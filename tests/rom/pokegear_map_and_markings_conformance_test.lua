-- ROM conformance: indoor and special locations resolve through source
-- coordinates. The compiled pokegear family carries one location record
-- per map identity with field-map key, matrix cell, displayed location,
-- section name, and flypoint key kept distinct, and the map projection
-- normalizes outdoor matrix cells, indoor header coordinates, the
-- last-exterior fallback, and the Mt Silver, Indigo, Sinjoh, and S.S.
-- Aqua specials with the source Y offset and virtual origins applied
-- exactly once. Identities are asserted as semantic keys and integer
-- coordinates, never as copied dump bytes. A missing dump reports a
-- skip, never a pass, through the declared dump capability.

local Assert = require("tests.support.Assert")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

-- Loads a map module that does not exist yet at this baseline. The
-- failure names the missing behaviour instead of surfacing as a suite
-- load error, so the pre-implementation red stays attributable.
---@param moduleName string
---@param missingMessage string
---@return table
local function requireFeature(moduleName, missingMessage)
  local ok, mod = pcall(require, moduleName)
  if not ok then
    error(missingMessage, 0)
  end
  assert(type(mod) == "table", missingMessage)
  return mod --[[@as table]]
end

---@param romFs table<string, unknown>
---@param versionId string
---@return table<string, unknown> catalog
local function compileCatalog(romFs, versionId)
  local loaded, PokegearAssetCompiler = pcall(require, "romdump.src.digest.ui.PokegearAssetCompiler")
  Assert.isTrue(
    loaded,
    "the pokegear family compiler must be published before the map closure can be proven"
  )
  assert(type(PokegearAssetCompiler) == "table", "the family compiler loads above")
  local bundle = PokegearAssetCompiler.compile(romFs, versionId)
  local compiled = assert(bundle, versionId .. " must compile the pokegear family")
  local manifest = assert(compiled.manifest, versionId .. " must publish its pokegear manifest")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  Assert.notNil(PokegearAssetSchema.validate(manifest), versionId .. " publishes a schema-valid map catalog")
  return assert(manifest.catalog, versionId .. " publishes its map catalog") --[[@as table<string, unknown>]]
end

-- The compiled catalog keeps the five map identities distinct: several
-- places share a label, so collapsing any two roles would silently merge
-- locations that only look alike.
---@param catalog table<string, unknown>
---@param versionId string
---@return table locations
local function checkMapClosure(catalog, versionId)
  local locations = assert(catalog.locations, versionId .. " publishes its location table")
  assert(type(locations) == "table", "the location table reads above")
  Assert.isTrue(#locations > 0, versionId .. " compiles a non-empty location table")
  local flypoints = assert(catalog.flypoints, versionId .. " publishes its flypoint table")
  assert(type(flypoints) == "table", "the flypoint table reads above")
  Assert.isTrue(#flypoints > 0, versionId .. " compiles a non-empty flypoint table")
  local flyKeys = {}
  for _, fly in ipairs(flypoints) do
    assert(type(fly) == "table" and type(fly.key) == "string", "flypoints carry semantic keys")
    flyKeys[fly.key] = true
  end
  for index, entry in ipairs(locations) do
    assert(type(entry) == "table", "location " .. index .. " is a record")
    for _, role in ipairs({ "fieldMap", "matrix", "location", "section", "flypoint" }) do
      Assert.notNil(entry[role], versionId .. " location " .. index .. " distinguishes its " .. role .. " identity")
    end
    if entry.flypoint ~= nil and type(entry.flypoint) == "string" then
      Assert.isTrue(
        flyKeys[entry.flypoint] == true,
        versionId .. " location " .. index .. " references a compiled flypoint"
      )
    end
  end
  return locations
end

---@param locations table
---@param predicate fun(entry: table): boolean
---@param role string
---@param versionId string
---@return table entry
local function findLocation(locations, predicate, role, versionId)
  for _, entry in ipairs(locations) do
    if predicate(entry) == true then
      return entry
    end
  end
  error(versionId .. " compiles no location for role " .. role, 0)
end

function T.indoor_and_special_locations_resolve_through_source_coordinates(romFs, versionId)
  local catalog = compileCatalog(romFs, versionId)
  local locations = checkMapClosure(catalog, versionId)

  local MapProjection = requireFeature(
    "game.hgss.src.pokegear.MapProjection",
    versionId .. " has no map projection owner yet: indoor and special locations cannot resolve through source coordinates"
  )

  -- Source vectors, discovered by compiled role so shared labels never
  -- stand in for identity: an outdoor main-matrix cell, an indoor map
  -- with explicit header coordinates, a zero-coordinate map taking the
  -- last-exterior fallback, and the four coordinate-exception specials.
  local outdoor = findLocation(locations, function(entry)
    return entry.matrix ~= nil and entry.explicitX == nil and entry.special == nil
  end, "outdoor-matrix", versionId)
  local indoor = findLocation(locations, function(entry)
    return entry.explicitX ~= nil and entry.special == nil
  end, "indoor-explicit", versionId)
  local fallback = findLocation(locations, function(entry)
    return entry.explicitX == 0 and entry.explicitY == 0 and entry.special == nil
  end, "last-exterior-fallback", versionId)
  local specials = {}
  for _, name in ipairs({ "mt-silver", "indigo", "sinjoh", "aqua" }) do
    specials[name] = findLocation(locations, function(entry)
      return entry.special == name
    end, "special-" .. name, versionId)
  end

  -- Outdoor main-matrix maps project world player coordinates divided by
  -- thirty-two; the integer division is computed here, never borrowed
  -- from the module under test.
  do
    local cell = MapProjection.contextCell({
      matrixX = outdoor.matrix.x,
      matrixY = outdoor.matrix.y,
      explicitX = nil,
      explicitY = nil,
      lastExterior = nil,
      special = nil,
    })
    Assert.equal(cell.x, math.floor(outdoor.matrix.x / 32), "outdoor columns divide world x by thirty-two")
    Assert.equal(cell.y, math.floor(outdoor.matrix.y / 32), "outdoor rows divide world z by thirty-two")
  end

  -- Indoor maps use their explicit header coordinates verbatim, and a map
  -- with both coordinates zero falls back to the last exterior instead
  -- of projecting the origin.
  do
    local cell = MapProjection.contextCell({
      matrixX = 0,
      matrixY = 0,
      explicitX = indoor.explicitX,
      explicitY = indoor.explicitY,
      lastExterior = nil,
      special = nil,
    })
    Assert.equal(cell.x, indoor.explicitX, "indoor columns keep their header coordinates")
    Assert.equal(cell.y, indoor.explicitY, "indoor rows keep their header coordinates")
    local zeroed = MapProjection.contextCell({
      matrixX = 0,
      matrixY = 0,
      explicitX = fallback.explicitX,
      explicitY = fallback.explicitY,
      lastExterior = { x = 9, y = 21 },
      special = nil,
    })
    Assert.equal(zeroed.x, 9, "zero-coordinate maps fall back to the last exterior column")
    Assert.equal(zeroed.y, 21, "zero-coordinate maps fall back to the last exterior row")
  end

  -- The four specials resolve through their own source coordinates, and
  -- repeated projection never drifts: the Y offset and the virtual
  -- origins apply exactly once, never once per open.
  for _, name in ipairs({ "mt-silver", "indigo", "sinjoh", "aqua" }) do
    local entry = specials[name]
    local first = MapProjection.contextCell({
      matrixX = 0,
      matrixY = 0,
      explicitX = entry.explicitX,
      explicitY = entry.explicitY,
      lastExterior = { x = 9, y = 21 },
      special = entry.special,
    })
    local again = MapProjection.contextCell({
      matrixX = 0,
      matrixY = 0,
      explicitX = entry.explicitX,
      explicitY = entry.explicitY,
      lastExterior = { x = 9, y = 21 },
      special = entry.special,
    })
    Assert.deepEqual(again, first, name .. " projection never drifts across repeated opens")
    local point = MapProjection.markerPoint(first, { x = 0, y = 0 }, 8, { x = 0, y = 0, width = 256, height = 192 })
    local raw = { x = first.x * 8, y = first.y * 8 }
    Assert.equal(point.y - raw.y, 2 - 48, name .. " applies the source Y offset and virtual origin exactly once")
  end
end

local suite = RomSuite.fromFacts(T)
return suite
