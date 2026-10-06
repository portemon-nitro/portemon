-- Independent battle-mechanics evidence bound to each ready dump: the
-- labeled native draw stream replays transcribed generator vectors with
-- exact call counts, staged damage truncates through its hand-evaluated
-- integer stages, and the ready dump binds every native move exactly once.
-- Every expected value below is transcribed from the established generator
-- recurrence, hand-evaluated from the staged Generation-IV sequence, or
-- counted against the source move range; nothing is read out of the
-- production functions under test. A shared provenance record travels with
-- each vector, and any rounding, order, or draw-consumption change must
-- surface as a reported mismatch rather than a silent pass.

local Assert = require("tests.support.Assert")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local SOURCE_REVISION = "0985e8718df4f25e64d6507d89c0c97c0d288981"

---@param name string module path under test
---@param behavior string observable behavior the module owns
---@return table the loaded module
local function requirePresent(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing conformance behavior: " .. behavior .. " (" .. name .. ")")
  assert(loaded ~= nil, "the conformance module loads")
  return loaded --[[@as table]]
end

-- Transcribed outputs of the exact generator recurrence
-- (state * 1103515245 + 24691 mod 2^32, upper 16 bits returned) as pinned
-- by the labeled-draw suite against the established generator owner
-- (libs/mons/src/gen4/Lcrng.lua, pret/pokeheartgold src/math_util.c
-- LCRandom). Fixed here by transcription, never produced by the battle
-- stream under test.
local DRAW_VECTORS = {
  {
    seed = 12345,
    labels = { "accuracy", "damage", "critical" },
    draws = { 54236, 48294, 33234 },
    final = { algorithm = "gen4-lcrng", state = 2178034914, calls = 3 },
  },
  {
    seed = 1,
    labels = { "accuracy", "damage", "critical", "effect" },
    draws = { 16838, 44065, 53998, 8119 },
    final = { algorithm = "gen4-lcrng", state = 532110581, calls = 4 },
  },
  {
    seed = 0,
    labels = { "accuracy", "damage", "critical", "effect" },
    draws = { 0, 59774, 21105, 12720 },
    final = { algorithm = "gen4-lcrng", state = 833674724, calls = 4 },
  },
}

---@param Fixture table provenance-checked fixture owner under test
---@param vector table transcribed draw vector
---@param versionId string ready dump this evidence binds to
---@return table actual draws with the exact stream capture
local function runDraws(Fixture, vector, versionId)
  local BattleRng = require("libs.battle.src.gen4.BattleRng")
  local record = {
    provenance = {
      basis = "source-derived",
      sourceRevision = SOURCE_REVISION,
      sourceLocation = "pret/pokeheartgold src/math_util.c (LCRandom)",
      evidenceIdentity = "transcribed generator vectors for seed " .. vector.seed .. " bound to " .. versionId,
      oracleMethod = "hand transcription of the exact recurrence with upper-16-bit output, cross-checked by the labeled-draw suite",
    },
    input = { seed = vector.seed, labels = vector.labels },
    expected = { draws = vector.draws, capture = vector.final },
  }
  Fixture.validate(record)
  local stream = BattleRng.new(record.input.seed)
  local draws = {}
  for index, label in ipairs(record.input.labels) do
    draws[#draws + 1] = stream:nextU16(label, { kind = "conformance_probe", index = index })
  end
  return Fixture.run(function()
    return { draws = draws, capture = stream:capture() }
  end, record)
end

function T.native_draw_streams_replay_transcribed_vectors_and_reject_extra_draws(romFs, versionId)
  Assert.notNil(romFs, "the draw oracle runs with its ready dump open")
  local Fixture = requirePresent("tests.support.BattleFidelityFixture", "independent fixture and provenance validation")
  Assert.isTrue(type(Fixture.validate) == "function", "fixtures own provenance validation")
  Assert.isTrue(type(Fixture.run) == "function", "fixtures own oracle execution")
  Assert.isTrue(type(Fixture.compare) == "function", "fixtures own mismatch comparison")
  for _, vector in ipairs(DRAW_VECTORS) do
    local actual = runDraws(Fixture, vector, versionId)
    local mismatch = Fixture.compare(actual, {
      expected = { draws = vector.draws, capture = vector.final },
    })
    Assert.isNil(mismatch, versionId .. " seed " .. vector.seed .. " replays its transcribed draws exactly")
  end

  local BattleRng = require("libs.battle.src.gen4.BattleRng")
  local drifted = BattleRng.new(DRAW_VECTORS[1].seed)
  local driftedDraws = {}
  for index, label in ipairs(DRAW_VECTORS[1].labels) do
    driftedDraws[#driftedDraws + 1] = drifted:nextU16(label, { kind = "conformance_probe", index = index })
  end
  driftedDraws[#driftedDraws + 1] = drifted:nextU16("accuracy", { kind = "conformance_probe", index = 99 })
  local drift = Fixture.compare({ draws = driftedDraws, capture = drifted:capture() }, {
    expected = { draws = DRAW_VECTORS[1].draws, capture = DRAW_VECTORS[1].final },
  })
  Assert.isTrue(type(drift) == "table", "one extra draw reports its mismatch")
  Assert.notNil(drift.expected, "draw mismatches carry the expected stream record")
  Assert.notNil(drift.actual, "draw mismatches carry the actual stream record")

  local incomplete = { input = { seed = 1 }, expected = { draws = {} } }
  Assert.throws(function()
    Fixture.validate(incomplete)
  end, "vectors without provenance never validate")
end

-- Level 50, power 80, attack 120, defense 90, neutral modifiers, maximum
-- roll: floor(2*50/5+2) = 22; floor(22*80*120/90) = 2346;
-- floor(2346/50)+2 = 48; every later stage holds 48. Hand-evaluated from
-- the staged Generation-IV operation sequence
-- (pret/pokeheartgold src/battle/battle_command.c, staged damage
-- application) and pinned by the staged damage vector suite, never read
-- out of the implementation under test.
local DAMAGE_CASE = {
  level = 50,
  power = 80,
  attack = 120,
  defense = 90,
  rawAttack = 120,
  rawDefense = 90,
  attackStage = 0,
  defenseStage = 0,
  criticalMultiplier = 1,
  category = "physical",
  burned = false,
  guts = false,
  stab = { numerator = 1, denominator = 1 },
  effectiveness = { numerator = 1, denominator = 1 },
  effectivenessFactors = { { numerator = 1, denominator = 1 } },
  weather = "none",
  weatherSuppressed = false,
  moveType = "normal",
  solarBeam = false,
  randomPercent = 100,
}

function T.staged_damage_truncation_matches_hand_evaluated_stages(romFs, versionId)
  Assert.notNil(romFs, "the arithmetic oracle runs with its ready dump open")
  local Fixture = requirePresent("tests.support.BattleFidelityFixture", "independent fixture and provenance validation")
  local Damage = require("libs.battle.src.gen4.Damage")
  local BattleRng = require("libs.battle.src.gen4.BattleRng")
  local record = {
    provenance = {
      basis = "source-derived",
      sourceRevision = SOURCE_REVISION,
      sourceLocation = "pret/pokeheartgold src/battle/battle_command.c (staged damage application)",
      evidenceIdentity = "hand-evaluated base truncation bound to " .. versionId,
      oracleMethod = "hand evaluation of the staged multiply/divide truncation order, cross-checked by the staged damage vector suite",
    },
    input = DAMAGE_CASE,
    expected = {
      amount = 48,
      critical = false,
      effectiveness = { numerator = 1, denominator = 1 },
    },
  }
  Fixture.validate(record)
  local stream = BattleRng.new(4242)
  local before = stream:capture()
  local actual = Fixture.run(function()
    return Damage.calculate(record.input, stream)
  end, record)
  local mismatch = Fixture.compare(actual, { expected = record.expected })
  Assert.isNil(mismatch, versionId .. " truncates the hand-evaluated damage stages exactly")
  Assert.deepEqual(stream:capture(), before, "the fixed maximum roll consumes no draws")

  local traced = Damage.trace(DAMAGE_CASE, BattleRng.new(4242))
  Assert.equal(traced.amount, 48, "the traced path agrees on the hand-evaluated amount")
  Assert.equal(traced.stages[1].name, "base", "stages open with the base truncation")
  Assert.equal(traced.stages[1].output, 46, "the base stage truncates to the hand-evaluated pre-bonus value")

  local collapsed = Fixture.compare({ amount = 49 }, { expected = { amount = 48 } })
  Assert.isTrue(type(collapsed) == "table", "a wrong rounding stage reports its mismatch")
  Assert.equal(collapsed.expected.amount, 48, "arithmetic mismatches carry the expected stage value")
  Assert.equal(collapsed.actual.amount, 49, "arithmetic mismatches carry the actual stage value")
end

function T.ready_dumps_bind_every_native_move_exactly_once(romFs, versionId)
  local Fixture = requirePresent("tests.support.BattleFidelityFixture", "independent fixture and provenance validation")
  local MonSources = require("romdump.src.config.MonSources")
  local BattleDataCompiler = require("romdump.src.digest.battle.BattleDataCompiler")
  local record = {
    provenance = {
      basis = "observed-rom",
      sourceRevision = versionId,
      sourceLocation = "user-owned dump, compiled native battle data",
      evidenceIdentity = "native move inventory of the ready " .. versionId .. " dump",
      oracleMethod = "decoder output counted against the source move range through the shared battle-data schema",
    },
    input = { versionId = versionId },
    expected = { nativeMoves = MonSources.NUM_MOVES },
  }
  Fixture.validate(record)
  local actual = Fixture.run(function()
    local compiled = assert(BattleDataCompiler.compileFromDump(romFs, { versionId = versionId }))
    local seen = {}
    for key, facts in pairs(compiled.moves) do
      Assert.isTrue(type(facts.behavior.key) == "string" and facts.behavior.key ~= "", key .. " needs a behavior key")
      Assert.isNil(seen[key], "move " .. key .. " resolves exactly once")
      seen[key] = true
    end
    Assert.isNil(seen["NONE"], "the NONE sentinel is not a usable combat move")
    local count = 0
    for moveId = 1, MonSources.NUM_MOVES do
      local key = MonSources.moveKeys[moveId]
      Assert.notNil(seen[key], "native move " .. moveId .. " must resolve")
      count = count + 1
    end
    return { nativeMoves = count }
  end, record)
  local inventoryMismatch = Fixture.compare(actual, { expected = record.expected })
  Assert.isNil(inventoryMismatch, versionId .. " binds every native move exactly once")
end

return RomSuite.fromFacts(T)
