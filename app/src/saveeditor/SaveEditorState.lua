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
local Moves = require("libs.mons.src.gen4.Moves")
local Renderer = require("app.src.saveeditor.SaveEditorRenderer")
local Controller = require("app.src.saveeditor.SaveEditorController")
local Decisions = require("app.src.saveeditor.SaveEditorDecisions")
local LocationSave = require("app.src.saveeditor.SaveEditorLocationSave")
local ValueEditor = require("app.src.saveeditor.SaveEditorValueEditor")
local PartyView = require("app.src.saveeditor.SaveEditorPartyView")
local ScrollViewport = require("libs.ui.src.ScrollViewport")
local Composition = require("app.src.saveeditor.SaveEditorComposition")
local LocationService = require("app.src.saveeditor.SaveEditorLocationService")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
local ItemAssetSchema = require("libs.assets.src.ItemAssetSchema")

---@class SaveEditorLocationService
---@field listMaps fun(self: SaveEditorLocationService): table[]
---@field mapSummaries fun(self: SaveEditorLocationService): table[]
---@field openMap fun(self: SaveEditorLocationService, mapId: integer)
---@field releaseGrid fun(self: SaveEditorLocationService)
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
---@field locationGridWidthTiles integer?
---@field locationGridHeightTiles integer?
---@field errorMessage string?
---@field notice string?
---@field generation number
---@field disposed boolean
---@field resultSent boolean
---@field approvedExit boolean
---@field closeRequest { reason: "back"|"quit", phase: "confirm"|"saving", previousModal: string?, previousModalReturnFocus: string?, previousFocus: string }?
---@field monDraft SaveEditorMonDraft?
---@field partyView SaveEditorPartyView?
---@field pendingMoveSlot integer?
---@field moveChildReturn integer?
---@field moveChildAction string?
---@field activeDraftField table<string, unknown>?
---@field valuePurpose string?
---@field dateProvider fun(): table<string, integer>
---@field iconStatus string?
---@field iconFailure string?
---@field locationSave SaveEditorLocationSave?
---@field pendingRemove table<string, unknown>?
---@field pendingQuantity table<string, unknown>?
---@field numberHold { pointerId: string, targetId: string, delta: integer, scopeEpoch: integer, nextTick: integer }?
---@field numberPressTarget string?
---@field numberPressUntilTick integer
---@field fieldInput FieldInput
---@field inputTick integer
---@field tickRemainder number
---@field activeScopeId string?
---@field scopeEpoch integer
---@field editorFeedback string?
---@field _flagCatalog { name: string, displayName: string, id: integer, targetId: string, value: boolean? }[]?
---@field _flagFilter { query: string, rows: { name: string, displayName: string, id: integer, targetId: string, value: boolean? }[], rowTargets: string[], indexByTarget: table<string, integer> }?
---@field _mapCatalog { rows: { mapId: integer, symbol: string, section: string, displayName: string, targetId: string }[], rowTargets: string[], indexByTarget: table<string, integer> }?
---@field _mapFilter { query: string, rows: { mapId: integer, symbol: string, section: string, displayName: string, targetId: string }[], rowTargets: string[], indexByTarget: table<string, integer> }?
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
      or map.displayName:lower():find(normalized, 1, true)
      or map.section:lower():find(normalized, 1, true)
      or tostring(map.mapId):find(normalized, 1, true)
    then
      filtered[#filtered + 1] = map
    end
  end
  return filtered
end

local function flagDisplayName(symbol)
  return (symbol:gsub("^FLAG_", "", 1))
end

local function scrollPurpose(viewportId, view)
  if viewportId == "party" then
    return "party:" .. tostring(view.partyTab or "Stats")
  elseif viewportId == "bag" then
    return "bag:" .. tostring(view.bagPocket)
  elseif viewportId == "flags" then
    return "flags"
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
    locationGridWidthTiles = nil,
    locationGridHeightTiles = nil,
    locationSave = nil,
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
    pendingMoveSlot = nil,
    moveChildReturn = nil,
    moveChildAction = nil,
    activeDraftField = nil,
    valuePurpose = nil,
    dateProvider = dateProvider,
    iconStatus = nil,
    iconFailure = nil,
    pendingRemove = nil,
    pendingQuantity = nil,
    numberHold = nil,
    numberPressTarget = nil,
    numberPressUntilTick = 0,
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
  local hold = self.numberHold
  if hold ~= nil then
    if self.controller.pointerId ~= hold.pointerId or self.controller.scopeEpoch ~= hold.scopeEpoch then
      self.numberHold = nil
    else
      while self.inputTick >= hold.nextTick do
        self:_adjustNumber(hold.delta)
        hold.nextTick = hold.nextTick + FieldInput.UI_REPEAT_INTERVAL_TICKS
      end
    end
  end
  self:_settleScope()
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
    local prepared, presentationError = pcall(function()
      self.renderer:preparePresentationAssets(assert(graphOrError.cacheFs), assert(graphOrError.fieldUiManifest))
    end)
    if not prepared then
      self:_openingFailed(Errors.new("SAVE_EDITOR_PRESENTATION_ASSET_FAILED", tostring(presentationError)))
      return
    end
    self.partyView = PartyView.new(assert(graphOrError.context))
    self.session = assert(graphOrError.session)
    self.locationService = LocationService.new({
      cacheFs = assert(graphOrError.cacheFs),
      world = assert(graphOrError.world),
      derivedAssets = assert(graphOrError.derivedAssets),
      savedObjects = assert(graphOrError.savedObjects),
    })
    self.locationSave = LocationSave.new({
      cacheFs = assert(graphOrError.cacheFs),
      world = assert(graphOrError.world),
      derivedAssets = self.derivedAssets,
      savedObjects = assert(graphOrError.savedObjects),
    })
    local originalLocation = assert(self.session:snapshot().location)
    self.controller:enterLocation(originalLocation)
    self.controller:setSection("Location")
    self.status, self.errorMessage = "ready", nil
    self:_settleScope()
    self:_resolve(self:_snapshot())
  end
  if self.status == "ready" and self.locationService then
    self:_updateLocationService()
  end
  if self.status == "ready" and self.locationSave ~= nil and self.locationSave:status() ~= nil then
    local updated, updateError = pcall(self._pumpLocationSave, self)
    if not updated then
      self:_cancelPendingLocationSave()
      error(updateError, 0)
    end
  end
  if self.status == "ready" and self.dependencies ~= nil and self.renderer ~= nil then
    local view = self:_snapshot()
    local plan = self:_resolve(view)
    self:_adoptGridSize(plan)
    self.renderer:prepareVisibleIcons(view, plan, self.dependencies.cacheFs, self.derivedAssets)
    self.iconStatus, self.iconFailure = self.renderer.iconStatus, self.renderer.iconFailure
    self:_settleScope()
  end
end

function State:_openingFailed(err)
  if not Errors.is(err) then
    error(err, 0)
  end
  self.status = "error"
  self.errorMessage = message(err)
  self.controller.focus = "retry"
  self:_settleScope()
  self:_resolve(self:_snapshot())
end

-- Computes the interaction scope identity from navigation facts only. Pure:
-- scope changes are applied by _settleScope at explicit transition
-- boundaries, never while a view is being observed.
local function computeScopeId(controller, valuePurpose, valueSnapshot)
  if controller.modal then
    return "decision:" .. controller.modal
  end
  if valueSnapshot ~= nil then
    local query = valueSnapshot.kind == "choice" and valueSnapshot.query or ""
    return "value:" .. (valuePurpose or "editor") .. ":" .. query
  end
  if controller.section == "Party" then
    return table.concat({
      "party",
      tostring(controller.partySlot0),
      controller.partyTab,
    }, ":")
  end
  if controller.section == "Progress" then
    return table.concat({
      "section:Progress",
      controller.query,
    }, ":")
  end
  if controller.section == "Bag" then
    return "section:Bag:" .. controller.bagPocket
  end
  local scopeId = "section:" .. controller.section .. ":" .. controller.locationPage
  if controller.section == "Location" and controller.locationPage == "map-list" then
    scopeId = scopeId .. ":" .. controller.query
  end
  return scopeId
end

-- Applies scope publication, input ownership and page normalization for
-- the current navigation facts. Called after semantic input, transitions,
-- opening changes, resize and focus loss; never from view or draw.
function State:_settleScope()
  local valueSnapshot = self.valueEditor ~= nil and self.valueEditor:snapshot() or nil
  local scopeId = computeScopeId(self.controller, self.valuePurpose, valueSnapshot)
  if scopeId ~= self.activeScopeId then
    self.activeScopeId = scopeId
    self.scopeEpoch = self.scopeEpoch + 1
    self.fieldInput:beginUi(self.inputTick)
    self.controller:cancelInteraction()
    self.numberHold = nil
    self.numberPressTarget = nil
  end
  self.controller.scopeId, self.controller.scopeEpoch = scopeId, self.scopeEpoch
  if self.status == "ready" and self.session ~= nil and self.dependencies ~= nil then
    if self.controller.section == "Bag" then
      self:_normalizeBagPage()
    end
  end
end

function State:_normalizeBagPage()
  local rows = self.session:bagSnapshot(self.controller.bagPocket)
  local pageCount = math.max(1, math.ceil(#rows / 6))
  self.controller.bagPage0 = math.max(0, math.min(pageCount - 1, self.controller.bagPage0))
end

function State:_snapshot()
  local session = self.session and self.session:snapshot() or nil
  local section = self.controller.section
  local flagRows, flagRowTargets, flagIndexByTarget = {}, {}, {}
  if session ~= nil and section == "Progress" then
    flagRows, flagRowTargets, flagIndexByTarget = self:_flagRows(session.flags)
  end
  local party = session and section == "Party" and self:_partyView() or {}
  local bag = session and section == "Bag" and self:_bagView() or {}
  local numberControls, numberControlVisuals, numberPressTicks
  if self.valueEditor ~= nil and self.valueEditor:snapshot().kind == "number" then
    local dependencies = assert(self.dependencies, "number editor requires its presentation manifest")
    local numberPresentation = assert(dependencies.bagManifest).interactive.overlays.quantity
    numberControls = numberPresentation.controls
    numberControlVisuals = numberPresentation.visuals
    numberPressTicks = numberPresentation.pressTicks
  end
  local view = {
    kind = "save_editor",
    status = self.status,
    message = self.errorMessage or self.message,
    errorMessage = self.errorMessage,
    notice = self.notice,
    versionId = self.versionId,
    saveId = self.saveId,
    session = session,
    framePreviewIndex = self.valuePurpose == "dialogue_frame" and self.valueEditor ~= nil and tonumber(
      self.valueEditor:snapshot().selectedKey
    ) or nil,
    ready = session ~= nil,
    dirty = self.session ~= nil
      and (
        self.session:isDirty() or (self.monDraft ~= nil and (self.monDraft:mode() == "add" or self.monDraft:isDirty()))
      ),
    dirtySections = session and session.dirtySections or { money = false, flags = false },
    sectionDirty = self:_sectionDirty(session),
    section = self.controller.section,
    sections = self.controller:snapshot().sections,
    navigationRows = {
      { role = "action", id = "section:Player", targetId = "section:Player", label = "Player" },
      { role = "action", id = "section:Progress", targetId = "section:Progress", label = "Progress" },
    },
    modal = self.controller.modal,
    focus = self.controller.focus,
    focusVisible = self.controller.focusVisible,
    capturedTarget = self.controller.capturedTarget,
    scrollOffset = self.controller.scrollOffset,
    query = self.controller.query,
    flagRows = flagRows,
    flagRowTargets = flagRowTargets,
    flagIndexByTarget = flagIndexByTarget,
    valueEditor = self.valueEditor and self.valueEditor:snapshot() or nil,
    editorFeedback = self.editorFeedback,
    numberControls = numberControls,
    numberControlVisuals = numberControlVisuals,
    numberPressTicks = numberPressTicks,
    unappliedDraft = self.valueEditor ~= nil,
    iconStatus = self.iconStatus,
    iconFailure = self.iconFailure,
    locationNavigation = self.controller:locationSnapshot(),
  }
  if self.locationService then
    local location = self.locationService:snapshot()
    local mapRows, mapRowTargets, mapIndexByTarget = self:_mapRows()
    location.maps = mapRows
    location.mapRowTargets = mapRowTargets
    location.mapIndexByTarget = mapIndexByTarget
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
  local saveStatus = self.locationSave ~= nil and self.locationSave:status() or nil
  view.locationSave = saveStatus
      and {
        operationId = saveStatus.operationId,
        state = "pending",
        cancelTarget = "save",
      }
    or nil
  if self.controller.modal ~= nil then
    view.decisionActions = Decisions.describe(self.controller.modal, self:_decisionFacts(saveStatus))
  end
  for key, value in pairs(party) do
    view[key] = value
  end
  for key, value in pairs(bag) do
    view[key] = value
  end
  local valueSnapshot = self.valueEditor ~= nil and self.valueEditor:snapshot() or nil
  local scopeId = computeScopeId(self.controller, self.valuePurpose, valueSnapshot)
  local scopeKind = self.controller.modal and "decision"
    or self.valueEditor and "value"
    or self.controller.section == "Party" and "party"
    or "section"
  view.scope = {
    id = scopeId,
    epoch = self.scopeEpoch,
    kind = scopeKind,
    focusId = self.controller.focus,
  }
  view.numberHoldTarget = self.numberHold and self.numberHold.targetId
    or self.inputTick < self.numberPressUntilTick and self.numberPressTarget
    or nil
  view.preserveChoiceScroll = self.preserveChoiceScroll
  view.scrollOffsets = self.controller.scrollOffsets
  return view
end

function State:_sectionDirty(session)
  if session == nil then
    return false
  end
  local dirty = session.dirtySections
  local section = self.controller.section
  if section == "Player" then
    return dirty.money == true or dirty.frame == true
  elseif section == "Progress" then
    return dirty.flags == true
  elseif section == "Location" then
    return dirty.location == true
  elseif section == "Party" then
    if self.monDraft ~= nil and (self.monDraft:mode() == "add" or self.monDraft:isDirty()) then
      return true
    end
    return dirty.party == true
  elseif section == "Bag" then
    return dirty.bag == true
  end
  return false
end

function State:_flagCatalogRows()
  if self._flagCatalog == nil then
    local catalog = {}
    for name, flagId in pairs(FieldScriptSymbols.flagsByName) do
      if name:sub(1, 9) ~= "FLAG_UNK_" then
        catalog[#catalog + 1] = {
          name = name,
          displayName = flagDisplayName(name),
          id = flagId,
          targetId = "flag:" .. name,
        }
      end
    end
    table.sort(catalog, function(a, b)
      return a.name < b.name
    end)
    self._flagCatalog = catalog
  end
  return assert(self._flagCatalog)
end

---@return { name: string, displayName: string, id: integer, targetId: string, value: boolean? }[] rows
---@return string[] rowTargets
---@return table<string, integer> indexByTarget
function State:_filteredFlagRows()
  local query = self.controller.query:lower()
  local cached = self._flagFilter
  if cached == nil or cached.query ~= query then
    local rows, rowTargets, indexByTarget = {}, {}, {}
    for _, descriptor in ipairs(self:_flagCatalogRows()) do
      if
        query == ""
        or descriptor.name:lower():find(query, 1, true)
        or descriptor.displayName:lower():find(query, 1, true)
      then
        rows[#rows + 1] = descriptor
        rowTargets[#rowTargets + 1] = descriptor.targetId
        indexByTarget[descriptor.targetId] = #rows
      end
    end
    cached = { query = query, rows = rows, rowTargets = rowTargets, indexByTarget = indexByTarget }
    self._flagFilter = cached
  end
  return cached.rows, cached.rowTargets, cached.indexByTarget
end

---@return { mapId: integer, symbol: string, section: string, displayName: string, targetId: string }[] rows
---@return string[] rowTargets
---@return table<string, integer> indexByTarget
function State:_mapCatalogRows()
  local cached = self._mapCatalog
  if cached == nil then
    local rows, rowTargets, indexByTarget = {}, {}, {}
    local summaries = assert(self.locationService, "the map catalog needs its location service"):mapSummaries()
    for _, summary in ipairs(summaries) do
      local descriptor = {
        mapId = summary.mapId,
        symbol = summary.symbol,
        section = summary.section,
        displayName = summary.displayName,
        targetId = "location:map:" .. summary.mapId,
      }
      rows[#rows + 1] = descriptor
      rowTargets[#rowTargets + 1] = descriptor.targetId
      indexByTarget[descriptor.targetId] = #rows
    end
    cached = { rows = rows, rowTargets = rowTargets, indexByTarget = indexByTarget }
    self._mapCatalog = cached
  end
  return cached.rows, cached.rowTargets, cached.indexByTarget
end

---@return { mapId: integer, symbol: string, section: string, displayName: string, targetId: string }[] rows
---@return string[] rowTargets
---@return table<string, integer> indexByTarget
function State:_filteredMapRows()
  local query = self.controller.query:lower()
  local cached = self._mapFilter
  if cached == nil or cached.query ~= query then
    local rows = filterLocationMaps(self:_mapCatalogRows(), self.controller.query)
    local rowTargets, indexByTarget = {}, {}
    for _, descriptor in ipairs(rows) do
      rowTargets[#rowTargets + 1] = descriptor.targetId
      indexByTarget[descriptor.targetId] = #rowTargets
    end
    cached = { query = query, rows = rows, rowTargets = rowTargets, indexByTarget = indexByTarget }
    self._mapFilter = cached
  end
  return cached.rows, cached.rowTargets, cached.indexByTarget
end

---@return { mapId: integer, symbol: string, section: string, displayName: string, targetId: string }[] rows
---@return string[] rowTargets
---@return table<string, integer> indexByTarget
function State:_mapRows()
  if self.controller.locationPage == "map-list" then
    return self:_filteredMapRows()
  end
  return self:_mapCatalogRows()
end

---@param values table<integer, boolean>
---@return { name: string, displayName: string, id: integer, targetId: string, value: boolean? }[] rows
---@return string[] rowTargets
---@return table<string, integer> indexByTarget
function State:_flagRows(values)
  local rows, rowTargets, indexByTarget = self:_filteredFlagRows()
  for _, row in ipairs(rows) do
    row.value = values[row.id] == true
  end
  return rows, rowTargets, indexByTarget
end

function State:_partyView()
  local dependencies = assert(self.dependencies, "ready Party view requires editor dependencies")
  assert(dependencies.context, "ready Party view requires its version context")
  local partyView = assert(self.partyView, "ready Party view requires its catalog-backed row builder")
  local snapshot = self.session:partySnapshot()
  local members = snapshot.members
  local controller = self.controller
  local draft = self.monDraft
  if draft ~= nil and draft:mode() == "add" and draft:basePartyRevision() == snapshot.revision then
    local staged = {}
    for _, member in ipairs(members) do
      staged[#staged + 1] = member
    end
    staged[#staged + 1] = { slot0 = controller.partySlot0 or #members, mon = draft:record() }
    members = staged
  end
  local tab = controller.partyTab
  local view = {
    partyTab = tab,
    partySlot0 = controller.partySlot0,
    partySelector = partyView:selector(members, controller.partySlot0),
    partyMemberCount = #members,
    partyEmpty = #members == 0,
  }
  if draft == nil then
    return view
  end
  local record = draft:record()
  local projection = draft:projection()
  local fields = {}
  local function collect(targetId, editor)
    if targetId ~= nil and editor ~= nil then
      fields[targetId] = editor
    end
  end
  if tab == "Stats" then
    local stats = partyView:stats(record, projection)
    view.partyStats = stats
    for _, fact in ipairs(stats.header) do
      collect(fact.targetId, fact.editor)
    end
    for _, row in ipairs(stats.rows) do
      collect(row.ivEditor.targetId, row.ivEditor.editor)
      collect(row.evEditor.targetId, row.evEditor.editor)
    end
  elseif tab == "Moves" then
    view.partyMoves = partyView:moves(record)
  else
    local details = partyView:details(record, projection)
    view.partyDetails = details
    for _, row in ipairs(details.rows) do
      collect(row.targetId, row.editor)
    end
  end
  view.partyFields = fields
  local _, validationError = draft:validate()
  view.partyValid = validationError == nil
  if validationError ~= nil then
    view.partyWarning = message(validationError)
  end
  return view
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
    pockets[#pockets + 1] = { key = key }
  end
  local snapshot = self.session:bagSnapshot(self.controller.bagPocket)
  local rows = {}
  for _, entry in ipairs(snapshot) do
    local item = itemCatalog:item(entry.item)
    rows[#rows + 1] = {
      item = entry.item,
      label = item.name or entry.item,
      iconKey = item.icon,
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
  local pageCount = math.max(1, math.ceil(#rows / 6))
  local page0 = math.max(0, math.min(pageCount - 1, self.controller.bagPage0))
  local pageRows = {}
  for index = page0 * 6 + 1, math.min(#rows, page0 * 6 + 6) do
    pageRows[#pageRows + 1] = rows[index]
  end
  local manifest = assert(self.dependencies.bagManifest, "Bag presentation manifest is required")
  local canAdd = false
  for _, key in ipairs(itemCatalog:itemKeys()) do
    if key ~= "NONE" and itemCatalog:item(key).pocket == self.controller.bagPocket then
      canAdd = true
      break
    end
  end
  return {
    bagPocket = self.controller.bagPocket,
    bagPockets = pockets,
    bagRows = rows,
    bagPageRows = pageRows,
    bagPage0 = page0,
    bagPageCount = pageCount,
    bagAddEnabled = canAdd,
    bagPocketTabRects = manifest.interactive.pocketTabs.rects,
    bagPocketStrip = manifest.interactive.pocketTabs.strips[self.controller.bagPocket],
    bagFocusVisuals = manifest.interactive.focus,
    bagTabFocusVisual = manifest.interactive.focus.tabs.visual,
    bagTabFocusTargets = manifest.interactive.focus.tabs.targets,
    bagQuantityVisuals = manifest.interactive.overlays.quantity.visuals,
    bagSelectedItem = self.controller.bagItemKey,
    bagSelectedQuantity = selectedQuantity,
    bagSelectedLabel = self.controller.bagItemKey and itemCatalog:item(self.controller.bagItemKey).name or nil,
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
  local fields = view.partyFields
  if fields == nil then
    return nil
  end
  return fields[targetId]
end

function State:_setDraftValue(descriptor, value)
  local draft = assert(self.monDraft, "raw Party fields require an active draft")
  if descriptor.setter == "level" then
    return draft:setLevel(value)
  elseif descriptor.setter == "species" then
    return draft:setSpecies(value)
  elseif descriptor.setter == "form" then
    return draft:setForm(value)
  elseif descriptor.setter == "iv" then
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
    self.numberHold = nil
    self.numberPressTarget = nil
    self.pendingFocusReturn = self.valueReturnFocus
    self.valueEditor, self.valuePurpose, self.activeDraftField = nil, nil, nil
    self.valueReturnFocus = nil
    if self.moveChildReturn ~= nil then
      local slot0, action = assert(self.moveChildReturn), assert(self.moveChildAction)
      self:_showMoveOverlay(slot0, action)
    elseif purpose == "bag_quantity" then
      local pending = assert(self.pendingQuantity)
      self.pendingQuantity = nil
      if pending.returnModal then
        self.controller.focus = "bag:item:" .. pending.itemKey
        self.controller:openModal(pending.returnModal)
      end
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
  elseif purpose == "dialogue_frame" then
    local changed = self.session:setFrameIndex(tonumber(result.value))
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
  elseif purpose == "party_move_key" or purpose == "party_move_pp" or purpose == "party_move_pp_ups" then
    local slot0 = assert(self.pendingMoveSlot, "a move component editor owns its slot")
    local draft = assert(self.monDraft, "a move component editor needs its member draft")
    local component = purpose == "party_move_key" and "move" or purpose == "party_move_pp" and "pp" or "ppUps"
    if not draft:setMove(slot0, component, result.value) then
      self.errorMessage = "That value is not valid for this move."
      editor:retry()
      return false
    end
    self.errorMessage = nil
    self.pendingFocusReturn = nil
    self.numberHold = nil
    self.numberPressTarget = nil
    self.valueEditor, self.valuePurpose, self.activeDraftField = nil, nil, nil
    self.valueReturnFocus = nil
    self:_showMoveOverlay(slot0, assert(self.moveChildAction))
    return true
  elseif purpose == "bag_add_item" then
    self.numberHold = nil
    self.numberPressTarget = nil
    self.valueEditor, self.valuePurpose, self.activeDraftField = nil, nil, nil
    self.controller:selectBagItem(result.value)
    self.valueReturnFocus = "bag:add"
    self:_openBagQuantity("add")
    return true
  elseif purpose == "bag_quantity" then
    local pending = assert(self.pendingQuantity)
    if not self:_publishBagQuantity(pending.itemKey, result.value) then
      editor:retry()
      return false
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
  self.numberHold = nil
  self.numberPressTarget = nil
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
  self.controller.partySlot0 = #self.session:partySnapshot().members
  self.controller.focus = "party:slot:" .. self.controller.partySlot0
  self.controller:cancelInteraction()
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
  self.pendingQuantity =
    { itemKey = itemKey, mode = mode, returnModal = mode == "set" and self.controller.modal or nil }
  self.controller.modal = nil
  self:_installValueEditor(
    ValueEditor.new({
      kind = "integer",
      value = mode == "add" and math.min(pocket.maxQuantity, current + 1) or current,
      min = 1,
      max = pocket.maxQuantity,
      base = "decimal",
    }),
    "bag_quantity",
    mode == "add" and "bag:add" or "bag:item:" .. itemKey
  )
end

function State:_adjustNumber(delta)
  if self.valueEditor ~= nil then
    self.valueEditor:adjustInteger(delta)
  end
end

function State:_publishBagQuantity(itemKey, quantity)
  local result = self.session:setBagQuantity(itemKey, quantity)
  if not result.ok then
    self.errorMessage = message(result.error)
    return false
  else
    self.errorMessage = nil
    if quantity > 0 then
      local rows = self.session:bagSnapshot(self.controller.bagPocket)
      for index, row in ipairs(rows) do
        if row.item == itemKey then
          self.controller.bagPage0 = math.floor((index - 1) / 6)
          self.controller.bagItemKey = itemKey
          self.controller.focus = "bag:item:" .. itemKey
          break
        end
      end
    end
    return true
  end
end

-- Resolves the presentation plan for already-settled facts. Pure
-- observation: grid adoption happens on the update path, never here.
function State:_resolve(view)
  view.textMetrics = assert(self.renderer):metrics()
  return self.presentation:resolve(self.displayContext:measure(self.width, self.height), view)
end

function State:_adoptGridSize(plan)
  local grid = plan.content.layout.locationGrid
  if grid ~= nil then
    self.locationGridWidthTiles = grid.columns
    self.locationGridHeightTiles = grid.rows
  end
end

---@param layout table<string, unknown>
---@return table<string, unknown>? list
---@return integer? rowIndex
function State:_activeList(layout)
  local available = type(layout) == "table" and layout.lists or nil
  if type(available) ~= "table" then
    return nil
  end
  local focus = self.controller.focus
  for _, list in pairs(available) do
    if focus == list.targetId then
      return list, nil
    end
    local indexByTarget = list.indexByTarget
    if type(indexByTarget) == "table" and indexByTarget[focus] ~= nil then
      return list, indexByTarget[focus]
    end
    for index, targetId in ipairs(list.rowTargets) do
      if focus == targetId then
        return list, index
      end
    end
  end
  return nil
end

---@param lists table<string, unknown>
---@param targetId string
---@return table<string, unknown>?
local function findListByRowTarget(lists, targetId)
  for _, list in pairs(lists) do
    for _, rowTarget in ipairs(list.rowTargets) do
      if rowTarget == targetId then
        return list
      end
    end
  end
  return nil
end

---@param lists table<string, unknown>
---@param viewportId string
---@return table<string, unknown>?
local function findListByViewportId(lists, viewportId)
  for _, list in pairs(lists) do
    if list.viewportId == viewportId then
      return list
    end
  end
  return nil
end

---@param list table<string, unknown>
---@return string? cursor
function State:_reconcileListCursor(list)
  local cursor = self.controller:listCursor(list.id)
  if cursor ~= nil then
    local indexByTarget = list.indexByTarget
    if type(indexByTarget) == "table" then
      if indexByTarget[cursor] ~= nil then
        return cursor
      end
    else
      for _, targetId in ipairs(list.rowTargets) do
        if targetId == cursor then
          return cursor
        end
      end
    end
  end
  cursor = list.rowTargets[1]
  self.controller:setListCursor(list.id, cursor)
  return cursor
end

---@param list table<string, unknown>
---@param offset number
function State:_storeListOffset(list, offset)
  if list.id == "location:map-list" then
    self.controller.locationMapOffset = offset
  elseif list.id == "flags" or list.id == "value:choice" then
    if list.id == "value:choice" then
      self.preserveChoiceScroll = true
    end
    self.controller.scrollOffsets[list.id] = offset
  else
    error("unknown generic list " .. tostring(list.id), 2)
  end
end

---@param list table<string, unknown>
---@param viewport table<string, unknown>
---@param offset number
---@return string? cursor
function State:_clampListCursorToVisible(list, viewport, offset)
  if #list.rowTargets == 0 then
    self.controller:setListCursor(list.id, nil)
    return nil
  end
  local firstIndex, lastIndex =
    ScrollViewport.visibleRange(offset, viewport.clip.height, viewport.rowExtent, viewport.gap, #list.rowTargets)
  local cursor = self.controller:listCursor(list.id)
  local cursorIndex
  for index, targetId in ipairs(list.rowTargets) do
    if targetId == cursor then
      cursorIndex = index
      break
    end
  end
  if cursorIndex ~= nil and firstIndex <= lastIndex then
    if cursorIndex < firstIndex then
      cursorIndex = firstIndex
    elseif cursorIndex > lastIndex then
      cursorIndex = lastIndex
    end
  elseif cursorIndex == nil then
    cursorIndex = firstIndex <= lastIndex and firstIndex or 1
  end
  local target = assert(list.rowTargets[assert(cursorIndex)], "visible cursor stays within its rows")
  self.controller:setListCursor(list.id, target)
  return target
end

function State:_syncChoiceSelection(list, targetId)
  if list.id ~= "value:choice" then
    return
  end
  local editor = assert(self.valueEditor, "choice rows need their value editor")
  local key = assert(targetId:match("^choice:(.+)$"), "choice cursor must identify a choice row")
  local guard = 0
  while editor:snapshot().selectedKey ~= key and guard < 64 do
    guard = guard + 1
    local snapshot = editor:snapshot()
    local current, wanted
    for index, option in ipairs(snapshot.options) do
      if option.key == snapshot.selectedKey then
        current = index
      end
      if option.key == key then
        wanted = index
      end
    end
    if wanted == nil then
      return
    end
    local delta = wanted - (current or 1)
    if delta == 0 then
      editor:moveChoice(1)
      editor:moveChoice(-1)
    else
      editor:moveChoice(delta)
    end
  end
end

---@param list table<string, unknown>
---@param rowIndex integer
---@param direction string
---@param layout table<string, unknown>
function State:_moveListRow(list, rowIndex, direction, layout)
  local viewport = assert(layout.viewports[list.viewportId], "list movement needs its scroll viewport")
  local visibleCount = math.max(1, viewport.lastIndex - viewport.firstIndex + 1)
  local delta = direction == "up" and -1
    or direction == "down" and 1
    or direction == "left" and -visibleCount
    or direction == "right" and visibleCount
    or error("list movement needs a cardinal direction", 2)
  local nextIndex = math.max(1, math.min(#list.rowTargets, rowIndex + delta))
  if list.id == "value:choice" then
    local editor = assert(self.valueEditor, "choice rows need their value editor")
    self.preserveChoiceScroll = false
    self:_syncChoiceSelection(list, list.rowTargets[rowIndex])
    if nextIndex ~= rowIndex then
      editor:moveChoice(nextIndex - rowIndex)
    end
    local selected = assert(editor:snapshot().selectedKey, "choice movement keeps a selected row")
    local target = "choice:" .. selected
    self.controller:setListCursor(list.id, target)
    self.controller:setFocus(target)
    return
  end
  -- Logical movement never depends on which rows the previous layout materialized:
  -- the cursor moves by index, the offset reveals that index, and focus is
  -- reconciled only after a fresh layout makes the target visible.
  local target = assert(list.rowTargets[nextIndex], "list movement stays within its rows")
  self.controller:setListCursor(list.id, target)
  local offset = ScrollViewport.reveal(
    viewport.offset,
    viewport.clip.height,
    (nextIndex - 1) * viewport.rowExtent,
    viewport.rowExtent
  )
  offset = ScrollViewport.clamp(offset, viewport.contentExtent, viewport.clip.height)
  self:_storeListOffset(list, offset)
  self:_reconcileFocus(target, self:_resolve(self:_snapshot()).content.layout)
end

function State:_filterFocusedList(list, rowIndex, operation, text)
  assert(list.filterable, "filtering needs a filterable list")
  local previousFocus = self.controller.focus
  local hadRowFocus = rowIndex ~= nil
  if list.id == "value:choice" then
    local editor = assert(self.valueEditor, "choice filtering needs its value editor")
    self.preserveChoiceScroll = false
    if operation == "append" then
      editor:textinput(assert(text, "filter append needs its input text"))
    elseif operation == "backspace" then
      editor:press("backspace")
    elseif operation == "clear" then
      editor:press("clear_search")
    else
      error("unknown list filter operation", 2)
    end
  else
    if operation == "append" then
      self.controller.query = self.controller.query .. assert(text, "filter append needs its input text")
    elseif operation == "backspace" then
      local glyphs = {}
      for glyph in Utf8Glyphs.iter(self.controller.query) do
        glyphs[#glyphs + 1] = glyph
      end
      table.remove(glyphs)
      self.controller.query = table.concat(glyphs)
    elseif operation == "clear" then
      self.controller.query = ""
    else
      error("unknown list filter operation", 2)
    end
    if list.id == "flags" then
      self.controller.scrollOffsets.flags = 0
    elseif list.id == "location:map-list" then
      self.controller.locationMapOffset = 0
    else
      error("unknown filterable list " .. list.id, 2)
    end
  end
  local layout = self:_resolve(self:_snapshot()).content.layout
  local fresh = assert(layout.lists and layout.lists[list.id], "filtering keeps its focused list")
  if #fresh.rowTargets == 0 then
    self.controller:setListCursor(fresh.id, nil)
    self.controller:setFocus(fresh.targetId)
    return
  end
  local focusLive = false
  for _, targetId in ipairs(fresh.rowTargets) do
    if targetId == previousFocus then
      focusLive = true
      break
    end
  end
  if hadRowFocus then
    if focusLive then
      self.controller:setListCursor(fresh.id, previousFocus)
      local viewport = assert(layout.viewports[fresh.viewportId], "filtering keeps its scroll viewport")
      local survived = fresh.indexByTarget ~= nil and fresh.indexByTarget[previousFocus] or nil
      if survived == nil then
        for index, targetId in ipairs(fresh.rowTargets) do
          if targetId == previousFocus then
            survived = index
            break
          end
        end
      end
      local revealed = ScrollViewport.clamp(
        ScrollViewport.reveal(
          viewport.offset,
          viewport.clip.height,
          (assert(survived, "surviving focus stays within its rows") - 1) * viewport.rowExtent,
          viewport.rowExtent
        ),
        viewport.contentExtent,
        viewport.clip.height
      )
      self:_storeListOffset(fresh, revealed)
      self:_reconcileFocus(previousFocus, self:_resolve(self:_snapshot()).content.layout)
    else
      self.controller:setListCursor(fresh.id, fresh.rowTargets[1])
      self.controller:setFocus(fresh.rowTargets[1])
    end
  else
    self:_reconcileListCursor(fresh)
  end
end

---@param list table<string, unknown>
---@param rowIndex integer?
---@param layout table<string, unknown>?
function State:_handleListConfirm(list, rowIndex, layout)
  if rowIndex ~= nil then
    self:_dispatchIntent(self.controller:press("confirm"))
    return
  end
  local cursor = self:_reconcileListCursor(list)
  if cursor == nil then
    return
  end
  if list.id == "value:choice" then
    self:_syncChoiceSelection(list, cursor)
    local editor = assert(self.valueEditor, "choice rows need their value editor")
    local selected = editor:snapshot().selectedKey
    if selected ~= nil then
      cursor = "choice:" .. selected
    end
  end
  self.controller:setListCursor(list.id, cursor)
  local resolved = layout or self:_resolve(self:_snapshot()).content.layout
  local viewport = assert(resolved.viewports[list.viewportId], "list confirmation needs its scroll viewport")
  local cursorIndex = list.indexByTarget ~= nil and list.indexByTarget[cursor] or nil
  if cursorIndex == nil then
    for index, targetId in ipairs(list.rowTargets) do
      if targetId == cursor then
        cursorIndex = index
        break
      end
    end
  end
  local revealed = ScrollViewport.clamp(
    ScrollViewport.reveal(
      viewport.offset,
      viewport.clip.height,
      (assert(cursorIndex, "entered cursor stays within its rows") - 1) * viewport.rowExtent,
      viewport.rowExtent
    ),
    viewport.contentExtent,
    viewport.clip.height
  )
  self:_storeListOffset(list, revealed)
  self:_reconcileFocus(cursor, self:_resolve(self:_snapshot()).content.layout)
end

---@param preferred string?
---@param layout table<string, unknown>?
---@return table<string, unknown> layout the reconciled layout
function State:_reconcileFocus(preferred, layout)
  local current = layout or self:_resolve(self:_snapshot()).content.layout
  local before = self.controller.focus
  ---@type string?
  local focus = preferred or self.pendingFocusReturn or self.controller.focus
  if focus ~= nil and current.focusGraph[focus] == nil then
    focus = nil
  end
  self.controller:reconcileFocus(current.focusGraph, focus, { current.defaultFocus })
  self.pendingFocusReturn = nil
  local reconciled = current
  if self.controller.focus ~= before then
    reconciled = self:_resolve(self:_snapshot()).content.layout
  end
  if reconciled.lists ~= nil then
    for _, list in pairs(reconciled.lists) do
      self:_reconcileListCursor(list)
    end
  end
  return reconciled
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
  if navigation.page ~= "grid" then
    return
  end
  if self.locationServiceMapId ~= mapId then
    service:openMap(mapId)
    self.locationServiceMapId = mapId
    self.locationViewport = nil
  end

  local center = assert(navigation.center, "Location viewport needs a center")
  local viewport = {
    centerX = center.fieldX,
    centerZ = center.fieldZ,
    widthTiles = self.locationGridWidthTiles or 1,
    heightTiles = self.locationGridHeightTiles or 1,
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
  return self.locationGridWidthTiles or 1, self.locationGridHeightTiles or 1
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
  if self.locationSave ~= nil then
    self.locationSave:cancel()
  end
end

function State:_startPendingLocationSave(snapshot, leave)
  local owner = assert(self.locationSave, "a relocated save needs its destination verifier")
  if owner:start(snapshot, leave) then
    self.errorMessage = nil
  end
end

-- Advances the pending destination verification and runs the session
-- transaction once its ticket is fresh. A verified ticket is not save
-- authorization: revision, placement and open drafts are rechecked here
-- immediately before the transaction runs. Only this owner invokes
-- Session.save and emits the final application result.
function State:_pumpLocationSave()
  local owner = self.locationSave
  if owner == nil or self.session == nil or owner:status() == nil then
    return
  end
  local result = owner:step(self.session:snapshot())
  if result.kind == "pending" then
    return
  end
  if result.kind == "cancelled" then
    self.errorMessage = "The destination check was canceled after the save changed."
    if self.closeRequest then
      self.closeRequest.phase = "confirm"
    end
    return
  end
  if result.kind == "failed" then
    self.errorMessage = result.reason or "The destination could not be verified."
    if self.closeRequest then
      self.closeRequest.phase = "confirm"
    end
    return
  end
  if result.kind == "unresolvable" then
    self.locationActionStatus = result.tileStatus
    self.errorMessage = result.reason or "The destination is unavailable."
    if self.closeRequest then
      self.closeRequest.phase = "confirm"
    end
    return
  end
  if result.kind == "drifted" then
    self.locationActionStatus = { state = "unavailable", reason = "destination_changed_during_resolution" }
    self.errorMessage = "The destination changed while it was being checked. Review it and save again."
    if self.closeRequest then
      self.closeRequest.phase = "confirm"
    end
    return
  end
  assert(result.kind == "verified", "destination verification settles with a known result")
  local fresh = self.session:snapshot()
  if fresh.revision ~= result.sessionRevision or not sameLocation(fresh.location, result.location) then
    self.errorMessage = "The destination check was canceled after the save changed."
    if self.closeRequest then
      self.closeRequest.phase = "confirm"
    end
    return
  end
  if self.valueEditor ~= nil or self.monDraft ~= nil then
    self.errorMessage = "Finish or cancel the open edit before saving."
    if self.closeRequest then
      self.closeRequest.phase = "confirm"
    end
    return
  end
  local saved = self.session:save(false)
  if not saved.ok then
    self.errorMessage = message(assert(saved.error, "failed save result must include its structured error"))
    if self.closeRequest then
      self.closeRequest.phase = "confirm"
    end
    return
  end
  self.errorMessage = nil
  if result.leave then
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

-- The selected member is always being edited: entering or reselecting a
-- member opens its edit draft, and leaving that member context publishes a
-- dirty draft through the session. An invalid draft blocks the transition
-- and keeps the current context with its error shown.
function State:_ensurePartyDraft()
  if self.controller.section ~= "Party" or self.session == nil then
    return false
  end
  local pending = self.monDraft
  if pending ~= nil and pending:mode() == "add" and pending:basePartyRevision() == self.session:partyRevision() then
    if self.controller.partySlot0 == nil then
      self.controller.partySlot0 = #self.session:partySnapshot().members
    end
    return true
  end
  local members = self.session:partySnapshot().members
  if #members == 0 then
    self.controller.partySlot0 = nil
    return false
  end
  local slot0 = self.controller.partySlot0
  local present = false
  for _, member in ipairs(members) do
    if member.slot0 == slot0 then
      present = true
      break
    end
  end
  if not present then
    slot0 = members[1].slot0
    self.controller.partySlot0 = slot0
  end
  local draft = self.monDraft
  if
    draft ~= nil
    and draft:mode() == "edit"
    and draft:slot0() == slot0
    and draft:basePartyRevision() == self.session:partyRevision()
  then
    return true
  end
  local fresh, freshError = self.session:beginMonEdit(assert(slot0))
  if fresh == nil then
    self.errorMessage = message(assert(freshError))
    return false
  end
  self.monDraft = fresh
  self.errorMessage = nil
  return true
end

---@return boolean applied true when no draft blocks the transition
function State:_applyCurrentPartyDraftIfNeeded()
  local draft = self.monDraft
  if draft == nil then
    return true
  end
  if draft:mode() ~= "add" and not draft:isDirty() then
    self.monDraft = nil
    return true
  end
  local canonical, validationError = draft:validate()
  if canonical == nil then
    self.errorMessage = message(assert(validationError))
    return false
  end
  local result = self.session:applyMonDraft(draft)
  if not result.ok then
    self.errorMessage = message(result.error)
    return false
  end
  if draft:mode() == "add" then
    local members = self.session:partySnapshot().members
    self.controller.partySlot0 = assert(members[#members], "an applied new member joins the party").slot0
  end
  self.monDraft = nil
  self.errorMessage = nil
  return true
end

function State:_requestDraftResolution(action)
  if self.monDraft == nil then
    self:_performDeferred(action)
    return false
  end
  if not self:_applyCurrentPartyDraftIfNeeded() then
    return true
  end
  self:_performDeferred(action)
  return false
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
      self.controller.query = ""
      self.controller.focus = "list:flags"
    elseif action.section == "Location" and self.locationService then
      self:_updateLocationService()
    elseif action.section == "Party" then
      self:_ensurePartyDraft()
    end
    self.errorMessage = nil
  elseif action.kind == "save" then
    self:_save(false)
  elseif action.kind == "party-slot" then
    self.controller:selectPartySlot(action.slot0)
    self:_ensurePartyDraft()
  elseif action.kind == "location-map-select" then
    local world = assert(self.dependencies.world)
    local record = world.maps[assert(world.byId[action.mapId], "selected map must be in structural world data")]
    local staged = self.session and self.session:snapshot().location or nil
    if staged ~= nil and staged.mapId == action.mapId then
      self.controller:chooseLocationMap(action.mapId, staged.fieldX, staged.fieldZ)
    else
      self.controller:chooseLocationMap(action.mapId, record.worldOriginX + 16, record.worldOriginZ + 16)
    end
    self.locationServiceMapId = nil
    self.locationViewport = nil
    self.locationActionStatus = nil
    self.errorMessage = nil
    self:_settleScope()
    return
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
  elseif action.kind == "select_tile" then
    self:_selectLocationTile(action.fieldX, action.fieldZ)
  end
  self:_settleScope()
end

function State:_confirmRemoval()
  local pending = assert(self.pendingRemove)
  assert(pending.kind == "bag", "only bag removal keeps a confirmation path")
  self.pendingRemove = nil
  self.controller:closeModal()
  local oldRows = self.session:bagSnapshot(self.controller.bagPocket)
  local oldIndex = 1
  for index, row in ipairs(oldRows) do
    if row.item == pending.itemKey then
      oldIndex = index
      break
    end
  end
  self:_publishBagQuantity(pending.itemKey, 0)
  self.controller.bagItemKey = nil
  local rows = self.session:bagSnapshot(self.controller.bagPocket)
  self.controller.bagPage0 = math.min(self.controller.bagPage0, math.max(0, math.ceil(#rows / 6) - 1))
  local focusRow = rows[math.min(oldIndex, #rows)]
  self.controller.focus = focusRow and "bag:item:" .. focusRow.item or "bag:add"
end

-- Reports whether a destination verification is currently pending.
function State:_locationSavePending()
  return self.locationSave ~= nil and self.locationSave:status() ~= nil
end

-- Builds the bounded enablement facts for the canonical decision set.
-- A save target cancels a running verification only outside a close
-- decision; inside one it keeps attempting the close save instead.
---@param saveStatus { state: string, operationId: integer }?
---@return { pendingSave: boolean }
function State:_decisionFacts(saveStatus)
  local pending = saveStatus ~= nil or self:_locationSavePending()
  return { pendingSave = pending and self.closeRequest == nil }
end

function State:_save(leave)
  if not self.session then
    return false
  end
  if self:_locationSavePending() then
    return false
  end
  if not self:_prepareLocationForSave(leave) then
    if self:_locationSavePending() then
      return false
    end
    if leave and self.closeRequest ~= nil then
      self.closeRequest.phase = "confirm"
    end
    return false
  end
  if not self:_applyCurrentPartyDraftIfNeeded() then
    if leave and self.closeRequest ~= nil then
      self.closeRequest.phase = "confirm"
    end
    return false
  end
  local result = self.session:save(self.valueEditor ~= nil)
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
  self.pendingMoveSlot = nil
  self.moveChildReturn = nil
  self.moveChildAction = nil
  self.closeRequest = nil
  self.pendingRemove = nil
  self.pendingQuantity = nil
  self.errorMessage = nil
  self.controller.partyTab = "Stats"
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

function State:_discardSection()
  self:_cancelPendingLocationSave()
  local section = self.controller.section
  local editorSections = {
    money = "Player",
    dialogue_frame = "Player",
    party_field = "Party",
    party_add_species = "Party",
    party_add_move = "Party",
    party_move_key = "Party",
    party_move_pp = "Party",
    party_move_pp_ups = "Party",
    bag_add_item = "Bag",
    bag_quantity = "Bag",
  }
  if self.valueEditor ~= nil and editorSections[self.valuePurpose] == section then
    self.valueEditor:cancel()
    self.valueEditor, self.valuePurpose, self.activeDraftField = nil, nil, nil
    self.valueReturnFocus, self.pendingFocusReturn = nil, nil
    self.pendingQuantity = nil
    self.numberHold = nil
    self.numberPressTarget = nil
  end
  if section == "Party" then
    self.monDraft = nil
    self.pendingMoveSlot = nil
    self.moveChildReturn = nil
    self.moveChildAction = nil
    if self.controller.modal == "party-move" then
      self.controller:closeModal()
    end
    self.errorMessage = nil
    assert(self.session, "section discard needs its ready session"):discardSection(section)
    local members = self.session:partySnapshot().members
    local slot0 = self.controller.partySlot0
    local present = false
    for _, member in ipairs(members) do
      if member.slot0 == slot0 then
        present = true
        break
      end
    end
    if not present then
      slot0 = #members > 0 and members[1].slot0 or nil
      self.controller.partySlot0 = slot0
    end
    self.controller.focus = slot0 ~= nil and ("party:slot:" .. slot0) or "party:add"
    self:_ensurePartyDraft()
    return
  elseif section == "Bag" then
    if self.controller.modal == "bag-item" or self.controller.modal == "remove" then
      self.pendingRemove = nil
      self.pendingQuantity = nil
      self.controller:closeModal()
      self.controller.bagItemKey = nil
      self.controller.focus = "bag:pocket:" .. self.controller.bagPocket
    end
  end
  self.errorMessage = nil
  local changed = assert(self.session, "section discard needs its ready session"):discardSection(section)
  if changed and section == "Location" then
    self:_syncLocationToSession()
  end
end

function State:_requestBack()
  if self.valueEditor then
    if self.moveChildReturn ~= nil then
      self.valueEditor:cancel()
      self.valueEditor = nil
      self.valuePurpose = nil
      self.activeDraftField = nil
      self.valueReturnFocus = nil
      self.pendingFocusReturn = nil
      local slot0, action = assert(self.moveChildReturn), assert(self.moveChildAction)
      self:_showMoveOverlay(slot0, action)
    else
      self.valueEditor:cancel()
      self.pendingFocusReturn = self.valueReturnFocus
      self.valueEditor = nil
      self.valuePurpose = nil
      self.activeDraftField = nil
      self.valueReturnFocus = nil
      self.controller:cancelInteraction()
    end
  elseif self.controller.modal ~= nil then
    self:_popDecision()
  elseif self.monDraft ~= nil then
    if not self:_applyCurrentPartyDraftIfNeeded() then
      return
    end
    if self.session and self.session:isDirty() then
      self:requestClose("back")
    else
      self:_sendResult()
    end
  elseif self.controller.section == "Bag" and self.controller.bagItemKey ~= nil then
    self.controller.bagItemKey = nil
    self.controller.focus = "bag:pocket:" .. self.controller.bagPocket
  elseif self.controller.section == "Location" and self.controller.locationPage == "grid" then
    self.controller:openLocationMaps()
    if self.locationService ~= nil then
      self.locationService:releaseGrid()
    end
    self.locationServiceMapId = nil
    self.locationViewport = nil
    self.locationActionStatus = nil
    self.errorMessage = nil
  elseif self.session and self.session:isDirty() then
    self:requestClose("back")
  else
    self:_sendResult()
  end
end

function State:_popDecision()
  local modal = assert(self.controller.modal, "decision pop needs its open decision")
  if modal == "leave" and self.closeRequest ~= nil then
    self:_cancelPendingLocationSave()
    local request = assert(self.closeRequest)
    self.closeRequest = nil
    self.controller.modal = request.previousModal
    self.controller.modalReturnFocus = request.previousModalReturnFocus
    self.controller.focus = request.previousFocus
  elseif modal == "party-move" then
    self.pendingMoveSlot = nil
    self.controller:closeModal()
  else
    if modal == "remove" then
      self.pendingRemove = nil
    end
    self.controller:closeModal()
  end
end

-- An occupied move slot owns a small decision layer with exactly three
-- component actions; each child editor suspends the overlay and returns to
-- it, so Back pops child, parent, then page one layer at a time.
function State:_showMoveOverlay(slot0, focusTarget)
  local draft = assert(self.monDraft, "a move overlay needs its member draft")
  assert(
    type(slot0) == "number" and slot0 % 1 == 0 and draft:record().moves[slot0 + 1] ~= nil,
    "a move overlay needs its occupied slot"
  )
  self.pendingMoveSlot = slot0
  self.moveChildReturn = nil
  self.moveChildAction = nil
  self.controller:openModal("party-move")
  self.controller.modalReturnFocus = "party:move:" .. slot0
  self.controller.focus = focusTarget or "party-move:move"
end

function State:_openMoveChild(action)
  local slot0 = assert(self.pendingMoveSlot, "a move component editor owns its slot")
  local draft = assert(self.monDraft, "a move component editor needs its member draft")
  local entry = assert(draft:record().moves[slot0 + 1], "a move component editor needs its occupied slot")
  local catalog = assert(self.dependencies.context.monCatalog)
  self.moveChildReturn = slot0
  self.moveChildAction = action
  self.controller.modal = nil
  self.controller.modalReturnFocus = nil
  if action == "party-move:move" then
    self:_installValueEditor(
      ValueEditor.new({
        kind = "choice",
        options = PartyView.options(assert(self.partyView), "moves", function()
          return catalog:moveKeys()
        end, function(key)
          return catalog:move(key).name or key
        end),
        value = entry.move,
      }),
      "party_move_key",
      action
    )
  elseif action == "party-move:pp" then
    local definition = catalog:move(entry.move)
    self:_installValueEditor(
      ValueEditor.new({
        kind = "integer",
        value = entry.pp,
        min = 0,
        max = Moves.maxPp(definition.basePp, entry.ppUps),
        base = "decimal",
      }),
      "party_move_pp",
      action
    )
  else
    assert(action == "party-move:pp-ups", "unknown move component action " .. tostring(action))
    self:_installValueEditor(
      ValueEditor.new({ kind = "integer", value = entry.ppUps, min = 0, max = 3, base = "decimal" }),
      "party_move_pp_ups",
      action
    )
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

-- Executes one canonical decision command for the already-matched
-- descriptor. Unknown commands are programming errors; targets outside
-- the published descriptor set never reach this map.
function State:_performDecisionCommand(kind, command, id)
  if command == "cancel" then
    if kind == "leave" and self.closeRequest ~= nil then
      self:_cancelPendingLocationSave()
      local request = assert(self.closeRequest)
      self.closeRequest = nil
      self.controller.modal = request.previousModal
      self.controller.modalReturnFocus = request.previousModalReturnFocus
      self.controller.focus = request.previousFocus
    elseif kind == "party-move" then
      self.pendingMoveSlot = nil
      self.controller:closeModal()
    elseif kind == "remove" then
      self.pendingRemove = nil
      self.controller:closeModal()
      if self.controller.section == "Bag" and self.controller.bagItemKey then
        self.controller.focus = "bag:item:" .. self.controller.bagItemKey
      end
    elseif kind == "bag-item" then
      self.controller:closeModal()
    else
      error("unknown cancelled decision kind " .. tostring(kind), 0)
    end
    return
  end
  if kind == "bag-item" then
    if command == "bag_quantity" then
      self:_openBagQuantity("set")
    elseif command == "bag_remove" then
      self.pendingRemove = { kind = "bag", itemKey = assert(self.controller.bagItemKey) }
      self.controller:openModal("remove")
    else
      error("unknown bag decision command " .. tostring(command), 0)
    end
  elseif kind == "party-move" then
    if command == "party-move:move" or command == "party-move:pp" or command == "party-move:pp-ups" then
      self:_openMoveChild(id)
    else
      error("unknown move decision command " .. tostring(command), 0)
    end
  elseif kind == "remove" then
    if command == "confirm_remove" then
      self:_confirmRemoval()
    else
      error("unknown removal decision command " .. tostring(command), 0)
    end
  elseif kind == "leave" then
    if command == "discard" then
      if self.closeRequest ~= nil then
        self:_performClose("discard")
      else
        self:_discard(false)
      end
    elseif command == "save" then
      if self.closeRequest ~= nil then
        self:_performClose("save")
      else
        self:_save(true)
      end
    elseif command == "cancel_pending_save" then
      self:_cancelPendingLocationSave()
      self.errorMessage = "Destination verification canceled."
    else
      error("unknown leave decision command " .. tostring(command), 0)
    end
  else
    error("unknown decision kind " .. tostring(kind), 0)
  end
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
    elseif valueKind == "name" then
      local controlId = targetId:match("^name%-control:(.+)$")
      self.valueEditor:activateTarget(controlId or targetId)
    elseif targetId == "confirm" then
      self.valueEditor:press("confirm")
    elseif valueKind == "number" and targetId:match("^number:delta:(%-?%d+)$") then
      self:_adjustNumber(assert(tonumber(targetId:match("^number:delta:(%-?%d+)$"))))
    else
      self.valueEditor:activateTarget(targetId)
    end
    self:_finishValueEditor()
    return
  end
  if self.controller.modal then
    local kind = assert(self.controller.modal, "decision activation needs its open decision")
    local selected = nil
    for _, action in ipairs(Decisions.describe(kind, self:_decisionFacts(nil))) do
      if action.id == targetId then
        selected = action
        break
      end
    end
    if selected ~= nil and selected.enabled then
      self:_performDecisionCommand(kind, selected.command, selected.id)
    end
    return
  end
  local section = targetId:match("^section:(.+)$")
  if section ~= nil then
    self:_requestDraftResolution({ kind = "section", section = section })
    return
  end
  if targetId == "money" then
    self:_cancelPendingLocationSave()
    local money = assert(self.session:snapshot().money)
    self:_installValueEditor(
      ValueEditor.new({ kind = "integer", value = money, min = 0, max = PlayerData.MAX_MONEY, base = "decimal" }),
      "money"
    )
  elseif targetId == "dialogue-frame" then
    self:_cancelPendingLocationSave()
    local frameIndexes = assert(self.dependencies.context.frameIndexes)
    local choices = {}
    for frameIndex in pairs(frameIndexes) do
      choices[#choices + 1] = frameIndex
    end
    table.sort(choices)
    local options = {}
    for _, frameIndex in ipairs(choices) do
      options[#options + 1] = { key = tostring(frameIndex), label = "Frame " .. tostring(frameIndex + 1) }
    end
    self:_installValueEditor(
      ValueEditor.new({ kind = "choice", options = options, value = tostring(self.session:snapshot().frameIndex) }),
      "dialogue_frame"
    )
  elseif targetId:sub(1, 5) == "flag:" then
    local name = targetId:sub(6)
    local current = self.session:snapshot().flags[FieldScriptSymbols.flagsByName[name]] == true
    local result = self.session:setFlag(name, not current)
    if not result.ok then
      self.errorMessage = message(result.error)
    end
  elseif targetId == "save" then
    if self:_locationSavePending() then
      self:_cancelPendingLocationSave()
      self.errorMessage = "Destination verification canceled."
    else
      self:_requestDraftResolution({ kind = "save" })
    end
  elseif targetId == "discard" then
    self:_discardSection()
  elseif targetId == "back" then
    self:_requestBack()
  elseif targetId:match("^party:slot:") then
    local slot0 = assert(tonumber(targetId:match("^party:slot:(%d+)$")))
    self:_requestDraftResolution({ kind = "party-slot", slot0 = slot0 })
  elseif targetId == "party:add" then
    if not self:_applyCurrentPartyDraftIfNeeded() then
      return
    end
    self:_cancelPendingLocationSave()
    local catalog = assert(self.dependencies.context.monCatalog)
    local options = PartyView.options(assert(self.partyView), "species", function()
      return catalog:speciesKeys()
    end, function(key)
      return catalog:species(key).name or key
    end)
    self:_installValueEditor(ValueEditor.new({ kind = "choice", options = options }), "party_add_species")
  elseif targetId == "party:page:previous" then
    self.controller:stepPartyTab("previous")
  elseif targetId == "party:page:next" then
    self.controller:stepPartyTab("next")
  elseif targetId:match("^party:field:") then
    if not self:_ensurePartyDraft() then
      return
    end
    local descriptor = self:_partyField(targetId)
    if descriptor ~= nil then
      self:_openEditor(descriptor)
      self.valuePurpose = "party_field"
    end
  elseif targetId == "party:use-species-name" then
    if not self:_ensurePartyDraft() then
      return
    end
    if not self:_setDraftValue({ setter = "scalar", fieldId = "nickname" }, nil) then
      self.errorMessage = "Nickname could not be cleared."
    else
      self.errorMessage = nil
    end
  elseif targetId:match("^party:move:%d+$") then
    if not self:_ensurePartyDraft() then
      return
    end
    self:_showMoveOverlay(assert(tonumber(targetId:match("^party:move:(%d+)$"))))
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
  elseif targetId:match("^bag:pocket:") then
    local pocket = assert(targetId:match("^bag:pocket:(.+)$"))
    self.controller:selectBagPocket(pocket)
  elseif targetId:match("^bag:item:") then
    self.controller:selectBagItem(assert(targetId:match("^bag:item:(.+)$")))
    self.controller:openModal("bag-item")
  elseif targetId == "bag:page:previous" or targetId == "bag:page:next" then
    self.controller:setBagPage(math.max(0, self.controller.bagPage0 + (targetId == "bag:page:next" and 1 or -1)))
  elseif targetId == "bag:add" then
    self:_cancelPendingLocationSave()
    self:_beginBagAdd()
  elseif targetId == "bag:quantity" then
    self:_openBagQuantity("set")
  elseif targetId == "bag:remove" then
    self.pendingRemove = { kind = "bag", itemKey = assert(self.controller.bagItemKey) }
    self.controller:openModal("remove")
  end
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
    intent.kind == "location-map-select"
    or intent.kind == "location-cursor-move"
    or intent.kind == "location-pan"
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
    elseif intent.modal == "party-move" then
      self.pendingMoveSlot = nil
      self.controller:closeModal()
    elseif intent.modal == "remove" then
      self.pendingRemove = nil
      self.controller.modalReturnFocus = nil
    else
      self.controller:closeModal()
    end
  elseif intent.kind == "scroll-drag" then
    local view = self:_snapshot()
    if intent.scopeId ~= view.scope.id or intent.scopeEpoch ~= view.scope.epoch then
      return
    end
    local layout = assert(self:_resolve(view).content.layout)
    self:_setScrollOffset(view, layout, intent.viewportId, intent.offset)
  elseif intent.kind == "move" then
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
    self.controller:cancelInteraction()
  end
end

function State:_revealFocusedRow(_)
  local view = self:_snapshot()
  local section = self.controller.section
  if section == "Bag" then
    return
  end
  if section == "Party" and (view.partyTab ~= "Details" or view.partyDetails == nil) then
    return
  end
  local rows = section == "Party" and view.partyDetails.rows or section == "Progress" and view.flagRows or {}
  ---@cast rows { targetId: string?, name: string? }[]
  local rowIndex
  for index, row in ipairs(rows) do
    local targetId = row.targetId or ("flag:" .. assert(row.name, "flag rows carry their logical name"))
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
  local purpose = section == "Party" and ("party:" .. tostring(view.partyTab))
    or section == "Bag" and ("bag:" .. tostring(view.bagPocket))
    or "flags"
  self.controller.scrollOffsets[purpose] = ScrollViewport.clamp(offset, viewport.contentExtent, viewport.clip.height)
end

function State:_pointer(events)
  if self.disposed then
    return
  end
  self:_settleScope()
  local view = self:_snapshot()
  local plan = self:_resolve(view)
  local mapped = self.presentation:mapInput(events, view)
  for _, event in ipairs(mapped) do
    self._pointerDispatching = event.pointerId == "mouse:1"
    local heldNumberTarget = self.numberHold ~= nil and self.numberHold.targetId or nil
    if event.type == "pointer_up" or event.type == "pointer_cancel" then
      if self.numberHold == nil or event.pointerId == nil or event.pointerId == self.numberHold.pointerId then
        self.numberHold = nil
      end
      if event.type == "pointer_cancel" then
        self.numberPressTarget = nil
      end
    end
    local intent = self.controller:pointer(event)
    if event.type == "pointer_down" and event.targetId ~= nil and self.controller.focus == event.targetId then
      local lists = plan.content.layout.lists
      if type(lists) == "table" then
        local list = findListByRowTarget(lists, event.targetId)
        if list ~= nil then
          self.controller:setListCursor(list.id, event.targetId)
        end
      end
    end
    if not (event.type == "pointer_up" and heldNumberTarget ~= nil) then
      self:_dispatchIntent(intent)
    end
    if
      event.type == "pointer_down"
      and self.valueEditor ~= nil
      and self.valueEditor:snapshot().kind == "number"
      and event.targetId ~= nil
      and event.targetId:match("^number:delta:(%-?%d+)$")
    then
      local delta = math.floor(assert(tonumber(event.targetId:match("^number:delta:(%-?%d+)$"))))
      self:_adjustNumber(delta)
      local pressTicks = assert(view.numberPressTicks, "number controls carry source press timing")
      assert(pressTicks > 0 and pressTicks % 1 == 0, "number control press timing is a positive integer")
      self.numberPressTarget = event.targetId
      self.numberPressUntilTick = self.inputTick + pressTicks
      self.numberHold = {
        pointerId = event.pointerId,
        targetId = event.targetId,
        delta = delta,
        scopeEpoch = self.controller.scopeEpoch,
        nextTick = self.inputTick + FieldInput.UI_REPEAT_DELAY_TICKS,
      }
    end
    self._pointerDispatching = false
  end
  if self.disposed then
    return plan
  end
  self:_reconcileFocus()
  self:_settleScope()
  return plan
end

function State:view()
  local view = self:_snapshot()
  local plan = self:_resolve(view)
  view.presentation = plan
  view.layout = plan.content.layout
  return view
end

-- Draw only consumes the settled publication: it never changes scope,
-- input buffers, focus, drafts, selection, hold counters, verification
-- state, or resource demand. Visible icon preparation runs on update.
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
  self.numberHold = nil
  self.numberPressTarget = nil
  self.locationViewport = nil
  self.locationGridWidthTiles = nil
  self.locationGridHeightTiles = nil
  self:_settleScope()
end

function State:focus(focused)
  if not focused then
    self.presentation:cancelPointers()
    self.controller:cancelInteraction()
    self.numberHold = nil
    self.numberPressTarget = nil
    self.fieldInput:clearAll()
    self.fieldInput:beginUi(self.inputTick)
    self:_settleScope()
  end
end

-- Consumes one batch of normalized UI events. Scope settles before the
-- first event acts, so already-retired captures cannot fire, and after
-- the batch, so later batches observe the settled epoch.
function State:_consumeUiInput(events)
  self:_settleScope()
  for _, event in ipairs(events) do
    if event.type == "navigate" then
      self.controller:markKeyboardNavigation()
      if self.controller.modal then
        local layout = self:_reconcileFocus()
        self.controller:moveFocus(layout.focusGraph, event.direction)
      elseif self.valueEditor then
        local snapshot = self.valueEditor:snapshot()
        if snapshot.kind == "choice" then
          local layout = self:_reconcileFocus()
          local list, rowIndex = self:_activeList(layout)
          if list ~= nil and list.id == "value:choice" and rowIndex ~= nil then
            self:_moveListRow(list, rowIndex, event.direction, layout)
            self.controller:cancelInteraction()
          elseif list ~= nil and list.id == "value:choice" then
            self.controller:moveFocus(layout.focusGraph, event.direction)
            self.controller:cancelInteraction()
          else
            self.preserveChoiceScroll = false
            if event.direction == "up" or event.direction == "down" then
              self.valueEditor:moveChoice(event.direction == "up" and -1 or 1)
            else
              local viewport = assert(layout.viewports["value:choice"])
              local visibleCount = math.max(1, viewport.lastIndex - viewport.firstIndex + 1)
              self.valueEditor:moveChoice((event.direction == "left" and -1 or 1) * visibleCount)
            end
            local selected = self.valueEditor:snapshot().selectedKey
            self.controller.focus = selected and ("choice:" .. selected) or "cancel"
          end
        elseif snapshot.kind == "name" or snapshot.kind == "number" then
          self.valueEditor:press(event.direction)
        end
      else
        local layout = self:_reconcileFocus()
        local list, rowIndex = self:_activeList(layout)
        if list ~= nil and rowIndex ~= nil then
          self:_moveListRow(list, rowIndex, event.direction, layout)
          self.controller:cancelInteraction()
        else
          self:_dispatchIntent(self.controller:press(event.direction))
        end
      end
    elseif event.type == "confirm" then
      local currentLayout = self:_reconcileFocus()
      if self.controller.modal then
        local target = currentLayout.targets[self.controller.focus]
        if target and target.activationEnabled and currentLayout.focusGraph[self.controller.focus] then
          self:_dispatchIntent(self.controller:press("confirm"))
        end
      elseif self:_activeList(currentLayout) ~= nil then
        local list, rowIndex = self:_activeList(currentLayout)
        self:_handleListConfirm(assert(list), rowIndex, currentLayout)
      elseif self.valueEditor then
        local confirmTarget = currentLayout.targets.confirm
        if self.valueEditor:snapshot().kind == "choice" and confirmTarget and not confirmTarget.activationEnabled then
          self.editorFeedback = "Choose an available option."
        elseif self.valueEditor:snapshot().kind == "name" then
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
      else
        local layout = self:_resolve(self:_snapshot()).content.layout
        local list, rowIndex = self:_activeList(layout)
        if list ~= nil and rowIndex ~= nil then
          self.controller:setFocus(list.targetId)
        elseif self.valueEditor then
          self.valueEditor:cancel()
          self:_finishValueEditor()
        else
          self:_dispatchIntent(self.controller:press("cancel"))
        end
      end
    end
  end
  self:_reconcileFocus()
  self:_settleScope()
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
    local editorLayout = self:_resolve(self:_snapshot()).content.layout
    local editorList, editorRow = self:_activeList(editorLayout)
    local choiceList = editorList ~= nil and editorList.id == "value:choice" and editorList or nil
    if key == "return" or key == "kpenter" then
      if choiceList ~= nil then
        self:_handleListConfirm(choiceList, editorRow, editorLayout)
      else
        local submitted, reason = self.valueEditor:submit()
        self.editorFeedback = submitted and nil or reason
        self:_finishValueEditor()
      end
    elseif key == "escape" then
      if choiceList ~= nil and editorRow ~= nil then
        self.controller:setFocus(choiceList.targetId)
      else
        self.valueEditor:cancel()
        self:_finishValueEditor()
      end
    elseif key == "backspace" then
      if choiceList ~= nil then
        self:_filterFocusedList(choiceList, editorRow, "backspace")
      else
        self.valueEditor:press("backspace")
      end
    elseif key == "delete" then
      if choiceList ~= nil then
        self:_filterFocusedList(choiceList, editorRow, "clear")
      else
        self.valueEditor:press("clear_search")
      end
    elseif key == "left" or key == "right" or key == "up" or key == "down" then
      self.controller:markKeyboardNavigation()
      if choiceList ~= nil and editorRow ~= nil then
        self:_moveListRow(choiceList, editorRow, key, editorLayout)
      elseif choiceList ~= nil then
        self.controller:moveFocus(editorLayout.focusGraph, key)
      elseif self.valueEditor:snapshot().kind == "choice" and (key == "left" or key == "right") then
        local viewport = assert(editorLayout.viewports["value:choice"])
        local visibleCount = math.max(1, viewport.lastIndex - viewport.firstIndex + 1)
        self.valueEditor:moveChoice((key == "left" and -1 or 1) * visibleCount)
      else
        self.valueEditor:press(key)
      end
    end
    self:_reconcileFocus()
    self:_settleScope()
    return
  end
  if key == "backspace" or key == "delete" then
    local layout = self:_resolve(self:_snapshot()).content.layout
    local list, rowIndex = self:_activeList(layout)
    if list ~= nil and list.filterable then
      self:_filterFocusedList(list, rowIndex, key == "delete" and "clear" or "backspace")
      self:_reconcileFocus()
      self:_settleScope()
    end
    return
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
      local layout = self:_resolve(self:_snapshot()).content.layout
      local list, rowIndex = self:_activeList(layout)
      if list ~= nil and list.id == "value:choice" then
        self:_filterFocusedList(list, rowIndex, "append", text)
      else
        self.preserveChoiceScroll = false
        self.valueEditor:textinput(text)
      end
    else
      self.valueEditor:textinput(text)
    end
    self.editorFeedback = nil
    self:_settleScope()
    return
  end
  local layout = self:_resolve(self:_snapshot()).content.layout
  local list, rowIndex = self:_activeList(layout)
  if list == nil or not list.filterable then
    return
  end
  self:_filterFocusedList(list, rowIndex, "append", text)
  self:_settleScope()
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
  assert(layout.scrollOwner == viewportId, "scroll intent must belong to the active owner")
  local viewport = assert(layout.viewports[viewportId], "active scroll owner needs a published viewport")
  local clamped = ScrollViewport.clamp(offset, viewport.contentExtent, viewport.clip.height)
  local list
  if type(layout.lists) == "table" then
    list = findListByViewportId(layout.lists, viewportId)
  end
  if list ~= nil then
    self:_storeListOffset(list, clamped)
    self:_clampListCursorToVisible(list, viewport, clamped)
  elseif viewportId == "location:map-list" then
    self.controller.locationMapOffset = clamped
  else
    if viewportId == "value:choice" then
      self.preserveChoiceScroll = true
    end
    local purpose = assert(scrollPurpose(viewportId, view))
    self.controller.scrollOffsets[purpose] = clamped
  end
end

function State:wheelmoved(_, y)
  local view = self:_snapshot()
  local layout = assert(self:_resolve(view).content.layout)
  local viewportId = layout.scrollOwner
  if viewportId == nil then
    return
  end
  local viewport = assert(layout.viewports[viewportId], "active scroll owner needs a published viewport")
  self:_setScrollOffset(view, layout, viewportId, viewport.offset - y * viewport.rowExtent)
  self:_settleScope()
end

function State:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  self.numberHold = nil
  self.numberPressTarget = nil
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
end

return State
