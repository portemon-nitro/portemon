-- Script spawn-update coverage: the explicit set_spawn command records
-- named respawn history on the required injected travel service while the
-- maps service keeps its spawn string, and generic party healing never
-- touches durable travel facts. A missing travel service faults with
-- attribution instead of silently keeping the old spawn.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldTravelState = require("libs.hgss.src.field.FieldTravelState")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")

local T = {}

local function travelService()
  return FieldTravelState.new({ lastHealSpawn = FieldTravelState.DEFAULT_LAST_HEAL_SPAWN })
end

local function runWith(services)
  local world = {
    vars = {},
    getVar = function(self, id)
      return self.vars[id]
    end,
    setVar = function(self, id, value)
      self.vars[id] = value
    end,
  }
  services = services or {}
  services.world = world
  return {
    instance = { scriptId = "test.spawn", locals = {}, textArgs = {} },
    services = services,
    semantics = RuntimeValues,
  }
end

local function mapsService()
  local service = { spawns = {} }
  function service:setSpawn(spawn)
    self.spawns[#self.spawns + 1] = spawn
  end
  return service
end

local function monsService()
  local service = { heals = 0 }
  function service:healParty()
    self.heals = self.heals + 1
  end
  return service
end

function T.set_spawn_records_named_history_on_the_travel_service()
  local travel = travelService()
  local maps = mapsService()
  local run = runWith({ maps = maps, travel = travel })
  Assert.equal(Runtime.executeNode({ op = "set_spawn", spawn = "SPAWN_GOLDENROD" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(travel:capture().lastHealSpawn, "SPAWN_GOLDENROD", "the explicit command updates travel")
  Assert.deepEqual(maps.spawns, { "SPAWN_GOLDENROD" }, "the maps service keeps its spawn string")
end

function T.missing_travel_service_faults_with_attribution()
  local run = runWith({ maps = mapsService() })
  local ok, err = pcall(function()
    Runtime.executeNode({ op = "set_spawn", spawn = "SPAWN_GOLDENROD" }, run)
  end)
  Assert.isFalse(ok, "spawn updates without a travel service must not silently keep the old spawn")
  Assert.isTrue(Errors.is(err))
  ---@cast err Errors.Error
  Assert.equal(err.code, "SCRIPT_SERVICE_MISSING")
end

function T.generic_healing_never_touches_travel_facts()
  local travel = travelService()
  local mons = monsService()
  local run = runWith({ mons = mons, travel = travel })
  Assert.equal(Runtime.executeNode({ op = "heal_party" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(mons.heals, 1, "healing still runs")
  Assert.equal(
    travel:capture().lastHealSpawn,
    FieldTravelState.DEFAULT_LAST_HEAL_SPAWN,
    "generic healing must not rewrite respawn history"
  )
  Assert.isNil(travel:capture().escapeEntrance, "generic healing must not invent entrances")
end

return { tests = T }
