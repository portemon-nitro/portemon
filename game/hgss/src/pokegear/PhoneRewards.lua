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
PhoneRewards.BERRY_ITEM_PREFIX = "custom.berry-"
PhoneRewards.MOM_GIFT_TRIGGER = "mom.gift"

PhoneRewards.STALE_CODE = "POKEGEAR_STALE_CANDIDATE"

-- Battles whose winnings never reach savings: no transfer on nonpositive
-- gain and none in these excluded source contexts.
PhoneRewards.EXCLUDED_BATTLE_KINDS = { link = true }

-- Normal purchases in source process order: balance threshold and exact
-- cost per entry. Item keys follow the companion catalog namespace; an
-- explicit override table may replace this default without changing the
-- order, thresholds, or costs.
---@return table<integer, { item: string, threshold: integer, cost: integer }>
function PhoneRewards.normalPurchases()
  return {
    { item = "custom.super-potion", threshold = 900, cost = 600 },
    { item = "custom.repel", threshold = 4000, cost = 270 },
    { item = "custom.super-potion", threshold = 7000, cost = 600 },
    { item = "custom.silk-scarf", threshold = 10000, cost = 100 },
    { item = "custom.moon-stone", threshold = 15000, cost = 3000 },
    { item = "custom.hyper-potion", threshold = 19000, cost = 900 },
    { item = "custom.choice-scarf", threshold = 30000, cost = 200 },
    { item = "custom.muscle-band", threshold = 40000, cost = 200 },
    { item = "custom.focus-sash", threshold = 50000, cost = 200 },
  }
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

-- Stages the battle-winnings split as a revisioned candidate. The staged
-- record carries the transfer, the player's kept money, and the new
-- savings balance as data; publication writes the savings side once and
-- advances the revision once. A stale candidate publishes nothing. The
-- draw stream is never drawn: settlement needs no draw, so an optional
-- stream may be supplied for forward compatibility and is left untouched.
---@param opts { state: table<string, unknown>, beforePlayer: integer, afterPlayer: integer, momBalance: integer, battleKind: string, outcomeId: string, random: table<string, unknown>? }
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
    local live = liveMom(owner)
    publishSavings(owner, expectedRevision, {
      balance = momBalance,
      purchases = live.purchases,
      gifts = live.gifts,
    })
    return { transfer = transfer, playerMoney = playerMoney, momBalance = momBalance }
  end
  return {
    isCurrent = isCurrent,
    publish = publish,
    transfer = transfer,
    playerMoney = playerMoney,
    momBalance = momBalance,
    outcomeId = opts.outcomeId,
  }
end

---@param queue unknown
---@return table<integer, table<string, unknown>> detached working copy of the gift queue
local function copyQueue(queue)
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
local function copyClaimed(claimed)
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

-- Stages one balance-change pass over the source purchase table as a
-- revisioned candidate. Unclaimed thresholds crossed since the previous
-- balance buy in source order until the five-entry queue fills; when no
-- normal purchase fires and the updated balance reaches a fresh
-- floor(balance/3000) tier above the recorded one, the berry fallback
-- draws at publication. A full queue stages nothing and draws nothing.
---@param expectedRevision integer
---@param opts { state: table<string, unknown>, balance: integer, previousBalance: integer, random: table<string, unknown>?, queuedGifts: table<integer, table<string, unknown>>?, claimed: table<string, boolean>?, purchases: table<integer, { item: string, threshold: integer, cost: integer }>? }
---@return { isCurrent: fun(): boolean, publish: fun(): table<string, unknown> }
function PhoneRewards.preparePurchases(expectedRevision, opts)
  assert(type(opts) == "table", "savings purchases stage their balance facts")
  local owner = checkState(opts.state)
  checkRevision(expectedRevision)
  checkMoney(opts.balance, "updated balance")
  checkMoney(opts.previousBalance, "previous balance")
  assert(opts.balance >= opts.previousBalance, "savings purchases apply positive balance changes")
  local table_ = opts.purchases or PhoneRewards.normalPurchases()
  assert(type(table_) == "table", "savings purchases read the source purchase table")
  local recorded = liveMom(owner)
  assert(type(recorded.balance) == "number", "savings staging reads the recorded balance")
  local recordedBalance = recorded.balance --[[@as integer]]
  local recordedGifts = recorded.gifts
  local recordedFlags = recorded.purchases
  local queue = opts.queuedGifts ~= nil and copyQueue(opts.queuedGifts) or copyQueue(recordedGifts)
  local claimed = copyClaimed(opts.claimed)
  if recordedFlags ~= nil then
    assert(type(recordedFlags) == "table", "recorded purchase flags stay a flag set")
    for key, value in
      pairs(recordedFlags --[[@as table<string, boolean>]])
    do
      if value == true then
        claimed[key] = true
      end
    end
  end
  local balance = opts.balance --[[@as integer]]
  local previousBalance = opts.previousBalance --[[@as integer]]
  local costs = 0
  local boughtAny = false
  for _, entry in ipairs(table_) do
    assert(
      type(entry) == "table"
        and type(entry.item) == "string"
        and type(entry.threshold) == "number"
        and type(entry.cost) == "number",
      "source purchases carry item, threshold, and cost"
    )
    if #queue >= PhoneRewards.GIFT_FIFO_MAX then
      break
    end
    local flag = entry.item .. "-" .. tostring(entry.threshold)
    if claimed[flag] ~= true and entry.threshold > previousBalance and entry.threshold <= balance then
      queue[#queue + 1] = { item = entry.item, quantity = 1 }
      costs = costs + entry.cost
      claimed[flag] = true
      boughtAny = true
    end
  end
  local berryPending = false
  if not boughtAny and #queue < PhoneRewards.GIFT_FIFO_MAX then
    if math.floor(balance / PhoneRewards.BERRY_TIER) > math.floor(recordedBalance / PhoneRewards.BERRY_TIER) then
      berryPending = true
    end
  end
  local random = opts.random
  if berryPending then
    assert(type(random) == "table", "the berry fallback stages its draw stream")
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
    local finalCosts = costs
    if berryPending then
      assert(type(random) == "table", "the berry fallback draws at publication")
      local draw = random --[[@as { lc: fun(self: table<string, unknown>, label: string): integer }]]
      local berryIndex = draw:lc(PhoneRewards.BERRY_DRAW_LABEL) % PhoneRewards.BERRY_CHOICES
      queue[#queue + 1] =
        { item = PhoneRewards.BERRY_ITEM_PREFIX .. berryIndex, quantity = PhoneRewards.BERRY_QUANTITY }
      finalCosts = finalCosts + PhoneRewards.BERRY_COST
    end
    local settledBalance = balance - finalCosts
    local trigger = nil
    if boughtAny or berryPending then
      trigger = PhoneRewards.MOM_GIFT_TRIGGER
    end
    publishSavings(owner, expectedRevision, {
      balance = settledBalance,
      purchases = claimed,
      gifts = queue,
    }, trigger)
    return { balance = settledBalance, gifts = copyQueue(queue) }
  end
  return { isCurrent = isCurrent, publish = publish }
end

---@param pending table<integer, table<string, unknown>>
---@param gift { item: string, quantity: integer }
---@return integer? matching queue position
local function findPending(pending, gift)
  for index, entry in ipairs(pending) do
    if entry.item == gift.item and entry.quantity == gift.quantity then
      return index
    end
  end
  return nil
end

-- Stages collection of one pending gift as a revisioned candidate. The
-- gift must already be pending: preparation fails when nothing matching
-- waits, so a repeated collection can never duplicate inventory.
-- Publication grants through the live Bag preparation when a Bag owner
-- is supplied, otherwise through the explicit synthetic free slot count;
-- a full Bag fails before clearing, keeping the same reward pending
-- without a reroll. Clearing and granting happen in one non-yielding
-- publication.
---@param expectedRevision integer
---@param opts { state: table<string, unknown>, gift: { item: string, quantity: integer }, bagFreeSlots: integer?, bag: table<string, unknown>?, bagRevision: integer? }
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
  if findPending(pending, gift) == nil then
    Errors.raise(PhoneRewards.STALE_CODE, "no matching gift waits for collection", {})
  end
  local bag = opts.bag
  local bagRevision = opts.bagRevision
  local bagFreeSlots = opts.bagFreeSlots
  if bag ~= nil then
    assert(type(bag) == "table", "gift collection grants through the live Bag owner")
  else
    assert(
      type(bagFreeSlots) == "number" and bagFreeSlots % 1 == 0,
      "gift collection without a Bag owner names the synthetic free slot count"
    )
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
    local position = findPending(fresh, gift)
    if position == nil then
      Errors.raise(PhoneRewards.STALE_CODE, "no matching gift waits for collection", {})
    end
    if bag ~= nil then
      local live = bag --[[@as table<string, unknown>]]
      local stage = live.prepareInventoryChanges --[[@as fun(self: table<string, unknown>, revision: integer, deltas: table<integer, table<string, unknown>>): table<string, unknown>?]]
      local revisionOf = live.revision --[[@as fun(self: table<string, unknown>): integer]]
      local expected = bagRevision or revisionOf(live)
      local item = gift.item
      assert(type(item) == "string", "live Bag grants name their item")
      local staged = stage(live, expected, { { op = "add", item = item, quantity = gift.quantity } })
      if staged == nil then
        Errors.raise(PhoneRewards.STALE_CODE, "the full Bag keeps the gift pending", {})
      end
      local commit = staged --[[@as { publish: fun() }]]
      assert(type(commit.publish) == "function", "Bag grants publish through their preparation")
      commit.publish()
    else
      assert(type(bagFreeSlots) == "number", "synthetic collection names its free slot count")
      if bagFreeSlots <= 0 then
        Errors.raise(PhoneRewards.STALE_CODE, "the full Bag keeps the gift pending", {})
      end
    end
    table.remove(fresh, position --[[@as integer]])
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
