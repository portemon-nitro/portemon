-- The script-owned Mom bank transfer: it captures both live balances and the
-- phone revision when the amount screen opens, bounds the accepted amount by
-- the source maximum for its mode, publishes the wallet/savings move exactly
-- once, refuses a transfer whose owners moved underneath it, and never runs
-- Mom's automatic shopping (src/scrcmd_c.c::ScrCmd_BankTransaction).

local Assert = require("tests.support.Assert")
local BankScreenState = require("game.hgss.src.bank.BankScreenState")
local BankTransactionHost = require("game.hgss.src.bank.BankTransactionHost")
local Errors = require("libs.errors.src.Errors")
local PokegearState = require("libs.hgss.src.save.PokegearState")
local ScriptErrors = require("libs.script.src.errors")

local T = {}

local DEPOSIT = 0
local WITHDRAW = 1

-- The phone owner needs the contact and location catalogs it validates
-- against; an empty closed catalog is the smallest legal owner.
local function phoneState(savings)
  local state = PokegearState.new({ seed = 1 }, {
    catalog = { contacts = {}, contactOrder = {}, callTriggers = {}, locations = {} },
  })
  state:setMom({ balance = savings, purchases = {}, gifts = {} })
  return state
end

local function host(profile, state)
  local screens = {}
  local hostRef = {}
  hostRef.savingsBox = { disposed = 0 }
  hostRef.bank = BankTransactionHost.new({
    profile = profile,
    pokegearState = state,
    savingsBox = hostRef.savingsBox,
    createInterface = function()
      return { dispose = function() end }
    end,
    createScreen = function(maxAmount)
      local screen = BankScreenState.new(maxAmount)
      screens[#screens + 1] = screen
      return screen
    end,
    clearUi = function() end,
  })
  hostRef.screens = screens
  return hostRef
end

---@param screen table
---@param role string
---@param digit integer?
local function tapRole(screen, role, digit)
  local target
  for _, key in ipairs(screen:status().keys) do
    if key.role == role and (digit == nil or key.digit == digit) then
      target = key
      break
    end
  end
  assert(target ~= nil, "the amount screen offers the " .. role .. " key")
  local x, y = target.x + target.width / 2, target.y + target.height / 2
  screen:step({ { type = "pointer_down", pointerId = "test", x = x, y = y } })
  screen:step({ { type = "pointer_up", pointerId = "test", x = x, y = y } })
end

---@param owner table
---@param handle table
---@param screen table
---@param digits integer[]
local function enter(owner, handle, screen, digits)
  for _, digit in ipairs(digits) do
    tapRole(screen, "digit", digit)
  end
  owner.bank:step(handle, {})
end

-- GetMaxBankTransactionAmount: a deposit is the lesser of the wallet and the
-- savings capacity, a withdrawal the lesser of the savings and the wallet
-- capacity.
function T.the_opening_maximum_is_the_lesser_of_the_source_funds_and_the_capacity()
  local profile = { money = 3000, coins = 0 }
  local state = phoneState(1000)
  local owner = host(profile, state)
  local deposit = owner.bank:open("owner:1", { mode = DEPOSIT })
  Assert.equal(owner.screens[1]:status().maxAmount, 3000, "a deposit is bounded by the wallet")
  owner.bank:close(deposit)

  local withdraw = owner.bank:open("owner:2", { mode = WITHDRAW })
  Assert.equal(owner.screens[2]:status().maxAmount, 1000, "a withdrawal is bounded by the savings")
  owner.bank:close(withdraw)

  profile.money = 999999
  local capped = owner.bank:open("owner:3", { mode = WITHDRAW })
  Assert.equal(owner.screens[3]:status().maxAmount, 0, "a full wallet leaves no withdrawal room")
  owner.bank:close(capped)
end

-- An accepted deposit moves the amount from the wallet into the savings once
-- and leaves the shopping queues alone.
function T.an_accepted_deposit_moves_both_owners_exactly_once()
  local profile = { money = 3000, coins = 0 }
  local state = phoneState(1000)
  local owner = host(profile, state)
  local handle = owner.bank:open("owner:1", { mode = DEPOSIT })
  enter(owner, handle, owner.screens[1], { 1, 2, 0, 0 })
  tapRole(owner.screens[1], "confirm")
  owner.bank:step(handle, {})
  Assert.equal(profile.money, 1800, "the wallet keeps what it did not transfer")
  local mom = state:readPhone().mom
  Assert.equal(mom.balance, 2200, "the savings receive the amount")
  Assert.deepEqual(mom.gifts, {}, "a manual deposit queues no Mom gift")
  Assert.deepEqual(mom.purchases, {}, "a manual deposit claims no Mom purchase")
  Assert.deepEqual(owner.bank:result(handle), { kind = "completed", amount = 1200 }, "the transfer completes once")
  Assert.isNil(owner.bank:result(handle), "the terminal result is consumed once")
  -- The finished transfer never replays on a later step or close.
  owner.bank:step(handle, {})
  owner.bank:close(handle)
  Assert.equal(profile.money, 1800, "a closed transfer leaves the wallet alone")
  Assert.equal(state:readPhone().mom.balance, 2200, "a closed transfer leaves the savings alone")
end

-- A withdrawal moves the amount back and saturates neither owner.
function T.an_accepted_withdrawal_returns_the_savings_into_the_wallet()
  local profile = { money = 3000, coins = 0 }
  local state = phoneState(1500)
  local owner = host(profile, state)
  local handle = owner.bank:open("owner:1", { mode = WITHDRAW })
  enter(owner, handle, owner.screens[1], { 1, 5, 0, 0 })
  tapRole(owner.screens[1], "confirm")
  owner.bank:step(handle, {})
  Assert.equal(profile.money, 4500, "the withdrawal reaches the wallet")
  Assert.equal(state:readPhone().mom.balance, 0, "the savings lose exactly the amount")
  owner.bank:close(handle)
end

-- A cancel and a confirmed zero entry move nothing and report the source
-- cancel.
function T.a_cancel_or_zero_entry_moves_nothing()
  local profile = { money = 3000, coins = 0 }
  local state = phoneState(1000)
  local owner = host(profile, state)
  local handle = owner.bank:open("owner:1", { mode = DEPOSIT })
  enter(owner, handle, owner.screens[1], { 7, 5, 0 })
  tapRole(owner.screens[1], "cancel")
  owner.bank:step(handle, {})
  Assert.deepEqual(owner.bank:result(handle), { kind = "completed", amount = 0 }, "a cancel completes with zero")
  Assert.equal(profile.money, 3000, "a cancel leaves the wallet alone")
  Assert.equal(state:readPhone().mom.balance, 1000, "a cancel leaves the savings alone")
  owner.bank:close(handle)

  local zeroed = owner.bank:open("owner:2", { mode = DEPOSIT })
  tapRole(owner.screens[2], "confirm")
  owner.bank:step(zeroed, {})
  Assert.deepEqual(owner.bank:result(zeroed), { kind = "completed", amount = 0 }, "a zero entry completes with zero")
  Assert.equal(profile.money, 3000, "a zero entry leaves the wallet alone")
  owner.bank:close(zeroed)
end

-- The transfer revalidates both owners against its capture: an outside move
-- aborts it without touching either balance, and the fault names the source
-- transfer.
function T.a_stale_owner_refuses_the_transfer_without_mutation()
  local profile = { money = 3000, coins = 0 }
  local state = phoneState(1000)
  local owner = host(profile, state)
  local handle = owner.bank:open("owner:1", { mode = DEPOSIT })
  for _, digit in ipairs({ 1, 2, 0, 0 }) do
    tapRole(owner.screens[1], "digit", digit)
  end
  -- A phone purchase spends part of the savings between open and confirm.
  state:setMom({ balance = 1600, purchases = {}, gifts = {} })
  tapRole(owner.screens[1], "confirm")
  local ok, err = pcall(function()
    owner.bank:step(handle, {})
  end)
  Assert.isFalse(ok, "a stale savings balance refuses the transfer")
  Assert.isTrue(Errors.is(err), "the refusal is attributed")
  ---@cast err Errors.Error
  Assert.equal(err.code, ScriptErrors.SCRIPT_BANK_TRANSFER_STALE, "the refusal names the stale transfer")
  Assert.equal((err.context or {}).command, "793", "the fault is attributed to the source bank transfer")
  Assert.equal(profile.money, 3000, "a refused transfer never charges the wallet")
  Assert.equal(state:readPhone().mom.balance, 1600, "a refused transfer never overwrites the savings")
  owner.bank:dispose()
end

-- A wallet that moved under the screen is refused the same way.
function T.a_stale_wallet_refuses_the_transfer()
  local profile = { money = 3000, coins = 0 }
  local state = phoneState(1000)
  local owner = host(profile, state)
  local handle = owner.bank:open("owner:1", { mode = DEPOSIT })
  tapRole(owner.screens[1], "digit", 1)
  profile.money = 500
  tapRole(owner.screens[1], "confirm")
  local ok, err = pcall(function()
    owner.bank:step(handle, {})
  end)
  Assert.isFalse(ok, "a stale wallet refuses the transfer")
  Assert.isTrue(Errors.is(err), "the refusal is attributed")
  ---@cast err Errors.Error
  Assert.equal(err.code, ScriptErrors.SCRIPT_BANK_TRANSFER_STALE, "the refusal names the stale transfer")
  Assert.equal(profile.money, 500, "a refused transfer leaves the outside wallet write alone")
  Assert.equal(state:readPhone().mom.balance, 1000, "a refused transfer leaves the savings alone")
  owner.bank:dispose()
end

-- ScrCmd_CheckBankBalance and ScrCmd_BankOrWalletIsFull read the live owners.
function T.the_balance_queries_read_the_live_owners()
  local profile = { money = 3000, coins = 0 }
  local state = phoneState(999999)
  local owner = host(profile, state)
  Assert.equal(owner.bank:savings(), 999999, "the savings query reads Mom's balance")
  Assert.equal(owner.bank:wallet(), 3000, "the wallet query reads the profile")
  Assert.isTrue(owner.bank:isFull("bank"), "a full savings account is full")
  Assert.isFalse(owner.bank:isFull("wallet"), "the wallet is not full")
  profile.money = 999999
  Assert.isTrue(owner.bank:isFull("wallet"), "a full wallet is full")
  owner.bank:dispose()
end

-- The host owns one live transfer: a second open is a programming fault, and a
-- stale handle never reaches another task's child.
function T.one_transfer_owns_the_host_at_a_time()
  local profile = { money = 3000, coins = 0 }
  local owner = host(profile, phoneState(0))
  local handle = owner.bank:open("owner:1", { mode = DEPOSIT })
  Assert.isTrue(owner.bank:isActive(), "the open transfer owns the host")
  Assert.isTrue(#owner.screens == 1, "the transfer opened one screen")
  local ok = pcall(function()
    owner.bank:open("owner:2", { mode = DEPOSIT })
  end)
  Assert.isFalse(ok, "a second transfer cannot open")
  local stale = { owner = "owner:2" }
  Assert.isFalse(
    pcall(function()
      owner.bank:step(stale, {})
    end),
    "another task's handle never steps the open transfer"
  )
  owner.bank:close(handle)
  Assert.isFalse(owner.bank:isActive(), "closing the transfer releases the host")
  owner.bank:dispose()
end

return { tests = T }
