-- Ordered logical variants, the six-row list, comparison pairing and
-- cycling, and presentation-only fallback for one entry. Variants follow
-- observed arrival order without gender-by-form cross-products; automatic
-- families offer every declared form once known; historyless knowledge
-- falls back to one legal variant without persisting anything. Pure
-- policy over borrowed owners: no love, no I/O, no history writes.

local Errors = require("libs.errors.src.Errors")

---@class PokedexForms
---@field _catalog table<string, unknown> borrowed generated catalog
---@field _monCatalog table<string, unknown> borrowed resolved mon catalog
---@field _dex table<string, unknown> borrowed authoritative knowledge owner
---@field _species string entry species key
---@field _variants table[] ordered logical picture variants
---@field _row integer zero-based list cursor
---@field _comparison { indices: integer[], activeSide: integer, facing: string }? active comparison pairing
local PokedexForms = {}
PokedexForms.__index = PokedexForms

-- First count threshold at or above the list count selects its thumb.
PokedexForms.SCROLLBAR_THRESHOLDS = { 1, 4, 7, 10, 13, 16, 20, 24, 28 }
PokedexForms.SCROLLBAR_LENGTHS = { 86, 78, 70, 62, 54, 46, 38, 30, 22 }
PokedexForms.SCROLLBAR_CENTER = 64
PokedexForms.SCROLLBAR_TRACK = 86

local function fail(message, context)
  Errors.raise("POKEDEX_INVALID", message, context)
end

---@param value unknown
---@param what string
---@return table<string, unknown>
local function checkTable(value, what)
  if type(value) ~= "table" then
    fail("forms needs " .. what, {})
  end
  assert(type(value) == "table", "forms reads its borrowed state")
  return value
end

---@param ratio integer gender ratio
---@return boolean whether the male gender is reachable
local function maleReachable(ratio)
  return ratio ~= 255 and ratio ~= 254
end

---@param ratio integer gender ratio
---@return boolean whether the female gender is reachable
local function femaleReachable(ratio)
  return ratio ~= 255 and ratio ~= 0
end

---@param monCatalog table<string, unknown>
---@param speciesKey string
---@return integer gender ratio
local function genderRatioOf(monCatalog, speciesKey)
  local speciesOf = monCatalog.species
  if type(speciesOf) ~= "function" then
    fail("forms needs the resolved mon catalog", { species = speciesKey })
  end
  local ok, definition = pcall(speciesOf, monCatalog, speciesKey)
  if not ok or type(definition) ~= "table" then
    fail("forms names a species outside the resolved catalog", { species = speciesKey })
  end
  assert(type(definition) == "table", "forms reads the resolved species")
  local ratio = definition.genderRatio
  if type(ratio) ~= "number" or ratio % 1 ~= 0 or ratio < 0 or ratio > 255 then
    fail("forms names a species without a gender ratio", { species = speciesKey })
  end
  return ratio --[[@as integer]]
end

---@param args { catalog: table<string, unknown>, monCatalog: table<string, unknown>, dex: table<string, unknown>, species: string }
---@return PokedexForms
function PokedexForms.new(args)
  if type(args) ~= "table" then
    fail("forms needs a construction record", {})
  end
  assert(type(args) == "table", "forms reads its construction record")
  local catalog = checkTable(args.catalog, "the generated catalog")
  if type(args.monCatalog) ~= "table" then
    fail("forms needs the resolved mon catalog", {})
  end
  if type(args.dex) ~= "table" then
    fail("forms needs the knowledge owner", {})
  end
  if type(args.species) ~= "string" or args.species == "" then
    fail("forms names its entry species", {})
  end
  local self = setmetatable({
    _catalog = catalog,
    _monCatalog = args.monCatalog,
    _dex = args.dex,
    _species = args.species,
    _variants = {},
    _row = 0,
    _comparison = nil,
  }, PokedexForms)
  self:_build()
  return self
end

---@param dex table<string, unknown>
---@param key string
---@param method string
---@return unknown[] detached list copy
local function dexList(dex, key, method)
  local reader = dex[method]
  assert(type(reader) == "function", "forms reads knowledge through its owner")
  local list = reader(dex, key)
  assert(type(list) == "table", "forms reads the detached knowledge list")
  local out = {}
  for _, item in ipairs(list) do
    out[#out + 1] = item
  end
  return out
end

function PokedexForms:_build()
  local catalog = self._catalog
  assert(type(catalog) == "table", "forms reads its borrowed catalog")
  local speciesRecords = checkTable(catalog.species, "species records")
  local record = checkTable(speciesRecords[self._species], "the entry species record")
  local policy = checkTable(record.formPolicy, "the generated form policy")
  local dex = self._dex
  local ratio = genderRatioOf(self._monCatalog, self._species)
  local variants = {}
  if policy.kind == "automatic" then
    local entries = checkTable(policy.variants, "the declared variants")
    local seenReader = dex.isSeen
    local caughtReader = dex.isCaught
    assert(type(seenReader) == "function", "forms reads knowledge through its owner")
    assert(type(caughtReader) == "function", "forms reads knowledge through its owner")
    local known = seenReader(dex, self._species) == true or caughtReader(dex, self._species) == true
    if known == true then
      local genders = dexList(dex, self._species, "observedGenders")
      local pictureGender = genders[1]
      if pictureGender == nil then
        if maleReachable(ratio) then
          pictureGender = "male"
        elseif femaleReachable(ratio) then
          pictureGender = "female"
        else
          pictureGender = "genderless"
        end
      end
      for _, entry in ipairs(entries) do
        variants[#variants + 1] = { id = entry.id, form = entry.form, gender = pictureGender }
      end
    end
  elseif policy.kind == "ordered" then
    local entries = checkTable(policy.variants, "the declared variants")
    local byId = {}
    for _, entry in ipairs(entries) do
      byId[entry.id] = entry
    end
    local genders = dexList(dex, self._species, "observedGenders")
    local pictureGender = genders[1]
    if pictureGender == nil then
      if maleReachable(ratio) then
        pictureGender = "male"
      elseif femaleReachable(ratio) then
        pictureGender = "female"
      else
        pictureGender = "genderless"
      end
    end
    for _, id in ipairs(dexList(dex, self._species, "observedVariants")) do
      local entry = byId[id]
      if entry ~= nil then
        variants[#variants + 1] = { id = entry.id, form = entry.form, gender = entry.gender or pictureGender }
      end
    end
  else
    local entries = checkTable(policy.variants, "the declared variants")
    local defaultForm = 0
    if entries[1] ~= nil and type(entries[1].form) == "number" then
      defaultForm = entries[1].form
    end
    local defaultId = 0
    if entries[1] ~= nil and type(entries[1].id) == "number" then
      defaultId = entries[1].id
    end
    local genders = dexList(dex, self._species, "observedGenders")
    if ratio == 255 then
      variants[#variants + 1] = { id = defaultId, form = defaultForm, gender = "genderless" }
    else
      for _, gender in ipairs(genders) do
        variants[#variants + 1] = { id = defaultId, form = defaultForm, gender = gender }
      end
    end
  end
  if #variants == 0 then
    local seenReader = self._dex.isSeen
    local caughtReader = self._dex.isCaught
    assert(type(seenReader) == "function", "forms reads knowledge through its owner")
    assert(type(caughtReader) == "function", "forms reads knowledge through its owner")
    if seenReader(self._dex, self._species) == true or caughtReader(self._dex, self._species) == true then
      local entries = checkTable(policy.variants, "the declared variants")
      local first = entries[1]
      assert(type(first) == "table", "the form policy declares its variants")
      local fallbackGender = first.gender
      if fallbackGender == nil then
        if maleReachable(ratio) then
          fallbackGender = "male"
        elseif femaleReachable(ratio) then
          fallbackGender = "female"
        else
          fallbackGender = "genderless"
        end
      end
      variants[#variants + 1] = { id = first.id or 0, form = first.form or 0, gender = fallbackGender }
    end
  end
  self._variants = variants
  self._row = 0
  self._comparison = nil
end

---@return table[] detached ordered variants
function PokedexForms:variants()
  local out = {}
  for _, variant in ipairs(self._variants) do
    out[#out + 1] = { id = variant.id, form = variant.form, gender = variant.gender }
  end
  return out
end

---@return integer zero-based list cursor
function PokedexForms:row()
  return self._row
end

---@return integer variant count
function PokedexForms:count()
  return #self._variants
end

---@param row integer zero-based destination row
---@return boolean whether the destination was accepted
function PokedexForms:goRow(row)
  if type(row) ~= "number" or row % 1 ~= 0 then
    fail("forms rows are zero-based indexes", {})
  end
  if self._comparison ~= nil then
    return false
  end
  if row < 0 or row > #self._variants - 1 then
    return false
  end
  self._row = row
  return true
end

---@param delta integer -1 or 1
---@return boolean whether the move was accepted
function PokedexForms:moveRow(delta)
  if delta ~= 1 and delta ~= -1 then
    fail("forms rows move one row at a time", { delta = delta })
  end
  return self:goRow(self._row + delta)
end

---@return boolean whether comparison opened
function PokedexForms:openComparison()
  if #self._variants < 2 then
    return false
  end
  local other = nil
  for index in ipairs(self._variants) do
    local candidate = index - 1
    if candidate ~= self._row then
      other = candidate
      break
    end
  end
  if other == nil then
    return false
  end
  self._comparison = { indices = { self._row, other }, activeSide = 0, facing = "front" }
  return true
end

---@return { indices: integer[], activeSide: integer, facing: string }? detached comparison state
function PokedexForms:comparison()
  if self._comparison == nil then
    return nil
  end
  return {
    indices = { self._comparison.indices[1], self._comparison.indices[2] },
    activeSide = self._comparison.activeSide,
    facing = self._comparison.facing,
  }
end

---@param side integer 0 or 1 selecting side
---@return boolean whether the side changed
function PokedexForms:setActiveSide(side)
  if self._comparison == nil then
    return false
  end
  if side ~= 0 and side ~= 1 then
    fail("comparison sides are zero or one", { side = side })
  end
  if self._comparison.activeSide == side then
    return false
  end
  self._comparison.activeSide = side
  return true
end

---@param side integer 0 or 1 cycling side
---@param delta integer -1 or 1 cycle direction
---@return boolean whether the cycle changed an index
function PokedexForms:cycle(side, delta)
  if self._comparison == nil then
    return false
  end
  if side ~= 0 and side ~= 1 then
    fail("comparison sides are zero or one", { side = side })
  end
  if delta ~= 1 and delta ~= -1 then
    fail("comparison cycles move by signed direction", { delta = delta })
  end
  if #self._variants <= 2 then
    return false
  end
  local other = self._comparison.indices[side == 0 and 2 or 1]
  local next = self._comparison.indices[side + 1]
  for _ = 1, #self._variants do
    next = (next + delta) % #self._variants
    if next ~= other then
      break
    end
  end
  if next == self._comparison.indices[side + 1] then
    return false
  end
  self._comparison.indices[side + 1] = next
  return true
end

function PokedexForms:flip()
  if self._comparison == nil then
    return false
  end
  if self._comparison.facing == "front" then
    self._comparison.facing = "back"
  else
    self._comparison.facing = "front"
  end
  return true
end

function PokedexForms:closeComparison()
  self._comparison = nil
end

---@return { form: integer, gender: string, frontPersonality: integer, backPersonality: integer } current variant picture facts for portraits
function PokedexForms:currentPictureFacts()
  local variant = self._variants[self._row + 1] or self._variants[1]
  if variant == nil then
    fail("forms needs its fallback variant before pictures", { species = self._species })
  end
  assert(type(variant) == "table", "forms pictures read the current variant")
  local frontPersonality = 0
  local reader = self._dex.firstPersonality
  if type(reader) == "function" then
    frontPersonality = reader(self._dex, self._species) or 0
  end
  return { form = variant.form, gender = variant.gender, frontPersonality = frontPersonality, backPersonality = 0 }
end

---@return integer authored scrollbar thumb length
function PokedexForms:scrollbarLength()
  local count = #self._variants
  for position, threshold in ipairs(PokedexForms.SCROLLBAR_THRESHOLDS) do
    if count <= threshold then
      return PokedexForms.SCROLLBAR_LENGTHS[position]
    end
  end
  return PokedexForms.SCROLLBAR_LENGTHS[#PokedexForms.SCROLLBAR_LENGTHS]
end

---@return integer logical scrollbar center position
function PokedexForms:scrollbarPosition()
  local count = #self._variants
  local length = self:scrollbarLength()
  local half = math.floor(length / 2)
  local track = PokedexForms.SCROLLBAR_TRACK
  local center = PokedexForms.SCROLLBAR_CENTER
  local minY = center - math.floor(track / 2) + half
  local maxY = center + math.floor(track / 2) - half
  if count <= 1 then
    return maxY
  end
  local step = math.floor((maxY - minY) * 256 / (count - 1))
  return minY + math.floor(step * self._row / 256)
end

---@return { variants: table[], row: integer, scrollbar: { length: integer, position: integer }, comparison: { indices: integer[], activeSide: integer, facing: string }? } detached forms projection
function PokedexForms:view()
  local projection = {
    variants = self:variants(),
    row = self._row,
    scrollbar = { length = self:scrollbarLength(), position = self:scrollbarPosition() },
  }
  local comparison = self:comparison()
  if comparison ~= nil then
    projection.comparison = comparison
  end
  return projection
end

return PokedexForms
