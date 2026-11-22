-- Drives one battle that the production field launched, without assembling
-- battle or field internals: the caller answers the open semantic requests and
-- this helper only submits them through the running battle and steps the real
-- field runtime. The render trap stays active for the whole drive.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local FieldBattleDriver = {}

-- The opposing side's single active slot, as the decision protocol addresses
-- it. A wild battle fields exactly one opponent entry.
FieldBattleDriver.FOE_POSITION = 2

---@param game table acceptance game owning the production field runtime
---@return table? active battle application lifetime
local function activeBattle(game)
  local coordinator = game.runtime.battleCoordinator
  if coordinator == nil then
    return nil
  end
  return coordinator:activeBattle()
end

-- Waits on the semantic boundary the field publishes when it hands a scripted
-- or encountered source to the battle application.
---@param game table acceptance game owning the production field runtime
---@param label string boundary description used in the timeout diagnostic
---@param maxTicks integer positive tick budget
---@return table the active battle application lifetime
function FieldBattleDriver.waitForLaunch(game, label, maxTicks)
  game:advanceUntil(label, function()
    return activeBattle(game) ~= nil
  end, maxTicks)
  return assert(activeBattle(game), label)
end

-- Answers every open player request with the caller's semantic decision and
-- steps the field until the battle application releases the field. `choose`
-- returns one reply choice, or one choice per addressed actor.
---@param game table acceptance game owning the production field runtime
---@param choose fun(request: table<string, unknown>, turn: integer): table|table[]
---@param maxTicks integer? tick budget, defaults to 2400
---@return { turns: integer, ticks: integer }
function FieldBattleDriver.drive(game, choose, maxTicks)
  local limit = maxTicks or 2400
  local turns, ticks = 0, 0
  local answeredRequestId = nil
  while ticks < limit do
    local battle = activeBattle(game)
    if battle == nil then
      return { turns = turns, ticks = ticks }
    end
    local status = battle:status()
    if status.phase == "failed" then
      error("the field battle application failed: " .. tostring(status.error), 0)
    end
    if status.phase == "running" and status.request ~= nil and status.request.requestId ~= answeredRequestId then
      answeredRequestId = status.request.requestId
      turns = turns + 1
      local answer = choose(status.request, turns)
      local choices = type(answer) == "table" and answer.actor ~= nil and { answer } or answer
      Assert.isTrue(type(choices) == "table", "the decision driver answers with a choice or a choice array")
      local actors = assert(status.request.actors, "player decisions address their combatants")
      Assert.equal(#choices, #actors, "every addressed actor answers exactly once")
      local accepted, replyErr = battle:submit(SessionFixture.replyFor(status.request, choices))
      Assert.isTrue(accepted, "a legal battle decision is accepted: " .. tostring(replyErr))
    end
    game:step()
    ticks = ticks + 1
  end
  error("the field battle application did not release the field within " .. tostring(limit) .. " ticks", 0)
end

-- Answers one open request by striking with the lead's first move slot at the
-- single opposing entry.
---@param request table<string, unknown> open player request
---@return table[] replies for every addressed actor
function FieldBattleDriver.strike(request)
  local choices = {}
  for _, actor in ipairs(assert(request.actors, "a decision request names its actors")) do
    choices[#choices + 1] =
      SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(FieldBattleDriver.FOE_POSITION))
  end
  return choices
end

-- Answers a learned-move prompt by declining it, so a battle that awards
-- experience never depends on a move-learning flow.
---@param request table<string, unknown> open player request
---@return table[] replies for every addressed actor
function FieldBattleDriver.decline(request)
  local choices = {}
  for _, actor in ipairs(assert(request.actors, "a decision request names its actors")) do
    choices[#choices + 1] = { actor = actor, kind = "confirm", payload = { decision = "decline" } }
  end
  return choices
end

return FieldBattleDriver
