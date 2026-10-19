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

return { tests = T }
