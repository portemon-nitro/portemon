-- Source Mom savings arithmetic and revisioned gift candidates: the
-- battle-winnings split from the actual capped money increase, the
-- ordered normal purchases with their exact costs, the resistance-berry
-- fallback on a fresh savings tier, and pending-gift collection through
-- the live Bag preparation boundary. Candidates stage every affected
-- companion field before publishing; publication validates currency,
-- writes once, advances the revision once, and never draws on a failed
-- path. Random draws happen at publication after the currency check, so
-- a stale candidate consumes nothing and a retry replays the same draw.
-- Pure policy: no love dependency. Bag grants use the live Bag owner's
-- preparation when one is supplied, otherwise an explicit synthetic free
-- slot count; the player pocket itself is settled by the battle owner
-- through its own player preparation, never here.

local Errors = require("libs.errors.src.Errors")

---@class PhoneRewards
local PhoneRewards = {}

PhoneRewards.MOM_MAX = 999999
PhoneRewards.PLAYER_MAX = 999999
PhoneRewards.SAVINGS_DIVISOR = 4
PhoneRewards.GIFT_FIFO_MAX = 5
PhoneRewards.BERRY_TIER = 3000
PhoneRewards.BERRY_QUANTITY = 5
PhoneRewards.BERRY_COST = 100
PhoneRewards.BERRY_CHOICES = 17
PhoneRewards.BERRY_DRAW_LABEL = "mom-berry"
PhoneRewards.MOM_GIFT_TRIGGER = "gear.trigger.12"

local LEGACY_PURCHASE_FLAGS = {
  [0] = "custom.super-potion-900",
  [1] = "custom.repel-4000",
  [2] = "custom.super-potion-7000",
  [3] = "custom.silk-scarf-10000",
  [4] = "custom.moon-stone-15000",
  [5] = "custom.hyper-potion-19000",
  [6] = "custom.choice-scarf-30000",
  [7] = "custom.muscle-band-40000",
  [8] = "custom.focus-sash-50000",
}

PhoneRewards.STALE_CODE = "POKEGEAR_STALE_CANDIDATE"

-- Battles whose winnings never reach savings: no transfer on nonpositive
-- gain and none in these excluded source contexts.
PhoneRewards.EXCLUDED_BATTLE_KINDS = { link = true }

-- Resolve only source-provided native items into runtime semantic keys.
---@param itemCatalog table<string, unknown>
---@param nativeItemId integer
---@return string the validated semantic item key
local function resolveItem(itemCatalog, nativeItemId)
  assert(type(itemCatalog) == "table", "native Mom gifts resolve through the generated item catalog")
  local byNative = itemCatalog.itemKeyByNativeId --[[@as fun(self: table<string, unknown>, nativeId: integer): string]]
  assert(type(byNative) == "function", "native Mom gifts use item identity lookup")
  return byNative(itemCatalog, nativeItemId)
end

---@param value unknown
---@param what string
local function checkMoney(value, what)
  assert(
    type(value) == "number" and value % 1 == 0 and value >= 0,
    "savings " .. what .. " stays a non-negative integer"
  )
end

---@param state unknown
---@return table<string, unknown> the live companion state owner
local function checkState(state)
  assert(type(state) == "table", "savings candidates publish through the companion state owner")
  local owner = state --[[@as table<string, unknown>]]
  assert(type(owner.revision) == "function", "savings candidates read the live revision")
  assert(type(owner.readPhone) == "function", "savings candidates read the live companion records")
  assert(type(owner.prepare) == "function", "savings candidates publish through the companion staged-candidate owner")
  return owner
end

---@param revision unknown
local function checkRevision(revision)
  assert(
    type(revision) == "number" and revision % 1 == 0 and revision >= 0,
    "savings candidates expect the live revision"
  )
end

---@param owner table<string, unknown>
---@return table<string, unknown> the live savings record
local function liveMom(owner)
  local readPhone = owner.readPhone --[[@as fun(self: table<string, unknown>): table<string, unknown>]]
  local phone = readPhone(owner)
  assert(type(phone) == "table" and type(phone.mom) == "table", "savings candidates read the live savings record")
  return phone.mom --[[@as table<string, unknown>]]
end

-- Computes the source savings split from the actual money increase after
-- the player ceiling: integer truncation of the quarter share, capped by
-- Mom's remaining capacity, with only the amount actually transferred
-- leaving the player's candidate. Pure arithmetic: no draws, no mutation.
---@param beforePlayer integer pocket money before the battle result
---@param afterPlayer integer pocket money after the capped prize or debit
---@param momBalance integer current savings balance
---@param battleKind string source battle context
---@return integer transfer, integer playerKeeps, integer momKeeps
function PhoneRewards.settlementFor(beforePlayer, afterPlayer, momBalance, battleKind)
  checkMoney(beforePlayer, "pocket money")
  checkMoney(afterPlayer, "pocket money")
  checkMoney(momBalance, "savings balance")
  assert(type(battleKind) == "string" and battleKind ~= "", "savings settlement names its battle context")
  local gain = math.min(afterPlayer, PhoneRewards.PLAYER_MAX) - beforePlayer
  if gain <= 0 then
    return 0, afterPlayer, momBalance
  end
  if PhoneRewards.EXCLUDED_BATTLE_KINDS[battleKind] == true then
    return 0, afterPlayer, momBalance
  end
  local room = PhoneRewards.MOM_MAX - momBalance
  if room < 0 then
    room = 0
  end
  local transfer = math.min(math.floor(gain / PhoneRewards.SAVINGS_DIVISOR), room)
  return transfer, math.min(afterPlayer, PhoneRewards.PLAYER_MAX) - transfer, momBalance + transfer
end

-- Every staged write keeps the companion bucket restorable: only
-- schema-owned fields change (savings balance, the claimed purchase
-- map, gift entries shaped as item records, call triggers). Draws and
-- transfers travel in the staged record and the publish receipt, never
-- as extra bucket fields.

---@param owner table<string, unknown>
---@param expectedRevision integer
local function checkCurrent(owner, expectedRevision)
  local revisionOf = owner.revision --[[@as fun(self: table<string, unknown>): integer]]
  if revisionOf(owner) ~= expectedRevision then
    Errors.raise(PhoneRewards.STALE_CODE, "phone savings candidate is stale and cannot publish", {})
  end
end

-- Publishes one validated savings record plus an optional gift-call
-- trigger as a single staged batch through the durable owner. The owner
-- validates the complete stage and advances the revision once; a stale
-- batch publishes nothing.
---@param owner table<string, unknown>
---@param expectedRevision integer
---@param savings table<string, unknown> the canonical savings record
---@param trigger string? gift-call trigger to set with the same batch
local function publishSavings(owner, expectedRevision, savings, trigger)
  local stage = owner.prepare --[[@as fun(self: table<string, unknown>, expectedRevision: integer, mutate: fun(edit: table<string, fun()>)): table<string, unknown>]]
  local candidate = stage(owner, expectedRevision, function(edit)
    local setMom = edit.setMom --[[@as fun(self: table<string, fun()>, savings: table<string, unknown>)]]
    assert(type(setMom) == "function", "savings publication writes through the staged savings operation")
    setMom(edit, savings)
    if trigger ~= nil then
      local setTrigger = edit.setTrigger --[[@as fun(self: table<string, fun()>, key: string, active: boolean)]]
      assert(type(setTrigger) == "function", "savings publication stages its gift-call trigger")
      setTrigger(edit, trigger, true)
    end
  end)
  local publish = candidate.publish --[[@as fun(self: table<string, unknown>): table<string, unknown>]]
  publish(candidate)
end

---@param value unknown
---@return table<string, unknown> detached copy of a gift entry
local function copyGift(value)
  assert(type(value) == "table", "savings gifts stay item records")
  local entry = value --[[@as table<string, unknown>]]
  local out = {}
  for key, child in pairs(entry) do
    out[key] = child
  end
  return out
end

local copyQueue, copyClaimed, purchaseEffects

-- Stages the battle-winnings split as a revisioned candidate. The staged
-- record carries the transfer, the player's kept money, and the new
-- savings balance as data; publication writes the savings side once and
-- advances the revision once. A stale candidate publishes nothing. The
-- draw stream is never drawn: settlement needs no draw, so an optional
-- stream may be supplied for forward compatibility and is left untouched.
---@param opts { state: table<string, unknown>, beforePlayer: integer, afterPlayer: integer, momBalance: integer, battleKind: string, outcomeId: string, random: table<string, unknown>?, itemCatalog: table<string, unknown>?, momPurchases: table<integer, table<string, unknown>>? }
---@param expectedRevision integer
---@return { isCurrent: fun(): boolean, publish: fun(): table<string, unknown>, transfer: integer, playerMoney: integer, momBalance: integer, outcomeId: string }
function PhoneRewards.prepareBattle(opts, expectedRevision)
  assert(type(opts) == "table", "savings settlement stages its battle facts")
  local owner = checkState(opts.state)
  checkRevision(expectedRevision)
  assert(type(opts.outcomeId) == "string" and opts.outcomeId ~= "", "savings settlement names its outcome")
  assert(type(opts.battleKind) == "string" and opts.battleKind ~= "", "savings settlement names its battle context")
  local transfer, playerMoney, momBalance =
    PhoneRewards.settlementFor(opts.beforePlayer, opts.afterPlayer, opts.momBalance, opts.battleKind)
  local live = liveMom(owner)
  local stagedMom = {
    balance = momBalance,
    purchases = copyClaimed(live.purchases),
    gifts = copyQueue(live.gifts),
  }
  local queued, berryPending, berryKeys = false, false, {}
  if transfer > 0 then
    assert(type(opts.itemCatalog) == "table", "battle savings resolve source item identities")
    local sourceRecords = assert(opts.momPurchases, "battle savings use the compiled source gift table")
    local purchases = {}
    for _, entry in ipairs(sourceRecords) do
      if entry.kind == "purchase" then
        purchases[#purchases + 1] = entry
      elseif entry.kind == "berry" then
        berryKeys[#berryKeys + 1] = resolveItem(opts.itemCatalog, entry.nativeItemId)
      else
        assert(false, "compiled Mom gifts carry a purchase or berry identity")
      end
    end
    assert(#purchases == 9 and #berryKeys == PhoneRewards.BERRY_CHOICES, "the compiled Mom gift vectors are complete")
    stagedMom, queued, berryPending = purchaseEffects(live, momBalance, purchases, berryKeys, opts.itemCatalog)
    if berryPending then
      assert(type(opts.random) == "table", "the berry fallback stages its existing draw stream")
    end
  end
  local box = { published = false }
  local function isCurrent()
    local revisionOf = owner.revision --[[@as fun(self: table<string, unknown>): integer]]
    return not box.published and revisionOf(owner) == expectedRevision
  end
  local function publish()
    if box.published then
      Errors.raise(PhoneRewards.STALE_CODE, "phone savings candidate is stale and cannot publish", {})
    end
    box.published = true
    checkCurrent(owner, expectedRevision)
    if berryPending then
      local random = opts.random --[[@as { lc: fun(self: table<string, unknown>, label: string): integer }]]
      assert(type(random) == "table", "the staged berry purchase draws through its existing stream")
      local index = random:lc(PhoneRewards.BERRY_DRAW_LABEL) % PhoneRewards.BERRY_CHOICES
      local berryKey = assert(berryKeys[index + 1], "the source berry vector covers each draw")
      stagedMom.gifts[#stagedMom.gifts + 1] = {
        item = berryKey,
        quantity = PhoneRewards.BERRY_QUANTITY,
      }
      stagedMom.balance = stagedMom.balance - PhoneRewards.BERRY_COST
    end
    publishSavings(owner, expectedRevision, stagedMom, queued and PhoneRewards.MOM_GIFT_TRIGGER or nil)
    return { transfer = transfer, playerMoney = playerMoney, momBalance = stagedMom.balance }
  end
  return {
    isCurrent = isCurrent,
    publish = publish,
    transfer = transfer,
    playerMoney = playerMoney,
    momBalance = stagedMom.balance,
    outcomeId = opts.outcomeId,
  }
end

---@param queue unknown
---@return table<integer, table<string, unknown>> detached working copy of the gift queue
function copyQueue(queue)
  assert(type(queue) == "table", "savings staging reads the gift queue")
  local out = {}
  for index, entry in
    ipairs(queue --[[@as table<integer, unknown>]])
  do
    out[index] = copyGift(entry)
  end
  return out
end

---@param claimed unknown
---@return table<string, boolean> working copy of the claimed purchase flags
function copyClaimed(claimed)
  local out = {}
  if claimed ~= nil then
    assert(type(claimed) == "table", "savings staging reads claimed purchase flags")
    for key, value in
      pairs(claimed --[[@as table<string, boolean>]])
    do
      assert(type(key) == "string" and value == true, "claimed purchases stay a flag set")
      out[key] = true
    end
  end
  return out
end

function purchaseEffects(recorded, balance, purchases, berryKeys, itemCatalog)
  local queue = copyQueue(recorded.gifts)
  local claimed = copyClaimed(recorded.purchases)
  local oldBalance = recorded.balance --[[@as integer]]
  local boughtAny = false
  for _, entry in ipairs(purchases) do
    assert(
      type(entry) == "table"
        and type(entry.sourceIndex) == "number"
        and entry.sourceIndex % 1 == 0
        and entry.sourceIndex >= 0
        and type(entry.nativeItemId) == "number"
        and entry.nativeItemId % 1 == 0
        and type(entry.threshold) == "number"
        and entry.threshold % 1 == 0
        and type(entry.cost) == "number"
        and entry.cost % 1 == 0,
      "native Mom purchase rows carry their source identity and exact costs"
    )
    if #queue >= PhoneRewards.GIFT_FIFO_MAX then
      break
    end
    local sourceIndex = entry.sourceIndex --[[@as integer]]
    local flag = "item-" .. tostring(sourceIndex)
    local itemKey = resolveItem(itemCatalog, entry.nativeItemId --[[@as integer]])
    local legacyFlag = itemKey .. "-" .. tostring(entry.threshold)
    local priorFlag = LEGACY_PURCHASE_FLAGS[sourceIndex]
    if claimed[flag] ~= true and claimed[legacyFlag] ~= true and claimed[priorFlag] ~= true then
      if balance < entry.threshold then
        break
      end
      queue[#queue + 1] = { item = itemKey, quantity = 1 }
      balance = balance - entry.cost --[[@as integer]]
      claimed[flag] = true
      boughtAny = true
    end
  end
  local berryPending = false
  if not boughtAny and #queue < PhoneRewards.GIFT_FIFO_MAX then
    berryPending = math.floor(balance / PhoneRewards.BERRY_TIER) > math.floor(oldBalance / PhoneRewards.BERRY_TIER)
  end
  assert(
    not berryPending or #berryKeys == PhoneRewards.BERRY_CHOICES,
    "the source berry table contains all resistance berries"
  )
  return { balance = balance, purchases = claimed, gifts = queue }, boughtAny or berryPending, berryPending
end

-- Stages the source purchase walk for focused callers. BattleRuntime uses
-- this same walk inside prepareBattle so payout and purchase publish once.
---@param expectedRevision integer
---@param opts { state: table<string, unknown>, balance: integer, previousBalance: integer, random: table<string, unknown>?, itemCatalog: table<string, unknown>, momPurchases: table<integer, table<string, unknown>> }
---@return { isCurrent: fun(): boolean, publish: fun(): table<string, unknown> }
function PhoneRewards.preparePurchases(expectedRevision, opts)
  assert(type(opts) == "table", "savings purchases stage their balance facts")
  local owner = checkState(opts.state)
  checkRevision(expectedRevision)
  checkMoney(opts.balance, "updated balance")
  checkMoney(opts.previousBalance, "previous balance")
  assert(opts.balance >= opts.previousBalance, "savings purchases apply positive balance changes")
  local recorded = liveMom(owner)
  assert(type(recorded.balance) == "number", "savings staging reads the recorded balance")
  assert(type(opts.itemCatalog) == "table", "savings purchases resolve source items")
  local purchases, berryKeys = {}, {}
  for _, entry in ipairs(opts.momPurchases) do
    if entry.kind == "purchase" then
      purchases[#purchases + 1] = entry
    elseif entry.kind == "berry" then
      berryKeys[#berryKeys + 1] = resolveItem(opts.itemCatalog, entry.nativeItemId)
    else
      assert(false, "compiled Mom gifts carry a purchase or berry identity")
    end
  end
  assert(#purchases == 9 and #berryKeys == PhoneRewards.BERRY_CHOICES, "the compiled Mom gift vectors are complete")
  local stagedMom, queued, berryPending =
    purchaseEffects(recorded, opts.balance, purchases, berryKeys, opts.itemCatalog)
  if berryPending then
    assert(type(opts.random) == "table", "the berry fallback stages its existing draw stream")
  end
  local box = { published = false }
  local function isCurrent()
    local revisionOf = owner.revision --[[@as fun(self: table<string, unknown>): integer]]
    return not box.published and revisionOf(owner) == expectedRevision
  end
  local function publish()
    if box.published then
      Errors.raise(PhoneRewards.STALE_CODE, "phone savings candidate is stale and cannot publish", {})
    end
    box.published = true
    checkCurrent(owner, expectedRevision)
    if berryPending then
      local random = opts.random --[[@as { lc: fun(self: table<string, unknown>, label: string): integer }]]
      local index = random:lc(PhoneRewards.BERRY_DRAW_LABEL) % PhoneRewards.BERRY_CHOICES
      local berryKey = assert(berryKeys[index + 1], "the source berry vector covers each draw")
      stagedMom.gifts[#stagedMom.gifts + 1] = {
        item = berryKey,
        quantity = PhoneRewards.BERRY_QUANTITY,
      }
      stagedMom.balance = stagedMom.balance - PhoneRewards.BERRY_COST
    end
    publishSavings(owner, expectedRevision, stagedMom, queued and PhoneRewards.MOM_GIFT_TRIGGER or nil)
    return { balance = stagedMom.balance, gifts = copyQueue(stagedMom.gifts) }
  end
  return { isCurrent = isCurrent, publish = publish }
end

-- Stages the queue-only half of the source gift delivery. The source script
-- has already completed the standard Bag give before opcode 812 reaches this
-- owner; this candidate never changes Bag inventory.
---@param expectedRevision integer
---@param opts { state: table<string, unknown>, gift: { item: string, quantity: integer } }
---@return { isCurrent: fun(): boolean, publish: fun(): table<string, unknown> }
function PhoneRewards.prepareCollection(expectedRevision, opts)
  assert(type(opts) == "table", "gift collection stages its pending gift")
  local owner = checkState(opts.state)
  checkRevision(expectedRevision)
  assert(type(opts.gift) == "table", "gift collection names its pending gift")
  local gift = opts.gift --[[@as { item: string, quantity: integer }]]
  assert(type(gift.item) == "string" and gift.item ~= "", "pending gifts name their item")
  assert(
    type(gift.quantity) == "number" and gift.quantity % 1 == 0 and gift.quantity >= 1,
    "pending gifts carry a quantity"
  )
  local recorded = liveMom(owner)
  local pending = copyQueue(recorded.gifts)
  if pending[1] == nil or pending[1].item ~= gift.item or pending[1].quantity ~= gift.quantity then
    Errors.raise(PhoneRewards.STALE_CODE, "no matching gift waits for collection", {})
  end
  local box = { published = false }
  local function isCurrent()
    local revisionOf = owner.revision --[[@as fun(self: table<string, unknown>): integer]]
    return not box.published and revisionOf(owner) == expectedRevision
  end
  local function publish()
    if box.published then
      Errors.raise(PhoneRewards.STALE_CODE, "phone savings candidate is stale and cannot publish", {})
    end
    box.published = true
    checkCurrent(owner, expectedRevision)
    local fresh = copyQueue(liveMom(owner).gifts)
    if fresh[1] == nil or fresh[1].item ~= gift.item or fresh[1].quantity ~= gift.quantity then
      Errors.raise(PhoneRewards.STALE_CODE, "no matching gift waits for collection", {})
    end
    table.remove(fresh, 1)
    local live = liveMom(owner)
    publishSavings(owner, expectedRevision, {
      balance = live.balance,
      purchases = live.purchases,
      gifts = fresh,
    })
    return { granted = copyGift(gift) }
  end
  return { isCurrent = isCurrent, publish = publish }
end

return PhoneRewards
