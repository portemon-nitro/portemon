-- Shared fixed mon domain enum membership. The strict generated-asset
-- validator and the composed resolved validator check the same native
-- growth curves, move categories, and native evolution methods; each
-- validator keeps its own admission policy around these sets. The tables
-- are immutable by convention: importers must only read them.
-- Love-free and filesystem-free.

---@class MonSharedEnums
local MonSharedEnums = {}

---@type table<string, boolean>
MonSharedEnums.growthCurves = {
  medium_fast = true,
  erratic = true,
  fluctuating = true,
  medium_slow = true,
  fast = true,
  slow = true,
  unused_6 = true,
  unused_7 = true,
}

---@type table<string, boolean>
MonSharedEnums.moveCategories = { physical = true, special = true, status = true }

---@type table<string, boolean>
MonSharedEnums.nativeEvolutionMethods = {
  friendship = true,
  friendship_day = true,
  friendship_night = true,
  level = true,
  trade = true,
  trade_item = true,
  stone = true,
  level_atk_gt_def = true,
  level_atk_eq_def = true,
  level_atk_lt_def = true,
  level_pid_lo = true,
  level_pid_hi = true,
  level_ninjask = true,
  level_shedinja = true,
  beauty = true,
  stone_male = true,
  stone_female = true,
  item_day = true,
  item_night = true,
  has_move = true,
  other_party_mon = true,
  level_male = true,
  level_female = true,
  coronet = true,
  eterna = true,
  route217 = true,
}

return MonSharedEnums
