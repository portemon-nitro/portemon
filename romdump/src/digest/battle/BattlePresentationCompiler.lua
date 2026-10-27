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
local PngWriter = require("romdump.src.digest.PngEncoder")
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
---@param patch { left: integer, top: integer, right: integer, bottom: integer, offset: integer, crop?: { left: integer, top: integer, right: integer, bottom: integer } } inclusive source tile rectangle, raw map offset, and optional wider tile crop
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
  -- The staged patch covers the offset tiles unless the caller names a
  -- wider tile crop around them.
  local crop = patch.crop or patch
  local patchWidth = (crop.right - crop.left + 1) * 8
  local patchHeight = (crop.bottom - crop.top + 1) * 8
  local rowBytes = patchWidth * 4
  local rows = {}
  for y = crop.top * 8, (crop.bottom + 1) * 8 - 1 do
    local start = (y * screenData.width + crop.left * 8) * 4 + 1
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

-- The species record's trailing PokepicSpeciesAnimData fields: the signed
-- shadow height and X offset and the shadow size the opponent Pokepic uses.
local function pictureShadow(animationBytes, speciesId)
  local offset = speciesId * Sources.PICTURE_ANIMATION_RECORD_SIZE + 86
  local height, xOffset, size = string.byte(animationBytes, offset + 1, offset + 3)
  assert(size ~= nil, "picture shadow attributes are truncated for species " .. speciesId)
  if height >= 128 then
    height = height - 256
  end
  if xOffset >= 128 then
    xOffset = xOffset - 256
  end
  return { height = height, xOffset = xOffset, size = size }
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
                shadow = facing == 2 and pictureShadow(animationBytes, speciesId) or nil,
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
  tripleRoles("cursor", ROLES.cursor)
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

---@generic K
---@param values table<K, unknown> set or map whose keys are listed
---@return K[] sorted keys
local function sortedSetValues(values)
  local result = {}
  for value in pairs(values) do
    result[#result + 1] = value
  end
  table.sort(result)
  return result
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

-- Discovers overlay_06.c's sMoveTypePalettes: the one run of word pointers
-- into the overlay image, each naming a sixteen-color BGR555 palette.
---@param romFs RomFs
---@return table<string, { colors: { r: integer, g: integer, b: integer }[] }> palettes by type key
local function compileMoveTypePalettes(romFs)
  local source = Sources.MOVE_BUTTONS.typePalettes
  local bytes, info = romFs:readOverlay(source.cpu, source.overlayId)
  if bytes == nil then
    error(info, 0)
  end
  assert(info ~= nil, "overlay reads describe their image")
  local base = info.ramAddress --[[@as integer]]
  local function word(offset)
    local b0, b1, b2, b3 = string.byte(bytes, offset + 1, offset + 4)
    return b0 + b1 * 0x100 + b2 * 0x10000 + b3 * 0x1000000
  end
  local tableOffset = nil
  for offset = 0, #bytes - source.count * 4, 4 do
    local inside = true
    for index = 0, source.count - 1 do
      local pointer = word(offset + index * 4)
      if pointer < base or pointer + 32 > base + #bytes then
        inside = false
        break
      end
    end
    if inside then
      if tableOffset ~= nil then
        error(Errors.new("BATTLE_SOURCE_UNEXPECTED", "move type palette table is ambiguous", {}), 0)
      end
      tableOffset = offset
    end
  end
  if tableOffset == nil then
    error(Errors.new("BATTLE_SOURCE_UNEXPECTED", "move type palette table is absent from its overlay", {}), 0)
  end
  local palettes = {}
  for typeId = 0, source.count - 1 do
    local start = word(tableOffset + typeId * 4) - base
    local colors = {}
    for index = 0, 15 do
      local low, high = string.byte(bytes, start + index * 2 + 1, start + index * 2 + 2)
      colors[index + 1] = Rgb555.decode(low + high * 0x100)
    end
    palettes[assert(MonSources.typeKeys[typeId], "move types have semantic keys")] = { colors = colors }
  end
  return palettes
end

-- Returns a caught structured failure as a value; anything else is a
-- programming error and propagates unchanged.
---@param err unknown failure caught by pcall
---@return Errors.Error structured failure
local function structuredFailure(err)
  if Errors.is(err) then
    return err --[[@as Errors.Error]]
  end
  error(err, 0)
end

-- Optional source message route fields and their normalized names.
local MESSAGE_SOURCE_ROUTE_FIELDS = {
  programContext = "programContext",
  placeholderPlan = "placeholderPlan",
  mailExpansion = "expansion",
  mailCase = "selectionCase",
  placeholders = "placeholderInputs",
  buffers = "bufferPlan",
  selection = "selection",
  recordSelection = "recordSelection",
  resources = "resources",
  routes = "routes",
  reachable = "reachableCases",
  unresolved = "unresolvedCases",
}

-- Copies a source menu context without its producer-only selector facts.
---@param value unknown source context value
---@return unknown copy
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

-- Message entries, routes, and fonts each menu text set draws.
---@return table<string, { entries: string[], routes: string[], fonts: string[] }> text sets by key
local function compileMenuTextSets()
  local textSets = {
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
      textSets.main.entries[#textSets.main.entries + 1] = key
    end
  end
  for _, key in pairs(Sources.MENU_MODE_RULES["pal-park"].labels) do
    textSets["pal-park"].entries[#textSets["pal-park"].entries + 1] = key
  end
  return textSets
end

-- One source menu route normalized with its text set, required context,
-- asset roles, and the staged layout resources it reaches.
---@param route table<string, unknown> source menu route
---@param textSet { entries: string[], routes: string[], fonts: string[] }
---@param menuLayouts table<string, table<string, unknown>> staged menu layouts
---@param resourceCatalog table<string, unknown> staged catalog
---@return table<string, unknown> normalized menu route
local function normalizeMenuRoute(route, textSet, menuLayouts, resourceCatalog)
  local normalized = {
    screenGroup = route.screenGroup,
    textSet = route.textSet,
    mode = route.mode,
    phase = route.phase,
    messageEntries = copyStrings(textSet.entries),
    messageRoutes = copyStrings(textSet.routes),
    fontRoles = copyStrings(textSet.fonts),
    assetRoles = {},
    assetBindings = {},
    requiredContext = {},
    resources = {},
  }
  local function addLayoutResources(layout)
    for _, resource in pairs(layout) do
      if type(resource) == "string" and resourceCatalog[resource] ~= nil then
        normalized.resources[#normalized.resources + 1] = resource
      end
    end
  end
  if route.screenGroup == "command" then
    normalized.requiredContext[#normalized.requiredContext + 1] = "main"
    normalized.requiredContext[#normalized.requiredContext + 1] = "frontier"
    addLayoutResources(menuLayouts.frontier)
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
    addLayoutResources(menuLayouts.bugContest)
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
  return normalized
end

-- Tokenizes the battle menu labels and every source message record into
-- semantic message entries.
---@param decodedMessageBanks table<string, table<string, unknown>> decoded message banks by role
---@return table<string, { tokens: table[] }> entries by semantic key
---@return table<string, unknown> provenance source message ids by semantic key
local function tokenizeMessageEntries(decodedMessageBanks)
  local messageEntries = {}
  local messageProvenance = {}
  for _, key in ipairs(sortedSetValues(Sources.MENU_MESSAGES)) do
    local messageId = Sources.MENU_MESSAGES[key]
    local tokens, tokenFailure = UiMessageBank.tokens(decodedMessageBanks.scriptController, 197, messageId, charmap)
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
  for _, key in ipairs(sortedSetValues(Sources.MESSAGE_RECORDS)) do
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
  return messageEntries, messageProvenance
end

-- A source route's bank references as staged catalog keys: staged keys
-- pass through, bank roles resolve to their staged bank.
---@param sourceRoute table<string, unknown> source message route
---@param messageBanks table<string, string> staged bank key by role
---@param resourceCatalog table<string, unknown> staged catalog
---@param bankRoleByResourceKey table<string, string> bank role by semantic resource key
---@return string[] references
local function semanticBankReferences(sourceRoute, messageBanks, resourceCatalog, bankRoleByResourceKey)
  local references = {}
  local function addReference(reference)
    if bankRoleByResourceKey[reference] ~= nil or resourceCatalog[reference] ~= nil then
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

-- Normalizes every source message route under its semantic key.
---@param messageBanks table<string, string> staged bank key by role
---@param resourceCatalog table<string, unknown> staged catalog
---@return table<string, table<string, unknown>> routes by semantic key
local function compileMessageSourceRoutes(messageBanks, resourceCatalog)
  local bankRoleByResourceKey = {}
  for role, resourceKey in pairs(Sources.MESSAGE_BANK_RESOURCE_KEYS) do
    bankRoleByResourceKey[resourceKey] = role
  end
  local sourceMessageRoutes = Sources.MESSAGE_ROUTES
  local routes = {}
  for sourceName, sourceRoute in pairs(Sources.MESSAGE_SOURCE_ROUTES) do
    local key = assert(sourceRoute.key, "message source route has a semantic key")
    local inputs = sourceRoute.inputs or sourceRoute.operands
    if inputs == nil and sourceRoute.input ~= nil then
      inputs = { sourceRoute.input }
    end
    local route = {
      banks = semanticBankReferences(sourceRoute, messageBanks, resourceCatalog, bankRoleByResourceKey),
      inputs = inputs or {},
    }
    for sourceField, field in pairs(MESSAGE_SOURCE_ROUTE_FIELDS) do
      route[field] = sourceRoute[sourceField]
    end
    if sourceName == "frontierTrainerSpeech" then
      route.recordFormula = sourceMessageRoutes.frontierTrainerSpeech.recordFormula
      route.profilePredicate = sourceMessageRoutes.frontierTrainerSpeech.profilePredicate
    elseif sourceName == "trainerPairSpeech" then
      route.recordSelection = sourceMessageRoutes.trainerPairSpeech.recordSelection
    elseif sourceName == "recorderFeedback" then
      route.routes = { "menu/vs-recorder-feedback" }
    end
    routes[key] = route
  end
  return routes
end

-- Global catalog staging: one semantic key per decoded payload. `staging`
-- pairs the manifest resource catalog with the payloads staged beside it.
---@class BattleGlobalStaging
---@field catalog table<string, { kind: string, contentIdentity: string, format: string, geometry: table<string, unknown>, path: string }>
---@field payloads table<string, unknown>

---@param staging BattleGlobalStaging
---@param resourceKey string semantic catalog key
---@param descriptor { kind: string, contentIdentity: string, format: string, geometry: table<string, unknown> } catalog entry without its path
---@param payload unknown decoded payload staged at the key's path
local function stageCatalogResource(staging, resourceKey, descriptor, payload)
  local path = BattlePresentationCache.globalResourcePath(resourceKey)
  staging.catalog[resourceKey] = {
    kind = descriptor.kind,
    contentIdentity = descriptor.contentIdentity,
    format = descriptor.format,
    geometry = descriptor.geometry,
    path = path,
  }
  staging.payloads[path] = payload
end

-- Stages the trainer message offset and pair index tables after checking
-- their record widths and that every offset stays inside the pair table.
---@param romFs RomFs
---@param staging BattleGlobalStaging
---@return table<string, table<string, unknown>> provenance offsets/pairs source coordinates and identities
local function stageTrainerMessageTables(romFs, staging)
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
    trainerPairs[offset / 4 + 1] =
      { trainerIndex = pairsReader:u16le(offset), messageKind = pairsReader:u16le(offset + 2) }
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
  stageCatalogResource(staging, "trainer-message-index/offsets", {
    kind = "message",
    contentIdentity = Hashing.sha1hex(offsetBytes),
    format = "hgss-trainer-message-offsets-v1",
    geometry = { recordCount = #trainerOffsets },
  }, { format = "HGSS_TRAINER_MESSAGE_OFFSETS", offsets = trainerOffsets })
  stageCatalogResource(staging, "trainer-message-index/pairs", {
    kind = "message",
    contentIdentity = Hashing.sha1hex(pairBytes),
    format = "hgss-trainer-message-pairs-v1",
    geometry = { recordCount = #trainerPairs },
  }, { format = "HGSS_TRAINER_MESSAGE_PAIRS", records = trainerPairs })
  return {
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
end

---@param decoded { cells: { objs: { x: integer, y: integer, width: integer, height: integer }[] }[] }
---@return { cellCount: integer, bounds: table[] } per-cell OBJ bounding boxes
local function cellBoundsGeometry(decoded)
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
  return { cellCount = #decoded.cells, bounds = bounds }
end

---@param decoded { colors: table[] }
---@return string format, table<string, unknown> geometry
local function describePalette(decoded)
  return "nitro-palette-rgb888-v1", { colorCount = #decoded.colors }
end

---@param decoded { depth: integer, tiles: string }
---@return string format, table<string, unknown> geometry
local function describeCharacters(decoded)
  return decoded.depth == 3 and "nitro-char-4bpp-v1" or "nitro-char-8bpp-v1",
    { depth = decoded.depth, tileCount = #decoded.tiles / (decoded.depth == 3 and 32 or 64) }
end

---@param decoded { width: integer, height: integer, entries: table[] }
---@return string format, table<string, unknown> geometry
local function describeScreen(decoded)
  return "nitro-bg-map-v1", { width = decoded.width, height = decoded.height, entryCount = #decoded.entries }
end

---@param decoded { cells: table[] }
---@return string format, table<string, unknown> geometry
local function describeCells(decoded)
  return "nitro-obj-cells-v1", cellBoundsGeometry(decoded)
end

---@param decoded { anims: { frames: table[] }[] }
---@return string format, table<string, unknown> geometry
local function describeAnimation(decoded)
  local frameCount = 0
  for _, animation in ipairs(decoded.anims) do
    frameCount = frameCount + #animation.frames
  end
  return "nitro-obj-animation-v1",
    { animationCount = #decoded.anims, frameCount = frameCount, durationUnit = "native-frame" }
end

-- Catalog resource kinds: each decodes one archive member and names its
-- staged format and geometry.
local CATALOG_RESOURCE_CODECS = {
  palette = { decode = decodePalette, describe = describePalette },
  texture = { decode = decodeChars, describe = describeCharacters },
  map = { decode = decodeScreen, describe = describeScreen },
  cell = { decode = decodeCells, describe = describeCells },
  animation = { decode = decodeAnimation, describe = describeAnimation },
}

-- Decodes one catalog resource member of a kind with a codec, letting
-- `prepare` normalize the decoded payload before its geometry is measured.
---@param archive Narc
---@param memberId integer
---@param kind string catalog resource kind
---@param label string diagnostic label
---@param prepare? fun(decoded: table<string, unknown>) in-place normalization
---@return table<string, unknown> decoded payload
---@return string format
---@return table<string, unknown> geometry
local function decodeCatalogResource(archive, memberId, kind, label, prepare)
  local codec = assert(CATALOG_RESOURCE_CODECS[kind], "catalog resource kinds are checked before decoding")
  local decoded = codec.decode(archive, memberId, label)
  if prepare ~= nil then
    prepare(decoded)
  end
  local format, geometry = codec.describe(decoded)
  return decoded, format, geometry
end

-- Transition resource sets never stage BG maps.
local TRANSITION_SET_KINDS = { palette = true, texture = true, cell = true, animation = true }

-- Stages the fixed transition resource sets under `<set>/<resource>` keys.
---@param staging BattleGlobalStaging
---@param transitionArchive Narc
---@return table<string, table<string, string>> resourceSets catalog keys by set and resource key
---@return table<string, { archive: string, memberId: integer }> provenance by catalog key
local function stageTransitionResourceSets(staging, transitionArchive)
  local resourceSets = {}
  local provenance = {}
  for _, set in ipairs(Sources.TRANSITION_RESOURCE_SETS) do
    local resourceKeys = {}
    for _, resource in ipairs(set.resources) do
      local bytes = must(transitionArchive:readMember(resource.member))
      local resourceKey = set.key .. "/" .. resource.key
      local label = "transition " .. resourceKey
      -- Route cells normalize against the depth of the set's characters,
      -- which the source lists before them.
      local function normalizeCells(decoded)
        local sourceMapping, mappingErr = G2dDecoder.decodeCellMapping(bytes, { label = label })
        local mapping = mustDecode(sourceMapping, mappingErr, label .. " mapping", resource.member)
        local characterKey = assert(resourceKeys.characters, "the route cell follows its character resource")
        local characterResource =
          assert(staging.catalog[characterKey], "the route character is cataloged before its cell")
        TransitionCellNormalizer.normalize(decoded, mapping, characterResource.geometry.depth)
      end
      if not TRANSITION_SET_KINDS[resource.kind] then
        error(
          Errors.new("BATTLE_RESOURCE_KIND_UNKNOWN", "transition resource has no decoder", {
            resource = resourceKey,
            kind = resource.kind,
          }),
          0
        )
      end
      local decoded, format, geometry = decodeCatalogResource(
        transitionArchive,
        resource.member,
        resource.kind,
        label,
        resource.kind == "cell" and normalizeCells or nil
      )
      stageCatalogResource(staging, resourceKey, {
        kind = resource.kind,
        contentIdentity = Hashing.sha1hex(bytes),
        format = format,
        geometry = geometry,
      }, decoded)
      resourceKeys[resource.key] = resourceKey
      provenance[resourceKey] = {
        archive = Sources.TRANSITION_ARCHIVE,
        memberId = resource.member,
      }
    end
    resourceSets[set.key] = resourceKeys
  end
  return resourceSets, provenance
end

---@class BattleTransitionStaging
---@field resourceSets table<string, table<string, string>>
---@field provenance table<string, { archive: string, memberId: integer }>
---@field sourceResources table<string, string> catalog key by `<kind>:<memberId>` source identity
---@field resourceMembers table<string, { archive: string, members: table<integer, { selectors: table<unknown, true> }> }>
---@field keySet table<string, true> content-addressed transition catalog keys
---@field particleMembers table<string, { archive: string, memberId: integer }>
---@field embeddedParticleResources table<string, { texture: string|nil, palette: string|nil }[]>

-- Stages each typed transition member once under its content-addressed
-- key, recording which source selectors reach it.
---@param staging BattleGlobalStaging
---@param transitionArchive Narc
---@param transition BattleTransitionStaging
local function stageTransitionTypedResources(staging, transitionArchive, transition)
  for _, source in ipairs(Sources.TRANSITION_TYPED_RESOURCES) do
    local provenanceKey = source.kind .. ":" .. source.memberId
    if transition.sourceResources[provenanceKey] == nil then
      local bytes = must(transitionArchive:readMember(source.memberId))
      local contentIdentity = Hashing.sha1hex(bytes)
      local resourceKey = "transition/content/" .. source.kind .. "/" .. contentIdentity
      local label = "transition member " .. source.memberId .. " payload " .. resourceKey
      if CATALOG_RESOURCE_CODECS[source.kind] == nil then
        error(
          Errors.new("BATTLE_RESOURCE_KIND_UNKNOWN", "transition source resource has no decoder", {
            memberId = source.memberId,
            kind = source.kind,
          }),
          0
        )
      end
      local decoded, format, geometry = decodeCatalogResource(transitionArchive, source.memberId, source.kind, label)
      stageCatalogResource(staging, resourceKey, {
        kind = source.kind,
        contentIdentity = contentIdentity,
        format = format,
        geometry = geometry,
      }, decoded)
      transition.keySet[resourceKey] = true
      if transition.resourceMembers[resourceKey] == nil then
        transition.resourceMembers[resourceKey] = {
          archive = Sources.TRANSITION_ARCHIVE,
          members = {},
        }
      end
      transition.sourceResources[provenanceKey] = resourceKey
    end
    local memberProvenance = transition.resourceMembers[transition.sourceResources[provenanceKey]]
    for _, sourceSelector in ipairs(source.selectors) do
      local sourceProvenance = memberProvenance.members[source.memberId]
      if sourceProvenance == nil then
        sourceProvenance = { selectors = {} }
        memberProvenance.members[source.memberId] = sourceProvenance
      end
      sourceProvenance.selectors[sourceSelector] = true
    end
  end
end

-- Stages one embedded APS texture or palette payload by content identity.
---@param staging BattleGlobalStaging
---@param transition BattleTransitionStaging
---@param kind "texture"|"palette"
---@param bytes string raw embedded payload
---@return string resourceKey
local function stageTransitionParticlePayload(staging, transition, kind, bytes)
  local identity = Hashing.sha1hex(bytes)
  local key = "transition/content/" .. kind .. "/" .. identity
  if staging.catalog[key] == nil then
    stageCatalogResource(staging, key, {
      kind = kind,
      contentIdentity = identity,
      format = kind == "texture" and "nitro-spl-texture-data-v1" or "nitro-spl-palette-data-v1",
      geometry = { byteCount = #bytes },
    }, { bytes = bytes })
    transition.keySet[key] = true
  end
  return key
end

-- Stages every transition APS archive with its embedded resources; shared
-- texture references resolve onto the referenced staged texture.
---@param staging BattleGlobalStaging
---@param transitionArchive Narc
---@param transition BattleTransitionStaging
local function stageTransitionParticles(staging, transitionArchive, transition)
  for _, memberId in ipairs(Sources.TRANSITION_PARTICLE_MEMBERS) do
    local bytes = must(transitionArchive:readMember(memberId))
    local decoded = must(Spl.decode(bytes))
    local contentIdentity = Hashing.sha1hex(bytes)
    local resourceKey = "transition/content/particle/" .. contentIdentity
    local embeddedKeys = {}
    local normalizedResources = {}
    for resourceIndex, resource in ipairs(decoded.resources) do
      local textureKey = resource.texture
          and stageTransitionParticlePayload(staging, transition, "texture", resource.texture)
        or nil
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
      local paletteKey = resource.palette
          and stageTransitionParticlePayload(staging, transition, "palette", resource.palette)
        or nil
      embeddedKeys[resourceIndex] = { texture = textureKey, palette = paletteKey }
      normalizedResources[resourceIndex] = { textureKey = textureKey, paletteKey = paletteKey }
    end
    stageCatalogResource(staging, resourceKey, {
      kind = "particle",
      contentIdentity = contentIdentity,
      format = "nitro-spl-aps-v1",
      geometry = { emitterCount = #decoded.emitters, resourceCount = #decoded.resources },
    }, {
      format = decoded.format,
      emitters = decoded.emitters,
      resources = normalizedResources,
      source = decoded.source,
    })
    transition.keySet[resourceKey] = true
    transition.sourceResources["particle:" .. memberId] = resourceKey
    transition.particleMembers[resourceKey] = { archive = Sources.TRANSITION_ARCHIVE, memberId = memberId }
    transition.embeddedParticleResources[resourceKey] = embeddedKeys
  end
end

---@param romFs RomFs
---@param staging BattleGlobalStaging
---@return BattleTransitionStaging transition staged transition resources and their provenance
local function compileTransitionResources(romFs, staging)
  local transitionArchive = openArchive(romFs, Sources.TRANSITION_ARCHIVE, "battle transitions")
  local resourceSets, provenance = stageTransitionResourceSets(staging, transitionArchive)
  ---@type BattleTransitionStaging
  local transition = {
    resourceSets = resourceSets,
    provenance = provenance,
    sourceResources = {},
    resourceMembers = {},
    keySet = {},
    particleMembers = {},
    embeddedParticleResources = {},
  }
  stageTransitionTypedResources(staging, transitionArchive, transition)
  stageTransitionParticles(staging, transitionArchive, transition)
  return transition
end

-- Catalog keys of every typed transition member any listed selector reaches.
---@param sourceResources table<string, string> catalog key by source identity
---@param selectors unknown[] source selectors
---@return string[] sorted catalog keys
local function transitionResourcesForSelectors(sourceResources, selectors)
  local wanted = {}
  for _, selector in ipairs(selectors) do
    wanted[selector] = true
  end
  local selected = {}
  for _, source in ipairs(Sources.TRANSITION_TYPED_RESOURCES) do
    for _, sourceSelector in ipairs(source.selectors) do
      if wanted[sourceSelector] then
        selected[sourceResources[source.kind .. ":" .. source.memberId]] = true
        break
      end
    end
  end
  return sortedSetValues(selected)
end

---@param messageKey string transition name message entry
---@param sourceResources table<string, string> catalog key by source identity
---@return table<string, { message: string, inputs: string[], resources: string[] }> routes by name
local function compileTransitionMessageRoutes(messageKey, sourceResources)
  local routes = {}
  for routeName, sourceRoute in pairs(Sources.TRANSITION_MESSAGE_SOURCE_ROUTES) do
    local input = routeName == "trainerName" and "trainerName" or "rivalName"
    routes[routeName] = {
      message = messageKey,
      inputs = { input },
      resources = transitionResourcesForSelectors(sourceResources, sourceRoute.selectors),
    }
  end
  return routes
end

local TRANSITION_INTERNAL_KINDS = { palette = "palette", character = "texture", cell = "cell", animation = "animation" }

---@param sourceResources table<string, string> catalog key by source identity
---@return table<string, table<string, string>> catalog keys by route and role
local function compileTransitionInternalResources(sourceResources)
  local internalResources = {}
  for routeName, sourceRoleMembers in pairs(Sources.TRANSITION_INTERNAL_RESOURCES) do
    local resourceKeys = {}
    for role, memberId in pairs(sourceRoleMembers) do
      local resourceKey = sourceResources[TRANSITION_INTERNAL_KINDS[role] .. ":" .. memberId]
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
    internalResources[routeName] = resourceKeys
  end
  return internalResources
end

local TRANSITION_KIND_BY_ROLE = {
  palette = "palette",
  character = "texture",
  characters = "texture",
  cell = "cell",
  animation = "animation",
  map = "map",
  maps = "map",
}

---@param sourceResources table<string, string> catalog key by source identity
---@param role string asset group role
---@param memberId number transition member
---@param routeKey string route under normalization
---@return string resourceKey
local function transitionResourceForRole(sourceResources, role, memberId, routeKey)
  local kind = TRANSITION_KIND_BY_ROLE[role]
  if kind == nil then
    error(
      Errors.new("BATTLE_TRANSITION_RESOURCE_UNRESOLVED", "transition route has an unknown resource role", {
        role = role,
      }),
      0
    )
  end
  local resourceKey = sourceResources[kind .. ":" .. memberId]
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

-- Replaces every source member in a route asset group with its catalog key.
---@param sourceResources table<string, string> catalog key by source identity
---@param group table<string, unknown> source asset group
---@param routeKey string route under normalization
---@return table<string, unknown> normalized group
local function normalizeTransitionResourceGroup(sourceResources, group, routeKey)
  local normalized = {}
  for role, value in pairs(group) do
    if type(value) == "number" then
      normalized[role] = transitionResourceForRole(sourceResources, role, value, routeKey)
    elseif type(value) == "table" then
      local entries = {}
      for index, entry in ipairs(value) do
        entries[index] = type(entry) == "number" and transitionResourceForRole(sourceResources, role, entry, routeKey)
          or normalizeTransitionResourceGroup(sourceResources, entry, routeKey)
      end
      normalized[role] = #entries > 0 and entries or normalizeTransitionResourceGroup(sourceResources, value, routeKey)
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

local TRANSITION_ROUTE_GROUPS = {
  "sprite",
  "record",
  "fixedSprite",
  "extraSprite",
  "opponent",
  "nameplate",
  "spriteVariants",
  "background",
  "sceneAssets",
}

-- Context inputs by semantic route family, matched by key prefix.
local TRANSITION_FAMILY_CONTEXT = {
  { prefix = "^fallback/", inputs = { "battleType", "terrain", "timeOfDay" } },
  { prefix = "^wild/", inputs = { "wildSpecies", "battleType" } },
  { prefix = "^trainer/", inputs = { "trainerClass", "battleType" } },
}

---@param sourceRoute table<string, unknown> source selector route
---@return table<string, true> context inputs the route reads
local function transitionRouteContext(sourceRoute)
  local context = {}
  for _, family in ipairs(TRANSITION_FAMILY_CONTEXT) do
    if sourceRoute.key:match(family.prefix) then
      for _, input in ipairs(family.inputs) do
        context[input] = true
      end
      break
    end
  end
  if sourceRoute.context ~= nil and sourceRoute.context.playerGender == true then
    context.playerGender = true
  end
  if sourceRoute.trainer ~= nil then
    context.transitionTrainer = true
  end
  if sourceRoute.messageRoute ~= nil then
    context[sourceRoute.messageRoute == "transition/rival-name" and "rivalName" or "trainerName"] = true
  end
  return context
end

---@param value unknown nested asset group value
---@param set table<string, true> collected strings
local function collectStrings(value, set)
  if type(value) == "string" then
    set[value] = true
  elseif type(value) == "table" then
    for _, nested in pairs(value) do
      collectStrings(nested, set)
    end
  end
end

-- Normalizes one selector's source route into its semantic route record.
---@param sourceRoute table<string, unknown> source selector route
---@param selector unknown source selector
---@param sourceResources table<string, string> catalog key by source identity
---@return table<string, unknown> route semantic route record
---@return table<string, true> resourceSet every catalog key the route reaches
---@return table<string, true> contextSet every context input the route reads
local function normalizeTransitionRoute(sourceRoute, selector, sourceResources)
  local resourceSet = {}
  for _, resourceKey in ipairs(transitionResourcesForSelectors(sourceResources, { selector })) do
    resourceSet[resourceKey] = true
  end
  local groups = {}
  for _, groupName in ipairs(TRANSITION_ROUTE_GROUPS) do
    local sourceGroup = sourceRoute[groupName]
    if sourceGroup ~= nil then
      groups[groupName] = normalizeTransitionResourceGroup(sourceResources, sourceGroup, sourceRoute.key)
    end
  end
  if sourceRoute.particles ~= nil then
    local particles = {}
    for role, memberId in pairs(sourceRoute.particles) do
      local resourceKey = sourceResources["particle:" .. memberId]
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
    end
    groups.particles = particles
  end
  collectStrings(groups, resourceSet)
  local contextSet = transitionRouteContext(sourceRoute)
  local route = {
    role = sourceRoute.role,
    requiredContext = sortedSetValues(contextSet),
    resources = sortedSetValues(resourceSet),
    assetGroups = groups,
    trainer = sourceRoute.trainer ~= nil and { key = sourceRoute.trainer.key } or nil,
    task = sourceRoute.task,
    messages = sourceRoute.messageRoute ~= nil and { sourceRoute.messageRoute } or nil,
  }
  return route, resourceSet, contextSet
end

-- Several selectors may share one semantic key: their roles must agree,
-- at most one carries a task, and resources and context unite.
---@param routeKey string semantic route key
---@param prior table<string, unknown> route already normalized under the key
---@param route table<string, unknown> route under merging
---@param resourceSet table<string, true> the route's catalog keys
---@param contextSet table<string, true> the route's context inputs
local function mergeTransitionRoute(routeKey, prior, route, resourceSet, contextSet)
  if prior.role ~= route.role then
    error(
      Errors.new("BATTLE_TRANSITION_ROUTE_CONFLICT", "semantic transition key has conflicting source roles", {
        route = routeKey,
      }),
      0
    )
  end
  if prior.task ~= nil and route.task ~= nil then
    error(
      Errors.new("BATTLE_TRANSITION_ROUTE_CONFLICT", "semantic transition key has conflicting source tasks", {
        route = routeKey,
      }),
      0
    )
  end
  route.task = route.task or prior.task
  for _, resourceKey in ipairs(prior.resources) do
    resourceSet[resourceKey] = true
  end
  route.resources = sortedSetValues(resourceSet)
  for _, input in ipairs(prior.requiredContext) do
    contextSet[input] = true
  end
  route.requiredContext = sortedSetValues(contextSet)
  if route.messages == nil then
    route.messages = prior.messages
  end
end

---@param sourceResources table<string, string> catalog key by source identity
---@return table<string, table<string, unknown>> semantic transition routes by key
local function compileTransitionRoutes(sourceResources)
  local routes = {}
  for selector, sourceRoute in pairs(Sources.TRANSITION_SELECTOR_ROUTES) do
    local route, resourceSet, contextSet = normalizeTransitionRoute(sourceRoute, selector, sourceResources)
    local prior = routes[sourceRoute.key]
    if prior ~= nil then
      mergeTransitionRoute(sourceRoute.key, prior, route, resourceSet, contextSet)
    end
    routes[sourceRoute.key] = route
  end
  return routes
end

---@param category integer source transition category
---@return string semantic route key
local function semanticCategoryRoute(category)
  local route = Sources.TRANSITION_PRESELECTION.categoryRoutes[category]
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

---@param category integer source transition category
---@return string semantic intro music role
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

---@param sourceRoutes table<unknown, string> source route key by input
---@param categories table<string, integer> source category by route key
---@return table<unknown, string> semantic route by input
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

---@param sourceRoutes table<unknown, string> source route key by input
---@param categories table<string, integer> source category by route key
---@return table<unknown, string> intro music role by input
local function normalizeInputMusicRoles(sourceRoutes, categories)
  local roles = {}
  for inputKey, routeKey in pairs(sourceRoutes) do
    local category = assert(categories[routeKey], "every source trainer or species route has a category")
    roles[inputKey] = musicRoleForCategory(category)
  end
  return roles
end

---@param categories integer[] source transition categories
---@return string[] semantic route keys in category order
local function categoryRoutesForList(categories)
  local routes = {}
  for _, category in ipairs(categories) do
    routes[#routes + 1] = semanticCategoryRoute(category)
  end
  return routes
end

-- The semantic transition preselection: input routes, music roles, and
-- the trainer/wild/setup-fallback selection rules.
---@return table<string, unknown> transition selection
local function compileTransitionSelection()
  local sourcePreselection = Sources.TRANSITION_PRESELECTION
  local trainerClassRoutes =
    normalizeInputRoutes(sourcePreselection.trainerClasses, sourcePreselection.trainerCategoryByKey)
  local wildSpeciesRoutes = normalizeInputRoutes(sourcePreselection.wildSpecies, sourcePreselection.wildCategoryByKey)
  local trainerClassMusicRoles =
    normalizeInputMusicRoles(sourcePreselection.trainerClasses, sourcePreselection.trainerCategoryByKey)
  local wildSpeciesMusicRoles =
    normalizeInputMusicRoles(sourcePreselection.wildSpecies, sourcePreselection.wildCategoryByKey)
  local sourceRules = sourcePreselection.selectionRules
  local specialBattle = sourceRules.trainer.specialBattle
  local selection = {
    trainerClassRoutes = trainerClassRoutes,
    wildSpeciesRoutes = wildSpeciesRoutes,
    trainerClassMusicRoles = trainerClassMusicRoles,
    wildSpeciesMusicRoles = wildSpeciesMusicRoles,
    trainerRules = {
      inputs = { "trainerClass", "battleType" },
      specialBattle = {
        preserveRoute = semanticCategoryRoute(specialBattle.preserveCategory),
        preserveMusicRole = musicRoleForCategory(specialBattle.preserveCategory),
        defaultRoute = semanticCategoryRoute(specialBattle.defaultCategory),
        defaultMusicRole = musicRoleForCategory(specialBattle.defaultCategory),
        doublesRoute = semanticCategoryRoute(specialBattle.doublesCategory),
        doublesMusicRole = musicRoleForCategory(specialBattle.doublesCategory),
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
    selection.fallbackRoutes[selector + 1] = {
      route = sourceRoute.key,
      terrain = context.terrain,
      timeOfDay = context.timeOfDay,
      battleKind = context.isTrainer and "trainer" or "wild",
    }
  end
  return selection
end

-- Closure coverage for every transition route: its context, staged
-- resource identities, and message entries.
---@param routes table<string, table<string, unknown>> semantic transition routes
---@param resourceCatalog table<string, { contentIdentity: string }>
---@param messageEntries table<string, unknown>
---@return table<string, table<string, unknown>> coverage by `transition/<route>` key
local function transitionRouteCoverage(routes, resourceCatalog, messageEntries)
  local coverage = {}
  for routeKey, route in pairs(routes) do
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
    coverage["transition/" .. routeKey] = {
      kind = "transition-route",
      route = routeKey,
      closureIdentity = Hashing.sha1hex(table.concat(identityParts, "\n")),
      resources = route.resources,
      operations = { route.role },
    }
  end
  return coverage
end

-- Normalized catalog sections a semantic root closes over.
---@class BattleSemanticClosureSources
---@field resourceCatalog table<string, { contentIdentity: string }>
---@field messageEntries table<string, unknown>
---@field messageRoutes table<string, table<string, unknown>>
---@field dynamicMessageRoutes table<string, table<string, unknown>>
---@field normalizedMessageSourceRoutes table<string, table<string, unknown>>
---@field sourceMessageRouteKeys table<string, string> semantic key by source message route name
---@field menuRoutes table<string, table<string, unknown>>
---@field transitionMessageRoutes table<string, table<string, unknown>>
---@field transitionRoutes table<string, table<string, unknown>>

---@class BattleSemanticClosure
---@field resources table<string, true>
---@field messages table<string, true>
---@field routes table<string, true>

---@param sources BattleSemanticClosureSources
---@param closure BattleSemanticClosure
---@param value unknown route value under walking
local function collectSemanticResources(sources, closure, value)
  if type(value) == "string" then
    if sources.resourceCatalog[value] ~= nil then
      closure.resources[value] = true
    end
  elseif type(value) == "table" then
    for _, nested in pairs(value) do
      collectSemanticResources(sources, closure, nested)
    end
  end
end

-- Walks a message route value, collecting the resources, message
-- entries, and message routes it transitively reaches.
---@param sources BattleSemanticClosureSources
---@param closure BattleSemanticClosure
---@param value unknown route value under walking
---@param visited table<string, true> route keys already walked
local function collectMessageClosure(sources, closure, value, visited)
  if type(value) == "string" then
    if sources.resourceCatalog[value] ~= nil then
      closure.resources[value] = true
      return
    end
    if sources.messageEntries[value] ~= nil then
      closure.messages[value] = true
      return
    end
    local routeKey = sources.sourceMessageRouteKeys[value] or value
    local route = sources.normalizedMessageSourceRoutes[routeKey]
      or sources.messageRoutes[routeKey]
      or sources.dynamicMessageRoutes[value]
    if route ~= nil then
      closure.routes[routeKey] = true
      if not visited[routeKey] then
        visited[routeKey] = true
        collectMessageClosure(sources, closure, route, visited)
        return
      end
    end
    local dynamic = sources.dynamicMessageRoutes[value]
    if dynamic ~= nil and not visited[value] then
      visited[value] = true
      closure.routes[value] = true
      collectMessageClosure(sources, closure, dynamic, visited)
    end
  elseif type(value) == "table" then
    local firstRecord = value.firstRecord
    local recordCount = value.recordCount
    if type(firstRecord) == "string" and type(recordCount) == "number" then
      local prefix, firstIndex = firstRecord:match("^(.*)/(%d+)$")
      if prefix ~= nil then
        for offset = 0, recordCount - 1 do
          collectMessageClosure(sources, closure, prefix .. "/" .. (tonumber(firstIndex) + offset), visited)
        end
      end
    end
    for key, nested in pairs(value) do
      if key == "placeholderPlan" and nested == "battleMessageTags" then
        collectMessageClosure(sources, closure, "battle/message-template", visited)
      else
        collectMessageClosure(sources, closure, nested, visited)
      end
    end
  end
end

-- The normalized route a semantic root names and the closure it reaches.
---@param sources BattleSemanticClosureSources
---@param root { kind: string, key: string, sourceRouteKey: string }
---@return table<string, unknown>|nil routeValue, BattleSemanticClosure closure
local function semanticRootClosure(sources, root)
  ---@type BattleSemanticClosure
  local closure = { resources = {}, messages = {}, routes = {} }
  local routeValue
  if root.kind == "menu-route" then
    routeValue = sources.menuRoutes[root.sourceRouteKey]
    if routeValue ~= nil then
      collectSemanticResources(sources, closure, routeValue.resources)
      collectMessageClosure(sources, closure, routeValue.messageEntries, {})
      collectMessageClosure(sources, closure, routeValue.messageRoutes, {})
    end
  elseif root.kind == "message-route" then
    routeValue = sources.normalizedMessageSourceRoutes[root.key]
      or sources.messageRoutes[root.sourceRouteKey]
      or sources.transitionMessageRoutes[root.sourceRouteKey]
    if routeValue ~= nil then
      collectMessageClosure(sources, closure, routeValue, { [root.key] = true })
    end
  elseif root.kind == "transition-route" then
    routeValue = sources.transitionRoutes[root.sourceRouteKey]
    if routeValue ~= nil then
      collectSemanticResources(sources, closure, routeValue.resources)
      collectMessageClosure(sources, closure, routeValue.messages, {})
    end
  end
  return routeValue, closure
end

local MENU_FONT_IDS = {
  bugContest = Sources.BUG_CONTEST_FONT_ID,
  recorderFeedback = Sources.RECORDER_FEEDBACK_FONT_ID,
}

-- One semantic root's coverage record and closure identity.
---@param sources BattleSemanticClosureSources
---@param root { kind: string, key: string }
---@param routeValue table<string, unknown> normalized root route
---@param closure BattleSemanticClosure
---@return table<string, unknown> coverage record
local function semanticRootCoverage(sources, root, routeValue, closure)
  local resourceKeys = sortedSetValues(closure.resources)
  local identityParts = { root.kind, root.key, Hashing.hashLua(routeValue) }
  for _, resourceKey in ipairs(resourceKeys) do
    identityParts[#identityParts + 1] = resourceKey .. "=" .. sources.resourceCatalog[resourceKey].contentIdentity
  end
  for messageKey in pairs(closure.messages) do
    if sources.messageEntries[messageKey] ~= nil then
      identityParts[#identityParts + 1] = messageKey .. "=" .. Hashing.hashLua(sources.messageEntries[messageKey])
    end
  end
  for routeKey in pairs(closure.routes) do
    local closureRoute = sources.normalizedMessageSourceRoutes[routeKey]
      or sources.messageRoutes[routeKey]
      or sources.dynamicMessageRoutes[routeKey]
    if closureRoute ~= nil then
      identityParts[#identityParts + 1] = routeKey .. "=" .. Hashing.hashLua(closureRoute)
    end
  end
  local isMenu = root.kind == "menu-route"
  if isMenu then
    for _, fontRole in ipairs(routeValue.fontRoles) do
      identityParts[#identityParts + 1] = fontRole
        .. "="
        .. FieldFontCache.defPath(MENU_FONT_IDS[fontRole] or Sources.MENU_TEXT_FONT_ID)
    end
  end
  table.sort(identityParts)
  return {
    kind = root.kind,
    route = root.key,
    closureIdentity = Hashing.sha1hex(table.concat(identityParts, "\n")),
    resources = resourceKeys,
    operations = { root.kind },
    messageEntries = sortedSetValues(closure.messages),
    messageRoutes = sortedSetValues(closure.routes),
    fontRoles = isMenu and routeValue.fontRoles or {},
    assetRoles = isMenu and routeValue.assetRoles or {},
    assetBindings = isMenu and routeValue.assetBindings or {},
    requiredContext = isMenu and routeValue.requiredContext or {},
    programContext = root.kind == "message-route" and routeValue.programContext or nil,
  }
end

-- Closes every semantic root not yet covered into `coverage`.
---@param sources BattleSemanticClosureSources
---@param semanticRoots { kind: string, key: string, sourceRouteKey: string }[]
---@param coverage table<string, table<string, unknown>> coverage by root key, extended in place
---@return string[] failures roots whose source route is not normalized
local function closeSemanticRoots(sources, semanticRoots, coverage)
  local failures = {}
  for _, root in ipairs(semanticRoots) do
    if coverage[root.key] == nil then
      local routeValue, closure = semanticRootClosure(sources, root)
      if routeValue == nil then
        failures[#failures + 1] = root.key .. ": source semantic route is not normalized"
      else
        coverage[root.key] = semanticRootCoverage(sources, root, routeValue, closure)
      end
    end
  end
  return failures
end

---@param rootFailures string[] roots whose source route is not normalized
---@param semanticRoots { key: string }[]
---@param coverage table<string, table<string, unknown>> coverage by root key
---@return string[] blockers
local function coverageBlockers(rootFailures, semanticRoots, coverage)
  local blockers = {}
  if #rootFailures > 0 then
    blockers[#blockers + 1] = "roots: " .. #rootFailures .. " source semantic roots did not close"
    for _, failure in ipairs(rootFailures) do
      blockers[#blockers + 1] = "roots: " .. failure
    end
  end
  local uncoveredRoots = 0
  for _, root in ipairs(semanticRoots) do
    if coverage[root.key] == nil then
      uncoveredRoots = uncoveredRoots + 1
    end
  end
  if uncoveredRoots > 0 then
    blockers[#blockers + 1] = "coverage: " .. uncoveredRoots .. " semantic roots have no closure identity"
  end
  return blockers
end

---@return table[] battlefield slot geometry rows
local function battlefieldSlots()
  local slots = {}
  for index, row in ipairs(Sources.SLOT_GEOMETRY) do
    slots[index] = {
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
  return slots
end

---@return { key: string, x: integer, y: integer }[] layers menu layout layers in order
---@return table<string, integer> indices source layer index by key
local function menuLayoutLayers()
  local layers = {}
  local indices = {}
  for _, layer in ipairs(Sources.MENU_LAYOUT.layers) do
    layers[#layers + 1] = { key = layer.key, x = layer.x, y = layer.y }
    indices[layer.key] = layer.index
  end
  return layers, indices
end

-- Background-dependent lower palettes: backgrounds 0..16 read base
-- 247+b with touch 271+b; background 17 reads base 288, touch 289.
-- BattleInput_NewInit loads the base member's first sixteen colors over
-- lower palette 0, so screens drawing palette 0 vary per background.
-- Variant palettes carry what the source carries (sixteen or thirty-two
-- colors depending on the background); the manifest records the
-- association without normalizing the counts.
---@param lower Narc lower-screen archive
---@param lowerPalette { colors: table[] } shared base lower palette
---@return table<string, table<string, unknown>> lowerVariants source base/touch colors by background
---@return { background: string, palette: table<string, unknown>, touchPalette: table<string, unknown> }[] palettes effective lower palettes in background order
local function compileBackgroundLowerPalettes(lower, lowerPalette)
  local lowerVariants = {}
  local palettes = {}
  for backgroundId = 0, 17 do
    local background = Sources.BACKGROUNDS[backgroundId + 1]
    local base = decodePalette(lower, Sources.lowerBasePaletteMember(backgroundId), background .. " lower palette")
    local touch = decodePalette(lower, Sources.lowerTouchPaletteMember(backgroundId), background .. " touch palette")
    lowerVariants[background] = { base = { colors = paletteRecords(base) }, touch = { colors = paletteRecords(touch) } }
    local colors = {}
    local touchColors = {}
    for index, color in ipairs(lowerPalette.colors) do
      colors[index] = index <= 16 and base.colors[index] or color
      touchColors[index] = colors[index]
      if index >= 9 and index <= 16 then
        touchColors[index] = assert(touch.colors[index], background .. " touch palette carries color " .. index)
      end
    end
    palettes[backgroundId + 1] =
      { background = background, palette = { colors = colors }, touchPalette = { colors = touchColors } }
  end
  return lowerVariants, palettes
end

---@return string native health-box component tile bytes
local function hudComponentBytes()
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
  return componentBytes
end

-- Ten recolored printer digits plus the printer's fill tile, appended
-- after the native components on every health-box strip.
---@param romFs RomFs
---@return string digit tile bytes
local function hudDigitBytes(romFs)
  local digitSource = Sources.HUD_DIGITS
  local digitChars =
    decodeChars(openArchive(romFs, digitSource.narc, "health-box digits"), digitSource.member, "health-box digits")
  assert(digitChars.depth == 3 and #digitChars.tiles >= 10 * 32, "health-box digits are ten 4bpp tiles")
  local slotOf = { [0] = digitSource.background, digitSource.foreground, digitSource.shadow }
  local digitByteParts = {}
  for index = 1, 10 * 32 do
    local byte = string.byte(digitChars.tiles, index)
    local low = assert(slotOf[byte % 16], "health-box digit pixels use printer values 0..2")
    local high = assert(slotOf[math.floor(byte / 16)], "health-box digit pixels use printer values 0..2")
    digitByteParts[index] = string.char(high * 16 + low)
  end
  local fillByte = string.char(digitSource.background * 17)
  return table.concat(digitByteParts) .. string.rep(fillByte, 32)
end

---@param romFs RomFs
---@return table<string, { colors: table[] }> text palettes by role, truncated to their source banks
local function compileTextPalettes(romFs)
  local textPalettes = {}
  for role, source in pairs(Sources.TEXT_PALETTES) do
    local archive = openArchive(romFs, source.narc, role .. " text palette")
    local decoded = decodePalette(archive, source.member, role .. " text palette")
    local colors = {}
    for index = 1, source.banks * 16 do
      local color = decoded.colors[index]
      assert(color ~= nil, role .. " text palette carries its source banks")
      colors[index] = { r = color.r, g = color.g, b = color.b }
    end
    textPalettes[role] = { colors = colors }
  end
  return textPalettes
end

-- Decodes one source battle message bank, tokenizes every record, and
-- stages it under its semantic bank key.
---@param staging BattleGlobalStaging
---@param archive Narc battle message archive
---@param role string message bank role
---@param dependencies table<string, unknown> message-bank decode dependencies, extended in place
---@return table<string, unknown> bank decoded bank
---@return string resourceKey staged bank key
---@return { archive: string, memberId: integer, contentIdentity: string } provenance
local function stageMessageBank(staging, archive, role, dependencies)
  local memberId = Sources.MESSAGE_BANKS[role]
  local sourceBytes = must(archive:readMember(memberId), "battle message source bank is absent")
  local bank, failure =
    UiMessageBank.read(archive, memberId, "battle message role " .. role, dependencies, "battle-message-" .. role)
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
  stageCatalogResource(staging, resourceKey, {
    kind = "message",
    contentIdentity = identity,
    format = "hgss-message-bank-tokens-v1",
    geometry = { recordCount = bank.messageCount, tokenCount = tokenCount },
  }, { format = "HGSS_MSG_BANK", records = records })
  return bank, resourceKey, { archive = Sources.MENU_MESSAGE_BANK, memberId = memberId, contentIdentity = identity }
end

-- The battle message phase: staged message banks and trainer message
-- index tables, tokenized message entries, and every normalized message
-- route, placeholder, tag, and template input.
---@param romFs RomFs
---@param staging BattleGlobalStaging
---@return table<string, unknown> messages normalized message sections plus their provenance
local function compileBattleMessages(romFs, staging)
  local menuMessageArchive = openArchive(romFs, Sources.MENU_MESSAGE_BANK, "battle menu messages")
  local messageDependencies = {}
  local messageBanks = {}
  local decodedMessageBanks = {}
  local messageBankProvenance = {}
  for _, role in ipairs(sortedSetValues(Sources.MESSAGE_BANKS)) do
    decodedMessageBanks[role], messageBanks[role], messageBankProvenance[role] =
      stageMessageBank(staging, menuMessageArchive, role, messageDependencies)
  end
  local trainerTables = Sources.TRAINER_MESSAGE_TABLES
  local trainerTableProvenance = stageTrainerMessageTables(romFs, staging)
  local messageEntries, messageProvenance = tokenizeMessageEntries(decodedMessageBanks)

  local messageRoutes = {}
  for routeKey, route in pairs(Sources.MENU_MESSAGE_ROUTES) do
    messageRoutes[routeKey] = {
      inputs = route.inputs,
      template = route.template,
      templates = route.templates,
      variants = route.variants,
      branches = route.branches,
    }
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
  local normalizedMessageSourceRoutes = compileMessageSourceRoutes(messageBanks, staging.catalog)
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
    messageTagInputs[role] = { input = resolver.input, output = resolver.result, selection = resolver.selectors }
  end
  local messageTemplateInputs = {}
  for role, sourceInput in pairs(Sources.MESSAGE_TEMPLATE_INPUTS) do
    messageTemplateInputs[role] = {
      input = sourceInput.input,
      dependency = sourceInput.dependency,
      supported = sourceInput.supported,
      reason = sourceInput.reason,
    }
  end
  local transitionNameBank = decodedMessageBanks.transitionName
  local transitionNameKey = "transition/trainer-name"
  local transitionNameTokens, transitionNameTokenFailure =
    UiMessageBank.tokens(transitionNameBank, Sources.TRANSITION_MESSAGE_MEMBER, Sources.TRANSITION_MESSAGE_ID, charmap)
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
  return {
    dependencies = messageDependencies,
    banks = messageBanks,
    bankProvenance = messageBankProvenance,
    trainerTableProvenance = trainerTableProvenance,
    entries = messageEntries,
    provenance = messageProvenance,
    routes = messageRoutes,
    dynamicRoutes = dynamicMessageRoutes,
    sourceRoutes = normalizedMessageSourceRoutes,
    placeholderBanks = placeholderBanks,
    placeholderSchemas = placeholderSchemas,
    tagSchemas = messageTagSchemas,
    tagInputs = messageTagInputs,
    templateInputs = messageTemplateInputs,
    transitionNameKey = transitionNameKey,
    transitionMessageProvenance = {
      archive = Sources.MENU_MESSAGE_BANK,
      memberId = Sources.TRANSITION_MESSAGE_MEMBER,
      messageId = Sources.TRANSITION_MESSAGE_ID,
    },
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
    local componentBytes = hudComponentBytes()
    local digitBytes = hudDigitBytes(romFs)
    local lowerObjPalette = decodePalette(sceneArchive, ROLES.lowerObjPalette, "lower OBJ palette")
    checkColorCount(lowerObjPalette, 112, "lower OBJ palette")
    local images = {}
    local resourcePayloads = {}
    local resourceCatalog = {}
    ---@type BattleGlobalStaging
    local staging = { catalog = resourceCatalog, payloads = resourcePayloads }
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
    local lowerVariants, backgroundLowerPalettes = compileBackgroundLowerPalettes(lower, lowerPalette)
    -- Background variants share one staged image per distinct raster, so
    -- the backdrop every menu composes is staged once per background.
    local stagedVariants = {}
    local pulsePalette = { colors = {} }
    for index = 1, #lowerPalette.colors do
      pulsePalette.colors[index] = index == 2 and { r = 255, g = 255, b = 255 } or { r = 0, g = 0, b = 0 }
    end
    local pulseScreen = decodeScreen(lower, Sources.MENU_PULSE_SCREEN, "battle menu pulse mask")
    local pulseMaskRaster = G2dRasterizer.renderScreen(lowerChars, pulsePalette, pulseScreen, {
      asset = Sources.LOWER_NARC,
      role = "battle menu palette-entry pulse mask",
    })
    local pulseMaskRows = {}
    for offset = 1, #pulseMaskRaster.pixels, 4 do
      local red, green, blue = string.byte(pulseMaskRaster.pixels, offset, offset + 2)
      pulseMaskRows[#pulseMaskRows + 1] = red == 255 and green == 255 and blue == 255 and "\255\255\255\255"
        or "\0\0\0\0"
    end
    stageSlice("menu-pulse-mask", table.concat(pulseMaskRows), pulseMaskRaster.width, pulseMaskRaster.height)
    local pulseMaskPath = BattlePresentationCache.globalImagePath("menu-pulse-mask")
    ---@param name string staged base slice name
    ---@param screen { width: integer, height: integer, entries: table[] } decoded lower screen
    ---@param label string diagnostic role label
    ---@param baseRaster { pixels: string } raster under the shared base palette
    ---@return table<string, string>? background-keyed base image paths, nil when no background changes the raster
    ---@return table<string, string>? background-keyed touch image paths, nil when touch colors change no pixels
    local function backgroundVariants(name, screen, label, baseRaster)
      local backgrounds = nil
      local touchBackgrounds = nil
      for _, variant in ipairs(backgroundLowerPalettes) do
        local raster = G2dRasterizer.renderScreen(lowerChars, variant.palette, screen, {
          asset = Sources.LOWER_NARC,
          role = label .. " " .. variant.background .. " variant",
        })
        if raster.pixels ~= baseRaster.pixels then
          local path = stagedVariants[raster.pixels]
          if path == nil then
            local variantName = name .. "-" .. variant.background:gsub("_", "-")
            stageSlice(variantName, raster.pixels, raster.width, raster.height)
            path = BattlePresentationCache.globalImagePath(variantName)
            stagedVariants[raster.pixels] = path
          end
          backgrounds = backgrounds or {}
          backgrounds[variant.background] = path
        end
        local touchRaster = G2dRasterizer.renderScreen(lowerChars, variant.touchPalette, screen, {
          asset = Sources.LOWER_NARC,
          role = label .. " " .. variant.background .. " touch variant",
        })
        if touchRaster.pixels ~= baseRaster.pixels then
          local touchPath = stagedVariants[touchRaster.pixels]
          if touchPath == nil then
            local variantName = name .. "-touch-" .. variant.background:gsub("_", "-")
            stageSlice(variantName, touchRaster.pixels, touchRaster.width, touchRaster.height)
            touchPath = BattlePresentationCache.globalImagePath(variantName)
            stagedVariants[touchRaster.pixels] = touchPath
          end
          touchBackgrounds = touchBackgrounds or {}
          touchBackgrounds[variant.background] = touchPath
        end
      end
      return backgrounds, touchBackgrounds
    end
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
        local tilemapBytes = must(lower:readMember(memberId), "menu tilemap source member is absent")
        local format, geometry = describeScreen(screen)
        stageCatalogResource(staging, tilemapKey, {
          kind = "map",
          contentIdentity = Hashing.sha1hex(tilemapBytes),
          format = format,
          geometry = geometry,
        }, screen)
        menuTilemapProvenance[tilemapKey] = { archive = Sources.LOWER_NARC, memberId = memberId }
        local backgrounds, touchBackgrounds = backgroundVariants(name, screen, label .. " screen " .. index, raster)
        local entry = {
          image = BattlePresentationCache.globalImagePath(name),
          width = raster.width,
          height = raster.height,
          tilemapKey = tilemapKey,
          plane = planes[index],
          template = templates[index],
          priority = priorities[index],
          backgrounds = backgrounds,
          touchBackgrounds = touchBackgrounds,
          pulse = memberId == Sources.MENU_PULSE_SCREEN,
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
    -- Each composition pins its sBattleMenuTemplates screen buffer ids and
    -- per-plane priorities; the fourth plane stays unused.
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
    -- Move buttons by slot: the occupied button re-rendered with each type
    -- palette in its bank (normal and pressed tilemaps), and the blank
    -- button an empty slot shows.
    do
      local buttonSource = Sources.MOVE_BUTTONS
      local typePalettes = compileMoveTypePalettes(romFs)
      local screen = decodeScreen(lower, ROLES.fightScreens[1], "fight screen 1")
      local feedback = Sources.MENU_FEEDBACK.moves
      local typeButtons = {}
      local function paletteWithBank(bank, colors)
        local merged = {}
        for index, color in ipairs(lowerPalette.colors) do
          merged[index] = color
        end
        for index = 1, 16 do
          merged[bank * 16 + index] = colors[index]
        end
        return { colors = merged }
      end
      for slot = 0, 3 do
        local button = feedback.buttons[slot + 1]
        assert(button.id == "move:" .. slot, "fight feedback lists the move buttons in slot order")
        local bank = buttonSource.firstBank + slot
        local types = {}
        for typeKey, palette in pairs(typePalettes) do
          local states = {}
          for state, offset in pairs({ normal = 0, pressed = feedback.states.pressed }) do
            local patch = BattlePresentationCompiler.compileMenuFeedbackPatch(
              lowerChars,
              paletteWithBank(bank, palette.colors),
              screen,
              { left = button.left, top = button.top, right = button.right, bottom = button.bottom, offset = offset }
            )
            local name = "menu-fight-move-" .. slot .. "-" .. typeKey .. "-" .. state
            stageSlice(name, patch.pixels, patch.width, patch.height)
            states[state] = BattlePresentationCache.globalImagePath(name)
          end
          types[typeKey] = states
        end
        local empty = buttonSource.empty[slot + 1]
        local blankBank = {}
        for index = 1, 16 do
          blankBank[index] = lowerPalette.colors[buttonSource.emptyBank * 16 + index]
        end
        local blank =
          BattlePresentationCompiler.compileMenuFeedbackPatch(lowerChars, paletteWithBank(bank, blankBank), screen, {
            left = empty.left,
            top = empty.top,
            right = empty.right,
            bottom = empty.bottom,
            offset = empty.offset,
            crop = button,
          })
        local emptyName = "menu-fight-move-" .. slot .. "-empty"
        stageSlice(emptyName, blank.pixels, blank.width, blank.height)
        typeButtons[slot + 1] = {
          x = button.left * 8,
          y = button.top * 8,
          width = blank.width,
          height = blank.height,
          types = types,
          empty = BattlePresentationCache.globalImagePath(emptyName),
        }
      end
      moves.screens[1].moveButtons = typeButtons
    end
    local target = compileMenu(ROLES.targetScreens, {
      "menu-target-1",
      "menu-target-2",
      "menu-target-3",
    }, "target", { 4, 5, 0 }, { 2, 1, 3 }, Sources.MENU_PLANES.target, "target")
    local twoOption = compileMenu(ROLES.twoOptionScreens, {
      "menu-two-option-1",
      "menu-two-option-2",
    }, "two-option", { 6, 0 }, { 2, 3 }, Sources.MENU_PLANES.twoOption, "twoOption")
    -- Single-battle sprites: HUD boxes through the HUD palette, the arrow
    -- and party gauges through the lower OBJ palette. Associations are
    -- never swapped.
    local function compileSprite(triple, name, label, animIndex, includeHudComponents)
      local charTiles = triple.chars.tiles
      local componentBase = nil
      local digitBase = nil
      if includeHudComponents then
        assert(triple.chars.depth == 3, "native health-box components use 4bpp characters")
        componentBase = #charTiles / 32
        digitBase = componentBase + Sources.HUD_COMPONENTS.tileCount
        charTiles = charTiles .. componentBytes .. digitBytes
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
        digitBase = digitBase,
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
    local cursorPalette = decodePalette(sceneArchive, ROLES.cursorPalette, "keypad cursor palette")
    checkColorCount(cursorPalette, 16, "keypad cursor palette")
    local cursorTriple = decodeTriple(sceneArchive, ROLES.cursor, cursorPalette, "keypad cursor")
    if #cursorTriple.anims < 4 then
      error(
        Errors.new("BATTLE_SOURCE_UNEXPECTED", "keypad cursor has fewer than four corner animations", {
          animations = #cursorTriple.anims,
        }),
        0
      )
    end
    local cursor = compileSprite(cursorTriple, "cursor-chars", "keypad cursor", 1)
    cursor.animations = {}
    for index, animation in ipairs(cursorTriple.anims) do
      cursor.animations[index] = summarizeAnimation(animation)
    end
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
    local textPalettes = compileTextPalettes(romFs)
    local messages = compileBattleMessages(romFs, staging)
    local messageEntries = messages.entries
    local messageRoutes = messages.routes
    local dynamicMessageRoutes = messages.dynamicRoutes
    local normalizedMessageSourceRoutes = messages.sourceRoutes

    local menuModeRules = {}
    for mode, rule in pairs(Sources.MENU_MODE_RULES) do
      local labels = {}
      for slot, key in pairs(rule.labels) do
        labels[slot] = key
      end
      menuModeRules[mode] = { labels = labels, dynamicFields = copyStrings(rule.dynamicFields) }
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
      if CATALOG_RESOURCE_CODECS[source.kind] == nil then
        error(
          Errors.new("BATTLE_RESOURCE_KIND_UNKNOWN", "menu layout resource has no decoder", {
            resource = resourceKey,
            kind = source.kind,
          }),
          0
        )
      end
      local decoded, format, geometry = decodeCatalogResource(archive, source.memberId, source.kind, label)
      stageCatalogResource(staging, resourceKey, {
        kind = source.kind,
        contentIdentity = Hashing.sha1hex(bytes),
        format = format,
        geometry = geometry,
      }, decoded)
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
      menuSelectors[routeKey] =
        { screenGroup = route.screenGroup, textSet = route.textSet, mode = route.mode, phase = route.phase }
      menuSelectorProvenance[routeKey] = route.sourceSelector
    end
    local menuRuntimeContexts = {}
    for contextKey, route in pairs(Sources.MENU_RUNTIME_CONTEXTS) do
      menuRuntimeContexts[contextKey] =
        { inputs = copyStrings(route.inputs), assetRoles = copyStrings(route.assetRoles) }
    end
    local menuContexts = {}
    for key, sourceContext in pairs(Sources.MENU_CONTEXTS) do
      menuContexts[key] = copyMenuContext(sourceContext)
    end
    menuContexts.frontier.input = "frontierBattle"
    local menuTextSets = compileMenuTextSets()
    local menuRoutes = {}
    for routeKey, route in pairs(Sources.MENU_ROUTES) do
      local textSet = assert(menuTextSets[route.textSet], "menu text set is source-defined")
      menuRoutes[routeKey] = normalizeMenuRoute(route, textSet, menuLayouts, resourceCatalog)
    end

    local transition = compileTransitionResources(romFs, staging)
    local transitionMessageRoutes =
      compileTransitionMessageRoutes(messages.transitionNameKey, transition.sourceResources)
    local transitionInternalResources = compileTransitionInternalResources(transition.sourceResources)
    local transitionRoutes = compileTransitionRoutes(transition.sourceResources)
    local transitionSelection = compileTransitionSelection()
    local transitionCatalogKeys = sortedSetValues(transition.keySet)
    local transitionCoverage = transitionRouteCoverage(transitionRoutes, resourceCatalog, messageEntries)

    local audioCompiler = require("romdump.src.digest.audio.AudioCompiler")
    local audioPlan, audioPlanError = audioCompiler.planSource(romFs)
    local introMusic = compileIntroMusic(romFs, audioPlan, audioPlanError)

    local sourceMessageRouteKeys = {}
    for sourceName, sourceRoute in pairs(Sources.MESSAGE_SOURCE_ROUTES) do
      sourceMessageRouteKeys[sourceName] = sourceRoute.key
    end
    local semanticRoots = Sources.listSemanticRoots()
    local rootFailures = closeSemanticRoots({
      resourceCatalog = resourceCatalog,
      messageEntries = messageEntries,
      messageRoutes = messageRoutes,
      dynamicMessageRoutes = dynamicMessageRoutes,
      normalizedMessageSourceRoutes = normalizedMessageSourceRoutes,
      sourceMessageRouteKeys = sourceMessageRouteKeys,
      menuRoutes = menuRoutes,
      transitionMessageRoutes = transitionMessageRoutes,
      transitionRoutes = transitionRoutes,
    }, semanticRoots, transitionCoverage)

    local transitionSelectorFamilies = {}
    for selector, family in pairs(Sources.TRANSITION_SELECTOR_FAMILIES) do
      transitionSelectorFamilies[selector] = family
    end

    local imageManifest = {}
    for name, image in pairs(images) do
      imageManifest[BattlePresentationCache.globalImagePath(name)] = { width = image.width, height = image.height }
    end
    local menuLayers, menuLayerIndices = menuLayoutLayers()
    local partialManifest = {
      schema = BattlePresentationSchema.MANIFEST_SCHEMA,
      version = { id = versionId, language = assert(MonSources.versionLanguages[versionId]) },
      catalogIdentity = versionId .. ":" .. romFs:metadata().sha1,
      -- Only a fully compiled bundle proves its dump-backed roles: the
      -- incomplete-job gate below never stages a partial manifest, so a
      -- staged manifest always carries its verification.
      verified = true,
      scenes = BattlePresentationCache.sceneInventory(),
      battlefield = { slots = battlefieldSlots() },
      layouts = {
        menu = {
          width = Sources.MENU_LAYOUT.width,
          height = Sources.MENU_LAYOUT.height,
          tilemapWidth = Sources.MENU_LAYOUT.tilemapWidth,
          tilemapHeight = Sources.MENU_LAYOUT.tilemapHeight,
          layers = menuLayers,
        },
      },
      hud = {
        player = playerHud,
        enemy = enemyHud,
        doubles = doublesHud,
        arrow = arrow,
        cursor = cursor,
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
          cursor = "hud/cursor",
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
          pulseMask = pulseMaskPath,
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
          narration = { font = narrationFont, palette = textPalettes.narration },
          trainerNarration = { font = narrationFont, palette = textPalettes.narration },
          hud = { font = FieldFontCache.defPath(Sources.HUD_MESSAGE_FONT_ID), palette = textPalettes.hud },
          menu = { font = FieldFontCache.defPath(Sources.MENU_TEXT_FONT_ID), palette = textPalettes.menu },
          bugContest = { font = FieldFontCache.defPath(Sources.BUG_CONTEST_FONT_ID) },
          recorderFeedback = { font = FieldFontCache.defPath(Sources.RECORDER_FEEDBACK_FONT_ID) },
        },
        entries = messageEntries,
        routes = messageRoutes,
        banks = messages.banks,
        dynamicRoutes = dynamicMessageRoutes,
        placeholderBanks = messages.placeholderBanks,
        sourceRoutes = normalizedMessageSourceRoutes,
        placeholders = messages.placeholderSchemas,
        tagSchemas = messages.tagSchemas,
        tagInputs = messages.tagInputs,
        templateInputs = messages.templateInputs,
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
        resourceSets = transition.resourceSets,
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
    local blockers = coverageBlockers(rootFailures, semanticRoots, transitionCoverage)
    local provenance = {
      source = Sources.provenance,
      rom = { version = versionId, sha1 = romFs:metadata().sha1 },
      roles = provenanceRoles(),
      menuSelectors = menuSelectorProvenance,
      menuMessageIds = messages.provenance,
      messageBanks = messages.bankProvenance,
      messageSourceResources = Sources.MESSAGE_SOURCE_ROUTES,
      trainerMessageTables = messages.trainerTableProvenance,
      recorderFeedbackFlags = Sources.RECORDER_FEEDBACK_SOURCE_FLAGS,
      recorderFeedbackUnreachableFlags = Sources.RECORDER_FEEDBACK_UNREACHABLE_FLAGS,
      frontierTrainerMessageRoute = Sources.FRONTIER_TRAINER_MESSAGE_ROUTE,
      transitionMessage = messages.transitionMessageProvenance,
      transitionMessageRoutes = Sources.TRANSITION_MESSAGE_SOURCE_ROUTES,
      messageDependencies = messages.dependencies,
      transitionResources = transition.provenance,
      transitionSelectorFamilies = transitionSelectorFamilies,
      transitionSelectorRoutes = Sources.TRANSITION_SELECTOR_ROUTES,
      transitionPreselection = Sources.TRANSITION_PRESELECTION,
      transitionSourceResources = transition.sourceResources,
      transitionResourceMembers = transition.resourceMembers,
      transitionParticleMembers = transition.particleMembers,
      embeddedParticleResources = transition.embeddedParticleResources,
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
    return nil, structuredFailure(bundle)
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

-- Mutable staging owned by one compileEffect call: the resolved semantic
-- resources and their payloads, the recorded source inputs, opened
-- archives, managed-sprite bookkeeping, and decoded particle archives.
---@class BattleEffectStaging
---@field romFs RomFs
---@field effectKey string
---@field sources table<string, unknown> BattleAnimationSources
---@field resolvedResources table<string, { kind: string, contentIdentity: string, payload: string }>
---@field resourcePayloads table<string, unknown>
---@field sourceInputs table[]
---@field resolvedSourceInputs table[]
---@field archives table<string, Narc>
---@field managedSpriteResources table<integer, table<string, table<integer, string>>>
---@field managedSpriteCapacities table<integer, { multiCell: boolean, multiAnimation: boolean }>
---@field pendingCharacterRasters table<string, table<string, unknown>>
---@field particleByBattler table<integer, string>
---@field decodedParticleResources table<string, { bytes: string, decoded: NitroSplData, source: table<string, unknown> }>

---@param state BattleEffectStaging
---@param role string source input role
---@param operands integer[] source operands
---@param message string failure message
---@return Errors.Error unresolved source-input failure
local function sourceInputError(state, role, operands, message)
  return Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", message, {
    effectKey = state.effectKey,
    provenance = { role = role, operands = operands },
  })
end

---@param state BattleEffectStaging
---@param role string source input role
---@param operands integer[] source operands
---@param selections table<string, table<string, unknown>> physical source selections by slot
---@param normalized table<string, unknown> semantic resolution record
local function recordSourceInput(state, role, operands, selections, normalized)
  state.sourceInputs[#state.sourceInputs + 1] = { role = role, operands = operands, selections = selections }
  state.resolvedSourceInputs[#state.resolvedSourceInputs + 1] = normalized
end

---@param state BattleEffectStaging
---@param archiveSymbol string
---@param label string diagnostic role
---@return Narc archive opened once per effect
local function effectArchive(state, archiveSymbol, label)
  local archive = state.archives[archiveSymbol]
  if archive == nil then
    archive = openArchive(state.romFs, archiveSymbol, label)
    state.archives[archiveSymbol] = archive
  end
  return archive
end

-- Stages one content-addressed effect resource. Re-staging the same key
-- must carry the same kind, identity, and payload.
---@param state BattleEffectStaging
---@param resourceKey string semantic resource key
---@param kind string resource kind
---@param contentIdentity string SHA-1 content identity
---@param payload unknown decoded payload
local function addEffectResource(state, resourceKey, kind, contentIdentity, payload)
  assert(type(resourceKey) == "string" and resourceKey ~= "", "effect resources use semantic keys")
  assert(type(contentIdentity) == "string" and #contentIdentity == 40, "effect resources use SHA-1 identities")
  local payloadPath = BattlePresentationCache.globalResourcePath("effect/content/" .. contentIdentity)
  local previous = state.resolvedResources[resourceKey]
  if previous ~= nil then
    assert(
      previous.kind == kind and previous.contentIdentity == contentIdentity,
      "semantic resource identity is stable"
    )
    assert(
      Hashing.hashLua(state.resourcePayloads[previous.payload]) == Hashing.hashLua(payload),
      "equal resources share payloads"
    )
    return
  end
  state.resolvedResources[resourceKey] = { kind = kind, contentIdentity = contentIdentity, payload = payloadPath }
  state.resourcePayloads[payloadPath] = payload
end

-- Stages one particle texture/palette pair as an exact drawable plus
-- decoded colors, returning their semantic resource keys. Shared
-- sources collapse onto one staged drawable through content identity.
---@param state BattleEffectStaging
---@param textureBytes string|nil raw 8-bit indexed texels when embedded
---@param paletteBytes string|nil raw RGB555 pairs when embedded
---@param textureFlags integer source resource flags word
---@param provenance table<string, unknown> source coordinates for failures
---@return { textureKey: string|nil, paletteKey: string|nil } staged semantic resource keys
local function stageParticleTexture(state, textureBytes, paletteBytes, textureFlags, provenance)
  local textureKey, paletteKey = nil, nil
  local colors = nil
  if paletteBytes ~= nil then
    colors = decodeParticlePalette(paletteBytes, provenance)
    local paletteIdentity = Hashing.sha1hex(paletteBytes)
    paletteKey = "battle/particle/palette/" .. paletteIdentity
    addEffectResource(state, paletteKey, "palette", paletteIdentity, { colors = colors })
  end
  if textureBytes ~= nil then
    local paletteColors = colors ~= nil and #colors or 0
    local width, height, bits = particleTextureDimensions(textureBytes, textureFlags, paletteColors, provenance)
    local rgba = decodeParticleRgba(textureBytes, width, height, bits, colors or {})
    local textureIdentity = Hashing.sha1hex(textureBytes)
    textureKey = "battle/particle/texture/" .. textureIdentity
    addEffectResource(state, textureKey, "texture", textureIdentity, {
      width = width,
      height = height,
      rgba8888 = rgba,
    })
  end
  return { textureKey = textureKey, paletteKey = paletteKey }
end

-- Stages every resource of one decoded particle archive exactly once,
-- resolving shared texture references onto their staged drawable.
---@param state BattleEffectStaging
---@param decoded NitroSplData decoded particle archive under staging
---@param provenance table<string, unknown> source coordinates for failures
---@return { textureKey: string|nil, paletteKey: string|nil }[] staged entries in source order
local function stageParticleArchiveResources(state, decoded, provenance)
  local entries = {}
  for resourceIndex, resource in ipairs(decoded.resources) do
    local textureKey, paletteKey = nil, nil
    if resource.textureReference ~= nil then
      local referenced = entries[resource.textureReference + 1]
      if referenced == nil or referenced.textureKey == nil then
        error(
          Errors.new("BATTLE_EFFECT_CLOSURE_UNRESOLVED", "particle texture reference has no staged payload", {
            effectKey = state.effectKey,
            resourceIndex = resourceIndex - 1,
            textureReference = resource.textureReference,
          }),
          0
        )
      end
      textureKey = referenced.textureKey
      paletteKey = stageParticleTexture(state, nil, resource.palette, resource.flags, provenance).paletteKey
    else
      local staged = stageParticleTexture(state, resource.texture, resource.palette, resource.flags, provenance)
      textureKey, paletteKey = staged.textureKey, staged.paletteKey
    end
    entries[resourceIndex] = { textureKey = textureKey, paletteKey = paletteKey }
  end
  return entries
end

---@param data string little-endian 32-bit words
---@return integer[] words in source order
local function u32leWords(data)
  local words = {}
  for offset = 1, #data, 4 do
    words[#words + 1] = string.byte(data, offset)
      + string.byte(data, offset + 1) * 256
      + string.byte(data, offset + 2) * 65536
      + string.byte(data, offset + 3) * 16777216
  end
  return words
end

-- The emitter's present section/calculation roles, each named once.
---@param emitter NitroSplEmitter
---@return string[] sorted feature roles
local function particleEmitterFeatures(emitter)
  local seen = {}
  local features = {}
  for _, group in ipairs({ emitter.sections, emitter.calculations }) do
    for _, entry in ipairs(group) do
      if seen[entry.role] == nil then
        seen[entry.role] = true
        features[#features + 1] = entry.role
      end
    end
  end
  table.sort(features)
  return features
end

-- The texture slot an emitter draws: its texture section's selector when
-- in range, otherwise its own ordinal clamped to the archive resources.
---@param emitter NitroSplEmitter
---@param entryCount integer staged archive resource count
---@param emitterIndex integer zero-based emitter ordinal
---@return integer|nil zero-based texture slot, nil when the archive stages no resources
local function particleEmitterTextureSlot(emitter, entryCount, emitterIndex)
  if entryCount == 0 then
    return nil
  end
  for _, section in ipairs(emitter.sections) do
    if section.role == "texture" then
      local selected = string.byte(section.data, 1)
      return selected < entryCount and selected or math.min(emitterIndex, entryCount - 1)
    end
  end
  return math.min(emitterIndex, entryCount - 1)
end

-- Normalizes one raw emitter into source-independent typed state: the
-- active source behaviors, the inline parameter bits, the base control
-- values, one word vector per present section/calculation, and the
-- resolved drawable its sprites draw. Unknown flags words fail.
---@param effectKey string effect under compilation
---@param emitter NitroSplEmitter raw emitter under normalizing
---@param entries { textureKey: string|nil, paletteKey: string|nil }[] staged archive resources
---@param emitterIndex integer zero-based emitter ordinal behind texture selection
---@param provenance table<string, unknown> source coordinates for failures
---@return table<string, unknown> normalized emitter record
local function normalizeParticleEmitter(effectKey, emitter, entries, emitterIndex, provenance)
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
  local params = {}
  for offset = 5, #emitter.baseRecord, 2 do
    params[#params + 1] = string.byte(emitter.baseRecord, offset) + string.byte(emitter.baseRecord, offset + 1) * 256
  end
  local record = {
    features = particleEmitterFeatures(emitter),
    variant = clearParticleSelectorBits(emitter.flags),
    params = params,
  }
  for _, group in ipairs({ emitter.sections, emitter.calculations }) do
    for _, entry in ipairs(group) do
      if record[entry.role] == nil then
        record[entry.role] = u32leWords(entry.data)
      end
    end
  end
  local slot = particleEmitterTextureSlot(emitter, #entries, emitterIndex)
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

---@param state BattleEffectStaging
---@param role string source input role
---@param operands integer[] manager index, unused, then six capacities
---@return table<string, unknown> empty resolution
local function resolveManagerCapacities(state, role, operands)
  if #operands ~= 8 then
    error(sourceInputError(state, role, operands, "sprite manager capacity frame is invalid"), 0)
  end
  local managerIndex = operands[1]
  local capacities = {}
  for index = 3, 8 do
    local capacity = operands[index]
    if type(capacity) ~= "number" or capacity < 0 or capacity > 0x7fffffff or capacity % 1 ~= 0 then
      error(
        Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "sprite manager capacity is invalid", {
          effectKey = state.effectKey,
          provenance = { role = role, operands = operands, capacityIndex = index },
        }),
        0
      )
    end
    capacities[index - 2] = capacity
  end
  if state.managedSpriteCapacities[managerIndex] ~= nil then
    error(sourceInputError(state, role, operands, "sprite manager slot is initialized more than once"), 0)
  end
  local hasMultiResourceManagers = capacities[5] > 0 and capacities[6] > 0
  state.managedSpriteCapacities[managerIndex] = {
    multiCell = hasMultiResourceManagers,
    multiAnimation = hasMultiResourceManagers,
  }
  recordSourceInput(state, role, operands, {}, {
    role = role,
    managerIndex = managerIndex,
    multiCellEnabled = hasMultiResourceManagers,
    multiAnimationEnabled = hasMultiResourceManagers,
  })
  return {}
end

---@param state BattleEffectStaging
---@param role string source input role
---@param operands integer[] manager index
---@return table<string, unknown> empty resolution
local function resolveManagerDisposal(state, role, operands)
  if #operands ~= 1 then
    error(sourceInputError(state, role, operands, "sprite manager disposal frame is invalid"), 0)
  end
  state.managedSpriteCapacities[operands[1]] = nil
  state.managedSpriteResources[operands[1]] = nil
  recordSourceInput(state, role, operands, {}, { role = role, managerIndex = operands[1], disposed = true })
  return {}
end

-- Reads and decodes one battler particle archive member, failing as an
-- unavailable source when the member is absent.
---@param state BattleEffectStaging
---@param role string source input role
---@param operands integer[] source operands
---@param source { archiveSymbol: string, memberId: integer } selected particle source
---@param memberId integer selected member
---@return string bytes, NitroSplData decoded
local function decodeBattlerParticle(state, role, operands, source, memberId)
  local particleArchive = effectArchive(state, source.archiveSymbol, "animation battler particle")
  local bytes, readErr = particleArchive:readMember(memberId)
  if bytes == nil then
    error(
      Errors.new("BATTLE_EFFECT_SOURCE_UNAVAILABLE", "selected battler particle member is absent", {
        effectKey = state.effectKey,
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
  local decoded, decodeErr = Spl.decode(bytes, { effectKey = state.effectKey, role = role })
  if decoded == nil then
    error(decodeErr, 0)
  end
  return bytes, decoded --[[@as NitroSplData]]
end

---@param state BattleEffectStaging
---@param role string source input role
---@param operands integer[] battler then particle member operands
---@return table<string, unknown> resolution carrying the selected particle resource key
local function resolveBattlerParticleResource(state, role, operands)
  local sources = state.sources
  local selection, _ = sources.resolveSourceSelection(role, operands)
  local definition = assert(sources.sourceInput(51), "opcode 51 has producer source metadata")
  if #operands ~= definition.operandCount then
    error(
      Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "battler particle resource has no typed source", {
        effectKey = state.effectKey,
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
    error(sourceInputError(state, role, operands, "battler particle source has no APS decoder"), 0)
  end
  local particleKey = selection and selection.resourceKeys and selection.resourceKeys.particle
    or sources.resolveParticleResource(memberId)
  local particle = particleKey ~= nil and state.decodedParticleResources[particleKey] or nil
  if particle == nil then
    local bytes, decoded = decodeBattlerParticle(state, role, operands, source, memberId)
    particleKey = particleKey or ("battle/particle/content/" .. Hashing.sha1hex(bytes))
    selection = {
      resourceKeys = { particle = particleKey },
      sourceSelections = { particle = source },
    }
    state.decodedParticleResources[particleKey] = { bytes = bytes, decoded = decoded, source = source }
  end
  state.particleByBattler[operands[1]] = selection.resourceKeys.particle
  local selections = {
    particle = { archiveSymbol = source.archiveSymbol, memberId = source.memberId, decoder = source.decoder },
  }
  recordSourceInput(state, role, operands, selections, { role = role, resourceKeys = selection.resourceKeys })
  return { resourceKeys = selection.resourceKeys }
end

-- The staged resource a managed-sprite slot identity selects. Optional
-- MCEL/MANM slots resolve to nil when no bytecode handler loaded them.
---@param state BattleEffectStaging
---@param role string source input role
---@param operands integer[] source operands; the first selects the manager
---@param slot string managed resource slot
---@param identity integer typed resource identity within the manager
---@param subject string failure subject ("configured sprite" or "managed sprite")
---@return string|nil resourceKey
local function managedSpriteResourceKey(state, role, operands, slot, identity, subject)
  local manager = state.managedSpriteResources[operands[1]]
  local resources = manager and manager[slot]
  local resourceKey = resources and resources[identity]
  local optional = slot == "multiCell" or slot == "multiAnimation"
  if resourceKey == nil and not (optional and resources == nil) then
    error(
      Errors.new(
        "BATTLE_EFFECT_SOURCE_UNRESOLVED",
        subject .. " resource identity has no prior source-selected payload",
        {
          effectKey = state.effectKey,
          reason = "the selected manager has no decoded resource with this typed identity",
          provenance = { role = role, operands = operands, slot = slot },
        }
      ),
      0
    )
  end
  return resourceKey
end

---@param state BattleEffectStaging
---@param role string source input role
---@param operands integer[] source operands
---@return table<string, unknown> resolution with the configured sprite's resources and task
local function resolveConfiguredSpriteAction(state, role, operands)
  local sources = state.sources
  local selection, selectionErr = sources.resolveSourceSelection(role, operands)
  if selection == nil then
    error(
      Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "configured sprite action is not source-resolved", {
        effectKey = state.effectKey,
        reason = selectionErr,
        provenance = { role = role, operands = operands },
      }),
      0
    )
  end
  local definition = assert(sources.sourceInput(78), "opcode 78 has source operand metadata")
  local capacities = state.managedSpriteCapacities[operands[1]]
  if capacities == nil then
    error(sourceInputError(state, role, operands, "configured sprite manager has no active capacity record"), 0)
  end
  local resourceKeys = {}
  for _, slot in ipairs(definition.resourceSlots) do
    if capacities[slot] ~= false then
      local operandIndex = assert(definition.resourceOperands[slot], "configured sprite slot has an operand")
      resourceKeys[slot] =
        managedSpriteResourceKey(state, role, operands, slot, operands[operandIndex], "configured sprite")
    end
  end
  recordSourceInput(state, role, operands, {}, {
    role = role,
    resourceKeys = resourceKeys,
    taskKind = selection.taskKind,
    context = selection.context,
    parameters = selection.parameters,
  })
  return {
    resourceKeys = resourceKeys,
    taskKind = selection.taskKind,
    context = selection.context,
    parameters = selection.parameters,
  }
end

local MANAGED_SPRITE_TEMPLATE_SLOTS = { "character", "palette", "cell", "animation", "multiCell", "multiAnimation" }

---@param state BattleEffectStaging
---@param role string source input role
---@param operands integer[] manager, unused, then six resource identities
---@return table<string, unknown> resolution with the template's resources
local function resolveManagedSpriteTemplate(state, role, operands)
  if #operands ~= 8 then
    error(sourceInputError(state, role, operands, "managed sprite resource reference shape is invalid"), 0)
  end
  local resourceKeys = {}
  for index, slot in ipairs(MANAGED_SPRITE_TEMPLATE_SLOTS) do
    local reference = operands[index + 2]
    -- Nitro's signed -1 resource ID means this sprite has no MCEL/MANM.
    if not (index > 4 and reference == 0xffffffff) then
      resourceKeys[slot] = managedSpriteResourceKey(state, role, operands, slot, reference, "managed sprite")
    end
  end
  recordSourceInput(state, role, operands, {}, { role = role, resourceKeys = resourceKeys })
  return { resourceKeys = resourceKeys }
end

-- Stages one selected APS emitter as a content-addressed emitter resource.
---@param state BattleEffectStaging
---@param role string source input role
---@param operands integer[] source operands
---@param particleKey string selected particle archive key
---@param particle { decoded: NitroSplData, source: table<string, unknown> } decoded particle archive
---@param emitterOrdinal unknown zero-based emitter ordinal from the source plan
---@param caseKey string selection case behind the emitter
---@return string resourceKey staged emitter key
local function stageActionEmitter(state, role, operands, particleKey, particle, emitterOrdinal, caseKey)
  if type(emitterOrdinal) ~= "number" or emitterOrdinal < 0 or emitterOrdinal % 1 ~= 0 then
    error(
      Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "particle emitter ordinal is invalid", {
        effectKey = state.effectKey,
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
        effectKey = state.effectKey,
        provenance = { role = role, operands = operands, case = caseKey },
        resourceKey = particleKey,
      }),
      0
    )
  end
  local provenance = { archiveSymbol = particle.source.archiveSymbol, memberId = particle.source.memberId }
  local entries = stageParticleArchiveResources(state, particle.decoded, provenance)
  local stagedEmitter = normalizeParticleEmitter(state.effectKey, emitter, entries, emitterOrdinal, provenance)
  local contentIdentity = Hashing.hashLua(stagedEmitter)
  local resourceKey = "battle/particle-emitter/" .. contentIdentity
  addEffectResource(state, resourceKey, "particle-emitter", contentIdentity, stagedEmitter)
  return resourceKey
end

---@param state BattleEffectStaging
---@param role string source input role
---@param operands integer[] battler first
---@param selection table<string, unknown> source selection plan
---@return table<string, unknown> resolution with the action profile and emitter resources
local function resolveParticleAction(state, role, operands, selection)
  local normalized = {
    role = role,
    actionProfile = selection.actionProfile,
    callbackCases = selection.callbackCases,
    resourceCases = selection.resourceCases,
    runtimeSelection = selection.runtimeSelection,
    taskKind = selection.taskKind,
  }
  if type(selection.actionProfile) ~= "string" then
    error(sourceInputError(state, role, operands, "battler particle action has no semantic profile"), 0)
  end
  local emitterSelections = selection.sourceEmitterSelections
  if emitterSelections ~= nil then
    local particleKey = state.particleByBattler[operands[1]]
    local particle = particleKey ~= nil and state.decodedParticleResources[particleKey] or nil
    if particle == nil then
      error(sourceInputError(state, role, operands, "particle action has no earlier APS selection for its battler"), 0)
    end
    if emitterSelections.resource ~= nil then
      normalized.resource =
        stageActionEmitter(state, role, operands, particleKey, particle, emitterSelections.resource, "fixed")
    else
      normalized.resourceCases = {}
      for pairKey, emitterOrdinal in pairs(emitterSelections) do
        normalized.resourceCases[pairKey] = emitterOrdinal == "source-assert" and "source-assert"
          or stageActionEmitter(state, role, operands, particleKey, particle, emitterOrdinal, pairKey)
      end
    end
  end
  local choosesEmitter = emitterSelections ~= nil or type(selection.callbackCases) == "table"
  if choosesEmitter and type(normalized.resourceCases) ~= "table" and normalized.resource == nil then
    error(sourceInputError(state, role, operands, "battler particle choice has no emitter resource cases"), 0)
  end
  recordSourceInput(state, role, operands, {}, normalized)
  return {
    actionProfile = selection.actionProfile,
    callbackCases = selection.callbackCases,
    resource = normalized.resource,
    resourceCases = normalized.resourceCases,
    runtimeSelection = selection.runtimeSelection,
    taskKind = selection.taskKind,
  }
end

local PALETTE_CALLBACK_OPERATIONS = {
  ["copy-main-background-palette-to-fade-buffer"] = true,
  ["grayscale-main-background-fade-buffer"] = true,
}

-- Resolves a callback whose source plan is one direct operation instead
-- of a task: a no-op, a picture visibility change, or a palette copy.
---@param state BattleEffectStaging
---@param role string source input role
---@param operands integer[] source operands
---@param selection table<string, unknown> source selection plan carrying `op`
---@return table<string, unknown> resolution carrying the direct operation
local function resolveCallbackOperation(state, role, operands, selection)
  if selection.op == "noop" then
    recordSourceInput(state, role, operands, {}, { role = role, op = "noop" })
    return { op = "noop" }
  end
  local isPictureOperation = selection.op == "set-pokemon-picture-vanished"
  local isPaletteOperation = PALETTE_CALLBACK_OPERATIONS[selection.op] == true
  if not isPictureOperation and not isPaletteOperation then
    error(sourceInputError(state, role, operands, "animation callback direct operation is invalid"), 0)
  elseif isPictureOperation and (type(selection.pictureSets) ~= "table" or type(selection.vanished) ~= "boolean") then
    error(sourceInputError(state, role, operands, "animation callback direct operation is invalid"), 0)
  elseif isPaletteOperation and (selection.pictureSets ~= nil or selection.vanished ~= nil) then
    error(sourceInputError(state, role, operands, "palette callback operation carries unexpected fields"), 0)
  end
  recordSourceInput(state, role, operands, {}, {
    role = role,
    op = selection.op,
    pictureSets = selection.pictureSets,
    vanished = selection.vanished,
  })
  return {
    op = selection.op,
    pictureSets = selection.pictureSets,
    vanished = selection.vanished,
  }
end

---@param state BattleEffectStaging
---@param role string source input role
---@param operands integer[] source operands
---@param selection table<string, unknown> source selection plan
local function checkCallbackPlan(state, role, operands, selection)
  if
    type(selection.callback) ~= "string"
    or type(selection.taskKind) ~= "string"
    or type(selection.context) ~= "string"
    or type(selection.parameters) ~= "table"
  then
    error(sourceInputError(state, role, operands, "animation callback plan has no semantic task"), 0)
  end
end

-- Animation source decoders by source-plan decoder name. Each receives
-- the selected archive member and returns its decoded payload.
local function decodeAnimationChars(archive, memberId, _, label)
  return decodeChars(archive, memberId, label .. " characters")
end

local function decodeAnimationPalette(archive, memberId, _, label)
  -- The runtime sprite task consumes its palette lease through the
  -- decoded colors field, so the staged payload keeps the same record
  -- shape as every other palette: colors under their field, never a
  -- bare color list.
  return { colors = paletteRecords(decodePalette(archive, memberId, label .. " palette")) }
end

local function decodeAnimationScreen(archive, memberId, _, label)
  return decodeScreen(archive, memberId, label .. " screen")
end

local function decodeAnimationCells(archive, memberId, _, label)
  return decodeCells(archive, memberId, label .. " cells")
end

local function decodeAnimationSequences(archive, memberId, _, label)
  return decodeAnimation(archive, memberId, label .. " animation")
end

local function decodeAnimationMultiCell(_, _, bytes, _, options)
  local MultiCell = require("libs.nds.src.nitro.g2d.MultiCell")
  return must(MultiCell.decode(bytes, options))
end

local function decodeAnimationMultiCellAnimation(_, _, bytes, _, options)
  local MultiCellAnimation = require("libs.nds.src.nitro.g2d.MultiCellAnimation")
  return must(MultiCellAnimation.decode(bytes, options))
end

local ANIMATION_SOURCE_DECODERS = {
  char = decodeAnimationChars,
  palette = decodeAnimationPalette,
  screen = decodeAnimationScreen,
  cell = decodeAnimationCells,
  animation = decodeAnimationSequences,
  multiCell = decodeAnimationMultiCell,
  multiCellAnimation = decodeAnimationMultiCellAnimation,
}

-- Reads, decodes, and stages every source-selected slot of one input in
-- slot order under its content-addressed animation resource key.
---@param state BattleEffectStaging
---@param role string source input role
---@param operands integer[] source operands
---@param sourceSelections table<string, table<string, unknown>> selected sources by slot
---@return table<string, string> resourceKeys by slot
---@return table<string, table<string, unknown>> selections physical selections by slot
local function stageSelectedSources(state, role, operands, sourceSelections)
  local resourceKeys = {}
  local selections = {}
  for _, slot in ipairs(sortedSetValues(sourceSelections)) do
    local source = sourceSelections[slot]
    local sourceArchive = effectArchive(state, source.archiveSymbol, "animation " .. role)
    local sourceBytes, sourceErr = sourceArchive:readMember(source.memberId)
    if sourceBytes == nil then
      error(
        Errors.new("BATTLE_EFFECT_SOURCE_UNAVAILABLE", "selected animation resource member is absent", {
          effectKey = state.effectKey,
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
    local decoder = ANIMATION_SOURCE_DECODERS[source.decoder]
    if decoder == nil then
      error(
        Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "animation source selection has no decoder", {
          effectKey = state.effectKey,
          role = role,
          provenance = { decoder = source.decoder, operands = operands, slot = slot },
        }),
        0
      )
    end
    local decoded = decoder(
      sourceArchive,
      source.memberId,
      sourceBytes,
      "animation " .. role,
      { effectKey = state.effectKey, role = role, slot = slot }
    )
    local contentIdentity = Hashing.sha1hex(sourceBytes)
    local resourceSlot = slot:gsub("(%u)", "-%1"):lower()
    local resourceKey = table.concat({ "battle/animation", role, resourceSlot, contentIdentity }, "/")
    local payloadPath = BattlePresentationCache.globalResourcePath(resourceKey)
    local previous = state.resolvedResources[resourceKey]
    if previous ~= nil then
      assert(
        previous.contentIdentity == contentIdentity
          and previous.kind == source.kind
          and Hashing.hashLua(state.resourcePayloads[previous.payload]) == Hashing.hashLua(decoded),
        "content-addressed battle resource keys identify one decoded format"
      )
    else
      state.resolvedResources[resourceKey] =
        { kind = source.kind, contentIdentity = contentIdentity, payload = payloadPath }
      state.resourcePayloads[payloadPath] = decoded
    end
    resourceKeys[slot] = resourceKey
    selections[slot] = { archiveSymbol = source.archiveSymbol, memberId = source.memberId, decoder = source.decoder }
  end
  return resourceKeys, selections
end

local MANAGED_SPRITE_SLOT_BY_ROLE = {
  ["sprite-character"] = "character",
  ["sprite-palette"] = "palette",
  ["sprite-cell"] = "cell",
  ["sprite-animation"] = "animation",
}

-- Records a sprite-loading input's staged resource under its manager and
-- typed identity so later templates and configured actions resolve it.
---@param state BattleEffectStaging
---@param role string source input role
---@param operands integer[] manager then typed identity
---@param resourceKeys table<string, string> staged resources by slot
local function registerManagedSpriteResource(state, role, operands, resourceKeys)
  local managedSlot = MANAGED_SPRITE_SLOT_BY_ROLE[role]
  if managedSlot == nil then
    return
  end
  local managerSlot = operands[1]
  local manager = state.managedSpriteResources[managerSlot] or {}
  state.managedSpriteResources[managerSlot] = manager
  local byIdentity = manager[managedSlot] or {}
  manager[managedSlot] = byIdentity
  local previous = byIdentity[operands[2]]
  if previous ~= nil and previous ~= resourceKeys[managedSlot] then
    error(
      Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "managed sprite resource identity is ambiguous", {
        effectKey = state.effectKey,
        provenance = { role = role, operands = operands, slot = managedSlot },
      }),
      0
    )
  end
  byIdentity[operands[2]] = resourceKeys[managedSlot]
end

-- A staged character tile set must become an exact RGBA drawable before
-- publication: the live image upload path admits no other texture shape.
-- Same-call co-selected palettes pair immediately; lone characters keep
-- their decoded tiles until the creating instruction pairs them.
---@param state BattleEffectStaging
---@param role string source input role
---@param resourceKeys table<string, string> staged resources by slot
---@param selections table<string, table<string, unknown>> physical selections by slot
local function queueCharacterRaster(state, role, resourceKeys, selections)
  local characterKey = resourceKeys.character
  if characterKey == nil or selections.character == nil or selections.character.decoder ~= "char" then
    return
  end
  local characterDescriptor = state.resolvedResources[characterKey]
  local stagedCharacters = characterDescriptor ~= nil and state.resourcePayloads[characterDescriptor.payload] or nil
  if
    characterDescriptor ~= nil
    and characterDescriptor.kind == "texture"
    and type(stagedCharacters) == "table"
    and type(stagedCharacters.tiles) == "string"
    and state.pendingCharacterRasters[characterKey] == nil
  then
    state.pendingCharacterRasters[characterKey] = {
      resourceKey = characterKey,
      payloadPath = characterDescriptor.payload,
      chars = stagedCharacters,
      paletteKey = resourceKeys.palette,
      role = role,
    }
  end
end

-- The semantic output of a source-selected input; callback plans also
-- carry their task context and parameters.
---@param resourceKeys table<string, string> staged resources by slot
---@param selection table<string, unknown> source selection plan
---@param isCallbackPlan boolean
---@return table<string, unknown> resolution record
local function selectedSourceOutput(resourceKeys, selection, isCallbackPlan)
  local output = {
    resourceKeys = resourceKeys,
    runtimeSelection = selection.runtimeSelection,
    battlerTarget = selection.battlerTarget,
    taskKind = selection.taskKind,
    callback = selection.callback,
    actionProfile = selection.actionProfile,
    callbackCases = selection.callbackCases,
  }
  if isCallbackPlan then
    output.context = selection.context
    output.parameters = selection.parameters
  end
  return output
end

-- Resolves every input the source plan selects through
-- BattleAnimationSources: particle actions, callbacks, and inputs that
-- stage source members by slot.
---@param state BattleEffectStaging
---@param role string source input role
---@param operands integer[] source operands
---@return table<string, unknown> resolution record handed to the animation compiler
local function resolveSelectedSourceInput(state, role, operands)
  local selection, selectionErr = state.sources.resolveSourceSelection(role, operands)
  if selection == nil then
    error(
      Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "animation source selection is not established", {
        effectKey = state.effectKey,
        reason = selectionErr,
        provenance = { role = role, operands = operands },
      }),
      0
    )
  end
  if role == "battler-particle-action" then
    return resolveParticleAction(state, role, operands, selection)
  end
  local isCallbackPlan = role == "battle-animation-callback"
  if isCallbackPlan then
    if selection.op ~= nil then
      return resolveCallbackOperation(state, role, operands, selection)
    end
    checkCallbackPlan(state, role, operands, selection)
  end
  local sourceSelections = selection.sourceSelections or {}
  if next(sourceSelections) == nil and selection.battlerTarget == nil and not isCallbackPlan then
    error(
      Errors.new("BATTLE_EFFECT_SOURCE_UNRESOLVED", "animation source plan carries no semantic output", {
        effectKey = state.effectKey,
        role = role,
        provenance = { operands = operands },
      }),
      0
    )
  end
  local resourceKeys, selections = stageSelectedSources(state, role, operands, sourceSelections)
  registerManagedSpriteResource(state, role, operands, resourceKeys)
  queueCharacterRaster(state, role, resourceKeys, selections)
  local normalized = selectedSourceOutput(resourceKeys, selection, isCallbackPlan)
  normalized.role = role
  recordSourceInput(state, role, operands, selections, normalized)
  return selectedSourceOutput(resourceKeys, selection, isCallbackPlan)
end

local SOURCE_INPUT_RESOLVERS = {
  ["managed-sprite-manager-capacities"] = resolveManagerCapacities,
  ["managed-sprite-manager-disposal"] = resolveManagerDisposal,
  ["battler-particle-resource"] = resolveBattlerParticleResource,
  ["configured-sprite-action"] = resolveConfiguredSpriteAction,
  ["managed-sprite-template"] = resolveManagedSpriteTemplate,
}

local CONTEXT_TYPES = {
  battlerTopology = "battle-animation-battler-topology",
  spriteContextTable = "battle-animation-sprite-context-table",
  movePower = "battle-animation-move-power-u16",
}

-- Typed context each native callback reads beyond its instruction.
local CALLBACK_REQUIRED_CONTEXT = {
  ["pokemon-picture-affine-blend-palette-transition"] = { "spriteContextTable" },
  ["battle-sprite-sinusoidal-position-animation"] = { "battlerTopology", "spriteContextTable" },
  ["battle-sprite-priority-appearance-transition"] = { "battlerTopology", "spriteContextTable" },
  ["battle-background-alpha-scroll-transition"] = { "battlerTopology" },
  ["battle-background-sprite-slide-transition"] = { "battlerTopology" },
  ["pokemon-picture-selected-position-offset-transition"] = { "battlerTopology" },
  ["pokemon-picture-offset-transition"] = { "battlerTopology" },
  ["pokemon-picture-cyclic-two-phase-position-transition"] = { "battlerTopology" },
  ["pokemon-picture-linear-offscreen-transition"] = { "battlerTopology" },
  ["battle-background-four-picture-move-power-transition"] = { "movePower" },
}

-- Adds the typed context one instruction tree reads to `requiredContext`.
---@param requiredContext table<string, { type: string }>
---@param instruction unknown normalized instruction or nested value
local function collectRequiredContext(requiredContext, instruction)
  if type(instruction) ~= "table" then
    return
  end
  local needs = {}
  local parameters = instruction.parameters
  if instruction.op == "set-pokemon-picture-vanished" then
    needs[#needs + 1] = "battlerTopology"
  end
  if parameters ~= nil and (parameters.spriteContextSlot ~= nil or parameters.oamModeSpriteSlots ~= nil) then
    needs[#needs + 1] = "spriteContextTable"
  end
  if parameters ~= nil and parameters.pictureSets ~= nil then
    needs[#needs + 1] = "battlerTopology"
  end
  for _, name in ipairs(CALLBACK_REQUIRED_CONTEXT[instruction.callback] or {}) do
    needs[#needs + 1] = name
  end
  for _, name in ipairs(needs) do
    requiredContext[name] = { type = CONTEXT_TYPES[name] }
  end
  for _, nested in pairs(instruction) do
    if type(nested) == "table" then
      collectRequiredContext(requiredContext, nested)
    end
  end
end

-- Validates the semantic effect key and reads its routed source stream.
---@param romFs RomFs
---@param sources table<string, unknown> BattleAnimationSources
---@param effectKey unknown requested key
---@return table<string, unknown>|nil route, string|nil stream
---@return Errors.Error|nil failure
local function readEffectSource(romFs, sources, effectKey)
  if type(effectKey) ~= "string" or effectKey == "" or effectKey:find("/", 1, true) ~= nil then
    return nil,
      nil,
      Errors.new("BATTLE_EFFECT_UNKNOWN", "unknown battle effect key: " .. tostring(effectKey), {
        effectKey = tostring(effectKey),
      })
  end
  local route = sources.resolveSemanticRoute(effectKey)
  if route == nil then
    return nil,
      nil,
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
      nil,
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
      nil,
      Errors.new("BATTLE_EFFECT_SOURCE_UNAVAILABLE", "could not read selected effect member", {
        effectKey = effectKey,
        archiveSymbol = route.archiveSymbol,
        memberId = route.memberId,
        cause = tostring(memberErr),
      })
  end
  return route, stream, nil
end

-- The audio closure: every effect sound's sequence grouped by its bank,
-- each bank one of the source-listed effect sound banks.
---@param state BattleEffectStaging
---@param instructions BattleAnimationInstruction[]
---@return { bankId: integer, sequenceIds: integer[] }[]|nil audio provenance
---@return unknown|nil failure
local function effectAudioProvenance(state, instructions)
  local hasSound = false
  for _, instruction in ipairs(instructions) do
    hasSound = hasSound or instruction.sound ~= nil
  end
  if not hasSound then
    return {}
  end
  local audioCompiler = require("romdump.src.digest.audio.AudioCompiler")
  local audioPlan, audioPlanErr = audioCompiler.planSource(state.romFs)
  if audioPlan == nil then
    return nil, audioPlanErr
  end
  local index = audioPlan.plan.index
  local plannedBanks = {}
  for _, bankSymbol in ipairs(state.sources.EFFECT_SOUND_BANKS) do
    local bankId = index.bankBySymbol[bankSymbol]
    assert(bankId ~= nil, "effect sound bank is source-indexed: " .. bankSymbol)
    plannedBanks[bankId] = true
  end
  local sequencesByBank = {}
  for _, instruction in ipairs(instructions) do
    local sequenceSymbol = instruction.sound
    if sequenceSymbol ~= nil then
      local sequenceId = index.sequenceBySymbol[sequenceSymbol]
      local sequenceRecord = sequenceId ~= nil and index.sequences[sequenceId] or nil
      if sequenceRecord == nil then
        return nil,
          Errors.new("BATTLE_EFFECT_CLOSURE_UNRESOLVED", "effect sound has no source-indexed sequence", {
            effectKey = state.effectKey,
            sequenceSymbol = sequenceSymbol,
          })
      end
      local bankId = sequenceRecord.bankId
      if not plannedBanks[bankId] then
        local bankRecord = index.banks[bankId]
        return nil,
          Errors.new("BATTLE_EFFECT_CLOSURE_UNRESOLVED", "effect sound lives outside the effect sound banks", {
            effectKey = state.effectKey,
            sequenceSymbol = sequenceSymbol,
            bankSymbol = bankRecord ~= nil and bankRecord.symbol or nil,
          })
      end
      sequencesByBank[bankId] = sequencesByBank[bankId] or {}
      sequencesByBank[bankId][sequenceId] = true
    end
  end
  local audioProvenance = {}
  for _, bankId in ipairs(sortedSetValues(sequencesByBank)) do
    audioProvenance[#audioProvenance + 1] = { bankId = bankId, sequenceIds = sortedSetValues(sequencesByBank[bankId]) }
  end
  return audioProvenance
end

-- The decoded APS archive behind one closure particle resource, reusing
-- an archive a battler particle input already decoded.
---@param state BattleEffectStaging
---@param resourceKey string particle resource key
---@return { bytes: string, decoded: NitroSplData, source: table<string, unknown> }|nil particle
---@return unknown|nil failure
local function closureParticle(state, resourceKey)
  local particle = state.decodedParticleResources[resourceKey]
  local source = particle and particle.source or state.sources.resolveParticleSource(resourceKey)
  if source == nil or source.decoder ~= "spl" or source.kind ~= "particle" then
    return nil,
      Errors.new("BATTLE_EFFECT_CLOSURE_UNRESOLVED", "particle resource has no typed producer source", {
        effectKey = state.effectKey,
        resourceKey = resourceKey,
      })
  end
  if particle ~= nil then
    return particle
  end
  local particleArchive = state.archives[source.archiveSymbol]
  if particleArchive == nil then
    local openedParticleArchive, particleArchiveError = state.romFs:openNarc(source.archiveSymbol)
    if openedParticleArchive == nil then
      return nil, particleArchiveError
    end
    particleArchive = openedParticleArchive
    state.archives[source.archiveSymbol] = openedParticleArchive
  end
  local bytes, particleReadErr = particleArchive:readMember(source.memberId)
  if bytes == nil then
    return nil, particleReadErr
  end
  local decoded, particleDecodeErr = Spl.decode(bytes, { role = "battle-effect-particle" })
  if decoded == nil then
    return nil, particleDecodeErr
  end
  particle = {
    bytes = bytes,
    decoded = decoded --[[@as NitroSplData]],
    source = source,
  }
  state.decodedParticleResources[resourceKey] = particle
  return particle
end

-- Stages one closure particle archive: its resources and every emitter
-- normalized into the source-independent particle payload.
---@param state BattleEffectStaging
---@param resourceKey string particle resource key
---@param particle { bytes: string, decoded: NitroSplData, source: table<string, unknown> } decoded particle archive
local function stageClosureParticle(state, resourceKey, particle)
  local provenance = {
    archiveSymbol = particle.source.archiveSymbol,
    memberId = particle.source.memberId,
  }
  local archiveDecoded = particle.decoded
  assert(archiveDecoded ~= nil and type(archiveDecoded.emitters) == "table", "particle archives decode before staging")
  local entries = stageParticleArchiveResources(state, archiveDecoded, provenance)
  local normalizedEmitters = {}
  for emitterIndex, emitter in ipairs(archiveDecoded.emitters) do
    normalizedEmitters[emitterIndex] =
      normalizeParticleEmitter(state.effectKey, emitter, entries, emitterIndex - 1, provenance)
  end
  local normalizedResources = {}
  for resourceIndex, entry in ipairs(entries) do
    normalizedResources[resourceIndex] = { textureKey = entry.textureKey, paletteKey = entry.paletteKey }
  end
  addEffectResource(state, resourceKey, "particle", Hashing.sha1hex(particle.bytes), {
    emitters = normalizedEmitters,
    resources = normalizedResources,
  })
end

-- Stages every particle archive an effect instruction creates, in
-- resource-key order.
---@param state BattleEffectStaging
---@param instructions BattleAnimationInstruction[]
---@return { resourceKey: string, archiveSymbol: string, memberId: integer }[]|nil particle provenance
---@return unknown|nil failure
local function stageClosureParticles(state, instructions)
  local particleResourceKeys = {}
  for _, instruction in ipairs(instructions) do
    if instruction.op == "create-battler-effect" and instruction.resource ~= nil then
      particleResourceKeys[instruction.resource] = true
    end
  end
  local particleProvenance = {}
  for _, resourceKey in ipairs(sortedSetValues(particleResourceKeys)) do
    local particle, particleErr = closureParticle(state, resourceKey)
    if particle == nil then
      return nil, particleErr
    end
    local staged, stageErr = pcall(stageClosureParticle, state, resourceKey, particle)
    if not staged then
      return nil, structuredFailure(stageErr)
    end
    local source = particle.source
    particleProvenance[#particleProvenance + 1] =
      { resourceKey = resourceKey, archiveSymbol = source.archiveSymbol, memberId = source.memberId }
  end
  return particleProvenance
end

-- Pairs each lone pending character with the one staged palette its
-- creating instruction carries. Two different palettes claiming one
-- character fail the build.
---@param state BattleEffectStaging
---@param instructions BattleAnimationInstruction[]
---@return table<string, string> palette key by character key
local function pairPendingCharacterPalettes(state, instructions)
  local pairByCharacter = {}
  for _, instruction in ipairs(instructions) do
    if type(instruction.resourceKeys) == "table" then
      local characters, palettes = {}, {}
      for _, key in pairs(instruction.resourceKeys) do
        if state.pendingCharacterRasters[key] ~= nil then
          characters[#characters + 1] = key
        elseif type(state.resolvedResources[key]) == "table" and state.resolvedResources[key].kind == "palette" then
          palettes[#palettes + 1] = key
        end
      end
      if #palettes == 1 then
        for _, characterKey in ipairs(characters) do
          local paired = pairByCharacter[characterKey]
          if paired ~= nil and paired ~= palettes[1] then
            error(
              Errors.new(
                "BATTLE_EFFECT_CLOSURE_UNRESOLVED",
                "managed sprite character pairs with more than one staged palette",
                { effectKey = state.effectKey, resourceKey = characterKey }
              ),
              0
            )
          end
          pairByCharacter[characterKey] = palettes[1]
        end
      end
    end
  end
  return pairByCharacter
end

-- Rasterize every pending character tile set through its paired source
-- palette into the exact RGBA drawable the live image upload path
-- requires. A character with no discoverable palette fails the build
-- instead of publishing raw Nitro bitfields.
---@param state BattleEffectStaging
---@param instructions BattleAnimationInstruction[]
local function rasterizePendingCharacters(state, instructions)
  if next(state.pendingCharacterRasters) == nil then
    return
  end
  local pairByCharacter = pairPendingCharacterPalettes(state, instructions)
  for characterKey, pending in pairs(state.pendingCharacterRasters) do
    local paletteKey = pending.paletteKey or pairByCharacter[characterKey]
    local paletteDescriptor = paletteKey ~= nil and state.resolvedResources[paletteKey] or nil
    local palettePayload = paletteDescriptor ~= nil and state.resourcePayloads[paletteDescriptor.payload] or nil
    -- Staged palettes carry their decoded colors field, the same record
    -- shape the runtime sprite task consumes: unwrap once here instead
    -- of publishing raw color lists beside wrapped records.
    local paletteColors = type(palettePayload) == "table" and palettePayload.colors or nil
    if type(paletteColors) ~= "table" or type(paletteColors[1]) ~= "table" or paletteColors[1].r == nil then
      error(
        Errors.new("BATTLE_EFFECT_CLOSURE_UNRESOLVED", "managed sprite character has no paired staged palette", {
          effectKey = state.effectKey,
          resourceKey = characterKey,
          role = pending.role,
        }),
        0
      )
    end
    local tileSize = pending.chars.depth == 3 and 32 or 64
    local tileCount = math.floor(#pending.chars.tiles / tileSize)
    local raster = G2dRasterizer.renderTileStrip(pending.chars, { colors = paletteColors }, 0, tileCount, 0, {
      role = "battle effect " .. state.effectKey .. " " .. pending.role .. " characters",
    })
    state.resourcePayloads[pending.payloadPath] = {
      width = raster.width,
      height = raster.height,
      rgba8888 = raster.pixels,
    }
  end
end

-- Validates the published effect record, re-raising a schema failure with
-- the failing instruction's source offset and continuation slot.
---@param effect BattlePresentationEffect
---@param sourceOffsets table<integer, integer>|nil source offset by instruction index
local function validateEffect(effect, sourceOffsets)
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
  if valid then
    return
  end
  local validation = structuredFailure(validationError)
  local diagnosticContext = {}
  for key, value in pairs(validation.context) do
    diagnosticContext[key] = value
  end
  diagnosticContext.effectKey = effect.key
  local instructionIndex = validation.message:match("instructions%[(%d+)%]")
  if instructionIndex ~= nil then
    local index = tonumber(instructionIndex)
    assert(index ~= nil, "schema instruction index parses as an integer")
    diagnosticContext.instructionIndex = index
    if sourceOffsets ~= nil then
      diagnosticContext.sourceOffset = sourceOffsets[index]
    end
    local instruction = effect.program.instructions[index]
    if instruction ~= nil then
      diagnosticContext.continuationSlot = instruction.continuationSlot
    end
  end
  error(Errors.new(validation.code, validation.message, diagnosticContext), 0)
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
  local animationSources = require("romdump.src.config.BattleAnimationSources")
  local route, stream, sourceErr = readEffectSource(romFs, animationSources, effectKey)
  if route == nil then
    return nil, sourceErr
  end
  ---@type BattleEffectStaging
  local state = {
    romFs = romFs,
    effectKey = effectKey,
    sources = animationSources,
    resolvedResources = {},
    resourcePayloads = {},
    sourceInputs = {},
    resolvedSourceInputs = {},
    archives = {},
    managedSpriteResources = {},
    managedSpriteCapacities = {},
    -- Managed-sprite and background character tile sets staged as raw
    -- tile data until rasterizePendingCharacters pairs each with its
    -- palette, so no staged texture keeps raw Nitro bitfields.
    pendingCharacterRasters = {},
    particleByBattler = {},
    decodedParticleResources = {},
  }
  local function resolveSourceInput(role, operands)
    return (SOURCE_INPUT_RESOLVERS[role] or resolveSelectedSourceInput)(state, role, operands)
  end
  local AnimationCompiler = require("romdump.src.digest.battle.BattleAnimationCompiler")
  local ok, program = pcall(AnimationCompiler.compile, {
    key = effectKey,
    stream = stream,
    resolveSourceInput = resolveSourceInput,
  })
  if not ok then
    return nil, structuredFailure(program)
  end
  assert(type(program) == "table", "animation compiler returns a program")
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
  for _, instruction in ipairs(effectProgram.instructions) do
    collectRequiredContext(requiredContext, instruction)
  end
  if type(effectProgram.subprograms) ~= "table" then
    return nil,
      Errors.new("BATTLE_EFFECT_CLOSURE_UNRESOLVED", "effect program carries no subprogram closure", {
        effectKey = effectKey,
        archiveSymbol = route.archiveSymbol,
        memberId = route.memberId,
        resolvedSourceInputs = state.resolvedSourceInputs,
        resourceDescriptors = state.resolvedResources,
        resourcePayloads = state.resourcePayloads,
      })
  end
  for _, subprogram in pairs(effectProgram.subprograms) do
    collectRequiredContext(requiredContext, subprogram)
  end
  local audioProvenance, audioErr = effectAudioProvenance(state, effectProgram.instructions)
  if audioProvenance == nil then
    return nil, audioErr
  end
  local particleProvenance, particleErr = stageClosureParticles(state, effectProgram.instructions)
  if particleProvenance == nil then
    return nil, particleErr
  end
  local rasterOk, rasterErr = pcall(rasterizePendingCharacters, state, effectProgram.instructions)
  if not rasterOk then
    return nil, structuredFailure(rasterErr)
  end
  local effect = {
    schema = require("libs.assets.src.battle.BattleAnimationSchema").EFFECT_SCHEMA,
    key = effectKey,
    catalogIdentity = versionId .. ":" .. romFs:metadata().sha1,
    program = effectProgram,
    dependencies = sortedSetValues(state.resolvedResources),
    resources = state.resolvedResources,
    requiredContext = requiredContext,
    resourcePayloads = state.resourcePayloads,
    provenance = {
      archiveSymbol = route.archiveSymbol,
      memberId = route.memberId,
      sourceInputs = state.sourceInputs,
      resolvedSourceInputs = state.resolvedSourceInputs,
      audio = audioProvenance,
      particle = particleProvenance,
    },
  }
  validateEffect(effect, program.sourceOffsets)
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
