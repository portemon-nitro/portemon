-- Tick-sampled background pixels for the compiled source background
-- families: selector 68 (alternating scroll) and selector 76 (scanline
-- sine sweep) displace the scene layer through the viewport scroll,
-- selector 28 (power-profiled four-picture transition) shifts owned
-- battler pictures through the task overlay seam, and each family
-- restores its baseline pixels on completion. Selector 38
-- (blend-alpha) holds pixels while its scalar register overlay
-- interpolates: no renderer consumes the scalar overlay yet, so its
-- pixel evidence is the documented null displacement beside the
-- interpolated coefficients.

local Assert = require("tests.support.Assert")
local BattleAnimationCompiler = require("romdump.src.digest.battle.BattleAnimationCompiler")
local BattleAnimationPlayer = require("libs.hgss.src.presentation.BattleAnimationPlayer")
local BattleAnimationSources = require("romdump.src.config.BattleAnimationSources")
local BattleEffectTasks = require("libs.hgss.src.presentation.BattleEffectTasks")
local BattlePicturePass = require("libs.hgss.src.presentation.BattlePicturePass")
local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")

local T = {}

local SCENE_KEY = "scene:bg-tick-probe"
local PORTRAIT_KEY = "mon:LEAD/0/male/plain/back"

local function quantize(channel)
  return math.floor(channel * 255 + 0.5)
end

local function imageDataDigest(data)
  local hash = 2166136261
  for y = 0, data:getHeight() - 1 do
    for x = 0, data:getWidth() - 1 do
      local red, green, blue, alpha = data:getPixel(x, y)
      for _, channel in ipairs({ red, green, blue, alpha }) do
        hash = (hash * 16777619 + quantize(channel)) % 4294967296
      end
    end
  end
  return hash
end

-- Compiles one source callback word-frame through the real producer
-- mapping: the selector, declared count, and raw operand words lower
-- to the semantic callback plan the runtime executes.
---@param words integer[] source stream words under compiling
---@param wantTaskKind string expected lowered task kind
---@return table compiled program
local function compileCallback(words, wantTaskKind)
  local parts = {}
  for _, word in ipairs(words) do
    local value = word % 4294967296
    parts[#parts + 1] = string.char(
      value % 256,
      math.floor(value / 256) % 256,
      math.floor(value / 65536) % 256,
      math.floor(value / 16777216) % 256
    )
  end
  local program = assert(BattleAnimationCompiler.compile({
    key = "probe-bg-tick",
    stream = table.concat(parts),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "battle-animation-callback", "the tick words ask for their source callback")
      return BattleAnimationSources.resolveBattleAnimationCallback(operands)
    end,
  }))
  Assert.equal(
    program.instructions[1].taskKind,
    wantTaskKind,
    "the lowered program keeps its source background task kind"
  )
  return program
end

local function occurrenceTopology()
  return {
    attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
    targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
  }
end

-- Starts one compiled background program on the real player against a
-- real scene: the test-only occurrence driver behind the tick samples.
-- State-only background tasks stage no leases, so the resource facade
-- fails loudly instead of fabricating pixels.
---@param words integer[] source stream words under driving
---@param wantTaskKind string expected lowered task kind
---@param event table occurrence event under driving (carries move power for selector 28)
---@return table run carrying player, handle, ticks, and scene
local function startRun(words, wantTaskKind, event)
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  local audio = {}
  function audio.play(_)
  end
  function audio.stop(_)
  end
  function audio.isFinished(_)
    return true
  end
  local resources = {}
  function resources.resolve(key)
    error("state-only background tasks stage no leases: " .. tostring(key), 0)
  end
  function resources.release(_lease)
    error("state-only background tasks release no leases", 0)
  end
  local player = assert(BattleAnimationPlayer.new({
    scene = scene,
    audio = audio,
    resources = resources,
    tasks = BattleEffectTasks,
  }))
  local program = compileCallback(words, wantTaskKind)
  local handle = assert(player:start({
    launchId = "probe-bg-tick",
    packetId = 1,
    event = event,
    visualSeed = 4242,
    topology = occurrenceTopology(),
  }, program))
  return { player = player, handle = handle, scene = scene, ticks = 0 }
end

-- Steps the driven player run forward one source tick.
---@param run table live occurrence run under sampling
local function stepPlayer(run)
  Assert.isTrue(
    run.player:status(run.handle) ~= "complete" and run.player:status(run.handle) ~= "failed",
    "the run stays alive while sampling player tick " .. tostring(run.ticks + 1)
  )
  run.player:stepSourceTick({ tick = 1 })
  run.ticks = run.ticks + 1
end

-- Steps the driven player run forward to the given player tick. The
-- invoke chain spawns its task on the first player tick without
-- stepping it (the player steps owned tasks before running the spawn
-- chain), so task tick N lands on player tick N + 1; every test below
-- grounds that offset by asserting untouched task state after the
-- spawn tick before sampling task ticks.
---@param run table live occurrence run under sampling
---@param tick integer player tick under reaching
local function stepToPlayerTick(run, tick)
  while run.ticks < tick do
    stepPlayer(run)
  end
end

-- Drains the driven run to its terminal status.
---@param run table live occurrence run under draining
local function drainRun(run)
  for _ = 1, 120 do
    if run.player:status(run.handle) == "complete" then
      return
    end
    run.player:stepSourceTick({ tick = 1 })
    run.ticks = run.ticks + 1
  end
  error("the background run reaches its compiled completion", 0)
end

local function checkerScene(scope, width, height, cell)
  local data = scope:own(love.image.newImageData(width, height))
  data:mapPixel(function(x, y)
    local cx = math.floor(x / cell) % 2
    local cy = math.floor(y / cell) % 2
    if cx == 0 and cy == 0 then
      return 1, 0, 0, 1
    end
    if cx == 1 and cy == 0 then
      return 0, 1, 0, 1
    end
    if cx == 0 and cy == 1 then
      return 0, 0, 1, 1
    end
    return 1, 1, 0, 1
  end)
  return scope:own(love.graphics.newImage(data))
end

local function stripedPortrait(scope)
  local data = scope:own(love.image.newImageData(128, 128))
  data:mapPixel(function(x, y)
    local cx = math.floor(x / 8) % 2
    local cy = math.floor(y / 8) % 2
    if cx == 0 and cy == 0 then
      return 1, 0, 0, 1
    end
    if cx == 1 and cy == 0 then
      return 0, 1, 0, 1
    end
    if cx == 0 and cy == 1 then
      return 0, 0, 1, 1
    end
    return 1, 1, 1, 1
  end)
  return scope:own(love.graphics.newImage(data))
end

local function rasterImage(scope, raster)
  local data = scope:own(love.image.newImageData(raster.width, raster.height, "rgba8"))
  for y = 0, raster.height - 1 do
    for x = 0, raster.width - 1 do
      local red, green, blue, alpha = raster:pixel(x, y)
      data:setPixel(x, y, red / 255, green / 255, blue / 255, alpha / 255)
    end
  end
  return scope:own(love.graphics.newImage(data))
end

-- Installs a two-tile black/white checkerboard as the decoded BG3
-- payload so the background-raster branch draws Scroll-sensitive
-- staged pixels.
---@return table staged BG3 payload
local function checkerBackground()
  local palette = {}
  for index = 0, 255 do
    palette[index + 1] = { r = 0, g = 0, b = 0 }
  end
  palette[2] = { r = 255, g = 255, b = 255 }
  -- Map spans are pixels: an 8x8-tile checkerboard covers the 64x64
  -- raster the canvas samples.
  local entries = {}
  for ty = 0, 7 do
    for tx = 0, 7 do
      entries[#entries + 1] = { tile = (tx + ty) % 2, flipH = false, flipV = false, palette = 0 }
    end
  end
  return {
    characters = string.rep("\0", 64) .. string.rep("\1", 64),
    colorMode = "8bpp",
    map = { width = 64, height = 64, entries = entries },
    palette = { colors = palette },
  }
end

local function scrolledView(manifest, scene, battlers, backgroundRaster)
  return {
    slotGeometry = manifest.battlefield.slots,
    hudPatchSpans = manifest.hud.patchSpans,
    hudSections = { player = manifest.hud.player, enemy = manifest.hud.enemy },
    mode = "idle",
    message = "",
    battlers = battlers,
    effectInstances = {},
    bgScroll = scene:scroll(),
    backgroundRaster = backgroundRaster,
  }
end

-- Renders one frame through the production detail pane and digests it.
-- The view carries no background raster here, so the harness takes the
-- sceneImageKey branch; the viewport scroll still displaces the scene
-- layer on that branch.
---@param scope table test-owned graphics scope
---@param canvas table reusable readable canvas
---@param assets table injected asset holder under drawing
---@param manifest table presentation manifest under drawing
---@param scene table live scene carrying the viewport under sampling
---@return integer frame digest
local function renderScrollFrame(scope, canvas, assets, manifest, scene)
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  BattleRenderer.drawPane({
    graphics = love.graphics,
    text = {},
    windows = {},
    assets = assets,
    frameKey = "default",
    sceneImageKey = SCENE_KEY,
  }, scrolledView(manifest, scene, {}, nil), "detail", {})
  love.graphics.setCanvas()
  return imageDataDigest(scope:own(canvas:newImageData()))
end

local function probeEvent(extra)
  local event = { sequence = 1, actionId = 1, hitIndex = 1, effectKey = "probe-bg-tick" }
  if extra ~= nil then
    for key, value in pairs(extra) do
      event[key] = value
    end
  end
  return event
end

-- Selector 68 lowers to the repo ramp-hold law: the opening phase
-- ramps from zero toward its extreme over the direction ticks and holds
-- the extreme over the phase interval, and the next phase holds the
-- opposite extreme. (Native ShakeBg alternates every tick instead; the
-- pixels below assert the repo law.) With offsets (8, 0), three ticks
-- per direction, two direction changes, and a one-tick hold, the eight
-- compiled ticks read 2, 5, 8, 8, -8, -8, -8, -8 before completion
-- restores the saved viewport.
function T.alternating_scroll_tick_samples_displace_and_restore(scope, context)
  local _ = context
  local manifest = ManifestFixture.manifest()
  local run = startRun(
    { 45, 68, 6, 8, 0, 3, 2, 1, 0, 50, 4 },
    "battle-background-alternating-scroll-transition",
    probeEvent()
  )
  local assets = {
    drawable = function(_, key)
      if key == SCENE_KEY then
        return checkerScene(scope, 256, 192, 8)
      end
      return nil
    end,
  }
  local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true }))
  local baseline = renderScrollFrame(scope, canvas, assets, manifest, run.scene)
  stepToPlayerTick(run, 1)
  local scroll = run.scene:scroll()
  Assert.deepEqual(
    { scroll.x, scroll.y },
    { 0, 0 },
    "the spawn tick writes no viewport: task tick N lands on player tick N + 1"
  )
  -- Task tick 1 rides player tick 2.
  stepToPlayerTick(run, 2)
  scroll = run.scene:scroll()
  Assert.deepEqual({ scroll.x, scroll.y }, { 2, 0 }, "the repo ramp climbs toward its extreme")
  local climbing = renderScrollFrame(scope, canvas, assets, manifest, run.scene)
  -- Task tick 3 rides player tick 4.
  stepToPlayerTick(run, 4)
  scroll = run.scene:scroll()
  Assert.deepEqual(
    { scroll.x, scroll.y },
    { 8, 0 },
    "the repo ramp reaches its extreme on the direction ticks"
  )
  local firstExtreme = renderScrollFrame(scope, canvas, assets, manifest, run.scene)
  -- Task tick 5 rides player tick 6.
  stepToPlayerTick(run, 6)
  scroll = run.scene:scroll()
  Assert.deepEqual(
    { scroll.x, scroll.y },
    { -8, 0 },
    "the next phase holds the opposite extreme"
  )
  local opposite = renderScrollFrame(scope, canvas, assets, manifest, run.scene)
  Assert.isTrue(climbing ~= baseline, "the climbing ramp displaces baseline pixels")
  Assert.isTrue(
    firstExtreme ~= baseline and firstExtreme ~= climbing,
    "the first extreme paints its own displaced frame"
  )
  Assert.isTrue(
    opposite ~= baseline and opposite ~= climbing and opposite ~= firstExtreme,
    "the opposite extreme paints a third displaced frame"
  )
  drainRun(run)
  Assert.equal(run.player:status(run.handle), "complete", "the alternating run reaches its compiled completion")
  Assert.equal(#run.scene:effectViews(), 0, "the scroll sweep publishes no drawable pictures")
  scroll = run.scene:scroll()
  Assert.deepEqual({ scroll.x, scroll.y }, { 0, 0 }, "completion restores the saved viewport")
  Assert.equal(
    renderScrollFrame(scope, canvas, assets, manifest, run.scene),
    baseline,
    "completion restores baseline pixels"
  )
  run.player:dispose()
end

-- Selector 76 rides a full sine cycle over its compiled duration at the
-- minimal one-pixel amplitude the wave law can express. Over twelve
-- ticks the viewport reads 0, 0, 1, 1, 1, 0, 0, 0, -1, -1, -1, 0 before
-- completion restores the saved viewport.
function T.scanline_sine_tick_samples_displace_and_restore(scope, context)
  local _ = context
  local manifest = ManifestFixture.manifest()
  local run = startRun(
    { 45, 76, 1, 12, 50, 4 },
    "battle-background-scanline-sine-wave-transition",
    probeEvent()
  )
  local assets = {
    drawable = function(_, key)
      if key == SCENE_KEY then
        return checkerScene(scope, 256, 192, 8)
      end
      return nil
    end,
  }
  local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true }))
  local baseline = renderScrollFrame(scope, canvas, assets, manifest, run.scene)
  stepToPlayerTick(run, 1)
  local scroll = run.scene:scroll()
  Assert.deepEqual(
    { scroll.x, scroll.y },
    { 0, 0 },
    "the spawn tick writes no viewport: task tick N lands on player tick N + 1"
  )
  -- Task tick 3 rides player tick 4.
  stepToPlayerTick(run, 4)
  scroll = run.scene:scroll()
  Assert.deepEqual({ scroll.x, scroll.y }, { 0, 1 }, "the sine crest lifts the viewport one pixel")
  local crest = renderScrollFrame(scope, canvas, assets, manifest, run.scene)
  -- Task tick 6 rides player tick 7.
  stepToPlayerTick(run, 7)
  scroll = run.scene:scroll()
  Assert.deepEqual({ scroll.x, scroll.y }, { 0, 0 }, "the sine crosses its origin mid-run")
  Assert.equal(
    renderScrollFrame(scope, canvas, assets, manifest, run.scene),
    baseline,
    "the origin crossing paints baseline pixels mid-run"
  )
  -- Task tick 9 rides player tick 10.
  stepToPlayerTick(run, 10)
  scroll = run.scene:scroll()
  Assert.deepEqual({ scroll.x, scroll.y }, { 0, -1 }, "the sine trough drops the viewport one pixel")
  local trough = renderScrollFrame(scope, canvas, assets, manifest, run.scene)
  Assert.isTrue(crest ~= baseline, "the crest displaces baseline pixels")
  Assert.isTrue(trough ~= baseline and trough ~= crest, "the trough paints its own displaced frame")
  drainRun(run)
  Assert.equal(run.player:status(run.handle), "complete", "the sine run reaches its compiled completion")
  Assert.equal(#run.scene:effectViews(), 0, "the sine sweep publishes no drawable pictures")
  scroll = run.scene:scroll()
  Assert.deepEqual({ scroll.x, scroll.y }, { 0, 0 }, "completion restores the saved viewport")
  Assert.equal(
    renderScrollFrame(scope, canvas, assets, manifest, run.scene),
    baseline,
    "completion restores baseline pixels"
  )
  run.player:dispose()
end

-- The decoded background-raster branch honors the same viewport
-- scroll: with a staged BG3 checkerboard installed, the tick-3 extreme
-- of the selector-68 sweep displaces raster pixels and completion
-- restores them. This confirms the backgroundRaster branch the
-- sceneImageKey-only views above do not exercise.
function T.alternating_scroll_displaces_the_decoded_background_raster(scope, context)
  local _ = context
  local manifest = ManifestFixture.manifest()
  local run = startRun(
    { 45, 68, 6, 8, 0, 3, 2, 1, 0, 50, 4 },
    "battle-background-alternating-scroll-transition",
    probeEvent()
  )
  run.scene:installBackground(checkerBackground())
  local raster = run.scene:backgroundRaster()
  local effectImage = rasterImage(scope, raster)
  local assets = {
    drawable = function(_, key)
      if key == SCENE_KEY then
        return effectImage
      end
      return nil
    end,
    background = function()
      return effectImage
    end,
  }
  local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true }))
  local function renderRaster()
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    BattleRenderer.drawPane({
      graphics = love.graphics,
      text = {},
      windows = {},
      assets = assets,
      frameKey = "default",
      sceneImageKey = SCENE_KEY,
    }, scrolledView(manifest, run.scene, {}, raster), "detail", {})
    love.graphics.setCanvas()
    return imageDataDigest(scope:own(canvas:newImageData()))
  end
  local baseline = renderRaster()
  stepToPlayerTick(run, 1)
  local scroll = run.scene:scroll()
  Assert.deepEqual(
    { scroll.x, scroll.y },
    { 0, 0 },
    "the spawn tick writes no viewport: task tick 3 rides player tick 4"
  )
  stepToPlayerTick(run, 4)
  scroll = run.scene:scroll()
  Assert.deepEqual({ scroll.x, scroll.y }, { 8, 0 }, "the raster run reaches its first extreme on schedule")
  Assert.isTrue(renderRaster() ~= baseline, "the extreme displaces decoded raster pixels")
  drainRun(run)
  Assert.equal(run.player:status(run.handle), "complete", "the raster run reaches its compiled completion")
  scroll = run.scene:scroll()
  Assert.deepEqual({ scroll.x, scroll.y }, { 0, 0 }, "completion restores the saved viewport")
  Assert.equal(renderRaster(), baseline, "completion restores baseline raster pixels")
  run.player:dispose()
end

local function attackerBattler()
  return {
    combatant = 1,
    activation = 1,
    side = 1,
    position = 0,
    name = "LEAD",
    level = 7,
    hp = 20,
    maxHp = 20,
    active = true,
    visible = true,
    portraitSelector = "LEAD/0/male/plain/back",
    pictureVisible = true,
  }
end

local function renderPictures(scope, graphics, pictures)
  local pass = scope:own(BattlePicturePass.new(graphics))
  return pass:render(graphics, pictures)
end

-- Selector 28 resolves the executed move power through its compiled
-- ladder to a source profile and sweeps every owned battler picture
-- through a staggered out-and-back arc scaled by that profile. Power
-- 50 selects profile 2 (reach 16): the attacker reads crop (15, 3) on
-- tick 1 and (9, 2) on tick 2 while the target still waits, and
-- completion drops every overlay exactly.
function T.move_power_profile_tick_samples_shift_pictures_and_restore(scope, context)
  local _ = context
  local manifest = ManifestFixture.manifest()
  local run = startRun(
    { 45, 28, 0, 50, 4 },
    "battle-background-four-picture-move-power-transition",
    probeEvent({ move = { power = 50 } })
  )
  local sceneImage = checkerScene(scope, 256, 192, 32)
  local portrait = stripedPortrait(scope)
  local assets = {
    drawable = function(_, key)
      if key == SCENE_KEY then
        return sceneImage
      end
      if key == PORTRAIT_KEY then
        return portrait
      end
      return nil
    end,
    renderPictures = function(_, drawGraphics, pictures)
      return renderPictures(scope, drawGraphics, pictures)
    end,
    background = function()
      return nil
    end,
  }
  local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true }))
  local function renderPicturesFrame()
    local battler = attackerBattler()
    local patch = run.scene:pictureState({ combatant = 1, activation = 1 })
    if patch ~= nil then
      for key, value in pairs(patch) do
        battler[key] = value
      end
    end
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    BattleRenderer.drawPane({
      graphics = love.graphics,
      text = {
        measure = function(value)
          return { width = #tostring(value) * 8, height = 16 }
        end,
        drawText = function()
        end,
        drawTextWithPalette = function()
        end,
      },
      windows = { drawWindow = function()
      end, drawApplicationFrame = function()
      end },
      assets = assets,
      frameKey = "frame",
      sceneImageKey = SCENE_KEY,
      doublesHud = manifest.hud.doubles,
    }, {
      slotGeometry = manifest.battlefield.slots,
      hudPatchSpans = manifest.hud.patchSpans,
      hudSections = { player = manifest.hud.player, enemy = manifest.hud.enemy },
      mode = "idle",
      message = "",
      battlers = { battler },
      effectInstances = {},
    }, "detail", {})
    love.graphics.setCanvas()
    return imageDataDigest(scope:own(canvas:newImageData()))
  end
  local baseline = renderPicturesFrame()
  stepToPlayerTick(run, 1)
  Assert.isNil(
    run.scene:pictureState({ combatant = 1, activation = 1 }),
    "the spawn tick owns no picture: task tick N lands on player tick N + 1"
  )
  -- Task tick 1 rides player tick 2.
  stepToPlayerTick(run, 2)
  local phase = run.player:status(run.handle)
  Assert.isTrue(
    phase ~= "complete" and phase ~= "failed",
    "the profile run stays alive past its first task tick, got " .. tostring(phase)
  )
  local first = run.scene:pictureState({ combatant = 1, activation = 1 })
  Assert.deepEqual(
    { first.pictureXOffset2, first.pictureYOffset },
    { 15, 3 },
    "tick 1 rides the profile-2 arc toward its reach"
  )
  local firstFrame = renderPicturesFrame()
  -- Task tick 2 rides player tick 3.
  stepToPlayerTick(run, 3)
  local second = run.scene:pictureState({ combatant = 1, activation = 1 })
  Assert.deepEqual(
    { second.pictureXOffset2, second.pictureYOffset },
    { 9, 2 },
    "tick 2 settles back along the same arc"
  )
  local secondFrame = renderPicturesFrame()
  Assert.isTrue(firstFrame ~= baseline, "the opening shift displaces baseline picture pixels")
  Assert.isTrue(
    secondFrame ~= baseline and secondFrame ~= firstFrame,
    "the arc paints its own displaced frame on tick 2"
  )
  Assert.equal(#run.scene:effectViews(), 0, "the profile run publishes no drawable pictures")
  drainRun(run)
  Assert.equal(run.player:status(run.handle), "complete", "the profile run reaches its compiled completion")
  Assert.isNil(
    run.scene:pictureState({ combatant = 1, activation = 1 }),
    "completion restores the attacker picture exactly"
  )
  Assert.isNil(
    run.scene:pictureState({ combatant = 3, activation = 3 }),
    "completion restores the target picture exactly"
  )
  Assert.equal(renderPicturesFrame(), baseline, "completion restores baseline picture pixels")
  run.player:dispose()
end

-- Selector 38 interpolates its compiled blend coefficients in the
-- task-owned scalar overlay, which no renderer consumes yet: the
-- frames hold baseline pixels from the first tick through completion
-- while the register values ride their program and release exactly.
function T.blend_alpha_tick_samples_hold_pixels_while_registers_interpolate(scope, context)
  local _ = context
  local manifest = ManifestFixture.manifest()
  local plan = assert(
    BattleAnimationSources.resolveBattleAnimationCallback({ 38, 6, 3, 16, 100, 16, 8, 200 })
  )
  Assert.equal(
    plan.taskKind,
    "battle-sprite-blend-alpha-transition",
    "selector 38 lowers to the scalar blend program"
  )
  Assert.deepEqual(
    plan.parameters,
    {
      oamModeSpriteSlots = { "sprite-context-slot-0", "sprite-context-slot-1" },
      startCoefficientA = 16,
      targetCoefficientA = 100,
      startCoefficientB = 16,
      targetCoefficientB = 200,
      durationTicks = 8,
    },
    "selector 38 carries its compiled blend operands"
  )
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  local journal = { acquired = {}, released = {} }
  local resources = {}
  function resources.resolve(key)
    journal.acquired[#journal.acquired + 1] = key
    return { key = key, lease = key }
  end
  function resources.release(lease)
    journal.released[#journal.released + 1] = lease
  end
  local task = assert(BattleEffectTasks.create("battle-sprite-blend-alpha-transition", {
    callback = plan.callback,
    taskContext = "battle-display",
    parameters = plan.parameters,
  }, { launchId = "probe-bg-tick", topology = occurrenceTopology() }, {
    scene = scene,
    audio = {},
    resources = resources,
  }))
  local assets = {
    drawable = function(_, key)
      if key == SCENE_KEY then
        return checkerScene(scope, 256, 192, 8)
      end
      return nil
    end,
  }
  local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true }))
  local baseline = renderScrollFrame(scope, canvas, assets, manifest, scene)
  task:stepSourceTick({ tick = 1 })
  Assert.equal(task:status(), "running", "the blend run stays alive past its first tick")
  local first = assert(scene:taskScalarPatch(task), "the running blend owns its register state")
  Assert.deepEqual(
    { first.blendCoefficientA, first.blendCoefficientB },
    { 27, 39 },
    "tick 1 interpolates toward the compiled targets"
  )
  Assert.deepEqual(
    first.spriteSlots,
    { "sprite-context-slot-0", "sprite-context-slot-1" },
    "the blend names its compiled sprite slots"
  )
  Assert.equal(
    renderScrollFrame(scope, canvas, assets, manifest, scene),
    baseline,
    "no renderer consumes the scalar overlay on tick 1"
  )
  for _ = 2, 7 do
    task:stepSourceTick({ tick = 1 })
  end
  local seventh = assert(scene:taskScalarPatch(task), "the blend still owns its register state on tick 7")
  Assert.deepEqual(
    { seventh.blendCoefficientA, seventh.blendCoefficientB },
    { 90, 177 },
    "tick 7 keeps interpolating toward the compiled targets"
  )
  Assert.equal(
    renderScrollFrame(scope, canvas, assets, manifest, scene),
    baseline,
    "no renderer consumes the scalar overlay on tick 7"
  )
  Assert.equal(#scene:effectViews(), 0, "the blend publishes no drawable pictures")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(task:status(), "complete", "the blend completes at its compiled duration")
  Assert.isNil(scene:taskScalarPatch(task), "completion releases the owned register state")
  Assert.equal(
    renderScrollFrame(scope, canvas, assets, manifest, scene),
    baseline,
    "completion holds baseline pixels"
  )
  task:dispose()
  Assert.equal(#journal.released, #journal.acquired, "the blend stages no leases")
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics" }
return suite
