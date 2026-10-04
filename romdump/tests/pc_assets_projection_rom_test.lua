-- Source-projected PC geometry and timing from the canonical HGSS data.
-- Source: pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36,
-- asm/overlay_14.s and asm/overlay_109.s.

local Assert = require("tests.support.Assert")
local PngReader = require("tests.support.PngReader")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function countKeys(values)
  local count = 0
  for _ in pairs(values) do
    count = count + 1
  end
  return count
end

function T.source_projection_keeps_pc_geometry_and_animation_ticks(romFs, _)
  local loaded, PcAssetCompiler = pcall(require, "romdump.src.digest.ui.PcAssetCompiler")
  Assert.isTrue(loaded, "the PC source projection compiler is missing")
  local bundle = assert(PcAssetCompiler.compile(romFs), "the PC source projection compiles")
  local manifest = assert(bundle.manifest)

  local storage = assert(manifest.storage)
  Assert.isTrue(next(storage.backgrounds) ~= nil, "Storage backgrounds have required semantic records")
  Assert.isTrue(next(storage.ui) ~= nil, "Storage UI roles have required semantic records")
  local windowFrames = assert(storage.ui.windowFrames)
  Assert.equal(countKeys(windowFrames), 2, "Storage retains standard and accent frame strips")
  local framePixels = {}
  for _, style in ipairs({ "standard", "accent" }) do
    local banks = assert(windowFrames[style], "Storage text-window frame style resolves: " .. style)
    Assert.equal(countKeys(banks), 2, "each frame strip exposes both source palette banks")
    framePixels[style] = {}
    for _, bank in ipairs({ "paletteBank0", "paletteBank1" }) do
      local frame = assert(banks[bank], "Storage frame palette bank resolves: " .. style .. "/" .. bank)
      Assert.equal(frame.width, 96, "Storage frame style retains its twelve source cells: " .. style .. "/" .. bank)
      Assert.equal(frame.height, 8, "Storage frame atlas retains 8x8 tile row height: " .. style .. "/" .. bank)
      local width, height, rgba = PngReader.rgba(assert(bundle.assets[frame.image]))
      Assert.equal(width, 96, "Storage frame PNG retains its source tile strip width")
      Assert.equal(height, 8, "Storage frame PNG retains its source tile strip height")
      Assert.equal(#rgba, 96 * 8 * 4, "Storage frame PNG retains decoded pixel data")
      framePixels[style][bank] = rgba
    end
    Assert.isTrue(
      framePixels[style].paletteBank0 ~= framePixels[style].paletteBank1,
      "member65 local palette banks render distinct pixels for " .. style
    )
  end
  local markings = assert(storage.ui.markings)
  Assert.equal(countKeys(markings), 6, "Storage exposes six source marking bits")
  for bit = 0, 5 do
    local pair = assert(markings[bit], "Storage marking bit resolves: " .. bit)
    Assert.equal(countKeys(pair), 2, "each marking bit has clear and set visuals")
    local rendered = {}
    for _, state in ipairs({ "clear", "set" }) do
      local visual = assert(pair[state], "Storage marking state resolves: " .. bit .. "/" .. state)
      Assert.equal(visual.width, 8, "marking visuals preserve one source tile width")
      Assert.equal(visual.height, 8, "marking visuals preserve one source tile height")
      local width, height, rgba = PngReader.rgba(assert(bundle.assets[visual.image]))
      Assert.equal(width, 8, "marking PNG retains the decoded tile width")
      Assert.equal(height, 8, "marking PNG retains the decoded tile height")
      Assert.equal(#rgba, 8 * 8 * 4, "marking PNG retains every decoded source pixel")
      rendered[state] = rgba
    end
    Assert.isTrue(
      rendered.clear ~= rendered.set,
      "clear and set source tile IDs render distinct pixels for bit " .. bit
    )
  end
  local wallpaperMap = assert(storage.geometry.wallpaperMap)
  Assert.equal(wallpaperMap.width, 168, "wallpaper source map width in logical pixels")
  Assert.equal(wallpaperMap.height, 160, "wallpaper source map height in logical pixels")
  Assert.equal(wallpaperMap.columns, 21, "wallpaper source map tile columns")
  Assert.equal(wallpaperMap.rows, 20, "wallpaper source map tile rows")
  Assert.equal(wallpaperMap.tileIdWrap, 64, "wallpaper tile IDs wrap at the source BG tile limit")

  local mailbox = assert(manifest.mailbox)
  Assert.isTrue(next(mailbox.ui) ~= nil, "Mailbox UI roles have required semantic records")
  Assert.equal(mailbox.geometry.visibleLetters, 10, "Mailbox shows ten letters per page")

  local mail = assert(manifest.mail)
  Assert.equal(mail.geometry.iconSlots, 3, "stationery keeps its three source icon locations")
  Assert.isTrue(next(mail.geometry.iconLocations) ~= nil, "stationery icon locations are present")
  Assert.equal(#mail.geometry.iconLocations, 3, "all three stationery icon locations are retained")
  Assert.isTrue(next(mail.text) ~= nil, "Mail text templates are present")

  local photoAlbum = assert(manifest.photoAlbum)
  Assert.equal(countKeys(mailbox.ui.backgrounds), 1, "Mailbox source UI background roles are retained")
  Assert.equal(countKeys(photoAlbum.ui.backgrounds), 2, "Photo Album source background roles are retained")
  local sprites = assert(photoAlbum.ui.sprites)
  Assert.equal(#sprites, 5, "the source album creates five sprite roles")
  for spriteIndex, sprite in ipairs(sprites) do
    Assert.equal(sprite.animationSpeed, 0x1000, "album sprite animation speed " .. spriteIndex)
  end
  Assert.isFalse(sprites[1].initiallyAnimating, "album's first sprite starts with animation stopped")
  Assert.isFalse(sprites[2].initiallyVisible, "album's second sprite starts hidden")
  Assert.isTrue(sprites[5].initiallyAnimating, "album's fifth sprite starts animated")
  local animations = assert(photoAlbum.ui.animations)
  Assert.isTrue(next(manifest.sequences) ~= nil, "PC source animation sequences are present")
  Assert.equal(countKeys(animations), 10, "album member 3 carries ten source animations")
  local expectedDurations = {
    [0] = { 2 },
    [1] = { 2 },
    [2] = { 2 },
    [3] = { 2 },
    [4] = { 2 },
    [5] = { 2 },
    [6] = { 1, 1 },
    [7] = { 2 },
    [8] = { 1 },
    [9] = { 2, 2, 2, 2 },
  }
  local frameCount = 0
  local totalDuration = 0
  for animationId = 0, 9 do
    local animation = assert(animations[animationId], "album animation resolves: " .. animationId)
    local sequence = assert(manifest.sequences["photoAlbum.animation." .. animationId])
    Assert.isFalse(sequence.loop, "album forward animation is not a looping sequence " .. animationId)
    Assert.equal(#sequence.frames, #animation.frames, "album sequence frame links " .. animationId)
    local expected = expectedDurations[animationId]
    Assert.equal(#animation.frames, #expected, "album animation frame count " .. animationId)
    for frameIndex, duration in ipairs(expected) do
      local frame = animation.frames[frameIndex]
      Assert.equal(frame.duration, duration, "album animation tick count " .. animationId .. "/" .. frameIndex)
      Assert.notNil(frame.image, "album animation frame image " .. animationId .. "/" .. frameIndex)
      frameCount = frameCount + 1
      totalDuration = totalDuration + duration
    end
  end
  Assert.equal(frameCount, 14, "album member 3 has fourteen source frames")
  Assert.equal(totalDuration, 25, "album member 3 has twenty-five source ticks")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump", "rom_source" }
return suite
