-- The one real Options journey through the production field composition:
-- the Start Menu unlock, the seven-setting child, an abandoned draft that
-- changes nothing durable, a confirmed draft across both persistence
-- scopes, ordinary Save/reload durability, and the battle-launch consumer
-- wiring through one real deterministic trainer battle under Scene Off,
-- Shift, and double speed. Cancellation details, legacy records, and
-- failed writes stay pinned by cheaper owner tests; Scene On admission and
-- the remaining speeds live with their battle owners. Acceptance stops
-- before GPU rendering; audio output is a deterministic recording fake
-- and the save root is isolated per boot. This suite proves the menu,
-- persistence, field next-use, and battle wiring through real composition.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldState = require("game.hgss.src.field.FieldState")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map:7" },
    tags = { "field", "menu", "options" },
  },
  tests = {},
}

local OPTIONS_ACTION = "vanilla.options"
local OPTIONS_APPLICATION = FieldApplicationIds.OPTIONS
local FLAG_GOT_OPTIONS = FieldScriptSymbols.flagsByName.FLAG_GOT_OPTIONS_BUTTON
local FLAG_GOT_SAVE = FieldScriptSymbols.flagsByName.FLAG_GOT_SAVE_BUTTON

local function withGame(fn)
  volumeFiles = {}
  local bootWidth, bootHeight = love.graphics.getDimensions()
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
    fieldOptions = {
      screenTopology = ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = bootWidth, height = bootHeight },
        touch = false,
        role = "world",
      }),
    },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "options acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The production FieldState callbacks LOVE dispatches. No synthetic input
-- behavior of its own.
local function hostCallbacks(game)
  return setmetatable({
    runtime = {
      input = game.runtime.input,
      actionKeys = game.runtime.actionKeys,
      cancelKeys = game.runtime.cancelKeys,
      menuKeys = game.runtime.menuKeys,
    },
  }, FieldState)
end

local function hostPhase(game)
  return game.runtime.applicationHost:status().phase
end

local function openStartMenu(game)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
  return game:advanceUntil("start menu becomes modal", function()
    return hostPhase(game) == FieldApplicationHost.PHASES.menu
  end, 120)
end

local function closeStartMenu(game)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
  game:advanceUntil("start menu closes", function(snapshot)
    return hostPhase(game) == FieldApplicationHost.PHASES.closed and not snapshot.fieldLocked
  end, 120)
end

local function menuStatus(game)
  local status = game.runtime.applicationHost:status()
  Assert.equal(status.phase, FieldApplicationHost.PHASES.menu, "the start menu must own the tick")
  return assert(status.menu, "the menu phase must expose the controller status")
end

local function actionById(status, id)
  for _, action in ipairs(assert(status.actions, "menu status must list actions")) do
    if action.id == id then
      return action
    end
  end
  return nil
end

local function cursorActionId(status)
  local position = assert(status.selectedPosition, "menu status must expose the selected position")
  for _, action in ipairs(assert(status.actions, "menu status must list actions")) do
    if action.position == position then
      return action.id
    end
  end
  error("start menu cursor does not resolve to a visible action", 0)
end

local function navigateTo(game, state, id)
  local status = menuStatus(game)
  for _ = 1, #status.actions + 1 do
    if cursorActionId(menuStatus(game)) == id then
      return
    end
    state:keypressed("s")
    game:step()
    state:keyreleased("s")
  end
  error("start menu never focuses " .. id, 0)
end

local function confirm(game)
  game.runtime.input:pressAction("key:return")
  game:step()
  game.runtime.input:releaseAction("key:return")
end

local function cancel(game)
  game.runtime.input:pressCancel("key:escape")
  game:step()
  game.runtime.input:releaseCancel("key:escape")
end

local function optionsView(game)
  local status = game.runtime.applicationHost:status()
  Assert.equal(
    status.phase,
    FieldApplicationHost.PHASES.application,
    "the options application must own the tick while open"
  )
  Assert.equal(status.applicationId, OPTIONS_APPLICATION, "the launched application must be options")
  local view = assert(status.application, "the options application must expose its status")
  assert(type(view) == "table", "the options status must be a record")
  return view
end

local function openOptions(game, state)
  game:setWorldState({ flag = FLAG_GOT_OPTIONS })
  openStartMenu(game)
  local action = actionById(menuStatus(game), OPTIONS_ACTION)
  Assert.isTrue(
    action ~= nil and action.enabled == true,
    "the unlocked options entry enables through source policy and catalogue capability"
  )
  navigateTo(game, state, OPTIONS_ACTION)
  confirm(game)
  game:advanceUntil("options application opens over the retained menu", function()
    return hostPhase(game) == FieldApplicationHost.PHASES.application
  end, 120)
  return optionsView(game)
end

local function rowIds(view)
  local ids = {}
  for _, row in ipairs(assert(view.rows, "the options status must publish its rows")) do
    ids[#ids + 1] = row.id
  end
  return ids
end

local function pressKey(game, state, key)
  state:keypressed(key)
  game:step()
  state:keyreleased(key)
end

-- In-memory volume backing behind the production AudioPreferences shape so
-- the suite exercises the real commit/restore path without touching the
-- global preference file. The backing is shared per boot journey so a
-- runtime replacement re-reads the committed record, proving the commit
-- durably published instead of living in the old port object.
local volumeFiles = {}

local function isolatedVolumeStorage()
  local storage = {}
  function storage.writeLua(_, path, record)
    volumeFiles[path] = record
  end
  function storage.loadLua(_, path)
    return volumeFiles[path]
  end
  function storage.replace(_, from, to)
    volumeFiles[to] = assert(volumeFiles[from], "replace requires the staged record")
    volumeFiles[from] = nil
  end
  function storage.exists(_, path)
    return volumeFiles[path] ~= nil
  end
  return storage
end

local function installVolumePort(game)
  local AudioPreferences = require("app.src.AudioPreferences")
  local gains = {}
  local port = AudioPreferences.new({
    storage = isolatedVolumeStorage(),
    setGain = function(gain)
      gains[#gains + 1] = gain
    end,
  })
  game.runtime.audioPreferences = port
  return port, gains
end

-- Forward declarations for the battle-leg drivers defined below the
-- journey: the journey calls them, so their names must resolve at the
-- journey's definition point.
local driveMenuSpeedLeg, driveMenuBattleLeg

-- Reloads the published save record through the actual save store: the
-- confirmed player options must survive a genuine store round trip.
local function loadStoredRuntime(game)
  local saveId = game.runtime.saveId
  local persisted = assert(game.runtime.saveStore:load(saveId), "the actual save store reloads the published record")
  game:_disposeRuntime()
  local runtime =
    game.harness:_newRuntime(persisted, game.saveNamespace, game.faults, game.lifecycle, game.fieldOptions, false)
  game.runtime = runtime
  game.hosts = runtime.scriptHosts or {}
  game.runtimeDisposed = false
  game.disposeErr = nil
  game.saveStatus = runtime.saveStatus
  return installVolumePort(game)
end

-- Touching an options control through the production field composition
-- focuses the same row a keyboard edit continues from: a tap on a Sound
-- choice focuses Sound before the release selects it, Left then edits
-- Sound instead of the previously focused row, and a footer tap focuses
-- its action without rendering anything.
function T.tests.touch_focuses_the_touched_row_through_production_composition()
  withGame(function(game)
    local state = hostCallbacks(game)
    installVolumePort(game)
    openOptions(game, state)
    local OptionsInterface = require("game.hgss.src.options.OptionsInterface")
    local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
    local view = optionsView(game)
    Assert.equal(view.focusId, "textSpeed", "the menu opens focused on the first row")
    local speedBefore = nil
    for _, row in ipairs(assert(view.rows, "the options status must publish its rows")) do
      if row.id == "textSpeed" then
        speedBefore = row.value
      end
    end
    local content = assert(view.presentation.content, "the presented options expose their list")
    local pane = nil
    for _, candidate in ipairs(assert(view.presentation.panes, "the plan carries its panes")) do
      if candidate.id == "content" then
        pane = candidate
      end
    end
    pane = pane or view.presentation.panes[1]
    local lx, ly = nil, nil
    for y = 0, 191 do
      for x = 0, 255 do
        local hit = OptionsInterface.hitTest(content, x, y)
        if hit ~= nil and hit.target == "soundMode" and hit.control == "value" and hit.index == 2 then
          lx, ly = x, y
          break
        end
      end
      if lx ~= nil then
        break
      end
    end
    Assert.isTrue(lx ~= nil, "the sound row publishes its second choice")
    local hx, hy = LayoutGeometry.logicalToHost(pane.placement, lx, ly)
    state:mousepressed(hx, hy, 1)
    game:step()
    Assert.equal(
      optionsView(game).focusId,
      "soundMode",
      "touching a choice focuses its row through composition"
    )
    state:mousereleased(hx, hy, 1)
    game:step()
    local touched = optionsView(game)
    Assert.equal(touched.focusId, "soundMode", "the release keeps the touched row focused")
    local soundValue = nil
    for _, row in ipairs(assert(touched.rows, "the options status must publish its rows")) do
      if row.id == "soundMode" then
        soundValue = row.value
      end
    end
    Assert.equal(soundValue, "mono", "the matching release selects the touched choice")
    pressKey(game, state, "a")
    local continued = optionsView(game)
    local afterSound, afterSpeed = nil, nil
    for _, row in ipairs(assert(continued.rows, "the options status must publish its rows")) do
      if row.id == "soundMode" then
        afterSound = row.value
      end
      if row.id == "textSpeed" then
        afterSpeed = row.value
      end
    end
    Assert.equal(afterSound, "stereo", "keyboard left edits the touched row next")
    Assert.equal(afterSpeed, speedBefore, "keyboard left leaves the previous row alone")
    local footerView = optionsView(game)
    local footerContent = assert(footerView.presentation.content, "the presented options expose their list")
    local footerPane = nil
    for _, candidate in ipairs(assert(footerView.presentation.panes, "the plan carries its panes")) do
      if candidate.id == "content" then
        footerPane = candidate
      end
    end
    footerPane = footerPane or footerView.presentation.panes[1]
    local cx, cy = nil, nil
    for y = 0, 191 do
      for x = 0, 255 do
        local hit = OptionsInterface.hitTest(footerContent, x, y)
        if hit ~= nil and hit.target == "confirm" then
          cx, cy = x, y
          break
        end
      end
      if cx ~= nil then
        break
      end
    end
    Assert.isTrue(cx ~= nil, "the footer publishes its confirm action")
    local chx, chy = LayoutGeometry.logicalToHost(footerPane.placement, cx, cy)
    state:mousepressed(chx, chy, 1)
    game:step()
    Assert.equal(
      optionsView(game).focusId,
      "confirm",
      "touching confirm focuses the footer action"
    )
    state:mousereleased(chx, chy, 1)
    game:step()
    Assert.equal(
      hostPhase(game),
      FieldApplicationHost.PHASES.application,
      "releasing a footer tap stays inside options"
    )
    cancel(game)
    game:advanceUntil("quit returns to the rebuilt start menu", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.menu
    end, 120)
  end)
end

function T.tests.options_confirm_adopts_player_settings_and_volume_then_survives_save_reload()
  withGame(function(game)
    local state = hostCallbacks(game)
    local port = installVolumePort(game)
    local view = openOptions(game, state)
    Assert.deepEqual(rowIds(view), {
      "textSpeed",
      "battleScene",
      "battleStyle",
      "soundMode",
      "volume",
      "battleSpeed",
      "textFrame",
    }, "the menu carries exactly the seven settings in order, frame last")
    Assert.isTrue(view.footer ~= nil and view.footer.confirm ~= nil, "the footer carries confirm")
    Assert.isTrue(view.footer.quit ~= nil, "the footer carries quit")
    Assert.equal(view.focusId, "textSpeed", "the menu opens focused on the first row")
    -- A genuine field wheel event reaches the options list through the
    -- real input composition, and the closing frame reveals its selector
    -- with the matching live preview before the draft is touched.
    state:wheelmoved(0, -1)
    game:step()
    state:wheelmoved(0, -1)
    game:step()
    state:wheelmoved(0, -1)
    game:step()
    Assert.equal(optionsView(game).scrollOffset, 64, "genuine wheel travel settles the list fully revealed")
    for _ = 1, 6 do
      pressKey(game, state, "s")
    end
    local framed = optionsView(game)
    Assert.equal(framed.focusId, "textFrame", "six downs reach the closing frame")
    Assert.equal(framed.scrollOffset, 64, "the frame rests fully revealed")
    Assert.equal(
      framed.preview.textFrame,
      game.runtime.playerData.options.textFrame,
      "the live preview follows the draft frame"
    )
    local wheeledPlan = assert(framed.presentation, "the presented options expose their plan")
    local wheeledContent = assert(wheeledPlan.content, "the plan carries its list")
    Assert.equal(#wheeledContent.rows, 7, "the revealed list keeps all seven rows")
    Assert.isTrue(wheeledContent.rows[7].previewRect ~= nil, "the revealed frame carries its sample window")
    for _ = 1, 6 do
      pressKey(game, state, "w")
    end
    Assert.equal(optionsView(game).focusId, "textSpeed", "six ups return to the first row")
    Assert.equal(optionsView(game).scrollOffset, 0, "returning to the top restores the offset")
    -- An abandoned draft changes nothing durable: edit, Quit, reopen.
    local committedSpeed = game.runtime.playerData.options.textSpeed
    local committedVolume = port:read()
    pressKey(game, state, "a")
    optionsView(game)
    cancel(game)
    game:advanceUntil("quit returns to the rebuilt start menu", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.menu
    end, 120)
    Assert.equal(
      game.runtime.playerData.options.textSpeed,
      committedSpeed,
      "quit leaves the live player record untouched"
    )
    Assert.equal(port:read(), committedVolume, "quit leaves the committed volume untouched")
    closeStartMenu(game)
    -- The committed draft keeps Shift, turns Scene Off, doubles the
    -- presentation speed, and raises text speed and volume.
    openOptions(game, state)
    pressKey(game, state, "a")
    pressKey(game, state, "s")
    pressKey(game, state, "d")
    for _ = 1, 3 do
      pressKey(game, state, "s")
    end
    pressKey(game, state, "d")
    pressKey(game, state, "d")
    pressKey(game, state, "s")
    pressKey(game, state, "d")
    pressKey(game, state, "s")
    pressKey(game, state, "d")
    pressKey(game, state, "s")
    Assert.equal(optionsView(game).focusId, "confirm", "the edited rows reach the footer confirm")
    confirm(game)
    game:advanceUntil("confirm returns to the rebuilt start menu", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.menu
    end, 120)
    Assert.equal(
      game.runtime.playerData.options.textSpeed,
      "fast",
      "the confirmed text speed lands on the live player record"
    )
    Assert.equal(game.runtime.playerData.options.battleScene, false, "the confirmed record carries Scene Off")
    Assert.equal(game.runtime.playerData.options.battleStyle, "shift", "the confirmed record keeps Shift")
    Assert.equal(game.runtime.playerData.options.battleSpeed, 2, "the confirmed record carries double speed")
    Assert.equal(port:read(), 82, "the confirmed volume publishes through the app-wide port")
    game:setWorldState({ flag = FLAG_GOT_SAVE })
    closeStartMenu(game)
    openStartMenu(game)
    local saveEntry = actionById(menuStatus(game), "vanilla.save")
    Assert.isTrue(saveEntry ~= nil and saveEntry.enabled, "the granted save entry enables on the recomposed menu")
    navigateTo(game, state, "vanilla.save")
    confirm(game)
    game:advanceUntil("the ordinary save publishes", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.closed and game.lifecycle.saveWrites > 0
    end, 240)
    local reloadedPort = loadStoredRuntime(game)
    game:waitForFieldEntry()
    Assert.equal(
      game.runtime.playerData.options.textSpeed,
      "fast",
      "the ordinary save retains the confirmed player option across reload"
    )
    Assert.equal(
      game.runtime.playerData.options.battleScene,
      false,
      "the ordinary save retains Scene Off across reload"
    )
    Assert.equal(game.runtime.playerData.options.battleSpeed, 2, "the ordinary save retains double speed across reload")
    Assert.equal(reloadedPort:read(), 82, "the app-wide volume carries across the save boundary")
    -- The live values wire into real battles: double speed steps two
    -- quanta per tick, and the trainer fight offers the Shift exchange
    -- while Scene Off omits the optional move program.
    driveMenuSpeedLeg(game)
    driveMenuBattleLeg(game, "launch-options-scene-off", 0)
  end)
end

-- Menu-to-battle wiring through the real owners: the confirmed draft
-- mutates the live player record, and the battle state machines below
-- are the production kernel, screen, timeline, scenario, and envelope
-- modules driven with those live values. Only harness setup (fakes,
-- party/scenario construction, decision driving) is local; no battle
-- offer, animation, or pacing logic is reimplemented here.
local function stageMenuTackle(staging)
  local BattleAnimationCompiler = require("romdump.src.digest.battle.BattleAnimationCompiler")
  local EffectStaging = require("tests.support.EffectStagingFixture")
  local function probeU32(value)
    return string.char(
      value % 256,
      math.floor(value / 256) % 256,
      math.floor(value / 65536) % 256,
      math.floor(value / 16777216) % 256
    )
  end
  local parts = {}
  for _, word in ipairs({ 29, 50, 4 }) do
    parts[#parts + 1] = probeU32(word)
  end
  local program = assert(BattleAnimationCompiler.compile({ key = "TACKLE", stream = table.concat(parts) }))
  local record = EffectStaging.effectRecord("TACKLE", {})
  record.program = {
    entry = program.entry,
    instructions = program.instructions,
    subprograms = program.subprograms,
    taskKinds = program.taskKinds,
  }
  staging:stageEffect("TACKLE", record, {})
end

local function stagingBackedAssets(staging)
  local assets = {}
  function assets.prepare(demand)
    return staging.services.prepare(demand)
  end
  function assets.drawable(imageKey)
    local staged = staging.services.drawable(imageKey)
    if staged ~= nil then
      return staged
    end
    return { handle = imageKey, width = 256, height = 192 }
  end
  function assets.release(imageKey)
    staging.services.release(imageKey)
  end
  assets.requestEffect = staging.services.requestEffect
  assets.loadEffect = staging.services.loadEffect
  assets.resolveEffectResource = staging.services.resolveEffectResource
  assets.releaseEffectResource = staging.services.releaseEffectResource
  return assets
end

-- Opens one real deterministic trainer battle over the live confirmed
-- player record: the kernel reads battleStyle from the same options
-- table the menu just mutated, and the screen freezes the same
-- battleScene beside it.
local function openMenuBattle(game, launchId)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local HgssBagService = require("libs.hgss.src.items.HgssBagService")
  local ItemFixture = require("libs.items.tests.item_fixture")
  local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")
  local BattleScreenState = require("game.hgss.tests.support.BattleScreenFixture")
  local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")
  local StagingFixture = require("tests.support.EffectStagingFixture")
  local SourceTick = require("libs.hgss.src.field.SourceTick")
  local Lcrng = require("libs.mons.src.gen4.Lcrng")
  local MonsSave = require("libs.mons.src.MonsSave")
  local Party = require("libs.mons.src.Party")
  local liveOptions = assert(game.runtime.playerData.options, "the menu wires the live player options")
  local holder = {}
  local rig = {
    submits = {},
    packets = {},
    text = { draws = {} },
    windows = { calls = {} },
    audio = { plays = {} },
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
  function rig.audio.stop(_)
    return true
  end
  function rig.audio.isFinished(_)
    return true
  end
  local staging = StagingFixture.new({ launchId = launchId })
  stageMenuTackle(staging)
  rig.staging = staging
  local catalog = CatalogFixture.makeCatalog()
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
  local function giveMon(species, level, seed, currentHp)
    local factory = CatalogFixture.makeFactory(seed, catalog)
    local record = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level }))
    record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
    if currentHp ~= nil then
      record.condition.currentHp = currentHp
    end
    Assert.isTrue(owner:addMon(record), "the menu battle needs its party member")
  end
  giveMon("EEVEE", 20, 0x33333333)
  giveMon("EEVEE", 5, 0x44444444)
  owner.swapPartyMons = function()
    error("a battle switch never reorders the persistent party", 2)
  end
  rig.party = owner
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  rig.bag = bag
  local function makeFoe(species, level, seed, currentHp)
    local factory = CatalogFixture.makeFactory(seed, catalog)
    local record = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level }))
    record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
    if currentHp ~= nil then
      record.condition.currentHp = currentHp
    end
    return record
  end
  local foeLead = makeFoe("EEVEE", 4, 0x5EED0002, 1)
  local foeReserve = makeFoe("PICHU", 4, 0x5EED0003)
  local trainerId = launchId .. "-trainer"
  local scenario = ScenarioFactory.fromTrainer({
    id = launchId .. "-scenario",
    format = "single",
    trainers = {
      {
        id = trainerId,
        name = "JOEY",
        class = "YOUNGSTER",
        party = { foeLead, foeReserve },
        aiPasses = {},
      },
    },
  }, {
    party = owner,
    bag = bag,
    player = { trainerId = 99, trainerName = "MINT", language = "english", trainerClassKey = "PKMN_TRAINER_ETHAN" },
  })
  local manifest = ManifestFixture.manifest()
  manifest.scenes = { { key = "general/plain/day", background = "general", terrain = "plain", time = "day" } }
  local screen = BattleScreenState.new({
    launchId = launchId,
    manifest = manifest,
    model = BattlePresentationModel,
    submit = function(reply)
      rig.submits[#rig.submits + 1] = reply
      return holder.battle:submit(reply)
    end,
    measureDisplay = function()
      return {
        width = 256,
        height = 384,
        topology = ScreenTopology.oneDisplay({
          id = "main",
          rect = { x = 0, y = 0, width = 256, height = 384 },
          touch = false,
          role = "world",
        }),
        pixelRatio = 1,
        signature = "options-menu-battle",
      }
    end,
    itemCatalog = ItemFixture.makeCatalog(),
    monCatalog = CatalogFixture.makeCatalog(),
    assets = stagingBackedAssets(staging),
    text = rig.text,
    windows = rig.windows,
    audio = rig.audio,
    battleScene = liveOptions.battleScene,
  })
  rig.screen = screen
  local port = screen:presentationPort()
  local present = port.present
  port.present = function(packet)
    rig.packets[#rig.packets + 1] = packet
    return present(packet)
  end
  rig.port = port
  holder.battle = BattleRuntime.new({
    request = { id = launchId, kind = "trainer", payload = { trainer = trainerId } },
    scenario = scenario,
    party = owner,
    bag = bag,
    player = {
      record = { profile = game.runtime.playerData.profile, options = liveOptions },
      context = {},
    },
    presentation = rig.port,
    seed = 0x12345678,
  })
  rig.battle = holder.battle
  function rig.pump(ticks)
    for _ = 1, ticks or 1 do
      rig.battle:update()
      rig.screen:updateFixed(SourceTick.DT)
    end
  end
  return rig
end

local function ackMenuBattleNarration(rig)
  local mode = rig.screen:status().mode
  if
    mode == "intro"
    or mode == "narration"
    or mode == "outcome"
    or rig.screen._timeline:messageActive()
    or rig.screen._timeline:levelUpStats() ~= nil
  then
    rig.screen:input({ { type = "confirm" } })
  end
end

local function awaitMenuBattleDecision(rig, wanted)
  for _ = 1, 240 do
    ackMenuBattleNarration(rig)
    local status = rig.battle:status()
    if status.phase == "failed" then
      error("the menu battle failed while awaiting " .. wanted .. ": " .. tostring(status.error), 0)
    end
    if status.phase == "complete" then
      error("the menu battle settled before asking for " .. wanted, 0)
    end
    if status.request ~= nil then
      if wanted == "shift" then
        local options = rig.battle:decisionOptions(status.request.requestId)
        if options ~= nil then
          for _, actor in ipairs(options.actors or {}) do
            if type(actor) == "table" and actor.kind == "shift" then
              return status.request
            end
          end
        end
      elseif status.request.kind == wanted then
        return status.request
      end
    end
    rig.pump(4)
  end
  error("the menu battle never asked for " .. wanted, 0)
end

local function submitMenuBattleMove(rig, request)
  local options = rig.battle:decisionOptions(request.requestId)
  Assert.notNil(options, "the opening turn projects its options")
  for _, actor in ipairs(options.actors or {}) do
    for _, choice in ipairs(actor.choices or {}) do
      if choice.role == "move" and choice.enabled == true then
        local ok, submitErr = rig.battle:submit({
          requestId = request.requestId,
          epoch = request.epoch,
          controller = request.controller,
          choices = { choice.choice },
        })
        Assert.isTrue(ok, "the opening strike is accepted: " .. tostring(submitErr))
        return
      end
    end
  end
  error("the opening request carries an enabled move", 0)
end

local function tackleDemands(rig)
  local total = 0
  for _, requested in ipairs(rig.staging.requests) do
    if requested == "TACKLE" then
      total = total + 1
    end
  end
  return total
end

-- Confirms one real deterministic trainer battle leg from the live menu
-- values: the Shift offer appears under the confirmed style, the
-- executed TACKLE admits or omits its animation per the confirmed
-- scene, and the answered offer releases the frozen arrival.
driveMenuBattleLeg = function(game, launchId, expectTackleDemands)
  local rig = openMenuBattle(game, launchId)
  local leadBefore = rig.party:partyMon(0)
  local opening = awaitMenuBattleDecision(rig, "action")
  submitMenuBattleMove(rig, opening)
  local request = awaitMenuBattleDecision(rig, "shift")
  local options = rig.battle:decisionOptions(request.requestId)
  Assert.notNil(options, "the shift request projects its options")
  local actor = nil
  for _, entry in ipairs(options.actors or {}) do
    if type(entry) == "table" and entry.kind == "shift" then
      actor = entry
    end
  end
  Assert.notNil(actor, "the shift request addresses its shift actor")
  local stay = nil
  local preview = nil
  for _, choice in ipairs(actor.choices or {}) do
    if choice.id == "shift:stay" then
      stay = choice.choice
    end
  end
  Assert.notNil(stay, "the shift offer carries its stay fragment")
  for _, packet in ipairs(rig.packets) do
    local published = packet.request
    if type(published) == "table" and published.requestId == request.requestId then
      for _, entry in ipairs((published.options or {}).actors or {}) do
        if type(entry) == "table" and entry.kind == "shift" and type(entry.preview) == "table" then
          preview = entry.preview
        end
      end
    end
  end
  Assert.notNil(preview, "the published offer carries its minimal preview")
  Assert.equal(preview.incomingName, "PICHU", "the offer names the frozen arrival")
  Assert.equal(preview.trainerName, "JOEY", "the offer names the opposing trainer")
  for _ = 1, 20 do
    ackMenuBattleNarration(rig)
    rig.pump(1)
  end
  local pending = rig.battle:status()
  Assert.notNil(pending.request, "the shift offer holds without input")
  Assert.equal(tackleDemands(rig), expectTackleDemands, "the executed TACKLE admits per the confirmed scene")
  local ok, submitErr = rig.battle:submit({
    requestId = request.requestId,
    epoch = request.epoch,
    controller = request.controller,
    choices = { stay },
  })
  Assert.isTrue(ok, "the stay answer is accepted: " .. tostring(submitErr))
  local following = awaitMenuBattleDecision(rig, "action")
  Assert.isTrue(following.requestId ~= request.requestId, "the answered offer releases its decision")
  local arrivals = 0
  for _, packet in ipairs(rig.packets) do
    for _, event in ipairs(packet.events or {}) do
      if event.kind == "switch" and type(event.payload) == "table" and event.payload.to ~= nil then
        arrivals = arrivals + 1
      end
    end
  end
  Assert.isTrue(arrivals >= 1, "staying still releases the frozen arrival")
  Assert.deepEqual(rig.party:partyMon(0), leadBefore, "staying never touches the persistent party")
  rig.screen:dispose()
end

-- Runs one source quantum through the production presentation envelope
-- with the live confirmed speed: 2x must step two complete quanta.
driveMenuSpeedLeg = function(game)
  local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")
  local SourceTick = require("libs.hgss.src.field.SourceTick")
  local liveSpeed = assert(game.runtime.playerData.options.battleSpeed, "the menu wires the live presentation speed")
  Assert.equal(liveSpeed, 2, "the confirmed draft carries double speed")
  local cache = { versionId = "options-menu-speed" }
  function cache:loadLua(_)
    return nil
  end
  function cache:read(_)
    return nil
  end
  function cache:exists(...)
    return false
  end
  local derived = {}
  function derived.requestBattleScene(_, _)
    return false
  end
  local envelope = FieldBattlePresentation.new({
    cacheFs = cache,
    windows = {},
    text = {},
    measureDisplay = function()
      return { width = 256, height = 384, topology = {}, pixelRatio = 1, signature = "options-menu-speed" }
    end,
    graphics = {},
    derivedAssets = derived,
  })
  local host = { phase = "active", advances = 0 }
  function host.status()
    return { phase = host.phase }
  end
  function host.advance()
    host.advances = host.advances + 1
  end
  function host.submit(_)
    return true
  end
  function host.notify(_, _) end
  local port = envelope:factory()({
    launchId = "options-menu-speed",
    kind = "wild",
    environment = { sceneKey = "general/grass/day" },
    host = host,
    battleSpeed = liveSpeed,
  })
  Assert.notNil(port, "admission hands back its pending port")
  local screen = { updates = 0 }
  function screen:updateFixed(_)
    screen.updates = screen.updates + 1
  end
  function screen:status()
    return { mode = "ready" }
  end
  function screen:dispose() end
  function screen:cancelPointerCapture() end
  envelope._screen = screen
  envelope:updateFixed(SourceTick.DT)
  Assert.equal(host.advances, 2, "double speed advances its launch twice per source tick")
  Assert.equal(screen.updates, 2, "double speed steps its screen twice per source tick")
  pcall(function()
    port.dispose()
  end)
  pcall(function()
    envelope:dispose()
  end)
end

return T
