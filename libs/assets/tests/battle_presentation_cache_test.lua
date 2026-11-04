-- Battle presentation cache boundary without a dump: canonical paths,
-- the scene inventory, exact deterministic demands, and truthful
-- readiness over staged files. Staged fixtures are synthetic; the ROM
-- suite proves the compiler stages the same shapes.

local ParticlesFixture = require("tests.support.BattleEncounterParticlesFixture")
local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local BattlePresentationSchema = require("libs.assets.src.battle.BattlePresentationSchema")
local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local MonCache = require("libs.assets.src.MonCache")
local PngWriter = require("tests.support.PngEncoder")

local T = {}

local function staging()
  return CacheFs.forVersion("heartgold", FakeCache.new())
end

function T.canonical_paths_keep_global_and_scene_roots_apart()
  Assert.equal(
    BattlePresentationCache.manifestPath(),
    "data/generated/battle/battle_presentation.lua",
    "the global manifest has its own path"
  )
  Assert.equal(
    BattlePresentationCache.markerPath(),
    "data/generated/battle/battle_presentation.complete",
    "the global marker has its own path"
  )
  Assert.equal(
    BattlePresentationCache.scenePath("general/grass/day"),
    "data/generated/battle/scenes/general-grass-day.lua",
    "scene keys map to file-safe scene paths"
  )
  Assert.equal(
    BattlePresentationCache.sceneImagePath("general/grass/day"),
    "assets/generated/battle/scenes/general-grass-day.png",
    "scene images live beside the scene record name"
  )
  Assert.equal(
    BattlePresentationCache.sceneIntroImagePath("general/grass/day"),
    "assets/generated/battle/scenes/general-grass-day-intro.png",
    "unbaked intro images have a dedicated scene path"
  )
  Assert.equal(
    BattlePresentationCache.sceneTerrainSpritePath("general/grass/day", "foe"),
    "assets/generated/battle/scenes/general-grass-day-terrain-foe.png",
    "terrain OBJ images have side-specific scene paths"
  )
  Assert.equal(
    BattlePresentationCache.sceneIntroCharactersPath("general/grass/day"),
    "data/generated/battle/scenes/general-grass-day-intro.bg3.chars",
    "unbaked intro characters have a dedicated scene path"
  )
  Assert.equal(
    BattlePresentationCache.sceneMarkerPath("general/grass/day"),
    "data/generated/battle/scenes/general-grass-day.complete",
    "scene markers live beside the scene record"
  )
  Assert.equal(
    BattlePresentationCache.evolutionGraphicsPath("main"),
    "assets/generated/battle/evolution-main.png",
    "evolution graphics use their semantic screen-layer path"
  )
end

function T.scene_inventory_covers_every_ordinary_combination()
  local inventory = BattlePresentationCache.sceneInventory()
  Assert.equal(#inventory, 18 * 18 * 3, "every background/terrain/time combination is inventoried")
  local seen = {}
  for _, entry in ipairs(inventory) do
    Assert.equal(entry.key, entry.background .. "/" .. entry.terrain .. "/" .. entry.time, "keys join their axes")
    Assert.isNil(seen[entry.key], "the inventory carries no duplicate key")
    seen[entry.key] = true
  end
  Assert.notNil(seen["general/grass/day"], "the ordinary grass day scene is inventoried")
  Assert.notNil(seen["cave_1/cave/day"], "the cave scene is inventoried")
  Assert.isNil(seen["effect/flash/day"], "effect backgrounds are never inventoried")
end

---@return table planning manifest synthesized without staged files
local function planningManifest()
  return BattlePresentationCache.load(staging())
end

function T.empty_staging_loads_a_planning_manifest_but_never_reads_ready()
  local manifest = planningManifest()
  Assert.equal(manifest.verified, false, "an unstaged manifest plans instead of proving")
  Assert.isTrue(type(manifest.scenes) == "table" and #manifest.scenes > 0, "planning still inventories scenes")
  local demand = assert(
    BattlePresentationCache.requirements(
      manifest,
      { background = "general", terrain = "grass", time = "day" },
      { MonCache.portraitSelector("CHIKORITA", 0, "male", false, "back") },
      nil,
      {},
      {}
    )
  )
  Assert.isTrue(BattlePresentationSchema.isValidDemand(demand), "a planning demand keeps its shape")
  Assert.isFalse(BattlePresentationCache.isReady(staging(), demand), "an empty staging area is never ready")
end

function T.single_battle_demands_stay_exact_deterministic_and_deduplicated()
  local manifest = planningManifest()
  local context = { background = "general", terrain = "grass", time = "day" }
  local selectors = {
    MonCache.portraitSelector("TOTODILE", 0, "male", false),
    MonCache.portraitSelector("CHIKORITA", 0, "male", false, "back"),
    MonCache.portraitSelector("CHIKORITA", 0, "male", false, "back"),
  }
  local first = assert(BattlePresentationCache.requirements(manifest, context, selectors, nil, {}, {}))
  local second = assert(BattlePresentationCache.requirements(manifest, context, selectors, nil, {}, {}))
  Assert.deepEqual(first, second, "demands are deterministic")
  Assert.deepEqual(first.scenes, { "general/grass/day" }, "one battle demands exactly one scene")
  Assert.deepEqual(first.pages, {
    "CHIKORITA/f0/male/plain/back",
    "TOTODILE/f0/male/plain",
  }, "portrait selectors deduplicate and sort")
  local unknown, err = BattlePresentationCache.requirements(
    manifest,
    { background = "effect", terrain = "flash", time = "day" },
    selectors,
    nil,
    {},
    {}
  )
  Assert.isNil(unknown, "an effect background never yields a demand")
  Assert.notNil(err, "the rejected context explains itself")
end

local validManifest = ManifestFixture.manifest

local function stagePng(cache, path, width, height)
  local pixels = string.rep("\1\2\3\255", width * height)
  cache:write(path, PngWriter.encode(width, height, pixels))
end

function T.evolution_particles_load_only_from_the_leaf_record_and_check_texture_closure()
  local cache = staging()
  Assert.isNil(BattlePresentationCache.loadEvolutionParticles(cache), "an unstaged leaf exposes no playable particles")
  Assert.isFalse(
    BattlePresentationCache.isEvolutionParticlesReady(cache, "evolution-marker"),
    "an unstaged EvolutionScene particle payload is not ready"
  )

  local leaf = ManifestFixture.evolutionRecord()
  cache:writeLua(BattlePresentationCache.evolutionPath(), leaf)
  cache:write(BattlePresentationCache.evolutionMarkerPath(), "evolution-marker")
  local texture = leaf.particles.textures[1]
  stagePng(cache, texture.image, texture.width, texture.height)

  local particles = assert(BattlePresentationCache.loadEvolutionParticles(cache))
  Assert.equal(particles.seed, 0, "the leaf loader returns the normalized particle payload")
  Assert.equal(#particles.emitters, #leaf.particles.emitters, "the leaf loader returns the complete emitter list")
  Assert.isTrue(
    BattlePresentationCache.isEvolutionParticlesReady(cache, "evolution-marker"),
    "the marker and complete texture closure establish readiness"
  )
  Assert.isFalse(
    BattlePresentationCache.isEvolutionParticlesReady(cache, "stale-marker"),
    "a stale leaf marker prevents readiness"
  )

  stagePng(cache, texture.image, texture.width + 1, texture.height)
  Assert.isFalse(
    BattlePresentationCache.isEvolutionParticlesReady(cache, "evolution-marker"),
    "a texture with dimensions different from the leaf record is not ready"
  )
end

function T.evolution_graphics_load_only_from_the_leaf_record_and_check_all_screen_rasters()
  local cache = staging()
  Assert.isNil(BattlePresentationCache.loadEvolutionGraphics(cache), "an unstaged leaf exposes no evolution BG rasters")
  Assert.isFalse(
    BattlePresentationCache.isEvolutionGraphicsReady(cache, "evolution-marker"),
    "an unstaged EvolutionScene BG set is not ready"
  )

  local leaf = ManifestFixture.evolutionRecord()
  cache:writeLua(BattlePresentationCache.evolutionPath(), leaf)
  cache:write(BattlePresentationCache.evolutionMarkerPath(), "evolution-marker")
  for _, layer in ipairs({ "main", "sub", "menu" }) do
    local image = leaf.graphics[layer]
    stagePng(cache, image.image, image.width, image.height)
  end
  for _, animationRole in ipairs({ "idle", "select" }) do
    for _, frame in ipairs(leaf.graphics.cursor.animations[animationRole].frames) do
      stagePng(cache, frame.image, frame.width, frame.height)
    end
  end

  local graphics = assert(BattlePresentationCache.loadEvolutionGraphics(cache))
  Assert.equal(
    graphics.main.image,
    "assets/generated/battle/evolution-main.png",
    "leaf loading returns the source-selected main BG raster"
  )
  Assert.equal(
    graphics.cursor.animations.select.frames[2].drawableKey,
    "battle:evolution-cursor:select:1",
    "leaf loading exposes the selected cursor sequence"
  )
  Assert.deepEqual(
    graphics.menuTextPalette.colors[2],
    { r = 2, g = 14, b = 26 },
    "leaf loading exposes the source-backed EvolutionScene font palette"
  )
  Assert.isTrue(
    BattlePresentationCache.isEvolutionGraphicsReady(cache, "evolution-marker"),
    "the marker and every screen raster establish readiness"
  )
  cache:remove(graphics.sub.image)
  Assert.isFalse(
    BattlePresentationCache.isEvolutionGraphicsReady(cache, "evolution-marker"),
    "a missing screen raster does not reach the PNG dimension parser"
  )
  stagePng(cache, graphics.sub.image, graphics.sub.width, graphics.sub.height)
  cache:remove(graphics.cursor.animations.select.frames[1].image)
  Assert.isFalse(
    BattlePresentationCache.isEvolutionGraphicsReady(cache, "evolution-marker"),
    "a missing cursor frame does not reach the PNG dimension parser"
  )
  local selectFrame = graphics.cursor.animations.select.frames[1]
  stagePng(cache, selectFrame.image, selectFrame.width, selectFrame.height)
  local menu = leaf.graphics.menu
  stagePng(cache, menu.image, menu.width, menu.height - 1)
  Assert.isFalse(
    BattlePresentationCache.isEvolutionGraphicsReady(cache, "evolution-marker"),
    "one malformed layer prevents the three-layer scene from being ready"
  )
end

-- Minimal hand-built PNG envelope: the mon page validator checks
-- structure, never CRCs, so the fixture carries a real-headed envelope
-- without a pixel payload.
local function envelopePng()
  local function u32(v)
    return string.char(math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256)
  end
  return "\137PNG\r\n\26\n"
    .. u32(13)
    .. "IHDR"
    .. u32(8)
    .. u32(8)
    .. "\8\2\0\0\0"
    .. u32(0)
    .. u32(1)
    .. "IDAT"
    .. "\120"
    .. u32(0)
    .. u32(0)
    .. "IEND"
    .. u32(0)
end

local function stageMonPage(cache, selector)
  cache:writeLua(MonCache.portraitManifestPath(), {
    schema = "g4-mon-portrait-manifest-v2",
    version = { id = "heartgold", language = "en" },
    pages = { [0] = { pageId = 0, image = MonCache.portraitPagePath(0), width = 8, height = 8 } },
    pageIds = { 0 },
    entries = {
      [selector] = {
        x = 0,
        y = 0,
        width = 8,
        height = 8,
        pageId = 0,
        frames = { { x = 0, y = 0, width = 8, height = 8 } },
      },
    },
    representative = { selector },
  })
  cache:writeLua(MonCache.indexPath(), {
    schema = "g4-mon-index-v2",
    version = { id = "heartgold", language = "en" },
    catalogHash = string.rep("a", 40),
    catalog = MonCache.catalogPath(),
    iconManifest = MonCache.iconManifestPath(),
    portraitManifest = MonCache.portraitManifestPath(),
    iconPages = { "icon-marker-0" },
    portraitPages = { "portrait-marker-0" },
  })
  cache:write(MonCache.pageMarkerPath("portraits", 0), "portrait-marker-0")
  cache:write(MonCache.pageImagePath("portraits", 0), envelopePng())
end

local function stageSourceIndices(cache, sourceIndices)
  for _, variant in pairs(sourceIndices.variants) do
    cache:write(
      variant.path,
      string.rep(string.char(0, 0, 0, 0), sourceIndices.width * sourceIndices.height)
    )
  end
end

local function stageBattle(cache, manifest, sceneKey)
  cache:writeLua(BattlePresentationCache.manifestPath(), manifest)
  cache:write(BattlePresentationCache.markerPath(), "marker")
  for path, geometry in pairs(manifest.menus.images) do
    stagePng(cache, path, geometry.width, geometry.height)
  end
  local function stageGlobalSourceIndices(source)
    if type(source) ~= "table" then
      return
    end
    local function writePath(path)
      cache:write(path, string.rep(string.char(0, 0, 0, 0), source.width * source.height))
    end
    if type(source.path) == "string" then
      writePath(source.path)
    end
    if type(source.variants) == "table" then
      for _, variant in pairs(source.variants) do
        writePath(variant.path)
      end
    end
  end
  for _, sectionName in ipairs({ "command", "moves", "target", "twoOption" }) do
    for _, screen in ipairs(manifest.menus[sectionName].screens) do
      stageGlobalSourceIndices(screen.sourceIndices)
      if screen.feedback ~= nil then
        for _, states in pairs(screen.feedback) do
          for _, patch in pairs(states) do
            stageGlobalSourceIndices(patch.sourceIndices)
          end
        end
      end
      if screen.moveButtons ~= nil then
        for _, button in ipairs(screen.moveButtons) do
          stageGlobalSourceIndices(button.sourceIndices.empty)
          for _, typeStates in pairs(button.sourceIndices.types) do
            for _, source in pairs(typeStates) do
              stageGlobalSourceIndices(source)
            end
          end
        end
      end
    end
  end
  local trainerPictures = type(manifest.trainerPictures) == "table" and manifest.trainerPictures.entries or nil
  if type(trainerPictures) == "table" then
    for _, entry in pairs(trainerPictures) do
      for _, sequence in ipairs(entry.animation.sequences) do
        for _, frame in ipairs(sequence.frames) do
          stageGlobalSourceIndices(frame.sourceIndices)
        end
      end
    end
  end
  local battleBalls = type(manifest.battleBalls) == "table" and manifest.battleBalls.entries or nil
  if type(battleBalls) == "table" then
    for _, entry in pairs(battleBalls) do
      for _, frame in ipairs(entry.frames) do
        stageGlobalSourceIndices(frame.sourceIndices)
      end
    end
  end
  local record = {
    schema = "g4-battle-scene-v5",
    key = sceneKey,
    background = "general",
    terrain = "grass",
    time = "day",
    canvasWidth = 512,
    canvasHeight = 256,
    viewport = { x = 0, y = 0, width = 256, height = 192 },
    layers = {
      {
        key = "background",
        backing = { width = 512, height = 256, mapWidth = 64, mapHeight = 32 },
        viewport = { x = 0, y = 0, width = 256, height = 192 },
        scroll = { x = 0, y = 0 },
        characters = {
          key = "battle-scene/general-grass-day/background/characters",
          path = "data/generated/battle/scenes/general-grass-day.bg3.chars",
          format = "indexed8",
        },
        baseCharacters = {
          key = "battle-scene/general-grass-day/intro/characters",
          path = "data/generated/battle/scenes/general-grass-day-intro.bg3.chars",
          format = "indexed8",
        },
        map = {
          key = "battle-scene/general-grass-day/background/map",
          path = "data/generated/battle/scenes/general-grass-day.bg3.map.lua",
          format = "tilemap",
        },
        palette = {
          key = "battle-scene/general-grass-day/background/palette",
          path = "data/generated/battle/scenes/general-grass-day.bg3.palette.lua",
          format = "rgb888",
        },
      },
    },
    imagePath = BattlePresentationCache.sceneImagePath(sceneKey),
    introLayer = {
      image = BattlePresentationCache.sceneIntroImagePath(sceneKey),
      width = 512,
      height = 256,
    },
    paletteSource = {
      key = "battle-scene/" .. sceneKey:gsub("/", "-") .. "/native-palettes",
      path = BattlePresentationCache.scenePaletteSourcePath(sceneKey),
      format = "native-encounter-palettes-v1",
    },
    terrainSprites = {
      player = {
        image = BattlePresentationCache.sceneTerrainSpritePath(sceneKey, "player"),
        width = 80,
        height = 80,
        origin = { x = -40, y = -40 },
        sourceIndices = {
          path = BattlePresentationCache.sceneTerrainSourceIndexPath(sceneKey, "player"),
          format = "source-index-rgba8",
          plane = "mainObj",
          width = 80,
          height = 80,
        },
      },
      foe = {
        image = BattlePresentationCache.sceneTerrainSpritePath(sceneKey, "foe"),
        width = 80,
        height = 80,
        origin = { x = -40, y = -40 },
        sourceIndices = {
          path = BattlePresentationCache.sceneTerrainSourceIndexPath(sceneKey, "foe"),
          format = "source-index-rgba8",
          plane = "mainObj",
          width = 80,
          height = 80,
        },
      },
    },
    encounterParticles = ParticlesFixture.sets(sceneKey),
  }
  cache:writeLua(BattlePresentationCache.scenePath(sceneKey), record)
  cache:write(BattlePresentationCache.sceneMarkerPath(sceneKey), "marker")
  cache:write(BattlePresentationCache.sceneCharactersPath(sceneKey), string.rep("\0", 65536))
  cache:write(BattlePresentationCache.sceneIntroCharactersPath(sceneKey), string.rep("\0", 65536))
  local entries = {}
  for index = 1, 2048 do
    entries[index] = { tile = 0, flipH = false, flipV = false, palette = 0 }
  end
  cache:writeLua(BattlePresentationCache.sceneMapPath(sceneKey), { width = 512, height = 256, entries = entries })
  local colors = {}
  for index = 1, 256 do
    colors[index] = { r = 0, g = 0, b = 0 }
  end
  cache:writeLua(BattlePresentationCache.scenePalettePath(sceneKey), { colors = colors })
  local function paletteWords()
    local words = {}
    for index = 1, 16 do
      words[index] = 0
    end
    return words
  end
  cache:writeLua(BattlePresentationCache.scenePaletteSourcePath(sceneKey), {
    mainObjSources = {
      hud = { firstSlot = 0, words = paletteWords() },
      hudAuxiliary = { firstSlot = 16, words = paletteWords() },
      terrain = { firstSlot = 32, words = paletteWords() },
    },
  })
  stagePng(cache, BattlePresentationCache.sceneImagePath(sceneKey), 512, 256)
  stagePng(cache, BattlePresentationCache.sceneIntroImagePath(sceneKey), 512, 256)
  stagePng(cache, BattlePresentationCache.sceneTerrainSpritePath(sceneKey, "player"), 80, 80)
  stagePng(cache, BattlePresentationCache.sceneTerrainSpritePath(sceneKey, "foe"), 80, 80)
  for _, side in ipairs({ "player", "foe" }) do
    cache:write(
      BattlePresentationCache.sceneTerrainSourceIndexPath(sceneKey, side),
      string.rep(string.char(32, 0, 0, 255), 80 * 80)
    )
  end
  for _, set in ipairs(record.encounterParticles) do
    for _, texture in ipairs(set.textures) do
      stagePng(cache, texture.image, texture.width, texture.height)
    end
  end
end

function T.separate_menu_patch_source_maps_are_part_of_global_readiness()
  local manifest = ManifestFixture.manifest()
  local function sourceIndices(name)
    return {
      path = "assets/generated/battle/" .. name .. ".source-index.rgba8",
      format = "source-index-rgba8",
      plane = "subBg",
      width = 8,
      height = 8,
    }
  end
  local command = manifest.menus.command.screens[1]
  command.feedback = {
    fight = {
      pressed = {
        image = command.image,
        x = 0,
        y = 0,
        width = 8,
        height = 8,
        sourceIndices = sourceIndices("feedback-pressed"),
      },
    },
  }
  local moves = manifest.menus.moves.screens[1]
  moves.moveButtons = {}
  for slot = 1, 4 do
    moves.moveButtons[slot] = {
      x = 0,
      y = 0,
      width = 8,
      height = 8,
      empty = moves.image,
      types = { NORMAL = { normal = moves.image, pressed = moves.image } },
      sourceIndices = {
        empty = sourceIndices("move-" .. slot .. "-empty"),
        types = {
          NORMAL = {
            normal = sourceIndices("move-" .. slot .. "-normal"),
            pressed = sourceIndices("move-" .. slot .. "-pressed"),
          },
        },
      },
    }
  end
  local cache = staging()
  stageBattle(cache, manifest, "general/grass/day")
  Assert.isTrue(BattlePresentationCache.isGlobalReady(cache, "marker"), "all patch maps complete the global closure")

  local missingFeedback = command.feedback.fight.pressed.sourceIndices.path
  cache:remove(missingFeedback)
  Assert.isFalse(
    BattlePresentationCache.isGlobalReady(cache, "marker"),
    "missing feedback map rejects global readiness"
  )
  cache:write(missingFeedback, string.rep(string.char(0, 0, 0, 0), 64))

  local missingMoveButton = moves.moveButtons[1].sourceIndices.types.NORMAL.pressed.path
  cache:remove(missingMoveButton)
  Assert.isFalse(
    BattlePresentationCache.isGlobalReady(cache, "marker"),
    "missing move-button map rejects global readiness"
  )
end

function T.unbaked_intro_characters_are_part_of_the_scene_readiness_closure()
  local sceneKey = "general/grass/day"
  local cache = staging()
  stageBattle(cache, validManifest(), sceneKey)
  Assert.isTrue(BattlePresentationCache.isSceneReady(cache, sceneKey, "marker"), "a complete scene reads ready")
  local staged = assert(
    cache:read(BattlePresentationCache.sceneIntroCharactersPath(sceneKey)),
    "the unbaked intro characters are staged"
  )
  Assert.equal(#staged, 65536, "the unbaked intro characters carry complete 8bpp tiles")
  cache:write(BattlePresentationCache.sceneIntroCharactersPath(sceneKey), "truncated")
  Assert.isFalse(
    BattlePresentationCache.isSceneReady(cache, sceneKey, "marker"),
    "truncated intro characters never read as ready"
  )
  cache:remove(BattlePresentationCache.sceneIntroCharactersPath(sceneKey))
  Assert.isFalse(
    BattlePresentationCache.isSceneReady(cache, sceneKey, "marker"),
    "missing intro characters never read as ready"
  )
  cache:write(BattlePresentationCache.sceneIntroCharactersPath(sceneKey), staged)
  Assert.isTrue(BattlePresentationCache.isSceneReady(cache, sceneKey, "marker"), "restored intro characters read ready")
end

function T.encounter_particle_textures_are_part_of_the_scene_readiness_closure()
  Assert.equal(
    BattlePresentationCache.sceneParticleTexturePath("general/grass/day", 2, 3),
    "assets/generated/battle/scenes/general-grass-day-particles-2-3.png",
    "particle textures have set- and id-specific scene paths"
  )
  local sceneKey = "general/grass/day"
  local cache = staging()
  stageBattle(cache, validManifest(), sceneKey)
  Assert.isTrue(BattlePresentationCache.isSceneReady(cache, sceneKey, "marker"), "a complete scene reads ready")
  local second = ParticlesFixture.sets(sceneKey)[2].textures[2]
  local staged = assert(cache:read(second.image), "the particle texture is staged")

  cache:write(second.image, "truncated")
  Assert.isFalse(
    BattlePresentationCache.isSceneReady(cache, sceneKey, "marker"),
    "a corrupt particle texture never reads as ready"
  )
  stagePng(cache, second.image, second.width + 1, second.height)
  Assert.isFalse(
    BattlePresentationCache.isSceneReady(cache, sceneKey, "marker"),
    "a wrongly sized particle texture never reads as ready"
  )
  cache:write(second.image, staged)
  Assert.isTrue(BattlePresentationCache.isSceneReady(cache, sceneKey, "marker"), "a restored texture reads ready")
  cache:remove(second.image)
  Assert.isFalse(
    BattlePresentationCache.isSceneReady(cache, sceneKey, "marker"),
    "a missing particle texture never reads as ready"
  )
end

function T.battle_ball_frames_are_part_of_the_exact_readiness_closure()
  local manifest = ManifestFixture.coreManifest()
  local selector = "ball:POKE_BALL"
  local portraitSelector = MonCache.portraitSelector("CHIKORITA", 0, "male", false)
  local demand = assert(
    BattlePresentationCache.requirements(
      manifest,
      { background = "general", terrain = "grass", time = "day" },
      { portraitSelector },
      nil,
      {},
      { selector }
    )
  )
  Assert.deepEqual(demand.battleBalls, { selector }, "the exact ball selector reaches the launch demand")
  local leaf = ManifestFixture.ballRecord(selector)
  local cache = staging()
  stageBattle(cache, manifest, "general/grass/day")
  stageMonPage(cache, portraitSelector)
  cache:writeLua(BattlePresentationCache.ballPath(selector), leaf)
  stagePng(cache, leaf.entry.frames[1].image, 16, 16)
  stageSourceIndices(cache, leaf.entry.frames[1].sourceIndices)
  cache:write(BattlePresentationCache.ballMarkerPath(selector), "marker")
  Assert.isTrue(BattlePresentationCache.isReady(cache, demand), "every requested frame is staged")
  cache:write(leaf.entry.frames[1].image, "truncated")
  Assert.isFalse(BattlePresentationCache.isReady(cache, demand), "a broken requested frame is never ready")
end

function T.trainer_picture_frames_are_part_of_the_exact_readiness_closure()
  local manifest = ManifestFixture.coreManifest()
  local selector = "back:PKMN_TRAINER_ETHAN"
  local leafPrefix = "assets/generated/battle/trainer-pictures/back-PKMN_TRAINER_ETHAN"
  local image0 = leafPrefix .. "-0.png"
  local image1 = leafPrefix .. "-1.png"
  local sequenceImage = leafPrefix .. "-sequence-1-frame-0.png"
  local frames = {
    {
      drawableKey = "trainer:" .. selector,
      image = image0,
      sourceIndices = {
        format = "source-index-rgba8",
        plane = "mainObj",
        width = 8,
        height = 8,
        variants = {
          ["slot:80"] = {
            path = "assets/generated/battle/trainer-back-PKMN_TRAINER_ETHAN-source-frame-0-slot-80.rgba8",
            firstSlot = 80,
          },
        },
      },
      rasterOffset = { x = -40, y = -40 },
      durationTicks = 2,
      sourceFrame = 0,
      userAttr = 0,
    },
    {
      drawableKey = "trainer:" .. selector .. ":frame:1",
      image = image1,
      sourceIndices = {
        format = "source-index-rgba8",
        plane = "mainObj",
        width = 8,
        height = 8,
        variants = {
          ["slot:80"] = {
            path = "assets/generated/battle/trainer-back-PKMN_TRAINER_ETHAN-source-frame-1-slot-80.rgba8",
            firstSlot = 80,
          },
        },
      },
      rasterOffset = { x = -24, y = -40 },
      durationTicks = 5,
      sourceFrame = 1,
      userAttr = 0,
    },
  }
  local leaf = {
    schema = "g4-battle-trainer-picture-v1",
    selector = selector,
    catalogIdentity = manifest.catalogIdentity,
    entry = {
      drawableKey = "trainer:" .. selector,
      image = image0,
      width = 8,
      height = 8,
      rasterOffset = { x = -40, y = -40 },
      paletteSource = { words = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 } },
      animation = {
        sourceSequence = 0,
        playMode = "forward_loop",
        loopStartFrameIdx = 0,
        frames = frames,
        sequences = {
          { sourceSequence = 0, playMode = "forward_loop", loopStartFrameIdx = 0, frames = frames },
          {
            sourceSequence = 1,
            playMode = "forward",
            loopStartFrameIdx = 0,
            frames = {
              {
                drawableKey = "trainer:" .. selector .. ":sequence:1:frame:0",
                image = sequenceImage,
                sourceIndices = {
                  format = "source-index-rgba8",
                  plane = "mainObj",
                  width = 8,
                  height = 8,
                  variants = {
                    ["slot:80"] = {
                      path = "assets/generated/battle/trainer-back-PKMN_TRAINER_ETHAN-sequence-1-slot-80.rgba8",
                      firstSlot = 80,
                    },
                  },
                },
                rasterOffset = { x = -40, y = -40 },
                durationTicks = 3,
                sourceFrame = 0,
                userAttr = 1,
              },
            },
          },
        },
      },
      throwOffsets = {
        { x = 0, y = 128 },
        { x = -34, y = 4 },
        { x = -28, y = -11 },
        { x = 50, y = -12 },
        { x = 32767, y = 32767 },
        { x = 32767, y = 32767 },
      },
    },
  }
  local demand = assert(
    BattlePresentationCache.requirements(
      manifest,
      { background = "general", terrain = "grass", time = "day" },
      { MonCache.portraitSelector("CHIKORITA", 0, "male", false) },
      nil,
      { selector },
      {}
    )
  )
  Assert.deepEqual(demand.trainerPictures, { selector }, "only the requested trainer class reaches the launch demand")
  local cache = staging()
  stageBattle(cache, manifest, "general/grass/day")
  stageMonPage(cache, MonCache.portraitSelector("CHIKORITA", 0, "male", false))
  cache:writeLua(BattlePresentationCache.trainerPicturePath(selector), leaf)
  stagePng(cache, image0, 8, 8)
  stagePng(cache, image1, 8, 8)
  stagePng(cache, sequenceImage, 8, 8)
  for _, sequence in ipairs(leaf.entry.animation.sequences) do
    for _, frame in ipairs(sequence.frames) do
      stageSourceIndices(cache, frame.sourceIndices)
    end
  end
  cache:write(BattlePresentationCache.trainerPictureMarkerPath(selector), "marker")
  Assert.isTrue(BattlePresentationCache.isReady(cache, demand), "both source frames are staged for the requested class")
  local stagedEntry = assert(BattlePresentationCache.loadTrainerPicture(cache, selector))
  Assert.deepEqual(
    stagedEntry.entry.animation.sequences,
    leaf.entry.animation.sequences,
    "the staged trainer metadata retains every selected source sequence"
  )
  Assert.deepEqual(
    stagedEntry.entry.throwOffsets,
    leaf.entry.throwOffsets,
    "the staged trainer metadata retains all six source throw anchors"
  )
  Assert.deepEqual(
    stagedEntry.entry.throwOffsets[5],
    { x = 32767, y = 32767 },
    "the first no-ball sentinel survives staging"
  )
  Assert.deepEqual(
    stagedEntry.entry.throwOffsets[6],
    { x = 32767, y = 32767 },
    "the final no-ball sentinel survives staging"
  )
  cache:remove(sequenceImage)
  Assert.isFalse(BattlePresentationCache.isReady(cache, demand), "a missing throw sequence frame prevents readiness")
  stagePng(cache, sequenceImage, 8, 8)
  cache:remove(image1)
  Assert.isFalse(BattlePresentationCache.isReady(cache, demand), "a missing non-first trainer frame prevents readiness")
end

function T.fully_staged_demands_read_ready_and_breakages_do_not()
  local selector = MonCache.portraitSelector("CHIKORITA", 0, "male", false, "back")
  local manifest = ManifestFixture.coreManifest()
  local valid, validationErr = BattlePresentationSchema.isValidManifest(manifest)
  Assert.isTrue(valid, "the staged manifest is schema-valid: " .. tostring(validationErr))
  local cache = staging()
  stageBattle(cache, manifest, "general/grass/day")
  stageMonPage(cache, selector)
  local demand = assert(
    BattlePresentationCache.requirements(
      manifest,
      { background = "general", terrain = "grass", time = "day" },
      { selector },
      nil,
      {},
      {}
    )
  )
  Assert.isTrue(BattlePresentationCache.isReady(cache, demand), "a fully staged demand reads ready")
  local stagedScene = assert(
    cache:read(BattlePresentationCache.sceneImagePath("general/grass/day")),
    "the staged scene image is available"
  )
  cache:write(BattlePresentationCache.sceneImagePath("general/grass/day"), "truncated")
  Assert.isFalse(BattlePresentationCache.isReady(cache, demand), "a corrupted scene image never reads as ready")
  cache:write(BattlePresentationCache.sceneImagePath("general/grass/day"), stagedScene:sub(1, 33))
  Assert.isFalse(BattlePresentationCache.isReady(cache, demand), "a header-only scene image never reads as ready")
  Assert.isFalse(
    BattlePresentationCache.isSceneReady(cache, "general/grass/day", "marker"),
    "a header-only scene audit never reads as ready"
  )
  cache:write(BattlePresentationCache.sceneImagePath("general/grass/day"), stagedScene:sub(1, #stagedScene - 12))
  Assert.isFalse(
    BattlePresentationCache.isReady(cache, demand),
    "a scene image without its terminal marker never reads as ready"
  )
  Assert.isFalse(
    BattlePresentationCache.isSceneReady(cache, "general/grass/day", "marker"),
    "a scene audit without its terminal marker never reads as ready"
  )
  cache:write(
    BattlePresentationCache.sceneImagePath("general/grass/day"),
    PngWriter.encode(256, 128, string.rep("\1\2\3\255", 256 * 128))
  )
  Assert.isFalse(BattlePresentationCache.isReady(cache, demand), "a wrongly sized scene image never reads as ready")
  cache:write(BattlePresentationCache.sceneImagePath("general/grass/day"), stagedScene)
  Assert.isTrue(BattlePresentationCache.isReady(cache, demand), "a restored complete scene reads ready again")
  stageBattle(cache, manifest, "general/grass/day")
  cache:writeLua(BattlePresentationCache.sceneMapPath("general/grass/day"), {
    width = 512,
    height = 256,
    entries = {},
  })
  Assert.isFalse(
    BattlePresentationCache.isReady(cache, demand),
    "a scene with its native BG3 map missing never reads as ready"
  )
end

function T.missing_scenes_fail_closed_naming_the_requested_key()
  local cache = staging()
  local missing, missingErr = BattlePresentationCache.loadScene(cache, "general/grass/night")
  Assert.isNil(missing, "an unstaged scene never resolves")
  Assert.isTrue(
    type(missingErr) == "string" and missingErr:find("general/grass/night", 1, true) ~= nil,
    "the missing scene names its requested key: " .. tostring(missingErr)
  )
  Assert.isTrue(
    missingErr:find("general-grass-night", 1, true) ~= nil,
    "the missing scene preserves its file identity: " .. tostring(missingErr)
  )
  local corrupt, corruptErr = BattlePresentationCache.loadScene(cache, "not-a-scene")
  Assert.isNil(corrupt, "a corrupt scene key never resolves")
  Assert.isTrue(
    type(corruptErr) == "string" and corruptErr:find("not-a-scene", 1, true) ~= nil,
    "the corrupt key fails with context: " .. tostring(corruptErr)
  )
end

function T.delayed_pages_keep_readiness_pending()
  local selector = MonCache.portraitSelector("CHIKORITA", 0, "male", false, "back")
  local manifest = ManifestFixture.coreManifest()
  local cache = staging()
  stageBattle(cache, manifest, "general/grass/day")
  local demand = assert(
    BattlePresentationCache.requirements(
      manifest,
      { background = "general", terrain = "grass", time = "day" },
      { selector },
      nil,
      {},
      {}
    )
  )
  Assert.isFalse(BattlePresentationCache.isReady(cache, demand), "a delayed portrait page stays pending")
end

-- One trainer picture, one ball, and the evolution bundle stage and read
-- through their own versioned paths: exact selectors publish standalone
-- records under marker-last receipts, malformed selectors fail before any
-- path exists, and a missing leaf never fabricates a record. An
-- incomplete replacement never reads ready while the previously staged
-- image stays on disk.
function T.selective_leaf_records_stage_and_read_by_exact_selector()
  Assert.isTrue(
    type(BattlePresentationCache.trainerPicturePath) == "function",
    "trainer pictures have their own contract path"
  )
  Assert.isTrue(
    type(BattlePresentationCache.trainerPictureMarkerPath) == "function",
    "trainer pictures have their own marker path"
  )
  Assert.isTrue(
    type(BattlePresentationCache.loadTrainerPicture) == "function",
    "trainer pictures load without the global manifest"
  )
  Assert.isTrue(
    type(BattlePresentationCache.isTrainerPictureReady) == "function",
    "trainer pictures carry their own readiness"
  )
  Assert.isTrue(type(BattlePresentationCache.ballPath) == "function", "balls have their own contract path")
  Assert.isTrue(type(BattlePresentationCache.ballMarkerPath) == "function", "balls have their own marker path")
  Assert.isTrue(type(BattlePresentationCache.loadBall) == "function", "balls load without the global manifest")
  Assert.isTrue(type(BattlePresentationCache.isBallReady) == "function", "balls carry their own readiness")
  Assert.isTrue(type(BattlePresentationCache.evolutionPath) == "function", "evolution has its own contract path")
  Assert.isTrue(type(BattlePresentationCache.evolutionMarkerPath) == "function", "evolution has its own marker path")
  Assert.isTrue(
    type(BattlePresentationCache.loadEvolution) == "function",
    "evolution loads without the global manifest"
  )
  Assert.isTrue(type(BattlePresentationCache.isEvolutionReady) == "function", "evolution carries its own readiness")
  Assert.equal(
    BattlePresentationCache.trainerPicturePath("front:YOUNGSTER"),
    "data/generated/battle/trainer-pictures/front-YOUNGSTER.lua",
    "a front picture record lives under its safe class key"
  )
  Assert.equal(
    BattlePresentationCache.trainerPictureMarkerPath("front:YOUNGSTER"),
    "data/generated/battle/trainer-pictures/front-YOUNGSTER.complete",
    "a front picture marker lives beside its record"
  )
  Assert.equal(
    BattlePresentationCache.trainerPicturePath("back:PKMN_TRAINER_ETHAN"),
    "data/generated/battle/trainer-pictures/back-PKMN_TRAINER_ETHAN.lua",
    "a back picture record keeps its safe class key"
  )
  Assert.equal(
    BattlePresentationCache.ballPath("ball:POKE_BALL"),
    "data/generated/battle/balls/POKE_BALL.lua",
    "a ball record lives under its safe item key"
  )
  Assert.equal(
    BattlePresentationCache.ballMarkerPath("ball:POKE_BALL"),
    "data/generated/battle/balls/POKE_BALL.complete",
    "a ball marker lives beside its record"
  )
  Assert.equal(
    BattlePresentationCache.evolutionPath(),
    "data/generated/battle/evolution/presentation.lua",
    "evolution stays one bundle record"
  )
  Assert.equal(
    BattlePresentationCache.evolutionMarkerPath(),
    "data/generated/battle/evolution/presentation.complete",
    "the evolution marker lives beside its record"
  )
  local cache = staging()
  Assert.isNil(
    BattlePresentationCache.loadTrainerPicture(cache, "front:YOUNGSTER"),
    "an unstaged trainer picture never resolves"
  )
  local missingBall, missingBallErr = BattlePresentationCache.loadBall(cache, "ball:POKE_BALL")
  Assert.isNil(missingBall, "an unstaged ball never resolves")
  Assert.isTrue(type(missingBallErr) == "string", "the missing ball names its failure: " .. tostring(missingBallErr))
  Assert.isNil(BattlePresentationCache.loadEvolution(cache), "unstaged evolution never resolves")
  Assert.isFalse(
    BattlePresentationCache.isTrainerPictureReady(cache, "front:YOUNGSTER", "leaf-marker"),
    "an unstaged trainer picture is never ready"
  )
  Assert.isFalse(
    BattlePresentationCache.isBallReady(cache, "ball:POKE_BALL", "leaf-marker"),
    "an unstaged ball is never ready"
  )
  Assert.isFalse(BattlePresentationCache.isEvolutionReady(cache, "leaf-marker"), "unstaged evolution is never ready")
  for _, badSelector in ipairs({ "", "YOUNGSTER", "front:lower!", "front:../evil", "ball:POKE_BALL", 7 }) do
    Assert.isFalse(
      pcall(BattlePresentationCache.trainerPicturePath, badSelector),
      "a malformed trainer selector never reaches a path: " .. tostring(badSelector)
    )
  end
  for _, badSelector in ipairs({ "", "POKE_BALL", "ball:lower!", "ball:a/b", "front:YOUNGSTER", 7 }) do
    Assert.isFalse(
      pcall(BattlePresentationCache.ballPath, badSelector),
      "a malformed ball selector never reaches a path: " .. tostring(badSelector)
    )
  end
  local badTrainer, badTrainerErr = BattlePresentationCache.loadTrainerPicture(cache, "front:lower!")
  Assert.isNil(badTrainer, "a malformed trainer selector never loads")
  Assert.isTrue(
    type(badTrainerErr) == "string" and badTrainerErr:find("front:lower!", 1, true) ~= nil,
    "the malformed trainer selector names itself: " .. tostring(badTrainerErr)
  )
  -- Leaf catalog identity matches the staged shared core.
  local core = ManifestFixture.manifest()
  cache:writeLua(BattlePresentationCache.manifestPath(), core)
  cache:write(BattlePresentationCache.markerPath(), "core-marker")
  -- Leaf records stage through their exact builders: the shared core no
  -- longer carries a trainer inventory to copy entries from.
  local trainerRecord = ManifestFixture.trainerPictureRecord("front:YOUNGSTER")
  Assert.equal(
    trainerRecord.catalogIdentity,
    core.catalogIdentity,
    "the staged trainer leaf belongs to the staged core generation"
  )
  local trainerEntry = trainerRecord.entry
  cache:writeLua(BattlePresentationCache.trainerPicturePath("front:YOUNGSTER"), trainerRecord)
  local trainerImages = {}
  local function leafTrainerImage(image)
    if trainerImages[image] == nil then
      trainerImages[image] = image
    end
    return trainerImages[image]
  end
  leafTrainerImage(trainerEntry.image)
  for _, frame in ipairs(trainerEntry.animation.frames) do
    leafTrainerImage(frame.image)
    stageSourceIndices(cache, frame.sourceIndices)
  end
  for _, sequence in ipairs(trainerEntry.animation.sequences) do
    for _, frame in ipairs(sequence.frames) do
      leafTrainerImage(frame.image)
      stageSourceIndices(cache, frame.sourceIndices)
    end
  end
  for _, image in pairs(trainerImages) do
    stagePng(cache, image, trainerEntry.width, trainerEntry.height)
  end
  cache:write(BattlePresentationCache.trainerPictureMarkerPath("front:YOUNGSTER"), "leaf-marker")
  local staged, stagedErr = BattlePresentationCache.loadTrainerPicture(cache, "front:YOUNGSTER")
  Assert.isNil(stagedErr, "the staged trainer picture loads cleanly: " .. tostring(stagedErr))
  Assert.equal(assert(staged).selector, "front:YOUNGSTER", "the loaded record names its exact selector")
  Assert.equal(
    staged.entry.drawableKey,
    "trainer:front:YOUNGSTER",
    "the loaded record keeps its semantic drawable identity"
  )
  Assert.isTrue(
    BattlePresentationCache.isTrainerPictureReady(cache, "front:YOUNGSTER", "leaf-marker"),
    "the staged trainer picture and its marker establish readiness"
  )
  Assert.isFalse(
    BattlePresentationCache.isTrainerPictureReady(cache, "front:YOUNGSTER", "stale-marker"),
    "a stale marker never proves the trainer picture"
  )
  Assert.isNil(BattlePresentationCache.loadBall(cache, "ball:POKE_BALL"), "staging a trainer picture stages no ball")
  Assert.isFalse(
    BattlePresentationCache.isBallReady(cache, "ball:POKE_BALL", "leaf-marker"),
    "staging a trainer picture never readies a ball"
  )
  cache:write(BattlePresentationCache.trainerPicturePath("front:YOUNGSTER"), "truncated")
  Assert.isFalse(
    BattlePresentationCache.isTrainerPictureReady(cache, "front:YOUNGSTER", "leaf-marker"),
    "a corrupt trainer record never reads as ready"
  )
  cache:writeLua(BattlePresentationCache.trainerPicturePath("front:YOUNGSTER"), trainerRecord)
  Assert.isTrue(
    BattlePresentationCache.isTrainerPictureReady(cache, "front:YOUNGSTER", "leaf-marker"),
    "a restored trainer record reads ready again"
  )
  for _, image in pairs(trainerImages) do
    cache:remove(image)
  end
  Assert.isFalse(
    BattlePresentationCache.isTrainerPictureReady(cache, "front:YOUNGSTER", "leaf-marker"),
    "a missing trainer frame prevents readiness"
  )
  for _, image in pairs(trainerImages) do
    stagePng(cache, image, trainerEntry.width, trainerEntry.height)
  end
  local ballRecord = ManifestFixture.ballRecord("ball:POKE_BALL")
  Assert.equal(
    ballRecord.catalogIdentity,
    core.catalogIdentity,
    "the staged ball leaf belongs to the staged core generation"
  )
  local ballEntry = ballRecord.entry
  local ballImage = ballEntry.frames[1].image
  cache:writeLua(BattlePresentationCache.ballPath("ball:POKE_BALL"), ballRecord)
  stagePng(cache, ballImage, ballEntry.frames[1].width, ballEntry.frames[1].height)
  stageSourceIndices(cache, ballEntry.frames[1].sourceIndices)
  cache:write(BattlePresentationCache.ballMarkerPath("ball:POKE_BALL"), "leaf-marker")
  Assert.isTrue(
    BattlePresentationCache.isBallReady(cache, "ball:POKE_BALL", "leaf-marker"),
    "the staged ball and its marker establish readiness"
  )
  -- A later replacement that fails before its image and marker are
  -- complete never reads ready, while the previously staged image
  -- stays on disk.
  local replacementImage = "assets/generated/battle/balls/POKE_BALL-1.png"
  local replacement = {
    schema = "g4-battle-ball-v1",
    selector = "ball:POKE_BALL",
    catalogIdentity = core.catalogIdentity,
    entry = {
      fadeColor = ballEntry.fadeColor,
      paletteSource = ballEntry.paletteSource,
      frames = {
        {
          drawableKey = ballEntry.frames[1].drawableKey,
          image = replacementImage,
          width = ballEntry.frames[1].width,
          height = ballEntry.frames[1].height,
          sourceIndices = ballEntry.frames[1].sourceIndices,
        },
      },
    },
  }
  cache:writeLua(BattlePresentationCache.ballPath("ball:POKE_BALL"), replacement)
  Assert.isFalse(
    BattlePresentationCache.isBallReady(cache, "ball:POKE_BALL", "leaf-marker"),
    "a replacement without its staged image never reads as ready"
  )
  Assert.notNil(cache:read(ballImage), "the failed replacement preserves the previously staged ball image")
  stagePng(cache, replacementImage, ballEntry.frames[1].width, ballEntry.frames[1].height)
  Assert.isTrue(
    BattlePresentationCache.isBallReady(cache, "ball:POKE_BALL", "leaf-marker"),
    "completing the replacement image restores readiness"
  )
  local loadedBall = assert(BattlePresentationCache.loadBall(cache, "ball:POKE_BALL"))
  Assert.equal(loadedBall.entry.frames[1].image, replacementImage, "the loaded ball names its exact published frame")
  Assert.isTrue(
    BattlePresentationCache.isTrainerPictureReady(cache, "front:YOUNGSTER", "leaf-marker"),
    "staging a ball never disturbs the trainer picture"
  )
  local stagedEvolution = ManifestFixture.evolutionRecord()
  Assert.equal(
    stagedEvolution.catalogIdentity,
    core.catalogIdentity,
    "the staged evolution leaf belongs to the staged core generation"
  )
  local evolutionRecord = stagedEvolution
  cache:writeLua(BattlePresentationCache.evolutionPath(), evolutionRecord)
  for _, texture in ipairs(evolutionRecord.particles.textures) do
    stagePng(cache, texture.image, texture.width, texture.height)
  end
  for _, layer in ipairs({ "main", "sub", "menu" }) do
    local image = evolutionRecord.graphics[layer]
    stagePng(cache, image.image, image.width, image.height)
  end
  for _, animationRole in ipairs({ "idle", "select" }) do
    for _, frame in ipairs(evolutionRecord.graphics.cursor.animations[animationRole].frames) do
      stagePng(cache, frame.image, frame.width, frame.height)
    end
  end
  cache:write(BattlePresentationCache.evolutionMarkerPath(), "leaf-marker")
  local evolution, evolutionErr = BattlePresentationCache.loadEvolution(cache)
  Assert.isNil(evolutionErr, "the staged evolution bundle loads cleanly: " .. tostring(evolutionErr))
  Assert.equal(assert(evolution).kind, "evolution", "the loaded evolution record names its bundle kind")
  Assert.equal(
    evolution.particles.seed,
    stagedEvolution.particles.seed,
    "the loaded evolution keeps its complete particle set"
  )
  Assert.isTrue(
    BattlePresentationCache.isEvolutionReady(cache, "leaf-marker"),
    "the staged evolution screens and its marker establish readiness"
  )
  cache:remove(evolutionRecord.graphics.cursor.animations.select.frames[1].image)
  Assert.isFalse(
    BattlePresentationCache.isEvolutionReady(cache, "leaf-marker"),
    "a missing evolution cursor frame prevents readiness"
  )
end

return { tests = T }
