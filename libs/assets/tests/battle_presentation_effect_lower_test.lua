-- Lower-level effect contract checks: numeric ranges stay bounded, the
-- explicit terrain alias normalizes, resource kinds stay closed, context
-- stays typed, and effect paths live inside the existing battle family
-- without aliasing scenes. Fixtures are synthetic.

local Assert = require("tests.support.Assert")

local T = {}

local function animationSchema()
  return require("libs.assets.src.battle.BattleAnimationSchema")
end

local function presentationCache()
  return require("libs.assets.src.battle.BattlePresentationCache")
end

local function baseEffect()
  return {
    schema = "g4-battle-effect-v1",
    key = "synthetic-lower-probe",
    catalogIdentity = "synthetic-catalog",
    program = {
      entry = "main",
      instructions = {
        { op = "branch-on-interpreter-state", values = { 1 }, branchTarget = 2, alternateTarget = 2 },
        {
          op = "start-visual-task",
          taskKind = "battle-background-blend-transition",
          values = { 4 },
        },
      },
      subprograms = {},
      taskKinds = { "battle-background-blend-transition" },
    },
    dependencies = { "synthetic-sound" },
    resources = {
      ["synthetic-sound"] = {
        kind = "sound",
        contentIdentity = string.rep("a", 40),
        payload = "synthetic-sound-path",
      },
    },
    requiredContext = {
      actors = { type = "battle-actors" },
      targets = { type = "target-actors" },
      attackerPosition = { type = "battler-position" },
      targetPosition = { type = "battler-position" },
    },
  }
end

function T.branch_targets_and_operands_keep_their_typed_ranges()
  local Schema = animationSchema()
  Assert.isTrue(Schema.isValidEffect(baseEffect()), "the base effect validates")
  local invalidTarget = baseEffect()
  invalidTarget.program.instructions[1].branchTarget = 0
  Assert.isFalse(Schema.isValidEffect(invalidTarget), "branch targets stay one-based")
  local fractional = baseEffect()
  fractional.program.instructions[2].values[1] = 1.5
  Assert.isFalse(Schema.isValidEffect(fractional), "semantic operands stay integral")
end

function T.aliases_normalize_while_unknown_kinds_stay_rejected()
  local Schema = animationSchema()
  local aliased = baseEffect()
  aliased.resources["synthetic-model"] = {
    kind = "model",
    contentIdentity = string.rep("b", 40),
    payload = "synthetic-model-path",
  }
  aliased.dependencies[#aliased.dependencies + 1] = "synthetic-model"
  Assert.isTrue(Schema.isValidEffect(aliased), "a closed model alias validates")
  local unknown = baseEffect()
  unknown.resources["synthetic-mystery"] = {
    kind = "mystery",
    contentIdentity = string.rep("c", 40),
    payload = "x",
  }
  Assert.isFalse(Schema.isValidEffect(unknown), "unknown resource kinds never validate")
  local untyped = baseEffect()
  untyped.requiredContext = { battle = {} }
  Assert.isFalse(Schema.isValidEffect(untyped), "untyped context never validates")
  local native = baseEffect()
  native.program.instructions[1].nativeOpcode = 3
  Assert.isFalse(Schema.isValidEffect(native), "dispatch identities never validate")
end

function T.effect_paths_stay_inside_the_existing_family()
  local Cache = presentationCache()
  local path = Cache.effectPath("synthetic-lower-probe")
  local marker = Cache.effectMarkerPath("synthetic-lower-probe")
  Assert.isTrue(path:find("battle", 1, true) ~= nil, "effect payloads never form a second root: " .. path)
  Assert.isTrue(marker:find("battle", 1, true) ~= nil, "effect markers never form a second root: " .. marker)
  Assert.isTrue(marker ~= path, "markers stay beside their payload")
  Assert.isTrue(Cache.scenePath("general/grass/day") ~= path, "effect paths never alias scene paths")
  local ok, _ = pcall(function()
    Cache.effectPath("has/slash")
  end)
  Assert.isFalse(ok, "slashed effect keys never resolve")
end

return { tests = T }
