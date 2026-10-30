-- Rock Smash item roll: source order of the odds adjustment (ability and
-- follower bonuses, capped at 100), the hit roll, the drawn item index, and
-- the Serene Grace / Super Luck index shift.
-- Source basis: the retail ROM's Rock Smash item check.

local Assert = require("tests.support.Assert")
local RockSmashItem = require("libs.hgss.src.field.RockSmashItem")

local T = {}

local ITEMS = { "A", "B", "C", "D", "E", "F", "G", "H" }

local function scripted(...)
  local values = { ... }
  local drawn = 0
  return function()
    drawn = drawn + 1
    return assert(values[drawn], "unexpected extra draw")
  end,
    function()
      return drawn
    end
end

local function roll(opts, ...)
  local draw, count = scripted(...)
  local found = RockSmashItem.roll({
    odds = opts.odds,
    items = ITEMS,
    ability = opts.ability,
    followerUsing = opts.followerUsing == true,
    draw = draw,
  })
  return found, count()
end

function T.zero_odds_draws_nothing()
  local found, drawn = roll({ odds = 0 })
  Assert.isNil(found)
  Assert.equal(drawn, 0)
end

function T.hit_roll_below_the_odds_then_the_index_ladder_picks_the_item()
  local expected = { [0] = "A", [24] = "A", [25] = "B", [44] = "B", [45] = "C", [54] = "C", [55] = "D", [74] = "E", [84] = "F", [94] = "G", [95] = "H", [99] = "H" }
  for index, item in pairs(expected) do
    local found, drawn = roll({ odds = 50 }, 49, index)
    Assert.equal(found, item, "index roll " .. index)
    Assert.equal(drawn, 2)
  end
  local missed, drawn = roll({ odds = 50 }, 50)
  Assert.isNil(missed)
  Assert.equal(drawn, 1)
end

function T.ability_and_follower_bonuses_add_five_each_and_cap_at_one_hundred()
  Assert.isNil(roll({ odds = 40 }, 40))
  Assert.equal(roll({ odds = 40, ability = "KEEN_EYE" }, 44, 0), "A")
  Assert.isNil(roll({ odds = 40, ability = "KEEN_EYE" }, 45))
  Assert.equal(roll({ odds = 40, ability = "MAGNET_PULL" }, 44, 0), "A")
  Assert.equal(roll({ odds = 40, ability = "SUCTION_CUPS" }, 44, 0), "A")
  Assert.equal(roll({ odds = 40, ability = "KEEN_EYE", followerUsing = true }, 49, 0), "A")
  Assert.isNil(roll({ odds = 40, ability = "STATIC" }, 40))
  Assert.equal(roll({ odds = 98, followerUsing = true, ability = "KEEN_EYE" }, 99, 0), "A")
end

function T.serene_grace_and_super_luck_shift_the_index_up_below_seven()
  Assert.equal(roll({ odds = 100, ability = "SERENE_GRACE" }, 0, 0), "B")
  Assert.equal(roll({ odds = 100, ability = "SUPER_LUCK" }, 0, 60), "E")
  Assert.equal(roll({ odds = 100, ability = "SERENE_GRACE" }, 0, 95), "H")
  Assert.equal(roll({ odds = 100, ability = "SERENE_GRACE" }, 0, 94), "H")
end

return { tests = T }
