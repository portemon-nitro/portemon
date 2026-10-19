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

-- Scrollbar families: source thresholds map to authored thumb lengths.
PokedexController.SCROLL_THRESHOLDS = { 15, 45, 90, 135, 180, 225, 270, 315, 360, 405, 450, 495 }
PokedexController.SCROLL_LENGTHS = { 110, 102, 94, 86, 78, 70, 62, 54, 46, 38, 30, 22 }
PokedexController.SCROLL_TOP = 21
PokedexController.SCROLL_BOTTOM = 131

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

---@param args { catalog: table<string, unknown>, monCatalog: table<string, unknown>, dex: table<string, unknown>, playerGender: string, playerPosition: table<string, unknown>, nativeLanguage: string }
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
    _area = nil,
    _size = nil,
    _forms = nil,
    _entrySpecies = nil,
    _originGrid = { page = 0, cursor = 0 },
    _originResults = nil,
    _key = 1,
    _revision = 0,
    _effects = {},
    _result = nil,
    _closing = false,
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

---@param speciesKey string?
function PokedexController:_restoreSelection(speciesKey)
  local dex = self._dex
  local order = self._catalog.dexOrders.national
  assert(type(order) == "table", "the browser reads the national order")
  local target = nil
  if type(speciesKey) == "string" and tryDex(dex, "isSeen", speciesKey) == true then
    target = speciesKey
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
  local order = self._catalog.dexOrders.national
  assert(type(order) == "table", "the browser reads the national order")
  local dexNumber = nil
  for index, key in ipairs(order) do
    if key == speciesKey then
      dexNumber = index
    end
  end
  self._selection = { species = speciesKey, dexNumber = dexNumber, seen = true, caught = caught, language = language }
  self._resumeSelection = speciesKey
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

---@return integer highest seen national number, zero when empty
function PokedexController:_sparseLength()
  local order = self._catalog.dexOrders.national
  assert(type(order) == "table", "the browser reads the national order")
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
  local order = self._catalog.dexOrders.national
  assert(type(order) == "table", "the browser reads the national order")
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
          dexNumber = self:_nationalNumber(key),
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
---@return integer? national number
function PokedexController:_nationalNumber(speciesKey)
  local order = self._catalog.dexOrders.national
  assert(type(order) == "table", "the browser reads the national order")
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
  local order = self._catalog.dexOrders.national
  assert(type(order) == "table", "the browser reads the national order")
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
  if self._cursor == 0 then
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
      self:_select(selectionSpecies)
      local order = self._catalog.dexOrders.national
      assert(type(order) == "table", "the browser reads the national order")
      for index, key in ipairs(order) do
        if key == selectionSpecies then
          self._pageIndex = math.floor((index - 1) / PokedexController.RESULT_SLOTS)
          self._cursor = (index - 1) % PokedexController.RESULT_SLOTS
        end
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
  local cancel = findCancel(events)
  if cancel ~= nil then
    self:_handleCancel()
    return
  end
  if self._closing == true then
    return
  end
  if self:_isReady(preparation) ~= true then
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
    return
  end
  self:_runSearch()
end

function PokedexController:_openSearch()
  self._search:reset()
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

---@param event table<string, unknown> input edge record
---@return boolean whether a fresh edge may end the empty wait
local function isFreshEdge(event)
  if type(event) ~= "table" then
    return false
  end
  return event.type == "confirm" or event.type == "cancel" or event.type == "activate" or event.type == "drag"
end

function PokedexController:_advancePhases()
  if self._feedback ~= nil then
    self:_advanceFeedback()
  end
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
        self:_bumpKey()
      end
    elseif event.direction == "right" then
      if self._mode ~= "johto" then
        self._mode = "johto"
        self:_bumpKey()
      end
    end
  elseif event.type == "y" then
    self:_openSearch()
  elseif event.type == "activate" and event.action == "mode" then
    if event.value == "national" and self._nationalUnlocked == true then
      self._mode = "national"
      self:_bumpKey()
    elseif event.value == "johto" then
      self._mode = "johto"
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

---@param event table<string, unknown>
function PokedexController:_handleSearch(event)
  if self._search:isEditorOpen() then
    self:_handleEditor(event)
    return
  end
  if event.type == "navigate" then
    return
  elseif event.type == "activate" and event.action == "criterion" then
    if type(event.value) == "string" then
      self._search:openEditor(event.value)
      self:_bumpKey()
    end
  elseif event.type == "activate" and (event.action == "search-run" or event.action == "editor-ok") then
    self:_runSearch()
  end
end

---@param event table<string, unknown>
function PokedexController:_handleEditor(event)
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
    if self._cursor ~= 0 then
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
  if self._cursor == 0 then
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
      self._area:setRegion("kanto")
    else
      self._area:setRegion("johto")
    end
    self:_bumpKey()
  elseif event.type == "l" then
    self._area:setRegion("johto")
    self:_bumpKey()
  elseif event.type == "r" then
    self._area:setRegion("kanto")
    self:_bumpKey()
  elseif event.type == "navigate" then
    if event.direction == "up" then
      self._area:moveRow(-1)
    elseif event.direction == "down" then
      self._area:moveRow(1)
    elseif event.direction == "left" or event.direction == "right" then
      self:_cycleEntryTab(event.direction == "left" and -1 or 1)
    end
  elseif event.type == "activate" then
    if event.action == "area-time" then
      self._area:setTime(event.value)
      self:_bumpKey()
    elseif event.action == "area-region" then
      self._area:setRegion(event.value)
      self:_bumpKey()
    elseif event.action == "area-row" then
      self._area:goRow(event.value)
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
      self._forms:moveRow(-1)
    elseif event.direction == "down" then
      self._forms:moveRow(1)
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
  local tabs = { "area", "size", "forms" }
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
      for side = 0, 1 do
        local variant = variants[comparison.indices[side + 1] + 1]
        if variant ~= nil then
          pictures[#pictures + 1] = {
            slot = side * 2,
            specimen = self:_specimen(variant.form, variant.gender, 0),
            facing = "front",
            mode = mode,
          }
          pictures[#pictures + 1] = {
            slot = side * 2 + 1,
            specimen = self:_specimen(variant.form, variant.gender, 0),
            facing = "back",
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

---@return { key: integer, mode: string, page: string, origin: string, selection: { species: string?, dexNumber: integer?, seen: boolean, caught: boolean, language: string }, counts: { seen: integer, caught: integer }, visual: { coverOffset: integer, barOffset: integer, paletteFades: table[], blend: table<string, unknown>, flash: table<string, unknown>, transition: table<string, unknown> }, pictures: table[], text: table[], controls: table<string, unknown>, grid: table<string, unknown>?, search: table<string, unknown>?, area: table<string, unknown>?, size: table<string, unknown>?, forms: table<string, unknown>?, returnPanel: table<string, unknown>? } detached semantic snapshot for presentation
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
    },
    pictures = {},
    text = {},
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
      focus = "order",
      previousColumn = "criteria",
    }
    local editor = self._search:editorView()
    if editor ~= nil then
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
      snapshot.text = { { role = "message", messageId = 9, visible = true, language = self._nativeLanguage } }
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
