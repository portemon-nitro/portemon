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
