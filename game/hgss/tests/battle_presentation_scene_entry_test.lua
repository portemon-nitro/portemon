-- Switch-entry trajectory through the staged cache: a reserve arrival in a
-- doubled battle starts displaced toward its source spawn side and
-- settles exactly on its slot settled edge over source ticks, while the
-- surviving partner never leaves its own settled edge. The production
-- battle screen runs over the real staged presentation manifest with
-- real playback packets; draws record through a recording double, never
-- through a reimplementation of the renderer. Expected slot edges come
-- from the pinned native geometry (battle_hp_bar.c health-box
-- templates; overlay-7 spawn tables): the opponent-right settled edge
-- is one half inset left of X=176 at baseline Y=42. Needs a ready
-- user-owned ROM with a prepared derived cache, otherwise it skips.

local Assert = require("tests.support.Assert")
local FakeGraphics = require("tests.support.FakeGraphics")
local BattleScreenFixture = require("game.hgss.tests.support.BattleScreenFixture")
local BattlePresentationManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local EncounterParticlesFixture = require("tests.support.BattleEncounterParticlesFixture")
local StubLease = require("tests.support.StubLease")
local BattleAudio = require("libs.hgss.src.audio.BattleAudio")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}
local function stagedImageWidth(image)
  return image.width
end

local function stagedImageHeight(image)
  return image.height
end

local function stagedImageDimensions(image)
  return image.width, image.height
end

local function stagedImageFilter() end

local function stagedDrawable(key)
  local hud = key:match("^hud:") ~= nil
  return {
    handle = key,
    width = hud and 1648 or 256,
    height = hud and 8 or 256,
    getWidth = stagedImageWidth,
    getHeight = stagedImageHeight,
    getDimensions = stagedImageDimensions,
    setFilter = stagedImageFilter,
  }
end

local PICTURE_HALF = 40
local DOUBLES_SETTLED = {
  { side = 2, x = 40, y = 112 },
  { side = 4, x = 80, y = 120 },
  { side = 3, x = 216, y = 50 },
  { side = 5, x = 176, y = 42 },
}

---@param center table<string, number> native settled center under test driving
---@param height number|nil signed height displacement under test driving
---@return number expected nominal image left edge
---@return number expected nominal image top edge
local function nominalOrigin(center, height)
  local displacement = 0
  if type(height) == "number" then
    displacement = height
  end
  return center.x - PICTURE_HALF, center.y - PICTURE_HALF + displacement
end

---@return table recording text boundary behind one draw
local function recordingText()
  local text = { draws = {} }
  function text.measure(content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(content, x, y)
    text.draws[#text.draws + 1] = { content = tostring(content), x = x, y = y, palette = nil }
  end
  function text.drawTextWithPalette(content, x, y, palette)
    text.draws[#text.draws + 1] = { content = tostring(content), x = x, y = y, palette = palette }
  end
  return text
end

---@return table recording window boundary behind one draw
local function recordingWindows()
  local windows = { boxes = {} }
  function windows.drawWindow(box, frameKey, background)
    windows.boxes[#windows.boxes + 1] = { box = box, frame = frameKey, background = background }
  end
  function windows.drawApplicationFrame(box, frameIndex)
    windows.boxes[#windows.boxes + 1] = { box = box, frame = frameIndex }
  end
  return windows
end

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

-- A reserve arrival in a doubled battle starts displaced toward its
-- source spawn side and settles exactly on its slot settled edge, while
-- the surviving partner never leaves its own settled edge.
function T.switched_arrival_travels_from_its_spawn_side_to_its_settled_edge(_, context)
  local RomImporter = require("romdump.src.source.RomImporter")
  local GameVersion = require("romdump.src.source.GameVersion")
  local ready = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      ready[#ready + 1] = versionId
    end
  end
  if #ready == 0 then
    context:skip("the switch-entry trajectory needs a ready user-owned ROM with a derived cache")
  end
  local CacheFs = require("libs.storage.src.CacheFs")
  local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
  local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
  local BattleScreenState = require("game.hgss.tests.support.BattleScreenFixture")
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  local versionId = ready[1]
  local cacheFs = CacheFs.forVersion(versionId)
  local core = BattlePresentationCache.load(cacheFs)
  Assert.equal(core.schema, BattlePresentationCache.MANIFEST_SCHEMA, versionId .. " stages the v3 battle manifest")
  Assert.equal(#core.battlefield.slots, 6, versionId .. " stages all six source slot geometries")
  Assert.isTrue(#core.hud.player.cells > 0, versionId .. " stages native player health-box cells")
  Assert.equal(core.hud.player.componentCount, 78, versionId .. " stages native health-box patch tiles")
  Assert.isTrue(next(core.pictures.selectors) ~= nil, versionId .. " stages source picture selectors")
  local scopeText = recordingText()
  local scopeWindows = recordingWindows()
  local launchId = "scene-entry-probe"
  -- The screen binds one launch view over the real staged core: shared
  -- sections borrow by reference while the exact trainer and ball leaves
  -- behind the switch packets stage as launch entries.
  local view = {}
  for key, value in pairs(core) do
    view[key] = value
  end
  local backPic = assert(
    BattlePresentationCache.loadTrainerPicture(cacheFs, "back:PKMN_TRAINER_ETHAN"),
    versionId .. " stages the player backpic leaf"
  )
  local frontPic = assert(
    BattlePresentationCache.loadTrainerPicture(cacheFs, "front:YOUNGSTER"),
    versionId .. " stages the foe front leaf"
  )
  local ballLeaf =
    assert(BattlePresentationCache.loadBall(cacheFs, "ball:POKE_BALL"), versionId .. " stages the lead ball leaf")
  view.trainerPictures = {
    entries = {
      ["back:PKMN_TRAINER_ETHAN"] = backPic.entry,
      ["front:YOUNGSTER"] = frontPic.entry,
    },
  }
  view.battleBalls = { entries = { ["ball:POKE_BALL"] = ballLeaf.entry } }
  local screen = BattleScreenState.new({
    launchId = launchId,
    manifest = view,
    model = BattlePresentationModel,
    submit = function(_)
      return true
    end,
    measureDisplay = function()
      return {
        width = 256,
        height = 384,
        topology = ScreenTopology.dualDisplay(
          { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
          { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
        ),
        pixelRatio = 1,
        signature = "scene-entry-probe:dual",
      }
    end,
    assets = {
      prepare = function(_)
        return true
      end,
      -- The holder calls its preparation services dot-style, so the
      -- recording double takes the key directly for handles to resolve.
      drawable = function(key)
        return stagedDrawable(key)
      end,
      release = function(_, _) end,
    },
    text = scopeText,
    windows = scopeWindows,
    audio = {
      play = function(_)
        return true
      end,
    },
    overrides = { sceneKey = "general/grass/day" },
  })
  local function foeRecord(combatant, position, activation, name, selector)
    return {
      combatant = combatant,
      side = 2,
      active = true,
      species = "RATTATA",
      form = 0,
      selector = "front",
      portraitSelector = selector,
      name = name,
      level = 4,
      hp = 12,
      maxHp = 12,
      position = position,
      activation = activation,
    }
  end
  local function ownRecord(combatant, position, activation, name, selector)
    return {
      combatant = combatant,
      side = 1,
      active = true,
      species = "CHIKORITA",
      form = 0,
      selector = "back",
      portraitSelector = selector,
      name = name,
      level = 9,
      hp = 30,
      maxHp = 30,
      experience = 120,
      position = position,
      activation = activation,
    }
  end
  local opening = {
    own = {
      ownRecord(1, 0, 11, "LEAD", "CHIKORITA/f0/male/plain/back"),
      ownRecord(4, 1, 14, "ALLY", "CHIKORITA/f0/female/plain/back"),
    },
    foes = {
      foeRecord(2, 2, 12, "FOE-A", "RATTATA/f0/male/plain"),
    },
  }
  local port = screen:presentationPort()
  port.enter({ launchId = launchId, kind = "wild", encounterPaletteRestoreType = "ordinary-doubles" })
  for _ = 1, 5 do
    screen:updateFixed(1 / 60)
  end
  Assert.isTrue(
    port.enter({ launchId = launchId, kind = "wild", encounterPaletteRestoreType = "ordinary-doubles" }),
    versionId .. " enters its staged doubled scene"
  )
  port.present({ launchId = launchId, packetId = 1, before = opening, after = opening, events = {} })
  for _ = 1, 1200 do
    screen:updateFixed(1 / 60)
  end
  local openingGraphics = FakeGraphics.new({})
  screen:draw({ graphics = openingGraphics })
  local openingRattata = drawsOf(openingGraphics.draws, "mon:RATTATA/f0/male/plain")
  local sourceSelector = core.pictures.selectors["pokemon/RATTATA/form-0/male/front"]
  local sourceAttributes = core.pictures.attributes[sourceSelector.attributes]
  Assert.equal(#openingRattata, 1, "the opening foe uses its exact staged portrait")
  local portraitTop = math.huge
  for _, vertex in ipairs(assert(openingRattata[1].meshVertices, "the production mesh carries source vertices")) do
    portraitTop = math.min(portraitTop, vertex[2])
  end
  -- Pokepic lowers the picture by its height and lifts an opponent's by
  -- the species shadow height.
  local expectedTop = DOUBLES_SETTLED[3].y - PICTURE_HALF + sourceAttributes.height - sourceAttributes.shadow.height
  Assert.equal(
    portraitTop,
    expectedTop,
    "the real screen resolves staged front-facing source height into its mesh origin, got "
      .. tostring(portraitTop)
      .. " expected "
      .. tostring(expectedTop)
  )
  local function arrivalDraws()
    local graphics = FakeGraphics.new({})
    screen:draw({ graphics = graphics })
    return drawsOf(graphics.draws, "mon:RATTATA/f0/male/shiny")
  end
  local function pictureLeft(entry)
    local left = math.huge
    for _, vertex in ipairs(assert(entry.meshVertices, "the production mesh carries source vertices")) do
      left = math.min(left, vertex[1])
    end
    return left
  end
  local before = arrivalDraws()
  Assert.equal(#before, 0, "the reserve arrival draws nothing before its switch packet")
  local switchedAfter = {
    own = opening.own,
    foes = {
      foeRecord(2, 2, 12, "FOE-A", "RATTATA/f0/male/plain"),
      foeRecord(3, 3, 21, "FOE-B", "RATTATA/f0/male/shiny"),
    },
  }
  port.present({
    launchId = launchId,
    packetId = 2,
    before = opening,
    after = switchedAfter,
    events = { { kind = "join", payload = { combatant = 3 } } },
  })
  screen:startPictureEntry(switchedAfter.foes[2], 8)
  local trajectory = {}
  for _ = 1, 600 do
    screen:updateFixed(1 / 60)
    local graphics = FakeGraphics.new({})
    screen:draw({ graphics = graphics })
    local pictures = drawsOf(graphics.draws, "mon:RATTATA/f0/male/shiny")
    if #pictures >= 1 then
      trajectory[#trajectory + 1] = pictureLeft(pictures[1])
    end
  end
  Assert.isTrue(#trajectory >= 1, "the switched arrival becomes visible after its switch packet")
  local settledArrivalX = nominalOrigin(DOUBLES_SETTLED[4], 0)
  Assert.equal(
    trajectory[#trajectory],
    settledArrivalX,
    "the switched arrival settles exactly on its slot settled edge"
  )
  local displaced = false
  for _, x in ipairs(trajectory) do
    if
      x --[[@as number]]
      < settledArrivalX - 4
    then
      displaced = true
      break
    end
  end
  Assert.isTrue(displaced, "the switched arrival starts displaced toward its source spawn side before settling")
  local survivorGraphics = FakeGraphics.new({})
  screen:draw({ graphics = survivorGraphics })
  local survivor = drawsOf(survivorGraphics.draws, "mon:RATTATA/f0/male/plain")
  Assert.isTrue(#survivor >= 1, "the surviving foe still draws after the arrival settles")
  local survivorX = nominalOrigin(DOUBLES_SETTLED[3], 0)
  Assert.equal(pictureLeft(survivor[1]), survivorX, "the surviving foe never leaves its settled edge")
end

-- The retail encounter opening through the real screen gate: admission
-- waits for the staged scene, the first source tick publishes frame 1
-- with the first member and its voice, draws and remeasure advance
-- nothing, and the task ends only after the second member retires.
-- Texture handles are strict pool leases through the production holder;
-- readiness is the holder state behind the runtime entry gate, never a
-- frame-count tolerance in the test.
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
  local objBank = sourcePalette(16)
  local layer = {
    sceneKey = ENCOUNTER_SCENE_KEY,
    mainObjBallSources = {},
    mainObjPostFill = {},
    paletteSource = {
      mainBg = mainBgSource,
      mainObjSources = {
        hud = { firstSlot = 0, words = objBank },
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
      },
      foe = {
        drawable = StubLease.new("scene-terrain:" .. ENCOUNTER_SCENE_KEY .. ":foe"),
        width = 64,
        height = 64,
        origin = { x = 0, y = 0 },
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
  local withheld = { ["scene:" .. ENCOUNTER_SCENE_KEY] = opts.withheldScene == true }
  local images = {}
  local released = {}
  local fadedRasters = {}
  local assets = {}
  function assets.prepare(_)
    return true
  end
  function assets.sceneLayer()
    return staged
  end
  function assets.fadedIntro(raster)
    fadedRasters[#fadedRasters + 1] = raster
    return { handle = "faded-intro-image" }
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
    manifest = BattlePresentationManifestFixture.manifest(),
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
  local rig =
    { screen = screen, port = port, audio = audio, launchId = launchId, fadedRasters = fadedRasters, released = released }
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

function T.native_palette_layout_rebuilds_for_a_replaced_scene_layer()
  local rig = openEncounterRig()
  rig.stage(stagedEncounterLayer(60, 43))
  rig.pump(5)
  presentOpening(rig)
  Assert.isTrue(rig.screen._nativePaletteLayoutReady, "the first scene publishes its native layout")

  local replacement = stagedEncounterLayer(60, 43)
  rig.screen._assets._sceneLayer = replacement
  Assert.isTrue(rig.screen:_stageNativePaletteLayout(), "a replaced staged layer rebuilds its layout")
  Assert.isTrue(type(replacement.nativePaletteLayout) == "table", "the current layer owns its native layout")
  rig.screen:dispose()
end

-- The private render snapshot carries each live particle owner through the
-- production screen draw in detail and compact layouts. Repeated draws keep
-- all three simulations and the encounter source frame unchanged.
function T.screen_draws_live_particle_owners_in_detail_and_compact_layouts()
  local rig = openEncounterRig()
  local ok, err = pcall(function()
    rig.stage(stagedEncounterLayer(60, 43))
    rig.pump(5)
    Assert.isTrue(rig.port.enter({ launchId = rig.launchId, kind = "wild", encounterPaletteRestoreType = "wild" }), "entry admits the staged scene")
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
    rig.screen._ballParticles:step(
      { { effect = "seal", ballKey = "POKE_BALL", battlerType = 0 } },
      {},
      {
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
      }
    )

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
    Assert.equal(after.openingPresentation.encounterFrame, before.openingPresentation.encounterFrame, "draws do not advance the encounter timeline")
    Assert.equal(#after.encounterParticleSystems, #before.encounterParticleSystems, "draws do not step encounter emitters")
    Assert.equal(#after.moveParticleSystems, #before.moveParticleSystems, "draws do not step move emitters")
    Assert.equal(#after.ballParticleSystems, #before.ballParticleSystems, "draws do not step ball emitters")
    rig.screen._scene:releaseParticleSystem(moveSystemId)
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
  Assert.isTrue(rig.port.enter({ launchId = rig.launchId, kind = "wild", encounterPaletteRestoreType = "wild" }), "entry admits the staged scene")
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
  Assert.isTrue(rig.port.enter({ launchId = rig.launchId, kind = "wild", encounterPaletteRestoreType = "wild" }), "the sourced scene admits")
  presentOpening(rig)
  rig.pump(1)

  local palette = assert(rig.screen:view().openingPresentation.encounterPalette, "the first tick publishes native palette state")
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

-- The wild encounter fade draws the faded intro upload while the task
-- runs and falls back to the static lease once it ends: uploads carry
-- the published frame's faded palette, the lease stays undrawn under
-- the fade, and the upload returns exactly once at the end.
function T.wild_encounter_fade_draws_the_faded_intro_while_active()
  local rig = openEncounterRig()
  rig.stage(stagedEncounterLayer(40, 36))
  rig.pump(5)
  Assert.isTrue(rig.port.enter({ launchId = rig.launchId, kind = "wild", encounterPaletteRestoreType = "wild" }), "entry admits the staged scene")
  presentOpening(rig)
  rig.pump(13)
  local mid = FakeGraphics.new({})
  rig.screen:draw({ graphics = mid })
  Assert.isTrue(
    #drawsOf(mid.draws, "faded-intro-image") >= 1,
    "the running fade draws its faded intro upload"
  )
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
  Assert.equal(
    #drawsOf(settled.draws, "faded-intro-image"),
    0,
    "the ended task draws no faded intro upload"
  )
  Assert.equal(
    rig.released["battle-faded-intro"],
    1,
    "the ended task returns its faded intro upload exactly once"
  )
end

-- A second member whose textures never stage fails the launch at its
-- exact start tick instead of starting late or running silent.
function T.missing_second_member_fails_the_launch_at_its_start_tick()
  local rig = openEncounterRig()
  rig.stage(stagedEncounterLayer(60, 43, 2))
  rig.pump(5)
  Assert.isTrue(rig.port.enter({ launchId = rig.launchId, kind = "wild", encounterPaletteRestoreType = "wild" }), "entry admits the staged scene")
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
  Assert.isTrue(rig.port.enter({ launchId = rig.launchId, kind = "wild", encounterPaletteRestoreType = "wild" }), "entry admits the staged scene")
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
  Assert.isTrue(rig.port.enter({ launchId = rig.launchId, kind = "wild", encounterPaletteRestoreType = "wild" }), "entry admits the staged scene")
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

return {
  tests = T,
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "battle-presentation:global",
      "battle-scene:general/grass/day",
      "battle-trainer-picture:back-PKMN_TRAINER_ETHAN",
      "battle-trainer-picture:front-YOUNGSTER",
      "battle-ball:POKE_BALL",
    },
  },
}
