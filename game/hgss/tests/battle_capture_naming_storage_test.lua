-- Committed captures keep their exact identity, land in the party or in
-- real PC boxes, and offer the native nickname decision before field
-- return. A named capture persists its nickname, a declined one keeps its
-- default name, and duplicate or late naming answers never create another
-- mon. The standalone naming screen already accepts text and seals exactly
-- once; the battle side delegates to that mechanism instead of a
-- substitute prompt.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local NamingScreenController = require("libs.hgss.src.ui.NamingScreenController")
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
local BattleSubflows = require("game.hgss.src.battle.BattleSubflows")
local BattlePresentationManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local BattlePresentationSchema = require("libs.assets.src.battle.BattlePresentationSchema")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local COMPOSER_MODULE = "game.hgss.src.battle.BattleChildApplications"
local RUNTIME_MODULE = "game.hgss.src.battle.BattleRuntime"
local STATE_MODULE = "game.hgss.src.battle.BattleScreenState"
local SCENARIO_FACTORY_MODULE = "libs.hgss.src.battle.HgssBattleScenarioFactory"

local TICK = 1 / 30

local T = {}

local CHARMAP = {}
for code = string.byte(" "), string.byte("~") do
  CHARMAP[string.char(code)] = code
end

---@return table<string, unknown> naming controller bound to a captured subject
local function captureNaming()
  return NamingScreenController.new({
    kind = "pokemon",
    maxLength = 10,
    initialText = "",
    charmap = CHARMAP,
    subject = { kind = "pokemon", species = 25 },
    effect = function() end,
  })
end

function T.standalone_naming_screen_accepts_and_seals_text_exactly_once()
  local screen = captureNaming()
  Assert.equal(screen:text(), "", "setup: the capture starts from the empty default")
  Assert.isTrue(screen:inputText("AB"), "the real naming screen accepts text")
  Assert.isTrue(screen:submit(), "the real naming screen submits")
  Assert.deepEqual(screen:result(), { kind = "submit", text = "AB" }, "the sealed text matches the entry")
  Assert.isFalse(screen:submit(), "a second submit seals nothing more")
  Assert.equal(screen:text(), "AB", "the sealed text is preserved after the extra submit")
end

function T.capture_naming_delegates_through_the_battle_child_composer()
  local ok, composer = pcall(require, COMPOSER_MODULE)
  Assert.isTrue(ok, "capture naming composes through the child module (" .. COMPOSER_MODULE .. ")")
  assert(composer ~= nil, "the composer loads")
end

function T.capture_naming_opens_as_a_real_naming_child()
  local flows = BattleSubflows.new({ launchId = "launch-naming-child" })
  local intent = {
    kind = "naming",
    purpose = "nickname",
    launchId = "launch-naming-child",
    requestId = 13,
    epoch = 5,
    controller = "player",
    cancellable = true,
    -- The capture naming intent carries the authoritative committed
    -- subject the completion caller stages: without a species the real
    -- naming screen cannot name its subject and the child must refuse
    -- rather than invent one.
    subject = { species = 25 },
    request = { requestId = 13, epoch = 5, controller = "player", kind = "nickname" },
    options = {
      requestId = 13,
      epoch = 5,
      controller = "player",
      kind = "nickname",
      actors = { { combatant = 1, activation = 5, kind = "nickname", choices = {} } },
    },
    party = {
      { combatant = 1, slot = 0, name = "LEAD", level = 20, hp = 30, maxHp = 30 },
    },
    inventory = {},
  }
  local ok, openErr = flows:open(intent)
  Assert.isTrue(ok, "the capture naming intent opens as a real naming child: " .. tostring(openErr))
  local reopened, _ = flows:open(intent)
  Assert.isTrue(reopened, "the capture naming intent opens as a real naming child")
  flows:dispose()
end

---@param value unknown value under test preparation
---@return unknown a detached copy sharing no table with the source
local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, item in pairs(value) do
    copy[deepCopy(key)] = deepCopy(item)
  end
  return copy
end

---@return table detached schema-valid staged manifest for the capture harness scene
local function screenManifest()
  local manifest = deepCopy(BattlePresentationManifestFixture.manifest())
  manifest.scenes = { { key = "general/plain/day", background = "general", terrain = "plain", time = "day" } }
  BattlePresentationSchema.assertManifest(manifest)
  return manifest
end

---@param image table fake image handle under inspection
---@return integer staged image width
local function fakeImageWidth(image)
  return image.width
end

---@param image table fake image handle under inspection
---@return integer staged image height
local function fakeImageHeight(image)
  return image.height
end

---@param image table fake image handle under inspection
---@return integer, integer staged image dimensions
local function fakeImageDimensions(image)
  return image.width, image.height
end

local function fakeImageSetFilter() end

---@param key string image identity under test preparation
---@return table fake image handle carrying the renderer-required dimensions
local function fakeDrawable(key)
  local hudImage = key:match("^hud:") ~= nil
  return {
    handle = key,
    width = hudImage and 1648 or 80,
    height = hudImage and 8 or 80,
    getWidth = fakeImageWidth,
    getHeight = fakeImageHeight,
    getDimensions = fakeImageDimensions,
    setFilter = fakeImageSetFilter,
  }
end

---@return table caller-owned dual-surface display facts
local function dualMeasurement()
  return {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
    ),
    pixelRatio = 1,
    signature = "capture-naming:dual",
  }
end

---@param speciesList string[] catalog species keys filling the live party in order
---@param catalog table? mon catalog under ownership, fixture root when absent
---@param game string? versioned game identity under ownership, heartgold when absent
---@return table live party owner holding the described members in order
local function makePartyOwner(speciesList, catalog, game)
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  catalog = catalog or CatalogFixture.makeCatalog()
  local owner = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x22222222):capture()),
    profile = CatalogFixture.profile(),
    game = game or "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = 7,
    date = CatalogFixture.metDate(),
  })
  local boxNames = {}
  for box = 0, owner:boxCount() - 1 do
    boxNames[#boxNames + 1] = { box = box, name = "BOX " .. tostring(box + 1) }
  end
  local metadata, metadataErr = owner:preparePcChanges({
    partyRevision = owner:partyRevision(),
    boxRevision = owner:boxRevision(),
  }, { metadata = boxNames })
  Assert.notNil(metadata, "the live save fixture stages its default PC names")
  Assert.isNil(metadataErr, "the default box names do not race their owner")
  metadata.publish()
  local factory = CatalogFixture.makeFactory(0xCA900001, catalog)
  for _, key in ipairs(speciesList) do
    local record = factory:createNormal(CatalogFixture.normalRequest({ species = key, level = 9 }))
    record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
    Assert.isTrue(owner:addMon(record), "the capture path needs its live party member")
  end
  return owner
end

---@param species string catalog species key under test preparation
---@param level integer battle level under test preparation
---@param seed integer fixed generator state under test preparation
---@param catalog table? mon catalog under generation, fixture root when absent
---@return table full mon-domain record for the enemy side
local function makeFoe(species, level, seed, catalog)
  catalog = catalog or CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(seed, catalog)
  local record = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level }))
  record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return record
end

---@return table bag owner holding one guaranteed ball
local function makeBallBag()
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  Assert.isTrue(bag:add("MASTER_BALL", 1), "the capture path stocks its thrown ball")
  return bag
end

---@param opts table rig options under test preparation
---@return table live rig with the runtime, the real screen, and its port
local function openCaptureRig(opts)
  local BattleRuntime = require(RUNTIME_MODULE)
  local BattleScreenState = require(STATE_MODULE)
  local ScenarioFactory = require(SCENARIO_FACTORY_MODULE)
  local holder = {}
  local rig = {
    measurement = dualMeasurement(),
    text = { draws = {} },
    windows = { calls = {} },
    audio = { plays = {} },
    assets = { prepared = {}, released = {}, images = {} },
  }
  function rig.text.measure(content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  function rig.text.drawText(content, x, y)
    rig.text.draws[#rig.text.draws + 1] = { content = tostring(content), x = x, y = y }
  end
  function rig.windows.drawWindow(box, frameKey, background)
    rig.windows.calls[#rig.windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  function rig.windows.drawApplicationFrame(box, frameIndex)
    rig.windows.calls[#rig.windows.calls + 1] = { applicationBox = box, frame = frameIndex }
  end
  function rig.audio.play(first, second)
    rig.audio.plays[#rig.audio.plays + 1] = second ~= nil and second or first
    return true
  end
  function rig.audio.playPanned(_, symbol)
    rig.audio.plays[#rig.audio.plays + 1] = symbol
    return true
  end
  function rig.audio.playFanfare(_, symbol)
    rig.audio.plays[#rig.audio.plays + 1] = symbol
    return true
  end
  function rig.assets.prepare(_)
    rig.assets.prepared[#rig.assets.prepared + 1] = true
    return true
  end
  function rig.assets.drawable(key)
    if rig.assets.images[key] == nil then
      rig.assets.images[key] = fakeDrawable(key)
    end
    return rig.assets.images[key]
  end
  function rig.assets.release(key)
    rig.assets.released[key] = (rig.assets.released[key] or 0) + 1
  end
  local catalog = opts.catalog or CatalogFixture.makeCatalog()
  local party = makePartyOwner(opts.party, opts.catalog, opts.game)
  local bag = opts.bag
  local player = {
    trainerId = 99,
    trainerName = "MINT",
    language = "french",
    trainerClassKey = "PKMN_TRAINER_ETHAN",
    metBill = opts.metBill == true,
  }
  local launchId = opts.launchId or "launch-capture-naming"
  local foe = makeFoe(opts.foeSpecies or "EEVEE", opts.foeLevel or 3, 0x5EED0002, opts.catalog)
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launchId .. "-attempt", mon = foe },
    { party = party, bag = bag, player = player }
  )
  local launch = {
    id = launchId,
    kind = "wild",
    payload = {
      attemptId = launchId .. "-attempt",
      species = opts.foeSpecies or "EEVEE",
      form = 0,
      level = opts.foeLevel or 3,
      personality = 1,
      ability = "RUN_AWAY",
    },
  }
  local screen = BattleScreenState.new({
    launchId = launchId,
    manifest = screenManifest(),
    model = BattlePresentationModel,
    submit = function(reply)
      return holder.battle:submit(reply)
    end,
    measureDisplay = function()
      return rig.measurement
    end,
    itemCatalog = ItemFixture.makeCatalog(),
    monCatalog = catalog,
    assets = rig.assets,
    text = rig.text,
    windows = rig.windows,
    audio = rig.audio,
  })
  rig.screen = screen
  rig.port = screen:presentationPort()
  local args = {
    request = launch,
    scenario = scenario,
    party = party,
    presentation = rig.port,
    seed = 0x12345678,
  }
  if bag ~= nil then
    args.bag = bag
  end
  if opts.dex ~= nil then
    args.dex = opts.dex
  end
  if opts.captures ~= nil then
    args.captures = opts.captures
  end
  holder.battle = BattleRuntime.new(args)
  rig.battle = holder.battle
  rig.party = party
  rig.bag = bag
  function rig.pump(ticks)
    for _ = 1, ticks or 1 do
      rig.battle:update()
      rig.screen:updateFixed(TICK)
    end
  end
  return rig
end

-- Advances the live lifetime until the player decision opens or the
-- lifetime settles.
---@param rig table live capture rig under test driving
---@param budget integer maximum update ticks before the driver gives up
---@return table<string, unknown> status once a player decision is open or the lifetime settled
local function driveToDecision(rig, budget)
  for _ = 1, budget do
    rig.pump(1)
    local current = rig.battle:status()
    if current.phase == "failed" then
      error("the capture battle failed: " .. tostring(current.error), 0)
    end
    if current.phase == "running" and current.request ~= nil then
      return current
    end
    if current.phase == "complete" then
      return current
    end
  end
  error("the capture battle never opened its player decision")
end

-- Acknowledges narration through the real screen path exactly as a player
-- would, so the terminal outcome can be observed and acknowledged.
---@param rig table live capture rig under test driving
local function ackNarration(rig)
  local mode = rig.screen:status().mode
  if mode == "intro" or mode == "narration"
    or rig.screen._timeline:messageActive() or rig.screen._timeline:levelUpStats() ~= nil
  then
    rig.screen:input({ { type = "confirm" } })
  end
end

---@param rig table live capture rig under test driving
---@param budget integer maximum update ticks before the driver gives up
---@return table<string, unknown> status once the commit receipt is published
local function driveToCommitted(rig, budget)
  for _ = 1, budget do
    rig.pump(1)
    ackNarration(rig)
    local current = rig.battle:status()
    if current.phase == "failed" then
      error("the capture battle failed: " .. tostring(current.error), 0)
    end
    if current.outcomeReceipt ~= nil and current.outcomeReceipt.committed == true then
      return current
    end
  end
  error("the capture battle never published its commit receipt")
end

-- Acknowledges narration until the nickname question of the committed
-- capture is offered through the real completion port.
---@param rig table live capture rig under test driving
---@param budget integer maximum update ticks before the driver gives up
---@return table<string, unknown> completion description once the question is offered
local function driveToNicknameQuestion(rig, budget)
  for _ = 1, budget do
    rig.pump(1)
    ackNarration(rig)
    local completion = rig.screen:status().completion
    if type(completion) == "table" and completion.stage == "question" then
      return completion
    end
  end
  local screen = rig.screen:status()
  local battle = rig.battle:status()
  error(
    "the committed capture never offered its nickname question (screen="
      .. tostring(screen.mode)
      .. ", completion="
      .. tostring(screen.completion and screen.completion.stage)
      .. ", phase="
      .. tostring(battle.phase)
      .. ")"
  )
end

-- A caught mon keeps its exact identity through the native nickname
-- decision and persists the typed name across save and reload.
function T.caught_mon_keeps_typed_nickname_through_save_and_reload()
  local rig = openCaptureRig({
    launchId = "launch-typed-nickname",
    party = { "CHIKORITA", "TOTODILE", "EEVEE", "CHIKORITA", "TOTODILE" },
    bag = makeBallBag(),
  })
  local opening = driveToDecision(rig, 600)
  local request = assert(opening.request, "the capture battle asks its opening decision")
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local options = rig.battle:decisionOptions(request.requestId)
  Assert.notNil(options, "the opening decision projects its options")
  local fragment = nil
  for _, actor in ipairs(options.actors) do
    for _, choice in ipairs(actor.choices or {}) do
      if
        choice.enabled == true
        and type(choice.choice) == "table"
        and type(choice.choice.payload) == "table"
        and choice.choice.payload.item == "MASTER_BALL"
      then
        fragment = choice.choice
      end
    end
  end
  Assert.notNil(fragment, "the opening decision offers the stocked ball")
  local thrown, throwErr = rig.battle:submit(SessionFixture.replyFor(request, {
    fragment --[[@as table<string, unknown>]],
  }))
  Assert.isTrue(thrown, "the thrown ball is accepted: " .. tostring(throwErr))
  local committed = driveToCommitted(rig, 1200)
  Assert.equal(committed.result, "capture", "the thrown ball settles as a capture")
  local receipt = assert(committed.outcomeReceipt, "completion carries its commit receipt")
  Assert.equal(#receipt.placements, 1, "the capture reports its single placement")
  Assert.equal(receipt.placements[1].destination, "party", "a fitting capture stays in the party")
  Assert.equal(receipt.placements[1].partySlot, 5, "the fifth slot holds the newcomer")
  local busy, busyReason = rig.battle:canSave()
  Assert.isFalse(busy, "durable save stays busy while the nickname choice is pending")
  Assert.equal(busyReason.phase, "postbattle", "the pending nickname owns the save gate")
  local question = driveToNicknameQuestion(rig, 1200)
  Assert.equal(question.kind, "capture_nickname", "the offered completion names the nickname decision")
  -- Yes types through the native naming screen: the staged text and the
  -- sealed submit travel the composed native controller.
  rig.screen:input({ { type = "confirm" } })
  rig.pump(3)
  local naming = rig.screen:status().completion
  Assert.notNil(naming, "answering yes keeps the completion open")
  assert(naming ~= nil, "the naming stage reports itself")
  Assert.equal(naming.stage, "naming", "answering yes opens the native naming lane")
  rig.screen:input({ { type = "text", text = "AB" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().completion.text, "AB", "the native screen stages the typed text")
  rig.screen:input({ { type = "name_control", id = "ok" } })
  for _ = 1, 600 do
    rig.pump(1)
    ackNarration(rig)
    if rig.battle:status().phase == "complete" then
      break
    end
  end
  Assert.equal(rig.battle:status().phase, "complete", "the named capture still returns to the field")
  Assert.isNil(rig.screen:status().completion, "the sealed nickname consumes its completion")
  local stored = rig.party:partyMon(5)
  Assert.equal(stored.species, "EEVEE", "the appended mon keeps its caught species")
  Assert.equal(stored.nickname, "AB", "the typed nickname reaches the committed party")
  Assert.equal(rig.bag:quantity("MASTER_BALL"), 0, "the capture spends its single ball")
  local saveable, _ = rig.battle:canSave()
  Assert.isTrue(saveable, "the save gate reopens once the nickname resolves")
  -- Ordinary save and reload see the selected name in its party slot.
  local FakeCache = require("tests.support.FakeCache")
  local SaveFs = require("libs.storage.src.SaveFs")
  local saves = SaveFs.global(FakeCache.new())
  local bucket = rig.party:capture()
  Assert.isTrue(saves:writeLua("mons.lua", bucket), "the named party writes through the save root")
  local loaded = assert(saves:loadLua("mons.lua"), "the named party reads back through the save root")
  local context = CatalogFixture.domainContext(CatalogFixture.makeCatalog())
  Assert.isTrue(MonsSave.validate(loaded, context), "the reloaded bucket validates before restore")
  local restored = MonsSave.restore(loaded, context)
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local reloaded = HgssMonService.new({
    catalog = CatalogFixture.makeCatalog(),
    bucket = MonsSave.capture(restored.party:capture(), restored.rng:capture(), restored.boxes:capture()),
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
  Assert.equal(reloaded:partyCount(), 6, "the reloaded party keeps its newcomer")
  Assert.equal(reloaded:partyMon(5).nickname, "AB", "the reloaded party keeps the typed nickname")
  rig.battle:dispose()
  rig.screen:dispose()
end

function T.declined_full_party_catch_shows_the_saved_pc_transfer_message()
  local rig = openCaptureRig({
    launchId = "launch-declined-pc-transfer",
    party = { "CHIKORITA", "TOTODILE", "EEVEE", "CHIKORITA", "TOTODILE", "EEVEE" },
    bag = makeBallBag(),
    metBill = false,
  })
  local opening = driveToDecision(rig, 600)
  local request = assert(opening.request, "the transfer battle opens its item decision")
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local options = assert(rig.battle:decisionOptions(request.requestId), "the item decision carries choices")
  local ball = nil
  for _, actor in ipairs(options.actors) do
    for _, choice in ipairs(actor.choices or {}) do
      local payload = type(choice.choice) == "table" and choice.choice.payload or nil
      if choice.enabled == true and type(payload) == "table" and payload.item == "MASTER_BALL" then
        ball = choice.choice
      end
    end
  end
  Assert.notNil(ball, "the full-party transfer test can catch with its stocked ball")
  local ballChoice = assert(ball, "the stocked ball choice exists")
  local caught, catchErr = rig.battle:submit(SessionFixture.replyFor(request, { ballChoice }))
  Assert.isTrue(caught, "the capture is accepted: " .. tostring(catchErr))
  local committed = driveToCommitted(rig, 1200)
  Assert.equal(committed.result, "capture", "the full-party battle settles as a capture")
  Assert.equal(committed.outcomeReceipt.placements[1].destination, "box", "the caught mon transfers to storage")
  Assert.isTrue(committed.outcomeReceipt.placements[1].pcHasSpace, "the active box had an empty slot")
  driveToNicknameQuestion(rig, 1200)
  rig.screen:input({ { type = "cancel" } })
  rig.pump(120)
  local message = rig.screen:view().message
  Assert.isTrue(message:find("PC", 1, true) ~= nil, "declining displays the source PC transfer line")
  Assert.isTrue(message:find(rig.party:boxMetadata(0).name, 1, true) ~= nil, "the transfer names the destination box")
  for _ = 1, 600 do
    if rig.battle:status().phase == "complete" then
      break
    end
    rig.pump(1)
  end
  Assert.equal(rig.battle:status().phase, "complete", "the transfer wait auto-advances before field return")
  Assert.isTrue(rig.screen:_portLeave({}), "the source transfer line releases the battle without acknowledgment")
  rig.battle:dispose()
  rig.screen:dispose()
end

function T.pc_transfer_message_uses_bill_and_box_capacity_facts()
  local BattleScreenState = require(STATE_MODULE)
  local entries = {}
  for _, key in ipairs({
    "battle/pc-transfer/has-space/someone",
    "battle/pc-transfer/has-space/bill",
    "battle/pc-transfer/box-full/someone",
    "battle/pc-transfer/box-full/bill",
  }) do
    local substitutions = key:find("box-full", 1, true) and 3 or 2
    local tokens = { { kind = "glyph", text = key .. ":" } }
    for index = 1, substitutions do
      tokens[#tokens + 1] = { kind = "substitution" }
      if index < substitutions then
        tokens[#tokens + 1] = { kind = "glyph", text = "|" }
      end
    end
    entries[key] = { tokens = tokens }
  end
  local screen = { _manifest = { messages = { entries = entries } } }
  local variants = {
    { metBill = false, pcHasSpace = true, key = "battle/pc-transfer/has-space/someone" },
    { metBill = true, pcHasSpace = true, key = "battle/pc-transfer/has-space/bill" },
    { metBill = false, pcHasSpace = false, key = "battle/pc-transfer/box-full/someone" },
    { metBill = true, pcHasSpace = false, key = "battle/pc-transfer/box-full/bill" },
  }
  for _, variant in ipairs(variants) do
    local text = assert(BattleScreenState._pcTransferText(screen, {
      subject = { nickname = "EEVEE" },
      metBill = variant.metBill,
      placement = {
        destination = "box",
        pcHasSpace = variant.pcHasSpace,
        previousBoxName = "OLD BOX",
        boxName = "NEW BOX",
      },
    }))
    Assert.isTrue(text:find(variant.key, 1, true) == 1, "the source route selects " .. variant.key)
  end
end

---@return table headless seven-operation port answering decline explicitly
local function decliningPort(record)
  return {
    enter = function(_plan)
      record.enters = record.enters + 1
      return true
    end,
    present = function(packet)
      record.packets[#record.packets + 1] = packet
    end,
    ready = function()
      return true
    end,
    leave = function(_plan)
      record.leaves = record.leaves + 1
      return true
    end,
    dispose = function()
      record.disposed = record.disposed + 1
    end,
    openCompletion = function(intent)
      record.opened[#record.opened + 1] = intent
      return true
    end,
    takeCompletion = function()
      local intent = record.opened[#record.opened]
      if intent == nil or record.answered[intent.completionId] then
        return nil
      end
      record.answered[intent.completionId] = true
      return { launchId = intent.launchId, completionId = intent.completionId, kind = "declined" }
    end,
  }
end

-- A full party spills the catch into the first empty box slot in scan
-- order while the party, the ball stock, and the caught knowledge publish
-- exactly once.
function T.full_party_catch_spills_to_first_empty_box_slot()
  local Committer = require("libs.hgss.src.battle.HgssBattleCommitter")
  local party = makePartyOwner({ "CHIKORITA", "TOTODILE", "EEVEE", "CHIKORITA", "TOTODILE" })
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(0xB0C00001, catalog)
  -- Room for one: the fifth slot stays in the party without touching boxes.
  local boxRevision = party:boxRevision()
  local fitting = factory:createNormal(CatalogFixture.normalRequest({ species = "EEVEE" }))
  local fittingPersonality = fitting.personality
  local prepared = Committer.prepare({
    outcome = { id = "outcome-party-has-room", result = "capture" },
    partyOwner = party,
    partyUpdates = {},
    captures = { { captureId = "room-1", success = true, mon = fitting } },
  })
  local receipt = Committer.commit(prepared)
  Assert.isTrue(receipt.committed, "the fitting capture commits")
  Assert.equal(#receipt.placements, 1, "the fitting capture reports its placement")
  Assert.equal(receipt.placements[1].destination, "party", "room in the party keeps the capture there")
  Assert.equal(receipt.placements[1].partySlot, 5, "the fifth slot holds the newcomer")
  Assert.equal(party:boxRevision(), boxRevision, "the fitting capture stages no box change")
  Assert.equal(party:partyMon(5).personality, fittingPersonality, "the appended mon keeps its identity")
  -- Full now: the occupied first cell of the active box pushes the next
  -- catch to the first empty slot in scan order.
  local occupant = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))
  local fill, fillErr = party:preparePcChanges({
    partyRevision = party:partyRevision(),
    boxRevision = party:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 0, mon = occupant } } })
  Assert.notNil(fill, "the setup occupies the first box cell: " .. tostring(fillErr))
  assert(fill ~= nil, "the box fill stages")
  fill.publish()
  local caught = factory:createNormal(CatalogFixture.normalRequest({ species = "EEVEE", level = 4 }))
  local caughtPersonality = caught.personality
  local partyRevision = party:partyRevision()
  local spilling = Committer.prepare({
    outcome = { id = "outcome-party-full-spills", result = "capture" },
    partyOwner = party,
    partyUpdates = {},
    captures = { { captureId = "spill-1", success = true, mon = caught } },
  })
  local spilled = Committer.commit(spilling)
  Assert.isTrue(spilled.committed, "the full-party capture commits through its box spillover")
  Assert.equal(#spilled.placements, 1, "the spillover reports its single placement")
  Assert.equal(spilled.placements[1].destination, "box", "a full party spills the catch into storage")
  Assert.equal(spilled.placements[1].box, 0, "the spillover scans from the active box")
  Assert.equal(spilled.placements[1].slot, 1, "the spillover takes the first empty slot in order")
  Assert.isTrue(spilled.placements[1].pcHasSpace, "the original active box had room for the transfer")
  Assert.equal(
    spilled.placements[1].boxName,
    party:boxMetadata(0).name,
    "the transfer carries its destination box name"
  )
  Assert.equal(
    spilled.placements[1].previousBoxName,
    party:boxMetadata(0).name,
    "the transfer retains the original active box name"
  )
  Assert.equal(party:partyCount(), 6, "the spillover leaves the party untouched")
  Assert.equal(party:partyRevision(), partyRevision, "the spillover publishes no party change")
  local stored = assert(party:boxMon(0, 1), "the spilled catch is readable in its box slot")
  Assert.equal(stored.personality, caughtPersonality, "the boxed mon keeps its caught identity")
  Assert.equal(party:boxMon(0, 0).personality, occupant.personality, "the spillover preserves its box neighbor")
end

-- A full box scans forward cyclically: with the active box full, the
-- catch lands in the next box instead of failing or overwriting.
function T.full_active_box_scans_forward_cyclically()
  local Committer = require("libs.hgss.src.battle.HgssBattleCommitter")
  local party = makePartyOwner({ "CHIKORITA", "TOTODILE", "EEVEE", "CHIKORITA", "TOTODILE", "EEVEE" })
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(0xB0C00002, catalog)
  local filler = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))
  local filling = {}
  for slot = 0, 29 do
    filling[#filling + 1] = { box = 0, slot = slot, mon = filler }
  end
  local staged, stageErr = party:preparePcChanges({
    partyRevision = party:partyRevision(),
    boxRevision = party:boxRevision(),
  }, { boxUpdates = filling })
  Assert.notNil(staged, "the setup fills the active box: " .. tostring(stageErr))
  assert(staged ~= nil, "the box fill stages")
  staged.publish()
  local caught = factory:createNormal(CatalogFixture.normalRequest({ species = "EEVEE", level = 4 }))
  local caughtPersonality = caught.personality
  local prepared = Committer.prepare({
    outcome = { id = "outcome-active-box-full", result = "capture" },
    partyOwner = party,
    partyUpdates = {},
    captures = { { captureId = "cyclic-1", success = true, mon = caught } },
  })
  local receipt = Committer.commit(prepared)
  Assert.isTrue(receipt.committed, "the capture commits past its full active box")
  Assert.equal(#receipt.placements, 1, "the capture reports its single placement")
  Assert.equal(receipt.placements[1].destination, "box", "the capture lands in storage")
  Assert.equal(receipt.placements[1].box, 1, "a full active box scans to the next box")
  Assert.equal(receipt.placements[1].slot, 0, "slots ascend from the next box start")
  Assert.isFalse(receipt.placements[1].pcHasSpace, "the original active box had no room")
  Assert.equal(
    receipt.placements[1].previousBoxName,
    party:boxMetadata(0).name,
    "the full-box transfer names the original active box"
  )
  Assert.equal(receipt.placements[1].boxName, party:boxMetadata(1).name, "the full-box transfer names its destination")
  local stored = assert(party:boxMon(1, 0), "the catch is readable in the next box")
  Assert.equal(stored.personality, caughtPersonality, "the boxed mon keeps its caught identity")
end

-- Declining the nickname keeps the default name while the boxed catch,
-- the spent ball, and the caught knowledge still publish exactly once.
function T.declined_nickname_keeps_default_name_and_finished_battle()
  local BattleRuntime = require(RUNTIME_MODULE)
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local ScenarioFactory = require(SCENARIO_FACTORY_MODULE)
  local party = makePartyOwner({ "CHIKORITA", "TOTODILE", "EEVEE", "CHIKORITA", "TOTODILE", "EEVEE" })
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  Assert.isTrue(bag:add("POKE_BALL", 5), "the decline path stocks its thrown ball")
  local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")
  local PokedexDexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
  local dex = PokedexKnowledge.new(PokedexDexFixture.refsForSpecies({ "CHIKORITA", "TOTODILE", "EEVEE" }))
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(0xDEC11E01, catalog)
  local caught = factory:createNormal(CatalogFixture.normalRequest({ species = "EEVEE", level = 4 }))
  local caughtPersonality = caught.personality
  local foe = makeFoe("EEVEE", 4, 0xDEC11E02)
  local launchId = "launch-declined-nickname"
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launchId .. "-attempt", mon = foe },
    { party = party, player = { trainerId = 99, trainerName = "MINT", language = "french", trainerClassKey = "PKMN_TRAINER_ETHAN", metBill = false } }
  )
  local record = { enters = 0, packets = {}, leaves = 0, disposed = 0, opened = {}, answered = {} }
  local battle = BattleRuntime.new({
    request = {
      id = launchId,
      kind = "wild",
      payload = { attemptId = launchId .. "-attempt", species = "EEVEE", form = 0, level = 4 },
    },
    scenario = scenario,
    party = party,
    bag = bag,
    bagDeltas = { { op = "take", item = "POKE_BALL", quantity = 1 } },
    dex = dex,
    captures = { { captureId = "decline-1", ball = "POKE_BALL", success = true, mon = caught } },
    presentation = decliningPort(record),
    seed = 0x12345678,
  })
  local ticks = 0
  while battle:status().phase ~= "complete" and battle:status().phase ~= "failed" and ticks < 1200 do
    battle:update()
    local current = battle:status()
    if current.phase == "running" and current.request ~= nil then
      local actor = assert(current.request.actors[1], "every decision addresses its combatant")
      local fled, fleeErr =
        battle:submit(SessionFixture.replyFor(current.request, { { actor = actor, kind = "run", payload = {} } }))
      Assert.isTrue(fled, "the decline driver flees to settle: " .. tostring(fleeErr))
    end
    ticks = ticks + 1
  end
  Assert.equal(battle:status().phase, "complete", "the declined capture still returns to the field")
  Assert.isTrue(#record.opened > 0, "the runtime routes the nickname decision through its completion port")
  Assert.isFalse(record.opened[1].metBill, "the source save flag selects someone's PC")
  Assert.isTrue(record.opened[1].placement.pcHasSpace, "the completion retains original-box capacity")
  Assert.equal(
    record.opened[1].placement.boxName,
    party:boxMetadata(0).name,
    "the completion carries the destination box name"
  )
  local receipt = assert(battle:status().outcomeReceipt, "completion carries its commit receipt")
  Assert.isTrue(receipt.committed, "the declined capture commits")
  Assert.equal(#receipt.placements, 1, "the declined capture reports its placement")
  Assert.equal(receipt.placements[1].destination, "box", "a full party spills the declined catch into storage")
  local placement = receipt.placements[1]
  local stored = assert(party:boxMon(placement.box, placement.slot), "the declined catch is readable in its box slot")
  Assert.equal(stored.personality, caughtPersonality, "the boxed mon keeps its caught identity")
  local Mon = require("libs.mons.src.Mon")
  Assert.isNil(stored.nickname, "declining stages no explicit nickname")
  Assert.equal(
    Mon.displayName(stored, CatalogFixture.makeCatalog()),
    "EEVEE",
    "declining keeps the default species name"
  )
  Assert.equal(party:partyCount(), 6, "the decline publishes no party change")
  Assert.equal(bag:quantity("POKE_BALL"), 4, "the capture spends its ball exactly once")
  Assert.isTrue(dex:isCaught("EEVEE"), "the capture registers caught knowledge exactly once")
  local saveable, _ = battle:canSave()
  Assert.isTrue(saveable, "the save gate reopens once the decline resolves")
  battle:dispose()
end

-- A stale owner revision before the pending rename refuses the write
-- while the committed mon and the battle outcome survive.
function T.stale_revision_before_rename_keeps_committed_mon()
  local BattleRuntime = require(RUNTIME_MODULE)
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local ScenarioFactory = require(SCENARIO_FACTORY_MODULE)
  local party = makePartyOwner({ "CHIKORITA" })
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(0x57A1E001, catalog)
  local caught = factory:createNormal(CatalogFixture.normalRequest({ species = "EEVEE", level = 4 }))
  local foe = makeFoe("EEVEE", 4, 0x57A1E002)
  local launchId = "launch-stale-rename"
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launchId .. "-attempt", mon = foe },
    { party = party, player = { trainerId = 99, trainerName = "MINT", language = "french", trainerClassKey = "PKMN_TRAINER_ETHAN" } }
  )
  local record = { enters = 0, packets = {}, leaves = 0, disposed = 0, opened = {}, answered = {} }
  local port = decliningPort(record)
  -- The port answers with a typed name instead of a decline so the stale
  -- owner has a write to refuse.
  function port.takeCompletion()
    local intent = record.opened[#record.opened]
    if intent == nil or record.answered[intent.completionId] then
      return nil
    end
    record.answered[intent.completionId] = true
    return { launchId = intent.launchId, completionId = intent.completionId, kind = "named", nickname = "AB" }
  end
  local battle = BattleRuntime.new({
    request = {
      id = launchId,
      kind = "wild",
      payload = { attemptId = launchId .. "-attempt", species = "EEVEE", form = 0, level = 4 },
    },
    scenario = scenario,
    party = party,
    captures = { { captureId = "stale-1", success = true, mon = caught } },
    presentation = port,
    seed = 0x12345678,
  })
  local drifted = false
  local ticks = 0
  while battle:status().phase ~= "complete" and battle:status().phase ~= "failed" and ticks < 1200 do
    battle:update()
    local current = battle:status()
    if current.phase == "running" and current.request ~= nil then
      local actor = assert(current.request.actors[1], "every decision addresses its combatant")
      local fled, fleeErr =
        battle:submit(SessionFixture.replyFor(current.request, { { actor = actor, kind = "run", payload = {} } }))
      Assert.isTrue(fled, "the stale driver flees to settle: " .. tostring(fleeErr))
    end
    if not drifted and #record.opened > 0 then
      local drifter = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))
      Assert.isTrue(party:addMon(drifter), "the concurrent owner move drifts the live revision")
      drifted = true
    end
    ticks = ticks + 1
  end
  Assert.isTrue(drifted, "the rename raced a genuine owner move")
  Assert.equal(battle:status().phase, "complete", "the refused rename still returns to the field")
  local receipt = assert(battle:status().outcomeReceipt, "completion carries its commit receipt")
  Assert.isTrue(receipt.committed, "the original capture commit survives the refused rename")
  Assert.equal(receipt.placements[1].destination, "party", "the capture keeps its committed placement")
  local stored = party:partyMon(receipt.placements[1].partySlot)
  Assert.equal(stored.species, "EEVEE", "the committed mon survives the refused rename")
  Assert.isNil(stored.nickname, "the refused rename writes no nickname")
  battle:dispose()
end

-- Every ready version replays the committed capture through its own owned
-- mon catalog: the versioned catalog names the same party and foe
-- species, the thrown ball settles as a capture in the first fitting
-- party slot, the native naming lane seals the typed nickname, and the
-- save gate reopens once the nickname resolves. The catalog and the game
-- identity both come from the versioned cache, never from a shared
-- fallback, so a version skew in species identities fails here instead
-- of hiding behind the synthetic fixture.
function T.versioned_species_replay_the_capture_naming_and_storage_flow(context)
  local GameVersion = require("romdump.src.source.GameVersion")
  local RomImporter = require("romdump.src.source.RomImporter")
  local CacheFs = require("libs.storage.src.CacheFs")
  local ItemCache = require("libs.assets.src.ItemCache")
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local MonCache = require("libs.assets.src.MonCache")
  local MonCatalog = require("libs.mons.src.MonCatalog")
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  if #versions == 0 then
    context:skip("the versioned capture flow needs a ready user-owned dump with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local root = MonCache.loadCatalog(cacheFs)
    Assert.equal(root.version.id, versionId, "the owned catalog names its own version, never a shared fallback")
    local items = ItemCatalog.new(ItemCache.loadCatalog(cacheFs))
    local catalog = MonCatalog.new(root, items)
    for _, speciesKey in ipairs({ "CHIKORITA", "TOTODILE", "EEVEE" }) do
      local known, knownErr = pcall(function()
        return catalog:species(speciesKey)
      end)
      Assert.isTrue(known, "the owned " .. versionId .. " catalog names " .. speciesKey .. ": " .. tostring(knownErr))
    end
    local rig = openCaptureRig({
      launchId = "launch-versioned-capture",
      catalog = catalog,
      game = versionId,
      party = { "CHIKORITA", "TOTODILE", "EEVEE", "CHIKORITA", "TOTODILE" },
      bag = makeBallBag(),
      foeSpecies = "EEVEE",
      foeLevel = 3,
    })
    local SessionFixture = require("libs.battle.tests.session_fixture")
    local opening = driveToDecision(rig, 600)
    local request = assert(opening.request, "the capture battle asks its opening decision on " .. versionId)
    local options = rig.battle:decisionOptions(request.requestId)
    Assert.notNil(options, "the opening decision projects its options on " .. versionId)
    local fragment = nil
    for _, actor in ipairs(options.actors) do
      for _, choice in ipairs(actor.choices or {}) do
        if
          choice.enabled == true
          and type(choice.choice) == "table"
          and type(choice.choice.payload) == "table"
          and choice.choice.payload.item == "MASTER_BALL"
        then
          fragment = choice.choice
        end
      end
    end
    Assert.notNil(fragment, "the opening decision offers the stocked ball on " .. versionId)
    local thrown, throwErr = rig.battle:submit(SessionFixture.replyFor(request, { fragment }))
    Assert.isTrue(thrown, "the thrown ball is accepted on " .. versionId .. ": " .. tostring(throwErr))
    local committed = driveToCommitted(rig, 1200)
    Assert.equal(committed.result, "capture", "the thrown ball settles as a capture on " .. versionId)
    local receipt = assert(committed.outcomeReceipt, "completion carries its commit receipt on " .. versionId)
    Assert.equal(#receipt.placements, 1, "the capture reports its single placement on " .. versionId)
    Assert.equal(receipt.placements[1].destination, "party", "a fitting capture stays in the party on " .. versionId)
    Assert.equal(receipt.placements[1].partySlot, 5, "the fifth slot holds the newcomer on " .. versionId)
    local question = driveToNicknameQuestion(rig, 1200)
    Assert.equal(
      question.kind,
      "capture_nickname",
      "the offered completion names the nickname decision on " .. versionId
    )
    rig.screen:input({ { type = "confirm" } })
    rig.pump(3)
    local naming = rig.screen:status().completion
    Assert.notNil(naming, "answering yes keeps the completion open on " .. versionId)
    assert(naming ~= nil, "the naming stage reports itself on " .. versionId)
    Assert.equal(naming.stage, "naming", "answering yes opens the native naming lane on " .. versionId)
    rig.screen:input({ { type = "text", text = "AB" } })
    rig.pump(1)
    Assert.equal(rig.screen:status().completion.text, "AB", "the native screen stages the typed text on " .. versionId)
    rig.screen:input({ { type = "name_control", id = "ok" } })
    for _ = 1, 600 do
      rig.pump(1)
      ackNarration(rig)
      if rig.battle:status().phase == "complete" then
        break
      end
    end
    Assert.equal(rig.battle:status().phase, "complete", "the named capture still returns to the field on " .. versionId)
    Assert.isNil(rig.screen:status().completion, "the sealed nickname consumes its completion on " .. versionId)
    local stored = rig.party:partyMon(5)
    Assert.equal(stored.species, "EEVEE", "the appended mon keeps its caught species on " .. versionId)
    Assert.equal(stored.nickname, "AB", "the typed nickname reaches the committed party on " .. versionId)
    local saveable, _ = rig.battle:canSave()
    Assert.isTrue(saveable, "the save gate reopens once the nickname resolves on " .. versionId)
    rig.battle:dispose()
    rig.screen:dispose()
  end
end

return {
  tests = T,
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = { "mon-catalog:global", "items:global" },
  },
}
