-- Party-menu field-move refusals: every non-executable check answer shows
-- its source message template and returns to the party menu; an executable
-- answer never completes the party child. Player-facing note: Chatter
-- eligibility matches FieldMove_CheckChatter, while field use stays
-- unavailable (chatter_recording_deferred) until a voice-recording
-- application owner exists.

local Assert = require("tests.support.Assert")
local PartyMenuFlow = require("game.hgss.src.field.PartyMenuFlow")

local T = { tests = {} }

local EXPECTED_TEMPLATES = {
  not_here = "fieldMoveNotHere",
  need_badge = "fieldMoveNeedBadge",
  have_follower = "fieldMoveHaveFollower",
  already_surfing = "fieldMoveAlreadySurfing",
  not_now = "fieldMoveNotNow",
}

local function flowAnswering(kind)
  local completed = {}
  local flow = setmetatable({
    _page = "party_browse",
    _child = {
      completeAction = function(_, outcome)
        completed[#completed + 1] = outcome
      end,
    },
    _mons = {
      partyRevision = function()
        return 1
      end,
    },
    _fieldMoves = {
      check = function()
        return { kind = kind }
      end,
    },
  }, PartyMenuFlow)
  return flow, completed
end

function T.tests.each_refusal_shows_its_source_message_template()
  for kind, templateKey in pairs(EXPECTED_TEMPLATES) do
    local flow, completed = flowAnswering(kind)
    flow:_routeFieldMove({ move = "CUT", slot = 0, moveSlot = 0 })
    Assert.equal(#completed, 1, kind)
    Assert.equal(completed[1].kind, kind)
    Assert.equal(completed[1].message.templateKey, templateKey, kind)
  end
end

return T
