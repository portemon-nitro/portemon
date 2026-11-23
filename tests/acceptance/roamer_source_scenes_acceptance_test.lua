-- The two source scenes that create native roamer slots, driven through the
-- production field composition on their own maps: the Burned Tower B1F
-- coordinate event whose beast-release scene creates Raikou and Entei, and
-- Vermilion's map-init Steven scene whose picture window precedes the
-- creation of the version's Lati roamer. Each test starts the real map,
-- reaches the authored creation commands and observes the settled native
-- slot metadata through the field's roamer owner. Only audio, fade and clock
-- host boundaries are recorded; maps, actors, scripts, the picture window
-- and the roamer owner stay production-owned, and the render trap stays
-- active throughout.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FinalizedGameFixture = require("tests.support.FinalizedGameFixture")
local RoamerSourceFacts = require("tests.acceptance.support.RoamerSourceFacts")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "audio-bank:700",
      "audio-bank:702",
      -- The Burned Tower B1F scene map.
      "map:217",
      "map-data:217",
      "message-bank:61",
      -- Vermilion and the neighbouring maps its outdoor coverage stages.
      "map:54",
      "map-data:54",
      "map-data:14",
      "map-data:15",
      "map-data:16",
      "map-data:19",
      "map-data:21",
      "map-data:55",
      "map-data:59",
      "message-bank:483",
    },
    tags = { "field", "script", "encounter", "roamer" },
  },
  tests = {},
}

local BURNED_TOWER_B1F = "MAP_BURNED_TOWER_B1F"
local BURNED_TOWER_SCRIPT = "vanilla.hgss.scr_seq.0024.script_000"
-- The map's own coordinate event covers (20,16)-(20,17) while VAR_UNK_40A1
-- still reads its pre-scene value; the player walks onto it from the south.
local BURNED_TOWER_APPROACH = { fieldX = 20, fieldZ = 17 }
-- The map's own warp landing from Burned Tower 1F, the floor the player
-- walks in from.
local BURNED_TOWER_ENTRY = { fieldX = 23, fieldZ = 16 }
local SCENE_TRIGGER_VAR = assert(FieldScriptSymbols.variablesByName.VAR_UNK_40A1)
local RAIKOU_HIDDEN_FLAG = assert(FieldScriptSymbols.flagsByName.FLAG_HIDE_BURNED_TOWER_B1F_RAIKOU)
local ENTEI_HIDDEN_FLAG = assert(FieldScriptSymbols.flagsByName.FLAG_HIDE_BURNED_TOWER_B1F_ENTEI)
local RAIKOU_STATUS_VAR = assert(FieldScriptSymbols.variablesByName.VAR_ROAMER_RAIKOU_STATUS)
local ENTEI_STATUS_VAR = assert(FieldScriptSymbols.variablesByName.VAR_ROAMER_ENTEI_STATUS)

local VERMILION = "MAP_VERMILION"
local VERMILION_SCRIPT = "vanilla.hgss.scr_seq.0776.script_013"
-- The map-init frame script starts the scene while this progression word is
-- at the value the Lost Item quest leaves behind.
local STEVEN_SCENE_VAR = assert(FieldScriptSymbols.variablesByName.VAR_UNK_4130)
local STEVEN_SCENE_READY = 1
local STEVEN_SCENE_DONE = 2
local STEVEN_HIDDEN_FLAG = assert(FieldScriptSymbols.flagsByName.FLAG_HIDE_VERMILION_CITY_STEVEN)
-- GetGameVersion answers 7 for HeartGold and 8 for SoulSilver; the scene
-- shows and releases the version's own Lati roamer.
local LATI_BY_VERSION = {
  heartgold = { slot = 2, key = "native.latias", species = "LATIAS" },
  soulsilver = { slot = 3, key = "native.latios", species = "LATIOS" },
}

---@param mapSymbol string
---@param location { fieldX: integer, fieldZ: integer, facing: string? }
---@param worldState table?
---@return AcceptanceHarness
local function harnessFor(mapSymbol, location, worldState)
  return AcceptanceHarness.new({
    gameFactory = function(versionId)
      return FinalizedGameFixture.build(versionId, {
        location = {
          mapSymbol = mapSymbol,
          fieldX = location.fieldX,
          fieldZ = location.fieldZ,
          facing = location.facing or "south",
        },
        worldState = worldState,
      })
    end,
  })
end

---@param game table acceptance game owning the production field runtime
---@param scriptId string canonical source script identity under test
---@return string[] faults the script published
local function faultsFor(game, scriptId)
  local faults = {}
  for _, record in ipairs(game:recordsForScript(scriptId, "script.error")) do
    local payload = record.payload or {}
    local context = payload.context or {}
    local where = ""
    for _, key in ipairs({ "localX", "localZ", "actorId", "fieldX", "fieldZ", "mapId" }) do
      if context[key] ~= nil then
        where = where .. " " .. key .. "=" .. tostring(context[key])
      end
    end
    faults[#faults + 1] = string.format(
      "%s/%s/%s%s",
      tostring(payload.code),
      tostring(context.command or context.originalName or "unknown"),
      tostring(payload.message),
      where
    )
  end
  return faults
end

---@param game table
---@return table<string, table> roamer records by key as the owner captures them
local function capturedRoamers(game)
  local owner = assert(game.runtime.roamerState, "the field runtime owns its roamer state")
  return assert(
    assert(owner:capture(), "the roamer owner captures its own state").roamers,
    "the roamer capture carries its records"
  )
end

-- Drives the fixed tick, answering only source dialogue and menu waits, until
-- the caller's boundary is reached or the source script publishes a fault. The
-- caller asserts the fault itself, so a faulting scene still ends the drive.
---@param game table
---@param scriptId string canonical source script identity under test
---@param label string boundary description
---@param done fun(snapshot: table): boolean
---@param maxTicks integer
local function driveScene(game, scriptId, label, done, maxTicks)
  for _ = 1, maxTicks do
    if done(game:snapshot()) then
      return
    end
    if #game:recordsForScript(scriptId, "script.error") > 0 then
      return
    end
    if game:snapshot().dialogue.modal then
      game:pressAction()
    else
      game:step()
    end
  end
  error(
    "the scene did not reach its boundary: "
      .. label
      .. "; foreground="
      .. tostring(game:snapshot().foregroundScript)
      .. ", modal="
      .. tostring(game:snapshot().dialogue.modal)
      .. ", stage="
      .. tostring(game:snapshot().mapEntryStage),
    0
  )
end

-- ---------------------------------------------------------------------------
-- Burned Tower B1F: the map's own coordinate event runs the beast-release
-- scene. The beasts cry, spin and flee, the scene hides them, and it creates
-- the two Johto roamer slots before Eusine's dialogue.
-- ---------------------------------------------------------------------------

function T.tests.burned_tower_beast_release_creates_raikou_and_entei()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harnessFor(BURNED_TOWER_B1F, BURNED_TOWER_ENTRY):boot({
    versionId = versionId,
    map = BURNED_TOWER_B1F,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    Assert.equal(game:snapshot().mapSymbol, BURNED_TOWER_B1F, "the scenario starts on Burned Tower B1F")
    game:moveTo(BURNED_TOWER_APPROACH)
    game:face("north")
    game:move("north")
    game:advanceUntil("the beast-release coordinate event starts", function()
      return #game:recordsForScript(BURNED_TOWER_SCRIPT, "script.started") > 0
    end, 240)

    local roamers = nil
    driveScene(game, BURNED_TOWER_SCRIPT, "the scene creates its two roamer slots", function()
      local state = game.runtime.roamerState
      roamers = state and state:capture() or nil
      return roamers ~= nil and roamers.roamers ~= nil and roamers.roamers["native.raikou"] ~= nil
        and roamers.roamers["native.entei"] ~= nil
    end, 4000)

    local faults = faultsFor(game, BURNED_TOWER_SCRIPT)
    Assert.equal(#faults, 0, "the beast-release scene runs its own native operations: " .. table.concat(faults, ","))
    roamers = capturedRoamers(game)
    local function assertSlot(key, slot, species, level, statusVar)
      local record = assert(roamers[key], "the scene creates the source roamer slot " .. tostring(slot))
      Assert.equal(record.native.slot, slot, "the created " .. species .. " names its source slot")
      Assert.equal(record.mon.species, species, "the created roamer is the source's " .. species)
      Assert.equal(record.mon.met.level, level, "the created " .. species .. " carries its source level")
      Assert.equal(record.lifecycle, "roaming", "the created " .. species .. " starts roaming")
      local routeIndex = RoamerSourceFacts.routeIndexOf(record)
      local region = RoamerSourceFacts.regionOf(slot)
      Assert.isTrue(
        routeIndex >= region.min and routeIndex < region.min + region.count,
        "the created " .. species .. " starts on an eligible " .. slot .. "-region route"
      )
      Assert.equal(
        record.location,
        RoamerSourceFacts.routeMapId(routeIndex),
        "the created " .. species .. " location agrees with its source route"
      )
      Assert.isTrue(
        type(record.mon.condition.currentHp) == "number" and record.mon.condition.currentHp > 0,
        "the created " .. species .. " starts at full battle health"
      )
      Assert.equal(
        game.runtime.scripts.worldState:getVar(statusVar),
        0,
        "the created " .. species .. " publishes its source status word"
      )
    end
    assertSlot("native.raikou", 0, "RAIKOU", 40, RAIKOU_STATUS_VAR)
    assertSlot("native.entei", 1, "ENTEI", 40, ENTEI_STATUS_VAR)
    Assert.isNil(roamers["native.latias"], "the Burned Tower scene creates neither Lati slot")
    Assert.isNil(roamers["native.latios"], "the Burned Tower scene creates neither Lati slot")
    local world = game.runtime.scripts.worldState
    Assert.isTrue(world:isFlagSet(RAIKOU_HIDDEN_FLAG), "the scene hides the Raikou statue before it roams")
    Assert.isTrue(world:isFlagSet(ENTEI_HIDDEN_FLAG), "the scene hides the Entei statue before it roams")
    Assert.equal(
      world:getVar(SCENE_TRIGGER_VAR),
      0,
      "the scene's own progression word stays at its pre-scene value until the scene closes"
    )
    Assert.equal(game:renderAttempts(), 0, "the scene acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- ---------------------------------------------------------------------------
-- Vermilion: the map-init Steven scene shows the version's Lati in the source
-- picture window, releases it as the roamer the game owns, closes the window
-- and finishes its authored progression.
-- ---------------------------------------------------------------------------

function T.tests.vermilion_steven_scene_releases_the_version_lati_roamer()
  local versionId = AcceptanceHarness.defaultVersion()
  local lati = assert(LATI_BY_VERSION[versionId], "the scenario names the version's Lati roamer")
  local other = lati.slot == 2 and { slot = 3, key = "native.latios" } or { slot = 2, key = "native.latias" }
  local worldState = FieldEventState.new()
  worldState:setVar(STEVEN_SCENE_VAR, STEVEN_SCENE_READY)
  local game = harnessFor(VERMILION, { fieldX = 16, fieldZ = 30 }, worldState):boot({
    versionId = versionId,
    map = VERMILION,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    game:advanceUntil("the map-init Steven scene starts", function()
      return #game:recordsForScript(VERMILION_SCRIPT, "script.started") > 0
    end, 240)

    local seenSpecies = nil
    driveScene(
      game,
      VERMILION_SCRIPT,
      "the Steven scene releases its roamer and closes its picture window",
      function(snapshot)
        local state = game.runtime.roamerState
        if state == nil then
          return false
        end
        local captured = state:capture()
        return captured ~= nil
          and captured.roamers ~= nil
          and captured.roamers[lati.key] ~= nil
          and snapshot.foregroundScript == nil
      end,
      6000
    )

    local faults = faultsFor(game, VERMILION_SCRIPT)
    Assert.equal(#faults, 0, "the Steven scene runs its own native operations: " .. table.concat(faults, ","))
    local roamers = capturedRoamers(game)
    local record = assert(roamers[lati.key], "the scene releases the " .. lati.species .. " roamer")
    Assert.equal(record.native.slot, lati.slot, "the released Lati names its source slot")
    Assert.equal(record.mon.species, lati.species, "the released roamer is the version's Lati species")
    Assert.equal(record.mon.met.level, 35, "the released Lati carries its source level")
    Assert.equal(record.lifecycle, "roaming", "the released Lati starts roaming")
    local routeIndex = RoamerSourceFacts.routeIndexOf(record)
    local region = RoamerSourceFacts.regionOf(lati.slot)
    Assert.isTrue(
      routeIndex >= region.min and routeIndex < region.min + region.count,
      "the released Lati starts on an eligible Kanto route"
    )
    Assert.isNil(roamers[other.key], "the scene creates only the version's own Lati roamer")
    -- The picture window's own source effect: the shown species is recorded as
    -- seen before the window closes again.
    Assert.isTrue(
      game.runtime.monService:hasSeenSpecies(lati.species) == true,
      "the picture window records the shown Lati as seen"
    )
    local world = game.runtime.scripts.worldState
    Assert.equal(
      world:getVar(STEVEN_SCENE_VAR),
      STEVEN_SCENE_DONE,
      "the scene finishes its authored progression after closing the window"
    )
    Assert.isTrue(world:isFlagSet(STEVEN_HIDDEN_FLAG), "the scene hides Steven once it is over")
    Assert.equal(game:renderAttempts(), 0, "the scene acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
