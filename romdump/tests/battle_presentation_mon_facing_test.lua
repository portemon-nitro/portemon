-- Back-facing portraits through the existing mon presentation owner:
-- facing-aware planning keeps front selectors stable, back selectors
-- resolve to distinct authored visuals, true source aliases share slots,
-- and page compilation packs the back pixels the selector names. Fixtures
-- are synthetic with distinct front/back payloads; the ROM suite proves
-- the same entry points against authored dump members.

local Assert = require("tests.support.Assert")
local MonCache = require("libs.assets.src.MonCache")
local MonPresentationCompiler = require("romdump.src.digest.mons.MonPresentationCompiler")
local MonSources = require("romdump.src.config.MonSources")

local T = {}

local FRONT_FACING = 2
local BACK_FACING = 0

local function u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end

local function u32(v)
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

local function container(magic, blocks)
  local body = table.concat(blocks)
  return magic
    .. string.char(0xFF, 0xFE)
    .. u16(0x0100)
    .. u32(0x10 + #body)
    .. u16(0x10)
    .. u16(#blocks)
    .. body
end

local function block(magic, payload)
  return magic:reverse() .. u32(8 + #payload) .. payload
end

local function charContainer(tiles)
  local payload = u16(8) .. u16(0x20) .. u32(3) .. u16(0) .. u16(0) .. u32(0) .. u32(#tiles) .. u32(0x18) .. tiles
  return container("RGCN", { block("CHAR", payload) })
end

local function paletteContainer()
  local parts = {}
  for i = 0, 15 do
    parts[#parts + 1] = u16(i * 0x111)
  end
  local payload = string.char(3, 0) .. u16(16) .. u32(0) .. u32(12) .. table.concat(parts)
  return container("NCLR", { block("PLTT", payload) })
end

-- Two distinct 6400-byte payloads with different seeds and words, so the
-- retail unscan yields distinct front and back pixels from the same
-- producer path.
local function payloadBytes(seed0, step)
  local parts = {}
  for i = 1, 3200 do
    local word = (seed0 + i * step) % 65536
    parts[#parts + 1] = string.char(word % 256, math.floor(word / 256) % 256)
  end
  return table.concat(parts)
end

local function catalog()
  return {
    version = { id = "heartgold", language = "english" },
    species = {
      CHIKORITA = { forms = { [0] = {} } },
      CYNDAQUIL = { forms = { [0] = {} } },
      TOTODILE = { forms = { [0] = {} } },
      UNOWN = { forms = { [1] = {}, [5] = {} } },
      ROTOM = { forms = { [1] = {}, [5] = {} } },
      EGG = { forms = { [0] = {} } },
    },
  }
end

-- Minimal shared icon inputs behind plan: the 256-color bank, the
-- two-frame animation, the two shared cells, and one tile run for every
-- naix member the test catalog selects.
local function iconMembers()
  local paletteWords = {}
  for _ = 1, 256 do
    paletteWords[#paletteWords + 1] = u16(0x7FFF)
  end
  local palettePayload = string.char(3, 0) .. u16(256) .. u32(0) .. u32(12) .. table.concat(paletteWords)
  local frames = { { duration = 6, cell = 0 }, { duration = 6, cell = 1 } }
  local header = u16(1)
    .. u16(#frames)
    .. u32(0x18)
    .. u32(0x18 + 16)
    .. u32(0x18 + 16 + 8 * #frames)
    .. string.rep("\0", 8)
  local entry = u32(#frames) .. u16(0) .. u16(1) .. u32(1) .. u32(0)
  local frameBlocks, frameData = {}, {}
  for i, frame in ipairs(frames) do
    frameBlocks[#frameBlocks + 1] = u32((i - 1) * 2) .. u16(frame.duration) .. u16(0)
    frameData[#frameData + 1] = u16(frame.cell)
  end
  local animPayload = header .. entry .. table.concat(frameBlocks) .. table.concat(frameData)
  local cellEntries = u16(1) .. u16(0) .. u32(0) .. u16(1) .. u16(0) .. u32(6)
  local cellAttrs = (u16(0) .. u16(0) .. u16(0)):rep(2)
  local cellPayload = u16(2) .. u16(0) .. u32(0x18) .. u32(0) .. string.rep("\0", 12) .. cellEntries .. cellAttrs
  return {
    [0] = container("NCLR", { block("PLTT", palettePayload) }),
    [1] = container("RNAN", { block("ABNK", animPayload) }),
    [2] = container("RECN", { block("CEBK", cellPayload) }),
  }
end

local function romFs()
  local members = { pokemon_graphics = {}, pokemon_graphics_other = {} }
  for key, species in pairs(catalog().species) do
    local speciesId = assert(MonSources.speciesId(key))
    for formId in pairs(species.forms) do
      for _, gender in ipairs({ "male", "female" }) do
        for _, facing in ipairs({ FRONT_FACING, BACK_FACING }) do
          local ids = MonSources.portraitIds(speciesId, gender, facing, false, formId)
          local store = members[ids.narc]
          if store then
            local seed = facing == BACK_FACING and 0xBEEF or 0x0102
            store[ids.charMemberId] = charContainer(payloadBytes(seed, speciesId + formId + 7))
          end
        end
        for _, shiny in ipairs({ false, true }) do
          local ids = MonSources.portraitIds(speciesId, gender, FRONT_FACING, shiny, formId)
          local store = members[ids.narc]
          if store then
            store[ids.palMemberId] = paletteContainer()
          end
        end
      end
    end
  end
  local icons = iconMembers()
  local iconTiles = charContainer(string.rep(string.char(0x11), 1024))
  local fs = {}
  function fs:openNarc(alias)
    if alias == "pokemon_icons" then
      local archive = {}
      function archive:readMember(memberId)
        return icons[memberId] or iconTiles
      end
      return archive
    end
    local store = members[alias] or {}
    local archive = {}
    function archive:readMember(memberId)
      return store[memberId]
    end
    return archive
  end
  return fs
end

function T.front_selectors_keep_their_established_spelling()
  Assert.equal(
    MonCache.portraitSelector("CHIKORITA", 0, "male", false),
    "CHIKORITA/f0/male/plain",
    "the front default spelling is unchanged"
  )
  Assert.equal(
    MonCache.portraitSelector("CHIKORITA", 0, "male", false, "front"),
    "CHIKORITA/f0/male/plain",
    "an explicit front mark matches the default"
  )
end

function T.plan_enumerates_back_selectors_apart_from_front_selectors()
  local planned = assert(MonPresentationCompiler.plan(romFs(), catalog()))
  local front = assert(
    planned.portraits.entries["CHIKORITA/f0/male/plain"],
    "the established front selector stays planned"
  )
  local back = assert(
    planned.portraits.entries["CHIKORITA/f0/male/plain/back"],
    "the back selector plans through the same owner"
  )
  Assert.isTrue(
    front.pageId ~= back.pageId or front.x ~= back.x or front.y ~= back.y,
    "distinct front/back source tuples keep distinct page slots"
  )
end

function T.true_source_aliases_share_one_page_slot()
  -- Eggs resolve to the same members in both facings, so both selectors
  -- alias one visual instead of allocating a fake second sprite.
  local planned = assert(MonPresentationCompiler.plan(romFs(), catalog()))
  local front = assert(planned.portraits.entries["EGG/f0/male/plain"], "the egg front selector stays planned")
  local back = assert(planned.portraits.entries["EGG/f0/male/plain/back"], "the egg back selector stays planned")
  Assert.deepEqual(
    { back.pageId, back.x, back.y },
    { front.pageId, front.x, front.y },
    "selectors sharing a source tuple share one page slot"
  )
end

function T.back_frames_differ_from_front_frames_and_stay_deterministic()
  local fs = romFs()
  local speciesId = assert(MonSources.speciesId("CHIKORITA"))
  local front = assert(MonPresentationCompiler.compileFrontFrames(fs, speciesId, 0, "male", false))
  local back = assert(MonPresentationCompiler.compileBackFrames(fs, speciesId, 0, "male", false))
  Assert.equal(back.width, 80, "back frames keep the 80-wide source geometry")
  Assert.equal(back.height, 80, "back frames keep the 80-high source geometry")
  Assert.equal(#back.frames, 2, "back compilation keeps both frames")
  local differs = false
  for index, frame in ipairs(back.frames) do
    if frame ~= front.frames[index] then
      differs = true
    end
  end
  Assert.isTrue(differs, "back pixels differ from front pixels instead of mirroring them")
  local again = assert(MonPresentationCompiler.compileBackFrames(fs, speciesId, 0, "male", false))
  for index, frame in ipairs(back.frames) do
    Assert.equal(again.frames[index], frame, "back compilation is deterministic")
  end
end

local function subRect(pixels, width, x, y, w, h)
  local parts = {}
  for row = 0, h - 1 do
    local base = ((y + row) * width + x) * 4
    parts[#parts + 1] = pixels:sub(base + 1, base + w * 4)
  end
  return table.concat(parts)
end

function T.back_pages_pack_the_pixels_their_selectors_name()
  local fs = romFs()
  local planned = assert(MonPresentationCompiler.plan(fs, catalog()))
  local selector = "TOTODILE/f0/male/plain/back"
  local entry = assert(planned.portraits.entries[selector], selector .. " stays planned")
  local pagePlan = assert(planned.portraitPages[entry.pageId], "the back entry names its page plan")
  local page = assert(MonPresentationCompiler.compilePage(fs, "portraits", pagePlan))
  local speciesId = assert(MonSources.speciesId("TOTODILE"))
  local back = assert(MonPresentationCompiler.compileBackFrames(fs, speciesId, 0, "male", false))
  Assert.equal(
    subRect(page.pixels, page.width, entry.x, entry.y, entry.width, entry.height),
    back.frames[1],
    "the planned back slot packs the compiled back pixels"
  )
end

return { tests = T }
