local Assert = require("tests.support.Assert")
local ApricornTreeTask = require("libs.hgss.src.script.tasks.ApricornTreeTask")

local T = {}

function T.harvest_checks_daily_state_then_animates_and_depletes_before_success()
  local calls = {}
  local ctx = {
    services = {
      apricorn = {
        treeForActor = function(_, actorId)
          calls[#calls + 1] = { "tree", actorId }
          return { treeIndex = 6, apricornKey = "GRN_APRICORN" }
        end,
        treeAvailable = function(_, index)
          Assert.equal(index, 6)
          return true
        end,
        beginTreeAnimation = function(_, actorId, tree)
          calls[#calls + 1] = { "begin", actorId, tree.treeIndex }
        end,
        advanceTreeAnimation = function(_, actorId, phase, frame)
          calls[#calls + 1] = { "frame", actorId, phase, frame }
        end,
        depleteTree = function(_, index)
          calls[#calls + 1] = { "deplete", index }
          return true
        end,
        finishTreeAnimation = function(_, actorId)
          calls[#calls + 1] = { "finish", actorId }
        end,
      },
    },
  }

  local state = ApricornTreeTask.create({ actorId = "map:34:object:2" }, ctx)
  for _ = 1, 81 do
    local result = ApricornTreeTask.poll(state, ctx)
    state = result.state
    if result.complete then
      Assert.equal(result.result, 1)
      break
    end
  end

  Assert.equal(calls[1][1], "tree")
  Assert.equal(calls[2][1], "begin")
  local depleteIndex
  local wiggleFrames = 0
  local expelFrames = 0
  local jumpFrames = 0
  for index, call in ipairs(calls) do
    if call[1] == "frame" and call[3] == "wiggle" then
      wiggleFrames = wiggleFrames + 1
    elseif call[1] == "frame" and call[3] == "expel" then
      expelFrames = expelFrames + 1
    elseif call[1] == "frame" and call[3] == "jump" then
      jumpFrames = jumpFrames + 1
    elseif call[1] == "deplete" then
      Assert.isNil(depleteIndex, "one tree can be depleted only once")
      depleteIndex = index
    end
  end
  Assert.equal(wiggleFrames, 32)
  Assert.equal(calls[depleteIndex][2], 6)
  Assert.equal(expelFrames, 8)
  Assert.equal(jumpFrames, 16)
  Assert.isTrue(depleteIndex <= #calls - 25, "depletion precedes ejection and jump")
  Assert.equal(calls[#calls][1], "finish")
end

function T.already_depleted_tree_returns_empty_without_starting_animation()
  local calls = {}
  local ctx = {
    services = {
      apricorn = {
        treeForActor = function()
          return { treeIndex = 7, apricornKey = "PNK_APRICORN" }
        end,
        treeAvailable = function(_, index)
          Assert.equal(index, 7)
          return false
        end,
        beginTreeAnimation = function()
          calls[#calls + 1] = "begin"
        end,
        advanceTreeAnimation = function(_, _, phase)
          calls[#calls + 1] = phase
        end,
        depleteTree = function()
          calls[#calls + 1] = "deplete"
          return false
        end,
        finishTreeAnimation = function()
          calls[#calls + 1] = "finish"
        end,
      },
    },
  }
  local state = ApricornTreeTask.create({ actorId = "map:34:object:3" }, ctx)
  local result = ApricornTreeTask.poll(state, ctx)
  Assert.isTrue(result.complete)
  Assert.equal(result.result, 0)
  Assert.equal(#calls, 0, "an unavailable tree does not start an animation or consume state")
end

return { tests = T }
