-- Coordinates the editor's asynchronous opening, input, session, and resources.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local HgssInputBindings = require("libs.hgss.src.ui.HgssInputBindings")
local FieldInput = require("libs.hgss.src.field.FieldInput")
local PlayerData = require("libs.hgss.src.save.PlayerData")
local DisplayContext = require("libs.ui.src.DisplayContext")
local Interface = require("app.src.saveeditor.SaveEditorInterface")
local Renderer = require("app.src.saveeditor.SaveEditorRenderer")
local Controller = require("app.src.saveeditor.SaveEditorController")
local ValueEditor = require("app.src.saveeditor.SaveEditorValueEditor")
local PartyView = require("app.src.saveeditor.SaveEditorPartyView")
local Draft = require("app.src.saveeditor.SaveEditorMonDraft")
local ScrollViewport = require("libs.ui.src.ScrollViewport")
local Composition = require("app.src.saveeditor.SaveEditorComposition")
local LocationService = require("app.src.saveeditor.SaveEditorLocationService")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
local ItemAssetSchema = require("libs.assets.src.ItemAssetSchema")

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
---@field preserveChoiceScroll boolean
---@field valueReturnFocus string?
---@field pendingFocusReturn string?
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
---@field closeRequest { reason: "back"|"quit", phase: "confirm"|"saving", previousModal: string?, previousModalReturnFocus: string?, previousFocus: string }?
---@field monDraft SaveEditorMonDraft?
---@field partyView SaveEditorPartyView?
---@field partyProjectionCache { partyRevision: integer, slot0: integer, value: SaveEditorMonProjection }?
---@field pendingDraftAction table<string, unknown>?
---@field activeDraftField table<string, unknown>?
---@field valuePurpose string?
---@field dateProvider fun(): table<string, integer>
---@field iconStatus string?
---@field iconFailure string?
---@field pendingLocationSave { operationId: integer, sessionRevision: integer, location: SaveEditorLocation, leave: boolean, closeReason: ("back"|"quit")?, verifier: SaveEditorLocationService }?
---@field locationSaveOperationId integer
---@field pendingRemove table<string, unknown>?
---@field pendingQuantity table<string, unknown>?
---@field fieldInput FieldInput
---@field inputTick integer
---@field tickRemainder number
---@field activeScopeId string?
---@field scopeEpoch integer
---@field editorFeedback string?
local State = {}
State.__index = State
local FIELD_DIRECTIONS = { up = "north", down = "south", left = "west", right = "east" }
local PRINTABLE_KEY_NAMES = {
  space = true,
  kpdecimal = true,
  kpdivide = true,
  kpmultiply = true,
  kpminus = true,
  kpplus = true,
  kpequals = true,
}

local function isPrintableKeyName(key)
  return (#key == 1 and key:match("^[%w%p ]$") ~= nil) or key:match("^kp%d$") ~= nil or PRINTABLE_KEY_NAMES[key] == true
end

local function sameLocation(left, right)
  return left.mapId == right.mapId
    and left.fieldX == right.fieldX
    and left.fieldZ == right.fieldZ
    and left.surfaceId == right.surfaceId
    and left.worldY == right.worldY
    and left.terrainDependencyHash == right.terrainDependencyHash
end

local function message(value)
  if Errors.is(value) then
    return value.message
  end
  return tostring(value)
end

local function filterLocationMaps(maps, query)
  local normalized = query:lower()
  if normalized == "" then
    return maps
  end
  local filtered = {}
  for _, map in ipairs(maps) do
    if
      map.symbol:lower():find(normalized, 1, true)
      or map.section:lower():find(normalized, 1, true)
      or tostring(map.mapId):find(normalized, 1, true)
    then
      filtered[#filtered + 1] = map
    end
  end
  return filtered
end

local function scrollOwner(controller, valueEditor)
  if controller.modal ~= nil then
    return nil
  end
  if valueEditor ~= nil and valueEditor:snapshot().kind == "choice" then
    return "value:choice"
  end
  if controller.section == "Location" and controller.locationPage == "map-list" then
    return "location:map-list"
  end
  if controller.section == "Party" then
    return "party"
  end
  if controller.section == "Bag" then
    return "bag"
  end
  if controller.section == "Progress" then
    return "flags"
  end
  return nil
end

local function scrollPurpose(viewportId, view)
  if viewportId == "party" then
    return "party:" .. view.partyPage .. ":" .. tostring(view.partySubpage or "list")
  elseif viewportId == "bag" then
    return "bag:" .. tostring(view.bagPocket)
  elseif viewportId == "flags" then
    return "flags:" .. tostring(view.flagGroup or view.flagFilter)
  elseif viewportId == "value:choice" then
    return "value:choice"
  end
  assert(viewportId == "location:map-list", "unknown save editor scroll viewport " .. viewportId)
  return nil
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
  local rendererOk, rendererOrError = pcall(Renderer.new, { text = text, versionId = options.versionId })
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
    pendingLocationSave = nil,
    locationSaveOperationId = 0,
    valueEditor = nil,
    preserveChoiceScroll = false,
    valueReturnFocus = nil,
    pendingFocusReturn = nil,
    errorMessage = nil,
    notice = nil,
    generation = 1,
    disposed = false,
    resultSent = false,
    approvedExit = false,
    closeRequest = nil,
    monDraft = nil,
    partyView = nil,
    partyProjectionCache = nil,
    pendingDraftAction = nil,
    activeDraftField = nil,
    valuePurpose = nil,
    dateProvider = dateProvider,
    iconStatus = nil,
    iconFailure = nil,
    pendingRemove = nil,
    pendingQuantity = nil,
    fieldInput = FieldInput.new(),
    inputTick = 0,
    tickRemainder = 0,
    activeScopeId = nil,
    scopeEpoch = 0,
    editorFeedback = nil,
  }, State)
  self.fieldInput:beginUi(self.inputTick)
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
  local allReady = true
  for _, name in ipairs({ "field-planning", "field-runtime" }) do
    local ready, failure = self.derivedAssets.requestMilestone(name, "required")
    if ready ~= true then
      if failure ~= nil then
        error(Errors.new("SAVE_EDITOR_ASSET_PREPARATION_FAILED", tostring(failure), { milestone = name }), 0)
      end
      allReady = false
    end
  end
  return allReady
end

function State:update(dt)
  if self.disposed then
    return
  end
  self.tickRemainder = self.tickRemainder + (dt or 0) * 60
  if self.tickRemainder >= 1 then
    self.inputTick = self.inputTick + math.floor(self.tickRemainder)
    self.tickRemainder = self.tickRemainder % 1
    self:_consumeUiInput(self.fieldInput:uiSnapshot(self.inputTick))
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
    self.partyView = PartyView.new(assert(graphOrError.context))
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
  if self.status == "ready" and self.pendingLocationSave then
    local updated, updateError = pcall(self._updatePendingLocationSave, self)
    if not updated then
      self:_cancelPendingLocationSave()
      error(updateError, 0)
    end
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
  local section = self.controller.section
  local flags = session and section == "Progress" and self:_flagRows(session.flags) or {}
  local party = session and section == "Party" and self:_partyView() or {}
  local bag = session and section == "Bag" and self:_bagView() or {}
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
    editorFeedback = self.editorFeedback,
    unappliedDraft = self.monDraft ~= nil,
    iconStatus = self.iconStatus,
    iconFailure = self.iconFailure,
    locationNavigation = self.controller:locationSnapshot(),
  }
  if self.locationService then
    local location = self.locationService:snapshot()
    local maps = self.locationService:listMaps()
    location.maps = self.controller.locationPage == "map-list" and filterLocationMaps(maps, self.controller.query)
      or maps
    location.symbol = location.map and location.map.symbol or nil
    location.actionStatus = self.locationActionStatus
        and {
          state = self.locationActionStatus.state,
          reason = self.locationActionStatus.reason,
        }
      or nil
    view.location = location
  end
  if session then
    view.savedLocation = session.originalLocation
    view.pendingLocation = session.locationChanged and session.location or nil
  end
  view.locationSave = self.pendingLocationSave
      and {
        operationId = self.pendingLocationSave.operationId,
        state = "pending",
        cancelTarget = "save",
      }
    or nil
  for key, value in pairs(party) do
    view[key] = value
  end
  for key, value in pairs(bag) do
    view[key] = value
  end
  local scopeId
  if self.controller.modal then
    scopeId = "decision:" .. self.controller.modal
  elseif self.valueEditor then
    local value = self.valueEditor:snapshot()
    local query = value.kind == "choice" and value.query or ""
    scopeId = "value:" .. (self.valuePurpose or "editor") .. ":" .. query
  elseif self.monDraft then
    scopeId = table.concat({
      "mon-draft",
      self.monDraft:mode(),
      tostring(self.controller.partySlot0),
      self.controller.partySubpage,
    }, ":")
  elseif self.controller.section == "Party" and self.controller.partyPage ~= "list" then
    scopeId = table.concat({
      "party-detail",
      tostring(self.controller.partySlot0),
      self.controller.partySubpage,
    }, ":")
  elseif self.controller.section == "Progress" then
    scopeId = table.concat({
      "section:Progress",
      self.controller.flagFilter,
      tostring(self.controller.flagGroup),
      self.controller.query,
    }, ":")
  elseif self.controller.section == "Bag" then
    scopeId = "section:Bag:" .. self.controller.bagPocket
  else
    scopeId = "section:" .. self.controller.section .. ":" .. self.controller.locationPage
    if self.controller.section == "Location" and self.controller.locationPage == "map-list" then
      scopeId = scopeId .. ":" .. self.controller.query
    end
  end
  if scopeId ~= self.activeScopeId then
    self.activeScopeId = scopeId
    self.scopeEpoch = self.scopeEpoch + 1
    self.fieldInput:beginUi(self.inputTick)
    self.controller:cancelInteraction()
  end
  self.controller.scopeId, self.controller.scopeEpoch = scopeId, self.scopeEpoch
  local scopeKind = self.controller.modal and "decision"
    or self.valueEditor and "value"
    or self.monDraft and "mon-draft"
    or self.controller.section == "Party" and self.controller.partyPage ~= "list" and "party-detail"
    or "section"
  view.scope = {
    id = scopeId,
    epoch = self.scopeEpoch,
    kind = scopeKind,
    focusId = self.controller.focus,
  }
  view.scrollOwner = scrollOwner(self.controller, self.valueEditor)
  view.preserveChoiceScroll = self.preserveChoiceScroll and view.scrollOwner == "value:choice"
  view.scrollOffsets = self.controller.scrollOffsets
  view.locationGridMode = self.controller.locationGridMode
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
  local partyView = assert(self.partyView, "ready Party view requires its catalog-backed row builder")
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
    local projection
    if self.monDraft then
      projection = self.monDraft:projection()
    else
      local cached = self.partyProjectionCache
      if cached and cached.partyRevision == snapshot.revision and cached.slot0 == controller.partySlot0 then
        projection = cached.value
      else
        projection = Draft.projectRecord(mon, { catalog = catalog })
        self.partyProjectionCache = {
          partyRevision = snapshot.revision,
          slot0 = assert(controller.partySlot0),
          value = projection,
        }
      end
    end
    local valid, validationError = mon, nil
    if self.monDraft then
      valid, validationError = self.monDraft:validate()
    end
    rows = PartyView.rows(partyView, mon, projection, controller.partySubpage, self.monDraft ~= nil, controller.focus)
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
  self:_cancelPendingLocationSave()
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
  self:_installValueEditor(ValueEditor.new(options), "party_field")
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
  self.preserveChoiceScroll = false
  local purpose = self.valuePurpose
  local descriptor = self.activeDraftField
  if result.kind == "cancel" then
    self.pendingFocusReturn = self.valueReturnFocus
    self.valueEditor, self.valuePurpose, self.activeDraftField = nil, nil, nil
    self.valueReturnFocus = nil
    if purpose == "bag_quantity" then
      self.pendingQuantity = nil
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
    local returnFocus = "bag:item:" .. result.value
    self.valueEditor, self.valuePurpose, self.activeDraftField = nil, nil, nil
    self.controller:selectBagItem(result.value)
    self.valueReturnFocus = returnFocus
    self:_openBagQuantity("add")
    return true
  elseif purpose == "bag_quantity" then
    local pending = assert(self.pendingQuantity)
    if pending.mode == "add" and result.value == 0 then
      self.errorMessage = "Add item must set a quantity above zero."
      editor:retry()
      return false
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
  self.pendingFocusReturn = self.valueReturnFocus
  self.valueEditor, self.valuePurpose, self.activeDraftField = nil, nil, nil
  self.valueReturnFocus = nil
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
  self:_installValueEditor(ValueEditor.new({ kind = "choice", options = options }), "bag_add_item")
end

function State:_openBagQuantity(mode)
  local itemKey = assert(self.controller.bagItemKey)
  local catalog = assert(self.dependencies.context.itemCatalog)
  local item = catalog:item(itemKey)
  local pocket = catalog:pocket(item.pocket)
  local current = self:_bagView().bagSelectedQuantity or 0
  self.pendingQuantity = { itemKey = itemKey, mode = mode }
  self:_installValueEditor(
    ValueEditor.new({
      kind = "integer",
      value = mode == "add" and current + 1 or current,
      min = 0,
      max = pocket.maxQuantity,
      base = "decimal",
    }),
    "bag_quantity",
    self.valueReturnFocus
  )
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
  view.textMetrics = assert(self.renderer):metrics()
  return self.presentation:resolve(self.displayContext:measure(self.width, self.height), view)
end

---@param preferred string?
function State:_reconcileFocus(preferred)
  local layout = self:_resolve(self:_snapshot()).content.layout
  local focus = preferred or self.pendingFocusReturn or self.controller.focus
  if focus == nil or layout.focusGraph[focus] == nil then
    focus = layout.defaultFocus
  end
  self.controller.focus = assert(focus)
  self.pendingFocusReturn = nil
end

---@param editor SaveEditorValueEditor
---@param purpose string
---@param returnFocus string?
function State:_installValueEditor(editor, purpose, returnFocus)
  assert(self.valueEditor == nil, "a value editor must be retired before its successor is installed")
  self.valueReturnFocus = returnFocus or self.controller.focus
  self.valueEditor = editor
  self.valuePurpose = purpose
  self.preserveChoiceScroll = false
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

function State:_prepareLocationForSave(leave)
  local session = assert(self.session)
  local snapshot = session:snapshot()
  if not snapshot.locationChanged then
    return true
  end
  local location = snapshot.location
  local maps = assert(self.dependencies.world.maps)
  assert(maps[self.dependencies.world.byId[location.mapId]], "staged map must be in structural world data")
  self:_startPendingLocationSave(snapshot, leave)
  return false
end

function State:_cancelPendingLocationSave()
  local pending = self.pendingLocationSave
  if pending == nil then
    return
  end
  self.pendingLocationSave = nil
  pending.verifier:dispose()
end

function State:_startPendingLocationSave(snapshot, leave)
  if self.pendingLocationSave then
    return
  end
  local location = snapshot.location
  local verifier = LocationService.new({
    cacheFs = assert(self.dependencies).cacheFs,
    world = self.dependencies.world,
    derivedAssets = self.derivedAssets,
    savedObjects = assert(self.dependencies.savedObjects),
  })
  local started, startError = pcall(function()
    verifier:openMap(location.mapId)
    verifier:setViewport(location.fieldX, location.fieldZ, 1, 1)
  end)
  if not started then
    verifier:dispose()
    error(startError, 0)
  end
  self.locationSaveOperationId = self.locationSaveOperationId + 1
  self.pendingLocationSave = {
    operationId = self.locationSaveOperationId,
    sessionRevision = snapshot.revision,
    location = {
      mapId = location.mapId,
      fieldX = location.fieldX,
      fieldZ = location.fieldZ,
      surfaceId = location.surfaceId,
      worldY = location.worldY,
      terrainDependencyHash = location.terrainDependencyHash,
    },
    leave = leave,
    closeReason = self.closeRequest and self.closeRequest.reason or nil,
    verifier = verifier,
  }
  self.errorMessage = nil
end

function State:_updatePendingLocationSave()
  local pending = self.pendingLocationSave
  if pending == nil or self.session == nil then
    return
  end
  local snapshot = self.session:snapshot()
  if snapshot.revision ~= pending.sessionRevision or not sameLocation(snapshot.location, pending.location) then
    self:_cancelPendingLocationSave()
    self.errorMessage = "The destination check was canceled after the save changed."
    if self.closeRequest then
      self.closeRequest.phase = "confirm"
    end
    return
  end
  pending.verifier:update()
  local readiness = pending.verifier:snapshot().status
  if readiness.state == "pending" then
    return
  end
  if readiness.state ~= "ready" then
    self:_cancelPendingLocationSave()
    self.errorMessage = readiness.reason or "The destination could not be verified."
    if self.closeRequest then
      self.closeRequest.phase = "confirm"
    end
    return
  end
  local placement, resolution = pending.verifier:resolve(
    pending.location.mapId,
    pending.location.fieldX,
    pending.location.fieldZ,
    pending.verifier:snapshot().generation
  )
  if placement == nil then
    self:_cancelPendingLocationSave()
    self.locationActionStatus = resolution
    self.errorMessage = resolution.reason or "The destination is unavailable."
    if self.closeRequest then
      self.closeRequest.phase = "confirm"
    end
    return
  end
  if not sameLocation(placement, pending.location) then
    self:_cancelPendingLocationSave()
    self.locationActionStatus = { state = "unavailable", reason = "destination_changed_during_resolution" }
    self.errorMessage = "The destination changed while it was being checked. Review it and save again."
    if self.closeRequest then
      self.closeRequest.phase = "confirm"
    end
    return
  end
  if
    self.pendingLocationSave ~= pending
    or self.pendingLocationSave.operationId ~= pending.operationId
    or self.session:snapshot().revision ~= pending.sessionRevision
    or not sameLocation(self.session:snapshot().location, pending.location)
  then
    self:_cancelPendingLocationSave()
    self.errorMessage = "The destination check was canceled after the save changed."
    if self.closeRequest then
      self.closeRequest.phase = "confirm"
    end
    return
  end
  if self.valueEditor ~= nil or self.monDraft ~= nil then
    self:_cancelPendingLocationSave()
    self.errorMessage = "Finish or cancel the open edit before saving."
    if self.closeRequest then
      self.closeRequest.phase = "confirm"
    end
    return
  end
  self.pendingLocationSave = nil
  pending.verifier:dispose()
  local saved, saveError = self.session:save(false)
  if not saved.ok then
    self.errorMessage = message(saveError)
    if self.closeRequest then
      self.closeRequest.phase = "confirm"
    end
    return
  end
  self.errorMessage = nil
  if pending.leave then
    local request = self.closeRequest
    self.closeRequest = nil
    self.controller.modal = nil
    if request and request.reason == "quit" then
      self.approvedExit = true
      love.event.quit(0)
    else
      self:_sendResult()
    end
  end
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
    if action.page == "map-list" then
      self.controller.query = ""
      self.controller.locationMapOffset = 0
    end
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
    local view = self:_snapshot()
    local plan = self:_resolve(view)
    local layout = plan.content.layout
    local maps = assert(view.location).maps
    if #maps == 0 then
      self.controller.focus = "location:map-picker"
      return
    end
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
      local viewport = assert(layout.viewports["location:map-list"])
      self.controller.locationMapOffset = ScrollViewport.clamp(
        ScrollViewport.reveal(
          viewport.offset,
          viewport.clip.height,
          (currentIndex - 1) * viewport.rowExtent,
          viewport.rowExtent
        ),
        viewport.contentExtent,
        viewport.clip.height
      )
    else
      self.controller:moveFocus(layout.focusGraph, action.direction)
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
    self.controller:closeModal()
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
  self.controller:closeModal()
  local pending = self.pendingDraftAction
  self.pendingDraftAction = nil
  self:_performDeferred(pending)
end

function State:_confirmRemoval()
  local pending = assert(self.pendingRemove)
  self.pendingRemove = nil
  self.controller:closeModal()
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
  if self.pendingLocationSave then
    return false
  end
  if not self:_prepareLocationForSave(leave) then
    if self.pendingLocationSave then
      return false
    end
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
  self:_cancelPendingLocationSave()
  local request = self.closeRequest
  if self.valueEditor then
    self.valueEditor:cancel()
    self.valueEditor = nil
  end
  self.valuePurpose, self.activeDraftField = nil, nil
  self.valueReturnFocus, self.pendingFocusReturn = nil, nil
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
    self.pendingFocusReturn = self.valueReturnFocus
    self.valueEditor = nil
    self.valuePurpose = nil
    self.activeDraftField = nil
    self.valueReturnFocus = nil
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
  self:_cancelPendingLocationSave()
  if self.closeRequest ~= nil then
    if self.closeRequest.phase == "saving" then
      self.closeRequest.phase = "confirm"
    end
    return true
  end
  local draftPending = self.monDraft ~= nil and (self.monDraft:mode() == "add" or self.monDraft:isDirty())
  if self.valueEditor ~= nil or draftPending or (self.session and self.session:isDirty()) then
    self.closeRequest = {
      reason = reason,
      phase = "confirm",
      previousModal = self.controller.modal,
      previousModalReturnFocus = self.controller.modalReturnFocus,
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
    elseif targetId:sub(1, 7) == "choice:" then
      self.valueEditor:activateTarget(targetId:sub(8))
    elseif targetId == "clear-search" then
      self.valueEditor:press("clear_search")
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
        self.controller:closeModal()
      end
    elseif targetId == "cancel" then
      if self.controller.modal == "leave" and self.closeRequest ~= nil then
        self:_cancelPendingLocationSave()
        local request = assert(self.closeRequest)
        self.closeRequest = nil
        self.controller.modal = request.previousModal
        self.controller.modalReturnFocus = request.previousModalReturnFocus
        self.controller.focus = request.previousFocus
      else
        self.controller:closeModal()
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
      elseif self.pendingLocationSave then
        self:_cancelPendingLocationSave()
        self.errorMessage = "Destination verification canceled."
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
    self:_cancelPendingLocationSave()
    local money = assert(self.session:snapshot().money)
    self:_installValueEditor(
      ValueEditor.new({ kind = "integer", value = money, min = 0, max = PlayerData.MAX_MONEY, base = "decimal" }),
      "money"
    )
  elseif targetId:sub(1, 5) == "flag:" then
    local name = targetId:sub(6)
    local current = self.session:snapshot().flags[FieldScriptSymbols.flagsByName[name]] == true
    local result = self.session:setFlag(name, not current)
    if not result.ok then
      self.errorMessage = message(result.error)
    end
  elseif targetId == "save" then
    if self.pendingLocationSave then
      self:_cancelPendingLocationSave()
      self.errorMessage = "Destination verification canceled."
    else
      self:_requestDraftResolution({ kind = "save" })
    end
  elseif targetId == "discard" then
    self:_requestDraftResolution({ kind = "session-discard" })
  elseif targetId == "back" then
    self:_requestBack()
  elseif targetId:match("^party:slot:") then
    local slot0 = assert(tonumber(targetId:match("^party:slot:(%d+)$")))
    self:_requestDraftResolution({ kind = "party-slot", slot0 = slot0 })
  elseif targetId == "party:add" then
    self:_cancelPendingLocationSave()
    local catalog = assert(self.dependencies.context.monCatalog)
    local options = PartyView.options(assert(self.partyView), "species", function()
      return catalog:speciesKeys()
    end, function(key)
      return catalog:species(key).name or key
    end)
    self:_installValueEditor(ValueEditor.new({ kind = "choice", options = options }), "party_add_species")
  elseif targetId == "party:edit" then
    self:_cancelPendingLocationSave()
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
    self:_cancelPendingLocationSave()
    local catalog = assert(self.dependencies.context.monCatalog)
    self:_installValueEditor(
      ValueEditor.new({
        kind = "choice",
        options = PartyView.options(assert(self.partyView), "moves", function()
          return catalog:moveKeys()
        end, function(key)
          return catalog:move(key).name or key
        end),
      }),
      "party_add_move"
    )
  elseif targetId == "bag:pocket:choose" then
    self:_cancelPendingLocationSave()
    local options = {}
    for _, pocket in ipairs(self:_bagView().bagPockets) do
      options[#options + 1] = { key = pocket.key, label = pocket.label }
    end
    self:_installValueEditor(
      ValueEditor.new({ kind = "choice", options = options, value = self.controller.bagPocket }),
      "bag_pocket"
    )
  elseif targetId:match("^bag:pocket:") then
    local pocket = assert(targetId:match("^bag:pocket:(.+)$"))
    self.controller:selectBagPocket(pocket)
  elseif targetId:match("^bag:item:") then
    self.controller:selectBagItem(assert(targetId:match("^bag:item:(.+)$")))
  elseif targetId == "bag:add" then
    self:_cancelPendingLocationSave()
    self:_beginBagAdd()
  elseif targetId == "bag:quantity" then
    self:_cancelPendingLocationSave()
    self:_openBagQuantity("set")
  elseif targetId == "bag:remove" then
    self:_cancelPendingLocationSave()
    self.pendingRemove = { kind = "bag", itemKey = assert(self.controller.bagItemKey) }
    self.controller:openModal("remove")
  end
end

function State:_firstFlagName()
  return assert(self:_flagRows({})[1], "field flags catalog is empty").name
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
  self.controller.scrollOffsets["flags:" .. tostring(nextFilter)] = 0
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
      self:_cancelPendingLocationSave()
      local request = assert(self.closeRequest)
      self.closeRequest = nil
      self.controller.modal = request.previousModal
      self.controller.modalReturnFocus = request.previousModalReturnFocus
      self.controller.focus = request.previousFocus
    elseif self.valueEditor then
      self.valueEditor:cancel()
      self:_finishValueEditor()
    elseif intent.modal == "draft" then
      self:_resolveDraftChoice("cancel")
    elseif intent.modal == "remove" then
      self.pendingRemove = nil
      self.controller.modalReturnFocus = nil
    else
      self.controller:closeModal()
      self.pendingDraftAction = nil
    end
  elseif intent.kind == "scroll-drag" then
    local view = self:_snapshot()
    if intent.scopeId ~= view.scope.id or intent.scopeEpoch ~= view.scope.epoch then
      return
    end
    local layout = assert(self:_resolve(view).content.layout)
    self:_setScrollOffset(view, layout, intent.viewportId, intent.offset)
  elseif intent.kind == "move" then
    if
      self.width < 400
      and not self.controller.locationGridMode
      and (intent.direction == "left" or intent.direction == "right")
    then
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
    elseif self.controller.section == "Progress" and intent.direction == "right" then
      self:_cycleFlagFilter(1)
    else
      local plan = self:_resolve(self:_snapshot())
      local layout = assert(plan.content.layout)
      if layout.focusGraph[self.controller.focus] == nil then
        self.controller.focus = layout.defaultFocus
      end
      self.controller:moveFocus(layout.focusGraph, intent.direction)
      if
        self.controller.section == "Party"
        or self.controller.section == "Bag"
        or self.controller.section == "Progress"
      then
        self:_revealFocusedRow(layout.focusOrder)
      end
    end
    self.controller:cancelInteraction()
  end
end

function State:_revealFocusedRow(_)
  local view = self:_snapshot()
  local section = self.controller.section
  local rows = section == "Party" and view.partyRows
    or section == "Bag" and view.bagRows
    or section == "Progress" and view.flagRows
    or {}
  local rowIndex
  for index, row in ipairs(rows or {}) do
    local targetId = row.targetId or (section == "Bag" and ("bag:item:" .. row.item) or "flag:" .. row.name)
    if targetId == self.controller.focus then
      rowIndex = index
      break
    end
  end
  if rowIndex == nil then
    return
  end
  local layout = assert(self:_resolve(view).content.layout)
  local viewportId = section == "Party" and "party" or section == "Bag" and "bag" or "flags"
  local viewport = assert(layout.viewports[viewportId])
  local offset = ScrollViewport.reveal(
    viewport.offset,
    viewport.clip.height,
    (rowIndex - 1) * viewport.rowExtent,
    viewport.rowExtent
  )
  local purpose = section == "Party" and ("party:" .. view.partyPage .. ":" .. tostring(view.partySubpage or "list"))
    or section == "Bag" and ("bag:" .. tostring(view.bagPocket))
    or ("flags:" .. tostring(view.flagGroup or view.flagFilter))
  self.controller.scrollOffsets[purpose] = ScrollViewport.clamp(offset, viewport.contentExtent, viewport.clip.height)
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
  self:_reconcileFocus()
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
    self.fieldInput:clearAll()
    self.fieldInput:beginUi(self.inputTick)
  end
end

function State:_consumeUiInput(events)
  for _, event in ipairs(events) do
    if event.type == "navigate" then
      if self.controller.modal then
        self:_dispatchIntent(self.controller:press(event.direction))
      elseif self.valueEditor then
        local snapshot = self.valueEditor:snapshot()
        if snapshot.kind == "choice" then
          self.preserveChoiceScroll = false
        end
        if snapshot.kind == "choice" and (event.direction == "up" or event.direction == "down") then
          self.valueEditor:press(event.direction)
        elseif snapshot.kind == "name" or snapshot.kind == "integer" then
          self.valueEditor:press(event.direction)
        elseif snapshot.kind == "choice" then
          self.valueEditor:press(event.direction)
        end
      elseif self.controller.section == "Location" and self.controller.locationGridMode then
        self:_dispatchIntent(self.controller:press(event.direction))
      else
        self:_dispatchIntent(self.controller:press(event.direction))
      end
    elseif event.type == "confirm" then
      if self.controller.modal then
        self:_dispatchIntent(self.controller:press("confirm"))
      elseif self.valueEditor then
        if self.valueEditor:snapshot().kind == "name" then
          self.valueEditor:press("confirm")
          self:_finishValueEditor()
        else
          local submitted, reason = self.valueEditor:submit()
          self.editorFeedback = submitted and nil or reason
          self:_finishValueEditor()
        end
      else
        self:_dispatchIntent(self.controller:press("confirm"))
      end
    elseif event.type == "cancel" then
      if self.controller.modal then
        self:_dispatchIntent(self.controller:press("cancel"))
      elseif self.valueEditor then
        self.valueEditor:cancel()
        self:_finishValueEditor()
      else
        self:_dispatchIntent(self.controller:press("cancel"))
      end
    end
  end
  self:_reconcileFocus()
end

function State:keypressed(key, _, isrepeat)
  if self.disposed or isrepeat or self.status == "opening" then
    return
  end
  if self.controller.modal then
    local source = "key:" .. key
    if key == "up" or key == "down" or key == "left" or key == "right" then
      self.fieldInput:pressDirection(FIELD_DIRECTIONS[key], source)
    elseif HgssInputBindings.isCancelKey(key) then
      self.fieldInput:pressCancel(source)
    elseif HgssInputBindings.isActionKey(key) or key == "return" or key == "kpenter" then
      self.fieldInput:pressAction(source)
    else
      return
    end
    self:_consumeUiInput(self.fieldInput:uiSnapshot(self.inputTick))
    return
  end
  if self.valueEditor then
    self.preserveChoiceScroll = false
    if key == "home" then
      self.valueEditor:press("group_previous")
    elseif key == "end" then
      self.valueEditor:press("group_next")
    elseif key == "return" or key == "kpenter" then
      local submitted, reason = self.valueEditor:submit()
      self.editorFeedback = submitted and nil or reason
      self:_finishValueEditor()
    elseif key == "escape" then
      self.valueEditor:cancel()
      self:_finishValueEditor()
    elseif key == "backspace" then
      self.valueEditor:press("backspace")
    elseif key == "delete" then
      self.valueEditor:press("clear_search")
    elseif key == "left" or key == "right" or key == "up" or key == "down" then
      self.valueEditor:press(key)
    end
    self:_reconcileFocus()
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
  if self.controller.section == "Location" and self.controller.locationPage == "map-list" then
    if key == "delete" then
      self.controller.query = ""
      self.controller.locationMapOffset = 0
      self:_reconcileFocus()
      return
    elseif key == "backspace" then
      local glyphs = {}
      for glyph in Utf8Glyphs.iter(self.controller.query) do
        glyphs[#glyphs + 1] = glyph
      end
      if #glyphs > 0 then
        table.remove(glyphs)
        self.controller.query = table.concat(glyphs)
        self.controller.locationMapOffset = 0
        self:_reconcileFocus()
      end
      return
    end
  end
  if self.controller.section == "Progress" and isPrintableKeyName(key) then
    return
  end
  local source = "key:" .. key
  if key == "up" or key == "down" or key == "left" or key == "right" then
    self.fieldInput:pressDirection(FIELD_DIRECTIONS[key], source)
  elseif HgssInputBindings.isCancelKey(key) then
    self.fieldInput:pressCancel(source)
  elseif HgssInputBindings.isActionKey(key) or key == "return" or key == "kpenter" then
    self.fieldInput:pressAction(source)
  elseif self.controller.section == "Progress" then
    return
  end
  self:_consumeUiInput(self.fieldInput:uiSnapshot(self.inputTick))
end

function State:textinput(text)
  if self.valueEditor then
    if self.valueEditor:snapshot().kind == "choice" then
      self.preserveChoiceScroll = false
    end
    self.valueEditor:textinput(text)
    self.editorFeedback = nil
  elseif
    self.controller.section == "Progress"
    or (self.controller.section == "Location" and self.controller.locationPage == "map-list")
  then
    self.controller.query = self.controller.query .. text
    if self.controller.section == "Location" then
      self.controller.locationMapOffset = 0
      if self.controller.locationPage == "map-list" then
        self:_reconcileFocus()
      end
    end
  end
end

function State:keyreleased(key)
  local source = "key:" .. key
  self.fieldInput:releaseDirection(source)
  self.fieldInput:releaseAction(source)
  self.fieldInput:releaseCancel(source)
end

local function joystickSource(joystick)
  if joystick and joystick.getGUID then
    return "joystick:" .. joystick:getGUID() .. ":" .. tostring(joystick)
  end
  return "joystick:" .. tostring(joystick)
end

function State:gamepadpressed(joystick, button)
  local source = joystickSource(joystick) .. ":" .. button
  local directions = { dpup = "up", dpdown = "down", dpleft = "left", dpright = "right" }
  local direction = directions[button]
  if direction then
    self.fieldInput:pressDirection(FIELD_DIRECTIONS[direction], source)
  elseif button == "a" then
    self.fieldInput:pressAction(source)
  elseif button == "b" then
    self.fieldInput:pressCancel(source)
  end
  self:_consumeUiInput(self.fieldInput:uiSnapshot(self.inputTick))
end

function State:gamepadreleased(joystick, button)
  local source = joystickSource(joystick) .. ":" .. button
  self.fieldInput:releaseDirection(source)
  self.fieldInput:releaseAction(source)
  self.fieldInput:releaseCancel(source)
end

function State:gamepadaxis(joystick, axis, value)
  local source = joystickSource(joystick) .. ":left"
  if axis == "leftx" then
    self.fieldInput:setStickAxis(source, "x", value)
  elseif axis == "lefty" then
    self.fieldInput:setStickAxis(source, "y", value)
  end
  self:_consumeUiInput(self.fieldInput:uiSnapshot(self.inputTick))
end

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

function State:_setScrollOffset(view, layout, viewportId, offset)
  assert(view.scrollOwner == viewportId, "scroll intent must belong to the active owner")
  local viewport = assert(layout.viewports[viewportId], "active scroll owner needs a published viewport")
  local clamped = ScrollViewport.clamp(offset, viewport.contentExtent, viewport.clip.height)
  if viewportId == "location:map-list" then
    self.controller.locationMapOffset = clamped
    return
  end
  if viewportId == "value:choice" then
    self.preserveChoiceScroll = true
  end
  local purpose = assert(scrollPurpose(viewportId, view))
  self.controller.scrollOffsets[purpose] = clamped
end

function State:wheelmoved(_, y)
  local view = self:_snapshot()
  local layout = assert(self:_resolve(view).content.layout)
  local viewportId = view.scrollOwner
  if viewportId == nil then
    return
  end
  local viewport = assert(layout.viewports[viewportId], "active scroll owner needs a published viewport")
  self:_setScrollOffset(view, layout, viewportId, viewport.offset - y * viewport.rowExtent)
end

function State:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  self.generation = self.generation + 1
  self:_cancelPendingLocationSave()
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
  self.partyView = nil
  self.partyProjectionCache = nil
end

return State
