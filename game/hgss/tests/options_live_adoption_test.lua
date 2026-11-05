-- Live player-options adoption through the real field composition: preparing
-- changed values validates without mutating, one application publishes the
-- six fields into the live record, and the next dialogue, signpost, script
-- and menu uses observe the committed speed and frame without any reload.
-- Busy owners refuse preparation, an abandoned preparation changes nothing,
-- and a consumed or stale application faults. No options screen exists on
-- this path. Headless: layouts, audio, message and display collaborators
-- are deterministic stubs, every controller and menu object is production.

local Assert = require("tests.support.Assert")
local BadgeSets = require("tests.support.BadgeSets")
local BagCursor = require("libs.hgss.src.items.BagCursor")
local BagPresentationFixture = require("tests.support.BagPresentationFixture")
local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local FieldDialogueController = require("libs.hgss.src.ui.FieldDialogueController")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldMenuCompositionCoordinator = require("game.hgss.src.field.FieldMenuCompositionCoordinator")
local FieldSignpostController = require("libs.hgss.src.interaction.FieldSignpostController")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldYesNoController = require("libs.hgss.src.ui.FieldYesNoController")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local ItemFixture = require("libs.items.tests.item_fixture")
local Mailbox = require("libs.hgss.src.save.Mailbox")
local PhotoAlbum = require("libs.hgss.src.save.PhotoAlbum")
local PlayerData = require("libs.hgss.src.save.PlayerData")
local ScriptDialogueHost = require("libs.hgss.src.script.ScriptDialogueHost")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local StarterChoiceState = require("game.hgss.src.starters.StarterChoiceState")
local TextSpeedPolicy = require("libs.hgss.src.ui.TextSpeedPolicy")

local T = {
  metadata = { tags = { "options", "adoption" } },
  tests = {},
}

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
local CURSOR = { cycle = { 0, 1, 2, 1 }, framePrinterTicks = 9 }
local GLYPH_COUNT = 12
local SIGN_GLYPHS = 6

local function glyph(text, code)
  return { kind = "glyph", code = code, text = text, raw = { code } }
end

local function dialoguePages()
  local tokens = {}
  for index = 1, GLYPH_COUNT do
    tokens[#tokens + 1] = glyph("A", index)
  end
  return { { lines = { { tokens = tokens, width = 0 } }, breakKind = "eos" } }
end

local function dialogueMessage()
  local tokens = {}
  for index = 1, GLYPH_COUNT do
    tokens[#tokens + 1] = glyph("A", index)
  end
  return { bankId = 543, messageId = 5, text = "", tokens = tokens, hadUnresolvedSubstitutions = false }
end

local function signLines()
  local tokens = {}
  for index = 1, SIGN_GLYPHS do
    tokens[#tokens + 1] = glyph("B", index)
  end
  return { { tokens = tokens } }
end

local function signMessage()
  local lines = signLines()
  local tokens = {}
  for _, line in ipairs(lines) do
    for _, token in ipairs(line.tokens) do
      tokens[#tokens + 1] = token
    end
  end
  return { bankId = 543, messageId = 6, text = "", tokens = tokens, hadUnresolvedSubstitutions = false, _lines = lines }
end

local function nullAudio()
  return { play = function() end }
end

local function openDialogue(policy)
  return FieldDialogueController.new({
    layout = function()
      return { pages = dialoguePages(), warnings = {}, lineHeight = 16, lineSpacing = 0 }
    end,
    policy = policy,
    audio = nullAudio(),
    continueCursor = CURSOR,
  })
end

local function openSignpost(policy)
  return FieldSignpostController.new({
    layout = function(message)
      return { lines = message._lines or signLines() }
    end,
    policy = policy,
  })
end

local function messageProvider()
  local provider = {}
  function provider:acquireBank(_)
    return true
  end
  function provider:get(bankId, messageId)
    return { bankId = bankId, messageId = messageId, text = "Yes", tokens = { glyph("A", 1) } }
  end
  function provider:format(template)
    return { tokens = template.tokens, text = template.text, hadUnresolvedSubstitutions = false }
  end
  function provider:releaseBank(_) end
  return provider
end

local function playerFacade()
  return {
    name = function()
      return "GOLD"
    end,
    rivalName = function()
      return "HIKARI"
    end,
    gender = function()
      return 0
    end,
  }
end

local function scriptLayout()
  return function()
    return { pages = dialoguePages(), warnings = {}, lineHeight = 16, lineSpacing = 0 }
  end
end

local function openScriptHost(dialogue, frameIndex)
  return ScriptDialogueHost.new({
    controller = dialogue,
    yesNoController = FieldYesNoController.new({ audio = nullAudio() }),
    provider = messageProvider(),
    layout = scriptLayout(),
    fontDef = { charmap = CHARMAP },
    player = playerFacade(),
    frameIndex = frameIndex,
  })
end

local function stubMeasurement()
  return {
    width = 256,
    height = 192,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      touch = true,
      role = "world",
    }),
    pixelRatio = 1,
    signature = "options-adoption-test:256x192",
  }
end

local function openStarter(frameIndex)
  return StarterChoiceState.new({
    catalog = CatalogFixture.makeCatalog(),
    cacheFs = CacheFs.forVersion("heartgold", FakeCache.new()),
    frameIndex = frameIndex,
    measureDisplay = stubMeasurement,
  })
end

local function openMons()
  local catalog = CatalogFixture.makeCatalog()
  local Lcrng = require("libs.mons.src.gen4.Lcrng")
  local MonsSave = require("libs.mons.src.MonsSave")
  local Party = require("libs.mons.src.Party")
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local mons = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(41):capture()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  })
  Assert.isTrue(
    mons:giveMon({
      species = "CHIKORITA",
      level = 5,
      heldItem = "NONE",
      form = 0,
      location = 7,
      date = CatalogFixture.metDate(),
    }),
    "setup gift must enter the party"
  )
  return mons
end

local function pcManifest()
  local stationery = {}
  for stationeryType = 0, 11 do
    stationery[stationeryType] = { itemKey = "MAIL_" .. stationeryType }
  end
  return {
    schema = "g4-pc-v3",
    mailbox = { background = {}, geometry = { visibleLetters = 10 }, pageSize = 10 },
    mail = { stationery = stationery, geometry = { iconSlots = 3 }, text = { templates = {} }, wordDictionary = {} },
  }
end

-- The composed harness: a validated live player record beside the real
-- dialogue, signpost, script and starter owners plus the production menu
-- composition whose per-open policy closure reads the live options.
local function openHarness()
  local playerData = assert(PlayerData.validate({
    profile = {
      name = "GOLD",
      rivalName = "HIKARI",
      gender = 0,
      trainerId = 0,
      money = 3000,
      badges = BadgeSets.empty(),
      nationalDex = false,
      runningShoes = false,
      runningShoesLock = false,
    },
    options = {
      textSpeed = "mid",
      textFrame = 0,
      battleStyle = "shift",
      battleScene = true,
      soundMode = "stereo",
      battleSpeed = 1,
    },
  }, { charmap = CHARMAP, frameIndexes = FRAME_INDEXES }))
  local dialogue = openDialogue(TextSpeedPolicy.forSpeed("mid"))
  local signpost = openSignpost(TextSpeedPolicy.forSpeed("mid"))
  local host = openScriptHost(dialogue, 0)
  local starter = openStarter(0)
  local harness
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local Composition = require("game.hgss.src.field.PartyMenuComposition")
  local composition = Composition.create({
    mons = openMons(),
    bag = bag,
    bagCursor = BagCursor.new(),
    itemCatalog = bag:catalog(),
    monCatalog = CatalogFixture.makeCatalog(),
    mailbox = Mailbox.new(),
    photoAlbum = PhotoAlbum.new(),
    pcManifest = pcManifest(),
    bagManifest = BagPresentationFixture.manifest(),
    partyManifest = {},
    uiManifest = FieldUiFixture.manifest(),
    profile = playerData.profile,
    versionId = "heartgold",
    cacheFs = {},
    derivedAssets = {},
    charmap = CatalogFixture.CHARMAP,
    heroGender = "male",
    measureDisplay = stubMeasurement,
    prepareIcons = function(_)
      return true
    end,
    cancelIconPreparation = function() end,
    contextSources = function()
      return {}
    end,
    worldPorts = {
      actors = {
        getActor = function()
          return nil
        end,
        actorsOf = function()
          return {}
        end,
        getPosition = function()
          return nil
        end,
        partnerId = function()
          return nil
        end,
        getCollisionAt = function()
          return nil
        end,
        beginScriptedAction = function() end,
        advanceScriptedAction = function() end,
        commitScriptedAction = function() end,
        cancelScriptedMovement = function() end,
        isScriptedMoving = function()
          return false
        end,
        removePresence = function() end,
        syncEventStateChanges = function() end,
      },
      events = {
        setFlag = function() end,
        isFlagSet = function()
          return false
        end,
      },
      maps = {
        current = function()
          return { symbol = "test-map", id = 61, fieldUse = {} }
        end,
        runtimeMap = function()
          return {}
        end,
      },
      player = {
        position = function()
          return { fieldX = 4, fieldZ = 5, worldY = 0 }
        end,
        facing = function()
          return "south"
        end,
        beginScriptedAction = function() end,
        advanceScriptedAction = function() end,
        commitScriptedAction = function() end,
        cancelScriptedMovement = function() end,
        isScriptedMoving = function()
          return false
        end,
        queueAvatarTransition = function() end,
        applyAvatarTransitions = function() end,
      },
      profile = { badges = BadgeSets.all() },
      weather = {
        change = function() end,
      },
      reactions = {
        dispatch = function() end,
      },
    },
    textPolicyForOpen = function()
      return TextSpeedPolicy.forSpeed(assert(harness.playerData.options.textSpeed))
    end,
  })
  harness = {
    playerData = playerData,
    playerDataContext = { charmap = CHARMAP, frameIndexes = FRAME_INDEXES },
    dialogue = dialogue,
    signpost = signpost,
    scripts = { dialogueHost = host },
    starterChoice = starter,
    partyMenu = composition,
  }
  harness.coordinator = FieldMenuCompositionCoordinator.new(harness)
  return harness
end

local function changedOptions()
  return {
    textSpeed = "fastest",
    textFrame = 1,
    battleStyle = "set",
    battleScene = false,
    soundMode = "mono",
    battleSpeed = 4,
  }
end

local function changedOptionsWith(overrides)
  local value = changedOptions()
  for key, item in pairs(overrides) do
    value[key] = item
  end
  return value
end

local function stepsToDone(dialogue, limit)
  for _ = 1, limit do
    local status = dialogue:status()
    if status.state == "WAITING_CLOSE" or status.state == "CLOSING" or status.state == "CLOSED" then
      return true
    end
    dialogue:step({})
  end
  local status = dialogue:status()
  return status.state == "WAITING_CLOSE" or status.state == "CLOSING" or status.state == "CLOSED"
end
-- One adopted preparation reaches every next use: the next dialogue,
-- signpost, and script request observe the committed speed and frame,
-- later choice prompts carry the committed frame, and future menu
-- children capture the current policy at creation. A single harness
-- boot covers the whole adoption fan-out.
function T.tests.adopted_values_reach_every_next_use_without_a_reload()
  local harness = openHarness()
  harness.dialogue:open({ id = "baseline", message = dialogueMessage(), allowCancel = false, frameIndex = 0 })
  Assert.isFalse(stepsToDone(harness.dialogue, 4), "the mid cadence must still be revealing after four steps")
  harness.dialogue:close()
  local before = harness.partyMenu
  Assert.deepEqual(
    TextSpeedPolicy.forSpeed(harness.playerData.options.textSpeed),
    TextSpeedPolicy.forSpeed("mid"),
    "the harness opens on the committed mid policy"
  )
  local attempt = assert(harness.coordinator:preparePlayerOptions(changedOptions()))
  attempt.apply()
  harness.dialogue:open({ id = "adopted", message = dialogueMessage(), allowCancel = false, frameIndex = 1 })
  Assert.isTrue(stepsToDone(harness.dialogue, 4), "the committed fastest cadence finishes the same text quickly")
  harness.dialogue:close()
  harness.signpost:printTyped(signMessage())
  for _ = 1, 2 do
    harness.signpost:updateFixed({})
  end
  Assert.isTrue(harness.signpost:isPrintDone(), "the committed fastest cadence completes the typed sign quickly")
  harness.signpost:finishPrint()
  harness.scripts.dialogueHost:startPrint("msg.hgss.1.2", {}, {})
  local status = harness.dialogue:status()
  Assert.equal(status.frameIndex, 1, "the next script request carries the committed frame")
  Assert.isTrue(stepsToDone(harness.dialogue, 4), "the script request reveals at the committed cadence")
  harness.dialogue:close()
  local options = harness.scripts.dialogueHost:yesNoOptions()
  Assert.equal(options.frameIndex, 1, "later choice prompts carry the committed frame")
  local flow = before.makeBagFlow()
  Assert.notNil(flow, "menu flows still construct after adoption")
  local BagScreenState = require("game.hgss.src.field.BagScreenState")
  local fresh = TextSpeedPolicy.forSpeed(harness.playerData.options.textSpeed)
  Assert.deepEqual(fresh, TextSpeedPolicy.forSpeed("fastest"))
  local child = BagScreenState.new({
    service = HgssBagService.new({ catalog = ItemFixture.makeCatalog() }),
    cursor = BagCursor.new(),
    manifest = BagPresentationFixture.manifest(),
    uiManifest = FieldUiFixture.manifest(),
    monCatalog = CatalogFixture.makeCatalog(),
    heroGender = "male",
    measureDisplay = stubMeasurement,
    context = "field",
    partyEmpty = true,
    effect = function() end,
    textPolicy = fresh,
  })
  Assert.notNil(child:status(), "a child built from the current policy opens normally")
  child:dispose()
  before.dispose()
end


function T.tests.preparation_validates_without_mutating_and_applies_exactly_once()
  local harness = openHarness()
  local before = PlayerData.validate(
    { profile = harness.playerData.profile, options = harness.playerData.options },
    harness.playerDataContext
  )
  Assert.deepEqual(before.options, {
    textSpeed = "mid",
    textFrame = 0,
    battleStyle = "shift",
    battleScene = true,
    soundMode = "stereo",
    battleSpeed = 1,
  })
  local profileIdentity = harness.playerData.profile
  local optionsIdentity = harness.playerData.options
  local broken, err = harness.coordinator:preparePlayerOptions(changedOptionsWith({ battleSpeed = 8 }))
  Assert.isNil(broken, "an invalid candidate never prepares")
  Assert.isTrue(Errors.is(err), "an invalid candidate reports a structured failure")
  Assert.deepEqual(harness.playerData.options, before.options, "a refused preparation mutates nothing")
  local attempt = assert(harness.coordinator:preparePlayerOptions(changedOptions()))
  Assert.deepEqual(harness.playerData.options, before.options, "preparation alone mutates nothing")
  attempt.apply()
  Assert.isTrue(rawequal(harness.playerData.profile, profileIdentity), "adoption keeps the live profile identity")
  Assert.isTrue(rawequal(harness.playerData.options, optionsIdentity), "adoption keeps the live options table")
  Assert.deepEqual(harness.playerData.options, changedOptions())
  Assert.equal(harness.playerData.profile.money, 3000, "adoption touches options, never the profile")
  Assert.throws(function()
    attempt.apply()
  end, "a consumed application faults instead of publishing twice")
  local revalidated = assert(
    PlayerData.validate(
      { profile = harness.playerData.profile, options = harness.playerData.options },
      harness.playerDataContext
    )
  )
  Assert.deepEqual(revalidated.options, changedOptions(), "the live record revalidates after adoption")
  local settled = PlayerData.prepareBattleChanges(
    { profile = harness.playerData.profile, options = harness.playerData.options },
    harness.playerDataContext,
    { moneyDelta = 100 }
  )
  Assert.deepEqual(settled.options, changedOptions(), "reward settlement preserves every adopted value")
  harness.partyMenu.dispose()
end

-- Ownership contention refuses without mutation: an abandoned preparation
-- and a record replacement fault the stale application, busy owners
-- refuse preparation, and idle setters reject retouching active owners.
-- One harness (plus the starter probe) covers the contention matrix.
function T.tests.ownership_contention_refuses_without_mutation()
  local harness = openHarness()
  local snapshot = {
    textSpeed = "mid",
    textFrame = 0,
    battleStyle = "shift",
    battleScene = true,
    soundMode = "stereo",
    battleSpeed = 1,
  }
  assert(harness.coordinator:preparePlayerOptions(changedOptions()))
  Assert.deepEqual(harness.playerData.options, snapshot, "abandoning a preparation changes nothing")
  local stale = assert(harness.coordinator:preparePlayerOptions(changedOptions()))
  harness.playerData = {
    profile = harness.playerData.profile,
    options = {
      textSpeed = "mid",
      textFrame = 0,
      battleStyle = "shift",
      battleScene = true,
      soundMode = "stereo",
      battleSpeed = 1,
    },
  }
  Assert.throws(function()
    stale.apply()
  end, "an application after a record replacement faults before writing")
  -- Busy owners refuse preparation while live.
  harness.dialogue:open({ id = "held", message = dialogueMessage(), allowCancel = false, frameIndex = 0 })
  local busy, err = harness.coordinator:preparePlayerOptions(changedOptions())
  Assert.isNil(busy, "an open dialogue refuses preparation")
  Assert.isTrue(Errors.is(err), "a busy owner reports a structured failure")
  harness.dialogue:close()
  harness.signpost:printTyped(signMessage())
  local signBusy, signErr = harness.coordinator:preparePlayerOptions(changedOptions())
  Assert.isNil(signBusy, "a live signpost print refuses preparation")
  Assert.isTrue(Errors.is(signErr), "a live sign reports a structured failure")
  harness.signpost:finishPrint()
  harness.scripts.dialogueHost:startPrint("msg.hgss.1.2", {}, {})
  local scriptBusy = harness.coordinator:preparePlayerOptions(changedOptions())
  Assert.isNil(scriptBusy, "an open script request refuses preparation")
  harness.dialogue:close()
  harness.scripts.dialogueHost:askYesNo(7)
  local choiceBusy = harness.coordinator:preparePlayerOptions(changedOptions())
  Assert.isNil(choiceBusy, "an open choice refuses preparation")
  harness.scripts.dialogueHost:closeYesNo()
  Assert.deepEqual(harness.playerData.options, snapshot, "busy refusals mutate nothing")
  local starterBusy = openHarness()
  starterBusy.starterChoice = {
    isActive = function()
      return true
    end,
    setFrameIndex = function()
      error("a busy starter must never be retouched", 0)
    end,
  }
  starterBusy.coordinator = FieldMenuCompositionCoordinator.new(starterBusy)
  Assert.isNil(starterBusy.coordinator:preparePlayerOptions(changedOptions()), "an active starter refuses preparation")
  -- Idle setters reject retouching active owners.
  harness.dialogue:open({ id = "held", message = dialogueMessage(), allowCancel = false, frameIndex = 0 })
  Assert.throws(function()
    harness.dialogue:setPolicy(TextSpeedPolicy.forSpeed("fastest"))
  end, "an active dialogue keeps its policy")
  harness.dialogue:close()
  harness.dialogue:setPolicy(TextSpeedPolicy.forSpeed("fastest"))
  harness.dialogue:open({ id = "reseated", message = dialogueMessage(), allowCancel = false, frameIndex = 0 })
  Assert.isTrue(stepsToDone(harness.dialogue, 4), "an idle policy change lands on the next request")
  harness.dialogue:close()
  harness.signpost:printTyped(signMessage())
  Assert.throws(function()
    harness.signpost:setPolicy(TextSpeedPolicy.forSpeed("fastest"))
  end, "a live signpost print keeps its policy")
  harness.signpost:finishPrint()
  harness.signpost:setPolicy(TextSpeedPolicy.forSpeed("fastest"))
  harness.scripts.dialogueHost:startPrint("msg.hgss.1.2", {}, {})
  Assert.throws(function()
    harness.scripts.dialogueHost:setFrameIndex(2)
  end, "an open script request keeps its frame")
  harness.dialogue:close()
  harness.scripts.dialogueHost:setFrameIndex(2)
  Assert.equal(harness.scripts.dialogueHost:yesNoOptions().frameIndex, 2)
  harness.starterChoice:setFrameIndex(2)
  Assert.isFalse(harness.starterChoice:isActive(), "an idle frame change leaves the starter closed")
  harness.partyMenu.dispose()
  starterBusy.partyMenu.dispose()
end


function T.tests.legacy_save_without_new_options_opens_with_defaults()
  local Coordinator = require("game.hgss.src.field.FieldMenuCompositionCoordinator")
  local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
  -- A persisted record predating the scene/sound/speed options carries
  -- only the original fields; opening the menu must default the absent
  -- ones instead of crashing, and must not mutate the live record until
  -- Confirm.
  local liveOptions = { textSpeed = "mid", textFrame = 0, battleStyle = "shift" }
  local volume = { current = 80 }
  local port = {
    read = function()
      return volume.current
    end,
    preview = function(value)
      volume.previewed = value
    end,
    commit = function(value)
      volume.current = value
    end,
    restore = function()
      volume.previewed = volume.current
    end,
  }
  local runtime = {
    playerData = { profile = {}, options = liveOptions },
    playerDataContext = { charmap = CHARMAP, frameIndexes = FRAME_INDEXES },
    audioPreferences = port,
    uiManifest = { options = {} },
  }
  local coordinator = Coordinator.new(runtime)
  local factory = nil
  for _, descriptor in ipairs(coordinator:applicationDescriptors()) do
    if descriptor.id == FieldApplicationIds.OPTIONS then
      factory = descriptor.factory
    end
  end
  Assert.notNil(factory, "the field catalogue registers the options destination")
  local screen = factory()
  local status = screen:status()
  local byId = {}
  for _, row in ipairs(assert(status.rows, "status carries its rows")) do
    byId[row.id] = row
  end
  Assert.equal(byId.battleScene.value, true, "an absent scene switch defaults on")
  Assert.equal(byId.soundMode.value, "stereo", "an absent channel mode defaults to stereo")
  Assert.equal(byId.battleSpeed.value, 1, "an absent presentation speed defaults to single rate")
  Assert.isNil(liveOptions.battleScene, "opening the menu mutates nothing until Confirm")
  screen:dispose()
end

-- A factory failure before handoff releases the owned port while a
-- fresh open with complete generated text succeeds on a new port.
function T.tests.failed_factory_open_releases_owned_port_and_permits_a_fresh_open()
  local Coordinator = require("game.hgss.src.field.FieldMenuCompositionCoordinator")
  local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
  local liveOptions = {
    textSpeed = "mid",
    textFrame = 0,
    battleStyle = "shift",
    battleScene = true,
    soundMode = "stereo",
    battleSpeed = 1,
  }
  local ports = {}
  local runtime = {
    playerData = { profile = {}, options = liveOptions },
    playerDataContext = { charmap = CHARMAP, frameIndexes = FRAME_INDEXES },
    audioPreferences = {
      read = function()
        return 80
      end,
      preview = function(_) end,
      commit = function(_) end,
      restore = function() end,
    },
    uiManifest = {
      options = {},
      dialogueFrames = { continueCursor = CURSOR },
    },
    fontDef = { glyphs = { [0] = { advance = 8 } } },
    cacheFs = FieldDialogueFixture.cacheWithFontId(1),
    presentationDisplay = stubMeasurement(),
  }
  runtime.optionsPresentationFactory = function()
    local port = { disposes = 0 }
    function port.prepare()
      return true
    end
    function port.dispose()
      port.disposes = port.disposes + 1
    end
    ports[#ports + 1] = port
    return port
  end
  local coordinator = Coordinator.new(runtime)
  local factory = nil
  for _, descriptor in ipairs(coordinator:applicationDescriptors()) do
    if descriptor.id == FieldApplicationIds.OPTIONS then
      factory = descriptor.factory
    end
  end
  Assert.notNil(factory, "the field catalogue registers the options destination")
  local ok, err = pcall(factory)
  Assert.isFalse(ok, "a missing generated preview message fails the open")
  Assert.isTrue(err ~= nil, "the failure propagates its cause")
  Assert.equal(#ports, 1, "the failed open admitted exactly one port")
  Assert.equal(ports[1].disposes, 1, "the failed open releases its owned port exactly once")
  runtime.uiManifest.options = {
    framePreviewText = {
      [0] = {
        text = "HI",
        tokens = {
          { kind = "glyph", text = "H", code = 1 },
          { kind = "glyph", text = "I", code = 1 },
          { kind = "eos" },
        },
      },
    },
  }
  local screen = factory()
  Assert.isTrue(screen:status().open, "a fresh open works after a factory failure")
  Assert.equal(#ports, 2, "the fresh open admits a new port")
  Assert.equal(ports[1].disposes, 1, "the failed port is never double-released")
  screen:dispose()
  Assert.equal(ports[2].disposes, 1, "the fresh screen still owns its port exactly once")
  Assert.equal(ports[1].disposes, 1, "disposal never touches the failed port again")
end

-- A mid-sequence live failure restores every earlier consumer and the
-- exact raw saved slots; a fresh attempt then publishes cleanly.
function T.tests.partial_setter_failure_restores_every_consumer_and_raw_slots()
  local harness = openHarness()
  harness.audioSink = {
    mode = "stereo",
    setChannelMode = function(self, mode)
      assert(mode == "stereo" or mode == "mono", "channel preview stays stereo or mono")
      self.mode = mode
    end,
  }
  local before = {
    textSpeed = "mid",
    textFrame = 0,
    battleStyle = "shift",
    battleScene = true,
    soundMode = "stereo",
    battleSpeed = 1,
  }
  Assert.deepEqual(harness.playerData.options, before, "the harness opens on its committed record")
  local transaction = assert(harness.coordinator:preparePlayerOptions(changedOptions()))
  Assert.isTrue(type(transaction.apply) == "function", "preparation returns its one-use application")
  Assert.isTrue(type(transaction.rollback) == "function", "preparation returns its idempotent restoration")
  local realFrame = harness.scripts.dialogueHost.setFrameIndex
  harness.scripts.dialogueHost.setFrameIndex = function()
    error("injected script frame failure", 0)
  end
  local ok, applyErr = pcall(transaction.apply)
  Assert.isFalse(ok, "the injected setter failure propagates")
  harness.scripts.dialogueHost.setFrameIndex = realFrame
  transaction.rollback()
  Assert.deepEqual(harness.playerData.options, before, "restoration keeps the exact raw saved slots")
  harness.dialogue:open({ id = "restored", message = dialogueMessage(), allowCancel = false, frameIndex = 0 })
  Assert.isFalse(stepsToDone(harness.dialogue, 4), "the restored mid cadence still reveals slowly")
  harness.dialogue:close()
  local fresh = assert(harness.coordinator:preparePlayerOptions(changedOptions()))
  fresh.apply()
  Assert.deepEqual(harness.playerData.options, changedOptions(), "a fresh attempt publishes the canonical set")
  fresh.rollback()
  Assert.deepEqual(harness.playerData.options, before, "restoration after success returns to the raw baseline")
  harness.partyMenu.dispose()
end

-- Records predating newer switches restore absent slots as absent while
-- live collaborators fall back to their documented defaults.
function T.tests.restoration_keeps_absent_old_save_slots_absent()
  local harness = openHarness()
  harness.audioSink = {
    mode = "stereo",
    setChannelMode = function(self, mode)
      self.mode = mode
    end,
  }
  harness.playerData.options.battleScene = nil
  harness.playerData.options.soundMode = nil
  harness.playerData.options.battleSpeed = nil
  local transaction = assert(harness.coordinator:preparePlayerOptions(changedOptions()))
  transaction.apply()
  Assert.equal(harness.playerData.options.battleScene, false, "the attempt stages its canonical scene")
  transaction.rollback()
  Assert.isNil(harness.playerData.options.battleScene, "restoration keeps the absent scene slot absent")
  Assert.isNil(harness.playerData.options.soundMode, "restoration keeps the absent channel slot absent")
  Assert.isNil(harness.playerData.options.battleSpeed, "restoration keeps the absent speed slot absent")
  Assert.equal(harness.playerData.options.textSpeed, "mid", "present slots return to their raw values")
  Assert.equal(harness.audioSink.mode, "stereo", "the live channel returns to its default")
  transaction.rollback()
  Assert.isNil(harness.playerData.options.battleScene, "a second restoration stays a no-op")
  local idle = assert(harness.coordinator:preparePlayerOptions(changedOptions()))
  idle.rollback()
  Assert.isNil(harness.playerData.options.battleScene, "a never-applied attempt restores nothing")
  harness.partyMenu.dispose()
end

return T
