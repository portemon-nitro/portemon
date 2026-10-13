-- Region-map location and flypoint queries over the compiled source tables
-- (catalog.regionMap): the first covering location of a cell in table order,
-- the hidden-location rules, the Johto/Kanto/Indigo region of a cell, and
-- flypoint selection under the visited flags and the region test. Follows
-- pokegear_map.c and overlay_101_021E9270.c of pret/pokeheartgold. Rows of
-- locations already include the source +2 offset; flypoints and matrix
-- cells do not. Pure module: no love, no I/O.

---@class MapLocations
---@field _locations table<integer, table<string, unknown>>
---@field _flypoints table<integer, table<string, unknown>>
---@field _byMapId table<integer, table<string, unknown>>
---@field _unlock integer
---@field _sinjoh boolean
---@field _aqua boolean
local MapLocations = {}
MapLocations.__index = MapLocations

-- Map symbols whose location is hidden unless the player stands on or near
-- it (source PokegearMap_ShouldLocationBeHidden).
local SINJOH_MAPS = {
  MAP_SINJOH_RUINS_EXTERIOR = true,
  MAP_SINJOH_RUINS_MYSTRI_STAGE = true,
  MAP_SINJOH_RUINS_CABIN = true,
}
local AQUA_MAPS = {
  MAP_SS_AQUA_1F = true,
  MAP_SS_AQUA_CAPTAIN_ROOM = true,
  MAP_SS_AQUA_1F_SOUTHEAST_ROOMS = true,
  MAP_SS_AQUA_1F_SOUTHWEST_ROOMS = true,
  MAP_SS_AQUA_1F_NORTHEAST_ROOMS = true,
  MAP_SS_AQUA_1F_NORTHWEST_ROOMS = true,
  MAP_SS_AQUA_B1F = true,
}

MapLocations.REGION = { KANTO = 0, INDIGO = 1, JOHTO = 2 }

-- Source map header ids of the two destinations the region test always allows
-- and of the flypoint whose unvisited art the world layer skips.
local MAP_ROUTE_26 = 30
local MAP_INDIGO_PLATEAU = 58
MapLocations.MAP_CIANWOOD = 75

---@class MapLocations.Options
---@field regionMap table<string, unknown> catalog.regionMap
---@field unlock integer map unlock level 0 to 2
---@field fieldMap string the current field map symbol, for the Sinjoh and S.S. Aqua rules

---@param opts MapLocations.Options
---@return MapLocations
function MapLocations.new(opts)
  assert(type(opts) == "table" and type(opts.regionMap) == "table", "locations need the compiled region map")
  local regionMap = opts.regionMap
  assert(
    type(regionMap.locations) == "table" and type(regionMap.flypoints) == "table",
    "the region map carries its tables"
  )
  local byMapId = {}
  for _, location in ipairs(regionMap.locations) do
    if byMapId[location.mapId] == nil then
      byMapId[location.mapId] = location
    end
  end
  return setmetatable({
    _locations = regionMap.locations,
    _flypoints = regionMap.flypoints,
    _byMapId = byMapId,
    _unlock = opts.unlock,
    _sinjoh = SINJOH_MAPS[opts.fieldMap] == true,
    _aqua = AQUA_MAPS[opts.fieldMap] == true,
  }, MapLocations)
end

---@return boolean whether the player stands on the Sinjoh Ruins maps
function MapLocations:atSinjoh()
  return self._sinjoh
end

---@return boolean whether the player stands on an S.S. Aqua map
function MapLocations:atAqua()
  return self._aqua
end

---@param location table<string, unknown>
---@return boolean
function MapLocations:_hidden(location)
  local symbol = location.mapSymbol
  if symbol == "MAP_SINJOH_RUINS_EXTERIOR" then
    return not self._sinjoh
  elseif symbol == "MAP_SS_AQUA_1F" then
    return not self._aqua
  end
  return false
end

-- The first location in table order covering a cell, or nil. A hidden first
-- match ends the search without trying later overlapping locations.
---@param x integer
---@param y integer
---@return table<string, unknown>? location
function MapLocations:locationAt(x, y)
  for _, location in ipairs(self._locations) do
    if x >= location.x and y >= location.y and x < location.x + location.width and y < location.y + location.height then
      if self:_hidden(location) then
        return nil
      end
      return location
    end
  end
  return nil
end

-- The selected location for a cell: the covering location, with the level-0
-- rule that hides Kanto except the Mt. Silver cell (source ov101_021EA794).
---@param x integer
---@param y integer
---@return table<string, unknown>? location
function MapLocations:select(x, y)
  local location = self:locationAt(x, y)
  if self._unlock == 0 and not (x == 25 and y == 10) and x >= 22 then
    return nil
  end
  return location
end

---@param mapId integer
---@return table<string, unknown>? location the first location of a map, hidden ones excluded
function MapLocations:byMapId(mapId)
  local location = self._byMapId[mapId]
  if location == nil or self:_hidden(location) then
    return nil
  end
  return location
end

---@return table<integer, table<string, unknown>> every location in table order
function MapLocations:all()
  return self._locations
end

---@return table<integer, table<string, unknown>> every flypoint in table order
function MapLocations:flypoints()
  return self._flypoints
end

-- The tile copies the source applies to the world layer once at creation:
-- the unlock-tier cover, the unvisited-town art, and the Goldenrod/Safari,
-- Sinjoh, and S.S. Aqua patches (source ov101_021EAF40). Tile units on the
-- world image, copied over the same positions.
---@param visited fun(flypoint: integer): boolean whether a flypoint was visited
---@return table<integer, table<string, integer>>
function MapLocations:worldPatches(visited)
  local patches = {}
  local function add(srcX, srcY, destX, destY, width, height)
    patches[#patches + 1] = { srcX = srcX, srcY = srcY, destX = destX, destY = destY, width = width, height = height }
  end
  if self._unlock == 0 then
    add(48, 0, 22, 0, 6, 20)
  elseif self._unlock == 1 then
    add(54, 0, 29, 0, 3, 20)
  end
  for _, flypoint in ipairs(self._flypoints) do
    local overlay = flypoint.overlay
    local skip = flypoint.nameMapId == MapLocations.MAP_CIANWOOD
      or overlay.width == 0
      or (self._unlock < 2 and MapLocations.regionOf(flypoint.x, flypoint.y) == MapLocations.REGION.KANTO)
      or visited(flypoint.flypoint) == true
    if not skip then
      add(
        overlay.srcX,
        overlay.srcY,
        flypoint.x - overlay.destX,
        flypoint.y - overlay.destY + 2,
        overlay.width,
        overlay.height
      )
    end
  end
  -- The Safari corner keeps its patch until the Goldenrod flypoint (flag
  -- index 15) is visited; the Safari Zone is always visible.
  if visited(15) ~= true then
    add(48, 27, 1, 9, 5, 6)
  end
  if self._sinjoh then
    add(55, 20, 19, 1, 3, 4)
  end
  if self._aqua then
    add(55, 24, 24, 15, 3, 3)
  end
  return patches
end

-- The Johto/Kanto/Indigo region of a matrix cell (source
-- Pokegear_RegionFromCoords). Rows here are matrix rows, without the +2.
---@param x integer
---@param y integer
---@return integer region MapLocations.REGION
function MapLocations.regionOf(x, y)
  if x > 21 then
    if x == 25 and y == 8 then
      return MapLocations.REGION.JOHTO
    elseif (x == 28 and y == 6) or (x == 28 and y > 8 and y < 13) then
      return MapLocations.REGION.INDIGO
    end
    return MapLocations.REGION.KANTO
  end
  return MapLocations.REGION.JOHTO
end

-- The region-name entry shown for a cell: Johto 0, Kanto 1 in message
-- bank 273 terms of the compiled `regionNames` order. Kanto and Indigo read
-- as Kanto, matching `(region / 2) ^ 1`.
---@param x integer selected cell column
---@param y integer selected cell row (with the +2)
---@return string "johto"|"kanto"
function MapLocations.regionName(x, y)
  local region = MapLocations.regionOf(x, y - 2)
  if region == MapLocations.REGION.JOHTO then
    return "johto"
  end
  return "kanto"
end

-- Whether a destination lies in the player's region, or is one of the two
-- always-allowed destinations (source ov101_021EA7E4/ov101_021EA804).
---@param mapId integer
---@param x integer matrix column
---@param y integer matrix row
---@param currentRegion integer
---@return boolean
function MapLocations.regionAllowed(mapId, x, y, currentRegion)
  if mapId == MAP_INDIGO_PLATEAU or mapId == MAP_ROUTE_26 then
    return true
  end
  return currentRegion == MapLocations.REGION.INDIGO or MapLocations.regionOf(x, y) == currentRegion
end

return MapLocations
