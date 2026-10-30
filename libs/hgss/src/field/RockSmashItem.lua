-- Rock Smash item roll: the pure odds, hit, and drawn-index rule behind the
-- item a smashed rock may yield after its wild-encounter check misses.
-- Source basis: the retail ROM's Rock Smash item check. The caller supplies
-- the 0..99 draw source, so the roll owns no random state. Pure domain
-- module: no love dependency.

local RockSmashItem = {}

local ODDS_BONUS_ABILITIES = {
  SUCTION_CUPS = true,
  MAGNET_PULL = true,
  KEEN_EYE = true,
}

local LUCK_ABILITIES = {
  SERENE_GRACE = true,
  SUPER_LUCK = true,
}

local BONUS = 5
local MAX_ODDS = 100
local ITEM_COUNT = 8

-- Upper bounds (exclusive) of the item index ladder over a 0..99 draw.
local INDEX_LADDER = { 25, 45, 55, 65, 75, 85, 95 }

---@param draw integer
---@return integer zero-based item index
local function indexFor(draw)
  for index, bound in ipairs(INDEX_LADDER) do
    if draw < bound then
      return index - 1
    end
  end
  return ITEM_COUNT - 1
end

-- Roll the item for one smashed rock. Zero odds draw nothing; otherwise one
-- draw decides the hit and a second picks the item.
---@param args { odds: integer, items: string[], ability: string?, followerUsing: boolean, draw: fun(): integer }
---@return string|nil item key, nil when the roll missed
function RockSmashItem.roll(args)
  assert(type(args) == "table" and type(args.draw) == "function", "the item roll needs its draw source")
  assert(type(args.items) == "table" and #args.items == ITEM_COUNT, "the item roll needs its 8-item table")
  local odds = args.odds
  assert(type(odds) == "number" and odds % 1 == 0 and odds >= 0 and odds <= MAX_ODDS, "the item odds are 0..100")
  if odds == 0 then
    return nil
  end
  if args.ability ~= nil and ODDS_BONUS_ABILITIES[args.ability] then
    odds = odds + BONUS
  end
  if args.followerUsing then
    odds = odds + BONUS
  end
  if odds > MAX_ODDS then
    odds = MAX_ODDS
  end
  if args.draw() >= odds then
    return nil
  end
  local index = indexFor(args.draw())
  if args.ability ~= nil and LUCK_ABILITIES[args.ability] and index < ITEM_COUNT - 1 then
    index = index + 1
  end
  return args.items[index + 1]
end

return RockSmashItem
