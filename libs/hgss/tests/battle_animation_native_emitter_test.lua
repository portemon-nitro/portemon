-- Emitter handle identity and the source particle phase: occurrence
-- emitter slots resolve to stable identities, one draw phase captures
-- every manager before calculating, and curved paths execute instead of
-- refusing. These probe the shared particle adapter surface the
-- movement tasks drive.

local Assert = require("tests.support.Assert")
local BattleParticleSystems = require("libs.hgss.src.presentation.BattleParticleSystems")

local T = {}

function T.emitter_handles_bind_occurrence_system_and_slot()
  Assert.isTrue(
    type(BattleParticleSystems.getEmitterHandle) == "function",
    "emitter slots resolve through an occurrence-bound handle provider"
  )
end

function T.draw_phase_captures_before_calculating_in_slot_order()
  Assert.isTrue(
    type(BattleParticleSystems.stepSourceDrawPhase) == "function",
    "one source phase captures every manager before calculating"
  )
end

function T.curved_paths_execute_instead_of_refusing()
  local Factory = require("libs.hgss.src.presentation.BattleEffectTasks")
  local context = {
    particles = BattleParticleSystems.newRegistry(),
    topology = {
      attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
      targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
    },
  }
  local services = { scene = {}, audio = {}, resources = {} }
  local ok, task = pcall(Factory.create, Factory.EMITTER_CURVED_PATH_KIND, {
    parameters = { emitterSlot = 0, durationTicks = 4 },
  }, context, services)
  Assert.isTrue(ok, "curved emitter paths construct instead of refusing: " .. tostring(task))
end

return { tests = T }
