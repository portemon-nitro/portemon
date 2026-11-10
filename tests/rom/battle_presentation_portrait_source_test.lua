-- Dump-backed back-facing portraits: the real private dump carries true
-- back-picture members apart from the front-picture members, back
-- selectors resolve through the same native picture-selection owner and
-- the existing scan/unscan path, and the established front selectors keep
-- resolving exactly as before. Assertions are selector relationships and
-- frame relationships, never committed commercial pixels.

local Assert = require("tests.support.Assert")
local MonCache = require("libs.assets.src.MonCache")
local MonPresentationCompiler = require("romdump.src.digest.mons.MonPresentationCompiler")
local MonSources = require("romdump.src.config.MonSources")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local FRONT_FACING = 2
local BACK_FACING = 0

---@param romFs table
---@param narcAlias string
---@param memberId integer
---@return string member bytes
local function readSourceMember(romFs, narcAlias, memberId)
  local narc = assert(romFs:openNarc(narcAlias), "the dump opens archive " .. narcAlias)
  return assert(narc:readMember(memberId), narcAlias .. " member " .. memberId .. " is readable")
end

function T.back_picture_members_exist_apart_from_front_picture_members(romFs, versionId)
  for _, speciesKey in ipairs({ "CHIKORITA", "CYNDAQUIL", "TOTODILE" }) do
    local speciesId = assert(MonSources.speciesId(speciesKey), versionId .. ": " .. speciesKey .. " has a native id")
    local front = MonSources.portraitIds(speciesId, "male", FRONT_FACING, false, 0)
    local back = MonSources.portraitIds(speciesId, "male", BACK_FACING, false, 0)
    Assert.isTrue(
      back.charMemberId ~= front.charMemberId,
      versionId .. ": " .. speciesKey .. " back art lives in its own character member"
    )
    local frontBytes = readSourceMember(romFs, front.narc, front.charMemberId)
    local backBytes = readSourceMember(romFs, back.narc, back.charMemberId)
    Assert.isTrue(#frontBytes > 0 and #backBytes > 0, versionId .. ": " .. speciesKey .. " members are non-empty")
    Assert.isTrue(backBytes ~= frontBytes, versionId .. ": " .. speciesKey .. " back bytes are authored, not aliased")
  end
end

---@param name string
---@return boolean supported
local function hasBackFramesEntry()
  local ok, value = pcall(function()
    return MonPresentationCompiler.compileBackFrames
  end)
  return ok and type(value) == "function"
end

function T.back_selectors_resolve_to_authored_back_frames(romFs, versionId)
  local frontSelector = MonCache.portraitSelector("CHIKORITA", 0, "male", false)
  local backSelector = MonCache.portraitSelector("CHIKORITA", 0, "male", false, "back")
  Assert.isTrue(backSelector ~= frontSelector, versionId .. ": the back selector resolves apart from the front one")
  Assert.isTrue(
    hasBackFramesEntry(),
    versionId .. ": the portrait owner compiles back frames through its existing decode path"
  )
  local speciesId = assert(MonSources.speciesId("CHIKORITA"), versionId .. ": CHIKORITA has a native id")
  local front = assert(
    MonPresentationCompiler.compileFrontFrames(romFs, speciesId, 0, "male", false),
    versionId .. ": the front frames compile"
  )
  local back = assert(
    MonPresentationCompiler.compileBackFrames(romFs, speciesId, 0, "male", false),
    versionId .. ": the back frames compile"
  )
  Assert.equal(#back.frames, #front.frames, versionId .. ": back compilation keeps both frames")
  Assert.isTrue(back.width == 80 and back.height == 80, versionId .. ": back frames keep the 80x80 source geometry")
  local differs = false
  for index, frame in ipairs(back.frames) do
    if frame ~= front.frames[index] then
      differs = true
    end
  end
  Assert.isTrue(differs, versionId .. ": back pixels differ from front pixels instead of mirroring them")
  local backAgain = assert(
    MonPresentationCompiler.compileBackFrames(romFs, speciesId, 0, "male", false),
    versionId .. ": the back frames recompile"
  )
  for index, frame in ipairs(back.frames) do
    Assert.equal(backAgain.frames[index], frame, versionId .. ": back compilation is deterministic")
  end
end

-- The normalized R8/RGB555 sidecars equal an independent source decode
-- through both facing branches: the same NCGR/NCLR members unscanned
-- and nibble-split by the test's own implementation match the staged
-- index planes byte for byte, and every source palette word matches,
-- including index zero.
function T.staged_sidecars_match_an_independent_source_decode(romFs, versionId)
  local U32 = require("libs.codec.src.U32")
  local Rgb555 = require("libs.codec.src.Rgb555")
  local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
  local bit = require("bit")
  local speciesId = assert(MonSources.speciesId("CHIKORITA"), versionId .. ": CHIKORITA has a native id")
  local function decodeIndependent(facing)
    local ids = MonSources.portraitIds(speciesId, "male", facing, false, 0)
    local archive = assert(romFs:openNarc(ids.narc), versionId .. ": the portrait archive opens")
    local charMember = assert(archive:readMember(ids.charMemberId), versionId .. ": char member is readable")
    local char = assert(G2dDecoder.decodeChar(charMember, {}), versionId .. ": char decodes")
    Assert.equal(char.depth, 3, versionId .. ": the source is 4bpp")
    local palMember = assert(archive:readMember(ids.palMemberId), versionId .. ": palette member is readable")
    local palette = assert(G2dDecoder.decodePalette(palMember, {}), versionId .. ": palette decodes")
    Assert.equal(#palette.colors, 16, versionId .. ": the source palette carries sixteen colors")
    Assert.isTrue(#char.tiles == 6400, versionId .. ": the portrait payload has two frames")
    -- Independent unscan: the retail seed/mask recurrence over the
    -- decoded tile words, written separately from the producer path.
    local seed = string.byte(char.tiles, 1) + string.byte(char.tiles, 2) * 256
    local plain = {}
    for i = 0, 3199 do
      local word = string.byte(char.tiles, i * 2 + 1) + string.byte(char.tiles, i * 2 + 2) * 256
      local decodedWord = bit.bxor(word, seed % 65536)
      plain[#plain + 1] = string.char(decodedWord % 256, math.floor(decodedWord / 256) % 256)
      seed = U32.add(U32.mul(seed, 1103515245), 24691) % 4294967296
    end
    local unscanned = table.concat(plain)
    local frames = {}
    for frame = 0, 1 do
      local parts = {}
      for y = 0, 79 do
        for byteX = 0, 39 do
          local byte = string.byte(unscanned, y * 80 + frame * 40 + byteX + 1) or 0
          parts[#parts + 1] = string.char(byte % 16, math.floor(byte / 16))
        end
      end
      frames[#frames + 1] = table.concat(parts)
    end
    local words = {}
    for _, color in ipairs(palette.colors) do
      words[#words + 1] = Rgb555.encode(
        math.floor((color.r * 31 + 127) / 255),
        math.floor((color.g * 31 + 127) / 255),
        math.floor((color.b * 31 + 127) / 255)
      )
    end
    return frames, words
  end
  local frontFrames, frontWords = decodeIndependent(FRONT_FACING)
  local backFrames, backWords = decodeIndependent(BACK_FACING)
  local combos = {}
  for _, facing in ipairs({ FRONT_FACING, BACK_FACING }) do
    local ids = MonSources.portraitIds(speciesId, "male", facing, false, 0)
    combos[#combos + 1] = {
      narc = ids.narc,
      charMemberId = ids.charMemberId,
      palMemberId = ids.palMemberId,
      selectors = { facing == FRONT_FACING and "front" or "back" },
    }
  end
  local page = assert(
    MonPresentationCompiler.compilePage(romFs, "portraits", {
      pageId = 0,
      width = 640,
      height = 320,
      cell = 80,
      combos = combos,
      representative = {},
    }),
    versionId .. ": the facing page compiles"
  )
  Assert.equal(page.paletteCount, 2, versionId .. ": both facings stage")
  Assert.equal(#page.indicesR8, 640 * 320, versionId .. ": the staged index plane covers the page")
  for slot = 0, 1 do
    local expected = slot == 0 and frontFrames or backFrames
    for frame = 0, 1 do
      local cellNumber = slot * 2 + frame
      local col = cellNumber % 8
      local row = math.floor(cellNumber / 8)
      local parts = {}
      for y = 0, 79 do
        local base = ((row * 80 + y) * 640 + col * 80) + 1
        parts[#parts + 1] = string.sub(page.indicesR8, base, base + 79)
      end
      Assert.equal(
        table.concat(parts),
        expected[frame + 1],
        versionId .. ": staged slot " .. slot .. " frame " .. frame .. " matches the independent decode"
      )
    end
  end
  local expectedWords = { frontWords, backWords }
  for slot = 0, 1 do
    for word = 1, 16 do
      local at = (slot * 16 + word - 1) * 2 + 1
      local staged = string.byte(page.basePalettesRgb555, at)
        + string.byte(page.basePalettesRgb555, at + 1) * 256
      Assert.equal(
        staged,
        expectedWords[slot + 1][word],
        versionId .. ": staged slot " .. slot .. " palette word " .. word .. " matches, including index zero"
      )
    end
  end
end

function T.established_front_selectors_keep_resolving(romFs, versionId)
  Assert.equal(
    MonCache.portraitSelector("CHIKORITA", 0, "male", false),
    "CHIKORITA/f0/male/plain",
    versionId .. ": the established front spelling is unchanged"
  )
  local speciesId = assert(MonSources.speciesId("TOTODILE"), versionId .. ": TOTODILE has a native id")
  local frames = assert(
    MonPresentationCompiler.compileFrontFrames(romFs, speciesId, 0, "male", true),
    versionId .. ": the shiny front frames still compile"
  )
  Assert.equal(#frames.frames, 2, versionId .. ": front compilation keeps both frames")
end

return RomSuite.fromFacts(T)
