-- Dump-backed back-facing portraits: the real private dump carries true
-- back-picture members apart from the front-picture members, back
-- selectors resolve through the same native picture-selection owner and
-- the existing scan/unscan path, and the established front selectors keep
-- resolving exactly as before. Assertions are selector relationships and
-- frame relationships, never committed commercial pixels.

local Assert = require("tests.support.Assert")
local BattlePicturePass = require("libs.hgss.src.presentation.BattlePicturePass")
local MonCache = require("libs.assets.src.MonCache")
local MonPresentationCompiler = require("romdump.src.digest.mons.MonPresentationCompiler")
local MonSources = require("romdump.src.config.MonSources")
local BattlePresentationSources = require("romdump.src.config.BattlePresentationSources")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local U32 = require("libs.codec.src.U32")
local RomSuite = require("tests.rom.support.RomSuite")
local bit = require("bit")

local T = {}

local FRONT_FACING = 2
local BACK_FACING = 0
local PORTRAIT_BYTES = 6400
local readSourceMember

---@param colors table<integer, table<string, integer>> decoded palette colors
---@param index integer palette index
---@return string RGBA bytes
local function rgba(colors, index)
  if index == 0 then
    return "\0\0\0\0"
  end
  local color = assert(colors[index + 1], "portrait texel selects a palette entry")
  return string.char(color.r, color.g, color.b, 255)
end

---@param romFs table
---@param speciesId integer
---@param form integer
---@param gender string
---@param shiny boolean
---@param frame integer
---@return string independently decoded RGBA frame
local function decodePortraitFrame(romFs, speciesId, form, gender, shiny, frame)
  local selection = MonSources.portraitIds(speciesId, gender, FRONT_FACING, shiny, form)
  local charBytes = readSourceMember(romFs, selection.narc, selection.charMemberId)
  local paletteBytes = readSourceMember(romFs, selection.narc, selection.palMemberId)
  local characters = assert(G2dDecoder.decodeChar(charBytes, { label = "independent Pokepic characters" }))
  local palette = assert(G2dDecoder.decodePalette(paletteBytes, { label = "independent Pokepic palette" }))
  Assert.equal(characters.depth, 3, "Pokepic source characters are 4bpp")
  Assert.equal(#characters.tiles, PORTRAIT_BYTES, "Pokepic source carries two 80x80 frames")
  local seed = string.byte(characters.tiles, 1) + string.byte(characters.tiles, 2) * 256
  local plainBytes = {}
  for wordIndex = 0, PORTRAIT_BYTES / 2 - 1 do
    local offset = wordIndex * 2
    local word = string.byte(characters.tiles, offset + 1) + string.byte(characters.tiles, offset + 2) * 256
    local plain = bit.bxor(word, seed % 65536)
    plainBytes[#plainBytes + 1] = string.char(plain % 256, math.floor(plain / 256) % 256)
    seed = U32.add(U32.mul(seed, 1103515245), 24691)
  end
  local plain = table.concat(plainBytes)
  local pixels = {}
  for y = 0, 79 do
    local row = y * 80 + frame * 40
    for byteX = 0, 39 do
      local packed = string.byte(plain, row + byteX + 1)
      pixels[#pixels + 1] = rgba(palette.colors, packed % 16)
      pixels[#pixels + 1] = rgba(palette.colors, math.floor(packed / 16))
    end
  end
  return table.concat(pixels)
end

---@param romFs table
---@param narcAlias string
---@param memberId integer
---@return string member bytes
readSourceMember = function(romFs, narcAlias, memberId)
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

function T.native_picture_pass_preserves_rom_portrait_frames(romFs, versionId)
  local cases = {
    { species = "CHIKORITA", form = 0, gender = "female", shiny = false },
    { species = "UNOWN", form = 5, gender = "male", shiny = false },
    { species = "TOTODILE", form = 0, gender = "male", shiny = true },
  }
  local graphics = love.graphics
  local pass = BattlePicturePass.new(graphics)
  local handles = {}
  local ok, failure = pcall(function()
    for _, selection in ipairs(cases) do
      local speciesId = assert(MonSources.speciesId(selection.species), versionId .. ": species has a native source id")
      local heightArchiveSymbol, heightMemberId = BattlePresentationSources.pictureHeightSource(
        speciesId,
        selection.species,
        selection.form,
        FRONT_FACING,
        selection.gender
      )
      local sourceHeight = string.byte(readSourceMember(romFs, heightArchiveSymbol, heightMemberId), 1)
      Assert.isTrue(type(sourceHeight) == "number", versionId .. ": selected picture has a source height byte")
      local decoded = assert(
        MonPresentationCompiler.compileFrontFrames(
          romFs,
          speciesId,
          selection.form,
          selection.gender,
          selection.shiny
        ),
        versionId .. ": selected front portrait compiles"
      )
      for frameIndex = 0, 1 do
        local reference = decodePortraitFrame(
          romFs,
          speciesId,
          selection.form,
          selection.gender,
          selection.shiny,
          frameIndex
        )
        Assert.equal(decoded.frames[frameIndex + 1], reference, versionId .. ": decoded frame equals independent ROM decode")
        local expectedData = love.image.newImageData(80, 80, "rgba8")
        local actualPixels = decoded.frames[frameIndex + 1]
        local actualData = love.image.newImageData(80, 80, "rgba8")
        for y = 0, 79 do
          for x = 0, 79 do
            local offset = (y * 80 + x) * 4 + 1
            expectedData:setPixel(
              x,
              y,
              string.byte(reference, offset) / 255,
              string.byte(reference, offset + 1) / 255,
              string.byte(reference, offset + 2) / 255,
              string.byte(reference, offset + 3) / 255
            )
            actualData:setPixel(
              x,
              y,
              string.byte(actualPixels, offset) / 255,
              string.byte(actualPixels, offset + 1) / 255,
              string.byte(actualPixels, offset + 2) / 255,
              string.byte(actualPixels, offset + 3) / 255
            )
          end
        end
        local expectedImage = graphics.newImage(expectedData)
        local actualImage = graphics.newImage(actualData)
        handles[#handles + 1] = expectedData
        handles[#handles + 1] = actualData
        handles[#handles + 1] = expectedImage
        handles[#handles + 1] = actualImage
        expectedImage:setFilter("nearest", "nearest")
        actualImage:setFilter("nearest", "nearest")
        local expectedCanvas = pass:render(graphics, {
          {
            kind = "picture",
            image = expectedImage,
            centerX = 128,
            centerY = 96 - sourceHeight,
            zCenter = 0,
            width = 80,
            height = 80,
            tintR = 1,
            tintG = 1,
            tintB = 1,
            alpha = 1,
          },
        })
        local expected = expectedCanvas:newImageData()
        handles[#handles + 1] = expected
        local actualCanvas = pass:render(graphics, {
          {
            kind = "picture",
            image = actualImage,
            centerX = 128,
          centerY = 96 - sourceHeight,
            zCenter = 0,
            width = 80,
            height = 80,
            tintR = 1,
            tintG = 1,
            tintB = 1,
            alpha = 1,
          },
        })
        local actual = actualCanvas:newImageData()
        handles[#handles + 1] = actual
        for _, point in ipairs({ { 0, 0 }, { 19, 23 }, { 40, 40 }, { 79, 79 } }) do
          local screenX, screenY = point[1] + 88, point[2] + 56 - sourceHeight
          local expectedPixel = { expected:getPixel(screenX, screenY) }
          local actualPixel = { actual:getPixel(screenX, screenY) }
          Assert.deepEqual(
            actualPixel,
            expectedPixel,
            versionId .. ": native picture pass preserves source texel " .. point[1] .. "," .. point[2]
          )
        end
      end
    end
  end)
  for _, handle in ipairs(handles) do
    handle:release()
  end
  pass:release()
  if not ok then
    error(failure, 0)
  end
end

return RomSuite.fromFacts(T)
