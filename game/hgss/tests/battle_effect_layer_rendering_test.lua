-- Native effect layering at the production render boundary: transient
-- pictures publish detached in allocation order, effect background
-- layers install over the persistent scene and remove without touching
-- it, and a full particle, model, and effect-background run over each
-- layer class restores the clean scene exactly, even when the incoming
-- graphics state was poisoned and foreign lighting state is present.
-- Setup below holds today through the real scene and raster paths; the
-- execution gate drives the battle-private program player together with
-- the battle-private effect task factory once both exist.
-- Native mechanism: overlay-7 effect backdrops over the overlay-12 BG3
-- scene with native blend, mask, depth, and priority decisions
-- (pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36).
-- Headless: the scene raster composes on the CPU; the recorder doubles
-- record only.

local Assert = require("tests.support.Assert")
local BattleAnimationCompiler = require("romdump.src.digest.battle.BattleAnimationCompiler")
local BattleAnimationSchema = require("libs.assets.src.battle.BattleAnimationSchema")
local BattleAnimationSources = require("romdump.src.config.BattleAnimationSources")
local BattlePresentationFlow = require("game.hgss.src.battle.BattlePresentationFlow")
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")
local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")

local T = {}

local function u32(value)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

local function streamOf(list)
  local parts = {}
  for _, word in ipairs(list) do
    parts[#parts + 1] = u32(word)
  end
  return table.concat(parts)
end

local function lowered(key, list)
  local program = assert(BattleAnimationCompiler.compile({ key = key, stream = streamOf(list) }))
  Assert.isTrue(
    BattleAnimationSchema.assertProgram({
      entry = program.entry,
      instructions = program.instructions,
      subprograms = program.subprograms,
      taskKinds = program.taskKinds,
    }),
    "the lowered program validates against the shared program shape"
  )
  return program
end

local function flatPalette(red, green, blue)
  local colors = {}
  for _ = 1, 16 do
    colors[#colors + 1] = { r = red, g = green, b = blue }
  end
  return colors
end

local function baseBackground()
  return {
    characters = string.rep("\0", 32),
    colorMode = "4bpp",
    map = {
      width = 8,
      height = 8,
      entries = { { tile = 0, flipH = false, flipV = false, palette = 0 } },
    },
    palette = { colors = flatPalette(8, 16, 24) },
  }
end

local function effectLayer()
  return {
    character = { depth = 3, tiles = string.rep("\0", 32) },
    screen = {
      width = 8,
      height = 8,
      entries = { { tile = 0, flipH = false, flipV = false, palette = 0 } },
    },
    palette = { colors = flatPalette(200, 40, 40) },
  }
end

local function stagedPicture(assetKey, selector)
  return {
    assetKey = assetKey,
    selector = selector,
    centerX = 64,
    centerY = 112,
    zCenter = 0,
    width = 64,
    height = 64,
    alpha = 1,
  }
end

local function sceneWithPair()
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  return scene
end

local function playbackPacket()
  local packet = BattlePresentationModel.packet({}, { events = {} }, {}, {
    launchId = "layer-rendering-probe",
    packetId = 1,
  })
  Assert.equal(packet.launchId, "layer-rendering-probe", "the playback input carries its launch identity")
  return packet
end

-- Builds the picture program's playback through the production event-time
-- topology constructor: the live screen admits picture shows only with
-- the frozen semantic slots behind the accepted event, never a bare
-- packet. The selected program and the scene-restoration assertions
-- below are unchanged; only the packet carries what production builds.
---@param key string selected effect key under playback
---@return table<string, unknown> detached playback packet with production-built topology
local function topologyPlayback(key)
  local views = {
    own = { { combatant = 1, activation = 1, side = 1, position = 1 } },
    foes = { { combatant = 3, activation = 3, side = 2, position = 2 } },
  }
  local packet = {
    launchId = "layer-rendering-probe",
    packetId = 1,
    before = views,
    after = views,
  }
  local event = {
    sequence = 1,
    actionId = 1,
    hitIndex = 1,
    effectKey = key,
    actors = { { combatant = 1, activation = 1 } },
    targets = { { combatant = 3, activation = 3 } },
    visualSeed = 4242,
  }
  local geometry = ManifestFixture.manifest().battlefield.slots
  return BattlePresentationFlow.animationPlayback(packet, event, geometry)
end

local function playerModule()
  local ok, Player = pcall(require, "libs.hgss.src.presentation.BattleAnimationPlayer")
  Assert.isTrue(ok, "the battle-private animation player resolves through the presentation boundary")
  Assert.equal(type(Player.new), "function", "the player exposes its construction entry point")
  return Player
end

local function effectFactoryModule()
  local ok, Factory = pcall(require, "libs.hgss.src.presentation.BattleEffectTasks")
  Assert.isTrue(ok, "the battle-private effect task factory resolves through the presentation boundary")
  Assert.equal(type(Factory.create), "function", "the factory exposes its task construction entry point")
  return Factory
end

function T.effect_pictures_publish_detached_in_allocation_order()
  local scene = sceneWithPair()
  local first = scene:allocEffect("layer-probe")
  local second = scene:allocEffect("layer-probe")
  scene:setEffectPicture(first.id, stagedPicture("staged-first", "first"))
  scene:setEffectPicture(second.id, stagedPicture("staged-second", "second"))
  local views = scene:effectViews()
  Assert.equal(#views, 2, "both transient effects publish")
  Assert.isTrue(views[1].id < views[2].id, "records publish in launch allocation order")
  Assert.equal(views[1].picture.assetKey, "staged-first", "the first record carries its staged drawable")
  views[1].picture.centerX = -9999
  views[1].picture.assetKey = "mutated"
  local reread = scene:effectViews()
  Assert.equal(reread[1].picture.centerX, 64, "mutating a published view never moves the stored picture")
  Assert.equal(reread[1].picture.assetKey, "staged-first", "mutating a published view never renames the stored asset")
end

function T.effect_background_layers_install_and_remove_cleanly()
  local scene = sceneWithPair()
  Assert.isFalse(scene:hasBackground(), "no staged background exists before installation")
  scene:installBackground(baseBackground())
  Assert.isTrue(scene:hasBackground(), "the persistent scene installs")
  local snapshot = scene:background()
  snapshot.map.entries[1].tile = 511
  snapshot.palette.colors[1].r = 255
  local reread = scene:background()
  Assert.equal(reread.map.entries[1].tile, 0, "the installed map keeps no alias to the snapshot")
  Assert.equal(reread.palette.colors[1].r, 8, "the installed palette keeps no alias to the snapshot")
  scene:installBackgroundLayer("effect-veil", effectLayer())
  local duplicated = Assert.throws(function()
    scene:installBackgroundLayer("effect-veil", effectLayer())
  end, "a duplicate effect layer key never installs twice")
  Assert.isTrue(
    string.find(tostring(duplicated), "effect layer keys are unique", 1, true) ~= nil,
    "the duplicate rejection names the ownership rule"
  )
  local unknown = Assert.throws(function()
    scene:removeBackgroundLayer("no-such-layer")
  end, "removing an unknown layer never succeeds silently")
  Assert.isTrue(
    string.find(tostring(unknown), "no-such-layer", 1, true) ~= nil,
    "the unknown-layer rejection names the layer"
  )
  scene:patchBackgroundMap(0, { tile = 0, flipH = true, flipV = false, palette = 0 })
  scene:patchBackgroundPalette(0, { r = 1, g = 2, b = 3 })
  scene:removeBackgroundLayer("effect-veil")
  local settled = scene:background()
  Assert.equal(settled.map.entries[1].flipH, true, "base map patches survive the layer removal")
  Assert.equal(settled.palette.colors[1].g, 2, "base palette patches survive the layer removal")
  scene:release()
  Assert.isFalse(scene:hasBackground(), "launch release drops the staged background")
end

function T.effect_runs_over_each_layer_class_restore_the_clean_scene_exactly()
  local pristine = sceneWithPair()
  pristine:installBackground(baseBackground())
  local cleanRaster = pristine:backgroundRaster()
  Assert.deepEqual(
    pristine:backgroundRaster(),
    cleanRaster,
    "repeated raster reads agree without advancing anything"
  )
  local poisoned = sceneWithPair()
  poisoned:installBackground(baseBackground())
  poisoned:patchBackgroundPalette(0, { r = 255, g = 255, b = 255 })
  poisoned:patchBackgroundPalette(1, { r = 255, g = 0, b = 255 })
  local programs = {
    lowered("layer-particle-run", { 51, 1, 64, 50, 4 }),
    lowered("layer-wide-run", { 8, 16, 0, 17, 2, 8, 9, 4 }),
    lowered("layer-picture-run", { 31, 0, 1, 31, 1, 1, 50, 4 }),
  }
  local Player = playerModule()
  local Factory = effectFactoryModule()
  local audio = {}
  function audio.play(_name) end
  function audio.stop(_name) end
  function audio.isFinished(_name)
    return true
  end
  local resources = {}
  function resources.resolve(key)
    local _ = key
    local params = {}
    for index = 1, 42 do
      params[index] = 0
    end
    params[29], params[30], params[24], params[32] = 12, 12, 0, 1
    return { features = { "alpha", "random" }, params = params }
  end
  function resources.release(_lease) end
  local player = assert(Player.new({
    scene = poisoned,
    audio = audio,
    resources = resources,
    tasks = Factory,
  }))
  for _, program in ipairs(programs) do
    local packet = playbackPacket()
    if program.key == "layer-picture-run" then
      packet = topologyPlayback(program.key)
    end
    local handle = assert(player:start(packet, program))
    for _ = 1, 120 do
      player:stepSourceTick({ tick = 1 })
      if player:status(handle) == "complete" then
        break
      end
    end
    Assert.equal(player:status(handle), "complete", program.key .. " completes over its layer class")
  end
  player:dispose()
  Assert.equal(#poisoned:effectViews(), 0, "no transient picture survives the effect runs")
  poisoned:patchBackgroundPalette(0, { r = 8, g = 16, b = 24 })
  poisoned:patchBackgroundPalette(1, { r = 8, g = 16, b = 24 })
  Assert.deepEqual(
    poisoned:backgroundRaster(),
    cleanRaster,
    "the restored scene matches the clean raster exactly"
  )
  Assert.deepEqual(poisoned:background(), pristine:background(), "no poisoned color survives restoration")
end

function T.callback_program_mutates_scene_and_completes_at_its_source_boundary()
  local program = assert(BattleAnimationCompiler.compile({
    key = "layer-callback-run",
    stream = streamOf({ 45, 51, 3, 10, 0xFFF0, 258, 50, 4 }),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "battle-animation-callback", "the picture word asks for its source callback")
      return BattleAnimationSources.resolveBattleAnimationCallback(operands)
    end,
  }))
  Assert.isTrue(
    BattleAnimationSchema.assertProgram({
      entry = program.entry,
      instructions = program.instructions,
      subprograms = program.subprograms,
      taskKinds = program.taskKinds,
    }),
    "the lowered program validates against the shared program shape"
  )
  Assert.equal(program.instructions[1].op, "invoke-battle-animation-callback", "the word keeps its callback operation")
  Assert.equal(
    program.instructions[1].taskKind,
    "pokemon-picture-selected-horizontal-offset-transition",
    "the word keeps its source task kind"
  )
  local Player = playerModule()
  local Factory = effectFactoryModule()
  local scene = sceneWithPair()
  local audio = {}
  function audio.play(_name) end
  function audio.stop(_name) end
  function audio.isFinished(_name)
    return true
  end
  local resources = {}
  function resources.resolve(key)
    local _ = key
    local params = {}
    for index = 1, 42 do
      params[index] = 0
    end
    params[29], params[30], params[24], params[32] = 12, 12, 0, 1
    return { features = { "alpha", "random" }, params = params }
  end
  function resources.release(_lease) end
  local player = assert(Player.new({
    scene = scene,
    audio = audio,
    resources = resources,
    tasks = Factory,
  }))
  local packet = playbackPacket()
  packet.event = { sequence = 1, actionId = 1, hitIndex = 1, effectKey = "layer-callback-run" }
  packet.visualSeed = 4242
  packet.topology = {
    attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
    targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
  }
  local handle = assert(player:start(packet, program))
  player:stepSourceTick({ tick = 1 })
  local held = player:status(handle)
  Assert.isTrue(
    held ~= "complete" and held ~= "failed",
    "the source-timed picture run stays alive past its first tick"
  )
  Assert.equal(#scene:effectViews(), 0, "spawning the callback publishes no drawable picture")
  player:stepSourceTick({ tick = 2 })
  local mutated = scene:pictureState({ combatant = 1, activation = 1 }) ~= nil
  Assert.isTrue(mutated, "the running callback owns its activation picture patch")
  Assert.equal(#scene:effectViews(), 0, "the running callback still publishes no drawable picture")
  local ticks = 2
  for _ = 1, 120 do
    if player:status(handle) == "complete" then
      break
    end
    player:stepSourceTick({ tick = 1 })
    ticks = ticks + 1
  end
  Assert.equal(player:status(handle), "complete", "the callback run reaches its own completion")
  Assert.isTrue(ticks >= 10, "the run honors its compiled duration instead of an early fixed budget")
  Assert.isTrue(ticks <= 14, "the run completes at its source boundary instead of stalling")
  Assert.isNil(
    scene:pictureState({ combatant = 1, activation = 1 }),
    "completion restores the activation it moved"
  )
  Assert.equal(#scene:effectViews(), 0, "no transient picture survives the callback run")
  player:dispose()
end

local function stagedEffectHolder(launchId, staging)
  local BattlePresentationAssets = require("game.hgss.src.battle.BattlePresentationAssets")
  local BattlePresentationManifestFixture = require("tests.support.BattlePresentationManifestFixture")
  return BattlePresentationAssets.new({
    assets = staging.services,
    launchId = launchId,
    sceneKey = "probe/plain/day",
    shadowRegions = BattlePresentationManifestFixture.manifest().pictures.shadow.regions,
  })
end

local function stagedSparkEffect(staging, key, width, height)
  local EffectStagingFixture = require("tests.support.EffectStagingFixture")
  local Hashing = require("romdump.src.digest.Hashing")
  local textureBytes = EffectStagingFixture.rgba(width, height)
  local textureIdentity = Hashing.sha1hex(textureBytes)
  staging:stageEffect(
    key,
    EffectStagingFixture.effectRecord(key, {
      { key = "probe-spark", kind = "texture", payload = "effects/probe-spark.lua", contentIdentity = textureIdentity },
    }),
    { ["effects/probe-spark.lua"] = { width = width, height = height, rgba8888 = textureBytes } }
  )
  return textureBytes
end

local function effectDetailView(scene)
  return {
    battlers = {},
    effectInstances = scene:effectViews(),
    hudPatchSpans = {},
    hudSections = {},
  }
end

local function effectDetailResources(graphics, assets)
  return {
    graphics = graphics,
    text = {},
    windows = {},
    assets = assets,
    frameKey = "default",
    sceneImageKey = "scene:probe",
  }
end

-- A staged effect texture reaches the production renderer through the
-- holder: the admitted picture draws through the real scene and render
-- boundary instead of failing on an unknown key.
function T.staged_effect_texture_paints_through_production_renderer()
  local EffectStagingFixture = require("tests.support.EffectStagingFixture")
  local FakeGraphics = require("tests.support.FakeGraphics")
  local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
  local staging = EffectStagingFixture.new({ launchId = "probe-layer-paint" })
  stagedSparkEffect(staging, "TACKLE", 4, 4)
  local assets = stagedEffectHolder("probe-layer-paint", staging)
  Assert.equal(assets:demandEffect("TACKLE"), true, "the staged closure reads ready")
  local effect = assets:loadEffect("TACKLE")
  Assert.notNil(effect, "the ready effect loads before painting")
  local lease = assets:resolveEffectResource(effect, "probe-spark")
  Assert.notNil(lease, "the texture admits before painting")
  Assert.notNil(assets:drawable("probe-spark"), "the admitted texture resolves to a drawable")
  local scene = sceneWithPair()
  local slot = scene:allocEffect("layer-paint-probe")
  scene:setEffectPicture(slot.id, {
    assetKey = "probe-spark",
    selector = "spark",
    centerX = 64,
    centerY = 48,
    zCenter = 0,
    width = 4,
    height = 4,
    alpha = 1,
  })
  local graphics = FakeGraphics.new()
  BattleRenderer.drawPane(effectDetailResources(graphics, assets), effectDetailView(scene), "detail", {})
  Assert.isTrue(#graphics.draws >= 1, "the staged effect picture composes through the production renderer")
  assets:dispose()
end

-- An effect picture whose asset key has no staged drawable fails loudly
-- at the production render boundary: no substitute image is ever drawn.
function T.unknown_effect_image_keys_fail_loudly_without_substitutes()
  local EffectStagingFixture = require("tests.support.EffectStagingFixture")
  local FakeGraphics = require("tests.support.FakeGraphics")
  local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
  local staging = EffectStagingFixture.new({ launchId = "probe-layer-unknown" })
  stagedSparkEffect(staging, "TACKLE", 4, 4)
  local assets = stagedEffectHolder("probe-layer-unknown", staging)
  Assert.equal(assets:demandEffect("TACKLE"), true, "the staged closure reads ready")
  Assert.isNil(assets:drawable("battle/effect-background/blend"), "invented proxy keys never resolve")
  Assert.isNil(assets:drawable("battle/pokemon-picture/reveal"), "invented reveal keys never resolve")
  local scene = sceneWithPair()
  local slot = scene:allocEffect("layer-unknown-probe")
  scene:setEffectPicture(slot.id, {
    assetKey = "battle/effect-background/blend",
    selector = "blend-transition",
    centerX = 128,
    centerY = 80,
    zCenter = 0,
    width = 4,
    height = 4,
    alpha = 1,
  })
  local graphics = FakeGraphics.new()
  local failure = Assert.throws(function()
    BattleRenderer.drawPane(effectDetailResources(graphics, assets), effectDetailView(scene), "detail", {})
  end, "an unstaged effect picture fails instead of drawing a substitute")
  Assert.isTrue(
    tostring(failure):find("transient effect drawables", 1, true) ~= nil,
    "the loud failure names the render boundary: " .. tostring(failure)
  )
  Assert.equal(#graphics.draws, 0, "the rejected picture draws nothing")
  assets:dispose()
end

return { tests = T }
