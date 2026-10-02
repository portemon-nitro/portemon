-- Native battle consequence planning: prize money for defeated trainers,
-- blackout debit for lost battles, and shaped post-battle effects. Plans
-- are detached records; applying them stays with the owning state
-- (player money through the player owner, friendship through the mon
-- owner, trainer-defeat flags and story rewards through the owning
-- scripts, which receive their rewards back instead of seeing them
-- applied twice). Amounts never go negative and prize money respects the
-- player money ceiling. Pure domain module: no live state, no love
-- dependency.
--
-- Trainer prize money follows the native rule: the defeated trainer's
-- final ordered party member decides the prize level, the trainer
-- class contributes its pinned payout rate, and the amount is
-- level * 4 * class rate * money multiplier, doubled once for an
-- ordinary doubles battle. Paired battles sum both trainers without the
-- doubles doubling. Unknown classes, empty parties, and malformed reward
-- metadata fail planning before anything publishes.

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

---@param levels unknown
---@param index integer
---@return integer final ordered party level deciding the prize
local function checkPrizeLevels(levels, index)
  if type(levels) ~= "table" or #levels == 0 then
    error("prize planning requires trainer " .. index .. " to carry a non-empty party level array", 0)
  end
  for _, level in ipairs(levels) do
    if type(level) ~= "number" or level % 1 ~= 0 or level < 1 or level > 100 then
      error("prize planning needs trainer " .. index .. " party levels in 1..100", 0)
    end
  end
  return levels[#levels] --[[@as integer]]
end

---@param trainer unknown
---@param index integer
---@return table<string, unknown> detached per-trainer prize facts
local function checkTrainerReward(trainer, index)
  if type(trainer) ~= "table" then
    error("prize planning requires trainer " .. index .. " reward facts as a record", 0)
  end
  local entry = trainer --[[@as table<string, unknown>]]
  if type(entry.trainerClass) ~= "number" or entry.trainerClass % 1 ~= 0 or entry.trainerClass < 0 then
    error("prize planning requires trainer " .. index .. " to carry its numeric trainer class", 0)
  end
  if type(entry.classRate) ~= "number" or entry.classRate % 1 ~= 0 or entry.classRate < 0 then
    error("prize planning requires trainer " .. index .. " to carry its class payout rate", 0)
  end
  local level = checkPrizeLevels(entry.partyLevels, index)
  return {
    trainerClass = entry.trainerClass,
    level = level,
    classRate = entry.classRate,
  }
end

-- Plans trainer prize money from detached native trainer facts: one or two
-- trainers carrying their numeric class, ordered party levels, and pinned
-- class rate, plus the represented battle format and the battle-local
-- money multiplier (1, or 2 while a money-up holder has sent out).
-- Trainer-defeat flags and story rewards stay script-owned: anything the
-- caller declares under scriptRewards is echoed back for the owning
-- script to apply, never applied here.
---@param args { trainers: table<integer, table<string, unknown>>, battleFormat: string, moneyMultiplier: integer, scriptRewards: table<string, unknown>? }
---@return { kind: string, battleFormat: string, multiplier: integer, trainers: table<integer, table<string, unknown>>, amount: integer, scriptRewards: table<string, unknown> }
function HgssBattleRewards.planMoney(args)
  if type(args) ~= "table" then
    error("prize planning requires an argument record", 0)
  end
  if type(args.trainers) ~= "table" or #args.trainers == 0 or #args.trainers > 2 then
    error("prize planning settles one defeated trainer, or two in a paired battle", 0)
  end
  if args.battleFormat ~= "single" and args.battleFormat ~= "double" then
    error("prize planning settles a represented singles or doubles battle", 0)
  end
  if args.moneyMultiplier ~= 1 and args.moneyMultiplier ~= 2 then
    error("prize planning scales through a money multiplier of 1 or 2", 0)
  end
  local scriptRewards = args.scriptRewards or {}
  if type(scriptRewards) ~= "table" then
    error("prize planning script rewards must be a record when present", 0)
  end
  if #args.trainers == 2 and args.battleFormat ~= "double" then
    error("prize planning settles paired trainers only on a doubles field", 0)
  end
  local trainers = {} ---@type table<integer, table<string, unknown>>
  local amount = 0
  for index, trainer in ipairs(args.trainers) do
    local facts = checkTrainerReward(trainer, index)
    local level = facts.level --[[@as integer]]
    local classRate = facts.classRate --[[@as integer]]
    local share = level * 4 * classRate * args.moneyMultiplier --[[@as integer]]
    -- An ordinary doubles battle doubles one trainer's prize once; a
    -- paired battle instead sums both trainers without doubling.
    if #args.trainers == 1 and args.battleFormat == "double" then
      share = share * 2
    end
    facts.amount = share
    trainers[#trainers + 1] = facts
    amount = amount + share
  end
  return {
    kind = "money",
    battleFormat = args.battleFormat,
    multiplier = args.moneyMultiplier,
    trainers = trainers,
    amount = math.min(PlayerData.MAX_MONEY, amount),
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
