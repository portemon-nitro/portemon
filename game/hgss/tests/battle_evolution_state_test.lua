-- Native evolution presentation sequencing: the state owns the source
-- entry, old-picture animation, cry/message, permitted cancel policy, and
-- transformation beats while the evolution domain owns eligibility and the
-- staged result. Publication never happens here; the staged domain records
-- ride the completion command. Only source-permitted input decides.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")

local BattleEvolutionState = require("game.hgss.src.battle.BattleEvolutionState")
local Evolution = require("libs.mons.src.gen4.Evolution")

local T = {}

---@return table<integer, integer> real medium-fast growth curve for level projection
local function growthCurve()
  local catalog = CatalogFixture.makeCatalog()
  return catalog:growthCurve("medium_fast")
end

---@param slots table<integer, table<string, unknown>> ordered form slots under the test subject
---@param targets table<string, table<string, unknown>>? target form overrides by species
---@return table<string, unknown> battle-local mon catalog double
local function testCatalog(slots, targets)
  local curve = growthCurve()
  local catalog = {}
  function catalog:species(_)
    return { growthCurve = "medium_fast", genderRatio = 31, baseExpYield = 60, evYield = {} }
  end
  function catalog:growthCurve(_)
    return curve
  end
  function catalog:form(speciesKey, _)
    if speciesKey == "TESTMON" then
      return {
        baseStats = { hp = 45, attack = 49, defense = 49, speed = 45, specialAttack = 65, specialDefense = 65 },
        abilities = { "OVERGROW" },
        levelUpMoves = {},
        evolutions = slots,
        types = { "grass" },
      }
    end
    local override = targets ~= nil and targets[speciesKey] or nil
    return {
      baseStats = { hp = 60, attack = 62, defense = 63, speed = 60, specialAttack = 80, specialDefense = 80 },
      abilities = { "OVERGROW" },
      levelUpMoves = {},
      evolutions = {},
      types = { "grass" },
      extra = override,
    }
  end
  return catalog
end

---@param level integer battle level under test preparation
---@return table<string, unknown> committed subject at the requested level
local function subjectAt(level)
  local curve = growthCurve()
  local zeros = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 }
  return {
    species = "TESTMON",
    form = 0,
    personality = 0,
    experience = curve[level],
    moves = {},
    ivs = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 },
    evs = zeros,
    condition = { currentHp = 20 },
    heldItem = "NONE",
  }
end

---@param context table<string, unknown>? trigger context overrides under test preparation
---@return table<string, unknown> level-trigger context for the test subject
local function levelContext(context)
  local record = { trigger = { kind = "level" }, party = {}, inventory = {} }
  if context ~= nil then
    for key, value in pairs(context) do
      record[key] = value
    end
  end
  return record
end

---@param slots table<integer, table<string, unknown>> ordered form slots under test preparation
---@param context table<string, unknown>? trigger context overrides under test preparation
---@return table<string, unknown> evolution presentation state at the requested level
local function stateFor(slots, context)
  return BattleEvolutionState.new({
    mon = subjectAt(20),
    context = levelContext(context),
    catalog = testCatalog(slots),
  })
end

---@param state table<string, unknown> evolution presentation state under driving
local function runToPrompt(state)
  for _ = 1, BattleEvolutionState.ENTRY_TICKS do
    state:stepSourceTick(1)
  end
  for _ = 1, BattleEvolutionState.SEQUENCE_TICKS do
    state:stepSourceTick(1)
  end
  Assert.equal(state:status().phase, "prompt", "the sequence offers its prompt")
end

---@param level integer battle level under test preparation
---@return table<integer, table<string, unknown>> single eligible level slot
local function singleSlot(level)
  return { { method = "level", level = level, target = "TESTVOLVED", form = 0 } }
end

-- Copies one test subject without sharing mutable state.
---@param mon table<string, unknown> test subject under copying
---@return table<string, unknown> detached copy
local function copyMon(mon)
  local out = {}
  for key, value in pairs(mon) do
    if type(value) == "table" then
      local cell = {}
      for innerKey, innerValue in pairs(value) do
        cell[innerKey] = innerValue
      end
      out[key] = cell
    else
      out[key] = value
    end
  end
  return out
end

function T.ineligible_subjects_settle_without_effects_or_mutation()
  local catalog = testCatalog({})
  local mon = subjectAt(5)
  local before = copyMon(mon)
  local state = BattleEvolutionState.new({ mon = mon, context = levelContext(), catalog = catalog })
  Assert.equal(state:status().phase, "settled", "an ineligible subject settles at once")
  local result = state:takeResult()
  Assert.notNil(result, "the settled state answers its choice")
  assert(result ~= nil, "the ineligible choice seals")
  Assert.equal(result.kind, "choice", "ineligibility still reports a choice")
  Assert.isFalse(result.choice.evolved, "nothing evolves without a candidate")
  Assert.equal(result.choice.reason, "ineligible", "the choice names its reason")
  Assert.isNil(state:takeResult(), "the settled choice reports exactly once")
  Assert.deepEqual(mon, before, "sequencing never mutates its subject")
end

function T.success_runs_the_native_beats_in_order_then_settles()
  local state = stateFor(singleSlot(15), nil)
  Assert.equal(state:status().phase, "entry", "the sequence opens on its entry beat")
  state:input({ { type = "confirm" } })
  Assert.equal(state:status().phase, "entry", "confirmation before the prompt decides nothing")
  runToPrompt(state)
  state:input({ { type = "confirm" } })
  state:input({ { type = "confirm" } })
  for _ = 1, BattleEvolutionState.TRANSFORMATION_TICKS do
    state:stepSourceTick(1)
  end
  Assert.equal(state:status().phase, "settled", "the transformation beat settles the sequence")
  local result = state:takeResult()
  Assert.notNil(result, "the settled sequence answers its choice")
  assert(result ~= nil, "the evolved choice seals")
  Assert.isTrue(result.choice.evolved, "the confirmed candidate evolves")
  Assert.equal(#result.choice.outcomes, 1, "one candidate settles one outcome")
  Assert.isTrue(result.choice.outcomes[1].evolved, "the outcome carries its transformation")
  Assert.notNil(result.choice.outcomes[1].staged, "the outcome carries its staged domain result")
  Assert.equal(result.choice.outcomes[1].staged.monAfter.species, "TESTVOLVED", "staging names the target")
  local kinds = {}
  for _, effect in ipairs(state:effects()) do
    kinds[#kinds + 1] = effect.kind .. ":" .. effect.phase
  end
  Assert.isTrue(#kinds >= 4, "entry, cry, prompt, and settled beats all sequence effects")
  Assert.equal(kinds[1], "music:entry", "music opens the entry")
  local cryAt, paletteAt, settledAt = 0, 0, 0
  for index, kind in ipairs(kinds) do
    if kind == "cry:sequence" and cryAt == 0 then
      cryAt = index
    end
    if kind == "palette:transformation" and paletteAt == 0 then
      paletteAt = index
    end
    if kind == "message:settled" and settledAt == 0 then
      settledAt = index
    end
  end
  Assert.isTrue(cryAt > 1, "the cry follows the entry music")
  Assert.isTrue(paletteAt > cryAt, "the transformation palette follows the cry")
  Assert.isTrue(settledAt > paletteAt, "settlement closes the sequence")
  Assert.isNil(state:takeResult(), "the settled choice reports exactly once")
end

function T.permitted_cancel_declines_without_applying()
  local state = stateFor(singleSlot(15), nil)
  runToPrompt(state)
  Assert.isTrue(state:status().canCancel, "level evolutions stay cancellable")
  state:input({ { type = "cancel" } })
  Assert.equal(state:status().phase, "settled", "a permitted cancel settles the sequence")
  local result = state:takeResult()
  Assert.notNil(result, "the cancelled sequence answers its choice")
  assert(result ~= nil, "the declined choice seals")
  Assert.isFalse(result.choice.evolved, "a cancelled candidate never evolves")
  Assert.equal(result.choice.outcomes[1].reason, "cancelled", "the outcome names its cancellation")
  Assert.isNil(result.choice.outcomes[1].staged, "a declined candidate stages nothing")
  local palette = false
  for _, effect in ipairs(state:effects()) do
    if effect.kind == "palette" then
      palette = true
    end
  end
  Assert.isFalse(palette, "a declined candidate sequences no transformation")
end

function T.trade_evolutions_hold_on_cancel()
  local state = BattleEvolutionState.new({
    mon = subjectAt(20),
    context = { trigger = { kind = "trade" }, party = {}, inventory = {} },
    catalog = testCatalog({ { method = "trade", target = "TESTVOLVED", form = 0 } }),
  })
  runToPrompt(state)
  Assert.isFalse(state:status().canCancel, "trade evolutions refuse cancellation")
  state:input({ { type = "cancel" } })
  Assert.equal(state:status().phase, "prompt", "a refused cancel holds the prompt")
  Assert.isNil(state:takeResult(), "a held prompt settles nothing")
  state:input({ { type = "confirm" } })
  for _ = 1, BattleEvolutionState.TRANSFORMATION_TICKS do
    state:stepSourceTick(1)
  end
  local result = state:takeResult()
  Assert.notNil(result, "the confirmed trade evolves")
  assert(result ~= nil, "the trade choice seals")
  Assert.isTrue(result.choice.evolved, "confirmation applies the held candidate")
end

function T.multiple_candidates_walk_source_order_without_skipping()
  local slots = {
    { method = "level", level = 10, target = "TESTVOLVED", form = 0 },
    { method = "level", level = 15, target = "TESTOTHER", form = 0 },
  }
  local catalog = testCatalog(slots)
  Assert.equal(#Evolution.candidates(subjectAt(20), levelContext(), catalog), 2, "setup: both slots match")
  local state = BattleEvolutionState.new({ mon = subjectAt(20), context = levelContext(), catalog = catalog })
  Assert.equal(state:status().candidateCount, 2, "the state walks every candidate")
  runToPrompt(state)
  state:input({ { type = "cancel" } })
  Assert.equal(state:status().phase, "entry", "declining the first candidate enters the second")
  runToPrompt(state)
  state:input({ { type = "confirm" } })
  for _ = 1, BattleEvolutionState.TRANSFORMATION_TICKS do
    state:stepSourceTick(1)
  end
  local result = state:takeResult()
  Assert.notNil(result, "the walked sequence answers its choice")
  assert(result ~= nil, "the walked choice seals")
  Assert.isTrue(result.choice.evolved, "the confirmed second candidate evolves")
  Assert.equal(#result.choice.outcomes, 2, "both candidates settle their outcome")
  Assert.equal(result.choice.outcomes[1].ruleIndex, 1, "the first outcome keeps source order")
  Assert.isFalse(result.choice.outcomes[1].evolved, "the first outcome stays declined")
  Assert.equal(result.choice.outcomes[2].ruleIndex, 2, "the second outcome keeps source order")
  Assert.isTrue(result.choice.outcomes[2].evolved, "the second outcome carries its transformation")
  Assert.equal(
    result.choice.outcomes[2].staged.monAfter.species,
    "TESTOTHER",
    "the second transformation names its own target"
  )
end

function T.shedinja_side_product_rides_the_staged_result()
  local slots = {
    { method = "level_ninjask", level = 20, target = "TESTVOLVED", form = 0 },
    { method = "level_shedinja", level = 20, target = "TESTSHED", form = 0 },
  }
  local state = stateFor(slots, { party = { subjectAt(20) }, inventory = { POKE_BALL = 1 } })
  runToPrompt(state)
  state:input({ { type = "confirm" } })
  for _ = 1, BattleEvolutionState.TRANSFORMATION_TICKS do
    state:stepSourceTick(1)
  end
  local result = state:takeResult()
  Assert.notNil(result, "the shed line answers its choice")
  assert(result ~= nil, "the shed choice seals")
  local staged = result.choice.outcomes[1].staged
  Assert.notNil(staged, "the outcome carries its staged domain result")
  assert(staged ~= nil, "the staged shed result stages")
  Assert.equal(#staged.additionalMons, 1, "room plus a ball stages exactly one extra mon")
  Assert.equal(staged.additionalMons[1].species, "TESTSHED", "the extra mon is the shed side product")
  Assert.equal(#staged.inventoryDeltas, 1, "the side product consumes its ball in the same operation")
end

function T.teardown_and_foreign_input_never_decide()
  local state = stateFor(singleSlot(15), nil)
  runToPrompt(state)
  state:input({ { type = "pointer_down" } })
  state:input({ { type = "dismiss" } })
  state:dispose()
  state:input({ { type = "confirm" } })
  state:stepSourceTick(9)
  Assert.isNil(state:takeResult(), "teardown ends the sequence without publishing")
  Assert.isFalse(state:status().active, "disposal releases the presentation lifetime")
end

return { tests = T }
