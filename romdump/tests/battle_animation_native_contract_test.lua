-- Stale effect generations never execute: the strict validator
-- rejects older schema generations instead of running them.

local Assert = require("tests.support.Assert")
local BattleAnimationSchema = require("libs.assets.src.battle.BattleAnimationSchema")

local T = {}

function T.stale_effect_generations_never_execute()
  local ok, _ = pcall(BattleAnimationSchema.assertEffect, {
    schema = "g4-battle-effect-v3",
    key = "stale-probe",
    catalogIdentity = "stale-probe",
    program = { entry = "main", instructions = {}, subprograms = {}, taskKinds = {} },
    dependencies = {},
    resources = {},
    requiredContext = {},
  })
  Assert.isTrue(not ok, "an older effect generation fails strict validation instead of executing")
end

return { tests = T }
