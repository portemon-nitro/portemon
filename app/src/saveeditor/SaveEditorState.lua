-- Coordinates the editor's asynchronous opening, input, session, and resources.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local HgssInputBindings = require("libs.hgss.src.ui.HgssInputBindings")
local PlayerData = require("libs.hgss.src.save.PlayerData")
local DisplayContext = require("libs.ui.src.DisplayContext")
local Interface = require("app.src.saveeditor.SaveEditorInterface")
local Renderer = require("app.src.saveeditor.SaveEditorRenderer")
local Controller = require("app.src.saveeditor.SaveEditorController")
local ValueEditor = require("app.src.saveeditor.SaveEditorValueEditor")
local Composition = require("app.src.saveeditor.SaveEditorComposition")
local LocationService = require("app.src.saveeditor.SaveEditorLocationService")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local ItemAssetSchema = require("libs.assets.src.ItemAssetSchema")
local Experience = require("libs.mons.src.gen4.Experience")
local Personality = require("libs.mons.src.gen4.Personality")

---@class SaveEditorLocationService
---@field listMaps fun(self: SaveEditorLocationService): table[]
---@field openMap fun(self: SaveEditorLocationService, mapId: integer)
---@field setViewport fun(self: SaveEditorLocationService, centerX: integer, centerZ: integer, widthTiles: integer, heightTiles: integer)
---@field update fun(self: SaveEditorLocationService)
---@field snapshot fun(self: SaveEditorLocationService): table<string, unknown>
---@field resolve fun(self: SaveEditorLocationService, mapId: integer, fieldX: integer, fieldZ: integer, expectedGeneration: integer): SaveEditorLocation?, table<string, unknown>
---@field dispose fun(self: SaveEditorLocationService)

---@class SaveEditorState
---@field valueEditor SaveEditorValueEditor?
---@field versionId string
---@field saveId string
---@field width number
---@field height number
---@field derivedAssets { requestMilestone: fun(name: string, urgency: string): unknown }
---@field repositoryRoot string
---@field onResult fun(result: { kind: string })
---@field displayContext DisplayContext
---@field controller SaveEditorController
---@field renderer SaveEditorRenderer?
---@field presentation ApplicationPresentation?
---@field status string
---@field message string
---@field session SaveEditorSession?
---@field dependencies table<string, unknown>?
---@field locationService SaveEditorLocationService?
---@field locationViewport table<string, number>?
---@field locationServiceMapId integer?
---@field errorMessage string?
---@field notice string?
---@field generation number
---@field disposed boolean
---@field resultSent boolean
---@field approvedExit boolean
---@field closeRequest { reason: "back"|"quit", phase: "confirm"|"saving", previousModal: string?, previousFocus: string }?
---@field monDraft SaveEditorMonDraft?
---@field pendingDraftAction table<string, unknown>?
---@field activeDraftField table<string, unknown>?
---@field valuePurpose string?
---@field dateProvider fun(): table<string, integer>
---@field iconStatus string?
---@field iconFailure string?
---@field pendingRemove table<string, unknown>?
---@field pendingQuantity table<string, unknown>?
local State = {}
State.__index = State

local function message(value)
  if Errors.is(value) then
    return value.message
  end
  return tostring(value)
end

local function makeText(versionId)
  return FieldTextRenderer.new({ cacheFs = CacheFs.forVersion(versionId) })
end

function State.new(options)
  assert(type(options) == "table", "save editor state options are required")
  assert(type(options.versionId) == "string" and options.versionId ~= "")
  assert(type(options.saveId) == "string" and options.saveId ~= "")
  assert(type(options.derivedAssets) == "table" and type(options.derivedAssets.requestMilestone) == "function")
  assert(type(options.repositoryRoot) == "string" and options.repositoryRoot ~= "")
  assert(type(options.onResult) == "function")
  local width, height = options.width, options.height
  if width == nil or height == nil then
    width, height = love.graphics.getDimensions()
  end
  local dateProvider = options.dateProvider
    or function()
      local date = os.date("*t")
      return { year = date.year, month = date.month, day = date.day }
    end
  assert(type(dateProvider) == "function", "save editor date provider must be callable")
  local text = makeText(options.versionId)
  local rendererOk, rendererOrError = pcall(Renderer.new, { text = text })
  if not rendererOk then
    pcall(function()
      text:release()
    end)
    error(rendererOrError, 0)
  end
  local presentationOk, presentationOrError = pcall(ApplicationPresentation.new, Interface.defaults())
  if not presentationOk then
    pcall(function()
      assert(rendererOrError):dispose()
    end)
    error(presentationOrError, 0)
  end
  ---@type SaveEditorState
  local self = setmetatable({
    versionId = options.versionId,
    saveId = options.saveId,
    width = width,
    height = height,
    derivedAssets = options.derivedAssets,
    repositoryRoot = options.repositoryRoot,
    onResult = options.onResult,
    displayContext = options.displayContext or DisplayContext.new({}),
    controller = Controller.new(),
    renderer = assert(rendererOrError),
    presentation = assert(presentationOrError),
    status = "opening",
    message = "Preparing save data",
    session = nil,
    dependencies = nil,
    locationService = nil,
    locationViewport = nil,
    locationServiceMapId = nil,
    valueEditor = nil,
    errorMessage = nil,
    notice = nil,
    generation = 1,
    disposed = false,
    resultSent = false,
    approvedExit = false,
    closeRequest = nil,
    monDraft = nil,
    pendingDraftAction = nil,
    activeDraftField = nil,
    valuePurpose = nil,
    dateProvider = dateProvider,
    iconStatus = nil,
    iconFailure = nil,
    pendingRemove = nil,
    pendingQuantity = nil,
  }, State)
  local resolveOk, resolveError = pcall(function()
    self:_resolve(self:_snapshot())
  end)
  if not resolveOk then
    self.presentation:dispose()
    self.renderer:dispose()
    self.presentation, self.renderer = nil, nil
    error(resolveError, 0)
  end
  return self
end

function State:_readyReadiness()
  local ready = true
  for _, name in ipairs({ "field-planning", "field-runtime" }) do
    local result = self.derivedAssets.requestMilestone(name, "required")
    if result == true then
      -- Milestone available.
    elseif type(result) == "table" and result.state == "failed" then
      error(
        Errors.new(
          "SAVE_EDITOR_ASSET_PREPARATION_FAILED",
          tostring(result.failure or (name .. " preparation failed")),
          {
            milestone = name,
          }
        ),
        0
      )
    elseif type(result) == "table" and result.state == "ready" then
      -- Explicit terminal success from a host adapter.
    else
      ready = false
    end
  end
  return ready
end

function State:update()
  if self.disposed then
    return
  end
  if self.status == "opening" then
    local generation = self.generation
    local readyOk, ready = pcall(function()
      return self:_readyReadiness()
    end)
    if generation ~= self.generation or self.disposed then
      return
    end
    if not readyOk then
      self:_openingFailed(ready)
      return
    end
    if not ready then
      return
    end
    local opened, graphOrError = pcall(Composition.open, {
      versionId = self.versionId,
      saveId = self.saveId,
      repositoryRoot = self.repositoryRoot,
      derivedAssets = self.derivedAssets,
    })
    if generation ~= self.generation or self.disposed then
      return
    end
    if not opened then
      self:_openingFailed(graphOrError)
      return
    end
    self.dependencies = graphOrError
    self.session = assert(graphOrError.session)
    self.locationService = LocationService.new({
      cacheFs = assert(graphOrError.cacheFs),
      world = assert(graphOrError.world),
      derivedAssets = assert(graphOrError.derivedAssets),
      savedObjects = assert(graphOrError.savedObjects),
    })
    local originalLocation = assert(self.session:snapshot().location)
    self.controller:enterLocation(originalLocation)
    self.controller:setSection("Location")
    self.locationService:openMap(originalLocation.mapId)
    self.locationServiceMapId = originalLocation.mapId
    self.status, self.errorMessage = "ready", nil
    self:_resolve(self:_snapshot())
  end
  if self.status == "ready" and self.locationService then
    self:_updateLocationService()
  end
  if self.status == "ready" and self.renderer and self.dependencies then
    local view = self:_snapshot()
    local plan = self:_resolve(view)
    self.renderer:prepareVisibleIcons(view, plan, self.dependencies.cacheFs, self.derivedAssets)
    self.iconStatus, self.iconFailure = self.renderer.iconStatus, self.renderer.iconFailure
  end
end

function State:_openingFailed(err)
  if not Errors.is(err) then
    error(err, 0)
  end
  self.status = "error"
  self.errorMessage = message(err)
  self.controller.focus = "retry"
  self:_resolve(self:_snapshot())
end

function State:_snapshot()
  local session = self.session and self.session:snapshot() or nil
  local flags = session and self:_flagRows(session.flags) or {}
  local party = session and self:_partyView() or {}
  local bag = session and self:_bagView() or {}
  local view = {
    kind = "save_editor",
    status = self.status,
    message = self.errorMessage or self.message,
    errorMessage = self.errorMessage,
    notice = self.notice,
    versionId = self.versionId,
    saveId = self.saveId,
    session = session,
    ready = session ~= nil,
    dirty = self.session ~= nil and self.session:isDirty() or self.monDraft ~= nil,
    dirtySections = session and session.dirtySections or { money = false, flags = false },
    section = self.controller.section,
    sections = self.controller:snapshot().sections,
    navigationRows = {
      { role = "action", id = "section:Player", targetId = "section:Player", label = "Player" },
      { role = "action", id = "section:Progress", targetId = "section:Progress", label = "Progress" },
    },
    modal = self.controller.modal,
    focus = self.controller.focus,
    scrollOffset = self.controller.scrollOffset,
    query = self.controller.query,
    flagFilter = self.controller.flagFilter,
    flagGroup = self.controller.flagGroup,
    flagGroupLabel = self.controller.flagGroup or self.controller.flagFilter,
    flagFilterLabel = self.controller.flagGroup or self.controller.flagFilter,
    flagRows = flags,
    valueEditor = self.valueEditor and self.valueEditor:snapshot() or nil,
    unappliedDraft = self.monDraft ~= nil,
    iconStatus = self.iconStatus,
    iconFailure = self.iconFailure,
    locationNavigation = self.controller:locationSnapshot(),
  }
  if self.locationService then
    local location = self.locationService:snapshot()
    location.maps = self.locationService:listMaps()
    location.symbol = location.map and location.map.symbol or nil
    location.actionStatus = self.locationActionStatus
        and {
          state = self.locationActionStatus.state,
          reason = self.locationActionStatus.reason,
        }
      or nil
    view.location = location
  end
  for key, value in pairs(party) do
    view[key] = value
  end
  for key, value in pairs(bag) do
    view[key] = value
  end
  return view
end

function State:_flagRows(values)
  local rows = {}
  local query = self.controller.query:lower()
  for name, flagId in pairs(FieldScriptSymbols.flagsByName) do
    local named = name:sub(1, 9) ~= "FLAG_UNK_"
    local inFilter = self.controller.flagFilter == "All" or named
    if self.controller.flagGroup then
      inFilter = name:sub(6, 6) == self.controller.flagGroup
    end
    if inFilter and (query == "" or name:lower():find(query, 1, true)) then
      rows[#rows + 1] = { name = name, id = flagId, value = values[flagId] == true }
    end
  end
  table.sort(rows, function(a, b)
    return a.name < b.name
  end)
  return rows
end

function State:_partyView()
  local dependencies = assert(self.dependencies, "ready Party view requires editor dependencies")
  local context = assert(dependencies.context)
  local catalog = assert(context.monCatalog)
  local snapshot = self.session:partySnapshot()
  local members = snapshot.members
  local controller = self.controller:snapshot()
  local rows = {}
  if controller.partyPage == "list" then
    local bySlot = {}
    for _, member in ipairs(members) do
      bySlot[member.slot0] = member.mon
    end
    for slot0 = 0, 5 do
      local mon = bySlot[slot0]
      if mon ~= nil then
        local species = catalog:species(mon.species)
        rows[#rows + 1] = {
          role = "action",
          targetId = "party:slot:" .. slot0,
          label = mon.nickname ~= nil and mon.nickname ~= "" and mon.nickname or species.name or mon.species,
          value = mon.species,
          iconKey = catalog:iconSelection(mon),
          slot0 = slot0,
        }
      else
        rows[#rows + 1] = {
          role = "read-only value",
          targetId = "party:empty-slot:" .. slot0,
          label = "Empty slot " .. (slot0 + 1),
        }
      end
    end
  elseif controller.partySlot0 ~= nil or self.monDraft ~= nil then
    local mon = self.monDraft and self.monDraft:record() or self:_selectedPartyMon(members)
    local projection = self.monDraft and self.monDraft:projection() or {}
    local valid, validationError = mon, nil
    if self.monDraft then
      valid, validationError = self.monDraft:validate()
    end
    rows = self:_monRows(mon, projection, controller.partySubpage, self.monDraft ~= nil)
    if validationError ~= nil then
      rows[#rows + 1] = { role = "warning", targetId = "party:validation", label = message(validationError) }
    elseif self.monDraft and valid == nil then
      rows[#rows + 1] =
        { role = "warning", targetId = "party:validation", label = "Correct invalid fields before Apply." }
    end
  end
  local selected = controller.partySlot0
  local draftDirty = self.monDraft ~= nil and (self.monDraft:mode() == "add" or self.monDraft:isDirty())
  return {
    partyPage = controller.partyPage,
    partySlot0 = selected,
    partyLastSlot0 = #members - 1,
    partySubpage = controller.partySubpage,
    partySubpages = { "Identity", "Training", "Stats", "Moves", "Origin" },
    partyRows = rows,
    partyCanAdd = #members < 6,
    partyDirty = draftDirty,
    partyValid = self.monDraft ~= nil and self.monDraft:validate() ~= nil,
    partyMemberCount = #members,
    partyError = self.errorMessage,
  }
end

function State:_selectedPartyMon(members)
  local slot0 = assert(self.controller.partySlot0, "Party detail requires a selected slot")
  for _, member in ipairs(members) do
    if member.slot0 == slot0 then
      return member.mon
    end
  end
  error("selected party slot is no longer available", 2)
end

function State:_monRows(mon, projection, subpage, editable)
  local dependencies = assert(self.dependencies)
  local context = assert(dependencies.context)
  local catalog = assert(context.monCatalog)
  local rows = {}
  local function add(fieldId, label, value, role, editor)
    rows[#rows + 1] = {
      role = editable and role or "read-only value",
      targetId = editable and editor and ("party:field:" .. fieldId) or ("party:readonly:" .. fieldId),
      id = fieldId,
      label = label,
      value = value,
      editor = editable and editor or nil,
      enabled = editable and editor ~= nil,
    }
  end
  local function integer(fieldId, label, value, minimum, maximum, base, setter)
    add(fieldId, label, value, "integer value", {
      kind = "integer",
      value = value,
      min = minimum,
      max = maximum,
      base = base or "decimal",
      setter = setter or "scalar",
      fieldId = fieldId,
    })
  end
  local function choice(fieldId, label, value, options, setter, convert)
    add(fieldId, label, value, "named choice", {
      kind = "choice",
      value = value,
      options = options,
      setter = setter or "scalar",
      fieldId = fieldId,
      convert = convert,
    })
  end
  local function textName(fieldId, label, value, kind, subject)
    add(fieldId, label, value, "action", {
      kind = "name",
      value = value or "",
      nameKind = kind,
      subject = subject,
      setter = fieldId == "nickname" and "scalar" or "origin",
      fieldId = fieldId,
    })
    if fieldId == "nickname" and editable then
      rows[#rows + 1] = {
        role = "action",
        targetId = "party:clear-nickname",
        id = "clear-nickname",
        label = "Clear nickname",
        enabled = true,
      }
    end
  end

  if subpage == "Identity" then
    local species = catalog:species(mon.species)
    local speciesOptions = self:_catalogOptions(catalog:speciesKeys(), function(key)
      return catalog:species(key).name or key
    end)
    local forms = {}
    for formId in pairs(species.forms) do
      forms[#forms + 1] = formId
    end
    table.sort(forms)
    local formOptions = self:_catalogOptions(forms, function(key)
      return tostring(key)
    end)
    local abilityOptions = {}
    local formOk, form = pcall(catalog.form, catalog, mon.species, mon.form)
    if formOk then
      abilityOptions = self:_catalogOptions(form.abilities, function(key)
        return catalog:ability(key).name or key
      end)
    end
    local itemCatalog = assert(context.itemCatalog)
    local heldItems = itemCatalog:itemKeys()
    local heldOptions = self:_catalogOptions(heldItems, function(key)
      return itemCatalog:item(key).name or key
    end)
    choice("species", "Species", mon.species, speciesOptions)
    choice("form", "Form", tostring(mon.form), formOptions, "scalar", "integer")
    textName(
      "nickname",
      "Nickname",
      mon.nickname,
      "pokemon",
      { kind = "pokemon", species = mon.species, form = mon.form }
    )
    integer("personality", "Personality", mon.personality, 0, 4294967295, "hex")
    choice("ability", "Ability", mon.ability, abilityOptions)
    choice("heldItem", "Held item", mon.heldItem, heldOptions)
    local abilityId = "Unavailable"
    local abilityOk, abilityDefinition = pcall(catalog.ability, catalog, mon.ability)
    if abilityOk then
      abilityId = abilityDefinition.nativeId
    elseif not Errors.is(abilityDefinition) then
      error(abilityDefinition, 0)
    end
    add("species-native-id", "Native species ID", species.nativeId)
    add("form-native-id", "Native form ID", mon.form)
    add("ability-native-id", "Native ability ID", abilityId)
    ---@type string|integer
    local abilitySlot = "Unavailable"
    if formOk and projection.nature ~= nil then
      abilitySlot = Personality.abilitySlot(#form.abilities, mon.personality)
    end
    add("pid-ability-slot", "PID ability slot", abilitySlot)
    add("nature", "Nature (derived)", projection.nature or "Unavailable")
    add("gender", "Gender (derived)", projection.gender or "Unavailable")
    add("shiny", "Shiny (derived)", projection.shiny == nil and "Unavailable" or (projection.shiny and "Yes" or "No"))
  elseif subpage == "Training" then
    local species = catalog:species(mon.species)
    local expRange = "Unavailable"
    if projection.level then
      local curve = catalog:growthCurve(species.growthCurve)
      local lower = Experience.expFor(curve, projection.level)
      local upper = projection.level < 100 and Experience.expFor(curve, projection.level + 1) or nil
      expRange = tostring(lower) .. "–" .. tostring(upper or "MAX")
    end
    integer("experience", "Experience", mon.experience, 0, 4294967295)
    integer("friendship", "Friendship", mon.friendship, 0, 255)
    add("level", "Level (derived)", projection.level or "Unavailable")
    add("growth-curve", "Growth curve", species.growthCurve)
    add("exp-interval", "Current level EXP interval", expRange)
  elseif subpage == "Stats" then
    local names = {
      { "hp", "HP" },
      { "attack", "Attack" },
      { "defense", "Defense" },
      { "speed", "Speed" },
      { "specialAttack", "Special Attack" },
      { "specialDefense", "Special Defense" },
    }
    for _, stat in ipairs(names) do
      integer("iv:" .. stat[1], stat[2] .. " IV", mon.ivs[stat[1]], 0, 31, nil, "iv")
      integer("ev:" .. stat[1], stat[2] .. " EV", mon.evs[stat[1]], 0, 255, nil, "ev")
      add("stat:" .. stat[1], stat[2] .. " (derived)", projection.stats and projection.stats[stat[1]] or "Unavailable")
    end
    add("max-hp", "Maximum HP (derived)", projection.stats and projection.stats.hp or "Unavailable")
    integer("currentHp", "Current HP", mon.condition.currentHp, 0, 4294967295)
    integer("status", "Status", mon.condition.status, 0, 4294967295, "hex")
    local evTotal = 0
    for _, value in pairs(mon.evs) do
      evTotal = evTotal + value
    end
    add("ev-total", "EV total", evTotal)
    add("ev-limit", "EV limit", "510")
  elseif subpage == "Moves" then
    for slot0, move in ipairs(mon.moves) do
      local index0 = slot0 - 1
      local prefix = "move:" .. index0 .. ":"
      local moveOptions = self:_catalogOptions(catalog:moveKeys(), function(key)
        return catalog:move(key).name or key
      end)
      choice(prefix .. "move", "Move " .. (index0 + 1), move.move, moveOptions, "move")
      local moveData = catalog:move(move.move)
      add(prefix .. "native-id", "Move native ID", moveData.nativeId)
      add(prefix .. "type", "Move type", moveData.type)
      add(prefix .. "power", "Move power", moveData.power)
      add(prefix .. "accuracy", "Move accuracy", moveData.accuracy)
      add(prefix .. "base-pp", "Base PP allowance", moveData.basePp)
      add(
        prefix .. "allowed-pp",
        "PP allowance at current Ups",
        moveData.basePp + math.floor(moveData.basePp * move.ppUps / 5)
      )
      integer(prefix .. "pp", "PP", move.pp, 0, 255, nil, "move")
      integer(prefix .. "ppUps", "PP Ups", move.ppUps, 0, 3, nil, "move")
      rows[#rows + 1] =
        { role = "action", targetId = "party:move:remove:" .. index0, label = "Remove move " .. (index0 + 1) }
    end
    if #mon.moves < 4 then
      rows[#rows + 1] = { role = "action", targetId = "party:move:add", label = "Add move" }
    end
  else
    local origin, met = mon.origin, mon.met
    local genders = { { key = "0", label = "Male" }, { key = "1", label = "Female" } }
    integer("trainerId", "Trainer ID", origin.trainerId, 0, 4294967295, "hex", "origin")
    textName("trainerName", "Trainer name", origin.trainerName, "player", {
      kind = "player",
      gender = origin.trainerGender,
    })
    choice("trainerGender", "Trainer gender", tostring(origin.trainerGender), genders, "origin", "integer")
    choice(
      "game",
      "Origin game",
      origin.game,
      self:_catalogOptions(HgssMonService.GAMES, function(key)
        return key
      end, true),
      "origin"
    )
    choice(
      "language",
      "Language",
      origin.language,
      self:_catalogOptions(HgssMonService.LANGUAGES, function(key)
        return key
      end, true),
      "origin"
    )
    local ballOptions = {}
    for _, key in ipairs(context.itemCatalog:itemKeys()) do
      if context.itemCatalog:item(key).pocket == "balls" then
        ballOptions[#ballOptions + 1] = { key = key, label = context.itemCatalog:item(key).name or key }
      end
    end
    choice("ball", "Ball", origin.ball, ballOptions, "origin")
    integer("location", "Met location", met.location, 0, 65535, nil, "met")
    integer("year", "Met year", met.date.year, 2000, 2255, nil, "met")
    integer("month", "Met month", met.date.month, 1, 12, nil, "met")
    integer("day", "Met day", met.date.day, 1, 31, nil, "met")
    integer("level", "Met level", met.level, 1, 100, nil, "met")
    integer("terrain", "Met terrain", met.terrain, 0, 255, nil, "met")
  end
  return rows
end

function State:_catalogOptions(keys, labelFor, numericKeys)
  local options = {}
  for key, value in pairs(keys) do
    local optionKey = numericKeys and key or value
    if numericKeys then
      optionKey = key
    elseif type(keys) == "table" and type(key) == "number" then
      optionKey = value
    end
    local textKey = tostring(optionKey)
    options[#options + 1] = { key = textKey, label = labelFor(textKey) }
  end
  table.sort(options, function(a, b)
    return a.key < b.key
  end)
  return options
end

function State:_bagView()
  local context = assert(self.dependencies.context)
  local itemCatalog = assert(context.itemCatalog)
  local pocketKeys = {}
  for key in pairs(ItemAssetSchema.POCKETS) do
    pocketKeys[#pocketKeys + 1] = key
  end
  table.sort(pocketKeys, function(a, b)
    return itemCatalog:pocket(a).nativeId < itemCatalog:pocket(b).nativeId
  end)
  local pockets = {}
  for _, key in ipairs(pocketKeys) do
    pockets[#pockets + 1] = { key = key, label = itemCatalog:pocketName(key) }
  end
  local snapshot = self.session:bagSnapshot(self.controller.bagPocket)
  local rows = {}
  for _, entry in ipairs(snapshot) do
    rows[#rows + 1] = {
      item = entry.item,
      label = itemCatalog:item(entry.item).name or entry.item,
      quantity = entry.quantity,
    }
  end
  local selectedQuantity = nil
  for _, row in ipairs(rows) do
    if row.item == self.controller.bagItemKey then
      selectedQuantity = row.quantity
      break
    end
  end
  return {
    bagPocket = self.controller.bagPocket,
    bagPocketLabel = itemCatalog:pocketName(self.controller.bagPocket),
    bagPockets = pockets,
    bagRows = rows,
    bagSelectedItem = self.controller.bagItemKey,
    bagSelectedQuantity = selectedQuantity,
  }
end

function State:_openEditor(descriptor)
  assert(type(descriptor) == "table" and type(descriptor.kind) == "string")
  local options = { kind = descriptor.kind }
  if descriptor.kind == "integer" then
    options.value = descriptor.value
    options.min = descriptor.min
    options.max = descriptor.max
    options.base = descriptor.base
  elseif descriptor.kind == "choice" then
    options.options = descriptor.options
    options.value = descriptor.value
  else
    options.nameKind = descriptor.nameKind
    options.maxLength = descriptor.nameKind == "pokemon" and 10 or 7
    options.initialText = descriptor.value
    options.charmap = assert(self.dependencies.context.charmap)
    options.subject = descriptor.subject
  end
  self.valueEditor = ValueEditor.new(options)
  self.activeDraftField = descriptor
end

function State:_partyField(targetId)
  local view = self:_snapshot()
  for _, row in ipairs(view.partyRows) do
    if row.targetId == targetId then
      return row.editor
    end
  end
  return nil
end

function State:_setDraftValue(descriptor, value)
  local draft = assert(self.monDraft, "raw Party fields require an active draft")
  if descriptor.setter == "iv" then
    return draft:setIV(descriptor.fieldId:sub(4), value)
  elseif descriptor.setter == "ev" then
    return draft:setEV(descriptor.fieldId:sub(4), value)
  elseif descriptor.setter == "move" then
    local slot0, component = descriptor.fieldId:match("^move:(%d+):(.+)$")
    assert(slot0 ~= nil and component ~= nil, "move field descriptor carries its slot and component")
    local moveSlot0 = assert(tonumber(slot0))
    assert(moveSlot0 % 1 == 0, "move slot index is an integer")
    ---@cast moveSlot0 integer
    return draft:setMove(moveSlot0, component, value)
  elseif descriptor.setter == "origin" then
    return draft:setOrigin(descriptor.fieldId, value)
  elseif descriptor.setter == "met" then
    return draft:setMet(descriptor.fieldId, value)
  end
  return draft:setScalar(descriptor.fieldId, value)
end

function State:_finishValueEditor()
  local editor = self.valueEditor
  if editor == nil then
    return
  end
  local result = editor:result()
  if result == nil then
    return false
  end
  local purpose = self.valuePurpose
  local descriptor = self.activeDraftField
  if result.kind == "cancel" then
    self.valueEditor, self.valuePurpose, self.activeDraftField = nil, nil, nil
    self.pendingQuantity = nil
    if purpose == "party_add_species" then
      self.controller.focus = self.controller.partyReturnFocus or "party:add"
      self.controller.partyReturnFocus = nil
    end
    return true
  end
  if purpose == "money" then
    local changed = self.session:setMoney(result.value)
    if not changed.ok then
      self.errorMessage = message(changed.error)
      editor:retry()
      return false
    end
  elseif purpose == "party_add_species" then
    if not self:_beginMonAdd(result.value) then
      editor:retry()
      return false
    end
  elseif purpose == "party_add_move" then
    if not self.monDraft:addMove(result.value) then
      self.errorMessage = "That move cannot be added to this member."
      editor:retry()
      return false
    else
      self.errorMessage = nil
    end
  elseif purpose == "bag_pocket" then
    self.controller:selectBagPocket(result.value)
  elseif purpose == "bag_add_item" then
    self.controller:selectBagItem(result.value)
    self:_openBagQuantity("add")
  elseif purpose == "bag_quantity" then
    local pending = assert(self.pendingQuantity)
    if pending.mode == "add" and result.value == 0 then
      self.errorMessage = "Add item must set a quantity above zero."
    elseif result.value == 0 then
      self.pendingRemove = { kind = "bag", itemKey = pending.itemKey }
      self.controller:openModal("remove")
    else
      if not self:_publishBagQuantity(pending.itemKey, result.value) then
        editor:retry()
        return false
      end
    end
    self.pendingQuantity = nil
  elseif descriptor ~= nil and self.monDraft ~= nil then
    local value = result.value
    if descriptor.convert == "integer" then
      value = assert(tonumber(value))
    end
    if not self:_setDraftValue(descriptor, value) then
      self.errorMessage = "That value is not valid for this field."
      editor:retry()
      return false
    end
  end
  self.valueEditor, self.valuePurpose, self.activeDraftField = nil, nil, nil
  return true
end

function State:_beginMonAdd(species)
  local world = assert(self.dependencies.world)
  local currentMapId = self.session:snapshot().location.mapId
  local map = assert(world.maps[world.byId[currentMapId]], "current map must be present in structural world data")
  local date = self.dateProvider()
  local draft, draftError = self.session:beginMonAdd(species, {
    location = assert(map.mapSectionNativeId),
    date = date,
  })
  if draft == nil then
    self.errorMessage = message(assert(draftError))
    return false
  end
  self.monDraft = draft
  self.controller:openPartyDraft("add", nil)
  self.errorMessage = nil
  return true
end

function State:_beginBagAdd()
  local catalog = assert(self.dependencies.context.itemCatalog)
  local options = {}
  for _, key in ipairs(catalog:itemKeys()) do
    local item = catalog:item(key)
    if key ~= "NONE" and item.pocket == self.controller.bagPocket then
      options[#options + 1] = { key = key, label = item.name or key }
    end
  end
  if #options == 0 then
    self.errorMessage = "This pocket has no items to add."
    return
  end
  self.valuePurpose = "bag_add_item"
  self.valueEditor = ValueEditor.new({ kind = "choice", options = options })
end

function State:_openBagQuantity(mode)
  local itemKey = assert(self.controller.bagItemKey)
  local catalog = assert(self.dependencies.context.itemCatalog)
  local item = catalog:item(itemKey)
  local pocket = catalog:pocket(item.pocket)
  local current = self:_bagView().bagSelectedQuantity or 0
  self.pendingQuantity = { itemKey = itemKey, mode = mode }
  self.valuePurpose = "bag_quantity"
  self.valueEditor = ValueEditor.new({
    kind = "integer",
    value = mode == "add" and current + 1 or current,
    min = 0,
    max = pocket.maxQuantity,
    base = "decimal",
  })
end

function State:_publishBagQuantity(itemKey, quantity)
  local result = self.session:setBagQuantity(itemKey, quantity)
  if not result.ok then
    self.errorMessage = message(result.error)
    return false
  else
    self.errorMessage = nil
    return true
  end
end

function State:_resolve(view)
  return self.presentation:resolve(self.displayContext:measure(self.width, self.height), view)
end

function State:_updateLocationService()
  local service = self.locationService
  if service == nil then
    return
  end
  local navigation = self.controller:locationSnapshot()
  local mapId = navigation.mapId
  if mapId == nil then
    return
  end
  if self.locationServiceMapId ~= mapId then
    service:openMap(mapId)
    self.locationServiceMapId = mapId
    self.locationViewport = nil
  end

  local plan = self:_resolve(self:_snapshot())
  local grid = plan.content.layout.locationGrid
  local center = assert(navigation.center, "Location viewport needs a center")
  local viewport = {
    centerX = center.fieldX,
    centerZ = center.fieldZ,
    widthTiles = grid and grid.columns or 1,
    heightTiles = grid and grid.rows or 1,
  }
  local previous = self.locationViewport
  if
    previous == nil
    or previous.centerX ~= viewport.centerX
    or previous.centerZ ~= viewport.centerZ
    or previous.widthTiles ~= viewport.widthTiles
    or previous.heightTiles ~= viewport.heightTiles
  then
    service:setViewport(viewport.centerX, viewport.centerZ, viewport.widthTiles, viewport.heightTiles)
    self.locationViewport = viewport
  end
  service:update()
end

function State:_syncLocationToSession()
  local current = assert(self.session:snapshot().location)
  self.controller:enterLocation(current)
  self.locationActionStatus = nil
  self.locationServiceMapId = nil
  self.locationViewport = nil
end

function State:_locationGridSize()
  local layout = self:_resolve(self:_snapshot()).content.layout
  local grid = layout.locationGrid
  return grid and grid.columns or 1, grid and grid.rows or 1
end

function State:_selectLocationTile(fieldX, fieldZ)
  local service = assert(self.locationService, "ready Location input needs its service")
  local navigation = self.controller:locationSnapshot()
  local mapId = assert(navigation.mapId)
  local placement, status = service:resolve(mapId, fieldX, fieldZ, service:snapshot().generation)
  self.locationActionStatus = status
  if placement == nil then
    self.errorMessage = status.reason
      or (status.state == "pending" and "Preparing destination data." or "Destination unavailable.")
    return
  end
  local result = self.session:setLocation(placement)
  if not result.ok then
    self.errorMessage = message(result.error)
    self.locationActionStatus = { state = "unavailable", reason = self.errorMessage }
    return
  end
  self.errorMessage = nil
  self.locationActionStatus = { state = "ready" }
end

function State:_prepareLocationForSave()
  local session = assert(self.session)
  local snapshot = session:snapshot()
  if not snapshot.locationChanged then
    return true
  end
  local location = snapshot.location
  local maps = assert(self.dependencies.world.maps)
  local record =
    assert(maps[self.dependencies.world.byId[location.mapId]], "staged map must be in structural world data")
  self.controller:chooseLocationMap(location.mapId, location.fieldX, location.fieldZ)
  self.locationServiceMapId = nil
  self.locationViewport = nil
  self:_updateLocationService()
  local placement, status = self.locationService:resolve(
    location.mapId,
    location.fieldX,
    location.fieldZ,
    self.locationService:snapshot().generation
  )
  self.locationActionStatus = status
  if placement == nil then
    self.errorMessage = status.reason
      or (
        status.state == "pending" and "Preparing destination data. Save again when it is ready."
        or "The destination is unavailable."
      )
    return false
  end
  if
    record.id ~= placement.mapId
    or location.fieldX ~= placement.fieldX
    or location.fieldZ ~= placement.fieldZ
    or location.surfaceId ~= placement.surfaceId
    or location.worldY ~= placement.worldY
    or location.terrainDependencyHash ~= placement.terrainDependencyHash
  then
    self.locationActionStatus = { state = "unavailable", reason = "destination_changed_during_resolution" }
    self.errorMessage = "The destination changed while it was being checked. Review it and save again."
    return false
  end
  self.errorMessage = nil
  return true
end

function State:_sendResult()
  if self.resultSent then
    return
  end
  self.resultSent = true
  self.onResult({ kind = "main_menu" })
end

function State:_requestDraftResolution(action)
  if self.monDraft == nil then
    self:_performDeferred(action)
    return false
  end
  local dirty = self.monDraft:mode() == "add" or self.monDraft:isDirty()
  if not dirty then
    self.monDraft = nil
    self:_performDeferred(action)
    return false
  end
  self.pendingDraftAction = action
  self.controller:openModal("draft")
  return true
end

function State:_performDeferred(action)
  if action == nil then
    return
  elseif action.kind == "back" then
    if self.session and self.session:isDirty() then
      self:requestClose("back")
    else
      self:_sendResult()
    end
  elseif action.kind == "section" then
    self.controller:setSection(action.section)
    if action.section == "Progress" then
      self.controller.focus = "flag:" .. self:_firstFlagName()
    elseif action.section == "Location" and self.locationService then
      self:_updateLocationService()
    end
    self.errorMessage = nil
  elseif action.kind == "save" then
    self:_save(false)
  elseif action.kind == "session-discard" then
    self:_discard(false)
  elseif action.kind == "party-slot" then
    self.controller:selectPartySlot(action.slot0)
  elseif action.kind == "party-detail" then
    if self.controller.partySlot0 ~= nil then
      self.controller.partyPage = "detail"
      self.controller.focus = "party:edit"
    else
      self.controller.partyPage = "list"
      self.controller.focus = "party:add"
    end
  elseif action.kind == "location-page" then
    self.errorMessage = nil
  elseif action.kind == "location-map-select" then
    local world = assert(self.dependencies.world)
    local record = world.maps[assert(world.byId[action.mapId], "selected map must be in structural world data")]
    self.controller:chooseLocationMap(action.mapId, record.worldOriginX + 16, record.worldOriginZ + 16)
    self.locationServiceMapId = nil
    self.locationViewport = nil
    self.locationActionStatus = nil
    self.errorMessage = nil
    self:_updateLocationService()
  elseif action.kind == "location-map-move" then
    local plan = self:_resolve(self:_snapshot())
    local layout = plan.content.layout
    local maps = self.locationService:listMaps()
    if action.direction == "up" or action.direction == "down" then
      local currentIndex
      for index, map in ipairs(maps) do
        if self.controller.focus == "location:map:" .. map.mapId then
          currentIndex = index
          break
        end
      end
      local delta = action.direction == "down" and 1 or -1
      if currentIndex == nil then
        currentIndex = delta > 0 and 0 or (#maps + 1)
      end
      currentIndex = math.max(1, math.min(#maps, currentIndex + delta))
      self.controller.focus = "location:map:" .. maps[currentIndex].mapId
      local visible = 0
      for targetId in pairs(layout.targets) do
        if targetId:match("^location:map:%d+$") then
          visible = visible + 1
        end
      end
      visible = math.max(1, visible)
      if currentIndex <= self.controller.locationMapOffset then
        self.controller.locationMapOffset = currentIndex - 1
      elseif currentIndex > self.controller.locationMapOffset + visible then
        self.controller.locationMapOffset = currentIndex - visible
      end
    else
      self.controller:moveFocus(layout.focusable, action.direction)
    end
  elseif action.kind == "location-cursor-move" then
    local width, height = self:_locationGridSize()
    self.controller:moveLocationCursor(action.direction, width, height)
    self:_updateLocationService()
  elseif action.kind == "location-pan" then
    if action.centerX ~= nil and action.centerZ ~= nil then
      self.controller.locationCenterX = action.centerX
      self.controller.locationCenterZ = action.centerZ
    else
      local width, height = self:_locationGridSize()
      self.controller:panLocation(action.direction, width, height)
    end
    self:_updateLocationService()
  elseif action.kind == "location-zoom" then
    self:_updateLocationService()
  elseif action.kind == "select_tile" then
    self:_selectLocationTile(action.fieldX, action.fieldZ)
  end
end

function State:_resolveDraftChoice(action)
  local draft = assert(self.monDraft)
  if action == "cancel" then
    self.controller.modal = nil
    self.pendingDraftAction = nil
    return
  elseif action == "apply" then
    local canonical, validationError = draft:validate()
    if canonical == nil then
      self.errorMessage = message(assert(validationError))
      return
    end
    local result = self.session:applyMonDraft(draft)
    if not result.ok then
      self.errorMessage = message(result.error)
      return
    end
  elseif action ~= "discard" then
    return
  end
  local previous = draft
  self.monDraft = nil
  self.errorMessage = nil
  if previous:mode() == "add" and action == "discard" then
    self.controller.partyPage = "list"
    self.controller.partySlot0 = nil
    self.controller.focus = "party:add"
  elseif previous:mode() == "add" then
    local members = self.session:partySnapshot().members
    local added = assert(members[#members], "applied new member must appear in the party")
    self.controller.partySlot0 = added.slot0
    self.controller.partyPage = "detail"
    self.controller.focus = "party:edit"
  else
    self.controller.partyPage = "detail"
    self.controller.focus = "party:edit"
  end
  self.controller.modal = nil
  local pending = self.pendingDraftAction
  self.pendingDraftAction = nil
  self:_performDeferred(pending)
end

function State:_confirmRemoval()
  local pending = assert(self.pendingRemove)
  self.pendingRemove = nil
  self.controller.modal = nil
  if pending.kind == "party" then
    local result = self.session:removePartyMon(pending.slot0)
    if not result.ok then
      self.errorMessage = message(result.error)
      return
    end
    self.controller.partyPage = "list"
    self.controller.partySlot0 = nil
    self.controller.focus = "party:add"
  else
    self:_publishBagQuantity(pending.itemKey, 0)
    self.controller.bagItemKey = nil
  end
end

function State:_save(leave)
  if not self.session then
    return false
  end
  if not self:_prepareLocationForSave() then
    if leave and self.closeRequest ~= nil then
      self.closeRequest.phase = "confirm"
    end
    return false
  end
  local result = self.session:save(self.valueEditor ~= nil or self.monDraft ~= nil)
  if not result.ok then
    self.errorMessage = message(result.error)
    if leave and self.closeRequest ~= nil then
      self.closeRequest.phase = "confirm"
    end
    return false
  end
  self.errorMessage = nil
  self:_syncLocationToSession()
  if leave then
    local request = self.closeRequest
    self.closeRequest = nil
    self.controller.modal = nil
    if request ~= nil and request.reason == "quit" then
      self.approvedExit = true
      love.event.quit(0)
    else
      self:_sendResult()
    end
  end
  return true
end

function State:_discard(leave)
  local request = self.closeRequest
  if self.valueEditor then
    self.valueEditor:cancel()
    self.valueEditor = nil
  end
  self.valuePurpose, self.activeDraftField = nil, nil
  if self.session then
    self.session:discard()
  end
  if self.session then
    self:_syncLocationToSession()
  end
  self.monDraft = nil
  self.pendingDraftAction = nil
  self.closeRequest = nil
  self.pendingRemove = nil
  self.pendingQuantity = nil
  self.errorMessage = nil
  self.controller.partyPage = "list"
  self.controller.partySubpage = "Identity"
  self.controller.partySlot0 = nil
  self.controller.bagItemKey = nil
  self.controller.partyReturnFocus = nil
  if self.controller.section == "Party" then
    self.controller.focus = "party:add"
  elseif self.controller.section == "Bag" then
    self.controller.focus = "bag:pocket:" .. self.controller.bagPocket
  end
  if leave then
    self.controller.modal = nil
    if request ~= nil and request.reason == "quit" then
      self.approvedExit = true
      love.event.quit(0)
    else
      self:_sendResult()
    end
  end
end

function State:_requestBack()
  if self.valueEditor then
    self.valueEditor:cancel()
    self.valueEditor = nil
    self.valuePurpose = nil
    self.activeDraftField = nil
    self.controller:cancelInteraction()
  elseif self.monDraft ~= nil then
    self:_requestDraftResolution({ kind = "back" })
  elseif self.controller.section == "Party" and self.controller.partyPage == "detail" then
    self.controller:closePartyDetail()
  elseif self.controller.section == "Bag" and self.controller.bagItemKey ~= nil then
    self.controller.bagItemKey = nil
    self.controller.focus = "bag:pocket:" .. self.controller.bagPocket
  elseif self.session and self.session:isDirty() then
    self:requestClose("back")
  else
    self:_sendResult()
  end
end

function State:requestClose(reason)
  assert(reason == "back" or reason == "quit", "save editor close reason is invalid")
  if self.approvedExit then
    return false
  end
  if self.disposed then
    return false
  end
  if self.closeRequest ~= nil then
    return true
  end
  local draftPending = self.monDraft ~= nil and (self.monDraft:mode() == "add" or self.monDraft:isDirty())
  if self.valueEditor ~= nil or draftPending or (self.session and self.session:isDirty()) then
    self.closeRequest = {
      reason = reason,
      phase = "confirm",
      previousModal = self.controller.modal,
      previousFocus = self.controller.focus,
    }
    self.controller:openModal("leave")
    return true
  elseif reason == "back" then
    self:_sendResult()
  end
  return false
end

function State:_performClose(action)
  local request = self.closeRequest
  if request == nil or request.phase ~= "confirm" then
    return
  end
  if action == "discard" then
    request.phase = "saving"
    self:_discard(true)
    return
  end
  request.phase = "saving"
  if self.valueEditor ~= nil then
    local submitted, reason = self.valueEditor:submit()
    if not submitted then
      self.errorMessage = reason or "Finish or cancel the open value before saving."
      request.phase = "confirm"
      return
    end
    if not self:_finishValueEditor() then
      request.phase = "confirm"
      return
    end
  end
  if self.monDraft ~= nil then
    local draft = assert(self.monDraft)
    local canonical, validationError = draft:validate()
    if canonical == nil then
      self.errorMessage = message(assert(validationError))
      request.phase = "confirm"
      return
    end
    local result = assert(self.session):applyMonDraft(draft)
    if not result.ok then
      self.errorMessage = message(result.error)
      request.phase = "confirm"
      return
    end
    self.monDraft = nil
  end
  if not self:_save(true) and self.closeRequest ~= nil then
    self.closeRequest.phase = "confirm"
  end
end

function State:onImportAttempt()
  self.notice = "Close the editor before importing another ROM."
end

function State:_activate(targetId)
  if self.status == "error" then
    if targetId == "retry" then
      self.generation = self.generation + 1
      self.status, self.errorMessage = "opening", nil
    elseif targetId == "back" then
      self:_sendResult()
    end
    return
  end
  if self.valueEditor and self.controller.modal == nil then
    local valueKind = self.valueEditor:snapshot().kind
    local digitAction = targetId:match("^digit%-(.+)$")
    if digitAction then
      self.valueEditor:press(digitAction)
    elseif targetId == "page-next" then
      self.valueEditor:press("page_next")
    elseif targetId == "page-previous" then
      self.valueEditor:press("page_previous")
    elseif valueKind == "name" then
      local controlId = targetId:match("^name%-control:(.+)$")
      self.valueEditor:activateTarget(controlId or targetId)
    elseif targetId == "confirm" then
      self.valueEditor:press("confirm")
    else
      self.valueEditor:activateTarget(targetId)
    end
    self:_finishValueEditor()
    return
  end
  if self.controller.modal then
    if self.controller.modal == "draft" then
      self:_resolveDraftChoice(targetId)
    elseif self.controller.modal == "remove" then
      if targetId == "remove" then
        self:_confirmRemoval()
      elseif targetId == "cancel" then
        self.pendingRemove = nil
        self.controller.modal = nil
      end
    elseif targetId == "cancel" then
      if self.controller.modal == "leave" and self.closeRequest ~= nil then
        local request = assert(self.closeRequest)
        self.closeRequest = nil
        self.controller.modal = request.previousModal
        self.controller.focus = request.previousFocus
      else
        self.controller.modal = nil
      end
    elseif targetId == "discard" then
      if self.closeRequest ~= nil then
        self:_performClose("discard")
      else
        self:_discard(false)
      end
    elseif targetId == "save" then
      if self.closeRequest ~= nil then
        self:_performClose("save")
      else
        self:_save(true)
      end
    end
    return
  end
  local section = targetId:match("^section:(.+)$")
  if targetId == "section" then
    local sections = { "Location", "Player", "Party", "Bag", "Progress" }
    local current = 1
    for index, value in ipairs(sections) do
      if value == self.controller.section then
        current = index
        break
      end
    end
    section = sections[current % #sections + 1]
  end
  if section ~= nil then
    self:_requestDraftResolution({ kind = "section", section = section })
    return
  end
  if targetId == "group-previous" then
    self:_cycleFlagFilter(-1)
    return
  elseif targetId == "group-next" then
    self:_cycleFlagFilter(1)
    return
  elseif targetId == "filter-named" then
    self.controller.flagFilter = self.controller.flagFilter == "Named" and "All" or "Named"
    self.controller.flagGroup = nil
    self.controller.focus = "flag:" .. self:_firstFlagName()
    self.controller.scrollOffset = 0
    return
  end
  if targetId == "money" then
    local money = assert(self.session:snapshot().money)
    self.valueEditor =
      ValueEditor.new({ kind = "integer", value = money, min = 0, max = PlayerData.MAX_MONEY, base = "decimal" })
    self.valuePurpose = "money"
    self._pointerOpenedValue = self._pointerDispatching == true
  elseif targetId:sub(1, 5) == "flag:" then
    local name = targetId:sub(6)
    local current = self.session:snapshot().flags[FieldScriptSymbols.flagsByName[name]] == true
    local result = self.session:setFlag(name, not current)
    if not result.ok then
      self.errorMessage = message(result.error)
    end
  elseif targetId == "save" then
    self:_requestDraftResolution({ kind = "save" })
  elseif targetId == "discard" then
    self:_requestDraftResolution({ kind = "session-discard" })
  elseif targetId == "back" then
    self:_requestBack()
  elseif targetId:match("^party:slot:") then
    local slot0 = assert(tonumber(targetId:match("^party:slot:(%d+)$")))
    self:_requestDraftResolution({ kind = "party-slot", slot0 = slot0 })
  elseif targetId == "party:add" then
    local catalog = assert(self.dependencies.context.monCatalog)
    local options = self:_catalogOptions(catalog:speciesKeys(), function(key)
      return catalog:species(key).name or key
    end)
    self.controller.partyReturnFocus = self.controller.focus
    self.valuePurpose = "party_add_species"
    self.valueEditor = ValueEditor.new({ kind = "choice", options = options })
  elseif targetId == "party:edit" then
    local slot0 = assert(self.controller.partySlot0)
    local draft, draftError = self.session:beginMonEdit(slot0)
    if draft == nil then
      self.errorMessage = message(assert(draftError))
    else
      self.monDraft = draft
      self.controller:openPartyDraft("edit", slot0)
      self.errorMessage = nil
    end
  elseif targetId:match("^party:field:") then
    local descriptor = self:_partyField(targetId)
    if descriptor ~= nil then
      self:_openEditor(descriptor)
      self.valuePurpose = "party_field"
    end
  elseif targetId == "party:clear-nickname" then
    if not self:_setDraftValue({ setter = "scalar", fieldId = "nickname" }, nil) then
      self.errorMessage = "Nickname could not be cleared."
    else
      self.errorMessage = nil
    end
  elseif targetId:match("^party:subpage:") then
    local subpage = assert(targetId:match("^party:subpage:(.+)$"))
    self.controller:selectPartySubpage(subpage)
  elseif targetId == "party:back" then
    if self.monDraft then
      self:_requestDraftResolution({ kind = "party-detail" })
    else
      self.controller:closePartyDetail()
    end
  elseif targetId == "party:apply" then
    self:_resolveDraftChoice("apply")
  elseif targetId == "party:discard" then
    self:_resolveDraftChoice("discard")
  elseif targetId == "party:cancel" then
    self:_requestDraftResolution({ kind = "party-detail" })
  elseif targetId == "party:remove" then
    self.pendingRemove = { kind = "party", slot0 = assert(self.controller.partySlot0) }
    self.controller:openModal("remove")
  elseif targetId == "party:move-up" or targetId == "party:move-down" then
    local slot0 = assert(self.controller.partySlot0)
    local other = targetId == "party:move-up" and slot0 - 1 or slot0 + 1
    local result = self.session:swapPartyMons(slot0, other)
    if not result.ok then
      self.errorMessage = message(result.error)
    else
      self.controller.partySlot0 = other
    end
  elseif targetId:match("^party:move:remove:") then
    local slot0 = assert(tonumber(targetId:match("^party:move:remove:(%d+)$")))
    if self.monDraft then
      assert(slot0 % 1 == 0, "move slot index is an integer")
      ---@cast slot0 integer
      self.monDraft:removeMove(slot0)
    end
  elseif targetId == "party:move:add" then
    local catalog = assert(self.dependencies.context.monCatalog)
    self.valuePurpose = "party_add_move"
    self.valueEditor = ValueEditor.new({
      kind = "choice",
      options = self:_catalogOptions(catalog:moveKeys(), function(key)
        return catalog:move(key).name or key
      end),
    })
  elseif targetId == "bag:pocket:choose" then
    local options = {}
    for _, pocket in ipairs(self:_bagView().bagPockets) do
      options[#options + 1] = { key = pocket.key, label = pocket.label }
    end
    self.valuePurpose = "bag_pocket"
    self.valueEditor = ValueEditor.new({ kind = "choice", options = options, value = self.controller.bagPocket })
  elseif targetId:match("^bag:pocket:") then
    local pocket = assert(targetId:match("^bag:pocket:(.+)$"))
    self.controller:selectBagPocket(pocket)
  elseif targetId:match("^bag:item:") then
    self.controller:selectBagItem(assert(targetId:match("^bag:item:(.+)$")))
  elseif targetId == "bag:add" then
    self:_beginBagAdd()
  elseif targetId == "bag:quantity" then
    self:_openBagQuantity("set")
  elseif targetId == "bag:remove" then
    self.pendingRemove = { kind = "bag", itemKey = assert(self.controller.bagItemKey) }
    self.controller:openModal("remove")
  end
end

function State:_firstFlagName()
  return assert(self:_flagRows({})[1], "field flags catalog is empty").name
end

function State:_moveFlagFocus(direction)
  local rows = self:_flagRows(self.session:snapshot().flags)
  if #rows == 0 then
    return
  end
  local current = 1
  for index, row in ipairs(rows) do
    if self.controller.focus == "flag:" .. row.name then
      current = index
      break
    end
  end
  current = math.max(1, math.min(#rows, current + direction))
  self.controller.focus = "flag:" .. rows[current].name
  local plan = self:_resolve(self:_snapshot())
  local layout = assert(plan.content.layout)
  local rowHeight = layout.viewport.height <= 200 and 22 or 34
  local visibleFlags = math.max(1, math.floor(layout.content.height / rowHeight) - 2)
  if current > self.controller.scrollOffset + visibleFlags then
    self.controller.scrollOffset = current - visibleFlags
  elseif current <= self.controller.scrollOffset then
    self.controller.scrollOffset = current - 1
  end
end

function State:_cycleFlagFilter(direction)
  local ordered = { "Named", "All" }
  local groups = {}
  for name in pairs(FieldScriptSymbols.flagsByName) do
    local group = name:sub(6, 6)
    if group:match("%a") then
      groups[group] = true
    end
  end
  for group in pairs(groups) do
    ordered[#ordered + 1] = group
  end
  table.sort(ordered, function(a, b)
    if a == "Named" then
      return true
    end
    if b == "Named" then
      return false
    end
    if a == "All" then
      return true
    end
    if b == "All" then
      return false
    end
    return a < b
  end)
  local current = self.controller.flagGroup or self.controller.flagFilter
  local index = 1
  for i, group in ipairs(ordered) do
    if group == current then
      index = i
      break
    end
  end
  local nextFilter = ordered[(index - 1 + direction) % #ordered + 1]
  self.controller.flagFilter = nextFilter == "All" and "All" or "Named"
  self.controller.flagGroup = nextFilter ~= "All" and nextFilter ~= "Named" and nextFilter or nil
  self.controller.scrollOffset = 0
  self.controller.focus = "flag:" .. self:_firstFlagName()
end

function State:_dispatchIntent(intent)
  if intent == nil then
    return
  end
  if intent.kind == "back" then
    self:_requestBack()
  elseif intent.kind == "activate" then
    self:_activate(intent.targetId)
  elseif intent.kind == "action" then
    self:_activate(intent.action)
  elseif
    intent.kind == "location-page"
    or intent.kind == "location-map-select"
    or intent.kind == "location-map-move"
    or intent.kind == "location-cursor-move"
    or intent.kind == "location-pan"
    or intent.kind == "location-zoom"
    or intent.kind == "select_tile"
  then
    self:_performDeferred(intent)
  elseif intent.kind == "cancel" then
    if intent.modal == "leave" and self.closeRequest ~= nil then
      local request = assert(self.closeRequest)
      self.closeRequest = nil
      self.controller.modal = request.previousModal
      self.controller.focus = request.previousFocus
    elseif self.valueEditor then
      self.valueEditor:cancel()
      self:_finishValueEditor()
    elseif intent.modal == "draft" then
      self:_resolveDraftChoice("cancel")
    elseif intent.modal == "remove" then
      self.pendingRemove = nil
    else
      self.controller.modal = nil
      self.pendingDraftAction = nil
    end
  elseif intent.kind == "move" then
    if self.width < 400 and (intent.direction == "left" or intent.direction == "right") then
      local sections = { "Location", "Player", "Party", "Bag", "Progress" }
      local current = 1
      for index, section in ipairs(sections) do
        if section == self.controller.section then
          current = index
          break
        end
      end
      local offset = intent.direction == "right" and 1 or -1
      local nextSection = sections[(current - 1 + offset) % #sections + 1]
      self:_requestDraftResolution({ kind = "section", section = nextSection })
    elseif self.controller.section == "Progress" then
      if intent.direction == "left" then
        self.controller.section = "Player"
        self.controller.focus = "money"
      elseif intent.direction == "right" then
        self:_cycleFlagFilter(1)
      elseif intent.direction == "up" or intent.direction == "down" then
        self:_moveFlagFocus(intent.direction == "down" and 1 or -1)
      end
    else
      local plan = self:_resolve(self:_snapshot())
      local focusable = assert(plan.content.layout).focusable
      self.controller:moveFocus(focusable, intent.direction)
      if self.controller.section == "Party" or self.controller.section == "Bag" then
        self:_revealFocusedRow(focusable)
      end
    end
    self.controller:cancelInteraction()
  end
end

function State:_revealFocusedRow(focusable)
  local _ = focusable
  local view = self:_snapshot()
  local rows = self.controller.section == "Party" and view.partyRows or view.bagRows
  local rowIndex
  for index, row in ipairs(rows or {}) do
    local targetId = row.targetId or ("bag:item:" .. row.item)
    if targetId == self.controller.focus then
      rowIndex = index
      break
    end
  end
  if rowIndex == nil then
    return
  end
  local layout = assert(self:_resolve(view).content.layout)
  local rowHeight = layout.viewport.height <= 200 and 22 or 34
  local visible = math.max(1, math.floor(layout.content.height / rowHeight) - 3)
  if rowIndex > self.controller.scrollOffset + visible then
    self.controller.scrollOffset = rowIndex - visible
  elseif rowIndex <= self.controller.scrollOffset then
    self.controller.scrollOffset = rowIndex - 1
  end
end

function State:_pointer(events)
  if self.disposed then
    return
  end
  local view = self:_snapshot()
  local plan = self:_resolve(view)
  local mapped = self.presentation:mapInput(events, view)
  for _, event in ipairs(mapped) do
    self._pointerDispatching = event.pointerId == "mouse:1"
    self:_dispatchIntent(self.controller:pointer(event))
    self._pointerDispatching = false
  end
  if self.disposed then
    return plan
  end
  self:_resolve(self:_snapshot())
  return plan
end

function State:view()
  local view = self:_snapshot()
  local plan = self:_resolve(view)
  view.presentation = plan
  view.layout = plan.content.layout
  return view
end

function State:draw()
  if self.disposed then
    return
  end
  local view = self:view()
  ApplicationPresentation.draw(
    self.renderer.graphics,
    { renderer = self.renderer, text = self.renderer.text },
    view,
    view.presentation
  )
end

function State:resize(width, height)
  self.width, self.height = width, height
  self.presentation:cancelPointers()
  self.controller:cancelInteraction()
  self.locationViewport = nil
end

function State:focus(focused)
  if not focused then
    self.presentation:cancelPointers()
    self.controller:cancelInteraction()
  end
end

function State:keypressed(key, _, isrepeat)
  if self.disposed or isrepeat then
    return
  end
  if self.status == "opening" and not HgssInputBindings.isCancelKey(key) then
    return
  end
  if self.valueEditor then
    if key == "home" then
      self.valueEditor:press("group_previous")
      return
    elseif key == "end" then
      self.valueEditor:press("group_next")
      return
    end
    if key == "pageup" then
      self.valueEditor:press("page_previous")
      return
    elseif key == "pagedown" then
      self.valueEditor:press("page_next")
      return
    end
    if (key == "return" or key == "kpenter") and self._pointerOpenedValue then
      self._pointerOpenedValue = false
    elseif key == "return" or key == "kpenter" then
      self:_activate("confirm")
    elseif key == "escape" then
      self.valueEditor:cancel()
      self:_finishValueEditor()
    elseif key == "backspace" then
      self.valueEditor:press("backspace")
    elseif key == "left" or key == "right" or key == "up" or key == "down" then
      self.valueEditor:press(key)
    end
    return
  end
  if self.controller.section == "Progress" and key == "home" then
    self:_cycleFlagFilter(-1)
    return
  elseif self.controller.section == "Progress" and key == "end" then
    self:_cycleFlagFilter(1)
    return
  end
  if self.controller.section == "Progress" and key == "backspace" then
    local glyphs = {}
    for glyph in Utf8Glyphs.iter(self.controller.query) do
      glyphs[#glyphs + 1] = glyph
    end
    if #glyphs > 0 then
      table.remove(glyphs)
      self.controller.query = table.concat(glyphs)
      self.controller.scrollOffset = 0
    end
    return
  end
  if self.controller.section == "Progress" and (#key == 1 or key == "space") then
    return
  end
  local action = key
  if HgssInputBindings.isCancelKey(key) then
    action = "back"
  elseif HgssInputBindings.isActionKey(key) then
    action = "confirm"
  end
  if self.controller.modal and (key == "left" or key == "right" or key == "up" or key == "down") then
    self:_dispatchIntent(self.controller:press(action))
  elseif self.status == "error" then
    self:_activate(key == "escape" and "back" or "retry")
  else
    self:_dispatchIntent(self.controller:press(action))
  end
end

function State:textinput(text)
  if self.valueEditor then
    self.valueEditor:textinput(text)
  elseif self.controller.section == "Progress" then
    self.controller.query = self.controller.query .. text
  end
end

function State:keyreleased() end

function State:gamepadpressed(_, button)
  local keys = { dpup = "up", dpdown = "down", dpleft = "left", dpright = "right", a = "confirm", b = "back" }
  local action = keys[button]
  if self.valueEditor then
    if action then
      self.valueEditor:press(action)
      self:_finishValueEditor()
    end
  elseif action then
    self:_dispatchIntent(self.controller:press(action))
  end
end

function State:gamepadreleased() end
function State:gamepadaxis() end

function State:mousepressed(x, y, button, istouch)
  if button == 1 and not istouch then
    self:_pointer({ { type = "pointer_down", pointerId = "mouse:1", x = x, y = y } })
  end
end
function State:mousemoved(x, y, _, _, istouch)
  if not istouch then
    self:_pointer({ { type = "pointer_move", pointerId = "mouse:1", x = x, y = y } })
  end
end
function State:mousereleased(x, y, button, istouch)
  if button == 1 and not istouch then
    self:_pointer({ { type = "pointer_up", pointerId = "mouse:1", x = x, y = y } })
  end
end
function State:touchpressed(id, x, y)
  self:_pointer({ { type = "pointer_down", pointerId = "touch:" .. tostring(id), x = x, y = y } })
end
function State:touchmoved(id, x, y)
  self:_pointer({ { type = "pointer_move", pointerId = "touch:" .. tostring(id), x = x, y = y } })
end
function State:touchreleased(id, x, y)
  self:_pointer({ { type = "pointer_up", pointerId = "touch:" .. tostring(id), x = x, y = y } })
end
function State:wheelmoved(_, y)
  local view = self:_snapshot()
  local rows = self.controller.section == "Party" and view.partyRows
    or self.controller.section == "Bag" and view.bagRows
    or self.controller.section == "Progress" and view.flagRows
    or {}
  self.controller.scrollOffset =
    math.max(0, math.min(math.max(0, #rows - 1), math.floor(self.controller.scrollOffset - y)))
end

function State:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  self.generation = self.generation + 1
  if self.locationService then
    self.locationService:dispose()
    self.locationService = nil
  end
  self.presentation:dispose()
  if self.renderer then
    self.renderer:dispose()
    self.renderer = nil
  end
  self.valueEditor = nil
  self.session = nil
  self.dependencies = nil
end

return State
