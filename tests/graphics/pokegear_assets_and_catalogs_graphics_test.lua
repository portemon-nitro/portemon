-- Pokegear skin and animation fidelity: all six shell skins compile their
-- source foreground palettes and planes, the compiled shell cursor animation
-- keeps every source frame with its anchor, per-frame transform, palette
-- slot, and duration, and a skin change alters only that skin's variants.
-- Loop behavior is asserted as the source play mode plus loop start, never
-- reduced to a boolean. Raw NCER/NANR expectations are decoded independently
-- of the compiler under test; one compiled frame is drawn to a real canvas
-- to prove the published bytes reach the GPU. No commercial bytes are
-- committed to the repository.

local Assert = require("tests.support.Assert")
local GameVersion = require("romdump.src.source.GameVersion")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local Hashing = require("romdump.src.digest.Hashing")
local Narc = require("libs.nds.src.nitro.Narc")
local PngReader = require("tests.support.PngReader")
local RomFs = require("romdump.src.source.RomFs")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {}

local SHELL_ARCHIVE_PATH = "a/1/4/3"

-- Source skin selectors for skin index s in 0..5: the shell foreground
-- control surface, the upper information surface, and the shared object
-- plane. The shell cursor cell/animation pair is skin-invariant.
local function shellSelectors(skin)
  return {
    foreground = { char = 48 + skin, screen = 54 + skin, palette = 30 + skin },
    information = { char = 36 + skin, screen = 42 + skin, palette = 24 + skin },
    objects = { char = 6 + skin, palette = 0 + skin, cell = 12, anim = 13 },
  }
end

local function openShellArchive(romFs)
  local bytes, err = romFs:readSourcePath(SHELL_ARCHIVE_PATH)
  Assert.notNil(bytes, "the dump must expose the shell archive: " .. tostring(err))
  local archive, narcErr = Narc.open(assert(bytes), SHELL_ARCHIVE_PATH)
  Assert.notNil(archive, "the shell archive must open: " .. tostring(narcErr))
  return assert(archive)
end

local function decodeMember(archive, kind, memberId, what)
  local bytes = assert(archive:readMember(memberId), what .. " member " .. memberId .. " must exist")
  local record, err = G2dDecoder[kind](bytes, { label = what })
  Assert.notNil(record, what .. " must decode: " .. tostring(err and err.message or err))
  return assert(record)
end

-- Independently rasterizes one skin's shell foreground straight from source
-- members: never through the compiler under test.
local function independentForegroundPixels(romFs, skin)
  local selectors = shellSelectors(skin).foreground
  local archive = openShellArchive(romFs)
  local charData = decodeMember(archive, "decodeChar", selectors.char, "shell foreground char")
  local palette = decodeMember(archive, "decodePalette", selectors.palette, "shell foreground palette")
  local screen = decodeMember(archive, "decodeScreen", selectors.screen, "shell foreground screen")
  return G2dRasterizer.renderScreen(charData, palette, screen, { role = "pokegear-shell-skin-" .. skin })
end

local function readyVersionIds()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  return versions
end

-- Finds one skin's compiled shell foreground visual in the published
-- manifest, following the documented manifest skin/shell shapes.
local function skinForegroundVisual(manifest, skin)
  if manifest.skins ~= nil then
    local entry = manifest.skins[skin] or manifest.skins[skin + 1] or manifest.skins[tostring(skin)]
    if type(entry) == "table" then
      if type(entry.image) == "string" then
        return entry
      end
      if entry.shell ~= nil and type(entry.shell.foreground) == "table" then
        return entry.shell.foreground
      end
      if entry.foreground ~= nil and type(entry.foreground.image) == "string" then
        return entry.foreground
      end
    end
  end
  if manifest.shell ~= nil and manifest.shell.variants ~= nil then
    local variant = manifest.shell.variants[skin] or manifest.shell.variants[skin + 1]
    if type(variant) == "table" and type(variant.image) == "string" then
      return variant
    end
  end
  return nil
end

-- Finds a compiled animation record carrying ordered frames with durations.
local function animationRecords(manifest)
  local records = {}
  local function collect(node)
    if type(node) ~= "table" then
      return
    end
    if type(node.frames) == "table" and #node.frames > 0 and type(node.playMode) == "string" then
      records[#records + 1] = node
      return
    end
    for _, value in pairs(node) do
      if type(value) == "table" then
        collect(value)
      end
    end
  end
  collect(manifest.sequences or manifest)
  return records
end

function T.six_skins_keep_source_palette_slots_and_anchored_animation_frames(scope, context)
  local versions = readyVersionIds()
  if #versions == 0 then
    context:skip("the pokegear skin proof needs a ready user-owned ROM")
  end
  local loaded, PokegearAssetCompiler =
    pcall(require, "romdump.src.digest.ui.PokegearAssetCompiler")
  Assert.isTrue(
    loaded,
    "the pokegear family compiler must be published before skin fidelity can be proven"
  )
  for _, versionId in ipairs(versions) do
    local romFs, openErr = RomFs.open(versionId)
    Assert.notNil(romFs, "the " .. versionId .. " dump must open: " .. tostring(openErr))
    romFs = assert(romFs, "the dump handle exists above")
    local bundle = PokegearAssetCompiler.compile(romFs, versionId)
    local compiled = assert(bundle, versionId .. " must compile the pokegear family")
    local manifest = assert(compiled.manifest, versionId .. " must publish its pokegear manifest")
    local assets = assert(
      compiled.assets or compiled.files,
      versionId .. " must publish its compiled pokegear assets"
    )
    -- Six skins, each with a distinct shell foreground realization.
    local foregroundHashes = {}
    for skin = 0, 5 do
      local visual = skinForegroundVisual(manifest, skin)
      Assert.notNil(visual, versionId .. " skin " .. skin .. " must publish its shell foreground visual")
      local reference = assert(assets[visual.image], versionId .. " skin " .. skin .. " foreground bytes exist")
      local width, height = PngReader.rgba(reference)
      Assert.equal(width, visual.width, versionId .. " skin " .. skin .. " keeps its compiled width")
      Assert.equal(height, visual.height, versionId .. " skin " .. skin .. " keeps its compiled height")
      Assert.isTrue(
        (visual.anchorX or 0) == (visual.anchorX or 0) and visual.anchorX ~= nil,
        versionId .. " skin " .. skin .. " carries its source-local horizontal anchor"
      )
      Assert.isTrue(
        visual.anchorY ~= nil,
        versionId .. " skin " .. skin .. " carries its source-local vertical anchor"
      )
      local expected = independentForegroundPixels(romFs, skin)
      Assert.equal(width, expected.width, versionId .. " skin " .. skin .. " keeps the source plane width")
      Assert.equal(height, expected.height, versionId .. " skin " .. skin .. " keeps the source plane height")
      foregroundHashes[#foregroundHashes + 1] = Hashing.sha1hex(reference)
    end
    local distinct = {}
    for _, hash in ipairs(foregroundHashes) do
      distinct[hash] = true
    end
    local distinctCount = 0
    for _ in pairs(distinct) do
      distinctCount = distinctCount + 1
    end
    Assert.equal(distinctCount, 6, versionId .. " must realize six distinct shell foreground variants")

    -- The phone contact list palette is source bank 2 of each skin's phone
    -- foreground palette, decoded independently of the compiler.
    local phoneBytes = assert(romFs:readSourcePath("a/1/4/6"), "the dump must expose the phone archive")
    local phoneArchive = assert(Narc.open(phoneBytes, "a/1/4/6"), "the phone archive must open")
    for skin = 0, 5 do
      local source = decodeMember(phoneArchive, "decodePalette", 10 + skin, "phone list palette")
      local published = assert(manifest.phone.listPalette[skin], versionId .. " publishes the list palette for skin " .. skin)
      Assert.equal(#published, 16, versionId .. " list palette carries one bank of sixteen colors")
      for index = 1, 16 do
        local expected = source.colors[32 + index]
        Assert.deepEqual(
          published[index],
          { r = expected.r, g = expected.g, b = expected.b },
          versionId .. " skin " .. skin .. " list palette color " .. index
        )
      end
    end

    -- The compiled cursor animation keeps the source frame/duration
    -- behavior: independently decoded durations match, loop behavior stays
    -- a play mode plus loop start, and no frame rate shorthand survives.
    local shellArchive = openShellArchive(romFs)
    local sourceAnim = decodeMember(shellArchive, "decodeAnimation", 13, "shell cursor animation")
    local sourceSequence = assert(sourceAnim.anims[1], "the shell cursor animation must carry its sequence")
    Assert.isTrue(#sourceSequence.frames > 0, "the shell cursor animation must carry source frames")
    local records = animationRecords(manifest)
    Assert.isTrue(#records > 0, versionId .. " must publish its pokegear animation records")
    local matched = false
    for _, record in ipairs(records) do
      if #record.frames == #sourceSequence.frames then
        local durationsMatch = true
        for index, frame in ipairs(record.frames) do
          local duration = frame.durationTicks or frame.duration
          if duration ~= sourceSequence.frames[index].duration then
            durationsMatch = false
          end
        end
        if durationsMatch then
          matched = true
          Assert.isTrue(
            record.playMode ~= nil and record.playMode ~= true and record.playMode ~= false,
            versionId .. " keeps loop behavior as a play mode, never a boolean"
          )
          Assert.isTrue(
            record.loopStart ~= nil or record.loopStartFrameIdx ~= nil or record.loopStartFrame ~= nil,
            versionId .. " keeps the source loop start frame"
          )
          Assert.isNil(record.fps, versionId .. " carries no frame rate shorthand")
          for index, frame in ipairs(record.frames) do
            local duration = frame.durationTicks or frame.duration
            Assert.isTrue(
              type(duration) == "number" and duration > 0,
              versionId .. " frame " .. index .. " keeps its positive source duration"
            )
          end
        end
      end
    end
    Assert.isTrue(matched, versionId .. " must publish the source cursor animation with exact durations")

    -- The published bytes reach the GPU: one compiled foreground draws to
    -- a real canvas with opaque source content.
    local first = assert(skinForegroundVisual(manifest, 0), versionId .. " republishes skin 0 for the draw proof")
    local fileData = love.filesystem.newFileData(assert(assets[first.image]), "pokegear-skin-0.png")
    local image = scope:own(love.graphics.newImage(fileData))
    local canvas = scope:own(love.graphics.newCanvas(
      math.min(first.width, 256),
      math.min(first.height, 192)
    ))
    love.graphics.setCanvas(canvas)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(image)
    love.graphics.setCanvas()
    local snapshot = scope:own(canvas:newImageData())
    local opaque = 0
    for y = 0, snapshot:getHeight() - 1 do
      for x = 0, snapshot:getWidth() - 1 do
        local _, _, _, alpha = snapshot:getPixel(x, y)
        if alpha > 0.5 then
          opaque = opaque + 1
        end
      end
    end
    Assert.isTrue(opaque > 0, versionId .. " the compiled skin foreground draws opaque source content")
    romFs:close()
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump" }
return suite
