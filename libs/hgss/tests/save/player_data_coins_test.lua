-- Game Corner coins on the canonical player profile. The source keeps the
-- coin balance beside the money, caps it at 50000 and adds through a u16
-- accumulator: a grant writes `(old + amount) % 65536` and then caps, while an
-- affordability query compares the unwrapped sum. The profile validation is
-- strict about the present field, and no debit ever touches anything but the
-- coin balance.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local PlayerData = require("libs.hgss.src.save.PlayerData")

local T = {}

local CHARMAP = {
  G = 305,
  O = 313,
  L = 310,
  D = 302,
  H = 306,
  I = 307,
  K = 309,
  A = 299,
  R = 316,
}
local FRAME_INDEXES = { [0] = true, [1] = true, [2] = true }

local function context()
  return { charmap = CHARMAP, frameIndexes = FRAME_INDEXES }
end

local function record(coins)
  return {
    profile = {
      name = "GOLD",
      rivalName = "HIKARI",
      gender = 0,
      trainerId = 1,
      money = 3000,
      coins = coins,
      badges = {},
      nationalDex = false,
      runningShoes = false,
      runningShoesLock = false,
      unionAvatar = 0,
    },
    options = {
      textFrame = 0,
      textSpeed = "mid",
      battleStyle = "shift",
      battleScene = true,
      soundMode = "stereo",
      battleSpeed = 1,
    },
  }
end

-- A rejected coin field is an attributed player-data failure, never a clamp
-- into a plausible balance.
local function rejectsCoins(coins)
  local validated, err = PlayerData.validate(record(coins), context())
  Assert.isNil(validated, "an invalid coin balance never validates")
  Assert.isTrue(Errors.is(err), "the coin failure is attributed: " .. tostring(err))
  Assert.isTrue(
    tostring((err --[[@as Errors.Error]]).code):find("PLAYER_DATA", 1, true) ~= nil,
    "the coin failure belongs to the player-data family, got " .. tostring((err --[[@as Errors.Error]]).code)
  )
end

---@param coins integer
---@return table a profile carrying the balance
local function profile(coins)
  return { money = 3000, coins = coins }
end

-- The source ceiling and the strict saved field.
function T.coins_are_a_present_integer_field_capped_at_the_source_maximum()
  Assert.equal(PlayerData.MAX_COINS, 50000, "the coin cap is the source 50000")
  Assert.equal(PlayerData.validate(record(0), context()).profile.coins, 0, "an empty balance validates")
  Assert.equal(
    PlayerData.validate(record(50000), context()).profile.coins,
    50000,
    "the source cap validates"
  )
  for _, value in ipairs({ -1, 50001, 12.5, "500", true }) do
    rejectsCoins(value)
  end
  rejectsCoins(nil)
end

-- A grant writes the u16 sum and then caps it.
function T.coin_grants_wrap_through_the_source_u16_accumulator_and_then_cap()
  local state = profile(0)
  Assert.isTrue(PlayerData.giveCoins(state, 500), "a grant inside the cap is accepted")
  Assert.equal(state.coins, 500, "the grant reaches the balance")

  state = profile(40000)
  Assert.isTrue(PlayerData.giveCoins(state, 20000), "a grant past the cap is accepted by the source")
  Assert.equal(state.coins, 50000, "the wrapped sum still caps at the source maximum")

  state = profile(40000)
  Assert.isTrue(PlayerData.giveCoins(state, 40000), "a grant that wraps the accumulator is accepted")
  Assert.equal(state.coins, 14464, "the wrapped sum is what the source actually stores")

  state = profile(50000)
  Assert.isFalse(PlayerData.giveCoins(state, 1), "a full wallet refuses another grant")
  Assert.equal(state.coins, 50000, "a refused grant leaves the balance alone")

  state = profile(100)
  Assert.isFalse(PlayerData.giveCoins(state, 65536), "a grant above the source operand range is refused")
  Assert.equal(state.coins, 100, "an out-of-range grant leaves the balance alone")
end

-- The affordability query compares the unwrapped sum, so a wrap never looks
-- affordable.
function T.can_give_coins_compares_the_unwrapped_sum()
  Assert.isTrue(PlayerData.canGiveCoins(profile(30000), 20000), "an exact fit is affordable")
  Assert.isTrue(PlayerData.canGiveCoins(profile(0), 50000), "the whole cap is affordable from empty")
  Assert.isFalse(
    PlayerData.canGiveCoins(profile(40000), 40000),
    "a sum past the cap is refused before the wrap"
  )
  Assert.isFalse(PlayerData.canGiveCoins(profile(40000), 20000), "a sum past the cap is refused")
  Assert.isFalse(PlayerData.canGiveCoins(profile(50000), 1), "a full wallet refuses another grant")
end

-- A charge never goes negative, never wraps, and never touches another field.
function T.coin_charges_refuse_insufficient_balances_without_mutation()
  local state = profile(1000)
  local before = { money = state.money, coins = state.coins }
  Assert.isFalse(PlayerData.takeCoins(state, 1001), "a charge above the balance is refused")
  Assert.deepEqual(
    { money = state.money, coins = state.coins },
    before,
    "a refused charge changes neither the coins nor the money"
  )

  Assert.isTrue(PlayerData.takeCoins(state, 1000), "an exact charge is accepted")
  Assert.equal(state.coins, 0, "the charge empties the balance")
  Assert.equal(state.money, 3000, "a coin debit never spends money")
  Assert.equal(PlayerData.coinBalance(state), 0, "the read answers the canonical balance")
end

return { tests = T }
