-- Per-open Storage interaction and child lifetime owner.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local PcStorageActions = require("libs.hgss.src.field.PcStorageActions")
local StorageInterface = require("game.hgss.src.pc.StorageInterface")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Mon = require("libs.mons.src.Mon")
local Personality = require("libs.mons.src.gen4.Personality")

---@class StorageScreenState
---@field _mode integer
---@field _mons HgssMonService
---@field _bag HgssBagService
---@field _actions PcStorageActions
---@field _manifest table<string, unknown>
---@field _measureDisplay fun(): DisplayMeasurement
---@field _session ApplicationPresentation
---@field _activeBox integer
---@field _contents table<string, unknown>?
---@field _publishedView table<string, unknown>?
---@field _publishedKey string?
---@field _admittedParentView table<string, unknown>?
---@field _admittedParentPlan table<string, unknown>?
---@field _dexNumber fun(speciesKey: string): integer?
---@field _tray "left"|"closed"
---@field _prompt { kind: "exit"|"continue" }?
---@field _notice { id: integer, subject: string? }?
---@field _noticedAction table<string, unknown>?
---@field _focus table<string, unknown>
---@field _carry table<string, unknown>?
---@field _menu { actions: string[], selected: integer, address: table<string, unknown> }?
---@field _editor table<string, unknown>?
---@field _child table<string, unknown>?
---@field _childKind string?
---@field _childRequest table<string, unknown>?
---@field _pendingIntent table<string, unknown>?
---@field _children table<string, fun(request: table<string, unknown>): table<string, unknown>>
---@field _releaseCheck table<string, unknown>?
---@field _releaseIntent table<string, unknown>?
---@field _releaseRevisions table<string, integer>?
---@field _transitionTick integer
---@field _closed boolean
---@field _resultTaken boolean
---@field _disposed boolean
---@field _state string
local StorageScreenState = {}
StorageScreenState.__index = StorageScreenState

local COMPILED_BOX_NAME_COUNT = 18

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = copy(child)
  end
  return result
end

-- Encodes one small semantic fact deterministically so successive ticks can
-- compare what the published view and layout were built from without
-- rebuilding them. Table keys sort by their text form; only screen-owned
-- interaction facts flow through here, never domain rows or GPU objects.
local function encodeFact(value)
  local kind = type(value)
  if kind == "table" then
    local keys = {}
    for key in pairs(value) do
      keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
      return tostring(a) .. "#" .. type(a) < tostring(b) .. "#" .. type(b)
    end)
    local parts = {}
    for _, key in ipairs(keys) do
      parts[#parts + 1] = encodeFact(key) .. "=" .. encodeFact(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif kind == "string" then
    return "s" .. tostring(#value) .. ":" .. value
  elseif kind == "number" or kind == "boolean" then
    return tostring(value)
  elseif value == nil then
    return "nil"
  else
    return kind .. ":" .. tostring(value)
  end
end

function StorageScreenState.new(options)
  assert(type(options) == "table", "Storage opens with concrete collaborators")
  assert(
    type(options.mode) == "number" and options.mode % 1 == 0 and options.mode >= 0 and options.mode <= 3,
    "Storage mode is one of the retail modes"
  )
  assert(options.mons ~= nil and options.bag ~= nil, "Storage borrows the live mon and Bag services")
  assert(type(options.measureDisplay) == "function", "Storage reads current display measurement")
  local manifest = assert(options.manifest, "Storage borrows its compiled manifest")
  local self = setmetatable({
    _mode = options.mode,
    _mons = options.mons,
    _bag = options.bag,
    _actions = PcStorageActions.new({ mons = options.mons, bag = options.bag }),
    _manifest = manifest,
    _measureDisplay = options.measureDisplay,
    _audio = options.audio,
    _icons = options.icons,
    _portraits = options.portraits,
    _children = options.childFactories or {},
    _activeBox = options.mons:activeBox(),
    _contents = nil,
    _publishedView = nil,
    _publishedKey = nil,
    _admittedParentView = nil,
    _admittedParentPlan = nil,
    _focus = { domain = options.mode == 1 and "box" or "party", slot = 0 },
    _dexNumber = assert(options.dexNumber, "Storage needs its dex number reader"),
    -- The party tray starts open at the left only in Deposit mode; the other
    -- modes open it from the PARTY button (EB2EC, EC354).
    _tray = options.mode == 0 and "left" or "closed",
    _prompt = nil,
    _notice = nil,
    _noticedAction = nil,
    _carry = nil,
    _menu = nil,
    _editor = nil,
    _child = nil,
    _childKind = nil,
    _childRequest = nil,
    _releaseCheck = nil,
    _releaseIntent = nil,
    _releaseRevisions = nil,
    _transitionTick = 0,
    _closed = false,
    _resultTaken = false,
    _disposed = false,
    _state = "browse",
  }, StorageScreenState)
  self._session = ApplicationPresentation.new(StorageInterface.defaults(manifest), options.overrides)
  self:_resolve()
  return self
end

-- Refreshes the private visible-box/party snapshot when its identity moved.
-- The identity is the pair of live revisions plus the screen's active box, so
-- off-screen boxes never widen display reads. Publication is all-or-nothing:
-- every narrow read must succeed and the revisions must still match, otherwise
-- the prior complete contents stay in place for that attempt.
function StorageScreenState:_refreshContents()
  local current = self._contents
  if
    current ~= nil
    and current.boxRevision == self._mons:boxRevision()
    and current.partyRevision == self._mons:partyRevision()
    and current.activeBox == self._activeBox
  then
    return
  end
  for _ = 1, 2 do
    local boxRevision = self._mons:boxRevision()
    local partyRevision = self._mons:partyRevision()
    local activeBox = self._activeBox
    local metadata = self._mons:boxMetadata(activeBox)
    local unlocks = self._mons:boxBonusUnlocks()
    local boxSlots = {}
    for slot = 0, 29 do
      boxSlots[slot + 1] = self._mons:boxMon(activeBox, slot) or false
    end
    local party = {}
    for slot = 0, self._mons:partyCount() - 1 do
      party[slot + 1] = self._mons:partyMon(slot)
    end
    if boxRevision == self._mons:boxRevision() and partyRevision == self._mons:partyRevision() then
      self._contents = {
        boxRevision = boxRevision,
        partyRevision = partyRevision,
        activeBox = activeBox,
        metadata = metadata,
        unlocks = unlocks,
        boxSlots = boxSlots,
        party = party,
      }
      return
    end
    if self._contents ~= nil then
      return
    end
  end
  assert(self._contents ~= nil, "Storage projection requires settled revisions")
end

-- Builds a transient display view from the retained contents plus live
-- interaction state. Selection, menus, carry, release progress, editor drafts
-- and transition ticks stay outside the revision-keyed contents, so they keep
-- advancing while the domain snapshot is unchanged. Every returned fact is a
-- detached copy; the retained rows never escape.
-- Message bank 25 ids for refusals, by action and reason (resolvers ov14_021F685C,
-- ov14_021F67B0 and ov14_021F68C0). Reasons without a source message stay silent.
local REFUSAL_MESSAGES = {
  party_full = 5,
  mail_attached = 30,
  capsule_attached = 29,
  last_usable = 6,
  bag_full = 14,
  no_item = nil,
}

---@param decision table<string, unknown>
---@return integer?
local function refusalMessageId(decision)
  local reason, action = decision.reason, decision.action
  if reason == "egg" then
    return action == "release" and 31 or 34
  elseif reason == "mail" then
    return action == "takeItem" and 24 or 54
  elseif reason == "griseous_orb" then
    return 55
  end
  return REFUSAL_MESSAGES[reason]
end

-- Turns a new refusal into the message line that shows until the next input.
function StorageScreenState:_syncNotice()
  local action = self._lastAction
  if action == self._noticedAction then
    return
  end
  self._noticedAction = action
  self._notice = nil
  if action ~= nil and action.kind == "refused" then
    local id = refusalMessageId(action)
    if id ~= nil then
      local mon = self:_occupant(self:_address(self._focus))
      self._notice = { id = id, subject = self:_itemSubject(mon, action) }
    end
  end
end

---@param mon table<string, unknown>?
---@param decision table<string, unknown>
---@return string?
function StorageScreenState:_itemSubject(mon, decision)
  local itemKey = decision.reason == "griseous_orb" and "GRISEOUS_ORB" or mon ~= nil and mon.heldItem or nil
  if itemKey == nil or itemKey == "NONE" then
    return nil
  end
  local ok, item = pcall(function()
    return self._bag:catalog():item(itemKey)
  end)
  return ok and item.name or nil
end

---@return string?
function StorageScreenState:_pendingSubject()
  local request = self._pendingIntent and self._pendingIntent.request
  local source = request and request.source
  return source ~= nil and self:_itemSubject(self:_occupant(source), {}) or nil
end

-- The prompt or message line, chosen by what the screen is doing (windows
-- W37/W39/W40/W38 of ov14_021F84B4 and resolvers F685C, F67B0, F68C0, F6844,
-- F6928). The browse prompt shows only in Deposit and Withdraw.
---@return { id: integer, window: string, subject: string?, yesNo: boolean? }?
function StorageScreenState:_message()
  if self._prompt ~= nil then
    return { id = self._prompt.kind == "exit" and 11 or 12, window = "W37", yesNo = true }
  end
  local check = self._releaseCheck
  if check ~= nil and not check.acknowledged then
    if check.outcome == "confirm" then
      return { id = 2, window = "W37", subject = check.name, yesNo = true }
    elseif check.outcome == "removed" then
      return { id = 3, window = "W37", subject = check.name }
    elseif check.outcome == "returned" then
      return { id = 32, window = "W37", subject = check.name }
    elseif check.outcome == "cancelled" and check.reason ~= nil then
      local id = refusalMessageId({ action = "release", reason = check.reason })
      return id ~= nil and { id = id, window = "W37" } or nil
    end
  end
  if self._pendingIntent ~= nil then
    return { id = 23, window = "W37", yesNo = true, subject = self:_pendingSubject() }
  end
  if self._notice ~= nil then
    return { id = self._notice.id, window = "W37", subject = self._notice.subject }
  end
  if self._editor ~= nil then
    if self._editor.kind == "markings" then
      return { id = 35, window = "W38" }
    end
    return { id = 10, window = "W39" }
  end
  if self._menu ~= nil and self._menu.address == nil then
    return { id = 7, window = "W39" }
  end
  local address = self:_address(self._focus)
  local mon = self._carry ~= nil and self._carry.mon or self:_occupant(address)
  if self._carry ~= nil or self._menu ~= nil then
    if self._mode <= 1 and mon ~= nil then
      return { id = 0, window = "W39", subject = Mon.displayName(mon, self._mons:catalog()) }
    elseif self._mode == 2 and mon ~= nil then
      return { id = mon.mail ~= nil and next(mon.mail) ~= nil and 56 or 36, window = "W40" }
    end
    return nil
  end
  if self._mode <= 1 then
    return { id = 18, window = "W39" }
  end
  return nil
end

-- The facts the top-screen info panel prints for the carried or highlighted
-- Pokémon (source window table ov14_021F84B4); nil when nothing is selected.
---@return table<string, unknown>?
function StorageScreenState:_selectedInfo()
  local mon = self._carry and self._carry.mon
  if mon == nil then
    local address = self:_address(self._focus)
    if address.kind == "party" then
      mon = address.slot < self._mons:partyCount() and self._mons:partyMon(address.slot) or nil
    else
      mon = self._mons:boxMon(address.box, address.slot)
    end
  end
  if mon == nil then
    return nil
  end
  local catalog = self._mons:catalog()
  local info = {
    nickname = Mon.displayName(mon, catalog),
    egg = mon.isEgg == true,
    itemName = mon.heldItem ~= "NONE" and self._bag:catalog():item(mon.heldItem).name or nil,
  }
  if not info.egg then
    local species = catalog:species(mon.species)
    info.speciesName = species.name
    info.level = self._mons:derive(mon).level
    info.dexNumber = self._dexNumber(mon.species)
    local gender = Personality.gender(species.genderRatio, mon.personality)
    info.gender = gender ~= "genderless" and gender or nil
    info.natureName = HgssMonService.natureName(Personality.nature(mon.personality))
    info.abilityName = catalog:ability(mon.ability).name
  end
  return info
end

function StorageScreenState:_buildView()
  local contents = assert(self._contents, "Storage projection refreshes before building its view")
  local boxSlots = {}
  for index, mon in ipairs(contents.boxSlots) do
    if mon == false then
      boxSlots[index] = false
    else
      local shown = copy(mon)
      shown.iconKey = self._mons:catalog():iconSelection(shown)
      shown.itemIconKey = self._bag:catalog():item(shown.heldItem).icon
      boxSlots[index] = shown
    end
  end
  local party = {}
  for index, mon in ipairs(contents.party) do
    local shown = copy(mon)
    shown.iconKey = self._mons:catalog():iconSelection(shown)
    shown.itemIconKey = self._bag:catalog():item(shown.heldItem).icon
    party[index] = shown
  end
  local metadata = contents.metadata
  return {
    mode = self._mode,
    state = self._state,
    activeBox = self._activeBox,
    wallpaperId = metadata.wallpaperId,
    boxName = metadata.name or self:_defaultBoxName(),
    boxSlots = boxSlots,
    party = party,
    info = self:_selectedInfo(),
    tray = self._tray,
    message = self:_message(),
    focus = copy(self._focus),
    carry = copy(self._carry),
    menu = copy(self._menu),
    editor = copy(self._editor),
    wallpaperUnlocks = copy(contents.unlocks),
  }
end

function StorageScreenState:_view()
  self:_refreshContents()
  return self:_buildView()
end

function StorageScreenState:_defaultBoxName()
  local storage = assert(self._manifest.storage, "Storage borrows its compiled storage manifest")
  local boxNames = assert(storage.boxNames, "Storage manifest carries source box names")
  if self._activeBox < COMPILED_BOX_NAME_COUNT then
    return assert(boxNames[self._activeBox + 1], "Storage manifest carries every compiled box name")
  end
  local format = assert(storage.expansionNameFormat, "Storage manifest carries its expansion name format")
  return format.prefix .. tostring(format.firstNumber + self._activeBox) .. format.suffix
end

function StorageScreenState:_address(target)
  if target.domain == "party" or target.kind == "party" then
    return { kind = "party", slot = target.slot }
  end
  return { kind = "box", box = self._activeBox, slot = target.slot }
end

function StorageScreenState:_monVisual(address)
  local mon = address.kind == "party" and self._mons:partyMon(address.slot)
    or self._mons:boxMon(address.box, address.slot)
  if mon == nil then
    return nil
  end
  mon.iconKey = self._mons:catalog():iconSelection(mon)
  mon.itemIconKey = self._bag:catalog():item(mon.heldItem).icon
  return mon
end

-- The action list for a tapped mon, per retail mode (the lists are ov14_021F7D3C,
-- ov14_021F7D2C and ov14_021F7D1C; the party tap in Withdraw mode is inferred
-- to show the deposit-side list). Nothing is filtered when a list is built:
-- rejections happen after the press.
---@param address table<string, unknown>
---@param mon table<string, unknown>?
---@return string[]?
function StorageScreenState:_actionsFor(address, mon)
  if mon == nil then
    return nil
  end
  if self._mode == 0 then
    return address.kind == "party" and { "deposit", "summary", "markings", "release" } or nil
  elseif self._mode == 1 then
    return address.kind == "box" and { "withdraw", "summary", "markings", "release" }
      or { "deposit", "summary", "markings", "release" }
  elseif self._mode == 2 then
    return { "move", "summary", "heldItems", "markings", "release" }
  end
  return nil
end

-- Tags a refusal with the action that caused it, so messages can differ per
-- action (an egg cannot be released, and cannot hold an item).
function StorageScreenState:_preview(request)
  local decision = self._actions:preview(request)
  if decision.kind == "refused" then
    decision.action = request.kind
  end
  return decision
end

function StorageScreenState:_occupant(address)
  if address.kind == "party" then
    return address.slot < self._mons:partyCount() and self._mons:partyMon(address.slot) or nil
  end
  return self._mons:boxMon(address.box, address.slot)
end

-- A tap on a mon: Move mode picks it up at once with its list showing, the item
-- mode picks up the held item directly, and the other modes list actions.
function StorageScreenState:_openMenu()
  local address = self:_address(self._focus)
  local mon = self:_occupant(address)
  if self._mode == 3 then
    if mon ~= nil and mon.heldItem ~= "NONE" then
      self:_beginAction("swapItems", nil, address)
    end
    return
  end
  local actions = self:_actionsFor(address, mon)
  if actions == nil then
    self._menu = nil
    return
  end
  self._menu = { actions = actions, selected = 1, address = address }
  if self._mode == 2 then
    self._carry = { kind = "mon", action = "move", source = address, mon = self:_monVisual(address) }
  end
end

-- Arms one release decision from a detached address and a single live
-- preview. Confirmation and protected-move return share the confirmation
-- path; any other preview outcome records the same cancelled/stale mapping
-- from either input origin. A second request while a live decision
-- (confirm/pending) is underway is rejected; a terminal outcome admits a
-- fresh request that retires the previous result.
function StorageScreenState:_startRelease(address)
  local existing = self._releaseCheck
  if existing ~= nil then
    assert(
      existing.outcome == "removed"
        or existing.outcome == "returned"
        or existing.outcome == "stale"
        or existing.outcome == "cancelled",
      "only one release decision may be armed"
    )
  end
  self._releaseCheck, self._releaseIntent, self._releaseRevisions = nil, nil, nil
  local source = copy(address)
  local intent = self:_preview({ kind = "release", source = source })
  local occupant = self:_occupant(source)
  local name = occupant ~= nil and Mon.displayName(occupant, self._mons:catalog()) or nil
  if intent.kind == "confirm" or intent.reason == "hm_return" then
    self._releaseIntent = intent
    self._releaseRevisions = copy(intent.expected)
    self._releaseCheck = {
      address = copy(source),
      name = name,
      scanned = 0,
      total = self._mons:boxCount() * 30 + 6,
      outcome = "confirm",
    }
  else
    self._releaseCheck = {
      address = copy(source),
      name = name,
      reason = intent.reason,
      scanned = 0,
      total = self._mons:boxCount() * 30 + 6,
      outcome = intent.kind == "stale" and "stale" or "cancelled",
    }
  end
end

---@param action string
---@param data table<string, unknown>?
---@param address table<string, unknown>? the acted-on address when no list is open
function StorageScreenState:_beginAction(action, data, address)
  local source = address or (self._menu and self._menu.address)
  if action == "move" and self._carry ~= nil and self._carry.action == "move" then
    return
  end
  if self._carry ~= nil and self._carry.action == "move" and self._mode == 2 then
    -- Another list entry puts the picked-up mon back first.
    self._carry = nil
  end
  self._menu = nil
  if action == "wallpaper" or action == "boxName" then
    source = source or self:_address(self._focus)
  else
    assert(source ~= nil, "Storage actions start at a selected address")
  end
  if action == "deposit" then
    self._focus = { domain = "box", slot = self._focus.slot }
    self._carry = {
      kind = "mon",
      action = action,
      source = source,
      mon = self:_monVisual(source),
    }
  elseif action == "withdraw" then
    self._carry = {
      kind = "mon",
      action = action,
      source = source,
      mon = self:_monVisual(source),
      destination = { kind = "party", slot = self._mons:partyCount() },
    }
  elseif action == "move" then
    self._carry = { kind = "mon", action = action, source = source, mon = self:_monVisual(source) }
  elseif action == "swapItems" then
    self._carry = { kind = "items", action = action, source = source, mon = self:_monVisual(source) }
  elseif action == "giveItem" then
    self:_openChild("heldItemPicker", { source = source })
  elseif action == "takeItem" then
    local intent = self:_preview({ kind = action, source = source, item = data and data.item })
    self._lastAction = intent.kind == "allowed" and self._actions:commit(intent) or intent
    if intent.kind == "confirm" then
      self._pendingIntent = intent
    end
  elseif action == "bagItem" then
    -- BAG puts the held item away (mode 3's bottom-right button).
    local carried = self._carry
    if carried ~= nil and carried.kind == "items" then
      self._carry = nil
      self:_beginAction("takeItem", nil, carried.source)
    end
  elseif action == "heldItems" then
    -- One entry that branches on the held item (ov14_021F5EE4 handlers).
    local mon = self:_occupant(source)
    if mon ~= nil and mon.isEgg == true then
      self._lastAction = { kind = "rejected", reason = "egg" }
    elseif mon ~= nil and mon.heldItem == "NONE" then
      self:_openChild("heldItemPicker", { source = source })
    else
      self:_beginAction("takeItem", nil, source)
    end
  elseif action == "release" then
    self:_startRelease(source)
  elseif action == "markings" then
    local mon = assert(self:_monVisual(source), "markings edit an occupied address")
    self._editor = { kind = "markings", source = source, mask = mon.markings, selected = 0 }
  elseif action == "wallpaper" then
    local wallpaperId = self._mons:boxMetadata(self._activeBox).wallpaperId
    local selected = wallpaperId >= 32 and wallpaperId - 16 or wallpaperId
    self._editor = { kind = "wallpaper", box = self._activeBox, selected = selected, focus = "slots" }
  elseif action == "summary" or action == "boxName" then
    self:_openChild(action, { source = source, box = self._activeBox })
  else
    error("unknown Storage action " .. tostring(action), 0)
  end
end

function StorageScreenState:_updateEditor(events)
  local editor = assert(self._editor)
  local function submit()
    local action
    if editor.kind == "markings" then
      action = { kind = "markings", source = editor.source, mask = editor.mask }
    else
      -- A locked entry, or the box's current wallpaper, keeps the chooser open.
      local wallpaperId = editor.selected < 16 and editor.selected or editor.selected + 16
      local unlocks = self._mons:boxBonusUnlocks()
      local unlocked = editor.selected < 16 or unlocks[editor.selected - 15] == true
      if unlocked and wallpaperId ~= self._mons:boxMetadata(editor.box).wallpaperId then
        action = { kind = "wallpaper", box = editor.box, wallpaperId = wallpaperId }
      end
    end
    if action ~= nil then
      self._lastAction = self._actions:commit(self:_preview(action))
      self._editor = nil
    end
  end
  for _, event in ipairs(events) do
    if event.type == "cancel" then
      self._editor = nil
      return
    elseif event.type == "pointer_cancel" then
      -- Pointer capture cancellation does not change the local draft.
    elseif event.type == "submit" then
      if editor.kind == "wallpaper" and editor.focus == "cancel" then
        self._editor = nil
        return
      end
      submit()
      if self._editor == nil then
        return
      end
    elseif editor.kind == "markings" and event.type == "navigate" then
      local delta = (event.direction == "left" and -1) or (event.direction == "right" and 1) or 0
      editor.selected = math.max(0, math.min(5, editor.selected + delta))
    elseif editor.kind == "wallpaper" and event.type == "navigate" then
      -- Left and right wrap among the page's four swatches; down walks to the
      -- confirm button and then Cancel (ov14_021F8900).
      local focus = editor.focus
      if focus == "slots" and (event.direction == "left" or event.direction == "right") then
        local step = event.direction == "left" and 3 or 1
        editor.selected = editor.selected - editor.selected % 4 + (editor.selected % 4 + step) % 4
      elseif event.direction == "down" then
        editor.focus = focus == "slots" and "confirm" or "cancel"
      elseif event.direction == "up" then
        editor.focus = focus == "cancel" and "confirm" or "slots"
      end
    elseif event.type == "wallpaper_choice" and editor.kind == "wallpaper" then
      local choice = event.id
      if type(choice) == "number" and choice % 1 == 0 and choice >= 0 and choice < 24 then
        editor.selected, editor.focus = choice, "slots"
      end
    elseif event.type == "wallpaper_page" and editor.kind == "wallpaper" then
      -- The arrows scroll a whole page of four, wrapping across the 24 entries.
      if event.delta == 1 or event.delta == -1 then
        editor.selected = (editor.selected + 4 * event.delta) % 24
      end
    elseif event.type == "marking_choice" and editor.kind == "markings" then
      local choice = event.id
      if type(choice) == "number" and choice % 1 == 0 and choice >= 0 and choice < 6 then
        editor.selected = choice
        local bit = 2 ^ choice
        local selected = math.floor(editor.mask / bit) % 2 == 1
        editor.mask = selected and editor.mask - bit or editor.mask + bit
      end
    elseif event.type == "confirm" then
      if editor.kind == "markings" then
        local bit = 2 ^ editor.selected
        local selected = math.floor(editor.mask / bit) % 2 == 1
        editor.mask = selected and editor.mask - bit or editor.mask + bit
      else
        submit()
        if self._editor == nil then
          return
        end
      end
    else
      assert(
        event.type == "navigate"
          or event.type == "wallpaper_choice"
          or event.type == "wallpaper_page"
          or event.type == "marking_choice",
        "unknown Storage editor input " .. event.type
      )
    end
  end
end

function StorageScreenState:_openChild(kind, request)
  local factory = assert(self._children[kind], "Storage child factory is composed: " .. kind)
  self._child = assert(factory(request), "Storage child factory returns its state")
  self._childKind, self._childRequest = kind, copy(request)
end

function StorageScreenState:_disposeChild()
  local child = self._child
  self._child, self._childKind, self._childRequest = nil, nil, nil
  if child ~= nil then
    child:dispose()
  end
end

function StorageScreenState:_updateChild(events)
  local child = assert(self._child)
  child:updateFixed(events)
  local kind, request = assert(self._childKind), assert(self._childRequest)
  if kind == "heldItemPicker" then
    local intent = child:takeIntent()
    if intent ~= nil then
      assert(intent.kind == "pick", "held item picker returns a Bag pick intent")
      local decision = self:_preview({
        kind = "giveItem",
        source = request.source,
        item = intent.item,
      })
      if decision.kind == "allowed" then
        self._lastAction = self._actions:commit(decision)
      elseif decision.kind == "confirm" then
        self._pendingIntent = decision
        self._lastAction = decision
      else
        self._lastAction = decision
      end
      self:_disposeChild()
      return
    end
  end
  local result = child.result and child:result() or child.takeResult and child:takeResult()
  if result ~= nil then
    local action
    if result.kind == "submit" and kind == "boxName" then
      action = { kind = "boxName", box = self._activeBox, name = result.text }
    elseif result.kind == "submit" and kind == "markings" then
      action = { kind = "markings", source = request.source, mask = result.mask }
    elseif result.kind == "submit" and kind == "wallpaper" then
      action = { kind = "wallpaper", box = self._activeBox, wallpaperId = result.wallpaperId }
    end
    if action ~= nil then
      self._lastAction = self._actions:commit(self:_preview(action))
    end
    self:_disposeChild()
  end
end

function StorageScreenState:_confirmCarry()
  local carry = assert(self._carry)
  local destination = carry.destination or self:_address(self._focus)
  if
    destination.kind == carry.source.kind and destination.kind == "party" and destination.slot == carry.source.slot
    or destination.kind == "box"
      and carry.source.kind == "box"
      and destination.box == carry.source.box
      and destination.slot == carry.source.slot
  then
    self._carry, self._menu = nil, nil
    return
  end
  if carry.kind == "items" then
    local intent = self:_preview({ kind = "swapItems", source = carry.source, destination = destination })
    self._lastAction = self._actions:commit(intent)
    self._carry, self._menu = nil, nil
    if self._lastAction.kind == "changed" or self._lastAction.kind == "unchanged" then
      self._focus = { domain = destination.kind, slot = destination.slot }
    end
    return
  end
  local occupied = destination.kind == "box" and self._mons:boxMon(destination.box, destination.slot) ~= nil
    or destination.kind == "party" and destination.slot < self._mons:partyCount()
  local kind = carry.action == "deposit" and "deposit"
    or carry.action == "withdraw" and "withdraw"
    or occupied and "swap"
    or "move"
  local intent = self:_preview({ kind = kind, source = carry.source, destination = destination })
  self._lastAction = self._actions:commit(intent)
  if self._lastAction.kind == "changed" or self._lastAction.kind == "unchanged" then
    self._focus, self._carry, self._menu = { domain = destination.kind, slot = destination.slot }, nil, nil
  end
end

function StorageScreenState:_resolve()
  assert(not self._disposed, "disposed Storage has no plan")
  self:_refreshContents()
  local view = self:_buildView()
  local measurement = self._measureDisplay()
  self._session:resolve(measurement, view)
  self._publishedView = view
  self._publishedKey = self:_publishKey(measurement)
end

-- Identifies everything the published pair was built from: the measured
-- display signature plus each screen-owned fact the view and its layout
-- read. Domain revisions cover external party/box drift; the transition
-- clock and the last action stay out because neither reaches the published
-- view nor its plan.
function StorageScreenState:_publishKey(measurement)
  return table.concat({
    assert(measurement.signature, "Storage publication keys on a measured display signature"),
    tostring(self._mode),
    tostring(self._state),
    tostring(self._activeBox),
    tostring(self._mons:boxRevision()),
    tostring(self._mons:partyRevision()),
    encodeFact(self._focus),
    encodeFact(self._carry),
    encodeFact(self._menu),
    encodeFact(self._editor),
    encodeFact(self._releaseCheck),
    encodeFact(self._prompt),
    encodeFact(self._notice),
    tostring(self._tray),
    tostring(self._childKind),
  }, "\0")
end

-- Returns the view input mapping and rendering must use, rebuilding and
-- resolving only when the measured display or a semantic fact moved since
-- the last publication. The first input of a tick therefore maps against
-- the previously published layout, and a stable idle tick performs no new
-- projection or resolution. A failed content refresh still propagates
-- before any mapping happens, retaining the prior complete contents.
function StorageScreenState:_ensurePublished()
  assert(not self._disposed, "disposed Storage has no plan")
  self:_syncNotice()
  self:_refreshContents()
  local measurement = self._measureDisplay()
  local key = self:_publishKey(measurement)
  if self._publishedView ~= nil and key == self._publishedKey then
    return self._publishedView
  end
  local view = self:_buildView()
  self._session:resolve(measurement, view)
  self._publishedView = view
  self._publishedKey = key
  return view
end

-- Slides the party tray out (modes 2 and 3 only: Deposit keeps it open).
function StorageScreenState:_closeTray()
  if self._mode >= 2 and self._tray ~= "closed" then
    self._tray = "closed"
    if self._focus.domain == "party" then
      self._focus = { domain = "box", slot = 0 }
    end
  end
end

-- Only the box-name editor consumes typed text.
---@return boolean
function StorageScreenState:acceptsText()
  return self._childKind == "boxName"
end

-- Answers the exit/continue prompt from one event. A closing answer
-- marks the screen closed, which ends the batch at its closed check.
---@param event table<string, unknown>
function StorageScreenState:_resolvePromptInput(event)
  -- Yes / No: the exit prompt leaves on Yes; "Continue Box operations?" leaves on No.
  local yes = event.type == "confirm"
  if yes or event.type == "cancel" then
    local leave = (self._prompt.kind == "exit") == yes
    self._prompt = nil
    if leave then
      self:cancel("input")
    end
  end
end

-- Applies the cancel precedence for one cancel event: an armed release first,
-- then the pending item intent, carry, menu, tray, and finally the prompt.
function StorageScreenState:_handleCancelInput()
  if
    self._releaseCheck ~= nil and (self._releaseCheck.outcome == "confirm" or self._releaseCheck.outcome == "pending")
  then
    self._releaseCheck.outcome = "cancelled"
    self._releaseIntent = nil
    self._releaseRevisions = nil
  elseif self._pendingIntent ~= nil then
    self._pendingIntent = nil
  elseif self._carry ~= nil then
    self._carry, self._menu = nil, nil
  elseif self._menu ~= nil then
    self._menu = nil
  elseif self._mode >= 2 and self._tray ~= "closed" then
    self:_closeTray()
  else
    self._prompt = { kind = "continue" }
  end
end

-- Moves focus, tray, active box, or the title-pair menu for one event.
---@param event table<string, unknown>
function StorageScreenState:_handleFocusInput(event)
  if event.type == "return" then
    if self._carry == nil and self._menu == nil and self._pendingIntent == nil then
      self._prompt = { kind = "exit" }
    end
  elseif event.type == "party" then
    if self._mode >= 2 and self._carry == nil then
      self._tray, self._focus = "left", { domain = "party", slot = 0 }
    end
  elseif event.type == "tray_close" then
    self:_closeTray()
  elseif event.type == "storage_target" then
    local target = copy(assert(event.target, "mapped Storage inputs identify a target"))
    local domain = target.domain or target.kind
    -- Deposit mode only hit-tests the party tray until a deposit asks where.
    local hidden = self._mode == 0 and domain == "box" and self._carry == nil
      or domain == "party" and self._tray == "closed"
    if not hidden then
      self._focus = { domain = domain, slot = target.slot }
      if target.box ~= nil then
        self._activeBox = target.box
      end
    end
  elseif event.type == "box_title" then
    -- The title plate opens the Wallpaper / Name pair.
    if self._carry == nil then
      self._menu = { actions = { "wallpaper", "boxName" }, selected = 1 }
    end
  elseif event.type == "navigate" then
    local direction = assert(event.direction)
    if self._menu ~= nil and self._carry == nil and (direction == "up" or direction == "down") then
      local delta = direction == "up" and -1 or 1
      self._menu.selected = math.max(1, math.min(#self._menu.actions, self._menu.selected + delta))
    elseif direction == "up" or direction == "down" then
      local delta = direction == "up" and -1 or 1
      self._focus.slot = math.max(0, math.min(self._focus.domain == "party" and 5 or 29, self._focus.slot + delta))
    elseif direction == "left" or direction == "right" then
      self._activeBox = (self._activeBox + (direction == "right" and 1 or -1)) % self._mons:boxCount()
      self._focus = { domain = self._focus.domain, slot = 0 }
      self._actions:commit(self:_preview({ kind = "activeBox", box = self._activeBox }))
    end
  else
    assert(false, "unknown Storage focus event " .. tostring(event.type))
  end
end

-- Dispatches one generic confirm or action event through the domain owner.
---@param event table<string, unknown>
function StorageScreenState:_handleConfirmInput(event)
  if event.type == "confirm" then
    if self._pendingIntent ~= nil then
      self._lastAction = self._actions:commit(self._pendingIntent, true)
      self._pendingIntent = nil
    elseif self._carry ~= nil then
      self:_confirmCarry()
    elseif self._menu ~= nil then
      local menu = assert(self._menu)
      local selectedAction = assert(menu.actions[menu.selected], "Storage selection resolves to a menu action")
      self:_beginAction(selectedAction)
    else
      self:_openMenu()
    end
  elseif event.type == "action" then
    self:_beginAction(assert(event.action), event, self._menu == nil and self:_address(self._focus) or nil)
  else
    assert(false, "unknown Storage input event " .. tostring(event.type))
  end
end

-- Dispatches one mapped event for the Storage-owned path. Returns true when
-- the event confirms an armed release and starts its scan slice.
---@param event table<string, unknown>
---@return boolean
function StorageScreenState:_dispatchStorageEvent(event)
  if self._prompt ~= nil then
    self:_resolvePromptInput(event)
    return false
  end
  local eventType = event.type
  if
    eventType == "return"
    or eventType == "party"
    or eventType == "tray_close"
    or eventType == "storage_target"
    or eventType == "box_title"
    or eventType == "navigate"
  then
    self:_handleFocusInput(event)
    return false
  elseif eventType == "release" then
    self:_startRelease(assert(event.address))
    return false
  elseif eventType == "confirm" and self._releaseCheck ~= nil and self._releaseCheck.outcome == "confirm" then
    self._releaseCheck.outcome = "pending"
    return true
  elseif eventType == "cancel" then
    self:_handleCancelInput()
    return false
  elseif eventType == "pointer_cancel" then
    -- The paired session has already discarded the invalid pointer capture.
    return false
  end
  self:_handleConfirmInput(event)
  return false
end

-- Dispatches the ordered batch until one action takes exclusive ownership.
-- A terminal close or a newly opened child or editor ends the batch so
-- later events never cross into another owner in the same tick. Returns the
-- scan suppression and whether the batch closed the screen.
---@param events table<string, unknown>[]
---@return boolean, boolean
function StorageScreenState:_dispatchStorageBatch(events)
  local beganScan = false
  for _, event in ipairs(events) do
    assert(type(event) == "table" and type(event.type) == "string", "Storage events are tagged records")
    if self:_dispatchStorageEvent(event) then
      beganScan = true
    end
    if self._closed then
      return beganScan, true
    end
    if self._child ~= nil or self._editor ~= nil then
      break
    end
  end
  return beganScan, false
end

-- Records the terminal outcome of one finished release scan.
---@param check table<string, unknown>
---@param result table<string, unknown>
function StorageScreenState:_settleReleaseResult(check, result)
  if result.kind == "stale" then
    check.outcome = "stale"
  elseif result.reason == "hm_return" then
    check.outcome = "returned"
  elseif result.kind == "changed" then
    check.outcome = "removed"
  else
    check.outcome = "cancelled"
  end
end

-- Advances the current release scan by exactly one fifteen-address slice.
function StorageScreenState:_advanceRelease()
  local check = self._releaseCheck
  if check == nil or check.outcome ~= "pending" then
    return
  end
  if
    self._releaseRevisions.partyRevision ~= self._mons:partyRevision()
    or self._releaseRevisions.boxRevision ~= self._mons:boxRevision()
  then
    check.outcome = "stale"
    self._releaseIntent = nil
    return
  end
  check.scanned = math.min(check.total, check.scanned + 15)
  if check.scanned == check.total then
    local intent = assert(self._releaseIntent)
    local result = intent.reason == "hm_return" and intent or self._actions:commit(intent, true)
    self:_settleReleaseResult(check, result)
    self._releaseIntent = nil
  end
end

---@param events table<string, unknown>[] an ordered batch of normalized events
function StorageScreenState:updateFixed(events)
  assert(not self._disposed, "disposed Storage does not update")
  assert(type(events) == "table", "Storage updates use an ordered event batch")
  if self._closed then
    return
  end
  if #events > 0 then
    -- A message stays until the next input, then the result is acknowledged.
    self._notice = nil
    local acknowledged = self._releaseCheck
    if acknowledged ~= nil and acknowledged.outcome ~= "confirm" and acknowledged.outcome ~= "pending" then
      acknowledged.acknowledged = true
    end
  end
  if self._child ~= nil then
    self:_updateChild(events)
    self:_ensurePublished()
    return
  end
  local view = self:_ensurePublished()
  events = self._session:mapInput(events, view)
  if self._editor ~= nil then
    self:_updateEditor(events)
    self:_ensurePublished()
    return
  end
  local beganScan, closedBatch = self:_dispatchStorageBatch(events)
  if closedBatch then
    return
  end
  self:_advanceRelease()
  if not beganScan then
    self._transitionTick = self._transitionTick + 1
  end
  self:_ensurePublished()
end

function StorageScreenState:status()
  local view = self:_ensurePublished()
  local status = {
    mode = self._mode,
    activeBox = self._activeBox,
    focus = copy(self._focus),
    phase = self._childKind and "child"
      or self._editor and "editor"
      or self._carry and "carry"
      or self._menu and "menu"
      or "browse",
    editor = copy(self._editor),
    menu = copy(self._menu),
    lastAction = copy(self._lastAction),
    transitionTick = self._transitionTick,
    childKind = self._childKind,
    releaseCheck = copy(self._releaseCheck),
    boxName = view.boxName,
    -- The slot projections stay detached copies: mutating a published
    -- status never reaches the stored mons nor the cached render facts,
    -- while the drawing snapshot below rides by identity.
    boxSlots = copy(view.boxSlots),
    party = copy(view.party),
    carry = copy(view.carry),
    -- The exact published snapshot drawing consumes this tick, borrowed
    -- transiently so the presentation boundary admits the same wallpaper,
    -- tray, and editor the next present paints. Never persisted.
    visualView = view,
    -- The last host-admitted parent pair, borrowed transiently so icon
    -- preparation can retain its pages while a replacement pends. The
    -- reference is read-only for composition and is never persisted.
    admittedParentView = self._admittedParentView,
  }
  if self._childKind == "heldItemPicker" and self._child ~= nil then
    status.bagChildStatus = self._child:status()
  end
  return status
end

--- Records the exact presented parent pair once the host admits it:
--- the current published view with its resolved plan. A held-item
--- picker admission preserves the previously recorded pair, so a pending
--- picker keeps drawing the parent it opened over. An open editor also
--- preserves the pair: the admitted surface stays the editor-free parent
--- the fallback is allowed to draw, never the transient chooser state.
function StorageScreenState:admitParentPresentation()
  assert(not self._disposed, "disposed Storage admits no presentation")
  if self._child ~= nil and self._childKind == "heldItemPicker" then
    return
  end
  if self._editor ~= nil then
    return
  end
  self:_ensurePublished()
  self._admittedParentView = self._publishedView
  self._admittedParentPlan = self._session:plan()
end

function StorageScreenState:draw(resources, presentationReady)
  assert(not self._disposed, "disposed Storage draws nothing")
  assert(type(resources) == "table", "Storage draw borrows its renderer resources")
  if self._child ~= nil and self._childKind == "heldItemPicker" then
    if presentationReady then
      local status = self._child:status()
      if status.presentation ~= nil then
        -- The narrowed Bag record mirrors the field Bag presenter; the
        -- plan's own render owns its requirements, so a presentation
        -- that ignores resources still draws through its own surface.
        ApplicationPresentation.draw(assert(love.graphics), {
          graphics = love.graphics,
          bagRenderer = assert(resources.bagRenderer, "Storage borrows the Bag renderer"),
          heroRenderer = assert(resources.heroRenderer, "Storage borrows the Bag hero renderer"),
          icons = assert(resources.itemIcons, "Storage borrows the Bag item icon provider"),
          text = assert(resources.textRenderer, "Storage borrows the text renderer"),
        }, status, status.presentation)
      end
      return
    end
  elseif presentationReady then
    local published = self:_ensurePublished()
    ApplicationPresentation.draw(assert(love.graphics), resources, published, self._session:plan())
    return
  end
  local admittedView = self._admittedParentView
  local admittedPlan = self._admittedParentPlan
  if admittedView == nil or admittedPlan == nil then
    return
  end
  ApplicationPresentation.draw(assert(love.graphics), resources, admittedView, admittedPlan)
end

-- The plan the last draw presented, so the host can decorate it with its outer
-- application frames. Selects the same route draw uses: the ready picker or
-- current parent when ready, otherwise the last recorded parent pair.
---@param presentationReady boolean?
---@return ApplicationPlan?
function StorageScreenState:presentationPlan(presentationReady)
  if self._child ~= nil and self._childKind == "heldItemPicker" then
    if presentationReady then
      return self._child:status().presentation
    end
    return self._admittedParentPlan
  end
  if presentationReady == false then
    return self._admittedParentPlan
  end
  return self._session:plan()
end

function StorageScreenState:result()
  if not self._closed or self._resultTaken then
    return nil
  end
  self._resultTaken = true
  return { kind = "closed" }
end

function StorageScreenState:isActive()
  return not self._closed and not self._disposed
end

function StorageScreenState:cancelPointerCapture()
  self._session:cancelPointers()
  local child = self._child
  if child ~= nil and type(child.cancelPointerCapture) == "function" then
    child:cancelPointerCapture()
  end
end

function StorageScreenState:cancel(_)
  if self._closed then
    return
  end
  self._closed = true
  self:_disposeChild()
  self._editor = nil
  if self._releaseCheck ~= nil and self._releaseCheck.outcome == "pending" then
    self._releaseCheck.outcome = "cancelled"
    self._releaseIntent = nil
  end
  self._session:cancelPointers()
end

function StorageScreenState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._contents = nil
  self._publishedView = nil
  self._publishedKey = nil
  self._admittedParentView = nil
  self._admittedParentPlan = nil
  self:_disposeChild()
  self._session:dispose()
end

return StorageScreenState
