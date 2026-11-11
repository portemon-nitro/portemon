-- Script dialogue host : the game-side bridge between the
-- script runtime's dialogue contract and the field dialogue controller. It
-- resolves message references (`msg.hgss.<bank>.<id>` through the message
-- provider), formats substitution slots from the instance's buffered text
-- arguments, opens the controller as a script-owned request (the session's
-- modal gate skips script-owned boxes; the scheduler steps them through
-- `advance`), and reports typing progress from the controller's status.
-- Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")

---@class ScriptDialogueHost
---@field private _controller table<string, unknown> FieldDialogueController-shaped
---@field private _provider FieldMessageProvider
---@field private _layout fun(formatted: table<string, unknown>): table<string, unknown>
---@field private _fontDef table<string, unknown>
---@field private _player table<string, unknown>|nil
---@field private _world table<string, unknown>|nil world state { getVar(id) -> unknown }
---@field private _mons HgssMonService|nil the live HGSS mon service for party/mon text
---@field private _items ItemCatalog|nil the shared item catalog for item/pocket/TM/berry text
---@field private _locationNames table<integer, string>|(fun(sectionId: integer): string?)|nil generated map-section display names
---@field private _frameIndex integer|nil player-selected user-frame index, captured at open
---@field private _yesNoController table<string, unknown> semantic field choice owner
---@field private _yesNoHost table<string, unknown>|nil live choice presentation host
---@field private _easyChatCatalog table<string, unknown>|nil borrowed shared word catalog behind word text and sentences
---@field private _pendingNode table<string, unknown>|nil
local ScriptDialogueHost = {}
ScriptDialogueHost.__index = ScriptDialogueHost

-- Text-value descriptor resolvers for the implemented forms: player and rival names,
-- the opposite protagonist's canonical name from the generated name bank,
-- and integers backed by a variable. Any other form is a fault: the
-- resolver contract never leaves a marker visible in the stream.
--
-- The opposite protagonist's canonical name lives in generated message bank
-- 445: message 1 names her for a male player, message 0 names him for a
-- female player. The source `BufferFriendsName` operation addresses that
-- bank through the player gender, so this boundary reads it the same way
-- instead of hard-coding either name.
local FRIEND_NAME_BANK_ID = 445

-- Read one generated message as substitution glyphs with scoped bank
-- ownership: the nested bank reference is released after a successful read
-- and also released before rethrowing the original fault when the bank get,
-- text parsing, or substitution formatting fails.
---@param provider FieldMessageProvider
---@param bankId integer
---@param messageId integer
---@param fontDef table<string, unknown>
---@return table<string, unknown> replacementTokens glyph-kind tokens without a terminal marker
local function scopedNameGlyphs(provider, bankId, messageId, fontDef)
  local acquired, acquireErr = provider:acquireBank(bankId)
  if not acquired then
    error(acquireErr, 0)
  end
  local template, templateErr = provider:get(bankId, messageId)
  if not template then
    provider:releaseBank(bankId)
    error(templateErr, 0)
  end
  local tokens, parseErr = FieldMessageProvider.asciiGlyphTokens(template.text, fontDef)
  if not tokens then
    provider:releaseBank(bankId)
    error(parseErr, 0)
  end
  provider:releaseBank(bankId)
  return tokens
end

-- Evaluates a text-operand that may be a literal scalar or a variable
-- reference through the world state.
---@param operand unknown
---@param world table<string, unknown>|nil
---@return unknown
local function evaluateTextOperand(operand, world)
  if type(operand) == "table" and operand.value == "var" then
    if world == nil or world.getVar == nil then
      local context = { operand = operand }
      ---@cast context Errors.Context
      Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "buffered text variable requires the world state", context)
    end
    local worldState = world --[[@as { getVar: fun(self: table, id: unknown): unknown }]]
    return worldState:getVar(operand.id)
  end
  return operand
end

-- Mon/party text identities. Returns the display string, or nil when the
-- descriptor names a form owned elsewhere. Out-of-range party positions
-- fail through the service's structured slot validation rather than
-- rendering an empty window.
---@param kind string
---@param descriptor table<string, unknown>
---@param mons HgssMonService the live HGSS mon service
---@param world table<string, unknown>|nil
---@return string|nil
local function resolveMonsTextValue(kind, descriptor, mons, world)
  local Mon = require("libs.mons.src.Mon")
  local catalog = mons:catalog()
  if kind == "party_species_name" then
    local position = evaluateTextOperand(descriptor.position, world)
    local mon = mons:partyMon(position)
    return catalog:species(mon.species).name
  elseif kind == "starter_species_name" then
    -- The published starter is the lead of the previously empty party: the
    -- starter task inserts the confirmed candidate at slot zero and the
    -- resumed script owns every later party change. Before selection the
    -- party is empty and the slot lookup fails through structured party
    -- validation; the modal presentation names its own candidates and never
    -- reads this global.
    local mon = mons:partyMon(0)
    return catalog:species(mon.species).name
  elseif kind == "party_nickname" then
    local position = evaluateTextOperand(descriptor.position, world)
    return Mon.displayName(mons:partyMon(position), catalog)
  elseif kind == "species_name" then
    local identity = evaluateTextOperand(descriptor.value, world)
    if type(identity) == "number" then
      return catalog:speciesByNativeId(identity).name
    end
    return catalog:species(identity --[[@as string]]).name
  elseif kind == "move_name" then
    local identity = evaluateTextOperand(descriptor.value, world)
    if type(identity) == "number" then
      return catalog:moveByNativeId(identity).name
    end
    return catalog:move(identity --[[@as string]]).name
  elseif kind == "party_mon_move_name" then
    local position = evaluateTextOperand(descriptor.position, world)
    local moveSlot = evaluateTextOperand(descriptor.moveSlot, world)
    local mon = mons:partyMon(position)
    local entry
    if type(moveSlot) == "number" then
      entry = mon.moves[moveSlot + 1]
    end
    if type(moveSlot) ~= "number" or entry == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_INVALID_REFERENCE,
        "party move slot is out of range",
        { position = position, moveSlot = moveSlot }
      )
    end
    assert(entry ~= nil, "move entry carries the validated move")
    return catalog:move(entry.move).name
  elseif kind == "nature_name" then
    local nature = evaluateTextOperand(descriptor.value, world)
    return require("libs.hgss.src.mons.HgssMonService").natureName(nature --[[@as integer]])
  end
  return nil
end

-- Item/pocket/TM/berry text identities, parallel to mon resolution. Returns
-- the display string, or nil when the descriptor names a form owned
-- elsewhere. Native identities resolve through the item catalog; unknown
-- natives fail through the catalog's structured record validation rather
-- than rendering a marker. A TM/HM move name coordinates the item catalog
-- (machine to taught move) with the injected mon catalog (move to display
-- name); a non-machine item is an attributed fault, never a fabricated
-- move. A berry name selects the source quantity-dependent form (below two
-- singular, otherwise plural), never the normal item plural.
---@param kind string
---@param descriptor table<string, unknown>
---@param items ItemCatalog the shared item catalog
---@param world table<string, unknown>|nil
---@param mons HgssMonService|nil the live HGSS mon service for move display names
---@return string|nil
local function resolveItemsTextValue(kind, descriptor, items, world, mons)
  if kind == "item_name" or kind == "item_name_indefinite" or kind == "item_name_plural" then
    local identity = evaluateTextOperand(descriptor.value, world)
    local record
    if type(identity) == "number" then
      record = items:itemByNativeId(identity)
    else
      record = items:item(identity --[[@as string]])
    end
    if kind == "item_name" then
      return record.name
    elseif kind == "item_name_indefinite" then
      return record.nameIndefinite
    end
    return record.namePlural
  elseif kind == "pocket_name" then
    local pocket = evaluateTextOperand(descriptor.value, world)
    if type(pocket) == "number" then
      return items:pocketName(items:pocketKeyByNativeId(pocket))
    end
    return items:pocketName(pocket --[[@as string]])
  elseif kind == "tmhm_move_name" then
    local identity = evaluateTextOperand(descriptor.value, world)
    local record
    if type(identity) == "number" then
      record = items:itemByNativeId(identity)
    else
      record = items:item(identity --[[@as string]])
    end
    local moveNativeId = record.tmhmMoveNativeId
    if type(moveNativeId) ~= "number" then
      Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "item is not a TM or HM", { item = identity })
    end
    if mons ~= nil then
      return mons:catalog():moveByNativeId(moveNativeId --[[@as integer]]).name
    end
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "TM/HM move text requires the mon catalog", { item = identity })
  elseif kind == "berry_name" then
    local itemIdentity = evaluateTextOperand(descriptor.item, world)
    local quantity = evaluateTextOperand(descriptor.quantity, world)
    local record
    if type(itemIdentity) == "number" then
      record = items:itemByNativeId(itemIdentity)
    else
      record = items:item(itemIdentity --[[@as string]])
    end
    if record.pocket ~= "berries" then
      Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "item is not a berry", { item = itemIdentity })
    end
    if type(quantity) ~= "number" then
      Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "berry quantity must be numeric", { quantity = quantity })
    end
    local count = quantity --[[@as number]]
    if count < 2 then
      return record.berryNameSingular
    end
    return record.berryNamePlural
  end
  return nil
end

-- Text-value descriptor resolvers for the implemented forms: player name,
-- integers backed by a variable, mon/party identities resolved through the
-- injected live mon service and its catalog, item/pocket/TM/berry
-- identities resolved through the injected shared item catalog (TM/HM move
-- names coordinate both catalogs), and buffered word identities resolved
-- through the shared word catalog. Any other form is a fault: the resolver
-- contract never leaves a marker visible in the stream.
-- One buffered word identity behind the easy_chat_word text form: the
-- null identity stays empty, every other identity resolves its display
-- fragments through the shared catalog. A missing catalog or an unknown
-- word is an attributed fault, never a marker.
---@param catalog table<string, unknown>|nil borrowed shared word catalog
---@param descriptor table<string, unknown> easy_chat_word text descriptor
---@return table<integer, table<string, unknown>>|nil replacementTokens
local function resolveEasyChatWord(catalog, descriptor)
  local word = descriptor.value
  if type(word) ~= "number" or word % 1 ~= 0 or word < 0 or word > 0xFFFF then
    local context = { value = word }
    ---@cast context Errors.Context
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "buffered word identity is invalid", context)
  end
  if catalog == nil then
    local context = { value = word }
    ---@cast context Errors.Context
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "buffered words require the shared word catalog", context)
  end
  if word == 0xFFFF then
    return {}
  end
  local catalogOwner = catalog --[[@as { wordTokens: fun(self: table, id: integer): table }]]
  return catalogOwner:wordTokens(word)
end

local function resolveTextValue(
  descriptor,
  player,
  fontDef,
  world,
  provider,
  mons,
  items,
  locationNames,
  easyChatCatalog
)
  if type(descriptor) == "string" then
    return FieldMessageProvider.asciiGlyphTokens(descriptor, fontDef)
  end
  if type(descriptor) ~= "table" or descriptor.text == nil then
    return nil
  end
  local kind = descriptor.text
  local value = descriptor.value
  if kind == "easy_chat_word" then
    return resolveEasyChatWord(easyChatCatalog, descriptor)
  end
  if kind == "player_name" then
    return FieldMessageProvider.asciiGlyphTokens(player:name(), fontDef)
  elseif kind == "rival_name" then
    return FieldMessageProvider.asciiGlyphTokens(player:rivalName(), fontDef)
  elseif kind == "friend_name" then
    local gender = player:gender()
    return scopedNameGlyphs(provider, FRIEND_NAME_BANK_ID, gender == 0 and 1 or 0, fontDef)
  elseif kind == "literal_text" then
    assert(type(value) == "string", "literal text value must be a string")
    return FieldMessageProvider.asciiGlyphTokens(value, fontDef)
  elseif kind == "map_name" then
    local mapSection = value
    if type(mapSection) == "table" and mapSection.value == "var" then
      assert(world and type(world.getVar) == "function", "map name variable requires world state")
      mapSection = world:getVar(mapSection.id)
    end
    assert(type(mapSection) == "number" and mapSection % 1 == 0, "map name section id is invalid")
    local name = type(locationNames) == "function" and locationNames(mapSection)
      or locationNames and locationNames[mapSection]
    assert(type(name) == "string", "map name section has no generated display name")
    return FieldMessageProvider.asciiGlyphTokens(name, fontDef)
  elseif kind == "integer" then
    if value == nil or type(value) ~= "table" or value.value ~= "var" then
      return nil
    end
    if world == nil or world.getVar == nil then
      local context = { kind = kind, value = value }
      ---@cast context Errors.Context
      Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "integer text values require the world state", context)
    end
    local worldState = world --[[@as { getVar: fun(self: table, id: unknown): unknown }]]
    return FieldMessageProvider.asciiGlyphTokens(tostring(worldState:getVar(value.id)), fontDef)
  elseif kind == "capitalized" then
    -- Buffered-text upper-casing: the wrapped mon or item text resolves to
    -- its display string, whose first character is upper-cased.
    local source = descriptor.source
    assert(type(source) == "table" and type(source.text) == "string", "capitalized text wraps a buffered text value")
    local text = mons ~= nil and resolveMonsTextValue(source.text, source, mons, world) or nil
    if text == nil and items ~= nil then
      text = resolveItemsTextValue(source.text, source, items, world, mons)
    end
    if text == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_UNSUPPORTED_REACHABLE,
        "unsupported capitalized text source " .. source.text,
        { kind = source.text }
      )
    end
    assert(text ~= nil, "capitalized text resolved")
    return FieldMessageProvider.asciiGlyphTokens(text:sub(1, 1):upper() .. text:sub(2), fontDef)
  end
  if mons ~= nil and type(kind) == "string" then
    local resolved = resolveMonsTextValue(kind, descriptor, mons, world)
    if resolved ~= nil then
      return FieldMessageProvider.asciiGlyphTokens(resolved, fontDef)
    end
  end
  if items ~= nil and type(kind) == "string" then
    local resolved = resolveItemsTextValue(kind, descriptor, items, world, mons)
    if resolved ~= nil then
      return FieldMessageProvider.asciiGlyphTokens(resolved, fontDef)
    end
  end
  Errors.raise(
    ScriptErrors.SCRIPT_UNSUPPORTED_REACHABLE,
    "unsupported buffered text form " .. tostring(kind),
    { kind = kind }
  )
end

---@param opts table<string, unknown> { controller, yesNoController, yesNoHost?, provider, layout, fontDef, player, world, mons?, items?, locationNames?, frameIndex?, easyChatCatalog? }
---@return ScriptDialogueHost
function ScriptDialogueHost.new(opts)
  assert(
    type(opts) == "table" and opts.controller and opts.provider,
    "script dialogue host requires a controller and message provider"
  )
  assert(
    opts.yesNoController and type(opts.yesNoController.open) == "function",
    "script dialogue host requires a yes/no controller"
  )
  assert(type(opts.layout) == "function", "script dialogue host requires the dialogue layout")
  assert(
    type(opts.fontDef) == "table" and type(opts.fontDef.charmap) == "table",
    "script dialogue host requires the generated font definition"
  )
  assert(opts.player and type(opts.player.name) == "function", "script dialogue host requires the player facade")
  local yesNoHost = opts.yesNoHost
  if yesNoHost ~= nil then
    assert(
      type(yesNoHost.openChoice) == "function"
        and type(yesNoHost.syncSelection) == "function"
        and type(yesNoHost.close) == "function",
      "script dialogue host choice host is invalid"
    )
  end
  local frameIndex = opts.frameIndex
  assert(
    frameIndex == nil or (type(frameIndex) == "number" and frameIndex >= 0 and frameIndex % 1 == 0),
    "script dialogue host frameIndex must be a non-negative integer"
  )
  local easyChatCatalog = opts.easyChatCatalog
  if easyChatCatalog ~= nil then
    assert(
      type(easyChatCatalog.wordTokens) == "function" and type(easyChatCatalog.template) == "function",
      "script dialogue word catalog needs its token and template resolvers"
    )
  end
  return setmetatable({
    _controller = opts.controller,
    _provider = opts.provider,
    _layout = opts.layout,
    _fontDef = opts.fontDef,
    _player = opts.player,
    _world = opts.world,
    _mons = opts.mons,
    _items = opts.items,
    _locationNames = opts.locationNames,
    _frameIndex = frameIndex,
    _yesNoController = opts.yesNoController,
    _yesNoHost = yesNoHost,
    _easyChatCatalog = easyChatCatalog,
  }, ScriptDialogueHost)
end

function ScriptDialogueHost:isOpen()
  return self._controller:isModal()
end

-- Replaces the player frame index future dialogue and choice requests
-- carry. An open dialogue or choice keeps the frame it opened with;
-- changing the default underneath it is an invariant fault with no
-- mutation. Script-specific window styles stay distinct from this default.
---@param index integer the validated zero-based user-frame index
function ScriptDialogueHost:setFrameIndex(index)
  assert(
    type(index) == "number" and index % 1 == 0 and index >= 0,
    "script dialogue frame index must be a non-negative integer"
  )
  if self:isOpen() or self:yesNoPresentation() ~= nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "the dialogue host owns an open request; defaults change only while idle"
    )
  end
  self._frameIndex = index
end

---@return { yesText: string, noText: string, frameIndex: integer? }
function ScriptDialogueHost:yesNoOptions()
  local yes = self:resolveMessage({ message = "external", bank = 191, id = 42 }, {}, {})
  local no = self:resolveMessage({ message = "external", bank = 191, id = 43 }, {}, {})
  return {
    yesText = yes.text,
    noText = no.text,
    frameIndex = self._frameIndex,
  }
end

---@param tick integer? the scheduler tick, required when a live choice host is composed
function ScriptDialogueHost:askYesNo(tick)
  local options = self:yesNoOptions()
  self._yesNoController:open(options)
  if self._yesNoHost ~= nil then
    self._yesNoHost:openChoice({
      yesText = options.yesText,
      noText = options.noText,
      frameIndex = options.frameIndex,
      selectedIndex = 0,
    }, tick)
  end
end

-- Applies translated choice events to the semantic controller, then syncs
-- the live host selection so draw and pointer mapping observe the same
-- row the controller owns.
---@param events table[]
function ScriptDialogueHost:handleYesNoEvents(events)
  assert(type(events) == "table", "choice events are required")
  for _, event in ipairs(events) do
    self._yesNoController:handleEvent(event)
  end
  if self._yesNoHost ~= nil then
    self._yesNoHost:syncSelection(self._yesNoController:status().selectedIndex)
  end
end

function ScriptDialogueHost:yesNoPresentation()
  local status = self._yesNoController:status()
  return status.active and status or nil
end

function ScriptDialogueHost:takeYesNoResult()
  return self._yesNoController:takeResult()
end

function ScriptDialogueHost:closeYesNo()
  self._yesNoController:close()
  if self._yesNoHost ~= nil then
    self._yesNoHost:close()
  end
end

-- One resolver per substitution control in `template`; the buffer slot is each
-- marker's own first argument, so a control occurring at several slots resolves
-- every occurrence from its own slot. The node's own bindings win over
-- instance textArgs.
---@param template table<string, unknown> provider message template
---@param bindings table<string, unknown> slot -> text value
---@param textArgs table<string, unknown> slot -> text value
---@return table<string, function> resolvers keyed by substitution control
function ScriptDialogueHost:substitutionResolvers(template, bindings, textArgs)
  local resolvers = {}
  local templateTokens = template --[[@as table]].tokens
  for _, token in ipairs(templateTokens) do
    if token.kind == "substitution" and token.control == FieldMessageText.TRNAME then
      local function resolvePlayerName()
        return FieldMessageProvider.asciiGlyphTokens(self._player:name(), self._fontDef)
      end
      resolvers[token.control] = resolvePlayerName
    elseif token.kind == "substitution" and token.args ~= nil and resolvers[token.control] == nil then
      local function resolveSubstitution(_, args, _)
        local slot = args and args[1]
        local descriptor = bindings[slot] or textArgs[slot]
        return resolveTextValue(
          descriptor,
          self._player,
          self._fontDef,
          self._world,
          self._provider,
          self._mons,
          self._items,
          self._locationNames,
          self._easyChatCatalog
        )
      end
      resolvers[token.control] = resolveSubstitution
    end
  end
  return resolvers
end

-- Resolve a literal word reference to a controller-ready formatted
-- message: the sentence template must exist, every non-null word resolves
-- its display fragments through the shared catalog, and the null identity
-- stays empty. The fragment stream concatenates the detached word tokens
-- directly; read-time expansion ignores selection locks.
---@param message table<string, unknown> easy_chat message reference
---@return FieldMessageProvider.FormattedMessage formatted { tokens, ... }
function ScriptDialogueHost:resolveEasyChatMessage(message)
  local catalog = self._easyChatCatalog
  if catalog == nil then
    local context = { message = message }
    ---@cast context Errors.Context
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "word sentences require the shared word catalog", context)
  end
  ---@cast catalog table<string, unknown>
  local bank, number, words = message.bank, message.number, message.words
  if
    type(bank) ~= "number"
    or type(number) ~= "number"
    or type(words) ~= "table"
    or #words ~= 2
    or catalog:template(bank, number) == nil
  then
    local context = { message = message }
    ---@cast context Errors.Context
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "unknown word sentence", context)
  end
  local tokens = {}
  local catalogOwner = catalog --[[@as { wordTokens: fun(self: table, id: integer): table }]]
  for _, word in ipairs(words) do
    if word ~= 0xFFFF then
      for _, fragment in ipairs(catalogOwner:wordTokens(word)) do
        tokens[#tokens + 1] = fragment
      end
    end
  end
  return {
    bankId = bank,
    messageId = number,
    text = "",
    tokens = tokens,
    hadUnresolvedSubstitutions = false,
  }
end

-- Resolve a message reference to a controller-ready formatted message.
---@param message unknown string reference, external descriptor, or word reference
---@param bindings table<string, unknown> slot -> text value
---@param textArgs table<string, unknown> slot -> text value
---@return FieldMessageProvider.FormattedMessage formatted { tokens, ... }
function ScriptDialogueHost:resolveMessage(message, bindings, textArgs)
  if type(message) == "table" and message.message == "easy_chat" then
    return self:resolveEasyChatMessage(message)
  end
  local bankId, messageId
  if type(message) == "string" then
    bankId, messageId = message:match("^msg%.hgss%.(%d+)%.(%d+)$")
    if bankId == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_INVALID_REFERENCE,
        "unknown message reference " .. tostring(message),
        { message = message }
      )
    end
    bankId, messageId = tonumber(bankId), tonumber(messageId)
  elseif type(message) == "table" and message.message == "external" then
    bankId, messageId = message.bank, message.id
    if type(bankId) ~= "number" or bankId % 1 ~= 0 or type(messageId) ~= "number" or messageId % 1 ~= 0 then
      Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "external message location is invalid", { message = message })
    end
  else
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "unsupported message reference form", { message = message })
  end
  local bank, bankErr = self._provider:acquireBank(bankId)
  if not bank then
    local err = bankErr --[[@as Errors.Error]]
    local context = { bankId = bankId, cause = err.context }
    ---@cast context Errors.Context
    Errors.raise(err.code, err.message, context)
  end
  local template, templateErr = self._provider:get(bankId, messageId)
  if not template then
    self._provider:releaseBank(bankId)
    local err = templateErr --[[@as Errors.Error]]
    local context = { bankId = bankId, messageId = messageId, cause = err.context }
    ---@cast context Errors.Context
    Errors.raise(err.code, err.message, context)
  end
  ---@cast template table<string, unknown>
  local resolvers = self:substitutionResolvers(template, bindings, textArgs)
  local okFormat, formatted = pcall(self._provider.format, self._provider, template, {}, resolvers)
  self._provider:releaseBank(bankId)
  if not okFormat then
    error(formatted)
  end
  if formatted.hadUnresolvedSubstitutions then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      string.format("message bank %d id %d has unresolvable substitutions", bankId, messageId),
      { bankId = bankId, messageId = messageId }
    )
  end
  return formatted
end

-- Open: called with the graph node; the controller request
-- opens on the following startPrint so a failed resolve cannot leave a
-- half-open box.
---@param node table<string, unknown>
function ScriptDialogueHost:openMessage(node)
  self._pendingNode = node
end

-- Open the controller as a script-owned request and start revealing.
-- An explicitly requested instant print reveals its whole content in the
-- same open: the waiter still owns completion, only the cadence changes.
---@param message unknown
---@param bindings table<string, unknown>|nil
---@param textArgs table<string, unknown>|nil
function ScriptDialogueHost:startPrint(message, bindings, textArgs)
  local node = self._pendingNode or {}
  self._pendingNode = nil
  local formatted = self:resolveMessage(message, bindings or {}, textArgs or {})
  -- Stable per-node identity for diagnostics: the full reference string,
  -- never a digit run that could collide across banks.
  local id = "script-dialogue"
  if node.message ~= nil then
    id = "script-" .. tostring(node.message):gsub("[^%w]", "_")
  end
  self._controller:open({
    id = id,
    message = formatted,
    allowCancel = false,
    instant = node.instant == true,
    frameIndex = self._frameIndex,
    metadata = {
      scriptOwned = true,
      message = message,
    },
  })
end

-- Typing progress for the dialogue task: page and glyph within the current
-- page, plus native printer completion. Only the end-of-text wait and the
-- post-boundary handoff count as complete: a prompt/page boundary still
-- belongs to the printer until a fresh edge performs its clear/scroll.
---@return table<string, unknown>|nil { pageIndex, glyphIndex, done }
function ScriptDialogueHost:printProgress()
  if not self:isOpen() then
    return { pageIndex = 0, glyphIndex = 0, done = true }
  end
  local status = self._controller:status()
  local done = status.state == "WAITING_CLOSE" or status.state == "CLOSING" or status.state == "CLOSED"
  return {
    pageIndex = math.max(0, (status.pageIndex or 1) - 1),
    glyphIndex = status.revealedGlyphs or 0,
    done = done,
  }
end

-- Close the box (idempotent on the controller). A non-erasing close would
-- need a message buffer the controller does not own; requesting one is an
-- attributed fault rather than a silent ignore.
---@param erase boolean
function ScriptDialogueHost:close(erase)
  if erase == false then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the dialogue controller cannot preserve a closed message box")
  end
  self._controller:close()
end

-- The controller keeps a completed printer handoff modal until explicit
-- script closure. Hold validates that state without changing its owner.
function ScriptDialogueHost:hold()
  local state = self._controller:status().state
  if state ~= "WAITING_CLOSE" and state ~= "CLOSING" then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "the dialogue controller has no completed message to hold",
      { state = state }
    )
  end
end

function ScriptDialogueHost:showWaitingIcon()
  Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the dialogue controller has no waiting icon")
end

function ScriptDialogueHost:hideWaitingIcon()
  Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the dialogue controller has no waiting icon")
end

-- Advance an open script-owned box by one fixed tick. The scheduler calls
-- this from its engine-owned async phase with the immutable input snapshot;
-- the session's modal gate never steps script-owned requests.
---@param input table<string, unknown>|nil
function ScriptDialogueHost:advance(input)
  if not self:isOpen() then
    return
  end
  input = input or {}
  local status = self._controller:status()
  -- A held post-boundary handoff stays open until script ownership closes
  -- or replaces it; stepping it here would close the window out from under
  -- the later close. Native prompt/page boundaries still own their fresh
  -- continuation edge, while the end-of-text wait reserves its edge for the
  -- explicit task-owned input that follows printing.
  if status.state == "CLOSING" then
    return
  end
  local printerDone = status.state == "WAITING_CLOSE"
  self._controller:step({
    actionPressed = input.pressedAction == true and not printerDone,
    actionDown = input.actionDown == true,
    cancelPressed = input.pressedCancel == true and not printerDone,
    cancelDown = input.cancelDown == true,
  })
end

return ScriptDialogueHost
