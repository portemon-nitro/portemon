-- Compiles the League ending's own source bundle: the Hall of Fame
-- registration application's text, the PC showcase's text, and the credit roll
-- with its backgrounds, "The End" screen, page timings and message lines.
--
-- Everything here is transcribed from the retail sources the port pins:
--   * src/credits/credits.c: CREDITS_FRAMES, MUSIC_BOX_WAIT_FRAMES, the
--     message bank the roll reads (NARC_msgdata_msg member 0x1b8) and the
--     game-title message index, the six background scene layers with their
--     shared character data and palette from NARC_a_2_6_3, the dancing
--     Pokémon/cloud sprite resources (members 0-3), the cutscene sprite
--     resources (base members 20 and 149), the scene/cutscene state machine
--     (NUM_SCENES, transition/flip timings, cutscene table), and the
--     credit state machine (fade lengths, skip gate, The End);
--   * include/credits/data.h: sSceneTransitionTimings, sScreenFlipTimings,
--     sCreditsBg2ScrnFileIds, sCreditsBg3ScrnFileIds, sPageTimings,
--     sCreditMsgLines, sPokemonSpriteSeqNos, sCutsceneSpriteGfxFileIds and
--     sCutscenes;
--   * src/register_hall_of_fame.c: the registration application's message
--     bank (msg_0180, lines 0-17), its per-member reveal sub-scene chain
--     with exact stage timings (back picture, cry, overworld sprite,
--     header window, front picture, species/level, caught detail), its
--     background/sprite archives (NARC_a_1_0_1 members 0-19, NARC_a_0_0_8
--     members 75-78), its whole-party scene (photo flashes, spotlights,
--     confetti, player picture, terminal A/B/touch acknowledgment), the
--     per-species picture animation scripts and cry delays (NARC_a_1_8_0),
--     and the trainer picture source (NARC_a_0_5_8) behind the player;
--   * the PC showcase's own message bank (msg_0181).
-- Realized surfaces use the existing G2d decoder/rasterizer (NCER/NANR via
-- PokemonCareAssetCompiler precedent) and the existing per-species picture
-- height/animation sources (MonSources, SummaryPictureCompiler); the
-- registration and credit choreography below is realized, not deferred.
--
-- Pure producer module: it reads the imported archive tree, rasterizes the
-- source background records once, and publishes one deterministic bundle.

local Errors = require("libs.errors.src.Errors")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local Hashing = require("romdump.src.digest.Hashing")
local Contract = require("libs.assets.src.DerivedAssetContract")
local Lz10 = require("romdump.src.digest.Lz10")
local Lz11 = require("romdump.src.digest.Lz11")
local PngWriter = require("romdump.src.digest.PngEncoder")
local EndingAssetCache = require("libs.assets.src.ending.EndingAssetCache")
local MonSources = require("romdump.src.config.MonSources")
local SummaryPictureCompiler = require("romdump.src.digest.ui.SummaryPictureCompiler")

---@class EndingAssetCompiler
local Compiler = {}

-- The credit roll's application archive (NARC_a_2_6_3). The source identity is
-- the raw NARC symbol: no curated alias covers it yet.
Compiler.creditArchive = { symbol = "NARC_a_2_6_3", path = "a/2/6/3" }
-- The roll's own source facts (src/credits/credits.c).
Compiler.CREDITS_FRAMES = 4976
Compiler.MUSIC_BOX_WAIT_FRAMES = 380
Compiler.CREDITS_MESSAGE_BANK = 440
Compiler.REGISTRATION_MESSAGE_BANK = 180
Compiler.SHOWCASE_MESSAGE_BANK = 181
-- GAME_TITLE_MSG_NO: HeartGold is message 0, SoulSilver message 1.
Compiler.TITLE_MESSAGE = { heartgold = 0, soulsilver = 1 }
-- src/register_hall_of_fame.c: the registration BGM over the reveal.
Compiler.REGISTRATION_BGM = "SEQ_GS_E_DENDOUIRI"
-- src/register_hall_of_fame.c photo effects: the first flash fades white
-- over 40 frames with the flash/kansei sound effects; the accepted photo
-- wait replays the flash over 15 frames and fades to black over 15.
Compiler.REGISTRATION_FLASH_FRAMES = 40
Compiler.REGISTRATION_REFLASH_FRAMES = 15
Compiler.REGISTRATION_FADE_FRAMES = 15
Compiler.REGISTRATION_FLASH_SE = "SEQ_SE_GS_DENDOUIRI_FLASH"
Compiler.REGISTRATION_KANSEI_SE = "SEQ_SE_GS_DENDOUIRI_KANSEI"
-- The individual-scene application archive (NARC_a_1_0_1): background
-- screens/chars/palettes for both scenes plus the overworld-sprite and
-- twinkle/player sprite groups, by the source member layout.

-- include/credits/data.h sScreenFlipTimings: the source display-swap timeline
-- behind HandleSceneFlip, parallel to the scene transitions.
local SCREEN_FLIP_TIMINGS = { 890, 1780, 2615, 3030, 4295 }
-- src/register_hall_of_fame.c sprite resource identities, realized below:
-- the individual-scene sprite group (NARC_a_0_0_8 char/cell/anim 76/77/78
-- with palette 75), the overworld-sprite groups (NARC_a_1_0_1 chars 9/12,
-- cells 10/13, anims 11/14 with palette 15; small vs large by follower
-- size), and the twinkle/player group (char 16, cell 17, anim 18 with
-- palette 19; the player picture itself comes from the trainer picture
-- source below).
-- src/credits/credits.c sprite resource members behind the dancing
-- Pokémon/clouds (members 0-3) and the character cutscenes (members 20 and
-- 149 plus per-sprite file IDs in sCutsceneSpriteGfxFileIds), realized
-- below into per-sequence frame rasters the credit choreography consumes.
local CREDIT_SPRITE_RESOURCES = { charMember = 1, paletteMember = 0, cellMember = 2, animMember = 3 }
local CUTSCENE_RESOURCES = { charBaseMember = 20, paletteMember = 149, count = 16 }
-- sCutsceneSpriteGfxFileIds (data.h): per-sprite {pal, char, cell, anim}.
local CUTSCENE_SPRITE_FILE_IDS = {
  { paletteMember = 150, charMember = 23, cellMember = 24, animMember = 25 },
  { paletteMember = 151, charMember = 26, cellMember = 27, animMember = 28 },
  { paletteMember = 152, charMember = 29, cellMember = 30, animMember = 31 },
  { paletteMember = 153, charMember = 32, cellMember = 33, animMember = 34 },
  { paletteMember = 154, charMember = 35, cellMember = 36, animMember = 37 },
  { paletteMember = 155, charMember = 38, cellMember = 39, animMember = 40 },
  { paletteMember = 156, charMember = 41, cellMember = 42, animMember = 43 },
  { paletteMember = 157, charMember = 44, cellMember = 45, animMember = 46 },
  { paletteMember = 158, charMember = 47, cellMember = 48, animMember = 49 },
  { paletteMember = 159, charMember = 50, cellMember = 51, animMember = 52 },
  { paletteMember = 160, charMember = 53, cellMember = 54, animMember = 55 },
  { paletteMember = 161, charMember = 56, cellMember = 57, animMember = 58 },
  { paletteMember = 162, charMember = 59, cellMember = 60, animMember = 61 },
  { paletteMember = 163, charMember = 62, cellMember = 63, animMember = 64 },
  { paletteMember = 164, charMember = 65, cellMember = 66, animMember = 67 },
  { paletteMember = 165, charMember = 68, cellMember = 69, animMember = 70 },
  { paletteMember = 166, charMember = 71, cellMember = 72, animMember = 73 },
  { paletteMember = 167, charMember = 74, cellMember = 75, animMember = 76 },
  { paletteMember = 168, charMember = 77, cellMember = 78, animMember = 79 },
  { paletteMember = 169, charMember = 80, cellMember = 81, animMember = 82 },
  { paletteMember = 170, charMember = 83, cellMember = 84, animMember = 85 },
  { paletteMember = 171, charMember = 86, cellMember = 87, animMember = 88 },
  { paletteMember = 172, charMember = 89, cellMember = 90, animMember = 91 },
  { paletteMember = 173, charMember = 92, cellMember = 93, animMember = 94 },
  { paletteMember = 174, charMember = 95, cellMember = 96, animMember = 97 },
  { paletteMember = 175, charMember = 98, cellMember = 99, animMember = 100 },
  { paletteMember = 176, charMember = 101, cellMember = 102, animMember = 103 },
  { paletteMember = 177, charMember = 104, cellMember = 105, animMember = 106 },
  { paletteMember = 178, charMember = 107, cellMember = 108, animMember = 109 },
  { paletteMember = 179, charMember = 110, cellMember = 111, animMember = 112 },
  { paletteMember = 180, charMember = 113, cellMember = 114, animMember = 115 },
  { paletteMember = 181, charMember = 116, cellMember = 117, animMember = 118 },
  { paletteMember = 182, charMember = 119, cellMember = 120, animMember = 121 },
  { paletteMember = 183, charMember = 122, cellMember = 123, animMember = 124 },
  { paletteMember = 184, charMember = 125, cellMember = 126, animMember = 127 },
  { paletteMember = 185, charMember = 128, cellMember = 129, animMember = 130 },
  { paletteMember = 186, charMember = 131, cellMember = 132, animMember = 133 },
  { paletteMember = 187, charMember = 134, cellMember = 135, animMember = 136 },
  { paletteMember = 188, charMember = 137, cellMember = 138, animMember = 139 },
  { paletteMember = 189, charMember = 140, cellMember = 141, animMember = 142 },
  { paletteMember = 190, charMember = 143, cellMember = 144, animMember = 145 },
  { paletteMember = 191, charMember = 146, cellMember = 147, animMember = 148 },
}

local CUTSCENES = {
  {
    uniqueSprites = 4,
    totalSprites = 4,
    spriteIds = { 0, 1, 2, 3 },
    params = {
      { spriteIdx = 0, animSeq = 2, x = 128, y = 96, activateTime = 50 },
      { spriteIdx = 1, animSeq = 2, x = 128, y = 96, activateTime = 50 },
      { spriteIdx = 2, animSeq = 2, x = 128, y = 96, activateTime = 50 },
      { spriteIdx = 3, animSeq = 2, x = 128, y = 96, activateTime = 50 },
    },
  },
  {
    uniqueSprites = 2,
    totalSprites = 2,
    spriteIds = { 3, 4 },
    params = {
      { spriteIdx = 0, animSeq = 3, x = 128, y = 96, activateTime = 333 },
      { spriteIdx = 1, animSeq = 2, x = 128, y = 96, activateTime = 333 },
    },
  },
  {
    uniqueSprites = 4,
    totalSprites = 4,
    spriteIds = { 5, 6, 7, 8 },
    params = {
      { spriteIdx = 0, animSeq = 2, x = 128, y = 96, activateTime = 700 },
      { spriteIdx = 1, animSeq = 2, x = 128, y = 96, activateTime = 700 },
      { spriteIdx = 2, animSeq = 2, x = 128, y = 96, activateTime = 700 },
      { spriteIdx = 3, animSeq = 2, x = 128, y = 96, activateTime = 700 },
    },
  },
  {
    uniqueSprites = 6,
    totalSprites = 6,
    spriteIds = { 0, 1, 2, 3, 5, 6 },
    params = {
      { spriteIdx = 0, animSeq = 3, x = 128, y = 96, activateTime = 890 },
      { spriteIdx = 1, animSeq = 3, x = 128, y = 96, activateTime = 890 },
      { spriteIdx = 2, animSeq = 3, x = 128, y = 96, activateTime = 890 },
      { spriteIdx = 3, animSeq = 4, x = 128, y = 96, activateTime = 890 },
      { spriteIdx = 4, animSeq = 3, x = 128, y = 96, activateTime = 890 },
      { spriteIdx = 5, animSeq = 3, x = 128, y = 96, activateTime = 890 },
    },
  },
  {
    uniqueSprites = 3,
    totalSprites = 3,
    spriteIds = { 5, 7, 9 },
    params = {
      { spriteIdx = 0, animSeq = 4, x = 128, y = 96, activateTime = 900 },
      { spriteIdx = 1, animSeq = 3, x = 128, y = 96, activateTime = 900 },
      { spriteIdx = 2, animSeq = 2, x = 128, y = 96, activateTime = 900 },
    },
  },
  {
    uniqueSprites = 5,
    totalSprites = 14,
    spriteIds = { 10, 11, 12, 13, 14, 0 },
    params = {
      { spriteIdx = 0, animSeq = 2, x = 128, y = 96, activateTime = 1230 },
      { spriteIdx = 1, animSeq = 2, x = 128, y = 96, activateTime = 1230 },
      { spriteIdx = 2, animSeq = 4, x = 90, y = 10, activateTime = 1260 },
      { spriteIdx = 2, animSeq = 3, x = 60, y = 15, activateTime = 1260 },
      { spriteIdx = 2, animSeq = 4, x = 80, y = 20, activateTime = 1260 },
      { spriteIdx = 2, animSeq = 4, x = 75, y = 25, activateTime = 1260 },
      { spriteIdx = 2, animSeq = 4, x = 95, y = 30, activateTime = 1280 },
      { spriteIdx = 2, animSeq = 2, x = 70, y = 35, activateTime = 1260 },
      { spriteIdx = 2, animSeq = 3, x = 100, y = 40, activateTime = 1280 },
      { spriteIdx = 2, animSeq = 3, x = 65, y = 45, activateTime = 1280 },
      { spriteIdx = 2, animSeq = 5, x = 90, y = 50, activateTime = 1350 },
      { spriteIdx = 2, animSeq = 4, x = 85, y = 55, activateTime = 1280 },
      { spriteIdx = 3, animSeq = 2, x = 128, y = 96, activateTime = 1240 },
      { spriteIdx = 4, animSeq = 2, x = 128, y = 96, activateTime = 1240 },
    },
  },
  {
    uniqueSprites = 4,
    totalSprites = 4,
    spriteIds = { 3, 16, 4, 15 },
    params = {
      { spriteIdx = 0, animSeq = 5, x = 128, y = 96, activateTime = 1550 },
      { spriteIdx = 1, animSeq = 2, x = 128, y = 96, activateTime = 1550 },
      { spriteIdx = 2, animSeq = 3, x = 128, y = 96, activateTime = 1550 },
      { spriteIdx = 3, animSeq = 2, x = 128, y = 96, activateTime = 1550 },
    },
  },
  {
    uniqueSprites = 4,
    totalSprites = 4,
    spriteIds = { 15, 17, 18, 19 },
    params = {
      { spriteIdx = 0, animSeq = 3, x = 128, y = 96, activateTime = 1800 },
      { spriteIdx = 1, animSeq = 2, x = 128, y = 96, activateTime = 1800 },
      { spriteIdx = 2, animSeq = 2, x = 128, y = 96, activateTime = 1800 },
      { spriteIdx = 3, animSeq = 2, x = 128, y = 96, activateTime = 1800 },
    },
  },
  {
    uniqueSprites = 4,
    totalSprites = 13,
    spriteIds = { 24, 25, 26, 27 },
    params = {
      { spriteIdx = 0, animSeq = 2, x = 128, y = 96, activateTime = 2200 },
      { spriteIdx = 1, animSeq = 2, x = 128, y = 96, activateTime = 2200 },
      { spriteIdx = 2, animSeq = 2, x = 116, y = 80, activateTime = 2200 },
      { spriteIdx = 2, animSeq = 2, x = 142, y = 85, activateTime = 2203 },
      { spriteIdx = 2, animSeq = 1, x = 128, y = 96, activateTime = 2200 },
      { spriteIdx = 2, animSeq = 1, x = 128, y = 96, activateTime = 2200 },
      { spriteIdx = 2, animSeq = 1, x = 128, y = 96, activateTime = 2200 },
      { spriteIdx = 2, animSeq = 1, x = 128, y = 96, activateTime = 2200 },
      { spriteIdx = 2, animSeq = 1, x = 128, y = 96, activateTime = 2200 },
      { spriteIdx = 2, animSeq = 1, x = 128, y = 96, activateTime = 2200 },
      { spriteIdx = 2, animSeq = 1, x = 128, y = 96, activateTime = 2200 },
      { spriteIdx = 2, animSeq = 1, x = 128, y = 96, activateTime = 2200 },
      { spriteIdx = 3, animSeq = 2, x = 128, y = 96, activateTime = 2200 },
    },
  },
  {
    uniqueSprites = 4,
    totalSprites = 12,
    spriteIds = { 20, 21, 22, 23 },
    params = {
      { spriteIdx = 0, animSeq = 2, x = 128, y = 96, activateTime = 2650 },
      { spriteIdx = 1, animSeq = 2, x = 128, y = 96, activateTime = 2650 },
      { spriteIdx = 2, animSeq = 3, x = 120, y = 80, activateTime = 2651 },
      { spriteIdx = 2, animSeq = 2, x = 126, y = 90, activateTime = 2652 },
      { spriteIdx = 2, animSeq = 3, x = 130, y = 72, activateTime = 2653 },
      { spriteIdx = 2, animSeq = 2, x = 110, y = 90, activateTime = 2654 },
      { spriteIdx = 2, animSeq = 3, x = 140, y = 100, activateTime = 2655 },
      { spriteIdx = 2, animSeq = 2, x = 125, y = 110, activateTime = 2656 },
      { spriteIdx = 2, animSeq = 3, x = 135, y = 72, activateTime = 2657 },
      { spriteIdx = 2, animSeq = 2, x = 114, y = 60, activateTime = 2658 },
      { spriteIdx = 2, animSeq = 3, x = 110, y = 80, activateTime = 2659 },
      { spriteIdx = 3, animSeq = 2, x = 128, y = 96, activateTime = 2650 },
    },
  },
  {
    uniqueSprites = 4,
    totalSprites = 4,
    spriteIds = { 28, 30, 29, 33 },
    params = {
      { spriteIdx = 0, animSeq = 2, x = 128, y = 96, activateTime = 3060 },
      { spriteIdx = 1, animSeq = 2, x = 128, y = 96, activateTime = 3060 },
      { spriteIdx = 2, animSeq = 2, x = 126, y = 96, activateTime = 3060 },
      { spriteIdx = 3, animSeq = 2, x = 128, y = 96, activateTime = 3060 },
    },
  },
  {
    uniqueSprites = 5,
    totalSprites = 9,
    spriteIds = { 34, 35, 36, 37, 32, 0 },
    params = {
      { spriteIdx = 0, animSeq = 2, x = 128, y = 110, activateTime = 3359 },
      { spriteIdx = 1, animSeq = 2, x = 128, y = 110, activateTime = 3340 },
      { spriteIdx = 2, animSeq = 2, x = 128, y = 110, activateTime = 3378 },
      { spriteIdx = 3, animSeq = 2, x = 128, y = 110, activateTime = 3397 },
      { spriteIdx = 4, animSeq = 2, x = 128, y = 110, activateTime = 3416 },
      { spriteIdx = 4, animSeq = 3, x = 128, y = 110, activateTime = 3435 },
      { spriteIdx = 4, animSeq = 2, x = 128, y = 110, activateTime = 3454 },
      { spriteIdx = 4, animSeq = 3, x = 128, y = 110, activateTime = 3473 },
      { spriteIdx = 4, animSeq = 4, x = 128, y = 110, activateTime = 3650 },
    },
  },
  {
    uniqueSprites = 6,
    totalSprites = 6,
    spriteIds = { 37, 36, 5, 29, 35, 34 },
    params = {
      { spriteIdx = 0, animSeq = 3, x = 128, y = 125, activateTime = 3760 },
      { spriteIdx = 1, animSeq = 3, x = 128, y = 100, activateTime = 3740 },
      { spriteIdx = 2, animSeq = 5, x = 128, y = 96, activateTime = 3810 },
      { spriteIdx = 3, animSeq = 3, x = 128, y = 96, activateTime = 3800 },
      { spriteIdx = 4, animSeq = 3, x = 128, y = 70, activateTime = 3730 },
      { spriteIdx = 5, animSeq = 3, x = 128, y = 45, activateTime = 3750 },
    },
  },
  {
    uniqueSprites = 4,
    totalSprites = 4,
    spriteIds = { 38, 39, 40, 41 },
    params = {
      { spriteIdx = 0, animSeq = 2, x = 128, y = 96, activateTime = 3935 },
      { spriteIdx = 1, animSeq = 2, x = 128, y = 96, activateTime = 3975 },
      { spriteIdx = 2, animSeq = 2, x = 128, y = 96, activateTime = 4015 },
      { spriteIdx = 3, animSeq = 2, x = 128, y = 96, activateTime = 4055 },
    },
  },
  {
    uniqueSprites = 3,
    totalSprites = 3,
    spriteIds = { 5, 29, 30 },
    params = {
      { spriteIdx = 0, animSeq = 6, x = 128, y = 96, activateTime = 4300 },
      { spriteIdx = 1, animSeq = 4, x = 128, y = 96, activateTime = 4300 },
      { spriteIdx = 2, animSeq = 4, x = 128, y = 96, activateTime = 4300 },
    },
  },
  {
    uniqueSprites = 2,
    totalSprites = 2,
    spriteIds = { 5, 6 },
    params = {
      { spriteIdx = 0, animSeq = 7, x = 128, y = 96, activateTime = 4570 },
      { spriteIdx = 1, animSeq = 4, x = 128, y = 96, activateTime = 4570 },
    },
  },
}
-- src/register_hall_of_fame.c background/sprite identities, realized below
-- into published images and frame rasters the registration scenes consume:
-- individual backgrounds (screens 0-2, chars 3, palette 4), whole-party
-- backgrounds (screens 5-6, chars 7, palette 8), the overworld-sprite and
-- twinkle groups above, the individual sprite group above, and the trainer
-- picture source (NARC_a_0_5_8) behind the whole-party player.
local REGISTRATION_ARCHIVE = { symbol = "NARC_a_1_0_1", path = "a/1/0/1" }
local REGISTRATION_SPRITE_ARCHIVE = { symbol = "NARC_a_0_0_8", path = "a/0/0/8" }
local REGISTRATION_ANIM_ARCHIVE = { symbol = "NARC_a_1_8_0", path = "a/1/8/0" }
local REGISTRATION_TRAINER_ARCHIVE = { symbol = "NARC_a_0_5_8", path = "a/0/5/8" }
-- Individual background layers (screens) over shared chars/palette.
local REGISTRATION_INDIV_SCREENS = { 0, 1, 2 }
local REGISTRATION_INDIV_CHAR = 3
local REGISTRATION_INDIV_PALETTE = 4
-- Whole-party background layers over shared chars/palette.
local REGISTRATION_WHOLE_SCREENS = { 5, 6 }
local REGISTRATION_WHOLE_CHAR = 7
local REGISTRATION_WHOLE_PALETTE = 8
-- Twinkle/player shared group (the player char comes from the trainer
-- picture source; the twinkle char is member 16).
local REGISTRATION_TWINKLE = { charMember = 16, cellMember = 17, animMember = 18, paletteMember = 19 }
-- Individual-scene shadow/cell/anim scaffolding (pixels come from the
-- recorded mons; palettes are source silhouette constants at runtime).
local REGISTRATION_SHADOW = { charMember = 76, cellMember = 77, animMember = 78, paletteMember = 75 }
-- Trainer picture members: class*5 + {char, pal, cell, anim, combined}.
-- Ethan is class 0, Lyra class 1 (trainer_class.h).
local TRAINER_CHAR_OFFSET = 0
local TRAINER_PALETTE_OFFSET = 1
local TRAINER_MEMBERS_PER_CLASS = 5
local TRAINER_ETHAN_CLASS = 0
local TRAINER_LYRA_CLASS = 1
-- sSpotlightColors / sConfettiColors (register_hall_of_fame.c), transcribed
-- so the port's 2D spotlight/confetti adaptation shares the source colors.
local SPOTLIGHT_COLORS = {
  { 31, 31, 12 },
  { 31, 31, 16 },
  { 31, 28, 8 },
  { 31, 31, 12 },
  { 31, 31, 16 },
  { 31, 28, 8 },
  { 31, 31, 12 },
  { 31, 31, 12 },
}
local CONFETTI_COLORS = {
  { 16, 28, 21 },
  { 31, 16, 29 },
  { 8, 8, 31 },
  { 6, 31, 31 },
  { 31, 31, 0 },
  { 9, 31, 0 },
  { 31, 18, 0 },
  { 22, 0, 31 },
}
-- data2.c sPokemonSpriteSeqNos: the dancing sequence per scene index.
local DANCE_SEQS_BY_SCENE = { 6, 1, 2, 4, 3, 5 }
local CLOUD_SEQ = 7
-- sCutsceneSpriteGfxFileIds (data.h): per-sprite {char, pal, cell, anim}
-- members, decimal. Sprite slots 5 and 7 swap char/pal by player gender
-- (LoadCutsceneSpriteGfx): female players and friends exchange file IDs.
-- src/hall_of_fame_showcase.c main/sub background archive behind the grid
-- and detail presentation.
local SHOWCASE_BACKGROUND_ARCHIVE = "NARC_a_0_9_7"

-- include/credits/data.h sSceneTransitionTimings and sScreenFlipTimings.
local SCENE_TRANSITION_TIMINGS = { 890, 1780, 2615, 3030, 4295 }
-- sCreditsBg2ScrnFileIds / sCreditsBg3ScrnFileIds: the six scenes' screen
-- records, drawn over one shared character set (member 5) and palette (member
-- 4).
local BG2_SCREEN_MEMBERS = { 0x07, 0x11, 0x09, 0x0F, 0x0D, 0x0B }
local BG3_SCREEN_MEMBERS = { 0x08, 0x12, 0x0A, 0x10, 0x0E, 0x0C }
local BG_CHAR_MEMBER = 5
local BG_PALETTE_MEMBER = 4
-- The End: GfGfxLoader_LoadCharData(member 6) with its screen record 19.
local THE_END_CHAR_MEMBER = 6
local THE_END_SCREEN_MEMBER = 19

-- sPageTimings: one start time and duration per credit page.
local PAGE_TIMINGS = {
  { startTime = 0, duration = 105 },
  { startTime = 110, duration = 105 },
  { startTime = 220, duration = 105 },
  { startTime = 330, duration = 105 },
  { startTime = 440, duration = 105 },
  { startTime = 550, duration = 105 },
  { startTime = 660, duration = 115 },
  { startTime = 779, duration = 109 },
  { startTime = 894, duration = 115 },
  { startTime = 1012, duration = 109 },
  { startTime = 1125, duration = 102 },
  { startTime = 1232, duration = 102 },
  { startTime = 1339, duration = 110 },
  { startTime = 1454, duration = 105 },
  { startTime = 1565, duration = 105 },
  { startTime = 1676, duration = 100 },
  { startTime = 1787, duration = 105 },
  { startTime = 1898, duration = 105 },
  { startTime = 2009, duration = 105 },
  { startTime = 2120, duration = 120 },
  { startTime = 2245, duration = 120 },
  { startTime = 2370, duration = 120 },
  { startTime = 2495, duration = 110 },
  { startTime = 2620, duration = 125 },
  { startTime = 2750, duration = 110 },
  { startTime = 2865, duration = 160 },
  { startTime = 3035, duration = 100 },
  { startTime = 3140, duration = 100 },
  { startTime = 3245, duration = 125 },
  { startTime = 3375, duration = 100 },
  { startTime = 3480, duration = 115 },
  { startTime = 3598, duration = 115 },
  { startTime = 3716, duration = 115 },
  { startTime = 3834, duration = 115 },
  { startTime = 3952, duration = 115 },
  { startTime = 4070, duration = 115 },
  { startTime = 4188, duration = 105 },
  { startTime = 4300, duration = 110 },
  { startTime = 4415, duration = 110 },
  { startTime = 4530, duration = 127 },
  { startTime = 4660, duration = 107 },
  { startTime = 4770, duration = 107 },
  { startTime = 4880, duration = 107 },
}

-- sCreditMsgLines: every printed credit line's page, source window position
-- and message index inside the roll's own message bank.
local CREDIT_LINES = {
  { page = 0, x = 0, y = 70, message = 0 },
  { page = 1, x = 20, y = 80, message = 3 },
  { page = 1, x = 40, y = 96, message = 4 },
  { page = 2, x = 20, y = 20, message = 5 },
  { page = 2, x = 40, y = 36, message = 6 },
  { page = 2, x = 20, y = 60, message = 7 },
  { page = 2, x = 40, y = 76, message = 8 },
  { page = 2, x = 20, y = 100, message = 9 },
  { page = 2, x = 40, y = 116, message = 10 },
  { page = 2, x = 20, y = 140, message = 11 },
  { page = 2, x = 40, y = 156, message = 12 },
  { page = 3, x = 20, y = 40, message = 13 },
  { page = 3, x = 40, y = 56, message = 14 },
  { page = 3, x = 40, y = 72, message = 15 },
  { page = 3, x = 40, y = 88, message = 16 },
  { page = 3, x = 40, y = 104, message = 17 },
  { page = 3, x = 40, y = 120, message = 18 },
  { page = 3, x = 40, y = 136, message = 19 },
  { page = 4, x = 20, y = 32, message = 20 },
  { page = 4, x = 20, y = 48, message = 21 },
  { page = 4, x = 20, y = 64, message = 22 },
  { page = 4, x = 40, y = 80, message = 23 },
  { page = 4, x = 40, y = 96, message = 24 },
  { page = 4, x = 40, y = 112, message = 25 },
  { page = 4, x = 40, y = 128, message = 26 },
  { page = 4, x = 40, y = 144, message = 27 },
  { page = 5, x = 40, y = 32, message = 28 },
  { page = 5, x = 40, y = 48, message = 29 },
  { page = 5, x = 40, y = 64, message = 30 },
  { page = 5, x = 40, y = 80, message = 31 },
  { page = 5, x = 40, y = 96, message = 32 },
  { page = 5, x = 40, y = 112, message = 33 },
  { page = 5, x = 40, y = 128, message = 34 },
  { page = 5, x = 40, y = 144, message = 35 },
  { page = 6, x = 20, y = 24, message = 36 },
  { page = 6, x = 40, y = 40, message = 37 },
  { page = 6, x = 40, y = 56, message = 38 },
  { page = 6, x = 40, y = 72, message = 39 },
  { page = 6, x = 40, y = 88, message = 40 },
  { page = 6, x = 40, y = 104, message = 41 },
  { page = 6, x = 40, y = 120, message = 42 },
  { page = 6, x = 40, y = 136, message = 43 },
  { page = 6, x = 40, y = 152, message = 44 },
  { page = 7, x = 20, y = 8, message = 45 },
  { page = 7, x = 40, y = 24, message = 46 },
  { page = 7, x = 40, y = 40, message = 47 },
  { page = 7, x = 40, y = 56, message = 48 },
  { page = 7, x = 40, y = 72, message = 49 },
  { page = 7, x = 20, y = 96, message = 50 },
  { page = 7, x = 40, y = 112, message = 51 },
  { page = 7, x = 40, y = 128, message = 52 },
  { page = 7, x = 20, y = 152, message = 53 },
  { page = 7, x = 40, y = 168, message = 54 },
  { page = 8, x = 20, y = 48, message = 55 },
  { page = 8, x = 40, y = 64, message = 56 },
  { page = 8, x = 40, y = 80, message = 57 },
  { page = 8, x = 40, y = 96, message = 58 },
  { page = 8, x = 40, y = 112, message = 59 },
  { page = 8, x = 40, y = 128, message = 60 },
  { page = 9, x = 40, y = 40, message = 61 },
  { page = 9, x = 40, y = 56, message = 62 },
  { page = 9, x = 40, y = 72, message = 63 },
  { page = 9, x = 40, y = 88, message = 64 },
  { page = 9, x = 40, y = 104, message = 65 },
  { page = 9, x = 40, y = 120, message = 66 },
  { page = 9, x = 40, y = 136, message = 67 },
  { page = 10, x = 20, y = 64, message = 68 },
  { page = 10, x = 40, y = 80, message = 69 },
  { page = 10, x = 40, y = 96, message = 70 },
  { page = 10, x = 40, y = 112, message = 71 },
  { page = 11, x = 20, y = 64, message = 72 },
  { page = 11, x = 40, y = 80, message = 73 },
  { page = 11, x = 40, y = 96, message = 74 },
  { page = 11, x = 40, y = 112, message = 75 },
  { page = 12, x = 20, y = 72, message = 76 },
  { page = 12, x = 40, y = 88, message = 77 },
  { page = 12, x = 40, y = 104, message = 78 },
  { page = 13, x = 20, y = 48, message = 79 },
  { page = 13, x = 40, y = 64, message = 80 },
  { page = 13, x = 40, y = 80, message = 81 },
  { page = 13, x = 40, y = 96, message = 82 },
  { page = 13, x = 40, y = 112, message = 83 },
  { page = 13, x = 40, y = 128, message = 84 },
  { page = 14, x = 20, y = 56, message = 85 },
  { page = 14, x = 40, y = 72, message = 86 },
  { page = 14, x = 40, y = 88, message = 87 },
  { page = 14, x = 40, y = 104, message = 88 },
  { page = 14, x = 40, y = 120, message = 89 },
  { page = 15, x = 20, y = 40, message = 90 },
  { page = 15, x = 40, y = 56, message = 91 },
  { page = 15, x = 40, y = 72, message = 92 },
  { page = 15, x = 40, y = 88, message = 93 },
  { page = 15, x = 40, y = 104, message = 94 },
  { page = 15, x = 40, y = 120, message = 95 },
  { page = 15, x = 40, y = 136, message = 96 },
  { page = 16, x = 40, y = 40, message = 97 },
  { page = 16, x = 40, y = 56, message = 98 },
  { page = 16, x = 40, y = 72, message = 99 },
  { page = 16, x = 40, y = 88, message = 100 },
  { page = 16, x = 40, y = 104, message = 101 },
  { page = 16, x = 40, y = 120, message = 102 },
  { page = 16, x = 40, y = 136, message = 103 },
  { page = 17, x = 40, y = 40, message = 104 },
  { page = 17, x = 40, y = 56, message = 105 },
  { page = 17, x = 40, y = 72, message = 106 },
  { page = 17, x = 40, y = 88, message = 107 },
  { page = 17, x = 40, y = 104, message = 108 },
  { page = 17, x = 40, y = 120, message = 109 },
  { page = 17, x = 40, y = 136, message = 110 },
  { page = 18, x = 20, y = 80, message = 111 },
  { page = 18, x = 40, y = 96, message = 112 },
  { page = 19, x = 20, y = 72, message = 113 },
  { page = 19, x = 40, y = 88, message = 114 },
  { page = 19, x = 40, y = 104, message = 115 },
  { page = 20, x = 20, y = 36, message = 116 },
  { page = 20, x = 40, y = 52, message = 117 },
  { page = 20, x = 40, y = 68, message = 118 },
  { page = 20, x = 20, y = 92, message = 119 },
  { page = 20, x = 40, y = 108, message = 120 },
  { page = 20, x = 40, y = 124, message = 121 },
  { page = 20, x = 40, y = 140, message = 122 },
  { page = 21, x = 20, y = 64, message = 123 },
  { page = 21, x = 40, y = 80, message = 124 },
  { page = 21, x = 40, y = 96, message = 125 },
  { page = 21, x = 40, y = 112, message = 126 },
  { page = 22, x = 20, y = 64, message = 127 },
  { page = 22, x = 40, y = 80, message = 128 },
  { page = 22, x = 40, y = 96, message = 129 },
  { page = 22, x = 40, y = 112, message = 130 },
  { page = 23, x = 20, y = 48, message = 131 },
  { page = 23, x = 40, y = 64, message = 132 },
  { page = 23, x = 40, y = 80, message = 133 },
  { page = 23, x = 40, y = 96, message = 134 },
  { page = 23, x = 40, y = 112, message = 135 },
  { page = 23, x = 40, y = 128, message = 136 },
  { page = 24, x = 40, y = 48, message = 137 },
  { page = 24, x = 40, y = 64, message = 138 },
  { page = 24, x = 40, y = 80, message = 139 },
  { page = 24, x = 40, y = 96, message = 140 },
  { page = 24, x = 40, y = 112, message = 141 },
  { page = 24, x = 40, y = 128, message = 142 },
  { page = 25, x = 20, y = 64, message = 143 },
  { page = 25, x = 40, y = 80, message = 144 },
  { page = 25, x = 40, y = 96, message = 145 },
  { page = 25, x = 40, y = 112, message = 146 },
  { page = 26, x = 20, y = 16, message = 147 },
  { page = 26, x = 40, y = 32, message = 148 },
  { page = 26, x = 40, y = 48, message = 149 },
  { page = 26, x = 40, y = 64, message = 150 },
  { page = 26, x = 40, y = 80, message = 151 },
  { page = 26, x = 40, y = 96, message = 152 },
  { page = 26, x = 40, y = 112, message = 153 },
  { page = 26, x = 40, y = 128, message = 154 },
  { page = 26, x = 40, y = 144, message = 155 },
  { page = 26, x = 40, y = 160, message = 156 },
  { page = 27, x = 20, y = 60, message = 157 },
  { page = 27, x = 20, y = 84, message = 158 },
  { page = 27, x = 40, y = 100, message = 159 },
  { page = 27, x = 40, y = 116, message = 160 },
  { page = 28, x = 20, y = 80, message = 161 },
  { page = 28, x = 40, y = 96, message = 162 },
  { page = 29, x = 20, y = 24, message = 163 },
  { page = 29, x = 40, y = 40, message = 164 },
  { page = 29, x = 40, y = 56, message = 165 },
  { page = 29, x = 40, y = 72, message = 166 },
  { page = 29, x = 40, y = 88, message = 167 },
  { page = 29, x = 40, y = 104, message = 168 },
  { page = 29, x = 40, y = 120, message = 169 },
  { page = 29, x = 40, y = 136, message = 170 },
  { page = 29, x = 40, y = 152, message = 171 },
  { page = 30, x = 20, y = 20, message = 172 },
  { page = 30, x = 40, y = 36, message = 173 },
  { page = 30, x = 20, y = 60, message = 174 },
  { page = 30, x = 40, y = 76, message = 175 },
  { page = 30, x = 20, y = 100, message = 176 },
  { page = 30, x = 40, y = 116, message = 177 },
  { page = 30, x = 20, y = 140, message = 178 },
  { page = 30, x = 40, y = 156, message = 179 },
  { page = 31, x = 20, y = 12, message = 180 },
  { page = 31, x = 40, y = 28, message = 181 },
  { page = 31, x = 40, y = 44, message = 182 },
  { page = 31, x = 40, y = 60, message = 183 },
  { page = 31, x = 40, y = 76, message = 184 },
  { page = 31, x = 40, y = 92, message = 185 },
  { page = 31, x = 40, y = 108, message = 186 },
  { page = 31, x = 40, y = 124, message = 187 },
  { page = 31, x = 20, y = 148, message = 188 },
  { page = 31, x = 40, y = 164, message = 189 },
  { page = 32, x = 20, y = 16, message = 190 },
  { page = 32, x = 40, y = 32, message = 191 },
  { page = 32, x = 40, y = 48, message = 192 },
  { page = 32, x = 40, y = 64, message = 193 },
  { page = 32, x = 40, y = 80, message = 194 },
  { page = 32, x = 40, y = 96, message = 195 },
  { page = 32, x = 40, y = 112, message = 196 },
  { page = 32, x = 40, y = 128, message = 197 },
  { page = 32, x = 40, y = 144, message = 198 },
  { page = 32, x = 40, y = 160, message = 199 },
  { page = 33, x = 40, y = 16, message = 200 },
  { page = 33, x = 40, y = 32, message = 201 },
  { page = 33, x = 40, y = 48, message = 202 },
  { page = 33, x = 40, y = 64, message = 203 },
  { page = 33, x = 40, y = 80, message = 204 },
  { page = 33, x = 40, y = 96, message = 205 },
  { page = 33, x = 40, y = 112, message = 206 },
  { page = 33, x = 40, y = 128, message = 207 },
  { page = 33, x = 40, y = 144, message = 208 },
  { page = 33, x = 40, y = 160, message = 209 },
  { page = 34, x = 40, y = 16, message = 210 },
  { page = 34, x = 40, y = 32, message = 211 },
  { page = 34, x = 40, y = 48, message = 212 },
  { page = 34, x = 40, y = 64, message = 213 },
  { page = 34, x = 40, y = 80, message = 214 },
  { page = 34, x = 40, y = 96, message = 215 },
  { page = 34, x = 40, y = 112, message = 216 },
  { page = 34, x = 40, y = 128, message = 217 },
  { page = 34, x = 40, y = 144, message = 218 },
  { page = 34, x = 40, y = 160, message = 219 },
  { page = 35, x = 40, y = 40, message = 220 },
  { page = 35, x = 40, y = 56, message = 221 },
  { page = 35, x = 40, y = 72, message = 222 },
  { page = 35, x = 40, y = 88, message = 223 },
  { page = 35, x = 40, y = 104, message = 224 },
  { page = 35, x = 40, y = 120, message = 225 },
  { page = 35, x = 40, y = 136, message = 226 },
  { page = 36, x = 20, y = 56, message = 227 },
  { page = 36, x = 40, y = 72, message = 228 },
  { page = 36, x = 40, y = 88, message = 229 },
  { page = 36, x = 40, y = 104, message = 230 },
  { page = 36, x = 40, y = 120, message = 231 },
  { page = 37, x = 20, y = 56, message = 232 },
  { page = 37, x = 40, y = 72, message = 233 },
  { page = 37, x = 40, y = 88, message = 234 },
  { page = 37, x = 40, y = 104, message = 235 },
  { page = 37, x = 40, y = 120, message = 236 },
  { page = 38, x = 20, y = 56, message = 237 },
  { page = 38, x = 40, y = 72, message = 238 },
  { page = 38, x = 40, y = 88, message = 239 },
  { page = 38, x = 40, y = 104, message = 240 },
  { page = 38, x = 40, y = 120, message = 241 },
  { page = 39, x = 20, y = 56, message = 242 },
  { page = 39, x = 40, y = 72, message = 243 },
  { page = 39, x = 40, y = 88, message = 244 },
  { page = 39, x = 40, y = 104, message = 245 },
  { page = 39, x = 40, y = 120, message = 246 },
  { page = 40, x = 20, y = 80, message = 247 },
  { page = 40, x = 40, y = 96, message = 248 },
  { page = 41, x = 20, y = 80, message = 249 },
  { page = 41, x = 40, y = 96, message = 250 },
  { page = 42, x = 20, y = 80, message = 251 },
  { page = 42, x = 40, y = 96, message = 252 },
}

---@param romFs table<string, unknown>
---@param memberId integer
---@param role string
---@return string bytes, string sha1
local function readMember(romFs, memberId, role)
  local narc =
    assert(romFs:openNarc(Compiler.creditArchive.symbol), "the League ending's source archive is unavailable")
  if memberId < 0 or memberId >= narc:memberCount() then
    Errors.raise("ENDING_SOURCE_MISSING", "League ending source member is unavailable", {
      archive = Compiler.creditArchive.symbol,
      memberId = memberId,
      count = narc:memberCount(),
      role = role,
    })
  end
  local bytes = assert(narc:readMember(memberId), "League ending source member is unreadable")
  return bytes, Hashing.sha1hex(bytes)
end

-- One source background record: an LZ-compressed character set or screen
-- tilemap from the credit archive, decoded and (for screens) rasterized over
-- the roll's shared character data and palette.
---@param romFs table<string, unknown>
---@param memberId integer
---@param role string
---@param decode function
---@return table<string, unknown> decoded, string sha1
local function decodeMember(romFs, memberId, role, decode)
  local bytes, sha1 = readMember(romFs, memberId, role)
  -- The credit archive stores its BG records with the DS BIOS compression the
  -- member's own header names: 0x10 is LZ77, 0x11 is LZ11.
  local marker = #bytes >= 1 and string.byte(bytes, 1) or nil
  local decompressed, decompressErr
  if marker == 0x10 then
    decompressed, decompressErr = Lz10.decode(bytes)
  elseif marker == 0x11 then
    decompressed, decompressErr = Lz11.decode(bytes)
  else
    -- A member stored raw already carries its decoded record.
    decompressed = bytes
  end
  if decompressed == nil then
    Errors.raise("ENDING_SOURCE_INVALID", "League ending source member could not be decompressed", {
      archive = Compiler.creditArchive.symbol,
      memberId = memberId,
      role = role,
      error = tostring(decompressErr),
    })
  end
  assert(decompressed ~= nil)
  local decoded, decodeErr = decode(decompressed, {
    archive = Compiler.creditArchive.symbol,
    memberId = memberId,
    section = role,
  })
  if decoded == nil then
    Errors.raise("ENDING_SOURCE_INVALID", "League ending source member could not be decoded", {
      archive = Compiler.creditArchive.symbol,
      memberId = memberId,
      role = role,
      error = tostring(decodeErr),
    })
  end
  ---@cast decoded -nil
  return decoded, --[[@as table<string, unknown>]]
    sha1
end

---@param data string
---@param images table<string, table<string, unknown>>
---@return table<string, unknown> published image record
local function publishImage(data, images)
  local sha1 = Hashing.sha1hex(data)
  local path = EndingAssetCache.imagePath(sha1)
  images[path] = { data = data }
  return { path = path, sha1 = sha1 }
end

-- Rasterize one screen record over the roll's shared character data and
-- palette. The source draws every scene over the same character set, so the
-- decode happens once and each scene only contributes its own tilemap.
---@param charData table<string, unknown>
---@param paletteData table<string, unknown>
---@param screenData table<string, unknown>
---@param role string
---@param images table<string, table<string, unknown>>
---@return table<string, unknown> published image record
local function rasterize(charData, paletteData, screenData, role, images)
  local image = G2dRasterizer.renderScreen(charData, paletteData, screenData, { role = role }, { backdrop = true })
  local png = PngWriter.encode(image.width, image.height, image.pixels)
  return publishImage(png, images)
end

-- The source roll's page table and message lines, as immutable records the
-- presentation reads by page.
---@return table<string, unknown>[]
local function pageTable()
  local pages = {}
  for index, timing in ipairs(PAGE_TIMINGS) do
    pages[index] = { page = index - 1, startTime = timing.startTime, duration = timing.duration, lines = {} }
  end
  for _, line in ipairs(CREDIT_LINES) do
    local page = assert(pages[line.page + 1], "a credit line names a source page")
    page.lines[#page.lines + 1] = { x = line.x, y = line.y, message = line.message }
  end
  return pages
end

-- Opens one source archive behind the registration/credit choreography. The
-- credit archive keeps its own bound helpers above; every other archive
-- resolves through these shared helpers so member identities stay explicit.
---@param romFs table<string, unknown>
---@param symbol string
---@param role string
---@return table<string, unknown> archive
local function openSourceArchive(romFs, symbol, role)
  local archive = assert(romFs:openNarc(symbol), "the League ending's source archive is unavailable: " .. symbol)
  assert(archive ~= nil, "unavailable source archives fail above: " .. role)
  return archive
end

---@param archive table<string, unknown>
---@param symbol string
---@param memberId integer
---@param role string
---@return string bytes, string sha1
local function readSourceMember(archive, symbol, memberId, role)
  if memberId < 0 or memberId >= archive:memberCount() then
    Errors.raise("ENDING_SOURCE_MISSING", "League ending source member is unavailable", {
      archive = symbol,
      memberId = memberId,
      count = archive:memberCount(),
      role = role,
    })
  end
  local bytes = assert(archive:readMember(memberId), "League ending source member is unreadable")
  return bytes, Hashing.sha1hex(bytes)
end

-- One LZ-framed source record from any archive: members name their own
-- compression (0x10 LZ77, 0x11 LZ11) or ride raw.
---@param archive table<string, unknown>
---@param symbol string
---@param memberId integer
---@param role string
---@param decode function
---@return table<string, unknown> decoded, string sha1
local function decodeSourceMember(archive, symbol, memberId, role, decode)
  local bytes, sha1 = readSourceMember(archive, symbol, memberId, role)
  local marker = #bytes >= 1 and string.byte(bytes, 1) or nil
  local decompressed, decompressErr
  if marker == 0x10 then
    decompressed, decompressErr = Lz10.decode(bytes)
  elseif marker == 0x11 then
    decompressed, decompressErr = Lz11.decode(bytes)
  else
    decompressed = bytes
  end
  if decompressed == nil then
    Errors.raise("ENDING_SOURCE_INVALID", "League ending source member could not be decompressed", {
      archive = symbol,
      memberId = memberId,
      role = role,
      error = tostring(decompressErr),
    })
  end
  assert(decompressed ~= nil)
  local decoded, decodeErr = decode(decompressed, { archive = symbol, memberId = memberId, section = role })
  if decoded == nil then
    Errors.raise("ENDING_SOURCE_INVALID", "League ending source member could not be decoded", {
      archive = symbol,
      memberId = memberId,
      role = role,
      error = tostring(decodeErr),
    })
  end
  ---@cast decoded -nil
  return decoded, sha1
end

-- Realizes every requested animation sequence of one NCER/NANR sprite group
-- into per-frame PNGs, preserving each frame's tick duration and the
-- sequence play mode. Blank source frames keep only their mark and timing
-- so the runtime draws nothing on exactly those frames.
---@param charData table<string, unknown>
---@param paletteColors table[]
---@param cellData table<string, unknown>
---@param animation table<string, unknown>
---@param seqNos integer[] zero-based sequence identities
---@param role string
---@param images table<string, table<string, unknown>>
---@return table<integer, table<string, unknown>> sequences by sequence number
local function realizeSequences(charData, paletteColors, cellData, animation, seqNos, role, images)
  local sequences = {}
  local anims = assert(animation.anims, "a sprite animation bank carries its sequences: " .. role)
  for _, seqNo in ipairs(seqNos) do
    local sequence = anims[seqNo + 1]
    if type(sequence) ~= "table" then
      Errors.raise("ENDING_SOURCE_INVALID", "a sprite animation sequence is missing", { role = role, seq = seqNo })
    end
    ---@cast sequence -nil
    local frames = {}
    for frameIndex, sourceFrame in ipairs(assert(sequence.frames, "a sprite sequence carries its frames")) do
      local duration = sourceFrame.duration
      if type(duration) ~= "number" or duration % 1 ~= 0 or duration < 0 then
        Errors.raise("ENDING_SOURCE_INVALID", "a sprite frame has invalid timing", { role = role, seq = seqNo })
      end
      local cellId = sourceFrame.cell
      local cell = type(cellId) == "number" and cellData.cells[cellId + 1] or nil
      if type(cell) == "table" and (type(cell.objs) ~= "table" or #cell.objs == 0) then
        frames[frameIndex] = { blank = true, durationTicks = duration }
      else
        local rendered = G2dRasterizer.renderAnimationFrame(
          charData,
          { colors = paletteColors },
          cellData,
          sequence,
          frameIndex,
          { role = role, seq = seqNo, frame = frameIndex - 1 },
          nil,
          nil
        )
        local png = PngWriter.encode(rendered.width, rendered.height, rendered.pixels)
        local staged = publishImage(png, images)
        local offset = rendered.offset or { x = 0, y = 0 }
        frames[frameIndex] = {
          path = staged.path,
          width = rendered.width,
          height = rendered.height,
          origin = { x = offset.x, y = offset.y },
          durationTicks = duration,
        }
      end
    end
    sequences[seqNo] = {
      playMode = sequence.playMode,
      loopStart = sequence.loopStartFrameIdx,
      frames = frames,
    }
  end
  return sequences
end

-- One decoded NCER/NANR sprite group (char/cell/anim over a palette),
-- raising before any consumer when a member is missing or undecodable.
---@param archive table<string, unknown>
---@param symbol string
---@param group { charMember: integer, cellMember: integer, animMember: integer }
---@param role string
---@return table<string, unknown> charData, table<string, unknown> cellData, table<string, unknown> animation
local function decodeSpriteGroup(archive, symbol, group, role)
  local charData = decodeSourceMember(archive, symbol, group.charMember, role .. " characters", G2dDecoder.decodeChar)
  local cellData = decodeSourceMember(archive, symbol, group.cellMember, role .. " cells", G2dDecoder.decodeCell)
  local animation =
    decodeSourceMember(archive, symbol, group.animMember, role .. " animation", G2dDecoder.decodeAnimation)
  return charData, cellData, animation
end
---@param archive table<string, unknown>
---@param symbol string
---@param memberId integer
---@param role string
---@return table[] colors
local function decodePaletteColors(archive, symbol, memberId, role)
  local paletteData = decodeSourceMember(archive, symbol, memberId, role, G2dDecoder.decodePalette)
  return assert(paletteData.colors, "a decoded palette carries its colors: " .. role)
end

-- The credit roll's dancing/cloud sprite sequences and cutscene sprites:
-- the shared dancing resources (char 1, pal 0, cell 2, anim 3) realized
-- for the dancing sequences and the cloud sequence, plus every cutscene
-- sprite's referenced sequences with the player-gender char/pal variants
-- for sprite slots 5 and 7 (LoadCutsceneSpriteGfx).
---@param romFs table<string, unknown>
---@param images table<string, table<string, unknown>>
---@return table<integer, table<string, unknown>> danceSequences, table<integer, table<string, unknown>> cutsceneSprites, table[] cutscenes
local function compileCreditsChoreography(romFs, images)
  local archive = openSourceArchive(romFs, Compiler.creditArchive.symbol, "credit sprites")
  local danceChar, danceCell, danceAnim =
    decodeSpriteGroup(archive, Compiler.creditArchive.symbol, CREDIT_SPRITE_RESOURCES, "dance")
  local dancePalette =
    decodePaletteColors(archive, Compiler.creditArchive.symbol, CREDIT_SPRITE_RESOURCES.paletteMember, "dance palette")
  local danceSequences =
    realizeSequences(danceChar, dancePalette, danceCell, danceAnim, { 0, 1, 2, 3, 4, 5, 6, CLOUD_SEQ }, "dance", images)
  -- Per-sprite referenced animation sequences across all cutscenes.
  local seqsBySprite = {}
  for _, cutscene in ipairs(CUTSCENES) do
    for _, param in ipairs(cutscene.params) do
      local spriteId = cutscene.spriteIds[param.spriteIdx + 1]
      assert(type(spriteId) == "number", "a cutscene param names its sprite")
      seqsBySprite[spriteId] = seqsBySprite[spriteId] or {}
      seqsBySprite[spriteId][param.animSeq] = true
    end
  end
  local cutsceneSprites = {}
  for spriteId = 0, #CUTSCENE_SPRITE_FILE_IDS - 1 do
    local fileIds = CUTSCENE_SPRITE_FILE_IDS[spriteId + 1]
    local seqSet = seqsBySprite[spriteId]
    if seqSet ~= nil then
      local seqNos = {}
      for seqNo in pairs(seqSet) do
        seqNos[#seqNos + 1] = seqNo
      end
      table.sort(seqNos)
      local function realizeWith(charMember, paletteMember, role)
        local charData = decodeSourceMember(
          archive,
          Compiler.creditArchive.symbol,
          charMember,
          role .. " characters",
          G2dDecoder.decodeChar
        )
        local paletteColors =
          decodePaletteColors(archive, Compiler.creditArchive.symbol, paletteMember, role .. " palette")
        local cellData = decodeSourceMember(
          archive,
          Compiler.creditArchive.symbol,
          fileIds.cellMember,
          role .. " cells",
          G2dDecoder.decodeCell
        )
        local animation = decodeSourceMember(
          archive,
          Compiler.creditArchive.symbol,
          fileIds.animMember,
          role .. " animation",
          G2dDecoder.decodeAnimation
        )
        return realizeSequences(charData, paletteColors, cellData, animation, seqNos, role, images)
      end
      local role = "cutscene sprite " .. spriteId
      local entry = { sequences = realizeWith(fileIds.charMember, fileIds.paletteMember, role) }
      -- Sprite slots 5 (player) and 7 (friend) exchange char/pal file IDs
      -- by player gender: female players and friends swap the pair.
      if spriteId == 5 or spriteId == 7 then
        local other = spriteId == 5 and CUTSCENE_SPRITE_FILE_IDS[8] or CUTSCENE_SPRITE_FILE_IDS[6]
        entry.femaleSequences = realizeWith(other.charMember, other.paletteMember, role .. " female")
      end
      cutsceneSprites[spriteId] = entry
    end
  end
  return danceSequences, cutsceneSprites, CUTSCENES
end

-- Rasterize one background screen over shared character data and palette,
-- publishing the layer image the registration scenes draw with offsets.
---@param charData table<string, unknown>
---@param paletteColors table[]
---@param archive table<string, unknown>
---@param symbol string
---@param memberId integer
---@param role string
---@param images table<string, table<string, unknown>>
---@return table<string, unknown> published image record
local function rasterizeRegistrationLayer(charData, paletteColors, archive, symbol, memberId, role, images)
  local screenData = decodeSourceMember(archive, symbol, memberId, role, G2dDecoder.decodeScreen)
  local image = G2dRasterizer.renderScreen(
    charData,
    { colors = paletteColors },
    screenData,
    { role = role },
    { backdrop = true }
  )
  return publishImage(PngWriter.encode(image.width, image.height, image.pixels), images)
end

-- The per-species picture animation scripts, cry delays and back-picture
-- heights behind the individual reveals: a180 member 0 carries one 89-byte
-- record per species (front entry 0, back entry 1), and the picture-height
-- archives carry one byte per species/form/gender/facing. Keyed by catalog
-- species key so the runtime resolves its recorded party without source
-- identities.
---@param romFs table<string, unknown>
---@return table<string, table<string, unknown>> tracks by species key
local function compileMonTracks(romFs)
  local animArchive = openSourceArchive(romFs, REGISTRATION_ANIM_ARCHIVE.symbol, "picture animation")
  if animArchive:memberCount() < 1 then
    Errors.raise("ENDING_SOURCE_MISSING", "League ending animation archive carries no records", {
      archive = REGISTRATION_ANIM_ARCHIVE.symbol,
    })
  end
  local animBytes = assert(animArchive:readMember(0), "League ending animation record is unreadable")
  local heightArchive = openSourceArchive(romFs, MonSources.PICTURE_HEIGHT_NARC, "picture heights")
  local otherHeightArchive = openSourceArchive(romFs, MonSources.PICTURE_HEIGHT_OTHER_NARC, "special picture heights")
  local tracks = {}
  for speciesId = 1, MonSources.MAX_SPECIES do
    local speciesKey = MonSources.speciesKeys[speciesId]
    if speciesKey ~= nil and speciesKey ~= "EGG" and speciesKey ~= "BAD_EGG" and speciesKey ~= "NONE" then
      local front = SummaryPictureCompiler.decodeBattleRecord(animBytes, speciesId, 0)
      local back = SummaryPictureCompiler.decodeBattleRecord(animBytes, speciesId, 1)
      local heights = {}
      for _, form in ipairs(MonSources.runtimeForms(speciesId)) do
        local byGender = {}
        for _, gender in ipairs({ "male", "female" }) do
          local heightSymbol, heightMember = MonSources.pictureHeightIds(speciesId, gender, 0, form)
          local sourceArchive = heightSymbol == MonSources.PICTURE_HEIGHT_NARC and heightArchive or otherHeightArchive
          local heightBytes =
            assert(sourceArchive:readMember(heightMember), "League ending picture height is unreadable")
          byGender[gender] = string.byte(heightBytes, 1)
        end
        heights[form] = byGender
      end
      local function bake(record)
        local steps = {}
        for _, step in ipairs(assert(record.script, "a picture record carries its script")) do
          steps[#steps + 1] = { next = step.next, duration = step.duration, xOffset = step.xOffset }
        end
        return { cryDelay = record.cryDelay, steps = steps }
      end
      tracks[speciesKey] = { front = bake(front), back = bake(back), heights = heights }
    end
  end
  return tracks
end

-- Compile the ending bundle. Every required source member resolves before any
-- section is produced, so a missing or undecodable record fails the artifact
-- instead of publishing a partial bundle.
-- The PC showcase's own backgrounds (src/hall_of_fame_showcase.c
-- HallOfFameShowcase_InitBgs): NARC_a_0_9_7 members 0/1/2 are the main
-- screen's tilemap/character set/palette and members 3/4/5 are the sub
-- screen's tilemap/character set/palette.
---@param romFs table<string, unknown>
---@param images table<string, table<string, unknown>>
---@return table<string, unknown> section
local function compileShowcase(romFs, images)
  local archive = openSourceArchive(romFs, SHOWCASE_BACKGROUND_ARCHIVE, "showcase backgrounds")
  local symbol = SHOWCASE_BACKGROUND_ARCHIVE
  local mainScreen = decodeSourceMember(archive, symbol, 0, "showcase main screen", G2dDecoder.decodeScreen)
  local mainChar = decodeSourceMember(archive, symbol, 1, "showcase main characters", G2dDecoder.decodeChar)
  local mainPalette = decodeSourceMember(archive, symbol, 2, "showcase main palette", G2dDecoder.decodePalette)
  local subScreen = decodeSourceMember(archive, symbol, 3, "showcase sub screen", G2dDecoder.decodeScreen)
  local subChar = decodeSourceMember(archive, symbol, 4, "showcase sub characters", G2dDecoder.decodeChar)
  local subPalette = decodeSourceMember(archive, symbol, 5, "showcase sub palette", G2dDecoder.decodePalette)
  local mainBg = rasterize(mainChar, mainPalette, mainScreen, "showcase-main-bg", images)
  local subBg = rasterize(subChar, subPalette, subScreen, "showcase-sub-bg", images)
  return {
    messageBank = Compiler.SHOWCASE_MESSAGE_BANK,
    mainBg = mainBg,
    subBg = subBg,
  }
end

-- The registration section: individual and whole-party background layers,
-- overworld-sprite and twinkle frame sequences, whole-party player pictures
-- for both genders, per-species animation tracks, and the spotlight and
-- confetti color tables behind the whole-party effects.
---@param romFs table<string, unknown>
---@param images table<string, table<string, unknown>>
---@return table<string, unknown> section
local function compileRegistration(romFs, images)
  local archive = openSourceArchive(romFs, REGISTRATION_ARCHIVE.symbol, "registration backgrounds")
  local spriteArchive = openSourceArchive(romFs, REGISTRATION_SPRITE_ARCHIVE.symbol, "registration sprites")
  local trainerArchive = openSourceArchive(romFs, REGISTRATION_TRAINER_ARCHIVE.symbol, "trainer pictures")
  -- Individual background layers over shared chars/palette.
  local indivChar = decodeSourceMember(
    archive,
    REGISTRATION_ARCHIVE.symbol,
    REGISTRATION_INDIV_CHAR,
    "individual background characters",
    G2dDecoder.decodeChar
  )
  local indivPalette =
    decodePaletteColors(archive, REGISTRATION_ARCHIVE.symbol, REGISTRATION_INDIV_PALETTE, "individual palette")
  local bgIndiv = {}
  for index, memberId in ipairs(REGISTRATION_INDIV_SCREENS) do
    bgIndiv[index] = rasterizeRegistrationLayer(
      indivChar,
      indivPalette,
      archive,
      REGISTRATION_ARCHIVE.symbol,
      memberId,
      "individual background layer " .. index,
      images
    )
  end
  -- Whole-party background layers over shared chars/palette.
  local wholeChar = decodeSourceMember(
    archive,
    REGISTRATION_ARCHIVE.symbol,
    REGISTRATION_WHOLE_CHAR,
    "whole-party background characters",
    G2dDecoder.decodeChar
  )
  local wholePalette =
    decodePaletteColors(archive, REGISTRATION_ARCHIVE.symbol, REGISTRATION_WHOLE_PALETTE, "whole-party palette")
  local bgWhole = {}
  for index, memberId in ipairs(REGISTRATION_WHOLE_SCREENS) do
    bgWhole[index] = rasterizeRegistrationLayer(
      wholeChar,
      wholePalette,
      archive,
      REGISTRATION_ARCHIVE.symbol,
      memberId,
      "whole-party background layer " .. index,
      images
    )
  end
  -- Follower overworld groups are intentionally not realized: the port
  -- draws the correct species' own front portrait at half scale as its
  -- documented 2D follower stand-in (the source flattens the 3D-model
  -- texture, which the port cannot rasterize), so no owSmall/owLarge
  -- animation has a draw consumer. Unused art stays out of the bundle.
  -- Twinkle sparkle frames (own char) and the shared cell/anim bank behind
  -- both the twinkle and the whole-party player. Sequence 0 only.
  local twinkleChar, twinkleCell, twinkleAnim =
    decodeSpriteGroup(archive, REGISTRATION_ARCHIVE.symbol, REGISTRATION_TWINKLE, "twinkle")
  local twinklePalette =
    decodePaletteColors(archive, REGISTRATION_ARCHIVE.symbol, REGISTRATION_TWINKLE.paletteMember, "twinkle palette")
  local twinkle = realizeSequences(twinkleChar, twinklePalette, twinkleCell, twinkleAnim, { 0 }, "twinkle", images)
  -- The whole-party player shadow reuses the twinkle char/cell/anim with
  -- the individual sprite palette (template 19), exactly like the source
  -- loads it.
  local twinkleShadowPalette = decodePaletteColors(
    spriteArchive,
    REGISTRATION_SPRITE_ARCHIVE.symbol,
    REGISTRATION_SHADOW.paletteMember,
    "twinkle shadow palette"
  )
  local twinkleShadow =
    realizeSequences(twinkleChar, twinkleShadowPalette, twinkleCell, twinkleAnim, { 0 }, "twinkle shadow", images)
  -- Whole-party player pictures: trainer front pixels over the shared
  -- twinkle cell/anim bank, one variant per player gender.
  local function realizePlayer(classId, role)
    local charData = decodeSourceMember(
      trainerArchive,
      REGISTRATION_TRAINER_ARCHIVE.symbol,
      classId * TRAINER_MEMBERS_PER_CLASS + TRAINER_CHAR_OFFSET,
      role .. " characters",
      G2dDecoder.decodeChar
    )
    local paletteColors = decodePaletteColors(
      trainerArchive,
      REGISTRATION_TRAINER_ARCHIVE.symbol,
      classId * TRAINER_MEMBERS_PER_CLASS + TRAINER_PALETTE_OFFSET,
      role .. " palette"
    )
    return realizeSequences(charData, paletteColors, twinkleCell, twinkleAnim, { 0 }, role, images)
  end
  local playerEthan = realizePlayer(TRAINER_ETHAN_CLASS, "player ethan")
  local playerLyra = realizePlayer(TRAINER_LYRA_CLASS, "player lyra")
  -- Individual-scene shadow scaffolding frames (pixels are the generic
  -- shadow blob; palettes are source silhouette constants at runtime).
  -- Sequence 0 only: shadows never select another animation sequence.
  local shadowChar, shadowCell, shadowAnim =
    decodeSpriteGroup(spriteArchive, REGISTRATION_SPRITE_ARCHIVE.symbol, REGISTRATION_SHADOW, "shadow")
  local shadowPalette = decodePaletteColors(
    spriteArchive,
    REGISTRATION_SPRITE_ARCHIVE.symbol,
    REGISTRATION_SHADOW.paletteMember,
    "shadow palette"
  )
  local shadow = realizeSequences(shadowChar, shadowPalette, shadowCell, shadowAnim, { 0 }, "shadow", images)
  local monTracks = compileMonTracks(romFs)
  return {
    messageBank = Compiler.REGISTRATION_MESSAGE_BANK,
    bgIndiv = bgIndiv,
    bgWhole = bgWhole,
    twinkle = twinkle,
    twinkleShadow = twinkleShadow,
    playerEthan = playerEthan,
    playerLyra = playerLyra,
    shadow = shadow,
    monTracks = monTracks,
    spotlightColors = SPOTLIGHT_COLORS,
    confettiColors = CONFETTI_COLORS,
    flashFrames = Compiler.REGISTRATION_FLASH_FRAMES,
    reflashFrames = Compiler.REGISTRATION_REFLASH_FRAMES,
    fadeFrames = Compiler.REGISTRATION_FADE_FRAMES,
    flashSe = Compiler.REGISTRATION_FLASH_SE,
    kanseiSe = Compiler.REGISTRATION_KANSEI_SE,
    bgm = Compiler.REGISTRATION_BGM,
  }
end

-- Every message bank the bundle's own sections read: the registration and
-- showcase applications and the credit roll.
---@return table<string, unknown>[] dependencies
function Compiler.dependencies()
  return {
    { kind = "message-bank", key = tostring(Compiler.REGISTRATION_MESSAGE_BANK) },
    { kind = "message-bank", key = tostring(Compiler.SHOWCASE_MESSAGE_BANK) },
    { kind = "message-bank", key = tostring(Compiler.CREDITS_MESSAGE_BANK) },
    -- Drawn alongside the bundle's own banks: the save-status window
    -- (bank 40) and the localized species/move names the showcase paints
    -- (banks 237 and 750), plus the month abbrev behind the showcase header
    -- (bank 239). An explicit dependency keeps draw-time lookups provisioned
    -- instead of falling back at draw time.
    { kind = "message-bank", key = "40" },
    { kind = "message-bank", key = "237" },
    { kind = "message-bank", key = "750" },
    { kind = "message-bank", key = "239" },
  }
end

---@param romFs table<string, unknown>
---@return { sections: table<string, unknown>, images: table<string, table<string, unknown>>, hashes: table<string, string>, provenance: table<string, unknown>, marker: string }
function Compiler.compile(romFs)
  assert(romFs and romFs.openNarc, "the League ending compiler requires the imported ROM tree")
  local charData, charSha1 = decodeMember(romFs, BG_CHAR_MEMBER, "credit background characters", G2dDecoder.decodeChar)
  local paletteData, paletteSha1 =
    decodeMember(romFs, BG_PALETTE_MEMBER, "credit background palette", G2dDecoder.decodePalette)
  local theEndChars, theEndCharSha1 =
    decodeMember(romFs, THE_END_CHAR_MEMBER, "The End characters", G2dDecoder.decodeChar)
  local theEndScreen, theEndScreenSha1 =
    decodeMember(romFs, THE_END_SCREEN_MEMBER, "The End screen", G2dDecoder.decodeScreen)
  local images = {}
  local scenes = {}
  for index = 1, #BG2_SCREEN_MEMBERS do
    local lower =
      decodeMember(romFs, BG2_SCREEN_MEMBERS[index], "credit scene " .. index .. " lower", G2dDecoder.decodeScreen)
    local upper =
      decodeMember(romFs, BG3_SCREEN_MEMBERS[index], "credit scene " .. index .. " upper", G2dDecoder.decodeScreen)
    scenes[index] = {
      index = index - 1,
      lower = rasterize(charData, paletteData, lower, "credit-scene-" .. index .. "-lower", images),
      upper = rasterize(charData, paletteData, upper, "credit-scene-" .. index .. "-upper", images),
    }
  end
  local theEnd = rasterize(theEndChars, paletteData, theEndScreen, "credit-the-end", images)
  local registration = compileRegistration(romFs, images)
  local showcase = compileShowcase(romFs, images)
  local danceSequences, cutsceneSprites, cutscenes = compileCreditsChoreography(romFs, images)
  local sections = {
    registration = registration,
    showcase = showcase,
    credits = {
      frames = Compiler.CREDITS_FRAMES,
      musicBoxWaitFrames = Compiler.MUSIC_BOX_WAIT_FRAMES,
      messageBank = Compiler.CREDITS_MESSAGE_BANK,
      titleMessages = { heartgold = Compiler.TITLE_MESSAGE.heartgold, soulsilver = Compiler.TITLE_MESSAGE.soulsilver },
      sceneTransitionTimings = SCENE_TRANSITION_TIMINGS,
      screenFlipTimings = SCREEN_FLIP_TIMINGS,
      danceSequences = danceSequences,
      danceSeqsByScene = DANCE_SEQS_BY_SCENE,
      cloudSeq = CLOUD_SEQ,
      cutsceneSprites = cutsceneSprites,
      cutscenes = cutscenes,
      pages = pageTable(),
      scenes = scenes,
      theEnd = theEnd,
    },
  }
  local metadata = assert(romFs:metadata(), "the League ending bundle needs its source identity")
  assert(type(metadata.sha1) == "string", "the League ending bundle needs the source ROM SHA-1")
  local dependencies = Compiler.dependencies()
  local dependencyHash = Hashing.hashLua(dependencies)
  local archiveInfo = assert(romFs:resolvedNarc(Compiler.creditArchive.symbol), "the credit archive resolves")
  local registrationArchiveInfo =
    assert(romFs:resolvedNarc(REGISTRATION_ARCHIVE.symbol), "the registration archive resolves")
  local registrationSpriteArchiveInfo =
    assert(romFs:resolvedNarc(REGISTRATION_SPRITE_ARCHIVE.symbol), "the registration sprite archive resolves")
  local registrationAnimArchiveInfo =
    assert(romFs:resolvedNarc(REGISTRATION_ANIM_ARCHIVE.symbol), "the picture animation archive resolves")
  local registrationTrainerArchiveInfo =
    assert(romFs:resolvedNarc(REGISTRATION_TRAINER_ARCHIVE.symbol), "the trainer picture archive resolves")
  return {
    sections = sections,
    images = images,
    hashes = {
      characters = charSha1,
      palette = paletteSha1,
      theEndCharacters = theEndCharSha1,
      theEndScreen = theEndScreenSha1,
    },
    provenance = {
      cacheFormat = Contract.ending.format,
      schema = Contract.ending.indexSchema,
      versionRomSha1 = metadata.sha1,
      dependencyHash = dependencyHash,
      source = {
        credits = {
          alias = Compiler.creditArchive.symbol,
          narcId = archiveInfo.narcId,
          path = archiveInfo.path,
        },
        -- Realized (not provenance-only) source art: the registration and
        -- credit choreography above consumes these members, so the bundle
        -- is complete only with them extracted.
        registrationArt = {
          backgroundArchive = REGISTRATION_ARCHIVE.symbol,
          backgroundMembers = {
            unpack(REGISTRATION_INDIV_SCREENS),
            REGISTRATION_INDIV_CHAR,
            REGISTRATION_INDIV_PALETTE,
            unpack(REGISTRATION_WHOLE_SCREENS),
            REGISTRATION_WHOLE_CHAR,
            REGISTRATION_WHOLE_PALETTE,
            REGISTRATION_TWINKLE.charMember,
            REGISTRATION_TWINKLE.cellMember,
            REGISTRATION_TWINKLE.animMember,
            REGISTRATION_TWINKLE.paletteMember,
          },
          backgroundNarcId = registrationArchiveInfo.narcId,
          spriteArchive = REGISTRATION_SPRITE_ARCHIVE.symbol,
          spriteMembers = {
            REGISTRATION_SHADOW.charMember,
            REGISTRATION_SHADOW.cellMember,
            REGISTRATION_SHADOW.animMember,
            REGISTRATION_SHADOW.paletteMember,
          },
          spriteNarcId = registrationSpriteArchiveInfo.narcId,
          animArchive = REGISTRATION_ANIM_ARCHIVE.symbol,
          animNarcId = registrationAnimArchiveInfo.narcId,
          trainerArchive = REGISTRATION_TRAINER_ARCHIVE.symbol,
          trainerNarcId = registrationTrainerArchiveInfo.narcId,
        },
        showcaseArt = {
          backgroundArchive = SHOWCASE_BACKGROUND_ARCHIVE,
          backgroundMembers = { 0, 1, 2, 3, 4, 5 },
        },
        creditSprites = CREDIT_SPRITE_RESOURCES,
        creditCutscenes = CUTSCENE_RESOURCES,
      },
      dependencies = dependencies,
    },
    marker = EndingAssetCache.marker(metadata.sha1, dependencyHash),
  }
end

return Compiler
