-- ROM conformance for the phone window-palette and OBJ-bank contracts: the producer emits
-- phone.windowPalette per skin from bank 1 of the same NCLR member behind
-- the foreground plane, and every retail-used phone OBJ sequence carries
-- its descriptor-grounded palette bank. Decomp grounding (read-only):
-- PokegearPhone_LoadPalettes loads MAIN_BG from NCLR member skin+10 and
-- SUB_BG from member skin+4, while windows[0,1] (the call speech/name
-- windows on SUB_2) print with palette 1; sSpriteTemplates in the same
-- file drives phone animations {0,1,2,3,4,5,6,8} with non-zero OBJ
-- palette slots 6 and 7. Bank-0-only rendering is therefore unverified,
-- never the default. Both tests fail loudly without a ready dump through
-- the declared rom_dump capability instead of skipping.

local Assert = require("tests.support.Assert")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local Lz10 = require("romdump.src.digest.Lz10")
local Narc = require("libs.nds.src.nitro.Narc")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearSources = require("romdump.src.config.PokegearSources")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

---@param _ unknown
local function void(_)
end

-- Retail-used phone OBJ sequences (one-based compiled ids), transcribed
-- from the .animation fields of sSpriteTemplates in
-- pokegear_phone_gfx.c: corners and arrows on OBJ palette slot 6,
-- scroll arrows and the move chevron on slot 7. Animation 7 has no
-- template behind it.
local RETAIL_USED_PHONE_SEQUENCES = { 1, 2, 3, 4, 5, 6, 7, 9 }

---@param romFs table<string, unknown>
---@param path string
---@return table archive
local function openArchive(romFs, path)
  local reader = romFs --[[@as { readSourcePath: fun(self: table, path: string): string? }]]
  local bytes = reader:readSourcePath(path)
  Assert.notNil(bytes, "the dump must expose archive " .. path)
  local archive = Narc.open(assert(bytes), path)
  Assert.notNil(archive, "archive " .. path .. " must open")
  return assert(archive)
end

---@param archive table
---@param memberId integer
---@param role string
---@return table palette record
local function decodeNclrMember(archive, memberId, role)
  local bytes = assert(archive:readMember(memberId), role .. " NCLR member " .. memberId .. " must exist")
  if string.byte(bytes, 1) == 0x10 then
    bytes = assert(Lz10.decode(bytes), role .. " NCLR member " .. memberId .. " must decompress")
  end
  local palette = G2dDecoder.decodePalette(bytes, { label = "phone-window:" .. role })
  Assert.notNil(palette, role .. " NCLR member " .. memberId .. " must decode")
  return assert(palette)
end

-- Sixteen colors of one zero-based palette bank as one-based {r, g, b}
-- records, in source color order. This oracle never calls the producer's
-- paletteBank helper.
---@param palette table
---@param bank integer zero-based bank
---@param role string
---@return table
local function bankColors(palette, bank, role)
  local colors = {}
  for index = 1, 16 do
    local color = palette.colors[bank * 16 + index]
    Assert.notNil(color, role .. " bank " .. bank .. " carries all sixteen source colors")
    colors[index] = { r = color.r, g = color.g, b = color.b }
  end
  return colors
end

-- The call speech/name windows print through palette 1 of the foreground
-- NCLR member: the manifest carries that bank per skin as
-- phone.windowPalette, decoded here straight from the dump.
function T.phone_window_palette_matches_bank1_of_the_foreground_member(romFs, versionId)
  local phone = openArchive(romFs, PokegearSources.archives.phone.path)
  local expected = {}
  for _, skin in ipairs(PokegearSources.skins) do
    local foreground = PokegearSources.phoneForeground(skin)
    expected[skin] =
      bankColors(decodeNclrMember(phone, foreground.palette, "phone.foreground.skin" .. skin), 1, "skin " .. skin)
  end
  local loaded, PokegearAssetCompiler = pcall(require, "romdump.src.digest.ui.PokegearAssetCompiler")
  Assert.isTrue(loaded, "the pokegear family compiler must be published before the window palette can be proven")
  assert(type(PokegearAssetCompiler) == "table", "the family compiler loads above")
  local bundle = PokegearAssetCompiler.compile(romFs, versionId)
  local compiled = assert(bundle, versionId .. " must compile the pokegear family")
  local window = compiled.manifest.phone.windowPalette
  Assert.notNil(
    window,
    versionId .. " publishes phone.windowPalette per skin: bank 1 of NCLR member 10+skin behind the SUB_2 call windows"
  )
  assert(type(window) == "table", "the window palette publishes above")
  for _, skin in ipairs(PokegearSources.skins) do
    Assert.deepEqual(
      window[skin],
      expected[skin],
      versionId .. " skin " .. skin .. " window palette is bank 1 of its foreground NCLR member"
    )
  end
  local record = PokegearAssetSchema.validate(compiled.manifest)
  Assert.notNil(record, versionId .. " manifest still validates with its window palette section")
end

-- Every retail-used phone OBJ sequence names its palette bank within the
-- decoded OBJ palette member instead of silently falling back to bank 0.
-- Exact bank values are transcribed from the a/1/7/5 descriptors and the
-- retail template slots in the implementation lane; this contract pins
-- coverage plus range so an untranscribed table cannot pass.
function T.phone_obj_sequences_carry_their_retail_palette_banks(romFs, versionId)
  void(versionId)
  local phone = openArchive(romFs, PokegearSources.archives.phone.path)
  local animBytes = assert(phone:readMember(3), "the phone NANR member must exist")
  if string.byte(animBytes, 1) == 0x10 then
    animBytes = assert(Lz10.decode(animBytes), "the phone NANR member must decompress")
  end
  local animation = G2dDecoder.decodeAnimation(animBytes, { label = "phone-window:animation" })
  Assert.notNil(animation, "the phone animation resource must decode")
  Assert.equal(#assert(animation).anims, 9, "the phone OBJ set keeps its nine source sequences")
  local objPalette = decodeNclrMember(phone, PokegearSources.phoneSpritePalette, "phone.obj")
  local bankCount = math.floor(#assert(objPalette.colors, "the phone OBJ palette carries its colors") / 16)
  Assert.isTrue(bankCount > 1, "the phone OBJ palette member carries more than the fallback bank")
  local banks = assert(PokegearSources.phoneSprites.phone, "the producer names its phone OBJ set").banks
  Assert.notNil(banks, "the producer records its phone OBJ bank selection")
  assert(type(banks) == "table", "the phone OBJ bank selection is a record")
  for _, sequence in ipairs(RETAIL_USED_PHONE_SEQUENCES) do
    local bank = banks[sequence]
    Assert.notNil(
      bank,
      "phone OBJ sequence " .. sequence .. " names its retail palette bank instead of falling back to bank 0"
    )
    Assert.isTrue(
      type(bank) == "number" and bank % 1 == 0 and bank >= 0 and bank < bankCount,
      "phone OBJ sequence " .. sequence .. " bank stays inside the decoded OBJ palette member"
    )
  end
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
