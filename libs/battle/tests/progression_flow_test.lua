-- In-battle rewards pause the battle instead of racing it: a knockout
-- that earns several levels pauses on every full-set learning prompt,
-- auto-fills when a slot is free, consumes each decision exactly once, and
-- restores from a plain frame without ever awarding twice.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

---@param behavior string missing owner under test
---@return table the loaded resumable-reward owner
local function progressionOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.Progression", behavior)
end

---@return table mon catalog built once from the fixed synthetic asset root
local function catalog()
  return CatalogFixture.makeCatalog()
end

---@param value unknown
---@return unknown detached copy of plain test data
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copy(item)
  end
  return out
end

---@param seed integer fixed generator state for this roster member
---@param overrides table<string, unknown>|nil generation request overrides
---@return table persistent mon record owned by the mon domain
local function makeMon(seed, overrides)
  local factory = CatalogFixture.makeFactory(seed, catalog())
  return factory:createNormal(CatalogFixture.normalRequest(overrides or {}))
end

---@param mon table mon record under test
---@param experience integer pinned cumulative experience under test
---@param hp integer pinned current health under test
local function pinProgressionBaseline(mon, experience, hp)
  mon.experience = experience
  mon.hp = hp
  mon.personality = 0
  for _, key in ipairs({ "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }) do
    mon.ivs[key] = 10
    mon.evs[key] = 0
  end
end

---@param mon table battle-owned mon copy under test
---@param expAward integer hand-specified experience award under test
---@param evAward table<string, integer> hand-specified effort award under test
---@return table reward input for one recipient
local function entry(mon, expAward, evAward)
  return { combatant = 1, mon = mon, expAward = expAward, evAward = evAward }
end

---@param entries table[] reward inputs under test
---@return table reward start input over the real catalog
local function startInput(entries)
  return {
    defeated = { combatant = 9, activation = 3 },
    entries = entries,
    catalog = catalog(),
  }
end

---@param events table[] outcome events under test
---@param kind string event identity under test
---@return table|nil the first event carrying that identity
local function findEvent(events, kind)
  for _, event in ipairs(events) do
    if type(event) == "table" and event.kind == kind then
      return event
    end
  end
  return nil
end

-- A full set pauses the battle on its learning prompt: the first step
-- reports the ordered prompt for the new move with the four current moves
-- and stays unfinished, the replacement lands with reset power points,
-- and the battle only completes once the decision is consumed.
function T.a_full_set_pauses_on_its_learning_prompt_until_replaced()
  local Progression = progressionOwner("resumable rewards own learning pauses and reload timing")
  Assert.isTrue(type(Progression.start) == "function", "the reward owner starts knockout work")
  Assert.isTrue(type(Progression.step) == "function", "the reward owner steps resumably")
  Assert.isTrue(type(Progression.validateFrame) == "function", "the reward owner validates frames")
  local mon = makeMon(11, {})
  pinProgressionBaseline(mon, 419, 28)
  local opened = Progression.start(startInput({ entry(mon, 600, { defense = 4 }) }))
  SessionFixture.assertPlainData(opened.frame, "reward frame")
  local paused = Progression.step(opened.flow, Progression.validateFrame(opened.frame), nil)
  Assert.isFalse(paused.done, "the battle stays paused while a prompt is outstanding")
  Assert.notNil(paused.request, "the pause carries its learning prompt")
  Assert.equal(paused.request.kind, "learn_move", "the prompt names move learning")
  Assert.equal(paused.request.combatant, 1, "the prompt names its recipient")
  Assert.equal(paused.request.incomingMove, "SYNTHESIS", "crossing to level twelve prompts synthesis")
  Assert.equal(#paused.request.currentMoves, 4, "the prompt carries the four current moves")
  Assert.isTrue(paused.request.canDecline, "the prompt can be declined")
  local stats = findEvent(paused.events, "stats")
  Assert.notNil(stats, "the pause reports its explicit stat reload")
  Assert.equal(stats.maxHpBefore, 28, "the reload opens from the level-nine maximum")
  Assert.equal(stats.maxHpAfter, 34, "the reload lands on the level-twelve maximum")
  local decided = Progression.step(
    paused.flow,
    Progression.validateFrame(paused.frame),
    { combatant = 1, decision = "replace", slot = 3 }
  )
  Assert.isTrue(decided.done, "the battle resumes once the decision is consumed")
  Assert.isNil(decided.request, "no prompt survives its decision")
  local moves = decided.flow.mons[1].moves
  Assert.equal(moves[4].move, "SYNTHESIS", "the replacement lands in the named slot")
  Assert.equal(moves[4].pp, 5, "a learned move resets to its base power points")
  Assert.equal(moves[4].ppUps, 0, "a learned move carries no power-point ups")
  Assert.equal(decided.flow.mons[1].experience, 1019, "the award applies exactly once")
  Assert.equal(decided.flow.mons[1].evs.defense, 4, "the effort award applies exactly once")
end

-- Free slots fill without prompting, declines stick, and stale replies
-- change nothing: the small award crosses one level and auto-learns with
-- base power points, the declined prompt keeps the old set, and replaying
-- either reply leaves the finished battle untouched.
function T.free_slots_fill_declines_stick_and_stale_replies_change_nothing()
  local Progression = progressionOwner("resumable rewards own learning pauses and reload timing")
  local small = makeMon(23, { level = 5 })
  pinProgressionBaseline(small, 135, 20)
  local opened = Progression.start(startInput({ entry(small, 100, { attack = 2 }) }))
  local finished = Progression.step(opened.flow, Progression.validateFrame(opened.frame), nil)
  Assert.isTrue(finished.done, "a free slot never pauses the battle")
  Assert.isNil(finished.request, "a free slot never prompts")
  local learned = findEvent(finished.events, "learn")
  Assert.notNil(learned, "the auto-fill reports its learned move")
  Assert.equal(learned.move, "RAZOR_LEAF", "crossing to level six auto-learns razor leaf")
  local moves = finished.flow.mons[1].moves
  Assert.equal(moves[3].move, "RAZOR_LEAF", "the new move fills the first free slot")
  Assert.equal(moves[3].pp, 25, "an auto-learned move resets to its base power points")

  local mon = makeMon(37, {})
  pinProgressionBaseline(mon, 419, 28)
  local pending = Progression.start(startInput({ entry(mon, 600, { defense = 4 }) }))
  local paused = Progression.step(pending.flow, Progression.validateFrame(pending.frame), nil)
  local declined = Progression.step(
    paused.flow,
    Progression.validateFrame(paused.frame),
    { combatant = 1, decision = "decline" }
  )
  Assert.isTrue(declined.done, "a decline resumes the battle")
  Assert.equal(declined.flow.mons[1].moves[4].move, "POISONPOWDER", "a decline keeps the old set")
  local stale = Progression.step(
    declined.flow,
    Progression.validateFrame(declined.frame),
    { combatant = 1, decision = "replace", slot = 3 }
  )
  Assert.isTrue(stale.done, "a stale reply after a decline stays finished")
  Assert.equal(#stale.events, 0, "a stale reply emits nothing new")
  Assert.equal(stale.flow.mons[1].moves[4].move, "POISONPOWDER", "a stale reply changes no move")
end

-- A frame copied mid-prompt restores the same battle: completing the copy
-- with the same replies reaches identical mons, the experience and effort
-- land exactly once, and two identical runs never diverge.
function T.a_frame_copied_mid_prompt_restores_without_double_award()
  local Progression = progressionOwner("resumable rewards own learning pauses and reload timing")
  local function runToPause(seed)
    local mon = makeMon(seed, {})
    pinProgressionBaseline(mon, 419, 28)
    local opened = Progression.start(startInput({ entry(mon, 600, { defense = 4 }) }))
    return Progression.step(opened.flow, Progression.validateFrame(opened.frame), nil)
  end
  local first = runToPause(51)
  local restoredFlow = { mons = copy(first.flow.mons), catalog = catalog() }
  local restoredFrame = Progression.validateFrame(copy(first.frame))
  SessionFixture.assertPlainData(restoredFrame, "restored frame")
  local reply = { combatant = 1, decision = "replace", slot = 3 }
  local done = Progression.step(first.flow, Progression.validateFrame(first.frame), reply)
  local redone = Progression.step(restoredFlow, restoredFrame, copy(reply))
  Assert.isTrue(done.done and redone.done, "both branches complete with the same reply")
  Assert.deepEqual(redone.flow.mons, done.flow.mons, "restore reaches identical mons")
  Assert.equal(done.flow.mons[1].experience, 1019, "restore awards experience exactly once")
  Assert.equal(done.flow.mons[1].evs.defense, 4, "restore awards effort exactly once")
  Assert.deepEqual(redone.events, done.events, "restore replays identical completion events")
  local second = runToPause(51)
  local secondDone = Progression.step(second.flow, Progression.validateFrame(second.frame), reply)
  Assert.deepEqual(secondDone.flow.mons, done.flow.mons, "identical runs never diverge")
end

---@return table loaded native session owner
local function executorOwner()
  return SessionFixture.requirePresent(
    "libs.battle.src.gen4.HgssSessionExecutor",
    "the private native lifecycle owns knockout rewards and learning prompts"
  )
end

local TEST_FORMAT = "test:native-format"
local TEST_SEED = 0x1BADB002

---@return table frozen battle content carrying the native ruleset binding
local function testContent()
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
  local Executor = executorOwner()
  local builder = ContentBuilder.new()
  NativeTypeChart.install(builder, "progression-flow-tests")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    Executor.RULESET,
    { key = Executor.RULESET, chart = Executor.RULESET },
    "progression-flow-tests"
  )
  behaviors:registerFormat(TEST_FORMAT, { key = TEST_FORMAT }, "progression-flow-tests")
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

---@param seeds table<integer, table<string, unknown>>? combatant seeds whose strikes and learnsets resolve
---@return table<string, table<string, unknown>> immutable move facts for the fixture strikes and learnsets
local function moveFactsFor(seeds)
  local catalog = catalog()
  local facts = {
    TACKLE = catalog:move("TACKLE"),
    STRUGGLE = { power = 50, accuracy = 100, category = "physical", moveType = "normal", priority = 0 },
  }
  for _, seed in ipairs(seeds or {}) do
    local learned = seed.mon --[[@as table<string, unknown>]]
    for _, moveEntry in ipairs(learned.moves --[[@as table<integer, table<string, unknown>>]]) do
      if type(moveEntry) == "table" and type(moveEntry.move) == "string" and facts[moveEntry.move] == nil then
        facts[moveEntry.move] = catalog:move(moveEntry.move)
      end
    end
    local form = catalog:form(learned.species --[[@as string]], learned.form --[[@as integer]])
    for _, chance in ipairs(form.levelUpMoves) do
      if facts[chance.move] == nil then
        facts[chance.move] = catalog:move(chance.move)
      end
    end
  end
  return facts
end

---@param formRecord table<string, unknown> catalog form record carrying its semantic types
---@return string[] detached semantic types for the form
local function copyFormTypes(formRecord)
  local types = {} ---@type string[]
  for _, key in ipairs(formRecord.types --[[@as string[] ]]) do
    types[#types + 1] = key --[[@as string]]
  end
  return types
end

---@param seeds table<integer, table<string, unknown>> combatant seeds under fact resolution
---@return table<string, table<string, unknown>> static species facts for the fixture combatants
local function speciesFactsFor(seeds)
  local facts = {}
  for _, seed in ipairs(seeds) do
    local mon = seed.mon --[[@as table<string, unknown>]]
    local species = mon.species --[[@as string]]
    local form = mon.form --[[@as integer]]
    local speciesRecord = catalog():species(species)
    local bucket = facts[species]
    if bucket == nil then
      bucket = {}
      facts[species] = bucket
    end
    bucket[form] = {
      baseStats = catalog():form(species, form).baseStats,
      growthCurve = catalog():growthCurve(speciesRecord.growthCurve --[[@as string]]),
      types = copyFormTypes(catalog():form(species, form)),
      levelUpMoves = catalog():form(species, form).levelUpMoves,
      baseExpYield = speciesRecord.baseExpYield,
      evYield = speciesRecord.evYield,
    }
  end
  return facts
end

---@param parts table sides/participants/positions under test
---@param seeds table<integer, table<string, unknown>> combatant seeds under fact resolution
---@return table detached native battle setup record
local function battleScenario(parts, seeds)
  return {
    ruleset = executorOwner().RULESET,
    format = TEST_FORMAT,
    sides = parts.sides,
    participants = parts.participants,
    positions = parts.positions,
    inventories = {},
    environment = { weather = "none" },
    random = { seed = TEST_SEED },
    formatState = {},
    moveFacts = moveFactsFor(seeds),
    speciesFacts = speciesFactsFor(seeds),
  }
end

---@param id integer nonreused combatant identity under test
---@param seed integer fixed generator state for the underlying mon
---@return table combatant seed striking with a single known move
local function tackleSeed(id, seed)
  local combatantEntry = SessionFixture.combatant(id, seed)
  combatantEntry.mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return combatantEntry
end

---@param session table live headless session under test
---@param frame table settled waiting frame carrying the open batch
---@param choose fun(request: table): table[] planned choices per pending request
local function answerRequests(session, frame, choose)
  Assert.notNil(frame.request, "waiting frames carry their decision batch")
  for _, request in ipairs(frame.request.requests) do
    local ok, err = session:submit(SessionFixture.replyFor(request, choose(request)))
    Assert.isTrue(ok, "planned replies are accepted")
    Assert.isNil(err, "accepted replies carry no input error")
  end
end

---@param session table live headless session under test
---@return table first non-running frame
---@return table[] events emitted while settling
local function drainEvents(session)
  local collected = {} ---@type table[]
  for _ = 1, 64 do
    local frame = session:advance(64)
    Assert.notNil(frame, "advance returns a battle frame")
    for _, event in ipairs(frame.events or {}) do
      collected[#collected + 1] = event
    end
    if frame.status ~= "running" then
      return frame, collected
    end
  end
  error("the planned turn never settled")
end

---@param collected table[] emitted events under inspection
---@return table<integer, integer[]> experience gained per recipient combatant, in order
local function expGains(collected)
  local gains = {} ---@type table<integer, integer[]>
  for _, event in ipairs(collected) do
    if type(event) == "table" and event.kind == "exp" then
      local combatant = event.combatant --[[@as integer]]
      gains[combatant] = gains[combatant] or {}
      gains[combatant][#gains[combatant] + 1] = event.gained --[[@as integer]]
    end
  end
  return gains
end

---@param frame table settled battle frame under inspection
---@return table|nil the pending learning prompt, when one is open
local function findLearnPrompt(frame)
  if frame.request == nil then
    return nil
  end
  for _, request in ipairs(frame.request.requests) do
    if request.kind == "learn_move" then
      return request
    end
  end
  return nil
end

---@param actor table addressed recipient entry under reply
---@param decision string replace or decline
---@param slot integer? zero-based move slot for replacements
---@return table decision choice carrying the learning reply
local function learnReply(actor, decision, slot)
  local payload = { decision = decision }
  if slot ~= nil then
    payload.slot = slot
  end
  return { actor = actor, kind = "confirm", payload = payload }
end

-- Knockout credit never leaks across foes: the opener earns against the
-- first foe by facing it, the reserve earns against the first foe by
-- relieving it, and only the reserve earns against the second foe because
-- the opener never takes the field against it.
function T.knockout_participation_stays_with_the_foe_it_was_earned_against()
  local contracts = SessionFixture.sessionContracts()
  local content = testContent()
  local first = tackleSeed(1, 11)
  local second = tackleSeed(3, 31)
  local foeOne = tackleSeed(2, 23)
  foeOne.mon.condition.currentHp = 1
  local foeTwo = tackleSeed(4, 41)
  foeTwo.mon.condition.currentHp = 1
  local seeds = { first, second, foeOne, foeTwo }
  local session = contracts.Battle.newSession(battleScenario({
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", { first, second }),
      SessionFixture.participant(2, 2, "beta", { foeOne, foeTwo }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
  }, seeds), content)
  local function strikeFoe(request)
    local actor = assert(request.actors[1], "action batches address their actor")
    if request.controller == "alpha" then
      if request.actors[1].combatant == 1 then
        return { SessionFixture.switchChoice(actor, 3) }
      end
      return { SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2)) }
    end
    return { SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(1)) }
  end
  local opening = SessionFixture.driveUntilSettled(session)
  answerRequests(session, opening, strikeFoe)
  local afterFirst, reliefEvents = drainEvents(session)
  Assert.equal(afterFirst.status, "waiting", "the relief turn opens its own batch")
  Assert.isNil(next(expGains(reliefEvents)), "the relief turn awards nothing")
  answerRequests(session, afterFirst, function(request)
    local actor = assert(request.actors[1], "action batches address their actor")
    return { SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(request.controller == "alpha" and 2 or 1)) }
  end)
  local afterSecond, foeOneEvents = drainEvents(session)
  Assert.equal(afterSecond.status, "waiting", "the second foe opens its own batch")
  local foeOneGains = expGains(foeOneEvents)
  Assert.deepEqual(foeOneGains[1], { 41 }, "the opener earns its participant half of the first knockout")
  Assert.deepEqual(foeOneGains[3], { 41 }, "the reserve earns its participant half of the first knockout")
  answerRequests(session, afterSecond, function(request)
    local actor = assert(request.actors[1], "action batches address their actor")
    return { SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(request.controller == "alpha" and 2 or 1)) }
  end)
  local ended, foeTwoEvents = drainEvents(session)
  Assert.equal(ended.status, "ended", "the second knockout ends the battle with no reserve behind it")
  local foeTwoGains = expGains(foeTwoEvents)
  Assert.isNil(foeTwoGains[1], "the opener earns nothing from a foe it never faced")
  Assert.deepEqual(foeTwoGains[3], { 82 }, "the reserve keeps the whole second knockout")
  session:dispose()
end

-- Portions and trade facts combine from the recipient record and the
-- player context: the active share holder keeps both halves unmultiplied,
-- the benched holder and the switched-in battler take the same-language
-- trade lift, and a foreign player context lifts both traded recipients
-- to the foreign rate while the locally owned holder stays flat.
function T.shared_and_traded_portions_combine_from_player_and_mon_facts()
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local profile = CatalogFixture.profile()
  local contracts = SessionFixture.sessionContracts()
  local content = testContent()
  local tradedProfile = { name = "BLUE", gender = 0, trainerId = 12345678 }
  ---@param language string player language carried by the scenario context
  ---@return table settled experience gains per recipient after one shared knockout
  local function runSharedKnockout(language)
    local lead = tackleSeed(1, 11)
    lead.mon.heldItem = "EXP__SHARE"
    local switched = SessionFixture.combatant(3, 32)
    switched.mon = makeMon(32, { profile = tradedProfile })
    switched.mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
    local benched = SessionFixture.combatant(5, 52)
    benched.mon = makeMon(52, { profile = tradedProfile })
    benched.mon.heldItem = "EXP__SHARE"
    local foe = tackleSeed(2, 23)
    foe.mon.condition.currentHp = 1
    local seeds = { lead, switched, benched, foe }
    local alphaSpec = SessionFixture.participant(1, 1, "alpha", { lead, switched, benched })
    alphaSpec.context =
      { trainerId = profile.trainerId, trainerName = profile.name, language = language }
    local session = contracts.Battle.newSession(battleScenario({
      sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
      participants = {
        alphaSpec,
        SessionFixture.participant(2, 2, "beta", { foe }),
      },
      positions = {
        SessionFixture.position(1, 1, { 1 }, 1),
        SessionFixture.position(2, 2, { 2 }, 2),
      },
    }, seeds), content)
    local opening = SessionFixture.driveUntilSettled(session)
    answerRequests(session, opening, function(request)
      local actor = assert(request.actors[1], "action batches address their actor")
      if request.controller == "alpha" then
        return { SessionFixture.switchChoice(actor, 3) }
      end
      return { SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(1)) }
    end)
    local relieved, reliefEvents = drainEvents(session)
    Assert.equal(relieved.status, "waiting", "the relief turn opens its own batch")
    Assert.isNil(next(expGains(reliefEvents)), "the relief turn awards nothing")
    answerRequests(session, relieved, function(request)
      local actor = assert(request.actors[1], "action batches address their actor")
      return { SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(request.controller == "alpha" and 2 or 1)) }
    end)
    local ended, closing = drainEvents(session)
    Assert.equal(ended.status, "ended", "the lone foe ends the battle once it falls")
    local gains = expGains(closing)
    session:dispose()
    return gains
  end
  local home = runSharedKnockout("english")
  Assert.deepEqual(home[1], { 40 }, "the participating holder keeps both halves unmultiplied")
  Assert.deepEqual(home[5], { 30 }, "the benched holder takes the same-language trade lift")
  Assert.deepEqual(home[3], { 30 }, "the switched-in battler takes the same-language trade lift")
  local away = runSharedKnockout("french")
  Assert.deepEqual(away[1], { 40 }, "matching ownership stays flat even under a foreign context")
  Assert.deepEqual(away[5], { 34 }, "the benched holder takes the foreign lift")
  Assert.deepEqual(away[3], { 34 }, "the switched-in battler takes the foreign lift")
end

---@param playerContext table<string, unknown> player participant context under reward
---@return boolean settledWithoutError
---@return unknown settlementError
---@return table[] eventsEmitted
local function settleKnockoutWithPlayerContext(playerContext)
  local contracts = SessionFixture.sessionContracts()
  local content = testContent()
  local first = tackleSeed(1, 11)
  local foe = tackleSeed(2, 23)
  foe.mon.condition.currentHp = 1
  local seeds = { first, foe }
  local alphaSpec = SessionFixture.participant(1, 1, "alpha", { first })
  alphaSpec.context = playerContext
  local session = contracts.Battle.newSession(battleScenario({
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      alphaSpec,
      SessionFixture.participant(2, 2, "beta", { foe }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
  }, seeds), content)
  local opening = SessionFixture.driveUntilSettled(session)
  answerRequests(session, opening, function(request)
    local actor = assert(request.actors[1], "action batches address their actor")
    if request.controller == "alpha" then
      return { SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2)) }
    end
    return { SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(1)) }
  end)
  local collected = {} ---@type table[]
  local ok, err = pcall(function()
    for _ = 1, 64 do
      local frame = session:advance(64)
      Assert.notNil(frame, "advance returns a battle frame")
      for _, event in ipairs(frame.events or {}) do
        collected[#collected + 1] = event
      end
      if frame.status ~= "running" then
        return
      end
    end
    error("the planned turn never settled")
  end)
  session:dispose()
  return ok, err, collected
end

---@param err unknown settlement error under inspection
---@return string? the domain error code, when the failure carries one
local function settlementCode(err)
  if type(err) ~= "table" then
    return nil
  end
  return (err --[[@as table<string, unknown>]]).code --[[@as string?]]
end

-- A production-marked player context without identity facts is invalid
-- composition: the knockout fails through the missing-identity path
-- and publishes no award.
function T.production_marked_contexts_without_player_facts_fail_the_reward()
  local ok, err, collected = settleKnockoutWithPlayerContext({ productionPlayer = true })
  Assert.isFalse(ok, "a marked context without facts fails instead of awarding")
  Assert.equal(settlementCode(err), "BATTLE_MISSING_BEHAVIOR", "the failure names the missing player identity")
  Assert.isNil(next(expGains(collected)), "no award is published")
end

-- A production-marked context with half-wired facts fails the same way:
-- partial identity never guesses an award.
function T.production_marked_contexts_with_half_wired_facts_fail_the_reward()
  local ok, err, collected =
    settleKnockoutWithPlayerContext({ productionPlayer = true, trainerId = 99, trainerName = "MINT" })
  Assert.isFalse(ok, "a marked context with half facts fails instead of awarding")
  Assert.equal(settlementCode(err), "BATTLE_MISSING_BEHAVIOR", "the failure names the missing player identity")
  Assert.isNil(next(expGains(collected)), "no award is published")
end

-- A benched share earner with a full set learns through its roster
-- identity: the prompt carries no entry token, a tokened reply is
-- rejected, the combatant-only reply replaces exactly once, interruption
-- replays the same prompt and completion, and experience lands once.
function T.benched_share_earners_learn_through_a_roster_scoped_prompt()
  local contracts = SessionFixture.sessionContracts()
  local Executor = executorOwner()
  local content = testContent()
  local striker = tackleSeed(1, 11)
  local learnerSeed = SessionFixture.combatant(3, 61)
  learnerSeed.mon.experience = 972
  learnerSeed.mon.heldItem = "EXP__SHARE"
  learnerSeed.mon.moves = {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "GROWL", pp = 40, ppUps = 0 },
    { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
    { move = "POISONPOWDER", pp = 30, ppUps = 0 },
  }
  local foe = tackleSeed(2, 23)
  foe.mon.condition.currentHp = 1
  local seeds = { striker, learnerSeed, foe }
  local session = contracts.Battle.newSession(battleScenario({
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", { striker, learnerSeed }),
      SessionFixture.participant(2, 2, "beta", { foe }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
  }, seeds), content)
  local opening = SessionFixture.driveUntilSettled(session)
  answerRequests(session, opening, function(request)
    local actor = assert(request.actors[1], "action batches address their actor")
    return { SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(request.controller == "alpha" and 2 or 1)) }
  end)
  local suspended, knockoutEvents = drainEvents(session)
  Assert.equal(suspended.status, "waiting", "the full set suspends the battle on its prompt")
  local prompt = findLearnPrompt(suspended)
  Assert.notNil(prompt, "the suspension names the pending learning prompt")
  Assert.equal(prompt.controller, "alpha", "the owning side answers its own learning prompt")
  local actor = assert(prompt.actors[1], "the prompt addresses its recipient")
  Assert.equal(actor.combatant, 3, "the prompt addresses the benched recipient")
  Assert.isNil(actor.activation, "learning prompts carry no entry token")
  Assert.equal(prompt.incomingMove, "SYNTHESIS", "crossing to level twelve prompts synthesis")
  Assert.equal(#prompt.currentMoves, 4, "the prompt carries the four current moves")
  local gains = expGains(knockoutEvents)
  Assert.deepEqual(gains[3], { 41 }, "the benched share lands once before the prompt")
  local tokened, tokenErr =
    session:submit(SessionFixture.replyFor(prompt, { learnReply({ combatant = 3, activation = 999 }, "replace", 3) }))
  Assert.isFalse(tokened, "a tokened learning reply answers nothing")
  Assert.notNil(tokenErr, "rejected learning replies report their input error")
  local snapshot = session:capture()
  SessionFixture.assertPlainData(snapshot, "pending learning")
  local revived = Executor.restore(snapshot, content)
  local first = SessionFixture.driveUntilSettled(session)
  local second = SessionFixture.driveUntilSettled(revived)
  Assert.deepEqual(second.request, first.request, "restored sessions reopen the identical learning prompt")
  for _, live in ipairs({ session, revived }) do
    local held = assert(findLearnPrompt(live == session and first or second), "the run keeps its prompt")
    local entry = assert(held.actors[1], "the prompt addresses its recipient")
    local ok, err = live:submit(SessionFixture.replyFor(held, { learnReply({ combatant = entry.combatant }, "replace", 3) }))
    Assert.isTrue(ok, "the combatant-only reply is accepted")
    Assert.isNil(err, "accepted replies carry no input error")
  end
  local firstEnded, firstClosing = drainEvents(session)
  local secondEnded, secondClosing = drainEvents(revived)
  Assert.equal(firstEnded.status, "ended", "the uninterrupted run ends after learning")
  Assert.equal(secondEnded.status, "ended", "the restored run ends after learning")
  Assert.deepEqual(secondClosing, firstClosing, "restored sessions replay the same completion")
  for _, live in ipairs({ session, revived }) do
    local finished = live:capture()
    Assert.equal(finished.combatants[3].mon.moves[4].move, "SYNTHESIS", "the replacement lands in the named slot")
    Assert.equal(finished.combatants[3].mon.experience, 1013, "the reply never awards twice")
  end
  Assert.deepEqual(
    firstEnded.outcome.evolutionEligible,
    { 3 },
    "the level gain surfaces once for post-battle handling"
  )
  session:dispose()
  revived:dispose()
end

-- Declining keeps the old set: the benched prompt resolves without
-- touching a move, the battle resumes past the same continuation once,
-- and the shared award still lands exactly once.
function T.benched_learners_keep_their_set_when_they_decline()
  local contracts = SessionFixture.sessionContracts()
  local content = testContent()
  local striker = tackleSeed(1, 11)
  local learnerSeed = SessionFixture.combatant(3, 61)
  learnerSeed.mon.experience = 972
  learnerSeed.mon.heldItem = "EXP__SHARE"
  learnerSeed.mon.moves = {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "GROWL", pp = 40, ppUps = 0 },
    { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
    { move = "POISONPOWDER", pp = 30, ppUps = 0 },
  }
  local foe = tackleSeed(2, 23)
  foe.mon.condition.currentHp = 1
  local seeds = { striker, learnerSeed, foe }
  local session = contracts.Battle.newSession(battleScenario({
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", { striker, learnerSeed }),
      SessionFixture.participant(2, 2, "beta", { foe }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
  }, seeds), content)
  local opening = SessionFixture.driveUntilSettled(session)
  answerRequests(session, opening, function(request)
    local actor = assert(request.actors[1], "action batches address their actor")
    return { SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(request.controller == "alpha" and 2 or 1)) }
  end)
  local suspended, _ = drainEvents(session)
  local prompt = findLearnPrompt(suspended)
  Assert.notNil(prompt, "the suspension names the pending learning prompt")
  local actor = assert(prompt.actors[1], "the prompt addresses its recipient")
  Assert.isNil(actor.activation, "benched prompts carry no entry token")
  local ok, err = session:submit(
    SessionFixture.replyFor(prompt, { learnReply({ combatant = actor.combatant }, "decline") })
  )
  Assert.isTrue(ok, "the decline is accepted")
  Assert.isNil(err, "accepted replies carry no input error")
  local ended, closing = drainEvents(session)
  Assert.equal(ended.status, "ended", "the decline resumes the battle past learning")
  local finished = session:capture()
  Assert.equal(finished.combatants[3].mon.moves[4].move, "POISONPOWDER", "a decline keeps the old set")
  Assert.equal(finished.combatants[3].mon.experience, 1013, "the award applies exactly once")
  Assert.isNil(findLearnPrompt(ended), "no prompt survives its decision")
  Assert.notNil(findEvent(closing, "declined"), "the decline reports its decision")
  session:dispose()
end

-- Active earners learn through the same roster identity: a full-set
-- recipient that dealt the knockout answers with its combatant alone and
-- resumes without a second award.
function T.active_learners_answer_without_an_entry_token()
  local contracts = SessionFixture.sessionContracts()
  local content = testContent()
  local learnerSeed = SessionFixture.combatant(1, 11)
  learnerSeed.mon.experience = 972
  learnerSeed.mon.moves = {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "GROWL", pp = 40, ppUps = 0 },
    { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
    { move = "POISONPOWDER", pp = 30, ppUps = 0 },
  }
  local foe = tackleSeed(2, 23)
  foe.mon.condition.currentHp = 1
  local seeds = { learnerSeed, foe }
  local session = contracts.Battle.newSession(battleScenario({
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", { learnerSeed }),
      SessionFixture.participant(2, 2, "beta", { foe }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
  }, seeds), content)
  local opening = SessionFixture.driveUntilSettled(session)
  answerRequests(session, opening, function(request)
    local actor = assert(request.actors[1], "action batches address their actor")
    return { SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(request.controller == "alpha" and 2 or 1)) }
  end)
  local suspended, _ = drainEvents(session)
  Assert.equal(suspended.status, "waiting", "the full set suspends the battle on its prompt")
  local prompt = findLearnPrompt(suspended)
  Assert.notNil(prompt, "the suspension names the pending learning prompt")
  local actor = assert(prompt.actors[1], "the prompt addresses its recipient")
  Assert.equal(actor.combatant, 1, "the prompt addresses the active recipient")
  Assert.isNil(actor.activation, "active prompts carry no entry token either")
  local ok, err = session:submit(
    SessionFixture.replyFor(prompt, { learnReply({ combatant = 1 }, "replace", 3) })
  )
  Assert.isTrue(ok, "the combatant-only reply is accepted")
  Assert.isNil(err, "accepted replies carry no input error")
  local ended, closing = drainEvents(session)
  Assert.equal(ended.status, "ended", "the battle ends once learning resolves")
  local finished = session:capture()
  Assert.equal(finished.combatants[1].mon.moves[4].move, "SYNTHESIS", "the replacement lands in the named slot")
  Assert.isNil(next(expGains(closing)), "the reply awards no experience again")
  session:dispose()
end

-- A foe that leaves and returns starts a fresh participant set: credit
-- earned against its first entry never follows it back, so only the
-- battler facing its final entry earns the knockout.
function T.reentered_foes_start_a_fresh_participant_set()
  local contracts = SessionFixture.sessionContracts()
  local content = testContent()
  local first = tackleSeed(1, 11)
  local second = tackleSeed(3, 31)
  local foeOne = tackleSeed(2, 23)
  foeOne.mon.condition.currentHp = 1
  -- The second foe stays healthy: it must survive the turn it enters so
  -- it can yield the field back, proving the return starts fresh.
  local foeTwo = tackleSeed(4, 41)
  local seeds = { first, second, foeOne, foeTwo }
  local session = contracts.Battle.newSession(battleScenario({
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", { first, second }),
      SessionFixture.participant(2, 2, "beta", { foeOne, foeTwo }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
  }, seeds), content)
  local opening = SessionFixture.driveUntilSettled(session)
  answerRequests(session, opening, function(request)
    local actor = assert(request.actors[1], "action batches address their actor")
    if request.controller == "alpha" then
      return { SessionFixture.switchChoice(actor, 3) }
    end
    return { SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(1)) }
  end)
  local relieved, _ = drainEvents(session)
  Assert.equal(relieved.status, "waiting", "the relief turn opens its own batch")
  answerRequests(session, relieved, function(request)
    local actor = assert(request.actors[1], "action batches address their actor")
    if request.controller == "beta" then
      return { SessionFixture.switchChoice(actor, 4) }
    end
    return { SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2)) }
  end)
  local swapped, _ = drainEvents(session)
  Assert.equal(swapped.status, "waiting", "the foe swap opens its own batch")
  answerRequests(session, swapped, function(request)
    local actor = assert(request.actors[1], "action batches address their actor")
    if request.controller == "beta" then
      return { SessionFixture.switchChoice(actor, 2) }
    end
    return { SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2)) }
  end)
  local settled, closing = drainEvents(session)
  Assert.equal(settled.status, "waiting", "the reserve behind the fallen foe opens its own batch")
  local gains = expGains(closing)
  Assert.isNil(gains[1], "the departed opener earns nothing from the final knockout")
  Assert.deepEqual(gains[3], { 82 }, "the remaining battler keeps the whole final knockout")
  local standing = session:capture()
  Assert.notNil(standing.combatants[4].active, "the yielding foe holds the field behind its return")
  session:dispose()
end

-- Ordinary battlefield choices still bind their live entry: a reply that
-- omits the token cannot answer an action batch, while the addressed
-- entry answers normally.
function T.action_replies_still_bind_their_live_entry_token()
  local contracts = SessionFixture.sessionContracts()
  local content = testContent()
  local first = tackleSeed(1, 11)
  local foe = tackleSeed(2, 23)
  local seeds = { first, foe }
  local session = contracts.Battle.newSession(battleScenario({
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", { first }),
      SessionFixture.participant(2, 2, "beta", { foe }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
  }, seeds), content)
  local opening = SessionFixture.driveUntilSettled(session)
  local action = assert(opening.request.requests[1], "the opening batch carries its action request")
  local actor = assert(action.actors[1], "the action request addresses its live entry")
  Assert.notNil(actor.activation, "action batches keep addressing live entries")
  local bare = { combatant = actor.combatant }
  local refused, refuseErr =
    session:submit(SessionFixture.replyFor(action, { SessionFixture.attackChoice(bare, 0, SessionFixture.positionTarget(2)) }))
  Assert.isFalse(refused, "a tokenless reply answers no live entry")
  Assert.notNil(refuseErr, "rejected replies report their input error")
  local ok, err = session:submit(
    SessionFixture.replyFor(action, { SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2)) })
  )
  Assert.isTrue(ok, "the addressed entry still answers")
  Assert.isNil(err, "accepted replies carry no input error")
  session:dispose()
end
-- fail at the validation boundary, unknown decisions and stray slots
-- raise the typed input error with the prompt still outstanding, and a
-- knockout with no recipients completes at once with no events.
function T.invalid_frames_and_replies_hold_the_continuation()
  local Progression = progressionOwner("resumable rewards own learning pauses and reload timing")
  local BattleErrors = require("libs.battle.src.errors")
  local Errors = require("libs.errors.src.Errors")
  Assert.throws(function()
    Progression.validateFrame({ kind = "progression" })
  end, "a frame without recipients fails")
  local mon = makeMon(71, {})
  pinProgressionBaseline(mon, 419, 28)
  local opened = Progression.start(startInput({ entry(mon, 600, { defense = 4 }) }))
  local paused = Progression.step(opened.flow, Progression.validateFrame(opened.frame), nil)
  Assert.isFalse(paused.done, "the prompt is outstanding")
  local held = copy(paused.frame)
  local unknown = Assert.throws(function()
    Progression.step(paused.flow, Progression.validateFrame(paused.frame), { combatant = 1, decision = "forget" })
  end, "an unknown decision raises the typed input error")
  Assert.isTrue(Errors.is(unknown), "the decision error is a domain error")
  Assert.equal(unknown.code, BattleErrors.INPUT, "the decision error names invalid input")
  Assert.deepEqual(paused.frame, held, "a rejected reply leaves the continuation untouched")
  local stray = Assert.throws(function()
    Progression.step(
      paused.flow,
      Progression.validateFrame(paused.frame),
      { combatant = 1, decision = "replace", slot = 9 }
    )
  end, "a stray slot raises the typed input error")
  Assert.equal(stray.code, BattleErrors.INPUT, "the slot error names invalid input")
  Assert.deepEqual(paused.frame, held, "a rejected slot leaves the continuation untouched")
  local quiet = Progression.start({ defeated = { combatant = 9, activation = 3 }, entries = {}, catalog = catalog() })
  local settled = Progression.step(quiet.flow, Progression.validateFrame(quiet.frame), nil)
  Assert.isTrue(settled.done, "a knockout with no recipients completes at once")
  Assert.equal(#settled.events, 0, "a knockout with no recipients emits nothing")
end

return { tests = T }
