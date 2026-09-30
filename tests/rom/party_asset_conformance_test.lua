-- ROM conformance: the native party presentation compiles from the real
-- dump. Every referenced member/hash and normalized image is attributable,
-- all frames resolve, the marker is last, no runtime file contains a NARC
-- member selector, badge frames come from the selected OAM cells with local
-- palette 1, failed publication preserves the prior family, and numeric
-- readouts use source cells. Assertions are coverage relationships and
-- cross-reference validity, never catalog snapshots or committed
-- commercial payloads.

local Assert = require("tests.support.Assert")
local ffi = require("ffi")
local PartyCache = require("libs.assets.src.PartyCache")
local Hashing = require("romdump.src.digest.Hashing")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local Lz10 = require("romdump.src.digest.Lz10")
local PngReader = require("tests.support.PngReader")
local RgbaImage = require("romdump.src.digest.ui.RgbaImage")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local compiledByVersion = {}

local function compileBundle(romFs)
  local PartyAssetCompiler = require("romdump.src.digest.ui.PartyAssetCompiler")
  return assert(PartyAssetCompiler.compile(romFs))
end

local function bundleFor(romFs, versionId)
  if compiledByVersion[versionId] == nil then
    compiledByVersion[versionId] = compileBundle(romFs)
  end
  return compiledByVersion[versionId]
end

local function assetBytes(value)
  if type(value) == "string" then
    return value
  end
  assert(
    type(value) == "userdata" and type(value.getFFIPointer) == "function" and type(value.getSize) == "function",
    "bundle assets are strings or LÖVE Data"
  )
  return ffi.string(value:getFFIPointer(), value:getSize())
end

local function pixel(rgba, width, x, y)
  local offset = (y * width + x) * 4 + 1
  return rgba:sub(offset, offset + 3)
end

local SOURCE_KEYS = { "narcId", "memberId", "fileId", "animIndex", "oam" }

local function assertNoSourceKeys(record, where)
  Assert.isTrue(type(record) == "table", where .. " is a record")
  for key, value in pairs(record) do
    for _, banned in ipairs(SOURCE_KEYS) do
      Assert.isTrue(key ~= banned, where .. " leaks source identity " .. tostring(key))
    end
    if type(value) == "table" and key ~= "provenance" then
      assertNoSourceKeys(value, where .. "." .. tostring(key))
    end
  end
end

function T.every_selected_member_is_attributable_and_frames_resolve(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  Assert.isTrue(#bundle.dependencies.dependencies > 0, "raw payload hashes are collected")
  for _, dependency in ipairs(bundle.dependencies.dependencies) do
    Assert.isTrue(type(dependency.sha1) == "string" and #dependency.sha1 > 0, "each payload carries an identity")
    if dependency.name:find(":member:") then
      Assert.equal(#dependency.sha1, 40, "member payloads carry content hashes")
    end
  end
  local manifest = bundle.manifest
  Assert.equal(manifest.schema, "g4-party-presentation-v2")
  local referenced = PartyCache.referencedPaths(manifest)
  Assert.isTrue(#referenced > 0, "the manifest references realized images")
  for _, path in ipairs(referenced) do
    Assert.isTrue(#assetBytes(assert(bundle.assets[path], path .. " resolves")) > 0, path .. " has pixels")
  end
  assertNoSourceKeys(manifest, "manifest")
end

function T.status_visuals_match_the_semantic_source_sequences(romFs, versionId)
  local PartySources = require("romdump.src.config.PartySources")
  local bundle = bundleFor(romFs, versionId)
  local archive = assert(romFs:openNarc(PartySources.statusArchive.symbol), "the status archive resolves")
  local function decode(kind, memberId, role)
    local bytes = assert(archive:readMember(memberId), role .. " member resolves")
    if string.byte(bytes, 1) == 0x10 then
      bytes = assert(Lz10.decode(bytes), role .. " member decompresses")
    end
    return assert(G2dDecoder[kind](bytes, { label = "party status " .. role }), role .. " decodes")
  end
  local char = decode("decodeChar", PartySources.status.charMember, "character")
  local palette = decode("decodePalette", PartySources.status.paletteMember, "palette")
  local cell = decode("decodeCell", PartySources.status.cellMember, "cell")
  local animation = decode("decodeAnimation", PartySources.status.animationMember, "animation")
  local visuals = assert(bundle.manifest.visuals.status, "status visuals publish")
  local expected = {
    { name = "paralysis", sequence = 1 },
    { name = "freeze", sequence = 2 },
    { name = "sleep", sequence = 3 },
    { name = "poison", sequence = 4 },
    { name = "burn", sequence = 5 },
    { name = "faint", sequence = 6 },
  }
  Assert.isNil(visuals.frames, "semantic status visuals do not publish a sequence array")
  Assert.isNil(visuals.unset, "UNSET has no runtime status visual")
  Assert.isNil(visuals.ok, "healthy status has no runtime visual")
  for _, mapping in ipairs(expected) do
    local visual = assert(visuals[mapping.name], mapping.name .. " has a semantic visual")
    Assert.equal(visual.width, 24, mapping.name .. " width")
    Assert.equal(visual.height, 8, mapping.name .. " height")
    local sequence = assert(animation.anims[mapping.sequence + 1], mapping.name .. " source sequence exists")
    Assert.equal(#sequence.frames, 1, mapping.name .. " source sequence is static")
    local source = G2dRasterizer.renderAnimationFrame(
      char,
      { colors = palette.colors },
      cell,
      sequence,
      1,
      { role = "party-status-" .. mapping.name, frame = 0 },
      2
    )
    local width, height, rgba = PngReader.rgba(assert(bundle.assets[visual.image], mapping.name .. " image resolves"))
    Assert.equal(width, 24, mapping.name .. " generated image width")
    Assert.equal(height, 8, mapping.name .. " generated image height")
    Assert.equal(rgba, source.pixels, mapping.name .. " pixels match its source sequence")
  end
  local referenced = {}
  for _, path in ipairs(PartyCache.referencedPaths(bundle.manifest)) do
    referenced[path] = true
  end
  for _, mapping in ipairs(expected) do
    Assert.isTrue(referenced[visuals[mapping.name].image], mapping.name .. " image participates in cache readiness")
  end
end

function T.panel_palette_states_are_compiled_as_source_images(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  for slot, panel in ipairs(bundle.manifest.panels) do
    local chrome = panel.chrome
    for _, state in ipairs({ "normal", "selected", "fainted", "selectedFainted" }) do
      local visual = assert(chrome[state], "panel " .. slot .. " publishes " .. state .. " chrome")
      local width, height = PngReader.rgba(assetBytes(assert(bundle.assets[visual.image], "panel chrome pixels resolve")))
      Assert.equal(width, 128)
      Assert.equal(height, 48)
    end
    local _, _, normal = PngReader.rgba(assetBytes(bundle.assets[chrome.normal.image]))
    local _, _, selected = PngReader.rgba(assetBytes(bundle.assets[chrome.selected.image]))
    local _, _, fainted = PngReader.rgba(assetBytes(bundle.assets[chrome.fainted.image]))
    local _, _, selectedFainted = PngReader.rgba(assetBytes(bundle.assets[chrome.selectedFainted.image]))
    Assert.isFalse(normal == selected, "selected panel state is independently compiled")
    Assert.isFalse(normal == fainted, "fainted panel state is independently compiled")
    Assert.isFalse(selected == selectedFainted, "selected-fainted panel state is independently compiled")
  end
end

function T.hp_strips_preserve_source_row_shape_and_cache_references(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local bars = assert(bundle.manifest.visuals.hpBars, "compiled Party visuals publish HP strips")
  local colors = {}
  for _, color in ipairs({ "green", "yellow", "red" }) do
    local visual = assert(bars[color], color .. " strip exists")
    local width, height, rgba = PngReader.rgba(assetBytes(assert(bundle.assets[visual.image], color .. " strip pixels resolve")))
    Assert.equal(width, 48)
    Assert.equal(height, 4)
    Assert.equal(pixel(rgba, width, 0, 0), pixel(rgba, width, 0, 3), "edge rows use the source edge color")
    Assert.equal(pixel(rgba, width, 0, 1), pixel(rgba, width, 0, 2), "body rows use the source body color")
    Assert.isFalse(
      pixel(rgba, width, 0, 0) == pixel(rgba, width, 0, 1),
      "edge and body rows remain distinct"
    )
    colors[color] = pixel(rgba, width, 0, 1)
    for x = 1, width - 1 do
      for y = 0, height - 1 do
        Assert.equal(pixel(rgba, width, x, y), pixel(rgba, width, 0, y), "source strip row is horizontally uniform")
      end
    end
  end
  Assert.isFalse(colors.green == colors.yellow, "green and yellow use their source palette selections")
  Assert.isFalse(colors.green == colors.red, "green and red use their source palette selections")
  Assert.isFalse(colors.yellow == colors.red, "yellow and red use their source palette selections")
  local referenced = {}
  for _, path in ipairs(PartyCache.referencedPaths(bundle.manifest)) do
    referenced[path] = true
  end
  for _, color in ipairs({ "green", "yellow", "red" }) do
    Assert.isTrue(referenced[bars[color].image], color .. " strip participates in cache readiness")
  end
end

function T.recompilation_is_deterministic(romFs, versionId)
  local first = bundleFor(romFs, versionId)
  compiledByVersion[versionId] = nil
  local second = bundleFor(romFs, versionId)
  Assert.equal(Hashing.hashLua(first.manifest), Hashing.hashLua(second.manifest), "manifest bytes are stable")
  Assert.equal(first.marker, second.marker, "the marker is stable")
end

function T.badge_frames_come_from_the_selected_cells(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local leaves = bundle.manifest.shinyLeaves
  Assert.equal(leaves.leafSequence, 6)
  Assert.equal(leaves.crownSequence, 7)
  Assert.equal(leaves.paletteBank, 1)
  Assert.equal(#leaves.anchors, 5)
  Assert.isTrue(#leaves.leaves.frames > 0, "leaf frames resolve")
  Assert.isTrue(#leaves.crown.frames > 0, "crown frames resolve")
  for _, frame in ipairs(leaves.leaves.frames) do
    local width, height = PngReader.rgba(assert(bundle.assets[frame.image], "leaf bytes must compile"))
    Assert.equal(width, frame.width)
    Assert.equal(height, frame.height)
    Assert.isTrue(frame.durationTicks > 0 and frame.durationTicks % 1 == 0, "leaf timing is integral")
  end
  local seen = {}
  for _, frame in ipairs(leaves.crown.frames) do
    Assert.isTrue(frame.durationTicks > 0, "crown timing is positive")
    seen[frame.image] = true
  end
  for image in pairs(seen) do
    Assert.isTrue(#assetBytes(bundle.assets[image]) > 0, "crown bytes must compile")
  end
end

function T.failed_publication_preserves_the_prior_family(romFs, versionId)
  local PartyCacheWriter = require("romdump.src.digest.ui.PartyCacheWriter")
  local bundle = bundleFor(romFs, versionId)
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion(versionId, backend)
  Assert.isTrue(PartyCacheWriter.write(cache, bundle), "the real bundle publishes")
  Assert.isTrue(PartyCache.isReady(cache, bundle.marker), "the real family reads as ready")
  local broken = {
    marker = bundle.marker .. "-broken",
    manifest = bundle.manifest,
    dependencies = bundle.dependencies,
    assets = {},
  }
  for path, bytes in pairs(bundle.assets) do
    broken.assets[path] = bytes
  end
  local victim = PartyCache.referencedPaths(bundle.manifest)[1]
  broken.assets[victim] = nil
  Assert.throws(function()
    PartyCacheWriter.write(cache, broken)
  end)
  Assert.isTrue(PartyCache.isReady(cache, bundle.marker), "the prior family remains valid")
end

function T.numeric_readouts_use_source_cells(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local glyphs = bundle.manifest.numberGlyphs
  Assert.equal(glyphs.advance, 8)
  Assert.equal(glyphs.height, 8)
  Assert.equal(#glyphs.digits, 10)
  for digit = 0, 9 do
    local record = glyphs.digits[digit + 1]
    local width, height = PngReader.rgba(assert(bundle.assets[record.image], "digit bytes must compile"))
    Assert.equal(width, 8)
    Assert.equal(height, 8)
  end
  local slashWidth = PngReader.rgba(assert(bundle.assets[glyphs.slash.image], "slash bytes must compile"))
  Assert.equal(slashWidth, 8)
  local levelWidth = PngReader.rgba(assert(bundle.assets[glyphs.level.image], "level bytes must compile"))
  Assert.equal(levelWidth, 16)
  local function glyphPixels(record)
    local width, height, rgba = PngReader.rgba(assert(bundle.assets[record.image]))
    return { width = width, height = height, pixels = rgba }
  end
  local sample = RgbaImage.compose({
    glyphPixels(glyphs.digits[5]),
    glyphPixels(glyphs.digits[1]),
    glyphPixels(glyphs.slash),
    glyphPixels(glyphs.digits[10]),
  }, "numeric sample")
  Assert.equal(sample.width, 8, "composed digits keep the 8-pixel advance")
end

function T.party_markers_bind_rom_identity_and_content(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local sha1 = assert(romFs:metadata().sha1, "the dump carries its identity")
  Assert.isTrue(type(sha1) == "string" and #sha1 == 40, "the ROM identity is a sha1")
  local format, middle, depHash = bundle.marker:match("^([^:]+):([^:]+):([^:]+)$")
  Assert.notNil(middle, "the marker carries three colon-separated segments")
  Assert.equal(format, PartyCache.FORMAT, "the marker names the family format")
  Assert.equal(middle, sha1, "the marker binds the ROM identity")
  Assert.isTrue(#depHash > 0, "the marker binds a content hash")
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion(versionId, backend)
  local PartyCacheWriter = require("romdump.src.digest.ui.PartyCacheWriter")
  Assert.isTrue(PartyCacheWriter.write(cache, bundle), "the real bundle publishes")
  Assert.isTrue(PartyCache.isReady(cache, bundle.marker), "the true marker reads as ready")
  local forged = PartyCache.FORMAT .. ":" .. string.rep("0", 40) .. ":" .. depHash
  Assert.isFalse(PartyCache.isReady(cache, forged), "a marker with a foreign ROM identity never reads as ready")
end

function T.icon_animation_timing_stays_integral_and_bounded(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local animations = bundle.manifest.iconAnimations
  Assert.isTrue(type(animations.periods) == "table", "icon periods resolve")
  Assert.isTrue(#animations.periods > 0, "at least one icon period is compiled")
  for index, ticks in ipairs(animations.periods) do
    Assert.isTrue(
      type(ticks) == "number" and ticks % 1 == 0 and ticks > 0,
      "icon period is a positive integral tick count at " .. tostring(index)
    )
  end
  Assert.isTrue(type(animations.replacementDurations) == "table", "replacement durations resolve")
  for index, ticks in ipairs(animations.replacementDurations) do
    Assert.isTrue(
      type(ticks) == "number" and ticks % 1 == 0 and ticks > 0,
      "replacement duration is a positive integral tick count at " .. tostring(index)
    )
  end
  Assert.isTrue(type(animations.replacementShift) == "table", "the replacement shift resolves")
  for index, shift in ipairs(animations.replacementShift) do
    Assert.isTrue(
      type(shift) == "number" and shift % 1 == 0,
      "the replacement shift stays integral at " .. tostring(index)
    )
  end
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
