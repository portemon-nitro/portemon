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
    schema = "g4-pokegear-assets-v3",
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
        { key = "custom.friend", family = "friend", sortWeight = 35 },
        { key = "custom.bill", family = "bill", sortWeight = 37 },
        { key = "custom.daycare-lady", family = "daycare", sortWeight = 40 },
        { key = "custom.leader-falkner", family = "gym", sortWeight = 50 },
      },
      contactOrder = {
        "custom.mom",
        "custom.trainer-plain",
        "custom.kurt",
        "custom.friend",
        "custom.bill",
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
  local flags = {
    isFlagSet = function()
      return false
    end,
  }
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

function T.tests.phone_world_context_reads_native_gym_and_oak_call_entry_facts()
  local PhoneWorldContext = require("game.hgss.src.pokegear.PhoneWorldContext")
  local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
  local values = {
    [FieldScriptSymbols.flagsByName.FLAG_SYS_OAK_ACKNOWLEDGED_JOHTO_DEX_COMPLETION] = true,
    [FieldScriptSymbols.flagsByName.FLAG_SYS_OAK_ACKNOWLEDGED_NATIONAL_DEX_COMPLETION] = false,
  }
  local flags = {
    isFlagSet = function(_, flag)
      return values[flag] == true
    end,
    setFlag = function(_, flag)
      values[flag] = true
    end,
  }
  local runtime = {
    session = { currentMap = { mapSectionNativeId = 12 } },
    playerData = { profile = { gender = 1, badges = 65535, nationalDex = true } },
    dexKnowledge = {
      bucket = function()
        return { seen = { "A", "B" }, caught = { "A" } }
      end,
      isNationalDexComplete = function()
        return false
      end,
    },
    localClock = {
      nowLocal = function()
        return { year = 2026, month = 10, day = 13, hour = 12 }
      end,
    },
  }
  local context = PhoneWorldContext.new({
    state = {
      queryRematch = function(_, key)
        Assert.equal(key, "gym.falkner", "gym seeking reads its registered contact")
        return { stage = 1, wins = 0 }
      end,
    },
    runtime = runtime,
    flags = flags,
    summaryDexNumbers = {
      A = { national = 1, regional = 1 },
      B = { national = 2, regional = 2 },
    },
  })
  local facts = context:callFacts({ map = 12, family = "oak" })

  Assert.equal(facts.badges, 16, "gym calls read the live badge count")
  Assert.equal(facts.playerGender, 1, "Oak calls read the live player gender")
  Assert.isTrue(facts.nationalDexUnlocked, "Oak calls read the National Dex unlock")
  Assert.equal(facts.nationalDexOwned, 1, "Oak calls read National Dex ownership")
  Assert.equal(facts.nationalDexSeen, 2, "Oak calls read National Dex seen count")
  Assert.equal(facts.johtoDexOwned, 1, "Oak calls read Johto Dex ownership")
  Assert.equal(facts.johtoDexSeen, 2, "Oak calls read Johto Dex seen count")
  Assert.isTrue(facts.acknowledgedJohto, "Oak calls read the Johto acknowledgment")
  Assert.isFalse(facts.acknowledgedNational, "Oak calls read the National acknowledgment")

  local gymFacts = context:callFacts({ key = "gym.falkner", family = "gym", map = 7 })
  Assert.isTrue(gymFacts.seeking, "gym calls read the durable active rematch stage")
  Assert.isTrue(gymFacts.dojoHasRoom, "the retail capacity loop permits the source invitation")

  context:setOakAcknowledged("national")
  Assert.isTrue(values[FieldScriptSymbols.flagsByName.FLAG_SYS_OAK_ACKNOWLEDGED_NATIONAL_DEX_COMPLETION])
end

function T.tests.phone_world_context_exposes_native_generic_pending_gift()
  local PhoneWorldContext = require("game.hgss.src.pokegear.PhoneWorldContext")
  local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
  local state = {
    readPhone = function()
      return { contacts = { ["trainer.joey"] = { reward = { item = "POTION", quantity = 1 } } } }
    end,
    queryRematch = function()
      return nil
    end,
  }
  local flags = {
    isFlagSet = function()
      return false
    end,
  }
  local context = PhoneWorldContext.new({
    state = state,
    flags = flags,
    runtime = { session = { currentMap = { mapSectionNativeId = 1 } } },
  })

  local facts = context:callFacts({ key = "trainer.joey", family = "trainer", map = 2 })

  Assert.isTrue(facts.pendingGenericGift, "generic native gift headers read the pending contact reward")
  Assert.equal(facts.radioTowerBeaten, false, "generic call facts retain the independent Rocket story state")
end

function T.tests.phone_world_context_applies_numeric_definition_effects_through_existing_owners()
  local PhoneWorldContext = require("game.hgss.src.pokegear.PhoneWorldContext")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local FieldEventState = require("libs.hgss.src.field.FieldEventState")
  local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "numeric-effect contact fixture validates")
  assert(record ~= nil, "numeric-effect contact fixture validated above")
  local state = PokegearState.new({ seed = 42 }, catalogRefs(record))
  state:registerContact("custom.trainer-plain")
  local events = FieldEventState.new()
  local context = PhoneWorldContext.new({
    state = state,
    flags = events,
    runtime = {
      itemCatalog = {
        itemKeyByNativeId = function(_, nativeId)
          return "NATIVE_ITEM_" .. nativeId
        end,
      },
    },
  })
  local random = {
    mt = function(_, _)
      return 3
    end,
    lc = function(_, _)
      return 1
    end,
  }

  local rematch = context:prepareCallDefinitionEffect("custom.trainer-plain", { kind = "rematch" }, random)
  Assert.isNil(state:queryRematch("custom.trainer-plain"), "preparing a numeric call leaves rematch state untouched")
  rematch.commit()
  local seeking = state:queryRematch("custom.trainer-plain")
  Assert.equal(seeking.stage, 1, "rematch definitions use persisted rematch state")
  local item = context:prepareCallDefinitionEffect("custom.trainer-plain", { kind = "item", param1 = 149 }, random)
  Assert.isNil(state:readPhone().contacts["custom.trainer-plain"].reward, "preparing a gift publishes no reward")
  item.commit()
  local reward = state:readPhone().contacts["custom.trainer-plain"].reward
  Assert.deepEqual(
    reward,
    { item = "NATIVE_ITEM_152", quantity = 1 },
    "item definitions map their source gift through the item catalog"
  )
  local flag = context:prepareCallDefinitionEffect(
    "custom.trainer-plain",
    { kind = "flag", param0 = 1, param1 = "FLAG_UNK_127" },
    random
  )
  Assert.isFalse(events:isFlagSet(FieldScriptSymbols.flagsByName.FLAG_UNK_127), "preparing a flag publishes no event")
  flag.commit()
  Assert.isTrue(events:isFlagSet(FieldScriptSymbols.flagsByName.FLAG_UNK_127), "flag definitions use the event owner")
  local word =
    context:prepareCallDefinitionEffect("custom.trainer-plain", { kind = "word", param0 = 4, param1 = 70 }, random)
  local substitutions = word.substitutions
  Assert.equal(substitutions.wordEntry, 71, "word definitions select one source entry through the LC stream")
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

function T.tests.phone_call_views_detach_native_pages_and_token_operands()
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic phone catalog validates before opening a call")
  assert(record ~= nil, "synthetic phone catalog validated above")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
  local state = PokegearState.new({ seed = 4243 }, catalogRefs(record))
  state:registerContact("custom.kurt")
  local resolves = 0
  local messages = {
    greeting = "custom.greeting",
    program = "custom.program",
    resolveLine = function()
      resolves = resolves + 1
      return {
        tokens = {
          { kind = "glyph", code = 1, text = "A", raw = { 1 }, metadata = { values = { 4 } } },
          {
            kind = "style",
            control = FieldMessageText.COLOR,
            args = { 2 },
            raw = { FieldMessageText.EXT_CTRL_CODE_BEGIN, 0x00, 0xFF },
          },
          { kind = "page_break" },
          { kind = "glyph", code = 2, text = "B", raw = { 2 } },
        },
      }
    end,
  }
  local world = {
    canCall = function()
      return true
    end,
    nativeSelectorFacts = localPhoneSelectorFacts(),
  }
  local random = PokegearRandom.new(4243)
  local call = PhoneCall.new({
    state = state,
    catalog = record.catalog,
    messages = messages,
    world = world,
    audio = instantAudio(),
    random = random,
  })
  local handle = call:begin({
    id = "detached-pages",
    contact = "custom.kurt",
    direction = "outgoing",
    kind = "ordinary",
  })
  call:step(handle, {})
  call:step(handle, {})
  local first = call:view(handle)
  local second = call:view(handle)
  local firstLines = first.lines --[[@as table[] ]]
  local secondLines = second.lines --[[@as table[] ]]
  local expectedLines = {
    {
      text = "A{COLOR 2}",
      tokens = {
        { kind = "glyph", code = 1, text = "A", raw = { 1 }, metadata = { values = { 4 } } },
        {
          kind = "style",
          control = FieldMessageText.COLOR,
          args = { 2 },
          raw = { FieldMessageText.EXT_CTRL_CODE_BEGIN, 0x00, 0xFF },
        },
      },
    },
    { text = "B", tokens = { { kind = "glyph", code = 2, text = "B", raw = { 2 } } } },
  }
  Assert.deepEqual(firstLines, expectedLines, "the source token stream creates the expected native pages")
  Assert.deepEqual(firstLines, secondLines, "same-tick views preserve the complete source page value")
  Assert.isFalse(firstLines == secondLines, "each read allocates an independent page list")
  Assert.isFalse(firstLines[1] == secondLines[1], "each page record is independent")
  Assert.isFalse(firstLines[1].tokens == secondLines[1].tokens, "each token list is independent")
  Assert.isFalse(firstLines[1].tokens[1] == secondLines[1].tokens[1], "each token record is independent")
  Assert.isFalse(
    firstLines[1].tokens[1].metadata.values == secondLines[1].tokens[1].metadata.values,
    "unknown nested token metadata is independent"
  )
  Assert.isFalse(firstLines[1].tokens[2].args == secondLines[1].tokens[2].args, "control operands are independent")
  Assert.isFalse(firstLines[1].tokens[2].raw == secondLines[1].tokens[2].raw, "control source bytes are independent")
  local randomBeforeReads = random:capture()
  firstLines[1].text = "changed"
  firstLines[1].tokens[1].text = "changed"
  firstLines[1].tokens[1].raw[1] = 99
  firstLines[1].tokens[1].metadata.values[1] = 99
  firstLines[1].tokens[2].args[1] = 99
  firstLines[1].tokens[2].raw[1] = 99
  table.remove(firstLines, 1)
  local third = call:view(handle)
  local thirdLines = third.lines --[[@as table[] ]]
  Assert.deepEqual(thirdLines, expectedLines, "later views retain original pages, metadata and operands")
  Assert.equal(first.page, 1, "a view read does not advance the active page")
  Assert.equal(third.page, 1, "later reads retain the active page cursor")
  Assert.equal(#thirdLines, 2, "mutating one page list cannot remove an authoritative page")
  Assert.equal(thirdLines[1].text, "A{COLOR 2}", "the first source page retains its rendered text")
  Assert.equal(thirdLines[2].text, "B", "the second source page retains its order and text")
  Assert.deepEqual(random:capture(), randomBeforeReads, "view reads consume no random state")
  Assert.equal(resolves, 1, "view reads do not resolve source messages again")

  call:step(handle, { confirm = true })
  local advanced = call:view(handle)
  Assert.equal(advanced.page, 2, "confirm advances the original page cursor")
  Assert.deepEqual(advanced.lines, expectedLines, "page advancement preserves source page order")
  call:cancel(handle, "test cleanup")
  local result = call:result(handle)
  Assert.notNil(result, "the call reports its terminal result before release")
  call:release(handle)
  Assert.deepEqual(second.lines, expectedLines, "an issued snapshot remains valid after release")
  Assert.throws(function()
    call:view(handle)
  end, "a released call still rejects a stale view handle")
  local nextHandle = call:begin({
    id = "detached-pages-next-call",
    contact = "custom.kurt",
    direction = "outgoing",
    kind = "ordinary",
  })
  call:step(nextHandle, {})
  call:step(nextHandle, {})
  local nextView = call:view(nextHandle)
  Assert.deepEqual(nextView.lines, expectedLines, "a subsequent call resolves its own original message pages")
  Assert.isFalse(nextView.lines == secondLines, "a later call does not reuse a prior snapshot")
  Assert.deepEqual(second.lines, expectedLines, "a later call cannot mutate an earlier released snapshot")
  call:cancel(nextHandle, "test cleanup")
  call:release(nextHandle)
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
function T.tests.gym_native_program_uses_special_entries_and_stages_only_an_accepted_available_invitation()
  local TrainerPhonePrograms = require("game.hgss.src.pokegear.phone.TrainerPhonePrograms")
  local worldWrites = {}
  local world = {
    queryRematch = function()
      return nil
    end,
    setRematch = function(_, contact, value)
      worldWrites[#worldWrites + 1] = { contact = contact, value = value }
    end,
  }
  local request = {
    contact = "hg.gym.falkner",
    family = "gym",
    direction = "outgoing",
    decision = { mode = "special", scriptType = 13, family = "gym" },
    record = { map = 10, rematchWeekday = 5, rematchTime = 0 },
    nativeFacts = {
      localMap = false,
      badges = 16,
      seeking = false,
      weekday = 5,
      timeOfDay = 0,
      dojoHasRoom = true,
    },
  }
  local session = TrainerPhonePrograms.selectNative(world, request)
  Assert.deepEqual(session.entries, { 2, 5 }, "the source prints its opening and invitation prompt entries")
  Assert.equal(session.program, "gym-invitation", "the source invitation choice follows the frozen gym special type")
  Assert.equal(TrainerPhonePrograms.step(session, {}), "waiting", "the invitation waits for a native yes/no choice")
  Assert.equal(TrainerPhonePrograms.step(session, { choice = "no" }), "continue", "declining selects its response page")
  Assert.equal(session.responseEntry, 7, "declining prints the native no response")
  Assert.equal(#worldWrites, 0, "declining does not stage rematch readiness")

  local accepted = TrainerPhonePrograms.selectNative(world, request)
  Assert.equal(
    TrainerPhonePrograms.step(accepted, { choice = "yes" }),
    "continue",
    "accepting selects its source response"
  )
  Assert.equal(accepted.responseEntry, 6, "an available dojo selects the native accepted response")
  Assert.equal(#worldWrites, 0, "the effect waits until its response page resolves")
  Assert.equal(
    TrainerPhonePrograms.step(accepted, { responseResolved = true }),
    "done",
    "the accepted response completes the program"
  )
  Assert.equal(#worldWrites, 1, "the accepted invitation stages exactly once")
  Assert.equal(worldWrites[1].contact, request.contact, "the effect preserves native contact identity")
  Assert.deepEqual(worldWrites[1].value, { stage = 1, wins = 0 }, "the durable owner receives the staged invitation")

  local localRequest = {
    contact = request.contact,
    family = "gym",
    direction = "outgoing",
    decision = request.decision,
    record = request.record,
    nativeFacts = { localMap = true },
  }
  Assert.deepEqual(
    TrainerPhonePrograms.selectNative(world, localRequest).entries,
    { 1 },
    "a local outgoing caller terminates with the source local-map entry"
  )
  local waitingRequest = {
    contact = request.contact,
    family = "gym",
    direction = "outgoing",
    decision = request.decision,
    record = request.record,
    nativeFacts = {
      localMap = false,
      badges = 15,
      seeking = false,
    },
  }
  Assert.deepEqual(
    TrainerPhonePrograms.selectNative(world, waitingRequest).entries,
    { 2, 3 },
    "a remote caller without all badges receives the native wait response"
  )
  waitingRequest.nativeFacts.badges = 16
  waitingRequest.nativeFacts.seeking = true
  Assert.deepEqual(
    TrainerPhonePrograms.selectNative(world, waitingRequest).entries,
    { 2, 9 },
    "an existing invitation takes precedence over the call window"
  )
  waitingRequest.nativeFacts.seeking = false
  waitingRequest.nativeFacts.weekday = 4
  waitingRequest.nativeFacts.timeOfDay = 0
  Assert.deepEqual(
    TrainerPhonePrograms.selectNative(world, waitingRequest).entries,
    { 2, 4 },
    "a closed native weekday window declines the invitation"
  )

  local incomingRequest = {
    contact = request.contact,
    family = "gym",
    direction = "incoming",
    decision = { mode = "special", scriptType = 14, family = "gym" },
    nativeFacts = { seeking = false },
    draw = function()
      return 1
    end,
  }
  local incoming = TrainerPhonePrograms.selectNative(world, incomingRequest)
  Assert.deepEqual(incoming.entries, { 10 }, "incoming calls show the opening before selecting a response")
  Assert.equal(TrainerPhonePrograms.step(incoming, {}), "continue", "incoming response follows the opening page")
  Assert.equal(incoming.responseEntry, 13, "the source random response uses its three-entry range")
  incomingRequest.nativeFacts.seeking = true
  incomingRequest.draw = function()
    error("seeking calls do not draw the random response")
  end
  local seeking = TrainerPhonePrograms.selectNative(world, incomingRequest)
  Assert.equal(TrainerPhonePrograms.step(seeking, {}), "continue", "seeking calls advance after the opening page")
  Assert.equal(seeking.responseEntry, 11, "seeking calls use the fixed native response")
end

function T.tests.generic_header_selector_skips_closed_radio_rematch_before_weekday_facts()
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local headers = {
    { type = 3, chance = 100, scriptType = 0, scriptId = 44 },
    { type = 1, chance = 100, scriptType = 0, scriptId = 34 },
  }
  for _ = 3, 8 do
    headers[#headers + 1] = { type = 0, chance = 100, scriptType = 0, scriptId = 65535 }
  end
  local manifest = fixtureManifest()
  local contact = manifest.catalog.contacts[2]
  contact.genericCallHeaders = { outgoing = headers, incoming = headers }
  local record = PokegearAssetSchema.validate(manifest)
  Assert.notNil(record, "the generic trainer header fixture validates through the real schema")
  assert(record ~= nil, "the generic trainer header fixture validated above")
  local state = PokegearState.new({ seed = 73 }, catalogRefs(record))
  state:registerContact("custom.trainer-plain")
  local selectedScript = nil
  local world = {
    canCall = function()
      return true
    end,
    nativeSelectorFacts = function()
      return { localMap = false }
    end,
    callFacts = function()
      return { radioTowerBeaten = false, seeking = false, pendingGenericGift = false }
    end,
  }
  local messages = phoneMessages()
  messages.resolveLine = function(_, _, scriptId)
    selectedScript = scriptId
    return { tokens = { { kind = "glyph", code = 1, text = "X", raw = { 1 } } } }
  end
  local call = PhoneCall.new({
    state = state,
    catalog = record.catalog,
    messages = messages,
    world = world,
    audio = {
      isEffectWaitComplete = function()
        return false
      end,
    },
    random = {
      mt = function()
        return 0
      end,
    },
  })
  local handle = call:begin({
    id = "generic-short-circuit",
    contact = "custom.trainer-plain",
    direction = "outgoing",
    kind = "ordinary",
  })
  call:step(handle, {})
  Assert.equal(selectedScript, 34, "the closed rematch header skips its unused weekday and time facts")
  Assert.equal(call:view(handle).stage, "message", "the following ordinary header produces a printable page")
end

function T.tests.generic_header_selector_skips_national_park_gifts_during_bug_contest()
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local headers = {
    { type = 7, chance = 100, scriptType = 0, scriptId = 44 },
    { type = 8, chance = 100, scriptType = 0, scriptId = 45 },
    { type = 1, chance = 100, scriptType = 0, scriptId = 34 },
  }
  for _ = 4, 8 do
    headers[#headers + 1] = { type = 0, chance = 100, scriptType = 0, scriptId = 65535 }
  end
  local manifest = fixtureManifest()
  manifest.catalog.contacts[2].genericCallHeaders = { outgoing = headers, incoming = headers }
  local record = PokegearAssetSchema.validate(manifest)
  Assert.notNil(record, "the contest-gated generic caller validates through the real schema")
  assert(record ~= nil, "the generic caller fixture validated above")
  local state = PokegearState.new({ seed = 74 }, catalogRefs(record))
  state:registerContact("custom.trainer-plain")
  local selectedScript = nil
  local messages = phoneMessages()
  messages.resolveLine = function(_, _, scriptId)
    selectedScript = scriptId
    return { tokens = { { kind = "glyph", code = 1, text = "X", raw = { 1 } } } }
  end
  local call = PhoneCall.new({
    state = state,
    catalog = record.catalog,
    messages = messages,
    world = {
      canCall = function()
        return true
      end,
      nativeSelectorFacts = function()
        return { localMap = false }
      end,
      callFacts = function()
        return {
          radioTowerBeaten = true,
          seeking = true,
          pendingGenericGift = true,
          nationalParkCaller = true,
          bugContestActive = true,
        }
      end,
    },
    audio = instantAudio(),
    random = {
      mt = function()
        return 0
      end,
    },
  })
  local handle = call:begin({
    id = "generic-national-park-contest",
    contact = "custom.trainer-plain",
    direction = "outgoing",
    kind = "ordinary",
  })
  call:step(handle, { confirm = true })
  Assert.equal(selectedScript, 34, "types seven and eight fall through during the National Park Bug Contest")
end

function T.tests.native_service_specials_follow_their_source_page_sequences()
  local ServicePhonePrograms = require("game.hgss.src.pokegear.phone.ServicePhonePrograms")
  local function finish(session, expected)
    local index = 1
    for _, entry in ipairs(expected) do
      Assert.equal(session.responseEntry, entry, "the next native response entry follows source order")
      local result = ServicePhonePrograms.stepNativePage(session, { responseResolved = true })
      index = index + 1
      if index <= #expected then
        Assert.equal(result, "continue", "the source program waits for each following response")
      else
        Assert.equal(result, "done", "the last source response completes the native program")
      end
    end
  end

  local bill = ServicePhonePrograms.selectNativePage({
    contact = "hg.bill",
    decision = { family = "bill", scriptType = 3 },
    nativeFacts = { playerGender = 0, pcFreeSlots = 0 },
  })
  Assert.deepEqual(bill.entries, { 3 }, "Bill begins with the gender-specific intro")
  Assert.equal(ServicePhonePrograms.stepNativePage(bill, {}), "continue", "Bill advances after the intro")
  finish(bill, { 9, 8 })

  local stockedBill = ServicePhonePrograms.selectNativePage({
    contact = "hg.bill",
    decision = { family = "bill", scriptType = 3 },
    nativeFacts = { playerGender = 1, pcFreeSlots = 5, pcBoxName = "BOX 2" },
    draw = function()
      return 1
    end,
  })
  Assert.equal(ServicePhonePrograms.stepNativePage(stockedBill, {}), "continue", "Bill advances to active-box advice")
  Assert.equal(stockedBill.responseEntry, 6, "Bill selects the source random advice entry")
  Assert.deepEqual(
    stockedBill.substitutionsByEntry[6],
    { [11] = { [10] = "BOX 2" }, [52] = { [11] = 5 } },
    "Bill's advice receives the active box name and free-slot count"
  )
  Assert.equal(
    ServicePhonePrograms.stepNativePage(stockedBill, { responseResolved = true }),
    "continue",
    "Bill prints the closing page after advice"
  )
  Assert.equal(stockedBill.responseEntry, 8, "Bill's advice is followed by the native closing")

  local mappedFriend = ServicePhonePrograms.selectNativePage({
    contact = "hg.friend",
    decision = { family = "friend", scriptType = 10 },
    nativeFacts = { timeOfDay = 2, friendMapIndex = 48 },
    draw = function()
      error("mapped Friend phrase does not draw")
    end,
  })
  Assert.deepEqual(mappedFriend.entries, { 6 }, "Friend's type-ten opening follows the time of day")
  Assert.equal(ServicePhonePrograms.stepNativePage(mappedFriend, {}), "continue", "Friend advances after its opening")
  Assert.equal(mappedFriend.responseEntry, 61, "Friend maps the current native map to the source phrase index")

  local randomFriend = ServicePhonePrograms.selectNativePage({
    contact = "hg.friend",
    decision = { family = "friend", scriptType = 10 },
    nativeFacts = { timeOfDay = 0 },
    draw = function()
      return 2
    end,
  })
  Assert.equal(
    ServicePhonePrograms.stepNativePage(randomFriend, {}),
    "continue",
    "unmapped Friend calls select a topic"
  )
  Assert.equal(randomFriend.responseEntry, 12, "an unmapped type-ten location selects one of three random phrases")

  local unlockedFriendDraws = { 500, 1 }
  local unlockedFriend = ServicePhonePrograms.selectNativePage({
    contact = "hg.friend",
    decision = { family = "friend", scriptType = 11 },
    nativeFacts = { timeOfDay = 1, friendEligiblePhraseIndices = { 1, 7, 19 } },
    draw = function()
      return table.remove(unlockedFriendDraws, 1)
    end,
  })
  Assert.deepEqual(unlockedFriend.entries, { 8 }, "Friend's type-eleven opening follows the time of day")
  Assert.equal(
    ServicePhonePrograms.stepNativePage(unlockedFriend, {}),
    "continue",
    "Friend advances after its incoming opening"
  )
  Assert.equal(unlockedFriend.responseEntry, 93, "the unlocked branch maps its draw to a source phrase row")
  Assert.equal(#unlockedFriendDraws, 0, "the unlocked branch consumes exactly two native draws")

  local buena = ServicePhonePrograms.selectNativePage({
    contact = "hg.buena",
    decision = { family = "buena", scriptType = 8 },
    nativeFacts = { playerGender = 0, timeOfDay = 1 },
    draw = function()
      return 2
    end,
  })
  Assert.deepEqual(buena.entries, { 5 }, "Buena's type-eight opening uses time and gender")
  Assert.equal(ServicePhonePrograms.stepNativePage(buena, {}), "continue", "Buena waits for her random follow-up")
  finish(buena, { 12 })

  local passwordOnAir = ServicePhonePrograms.selectNativePage({
    contact = "hg.buena",
    decision = { family = "buena", scriptType = 9 },
    nativeFacts = { playerGender = 1, timeOfDay = 0, passwordOnAir = true },
    draw = function()
      error("the password page does not consume a random draw")
    end,
  })
  Assert.deepEqual(passwordOnAir.entries, { 16 }, "Buena's type-nine opener is gendered")
  Assert.equal(ServicePhonePrograms.stepNativePage(passwordOnAir, {}), "continue", "password-on-air adds its follow-up")
  finish(passwordOnAir, { 36 })

  local gameClear = ServicePhonePrograms.selectNativePage({
    contact = "hg.buena",
    decision = { family = "buena", scriptType = 9 },
    nativeFacts = { playerGender = 1, timeOfDay = 2, passwordOnAir = false, gameClear = true },
    draw = function()
      return 13
    end,
  })
  Assert.deepEqual(gameClear.entries, { 20 }, "Buena's type-nine opener follows the time of day")
  Assert.equal(ServicePhonePrograms.stepNativePage(gameClear, {}), "continue", "Buena waits for the game-clear branch")
  finish(gameClear, { 35 })

  local baoba = ServicePhonePrograms.selectNativePage({
    contact = "hg.baoba",
    decision = { family = "baoba", scriptType = 15 },
    nativeFacts = { playerGender = 0, safariArrangementAreas = { 0, 11, 4 } },
  })
  Assert.deepEqual(baoba.entries, { 18 }, "Baoba selects the message for the live Safari arrangement count")
  Assert.deepEqual(baoba.substitutionsByEntry[18], { safariAreaIds = { 0, 11, 4 } })
  Assert.equal(ServicePhonePrograms.stepNativePage(baoba, {}), "done", "Baoba's single source page completes")
end

function T.tests.daycare_native_pages_follow_slot_growth_egg_and_compatibility_facts()
  local ServicePhonePrograms = require("game.hgss.src.pokegear.phone.ServicePhonePrograms")
  local noMons = ServicePhonePrograms.selectNativePage({
    contact = "hg.daycare-lady",
    decision = { family = "daycare", scriptType = 6 },
    nativeFacts = { playerGender = 0, daycareMons = {} },
  })
  Assert.deepEqual(noMons.entries, { 3 }, "the remote Day Care opener is gendered")
  Assert.equal(ServicePhonePrograms.stepNativePage(noMons, {}), "continue")
  Assert.equal(noMons.responseEntry, 10, "an empty Day Care closes with its empty response")
  Assert.equal(ServicePhonePrograms.stepNativePage(noMons, { responseResolved = true }), "done")

  local oneMon = ServicePhonePrograms.selectNativePage({
    contact = "hg.daycare-lady",
    decision = { family = "daycare", scriptType = 6 },
    nativeFacts = {
      playerGender = 1,
      daycareMons = { { nickname = "SPROUT", growth = 2 } },
    },
  })
  Assert.deepEqual(oneMon.entries, { 4 })
  Assert.equal(ServicePhonePrograms.stepNativePage(oneMon, {}), "continue")
  Assert.equal(oneMon.responseEntry, 5, "an occupied Day Care begins its mon report")
  Assert.deepEqual(oneMon.responseSubstitutionsByIndex[2], { [0] = { [10] = "SPROUT" }, [52] = { [11] = 2 } })
  Assert.equal(ServicePhonePrograms.stepNativePage(oneMon, { responseResolved = true }), "continue")
  Assert.equal(oneMon.responseEntry, 6, "the report names the mon and level growth")
  Assert.deepEqual(oneMon.responseSubstitutions, { [0] = { [10] = "SPROUT" }, [52] = { [11] = 2 } })
  Assert.equal(ServicePhonePrograms.stepNativePage(oneMon, { responseResolved = true }), "continue")
  Assert.equal(oneMon.responseEntry, 8, "one deposited mon uses the singular closing")
  Assert.equal(ServicePhonePrograms.stepNativePage(oneMon, { responseResolved = true }), "done")

  local egg = ServicePhonePrograms.selectNativePage({
    contact = "hg.daycare-man",
    decision = { family = "daycare", scriptType = 7 },
    nativeFacts = { daycareEggPid = 123, daycareMons = {} },
  })
  Assert.deepEqual(egg.entries, { 2 })
  Assert.equal(ServicePhonePrograms.stepNativePage(egg, {}), "continue")
  Assert.equal(egg.responseEntry, 3, "an available egg selects its source page")
  Assert.equal(ServicePhonePrograms.stepNativePage(egg, { responseResolved = true }), "done")

  local pair = ServicePhonePrograms.selectNativePage({
    contact = "hg.daycare-man",
    decision = { family = "daycare", scriptType = 7 },
    nativeFacts = {
      daycareEggPid = 0,
      daycareCompatibility = 1,
      daycareMons = { { nickname = "A", growth = 0 }, { nickname = "B", growth = 0 } },
    },
  })
  Assert.equal(ServicePhonePrograms.stepNativePage(pair, {}), "continue")
  Assert.equal(pair.responseEntry, 6, "two deposited mons select the pair page")
  Assert.deepEqual(pair.substitutionsByEntry[6], { [0] = { [10] = "A", [11] = "B" } })
  Assert.equal(ServicePhonePrograms.stepNativePage(pair, { responseResolved = true }), "continue")
  Assert.equal(pair.responseEntry, 8, "medium compatibility selects its source page")
  Assert.equal(ServicePhonePrograms.stepNativePage(pair, { responseResolved = true }), "continue")
  Assert.equal(pair.responseEntry, 11, "the pair report has the native closing")
  Assert.equal(ServicePhonePrograms.stepNativePage(pair, { responseResolved = true }), "done")
end

function T.tests.phone_call_prints_the_native_gym_pages_before_staging_an_invitation()
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local catalog = record.catalog --[[@as table<string, unknown>]]
  local contacts = catalog.contacts --[[@as table<integer, table<string, unknown>>]]
  local leader = assert(
    (function()
      for _, contact in ipairs(contacts) do
        if contact.key == "custom.leader-falkner" then
          return contact
        end
      end
    end)(),
    "the synthetic catalog has its Gym caller"
  )
  leader.rematchWeekday = 5
  leader.rematchTime = 0
  local state = PokegearState.new({ seed = 18 }, catalogRefs(record))
  state:registerContact("custom.leader-falkner")
  local trace = {}
  local rematches = {}
  local facts = {
    localMap = false,
    badges = 16,
    seeking = false,
    weekday = 5,
    timeOfDay = 0,
    dojoHasRoom = true,
  }
  local messages = phoneMessages()
  messages.resolveContactEntry = function(_, _, entry)
    trace[#trace + 1] = entry
    return { tokens = { { kind = "glyph", code = entry, text = tostring(entry), raw = { entry } } } }
  end
  local world = {
    canCall = function()
      return true
    end,
    nativeSelectorFacts = function()
      return { localMap = false }
    end,
    callFacts = function()
      return facts
    end,
    queryRematch = function()
      return nil
    end,
    setRematch = function(_, contact, value)
      rematches[#rematches + 1] = { contact = contact, value = value }
    end,
  }
  local call = PhoneCall.new({
    state = state,
    catalog = catalog,
    messages = messages,
    world = world,
    audio = instantAudio(),
    random = PokegearRandom.new(18),
  })
  local handle = call:begin({
    id = "gym-native-1",
    contact = "custom.leader-falkner",
    direction = "outgoing",
    kind = "ordinary",
  })
  call:step(handle, { confirm = true })
  Assert.deepEqual(trace, { 2, 5 }, "the conversation resolves its native introduction and choice prompt entries")
  local foundChoice = false
  for _ = 1, 6 do
    if call:view(handle).stage == "choice" then
      foundChoice = true
      break
    end
    call:step(handle, { confirm = true })
  end
  Assert.isTrue(foundChoice, "the native invitation reaches its yes/no menu after the prompt")
  Assert.deepEqual(call:view(handle).choices, { "yes", "no" }, "the call exposes the native invitation choices")
  call:step(handle, { choice = "yes" })
  Assert.equal(trace[#trace], 6, "acceptance resolves the native accepted response entry")
  Assert.equal(#rematches, 0, "the rematch stays unstaged while its response page is visible")
  for _ = 1, 6 do
    if call:result(handle) ~= nil then
      break
    end
    call:step(handle, { confirm = true })
  end
  local result = call:result(handle)
  Assert.notNil(result, "the native gym conversation reaches a terminal outcome")
  Assert.isNil(result.error, "the native gym conversation succeeds")
  Assert.equal(#rematches, 1, "the invitation stages once after its response completes")
  Assert.deepEqual(rematches[1].value, { stage = 1, wins = 0 }, "the phone writes the durable invitation shape")
end

function T.tests.oak_native_selector_preserves_scripted_incoming_local_and_acknowledgment_order()
  local ProfessorPhonePrograms = require("game.hgss.src.pokegear.phone.ProfessorPhonePrograms")
  local record = { map = 10 }
  local scripted = ProfessorPhonePrograms.selectOakNative("outgoing", record, { scriptedCallType = 2 })
  Assert.deepEqual(
    scripted,
    { mode = "numeric", scriptId = 82, family = "oak" },
    "scripted Oak calls precede every other selector branch"
  )

  local incoming = ProfessorPhonePrograms.selectOakNative("incoming", record, { nationalDexOwned = 101 })
  Assert.deepEqual(
    incoming,
    { mode = "numeric", scriptId = 70, family = "oak" },
    "incoming calls scale and floor the National Dex count"
  )
  incoming = ProfessorPhonePrograms.selectOakNative("incoming", record, { nationalDexOwned = 9999, localMap = true })
  Assert.deepEqual(
    incoming,
    { mode = "numeric", scriptId = 77, family = "oak" },
    "incoming calls clamp their script range before checking locality"
  )

  local localCall =
    ProfessorPhonePrograms.selectOakNative("outgoing", record, { localMap = true, acknowledgedNational = true })
  Assert.deepEqual(
    localCall,
    { mode = "numeric", scriptId = 68, family = "oak" },
    "a local call precedes completion acknowledgments"
  )
  local nationalAck =
    ProfessorPhonePrograms.selectOakNative("outgoing", record, { localMap = false, acknowledgedNational = true })
  Assert.deepEqual(
    nationalAck,
    { mode = "numeric", scriptId = 81, family = "oak" },
    "National Dex acknowledgment selects its native numeric script"
  )
  local johtoAck = ProfessorPhonePrograms.selectOakNative("outgoing", record, {
    localMap = false,
    acknowledgedNational = false,
    nationalDexUnlocked = false,
    acknowledgedJohto = true,
  })
  Assert.deepEqual(
    johtoAck,
    { mode = "numeric", scriptId = 80, family = "oak" },
    "Johto acknowledgment selects its native numeric script"
  )
  local special = ProfessorPhonePrograms.selectOakNative("outgoing", record, {
    localMap = false,
    acknowledgedNational = false,
    nationalDexUnlocked = true,
    acknowledgedJohto = false,
  })
  Assert.deepEqual(
    special,
    { mode = "special", scriptType = 5, family = "oak" },
    "ordinary Oak calls select special type five"
  )
end

function T.tests.kenji_native_selector_preserves_source_wait_active_and_time_order()
  local TrainerPhonePrograms = require("game.hgss.src.pokegear.phone.TrainerPhonePrograms")
  local function select(facts)
    return TrainerPhonePrograms.selectKenjiNative(facts)
  end

  Assert.deepEqual(
    select({ localMap = true, kenjiWaitDays = 3, kenjiActive = true, seeking = false }),
    { scriptId = 86, activate = false },
    "same-map calls select the local script before remote wait facts"
  )
  Assert.deepEqual(
    select({ localMap = false, kenjiWaitDays = 2, kenjiActive = false, seeking = false, timeOfDay = 1 }),
    { scriptId = 87, activate = false },
    "more than one wait day selects the waiting script"
  )
  Assert.deepEqual(
    select({ localMap = false, kenjiWaitDays = 1, kenjiActive = false, seeking = false, timeOfDay = 1 }),
    { scriptId = 88, activate = false },
    "one wait day precedes the active-without-seeking branch"
  )
  Assert.deepEqual(
    select({ localMap = false, kenjiWaitDays = 0, kenjiActive = true, seeking = false, timeOfDay = 1 }),
    { scriptId = 87, activate = false },
    "an active caller without its seeking rematch remains waiting"
  )
  Assert.deepEqual(
    select({ localMap = false, kenjiWaitDays = 0, kenjiActive = false, seeking = false, timeOfDay = 2 }),
    { scriptId = 91, activate = false },
    "evening and night return before the active and seeking side effect"
  )
  Assert.deepEqual(
    select({ localMap = false, kenjiWaitDays = 0, kenjiActive = false, seeking = false, timeOfDay = 0 }),
    { scriptId = 89, activate = true },
    "an eligible morning call activates Kenji and selects the morning script"
  )
  Assert.deepEqual(
    select({ localMap = false, kenjiWaitDays = 0, kenjiActive = true, seeking = true, timeOfDay = 1 }),
    { scriptId = 90, activate = false },
    "an eligible daytime repeat preserves seeking and selects the day script"
  )
end

function T.tests.mother_native_selector_preserves_scripted_local_incoming_and_rival_order()
  local MotherPhoneProgram = require("game.hgss.src.pokegear.phone.MotherPhoneProgram")
  local record = { key = "custom.mom" }
  local scripted = MotherPhoneProgram.selectNative("outgoing", record, { scriptedCallType = 2 })
  Assert.deepEqual(
    scripted,
    { mode = "special", scriptType = 4, family = "mother" },
    "scripted Mom calls select special type four first"
  )
  local localCall = MotherPhoneProgram.selectNative("incoming", record, {
    scriptedCallType = 0,
    localMap = true,
  })
  Assert.deepEqual(
    localCall,
    { mode = "numeric", scriptId = 23, family = "mother" },
    "locality precedes incoming trigger selection"
  )
  local incoming = MotherPhoneProgram.selectNative("incoming", record, {
    scriptedCallType = 0,
    localMap = false,
    predefinedScript = 37,
  })
  Assert.deepEqual(
    incoming,
    { mode = "numeric", scriptId = 37, family = "mother" },
    "incoming Mom uses its provided native script ID"
  )
  local early = MotherPhoneProgram.selectNative("outgoing", record, {
    scriptedCallType = 0,
    localMap = false,
    gaveRivalName = false,
  })
  Assert.deepEqual(
    early,
    { mode = "numeric", scriptId = 25, family = "mother" },
    "the rival-name branch selects its source numeric script"
  )
  local followup = MotherPhoneProgram.selectNative("outgoing", record, {
    scriptedCallType = 0,
    localMap = false,
    gaveRivalName = true,
    talkedAfterNamingRival = false,
  })
  Assert.deepEqual(
    followup,
    { mode = "numeric", scriptId = 26, family = "mother" },
    "the one-time follow-up precedes the savings special"
  )
  local savings = MotherPhoneProgram.selectNative("outgoing", record, {
    scriptedCallType = 0,
    localMap = false,
    gaveRivalName = true,
    talkedAfterNamingRival = true,
  })
  Assert.deepEqual(
    savings,
    { mode = "special", scriptType = 4, family = "mother" },
    "the completed rival branches select Mom's native savings special"
  )
end

function T.tests.mother_native_savings_program_resolves_source_pages_and_writes_once()
  local MotherPhoneProgram = require("game.hgss.src.pokegear.phone.MotherPhoneProgram")
  local writes = {}
  local world = {
    setMomSavingsChoice = function(_, saving)
      writes[#writes + 1] = saving
    end,
  }
  local session = MotherPhoneProgram.selectNativeSession(world, {
    contact = "custom.mom",
    decision = { mode = "special", scriptType = 4, family = "mother" },
    nativeFacts = {
      scriptedCallType = 0,
      momIntroParameter = 3,
      momSavingsBalance = 500,
      momSavingsActive = false,
      momGiftQueueFull = false,
    },
  })
  Assert.deepEqual(session.entries, { 10 }, "Mom selects the map intro entry from the source location parameter")
  Assert.equal(MotherPhoneProgram.stepNative(session, {}), "continue", "Mom shows the balance-dependent source prompt")
  Assert.equal(session.responseEntry, 24, "the native prompt uses the savings flag and current balance")
  Assert.equal(
    MotherPhoneProgram.stepNative(session, { responseResolved = true }),
    "waiting",
    "Mom waits for an explicit savings choice"
  )
  Assert.equal(
    MotherPhoneProgram.stepNative(session, { choice = "save" }),
    "continue",
    "the choice selects its matching response entry"
  )
  Assert.equal(session.responseEntry, 25, "saving resolves the native response page")
  Assert.deepEqual(writes, {}, "Mom defers the selected savings flag until the response text resolves")
  session.responseEffect()
  session.responseEffect = nil
  Assert.deepEqual(writes, { true }, "Mom publishes the selected savings flag after response validation")
  Assert.equal(
    MotherPhoneProgram.stepNative(session, { responseResolved = true }),
    "done",
    "Mom finishes after the response page"
  )
  Assert.deepEqual(writes, { true }, "repeated completion cannot write the savings choice twice")
end

function T.tests.mother_scripted_intro_defers_rival_conversation_flag_until_text_is_ready()
  local MotherPhoneProgram = require("game.hgss.src.pokegear.phone.MotherPhoneProgram")
  local writes = 0
  local world = {
    setMomTalkedAfterNamingRival = function()
      writes = writes + 1
    end,
  }

  local session = MotherPhoneProgram.selectNativeSession(world, {
    contact = "custom.mom",
    decision = { mode = "special", scriptType = 4, family = "mother" },
    nativeFacts = {
      scriptedCallType = 2,
      momSavingsBalance = 0,
      momSavingsActive = false,
      momGiftQueueFull = false,
    },
  })

  Assert.equal(writes, 0, "selecting the scripted intro does not publish its follow-up flag")
  Assert.deepEqual(session.entries, { 22 }, "scripted intro enters the source-specific Mom prompt")
  Assert.isTrue(type(session.deferredEffect) == "function", "the scripted intro carries a deferred source flag write")
  session.deferredEffect()
  Assert.equal(writes, 1, "the source follow-up flag publishes after the selected text is ready")
  Assert.deepEqual(
    session.substitutionsByEntry[22],
    { [55] = { [10] = 0 } },
    "Mom's savings balance uses its source variable and argument slot"
  )
end

function T.tests.phone_call_opens_native_remote_kurt_program()
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "Kurt caller fixture validates through the asset schema")
  assert(record ~= nil, "Kurt caller fixture validated above")
  local state = PokegearState.new({ seed = 76 }, catalogRefs(record))
  state:registerContact("custom.kurt")
  local selectedEntry = nil
  local selectedSubstitutions = nil
  local messages = phoneMessages()
  messages.resolveContactEntry = function(_, _, entry, substitutions)
    selectedEntry = entry
    selectedSubstitutions = substitutions
    return { tokens = { { kind = "glyph", code = 1, text = "K", raw = { 1 } } } }
  end
  local call = PhoneCall.new({
    state = state,
    catalog = record.catalog,
    messages = messages,
    world = {
      canCall = function()
        return true
      end,
      nativeSelectorFacts = function()
        return { localMap = false }
      end,
      callFacts = function()
        return {
          kurtRepeatCaller = true,
          kurtQuantity = 2,
          kurtBallName = "GREAT BALL",
          kurtDailyWork = false,
        }
      end,
    },
    audio = instantAudio(),
  })

  local handle = call:begin({ id = "kurt-native", contact = "custom.kurt", direction = "outgoing", kind = "ordinary" })
  call:step(handle, { confirm = true })

  Assert.equal(selectedEntry, 6, "Kurt's repeat-caller flag selects the native second opening entry")
  Assert.equal(call:view(handle).stage, "message", "remote Kurt produces a printable native conversation page")
  call:step(handle, { advance = true })
  Assert.equal(selectedEntry, 3, "Kurt's completed Apricorn batch advances to its source quantity page")
  Assert.deepEqual(
    selectedSubstitutions,
    { [51] = { [11] = "GREAT BALL" }, [8] = { [10] = 2 } },
    "Kurt's item and quantity follow the source variable selectors"
  )
end

function T.tests.phone_call_opens_native_remote_bill_and_friend_pages()
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "service caller fixture validates through the asset schema")
  assert(record ~= nil, "service caller fixture validated above")
  local state = PokegearState.new({ seed = 77 }, catalogRefs(record))
  state:registerContact("custom.bill")
  state:registerContact("custom.friend")
  local resolved = {}
  local randomLabels = {}
  local messages = phoneMessages()
  messages.resolveContactEntry = function(_, contact, entry)
    local entries = resolved[contact] or {}
    resolved[contact] = entries
    entries[#entries + 1] = entry
    return { tokens = { { kind = "glyph", code = 1, text = "S", raw = { 1 } } } }
  end
  local call = PhoneCall.new({
    state = state,
    catalog = record.catalog,
    messages = messages,
    world = {
      canCall = function()
        return true
      end,
      nativeSelectorFacts = function()
        return { localMap = false, playerGender = 1 }
      end,
      callFacts = function()
        return {
          playerGender = 1,
          timeOfDay = 2,
          pcFreeSlots = 0,
          friendMapIndex = 4,
          friendEligiblePhraseIndices = { 2 },
        }
      end,
    },
    audio = instantAudio(),
    random = {
      lc = function(_, label)
        randomLabels[#randomLabels + 1] = label
        return 1
      end,
    },
  })

  for _, contact in ipairs({ "custom.bill", "custom.friend" }) do
    local handle =
      call:begin({ id = "special-" .. contact, contact = contact, direction = "outgoing", kind = "ordinary" })
    call:step(handle, { confirm = true })
    Assert.equal(call:view(handle).stage, "message", contact .. " special dispatch resolves a printable native page")
    for _ = 1, 8 do
      if call:result(handle) ~= nil then
        break
      end
      call:step(handle, { advance = true })
    end
    Assert.notNil(call:result(handle), contact .. " special call completes after its native opening page")
  end

  local incoming = call:begin({
    id = "special-friend-incoming",
    contact = "custom.friend",
    direction = "incoming",
    kind = "incoming",
  })
  call:step(incoming, { confirm = true })
  for _ = 1, 8 do
    if call:result(incoming) ~= nil then
      break
    end
    call:step(incoming, { advance = true })
  end
  Assert.notNil(call:result(incoming), "Friend's incoming follow-up page reaches a terminal result")

  Assert.deepEqual(
    resolved["custom.bill"],
    { 4, 9, 8 },
    "Bill resolves the opening, empty-box branch, and closing pages"
  )
  Assert.deepEqual(
    resolved["custom.friend"],
    { 6, 17, 9, 10 },
    "Friend resolves each direction's opener and source follow-up"
  )
  Assert.deepEqual(
    randomLabels,
    { "friend-response-message", "friend-response-message" },
    "Friend's random-message branch consumes its source condition and selection draws"
  )
end

function T.tests.phone_call_opens_and_resolves_the_dynamic_baoba_incoming_page()
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local manifest = fixtureManifest()
  manifest.catalog.contacts[#manifest.catalog.contacts + 1] = {
    key = "custom.baoba",
    family = "baoba",
    sortWeight = 45,
  }
  manifest.catalog.contactOrder[#manifest.catalog.contactOrder + 1] = "custom.baoba"
  local record = PokegearAssetSchema.validate(manifest)
  Assert.notNil(record, "Baoba fixture validates through the asset schema")
  assert(record ~= nil, "Baoba fixture validated above")
  local baobaFamily = nil
  for _, contact in ipairs(record.catalog.contacts) do
    if contact.key == "custom.baoba" then
      baobaFamily = contact.family
    end
  end
  Assert.equal(baobaFamily, "baoba", "Baoba remains the selected catalog family")
  local state = PokegearState.new({ seed = 77 }, catalogRefs(record))
  state:registerContact("custom.baoba")
  local resolvedEntry = nil
  local messages = phoneMessages()
  messages.resolveContactEntry = function(_, _, entry)
    resolvedEntry = entry
    return { tokens = { { kind = "glyph", code = 1, text = "B", raw = { 1 } } } }
  end
  local call = PhoneCall.new({
    state = state,
    catalog = record.catalog,
    messages = messages,
    world = {
      canCall = function()
        return true
      end,
      nativeSelectorFacts = function()
        return { localMap = false, playerGender = 1 }
      end,
      callFacts = function()
        return { playerGender = 1, safariArrangementAreas = {} }
      end,
    },
    audio = instantAudio(),
  })
  local handle =
    call:begin({ id = "baoba-incoming", contact = "custom.baoba", direction = "incoming", kind = "incoming" })
  call:step(handle, { confirm = true })
  local outcome = call:result(handle)
  Assert.isNil(
    outcome,
    "Baoba native dispatch should not fail: " .. tostring(outcome and outcome.error and outcome.error.message)
  )
  Assert.equal(call:view(handle).stage, "message", "Baoba opens a native message page")
  Assert.equal(resolvedEntry, 39, "zero Safari arrangements select the source female page")
  call:step(handle, { advance = true })
  Assert.notNil(call:result(handle), "Baoba resolves and completes the incoming page")
end

function T.tests.phone_call_resolves_oak_incoming_script_from_its_frozen_native_facts()
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
  local manifest = fixtureManifest()
  manifest.catalog.contacts[#manifest.catalog.contacts + 1] = {
    key = "custom.oak",
    family = "oak",
    sortWeight = 60,
  }
  manifest.catalog.contactOrder[#manifest.catalog.contactOrder + 1] = "custom.oak"
  local record = PokegearAssetSchema.validate(manifest)
  Assert.notNil(record, "the synthetic Oak contact validates through the real asset schema")
  assert(record ~= nil, "synthetic Oak catalog validated above")
  record.catalog.callDefinitions[70] = {
    id = 70,
    kind = "item",
    param0 = 0,
    param1 = 26,
    male = { bank = 641, entry = 70 },
    female = { bank = 641, entry = 70 },
  }
  local state = PokegearState.new({ seed = 82 }, catalogRefs(record))
  state:registerContact("custom.oak")
  local resolvedScript = nil
  local effects = {}
  local messages = phoneMessages()
  messages.resolveLine = function(_, _, scriptId)
    resolvedScript = scriptId
    return { tokens = { { kind = "glyph", code = scriptId, text = tostring(scriptId), raw = { scriptId } } } }
  end
  local world = {
    canCall = function()
      return true
    end,
    nativeSelectorFacts = function()
      return { localMap = false }
    end,
    callFacts = function()
      return { nationalDexOwned = 101 }
    end,
    prepareCallDefinitionEffect = function(_, contact, definition)
      return {
        substitutions = {},
        commit = function()
          effects[#effects + 1] = { contact = contact, definition = definition }
        end,
      }
    end,
  }
  local call = PhoneCall.new({
    state = state,
    catalog = record.catalog,
    messages = messages,
    world = world,
    audio = instantAudio(),
    random = PokegearRandom.new(82),
  })
  local handle = call:begin({
    id = "oak-incoming-1",
    contact = "custom.oak",
    direction = "incoming",
    kind = "incoming",
  })
  for _ = 1, 12 do
    if call:result(handle) ~= nil then
      break
    end
    call:step(handle, { confirm = true })
  end
  local result = call:result(handle)
  Assert.notNil(result, "the source numeric Oak call reaches a terminal result")
  Assert.isNil(result.error, "the source numeric Oak call succeeds")
  Assert.equal(resolvedScript, 70, "the caller's frozen owned count selects the native incoming definition")
  Assert.equal(#effects, 1, "the numeric definition effect runs once at the source greeting stage")
  Assert.equal(effects[1].definition.param1, 26, "the numeric effect receives its compiled native parameter")
end

function T.tests.numeric_call_effect_is_not_published_when_its_selected_native_text_is_malformed()
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
  local manifest = fixtureManifest()
  manifest.catalog.contacts[#manifest.catalog.contacts + 1] = {
    key = "custom.oak",
    family = "oak",
    sortWeight = 60,
  }
  manifest.catalog.contactOrder[#manifest.catalog.contactOrder + 1] = "custom.oak"
  local record = assert(PokegearAssetSchema.validate(manifest), "Oak fixture validates")
  record.catalog.callDefinitions[70] = {
    id = 70,
    kind = "word",
    param0 = 4,
    param1 = 70,
    male = { bank = 641, entry = 70 },
    female = { bank = 641, entry = 70 },
  }
  local state = PokegearState.new({ seed = 82 }, catalogRefs(record))
  state:registerContact("custom.oak")
  local published = 0
  local trace = {}
  local random = PokegearRandom.new(82, { trace = trace })
  local randomBefore = random:capture()
  local messages = phoneMessages()
  messages.resolveLine = function()
    error({ code = "MESSAGE_MISSING", message = "native caller text is unavailable" }, 0)
  end
  local call = PhoneCall.new({
    state = state,
    catalog = record.catalog,
    messages = messages,
    world = {
      canCall = function()
        return true
      end,
      nativeSelectorFacts = function()
        return { localMap = false }
      end,
      callFacts = function()
        return { nationalDexOwned = 101 }
      end,
      prepareCallDefinitionEffect = function(_, _, _, effectRandom)
        local entry = 70 + effectRandom:lc("phone-word-entry") % 4
        return {
          substitutions = { wordEntry = entry },
          commit = function()
            published = published + 1
          end,
        }
      end,
    },
    audio = instantAudio(),
    random = random,
  })
  local handle = call:begin({
    id = "oak-malformed-text",
    contact = "custom.oak",
    direction = "incoming",
    kind = "incoming",
  })
  call:step(handle, { confirm = true })

  Assert.equal(published, 0, "an invalid native page publishes no numeric definition effect")
  Assert.deepEqual(random:capture(), randomBefore, "a failed native page restores both source random streams")
  Assert.deepEqual(trace, {}, "a failed native page removes its uncommitted draw trace")
  local result = call:result(handle)
  Assert.notNil(result, "malformed selected text fails the native call")
  Assert.notNil(result.error, "malformed selected text remains a terminal failure")
end

function T.tests.cancelling_a_live_phone_call_returns_an_unsuccessful_terminal_result()
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local record = assert(PokegearAssetSchema.validate(fixtureManifest()), "phone fixture validates")
  local state = PokegearState.new({ seed = 23 }, catalogRefs(record))
  state:registerContact("custom.trainer-plain")
  local call = PhoneCall.new({
    state = state,
    catalog = record.catalog,
    messages = phoneMessages(),
    world = {
      canCall = function()
        return true
      end,
      nativeSelectorFacts = function()
        return { localMap = false }
      end,
    },
    audio = instantAudio(),
  })
  local handle = call:begin({
    id = "cancel-live-call",
    contact = "custom.trainer-plain",
    direction = "outgoing",
    kind = "ordinary",
  })
  call:cancel(handle, "field-session-disposed")
  local result = call:result(handle)
  Assert.notNil(result, "cancelling a live call reports a terminal result")
  Assert.isFalse(result.signal ~= false, "cancellation is an unsuccessful terminal, not a completed call")
end

function T.tests.selector_owned_phone_effects_and_draws_roll_back_when_native_text_is_missing()
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
  local manifest = fixtureManifest()
  local cases = {
    {
      key = "custom.kenji",
      family = "kenji",
      direction = "outgoing",
      scriptId = 89,
      facts = { kenjiWaitDays = 0, kenjiActive = false, seeking = false, timeOfDay = 0 },
      effectMethod = "applyKenjiActiveEffect",
    },
    {
      key = "custom.irwin",
      family = "irwin",
      direction = "incoming",
      scriptId = 168,
      facts = {
        irwinInitialTrigger = true,
        badges = 16,
        plainBadge = false,
        fogBadge = false,
        marshBadge = false,
        risingBadge = false,
        irwinNationalBadgeMessageSeen = false,
        irwinMarshBadgeMessageSeen = false,
        irwinSnorlaxMessageSeen = false,
        irwinVermilionMessageSeen = false,
        irwinVermilionEvent = false,
        vermilionFlypoint = false,
        gameClear = false,
        irwinGameClearMessageSeen = false,
        radioTowerBeaten = false,
        rocketHideoutCleared = false,
        irwinHideoutMessageSeen = false,
        irwinUnknownProgress = false,
        irwinUnknownProgressMessageSeen = false,
        snorlaxMet = false,
      },
      effectMethod = "applyIrwinIncomingEffect",
    },
  }
  for _, case in ipairs(cases) do
    manifest.catalog.contacts[#manifest.catalog.contacts + 1] = {
      key = case.key,
      family = case.family,
      sortWeight = 60 + #manifest.catalog.contacts,
    }
    manifest.catalog.contactOrder[#manifest.catalog.contactOrder + 1] = case.key
  end
  local record = assert(PokegearAssetSchema.validate(manifest), "selector effect contacts validate")
  for _, case in ipairs(cases) do
    record.catalog.callDefinitions[case.scriptId] = {
      id = case.scriptId,
      kind = "none",
      male = { bank = 641, entry = case.scriptId },
      female = { bank = 641, entry = case.scriptId },
    }
    local state = PokegearState.new({ seed = 82 }, catalogRefs(record))
    state:registerContact(case.key)
    local effects = 0
    local messages = phoneMessages()
    messages.resolveLine = function()
      error({ code = "MESSAGE_MISSING", message = "native caller text is unavailable" }, 0)
    end
    local world = {
      canCall = function()
        return true
      end,
      nativeSelectorFacts = function()
        return { localMap = false }
      end,
      callFacts = function()
        return case.facts
      end,
    }
    world[case.effectMethod] = function()
      effects = effects + 1
    end
    local call = PhoneCall.new({
      state = state,
      catalog = record.catalog,
      messages = messages,
      world = world,
      audio = instantAudio(),
      random = PokegearRandom.new(82),
    })
    local handle = call:begin({
      id = "missing-text-" .. case.key,
      contact = case.key,
      direction = case.direction,
      kind = case.direction == "incoming" and "incoming" or "ordinary",
    })
    call:step(handle, { confirm = true })
    Assert.equal(effects, 0, case.family .. " selection publishes no source effect before valid text")
    local result = call:result(handle)
    Assert.notNil(result and result.error, case.family .. " missing text remains a failed terminal")
  end

  local irwin = cases[2]
  irwin.direction = "outgoing"
  irwin.facts = { rocketTakeoverActive = false }
  local outgoingManifest = fixtureManifest()
  outgoingManifest.catalog.contacts[#outgoingManifest.catalog.contacts + 1] = {
    key = irwin.key,
    family = irwin.family,
    sortWeight = 70,
  }
  outgoingManifest.catalog.contactOrder[#outgoingManifest.catalog.contactOrder + 1] = irwin.key
  local outgoingCatalog = assert(PokegearAssetSchema.validate(outgoingManifest), "Irwin outgoing catalog validates")
  for scriptId = 172, 174 do
    outgoingCatalog.catalog.callDefinitions[scriptId] = {
      id = scriptId,
      kind = "none",
      male = { bank = 641, entry = scriptId },
      female = { bank = 641, entry = scriptId },
    }
  end
  local state = PokegearState.new({ seed = 82 }, catalogRefs(outgoingCatalog))
  state:registerContact(irwin.key)
  local trace = {}
  local random = PokegearRandom.new(82, { trace = trace })
  local randomBefore = random:capture()
  local messages = phoneMessages()
  messages.resolveLine = function()
    error({ code = "MESSAGE_MISSING", message = "native caller text is unavailable" }, 0)
  end
  local call = PhoneCall.new({
    state = state,
    catalog = outgoingCatalog.catalog,
    messages = messages,
    world = {
      canCall = function()
        return true
      end,
      nativeSelectorFacts = function()
        return { localMap = false }
      end,
      callFacts = function()
        return { rocketTakeoverActive = false }
      end,
    },
    audio = instantAudio(),
    random = random,
  })
  local handle = call:begin({
    id = "missing-text-irwin-outgoing",
    contact = irwin.key,
    direction = "outgoing",
    kind = "ordinary",
  })
  call:step(handle, { confirm = true })
  Assert.deepEqual(random:capture(), randomBefore, "failed Irwin text restores its selector draw")
  Assert.deepEqual(trace, {}, "failed Irwin text removes its uncommitted selector trace")
end

function T.tests.generic_type_two_uses_its_definition_and_one_phrase_draw()
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "generic caller fixture validates through the asset schema")
  assert(record ~= nil, "generic caller fixture validated above")
  local trainer = nil
  for _, contact in ipairs(record.catalog.contacts) do
    if contact.key == "custom.trainer-plain" then
      trainer = contact
    end
  end
  trainer = assert(trainer, "generic trainer contact exists")
  local rows = { { type = 1, chance = 100, scriptId = 10, scriptType = 2 } }
  for _ = 2, 8 do
    rows[#rows + 1] = { type = 0, chance = 100, scriptId = 0, scriptType = 0 }
  end
  trainer.genericCallHeaders = { incoming = rows, outgoing = rows }
  record.catalog.callDefinitions[10] = {
    id = 10,
    kind = "none",
    male = { bank = 641, entry = 10 },
    female = { bank = 641, entry = 10 },
  }
  local state = PokegearState.new({ seed = 21 }, catalogRefs(record))
  state:registerContact("custom.trainer-plain")
  local randomTrace = {}
  local random = PokegearRandom.new(21, { trace = randomTrace })
  local chosenScriptType = nil
  local chosenVariation = nil
  local messages = phoneMessages()
  messages.resolveLine = function(_, _, _, scriptType, variation)
    chosenScriptType = scriptType
    chosenVariation = variation
    return { tokens = { { kind = "glyph", code = 1, text = "G", raw = { 1 } } } }
  end
  local call = PhoneCall.new({
    state = state,
    catalog = record.catalog,
    messages = messages,
    world = {
      canCall = function()
        return true
      end,
      nativeSelectorFacts = function()
        return { localMap = false }
      end,
    },
    audio = instantAudio(),
    random = random,
  })
  local handle =
    call:begin({ id = "generic-type-two", contact = "custom.trainer-plain", direction = "outgoing", kind = "ordinary" })
  call:step(handle, { confirm = true })
  Assert.equal(call:view(handle).stage, "message", "generic type two resolves a native phrase page")
  Assert.equal(chosenScriptType, 2, "the frozen header script type reaches native rendering")
  Assert.equal(
    chosenVariation,
    randomTrace[#randomTrace].value % 11,
    "generic type two selects one phrase with its source draw"
  )
end

function T.tests.generic_type_one_resolves_native_species_buffers_before_its_definition_page()
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "generic caller fixture validates through the asset schema")
  assert(record ~= nil, "generic caller fixture validated above")
  local trainer = nil
  for _, contact in ipairs(record.catalog.contacts) do
    if contact.key == "custom.trainer-plain" then
      trainer = contact
    end
  end
  trainer = assert(trainer, "generic trainer contact exists")
  local rows = { { type = 1, chance = 100, scriptId = 10, scriptType = 1 } }
  for _ = 2, 8 do
    rows[#rows + 1] = { type = 0, chance = 100, scriptId = 0, scriptType = 0 }
  end
  trainer.genericCallHeaders = { incoming = rows, outgoing = rows }
  record.catalog.callDefinitions[10] = {
    id = 10,
    kind = "none",
    male = { bank = 641, entry = 10 },
    female = { bank = 641, entry = 10 },
  }
  local state = PokegearState.new({ seed = 22 }, catalogRefs(record))
  state:registerContact("custom.trainer-plain")
  local order = {}
  local nativeNames = nil
  local messages = phoneMessages()
  messages.resolveLine = function(_, _, _, scriptType, _, substitutions)
    order[#order + 1] = "page"
    nativeNames = substitutions
    Assert.equal(scriptType, 1, "generic type one reaches its source text handler")
    return { tokens = { { kind = "glyph", code = 1, text = "G", raw = { 1 } } } }
  end
  local world = {
    canCall = function()
      return true
    end,
    nativeSelectorFacts = function()
      return { localMap = false }
    end,
    genericTrainerSubstitutions = function(_, _, random, timeOfDay)
      Assert.equal(timeOfDay, 1, "generic trainer rendering uses the call's frozen time of day")
      random:lc("generic-trainer-mon")
      random:lc("generic-wild-encounter-slot")
      order[#order + 1] = "buffers"
      return { [10] = "PIKACHU", [11] = "RATTATA" }
    end,
    callFacts = function()
      return { timeOfDay = 1 }
    end,
  }
  local call = PhoneCall.new({
    state = state,
    catalog = record.catalog,
    messages = messages,
    world = world,
    audio = instantAudio(),
    random = PokegearRandom.new(22),
  })
  local handle =
    call:begin({ id = "generic-type-one", contact = "custom.trainer-plain", direction = "outgoing", kind = "ordinary" })
  for _ = 1, 8 do
    call:step(handle, { confirm = true })
    if call:view(handle).stage == "message" then
      break
    end
  end
  Assert.deepEqual(order, { "buffers", "page" }, "species buffers are selected before resolving the native page")
  Assert.deepEqual(
    nativeNames,
    { [10] = "PIKACHU", [11] = "RATTATA" },
    "both native species variables reach formatting"
  )
end

function T.tests.field_runtime_selects_generic_type_one_species_with_native_slots_and_draws()
  local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
  local draws = {}
  local lookup = nil
  local land = {}
  for slot = 1, 12 do
    land[slot] = { species = "LAND_" .. slot }
  end
  local goodRod = {}
  for slot = 1, 5 do
    goodRod[slot] = { species = "FISH_" .. slot }
  end
  local runtime = setmetatable({
    _trainerCatalog = {
      _trainers = {
        [41] = { party = { { species = "PIKACHU" }, { species = "EEVEE" } } },
      },
    },
    mapLoader = {
      load = function(_, mapId)
        return { fieldData = { wildEncounterMemberId = mapId + 100 } }
      end,
    },
    _encounterCatalog = {
      tableFor = function(_, memberId, options)
        lookup = { memberId = memberId, options = options }
        return { land = { morning = land, day = land, night = land }, goodRod = goodRod }
      end,
    },
    monCatalog = {
      species = function(_, species)
        return { name = "NAME_" .. species }
      end,
    },
    versionId = "heartgold",
  }, FieldRuntime)
  local random = {
    lc = function(_, label)
      draws[#draws + 1] = label
      return #draws == 1 and 1 or 11
    end,
  }
  local contact = { trainerId = 41, trainerClass = 10, mapId = 6 }
  local substitutions = runtime:genericTrainerPhoneSpecies(contact, 1, random)
  Assert.deepEqual(
    substitutions,
    { [10] = "NAME_EEVEE", [11] = "NAME_LAND_12" },
    "type one buffers selected trainer and daytime land species"
  )
  Assert.deepEqual(
    draws,
    { "generic-trainer-mon", "generic-wild-encounter-slot" },
    "native type one consumes trainer then encounter draws"
  )
  Assert.equal(lookup.memberId, 106, "the caller's native map chooses its encounter member")
  Assert.equal(lookup.options.timeOfDay, "day", "the native time selector reaches encounter data")
  Assert.equal(lookup.options.rod, nil, "ordinary trainers use the land encounter slots")
  Assert.equal(#land, 12, "ordinary type-one calls keep twelve native land slots")

  draws = {}
  local fisherman = { trainerId = 41, trainerClass = 11, mapId = 9 }
  random.lc = function(_, label)
    draws[#draws + 1] = label
    return #draws == 1 and 0 or 2
  end
  substitutions = runtime:genericTrainerPhoneSpecies(fisherman, 2, random)
  Assert.equal(substitutions[11], "NAME_FISH_3", "night Fisherman call selects its third good-rod slot")
  Assert.equal(lookup.options.rod, "good_rod", "Fisherman calls request the native good-rod table")
  Assert.equal(lookup.options.timeOfDay, "night", "Fisherman lookup carries native night context")
  Assert.equal(#goodRod, 5, "the good-rod table retains five source slots")
  Assert.deepEqual(
    draws,
    { "generic-trainer-mon", "generic-wild-encounter-slot" },
    "Fisherman calls keep the two source draws"
  )

  runtime.mapLoader.load = function(_, mapId)
    return { fieldData = { wildEncounterMemberId = 255 } }
  end
  runtime._encounterCatalog.tableFor = function()
    error("the absent native encounter member uses only the source Rattata fallback")
  end
  draws = {}
  random.lc = function(_, label)
    draws[#draws + 1] = label
    return 1
  end
  substitutions = runtime:genericTrainerPhoneSpecies(contact, 0, random)
  Assert.equal(substitutions[11], "NAME_RATTATA", "missing encounter member resolves the source fallback species")
  Assert.deepEqual(draws, { "generic-trainer-mon" }, "the Rattata fallback consumes no encounter slot draw")
end

function T.tests.oak_special_program_runs_native_choice_counts_rating_and_acknowledgment_once()
  local ProfessorPhonePrograms = require("game.hgss.src.pokegear.phone.ProfessorPhonePrograms")
  local writes = {}
  local world = {
    setOakAcknowledged = function(_, dex)
      writes[#writes + 1] = dex
    end,
  }
  local nativeFacts = {
    nationalDexUnlocked = true,
    acknowledgedJohto = false,
    johtoComplete = true,
    nationalComplete = false,
    johtoSeen = 114,
    johtoOwned = 251,
    johtoRatingEntry = 18,
    playerGender = 0,
  }
  local session = ProfessorPhonePrograms.selectOakNativeSession(world, {
    contact = "custom.oak",
    decision = { mode = "special", scriptType = 5, family = "oak" },
    nativeFacts = nativeFacts,
  })
  Assert.deepEqual(session.entries, { 13, 15 }, "Oak opens with the native gendered page and second page")
  Assert.deepEqual(session.choices, { "johto", "national" }, "Oak presents its source-selected dex menu")
  Assert.equal(ProfessorPhonePrograms.step(session, {}), "waiting", "Oak waits for a menu selection")
  Assert.equal(
    ProfessorPhonePrograms.step(session, { choice = "johto" }),
    "continue",
    "the selected dex opens its count page"
  )
  Assert.equal(session.responseEntry, 20, "Oak prints the native count entry before its rating")
  Assert.equal(#writes, 0, "Oak does not acknowledge a completion before the count page is read")
  Assert.equal(
    ProfessorPhonePrograms.step(session, { responseResolved = true }),
    "continue",
    "the count page leads to its native rating"
  )
  Assert.equal(session.responseEntry, 18, "the frozen source rating resolves to its message entry")
  Assert.deepEqual(writes, {}, "Oak defers acknowledgment until its rating text resolves")
  session.responseEffect()
  session.responseEffect = nil
  Assert.deepEqual(writes, { "johto" }, "Oak acknowledges the completed selected dex after rating validation")
  Assert.equal(
    ProfessorPhonePrograms.step(session, { responseResolved = true }),
    "done",
    "Oak finishes after the rating page"
  )
  Assert.deepEqual(writes, { "johto" }, "repeated completion does not repeat Oak's acknowledgment effect")
end

function T.tests.phone_call_executes_oak_special_bank_pages_choice_and_effect()
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
  local manifest = fixtureManifest()
  manifest.catalog.contacts[#manifest.catalog.contacts + 1] = {
    key = "custom.oak",
    family = "oak",
    sortWeight = 60,
  }
  manifest.catalog.contactOrder[#manifest.catalog.contactOrder + 1] = "custom.oak"
  local record = PokegearAssetSchema.validate(manifest)
  Assert.notNil(record, "the synthetic Oak contact validates through the real asset schema")
  assert(record ~= nil, "synthetic Oak catalog validated above")
  local state = PokegearState.new({ seed = 82 }, catalogRefs(record))
  state:registerContact("custom.oak")
  local random = PokegearRandom.new(82)
  local resolvedEntries = {}
  local writes = {}
  local messages = phoneMessages()
  messages.resolveContactEntry = function(_, _, entry)
    resolvedEntries[#resolvedEntries + 1] = entry
    return { tokens = { { kind = "glyph", code = entry, text = tostring(entry), raw = { entry } } } }
  end
  local world = {
    canCall = function()
      return true
    end,
    nativeSelectorFacts = function()
      return { localMap = false }
    end,
    callFacts = function()
      return {
        nationalDexOwned = 101,
        nationalDexUnlocked = true,
        acknowledgedNational = false,
        acknowledgedJohto = false,
        playerGender = 0,
        johtoSeen = 114,
        johtoOwned = 251,
        johtoComplete = true,
        johtoRatingEntry = 18,
      }
    end,
    setOakAcknowledged = function(_, dex)
      writes[#writes + 1] = dex
    end,
  }
  local call = PhoneCall.new({
    state = state,
    catalog = record.catalog,
    messages = messages,
    world = world,
    audio = instantAudio(),
    random = random,
  })
  local handle = call:begin({
    id = "oak-special-1",
    contact = "custom.oak",
    direction = "outgoing",
    kind = "ordinary",
  })
  for _ = 1, 12 do
    if call:view(handle).stage == "choice" then
      break
    end
    call:step(handle, { confirm = true })
  end
  local choiceView = call:view(handle)
  Assert.equal(choiceView.stage, "choice", "Oak reaches its native Dex menu after its opening pages")
  Assert.deepEqual(resolvedEntries, { 13, 15 }, "Oak resolves its source bank entries in order")
  Assert.deepEqual(choiceView.choices, { "johto", "national" }, "the current source flags select the two-Dex menu")
  local otherChoiceView = call:view(handle)
  local randomBeforeReads = random:capture()
  local choices = choiceView.choices --[[@as string[] ]]
  choices[1] = "changed"
  table.insert(choices, "inserted")
  table.remove(choices, 2)
  Assert.deepEqual(
    otherChoiceView.choices,
    { "johto", "national" },
    "mutating one menu snapshot cannot alter another same-tick view"
  )
  local laterChoiceView = call:view(handle)
  Assert.deepEqual(
    laterChoiceView.choices,
    { "johto", "national" },
    "mutating a menu snapshot cannot alter the source-selected choices"
  )
  Assert.deepEqual(random:capture(), randomBeforeReads, "polling the menu consumes no random state")
  Assert.deepEqual(writes, {}, "polling the menu does not commit Oak's acknowledgment")
  call:step(handle, { choice = "johto" })
  Assert.equal(call:view(handle).lines[1].text, "20", "Oak's selected evaluation resolves its native counts entry")
  call:step(handle, { confirm = true })
  call:step(handle, { confirm = true })
  Assert.deepEqual(writes, { "johto" }, "Oak acknowledges completion after its counts page")
  Assert.equal(call:view(handle).lines[1].text, "18", "Oak resolves the frozen rating message")
  for _ = 1, 8 do
    if call:result(handle) ~= nil then
      break
    end
    call:step(handle, { confirm = true })
  end
  local result = call:result(handle)
  Assert.notNil(result, "Oak's native special call reaches a terminal result")
  Assert.isNil(result.error, "Oak's completed evaluation succeeds")
  Assert.deepEqual(
    resolvedEntries,
    { 13, 15, 20, 18 },
    "Oak's complete native conversation uses only its selected entries"
  )
  Assert.deepEqual(writes, { "johto" }, "repeated phone steps do not repeat the completion effect")
end

function T.tests.phone_call_does_not_acknowledge_oak_when_rating_text_is_invalid()
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local Errors = require("libs.errors.src.Errors")
  local manifest = fixtureManifest()
  manifest.catalog.contacts[#manifest.catalog.contacts + 1] = {
    key = "custom.oak",
    family = "oak",
    sortWeight = 60,
  }
  manifest.catalog.contactOrder[#manifest.catalog.contactOrder + 1] = "custom.oak"
  local record = PokegearAssetSchema.validate(manifest)
  Assert.notNil(record, "the synthetic Oak contact validates through the real asset schema")
  assert(record ~= nil, "synthetic Oak catalog validated above")
  local state = PokegearState.new({ seed = 83 }, catalogRefs(record))
  state:registerContact("custom.oak")
  local acknowledged = {}
  local messages = phoneMessages()
  messages.resolveContactEntry = function(_, _, entry)
    if entry == 18 then
      error(Errors.new("MESSAGE_MISSING", "Oak rating is absent", {
        source = { members = { 12, 18 } },
      }), 0)
    end
    return { tokens = { { kind = "glyph", code = entry, text = tostring(entry), raw = { entry } } } }
  end
  local call = PhoneCall.new({
    state = state,
    catalog = record.catalog,
    messages = messages,
    world = {
      canCall = function()
        return true
      end,
      nativeSelectorFacts = function()
        return { localMap = false }
      end,
      callFacts = function()
        return {
          nationalDexOwned = 101,
          nationalDexUnlocked = true,
          acknowledgedNational = false,
          acknowledgedJohto = false,
          playerGender = 0,
          johtoSeen = 114,
          johtoOwned = 251,
          johtoComplete = true,
          johtoRatingEntry = 18,
        }
      end,
      setOakAcknowledged = function(_, dex)
        acknowledged[#acknowledged + 1] = dex
      end,
    },
    audio = instantAudio(),
  })
  local handle =
    call:begin({ id = "oak-invalid-rating", contact = "custom.oak", direction = "outgoing", kind = "ordinary" })
  for _ = 1, 12 do
    if call:view(handle).stage == "choice" then
      break
    end
    call:step(handle, { confirm = true })
  end
  Assert.equal(call:view(handle).stage, "choice", "Oak opens its source Dex choice")
  call:step(handle, { choice = "johto" })
  call:step(handle, { confirm = true })

  local failedView = call:view(handle)
  local viewResult = failedView.result --[[@as table<string, unknown> ]]
  local viewError = viewResult.error --[[@as Errors.Error ]]
  local result = call:result(handle) --[[@as table<string, unknown> ]]
  local resultError = result.error --[[@as Errors.Error ]]
  Assert.notNil(result, "a missing rating produces a terminal call error")
  Assert.isTrue(Errors.is(viewError), "view preserves the structured error type")
  Assert.isTrue(Errors.is(resultError), "result preserves the structured error type")
  Assert.isFalse(viewError == resultError, "view and result return distinct structured errors")
  Assert.isFalse(viewError.context == resultError.context, "each error snapshot owns its context")
  Assert.equal(viewError.code, "MESSAGE_MISSING", "the terminal preserves Oak's message failure")
  Assert.deepEqual(viewError.context, { source = { members = { 12, 18 } } }, "the error retains nested context")
  viewError.context.source.members[1] = 99
  resultError.code = "CORRUPTED"
  local laterViewError = call:view(handle).result.error --[[@as Errors.Error ]]
  local laterResultError = call:result(handle).error --[[@as Errors.Error ]]
  Assert.equal(laterViewError.code, "MESSAGE_MISSING", "view mutation cannot change the owner error")
  Assert.equal(laterResultError.code, "MESSAGE_MISSING", "result mutation cannot change the owner error")
  Assert.deepEqual(
    laterViewError.context,
    { source = { members = { 12, 18 } } },
    "nested error context remains unchanged in later views"
  )
  Assert.deepEqual(
    laterResultError.context,
    { source = { members = { 12, 18 } } },
    "nested error context remains unchanged in later results"
  )
  Assert.equal(#acknowledged, 0, "an invalid rating does not publish Oak's acknowledgment")
  call:release(handle)
  Assert.equal(viewError.code, "MESSAGE_MISSING", "a retained error snapshot remains valid after release")
  Assert.throws(function()
    call:result(handle)
  end, "a released call rejects stale result reads")
end

function T.tests.phone_call_does_not_publish_mom_savings_choice_when_response_text_is_invalid()
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic Mom contact validates through the real asset schema")
  assert(record ~= nil, "synthetic Mom catalog validated above")
  local state = PokegearState.new({ seed = 84 }, catalogRefs(record))
  state:registerContact("custom.mom")
  local savingsChoice = false
  local messages = phoneMessages()
  messages.resolveContactEntry = function(_, _, entry)
    if entry == 25 then
      error({ code = "MESSAGE_MISSING", message = "Mom's savings response is absent" }, 0)
    end
    return { tokens = { { kind = "glyph", code = entry, text = tostring(entry), raw = { entry } } } }
  end
  local call = PhoneCall.new({
    state = state,
    catalog = record.catalog,
    messages = messages,
    world = {
      canCall = function()
        return true
      end,
      nativeSelectorFacts = function()
        return {
          localMap = false,
          gaveRivalName = true,
          talkedAfterNamingRival = true,
        }
      end,
      callFacts = function()
        return {
          momIntroParameter = 3,
          momSavingsBalance = 500,
          momSavingsActive = false,
          momGiftQueueFull = false,
        }
      end,
      setMomSavingsChoice = function(_, saving)
        savingsChoice = saving
      end,
    },
    audio = instantAudio(),
  })
  local handle =
    call:begin({ id = "mom-invalid-response", contact = "custom.mom", direction = "outgoing", kind = "ordinary" })
  for _ = 1, 24 do
    if call:view(handle).stage == "choice" then
      break
    end
    if call:result(handle) ~= nil then
      break
    end
    call:step(handle, { confirm = true })
  end
  Assert.equal(
    call:view(handle).stage,
    "choice",
    "Mom reaches the explicit savings choice before a terminal result "
      .. tostring((call:result(handle) or {}).error and (call:result(handle) or {}).error.message)
  )
  call:step(handle, { choice = "save" })

  local result = call:result(handle)
  Assert.notNil(result, "a missing savings response produces a terminal call error")
  Assert.equal(result.error.code, "MESSAGE_MISSING", "the terminal preserves Mom's message failure")
  Assert.isFalse(savingsChoice, "an invalid response does not publish Mom's savings flag")
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
    canCall = function()
      return true
    end,
    nativeSelectorFacts = function()
      return { localMap = false }
    end,
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
  Assert.equal(failure.domain, "phone", "the failure names the unsupported native phone handler")
  Assert.isNil(state:queryRematch("custom.kurt"), "the failed stage stages no persisted readiness")
  Assert.deepEqual(state:readPhone().triggers, {}, "the failed stage sets no trigger")

  -- The failed call released the line: the local numeric branch on the
  -- same contact completes without a service owner.
  world.nativeSelectorFacts = localPhoneSelectorFacts()
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
    ["hg.trainer.200.map.0.contact.0"] = "mother-23",
    ["hg.trainer.201.map.0.contact.1"] = "elm-1",
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

function T.tests.native_rematch_identity_uses_source_flags_and_unlocked_group_fallback()
  local Programs = require("game.hgss.src.pokegear.phone.TrainerPhonePrograms")
  local contact = { key = "trainer.joey", id = 10, trainerId = 100 }
  local catalog = {
    contacts = { contact },
    rematchSets = {
      [100] = { group = 4, trainers = { 100, 101, 102, 103, 0, 0 } },
    },
  }
  local defeated = { [101] = true, [102] = false }
  local world = {
    queryRematch = function()
      return { stage = 1, wins = 0 }
    end,
    trainerDefeated = function(_, trainerId)
      return defeated[trainerId] == true
    end,
    rematchGroupUnlocked = function(_, group)
      return group == 2
    end,
    timeOfDayWild = function()
      return 1
    end,
  }

  Assert.equal(Programs.nativeRematchTrainer(contact.key, world, catalog), 102,
    "the first undefeated native trainer is selected from the source row")
  Assert.equal(defeated[103], nil, "selection does not require later trainer flags")
end

return T
