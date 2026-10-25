-- Source-backed battle presentation production: the shared ordinary
-- menu/HUD definitions plus lazily compiled persistent BG3 scenes. Source
-- selection follows the retail ROM's battle background selection; container
-- and animation layouts follow GBATEK's "Nitro Character Tiles / BG Maps
-- Screens / OBJ Animations / OBJ Metatile Cells" pages. Decoding reuses the
-- existing G2D primitives (including the retail-tail producer option for
-- the background CHAR family); this module only selects members, bakes
-- terrain, and stages semantic records with image buffers. Pure module: no
-- LOVE objects, no filesystem writes; callers publish through the
-- battle-presentation cache paths.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")
local U32 = require("libs.codec.src.U32")
local Hashing = require("romdump.src.digest.Hashing")
local Lz10 = require("romdump.src.digest.Lz10")
local MonSources = require("romdump.src.config.MonSources")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local TransitionCellNormalizer = require("romdump.src.digest.battle.TransitionCellNormalizer")
local PngWriter = require("libs.assets.src.PngWriter")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local UiMessageBank = require("romdump.src.digest.ui.UiMessageBank")
local charmap = require("romdump.src.catalog.hgss.charmap")
local BattlePresentationSources = require("romdump.src.config.BattlePresentationSources")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local BattlePresentationSchema = require("libs.assets.src.battle.BattlePresentationSchema")
local Spl = require("libs.nds.src.nitro.particle.Spl")
local Rgb555 = require("libs.codec.src.Rgb555")
local bit = require("bit")

---@class BattlePresentationCompiler
local BattlePresentationCompiler = {}

---@class BattlePresentationEffectProgram one executable normalized program
---@field entry string entry label
---@field instructions BattleAnimationInstruction[] normalized instructions in order
---@field subprograms table<string, unknown> named subprograms by key
---@field taskKinds string[] required task kinds in order

---@class BattlePresentationEffect one compiled effect artifact record
---@field schema string effect schema identity
---@field key string flat semantic effect key
---@field catalogIdentity string catalog generation identity
---@field program BattlePresentationEffectProgram executable normalized program
---@field dependencies string[] closed dependency keys in order
---@field resources table<string, { kind: string, contentIdentity: string, payload: string }> owned resource descriptors by key
---@field resourcePayloads table<string, table<string, unknown>> decoded payloads keyed by cache-relative path; build-only
---@field provenance table<string, unknown> producer-only physical source selections
---@field requiredContext table<string, string|number|boolean> typed context parameters

local provenanceRoles

BattlePresentationCompiler.CANVAS_WIDTH = 512
BattlePresentationCompiler.CANVAS_HEIGHT = 256

local SUPPORTED_VERSIONS = { heartgold = true, soulsilver = true }

local Sources = BattlePresentationSources
local ROLES = Sources.ROLES

-- Normalized native particle emission. APS12_1 emitter words become
-- source-independent typed emitter state plus exact RGBA drawables; no
-- raw container record crosses into staged payloads. The container
-- decoder owns the section/calculation vocabulary; the committed flags
-- inventory below owns every emitter flags word observed across the
-- canonical particle archive, so a novel combination fails the effect
-- instead of staging invented motion. Texture texels are 8-bit indices
-- into the staged partial palette; index zero is transparent per DS 2D
-- convention and out-of-range indices stage transparent.

-- Section/calculation selector bits shared with the container decoder
-- (libs.nds.src.nitro.particle.Spl): only these bits select trailing
-- emitter data, every other set bit is an inline emitter parameter.
local PARTICLE_SELECTOR_BITS = { 8, 9, 10, 11, 16, 24, 25, 26, 27, 28, 29 }

local KNOWN_PARTICLE_EMITTER_FLAG_WORDS = {
  0x00004312,
  0x00004400,
  0x00004500,
  0x00004503,
  0x00004513,
  0x00004600,
  0x00004611,
  0x00004641,
  0x00004642,
  0x00004700,
  0x00004701,
  0x00004702,
  0x00004704,
  0x00004710,
  0x00004711,
  0x00004712,
  0x00004742,
  0x00004752,
  0x00004756,
  0x00004796,
  0x000047c6,
  0x00004e15,
  0x00004e51,
  0x00004f00,
  0x00004f15,
  0x00004f53,
  0x00005700,
  0x00005702,
  0x00005740,
  0x00005741,
  0x00006700,
  0x00006702,
  0x00006746,
  0x00006f00,
  0x00006f41,
  0x00007702,
  0x00007705,
  0x00007707,
  0x00007712,
  0x00007798,
  0x00008042,
  0x00008440,
  0x00008706,
  0x00008716,
  0x00009740,
  0x0000c7d6,
  0x0000e700,
  0x00014100,
  0x00014443,
  0x00014500,
  0x00014501,
  0x00014502,
  0x00014503,
  0x00014510,
  0x00014511,
  0x00014547,
  0x00014586,
  0x00014600,
  0x00014601,
  0x00014610,
  0x00014700,
  0x00014701,
  0x00014702,
  0x00014703,
  0x00014704,
  0x00014705,
  0x00014710,
  0x00014711,
  0x00014712,
  0x00014740,
  0x00014741,
  0x00014742,
  0x00014745,
  0x00014786,
  0x00014792,
  0x000147c3,
  0x00014f00,
  0x00014f01,
  0x00014f02,
  0x00015500,
  0x00015502,
  0x00015700,
  0x00015701,
  0x00015702,
  0x00015706,
  0x00015710,
  0x00015742,
  0x000157c2,
  0x000157c3,
  0x00015f00,
  0x00016500,
  0x00016501,
  0x00016700,
  0x00016701,
  0x00016702,
  0x00016705,
  0x00016706,
  0x00016741,
  0x00016743,
  0x00016786,
  0x00017401,
  0x00017540,
  0x00017601,
  0x00017700,
  0x00017702,
  0x00017706,
  0x00017741,
  0x00017746,
  0x00017747,
  0x00018700,
  0x00018702,
  0x00019f00,
  0x0001b700,
  0x0001c7c3,
  0x00024f05,
  0x00034705,
  0x000b6700,
  0x00202700,
  0x00204000,
  0x00204012,
  0x00204100,
  0x00204101,
  0x00204148,
  0x00204186,
  0x00204283,
  0x00204300,
  0x00204400,
  0x00204442,
  0x00204500,
  0x00204505,
  0x00204510,
  0x00204543,
  0x00204596,
  0x00204600,
  0x00204612,
  0x00204613,
  0x00204686,
  0x00204695,
  0x00204700,
  0x00204701,
  0x00204702,
  0x00204706,
  0x00204710,
  0x00204711,
  0x00204712,
  0x00204713,
  0x00204716,
  0x00204740,
  0x00204746,
  0x00204752,
  0x00204786,
  0x00204900,
  0x00204b00,
  0x00204c00,
  0x00204d00,
  0x00204d11,
  0x00204d86,
  0x00204e10,
  0x00204f00,
  0x00204f01,
  0x00204f12,
  0x00204f57,
  0x00205141,
  0x00205400,
  0x00205500,
  0x00205600,
  0x00205700,
  0x00205701,
  0x00205705,
  0x00205742,
  0x00205747,
  0x00205d00,
  0x00205f00,
  0x00205f03,
  0x00206546,
  0x00206596,
  0x00206700,
  0x00206701,
  0x00206702,
  0x00206715,
  0x00206741,
  0x00206746,
  0x00206786,
  0x002067c2,
  0x00206d46,
  0x00207502,
  0x00207600,
  0x00207700,
  0x00207701,
  0x00207702,
  0x00207703,
  0x00207705,
  0x00207711,
  0x00207742,
  0x00207746,
  0x00207786,
  0x002077c6,
  0x00207e03,
  0x00208000,
  0x00208100,
  0x00208300,
  0x00208400,
  0x00208500,
  0x00208601,
  0x00208700,
  0x00208702,
  0x00208f00,
  0x00209600,
  0x0020b302,
  0x0020b500,
  0x0020c514,
  0x0020c600,
  0x0020c711,
  0x0020c714,
  0x0020e7d2,
  0x00214000,
  0x00214002,
  0x00214142,
  0x00214200,
  0x00214312,
  0x00214342,
  0x00214400,
  0x00214500,
  0x00214501,
  0x00214502,
  0x00214503,
  0x00214542,
  0x00214546,
  0x002146c3,
  0x00214700,
  0x00214701,
  0x00214702,
  0x00214711,
  0x00214712,
  0x00214740,
  0x00214742,
  0x00214791,
  0x00214e11,
  0x00214f00,
  0x00215000,
  0x00215200,
  0x00215300,
  0x00215303,
  0x00215500,
  0x00215600,
  0x00215640,
  0x00215700,
  0x00215701,
  0x00215702,
  0x00215720,
  0x002157c3,
  0x00216402,
  0x00216501,
  0x00216600,
  0x00216701,
  0x00216702,
  0x00216f01,
  0x00216f02,
  0x00216f11,
  0x00217502,
  0x00217642,
  0x00217701,
  0x00218000,
  0x00218200,
  0x00218700,
  0x00219700,
  0x0021b500,
  0x0021b600,
  0x0021b700,
  0x0021c7d2,
  0x00226d01,
  0x00284546,
  0x00284740,
  0x00284783,
  0x00284f40,
  0x00294740,
  0x00294766,
  0x00298500,
  0x00298700,
  0x00414505,
  0x00414600,
  0x00414796,
  0x00418702,
  0x00614500,
  0x00614700,
  0x00614712,
  0x00615702,
  0x00619700,
  0x00694546,
  0x00694786,
  0x01004700,
  0x01004701,
  0x01004705,
  0x01004706,
  0x01004710,
  0x01004712,
  0x01004752,
  0x01005700,
  0x01005742,
  0x01006701,
  0x01007600,
  0x01007606,
  0x01007701,
  0x01007702,
  0x01014510,
  0x01014600,
  0x01014700,
  0x01014701,
  0x01014702,
  0x01014704,
  0x01014706,
  0x01014710,
  0x01014711,
  0x01015600,
  0x01015741,
  0x01016700,
  0x01016701,
  0x01016f11,
  0x01017642,
  0x01017700,
  0x01017701,
  0x01017702,
  0x01017742,
  0x01017791,
  0x01017f00,
  0x01018700,
  0x01018710,
  0x01204001,
  0x01204100,
  0x01204400,
  0x01204501,
  0x01204612,
  0x01204642,
  0x01204656,
  0x01204702,
  0x01204706,
  0x01204710,
  0x01204717,
  0x01204746,
  0x01204748,
  0x01204758,
  0x01204786,
  0x01205500,
  0x01205700,
  0x01206543,
  0x01206700,
  0x01207206,
  0x012074c6,
  0x01207502,
  0x01207540,
  0x01207601,
  0x01207642,
  0x01207646,
  0x012076c1,
  0x012076c6,
  0x01207700,
  0x01207702,
  0x01207742,
  0x01207e01,
  0x01207f05,
  0x01214542,
  0x01214546,
  0x01214708,
  0x01214711,
  0x01214712,
  0x01214743,
  0x01215400,
  0x01215700,
  0x01216f11,
  0x01217006,
  0x01217402,
  0x01217642,
  0x01217700,
  0x01217701,
  0x01217742,
  0x01217c43,
  0x01227f01,
  0x01227f46,
  0x01417606,
  0x01807501,
  0x02204700,
  0x02205746,
  0x02205f02,
  0x02206d01,
  0x02214701,
  0x02225f26,
  0x03214f46,
  0x03227741,
  0x03227f41,
  0x03235f41,
  0x03237f41,
  0x04004611,
  0x04004792,
  0x04004f51,
  0x04014500,
  0x04014501,
  0x04014511,
  0x04014512,
  0x04014546,
  0x04014682,
  0x04014700,
  0x04014701,
  0x04014702,
  0x04014711,
  0x04014712,
  0x04014782,
  0x04014792,
  0x04204400,
  0x04204500,
  0x04204700,
  0x04204702,
  0x04204711,
  0x04204712,
  0x04204c00,
  0x04204d00,
  0x04204d12,
  0x04205f00,
  0x04206600,
  0x04214500,
  0x04214711,
  0x04215400,
  0x04215600,
  0x04216600,
  0x04217782,
  0x04614712,
  0x05225400,
  0x08004200,
  0x08004603,
  0x08004701,
  0x08004704,
  0x08014500,
  0x08014502,
  0x08014503,
  0x08014542,
  0x08014543,
  0x08014602,
  0x08014642,
  0x08014643,
  0x08014646,
  0x08014700,
  0x08014703,
  0x08014741,
  0x08014742,
  0x08014746,
  0x080147c2,
  0x080147c3,
  0x08014f01,
  0x08015703,
  0x08015746,
  0x08015f02,
  0x08016783,
  0x08017702,
  0x08017746,
  0x0801bf46,
  0x080b4700,
  0x080b6702,
  0x08204001,
  0x08204100,
  0x08204103,
  0x08204500,
  0x08204600,
  0x08204700,
  0x08204702,
  0x08204716,
  0x08204c00,
  0x08205500,
  0x08205703,
  0x08206601,
  0x08206c01,
  0x08206d46,
  0x08207742,
  0x08207746,
  0x08214000,
  0x08214002,
  0x08214003,
  0x08214301,
  0x08214400,
  0x08214543,
  0x08214700,
  0x08214702,
  0x08214743,
  0x08214d00,
  0x08214f02,
  0x08215303,
  0x08215700,
  0x08217402,
  0x08217543,
  0x08217702,
  0x08224763,
  0x08227622,
  0x08415200,
  0x08417703,
  0x090145c3,
  0x09204500,
  0x09207741,
  0x09214d43,
  0x09225740,
  0x0a204f00,
  0x0c204703,
  0x0c204d12,
  0x0c214746,
  0x0d015703,
  0x0d204700,
  0x20004010,
  0x20014500,
  0x20014540,
  0x20014701,
  0x20014744,
  0x20014781,
  0x20015700,
  0x20018000,
  0x200b8703,
  0x20204411,
  0x20204501,
  0x20204502,
  0x20204600,
  0x20204710,
  0x20204780,
  0x20205740,
  0x20207701,
  0x20214400,
  0x20214700,
  0x20214702,
  0x20214750,
  0x20214f02,
  0x20215740,
  0x21014796,
  0x21205600,
  0x21214743,
  0x22004f10,
  0x24004742,
  0x24006744,
  0x24014700,
  0x24016744,
  0x24204400,
  0x24214200,
  0x24214400,
  0x24214600,
  0x25204402,
  0x28014742,
  0x28015701,
  0x28017501,
  0x28204500,
  0x28204702,
  0x30207702,
  0x81007749,
  -- Synthetic fixture word behind the repo's own headerless particle
  -- tests: selector-only, never observed in ROM data.
  0x03000a00,
}

local KNOWN_PARTICLE_EMITTER_FLAGS = {}
for _, word in ipairs(KNOWN_PARTICLE_EMITTER_FLAG_WORDS) do
  KNOWN_PARTICLE_EMITTER_FLAGS[word] = true
end

---@param flags integer raw emitter flags word under splitting
---@return integer inline parameter bits with every selector bit cleared
local function clearParticleSelectorBits(flags)
  local remainder = math.floor(flags)
  for _, bitPos in ipairs(PARTICLE_SELECTOR_BITS) do
    local bitValue = 2 ^ bitPos
    if math.floor(remainder / bitValue) % 2 == 1 then
      remainder = math.floor(remainder - bitValue)
    end
  end
  return remainder
end

---@param paletteBytes string raw RGB555 palette pairs
---@param provenance table<string, unknown> source coordinates for failures
---@return { r: integer, g: integer, b: integer }[] staged palette colors
local function decodeParticlePalette(paletteBytes, provenance)
  if #paletteBytes < 2 or #paletteBytes % 2 ~= 0 or #paletteBytes > 512 then
    error(
      Errors.new("BATTLE_PARTICLE_RESOURCE_INVALID", "particle palette length is not RGB555 pairs", {
        paletteBytes = #paletteBytes,
        archiveSymbol = provenance.archiveSymbol,
        memberId = provenance.memberId,
      }),
      0
    )
  end
  local colors = {}
  for offset = 1, #paletteBytes, 2 do
    local word = string.byte(paletteBytes, offset) + string.byte(paletteBytes, offset + 1) * 256
    colors[#colors + 1] = Rgb555.decode(word)
  end
  return colors
end

---@param textureBytes string raw indexed texels
---@param textureFlags integer source resource flags word (0 selects size inference)
---@param paletteColors integer staged palette entry count
---@param provenance table<string, unknown> source coordinates for failures
---@return integer width, integer height staged drawable dimensions
---@return integer bits bits per texel behind the pixel expansion
local function particleTextureDimensions(textureBytes, textureFlags, paletteColors, provenance)
  if textureFlags ~= 0 then
    local widthCode = math.floor(textureFlags / 256) % 16
    local heightCode = math.floor(textureFlags / 16) % 16
    if widthCode > 7 or heightCode > 7 then
      error(
        Errors.new("BATTLE_PARTICLE_RESOURCE_INVALID", "particle texture size code is outside hardware range", {
          textureFlags = string.format("0x%x", textureFlags),
          archiveSymbol = provenance.archiveSymbol,
          memberId = provenance.memberId,
        }),
        0
      )
    end
    local width = 8 * math.floor(2 ^ widthCode)
    local height = 8 * math.floor(2 ^ heightCode)
    if #textureBytes ~= width * height then
      error(
        Errors.new("BATTLE_PARTICLE_RESOURCE_INVALID", "particle texture length mismatches its dimensions", {
          textureBytes = #textureBytes,
          width = width,
          height = height,
          archiveSymbol = provenance.archiveSymbol,
          memberId = provenance.memberId,
        }),
        0
      )
    end
    return width, height, 8
  end
  local found = nil
  local solutions = 0
  for _, bits in ipairs({ 1, 2, 4, 8 }) do
    if paletteColors == 2 ^ bits then
      for _, width in ipairs({ 8, 16, 32, 64, 128, 256, 512, 1024 }) do
        for _, height in ipairs({ 8, 16, 32, 64, 128, 256, 512, 1024 }) do
          if width * height * bits / 8 == #textureBytes then
            solutions = solutions + 1
            found = { width = width, height = height, bits = bits }
          end
        end
      end
    end
  end
  if solutions ~= 1 or found == nil then
    error(
      Errors.new("BATTLE_PARTICLE_RESOURCE_INVALID", "headerless particle texture has no unique dimensions", {
        textureBytes = #textureBytes,
        paletteColors = paletteColors,
        archiveSymbol = provenance.archiveSymbol,
        memberId = provenance.memberId,
      }),
      0
    )
  end
  return found.width, found.height, found.bits
end

---@param textureBytes string raw indexed texels
---@param width integer staged drawable width
---@param height integer staged drawable height
---@param bits integer bits per texel behind the pixel expansion
---@param colors { r: integer, g: integer, b: integer }[] staged palette colors
---@return string row-major straight-alpha RGBA8888 bytes
local function decodeParticleRgba(textureBytes, width, height, bits, colors)
  local perByte = 8 / bits
  assert(#textureBytes * perByte == width * height, "particle texels fill their drawable")
  local mask = 2 ^ bits - 1
  local parts = {}
  for index = 1, #textureBytes do
    local packed = string.byte(textureBytes, index)
    for slot = 0, perByte - 1 do
      local texel = math.floor(packed / 2 ^ (slot * bits)) % (mask + 1)
      local color = nil
      if texel ~= 0 then
        color = colors[texel + 1]
      end
      if color == nil then
        parts[#parts + 1] = "\0\0\0\0"
      else
        parts[#parts + 1] = string.char(color.r, color.g, color.b, 255)
      end
    end
  end
  return table.concat(parts)
end

---@param charData { depth: integer, tiles: string } decoded lower BG characters
---@param paletteData { colors: table[] } decoded lower BG palette
---@param screenData { width: integer, height: integer, entries: table[] } decoded menu tilemap
---@param patch { left: integer, top: integer, right: integer, bottom: integer, offset: integer } inclusive source tile rectangle and raw map offset
---@return { width: integer, height: integer, pixels: string } cropped state art for the patched source map region
function BattlePresentationCompiler.compileMenuFeedbackPatch(charData, paletteData, screenData, patch)
  assert(patch.left >= 0 and patch.top >= 0, "menu feedback bounds begin inside the source tilemap")
  assert(patch.right >= patch.left and patch.bottom >= patch.top, "menu feedback bounds are ordered")
  assert(
    patch.right < screenData.width / 8 and patch.bottom < screenData.height / 8,
    "menu feedback bounds fit the source tilemap"
  )
  assert(patch.offset >= 0 and patch.offset <= 0xffff, "menu feedback uses a source 16-bit map offset")
  local columns = screenData.width / 8
  local entries = {}
  for index, entry in ipairs(screenData.entries) do
    entries[index] = entry
  end
  for tileY = patch.top, patch.bottom do
    for tileX = patch.left, patch.right do
      local index = tileY * columns + tileX + 1
      local entry = screenData.entries[index]
      local raw = entry.tile + (entry.flipH and 1024 or 0) + (entry.flipV and 2048 or 0) + entry.palette * 4096
      local patched = raw + patch.offset
      assert(patched <= 0xffff, "menu feedback map offset fits the source entry")
      entries[index] = {
        tile = patched % 1024,
        flipH = math.floor(patched / 1024) % 2 == 1,
        flipV = math.floor(patched / 2048) % 2 == 1,
        palette = math.floor(patched / 4096),
      }
    end
  end
  local raster = G2dRasterizer.renderScreen(charData, paletteData, {
    width = screenData.width,
    height = screenData.height,
    entries = entries,
  })
  local patchWidth = (patch.right - patch.left + 1) * 8
  local patchHeight = (patch.bottom - patch.top + 1) * 8
  local rowBytes = patchWidth * 4
  local rows = {}
  for y = patch.top * 8, (patch.bottom + 1) * 8 - 1 do
    local start = (y * screenData.width + patch.left * 8) * 4 + 1
    rows[#rows + 1] = raster.pixels:sub(start, start + rowBytes - 1)
  end
  return { width = patchWidth, height = patchHeight, pixels = table.concat(rows) }
end

---@generic T
---@param value T?
---@param err unknown?
---@return T
local function must(value, err)
  if value == nil then
    error(err, 0)
  end
  return value
end

---@param romFs RomFs
---@param symbol string NARC symbol or alias
---@param role string diagnostic role
---@return Narc archive
local function openArchive(romFs, symbol, role)
  local archive, openErr = romFs:openNarc(symbol)
  if archive == nil then
    if Errors.is(openErr) then
      error(openErr, 0)
    end
    error(
      Errors.new(
        "BATTLE_ARCHIVE_UNAVAILABLE",
        "battle presentation archive " .. symbol .. " is unavailable (" .. role .. ")",
        {
          symbol = symbol,
          role = role,
        }
      ),
      0
    )
  end
  return archive
end

---@param archive Narc
---@param memberId integer
---@param label string source role for diagnostics
---@return string member bytes, LZ-unwrapped when wrapped
local function decodeMember(archive, memberId, label)
  local member, err = archive:readMember(memberId)
  if member == nil then
    if Errors.is(err) then
      error(err, 0)
    end
    error(
      Errors.new("BATTLE_MEMBER_MISSING", label .. " member " .. memberId .. " is absent", {
        member = memberId,
        label = label,
      }),
      0
    )
  end
  assert(member ~= nil, "the source member carries bytes")
  if string.byte(member, 1) == 0x10 then
    local plain, lzErr = Lz10.decode(member)
    if plain == nil then
      local causeCode
      if Errors.is(lzErr) then
        local decompressionError = lzErr --[[@as Errors.Error]]
        causeCode = decompressionError.code
      end
      error(
        Errors.new("BATTLE_COMPRESSED_MEMBER_INVALID", "could not decompress " .. label, {
          label = label,
          memberId = memberId,
          causeCode = causeCode,
          cause = tostring(lzErr),
        }),
        0
      )
    end
    return plain
  end
  return member
end

-- Native picture animation records are 89 bytes in member 0 of NARC_a_1_8_0:
-- two 43-byte facing records plus three trailing species attributes. Each
-- facing record begins with three attributes followed by ten four-byte
-- PokepicAnimScript entries. The interpreter consumes `next`, duration,
-- and x offset; negative `next` values encode source loop/end control.
local function pictureAnimation(animationBytes, speciesId, facing)
  local facingOffset = facing == 2 and 0 or 43
  local recordOffset = speciesId * Sources.PICTURE_ANIMATION_RECORD_SIZE + facingOffset + 3
  local steps = {}
  for stepIndex = 0, 9 do
    local offset = recordOffset + stepIndex * 4
    local nextFrame = string.byte(animationBytes, offset + 1)
    local duration = string.byte(animationBytes, offset + 2)
    local xOffset = string.byte(animationBytes, offset + 3)
    local auxiliary = string.byte(animationBytes, offset + 4)
    assert(
      nextFrame ~= nil and duration ~= nil and xOffset ~= nil and auxiliary ~= nil,
      "picture animation record is truncated for species "
        .. speciesId
        .. " facing "
        .. facing
        .. " at "
        .. offset
        .. " of "
        .. #animationBytes
    )
    if nextFrame >= 128 then
      nextFrame = nextFrame - 256
    end
    if xOffset >= 128 then
      xOffset = xOffset - 256
    end
    if auxiliary >= 128 then
      auxiliary = auxiliary - 256
    end
    steps[#steps + 1] = { next = nextFrame, duration = duration, xOffset = xOffset, auxiliary = auxiliary }
  end
  return { steps = steps }
end

---@class BattlePresentationCompiler.ScenePayloads
---@field characters string normalized packed 4bpp color indices in tile order
---@field map { width: integer, height: integer, entries: table[] }
---@field palette { colors: { r: integer, g: integer, b: integer }[] }

---@class BattlePresentationCompiler.SceneBuildMetadata
---@field background { archiveSymbol: string, id: integer, charactersMember: integer }
---@field terrain { archiveSymbol: string, paletteMember: integer, type0Member: integer, type1Member: integer }
---@field palette { archiveSymbol: string, member: integer, variant: integer, selection: string }
---@field screen { archiveSymbol: string, member: integer }

---@class BattlePresentationCompiler.SceneRecord : BattlePresentationCache.SceneRecord
---@field layers BattlePresentationCache.SceneLayer[]
---@field layerPayloads BattlePresentationCompiler.ScenePayloads[]
---@field buildMetadata BattlePresentationCompiler.SceneBuildMetadata
---@field image string RGBA pixels for the static PNG optimization

-- Compile the source-selected per-species height and facing animation data
-- into semantic keys. Physical member identities remain in the source
-- selector and never enter the manifest.
local function compilePictureAttributes(romFs)
  local heightArchive = openArchive(romFs, Sources.PICTURE_HEIGHT_NARC, "picture heights")
  local otherHeightArchive = openArchive(romFs, Sources.PICTURE_HEIGHT_OTHER_NARC, "special picture heights")
  local animationArchive = openArchive(romFs, Sources.PICTURE_ANIMATION_NARC, "picture animation attributes")
  local portraitArchives = {
    pokemon_graphics = openArchive(romFs, "pokemon_graphics", "picture variant selection"),
    pokemon_graphics_other = openArchive(romFs, "pokemon_graphics_other", "special picture variant selection"),
  }
  local animationBytes =
    decodeMember(animationArchive, Sources.PICTURE_ANIMATION_MEMBER, "picture animation attributes")
  local pictureAttributes = {}
  local pictureSelectors = {}
  for speciesId = 1, MonSources.MAX_SPECIES do
    local speciesKey = MonSources.speciesKeys[speciesId]
    if speciesKey ~= nil then
      for _, form in ipairs(MonSources.runtimeForms(speciesId)) do
        for _, gender in ipairs({ "male", "female" }) do
          for _, facing in ipairs({ 0, 2 }) do
            local portrait = MonSources.portraitIds(speciesId, gender, facing, false, form)
            local portraitArchive = assert(portraitArchives[portrait.narc], "portrait source archive is known")
            local charBytes, charErr = portraitArchive:readMember(portrait.charMemberId)
            if charBytes == nil then
              error(charErr, 0)
            end
            if #charBytes > 0 then
              local heightSymbol, heightMember =
                Sources.pictureHeightSource(speciesId, speciesKey, form, facing, gender)
              local sourceArchive = heightSymbol == Sources.PICTURE_HEIGHT_NARC and heightArchive or otherHeightArchive
              local heightBytes, heightErr = sourceArchive:readMember(heightMember)
              if heightBytes == nil then
                error(heightErr, 0)
              end
              if #heightBytes ~= 1 then
                error(
                  Errors.new("BATTLE_PICTURE_HEIGHT_INVALID", "picture height member must contain one byte", {
                    species = speciesKey,
                    form = form,
                    gender = gender,
                    facing = facing == 2 and "front" or "back",
                    size = #heightBytes,
                  }),
                  0
                )
              end
              local facingKey = facing == 2 and "front" or "back"
              local key = "pokemon/" .. speciesKey .. "/form-" .. form .. "/" .. gender .. "/" .. facingKey
              pictureAttributes[key] = {
                height = string.byte(heightBytes, 1),
                animation = pictureAnimation(animationBytes, speciesId, facing),
              }
              pictureSelectors[key] = {
                species = speciesKey,
                form = form,
                gender = gender,
                facing = facingKey,
                attributes = key,
              }
            end
          end
        end
      end
    end
  end
  return pictureAttributes, pictureSelectors
end

-- Pokepic's shadow NCGR is the same scanned 6,400-byte row surface used by
-- the portrait path. UnscanPokepic_PtHGSS XORs its 3,200 little-endian words
-- with the running 16-bit LCRNG state before PokepicManager_Create copies
-- the first 40 bytes of each row into the 256x256 texture at (160,160).
local function unscanShadowCharacters(characters)
  local shadow = Sources.POKE_SHADOW
  assert(
    #characters == shadow.sourceRowBytes * shadow.sourceRows,
    "Pokepic shadow characters match the native scanned source surface (found " .. #characters .. " bytes)"
  )
  local seed = string.byte(characters, 1) + string.byte(characters, 2) * 256
  local output = {}
  for wordOffset = 0, 3199 do
    local offset = wordOffset * 2
    local word = string.byte(characters, offset + 1) + string.byte(characters, offset + 2) * 256
    local plain = bit.bxor(word, seed % 65536)
    output[#output + 1] = string.char(plain % 256, math.floor(plain / 256))
    seed = U32.add(U32.mul(seed, 1103515245), 24691)
  end
  return table.concat(output)
end

local function shadowTexture(characters)
  local shadow = Sources.POKE_SHADOW
  local source = unscanShadowCharacters(characters)
  local texture = {}
  local fill = string.byte(source, 1)
  for offset = 1, shadow.textureWidth * shadow.textureHeight / 2 do
    texture[offset] = fill
  end
  for row = 0, shadow.sourceRows - 1 do
    local sourceOffset = row * shadow.sourceRowBytes
    local textureOffset = shadow.textureOriginByteOffset + row * shadow.textureRowBytes
    for byteX = 0, shadow.copiedRowBytes - 1 do
      texture[textureOffset + byteX + 1] = string.byte(source, sourceOffset + byteX + 1)
    end
  end
  local chunks = {}
  for first = 1, #texture, 2048 do
    local bytes = {}
    for index = first, math.min(first + 2047, #texture) do
      bytes[#bytes + 1] = string.char(texture[index])
    end
    chunks[#chunks + 1] = table.concat(bytes)
  end
  return table.concat(chunks)
end

-- Compile the native shadow character/palette UV selections into one
-- source-independent image. The logical size selector remains in the
-- manifest as four normalized rectangles stacked in this image.
---@param characterData { depth: integer, tiles: string } decoded NARC 259 NCGR
---@param paletteData { colors: table[] } decoded NARC 260 NCLR
---@return { width: integer, height: integer, pixels: string } staged shadow atlas
function BattlePresentationCompiler.compileShadowImage(characterData, paletteData)
  assert(characterData.depth == Sources.POKE_SHADOW.depth, "native shadow art uses 4bpp characters")
  assert(type(characterData.tiles) == "string", "native shadow art has decoded character bytes")
  assert(type(paletteData.colors) == "table" and #paletteData.colors == 16, "native shadow art has one 4bpp palette")
  local texture = shadowTexture(characterData.tiles)
  local rows = {}
  for _, region in ipairs(Sources.POKE_SHADOW.regions) do
    local rgba = {}
    for y = 0, region.height - 1 do
      for x = 0, region.width - 1 do
        local pixelX, pixelY = region.x + x, region.y + y
        local byteOffset = pixelY * Sources.POKE_SHADOW.textureRowBytes + math.floor(pixelX / 2)
        local packed = string.byte(texture, byteOffset + 1)
        local colorIndex = pixelX % 2 == 0 and packed % 16 or math.floor(packed / 16)
        local color = assert(paletteData.colors[colorIndex + 1], "shadow pixel palette index is in range")
        rgba[#rgba + 1] = string.char(color.r, color.g, color.b, colorIndex == 0 and 0 or 255)
      end
    end
    rows[#rows + 1] = table.concat(rgba)
  end
  return { width = 64, height = 64, pixels = table.concat(rows) }
end

---@generic T
---@param decoded T?
---@param err unknown?
---@param label string
---@param memberId integer
---@return T decoded payload
local function mustDecode(decoded, err, label, memberId)
  if decoded ~= nil then
    return decoded
  end
  local cause = "unknown"
  if type(err) == "table" and type(err.code) == "string" then
    cause = err.code
  end
  error(
    Errors.new("BATTLE_DECODE_FAILED", label .. " failed to decode (" .. cause .. ")", {
      label = label,
      memberId = memberId,
      cause = cause,
    }),
    0
  )
end

---@param archive Narc
---@param memberId integer
---@param label string
---@param charOpts { label: string, allowRetailTail: boolean }? decoder options (the retail-tail producer option for background chars)
---@return { depth: integer, tiles: string }
local function decodeChars(archive, memberId, label, charOpts)
  local bytes = decodeMember(archive, memberId, label)
  local decoded, err = G2dDecoder.decodeChar(bytes, charOpts or { label = label })
  return mustDecode(decoded, err, label, memberId)
end

---@param archive Narc
---@param memberId integer
---@param label string
---@return { width: integer, height: integer, entries: table[] }
local function decodeScreen(archive, memberId, label)
  local bytes = decodeMember(archive, memberId, label)
  local decoded, err = G2dDecoder.decodeScreen(bytes, { label = label })
  return mustDecode(decoded, err, label, memberId)
end

---@param archive Narc
---@param memberId integer
---@param label string
---@return { colors: table[] }
local function decodePalette(archive, memberId, label)
  local bytes = decodeMember(archive, memberId, label)
  local decoded, err = G2dDecoder.decodePalette(bytes, { label = label })
  return mustDecode(decoded, err, label, memberId)
end

---@param archive Narc
---@param memberId integer
---@param label string
---@return { cells: table[] }
local function decodeCells(archive, memberId, label)
  local bytes = decodeMember(archive, memberId, label)
  local decoded, err = G2dDecoder.decodeCell(bytes, { label = label })
  return mustDecode(decoded, err, label, memberId)
end

---@param archive Narc
---@param memberId integer
---@param label string
---@return { anims: table[] }
local function decodeAnimation(archive, memberId, label)
  local bytes = decodeMember(archive, memberId, label)
  local decoded, err = G2dDecoder.decodeAnimation(bytes, { label = label })
  return mustDecode(decoded, err, label, memberId)
end

---@param decoded { depth: integer, tiles: string }|{ colors: table[] }|{ width: integer, height: integer, entries: table[] }|{ cells: table[] }|{ anims: table[] }
---@return { depth: integer, tiles: string }
local function requireMenuCharacters(decoded)
  assert(type(decoded.depth) == "number" and type(decoded.tiles) == "string", "menu character resource is decoded")
  ---@cast decoded { depth: integer, tiles: string }
  return decoded
end

---@param decoded { depth: integer, tiles: string }|{ colors: table[] }|{ width: integer, height: integer, entries: table[] }|{ cells: table[] }|{ anims: table[] }
---@return { colors: table[] }
local function requireMenuPalette(decoded)
  assert(type(decoded.colors) == "table", "menu palette resource is decoded")
  ---@cast decoded { colors: table[] }
  return decoded
end

---@param decoded { depth: integer, tiles: string }|{ colors: table[] }|{ width: integer, height: integer, entries: table[] }|{ cells: table[] }|{ anims: table[] }
---@return { width: integer, height: integer, entries: table[] }
local function requireMenuScreen(decoded)
  assert(
    type(decoded.width) == "number" and type(decoded.height) == "number" and type(decoded.entries) == "table",
    "menu screen resource is decoded"
  )
  ---@cast decoded { width: integer, height: integer, entries: table[] }
  return decoded
end

---@param versionId string
local function checkVersion(versionId)
  if SUPPORTED_VERSIONS[versionId] ~= true then
    error(
      Errors.new(
        "BATTLE_VERSION_UNSUPPORTED",
        "battle presentation has no source contract for " .. tostring(versionId),
        { versionId = versionId }
      ),
      0
    )
  end
end

---@param record { colors: { r: integer, g: integer, b: integer }[] } decoded G2D record
---@param expected integer
---@param label string
local function checkColorCount(record, expected, label)
  if #record.colors ~= expected then
    error(
      Errors.new(
        "BATTLE_SOURCE_UNEXPECTED",
        label .. " carries " .. #record.colors .. " colors, expected " .. expected,
        {
          label = label,
          available = #record.colors,
          expected = expected,
        }
      ),
      0
    )
  end
end

---@param record { width: integer, height: integer }
---@param width integer
---@param height integer
---@param label string
local function checkScreenSize(record, width, height, label)
  if record.width ~= width or record.height ~= height then
    error(
      Errors.new(
        "BATTLE_SOURCE_UNEXPECTED",
        label .. " is " .. record.width .. "x" .. record.height .. ", expected " .. width .. "x" .. height,
        { label = label, width = record.width, height = record.height }
      ),
      0
    )
  end
end

-- One sprite triple (animation, cells, characters) through the shared
-- decoders with its palette association kept alongside the geometry.
---@param archive Narc
---@param role { nanr: integer, ncer: integer, ncgr: integer }
---@param palette { colors: table[] }
---@param label string
---@param normalizeObjTiles? boolean normalize cell tile bases for the staged tile strip
---@return { anims: table[], cells: table[], chars: { depth: integer, tiles: string }, palette: { colors: table[] } }
local function decodeTriple(archive, role, palette, label, normalizeObjTiles)
  local animation = decodeAnimation(archive, role.nanr, label .. " animation")
  local cellBytes = decodeMember(archive, role.ncer, label .. " cells")
  local decodedCells, cellErr = G2dDecoder.decodeCell(cellBytes, { label = label .. " cells" })
  local cells = mustDecode(decodedCells, cellErr, label .. " cells", role.ncer)
  if normalizeObjTiles then
    local decodedMapping, mappingErr = G2dDecoder.decodeCellMapping(cellBytes, { label = label .. " cells" })
    local mapping = mustDecode(decodedMapping, mappingErr, label .. " cell mapping", role.ncer)
    local scale = 2 ^ mapping --[[@as integer]]
    for _, cell in ipairs(cells.cells) do
      for _, obj in ipairs(cell.objs) do
        obj.tile = obj.tile * scale
      end
    end
  end
  local chars = decodeChars(archive, role.ncgr, label .. " characters")
  if chars.depth ~= 3 then
    error(
      Errors.new(
        "BATTLE_SOURCE_UNEXPECTED",
        label .. " characters are not 4bpp",
        { label = label, depth = chars.depth }
      ),
      0
    )
  end
  return { anims = animation.anims, cells = cells.cells, chars = chars, palette = palette }
end

---@param anim { frames: { cell: integer, duration: integer }[], playMode: string, loopStartFrameIdx: integer } decoded animation
---@return { playMode: string, loopStartFrameIdx: integer, frames: table[] }
local function summarizeAnimation(anim)
  local frames = {}
  for _, frame in ipairs(anim.frames) do
    frames[#frames + 1] = { cell = frame.cell, duration = frame.duration }
  end
  return { playMode = anim.playMode, loopStartFrameIdx = anim.loopStartFrameIdx, frames = frames }
end

---@param triple { anims: table[] }
---@param animIndex integer|nil 1-based animation selection (defaults to the only animation)
---@return { playMode: string, loopStartFrameIdx: integer, frames: table[] }
local function selectAnimation(triple, animIndex)
  if animIndex == nil then
    if #triple.anims ~= 1 then
      error(
        Errors.new(
          "BATTLE_SOURCE_UNEXPECTED",
          "sprite keeps " .. #triple.anims .. " animations, expected exactly one",
          { animations = #triple.anims }
        ),
        0
      )
    end
    animIndex = 1
  end
  return summarizeAnimation(must(triple.anims[animIndex], "sprite animation is missing"))
end

-- The evidenced player arrow: six cells with durations 0, 4, 4, 4, 16, 6.
-- The authored zero opening frame is preserved, never rewritten.
local ARROW_DURATIONS = { 0, 4, 4, 4, 16, 6 }

---@param triple { anims: table[], cells: table[], chars: { depth: integer, tiles: string }, palette: { colors: table[] } }
local function checkArrow(triple)
  if #triple.anims ~= 1 then
    error(
      Errors.new("BATTLE_SOURCE_UNEXPECTED", "arrow keeps " .. #triple.anims .. " animations, expected one", {
        animations = #triple.anims,
      }),
      0
    )
  end
  local frames = triple.anims[1].frames
  if #frames ~= #ARROW_DURATIONS then
    error(
      Errors.new("BATTLE_SOURCE_UNEXPECTED", "arrow keeps " .. #frames .. " cells, expected six", {
        frames = #frames,
      }),
      0
    )
  end
  for index, frame in ipairs(frames) do
    if frame.cell ~= index - 1 or frame.duration ~= ARROW_DURATIONS[index] then
      error(
        Errors.new(
          "BATTLE_SOURCE_UNEXPECTED",
          "arrow frame "
            .. (index - 1)
            .. " is cell "
            .. frame.cell
            .. "/"
            .. frame.duration
            .. " ticks, expected cell "
            .. (index - 1)
            .. "/"
            .. ARROW_DURATIONS[index]
            .. " ticks",
          { cell = frame.cell, duration = frame.duration }
        ),
        0
      )
    end
  end
end

local function concatChars(chars)
  -- string.char/unpack are limited by the Lua stack; build in row chunks.
  local out = {}
  for i = 1, #chars, 4096 do
    out[#out + 1] = string.char(unpack(chars, i, math.min(i + 4095, #chars)))
  end
  return table.concat(out)
end

---@param pixels string RGBA image buffer
---@param width integer image width in pixels
---@param height integer image height in pixels
---@param name string slice name for diagnostics
---@return string staged PNG bytes
local function encodeImage(pixels, width, height, name)
  if #pixels ~= width * height * 4 then
    error(
      Errors.new(
        "BATTLE_IMAGE_INVALID",
        name .. " carries " .. #pixels .. " bytes, expected " .. (width * height * 4),
        {
          name = name,
          bytes = #pixels,
        }
      ),
      0
    )
  end
  return PngWriter.encode(width, height, pixels)
end

---@param palette { colors: table[] }
---@return table[] color records
local function paletteRecords(palette)
  local colors = {}
  for _, color in ipairs(palette.colors) do
    colors[#colors + 1] = { r = color.r, g = color.g, b = color.b }
  end
  return colors
end

-- Producer provenance beside the staged global manifest: every selected
-- role with its archive symbol and member. Native identities live here
-- and in the producer configuration only, never in the runtime manifest.
function provenanceRoles()
  local roles = {
    lowerChars = { narc = Sources.LOWER_NARC, member = ROLES.lowerChars },
    lowerPalette = { narc = Sources.LOWER_NARC, member = ROLES.lowerPalette },
    hudPalette = { narc = Sources.SCENE_NARC, member = ROLES.hudPalette },
    lowerObjPalette = { narc = Sources.SCENE_NARC, member = ROLES.lowerObjPalette },
    backdropScreen = { narc = Sources.LOWER_NARC, member = ROLES.backdropScreen },
    terrainCells0 = { narc = Sources.SCENE_NARC, member = ROLES.terrainCells0 },
    terrainAnim0 = { narc = Sources.SCENE_NARC, member = ROLES.terrainAnim0 },
    terrainCells1 = { narc = Sources.SCENE_NARC, member = ROLES.terrainCells1 },
    terrainAnim1 = { narc = Sources.SCENE_NARC, member = ROLES.terrainAnim1 },
    battleFont = { narc = "font", member = Sources.BATTLE_FONT_ID },
  }
  local function screenRoles(field, members, narc)
    local list = {}
    for _, memberId in ipairs(members) do
      list[#list + 1] = { narc = narc, member = memberId }
    end
    roles[field] = list
  end
  screenRoles("commandScreens", ROLES.commandScreens, Sources.LOWER_NARC)
  screenRoles("fightScreens", ROLES.fightScreens, Sources.LOWER_NARC)
  screenRoles("targetScreens", ROLES.targetScreens, Sources.LOWER_NARC)
  screenRoles("twoOptionScreens", ROLES.twoOptionScreens, Sources.LOWER_NARC)
  local function tripleRoles(field, role)
    roles[field] = {
      nanr = { narc = Sources.SCENE_NARC, member = role.nanr },
      ncer = { narc = Sources.SCENE_NARC, member = role.ncer },
      ncgr = { narc = Sources.SCENE_NARC, member = role.ncgr },
    }
  end
  tripleRoles("playerHud", ROLES.playerHud)
  tripleRoles("enemyHud", ROLES.enemyHud)
  roles.doublesHud = {
    playerLeft = {
      nanr = { narc = Sources.SCENE_NARC, member = ROLES.playerHudDoubleLeft.nanr },
      ncer = { narc = Sources.SCENE_NARC, member = ROLES.playerHudDoubleLeft.ncer },
      ncgr = { narc = Sources.SCENE_NARC, member = ROLES.playerHudDoubleLeft.ncgr },
    },
    playerRight = {
      nanr = { narc = Sources.SCENE_NARC, member = ROLES.playerHudDoubleRight.nanr },
      ncer = { narc = Sources.SCENE_NARC, member = ROLES.playerHudDoubleRight.ncer },
      ncgr = { narc = Sources.SCENE_NARC, member = ROLES.playerHudDoubleRight.ncgr },
    },
    enemyLeft = {
      nanr = { narc = Sources.SCENE_NARC, member = ROLES.enemyHudDoubleLeft.nanr },
      ncer = { narc = Sources.SCENE_NARC, member = ROLES.enemyHudDoubleLeft.ncer },
      ncgr = { narc = Sources.SCENE_NARC, member = ROLES.enemyHudDoubleLeft.ncgr },
    },
    enemyRight = {
      nanr = { narc = Sources.SCENE_NARC, member = ROLES.enemyHudDoubleRight.nanr },
      ncer = { narc = Sources.SCENE_NARC, member = ROLES.enemyHudDoubleRight.ncer },
      ncgr = { narc = Sources.SCENE_NARC, member = ROLES.enemyHudDoubleRight.ncgr },
    },
  }
  tripleRoles("arrow", ROLES.arrow)
  roles.gauges = {}
  for _, family in ipairs(ROLES.gauges) do
    roles.gauges[#roles.gauges + 1] = {
      nanr = { narc = Sources.SCENE_NARC, member = family.nanr },
      ncer = { narc = Sources.SCENE_NARC, member = family.ncer },
      ncgr = { narc = Sources.SCENE_NARC, member = family.ncgr },
    }
  end
  roles.baseChars = {}
  roles.basePalettes = {}
  for backgroundId = 0, 17 do
    roles.baseChars[#roles.baseChars + 1] = { narc = Sources.LOWER_NARC, member = Sources.baseCharMember(backgroundId) }
    local variants = backgroundId < Sources.OUTDOOR_BACKGROUNDS and 2 or 0
    for variant = 0, variants do
      roles.basePalettes[#roles.basePalettes + 1] =
        { narc = Sources.LOWER_NARC, member = Sources.basePaletteMember(backgroundId, variant) }
    end
  end
  return roles
end

local function copyStrings(values)
  local copied = {}
  for index, value in ipairs(values) do
    copied[index] = value
  end
  return copied
end

local function introSequenceKey(sequenceSymbol)
  return "audio/sequence/" .. sequenceSymbol
end

local function compileIntroMusic(romFs, audioPlan, audioPlanError)
  local source = Sources.INTRO_MUSIC
  if audioPlan == nil then
    error(audioPlanError, 0)
  end

  local routes = {}
  local routeKeys = {}
  local sourceRoutes = {}
  local sequenceSymbols = {}
  local function addRoute(sequenceSymbol, role)
    local routeKey = "battle/music/" .. role
    local sequenceKey = introSequenceKey(sequenceSymbol)
    sequenceSymbols[sequenceKey] = sequenceSymbol
    if routeKeys[routeKey] == nil then
      local context = source.routeContexts[role]
      assert(context ~= nil, "every intro music role has a source context")
      routeKeys[routeKey] = true
      routes[#routes + 1] = {
        key = routeKey,
        sequenceKey = sequenceKey,
        context = copyStrings(context),
      }
    end
    return routeKey, sequenceKey
  end

  for rowIndex, sequenceSymbol in ipairs(source.rows) do
    local role = assert(source.roles[sequenceSymbol], "every source music row has a semantic role")
    local routeKey, sequenceKey = addRoute(sequenceSymbol, role)
    sourceRoutes[rowIndex] = {
      sequenceSymbol = sequenceSymbol,
      routeKey = routeKey,
      sequenceKey = sequenceKey,
      transitionFallback = source.transitionFallbackCategories[rowIndex - 1] == true,
    }
  end

  local kantoTrainerSymbol = Sources.AUDIO_ROLES.kantoTrainer
  local kantoTrainerRole = assert(source.roles[kantoTrainerSymbol], "Kanto trainer sequence has a semantic role")
  addRoute(kantoTrainerSymbol, kantoTrainerRole)

  local selection = source.selectionSound
  local selectionSequenceKey = introSequenceKey(selection.sequenceSymbol)
  sequenceSymbols[selectionSequenceKey] = selection.sequenceSymbol
  local selectedBanks = {}
  local selectedSequences = {}
  local sequenceIndex = audioPlan.plan.index
  for sequenceKey, sequenceSymbol in pairs(sequenceSymbols) do
    local sequenceId = sequenceIndex.sequenceBySymbol[sequenceSymbol]
    local record = sequenceId ~= nil and sequenceIndex.sequences[sequenceId] or nil
    if record == nil then
      error(
        Errors.new(
          "BATTLE_INTRO_MUSIC_SEQUENCE_MISSING",
          "selected intro music sequence is absent from the audio plan",
          {
            sequenceKey = sequenceKey,
            sequenceSymbol = sequenceSymbol,
          }
        ),
        0
      )
    end
    local bankId = record.bankId
    if sequenceIndex.banks[bankId] == nil then
      error(
        Errors.new("BATTLE_INTRO_MUSIC_BANK_MISSING", "selected intro music bank is absent from the audio plan", {
          sequenceKey = sequenceKey,
          sequenceSymbol = sequenceSymbol,
        }),
        0
      )
    end
    selectedBanks[bankId] = selectedBanks[bankId] or { sequenceIds = {} }
    selectedBanks[bankId].sequenceIds[sequenceId] = true
    selectedSequences[sequenceKey] = { sequenceId = sequenceId, bankId = bankId }
  end

  local AudioBank = require("libs.assets.src.audio.AudioBank")
  local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
  local sequenceClosures = {}
  for bankId, selected in pairs(selectedBanks) do
    local sequenceIds = {}
    for sequenceId in pairs(selected.sequenceIds) do
      sequenceIds[#sequenceIds + 1] = sequenceId
    end
    table.sort(sequenceIds)
    local compiled, compileErr = AudioCompiler.compileBank(
      romFs,
      { bankId = bankId, sequenceIds = sequenceIds },
      function() end
    )
    if compiled == nil then
      error(compileErr, 0)
    end
    local sampleKeys = AudioBank.sampleKeys(compiled.bank)
    if sampleKeys == nil then
      error(
        Errors.new("BATTLE_INTRO_MUSIC_BANK_INVALID", "compiled intro music bank has invalid sample references", {
          bankIdentity = Hashing.hashLua(compiled.bank),
        }),
        0
      )
    end
    for index, sampleKey in ipairs(sampleKeys) do
      sampleKeys[index] = "audio/sample/content/" .. sampleKey
    end
    table.sort(sampleKeys)
    local bankIdentity = Hashing.hashLua(compiled.bank)
    local bankKey = "audio/bank/content/" .. bankIdentity
    for sequenceKey, selectedSequence in pairs(selectedSequences) do
      if selectedSequence.bankId == bankId then
        local sequence = compiled.sequences[selectedSequence.sequenceId]
        if sequence == nil then
          error(
            Errors.new("BATTLE_INTRO_MUSIC_SEQUENCE_MISSING", "compiled intro music sequence is absent from its bank", {
              sequenceKey = sequenceKey,
            }),
            0
          )
        end
        sequenceClosures[sequenceKey] = {
          bankKey = bankKey,
          player = {
            volume = sequence.player.initialVolume,
            channelPriority = sequence.player.channelPriority,
            playerPriority = sequence.player.playerPriority,
          },
          sampleKeys = copyStrings(sampleKeys),
          closureIdentity = Hashing.hashLua({
            sequence = Hashing.hashLua(sequence),
            bank = bankIdentity,
            samples = sampleKeys,
          }),
        }
      end
    end
  end

  return {
    inputs = copyStrings(source.inputs),
    inputTypes = source.inputTypes,
    routes = routes,
    sourceRoutes = sourceRoutes,
    kantoOverrides = copyStrings(source.kantoOverrides),
    kantoSelection = source.selectionRules.kantoOverride,
    selectionRules = {
      trainer = source.selectionRules.trainer,
      wild = source.selectionRules.wild,
    },
    transitionFallbackIndependent = source.transitionFallbackIndependent,
    selectionSound = {
      key = "battle/music/menu-selection",
      eventInput = selection.eventInput,
      sequenceKey = selectionSequenceKey,
    },
    sequenceClosures = sequenceClosures,
  }
end

-- Compile the shared ordinary battle UI: menu compositions, health-box
-- and arrow sprites with their animations, party gauges, terrain bake
-- inputs, lower palettes per background, font/audio references, and the
-- supported scene inventory. Returns the verified manifest, the staged
-- image buffers by slice name, and the producer provenance beside it.
---@param romFs RomFs
---@param opts? { versionId?: string }
---@return { manifest: table<string, unknown>, images: table<string, { width: integer, height: integer, pixels: string }>, resourcePayloads: table<string, table<string, unknown>>, provenance: table<string, unknown>, blockers: string[] }|nil bundle
---@return unknown|nil reason
function BattlePresentationCompiler.compileGlobal(romFs, opts)
  opts = opts or {}
  local versionId = opts.versionId or romFs:version()
  checkVersion(versionId)
  local ok, bundle = pcall(function()
    local lower = openArchive(romFs, Sources.LOWER_NARC, "lower screen")
    local sceneArchive = openArchive(romFs, Sources.SCENE_NARC, "battle scene")
    local lowerChars = decodeChars(lower, ROLES.lowerChars, "shared lower characters")
    if lowerChars.depth ~= 3 or #lowerChars.tiles ~= 32768 then
      error(
        Errors.new("BATTLE_SOURCE_UNEXPECTED", "shared lower characters carry an unexpected tile region", {
          depth = lowerChars.depth,
          bytes = #lowerChars.tiles,
        }),
        0
      )
    end
    local lowerPalette = decodePalette(lower, ROLES.lowerPalette, "base lower palette")
    checkColorCount(lowerPalette, 256, "base lower palette")
    local hudPalette = decodePalette(sceneArchive, ROLES.hudPalette, "ordinary HUD palette")
    checkColorCount(hudPalette, 16, "ordinary HUD palette")
    local componentByteParts = {}
    local componentHex = Sources.HUD_COMPONENTS.hex
    for index = 1, #componentHex, 2 do
      componentByteParts[#componentByteParts + 1] = string.char(tonumber(componentHex:sub(index, index + 1), 16))
    end
    local componentBytes = table.concat(componentByteParts)
    assert(
      #componentBytes == Sources.HUD_COMPONENTS.tileCount * 32,
      "native HUD component bytes match their published tile count"
    )
    local lowerObjPalette = decodePalette(sceneArchive, ROLES.lowerObjPalette, "lower OBJ palette")
    checkColorCount(lowerObjPalette, 112, "lower OBJ palette")
    local images = {}
    local resourcePayloads = {}
    local resourceCatalog = {}
    local menuTilemapProvenance = {}
    local function stageSlice(name, pixels, width, height)
      images[name] = { width = width, height = height, pixels = pixels }
    end
    local shadowArchive = openArchive(romFs, Sources.POKE_SHADOW.archive, "Pokepic shadow art")
    local shadowCharacterBytes =
      decodeMember(shadowArchive, Sources.POKE_SHADOW.characterMember, "Pokepic shadow characters")
    local shadowPaletteBytes = decodeMember(shadowArchive, Sources.POKE_SHADOW.paletteMember, "Pokepic shadow palette")
    local shadowCharacters = mustDecode(
      G2dDecoder.decodeChar(shadowCharacterBytes, { label = "Pokepic shadow characters" }),
      nil,
      "Pokepic shadow characters",
      Sources.POKE_SHADOW.characterMember
    )
    local shadowPalette = mustDecode(
      G2dDecoder.decodePalette(shadowPaletteBytes, { label = "Pokepic shadow palette" }),
      nil,
      "Pokepic shadow palette",
      Sources.POKE_SHADOW.paletteMember
    )
    local shadowRaster = BattlePresentationCompiler.compileShadowImage(shadowCharacters, shadowPalette)
    stageSlice("pokepic-shadow", shadowRaster.pixels, shadowRaster.width, shadowRaster.height)
    local shadowRegions = {}
    for index, sourceRegion in ipairs(Sources.POKE_SHADOW.regions) do
      shadowRegions[index] = {
        size = sourceRegion.size,
        x = 0,
        y = (index - 1) * sourceRegion.height,
        width = sourceRegion.width,
        height = sourceRegion.height,
      }
    end
    local lowerStrip = G2dRasterizer.renderTileStrip(lowerChars, lowerPalette, 0, Sources.LOWER_USED_TILES, 0, {
      asset = Sources.LOWER_NARC,
      role = "shared lower characters",
    })
    stageSlice("lower-chars", lowerStrip.pixels, lowerStrip.width, lowerStrip.height)
    -- One menu descriptor per lower composition: the staged screen slices
    -- with the source template/priority facts where the source pins them.
    local function compileMenu(roleMembers, names, label, templates, priorities, planes, feedbackKey)
      local feedback = Sources.MENU_FEEDBACK[feedbackKey]
      local screens = {}
      for index, memberId in ipairs(roleMembers) do
        local screen = decodeScreen(lower, memberId, label .. " screen " .. index)
        checkScreenSize(screen, 256, 256, label .. " screen " .. index)
        local raster = G2dRasterizer.renderScreen(lowerChars, lowerPalette, screen, {
          asset = Sources.LOWER_NARC,
          role = label .. " screen " .. index,
        })
        local name = names[index]
        stageSlice(name, raster.pixels, raster.width, raster.height)
        local tilemapKey = "menu/tilemap/" .. name:sub(#"menu-" + 1):gsub("-", "/")
        local tilemapPath = BattlePresentationCache.globalResourcePath(tilemapKey)
        local tilemapBytes = must(lower:readMember(memberId), "menu tilemap source member is absent")
        resourcePayloads[tilemapPath] = screen
        resourceCatalog[tilemapKey] = {
          kind = "map",
          contentIdentity = Hashing.sha1hex(tilemapBytes),
          format = "nitro-bg-map-v1",
          geometry = { width = screen.width, height = screen.height, entryCount = #screen.entries },
          path = tilemapPath,
        }
        menuTilemapProvenance[tilemapKey] = { archive = Sources.LOWER_NARC, memberId = memberId }
        local entry = {
          image = BattlePresentationCache.globalImagePath(name),
          width = raster.width,
          height = raster.height,
          tilemapKey = tilemapKey,
          plane = planes[index],
          template = templates[index],
          priority = priorities[index],
        }
        if feedback ~= nil and index == feedback.screenIndex then
          entry.feedback = {}
          for _, button in ipairs(feedback.buttons) do
            local states = {}
            for state, offset in pairs(feedback.states) do
              local patch = BattlePresentationCompiler.compileMenuFeedbackPatch(lowerChars, lowerPalette, screen, {
                left = button.left,
                top = button.top,
                right = button.right,
                bottom = button.bottom,
                offset = offset,
              })
              local variantName = name .. "-" .. button.id:gsub("[^%w]+", "-"):gsub("%-+$", "") .. "-" .. state
              stageSlice(variantName, patch.pixels, patch.width, patch.height)
              states[state] = {
                image = BattlePresentationCache.globalImagePath(variantName),
                x = button.left * 8,
                y = button.top * 8,
                width = patch.width,
                height = patch.height,
              }
            end
            entry.feedback[button.id] = states
          end
        end
        screens[#screens + 1] = entry
      end
      return { image = screens[1].image, screens = screens }
    end
    -- Command composition pins template buffer indices 1, 2, 0 with
    -- priorities 2, 3, 3; the fourth buffer stays unused at priority 0.
    local command = compileMenu(ROLES.commandScreens, {
      "menu-command-1",
      "menu-command-2",
      "menu-command-3",
    }, "command", { 1, 2, 0 }, { 2, 3, 3 }, Sources.MENU_PLANES.command, "command")
    local moves = compileMenu(
      ROLES.fightScreens,
      { "menu-fight-1", "menu-fight-2" },
      "fight",
      { 3, 0 },
      { 2, 3 },
      Sources.MENU_PLANES.moves,
      "moves"
    )
    local target = compileMenu(ROLES.targetScreens, {
      "menu-target-1",
      "menu-target-2",
      "menu-target-3",
    }, "target", { 4, 2, 0 }, { 2, 3, 3 }, Sources.MENU_PLANES.target, "target")
    local twoOption = compileMenu(ROLES.twoOptionScreens, {
      "menu-two-option-1",
      "menu-two-option-2",
    }, "two-option", { 6, 0 }, { 2, 3 }, Sources.MENU_PLANES.twoOption, "twoOption")
    -- Background-dependent lower palettes: backgrounds 0..16 read base
    -- 247+b with touch 271+b; background 17 reads base 288, touch 289.
    local lowerVariants = {}
    for backgroundId = 0, 17 do
      local background = Sources.BACKGROUNDS[backgroundId + 1]
      -- Variant palettes carry what the source carries (sixteen or
      -- thirty-two colors depending on the background); the manifest
      -- records the association without normalizing the counts.
      local base = decodePalette(lower, Sources.lowerBasePaletteMember(backgroundId), background .. " lower palette")
      local touch = decodePalette(lower, Sources.lowerTouchPaletteMember(backgroundId), background .. " touch palette")
      lowerVariants[background] =
        { base = { colors = paletteRecords(base) }, touch = { colors = paletteRecords(touch) } }
    end
    -- Single-battle sprites: HUD boxes through the HUD palette, the arrow
    -- and party gauges through the lower OBJ palette. Associations are
    -- never swapped.
    local function compileSprite(triple, name, label, animIndex, includeHudComponents)
      local charTiles = triple.chars.tiles
      local componentBase = nil
      if includeHudComponents then
        assert(triple.chars.depth == 3, "native health-box components use 4bpp characters")
        componentBase = #charTiles / 32
        charTiles = charTiles .. componentBytes
      end
      local strip = G2dRasterizer.renderTileStrip(
        { depth = triple.chars.depth, tiles = charTiles },
        triple.palette,
        0,
        math.floor(#charTiles / 32),
        0,
        { asset = Sources.SCENE_NARC, role = label }
      )
      stageSlice(name, strip.pixels, strip.width, strip.height)
      return {
        image = BattlePresentationCache.globalImagePath(name),
        cells = triple.cells,
        animation = selectAnimation(triple, animIndex),
        palette = { colors = paletteRecords(triple.palette) },
        componentBase = componentBase,
        componentCount = includeHudComponents and Sources.HUD_COMPONENTS.tileCount or nil,
      }
    end
    local playerTriple = decodeTriple(sceneArchive, ROLES.playerHud, hudPalette, "player HUD", true)
    local enemyTriple = decodeTriple(sceneArchive, ROLES.enemyHud, hudPalette, "enemy HUD", true)
    local playerDoubleLeftTriple =
      decodeTriple(sceneArchive, ROLES.playerHudDoubleLeft, hudPalette, "player left doubled HUD", true)
    local playerDoubleRightTriple =
      decodeTriple(sceneArchive, ROLES.playerHudDoubleRight, hudPalette, "player right doubled HUD", true)
    local enemyDoubleLeftTriple =
      decodeTriple(sceneArchive, ROLES.enemyHudDoubleLeft, hudPalette, "enemy left doubled HUD", true)
    local enemyDoubleRightTriple =
      decodeTriple(sceneArchive, ROLES.enemyHudDoubleRight, hudPalette, "enemy right doubled HUD", true)
    local arrowTriple = decodeTriple(sceneArchive, ROLES.arrow, lowerObjPalette, "player arrow")
    checkArrow(arrowTriple)
    local playerHud = compileSprite(playerTriple, "hud-player-chars", "player HUD", nil, true)
    local enemyHud = compileSprite(enemyTriple, "hud-enemy-chars", "enemy HUD", nil, true)
    -- Doubled health boxes ride the same HUD palette association as the
    -- single-battle boxes, never the lower OBJ palette. Each family
    -- keeps its staged strip, source cells, animation, and palette
    -- behind one semantic slot key.
    local doublesHud = {
      playerLeft = compileSprite(
        playerDoubleLeftTriple,
        "hud-doubles-player-left-chars",
        "player left doubled HUD",
        nil,
        true
      ),
      playerRight = compileSprite(
        playerDoubleRightTriple,
        "hud-doubles-player-right-chars",
        "player right doubled HUD",
        nil,
        true
      ),
      enemyLeft = compileSprite(
        enemyDoubleLeftTriple,
        "hud-doubles-enemy-left-chars",
        "enemy left doubled HUD",
        nil,
        true
      ),
      enemyRight = compileSprite(
        enemyDoubleRightTriple,
        "hud-doubles-enemy-right-chars",
        "enemy right doubled HUD",
        nil,
        true
      ),
    }
    local arrow = compileSprite(arrowTriple, "arrow-chars", "player arrow")
    local partyGauges = {}
    for familyIndex, family in ipairs(ROLES.gauges) do
      local triple = decodeTriple(sceneArchive, family, lowerObjPalette, "party gauges " .. familyIndex)
      local section =
        compileSprite(triple, "gauges-" .. (familyIndex - 1) .. "-chars", "party gauges " .. familyIndex, 1)
      local animations = {}
      for _, anim in ipairs(triple.anims) do
        animations[#animations + 1] = summarizeAnimation(anim)
      end
      section.animations = animations
      partyGauges[#partyGauges + 1] = section
    end
    local type0Cells = decodeCells(sceneArchive, ROLES.terrainCells0, "terrain type-0 cells")
    local type0Anim = decodeAnimation(sceneArchive, ROLES.terrainAnim0, "terrain type-0 animation")
    local type1Cells = decodeCells(sceneArchive, ROLES.terrainCells1, "terrain type-1 cells")
    local type1Anim = decodeAnimation(sceneArchive, ROLES.terrainAnim1, "terrain type-1 animation")
    -- Keep narration bound to its own decoded FontID resource. The field-font
    -- producer stages every text-printer font role used by battle separately.
    local narrationFont = FieldFontCache.defPath(Sources.BATTLE_FONT_ID)
    local menuMessageArchive = openArchive(romFs, Sources.MENU_MESSAGE_BANK, "battle menu messages")
    local messageDependencies = {}
    local messageBanks = {}
    local decodedMessageBanks = {}
    local messageBankProvenance = {}
    local messageBankRoles = {}
    for role in pairs(Sources.MESSAGE_BANKS) do
      messageBankRoles[#messageBankRoles + 1] = role
    end
    table.sort(messageBankRoles)
    local function stageMessageBank(role)
      local memberId = Sources.MESSAGE_BANKS[role]
      local sourceBytes = must(menuMessageArchive:readMember(memberId), "battle message source bank is absent")
      local bank, failure = UiMessageBank.read(
        menuMessageArchive,
        memberId,
        "battle message role " .. role,
        messageDependencies,
        "battle-message-" .. role
      )
      if bank == nil then
        error(
          Errors.new("BATTLE_MESSAGE_BANK_INVALID", "source battle message bank does not decode", {
            role = role,
            memberId = memberId,
            route = role,
            cause = failure and failure.message or "unknown message-bank failure",
          }),
          0
        )
      end
      local records = {}
      local tokenCount = 0
      for messageId = 0, bank.messageCount - 1 do
        local tokens, tokenFailure = UiMessageBank.tokens(bank, memberId, messageId, charmap)
        if tokens == nil then
          error(
            Errors.new("BATTLE_MESSAGE_BANK_INVALID", "source message record cannot be normalized", {
              role = role,
              memberId = memberId,
              messageId = messageId,
              cause = tokenFailure and tokenFailure.message or "unknown tokenization failure",
            }),
            0
          )
        end
        records[messageId + 1] = { tokens = tokens }
        tokenCount = tokenCount + #tokens
      end
      local identity = Hashing.sha1hex(sourceBytes)
      local resourceKey = assert(Sources.MESSAGE_BANK_RESOURCE_KEYS[role], "message role has a semantic resource key")
      local path = BattlePresentationCache.globalResourcePath(resourceKey)
      resourceCatalog[resourceKey] = {
        kind = "message",
        contentIdentity = identity,
        format = "hgss-message-bank-tokens-v1",
        geometry = { recordCount = bank.messageCount, tokenCount = tokenCount },
        path = path,
      }
      resourcePayloads[path] = { format = "HGSS_MSG_BANK", records = records }
      messageBanks[role] = resourceKey
      messageBankProvenance[role] = {
        archive = Sources.MENU_MESSAGE_BANK,
        memberId = memberId,
        contentIdentity = identity,
      }
      return bank
    end
    for _, role in ipairs(messageBankRoles) do
      decodedMessageBanks[role] = stageMessageBank(role)
    end
    local trainerTables = Sources.TRAINER_MESSAGE_TABLES
    local offsetArchive = openArchive(romFs, trainerTables.offsetsArchive, "trainer message offsets")
    local pairArchive = openArchive(romFs, trainerTables.pairsArchive, "trainer message pairs")
    local offsetBytes = must(offsetArchive:readMember(trainerTables.memberId), "trainer message offset table is absent")
    local pairBytes = must(pairArchive:readMember(trainerTables.memberId), "trainer message pair table is absent")
    if #offsetBytes % 2 ~= 0 or #pairBytes % 4 ~= 0 then
      error(
        Errors.new("BATTLE_TRAINER_MESSAGE_INDEX_INVALID", "trainer message tables have invalid record widths", {
          offsetBytes = #offsetBytes,
          pairBytes = #pairBytes,
        }),
        0
      )
    end
    local offsetsReader = BinaryReader.new(offsetBytes, "trainer-message-offsets")
    local pairsReader = BinaryReader.new(pairBytes, "trainer-message-pairs")
    local trainerOffsets = {}
    for offset = 0, #offsetBytes - 2, 2 do
      trainerOffsets[#trainerOffsets + 1] = offsetsReader:u16le(offset)
    end
    local trainerPairs = {}
    for offset = 0, #pairBytes - 4, 4 do
      trainerPairs[#trainerPairs + 1] = {
        trainerIndex = pairsReader:u16le(offset),
        messageSelector = pairsReader:u16le(offset + 2),
      }
    end
    for index, offset in ipairs(trainerOffsets) do
      if offset % 4 ~= 0 or offset > #pairBytes then
        error(
          Errors.new("BATTLE_TRAINER_MESSAGE_INDEX_INVALID", "trainer offset escapes its pair table", {
            trainerIndex = index - 1,
            offset = offset,
            pairBytes = #pairBytes,
          }),
          0
        )
      end
    end
    local trainerTableProvenance = {
      offsets = {
        archive = trainerTables.offsetsArchive,
        memberId = trainerTables.memberId,
        contentIdentity = Hashing.sha1hex(offsetBytes),
        recordCount = #trainerOffsets,
      },
      pairs = {
        archive = trainerTables.pairsArchive,
        memberId = trainerTables.memberId,
        contentIdentity = Hashing.sha1hex(pairBytes),
        recordCount = #trainerPairs,
      },
    }
    local function stageTrainerMessageTable(resourceKey, bytes, payload, recordCount, role)
      local path = BattlePresentationCache.globalResourcePath(resourceKey)
      resourceCatalog[resourceKey] = {
        kind = "message",
        contentIdentity = Hashing.sha1hex(bytes),
        format = role == "offsets" and "hgss-trainer-message-offsets-v1" or "hgss-trainer-message-pairs-v1",
        geometry = { recordCount = recordCount },
        path = path,
      }
      resourcePayloads[path] = payload
    end
    stageTrainerMessageTable(
      "trainer-message-index/offsets",
      offsetBytes,
      { format = "HGSS_TRAINER_MESSAGE_OFFSETS", offsets = trainerOffsets },
      #trainerOffsets,
      "offsets"
    )
    local normalizedTrainerPairs = {}
    for index, pair in ipairs(trainerPairs) do
      normalizedTrainerPairs[index] = {
        trainerIndex = pair.trainerIndex,
        messageKind = pair.messageSelector,
      }
    end
    stageTrainerMessageTable(
      "trainer-message-index/pairs",
      pairBytes,
      { format = "HGSS_TRAINER_MESSAGE_PAIRS", records = normalizedTrainerPairs },
      #normalizedTrainerPairs,
      "pairs"
    )
    local messageBank = decodedMessageBanks.scriptController
    local messageKeys = {}
    for key in pairs(Sources.MENU_MESSAGES) do
      messageKeys[#messageKeys + 1] = key
    end
    table.sort(messageKeys)
    local messageEntries = {}
    local messageProvenance = {}
    for _, key in ipairs(messageKeys) do
      local messageId = Sources.MENU_MESSAGES[key]
      local tokens, tokenFailure = UiMessageBank.tokens(messageBank, 197, messageId, charmap)
      if tokens == nil then
        error(
          Errors.new("BATTLE_MENU_MESSAGE_INVALID", "battle menu text selector is absent or malformed", {
            message = key,
            messageId = messageId,
            cause = tokenFailure and tokenFailure.message or "unknown tokenizer failure",
          }),
          0
        )
      end
      messageEntries[key] = { tokens = tokens }
      messageProvenance[key] = messageId
    end
    local messageRecordKeys = {}
    for key in pairs(Sources.MESSAGE_RECORDS) do
      messageRecordKeys[#messageRecordKeys + 1] = key
    end
    table.sort(messageRecordKeys)
    for _, key in ipairs(messageRecordKeys) do
      local source = Sources.MESSAGE_RECORDS[key]
      local memberId = Sources.MESSAGE_BANKS[source.bank]
      local tokens, tokenFailure =
        UiMessageBank.tokens(decodedMessageBanks[source.bank], memberId, source.messageId, charmap)
      if tokens == nil then
        error(
          Errors.new("BATTLE_MENU_MESSAGE_INVALID", "source battle message record is absent or malformed", {
            message = key,
            role = source.bank,
            memberId = memberId,
            messageId = source.messageId,
            cause = tokenFailure and tokenFailure.message or "unknown tokenizer failure",
          }),
          0
        )
      end
      messageEntries[key] = { tokens = tokens }
      messageProvenance[key] = { bankRole = source.bank, messageId = source.messageId }
    end

    local messageRoutes = {}
    for routeKey, route in pairs(Sources.MENU_MESSAGE_ROUTES) do
      local copy = { inputs = route.inputs }
      if route.template ~= nil then
        copy.template = route.template
      end
      if route.templates ~= nil then
        copy.templates = route.templates
      end
      if route.variants ~= nil then
        copy.variants = route.variants
      end
      if route.branches ~= nil then
        copy.branches = route.branches
      end
      messageRoutes[routeKey] = copy
    end
    local sourceMessageRoutes = Sources.MESSAGE_ROUTES
    local dynamicMessageRoutes = {
      captureShake = {
        bank = messageBanks[sourceMessageRoutes.captureShake.bank],
        input = sourceMessageRoutes.captureShake.input,
        firstRecord = sourceMessageRoutes.captureShake.firstRecord,
        minimum = sourceMessageRoutes.captureShake.minimum,
        maximum = sourceMessageRoutes.captureShake.maximum,
        recordCount = sourceMessageRoutes.captureShake.recordCount,
      },
      metBillPCTransfer = {
        banks = { messageBanks.scriptController },
        inputs = sourceMessageRoutes.metBillPCTransfer.inputs,
        cases = sourceMessageRoutes.metBillPCTransfer.cases,
      },
      frontierTrainerSpeech = {
        banks = {
          messageBanks.frontierTrainerProfileZero,
          messageBanks.frontierTrainerProfileFallback,
        },
        inputs = sourceMessageRoutes.frontierTrainerSpeech.inputs,
        profilePredicate = sourceMessageRoutes.frontierTrainerSpeech.profilePredicate,
        recordFormula = sourceMessageRoutes.frontierTrainerSpeech.recordFormula,
      },
      trainerPairSpeech = {
        bank = messageBanks.trainerPairLookup,
        inputs = sourceMessageRoutes.trainerPairSpeech.inputs,
        selection = {
          lookup = sourceMessageRoutes.trainerPairSpeech.selection.lookup,
          offsetsResource = trainerTables.offsetsResource,
          pairsResource = trainerTables.pairsResource,
          offsetSelection = trainerTables.offsetSelection,
          pairSelection = trainerTables.pairSelection,
        },
      },
      tutorialAuthor = {
        bank = messageBanks.tutorialAuthor,
        input = sourceMessageRoutes.tutorialAuthor.input,
        variants = sourceMessageRoutes.tutorialAuthor.variants,
      },
    }
    local messageBankRoleByResourceKey = {}
    for role, resourceKey in pairs(Sources.MESSAGE_BANK_RESOURCE_KEYS) do
      messageBankRoleByResourceKey[resourceKey] = role
    end
    local function semanticBankReferences(sourceRoute)
      local references = {}
      local function addReference(reference)
        if messageBankRoleByResourceKey[reference] ~= nil or resourceCatalog[reference] ~= nil then
          references[#references + 1] = reference
          return
        end
        local resourceKey = messageBanks[reference]
        if resourceKey == nil then
          error(
            Errors.new("BATTLE_MESSAGE_ROUTE_INVALID", "source message route references an unstaged bank key", {
              bank = reference,
            }),
            0
          )
        end
        references[#references + 1] = resourceKey
      end
      if sourceRoute.bankRole ~= nil then
        addReference(sourceRoute.bankRole)
      elseif sourceRoute.banks ~= nil then
        for _, bank in ipairs(sourceRoute.banks) do
          addReference(bank)
        end
      end
      return references
    end
    local normalizedMessageSourceRoutes = {}
    for sourceName, sourceRoute in pairs(Sources.MESSAGE_SOURCE_ROUTES) do
      local key = assert(sourceRoute.key, "message source route has a semantic key")
      local inputs = sourceRoute.inputs or sourceRoute.operands
      if inputs == nil and sourceRoute.input ~= nil then
        inputs = { sourceRoute.input }
      end
      local route = {
        banks = semanticBankReferences(sourceRoute),
        inputs = inputs or {},
      }
      if sourceRoute.programContext ~= nil then
        route.programContext = sourceRoute.programContext
      end
      if sourceRoute.placeholderPlan ~= nil then
        route.placeholderPlan = sourceRoute.placeholderPlan
      end
      if sourceRoute.mailExpansion ~= nil then
        route.expansion = sourceRoute.mailExpansion
      end
      if sourceRoute.mailCase ~= nil then
        route.selectionCase = sourceRoute.mailCase
      end
      if sourceRoute.placeholders ~= nil then
        route.placeholderInputs = sourceRoute.placeholders
      end
      if sourceRoute.buffers ~= nil then
        route.bufferPlan = sourceRoute.buffers
      end
      if sourceRoute.selection ~= nil then
        route.selection = sourceRoute.selection
      end
      if sourceRoute.recordSelection ~= nil then
        route.recordSelection = sourceRoute.recordSelection
      end
      if sourceRoute.resources ~= nil then
        route.resources = sourceRoute.resources
      end
      if sourceRoute.routes ~= nil then
        route.routes = sourceRoute.routes
      end
      if sourceRoute.reachable ~= nil then
        route.reachableCases = sourceRoute.reachable
      end
      if sourceRoute.unresolved ~= nil then
        route.unresolvedCases = sourceRoute.unresolved
      end
      if sourceName == "frontierTrainerSpeech" then
        route.recordFormula = sourceMessageRoutes.frontierTrainerSpeech.recordFormula
        route.profilePredicate = sourceMessageRoutes.frontierTrainerSpeech.profilePredicate
      elseif sourceName == "trainerPairSpeech" then
        route.recordSelection = sourceMessageRoutes.trainerPairSpeech.recordSelection
      elseif sourceName == "recorderFeedback" then
        route.routes = { "menu/vs-recorder-feedback" }
      end
      normalizedMessageSourceRoutes[key] = route
    end
    local placeholderBanks = {}
    for placeholderRole, bankRole in pairs(Sources.MESSAGE_PLACEHOLDER_BANKS) do
      placeholderBanks[placeholderRole] = messageBanks[bankRole]
    end
    local placeholderSchemas = {}
    for role, sourceSchema in pairs(Sources.MESSAGE_PLACEHOLDER_SCHEMAS) do
      placeholderSchemas[role] = {
        bank = messageBanks[sourceSchema.bankRole],
        input = sourceSchema.input,
      }
    end
    local messageTagSchemas = {}
    for sourceTag, slots in pairs(Sources.MESSAGE_TAG_SCHEMAS) do
      local key = sourceTag:gsub("^TAG_", ""):lower():gsub("_", "-")
      messageTagSchemas[key] = slots
    end
    local messageTagInputs = {}
    for role, resolver in pairs(Sources.MESSAGE_TAG_CONTEXT_RESOLVERS) do
      local normalized = { input = resolver.input, output = resolver.result }
      if resolver.selectors ~= nil then
        normalized.selection = resolver.selectors
      end
      messageTagInputs[role] = normalized
    end
    local messageTemplateInputs = {}
    for role, sourceInput in pairs(Sources.MESSAGE_TEMPLATE_INPUTS) do
      local normalized = { input = sourceInput.input }
      if sourceInput.dependency ~= nil then
        normalized.dependency = sourceInput.dependency
      end
      if sourceInput.supported ~= nil then
        normalized.supported = sourceInput.supported
      end
      if sourceInput.reason ~= nil then
        normalized.reason = sourceInput.reason
      end
      messageTemplateInputs[role] = normalized
    end
    local transitionNameBank = decodedMessageBanks.transitionName
    local transitionNameKey = "transition/trainer-name"
    local transitionNameTokens, transitionNameTokenFailure = UiMessageBank.tokens(
      transitionNameBank,
      Sources.TRANSITION_MESSAGE_MEMBER,
      Sources.TRANSITION_MESSAGE_ID,
      charmap
    )
    if transitionNameTokens == nil then
      error(
        Errors.new("BATTLE_TRANSITION_MESSAGE_INVALID", "transition name text is absent or malformed", {
          memberId = Sources.TRANSITION_MESSAGE_MEMBER,
          messageId = Sources.TRANSITION_MESSAGE_ID,
          cause = transitionNameTokenFailure and transitionNameTokenFailure.message or "unknown tokenizer failure",
        }),
        0
      )
    end
    messageEntries[transitionNameKey] = { tokens = transitionNameTokens }
    messageRoutes[transitionNameKey] = { template = transitionNameKey, inputs = { "trainerName" } }
    messageRoutes["transition/rival-name"] = { template = transitionNameKey, inputs = { "rivalName" } }
    local transitionMessageProvenance = {
      archive = Sources.MENU_MESSAGE_BANK,
      memberId = Sources.TRANSITION_MESSAGE_MEMBER,
      messageId = Sources.TRANSITION_MESSAGE_ID,
    }

    local menuModeRules = {}
    for mode, rule in pairs(Sources.MENU_MODE_RULES) do
      local labels = {}
      for slot, key in pairs(rule.labels) do
        labels[slot] = key
      end
      local dynamicFields = {}
      for index, field in ipairs(rule.dynamicFields) do
        dynamicFields[index] = field
      end
      menuModeRules[mode] = { labels = labels, dynamicFields = dynamicFields }
    end

    local menuLayouts = {}
    local menuLayoutProvenance = {}
    local function compileMenuLayoutResource(layoutKey, slot, source, archive)
      local bytes = must(archive:readMember(source.memberId), "menu layout source member is absent")
      local pathSlot = slot:gsub("%u", function(letter)
        return "-" .. letter:lower()
      end)
      local resourceKey = "menu/layout/" .. layoutKey .. "/" .. pathSlot
      local label = "menu layout " .. layoutKey .. " " .. slot
      local decoded
      local format
      local geometry
      if source.kind == "texture" then
        decoded = decodeChars(archive, source.memberId, label)
        format = decoded.depth == 3 and "nitro-char-4bpp-v1" or "nitro-char-8bpp-v1"
        geometry = { depth = decoded.depth, tileCount = #decoded.tiles / (decoded.depth == 3 and 32 or 64) }
      elseif source.kind == "palette" then
        decoded = decodePalette(archive, source.memberId, label)
        format = "nitro-palette-rgb888-v1"
        geometry = { colorCount = #decoded.colors }
      elseif source.kind == "map" then
        decoded = decodeScreen(archive, source.memberId, label)
        format = "nitro-bg-map-v1"
        geometry = { width = decoded.width, height = decoded.height, entryCount = #decoded.entries }
      elseif source.kind == "cell" then
        decoded = decodeCells(archive, source.memberId, label)
        format = "nitro-obj-cells-v1"
        local bounds = {}
        for index, cell in ipairs(decoded.cells) do
          local minX, minY, maxX, maxY
          for _, obj in ipairs(cell.objs) do
            minX = minX == nil and obj.x or math.min(minX, obj.x)
            minY = minY == nil and obj.y or math.min(minY, obj.y)
            maxX = math.max(maxX or (obj.x + obj.width), obj.x + obj.width)
            maxY = math.max(maxY or (obj.y + obj.height), obj.y + obj.height)
          end
          bounds[index] = minX == nil and { x = 0, y = 0, width = 0, height = 0 }
            or { x = minX, y = minY, width = maxX - minX, height = maxY - minY }
        end
        geometry = { cellCount = #decoded.cells, bounds = bounds }
      elseif source.kind == "animation" then
        decoded = decodeAnimation(archive, source.memberId, label)
        format = "nitro-obj-animation-v1"
        local frameCount = 0
        for _, animation in ipairs(decoded.anims) do
          frameCount = frameCount + #animation.frames
        end
        geometry = { animationCount = #decoded.anims, frameCount = frameCount, durationUnit = "native-frame" }
      else
        error(
          Errors.new("BATTLE_RESOURCE_KIND_UNKNOWN", "menu layout resource has no decoder", {
            resource = resourceKey,
            kind = source.kind,
          }),
          0
        )
      end
      local path = BattlePresentationCache.globalResourcePath(resourceKey)
      resourcePayloads[path] = decoded
      resourceCatalog[resourceKey] = {
        kind = source.kind,
        contentIdentity = Hashing.sha1hex(bytes),
        format = format,
        geometry = geometry,
        path = path,
      }
      menuLayoutProvenance[resourceKey] = {
        archive = source.archive,
        memberId = source.memberId,
      }
      return resourceKey, decoded
    end

    local frontierSources = Sources.MENU_LAYOUT_RESOURCES.frontier
    local frontierCharacterKey, frontierCharacterSource =
      compileMenuLayoutResource("frontier", "character", frontierSources.character, lower)
    local frontierCharacter = requireMenuCharacters(frontierCharacterSource)
    local frontierPaletteKey, frontierPaletteSource =
      compileMenuLayoutResource("frontier", "palette", frontierSources.palette, lower)
    local frontierPalette = requireMenuPalette(frontierPaletteSource)
    local frontierTilemapKey, frontierTilemapSource =
      compileMenuLayoutResource("frontier", "tilemap", frontierSources.tilemap, lower)
    local frontierTilemap = requireMenuScreen(frontierTilemapSource)
    checkScreenSize(frontierTilemap, 256, 256, "Frontier lower-screen menu")
    local frontierRaster = G2dRasterizer.renderScreen(frontierCharacter, frontierPalette, frontierTilemap, {
      asset = Sources.LOWER_NARC,
      role = "Frontier lower-screen menu",
    })
    stageSlice("menu-frontier-layout", frontierRaster.pixels, frontierRaster.width, frontierRaster.height)
    menuLayouts.frontier = {
      image = BattlePresentationCache.globalImagePath("menu-frontier-layout"),
      character = frontierCharacterKey,
      palette = frontierPaletteKey,
      tilemap = frontierTilemapKey,
    }
    menuLayouts.frontier.touchPalette =
      compileMenuLayoutResource("frontier", "touchPalette", frontierSources.touchPalette, lower)

    local vsRecorderSource = Sources.MENU_LAYOUT_RESOURCES.vsRecorder.tilemap
    local vsRecorderTilemapKey, vsRecorderTilemapSource =
      compileMenuLayoutResource("vs-recorder", "tilemap", vsRecorderSource, lower)
    local vsRecorderTilemap = requireMenuScreen(vsRecorderTilemapSource)
    checkScreenSize(vsRecorderTilemap, 256, 256, "VS Recorder lower-screen menu")
    local vsRecorderRaster = G2dRasterizer.renderScreen(lowerChars, lowerPalette, vsRecorderTilemap, {
      asset = Sources.LOWER_NARC,
      role = "VS Recorder lower-screen menu",
    })
    stageSlice("menu-vs-recorder-layout", vsRecorderRaster.pixels, vsRecorderRaster.width, vsRecorderRaster.height)
    menuLayouts.vsRecorder = {
      image = BattlePresentationCache.globalImagePath("menu-vs-recorder-layout"),
      tilemap = vsRecorderTilemapKey,
    }

    local bugContestResources = {}
    local bugContestSceneArchive = openArchive(romFs, Sources.SCENE_NARC, "battle scene")
    for slot, source in pairs(Sources.MENU_LAYOUT_RESOURCES.bugContest) do
      local archive = source.archive == Sources.SCENE_NARC and bugContestSceneArchive or lower
      bugContestResources[slot] = compileMenuLayoutResource("bug-contest", slot, source, archive)
    end
    menuLayouts.bugContest = {
      character = bugContestResources.character,
      palette = bugContestResources.palette,
      cell = bugContestResources.cell,
      animation = bugContestResources.animation,
      sprites = Sources.BUG_CONTEST_SPRITES,
    }

    local pictureAttributes, pictureSelectors = compilePictureAttributes(romFs)

    local menuSelectors = {}
    local menuSelectorProvenance = {}
    for routeKey, route in pairs(Sources.MENU_ROUTES) do
      local selector = { screenGroup = route.screenGroup, textSet = route.textSet }
      if route.mode ~= nil then
        selector.mode = route.mode
      end
      if route.phase ~= nil then
        selector.phase = route.phase
      end
      menuSelectors[routeKey] = selector
      menuSelectorProvenance[routeKey] = route.sourceSelector
    end
    local menuRuntimeContexts = {}
    for contextKey, route in pairs(Sources.MENU_RUNTIME_CONTEXTS) do
      local inputs = {}
      for index, input in ipairs(route.inputs) do
        inputs[index] = input
      end
      local assetRoles = {}
      for index, role in ipairs(route.assetRoles) do
        assetRoles[index] = role
      end
      menuRuntimeContexts[contextKey] = { inputs = inputs, assetRoles = assetRoles }
    end
    local function copyMenuContext(value)
      if type(value) ~= "table" then
        return value
      end
      local copy = {}
      for key, nested in pairs(value) do
        if key ~= "sourceSelector" and key ~= "predicate" then
          copy[key] = copyMenuContext(nested)
        end
      end
      return copy
    end
    local menuContexts = {}
    for key, sourceContext in pairs(Sources.MENU_CONTEXTS) do
      menuContexts[key] = copyMenuContext(sourceContext)
    end
    menuContexts.frontier.input = "frontierBattle"
    local menuTextSets = {
      none = { entries = {}, routes = {}, fonts = {} },
      main = { entries = { "label/cancel", "label/run" }, routes = {}, fonts = { "menu" } },
      ["pal-park"] = { entries = {}, routes = {}, fonts = { "menu" } },
      fight = {
        entries = { "label/pp", "label/pp-max", "label/target-cancel" },
        routes = { "menu/give-up-move" },
        fonts = { "menu" },
      },
      target = {
        entries = {
          "label/target-cancel",
          "label/target-gender-male",
          "label/target-gender-female",
          "label/target-gender-unknown",
        },
        routes = {},
        fonts = { "menu" },
      },
      ["yes-no"] = { entries = { "label/yes", "label/no" }, routes = {}, fonts = { "menu" } },
      ["keep-forget"] = { entries = { "label/keep-move", "label/forget-move" }, routes = {}, fonts = { "menu" } },
      ["give-up"] = { entries = {}, routes = { "menu/give-up-move" }, fonts = { "menu" } },
      ["switch-or-flee"] = {
        entries = { "label/switch", "label/flee", "label/switch-flee" },
        routes = {},
        fonts = { "menu" },
      },
      ["switch-or-keep"] = {
        entries = { "label/switch", "label/keep-battling-switch" },
        routes = {},
        fonts = { "menu" },
      },
      ["vs-recorder"] = {
        entries = { "label/recorder-stop" },
        routes = { "menu/vs-recorder-feedback" },
        fonts = { "menu", "recorderFeedback" },
      },
    }
    for _, rule in pairs(Sources.MENU_MODE_RULES) do
      for _, key in pairs(rule.labels) do
        menuTextSets.main.entries[#menuTextSets.main.entries + 1] = key
      end
    end
    for _, key in pairs(Sources.MENU_MODE_RULES["pal-park"].labels) do
      menuTextSets["pal-park"].entries[#menuTextSets["pal-park"].entries + 1] = key
    end
    local menuRoutes = {}
    for routeKey, route in pairs(Sources.MENU_ROUTES) do
      local textSet = assert(menuTextSets[route.textSet], "menu text set is source-defined")
      local normalized = {
        screenGroup = route.screenGroup,
        textSet = route.textSet,
        messageEntries = {},
        messageRoutes = {},
        fontRoles = {},
        assetRoles = {},
        assetBindings = {},
        requiredContext = {},
        resources = {},
      }
      for _, key in ipairs(textSet.entries) do
        normalized.messageEntries[#normalized.messageEntries + 1] = key
      end
      for _, key in ipairs(textSet.routes) do
        normalized.messageRoutes[#normalized.messageRoutes + 1] = key
      end
      for _, role in ipairs(textSet.fonts) do
        normalized.fontRoles[#normalized.fontRoles + 1] = role
      end
      if route.screenGroup == "command" then
        normalized.requiredContext[#normalized.requiredContext + 1] = "main"
        normalized.requiredContext[#normalized.requiredContext + 1] = "frontier"
        for _, resource in pairs(menuLayouts.frontier) do
          if type(resource) == "string" and resourceCatalog[resource] ~= nil then
            normalized.resources[#normalized.resources + 1] = resource
          end
        end
        normalized.assetRoles[#normalized.assetRoles + 1] = "frontierMenuLayout"
      elseif route.screenGroup == "fight" then
        normalized.requiredContext[#normalized.requiredContext + 1] = "moveSelection"
        normalized.assetRoles[#normalized.assetRoles + 1] = "moveTypeIcon"
      elseif route.screenGroup == "target" then
        normalized.requiredContext[#normalized.requiredContext + 1] = "targetSelection"
        normalized.assetRoles[#normalized.assetRoles + 1] = "pokemonIcon"
        normalized.assetBindings.pokemonIcon = {
          catalog = "mon-icons",
          selector = "species-form",
          context = { "targetSelection.candidate.species", "targetSelection.candidate.form" },
          when = "candidate-enabled-and-hit",
        }
        normalized.assetRoles[#normalized.assetRoles + 1] = "battleCondition"
      elseif route.screenGroup == "vs-recorder" then
        normalized.requiredContext[#normalized.requiredContext + 1] = "vsRecorder"
        normalized.resources[#normalized.resources + 1] = menuLayouts.vsRecorder.tilemap
      end
      if route.mode == "bug-contest" then
        normalized.requiredContext[#normalized.requiredContext + 1] = "bugContest"
        normalized.assetRoles[#normalized.assetRoles + 1] = "pokemonIcon"
        normalized.assetBindings.pokemonIcon = {
          catalog = "mon-icons",
          selector = "species-form",
          context = { "bugContest.caughtPokemon.species", "bugContest.caughtPokemon.form" },
          when = "caught-mon-present",
        }
        normalized.fontRoles[#normalized.fontRoles + 1] = "bugContest"
        for _, messageRouteKey in ipairs({
          "menu/bug-contest-caught-gender",
          "menu/bug-contest-level",
          "menu/bug-contest-remaining-balls",
        }) do
          normalized.messageRoutes[#normalized.messageRoutes + 1] = messageRouteKey
        end
        for _, resource in pairs(menuLayouts.bugContest) do
          if type(resource) == "string" and resourceCatalog[resource] ~= nil then
            normalized.resources[#normalized.resources + 1] = resource
          end
        end
      end
      if route.mode ~= nil then
        normalized.mode = route.mode
      end
      if route.phase ~= nil then
        normalized.phase = route.phase
      end
      table.sort(normalized.messageEntries)
      table.sort(normalized.messageRoutes)
      table.sort(normalized.fontRoles)
      table.sort(normalized.assetRoles)
      table.sort(normalized.requiredContext)
      table.sort(normalized.resources)
      for index = #normalized.resources, 2, -1 do
        if normalized.resources[index] == normalized.resources[index - 1] then
          table.remove(normalized.resources, index)
        end
      end
      menuRoutes[routeKey] = normalized
    end

    local transitionArchive = openArchive(romFs, Sources.TRANSITION_ARCHIVE, "battle transitions")
    local transitionResourceSets = {}
    local transitionProvenance = {}
    for _, set in ipairs(Sources.TRANSITION_RESOURCE_SETS) do
      local resourceKeys = {}
      for _, resource in ipairs(set.resources) do
        local bytes, resourceErr = transitionArchive:readMember(resource.member)
        if bytes == nil then
          error(resourceErr, 0)
        end
        local resourceKey = set.key .. "/" .. resource.key
        local label = "transition " .. resourceKey
        local decoded
        local format
        local geometry
        if resource.kind == "palette" then
          decoded = decodePalette(transitionArchive, resource.member, label)
          format = "nitro-palette-rgb888-v1"
          geometry = { colorCount = #decoded.colors }
        elseif resource.kind == "texture" then
          decoded = decodeChars(transitionArchive, resource.member, label)
          format = decoded.depth == 3 and "nitro-char-4bpp-v1" or "nitro-char-8bpp-v1"
          geometry = { depth = decoded.depth, tileCount = #decoded.tiles / (decoded.depth == 3 and 32 or 64) }
        elseif resource.kind == "cell" then
          decoded = decodeCells(transitionArchive, resource.member, label)
          local sourceMapping, mappingErr = G2dDecoder.decodeCellMapping(bytes, { label = label })
          local mapping = mustDecode(sourceMapping, mappingErr, label .. " mapping", resource.member)
          local characterKey = assert(resourceKeys.characters, "the route cell follows its character resource")
          local characterResource =
            assert(resourceCatalog[characterKey], "the route character is cataloged before its cell")
          TransitionCellNormalizer.normalize(decoded, mapping, characterResource.geometry.depth)
          format = "nitro-obj-cells-v1"
          local bounds = {}
          for cellIndex, cell in ipairs(decoded.cells) do
            local minX, minY, maxX, maxY
            for _, obj in ipairs(cell.objs) do
              minX = minX == nil and obj.x or math.min(minX, obj.x)
              minY = minY == nil and obj.y or math.min(minY, obj.y)
              maxX = math.max(maxX or (obj.x + obj.width), obj.x + obj.width)
              maxY = math.max(maxY or (obj.y + obj.height), obj.y + obj.height)
            end
            bounds[cellIndex] = minX == nil and { x = 0, y = 0, width = 0, height = 0 }
              or { x = minX, y = minY, width = maxX - minX, height = maxY - minY }
          end
          geometry = { cellCount = #decoded.cells, bounds = bounds }
        elseif resource.kind == "animation" then
          decoded = decodeAnimation(transitionArchive, resource.member, label)
          format = "nitro-obj-animation-v1"
          local frameCount = 0
          for _, animation in ipairs(decoded.anims) do
            frameCount = frameCount + #animation.frames
          end
          geometry = { animationCount = #decoded.anims, frameCount = frameCount, durationUnit = "native-frame" }
        else
          error(
            Errors.new("BATTLE_RESOURCE_KIND_UNKNOWN", "transition resource has no decoder", {
              resource = resourceKey,
              kind = resource.kind,
            }),
            0
          )
        end
        local path = BattlePresentationCache.globalResourcePath(resourceKey)
        resourcePayloads[path] = decoded
        resourceCatalog[resourceKey] = {
          kind = resource.kind,
          contentIdentity = Hashing.sha1hex(bytes),
          format = format,
          geometry = geometry,
          path = path,
        }
        resourceKeys[resource.key] = resourceKey
        transitionProvenance[resourceKey] = {
          archive = Sources.TRANSITION_ARCHIVE,
          memberId = resource.member,
        }
      end
      transitionResourceSets[set.key] = resourceKeys
    end
    local transitionSourceResources = {}
    local transitionResourceMembers = {}
    local transitionResourceKeySet = {}
    for _, source in ipairs(Sources.TRANSITION_TYPED_RESOURCES) do
      local provenanceKey = source.kind .. ":" .. source.memberId
      local prior = transitionSourceResources[provenanceKey]
      if prior == nil then
        local bytes, readErr = transitionArchive:readMember(source.memberId)
        if bytes == nil then
          error(readErr, 0)
        end
        local contentIdentity = Hashing.sha1hex(bytes)
        local resourceKey = "transition/content/" .. source.kind .. "/" .. contentIdentity
        local label = "transition member " .. source.memberId .. " payload " .. resourceKey
        local decoded
        local format
        local geometry
        if source.kind == "palette" then
          decoded = decodePalette(transitionArchive, source.memberId, label)
          format = "nitro-palette-rgb888-v1"
          geometry = { colorCount = #decoded.colors }
        elseif source.kind == "texture" then
          decoded = decodeChars(transitionArchive, source.memberId, label)
          format = decoded.depth == 3 and "nitro-char-4bpp-v1" or "nitro-char-8bpp-v1"
          geometry = { depth = decoded.depth, tileCount = #decoded.tiles / (decoded.depth == 3 and 32 or 64) }
        elseif source.kind == "cell" then
          decoded = decodeCells(transitionArchive, source.memberId, label)
          format = "nitro-obj-cells-v1"
          local bounds = {}
          for cellIndex, cell in ipairs(decoded.cells) do
            local minX, minY, maxX, maxY
            for _, obj in ipairs(cell.objs) do
              minX = minX == nil and obj.x or math.min(minX, obj.x)
              minY = minY == nil and obj.y or math.min(minY, obj.y)
              maxX = math.max(maxX or (obj.x + obj.width), obj.x + obj.width)
              maxY = math.max(maxY or (obj.y + obj.height), obj.y + obj.height)
            end
            bounds[cellIndex] = minX == nil and { x = 0, y = 0, width = 0, height = 0 }
              or { x = minX, y = minY, width = maxX - minX, height = maxY - minY }
          end
          geometry = { cellCount = #decoded.cells, bounds = bounds }
        elseif source.kind == "animation" then
          decoded = decodeAnimation(transitionArchive, source.memberId, label)
          format = "nitro-obj-animation-v1"
          local frameCount = 0
          for _, animation in ipairs(decoded.anims) do
            frameCount = frameCount + #animation.frames
          end
          geometry = { animationCount = #decoded.anims, frameCount = frameCount, durationUnit = "native-frame" }
        elseif source.kind == "map" then
          decoded = decodeScreen(transitionArchive, source.memberId, label)
          format = "nitro-bg-map-v1"
          geometry = { width = decoded.width, height = decoded.height, entryCount = #decoded.entries }
        else
          error(
            Errors.new("BATTLE_RESOURCE_KIND_UNKNOWN", "transition source resource has no decoder", {
              memberId = source.memberId,
              kind = source.kind,
            }),
            0
          )
        end
        local path = BattlePresentationCache.globalResourcePath(resourceKey)
        resourcePayloads[path] = decoded
        resourceCatalog[resourceKey] = {
          kind = source.kind,
          contentIdentity = contentIdentity,
          format = format,
          geometry = geometry,
          path = path,
        }
        transitionResourceKeySet[resourceKey] = true
        if transitionResourceMembers[resourceKey] == nil then
          transitionResourceMembers[resourceKey] = {
            archive = Sources.TRANSITION_ARCHIVE,
            members = {},
          }
        end
        transitionSourceResources[provenanceKey] = resourceKey
      end
      for _, sourceSelector in ipairs(source.selectors) do
        local memberProvenance = transitionResourceMembers[transitionSourceResources[provenanceKey]]
        local sourceProvenance = memberProvenance.members[source.memberId]
        if sourceProvenance == nil then
          sourceProvenance = { selectors = {} }
          memberProvenance.members[source.memberId] = sourceProvenance
        end
        sourceProvenance.selectors[sourceSelector] = true
      end
    end
    local transitionParticleMembers = {}
    local embeddedParticleResources = {}
    local function stageParticlePayload(kind, bytes)
      local identity = Hashing.sha1hex(bytes)
      local key = "transition/content/" .. kind .. "/" .. identity
      if resourceCatalog[key] == nil then
        local path = BattlePresentationCache.globalResourcePath(key)
        resourceCatalog[key] = {
          kind = kind,
          contentIdentity = identity,
          format = kind == "texture" and "nitro-spl-texture-data-v1" or "nitro-spl-palette-data-v1",
          geometry = { byteCount = #bytes },
          path = path,
        }
        resourcePayloads[path] = { bytes = bytes }
        transitionResourceKeySet[key] = true
      end
      return key
    end
    for _, memberId in ipairs(Sources.TRANSITION_PARTICLE_MEMBERS) do
      local bytes, readErr = transitionArchive:readMember(memberId)
      if bytes == nil then
        error(readErr, 0)
      end
      local decoded, decodeErr = Spl.decode(bytes)
      if decoded == nil then
        error(decodeErr, 0)
      end
      local contentIdentity = Hashing.sha1hex(bytes)
      local resourceKey = "transition/content/particle/" .. contentIdentity
      local embeddedKeys = {}
      for resourceIndex, resource in ipairs(decoded.resources) do
        local textureKey = resource.texture and stageParticlePayload("texture", resource.texture) or nil
        if resource.textureReference ~= nil then
          local referenced = embeddedKeys[resource.textureReference + 1]
          if referenced == nil or referenced.texture == nil then
            error(
              Errors.new("BATTLE_PARTICLE_RESOURCE_INVALID", "APS texture reference has no staged source", {
                memberId = memberId,
                resourceIndex = resourceIndex - 1,
                textureReference = resource.textureReference,
              }),
              0
            )
          end
          textureKey = referenced.texture
        end
        local paletteKey = resource.palette and stageParticlePayload("palette", resource.palette) or nil
        embeddedKeys[resourceIndex] = { texture = textureKey, palette = paletteKey }
      end
      local normalizedResources = {}
      for index in ipairs(decoded.resources) do
        local embedded = embeddedKeys[index]
        normalizedResources[index] = {
          textureKey = embedded.texture,
          paletteKey = embedded.palette,
        }
      end
      local normalizedParticle = {
        format = decoded.format,
        emitters = decoded.emitters,
        resources = normalizedResources,
        source = decoded.source,
      }
      local path = BattlePresentationCache.globalResourcePath(resourceKey)
      resourceCatalog[resourceKey] = {
        kind = "particle",
        contentIdentity = contentIdentity,
        format = "nitro-spl-aps-v1",
        geometry = { emitterCount = #decoded.emitters, resourceCount = #decoded.resources },
        path = path,
      }
      resourcePayloads[path] = normalizedParticle
      transitionResourceKeySet[resourceKey] = true
      transitionSourceResources["particle:" .. memberId] = resourceKey
      transitionParticleMembers[resourceKey] = { archive = Sources.TRANSITION_ARCHIVE, memberId = memberId }
      embeddedParticleResources[resourceKey] = embeddedKeys
    end
    local function resourcesForSourceSelectors(selectors)
      local selected = {}
      for _, source in ipairs(Sources.TRANSITION_TYPED_RESOURCES) do
        local included = false
        for _, sourceSelector in ipairs(source.selectors) do
          for _, selector in ipairs(selectors) do
            if sourceSelector == selector then
              included = true
              break
            end
          end
          if included then
            break
          end
        end
        if included then
          local key = transitionSourceResources[source.kind .. ":" .. source.memberId]
          selected[key] = true
        end
      end
      local keys = {}
      for key in pairs(selected) do
        keys[#keys + 1] = key
      end
      table.sort(keys)
      return keys
    end
    local transitionMessageRoutes = {}
    for routeName, sourceRoute in pairs(Sources.TRANSITION_MESSAGE_SOURCE_ROUTES) do
      local input = routeName == "trainerName" and "trainerName" or "rivalName"
      transitionMessageRoutes[routeName] = {
        message = transitionNameKey,
        inputs = { input },
        resources = resourcesForSourceSelectors(sourceRoute.selectors),
      }
    end
    local transitionInternalResources = {}
    local sourceResourceKinds = { palette = "palette", character = "texture", cell = "cell", animation = "animation" }
    for routeName, sourceResources in pairs(Sources.TRANSITION_INTERNAL_RESOURCES) do
      local resourceKeys = {}
      for role, memberId in pairs(sourceResources) do
        local resourceKey = transitionSourceResources[sourceResourceKinds[role] .. ":" .. memberId]
        if resourceKey == nil then
          error(
            Errors.new("BATTLE_TRANSITION_RESOURCE_UNRESOLVED", "internal transition resource has no staged member", {
              route = routeName,
              role = role,
            }),
            0
          )
        end
        resourceKeys[role] = resourceKey
      end
      transitionInternalResources[routeName] = resourceKeys
    end
    local function transitionResourceForRole(role, memberId, routeKey)
      local kindByRole = {
        palette = "palette",
        character = "texture",
        characters = "texture",
        cell = "cell",
        animation = "animation",
        map = "map",
        maps = "map",
      }
      local kind = kindByRole[role]
      if kind == nil then
        error(
          Errors.new("BATTLE_TRANSITION_RESOURCE_UNRESOLVED", "transition route has an unknown resource role", {
            role = role,
          }),
          0
        )
      end
      local resourceKey = transitionSourceResources[kind .. ":" .. memberId]
      if resourceKey == nil then
        error(
          Errors.new(
            "BATTLE_TRANSITION_RESOURCE_UNRESOLVED",
            "transition route " .. routeKey .. " references unstaged " .. role .. " member " .. memberId,
            { role = role, memberId = memberId, route = routeKey }
          ),
          0
        )
      end
      return resourceKey
    end
    local function normalizeTransitionResourceGroup(group, routeKey)
      local normalized = {}
      for role, value in pairs(group) do
        if type(value) == "number" then
          normalized[role] = transitionResourceForRole(role, value, routeKey)
        elseif type(value) == "table" then
          local entries = {}
          for index, entry in ipairs(value) do
            if type(entry) == "number" then
              entries[index] = transitionResourceForRole(role, entry, routeKey)
            else
              entries[index] = normalizeTransitionResourceGroup(entry, routeKey)
            end
          end
          if #entries > 0 then
            normalized[role] = entries
          else
            normalized[role] = normalizeTransitionResourceGroup(value, routeKey)
          end
        else
          error(
            Errors.new("BATTLE_TRANSITION_RESOURCE_UNRESOLVED", "transition route resource group is malformed", {
              role = role,
            }),
            0
          )
        end
      end
      return normalized
    end
    local transitionRoutes = {}
    for selector, sourceRoute in pairs(Sources.TRANSITION_SELECTOR_ROUTES) do
      local resourceKeys = resourcesForSourceSelectors({ selector })
      local resourceSet = {}
      for _, resourceKey in ipairs(resourceKeys) do
        resourceSet[resourceKey] = true
      end
      local groups = {}
      for _, groupName in ipairs({
        "sprite",
        "record",
        "fixedSprite",
        "extraSprite",
        "opponent",
        "nameplate",
        "spriteVariants",
        "background",
        "sceneAssets",
      }) do
        local sourceGroup = sourceRoute[groupName]
        if sourceGroup ~= nil then
          groups[groupName] = normalizeTransitionResourceGroup(sourceGroup, sourceRoute.key)
        end
      end
      if sourceRoute.particles ~= nil then
        local particles = {}
        for role, memberId in pairs(sourceRoute.particles) do
          local resourceKey = transitionSourceResources["particle:" .. memberId]
          if resourceKey == nil then
            error(
              Errors.new("BATTLE_TRANSITION_RESOURCE_UNRESOLVED", "transition route particle payload is not staged", {
                memberId = memberId,
                route = sourceRoute.key,
              }),
              0
            )
          end
          particles[role] = resourceKey
          resourceSet[resourceKey] = true
        end
        groups.particles = particles
      end
      local groupSet = {}
      local function collectGroup(value)
        if type(value) == "string" then
          groupSet[value] = true
        elseif type(value) == "table" then
          for _, nested in pairs(value) do
            collectGroup(nested)
          end
        end
      end
      collectGroup(groups)
      for resourceKey in pairs(groupSet) do
        resourceSet[resourceKey] = true
      end
      local routeResources = {}
      for resourceKey in pairs(resourceSet) do
        routeResources[#routeResources + 1] = resourceKey
      end
      table.sort(routeResources)
      local requiredContext = {}
      local contextSet = {}
      local function requireContext(name)
        if not contextSet[name] then
          contextSet[name] = true
          requiredContext[#requiredContext + 1] = name
        end
      end
      if sourceRoute.key:match("^fallback/") then
        requireContext("battleType")
        requireContext("terrain")
        requireContext("timeOfDay")
      elseif sourceRoute.key:match("^wild/") then
        requireContext("wildSpecies")
        requireContext("battleType")
      elseif sourceRoute.key:match("^trainer/") then
        requireContext("trainerClass")
        requireContext("battleType")
      end
      if sourceRoute.context ~= nil and sourceRoute.context.playerGender == true then
        requireContext("playerGender")
      end
      local trainer
      if sourceRoute.trainer ~= nil then
        trainer = { key = sourceRoute.trainer.key }
        requireContext("transitionTrainer")
      end
      local messages = {}
      if sourceRoute.messageRoute ~= nil then
        messages[1] = sourceRoute.messageRoute
        if sourceRoute.messageRoute == "transition/rival-name" then
          requireContext("rivalName")
        else
          requireContext("trainerName")
        end
      end
      table.sort(requiredContext)
      local route = {
        role = sourceRoute.role,
        requiredContext = requiredContext,
        resources = routeResources,
        assetGroups = groups,
        trainer = trainer,
      }
      if sourceRoute.task ~= nil then
        route.task = sourceRoute.task
      end
      if #messages > 0 then
        route.messages = messages
      end
      local prior = transitionRoutes[sourceRoute.key]
      if prior ~= nil then
        if prior.role ~= route.role then
          error(
            Errors.new("BATTLE_TRANSITION_ROUTE_CONFLICT", "semantic transition key has conflicting source roles", {
              route = sourceRoute.key,
            }),
            0
          )
        end
        if prior.task ~= nil and route.task ~= nil then
          error(
            Errors.new("BATTLE_TRANSITION_ROUTE_CONFLICT", "semantic transition key has conflicting source tasks", {
              route = sourceRoute.key,
            }),
            0
          )
        end
        route.task = route.task or prior.task
        for _, resourceKey in ipairs(route.resources) do
          resourceSet[resourceKey] = true
        end
        for _, resourceKey in ipairs(prior.resources) do
          resourceSet[resourceKey] = true
        end
        route.resources = {}
        for resourceKey in pairs(resourceSet) do
          route.resources[#route.resources + 1] = resourceKey
        end
        table.sort(route.resources)
        for _, input in ipairs(prior.requiredContext) do
          requireContext(input)
        end
        table.sort(requiredContext)
        route.requiredContext = requiredContext
        if #messages == 0 then
          route.messages = prior.messages
        end
      end
      transitionRoutes[sourceRoute.key] = route
    end
    local sourcePreselection = Sources.TRANSITION_PRESELECTION
    local function semanticCategoryRoute(category)
      local route = sourcePreselection.categoryRoutes[category]
      if type(route) == "table" and route.fallback == true then
        return "setup-fallback"
      end
      if type(route) ~= "string" then
        error(
          Errors.new("BATTLE_TRANSITION_ROUTE_UNRESOLVED", "source category has no semantic transition route", {
            category = category,
          }),
          0
        )
      end
      return route
    end
    local function normalizeInputRoutes(sourceRoutes, categories)
      local routes = {}
      for inputKey, routeKey in pairs(sourceRoutes) do
        local category = categories[routeKey]
        if category == nil then
          error(
            Errors.new("BATTLE_TRANSITION_ROUTE_UNRESOLVED", "source input has no semantic category route", {
              input = inputKey,
            }),
            0
          )
        end
        routes[inputKey] = semanticCategoryRoute(category)
      end
      return routes
    end
    local function musicRoleForCategory(category)
      local sequenceSymbol = Sources.INTRO_MUSIC.rows[category + 1]
      assert(sequenceSymbol ~= nil, "every source category selects an intro sequence")
      local role = Sources.INTRO_MUSIC.roles[sequenceSymbol]
      if role == nil and sequenceSymbol == Sources.AUDIO_ROLES.kantoTrainer then
        role = "kanto-trainer"
      end
      assert(type(role) == "string", "every selected intro sequence has a semantic role")
      return role
    end
    local function normalizeInputMusicRoles(sourceRoutes, categories)
      local roles = {}
      for inputKey, routeKey in pairs(sourceRoutes) do
        local category = assert(categories[routeKey], "every source trainer or species route has a category")
        roles[inputKey] = musicRoleForCategory(category)
      end
      return roles
    end
    local trainerClassRoutes =
      normalizeInputRoutes(sourcePreselection.trainerClasses, sourcePreselection.trainerCategoryByKey)
    local wildSpeciesRoutes = normalizeInputRoutes(sourcePreselection.wildSpecies, sourcePreselection.wildCategoryByKey)
    local trainerClassMusicRoles =
      normalizeInputMusicRoles(sourcePreselection.trainerClasses, sourcePreselection.trainerCategoryByKey)
    local wildSpeciesMusicRoles =
      normalizeInputMusicRoles(sourcePreselection.wildSpecies, sourcePreselection.wildCategoryByKey)
    local function categoryRoutesForList(categories)
      local routes = {}
      for _, category in ipairs(categories) do
        routes[#routes + 1] = semanticCategoryRoute(category)
      end
      return routes
    end
    local sourceRules = sourcePreselection.selectionRules
    local transitionSelection = {
      trainerClassRoutes = trainerClassRoutes,
      wildSpeciesRoutes = wildSpeciesRoutes,
      trainerClassMusicRoles = trainerClassMusicRoles,
      wildSpeciesMusicRoles = wildSpeciesMusicRoles,
      trainerRules = {
        inputs = { "trainerClass", "battleType" },
        specialBattle = {
          preserveRoute = semanticCategoryRoute(sourceRules.trainer.specialBattle.preserveCategory),
          preserveMusicRole = musicRoleForCategory(sourceRules.trainer.specialBattle.preserveCategory),
          defaultRoute = semanticCategoryRoute(sourceRules.trainer.specialBattle.defaultCategory),
          defaultMusicRole = musicRoleForCategory(sourceRules.trainer.specialBattle.defaultCategory),
          doublesRoute = semanticCategoryRoute(sourceRules.trainer.specialBattle.doublesCategory),
          doublesMusicRole = musicRoleForCategory(sourceRules.trainer.specialBattle.doublesCategory),
        },
        preserveRoutes = categoryRoutesForList(sourceRules.trainer.preserveCategories),
        doublesRoute = semanticCategoryRoute(sourceRules.trainer.doublesCategory),
        alternateTransitionRoute = semanticCategoryRoute(sourceRules.trainer.alternateCategory),
        unknownRoute = semanticCategoryRoute(41),
        unknownMusicRole = musicRoleForCategory(41),
        doublesMusicRole = musicRoleForCategory(sourceRules.trainer.doublesCategory),
        alternateMusicRole = musicRoleForCategory(sourceRules.trainer.alternateCategory),
      },
      wildRules = {
        inputs = { "wildSpecies", "battleType", "transitionMode" },
        specialMode = "wild-transition-special-case",
        fallbackRoute = semanticCategoryRoute(sourceRules.wild.fallbackCategory),
        fallbackMusicRole = musicRoleForCategory(sourceRules.wild.fallbackCategory),
        doublesRoute = semanticCategoryRoute(sourceRules.wild.doublesCategoryWhenCategoryAtLeast.category),
        doublesMusicRole = musicRoleForCategory(sourceRules.wild.doublesCategoryWhenCategoryAtLeast.category),
      },
      fallbackRoutes = {},
    }
    for selector = 0, 11 do
      local sourceRoute = Sources.TRANSITION_SELECTOR_ROUTES[selector]
      local context = assert(sourceRoute.context)
      transitionSelection.fallbackRoutes[#transitionSelection.fallbackRoutes + 1] = {
        route = sourceRoute.key,
        terrain = context.terrain,
        timeOfDay = context.timeOfDay,
        battleKind = context.isTrainer and "trainer" or "wild",
      }
    end
    local transitionCatalogKeys = {}
    for resourceKey in pairs(transitionResourceKeySet) do
      transitionCatalogKeys[#transitionCatalogKeys + 1] = resourceKey
    end
    table.sort(transitionCatalogKeys)

    local transitionCoverage = {}
    for routeKey, route in pairs(transitionRoutes) do
      local identityParts = { "transition-route", routeKey, route.role }
      for _, input in ipairs(route.requiredContext) do
        identityParts[#identityParts + 1] = "context=" .. input
      end
      for _, resourceKey in ipairs(route.resources) do
        local descriptor = assert(resourceCatalog[resourceKey], "transition route resource is staged")
        identityParts[#identityParts + 1] = resourceKey .. "=" .. descriptor.contentIdentity
      end
      for _, messageKey in ipairs(route.messages or {}) do
        identityParts[#identityParts + 1] = messageKey .. "=" .. Hashing.hashLua(messageEntries[messageKey])
      end
      transitionCoverage["transition/" .. routeKey] = {
        kind = "transition-route",
        route = routeKey,
        closureIdentity = Hashing.sha1hex(table.concat(identityParts, "\n")),
        resources = route.resources,
        operations = { route.role },
      }
    end

    local rootFailures = {}
    local audioCompiler = require("romdump.src.digest.audio.AudioCompiler")
    local audioPlan, audioPlanError = audioCompiler.planSource(romFs)
    local introMusic = compileIntroMusic(romFs, audioPlan, audioPlanError)

    local semanticRoots = Sources.listSemanticRoots()
    local function collectSemanticResources(value, selected)
      if type(value) == "string" then
        if resourceCatalog[value] ~= nil then
          selected[value] = true
        end
      elseif type(value) == "table" then
        for _, nested in pairs(value) do
          collectSemanticResources(nested, selected)
        end
      end
    end
    local sourceMessageRouteKeys = {}
    for sourceName, sourceRoute in pairs(Sources.MESSAGE_SOURCE_ROUTES) do
      sourceMessageRouteKeys[sourceName] = sourceRoute.key
    end
    local function collectMessageClosure(value, selectedResources, selectedMessages, visited, selectedRoutes)
      if type(value) == "string" then
        if resourceCatalog[value] ~= nil then
          selectedResources[value] = true
          return
        end
        if messageEntries[value] ~= nil then
          selectedMessages[value] = true
          return
        end
        local routeKey = sourceMessageRouteKeys[value] or value
        local route = normalizedMessageSourceRoutes[routeKey] or messageRoutes[routeKey] or dynamicMessageRoutes[value]
        if route ~= nil then
          selectedRoutes[routeKey] = true
        end
        if route ~= nil and not visited[routeKey] then
          visited[routeKey] = true
          collectMessageClosure(route, selectedResources, selectedMessages, visited, selectedRoutes)
          return
        end
        local dynamic = dynamicMessageRoutes[value]
        if dynamic ~= nil and not visited[value] then
          visited[value] = true
          selectedRoutes[value] = true
          collectMessageClosure(dynamic, selectedResources, selectedMessages, visited, selectedRoutes)
        end
      elseif type(value) == "table" then
        local firstRecord = value.firstRecord
        local recordCount = value.recordCount
        if type(firstRecord) == "string" and type(recordCount) == "number" then
          local prefix, firstIndex = firstRecord:match("^(.*)/(%d+)$")
          if prefix ~= nil then
            for offset = 0, recordCount - 1 do
              collectMessageClosure(
                prefix .. "/" .. (tonumber(firstIndex) + offset),
                selectedResources,
                selectedMessages,
                visited,
                selectedRoutes
              )
            end
          end
        end
        for key, nested in pairs(value) do
          if key == "placeholderPlan" and nested == "battleMessageTags" then
            collectMessageClosure(
              "battle/message-template",
              selectedResources,
              selectedMessages,
              visited,
              selectedRoutes
            )
          elseif key == "mailExpansion" or key == "expansion" then
            collectMessageClosure(nested, selectedResources, selectedMessages, visited, selectedRoutes)
          elseif key == "routes" then
            collectMessageClosure(nested, selectedResources, selectedMessages, visited, selectedRoutes)
          else
            collectMessageClosure(nested, selectedResources, selectedMessages, visited, selectedRoutes)
          end
        end
      end
    end
    local function sortedSetValues(values)
      local result = {}
      for value in pairs(values) do
        result[#result + 1] = value
      end
      table.sort(result)
      return result
    end
    for _, root in ipairs(semanticRoots) do
      local coverageKey = root.key
      if transitionCoverage[coverageKey] == nil then
        local routeValue
        local selectedResources = {}
        local selectedMessageKeys = {}
        local messageRouteKeys = {}
        if root.kind == "menu-route" then
          routeValue = menuRoutes[root.sourceRouteKey]
          if routeValue ~= nil then
            collectSemanticResources(routeValue.resources, selectedResources)
            collectMessageClosure(
              routeValue.messageEntries,
              selectedResources,
              selectedMessageKeys,
              {},
              messageRouteKeys
            )
            collectMessageClosure(
              routeValue.messageRoutes,
              selectedResources,
              selectedMessageKeys,
              {},
              messageRouteKeys
            )
          end
        elseif root.kind == "message-route" then
          routeValue = normalizedMessageSourceRoutes[root.key]
            or messageRoutes[root.sourceRouteKey]
            or transitionMessageRoutes[root.sourceRouteKey]
          if routeValue ~= nil then
            collectMessageClosure(
              routeValue,
              selectedResources,
              selectedMessageKeys,
              { [root.key] = true },
              messageRouteKeys
            )
          end
        elseif root.kind == "transition-route" then
          local transitionKey = root.sourceRouteKey
          routeValue = transitionRoutes[transitionKey]
          if routeValue ~= nil then
            collectSemanticResources(routeValue.resources, selectedResources)
            collectMessageClosure(routeValue.messages, selectedResources, selectedMessageKeys, {}, messageRouteKeys)
          end
        end
        if routeValue == nil then
          rootFailures[#rootFailures + 1] = root.key .. ": source semantic route is not normalized"
        else
          local resourceKeys = {}
          for resourceKey in pairs(selectedResources) do
            resourceKeys[#resourceKeys + 1] = resourceKey
          end
          table.sort(resourceKeys)
          local identityParts = { root.kind, root.key, Hashing.hashLua(routeValue) }
          for _, resourceKey in ipairs(resourceKeys) do
            identityParts[#identityParts + 1] = resourceKey .. "=" .. resourceCatalog[resourceKey].contentIdentity
          end
          for messageKey in pairs(selectedMessageKeys) do
            if messageEntries[messageKey] ~= nil then
              identityParts[#identityParts + 1] = messageKey .. "=" .. Hashing.hashLua(messageEntries[messageKey])
            end
          end
          for routeKey in pairs(messageRouteKeys) do
            local closureRoute = normalizedMessageSourceRoutes[routeKey]
              or messageRoutes[routeKey]
              or dynamicMessageRoutes[routeKey]
            if closureRoute ~= nil then
              identityParts[#identityParts + 1] = routeKey .. "=" .. Hashing.hashLua(closureRoute)
            end
          end
          if root.kind == "menu-route" then
            for _, fontRole in ipairs(routeValue.fontRoles) do
              identityParts[#identityParts + 1] = fontRole
                .. "="
                .. FieldFontCache.defPath(
                  fontRole == "bugContest" and Sources.BUG_CONTEST_FONT_ID
                    or fontRole == "recorderFeedback" and Sources.RECORDER_FEEDBACK_FONT_ID
                    or Sources.MENU_TEXT_FONT_ID
                )
            end
          end
          table.sort(identityParts)
          local operations = { root.kind }
          transitionCoverage[coverageKey] = {
            kind = root.kind,
            route = root.key,
            closureIdentity = Hashing.sha1hex(table.concat(identityParts, "\n")),
            resources = resourceKeys,
            operations = operations,
            messageEntries = sortedSetValues(selectedMessageKeys),
            messageRoutes = sortedSetValues(messageRouteKeys),
            fontRoles = root.kind == "menu-route" and routeValue.fontRoles or {},
            assetRoles = root.kind == "menu-route" and routeValue.assetRoles or {},
            assetBindings = root.kind == "menu-route" and routeValue.assetBindings or {},
            requiredContext = root.kind == "menu-route" and routeValue.requiredContext or {},
            programContext = root.kind == "message-route" and routeValue.programContext or nil,
          }
        end
      end
    end

    local transitionSelectorFamilies = {}
    for selector, family in pairs(Sources.TRANSITION_SELECTOR_FAMILIES) do
      transitionSelectorFamilies[selector] = family
    end

    local imageManifest = {}
    for name, image in pairs(images) do
      imageManifest[BattlePresentationCache.globalImagePath(name)] = { width = image.width, height = image.height }
    end
    local partialManifest = {
      schema = BattlePresentationSchema.MANIFEST_SCHEMA,
      version = { id = versionId, language = assert(MonSources.versionLanguages[versionId]) },
      catalogIdentity = versionId .. ":" .. romFs:metadata().sha1,
      -- Only a fully compiled bundle proves its dump-backed roles: the
      -- incomplete-job gate below never stages a partial manifest, so a
      -- staged manifest always carries its verification.
      verified = true,
      scenes = BattlePresentationCache.sceneInventory(),
      battlefield = { slots = {} },
      layouts = {
        menu = {
          width = Sources.MENU_LAYOUT.width,
          height = Sources.MENU_LAYOUT.height,
          tilemapWidth = Sources.MENU_LAYOUT.tilemapWidth,
          tilemapHeight = Sources.MENU_LAYOUT.tilemapHeight,
          layers = {},
        },
      },
      hud = {
        player = playerHud,
        enemy = enemyHud,
        doubles = doublesHud,
        arrow = arrow,
        partyGauges = partyGauges,
        patchSpans = Sources.HUD_PATCH_SPANS,
        terrain = {
          type0 = { cells = type0Cells.cells, animation = selectAnimation({ anims = type0Anim.anims }) },
          type1 = { cells = type1Cells.cells, animation = selectAnimation({ anims = type1Anim.anims }) },
        },
        roles = {
          player = "hud/player",
          enemy = "hud/enemy",
          playerLeft = "hud/doubles/player-left",
          playerRight = "hud/doubles/player-right",
          enemyLeft = "hud/doubles/enemy-left",
          enemyRight = "hud/doubles/enemy-right",
          arrow = "hud/arrow",
          gauges = { "hud/gauge/health", "hud/gauge/experience" },
        },
        selectors = {
          single = { player = "player", opponent = "enemy" },
          double = {
            playerLeft = "playerLeft",
            playerRight = "playerRight",
            enemyLeft = "enemyLeft",
            enemyRight = "enemyRight",
          },
        },
      },
      pictures = {
        attributes = pictureAttributes,
        selectors = pictureSelectors,
        shadow = {
          image = BattlePresentationCache.globalImagePath("pokepic-shadow"),
          width = shadowRaster.width,
          height = shadowRaster.height,
          regions = shadowRegions,
        },
      },
      menus = {
        images = imageManifest,
        layouts = menuLayouts,
        routes = menuRoutes,
        command = command,
        moves = moves,
        target = target,
        twoOption = twoOption,
        lower = {
          image = BattlePresentationCache.globalImagePath("lower-chars"),
          palette = { colors = paletteRecords(lowerPalette) },
          variants = lowerVariants,
        },
        roles = {
          command = "menu/command",
          moves = "menu/moves",
          target = "menu/target",
          twoOption = "menu/two-option",
        },
        selectors = menuSelectors,
        modeRules = menuModeRules,
        runLabelSelector = { cancel = "label/cancel", ordinary = "label/run" },
        runtimeContexts = menuRuntimeContexts,
        contexts = menuContexts,
      },
      messages = {
        roles = {
          narration = { font = narrationFont },
          trainerNarration = { font = narrationFont },
          hud = { font = FieldFontCache.defPath(Sources.HUD_MESSAGE_FONT_ID) },
          menu = { font = FieldFontCache.defPath(Sources.MENU_TEXT_FONT_ID) },
          bugContest = { font = FieldFontCache.defPath(Sources.BUG_CONTEST_FONT_ID) },
          recorderFeedback = { font = FieldFontCache.defPath(Sources.RECORDER_FEEDBACK_FONT_ID) },
        },
        entries = messageEntries,
        routes = messageRoutes,
        banks = messageBanks,
        dynamicRoutes = dynamicMessageRoutes,
        placeholderBanks = placeholderBanks,
        sourceRoutes = normalizedMessageSourceRoutes,
        placeholders = placeholderSchemas,
        tagSchemas = messageTagSchemas,
        tagInputs = messageTagInputs,
        templateInputs = messageTemplateInputs,
        templateExpansion = { input = Sources.MESSAGE_TEMPLATE_EXPANSION.input },
      },
      transitions = {
        selectors = {
          trainerEncounter = { inputs = { "trainerClass", "battleType" }, resolved = false },
          wildEncounter = { inputs = { "wildSpecies", "battleType" }, resolved = false },
          setupFallback = {
            inputs = { "battleType", "terrain", "timeOfDay" },
            terrainOffset = Sources.TRANSITION_FALLBACK.terrainOffset,
            offsetTimes = Sources.TRANSITION_FALLBACK.offsetTimes,
            trainerOffset = Sources.TRANSITION_FALLBACK.trainerOffset,
            resolved = false,
          },
        },
        resourceSets = transitionResourceSets,
        resources = transitionCatalogKeys,
        messageRoutes = transitionMessageRoutes,
        internalResources = transitionInternalResources,
        routes = transitionRoutes,
        selection = transitionSelection,
      },
      audioRoles = {
        wild = Sources.AUDIO_ROLES.wild,
        trainer = Sources.AUDIO_ROLES.trainer,
        rival = Sources.AUDIO_ROLES.rival,
        select = Sources.AUDIO_ROLES.select,
        gymLeader = Sources.AUDIO_ROLES.gymLeader,
        rocket = Sources.AUDIO_ROLES.rocket,
        suicune = Sources.AUDIO_ROLES.suicune,
        entei = Sources.AUDIO_ROLES.entei,
        raikou = Sources.AUDIO_ROLES.raikou,
        champion = Sources.AUDIO_ROLES.champion,
        kantoWild = Sources.AUDIO_ROLES.kantoWild,
        kantoTrainer = Sources.AUDIO_ROLES.kantoTrainer,
        kantoGymLeader = Sources.AUDIO_ROLES.kantoGymLeader,
        cries = "species",
        introMusic = introMusic,
      },
      resources = resourceCatalog,
      coverage = transitionCoverage,
    }
    for index, row in ipairs(Sources.SLOT_GEOMETRY) do
      partialManifest.battlefield.slots[index] = {
        sideType = row.sideType,
        settledX = row.settledX,
        settledY = row.settledY,
        entryX = row.entryX,
        entryY = row.entryY,
        depth = row.depth,
        hudX = row.hudX,
        hudY = row.hudY,
        hudPriority = row.hudPriority,
        hudBgPriority = row.hudBgPriority,
      }
    end
    local menuLayerIndices = {}
    for _, layer in ipairs(Sources.MENU_LAYOUT.layers) do
      partialManifest.layouts.menu.layers[#partialManifest.layouts.menu.layers + 1] = {
        key = layer.key,
        x = layer.x,
        y = layer.y,
      }
      menuLayerIndices[layer.key] = layer.index
    end
    local blockers = {}
    if #rootFailures > 0 then
      blockers[#blockers + 1] = "roots: " .. #rootFailures .. " source semantic roots did not close"
      for _, failure in ipairs(rootFailures) do
        blockers[#blockers + 1] = "roots: " .. failure
      end
    end
    local uncoveredRoots = 0
    for _, root in ipairs(semanticRoots) do
      if transitionCoverage[root.key] == nil then
        uncoveredRoots = uncoveredRoots + 1
      end
    end
    if uncoveredRoots > 0 then
      blockers[#blockers + 1] = "coverage: " .. uncoveredRoots .. " semantic roots have no closure identity"
    end
    local provenance = {
      source = Sources.provenance,
      rom = { version = versionId, sha1 = romFs:metadata().sha1 },
      roles = provenanceRoles(),
      menuSelectors = menuSelectorProvenance,
      menuMessageIds = messageProvenance,
      messageBanks = messageBankProvenance,
      messageSourceResources = Sources.MESSAGE_SOURCE_ROUTES,
      trainerMessageTables = trainerTableProvenance,
      recorderFeedbackFlags = Sources.RECORDER_FEEDBACK_SOURCE_FLAGS,
      recorderFeedbackUnreachableFlags = Sources.RECORDER_FEEDBACK_UNREACHABLE_FLAGS,
      frontierTrainerMessageRoute = Sources.FRONTIER_TRAINER_MESSAGE_ROUTE,
      transitionMessage = transitionMessageProvenance,
      transitionMessageRoutes = Sources.TRANSITION_MESSAGE_SOURCE_ROUTES,
      messageDependencies = messageDependencies,
      transitionResources = transitionProvenance,
      transitionSelectorFamilies = transitionSelectorFamilies,
      transitionSelectorRoutes = Sources.TRANSITION_SELECTOR_ROUTES,
      transitionPreselection = Sources.TRANSITION_PRESELECTION,
      transitionSourceResources = transitionSourceResources,
      transitionResourceMembers = transitionResourceMembers,
      transitionParticleMembers = transitionParticleMembers,
      embeddedParticleResources = embeddedParticleResources,
      menuTilemaps = menuTilemapProvenance,
      menuLayouts = menuLayoutProvenance,
      menuLayerIndices = menuLayerIndices,
      hudComponents = {
        source = Sources.HUD_COMPONENTS.source,
        contentIdentity = Hashing.sha1hex(componentBytes),
      },
      pokepicShadow = {
        source = {
          archive = Sources.POKE_SHADOW.archive,
          characterMember = Sources.POKE_SHADOW.characterMember,
          paletteMember = Sources.POKE_SHADOW.paletteMember,
          file = "src/pokepic.c",
          symbol = "PokepicManager_Create / PokepicManager_BufferPlttData / sPokepicShadowUVParams",
        },
        characterIdentity = Hashing.sha1hex(shadowCharacterBytes),
        paletteIdentity = Hashing.sha1hex(shadowPaletteBytes),
      },
      introMusicSources = Sources.INTRO_MUSIC,
    }
    return {
      manifest = partialManifest,
      images = images,
      resourcePayloads = resourcePayloads,
      provenance = provenance,
      blockers = blockers,
    }
  end)
  if not ok then
    if Errors.is(bundle) then
      return nil, bundle
    end
    error(bundle, 0)
  end
  if #bundle.blockers > 0 then
    return nil,
      Errors.new(
        "BATTLE_MANIFEST_INCOMPLETE",
        "source-backed battle presentation sections are available, but semantic root coverage closure remains unresolved",
        {
          version = versionId,
          blockers = bundle.blockers,
          partialCatalog = bundle.manifest,
          images = bundle.images,
          resourcePayloads = bundle.resourcePayloads,
          provenance = bundle.provenance,
        }
      )
  end
  return bundle
end

---@param bytes string
---@return integer[] 1-based byte array
local function byteArray(bytes)
  local values = {}
  for start = 1, #bytes, 4096 do
    local stop = math.min(start + 4095, #bytes)
    local chunk = { string.byte(bytes, start, stop) }
    for _, value in ipairs(chunk) do
      values[#values + 1] = value
    end
  end
  return values
end

---@param cells string 0x1000 terrain 4bpp bytes
---@param position integer 0-based byte position
---@return integer byte value
local function cellByte(cells, position)
  local value = string.byte(cells, position + 1)
  return must(value, "terrain cells end before their documented extent")
end

-- Bake terrain type-1 over destination tiles x=16..31, y=20..27. The left
-- 64-pixel chunk reads objY * 0x100 + objX * 0x20 + i / 2; the right chunk
-- adds the source 0x700 term first. A zero nibble leaves the destination
-- unchanged; any other nibble writes nibble + 0x70.
---@param dest integer[] destination 8bpp bytes
---@param cells string terrain 4bpp bytes
local function bakeType1(dest, cells)
  for bgY = 20, 27 do
    for bgX = 16, 31 do
      local objX, objY = bgX - 16, bgY - 20
      local base = 0
      if objX >= 8 then
        base = 0x700
        objX = objX - 8
      end
      for i = 0, 63 do
        local byte = cellByte(cells, base + objY * 0x100 + objX * 0x20 + math.floor(i / 2))
        local nibble = byte % 16
        if i % 2 == 1 then
          nibble = math.floor(byte / 16)
        end
        if nibble ~= 0 then
          dest[bgY * 0x800 + bgX * 0x40 + i + 1] = nibble + 0x70
        end
      end
    end
  end
end

-- Bake terrain type-0: the first 0x800 unpacked pixels at byte offset
-- 0x9800, then the remainder over tiles x=0..23, y=28..31 reading
-- 0x400 + floor(objX / 8) * 0x400 + (objX % 8) * 0x20 + objY * 0x100 + i / 2.
---@param dest integer[] destination 8bpp bytes
---@param cells string terrain 4bpp bytes
local function bakeType0(dest, cells)
  for k = 0, 0x7FF do
    local byte = cellByte(cells, math.floor(k / 2))
    local nibble = byte % 16
    if k % 2 == 1 then
      nibble = math.floor(byte / 16)
    end
    if nibble ~= 0 then
      dest[0x9800 + k + 1] = nibble + 0x70
    end
  end
  for bgY = 28, 31 do
    for bgX = 0, 23 do
      local objX, objY = bgX, bgY - 28
      local base = 0x400 + math.floor(objX / 8) * 0x400
      for i = 0, 63 do
        local byte = cellByte(cells, base + (objX % 8) * 0x20 + objY * 0x100 + math.floor(i / 2))
        local nibble = byte % 16
        if i % 2 == 1 then
          nibble = math.floor(byte / 16)
        end
        if nibble ~= 0 then
          dest[bgY * 0x800 + bgX * 0x40 + i + 1] = nibble + 0x70
        end
      end
    end
  end
end

-- Compile the exact requested persistent scene: the background base with
-- its time-variant palette, the terrain bake, and the common screen
-- rasterized over the result. Returns the source-canvas record with its
-- composed RGBA image; callers stage the record with its PNG.
---@param romFs RomFs
---@param opts? { versionId?: string }
---@param sceneKey string semantic scene key
---@return BattlePresentationCompiler.SceneRecord|nil scene
---@return unknown|nil reason
function BattlePresentationCompiler.compileScene(romFs, opts, sceneKey)
  opts = opts or {}
  local versionId = opts.versionId or romFs:version()
  checkVersion(versionId)
  local parsed = Sources.parseSceneKey(sceneKey)
  if parsed == nil then
    return nil,
      Errors.new("BATTLE_SCENE_UNKNOWN", "unknown battle scene key: " .. tostring(sceneKey), {
        sceneKey = sceneKey,
      })
  end
  local ok, scene = pcall(function()
    local backgroundId = must(Sources.backgroundId(parsed.background), "scene background has no identity")
    local terrain = must(Sources.TERRAIN[parsed.terrain], "scene terrain has no recipe")
    local variant = must(Sources.paletteVariant(parsed.background, parsed.time), "scene time has no variant")
    local lower = openArchive(romFs, Sources.LOWER_NARC, "persistent backdrop")
    local sceneArchive = openArchive(romFs, Sources.SCENE_NARC, "persistent terrain")
    local baseChars =
      decodeChars(lower, Sources.baseCharMember(backgroundId), parsed.background .. " base characters", {
        label = parsed.background .. " base characters",
        allowRetailTail = true,
      })
    if baseChars.depth ~= 4 or #baseChars.tiles ~= 65536 then
      error(
        Errors.new("BATTLE_SOURCE_UNEXPECTED", parsed.background .. " base carries an unexpected tile region", {
          depth = baseChars.depth,
          bytes = #baseChars.tiles,
        }),
        0
      )
    end
    local basePalette =
      decodePalette(lower, Sources.basePaletteMember(backgroundId, variant), parsed.background .. " base palette")
    checkColorCount(basePalette, 256, parsed.background .. " base palette")
    -- Indoor and special backgrounds keep palette variant zero: the day
    -- terrain member regardless of the requested time.
    local terrainMember = must(terrain[parsed.time], "scene time has no terrain member")
    if not Sources.isOutdoor(parsed.background) then
      terrainMember = terrain.day
    end
    local terrainPalette = decodePalette(sceneArchive, terrainMember, parsed.terrain .. " terrain palette")
    checkColorCount(terrainPalette, 16, parsed.terrain .. " terrain palette")
    local type0 = decodeChars(sceneArchive, terrain.type0, parsed.terrain .. " type-0 cells")
    local type1 = decodeChars(sceneArchive, terrain.type1, parsed.terrain .. " type-1 cells")
    for _, sized in ipairs({ { type0, "type-0" }, { type1, "type-1" } }) do
      if sized[1].depth ~= 3 or #sized[1].tiles ~= 4096 then
        error(
          Errors.new(
            "BATTLE_SOURCE_UNEXPECTED",
            parsed.terrain .. " " .. sized[2] .. " cells carry an unexpected region",
            {
              depth = sized[1].depth,
              bytes = #sized[1].tiles,
            }
          ),
          0
        )
      end
    end
    local screen = decodeScreen(lower, ROLES.backdropScreen, "persistent backdrop screen")
    checkScreenSize(
      screen,
      BattlePresentationCompiler.CANVAS_WIDTH,
      BattlePresentationCompiler.CANVAS_HEIGHT,
      "persistent backdrop screen"
    )
    local dest = byteArray(baseChars.tiles)
    bakeType1(dest, type1.tiles)
    bakeType0(dest, type0.tiles)
    local combined = {}
    for _, color in ipairs(basePalette.colors) do
      combined[#combined + 1] = { r = color.r, g = color.g, b = color.b }
    end
    for index, color in ipairs(terrainPalette.colors) do
      combined[0x70 + index] = { r = color.r, g = color.g, b = color.b }
    end
    local raster = G2dRasterizer.renderScreen({ depth = 4, tiles = concatChars(dest) }, { colors = combined }, screen, {
      asset = Sources.LOWER_NARC,
      role = "persistent scene " .. sceneKey,
    }, { transparentZero = false })
    local sceneStem = sceneKey:gsub("/", "-")
    local paletteSelection = Sources.isOutdoor(parsed.background) and parsed.time or "fixed-day"
    local layer = {
      key = "background",
      backing = { width = 512, height = 256, mapWidth = 64, mapHeight = 32 },
      viewport = { x = 0, y = 0, width = 256, height = 192 },
      scroll = { x = 0, y = 0 },
      characters = {
        key = "battle-scene/" .. sceneStem .. "/background/characters",
        path = BattlePresentationCache.sceneCharactersPath(sceneKey),
        format = "indexed8",
      },
      map = {
        key = "battle-scene/" .. sceneStem .. "/background/map",
        path = BattlePresentationCache.sceneMapPath(sceneKey),
        format = "tilemap",
      },
      palette = {
        key = "battle-scene/" .. sceneStem .. "/background/palette",
        path = BattlePresentationCache.scenePalettePath(sceneKey),
        format = "rgb888",
      },
    }
    local record = {
      schema = BattlePresentationSchema.SCENE_SCHEMA,
      key = sceneKey,
      background = parsed.background,
      terrain = parsed.terrain,
      time = parsed.time,
      canvasWidth = raster.width,
      canvasHeight = raster.height,
      viewport = { x = 0, y = 0, width = 256, height = 192 },
      layers = { layer },
      layerPayloads = {
        {
          characters = concatChars(dest),
          map = { width = screen.width, height = screen.height, entries = screen.entries },
          palette = { colors = combined },
        },
      },
      buildMetadata = {
        background = {
          archiveSymbol = Sources.LOWER_NARC,
          id = backgroundId,
          charactersMember = Sources.baseCharMember(backgroundId),
        },
        terrain = {
          archiveSymbol = Sources.SCENE_NARC,
          paletteMember = terrainMember,
          type0Member = terrain.type0,
          type1Member = terrain.type1,
        },
        palette = {
          archiveSymbol = Sources.LOWER_NARC,
          member = Sources.basePaletteMember(backgroundId, variant),
          variant = variant,
          selection = paletteSelection,
        },
        screen = { archiveSymbol = Sources.LOWER_NARC, member = ROLES.backdropScreen },
      },
      image = raster.pixels,
      imagePath = BattlePresentationCache.sceneImagePath(sceneKey),
    }
    local sceneOk, sceneErr = pcall(BattlePresentationSchema.assertScene, {
      schema = record.schema,
      key = record.key,
      background = record.background,
      terrain = record.terrain,
      time = record.time,
      canvasWidth = record.canvasWidth,
      canvasHeight = record.canvasHeight,
      viewport = record.viewport,
      layers = record.layers,
      imagePath = record.imagePath,
    })
    if not sceneOk then
      error(
        Errors.new("BATTLE_SCENE_INVALID", "composed battle scene failed its own schema", {
          cause = tostring(sceneErr),
        }),
        0
      )
    end
    return record
  end)
  if not ok then
    if Errors.is(scene) then
      return nil, scene
    end
    error(scene, 0)
  end
  return scene
end

-- Stage one compiled global bundle through a worker artifact: the verified
-- manifest, the producer provenance, every staged slice PNG, and the
-- completion marker. Returns the marker.
---@param artifact PreparedArtifact
---@param bundle { manifest: table<string, unknown>, images: table<string, { width: integer, height: integer, pixels: string }>, resourcePayloads: table<string, table<string, unknown>>, provenance: table<string, unknown> } compileGlobal bundle
---@param marker string completion marker
---@return string marker
function BattlePresentationCompiler.stageGlobal(artifact, bundle, marker)
  assert(type(marker) == "string" and marker ~= "", "global staging requires its marker")
  local stage = artifact:stageFs()
  artifact:addOwnedRoot(BattlePresentationCache.manifestPath())
  artifact:addOwnedRoot(BattlePresentationCache.provenancePath())
  artifact:addOwnedRoot(BattlePresentationCache.markerPath())
  stage:writeLua(BattlePresentationCache.manifestPath(), bundle.manifest)
  stage:writeLua(BattlePresentationCache.provenancePath(), bundle.provenance)
  local names = {}
  for name in pairs(bundle.images) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local image = bundle.images[name]
    local path = BattlePresentationCache.globalImagePath(name)
    artifact:addOwnedRoot(path)
    stage:write(path, encodeImage(image.pixels, image.width, image.height, name))
  end
  local resourcePaths = {}
  for path in pairs(bundle.resourcePayloads) do
    resourcePaths[#resourcePaths + 1] = path
  end
  table.sort(resourcePaths)
  for _, path in ipairs(resourcePaths) do
    artifact:addOwnedRoot(path)
    stage:writeLua(path, bundle.resourcePayloads[path])
  end
  stage:write(BattlePresentationCache.markerPath(), marker)
  return marker
end

-- The content identity behind the global completion marker: the verified
-- manifest plus every staged image and decoded resource payload.
---@param romSha1 string
---@param bundle { manifest: table<string, unknown>, images: table<string, { width: integer, height: integer, pixels: string }>, resourcePayloads: table<string, table<string, unknown>>, provenance: table<string, unknown> } compileGlobal bundle
---@return string marker
function BattlePresentationCompiler.globalMarker(romSha1, bundle)
  local imageHashes = {}
  for name, image in pairs(bundle.images) do
    imageHashes[name] = Hashing.sha1hex(image.pixels)
  end
  local resourceHashes = {}
  for path, payload in pairs(bundle.resourcePayloads) do
    resourceHashes[path] = Hashing.hashLua(payload)
  end
  return BattlePresentationCache.marker(
    romSha1,
    Hashing.hashLua({ manifest = bundle.manifest, images = imageHashes, resources = resourceHashes })
  )
end

-- Stage one composed scene through a worker artifact: the schema-valid
-- record without its pixels, the staged scene PNG, and the completion
-- marker. Returns the marker.
---@param artifact PreparedArtifact
---@param scene BattlePresentationCompiler.SceneRecord compileScene record
---@param marker string completion marker
---@return string marker
function BattlePresentationCompiler.stageScene(artifact, scene, marker)
  assert(type(marker) == "string" and marker ~= "", "scene staging requires its marker")
  local stage = artifact:stageFs()
  artifact:addOwnedRoot(BattlePresentationCache.scenePath(scene.key))
  artifact:addOwnedRoot(BattlePresentationCache.sceneImagePath(scene.key))
  artifact:addOwnedRoot(scene.layers[1].characters.path)
  artifact:addOwnedRoot(scene.layers[1].map.path)
  artifact:addOwnedRoot(scene.layers[1].palette.path)
  artifact:addOwnedRoot(BattlePresentationCache.sceneProvenancePath(scene.key))
  artifact:addOwnedRoot(BattlePresentationCache.sceneMarkerPath(scene.key))
  stage:writeLua(BattlePresentationCache.scenePath(scene.key), {
    schema = scene.schema,
    key = scene.key,
    background = scene.background,
    terrain = scene.terrain,
    time = scene.time,
    canvasWidth = scene.canvasWidth,
    canvasHeight = scene.canvasHeight,
    viewport = scene.viewport,
    layers = scene.layers,
    imagePath = scene.imagePath,
  })
  local payload = assert(scene.layerPayloads[1], "the scene carries its BG3 payload")
  stage:write(scene.layers[1].characters.path, payload.characters)
  stage:writeLua(scene.layers[1].map.path, payload.map)
  stage:writeLua(scene.layers[1].palette.path, payload.palette)
  stage:writeLua(BattlePresentationCache.sceneProvenancePath(scene.key), scene.buildMetadata)
  stage:write(
    BattlePresentationCache.sceneImagePath(scene.key),
    encodeImage(scene.image, scene.canvasWidth, scene.canvasHeight, scene.key)
  )
  stage:write(BattlePresentationCache.sceneMarkerPath(scene.key), marker)
  return marker
end

-- The content identity behind one scene completion marker.
---@param romSha1 string
---@param scene BattlePresentationCompiler.SceneRecord compileScene record
---@return string marker
function BattlePresentationCompiler.sceneMarker(romSha1, scene)
  return BattlePresentationCache.marker(
    romSha1,
    Hashing.hashLua({
      key = scene.key,
      canvasWidth = scene.canvasWidth,
      canvasHeight = scene.canvasHeight,
      viewport = scene.viewport,
      layers = scene.layers,
      image = Hashing.sha1hex(scene.image),
      layerPayloads = {
        {
          characters = Hashing.sha1hex(scene.layerPayloads[1].characters),
          map = scene.layerPayloads[1].map,
          palette = scene.layerPayloads[1].palette,
        },
      },
      buildMetadata = scene.buildMetadata,
    })
  )
end

-- Compile one independently requested effect: a closed normalized program
-- lowered through the animation compiler with its transitive resources and
-- typed context. Source selection follows asm/overlay_07.s ov07_0221C01C
-- (pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36).
---@param romFs RomFs
---@param opts? { versionId?: string }
---@param effectKey string flat semantic effect key
---@return BattlePresentationEffect|nil effect artifact
---@return unknown|nil reason
function BattlePresentationCompiler.compileEffect(romFs, opts, effectKey)
  opts = opts or {}
  local versionId = opts.versionId or romFs:version()
  checkVersion(versionId)
  if type(effectKey) ~= "string" or effectKey == "" or effectKey:find("/", 1, true) ~= nil then
    return nil,
      Errors.new("BATTLE_EFFECT_UNKNOWN", "unknown battle effect key: " .. tostring(effectKey), {
        effectKey = tostring(effectKey),
      })
  end
  local animationSources = require("romdump.src.config.BattleAnimationSources")
  local route = animationSources.resolveSemanticRoute(effectKey)
  if route == nil then
    return nil,
      Errors.new("BATTLE_EFFECT_UNKNOWN", "unknown battle effect key: " .. effectKey, {
        effectKey = effectKey,
      })
  end
  assert(
    route.kind == "move" or route.kind == "battle-animation",
    "source route resolver returns a supported semantic root kind"
  )
  local archive, archiveErr = romFs:openNarc(route.archiveSymbol)
  if archive == nil then
    return nil,
      Errors.new("BATTLE_EFFECT_SOURCE_UNAVAILABLE", "could not open selected effect archive", {
        effectKey = effectKey,
        archiveSymbol = route.archiveSymbol,
        memberId = route.memberId,
        cause = tostring(archiveErr),
      })
  end
  local stream, memberErr = archive:readMember(route.memberId)
  if stream == nil then
    return nil,
      Errors.new("BATTLE_EFFECT_SOURCE_UNAVAILABLE", "could not read selected effect member", {
        effectKey = effectKey,
        archiveSymbol = route.archiveSymbol,
        memberId = route.memberId,
        cause = tostring(memberErr),
      })
  end
  local AnimationCompiler = require("romdump.src.digest.battle.BattleAnimationCompiler")
  local resolvedResources = {}
  local resourcePayloads = {}
  local sourceInputs = {}
  local resolvedSourceInputs = {}
  local archives = {}
  local managedSpriteResources = {}
  local managedSpriteCapacities = {}
  -- Managed-sprite and background character tile sets staged as raw tile
  -- data, keyed by semantic resource key. Each entry keeps its decoded
  -- tiles plus the same-call paired palette key when the selecting
  -- instruction co-selected one; lone characters resolve their palette
  -- through the creating instruction at the end of compilation. The
  -- rasterization pass below replaces every entry with the exact RGBA
  -- drawable the live image upload path requires, so no staged texture
  -- keeps raw Nitro bitfields.
  local pendingCharacterRasters = {}
  local particleByBattler = {}
  local decodedParticleResources = {}
  local function addEffectResource(resourceKey, kind, contentIdentity, payload)
    assert(type(resourceKey) == "string" and resourceKey ~= "", "effect resources use semantic keys")
    assert(type(contentIdentity) == "string" and #contentIdentity == 40, "effect resources use SHA-1 identities")
    local payloadPath = BattlePresentationCache.globalResourcePath("effect/content/" .. contentIdentity)
    local previous = resolvedResources[resourceKey]
    if previous ~= nil then
      assert(
        previous.kind == kind and previous.contentIdentity == contentIdentity,
        "semantic resource identity is stable"
      )
      assert(
        Hashing.hashLua(resourcePayloads[previous.payload]) == Hashing.hashLua(payload),
        "equal resources share payloads"
      )
      return
    end
    resolvedResources[resourceKey] = { kind = kind, contentIdentity = contentIdentity, payload = payloadPath }
    resourcePayloads[payloadPath] = payload
  end
  -- Stages one particle texture/palette pair as an exact drawable plus
  -- decoded colors, returning their semantic resource keys. Shared
  -- sources collapse onto one staged drawable through content identity.
  ---@param textureBytes string|nil raw 8-bit indexed texels when embedded
  ---@param paletteBytes string|nil raw RGB555 pairs when embedded
  ---@param textureFlags integer source resource flags word
  ---@param provenance table<string, unknown> source coordinates for failures
  ---@return { textureKey: string|nil, paletteKey: string|nil } staged semantic resource keys
  local function stageParticleTexture(textureBytes, paletteBytes, textureFlags, provenance)
    local textureKey, paletteKey = nil, nil
    local colors = nil
    if paletteBytes ~= nil then
      colors = decodeParticlePalette(paletteBytes, provenance)
      local paletteIdentity = Hashing.sha1hex(paletteBytes)
      paletteKey = "battle/particle/palette/" .. paletteIdentity
      addEffectResource(paletteKey, "palette", paletteIdentity, { colors = colors })
    end
    if textureBytes ~= nil then
      local paletteColors = colors ~= nil and #colors or 0
      local width, height, bits = particleTextureDimensions(textureBytes, textureFlags, paletteColors, provenance)
      local rgba = decodeParticleRgba(textureBytes, width, height, bits, colors or {})
      local textureIdentity = Hashing.sha1hex(textureBytes)
      textureKey = "battle/particle/texture/" .. textureIdentity
      addEffectResource(textureKey, "texture", textureIdentity, {
        width = width,
        height = height,
        rgba8888 = rgba,
      })
    end
    return { textureKey = textureKey, paletteKey = paletteKey }
  end
  -- Stages every resource of one decoded particle archive exactly once,
  -- resolving shared texture references onto their staged drawable.
  ---@param decoded NitroSplData decoded particle archive under staging
  ---@param provenance table<string, unknown> source coordinates for failures
  ---@return { textureKey: string|nil, paletteKey: string|nil }[] staged entries in source order
  local function stageParticleArchiveResources(decoded, provenance)
    local entries = {}
    for resourceIndex, resource in ipairs(decoded.resources) do
      local textureKey, paletteKey = nil, nil
      if resource.textureReference ~= nil then
        local referenced = entries[resource.textureReference + 1]
        if referenced == nil or referenced.textureKey == nil then
          error(
            Errors.new("BATTLE_EFFECT_CLOSURE_UNRESOLVED", "particle texture reference has no staged payload", {
              effectKey = effectKey,
              resourceIndex = resourceIndex - 1,
              textureReference = resource.textureReference,
            }),
            0
          )
        end
        textureKey = referenced.textureKey
        paletteKey = stageParticleTexture(nil, resource.palette, resource.flags, provenance).paletteKey
      else
        local staged = stageParticleTexture(resource.texture, resource.palette, resource.flags, provenance)
        textureKey, paletteKey = staged.textureKey, staged.paletteKey
      end
      entries[resourceIndex] = { textureKey = textureKey, paletteKey = paletteKey }
    end
    return entries
  end
  -- Normalizes one raw emitter into source-independent typed state: the
  -- active source behaviors, the inline parameter bits, the base control
  -- values, one word vector per present section/calculation, and the
  -- resolved drawable its sprites draw. Unknown flags words fail.
  ---@param emitter NitroSplEmitter raw emitter under normalizing
  ---@param entries { textureKey: string|nil, paletteKey: string|nil }[] staged archive resources
  ---@param emitterIndex integer zero-based emitter ordinal behind texture selection
  ---@param provenance table<string, unknown> source coordinates for failures
  ---@return table<string, unknown> normalized emitter record
  local function normalizeParticleEmitter(emitter, entries, emitterIndex, provenance)
    assert(#emitter.baseRecord == 0x58, "emitter base records keep their source size")
    if KNOWN_PARTICLE_EMITTER_FLAGS[emitter.flags] ~= true then
      error(
        Errors.new("BATTLE_PARTICLE_RESOURCE_INVALID", "particle emitter flags are outside the source inventory", {
          effectKey = effectKey,
          flags = string.format("0x%08x", emitter.flags),
          archiveSymbol = provenance.archiveSymbol,
          memberId = provenance.memberId,
        }),
        0
      )
    end
    local seen = {}
    local features = {}
    for _, section in ipairs(emitter.sections) do
      if seen[section.role] == nil then
        seen[section.role] = true
        features[#features + 1] = section.role
      end
    end
    for _, calculation in ipairs(emitter.calculations) do
      if seen[calculation.role] == nil then
        seen[calculation.role] = true
        features[#features + 1] = calculation.role
      end
    end
    table.sort(features)
    local params = {}
    for offset = 5, #emitter.baseRecord, 2 do
      params[#params + 1] = string.byte(emitter.baseRecord, offset) + string.byte(emitter.baseRecord, offset + 1) * 256
    end
    local record = {
      features = features,
      variant = clearParticleSelectorBits(emitter.flags),
      params = params,
    }
    local function stageWords(role, data)
      if record[role] ~= nil then
        return
      end
      local words = {}
      for offset = 1, #data, 4 do
        words[#words + 1] = string.byte(data, offset)
          + string.byte(data, offset + 1) * 256
          + string.byte(data, offset + 2) * 65536
          + string.byte(data, offset + 3) * 16777216
      end
      record[role] = words
    end
    for _, section in ipairs(emitter.sections) do
      stageWords(section.role, section.data)
    end
    for _, calculation in ipairs(emitter.calculations) do
      stageWords(calculation.role, calculation.data)
    end
    local slot = nil
    if #entries > 0 then
      slot = math.min(emitterIndex, #entries - 1)
      for _, section in ipairs(emitter.sections) do
        if section.role == "texture" then
          local selected = string.byte(section.data, 1)
          if selected < #entries then
            slot = selected
          end
          break
        end
      end
    end
    local textureKey = nil
    if slot ~= nil then
      local selected = entries[slot + 1]
      textureKey = selected ~= nil and selected.textureKey or nil
      if textureKey == nil then
        error(
          Errors.new("BATTLE_EFFECT_CLOSURE_UNRESOLVED", "particle emitter texture has no staged drawable", {
            effectKey = effectKey,
            emitterIndex = emitterIndex,
            textureSlot = slot,
            archiveSymbol = provenance.archiveSymbol,
            memberId = provenance.memberId,
          }),
          0
        )
      end
    end
    record.textureSlot = slot
    record.textureKey = textureKey
    return record
  end
  local function stageParticleEmitter(emitter)
    local contentIdentity = Hashing.hashLua(emitter)
    local resourceKey = "battle/particle-emitter/" .. contentIdentity
    local payloadPath = BattlePresentationCache.globalResourcePath("effect/content/" .. contentIdentity)
    local previous = resolvedResources[resourceKey]
    if previous == nil then
      resolvedResources[resourceKey] = {
        kind = "particle-emitter",
        contentIdentity = contentIdentity,
        payload = payloadPath,
      }
      resourcePayloads[payloadPath] = emitter
    else
      assert(previous.kind == "particle-emitter" and previous.contentIdentity == contentIdentity)
      assert(Hashing.hashLua(resourcePayloads[previous.payload]) == contentIdentity)
    end
    return resourceKey
  end
  local function resolveSourceInput(role, operands)
    if role == "managed-sprite-manager-capacities" then
      if #operands ~= 8 then
        error(
          Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "sprite manager capacity frame is invalid", {
            effectKey = effectKey,
            provenance = { role = role, operands = operands },
          }),
          0
        )
      end
      local managerIndex = operands[1]
      local capacities = {}
      for index = 3, 8 do
        local capacity = operands[index]
        if type(capacity) ~= "number" or capacity < 0 or capacity > 0x7fffffff or capacity % 1 ~= 0 then
          error(
            Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "sprite manager capacity is invalid", {
              effectKey = effectKey,
              provenance = { role = role, operands = operands, capacityIndex = index },
            }),
            0
          )
        end
        capacities[index - 2] = capacity
      end
      if managedSpriteCapacities[managerIndex] ~= nil then
        error(
          Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "sprite manager slot is initialized more than once", {
            effectKey = effectKey,
            provenance = { role = role, operands = operands },
          }),
          0
        )
      end
      local hasMultiResourceManagers = capacities[5] > 0 and capacities[6] > 0
      managedSpriteCapacities[managerIndex] = {
        multiCell = hasMultiResourceManagers,
        multiAnimation = hasMultiResourceManagers,
      }
      sourceInputs[#sourceInputs + 1] = { role = role, operands = operands, selections = {} }
      resolvedSourceInputs[#resolvedSourceInputs + 1] = {
        role = role,
        managerIndex = managerIndex,
        multiCellEnabled = hasMultiResourceManagers,
        multiAnimationEnabled = hasMultiResourceManagers,
      }
      return {}
    end
    if role == "managed-sprite-manager-disposal" then
      if #operands ~= 1 then
        error(
          Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "sprite manager disposal frame is invalid", {
            effectKey = effectKey,
            provenance = { role = role, operands = operands },
          }),
          0
        )
      end
      managedSpriteCapacities[operands[1]] = nil
      managedSpriteResources[operands[1]] = nil
      sourceInputs[#sourceInputs + 1] = { role = role, operands = operands, selections = {} }
      resolvedSourceInputs[#resolvedSourceInputs + 1] = { role = role, managerIndex = operands[1], disposed = true }
      return {}
    end
    if role == "battler-particle-resource" then
      local selection, _ = animationSources.resolveSourceSelection(role, operands)
      local definition = assert(animationSources.sourceInput(51), "opcode 51 has producer source metadata")
      if #operands ~= definition.operandCount then
        error(
          Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "battler particle resource has no typed source", {
            effectKey = effectKey,
            reason = "particle resource operand shape is invalid",
            provenance = { role = role, operands = operands },
          }),
          0
        )
      end
      local memberId = operands[definition.memberOperand]
      local source = selection and selection.sourceSelections and selection.sourceSelections.particle
        or {
          archiveSymbol = definition.archiveSymbol,
          memberId = memberId,
          decoder = definition.decoder,
          kind = definition.kind,
        }
      if source == nil or source.decoder ~= "spl" or source.kind ~= "particle" then
        error(
          Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "battler particle source has no APS decoder", {
            effectKey = effectKey,
            provenance = { role = role, operands = operands },
          }),
          0
        )
      end
      local particleKey = selection and selection.resourceKeys and selection.resourceKeys.particle
        or animationSources.resolveParticleResource(memberId)
      local particle = particleKey ~= nil and decodedParticleResources[particleKey] or nil
      if particle == nil then
        local particleArchive = archives[source.archiveSymbol]
        if particleArchive == nil then
          particleArchive = openArchive(romFs, source.archiveSymbol, "animation battler particle")
          archives[source.archiveSymbol] = particleArchive
        end
        local bytes, readErr = particleArchive:readMember(memberId)
        if bytes == nil then
          error(
            Errors.new("BATTLE_EFFECT_SOURCE_UNAVAILABLE", "selected battler particle member is absent", {
              effectKey = effectKey,
              provenance = {
                archiveSymbol = source.archiveSymbol,
                memberId = memberId,
                role = role,
                operands = operands,
              },
              cause = tostring(readErr),
            }),
            0
          )
        end
        local decoded, decodeErr = Spl.decode(bytes, { effectKey = effectKey, role = role })
        if decoded == nil then
          error(decodeErr, 0)
        end
        particleKey = particleKey or ("battle/particle/content/" .. Hashing.sha1hex(bytes))
        selection = {
          resourceKeys = { particle = particleKey },
          sourceSelections = { particle = source },
        }
        particle = { bytes = bytes, decoded = decoded, source = source }
        decodedParticleResources[particleKey] = particle
      end
      local selectedParticleKey = selection.resourceKeys.particle
      particleByBattler[operands[1]] = selectedParticleKey
      local selections = {
        particle = { archiveSymbol = source.archiveSymbol, memberId = source.memberId, decoder = source.decoder },
      }
      sourceInputs[#sourceInputs + 1] = { role = role, operands = operands, selections = selections }
      resolvedSourceInputs[#resolvedSourceInputs + 1] = { role = role, resourceKeys = selection.resourceKeys }
      return { resourceKeys = selection.resourceKeys }
    end
    if role == "configured-sprite-action" then
      local selection, selectionErr = animationSources.resolveSourceSelection(role, operands)
      if selection == nil then
        error(
          Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "configured sprite action is not source-resolved", {
            effectKey = effectKey,
            reason = selectionErr,
            provenance = { role = role, operands = operands },
          }),
          0
        )
      end
      local definition = assert(animationSources.sourceInput(78), "opcode 78 has source operand metadata")
      local resourceKeys = {}
      local manager = managedSpriteResources[operands[1]]
      local capacities = managedSpriteCapacities[operands[1]]
      if capacities == nil then
        error(
          Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "configured sprite manager has no active capacity record", {
            effectKey = effectKey,
            provenance = { role = role, operands = operands },
          }),
          0
        )
      end
      for _, slot in ipairs(definition.resourceSlots) do
        if capacities[slot] ~= false then
          local operandIndex = assert(definition.resourceOperands[slot], "configured sprite slot has an operand")
          local identity = operands[operandIndex]
          local resources = manager and manager[slot]
          local resourceKey = resources and resources[identity]
          local optional = slot == "multiCell" or slot == "multiAnimation"
          if optional and resources == nil then
            -- No bytecode handler loads MCEL/MANM resources; nil selects ordinary cells.
          elseif resourceKey == nil then
            error(
              Errors.new(
                "BATTLE_EFFECT_SOURCE_UNRESOLVED",
                "configured sprite resource identity has no prior source-selected payload",
                {
                  effectKey = effectKey,
                  reason = "the selected manager has no decoded resource with this typed identity",
                  provenance = { role = role, operands = operands, slot = slot },
                }
              ),
              0
            )
          end
          resourceKeys[slot] = resourceKey
        end
      end
      sourceInputs[#sourceInputs + 1] = { role = role, operands = operands, selections = {} }
      local normalized = {
        role = role,
        resourceKeys = resourceKeys,
        taskKind = selection.taskKind,
        context = selection.context,
        parameters = selection.parameters,
      }
      resolvedSourceInputs[#resolvedSourceInputs + 1] = normalized
      return {
        resourceKeys = resourceKeys,
        taskKind = selection.taskKind,
        context = selection.context,
        parameters = selection.parameters,
      }
    end
    if role == "managed-sprite-template" then
      if #operands ~= 8 then
        error(
          Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "managed sprite resource reference shape is invalid", {
            effectKey = effectKey,
            provenance = { role = role, operands = operands },
          }),
          0
        )
      end
      local resourceKeys = {}
      local resourceSlots = { "character", "palette", "cell", "animation", "multiCell", "multiAnimation" }
      for index, slot in ipairs(resourceSlots) do
        local reference = operands[index + 2]
        local optional = index > 4
        if optional and reference == 0xffffffff then
          -- Nitro's signed -1 resource ID means this sprite has no MCEL/MANM.
        else
          local manager = managedSpriteResources[operands[1]]
          local resources = manager and manager[slot]
          local resourceKey = resources and resources[reference]
          if optional and resources == nil then
            -- No bytecode handler loads MCEL/MANM resources; nil selects ordinary cells.
          elseif resourceKey == nil then
            error(
              Errors.new(
                "BATTLE_EFFECT_SOURCE_UNRESOLVED",
                "managed sprite resource identity has no prior source-selected payload",
                {
                  effectKey = effectKey,
                  reason = "the selected manager has no decoded resource with this typed identity",
                  provenance = { role = role, operands = operands, slot = slot },
                }
              ),
              0
            )
          end
          resourceKeys[slot] = resourceKey
        end
      end
      sourceInputs[#sourceInputs + 1] = { role = role, operands = operands, selections = {} }
      resolvedSourceInputs[#resolvedSourceInputs + 1] = { role = role, resourceKeys = resourceKeys }
      return { resourceKeys = resourceKeys }
    end
    local selection, selectionErr = animationSources.resolveSourceSelection(role, operands)
    if selection == nil then
      error(
        Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "animation source selection is not established", {
          effectKey = effectKey,
          reason = selectionErr,
          provenance = { role = role, operands = operands },
        }),
        0
      )
    end
    if role == "battler-particle-action" then
      local normalized = {
        role = role,
        actionProfile = selection.actionProfile,
        callbackCases = selection.callbackCases,
        resourceCases = selection.resourceCases,
        runtimeSelection = selection.runtimeSelection,
        taskKind = selection.taskKind,
      }
      if type(selection.actionProfile) ~= "string" then
        error(
          Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "battler particle action has no semantic profile", {
            effectKey = effectKey,
            provenance = { role = role, operands = operands },
          }),
          0
        )
      end
      if selection.sourceEmitterSelections ~= nil then
        local particleKey = particleByBattler[operands[1]]
        local particle = particleKey ~= nil and decodedParticleResources[particleKey] or nil
        if particle == nil then
          error(
            Errors.new(
              "BATTLE_EFFECT_SOURCE_UNRESOLVED",
              "particle action has no earlier APS selection for its battler",
              {
                effectKey = effectKey,
                provenance = { role = role, operands = operands },
              }
            ),
            0
          )
        end
        local function emitterKey(emitterOrdinal, caseKey)
          if type(emitterOrdinal) ~= "number" or emitterOrdinal < 0 or emitterOrdinal % 1 ~= 0 then
            error(
              Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "particle emitter ordinal is invalid", {
                effectKey = effectKey,
                provenance = { role = role, operands = operands, case = caseKey },
                resourceKey = particleKey,
              }),
              0
            )
          end
          local emitter = particle.decoded.emitters[emitterOrdinal + 1]
          if emitter == nil then
            error(
              Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "particle emitter ordinal has no decoded APS record", {
                effectKey = effectKey,
                provenance = { role = role, operands = operands, case = caseKey },
                resourceKey = particleKey,
              }),
              0
            )
          end
          local entries = stageParticleArchiveResources(particle.decoded, {
            archiveSymbol = particle.source.archiveSymbol,
            memberId = particle.source.memberId,
          })
          local stagedEmitter = normalizeParticleEmitter(emitter, entries, emitterOrdinal, {
            archiveSymbol = particle.source.archiveSymbol,
            memberId = particle.source.memberId,
          })
          return stageParticleEmitter(stagedEmitter)
        end
        if selection.sourceEmitterSelections.resource ~= nil then
          normalized.resource = emitterKey(selection.sourceEmitterSelections.resource, "fixed")
        else
          normalized.resourceCases = {}
          for pairKey, emitterOrdinal in pairs(selection.sourceEmitterSelections) do
            if emitterOrdinal == "source-assert" then
              normalized.resourceCases[pairKey] = "source-assert"
            else
              normalized.resourceCases[pairKey] = emitterKey(emitterOrdinal, pairKey)
            end
          end
        end
      end
      if selection.sourceEmitterSelections == nil and type(selection.callbackCases) ~= "table" then
        normalized.actionProfile = selection.actionProfile
      elseif type(normalized.resourceCases) ~= "table" then
        if normalized.resource == nil then
          error(
            Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "battler particle choice has no emitter resource cases", {
              effectKey = effectKey,
              provenance = { role = role, operands = operands },
            }),
            0
          )
        end
      end
      sourceInputs[#sourceInputs + 1] = { role = role, operands = operands, selections = {} }
      resolvedSourceInputs[#resolvedSourceInputs + 1] = normalized
      return {
        actionProfile = selection.actionProfile,
        callbackCases = selection.callbackCases,
        resource = normalized.resource,
        resourceCases = normalized.resourceCases,
        runtimeSelection = selection.runtimeSelection,
        taskKind = selection.taskKind,
      }
    end
    local callbackResult
    if role == "battle-animation-callback" then
      if selection.op == "noop" then
        local normalized = { role = role, op = "noop" }
        sourceInputs[#sourceInputs + 1] = { role = role, operands = operands, selections = {} }
        resolvedSourceInputs[#resolvedSourceInputs + 1] = normalized
        return { op = "noop" }
      end
      if selection.op ~= nil then
        local isPictureOperation = selection.op == "set-pokemon-picture-vanished"
        local isPaletteOperation = selection.op == "copy-main-background-palette-to-fade-buffer"
          or selection.op == "grayscale-main-background-fade-buffer"
        if not isPictureOperation and not isPaletteOperation then
          error(
            Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "animation callback direct operation is invalid", {
              effectKey = effectKey,
              provenance = { role = role, operands = operands },
            }),
            0
          )
        end
        if isPictureOperation then
          if type(selection.pictureSets) ~= "table" or type(selection.vanished) ~= "boolean" then
            error(
              Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "animation callback direct operation is invalid", {
                effectKey = effectKey,
                provenance = { role = role, operands = operands },
              }),
              0
            )
          end
        elseif selection.pictureSets ~= nil or selection.vanished ~= nil then
          error(
            Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "palette callback operation carries unexpected fields", {
              effectKey = effectKey,
              provenance = { role = role, operands = operands },
            }),
            0
          )
        end
        local normalized = {
          role = role,
          op = selection.op,
          pictureSets = selection.pictureSets,
          vanished = selection.vanished,
        }
        sourceInputs[#sourceInputs + 1] = { role = role, operands = operands, selections = {} }
        resolvedSourceInputs[#resolvedSourceInputs + 1] = normalized
        return {
          op = selection.op,
          pictureSets = selection.pictureSets,
          vanished = selection.vanished,
        }
      end
      if
        type(selection.callback) ~= "string"
        or type(selection.taskKind) ~= "string"
        or type(selection.context) ~= "string"
        or type(selection.parameters) ~= "table"
      then
        error(
          Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "animation callback plan has no semantic task", {
            effectKey = effectKey,
            provenance = { role = role, operands = operands },
          }),
          0
        )
      end
      callbackResult = {
        callback = selection.callback,
        taskKind = selection.taskKind,
        context = selection.context,
        battlerTarget = selection.battlerTarget,
        parameters = selection.parameters,
      }
    end
    local resourceKeys = {}
    local selections = {}
    local slots = {}
    local sourceSelections = selection.sourceSelections or {}
    if next(sourceSelections) == nil and selection.battlerTarget == nil and callbackResult == nil then
      error(
        Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "animation source plan carries no semantic output", {
          effectKey = effectKey,
          role = role,
          provenance = { operands = operands },
        }),
        0
      )
    end
    for slot in pairs(sourceSelections) do
      slots[#slots + 1] = slot
    end
    table.sort(slots)
    for _, slot in ipairs(slots) do
      local source = sourceSelections[slot]
      local sourceArchive = archives[source.archiveSymbol]
      if sourceArchive == nil then
        sourceArchive = openArchive(romFs, source.archiveSymbol, "animation " .. role)
        archives[source.archiveSymbol] = sourceArchive
      end
      local sourceBytes, sourceErr = sourceArchive:readMember(source.memberId)
      if sourceBytes == nil then
        error(
          Errors.new("BATTLE_EFFECT_SOURCE_UNAVAILABLE", "selected animation resource member is absent", {
            effectKey = effectKey,
            role = role,
            provenance = {
              archiveSymbol = source.archiveSymbol,
              memberId = source.memberId,
              operands = operands,
              slot = slot,
            },
            cause = tostring(sourceErr),
          }),
          0
        )
      end
      local decoded
      if source.decoder == "char" then
        decoded = decodeChars(sourceArchive, source.memberId, "animation " .. role .. " characters")
      elseif source.decoder == "palette" then
        decoded = paletteRecords(decodePalette(sourceArchive, source.memberId, "animation " .. role .. " palette"))
      elseif source.decoder == "screen" then
        decoded = decodeScreen(sourceArchive, source.memberId, "animation " .. role .. " screen")
      elseif source.decoder == "cell" then
        decoded = decodeCells(sourceArchive, source.memberId, "animation " .. role .. " cells")
      elseif source.decoder == "animation" then
        decoded = decodeAnimation(sourceArchive, source.memberId, "animation " .. role .. " animation")
      elseif source.decoder == "multiCell" then
        local MultiCell = require("libs.nds.src.nitro.g2d.MultiCell")
        local decodeErr
        decoded, decodeErr = MultiCell.decode(sourceBytes, { effectKey = effectKey, role = role, slot = slot })
        if decoded == nil then
          error(decodeErr, 0)
        end
      elseif source.decoder == "multiCellAnimation" then
        local MultiCellAnimation = require("libs.nds.src.nitro.g2d.MultiCellAnimation")
        local decodeErr
        decoded, decodeErr = MultiCellAnimation.decode(sourceBytes, { effectKey = effectKey, role = role, slot = slot })
        if decoded == nil then
          error(decodeErr, 0)
        end
      else
        error(
          Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "animation source selection has no decoder", {
            effectKey = effectKey,
            role = role,
            provenance = { decoder = source.decoder, operands = operands, slot = slot },
          }),
          0
        )
      end
      local contentIdentity = Hashing.sha1hex(sourceBytes)
      local resourceSlot = slot:gsub("(%u)", "-%1"):lower()
      local resourceKey = table.concat({ "battle/animation", role, resourceSlot, contentIdentity }, "/")
      local payloadPath = BattlePresentationCache.globalResourcePath(resourceKey)
      local descriptor = {
        kind = source.kind,
        contentIdentity = contentIdentity,
        payload = payloadPath,
      }
      local previous = resolvedResources[resourceKey]
      if previous ~= nil then
        assert(
          previous.contentIdentity == descriptor.contentIdentity
            and previous.kind == descriptor.kind
            and Hashing.hashLua(resourcePayloads[previous.payload]) == Hashing.hashLua(decoded),
          "content-addressed battle resource keys identify one decoded format"
        )
      else
        resolvedResources[resourceKey] = descriptor
        resourcePayloads[payloadPath] = decoded
      end
      resourceKeys[slot] = resourceKey
      selections[slot] = { archiveSymbol = source.archiveSymbol, memberId = source.memberId, decoder = source.decoder }
    end
    local managedSlot = ({
      ["sprite-character"] = "character",
      ["sprite-palette"] = "palette",
      ["sprite-cell"] = "cell",
      ["sprite-animation"] = "animation",
    })[role]
    if managedSlot ~= nil then
      local managerSlot = operands[1]
      managedSpriteResources[managerSlot] = managedSpriteResources[managerSlot] or {}
      managedSpriteResources[managerSlot][managedSlot] = managedSpriteResources[managerSlot][managedSlot] or {}
      local byIdentity = managedSpriteResources[managerSlot][managedSlot]
      local previous = byIdentity[operands[2]]
      if previous ~= nil and previous ~= resourceKeys[managedSlot] then
        error(
          Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "managed sprite resource identity is ambiguous", {
            effectKey = effectKey,
            provenance = { role = role, operands = operands, slot = managedSlot },
          }),
          0
        )
      end
      byIdentity[operands[2]] = resourceKeys[managedSlot]
    end
    -- A staged character tile set must become an exact RGBA drawable
    -- before publication: the live image upload path admits no other
    -- texture shape. Same-call co-selected palettes pair immediately;
    -- lone characters keep their decoded tiles until the creating
    -- instruction pairs them below.
    if resourceKeys.character ~= nil and selections.character ~= nil and selections.character.decoder == "char" then
      local characterKey = resourceKeys.character
      local characterDescriptor = resolvedResources[characterKey]
      local stagedCharacters = characterDescriptor ~= nil and resourcePayloads[characterDescriptor.payload] or nil
      if
        characterDescriptor ~= nil
        and characterDescriptor.kind == "texture"
        and type(stagedCharacters) == "table"
        and type(stagedCharacters.tiles) == "string"
        and pendingCharacterRasters[characterKey] == nil
      then
        pendingCharacterRasters[characterKey] = {
          resourceKey = characterKey,
          payloadPath = characterDescriptor.payload,
          chars = stagedCharacters,
          paletteKey = resourceKeys.palette,
          role = role,
        }
      end
    end
    sourceInputs[#sourceInputs + 1] = {
      role = role,
      operands = operands,
      selections = selections,
    }
    local normalized = {
      role = role,
      resourceKeys = resourceKeys,
      runtimeSelection = selection.runtimeSelection,
      battlerTarget = selection.battlerTarget,
      taskKind = selection.taskKind,
      callback = selection.callback,
      actionProfile = selection.actionProfile,
      callbackCases = selection.callbackCases,
    }
    if callbackResult ~= nil then
      normalized.callback = callbackResult.callback
      normalized.taskKind = callbackResult.taskKind
      normalized.context = callbackResult.context
      normalized.battlerTarget = callbackResult.battlerTarget
      normalized.parameters = callbackResult.parameters
    end
    resolvedSourceInputs[#resolvedSourceInputs + 1] = normalized
    local result = {
      resourceKeys = resourceKeys,
      runtimeSelection = selection.runtimeSelection,
      battlerTarget = selection.battlerTarget,
      taskKind = selection.taskKind,
      callback = selection.callback,
      actionProfile = selection.actionProfile,
      callbackCases = selection.callbackCases,
    }
    if callbackResult ~= nil then
      result.callback = callbackResult.callback
      result.taskKind = callbackResult.taskKind
      result.context = callbackResult.context
      result.battlerTarget = callbackResult.battlerTarget
      result.parameters = callbackResult.parameters
    end
    return result
  end
  local ok, program = pcall(AnimationCompiler.compile, {
    key = effectKey,
    stream = stream,
    resolveSourceInput = resolveSourceInput,
  })
  if not ok then
    if Errors.is(program) then
      return nil, program
    end
    error(program, 0)
  end
  assert(type(program) == "table", "animation compiler returns a program")
  local sourceOffsets = program.sourceOffsets
  local effectProgram = {
    entry = program.entry,
    instructions = program.instructions,
    subprograms = program.subprograms,
    taskKinds = program.taskKinds,
  }
  local requiredContext = {
    actors = { type = "battle-actors" },
    targets = { type = "target-actors" },
    attackerPosition = { type = "battler-position" },
    targetPosition = { type = "battler-position" },
  }
  local function collectRequiredContext(instruction)
    if type(instruction) ~= "table" then
      return
    end
    if instruction.op == "set-pokemon-picture-vanished" then
      requiredContext.battlerTopology = { type = "battle-animation-battler-topology" }
    end
    if
      instruction.parameters ~= nil
      and (instruction.parameters.spriteContextSlot ~= nil or instruction.parameters.oamModeSpriteSlots ~= nil)
    then
      requiredContext.spriteContextTable = { type = "battle-animation-sprite-context-table" }
    end
    if instruction.parameters ~= nil and instruction.parameters.pictureSets ~= nil then
      requiredContext.battlerTopology = { type = "battle-animation-battler-topology" }
    end
    if instruction.callback == "pokemon-picture-affine-blend-palette-transition" then
      requiredContext.spriteContextTable = { type = "battle-animation-sprite-context-table" }
    elseif instruction.callback == "battle-sprite-sinusoidal-position-animation" then
      requiredContext.battlerTopology = { type = "battle-animation-battler-topology" }
      requiredContext.spriteContextTable = { type = "battle-animation-sprite-context-table" }
    elseif instruction.callback == "battle-sprite-priority-appearance-transition" then
      requiredContext.battlerTopology = { type = "battle-animation-battler-topology" }
      requiredContext.spriteContextTable = { type = "battle-animation-sprite-context-table" }
    elseif
      instruction.callback == "battle-background-alpha-scroll-transition"
      or instruction.callback == "battle-background-sprite-slide-transition"
    then
      requiredContext.battlerTopology = { type = "battle-animation-battler-topology" }
    elseif instruction.callback == "pokemon-picture-selected-position-offset-transition" then
      requiredContext.battlerTopology = { type = "battle-animation-battler-topology" }
    elseif instruction.callback == "pokemon-picture-offset-transition" then
      requiredContext.battlerTopology = { type = "battle-animation-battler-topology" }
    elseif instruction.callback == "pokemon-picture-cyclic-two-phase-position-transition" then
      requiredContext.battlerTopology = { type = "battle-animation-battler-topology" }
    elseif instruction.callback == "pokemon-picture-linear-offscreen-transition" then
      requiredContext.battlerTopology = { type = "battle-animation-battler-topology" }
    elseif instruction.callback == "battle-background-four-picture-move-power-transition" then
      requiredContext.movePower = { type = "battle-animation-move-power-u16" }
    end
    for _, nested in pairs(instruction) do
      if type(nested) == "table" then
        collectRequiredContext(nested)
      end
    end
  end
  for _, instruction in ipairs(effectProgram.instructions) do
    collectRequiredContext(instruction)
  end
  local subprograms = effectProgram.subprograms
  if type(subprograms) ~= "table" then
    return nil,
      Errors.new("BATTLE_EFFECT_CLOSURE_UNRESOLVED", "effect program carries no subprogram closure", {
        effectKey = effectKey,
        archiveSymbol = route.archiveSymbol,
        memberId = route.memberId,
        resolvedSourceInputs = resolvedSourceInputs,
        resourceDescriptors = resolvedResources,
        resourcePayloads = resourcePayloads,
      })
  end
  for _, subprogram in pairs(subprograms) do
    collectRequiredContext(subprogram)
  end
  local soundSymbols = {}
  for _, instruction in ipairs(effectProgram.instructions) do
    if instruction.sound ~= nil then
      soundSymbols[instruction.sound] = true
    end
  end
  local audioProvenance, particleProvenance = {}, {}
  if next(soundSymbols) ~= nil then
    local audioCompiler = require("romdump.src.digest.audio.AudioCompiler")
    local audioPlan, audioPlanErr = audioCompiler.planSource(romFs)
    if audioPlan == nil then
      return nil, audioPlanErr
    end
    local index = audioPlan.plan.index
    local plannedBanks = {}
    for _, bankSymbol in ipairs(animationSources.EFFECT_SOUND_BANKS) do
      local bankId = index.bankBySymbol[bankSymbol]
      assert(bankId ~= nil, "effect sound bank is source-indexed: " .. bankSymbol)
      plannedBanks[bankId] = true
    end
    local sequencesByBank = {}
    for _, instruction in ipairs(effectProgram.instructions) do
      local sequenceSymbol = instruction.sound
      if sequenceSymbol ~= nil then
        local sequenceId = index.sequenceBySymbol[sequenceSymbol]
        local sequenceRecord = sequenceId ~= nil and index.sequences[sequenceId] or nil
        if sequenceRecord == nil then
          return nil,
            Errors.new("BATTLE_EFFECT_CLOSURE_UNRESOLVED", "effect sound has no source-indexed sequence", {
              effectKey = effectKey,
              sequenceSymbol = sequenceSymbol,
            })
        end
        local bankId = sequenceRecord.bankId
        if not plannedBanks[bankId] then
          local bankRecord = index.banks[bankId]
          return nil,
            Errors.new("BATTLE_EFFECT_CLOSURE_UNRESOLVED", "effect sound lives outside the effect sound banks", {
              effectKey = effectKey,
              sequenceSymbol = sequenceSymbol,
              bankSymbol = bankRecord ~= nil and bankRecord.symbol or nil,
            })
        end
        sequencesByBank[bankId] = sequencesByBank[bankId] or {}
        sequencesByBank[bankId][sequenceId] = true
      end
    end
    local bankIds = {}
    for bankId in pairs(sequencesByBank) do
      bankIds[#bankIds + 1] = bankId
    end
    table.sort(bankIds)
    for _, bankId in ipairs(bankIds) do
      local sequenceIds = {}
      for sequenceId in pairs(sequencesByBank[bankId]) do
        sequenceIds[#sequenceIds + 1] = sequenceId
      end
      table.sort(sequenceIds)
      audioProvenance[#audioProvenance + 1] = { bankId = bankId, sequenceIds = sequenceIds }
    end
  end

  local particleResourceKeys = {}
  for _, instruction in ipairs(effectProgram.instructions) do
    if instruction.op == "create-battler-effect" and instruction.resource ~= nil then
      particleResourceKeys[instruction.resource] = true
    end
  end
  local orderedParticleKeys = {}
  for resourceKey in pairs(particleResourceKeys) do
    orderedParticleKeys[#orderedParticleKeys + 1] = resourceKey
  end
  table.sort(orderedParticleKeys)
  for _, resourceKey in ipairs(orderedParticleKeys) do
    local particle = decodedParticleResources[resourceKey]
    local source = particle and particle.source or animationSources.resolveParticleSource(resourceKey)
    if source == nil or source.decoder ~= "spl" or source.kind ~= "particle" then
      return nil,
        Errors.new("BATTLE_EFFECT_CLOSURE_UNRESOLVED", "particle resource has no typed producer source", {
          effectKey = effectKey,
          resourceKey = resourceKey,
        })
    end
    if particle == nil then
      local particleArchive = archives[source.archiveSymbol]
      if particleArchive == nil then
        local openedParticleArchive, particleArchiveError = romFs:openNarc(source.archiveSymbol)
        if openedParticleArchive == nil then
          return nil, particleArchiveError
        end
        particleArchive = openedParticleArchive
        archives[source.archiveSymbol] = openedParticleArchive
      end
      local bytes, particleReadErr = particleArchive:readMember(source.memberId)
      if bytes == nil then
        return nil, particleReadErr
      end
      local decoded, particleDecodeErr = Spl.decode(bytes, { role = "battle-effect-particle" })
      if decoded == nil then
        return nil, particleDecodeErr
      end
      particle = { bytes = bytes, decoded = decoded, source = source }
      decodedParticleResources[resourceKey] = particle
    end
    local decoded = particle.decoded
    local provenance = {
      archiveSymbol = particle.source.archiveSymbol,
      memberId = particle.source.memberId,
    }
    local archiveDecoded = decoded --[[@as NitroSplData]]
    assert(
      archiveDecoded ~= nil and type(archiveDecoded.emitters) == "table",
      "particle archives decode before staging"
    )
    local normalizedEmitters = nil
    local entries = nil
    local normalizedOk, normalizeErr = pcall(function()
      entries = stageParticleArchiveResources(archiveDecoded, provenance)
      normalizedEmitters = {}
      for emitterIndex, emitter in ipairs(archiveDecoded.emitters) do
        normalizedEmitters[emitterIndex] = normalizeParticleEmitter(emitter, entries, emitterIndex - 1, provenance)
      end
    end)
    if not normalizedOk then
      if Errors.is(normalizeErr) then
        return nil, normalizeErr
      end
      error(normalizeErr, 0)
    end
    assert(entries ~= nil and normalizedEmitters ~= nil, "particle archives normalize before staging")
    local normalizedResources = {}
    for resourceIndex, entry in ipairs(entries) do
      normalizedResources[resourceIndex] = { textureKey = entry.textureKey, paletteKey = entry.paletteKey }
    end
    local normalizedParticle = {
      emitters = normalizedEmitters,
      resources = normalizedResources,
    }
    addEffectResource(resourceKey, "particle", Hashing.sha1hex(particle.bytes), normalizedParticle)
    particleProvenance[#particleProvenance + 1] = {
      resourceKey = resourceKey,
      archiveSymbol = particle.source.archiveSymbol,
      memberId = particle.source.memberId,
    }
  end

  -- Rasterize every pending character tile set through its paired
  -- source palette into the exact RGBA drawable the live image upload
  -- path requires. Same-call co-selections pair directly; lone
  -- characters pair through the creating instruction that carries both
  -- the character key and its palette key. A character with no
  -- discoverable palette, or one claimed by two different palettes,
  -- fails the build instead of publishing raw Nitro bitfields.
  local function rasterizePendingCharacters()
    if next(pendingCharacterRasters) == nil then
      return
    end
    local pairByCharacter = {}
    for _, instruction in ipairs(effectProgram.instructions) do
      if type(instruction.resourceKeys) == "table" then
        local characters, palettes = {}, {}
        for _, key in pairs(instruction.resourceKeys) do
          if pendingCharacterRasters[key] ~= nil then
            characters[#characters + 1] = key
          elseif type(resolvedResources[key]) == "table" and resolvedResources[key].kind == "palette" then
            palettes[#palettes + 1] = key
          end
        end
        if #palettes == 1 then
          for _, characterKey in ipairs(characters) do
            if pairByCharacter[characterKey] == nil then
              pairByCharacter[characterKey] = palettes[1]
            elseif pairByCharacter[characterKey] ~= palettes[1] then
              error(
                Errors.new(
                  "BATTLE_EFFECT_CLOSURE_UNRESOLVED",
                  "managed sprite character pairs with more than one staged palette",
                  {
                    effectKey = effectKey,
                    resourceKey = characterKey,
                  }
                ),
                0
              )
            end
          end
        end
      end
    end
    for characterKey, pending in pairs(pendingCharacterRasters) do
      local paletteKey = pending.paletteKey or pairByCharacter[characterKey]
      local paletteDescriptor = paletteKey ~= nil and resolvedResources[paletteKey] or nil
      local palettePayload = paletteDescriptor ~= nil and resourcePayloads[paletteDescriptor.payload] or nil
      if type(palettePayload) ~= "table" or type(palettePayload[1]) ~= "table" or palettePayload[1].r == nil then
        error(
          Errors.new("BATTLE_EFFECT_CLOSURE_UNRESOLVED", "managed sprite character has no paired staged palette", {
            effectKey = effectKey,
            resourceKey = characterKey,
            role = pending.role,
          }),
          0
        )
      end
      local tileSize = pending.chars.depth == 3 and 32 or 64
      local tileCount = math.floor(#pending.chars.tiles / tileSize)
      local raster = G2dRasterizer.renderTileStrip(pending.chars, { colors = palettePayload }, 0, tileCount, 0, {
        role = "battle effect " .. effectKey .. " " .. pending.role .. " characters",
      })
      resourcePayloads[pending.payloadPath] = {
        width = raster.width,
        height = raster.height,
        rgba8888 = raster.pixels,
      }
    end
  end
  local rasterOk, rasterErr = pcall(rasterizePendingCharacters)
  if not rasterOk then
    if Errors.is(rasterErr) then
      return nil, rasterErr
    end
    error(rasterErr, 0)
  end

  local dependencies = {}
  for key in pairs(resolvedResources) do
    dependencies[#dependencies + 1] = key
  end
  table.sort(dependencies)
  local catalogIdentity = versionId .. ":" .. romFs:metadata().sha1
  local effect = {
    schema = require("libs.assets.src.battle.BattleAnimationSchema").EFFECT_SCHEMA,
    key = effectKey,
    catalogIdentity = catalogIdentity,
    program = effectProgram,
    dependencies = dependencies,
    resources = resolvedResources,
    requiredContext = requiredContext,
    resourcePayloads = resourcePayloads,
    provenance = {
      archiveSymbol = route.archiveSymbol,
      memberId = route.memberId,
      sourceInputs = sourceInputs,
      resolvedSourceInputs = resolvedSourceInputs,
      audio = audioProvenance,
      particle = particleProvenance,
    },
  }
  local effectSchema = require("libs.assets.src.battle.BattleAnimationSchema")
  local valid, validationError = pcall(effectSchema.assertEffect, {
    schema = effect.schema,
    key = effect.key,
    catalogIdentity = effect.catalogIdentity,
    program = effect.program,
    dependencies = effect.dependencies,
    resources = effect.resources,
    requiredContext = effect.requiredContext,
  })
  if not valid then
    if Errors.is(validationError) then
      local validation = validationError --[[@as Errors.Error]]
      local instructionIndex = validation.message:match("instructions%[(%d+)%]")
      local diagnosticContext = {}
      for key, value in pairs(validation.context) do
        diagnosticContext[key] = value
      end
      diagnosticContext.effectKey = effectKey
      if instructionIndex ~= nil then
        local index = tonumber(instructionIndex)
        assert(index ~= nil, "schema instruction index parses as an integer")
        diagnosticContext.instructionIndex = index
        if sourceOffsets ~= nil then
          diagnosticContext.sourceOffset = sourceOffsets[index]
        end
        local instruction = effectProgram.instructions[index]
        if instruction ~= nil then
          diagnosticContext.continuationSlot = instruction.continuationSlot
        end
      end
      error(Errors.new(validation.code, validation.message, diagnosticContext), 0)
    end
    error(validationError, 0)
  end
  return effect
end

-- Stage one compiled effect through a worker artifact: the schema-valid
-- record and the completion marker. Returns the marker.
---@param artifact PreparedArtifact
---@param effect BattlePresentationEffect compileEffect record
---@param marker string completion marker
---@return string marker
function BattlePresentationCompiler.stageEffect(artifact, effect, marker)
  assert(type(marker) == "string" and marker ~= "", "effect staging requires its marker")
  local stage = artifact:stageFs()
  artifact:addOwnedRoot(BattlePresentationCache.effectPath(effect.key))
  artifact:addOwnedRoot(BattlePresentationCache.effectMarkerPath(effect.key))
  local resourcePaths = {}
  local referencedPaths = {}
  for _, descriptor in pairs(effect.resources) do
    assert(
      effect.resourcePayloads[descriptor.payload] ~= nil,
      "effect resource payload must be decoded before publication: " .. descriptor.payload
    )
    if not referencedPaths[descriptor.payload] then
      referencedPaths[descriptor.payload] = true
      resourcePaths[#resourcePaths + 1] = descriptor.payload
    end
  end
  for path in pairs(effect.resourcePayloads) do
    assert(referencedPaths[path], "decoded effect payload must have a semantic resource descriptor: " .. path)
  end
  table.sort(resourcePaths)
  for _, path in ipairs(resourcePaths) do
    artifact:addOwnedRoot(path)
    stage:writeLua(path, effect.resourcePayloads[path])
  end
  stage:writeLua(BattlePresentationCache.effectPath(effect.key), {
    schema = effect.schema,
    key = effect.key,
    catalogIdentity = effect.catalogIdentity,
    program = effect.program,
    dependencies = effect.dependencies,
    resources = effect.resources,
    requiredContext = effect.requiredContext,
  })
  stage:write(BattlePresentationCache.effectMarkerPath(effect.key), marker)
  return marker
end

-- The content identity behind one effect completion marker.
---@param romSha1 string
---@param effect BattlePresentationEffect compileEffect record
---@return string marker
function BattlePresentationCompiler.effectMarker(romSha1, effect)
  local payloadHashes = {}
  for path, payload in pairs(effect.resourcePayloads) do
    payloadHashes[path] = Hashing.hashLua(payload)
  end
  return BattlePresentationCache.marker(
    romSha1,
    Hashing.hashLua({
      key = effect.key,
      program = effect.program,
      dependencies = effect.dependencies,
      resources = effect.resources,
      requiredContext = effect.requiredContext,
      payloads = payloadHashes,
    })
  )
end

return BattlePresentationCompiler
