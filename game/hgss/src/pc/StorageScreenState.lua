-- Per-open Storage interaction and child lifetime owner.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local PcStorageActions = require("libs.hgss.src.field.PcStorageActions")
local StorageInterface = require("game.hgss.src.pc.StorageInterface")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local PcStorageGeometry = require("libs.hgss.src.ui.PcStorageGeometry")
local PcStorageGrid = require("libs.hgss.src.ui.PcStorageGrid")
local MonCache = require("libs.assets.src.MonCache")
local SummaryModel = require("libs.hgss.src.ui.SummaryModel")
local Mon = require("libs.mons.src.Mon")
local Personality = require("libs.mons.src.gen4.Personality")

---@class StorageScreenState
---@field _mode integer
---@field _mons HgssMonService
---@field _bag HgssBagService
---@field _audio table<string, unknown>?
---@field _actions PcStorageActions
---@field _manifest table<string, unknown>
---@field _measureDisplay fun(): DisplayMeasurement
---@field _session ApplicationPresentation
---@field _admittedLayoutSession ApplicationPresentation?
---@field _publishedMeasurementSignature string?
---@field _admittedParentSignature string?
---@field _activeBox integer
---@field _contents table<string, unknown>?
---@field _publishedView table<string, unknown>?
---@field _publishedKey string?
---@field _admittedParentView table<string, unknown>?
---@field _admittedParentPlan table<string, unknown>?
---@field _dexNumber fun(speciesKey: string): integer?
---@field _tray "left"|"right"|"closed"
---@field _transferSide "right"?
---@field _transferGeneration integer
---@field _transfer { moves: { fromDomain: "box"|"party", from: integer, toDomain: "box"|"party", to: integer, mon: table<string, unknown>? }[] }?
---@field _boxTray "closed"|"box"|"deposit"
---@field _trayBox integer
---@field _boxTrayChangeBox boolean
---@field _prompt { kind: "exit"|"continue" }?
---@field _notice { id: integer, subject: string? }?
---@field _noticedAction table<string, unknown>?
---@field _resultNotice { id: integer, subject: string? }?
---@field _noticedResult table<string, unknown>?
---@field _promptChoice { key: string, choice: string }?
---@field _drag table<string, unknown>?
---@field _hint integer?
---@field _pendingResultAction string?
---@field _pendingResultItem string?
---@field _focus table<string, unknown>
---@field _grid PcStorageGrid
---@field _infoVisible boolean
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
    _publishedMeasurementSignature = nil,
    _admittedParentView = nil,
    _admittedParentPlan = nil,
    _admittedParentSignature = nil,
    -- Deposit starts on the always-open party panel; every other mode starts
    -- on the first box slot (PCBox_State_Start).
    _focus = { domain = options.mode == 0 and "party" or "box", slot = 0 },
    _grid = PcStorageGrid.new(PcStorageGrid.browseLayout(options.mode, options.mode == 0), 0),
    _infoVisible = true,
    _dexNumber = assert(options.dexNumber, "Storage needs its dex number reader"),
    -- The party tray starts open at the left only in Deposit mode; the other
    -- modes open it from the PARTY button (EB2EC, EC354).
    _tray = options.mode == 0 and "left" or "closed",
    _transferSide = nil,
    _transferGeneration = 0,
    _transfer = nil,
    _boxTray = "closed",
    _trayBox = options.mons:activeBox(),
    _boxTrayChangeBox = false,
    _prompt = nil,
    _notice = nil,
    _noticedAction = nil,
    _resultNotice = nil,
    _noticedResult = nil,
    _promptChoice = nil,
    _drag = nil,
    _hint = nil,
    _pendingResultAction = nil,
    _pendingResultItem = nil,
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
    _booted = false,
    _closed = false,
    _resultTaken = false,
    _disposed = false,
    _state = "browse",
  }, StorageScreenState)
  self._session = ApplicationPresentation.new(StorageInterface.defaults(manifest), options.overrides)
  local fallbackBuilt, fallbackSession =
    pcall(ApplicationPresentation.new, StorageInterface.defaults(manifest), options.overrides)
  if not fallbackBuilt then
    self._session:dispose()
    error(fallbackSession, 0)
  end
  self._admittedLayoutSession = fallbackSession
  local resolved, resolveError = pcall(function()
    self:_resolve()
  end)
  if not resolved then
    self._session:dispose()
    assert(self._admittedLayoutSession):dispose()
    error(resolveError, 0)
  end
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
  box_full = 13,
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

-- Turns a new refusal or item result into the message line that shows until
-- the next input.
function StorageScreenState:_syncNotice()
  local result = self._resultNotice
  if result ~= nil and result ~= self._noticedResult then
    self._noticedResult = result
    self._notice = result
    return
  end
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

-- Resolves one Bag item key to its catalog display name.
---@param itemKey string?
---@return string?
function StorageScreenState:_itemName(itemKey)
  if itemKey == nil or itemKey == "NONE" then
    return nil
  end
  local ok, item = pcall(function()
    return self._bag:catalog():item(itemKey)
  end)
  return ok and item.name or nil
end

-- Records the source's item result line after a committed item transfer:
-- 15 "Took the ...", 16 "... is now being held.", 27 "Placed ... in the Bag.".
---@param action string
---@param itemKey string?
---@param result table<string, unknown>?
function StorageScreenState:_recordItemResult(action, itemKey, result)
  if result == nil or (result.kind ~= "changed" and result.kind ~= "unchanged") then
    return
  end
  local id = action == "bagItem" and 27 or action == "giveItem" and 16 or 15
  self._resultNotice = { id = id, subject = self:_itemName(itemKey) }
end

---@return string?
function StorageScreenState:_pendingSubject()
  local request = self._pendingIntent and self._pendingIntent.request
  local source = request and request.source
  return source ~= nil and self:_itemSubject(self:_occupant(source), {}) or nil
end

-- Names the incoming item for a give-item replacement confirmation (bank 25
-- msg 26 'Put away {item}?'), resolved through the live Bag catalog.
---@param request table<string, unknown>
---@return string?
function StorageScreenState:_incomingItemSubject(request)
  if type(request.item) ~= "string" then
    return nil
  end
  local ok, item = pcall(function()
    return self._bag:catalog():item(request.item)
  end)
  return ok and item.name or nil
end

-- The open two-row confirmation prompt and its highlighted row. The source
-- prompt opens on NO for a release decision and on YES for every other
-- question; up/down toggles it.
---@return { key: string, choice: string }?
function StorageScreenState:_yesNoPrompt()
  local key
  if self._prompt ~= nil then
    key = "prompt:" .. self._prompt.kind
  elseif self._releaseCheck ~= nil and self._releaseCheck.outcome == "confirm" then
    key = "release"
  elseif self._pendingIntent ~= nil then
    key = "intent"
  end
  if key == nil then
    self._promptChoice = nil
    return nil
  end
  local state = self._promptChoice
  if state == nil or state.key ~= key then
    state = { key = key, choice = key == "release" and "no" or "yes" }
    self._promptChoice = state
  end
  return state
end

-- Resolves the prompt's highlighted row into the generic event the screen
-- already handles: NO resolves exactly like a cancel.
---@param event table<string, unknown>
---@return table<string, unknown>
function StorageScreenState:_resolvePromptChoice(event)
  local prompt = self:_yesNoPrompt()
  if prompt == nil then
    return event
  end
  if event.type == "navigate" and (event.direction == "up" or event.direction == "down") then
    prompt.choice = prompt.choice == "yes" and "no" or "yes"
    self:_cue("SEQ_SE_DP_SELECT")
    return { type = "prompt_choice" }
  end
  if event.type == "confirm" and prompt.choice == "no" then
    return { type = "cancel" }
  end
  if event.type == "cancel" or event.type == "confirm" then
    prompt.choice = event.type == "confirm" and "yes" or "no"
  end
  return event
end

-- The prompt or message line, chosen by what the screen is doing (windows
-- W37/W39/W40/W38 of ov14_021F84B4 and resolvers F685C, F67B0, F68C0, F6844,
-- F6928). The browse prompt shows only in Deposit and Withdraw.
---@return { id: integer, window: string, subject: string?, yesNo: boolean? }?
local function messageRecord(self)
  if self._prompt ~= nil then
    return { id = self._prompt.kind == "exit" and 11 or 12, window = "W37", yesNo = true }
  end
  local check = self._releaseCheck
  if check ~= nil and not check.acknowledged then
    if check.outcome == "confirm" then
      return { id = 2, window = "W37", subject = check.name, yesNo = true }
    elseif check.outcome == "released" then
      return { id = check.sequel and 4 or 3, window = "W37", subject = check.name }
    elseif check.outcome == "returned" then
      return { id = check.sequel and 33 or 32, window = "W37", subject = check.sequel and nil or check.name }
    elseif check.outcome == "cancelled" and check.reason ~= nil then
      local id = refusalMessageId({ action = "release", reason = check.reason })
      return id ~= nil and { id = id, window = "W37" } or nil
    end
  end
  if self._pendingIntent ~= nil then
    local request = self._pendingIntent.request
    if request ~= nil and request.kind == "giveItem" then
      return { id = 26, window = "W37", yesNo = true, subject = self:_incomingItemSubject(request) }
    end
    -- Taking asks "Take this ...?"; the BAG half asks "Put away ...?".
    local id = self._pendingResultAction == "bagItem" and 26 or 23
    return { id = id, window = "W37", yesNo = true, subject = self:_pendingSubject() }
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
  if self._carry ~= nil and self._carry.action == "deposit" then
    return { id = 19, window = "W39" }
  end
  if self._menu ~= nil and self._menu.address == nil then
    return { id = 7, window = "W39" }
  end
  local address = self:_address(self._focus)
  local mon = self._carry ~= nil and self._carry.mon or self:_occupant(address)
  if self._carry ~= nil or self._menu ~= nil then
    if self._mode <= 1 and mon ~= nil then
      return { id = 0, window = "W39", subject = Mon.displayName(mon, self._mons:catalog()) }
    end
    return nil
  end
  if self._mode <= 1 then
    return { id = 18, window = "W39" }
  end
  return nil
end

-- The prompt or message line with the highlighted row of an open two-row
-- confirmation attached, so the baked button art can swap its selected row.
---@return table<string, unknown>?
function StorageScreenState:_message()
  if self._hint ~= nil and self._drag ~= nil then
    return { id = self._hint, window = "W40", yesNo = false }
  end
  local message = messageRecord(self)
  if message == nil or message.yesNo ~= true then
    return message
  end
  return {
    id = message.id,
    window = message.window,
    subject = message.subject,
    yesNo = true,
    yesNoChoice = assert(self:_yesNoPrompt()).choice,
  }
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
  local item = mon.heldItem ~= "NONE" and self._bag:catalog():item(mon.heldItem) or nil
  local info = {
    nickname = Mon.displayName(mon, catalog),
    egg = mon.isEgg == true,
    itemName = item and item.name or nil,
    itemDescription = item and item.description or nil,
    itemIconKey = item and item.icon or nil,
    -- Eggs show the shared egg picture; everything else resolves the exact
    -- generated front portrait.
    portraitSelector = mon.isEgg == true and MonCache.portraitSelector("EGG", 0, "male", false)
      or SummaryModel.portraitSelectorFor(catalog, mon),
  }
  if not info.egg then
    local species = catalog:species(mon.species)
    local form = assert(catalog:form(mon.species, assert(mon.form, "stored mons carry their form")))
    info.speciesName = species.name
    info.types = assert(form.types, "catalog forms carry their types")
    info.level = self._mons:derive(mon).level
    info.dexNumber = self._dexNumber(mon.species)
    local gender = Personality.gender(species.genderRatio, mon.personality)
    info.gender = gender ~= "genderless" and gender or nil
    info.natureName = HgssMonService.natureName(Personality.nature(mon.personality))
    info.abilityName = catalog:ability(mon.ability).name
    info.moves = {}
    for slot = 1, 4 do
      local entry = mon.moves and mon.moves[slot]
      info.moves[slot] = entry ~= nil and catalog:move(entry.move).name or nil
    end
  end
  return info
end

-- The release animation the source currently shows: the shrink/grow phase
-- with its tick, or the hidden slot after the shrink while the messages run.
---@return table<string, unknown>?
function StorageScreenState:_releaseView()
  local check = self._releaseCheck
  if check == nil then
    return nil
  end
  if check.outcome == "pending" and check.phase ~= nil then
    return { phase = check.phase, tick = check.shrink, address = copy(check.address), mon = copy(check.mon) }
  end
  if check.outcome == "released" then
    return { phase = "hidden", address = copy(check.address) }
  end
  return nil
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
  local transferGeneration = self._transferGeneration
  return {
    mode = self._mode,
    state = self._state,
    activeBox = self._activeBox,
    wallpaperId = metadata.wallpaperId,
    boxName = metadata.name or self:_defaultBoxName(),
    boxSlots = boxSlots,
    party = party,
    info = self._infoVisible and self:_selectedInfo() or nil,
    tray = self._tray,
    transferSide = self._transferSide,
    transferGeneration = transferGeneration,
    transfer = copy(self._transfer),
    onTransferComplete = self._transferSide ~= nil and function()
      if self._transferGeneration == transferGeneration then
        self._transferSide = nil
        self._transfer = nil
      end
    end or nil,
    message = self:_message(),
    focus = copy(self._focus),
    cursor = self:_cursorView(),
    boxTray = self:_boxTrayView(),
    release = self:_releaseView(),
    carry = copy(self._carry),
    drag = copy(self._drag),
    menu = copy(self._menu),
    editor = copy(self._editor),
    wallpaperUnlocks = copy(contents.unlocks),
  }
end

function StorageScreenState:_view()
  self:_refreshContents()
  return self:_buildView()
end

---@param box integer?
---@return string
function StorageScreenState:_boxName(box)
  box = box or self._activeBox
  local storage = assert(self._manifest.storage, "Storage borrows its compiled storage manifest")
  local boxNames = assert(storage.boxNames, "Storage manifest carries source box names")
  if box < COMPILED_BOX_NAME_COUNT then
    return assert(boxNames[box + 1], "Storage manifest carries every compiled box name")
  end
  local format = assert(storage.expansionNameFormat, "Storage manifest carries its expansion name format")
  return format.prefix .. tostring(format.firstNumber + box) .. format.suffix
end

function StorageScreenState:_defaultBoxName()
  return self:_boxName(self._activeBox)
end

-- The visible six-box page of the open box tray: names, counts, wallpapers
-- and one BASE_COLOR dot per occupied slot.
---@return table<string, unknown>?
function StorageScreenState:_boxTrayView()
  if self._boxTray == "closed" then
    return nil
  end
  local catalog = self._mons:catalog()
  local page = math.floor(self._trayBox / PcStorageGeometry.TRAY_PAGE_SIZE) * PcStorageGeometry.TRAY_PAGE_SIZE
  local boxes = {}
  for column = 0, PcStorageGeometry.TRAY_PAGE_SIZE - 1 do
    local box = page + column
    local dots, count = {}, 0
    for slot = 0, 29 do
      local mon = self._mons:boxMon(box, slot)
      if mon ~= nil then
        count = count + 1
        if mon.isEgg == true then
          dots[slot + 1] = mon.species == "MANAPHY" and 1 or 8
        else
          dots[slot + 1] = catalog:species(mon.species).color
        end
      end
    end
    local metadata = self._mons:boxMetadata(box)
    boxes[column + 1] = {
      box = box,
      name = self:_boxName(box),
      count = count,
      wallpaperId = metadata.wallpaperId,
      dots = dots,
      active = box == self._activeBox,
    }
  end
  return {
    mode = self._boxTray,
    trayBox = self._trayBox,
    page = page,
    boxes = boxes,
    changeBox = self._boxTrayChangeBox,
  }
end

function StorageScreenState:_address(target)
  if target.domain == "party" or target.kind == "party" then
    return { kind = "party", slot = target.slot }
  end
  return { kind = "box", box = self._activeBox, slot = target.slot }
end

-- The browse grid depends on the mode and whether the party panel is open;
-- Deposit keeps the panel open for the whole session.
---@return string
function StorageScreenState:_browseLayout()
  return PcStorageGrid.browseLayout(self._mode, self._tray ~= "closed")
end

-- Grid node id of one slot in a layout, or nil when the layout does not carry
-- that custody domain.
---@param domain "box"|"party"
---@param slot integer
---@return integer?
function StorageScreenState:_nodeForSlot(domain, slot)
  local layout = self._grid:layoutName()
  if layout == "deposit" or layout == "moveParty" or layout == "itemParty" then
    return domain == "party" and slot or nil
  end
  if layout == "tray" then
    return domain == "party" and 30 + slot or slot
  end
  if layout == "depositBox" then
    return nil
  end
  return domain == "box" and slot or nil
end

-- First and last action-row node of the open list in the current layout.
---@return integer?, integer?
function StorageScreenState:_menuNodes()
  local layout = self._grid:layoutName()
  if layout == "deposit" then
    return 7, 10
  elseif layout == "withdraw" then
    return 34, 37
  elseif layout == "move" then
    return 36, 40
  elseif layout == "moveParty" then
    return 8, 12
  elseif layout == "item" then
    return 36, 36
  elseif layout == "itemParty" then
    return 8, 8
  elseif layout == "boxMenu" then
    return 9, 10
  end
  return nil, nil
end

-- Where the source sends the cursor when the action list opens.
---@return integer?
function StorageScreenState:_firstMenuNode()
  local first = self:_menuNodes()
  return first
end

-- Projects the cursor node onto the selection facts the view publishes:
-- the highlighted slot, the open list row and the editor's focused control.
function StorageScreenState:_applyCursorFocus()
  local node = self._grid:current()
  local kind = node.kind
  if kind == "box" then
    self._focus = { domain = "box", slot = node.index }
    self._infoVisible = true
  elseif kind == "party" then
    self._focus = { domain = "party", slot = node.index }
    self._infoVisible = true
  elseif kind == "box_tray" then
    local page = math.floor(self._trayBox / PcStorageGeometry.TRAY_PAGE_SIZE) * PcStorageGeometry.TRAY_PAGE_SIZE
    self._trayBox = page + node.index
    if self._boxTray == "box" then
      self._boxTrayChangeBox = self._trayBox ~= self._activeBox
    end
    self._infoVisible = false
  elseif kind == "menu" then
    if self._menu ~= nil then
      self._menu.selected = node.index + 1
    end
    self._infoVisible = true
  elseif kind == "mark" then
    local editor = self._editor
    if editor ~= nil then
      editor.selected = node.index
      editor.focus = "marks"
    end
    self._infoVisible = false
  elseif kind == "wallpaper" then
    local editor = self._editor
    if editor ~= nil then
      local pageStart = editor.selected - editor.selected % PcStorageGeometry.WALLPAPER_PAGE_SIZE
      editor.selected = pageStart + node.index
      editor.focus = "slots"
    end
    self._infoVisible = false
  elseif kind == "confirm" or kind == "cancel" then
    local editor = self._editor
    if editor ~= nil then
      editor.focus = kind
    end
    self._infoVisible = false
  else
    self._infoVisible = false
  end
end

-- Moves the cursor to a node of the current layout.
---@param node integer
function StorageScreenState:_placeCursor(node)
  self._grid:setNode(node)
  self:_applyCursorFocus()
end

-- Restores the browse layout at the selected custody cell.
function StorageScreenState:_restoreBrowseGrid()
  local layout = self:_browseLayout()
  -- The layout decides the node id: a party cell is `30 + slot` in the tray
  -- layout and `slot` in the browse layouts, so switch first, then resolve.
  self._grid:setLayout(layout, 0)
  self._grid:setNode(self:_nodeForSlot(self._focus.domain, self._focus.slot) or 0)
  self:_applyCursorFocus()
end

-- The cursor pose and position the source draws: the tracked node anchor
-- while idle, the quarter-step slide while moving, and the carrying hand
-- whenever a mon is held.
---@return { x: integer, y: integer, pose: string }
function StorageScreenState:_cursorView()
  local node = self._grid:current()
  local pose = self._carry ~= nil and "carry" or self._grid:pose()
  return { x = node.x, y = node.y, pose = pose, layout = self._grid:layoutName(), node = self._grid:index() }
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

-- Nil-guarded retail cue player: the composed audio boundary may be absent
-- or carry a nil play function, and silent presentation paths must never
-- fail on a missing cue.
---@param sequenceName string
function StorageScreenState:_cue(sequenceName)
  local audio = self._audio
  if audio ~= nil and audio.play ~= nil then
    audio.play(sequenceName)
  end
end

-- First empty slot of one box, or nil when the box is full.
---@param box integer
---@return integer?
function StorageScreenState:_firstEmptySlot(box)
  for slot = 0, 29 do
    if self._mons:boxMon(box, slot) == nil then
      return slot
    end
  end
  return nil
end

-- First empty deposit target scanning forward from the active box, wrapping
-- across every box (retail lets the depositor pick any box). Nil only when
-- every box is full.
---@return table<string, unknown>?
function StorageScreenState:_firstEmptyDepositTarget()
  local count = self._mons:boxCount()
  for step = 0, count - 1 do
    local box = (self._activeBox + step) % count
    local slot = self:_firstEmptySlot(box)
    if slot ~= nil then
      return { kind = "box", box = box, slot = slot }
    end
  end
  return nil
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
  if self._boxTray ~= "closed" then
    self._boxTray = "closed"
    self._boxTrayChangeBox = false
  end
  local address = self:_address(self._focus)
  local mon = self:_occupant(address)
  if self._mode == 3 then
    if mon == nil then
      self._menu = nil
      return
    end
    -- PCBox_SelectItemModeBoxMon: the item list has one row, BAG when the mon
    -- already holds something and GIVE when the player can hand one over.
    self:_cue("SEQ_SE_DP_BOX02")
    local holding = mon.heldItem ~= "NONE"
    self._menu = { actions = { holding and "bagItem" or "giveItem" }, selected = 1, address = address }
    if holding then
      -- The item remains selected for the BAG action until a new touch starts
      -- a stylus drag from its own source mon.
      self._carry = { kind = "items", action = "swapItems", source = address, mon = self:_monVisual(address) }
    end
    self:_syncGridAvailability()
    self:_placeCursor(assert(self:_firstMenuNode(), "the item list carries its source row node"))
    return
  end
  local actions = self:_actionsFor(address, mon)
  if actions == nil then
    self._menu = nil
    return
  end
  self:_cue("SEQ_SE_DP_BOX02")
  -- Opening the list only selects the mon; the picked-up hand comes from the
  -- list's MOVE row (PCBox_SelectMoveModeBoxMon keeps the icon in place).
  self._menu = { actions = actions, selected = 1, address = address }
  self:_syncGridAvailability()
  -- The source slides the cursor onto the first action row as the list opens.
  self:_placeCursor(assert(self:_firstMenuNode(), "the open list carries source row nodes"))
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
      mon = self:_monVisual(source),
      scanned = 0,
      total = self._mons:boxCount() * 30 + 6,
      shrink = 0,
      phase = nil,
      scanOutcome = nil,
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
    if self._releaseCheck.outcome == "cancelled" then
      self:_cue("SEQ_SE_DP_BOX03")
    end
  end
end

---@param action string
---@param data table<string, unknown>?
---@param address table<string, unknown>? the acted-on address when no list is open
function StorageScreenState:_beginAction(action, data, address)
  local source = address or (self._menu and self._menu.address)
  -- Terminal refusals return to the list they came from
  -- (PCBox_State_ReturnToActionMenu), so remember it before clearing.
  local previousMenu = self._menu
  if action == "move" and self._carry ~= nil and self._carry.action == "move" then
    return
  end
  if self._carry ~= nil and self._carry.action == "move" and self._carry.holding ~= true and self._mode == 2 then
    -- Another list entry puts a merely selected mon back first; a held mon
    -- stays on the hand for the summary (summaryFromHolding).
    self._carry = nil
  end
  -- Children remember the list they came from: the source returns to the mode
  -- list after a summary, a held-item pick or a naming screen.
  if action == "summary" or action == "boxName" or action == "heldItems" or action == "giveItem" then
    self._returnView = {
      menu = copy(self._menu),
      carry = copy(self._carry),
      boxTray = self._boxTray,
      trayBox = self._trayBox,
      changeBox = self._boxTrayChangeBox,
      layout = self._grid:layoutName(),
      node = self._grid:index(),
      focus = copy(self._focus),
    }
  end
  self._menu = nil
  if action == "wallpaper" or action == "boxName" then
    source = source or self:_address(self._focus)
  else
    assert(source ~= nil, "Storage actions start at a selected address")
  end
  if action == "deposit" then
    -- Retail TryDeposit runs the custody checks first, then opens the
    -- target-box selector: probe with the first empty slot so refusals
    -- surface before any carry is armed, and deposit at confirm time into
    -- the chosen box's first empty slot (never a focused occupied slot).
    local target = self:_firstEmptyDepositTarget()
    local probe
    if target ~= nil then
      probe = self:_preview({ kind = "deposit", source = source, destination = target })
    else
      -- Every box is full: the swap preview still runs the same
      -- party-custody checks without needing an empty destination.
      probe = self:_preview({
        kind = "swap",
        source = source,
        destination = { kind = "box", box = self._activeBox, slot = 0 },
      })
    end
    if probe.kind == "refused" then
      self._lastAction = probe
      self._menu = previousMenu
      self:_cue("SEQ_SE_DP_BOX03")
      return
    end
    self._focus = { domain = "box", slot = self._focus.slot }
    self._carry = {
      kind = "mon",
      action = action,
      source = source,
      mon = self:_monVisual(source),
    }
    self:_syncCarryGrid()
    self:_openDepositSelector()
    return
  elseif action == "withdraw" then
    -- PCBox_TryWithdraw refuses a full party before the panel slides in.
    local intent = self:_preview({
      kind = "withdraw",
      source = source,
      destination = { kind = "party", slot = self._mons:partyCount() },
    })
    if intent.kind == "refused" then
      self._lastAction = intent
      self._menu = previousMenu
      self:_cue("SEQ_SE_DP_BOX03")
      return
    end
    -- The source slides the party panel in on the right while the mon travels
    -- into the party's last slot.
    self._tray = "right"
    self._carry = {
      kind = "mon",
      action = action,
      source = source,
      mon = self:_monVisual(source),
      destination = { kind = "party", slot = self._mons:partyCount() },
    }
  elseif action == "move" then
    -- PCBox_State_ChooseMoveFromBox: the MOVE row slides the box tray open and
    -- puts the mon on the hand, so the next confirm drops it on a box slot, a
    -- party slot, or another box's thumbnail.
    self._carry = {
      kind = "mon",
      action = action,
      source = source,
      mon = self:_monVisual(source),
      holding = true,
    }
    self._boxTray = "box"
    self._tray = "right"
    self._trayBox = self._activeBox
    self._boxTrayChangeBox = false
    self._grid:setLayout("tray", 0)
    self._grid:setNode(self:_nodeForSlot(source.kind, source.slot) or 0)
    self:_syncGridAvailability()
    self:_applyCursorFocus()
  elseif action == "swapItems" then
    self._carry = { kind = "items", action = action, source = source, mon = self:_monVisual(source) }
  elseif action == "giveItem" then
    self:_openChild("heldItemPicker", { source = source })
  elseif action == "takeItem" then
    -- PCBox_TakeHeldItemToBag and its BAG half share the domain transfer; the
    -- result line differs ("Took the ..." vs "Placed ... in the Bag.").
    local resultAction = data and data.resultAction or "takeItem"
    local mon = self:_occupant(source)
    local itemKey = data and data.item or (mon ~= nil and mon.heldItem or nil)
    local intent = self:_preview({ kind = action, source = source, item = data and data.item })
    if intent.kind == "allowed" then
      local result = self._actions:commit(intent)
      self._lastAction = result
      self:_recordItemResult(resultAction, itemKey, result)
    else
      self._lastAction = intent
      if intent.kind == "confirm" then
        self._pendingIntent = intent
        self._pendingResultAction = resultAction
        self._pendingResultItem = itemKey
      end
    end
    if self._lastAction.kind == "refused" then
      self:_cue("SEQ_SE_DP_BOX03")
    end
  elseif action == "bagItem" then
    -- PCBox_HandleBagGiveCommand's BAG half: put the held item away.
    local carried = self._carry
    local target = carried ~= nil and carried.source or source
    self._carry = nil
    self:_beginAction("takeItem", { resultAction = "bagItem" }, target)
  elseif action == "heldItems" then
    -- One entry that branches on the held item (ov14_021F5EE4 handlers).
    local mon = self:_occupant(source)
    if mon ~= nil and mon.isEgg == true then
      self._lastAction = { kind = "refused", reason = "egg", action = "heldItems" }
      self._menu = previousMenu
      self:_cue("SEQ_SE_DP_BOX03")
    elseif mon ~= nil and mon.heldItem == "NONE" then
      self:_openChild("heldItemPicker", { source = source })
    else
      self:_beginAction("takeItem", nil, source)
    end
  elseif action == "release" then
    self:_startRelease(source)
    if self._releaseCheck ~= nil and self._releaseCheck.outcome ~= "confirm" then
      self._menu = previousMenu
    end
  elseif action == "markings" then
    local mon = assert(self:_monVisual(source), "markings edit an occupied address")
    self._editor = { kind = "markings", source = source, mask = mon.markings, selected = 0, focus = "marks" }
    self._grid:setLayout("marking", 0)
    self:_applyCursorFocus()
  elseif action == "wallpaper" then
    local box = self._boxTray == "box" and self._trayBox or self._activeBox
    self._boxTray = "closed"
    self._boxTrayChangeBox = false
    local wallpaperId = self._mons:boxMetadata(box).wallpaperId
    local selected = wallpaperId >= 32 and wallpaperId - 16 or wallpaperId
    self._editor = { kind = "wallpaper", box = box, selected = selected, current = selected, focus = "slots" }
    self._grid:setLayout("wallpaper", selected % PcStorageGeometry.WALLPAPER_PAGE_SIZE)
    self._grid:setRowCursor(selected % PcStorageGeometry.WALLPAPER_PAGE_SIZE)
    self:_applyCursorFocus()
  elseif action == "summary" or action == "boxName" then
    self:_openChild(action, { source = source, box = self._activeBox })
  else
    error("unknown Storage action " .. tostring(action), 0)
  end
  self:_syncCarryGrid()
end

-- Keeps the cursor on the held mon's cell after a pick-up.
function StorageScreenState:_syncCarryGrid()
  local carry = self._carry
  if carry == nil or carry.source == nil then
    return
  end
  local node = self:_nodeForSlot(carry.source.kind, carry.source.slot)
  if node ~= nil then
    self:_placeCursor(node)
  end
end

function StorageScreenState:_updateEditor(events)
  local editor = assert(self._editor)
  local function close()
    self._editor = nil
    self:_restoreBrowseGrid()
  end
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
      if editor.kind == "wallpaper" and editor.box ~= self._activeBox then
        self._activeBox = editor.box
        self._actions:commit(self:_preview({ kind = "activeBox", box = editor.box }))
      end
      close()
      return true
    end
    return false
  end
  local function toggleMarking(bit)
    local power = 2 ^ bit
    local selected = math.floor(editor.mask / power) % 2 == 1
    editor.mask = selected and editor.mask - power or editor.mask + power
    self:_cue("SEQ_SE_DP_DECIDE")
  end
  local function placeEditorNode(node)
    self._grid:setNode(node)
    self:_applyCursorFocus()
  end
  for _, event in ipairs(events) do
    if event.type == "cancel" then
      close()
      return
    elseif event.type == "pointer_cancel" then
      -- Pointer capture cancellation does not change the local draft.
    elseif event.type == "navigate" then
      local moved = self._grid:move(assert(event.direction))
      if moved ~= nil then
        self:_cue("SEQ_SE_DP_SELECT")
        self:_applyCursorFocus()
      end
    elseif event.type == "confirm" then
      local kind = self._grid:kind()
      if editor.kind == "markings" then
        if kind == "mark" then
          toggleMarking(editor.selected)
        elseif kind == "confirm" then
          if submit() then
            return
          end
        else
          close()
          return
        end
      else
        if kind == "wallpaper" or kind == "confirm" then
          if submit() then
            return
          end
        else
          close()
          return
        end
      end
    elseif event.type == "submit" then
      if submit() then
        return
      end
    elseif editor.kind == "markings" and event.type == "marking_choice" then
      local choice = event.id
      if type(choice) == "number" and choice % 1 == 0 and choice >= 0 and choice < 6 then
        placeEditorNode(choice)
        toggleMarking(choice)
      end
    elseif editor.kind == "wallpaper" and event.type == "wallpaper_choice" then
      local choice = event.id
      if type(choice) == "number" and choice % 1 == 0 and choice >= 0 and choice < 24 then
        editor.selected = choice
        local column = choice % PcStorageGeometry.WALLPAPER_PAGE_SIZE
        placeEditorNode(column)
        self._grid:setRowCursor(math.floor(column))
      end
    elseif editor.kind == "wallpaper" and event.type == "wallpaper_page" then
      -- The arrows scroll a whole page of four, wrapping across the 24 entries.
      if event.delta == 1 or event.delta == -1 then
        editor.selected = (editor.selected + 4 * event.delta) % 24
        local column = editor.selected % PcStorageGeometry.WALLPAPER_PAGE_SIZE
        placeEditorNode(column)
        self._grid:setRowCursor(column)
      end
    else
      assert(
        event.type == "marking_choice" or event.type == "wallpaper_choice" or event.type == "wallpaper_page",
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

-- Restores the list, tray and carried mon a child was opened from, so a
-- summary or naming screen returns to the same row (PCBox_State_ReturnFrom
-- Summary / _ReturnFromNamingScreen).
function StorageScreenState:_restoreReturnView()
  local saved = self._returnView
  self._returnView = nil
  if saved == nil then
    return false
  end
  self._menu = saved.menu
  self._carry = saved.carry
  self._boxTray = saved.boxTray
  self._trayBox = saved.trayBox
  self._boxTrayChangeBox = saved.changeBox
  self._focus = saved.focus
  self._grid:setLayout(saved.layout, saved.node)
  self:_syncGridAvailability()
  self:_applyCursorFocus()
  return true
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
        local result = self._actions:commit(decision)
        self._lastAction = result
        self:_recordItemResult("giveItem", intent.item, result)
      elseif decision.kind == "confirm" then
        self._pendingIntent = decision
        self._pendingResultAction = "giveItem"
        self._pendingResultItem = intent.item
        self._lastAction = decision
      else
        self._lastAction = decision
        self:_cue("SEQ_SE_DP_BOX03")
      end
      self:_disposeChild()
      self:_restoreReturnView()
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
    if not self:_restoreReturnView() then
      self:_restoreBrowseGrid()
    end
  end
end

function StorageScreenState:_confirmCarry()
  local carry = assert(self._carry)
  if self._boxTray == "deposit" then
    self:_confirmDepositSelection()
    return
  end
  if carry.holding == true then
    local destination = self:_heldDestination()
    if destination == false then
      self:_refuseHeldDestination()
      return
    end
    if destination == nil then
      self._carry, self._menu = nil, nil
      self._boxTray, self._boxTrayChangeBox = "closed", false
      self:_cue("SEQ_SE_DP_SELECT")
      self:_restoreBrowseGrid()
      return
    end
    self:_finishCarry(destination)
    return
  end
  if carry.action == "deposit" then
    -- The selector commits into the chosen box's first empty slot; a full
    -- box reports bank-25 msg 13 and keeps the selector open.
    local slot = self:_firstEmptySlot(self._activeBox)
    if slot == nil then
      self._lastAction = { kind = "refused", reason = "box_full", action = "deposit" }
      self:_cue("SEQ_SE_DP_BOX03")
      return
    end
    local deposit = { kind = "box", box = self._activeBox, slot = slot }
    local intent = self:_preview({ kind = "deposit", source = carry.source, destination = deposit })
    self._lastAction = self._actions:commit(intent)
    if self._lastAction.kind == "changed" or self._lastAction.kind == "unchanged" then
      self._focus, self._carry, self._menu = { domain = "box", slot = slot }, nil, nil
      self:_cue("SEQ_SE_DP_BOX01")
      self:_restoreBrowseGrid()
    elseif self._lastAction.kind == "refused" then
      self:_cue("SEQ_SE_DP_BOX03")
    end
    return
  end
  self:_finishCarry(carry.destination or self:_address(self._focus))
end

-- Resolves the hand's grid node into the custody destination the drop names:
-- a box slot in the active box, a party slot (the party end when the cursor
-- sits past it), or another box's first empty slot from the tray row.
-- Returns false when the named box is full, nil when the node is not a drop.
---@return table<string, unknown>|false|nil
function StorageScreenState:_heldDestination()
  local node = self._grid:current()
  if node.kind == "box" then
    return { kind = "box", box = self._activeBox, slot = node.index }
  elseif node.kind == "party" then
    local count = self._mons:partyCount()
    return { kind = "party", slot = math.min(node.index, count) }
  elseif node.kind == "box_tray" then
    local page = math.floor(self._trayBox / PcStorageGeometry.TRAY_PAGE_SIZE) * PcStorageGeometry.TRAY_PAGE_SIZE
    local box = page + node.index
    if box == self._activeBox then
      return false
    end
    local slot = self:_firstEmptySlot(box)
    if slot == nil then
      return false
    end
    return { kind = "box", box = box, slot = slot }
  end
  return nil
end

function StorageScreenState:_refuseHeldDestination()
  local carry = assert(self._carry)
  local node = self._grid:current()
  local page = math.floor(self._trayBox / PcStorageGeometry.TRAY_PAGE_SIZE) * PcStorageGeometry.TRAY_PAGE_SIZE
  local activeThumbnail = node.kind == "box_tray" and page + node.index == self._activeBox
  self._lastAction = {
    kind = "refused",
    reason = activeThumbnail and "active_box" or "box_full",
    action = carry.action,
  }
  self:_cue("SEQ_SE_DP_BOX03")
end

-- Commits one carry onto its destination and closes the hand/tray on success.
---@param destination table<string, unknown>
function StorageScreenState:_finishCarry(destination)
  local carry = assert(self._carry)
  if
    destination.kind == carry.source.kind and destination.kind == "party" and destination.slot == carry.source.slot
    or destination.kind == "box"
      and carry.source.kind == "box"
      and destination.box == carry.source.box
      and destination.slot == carry.source.slot
  then
    self._carry, self._menu = nil, nil
    self._boxTray, self._boxTrayChangeBox = "closed", false
    self._tray = carry.source.kind == "party" and "left" or "closed"
    self:_restoreBrowseGrid()
    return
  end
  if carry.kind == "items" then
    local intent = self:_preview({ kind = "swapItems", source = carry.source, destination = destination })
    self._lastAction = self._actions:commit(intent)
    self._carry, self._menu = nil, nil
    if self._lastAction.kind == "changed" or self._lastAction.kind == "unchanged" then
      self._focus = { domain = destination.kind, slot = destination.slot }
      self:_cue("SEQ_SE_DP_BOX01")
      self:_restoreBrowseGrid()
    elseif self._lastAction.kind == "refused" then
      self:_cue("SEQ_SE_DP_BOX03")
    end
    return
  end
  local occupied = destination.kind == "box" and self._mons:boxMon(destination.box, destination.slot) ~= nil
    or destination.kind == "party" and destination.slot < self._mons:partyCount()
  local kind = carry.action == "deposit" and "deposit"
    or carry.action == "withdraw" and "withdraw"
    or occupied and "swap"
    or "move"
  local displaced = destination.kind == "party" and occupied and self:_monVisual(destination) or nil
  local intent = self:_preview({ kind = kind, source = carry.source, destination = destination })
  self._lastAction = self._actions:commit(intent)
  if self._lastAction.kind == "changed" or self._lastAction.kind == "unchanged" then
    if destination.kind == "party" and carry.source.kind == "box" then
      self._transferGeneration = self._transferGeneration + 1
      self._transferSide = "right"
      self._transfer = {
        moves = {
          {
            fromDomain = "box",
            from = carry.source.slot,
            toDomain = "party",
            to = destination.slot,
            mon = copy(carry.mon),
          },
        },
      }
      if displaced ~= nil then
        self._transfer.moves[#self._transfer.moves + 1] = {
          fromDomain = "party",
          from = destination.slot,
          toDomain = "box",
          to = carry.source.slot,
          mon = copy(displaced),
        }
      end
    end
    self._tray = carry.source.kind == "party" and "left" or "closed"
    self._boxTray, self._boxTrayChangeBox = "closed", false
    self._focus, self._carry, self._menu = { domain = destination.kind, slot = destination.slot }, nil, nil
    self:_cue("SEQ_SE_DP_BOX01")
    self:_restoreBrowseGrid()
  elseif self._lastAction.kind == "refused" then
    self:_cue("SEQ_SE_DP_BOX03")
  end
end

function StorageScreenState:_resolve()
  assert(not self._disposed, "disposed Storage has no plan")
  self:_refreshContents()
  local view = self:_buildView()
  local measurement = self._measureDisplay()
  self._session:resolve(measurement, view)
  -- The fallback session tracks the same classification history from the
  -- start so a later resize reflows the admitted view to the same case
  -- the live session would select. Nothing is admitted until the host
  -- says ready, so the plan is synchronized here but never stored.
  assert(self._admittedLayoutSession):resolve(measurement, view)
  self._publishedView = view
  self._publishedKey = self:_publishKey(measurement)
  self._publishedMeasurementSignature = measurement.signature
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
    self._grid:layoutName(),
    tostring(self._grid:index()),
    tostring(self._boxTray),
    tostring(self._trayBox),
    tostring(self._boxTrayChangeBox),
    encodeFact(self._carry),
    encodeFact(self._drag),
    encodeFact(self._menu),
    encodeFact(self._editor),
    encodeFact(self._releaseCheck),
    tostring(self._hint),
    tostring(self._promptChoice and self._promptChoice.choice),
    encodeFact(self._prompt),
    encodeFact(self._notice),
    tostring(self._tray),
    tostring(self._transferSide),
    tostring(self._transferGeneration),
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
  -- A changed display signature reflows only the retained parent: the
  -- live session keeps its current view for input while the fallback
  -- session resolves the admitted view under the same measurement. The
  -- new parent plan and its signature publish together only after the
  -- fallback resolve returns a valid plan, so a rejected measurement
  -- keeps the last valid pair and retries on the next refresh.
  if measurement.signature ~= self._publishedMeasurementSignature then
    local fallbackView = self._admittedParentView or view
    local fallbackPlan = assert(self._admittedLayoutSession):resolve(measurement, fallbackView)
    if self._admittedParentView ~= nil then
      self._admittedParentPlan = fallbackPlan
      self._admittedParentSignature = measurement.signature
    end
  end
  self._publishedView = view
  self._publishedKey = key
  self._publishedMeasurementSignature = measurement.signature
  return view
end

-- Slides the party tray out (modes 2 and 3 only: Deposit keeps it open).
function StorageScreenState:_closeTray()
  if self._boxTray ~= "closed" then
    self:_closeBoxTray()
  end
  if self._mode >= 2 and self._tray ~= "closed" then
    self._tray = "closed"
    if self._focus.domain == "party" then
      self._focus = { domain = "box", slot = 0 }
    end
    self:_restoreBrowseGrid()
  end
end

-- Steps the active box from the title plate, matching the source left/right
-- shortcut that keeps the cursor on the title.
---@param delta integer
function StorageScreenState:_switchBox(delta)
  local count = self._mons:boxCount()
  self._activeBox = (self._activeBox + delta) % count
  self._focus = { domain = "box", slot = 0 }
  self._actions:commit(self:_preview({ kind = "activeBox", box = self._activeBox }))
  if self._grid:layoutName() ~= "deposit" then
    self._grid:setNode(30)
  end
  self._infoVisible = false
end

-- Opens the Move/Item box tray at the active box page. The source starts the
-- cursor on the box slot the player came from; the tray plate shows the
-- selected column.
function StorageScreenState:_openBoxTray()
  if self._mode < 2 or self._boxTray ~= "closed" then
    return
  end
  self._boxTray = "box"
  self._tray = "right"
  self._trayBox = self._activeBox
  self._boxTrayChangeBox = false
  local carry = self._carry
  self._grid:setLayout("tray", 0)
  local node = 37 + self._trayBox % PcStorageGeometry.TRAY_PAGE_SIZE
  if carry ~= nil and carry.holding == true and carry.source ~= nil then
    -- The party panel's SWITCH keeps the held mon on the hand and starts the
    -- tray cursor on its own cell, so the next confirm drops it in a box.
    node = self:_nodeForSlot(carry.source.kind, carry.source.slot) or node
  end
  self._grid:setNode(node)
  self:_syncGridAvailability()
  self:_applyCursorFocus()
end

function StorageScreenState:_closeBoxTray()
  if self._boxTray == "closed" then
    return
  end
  local carry = self._carry
  self._boxTray = "closed"
  self._boxTrayChangeBox = false
  self._carry = nil
  self._tray = carry ~= nil and carry.source.kind == "party" and "left" or "closed"
  self:_restoreBrowseGrid()
end

-- Stages a deposit: the party mon stays in carry while the selector chooses
-- the destination box; the active box only changes when the deposit commits.
function StorageScreenState:_openDepositSelector()
  self._boxTray = "deposit"
  self._trayBox = self._activeBox
  self._boxTrayChangeBox = false
  self._grid:setLayout("depositBox", self._trayBox % PcStorageGeometry.TRAY_PAGE_SIZE)
  self:_syncGridAvailability()
  self:_applyCursorFocus()
end

-- Cancelling the deposit selector returns to the deposit list on the same
-- party mon (PCBox_State_DepositBoxSelectClosed -> RETURN_TO_ACTION_MENU).
function StorageScreenState:_closeDepositSelector()
  local source = assert(self._carry, "deposit selector retains its source").source
  self._boxTray = "closed"
  self._boxTrayChangeBox = false
  self._carry = nil
  self._focus = { domain = "party", slot = source.slot }
  self._menu = {
    actions = { "deposit", "summary", "markings", "release" },
    selected = 1,
    address = copy(source),
  }
  local layout = self:_browseLayout()
  local node = self:_nodeForSlot("party", source.slot) or 0
  self._grid:setLayout(layout, node)
  self:_syncGridAvailability()
  self:_placeCursor(assert(self:_firstMenuNode(), "the deposit list carries source row nodes"))
end

-- Moves the active box to the staged tray box (the Change Box plate).
function StorageScreenState:_switchToTrayBox()
  if self._trayBox == self._activeBox then
    return
  end
  self._activeBox = self._trayBox
  self._focus = { domain = "box", slot = 0 }
  self._infoVisible = false
  self._boxTrayChangeBox = false
  self._actions:commit(self:_preview({ kind = "activeBox", box = self._activeBox }))
  self:_syncGridAvailability()
end

-- Pages the tray by whole six-box pages, keeping the selected column.
---@param delta integer
function StorageScreenState:_changeTrayPage(delta)
  local count = self._mons:boxCount()
  local column = self._trayBox % PcStorageGeometry.TRAY_PAGE_SIZE
  self._trayBox = (self._trayBox + delta * PcStorageGeometry.TRAY_PAGE_SIZE) % count
  self._trayBox = self._trayBox - self._trayBox % PcStorageGeometry.TRAY_PAGE_SIZE + column
  self._boxTrayChangeBox = self._boxTray == "box" and self._trayBox ~= self._activeBox
  local layout = self._grid:layoutName()
  if layout == "depositBox" or layout == "boxMenu" then
    self._grid:setNode(column)
  else
    self._grid:setNode(37 + column)
  end
  self:_applyCursorFocus()
end

-- Confirms the staged deposit box into its first empty slot.
function StorageScreenState:_confirmDepositSelection()
  local carry = self._carry
  if carry == nil or carry.action ~= "deposit" then
    self:_closeDepositSelector()
    return
  end
  local box = self._trayBox
  local slot = self:_firstEmptySlot(box)
  if slot == nil then
    self._lastAction = { kind = "refused", reason = "box_full", action = "deposit" }
    self:_cue("SEQ_SE_DP_BOX03")
    return
  end
  local destination = { kind = "box", box = box, slot = slot }
  local intent = self:_preview({ kind = "deposit", source = carry.source, destination = destination })
  self._lastAction = self._actions:commit(intent)
  if self._lastAction.kind == "changed" or self._lastAction.kind == "unchanged" then
    self._activeBox = box
    self._actions:commit(self:_preview({ kind = "activeBox", box = box }))
    self._focus, self._carry, self._menu = { domain = "box", slot = slot }, nil, nil
    self._boxTray = "closed"
    self._boxTrayChangeBox = false
    self:_cue("SEQ_SE_DP_BOX01")
    self:_restoreBrowseGrid()
  elseif self._lastAction.kind == "refused" then
    self:_cue("SEQ_SE_DP_BOX03")
  end
end

-- Opens the title plate's Wallpaper / Name pair on the box-menu layout.
function StorageScreenState:_openTitleMenu()
  if self._carry ~= nil then
    return
  end
  self._menu = { actions = { "wallpaper", "boxName" }, selected = 1 }
  self._boxTray = "box"
  self._trayBox = self._activeBox
  self._boxTrayChangeBox = false
  self._grid:setLayout("boxMenu", self._activeBox % PcStorageGeometry.TRAY_PAGE_SIZE)
  self._grid:setRowCursor(self._activeBox % PcStorageGeometry.TRAY_PAGE_SIZE)
  self:_syncGridAvailability()
  self:_applyCursorFocus()
end

-- Enables only the controls the current layout actually renders. Closed
-- action lists keep their row nodes inert, so the source cursor bounces back
-- instead of sliding onto an undrawn row.
function StorageScreenState:_syncGridAvailability()
  local layout = self._grid:layoutName()
  local menuOpen = self._menu ~= nil
  local function setRange(first, last, enabled)
    for index = first, last do
      self._grid:setEnabled(index, enabled)
    end
  end
  if layout == "boxMenu" then
    return
  elseif layout == "tray" then
    self._grid:setEnabled(45, self._boxTrayChangeBox)
    local holding = self._carry ~= nil and self._carry.holding == true and self._boxTray == "box"
    self._grid:setEnabled(43, not holding)
    self._grid:setEnabled(44, not holding)
  elseif layout == "deposit" then
    setRange(7, 11, menuOpen)
  elseif layout == "withdraw" then
    setRange(34, 38, menuOpen)
  elseif layout == "move" then
    setRange(36, 41, menuOpen)
  elseif layout == "moveParty" then
    setRange(8, 13, menuOpen)
  elseif layout == "item" then
    setRange(36, 37, menuOpen)
  elseif layout == "itemParty" then
    setRange(8, 9, menuOpen)
  end
end

-- Moves the source cursor one direction through the active grid.
---@param direction "up"|"down"|"left"|"right"
function StorageScreenState:_navigate(direction)
  local node = self._grid:current()
  if node.kind == "title" and (direction == "left" or direction == "right") then
    self:_cue("SEQ_SE_DP_SELECT")
    self:_switchBox(direction == "left" and -1 or 1)
    return
  end
  self:_syncGridAvailability()
  local before = self._grid:index()
  local moved = self._grid:move(direction)
  if moved == nil then
    return
  end
  self:_cue("SEQ_SE_DP_SELECT")
  if self._grid:layoutName() == "depositBox" and (direction == "left" or direction == "right") then
    -- PCBox_DepositBoxGridOnKeyMove wraps box-by-box across all boxes, not
    -- inside the visible six-box page: leaving the first column steps back a
    -- box and leaving the last column steps forward.
    local count = self._mons:boxCount()
    if before == 5 and moved == 0 then
      self._trayBox = (self._trayBox + 1) % count
    elseif before == 0 and moved == 5 then
      self._trayBox = (self._trayBox - 1) % count
    end
  end
  self:_applyCursorFocus()
end

-- Whether one box holds any mon (the move-party hint's second condition).
---@param box integer
---@return boolean
function StorageScreenState:_boxHasMon(box)
  for slot = 0, 29 do
    if self._mons:boxMon(box, slot) ~= nil then
      return true
    end
  end
  return false
end

-- The W40 hint the source prints while a party-side drag is held
-- (PCBox_PrintPanelHint kinds 0..3 and 6..10).
---@param drag table<string, unknown>
---@return integer?
function StorageScreenState:_dragHint(drag)
  local mon = drag.mon
  if drag.kind == "items" then
    return self._actions.hasMail(mon) and 59 or 60
  end
  if drag.action == "withdraw" then
    return self._mons:partyCount() == 6 and 39 or 37
  end
  if drag.source.kind ~= "party" then
    return nil
  end
  local lastUsable = self._actions:lastUsableAfterRemoving(drag.source)
  if drag.action == "deposit" then
    if not lastUsable then
      return 58
    end
  elseif not lastUsable and not self:_boxHasMon(self._activeBox) then
    return 58
  end
  if self._actions.hasMail(mon) then
    return 56
  end
  if self._actions.hasCapsule(mon) then
    return 57
  end
  if drag.action == "deposit" and self:_firstEmptySlot(self._activeBox) == nil then
    return 38
  end
  return 36
end

-- Opens one stylus drag from an occupied custody cell. The source picks the
-- mon up immediately (no threshold): the icon follows the stylus, the hand
-- cursor hides, and the action list slides out until the drop.
---@param target table<string, unknown>
---@param pointerId unknown
---@param x number
---@param y number
---@return boolean started
function StorageScreenState:_startDrag(target, pointerId, x, y)
  if self._prompt ~= nil or self._child ~= nil or self._editor ~= nil then
    return false
  end
  local address = self:_address(target)
  local mon = self:_occupant(address)
  if mon == nil then
    return false
  end
  local kind, action = "mon", nil
  if self._mode == 0 then
    if address.kind ~= "party" then
      return false
    end
    action = "deposit"
  elseif self._mode == 1 then
    if address.kind ~= "box" then
      return false
    end
    action = "withdraw"
  elseif self._mode == 2 then
    action = "move"
  else
    -- PCBox_StartItemModeBoxDrag: a mon without a held item opens GIVE/BAG
    -- instead; a held item is lifted onto the stylus.
    if mon.heldItem == "NONE" then
      return false
    end
    kind, action = "items", "swapItems"
  end
  local monVisual = self:_monVisual(address)
  self._focus = { domain = address.kind, slot = address.slot }
  if address.kind == "box" then
    self._activeBox = address.box or self._activeBox
  end
  self._infoVisible = true
  self._menu = nil
  self._drag = {
    pointerId = pointerId,
    kind = kind,
    action = action,
    source = address,
    mon = monVisual,
    x = x or 0,
    y = y or 0,
    -- The panel the stylus carries along: party sources keep their panel
    -- visible until the stylus leaves it; a withdraw drag raises the right
    -- panel once the stylus leaves the source cell.
    panelSide = address.kind == "party" and (self._tray ~= "closed" and self._tray or "left") or "right",
    trayBefore = self._tray,
    boxTrayBefore = self._boxTray,
  }
  self._carry = { kind = kind, action = action, source = copy(address), mon = monVisual }
  self._hint = self:_dragHint(self._drag)
  return true
end

-- Ends the current drag, returning the browse grid to the source cell.
function StorageScreenState:_endDrag()
  self._drag = nil
  self._hint = nil
  self._carry, self._menu = nil, nil
  self._boxTray, self._boxTrayChangeBox = "closed", false
  if self._mode >= 2 and self._tray ~= "closed" then
    self._tray = "closed"
  end
end

-- Restores the source's action list after a drag that never left its cell,
-- matching the source's slide-in menu on release.
function StorageScreenState:_returnDragToSource()
  local drag = assert(self._drag)
  local source = drag.source
  local items = drag.kind == "items"
  local trayWasOpen = drag.boxTrayBefore == "box"
  self:_endDrag()
  self._focus = { domain = source.kind, slot = source.slot }
  if source.kind == "box" then
    self._activeBox = source.box or self._activeBox
  end
  if trayWasOpen and not items then
    -- A drag that began on the box tray resumes its tray input at the source
    -- cell instead of closing the tray.
    self._boxTray = "box"
    self._trayBox = self._activeBox
    self._grid:setLayout("tray", 0)
    self._grid:setNode(self:_nodeForSlot(source.kind, source.slot) or 0)
    self:_syncGridAvailability()
    self:_applyCursorFocus()
    return
  end
  self:_restoreBrowseGrid()
  if not items then
    self:_openMenu()
  end
end

-- Keeps the panel the drag carries in step with the stylus: a party source
-- lowers its panel once the stylus leaves the panel band, and a withdraw
-- drag raises the right panel once the stylus leaves the source cell.
---@param drag table<string, unknown>
function StorageScreenState:_updateDragPanel(drag)
  local x, y = drag.x, drag.y
  if drag.action == "withdraw" then
    local rect = PcStorageGeometry.boxSlotRect(drag.source.slot)
    local outside = x < rect.x - 16
      or x >= rect.x + rect.width + 16
      or y < rect.y - 16
      or y >= rect.y + rect.height + 16
    self._tray = outside and drag.panelSide or "closed"
    return
  end
  if drag.source.kind ~= "party" then
    if drag.trayBefore ~= "closed" then
      self._tray = drag.trayBefore
    end
    return
  end
  local inside = x >= 16 and x < 104 and y >= 48
  self._tray = inside and drag.panelSide or "closed"
end

-- Resolves the last held stylus point into the custody drop it names: the
-- visible party panel's drop rects, a tray thumbnail (its box's first empty
-- slot), or the box grid. Returns false when a named box is full.
---@return table<string, unknown>|false|nil
function StorageScreenState:_dragDestination()
  local drag = assert(self._drag)
  local x, y = drag.x, drag.y
  local partySlot
  if self._tray == "left" then
    partySlot = PcStorageGeometry.partyDropSlot(x, y, "left")
  elseif self._tray == "right" then
    partySlot = PcStorageGeometry.partyDropSlot(x, y, "right")
  end
  if partySlot ~= nil then
    if drag.action == "deposit" then
      return drag.source.kind == "party" and drag.source.slot == partySlot and { kind = "party", slot = partySlot }
        or nil
    end
    return { kind = "party", slot = math.min(partySlot, self._mons:partyCount()) }
  end
  if drag.action == "deposit" and self._tray ~= "closed" then
    -- The raised panel covers the box grid; release elsewhere drops back.
    return nil
  end
  if self._boxTray == "box" then
    local column = PcStorageGeometry.trayDropColumn(x, y, false)
    if column ~= nil then
      local page = math.floor(self._trayBox / PcStorageGeometry.TRAY_PAGE_SIZE) * PcStorageGeometry.TRAY_PAGE_SIZE
      local box = page + column
      if box == self._activeBox then
        return nil
      end
      if drag.kind == "items" then
        return nil
      end
      local slot = self:_firstEmptySlot(box)
      if slot == nil then
        return false
      end
      return { kind = "box", box = box, slot = slot }
    end
  end
  if drag.action == "withdraw" and self._tray == "closed" then
    -- Without the party panel the withdraw drag drops back on its cell.
    return nil
  end
  local slot = PcStorageGeometry.boxDropSlot(x, y)
  if slot == nil then
    return nil
  end
  return { kind = "box", box = self._activeBox, slot = slot }
end

-- Starts one stylus drag from an occupied custody cell, or falls back to the
-- cursor placement and item list the source shows for a mere tap.
---@param event table<string, unknown>
function StorageScreenState:_handleStorageTouch(event)
  if self:_yesNoPrompt() ~= nil then
    -- An open confirmation owns every press that is not one of its buttons.
    return
  end
  local target = copy(assert(event.target, "mapped Storage touch identifies a target"))
  local carry = self._carry
  if carry ~= nil and carry.holding == true then
    local address = self:_address(target)
    if address.kind == "box" then
      self._activeBox = address.box or self._activeBox
    end
    local node = self:_nodeForSlot(address.kind, address.slot)
    if node ~= nil then
      self._grid:setNode(node)
      self:_applyCursorFocus()
      local destination = self:_heldDestination()
      if destination ~= nil and destination ~= false then
        self:_finishCarry(destination)
      elseif destination == false then
        self:_refuseHeldDestination()
      end
    end
    return
  end
  if carry ~= nil and carry.kind == "items" and carry.holding ~= true and self._drag == nil then
    -- The BAG row is a selection, not a hand-held drop. A touch on another
    -- mon starts a fresh item-mode drag from that mon.
    self._carry, self._menu = nil, nil
    carry = nil
  end
  if self._boxTray == "deposit" or carry ~= nil then
    return
  end
  if self:_startDrag(target, event.pointerId, event.x, event.y) then
    self:_syncCarryGrid()
    return
  end
  self:_touchTarget(target)
  if self._mode == 3 and self._boxTray == "closed" then
    self:_openMenu()
  end
end

---@param event table<string, unknown>
function StorageScreenState:_handleDragMove(event)
  local drag = self._drag
  if drag == nil or (drag.pointerId ~= nil and event.pointerId ~= nil and event.pointerId ~= drag.pointerId) then
    return
  end
  drag.x, drag.y = event.x, event.y
  self:_updateDragPanel(drag)
end

---@param event table<string, unknown>
function StorageScreenState:_handleDragRelease(event)
  local drag = self._drag
  if drag == nil or (drag.pointerId ~= nil and event.pointerId ~= nil and event.pointerId ~= drag.pointerId) then
    return
  end
  drag.x, drag.y = event.x, event.y
  self:_updateDragPanel(drag)
  local destination = self:_dragDestination()
  if destination == nil or destination == false then
    if destination == false then
      self._lastAction = { kind = "refused", reason = "box_full", action = drag.action }
      self:_cue("SEQ_SE_DP_BOX03")
    end
    self:_returnDragToSource()
    return
  end
  local source = drag.source
  local same = destination.kind == source.kind
    and destination.slot == source.slot
    and (destination.kind == "party" or destination.box == source.box)
  if same or (drag.kind == "items" and self:_occupant(destination) == nil) then
    self:_returnDragToSource()
    return
  end
  self._tray = drag.trayBefore
  self._boxTray = drag.boxTrayBefore
  self:_finishCarry(destination)
  if self._carry ~= nil then
    -- Pointer capture ended; a refused drop returns custody and presentation
    -- to the source rather than leaving a ghost attached to a released pen.
    self:_returnDragToSource()
    return
  end
  self._drag = nil
  self._hint = nil
end

-- Cancels an in-flight drag without committing it (pointer capture loss).
function StorageScreenState:_cancelDrag()
  local drag = self._drag
  if drag == nil then
    return
  end
  self:_endDrag()
  self._tray = drag.trayBefore
  self._boxTray = drag.boxTrayBefore
  self._focus = { domain = drag.source.kind, slot = drag.source.slot }
  self:_restoreBrowseGrid()
end

-- Places the source cursor on a touched slot; touch never animates the slide.
---@param target table<string, unknown>
function StorageScreenState:_touchTarget(target)
  local domain = target.domain or target.kind
  local hidden = (self._mode == 0 and domain == "box" and self._carry == nil)
    or (domain == "party" and self._tray == "closed")
  if hidden then
    return
  end
  self._focus = { domain = domain, slot = target.slot }
  if target.box ~= nil then
    self._activeBox = target.box
  end
  local node = self:_nodeForSlot(domain, target.slot)
  if node ~= nil then
    self._grid:setNode(node)
  end
  self._infoVisible = true
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
  if self._boxTray == "deposit" then
    self:_closeDepositSelector()
    self:_cue("SEQ_SE_DP_SELECT")
    return
  end
  if
    self._releaseCheck ~= nil and (self._releaseCheck.outcome == "confirm" or self._releaseCheck.outcome == "pending")
  then
    self._releaseCheck.outcome = "cancelled"
    self._releaseCheck.phase = nil
    self._releaseIntent = nil
    self._releaseRevisions = nil
    self._pendingResultAction, self._pendingResultItem = nil, nil
    self:_cue("SEQ_SE_DP_SELECT")
  elseif self._pendingIntent ~= nil then
    self._pendingIntent = nil
    self:_cue("SEQ_SE_DP_SELECT")
  elseif self._carry ~= nil then
    local carry = assert(self._carry)
    local drag = self._drag
    local boxTrayWasOpen = self._boxTray ~= "closed"
    if drag ~= nil then
      self._tray = drag.trayBefore
      self._boxTray = drag.boxTrayBefore
    end
    if carry.action == "withdraw" then
      self._tray = "closed"
    end
    -- A cancelled hold puts the mon back and closes the tray it opened from.
    self._carry, self._menu = nil, nil
    if boxTrayWasOpen then
      self._boxTray, self._boxTrayChangeBox = "closed", false
      self._tray = carry.source.kind == "party" and "left" or "closed"
    end
    self._drag, self._hint = nil, nil
    self:_cue("SEQ_SE_DP_SELECT")
    self:_restoreBrowseGrid()
  elseif self._menu ~= nil then
    local titleMenu = self._menu.address == nil
    self._menu = nil
    self:_cue("SEQ_SE_DP_SELECT")
    if titleMenu then
      self._boxTray = "closed"
      self._boxTrayChangeBox = false
      self._grid:setLayout(self:_browseLayout(), 30)
      self:_applyCursorFocus()
    else
      self:_restoreBrowseGrid()
    end
  elseif self._boxTray == "box" then
    self:_closeBoxTray()
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
      self._grid:setLayout(self:_browseLayout(), 0)
      self:_applyCursorFocus()
    end
  elseif event.type == "tray_close" then
    self:_closeTray()
  elseif event.type == "storage_target" then
    self:_touchTarget(copy(assert(event.target, "mapped Storage inputs identify a target")))
  elseif event.type == "box_title" then
    self:_openTitleMenu()
  elseif event.type == "box_tab" or event.type == "box_tray_open" then
    local holding = self._carry ~= nil and self._carry.holding == true
    if (self._carry == nil and self._menu == nil) or holding then
      self:_openBoxTray()
    end
  elseif event.type == "box_tray_page" then
    if self._boxTray ~= "closed" then
      self:_cue("SEQ_SE_DP_SELECT")
      self:_changeTrayPage(event.delta == -1 and -1 or 1)
    end
  elseif event.type == "box_tray_change" then
    if self._boxTray == "box" then
      self:_cue("SEQ_SE_DP_DECIDE")
      self:_switchToTrayBox()
      self._grid:setNode(45)
      self:_applyCursorFocus()
    end
  elseif event.type == "box_tray_select" then
    if self._boxTray ~= "closed" then
      local column = assert(event.column)
      local page = math.floor(self._trayBox / PcStorageGeometry.TRAY_PAGE_SIZE) * PcStorageGeometry.TRAY_PAGE_SIZE
      self._trayBox = page + column
      self._boxTrayChangeBox = self._boxTray == "box" and self._trayBox ~= self._activeBox
      self:_syncGridAvailability()
      if self._boxTray == "deposit" then
        -- PCBox_SelectDepositBox records the touched column before moving the
        -- cursor to the OK plate, so returning restores it.
        self._grid:setRowCursor(column)
        self._grid:setNode(8)
      elseif self._grid:layoutName() == "boxMenu" then
        self._grid:setRowCursor(column)
        self._grid:setNode(8)
      elseif self._carry ~= nil and self._carry.holding == true then
        -- A held mon drops on the thumbnail under the hand.
        self._grid:setNode(37 + column)
      elseif self._boxTrayChangeBox then
        self._grid:setNode(45)
      else
        self._grid:setNode(37 + column)
      end
      self:_applyCursorFocus()
      if self._carry ~= nil and self._carry.holding == true then
        local destination = self:_heldDestination()
        if destination ~= nil and destination ~= false then
          self:_finishCarry(destination)
        elseif destination == false then
          self:_refuseHeldDestination()
        end
      end
    end
  elseif event.type == "box_tray_cancel" then
    if self._boxTray == "deposit" then
      self:_closeDepositSelector()
    else
      self:_closeBoxTray()
    end
    self:_cue("SEQ_SE_DP_SELECT")
  elseif event.type == "box_prev" or event.type == "box_next" then
    if self._carry == nil and self._menu == nil then
      self:_cue("SEQ_SE_DP_SELECT")
      self:_switchBox(event.type == "box_prev" and -1 or 1)
    end
  elseif event.type == "navigate" then
    self:_navigate(assert(event.direction))
  else
    assert(false, "unknown Storage focus event " .. tostring(event.type))
  end
end

-- Dispatches one generic confirm or action event through the domain owner.
---@param event table<string, unknown>
function StorageScreenState:_handleConfirmInput(event)
  if event.type == "confirm" then
    local menuFirst, menuLast = self:_menuNodes()
    local onMenuRow = menuFirst ~= nil and self._grid:index() >= menuFirst and self._grid:index() <= menuLast
    if self._menu ~= nil and onMenuRow then
      local menu = assert(self._menu)
      local selectedAction = assert(menu.actions[menu.selected], "Storage selection resolves to a menu action")
      self:_cue("SEQ_SE_DP_DECIDE")
      self:_beginAction(selectedAction)
    elseif self._pendingIntent ~= nil then
      ---@type table<string, unknown>
      local pending = assert(self._pendingIntent)
      local result = self._actions:commit(pending, true)
      self._lastAction = result
      local request = pending.request
      assert(type(request) == "table", "a pending item intent names its request")
      ---@cast request table<string, unknown>
      self:_recordItemResult(self._pendingResultAction or request.kind, self._pendingResultItem, result)
      self._pendingIntent = nil
      self._pendingResultAction, self._pendingResultItem = nil, nil
    elseif self._carry ~= nil then
      self:_confirmCarry()
    elseif self._menu ~= nil then
      local menu = assert(self._menu)
      local selectedAction = assert(menu.actions[menu.selected], "Storage selection resolves to a menu action")
      self:_cue("SEQ_SE_DP_DECIDE")
      self:_beginAction(selectedAction)
    else
      self:_confirmNode()
    end
  elseif event.type == "action" then
    self:_cue("SEQ_SE_DP_DECIDE")
    local action = assert(event.action)
    local carry = self._carry
    local address = self._menu == nil and self:_address(self._focus) or nil
    if action == "summary" and carry ~= nil and carry.holding == true then
      address = carry.source
    end
    self:_beginAction(action, event, address)
  else
    assert(false, "unknown Storage input event " .. tostring(event.type))
  end
end

-- Confirms the focused source control when no list is open.
function StorageScreenState:_confirmNode()
  local node = self._grid:current()
  local kind = node.kind
  if kind == "box" or kind == "party" then
    self:_openMenu()
  elseif kind == "box_tray" then
    if self._boxTray == "deposit" then
      self:_confirmDepositSelection()
    elseif self._grid:layoutName() == "boxMenu" then
      if self._trayBox == self._activeBox then
        self:_cue("SEQ_SE_DP_BOX03")
      else
        self._grid:setNode(8)
        self:_syncGridAvailability()
        self:_applyCursorFocus()
      end
    elseif self._trayBox == self._activeBox then
      self:_cue("SEQ_SE_DP_BOX03")
    else
      self._boxTrayChangeBox = true
      self:_syncGridAvailability()
      self._grid:setNode(45)
      self:_applyCursorFocus()
    end
  elseif kind == "title" then
    if self._grid:layoutName() == "boxMenu" then
      self:_switchToTrayBox()
      self._grid:setNode(8)
      self:_applyCursorFocus()
    else
      self:_openTitleMenu()
    end
  elseif kind == "return" or kind == "exit" then
    local layout = self._grid:layoutName()
    if layout == "tray" then
      if self._boxTrayChangeBox then
        self:_switchToTrayBox()
      else
        self:_closeBoxTray()
      end
    elseif layout == "moveParty" or layout == "itemParty" then
      self:_closeTray()
    else
      self._prompt = { kind = "exit" }
    end
  elseif kind == "menu" then
    local menu = assert(self._menu)
    self:_cue("SEQ_SE_DP_DECIDE")
    self:_beginAction(assert(menu.actions[menu.selected]))
  elseif kind == "menu_exit" then
    self:_handleCancelInput()
  elseif kind == "party_button" then
    if self._carry == nil then
      self:_handleFocusInput({ type = "party" })
    end
  elseif kind == "party_panel_button" then
    if self._boxTray == "box" then
      self:_closeBoxTray()
    else
      self:_openBoxTray()
    end
  elseif kind == "item_button" then
    local holding = self._carry ~= nil and self._carry.kind == "items"
    self:_cue("SEQ_SE_DP_DECIDE")
    self:_beginAction(holding and "bagItem" or "giveItem")
  elseif kind == "tray_tab" then
    if self._carry == nil and self._menu == nil then
      self:_openBoxTray()
    end
  elseif kind == "prev_box" or kind == "next_box" or kind == "page_prev" or kind == "page_next" then
    -- Source touch-only plates; the D-pad keeps the cursor on them.
    return
  elseif kind == "confirm" and self._boxTray == "deposit" then
    self:_confirmDepositSelection()
  elseif kind == "cancel" and self._boxTray == "deposit" then
    self:_closeDepositSelector()
  else
    error("unhandled Storage focus kind " .. tostring(kind), 0)
  end
end

-- Dispatches one mapped event for the Storage-owned path. Returns true when
-- the event confirms an armed release and starts its scan slice.
---@param event table<string, unknown>
---@return boolean
function StorageScreenState:_dispatchStorageEvent(event)
  event = self:_resolvePromptChoice(event)
  if event.type == "prompt_choice" then
    return false
  end
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
    or eventType == "box_tab"
    or eventType == "box_prev"
    or eventType == "box_next"
    or eventType == "box_tray_open"
    or eventType == "box_tray_page"
    or eventType == "box_tray_select"
    or eventType == "box_tray_change"
    or eventType == "box_tray_cancel"
    or eventType == "navigate"
  then
    self:_handleFocusInput(event)
    return false
  elseif eventType == "storage_touch" then
    self:_handleStorageTouch(event)
    return false
  elseif eventType == "storage_drag_move" then
    self:_handleDragMove(event)
    return false
  elseif eventType == "storage_drag_release" then
    self:_handleDragRelease(event)
    return false
  elseif eventType == "release" then
    self:_startRelease(assert(event.address))
    return false
  elseif eventType == "confirm" and self._releaseCheck ~= nil and self._releaseCheck.outcome == "confirm" then
    -- PCBox_ConfirmRelease hides the outline and starts the shrink at once;
    -- the scan runs alongside it.
    self._releaseCheck.outcome = "pending"
    self._releaseCheck.phase = "shrink"
    self._releaseCheck.shrink = 0
    return true
  elseif eventType == "cancel" then
    self:_handleCancelInput()
    return false
  elseif eventType == "pointer_cancel" then
    -- The paired session has already discarded the invalid pointer capture.
    self:_cancelDrag()
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

-- Records what the finished release-check scan learned. The scan never
-- mutates custody: the source deletes the mon only after the shrink and both
-- message acknowledgements.
---@param check table<string, unknown>
---@param result table<string, unknown>
function StorageScreenState:_settleReleaseResult(check, result)
  if result.kind == "stale" then
    check.scanOutcome = "stale"
  elseif result.reason == "hm_return" then
    check.scanOutcome = "returned"
  elseif result.kind == "changed" then
    check.scanOutcome = "removed"
  else
    check.scanOutcome = "cancelled"
  end
end

-- Advances the release animation and scan together by one fixed tick. The
-- shrink starts with the confirmation, while the scan visits fifteen
-- candidate addresses per tick; the mon stays in custody throughout.
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
    check.phase = nil
    self._releaseIntent = nil
    return
  end
  if check.scanned < check.total then
    check.scanned = math.min(check.total, check.scanned + 15)
    if check.scanned == check.total then
      -- The scan revalidates custody without mutating it: removal happens
      -- only after the shrink and both message acknowledgements.
      local intent = assert(self._releaseIntent)
      local fresh = self:_preview(intent.request)
      self:_settleReleaseResult(check, fresh.kind == "confirm" and { kind = "changed" } or fresh)
      if check.scanOutcome == "stale" then
        check.outcome = "stale"
        check.phase = nil
        self._releaseIntent = nil
        return
      end
    end
  end
  if check.phase == "shrink" then
    if check.shrink < PcStorageGeometry.RELEASE_SHRINK_TICKS then
      check.shrink = check.shrink + 1
    end
    local shrinkComplete = check.shrink >= PcStorageGeometry.RELEASE_SHRINK_TICKS
    local scanComplete = check.scanned >= check.total
    if shrinkComplete and scanComplete then
      if check.scanOutcome == "returned" then
        check.phase = "grow"
        check.shrink = 0
      else
        check.outcome = "released"
        check.phase = nil
      end
    end
  elseif check.phase == "grow" then
    if check.shrink < PcStorageGeometry.RELEASE_GROW_TICKS then
      check.shrink = check.shrink + 1
    end
    if check.shrink >= PcStorageGeometry.RELEASE_GROW_TICKS then
      check.outcome = "returned"
      check.phase = nil
    end
  end
end

---@param events table<string, unknown>[] an ordered batch of normalized events
function StorageScreenState:updateFixed(events)
  assert(not self._disposed, "disposed Storage does not update")
  assert(type(events) == "table", "Storage updates use an ordered event batch")
  if not self._booted then
    -- Retail plays the login cue once when the app opens, not per tick.
    self._booted = true
    self:_cue("SEQ_SE_DP_PC_LOGIN")
  end
  if self._closed then
    return
  end
  if #events > 0 then
    -- A message stays until the next input, then the result is acknowledged.
    self._notice = nil
    local acknowledged = self._releaseCheck
    local releaseMessageOpen = acknowledged ~= nil
      and (acknowledged.outcome == "released" or (acknowledged.outcome == "returned" and not acknowledged.acknowledged))
    if acknowledged ~= nil and acknowledged.outcome ~= "confirm" and acknowledged.outcome ~= "pending" then
      if acknowledged.outcome == "released" then
        if acknowledged.sequel then
          -- The bye-bye acknowledgement is when storage finally removes the
          -- mon (PCBox_State_RemoveReleasedMon).
          local result = self._actions:commit(assert(self._releaseIntent), true)
          self._releaseIntent, self._releaseRevisions = nil, nil
          if result.kind == "changed" then
            acknowledged.outcome = "removed"
            acknowledged.acknowledged = true
            acknowledged.sequel = nil
          else
            acknowledged.outcome = "stale"
            acknowledged.acknowledged = true
          end
        else
          -- The released line is followed by the bye-bye line before removal.
          acknowledged.sequel = true
        end
      elseif acknowledged.outcome == "returned" then
        if acknowledged.sequel then
          acknowledged.acknowledged = true
        else
          acknowledged.sequel = true
        end
      elseif acknowledged.outcome ~= "removed" then
        acknowledged.acknowledged = true
      end
    end
    if releaseMessageOpen then
      -- A release message owns this input: it only dismisses (or finishes)
      -- the message, never the grid behind it.
      self:_ensurePublished()
      return
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
  -- The signature belongs to the measurement that built the live plan,
  -- sampled once per refresh rather than re-sampled after the fact.
  self._admittedParentSignature = assert(self._publishedMeasurementSignature)
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
  self._publishedMeasurementSignature = nil
  self._admittedParentView = nil
  self._admittedParentPlan = nil
  self._admittedParentSignature = nil
  self:_disposeChild()
  self._session:dispose()
  local fallback = self._admittedLayoutSession
  if fallback ~= nil then
    fallback:dispose()
  end
end

return StorageScreenState
