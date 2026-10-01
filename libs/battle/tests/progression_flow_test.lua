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

-- Invalid frames and replies never move the battle: malformed frames
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
