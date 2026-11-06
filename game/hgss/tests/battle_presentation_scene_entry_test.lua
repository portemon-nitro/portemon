-- Retail encounter opening through the real screen gate: admission
-- waits for the staged scene, the first source tick publishes frame 1
-- with the first member and its voice, draws and remeasure advance
-- nothing, and the task ends only after the second member retires.
-- Texture handles are strict pool leases through the production holder;
-- readiness is the holder state behind the runtime entry gate, never a
-- frame-count tolerance in the test. All scenes here are synthetic
-- staged layers, so this file needs no ROM and runs in CI.

local Assert = require("tests.support.Assert")
local FakeGraphics = require("tests.support.FakeGraphics")
local BattleScreenFixture = require("game.hgss.tests.support.BattleScreenFixture")
local BattlePresentationManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local EncounterParticlesFixture = require("tests.support.BattleEncounterParticlesFixture")
local StubLease = require("tests.support.StubLease")
local BattleAudio = require("libs.hgss.src.audio.BattleAudio")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local Rgb555 = require("libs.codec.src.Rgb555")

local T = {}
---@param draws table[] recorded draws under inspection
---@param handle string artwork identity under inspection
---@return table[] draws carrying that artwork identity
local function drawsOf(draws, handle)
  local found = {}
  for _, entry in ipairs(draws) do
    local image = entry.meshTexture or entry.image
    if type(image) == "table" and image.handle == handle then
      found[#found + 1] = entry
    end
  end
  return found
end

local ENCOUNTER_SCENE_KEY = "general/grass/day"
-- The production battle screen consumes one presentation source tick per
-- accepted update, exactly as the runtime delivers it; the encounter task
-- advances once per such tick.
local SourceTick = require("libs.hgss.src.field.SourceTick")
local ENCOUNTER_TICK = SourceTick.DT

---@return table recording voice sink behind the live screen
local function recordingEncounterAudio()
  local audio = { voices = {} }
  function audio:play(symbol)
    audio.voices[#audio.voices + 1] = symbol
    return true
  end
  function audio:playPanned(symbol, _)
    audio.voices[#audio.voices + 1] = symbol
    return true
  end
  function audio:playMusic(symbol)
    audio.voices[#audio.voices + 1] = symbol
    return true
  end
  function audio:playFanfare(symbol)
    audio.voices[#audio.voices + 1] = symbol
    return true
  end
  return audio
end

-- Stages one synthetic scene layer in the shape the production holder
-- adopts: BG3 payload plus the two encounter emitter sets with
-- lease-shaped texture handles. A withheld set models an empty image
-- closure for that set.
---@param firstLife integer emitter lifespan for the first set
---@param secondLife integer emitter lifespan for the second set
---@param withholdSet integer? set index staged without texture handles, nil for a complete layer
---@return table<string, unknown> staged scene layer
local stagedMenuSourceIndices

local function stagedEncounterLayer(firstLife, secondLife, withholdSet)
  local sets = EncounterParticlesFixture.sizedSets(ENCOUNTER_SCENE_KEY, 1, 1, firstLife, secondLife)
  local mapEntries = {}
  for _ = 1, 32 * 32 do
    mapEntries[#mapEntries + 1] = { tile = 0, flipH = false, flipV = false, palette = 0 }
  end
  local paletteColors = {}
  for _ = 1, 256 do
    paletteColors[#paletteColors + 1] = { r = 0, g = 0, b = 0 }
  end
  -- Preserved-range index 120 reads red so faded intro rasters prove
  -- their bytes: the unbaked base tile addresses 0x78 (untouched by the
  -- battle-setup fill) while the baked tile reads 0x00 (fill white).
  paletteColors[0x78 + 1] = { r = 255, g = 0, b = 0 }
  local function sourcePalette(size)
    local words = {}
    for index = 1, size do
      words[index] = 0
    end
    return words
  end
  local mainBgSource = sourcePalette(256)
  mainBgSource[121] = 0x001F
  local objectBank = sourcePalette(16)
  local layer = {
    sceneKey = ENCOUNTER_SCENE_KEY,
    mainObjBallSources = {},
    mainObjBallPaletteSources = {},
    mainObjTrainerPaletteSources = {},
    mainObjPostFill = {},
    paletteSource = {
      mainBg = mainBgSource,
      mainObjSources = {
        hud = { firstSlot = 0, words = objectBank },
        hudAuxiliary = { firstSlot = 16, words = sourcePalette(16) },
        terrain = { firstSlot = 32, words = sourcePalette(16) },
      },
      subBgOpaque = sourcePalette(256),
      subObjOpaque = sourcePalette(256),
      initialDisplayed = {
        subBg = sourcePalette(256),
        subObj = sourcePalette(256),
      },
    },
    nativePaletteLayout = { trainers = {}, balls = {} },
    characters = string.rep("\0", 64),
    baseCharacters = string.char(0x78) .. string.rep("\0", 63),
    colorMode = "8bpp",
    map = {
      width = 256,
      height = 256,
      entries = mapEntries,
    },
    palette = { colors = paletteColors },
    introLayer = { drawable = StubLease.new("scene-intro:" .. ENCOUNTER_SCENE_KEY), width = 256, height = 192 },
    terrainSprites = {
      player = {
        drawable = StubLease.new("scene-terrain:" .. ENCOUNTER_SCENE_KEY .. ":player"),
        width = 64,
        height = 64,
        origin = { x = 0, y = 0 },
        sourceIndices = {
          plane = "mainObj",
          width = 64,
          height = 64,
          pixels = string.rep(string.char(32, 0, 0, 255), 64 * 64),
        },
      },
      foe = {
        drawable = StubLease.new("scene-terrain:" .. ENCOUNTER_SCENE_KEY .. ":foe"),
        width = 64,
        height = 64,
        origin = { x = 0, y = 0 },
        sourceIndices = {
          plane = "mainObj",
          width = 64,
          height = 64,
          pixels = string.rep(string.char(32, 0, 0, 255), 64 * 64),
        },
      },
    },
    encounterParticles = {},
  }
  for setIndex, set in ipairs(sets) do
    local textures = {}
    for _, texture in ipairs(set.textures) do
      local drawable = nil
      if withholdSet ~= setIndex then
        drawable = StubLease.new("encounter-particle:" .. ENCOUNTER_SCENE_KEY .. ":" .. setIndex .. ":" .. texture.id)
        drawable.width = texture.width
        drawable.height = texture.height
      end
      textures[#textures + 1] = { id = texture.id, width = texture.width, height = texture.height, drawable = drawable }
    end
    layer.encounterParticles[setIndex] =
      { startTick = set.startTick, seed = set.seed, emitters = set.emitters, textures = textures }
  end
  return layer
end

---@param opts table? withheldScene true while the scene art stays unstaged
---@return table live rig with the real screen, port, and recording audio
local function openEncounterRig(opts)
  opts = opts or {}
  local audio = recordingEncounterAudio()
  local staged = nil
  local manifest = opts.manifest or BattlePresentationManifestFixture.manifest()
  local withheld = { ["scene:" .. ENCOUNTER_SCENE_KEY] = opts.withheldScene == true }
  local images = {}
  local released = {}
  local fadedRasters = {}
  local paletteRasters = {}
  local assets = { headless = opts.headless == true }
  function assets.prepare(_)
    return true
  end
  function assets.sceneLayer()
    return staged
  end
  function assets.fadedIntro(raster)
    fadedRasters[#fadedRasters + 1] = raster
    if opts.fadedIntroFailure ~= nil then
      return nil, opts.fadedIntroFailure
    end
    return { handle = "faded-intro-image" }
  end
  function assets.paletteImage(key, raster)
    local image = { handle = key, raster = raster, width = raster.width, height = raster.height }
    paletteRasters[key] = paletteRasters[key] or {}
    paletteRasters[key][#paletteRasters[key] + 1] = raster
    return image
  end
  function assets.drawable(key)
    if withheld[key] then
      return nil
    end
    if images[key] == nil then
      local stored = StubLease.new(key)
      images[key] = stored
      if key:sub(1, 4) == "mon:" then
        return { lease = stored, quad = { handle = "quad:" .. key } }
      end
      return stored
    end
    local stored = images[key]
    if key:sub(1, 4) == "mon:" then
      return { lease = stored, quad = { handle = "quad:" .. key } }
    end
    return stored
  end
  function assets.release(key)
    released[key] = (released[key] or 0) + 1
  end
  local measurement = {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" },
      "encounter-readiness:dual"
    ),
    pixelRatio = 1,
    signature = "encounter-readiness:dual",
  }
  local text = {}
  function text.measure(content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(_) end
  function text.drawTextWithPalette(_, _, _) end
  local windows = {}
  function windows.drawWindow(_, _, _) end
  function windows.drawApplicationFrame(_, _) end
  local launchId = "encounter-readiness-probe"
  local screen = BattleScreenFixture.new({
    launchId = launchId,
    manifest = manifest,
    model = {},
    submit = function(_)
      return true
    end,
    measureDisplay = function()
      return measurement
    end,
    assets = assets,
    text = text,
    windows = windows,
    audio = audio,
    overrides = { sceneKey = ENCOUNTER_SCENE_KEY },
  })
  local port = screen:presentationPort()
  local rig = {
    screen = screen,
    port = port,
    audio = audio,
    launchId = launchId,
    manifest = manifest,
    fadedRasters = fadedRasters,
    paletteRasters = paletteRasters,
    released = released,
  }
  local enter = port.enter
  function port.enter(plan)
    plan = plan or {}
    plan.encounterPaletteRestoreType = plan.encounterPaletteRestoreType or "wild"
    return enter(plan)
  end
  function rig.pump(count, allowFailure)
    for _ = 1, count do
      screen:updateFixed(ENCOUNTER_TICK)
      if allowFailure ~= true then
        local status = screen:status()
        Assert.isTrue(status.mode ~= "failed", "the readiness screen never fails: " .. tostring(status.error))
      end
    end
    return screen:status()
  end
  function rig.stage(layer)
    local maps = layer.menuSourceIndices or stagedMenuSourceIndices(manifest)
    layer.menuSourceIndices = maps
    if layer.sourceMapFor == nil then
      layer.sourceMapFor = function(descriptor)
        if type(descriptor) == "table" and type(descriptor.pixels) == "string" then
          return descriptor
        end
        local path = type(descriptor) == "table" and descriptor.path or nil
        assert(type(path) == "string" and path ~= "", "source-index descriptor names its map")
        return assert(maps[path], "staged source-index map remains in the staged scene: " .. path)
      end
    end
    staged = layer
    withheld["scene:" .. ENCOUNTER_SCENE_KEY] = false
    rig.port.enter({
      launchId = rig.launchId,
      kind = "wild",
      encounterPaletteRestoreType = "wild",
    })
  end
  function rig.resize(signature)
    measurement.signature = signature
  end
  function rig.compact()
    measurement.width = 256
    measurement.height = 192
    measurement.topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      touch = false,
      role = "world",
    })
    measurement.signature = "encounter-readiness:compact"
  end
  return rig
end

---@param rig table live rig under inspection
---@param symbol string staged sequence symbol under inspection
---@return integer voices of the symbol so far
local function voiceCount(rig, symbol)
  local count = 0
  for _, voiced in ipairs(rig.audio.voices) do
    if voiced == symbol then
      count = count + 1
    end
  end
  return count
end

---@param combatant integer
---@param side integer
---@param active boolean
---@param species string
---@param name string
---@param portrait string
---@return table detached battler record
local function encounterBattler(combatant, side, active, species, name, portrait)
  return {
    combatant = combatant,
    participant = combatant,
    side = side,
    controller = side == 1 and "player" or "wild",
    active = active,
    hp = 20,
    maxHp = 20,
    species = species,
    form = 0,
    ballKey = "POKE_BALL",
    name = name,
    level = 9,
    selector = side == 1 and "back" or "front",
    portraitSelector = portrait,
    moves = {},
    experience = 100,
  }
end

---@return table detached opening view picturing the wild lead and foe
local function encounterOpening()
  return {
    playerTrainer = { classKey = "PKMN_TRAINER_ETHAN" },
    own = { encounterBattler(1, 1, true, "CHIKORITA", "LEAD", "CHIKORITA/f0/male/plain/back") },
    foes = { encounterBattler(3, 2, true, "RATTATA", "FOE", "RATTATA/f0/male/plain") },
  }
end

---@param rig table live rig under test driving
local function presentOpening(rig)
  rig.port.present({
    launchId = rig.launchId,
    packetId = 1,
    before = encounterOpening(),
    after = encounterOpening(),
    events = {},
  })
end

function T.native_palette_layout_tracks_the_staged_scene_layer()
  local rig = openEncounterRig()
  rig.stage(stagedEncounterLayer(60, 43))
  rig.pump(5)
  local entries = rig.screen._manifest.battleBalls.entries
  Assert.isTrue(entries["ball:POKE_BALL"] ~= nil, "the encounter fixture stages its selected ball")
  local savedBall = entries["ball:POKE_BALL"]
  entries["ball:POKE_BALL"] = nil
  presentOpening(rig)
  rig.pump(1)
  Assert.isFalse(rig.screen._nativePaletteLayoutReady, "native palette layout waits while the ball leaf is pending")

  entries["ball:POKE_BALL"] = savedBall
  rig.screen._encounterPaletteRestoreType = nil
  rig.pump(1)
  Assert.isTrue(rig.screen._nativePaletteLayoutReady, "the restored scene publishes its native layout")
  local replacement = stagedEncounterLayer(60, 43)
  rig.screen._assets._sceneLayer = replacement
  Assert.isTrue(rig.screen:_stageNativePaletteLayout(), "a replaced staged layer rebuilds its layout")
  Assert.isTrue(type(replacement.nativePaletteLayout) == "table", "the current layer owns its native layout")
  rig.screen:dispose()
end

local function nativePaletteSource()
  local Rgb555 = require("libs.codec.src.Rgb555")
  local function planeWords(length, first, second)
    local words = {}
    for index = 0, length - 1 do
      words[index + 1] = index % 2 == 0 and first or second
    end
    return words
  end
  local hud = planeWords(16, Rgb555.encode(31, 0, 0), Rgb555.encode(0, 0, 31))
  local hudAuxiliary = planeWords(16, Rgb555.encode(31, 0, 0), Rgb555.encode(0, 0, 31))
  local terrain = planeWords(16, Rgb555.encode(31, 0, 0), Rgb555.encode(0, 0, 31))
  local subBg = planeWords(256, Rgb555.encode(0, 31, 0), Rgb555.encode(0, 0, 31))
  local subObj = planeWords(256, Rgb555.encode(31, 31, 0), Rgb555.encode(0, 31, 31))
  return {
    mainBg = planeWords(256, Rgb555.encode(31, 0, 0), Rgb555.encode(0, 0, 31)),
    mainObjSources = {
      hud = { firstSlot = 0, words = hud },
      hudAuxiliary = { firstSlot = 16, words = hudAuxiliary },
      terrain = { firstSlot = 32, words = terrain },
    },
    subBgOpaque = subBg,
    subObjOpaque = subObj,
    initialDisplayed = { subBg = subBg, subObj = subObj },
    fill = Rgb555.encode(31, 31, 31),
  }
end

local function sourceIndexPixels(width, height, firstSlot, secondSlot, opaquePixels)
  if secondSlot == nil and opaquePixels == nil then
    return string.rep(string.char(firstSlot, 0, 0, 255), width * height)
  end
  local pixels = {}
  for index = 0, width * height - 1 do
    local slot = secondSlot ~= nil and index % 2 == 1 and secondSlot or firstSlot
    local alpha = 255
    if opaquePixels ~= nil and index >= opaquePixels then
      alpha = 0
    end
    pixels[#pixels + 1] = string.char(slot, 0, 0, alpha)
  end
  return table.concat(pixels)
end

stagedMenuSourceIndices = function(manifest)
  local maps = {}
  local function visit(value, parentPalette)
    if type(value) ~= "table" then
      return
    end
    local palette = type(value.paletteSource) == "table" and value.paletteSource or parentPalette
    local descriptor = value.sourceIndices
    if type(descriptor) == "table" then
      local baseSlot = type(palette) == "table" and palette.firstSlot or nil
      local slot = type(baseSlot) == "number" and baseSlot or 0
      local function stage(path, firstSlot)
        local sourceSlot = type(firstSlot) == "number" and firstSlot or slot
        maps[path] = {
          plane = descriptor.plane,
          width = descriptor.width,
          height = descriptor.height,
          pixels = sourceIndexPixels(descriptor.width, descriptor.height, sourceSlot),
          paletteSource = type(palette) == "table" and { firstSlot = sourceSlot, words = palette.words } or nil,
        }
      end
      if type(descriptor.path) == "string" then
        stage(descriptor.path)
      end
      if type(descriptor.variants) == "table" then
        for _, variant in pairs(descriptor.variants) do
          stage(variant.path, variant.firstSlot)
        end
      end
    end
    for key, child in pairs(value) do
      if key ~= "sourceIndices" then
        visit(child, palette)
      end
    end
  end
  visit(manifest.menus)
  visit(manifest.hud)
  visit(manifest.trainerPictures)
  visit(manifest.battleBalls)
  return maps
end

-- The private render snapshot carries each live particle owner through the
-- production screen draw in detail and compact layouts. Repeated draws keep
-- all three simulations and the encounter source frame unchanged.
function T.screen_draws_live_particle_owners_in_detail_and_compact_layouts()
  local rig = openEncounterRig()
  local ok, err = pcall(function()
    rig.stage(stagedEncounterLayer(60, 43))
    rig.pump(5)
    Assert.isTrue(
      rig.port.enter({ launchId = rig.launchId, kind = "wild", encounterPaletteRestoreType = "wild" }),
      "entry admits the staged scene"
    )
    presentOpening(rig)
    rig.pump(1)

    local SplParticleSimulation = require("libs.hgss.src.presentation.SplParticleSimulation")
    local ParticleFixture = require("tests.support.BattleParticleLeaseFixture")
    local moveSimulation = SplParticleSimulation.new(0, 0)
    SplParticleSimulation.addEmitter(moveSimulation, 0, nil, ParticleFixture.payload(1).emitters[1])
    SplParticleSimulation.advance(moveSimulation)
    local moveTexture = StubLease.new("move-live-particle")
    moveTexture.width = 8
    moveTexture.height = 8
    local moveSystemId = rig.screen._scene:allocParticleSystem({
      simulation = moveSimulation,
      textures = { [0] = moveTexture },
    })

    local ballParticles = ParticleFixture.payload(1)
    local ballTexture = StubLease.new("ball-live-particle")
    ballTexture.width = 8
    ballTexture.height = 8
    rig.screen._ballParticles:step({ { effect = "seal", ballKey = "POKE_BALL", battlerType = 0 } }, {}, {
      particles = function()
        return {
          seal = {
            seed = ballParticles.seed,
            emitters = ballParticles.emitters,
            textures = ballParticles.textures,
          },
        }
      end,
      texture = function()
        return ballTexture
      end,
    })

    -- The first encounter particle starts fully transparent; advance once
    -- so the production draw boundary receives visible particles.
    rig.pump(1)
    local before = rig.screen:view()
    Assert.equal(#before.encounterParticleSystems, 1, "the encounter owner has a live emitter")
    Assert.equal(#before.moveParticleSystems, 1, "the scene owner has a live move emitter")
    Assert.equal(#before.ballParticleSystems, 1, "the ball owner has a live seal emitter")
    local detail = FakeGraphics.new({})
    rig.screen:draw({ graphics = detail })
    for _, handle in ipairs({
      "encounter-particle:" .. ENCOUNTER_SCENE_KEY .. ":1:0",
      "move-live-particle",
      "ball-live-particle",
    }) do
      Assert.isTrue(#drawsOf(detail.draws, handle) >= 1, "detail draws " .. handle)
    end

    rig.compact()
    local compact = FakeGraphics.new({})
    rig.screen:draw({ graphics = compact })
    rig.screen:draw({ graphics = FakeGraphics.new({}) })
    for _, handle in ipairs({
      "encounter-particle:" .. ENCOUNTER_SCENE_KEY .. ":1:0",
      "move-live-particle",
      "ball-live-particle",
    }) do
      Assert.isTrue(#drawsOf(compact.draws, handle) >= 1, "compact draws " .. handle)
    end
    local after = rig.screen:view()
    Assert.equal(
      after.openingPresentation.encounterFrame,
      before.openingPresentation.encounterFrame,
      "draws do not advance the encounter timeline"
    )
    Assert.equal(
      #after.encounterParticleSystems,
      #before.encounterParticleSystems,
      "draws do not step encounter emitters"
    )
    Assert.equal(#after.moveParticleSystems, #before.moveParticleSystems, "draws do not step move emitters")
    Assert.equal(#after.ballParticleSystems, #before.ballParticleSystems, "draws do not step ball emitters")
    rig.screen._scene:releaseParticleSystem(moveSystemId)
  end)
  rig.screen:dispose()
  if not ok then
    error(err, 0)
  end
end

-- Native source-indexed terrain is uploaded from the displayed OBJ words
-- and used by the production screen draw, while the separately leased
-- encounter particle keeps its original white draw color above the 2D art.
function T.screen_draws_source_sampled_terrain_under_untinted_encounter_particles()
  local Rgb555 = require("libs.codec.src.Rgb555")
  local rig = openEncounterRig()
  local ok, err = pcall(function()
    local width, height = 64, 64
    local layer = stagedEncounterLayer(60, 43)
    local sourceParticleImage = layer.encounterParticles[1].textures[1].drawable.image
    local sourceTerrainImage = layer.terrainSprites.player.drawable.image
    layer.paletteSource = nativePaletteSource()
    layer.menuSourceIndices = stagedMenuSourceIndices(rig.manifest)
    for _, side in ipairs({ "player", "foe" }) do
      layer.terrainSprites[side].sourceIndices = {
        plane = "mainObj",
        width = width,
        height = height,
        pixels = sourceIndexPixels(width, height, 0, 1, 2),
      }
    end
    rig.stage(layer)
    rig.pump(5)
    Assert.isTrue(rig.port.enter({ launchId = rig.launchId, kind = "wild" }), "entry admits indexed scene art")
    presentOpening(rig)
    rig.pump(10)

    local view = rig.screen:view()
    Assert.equal(view.openingPresentation.encounterFrame, 10, "the composed image follows native source frame 10")
    local palette = view.openingPresentation.encounterPalette
    Assert.notNil(palette, "the frame carries displayed native planes")
    local key = "scene-terrain:" .. ENCOUNTER_SCENE_KEY .. ":player"
    local image = rig.screen._assets:drawable(key)
    Assert.notNil(image, "native terrain publishes a keyed palette drawable")
    local raster = image.raster
    Assert.notNil(raster, "the keyed drawable retains its uploaded raster for verification")
    Assert.equal(raster.width, width, "the sampled terrain keeps source width")
    Assert.equal(raster.height, height, "the sampled terrain keeps source height")
    for pixelIndex, slot in ipairs({ 1, 2 }) do
      local rgb = Rgb555.decode(palette.mainObj[slot])
      local offset = (pixelIndex - 1) * 4
      Assert.equal(raster.pixels:byte(offset + 1), rgb.r, "source slot " .. slot .. " samples its displayed red")
      Assert.equal(raster.pixels:byte(offset + 2), rgb.g, "source slot " .. slot .. " samples its displayed green")
      Assert.equal(raster.pixels:byte(offset + 3), rgb.b, "source slot " .. slot .. " samples its displayed blue")
      Assert.equal(raster.pixels:byte(offset + 4), 255, "opaque source coverage remains opaque")
    end
    Assert.equal(raster.pixels:byte(12), 0, "transparent source coverage stays transparent")

    local uploadCount = #rig.paletteRasters[image.handle]
    local detail = FakeGraphics.new({})
    rig.screen:draw({ graphics = detail })
    rig.screen:draw({ graphics = FakeGraphics.new({}) })
    Assert.equal(
      #rig.paletteRasters[image.handle],
      uploadCount,
      "repeated draws do not rematerialize an unchanged palette image"
    )
    local terrainDraw = drawsOf(detail.draws, image.handle)[1]
    local particleDraw = drawsOf(detail.draws, "encounter-particle:" .. ENCOUNTER_SCENE_KEY .. ":1:0")[1]
    Assert.isTrue(terrainDraw ~= nil, "the real detail screen draws the sampled terrain image")
    Assert.isTrue(particleDraw ~= nil, "the real detail screen draws the separate encounter particle")
    Assert.equal(particleDraw.image, sourceParticleImage, "the encounter particle keeps its original texture lease")
    local terrainOrder, particleOrder
    for index, draw in ipairs(detail.draws) do
      if draw == terrainDraw then
        terrainOrder = index
      elseif draw == particleDraw then
        particleOrder = index
      end
    end
    Assert.isTrue(
      type(terrainOrder) == "number" and type(particleOrder) == "number" and terrainOrder < particleOrder,
      "the encounter particle remains above the sampled 2D terrain"
    )
    local SplParticleDraw = require("libs.hgss.src.presentation.SplParticleDraw")
    local sourceParticle = nil
    for _, system in ipairs(view.encounterParticleSystems) do
      if system.textures[0] ~= nil and system.textures[0].image.handle == sourceParticleImage.handle then
        sourceParticle = system
        break
      end
    end
    Assert.isTrue(sourceParticle ~= nil, "the encounter particle retains its native live simulation")
    local nativeParticleGraphics = FakeGraphics.new({})
    SplParticleDraw.draw(nativeParticleGraphics, sourceParticle.simulation, {
      centerX = 128,
      centerY = 96,
      resolveTexture = function(_, particle, child)
        local textureId = child ~= nil and child.texNo or particle.texNo
        return assert(sourceParticle.textures[textureId])
      end,
    })
    local nativeParticleDraw = drawsOf(nativeParticleGraphics.draws, sourceParticleImage.handle)[1]
    Assert.isTrue(nativeParticleDraw ~= nil, "the source simulation draws its own native particle tint")
    Assert.deepEqual(
      particleDraw.color,
      nativeParticleDraw.color,
      "native 2D sampling leaves the source particle tint unchanged"
    )

    rig.compact()
    local compact = FakeGraphics.new({})
    rig.screen:draw({ graphics = compact })
    local compactTerrain = drawsOf(compact.draws, image.handle)[1]
    Assert.isTrue(compactTerrain ~= nil, "compact layout draws the same source-sampled terrain")
    Assert.equal(compactTerrain.x, terrainDraw.x, "compact layout preserves the native terrain origin")
    Assert.equal(compactTerrain.y, terrainDraw.y, "compact layout preserves the native terrain origin")

    while rig.screen:view().openingPresentation.encounterFrame < 36 do
      rig.pump(1)
    end
    local stableUploadCount = #rig.paletteRasters[image.handle]
    rig.pump(4)
    Assert.equal(
      #rig.paletteRasters[image.handle],
      stableUploadCount,
      "unchanged native words across source ticks do not rematerialize the terrain image"
    )
    while rig.screen:view().openingPresentation.encounterFrame ~= nil do
      rig.pump(1)
      local frame = rig.screen:view().openingPresentation.encounterFrame
      Assert.isTrue(frame == nil or frame < 120, "the encounter task retires within its bounded source lifecycle")
    end
    Assert.equal(rig.released[image.handle], 1, "encounter retirement releases the terrain replacement exactly once")
    local settled = FakeGraphics.new({})
    rig.screen:draw({ graphics = settled })
    Assert.isTrue(
      #drawsOf(settled.draws, sourceTerrainImage.handle) >= 1,
      "post-encounter drawing restores the original terrain lease"
    )
    Assert.equal(
      #drawsOf(settled.draws, image.handle),
      0,
      "post-encounter drawing no longer samples the released image"
    )
    rig.screen:dispose()
    Assert.equal(rig.released[image.handle], 1, "screen disposal does not release the retired replacement twice")
  end)
  rig.screen:dispose()
  if not ok then
    error(err, 0)
  end
end

-- A synthetic second lower drawable carries the SUB_OBJ map beside the
-- existing menu screen's SUB_BG map. Both pass through the production
-- BattleMenuPresenter and remain separate through the frame-28 reveal.
function T.interaction_menu_samples_source_bg_and_obj_planes_without_the_lower_wash()
  local Rgb555 = require("libs.codec.src.Rgb555")
  local manifest = BattlePresentationManifestFixture.manifest()
  local backgroundPath = "synthetic/menu-command-sub-bg.rgba8"
  local objectPath = "synthetic/menu-command-sub-obj.rgba8"
  local objectImagePath = "assets/generated/battle/menu-command-sub-obj.png"
  local backgroundScreen = manifest.menus.command.screens[1]
  backgroundScreen.sourceIndices = {
    path = backgroundPath,
    format = "source-index-rgba8",
    plane = "subBg",
    width = 256,
    height = 256,
  }
  manifest.menus.images[objectImagePath] = { width = 256, height = 256 }
  manifest.menus.command.screens[2] = {
    image = objectImagePath,
    width = 256,
    height = 256,
    tilemapKey = "menu/tilemap/synthetic-object",
    plane = 2,
    template = 1,
    priority = 3,
    sourceIndices = {
      path = objectPath,
      format = "source-index-rgba8",
      plane = "subObj",
      width = 256,
      height = 256,
    },
  }
  local rig = openEncounterRig({ manifest = manifest })
  local ok, err = pcall(function()
    local layer = stagedEncounterLayer(60, 43)
    layer.paletteSource = nativePaletteSource()
    layer.menuSourceIndices = stagedMenuSourceIndices(manifest)
    rig.stage(layer)
    rig.pump(5)
    Assert.isTrue(rig.port.enter({ launchId = rig.launchId, kind = "wild" }), "entry admits indexed lower art")
    presentOpening(rig)
    rig.pump(28)

    local view = rig.screen:view()
    Assert.equal(view.openingPresentation.encounterFrame, 28, "the lower composition observes native reveal frame 28")
    local palette = view.openingPresentation.encounterPalette
    Assert.notNil(palette, "the lower reveal carries separate native palette planes")
    local bgImage = rig.screen._assets:drawable("menu:command:screen:1")
    local objImage = rig.screen._assets:drawable("menu:command:screen:2")
    local function sampledScreen(sourceKey)
      for uploadKey in pairs(rig.paletteRasters) do
        if uploadKey:find(":" .. sourceKey .. ":", 1, true) ~= nil then
          return true
        end
      end
      return false
    end
    Assert.notNil(bgImage, "the menu BG keeps its semantic drawable lookup")
    Assert.notNil(objImage, "the synthetic menu OBJ keeps its semantic drawable lookup")
    Assert.isTrue(sampledScreen("menu:command:screen:1@general"), "the active command screen is sampled")
    Assert.isFalse(sampledScreen("menu:moves:screen:1@general"), "inactive move screens are not sampled")
    Assert.isFalse(sampledScreen("menu:target:screen:1@general"), "inactive target screens are not sampled")
    Assert.isFalse(sampledScreen("menu:two-option:screen:1@general"), "inactive child screens are not sampled")
    local bgRgb = Rgb555.decode(palette.subBg[1])
    local objRgb = Rgb555.decode(palette.subObj[2])
    Assert.deepEqual({
      bgImage.raster.pixels:byte(1),
      bgImage.raster.pixels:byte(2),
      bgImage.raster.pixels:byte(3),
      bgImage.raster.pixels:byte(4),
    }, { bgRgb.r, bgRgb.g, bgRgb.b, 255 }, "menu source pixels sample SUB_BG words")
    Assert.deepEqual({
      objImage.raster.pixels:byte(1),
      objImage.raster.pixels:byte(2),
      objImage.raster.pixels:byte(3),
      objImage.raster.pixels:byte(4),
    }, { objRgb.r, objRgb.g, objRgb.b, 255 }, "menu source pixels sample SUB_OBJ words")
    -- While the encounter reveal holds the controls disabled, only the
    -- backdrop plane draws: the button tilemaps stay hidden, matching the
    -- retail SUB_2-only disabled composition.
    local disabledGraphics = FakeGraphics.new({})
    rig.screen:draw({ graphics = disabledGraphics })
    Assert.isTrue(
      #drawsOf(disabledGraphics.draws, objImage.handle) >= 1,
      "the disabled lower menu keeps its backdrop visible"
    )
    Assert.equal(
      #drawsOf(disabledGraphics.draws, bgImage.handle),
      0,
      "the disabled lower menu hides its button tilemaps"
    )
    -- With the command menu open, both planes pass through the
    -- production BattleMenuPresenter.
    rig.screen._mode = "command"
    local graphics = FakeGraphics.new({})
    rig.screen:draw({ graphics = graphics })
    Assert.isTrue(#drawsOf(graphics.draws, bgImage.handle) >= 1, "the real lower menu draws the sampled SUB_BG image")
    Assert.isTrue(#drawsOf(graphics.draws, objImage.handle) >= 1, "the real lower menu draws the sampled SUB_OBJ image")
    local fullScreenWash = false
    for _, rectangle in ipairs(graphics.rectangles) do
      if
        rectangle.mode == "fill"
        and rectangle.x == 0
        and rectangle.y == 0
        and rectangle.w == 256
        and rectangle.h == 192
      then
        fullScreenWash = true
      end
    end
    Assert.isFalse(fullScreenWash, "the lower encounter plane does not wash over SUB_OBJ art")
    Assert.isTrue(#graphics.canvases >= 2, "the original BG1 blend still composes the lower menu layers")
  end)
  rig.screen:dispose()
  if not ok then
    error(err, 0)
  end
end

-- The staged scene gates admission, and the first admitted source tick
-- runs the opening once: frame 1 with the first member and its voice.
-- Draws and remeasure between fixed steps advance nothing, and the
-- task ends only after the second member retires.
function T.ready_presentation_runs_the_opening_once_from_the_first_source_tick()
  local rig = openEncounterRig({ withheldScene = true })
  Assert.isFalse(
    rig.port.enter({ launchId = rig.launchId, kind = "wild", encounterPaletteRestoreType = "wild" }),
    "entry holds while the scene art is not staged"
  )
  rig.pump(3)
  Assert.isFalse(
    rig.port.enter({ launchId = rig.launchId, kind = "wild", encounterPaletteRestoreType = "wild" }),
    "entry still holds without the staged scene"
  )
  rig.stage(stagedEncounterLayer(60, 43, nil))
  rig.pump(5)
  Assert.isTrue(
    rig.port.enter({ launchId = rig.launchId, kind = "wild", encounterPaletteRestoreType = "wild" }),
    "entry admits the staged scene"
  )
  presentOpening(rig)
  rig.pump(1)
  local first = rig.screen:view()
  Assert.equal(first.openingPresentation.encounterFrame, 1, "the first source tick publishes frame 1")
  Assert.equal(#first.encounterParticleSystems, 1, "the first member starts on frame 1")
  Assert.equal(
    voiceCount(rig, BattleAudio.SINK_SOUNDS.encounterStart),
    1,
    "the first source tick voices the opening sound once"
  )
  local voicesBefore = #rig.audio.voices
  rig.screen:draw({ graphics = FakeGraphics.new({}) })
  rig.screen:draw({ graphics = FakeGraphics.new({}) })
  local held = rig.screen:view()
  Assert.equal(held.openingPresentation.encounterFrame, 1, "draws never advance the task frame")
  Assert.equal(#held.encounterParticleSystems, 1, "draws spawn no particles")
  Assert.equal(#rig.audio.voices, voicesBefore, "draws voice no battle sounds")
  rig.resize("encounter-readiness:resized")
  for step = 1, 3 do
    rig.pump(1)
    local stepped = rig.screen:view()
    Assert.equal(
      stepped.openingPresentation.encounterFrame,
      1 + step,
      "source tick "
        .. step
        .. " after draw and remeasure advances the task, got "
        .. tostring(stepped.openingPresentation.encounterFrame)
    )
  end
  local second = rig.screen:view()
  rig.pump(16)
  local twentieth = rig.screen:view()
  Assert.equal(twentieth.openingPresentation.encounterFrame, 20, "the task counts one frame per source tick")
  Assert.equal(#twentieth.encounterParticleSystems, 2, "the second member starts on frame 20")
  rig.pump(30)
  local fiftieth = rig.screen:view()
  Assert.equal(fiftieth.openingPresentation.encounterFrame, 50, "the task still runs at the late bank fade")
  Assert.equal(#fiftieth.encounterParticleSystems, 2, "both members run through the frame-50 fade")
  rig.pump(10)
  local sixtieth = rig.screen:view()
  Assert.equal(sixtieth.openingPresentation.encounterFrame, 60, "the task waits while the second system stays active")
  Assert.equal(#sixtieth.encounterParticleSystems, 2, "both members run through the late fade")
  rig.pump(1)
  local sixtyFirst = rig.screen:view()
  Assert.equal(sixtyFirst.openingPresentation.encounterFrame, 61, "the task runs on while the first system is gone")
  Assert.equal(#sixtyFirst.encounterParticleSystems, 1, "the retired first system leaves the second running")
  rig.pump(1)
  local sixtySecond = rig.screen:view()
  Assert.equal(sixtySecond.openingPresentation.encounterFrame, 62, "the task reaches the second retirement tick")
  local silentAfter = nil
  for tick = 63, 80 do
    rig.pump(1)
    if rig.screen:view().openingPresentation.encounterFrame == nil then
      silentAfter = tick
      break
    end
  end
  Assert.isTrue(
    silentAfter ~= nil and silentAfter >= 63 and silentAfter <= 70,
    "the task ends once after the second system retires, got " .. tostring(silentAfter)
  )
  rig.pump(10)
  local settled = rig.screen:view()
  Assert.isNil(settled.openingPresentation.encounterFrame, "the ended task publishes no further frame")
  Assert.equal(#settled.encounterParticleSystems, 0, "retired systems leave the draw list")
  Assert.equal(voiceCount(rig, BattleAudio.SINK_SOUNDS.encounterStart), 1, "the opening sound voices exactly once")
  Assert.equal(voiceCount(rig, BattleAudio.SINK_SOUNDS.encounterSettle), 1, "the settle sound voices exactly once")
end

function T.encounter_palette_staging_uses_independent_native_plane_sources()
  local rig = openEncounterRig()
  local layer = stagedEncounterLayer(40, 36)
  local function words(count, sentinelIndex, sentinel)
    local result = {}
    for index = 1, count do
      result[index] = index == sentinelIndex and sentinel or 0
    end
    return result
  end
  layer.paletteSource = {
    mainBg = words(256, 121, 0x001F),
    mainObjSources = {
      hud = { firstSlot = 0, words = words(16, 16, 0) },
      hudAuxiliary = { firstSlot = 16, words = words(16, 16, 0) },
      terrain = { firstSlot = 32, words = words(16, 16, 0x03E0) },
      lateStatic = { firstSlot = 208, words = words(16, 16, 0x03E0) },
    },
    subBgOpaque = words(256, 1, 0x7C00),
    subObjOpaque = words(256, 1, 0x4210),
    initialDisplayed = {
      subBg = words(256, 1, 0x7C00),
      subObj = words(256, 1, 0x4210),
    },
  }
  layer.nativePaletteLayout = { trainers = {}, balls = {} }
  layer.mainObjBallPaletteSources = {}
  layer.mainObjTrainerPaletteSources = {}
  rig.stage(layer)
  rig.pump(1)
  Assert.isTrue(
    rig.port.enter({ launchId = rig.launchId, kind = "wild", encounterPaletteRestoreType = "wild" }),
    "the sourced scene admits"
  )
  presentOpening(rig)
  rig.pump(1)

  local palette =
    assert(rig.screen:view().openingPresentation.encounterPalette, "the first tick publishes native palette state")
  Assert.equal(#palette.mainBg, 256, "main BG keeps its native palette size")
  Assert.equal(palette.mainObj[224], 0x03E0, "the late static MAIN_OBJ word remains source-defined")
  Assert.equal(#palette.subBg, 256, "sub BG keeps its native palette size")
  Assert.equal(#palette.subObj, 256, "sub OBJ keeps its native palette size")
  Assert.deepEqual(
    { palette.mainBg[121], palette.mainObj[224], palette.subBg[1], palette.subObj[1] },
    { 0x001F, 0x03E0, 0x7C00, 0x4210 },
    "each native plane retains its own source word"
  )
end

-- A data-only host keeps the original art when native palette image output is absent.
function T.headless_encounter_keeps_static_art_and_publishes_readiness()
  local rig = openEncounterRig({ headless = true })
  rig.stage(stagedEncounterLayer(40, 36))
  rig.pump(5)
  Assert.isTrue(
    rig.port.enter({ launchId = rig.launchId, kind = "wild", encounterPaletteRestoreType = "wild" }),
    "headless entry admits the staged scene"
  )
  presentOpening(rig)
  rig.pump(8)
  Assert.isTrue(rig.screen:firstNativeBattleFrameReady(), "headless composition can release its static first frame")
  Assert.equal(#rig.fadedRasters, 0, "headless composition never attempts BG3 image uploads")
  Assert.equal(next(rig.paletteRasters), nil, "headless composition never attempts native plane image uploads")
  local draw = FakeGraphics.new({})
  rig.screen:draw({ graphics = draw })
  Assert.isTrue(
    #drawsOf(draw.draws, "scene-intro:" .. ENCOUNTER_SCENE_KEY) > 0,
    "headless rendering keeps the original intro drawable"
  )
  rig.screen:dispose()
end

-- The wild encounter fade draws the faded intro upload while the task
-- runs and falls back to the static lease once it ends: uploads carry
-- the published frame's faded palette, the lease stays undrawn under
-- the fade, and the upload returns exactly once at the end.
function T.wild_encounter_fade_draws_the_faded_intro_while_active()
  local rig = openEncounterRig()
  rig.stage(stagedEncounterLayer(40, 36))
  rig.pump(5)
  Assert.isTrue(
    rig.port.enter({ launchId = rig.launchId, kind = "wild", encounterPaletteRestoreType = "wild" }),
    "entry admits the staged scene"
  )
  presentOpening(rig)
  rig.pump(13)
  local mid = FakeGraphics.new({})
  rig.screen:draw({ graphics = mid })
  Assert.isTrue(#drawsOf(mid.draws, "faded-intro-image") >= 1, "the running fade draws its faded intro upload")
  Assert.equal(
    #drawsOf(mid.draws, "scene-intro:" .. ENCOUNTER_SCENE_KEY),
    0,
    "the running fade draws no static intro lease"
  )
  Assert.isTrue(#rig.fadedRasters >= 2, "several encounter frames upload their own raster")
  Assert.deepEqual(
    { rig.fadedRasters[1]:pixel(0, 0) },
    { 255, 0, 0, 255 },
    "the first faded raster samples the unfaded red base"
  )
  local midFade = false
  local distinct = {}
  for _, raster in ipairs(rig.fadedRasters) do
    local r, g, b, a = raster:pixel(0, 0)
    distinct[r * 65536 + g * 256 + b] = true
    if r == 255 and g == 25 and b == 25 and a == 255 then
      midFade = true
    end
  end
  Assert.isTrue(midFade, "a mid-fade raster blends red toward white at coefficient 2")
  local distinctCount = 0
  for _ in pairs(distinct) do
    distinctCount = distinctCount + 1
  end
  Assert.isTrue(distinctCount >= 3, "successive frames advance the fade")
  local endedAt = nil
  for tick = 13, 160 do
    rig.pump(1)
    if rig.screen:view().openingPresentation.encounterFrame == nil then
      endedAt = tick
      break
    end
  end
  Assert.isTrue(endedAt ~= nil, "the encounter task ends after its systems retire")
  rig.pump(2)
  local settled = FakeGraphics.new({})
  rig.screen:draw({ graphics = settled })
  Assert.isTrue(
    #drawsOf(settled.draws, "scene-intro:" .. ENCOUNTER_SCENE_KEY) >= 1,
    "the ended task draws the static intro lease again"
  )
  Assert.equal(#drawsOf(settled.draws, "faded-intro-image"), 0, "the ended task draws no faded intro upload")
  Assert.equal(rig.released["battle-faded-intro"], 1, "the ended task returns its faded intro upload exactly once")
end

-- Unchanged visible colors reuse the current texture through source phases,
-- and repeated draws never trigger another upload. The frame-11 upload
-- carries that tick's displayed palette word, so pixels and the published
-- source frame describe one native tick.
function T.encounter_intro_uploads_follow_visible_palette_changes()
  local rig = openEncounterRig()
  local function paletteUploadCount()
    local count = 0
    for _, rasters in pairs(rig.paletteRasters) do
      count = count + #rasters
    end
    return count
  end
  rig.stage(stagedEncounterLayer(60, 43))
  rig.pump(5)
  Assert.isTrue(rig.port.enter({ launchId = rig.launchId, kind = "wild" }), "entry admits the staged scene")
  presentOpening(rig)

  for frame = 1, 10 do
    rig.pump(1)
    Assert.equal(rig.screen:view().openingPresentation.encounterFrame, frame, "the published frame advances")
    if frame == 1 then
      rig.initialUploadCount = #rig.fadedRasters
      rig.initialPaletteUploadCount = paletteUploadCount()
    end
  end
  Assert.equal(#rig.fadedRasters, rig.initialUploadCount, "frames 1 through 10 reuse the same visible colors")
  local beforeDraw = #rig.fadedRasters
  local paletteUploadsBeforeDraw = paletteUploadCount()
  rig.screen:draw({ graphics = FakeGraphics.new({}) })
  rig.screen:draw({ graphics = FakeGraphics.new({}) })
  Assert.equal(#rig.fadedRasters, beforeDraw, "drawing performs no palette image upload")
  Assert.equal(paletteUploadCount(), paletteUploadsBeforeDraw, "drawing performs no indexed plane upload")

  rig.pump(1)
  local frame11 = rig.screen:view()
  Assert.equal(frame11.openingPresentation.encounterFrame, 11, "frame 11 publishes the changed palette")
  Assert.isTrue(#rig.fadedRasters > beforeDraw, "a visible palette change uploads a replacement")
  Assert.isTrue(paletteUploadCount() > paletteUploadsBeforeDraw, "frame 11 uploads changed indexed plane pixels")
  local frame11Word = assert(
    frame11.openingPresentation.encounterPalette.mainBg[121],
    "the visible source color is staged"
  )
  local frame11Expected = Rgb555.decode(frame11Word)
  Assert.deepEqual(
    { rig.fadedRasters[#rig.fadedRasters]:pixel(0, 0) },
    { frame11Expected.r, frame11Expected.g, frame11Expected.b, 255 },
    "the frame-11 upload carries that tick's displayed palette word"
  )
  rig.pump(25)
  Assert.equal(rig.screen:view().openingPresentation.encounterFrame, 36, "the main fade settles on frame 36")
  local settledUploadCount = #rig.fadedRasters
  local settledPaletteUploadCount = paletteUploadCount()
  rig.pump(22)
  Assert.equal(rig.screen:view().openingPresentation.encounterFrame, 58, "the late task reaches frame 58")
  Assert.equal(
    #rig.fadedRasters,
    settledUploadCount,
    "late palette changes outside the visible source indices do not replace the raster"
  )
  Assert.equal(
    paletteUploadCount(),
    settledPaletteUploadCount,
    "late palette changes outside visible source indices do not replace indexed plane images"
  )
  local rastersBySource = {}
  for key, rasters in pairs(rig.paletteRasters) do
    local sourceKey = key:gsub(":generation:%d+$", "")
    local published = rastersBySource[sourceKey] or {}
    local generation = tonumber(key:match(":generation:(%d+)$"))
    for _, raster in ipairs(rasters) do
      published[#published + 1] = { generation = generation, raster = raster }
    end
    rastersBySource[sourceKey] = published
  end
  for sourceKey, uploads in pairs(rastersBySource) do
    table.sort(uploads, function(left, right)
      return left.generation < right.generation
    end)
    for index = 2, #uploads do
      local previous = uploads[index - 1].raster
      local current = uploads[index].raster
      Assert.isFalse(
        current.width == previous.width and current.height == previous.height and current.pixels == previous.pixels,
        "a source drawable never uploads a duplicate current raster: " .. sourceKey
      )
    end
  end
  Assert.equal(
    paletteUploadCount(),
    settledPaletteUploadCount,
    "late palette changes outside visible source indices do not replace indexed plane images"
  )
  rig.screen:dispose()
end

-- A configured image service failure is terminal and retains its cause.
-- It must not silently fall back to the original static intro.
function T.configured_intro_upload_failure_fails_the_battle_screen()
  local rig = openEncounterRig({ fadedIntroFailure = "GPU upload rejected" })
  rig.stage(stagedEncounterLayer(60, 43))
  rig.pump(5)
  Assert.isTrue(rig.port.enter({ launchId = rig.launchId, kind = "wild" }), "entry admits the staged scene")
  presentOpening(rig)

  local status = rig.pump(1, true)
  Assert.equal(status.mode, "failed", "a configured upload failure terminates the screen")
  for _, identity in ipairs({ rig.launchId, ENCOUNTER_SCENE_KEY, "faded intro", "GPU upload rejected" }) do
    Assert.isTrue(
      type(status.error) == "string" and status.error:find(identity, 1, true) ~= nil,
      "the terminal error names " .. identity .. ": " .. tostring(status.error)
    )
  end
  Assert.isNil(rig.screen._fadedIntroImage, "the failed frame publishes no prior intro image")
  rig.screen:dispose()
end

-- A second member whose textures never stage fails the launch at its
-- exact start tick instead of starting late or running silent.
function T.missing_second_member_fails_the_launch_at_its_start_tick()
  local rig = openEncounterRig()
  rig.stage(stagedEncounterLayer(60, 43, 2))
  rig.pump(5)
  Assert.isTrue(
    rig.port.enter({ launchId = rig.launchId, kind = "wild", encounterPaletteRestoreType = "wild" }),
    "entry admits the staged scene"
  )
  presentOpening(rig)
  local status = rig.pump(20, true)
  Assert.equal(status.mode, "failed", "a missing second member fails the launch at frame 20")
  Assert.isTrue(
    type(status.error) == "string" and status.error:find(ENCOUNTER_SCENE_KEY, 1, true) ~= nil,
    "the failure names the staged scene, got " .. tostring(status.error)
  )
  Assert.isTrue(
    type(status.error) == "string" and status.error:find("20", 1, true) ~= nil,
    "the failure names the missed source frame, got " .. tostring(status.error)
  )
end

-- A first member whose textures never stage fails before the task can
-- consume its first source tick.
function T.missing_first_member_fails_before_the_first_source_tick()
  local rig = openEncounterRig()
  rig.stage(stagedEncounterLayer(60, 43, 1))
  rig.pump(5)
  Assert.isTrue(
    rig.port.enter({ launchId = rig.launchId, kind = "wild", encounterPaletteRestoreType = "wild" }),
    "entry admits the staged scene"
  )
  presentOpening(rig)
  local status = rig.pump(2, true)
  Assert.equal(status.mode, "failed", "a missing first member fails before the first source tick")
  Assert.isTrue(
    type(status.error) == "string" and status.error:find(ENCOUNTER_SCENE_KEY, 1, true) ~= nil,
    "the failure names the staged scene, got " .. tostring(status.error)
  )
end

-- The fixed grass-day handoff through the real staged cache: the task
-- publishes one source frame per accepted tick, both member systems
-- start on their native ticks with their native voices, the bank fade
-- metadata selects the native masks at the native frames, and the late
-- bank operation arms at its native frame. The trace below records every
-- listed native frame; pixel-exactness against the original game stays
-- uncertified here (no original-game frame captures exist in the repo).
function T.grass_day_handoff_matches_the_native_task_schedule()
  local Trace = require("tests.support.BattleHandoffTrace")
  local rig = openEncounterRig()
  rig.stage(stagedEncounterLayer(60, 43, nil))
  rig.pump(5)
  Assert.isTrue(
    rig.port.enter({ launchId = rig.launchId, kind = "wild", encounterPaletteRestoreType = "wild" }),
    "entry admits the staged scene"
  )
  presentOpening(rig)
  local trace = Trace.new(ENCOUNTER_SCENE_KEY)
  local observed = {}
  local ticks = 0
  while ticks < 90 do
    rig.pump(1)
    ticks = ticks + 1
    local view = rig.screen:view()
    local opening = view.openingPresentation
    local frame = type(opening) == "table" and opening.encounterFrame or nil
    local systems = view.encounterParticleSystems
    local members, emitters = {}, {}
    if type(systems) == "table" then
      for _, system in ipairs(systems) do
        members[#members + 1] = tostring(system.setIndex)
        local live = system.simulation ~= nil and system.simulation.emitters or {}
        emitters[#emitters + 1] = #live
      end
    end
    trace:observe({
      taskFrame = frame,
      cover = 0,
      scene = ENCOUNTER_SCENE_KEY,
      members = members,
      activeEmitters = emitters,
    })
    observed[ticks] = {
      frame = frame,
      systems = type(systems) == "table" and #systems or 0,
      opening = opening,
    }
    if frame == nil and ticks > 70 then
      break
    end
  end
  Assert.equal(observed[1].frame, 1, "the first accepted tick publishes source frame 1")
  Assert.equal(observed[1].systems, 1, "the first member starts on frame 1")
  Assert.isTrue(observed[1].opening.encounterPalette ~= nil, "the first source frame carries the staged plane snapshot")
  Assert.equal(voiceCount(rig, BattleAudio.SINK_SOUNDS.encounterStart), 1, "the opening voice sounds on frame 1")
  for tick = 2, 19 do
    Assert.equal(observed[tick].frame, tick, "the task counts one frame per source tick at tick " .. tick)
    Assert.equal(observed[tick].systems, 1, "only the first member runs before frame 20")
  end
  Assert.equal(observed[10].opening.encounterFlash.mainBgMask, 0xF3FF, "the fade selects the native main BG mask")
  Assert.equal(observed[10].opening.encounterFlash.mainObjMask, 0x3FFF, "the fade selects the native main OBJ mask")
  Assert.equal(observed[18].frame, 18, "the task still counts through the late fade approach")
  Assert.equal(observed[20].frame, 20, "the task reaches the second member start")
  Assert.equal(observed[20].systems, 2, "the second member starts on frame 20")
  Assert.equal(observed[23].frame, 23, "the task reaches the settle voice")
  Assert.equal(
    voiceCount(rig, BattleAudio.SINK_SOUNDS.encounterSettle),
    1,
    "the settle voice sounds exactly once on frame 23"
  )
  Assert.equal(observed[25].systems, 2, "both members run through the mid fade")
  Assert.equal(observed[28].frame, 28, "the task reaches the restore frame")
  Assert.equal(observed[36].frame, 36, "the task runs on through the restore tail")
  Assert.equal(observed[45].systems, 2, "both members run through the late approach")
  Assert.equal(observed[50].frame, 50, "the task reaches the late bank frame")
  Assert.isTrue(observed[50].opening.encounterPalette ~= nil, "the late bank frame carries the plane snapshot")
  Assert.equal(
    observed[50].opening.encounterPalette.lateBgMask,
    0x0C00,
    "the late operation selects the native main BG bank pair"
  )
  Assert.isNil(observed[50].opening.encounterFlash, "the late operation retires the main fade metadata")
  local endedAt = nil
  for tick = 51, 90 do
    if observed[tick] ~= nil and observed[tick].frame == nil then
      endedAt = tick
      break
    end
  end
  Assert.notNil(endedAt, "the task ends after the second member retires")
  Assert.equal(observed[endedAt].systems, 0, "retired members leave the draw list")
  Assert.equal(
    voiceCount(rig, BattleAudio.SINK_SOUNDS.encounterStart),
    1,
    "the opening voice still sounds exactly once"
  )
  Assert.equal(
    voiceCount(rig, BattleAudio.SINK_SOUNDS.encounterSettle),
    1,
    "the settle voice still sounds exactly once"
  )
end

-- The palette upload keys published through the production holder,
-- stripped of their generation suffix so one source drawable counts
-- once no matter how many replacements it required.
---@param rig table live rig under inspection
---@return table<string, boolean> staged source drawable identities
local function publishedPaletteSources(rig)
  local seen = {}
  for key in pairs(rig.paletteRasters) do
    seen[key:gsub(":generation:%d+$", "")] = true
  end
  return seen
end

---@param rig table live rig under inspection
---@return integer total staged palette uploads across every source key
local function paletteUploadCount(rig)
  local count = 0
  for _, rasters in pairs(rig.paletteRasters) do
    count = count + #rasters
  end
  return count
end

-- The newest uploaded raster behind one published source drawable: the
-- holder keys every replacement upload by generation, so the latest
-- generation carries the currently published pixels.
---@param rig table live rig under inspection
---@param source string stripped source drawable identity
---@return table? newest uploaded raster, nil while the source never published
local function latestPublishedRaster(rig, source)
  local latest, latestGeneration = nil, -1
  for key, rasters in pairs(rig.paletteRasters) do
    if key:gsub(":generation:%d+$", "") == source then
      local generation = tonumber(key:match(":generation:(%d+)$")) or -1
      if generation >= latestGeneration and #rasters > 0 then
        latest, latestGeneration = rasters[#rasters], generation
      end
    end
  end
  return latest
end

-- A wild singles opening through the production screen samples only the
-- drawables the renderer can sample while the health boxes stay hidden:
-- both terrain slides and the command menu screens. Doubled HUD strips,
-- both singles HUDs, both party gauges, the other lower menus, trainer
-- slides, and ball frames never rasterize or upload, while the sampled
-- terrain and menu pixels match their displayed native words.

function T.wild_singles_palette_requests_cover_only_visible_drawables()
  local rig = openEncounterRig()
  rig.stage(stagedEncounterLayer(60, 43))
  rig.pump(5)
  Assert.isTrue(rig.port.enter({ launchId = rig.launchId, kind = "wild" }), "entry admits the staged scene")
  presentOpening(rig)
  for _ = 1, 12 do
    rig.pump(1)
    rig.screen:draw({ graphics = FakeGraphics.new({}) })
  end
  local seen = publishedPaletteSources(rig)
  Assert.isTrue(next(seen) ~= nil, "the singles opening publishes palette drawables")
  for _, forbidden in ipairs({
    ":hud:player-left",
    ":hud:player-right",
    ":hud:enemy-left",
    ":hud:enemy-right",
    ":hud:player",
    ":hud:enemy",
    ":gauges:player",
    ":gauges:enemy",
    ":menu:moves",
    ":menu:target",
    ":two-option",
    ":battle-palette:trainer:",
    ":battle-palette:ball:",
  }) do
    for key in pairs(seen) do
      Assert.isNil(key:find(forbidden, 1, true), "the wild singles opening never samples " .. forbidden .. ": " .. key)
    end
  end
  local prefix = "battle-palette:" .. ENCOUNTER_SCENE_KEY .. ":"
  for _, required in ipairs({
    prefix .. "scene-terrain:" .. ENCOUNTER_SCENE_KEY .. ":player",
    prefix .. "scene-terrain:" .. ENCOUNTER_SCENE_KEY .. ":foe",
    prefix .. "menu:command:screen:1@general",
  }) do
    Assert.isTrue(seen[required] == true, "the wild singles opening samples its visible art: " .. required)
  end
  local palette = rig.screen:view().openingPresentation.encounterPalette
  Assert.notNil(palette, "the composed frame carries its displayed native planes")
  local terrainExpected = Rgb555.decode(assert(palette.mainObj[33], "the terrain slot stages its word"))
  local terrainRaster = latestPublishedRaster(rig, prefix .. "scene-terrain:" .. ENCOUNTER_SCENE_KEY .. ":player")
  Assert.notNil(terrainRaster, "the terrain publishes its sampled raster")
  Assert.equal(terrainRaster.pixels:byte(1), terrainExpected.r, "the sampled terrain red follows its word")
  Assert.equal(terrainRaster.pixels:byte(2), terrainExpected.g, "the sampled terrain green follows its word")
  Assert.equal(terrainRaster.pixels:byte(3), terrainExpected.b, "the sampled terrain blue follows its word")
  Assert.equal(terrainRaster.pixels:byte(4), 255, "opaque terrain coverage stays opaque")
  local menuExpected = Rgb555.decode(assert(palette.subBg[1], "the menu slot stages its word"))
  local menuRaster = latestPublishedRaster(rig, prefix .. "menu:command:screen:1@general")
  Assert.notNil(menuRaster, "the command menu publishes its sampled raster")
  Assert.equal(menuRaster.pixels:byte(1), menuExpected.r, "the sampled menu red follows its word")
  Assert.equal(menuRaster.pixels:byte(2), menuExpected.g, "the sampled menu green follows its word")
  Assert.equal(menuRaster.pixels:byte(3), menuExpected.b, "the sampled menu blue follows its word")
  rig.screen:dispose()
end

---@param combatant integer native battler identity
---@param side integer 1 for the near side, 2 for the far side
---@param active boolean false while the slot stays benched
---@param visible boolean false while the slot hides mid-transition
---@param position integer claimed native slot
---@param name string displayed nickname
---@param species string staged species key
---@return table detached delivery-shaped battler record
local function trainerDoublesBattler(combatant, side, active, visible, position, name, species)
  return {
    combatant = combatant,
    participant = side == 1 and 1 or 2,
    side = side,
    controller = side == 1 and "player" or "trainer:2",
    active = active,
    visible = visible,
    position = position,
    hp = 20,
    maxHp = 20,
    species = species,
    form = 0,
    ballKey = "POKE_BALL",
    name = name,
    level = 9,
    selector = side == 1 and "back" or "front",
    portraitSelector = species .. "/f0/male/plain",
    moves = {},
    experience = 100,
  }
end

---@return table detached trainer doubles opening with one hidden foe slot
local function trainerDoublesOpening()
  return {
    playerTrainer = { classKey = "PKMN_TRAINER_ETHAN", name = "ETHAN" },
    foeTrainers = { { classKey = "YOUNGSTER", name = "YOUNGSTER" } },
    participants = {
      { participant = 1, side = 1 },
      { participant = 2, side = 2, controller = "trainer:2" },
    },
    own = {
      trainerDoublesBattler(1, 1, true, true, 1, "LEAD", "CHIKORITA"),
      trainerDoublesBattler(2, 1, true, true, 2, "PARTNER", "SHINX"),
    },
    foes = {
      trainerDoublesBattler(3, 2, true, true, 3, "FOE", "RATTATA"),
      trainerDoublesBattler(4, 2, true, false, 4, "HIDDEN", "GEODUDE"),
    },
  }
end

-- A trainer doubles opening binds exactly the occupied slot art. While
-- every battler hides, only the terrain slides and the command menu
-- publish: the hidden foe slot, both gauges, and every HUD stay
-- unpublished. Once the reveal facts the renderer consumes arrive (live
-- battlers with shown boxes and revealed gauge rows), the same tick
-- publishes the claimed doubles strips and both gauges with matching
-- pixels, and never the hidden slot or the singles families. The full
-- trainer ceremony never runs in this staged rig, so the test stages
-- the reveal facts directly instead of replaying its slide tracks.
function T.trainer_doubles_reveal_binds_visible_slots_and_enemy_gauge()
  local rig = openEncounterRig()
  rig.stage(stagedEncounterLayer(60, 43))
  rig.pump(5)
  Assert.isTrue(
    rig.port.enter({ launchId = rig.launchId, kind = "trainer", encounterPaletteRestoreType = "trainer" }),
    "entry admits the trainer scene"
  )
  local opening = trainerDoublesOpening()
  rig.port.present({ launchId = rig.launchId, packetId = 1, before = opening, after = opening, events = {} })
  for _ = 1, 12 do
    rig.pump(1)
    rig.screen:draw({ graphics = FakeGraphics.new({}) })
  end
  local prefix = "battle-palette:" .. ENCOUNTER_SCENE_KEY .. ":"
  Assert.deepEqual(publishedPaletteSources(rig), {
    [prefix .. "scene-terrain:" .. ENCOUNTER_SCENE_KEY .. ":player"] = true,
    [prefix .. "scene-terrain:" .. ENCOUNTER_SCENE_KEY .. ":foe"] = true,
    [prefix .. "menu:command:screen:1@general"] = true,
  }, "hidden slots, gauges, and HUDs publish nothing while every battler hides")
  -- Stage the reveal facts the renderer consumes: the three shown
  -- battlers go live with shown boxes, the fourth foe slot stays
  -- hidden, and both gauge rows reveal. The timeline hands out detached
  -- copies, so the reveal lands on its live records.
  local shown = rig.screen._timeline._battlers
  Assert.notNil(shown, "the timeline keeps its live battler records")
  for id, battler in pairs(shown) do
    if type(battler) == "table" and battler.combatant ~= 4 then
      battler.visible = true
      battler.hudVisible = true
    end
  end
  local timeline = rig.screen._timeline
  local realOpening = timeline.openingPresentation
  function timeline.openingPresentation(self)
    local presentation = realOpening(self)
    if type(presentation) == "table" then
      presentation.playerGaugeVisible = true
      presentation.enemyGaugeVisible = true
    end
    return presentation
  end
  rig.pump(1)
  rig.screen:draw({ graphics = FakeGraphics.new({}) })
  local late = publishedPaletteSources(rig)
  for _, required in ipairs({
    prefix .. "hud:player-left",
    prefix .. "hud:player-right",
    prefix .. "hud:enemy-left",
    prefix .. "gauges:player",
    prefix .. "gauges:enemy",
  }) do
    Assert.isTrue(late[required] == true, "the reveal binds its visible art the same tick: " .. required)
  end
  for _, forbidden in ipairs({
    prefix .. "hud:enemy-right",
    prefix .. "hud:player",
    prefix .. "hud:enemy",
  }) do
    Assert.isNil(late[forbidden], "the reveal never publishes hidden or singles art: " .. forbidden)
  end
  local palette = rig.screen:view().openingPresentation.encounterPalette
  Assert.notNil(palette, "the revealed frame carries its displayed native planes")
  local expected = Rgb555.decode(assert(palette.subObj[1], "the enemy gauge slot stages its word"))
  local raster = latestPublishedRaster(rig, prefix .. "gauges:enemy")
  Assert.notNil(raster, "the revealed gauge publishes its sampled raster")
  Assert.equal(raster.pixels:byte(1), expected.r, "the revealed gauge red follows its displayed word")
  Assert.equal(raster.pixels:byte(2), expected.g, "the revealed gauge green follows its displayed word")
  Assert.equal(raster.pixels:byte(3), expected.b, "the revealed gauge blue follows its displayed word")
  local hudExpected = Rgb555.decode(assert(palette.mainObj[1], "the doubles HUD slot stages its word"))
  local hudRaster = latestPublishedRaster(rig, prefix .. "hud:player-left")
  Assert.notNil(hudRaster, "the revealed doubles strip publishes its sampled raster")
  Assert.equal(hudRaster.pixels:byte(1), hudExpected.r, "the revealed HUD red follows its displayed word")
  Assert.equal(hudRaster.pixels:byte(2), hudExpected.g, "the revealed HUD green follows its displayed word")
  Assert.equal(hudRaster.pixels:byte(3), hudExpected.b, "the revealed HUD blue follows its displayed word")
  rig.screen:dispose()
end

-- A palette version bump that touches only banks no visible drawable
-- uses performs no rasterization and keeps every published image: the
-- screen reuses its sampled rasters and the holder performs no upload.
function T.unused_palette_banks_keep_published_drawables()
  local Raster = require("game.hgss.src.battle.BattleEncounterIndexedRaster")
  local realRender = Raster.render
  local rig = openEncounterRig()
  rig.stage(stagedEncounterLayer(60, 43))
  rig.pump(5)
  Assert.isTrue(rig.port.enter({ launchId = rig.launchId, kind = "wild" }), "entry admits the staged scene")
  presentOpening(rig)
  for _ = 1, 11 do
    rig.pump(1)
  end
  rig.pump(25)
  Assert.equal(rig.screen:view().openingPresentation.encounterFrame, 36, "the main fade settles on frame 36")
  local before = paletteUploadCount(rig)
  local terrainKey = "scene-terrain:" .. ENCOUNTER_SCENE_KEY .. ":player"
  local terrainBefore = rig.screen._assets:drawable(terrainKey)
  Assert.notNil(terrainBefore, "the settled frame publishes its sampled terrain")
  local timeline = rig.screen._timeline
  local realOpening = timeline.openingPresentation
  function timeline.openingPresentation(self)
    local presentation = realOpening(self)
    Assert.notNil(presentation.encounterPalette, "the steady frame carries its palette snapshot")
    presentation.encounterPalette.version = presentation.encounterPalette.version + 1
    presentation.encounterPalette.mainObj[6] = 0x7FFF
    return presentation
  end
  local renders = 0
  Raster.render = function(...)
    renders = renders + 1
    return realRender(...)
  end
  local ok, err = pcall(function()
    rig.pump(1)
  end)
  Raster.render = realRender
  Assert.isTrue(ok, "the unused bank change never fails the screen: " .. tostring(err))
  Assert.equal(renders, 0, "an unused bank change rasterizes no visible drawable")
  Assert.equal(paletteUploadCount(rig), before, "an unused bank change uploads no replacement")
  Assert.equal(
    rig.screen._assets:drawable(terrainKey),
    terrainBefore,
    "an unused bank change keeps the published image"
  )
  rig.screen:dispose()
end

-- Settled source frames advance readiness without palette work: the
-- published frame follows the encounter frame while no source map is
-- opened, no raster is sampled, and no image uploads.
function T.settled_palette_frames_publish_readiness_without_new_uploads()
  local rig = openEncounterRig()
  rig.stage(stagedEncounterLayer(60, 43))
  rig.pump(5)
  Assert.isTrue(rig.port.enter({ launchId = rig.launchId, kind = "wild" }), "entry admits the staged scene")
  presentOpening(rig)
  for _ = 1, 11 do
    rig.pump(1)
  end
  rig.pump(25)
  Assert.equal(rig.screen:view().openingPresentation.encounterFrame, 36, "the main fade settles on frame 36")
  local layer = rig.screen._assets:sceneLayer()
  Assert.notNil(layer, "the settled scene stages its layer")
  local realSourceMapFor = assert(layer.sourceMapFor, "the staged scene carries its source-map reader")
  local reads = 0
  layer.sourceMapFor = function(descriptor)
    reads = reads + 1
    return realSourceMapFor(descriptor)
  end
  local uploads = paletteUploadCount(rig)
  for _ = 1, 3 do
    rig.pump(1)
  end
  layer.sourceMapFor = realSourceMapFor
  Assert.equal(rig.screen:view().openingPresentation.encounterFrame, 39, "the settled frames advance")
  Assert.equal(reads, 0, "settled frames open no source maps")
  Assert.equal(paletteUploadCount(rig), uploads, "settled frames upload no replacement")
  Assert.equal(
    rig.screen._paletteDrawableFrame,
    39,
    "the published frame follows the encounter frame without new images"
  )
  Assert.isTrue(rig.screen:firstNativeBattleFrameReady(), "the settled frame stays ready")
  rig.screen:dispose()
end

return {
  tests = T,
}
