-- Thrown balls keep the exact native catch arithmetic: each ball reads only
-- its own source facts at exact thresholds, the integer odds stages floor in
-- source order, shake checks consume one labeled draw per check until the
-- first failure, and guaranteed throws spend no draws. Later-generation
-- shortcuts such as critical captures or experience on catch do not exist.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

---@param behavior string missing owner under test
---@return table the loaded catch calculator
local function captureOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.Capture", behavior)
end

---@param behavior string missing owner under test
---@return table the loaded capture environment owner
local function contextOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.CaptureContext", behavior)
end

---@param values integer[] scripted draw results in consumption order
---@return table stream double with labeled-draw accounting
local function scriptedStream(values)
  local used = 0
  local labels = {}
  return {
    nextU16 = function(self, label, cause)
      assert(self ~= nil, "draws arrive through the stream")
      assert(type(label) == "string" and label ~= "", "shake draws name their call site")
      assert(type(cause) == "table", "shake draws carry their semantic cause")
      used = used + 1
      labels[#labels + 1] = label
      return values[used] or 0
    end,
    capture = function()
      return { used = used, labels = labels }
    end,
  }
end

---@param overrides table<string, unknown>|nil field replacements for this target
---@return table wild target facts with full health and no status
local function targetFacts(overrides)
  local facts = {
    catchRate = 45,
    maxHp = 100,
    hp = 100,
    status = "healthy",
    species = "PIKACHU",
    types = { "electric" },
    level = 20,
    weight = 60,
    baseSpeed = 90,
    gender = "male",
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      facts[key] = value
    end
  end
  return facts
end

---@param overrides table<string, unknown>|nil field replacements for this encounter
---@return table open wild encounter environment on the first turn
local function wildEnv(overrides)
  local env = {
    mode = "wild",
    turns = 0,
    pokedexCaught = false,
    attackerLevel = 20,
    attackerSpecies = "PIDGEY",
    attackerGender = "female",
    method = "land",
    fished = false,
    timeOfDay = "day",
    inCave = false,
    backdrop = "field",
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      env[key] = value
    end
  end
  return env
end

---@param ball string ball key under test
---@param target table<string, unknown>|nil target facts under test
---@param env table<string, unknown>|nil encounter environment under test
---@param values integer[] scripted draw results in consumption order
---@return table calculation with its stream accounting
local function calculate(ball, target, env, values)
  local Capture = captureOwner("exact catch and shake arithmetic owns thrown balls")
  local Context = contextOwner("typed capture environments own the facts each ball reads")
  local context = Context.forBall(ball, target or targetFacts(), env or wildEnv())
  local attempt = { actor = 1, inventoryId = "party", ball = ball, target = { combatant = 2 } }
  local stream = scriptedStream(values)
  local calc = Capture.calculate(attempt, context, stream)
  local accounting = stream:capture()
  return { calc = calc, used = accounting.used, labels = accounting.labels }
end

-- The health factor floors before any status is applied: full health holds
-- the base odds while one remaining hit point nearly triples them.
function T.plain_throws_floor_the_health_factor_before_any_status()
  local full = calculate("POKE_BALL", targetFacts({ hp = 100 }), wildEnv(), { 0, 0, 0 })
  Assert.equal(full.calc.odds, 15, "full health keeps the base odds")
  local weak = calculate("POKE_BALL", targetFacts({ hp = 1 }), wildEnv(), { 0, 0, 0 })
  Assert.equal(weak.calc.odds, 44, "one hit point nearly triples the odds")
end

-- Sleep and freeze double the odds while burn, paralysis, and poison add
-- exactly half, each on the same weakened target.
function T.sleep_and_freeze_double_while_minor_status_adds_half()
  local cases = {
    { status = "asleep", odds = 88 },
    { status = "frozen", odds = 88 },
    { status = "burned", odds = 66 },
    { status = "paralyzed", odds = 66 },
    { status = "poisoned", odds = 66 },
  }
  for _, case in ipairs(cases) do
    local outcome = calculate("POKE_BALL", targetFacts({ hp = 1, status = case.status }), wildEnv(), { 0, 0, 0 })
    Assert.equal(outcome.calc.odds, case.odds, case.status .. " applies its own stage")
  end
end

-- The half bonus floors down on odd odds: 79 becomes 118, never 119.
function T.odd_odds_floor_the_half_bonus_down()
  local outcome =
    calculate("POKE_BALL", targetFacts({ hp = 31, catchRate = 100, status = "burned" }), wildEnv(), { 0, 0, 0 })
  Assert.equal(outcome.calc.odds, 118, "the half bonus floors in integer order")
end

-- Great, Safari, and Sport balls share the half bonus on the base target.
function T.great_safari_and_sport_share_the_half_bonus()
  for _, ball in ipairs({ "GREAT_BALL", "SAFARI_BALL", "SPORT_BALL" }) do
    local outcome = calculate(ball, targetFacts(), wildEnv(), { 0, 0, 0 })
    Assert.equal(outcome.calc.odds, 22, ball .. " applies the half bonus")
  end
end

-- The Ultra Ball doubles the base odds exactly.
function T.ultra_ball_doubles_the_odds()
  local outcome = calculate("ULTRA_BALL", targetFacts(), wildEnv(), { 0, 0, 0 })
  Assert.equal(outcome.calc.odds, 30, "the ultra multiplier doubles the odds")
end

-- Master and Park throws land without consulting odds or the stream, even
-- against a nearly uncatchable target.
function T.master_and_park_throws_land_without_odds_or_draws()
  for _, ball in ipairs({ "MASTER_BALL", "PARK_BALL" }) do
    local outcome = calculate(ball, targetFacts({ catchRate = 3 }), wildEnv(), { 65535 })
    Assert.isTrue(outcome.calc.success, ball .. " always succeeds")
    Assert.equal(outcome.calc.shakes, 3, ball .. " reports full shakes")
    Assert.equal(outcome.used, 0, ball .. " spends no draw")
    Assert.isNil(outcome.calc.threshold, ball .. " computes no shake threshold")
  end
end

-- Full odds guarantee the catch with no shake math: the doubled Ultra odds
-- land while the weaker Great and plain odds on the same sleeping target
-- still shake with exact staged thresholds.
function T.full_odds_guarantee_while_weaker_odds_keep_exact_thresholds()
  local target = targetFacts({ catchRate = 100, maxHp = 100, hp = 30, status = "asleep" })
  local ultra = calculate("ULTRA_BALL", target, wildEnv(), { 65535 })
  Assert.equal(ultra.calc.odds, 320, "the doubled ultra odds are staged exactly")
  Assert.isTrue(ultra.calc.success, "full odds guarantee the catch")
  Assert.equal(ultra.calc.shakes, 3, "a guaranteed catch reports full shakes")
  Assert.equal(ultra.used, 0, "a guaranteed catch spends no draw")
  Assert.isNil(ultra.calc.threshold, "a guaranteed catch computes no shake threshold")
  local great = calculate("GREAT_BALL", target, wildEnv(), { 0, 0, 0 })
  Assert.equal(great.calc.odds, 240, "the great odds are staged exactly")
  Assert.equal(great.calc.threshold, 65535, "the great threshold is staged exactly")
  Assert.isTrue(great.calc.success, "the scripted tape lands every shake")
  Assert.equal(great.used, 3, "a shaken catch spends one draw per shake")
  local plain = calculate("POKE_BALL", target, wildEnv(), { 0, 0, 0 })
  Assert.equal(plain.calc.odds, 160, "the plain odds are staged exactly")
  Assert.equal(plain.calc.threshold, 61680, "the plain threshold is staged exactly")
  Assert.isTrue(plain.calc.success, "the scripted tape lands every shake")
  Assert.equal(plain.used, 3, "a shaken catch spends one draw per shake")
end

-- Odds one step below guaranteed still shake: 253 keeps the highest live
-- threshold, so a hostile draw breaks out immediately while a kind tape
-- lands all three shakes.
function T.near_guaranteed_odds_still_shake()
  local target = targetFacts({ catchRate = 255, maxHp = 100, hp = 1 })
  local hostile = calculate("POKE_BALL", target, wildEnv(), { 65535 })
  Assert.equal(hostile.calc.odds, 253, "the odds stop one step below guaranteed")
  Assert.equal(hostile.calc.threshold, 65535, "the threshold keeps its highest live value")
  Assert.isFalse(hostile.calc.success, "a hostile draw breaks out at once")
  Assert.equal(hostile.calc.shakes, 0, "a hostile draw shakes never")
  Assert.equal(hostile.used, 1, "an instant breakout spends exactly one draw")
  local kind = calculate("POKE_BALL", target, wildEnv(), { 0, 0, 0 })
  Assert.isTrue(kind.calc.success, "a kind tape lands every shake")
  Assert.equal(kind.calc.shakes, 3, "a landed catch reports full shakes")
  Assert.equal(kind.used, 3, "a landed catch spends one draw per shake")
end

-- Each shake check consumes exactly one draw until the first failure: the
-- tape decides the shake count and the draw count together.
function T.shake_tape_decides_each_check_in_order()
  local target = targetFacts({ hp = 1 })
  local second = calculate("POKE_BALL", target, wildEnv(), { 0, 65535, 0 })
  Assert.isFalse(second.calc.success, "the second check breaks the catch")
  Assert.equal(second.calc.shakes, 1, "one landed check shakes once")
  Assert.equal(second.used, 2, "a second-check breakout spends two draws")
  local third = calculate("POKE_BALL", target, wildEnv(), { 0, 0, 65535 })
  Assert.isFalse(third.calc.success, "the third check breaks the catch")
  Assert.equal(third.calc.shakes, 2, "two landed checks shake twice")
  Assert.equal(third.used, 3, "a third-check breakout spends three draws")
end

-- Every shake draw names the same call site: three ordered shakes arrive
-- through one labeled shake stage.
function T.shake_draws_share_one_labeled_call_site()
  local outcome = calculate("POKE_BALL", targetFacts({ hp = 1 }), wildEnv(), { 0, 0, 0 })
  Assert.isTrue(outcome.calc.success, "the kind tape lands every shake")
  Assert.equal(outcome.used, 3, "a landed catch spends one draw per shake")
  Assert.equal(#outcome.labels, 3, "each shake draw is labeled")
  Assert.equal(outcome.labels[1], outcome.labels[2], "shake draws share one call site")
  Assert.equal(outcome.labels[2], outcome.labels[3], "shake draws share one call site")
end

-- Success always means three shakes and failure always means fewer: no
-- shortcut path can land a catch on a single draw.
function T.success_means_three_shakes_and_failure_means_fewer()
  local target = targetFacts({ hp = 1 })
  local tapes = { { 0, 0, 0 }, { 65535 }, { 0, 65535 }, { 0, 0, 65535 }, { 0, 0, 0, 0 } }
  for _, tape in ipairs(tapes) do
    local outcome = calculate("POKE_BALL", target, wildEnv(), tape)
    Assert.isTrue(outcome.calc.shakes <= 3, "no throw ever shakes more than three times")
    if outcome.calc.success then
      Assert.equal(outcome.calc.shakes, 3, "success always reports three shakes")
      Assert.equal(outcome.used, 3, "success always spends three draws")
    else
      Assert.isTrue(outcome.calc.shakes < 3, "failure always reports fewer than three shakes")
      Assert.equal(outcome.used, outcome.calc.shakes + 1, "failure spends one draw per shake plus the miss")
    end
  end
end

-- The Heavy Ball adjusts the rate by weight at exact hectogram stages:
-- below 2048 it subtracts, then it adds 20, 30, and 40 per stage, and the
-- subtraction floors near zero on light targets without going negative.
function T.heavy_ball_follows_the_weight_stages()
  local cases = {
    { weight = 2047, odds = 8 },
    { weight = 2048, odds = 21 },
    { weight = 3071, odds = 21 },
    { weight = 3072, odds = 25 },
    { weight = 4095, odds = 25 },
    { weight = 4096, odds = 28 },
  }
  for _, case in ipairs(cases) do
    local outcome = calculate("HEAVY_BALL", targetFacts({ weight = case.weight }), wildEnv(), { 0, 0, 0 })
    Assert.equal(outcome.calc.odds, case.odds, "weight " .. case.weight .. " stages exactly")
  end
  local light = calculate("HEAVY_BALL", targetFacts({ catchRate = 30, weight = 100 }), wildEnv(), { 0, 0, 0 })
  Assert.equal(light.calc.odds, 3, "the light subtraction floors without going negative")
end

-- The Nest Ball stages by target level: triple at 11, double through 21,
-- single from 22 on, with the below-one result clamped at 32.
function T.nest_ball_follows_the_level_stages()
  local cases = {
    { level = 11, odds = 100 },
    { level = 12, odds = 66 },
    { level = 21, odds = 66 },
    { level = 22, odds = 33 },
    { level = 32, odds = 33 },
  }
  for _, case in ipairs(cases) do
    local outcome = calculate("NEST_BALL", targetFacts({ catchRate = 100, level = case.level }), wildEnv(), { 0, 0, 0 })
    Assert.equal(outcome.calc.odds, case.odds, "level " .. case.level .. " stages exactly")
  end
  local staged = calculate("NEST_BALL", targetFacts({ catchRate = 100, level = 11 }), wildEnv(), { 0, 0, 0 })
  Assert.equal(staged.calc.threshold, 52428, "the triple-odds threshold is staged exactly")
end

-- The Level Ball compares attacker and target levels at exact ratios: 8
-- times at quadruple, 4 times at double, twice when ahead, once otherwise.
function T.level_ball_compares_attacker_and_target_levels()
  local cases = {
    { target = 10, odds = 120 },
    { target = 11, odds = 60 },
    { target = 20, odds = 60 },
    { target = 21, odds = 30 },
    { target = 40, odds = 15 },
  }
  for _, case in ipairs(cases) do
    local outcome =
      calculate("LEVEL_BALL", targetFacts({ level = case.target }), wildEnv({ attackerLevel = 40 }), { 0, 0, 0 })
    Assert.equal(outcome.calc.odds, case.odds, "target level " .. case.target .. " stages exactly")
  end
end

-- The Timer Ball grows with elapsed turns and caps at four times: turns 0,
-- 10, 20, and 30 stage 1, 2, 3, and 4, and turn 45 stays capped.
function T.timer_ball_grows_with_elapsed_turns_and_caps()
  local cases = {
    { turns = 0, odds = 15 },
    { turns = 10, odds = 30 },
    { turns = 20, odds = 45 },
    { turns = 30, odds = 60 },
    { turns = 45, odds = 60 },
  }
  for _, case in ipairs(cases) do
    local outcome = calculate("TIMER_BALL", targetFacts(), wildEnv({ turns = case.turns }), { 0, 0, 0 })
    Assert.equal(outcome.calc.odds, case.odds, "turn " .. case.turns .. " stages exactly")
  end
end

-- The Quick Ball rewards only the opening turn with four times: turn zero
-- stages 60 while turn one falls back to plain odds, never a later bonus.
function T.quick_ball_only_rewards_the_opening_turn()
  local opening = calculate("QUICK_BALL", targetFacts(), wildEnv({ turns = 0 }), { 0, 0, 0 })
  Assert.equal(opening.calc.odds, 60, "the opening turn quadruples the odds")
  local late = calculate("QUICK_BALL", targetFacts(), wildEnv({ turns = 1 }), { 0, 0, 0 })
  Assert.equal(late.calc.odds, 15, "later turns fall back to plain odds")
end

-- The Dive Ball needs open water under the surfer: surfing stages the bonus
-- while dry land stays plain.
function T.dive_ball_needs_open_water_under_the_surfer()
  local wet = calculate("DIVE_BALL", targetFacts(), wildEnv({ method = "surf" }), { 0, 0, 0 })
  Assert.equal(wet.calc.odds, 52, "surfing stages the water bonus")
  local dry = calculate("DIVE_BALL", targetFacts(), wildEnv({ method = "land" }), { 0, 0, 0 })
  Assert.equal(dry.calc.odds, 15, "dry land stays plain")
end

-- The Dusk Ball needs night or a cave: both stage the bonus while a bright
-- open field stays plain.
function T.dusk_ball_needs_night_or_cave()
  local night = calculate("DUSK_BALL", targetFacts(), wildEnv({ timeOfDay = "night" }), { 0, 0, 0 })
  Assert.equal(night.calc.odds, 52, "night stages the dusk bonus")
  local cave = calculate("DUSK_BALL", targetFacts(), wildEnv({ timeOfDay = "day", inCave = true }), { 0, 0, 0 })
  Assert.equal(cave.calc.odds, 52, "caves stage the dusk bonus by day")
  local field = calculate("DUSK_BALL", targetFacts(), wildEnv({ timeOfDay = "day", inCave = false }), { 0, 0, 0 })
  Assert.equal(field.calc.odds, 15, "a bright open field stays plain")
end

-- Presentation scenery never counts as terrain: a cave-looking backdrop
-- over an open field stays plain while true night still applies.
function T.backdrop_never_counts_as_terrain()
  local dressed = calculate(
    "DUSK_BALL",
    targetFacts(),
    wildEnv({ timeOfDay = "day", inCave = false, backdrop = "cave_look" }),
    { 0, 0, 0 }
  )
  Assert.equal(dressed.calc.odds, 15, "scenery alone stages no bonus")
  local night = calculate(
    "DUSK_BALL",
    targetFacts(),
    wildEnv({ timeOfDay = "night", inCave = false, backdrop = "cave_look" }),
    { 0, 0, 0 }
  )
  Assert.equal(night.calc.odds, 52, "true night still stages the bonus")
end

-- The Net Ball needs bug or water types: both triple while fire stays plain.
function T.net_ball_needs_bug_or_water_types()
  local water = calculate("NET_BALL", targetFacts({ types = { "water" } }), wildEnv(), { 0, 0, 0 })
  Assert.equal(water.calc.odds, 45, "water stages the net bonus")
  local bug = calculate("NET_BALL", targetFacts({ types = { "bug" } }), wildEnv(), { 0, 0, 0 })
  Assert.equal(bug.calc.odds, 45, "bug stages the net bonus")
  local fire = calculate("NET_BALL", targetFacts({ types = { "fire" } }), wildEnv(), { 0, 0, 0 })
  Assert.equal(fire.calc.odds, 15, "fire stays plain")
end

-- The Repeat Ball needs a caught record: known species triple while new
-- species stay plain.
function T.repeat_ball_needs_a_caught_record()
  local known = calculate("REPEAT_BALL", targetFacts(), wildEnv({ pokedexCaught = true }), { 0, 0, 0 })
  Assert.equal(known.calc.odds, 45, "a caught record stages the repeat bonus")
  local fresh = calculate("REPEAT_BALL", targetFacts(), wildEnv({ pokedexCaught = false }), { 0, 0, 0 })
  Assert.equal(fresh.calc.odds, 15, "a new species stays plain")
end

-- The Lure Ball needs a fished encounter: hooked targets triple while dry
-- encounters stay plain.
function T.lure_ball_needs_a_fished_encounter()
  local hooked = calculate("LURE_BALL", targetFacts(), wildEnv({ fished = true }), { 0, 0, 0 })
  Assert.equal(hooked.calc.odds, 45, "a fished encounter stages the lure bonus")
  local dry = calculate("LURE_BALL", targetFacts(), wildEnv({ fished = false }), { 0, 0, 0 })
  Assert.equal(dry.calc.odds, 15, "a dry encounter stays plain")
end

-- The Fast Ball needs a hundred base speed: the boundary stages four times
-- while 99 stays plain.
function T.fast_ball_needs_a_hundred_base_speed()
  local swift = calculate("FAST_BALL", targetFacts({ baseSpeed = 100 }), wildEnv(), { 0, 0, 0 })
  Assert.equal(swift.calc.odds, 60, "a hundred base speed quadruples the odds")
  local slow = calculate("FAST_BALL", targetFacts({ baseSpeed = 99 }), wildEnv(), { 0, 0, 0 })
  Assert.equal(slow.calc.odds, 15, "ninety-nine stays plain")
end

-- The Love Ball needs the same species with the opposite gender: only that
-- pairing stages eight times.
function T.love_ball_needs_same_species_and_opposite_gender()
  local pair = calculate(
    "LOVE_BALL",
    targetFacts({ species = "PIKACHU", gender = "male" }),
    wildEnv({ attackerSpecies = "PIKACHU", attackerGender = "female" }),
    { 0, 0, 0 }
  )
  Assert.equal(pair.calc.odds, 120, "the opposite-gender pairing stages eight times")
  local same = calculate(
    "LOVE_BALL",
    targetFacts({ species = "PIKACHU", gender = "male" }),
    wildEnv({ attackerSpecies = "PIKACHU", attackerGender = "male" }),
    { 0, 0, 0 }
  )
  Assert.equal(same.calc.odds, 15, "the same gender stays plain")
  local other = calculate(
    "LOVE_BALL",
    targetFacts({ species = "PIKACHU", gender = "male" }),
    wildEnv({ attackerSpecies = "PIDGEY", attackerGender = "female" }),
    { 0, 0, 0 }
  )
  Assert.equal(other.calc.odds, 15, "another species stays plain")
end

-- The Moon Ball needs the moon-stone line: listed species quadruple while
-- outsiders stay plain.
function T.moon_ball_needs_the_moon_stone_line()
  for _, species in ipairs({ "CLEFAIRY", "NIDORAN_F" }) do
    local outcome = calculate("MOON_BALL", targetFacts({ species = species }), wildEnv(), { 0, 0, 0 })
    Assert.equal(outcome.calc.odds, 60, species .. " stages the moon bonus")
  end
  local outsider = calculate("MOON_BALL", targetFacts({ species = "PIKACHU" }), wildEnv(), { 0, 0, 0 })
  Assert.equal(outsider.calc.odds, 15, "outsiders stay plain")
end

-- Each conditional ball names its missing facts instead of guessing: a
-- bare encounter cannot stage any of them.
function T.each_conditional_ball_names_its_missing_facts()
  local Context = contextOwner("typed capture environments own the facts each ball reads")
  local balls = {
    "NET_BALL",
    "DIVE_BALL",
    "NEST_BALL",
    "REPEAT_BALL",
    "TIMER_BALL",
    "QUICK_BALL",
    "DUSK_BALL",
    "FAST_BALL",
    "LEVEL_BALL",
    "LURE_BALL",
    "MOON_BALL",
    "LOVE_BALL",
    "HEAVY_BALL",
  }
  for _, ball in ipairs(balls) do
    local ok, err = pcall(Context.forBall, ball, {}, {})
    Assert.isFalse(ok, ball .. " refuses a bare encounter")
    Assert.isTrue(type(err) == "table" and type(err.code) == "string", ball .. " names its missing fact")
  end
end

-- Plain balls need no extra facts: the whole 1x family stages the base odds
-- from the target alone.
function T.plain_balls_need_no_extra_facts()
  local cases = {
    { ball = "POKE_BALL", odds = 15 },
    { ball = "PREMIER_BALL", odds = 15 },
    { ball = "LUXURY_BALL", odds = 15 },
    { ball = "HEAL_BALL", odds = 15 },
    { ball = "FRIEND_BALL", odds = 15 },
    { ball = "CHERISH_BALL", odds = 15 },
  }
  for _, case in ipairs(cases) do
    local outcome = calculate(case.ball, targetFacts(), wildEnv(), { 0, 0, 0 })
    Assert.equal(outcome.calc.odds, case.odds, case.ball .. " stages plain odds")
  end
end

-- Unknown balls fail before any draw: nothing is staged and the stream is
-- never touched.
function T.unknown_balls_fail_before_any_draw()
  local Context = contextOwner("typed capture environments own the facts each ball reads")
  local stream = scriptedStream({ 0, 0, 0 })
  local ok, err = pcall(Context.forBall, "GOLD_BALL", targetFacts(), wildEnv())
  Assert.isFalse(ok, "an unknown ball never stages")
  Assert.isTrue(type(err) == "table" and type(err.code) == "string", "an unknown ball names its failure")
  Assert.deepEqual(stream:capture(), { used = 0, labels = {} }, "a rejected ball spends no draw")
end

-- Malformed environments are rejected at their owner while built contexts
-- validate cleanly.
function T.context_validation_rejects_malformed_environments()
  local Context = contextOwner("typed capture environments own the facts each ball reads")
  local okNil, errNil = pcall(Context.validate, nil)
  Assert.isFalse(okNil, "a missing environment never validates")
  Assert.isTrue(type(errNil) == "table" and type(errNil.code) == "string", "a missing environment names its failure")
  for _, candidate in ipairs({ {}, { ball = "POKE_BALL" } }) do
    local ok, err = pcall(Context.validate, candidate)
    Assert.isFalse(ok, "a malformed environment never validates")
    Assert.isTrue(type(err) == "table" and type(err.code) == "string", "a malformed environment names its failure")
  end
  local built = Context.forBall("POKE_BALL", targetFacts(), wildEnv())
  Assert.isTrue(Context.validate(built), "a built context validates")
end

return { tests = T }
