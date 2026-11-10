-- Independently requested battle effect artifacts carry one closed executable
-- program with typed context. Records stay source-independent: native
-- identities never validate. Fixtures are synthetic.

local Assert = require("tests.support.Assert")

local T = {}

---@return table|nil
local function tryLoad(name)
  local ok, module = pcall(require, name)
  if ok and type(module) == "table" then
    return module
  end
  return nil
end

local function animationSchema()
  return tryLoad("libs.assets.src.battle.BattleAnimationSchema")
end

local function presentationCache()
  return require("libs.assets.src.battle.BattlePresentationCache")
end

local function assetContract()
  return require("libs.assets.src.DerivedAssetContract")
end

local function effectArtifact()
  return {
    schema = "g4-battle-effect-v5",
    key = "synthetic-effect-probe",
    catalogIdentity = "synthetic-catalog",
    program = {
      entry = "main",
      instructions = {
        { op = "interpreter-wait", values = { 2 } },
        { op = "start-visual-task", taskKind = "battle-background-blend-transition", values = { 4 } },
      },
      subprograms = {},
      taskKinds = { "battle-background-blend-transition" },
    },
    dependencies = { "synthetic-palette", "synthetic-texture" },
    resources = {
      ["synthetic-palette"] = {
        kind = "palette",
        payload = "synthetic-palette-path",
        contentIdentity = string.rep("a", 40),
      },
      ["synthetic-texture"] = {
        kind = "texture",
        payload = "synthetic-texture-path",
        contentIdentity = string.rep("b", 40),
      },
    },
    requiredContext = {
      actors = { type = "battle-actors" },
    },
    displayPolicy = { suspendHealthbarUpdates = true, updateBattlerG3 = false },
  }
end

function T.effect_artifacts_carry_closed_programs_and_typed_context()
  local Schema = animationSchema()
  Assert.isTrue(Schema ~= nil, "no normalized effect and particle schema owns the executable program contract")
  assert(Schema ~= nil, "the effect schema carries its validation")
  Assert.isTrue(type(Schema.assertEffect) == "function", "the effect schema validates effect artifacts")
  Assert.isTrue(type(Schema.isValidEffect) == "function", "the effect schema reports validity")
  assert(Schema.assertEffect ~= nil and Schema.isValidEffect ~= nil, "effect validation is available")
  local valid, failure = Schema.isValidEffect(effectArtifact())
  Assert.isTrue(valid, "a closed synthetic effect validates: " .. tostring(failure))
  local open = effectArtifact()
  open.program.instructions[1].nativeOpcode = 12
  Assert.isFalse(Schema.isValidEffect(open), "native dispatch identities never validate in programs")
  local untyped = effectArtifact()
  untyped.requiredContext = { battle = {} }
  Assert.isFalse(Schema.isValidEffect(untyped), "effect context never reaches arbitrary battle or field objects")
  local unknownKind = effectArtifact()
  unknownKind.resources["synthetic-palette"] = { kind = "mystery" }
  Assert.isFalse(Schema.isValidEffect(unknownKind), "unknown resource kinds never validate")
end

function T.effect_artifacts_carry_their_complete_root_display_policy()
  local Schema = animationSchema()
  assert(Schema ~= nil, "the effect schema is available")
  local artifact = effectArtifact()
  Assert.deepEqual(
    artifact.displayPolicy,
    { suspendHealthbarUpdates = true, updateBattlerG3 = false },
    "the fixture carries the complete root display policy"
  )
  local valid, failure = Schema.isValidEffect(artifact)
  Assert.isTrue(valid, "a closed synthetic effect with its policy validates: " .. tostring(failure))
  local missing = effectArtifact()
  missing.displayPolicy = nil
  Assert.isFalse(Schema.isValidEffect(missing), "a root without its display policy never validates")
  local partial = effectArtifact()
  partial.displayPolicy = { suspendHealthbarUpdates = true }
  Assert.isFalse(Schema.isValidEffect(partial), "a half-named display policy never validates")
  local invented = effectArtifact()
  invented.displayPolicy = { suspendHealthbarUpdates = true, updateBattlerG3 = false, hideHud = true }
  Assert.isFalse(Schema.isValidEffect(invented), "a display policy with extra fields never validates")
  local guessed = effectArtifact()
  guessed.displayPolicy = { suspendHealthbarUpdates = 1, updateBattlerG3 = false }
  Assert.isFalse(Schema.isValidEffect(guessed), "a non-boolean display policy never validates")
end

function T.visual_task_background_load_carries_its_staged_slots()
  local Schema = animationSchema()
  assert(Schema ~= nil, "the effect schema is available")
  local artifact = effectArtifact()
  artifact.program.instructions[2] = {
    op = "start-visual-task",
    taskKind = "battle-background-resource-load",
    values = { 9, 0x1234 },
    resourceKeys = {
      character = "synthetic-bg-character",
      palette = "synthetic-bg-palette",
      screenDefault = "synthetic-bg-screen-default",
      screenAlternate = "synthetic-bg-screen-alternate",
    },
    runtimeSelection = "battle-background-screen-selection",
  }
  artifact.program.taskKinds = { "battle-background-resource-load" }
  artifact.dependencies = {
    "synthetic-bg-character",
    "synthetic-bg-palette",
    "synthetic-bg-screen-default",
    "synthetic-bg-screen-alternate",
  }
  artifact.resources = {
    ["synthetic-bg-character"] = {
      kind = "tiles",
      payload = "synthetic-bg-character-path",
      contentIdentity = string.rep("c", 40),
    },
    ["synthetic-bg-palette"] = {
      kind = "palette",
      payload = "synthetic-bg-palette-path",
      contentIdentity = string.rep("d", 40),
    },
    ["synthetic-bg-screen-default"] = {
      kind = "map",
      payload = "synthetic-bg-screen-default-path",
      contentIdentity = string.rep("e", 40),
    },
    ["synthetic-bg-screen-alternate"] = {
      kind = "map",
      payload = "synthetic-bg-screen-alternate-path",
      contentIdentity = string.rep("f", 40),
    },
  }
  local valid, failure = Schema.isValidEffect(artifact)
  Assert.isTrue(valid, "a staged background load validates: " .. tostring(failure))
  local partial = effectArtifact()
  partial.program.instructions[2] = {
    op = "start-visual-task",
    taskKind = "battle-background-resource-load",
    values = { 9, 0x1234 },
    resourceKeys = { character = "synthetic-bg-character" },
    runtimeSelection = "battle-background-screen-selection",
  }
  Assert.isFalse(
    Schema.isValidEffect(partial),
    "a background load with an incomplete slot closure never validates"
  )
end

function T.effect_cache_paths_live_in_the_existing_family()
  local Cache = presentationCache()
  Assert.isTrue(
    type(Cache.effectPath) == "function",
    "the presentation cache addresses independently requested effect artifacts"
  )
  Assert.isTrue(
    type(Cache.effectMarkerPath) == "function",
    "effect artifacts carry their own completion markers inside the existing family"
  )
  assert(Cache.effectPath ~= nil and Cache.effectMarkerPath ~= nil, "effect paths are available")
  local path = Cache.effectPath("synthetic-effect-probe")
  Assert.isTrue(type(path) == "string" and path ~= "", "effect paths resolve inside the existing family")
  Assert.isTrue(path:find("battle", 1, true) ~= nil, "effect artifacts never form a second asset root: " .. path)
  local marker = Cache.effectMarkerPath("synthetic-effect-probe")
  Assert.isTrue(marker ~= path, "effect markers stay beside their payload")
end

function T.generated_contract_mirrors_the_effect_schema_identity()
  local Schema = animationSchema()
  assert(Schema ~= nil, "the effect schema is available")
  Assert.equal(
    assetContract().battlePresentation.effectSchema,
    Schema.EFFECT_SCHEMA,
    "the validator and the generated contract agree on one effect identity"
  )
end

function T.stale_effect_artifacts_never_validate()
  local Schema = animationSchema()
  Assert.isTrue(Schema ~= nil, "the effect schema owns the executable program contract")
  assert(Schema ~= nil, "the effect schema is available")
  local stale = effectArtifact()
  stale.schema = "g4-battle-effect-v1"
  Assert.equal(stale.schema, "g4-battle-effect-v1", "the stale fixture predates normalization")
  Assert.isFalse(
    Schema.isValidEffect(stale),
    "the previous raw-emitter artifact no longer validates and regenerates lazily"
  )
end

return { tests = T }
