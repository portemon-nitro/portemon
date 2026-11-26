-- Owns one script-opened Mom bank transfer: the source amount screen, the one
-- atomic wallet/savings move it accepts, and the return to the paused field
-- (src/scrcmd_c.c::ScrCmd_BankTransaction/NativeScript_WaitBankTransaction,
-- GetMaxBankTransactionAmount). The host captures both live balances and the
-- phone revision when the screen opens, so the accepted amount is the lesser
-- of the source funds and the destination capacity and a transfer can only
-- publish against the state it was quoted from. It never runs Mom's automatic
-- shopping: a manual transfer moves money and savings only.

local Errors = require("libs.errors.src.Errors")
local PlayerData = require("libs.hgss.src.save.PlayerData")
local ScriptErrors = require("libs.script.src.errors")

-- include/constants/player_data.h MAX_MONEY: both the wallet and Mom's savings
-- saturate here, so the capacity of the destination bounds one transfer.
local MAX_MONEY = PlayerData.MAX_MONEY

-- ScrCmd_BankTransaction's two modes.
local MODE_DEPOSIT = 0
local MODE_WITHDRAW = 1

---@class BankTransactionHost.Active
---@field handle table<string, unknown>
---@field owner string
---@field mode integer
---@field money integer the captured wallet
---@field savings integer the captured savings
---@field revision integer the captured phone revision
---@field max integer the source maximum for this mode
---@field screen table<string, unknown> the live amount screen
---@field interface table<string, unknown>? the loaded keypad presentation
---@field result { kind: string, amount: integer }?
---@field resultTaken boolean

---@class BankTransactionHost
---@field private _profile table<string, unknown>
---@field private _pokegearState table<string, unknown>
---@field private _createScreen fun(max: integer): table<string, unknown>
---@field private _createInterface fun(): table<string, unknown>
---@field private _savingsBox table<string, unknown>
---@field savingsBox table<string, unknown> the transient savings window the bank script opens
---@field private _clearUi fun()
---@field activeInterface table<string, unknown>?
---@field private _nextId integer
---@field private _active BankTransactionHost.Active?
---@field private _disposed boolean
local BankTransactionHost = {}
BankTransactionHost.__index = BankTransactionHost

---@param opts table<string, unknown>
---@return BankTransactionHost
function BankTransactionHost.new(opts)
  assert(type(opts) == "table", "bank host options are required")
  local profile = assert(opts.profile, "bank host requires the canonical profile")
  assert(type(profile.money) == "number", "bank host requires the live wallet")
  local state = assert(opts.pokegearState, "bank host requires the live phone state")
  assert(
    type(state.readPhone) == "function" and type(state.prepare) == "function",
    "bank host requires the phone state"
  )
  assert(type(state.revision) == "function", "bank host requires the phone revision")
  local createScreen = assert(opts.createScreen, "bank host requires the amount screen factory")
  assert(type(createScreen) == "function", "bank host amount screen factory must be callable")
  local self = setmetatable({
    _profile = profile,
    _pokegearState = state,
    _createScreen = createScreen,
    _savingsBox = assert(opts.savingsBox, "bank host requires the savings window"),
    _createInterface = assert(opts.createInterface, "bank host requires the keypad presentation factory"),
    _clearUi = assert(opts.clearUi, "bank host requires field UI edge release"),
    _nextId = 0,
    _active = nil,
    _disposed = false,
  }, BankTransactionHost)
  self.savingsBox = self._savingsBox
  return self
end

---@return integer
function BankTransactionHost:_liveMoney()
  local money = self._profile.money
  assert(type(money) == "number", "the canonical profile carries its money")
  return money --[[@as integer]]
end

---@return integer
function BankTransactionHost:_liveSavings()
  local phone = self._pokegearState:readPhone()
  local mom = type(phone) == "table" and phone.mom or nil
  local savings = type(mom) == "table" and mom.balance or nil
  assert(type(savings) == "number", "the phone state carries Mom's savings")
  return savings --[[@as integer]]
end

-- GetMaxBankTransactionAmount: a deposit is bounded by the wallet and the
-- savings capacity, a withdrawal by the savings and the wallet capacity.
---@param mode integer
---@param money integer
---@param savings integer
---@return integer
local function maxAmountFor(mode, money, savings)
  if mode == MODE_DEPOSIT then
    local capacity = MAX_MONEY - savings
    return math.min(money, capacity)
  end
  assert(mode == MODE_WITHDRAW, "the bank transfer mode is a deposit or a withdrawal")
  local capacity = MAX_MONEY - money
  return math.min(savings, capacity)
end

---@param handle table<string, unknown>
---@return BankTransactionHost.Active
function BankTransactionHost:_activeFor(handle)
  local active = assert(self._active, "no script bank transfer is open")
  assert(handle == active.handle, "bank handle is stale or belongs to another task")
  return active
end

-- One stale or failed transfer is attributed to the source command it came
-- from, so a script fault names the bank transfer instead of an anonymous
-- service failure.
---@param code string
---@param message string
---@param context table<string, unknown>
local function failTransfer(code, message, context)
  context.command = "793"
  context.originalName = "ScrCmd_BankTransaction"
  Errors.raise(code, message, context --[[@as Errors.Context]])
end

---@param active BankTransactionHost.Active
---@param amount integer
function BankTransactionHost:_publishTransfer(active, amount)
  local money = self:_liveMoney()
  if money ~= active.money then
    failTransfer(ScriptErrors.SCRIPT_BANK_TRANSFER_STALE, "the saved wallet moved while the amount screen was open", {
      mode = active.mode,
      wallet = money,
      expectedWallet = active.money,
    })
  end
  local savings = self:_liveSavings()
  if savings ~= active.savings then
    failTransfer(ScriptErrors.SCRIPT_BANK_TRANSFER_STALE, "Mom's savings moved while the amount screen was open", {
      mode = active.mode,
      savings = savings,
      expectedSavings = active.savings,
    })
  end
  local nextMoney
  local nextSavings
  if active.mode == MODE_DEPOSIT then
    nextMoney = money - amount
    nextSavings = savings + amount
  else
    nextMoney = money + amount
    nextSavings = savings - amount
  end
  assert(nextMoney >= 0 and nextMoney <= MAX_MONEY, "the transfer keeps the wallet in range")
  assert(nextSavings >= 0 and nextSavings <= MAX_MONEY, "the transfer keeps the savings in range")
  local current = self._pokegearState:readPhone()
  assert(type(current) == "table" and type(current.mom) == "table", "the phone state carries Mom's savings")
  ---@cast current -nil
  local mom = current.mom --[[@as { balance: integer, purchases: table<string, boolean>, gifts: table<string, unknown>[] }]]
  local prepared = self._pokegearState:prepare(active.revision, function(edit)
    edit:setMom({ balance = nextSavings, purchases = mom.purchases, gifts = mom.gifts })
  end)
  if not prepared.isCurrent then
    failTransfer(ScriptErrors.SCRIPT_BANK_TRANSFER_STALE, "the savings candidate is stale after the amount screen", {
      mode = active.mode,
      revision = active.revision,
    })
  end
  -- Both owners are written in one non-yielding step, after every fallible
  -- check: the prepared phone candidate publishes once and the canonical
  -- wallet takes its settled value.
  self._profile.money = nextMoney
  prepared.publish()
end

---@param ownerKey string
---@param descriptor { mode: integer }
---@return table<string, unknown> opaque task-owned handle
function BankTransactionHost:open(ownerKey, descriptor)
  assert(not self._disposed, "disposed bank host cannot open a screen")
  assert(type(ownerKey) == "string" and ownerKey ~= "", "bank owner identity is required")
  assert(type(descriptor) == "table", "bank launch descriptor is required")
  assert(descriptor.mode == MODE_DEPOSIT or descriptor.mode == MODE_WITHDRAW, "bank transfer mode is invalid")
  assert(self._active == nil, "a script bank transfer is already open")

  local money = self:_liveMoney()
  local savings = self:_liveSavings()
  local revision = self._pokegearState:revision()
  local max = maxAmountFor(descriptor.mode, money, savings)
  local screen
  local interface
  local ok, err = pcall(function()
    interface = self._createInterface()
    screen = self._createScreen(max)
    assert(type(screen) == "table", "the bank screen factory must return the amount screen")
    assert(type(screen.status) == "function", "the amount screen exposes its status")
    assert(type(screen.takeResult) == "function", "the amount screen exposes its terminal result")
    self._clearUi()
  end)
  if not ok then
    if screen ~= nil and type(screen.dispose) == "function" then
      screen:dispose()
    end
    error(err, 0)
  end

  self._nextId = self._nextId + 1
  local handle = { id = self._nextId, owner = ownerKey }
  self._active = {
    handle = handle,
    owner = ownerKey,
    mode = descriptor.mode,
    money = money,
    savings = savings,
    revision = revision,
    max = max,
    screen = assert(screen),
    interface = interface,
    result = nil,
    resultTaken = false,
  }
  return handle
end

-- The current saved savings balance (ScrCmd_CheckBankBalance and
-- ScrCmd_BankOrWalletIsFull read it directly).
---@return integer
function BankTransactionHost:savings()
  return self:_liveSavings()
end

-- The current saved wallet balance.
---@return integer
function BankTransactionHost:wallet()
  return self:_liveMoney()
end

-- ScrCmd_BankOrWalletIsFull: selector 0 asks whether Mom's savings are full,
-- every other selector asks whether the wallet is full.
---@param kind string "bank"|"wallet"
---@return boolean
function BankTransactionHost:isFull(kind)
  assert(kind == "bank" or kind == "wallet", "the bank fullness query names the bank or the wallet")
  local value = kind == "bank" and self:_liveSavings() or self:_liveMoney()
  return value >= MAX_MONEY
end

---@return boolean
function BankTransactionHost:isActive()
  return self._active ~= nil
end

---@return table<string, unknown>?
function BankTransactionHost:activeHandle()
  return self._active and self._active.handle or nil
end

-- The live amount screen's read-only status, or nil before a transfer opens.
-- The live transfer's presentation: the loaded keypad interface and the amount
-- screen's published status. Nil before a transfer opens, so the draw site
-- paints nothing.
---@return { interface: table<string, unknown>, status: table<string, unknown> }?
function BankTransactionHost:presentation()
  local active = self._active
  if active == nil or active.screen == nil or active.interface == nil then
    return nil
  end
  ---@cast active BankTransactionHost.Active
  return { interface = active.interface, status = active.screen:status() }
end

---@return table<string, unknown>?
function BankTransactionHost:status()
  local active = self._active
  if active == nil or active.screen == nil then
    return nil
  end
  ---@cast active BankTransactionHost.Active
  return active.screen:status()
end

---@param handle table<string, unknown>
---@param uiEvents table[]
function BankTransactionHost:step(handle, uiEvents)
  local active = self:_activeFor(handle)
  assert(type(uiEvents) == "table", "bank host consumes scheduler UI events")
  if active.result ~= nil then
    return
  end
  active.screen:step(uiEvents)
  local terminal = active.screen:takeResult()
  if terminal == nil then
    return
  end
  local amount = terminal.amount --[[@as integer]]
  if amount == 0 then
    -- A cancelled or zero entry moves nothing and reports the source cancel.
    active.result = { kind = "completed", amount = 0 }
  else
    self:_publishTransfer(active, amount)
    active.result = { kind = "completed", amount = amount }
  end
  active.screen:dispose()
  active.screen = nil
  if active.interface ~= nil and type(active.interface.dispose) == "function" then
    active.interface:dispose()
  end
  active.interface = nil
end

---@param handle table<string, unknown>
---@return { kind: string, amount: integer }?
function BankTransactionHost:result(handle)
  local active = self:_activeFor(handle)
  if active.result == nil or active.resultTaken then
    return nil
  end
  active.resultTaken = true
  return { kind = active.result.kind, amount = active.result.amount }
end

function BankTransactionHost:refreshPresentation()
  -- The amount screen is redrawn from its own status; nothing is leased here.
end

function BankTransactionHost:cancelPointerCapture()
  local active = self._active
  if active ~= nil and active.screen ~= nil then
    active.screen:cancelPointerCapture()
  end
end

---@param handle table<string, unknown>
function BankTransactionHost:close(handle)
  local active = self:_activeFor(handle)
  if active.screen ~= nil then
    active.screen:cancelPointerCapture()
    active.screen:dispose()
    active.screen = nil
  end
  if active.interface ~= nil and type(active.interface.dispose) == "function" then
    active.interface:dispose()
  end
  active.interface = nil
  self._clearUi()
  self._active = nil
end

function BankTransactionHost:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  local active = self._active
  if active ~= nil then
    self:close(active.handle)
  end
end

return BankTransactionHost
