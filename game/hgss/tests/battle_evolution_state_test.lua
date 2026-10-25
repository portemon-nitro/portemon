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
  -- Retail post-evolution learning only offers the target learnset
  -- entries at the current level, so the vector stages its three
  -- pending moves at sixteen in learnset order.
  local target = species.TOTODILE.forms[0].levelUpMoves --[[@as table<integer, table<string, unknown>>]]
  target[#target + 1] = { level = 16, move = "SCRATCH" }
  target[#target + 1] = { level = 16, move = "LEER" }
  target[#target + 1] = { level = 16, move = "WATER_GUN" }
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
---@param source string? retail presentation origin under construction
---@return table evolution presentation state for the committed subject
local function stateFor(catalog, mon, source)
  return BattleEvolutionState.new({
    mon = mon,
    context = { trigger = { kind = "level" }, timeOfDay = "day", party = {}, inventory = {} },
    catalog = catalog,
    source = source or "battle",
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

---@param state table<string, unknown> evolution presentation state under inspection
---@return table<integer, unknown> retail message ids in sequence order
local function messageIds(state)
  local out = {}
  for _, effect in ipairs(state:effects()) do
    if effect.kind == "message" then
      out[#out + 1] = effect.msg
    end
  end
  return out
end

---@param state table<string, unknown> evolution presentation state under inspection
---@param kind string effect kind under counting
---@return integer matching effect records
local function countKind(state, kind)
  local count = 0
  for _, effect in ipairs(state:effects()) do
    if effect.kind == kind then
      count = count + 1
    end
  end
  return count
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
  Assert.equal(#state:effects(), 0, "ineligibility sequences no presentation evidence")
  Assert.deepEqual(mon, before, "sequencing never mutates its subject")
end

-- The native beats run with no confirmation gate: entry, cry, and the
-- transformation follow ticks alone, and a lone free move slot fills
-- silently behind the same run. The sequenced evidence follows the
-- retail beats: entry BGM, What?, old cry, evolving, particle/sound
-- cascade, new cry, and congratulations.
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
  local signature = {}
  for _, effect in ipairs(state:effects()) do
    if effect.kind == "message" then
      signature[#signature + 1] = "message:" .. tostring(effect.msg)
    elseif effect.kind == "sound" then
      signature[#signature + 1] = "sound:" .. tostring(effect.se)
    elseif effect.kind == "cry" then
      signature[#signature + 1] = "cry:" .. tostring(effect.species)
    elseif effect.kind == "particles" then
      local emitters = {}
      for _, emitter in ipairs(effect.emitters) do
        emitters[#emitters + 1] = tostring(emitter)
      end
      signature[#signature + 1] = "particles:" .. table.concat(emitters, "+")
    elseif effect.kind == "window" or effect.kind == "affine" then
      signature[#signature + 1] = effect.kind .. ":" .. tostring(effect.op)
    else
      signature[#signature + 1] = tostring(effect.kind)
    end
  end
  Assert.deepEqual(signature, {
    "music_direct",
    "message:916",
    "cry:CHIKORITA",
    "message:917",
    "particles:0",
    "sound:1528",
    "window:narrow",
    "particles:1+2+7+8+9+11",
    "sound:1529",
    "affine:oscillate_start",
    "particles:3+4+5+6+10",
    "sound:1530",
    "particles:12",
    "sound:1531",
    "window:widen",
    "palette",
    "cry:TOTODILE",
    "message:918",
  }, "the unguided run sequences the retail beats in order")
  local opening = state:effects()[1]
  Assert.equal(opening.seq, 1011, "entry voices SEQ_GS_SHINKA music-direct")
  local cries = {}
  for _, effect in ipairs(state:effects()) do
    if effect.kind == "cry" then
      cries[#cries + 1] = { effect.species, effect.form }
    end
  end
  Assert.deepEqual(
    cries,
    { { "CHIKORITA", 0 }, { "TOTODILE", 0 } },
    "both cries voice with the subject form"
  )
end

-- Non-battle sources skip the What? beat and combine the progress line:
-- field level-up still cancels but never prints What.
function T.field_level_skips_what_and_combines_evolving()
  local catalog = evolutionCatalog(graftLevelSlot)
  local mon = subjectAt(catalog, "CHIKORITA", 16, { moveEntry("TACKLE") })
  local state = stateFor(catalog, mon, "field_level")
  Assert.equal(state:status().flags, 1, "field level-up passes retail flags 1")
  Assert.isFalse(state:status().printWhat, "only battle prints What")
  runUntilSettled(state, 60)
  local result = state:takeResult()
  Assert.notNil(result, "the field run answers its choice")
  assert(result ~= nil, "the field choice seals")
  Assert.isTrue(result.choice.evolved, "field level-up still evolves")
  Assert.deepEqual(
    messageIds(state),
    { 915, 918 },
    "field level-up combines What-evolving and skips the lone What"
  )
end

-- Cancel during the transformation beat declines without staging:
-- no transformation, no palette, and the input record stays untouched.
-- Retail stops the BGM, replays the old cry, and prints stopped-evolving.
function T.permitted_cancel_declines_without_applying()
  local catalog = evolutionCatalog(graftLevelSlot)
  local mon = subjectAt(catalog, "CHIKORITA", 16, { moveEntry("TACKLE") })
  local before = copyMon(mon)
  local state = stateFor(catalog, mon)
  Assert.isTrue(state:status().canCancel, "level evolutions stay cancellable")
  for _ = 1, BattleEvolutionState.ENTRY_TICKS + BattleEvolutionState.SEQUENCE_TICKS do
    state:stepSourceTick(1)
  end
  Assert.equal(state:status().phase, "transformation", "setup: the sequence reaches its cancellable beat")
  state:input({ { type = "cancel" } })
  Assert.equal(state:status().phase, "settled", "a permitted cancel settles the sequence")
  local result = state:takeResult()
  Assert.notNil(result, "the cancelled sequence answers its choice")
  assert(result ~= nil, "the declined choice seals")
  Assert.isFalse(result.choice.evolved, "a cancelled candidate never evolves")
  Assert.equal(result.choice.reason, "cancelled", "the outcome names its cancellation")
  Assert.isNil(result.choice.staged, "a declined candidate stages nothing")
  Assert.deepEqual(mon, before, "a declined candidate leaves its subject untouched")
  local tail = {}
  for _, effect in ipairs(state:effects()) do
    if effect.phase ~= "transformation" then
      -- The sequence cry predates the cancel beat; only the
      -- transformation beat carries the cancel evidence.
    elseif effect.kind == "stop_bgm" then
      tail[#tail + 1] = effect.seq
    elseif effect.kind == "cry" then
      tail[#tail + 1] = "cry:" .. tostring(effect.species)
    elseif effect.kind == "message" and effect.msg == BattleEvolutionState.MSG_STOPPED then
      tail[#tail + 1] = effect.msg
    elseif effect.kind == "palette" then
      tail[#tail + 1] = "palette"
    end
  end
  Assert.deepEqual(
    tail,
    { 1011, "cry:CHIKORITA", 919 },
    "cancel stops SHINKA, replays the old cry, and prints stopped-evolving"
  )
end

-- Retail checks B during OSCILLATE alone: cancel input on the entry and
-- sequence beats decides nothing and sequences nothing.
function T.cancel_before_transformation_is_ignored()
  local catalog = evolutionCatalog(graftLevelSlot)
  local mon = subjectAt(catalog, "CHIKORITA", 16, { moveEntry("TACKLE") })
  local state = stateFor(catalog, mon)
  local entryEffects = #state:effects()
  state:input({ { type = "cancel" } })
  Assert.equal(state:status().phase, "entry", "an entry cancel decides nothing")
  Assert.equal(#state:effects(), entryEffects, "an entry cancel sequences nothing")
  for _ = 1, BattleEvolutionState.ENTRY_TICKS do
    state:stepSourceTick(1)
  end
  Assert.equal(state:status().phase, "sequence", "setup: the sequence beat starts")
  local sequenceEffects = #state:effects()
  state:input({ { type = "cancel" } })
  Assert.equal(state:status().phase, "sequence", "a sequence cancel decides nothing")
  Assert.equal(#state:effects(), sequenceEffects, "a sequence cancel sequences nothing")
  Assert.isNil(state:takeResult(), "ignored cancels settle nothing early")
  for _ = 1, BattleEvolutionState.SEQUENCE_TICKS do
    state:stepSourceTick(1)
  end
  Assert.equal(state:status().phase, "transformation", "setup: the cancellable beat starts")
  state:input({ { type = "cancel" } })
  Assert.equal(state:status().phase, "settled", "the transformation cancel still declines")
  local result = state:takeResult()
  Assert.notNil(result, "the declined sequence answers its choice")
  assert(result ~= nil, "the declined choice seals")
  Assert.isFalse(result.choice.evolved, "the declined candidate never evolves")
end

-- A full move set pauses for explicit answers in learnset order: replace
-- the first pending move, decline the second, and the staged set carries
-- exactly those decisions. Each pause carries the retail battery
-- (wants, however, should-delete, which-move) plus the summary hook; a replacement
-- voices SELECT, runs poof/forgot/and/learned, and waits out the LVUP
-- fanfare beat before continuing, while a decline voices SELECT, runs
-- stop-trying/did-not-learn, and continues at once.
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
  Assert.deepEqual(
    messageIds(state),
    { 916, 917, 918, 1193, 1194, 1195, 1196 },
    "the first pause carries battle What, evolving, evolved, and the full-set battery"
  )
  local first = state:learnPrompt()
  Assert.notNil(first, "the paused sequence exposes its learning prompt")
  assert(first ~= nil, "the first prompt stages")
  Assert.equal(first.move, "SCRATCH", "pending moves follow target learnset order")
  Assert.equal(#first.currentMoves, 4, "the prompt carries the four held moves")
  local summaries = {}
  for _, effect in ipairs(state:effects()) do
    if effect.kind == "summary" then
      summaries[#summaries + 1] = effect
    end
  end
  Assert.equal(#summaries, 1, "the first pause records one mode-2 summary hook")
  local hook = assert(summaries[1], "the summary hook stages")
  Assert.equal(hook.phase, "learn", "the summary hook rides the learn phase")
  Assert.deepEqual(hook.pages, { 1, 4, 0, 0 }, "the summary hook names the retail pages")
  Assert.equal(hook.mode, 2, "the summary hook names the replacement mode")
  Assert.equal(hook.move, "SCRATCH", "the summary hook keeps its legacy move key")
  Assert.equal(hook.moveToLearn, "SCRATCH", "the summary hook names the incoming move")
  Assert.deepEqual(
    hook.currentMoves,
    { "TACKLE", "GROWL", "RAZOR_LEAF", "POISONPOWDER" },
    "the summary hook carries the four held moves"
  )
  Assert.equal(hook.species, "TOTODILE", "the summary hook names the evolved species")
  Assert.equal(hook.form, 0, "the summary hook voices the subject form")
  first.currentMoves[1] = "MUTATED"
  first.move = "MUTATED"
  local reread = {}
  for _, effect in ipairs(state:effects()) do
    if effect.kind == "summary" then
      reread[#reread + 1] = effect
    end
  end
  Assert.equal(reread[1].moveToLearn, "SCRATCH", "the summary hook detaches the incoming move")
  Assert.deepEqual(
    reread[1].currentMoves,
    { "TACKLE", "GROWL", "RAZOR_LEAF", "POISONPOWDER" },
    "the summary hook detaches the held moves"
  )
  state:answerLearn({ choice = "replace", slot = 3 })
  Assert.equal(state:status().phase, "fanfare", "a replacement waits out its fanfare beat")
  Assert.isNil(state:takeResult(), "the fanfare beat settles nothing early")
  local forgotten = {}
  for _, effect in ipairs(state:effects()) do
    if effect.kind == "message" and effect.msg == BattleEvolutionState.MSG_FORGOT then
      forgotten[#forgotten + 1] = effect.move
    end
  end
  Assert.deepEqual(forgotten, { "POISONPOWDER" }, "the replacement forgets its named slot")
  Assert.deepEqual(
    messageIds(state),
    { 916, 917, 918, 1193, 1194, 1195, 1196, 1199, 1200, 1201, 1202 },
    "a replacement runs poof/forgot/and/learned"
  )
  Assert.equal(countKind(state, "fanfare_wait"), 1, "a replacement records its fanfare wait")
  for _, effect in ipairs(state:effects()) do
    if effect.kind == "fanfare_wait" then
      Assert.equal(effect.seq, 1184, "the fanfare wait voices SEQ_ME_LVUP")
    end
    if effect.kind == "sound" and effect.phase == "learn" then
      Assert.equal(effect.se, 1500, "menu answers voice SELECT")
    end
  end
  for _ = 1, BattleEvolutionState.FANFARE_TICKS do
    state:stepSourceTick(1)
  end
  Assert.equal(state:status().phase, "learn", "the fanfare beat continues to the next pending move")
  local second = state:learnPrompt()
  Assert.notNil(second, "the second pending move pauses in turn")
  assert(second ~= nil, "the second prompt stages")
  Assert.equal(second.move, "LEER", "the second pending move keeps learnset order")
  state:answerLearn({ choice = "decline" })
  Assert.equal(state:status().phase, "learn", "a declined prompt continues at once")
  Assert.equal(countKind(state, "fanfare_wait"), 1, "a decline records no fanfare wait")
  local declined = messageIds(state)
  Assert.equal(declined[#declined - 5], 1197, "a decline asks stop-trying")
  Assert.equal(declined[#declined - 4], 1198, "a decline reports did-not-learn")
  Assert.equal(declined[#declined - 3], 1193, "a decline advances to the next wants-to-learn")
  Assert.equal(declined[#declined - 2], 1194, "the next pause repeats however-four")
  Assert.equal(declined[#declined - 1], 1195, "the next pause repeats should-delete")
  Assert.equal(declined[#declined], 1196, "the next pause repeats which-move")
  local third = state:learnPrompt()
  Assert.notNil(third, "the third pending move pauses in turn")
  assert(third ~= nil, "the third prompt stages")
  Assert.equal(third.move, "WATER_GUN", "the third pending move keeps learnset order")
  state:answerLearn({ choice = "replace", slot = 0 })
  Assert.equal(state:status().phase, "fanfare", "the last replacement waits out its fanfare beat")
  for _ = 1, BattleEvolutionState.FANFARE_TICKS do
    state:stepSourceTick(1)
  end
  runUntilSettled(state, 60)
  local result = state:takeResult()
  Assert.notNil(result, "the answered sequence settles its choice")
  assert(result ~= nil, "the learned choice seals")
  Assert.isTrue(result.choice.evolved, "answered learning still evolves")
  Assert.deepEqual(
    messageIds(state),
    {
      916, 917, 918,
      1193, 1194, 1195, 1196,
      1199, 1200, 1201, 1202,
      1193, 1194, 1195, 1196,
      1197, 1198,
      1193, 1194, 1195, 1196,
      1199, 1200, 1201, 1202,
    },
    "the whole learning run sequences the retail message battery"
  )
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
    source = "trade",
  })
  Assert.equal(state:status().flags, 4, "trade passes retail flags 4")
  Assert.isFalse(state:status().printWhat, "trade never prints What")
  for _ = 1, BattleEvolutionState.ENTRY_TICKS + 1 do
    state:stepSourceTick(1)
  end
  Assert.isNil(state:status().canCancel, "trade evolutions refuse cancellation")
  state:input({ { type = "cancel" } })
  Assert.isTrue(state:status().active, "a refused cancel keeps the sequence alive")
  for _ = 1, BattleEvolutionState.SEQUENCE_TICKS do
    state:stepSourceTick(1)
  end
  Assert.equal(state:status().phase, "transformation", "setup: the cancellable beat starts")
  state:input({ { type = "cancel" } })
  Assert.isTrue(state:status().active, "trade refuses cancel even on the transformation beat")
  Assert.isNil(state:takeResult(), "a held sequence settles nothing early")
  Assert.deepEqual(
    messageIds(state),
    { 915 },
    "trade combines What-evolving with no lone What"
  )
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

-- Retail sources derive the scene flags: battle passes 3 (cancel plus
-- What), field level-up passes 1 (cancel only), stone/item passes 0, and
-- trade passes 4 (neither low bit set). Effective cancel additionally
-- requires a cancellable domain rule.
function T.sources_derive_retail_flags_cancel_and_what()
  local catalog = evolutionCatalog(graftLevelSlot)
  local cases = {
    { source = "battle", flags = 3, cancellable = true, printWhat = true },
    { source = "field_level", flags = 1, cancellable = true, printWhat = false },
    { source = "field_item", flags = 0, cancellable = false, printWhat = false },
  }
  for _, case in ipairs(cases) do
    local mon = subjectAt(catalog, "CHIKORITA", 16, { moveEntry("TACKLE") })
    local state = stateFor(catalog, mon, case.source)
    local status = state:status()
    Assert.equal(status.source, case.source, "status names its source")
    Assert.equal(status.flags, case.flags, case.source .. " passes its retail flags")
    Assert.equal(status.printWhat, case.printWhat, case.source .. " sets its What policy")
    if case.cancellable then
      Assert.isTrue(status.canCancel, case.source .. " keeps a cancellable rule cancellable")
    else
      Assert.isNil(status.canCancel, case.source .. " never cancels even a cancellable rule")
    end
    Assert.equal(state:draw().flags, case.flags, "the drawable record carries its flags")
  end
end

-- Stone/item sources never cancel even when the domain rule permits it:
-- retail stone callers pass flags 0.
function T.field_item_source_never_cancels()
  local catalog = evolutionCatalog(graftLevelSlot)
  local mon = subjectAt(catalog, "CHIKORITA", 16, { moveEntry("TACKLE") })
  local state = stateFor(catalog, mon, "field_item")
  for _ = 1, BattleEvolutionState.ENTRY_TICKS + BattleEvolutionState.SEQUENCE_TICKS do
    state:stepSourceTick(1)
  end
  Assert.equal(state:status().phase, "transformation", "setup: the cancellable beat starts")
  state:input({ { type = "cancel" } })
  Assert.isTrue(state:status().active, "stone/item input never cancels")
  runUntilSettled(state, 60)
  local result = state:takeResult()
  Assert.notNil(result, "the held sequence still completes on its own")
  assert(result ~= nil, "the held choice seals")
  Assert.isTrue(result.choice.evolved, "the unguided sequence applies its candidate")
  Assert.deepEqual(messageIds(state), { 915, 918 }, "stone/item skips the lone What")
end

-- The drawable record names the concrete retail assets the visual
-- owners must provide: main/sub background narcs, cursor sprites,
-- per-subject pictures, the particle resource, window/affine
-- parameters, and the summary hook.
function T.draw_names_retail_asset_requests()
  local catalog = evolutionCatalog(graftLevelSlot)
  local mon = subjectAt(catalog, "CHIKORITA", 16, { moveEntry("TACKLE") })
  local state = stateFor(catalog, mon)
  local drawn = state:draw()
  Assert.equal(drawn.kind, "evolution", "the drawable record names its kind")
  Assert.equal(drawn.source, "battle", "the drawable record names its source")
  Assert.equal(drawn.flags, 3, "the drawable record carries its flags")
  local assets = assert(drawn.assets, "the drawable record carries its asset manifest")
  Assert.equal(assets.mainBg.narc, "a_1_1_5", "the main background names its narc")
  Assert.equal(assets.mainBg.charMember, 0, "the main background names its char member")
  Assert.equal(assets.mainBg.scrnMember, 1, "the main background names its screen member")
  Assert.equal(assets.mainBg.paletteMember, 8, "the main background names its palette member")
  Assert.equal(assets.subBg.narc, "a_2_3_7", "the sub background names its narc")
  Assert.equal(assets.subBg.topCharMember, 16, "the sub background names its top char member")
  Assert.equal(assets.subBg.topScrnMember, 17, "the sub background names its top screen member")
  Assert.equal(assets.subBg.menuCharMember, 1, "the sub background names its menu char member")
  Assert.equal(assets.subBg.menuScrnMember, 10, "the sub background names its menu screen member")
  Assert.equal(assets.cursor.plttMember, 11, "the cursor names its palette member")
  Assert.equal(assets.cursor.charMember, 12, "the cursor names its char member")
  Assert.equal(assets.cursor.cellMember, 13, "the cursor names its cell member")
  Assert.equal(assets.cursor.animMember, 14, "the cursor names its anim member")
  Assert.deepEqual(
    assets.pokepic.old,
    { species = "CHIKORITA", form = 0 },
    "the old picture resolves per subject species and form"
  )
  Assert.deepEqual(
    assets.pokepic.new,
    { species = "TOTODILE", form = 0 },
    "the new picture resolves per target species and subject form"
  )
  Assert.equal(assets.particles.resource, 0, "the particle scene names its resource")
  Assert.deepEqual(
    assets.particles.emitterSequence,
    { { 0 }, { 1, 2, 7, 8, 9, 11 }, { 3, 4, 5, 6, 10 }, { 12 } },
    "the particle scene carries the retail emitter sequence"
  )
  Assert.equal(assets.window.narrowTop, 40, "the window names its narrow target")
  Assert.equal(assets.affine.scaleOscillation, 16, "the affine evidence names its oscillation")
  Assert.equal(assets.affine.scaleStep, 8, "the affine evidence names its scale step")
  Assert.deepEqual(assets.summary.pages, { 1, 4, 0, 0 }, "the summary hook names its pages")
  Assert.equal(assets.summary.mode, 2, "the summary hook names its mode")
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
