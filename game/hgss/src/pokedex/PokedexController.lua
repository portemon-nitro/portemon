-- The deterministic browser state machine: cover, sparse numbered grid,
-- transactional search with source feedback timing, result origin, entry
-- pages, comparison, return, and the close lifecycle. Borrows the
-- generated catalog and the authoritative knowledge owner, delegates
-- page-specific policy to four leaf helpers, and projects a detached
-- semantic view with one-shot effects for the presentation owner. Pure
-- policy: no love, no rendering, no I/O, no history writes.

local Errors = require("libs.errors.src.Errors")
local PokedexArea = require("game.hgss.src.pokedex.PokedexArea")
local PokedexForms = require("game.hgss.src.pokedex.PokedexForms")
local PokedexSearch = require("game.hgss.src.pokedex.PokedexSearch")
local PokedexSize = require("game.hgss.src.pokedex.PokedexSize")

---@class PokedexController
---@field _catalog table<string, unknown> borrowed generated catalog
---@field _monCatalog table<string, unknown> borrowed resolved mon catalog
---@field _dex table<string, unknown> borrowed authoritative knowledge owner
---@field _playerGender string trainer gender selecting height records
---@field _playerName string? trainer display name behind the size page
---@field _playerPosition table<string, integer> captured global block cell
---@field _nativeLanguage string selected game language key
---@field _mode string active dex mode
---@field _profileName string frozen per-open measurement profile
---@field _nationalUnlocked boolean cached national availability
---@field _page string top-level page
---@field _origin string entry/results origin
---@field _cursor integer zero-based grid/results cursor
---@field _pageIndex integer current grid/results page
---@field _selection table<string, unknown> current selection facts
---@field _resumeSelection string? last eligible in-session species
---@field _search PokedexSearch criteria owner
---@field _feedback { phase: string, tick: integer, wait: integer, list: string[]? }? running search feedback sequence
---@field _results string[] completed result species list
---@field _area PokedexArea? entry area helper
---@field _size PokedexSize? entry size helper
---@field _forms PokedexForms? entry forms helper
---@field _entrySpecies string? open entry species
---@field _originGrid { page: integer, cursor: integer } saved grid cursor for entry/results return
---@field _originResults { list: string[], cursor: integer, page: integer }? saved results list for entry return
---@field _key integer resource demand generation
---@field _revision integer observed knowledge revision
---@field _effects table[] pending one-shot effects
---@field _result { kind: string }? terminal close result
---@field _closing boolean close sequence running
---@field _areaPanRegion integer viewed map region driving the scroll, 0 johto or 1 kanto
---@field _areaPanOffset integer current SUB BG0 X scroll in native pixels
---@field _disposed boolean teardown flag
---@field _coverOffset integer cover slide position
---@field _coverDrag { from: number, preOffset: integer }? in-progress cover drag
---@field _held { left: boolean, right: boolean, touch: boolean } last held snapshot
---@field _transition { phase: string, tick: integer } named visual phase and tick
local PokedexController = {}
PokedexController.__index = PokedexController

PokedexController.LANGUAGE_ORDER = { "english", "french", "german", "italian", "spanish", "japanese" }

-- Source feedback gates in fixed updates.
PokedexController.FEED_LABEL_TICKS = 28
PokedexController.FEED_RISE_TICKS = 52
PokedexController.FEED_HOLD_TICKS = 32
PokedexController.FEED_MOVE_TICKS = 24
PokedexController.FEED_RETRACT_TICKS = 20
PokedexController.FEED_TIMEOUT_TICKS = 60

-- Ordered keyboard/gamepad focus graph across the search root: the
-- seven source criteria followed by the run and reset actions.
local SEARCH_FOCUSABLES = { "order", "letter", "type", "shape", "area", "height", "weight", "run", "reset" }

-- Scrollbar families: source thresholds map to authored thumb lengths.
PokedexController.SCROLL_THRESHOLDS = { 15, 45, 90, 135, 180, 225, 270, 315, 360, 405, 450, 495 }
PokedexController.SCROLL_LENGTHS = { 110, 102, 94, 86, 78, 70, 62, 54, 46, 38, 30, 22 }
PokedexController.SCROLL_TOP = 21
PokedexController.SCROLL_BOTTOM = 131
-- The area map rides SUB BG0: settled native X scroll per region with an
-- eight-pixel per-frame travel between the two settled positions.
PokedexController.AREA_PAN_STEP = 8
PokedexController.AREA_PAN_JOHTO = -72
PokedexController.AREA_PAN_KANTO = 104

-- Compact result paging reserves the return slot alongside the matches.
PokedexController.RESULT_SLOTS = 15

local function fail(message, context)
  Errors.raise("POKEDEX_INVALID", message, context)
end

---@param value unknown
---@param what string
---@return table<string, unknown>
local function checkTable(value, what)
  if type(value) ~= "table" then
    fail("browser needs " .. what, {})
  end
  assert(type(value) == "table", "the browser reads its borrowed state")
  return value
end

---@param list unknown
---@param what string
local function checkDenseStrings(list, what)
  if type(list) ~= "table" then
    fail("browser catalog is missing its " .. what, {})
  end
  assert(type(list) == "table", "the browser reads its borrowed catalog")
  local count = 0
  for key in pairs(list) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
      fail("browser catalog needs a dense " .. what, {})
    end
    count = count + 1
  end
  for index = 1, count do
    if type(list[index]) ~= "string" then
      fail("browser catalog needs a dense " .. what, {})
    end
  end
end

---@param catalog table<string, unknown>
local function checkCatalog(catalog)
  checkTable(catalog, "the generated catalog")
  assert(type(catalog) == "table", "the browser reads its borrowed catalog")
  local orders = checkTable(catalog.dexOrders, "dex orders")
  checkDenseStrings(orders.johto, "johto order")
  checkDenseStrings(orders.national, "national order")
  local speciesRecords = checkTable(catalog.species, "species records")
  for _, mode in ipairs({ "johto", "national" }) do
    for _, key in ipairs(orders[mode]) do
      local record = speciesRecords[key]
      if type(record) ~= "table" then
        fail("browser catalog is missing its species record", { species = key })
      end
      local policy = record.formPolicy
      if type(policy) ~= "table" or type(policy.variants) ~= "table" then
        fail("browser catalog is missing its form policy", { species = key })
      end
    end
  end
  local profiles = checkTable(catalog.measurementProfiles, "measurement profiles")
  for _, name in ipairs({ "base", "giratina_origin" }) do
    local profile = profiles[name]
    if type(profile) ~= "table" then
      fail("browser catalog is missing its measurement profile", { profile = name })
    end
    local measurements = profile.measurements
    if type(measurements) ~= "table" then
      fail("browser catalog is missing its measurements", { profile = name })
    end
    for _, key in ipairs(orders.national) do
      local row = measurements[key]
      if type(row) ~= "table" or type(row.heightDm) ~= "number" or type(row.weightHg) ~= "number" then
        fail("browser catalog is missing its legal measurement row", { species = key, profile = name })
      end
    end
  end
  local sorts = checkTable(catalog.sortOrders, "sort orders")
  checkDenseStrings(sorts.alphabetical, "alphabetical order")
  checkTable(catalog.criteria, "search criteria lists")
  local steps = checkTable(catalog.sliderSteps, "slider steps")
  for position = 1, 153 do
    local step = steps[position]
    if type(step) ~= "table" or type(step.heightDm) ~= "number" or type(step.weightHg) ~= "number" then
      fail("browser catalog is missing its slider step", { step = position })
    end
  end
  checkTable(catalog.areaGeometry, "area geometry")
  if type(catalog.areaOrder) ~= "table" then
    fail("browser catalog is missing its area order", {})
  end
  checkTable(catalog.habitats, "habitats")
end

---@param dex table<string, unknown>
---@param method string
---@param argument string?
---@return unknown
local function tryDex(dex, method, argument)
  local reader = dex[method]
  if type(reader) ~= "function" then
    return nil
  end
  local ok, result = pcall(reader, dex, argument)
  if not ok then
    return nil
  end
  return result
end

---@param args { catalog: table<string, unknown>, monCatalog: table<string, unknown>, dex: table<string, unknown>, playerGender: string, playerPosition: table<string, unknown>, playerName: string?, nativeLanguage: string }
---@return PokedexController
function PokedexController.new(args)
  if type(args) ~= "table" then
    fail("browser needs a construction record", {})
  end
  assert(type(args) == "table", "the browser reads its construction record")
  checkCatalog(checkTable(args.catalog, "the generated catalog"))
  if type(args.monCatalog) ~= "table" then
    fail("browser needs the resolved mon catalog", {})
  end
  if type(args.dex) ~= "table" then
    fail("browser needs the knowledge owner", {})
  end
  if args.playerGender ~= "male" and args.playerGender ~= "female" then
    fail("browser needs the trainer gender", {})
  end
  if args.playerName ~= nil and (type(args.playerName) ~= "string" or args.playerName == "") then
    fail("browser needs a nonempty trainer name when one travels", {})
  end
  local position = checkTable(args.playerPosition, "the captured player cell")
  if type(position.mapX) ~= "number" or type(position.mapY) ~= "number" then
    fail("browser needs the captured global block cell", {})
  end
  if type(args.nativeLanguage) ~= "string" or args.nativeLanguage == "" then
    fail("browser needs the native language key", {})
  end
  local dex = args.dex
  local nationalUnlocked = tryDex(dex, "hasNationalDex") == true
  local resume = tryDex(dex, "resume")
  if type(resume) ~= "table" then
    resume = {}
  end
  assert(type(resume) == "table", "the browser reads the resume record")
  local mode = "johto"
  if resume.mode == "national" and nationalUnlocked == true then
    mode = "national"
  elseif resume.mode == "johto" then
    mode = "johto"
  elseif nationalUnlocked == true then
    mode = "national"
  end
  local profileName = "base"
  local giratinaCaught = tryDex(dex, "isCaught", "GIRATINA") == true
  if giratinaCaught == true then
    local variants = tryDex(dex, "observedVariants", "GIRATINA")
    if type(variants) == "table" and type(variants[1]) == "number" then
      local catalog = args.catalog
      assert(type(catalog) == "table", "the browser reads its borrowed catalog")
      local speciesRecords = catalog.species
      assert(type(speciesRecords) == "table", "the browser reads species records")
      local record = speciesRecords.GIRATINA
      if type(record) == "table" and type(record.formPolicy) == "table" then
        local entries = record.formPolicy.variants
        if type(entries) == "table" then
          for _, entry in ipairs(entries) do
            if entry.id == variants[1] and entry.form == 1 then
              profileName = "giratina_origin"
            end
          end
        end
      end
    end
  end
  local self = setmetatable({
    _catalog = args.catalog,
    _monCatalog = args.monCatalog,
    _dex = dex,
    _playerGender = args.playerGender,
    _playerName = args.playerName,
    _playerPosition = { mapX = position.mapX, mapY = position.mapY },
    _nativeLanguage = args.nativeLanguage,
    _mode = mode,
    _profileName = profileName,
    _nationalUnlocked = nationalUnlocked,
    _page = "cover",
    _origin = "grid",
    _cursor = 0,
    _pageIndex = 0,
    _selection = { seen = false, caught = false, language = args.nativeLanguage },
    _resumeSelection = nil,
    _search = PokedexSearch.new({ catalog = args.catalog, dex = dex }),
    _feedback = nil,
    _results = {},
    _searchFocus = "order",
    _area = nil,
    _size = nil,
    _forms = nil,
    _entrySpecies = nil,
    _originGrid = { page = 0, cursor = 0 },
    _originResults = nil,
    _key = 1,
    _spriteTick = 0,
    _objectAges = {},
    _objectPage = nil,
    _revision = 0,
    _effects = {},
    _result = nil,
    _closing = false,
    _areaPanRegion = 0,
    _areaPanOffset = PokedexController.AREA_PAN_JOHTO,
    _disposed = false,
    _coverOffset = 0,
    _coverDrag = nil,
    _held = { left = false, right = false, touch = false },
    _transition = { phase = "rest", tick = 0 },
  }, PokedexController)
  local revision = tryDex(dex, "revision")
  if type(revision) == "number" then
    self._revision = revision
  end
  self._search:setContext({ mode = mode, profileName = profileName, nationalUnlocked = nationalUnlocked })
  self:_restoreSelection(resume.species)
  return self
end

---@return string[] the active regional order backing every numbered operation
function PokedexController:_activeOrder()
  local orders = self._catalog.dexOrders
  assert(type(orders) == "table", "the browser reads its dex orders")
  local order = assert(orders[self._mode], "the browser reads the active dex order")
  assert(type(order) == "table", "the browser reads the active dex order")
  return order
end

---@return boolean whether the cursor addresses the single global search-return slot
function PokedexController:_isSearchReturnSlot()
  return self._pageIndex == 0 and self._cursor == 0
end

---@param speciesKey string?
function PokedexController:_restoreSelection(speciesKey)
  local dex = self._dex
  local order = self:_activeOrder()
  local target = nil
  if type(speciesKey) == "string" and tryDex(dex, "isSeen", speciesKey) == true then
    for _, key in ipairs(order) do
      if key == speciesKey then
        target = speciesKey
        break
      end
    end
  end
  if target == nil then
    for _, key in ipairs(order) do
      if tryDex(dex, "isSeen", key) == true then
        target = key
        break
      end
    end
  end
  if target == nil then
    self._selection = { seen = false, caught = false, language = self._nativeLanguage }
    self._cursor = 0
    self._pageIndex = 0
    return
  end
  for index, key in ipairs(order) do
    if key == target then
      self._pageIndex = math.floor((index - 1) / PokedexController.RESULT_SLOTS)
      self._cursor = (index - 1) % PokedexController.RESULT_SLOTS
    end
  end
  self:_select(target)
end

---@param speciesKey string?
function PokedexController:_select(speciesKey)
  if type(speciesKey) ~= "string" then
    self._selection = { seen = false, caught = false, language = self._nativeLanguage }
    return
  end
  local seen = tryDex(self._dex, "isSeen", speciesKey) == true
  if seen ~= true then
    self._selection = { seen = false, caught = false, language = self._nativeLanguage }
    return
  end
  local caught = tryDex(self._dex, "isCaught", speciesKey) == true
  local language = self._selection.language
  if type(language) ~= "string" then
    language = self._nativeLanguage
  end
  if language ~= self._nativeLanguage and not self:_languageAcquired(speciesKey, language) then
    language = self._nativeLanguage
  end
  local order = self:_activeOrder()
  local dexNumber = nil
  for index, key in ipairs(order) do
    if key == speciesKey then
      dexNumber = index
    end
  end
  self._selection = { species = speciesKey, dexNumber = dexNumber, seen = true, caught = caught, language = language }
  self._resumeSelection = speciesKey
end

-- After a regional mode change the cursor keeps its eligible selection in
-- the new order, or falls back to the first member of the new order.
-- Dex history is never touched: only the ephemeral cursor moves.
function PokedexController:_reconcileModeSelection()
  local order = self:_activeOrder()
  local species = self._selection.species
  if type(species) == "string" and tryDex(self._dex, "isSeen", species) == true then
    for index, key in ipairs(order) do
      if key == species then
        self:_select(species)
        self._pageIndex = math.floor((index - 1) / PokedexController.RESULT_SLOTS)
        self._cursor = (index - 1) % PokedexController.RESULT_SLOTS
        return
      end
    end
  end
  self:_restoreSelection(nil)
end

---@param speciesKey string
---@param language string
---@return boolean
function PokedexController:_languageAcquired(speciesKey, language)
  local languages = tryDex(self._dex, "caughtLanguages", speciesKey)
  if type(languages) ~= "table" then
    return false
  end
  for _, key in ipairs(languages) do
    if key == language then
      return true
    end
  end
  return false
end

function PokedexController:_bumpKey()
  self._key = self._key + 1
end

---@param role string
function PokedexController:_emitSound(role)
  self._effects[#self._effects + 1] = { kind = "sound", role = role }
end

---@param speciesKey string
---@param form integer
function PokedexController:_emitCry(speciesKey, form)
  self._effects[#self._effects + 1] = { kind = "cry", species = speciesKey, form = form, mode = 0, key = speciesKey }
end

function PokedexController:_emitResume()
  self._effects[#self._effects + 1] = { kind = "resume", mode = self._mode, species = self._resumeSelection }
end

---@param preparation { readyKey: integer }?
---@return boolean whether the update carries matching readiness
function PokedexController:_isReady(preparation)
  return type(preparation) == "table" and preparation.readyKey == self._key
end

---@return integer highest seen active-mode number, zero when empty
function PokedexController:_sparseLength()
  local order = self:_activeOrder()
  local length = 0
  for index, key in ipairs(order) do
    if tryDex(self._dex, "isSeen", key) == true then
      length = index
    end
  end
  return length
end

---@return integer last grid page guarding zero at empty
function PokedexController:_gridLastPage()
  local length = self:_sparseLength()
  if length <= 0 then
    return 0
  end
  return math.floor((length - 1) / PokedexController.RESULT_SLOTS) --[[@as integer]]
end

---@param length integer list length
---@return integer authored scrollbar thumb
function PokedexController:_scrollLength(length)
  for position, threshold in ipairs(PokedexController.SCROLL_THRESHOLDS) do
    if length <= threshold then
      return PokedexController.SCROLL_LENGTHS[position]
    end
  end
  return PokedexController.SCROLL_LENGTHS[#PokedexController.SCROLL_LENGTHS]
end

---@param length integer
---@param lastPage integer
---@param page integer
---@return { length: integer, position: integer } scrollbar projection
function PokedexController:_scrollbar(length, lastPage, page)
  local thumb = self:_scrollLength(length)
  local half = math.floor(thumb / 2)
  local minY = PokedexController.SCROLL_TOP + half
  local maxY = PokedexController.SCROLL_BOTTOM - half
  local position = maxY
  if lastPage > 0 then
    if page >= lastPage then
      position = maxY
    else
      local step = math.floor((maxY - minY) * 256 / lastPage)
      position = minY + math.floor(step * page / 256)
    end
  end
  return { length = thumb, position = position }
end

---@param speciesKey string
---@return integer first observed physical form for cries
function PokedexController:_cryForm(speciesKey)
  local variants = tryDex(self._dex, "observedVariants", speciesKey)
  if type(variants) == "table" and type(variants[1]) == "number" then
    local speciesRecords = self._catalog.species
    assert(type(speciesRecords) == "table", "the browser reads species records")
    local record = speciesRecords[speciesKey]
    if type(record) == "table" and type(record.formPolicy) == "table" then
      local entries = record.formPolicy.variants
      if type(entries) == "table" then
        for _, entry in ipairs(entries) do
          if entry.id == variants[1] and type(entry.form) == "number" then
            return entry.form
          end
        end
      end
    end
  end
  local speciesRecords = self._catalog.species
  assert(type(speciesRecords) == "table", "the browser reads species records")
  local record = speciesRecords[speciesKey]
  if type(record) == "table" and type(record.formPolicy) == "table" then
    local entries = record.formPolicy.variants
    if type(entries) == "table" and type(entries[1]) == "table" and type(entries[1].form) == "number" then
      return entries[1].form
    end
  end
  return 0
end

---@return { firstIndex: integer, yOffset: integer, entries: { index: integer, dexNumber: integer?, species: string?, seen: boolean, caught: boolean, returnToSearch: boolean }[] } detached grid buffer of thirty semantic entries
function PokedexController:_gridBuffer()
  local order = self:_activeOrder()
  local firstIndex = self._pageIndex * PokedexController.RESULT_SLOTS
  local entries = {}
  for position = 1, 30 do
    local global = firstIndex + position - 1
    local key = order[global + 1]
    if type(key) == "string" and tryDex(self._dex, "isSeen", key) == true then
      entries[#entries + 1] = {
        index = global,
        dexNumber = global + 1,
        species = key,
        seen = true,
        caught = tryDex(self._dex, "isCaught", key) == true,
        returnToSearch = false,
      }
    elseif type(key) == "string" then
      entries[#entries + 1] =
        { index = global, dexNumber = global + 1, seen = false, caught = false, returnToSearch = false }
    else
      entries[#entries + 1] = { index = global, seen = false, caught = false, returnToSearch = false }
    end
  end
  return { firstIndex = firstIndex, yOffset = 0, entries = entries }
end

---@return { firstIndex: integer, yOffset: integer, entries: { index: integer, dexNumber: integer?, species: string?, seen: boolean, caught: boolean, returnToSearch: boolean }[] } detached result buffer with the leading return slot
function PokedexController:_resultsBuffer()
  local firstIndex = self._pageIndex * PokedexController.RESULT_SLOTS
  local entries = {}
  for position = 1, 30 do
    local global = firstIndex + position - 1
    if global == 0 then
      entries[#entries + 1] = { index = 0, seen = false, caught = false, returnToSearch = true }
    else
      local key = self._results[global]
      if type(key) == "string" then
        entries[#entries + 1] = {
          index = global,
          dexNumber = self:_activeNumber(key),
          species = key,
          seen = true,
          caught = tryDex(self._dex, "isCaught", key) == true,
          returnToSearch = false,
        }
      else
        entries[#entries + 1] = { index = global, seen = false, caught = false, returnToSearch = false }
      end
    end
  end
  return { firstIndex = firstIndex, yOffset = 0, entries = entries }
end

---@param speciesKey string
---@return integer? active-mode number
function PokedexController:_activeNumber(speciesKey)
  local order = self:_activeOrder()
  for index, key in ipairs(order) do
    if key == speciesKey then
      return index
    end
  end
  return nil
end

---@return integer last results page including the return slot
function PokedexController:_resultsLastPage()
  return math.floor(#self._results / PokedexController.RESULT_SLOTS)
end

function PokedexController:_openEntry(speciesKey, origin)
  self._entrySpecies = speciesKey
  self._origin = origin
  local nationalUnlocked = self._nationalUnlocked
  self._area = PokedexArea.new({
    catalog = self._catalog,
    dex = self._dex,
    species = speciesKey,
    nationalUnlocked = nationalUnlocked,
    playerPosition = self._playerPosition,
  })
  self._forms = PokedexForms.new({
    catalog = self._catalog,
    monCatalog = self._monCatalog,
    dex = self._dex,
    species = speciesKey,
  })
  self._size = nil
  if tryDex(self._dex, "isCaught", speciesKey) == true then
    self._size = PokedexSize.new({
      catalog = self._catalog,
      species = speciesKey,
      profileName = self._profileName,
      playerGender = self._playerGender,
    })
  end
  self._page = "area"
  self:_bumpKey()
end

function PokedexController:_closeEntry()
  self._area = nil
  self._size = nil
  self._forms = nil
  self._entrySpecies = nil
end

function PokedexController:_returnToOrigin()
  local origin = self._origin
  self:_closeEntry()
  self:_emitResume()
  if origin == "results" and self._originResults ~= nil then
    local saved = self._originResults
    assert(type(saved) == "table", "entry return restores its saved results")
    self._results = saved.list
    self._cursor = saved.cursor
    self._pageIndex = saved.page
    self._page = "results"
    self:_refreshResultsSelection()
  else
    self._page = "grid"
    self._cursor = self._originGrid.cursor
    self._pageIndex = self._originGrid.page
    local species = self:_gridSlotSpecies(self._pageIndex * PokedexController.RESULT_SLOTS + self._cursor)
    if species ~= nil then
      self:_select(species)
    else
      self:_restoreSelection(self._resumeSelection)
    end
  end
  self:_bumpKey()
end

---@param global integer zero-based grid slot
---@return string? seen species at the slot
function PokedexController:_gridSlotSpecies(global)
  local order = self:_activeOrder()
  local key = order[global + 1]
  if type(key) == "string" and tryDex(self._dex, "isSeen", key) == true then
    return key
  end
  return nil
end

function PokedexController:_refreshGridSelection()
  local species = self:_gridSlotSpecies(self._pageIndex * PokedexController.RESULT_SLOTS + self._cursor)
  if species ~= nil then
    self:_select(species)
  else
    self._selection = { seen = false, caught = false, language = self._nativeLanguage }
  end
end

function PokedexController:_refreshResultsSelection()
  local global = self._pageIndex * PokedexController.RESULT_SLOTS + self._cursor
  if self:_isSearchReturnSlot() then
    self._selection = { seen = false, caught = false, language = self._nativeLanguage }
    return
  end
  local key = self._results[global]
  if type(key) == "string" then
    self:_select(key)
  else
    self._selection = { seen = false, caught = false, language = self._nativeLanguage }
  end
end

function PokedexController:_rebuildFromKnowledge()
  local dex = self._dex
  self._nationalUnlocked = tryDex(dex, "hasNationalDex") == true
  if self._mode == "national" and self._nationalUnlocked ~= true then
    self._mode = "johto"
  end
  self._search:setContext({
    mode = self._mode,
    profileName = self._profileName,
    nationalUnlocked = self._nationalUnlocked,
  })
  self._search:cancelDrag()
  self._coverDrag = nil
  local selectionSpecies = self._selection.species
  if type(selectionSpecies) == "string" and tryDex(dex, "isSeen", selectionSpecies) ~= true then
    selectionSpecies = nil
  end
  if self._page == "results" then
    local ok, list = pcall(function()
      return self._search:run()
    end)
    if ok == true and type(list) == "table" then
      self._results = list
    end
    local lastPage = self:_resultsLastPage()
    if self._pageIndex > lastPage then
      self._pageIndex = lastPage
    end
    if self._cursor > PokedexController.RESULT_SLOTS - 1 then
      self._cursor = PokedexController.RESULT_SLOTS - 1
    end
    self:_refreshResultsSelection()
  elseif self._page == "area" or self._page == "size" or self._page == "forms" or self._page == "return" then
    if type(self._entrySpecies) == "string" and tryDex(dex, "isSeen", self._entrySpecies) == true then
      local species = self._entrySpecies
      local page = self._page
      self:_openEntry(species, self._origin)
      if page == "size" and self._size == nil then
        self._page = "area"
      elseif page ~= "area" and page ~= "return" then
        self._page = page
      end
      self._key = self._key + 1
    else
      self:_closeEntry()
      self._page = "grid"
      self:_restoreSelection(selectionSpecies)
      self:_bumpKey()
    end
  else
    if type(selectionSpecies) == "string" then
      local order = self:_activeOrder()
      local positioned = false
      for index, key in ipairs(order) do
        if key == selectionSpecies then
          self:_select(selectionSpecies)
          self._pageIndex = math.floor((index - 1) / PokedexController.RESULT_SLOTS)
          self._cursor = (index - 1) % PokedexController.RESULT_SLOTS
          positioned = true
        end
      end
      if positioned ~= true then
        self:_restoreSelection(nil)
      end
    else
      self:_restoreSelection(nil)
    end
  end
  local revision = tryDex(dex, "revision")
  if type(revision) == "number" then
    self._revision = revision
  end
end

-- A fresh A/B/touch edge may end the empty-result wait: new confirms
-- and cancels plus fresh touch-down (an activate edge or the start of a
-- pointer drag). Held keys, navigation, and drag motion never dismiss.
---@param event table<string, unknown>
---@return boolean whether a fresh edge may end the empty wait
local function isFreshEdge(event)
  if type(event) ~= "table" then
    return false
  end
  if event.type == "confirm" or event.type == "cancel" or event.type == "activate" then
    return true
  end
  return event.type == "drag" and event.phase == "begin"
end

---@param events table<integer, table<string, unknown>> batch for one fixed update
---@return boolean whether the batch carries a fresh start edge
local function hasStart(events)
  for _, event in ipairs(events) do
    if type(event) == "table" and event.type == "start" then
      return true
    end
  end
  return false
end

---@param events table<integer, table<string, unknown>> batch for one fixed update
---@return table<string, unknown>? the cancel edge when present
local function findCancel(events)
  for _, event in ipairs(events) do
    if type(event) == "table" and event.type == "cancel" then
      return event
    end
  end
  return nil
end

---@param event table<string, unknown>
---@return boolean whether the event may change pages or close entries
local function consumesTransition(event)
  if type(event) ~= "table" then
    return false
  end
  if event.type == "navigate" or event.type == "confirm" or event.type == "menu" then
    return true
  end
  if event.type == "y" or event.type == "l" or event.type == "r" or event.type == "select" then
    return true
  end
  if event.type == "activate" then
    local action = event.action
    return action == "grid-slot"
      or action == "entry-tab"
      or action == "compare"
      or action == "compare-back"
      or action == "return-list"
      or action == "search-run"
      or action == "search-reset"
      or action == "editor-ok"
      or action == "editor-cancel"
  end
  return false
end

---@param events table<integer, table<string, unknown>>
---@param preparation { readyKey: integer }?
function PokedexController:updateFixed(events, preparation)
  if self._disposed == true then
    return
  end
  if type(events) ~= "table" then
    fail("browser updates consume an event batch", {})
  end
  local revision = tryDex(self._dex, "revision")
  if type(revision) == "number" and revision ~= self._revision then
    self:_rebuildFromKnowledge()
  end
  if self._feedback ~= nil and self._feedback.phase == "wait" then
    for _, event in ipairs(events) do
      if isFreshEdge(event) then
        self._feedback = nil
        self._page = "search"
        self:_bumpKey()
        return
      end
    end
  end
  local cancel = findCancel(events)
  if cancel ~= nil then
    self:_handleCancel()
    return
  end
  if self._closing == true then
    return
  end
  if self:_isReady(preparation) ~= true then
    -- A captured slider gesture is a lifetime event, not newly admitted
    -- navigation: its move/end/cancel settles the owned search
    -- transaction even while the bumped visual generation is pending.
    -- Every unrelated edge stays gated until readiness returns.
    local activeTarget = self._search:dragTarget()
    if activeTarget ~= nil then
      for _, event in ipairs(events) do
        if
          type(event) == "table"
          and event.type == "drag"
          and (event.phase == "move" or event.phase == "end" or event.phase == "cancel")
          and event.target == activeTarget
        then
          self:_handleDrag(event)
        end
      end
    end
    return
  end
  self:_advancePhases()
  if self._feedback ~= nil then
    return
  end
  if hasStart(events) then
    self:_handleStart()
    return
  end
  local transitionTaken = false
  for _, event in ipairs(events) do
    if type(event) ~= "table" then
      fail("browser events are records", {})
    end
    if event.type == "held" then
      self._held = { left = event.left == true, right = event.right == true, touch = event.touch == true }
      if event.left ~= true and event.right ~= true and event.touch ~= true then
        self._search:resetOpCount()
      end
    elseif event.type == "drag" then
      self:_handleDrag(event)
    elseif consumesTransition(event) and transitionTaken == true then
      -- At most one navigation or transition per batch; later edges drop.
    else
      if consumesTransition(event) then
        transitionTaken = true
      end
      self:_handleEvent(event)
    end
  end
end

function PokedexController:_handleCancel()
  if self._feedback ~= nil then
    return
  end
  if self._closing == true then
    return
  end
  if self._page == "cover" or self._page == "grid" then
    self._closing = true
    self._transition = { phase = "close", tick = 0 }
    self:_emitResume()
    self._result = { kind = "close" }
    self:_bumpKey()
    return
  end
  if self._page == "search" then
    if self._search:isEditorOpen() then
      self._search:closeEditor(false)
      self:_bumpKey()
    else
      self._page = "grid"
      self:_bumpKey()
    end
    return
  end
  if self._page == "results" then
    self._page = "grid"
    self:_restoreSelection(self._resumeSelection)
    self:_bumpKey()
    return
  end
  if self._page == "forms" and self._forms ~= nil and self._forms:comparison() ~= nil then
    self._forms:closeComparison()
    self:_bumpKey()
    return
  end
  if self._page == "return" then
    self:_returnToOrigin()
    return
  end
  self:_returnToOrigin()
end

function PokedexController:_handleStart()
  if self._feedback ~= nil then
    return
  end
  if self._page == "cover" then
    self._page = "grid"
    self._coverOffset = 256
    self:_bumpKey()
    return
  end
  if self._page == "grid" then
    self._page = "cover"
    self._coverOffset = 0
    self:_bumpKey()
    return
  end
  if self._page ~= "search" then
    return
  end
  if self._search:isEditorOpen() then
    self._search:closeEditor(true)
    self:_bumpKey()
    self:_runSearch()
    return
  end
  self:_runSearch()
end

function PokedexController:_openSearch()
  self._search:reset()
  self._searchFocus = "order"
  self._search:setContext({
    mode = self._mode,
    profileName = self._profileName,
    nationalUnlocked = self._nationalUnlocked,
  })
  self._feedback = nil
  self._page = "search"
  self:_bumpKey()
end

function PokedexController:_runSearch()
  self._feedback = { phase = "label", tick = 0, wait = 0 }
  self:_emitSound("SEQ_SE_DP_Z_SEARCH")
  self:_bumpKey()
end

function PokedexController:_advanceFeedback()
  local feedback = self._feedback
  if feedback == nil then
    return
  end
  assert(type(feedback) == "table", "the browser reads its feedback sequence")
  feedback.tick = feedback.tick + 1
  if feedback.phase == "label" then
    if feedback.tick >= PokedexController.FEED_LABEL_TICKS then
      local list = self._search:run()
      if #list == 0 then
        self._feedback = { phase = "retract", tick = 0, wait = 0 }
      else
        self._feedback = { phase = "rise", tick = 0, wait = 0, list = list }
      end
    end
    return
  end
  if feedback.phase == "rise" then
    if feedback.tick >= PokedexController.FEED_RISE_TICKS then
      self._feedback = { phase = "hold", tick = 0, wait = 0, list = feedback.list }
    end
    return
  end
  if feedback.phase == "hold" then
    if feedback.tick >= PokedexController.FEED_HOLD_TICKS then
      self._feedback = { phase = "move", tick = 0, wait = 0, list = feedback.list }
    end
    return
  end
  if feedback.phase == "move" then
    if feedback.tick >= PokedexController.FEED_MOVE_TICKS then
      self._results = feedback.list or {}
      self._cursor = 0
      self._pageIndex = 0
      self._origin = "search"
      self._page = "results"
      self._feedback = nil
      self:_refreshResultsSelection()
      self:_bumpKey()
    end
    return
  end
  if feedback.phase == "retract" then
    if feedback.tick >= PokedexController.FEED_RETRACT_TICKS then
      self:_emitSound("SEQ_SE_DP_CUSTOM06")
      self._feedback = { phase = "wait", tick = 0, wait = 0 }
    end
    return
  end
  if feedback.phase == "wait" then
    feedback.wait = feedback.wait + 1
    if feedback.wait >= PokedexController.FEED_TIMEOUT_TICKS then
      self._feedback = nil
      self._page = "search"
      self:_bumpKey()
    end
  end
end

-- Reads the controller's current area-region state into the pan region:
-- kanto only while national travel is unlocked, johto otherwise. Kept in
-- one helper so region switches, entry opens, and per-tick updates agree.
function PokedexController:_syncAreaPanRegion()
  local region = 0
  if self._area ~= nil then
    local area = self._area:view()
    if area.region == "kanto" and self._nationalUnlocked == true then
      region = 1
    end
  end
  self._areaPanRegion = region
end

---@param region string viewed map region
function PokedexController:_setAreaRegion(region)
  if self._area == nil then
    return
  end
  self._area:setRegion(region)
  self:_syncAreaPanRegion()
end

-- Eases the area scroll eight pixels per fixed update toward the settled
-- position of the currently viewed region. The renderer only reads the
-- published offset; it never advances the travel itself.
function PokedexController:_advanceAreaPan()
  self:_syncAreaPanRegion()
  local target = PokedexController.AREA_PAN_JOHTO
  if self._areaPanRegion == 1 then
    target = PokedexController.AREA_PAN_KANTO
  end
  local offset = self._areaPanOffset
  if offset < target then
    offset = math.min(offset + PokedexController.AREA_PAN_STEP, target)
  elseif offset > target then
    offset = math.max(offset - PokedexController.AREA_PAN_STEP, target)
  end
  self._areaPanOffset = offset
end

-- The accepted source clock behind live sprite intents: bumped once per
-- accepted fixed update, never on projections or draws. A feedback phase
-- change installs new animation art, so it advances the demand key while
-- pure animation ticks keep the key quiet.
function PokedexController:_advancePhases()
  self._spriteTick = self._spriteTick + 1
  if self._feedback ~= nil then
    local phase = self._feedback.phase
    self:_advanceFeedback()
    local next = self._feedback ~= nil and self._feedback.phase or nil
    if next ~= phase then
      self:_bumpKey()
    end
  end
  self:_advanceAreaPan()
  if self._area ~= nil and (self._page == "area" or self._page == "size" or self._page == "forms") then
    self._area:update()
  end
  if self._size ~= nil and self._page == "size" then
    self._size:update()
    local sound = self._size:takeSound()
    if sound ~= nil then
      self:_emitSound(sound)
    end
  end
  self._search:tick()
end

---@param event table<string, unknown>
function PokedexController:_handleDrag(event)
  local target = event.target
  local phase = event.phase
  local value = event.value
  if target == "cover" then
    if phase == "begin" then
      self._coverDrag = { from = type(value) == "number" and value or 0, preOffset = self._coverOffset }
    elseif phase == "move" and self._coverDrag ~= nil then
      if type(value) == "number" then
        if value < 0 then
          value = 0
        end
        if value > 256 then
          value = 256
        end
        self._coverOffset = math.floor(value) --[[@as integer]]
      end
    elseif phase == "end" and self._coverDrag ~= nil then
      local from = self._coverDrag.from
      self._coverDrag = nil
      if type(value) ~= "number" then
        return
      end
      if from <= 128 then
        if value >= 64 then
          self._page = "grid"
          self._coverOffset = 256
        else
          self._page = "cover"
          self._coverOffset = 0
        end
      else
        if value >= 192 then
          self._page = "grid"
          self._coverOffset = 256
        else
          self._page = "cover"
          self._coverOffset = 0
        end
      end
      self:_bumpKey()
    elseif (phase == "cancel" or phase == "end") and self._coverDrag ~= nil then
      self._coverOffset = self._coverDrag.preOffset
      self._coverDrag = nil
    end
    return
  end
  if target == "height-min" or target == "height-max" or target == "weight-min" or target == "weight-max" then
    -- Only the captured endpoint moves: a continuation naming any other
    -- endpoint is stale and must neither mutate the bound nor clear the
    -- owned transaction.
    if target ~= self._search:dragTarget() and phase ~= "begin" then
      return
    end
    local criterion = "height"
    if target == "weight-min" or target == "weight-max" then
      criterion = "weight"
    end
    local endpoint = "min"
    if target == "height-max" or target == "weight-max" then
      endpoint = "max"
    end
    if phase == "begin" then
      if type(value) ~= "number" then
        fail("browser drags carry positions", {})
      end
      self._search:beginDrag(criterion, endpoint, math.floor(value))
      self:_bumpKey()
    elseif phase == "move" then
      if self._search:isDragging() and type(value) == "number" then
        self._search:moveDrag(math.floor(value))
      end
    elseif phase == "end" then
      self._search:endDrag(true)
      self:_bumpKey()
    elseif phase == "cancel" then
      self._search:cancelDrag()
      self:_bumpKey()
    end
    return
  end
  if target == "grid-scroll" or target == "area-scroll" or target == "forms-scroll" then
    if phase ~= "end" or type(value) ~= "number" then
      return
    end
    local fraction = value
    if fraction < 0 then
      fraction = 0
    end
    if fraction > 1 then
      fraction = 1
    end
    if target == "grid-scroll" and (self._page == "grid" or self._page == "results") then
      local lastPage = self:_gridLastPage()
      if self._page == "results" then
        lastPage = self:_resultsLastPage()
      end
      self._pageIndex = math.floor(fraction * (lastPage + 1))
      if self._pageIndex > lastPage then
        self._pageIndex = lastPage
      end
      if self._page == "grid" then
        self:_refreshGridSelection()
      else
        self:_refreshResultsSelection()
      end
      self:_bumpKey()
    elseif target == "area-scroll" and self._page == "area" and self._area ~= nil then
      local count = self._area:rowCount()
      if count > 0 then
        self._area:goRow(math.floor(fraction * count))
      end
    elseif target == "forms-scroll" and self._page == "forms" and self._forms ~= nil then
      local count = self._forms:count()
      if count > 0 then
        self._forms:goRow(math.floor(fraction * count))
        self:_bumpKey()
      end
    end
  end
end

---@param event table<string, unknown>
function PokedexController:_handleEvent(event)
  if self._feedback ~= nil then
    if self._feedback.phase == "wait" and isFreshEdge(event) then
      self._feedback = nil
      self._page = "search"
      self:_bumpKey()
    end
    return
  end
  if self._page == "cover" then
    self:_handleCover(event)
  elseif self._page == "grid" then
    self:_handleGrid(event)
  elseif self._page == "search" then
    self:_handleSearch(event)
  elseif self._page == "results" then
    self:_handleResults(event)
  elseif self._page == "area" then
    self:_handleArea(event)
  elseif self._page == "size" then
    self:_handleSize(event)
  elseif self._page == "forms" then
    self:_handleForms(event)
  elseif self._page == "return" then
    self:_handleReturn(event)
  end
end

---@param event table<string, unknown>
function PokedexController:_handleCover(event)
  if event.type == "confirm" then
    self._page = "grid"
    self._coverOffset = 256
    self:_bumpKey()
  elseif event.type == "navigate" then
    if event.direction == "left" then
      if self._nationalUnlocked == true and self._mode ~= "national" then
        self._mode = "national"
        self:_reconcileModeSelection()
        self:_bumpKey()
      end
    elseif event.direction == "right" then
      if self._mode ~= "johto" then
        self._mode = "johto"
        self:_reconcileModeSelection()
        self:_bumpKey()
      end
    end
  elseif event.type == "y" then
    self:_openSearch()
  elseif event.type == "activate" and event.action == "mode" then
    if event.value == "national" and self._nationalUnlocked == true then
      self._mode = "national"
      self:_reconcileModeSelection()
      self:_bumpKey()
    elseif event.value == "johto" then
      self._mode = "johto"
      self:_reconcileModeSelection()
      self:_bumpKey()
    end
  end
end

---@param delta integer
function PokedexController:_moveGridCursor(delta)
  local total = (self:_gridLastPage() + 1) * PokedexController.RESULT_SLOTS
  local absolute = self._pageIndex * PokedexController.RESULT_SLOTS + self._cursor
  absolute = (absolute + delta) % total
  self._pageIndex = math.floor(absolute / PokedexController.RESULT_SLOTS)
  self._cursor = absolute % PokedexController.RESULT_SLOTS
  self:_refreshGridSelection()
  self:_bumpKey()
end

---@param event table<string, unknown>
function PokedexController:_handleGrid(event)
  if event.type == "navigate" then
    if event.direction == "left" then
      self:_moveGridCursor(-1)
    elseif event.direction == "right" then
      self:_moveGridCursor(1)
    elseif event.direction == "up" then
      self:_moveGridCursor(-5)
    elseif event.direction == "down" then
      self:_moveGridCursor(5)
    end
  elseif event.type == "confirm" then
    local species = self:_gridSlotSpecies(self._pageIndex * PokedexController.RESULT_SLOTS + self._cursor)
    if species ~= nil then
      self:_select(species)
      self._originGrid = { page = self._pageIndex, cursor = self._cursor }
      self:_openEntry(species, "grid")
    end
  elseif event.type == "menu" then
    local species = self:_gridSlotSpecies(self._pageIndex * PokedexController.RESULT_SLOTS + self._cursor)
    if species ~= nil then
      self:_emitCry(species, self:_cryForm(species))
    end
  elseif event.type == "y" then
    self:_openSearch()
  elseif event.type == "select" then
    self:_cycleLanguage()
  elseif event.type == "l" then
    if self._pageIndex > 0 then
      self._pageIndex = self._pageIndex - 1
      self:_refreshGridSelection()
      self:_bumpKey()
    end
  elseif event.type == "r" then
    local lastPage = self:_gridLastPage()
    if self._pageIndex < lastPage then
      self._pageIndex = self._pageIndex + 1
      self:_refreshGridSelection()
      self:_bumpKey()
    end
  elseif event.type == "activate" then
    self:_handleGridActivate(event)
  end
end

---@param event table<string, unknown>
function PokedexController:_handleGridActivate(event)
  if event.action == "grid-slot" then
    local slot = event.value
    if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 or slot > PokedexController.RESULT_SLOTS - 1 then
      return
    end
    if slot == self._cursor then
      local species = self:_gridSlotSpecies(self._pageIndex * PokedexController.RESULT_SLOTS + self._cursor)
      if species ~= nil then
        self:_select(species)
        self._originGrid = { page = self._pageIndex, cursor = self._cursor }
        self:_openEntry(species, "grid")
      end
    else
      self._cursor = math.floor(slot) --[[@as integer]]
      self:_refreshGridSelection()
      self:_bumpKey()
    end
  elseif event.action == "entry-tab" then
    local species = self:_gridSlotSpecies(self._pageIndex * PokedexController.RESULT_SLOTS + self._cursor)
    if species == nil then
      return
    end
    self:_select(species)
    self._originGrid = { page = self._pageIndex, cursor = self._cursor }
    self:_openEntry(species, "grid")
    self:_switchEntryTab(event.value)
  elseif event.action == "cry" then
    local species = self:_gridSlotSpecies(self._pageIndex * PokedexController.RESULT_SLOTS + self._cursor)
    if species ~= nil then
      self:_emitCry(species, self:_cryForm(species))
    end
  elseif event.action == "language" then
    self:_cycleLanguage()
  elseif event.action == "search" then
    self:_openSearch()
  elseif event.action == "cover" then
    self._page = "cover"
    self._coverOffset = 0
    self:_bumpKey()
  elseif event.action == "page-next" then
    local lastPage = self:_gridLastPage()
    if self._pageIndex < lastPage then
      self._pageIndex = self._pageIndex + 1
      self:_refreshGridSelection()
      self:_bumpKey()
    end
  elseif event.action == "page-prev" then
    if self._pageIndex > 0 then
      self._pageIndex = self._pageIndex - 1
      self:_refreshGridSelection()
      self:_bumpKey()
    end
  end
end

function PokedexController:_cycleLanguage()
  local species = self._selection.species
  if type(species) ~= "string" or self._selection.seen ~= true then
    return
  end
  local current = self._selection.language
  if type(current) ~= "string" then
    current = self._nativeLanguage
  end
  local position = 1
  for index, key in ipairs(PokedexController.LANGUAGE_ORDER) do
    if key == current then
      position = index
    end
  end
  local count = #PokedexController.LANGUAGE_ORDER
  for step = 1, count do
    local candidate = PokedexController.LANGUAGE_ORDER[(position + step - 1) % count + 1]
    if candidate == self._nativeLanguage or self:_languageAcquired(species, candidate) then
      if candidate ~= current then
        self._selection.language = candidate
        self:_bumpKey()
      end
      return
    end
  end
end

---@param direction string navigate direction
---@return integer focus step across the search graph
local function searchFocusStep(direction)
  if direction == "up" or direction == "left" then
    return -1
  end
  return 1
end

---@param delta integer signed focus step
function PokedexController:_moveSearchFocus(delta)
  local index = 1
  for position, name in ipairs(SEARCH_FOCUSABLES) do
    if name == self._searchFocus then
      index = position
    end
  end
  index = (index + delta - 1) % #SEARCH_FOCUSABLES + 1
  self._searchFocus = SEARCH_FOCUSABLES[index]
  self:_bumpKey()
end

-- Moves the open editor focus one step without staging anything: option
-- editors walk their projected option list, skipping the locked Kanto
-- scope, while slider editors switch endpoint on up/down.
---@param delta integer signed focus step
---@param direction string navigate direction
function PokedexController:_moveEditorFocus(delta, direction)
  local editor = self._search:editorView()
  if editor == nil then
    return
  end
  local kind = editor.criterion
  if kind == "height" or kind == "weight" then
    if direction == "up" then
      self._search:setSliderEndpoint("min")
      self:_bumpKey()
    elseif direction == "down" then
      self._search:setSliderEndpoint("max")
      self:_bumpKey()
    elseif direction == "left" or direction == "right" then
      local endpoint = editor.endpoint
      if endpoint ~= "min" and endpoint ~= "max" then
        endpoint = "min"
      end
      self._search:stepSlider(kind, endpoint, searchFocusStep(direction))
      self:_bumpKey()
    end
    return
  end
  local options = self._search:editorOptions(kind)
  if #options == 0 then
    return
  end
  local index = 1
  for position, option in ipairs(options) do
    if option == editor.focus then
      index = position
    end
  end
  for _ = 1, #options do
    index = (index + delta - 1) % #options + 1
    local choice = options[index]
    if choice ~= "kanto" or kind ~= "area" or self._nationalUnlocked == true then
      self._search:focusOption(choice)
      self:_bumpKey()
      return
    end
  end
end

function PokedexController:_confirmSearchFocus()
  local focus = self._searchFocus
  if focus == "run" then
    self:_runSearch()
    return
  end
  if focus == "reset" then
    self._search:reset()
    self:_bumpKey()
    return
  end
  self._search:openEditor(focus)
  self:_bumpKey()
end

---@param event table<string, unknown>
function PokedexController:_handleSearch(event)
  if self._search:isEditorOpen() then
    self:_handleEditor(event)
    return
  end
  if event.type == "navigate" then
    self:_moveSearchFocus(searchFocusStep(event.direction))
  elseif event.type == "confirm" then
    self:_confirmSearchFocus()
  elseif event.type == "activate" and event.action == "criterion" then
    if type(event.value) == "string" then
      local known = false
      for _, name in ipairs(SEARCH_FOCUSABLES) do
        if name == event.value then
          known = true
        end
      end
      if known then
        self._searchFocus = event.value
        self._search:openEditor(event.value)
        self:_bumpKey()
      end
    end
  elseif event.type == "activate" and (event.action == "search-run" or event.action == "editor-ok") then
    self:_runSearch()
  elseif event.type == "activate" and event.action == "search-reset" then
    self._search:reset()
    self:_bumpKey()
  end
end

---@param event table<string, unknown>
function PokedexController:_handleEditor(event)
  local editor = self._search:editorView()
  if editor == nil then
    return
  end
  local kind = editor.criterion
  if event.type == "navigate" then
    self:_moveEditorFocus(searchFocusStep(event.direction), event.direction)
    return
  end
  if event.type == "confirm" then
    if kind == "height" or kind == "weight" then
      self._search:closeEditor(true)
      self:_bumpKey()
    else
      local focus = editor.focus
      if type(focus) == "string" then
        self._search:choose(focus)
        self:_bumpKey()
      end
    end
    return
  end
  if event.type == "activate" and event.action == "editor-choice" then
    if type(event.value) == "string" then
      self._search:choose(event.value)
      self:_bumpKey()
    end
  elseif event.type == "activate" and event.action == "slider-step" then
    self._search:stepSlider(event.criterion, event.endpoint, event.direction)
    self:_bumpKey()
  elseif event.type == "activate" and event.action == "editor-ok" then
    self._search:closeEditor(true)
    self:_bumpKey()
  elseif event.type == "activate" and event.action == "editor-cancel" then
    self._search:closeEditor(false)
    self:_bumpKey()
  end
end

---@param delta integer
function PokedexController:_moveResultsCursor(delta)
  local total = (self:_resultsLastPage() + 1) * PokedexController.RESULT_SLOTS
  local absolute = self._pageIndex * PokedexController.RESULT_SLOTS + self._cursor
  absolute = (absolute + delta) % total
  self._pageIndex = math.floor(absolute / PokedexController.RESULT_SLOTS)
  self._cursor = absolute % PokedexController.RESULT_SLOTS
  self:_refreshResultsSelection()
  self:_bumpKey()
end

---@param event table<string, unknown>
function PokedexController:_handleResults(event)
  if event.type == "navigate" then
    if event.direction == "left" then
      self:_moveResultsCursor(-1)
    elseif event.direction == "right" then
      self:_moveResultsCursor(1)
    elseif event.direction == "up" then
      self:_moveResultsCursor(-5)
    elseif event.direction == "down" then
      self:_moveResultsCursor(5)
    end
  elseif event.type == "confirm" then
    self:_activateResultsSlot()
  elseif event.type == "menu" then
    if self:_isSearchReturnSlot() ~= true then
      local key = self._results[self._pageIndex * PokedexController.RESULT_SLOTS + self._cursor]
      if type(key) == "string" then
        self:_emitCry(key, self:_cryForm(key))
      end
    end
  elseif event.type == "y" then
    self._page = "search"
    self:_bumpKey()
  elseif event.type == "l" then
    if self._pageIndex > 0 then
      self._pageIndex = self._pageIndex - 1
      self:_refreshResultsSelection()
      self:_bumpKey()
    end
  elseif event.type == "r" then
    local lastPage = self:_resultsLastPage()
    if self._pageIndex < lastPage then
      self._pageIndex = self._pageIndex + 1
      self:_refreshResultsSelection()
      self:_bumpKey()
    end
  elseif event.type == "activate" then
    if event.action == "grid-slot" and type(event.value) == "number" then
      local slot = event.value
      if slot >= 0 and slot < PokedexController.RESULT_SLOTS and slot % 1 == 0 then
        self._cursor = slot
        self:_refreshResultsSelection()
        self:_activateResultsSlot()
        self:_bumpKey()
      end
    end
  end
end

function PokedexController:_activateResultsSlot()
  if self:_isSearchReturnSlot() then
    self._page = "search"
    self:_bumpKey()
    return
  end
  local key = self._results[self._pageIndex * PokedexController.RESULT_SLOTS + self._cursor]
  if type(key) ~= "string" then
    return
  end
  self._originResults = {
    list = self._results,
    cursor = self._cursor,
    page = self._pageIndex,
  }
  self:_select(key)
  self:_openEntry(key, "results")
end

---@param event table<string, unknown>
function PokedexController:_handleArea(event)
  if self._area == nil then
    return
  end
  if event.type == "confirm" then
    self._area:cycleTime()
    self:_bumpKey()
  elseif event.type == "select" then
    if self._area:view().region == "johto" then
      self:_setAreaRegion("kanto")
    else
      self:_setAreaRegion("johto")
    end
    self:_bumpKey()
  elseif event.type == "l" then
    self:_setAreaRegion("johto")
    self:_bumpKey()
  elseif event.type == "r" then
    self:_setAreaRegion("kanto")
    self:_bumpKey()
  elseif event.type == "navigate" then
    if event.direction == "up" then
      if self._area:moveRow(-1) then
        self:_bumpKey()
      end
    elseif event.direction == "down" then
      if self._area:moveRow(1) then
        self:_bumpKey()
      end
    elseif event.direction == "left" or event.direction == "right" then
      self:_cycleEntryTab(event.direction == "left" and -1 or 1)
    end
  elseif event.type == "activate" then
    if event.action == "area-time" then
      self._area:setTime(event.value)
      self:_bumpKey()
    elseif event.action == "area-region" then
      self:_setAreaRegion(event.value)
      self:_bumpKey()
    elseif event.action == "area-row" then
      if self._area:goRow(event.value) then
        self:_bumpKey()
      end
    elseif event.action == "entry-tab" then
      self:_switchEntryTab(event.value)
    elseif event.action == "compare-back" then
      self:_returnToOrigin()
    end
  end
end

---@param event table<string, unknown>
function PokedexController:_handleSize(event)
  if event.type == "confirm" then
    if self._size ~= nil and self._size:isMoving() then
      self._size:restart()
    end
  elseif event.type == "navigate" then
    if event.direction == "left" or event.direction == "right" then
      self:_cycleEntryTab(event.direction == "left" and -1 or 1)
    end
  elseif event.type == "activate" then
    if event.action == "size-restart" then
      if self._size ~= nil and self._size:isMoving() then
        self._size:restart()
      end
    elseif event.action == "entry-tab" then
      self:_switchEntryTab(event.value)
    elseif event.action == "compare-back" then
      self:_returnToOrigin()
    end
  end
end

---@param event table<string, unknown>
function PokedexController:_handleForms(event)
  if self._forms == nil then
    return
  end
  if self._forms:comparison() ~= nil then
    self:_handleComparison(event)
    return
  end
  if event.type == "navigate" then
    if event.direction == "up" then
      if self._forms:moveRow(-1) then
        self:_bumpKey()
      end
    elseif event.direction == "down" then
      if self._forms:moveRow(1) then
        self:_bumpKey()
      end
    elseif event.direction == "left" or event.direction == "right" then
      self:_cycleEntryTab(event.direction == "left" and -1 or 1)
    end
  elseif event.type == "activate" then
    if event.action == "forms-row" then
      self._forms:goRow(event.value)
      self:_bumpKey()
    elseif event.action == "compare" then
      if self._forms:openComparison() then
        self:_bumpKey()
      end
    elseif event.action == "entry-tab" then
      self:_switchEntryTab(event.value)
    elseif event.action == "compare-back" then
      self:_returnToOrigin()
    end
  end
end

---@param event table<string, unknown>
function PokedexController:_handleComparison(event)
  if self._forms == nil then
    return
  end
  if event.type == "confirm" then
    self._forms:closeComparison()
    self:_bumpKey()
  elseif event.type == "menu" then
    self._forms:flip()
    self:_bumpKey()
  elseif event.type == "navigate" then
    local comparison = self._forms:comparison()
    local active = 0
    if comparison ~= nil and comparison.activeSide == 1 then
      active = 1
    end
    if event.direction == "up" then
      self._forms:cycle(active, -1)
    elseif event.direction == "down" then
      self._forms:cycle(active, 1)
    elseif event.direction == "left" then
      self._forms:setActiveSide(1)
    elseif event.direction == "right" then
      self._forms:setActiveSide(0)
    end
    self:_bumpKey()
  elseif event.type == "activate" then
    if event.action == "compare-flip" then
      self._forms:flip()
      self:_bumpKey()
    elseif event.action == "compare-side" then
      self._forms:setActiveSide(event.value)
      self:_bumpKey()
    elseif event.action == "compare-cycle" then
      self._forms:cycle(event.side, event.delta)
      self:_bumpKey()
    elseif event.action == "compare-back" then
      self._forms:closeComparison()
      self:_bumpKey()
    elseif event.action == "entry-tab" then
      self._forms:closeComparison()
      self:_switchEntryTab(event.value)
    end
  end
end

---@param event table<string, unknown>
function PokedexController:_handleReturn(event)
  if event.type == "confirm" then
    self:_returnToOrigin()
  elseif event.type == "navigate" then
    if event.direction == "left" then
      self._page = "forms"
      self:_bumpKey()
    elseif event.direction == "right" then
      self._page = "area"
      self:_bumpKey()
    end
  elseif event.type == "activate" then
    if event.action == "return-list" then
      self:_returnToOrigin()
    elseif event.action == "entry-tab" then
      self:_switchEntryTab(event.value)
    end
  end
end

---@param tab string?
function PokedexController:_switchEntryTab(tab)
  if type(self._entrySpecies) ~= "string" then
    return
  end
  if tab == "area" then
    self._page = "area"
    self:_bumpKey()
  elseif tab == "size" then
    if self._size ~= nil then
      self._page = "size"
      self:_bumpKey()
    end
  elseif tab == "forms" then
    self._page = "forms"
    self:_bumpKey()
  elseif tab == "return" then
    self._page = "return"
    self:_bumpKey()
  end
end

---@param direction integer -1 or 1 tab cycle
function PokedexController:_cycleEntryTab(direction)
  local tabs = { "area", "size", "forms", "return" }
  local current = 1
  for index, name in ipairs(tabs) do
    if name == self._page then
      current = index
    end
  end
  for _ = 1, #tabs do
    current = (current + direction - 1) % #tabs + 1
    local candidate = tabs[current]
    if candidate ~= "size" or self._size ~= nil then
      self:_switchEntryTab(candidate)
      return
    end
  end
end

---@param form integer resolved physical form
---@param gender string picture gender
---@param personality integer picture personality
---@return { species: string?, form: integer, gender: string, personality: integer, language: string, isEgg: boolean, shiny: boolean } detached semantic specimen for one picture
function PokedexController:_specimen(form, gender, personality)
  return {
    species = self._entrySpecies,
    form = form,
    gender = gender,
    personality = personality,
    language = self._selection.language,
    isEgg = false,
    shiny = false,
  }
end

---@return { slot: integer, specimen: table<string, unknown>, facing: string, mode: string }[] picture slots for the open entry
function PokedexController:_entryPictures()
  local pictures = {}
  if type(self._entrySpecies) ~= "string" or self._forms == nil then
    return pictures
  end
  local mode = "silhouette"
  if self._selection.caught == true then
    mode = "portrait"
  end
  if self._forms:comparison() ~= nil then
    local comparison = self._forms:comparison()
    if comparison ~= nil then
      local variants = self._forms:variants()
      local facing = comparison.facing
      local facePersonality = 0
      if facing == "front" then
        local firstPersonality = tryDex(self._dex, "firstPersonality", self._entrySpecies)
        if type(firstPersonality) == "number" then
          facePersonality = firstPersonality
        end
      end
      for side = 0, 1 do
        local variant = variants[comparison.indices[side + 1] + 1]
        if variant ~= nil then
          pictures[#pictures + 1] = {
            slot = side,
            specimen = self:_specimen(variant.form, variant.gender, facePersonality),
            facing = facing,
            mode = mode,
          }
        end
      end
      return pictures
    end
  end
  local facts = self._forms:currentPictureFacts()
  pictures[#pictures + 1] = {
    slot = 0,
    specimen = self:_specimen(facts.form, facts.gender, facts.frontPersonality),
    facing = "front",
    mode = mode,
  }
  pictures[#pictures + 1] = {
    slot = 1,
    specimen = self:_specimen(facts.form, facts.gender, facts.backPersonality),
    facing = "back",
    mode = mode,
  }
  return pictures
end

---@param number integer dex number in the active order
---@return string zero-padded display digits
local function padNumber(number)
  return string.format("%03d", number)
end

-- Ordered search criteria behind the native criteria root. The editor
-- projection names its criterion under either spelling; both resolve to
-- the same contracted slots.
local SEARCH_CRITERIA = { "order", "letter", "type", "height", "weight", "area", "shape" }

---@param controller PokedexController browser controller under construction of its text slots
---@return table<string, unknown> bound search text bindings
local function searchTextBindings(controller)
  local catalog = controller._catalog
  if type(catalog) ~= "table" then
    fail("search text needs its generated catalog", {})
  end
  assert(type(catalog) == "table", "search text reads its generated catalog")
  return checkTable(catalog.searchText, "search text bindings")
end

---@param records table<string, integer> bound message ids by option key
---@param key string? staged option key
---@param what string attribution behind the lookup
---@return integer bound source message identity
local function searchMessageId(records, key, what)
  if type(records) ~= "table" then
    fail("search text names no " .. what .. " table", {})
  end
  local id = type(key) == "string" and records[key] or nil
  if type(id) ~= "number" then
    fail("search text names no " .. what, { key = key })
  end
  assert(type(id) == "number", "search text binds its message")
  return id
end

-- Lenient variant for catalog-driven type keys: a synthetic catalog may
-- stage a key with no native bank entry, in which case there is no
-- source-backed label and the caller skips the slot instead of failing
-- the whole page. Real catalogs only carry native keys.
---@param records table<string, integer>? bound message ids by option key
---@param key string? staged option key
---@return integer? bound source message identity, or nil without a native entry
local function searchMessageIdOrNil(records, key)
  if type(records) ~= "table" then
    return nil
  end
  local id = type(key) == "string" and records[key] or nil
  if type(id) ~= "number" then
    return nil
  end
  return id
end

---@param slots table[] detached semantic text slot requests under construction
---@param role string contracted window role
---@param messageId integer source UI bank entry
---@param language string selected game language key
local function appendUiSlot(slots, role, messageId, language)
  slots[#slots + 1] = { role = role, kind = "ui", messageId = messageId, language = language }
end

---@param slots table[] detached semantic text slot requests under construction
---@param selection { species: string?, dexNumber: integer?, seen: boolean, caught: boolean, language: string } live browser selection record
local function appendHighlightedIdentity(slots, selection)
  if selection.seen == true and type(selection.species) == "string" and type(selection.dexNumber) == "number" then
    slots[#slots + 1] = { role = "grid.selected-number", kind = "numeric", value = padNumber(selection.dexNumber) }
    slots[#slots + 1] = {
      role = "grid.selected-name",
      kind = "species_name",
      species = selection.species,
      language = selection.language,
    }
  end
end

-- Bounded selected-detail family for the adapted inspector: number and
-- name for seen-only highlights, plus the caught-protected category,
-- flavor, height, and weight once caught. Unseen slots publish nothing.
---@param controller PokedexController browser controller under construction of its text slots
---@param slots table[] detached semantic text slot requests under construction
local function appendCompactDetails(controller, slots)
  local selection = controller._selection
  if selection.seen ~= true or type(selection.species) ~= "string" then
    return
  end
  if type(selection.dexNumber) == "number" then
    slots[#slots + 1] = { role = "compact.detail-number", kind = "numeric", value = padNumber(selection.dexNumber) }
  end
  slots[#slots + 1] = {
    role = "compact.detail-name",
    kind = "species_name",
    species = selection.species,
    language = selection.language,
  }
  if selection.caught ~= true then
    return
  end
  slots[#slots + 1] = {
    role = "compact.detail-category",
    kind = "category",
    species = selection.species,
    language = selection.language,
  }
  slots[#slots + 1] =
    { role = "compact.detail-flavor", kind = "flavor", species = selection.species, language = selection.language }
  slots[#slots + 1] = { role = "compact.detail-height", kind = "height", species = selection.species }
  slots[#slots + 1] = { role = "compact.detail-weight", kind = "weight", species = selection.species }
end

-- Compact-only inspector close caption: the BACK word behind the close
-- toggle on every page, so a carried-open overlay never draws an
-- unlabeled control. The id is an already-bound bank-802 entry
-- reached through the existing kind="ui" path.
---@param controller PokedexController browser controller under construction of its text slots
---@param slots table[] detached semantic text slot requests under construction
local function appendCompactClose(controller, slots)
  local searchText = searchTextBindings(controller)
  appendUiSlot(slots, "compact.action-back", searchText.buttons.back, controller._nativeLanguage)
end

-- Compact-only action captions for the grid/results footer: the SEARCH
-- word and the return-to-title word behind the cover/search buttons.
-- Every id is an already-bound bank-802 entry reached through the
-- existing kind="ui" path, so no producer or schema change is needed.
---@param controller PokedexController browser controller under construction of its text slots
---@param slots table[] detached semantic text slot requests under construction
local function appendCompactListActions(controller, slots)
  local searchText = searchTextBindings(controller)
  local language = controller._nativeLanguage
  appendUiSlot(slots, "compact.action-search", searchText.buttons.run, language)
  appendUiSlot(slots, "compact.action-cover", searchText.returnCancel, language)
end

---@param controller PokedexController browser controller under construction of its text slots
---@return table<string, unknown> bound entry-page text bindings
local function entryTextBindings(controller)
  local catalog = controller._catalog
  if type(catalog) ~= "table" then
    fail("entry text needs its generated catalog", {})
  end
  assert(type(catalog) == "table", "entry text reads its generated catalog")
  return checkTable(catalog.entryText, "entry text bindings")
end

---@param controller PokedexController browser controller under construction of its text slots
---@return table<string, unknown> bound form-name policy bindings
local function formNameBindings(controller)
  local catalog = controller._catalog
  if type(catalog) ~= "table" then
    fail("form names need their generated catalog", {})
  end
  assert(type(catalog) == "table", "form names read their generated catalog")
  return checkTable(catalog.formNames, "form name bindings")
end

-- Species-specific form-name message behind one list/compare row,
-- transcribed from the native form-name policy: fixed Unown names, the
-- Shellos/Gastrodon, Burmy/Wormadam, Deoxys, Shaymin, Giratina, Rotom,
-- Castform and Cherrim runs indexed by form id, the Pichu mapping, the
-- gendered male/female rows, and the generic species-named entry. A
-- form id outside its native run fails instead of inventing a label,
-- and a raw numeric index is never shown.
---@param formNames table<string, unknown> bound form-name policy bindings
---@param species string entry species key
---@param variant { form: integer, gender: string } visible list variant
---@return integer bound source UI message identity
---@return boolean whether the message names the species through the native field
local function formNameMessageId(formNames, species, variant)
  local fixed = type(formNames.fixed) == "table" and formNames.fixed[species] or nil
  if type(fixed) == "number" then
    ---@cast fixed integer
    return fixed, false
  end
  if species == "PICHU" then
    local pichu = checkTable(formNames.pichu, "pichu form names")
    local entry = pichu[variant.form]
    if type(entry) == "number" then
      ---@cast entry integer
      return entry, false
    end
    return searchMessageId({ other = pichu.other }, "other", "pichu form"), false
  end
  local base = type(formNames.base) == "table" and formNames.base[species] or nil
  if type(base) == "number" then
    local count = type(formNames.count) == "table" and formNames.count[species] or nil
    if type(count) ~= "number" or variant.form < 0 or variant.form >= count then
      fail("form names cover no such variant", { species = species, form = variant.form })
    end
    assert(type(count) == "number", "form names bound their run length")
    ---@cast base integer
    return base + variant.form, false
  end
  if variant.gender == "male" then
    return searchMessageId(formNames, "male", "gendered form"), false
  end
  if variant.gender == "female" then
    return searchMessageId(formNames, "female", "gendered form"), false
  end
  return searchMessageId(formNames, "generic", "gendered form"), true
end

-- One form-name row behind a list, selected, or compare slot: plain UI
-- bank entries resolve directly while the generic species-named entry
-- travels as a species-templated slot for preparation to expand.
---@param slots table[] detached semantic text slot requests under construction
---@param role string contracted window role
---@param species string entry species key
---@param variant { form: integer, gender: string } visible list variant
---@param language string selected game language key
---@param formNames table<string, unknown> bound form-name policy bindings
local function appendFormNameSlot(slots, role, species, variant, language, formNames)
  local messageId, namesSpecies = formNameMessageId(formNames, species, variant)
  if namesSpecies then
    slots[#slots + 1] =
      { role = role, kind = "named_ui", messageId = messageId, species = species, language = language }
    return
  end
  appendUiSlot(slots, role, messageId, language)
end

-- Shared staged search values behind a role prefix: the menu prefix
-- paints the main-screen value windows while the summary prefix paints
-- the return-slot recap on the results screen from the same staged
-- criteria and message bindings.
---@param controller PokedexController browser controller under construction of its text slots
---@param slots table[] detached semantic text slot requests under construction
---@param prefix string window role prefix behind the staged values
local function appendStagedValueSlots(controller, slots, prefix)
  local searchText = searchTextBindings(controller)
  local language = controller._nativeLanguage
  local criteria = controller._search:criteria()
  appendUiSlot(slots, prefix .. "order", searchMessageId(searchText.orders, criteria.order, "sort"), language)
  local letterKey = type(criteria.letter) == "string" and criteria.letter:upper() or "unrestricted"
  appendUiSlot(slots, prefix .. "letter", searchMessageId(searchText.letters, letterKey, "letter"), language)
  local typeGroup = searchText.types
  for index, valueRole in ipairs({ prefix .. "type-1", prefix .. "type-2" }) do
    local staged = index == 1 and criteria.type1 or criteria.type2
    local typeId = searchMessageIdOrNil(typeGroup, staged or "unrestricted")
    if typeId ~= nil then
      appendUiSlot(slots, valueRole, typeId, language)
    end
  end
  for _, measure in ipairs({ "height", "weight" }) do
    local bounds = criteria[measure]
    assert(type(bounds) == "table", "search reads its slider bounds")
    slots[#slots + 1] = { role = prefix .. measure .. "-min", kind = "numeric", value = tostring(bounds.min) }
    slots[#slots + 1] = { role = prefix .. measure .. "-max", kind = "numeric", value = tostring(bounds.max) }
  end
  appendUiSlot(
    slots,
    prefix .. "area",
    searchMessageId(searchText.areas, criteria.area or "unrestricted", "area scope"),
    language
  )
end

-- One option row per editor choice: six sorts, 27 letter marks, the
-- catalog type set with its empty mark, area scopes honoring their
-- enabled flags, and integer slider bounds stay with the value slots.
---@param controller PokedexController browser controller under construction of its text slots
---@param slots table[] detached semantic text slot requests under construction
---@param kind string open editor criterion
---@param language string selected game language key
---@param searchText table<string, unknown> bound search text bindings
local function appendEditorOptions(controller, slots, kind, language, searchText)
  local enabled = nil
  local editor = controller._search:editorView()
  if kind == "area" and type(editor) == "table" and type(editor.choices) == "table" then
    local areaChoices = editor.choices.area
    if type(areaChoices) == "table" then
      enabled = {}
      for name, record in pairs(areaChoices) do
        if type(record) == "table" and record.enabled == true then
          enabled[name] = true
        end
      end
    end
  end
  local group = searchText[kind .. "s"]
  for _, option in ipairs(controller._search:editorOptions(kind)) do
    if enabled ~= nil and enabled[option] ~= true then
      -- A disabled scope keeps its blank native window.
    elseif kind == "type" then
      local optionId = searchMessageIdOrNil(type(group) == "table" and group or nil, option)
      if optionId ~= nil then
        appendUiSlot(slots, "search.option-" .. kind .. "-" .. option, optionId, language)
      end
    else
      appendUiSlot(slots, "search.option-" .. kind .. "-" .. option, searchMessageId(group, option, kind), language)
    end
  end
end

-- Source-backed search text: menu captions with staged values and
-- run/reset/back on the root; each editor carries its own title and
-- current-value windows plus one option row per choice and the commit
-- buttons. The shape editor publishes its title and buttons only: the
-- source prints no option labels and the silhouettes are sprite art.
-- Disabled scopes (the Kanto scope before the national unlock) publish
-- no label, matching the blank native window.
---@param controller PokedexController browser controller under construction of its text slots
---@param slots table[] detached semantic text slot requests under construction
local function appendSearchSlots(controller, slots)
  local searchText = searchTextBindings(controller)
  local language = controller._nativeLanguage
  local criteria = controller._search:criteria()
  local editor = controller._search:editorView()
  if editor == nil then
    for _, name in ipairs(SEARCH_CRITERIA) do
      appendUiSlot(slots, "search.caption-" .. name, searchMessageId(searchText.criteria, name, "caption"), language)
    end
    appendStagedValueSlots(controller, slots, "search.value-")
    appendUiSlot(slots, "search.button-run", searchMessageId(searchText.buttons, "run", "button"), language)
    appendUiSlot(slots, "search.button-reset", searchMessageId(searchText.buttons, "reset", "button"), language)
    appendUiSlot(slots, "search.button-back", searchMessageId(searchText.buttons, "back", "button"), language)
    return
  end
  local kind = editor.criterion
  if type(kind) ~= "string" then
    kind = editor.kind
  end
  assert(type(kind) == "string", "search editors name their criterion")
  appendUiSlot(slots, "search.title-" .. kind, searchMessageId(searchText.criteria, kind, "caption"), language)
  if kind == "height" or kind == "weight" then
    local bounds = criteria[kind]
    assert(type(bounds) == "table", "search reads its slider bounds")
    slots[#slots + 1] = { role = "search.current-" .. kind .. "-min", kind = "numeric", value = tostring(bounds.min) }
    slots[#slots + 1] = { role = "search.current-" .. kind .. "-max", kind = "numeric", value = tostring(bounds.max) }
  elseif kind == "type" then
    local typeGroup = searchText.types
    local current1 = searchMessageIdOrNil(typeGroup, criteria.type1 or "unrestricted")
    if current1 ~= nil then
      appendUiSlot(slots, "search.current-type-1", current1, language)
    end
    local current2 = searchMessageIdOrNil(typeGroup, criteria.type2 or "unrestricted")
    if current2 ~= nil then
      appendUiSlot(slots, "search.current-type-2", current2, language)
    end
    appendEditorOptions(controller, slots, kind, language, searchText)
  elseif kind == "area" then
    appendUiSlot(
      slots,
      "search.current-area",
      searchMessageId(searchText.areas, criteria.area or "unrestricted", "area scope"),
      language
    )
    appendEditorOptions(controller, slots, kind, language, searchText)
  elseif kind ~= "shape" then
    if kind == "letter" then
      local letterKey = type(criteria.letter) == "string" and criteria.letter:upper() or "unrestricted"
      appendUiSlot(slots, "search.current-letter", searchMessageId(searchText.letters, letterKey, "letter"), language)
    elseif kind == "order" then
      appendUiSlot(slots, "search.current-order", searchMessageId(searchText.orders, criteria.order, "sort"), language)
    end
    appendEditorOptions(controller, slots, kind, language, searchText)
  end
  appendUiSlot(slots, "search.button-ok", searchMessageId(searchText.editorButtons, "ok", "button"), language)
  appendUiSlot(slots, "search.button-cancel", searchMessageId(searchText.editorButtons, "cancel", "button"), language)
end

-- The six visible area rows around the list cursor: the region row
-- names the viewed region while habitat rows resolve their landmark
-- names through the compiled map-section bindings. Positions outside the
-- list stay unpublished so their windows stay blank; a habitat row with
-- no compiled name binding fails instead of inventing a label.
---@param controller PokedexController browser controller under construction of its text slots
---@param slots table[] detached semantic text slot requests under construction
---@param entryText table<string, unknown> bound entry-page text bindings
---@param areaView { row: integer, region: string, rows: { kind: string, mapKey: string? }[] } detached area projection
local function appendAreaRows(controller, slots, entryText, areaView)
  local language = controller._nativeLanguage
  local geometry = checkTable(controller._catalog.areaGeometry, "area geometry")
  for position = 1, 6 do
    local row = areaView.rows[areaView.row + position - 2]
    if row ~= nil then
      local role = position == 1 and "area.location" or "area.row-" .. position
      if row.kind == "all" then
        if areaView.region == "johto" then
          appendUiSlot(slots, role, entryText.areaRegionJohto, language)
        elseif areaView.region == "kanto" then
          appendUiSlot(slots, role, entryText.areaRegionKanto, language)
        else
          fail("area text names a known region", { region = areaView.region })
        end
      else
        local record = geometry[row.mapKey]
        if type(record) ~= "table" then
          fail("area text names a mapped habitat row", { mapKey = row.mapKey })
        end
        assert(type(record) == "table", "area rows read their compiled geometry")
        local name = record.name
        if type(name) ~= "table" or name.bankId == 0 then
          fail("area text names a mapped habitat row", { mapKey = row.mapKey })
        end
        assert(type(name.bankId) == "number", "area names bind their bank")
        assert(type(name.messageId) == "number", "area names bind their entry")
        slots[#slots + 1] = { role = role, kind = "area_name", bankId = name.bankId, messageId = name.messageId }
      end
    end
  end
end

-- Area screen text: title, daypart, region tabs, the unknown banner when
-- the list holds only the region entry, and the six scrolled rows.
---@param controller PokedexController browser controller under construction of its text slots
---@param slots table[] detached semantic text slot requests under construction
---@param entryText table<string, unknown> bound entry-page text bindings
local function appendAreaSlots(controller, slots, entryText)
  local area = controller._area
  assert(area ~= nil, "area text reads the open area helper")
  local areaView = area:view()
  if type(areaView.time) ~= "number" or areaView.time < 0 or areaView.time > 2 then
    fail("area text names a known daypart", { time = areaView.time })
  end
  assert(type(areaView.region) == "string", "area reads its viewed region")
  local searchText = searchTextBindings(controller)
  local language = controller._nativeLanguage
  appendUiSlot(slots, "area.title", entryText.areaTitle, language)
  slots[#slots + 1] = {
    role = "area.time",
    kind = "ui",
    messageId = searchText.timeBase + areaView.time,
    language = language,
  }
  appendUiSlot(slots, "area.caption", entryText.areaCaption, language)
  if controller._nationalUnlocked == true then
    appendUiSlot(slots, "area.tab-johto", searchText.areas.johto, language)
    appendUiSlot(slots, "area.tab-kanto", searchText.areas.kanto, language)
  else
    appendUiSlot(slots, "area.tab-johto-solo", searchText.areas.johto, language)
  end
  if #areaView.rows <= 1 then
    appendUiSlot(slots, "area.unknown", entryText.areaUnknown, language)
  end
  appendAreaRows(controller, slots, entryText, areaView)
end

-- Size screen text: title, species and trainer names, height/weight
-- captions, unit marks and trainer-gender words. Measurements stay
-- with the caught-gated entry slots; seen-only pages leave them blank.
---@param controller PokedexController browser controller under construction of its text slots
---@param slots table[] detached semantic text slot requests under construction
---@param entryText table<string, unknown> bound entry-page text bindings
---@param species string entry species key
---@param language string selected game language key
local function appendSizeSlots(controller, slots, entryText, species, language)
  local native = controller._nativeLanguage
  appendUiSlot(slots, "size.title", entryText.sizeTitle, native)
  slots[#slots + 1] = { role = "size.species-name", kind = "species_name", species = species, language = language }
  if type(controller._playerName) == "string" and controller._playerName ~= "" then
    slots[#slots + 1] = { role = "size.player-name", kind = "player_name", value = controller._playerName }
  end
  appendUiSlot(slots, "size.caption-height", entryText.sizeCaptionHeight, native)
  appendUiSlot(slots, "size.mark-height-left", entryText.sizeMarkHeight, native)
  appendUiSlot(slots, "size.mark-height-right", entryText.sizeMarkHeight, native)
  if controller._playerGender == "male" then
    appendUiSlot(slots, "size.gender-height", entryText.sizeMaleHeight, native)
  else
    appendUiSlot(slots, "size.gender-height", entryText.sizeFemaleHeight, native)
  end
  appendUiSlot(slots, "size.caption-weight", entryText.sizeCaptionWeight, native)
  appendUiSlot(slots, "size.mark-weight-left", entryText.sizeMarkWeight, native)
  appendUiSlot(slots, "size.mark-weight-right", entryText.sizeMarkWeight, native)
  if controller._playerGender == "male" then
    appendUiSlot(slots, "size.gender-weight", entryText.sizeMaleWeight, native)
  else
    appendUiSlot(slots, "size.gender-weight", entryText.sizeFemaleWeight, native)
  end
  if tryDex(controller._dex, "isCaught", species) == true then
    slots[#slots + 1] = { role = "size.species-weight", kind = "weight", species = species }
  end
end

-- Forms screen text: title, species header, selected form name and the
-- six visible form rows around the cursor, plus the multi-form caption.
-- The compare pairing replaces the list with both compared names and
-- labels on both sides.
---@param controller PokedexController browser controller under construction of its text slots
---@param slots table[] detached semantic text slot requests under construction
---@param entryText table<string, unknown> bound entry-page text bindings
---@param formNames table<string, unknown> bound form-name policy bindings
---@param species string entry species key
---@param language string selected game language key
local function appendFormsSlots(controller, slots, entryText, formNames, species, language)
  local forms = controller._forms
  assert(forms ~= nil, "forms text reads the open forms helper")
  local formsView = forms:view()
  local native = controller._nativeLanguage
  appendUiSlot(slots, "forms.title", entryText.formsTitle, native)
  local comparison = formsView.comparison
  if comparison ~= nil then
    slots[#slots + 1] = {
      role = "forms.compare-header",
      kind = "named_ui",
      messageId = entryText.formsCompareHeader,
      species = species,
      language = language,
    }
    appendUiSlot(slots, "forms.compare-caption", entryText.formsTitle, native)
    appendUiSlot(slots, "forms.compare-label-left", entryText.formsCompareLeft, native)
    appendUiSlot(slots, "forms.compare-label-right", entryText.formsCompareRight, native)
    local indices = comparison.indices
    assert(type(indices) == "table", "forms comparisons pair two variants")
    for side = 1, 2 do
      local variant = formsView.variants[indices[side] + 1]
      if variant == nil then
        fail("forms comparisons pair known variants", { side = side })
      end
      assert(type(variant) == "table", "forms comparisons pair known variants")
      local role = side == 1 and "forms.compare-left" or "forms.compare-right"
      appendFormNameSlot(slots, role, species, variant, language, formNames)
    end
    return
  end
  slots[#slots + 1] = {
    role = "forms.header",
    kind = "named_ui",
    messageId = entryText.formsHeader,
    species = species,
    language = language,
  }
  local selected = formsView.variants[formsView.row + 1]
  if selected == nil then
    fail("forms text names the selected variant", { species = species })
  end
  assert(type(selected) == "table", "forms text names the selected variant")
  appendFormNameSlot(slots, "forms.selected", species, selected, language, formNames)
  if #formsView.variants > 1 then
    appendUiSlot(slots, "forms.caption", entryText.formsCaption, native)
  end
  for position = 1, 6 do
    local variant = formsView.variants[formsView.row + position - 2]
    if variant ~= nil then
      appendFormNameSlot(slots, "forms.row-" .. position, species, variant, language, formNames)
    end
  end
end

-- Detached semantic text requests for the visible page: counts, the
-- regional selection identity, source-backed search captions/values and
-- per-editor options, area daypart/region, return actions, the selected
-- form name, bounded selected-detail strings, and the open specimen
-- facts the prepared renderer resolves through its message banks. Only
-- fact-derived slots with a verified source message reference are
-- published here, so preparation never fetches an invented bank entry.
---@return table[] detached semantic text slot requests for the visible page
function PokedexController:_textSlots()
  local slots = {}
  if self._page == "cover" then
    local coverText = searchTextBindings(self)
    local coverLanguage = self._nativeLanguage
    appendUiSlot(slots, "compact.action-search", coverText.buttons.run, coverLanguage)
    appendUiSlot(slots, "compact.action-open", coverText.returnAction, coverLanguage)
    appendCompactClose(self, slots)
  elseif self._page == "grid" then
    local seen = tryDex(self._dex, "countSeen", self._mode)
    local caught = tryDex(self._dex, "countCaught", self._mode)
    slots[#slots + 1] =
      { role = "grid.seen-count", kind = "numeric", value = tostring(type(seen) == "number" and seen or 0) }
    slots[#slots + 1] = {
      role = "grid.caught-count",
      kind = "numeric",
      value = tostring(type(caught) == "number" and caught or 0),
    }
    appendHighlightedIdentity(slots, self._selection)
    appendCompactDetails(self, slots)
    appendCompactListActions(self, slots)
    appendCompactClose(self, slots)
  elseif self._page == "search" then
    -- The feedback count follows the native result-count template (bank
    -- 802 entry 15, field 0 bound to the completed count, shown while
    -- the results rise). While the count is unknown the slot stays
    -- unpublished and its window stays absent, never a raw marker.
    if self._feedback ~= nil and self._feedback.list ~= nil then
      slots[#slots + 1] = {
        role = "search.feedback",
        kind = "ui",
        messageId = 15,
        fields = { [0] = padNumber(#self._feedback.list) },
        language = self._nativeLanguage,
      }
    end
    appendSearchSlots(self, slots)
    appendCompactClose(self, slots)
  elseif self._page == "results" then
    slots[#slots + 1] = { role = "search.results", kind = "numeric", value = tostring(#self._results) }
    appendHighlightedIdentity(slots, self._selection)
    appendCompactDetails(self, slots)
    appendCompactListActions(self, slots)
    appendCompactClose(self, slots)
    -- The leading return slot shows the criteria recap the species
    -- highlight replaces: same staged values in the summary rects.
    if self._selection.species == nil then
      local summaryText = searchTextBindings(self)
      local summaryLanguage = self._nativeLanguage
      for _, name in ipairs(SEARCH_CRITERIA) do
        appendUiSlot(
          slots,
          "search.summary-caption-" .. name,
          searchMessageId(summaryText.criteria, name, "caption"),
          summaryLanguage
        )
      end
      appendStagedValueSlots(self, slots, "search.summary-value-")
    end
  elseif self._page == "area" or self._page == "size" or self._page == "forms" or self._page == "return" then
    local species = self._entrySpecies
    if type(species) == "string" and tryDex(self._dex, "isSeen", species) == true then
      local language = self._selection.language
      if type(language) ~= "string" then
        language = self._nativeLanguage
      end
      local dexNumber = self:_activeNumber(species)
      if type(dexNumber) == "number" then
        slots[#slots + 1] = { role = "entry.dex-number", kind = "numeric", value = padNumber(dexNumber) }
      end
      slots[#slots + 1] = { role = "entry.species-name", kind = "species_name", species = species, language = language }
      if tryDex(self._dex, "isCaught", species) == true then
        slots[#slots + 1] = { role = "entry.category", kind = "category", species = species, language = language }
        slots[#slots + 1] = { role = "entry.flavor", kind = "flavor", species = species, language = language }
        slots[#slots + 1] = { role = "entry.height", kind = "height", species = species }
        -- The size page paints weight through its own lower-pane window;
        -- the entry-page rect would overflow that screen.
        if self._page ~= "size" then
          slots[#slots + 1] = { role = "entry.weight", kind = "weight", species = species }
        end
      end
    end
    if self._page == "area" and self._area ~= nil then
      appendAreaSlots(self, slots, entryTextBindings(self))
    elseif self._page == "size" then
      local sizeSpecies = self._entrySpecies
      if type(sizeSpecies) == "string" then
        local sizeLanguage = self._selection.language
        if type(sizeLanguage) ~= "string" then
          sizeLanguage = self._nativeLanguage
        end
        appendSizeSlots(self, slots, entryTextBindings(self), sizeSpecies, sizeLanguage)
      end
    elseif self._page == "forms" and self._forms ~= nil then
      local formsSpecies = self._entrySpecies
      if type(formsSpecies) == "string" then
        local formsLanguage = self._selection.language
        if type(formsLanguage) ~= "string" then
          formsLanguage = self._nativeLanguage
        end
        appendFormsSlots(self, slots, entryTextBindings(self), formNameBindings(self), formsSpecies, formsLanguage)
      end
    elseif self._page == "return" then
      local searchText = searchTextBindings(self)
      appendUiSlot(slots, "return.title", searchText.returnCancel, self._nativeLanguage)
      appendUiSlot(slots, "return.action", searchText.returnAction, self._nativeLanguage)
    end
    local tabText = searchTextBindings(self)
    local tabEntry = entryTextBindings(self)
    local tabLanguage = self._nativeLanguage
    appendUiSlot(slots, "compact.tab-area", tabEntry.areaTitle, tabLanguage)
    appendUiSlot(slots, "compact.tab-size", tabEntry.sizeTitle, tabLanguage)
    appendUiSlot(slots, "compact.tab-forms", tabEntry.formsTitle, tabLanguage)
    appendUiSlot(slots, "compact.tab-return", tabText.returnCancel, tabLanguage)
    appendCompactClose(self, slots)
  end
  return slots
end

---@return { species: string?, dexNumber: integer?, seen: boolean, caught: boolean, language: string } detached selection snapshot
function PokedexController:_selectionView()
  local selection = self._selection
  if selection.species == nil then
    return { seen = false, caught = false, language = self._nativeLanguage }
  end
  return {
    species = selection.species,
    dexNumber = selection.dexNumber,
    seen = selection.seen == true,
    caught = selection.caught == true,
    language = selection.language,
  }
end

---@return { information: { first: string[], second: string[], eva: integer, evb: integer }, controls: { first: string[], second: string[], eva: integer, evb: integer } } information and controls blend policies
function PokedexController:_blendView()
  local information = { first = {}, second = {}, eva = 0, evb = 0 }
  local controls = { first = {}, second = { "bg0", "bg1", "bg2", "bg3" }, eva = 6, evb = 10 }
  if self._page == "area" and self._area ~= nil then
    local area = self._area:view()
    if area.phase == "refresh" then
      local q = area.refresh
      controls = { first = { "bg2" }, second = { "bg3" }, eva = 31 - q, evb = q }
    end
    information = { first = {}, second = { "bg0" }, eva = area.alpha, evb = 31 - area.alpha }
  end
  return { information = information, controls = controls }
end

-- Native area marker silhouettes: the twelve width/height pairs behind
-- shape selection (sPokedexAreaMarkerSizes in pokedex_rodata.s), kept
-- beside the shape projection so the player overlap test uses the exact
-- source extents without a producer round trip.
local AREA_MARKER_SIZES = {
  { 8, 8 },
  { 16, 8 },
  { 24, 8 },
  { 32, 8 },
  { 40, 8 },
  { 48, 8 },
  { 8, 16 },
  { 8, 24 },
  { 8, 32 },
  { 8, 40 },
  { 16, 16 },
  { 24, 16 },
}

-- Area scrollbar family: the source size steps over the row count with
-- the shared scrollbar lengths around center 96 on a track of 86
-- (sPokedexAreaScrollbarSizeSteps, sPokedexScrollbarLengths and the
-- SyncAreaScrollbar center/track in the pinned sources).
local AREA_SCROLL_THRESHOLDS = { 1, 4, 7, 10, 13, 16, 20, 24, 255 }
local AREA_SCROLL_LENGTHS = { 86, 78, 70, 62, 54, 46, 38, 30, 22 }
local AREA_SCROLL_CENTER = 96
local AREA_SCROLL_TRACK = 86

---@param objects table[] intent list under projection
---@param subject string semantic subject behind the intent
---@param choice string selected animation choice behind the intent
---@param pane string authored engine pane behind the intent
---@param x integer native horizontal origin behind the intent
---@param y integer native vertical origin behind the intent
---@param age integer accepted ticks since the choice was installed
---@param instance integer? repeated-marker index behind the intent
local function emitIntent(objects, subject, choice, pane, x, y, age, instance)
  local record = { subject = subject, choice = choice, pane = pane, x = x, y = y, age = age, visible = true }
  if instance ~= nil then
    record.instance = instance
  end
  objects[#objects + 1] = record
end

---@param pageKey integer demand generation behind the projection
---@param key string per-generation object identity
---@param choice string selected animation choice behind the object
---@return integer accepted ticks since the choice was installed
function PokedexController:_trackObjectAge(pageKey, key, choice)
  if self._objectPage ~= pageKey then
    self._objectAges = {}
    self._objectPage = pageKey
  end
  local slot = self._objectAges[key]
  if slot == nil or slot.choice ~= choice then
    slot = { choice = choice, since = self._spriteTick }
    self._objectAges[key] = slot
  end
  return self._spriteTick - slot.since
end

---@param thresholds integer[] ascending count thresholds behind the bucket
---@param count integer ranked count behind the bucket
---@return integer 1-based bucket position behind the count
local function bucketIndex(thresholds, count)
  for position, threshold in ipairs(thresholds) do
    if count <= threshold then
      return position
    end
  end
  return #thresholds
end

---@param species string selected species behind the art
---@return string[]? ordered type names behind the selected specimen
function PokedexController:_selectionTypes(species)
  local form = self:_cryForm(species)
  local okForm, formRecord = pcall(self._monCatalog.form, self._monCatalog, species, form)
  if okForm and type(formRecord) == "table" and type(formRecord.types) == "table" then
    return formRecord.types
  end
  local okSpecies, definition = pcall(self._monCatalog.species, self._monCatalog, species)
  if okSpecies and type(definition) == "table" and type(definition.types) == "table" then
    return definition.types
  end
  return nil
end

---@param mapKey string? habitat map key behind the marker
---@param kind string? habitat row kind behind the marker
---@return integer 0-based native marker shape behind the row
function PokedexController:_areaMarkerShape(mapKey, kind)
  if kind == "dungeon" then
    return 0
  end
  local geometry = self._catalog.areaGeometry
  if type(geometry) ~= "table" or type(mapKey) ~= "string" then
    return 0
  end
  local geo = geometry[mapKey]
  if type(geo) ~= "table" or geo.kind ~= "outdoor" or type(geo.rect) ~= "table" then
    return 0
  end
  local width, height = geo.rect.width, geo.rect.height
  if width == 1 then
    if height == 1 then
      return 0
    elseif height == 2 then
      return 6
    elseif height == 3 then
      return 7
    elseif height == 4 then
      return 8
    elseif height == 5 then
      return 9
    end
  elseif width == 2 then
    if height == 1 then
      return 1
    else
      return 10
    end
  elseif width == 3 then
    if height == 1 then
      return 2
    else
      return 11
    end
  elseif width == 4 then
    return 3
  elseif width == 5 then
    return 4
  elseif width == 6 then
    return 5
  end
  return 0
end

---@param objects table[] intent list under projection
---@param pageKey integer demand generation behind the projection
local function projectGridObjects(self, objects, pageKey)
  local function ageOf(key, choice)
    return self:_trackObjectAge(pageKey, key, choice)
  end
  local cursor = self._cursor
  emitIntent(
    objects,
    "cursor",
    "active",
    "controls",
    48 + 40 * (cursor % 5),
    24 + 40 * math.floor(cursor / 5),
    ageOf("cursor", "active")
  )
  local lastPage = self:_gridLastPage()
  local length = self:_sparseLength()
  if self._page == "results" then
    lastPage = self:_resultsLastPage()
    length = #self._results + 1
  end
  local upChoice = self._pageIndex > 0 and "enabled" or "disabled"
  local downChoice = self._pageIndex < lastPage and "enabled" or "disabled"
  emitIntent(objects, "arrow-up", upChoice, "controls", 242, 12, ageOf("arrow-up", upChoice))
  emitIntent(objects, "arrow-down", downChoice, "controls", 242, 140, ageOf("arrow-down", downChoice))
  local bucket = bucketIndex(PokedexController.SCROLL_THRESHOLDS, length)
  local scroll = self:_scrollbar(length, lastPage, self._pageIndex)
  emitIntent(
    objects,
    "scrollbar",
    "size" .. (bucket - 1),
    "controls",
    242,
    scroll.position,
    ageOf("scrollbar", "size" .. (bucket - 1))
  )
  local selection = self:_selectionView()
  if selection.caught == true and type(selection.species) == "string" then
    local species = selection.species
    local types = self:_selectionTypes(species)
    if type(types) == "table" and type(types[1]) == "string" then
      emitIntent(objects, "type-1", types[1], "information", 168, 72, ageOf("type-1", types[1]))
      if type(types[2]) == "string" and types[2] ~= types[1] then
        emitIntent(objects, "type-2", types[2], "information", 217, 72, ageOf("type-2", types[2]))
      end
    end
    local originHidden = species == "GIRATINA" and self:_cryForm(species) == 1
    if not originHidden then
      emitIntent(objects, "footprint", species, "information", 120, 80, ageOf("footprint", species))
    end
    emitIntent(objects, "caught-mark", "shown", "information", 112, 32, ageOf("caught-mark", "shown"))
  end
end

---@param value integer height decimetres behind the handle
---@return integer[] four decimal digits behind the height readout
local function heightDigits(value)
  local inches = value == 999 and 1188 or math.floor((10000 * value / 254 + 5) / 10)
  local feet = math.floor(inches / 12)
  local remainder = inches % 12
  return {
    feet >= 10 and math.floor(feet / 10) or nil,
    feet % 10,
    math.floor(remainder / 10),
    remainder % 10,
  }
end

---@param value integer weight hectograms behind the handle
---@return (integer?)[] five decimal digits behind the weight readout, nil for hidden leading zeroes
local function weightDigits(value)
  local shown = value == 9999 and 99990 or math.floor((value * 220462 + 50000) / 100000)
  local digits = {}
  local started, divisor = false, 10000
  for position = 1, 5 do
    local digit = math.floor(shown / divisor)
    if digit ~= 0 or started or position == 3 then
      started = true
      digits[position] = digit
    else
      digits[position] = nil
    end
    shown = shown % divisor
    divisor = math.floor(divisor / 10)
  end
  return digits
end

---@param bound integer slider bound behind the limit arrows
---@return string limit arrow choice behind the bound
local function limitChoice(bound)
  if bound == 0 then
    return "at-min"
  elseif bound == 152 then
    return "at-max"
  end
  return "mid"
end

---@param objects table[] intent list under projection
---@param pageKey integer demand generation behind the projection
---@param kind string height or weight editor kind behind the handles
---@param bounds { min: integer, max: integer } published slider bounds behind the handles
local function projectSliderObjects(self, objects, pageKey, kind, bounds)
  local function ageOf(key, choice)
    return self:_trackObjectAge(pageKey, key, choice)
  end
  local maxX = 52 + bounds.max
  local minX = 52 + bounds.min
  emitIntent(objects, "slider-cursor", "active", "controls", maxX, 16, ageOf("slider-cursor", "active"))
  emitIntent(objects, "slider-max", kind, "controls", maxX, 68, ageOf("slider-max", kind))
  emitIntent(objects, "slider-min", kind, "controls", minX, 132, ageOf("slider-min", kind))
  local maxDigits = kind == "height" and heightDigits(bounds.max) or weightDigits(bounds.max)
  local minDigits = kind == "height" and heightDigits(bounds.min) or weightDigits(bounds.min)
  local offsets = kind == "height" and { -20, -12, 4, 12 } or { -20, -12, -4, 4, 20 }
  for position, digit in ipairs(maxDigits) do
    if digit ~= nil then
      local key = "digit-max-" .. position
      emitIntent(objects, key, "d" .. digit, "controls", maxX + offsets[position], 64, ageOf(key, "d" .. digit))
    end
  end
  for position, digit in ipairs(minDigits) do
    if digit ~= nil then
      local key = "digit-min-" .. position
      emitIntent(objects, key, "d" .. digit, "controls", minX + offsets[position], 136, ageOf(key, "d" .. digit))
    end
  end
  local maxChoice, minChoice = limitChoice(bounds.max), limitChoice(bounds.min)
  emitIntent(objects, "limit-max-left", maxChoice, "controls", 18, 60, ageOf("limit-max-left", maxChoice))
  emitIntent(objects, "limit-max-right", maxChoice, "controls", 238, 60, ageOf("limit-max-right", maxChoice))
  emitIntent(objects, "limit-min-left", minChoice, "controls", 18, 132, ageOf("limit-min-left", minChoice))
  emitIntent(objects, "limit-min-right", minChoice, "controls", 238, 132, ageOf("limit-min-right", minChoice))
end

---@param objects table[] intent list under projection
---@param pageKey integer demand generation behind the projection
local function projectSearchObjects(self, objects, pageKey)
  if self._feedback ~= nil and self._feedback.phase ~= "wait" then
    local phase = self._feedback.phase
    local choice = phase == "label" and "label" or (phase == "retract" and "retract" or "rise")
    emitIntent(objects, "feedback", choice, "information", 128, 80, self:_trackObjectAge(pageKey, "feedback", choice))
  end
  local shape = self._search:criteria().shape
  if shape ~= nil then
    local editor = self._search:editorView()
    local onShapePage = type(editor) == "table" and editor.kind == "shape"
    local x, y = 224, 72
    if onShapePage then
      x, y = 152, 20
    end
    emitIntent(objects, "body-icon", shape, "controls", x, y, self:_trackObjectAge(pageKey, "body-icon", shape))
  end
  local editor = self._search:editorView()
  if type(editor) == "table" and (editor.kind == "height" or editor.kind == "weight") then
    local slider = editor.slider
    if type(slider) == "table" and type(slider.bounds) == "table" then
      projectSliderObjects(self, objects, pageKey, editor.kind, slider.bounds)
    end
  end
end

---@param area table<string, unknown> detached area projection behind the intents
---@return boolean whether the player stands inside a visible habitat marker
local function areaPlayerHit(self, area)
  local px, py = area.player.x * 8 + 68, area.player.y * 8 + 44
  local rows = area.rows
  local markers = area.markers
  for position = 2, #rows do
    local marker = markers[position - 1]
    local row = rows[position]
    if
      type(marker) == "table"
      and marker.visible == true
      and (area.row == 0 or area.row == position - 1)
      and type(row) == "table"
    then
      local shape = self:_areaMarkerShape(row.mapKey, row.kind)
      local size = AREA_MARKER_SIZES[shape + 1]
      if size ~= nil and type(marker.position) == "table" then
        local halfWidth, halfHeight = size[1] / 2, size[2] / 2
        if px >= marker.position.x - halfWidth and px < marker.position.x + halfWidth then
          if py >= marker.position.y - halfHeight and py < marker.position.y + halfHeight then
            return true
          end
        end
      end
    end
  end
  return false
end

---@param objects table[] intent list under projection
---@param pageKey integer demand generation behind the projection
---@param area table<string, unknown> detached area projection behind the intents
local function projectAreaObjects(self, objects, pageKey, area)
  local function ageOf(key, choice)
    return self:_trackObjectAge(pageKey, key, choice)
  end
  local gender = self._playerGender == "female" and "female" or "male"
  local choice = gender
  if areaPlayerHit(self, area) then
    choice = gender .. "-here"
  end
  local record = {
    subject = "player",
    choice = choice,
    pane = "information",
    x = area.player.x * 8 + 68,
    y = area.player.y * 8 + 44,
    age = ageOf("player", choice),
    visible = area.player.visible == true,
  }
  objects[#objects + 1] = record
  emitIntent(objects, "time-cursor", "active", "information", 32, 76 + 32 * area.time, ageOf("time-cursor", "active"))
  local instance = 0
  for position = 2, #area.rows do
    local marker = area.markers[position - 1]
    local row = area.rows[position]
    if type(marker) == "table" and type(row) == "table" and (area.row == 0 or area.row == position - 1) then
      instance = instance + 1
      local shape = self:_areaMarkerShape(row.mapKey, row.kind)
      local shapeChoice = "shape" .. shape
      local markerRecord = {
        subject = "marker",
        choice = shapeChoice,
        pane = "information",
        x = marker.position.x,
        y = marker.position.y,
        age = self:_trackObjectAge(pageKey, "marker-" .. instance, shapeChoice),
        visible = marker.visible == true,
        instance = instance,
      }
      objects[#objects + 1] = markerRecord
    end
  end
  local count = #area.rows
  local bucket = bucketIndex(AREA_SCROLL_THRESHOLDS, count)
  local length = AREA_SCROLL_LENGTHS[bucket]
  local half = math.floor(length / 2)
  local minY = AREA_SCROLL_CENTER - math.floor(AREA_SCROLL_TRACK / 2) + half
  local maxY = AREA_SCROLL_CENTER + math.floor(AREA_SCROLL_TRACK / 2) - half
  local y = maxY
  local last = count - 1
  if last > 0 and area.row ~= last then
    local step = math.floor((maxY - minY) * 256 / last)
    y = minY + math.floor(step * area.row / 256)
  end
  local scrollChoice = "size" .. (bucket - 1)
  emitIntent(objects, "scrollbar", scrollChoice, "controls", 242, y, ageOf("scrollbar", scrollChoice))
  local upChoice = area.row > 0 and "enabled" or "disabled"
  local downChoice = area.row < last and "enabled" or "disabled"
  emitIntent(objects, "arrow-up", upChoice, "controls", 242, 44, ageOf("arrow-up", upChoice))
  emitIntent(objects, "arrow-down", downChoice, "controls", 242, 148, ageOf("arrow-down", downChoice))
end

---@param objects table[] intent list under projection
---@param pageKey integer demand generation behind the projection
local function projectEntryObjects(self, objects, pageKey)
  local function ageOf(key, choice)
    return self:_trackObjectAge(pageKey, key, choice)
  end
  local tabIndex = 0
  if self._page == "size" then
    tabIndex = 1
  elseif self._page == "forms" then
    tabIndex = 2
  elseif self._page == "return" then
    tabIndex = 3
  end
  emitIntent(objects, "tab-cursor", "active", "controls", 32 + 64 * tabIndex, 176, ageOf("tab-cursor", "active"))
  if self._page == "area" and self._area ~= nil then
    projectAreaObjects(self, objects, pageKey, self._area:view())
  elseif self._page == "size" and self._size ~= nil then
    local size = self._size:view()
    if type(size.pans) == "table" and size.pans[1] ~= nil and size.pans[2] ~= nil then
      emitIntent(objects, "pan-left", "active", "controls", size.pans[1].x, size.pans[1].y, ageOf("pan-left", "active"))
      emitIntent(
        objects,
        "pan-right",
        "active",
        "controls",
        size.pans[2].x,
        size.pans[2].y,
        ageOf("pan-right", "active")
      )
    end
    emitIntent(objects, "beam-top", "active", "controls", 128, 104, ageOf("beam-top", "active"))
    emitIntent(objects, "beam-bottom", "active", "controls", 128, 104, ageOf("beam-bottom", "active"))
    local gender = self._playerGender == "female" and "female" or "male"
    local yOffset = 0
    if type(size.height) == "table" and type(size.height.trainer) == "table" then
      yOffset = size.height.trainer.yOffset or 0
    end
    emitIntent(objects, "trainer", gender, "information", 184, 112 + yOffset, ageOf("trainer", gender))
  elseif self._page == "forms" and self._forms ~= nil then
    local forms = self._forms:view()
    local comparison = self._forms:comparison()
    if comparison ~= nil then
      local variants = forms.variants
      if type(variants) == "table" and #variants >= 3 then
        local corners = {
          { choice = "tl", x = 64, y = 56 },
          { choice = "tr", x = 192, y = 56 },
          { choice = "bl", x = 64, y = 128 },
          { choice = "br", x = 192, y = 128 },
        }
        for _, corner in ipairs(corners) do
          emitIntent(
            objects,
            "compare-frame",
            corner.choice,
            "controls",
            corner.x,
            corner.y,
            ageOf("compare-frame-" .. corner.choice, corner.choice)
          )
        end
      end
      local side = comparison.activeSide == 0 and "left" or "right"
      emitIntent(
        objects,
        "compare-side",
        side,
        "controls",
        side == "left" and 64 or 192,
        88,
        ageOf("compare-side", side)
      )
    else
      local count = type(forms.variants) == "table" and #forms.variants or 0
      local bucket = bucketIndex(PokedexForms.SCROLLBAR_THRESHOLDS, count)
      local scrollChoice = "size" .. (bucket - 1)
      emitIntent(
        objects,
        "scrollbar",
        scrollChoice,
        "controls",
        242,
        forms.scrollbar.position,
        ageOf("scrollbar", scrollChoice)
      )
      local upChoice = forms.row > 0 and "enabled" or "disabled"
      local downChoice = forms.row < count - 1 and "enabled" or "disabled"
      emitIntent(objects, "arrow-up", upChoice, "controls", 242, 12, ageOf("arrow-up", upChoice))
      emitIntent(objects, "arrow-down", downChoice, "controls", 242, 116, ageOf("arrow-down", downChoice))
    end
  end
end

---@return { key: integer, mode: string, page: string, origin: string, selection: { species: string?, dexNumber: integer?, seen: boolean, caught: boolean, language: string }, counts: { seen: integer, caught: integer }, visual: { coverOffset: integer, barOffset: integer, paletteFades: table[], blend: table<string, unknown>, flash: table<string, unknown>, transition: table<string, unknown>, spriteTick: integer }, areaPan: { region: integer, offset: integer }, pictures: table[], text: table[], controls: table<string, unknown>, objects: table[]?, grid: table<string, unknown>?, search: table<string, unknown>?, area: table<string, unknown>?, size: table<string, unknown>?, forms: table<string, unknown>?, returnPanel: table<string, unknown>? } detached semantic snapshot for presentation
function PokedexController:view()
  local seen = tryDex(self._dex, "countSeen", self._mode)
  local caught = tryDex(self._dex, "countCaught", self._mode)
  local snapshot = {
    key = self._key,
    mode = self._mode,
    page = self._page,
    origin = self._origin,
    selection = self:_selectionView(),
    counts = {
      seen = type(seen) == "number" and seen or 0,
      caught = type(caught) == "number" and caught or 0,
    },
    visual = {
      coverOffset = self._coverOffset,
      barOffset = 0,
      paletteFades = {},
      blend = self:_blendView(),
      flash = { active = false, tick = 0 },
      transition = { phase = self._transition.phase, tick = self._transition.tick },
      spriteTick = self._spriteTick,
    },
    areaPan = { region = self._areaPanRegion, offset = self._areaPanOffset },
    pictures = {},
    controls = {},
  }
  if self._page == "grid" then
    snapshot.grid = {
      page = self._pageIndex,
      lastPage = self:_gridLastPage(),
      cursor = self._cursor,
      buffers = { self:_gridBuffer() },
      scrollbar = self:_scrollbar(self:_sparseLength(), self:_gridLastPage(), self._pageIndex),
    }
  elseif self._page == "search" then
    snapshot.search = {
      criteria = self._search:criteria(),
      focus = self._searchFocus,
      previousColumn = "criteria",
    }
    local editor = self._search:editorView()
    if editor ~= nil then
      local kind = editor.criterion
      if kind ~= "height" and kind ~= "weight" then
        editor.options = self._search:editorOptions(kind)
      end
      snapshot.search.editor = editor
      snapshot.search.focus = editor.focus
      snapshot.search.previousColumn = editor.previousColumn
    end
    local slider = self._search:sliderView()
    if slider ~= nil then
      snapshot.search.slider = slider
    end
    if self._feedback ~= nil then
      snapshot.search.feedback = {
        phase = self._feedback.phase,
        bodyTick = self._feedback.tick,
        labelTick = self._feedback.tick,
        holdTick = self._feedback.tick,
        offset = 0,
      }
    end
  elseif self._page == "results" then
    snapshot.grid = {
      page = self._pageIndex,
      lastPage = self:_resultsLastPage(),
      cursor = self._cursor,
      buffers = { self:_resultsBuffer() },
      scrollbar = self:_scrollbar(#self._results + 1, self:_resultsLastPage(), self._pageIndex),
    }
  elseif self._page == "area" and self._area ~= nil then
    snapshot.area = self._area:view()
    snapshot.pictures = self:_entryPictures()
  elseif self._page == "size" and self._size ~= nil then
    snapshot.size = self._size:view()
    snapshot.pictures = self:_entryPictures()
  elseif self._page == "forms" and self._forms ~= nil then
    snapshot.forms = self._forms:view()
    snapshot.pictures = self:_entryPictures()
  elseif self._page == "return" then
    snapshot.returnPanel = { focused = true }
    snapshot.pictures = self:_entryPictures()
  end
  snapshot.text = self:_textSlots()
  local objects = {}
  if self._page == "grid" or self._page == "results" then
    projectGridObjects(self, objects, self._key)
  elseif self._page == "search" then
    projectSearchObjects(self, objects, self._key)
  elseif self._page == "area" or self._page == "size" or self._page == "forms" or self._page == "return" then
    projectEntryObjects(self, objects, self._key)
  end
  if #objects > 0 then
    snapshot.objects = objects
  end
  return snapshot
end

---@return table[] pending one-shot effects, cleared on read
function PokedexController:drainEffects()
  local pending = self._effects
  self._effects = {}
  return pending
end

---@return { kind: string }? the one-use close result
function PokedexController:takeResult()
  local result = self._result
  self._result = nil
  return result
end

function PokedexController:cancelPointerCapture()
  self._search:cancelDrag()
  if self._coverDrag ~= nil then
    self._coverOffset = self._coverDrag.preOffset
    self._coverDrag = nil
  end
  self._held = { left = false, right = false, touch = false }
end

function PokedexController:dispose()
  if self._disposed == true then
    return
  end
  self._disposed = true
  self._effects = {}
  self._coverDrag = nil
  self._feedback = nil
  self._area = nil
  self._size = nil
  self._forms = nil
end

return PokedexController
