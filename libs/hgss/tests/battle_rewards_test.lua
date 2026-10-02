-- Battle consequences: prize money, blackout loss, dex registration, and
-- roamer writeback are committed through their source owners with native
-- caps. Story rewards owned by scripts are returned for the script to
-- apply, never applied twice, and a failed commit never resumes success.

local Assert = require("tests.support.Assert")

local REWARDS_MODULE = "libs.hgss.src.battle.HgssBattleRewards"
local COMMITTER_MODULE = "libs.hgss.src.battle.HgssBattleCommitter"
local KNOWLEDGE_MODULE = "libs.hgss.src.mons.PokedexKnowledge"

---@param name string module path under test
---@param behavior string missing owner under test
---@return table the loaded consequence owner
local function requirePresent(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing battle consequence owner: " .. behavior .. " (" .. name .. ")")
  assert(loaded ~= nil, "the battle consequence module loads")
  return loaded --[[@as table]]
end

local T = {}

function T.trainer_win_plans_money_through_the_player_owner_only()
  local Rewards = requirePresent(REWARDS_MODULE, "native prize and loss planning")
  Assert.isTrue(type(Rewards.planMoney) == "function", "prize money plans through one entry point")
  Assert.isTrue(type(Rewards.planLoss) == "function", "blackout loss plans through one entry point")
  Assert.isTrue(type(Rewards.planPostBattle) == "function", "post-battle effects plan through one entry point")

  local plan = Rewards.planMoney({
    trainers = { { trainerClass = 2, partyLevels = { 5, 5 }, classRate = 4 } },
    battleFormat = "single",
    moneyMultiplier = 1,
  })
  Assert.equal(plan.amount, 80, "a planned prize follows level * 4 * class rate")
  Assert.isTrue(plan.amount <= 999999, "a planned prize respects the player money cap")

  local Knowledge = requirePresent(KNOWLEDGE_MODULE, "minimal seen and caught knowledge")
  Assert.isTrue(type(Knowledge.new) == "function", "dex knowledge constructs explicitly")
  local dex = Knowledge.new({ species = { CHIKORITA = true, EEVEE = true } })
  local staged = dex:capture("EEVEE")
  Assert.isTrue(staged ~= nil, "a capture stages caught knowledge")

  local Committer = requirePresent(COMMITTER_MODULE, "reward commit without duplicated story flags")
  local prepared = Committer.prepare({
    outcome = { id = "outcome-trainer-win", result = "win" },
    rewards = plan,
    scriptFlags = {},
  })
  local receipt = Committer.commit(prepared)
  Assert.isTrue(receipt.committed, "the trainer win commits")
  local repeatReceipt = Committer.commit(prepared)
  Assert.equal(repeatReceipt.outcomeId, receipt.outcomeId, "a repeated win reuses the recorded receipt")
end

function T.loss_resolves_blackout_without_resuming_a_failed_commit()
  local Rewards = requirePresent(REWARDS_MODULE, "native blackout planning")
  local loss = Rewards.planLoss({ money = 1200, partyLevels = { 9 } })
  Assert.isTrue(loss.amount >= 0, "a planned loss takes nothing below zero")

  local Committer = requirePresent(COMMITTER_MODULE, "failed commit without resumed success")
  local outcome = { id = "outcome-failed-loss", result = "loss" }
  local ok, err = pcall(Committer.prepare, { outcome = outcome, rewards = loss, stale = true })
  Assert.isFalse(ok, "an invalid loss batch never reaches publication: " .. tostring(err))
  Assert.isNil(Committer.receipt("outcome-failed-loss"), "a failed commit records no receipt")
end

function T.prize_uses_the_final_party_level_class_rate_and_multiplier()
  local Rewards = requirePresent(REWARDS_MODULE, "native prize and loss planning")
  local function single(trainerClass, partyLevels, classRate, moneyMultiplier)
    return Rewards.planMoney({
      trainers = { { trainerClass = trainerClass, partyLevels = partyLevels, classRate = classRate } },
      battleFormat = "single",
      moneyMultiplier = moneyMultiplier,
    })
  end
  -- The final party member decides the prize level even when it is not
  -- the strongest: class 2 pays rate 4, so level 9 awards 9 * 4 * 4.
  local final = single(2, { 12, 5, 9 }, 4, 1)
  Assert.equal(final.amount, 144, "the prize uses the final party level, not the strongest")
  Assert.equal(final.trainers[1].level, 9, "the plan records its deciding level")
  Assert.equal(final.trainers[1].classRate, 4, "the plan records its class rate")
  -- The money-up multiplier doubles the payout exactly once.
  local boosted = single(2, { 12, 5, 9 }, 4, 2)
  Assert.equal(boosted.amount, 288, "an active money-up effect doubles the prize once")
  -- A zero-rate class legitimately awards nothing, even when boosted.
  local zeroed = single(0, { 10 }, 0, 2)
  Assert.equal(zeroed.amount, 0, "a zero-rate class awards zero")
  -- An ordinary doubles battle doubles one trainer's prize once.
  local doubles = Rewards.planMoney({
    trainers = { { trainerClass = 2, partyLevels = { 12, 5, 9 }, classRate = 4 } },
    battleFormat = "double",
    moneyMultiplier = 1,
  })
  Assert.equal(doubles.amount, 288, "an ordinary doubles battle doubles one prize once")
  -- A paired battle sums both trainers without the doubles doubling:
  -- 6 * 4 * 4 plus 10 * 4 * 16.
  local pair = Rewards.planMoney({
    trainers = {
      { trainerClass = 2, partyLevels = { 6 }, classRate = 4 },
      { trainerClass = 23, partyLevels = { 4, 10 }, classRate = 16 },
    },
    battleFormat = "double",
    moneyMultiplier = 1,
  })
  Assert.equal(pair.amount, 736, "a paired battle sums both trainers without doubling")
  local boostedPair = Rewards.planMoney({
    trainers = {
      { trainerClass = 2, partyLevels = { 6 }, classRate = 4 },
      { trainerClass = 23, partyLevels = { 4, 10 }, classRate = 16 },
    },
    battleFormat = "double",
    moneyMultiplier = 2,
  })
  Assert.equal(boostedPair.amount, 1472, "money-up scales every paired prize once")
  Assert.isFalse(
    pcall(single, 2, {}, 4, 1),
    "an empty level array never plans"
  )
  Assert.isFalse(
    pcall(single, 2, { 5 }, nil, 1),
    "a missing class rate never plans"
  )
  Assert.isFalse(
    pcall(Rewards.planMoney, {
      trainers = { { trainerClass = "YOUNGSTER", partyLevels = { 5 }, classRate = 4 } },
      battleFormat = "single",
      moneyMultiplier = 1,
    }),
    "a display-name class never plans"
  )
  Assert.isFalse(
    pcall(Rewards.planMoney, {
      trainers = {
        { trainerClass = 2, partyLevels = { 6 }, classRate = 4 },
        { trainerClass = 23, partyLevels = { 10 }, classRate = 16 },
      },
      battleFormat = "single",
      moneyMultiplier = 1,
    }),
    "a paired battle on a singles field never plans"
  )
  Assert.isFalse(
    pcall(single, 2, { 5 }, 4, 3),
    "an unknown multiplier never plans"
  )
end

function T.blackout_debit_scales_with_badges_and_never_overdraws()
  local Rewards = requirePresent(REWARDS_MODULE, "native blackout planning")
  local plain = Rewards.planLoss({ money = 1200, partyLevels = { 9 } })
  Assert.equal(plain.amount, 72, "the debit scales the strongest level without badges")
  local badged = Rewards.planLoss({ money = 100000, partyLevels = { 9 }, badges = 2 })
  Assert.equal(badged.amount, 288, "each badge doubles the debit")
  local broke = Rewards.planLoss({ money = 50, partyLevels = { 60 }, badges = 8 })
  Assert.equal(broke.amount, 50, "the debit never takes more than the pocket holds")
  Assert.isFalse(
    pcall(Rewards.planLoss, { money = -5, partyLevels = { 9 } }),
    "a negative pocket never plans"
  )
end

function T.post_battle_effects_drop_defeat_gated_awards()
  local Rewards = requirePresent(REWARDS_MODULE, "native prize and loss planning")
  local won = Rewards.planPostBattle({
    victory = true,
    friendship = { { slot = 0, amount = 2 }, { slot = 1, amount = 3, victoryOnly = true } },
    pokerusSpread = true,
  })
  Assert.equal(#won.friendship, 2, "a win keeps every declared award")
  Assert.isTrue(won.pokerusSpread, "declared spread survives shaping")
  local lost = Rewards.planPostBattle({
    victory = false,
    friendship = { { slot = 0, amount = 2 }, { slot = 1, amount = 3, victoryOnly = true } },
  })
  Assert.equal(#lost.friendship, 1, "a loss drops victory-gated awards")
  Assert.isFalse(lost.pokerusSpread, "spread defaults to false")
  Assert.isFalse(
    pcall(Rewards.planPostBattle, { victory = true, friendship = { { slot = 6, amount = 1 } } }),
    "an out-of-party slot never plans"
  )
end

---@return table<string, unknown> a valid player record holding the given money
---@return table<string, unknown> its validation context
local function playerRecord(money)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  return {
    profile = { name = "RED", gender = 0, trainerId = 1, money = money, badges = 3, nationalDex = false },
    options = { textFrame = 0, textSpeed = "fastest" },
  }, { charmap = CatalogFixture.CHARMAP, frameIndexes = { [0] = true } }
end

function T.player_money_facts_cap_and_floor_through_the_committer()
  local PlayerData = require("libs.hgss.src.save.PlayerData")
  local record, context = playerRecord(999900)
  local prize = PlayerData.prepareBattleChanges(record, context, { moneyDelta = 50000 })
  Assert.equal(prize.profile.money, 999999, "prize overflow past the ceiling is lost")
  Assert.equal(prize.profile.badges, 3, "unrelated profile facts carry over")
  local poor, poorContext = playerRecord(100)
  local debit = PlayerData.prepareBattleChanges(poor, poorContext, { moneyDelta = -500 })
  Assert.equal(debit.profile.money, 0, "blackout debit never drops below zero")
  Assert.isFalse(
    pcall(PlayerData.prepareBattleChanges, record, context, { moneyDelta = 1.5 }),
    "a fractional delta never stages"
  )

  local Committer = requirePresent(COMMITTER_MODULE, "reward commit without duplicated story flags")
  local Rewards = requirePresent(REWARDS_MODULE, "native prize and loss planning")
  local plan = Rewards.planMoney({
    trainers = { { trainerClass = 2, partyLevels = { 5, 5 }, classRate = 4 } },
    battleFormat = "single",
    moneyMultiplier = 1,
  })
  local base, baseContext = playerRecord(1000)
  local prepared = Committer.prepare({
    outcome = { id = "outcome-money-through-commit", result = "win" },
    rewards = plan,
    scriptFlags = { gym1 = true },
    player = { record = base, context = baseContext, moneyDelta = plan.amount },
  })
  local receipt = Committer.commit(prepared)
  Assert.isTrue(receipt.committed, "the money batch commits")
  Assert.equal(receipt.player.profile.money, 1080, "the receipt carries the validated money candidate")
  Assert.isTrue(receipt.scriptFlags.gym1, "script-owned flags echo back unapplied")
  Assert.equal(base.profile.money, 1000, "staging never touches the input record")
end

function T.dex_knowledge_round_trips_through_its_save_bucket()
  local Knowledge = requirePresent(KNOWLEDGE_MODULE, "minimal seen and caught knowledge")
  local refs = { species = { CHIKORITA = true, EEVEE = true } }
  local dex = Knowledge.new({ species = refs.species })
  Assert.isFalse(dex:isCaught("EEVEE"), "new knowledge starts uncaught")
  local staged = dex:capture("EEVEE")
  Assert.isFalse(dex:isCaught("EEVEE"), "staging leaves live knowledge alone")
  staged.publish()
  Assert.isTrue(dex:isCaught("EEVEE"), "publishing registers the capture")
  local bucket = dex:bucket()
  local PokedexSave = require("libs.hgss.src.save.PokedexSave")
  local valid = PokedexSave.validate(bucket, refs)
  Assert.deepEqual(valid.caught, { "EEVEE" }, "the bucket persists the caught flag")
  local revived = Knowledge.restore(valid, refs)
  Assert.isTrue(revived:isCaught("EEVEE"), "restore keeps caught knowledge")
  Assert.isFalse(revived:isCaught("CHIKORITA"), "restore infers no historic catches")
  Assert.isFalse(pcall(PokedexSave.validate, bucket, { species = {} }), "unknown keys never validate")
  local initial = PokedexSave.initial()
  Assert.deepEqual(initial.caught, {}, "initial knowledge starts empty")
  Assert.isFalse(pcall(dex.capture, dex, "MISSINGNO"), "unknown species never stage")
end

return { tests = T }
