-- Opponent controller determinism: recorded selection answers each owned
-- request once no matter how often the host polls, human arrival order and
-- idle polls never move the outcome, ordinary views expose no private
-- information, wild fighters pick source attacks without trainer options,
-- scripted fighters replay only their listed actions, and rejected replies
-- never consume the open request. Composition runs through the real
-- session, protocol, view, and native stream owners.

local Assert = require("tests.support.Assert")
local BattleRng = require("libs.battle.src.gen4.BattleRng")
local SessionFixture = require("libs.battle.tests.session_fixture")

local AI_MODULE = "libs.hgss.src.battle.HgssTrainerAi"
local OPPONENTS_MODULE = "libs.hgss.src.battle.HgssOpponentControllers"

local T = {}

local FIXED_SEED = 11259375

---@param name string module path under test
---@param behavior string observable behavior the module owns
---@return table the loaded module
local function requirePresent(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing controller behavior: " .. behavior .. " (" .. name .. ")")
  assert(loaded ~= nil, "the controller module loads")
  return loaded --[[@as table]]
end

---@return table scenario parts with a human side and an owned-opponent side
local function duel()
  return {
    sides = {
      SessionFixture.side(1, { 1 }),
      SessionFixture.side(2, { 2 }),
    },
    participants = {
      SessionFixture.participant(1, 1, "human", {
        SessionFixture.combatant(1, 11),
        SessionFixture.combatant(2, 12),
      }),
      SessionFixture.participant(2, 2, "ai", {
        SessionFixture.combatant(3, 23),
        SessionFixture.combatant(4, 24),
      }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 3),
    },
    inventories = {},
  }
end

---@param request table pending decision request
---@return table[] one strike per addressed actor
local function strikeEveryone(request)
  local choices = {}
  for _, actor in ipairs(request.actors) do
    choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(1))
  end
  return choices
end

---@param requests table[] pending decision requests
---@param controller string
---@return table the request owned by the controller
local function ownedRequest(requests, controller)
  for _, request in ipairs(requests) do
    if request.controller == controller then
      return request
    end
  end
  error("no request for controller " .. controller, 0)
end

---@return table selection controller bound to a fixed program
local function boundAi()
  local Ai = requirePresent(AI_MODULE, "the native controller binds flags and programs to decisions")
  return Ai.new({ program = { key = "youngster_opening", revision = "native-1", instructions = {}, entryPoints = {} }, aiPasses = {} })
end

-- A recorded reply survives any amount of polling: repeated decisions over
-- the same owned request return identical choices, and only the first
-- evaluation touches the native stream.
function T.recorded_replies_survive_repeated_polls()
  local controller = boundAi()
  local stream = BattleRng.new(FIXED_SEED)
  local session = SessionFixture.newSession(SessionFixture.sessionContracts(), SessionFixture.buildScenario(duel()))
  local waiting = SessionFixture.driveUntilSettled(session, 64)
  Assert.equal(waiting.status, "waiting", "open battles wait for both controllers")
  local request = ownedRequest(waiting.request.requests, "ai")
  local observation = session:view("ai")
  local first = controller:decide(request, observation, stream)
  local afterFirst = stream:capture()
  Assert.isTrue(afterFirst.calls > 0, "the first evaluation may draw from the native stream")
  local second = controller:decide(request, observation, stream)
  local third = controller:decide(request, observation, stream)
  Assert.deepEqual(second, first, "a second poll returns the recorded reply")
  Assert.deepEqual(third, first, "a third poll returns the recorded reply")
  Assert.deepEqual(stream:capture(), afterFirst, "repolls draw nothing more")
  Assert.equal(first.requestId, request.requestId, "the reply stays bound to its request")
  Assert.equal(first.epoch, request.epoch, "the reply stays bound to its batch epoch")
  Assert.equal(first.controller, "ai", "the reply names its controller")
end

-- Arrival order and idle host polls leave the outcome identical: answering
-- the human first or the owned opponent first, with extra advances in
-- between, emits the same event sequence and the same terminal result.
function T.arrival_order_and_idle_polls_leave_outcomes_identical()
  local contracts = SessionFixture.sessionContracts()
  ---@param reversed boolean
  ---@param polls integer
  ---@return table[] every emitted event in sequence order
  local function runBattle(reversed, polls)
    local controller = boundAi()
    local aiStream = BattleRng.new(FIXED_SEED)
    local session = SessionFixture.newSession(contracts, SessionFixture.buildScenario(duel()))
    local waiting = SessionFixture.driveUntilSettled(session, 64)
    local ordered = {}
    for _, request in ipairs(waiting.request.requests) do
      ordered[#ordered + 1] = request
    end
    if reversed then
      local flipped = {}
      for index = #ordered, 1, -1 do
        flipped[#flipped + 1] = ordered[index]
      end
      ordered = flipped
    end
    for _ = 1, polls do
      local idle = session:advance(64)
      Assert.equal(idle.status, "waiting", "idle polls keep waiting for the same batch")
      Assert.equal(idle.request.epoch, waiting.request.epoch, "idle polls never open a new batch")
    end
    for _, request in ipairs(ordered) do
      local reply
      if request.controller == "ai" then
        reply = controller:decide(request, session:view("ai"), aiStream)
      else
        reply = SessionFixture.replyFor(request, strikeEveryone(request))
      end
      local ok, err = session:submit(reply)
      Assert.isTrue(ok, "ordered legal replies are accepted")
      Assert.isNil(err, "accepted replies carry no input error")
    end
    return SessionFixture.driveToEnd(session, 64, function(request)
      if request.controller == "ai" then
        return controller:decide(request, session:view("ai"), aiStream).choices
      end
      return strikeEveryone(request)
    end)
  end
  local forward = runBattle(false, 0)
  local backward = runBattle(true, 5)
  Assert.isTrue(#forward > 0, "the ordered battle emits events")
  Assert.deepEqual(backward, forward, "arrival order and idle polls never move the outcome")
end

-- Ordinary controller views expose no private information: the human reads
-- only public health bars for opposing entries while full reads stay behind
-- the separate privileged entrypoint.
function T.ordinary_views_carry_no_private_information()
  local contracts = SessionFixture.sessionContracts()
  local session = SessionFixture.newSession(contracts, SessionFixture.buildScenario(duel()))
  SessionFixture.driveUntilSettled(session, 64)
  local view = session:view("human")
  Assert.isTrue(type(view.opponents) == "table" and #view.opponents > 0, "the human sees opposing entries")
  for _, opponent in ipairs(view.opponents) do
    Assert.isNil(opponent.moves, "opposing moves never leak into the ordinary view")
    Assert.isNil(opponent.heldItem, "opposing items never leak into the ordinary view")
    Assert.isNil(opponent.mon, "opposing rosters never leak into the ordinary view")
    Assert.isTrue(type(opponent.hp) == "table" or type(opponent.hp) == "number", "health bars stay visible")
  end
  Assert.isTrue(type(view.combatants) == "table" and #view.combatants > 0, "owned combatants stay visible")
end

-- Wild fighters pick source attacks without trainer options: every reply
-- carries the validated shape, every choice strikes, and the same seed
-- replays the same reply.
function T.wild_fighters_attack_without_trainer_options()
  local Opponents = requirePresent(
    OPPONENTS_MODULE,
    "wild and scripted policies answer through the shared reply shape"
  )
  Assert.isTrue(type(Opponents.wild) == "function", "the wild policy answers owned requests")
  local contracts = SessionFixture.sessionContracts()
  local session = SessionFixture.newSession(contracts, SessionFixture.buildScenario(duel()))
  local waiting = SessionFixture.driveUntilSettled(session, 64)
  local request = ownedRequest(waiting.request.requests, "ai")
  ---@return table validated wild reply for the fixed request
  local function decideWild()
    return Opponents.wild(request, session:view("ai"), BattleRng.new(FIXED_SEED))
  end
  local first = decideWild()
  contracts.Protocol.validateReply(first, "action")
  for _, choice in ipairs(first.choices) do
    Assert.equal(choice.kind, "attack", "wild fighters only strike")
  end
  Assert.deepEqual(decideWild(), first, "the same seed replays the same wild reply")
  local ok, err = session:submit(first)
  Assert.isTrue(ok, "wild replies submit through the shared protocol")
  Assert.isNil(err, "accepted wild replies carry no input error")
end

-- Scripted fighters replay only their listed actions in order: each owned
-- request consumes the next listed action, while missing script context or
-- an exhausted list fails instead of guessing.
function T.scripted_fighters_replay_only_their_listed_actions()
  local Opponents = requirePresent(
    OPPONENTS_MODULE,
    "wild and scripted policies answer through the shared reply shape"
  )
  Assert.isTrue(type(Opponents.scripted) == "function", "the scripted policy answers owned requests")
  local contracts = SessionFixture.sessionContracts()
  local session = SessionFixture.newSession(contracts, SessionFixture.buildScenario(duel()))
  local waiting = SessionFixture.driveUntilSettled(session, 64)
  local request = ownedRequest(waiting.request.requests, "ai")
  local actor = request.actors[1]
  local script = {
    actions = {
      { kind = "attack", payload = { moveSlot = 0, target = { kind = "position", position = 1 } } },
      { kind = "attack", payload = { moveSlot = 0, target = { kind = "position", position = 1 } } },
    },
    cursor = 1,
  }
  local stream = BattleRng.new(FIXED_SEED)
  local before = stream:capture()
  local first = Opponents.scripted(request, session:view("ai"), stream, { actor = actor, script = script })
  contracts.Protocol.validateReply(first, "action")
  Assert.equal(first.choices[1].kind, "attack", "the first listed action replays")
  Assert.deepEqual(stream:capture(), before, "scripted replays draw nothing")
  local second = Opponents.scripted(request, session:view("ai"), stream, { actor = actor, script = script })
  Assert.equal(script.cursor, 3, "each owned request consumes one listed action")
  Assert.deepEqual(second.choices[1].payload, first.choices[1].payload, "listed repeats stay identical")
  Assert.throws(function()
    Opponents.scripted(request, session:view("ai"), stream, { actor = actor, script = script })
  end, "an exhausted script list fails instead of guessing")
  Assert.throws(function()
    Opponents.scripted(request, session:view("ai"), stream, nil)
  end, "missing script context fails instead of guessing")
end

-- Rejected replies never consume the open request: a tampered epoch fails
-- with a typed input error, the batch identity holds, and the recorded
-- reply still answers afterwards with no extra evaluation.
function T.rejected_replies_never_consume_the_open_request()
  local controller = boundAi()
  local stream = BattleRng.new(FIXED_SEED)
  local session = SessionFixture.newSession(SessionFixture.sessionContracts(), SessionFixture.buildScenario(duel()))
  local waiting = SessionFixture.driveUntilSettled(session, 64)
  local request = ownedRequest(waiting.request.requests, "ai")
  local recorded = controller:decide(request, session:view("ai"), stream)
  local tampered = {
    requestId = recorded.requestId,
    epoch = recorded.epoch + 1,
    controller = recorded.controller,
    choices = recorded.choices,
  }
  local ok, err = session:submit(tampered)
  Assert.isFalse(ok, "a stale epoch never answers")
  Assert.isTrue(type(err) == "table" and err.code ~= nil, "rejection carries a typed input error")
  local pending = session:advance(1)
  Assert.equal(pending.status, "waiting", "the batch stays open after a rejection")
  Assert.equal(pending.request.epoch, waiting.request.epoch, "rejection never opens a new batch")
  local accepted, acceptErr = session:submit(recorded)
  Assert.isTrue(accepted, "the recorded reply still answers afterwards")
  Assert.isNil(acceptErr, "the recorded reply carries no input error")
end

return { tests = T }
