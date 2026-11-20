-- Script service injection: the composed scheduler carries the travel
-- owner, the field-move runtime, and the live game-stats owner to the
-- tasks and operations that consume them. A set_spawn slice updates the
-- injected travel through the scheduler; a pending field_move slice reaches
-- the injected runtime; a source game-score slice credits the injected
-- stats owner. Override slices install through the override layer like any
-- source script. No planning vocabulary here.

local Assert = require("tests.support.Assert")
local BagSave = require("libs.hgss.src.save.BagSave")
local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FakeCache = require("tests.support.FakeCache")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local FieldScriptSliceFixture = require("tests.support.FieldScriptSliceFixture")
local FieldTravelState = require("libs.hgss.src.field.FieldTravelState")
local GameStats = require("libs.hgss.src.mons.GameStats")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local HoOhAppearanceFixture = require("tests.support.HoOhAppearanceFixture")
local ItemCatalog = require("libs.items.src.ItemCatalog")
local ItemFixture = require("libs.items.tests.item_fixture")
local LuaWriter = require("libs.codec.src.LuaWriter")
local MartSave = require("libs.hgss.src.save.MartSave")
local MartService = require("libs.hgss.src.items.MartService")
local MonNamingState = require("game.hgss.src.field.MonNamingState")
local PlayerData = require("libs.hgss.src.save.PlayerData")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local ScriptErrors = require("libs.script.src.errors")

local T = { tests = {} }

local composeSlice = FieldScriptSliceFixture.compose

-- A slice chunk serialized from a DSL step table: nested steps and value
-- descriptors travel exactly as authored instead of through a hand emitter.
local function encodedChunk(id, steps)
  return LuaWriter.encode({ api = 1, id = id, steps = steps })
end

-- The shared field naming host the production field wires into script
-- services, with the same controller, session, and generated charmap.
local function namingHost()
  return MonNamingState.new({
    effect = function() end,
    charmap = CatalogFixture.CHARMAP,
    measureDisplay = function()
      return {
        width = 800,
        height = 600,
        topology = ScreenTopology.oneDisplay({
          id = "main",
          rect = { x = 0, y = 0, width = 800, height = 600 },
          role = "world",
          touch = true,
        }),
        pixelRatio = 1,
        signature = "rival-naming:800x600",
      }
    end,
  })
end

-- The naming screen's own generated message bank: the source reads the
-- selected edition's FIRST_DEFAULT_NAME_RIVAL row from bank 254 when the
-- player commits an empty name (msg_0254_00084 under HeartGold). The provider
-- is the real one over a fake cache, so the task's default travels the same
-- generated-text path dialogue does.
---@param rivalDefaultText string the bank's rival default-name row
---@return FieldMessageProvider
local function namingMessageProvider(rivalDefaultText)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(FieldMessageCache.bankPath(254), {
    schema = FieldMessageCache.SCHEMA,
    bankId = 254,
    messageCount = 91,
    messages = {
      [84] = {
        id = 84,
        raw = { 0xFFFF },
        text = rivalDefaultText,
        tokens = { { kind = "eos", raw = { 0xFFFF } } },
      },
    },
  })
  return FieldMessageProvider.new(cache)
end

local SAVE_CONTEXT = { charmap = CatalogFixture.CHARMAP, frameIndexes = { [0] = true } }

-- The live saved player record, validated by its owning module.
local function savedPlayer(rivalName)
  return assert(PlayerData.validate({
    profile = {
      name = "GOLD",
      rivalName = rivalName,
      gender = 0,
      trainerId = 0,
      money = 3000,
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
  }, SAVE_CONTEXT))
end

-- Step the platform until the naming screen owns the field, bounded so a
-- missing block fails instead of spinning.
local function stepUntilNaming(platform, naming, firstTick)
  for index = 1, 32 do
    platform.scheduler:step(firstTick + index, nil)
    if naming:isActive() then
      return firstTick + index
    end
  end
  return nil
end

local function driveSlice(services, id, steps, tick)
  local platform = composeSlice(services, id, steps)
  local composed = assert(platform.composition:effective(id), "the slice must compose")
  platform.scheduler:createForeground(composed, nil, tick or 100)
  platform.scheduler:step(tick or 100, nil)
  return platform
end

function T.tests.set_spawn_updates_the_injected_travel_service()
  local travel = FieldTravelState.new({ lastHealSpawn = "SPAWN_NEW_BARK" })
  driveSlice({ travel = travel, fieldMoves = nil }, "test.travel_slice", {
    { op = "set_spawn", spawn = "SPAWN_GOLDENROD" },
  })
  Assert.equal(travel:capture().lastHealSpawn, "SPAWN_GOLDENROD", "set_spawn records on the injected travel owner")
end

function T.tests.set_special_spawn_writes_durable_copied_travel_state()
  local travel = FieldTravelState.new({ lastHealSpawn = "SPAWN_NEW_BARK" })
  driveSlice({ travel = travel, fieldMoves = nil }, "test.special_slice", {
    { op = "set_special_spawn", map = "MAP_NEW_BARK", fieldX = 688, fieldZ = 393, warpId = -1, direction = "south" },
  })
  Assert.deepEqual(travel:specialSpawn(), {
    map = "MAP_NEW_BARK",
    fieldX = 688,
    fieldZ = 393,
    warpId = -1,
    direction = "south",
  }, "opcode 582 writes the durable travel owner through the script maps service")
  Assert.deepEqual(travel:capture().specialSpawn, {
    map = "MAP_NEW_BARK",
    fieldX = 688,
    fieldZ = 393,
    warpId = -1,
    direction = "south",
  }, "the opcode-582 value survives travel capture")
end

-- A composed source score slice credits the live game-stats owner it was
-- wired with: nothing at composition time, once per executed command, on the
-- same saved score the trainer card reads.
function T.tests.script_score_slice_credits_the_injected_stats_owner()
  local stats = GameStats.new({ species = { CHIKORITA = true } })
  local platform = composeSlice({ travel = nil, fieldMoves = nil, gameStats = stats }, "test.score_slice", {
    { op = "game_score_event", event = 1 },
    { op = "game_score_event", event = 21 },
  })
  Assert.equal(stats:score(), 0, "composing a script scores nothing before it runs")
  local composed = assert(platform.composition:effective("test.score_slice"))
  platform.scheduler:createForeground(composed, nil, 100)
  platform.scheduler:step(100, nil)
  Assert.equal(stats:score(), 21, "one execution credits each source event's weight once")
  platform.scheduler:createForeground(composed, nil, 200)
  platform.scheduler:step(200, nil)
  Assert.equal(stats:score(), 42, "the next execution credits the events again")
  Assert.equal(stats:bucket().score, 42, "the credited score is the persisted score")
end

-- A score slice composed without a game-stats owner faults at the command
-- instead of succeeding through a scratch or per-script score. The scheduler
-- contains a structured fault on the running context, so the fault is
-- observed on the instance the foreground created: the slice ends there and
-- no composable owner is left to credit the event.
function T.tests.script_score_slice_faults_without_a_stats_owner()
  local platform = composeSlice({ travel = nil, fieldMoves = nil, gameStats = nil }, "test.score_missing", {
    { op = "game_score_event", event = 1 },
  })
  local composed = assert(platform.composition:effective("test.score_missing"))
  local instanceId = platform.scheduler:createForeground(composed, nil, 100)
  -- An ended root leaves the live set, so the test keeps the instance the
  -- foreground created and reads its terminal state after the step.
  local running = assert(platform.scheduler:instance(instanceId), "the score slice must start")
  platform.scheduler:step(100, nil)
  Assert.equal(running.status, "faulted", "a scripted score without a game-stats owner faults the script")
  Assert.equal(running.endReason, ScriptErrors.SCRIPT_SERVICE_MISSING, "the fault names the missing service")
  Assert.isNil(platform.scheduler:instance(instanceId), "the faulted score slice leaves no live script")
end

function T.tests.pending_field_move_reaches_the_injected_runtime()
  local takes = 0
  local fieldMoves = {
    takePending = function(_)
      takes = takes + 1
      error("no pending request queued", 0)
    end,
  }
  local ok, err = pcall(driveSlice, { travel = nil, fieldMoves = fieldMoves }, "test.moves_slice", {
    { op = "field_move", source = "pending" },
  })
  Assert.isFalse(ok, "an empty pending queue faults instead of succeeding")
  Assert.equal(takes, 1, "the task reads the injected runtime exactly once")
  Assert.isTrue(tostring(err):find("pending") ~= nil, "the fault names the missing queue: " .. tostring(err))
end

function T.tests.script_battle_launch_suspends_on_the_host_and_resumes_committed()
  local launches = {}
  local battleHost = {
    launchBattle = function(_, spec)
      launches[#launches + 1] = spec
      return "script-launch-1"
    end,
    battleStatus = function(_)
      return { phase = "complete", committed = true, result = "win", sourceResult = 1 }
    end,
    lastBattleResult = function(_)
      return { result = "win", sourceResult = 1 }
    end,
  }
  local platform = driveSlice({ travel = nil, fieldMoves = nil, battle = battleHost }, "test.battle_slice", {
    { op = "battle_launch" },
    { op = "battle_result" },
  })
  for _ = 1, 8 do
    platform.scheduler:step(100 + _, nil)
  end
  Assert.equal(#launches, 1, "the launch reaches the injected host exactly once")
  Assert.equal(launches[1].kind, "wild")
  Assert.equal(launches[1].details.species, "TOTODILE", "launch details evaluate before the host")
  local symbols = require("libs.assets.src.field.FieldScriptSymbols")
  Assert.equal(
    platform.worldState:getVar(symbols.variablesByName.VAR_TEMP_x4001),
    1,
    "the completed task writes its outcome code"
  )
  Assert.equal(
    platform.worldState:getVar(symbols.variablesByName.VAR_TEMP_x4002),
    1,
    "the script resumes on the committed result"
  )
end

-- The production Trainer Card service contributes no Frontier star: with
-- every flag set and a complete dex the count stops at four, and the
-- composition needs no runtime Frontier records owner to answer.
function T.tests.production_trainer_card_service_counts_no_frontier_star()
  local targetModule = "game.hgss.src.field.FieldScripts"
  local composeModule = "game.hgss.src.field.FieldScriptComposition"
  local seen = {}
  local double = {
    new = function(opts)
      seen.opts = opts
      return { scheduler = {}, worldState = {}, blackoutFlow = {}, moneyBox = {} }
    end,
  }
  local savedTarget = package.loaded[targetModule]
  local savedCompose = package.loaded[composeModule]
  package.loaded[targetModule] = double
  package.loaded[composeModule] = nil
  local ok, err = pcall(function()
    local compose = require(composeModule).compose
    local runtime = {
      applicationHost = {
        requestReopen = function() end,
      },
      applyAvatarTransitions = function()
        return {}
      end,
      _setLiveWeather = function() end,
      overrideFs = {},
      eventState = {
        setFlag = function() end,
      },
      pokedexCatalog = {},
      actors = {},
      player = {},
      playerAvatar = nil,
      playerData = { profile = {}, options = { textFrame = 0 } },
      versionId = "heartgold",
      runtimeMap = { mapId = 61 },
      actorConfig = {
        apricorn = {
          depletedTreeSpriteId = 262,
          treeSpriteIdByKey = {
            RED_APRICORN = 263,
            YLW_APRICORN = 264,
            BLU_APRICORN = 265,
            GRN_APRICORN = 266,
            PNK_APRICORN = 267,
            WHT_APRICORN = 268,
            BLK_APRICORN = 269,
          },
          fruitSpriteIdByKey = {
            RED_APRICORN = 270,
            YLW_APRICORN = 271,
            BLU_APRICORN = 272,
            GRN_APRICORN = 273,
            PNK_APRICORN = 274,
            WHT_APRICORN = 275,
            BLK_APRICORN = 276,
          },
        },
      },
      overworld = {
        phase = function()
          return "present"
        end,
      },
      fieldTerrainEffectController = {},
      scriptHosts = nil,
      screenFade = require("libs.hgss.src.transition.FieldScriptScreenFade").new(),
      auxiliaryFieldUi = {},
      contextChoiceProvider = {},
      menuHost = {},
      dialogue = {},
      messageProvider = {},
      signpost = {},
      windowStyles = {},
      transition = {},
      mapLoader = {},
      kurtBoxHost = {},
      easyChatCatalog = {},
      easyChatState = {},
      pokegearRandom = {},
      easyChatScriptHost = {},
      dexKnowledge = {
        isNationalDexComplete = function()
          return true
        end,
        countSeen = function()
          return 0
        end,
        countCaught = function()
          return 0
        end,
        prepareChanges = function()
          error("the star-count stub never stages dex changes", 0)
        end,
      },
      scripts = {
        worldState = {
          isFlagSet = function()
            return true
          end,
        },
      },
      fashionCase = {},
    }
    local result = compose(runtime, {
      cacheFs = {
        loadLua = function()
          return HoOhAppearanceFixture.core()
        end,
      },
      layoutMessage = function(message)
        return message
      end,
      fontDef = {},
      audioService = {
        play = function() end,
        playMusic = function() end,
        playCry = function() end,
        stop = function() end,
        moveSequenceVolume = function() end,
      },
      followerInteractionCatalog = {},
      followerReactionTicks = {},
      mons = {},
      itemCatalog = {},
      followingMon = {},
      clock = {},
    })
    Assert.notNil(result.scripts, "composition still yields its scripts")
    local service = assert(seen.opts and seen.opts.trainerCardStars, "composition wires the star service")
    Assert.equal(service.count(), 4, "every flag plus a complete dex still counts no Frontier star")
  end)
  package.loaded[targetModule] = savedTarget
  package.loaded[composeModule] = savedCompose
  if not ok then
    error(err, 0)
  end
end

local CHARMAP = { G = 305, O = 313, L = 310, D = 302 }
local FRAME_INDEXES = { [0] = true }

-- The captured player record is the authoritative saved wallet: the profile
-- bucket GameSave persists, validated with the generated font metadata.
local function capturePlayerRecord(profile)
  return assert(PlayerData.validate({
    profile = {
      name = "GOLD",
      rivalName = "GOLD",
      gender = profile.gender,
      trainerId = 0,
      money = profile.money,
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
  }, { charmap = CHARMAP, frameIndexes = FRAME_INDEXES }))
end

-- A real mart over the same profile the scripts mutate: one affordable
-- consumable, no mocks of the transaction owner.
local function martOver(profile)
  local root = ItemFixture.buildAssetRoot()
  root.items.POTION.price = 30
  local itemCatalog = ItemCatalog.new(root)
  local bag = HgssBagService.new({ catalog = itemCatalog, bag = BagSave.empty() })
  local service = MartService.new({
    profile = profile,
    bag = bag,
    itemCatalog = itemCatalog,
    catalog = { cards = {}, apricorns = {}, seals = {}, decorations = {} },
    bucket = MartSave.empty(),
  })
  return service, bag
end

local function potionStock()
  return {
    key = "money-slice-stock",
    currency = "money",
    presentationKind = "items",
    quantityMode = "multiple",
    bonusPolicy = "none",
    entries = {
      {
        key = "potion",
        displayItemKey = "POTION",
        description = { kind = "item" },
        unitPrice = 30,
        destination = { kind = "bag", key = "POTION" },
        restriction = { kind = "none" },
      },
    },
  }
end

-- The source money family moves the one live profile wallet: the immediate
-- and variable forms saturate instead of underflowing, the money check reports
-- affordability without touching the balance, and every other consumer of the
-- wallet (the mart, the captured save) sees the same balance.
function T.tests.script_money_slice_moves_the_one_live_wallet()
  local profile = { gender = 0, name = "Gold", badges = {}, money = 100 }
  local platform = composeSlice({ profile = profile }, "test.money_slice", {
    { op = "money_change", action = "add", amount = 999999 },
    { op = "money_change", action = "subtract", amount = 1000000 },
    { op = "money_change", action = "add", amount = 100 },
    { op = "set_var", variable = "VAR_TEMP_x4001", value = 40 },
    { op = "money_change", action = "subtract", amount = "VAR_TEMP_x4001" },
    { op = "money_check", amount = 1000, result = "VAR_TEMP_x4002" },
    { op = "money_check", amount = 60, result = "VAR_TEMP_x4002" },
    -- The source reads the amount before it writes the result pointer, so one
    -- variable may hold both: the check answers the pre-write value.
    { op = "set_var", variable = "VAR_TEMP_x4002", value = 70 },
    { op = "money_check", amount = "VAR_TEMP_x4002", result = "VAR_TEMP_x4002" },
    { op = "set_var", variable = "VAR_TEMP_x4002", value = 60 },
    { op = "money_check", amount = "VAR_TEMP_x4002", result = "VAR_TEMP_x4002" },
  })
  local composed = assert(platform.composition:effective("test.money_slice"), "the money slice must compose")
  local instanceId = platform.scheduler:createForeground(composed, nil, 100)
  platform.scheduler:step(100, nil)
  local variables = require("libs.assets.src.field.FieldScriptSymbols").variablesByName
  Assert.equal(profile.money, 60, "the wallet ends where the source arithmetic puts it")
  Assert.equal(
    platform.worldState:getVar(variables.VAR_TEMP_x4002),
    1,
    "the aliased money check reports the balance it was asked about"
  )
  Assert.isNil(platform.scheduler:instance(instanceId), "every source money command ran in the one stepped tick")

  -- Saturation is checked in both directions, separately from the journey
  -- balance: adding far past the cap stops at 999999 and subtracting past the
  -- balance stops at zero instead of failing.
  local capProfile = { gender = 0, name = "Gold", badges = {}, money = 999999 }
  local cap = composeSlice({ profile = capProfile }, "test.money_cap", {
    { op = "money_change", action = "add", amount = 1 },
  })
  cap.scheduler:createForeground(assert(cap.composition:effective("test.money_cap")), nil, 100)
  cap.scheduler:step(100, nil)
  Assert.equal(capProfile.money, 999999, "the added money saturates at the source wallet cap")

  local emptyProfile = { gender = 0, name = "Gold", badges = {}, money = 0 }
  local empty = composeSlice({ profile = emptyProfile }, "test.money_empty", {
    { op = "money_change", action = "subtract", amount = 500 },
  })
  empty.scheduler:createForeground(assert(empty.composition:effective("test.money_empty")), nil, 100)
  empty.scheduler:step(100, nil)
  Assert.equal(emptyProfile.money, 0, "an unaffordable source subtraction saturates at zero instead of failing")
end

-- The wallet the scripts moved is the wallet the mart transacts on and the
-- wallet the save record carries; a restored profile answers the same money
-- check the live one did.
function T.tests.script_money_balance_is_the_mart_and_save_balance()
  local profile = { gender = 0, name = "Gold", badges = {}, money = 100 }
  driveSlice({ profile = profile }, "test.money_wallet", {
    { op = "money_change", action = "add", amount = 60 },
  })
  Assert.equal(profile.money, 160, "the script credits the live profile")

  local service, bag = martOver(profile)
  local session = assert(service:openBuy(potionStock()))
  local token = assert(session:quoteBuy("potion", 2))
  Assert.notNil(session:commit(token))
  Assert.equal(profile.money, 100, "the mart debits the same profile the script credited")
  Assert.equal(bag:quantity("POTION"), 2, "the purchase lands in the live Bag")
  Assert.equal(session:view().balance, 100, "the mart reads the post-purchase balance")
  session:close()

  local captured = capturePlayerRecord(profile)
  Assert.equal(captured.profile.money, 100, "the captured player record carries the live balance")
  profile.money = 55
  Assert.equal(captured.profile.money, 100, "the captured record is a snapshot, not a live alias")
  Assert.equal(profile.money, 55)

  local restoredPlatform = composeSlice({ profile = captured.profile }, "test.money_restored", {
    { op = "money_check", amount = 100, result = "VAR_TEMP_x4003" },
    { op = "money_check", amount = 101, result = "VAR_TEMP_x4004" },
  })
  restoredPlatform.scheduler:createForeground(
    assert(restoredPlatform.composition:effective("test.money_restored")),
    nil,
    100
  )
  restoredPlatform.scheduler:step(100, nil)
  local variables = require("libs.assets.src.field.FieldScriptSymbols").variablesByName
  Assert.equal(
    restoredPlatform.worldState:getVar(variables.VAR_TEMP_x4003),
    1,
    "the restored wallet affords the saved balance"
  )
  Assert.equal(
    restoredPlatform.worldState:getVar(variables.VAR_TEMP_x4004),
    0,
    "the restored wallet affords nothing beyond it"
  )
end

-- The source money box draws a captured balance: opening pins the current
-- money, wallet changes do not repaint it, an explicit update does, and hiding
-- frees the window so a later show opens a fresh one.
function T.tests.script_money_box_keeps_its_display_until_an_explicit_update()
  local profile = { gender = 0, name = "Gold", badges = {}, money = 150 }
  local platform = composeSlice(
    { profile = profile, messageProvider = FieldScriptSliceFixture.moneyMessageProvider() },
    "test.money_box",
    {
      { op = "money_box", action = "show", tileX = 3, tileY = 5 },
      { op = "yield_tick" },
      { op = "money_change", action = "subtract", amount = 40 },
      { op = "yield_tick" },
      { op = "money_box", action = "update" },
      { op = "yield_tick" },
      { op = "money_box", action = "hide" },
      { op = "yield_tick" },
      { op = "money_box", action = "show", tileX = 1, tileY = 2 },
    }
  )
  local box = assert(platform.moneyBox, "the composed field owns one source money box host")
  platform.scheduler:createForeground(assert(platform.composition:effective("test.money_box")), nil, 100)
  local tick = 100
  local function step()
    platform.scheduler:step(tick, nil)
    tick = tick + 1
  end

  step()
  local shown = assert(box:snapshot(), "an open money box reports its presentation snapshot")
  Assert.isTrue(shown.visible, "the opened window is visible")
  Assert.equal(shown.tileX, 3, "the window opens at the source tile column")
  Assert.equal(shown.tileY, 5, "the window opens at the source tile row")
  Assert.equal(shown.label, "MONEY", "the first row is the source bank label")
  Assert.equal(shown.displayedMoney, 150, "opening captures the live balance")

  step()
  Assert.equal(profile.money, 110, "the wallet moves while the box stays open")
  Assert.equal(box:snapshot().displayedMoney, 150, "the drawn balance does not follow the wallet")

  step()
  Assert.equal(box:snapshot().displayedMoney, 110, "an explicit update repaints the current balance")

  step()
  Assert.isFalse(box:snapshot().visible, "hiding closes the window")

  step()
  local reopened = assert(box:snapshot())
  Assert.isTrue(reopened.visible, "a later show opens the window again")
  Assert.equal(reopened.tileX, 1, "the reopened window uses the new source column")
  Assert.equal(reopened.tileY, 2, "the reopened window uses the new source row")
  Assert.equal(reopened.displayedMoney, 110, "the reopened window captures the current balance")

  -- Field teardown closes the transient window; it is presentation state and
  -- never outlives the field that created it.
  box:dispose()
  Assert.isFalse(box:snapshot().visible, "field teardown closes the source window")
end

-- A money box command with no open window is a script-state fault, not a quiet
-- success: the field never keeps a stale window alive across commands.
function T.tests.script_money_box_faults_without_an_open_window()
  local function faultedBy(steps, id)
    local platform = composeSlice({}, id, steps)
    local composed = assert(platform.composition:effective(id), "the box slice must compose")
    local instanceId = platform.scheduler:createForeground(composed, nil, 100)
    local running = assert(platform.scheduler:instance(instanceId), "the box slice must start")
    platform.scheduler:step(100, nil)
    platform.scheduler:step(101, nil)
    return running
  end

  local missing = faultedBy({ { op = "money_box", action = "update" } }, "test.money_box_missing")
  Assert.equal(missing.status, "faulted", "an update with no open window faults the script")
  Assert.isTrue(type(missing.endReason) == "string", "the fault is attributed: " .. tostring(missing.endReason))

  local twice = faultedBy({
    { op = "money_box", action = "show", tileX = 0, tileY = 0 },
    { op = "money_box", action = "show", tileX = 1, tileY = 1 },
  }, "test.money_box_twice")
  Assert.equal(twice.status, "faulted", "a second show cannot open a second window")

  local ghost = faultedBy({
    { op = "money_box", action = "show", tileX = 0, tileY = 0 },
    { op = "money_box", action = "hide" },
    { op = "yield_tick" },
    { op = "money_box", action = "hide" },
  }, "test.money_box_ghost")
  Assert.equal(ghost.status, "faulted", "hiding an already closed window faults instead of keeping it alive")
end

-- Retail `include/constants/flags.h::TRAINER_FLAG_BASE`.
local TRAINER_FLAG_BASE = 0x550

local function submitRivalName(platform, tick, name)
  local events = {}
  for _ = 1, 7 do
    events[#events + 1] = { type = "cancel" }
  end
  events[#events + 1] = { type = "text", text = name }
  platform.scheduler:step(tick, { uiEvents = events })
  platform.scheduler:step(tick + 1, { uiEvents = { { type = "name_control", id = "ok" } } })
end

-- Poll until the naming host releases the field, running an optional
-- observation after every step; returns the release tick or nil.
local function stepUntilNamingClosed(platform, naming, firstTick, observe)
  for index = 1, 40 do
    platform.scheduler:step(firstTick + index, nil)
    if observe ~= nil then
      observe()
    end
    if not naming:isActive() then
      return firstTick + index
    end
  end
  return nil
end

local function battleHost(outcome)
  local launches = {}
  local sourceResult = outcome == "win" and 1 or 0
  return {
    launchBattle = function(_, spec)
      launches[#launches + 1] = spec
      return "script-launch-1"
    end,
    battleStatus = function()
      return { phase = "complete", committed = true, result = outcome, sourceResult = sourceResult }
    end,
    lastBattleResult = function()
      return { result = outcome, sourceResult = sourceResult }
    end,
  },
    launches
end

-- A composed rival battle: the script launches its own battle, branches on
-- the committed result, and only the winning branch flags the trainer and
-- runs the source rival naming wait.
local function rivalBattleSteps()
  return {
    {
      op = "battle_launch",
      kind = "trainer",
      details = { trainer = 3 },
      result = { value = "var", id = "VAR_TEMP_x4001" },
    },
    { op = "battle_result", result = { value = "var", id = "VAR_TEMP_x4001" } },
    {
      op = "if",
      condition = {
        condition = "compare",
        operator = "eq",
        left = { value = "var", id = "VAR_TEMP_x4001" },
        right = 1,
      },
      yes = {
        { op = "set_flag", flag = { value = "trainer_flag_id", trainer = 3 } },
        { op = "rival_naming", result = { value = "var", id = "VAR_TEMP_x4003" } },
        { op = "set_var", variable = "VAR_TEMP_x4002", value = 1 },
      },
      no = {
        { op = "set_var", variable = "VAR_TEMP_x4002", value = 2 },
      },
    },
  }
end

-- The source rival-naming wait runs the one shared field naming screen and
-- publishes the accepted name to the live saved profile; the script resumes
-- only after the screen closes.
function T.tests.rival_naming_blocks_then_publishes_the_accepted_name_to_the_saved_profile()
  local record = savedPlayer("SILVER")
  local naming = namingHost()
  local platform = composeSlice(
    {
      travel = nil,
      fieldMoves = nil,
      monNaming = naming,
      profile = record.profile,
      versionId = "heartgold",
      messageProvider = namingMessageProvider("SOUL"),
      fontDef = { charmap = CatalogFixture.CHARMAP },
      encode = encodedChunk,
    },
    "test.rival_naming",
    {
      { op = "rival_naming", result = { value = "var", id = "VAR_TEMP_x4003" } },
      { op = "set_var", variable = "VAR_TEMP_x4002", value = 7 },
    }
  )
  local composed = assert(platform.composition:effective("test.rival_naming"), "the rival naming slice must compose")
  local instanceId = platform.scheduler:createForeground(composed, nil, 100)
  local running = assert(platform.scheduler:instance(instanceId))
  local openedAt = assert(stepUntilNaming(platform, naming, 100), "the script blocks on the naming screen")
  Assert.equal(running.status, "blocked", "the script instance blocks on the naming task")
  Assert.notNil(running.waitingTaskId, "the blocking task owns the script continuation")
  Assert.equal(record.profile.rivalName, "SILVER", "the saved rival name is untouched before acceptance")
  Assert.equal(platform.worldState:getVar("VAR_TEMP_x4002"), 0, "no script step runs behind the naming screen")

  submitRivalName(platform, openedAt + 1, "SOUL")
  Assert.equal(record.profile.rivalName, "SILVER", "editing the name publishes nothing yet")
  local closedAt = assert(
    stepUntilNamingClosed(platform, naming, openedAt + 2, function()
      Assert.equal(
        platform.worldState:getVar("VAR_TEMP_x4002"),
        0,
        "the script resumes only after the naming screen closes"
      )
    end),
    "the naming screen settles after its OK press"
  )
  for index = 1, 3 do
    platform.scheduler:step(closedAt + index, nil)
  end

  Assert.isFalse(naming:isActive(), "the modal released the field")
  Assert.equal(record.profile.rivalName, "SOUL", "the accepted name lands on the live saved profile")
  Assert.equal(platform.player:rivalName(), "SOUL", "dialogue reads the new rival name immediately")
  Assert.equal(
    platform.worldState:getVar("VAR_TEMP_x4003"),
    0,
    "the source result variable receives the accepted result code"
  )
  Assert.equal(platform.worldState:getVar("VAR_TEMP_x4002"), 7, "the resumed script ran to its end")

  local captured = assert(PlayerData.validate({ profile = record.profile, options = record.options }, SAVE_CONTEXT))
  Assert.equal(captured.profile.rivalName, "SOUL", "the captured save carries the new rival name")
  platform.player:setProfile(captured.profile)
  Assert.equal(platform.player:rivalName(), "SOUL", "a reloaded save still shows the new rival name")
end

-- The blank-entry default is the generated message text: the composition
-- reads the naming screen's own bank row through the field message provider
-- and the task commits exactly that text. The row here holds a name the retail
-- rows do not, so the committed default proves source-data dependence rather
-- than a runtime literal.
function T.tests.blank_rival_name_commits_the_generated_source_default()
  local record = savedPlayer("SILVER")
  local naming = namingHost()
  local platform = composeSlice(
    {
      travel = nil,
      fieldMoves = nil,
      monNaming = naming,
      profile = record.profile,
      versionId = "heartgold",
      messageProvider = namingMessageProvider("LANCE"),
      fontDef = { charmap = CatalogFixture.CHARMAP },
      encode = encodedChunk,
    },
    "test.rival_default_name",
    {
      { op = "rival_naming", result = { value = "var", id = "VAR_TEMP_x4003" } },
      { op = "set_var", variable = "VAR_TEMP_x4002", value = 7 },
    }
  )
  local composed =
    assert(platform.composition:effective("test.rival_default_name"), "the rival default-name slice must compose")
  platform.scheduler:createForeground(composed, nil, 100)
  local openedAt = assert(stepUntilNaming(platform, naming, 100), "the script blocks on the naming screen")

  submitRivalName(platform, openedAt + 1, "")
  Assert.equal(record.profile.rivalName, "SILVER", "an empty entry publishes nothing before the screen settles")
  local closedAt =
    assert(stepUntilNamingClosed(platform, naming, openedAt + 2), "the naming screen settles after its OK press")
  for index = 1, 3 do
    platform.scheduler:step(closedAt + index, nil)
  end

  Assert.isFalse(naming:isActive(), "the modal released the field")
  Assert.equal(record.profile.rivalName, "LANCE", "the generated default name lands on the live saved profile")
  Assert.equal(platform.player:rivalName(), "LANCE", "dialogue reads the committed default immediately")
  Assert.equal(
    platform.worldState:getVar("VAR_TEMP_x4003"),
    0,
    "the source result variable receives the accepted result code"
  )
  Assert.equal(platform.worldState:getVar("VAR_TEMP_x4002"), 7, "the resumed script ran to its end")
end

-- The live name write re-checks the saved-profile name contract, so a name the
-- generated field font cannot encode -- or one outside the 1..7-glyph limit --
-- faults before it reaches the profile or any later save capture.
function T.tests.rival_name_write_rejects_unusable_names_and_keeps_the_profile()
  local record = savedPlayer("SILVER")
  local platform = composeSlice({
    travel = nil,
    fieldMoves = nil,
    profile = record.profile,
    fontDef = { charmap = CatalogFixture.CHARMAP },
    encode = encodedChunk,
  }, "test.rival_name_write", { { op = "set_var", variable = "VAR_TEMP_x4002", value = 1 } })
  -- The generated charmap holds the uppercase letters and only the lowercase
  -- glyphs the default rival name uses, so "o" and "u" are unencodable.
  for _, rejected in ipairs({ "Soul", "", "TOOLONGNAME" }) do
    local err = Assert.throws(function()
      platform.player:setRivalName(rejected)
    end)
    Assert.equal(
      err and err.code,
      "PLAYER_DATA_NAME_INVALID",
      "rival name " .. tostring(rejected) .. " must be rejected"
    )
    Assert.equal(record.profile.rivalName, "SILVER", "a rejected name leaves the live profile untouched")
    Assert.equal(platform.player:rivalName(), "SILVER", "the script-visible rival name stays the accepted one")
  end
  platform.player:setRivalName("SOUL")
  Assert.equal(record.profile.rivalName, "SOUL", "an encodable name inside the limit is published")
end

-- A scripted rival battle keeps its supported launch and outcome: the
-- script-owned branch decides the trainer flag and the following naming, and
-- a loss neither awards a flag nor opens the naming screen.
function T.tests.rival_battle_outcome_gates_the_trainer_flag_and_the_following_naming()
  local record = savedPlayer("SILVER")
  local winHost, winLaunches = battleHost("win")
  local winNaming = namingHost()
  local platform = composeSlice({
    travel = nil,
    fieldMoves = nil,
    battle = winHost,
    monNaming = winNaming,
    profile = record.profile,
    versionId = "heartgold",
    messageProvider = namingMessageProvider("SOUL"),
    fontDef = { charmap = CatalogFixture.CHARMAP },
    encode = encodedChunk,
  }, "test.rival_battle", rivalBattleSteps())
  local composed = assert(platform.composition:effective("test.rival_battle"), "the rival battle slice must compose")
  local instanceId = platform.scheduler:createForeground(composed, nil, 300)
  local running = assert(platform.scheduler:instance(instanceId))
  local openedAt = assert(stepUntilNaming(platform, winNaming, 300), "the winning branch reaches rival naming")
  Assert.equal(running.status, "blocked", "the script still blocks on the naming task")
  Assert.notNil(running.waitingTaskId, "the naming task owns the script continuation")
  Assert.equal(#winLaunches, 1, "the script launched its own rival battle once")
  Assert.equal(winLaunches[1].kind, "trainer")
  Assert.isTrue(platform.worldState:isFlagSet(TRAINER_FLAG_BASE + 3), "the winning branch flags the defeated trainer")
  Assert.equal(platform.worldState:getVar("VAR_TEMP_x4002"), 0, "naming blocks before the following script step")

  submitRivalName(platform, openedAt + 1, "SOUL")
  local closedAt = assert(stepUntilNamingClosed(platform, winNaming, openedAt + 2), "the naming screen settles")
  for index = 1, 3 do
    platform.scheduler:step(closedAt + index, nil)
  end
  Assert.equal(record.profile.rivalName, "SOUL", "the winning branch named the rival")
  Assert.equal(platform.worldState:getVar("VAR_TEMP_x4002"), 1, "the winning branch ran to its end")

  local lostRecord = savedPlayer("SILVER")
  local lostHost, lostLaunches = battleHost("loss")
  local lostNaming = namingHost()
  local lostPlatform = composeSlice({
    travel = nil,
    fieldMoves = nil,
    battle = lostHost,
    monNaming = lostNaming,
    profile = lostRecord.profile,
    fontDef = { charmap = CatalogFixture.CHARMAP },
    encode = encodedChunk,
  }, "test.rival_battle", rivalBattleSteps())
  local lostComposed = assert(lostPlatform.composition:effective("test.rival_battle"))
  lostPlatform.scheduler:createForeground(lostComposed, nil, 500)
  for index = 1, 32 do
    lostPlatform.scheduler:step(500 + index, nil)
  end
  Assert.equal(#lostLaunches, 1, "the losing branch still runs the scripted battle")
  Assert.isFalse(
    lostPlatform.worldState:isFlagSet(TRAINER_FLAG_BASE + 3),
    "a lost battle awards no trainer flag by itself"
  )
  Assert.isFalse(lostNaming:isActive(), "the losing branch never opens the naming screen")
  Assert.equal(lostRecord.profile.rivalName, "SILVER", "the losing branch keeps the saved rival name")
  Assert.equal(lostPlatform.worldState:getVar("VAR_TEMP_x4002"), 2, "the losing branch ran to its end")
  Assert.isFalse(FieldEventState.new():isFlagSet(TRAINER_FLAG_BASE + 3), "a new game carries no defeated trainer")
end

-- A composed dynamic-warp slice writes the durable destination on the
-- injected travel owner, keeps the special spawn separate, and answers the
-- floor from the pinned source map table in the same tick.
function T.tests.script_dynamic_warp_slice_writes_the_durable_destination_and_reads_its_floor()
  local travel = FieldTravelState.new({ lastHealSpawn = "SPAWN_NEW_BARK" })
  local special = { map = "MAP_NEW_BARK", fieldX = 688, fieldZ = 393, warpId = -1, direction = "south" }
  local platform = composeSlice(
    {
      travel = travel,
      fieldMoves = nil,
      mapLoader = {
        mapSymbol = function(_, mapId)
          Assert.equal(mapId, 40, "the source map id resolves through the injected map loader")
          return "MAP_GOLDENROD_DEPARTMENT_STORE_1F"
        end,
      },
    },
    "test.dynamic_warp_slice",
    {
      { op = "set_special_spawn", map = special.map, fieldX = 688, fieldZ = 393, warpId = -1, direction = "south" },
      { op = "set_dynamic_warp", map = 40, warpId = 0, fieldX = 5, fieldZ = 6, direction = "north" },
      { op = "get_dynamic_warp_floor" },
    }
  )
  Assert.isNil(travel:dynamicWarp(), "composing a script records no destination")
  local composed = assert(platform.composition:effective("test.dynamic_warp_slice"))
  platform.scheduler:createForeground(composed, nil, 100)
  platform.scheduler:step(100, nil)

  Assert.deepEqual(travel:dynamicWarp(), {
    map = "MAP_GOLDENROD_DEPARTMENT_STORE_1F",
    warpId = 0,
    fieldX = 5,
    fieldZ = 6,
    direction = "north",
  }, "the composed command reaches the durable travel owner")
  Assert.deepEqual(travel:specialSpawn(), special, "the composed special spawn keeps its own value")
  local symbols = require("libs.assets.src.field.FieldScriptSymbols")
  Assert.equal(
    platform.worldState:getVar(symbols.variablesByName.VAR_TEMP_x4001),
    1,
    "the source department-store floor table answers the query"
  )
end

-- The generated floor-label bank the source floor box reads, in the shape the
-- message cache publishes: msg_0191_00016 is the window title, 00017 is the
-- substitution template the script's buffered floor text fills, and
-- 00116..00122 are the source storey labels (1F..6F, B1F). The provider is the
-- real one, so the composed window resolves through the same path dialogue does.
local FLOOR_WINDOW_MESSAGES = {
  [16] = "Current Floor",
  [17] = "{STRVAR_1 50, 0, 0}",
  [116] = "1F",
  [117] = "2F",
  [118] = "3F",
  [119] = "4F",
  [120] = "5F",
  [121] = "6F",
  [122] = "B1F",
  [125] = "ROOF",
}

---@return table<string, unknown> provider, table<string, unknown> fontDef
local function floorWindowMessageSource()
  local charmap = {}
  local code = 0x0400
  for _, text in pairs(FLOOR_WINDOW_MESSAGES) do
    for index = 1, #text do
      local char = text:sub(index, index)
      if charmap[char] == nil then
        charmap[char] = code
        code = code + 1
      end
    end
  end
  local fontDef = { charmap = charmap }
  local messages = {}
  for messageId, text in pairs(FLOOR_WINDOW_MESSAGES) do
    messages[messageId] = {
      id = messageId,
      raw = {},
      text = text,
      tokens = FieldMessageText.parse(text, fontDef, { eos = true }),
    }
  end
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(FieldMessageCache.bankPath(191), {
    schema = FieldMessageCache.SCHEMA,
    bankId = 191,
    messageCount = 126,
    source = { narc = "NARC_msgdata_msg", memberId = 191, memberSha1 = "synthetic" },
    messages = messages,
  })
  return FieldMessageProvider.new(cache), fontDef
end

-- A composed floor-window slice shows the source window through the composed
-- host: the service supplies the live map's label table and the script's
-- buffered floor text, the command never writes the observed result variable,
-- and the field's own tick releases the window once the script writes the
-- closing sentinel.
function T.tests.script_floor_window_slice_observes_its_result_variable()
  local symbols = require("libs.assets.src.field.FieldScriptSymbols")
  local provider, fontDef = floorWindowMessageSource()
  local platform = composeSlice(
    {
      travel = FieldTravelState.new({ lastHealSpawn = "SPAWN_NEW_BARK" }),
      fieldMoves = nil,
      sourceMap = {
        mapSymbol = "MAP_GOLDENROD_DEPARTMENT_STORE_ELEVATOR",
        fieldData = { mapId = 7, scriptBankId = 3, initScripts = {} },
      },
      messageProvider = provider,
      fontDef = fontDef,
      encode = encodedChunk,
    },
    "test.floor_window_slice",
    {
      { op = "buffer_text", slot = 0, value = { text = "dept_store_floor_no", floor = 4 } },
      { op = "floor_window_show", tileX = 4, tileY = 5, floor = 4, result = { value = "var", id = "VAR_TEMP_x4001" } },
    }
  )
  local composed = assert(platform.composition:effective("test.floor_window_slice"))
  platform.scheduler:createForeground(composed, nil, 100)
  platform.scheduler:step(100, nil)

  local snapshot = assert(platform.floorWindow:snapshot(), "the composed command shows the source window")
  Assert.equal(snapshot.map, "MAP_GOLDENROD_DEPARTMENT_STORE_ELEVATOR", "the window carries the live map identity")
  Assert.equal(snapshot.tileX, 4)
  Assert.equal(snapshot.tileY, 5)
  Assert.equal(snapshot.labelMessage, "msg.hgss.0191.00017", "a numbered floor resolves the ordinary floor label")
  Assert.equal(snapshot.title, "Current Floor", "the window draws the source title text")
  Assert.equal(snapshot.label, "4F", "the label substitutes the floor text the script buffered")
  local resultId = symbols.variablesByName.VAR_TEMP_x4001
  Assert.equal(platform.worldState:getVar(resultId), 0, "the composing command never writes the observed variable")

  platform.worldState:setVar(resultId, 0xFFFF)
  platform.scheduler:step(101, nil)
  Assert.isNil(platform.floorWindow:snapshot(), "the field tick releases the window on the sentinel")
end

-- A composed clock slice answers the field hour from the injected local clock
-- and keeps running in the same tick.
function T.tests.script_clock_hour_slice_reads_the_injected_field_clock()
  local travel = FieldTravelState.new({ lastHealSpawn = "SPAWN_NEW_BARK" })
  local platform = composeSlice(
    {
      travel = travel,
      fieldMoves = nil,
      clock = {
        nowLocal = function()
          return { year = 2000, month = 1, day = 2, hour = 23, minute = 30 }
        end,
      },
    },
    "test.clock_slice",
    {
      { op = "field_clock_hour" },
      { op = "set_spawn", spawn = "SPAWN_GOLDENROD" },
    }
  )
  local composed = assert(platform.composition:effective("test.clock_slice"))
  platform.scheduler:createForeground(composed, nil, 100)
  platform.scheduler:step(100, nil)

  local symbols = require("libs.assets.src.field.FieldScriptSymbols")
  Assert.equal(
    platform.worldState:getVar(symbols.variablesByName.VAR_TEMP_x4002),
    23,
    "the composed field clock answers the source hour"
  )
  Assert.equal(travel:capture().lastHealSpawn, "SPAWN_GOLDENROD", "the following command runs in the same tick")
end

return T
