-- Area lists, region/time travel, source marker placement, pulse, and
-- blend sequencing: the area page through the public fixed-update
-- projection. Real knowledge owner and compact synthetic catalogs with
-- outdoor/dungeon same-key membership; only readiness is stubbed. No
-- renderer, GPU, audio device, ROM, or worker is touched.

local Assert = require("tests.support.Assert")
local PokedexDexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")

local CONTROLLER_MODULE = "game.hgss.src.pokedex.PokedexController"

local T = {}

---@param behavior string missing browser behavior under test
---@return table the loaded browser controller owner
local function requirePresent(behavior)
  local ok, loaded = pcall(require, CONTROLLER_MODULE)
  Assert.isTrue(ok, "missing browser state owner: " .. behavior .. " (" .. CONTROLLER_MODULE .. ")")
  assert(loaded ~= nil, "the browser module loads")
  return loaded --[[@as table]]
end

local function catalogs()
  local monCatalog = PokedexDexFixture.makeCatalog()
  local catalog = PokedexDexFixture.buildPokedexCatalog()
  catalog.areaGeometry["custom.route-2"] = {
    kind = "outdoor",
    region = "johto",
    mapKey = "custom.route-2",
    name = { bankId = 1, messageId = 3 },
    rect = { x = 24, y = 0, width = 4, height = 4 },
    markerMask = {},
  }
  catalog.areaGeometry["custom.route-2-east"] = {
    kind = "outdoor",
    region = "johto",
    mapKey = "custom.route-2-east",
    name = { bankId = 1, messageId = 4 },
    rect = { x = 28, y = 0, width = 2, height = 4 },
    markerMask = {},
  }
  catalog.areaGeometry["custom.kanto-road"] = {
    kind = "outdoor",
    region = "kanto",
    mapKey = "custom.kanto-road",
    name = { bankId = 1, messageId = 5 },
    rect = { x = 24, y = 0, width = 4, height = 4 },
    markerMask = {},
  }
  catalog.areaOrder = { "custom.route-29", "custom.dark-cave", "custom.route-2", "custom.route-2-east" }
  catalog.habitats["EEVEE"] = {
    morning = {
      outdoor = { "custom.route-29", "custom.route-2", "custom.route-2-east" },
      dungeon = { "custom.dark-cave" },
    },
    day = { outdoor = {}, dungeon = {} },
    night = { outdoor = {}, dungeon = { "custom.dark-cave" } },
    other = { outdoor = { "custom.kanto-road" }, dungeon = {} },
  }
  return monCatalog, catalog
end

local function enabledOwner(monCatalog, catalog, national)
  local owner = PokedexKnowledge.new(PokedexDexFixture.refs(monCatalog, catalog))
  local flags = { dexEnabled = true }
  if national == true then
    flags.nationalDex = true
  end
  owner:prepareChanges({ flags = flags }):publish()
  return owner
end

---@param owner table knowledge owner under test
---@param monCatalog table resolved mon catalog
---@param fields table specimen fields
local function catch(owner, monCatalog, fields)
  local specimen = owner:describe(PokedexDexFixture.makeMon(monCatalog, fields))
  owner:prepareChanges({ observations = { { kind = "caught", specimen = specimen } } }):publish()
end

local function newBrowser(PokedexController, owner, monCatalog, catalog, position)
  return PokedexController.new({
    catalog = catalog,
    monCatalog = monCatalog,
    dex = owner,
    playerGender = "male",
    playerPosition = position or { mapX = 10, mapY = 10 },
    nativeLanguage = "english",
  })
end

---@param controller table browser under test
---@return table preparation carrying the currently demanded ready key
local function readyPrep(controller)
  return { readyKey = controller:view().key }
end

---@param controller table browser under test
---@param events table|nil semantic batch for one fixed update
local function tick(controller, events)
  controller:updateFixed(events or {}, readyPrep(controller))
end

---@param controller table browser under test
---@param count integer fixed updates to advance with no input
local function idle(controller, count)
  for _ = 1, count do
    tick(controller)
  end
end

---@param controller table browser under test
---@param species string entry to open through the grid
local function openArea(controller, species)
  tick(controller, { { type = "confirm" } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "grid", "cover confirm opens the grid before the entry")
  local slots = controller:view().grid.buffers[1].entries
  local cursor = controller:view().grid.cursor
  local target = nil
  for index, entry in ipairs(slots) do
    if entry.species == species then
      target = index - 1
    end
  end
  assert(target ~= nil, "the fixture species is on the grid")
  local moves = target - cursor
  local direction = moves > 0 and "right" or "left"
  for _ = 1, math.abs(moves) do
    tick(controller, { { type = "navigate", direction = direction } })
  end
  tick(controller, { { type = "confirm" } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "area", "confirming a nonblank selection opens its area page")
end

function T.area_starts_at_morning_johto_and_merges_namespaces_in_order()
  local PokedexController = requirePresent("typed area lists and region/time travel")
  local monCatalog, catalog = catalogs()
  local owner = enabledOwner(monCatalog, catalog, true)
  catch(owner, monCatalog, { species = "EEVEE", personality = 31 })
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openArea(controller, "EEVEE")
  local area = controller:view().area
  Assert.notNil(area, "the area projection is present")
  Assert.equal(area.time, 0, "every entry starts at morning")
  Assert.equal(area.region, "johto", "every entry starts in johto")
  Assert.equal(area.row, 0, "every entry starts on the first row")
  Assert.equal(area.rows[1].kind, "all", "the show-everything row leads the list")
  local kinds = {}
  for index = 2, #area.rows do
    kinds[#kinds + 1] = area.rows[index].kind .. ":" .. area.rows[index].mapKey
  end
  Assert.deepEqual(kinds, {
    "outdoor:custom.route-29",
    "outdoor:custom.route-2",
    "outdoor:custom.kanto-road",
    "dungeon:custom.dark-cave",
  }, "namespaces merge outdoor timed, outdoor other, dungeon timed, dungeon other")
  Assert.equal(area.rows[5].timed, true, "the dungeon row carries its timed membership")
  Assert.equal(area.rows[5].other, false, "the dungeon row carries no other membership")
  local routeTwos = 0
  for _, row in ipairs(area.rows) do
    if row.mapKey == "custom.route-2" or row.mapKey == "custom.route-2-east" then
      routeTwos = routeTwos + 1
    end
  end
  Assert.equal(routeTwos, 1, "only the authored route pair coalesces into a single row")
  controller:dispose()
end

function T.time_cycles_and_region_travel_gates_on_national()
  local PokedexController = requirePresent("typed area lists and region/time travel")
  local monCatalog, catalog = catalogs()
  local owner = enabledOwner(monCatalog, catalog, false)
  catch(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openArea(controller, "CHIKORITA")
  tick(controller, { { type = "activate", action = "area-time", value = 1 } })
  idle(controller, 10)
  Assert.equal(controller:view().area.time, 1, "the time command advances morning to day")
  tick(controller, { { type = "l" } })
  idle(controller, 30)
  Assert.equal(controller:view().area.region, "johto", "the johto selector keeps johto")
  tick(controller, { { type = "r" } })
  idle(controller, 30)
  Assert.equal(controller:view().area.region, "johto", "the kanto selector is inert before the national unlock")
  controller:dispose()
  local nationalOwner = enabledOwner(monCatalog, catalog, true)
  catch(nationalOwner, monCatalog, { species = "EEVEE", personality = 31 })
  local national = newBrowser(PokedexController, nationalOwner, monCatalog, catalog)
  openArea(national, "EEVEE")
  tick(national, { { type = "r" } })
  idle(national, 30)
  Assert.equal(national:view().area.region, "kanto", "the kanto selector travels with national unlocked")
  Assert.equal(national:view().area.mapOffset, 104, "the kanto leg uses its map offset")
  Assert.equal(national:view().area.row, 0, "region travel resets the list cursor")
  national:dispose()
end

function T.two_row_moves_need_their_full_destination()
  local PokedexController = requirePresent("typed area lists and region/time travel")
  local monCatalog, catalog = catalogs()
  local owner = enabledOwner(monCatalog, catalog, true)
  catch(owner, monCatalog, { species = "EEVEE", personality = 31 })
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openArea(controller, "EEVEE")
  local count = #controller:view().area.rows
  Assert.isTrue(count >= 3, "the fixture list has room for row moves")
  tick(controller, { { type = "navigate", direction = "down" } })
  idle(controller, 10)
  Assert.equal(controller:view().area.row, 1, "a one-row move advances one row")
  tick(controller, {
    { type = "activate", action = "area-row", value = 2 },
  })
  idle(controller, 10)
  Assert.equal(controller:view().area.row, 2, "a two-row touch jump selects its in-range row")
  tick(controller, {
    { type = "activate", action = "area-row", value = count + 1 },
  })
  idle(controller, 10)
  Assert.equal(controller:view().area.row, 2, "a two-row command past the end is a no-op, never a clamped one-row move")
  tick(controller, { { type = "navigate", direction = "down" } })
  idle(controller, 10)
  tick(controller, { { type = "navigate", direction = "down" } })
  idle(controller, 10)
  Assert.equal(controller:view().area.row, count - 1, "directional moves stop at the last row")
  controller:dispose()
end

function T.summary_only_species_report_unknown_area()
  local PokedexController = requirePresent("typed area lists and region/time travel")
  local monCatalog, catalog = catalogs()
  catalog.habitats["TOTODILE"] = {
    morning = { outdoor = {}, dungeon = {} },
    day = { outdoor = {}, dungeon = {} },
    night = { outdoor = {}, dungeon = {} },
    other = { outdoor = {}, dungeon = {} },
  }
  local owner = enabledOwner(monCatalog, catalog, true)
  catch(owner, monCatalog, { species = "TOTODILE", personality = 31 })
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openArea(controller, "TOTODILE")
  local rows = controller:view().area.rows
  Assert.equal(#rows, 1, "a summary-only list carries just the show-everything row")
  Assert.equal(rows[1].kind, "all", "the summary-only list reports unknown area")
  controller:dispose()
end

function T.refresh_hides_markers_rebuilds_and_restores_with_pulse()
  local PokedexController = requirePresent("typed area lists and region/time travel")
  local monCatalog, catalog = catalogs()
  local owner = enabledOwner(monCatalog, catalog, true)
  catch(owner, monCatalog, { species = "EEVEE", personality = 31 })
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog, { mapX = 10, mapY = 10 })
  openArea(controller, "EEVEE")
  tick(controller, { { type = "activate", action = "area-time", value = 1 } })
  local hidden = controller:view()
  local anyVisible = false
  for _, marker in ipairs(hidden.area.markers) do
    if marker.visible then
      anyVisible = true
    end
  end
  Assert.isFalse(anyVisible, "a region/time refresh immediately hides every habitat marker")
  Assert.isFalse(hidden.area.player.visible, "a region/time refresh immediately hides the player marker")
  local refresh = hidden.visual.blend.controls
  Assert.equal(refresh.eva + refresh.evb, 31, "the refresh blend preserves the hardware complement")
  Assert.isTrue(refresh.eva ~= 6 or refresh.evb ~= 10, "the refresh blend leaves the normal controls coefficients")
  idle(controller, 60)
  local restored = controller:view()
  Assert.equal(restored.visual.blend.controls.eva, 6, "the rebuild restores the normal controls blend")
  Assert.equal(restored.visual.blend.controls.evb, 10, "the rebuild restores the normal controls blend")
  Assert.equal(restored.area.player.x, 10, "the player marker keeps its projected global column")
  Assert.equal(restored.area.player.y, 10, "the player marker keeps its projected global row")
  local seenOn, seenOff = false, false
  for _ = 1, 30 do
    tick(controller)
    if controller:view().area.player.visible then
      seenOn = true
    else
      seenOff = true
    end
  end
  Assert.isTrue(seenOn and seenOff, "the player marker blinks on its authored cycle")
  local first = restored.area.alpha
  tick(controller)
  local second = controller:view().area.alpha
  Assert.isTrue(first ~= second, "the marker pulse advances while the page rests")
  for _ = 1, 40 do
    tick(controller)
  end
  local pulse = controller:view()
  Assert.isTrue(pulse.area.alpha >= 0 and pulse.area.alpha <= 15, "the pulse stays inside its authored range")
  Assert.equal(
    pulse.visual.blend.information.eva + pulse.visual.blend.information.evb,
    31,
    "the pulse preserves the hardware blend complement"
  )
  Assert.equal(
    pulse.visual.blend.information.eva,
    pulse.area.alpha,
    "the information blend follows the pulse coefficient"
  )
  controller:dispose()
end

function T.player_and_habitat_thresholds_stay_distinct()
  local PokedexController = requirePresent("typed area lists and region/time travel")
  local monCatalog, catalog = catalogs()
  local owner = enabledOwner(monCatalog, catalog, true)
  catch(owner, monCatalog, { species = "EEVEE", personality = 31 })
  local johto = newBrowser(PokedexController, owner, monCatalog, catalog, { mapX = 22, mapY = 5 })
  openArea(johto, "EEVEE")
  idle(johto, 60)
  Assert.equal(johto:view().area.player.x, 22, "column twenty-two stays on the johto side for the player")
  Assert.equal(johto:view().area.player.y, 5, "the johto player row projects unchanged")
  johto:dispose()
  local kanto = newBrowser(PokedexController, owner, monCatalog, catalog, { mapX = 23, mapY = 5 })
  openArea(kanto, "EEVEE")
  tick(kanto, { { type = "r" } })
  idle(kanto, 60)
  Assert.equal(kanto:view().area.region, "kanto", "the kanto leg views the kanto map")
  Assert.equal(kanto:view().area.player.x, 1, "column twenty-three subtracts twenty-two into kanto space")
  Assert.equal(kanto:view().area.player.y, 5, "the kanto player row projects unchanged")
  kanto:dispose()
end

-- Dungeon markers carry their own silhouette and pixel shift: the tall
-- hollow paints narrow and tall with a vertical nudge, the shifted hall
-- paints square with both nudges, the plain burrow paints square with no
-- nudge, and the kanto shaft subtracts twenty-two blocks before its own
-- nudge. The outdoor road keeps its existing shape and center.
function T.dungeon_markers_apply_their_own_shape_and_pixel_shift_in_both_regions()
  local PokedexController = requirePresent("dungeon marker shape and position")
  local monCatalog = PokedexDexFixture.makeCatalog()
  local catalog = PokedexDexFixture.buildPokedexCatalog()
  catalog.areaGeometry["custom.tall-hollow"] = {
    kind = "dungeon",
    region = "johto",
    mapKey = "custom.tall-hollow",
    name = { bankId = 1, messageId = 11 },
    position = { x = 11, y = 6 },
    markerShape = 6,
    markerOffsetPx = { x = 0, y = 4 },
  }
  catalog.areaGeometry["custom.shifted-hall"] = {
    kind = "dungeon",
    region = "johto",
    mapKey = "custom.shifted-hall",
    name = { bankId = 1, messageId = 12 },
    position = { x = 13, y = 6 },
    markerShape = 0,
    markerOffsetPx = { x = 4, y = 4 },
  }
  catalog.areaGeometry["custom.plain-burrow"] = {
    kind = "dungeon",
    region = "johto",
    mapKey = "custom.plain-burrow",
    name = { bankId = 1, messageId = 13 },
    position = { x = 15, y = 6 },
    markerShape = 0,
    markerOffsetPx = { x = 0, y = 0 },
  }
  catalog.areaGeometry["custom.kanto-shaft"] = {
    kind = "dungeon",
    region = "kanto",
    mapKey = "custom.kanto-shaft",
    name = { bankId = 1, messageId = 14 },
    position = { x = 30, y = 7 },
    markerShape = 6,
    markerOffsetPx = { x = 0, y = 4 },
  }
  catalog.areaGeometry["custom.plain-road"] = {
    kind = "outdoor",
    region = "johto",
    mapKey = "custom.plain-road",
    name = { bankId = 1, messageId = 15 },
    rect = { x = 4, y = 2, width = 4, height = 2 },
    markerMask = {},
  }
  catalog.areaOrder = {
    "custom.plain-road",
    "custom.tall-hollow",
    "custom.shifted-hall",
    "custom.plain-burrow",
    "custom.kanto-shaft",
  }
  catalog.habitats["EEVEE"] = {
    morning = {
      outdoor = { "custom.plain-road" },
      dungeon = { "custom.tall-hollow", "custom.shifted-hall", "custom.plain-burrow" },
    },
    day = { outdoor = {}, dungeon = {} },
    night = { outdoor = {}, dungeon = {} },
    other = { outdoor = {}, dungeon = { "custom.kanto-shaft" } },
  }
  local owner = enabledOwner(monCatalog, catalog, true)
  catch(owner, monCatalog, { species = "EEVEE", personality = 31 })
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openArea(controller, "EEVEE")
  local area = controller:view().area
  local keys = {}
  for index = 2, #area.rows do
    keys[#keys + 1] = area.rows[index].mapKey
  end
  Assert.deepEqual(keys, {
    "custom.plain-road",
    "custom.tall-hollow",
    "custom.shifted-hall",
    "custom.plain-burrow",
    "custom.kanto-shaft",
  }, "the fixture rows order the road, the three johto hollows and the other-season shaft")
  local expectedJohto = {
    { x = 112, y = 64 },
    { x = 156, y = 96 },
    { x = 176, y = 96 },
    { x = 188, y = 92 },
    { x = 308, y = 104 },
  }
  for index, want in ipairs(expectedJohto) do
    local marker = area.markers[index]
    Assert.notNil(marker, "every fixture row projects its marker")
    Assert.equal(marker.position.x, want.x, "row marker " .. index .. " keeps its horizontal pixel center")
    Assert.equal(marker.position.y, want.y, "row marker " .. index .. " keeps its vertical pixel center")
  end
  local objects = controller:view().objects
  Assert.notNil(objects, "the area page projects its sprite intents")
  local markers = {}
  for _, intent in ipairs(assert(objects, "the area carries its intents")) do
    if intent.subject == "marker" then
      markers[#markers + 1] = intent
    end
  end
  Assert.equal(#markers, 5, "every fixture row paints its marker")
  local choices = {}
  for _, marker in ipairs(markers) do
    choices[#choices + 1] = marker.choice
    Assert.equal(marker.pane, "information", "markers paint on the upper pane")
  end
  Assert.deepEqual(choices, { "shape3", "shape6", "shape0", "shape0", "shape6" }, "each marker paints its own silhouette")
  for index, want in ipairs(expectedJohto) do
    Assert.equal(markers[index].x, want.x, "painted marker " .. index .. " matches its projected column")
    Assert.equal(markers[index].y, want.y, "painted marker " .. index .. " matches its projected row")
  end
  tick(controller, { { type = "r" } })
  idle(controller, 60)
  local kanto = controller:view().area
  Assert.equal(kanto.region, "kanto", "the region selector travels")
  Assert.equal(#kanto.rows, 2, "the kanto leg keeps the show-everything row and the other-season shaft")
  Assert.equal(kanto.rows[2].mapKey, "custom.kanto-shaft", "the kanto leg lists the shaft")
  Assert.equal(kanto.markers[1].position.x, 132, "the kanto shaft subtracts twenty-two blocks before its own shift")
  Assert.equal(kanto.markers[1].position.y, 104, "the kanto shaft keeps its vertical shift")
  local kantoObjects = controller:view().objects
  Assert.notNil(kantoObjects, "the kanto leg projects its sprite intents")
  local kantoMarkers = {}
  for _, intent in ipairs(assert(kantoObjects, "the kanto leg carries its intents")) do
    if intent.subject == "marker" then
      kantoMarkers[#kantoMarkers + 1] = intent
    end
  end
  Assert.equal(#kantoMarkers, 1, "the kanto leg paints only the shaft")
  Assert.equal(kantoMarkers[1].choice, "shape6", "the kanto shaft keeps its tall silhouette")
  Assert.equal(kantoMarkers[1].x, 132, "the painted kanto shaft matches its projected column")
  Assert.equal(kantoMarkers[1].y, 104, "the painted kanto shaft matches its projected row")
  controller:dispose()
end

return { tests = T }
