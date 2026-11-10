-- Source catalog closure: every reachable ordinary and feedback program
-- resolves a semantic root, including the follower enter/recall pair,
-- while authentic End-only members stay classified instead of routing.
-- Probes use the real producer catalog, never a frozen count.

local Assert = require("tests.support.Assert")
local BattleAnimationSources = require("romdump.src.config.BattleAnimationSources")

local T = {}

local function rootsByKind()
  local moves = {}
  local animations = {}
  for _, root in ipairs(BattleAnimationSources.listSemanticRoots()) do
    if root.kind == "move" then
      moves[root.moveId] = root
    elseif root.kind == "battle-animation" then
      animations[root.animationCategory] = root
    end
  end
  return moves, animations
end

function T.follower_enter_and_recall_resolve_their_own_roots()
  local _, animations = rootsByKind()
  local enter = animations[41]
  Assert.notNil(enter, "the follower enter animation resolves its own catalog root")
  Assert.equal(enter.memberId, 41, "the enter root keeps its source member")
  local recall = animations[42]
  Assert.notNil(recall, "the follower recall animation resolves its own catalog root")
  Assert.equal(recall.memberId, 42, "the recall root keeps its source member")
end

function T.feedback_weather_and_state_roots_resolve_beside_moves()
  local moves, animations = rootsByKind()
  Assert.notNil(moves[1], "the first ordinary move resolves its semantic root")
  for _, category in ipairs({ 18, 19, 20, 21, 22, 25, 26 }) do
    local root = animations[category]
    Assert.notNil(root, "feedback animation " .. category .. " resolves its semantic root")
    Assert.equal(root.memberId, category, "feedback root " .. category .. " keeps its source member")
  end
end

function T.authentic_end_only_members_route_no_program()
  local _, animations = rootsByKind()
  Assert.isNil(animations[23], "the first end-only feedback member routes no program")
  Assert.isNil(animations[24], "the second end-only feedback member routes no program")
end

return { tests = T }
