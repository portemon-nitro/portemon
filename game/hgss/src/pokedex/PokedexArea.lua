-- Typed habitat lists, region/time travel, and source marker placement
-- for one entry: namespace merging with only the authored route-pair
-- coalescing, region travel and refresh sequencing, and the marker pulse.
-- Pure policy over borrowed catalogs: no love, no I/O, no history writes.

local Errors = require("libs.errors.src.Errors")

---@class PokedexArea
---@field _catalog table<string, unknown> borrowed generated catalog
---@field _dex table<string, unknown> borrowed authoritative knowledge owner
---@field _species string entry species key
---@field _nationalUnlocked boolean whether kanto travel is permitted
---@field _playerX integer captured global block column
---@field _playerY integer captured global block row
---@field _time integer 0 morning, 1 day, 2 night
---@field _region string viewed map region
---@field _row integer zero-based list cursor
---@field _rows table[] merged typed rows
---@field _phase string rest or refresh
---@field _refreshQ integer blend coefficient while refreshing
---@field _refreshUp boolean whether the background refresh is still climbing
---@field _travelTicks integer remaining region movement updates
---@field _pulseTick integer marker pulse clock
---@field _blinkTick integer player blink clock
local PokedexArea = {}
PokedexArea.__index = PokedexArea

PokedexArea.TIME_COUNT = 3
-- The separate background refresh value climbs by two to sixteen, then
-- falls back by two before region movement completes.
PokedexArea.REFRESH_STEP = 2
PokedexArea.REFRESH_TOP = 16
PokedexArea.REGION_TRAVEL_TICKS = 22
PokedexArea.BLINK_ON_TICKS = 16
PokedexArea.BLINK_PERIOD = 24
PokedexArea.PULSE_PERIOD = 32
PokedexArea.PULSE_TOP = 15
-- Only these authored pairs coalesce; no other neighboring areas merge.
PokedexArea.COALESCED_PAIRS = {
  ["custom.route-2-east"] = "custom.route-2",
  ["custom.route-16-east"] = "custom.route-16",
}

local function fail(message, context)
  Errors.raise("POKEDEX_INVALID", message, context)
end

---@param value unknown
---@param what string
---@return table<string, unknown>
local function checkTable(value, what)
  if type(value) ~= "table" then
    fail("area needs " .. what, {})
  end
  assert(type(value) == "table", "area reads its borrowed state")
  return value
end

---@param key string
---@return string coalesced representative map key
local function coalesceKey(key)
  return PokedexArea.COALESCED_PAIRS[key] or key
end

---@param args { catalog: table<string, unknown>, dex: table<string, unknown>, species: string, nationalUnlocked: boolean, playerPosition: table<string, unknown> }
---@return PokedexArea
function PokedexArea.new(args)
  if type(args) ~= "table" then
    fail("area needs a construction record", {})
  end
  assert(type(args) == "table", "area reads its construction record")
  local catalog = checkTable(args.catalog, "the generated catalog")
  if type(args.dex) ~= "table" then
    fail("area needs the knowledge owner", {})
  end
  if type(args.species) ~= "string" or args.species == "" then
    fail("area names its entry species", {})
  end
  local position = checkTable(args.playerPosition, "the captured player cell")
  if type(position.mapX) ~= "number" or type(position.mapY) ~= "number" then
    fail("area needs the captured global block cell", {})
  end
  local self = setmetatable({
    _catalog = catalog,
    _dex = args.dex,
    _species = args.species,
    _nationalUnlocked = args.nationalUnlocked == true,
    _playerX = position.mapX,
    _playerY = position.mapY,
    _time = 0,
    _region = "johto",
    _row = 0,
    _rows = {},
    _phase = "rest",
    _refreshQ = 0,
    _refreshUp = true,
    _travelTicks = 0,
    _pulseTick = 0,
    _blinkTick = 0,
  }, PokedexArea)
  self:_rebuild()
  return self
end

---@param list unknown
---@return string[] dense copy
local function copyKeys(list)
  local out = {}
  if type(list) ~= "table" then
    return out
  end
  for _, key in ipairs(list) do
    out[#out + 1] = key
  end
  return out
end

function PokedexArea:_rebuild()
  local catalog = self._catalog
  assert(type(catalog) == "table", "area reads its borrowed catalog")
  local habitats = checkTable(catalog.habitats, "habitats")
  local record = habitats[self._species]
  local rows = { { kind = "all" } }
  if type(record) == "table" then
    local times = { "morning", "day", "night" }
    local timeKey = times[self._time + 1]
    local timed = checkTable(record[timeKey], "the timed habitat set")
    local other = checkTable(record.other, "the other habitat set")
    local geometry = checkTable(catalog.areaGeometry, "area geometry")
    local order = catalog.areaOrder
    assert(type(order) == "table", "area reads the authored area order")
    local rank = {}
    for index, key in ipairs(order) do
      if rank[key] == nil then
        rank[key] = index
      end
    end
    local function rankOf(key)
      if rank[key] ~= nil then
        return rank[key]
      end
      return #order + 1
    end
    ---@param keys string[]
    ---@param kind string
    ---@param timedMember boolean
    ---@param otherMember boolean
    ---@param filterRegion boolean
    local function append(keys, kind, timedMember, otherMember, filterRegion)
      local seen = {}
      local merged = {}
      for _, key in ipairs(keys) do
        local representative = coalesceKey(key)
        if seen[representative] == nil then
          local geo = geometry[representative] or geometry[key]
          if type(geo) == "table" then
            local geoRecord = geo
            if filterRegion == false or geoRecord.region == self._region then
              seen[representative] = { mapKey = representative, timed = false, other = false }
              merged[#merged + 1] = seen[representative]
            end
          end
        end
        local entry = seen[representative]
        if entry ~= nil then
          if timedMember then
            entry.timed = true
          end
          if otherMember then
            entry.other = true
          end
        end
      end
      table.sort(merged, function(left, right)
        return rankOf(left.mapKey) < rankOf(right.mapKey)
      end)
      for _, entry in ipairs(merged) do
        rows[#rows + 1] = { kind = kind, mapKey = entry.mapKey, timed = entry.timed, other = entry.other }
      end
    end
    local timedOutdoor = copyKeys(checkTable(timed, "the timed habitat set").outdoor)
    local timedDungeon = copyKeys(checkTable(timed, "the timed habitat set").dungeon)
    local otherOutdoor = copyKeys(checkTable(other, "the other habitat set").outdoor)
    local otherDungeon = copyKeys(checkTable(other, "the other habitat set").dungeon)
    -- Timed namespaces follow the viewed region; the other-season
    -- namespaces stay visible regardless of region.
    append(timedOutdoor, "outdoor", true, false, true)
    append(otherOutdoor, "outdoor", false, true, false)
    append(timedDungeon, "dungeon", true, false, true)
    append(otherDungeon, "dungeon", false, true, false)
  end
  self._rows = rows
  if self._row > #rows - 1 then
    self._row = #rows - 1
  end
  if self._row < 0 then
    self._row = 0
  end
end

---@return integer zero-based row count
function PokedexArea:rowCount()
  return #self._rows
end

---@return boolean
function PokedexArea:isRefreshing()
  return self._phase ~= "rest"
end

function PokedexArea:_beginRefresh()
  self._phase = "refresh"
  self._refreshQ = 0
  self._refreshUp = true
  self._travelTicks = PokedexArea.REGION_TRAVEL_TICKS
end

---@param time integer 0 morning, 1 day, 2 night
function PokedexArea:setTime(time)
  if time ~= 0 and time ~= 1 and time ~= 2 then
    fail("area times are morning, day, or night", { time = time })
  end
  if time == self._time then
    return
  end
  self._time = time
  self._row = 0
  self:_rebuild()
  self:_beginRefresh()
end

function PokedexArea:cycleTime()
  self:setTime((self._time + 1) % PokedexArea.TIME_COUNT)
end

---@param region string viewed map region
function PokedexArea:setRegion(region)
  if region ~= "johto" and region ~= "kanto" then
    fail("area regions are johto or kanto", { region = region })
  end
  if region == "kanto" and self._nationalUnlocked ~= true then
    return
  end
  if region == self._region then
    return
  end
  self._region = region
  self._row = 0
  self:_rebuild()
  self:_beginRefresh()
end

---@param row integer zero-based destination row
---@return boolean whether the destination was accepted
function PokedexArea:goRow(row)
  if type(row) ~= "number" or row % 1 ~= 0 then
    fail("area rows are zero-based indexes", {})
  end
  if self._phase ~= "rest" then
    return false
  end
  if row < 0 or row > #self._rows - 1 then
    return false
  end
  self._row = row
  return true
end

---@param delta integer -1 or 1
---@return boolean whether the move was accepted
function PokedexArea:moveRow(delta)
  if delta ~= 1 and delta ~= -1 then
    fail("area rows move one row at a time", { delta = delta })
  end
  return self:goRow(self._row + delta)
end

function PokedexArea:update()
  if self._phase == "refresh" then
    if self._refreshUp == true then
      self._refreshQ = self._refreshQ + PokedexArea.REFRESH_STEP
      if self._refreshQ >= PokedexArea.REFRESH_TOP then
        self._refreshQ = PokedexArea.REFRESH_TOP
        self._refreshUp = false
      end
    elseif self._refreshQ > 0 then
      self._refreshQ = self._refreshQ - PokedexArea.REFRESH_STEP
      if self._refreshQ < 0 then
        self._refreshQ = 0
      end
    elseif self._travelTicks > 0 then
      self._travelTicks = self._travelTicks - 1
    else
      self._phase = "rest"
      self._refreshQ = 0
      self._pulseTick = 0
    end
  end
  self._pulseTick = self._pulseTick + 1
  self._blinkTick = self._blinkTick + 1
end

---@return integer current pulse coefficient 0 through 15
function PokedexArea:alpha()
  local step = self._pulseTick % PokedexArea.PULSE_PERIOD
  if step <= PokedexArea.PULSE_TOP then
    return step
  end
  return PokedexArea.PULSE_PERIOD - 1 - step
end

---@param mapKey string
---@return { shape: string, palette: integer, position: { x: number, y: number }, visible: boolean } marker projection for one habitat row
function PokedexArea:_markerFor(mapKey)
  local catalog = self._catalog
  assert(type(catalog) == "table", "area reads its borrowed catalog")
  local geometry = checkTable(catalog.areaGeometry, "area geometry")
  local geo = checkTable(geometry[mapKey], "the habitat geometry")
  local regionOffset = 0
  if self._region == "kanto" then
    regionOffset = 22
  end
  local position
  if geo.kind == "dungeon" then
    local at = checkTable(geo.position, "the dungeon placement")
    local offset = checkTable(geo.markerOffsetPx, "the dungeon marker pixel offset")
    if type(offset.x) ~= "number" or offset.x % 1 ~= 0 then
      fail("dungeon x offset is an integer", {})
    end
    if type(offset.y) ~= "number" or offset.y % 1 ~= 0 then
      fail("dungeon y offset is an integer", {})
    end
    position = { x = 8 * (at.x - regionOffset) + 68 + offset.x, y = 8 * at.y + 44 + offset.y }
  else
    local rect = checkTable(geo.rect, "the outdoor rect")
    position = {
      x = 8 * (rect.x - regionOffset) + 4 * rect.width + 64,
      y = 8 * rect.y + 4 * rect.height + 40,
    }
  end
  return { shape = "area", palette = 0, position = position, visible = self._phase == "rest" }
end

---@return { x: integer, y: integer, visible: boolean } detached player marker projection
function PokedexArea:playerView()
  local x = self._playerX
  if self._region == "kanto" then
    x = x - 22
  end
  return {
    x = x,
    y = self._playerY,
    visible = self._phase == "rest" and (self._blinkTick % PokedexArea.BLINK_PERIOD) < PokedexArea.BLINK_ON_TICKS,
  }
end

---@return { time: integer, region: string, row: integer, rows: { kind: string, mapKey: string?, timed: boolean?, other: boolean? }[], mapOffset: integer, markers: { shape: string, palette: integer, position: { x: number, y: number }, visible: boolean }[], player: { x: integer, y: integer, visible: boolean }, alpha: integer, phase: string, refresh: integer } detached area projection
function PokedexArea:view()
  local rows = {}
  for _, row in ipairs(self._rows) do
    if row.kind == "all" then
      rows[#rows + 1] = { kind = "all" }
    else
      rows[#rows + 1] = { kind = row.kind, mapKey = row.mapKey, timed = row.timed, other = row.other }
    end
  end
  local markers = {}
  for position = 2, #self._rows do
    local row = self._rows[position]
    assert(type(row.mapKey) == "string", "habitat rows carry their map key")
    local marker = self:_markerFor(row.mapKey)
    markers[#markers + 1] = marker
  end
  local mapOffset = -72
  if self._region == "kanto" then
    mapOffset = 104
  end
  return {
    time = self._time,
    region = self._region,
    row = self._row,
    rows = rows,
    mapOffset = mapOffset,
    markers = markers,
    player = self:playerView(),
    alpha = self:alpha(),
    phase = self._phase,
    refresh = self._refreshQ,
  }
end

return PokedexArea
