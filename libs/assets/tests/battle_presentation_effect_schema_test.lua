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
    schema = "g4-battle-effect-v3",
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

function T.contract_identities_version_the_new_catalog_shapes()
  local Contract = assetContract()
  Assert.equal(
    Contract.battlePresentation.schema,
    "g4-battle-presentation-v5",
    "the shared contract versions the normalized global catalog"
  )
  Assert.equal(
    Contract.battlePresentation.sceneSchema,
    "g4-battle-scene-v2",
    "the shared contract versions scenes with backing and provenance facts"
  )
  Assert.isTrue(
    type(Contract.battlePresentation.effectSchema) == "string" and Contract.battlePresentation.effectSchema ~= "",
    "the shared contract versions independently requested effect artifacts"
  )
end

function T.effect_schema_versions_the_normalized_particle_contract()
  local Schema = animationSchema()
  Assert.isTrue(Schema ~= nil, "the effect schema owns the executable program contract")
  assert(Schema ~= nil, "the effect schema is available")
  Assert.equal(
    Schema.EFFECT_SCHEMA,
    "g4-battle-effect-v3",
    "the effect schema carries the normalized particle contract identity"
  )
  local Contract = assetContract()
  Assert.equal(
    Contract.battlePresentation.effectSchema,
    "g4-battle-effect-v3",
    "the generated contract mirrors the normalized effect schema"
  )
  Assert.equal(
    Contract.battlePresentation.effectSchema,
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
