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
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageTokenizer = require("romdump.src.digest.ui.FieldMessageTokenizer")
local charmap = require("romdump.src.reference.hgss.charmap")
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
  Assert.equal(manifest.schema, "g4-party-presentation-v3")
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

local function decodeArchiveMember(archive, memberId, kind, role)
  local bytes = assert(archive:readMember(memberId), role .. " member resolves")
  if string.byte(bytes, 1) == 0x10 then
    bytes = assert(Lz10.decode(bytes), role .. " member decompresses")
  end
  return assert(G2dDecoder[kind](bytes, { label = "party " .. role }), role .. " decodes")
end

local function layoutFor(section, count, className)
  local layout = section[count] or section[tostring(count)]
  Assert.notNil(layout, className .. " covers " .. count .. " entries")
  return layout
end

local function collectRgba(record)
  local colors = {}
  local function visit(value)
    if type(value) ~= "table" then
      return
    end
    if type(value.r) == "number" and type(value.g) == "number" and type(value.b) == "number" then
      Assert.isTrue(
        value.r % 1 == 0 and value.g % 1 == 0 and value.b % 1 == 0,
        "generated colors use integer channels"
      )
      Assert.isTrue(
        value.r >= 0 and value.r <= 255 and value.g >= 0 and value.g <= 255 and value.b >= 0 and value.b <= 255,
        "generated colors stay inside the byte range"
      )
      local alpha = value.a == nil and 255 or value.a
      Assert.isTrue(alpha % 1 == 0 and alpha >= 0 and alpha <= 255, "generated colors stay inside the byte range")
      colors[string.char(value.r, value.g, value.b, alpha)] = true
    else
      for _, nested in pairs(value) do
        visit(nested)
      end
    end
  end
  visit(record)
  return colors
end

local function assertPaneRect(record, where)
  Assert.notNil(record, where .. " publishes its rectangle")
  Assert.isTrue(record.width > 0 and record.height > 0, where .. " size is realized")
  Assert.isTrue(
    record.x >= 0 and record.y >= 0 and record.x + record.width <= 256 and record.y + record.height <= 192,
    where .. " fits the native pane"
  )
end

function T.icon_animation_timing_stays_integral_and_bounded(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local animations = bundle.manifest.iconAnimations
  Assert.isTrue(type(animations.sequences) == "table", "icon timelines resolve")
  Assert.equal(#animations.sequences, 6, "all six icon sequences carry timelines")
  for sequenceNo, timeline in ipairs(animations.sequences) do
    Assert.isTrue(#timeline > 0, "icon sequence " .. sequenceNo .. " carries frames")
    for frameIndex, record in ipairs(timeline) do
      local where = "icon sequence " .. sequenceNo .. " frame " .. frameIndex
      Assert.isTrue(
        type(record.durationTicks) == "number" and record.durationTicks % 1 == 0 and record.durationTicks > 0,
        where .. " timing is a positive integral tick count"
      )
      Assert.isTrue(
        type(record.translateX) == "number"
          and record.translateX % 1 == 0
          and type(record.translateY) == "number"
          and record.translateY % 1 == 0,
        where .. " translations stay integral"
      )
    end
  end
end

function T.icon_timelines_preserve_source_frame_cadence(romFs, versionId)
  local PartySources = require("romdump.src.config.PartySources")
  local bundle = bundleFor(romFs, versionId)
  local animations = bundle.manifest.iconAnimations
  Assert.notNil(animations, "the manifest publishes icon animation data")
  local timelines = animations.sequences
  Assert.notNil(timelines, "icon animation publishes exact per-frame timelines, not period totals alone")
  Assert.equal(#timelines, 6, "all six icon sequences carry timelines")
  local archive = assert(romFs:openNarc(PartySources.iconShared.archive), "the icon archive resolves")
  local animation =
    decodeArchiveMember(archive, PartySources.iconShared.animationMember, "decodeAnimation", "icon animation")
  Assert.equal(#animation.anims, 6, "six source icon sequences are addressable")
  local playbacks = { forward = "once", forward_loop = "loop", reverse = "once", reverse_loop = "loop" }
  local expectedPeriods = { 1, 8, 12, 24, 40, 36 }
  for sequenceNo = 1, 6 do
    local where = "icon sequence " .. (sequenceNo - 1)
    local timeline = timelines[sequenceNo]
    Assert.notNil(timeline, where .. " has a timeline")
    local source = animation.anims[sequenceNo]
    Assert.equal(#timeline, #source.frames, where .. " keeps every source frame")
    local total = 0
    for frameIndex, record in ipairs(timeline) do
      local frameWhere = where .. " frame " .. (frameIndex - 1)
      local sourceFrame = source.frames[frameIndex]
      Assert.isTrue(
        record.iconFrame == 1 or record.iconFrame == 2,
        frameWhere .. " references the two icon atlas frames"
      )
      Assert.isTrue(
        type(record.durationTicks) == "number" and record.durationTicks > 0 and record.durationTicks % 1 == 0,
        frameWhere .. " timing is a positive integer"
      )
      Assert.equal(record.durationTicks, sourceFrame.duration, frameWhere .. " keeps its source duration")
      Assert.equal(record.translateX, sourceFrame.translateX, frameWhere .. " keeps its source x translation")
      Assert.equal(record.translateY, sourceFrame.translateY, frameWhere .. " keeps its source y translation")
      Assert.isTrue(
        type(record.translateX) == "number"
          and record.translateX % 1 == 0
          and type(record.translateY) == "number"
          and record.translateY % 1 == 0,
        frameWhere .. " translations stay integral"
      )
      total = total + record.durationTicks
    end
    Assert.equal(total, expectedPeriods[sequenceNo], where .. " spans its source period")
    Assert.equal(timeline.loopFrom, source.loopStartFrameIdx + 1, where .. " preserves the source loop origin")
    if #source.frames == 1 then
      Assert.equal(timeline.playback, "static", where .. " single-frame playback stays static")
    else
      Assert.equal(timeline.playback, playbacks[source.playMode], where .. " preserves the source playback")
    end
  end
  local durations = {}
  local shifts = {}
  for _, record in ipairs(timelines[6]) do
    durations[#durations + 1] = record.durationTicks
    shifts[#shifts + 1] = record.translateX
  end
  Assert.deepEqual(durations, { 32, 2, 2 }, "the replacement sequence keeps its 32/2/2 keyframe durations")
  Assert.deepEqual(shifts, { 0, 1, -1 }, "the replacement sequence keeps its 0/+1/-1 shifts")
end

function T.panel_text_roles_resolve_from_the_source_window_palette(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local text = bundle.manifest.text
  Assert.notNil(text, "the manifest publishes party text")
  local roles = text.roles
  Assert.notNil(roles, "party text publishes its palette roles")
  local archive = assert(romFs:openNarc("NARC_graphic_plist_gra"), "the party archive resolves")
  local palette = decodeArchiveMember(archive, 16, "decodePalette", "party window palette")
  local sourceColors = {}
  for _, color in ipairs(palette.colors) do
    sourceColors[string.char(color.r, color.g, color.b, 255)] = true
  end
  local roleSets = {}
  for _, name in ipairs({ "ordinary", "male", "female" }) do
    local role = roles[name]
    Assert.notNil(role, "the " .. name .. " text role resolves")
    local colors = collectRgba(role)
    Assert.isTrue(next(colors) ~= nil, "the " .. name .. " role carries resolved colors")
    for pixel in pairs(colors) do
      Assert.isTrue(sourceColors[pixel], "the " .. name .. " role derives from the source window palette")
    end
    roleSets[name] = colors
  end
  local function distinct(first, second)
    for pixel in pairs(first) do
      if second[pixel] == nil then
        return true
      end
    end
    for pixel in pairs(second) do
      if first[pixel] == nil then
        return true
      end
    end
    return false
  end
  Assert.isTrue(distinct(roleSets.ordinary, roleSets.male), "ordinary and male roles stay distinct")
  Assert.isTrue(distinct(roleSets.ordinary, roleSets.female), "ordinary and female roles stay distinct")
  Assert.isTrue(distinct(roleSets.male, roleSets.female), "male and female roles stay distinct")
  assertNoSourceKeys(roles, "text.roles")
end

function T.numeric_fields_keep_their_source_window_origins(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local glyphs = bundle.manifest.numberGlyphs
  Assert.notNil(glyphs, "number glyphs resolve")
  local placement = glyphs.placement
  Assert.notNil(placement, "number glyphs publish their window-relative placement")
  Assert.deepEqual(placement.level, { x = 5, y = 2 }, "level numerals start inside the level window")
  Assert.deepEqual(placement.current, { x = 0, y = 2 }, "current HP begins at the HP window origin row")
  Assert.deepEqual(placement.slash, { x = 28, y = 2 }, "the HP slash keeps its source column")
  Assert.deepEqual(placement.max, { x = 36, y = 2 }, "max HP keeps its source column")
end

function T.gender_labels_and_message_windows_come_from_source(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local text = bundle.manifest.text
  Assert.notNil(text and text.labels, "party text publishes its labels")
  local messageArchive = assert(romFs:openNarc("NARC_msgdata_msg"), "the message archive resolves")
  local bankBytes = assert(messageArchive:readMember(300), "message bank 300 resolves")
  local bank = assert(FieldMessageBank.decode(bankBytes, { label = "party-message-bank-300" }))
  local function displayText(index)
    local message = bank.messages[index + 1]
    Assert.notNil(message, "bank 300 carries message " .. index)
    local tokens = assert(
      FieldMessageTokenizer.tokenize(message.raw, charmap, { bankId = 300, messageId = index })
    )
    local parts = {}
    for _, token in ipairs(tokens) do
      if token.kind == "eos" then
        break
      elseif token.kind == "glyph" then
        parts[#parts + 1] = token.text
      else
        error("gender label carries a non-display token " .. tostring(token.kind), 0)
      end
    end
    return table.concat(parts)
  end
  Assert.equal(text.labels.male, displayText(27), "the male label matches source message 27")
  Assert.equal(text.labels.female, displayText(28), "the female label matches source message 28")
  Assert.isTrue(text.labels.male ~= text.labels.female, "gender labels stay distinct")
  local windows = bundle.manifest.windows
  Assert.notNil(windows, "the manifest publishes its native windows")
  for _, name in ipairs({ "browse", "context", "action" }) do
    assertPaneRect(windows[name], "the " .. name .. " message window")
  end
  Assert.deepEqual(windows.prompt, { x = 200, y = 80 }, "the confirm prompt keeps its source anchor")
  assertNoSourceKeys(windows, "windows")
  local controls = bundle.manifest.controls
  Assert.notNil(controls and controls.cancel, "the semantic cancel control resolves")
  local cancel = controls.cancel
  Assert.isTrue(type(cancel.label) == "string" and #cancel.label > 0, "cancel keeps its label on the text layer")
  Assert.isNil(cancel.image, "the cancel label is not baked into a sprite")
  assertPaneRect(cancel.textRect, "the cancel text rectangle")
  Assert.equal(cancel.align, "center", "cancel keeps its center-alignment contract")
end

function T.panel_gender_origins_keep_the_name_window_mark_offset(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  Assert.equal(#bundle.manifest.panels, 6, "six slot panels resolve")
  for slot, panel in ipairs(bundle.manifest.panels) do
    Assert.notNil(panel.text.name, "panel " .. slot .. " carries its name subrect")
    Assert.notNil(panel.text.gender, "panel " .. slot .. " carries its gender origin")
    local name, gender = panel.text.name, panel.text.gender
    Assert.deepEqual(
      { x = gender.x - name.x, y = gender.y - name.y },
      { x = 64, y = 0 },
      "panel " .. slot .. " places the mark at name-window-local (64,0)"
    )
  end
end

function T.menu_layouts_cover_every_supported_entry_count(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local menu = bundle.manifest.contextMenu
  Assert.notNil(menu, "the manifest publishes generated context-menu layouts")
  Assert.notNil(menu.topLevel, "the top-level menu section resolves")
  Assert.notNil(menu.subcontext, "the subcontext menu section resolves")
  local styles = {}
  for count = 2, 8 do
    local layout = layoutFor(menu.topLevel, count, "top-level")
    Assert.equal(#layout, count, "the " .. count .. "-entry top-level layout carries one record per entry")
    for index, entry in ipairs(layout) do
      local where = count .. "-entry top-level button " .. index
      assertPaneRect(entry.textRect, where .. " text")
      assertPaneRect(entry.frameRect, where .. " frame")
      Assert.isTrue(
        entry.frameShape == "standard" or entry.frameShape == "cancel",
        where .. " names its native frame shape"
      )
      Assert.isTrue(type(entry.style) == "string" and #entry.style > 0, where .. " names its text/fill style")
      styles[entry.style] = true
      Assert.notNil(entry.touch, where .. " publishes its touch rectangle")
      Assert.isTrue(entry.touch.top <= entry.touch.bottom, where .. " touch rows are ordered")
      for _, neighbor in pairs({ up = entry.up, down = entry.down, left = entry.left, right = entry.right }) do
        if neighbor ~= nil then
          Assert.isTrue(
            type(neighbor) == "number" and neighbor % 1 == 0 and neighbor >= 1 and neighbor <= count,
            where .. " neighbors address semantic entries"
          )
        end
      end
      Assert.notNil(entry.left, where .. " keeps the source lateral relation")
      Assert.notNil(entry.right, where .. " keeps the source lateral relation")
    end
  end
  local distinct = 0
  for _ in pairs(styles) do
    distinct = distinct + 1
  end
  Assert.isTrue(distinct >= 2, "top-level layouts distinguish entry style families")
  for count = 2, 5 do
    local layout = layoutFor(menu.subcontext, count, "subcontext")
    Assert.equal(#layout, count, "the " .. count .. "-entry subcontext layout carries one record per entry")
    for index, entry in ipairs(layout) do
      local where = count .. "-entry subcontext button " .. index
      assertPaneRect(entry.textRect, where .. " text")
      assertPaneRect(entry.frameRect, where .. " frame")
      Assert.notNil(entry.touch, where .. " publishes its touch rectangle")
      Assert.isNil(entry.left, where .. " has no source lateral relation")
      Assert.isNil(entry.right, where .. " has no source lateral relation")
      for _, neighbor in pairs({ up = entry.up, down = entry.down }) do
        if neighbor ~= nil then
          Assert.isTrue(
            type(neighbor) == "number" and neighbor % 1 == 0 and neighbor >= 1 and neighbor <= count,
            where .. " neighbors address semantic entries"
          )
        end
      end
    end
  end
  Assert.isTrue(
    (menu.topLevel[1] or menu.topLevel["1"]) == nil,
    "unsupported top-level counts have no fallback layout"
  )
  Assert.isTrue(
    (menu.topLevel[9] or menu.topLevel["9"]) == nil,
    "unsupported top-level counts have no fallback layout"
  )
  Assert.isTrue(
    (menu.subcontext[1] or menu.subcontext["1"]) == nil,
    "unsupported subcontext counts have no fallback layout"
  )
  Assert.isTrue(
    (menu.subcontext[6] or menu.subcontext["6"]) == nil,
    "unsupported subcontext counts have no fallback layout"
  )
  Assert.notNil(menu.textPalette, "context buttons publish their text roles")
  Assert.notNil(menu.fillPalette, "context buttons publish their fill roles")
  for _, palette in ipairs({ menu.textPalette, menu.fillPalette }) do
    local colors = collectRgba(palette)
    local paletteDistinct = 0
    for _ in pairs(colors) do
      paletteDistinct = paletteDistinct + 1
    end
    Assert.isTrue(paletteDistinct >= 2, "button palettes distinguish raised from depressed")
  end
  assertNoSourceKeys(menu, "contextMenu")
end

function T.context_frames_use_source_border_pixels(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local menu = bundle.manifest.contextMenu
  Assert.notNil(menu, "context-menu layouts resolve before frame inspection")
  local frames = menu.frames
  Assert.notNil(frames, "context button frames publish generated visuals")
  local groups = {
    standard = { width = 128, height = 32 },
    cancel = { width = 56, height = 40 },
  }
  local seenPaths = {}
  local stateBytes = {}
  for _, shape in ipairs({ "standard", "cancel" }) do
    local size = groups[shape]
    local group = frames[shape]
    Assert.notNil(group, "the " .. shape .. " frame group resolves")
    stateBytes[shape] = {}
    for _, state in ipairs({ "raised", "selected", "pressed" }) do
      local where = shape .. " " .. state .. " frame"
      local visual = group[state]
      Assert.notNil(visual, "the " .. where .. " resolves")
      Assert.equal(visual.width, size.width, where .. " width")
      Assert.equal(visual.height, size.height, where .. " height")
      local bytes = assetBytes(assert(bundle.assets[visual.image], where .. " image resolves"))
      local width, height, rgba = PngReader.rgba(bytes)
      Assert.equal(width, size.width, where .. " image width")
      Assert.equal(height, size.height, where .. " image height")
      local opaque = 0
      for x = 0, width - 1 do
        if string.byte(pixel(rgba, width, x, 0), 4) ~= 0 then
          opaque = opaque + 1
        end
        if string.byte(pixel(rgba, width, x, height - 1), 4) ~= 0 then
          opaque = opaque + 1
        end
      end
      for y = 0, height - 1 do
        if string.byte(pixel(rgba, width, 0, y), 4) ~= 0 then
          opaque = opaque + 1
        end
        if string.byte(pixel(rgba, width, width - 1, y), 4) ~= 0 then
          opaque = opaque + 1
        end
      end
      Assert.isTrue(opaque > 0, where .. " keeps an opaque border")
      local center = pixel(rgba, width, math.floor(width / 2), math.floor(height / 2))
      Assert.equal(string.byte(center, 4), 0, where .. " keeps a transparent interior")
      local distinct = 0
      local colors = {}
      for offset = 1, #rgba, 4 do
        if string.byte(rgba, offset + 3) ~= 0 then
          colors[rgba:sub(offset, offset + 3)] = true
        end
      end
      for _ in pairs(colors) do
        distinct = distinct + 1
      end
      Assert.isTrue(distinct <= 16, where .. " uses a tiled border palette")
      stateBytes[shape][state] = bytes
      seenPaths[#seenPaths + 1] = visual.image
    end
  end
  for shape, states in pairs(stateBytes) do
    local stateNames = { "raised", "selected", "pressed" }
    for first = 1, #stateNames do
      for second = first + 1, #stateNames do
        Assert.isFalse(
          states[stateNames[first]] == states[stateNames[second]],
          shape .. " " .. stateNames[first] .. "/" .. stateNames[second] .. " stay distinct visuals"
        )
      end
    end
  end
  local referenced = {}
  for _, path in ipairs(PartyCache.referencedPaths(bundle.manifest)) do
    referenced[path] = true
  end
  for _, path in ipairs(seenPaths) do
    Assert.isTrue(referenced[path], path .. " participates in cache readiness")
  end
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
