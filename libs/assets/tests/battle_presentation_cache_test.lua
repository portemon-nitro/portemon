-- Battle presentation cache boundary without a dump: canonical paths,
-- the scene inventory, exact deterministic demands, and truthful
-- readiness over staged files. Staged fixtures are synthetic; the ROM
-- suite proves the compiler stages the same shapes.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local BattlePresentationSchema = require("libs.assets.src.battle.BattlePresentationSchema")
local MonCache = require("libs.assets.src.MonCache")
local PngWriter = require("libs.assets.src.PngWriter")

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
    BattlePresentationCache.sceneMarkerPath("general/grass/day"),
    "data/generated/battle/scenes/general-grass-day.complete",
    "scene markers live beside the scene record"
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
      nil
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
  local first = assert(BattlePresentationCache.requirements(manifest, context, selectors, nil))
  local second = assert(BattlePresentationCache.requirements(manifest, context, selectors, nil))
  Assert.deepEqual(first, second, "demands are deterministic")
  Assert.deepEqual(first.scenes, { "general/grass/day" }, "one battle demands exactly one scene")
  Assert.deepEqual(
    first.pages,
    {
      "CHIKORITA/f0/male/plain/back",
      "TOTODILE/f0/male/plain",
    },
    "portrait selectors deduplicate and sort"
  )
  local unknown, err = BattlePresentationCache.requirements(
    manifest,
    { background = "effect", terrain = "flash", time = "day" },
    selectors,
    nil
  )
  Assert.isNil(unknown, "an effect background never yields a demand")
  Assert.notNil(err, "the rejected context explains itself")
end

local function validManifest()
  local images = {
    ["assets/generated/battle/menu-command-1.png"] = { width = 8, height = 8 },
    ["assets/generated/battle/scene-test.png"] = { width = 8, height = 8 },
  }
  local function sprite(image)
    return {
      image = image,
      cells = {
        {
          objs = {
            {
              x = 0,
              y = 0,
              tile = 0,
              flipH = false,
              flipV = false,
              palette = 0,
              shape = 0,
              size = 0,
              width = 8,
              height = 8,
              affine = false,
              disabled = false,
              objMode = "normal",
              mosaic = false,
              colorMode = "16-color",
              priority = 0,
            },
          },
        },
      },
      animation = { playMode = "forward", loopStartFrameIdx = 0, frames = { { cell = 0, duration = 4 } } },
      palette = { colors = { { r = 1, g = 2, b = 3 } } },
    }
  end
  local function menu(image)
    return {
      image = image,
      screens = { { image = image, width = 8, height = 8 } },
    }
  end
  local command = menu("assets/generated/battle/menu-command-1.png")
  return {
    schema = "g4-battle-presentation-v1",
    version = { id = "heartgold", language = "en" },
    verified = true,
    scenes = { { key = "general/grass/day", background = "general", terrain = "grass", time = "day" } },
    images = images,
    command = command,
    moves = command,
    target = command,
    twoOption = command,
    lower = {
      image = "assets/generated/battle/menu-command-1.png",
      palette = { colors = { { r = 1, g = 2, b = 3 } } },
      variants = {
        general = {
          base = { colors = { { r = 1, g = 2, b = 3 } } },
          touch = { colors = { { r = 1, g = 2, b = 3 } } },
        },
      },
    },
    playerHud = sprite("assets/generated/battle/menu-command-1.png"),
    enemyHud = sprite("assets/generated/battle/menu-command-1.png"),
    arrow = sprite("assets/generated/battle/menu-command-1.png"),
    partyGauges = {
      sprite("assets/generated/battle/menu-command-1.png"),
      sprite("assets/generated/battle/menu-command-1.png"),
    },
    terrain = {
      type0 = { cells = sprite("assets/generated/battle/menu-command-1.png").cells, animation = sprite("assets/generated/battle/menu-command-1.png").animation },
      type1 = { cells = sprite("assets/generated/battle/menu-command-1.png").cells, animation = sprite("assets/generated/battle/menu-command-1.png").animation },
    },
    textRoles = {
      narration = { font = "font-0", sourceFontId = 1 },
      menu = { font = "font-0" },
      hud = { font = "font-0" },
    },
    audioRoles = {
      wild = "SEQ_GS_VS_NORAPOKE",
      trainer = "SEQ_GS_VS_TRAINER",
      rival = "SEQ_GS_VS_RIVAL",
      select = "SEQ_SE_DP_SELECT",
      narrationBank = 197,
      cries = "species",
    },
  }
end

local function stagePng(cache, path, width, height)
  local pixels = string.rep("\1\2\3\255", width * height)
  cache:write(path, PngWriter.encode(width, height, pixels))
end

-- Minimal hand-built PNG envelope: the mon page validator checks
-- structure, never CRCs, so the fixture carries a real-headed envelope
-- without a pixel payload.
local function envelopePng()
  local function u32(v)
    return string.char(
      math.floor(v / 16777216) % 256,
      math.floor(v / 65536) % 256,
      math.floor(v / 256) % 256,
      v % 256
    )
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

local function stageBattle(cache, manifest, sceneKey)
  cache:writeLua(BattlePresentationCache.manifestPath(), manifest)
  cache:write(BattlePresentationCache.markerPath(), "marker")
  for path, geometry in pairs(manifest.images) do
    stagePng(cache, path, geometry.width, geometry.height)
  end
  local record = {
    schema = "g4-battle-scene-v1",
    key = sceneKey,
    background = "general",
    terrain = "grass",
    time = "day",
    canvasWidth = 8,
    canvasHeight = 8,
    viewport = { x = 0, y = 0, width = 8, height = 8 },
    imagePath = BattlePresentationCache.sceneImagePath(sceneKey),
  }
  cache:writeLua(BattlePresentationCache.scenePath(sceneKey), record)
  cache:write(BattlePresentationCache.sceneMarkerPath(sceneKey), "marker")
  stagePng(cache, BattlePresentationCache.sceneImagePath(sceneKey), 8, 8)
end

function T.fully_staged_demands_read_ready_and_breakages_do_not()
  local selector = MonCache.portraitSelector("CHIKORITA", 0, "male", false, "back")
  local manifest = validManifest()
  Assert.isTrue(BattlePresentationSchema.isValidManifest(manifest), "the staged manifest is schema-valid")
  local cache = staging()
  stageBattle(cache, manifest, "general/grass/day")
  stageMonPage(cache, selector)
  local demand = assert(
    BattlePresentationCache.requirements(
      manifest,
      { background = "general", terrain = "grass", time = "day" },
      { selector },
      nil
    )
  )
  Assert.isTrue(BattlePresentationCache.isReady(cache, demand), "a fully staged demand reads ready")
  cache:write(BattlePresentationCache.sceneImagePath("general/grass/day"), "truncated")
  Assert.isFalse(
    BattlePresentationCache.isReady(cache, demand),
    "a corrupted scene image never reads as ready"
  )
end

function T.delayed_pages_keep_readiness_pending()
  local selector = MonCache.portraitSelector("CHIKORITA", 0, "male", false, "back")
  local manifest = validManifest()
  local cache = staging()
  stageBattle(cache, manifest, "general/grass/day")
  local demand = assert(
    BattlePresentationCache.requirements(
      manifest,
      { background = "general", terrain = "grass", time = "day" },
      { selector },
      nil
    )
  )
  Assert.isFalse(BattlePresentationCache.isReady(cache, demand), "a delayed portrait page stays pending")
end

return { tests = T }
