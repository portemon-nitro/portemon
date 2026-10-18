-- Compiles the compact Pokedex semantic catalog from the selected dump:
-- source orders, completion sets, sort orders, measurement profiles,
-- search criteria, slider steps, area geometry and encounter sets,
-- evaluation ratings, and fixed text bindings. Source tables are read
-- through bounded archive members with full dimension, termination, and
-- reference validation; the compiled root carries no native member
-- arithmetic. Returns the validated catalog plus dependency provenance.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local MonCache = require("libs.assets.src.MonCache")
local MonSources = require("romdump.src.config.MonSources")
local PokedexAssetSchema = require("libs.assets.src.PokedexAssetSchema")
local PokedexCache = require("libs.assets.src.PokedexCache")
local PokedexSources = require("romdump.src.config.PokedexSources")

local PokedexCatalogCompiler = {}

PokedexCatalogCompiler.ERROR = {
  SOURCE_UNAVAILABLE = "POKEDEX_SOURCE_UNAVAILABLE",
  MEMBER_COUNT = "POKEDEX_MEMBER_COUNT",
  MEMBER_SIZE = "POKEDEX_MEMBER_SIZE",
  UNMAPPED_SPECIES = "POKEDEX_UNMAPPED_SPECIES",
  DUPLICATE_ORDER = "POKEDEX_DUPLICATE_ORDER",
  UNTERMINATED_LIST = "POKEDEX_UNTERMINATED_LIST",
  ILLEGAL_AREA = "POKEDEX_ILLEGAL_AREA",
  INVERSE_MISMATCH = "POKEDEX_INVERSE_MISMATCH",
  HEIGHT_UNAVAILABLE = "POKEDEX_HEIGHT_UNAVAILABLE",
  VERSION_UNSUPPORTED = "POKEDEX_VERSION_UNSUPPORTED",
  CATALOG_INVALID = "POKEDEX_CATALOG_INVALID",
}

---@param code string
---@param message string
---@param context table<string, unknown>?
---@noreturn
local function raise(code, message, context)
  Errors.raise(code, message, context or {})
end

---@param romFs table<string, unknown>
---@param spec { path: string, memberCount: integer }
---@param label string
---@return Narc
local function readArchive(romFs, spec, label)
  local bytes, readErr = romFs:readSourcePath(spec.path)
  if bytes == nil then
    raise(
      PokedexCatalogCompiler.ERROR.SOURCE_UNAVAILABLE,
      "pokedex " .. label .. " source is unavailable: " .. tostring(readErr),
      { path = spec.path }
    )
  end
  ---@cast bytes string
  local Narc = require("libs.nds.src.nitro.Narc")
  local archive, narcErr = Narc.open(bytes, spec.path)
  if archive == nil then
    raise(
      PokedexCatalogCompiler.ERROR.SOURCE_UNAVAILABLE,
      "pokedex " .. label .. " archive does not open: " .. tostring(narcErr and narcErr.message or narcErr),
      { path = spec.path }
    )
  end
  assert(archive ~= nil, "pokedex source archive is unavailable")
  if archive:memberCount() ~= spec.memberCount then
    raise(
      PokedexCatalogCompiler.ERROR.MEMBER_COUNT,
      "pokedex "
        .. label
        .. " archive has "
        .. archive:memberCount()
        .. " members, expected "
        .. spec.memberCount
        .. " members",
      { path = spec.path, count = archive:memberCount(), expected = spec.memberCount }
    )
  end
  return archive
end

---@param archive Narc
---@param memberId integer
---@param label string
---@return string
local function readMember(archive, memberId, label)
  local bytes = archive:readMember(memberId)
  if bytes == nil then
    raise(
      PokedexCatalogCompiler.ERROR.SOURCE_UNAVAILABLE,
      "pokedex " .. label .. " member " .. memberId .. " is unavailable",
      { member = memberId }
    )
  end
  assert(bytes ~= nil, "pokedex source member is unavailable")
  return bytes
end

---@param bytes string
---@param offset integer
---@return integer
local function byteAt(bytes, offset)
  local value = string.byte(bytes, offset)
  assert(value ~= nil, "pokedex source bytes end prematurely")
  return value
end

local function u16le(bytes, offset)
  return byteAt(bytes, offset) + byteAt(bytes, offset + 1) * 256
end

local function u32le(bytes, offset)
  return byteAt(bytes, offset)
    + byteAt(bytes, offset + 1) * 256
    + byteAt(bytes, offset + 2) * 65536
    + byteAt(bytes, offset + 3) * 16777216
end

local function s16le(bytes, offset)
  local value = u16le(bytes, offset)
  if value >= 32768 then
    return value - 65536
  end
  return value
end

---@param archive Narc
---@param memberId integer
---@param count integer
---@param label string
---@return integer[]
local function readIdList(archive, memberId, count, label)
  local bytes = readMember(archive, memberId, label)
  if #bytes ~= count * 2 then
    raise(
      PokedexCatalogCompiler.ERROR.MEMBER_SIZE,
      "pokedex " .. label .. " member has " .. #bytes .. " bytes, expected " .. (count * 2) .. " bytes",
      { member = memberId, size = #bytes }
    )
  end
  local ids = {}
  for index = 1, count do
    ids[index] = u16le(bytes, (index - 1) * 2 + 1)
  end
  return ids
end

---@param monCatalog table<string, unknown>
---@param id integer
---@param label string
---@return string
local function keyForId(monCatalog, id, label)
  local key = MonSources.speciesKeys[id]
  if type(key) ~= "string" then
    raise(
      PokedexCatalogCompiler.ERROR.UNMAPPED_SPECIES,
      "pokedex " .. label .. " references unmapped species id " .. id,
      { id = id }
    )
  end
  local species = monCatalog.species
  if type(species) ~= "table" or species[key] == nil then
    raise(
      PokedexCatalogCompiler.ERROR.UNMAPPED_SPECIES,
      "pokedex " .. label .. " references species outside the mon catalog: " .. key,
      { key = key }
    )
  end
  return key
end

---@param monCatalog table<string, unknown>
---@param ids integer[]
---@param label string
---@return string[]
local function keysForIds(monCatalog, ids, label)
  local keys, seen = {}, {}
  for _, id in ipairs(ids) do
    local key = keyForId(monCatalog, id, label)
    if seen[key] then
      raise(
        PokedexCatalogCompiler.ERROR.DUPLICATE_ORDER,
        "pokedex " .. label .. " repeats species " .. key,
        { key = key }
      )
    end
    seen[key] = true
    keys[#keys + 1] = key
  end
  return keys
end

local function _compile(romFs, versionId, monCatalog, sink)
  if not PokedexSources.versions[versionId] then
    raise(
      PokedexCatalogCompiler.ERROR.VERSION_UNSUPPORTED,
      "pokedex catalog names an unsupported version: " .. tostring(versionId),
      { versionId = versionId }
    )
  end
  assert(type(monCatalog) == "table" and type(monCatalog.species) == "table", "catalog requires a mon catalog")
  assert(
    type(monCatalog.version) == "table" and type(monCatalog.version.language) == "string",
    "catalog requires the mon catalog language"
  )
  local metadata = assert(romFs:metadata(), "pokedex compilation requires ROM metadata")
  assert(type(metadata.sha1) == "string" and metadata.sha1 ~= "", "pokedex compilation requires the ROM identity")

  local baseArchive = readArchive(romFs, PokedexSources.archives.measuresBase, "base measures")
  local originArchive = readArchive(romFs, PokedexSources.archives.measuresOrigin, "origin measures")
  local sliderArchive = readArchive(romFs, PokedexSources.archives.slider, "slider")
  local habitatArchive = readArchive(romFs, PokedexSources.archives.habitat, "habitat")
  local inverseArchive = readArchive(romFs, PokedexSources.archives.johtoInverse, "johto inverse")
  local heightArchive = readArchive(romFs, PokedexSources.archives.portraitY, "portrait heights")
  local heightAltArchive = readArchive(romFs, PokedexSources.archives.portraitYAlt, "alternate portrait heights")

  local function parseMeasures(archive, label)
    local heights = readMember(archive, 0, label .. " heights")
    local weights = readMember(archive, 1, label .. " weights")
    if #heights ~= 494 * 4 or #weights ~= 494 * 4 then
      raise(
        PokedexCatalogCompiler.ERROR.MEMBER_SIZE,
        "pokedex " .. label .. " measurement tables are not 494 entries",
        {}
      )
    end
    local shapes = readMember(archive, 2, label .. " shapes")
    if #shapes ~= 494 then
      raise(PokedexCatalogCompiler.ERROR.MEMBER_SIZE, "pokedex " .. label .. " shape table is not 494 bytes", {})
    end
    local scales = {}
    for member = 3, 10 do
      local bytes = readMember(archive, member, label .. " geometry")
      if #bytes ~= 494 * 2 then
        raise(
          PokedexCatalogCompiler.ERROR.MEMBER_SIZE,
          "pokedex " .. label .. " geometry member " .. member .. " is not 494 entries",
          {}
        )
      end
      scales[member] = bytes
    end
    return { heights = heights, weights = weights, shapes = shapes, scales = scales }
  end

  local base = parseMeasures(baseArchive, "base")
  local origin = parseMeasures(originArchive, "origin")

  local function parseSorts(archive, label)
    local parsed = {}
    for member = 14, 17 do
      parsed[member] = readIdList(archive, member, 493, label .. " sort order " .. member)
    end
    return parsed
  end

  local baseSortIds = parseSorts(baseArchive, "base")
  local originSortIds = parseSorts(originArchive, "origin")

  -- Species slots are entry-indexed: entry e (zero-based) carries species
  -- e, so species s reads byte offset s * size. Entry 0 is the source
  -- padding slot and is never emitted.
  local function profileMeasurements(parsed)
    local measurements = {}
    for id = 1, 493 do
      local key = MonSources.speciesKeys[id]
      if key ~= nil and monCatalog.species[key] ~= nil then
        measurements[key] = {
          heightDm = u32le(parsed.heights, id * 4 + 1),
          weightHg = u32le(parsed.weights, id * 4 + 1),
          scale = {
            male = { trainer = s16le(parsed.scales[5], id * 2 + 1), mon = s16le(parsed.scales[6], id * 2 + 1) },
            female = { trainer = s16le(parsed.scales[3], id * 2 + 1), mon = s16le(parsed.scales[4], id * 2 + 1) },
          },
          yOffset = {
            male = { trainer = s16le(parsed.scales[9], id * 2 + 1), mon = s16le(parsed.scales[10], id * 2 + 1) },
            female = { trainer = s16le(parsed.scales[7], id * 2 + 1), mon = s16le(parsed.scales[8], id * 2 + 1) },
          },
        }
      end
    end
    return measurements
  end

  local baseMeasurements = profileMeasurements(base)
  local originMeasurements = profileMeasurements(origin)

  local nationalIds = readIdList(baseArchive, 11, 493, "national order")
  local johtoIds = readIdList(baseArchive, 12, 256, "johto order")
  local alphaIds = readIdList(baseArchive, 13, 493, "alphabetical order")

  local national = keysForIds(monCatalog, nationalIds, "national order")
  local johto = keysForIds(monCatalog, johtoIds, "johto order")
  local alphabetical = keysForIds(monCatalog, alphaIds, "alphabetical order")
  local function resolveSorts(sortIds, label)
    local resolved = {}
    for member = 14, 17 do
      resolved[member] = keysForIds(monCatalog, sortIds[member], label .. " sort order " .. member)
    end
    return resolved
  end

  local baseSorts = resolveSorts(baseSortIds, "base")
  local originSorts = resolveSorts(originSortIds, "origin")

  local nationalSet = {}
  for _, key in ipairs(national) do
    nationalSet[key] = true
  end
  for _, key in ipairs(alphabetical) do
    if not nationalSet[key] then
      raise(
        PokedexCatalogCompiler.ERROR.UNMAPPED_SPECIES,
        "pokedex alphabetical order covers species outside the national order: " .. key,
        { key = key }
      )
    end
  end
  if #alphabetical ~= #national then
    raise(PokedexCatalogCompiler.ERROR.MEMBER_SIZE, "pokedex alphabetical order does not cover every species", {})
  end

  local letters = {}
  for index, letter in ipairs(PokedexSources.letterOrder) do
    local bytes = readMember(baseArchive, 17 + index, "letter list " .. letter)
    if #bytes % 2 ~= 0 then
      raise(PokedexCatalogCompiler.ERROR.MEMBER_SIZE, "pokedex letter list " .. letter .. " is not u16-aligned", {})
    end
    local ids = {}
    for offset = 1, #bytes, 2 do
      ids[#ids + 1] = u16le(bytes, offset)
    end
    letters[letter] = keysForIds(monCatalog, ids, "letter list " .. letter)
  end
  for member = 44, 61 do
    local bytes = readMember(baseArchive, member, "extra letter slot")
    if #bytes ~= 0 then
      raise(
        PokedexCatalogCompiler.ERROR.MEMBER_SIZE,
        "pokedex extra letter slot " .. member .. " is not empty",
        { member = member }
      )
    end
  end

  local types = {}
  for index, name in ipairs(PokedexSources.typeOrder) do
    local bytes = readMember(baseArchive, 61 + index, "type list " .. name)
    if #bytes % 2 ~= 0 then
      raise(PokedexCatalogCompiler.ERROR.MEMBER_SIZE, "pokedex type list " .. name .. " is not u16-aligned", {})
    end
    local ids = {}
    for offset = 1, #bytes, 2 do
      ids[#ids + 1] = u16le(bytes, offset)
    end
    types[name] = keysForIds(monCatalog, ids, "type list " .. name)
  end

  local shapeLists = {}
  for index, name in ipairs(PokedexSources.shapeOrder) do
    local bytes = readMember(baseArchive, 78 + index, "shape list " .. name)
    if #bytes % 2 ~= 0 then
      raise(PokedexCatalogCompiler.ERROR.MEMBER_SIZE, "pokedex shape list " .. name .. " is not u16-aligned", {})
    end
    local ids = {}
    for offset = 1, #bytes, 2 do
      ids[#ids + 1] = u16le(bytes, offset)
    end
    shapeLists[name] = keysForIds(monCatalog, ids, "shape list " .. name)
  end

  local sliderBytes = readMember(sliderArchive, 0, "slider rows")
  if #sliderBytes ~= 153 * 4 then
    raise(
      PokedexCatalogCompiler.ERROR.MEMBER_SIZE,
      "pokedex slider member has " .. #sliderBytes .. " bytes, expected 612 bytes",
      { size = #sliderBytes }
    )
  end
  local sliderSteps = {}
  for row = 1, 153 do
    sliderSteps[row] = {
      heightDm = u16le(sliderBytes, (row - 1) * 4 + 1),
      weightHg = u16le(sliderBytes, (row - 1) * 4 + 3),
    }
  end
  local maskBytes = readMember(sliderArchive, 1, "area masks")
  if #maskBytes ~= 494 then
    raise(PokedexCatalogCompiler.ERROR.MEMBER_SIZE, "pokedex area mask member is not 494 bytes", {})
  end
  local function maskFor(speciesId)
    return byteAt(maskBytes, speciesId + 1)
  end

  local areas = { johto = {}, kanto = {}, unknown = {} }
  for id = 1, 493 do
    local key = MonSources.speciesKeys[id]
    if key ~= nil and monCatalog.species[key] ~= nil then
      local mask = maskFor(id)
      local unrestricted = (math.floor(mask / 128) % 2) == 1
      if unrestricted or (mask % 4) >= 2 then
        areas.johto[#areas.johto + 1] = key
      end
      if unrestricted or (math.floor(mask / 4) % 2) == 1 then
        areas.kanto[#areas.kanto + 1] = key
      end
      if unrestricted or (math.floor(mask / 16) % 2) == 1 then
        areas.unknown[#areas.unknown + 1] = key
      end
    end
  end
  -- Preserve source tie order: national order filtered by mask bit. The
  -- mask member is species-indexed while display follows dex order.
  local function orderLikeNational(list)
    local wanted = {}
    for _, key in ipairs(list) do
      wanted[key] = true
    end
    local ordered = {}
    for _, key in ipairs(national) do
      if wanted[key] then
        ordered[#ordered + 1] = key
      end
    end
    return ordered
  end
  areas.johto = orderLikeNational(areas.johto)
  areas.kanto = orderLikeNational(areas.kanto)
  areas.unknown = orderLikeNational(areas.unknown)

  local dungeonGeometry = readMember(habitatArchive, 0, "dungeon geometry")
  if #dungeonGeometry ~= 26 * 4 then
    raise(PokedexCatalogCompiler.ERROR.MEMBER_SIZE, "pokedex dungeon geometry is not 26 records", {})
  end
  local outdoorGeometry = readMember(habitatArchive, 1, "outdoor geometry")
  if #outdoorGeometry ~= 70 * 36 then
    raise(PokedexCatalogCompiler.ERROR.MEMBER_SIZE, "pokedex outdoor geometry is not 70 records", {})
  end

  local areaGeometry = {}
  local function outdoorKey(id)
    return "dex-outdoor-" .. id
  end

  local function dungeonKey(id)
    return "dex-dungeon-" .. id
  end

  for id = 1, 70 do
    local baseOffset = (id - 1) * 36 + 1
    local x = byteAt(outdoorGeometry, baseOffset)
    local y = byteAt(outdoorGeometry, baseOffset + 1)
    local markerMask = {}
    for index = 1, 32 do
      markerMask[index] = byteAt(outdoorGeometry, baseOffset + 3 + index)
    end
    areaGeometry[outdoorKey(id)] = {
      kind = "outdoor",
      region = x < 22 and "johto" or "kanto",
      mapKey = outdoorKey(id),
      name = { bankId = 0, messageId = 0 },
      rect = {
        x = x,
        y = y,
        width = byteAt(outdoorGeometry, baseOffset + 2),
        height = byteAt(outdoorGeometry, baseOffset + 3),
      },
      markerMask = markerMask,
    }
  end
  for id = 1, 26 do
    local baseOffset = (id - 1) * 4 + 1
    local x = byteAt(dungeonGeometry, baseOffset)
    local y = byteAt(dungeonGeometry, baseOffset + 1)
    areaGeometry[dungeonKey(id)] = {
      kind = "dungeon",
      region = x < 22 and "johto" or "kanto",
      mapKey = dungeonKey(id),
      name = { bankId = 0, messageId = 0 },
      position = { x = x, y = y },
    }
  end

  local areaBases = PokedexSources.habitatBases
  local function readAreaList(group, slot)
    local memberId = areaBases[group + 1] + slot
    local bytes = readMember(habitatArchive, memberId, "habitat list")
    if #bytes < 4 or #bytes % 4 ~= 0 then
      raise(
        PokedexCatalogCompiler.ERROR.MEMBER_SIZE,
        "pokedex habitat list is not a u32 row grid (group " .. group .. " slot " .. slot .. ")",
        {}
      )
    end
    local values = {}
    for offset = 1, #bytes, 4 do
      values[#values + 1] = u32le(bytes, offset)
    end
    if values[#values] ~= 0 then
      raise(
        PokedexCatalogCompiler.ERROR.UNTERMINATED_LIST,
        "pokedex habitat list has no zero terminator (group " .. group .. " slot " .. slot .. ")",
        {}
      )
    end
    values[#values] = nil
    return values
  end

  local function areaKeysFor(group, slot, namespace)
    local keys = {}
    for _, areaId in ipairs(readAreaList(group, slot)) do
      local limit = namespace == "outdoor" and 70 or 26
      if areaId < 1 or areaId > limit then
        raise(
          PokedexCatalogCompiler.ERROR.ILLEGAL_AREA,
          "pokedex habitat list references illegal " .. namespace .. " area " .. areaId,
          { area = areaId }
        )
      end
      if namespace == "outdoor" then
        keys[#keys + 1] = outdoorKey(areaId)
      else
        keys[#keys + 1] = dungeonKey(areaId)
      end
    end
    return keys
  end

  local function habitatSetsFor(slot)
    return {
      morning = { dungeon = areaKeysFor(0, slot, "dungeon"), outdoor = areaKeysFor(3, slot, "outdoor") },
      day = { dungeon = areaKeysFor(1, slot, "dungeon"), outdoor = areaKeysFor(4, slot, "outdoor") },
      night = { dungeon = areaKeysFor(2, slot, "dungeon"), outdoor = areaKeysFor(5, slot, "outdoor") },
      other = { dungeon = areaKeysFor(6, slot, "dungeon"), outdoor = areaKeysFor(7, slot, "outdoor") },
    }
  end

  for group = 0, 7 do
    local values = readAreaList(group, 494)
    if #values ~= 0 then
      raise(
        PokedexCatalogCompiler.ERROR.ILLEGAL_AREA,
        "pokedex unused habitat slot 494 carries encounters",
        { group = group }
      )
    end
  end
  local allAreaSets = habitatSetsFor(0)
  local habitats = {}
  for id = 1, 493 do
    local key = MonSources.speciesKeys[id]
    if key ~= nil and monCatalog.species[key] ~= nil then
      habitats[key] = habitatSetsFor(id)
    end
  end

  local inverseBytes = readMember(inverseArchive, 0, "johto inverse")
  if #inverseBytes ~= 494 * 2 then
    raise(PokedexCatalogCompiler.ERROR.MEMBER_SIZE, "pokedex johto inverse is not 494 entries", {})
  end
  -- Species slots are entry-indexed like every bounded table: entry e
  -- (zero-based) carries species e, so species s reads byte offset s*2.
  -- Entry 0 belongs to the unused species 0 slot and is never emitted.
  local inverse = {}
  for id = 1, 493 do
    inverse[id] = u16le(inverseBytes, id * 2 + 1)
  end
  local nonzero = 0
  for id = 1, 493 do
    if inverse[id] ~= 0 then
      nonzero = nonzero + 1
    end
  end
  if nonzero ~= 256 then
    raise(
      PokedexCatalogCompiler.ERROR.INVERSE_MISMATCH,
      "pokedex johto inverse carries " .. nonzero .. " nonzero entries, expected 256",
      {}
    )
  end
  for position, key in ipairs(johto) do
    local id = assert(MonSources.speciesId(key), "johto order resolves its species")
    if inverse[id] ~= position then
      raise(
        PokedexCatalogCompiler.ERROR.INVERSE_MISMATCH,
        "pokedex johto inverse entry for " .. key .. " does not match its johto position",
        { key = key }
      )
    end
  end

  ---@param memberId integer
  ---@return string|nil
  local function rawHeightMember(memberId)
    return heightArchive:readMember(memberId)
  end

  ---@param memberId integer
  ---@param label string
  ---@return string
  local function heightMember(memberId, label)
    local bytes = rawHeightMember(memberId)
    if bytes == nil then
      raise(
        PokedexCatalogCompiler.ERROR.SOURCE_UNAVAILABLE,
        "pokedex " .. label .. " height member is unavailable",
        { member = memberId }
      )
    end
    assert(bytes ~= nil, "pokedex height member is unavailable")
    assert(bytes ~= nil, "pokedex height member is unavailable")
    return bytes
  end

  ---@param memberId integer
  ---@return string
  local function altHeightMember(memberId)
    local bytes = heightAltArchive:readMember(memberId)
    if bytes == nil then
      raise(
        PokedexCatalogCompiler.ERROR.SOURCE_UNAVAILABLE,
        "pokedex alternate height member is unavailable",
        { member = memberId }
      )
    end
    assert(bytes ~= nil, "pokedex alternate height member is unavailable")
    return bytes
  end

  local function genderRatioOf(key)
    local record = monCatalog.species[key]
    if type(record) ~= "table" or type(record.genderRatio) ~= "number" then
      return nil
    end
    return record.genderRatio
  end

  local function validGenders(key)
    local ratio = genderRatioOf(key)
    if ratio == 0 then
      return { "male" }
    end
    if ratio == 254 then
      return { "female" }
    end
    if ratio == 255 then
      return { "male" }
    end
    return { "male", "female" }
  end

  -- Gender-invalid ordinary slots stay empty: female slots of male-only
  -- and genderless species, non-female slots of female-only species.
  for id = 1, 493 do
    local key = MonSources.speciesKeys[id]
    if key ~= nil and monCatalog.species[key] ~= nil then
      local ratio = genderRatioOf(key)
      local invalid = {}
      if ratio == 0 or ratio == 255 or ratio == nil then
        invalid = { 4 * id, 4 * id + 2 }
      elseif ratio == 254 then
        invalid = { 4 * id + 1, 4 * id + 3 }
      end
      for _, memberId in ipairs(invalid) do
        local bytes = rawHeightMember(memberId)
        if bytes ~= nil and #bytes ~= 0 then
          raise(
            PokedexCatalogCompiler.ERROR.HEIGHT_UNAVAILABLE,
            "pokedex unreachable height member " .. memberId .. " is not empty",
            { member = memberId }
          )
        end
      end
    end
  end

  local backYOffset = {}
  for id = 1, 493 do
    local key = MonSources.speciesKeys[id]
    local catalogRecord = key ~= nil and monCatalog.species[key] or nil
    if key ~= nil and catalogRecord ~= nil and type(catalogRecord.forms) == "table" then
      local forms = {}
      for form in pairs(catalogRecord.forms) do
        if type(form) == "number" then
          forms[#forms + 1] = form
        end
      end
      table.sort(forms)
      local genders = validGenders(key)
      for _, form in ipairs(forms) do
        local memberId = PokedexSources.altHeightMember(key, form, 0)
        if memberId == nil then
          for _, gender in ipairs(genders) do
            memberId = PokedexSources.ordinaryHeightMember(id, 0, gender == "female")
            local bytes = heightMember(memberId, "ordinary")
            if #bytes == 0 then
              raise(
                PokedexCatalogCompiler.ERROR.HEIGHT_UNAVAILABLE,
                "pokedex back height for " .. key .. " form " .. form .. " is uninitialized",
                { key = key, form = form }
              )
            end
            backYOffset[MonCache.portraitSelector(key, form, gender == "female" and "female" or "male", false, "back")] =
              byteAt(bytes, 1)
          end
        else
          local altBytes = altHeightMember(memberId)
          if #altBytes == 0 then
            raise(
              PokedexCatalogCompiler.ERROR.HEIGHT_UNAVAILABLE,
              "pokedex alternate back height for " .. key .. " form " .. form .. " is uninitialized",
              { key = key, form = form }
            )
          end
          for _, gender in ipairs(genders) do
            backYOffset[MonCache.portraitSelector(key, form, gender == "female" and "female" or "male", false, "back")] =
              byteAt(altBytes, 1)
          end
        end
      end
    end
  end

  local function formPolicyFor(key)
    local ordered = PokedexSources.orderedPolicies[key]
    local automatic = PokedexSources.automaticFamilies[key] == true
    local catalogRecord = monCatalog.species[key]
    local resolved = {}
    if type(catalogRecord) == "table" and type(catalogRecord.forms) == "table" then
      for form in pairs(catalogRecord.forms) do
        if type(form) == "number" then
          resolved[#resolved + 1] = form
        end
      end
    end
    table.sort(resolved)
    local resolvedSet = {}
    for _, form in ipairs(resolved) do
      resolvedSet[form] = true
    end
    if ordered ~= nil then
      local variants = {}
      if key == "PICHU" then
        for _, fixed in ipairs(PokedexSources.pichuVariants) do
          if resolvedSet[fixed.form] then
            variants[#variants + 1] = { id = fixed.id, form = fixed.form, gender = fixed.gender }
          end
        end
        for _, form in ipairs(resolved) do
          if form >= 2 then
            variants[#variants + 1] = { id = form + 1, form = form }
          end
        end
      else
        for id = 0, ordered.capacity - 1 do
          if resolvedSet[id] then
            variants[#variants + 1] = { id = id, form = id }
          end
        end
        for _, form in ipairs(resolved) do
          if form >= ordered.capacity then
            variants[#variants + 1] = { id = form, form = form }
          end
        end
      end
      if #variants == 0 then
        variants[#variants + 1] = { id = 0, form = resolved[1] or 0 }
      end
      return {
        kind = "ordered",
        variants = variants,
        defaultVariant = variants[1].id,
        rememberCaughtVariants = ordered.rememberCaughtVariants == true,
        rememberFirstPersonality = ordered.rememberFirstPersonality == true,
      }
    end
    if automatic then
      local variants = {}
      for _, form in ipairs(resolved) do
        variants[#variants + 1] = { id = form, form = form }
      end
      if #variants == 0 then
        variants[#variants + 1] = { id = 0, form = 0 }
      end
      return {
        kind = "automatic",
        variants = variants,
        defaultVariant = variants[1].id,
        rememberCaughtVariants = false,
        rememberFirstPersonality = false,
      }
    end
    return {
      kind = "ordinary",
      variants = { { id = 0, form = resolved[1] or 0 } },
      defaultVariant = 0,
      rememberCaughtVariants = false,
      rememberFirstPersonality = false,
    }
  end

  local johtoPosition = {}
  for position, key in ipairs(johto) do
    johtoPosition[key] = position
  end
  local nationalPosition = {}
  for position, key in ipairs(national) do
    nationalPosition[key] = position
  end
  local exclusionNational, exclusionJohto = {}, {}
  for _, key in ipairs(PokedexSources.completionExclusions.national) do
    exclusionNational[key] = true
  end
  for _, key in ipairs(PokedexSources.completionExclusions.johto) do
    exclusionJohto[key] = true
  end

  local species = {}
  for key in pairs(monCatalog.species) do
    if type(key) == "string" then
      local displayed = nationalPosition[key] ~= nil
      local record = { formPolicy = formPolicyFor(key) }
      if displayed then
        record.nationalNumber = nationalPosition[key]
        record.johtoNumber = johtoPosition[key]
        local shapeByte = byteAt(base.shapes, (assert(MonSources.speciesId(key), "species resolves")) + 1)
        if shapeByte == nil or shapeByte > 13 then
          raise(
            PokedexCatalogCompiler.ERROR.MEMBER_SIZE,
            "pokedex body shape for " .. key .. " is not a valid shape",
            { key = key }
          )
        end
        record.shape = PokedexSources.shapeOrder[shapeByte + 1]
      end
      species[key] = record
    end
  end

  local completionSets = { johto = {}, national = {} }
  for _, key in ipairs(johto) do
    if not exclusionJohto[key] then
      completionSets.johto[#completionSets.johto + 1] = key
    end
  end
  for _, key in ipairs(national) do
    if not exclusionNational[key] then
      completionSets.national[#completionSets.national + 1] = key
    end
  end

  local function sortKeys(sortTable, member)
    return sortTable[member]
  end

  local measurementProfiles = {
    base = {
      measurements = baseMeasurements,
      sorts = {
        heaviest = sortKeys(baseSorts, 14),
        lightest = sortKeys(baseSorts, 15),
        tallest = sortKeys(baseSorts, 16),
        shortest = sortKeys(baseSorts, 17),
      },
    },
    giratina_origin = {
      measurements = originMeasurements,
      sorts = {
        heaviest = sortKeys(originSorts, 14),
        lightest = sortKeys(originSorts, 15),
        tallest = sortKeys(originSorts, 16),
        shortest = sortKeys(originSorts, 17),
      },
    },
  }

  local areaOrder = {}
  for id = 1, 26 do
    areaOrder[#areaOrder + 1] = dungeonKey(id)
  end
  for id = 1, 70 do
    areaOrder[#areaOrder + 1] = outdoorKey(id)
  end

  local function ratingFor(required)
    return {
      bands = { { max = required - 1, messageId = 0 } },
      complete = { maleMessageId = 0, femaleMessageId = 0 },
      incompleteMusicId = 0,
      completeMusicId = 0,
    }
  end

  local catalog = {
    schema = PokedexCache.CATALOG_SCHEMA,
    versionId = versionId,
    nativeLanguage = monCatalog.version.language,
    species = species,
    dexOrders = { johto = johto, national = national },
    completionSets = completionSets,
    sortOrders = { alphabetical = alphabetical },
    measurementProfiles = measurementProfiles,
    criteria = { letters = letters, types = types, shapes = shapeLists, areas = areas },
    sliderSteps = sliderSteps,
    areaGeometry = areaGeometry,
    areaOrder = areaOrder,
    habitats = habitats,
    allAreaSets = allAreaSets,
    evaluation = {
      johto = ratingFor(#completionSets.johto),
      national = ratingFor(#completionSets.national),
    },
    pictures = { backYOffset = backYOffset },
    textBindings = PokedexSources.textBindings(versionId),
  }

  local validated, schemaErr = PokedexAssetSchema.validateCatalog(catalog, monCatalog)
  if validated == nil then
    raise(
      PokedexCatalogCompiler.ERROR.CATALOG_INVALID,
      "pokedex catalog failed closed validation: " .. tostring(schemaErr and schemaErr.message or schemaErr),
      {}
    )
  end

  local inputs = {}
  for _, entry in ipairs({
    { path = PokedexSources.archives.measuresBase.path, archive = baseArchive },
    { path = PokedexSources.archives.measuresOrigin.path, archive = originArchive },
    { path = PokedexSources.archives.slider.path, archive = sliderArchive },
    { path = PokedexSources.archives.habitat.path, archive = habitatArchive },
    { path = PokedexSources.archives.johtoInverse.path, archive = inverseArchive },
    { path = PokedexSources.archives.portraitY.path, archive = heightArchive },
    { path = PokedexSources.archives.portraitYAlt.path, archive = heightAltArchive },
  }) do
    local bytes = assert(romFs:readSourcePath(entry.path), "provenance requires its source bytes")
    inputs[#inputs + 1] = { path = entry.path, sha1 = Hashing.sha1hex(bytes), members = entry.archive:memberCount() }
  end
  local provenance = {
    schema = PokedexCache.CATALOG_SCHEMA,
    cacheFormat = PokedexCache.FORMAT,
    versionId = versionId,
    versionRomSha1 = metadata.sha1,
    source = PokedexSources.provenance,
    inputs = inputs,
    dependencies = { "mon-catalog:global" },
  }
  provenance.dependencyHash = Hashing.hashLua(provenance)
  provenance.marker = PokedexCache.dataMarker(metadata.sha1, provenance.dependencyHash)
  if sink ~= nil then
    sink.provenance = provenance
    sink.dependencyHash = provenance.dependencyHash
    sink.marker = provenance.marker
  end
  return catalog, nil
end

---@param romFs table<string, unknown>
---@param versionId string
---@param monCatalog table<string, unknown>
---@param sink table<string, unknown>?
---@return table<string, unknown>?
---@return Errors.Error?
function PokedexCatalogCompiler.compile(romFs, versionId, monCatalog, sink)
  assert(romFs and romFs.readSourcePath and romFs.metadata, "compile requires a RomFs-shaped object")
  local ok, first, second = xpcall(_compile, function(err)
    if Errors.is(err) then
      return err
    end
    return { raw = err, trace = debug.traceback("", 2) }
  end, romFs, versionId, monCatalog, sink)
  if ok then
    return first, second
  end
  if Errors.is(first) then
    return nil, first --[[@as Errors.Error]]
  end
  if type(first) == "table" and first.trace then
    error(first.raw, 0)
  end
  error(first, 0)
end

return PokedexCatalogCompiler
