local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Cartridge = require("libs.nds.src.rom.Cartridge")
local NdsBuilder = require("tests.support.NdsBuilder")
local BannerIconFixture = require("tests.support.BannerIconFixture")

local T = {}

local FIXTURE = {
  gameCode = "IPKE",
  title = "TESTHG",
  overlays9 = { "OVERLAY0-DATA" },
  unmapped = { "UNMAPPED-DATA" },
  tree = {
    files = { { name = "root.bin", content = "ROOT" } },
    dirs = {
      {
        name = "folder",
        files = { { name = "a.bin", content = "AAAA" } },
        dirs = {
          { name = "nested", files = { { name = "b.bin", content = "BB" } } },
        },
      },
    },
  },
}

local function borrowedSource(data)
  return {
    size = function()
      return #data
    end,
    read = function(_, offset, length)
      if offset < 0 or length < 0 or offset + length > #data then
        return nil, "read outside fixture"
      end
      return data:sub(offset + 1, offset + length)
    end,
  }
end

local function u32At(data, offset)
  local b1, b2, b3, b4 = data:byte(offset + 1, offset + 4)
  return b1 + b2 * 0x100 + b3 * 0x10000 + b4 * 0x1000000
end

local function withU32(data, offset, value)
  local bytes = string.char(
    value % 0x100,
    math.floor(value / 0x100) % 0x100,
    math.floor(value / 0x10000) % 0x100,
    math.floor(value / 0x1000000) % 0x100
  )
  return data:sub(1, offset) .. bytes .. data:sub(offset + 5)
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected an Errors object, got " .. tostring(err))
  Assert.equal(err.code, code)
end

function T.parses_generic_container_from_a_borrowed_source()
  local data = NdsBuilder.build(FIXTURE)
  local cartridge = Cartridge.parse(borrowedSource(data))
  Assert.equal(cartridge:header().gameCode, "IPKE")
  Assert.equal(cartridge:fatCount(), 5)
  Assert.equal(cartridge:readFatFile(0), "OVERLAY0-DATA")
  Assert.equal(cartridge:nitroFs().byPath["folder/nested/b.bin"], 4)
  Assert.equal(cartridge:arm9Overlays()[1].fileId, 0)
  Assert.equal(#cartridge:arm7Overlays(), 0)
end

function T.rejects_section_outside_rom()
  local data = NdsBuilder.build({ corrupt = { sectionOutOfRange = true } })
  throwsCode("NDS_SECTION_OUT_OF_RANGE", function()
    Cartridge.parse(borrowedSource(data))
  end)
end

function T.rejects_invalid_fat_size()
  local data = NdsBuilder.build({
    gameCode = FIXTURE.gameCode,
    title = FIXTURE.title,
    overlays9 = FIXTURE.overlays9,
    unmapped = FIXTURE.unmapped,
    tree = FIXTURE.tree,
    corrupt = { fatNotDiv8 = true },
  })
  throwsCode("NDS_FAT_SIZE_INVALID", function()
    Cartridge.parse(borrowedSource(data))
  end)
end

function T.rejects_fat_entry_with_start_past_end()
  local data = NdsBuilder.build(FIXTURE)
  local fatOffset = u32At(data, 0x48)
  local malformed = withU32(data, fatOffset, u32At(data, fatOffset + 4) + 1)
  throwsCode("FAT_ENTRY_INVALID", function()
    Cartridge.parse(borrowedSource(malformed))
  end)
end

function T.rejects_fat_entry_past_rom()
  local data = NdsBuilder.build(FIXTURE)
  local fatOffset = u32At(data, 0x48)
  local malformed = withU32(data, fatOffset + 4, #data + 1)
  throwsCode("FAT_RANGE_OUT_OF_BOUNDS", function()
    Cartridge.parse(borrowedSource(malformed))
  end)
end

function T.reads_static_banner_tiles_nibbles_palette_and_transparency()
  Assert.equal(
    type(Cartridge.readBannerIcon),
    "function",
    "the cartridge owner must expose a pure static-banner reader"
  )
  local banner = BannerIconFixture.staticBanner()
  local data = NdsBuilder.build(BannerIconFixture.spec("IPKE", banner.block, "HEARTGOLD-BANNER"))
  local source = borrowedSource(data)
  local rgba, failure = Cartridge.readBannerIcon(source, Cartridge.readHeader(source))
  Assert.isNil(failure, "a complete static banner must decode")
  Assert.equal(rgba, banner.rgba, "the decoded row-major RGBA must match the independent fixture oracle")
  Assert.equal(#rgba, 4096, "a static banner is exactly 32x32 RGBA")
end

function T.reads_all_transparent_banner_without_fabricating_pixels()
  Assert.equal(type(Cartridge.readBannerIcon), "function", "the static-banner reader is required")
  local banner = BannerIconFixture.transparentBanner()
  local data = NdsBuilder.build(BannerIconFixture.spec("IPKE", banner.block, "TRANSPARENT-BANNER"))
  local rgba, failure = Cartridge.readBannerIcon(borrowedSource(data))
  Assert.isNil(failure)
  Assert.equal(rgba, banner.rgba)
  Assert.equal(rgba, string.rep("\0", 4096), "index zero stays transparent with zero RGB")
end

function T.rejects_missing_out_of_range_truncated_and_unreadable_banners()
  Assert.equal(type(Cartridge.readBannerIcon), "function", "the static-banner reader is required")
  local banner = BannerIconFixture.staticBanner()
  local missing = NdsBuilder.build(BannerIconFixture.spec("IPKE", nil, "MISSING-BANNER"))
  local complete = NdsBuilder.build(BannerIconFixture.spec("IPKE", banner.block, "COMPLETE-BANNER"))
  local truncated = NdsBuilder.build(BannerIconFixture.spec("IPKE", banner.block:sub(1, -2), "TRUNCATED-BANNER"))
  local cases = {
    { label = "missing banner", data = missing },
    { label = "out-of-range banner", data = BannerIconFixture.withBannerOffset(complete, #complete + 1) },
    { label = "truncated banner", data = truncated },
  }
  for _, case in ipairs(cases) do
    local rgba, failure = Cartridge.readBannerIcon(borrowedSource(case.data))
    Assert.isNil(rgba, case.label .. " must not fabricate an icon")
    Assert.isTrue(Errors.is(failure), case.label .. " must return a structured error")
  end

  local bannerOffset = Cartridge.readHeader(borrowedSource(complete)).bannerOffset
  local unreadable = {
    size = function()
      return #complete
    end,
    read = function(_, offset, length)
      if offset == bannerOffset then
        return nil, "injected banner read failure"
      end
      return complete:sub(offset + 1, offset + length)
    end,
  }
  local rgba, failure = Cartridge.readBannerIcon(unreadable, Cartridge.readHeader(borrowedSource(complete)))
  Assert.isNil(rgba)
  Assert.isTrue(Errors.is(failure), "an inexact banner read must remain a structured failure")
end

return { tests = T }
