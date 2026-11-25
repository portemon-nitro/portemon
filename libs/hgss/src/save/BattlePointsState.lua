-- The persisted Battle Point wallet: one closed bucket carrying exactly its
-- schema and the source balance. The source keeps the balance in
-- `FrontierData.battlePoints` and applies every read/write through
-- FrontierData_BattlePointAction (src/frontier_data.c), whose SET and ADD
-- saturate at 9999 and whose SUB floors at 0. Those source gates belong to
-- the command that names the amount, so this owner only validates and stores
-- a settled balance: replacements stage as one-use revision-based candidates
-- exactly like the party, Bag, and dex owners, a stale or repeated
-- publication fails before touching state, and a malformed saved balance is
-- reported rather than clamped. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local GameSaveErrors = require("libs.hgss.src.save.GameSaveErrors")

---@class BattlePointsState
---@field private _balance integer
---@field private _revision integer
local BattlePointsState = {}
BattlePointsState.__index = BattlePointsState

BattlePointsState.SCHEMA = "hgss-battle-points-v1"
-- The source's own ceiling for the wallet (FrontierData_BattlePointAction).
BattlePointsState.MAX = 9999

local BUCKET_FIELDS = { schema = true, balance = true }

---@param message string
---@param context table<string, unknown>
local function fail(message, context)
  Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, message, context)
end

---@param value unknown
---@param what string
---@return integer
local function checkBalance(value, what)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > BattlePointsState.MAX then
    fail(
      "battle points " .. what .. " must be an integer in 0.." .. tostring(BattlePointsState.MAX),
      { field = what, value = value }
    )
  end
  return value --[[@as integer]]
end

---@return BattlePointsState
function BattlePointsState.new()
  return setmetatable({ _balance = 0, _revision = 0 }, BattlePointsState)
end

-- Restores the settled wallet from a saved bucket. A save without the bucket
-- holds no point, which is what every record written before the wallet
-- existed owed; a present bucket is validated whole.
---@param bucket unknown
---@return BattlePointsState
function BattlePointsState.restore(bucket)
  if bucket == nil then
    return BattlePointsState.new()
  end
  if type(bucket) ~= "table" then
    fail("battle points bucket must be a record", {})
  end
  assert(type(bucket) == "table", "battle-points validation reads the record")
  for key in pairs(bucket) do
    if BUCKET_FIELDS[key] ~= true then
      fail("battle points bucket has an unknown field", { field = key })
    end
  end
  if bucket.schema ~= BattlePointsState.SCHEMA then
    fail("battle points schema must be " .. BattlePointsState.SCHEMA, { schema = bucket.schema })
  end
  if bucket.balance == nil then
    fail("battle points bucket names its balance", {})
  end
  return setmetatable({ _balance = checkBalance(bucket.balance, "balance"), _revision = 0 }, BattlePointsState)
end

---@return integer
function BattlePointsState:balance()
  return self._balance
end

---@return integer
function BattlePointsState:revision()
  return self._revision
end

-- Stages one replacement balance without touching the settled one.
---@class BattlePointsPreparation
---@field changed boolean
---@field isCurrent fun(): boolean
---@field publish fun()

---@param balance integer
---@return BattlePointsPreparation
function BattlePointsState:prepare(balance)
  local nextBalance = checkBalance(balance, "balance")
  local changed = nextBalance ~= self._balance
  local capturedRevision = self._revision
  local consumed = false
  local function isCurrent()
    return (not consumed) and self._revision == capturedRevision
  end
  local function publish()
    if consumed then
      fail("battle points preparation already published", {})
    end
    if self._revision ~= capturedRevision then
      fail("battle points preparation is stale", {})
    end
    consumed = true
    self._balance = nextBalance
    if changed then
      self._revision = self._revision + 1
    end
  end
  return { changed = changed, isCurrent = isCurrent, publish = publish }
end

---@return table<string, unknown> detached canonical bucket
function BattlePointsState:capture()
  return { schema = BattlePointsState.SCHEMA, balance = self._balance }
end

return BattlePointsState
