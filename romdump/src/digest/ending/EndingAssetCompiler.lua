-- Compiles the League ending's own source bundle: the Hall of Fame
-- registration application's text, the PC showcase's text, and the credit roll
-- with its backgrounds, "The End" screen, page timings and message lines.
--
-- Everything here is transcribed from the retail sources the port pins:
--   * src/credits/credits.c: CREDITS_FRAMES, MUSIC_BOX_WAIT_FRAMES, the
--     message bank the roll reads (NARC_msgdata_msg member 0x1b8) and the
--     game-title message index, and the six background scene layers with their
--     shared character data and palette from NARC_a_2_6_3;
--   * include/credits/data.h: sSceneTransitionTimings, sScreenFlipTimings,
--     sCreditsBg2ScrnFileIds, sCreditsBg3ScrnFileIds, sPageTimings and
--     sCreditMsgLines;
--   * src/register_hall_of_fame.c: the registration application's message bank
--     (msg_0180) and its per-member reveal cadence;
--   * the PC showcase's own message bank (msg_0181).
-- The roll's OAM sprite and cutscene choreography is not compiled: the port has
-- no OAM cell/animation renderer, so this bundle carries the parts a
-- presentation can actually draw (backgrounds, text roll, The End).
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

-- src/register_hall_of_fame.c: every member's reveal runs its own sub-scene
-- chain (back picture, overworld sprite, header window, front picture) before
-- the whole-party scene waits for the player. The cadence below is the source
-- sub-scene frame count per member.
Compiler.REGISTRATION_MEMBER_FRAMES = 84

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

-- Compile the ending bundle. Every required source member resolves before any
-- section is produced, so a missing or undecodable record fails the artifact
-- instead of publishing a partial bundle.
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
    -- (banks 237 and 750). An explicit dependency keeps draw-time lookups
    -- provisioned instead of falling back at draw time.
    { kind = "message-bank", key = "40" },
    { kind = "message-bank", key = "237" },
    { kind = "message-bank", key = "750" },
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
  local sections = {
    registration = {
      messageBank = Compiler.REGISTRATION_MESSAGE_BANK,
      memberFrames = Compiler.REGISTRATION_MEMBER_FRAMES,
    },
    showcase = {
      messageBank = Compiler.SHOWCASE_MESSAGE_BANK,
    },
    credits = {
      frames = Compiler.CREDITS_FRAMES,
      musicBoxWaitFrames = Compiler.MUSIC_BOX_WAIT_FRAMES,
      messageBank = Compiler.CREDITS_MESSAGE_BANK,
      titleMessages = { heartgold = Compiler.TITLE_MESSAGE.heartgold, soulsilver = Compiler.TITLE_MESSAGE.soulsilver },
      sceneTransitionTimings = SCENE_TRANSITION_TIMINGS,
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
      },
      dependencies = dependencies,
    },
    marker = EndingAssetCache.marker(metadata.sha1, dependencyHash),
  }
end

return Compiler
