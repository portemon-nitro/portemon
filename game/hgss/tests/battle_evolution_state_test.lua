-- Native post-battle evolution presentation: the state binds one staged
-- domain flow for its committed subject, starts its entry, cry, and
-- animation beats on its own without a confirmation gate, honors cancel
-- only where the source method permits it, resolves each pending learned
-- move through an explicit replace-or-decline answer, and settles exactly
-- one typed result without ever writing mon fields itself.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ItemFixture = require("libs.items.tests.item_fixture")
local Experience = require("libs.mons.src.gen4.Experience")
local MonStats = require("libs.mons.src.gen4.MonStats")

local BattleEvolutionState = require("game.hgss.src.battle.BattleEvolutionState")

local T = {}

---@param mutate fun(root: table<string, unknown>)|nil species edits for one vector
---@return table mon catalog carrying exactly the vector slots
local function evolutionCatalog(mutator)
  local root = CatalogFixture.buildAssetRoot()
  if mutator ~= nil then
    mutator(root)
  end
  local MonCatalog = require("libs.mons.src.MonCatalog")
  return MonCatalog.new(root, ItemFixture.makeCatalog())
end

---@param root table<string, unknown> mutable synthetic mon asset root under grafting
local function graftLevelSlot(root)
  local species = root.species --[[@as table<string, table<string, unknown>>]]
  local forms = species.CHIKORITA.forms --[[@as table<integer, table<string, unknown>>]]
  forms[0].evolutions = {
    { method = "level", level = 16, target = "TOTODILE", form = 0 },
  }
end

---@param root table<string, unknown> mutable synthetic mon asset root under grafting
local function graftTwoSlots(root)
  local species = root.species --[[@as table<string, table<string, unknown>>]]
  local forms = species.CHIKORITA.forms --[[@as table<integer, table<string, unknown>>]]
  forms[0].evolutions = {
    { method = "level", level = 16, target = "TOTODILE", form = 0 },
    { method = "level", level = 10, target = "EEVEE", form = 0 },
  }
end

---@param root table<string, unknown> mutable synthetic mon asset root under grafting
local function graftTradeSlot(root)
  local species = root.species --[[@as table<string, table<string, unknown>>]]
  local forms = species.CHIKORITA.forms --[[@as table<integer, table<string, unknown>>]]
  forms[0].evolutions = {
    { method = "trade", target = "TOTODILE", form = 0 },
  }
end

---@param root table<string, unknown> mutable synthetic mon asset root under grafting
local function graftNincadaLine(root)
  local species = root.species --[[@as table<string, table<string, unknown>>]]
  local function stats(hp, attack, defense, speed, specialAttack, specialDefense)
    return {
      hp = hp,
      attack = attack,
      defense = defense,
      speed = speed,
      specialAttack = specialAttack,
      specialDefense = specialDefense,
    }
  end
  local held = {
    common = { item = "NONE", nativeId = 0 },
    rare = { item = "NONE", nativeId = 0 },
  }
  species.NINCADA = {
    nativeId = 290,
    name = "NINCADA",
    growthCurve = "erratic",
    baseFriendship = 70,
    genderRatio = 31,
    eggCycles = 15,
    eggGroups = { "bug", "bug" },
    catchRate = 255,
    baseExpYield = 65,
    evYield = stats(0, 0, 1, 0, 0, 0),
    heldItems = held,
    color = 3,
    flip = false,
    forms = {
      [0] = {
        baseStats = stats(31, 45, 90, 40, 30, 30),
        types = { "bug", "ground" },
        abilities = { "OVERGROW" },
        tmhm = {},
        levelUpMoves = {
          { level = 1, move = "SCRATCH" },
          { level = 1, move = "HARDEN" },
        },
        evolutions = {
          { method = "level_ninjask", level = 20, target = "NINJASK", form = 0 },
          { method = "level_shedinja", level = 20, target = "SHEDINJA", form = 0 },
        },
        icon = "NINCADA/f0",
        portrait = "NINCADA/f0/male/plain",
      },
    },
  }
  species.NINJASK = {
    nativeId = 291,
    name = "NINJASK",
    growthCurve = "erratic",
    baseFriendship = 70,
    genderRatio = 31,
    eggCycles = 15,
    eggGroups = { "bug", "bug" },
    catchRate = 120,
    baseExpYield = 155,
    evYield = stats(0, 0, 0, 2, 0, 0),
    heldItems = held,
    color = 3,
    flip = false,
    forms = {
      [0] = {
        baseStats = stats(61, 90, 45, 160, 50, 50),
        types = { "bug", "flying" },
        abilities = { "OVERGROW" },
        tmhm = {},
        levelUpMoves = {
          { level = 1, move = "SCRATCH" },
          { level = 1, move = "HARDEN" },
        },
        evolutions = {},
        icon = "NINJASK/f0",
        portrait = "NINJASK/f0/male/plain",
      },
    },
  }
end

---@param catalog table mon catalog under test preparation
---@param species string subject species key under test preparation
---@param level integer pinned battle level under test preparation
---@param moves table<integer, table<string, unknown>>|nil staged move set under preparation
---@return table committed subject at the requested level with full health
local function subjectAt(catalog, species, level, moves)
  local factory = CatalogFixture.makeFactory(0xE0010001, catalog)
  local mon = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level }))
  if moves ~= nil then
    mon.moves = moves
  end
  mon.condition.currentHp = MonStats.derive(mon, catalog).maxHp
  return mon
end

---@param catalog table mon catalog under test preparation
---@param mon table<string, unknown> test subject under construction
---@return table evolution presentation state for the committed subject
local function stateFor(catalog, mon)
  return BattleEvolutionState.new({
    mon = mon,
    context = { trigger = { kind = "level" }, timeOfDay = "day", party = {}, inventory = {} },
    catalog = catalog,
  })
end

---@param move string move identity under test preparation
---@return table<string, unknown> staged move entry with full points
local function moveEntry(move)
  return { move = move, pp = 35, ppUps = 0 }
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

---@param state table<string, unknown> evolution presentation state under driving
---@param ticks integer tick budget before the driver gives up
local function runUntilSettled(state, ticks)
  for _ = 1, ticks do
    state:stepSourceTick(1)
    local phase = state:status().phase
    if phase == "settled" or phase == "learn" then
      return
    end
  end
  error("the evolution sequence never settled")
end

function T.ineligible_subjects_settle_without_effects_or_mutation()
  local catalog = evolutionCatalog(nil)
  local mon = subjectAt(catalog, "CHIKORITA", 5, { moveEntry("TACKLE") })
  local before = copyMon(mon)
  local state = stateFor(catalog, mon)
  Assert.equal(state:status().phase, "settled", "an ineligible subject settles at once")
  local result = state:takeResult()
  Assert.notNil(result, "the settled state answers its choice")
  assert(result ~= nil, "the ineligible choice seals")
  Assert.equal(result.kind, "choice", "ineligibility still reports a choice")
  Assert.isFalse(result.choice.evolved, "nothing evolves without a matching rule")
  Assert.equal(result.choice.reason, "ineligible", "the choice names its reason")
  Assert.isNil(state:takeResult(), "the settled choice reports exactly once")
  Assert.deepEqual(mon, before, "sequencing never mutates its subject")
end

-- The native beats run with no confirmation gate: entry, cry, and the
-- transformation follow ticks alone, and a lone free move slot fills
-- silently behind the same run.
function T.sequence_starts_without_confirmation_and_completes_alone()
  local catalog = evolutionCatalog(graftLevelSlot)
  local mon = subjectAt(catalog, "CHIKORITA", 16, { moveEntry("TACKLE") })
  local state = stateFor(catalog, mon)
  Assert.equal(state:status().phase, "entry", "the sequence opens on its entry beat")
  state:input({ { type = "confirm" } })
  runUntilSettled(state, 60)
  local result = state:takeResult()
  Assert.notNil(result, "the unguided sequence answers its choice")
  assert(result ~= nil, "the evolved choice seals")
  Assert.isTrue(result.choice.evolved, "the sequence completes without any confirmation")
  local staged = assert(result.choice.staged, "the outcome carries its staged domain result")
  Assert.equal(staged.mon.species, "TOTODILE", "staging names the first matching target")
  Assert.isNil(state:takeResult(), "the settled choice reports exactly once")
  local kinds = {}
  for _, effect in ipairs(state:effects()) do
    kinds[#kinds + 1] = effect.kind .. ":" .. effect.phase
  end
  Assert.isTrue(#kinds >= 4, "entry, cry, transformation, and settlement all sequence effects")
  Assert.equal(kinds[1], "music:entry", "music opens the entry")
end

-- Cancel during the permitted animation window declines without staging:
-- no transformation, no palette, and the input record stays untouched.
function T.permitted_cancel_declines_without_applying()
  local catalog = evolutionCatalog(graftLevelSlot)
  local mon = subjectAt(catalog, "CHIKORITA", 16, { moveEntry("TACKLE") })
  local before = copyMon(mon)
  local state = stateFor(catalog, mon)
  Assert.isTrue(state:status().canCancel, "level evolutions stay cancellable")
  for _ = 1, BattleEvolutionState.ENTRY_TICKS + 1 do
    state:stepSourceTick(1)
  end
  state:input({ { type = "cancel" } })
  Assert.equal(state:status().phase, "settled", "a permitted cancel settles the sequence")
  local result = state:takeResult()
  Assert.notNil(result, "the cancelled sequence answers its choice")
  assert(result ~= nil, "the declined choice seals")
  Assert.isFalse(result.choice.evolved, "a cancelled candidate never evolves")
  Assert.equal(result.choice.reason, "cancelled", "the outcome names its cancellation")
  Assert.isNil(result.choice.staged, "a declined candidate stages nothing")
  Assert.deepEqual(mon, before, "a declined candidate leaves its subject untouched")
  local palette = false
  for _, effect in ipairs(state:effects()) do
    if effect.kind == "palette" then
      palette = true
    end
  end
  Assert.isFalse(palette, "a declined candidate sequences no transformation")
end

-- A full move set pauses for explicit answers in learnset order: replace
-- the first pending move, decline the second, and the staged set carries
-- exactly those decisions.
function T.full_moves_pause_for_replace_then_decline_in_order()
  local catalog = evolutionCatalog(graftLevelSlot)
  local mon = subjectAt(catalog, "CHIKORITA", 16, {
    moveEntry("TACKLE"),
    moveEntry("GROWL"),
    moveEntry("RAZOR_LEAF"),
    moveEntry("POISONPOWDER"),
  })
  local state = stateFor(catalog, mon)
  runUntilSettled(state, 60)
  Assert.equal(state:status().phase, "learn", "a full set pauses on its first pending move")
  local first = state:learnPrompt()
  Assert.notNil(first, "the paused sequence exposes its learning prompt")
  assert(first ~= nil, "the first prompt stages")
  Assert.equal(first.move, "SCRATCH", "pending moves follow target learnset order")
  Assert.equal(#first.currentMoves, 4, "the prompt carries the four held moves")
  state:answerLearn({ choice = "replace", slot = 3 })
  Assert.equal(state:status().phase, "learn", "an answered prompt advances to the next pending move")
  local second = state:learnPrompt()
  Assert.notNil(second, "the second pending move pauses in turn")
  assert(second ~= nil, "the second prompt stages")
  Assert.equal(second.move, "LEER", "the second pending move keeps learnset order")
  state:answerLearn({ choice = "decline" })
  local third = state:learnPrompt()
  Assert.notNil(third, "the third pending move pauses in turn")
  assert(third ~= nil, "the third prompt stages")
  Assert.equal(third.move, "WATER_GUN", "the third pending move keeps learnset order")
  state:answerLearn({ choice = "replace", slot = 0 })
  runUntilSettled(state, 60)
  local result = state:takeResult()
  Assert.notNil(result, "the answered sequence settles its choice")
  assert(result ~= nil, "the learned choice seals")
  Assert.isTrue(result.choice.evolved, "answered learning still evolves")
  local staged = assert(result.choice.staged, "the outcome carries its staged domain result")
  local names = {}
  for _, entry in ipairs(staged.mon.moves) do
    names[#names + 1] = entry.move
  end
  Assert.deepEqual(names, { "WATER_GUN", "GROWL", "RAZOR_LEAF", "SCRATCH" }, "replace and decline land exactly")
end

-- Learning answers outside the open prompt fail loudly instead of
-- guessing: an unknown choice and an out-of-range slot both refuse.
function T.learning_answers_outside_the_prompt_refuse()
  local catalog = evolutionCatalog(graftLevelSlot)
  local mon = subjectAt(catalog, "CHIKORITA", 16, {
    moveEntry("TACKLE"),
    moveEntry("GROWL"),
    moveEntry("RAZOR_LEAF"),
    moveEntry("POISONPOWDER"),
  })
  local state = stateFor(catalog, mon)
  runUntilSettled(state, 60)
  Assert.equal(state:status().phase, "learn", "setup: the sequence pauses on its pending move")
  local okChoice = pcall(function()
    state:answerLearn({ choice = "forget" })
  end)
  Assert.isFalse(okChoice, "an unknown learning choice refuses")
  local okSlot = pcall(function()
    state:answerLearn({ choice = "replace", slot = 9 })
  end)
  Assert.isFalse(okSlot, "an out-of-range replacement slot refuses")
  local prompt = state:learnPrompt()
  Assert.notNil(prompt, "refused answers leave the pending prompt open")
end

-- Two matching rules still stage one evolution: the first source match
-- wins and no candidate walk reapplies a second transformation.
function T.first_matching_rule_wins_and_applies_once()
  local catalog = evolutionCatalog(graftTwoSlots)
  local mon = subjectAt(catalog, "CHIKORITA", 16, { moveEntry("TACKLE") })
  local state = stateFor(catalog, mon)
  runUntilSettled(state, 120)
  local result = state:takeResult()
  Assert.notNil(result, "the single-rule sequence answers its choice")
  assert(result ~= nil, "the first-match choice seals")
  Assert.isTrue(result.choice.evolved, "the first matching rule evolves")
  local staged = assert(result.choice.staged, "the outcome carries its staged domain result")
  Assert.equal(staged.mon.species, "TOTODILE", "the earlier sixteen slot wins over the later ten slot")
  Assert.equal(#staged.additionalMons, 0, "a plain rule stages no side product")
end

function T.trade_evolutions_hold_on_cancel()
  local catalog = evolutionCatalog(graftTradeSlot)
  local mon = subjectAt(catalog, "CHIKORITA", 16, { moveEntry("TACKLE") })
  local state = BattleEvolutionState.new({
    mon = mon,
    context = { trigger = { kind = "trade" }, timeOfDay = "day", party = {}, inventory = {} },
    catalog = catalog,
  })
  for _ = 1, BattleEvolutionState.ENTRY_TICKS + 1 do
    state:stepSourceTick(1)
  end
  Assert.isFalse(state:status().canCancel, "trade evolutions refuse cancellation")
  state:input({ { type = "cancel" } })
  Assert.isTrue(state:status().active, "a refused cancel keeps the sequence alive")
  Assert.isNil(state:takeResult(), "a held sequence settles nothing early")
  runUntilSettled(state, 60)
  local result = state:takeResult()
  Assert.notNil(result, "the held trade still completes on its own")
  assert(result ~= nil, "the trade choice seals")
  Assert.isTrue(result.choice.evolved, "the unguided trade applies its candidate")
end

function T.shedinja_side_product_rides_the_staged_result()
  local catalog = evolutionCatalog(graftNincadaLine)
  local mon = subjectAt(catalog, "NINCADA", 20, { moveEntry("SCRATCH") })
  local state = BattleEvolutionState.new({
    mon = mon,
    context = {
      trigger = { kind = "level" },
      timeOfDay = "day",
      party = { copyMon(mon) },
      inventory = { POKE_BALL = 1 },
    },
    catalog = catalog,
  })
  runUntilSettled(state, 60)
  local result = state:takeResult()
  Assert.notNil(result, "the shed line answers its choice")
  assert(result ~= nil, "the shed choice seals")
  Assert.isTrue(result.choice.evolved, "the shed line evolves")
  local staged = assert(result.choice.staged, "the outcome carries its staged domain result")
  Assert.equal(staged.mon.species, "NINJASK", "the primary stages its evolved species")
  Assert.equal(#staged.additionalMons, 1, "room plus a ball stages exactly one extra mon")
  Assert.equal(staged.additionalMons[1].species, "SHEDINJA", "the extra mon is the shed side product")
  Assert.equal(#staged.inventoryDeltas, 1, "the side product consumes its ball in the same operation")
end

function T.teardown_and_foreign_input_never_decide()
  local catalog = evolutionCatalog(graftLevelSlot)
  local mon = subjectAt(catalog, "CHIKORITA", 16, { moveEntry("TACKLE") })
  local state = stateFor(catalog, mon)
  for _ = 1, BattleEvolutionState.ENTRY_TICKS + 1 do
    state:stepSourceTick(1)
  end
  state:input({ { type = "pointer_down" } })
  state:input({ { type = "dismiss" } })
  state:dispose()
  state:input({ { type = "cancel" } })
  state:stepSourceTick(9)
  Assert.isNil(state:takeResult(), "teardown ends the sequence without publishing")
  Assert.isFalse(state:status().active, "disposal releases the presentation lifetime")
end

return { tests = T }
