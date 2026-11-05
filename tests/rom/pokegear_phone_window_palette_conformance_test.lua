-- ROM conformance for the phone palette contracts: one dump open proves
-- the per-skin call-window palette (bank 1 of the upper NCLR member
-- behind the SUB_2 windows), the upload-relative OBJ sequence banks with
-- the cell-attributed fast-forward sequence, and the source-blended dim
-- variants. Decomp grounding (read-only): PokegearPhone_LoadPalettes
-- loads MAIN_BG from NCLR member skin+10 and SUB_BG from member skin+4,
-- while windows[0,1] print with palette 1; sSpriteTemplates drives phone
-- animations {2,3,4,5,0,1,6,8} with OBJ palette slots 6 and 7 in
-- paletteMode 0 (upload base 0x40, so hardware 6/7 are NCLR-local 2/3)
-- and animation 8 in paletteMode 1 (no forced override, the NCER cell
-- palette applies); PokegearPhone_SetTouchscreenDimState blends the MAIN
-- ranges toward black with factor 8. Each scenario fails loudly without
-- a ready dump through the declared rom_dump capability instead of
-- skipping.

local Assert = require("tests.support.Assert")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local Lz10 = require("romdump.src.digest.Lz10")
local Narc = require("libs.nds.src.nitro.Narc")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearSources = require("romdump.src.config.PokegearSources")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

-- Compiled phone OBJ sequences (one-based) transcribed from the
-- .animation fields of sSpriteTemplates in pokegear_phone_gfx.c:
-- animations {2,3,4,5} on OBJ palette slot 6, animations {0,1,6} on
-- slot 7, animation 8 in paletteMode 1. Animation 7 has no template
-- behind it. The upload base is hardware color entry 0x40 (slot 4),
-- so paletteMode-0 hardware slots map to NCLR-local banks 2 and 3.
local EXPECTED_LOCAL_BANKS = { [1] = 3, [2] = 3, [3] = 2, [4] = 2, [5] = 2, [6] = 2, [7] = 3 }
local MODE1_SEQUENCE = 9
local PIXEL_PROOF_SEQUENCES = { 1, 2, 3, 9 }

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
---@return string raw member bytes, LZ-decoded when wrapped
local function readMemberBytes(archive, memberId, role)
  local bytes = assert(archive:readMember(memberId), role .. " member " .. memberId .. " must exist")
  if string.byte(bytes, 1) == 0x10 then
    bytes = assert(Lz10.decode(bytes), role .. " member " .. memberId .. " must decompress")
  end
  return bytes
end

---@param archive table
---@param memberId integer
---@param role string
---@return table palette record
local function decodeNclrMember(archive, memberId, role)
  local palette = G2dDecoder.decodePalette(readMemberBytes(archive, memberId, role), { label = "phone-window:" .. role })
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

---@param romFs table<string, unknown>
---@param versionId string
---@return table bundle the compiled pokegear family
local function compileFamily(romFs, versionId)
  local loaded, PokegearAssetCompiler = pcall(require, "romdump.src.digest.ui.PokegearAssetCompiler")
  Assert.isTrue(loaded, "the pokegear family compiler must be published before the palettes can be proven")
  assert(type(PokegearAssetCompiler) == "table", "the family compiler loads above")
  local bundle = PokegearAssetCompiler.compile(romFs, versionId)
  Assert.notNil(bundle, versionId .. " must compile the pokegear family")
  return assert(bundle)
end

-- The call windows print through SUB member 4+skin bank 1, while the
-- list and tooltip keep MAIN member 10+skin banks 2 and 10.
function T.phone_window_palette_uses_the_upper_member(romFs, versionId)
  local phone = openArchive(romFs, PokegearSources.archives.phone.path)
  local bundle = compileFamily(romFs, versionId)
  local compiled = assert(bundle.manifest, versionId .. " publishes its pokegear manifest").phone
  Assert.notNil(compiled.windowPalette, versionId .. " publishes phone.windowPalette per skin")
  Assert.notNil(compiled.listPalette, versionId .. " keeps publishing phone.listPalette per skin")
  Assert.notNil(compiled.tooltipPalette, versionId .. " keeps publishing phone.tooltipPalette per skin")
  for _, skin in ipairs(PokegearSources.skins) do
    local upper = PokegearSources.phoneUpper(skin)
    local expectedWindow =
      bankColors(decodeNclrMember(phone, upper.palette, "phone.upper.skin" .. skin), 1, "upper skin " .. skin)
    Assert.deepEqual(
      compiled.windowPalette[skin],
      expectedWindow,
      versionId .. " skin " .. skin .. " window palette is bank 1 of the SUB member " .. upper.palette
    )
    local foreground = PokegearSources.phoneForeground(skin)
    local foregroundPalette = decodeNclrMember(phone, foreground.palette, "phone.foreground.skin" .. skin)
    Assert.deepEqual(
      compiled.listPalette[skin],
      bankColors(foregroundPalette, 2, "foreground skin " .. skin),
      versionId .. " skin " .. skin .. " list palette stays bank 2 of the MAIN member " .. foreground.palette
    )
    Assert.deepEqual(
      compiled.tooltipPalette[skin],
      bankColors(foregroundPalette, 10, "foreground skin " .. skin),
      versionId .. " skin " .. skin .. " tooltip palette stays bank 10 of the MAIN member " .. foreground.palette
    )
  end
  local record = PokegearAssetSchema.validate(bundle.manifest)
  Assert.notNil(record, versionId .. " manifest still validates with its window palette section")
end

-- The producer records NCLR-local banks (hardware slot minus the 0x40
-- upload base of four banks), and the mode-1 fast-forward sequence
-- names no override so the NCER cell palette applies.
function T.phone_sprites_use_upload_relative_banks(romFs, versionId)
  local phone = openArchive(romFs, PokegearSources.archives.phone.path)
  local objPalette = decodeNclrMember(phone, PokegearSources.phoneSpritePalette, "phone.obj")
  local bankCount = math.floor(#assert(objPalette.colors, "the phone OBJ palette carries its colors") / 16)
  Assert.isTrue(bankCount > 1, "the phone OBJ palette member carries more than the fallback bank")
  local banks = assert(PokegearSources.phoneSprites.phone, "the producer names its phone OBJ set").banks
  Assert.notNil(banks, "the producer records its phone OBJ bank selection")
  assert(type(banks) == "table", "the phone OBJ bank selection is a record")
  for sequence, expected in pairs(EXPECTED_LOCAL_BANKS) do
    Assert.equal(
      banks[sequence],
      expected,
      "phone OBJ sequence " .. sequence .. " selects NCLR-local bank " .. expected .. ", not its hardware slot"
    )
  end
  Assert.isNil(
    banks[MODE1_SEQUENCE],
    "phone OBJ sequence " .. MODE1_SEQUENCE .. " names no override: the NCER cell palette applies"
  )

  local animBytes = readMemberBytes(phone, 3, "phone animation")
  local animation = G2dDecoder.decodeAnimation(animBytes, { label = "phone-window:animation" })
  Assert.notNil(animation, "the phone animation resource must decode")
  Assert.equal(#assert(animation).anims, 9, "the phone OBJ set keeps its nine source sequences")
end

-- Representative compiled frames reproduce an independent raster of the
-- same source with the corrected bank selection: corners, scroll
-- arrows, and the mode-1 fast-forward cell with per-cell palettes.
-- The oracle never calls the producer's sprite compiler.
function T.phone_sprite_pixels_match_corrected_source_cells(romFs, versionId)
  local PngReader = require("tests.support.PngReader")
  local phone = openArchive(romFs, PokegearSources.archives.phone.path)
  local bundle = compileFamily(romFs, versionId)
  local manifest = assert(bundle.manifest, versionId .. " publishes its pokegear manifest")
  local sprites = assert(manifest.phone.sprites, versionId .. " publishes its phone sprite sets").phone
  local selection = assert(PokegearSources.phoneSprites.phone, "the producer names its phone OBJ set")
  local character = G2dDecoder.decodeChar(readMemberBytes(phone, selection.char, "phone.obj.character"), {})
  local palette = G2dDecoder.decodePalette(readMemberBytes(phone, PokegearSources.phoneSpritePalette, "phone.obj.palette"), {})
  local cellBytes = readMemberBytes(phone, selection.cell, "phone.obj.cell")
  local cells = G2dDecoder.decodeCell(cellBytes, {})
  local mapping = G2dDecoder.decodeCellMapping(cellBytes, { label = "phone-window:obj-cell" })
  local animBytes = readMemberBytes(phone, selection.anim, "phone.obj.animation")
  local animation = G2dDecoder.decodeAnimation(animBytes, { label = "phone-window:obj-animation" })
  Assert.notNil(animation, "the phone animation resource must decode")
  local anims = assert(animation).anims
  for _, sequence in ipairs(PIXEL_PROOF_SEQUENCES) do
    local override = EXPECTED_LOCAL_BANKS[sequence]
    local rendered = G2dRasterizer.renderAnimationFrame(
      character,
      palette,
      cells,
      anims[sequence],
      1,
      { role = "phone-window:sequence" .. sequence, frame = 0 },
      override,
      mapping
    )
    local frame = assert(sprites[sequence], "the compiled set carries sequence " .. sequence).frames[1]
    Assert.notNil(frame, "compiled sequence " .. sequence .. " carries its first frame")
    assert(frame ~= nil, "the compiled frame exists above")
    Assert.equal(frame.width, rendered.width, "sequence " .. sequence .. " keeps its source frame width")
    Assert.equal(frame.height, rendered.height, "sequence " .. sequence .. " keeps its source frame height")
    local staged = assert(bundle.assets[frame.image], "sequence " .. sequence .. " stages its first frame")
    local width, height, rgba = PngReader.rgba(staged)
    Assert.equal(width, rendered.width, "sequence " .. sequence .. " staged art matches its source width")
    Assert.equal(height, rendered.height, "sequence " .. sequence .. " staged art matches its source height")
    Assert.equal(
      rgba,
      rendered.pixels,
      "sequence "
        .. sequence
        .. " staged pixels match the source cells through "
        .. (override == nil and "their NCER palettes" or ("NCLR-local bank " .. override))
    )
  end
end

-- Five-bit channel inversion for the exact blend oracle below: the
-- shared 5-to-8-bit expansion is injective, so every staged 8-bit
-- channel maps back to exactly one source channel.
---@param expanded integer staged 8-bit channel
---@return integer source 5-bit channel
local function toSourceChannel(expanded)
  for channel = 0, 31 do
    if math.floor((channel * 255 + 15) / 31) == expanded then
      return channel
    end
  end
  error("staged channel " .. expanded .. " has no source 5-bit value", 0)
end

-- The retail blend toward black with factor 8 (BlendColor(source, 0, 8)
-- in palette.c): source + (((0 - source) * 8) >> 4), per 5-bit channel.
---@param color table staged 8-bit source color
---@return table staged 8-bit blended color
local function dimColor(color)
  local dimmed = {}
  for _, channel in ipairs({ "r", "g", "b" }) do
    local source = toSourceChannel(color[channel])
    local blended = source + math.floor(((0 - source) * 8) / 16)
    dimmed[channel] = math.floor((blended * 255 + 15) / 31)
  end
  return dimmed
end

-- The dim roles exist for every skin with the generated family identity:
-- the dimmed list palette matches the retail blend exactly, dimmed
-- sprites keep geometry and durations, and every dimmed plane decodes
-- at its source extent while differing from its bright original.
function T.phone_dim_variants_follow_the_source_blend(romFs, versionId)
  local PngReader = require("tests.support.PngReader")
  local bundle = compileFamily(romFs, versionId)
  local manifest = assert(bundle.manifest, versionId .. " publishes its pokegear manifest")
  Assert.equal(
    manifest.schema,
    "g4-pokegear-assets-v3",
    versionId .. " publishes the generated family with its dim roles"
  )
  local phone = assert(manifest.phone, versionId .. " publishes its phone section")
  for _, role in ipairs({ "foregroundDim", "foregroundDimChoice", "dimShellForeground", "listPaletteDim", "spritesDim" }) do
    Assert.notNil(phone[role], versionId .. " publishes phone." .. role)
  end
  for _, skin in ipairs(PokegearSources.skins) do
    local list = assert(phone.listPalette[skin], "skin " .. skin .. " carries its list palette")
    local dimmed = assert(phone.listPaletteDim[skin], "skin " .. skin .. " carries its dimmed list palette")
    for index = 1, 16 do
      Assert.deepEqual(
        dimmed[index],
        dimColor(assert(list[index], "skin " .. skin .. " list color " .. index .. " exists")),
        versionId .. " skin " .. skin .. " dimmed list color " .. index .. " matches the retail blend"
      )
    end
    for _, role in ipairs({ "foregroundDim", "foregroundDimChoice" }) do
      local bright = assert(phone.foreground[skin], "skin " .. skin .. " carries its lower plane")
      local dark = assert(phone[role][skin], "skin " .. skin .. " carries its " .. role .. " plane")
      Assert.equal(dark.width, bright.width, "skin " .. skin .. " " .. role .. " keeps its plane width")
      Assert.equal(dark.height, bright.height, "skin " .. skin .. " " .. role .. " keeps its plane height")
      local _, _, brightRgba = PngReader.rgba(assert(bundle.assets[bright.image], "skin " .. skin .. " stages its lower plane"))
      local _, _, darkRgba = PngReader.rgba(assert(bundle.assets[dark.image], "skin " .. skin .. " stages its " .. role .. " plane"))
      Assert.isTrue(brightRgba ~= darkRgba, "skin " .. skin .. " " .. role .. " differs from its bright original")
    end
    local shellBright = assert(manifest.shell.foreground[skin], "skin " .. skin .. " carries its strip plane")
    local shellDark =
      assert(phone.dimShellForeground[skin], "skin " .. skin .. " carries its dimmed strip plane")
    local _, _, shellBrightRgba =
      PngReader.rgba(assert(bundle.assets[shellBright.image], "skin " .. skin .. " stages its strip plane"))
    local _, _, shellDarkRgba =
      PngReader.rgba(assert(bundle.assets[shellDark.image], "skin " .. skin .. " stages its dimmed strip plane"))
    Assert.isTrue(shellBrightRgba ~= shellDarkRgba, "skin " .. skin .. " dimmed strip differs from its bright original")
  end
  local sprites = assert(phone.sprites, versionId .. " publishes its phone sprite sets").phone
  local dimSprites = assert(phone.spritesDim, versionId .. " publishes its dimmed phone sprite sets").phone
  for sequence, clip in pairs(sprites) do
    local dark = assert(dimSprites[sequence], "dimmed set keeps sequence " .. sequence)
    Assert.equal(#dark.frames, #clip.frames, "dimmed sequence " .. sequence .. " keeps its frame count")
    for frameIndex, frame in ipairs(clip.frames) do
      local darkFrame = assert(dark.frames[frameIndex], "dimmed sequence " .. sequence .. " keeps frame " .. frameIndex)
      Assert.equal(darkFrame.width, frame.width, "dimmed sequence " .. sequence .. " keeps frame widths")
      Assert.equal(darkFrame.height, frame.height, "dimmed sequence " .. sequence .. " keeps frame heights")
      Assert.equal(darkFrame.duration, frame.duration, "dimmed sequence " .. sequence .. " keeps frame durations")
      Assert.equal(darkFrame.anchorX, frame.anchorX, "dimmed sequence " .. sequence .. " keeps frame anchors")
      Assert.equal(darkFrame.anchorY, frame.anchorY, "dimmed sequence " .. sequence .. " keeps frame anchors")
    end
  end
  local record = PokegearAssetSchema.validate(manifest)
  Assert.notNil(record, versionId .. " manifest validates with its dim roles")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
