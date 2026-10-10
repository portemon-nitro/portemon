-- Coordinates the editor's asynchronous opening, input, session, and resources.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local HgssInputBindings = require("libs.hgss.src.ui.HgssInputBindings")
local FieldInput = require("libs.hgss.src.field.FieldInput")
local PlayerData = require("libs.hgss.src.save.PlayerData")
local DisplayContext = require("libs.ui.src.DisplayContext")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local Interface = require("app.src.saveeditor.SaveEditorInterface")
local Moves = require("libs.mons.src.gen4.Moves")
local Renderer = require("app.src.saveeditor.SaveEditorRenderer")
local Controller = require("app.src.saveeditor.SaveEditorController")
local Decisions = require("app.src.saveeditor.SaveEditorDecisions")
local LocationSave = require("app.src.saveeditor.SaveEditorLocationSave")
local SaveEditorNavigation = require("app.src.saveeditor.SaveEditorNavigation")
local ValueEditor = require("app.src.saveeditor.SaveEditorValueEditor")
local PartyView = require("app.src.saveeditor.SaveEditorPartyView")
local ScrollViewport = require("libs.ui.src.ScrollViewport")
local Composition = require("app.src.saveeditor.SaveEditorComposition")
local LocationService = require("app.src.saveeditor.SaveEditorLocationService")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
local ItemAssetSchema = require("libs.assets.src.ItemAssetSchema")
local ModalStack = require("app.src.saveeditor.SaveEditorModalStack")
local MapCatalog = require("app.src.saveeditor.SaveEditorMapCatalog")
local SaveEditorPreset = require("app.src.saveeditor.SaveEditorPreset")

---@class SaveEditorBagItemMetadata
---@field item string
---@field label string
---@field iconKey string?

---@class SaveEditorFlagRow
---@field name string
---@field displayName string
---@field id integer
---@field targetId string

---@class SaveEditorBagOption
---@field key string
---@field label string

---@generic T
---@class SaveEditorIncrementalSort<T>
---@field source T[]
---@field destination T[]
---@field less fun(left: T, right: T): boolean
---@field width integer
---@field left integer
---@field leftEnd integer?
---@field rightEnd integer?
---@field i integer?
---@field j integer?
---@field output integer

---@generic T
---@param rows T[]
---@param less fun(left: T, right: T): boolean
---@return SaveEditorIncrementalSort<T>
local function newIncrementalSort(rows, less)
  return {
    source = rows,
    destination = {},
    less = less,
    width = 1,
    left = 1,
    output = 1,
  }
end

---@generic T
---@param sort SaveEditorIncrementalSort<T>
---@param budget integer
---@return integer, boolean
local function advanceIncrementalSort(sort, budget)
  local used = 0
  local count = #sort.source
  while used < budget and sort.width < count do
    if sort.left > count then
      sort.source, sort.destination = sort.destination, sort.source
      sort.width = sort.width * 2
      sort.left = 1
      sort.output = 1
      if sort.width >= count then
        return used, true
      end
    end
    if sort.leftEnd == nil then
      sort.leftEnd = math.min(sort.left + sort.width - 1, count)
      sort.rightEnd = math.min(sort.left + sort.width * 2 - 1, count)
      sort.i = sort.left
      sort.j = sort.leftEnd + 1
    end
    local i = assert(sort.i)
    local j = assert(sort.j)
    local leftEnd = assert(sort.leftEnd)
    local rightEnd = assert(sort.rightEnd)
    if i > leftEnd and j > rightEnd then
      sort.left = rightEnd + 1
      sort.leftEnd = nil
      sort.rightEnd = nil
      sort.i = nil
      sort.j = nil
    else
      local takeLeft = i <= leftEnd and (j > rightEnd or not sort.less(sort.source[j], sort.source[i]))
      if takeLeft then
        sort.destination[sort.output] = sort.source[i]
        sort.i = i + 1
      else
        sort.destination[sort.output] = sort.source[j]
        sort.j = j + 1
      end
      sort.output = sort.output + 1
      used = used + 1
    end
  end
  return used, sort.width >= count
end

---@class SaveEditorBagCatalogMetadata
---@field catalog ItemCatalog
---@field pockets { key: string }[]
---@field pocketByKey table<string, table<string, unknown>>
---@field optionsByPocket table<string, { key: string, label: string }[]>
---@field itemByKey table<string, SaveEditorBagItemMetadata>

---@class SaveEditorBagCatalogTask
---@field catalog ItemCatalog
---@field nextItemKey fun(): string?
---@field pockets { key: string }[]
---@field pocketByKey table<string, table<string, unknown>>
---@field optionsByPocket table<string, { key: string, label: string }[]>
---@field itemByKey table<string, SaveEditorBagItemMetadata>
---@field sortPocketIndex integer
---@field sort SaveEditorIncrementalSort<SaveEditorBagOption>?
---@field stage "scan"|"sort"

---@class SaveEditorFlagCatalogTask
---@field iterator fun(state: table<string, integer>, key: string?): string?, integer?
---@field state table<string, integer>
---@field key string?
---@field rows SaveEditorFlagRow[]
---@field stage "scan"|"sort"|"index"
---@field sort SaveEditorIncrementalSort<SaveEditorFlagRow>?
---@field rowTargets string[]
---@field indexByTarget table<string, integer>
---@field indexCursor integer

---@class SaveEditorBagPageRow
---@field item string
---@field label string
---@field iconKey string?
---@field quantity integer

---@class SaveEditorBagProjection
---@field catalog ItemCatalog
---@field pocket string
---@field revision integer
---@field rows SaveEditorBagItemMetadata[]
---@field rowByItem table<string, SaveEditorBagItemMetadata>
---@field quantityByItem table<string, integer>
---@field pageRows table<integer, SaveEditorBagPageRow[]>
---@field pageCount integer

---@class SaveEditorLocationService
---@field newMapSummaryTask fun(self: SaveEditorLocationService): SaveEditorMapSummaryTask
---@field openMap fun(self: SaveEditorLocationService, mapId: integer, request: { purpose: "browse"|"verify" }?)
---@field releaseGrid fun(self: SaveEditorLocationService)
---@field cancelInitialSurvey fun(self: SaveEditorLocationService)
---@field setViewport fun(self: SaveEditorLocationService, centerX: integer, centerZ: integer, widthTiles: integer, heightTiles: integer)
---@field update fun(self: SaveEditorLocationService)
---@field snapshot fun(self: SaveEditorLocationService): table<string, unknown>
---@field resolve fun(self: SaveEditorLocationService, mapId: integer, fieldX: integer, fieldZ: integer, expectedGeneration: integer): SaveEditorLocation?, table<string, unknown>
---@field dispose fun(self: SaveEditorLocationService)

---@class SaveEditorPendingPreset
---@field session SaveEditorSession
---@field sessionRevision integer
---@field preset SaveEditorPresetData
---@field mapId integer
---@field fieldX integer
---@field fieldZ integer
---@field metLocation integer
---@field date table<string, integer>
---@field service SaveEditorLocationService

---@class SaveEditorLocationListBuildTask
---@field listId string
---@field source SaveEditorMapCatalogRow[]
---@field cursor integer
---@field rows SaveEditorMapCatalogRow[]
---@field rowTargets string[]
---@field indexByTarget table<string, integer>

---@class SaveEditorListFilterRow
---@field targetId string
---@field name string?
---@field displayName string
---@field symbol string?
---@field section string?
---@field mapId integer?
---@field id integer?
---@field value boolean?
---@field kind "group"|"map"?
---@field mapSectionNativeId integer?
---@field groupId string?
---@field maps SaveEditorMapCatalogRow[]?

---@class SaveEditorIndexedListCache
---@field query string
---@field revision integer
---@field queryRevision integer
---@field rows SaveEditorListFilterRow[]
---@field rowTargets string[]
---@field indexByTarget table<string, integer>
---@field source SaveEditorListFilterRow[]?

---@class SaveEditorIndexedListProjection
---@field revision integer
---@field queryRevision integer
---@field pending boolean
---@field count integer
---@field rowTargets string[]
---@field indexByTarget table<string, integer>
---@field idAt fun(index: integer): string?
---@field indexOf fun(targetId: string): integer?
---@field rowAt fun(index: integer): SaveEditorListFilterRow?

---@class SaveEditorListFilterTask
---@field listId string
---@field query string
---@field foldedQuery string
---@field queryRevision integer
---@field revision integer
---@field cursor integer
---@field groupMapCursor integer?
---@field source SaveEditorListFilterRow[]
---@field rows SaveEditorListFilterRow[]
---@field rowTargets string[]
---@field indexByTarget table<string, integer>

---@class SaveEditorState
---@field _uiSessionSnapshot { owner: SaveEditorSession, revision: integer, value: SaveEditorSnapshot }?
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
---@field modalStack SaveEditorModalStack
---@field modalLayerSequence integer
---@field renderer SaveEditorRenderer?
---@field presentation ApplicationPresentation?
---@field status string
---@field message string
---@field session SaveEditorSession?
---@field dependencies table<string, unknown>?
---@field locationService SaveEditorLocationService?
---@field locationViewport table<string, number>?
---@field locationServiceMapId integer?
---@field locationPreviewMemory table<integer, { cursor: { fieldX: integer, fieldZ: integer }, center: { fieldX: integer, fieldZ: integer } }>
---@field locationAutoCenterToken { mapId: integer, generation: integer? }?
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
---@field activeDraftField table<string, unknown>?
---@field valuePurpose string?
---@field dateProvider fun(): table<string, integer>
---@field navigationDebug boolean
---@field iconStatus string?
---@field iconFailure string?
---@field locationSave SaveEditorLocationSave?
---@field pendingPreset SaveEditorPendingPreset?
---@field pendingRemove table<string, unknown>?
---@field pendingQuantity table<string, unknown>?
---@field numberHold { pointerId: string, targetId: string, delta: integer, scopeEpoch: integer, nextTick: integer }?
---@field numberPressTarget string?
---@field numberPressUntilTick integer
---@field fieldInput FieldInput
---@field inputTick integer
---@field tickRemainder number
---@field activeScopeId string?
---@field activeScopeRevision string?
---@field scopeEpoch integer
---@field editorFeedback string?
---@field _flagCatalog { name: string, displayName: string, id: integer, targetId: string, value: boolean? }[]?
---@field _flagFilter SaveEditorIndexedListCache?
---@field _mapCatalog SaveEditorIndexedListCache?
---@field _locationMapCatalog SaveEditorMapCatalog?
---@field _locationMapSummaryTask SaveEditorMapSummaryTask?
---@field _locationCatalogTask SaveEditorMapCatalogTask?
---@field _locationListBuildTask SaveEditorLocationListBuildTask?
---@field _locationCatalogLocation SaveEditorLocation?
---@field _locationListCaches table<string, SaveEditorIndexedListCache>
---@field _mapFilter SaveEditorIndexedListCache?
---@field _pendingChoiceCursor { targetId: string?, index: integer? }?
---@field _listFilterTask SaveEditorListFilterTask?
---@field _listQueryRevision integer?
---@field _pendingListCursor { listId: string, targetId: string?, index: integer? }?
---@field _bagCatalogMetadata SaveEditorBagCatalogMetadata?
---@field _bagCatalogTask SaveEditorBagCatalogTask?
---@field _flagCatalogTask SaveEditorFlagCatalogTask?
---@field _bagProjection SaveEditorBagProjection?
---@field _publishedView table<string, unknown>?
---@field _publishedPlan table<string, unknown>?
---@field _publishedDirty boolean?
---@field _publishedWidth number?
---@field _publishedHeight number?
---@field _publishedScopeEpoch integer?
---@field _publishedSession SaveEditorSession?
---@field _publishedSessionRevision integer?
---@field _publishedScopeId string?
---@field _publishedScopeRevision string?
---@field _publishedSignature string?
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
  assert(viewportId:match("^location:"), "unknown save editor scroll viewport " .. viewportId)
  return nil
end

local function locationListId(navigation)
  if navigation.page == "root" then
    return "location:root"
  elseif navigation.page == "group" then
    return assert(navigation.groupId, "a map group list has a stable group ID")
  end
  return nil
end

local function navigationSnapshot(layout, controller, editor)
  local remembered = {}
  for regionId, targetId in pairs(controller.focusByRegion[layout.scopeId] or {}) do
    remembered[regionId] = targetId
  end
  for listId, targetId in pairs(controller.listCursors) do
    remembered[listId] = targetId
  end
  return {
    scope = { id = layout.scopeId, epoch = layout.scopeEpoch },
    regions = layout.focusNavigation.regions,
    controls = layout.focusNavigation.controls,
    remembered = remembered,
    editor = editor,
  }
end

local function navigationSnapshotForState(state, layout)
  local editorKind = state.valueEditor and state.valueEditor:snapshot().kind or nil
  local editor
  if editorKind == "name" or editorKind == "number" then
    editor = { engaged = true, consumes = { up = true, down = true, left = true, right = true } }
  end
  return navigationSnapshot(layout, state.controller, editor)
end

local function logicalFocusIndex(logical, targetId)
  if logical.matrix ~= nil then
    for _, row in ipairs(logical.matrix) do
      for _, id in ipairs(row) do
        if id == targetId then
          return true
        end
      end
    end
    return false
  end
  return logical.indexOf ~= nil and logical.indexOf(targetId) ~= nil
end

local function logicalFocus(layout, targetId)
  local publication = layout.focusNavigation
  if publication == nil then
    return nil
  end
  for _, control in ipairs(publication.controls) do
    if control.id == targetId then
      return { scopeId = layout.scopeId, regionId = control.regionId, targetId = targetId }
    end
  end
  for _, region in ipairs(publication.regions) do
    if region.logical and logicalFocusIndex(region.logical, targetId) then
      return { scopeId = layout.scopeId, regionId = region.id, targetId = targetId }
    end
  end
  return nil
end

local function makeText(versionId)
  return FieldTextRenderer.new({ cacheFs = CacheFs.forVersion(versionId) })
end

local function scopeDescription(state)
  local controller = state.controller
  local scopeId
  local scopeRevision
  local scopeKind = controller.modal and "decision"
    or state.valueEditor and "value"
    or controller.section == "Party" and "party"
    or "section"
  if controller.modal then
    scopeId = "decision:" .. controller.modal
    scopeRevision = scopeId
  elseif state.valueEditor then
    local value = state.valueEditor:snapshot()
    scopeId = "value:" .. (state.valuePurpose or "editor")
    scopeRevision = table.concat({ scopeId, value.kind == "choice" and value.query or "" }, ":")
  elseif controller.section == "Party" then
    scopeId = "section:Party"
    scopeRevision = table.concat({ scopeId, tostring(controller.partySlot0), controller.partyTab }, ":")
  elseif controller.section == "Progress" then
    scopeId = "section:Progress"
    scopeRevision = table.concat({ scopeId, controller.query }, ":")
  elseif controller.section == "Bag" then
    scopeId = "section:Bag"
    scopeRevision = table.concat({ scopeId, controller.bagPocket, controller.bagPage0 }, ":")
  else
    scopeId = "section:" .. controller.section
    scopeRevision = controller.section == "Location"
        and table.concat({ scopeId, controller.locationPage, controller.query }, ":")
      or scopeId
  end
  return scopeId, scopeRevision, scopeKind
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
    navigationDebug = options.navigationDebug == true,
    displayContext = options.displayContext or DisplayContext.new({}),
    controller = Controller.new(),
    modalStack = ModalStack.new(),
    modalLayerSequence = 0,
    renderer = assert(rendererOrError),
    presentation = assert(presentationOrError),
    status = "opening",
    message = "Preparing save data",
    session = nil,
    dependencies = nil,
    locationService = nil,
    locationViewport = nil,
    locationServiceMapId = nil,
    locationPreviewMemory = {},
    locationAutoCenterToken = nil,
    _locationListCaches = {},
    locationGridWidthTiles = nil,
    locationGridHeightTiles = nil,
    locationSave = nil,
    pendingPreset = nil,
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
    activeScopeRevision = nil,
    scopeEpoch = 0,
    editorFeedback = nil,
    _publishedView = nil,
    _publishedPlan = nil,
    _publishedDirty = nil,
    _publishedWidth = nil,
    _publishedHeight = nil,
    _publishedScopeEpoch = nil,
    _publishedSession = nil,
    _publishedSessionRevision = nil,
    _publishedScopeId = nil,
    _publishedScopeRevision = nil,
    _publishedSignature = nil,
  }, State)
  self:_syncScope()
  -- The opening pair is published before any draw observes the state.
  local resolveOk, resolveError = pcall(function()
    self:_publishPublication()
  end)
  if not resolveOk then
    self.presentation:dispose()
    self.renderer:dispose()
    self.presentation, self.renderer = nil, nil
    error(resolveError, 0)
  end
  return self
end

function State:_syncScope()
  local scopeId, scopeRevision = scopeDescription(self)
  assert(scopeRevision ~= nil, "active focus scopes publish a layout revision")
  if scopeId == self.activeScopeId and scopeRevision == self.activeScopeRevision then
    return
  end
  local previousScopeId = self.activeScopeId
  if
    previousScopeId ~= nil
    and scopeId ~= previousScopeId
    and (previousScopeId:match("^decision:") or previousScopeId:match("^value:"))
  then
    self.controller.focusByScope[previousScopeId] = nil
    self.controller.focusByRegion[previousScopeId] = nil
  end
  self.activeScopeId = scopeId
  self.activeScopeRevision = scopeRevision
  self.scopeEpoch = self.scopeEpoch + 1
  self.fieldInput:beginUi(self.inputTick)
  self.controller:cancelInteraction()
  self.numberHold = nil
  self.numberPressTarget = nil
  self.controller.scopeId, self.controller.scopeEpoch = scopeId, self.scopeEpoch
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
  if
    self.locationService ~= nil
    and self.controller.section == "Location"
    and (self.controller.locationPage == "root" or self.controller.locationPage == "group")
  then
    self:_locationListCache(assert(locationListId(self.controller:locationSnapshot())))
  end
  self:_advanceLocationPreparation(256)
  self.tickRemainder = self.tickRemainder + (dt or 0) * 60
  if self.tickRemainder >= 1 then
    self.inputTick = self.inputTick + math.floor(self.tickRemainder)
    self.tickRemainder = self.tickRemainder % 1
    self:_consumeUiInput(self.fieldInput:uiSnapshot(self.inputTick))
  end
  local rowVisits = 0
  if self.valueEditor ~= nil then
    local wasFiltering = self.valueEditor:snapshot().pending == true
    rowVisits = self.valueEditor:update(256)
    if wasFiltering and self.valueEditor:snapshot().pending ~= true then
      self:_reconcilePublishedChoiceFilter()
    end
  end
  if self._listFilterTask ~= nil then
    if self._listFilterTask.listId ~= self:_activeFilterListId() then
      self._listFilterTask = nil
      self._pendingListCursor = nil
    else
      rowVisits = rowVisits + self:_advanceListFilter(math.max(0, 256 - rowVisits))
    end
  end
  if self.status == "ready" and self.session ~= nil then
    if self.controller.section == "Progress" then
      rowVisits = rowVisits + self:_advanceFlagCatalog(math.max(0, 256 - rowVisits))
    elseif self.controller.section == "Bag" then
      rowVisits = rowVisits + self:_advanceBagCatalog(math.max(0, 256 - rowVisits))
    end
  end
  local hold = self.numberHold
  if hold ~= nil then
    if self.controller.pointerId ~= hold.pointerId or self.controller.scopeEpoch ~= hold.scopeEpoch then
      self.numberHold = nil
    else
      while self.inputTick >= hold.nextTick do
        self.valueEditor:adjustPlace(hold.delta)
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
    self._locationMapSummaryTask = self.locationService:newMapSummaryTask()
    local originalLocation = assert(self.session:snapshot().location)
    self.controller:enterLocation(originalLocation)
    self.controller:setSection("Location")
    self:_syncScope()
    self._locationCatalogLocation = originalLocation
    self.status, self.errorMessage = "ready", nil
    self:_invalidatePublication()
    self:_settleScope()
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
  if self.pendingPreset ~= nil then
    local updated, updateError = pcall(self._stepPreset, self)
    if not updated then
      self:_finishPreset()
      error(updateError, 0)
    end
  end
  if self.status == "ready" and self.dependencies ~= nil and self.renderer ~= nil then
    self:_invalidatePublication()
    local view = self:_ensurePublished()
    local plan = assert(self._publishedPlan, "the settled publication owns its plan")
    self:_adoptGridSize(plan)
    self.renderer:prepareVisibleIcons(view, plan, self.dependencies.cacheFs, self.derivedAssets, true)
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
  self:_invalidatePublication()
  self:_settleScope()
end

-- Computes the interaction scope identity from navigation facts only. Pure:
-- scope changes are applied by _settleScope at explicit transition
-- boundaries, never while a view is being observed.
-- Applies scope publication, input ownership and page normalization for
-- the current navigation facts. Called after semantic input, transitions,
-- opening changes, resize and focus loss; never from view or draw.
function State:_settleScope()
  local scopeId, scopeRevision = scopeDescription(self)
  assert(scopeRevision ~= nil, "active focus scopes publish a layout revision")
  if scopeId ~= self.activeScopeId or scopeRevision ~= self.activeScopeRevision then
    self.activeScopeId = scopeId
    self.activeScopeRevision = scopeRevision
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
  local owner = self.session
  local session
  if owner == nil then
    self._uiSessionSnapshot = nil
  else
    local revision = owner:revision()
    local cached = self._uiSessionSnapshot
    if cached == nil or cached.owner ~= owner or cached.revision ~= revision then
      local value = owner:snapshot()
      cached = { owner = owner, revision = revision, value = value }
      self._uiSessionSnapshot = cached
    end
    session = cached.value
  end
  local section = self.controller.section
  local flagModel, flagRows, flagRowTargets, flagIndexByTarget
  if session ~= nil and section == "Progress" then
    flagModel = self:_flagProjection(session.flags)
    flagRows, flagRowTargets, flagIndexByTarget = flagModel.rowTargets, flagModel.rowTargets, flagModel.indexByTarget
  end
  local party = session and section == "Party" and self:_partyView() or {}
  local bag = session and section == "Bag" and self:_bagView() or {}
  local sessionDirty = false
  if session ~= nil then
    local dirtySections = session.dirtySections
    sessionDirty = dirtySections.money
      or dirtySections.frame
      or dirtySections.flags
      or dirtySections.party
      or dirtySections.bag
      or dirtySections.location
  end
  local modalTitle
  if self.controller.modal == "party-move" then
    local slot0 = assert(self.pendingMoveSlot, "move dialog owns its selected move slot")
    local record = assert(self.monDraft, "move dialog owns the active member draft"):record()
    local move = assert(record.moves[slot0 + 1], "move dialog owns an occupied move")
    local catalog = assert(self.dependencies).context.monCatalog
    local moveName = catalog:move(move.move).name or move.move
    modalTitle = "Edit move: " .. moveName
  end
  local modalLayers = self.modalStack:layers()
  local valueEditorSnapshot = self.valueEditor and self.valueEditor:snapshot() or nil
  if valueEditorSnapshot ~= nil then
    local layerKind = valueEditorSnapshot.kind == "number" and "number" or valueEditorSnapshot.kind
    for index = #modalLayers, 1, -1 do
      local layer = modalLayers[index]
      if layer.kind == layerKind then
        layer.payload.snapshot = valueEditorSnapshot
        break
      end
    end
  end
  local numberControlVisuals, numberPressTicks
  if valueEditorSnapshot ~= nil and valueEditorSnapshot.kind == "number" then
    local dependencies = assert(self.dependencies, "number editor requires its presentation manifest")
    local numberPresentation = assert(dependencies.bagManifest).interactive.overlays.quantity
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
    framePreviewIndex = self.valuePurpose == "dialogue_frame" and valueEditorSnapshot ~= nil and tonumber(
      valueEditorSnapshot.selectedKey
    ) or nil,
    ready = session ~= nil,
    dirty = session ~= nil
      and (sessionDirty or (self.monDraft ~= nil and (self.monDraft:mode() == "add" or self.monDraft:isDirty()))),
    dirtySections = session and session.dirtySections or { money = false, flags = false },
    sectionDirty = self:_sectionDirty(session),
    section = self.controller.section,
    sections = self.controller:snapshot().sections,
    navigationRows = {
      { role = "action", id = "section:Player", targetId = "section:Player", label = "Player" },
      { role = "action", id = "section:Progress", targetId = "section:Progress", label = "Progress" },
    },
    modal = self.controller.modal,
    modalTitle = modalTitle,
    modalLayers = modalLayers,
    focus = self.controller.focus,
    focusVisible = self.controller.focusVisible,
    capturedTarget = self.controller.capturedTarget,
    scrollOffset = self.controller.scrollOffset,
    query = self.controller.query,
    flagRows = flagRows,
    flagRowTargets = flagRowTargets,
    flagIndexByTarget = flagIndexByTarget,
    flagModel = flagModel,
    flagRowAt = flagModel and flagModel.rowAt or nil,
    valueEditor = valueEditorSnapshot,
    editorFeedback = self.editorFeedback,
    numberControlVisuals = numberControlVisuals,
    numberPressTicks = numberPressTicks,
    unappliedDraft = self.valueEditor ~= nil,
    iconStatus = self.iconStatus,
    iconFailure = self.iconFailure,
    locationNavigation = self.controller:locationSnapshot(),
  }
  if self.locationService then
    local location = self.locationService:snapshot()
    ---@type SaveEditorIndexedListProjection
    local mapModel = self:_mapProjection()
    location.mapModel = mapModel
    location.mapListId = locationListId(self.controller:locationSnapshot())
    location.breadcrumb = self.controller.locationPage == "group"
        and assert(self.controller.locationGroupId, "map breadcrumb needs its section identity")
      or nil
    location.maps = mapModel.rowTargets
    location.mapRowTargets = mapModel.rowTargets
    location.mapIndexByTarget = mapModel.indexByTarget
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
  local scopeId, _, scopeKind = scopeDescription(self)
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
  view.listCursors = self.controller.listCursors
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

function State:_advanceFlagCatalog(budget)
  if self._flagCatalog ~= nil then
    return 0
  end
  local task = self._flagCatalogTask
  if task == nil then
    local iterator, state, key = pairs(FieldScriptSymbols.flagsByName)
    task = {
      iterator = iterator,
      state = state,
      key = key,
      rows = {},
      stage = "scan",
      rowTargets = {},
      indexByTarget = {},
      indexCursor = 1,
    }
    self._flagCatalogTask = task
  end
  local used = 0
  while used < budget do
    if task.stage == "scan" then
      local name, flagId = task.iterator(task.state, task.key)
      task.key = name
      if name == nil then
        task.stage = "sort"
        task.sort = newIncrementalSort(task.rows, function(a, b)
          return a.name < b.name
        end)
      else
        used = used + 1
        if name:sub(1, 9) ~= "FLAG_UNK_" then
          task.rows[#task.rows + 1] = {
            name = name,
            displayName = flagDisplayName(name),
            id = assert(flagId),
            targetId = "flag:" .. name,
          }
        end
      end
    elseif task.stage == "sort" then
      local sort = assert(task.sort)
      local sortUsed, complete = advanceIncrementalSort(sort, budget - used)
      used = used + sortUsed
      if complete then
        task.rows = sort.source
        task.sort = nil
        task.stage = "index"
      end
    else
      local index = task.indexCursor
      local row = task.rows[index]
      if row == nil then
        self._flagCatalog = task.rows
        self._flagFilter = {
          query = "",
          revision = 1,
          queryRevision = 0,
          rows = task.rows,
          rowTargets = task.rowTargets,
          indexByTarget = task.indexByTarget,
        }
        self._flagCatalogTask = nil
        break
      end
      task.rowTargets[index] = row.targetId
      task.indexByTarget[row.targetId] = index
      task.indexCursor = index + 1
      used = used + 1
    end
  end
  return used
end

function State:_flagCatalogRows()
  return assert(self._flagCatalog)
end

---@param cache SaveEditorIndexedListCache
---@param revision integer
---@param queryRevision integer
---@param pending boolean
---@param rowAt fun(index: integer): SaveEditorListFilterRow?
---@return SaveEditorIndexedListProjection
local function makeListProjection(cache, revision, queryRevision, pending, rowAt)
  return {
    revision = revision,
    queryRevision = queryRevision,
    pending = pending,
    count = #cache.rows,
    rowTargets = cache.rowTargets,
    indexByTarget = cache.indexByTarget,
    idAt = function(index)
      return cache.rowTargets[index]
    end,
    indexOf = function(targetId)
      return cache.indexByTarget[targetId]
    end,
    rowAt = rowAt or function(index)
      return cache.rows[index]
    end,
  }
end

local function matchesListQuery(listId, descriptor, query)
  if query == "" then
    return true
  end
  if listId == "flags" then
    return descriptor.name:lower():find(query, 1, true) ~= nil
      or descriptor.displayName:lower():find(query, 1, true) ~= nil
  end
  if descriptor.kind == "group" then
    return descriptor.displayName:lower():find(query, 1, true) ~= nil
  end
  return descriptor.symbol:lower():find(query, 1, true) ~= nil
    or descriptor.displayName:lower():find(query, 1, true) ~= nil
    or descriptor.section:lower():find(query, 1, true) ~= nil
    or tostring(descriptor.mapId):find(query, 1, true) ~= nil
end

function State:_beginListFilter(listId, query, source, previous)
  if self._pendingListCursor ~= nil and self._pendingListCursor.listId ~= listId then
    self._pendingListCursor = nil
  end
  self._listQueryRevision = (self._listQueryRevision or 0) + 1
  self._listFilterTask = {
    listId = listId,
    query = query,
    foldedQuery = query:lower(),
    queryRevision = self._listQueryRevision,
    revision = previous and previous.revision or 0,
    cursor = 1,
    source = source,
    rows = {},
    rowTargets = {},
    indexByTarget = {},
  }
end

function State:_advanceListFilter(budget)
  local task = assert(self._listFilterTask)
  local visited = 0
  while task.cursor <= #task.source and visited < budget do
    local descriptor = task.source[task.cursor]
    local matches
    if task.groupMapCursor ~= nil then
      local map = descriptor.maps[task.groupMapCursor]
      visited = visited + 1
      if map.displayName:lower():find(task.foldedQuery, 1, true) ~= nil then
        matches = true
      else
        task.groupMapCursor = task.groupMapCursor + 1
        if task.groupMapCursor > #descriptor.maps then
          task.groupMapCursor = nil
          task.cursor = task.cursor + 1
        end
      end
    else
      visited = visited + 1
      matches = matchesListQuery(task.listId, descriptor, task.foldedQuery)
      if not matches and descriptor.kind == "group" and task.foldedQuery ~= "" and #descriptor.maps > 0 then
        task.groupMapCursor = 1
      elseif not matches then
        task.cursor = task.cursor + 1
      end
    end
    if matches then
      task.rows[#task.rows + 1] = descriptor
      task.rowTargets[#task.rowTargets + 1] = descriptor.targetId
      task.indexByTarget[descriptor.targetId] = #task.rows
      task.groupMapCursor = nil
      task.cursor = task.cursor + 1
    end
  end
  if task.cursor > #task.source then
    local cache = {
      query = task.query:lower(),
      revision = task.revision + 1,
      queryRevision = task.queryRevision,
      rows = task.rows,
      rowTargets = task.rowTargets,
      indexByTarget = task.indexByTarget,
      source = task.source,
    }
    if task.listId == "flags" then
      self._flagFilter = cache
    elseif task.listId:match("^location:") then
      self._locationListCaches[task.listId] = cache
    else
      self._mapFilter = cache
    end
    self._listFilterTask = nil
    self:_reconcilePublishedListFilter()
  end
  return visited
end

function State:_activeFilterListId()
  if self.controller.modal ~= nil or self.valueEditor ~= nil then
    return nil
  elseif self.controller.section == "Progress" then
    return "flags"
  elseif
    self.controller.section == "Location"
    and (self.controller.locationPage == "root" or self.controller.locationPage == "group")
  then
    return locationListId(self.controller:locationSnapshot())
  end
  return nil
end

---@return { name: string, displayName: string, id: integer, targetId: string, value: boolean? }[] rows
---@return string[] rowTargets
---@return table<string, integer> indexByTarget
function State:_filteredFlagRows()
  local query = self.controller.query:lower()
  local cached = self._flagFilter
  if cached == nil then
    local rows = self._flagCatalog or {}
    local rowTargets, indexByTarget = {}, {}
    for index, descriptor in ipairs(rows) do
      rowTargets[index] = descriptor.targetId
      indexByTarget[descriptor.targetId] = index
    end
    cached = {
      query = "",
      revision = self._flagCatalog ~= nil and 1 or 0,
      queryRevision = 0,
      rows = rows,
      rowTargets = rowTargets,
      indexByTarget = indexByTarget,
    }
    self._flagFilter = cached
  end
  if self._listFilterTask ~= nil and self._listFilterTask.listId == "flags" and cached.query == query then
    self._listFilterTask = nil
    self._pendingListCursor = nil
  end
  if
    self._flagCatalog ~= nil
    and cached.query ~= query
    and (self._listFilterTask == nil or self._listFilterTask.listId ~= "flags" or self._listFilterTask.query ~= query)
  then
    self:_beginListFilter("flags", query, self._flagCatalog, cached)
  end
  return cached.rows, cached.rowTargets, cached.indexByTarget
end

---@return SaveEditorIndexedListProjection
function State:_mapProjection()
  local navigation = self.controller:locationSnapshot()
  local listId = locationListId(navigation) or navigation.groupId or "location:root"
  local cache = self._locationListCaches[listId]
  if self._locationMapCatalog == nil or cache == nil then
    self:_locationListCache(listId)
    local pending = { rows = {}, rowTargets = {}, indexByTarget = {} }
    return makeListProjection(pending, 0, 0, true, function()
      return nil
    end)
  end
  local filteringActive = self.controller.section == "Location"
    and (navigation.page == "root" or navigation.page == "group")
  local query = filteringActive and self.controller.query:lower() or cache.query
  if not filteringActive then
    return makeListProjection(cache, cache.revision, cache.queryRevision, false, function(index)
      return cache.rows[index]
    end)
  end
  if
    cache.query ~= query
    and (self._listFilterTask == nil or self._listFilterTask.listId ~= listId or self._listFilterTask.query ~= query)
  then
    self:_beginListFilter(listId, query, cache.source, cache)
  end
  local task = self._listFilterTask
  local pending = task ~= nil and task.listId == listId
  local queryRevision = cache.queryRevision
  if pending then
    queryRevision = assert(task, "active list filtering owns a query revision").queryRevision
  end
  return makeListProjection(cache, cache.revision, queryRevision, pending, function(index)
    return cache.rows[index]
  end)
end

---@param listId string
---@return SaveEditorIndexedListCache?
function State:_locationListCache(listId)
  local cached = self._locationListCaches[listId]
  if cached ~= nil then
    return cached
  end
  self:_startLocationListCache(listId)
  return nil
end

function State:_startLocationListCache(listId)
  if self._locationListCaches[listId] ~= nil then
    return
  end
  local task = self._locationListBuildTask
  if task ~= nil and task.listId == listId then
    return
  end
  local catalog = self._locationMapCatalog
  if catalog == nil then
    return
  end
  local rows
  if listId == "location:root" then
    rows = catalog.groupRows
  else
    assert(listId:match("^location:group:"), "Location list identity is a root or source group")
    local groupId = listId
    rows = assert(catalog.groupById[groupId], "map group belongs to the complete source catalog").maps
  end
  self._locationListBuildTask = {
    listId = listId,
    source = rows,
    cursor = 1,
    rows = {},
    rowTargets = {},
    indexByTarget = {},
  }
end

function State:_advanceLocationPreparation(budget)
  local used = 0
  local summaries = self._locationMapSummaryTask
  if summaries ~= nil and used < budget then
    local consumed, complete = summaries:advance(budget - used)
    used = used + consumed
    if complete then
      self._locationCatalogTask = MapCatalog.newTask(summaries:take())
      self._locationMapSummaryTask = nil
    end
  end
  local catalogTask = self._locationCatalogTask
  if catalogTask ~= nil and used < budget then
    local consumed, complete = catalogTask:advance(budget - used)
    used = used + consumed
    if complete then
      self._locationMapCatalog = catalogTask:take()
      self._locationCatalogTask = nil
      local original = self._locationCatalogLocation
      if original ~= nil then
        local initialGroup = self._locationMapCatalog:groupForMap(original.mapId)
        if initialGroup ~= nil then
          self.controller:rememberLocationDestination(initialGroup, "location:map:" .. tostring(original.mapId))
        end
        self._locationCatalogLocation = nil
      end
      self:_startLocationListCache("location:root")
    end
  end
  local task = self._locationListBuildTask
  if task ~= nil then
    while used < budget and task.cursor <= #task.source do
      local row = task.source[task.cursor]
      local index = #task.rows + 1
      task.rows[index] = row
      task.rowTargets[index] = row.targetId
      task.indexByTarget[row.targetId] = index
      task.cursor = task.cursor + 1
      used = used + 1
    end
    if task.cursor > #task.source then
      self._locationListCaches[task.listId] = {
        query = "",
        revision = 1,
        queryRevision = 0,
        rows = task.rows,
        rowTargets = task.rowTargets,
        indexByTarget = task.indexByTarget,
        source = task.rows,
      }
      self._locationListBuildTask = nil
    end
  end
  return used
end

function State:_flagProjection(values)
  local rows, rowTargets, indexByTarget = self:_filteredFlagRows()
  local cache = assert(self._flagFilter)
  local task = self._listFilterTask
  local pending = self._flagCatalog == nil or (task ~= nil and task.listId == "flags")
  local queryRevision = cache.queryRevision
  if task ~= nil and task.listId == "flags" then
    queryRevision = assert(task).queryRevision
  end
  local projection = makeListProjection(cache, cache.revision, queryRevision, pending, function(index)
    local descriptor = rows[index]
    if descriptor == nil then
      return nil
    end
    return {
      name = descriptor.name,
      displayName = descriptor.displayName,
      id = descriptor.id,
      targetId = descriptor.targetId,
      value = values[descriptor.id] == true,
    }
  end)
  projection.rowTargets, projection.indexByTarget = rowTargets, indexByTarget
  return projection
end

function State:_reconcilePublishedListFilter()
  local previous = self._pendingListCursor
  self._pendingListCursor = nil
  if previous == nil then
    return
  end
  local layout = self:_resolve(self:_snapshot()).content.layout
  local list = layout.lists[previous.listId]
  if list == nil then
    return
  end
  if #list.rowTargets == 0 then
    self.controller:setListCursor(previous.listId, nil)
    self.controller:setFocus(list.targetId)
    return
  end
  local index = previous.targetId and list.indexByTarget and list.indexByTarget[previous.targetId] or nil
  index = index or math.max(1, math.min(previous.index or 1, #list.rowTargets))
  local targetId = list.rowTargets[index]
  self.controller:setListCursor(previous.listId, targetId)
  if self.controller.focus == previous.targetId or self.controller.focus == list.targetId then
    self.controller:setFocus(targetId)
    local viewport = assert(layout.viewports[list.viewportId])
    local revealed = ScrollViewport.clamp(
      ScrollViewport.reveal(viewport.offset, viewport.clip.height, (index - 1) * viewport.rowExtent, viewport.rowExtent),
      viewport.contentExtent,
      viewport.clip.height
    )
    self:_storeListOffset(list, revealed)
  end
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
    bagQuantityVisuals = assert(dependencies.bagManifest, "Party pager reuses Bag arrow visuals").interactive.overlays.quantity.visuals,
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

function State:_advanceBagCatalog(budget)
  local itemCatalog = assert(self.dependencies.context.itemCatalog)
  local cached = self._bagCatalogMetadata
  if cached ~= nil and cached.catalog == itemCatalog then
    return 0
  end
  local task = self._bagCatalogTask
  if task == nil or task.catalog ~= itemCatalog then
    local pocketKeys, pocketByKey = {}, {}
    for key in pairs(ItemAssetSchema.POCKETS) do
      pocketKeys[#pocketKeys + 1] = key
      pocketByKey[key] = itemCatalog:pocket(key)
    end
    table.sort(pocketKeys, function(a, b)
      return pocketByKey[a].nativeId < pocketByKey[b].nativeId
    end)
    local pockets, optionsByPocket = {}, {}
    for _, key in ipairs(pocketKeys) do
      pockets[#pockets + 1] = { key = key }
      optionsByPocket[key] = {}
    end
    task = {
      catalog = itemCatalog,
      nextItemKey = itemCatalog:itemKeyIterator(),
      pockets = pockets,
      pocketByKey = pocketByKey,
      optionsByPocket = optionsByPocket,
      itemByKey = {},
      sortPocketIndex = 1,
      stage = "scan",
    }
    self._bagCatalogTask = task
  end
  local used = 0
  while used < budget do
    if task.stage == "scan" then
      local key = task.nextItemKey()
      if key == nil then
        task.stage = "sort"
      else
        used = used + 1
        local item = itemCatalog:item(key)
        task.itemByKey[key] = { item = key, label = item.name or key, iconKey = item.icon }
        if key ~= "NONE" then
          local options = task.optionsByPocket[item.pocket]
          if options ~= nil then
            options[#options + 1] = { key = key, label = item.name or key }
          end
        end
      end
    elseif task.sortPocketIndex <= #task.pockets then
      local pocket = task.pockets[task.sortPocketIndex].key
      local sort = task.sort
      if sort == nil then
        sort = newIncrementalSort(task.optionsByPocket[pocket], function(a, b)
          return itemCatalog:orderingKey(a.key) < itemCatalog:orderingKey(b.key)
        end)
        task.sort = sort
      end
      local sortUsed, complete = advanceIncrementalSort(sort, budget - used)
      used = used + sortUsed
      if complete then
        task.optionsByPocket[pocket] = sort.source
        task.sort = nil
        task.sortPocketIndex = task.sortPocketIndex + 1
      end
    else
      cached = {
        catalog = itemCatalog,
        pockets = task.pockets,
        pocketByKey = task.pocketByKey,
        optionsByPocket = task.optionsByPocket,
        itemByKey = task.itemByKey,
      }
      self._bagCatalogMetadata = cached
      self._bagCatalogTask = nil
      break
    end
  end
  return used
end

function State:_bagView()
  local itemCatalog = assert(self.dependencies.context.itemCatalog)
  local catalog = self._bagCatalogMetadata
  if catalog == nil or catalog.catalog ~= itemCatalog then
    local manifest = assert(self.dependencies.bagManifest, "Bag presentation manifest is required")
    return {
      bagPocket = self.controller.bagPocket,
      bagPockets = {},
      bagRows = {},
      bagPageRows = {},
      bagPage0 = 0,
      bagPageCount = 1,
      bagAddEnabled = false,
      bagPocketTabRects = {},
      bagPocketStrip = manifest.interactive.pocketTabs.strips[self.controller.bagPocket],
      bagFocusVisuals = manifest.interactive.focus,
      bagTabFocusVisual = manifest.interactive.focus.tabs.visual,
      bagTabFocusTargets = manifest.interactive.focus.tabs.targets,
      bagQuantityVisuals = manifest.interactive.overlays.quantity.visuals,
      bagSelectedItem = self.controller.bagItemKey,
      bagSelectedQuantity = nil,
      bagSelectedLabel = nil,
    }
  end
  local revision = self.session:revision()
  local pocket = self.controller.bagPocket
  local projection = self._bagProjection
  if
    projection == nil
    or projection.catalog ~= itemCatalog
    or projection.pocket ~= pocket
    or projection.revision ~= revision
  then
    local rows, quantityByItem = {}, {}
    local previousRows = projection ~= nil and projection.catalog == itemCatalog and projection.rowByItem or {}
    for _, entry in ipairs(self.session:bagSnapshot(pocket)) do
      local row = previousRows[entry.item]
        or assert(catalog.itemByKey[entry.item], "bag entries resolve in the item catalog")
      rows[#rows + 1] = row
      quantityByItem[entry.item] = entry.quantity
    end
    local rowByItem = {}
    for _, row in ipairs(rows) do
      rowByItem[row.item] = row
    end
    projection = {
      catalog = itemCatalog,
      pocket = pocket,
      revision = revision,
      rows = rows,
      rowByItem = rowByItem,
      quantityByItem = quantityByItem,
      pageRows = {},
      pageCount = math.max(1, math.ceil(#rows / 6)),
    }
    self._bagProjection = projection
  end
  local pageCount = projection.pageCount
  self.controller.bagPage0 = math.max(0, math.min(pageCount - 1, self.controller.bagPage0))
  local pageRows = projection.pageRows[self.controller.bagPage0]
  if pageRows == nil then
    pageRows = {}
    local firstIndex = self.controller.bagPage0 * 6 + 1
    for index = firstIndex, math.min(#projection.rows, firstIndex + 5) do
      local metadata = projection.rows[index]
      pageRows[#pageRows + 1] = {
        item = metadata.item,
        label = metadata.label,
        iconKey = metadata.iconKey,
        quantity = projection.quantityByItem[metadata.item],
      }
    end
    projection.pageRows[self.controller.bagPage0] = pageRows
  end
  local manifest = assert(self.dependencies.bagManifest, "Bag presentation manifest is required")
  local options = assert(catalog.optionsByPocket[pocket])
  local selectedMetadata = self.controller.bagItemKey and catalog.itemByKey[self.controller.bagItemKey] or nil
  return {
    bagPocket = self.controller.bagPocket,
    bagPockets = catalog.pockets,
    bagRows = projection.rows,
    bagPageRows = pageRows,
    bagPage0 = self.controller.bagPage0,
    bagPageCount = pageCount,
    bagAddEnabled = #options > 0,
    bagPocketTabRects = manifest.interactive.pocketTabs.rects,
    bagPocketStrip = manifest.interactive.pocketTabs.strips[self.controller.bagPocket],
    bagFocusVisuals = manifest.interactive.focus,
    bagTabFocusVisual = manifest.interactive.focus.tabs.visual,
    bagTabFocusTargets = manifest.interactive.focus.tabs.targets,
    bagQuantityVisuals = manifest.interactive.overlays.quantity.visuals,
    bagSelectedItem = self.controller.bagItemKey,
    bagSelectedQuantity = self.controller.bagItemKey and projection.quantityByItem[self.controller.bagItemKey] or nil,
    bagSelectedLabel = selectedMetadata and selectedMetadata.label or nil,
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
    local removedLayer = self:_popValueLayer(editor)
    self.valueEditor, self.valuePurpose, self.activeDraftField = nil, nil, nil
    self.valueReturnFocus = nil
    local parentMove = self:_restoreMoveParent(removedLayer)
    if not parentMove and purpose == "bag_quantity" then
      local pending = assert(self.pendingQuantity)
      self.pendingQuantity = nil
      if pending.returnModal then
        self.controller:setFocus("bag:item:" .. pending.itemKey)
        assert(self.modalStack:top() and self.modalStack:top().kind == "bag-item")
        self.controller.modal = pending.returnModal
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
    local removedLayer = self:_popValueLayer(editor)
    self.valueEditor, self.valuePurpose, self.activeDraftField = nil, nil, nil
    self.valueReturnFocus = nil
    self:_restoreMoveParent(removedLayer)
    return true
  elseif purpose == "bag_add_item" then
    self.numberHold = nil
    self.numberPressTarget = nil
    self:_popValueLayer(editor)
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
    if pending.returnModal then
      self.controller.modal = pending.returnModal
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
  self:_popValueLayer(editor)
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
  self.controller:setFocus("party:slot:" .. self.controller.partySlot0)
  self.controller:cancelInteraction()
  self.errorMessage = nil
  return true
end

function State:_beginBagAdd()
  local catalog = assert(self._bagCatalogMetadata, "Bag Add requires a prepared item catalog")
  local options = assert(catalog.optionsByPocket[self.controller.bagPocket])
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

function State:_adjustNumberPlace(place, sign)
  if self.valueEditor ~= nil then
    self.valueEditor:selectPlace(place)
    self.valueEditor:adjustPlace(sign)
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
          self.controller:setFocus("bag:item:" .. itemKey)
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

-- Probes the owning session revision without failing on partial states.
-- States that can snapshot always answer; anything else keeps a nil mark.
---@param owner SaveEditorSession?
---@return integer?
local function publishedSessionRevision(owner)
  if owner == nil then
    return nil
  end
  local ok, revision = pcall(function()
    return owner:revision()
  end)
  if ok then
    return revision
  end
  return nil
end

-- Reads the current host measurement signature without resolving a
-- plan. States without a display context keep a nil mark.
---@param state SaveEditorState
---@return string?
local function publicationSignature(state)
  local display = state.displayContext
  if display == nil then
    return nil
  end
  local ok, measurement = pcall(function()
    return display:measure(state.width, state.height)
  end)
  if ok and type(measurement) == "table" then
    return measurement.signature
  end
  return nil
end

-- Marks the settled pair stale. Called at input, mutation, resize,
-- focus and async publication boundaries; the owning funnel exit
-- refreshes the pair before any draw observes the state.
function State:_invalidatePublication()
  self._publishedDirty = true
end

-- Publishes one matched (view, plan) pair atomically. A failed
-- candidate keeps the previously published pair and propagates the
-- existing failure; half-updated state is never exposed.
function State:_publishPublication()
  local view = self:_snapshot()
  local plan = self:_resolve(view)
  view.presentation = plan
  view.layout = plan.content.layout
  self._publishedView = view
  self._publishedPlan = plan
  self._publishedDirty = false
  self._publishedWidth, self._publishedHeight = self.width, self.height
  self._publishedScopeEpoch = self.scopeEpoch
  self._publishedSession = self.session
  self._publishedSessionRevision = publishedSessionRevision(self.session)
  self._publishedScopeId, self._publishedScopeRevision = scopeDescription(self)
  self._publishedSignature = publicationSignature(self)
  return view
end

-- Returns the settled pair, republishing when a boundary marked it
-- stale, when the measurement, scope epoch or owning session revision
-- moved on, or when no pair was published yet. A plan is never paired
-- with an older view.
function State:_ensurePublished()
  if self._publishedView == nil then
    self:_publishPublication()
    return assert(self._publishedView, "the editor publishes its settled pair before observing it")
  end
  local scopeId, scopeRevision = scopeDescription(self)
  if
    self._publishedDirty
    or self._publishedWidth ~= self.width
    or self._publishedHeight ~= self.height
    or self._publishedScopeEpoch ~= self.scopeEpoch
    or self._publishedSession ~= self.session
    or self._publishedSessionRevision ~= publishedSessionRevision(self.session)
    or self._publishedScopeId ~= scopeId
    or self._publishedScopeRevision ~= scopeRevision
    or self._publishedSignature ~= publicationSignature(self)
  then
    self:_publishPublication()
  end
  return assert(self._publishedView, "the editor publishes its settled pair before observing it")
end

-- Refreshes an already-published pair after a funnel exit. States that
-- never published (hand-built harnesses, disposed editors) keep their
-- legacy observation instead of resolving a pair nobody owns yet.
function State:_refreshPublication()
  if self._publishedDirty and self._publishedView ~= nil and not self.disposed then
    self:_ensurePublished()
  end
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
    if type(indexByTarget) ~= "table" and focus ~= nil then
      for index, targetId in ipairs(list.rowTargets) do
        if focus == targetId then
          return list, index
        end
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
    if list.indexByTarget ~= nil and list.indexByTarget[targetId] ~= nil then
      return list
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
  local indexByTarget = list.indexByTarget
  if cursor ~= nil and type(indexByTarget) == "table" and indexByTarget[cursor] ~= nil then
    return cursor
  end
  cursor = list.rowTargets[1]
  self.controller:setListCursor(list.id, cursor)
  return cursor
end

---@param list table<string, unknown>
---@param offset number
function State:_storeListOffset(list, offset)
  if list.id:match("^location:") then
    self.controller.locationMapOffset = offset
    self.controller.scrollOffset = offset
    local memory = list.id == "location:root" and self.controller.locationMemory.root
      or self.controller.locationMemory.groups[list.id]
    if memory ~= nil then
      memory.scroll = offset
    end
  elseif list.id == "flags" or list.id == "value:choice" then
    if list.id == "value:choice" then
      self.preserveChoiceScroll = true
    end
    self.controller.scrollOffsets[list.id] = offset
  else
    error("unknown generic list " .. tostring(list.id), 2)
  end
end

---@param layout table<string, unknown>
---@param targetId string
---@param navigationReveal { viewportId:string, index:integer }?
---@return table<string, unknown> layout the current layout, refreshed once after an offset change
function State:_revealFocusedTarget(layout, targetId, navigationReveal)
  local revealByTarget = layout.revealByTarget
  local anchor = type(revealByTarget) == "table" and revealByTarget[targetId] or nil
  local viewportId = anchor and anchor.viewportId or nil
  local itemStart = anchor and anchor.start or nil
  local itemExtent = anchor and anchor.extent or nil
  local list
  if anchor == nil and navigationReveal ~= nil then
    viewportId = navigationReveal.viewportId
    local viewport = layout.viewports and layout.viewports[viewportId]
    if viewport ~= nil then
      itemStart = (navigationReveal.index - 1) * (viewport.rowExtent + (viewport.gap or 0))
      itemExtent = viewport.rowExtent
    end
  elseif viewportId == nil then
    for _, candidate in pairs(layout.lists or {}) do
      local index = candidate.indexByTarget and candidate.indexByTarget[targetId]
      if index ~= nil then
        list = candidate
        viewportId = candidate.viewportId
        local viewport = layout.viewports and layout.viewports[viewportId]
        if viewport ~= nil then
          itemStart = (index - 1) * (viewport.rowExtent + (viewport.gap or 0))
          itemExtent = viewport.rowExtent
        end
        break
      end
    end
  end
  if viewportId == nil or itemStart == nil or itemExtent == nil then
    return layout
  end
  local viewport = layout.viewports and layout.viewports[viewportId]
  if viewport == nil then
    return layout
  end
  if list == nil then
    list = findListByViewportId(layout.lists or {}, viewportId)
  end
  local revealed = ScrollViewport.reveal(viewport.offset, viewport.clip.height, itemStart, itemExtent)
  local offset = ScrollViewport.clamp(revealed, viewport.contentExtent, viewport.clip.height)
  if offset == viewport.offset then
    return layout
  end
  if list ~= nil then
    self:_storeListOffset(list, offset)
  else
    self:_setScrollOffset(self:_snapshot(), layout, viewportId, offset)
  end
  return self:_resolve(self:_snapshot()).content.layout
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
  local cursorIndex = cursor ~= nil and list.indexByTarget and list.indexByTarget[cursor] or nil
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
  editor:selectChoice(key)
end

function State:_filterFocusedList(list, rowIndex, operation, text)
  assert(list.filterable, "filtering needs a filterable list")
  local previousFocus = self.controller.focus
  local hadRowFocus = rowIndex ~= nil
  if list.id == "value:choice" then
    local editor = assert(self.valueEditor, "choice filtering needs its value editor")
    local priorQuery = editor:snapshot().query
    local priorTarget = rowIndex ~= nil and previousFocus or self.controller:listCursor(list.id)
    local priorIndex = rowIndex or (priorTarget ~= nil and list.indexByTarget[priorTarget] or nil)
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
    if editor:snapshot().query ~= priorQuery then
      self._pendingChoiceCursor = { targetId = priorTarget, index = priorIndex }
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
    elseif list.id:match("^location:") then
      self.controller.locationMapOffset = 0
      self.controller.scrollOffset = 0
    else
      error("unknown filterable list " .. list.id, 2)
    end
  end
  self:_syncScope()
  local layout = self:_resolve(self:_snapshot()).content.layout
  local fresh = assert(layout.lists and layout.lists[list.id], "filtering keeps its focused list")
  if fresh.pending then
    self._pendingListCursor = {
      listId = fresh.id,
      targetId = previousFocus,
      index = rowIndex,
    }
    return
  end
  if #fresh.rowTargets == 0 then
    self.controller:setListCursor(fresh.id, nil)
    self.controller:setFocus(fresh.targetId)
    return
  end
  local focusLive = fresh.indexByTarget ~= nil and fresh.indexByTarget[previousFocus] ~= nil
  if hadRowFocus then
    if focusLive then
      self.controller:setListCursor(fresh.id, previousFocus)
      layout = self:_revealFocusedTarget(layout, previousFocus)
      self:_reconcileFocus(previousFocus, layout)
    else
      local nearestIndex = math.min(assert(rowIndex, "focused rows have a logical index"), #fresh.rowTargets)
      local nearestTarget = fresh.rowTargets[nearestIndex]
      self.controller:setListCursor(fresh.id, nearestTarget)
      layout = self:_revealFocusedTarget(layout, nearestTarget)
      self:_reconcileFocus(nearestTarget, layout)
    end
  else
    self:_reconcileListCursor(fresh)
  end
end

function State:_reconcilePublishedChoiceFilter()
  local previous = self._pendingChoiceCursor
  self._pendingChoiceCursor = nil
  if previous == nil then
    return
  end
  local layout = self:_resolve(self:_snapshot()).content.layout
  local list = layout.lists and layout.lists["value:choice"]
  if list == nil then
    return
  end
  if #list.rowTargets == 0 then
    self.controller:setListCursor(list.id, nil)
    self.controller:setFocus(list.targetId)
    self:_reconcileFocus(list.targetId, layout)
    return
  end
  local index = previous.targetId ~= nil and list.indexByTarget[previous.targetId] or nil
  if index == nil then
    index = math.min(previous.index or 1, #list.rowTargets)
  end
  local targetId = assert(list.rowTargets[index])
  self.controller:setListCursor(list.id, targetId)
  if previous.targetId ~= nil and previous.targetId ~= list.targetId then
    self.controller:setFocus(targetId)
    layout = self:_revealFocusedTarget(layout, targetId)
    self:_reconcileFocus(targetId, layout)
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
  self.controller:setListCursor(list.id, cursor)
  local resolved = layout or self:_resolve(self:_snapshot()).content.layout
  resolved = self:_revealFocusedTarget(resolved, cursor)
  self:_reconcileFocus(cursor, resolved)
end

---@param preferred string?
---@param layout table<string, unknown>?
---@return table<string, unknown> layout the reconciled layout
function State:_reconcileFocus(preferred, layout)
  local current = layout or self:_resolve(self:_snapshot()).content.layout
  local before = self.controller.focus
  ---@type string?
  local focus = preferred or self.pendingFocusReturn or self.controller.focus
  local logical = focus ~= nil and logicalFocus(current, focus) or nil
  local rememberedFocus = self.controller.focusByScope[current.scopeId]
  local fallbackTargets = {}
  local defaultFocus = current.defaultFocus
  local defaultLogical = defaultFocus ~= nil and logicalFocus(current, defaultFocus) or nil
  if logical == nil and defaultLogical == nil then
    -- A page default can be a geometry sentinel without a published eligible
    -- control. Return to the active section before using the first eligible
    -- control in layout order.
    fallbackTargets[#fallbackTargets + 1] = "section:" .. self.controller.section
    for _, control in ipairs(current.focusNavigation.controls) do
      if control.eligible then
        fallbackTargets[#fallbackTargets + 1] = control.id
        break
      end
    end
  else
    if rememberedFocus ~= nil then
      fallbackTargets[#fallbackTargets + 1] = rememberedFocus
    end
    if defaultFocus ~= nil then
      fallbackTargets[#fallbackTargets + 1] = defaultFocus
    end
    if logical == nil and rememberedFocus == nil then
      logical = defaultLogical
    end
  end
  local reconciled = SaveEditorNavigation.reconcile(
    navigationSnapshot(current, self.controller),
    logical or { scopeId = current.scopeId, regionId = "", targetId = focus or "" },
    fallbackTargets
  )
  self.controller:setFocus(reconciled.targetId)
  self.controller:rememberRegionFocus(reconciled.regionId, reconciled.targetId)
  for _, region in ipairs(current.focusNavigation.regions) do
    if region.id == reconciled.regionId and region.kind == "list" then
      self.controller:setListCursor(region.id, reconciled.targetId)
      break
    end
  end
  self.pendingFocusReturn = nil
  local freshLayout = current
  if self.controller.focus ~= before then
    freshLayout = self:_resolve(self:_snapshot()).content.layout
  end
  if freshLayout.lists ~= nil then
    for _, list in pairs(freshLayout.lists) do
      self:_reconcileListCursor(list)
    end
  end
  freshLayout = self:_revealFocusedTarget(freshLayout, self.controller.focus)
  return freshLayout
end

---@param editor SaveEditorValueEditor
---@param purpose string
---@param returnFocus string?
function State:_installValueEditor(editor, purpose, returnFocus)
  assert(self.valueEditor == nil, "a value editor must be retired before its successor is installed")
  self.valueReturnFocus = returnFocus or self.controller.focus
  self.valueEditor = editor
  self.valuePurpose = purpose
  local editorKind = editor:snapshot().kind
  self:_pushModalLayer(editorKind == "number" and "number" or editorKind, { purpose = purpose })
  self.preserveChoiceScroll = false
end

function State:_pushModalLayer(kind, payload)
  self.modalLayerSequence = self.modalLayerSequence + 1
  local scopeId = self.controller.scopeId
  local regionId = scopeId
  for candidateRegion, targetId in pairs(self.controller.focusByRegion[scopeId] or {}) do
    if targetId == self.controller.focus then
      regionId = candidateRegion
      break
    end
  end
  self.modalStack:push({
    id = kind .. ":" .. tostring(self.modalLayerSequence),
    kind = kind,
    payload = payload,
    opener = {
      controlId = self.controller.focus,
      regionId = regionId,
      scrollAnchor = self.controller.scrollOffsets[scopeId] or self.controller.scrollOffset,
    },
  })
end

function State:_popModalLayer(kind)
  local layer = assert(self.modalStack:top(), "modal layer stack is empty")
  assert(layer.kind == kind, "modal layers must be removed in LIFO order")
  return assert(self.modalStack:pop())
end

function State:_popValueLayer(editor)
  local kind = editor:snapshot().kind
  local layer = self:_popModalLayer(kind == "number" and "number" or kind)
  editor:dispose()
  return layer
end

function State:_restoreMoveParent(childLayer)
  local parent = self.modalStack:top()
  if parent == nil or parent.kind ~= "move" then
    return false
  end
  local targetId = assert(childLayer.opener.controlId, "move child remembers its opening action")
  assert(
    targetId == "party-move:move" or targetId == "party-move:pp" or targetId == "party-move:pp-ups",
    "move child opener is one of the component actions"
  )
  self:_showMoveOverlay(assert(parent.payload.slot0), targetId)
  return true
end

function State:_openDecision(kind, payload)
  local layerKind = kind == "party-move" and "move" or kind == "remove" and "bag-remove" or kind
  self:_pushModalLayer(layerKind, payload or { decision = kind })
  self.controller:openModal(kind)
end

function State:_closeDecision()
  local kind = assert(self.controller.modal, "a decision layer is active")
  local layerKind = kind == "party-move" and "move" or kind == "remove" and "bag-remove" or kind
  self:_popModalLayer(layerKind)
  local focus = self.controller:closeModal()
  local parent = self.modalStack:top()
  self.controller.modal = parent and parent.kind == "bag-item" and "bag-item"
    or parent and parent.kind == "move" and "party-move"
    or nil
  return focus
end

function State:_updateLocationService()
  local service = self.locationService
  if service == nil or self.controller.section ~= "Location" then
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
    local remembered = self.locationPreviewMemory[mapId]
    service:openMap(mapId, {
      purpose = "browse",
      rememberedCursor = remembered and remembered.cursor or nil,
    })
    self.locationServiceMapId = mapId
    self.locationViewport = nil
    if self.locationAutoCenterToken and self.locationAutoCenterToken.mapId == mapId then
      self.locationAutoCenterToken.generation = assert(service:snapshot().initialCursor).generation
    end
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
    local token = self.locationAutoCenterToken
    if token ~= nil and token.mapId == mapId then
      token.generation = assert(service:snapshot().initialCursor).generation
    end
  end
  service:update()
  local token = self.locationAutoCenterToken
  if token ~= nil and token.mapId == mapId then
    local view = service:snapshot()
    local result = view.initialCursor
    if
      view.status.state == "ready"
      and result ~= nil
      and result.state == "ready"
      and result.mapId == token.mapId
      and result.generation == token.generation
    then
      self.controller:setLocationCursor(result.fieldX, result.fieldZ)
      self.locationAutoCenterToken = nil
    end
  end
end

function State:_syncLocationToSession()
  local current = assert(self.session:snapshot().location)
  self.controller:enterLocation(current)
  self.locationAutoCenterToken = nil
  self.locationActionStatus = nil
  self.locationServiceMapId = nil
  self.locationViewport = nil
end

function State:importPresetFile(file)
  local filename = file:getFilename()
  local basename = filename:match("([^/\\]+)$") or filename
  local reason
  if self.disposed or self.status ~= "ready" or self.session == nil or self.dependencies == nil then
    reason = "The Save Editor is not ready to import a preset."
  elseif self.pendingPreset ~= nil then
    reason = "Another preset is already being checked. Wait for it to finish."
  elseif self.closeRequest ~= nil or self:_locationSavePending() then
    reason = "Finish or cancel the current Save operation before importing a preset."
  elseif self.valueEditor ~= nil or self.controller.modal ~= nil or self.modalStack:top() ~= nil then
    reason = "Finish or cancel the open editor dialog before importing a preset."
  elseif self.monDraft ~= nil and (self.monDraft:mode() == "add" or self.monDraft:isDirty()) then
    reason = "Finish or cancel the Party edit before importing a preset."
  end
  if reason ~= nil then
    self:_showPresetResult("rejected", reason, basename)
    return
  end

  local sizeOk, size = pcall(file.getSize, file)
  if
    not sizeOk
    or type(size) ~= "number"
    or size ~= size
    or size == math.huge
    or size == -math.huge
    or size ~= math.floor(size)
    or size < 0
    or size > 131072
  then
    self:_showPresetResult("rejected", "The preset file size is invalid or exceeds 128 KiB.", basename)
    return
  end
  local openedOk, opened = pcall(file.open, file, "r")
  if not openedOk or opened ~= true then
    self:_showPresetResult("rejected", "The preset file could not be opened.", basename)
    return
  end
  local readOk, source = pcall(file.read, file, "string", size)
  local closeOk, closed = pcall(file.close, file)
  if not readOk or type(source) ~= "string" or #source ~= size then
    self:_showPresetResult("rejected", "The preset file could not be read.", basename)
    return
  end
  if not closeOk or closed == false then
    self:_showPresetResult("rejected", "The preset file could not be closed.", basename)
    return
  end
  local preset, parseError = SaveEditorPreset.parse(source)
  if preset == nil then
    self:_showPresetResult("rejected", Errors.format(assert(parseError)), basename)
    return
  end

  local session = assert(self.session)
  local expectedRevision = session:revision()
  local world = assert(self.dependencies.world)
  local mapId, metLocation
  if preset.location == nil then
    local current = assert(session:snapshot().location)
    local currentMap = assert(world.maps[world.byId[current.mapId]], "current map is in the structural world")
    metLocation = assert(currentMap.mapSectionNativeId, "current map has a met location")
  else
    mapId = world.bySymbol[preset.location.map]
    if type(mapId) ~= "number" or mapId ~= math.floor(mapId) or world.byId[mapId] == nil then
      self:_showPresetResult(
        "rejected",
        "The preset map is not available in this game: " .. preset.location.map,
        preset.name
      )
      return
    end
    local map = world.maps[world.byId[mapId]]
    if type(map) ~= "table" or type(map.mapSectionNativeId) ~= "number" then
      self:_showPresetResult(
        "rejected",
        "The preset map has no valid met location: " .. preset.location.map,
        preset.name
      )
      return
    end
    metLocation = map.mapSectionNativeId
  end
  local resolvedMapId = mapId --[[@as integer?]]
  local date = self.dateProvider()
  local originalLocation = session:snapshot().location
  if preset.location == nil then
    local partyRevision = session:partyRevision()
    local result = session:applyPreset(preset, {
      expectedRevision = expectedRevision,
      metLocation = metLocation,
      date = date,
    })
    self:_reportPresetApplication(
      result,
      preset.name,
      session:partyRevision() ~= partyRevision,
      not sameLocation(originalLocation, session:snapshot().location)
    )
    return
  end

  local graph = assert(self.dependencies)
  local service = LocationService.new({
    cacheFs = assert(graph.cacheFs),
    world = world,
    derivedAssets = assert(graph.derivedAssets),
    savedObjects = assert(graph.savedObjects),
  })
  local setupOk, setupError = pcall(function()
    service:openMap(assert(resolvedMapId), { purpose = "verify" })
    service:setViewport(preset.location.x, preset.location.z, 1, 1)
  end)
  if not setupOk then
    service:dispose()
    if Errors.is(setupError) then
      self:_showPresetResult("rejected", Errors.format(setupError), preset.name)
      return
    end
    error(setupError, 0)
  end
  self.pendingPreset = {
    session = session,
    sessionRevision = expectedRevision,
    preset = preset,
    mapId = assert(resolvedMapId),
    fieldX = preset.location.x,
    fieldZ = preset.location.z,
    metLocation = metLocation,
    date = date,
    service = service,
  }
  self.notice = "Checking preset destination…"
end

function State:_showPresetResult(kind, detail, presetName)
  local title = kind == "imported" and "Preset imported"
    or kind == "satisfied" and "Preset already satisfied"
    or "Preset rejected"
  local name = presetName ~= nil and presetName ~= "" and presetName or "the dropped file"
  local messageText
  if kind == "imported" then
    messageText = name .. " was staged. Changes are staged. Use Save to write them to disk."
  elseif kind == "satisfied" then
    messageText = name .. " made no changes; no changes were needed."
  else
    messageText = name .. ": " .. detail
  end
  local dialog = love.window and love.window.showMessageBox
  local called = false
  local result
  if type(dialog) == "function" then
    local ok, value = pcall(dialog, title, messageText, kind == "rejected" and "error" or "info")
    called, result = ok, value
  end
  if not called or result ~= true then
    self.notice = messageText
  else
    self.notice = nil
  end
end

function State:_finishPreset()
  local pending = self.pendingPreset
  self.pendingPreset = nil
  if pending ~= nil then
    pending.service:dispose()
  end
  self.notice = nil
  return pending
end

function State:_reportPresetApplication(result, presetName, partyChanged, locationChanged)
  if result.ok ~= true then
    self:_showPresetResult("rejected", Errors.format(assert(result.error)), presetName)
    return
  end
  if result.changed == true then
    if partyChanged then
      self.monDraft = nil
    end
    self._uiSessionSnapshot = nil
    if locationChanged then
      self:_syncLocationToSession()
    end
    self:_showPresetResult("imported", "", presetName)
  else
    self:_showPresetResult("satisfied", "", presetName)
  end
end

function State:_stepPreset()
  local pending = assert(self.pendingPreset)
  pending.service:update()
  local view = pending.service:snapshot()
  if view.status.state == "failed" then
    local finished = assert(self:_finishPreset())
    self:_showPresetResult(
      "rejected",
      view.status.reason or "The preset destination could not be loaded.",
      finished.preset.name
    )
    return
  end
  if view.status.state ~= "ready" then
    return
  end
  local placement, status = pending.service:resolve(pending.mapId, pending.fieldX, pending.fieldZ, view.generation)
  if placement == nil then
    if status.state == "pending" then
      return
    end
    local finished = assert(self:_finishPreset())
    self:_showPresetResult("rejected", status.reason or "The preset destination is unavailable.", finished.preset.name)
    return
  end
  if placement.mapId ~= pending.mapId or placement.fieldX ~= pending.fieldX or placement.fieldZ ~= pending.fieldZ then
    local finished = assert(self:_finishPreset())
    self:_showPresetResult(
      "rejected",
      "The verified destination did not match the preset coordinates.",
      finished.preset.name
    )
    return
  end
  local session = assert(self.session)
  if
    self.disposed
    or self.status ~= "ready"
    or session ~= pending.session
    or session:revision() ~= pending.sessionRevision
    or self.closeRequest ~= nil
    or self:_locationSavePending()
    or self.valueEditor ~= nil
    or self.controller.modal ~= nil
    or self.modalStack:top() ~= nil
    or (self.monDraft ~= nil and (self.monDraft:mode() == "add" or self.monDraft:isDirty()))
  then
    local finished = assert(self:_finishPreset())
    self:_showPresetResult(
      "rejected",
      "The save changed or an edit became active during verification. Drop the preset again to retry.",
      finished.preset.name
    )
    return
  end
  local finished = assert(self:_finishPreset())
  local partyRevision = session:partyRevision()
  local originalLocation = session:snapshot().location
  local result = session:applyPreset(finished.preset, {
    expectedRevision = finished.sessionRevision,
    placement = placement,
    metLocation = finished.metLocation,
    date = finished.date,
  })
  self:_reportPresetApplication(
    result,
    finished.preset.name,
    session:partyRevision() ~= partyRevision,
    not sameLocation(originalLocation, session:snapshot().location)
  )
end

function State:_locationGridSize()
  return self.locationGridWidthTiles or 1, self.locationGridHeightTiles or 1
end

function State:_takeLocationCursorOwnership()
  self.locationAutoCenterToken = nil
  if self.locationService ~= nil then
    self.locationService:cancelInitialSurvey()
  end
end

function State:_selectLocationTile(fieldX, fieldZ)
  self:_takeLocationCursorOwnership()
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
  self.locationAutoCenterToken = nil
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
  self._uiSessionSnapshot = nil
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
    local leavingGrid = self.controller.section == "Location"
      and self.controller.locationPage == "grid"
      and action.section ~= "Location"
    if leavingGrid then
      self:_rememberLocationPreview()
    end
    self.controller:setSection(action.section)
    if leavingGrid and self.locationService then
      self.locationAutoCenterToken = nil
      self.locationService:releaseGrid()
      self.locationServiceMapId = nil
      self.locationViewport = nil
    end
    if action.section == "Progress" then
      self.controller.query = ""
      self.controller:setFocus("list:flags")
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
  elseif action.kind == "location-group-select" then
    local projection = self:_mapProjection()
    local index = assert(projection.indexOf(action.groupId), "selected map section belongs to the current projection")
    local group = assert(projection.rowAt(index), "selected map section has catalog metadata")
    local query = self.controller.query
    local foldedQuery = query:lower()
    local carriedQuery = group.displayName:lower():find(foldedQuery, 1, true) == nil and query ~= "" and query or nil
    self.controller:enterLocationGroup(action.groupId, carriedQuery)
    return
  elseif action.kind == "location-map-select" then
    local world = assert(self.dependencies.world)
    local record = world.maps[assert(world.byId[action.mapId], "selected map must be in structural world data")]
    local remembered = self.locationPreviewMemory[action.mapId]
    local staged = self.session and self.session:snapshot().location or nil
    if remembered ~= nil then
      self.controller:chooseLocationMap(action.mapId, remembered.cursor.fieldX, remembered.cursor.fieldZ)
      self.controller.locationCenterX = remembered.center.fieldX
      self.controller.locationCenterZ = remembered.center.fieldZ
    elseif staged ~= nil and staged.mapId == action.mapId then
      self.controller:chooseLocationMap(action.mapId, staged.fieldX, staged.fieldZ)
    else
      self.controller:chooseLocationMap(action.mapId, record.worldOriginX + 16, record.worldOriginZ + 16)
    end
    self.locationServiceMapId = nil
    self.locationViewport = nil
    self.locationAutoCenterToken = remembered == nil and { mapId = action.mapId } or nil
    self.locationActionStatus = nil
    self.errorMessage = nil
    self:_settleScope()
    return
  elseif action.kind == "location-cursor-move" then
    self:_takeLocationCursorOwnership()
    local width, height = self:_locationGridSize()
    self.controller:moveLocationCursor(action.direction, width, height)
    self:_updateLocationService()
  elseif action.kind == "location-pan" then
    self:_takeLocationCursorOwnership()
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
  self:_closeDecision()
  if self.controller.modal == "bag-item" then
    self:_closeDecision()
  end
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
  self.controller:setFocus(focusRow and "bag:item:" .. focusRow.item or "bag:add")
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
  self._uiSessionSnapshot = nil
  self.errorMessage = nil
  self:_syncLocationToSession()
  if leave then
    local request = self.closeRequest
    self.closeRequest = nil
    self.modalStack:dispose()
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
    self.valueEditor:dispose()
    self.modalStack:dispose()
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
  self.closeRequest = nil
  self.pendingRemove = nil
  self.pendingQuantity = nil
  self.errorMessage = nil
  self.controller.partyTab = "Stats"
  self.controller.partySlot0 = nil
  self.controller.bagItemKey = nil
  if self.controller.section == "Party" then
    self.controller:setFocus("party:add")
  elseif self.controller.section == "Bag" then
    self.controller:setFocus("bag:pocket:" .. self.controller.bagPocket)
  end
  if leave then
    self.modalStack:dispose()
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
    self:_popValueLayer(self.valueEditor)
    self.valueEditor, self.valuePurpose, self.activeDraftField = nil, nil, nil
    self.valueReturnFocus, self.pendingFocusReturn = nil, nil
    self.pendingQuantity = nil
    self.numberHold = nil
    self.numberPressTarget = nil
  end
  if section == "Party" then
    self.monDraft = nil
    self.pendingMoveSlot = nil
    if self.modalStack:top() and self.modalStack:top().kind == "move" then
      self:_popModalLayer("move")
      self.controller.modal = nil
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
    self.controller:setFocus(slot0 ~= nil and ("party:slot:" .. slot0) or "party:add")
    self:_ensurePartyDraft()
    return
  elseif section == "Bag" then
    local layer = self.modalStack:top()
    if layer and (layer.kind == "bag-item" or layer.kind == "bag-remove") then
      self.pendingRemove = nil
      self.pendingQuantity = nil
      while
        self.modalStack:top()
        and (self.modalStack:top().kind == "bag-item" or self.modalStack:top().kind == "bag-remove")
      do
        self:_popModalLayer(self.modalStack:top().kind)
      end
      self.controller.modal = nil
      self.controller.bagItemKey = nil
      self.controller:setFocus("bag:pocket:" .. self.controller.bagPocket)
    end
  end
  self.errorMessage = nil
  local changed = assert(self.session, "section discard needs its ready session"):discardSection(section)
  if changed and section == "Location" then
    self:_syncLocationToSession()
  end
end

function State:_requestBack()
  local focus = self.controller.focus
  if
    self.valueEditor == nil
    and self.controller.modal == nil
    and self.controller.section == "Location"
    and self.controller.locationPage == "root"
    and focus ~= nil
    and (
      focus == "list:location:root"
      or focus:match("^list:location:group:.+$")
      or focus:match("^location:group:.+$")
      or focus:match("^location:map:%d+$")
    )
  then
    local layout = self:_resolve(self:_snapshot()).content.layout
    local activeList, rowIndex = self:_activeList(layout)
    local listId = locationListId(self.controller:locationSnapshot())
    if activeList ~= nil and activeList.id == listId then
      if rowIndex ~= nil then
        self.controller:setListCursor(activeList.id, self.controller.focus)
      end
      self.controller:setFocus("section:Location")
      self:_reconcileFocus("section:Location", layout)
      return
    end
  end

  if self.valueEditor then
    self.valueEditor:cancel()
    self:_finishValueEditor()
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
    self.controller:setFocus("bag:pocket:" .. self.controller.bagPocket)
  elseif self.controller.section == "Location" and self.controller.locationPage ~= "root" then
    local wasGrid = self.controller.locationPage == "grid"
    if wasGrid then
      self:_rememberLocationPreview()
    end
    self.locationAutoCenterToken = nil
    self.controller:backLocation()
    if wasGrid and self.locationService ~= nil then
      self.locationService:releaseGrid()
      self.locationServiceMapId = nil
      self.locationViewport = nil
      self.locationActionStatus = nil
    end
    self.errorMessage = nil
  elseif self.session and self.session:isDirty() then
    self:requestClose("back")
  else
    self:_sendResult()
  end
end

function State:_rememberLocationPreview()
  local navigation = self.controller:locationSnapshot()
  if navigation.page ~= "grid" or navigation.mapId == nil or navigation.cursor == nil or navigation.center == nil then
    return
  end
  self.locationPreviewMemory[navigation.mapId] = {
    cursor = { fieldX = navigation.cursor.fieldX, fieldZ = navigation.cursor.fieldZ },
    center = { fieldX = navigation.center.fieldX, fieldZ = navigation.center.fieldZ },
  }
end

function State:_popDecision(decision)
  local modal = decision or assert(self.controller.modal, "decision pop needs its open decision")
  assert(modal == self.controller.modal, "decision action must belong to the active decision")
  if modal == "leave" and self.closeRequest ~= nil then
    self:_cancelPendingLocationSave()
    self:_popModalLayer("leave")
    local request = assert(self.closeRequest)
    self.closeRequest = nil
    self.controller.modal = request.previousModal
    self.controller.modalReturnFocus = request.previousModalReturnFocus
    self.controller:setFocus(request.previousFocus)
  elseif modal == "party-move" then
    self.pendingMoveSlot = nil
    self:_closeDecision()
  else
    if modal == "remove" then
      self.pendingRemove = nil
    end
    self:_closeDecision()
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
  if self.modalStack:top() == nil or self.modalStack:top().kind ~= "move" then
    local entry = assert(draft:record().moves[slot0 + 1])
    local catalog = assert(self.dependencies.context.monCatalog)
    self:_openDecision("party-move", {
      slot0 = slot0,
      title = "Edit move: " .. (catalog:move(entry.move).name or entry.move),
    })
  else
    self.controller.modal = "party-move"
  end
  self.controller.modalReturnFocus = "party:move:" .. slot0
  self.controller:setFocus(focusTarget or "party-move:move")
end

function State:_openMoveChild(action)
  local slot0 = assert(self.pendingMoveSlot, "a move component editor owns its slot")
  local draft = assert(self.monDraft, "a move component editor needs its member draft")
  local entry = assert(draft:record().moves[slot0 + 1], "a move component editor needs its occupied slot")
  local catalog = assert(self.dependencies.context.monCatalog)
  self.controller:setFocus(action)
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
    self:_openDecision("leave")
    self:_syncScope()
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
      self:_popModalLayer("leave")
      local request = assert(self.closeRequest)
      self.closeRequest = nil
      self.controller.modal = request.previousModal
      self.controller.modalReturnFocus = request.previousModalReturnFocus
      self.controller.focus = request.previousFocus
    elseif kind == "party-move" then
      self.pendingMoveSlot = nil
      self:_closeDecision()
    elseif kind == "remove" then
      self.pendingRemove = nil
      self:_closeDecision()
      if self.controller.section == "Bag" and self.controller.bagItemKey then
        self.controller.focus = "bag:item:" .. self.controller.bagItemKey
      end
    elseif kind == "bag-item" then
      self:_closeDecision()
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
      self:_openDecision("remove")
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

function State:_activateControl(targetId, layout)
  local control
  for _, candidate in ipairs(layout.focusNavigation.controls) do
    if candidate.id == targetId then
      control = candidate
      break
    end
  end
  if control == nil or not control.eligible then
    return
  end
  local action = assert(control.action, "active controls publish an action record")
  self:_dispatchActivationAction(action, layout)
end

function State:_numberEditorTooSmall(layout)
  if self.valueEditor == nil or self.valueEditor:snapshot().kind ~= "number" then
    return false
  end
  local currentLayout = layout or self:_resolve(self:_snapshot()).content.layout
  return currentLayout.numberTooSmall == true
end

local function removeBagItem(self)
  self.pendingRemove = { kind = "bag", itemKey = assert(self.controller.bagItemKey) }
  self:_openDecision("remove")
end

local function editBagQuantity(self)
  self:_openBagQuantity("set")
end

local function saveAndExit(self)
  if self.closeRequest ~= nil then
    self:_performClose("save")
  elseif self:_locationSavePending() then
    self:_cancelPendingLocationSave()
    self.errorMessage = "Destination verification canceled."
  else
    self:_save(true)
  end
end

local function discardAndExit(self)
  if self.closeRequest ~= nil then
    self:_performClose("discard")
  else
    self:_discard(false)
  end
end

local function valueEditorAction(finish)
  return function(self, action)
    finish(assert(self.valueEditor), action)
    self:_finishValueEditor()
  end
end

local function openMoveChild(command)
  return function(self)
    self:_openMoveChild(command)
  end
end

local function deferred(build)
  return function(self, action)
    self:_performDeferred(build(action))
  end
end

local function noop() end

local function installChoiceEditor(self, purpose, options)
  self:_installValueEditor(ValueEditor.new({ kind = "choice", options = options }), purpose)
end

-- Activation handlers by action kind; each runs as `handler(state, action)`.
local ACTIVATION_HANDLERS = {
  ["section.select"] = function(self, action)
    self:_requestDraftResolution({ kind = "section", section = action.section })
  end,
  ["player.edit-money"] = function(self)
    self:_cancelPendingLocationSave()
    local money = assert(self.session:snapshot().money)
    self:_installValueEditor(
      ValueEditor.new({ kind = "integer", value = money, min = 0, max = PlayerData.MAX_MONEY, base = "decimal" }),
      "money"
    )
  end,
  ["player.edit-dialogue-frame"] = function(self)
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
  end,
  ["progress.toggle-flag"] = function(self, action)
    if self._listFilterTask ~= nil then
      return
    end
    local current = self.session:snapshot().flags[FieldScriptSymbols.flagsByName[action.name]] == true
    local result = self.session:setFlag(action.name, not current)
    if not result.ok then
      self.errorMessage = message(result.error)
    end
  end,
  ["value.confirm"] = valueEditorAction(function(editor)
    editor:press("confirm")
  end),
  ["value.cancel"] = valueEditorAction(function(editor)
    editor:cancel()
  end),
  ["value.adjust-number-place"] = function(self, action)
    assert(action.direction == "up" or action.direction == "down")
    self:_adjustNumberPlace(action.place, action.direction == "up" and 1 or -1)
    self:_finishValueEditor()
  end,
  ["value.choose-option"] = valueEditorAction(function(editor, action)
    editor:activateTarget(action.key)
  end),
  ["value.activate-name-control"] = valueEditorAction(function(editor, action)
    editor:activateTarget(action.control)
  end),
  ["value.activate-name-key"] = valueEditorAction(function(editor, action)
    editor:activateTarget(tostring(action.row) .. ":" .. tostring(action.column))
  end),
  ["value.change-page"] = valueEditorAction(function(editor, action)
    assert(action.direction == "next" or action.direction == "previous")
    editor:press(action.direction == "next" and "page_next" or "page_previous")
  end),
  ["value.press"] = valueEditorAction(function(editor, action)
    editor:press(action.key)
  end),
  ["value.focus-choice-list"] = noop,
  ["list.inert"] = noop,
  ["decision.cancel"] = function(self, action)
    self:_popDecision(action.decision)
  end,
  ["decision.edit-bag-quantity"] = editBagQuantity,
  ["decision.remove-bag-item"] = removeBagItem,
  ["decision.edit-move"] = openMoveChild("party-move:move"),
  ["decision.edit-move-pp"] = openMoveChild("party-move:pp"),
  ["decision.edit-move-pp-ups"] = openMoveChild("party-move:pp-ups"),
  ["decision.confirm-remove"] = function(self)
    self:_confirmRemoval()
  end,
  ["decision.save-and-exit"] = saveAndExit,
  ["decision.discard-and-exit"] = discardAndExit,
  ["editor.save"] = function(self)
    if self:_locationSavePending() then
      self:_cancelPendingLocationSave()
      self.errorMessage = "Destination verification canceled."
    else
      self:_requestDraftResolution({ kind = "save" })
    end
  end,
  ["editor.discard"] = function(self)
    self:_discardSection()
  end,
  ["editor.back"] = function(self)
    self:_requestBack()
  end,
  ["editor.retry-open"] = function(self)
    self.generation = self.generation + 1
    self.status, self.errorMessage = "opening", nil
  end,
  ["editor.close-open-error"] = function(self)
    self:_sendResult()
  end,
  ["location.select-group"] = deferred(function(action)
    return { kind = "location-group-select", groupId = action.groupId }
  end),
  ["location.select-map"] = function(self, action)
    if self._listFilterTask ~= nil then
      return
    end
    self:_performDeferred({ kind = "location-map-select", mapId = action.mapId })
  end,
  ["location.select-tile"] = deferred(function(action)
    return { kind = "select_tile", fieldX = action.fieldX, fieldZ = action.fieldZ }
  end),
  ["location.select-current-tile"] = function(self)
    local cursor = self.controller:locationSnapshot().cursor
    if cursor ~= nil then
      self:_performDeferred({ kind = "select_tile", fieldX = cursor.fieldX, fieldZ = cursor.fieldZ })
    end
  end,
  ["party.select-slot"] = function(self, action)
    self:_requestDraftResolution({ kind = "party-slot", slot0 = action.slot0 })
  end,
  ["party.change-page"] = function(self, action)
    self.controller:stepPartyTab(action.direction)
  end,
  ["party.add-member"] = function(self)
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
    installChoiceEditor(self, "party_add_species", options)
  end,
  ["party.edit-field"] = function(self, action)
    if not self:_ensurePartyDraft() then
      return
    end
    local descriptor = self:_partyField("party:field:" .. action.fieldId)
    if descriptor ~= nil then
      self:_openEditor(descriptor)
      self.valuePurpose = "party_field"
    end
  end,
  ["party.use-species-name"] = function(self)
    if not self:_ensurePartyDraft() then
      return
    end
    if not self:_setDraftValue({ setter = "scalar", fieldId = "nickname" }, nil) then
      self.errorMessage = "Nickname could not be cleared."
    else
      self.errorMessage = nil
    end
  end,
  ["party.add-move"] = function(self)
    self:_cancelPendingLocationSave()
    local catalog = assert(self.dependencies.context.monCatalog)
    local options = PartyView.options(assert(self.partyView), "moves", function()
      return catalog:moveKeys()
    end, function(key)
      return catalog:move(key).name or key
    end)
    installChoiceEditor(self, "party_add_move", options)
  end,
  ["party.edit-move"] = function(self, action)
    if not self:_ensurePartyDraft() then
      return
    end
    self:_showMoveOverlay(action.moveIndex)
  end,
  ["bag.select-pocket"] = function(self, action)
    self.controller:selectBagPocket(action.pocket)
  end,
  ["bag.change-page"] = function(self, action)
    self.controller:setBagPage(math.max(0, self.controller.bagPage0 + (action.direction == "next" and 1 or -1)))
  end,
  ["bag.select-item"] = function(self, action)
    self.controller:selectBagItem(action.itemKey)
    self:_openDecision("bag-item")
  end,
  ["bag.add-item"] = function(self)
    self:_cancelPendingLocationSave()
    self:_beginBagAdd()
  end,
  ["bag.edit-quantity"] = editBagQuantity,
  ["bag.remove-item"] = removeBagItem,
}

local NUMBER_GUARDED_ACTIONS = {
  ["value.confirm"] = true,
  ["value.adjust-number-place"] = true,
  ["value.press"] = true,
}

function State:_dispatchActivationAction(action, layout)
  if action.kind:match("^decision%.") and action.command ~= nil then
    self:_performDecisionCommand(assert(action.decision), action.command, assert(action.id))
    return
  end
  if NUMBER_GUARDED_ACTIONS[action.kind] and self:_numberEditorTooSmall(layout) then
    return
  end
  local handler = ACTIVATION_HANDLERS[action.kind]
  if handler == nil then
    error("unknown Save Editor activation action: " .. tostring(action.kind), 2)
  end
  handler(self, action)
end

function State:_activate(targetId)
  self:_activateControl(targetId, self:_reconcileFocus())
end

function State:_dispatchIntent(intent)
  if intent == nil then
    return
  end
  if intent.kind == "back" then
    self:_requestBack()
  elseif intent.kind == "activate" then
    self:_activateControl(intent.targetId, self:_reconcileFocus())
  elseif intent.kind == "action" then
    self:_activateControl(intent.action, self:_reconcileFocus())
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
      self:_popModalLayer("leave")
      local request = assert(self.closeRequest)
      self.closeRequest = nil
      self.controller.modal = request.previousModal
      self.controller.modalReturnFocus = request.previousModalReturnFocus
      self.controller:setFocus(request.previousFocus)
    elseif self.valueEditor then
      self.valueEditor:cancel()
      self:_finishValueEditor()
    elseif intent.modal == "party-move" then
      self.pendingMoveSlot = nil
      self:_closeDecision()
    elseif intent.modal == "remove" then
      self.pendingRemove = nil
      self.controller.modalReturnFocus = nil
    else
      self:_closeDecision()
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
    self:_navigate(layout, intent.direction)
    self.controller:cancelInteraction()
  end
end

function State:_navigate(layout, direction)
  assert(layout.focusNavigation, "Save Editor layout publishes navigation regions")
  local focus = logicalFocus(layout, self.controller.focus)
  if focus == nil then
    focus = assert(logicalFocus(layout, layout.defaultFocus), "default focus belongs to a published region")
  end
  if
    self.controller.modal == nil
    and self.valueEditor == nil
    and self.controller.section == "Location"
    and self.controller.locationPage == "grid"
    and self.controller.locationFocus == "grid"
    and (self.controller.focus == "location:grid" or self.controller.focus:match("^location:tile:") ~= nil)
  then
    self:_performDeferred({ kind = "location-cursor-move", direction = direction })
    self.controller:markKeyboardNavigation()
    return
  end
  local place, arrow = focus.targetId:match("^number:place:(%d+):([^:]+)$")
  if self.valueEditor ~= nil and place ~= nil then
    local selected = math.floor(assert(tonumber(place)))
    if direction == "up" or direction == "down" then
      self:_adjustNumberPlace(selected, direction == "up" and 1 or -1)
      self.controller:markKeyboardNavigation()
      return
    elseif direction == "left" or direction == "right" then
      local nextPlace = selected + (direction == "left" and 1 or -1)
      if nextPlace >= 0 and nextPlace < self.valueEditor:snapshot().digitCount then
        self.valueEditor:selectPlace(nextPlace)
        self.controller:setFocus("number:place:" .. tostring(nextPlace) .. ":" .. (arrow or "up"))
        self.controller:markKeyboardNavigation()
        return
      end
    end
  end
  local snapshot = navigationSnapshotForState(self, layout)
  local resolved = SaveEditorNavigation.resolve(snapshot, focus, direction)
  self.controller:markKeyboardNavigation()
  if resolved.kind == "edit" then
    assert(self.valueEditor, "an editing result requires an active native editor")
    self.valueEditor:press(direction)
  elseif resolved.kind == "move" then
    self:_applyNavigationMove(layout, resolved)
  end
end

---@param layout table<string, unknown>
---@param resolved table<string, unknown>
function State:_applyNavigationMove(layout, resolved)
  local targetId = assert(resolved.targetId)
  local regionId = assert(resolved.regionId)
  self.controller:setFocus(targetId)
  self.controller:rememberRegionFocus(regionId, targetId)
  for _, region in ipairs(layout.focusNavigation.regions) do
    if region.id == regionId and region.kind == "list" then
      self.controller:setListCursor(region.id, targetId)
      break
    end
  end
  self:_revealFocusedTarget(layout, targetId, resolved.reveal)
end

---@param layout table<string, unknown>
---@param direction "previous"|"next"
function State:_navigateTab(layout, direction)
  local focus = logicalFocus(layout, self.controller.focus)
  if focus == nil then
    focus = assert(logicalFocus(layout, layout.defaultFocus), "default focus belongs to a published region")
  end
  local resolved = SaveEditorNavigation.resolveTab(navigationSnapshotForState(self, layout), focus, direction)
  self.controller:markKeyboardNavigation()
  if resolved.kind == "move" then
    self:_applyNavigationMove(layout, resolved)
  end
end

function State:_pointer(events)
  if self.disposed or self.resultSent then
    return
  end
  self:_settleScope()
  local view = self:_ensurePublished()
  local plan = assert(self._publishedPlan, "the settled publication owns its plan")
  local numberEditor = self.valueEditor ~= nil and self.valueEditor:snapshot().kind == "number"
  if numberEditor and self:_numberEditorTooSmall(plan.content.layout) and plan.content.layout.targets.cancel == nil then
    self:_refreshPublication()
    return self._publishedPlan or plan
  end
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
    local pointerStart = self.controller.locationPointerStart
    if
      event.type == "pointer_move"
      and self.controller.locationDragging
      and pointerStart ~= nil
      and pointerStart.grid ~= nil
    then
      self:_takeLocationCursorOwnership()
    end
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
    if self.disposed or self.resultSent then
      self._pointerDispatching = false
      return plan
    end
    if
      event.type == "pointer_down"
      and self.valueEditor ~= nil
      and self.valueEditor:snapshot().kind == "number"
      and event.targetId ~= nil
      and event.targetId:match("^number:place:(%d+):([^:]+)$")
    then
      local place, direction = event.targetId:match("^number:place:(%d+):([^:]+)$")
      assert(direction == "up" or direction == "down")
      local sign = direction == "up" and 1 or -1
      self:_adjustNumberPlace(assert(tonumber(place)), sign)
      local pressTicks = assert(view.numberPressTicks, "number controls carry source press timing")
      assert(pressTicks > 0 and pressTicks % 1 == 0, "number control press timing is a positive integer")
      self.numberPressTarget = event.targetId
      self.numberPressUntilTick = self.inputTick + pressTicks
      self.numberHold = {
        pointerId = event.pointerId,
        targetId = event.targetId,
        delta = sign,
        scopeEpoch = self.controller.scopeEpoch,
        nextTick = self.inputTick + FieldInput.UI_REPEAT_DELAY_TICKS,
      }
    end
    self._pointerDispatching = false
    self:_syncScope()
  end
  if self.disposed or self.resultSent then
    return plan
  end
  self:_reconcileFocus()
  self:_settleScope()
  self:_invalidatePublication()
  self:_refreshPublication()
  return self._publishedPlan or plan
end

-- Synchronous fresh-observation API: republishes when a boundary
-- marked the pair stale and otherwise returns the coherent pair.
function State:view()
  return self:_ensurePublished()
end

-- Draw only consumes the settled publication: it never changes scope,
-- input buffers, focus, drafts, selection, hold counters, verification
-- state, or derived-asset demand. Visible icon images are prepared for drawing.
function State:draw()
  if self.disposed then
    return
  end
  local view = assert(self._publishedView, "draw consumes the settled publication")
  local plan = assert(self._publishedPlan, "the settled publication owns its plan")
  ApplicationPresentation.draw(
    self.renderer.graphics,
    { renderer = self.renderer, text = self.renderer.text },
    view,
    plan
  )
  self:_drawNavigationDebug(view)
end

function State:_drawNavigationDebug(view)
  if not self.navigationDebug or view.layout == nil then
    return
  end
  local layout = view.layout
  local focus = logicalFocus(layout, self.controller.focus)
  if focus == nil then
    return
  end
  local control
  for _, candidate in ipairs(layout.focusNavigation.controls) do
    if candidate.id == focus.targetId then
      control = candidate
      break
    end
  end
  local region
  for _, candidate in ipairs(layout.focusNavigation.regions) do
    if candidate.id == focus.regionId then
      region = candidate
      break
    end
  end
  local graphics = self.renderer.graphics
  local rect = control and control.rect or region and region.rect
  graphics.push("all")
  if rect ~= nil then
    local interactivePlacement
    for _, pane in ipairs(view.presentation.panes) do
      if pane.interactive then
        interactivePlacement = pane.placement
        break
      end
    end
    assert(interactivePlacement, "navigation diagnostics require the active logical pane placement")
    LogicalSurface.draw(graphics, interactivePlacement, function()
      graphics.setColor(1, 0.85, 0.2, 1)
      graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
    end)
  end
  local lines = { focus.regionId .. " / " .. focus.targetId }
  local snapshot = navigationSnapshotForState(self, layout)
  for _, direction in ipairs({ "up", "down", "left", "right" }) do
    local resolved = SaveEditorNavigation.resolve(snapshot, focus, direction)
    lines[#lines + 1] = direction
      .. ": "
      .. resolved.reason
      .. (resolved.targetId and (" → " .. resolved.targetId) or "")
  end
  graphics.setColor(0, 0, 0, 0.9)
  graphics.rectangle("fill", 4, 4, 250, #lines * 14 + 8)
  graphics.setColor(1, 1, 1, 1)
  for index, line in ipairs(lines) do
    graphics.print(line, 8, 8 + (index - 1) * 14)
  end
  graphics.pop()
end

function State:resize(width, height)
  self:_invalidatePublication()
  local numberEditor = self.valueEditor ~= nil and self.valueEditor:snapshot().kind == "number"
  local wasNumberTooSmall = numberEditor and self:_numberEditorTooSmall() or false
  self.width, self.height = width, height
  self.presentation:cancelPointers()
  self.controller:cancelInteraction()
  self.numberHold = nil
  self.numberPressTarget = nil
  self.locationViewport = nil
  self.locationGridWidthTiles = nil
  self.locationGridHeightTiles = nil
  if numberEditor then
    local layout = assert(self:_resolve(self:_snapshot()).content.layout)
    if not self:_numberEditorTooSmall(layout) then
      local preferred
      if wasNumberTooSmall then
        preferred = "number:place:" .. tostring(self.valueEditor:snapshot().selectedPlace) .. ":up"
      end
      self:_reconcileFocus(preferred, layout)
    elseif layout.targets.cancel ~= nil then
      self:_reconcileFocus(nil, layout)
    end
  end
  self:_settleScope()
  self:_refreshPublication()
end

function State:focus(focused)
  if not focused then
    self:_invalidatePublication()
    self.presentation:cancelPointers()
    self.controller:cancelInteraction()
    self.numberHold = nil
    self.numberPressTarget = nil
    self.fieldInput:clearAll()
    self.fieldInput:beginUi(self.inputTick)
    self:_settleScope()
    self:_refreshPublication()
  end
end

-- Consumes one batch of normalized UI events. Scope settles before the
-- first event acts, so already-retired captures cannot fire, and after
-- the batch, so later batches observe the settled epoch.
function State:_consumeUiInput(events)
  if self.disposed or self.resultSent then
    return
  end
  self:_settleScope()
  self:_invalidatePublication()
  if self.valueEditor ~= nil and self.valueEditor:snapshot().kind == "number" then
    local layout = assert(self:_ensurePublished().layout)
    if self:_numberEditorTooSmall(layout) and layout.targets.cancel == nil then
      for _, event in ipairs(events) do
        if event.type == "cancel" then
          self.valueEditor:cancel()
          self:_finishValueEditor()
          self:_syncScope()
          self:_reconcileFocus()
          break
        end
      end
      self:_settleScope()
      self:_refreshPublication()
      return
    end
  end
  for _, event in ipairs(events) do
    if event.type == "navigate" then
      local layout = self:_reconcileFocus()
      self:_navigate(layout, event.direction)
      self.controller:cancelInteraction()
    elseif event.type == "confirm" then
      local currentLayout = self:_reconcileFocus()
      if self.controller.modal then
        local target = currentLayout.targets[self.controller.focus]
        if target and target.focusable and target.activationEnabled then
          self:_dispatchIntent(self.controller:press("confirm"))
        end
      elseif self:_activeList(currentLayout) ~= nil then
        local list, rowIndex = self:_activeList(currentLayout)
        self:_handleListConfirm(assert(list), rowIndex, currentLayout)
      elseif self.valueEditor then
        if self:_numberEditorTooSmall(currentLayout) then
          local cancelTarget = currentLayout.targets.cancel
          if self.controller.focus == "cancel" and cancelTarget and cancelTarget.focusable then
            self:_activateControl("cancel", currentLayout)
          end
        elseif self.valueEditor:snapshot().kind == "number" then
          local targetId = self.controller.focus
          local target = currentLayout.targets[targetId]
          if (targetId == "confirm" or targetId == "cancel") and target and target.focusable then
            self:_activateControl(targetId, currentLayout)
          end
        else
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
        end
      else
        self:_dispatchIntent(self.controller:press("confirm"))
      end
    elseif event.type == "cancel" then
      if self.controller.modal then
        self:_dispatchIntent(self.controller:press("cancel"))
      elseif self.valueEditor then
        if self.valueEditor:snapshot().kind == "number" and self.controller.focus ~= "cancel" then
          self.controller:setFocus("cancel")
          self.controller:markKeyboardNavigation()
          self.controller:cancelInteraction()
        else
          self.valueEditor:cancel()
          self:_finishValueEditor()
        end
      else
        self:_dispatchIntent(self.controller:press("cancel"))
      end
    end
    if self.disposed or self.resultSent then
      return
    end
    self:_syncScope()
  end
  if not self.disposed and not self.resultSent then
    self:_invalidatePublication()
    self:_reconcileFocus()
    self:_settleScope()
    self:_refreshPublication()
  end
end

function State:keypressed(key, _, isrepeat)
  if self.disposed or self.resultSent or isrepeat or self.status == "opening" then
    return
  end
  if self.valueEditor ~= nil and self.valueEditor:snapshot().kind == "number" then
    local editorLayout = assert(self:_resolve(self:_snapshot()).content.layout)
    if self:_numberEditorTooSmall(editorLayout) then
      local source = "key:" .. key
      if key == "escape" then
        self.valueEditor:cancel()
        self:_finishValueEditor()
        self:_invalidatePublication()
        self:_settleScope()
        self:_refreshPublication()
      elseif editorLayout.targets.cancel ~= nil and (key == "return" or key == "kpenter") then
        self.fieldInput:pressAction(source)
        self:_consumeUiInput(self.fieldInput:uiSnapshot(self.inputTick))
      end
      return
    end
  end
  if key == "tab" then
    local layout = self:_resolve(self:_snapshot()).content.layout
    local direction = love.keyboard.isDown("lshift", "rshift") and "previous" or "next"
    self:_navigateTab(layout, direction)
    self.controller:cancelInteraction()
    self:_invalidatePublication()
    self:_settleScope()
    self:_refreshPublication()
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
    if self:_numberEditorTooSmall(editorLayout) then
      if key == "escape" then
        self.valueEditor:cancel()
        self:_finishValueEditor()
        self:_invalidatePublication()
        self:_settleScope()
        self:_refreshPublication()
      end
      return
    end
    if self.valueEditor:snapshot().kind == "number" then
      local source = "key:" .. key
      if key == "up" or key == "down" or key == "left" or key == "right" then
        self.fieldInput:pressDirection(FIELD_DIRECTIONS[key], source)
        self:_consumeUiInput(self.fieldInput:uiSnapshot(self.inputTick))
      elseif key == "return" or key == "kpenter" then
        self.fieldInput:pressAction(source)
        self:_consumeUiInput(self.fieldInput:uiSnapshot(self.inputTick))
      elseif key == "escape" then
        self.fieldInput:pressCancel(source)
        self:_consumeUiInput(self.fieldInput:uiSnapshot(self.inputTick))
      elseif key == "backspace" then
        self.valueEditor:press("backspace")
        self:_syncScope()
      elseif key == "delete" then
        self.valueEditor:press("clear_search")
        self:_syncScope()
      end
      return
    end
    local editorList, editorRow = self:_activeList(editorLayout)
    local choiceList = editorList ~= nil and editorList.id == "value:choice" and editorList or nil
    if self.valueEditor:snapshot().kind == "choice" then
      -- An active choice list shares the gamepad and normalized input
      -- machinery: physical keys classify once into navigation, confirm and
      -- cancel events for the shared consumer below. A discrete press builds
      -- one event instead of latching a held physical source, so repeated
      -- confirms never depend on release ordering. Filter editing
      -- (backspace/delete) and text entry stay on their direct
      -- keyboard-only paths, and space keeps its text behavior instead of
      -- confirming.
      if key == "up" or key == "down" or key == "left" or key == "right" then
        self:_consumeUiInput({ { type = "navigate", direction = key } })
      elseif key == "backspace" then
        if choiceList ~= nil then
          self:_filterFocusedList(choiceList, editorRow, "backspace")
        else
          self.valueEditor:press("backspace")
        end
        self:_invalidatePublication()
        self:_syncScope()
        self:_reconcileFocus()
        self:_settleScope()
        self:_refreshPublication()
      elseif key == "delete" then
        if choiceList ~= nil then
          self:_filterFocusedList(choiceList, editorRow, "clear")
        else
          self.valueEditor:press("clear_search")
        end
        self:_invalidatePublication()
        self:_syncScope()
        self:_reconcileFocus()
        self:_settleScope()
        self:_refreshPublication()
      elseif HgssInputBindings.isCancelKey(key) then
        self:_consumeUiInput({ { type = "cancel" } })
      elseif key == "return" or key == "kpenter" then
        self:_consumeUiInput({ { type = "confirm" } })
      else
        self:_invalidatePublication()
        self:_syncScope()
        self:_reconcileFocus()
        self:_settleScope()
        self:_refreshPublication()
      end
      return
    end
    if key == "return" or key == "kpenter" then
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
      self.controller:markKeyboardNavigation()
      self:_navigate(editorLayout, key)
    end
    self:_invalidatePublication()
    self:_syncScope()
    self:_reconcileFocus()
    self:_settleScope()
    self:_refreshPublication()
    return
  end
  if key == "backspace" or key == "delete" then
    local layout = self:_resolve(self:_snapshot()).content.layout
    local list, rowIndex = self:_activeList(layout)
    if list ~= nil and list.filterable then
      self:_filterFocusedList(list, rowIndex, key == "delete" and "clear" or "backspace")
      self:_invalidatePublication()
      self:_reconcileFocus()
      self:_settleScope()
      self:_refreshPublication()
    end
    return
  end
  if isPrintableKeyName(key) then
    local layout = self:_resolve(self:_snapshot()).content.layout
    local list = self:_activeList(layout)
    if list ~= nil and list.filterable then
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
  if self.disposed or self.resultSent then
    return
  end
  self:_invalidatePublication()
  if self.valueEditor then
    if self:_numberEditorTooSmall() then
      return
    end
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
    self:_refreshPublication()
    return
  end
  local layout = assert(self:_ensurePublished().layout)
  local list, rowIndex = self:_activeList(layout)
  if list == nil or not list.filterable then
    return
  end
  self:_filterFocusedList(list, rowIndex, "append", text)
  self:_settleScope()
  self:_refreshPublication()
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
  if self.disposed or self.resultSent then
    return
  end
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
  if self.disposed or self.resultSent then
    return
  end
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
  elseif viewportId:match("^location:") then
    self.controller.locationMapOffset = clamped
    self.controller.scrollOffset = clamped
  else
    if viewportId == "value:choice" then
      self.preserveChoiceScroll = true
    end
    local purpose = assert(scrollPurpose(viewportId, view))
    self.controller.scrollOffsets[purpose] = clamped
  end
end

function State:wheelmoved(_, y)
  if y ~= 0 then
    self.controller:markPointerModality()
  end
  local view = self:_ensurePublished()
  local layout = assert(view.layout)
  local viewportId = layout.scrollOwner
  if viewportId == nil then
    return
  end
  local viewport = assert(layout.viewports[viewportId], "active scroll owner needs a published viewport")
  self:_invalidatePublication()
  self:_setScrollOffset(view, layout, viewportId, viewport.offset - y * viewport.rowExtent)
  self:_settleScope()
  self:_refreshPublication()
end

function State:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  self._publishedView = nil
  self._publishedPlan = nil
  self._publishedDirty = true
  self.numberHold = nil
  self.numberPressTarget = nil
  self.generation = self.generation + 1
  self:_finishPreset()
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
  self.modalStack:dispose()
  if self.valueEditor then
    self.valueEditor:dispose()
  end
  self.valueEditor = nil
  self.session = nil
  self._uiSessionSnapshot = nil
  self.dependencies = nil
  self.partyView = nil
end

return State
