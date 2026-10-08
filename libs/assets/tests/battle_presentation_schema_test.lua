-- Runtime-facing validation for the battle presentation family: the
-- staged global manifest, one composed scene record, and exact launch
-- demands. Fixtures are synthetic; the ROM suite proves the staged
-- compiler output satisfies the same contract.

local Assert = require("tests.support.Assert")
local Schema = require("libs.assets.src.battle.BattlePresentationSchema")

local T = {}

---@return table menu descriptor with one staged screen
local function menuSection()
  return {
    image = "assets/generated/battle/menu-command-1.png",
    screens = {
      {
        image = "assets/generated/battle/menu-command-1.png",
        width = 256,
        height = 256,
        template = 1,
        priority = 2,
      },
    },
  }
end

---@return table sprite descriptor with one cell and one frame
local function spriteSection(image)
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
            size = 1,
            width = 16,
            height = 16,
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
    animation = { playMode = "forward_loop", loopStartFrameIdx = 0, frames = { { cell = 0, duration = 4 } } },
    palette = { colors = { { r = 0, g = 0, b = 0 } } },
  }
end

---@return table shared per-type terrain bake metadata without staged pixels
local function terrainSection()
  local sprite = spriteSection("assets/generated/battle/terrain-type0.png")
  return { cells = sprite.cells, animation = sprite.animation }
end

---@return table valid staged global manifest
local function manifest()
  return {
    schema = "g4-battle-presentation-v1",
    version = { id = "soulsilver", language = "en" },
    verified = true,
    scenes = {
      { key = "general/grass/day", background = "general", terrain = "grass", time = "day" },
    },
    images = {
      ["assets/generated/battle/menu-command-1.png"] = { width = 256, height = 256 },
      ["assets/generated/battle/lower-chars.png"] = { width = 3072, height = 8 },
      ["assets/generated/battle/hud-player-chars.png"] = { width = 1024, height = 8 },
      ["assets/generated/battle/hud-enemy-chars.png"] = { width = 1024, height = 8 },
      ["assets/generated/battle/arrow-chars.png"] = { width = 208, height = 8 },
      ["assets/generated/battle/gauges-0-chars.png"] = { width = 128, height = 8 },
      ["assets/generated/battle/gauges-1-chars.png"] = { width = 512, height = 8 },
    },
    command = menuSection(),
    moves = menuSection(),
    target = menuSection(),
    twoOption = menuSection(),
    lower = {
      image = "assets/generated/battle/lower-chars.png",
      palette = { colors = { { r = 1, g = 2, b = 3 } } },
      variants = {
        general = {
          base = { colors = { { r = 1, g = 2, b = 3 } } },
          touch = { colors = { { r = 4, g = 5, b = 6 } } },
        },
      },
    },
    playerHud = spriteSection("assets/generated/battle/hud-player-chars.png"),
    enemyHud = spriteSection("assets/generated/battle/hud-enemy-chars.png"),
    arrow = spriteSection("assets/generated/battle/arrow-chars.png"),
    partyGauges = {
      spriteSection("assets/generated/battle/gauges-0-chars.png"),
      spriteSection("assets/generated/battle/gauges-1-chars.png"),
    },
    terrain = {
      type0 = terrainSection(),
      type1 = terrainSection(),
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

function T.staged_manifests_validate()
  Assert.isTrue(Schema.isValidManifest(manifest()), "a complete staged manifest validates")
end

function T.manifests_reject_missing_roles_and_bad_geometry()
  local missing = manifest()
  missing.arrow = nil
  Assert.isFalse(Schema.isValidManifest(missing), "a manifest without its arrow role never validates")
  local badCell = manifest()
  badCell.playerHud.cells[1].objs[1].width = 0 - (0 / 0)
  Assert.isFalse(Schema.isValidManifest(badCell), "NaN sprite geometry never validates")
  local negative = manifest()
  negative.playerHud.cells[1].objs[1].width = -1
  Assert.isFalse(Schema.isValidManifest(negative), "negative sprite dimensions never validate")
  local unknown = manifest()
  unknown.audioRoles = { wild = "SEQ_MISSING" }
  Assert.isFalse(Schema.isValidManifest(unknown), "an incomplete audio role map never validates")
  local foreign = manifest()
  foreign.extraNative = { memberId = 3 }
  Assert.isFalse(Schema.isValidManifest(foreign), "native-shaped extension data never validates")
end

---@return table valid composed scene record
local function scene()
  return {
    schema = "g4-battle-scene-v1",
    key = "general/grass/day",
    background = "general",
    terrain = "grass",
    time = "day",
    canvasWidth = 512,
    canvasHeight = 256,
    viewport = { x = 0, y = 0, width = 512, height = 256 },
    imagePath = "assets/generated/battle/scenes/general-grass-day.png",
  }
end

function T.scene_records_validate_their_key_and_viewport()
  Assert.isTrue(Schema.isValidScene(scene()), "a composed scene record validates")
  local escaped = scene()
  escaped.viewport = { x = 300, y = 0, width = 256, height = 192 }
  Assert.isFalse(Schema.isValidScene(escaped), "a viewport escaping its canvas never validates")
  local mismatch = scene()
  mismatch.key = "general/grass/night"
  Assert.isFalse(Schema.isValidScene(mismatch), "a scene key disagreeing with its axes never validates")
  local effect = scene()
  effect.key = "effect/flash/day"
  effect.background = "effect"
  Assert.isFalse(Schema.isValidScene(effect), "an effect background never validates as a scene")
end

function T.launch_demands_carry_exact_deduplicated_members()
  local demand = {
    scenes = { "general/grass/day" },
    pages = { "CHIKORITA/f0/male/plain/back" },
    audio = { roles = { "SEQ_GS_VS_NORAPOKE" }, banks = {}, cries = { "cry:CHIKORITA" } },
  }
  Assert.isTrue(Schema.isValidDemand(demand), "an exact launch demand validates")
  local empty = { scenes = {}, pages = {}, audio = { roles = {}, banks = {}, cries = {} } }
  Assert.isFalse(Schema.isValidDemand(empty), "an empty demand never validates")
  local duplicated = {
    scenes = { "general/grass/day", "general/grass/day" },
    pages = {},
    audio = { roles = {}, banks = {}, cries = {} },
  }
  Assert.isFalse(Schema.isValidDemand(duplicated), "a duplicated scene demand never validates")
end

return { tests = T }
