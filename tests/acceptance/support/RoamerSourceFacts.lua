-- Source roamer facts and the transition oracles derived from them. The
-- eligible-route graph, the region bounds and the two source location
-- updates are transcribed from field_roamer.c so every acceptance that
-- reasons about native roamer movement reads one copy. The oracles consume
-- a detached world-stream copy and predict the route indexes the source
-- algorithms select; they never decide what the production owner does.

local MapCatalog = require("romdump.src.digest.map.MapCatalog")

local RoamerSourceFacts = {}

-- field_roamer.c::sRoamerLocations: the 41 eligible roamer routes in source
-- index order (Johto 0..15, Kanto 16..40).
RoamerSourceFacts.ROUTES = {
  "MAP_ROUTE_29",
  "MAP_ROUTE_30",
  "MAP_ROUTE_31",
  "MAP_ROUTE_32",
  "MAP_ROUTE_33",
  "MAP_ROUTE_34",
  "MAP_ROUTE_35",
  "MAP_ROUTE_36",
  "MAP_ROUTE_37",
  "MAP_ROUTE_38",
  "MAP_ROUTE_39",
  "MAP_ROUTE_42",
  "MAP_ROUTE_43",
  "MAP_ROUTE_44",
  "MAP_ROUTE_45",
  "MAP_ROUTE_46",
  "MAP_ROUTE_1",
  "MAP_ROUTE_2",
  "MAP_ROUTE_3",
  "MAP_ROUTE_4",
  "MAP_ROUTE_5",
  "MAP_ROUTE_6",
  "MAP_ROUTE_7",
  "MAP_ROUTE_8",
  "MAP_ROUTE_9",
  "MAP_ROUTE_10",
  "MAP_ROUTE_11",
  "MAP_ROUTE_12",
  "MAP_ROUTE_13",
  "MAP_ROUTE_14",
  "MAP_ROUTE_15",
  "MAP_ROUTE_16",
  "MAP_ROUTE_17",
  "MAP_ROUTE_18",
  "MAP_ROUTE_19",
  "MAP_ROUTE_20",
  "MAP_ROUTE_21",
  "MAP_ROUTE_22",
  "MAP_ROUTE_24",
  "MAP_ROUTE_26",
  "MAP_ROUTE_28",
}

-- field_roamer.c::sRoamerAdjacencyTable: the neighbors of each source route
-- index, in source order.
RoamerSourceFacts.ADJACENCY = {
  { 1, 15 },
  { 0, 2 },
  { 1, 3, 7 },
  { 2, 4, 7 },
  { 3, 5 },
  { 4, 6 },
  { 5, 7 },
  { 2, 3, 8 },
  { 7, 9, 11 },
  { 8, 10, 11 },
  { 9 },
  { 8, 9, 12, 13 },
  { 11, 13 },
  { 11, 12, 15 },
  { 13, 15 },
  { 0, 14 },
  { 17, 37 },
  { 16, 37, 18 },
  { 17, 19 },
  { 18, 20, 38 },
  { 19, 21, 22, 23, 24, 38 },
  { 22, 23, 26 },
  { 20, 21, 23, 31 },
  { 20, 21, 22, 25, 27 },
  { 19, 20, 25, 38 },
  { 23, 24, 27 },
  { 21, 27 },
  { 23, 25, 26, 28 },
  { 27, 29 },
  { 28, 30 },
  { 29, 33, 34 },
  { 22, 37 },
  { 31, 33 },
  { 30, 32, 34 },
  { 30, 33 },
  { 34, 36 },
  { 16, 34 },
  { 16, 17, 39, 40 },
  { 19, 20, 24 },
  { 37, 40 },
  { 37, 39, 24 },
}

-- field_roamer.c::ROAMER_LOC_JOHTO_START/COUNT and the Kanto pair: Raikou and
-- Entei pick inside Johto, Latias and Latios inside Kanto.
RoamerSourceFacts.REGIONS = {
  johto = { min = 0, count = 16 },
  kanto = { min = 16, count = 25 },
}

---@param routeIndex integer source route index
---@return integer source route map id
function RoamerSourceFacts.routeMapId(routeIndex)
  local symbol = assert(
    RoamerSourceFacts.ROUTES[routeIndex + 1],
    "the source route index names a route: " .. tostring(routeIndex)
  )
  return MapCatalog.idForSymbol(symbol)
end

---@param slot integer source roamer slot
---@return { min: integer, count: integer } the region that slot picks inside
function RoamerSourceFacts.regionOf(slot)
  return slot <= 1 and RoamerSourceFacts.REGIONS.johto or RoamerSourceFacts.REGIONS.kanto
end

---@param record table roamer record as the owner captures it
---@return integer its source route index
function RoamerSourceFacts.routeIndexOf(record)
  return assert(record.native, "a native roamer record names its metadata").routeIndex
end

-- The source's generator answers a 16-bit value; the field's existing
-- encounter draws read the shared world stream the same way.
---@param rng table a detached copy of the world stream
---@return integer
local function nextU16(rng)
  return rng:nextRaw() % 65536
end

-- field_roamer.c::RoamerLocationSetRandom: one in-region draw per attempt,
-- rejecting the player's previous location and the roamer's current route.
---@param rng table a detached copy of the world stream
---@param slot integer source roamer slot
---@param current integer current route index
---@param lastLocation integer|false the source's player-location history back
---@return integer the chosen route index
local function chooseRandom(rng, slot, current, lastLocation)
  local region = RoamerSourceFacts.regionOf(slot)
  while true do
    local candidate = nextU16(rng) % region.count + region.min
    local mapId = RoamerSourceFacts.routeMapId(candidate)
    if mapId ~= lastLocation and mapId ~= RoamerSourceFacts.routeMapId(current) then
      return candidate
    end
  end
end

-- field_roamer.c::Save_UpdateRoamersLocation over the source's own route
-- graph, drawing from the one world stream in slot order: a 1/16 chance to
-- randomize inside the slot's region, otherwise one adjacent route, never
-- the player's previous location; a single neighbor that is that location
-- falls back to the random branch. Terminal slots never move.
---@param roamers table<string, table> the captured roamer records by key
---@param slotKeys string[] the source keys in slot order
---@param lastLocation integer|false the source's player-location history back
---@param rng table a detached copy of the world stream
---@return table<integer, integer> predicted route index by slot
function RoamerSourceFacts.simulateUpdate(roamers, slotKeys, lastLocation, rng)
  local locations = {}
  for slot, key in ipairs(slotKeys) do
    locations[slot - 1] = RoamerSourceFacts.routeIndexOf(roamers[key])
  end
  local function updateAdjacent(slot, current, previous)
    local neighbors = assert(
      RoamerSourceFacts.ADJACENCY[current + 1],
      "the source graph names the current route"
    )
    if #neighbors == 1 then
      local candidate = neighbors[1]
      if RoamerSourceFacts.routeMapId(candidate) == previous then
        locations[slot] = chooseRandom(rng, slot, current, previous)
      else
        locations[slot] = candidate
      end
      return
    end
    while true do
      local candidate = neighbors[nextU16(rng) % #neighbors + 1]
      if RoamerSourceFacts.routeMapId(candidate) ~= previous then
        locations[slot] = candidate
        return
      end
    end
  end
  for slot = 0, #slotKeys - 1 do
    local key = slotKeys[slot + 1]
    local record = roamers[key]
    local current = locations[slot]
    if record ~= nil and current ~= nil and record.lifecycle == "roaming" then
      if nextU16(rng) % 16 == 0 then
        locations[slot] = chooseRandom(rng, slot, current, lastLocation)
      else
        updateAdjacent(slot, current, lastLocation)
      end
    end
  end
  return locations
end

-- field_roamer.c::Save_RandomizeRoamersLocation: every active slot picks a
-- fresh in-region route, excluding the player's previous location and its
-- own current route, one draw attempt at a time in slot order.
---@param roamers table<string, table> the captured roamer records by key
---@param slotKeys string[] the source keys in slot order
---@param lastLocation integer|false the source's player-location history back
---@param rng table a detached copy of the world stream
---@return table<integer, integer> predicted route index by slot
function RoamerSourceFacts.simulateRandomize(roamers, slotKeys, lastLocation, rng)
  local locations = {}
  for slot = 0, #slotKeys - 1 do
    local record = roamers[slotKeys[slot + 1]]
    local current = RoamerSourceFacts.routeIndexOf(record)
    locations[slot] = current
    if record.lifecycle == "roaming" then
      locations[slot] = chooseRandom(rng, slot, current, lastLocation)
    end
  end
  return locations
end

return RoamerSourceFacts
