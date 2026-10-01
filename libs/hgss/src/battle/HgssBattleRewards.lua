-- Native battle consequence planning: prize money for defeated trainers,
-- blackout debit for lost battles, and shaped post-battle effects. Plans
-- are detached records; applying them stays with the owning state
-- (player money through the player owner, friendship through the mon
-- owner, trainer-defeat flags and story rewards through the owning
-- scripts, which receive their rewards back instead of seeing them
-- applied twice). Amounts never go negative and prize money respects the
-- player money ceiling. Pure domain module: no live state, no love
-- dependency.

local PlayerData = require("libs.hgss.src.save.PlayerData")

---@class HgssBattleRewards
local HgssBattleRewards = {}

-- Base blackout debit per opposing level before the badge scaling applies.
HgssBattleRewards.BLACKOUT_PER_LEVEL = 8

---@param levels unknown
---@return integer
local function checkLevels(levels)
  if type(levels) ~= "table" or #levels == 0 then
    error("battle reward planning requires a non-empty party level array", 0)
  end
  local strongest = 0
  for _, level in ipairs(levels) do
    if type(level) ~= "number" or level % 1 ~= 0 or level < 1 or level > 100 then
      error("battle reward planning needs party levels in 1..100", 0)
    end
    if level > strongest then
      strongest = level --[[@as integer]]
    end
  end
  return strongest
end

-- Plans trainer prize money: the supplied base payout scaled by the
-- strongest opposing party level, capped at the player money ceiling.
-- Trainer-defeat flags and story rewards stay script-owned: anything the
-- caller declares under scriptRewards is echoed back for the owning
-- script to apply, never applied here.
---@param args { trainerClass: string, partyLevels: integer[], basePayout: integer, scriptRewards: table<string, unknown>? }
---@return { kind: string, trainerClass: string, level: integer, basePayout: integer, amount: integer, scriptRewards: table<string, unknown> }
function HgssBattleRewards.planMoney(args)
  if type(args) ~= "table" then
    error("prize planning requires an argument record", 0)
  end
  if type(args.trainerClass) ~= "string" or args.trainerClass == "" then
    error("prize planning requires a trainer class", 0)
  end
  if type(args.basePayout) ~= "number" or args.basePayout % 1 ~= 0 or args.basePayout < 0 then
    error("prize planning requires a non-negative integer base payout", 0)
  end
  local strongest = checkLevels(args.partyLevels)
  local scriptRewards = args.scriptRewards or {}
  if type(scriptRewards) ~= "table" then
    error("prize planning script rewards must be a record when present", 0)
  end
  return {
    kind = "money",
    trainerClass = args.trainerClass,
    level = strongest,
    basePayout = args.basePayout,
    amount = math.min(PlayerData.MAX_MONEY, args.basePayout * strongest),
    scriptRewards = scriptRewards,
  }
end

-- Plans the blackout debit for a lost battle: the strongest own party
-- level scaled by earned badges, capped at the money on hand so the
-- debit never takes the pocket below zero.
---@param args { money: integer, partyLevels: integer[], badges: integer? }
---@return { kind: string, level: integer, badges: integer, amount: integer }
function HgssBattleRewards.planLoss(args)
  if type(args) ~= "table" then
    error("blackout planning requires an argument record", 0)
  end
  if type(args.money) ~= "number" or args.money % 1 ~= 0 or args.money < 0 then
    error("blackout planning requires non-negative integer money on hand", 0)
  end
  local badges = args.badges or 0
  if type(badges) ~= "number" or badges % 1 ~= 0 or badges < 0 or badges > 16 then
    error("blackout planning requires a badge count in 0..16", 0)
  end
  local strongest = checkLevels(args.partyLevels)
  local debit = strongest * HgssBattleRewards.BLACKOUT_PER_LEVEL * (2 ^ badges)
  return {
    kind = "loss",
    level = strongest,
    badges = badges,
    amount = math.min(args.money, debit),
  }
end

-- Shapes caller-declared post-battle effects (friendship awards the mon
-- owner applies, Pokerus spread state, held-item settlements) without
-- inventing rates: every effect carries its explicit slot and amount, and
-- victory-gated effects are dropped on defeat so a failed battle applies
-- nothing. The plan is detached; application stays with the owners.
---@param args { victory: boolean, friendship: { slot: integer, amount: integer, victoryOnly: boolean? }[]?, pokerusSpread: boolean? }
---@return { victory: boolean, friendship: { slot: integer, amount: integer }[], pokerusSpread: boolean }
function HgssBattleRewards.planPostBattle(args)
  if type(args) ~= "table" then
    error("post-battle planning requires an argument record", 0)
  end
  if type(args.victory) ~= "boolean" then
    error("post-battle planning requires a victory flag", 0)
  end
  local declared = args.friendship or {}
  if type(declared) ~= "table" then
    error("post-battle friendship effects must be an array when present", 0)
  end
  local friendship = {}
  for _, award in ipairs(declared) do
    if type(award) ~= "table" then
      error("post-battle friendship awards must be records", 0)
    end
    if type(award.slot) ~= "number" or award.slot % 1 ~= 0 or award.slot < 0 or award.slot > 5 then
      error("post-battle friendship awards name a party slot in 0..5", 0)
    end
    if type(award.amount) ~= "number" or award.amount % 1 ~= 0 or award.amount < 0 or award.amount > 255 then
      error("post-battle friendship awards carry an amount in 0..255", 0)
    end
    if award.victoryOnly ~= true or args.victory then
      friendship[#friendship + 1] = { slot = award.slot, amount = award.amount }
    end
  end
  local spread = args.pokerusSpread
  if spread == nil then
    spread = false
  end
  if type(spread) ~= "boolean" then
    error("post-battle pokerus spread must be a boolean when present", 0)
  end
  return { victory = args.victory, friendship = friendship, pokerusSpread = spread }
end

return HgssBattleRewards
