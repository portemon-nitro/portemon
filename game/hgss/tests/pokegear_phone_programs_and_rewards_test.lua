-- Foreground phone conversations, earned rewards, and savings: conversation
-- effects run once at their source stage, missing world owners fail with
-- attribution instead of invented answers, battle winnings split into Mom
-- savings through capped source arithmetic, and savings purchases follow
-- source order with bounded gift queues. Lower-level cases pin request
-- rejection, every selector early return in source order, threshold and
-- tier boundaries on both sides, stale and replayed candidates, absent
-- versus zero owners, exactly-once battle publication, and companion
-- restore of staged savings. All expectations use synthetic contacts and
-- independent arithmetic, never the behaviour under test as its own oracle.

local Assert = require("tests.support.Assert")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

local SOURCE_PURCHASES = {
  { sourceIndex = 0, nativeItemId = 26, threshold = 900, cost = 600 },
  { sourceIndex = 1, nativeItemId = 79, threshold = 4000, cost = 270 },
  { sourceIndex = 2, nativeItemId = 26, threshold = 7000, cost = 600 },
  { sourceIndex = 3, nativeItemId = 251, threshold = 10000, cost = 100 },
  { sourceIndex = 4, nativeItemId = 81, threshold = 15000, cost = 3000 },
  { sourceIndex = 5, nativeItemId = 25, threshold = 19000, cost = 900 },
  { sourceIndex = 6, nativeItemId = 287, threshold = 30000, cost = 200 },
  { sourceIndex = 7, nativeItemId = 266, threshold = 40000, cost = 200 },
  { sourceIndex = 8, nativeItemId = 275, threshold = 50000, cost = 200 },
}
local SOURCE_BERRIES = {
  "CHERI_BERRY",
  "CHESTO_BERRY",
  "PECHA_BERRY",
  "RAWST_BERRY",
  "ASPEAR_BERRY",
  "LEPPA_BERRY",
  "ORAN_BERRY",
  "PERSIM_BERRY",
  "LUM_BERRY",
  "SITRUS_BERRY",
  "FIGY_BERRY",
  "WIKI_BERRY",
  "MAGO_BERRY",
  "AGUAV_BERRY",
  "IAPAPA_BERRY",
  "RAZZ_BERRY",
  "BLUK_BERRY",
}
local SOURCE_ITEM_KEYS = {
  [25] = "HYPER_POTION",
  [26] = "SUPER_POTION",
  [79] = "REPEL",
  [81] = "MOON_STONE",
  [251] = "SILK_SCARF",
  [266] = "MUSCLE_BAND",
  [275] = "FOCUS_SASH",
  [287] = "CHOICE_SCARF",
}
for index, key in ipairs(SOURCE_BERRIES) do
  SOURCE_ITEM_KEYS[148 + index] = key
end

local function sourceMomPurchases()
  local records = {}
  for _, entry in ipairs(SOURCE_PURCHASES) do
    records[#records + 1] = {
      kind = "purchase",
      sourceIndex = entry.sourceIndex,
      nativeItemId = entry.nativeItemId,
      threshold = entry.threshold,
      cost = entry.cost,
    }
  end
  for index, key in ipairs(SOURCE_BERRIES) do
    records[#records + 1] = {
      kind = "berry",
      sourceIndex = index - 1,
      nativeItemId = 148 + index,
      threshold = 0,
      cost = 100,
      key = key,
    }
  end
  return records
end

local TEST_ITEM_CATALOG = {
  itemKeyByNativeId = function(_, nativeId)
    local key = SOURCE_ITEM_KEYS[nativeId]
    assert(key ~= nil, "test catalog contains each native Mom item")
    return key
  end,
  item = function(_, key)
    for nativeId, itemKey in pairs(SOURCE_ITEM_KEYS) do
      if itemKey == key then
        return { nativeId = nativeId }
      end
    end
    error("test catalog has no native item " .. key, 0)
  end,
}

local function prepareBattle(opts, expectedRevision)
  opts.momPurchases = sourceMomPurchases()
  opts.itemCatalog = opts.itemCatalog or TEST_ITEM_CATALOG
  return require("game.hgss.src.pokegear.PhoneRewards").prepareBattle(opts, expectedRevision)
end

local function preparePurchases(expectedRevision, opts)
  opts.momPurchases = sourceMomPurchases()
  opts.itemCatalog = opts.itemCatalog or TEST_ITEM_CATALOG
  local current = opts.state:readPhone().mom
  opts.state:setMom({
    balance = opts.previousBalance,
    purchases = opts.claimed or current.purchases,
    gifts = opts.queuedGifts or current.gifts,
  })
  expectedRevision = opts.state:revision()
  return require("game.hgss.src.pokegear.PhoneRewards").preparePurchases(expectedRevision, opts)
end

-- Loads a phone module that does not exist yet at this baseline. The
-- failure names the missing behaviour instead of surfacing as a suite load
-- error, so the pre-implementation red stays attributable.
---@param moduleName string
---@param missingMessage string
---@return table
local function requireFeature(moduleName, missingMessage)
  local ok, mod = pcall(require, moduleName)
  if not ok then
    error(missingMessage, 0)
  end
  assert(type(mod) == "table", missingMessage)
  return mod --[[@as table]]
end

local function visualRef(path)
  return { image = path, width = 32, height = 32, anchorX = 0, anchorY = 0 }
end

-- Synthetic companion catalog with one contact per exercised family,
-- validated through the real asset schema so the phone tests borrow only
-- genuine semantic references.
---@return table
local function fixtureManifest()
  return {
    schema = "g4-pokegear-assets-v2",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png") },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png") },
    phone = { panel = visualRef("assets/generated/pokegear/phone-panel.png") },
    map = { base = visualRef("assets/generated/pokegear/map-base.png") },
    fly = { base = visualRef("assets/generated/pokegear/fly-base.png") },
    radio = { dial = visualRef("assets/generated/pokegear/radio-dial.png") },
    catalog = {
      contacts = {
        { key = "custom.mom", family = "mother", sortWeight = 10 },
        { key = "custom.trainer-plain", family = "trainer", sortWeight = 20 },
        { key = "custom.kurt", family = "kurt", sortWeight = 30 },
        { key = "custom.daycare-lady", family = "daycare", sortWeight = 40 },
        { key = "custom.leader-falkner", family = "gym", sortWeight = 50 },
      },
      contactOrder = {
        "custom.mom",
        "custom.trainer-plain",
        "custom.kurt",
        "custom.daycare-lady",
        "custom.leader-falkner",
      },
      callDefinitions = {},
      callTriggers = {},
      rematches = {},
      gifts = {},
      momPurchases = {},
      locations = {
        { key = "custom.new-bark" },
      },
      flypoints = {},
      regionMap = require("tests.support.PokegearRegionMapFixture").build(),
      reception = {},
      shows = {},
      radioEffects = {},
    },
    text = {},
    sequences = {},
  }
end

---@param refs table
---@return table
local function catalogRefs(refs)
  return { catalog = refs.catalog }
end

-- A deterministic audio boundary: every effect wait completes on the next
-- poll, so the conversation advances through completion state rather than
-- wall-clock waits.
---@return table
local function instantAudio()
  local completed = true
  return {
    playDialing = function()
      completed = false
    end,
    isEffectWaitComplete = function()
      local done = completed
      completed = true
      return done
    end,
  }
end

local function phoneMessages()
  return {
    greeting = "custom.greeting",
    program = "custom.program",
    resolveLine = function()
      return { tokens = { { kind = "glyph", code = 1, text = "X", raw = { 1 } } } }
    end,
  }
end

local function localPhoneSelectorFacts()
  return function()
    return { localMap = true }
  end
end

-- A compiled synthetic permission pair covers both directional outcomes
-- without claiming that HGSS has a native incoming-only map.
function T.tests.phone_admission_uses_synthetic_directional_map_permissions()
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
  local PhoneWorldContext = require("game.hgss.src.pokegear.PhoneWorldContext")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic phone catalog validates before adding its compiled policy record")
  assert(record ~= nil, "synthetic phone catalog validated above")
  record.catalog.callPermissions = {
    [9000] = { outgoing = false, incoming = true },
  }

  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local state = PokegearState.new({ seed = 9210 }, catalogRefs(record))
  state:registerContact("custom.kurt")
  local contact = nil
  for _, candidate in ipairs(record.catalog.contacts) do
    if candidate.key == "custom.kurt" then
      contact = candidate
      candidate.map = 0
      break
    end
  end
  assert(contact ~= nil, "the synthetic service contact exists")

  local currentMap = { mapId = 9000, mapSectionNativeId = 0 }
  local flags = { isFlagSet = function()
    return false
  end }
  local world = PhoneWorldContext.new({
    state = state,
    catalog = record.catalog,
    runtime = { session = { currentMap = currentMap }, eventState = flags },
    flags = flags,
  })
  local audio = { dials = 0 }
  function audio:playDialing()
    self.dials = self.dials + 1
  end
  function audio:isEffectWaitComplete()
    return true
  end
  local call = PhoneCall.new({
    state = state,
    catalog = record.catalog,
    messages = phoneMessages(),
    world = world,
    audio = audio,
  })

  local blocked = call:begin({
    id = "synthetic-outgoing-denied",
    contact = "custom.kurt",
    direction = "outgoing",
    kind = "ordinary",
  })
  local denied = call:result(blocked)
  Assert.notNil(denied, "synthetic outgoing denial is terminal before dialing")
  Assert.equal(denied.signal, false, "the compiled synthetic pair denies outgoing calls")
  Assert.equal(denied.ready, false, "the denied call is not reported as completed")
  Assert.equal((call:view(blocked) --[[@as table]]).stage, "noSignal", "the rejected handle retains its no-signal view")
  Assert.equal(audio.dials, 0, "the denied direction takes no audio effect")
  call:release(blocked)

  local allowed = call:begin({
    id = "synthetic-incoming-allowed",
    contact = "custom.kurt",
    direction = "incoming",
    kind = "ordinary",
  })
  Assert.isNil(call:result(allowed), "the same synthetic pair allows incoming calls")
  Assert.equal(audio.dials, 2, "the allowed direction acquires its normal dialing effect")
  call:cancel(allowed, "test cleanup")
  call:release(allowed)
end

function T.tests.phone_world_context_samples_the_live_native_map_and_rejects_missing_source()
  local PhoneWorldContext = require("game.hgss.src.pokegear.PhoneWorldContext")
  local ScriptErrors = require("libs.script.src.errors")
  local currentMap = { mapId = 9000 }
  local context = PhoneWorldContext.new({
    state = {},
    catalog = {
      callPermissions = {
        [9000] = { incoming = false, outgoing = false },
        [9001] = { incoming = true, outgoing = true },
      },
    },
    runtime = { session = { currentMap = currentMap } },
  })

  Assert.isFalse(context:canCall("incoming"), "the first live map denies incoming calls")
  Assert.isFalse(context:canCall("outgoing"), "the first live map denies outgoing calls")
  currentMap.mapId = 9001
  Assert.isTrue(context:canCall("incoming"), "a map change is sampled for incoming calls")
  Assert.isTrue(context:canCall("outgoing"), "a map change is sampled for outgoing calls")
  Assert.equal(
    (Assert.throws(function()
      context:canCall("sideways")
    end, "call permissions reject unknown directions") --[[@as table]]).code,
    ScriptErrors.FEATURE_UNAVAILABLE,
    "invalid directions retain feature attribution"
  )

  currentMap.mapId = 9002
  Assert.equal(
    (Assert.throws(function()
      context:canCall("incoming")
    end, "unknown native maps cannot imply permission") --[[@as table]]).code,
    ScriptErrors.FEATURE_UNAVAILABLE,
    "missing source map records retain feature attribution"
  )
end

-- Native dialogue waits for text completion before entering the program
-- stage. Repeated polls do not advance that stage.
function T.tests.phone_text_wait_precedes_the_program_stage()
  local PhoneCall = requireFeature(
    "game.hgss.src.pokegear.PhoneCall",
    "phone calls have no foreground session owner yet: conversation effects cannot stage once at their source step"
  )
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")

  local state = PokegearState.new({ seed = 4242 }, catalogRefs(record))
  state:registerContact("custom.kurt")
  local world = {
    flags = {},
    rematchReady = {},
    canCall = function()
      return true
    end,
    nativeSelectorFacts = localPhoneSelectorFacts(),
  }
  local random = PokegearRandom.new(4242)
  local call = PhoneCall.new({
    state = state,
    catalog = record.catalog,
    messages = phoneMessages(),
    world = world,
    audio = instantAudio(),
    random = random,
  })
  local handle = call:begin({
    id = "call-1",
    contact = "custom.kurt",
    direction = "outgoing",
    kind = "ordinary",
  })

  -- Reaching native dialogue stops at its text wait.
  call:step(handle, {})
  call:step(handle, {})
  Assert.equal((call:view(handle) --[[@as table]]).stage, "message", "native text holds before program effects")

  -- Repeated status and view reads never duplicate the staged effect.
  for _ = 1, 4 do
    call:view(handle)
    call:step(handle, {})
  end
  Assert.isTrue(
    (call:view(handle) --[[@as table]]).stage == "message",
    "repeated polls leave the native text stage unchanged"
  )

  -- Closing during text releases the call lease.
  call:cancel(handle, "hangup")
  local terminal = call:result(handle)
  Assert.notNil(terminal, "a closed call still reports its terminal result")
end

-- A missing world owner is an attributed dependency failure, never an
-- invented empty-world answer: a branch that reads Kurt production state
-- names its missing owner before any effect, while a branch that needs no
-- production state still answers locally.
function T.tests.branches_without_their_world_owner_fail_with_attribution()
  local PhoneWorldContext = requireFeature(
    "game.hgss.src.pokegear.PhoneWorldContext",
    "phone conversations have no world-context adapter yet: missing Kurt, Day Care, and Safari owners cannot fail with attribution"
  )
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = require("libs.hgss.src.save.PokegearState")

  local state = PokegearState.new({ seed = 7 }, catalogRefs(record))
  state:registerContact("custom.kurt")
  state:registerContact("custom.daycare-lady")

  -- No Kurt owner is injected: the production-status branch must name it.
  local withoutKurt = PhoneWorldContext.new({ state = state, flags = {} })
  local err = Assert.throws(function()
    withoutKurt:read("kurt.production")
  end, "a branch reading absent Kurt state must fail")
  local message = tostring((type(err) == "table" and (err.code or err.message)) or err)
  Assert.notNil(
    (message:find("kurt", 1, true) or (type(err) == "table" and err.domain == "kurt")) and true or nil,
    "the Kurt failure must attribute the missing kurt domain"
  )

  -- A local acknowledgement branch reads no production state and still
  -- answers without requiring the absent simulation.
  local localAnswer = withoutKurt:read("kurt.local-greeting")
  Assert.notNil(localAnswer, "a branch needing no production state answers locally")

  -- Same discipline for the Day Care owner: egg facts without the owner
  -- fail by name rather than synthesising a no-egg response.
  local daycareErr = Assert.throws(function()
    withoutKurt:read("daycare.egg")
  end, "a branch reading absent Day Care state must fail")
  local daycareMessage =
    tostring((type(daycareErr) == "table" and (daycareErr.code or daycareErr.message)) or daycareErr)
  Assert.notNil(
    (daycareMessage:find("daycare", 1, true) or (type(daycareErr) == "table" and daycareErr.domain == "daycare"))
        and true
      or nil,
    "the Day Care failure must attribute the missing daycare domain"
  )

  -- Supplying the owner resolves the same branch: absence was the only
  -- blocker, and no draw or mutation happened while it was missing.
  local withKurt = PhoneWorldContext.new({ state = state, flags = {}, kurt = { status = "working" } })
  local production = withKurt:read("kurt.production")
  Assert.notNil(production, "the branch resolves once its owner is present")
end

-- Independent source arithmetic for the savings split: the transfer comes
-- from the actual capped money increase divided by four with integer
-- truncation, limited by Mom's remaining capacity, and only the amount
-- actually transferred leaves the player's candidate.
---@param beforePlayer integer
---@param afterPlayer integer
---@param momBalance integer
---@return integer transfer
---@return integer playerKeeps
---@return integer momKeeps
local function expectedSettlement(beforePlayer, afterPlayer, momBalance)
  local MOM_CAP = 999999
  local gain = afterPlayer - beforePlayer
  if gain <= 0 then
    return 0, afterPlayer, momBalance
  end
  local raw = math.floor(gain / 4)
  local room = MOM_CAP - momBalance
  if room < 0 then
    room = 0
  end
  local transfer = math.min(raw, room)
  return transfer, afterPlayer - transfer, momBalance + transfer
end

-- Battle winnings split into Mom savings through the capped actual gain:
-- fractional gains truncate, the player ceiling binds before the quarter
-- share, Mom's capacity caps the transfer, losses move nothing, repeats
-- settle once, and stale candidates mutate no owner.
function T.tests.battle_winnings_split_into_savings_from_the_capped_actual_gain()
  local PhoneRewards = requireFeature(
    "game.hgss.src.pokegear.PhoneRewards",
    "phone rewards have no settlement owner yet: battle winnings cannot split into Mom savings"
  )
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")

  ---@param beforePlayer integer
  ---@param afterPlayer integer
  ---@param momBalance integer
  ---@param outcomeId string
  ---@param battleKind string
  ---@return integer transfer
  ---@return integer playerKeeps
  ---@return integer momKeeps
  local function settle(beforePlayer, afterPlayer, momBalance, outcomeId, battleKind)
    local state = PokegearState.new({ seed = 99 }, catalogRefs(record))
    local claimed = {}
    if momBalance >= 50000 then
      for _, entry in ipairs(SOURCE_PURCHASES) do
        claimed["item-" .. tostring(entry.sourceIndex)] = true
      end
    end
    state:setMom({ balance = momBalance, purchases = claimed, gifts = {} })
    local revision = state:revision()
    local staged = prepareBattle({
      state = state,
      beforePlayer = beforePlayer,
      afterPlayer = afterPlayer,
      momBalance = momBalance,
      battleKind = battleKind,
      outcomeId = outcomeId,
    }, revision)
    Assert.isTrue(staged.isCurrent(), "a freshly staged settlement is current")
    local receipt = staged.publish()
    local phone = state:readPhone()
    local mom = phone.mom --[[@as table]]
    Assert.equal(receipt.transfer, staged.transfer, "publication reports the staged transfer")
    Assert.equal(receipt.momBalance, mom.balance, "publication reports the staged balance")
    return staged.transfer, staged.playerMoney, mom.balance
  end

  -- Ordinary quarter shares with integer truncation at the 3/4/5 boundary.
  do
    local transfer, player, mom = settle(1000, 1500, 0, "win-1", "trainer")
    local wantTransfer, wantPlayer, wantMom = expectedSettlement(1000, 1500, 0)
    Assert.equal(transfer, wantTransfer, "a gain of 500 transfers 125")
    Assert.equal(transfer, 125, "the ordinary quarter share is exact")
    Assert.equal(player, wantPlayer, "the player keeps the gain minus the transfer")
    Assert.equal(mom, wantMom, "Mom banks the transferred share")
  end
  do
    local tiny = settle(1000, 1003, 0, "win-2", "trainer")
    Assert.equal(tiny, 0, "a gain of 3 truncates to no transfer")
    local four = settle(1000, 1004, 0, "win-3", "trainer")
    Assert.equal(four, 1, "a gain of 4 transfers 1")
    local five = settle(1000, 1005, 0, "win-4", "trainer")
    Assert.equal(five, 1, "a gain of 5 transfers 1")
  end

  -- The player ceiling binds before the quarter share is computed.
  do
    local transfer, player, mom = settle(999900, 999999, 0, "win-5", "trainer")
    local wantTransfer, wantPlayer, wantMom = expectedSettlement(999900, 999999, 0)
    Assert.equal(transfer, wantTransfer, "only the capped increase of 99 is split")
    Assert.equal(transfer, 24, "the capped gain truncates to 24")
    Assert.equal(player, wantPlayer, "the player keeps the capped gain minus the transfer")
    Assert.equal(mom, wantMom, "Mom banks the capped share")
  end

  -- Mom's remaining capacity caps the transfer; only the amount actually
  -- moved leaves the player's candidate.
  do
    local transfer, player, mom = settle(1000, 1500, 999990, "win-6", "trainer")
    local wantTransfer, wantPlayer, wantMom = expectedSettlement(1000, 1500, 999990)
    Assert.equal(transfer, wantTransfer, "a nearly full savings caps the transfer to its room")
    Assert.equal(transfer, 9, "only 9 fits under the savings ceiling")
    Assert.equal(player, wantPlayer, "the player keeps the gain minus only the moved 9")
    Assert.equal(mom, wantMom, "Mom stops exactly at the savings ceiling")
  end

  -- Losses and excluded contexts move nothing.
  do
    local transfer, player, mom = settle(1500, 1400, 200, "loss-1", "trainer")
    Assert.equal(transfer, 0, "a lost battle transfers nothing")
    Assert.equal(player, 1400, "a lost battle keeps the player's post-battle money")
    Assert.equal(mom, 200, "a lost battle leaves savings alone")
    local linked = settle(1000, 1500, 0, "win-link", "link")
    Assert.equal(linked, 0, "an excluded battle context transfers nothing")
  end

  -- Repeating the same outcome settles once; a stale candidate mutates no
  -- owner.
  do
    local state = PokegearState.new({ seed = 99 }, catalogRefs(record))
    local revision = state:revision()
    local staged = prepareBattle({
      state = state,
      beforePlayer = 1000,
      afterPlayer = 1500,
      momBalance = 0,
      battleKind = "trainer",
      outcomeId = "win-repeat",
    }, revision)
    staged.publish()
    local once = state:readPhone().mom --[[@as table]]
    local replay = prepareBattle({
      state = state,
      beforePlayer = 1000,
      afterPlayer = 1500,
      momBalance = 0,
      battleKind = "trainer",
      outcomeId = "win-repeat",
    }, revision)
    Assert.isFalse(replay.isCurrent(), "a repeated outcome is no longer current")
    Assert.throws(function()
      replay.publish()
    end, "replaying a settlement must fail")
    Assert.deepEqual(state:readPhone().mom, once, "the replay leaves savings exactly as settled")

    local fresh = state:revision()
    local candidate = prepareBattle({
      state = state,
      beforePlayer = 1000,
      afterPlayer = 1500,
      momBalance = 0,
      battleKind = "trainer",
      outcomeId = "win-stale",
    }, fresh)
    state:registerContact("custom.mom")
    Assert.throws(function()
      candidate.publish()
    end, "a stale settlement must fail")
    local mom = state:readPhone().mom --[[@as table]]
    Assert.equal(mom.balance, once.balance, "a stale settlement moves no savings")
  end
end

-- Independent source purchase table in process order: each entry carries
-- its balance threshold and cost. The berry fallback buys one of seventeen
-- resistance berries in quantity five for cost 100 when a new
-- floor(balance/3000) tier is crossed without a normal purchase.
---@return table[]
local function sourcePurchaseTable()
  return SOURCE_PURCHASES
end

-- Savings purchases follow source order with FIFO boundaries: thresholds
-- process in order with their exact costs, a full five-entry queue draws
-- nothing, claimed flags never rebuy, the berry fallback needs a fresh
-- tier crossing, and a full Bag keeps the queued gift pending without a
-- reroll on the next collection.
function T.tests.savings_purchases_follow_source_order_with_fifo_boundaries()
  local PhoneRewards = requireFeature(
    "game.hgss.src.pokegear.PhoneRewards",
    "phone rewards have no purchase owner yet: savings thresholds cannot enqueue gifts"
  )
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")

  Assert.equal(#sourcePurchaseTable(), 9, "the source table carries nine normal purchases in order")
  Assert.equal(sourcePurchaseTable()[1].threshold, 900, "the first threshold is 900")
  Assert.equal(sourcePurchaseTable()[1].cost, 600, "the first cost is 600")
  Assert.equal(sourcePurchaseTable()[9].threshold, 50000, "the last threshold is 50000")

  -- Crossing the first threshold enqueues exactly its purchase and spends
  -- exactly its cost.
  do
    local state = PokegearState.new({ seed = 11 }, catalogRefs(record))
    local random = PokegearRandom.new(11)
    local candidate = preparePurchases(state:revision(), {
      state = state,
      balance = 950,
      previousBalance = 800,
      random = random,
    })
    candidate.publish()
    local mom = state:readPhone().mom --[[@as table]]
    Assert.equal(#mom.gifts, 1, "one threshold crossing enqueues one gift")
    Assert.equal(mom.gifts[1].item, "SUPER_POTION", "the first purchase is the super potion")
    Assert.equal(mom.balance, 950 - 600, "the purchase spends exactly its source cost")
    Assert.isTrue(mom.purchases["item-0"] == true, "the native source slot is marked claimed")
  end

  -- A full five-entry queue draws nothing and buys nothing.
  do
    local state = PokegearState.new({ seed = 12 }, catalogRefs(record))
    local random = PokegearRandom.new(12)
    local full = {
      { item = "custom.a", quantity = 1 },
      { item = "custom.b", quantity = 1 },
      { item = "custom.c", quantity = 1 },
      { item = "custom.d", quantity = 1 },
      { item = "custom.e", quantity = 1 },
    }
    local before = random:capture()
    local candidate = preparePurchases(state:revision(), {
      state = state,
      balance = 60000,
      previousBalance = 100,
      queuedGifts = full,
      random = random,
    })
    candidate.publish()
    local mom = state:readPhone().mom --[[@as table]]
    Assert.equal(#mom.gifts, 5, "a full queue enqueues nothing further")
    Assert.deepEqual(random:capture(), before, "a full queue consumes no random draw")
    Assert.equal(mom.balance, 60000, "a full queue spends nothing")
  end

  -- Claimed thresholds never rebuy; otherwise the berry fallback fires only
  -- on a fresh tier crossing with a labelled draw inside all seventeen.
  do
    local state = PokegearState.new({ seed = 13 }, catalogRefs(record))
    local random = PokegearRandom.new(13)
    local candidate = preparePurchases(state:revision(), {
      state = state,
      balance = 3000,
      previousBalance = 2900,
      claimed = {
        ["item-0"] = true,
        ["item-1"] = true,
        ["item-2"] = true,
        ["item-3"] = true,
        ["item-4"] = true,
        ["item-5"] = true,
        ["item-6"] = true,
        ["item-7"] = true,
        ["item-8"] = true,
      },
      random = random,
    })
    candidate.publish()
    local mom = state:readPhone().mom --[[@as table]]
    Assert.equal(#mom.gifts, 1, "only the berry fallback enqueues when normals are claimed")
    local berry = mom.gifts[1]
    Assert.equal(berry.quantity, 5, "the fallback berry comes in quantity five")
    Assert.equal(mom.balance, 3000 - 100, "the fallback berry costs 100")
    local expectedIndex = PokegearRandom.new(13):lc("mom-berry") % 17
    Assert.equal(berry.item, SOURCE_BERRIES[expectedIndex + 1], "the berry is the labelled native choice")
  end

  -- A valid pre-native v9 save may contain the old item-threshold claim.
  -- It still suppresses the corresponding native purchase after migration.
  do
    local state = PokegearState.new({ seed = 130 }, catalogRefs(record))
    local candidate = preparePurchases(state:revision(), {
      state = state,
      balance = 1000,
      previousBalance = 800,
      claimed = { ["custom.super-potion-900"] = true },
    })
    candidate.publish()
    local mom = state:readPhone().mom --[[@as table]]
    Assert.equal(#mom.gifts, 0, "a prior v9 claim is not earned a second time")
    Assert.equal(mom.balance, 1000, "a prior v9 claim does not spend savings again")
  end

  -- The complete source berry vector resolves before publication can draw;
  -- a bad catalog leaves the deterministic stream untouched.
  do
    local state = PokegearState.new({ seed = 131 }, catalogRefs(record))
    local random = PokegearRandom.new(131)
    local claimed = {}
    for index = 0, 8 do
      claimed["item-" .. tostring(index)] = true
    end
    local itemCatalog = {
      itemKeyByNativeId = function(_, nativeId)
        assert(nativeId ~= 165, "the catalog omits the last source berry")
        return TEST_ITEM_CATALOG:itemKeyByNativeId(nativeId)
      end,
    }
    local before = random:capture()
    local ok = pcall(function()
      preparePurchases(state:revision(), {
        state = state,
        balance = 3000,
        previousBalance = 2900,
        claimed = claimed,
        random = random,
        itemCatalog = itemCatalog,
      })
    end)
    Assert.isFalse(ok, "an invalid source berry rejects candidate preparation")
    Assert.deepEqual(random:capture(), before, "invalid item identity consumes no random draw")
  end

  -- The production battle candidate validates the complete berry vector
  -- before any eventual publication draw and rejects stale draws first.
  do
    local claimed = {}
    for index = 0, 8 do
      claimed["item-" .. tostring(index)] = true
    end
    local state = PokegearState.new({ seed = 132 }, catalogRefs(record))
    state:setMom({ balance = 0, purchases = claimed, gifts = {} })
    local random = PokegearRandom.new(132)
    local invalidCatalog = {
      itemKeyByNativeId = function(_, nativeId)
        assert(nativeId ~= 165, "the catalog omits the final battle berry")
        return TEST_ITEM_CATALOG:itemKeyByNativeId(nativeId)
      end,
    }
    local before = random:capture()
    local ok = pcall(function()
      prepareBattle({
        state = state,
        beforePlayer = 0,
        afterPlayer = 12000,
        momBalance = 0,
        battleKind = "trainer",
        outcomeId = "invalid-battle-berry",
        random = random,
        itemCatalog = invalidCatalog,
      }, state:revision())
    end)
    Assert.isFalse(ok, "invalid battle berry identity rejects preparation")
    Assert.deepEqual(random:capture(), before, "invalid battle berry identity consumes no random draw")

    local staleState = PokegearState.new({ seed = 133 }, catalogRefs(record))
    staleState:setMom({ balance = 0, purchases = claimed, gifts = {} })
    local staleRandom = PokegearRandom.new(133)
    local candidate = prepareBattle({
      state = staleState,
      beforePlayer = 0,
      afterPlayer = 12000,
      momBalance = 0,
      battleKind = "trainer",
      outcomeId = "stale-battle-berry",
      random = staleRandom,
    }, staleState:revision())
    local staleBefore = staleRandom:capture()
    staleState:setTrigger("gear.trigger.test", true)
    Assert.throws(function()
      candidate.publish()
    end, "stale battle berry candidate is rejected")
    Assert.deepEqual(staleRandom:capture(), staleBefore, "stale battle candidate consumes no random draw")
  end

  -- The dequeue candidate only advances the FIFO; the source Bag give is
  -- owned by the interpreted script between peek and take.
  do
    local state = PokegearState.new({ seed = 14 }, catalogRefs(record))
    local stock = preparePurchases(state:revision(), {
      state = state,
      balance = 950,
      previousBalance = 800,
      random = PokegearRandom.new(14),
    })
    stock.publish()
    Assert.equal(
      (state:readPhone().mom --[[@as table]]).gifts[1].item,
      "SUPER_POTION",
      "the source purchase stages the pending gift through the real queue"
    )
    local collect = PhoneRewards.prepareCollection(state:revision(), {
      state = state,
      gift = { item = "SUPER_POTION", quantity = 1 },
    })
    collect.publish()
    local cleared = state:readPhone().mom --[[@as table]]
    Assert.equal(#cleared.gifts, 0, "the source dequeue clears the pending gift once")
    Assert.throws(function()
      PhoneRewards.prepareCollection(
        state:revision(),
        { state = state, gift = { item = "SUPER_POTION", quantity = 1 } }
      )
    end, "a duplicate source dequeue finds no matching head")
  end
end

-- Malformed requests never take the call lease: unknown and unacquired
-- contacts fail with attribution, unknown directions and kinds fail,
-- a second call while one is live fails, and stale handles fail on
-- every operation without touching a new call.
function T.tests.phone_call_rejects_malformed_requests_without_taking_the_lease()
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")

  local state = PokegearState.new({ seed = 21 }, catalogRefs(record))
  state:registerContact("custom.trainer-plain")
  local world = {
    flags = {},
    rematchReady = {},
    canCall = function()
      return true
    end,
  }
  local call = PhoneCall.new({
    state = state,
    catalog = record.catalog,
    messages = phoneMessages(),
    world = world,
    audio = instantAudio(),
    random = PokegearRandom.new(21),
  })

  local unknown = Assert.throws(function()
    call:begin({ id = "bad-1", contact = "custom.unknown", direction = "outgoing", kind = "ordinary" })
  end, "an unknown contact never takes the lease")
  Assert.equal((unknown --[[@as table]]).domain, "phone", "the unknown contact names the phone domain")
  local unacquired = Assert.throws(function()
    call:begin({ id = "bad-2", contact = "custom.kurt", direction = "outgoing", kind = "ordinary" })
  end, "an unacquired contact never takes the lease")
  Assert.equal((unacquired --[[@as table]]).domain, "phone", "the unacquired contact names the phone domain")
  Assert.throws(function()
    call:begin({ id = "bad-3", contact = "custom.trainer-plain", direction = "sideways", kind = "ordinary" })
  end, "an unknown direction never takes the lease")
  Assert.throws(function()
    call:begin({ id = "bad-4", contact = "custom.trainer-plain", direction = "outgoing", kind = "chat" })
  end, "an unknown call kind never takes the lease")

  -- The rejected requests left the line free: a valid call still opens,
  -- and a second live call still fails exactly once.
  local first = call:begin({
    id = "good-1",
    contact = "custom.trainer-plain",
    direction = "outgoing",
    kind = "ordinary",
  })
  Assert.throws(function()
    call:begin({ id = "good-2", contact = "custom.trainer-plain", direction = "outgoing", kind = "ordinary" })
  end, "one foreground call owns the line")
  call:cancel(first, "hangup")
  local second = call:begin({
    id = "good-2",
    contact = "custom.trainer-plain",
    direction = "outgoing",
    kind = "ordinary",
  })
  Assert.equal(second.id, "good-2", "the released line opens again with its stable id")

  -- Stale handles fail on every operation without acting on a new call.
  local ghost = { id = "ghost" }
  Assert.throws(function()
    call:step(ghost, {})
  end, "a stale step never runs")
  Assert.throws(function()
    call:view(ghost)
  end, "a stale view never reads")
  Assert.throws(function()
    call:result(ghost)
  end, "a stale result never reports")
  Assert.throws(function()
    call:cancel(ghost, "hangup")
  end, "a stale cancel never hangs up")
end

-- Every selector early return resolves in source order: each decisive
-- fact selects its own program, flipping it falls through, and higher
-- branches win over lower ones. Pure dispatch with no draws.
function T.tests.selectors_resolve_every_family_branch_in_source_order()
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")

  ---@param family string
  ---@param facts table<string, unknown>
  ---@param program string
  ---@param why string
  local function check(family, facts, program, why)
    Assert.equal(PhoneCall.selectProgram(family, facts), program, why)
  end

  local elmCases = {
    { { predefinedScript = "elm-intro" }, "elm-predefined" },
    { { incomingCall = true }, "elm-incoming" },
    { { localMap = true }, "elm-local-map" },
    { { panicCall = true }, "elm-panic" },
    { { rivalUnnamed = true }, "elm-rival" },
    { { eggEvent = true }, "elm-egg" },
    { { eggGift = true }, "elm-gift" },
    { { eggHatched = true }, "elm-hatch" },
    { { everstone = true }, "elm-everstone" },
    { { rockets = true }, "elm-rockets" },
    { { badges = 8, rockets = false }, "elm-early" },
    { { gameClear = true }, "elm-clear" },
    { { ssTicket = true }, "elm-ticket" },
    { { pokerus = true }, "elm-pokerus" },
    { {}, "elm-early" },
  }
  for _, case in ipairs(elmCases) do
    check("elm", case[1], case[2], "elm resolves " .. case[2])
  end
  check(
    "elm-predefined",
    { predefinedScript = "elm-intro" },
    "elm-predefined",
    "the predefined family keeps its script"
  )
  -- Higher branches win: each pair proves the order, not just the hit.
  check("elm", { localMap = true, panicCall = true }, "elm-local-map", "the local map precedes the panic call")
  check("elm", { localMap = false, panicCall = true }, "elm-panic", "a false local map falls through to panic")
  check("elm", { eggEvent = true, eggGift = true }, "elm-egg", "the egg call precedes its gift state")
  check("elm", { badges = 3, rockets = true }, "elm-rockets", "rockets precede the badge default")
  check("elm", { gameClear = true, pokerus = true }, "elm-clear", "the clear state precedes pokerus")
  check("elm", { ssTicket = true, pokerus = true }, "elm-ticket", "the ticket precedes pokerus")

  check("oak", { excluded = true, dexSeen = 100 }, "oak-deferred", "oak exclusions defer first")
  check(
    "oak",
    { nationalDex = true, dexSeen = 5 },
    "oak-national-evaluation",
    "the national choice precedes the seen count"
  )
  check("oak", { dexSeen = 10, dexCaught = 5 }, "oak-evaluation", "the seen count evaluates")
  check("oak", {}, "oak-intro", "no dex knowledge introduces")

  check("mother", { giftPending = true, savingsChoice = true }, "mother-gift", "the pending gift announces first")
  check("mother", { savingsChoice = true }, "mother-savings", "the savings choice banks")
  check("mother", { savingsChoice = false }, "mother-offer", "an unset choice offers")
  check("mother", {}, "mother-greeting", "no facts greet")

  check("generic", { storyCall = "x", weekday = "monday" }, "generic-story", "the story call precedes weekday gates")
  check("generic", { contest = true, weekday = "monday" }, "generic-contest", "the contest gate precedes weekday gates")
  check("generic", { weekday = "monday", hour = 9 }, "generic-weekday", "the weekday gate resolves")
  check("generic", { repeatCall = true }, "generic-repeat", "repeat history resolves")
  check("generic", {}, "generic-greeting", "no gates greet")

  check("gym", { weekday = "saturday", morning = true }, "gym-rematch", "the source window invites")
  check("gym", { weekday = "sunday", morning = true }, "gym-waiting", "a wrong weekday waits")
  check("gym", { weekday = "saturday", morning = false }, "gym-waiting", "a wrong half waits")
  check(
    "gym",
    { window = { weekday = "friday", morning = false }, weekday = "friday", morning = false },
    "gym-rematch",
    "a recorded window invites on its own terms"
  )

  check("bill", { acknowledged = true, pcFreeSlots = 5 }, "bill-greeting", "an acknowledgement needs no capacity read")
  check("bill", { pcFreeSlots = 0 }, "bill-full", "a full box reports full")
  check("bill", { pcFreeSlots = 5 }, "bill-advice", "free slots advise")
  check("bill", {}, "bill-greeting", "no box facts greet")
  check("buena", { takeover = true, passwordKnown = true }, "buena-closed", "the takeover closes first")
  check("buena", { passwordKnown = true }, "buena-reward", "the known password rewards")
  check("buena", { blueCard = true }, "buena-password", "the blue card asks for the password")
  check("buena", {}, "buena-greeting", "no card facts greet")

  check("trainer", { invitation = true }, "trainer-rematch", "the invitation program invites")
  check("trainer", {}, "trainer-ordinary", "no invitation stays ordinary")
  check("kenji", { kenjiActive = true }, "kenji-active", "the active errand reports active")
  check("kenji", { waitExpired = true }, "kenji-ready", "the expired wait reports ready")
  check("kenji", {}, "kenji-waiting", "no wait keeps waiting")
  check("irwin", { storyEvent = true }, "irwin-story", "the story event reacts")
  check("irwin", {}, "irwin-greeting", "no event greets")
  check("kurt", { aboutProduction = true }, "kurt-production", "the production question produces")
  check("kurt", {}, "kurt-greeting", "no question greets locally")
  check("daycare", { aboutEgg = true }, "daycare-egg", "the egg question answers")
  check("daycare", {}, "daycare-greeting", "no question greets locally")
  check("bike", { acknowledged = true }, "bike-greeting", "an acknowledgement greets")
  check("bike", { hasBicycle = true }, "bike-owned", "an owned bicycle reports owned")
  check("bike", {}, "bike-offer", "no bicycle offers")
  check("friend", { subject = "swarm" }, "friend-topic", "a subject discusses")
  check("friend", {}, "friend-greeting", "no subject greets")
  check("baoba", { safariTest = true }, "baoba-test", "the safari test reports")
  check("baoba", {}, "baoba-greeting", "no test greets locally")
end

-- Stale and replayed candidates change no owner: a revision move
-- between preparation and publication fails the purchase, a second
-- collection of the same gift finds nothing pending, and a chained
-- pass reuses recorded purchase flags instead of rebuying.
function T.tests.savings_candidates_reject_stale_and_replayed_publication()
  local PhoneRewards = require("game.hgss.src.pokegear.PhoneRewards")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")

  -- A revision move between preparation and publication fails before
  -- any write: balances, queues, and flags stay exactly as recorded.
  do
    local state = PokegearState.new({ seed = 41 }, catalogRefs(record))
    local candidate = preparePurchases(state:revision(), {
      state = state,
      balance = 950,
      previousBalance = 800,
      random = PokegearRandom.new(41),
    })
    local before = state:readPhone().mom --[[@as table]]
    state:registerContact("custom.mom")
    Assert.throws(function()
      candidate.publish()
    end, "a stale purchase publishes nothing")
    Assert.deepEqual(state:readPhone().mom, before, "the stale purchase leaves savings exactly as recorded")
  end

  -- Staging a berry draw never advances it; a stale revision is rejected
  -- before publication can consume that draw.
  do
    local state = PokegearState.new({ seed = 410 }, catalogRefs(record))
    local random = PokegearRandom.new(410)
    local claimed = {}
    for index = 0, 8 do
      claimed["item-" .. tostring(index)] = true
    end
    local candidate = preparePurchases(state:revision(), {
      state = state,
      balance = 3000,
      previousBalance = 2900,
      claimed = claimed,
      random = random,
    })
    local before = random:capture()
    state:registerContact("custom.mom")
    Assert.throws(function()
      candidate.publish()
    end, "a stale berry candidate publishes nothing")
    Assert.deepEqual(random:capture(), before, "a stale berry candidate consumes no random draw")
  end

  -- A collected gift cannot be collected twice: the retry finds no
  -- matching pending entry at preparation, so no inventory duplicates.
  do
    local state = PokegearState.new({ seed = 42 }, catalogRefs(record))
    local stock = preparePurchases(state:revision(), {
      state = state,
      balance = 950,
      previousBalance = 800,
      random = PokegearRandom.new(42),
    })
    stock.publish()
    local collect = PhoneRewards.prepareCollection(state:revision(), {
      state = state,
      gift = { item = "SUPER_POTION", quantity = 1 },
    })
    collect.publish()
    Assert.throws(function()
      PhoneRewards.prepareCollection(state:revision(), {
        state = state,
        gift = { item = "SUPER_POTION", quantity = 1 },
      })
    end, "a repeated collection finds nothing pending")
    Assert.equal(#(state:readPhone().mom --[[@as table]]).gifts, 0, "the collected queue stays empty")
  end

  -- A chained pass buys only newly crossed thresholds: recorded flags
  -- survive in the companion record and never rebuy.
  do
    local state = PokegearState.new({ seed = 43 }, catalogRefs(record))
    local first = preparePurchases(state:revision(), {
      state = state,
      balance = 950,
      previousBalance = 800,
      random = PokegearRandom.new(43),
    })
    first.publish()
    local chained = preparePurchases(state:revision(), {
      state = state,
      balance = 4500,
      previousBalance = 950,
      random = PokegearRandom.new(44),
    })
    chained.publish()
    local mom = state:readPhone().mom --[[@as table]]
    Assert.equal(#mom.gifts, 2, "the chained pass enqueues only the new threshold")
    Assert.equal(mom.gifts[1].item, "SUPER_POTION", "the first purchase stays first")
    Assert.equal(mom.gifts[2].item, "REPEL", "the chained pass buys the repel")
    Assert.equal(mom.balance, 4500 - 270, "the chained pass spends only its own cost")
    Assert.isTrue(mom.purchases["item-0"] == true, "the first source slot flag survives")
    Assert.isTrue(mom.purchases["item-1"] == true, "the next source slot flag records")
  end
end

-- Thresholds and berry tiers hold on both sides: the crossed threshold
-- buys inclusively, an already crossed one never rebuys, and the
-- resistance berry fires only on a fresh floor(balance/3000) tier with
-- its labelled draw.
function T.tests.purchase_thresholds_and_berry_tiers_hold_on_both_sides()
  local PhoneRewards = require("game.hgss.src.pokegear.PhoneRewards")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")

  ---@param seed integer
  ---@param balance integer
  ---@param previousBalance integer
  ---@return table mom record after publication
  local function apply(seed, balance, previousBalance)
    local state = PokegearState.new({ seed = seed }, catalogRefs(record))
    local claimed = {}
    for _, entry in ipairs(SOURCE_PURCHASES) do
      if entry.threshold <= previousBalance then
        claimed["item-" .. tostring(entry.sourceIndex)] = true
      end
    end
    local candidate = preparePurchases(state:revision(), {
      state = state,
      balance = balance,
      previousBalance = previousBalance,
      claimed = claimed,
      random = PokegearRandom.new(seed),
    })
    candidate.publish()
    return state:readPhone().mom --[[@as table]]
  end

  local edge = apply(51, 900, 899)
  Assert.equal(#edge.gifts, 1, "landing exactly on the threshold buys")
  Assert.equal(edge.gifts[1].item, "SUPER_POTION", "the edge purchase is the super potion")

  local recross = apply(52, 950, 900)
  Assert.equal(#recross.gifts, 0, "an already crossed threshold never rebuys")
  Assert.equal(recross.balance, 950, "a pass with no purchase spends nothing")

  local belowTier = apply(53, 2999, 2998)
  Assert.equal(#belowTier.gifts, 0, "staying inside the tier buys no berry")

  local crossTier = apply(54, 3000, 2999)
  Assert.equal(#crossTier.gifts, 1, "crossing into a fresh tier buys the berry fallback")
  local expectedIndex = PokegearRandom.new(54):lc("mom-berry") % 17
  Assert.equal(
    crossTier.gifts[1].item,
    SOURCE_BERRIES[expectedIndex + 1],
    "the tier berry is selected from the native source vector"
  )
  Assert.equal(crossTier.gifts[1].quantity, 5, "the tier berry comes in quantity five")
  Assert.equal(crossTier.balance, 3000 - 100, "the tier berry costs 100")

  local state = PokegearState.new({ seed = 55 }, catalogRefs(record))
  local candidate = preparePurchases(state:revision(), {
    state = state,
    balance = 950,
    previousBalance = 800,
    random = PokegearRandom.new(55),
  })
  candidate.publish()
  Assert.equal(
    (state:readPhone().triggers --[[@as table]])["gear.trigger.12"],
    true,
    "an enqueued purchase sets the gift call trigger"
  )
end

-- Absent owners fail with attribution while present owners reporting
-- zero answer normally: box capacity zero is a fact, a missing box
-- owner is a dependency failure, and an unset savings choice reads as
-- nil instead of a fabricated answer.
function T.tests.world_reads_distinguish_absent_owners_from_zero_counts()
  local PhoneWorldContext = require("game.hgss.src.pokegear.PhoneWorldContext")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local FieldEventState = require("libs.hgss.src.field.FieldEventState")
  local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

  local state = PokegearState.new({ seed = 61 }, catalogRefs(record))
  local bare = PhoneWorldContext.new({ state = state })

  local kurtErr = Assert.throws(function()
    bare:read("kurt.production")
  end, "absent Kurt production fails")
  Assert.equal((kurtErr --[[@as table]]).domain, "kurt", "the Kurt failure names kurt")

  local pcErr = Assert.throws(function()
    bare:read("bill.pc-free")
  end, "absent box capacity fails")
  Assert.equal((pcErr --[[@as table]]).domain, "pc", "the box failure names pc")

  local flagsErr = Assert.throws(function()
    PhoneWorldContext.new({ state = state }):read("mom.savings-choice")
  end, "an absent flag owner fails")
  Assert.equal((flagsErr --[[@as table]]).domain, "flags", "the flag failure names flags")

  local dexErr = Assert.throws(function()
    bare:read("dex.seen")
  end, "absent Dex knowledge fails")
  Assert.equal((dexErr --[[@as table]]).domain, "dex", "the dex failure names dex")

  -- Present owners answer, including zero and false: those are facts,
  -- not missing dependencies.
  local stocked = PhoneWorldContext.new({ state = state, flags = FieldEventState.new(), pc = { freeSlots = 0 } })
  Assert.equal(stocked:read("bill.pc-free"), 0, "a full box reports zero free slots")
  Assert.isFalse(stocked:read("mom.savings-choice"), "the clear native flag reports savings disabled")
  stocked:setMomSavingsChoice(true)
  Assert.isTrue(stocked:read("mom.savings-choice"), "an accepted choice reads the native flag")
  Assert.isTrue(
    FieldEventState.new({ flags = { [FieldScriptSymbols.flagsByName.FLAG_SYS_MOMS_SAVINGS] = true } })
      :isFlagSet(FieldScriptSymbols.flagsByName.FLAG_SYS_MOMS_SAVINGS),
    "the native savings symbol resolves to an event flag"
  )
  local dex = PhoneWorldContext.new({
    state = state,
    flags = FieldEventState.new(),
    dex = {
      bucket = function()
        return { seen = { "custom.cyndaquil" }, caught = {} }
      end,
    },
  })
  Assert.equal(dex:read("dex.seen"), 1, "present Dex knowledge reads its live count")
end

-- A service stage without its owner fails before any effect: the call
-- ends with attribution, staged world facts stay untouched, no trigger
-- is set, and the released line opens again. A local branch needing no
-- owner still completes on the same contact.
function T.tests.service_stage_without_its_owner_fails_before_any_effect()
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")

  local state = PokegearState.new({ seed = 71 }, catalogRefs(record))
  state:registerContact("custom.kurt")
  local world = {
    flags = {},
    rematchReady = {},
    canCall = function()
      return true
    end,
    aboutProduction = true,
    nativeSelectorFacts = localPhoneSelectorFacts(),
  }
  local call = PhoneCall.new({
    state = state,
    catalog = record.catalog,
    messages = phoneMessages(),
    world = world,
    audio = instantAudio(),
    random = PokegearRandom.new(71),
  })
  local handle = call:begin({
    id = "kurt-1",
    contact = "custom.kurt",
    direction = "outgoing",
    kind = "ordinary",
  })
  call:step(handle, {})
  call:step(handle, {})
  call:step(handle, { advance = true })
  local failed = call:result(handle)
  Assert.notNil(failed, "the unavailable source owner returns a terminal result")
  local failure = (failed --[[@as table]]).error --[[@as table]]
  Assert.equal(failure.code, "FEATURE_UNAVAILABLE", "only typed feature failures become terminal results")
  Assert.equal(failure.domain, "kurt", "the failure names the missing kurt domain")
  Assert.isNil(world.rematchReady["custom.kurt"], "the failed stage stages no readiness")
  Assert.deepEqual(state:readPhone().triggers, {}, "the failed stage sets no trigger")

  -- The failed call released the line: a local branch on the same
  -- contact completes without any production owner.
  world.aboutProduction = nil
  local localHandle = call:begin({
    id = "kurt-2",
    contact = "custom.kurt",
    direction = "outgoing",
    kind = "ordinary",
  })
  call:step(localHandle, {})
  call:step(localHandle, {})
  call:step(localHandle, { advance = true })
  local done = call:result(localHandle)
  Assert.notNil(done, "the local branch completes without the owner")
  Assert.isNil((done --[[@as table]]).error, "the local branch carries no failure")
end

-- The battle committer settles companion savings exactly once: the
-- named preparation validates before any swap, publishes with the
-- batch under the outcome receipt, and a repeated commit reuses the
-- receipt instead of banking twice. A stale candidate fails preparation
-- with no owner touched.
function T.tests.battle_publication_settles_companion_savings_exactly_once()
  local PhoneRewards = require("game.hgss.src.pokegear.PhoneRewards")
  local HgssBattleCommitter = require("libs.hgss.src.battle.HgssBattleCommitter")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = require("libs.hgss.src.save.PokegearState")

  local state = PokegearState.new({ seed = 81 }, catalogRefs(record))
  local candidate = prepareBattle({
    state = state,
    beforePlayer = 1000,
    afterPlayer = 1500,
    momBalance = 0,
    battleKind = "trainer",
    outcomeId = "pokegear-commit-1",
  }, state:revision())
  local prepared = HgssBattleCommitter.prepare({
    outcome = { id = "pokegear-commit-1", result = "win" },
    pokegear = candidate,
  })
  local receipt = HgssBattleCommitter.commit(prepared)
  Assert.isTrue(receipt.committed, "the batch commits")
  Assert.equal((receipt.pokegear --[[@as table]]).transfer, 125, "the receipt carries the staged transfer")
  Assert.equal((state:readPhone().mom --[[@as table]]).balance, 125, "the commit banks the transfer")
  local replay = HgssBattleCommitter.commit(prepared)
  Assert.isTrue(replay == receipt, "a repeated commit reuses the recorded receipt")
  Assert.equal((state:readPhone().mom --[[@as table]]).balance, 125, "the replay banks nothing twice")

  local stale = prepareBattle({
    state = state,
    beforePlayer = 1000,
    afterPlayer = 1500,
    momBalance = 0,
    battleKind = "trainer",
    outcomeId = "pokegear-commit-stale",
  }, state:revision())
  state:registerContact("custom.mom")
  Assert.throws(function()
    HgssBattleCommitter.prepare({
      outcome = { id = "pokegear-commit-stale", result = "win" },
      pokegear = stale,
    })
  end, "a stale savings candidate fails preparation")
  Assert.equal((state:readPhone().mom --[[@as table]]).balance, 125, "the failed preparation moves no savings")
end

-- A won trainer battle commits Mom savings atomically with the prize:
-- the player keeps the gain minus the transferred quarter share, the
-- savings bank the share, and the receipt carries both candidates.
function T.tests.trainer_win_commits_mom_savings_with_the_prize()
  local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local MonsSave = require("libs.mons.src.MonsSave")
  local Party = require("libs.mons.src.Party")
  local Lcrng = require("libs.mons.src.gen4.Lcrng")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = require("libs.hgss.src.save.PokegearState")

  local catalog = CatalogFixture.makeCatalog()
  local foe = CatalogFixture.makeFactory(0x5EED0001, catalog)
    :createNormal(CatalogFixture.normalRequest({ species = "TOTODILE", level = 4 }))
  foe.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  local owner = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x22222222):capture()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = 7,
    date = CatalogFixture.metDate(),
  })
  local lead = CatalogFixture.makeFactory(0x33333333, catalog)
    :createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA", level = 5 }))
  lead.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  Assert.isTrue(owner:addMon(lead), "the prize battle needs its live party lead")
  local playerRecord = {
    profile = {
      name = "RED",
      gender = 0,
      trainerId = 1,
      money = 3000,
      badges = 0,
      nationalDex = false,
      runningShoes = false,
      runningShoesLock = false,
    },
    options = { textFrame = 0, textSpeed = "fastest" },
  }
  local playerContext = { charmap = CatalogFixture.CHARMAP, frameIndexes = { [0] = true } }
  local trainers = {
    {
      id = "rival-early",
      class = 2,
      party = { foe },
      partyLevels = { 4 },
      prizeMoney = { trainerClass = 2, classRate = 4 },
      program = { key = "rival_opening", revision = "native-1", instructions = {}, entryPoints = {} },
      aiPasses = {},
    },
  }
  local scenario = ScenarioFactory.fromTrainer(
    { id = "trainer-prize-mom", trainers = trainers },
    { party = owner, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local pokegearState = PokegearState.new({ seed = 82 }, catalogRefs(record))
  local battle = BattleRuntime.new({
    request = { id = "launch-mom-settlement", kind = "trainer", payload = { trainer = "rival-early" } },
    scenario = scenario,
    party = owner,
    player = { record = playerRecord, context = playerContext },
    pokegear = {
      state = pokegearState,
      random = require("game.hgss.src.pokegear.PokegearRandom").new(82),
      itemCatalog = TEST_ITEM_CATALOG,
      momPurchases = sourceMomPurchases(),
    },
  })
  local claimed = {} ---@type table<integer, boolean>
  local ticks = 0
  while battle:status().phase ~= "complete" and battle:status().phase ~= "failed" and ticks < 1200 do
    battle:update()
    local current = battle:status()
    if current.phase == "running" and current.request ~= nil then
      local kinds = {}
      if current.request.legalChoices ~= nil then
        kinds = current.request.legalChoices.kinds
      end
      local admitsSwitch = false
      local admitsAttack = false
      for _, kind in ipairs(kinds) do
        if kind == "switch" then
          admitsSwitch = true
        end
        if kind == "attack" then
          admitsAttack = true
        end
      end
      local choices = {}
      for _, actor in ipairs(assert(current.request.actors, "a decision request names its actors")) do
        if admitsSwitch and not admitsAttack then
          local choiceId = nil
          for _, seed in ipairs(scenario.participants[1].roster) do
            local id = (seed --[[@as table<string, unknown>]]).id --[[@as integer]]
            if id ~= actor.combatant and not claimed[id] then
              claimed[id] = true
              choiceId = id
              break
            end
          end
          choices[#choices + 1] =
            SessionFixture.switchChoice(actor, assert(choiceId, "the replacement needs a reserve"))
        else
          choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
        end
      end
      local accepted = battle:submit(SessionFixture.replyFor(current.request, choices))
      Assert.isTrue(accepted, "a legal decision is accepted")
    end
    ticks = ticks + 1
  end
  local finalStatus = battle:status()
  Assert.equal(
    finalStatus.phase,
    "complete",
    "answered decisions finish the trainer battle: "
      .. tostring(finalStatus.error or finalStatus.failure or finalStatus.reason)
  )
  Assert.equal(battle:status().result, "win", "a fainted enemy side reports the win")
  local receipt = assert(battle:status().outcomeReceipt, "completion carries its commit receipt")
  -- Class 2 pays rate 4 at final level 4: a prize of 64, quartered to
  -- 16 for savings, leaving the player 48 of the gain.
  Assert.equal(receipt.rewards.amount, 64, "the prize follows the native class rate and final level")
  Assert.equal(receipt.player.profile.money, 3048, "the player keeps the gain minus the transferred share")
  Assert.equal((receipt.pokegear --[[@as table]]).transfer, 16, "the receipt carries the staged transfer")
  Assert.equal((pokegearState:readPhone().mom --[[@as table]]).balance, 16, "the commit banks the share")
  Assert.equal(playerRecord.profile.money, 3000, "staging never touches the input record")
  battle:dispose()
end

-- Staged savings survive the companion owner: a settled, purchased, and
-- collected savings record captures and restores with its balance,
-- queue, claimed flags, and gift trigger intact.
function T.tests.staged_savings_states_restore_through_the_companion_owner()
  local PhoneRewards = require("game.hgss.src.pokegear.PhoneRewards")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")

  local state = PokegearState.new({ seed = 91 }, catalogRefs(record))
  local settlement = prepareBattle({
    state = state,
    beforePlayer = 1000,
    afterPlayer = 1500,
    momBalance = 0,
    battleKind = "trainer",
    outcomeId = "win-restore",
  }, state:revision())
  settlement.publish()
  local stock = preparePurchases(state:revision(), {
    state = state,
    balance = 950,
    previousBalance = 800,
    random = PokegearRandom.new(91),
  })
  stock.publish()
  local collect = PhoneRewards.prepareCollection(state:revision(), {
    state = state,
    gift = { item = "SUPER_POTION", quantity = 1 },
  })
  collect.publish()
  local revived = PokegearState.restore(state:capture(), catalogRefs(record))
  local mom = revived:readPhone().mom --[[@as table]]
  Assert.equal(mom.balance, 350, "the restored balance keeps the settled purchase cost")
  Assert.deepEqual(mom.gifts, {}, "the restored queue keeps the collection")
  Assert.isTrue(mom.purchases["item-0"] == true, "the restored flags keep the source claim")
  Assert.equal(revived:readPhone().triggers["gear.trigger.12"], true, "the restored triggers keep the gift call")
end

-- Native-shaped contact keys dispatch through their generated family:
-- every key below carries the shared native trainer-key shape, so only
-- the stamped family (never a key substring) may select the program.
-- An unstamped family fails with attribution instead of guessing.
function T.tests.native_shaped_contact_keys_dispatch_through_their_generated_family()
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
  local catalog = {
    contacts = {
      { key = "hg.trainer.200.map.0.contact.0", family = "mother" },
      { key = "hg.trainer.201.map.0.contact.1", family = "elm" },
      { key = "hg.trainer.202.map.0.contact.10", family = "trainer" },
      { key = "hg.trainer.203.map.0.contact.17", family = "gym" },
      { key = "hg.trainer.204.map.0.contact.99", family = "bogus" },
    },
    contactOrder = {
      "hg.trainer.200.map.0.contact.0",
      "hg.trainer.201.map.0.contact.1",
      "hg.trainer.202.map.0.contact.10",
      "hg.trainer.203.map.0.contact.17",
      "hg.trainer.204.map.0.contact.99",
    },
    locations = {},
  }
  local state = PokegearState.new({ seed = 77 }, { catalog = catalog })
  for _, contact in ipairs(catalog.contacts) do
    state:registerContact((contact --[[@as table]]).key)
  end
  local world = {
    flags = {},
    rematchReady = {},
    canCall = function()
      return true
    end,
  }
  local call = PhoneCall.new({
    state = state,
    catalog = catalog,
    messages = phoneMessages(),
    world = world,
    audio = instantAudio(),
    random = PokegearRandom.new(77),
  })
  world.nativeSelectorFacts = localPhoneSelectorFacts()
  local expected = {
    ["hg.trainer.200.map.0.contact.0"] = "mother-greeting",
    ["hg.trainer.201.map.0.contact.1"] = "elm-early",
  }
  local id = 0
  for contactKey, program in pairs(expected) do
    id = id + 1
    local handle = call:begin({ id = "native-" .. id, contact = contactKey, direction = "outgoing", kind = "ordinary" })
    call:step(handle, {})
    call:step(handle, {})
    call:step(handle, { advance = true })
    Assert.equal(
      (call:view(handle) --[[@as table]]).program,
      program,
      contactKey .. " runs its generated family program"
    )
    call:release(handle)
  end
  local unmapped = Assert.throws(function()
    call:begin({
      id = "native-bogus",
      contact = "hg.trainer.204.map.0.contact.99",
      direction = "outgoing",
      kind = "ordinary",
    })
  end, "an unstamped family never takes the lease")
  Assert.equal((unmapped --[[@as table]]).domain, "phone", "the unstamped family names the phone domain")
end

return T
