-- Bounded source-compiler coverage for the generated option controls: the
-- real dump resolves the curated archives, the curated selectors cross-check
-- through the resource lists and headers, the compiled section carries the
-- locked semantic shapes with decoded anchors and tick durations, every
-- state frame rasterizes its own source pixels, and the field-UI class
-- publishes the new outputs through its existing completion check.

local Assert = require("tests.support.Assert")
local PngReader = require("tests.support.PngReader")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local Lz10 = require("romdump.src.digest.Lz10")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldUiCacheWriter = require("romdump.src.digest.ui.FieldUiCacheWriter")
local FakeCache = require("tests.support.FakeCache")
local CacheFs = require("libs.storage.src.CacheFs")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function optionsSources()
  local ok, mod = pcall(require, "romdump.src.config.OptionsSources")
  Assert.isTrue(ok, "OptionsSources missing: " .. tostring(mod))
  return mod
end

local function optionsCompiler()
  local ok, mod = pcall(require, "romdump.src.digest.ui.OptionsAssetCompiler")
  Assert.isTrue(ok, "OptionsAssetCompiler missing: " .. tostring(mod))
  return mod
end

local function plain(archive, memberId)
  local Lz10decode = require("romdump.src.digest.Lz10")
  local bytes = assert(archive:readMember(memberId), "member " .. memberId .. " must exist")
  if string.byte(bytes, 1) == 0x10 then
    return assert(Lz10decode.decode(bytes))
  end
  return bytes
end

local function compileOptions(romFs, versionId)
  local Compiler = optionsCompiler()
  local bundle, err = Compiler.compile(romFs, versionId or romFs:version())
  assert(bundle, "the options compiler must succeed: " .. tostring(err and err.message or err))
  return bundle
end

function T.options_archives_resolve_through_the_curated_symbols(romFs, _)
  local Sources = optionsSources()
  local entry = assert(romFs:resolvedNarc(Sources.archive.symbol), "the options archive symbol must resolve")
  Assert.equal(entry.path, Sources.archive.path)
  local archive = assert(romFs:openNarc(Sources.archive.symbol), "the options archive must open")
  Assert.equal(archive:memberCount(), Sources.archive.memberCount)
  local messages = assert(romFs:openNarc(Sources.messagesArchive.symbol), "the message archive must open")
  local bankBytes = assert(messages:readMember(Sources.messageBank), "the options message bank must exist")
  Assert.isTrue(#bankBytes > 0, "the options message bank must carry bytes")
end

function T.resource_lists_cross_check_the_curated_selectors(romFs, _)
  local Sources = optionsSources()
  local BinaryReader = require("libs.codec.src.BinaryReader")
  local archive = assert(romFs:openNarc(Sources.resdat.symbol), "the resdat archive must open")
  local function records(memberId)
    local bytes = assert(archive:readMember(memberId), "resdat member " .. memberId .. " must exist")
    local reader = BinaryReader.new(bytes, "resdat")
    local resourceType = reader:u32le(0)
    local rows = {}
    local rowCount = (#bytes - 4) / 24
    for row = 0, rowCount - 2 do
      local base = 4 + row * 24
      rows[#rows + 1] = {
        narcId = reader:u32le(base),
        memberId = reader:u32le(base + 4),
        resourceId = reader:u32le(base + 12),
      }
    end
    return resourceType, rows
  end
  local function checkList(memberId, kind, expectedMembers)
    local _, rows = records(memberId)
    Assert.equal(#rows, #expectedMembers, kind .. " list carries one record per curated member")
    for index, member in ipairs(expectedMembers) do
      Assert.equal(rows[index].narcId, Sources.archive.narcId, kind .. " record " .. index .. " names the options NARC")
      Assert.equal(rows[index].memberId, member, kind .. " record " .. index .. " names its member")
      Assert.equal(rows[index].resourceId, index - 1, kind .. " record " .. index .. " carries its resource id")
    end
  end
  checkList(Sources.resdat.lists.animation, "animation", Sources.members.animations)
  checkList(Sources.resdat.lists.cell, "cell", Sources.members.cells)
  checkList(Sources.resdat.lists.char, "char", Sources.members.chars)
  checkList(Sources.resdat.lists.palette, "palette", Sources.members.palettes)
  local headerBytes = assert(archive:readMember(Sources.resdat.headers), "the options header set must exist")
  local reader = BinaryReader.new(headerBytes, "resdat-headers")
  local sets = Sources.sets
  for index, set in ipairs(sets) do
    local base = (index - 1) * 32
    Assert.equal(reader:u32le(base), set.char, "header set " .. index .. " selects its char")
    Assert.equal(reader:u32le(base + 4), set.palette, "header set " .. index .. " selects its palette")
    Assert.equal(reader:u32le(base + 8), set.cell, "header set " .. index .. " selects its cell")
    Assert.equal(reader:u32le(base + 12), set.animation, "header set " .. index .. " selects its animation")
  end
end

local function assertSequence(shape, name, frameCount, loop)
  Assert.isTrue(type(shape) == "table", name .. " must be a sequence")
  Assert.equal(shape.loop, loop, name .. " terminates as compiled")
  Assert.isTrue(type(shape.bounds) == "table", name .. " carries its logical bounds")
  Assert.isTrue(type(shape.frames) == "table", name .. " carries its frames")
  Assert.equal(#shape.frames, frameCount, name .. " carries its compiled frames")
  for index, frame in ipairs(shape.frames) do
    local where = name .. " frame " .. index
    Assert.isTrue(type(frame.image) == "string" and frame.image ~= "", where .. " names its atlas")
    for _, field in ipairs({ "x", "y", "width", "height" }) do
      Assert.isTrue(
        type(frame.atlas[field]) == "number" and frame.atlas[field] % 1 == 0 and frame.atlas[field] >= 0,
        where .. " atlas " .. field .. " is a non-negative integer"
      )
    end
    Assert.isTrue(frame.atlas.width > 0 and frame.atlas.height > 0, where .. " atlas rect is non-empty")
    Assert.isTrue(
      type(frame.offset.x) == "number" and frame.offset.x % 1 == 0,
      where .. " offset x stays a signed integer"
    )
    Assert.isTrue(
      type(frame.offset.y) == "number" and frame.offset.y % 1 == 0,
      where .. " offset y stays a signed integer"
    )
    Assert.isTrue(
      type(frame.ticks) == "number" and frame.ticks % 1 == 0 and frame.ticks >= 1,
      where .. " keeps its positive source tick duration"
    )
  end
end

local function assertLabel(record, name)
  Assert.isTrue(type(record) == "table", name .. " must be a label record")
  Assert.isTrue(type(record.text) == "string" and record.text ~= "", name .. " carries display text")
  Assert.isTrue(type(record.tokens) == "table" and #record.tokens > 0, name .. " carries its token stream")
end

function T.compiled_section_carries_the_locked_semantic_shapes(romFs, versionId)
  local bundle = compileOptions(romFs, versionId)
  local section = assert(bundle.section, "the compiler returns its semantic section")
  Assert.equal(section.version, 7)
  local DisplayTiming = require("libs.nds.src.gx.DisplayTiming")
  Assert.equal(section.animationTickSeconds, 1 / DisplayTiming.REFRESH_HZ)
  local labels = assert(section.labels, "the section carries its labels")
  for _, key in ipairs({
    "title",
    "textSpeed",
    "battleScene",
    "battleStyle",
    "soundMode",
    "textFrame",
    "confirm",
    "quit",
  }) do
    assertLabel(labels[key], "labels." .. key)
  end
  Assert.equal(labels.title.text, "OPTIONS")
  Assert.equal(labels.textSpeed.text, "TEXT SPEED")
  Assert.equal(labels.confirm.text:find("CONFIRM", 1, true) ~= nil, true, "the confirm label keeps its wording")
  for _, key in ipairs({ "mid", "fast" }) do
    assertLabel(labels.textSpeedValues[key], "textSpeedValues." .. key)
  end
  Assert.equal(labels.textSpeedValues.mid.text, "MID")
  Assert.equal(labels.textSpeedValues.fast.text, "FAST")
  for _, key in ipairs({ "on", "off" }) do
    assertLabel(labels.battleSceneValues[key], "battleSceneValues." .. key)
  end
  Assert.equal(labels.battleSceneValues.on.text, "ON")
  Assert.equal(labels.battleSceneValues.off.text, "OFF")
  for _, key in ipairs({ "shift", "set" }) do
    assertLabel(labels.battleStyleValues[key], "battleStyleValues." .. key)
  end
  Assert.equal(labels.battleStyleValues.shift.text, "SHIFT")
  Assert.equal(labels.battleStyleValues.set.text, "SET")
  for _, key in ipairs({ "stereo", "mono" }) do
    assertLabel(labels.soundModeValues[key], "soundModeValues." .. key)
  end
  Assert.equal(labels.soundModeValues.stereo.text, "STEREO")
  Assert.equal(labels.soundModeValues.mono.text, "MONO")
  for frame = 0, 19 do
    assertLabel(labels.frameValues[frame], "frameValues[" .. frame .. "]")
  end
  Assert.equal(labels.frameValues[0].text, "TYPE 1")
  Assert.equal(labels.frameValues[19].text, "TYPE 20")
  local previews = assert(section.framePreviewText, "the section carries its frame previews")
  for frame = 0, 19 do
    assertLabel(previews[frame], "framePreviewText[" .. frame .. "]")
  end
  Assert.equal(previews[0].text, "WINDOW TYPE 1")
  Assert.equal(previews[19].text, "WINDOW TYPE 20")
  local choices = assert(section.choices, "the section carries its choice controls")
  assertSequence(choices.small.unselected, "small unselected", 1, true)
  assertSequence(choices.small.selected, "small selected", 1, true)
  assertSequence(choices.wide.unselected, "wide unselected", 1, true)
  assertSequence(choices.wide.selected, "wide selected", 1, true)
  Assert.deepEqual(choices.small.unselected.bounds, { x = 0, y = 0, width = 48, height = 32 })
  Assert.deepEqual(choices.wide.unselected.bounds, { x = 0, y = 0, width = 64, height = 32 })
  local arrows = assert(section.arrows, "the section carries its arrows")
  assertSequence(arrows.left.idle, "left idle", 1, true)
  assertSequence(arrows.left.pressed, "left pressed", 2, false)
  assertSequence(arrows.right.idle, "right idle", 1, true)
  assertSequence(arrows.right.pressed, "right pressed", 2, false)
  local actions = assert(section.actions, "the section carries its footer actions")
  assertSequence(actions.normal, "action normal", 1, false)
  assertSequence(actions.focused, "action focused", 1, false)
  assertSequence(actions.pressed, "action pressed", 2, false)
  assertSequence(actions.pressedFocused, "action pressed-focused", 2, false)
  -- The sliders borrow the bag quantity-decrement pressed visual at draw time:
  -- the options section carries no cursor art of its own.
  Assert.isNil(section.sliderCursor, "the options section carries no slider cursor art")
end

-- The sliders borrow the bag quantity-decrement pressed visual at draw time,
-- so the compiled section carries no cursor art and the chrome atlas packs
-- only the pills, arrows, actions, and face patches.
function T.compiled_section_carries_no_slider_cursor_art(romFs, versionId)
  local bundle = compileOptions(romFs, versionId)
  local section = assert(bundle.section, "the compiler returns its semantic section")
  Assert.equal(section.version, 7, "the options section carries the thumb-borrowing contract")
  Assert.isNil(section.sliderCursor, "the options section carries no slider cursor art")
  local chromeImage = FieldUiAssetCache.assetDir() .. "/options-chrome.png"
  local chromeBytes = assert(bundle.files[chromeImage], "the chrome atlas must be published")
  local chromeWidth, chromeHeight, _ = PngReader.rgba(chromeBytes)
  Assert.isTrue(chromeWidth > 0 and chromeHeight > 0, "the chrome atlas keeps its packed extent")
end

function T.compiled_frames_keep_their_decoded_anchors_and_sizes(romFs, versionId)
  local bundle = compileOptions(romFs, versionId)
  local section = assert(bundle.section)
  Assert.deepEqual(section.choices.small.selected.frames[1].offset, { x = -8, y = 0 })
  Assert.deepEqual(section.choices.wide.selected.frames[1].offset, { x = -8, y = 0 })
  Assert.deepEqual(section.choices.small.selected.bounds, { x = -8, y = 0, width = 48, height = 32 })
  Assert.deepEqual(section.choices.wide.selected.bounds, { x = -8, y = 0, width = 64, height = 32 })
  Assert.deepEqual(section.choices.small.unselected.frames[1].atlas.height, 32)
  Assert.deepEqual(section.choices.wide.unselected.frames[1].atlas.width, 64)
  for _, side in ipairs({ "left", "right" }) do
    for _, state in ipairs({ "idle", "pressed" }) do
      for _, frame in ipairs(section.arrows[side][state].frames) do
        Assert.deepEqual({ frame.atlas.width, frame.atlas.height }, { 32, 32 })
        Assert.deepEqual(frame.offset, { x = 0, y = 0 })
      end
    end
  end
  Assert.equal(section.arrows.left.pressed.frames[1].ticks, 8)
  Assert.equal(section.arrows.left.pressed.frames[2].ticks, 8)
  for _, frame in ipairs(section.actions.pressed.frames) do
    Assert.deepEqual({ frame.atlas.width, frame.atlas.height }, { 64, 24 })
  end
  Assert.equal(section.actions.pressed.frames[1].ticks, 8)
  Assert.equal(section.actions.pressed.frames[2].ticks, 4)
end

function T.compiled_pixels_match_the_decoded_source_art(romFs, versionId)
  local bundle = compileOptions(romFs, versionId)
  local section = assert(bundle.section)
  local archive = assert(romFs:openNarc(optionsSources().archive.symbol))
  local function decoded(kind, memberId)
    local decodedValue, err = G2dDecoder[kind](plain(archive, memberId), { label = "options:" .. memberId })
    assert(decodedValue, tostring(err and err.message or err))
    return decodedValue
  end
  local function atlasPixels(frame)
    local bytes = assert(bundle.files[frame.image], "the atlas " .. frame.image .. " must be published")
    local width, _, rgba = PngReader.rgba(bytes)
    local pixels = {}
    for y = 0, frame.atlas.height - 1 do
      for x = 0, frame.atlas.width - 1 do
        pixels[#pixels + 1] = rgba:sub(
          (y + frame.atlas.y) * width * 4 + (x + frame.atlas.x) * 4 + 1,
          (y + frame.atlas.y) * width * 4 + (x + frame.atlas.x) * 4 + 4
        )
      end
    end
    return pixels
  end
  local function referencePixels(image)
    local pixels = {}
    for y = 0, image.height - 1 do
      for x = 0, image.width - 1 do
        local off = (y * image.width + x) * 4 + 1
        pixels[#pixels + 1] = image.pixels:sub(off, off + 3)
      end
    end
    return pixels
  end
  -- The selected small pill reproduces the decoded sprite composition.
  do
    local char = decoded("decodeChar", 4)
    local palette = decoded("decodePalette", 0)
    local cell = decoded("decodeCell", 9)
    local animation = decoded("decodeAnimation", 13)
    local reference = G2dRasterizer.renderAnimationFrame(
      char,
      { colors = palette.colors },
      cell,
      animation.anims[1],
      1,
      { asset = "options", member = 4 }
    )
    Assert.deepEqual(atlasPixels(section.choices.small.selected.frames[1]), referencePixels(reference))
  end
  -- The unselected faces reproduce the baseline screen crop with the
  -- inter-pill backing trim cleared to transparent, so printed pills
  -- blend onto the leveled plates instead of framing themselves in
  -- retail control-side blue. The trim color is sampled from each crop's
  -- own top-right backing margin, mirroring the compiler rule.
  local function expectTrimmedCrop(originX, originY, width, height, what)
    local char = decoded("decodeChar", 7)
    local palette = decoded("decodePalette", 2)
    local screen = decoded("decodeScreen", 17)
    local reference = G2dRasterizer.renderScreen(
      char,
      { colors = palette.colors },
      screen,
      { asset = "options", member = 17 }
    )
    local rows = {}
    for y = originY, originY + height - 1 do
      for x = originX, originX + width - 1 do
        local off = (y * reference.width + x) * 4 + 1
        rows[#rows + 1] = reference.pixels:sub(off, off + 3)
      end
    end
    local crop = table.concat(rows)
    local toff = (4 * width + (width - 1)) * 4 + 1
    local tr, tg, tb, ta = string.byte(crop, toff, toff + 3)
    Assert.equal(ta, 255, what .. " trim margin stays opaque backing in source")
    local expected, masked = {}, 0
    for i = 1, #crop, 4 do
      local r, g, b = string.byte(crop, i, i + 2)
      if r == tr and g == tg and b == tb then
        masked = masked + 1
        expected[#expected + 1] = string.char(r, g, b, 0)
      else
        expected[#expected + 1] = crop:sub(i, i + 3)
      end
    end
    Assert.isTrue(masked > 0, what .. " carries backing trim to clear")
    return expected
  end
  Assert.deepEqual(
    atlasPixels(section.choices.small.unselected.frames[1]),
    expectTrimmedCrop(112, 24, 48, 32, "small unselected")
  )
  Assert.deepEqual(
    atlasPixels(section.choices.wide.unselected.frames[1]),
    expectTrimmedCrop(112, 72, 64, 32, "wide unselected")
  )
  -- The pressed arrow reproduces its decoded pressed cell.
  do
    local char = decoded("decodeChar", 5)
    local palette = decoded("decodePalette", 0)
    local cell = decoded("decodeCell", 10)
    local animation = decoded("decodeAnimation", 14)
    local reference = G2dRasterizer.renderAnimationFrame(
      char,
      { colors = palette.colors },
      cell,
      animation.anims[2],
      1,
      { asset = "options", member = 5 }
    )
    Assert.deepEqual(atlasPixels(section.arrows.left.pressed.frames[1]), referencePixels(reference))
  end
end

-- The selected-row indicator is the native MAIN selection layer, not an
-- opaque base: the staged 256x30 transparent PNG reproduces the decoded
-- full border box at selection screen rows 13..42 exactly (the 24px row
-- centers the 30px box with a 3px overhang on each side), keeps
-- palette-zero transparent, hashes the selection member, and never equals
-- the opaque MAIN backing.
function T.selection_strip_matches_the_native_selected_row_layer(romFs, versionId)
  local bundle = compileOptions(romFs, versionId)
  local section = assert(bundle.section, "the compiler returns its semantic section")
  Assert.equal(section.version, 7, "the options section carries its selection-layer contract")
  local overlayKey = "hgss.options.selection_overlay"
  Assert.equal(section.selectionOverlay, overlayKey, "the section indexes its selected-row strip")
  Assert.equal(
    FieldUiAssetCache.ASSET.OPTIONS_SELECTION_OVERLAY,
    overlayKey,
    "the runtime asset index names the selected-row strip"
  )
  local Sources = optionsSources()
  local overlayImage = FieldUiAssetCache.assetDir() .. "/options-selection-overlay.png"
  local overlayBytes = assert(bundle.files[overlayImage], "the selected-row strip is staged as its indexed PNG")
  local width, height, rgba = PngReader.rgba(overlayBytes)
  Assert.equal(width, 256, "the selected-row strip width")
  Assert.equal(height, 30, "the selected-row strip height")
  local archive = assert(romFs:openNarc(Sources.archive.symbol))
  local function decoded(kind, memberId)
    local decodedValue, err = G2dDecoder[kind](plain(archive, memberId), { label = "options:" .. memberId })
    assert(decodedValue, tostring(err and err.message or err))
    return decodedValue
  end
  local char = decoded("decodeChar", Sources.members.faceChar)
  local palette = decoded("decodePalette", Sources.members.facePalette)
  local screen = decoded("decodeScreen", Sources.selectionOverlayScreen)
  Assert.equal(screen.width, 256, "the selection screen width")
  Assert.equal(screen.height, 56, "the selection screen height")
  local render = G2dRasterizer.renderScreen(
    char,
    { colors = palette.colors },
    screen,
    { asset = "options", member = Sources.selectionOverlayScreen }
  )
  local expected = {}
  for y = 13, 42 do
    expected[#expected + 1] = render.pixels:sub(y * 256 * 4 + 1, (y + 1) * 256 * 4)
  end
  Assert.equal(rgba, table.concat(expected), "every strip pixel matches the native selection layer")
  local transparent, total = 0, 256 * 30
  for index = 4, #rgba, 4 do
    if string.byte(rgba, index) == 0 then
      transparent = transparent + 1
    end
  end
  Assert.isTrue(transparent > 0, "the strip keeps source-zero transparent")
  Assert.isTrue(transparent < total, "the strip still carries opaque selection artwork")
  local names = {}
  for _, dep in ipairs(bundle.dependencies) do
    names[dep.name] = true
  end
  Assert.isTrue(
    names[Sources.archive.symbol .. ":member:" .. Sources.selectionOverlayScreen] == true,
    "the producer hashes the selection screen member"
  )
  local headerBytes = assert(
    bundle.files[FieldUiAssetCache.assetDir() .. "/options-header-background.png"],
    "the header shell band is staged"
  )
  local _, _, headerRgba = PngReader.rgba(headerBytes)
  Assert.isTrue(rgba ~= headerRgba, "the strip is not the opaque MAIN backing")
end

function T.backdrops_derive_from_the_audited_base_screens(romFs, versionId)
  local bundle = compileOptions(romFs, versionId)
  local section = assert(bundle.section, "the compiler returns its semantic section")
  Assert.equal(section.version, 7, "the options section carries its backdrop contract")
  Assert.equal(
    section.backdrops.header,
    FieldUiAssetCache.ASSET.OPTIONS_HEADER_BACKGROUND,
    "the header shell band carries its semantic role"
  )
  Assert.equal(
    section.backdrops.footer,
    FieldUiAssetCache.ASSET.OPTIONS_FOOTER_BACKGROUND,
    "the footer shell band carries its semantic role"
  )
  Assert.equal(
    section.backdrops.preview,
    FieldUiAssetCache.ASSET.OPTIONS_PREVIEW_BACKGROUND,
    "the preview backdrop carries its semantic role"
  )
  Assert.isNil(section.backdrops.controls, "the full-screen controls backdrop role is gone")
  local headerImage = FieldUiAssetCache.assetDir() .. "/options-header-background.png"
  local footerImage = FieldUiAssetCache.assetDir() .. "/options-footer-background.png"
  local previewImage = FieldUiAssetCache.assetDir() .. "/options-preview-background.png"
  Assert.isNil(
    bundle.files[FieldUiAssetCache.assetDir() .. "/options-controls-background.png"],
    "the full-screen controls backdrop file is gone"
  )
  local headerBytes = assert(bundle.files[headerImage], "the header shell band is staged")
  local footerBytes = assert(bundle.files[footerImage], "the footer shell band is staged")
  local previewBytes = assert(bundle.files[previewImage], "the preview backdrop is staged")
  local function stagedBand(bytes, what)
    local width, height, rgba = PngReader.rgba(bytes)
    Assert.equal(width, 256, what .. " width")
    Assert.equal(height, 24, what .. " height")
    return rgba
  end
  local function stagedScreen(bytes, what)
    local width, height, rgba = PngReader.rgba(bytes)
    Assert.equal(width, 256, what .. " width")
    Assert.equal(height, 192, what .. " height")
    return rgba
  end
  local headerRgba = stagedBand(headerBytes, "the header shell band")
  local footerRgba = stagedBand(footerBytes, "the footer shell band")
  local previewRgba = stagedScreen(previewBytes, "the preview backdrop")
  local Sources = optionsSources()
  local archive = assert(romFs:openNarc(Sources.archive.symbol))
  local function decoded(kind, memberId)
    local decodedValue, err = G2dDecoder[kind](plain(archive, memberId), { label = "options:" .. memberId })
    assert(decodedValue, tostring(err and err.message or err))
    return decodedValue
  end
  -- The expected shell bands: the audited MAIN base with palette-zero
  -- normalized to the same palette's opaque backdrop, sliced by tile row
  -- (header tile rows 0..2, footer tile rows 21..23) and rasterized
  -- through the shared screen path. The preview keeps the full visible
  -- viewport: the audited SUB map cropped to the top 256x192 rows (or
  -- fewer for a shorter source plane).
  local function expectedBand(charMember, paletteMember, screenMember, firstTileRow, tileRowCount)
    local char = decoded("decodeChar", charMember)
    local palette = decoded("decodePalette", paletteMember)
    local screen = decoded("decodeScreen", screenMember)
    Assert.equal(screen.width, 256, "screen " .. screenMember .. " width")
    Assert.equal(screen.height, 256, "screen " .. screenMember .. " height")
    local columns = screen.width / 8
    local entries = {}
    for tileRow = firstTileRow, firstTileRow + tileRowCount - 1 do
      for col = 0, columns - 1 do
        entries[#entries + 1] = screen.entries[tileRow * columns + col + 1]
      end
    end
    local render = G2dRasterizer.renderScreen(
      char,
      { colors = palette.colors },
      { width = 256, height = tileRowCount * 8, entries = entries },
      { asset = "options", member = screenMember },
      { backdrop = true }
    )
    return render.pixels
  end
  local function expectedRgba(charMember, paletteMember, screenMember, expectFull)
    local char = decoded("decodeChar", charMember)
    local palette = decoded("decodePalette", paletteMember)
    local screen = decoded("decodeScreen", screenMember)
    if expectFull then
      Assert.equal(screen.width, 256, "screen " .. screenMember .. " width")
      Assert.equal(screen.height, 256, "screen " .. screenMember .. " height")
    end
    local render = G2dRasterizer.renderScreen(
      char,
      { colors = palette.colors },
      screen,
      { asset = "options", member = screenMember },
      { backdrop = true }
    )
    local rows = {}
    for y = 0, math.min(191, render.height - 1) do
      rows[#rows + 1] = render.pixels:sub(y * 256 * 4 + 1, (y + 1) * 256 * 4)
    end
    return table.concat(rows)
  end
  Assert.equal(headerRgba, expectedBand(7, 2, 17, 0, 3), "the header shell band matches MAIN rows 0..23")
  Assert.equal(footerRgba, expectedBand(7, 2, 17, 21, 3), "the footer shell band matches MAIN rows 168..191")
  Assert.equal(previewRgba, expectedRgba(8, 3, 19, true), "the preview backdrop matches the SUB base")
  Assert.isTrue(
    headerRgba ~= expectedBand(7, 2, 17, 21, 3),
    "the header band is not the footer band"
  )
  Assert.isTrue(headerRgba ~= previewRgba, "the shell bands carry rasters distinct from the preview")
  local function assertOpaque(rgba, what)
    for index = 4, #rgba, 4 do
      if string.byte(rgba, index) ~= 255 then
        Assert.fail(what .. " pixel " .. math.floor(index / 4) .. " is not opaque")
      end
    end
  end
  assertOpaque(headerRgba, "the header shell band")
  assertOpaque(footerRgba, "the footer shell band")
  assertOpaque(previewRgba, "the preview backdrop")
  local names = {}
  for _, dep in ipairs(bundle.dependencies) do
    names[dep.name] = true
  end
  for _, memberId in ipairs({ 2, 7, 17, 3, 8, 19 }) do
    Assert.isTrue(
      names[Sources.archive.symbol .. ":member:" .. memberId] == true,
      "the producer hashes backdrop member " .. memberId
    )
  end
end

function T.field_ui_compilation_publishes_ready_options(romFs, versionId)
  local FieldUiCompiler = require("romdump.src.digest.ui.FieldUiCompiler")
  local bundle = assert(FieldUiCompiler.compile(romFs))
  local options = assert(bundle.manifest.options, "the field-UI class carries its options section")
  Assert.equal(options.version, 7)
  Assert.isTrue(bundle.manifest.assets[FieldUiAssetCache.ASSET.OPTIONS_CHROME] ~= nil, "the chrome atlas is indexed")
  Assert.isTrue(FieldUiAssetCache.validateManifest(bundle.manifest), "the extended class still validates")
  local cache = CacheFs.forVersion(versionId, FakeCache.new())
  FieldUiCacheWriter.write(cache, bundle)
  Assert.isTrue(FieldUiAssetCache.isReady(cache, bundle.marker), "every indexed file is ready after publication")
  local broken = assert(FieldUiCompiler.compile(romFs))
  broken.manifest.options = nil
  local ok, err = FieldUiAssetCache.validateManifest(broken.manifest)
  Assert.isFalse(ok, "a class without options is not ready")
  Assert.equal(assert(err).code, "FIELD_UI_MANIFEST_INVALID")
end

function T.compiled_section_carries_no_source_identities(romFs, versionId)
  local bundle = compileOptions(romFs, versionId)
  local forbidden = {
    member = true,
    memberId = true,
    narc = true,
    narcId = true,
    alias = true,
    fileId = true,
    bank = true,
    bankId = true,
    index = true,
  }
  local function scan(value, path)
    if type(value) ~= "table" then
      return
    end
    for key, nested in pairs(value) do
      if type(key) == "string" and forbidden[key] then
        Assert.fail("the options section leaks source detail '" .. key .. "' at " .. path)
      end
      if type(nested) == "table" then
        scan(nested, path .. "." .. tostring(key))
      end
    end
  end
  scan(bundle.section, "options")
end

local function tamperedRom(romFs, alias, memberId, replacement)
  local realArchive = assert(romFs:openNarc(alias))
  local wrapped = setmetatable({}, { __index = realArchive })
  function wrapped.readMember(_, id)
    if id == memberId then
      return replacement
    end
    return realArchive:readMember(id)
  end
  local fake = setmetatable({}, { __index = romFs })
  function fake.openNarc(_, name)
    if name == alias then
      return wrapped
    end
    return romFs:openNarc(name)
  end
  return fake
end

function T.missing_option_source_fails_with_producer_context(romFs, versionId)
  local Compiler = optionsCompiler()
  local Sources = optionsSources()
  do
    local fake = tamperedRom(romFs, Sources.archive.symbol, Sources.members.chars[1], nil)
    local bundle, err = Compiler.compile(fake, versionId)
    Assert.isNil(bundle, "a missing char member must not compile")
    Assert.equal(assert(err).code, Compiler.ERROR.SOURCE_INVALID)
  end
  do
    local fake = tamperedRom(romFs, Sources.messagesArchive.symbol, Sources.messageBank, nil)
    local bundle, err = Compiler.compile(fake, versionId)
    Assert.isNil(bundle, "a missing message bank must not compile")
    Assert.equal(assert(err).code, Compiler.ERROR.SOURCE_INVALID)
  end
  do
    local fake = tamperedRom(romFs, Sources.resdat.symbol, Sources.resdat.lists.animation, string.rep("\0", 124))
    local bundle, err = Compiler.compile(fake, versionId)
    Assert.isNil(bundle, "a resdat list that disagrees with the curated selectors must not compile")
    Assert.equal(assert(err).code, Compiler.ERROR.SOURCE_INVALID)
  end
end

-- Every source-derived options class carries its mandatory scrolling row
-- plates: the section versions the row contract, indexes the three
-- 256-wide opaque plates, and stale or incomplete classes fail strict
-- readiness while the two full-screen source bases stay intact.
function T.compiled_row_plates_publish_indexed_opaque_backings(romFs, versionId)
  local bundle = compileOptions(romFs, versionId)
  local section = assert(bundle.section, "the compiler returns its semantic section")
  Assert.equal(section.version, 7, "the options section carries the row-plate contract")
  local backings = assert(section.rowBackings, "the section indexes its row plates")
  Assert.equal(backings.odd, "hgss.options.row_odd", "the odd row plate carries its semantic role")
  Assert.equal(backings.even, "hgss.options.row_even", "the even row plate carries its semantic role")
  Assert.equal(backings.frame, "hgss.options.row_frame", "the frame plate carries its semantic role")
  Assert.equal(
    FieldUiAssetCache.ASSET.OPTIONS_ROW_ODD,
    "hgss.options.row_odd",
    "the runtime asset index names the odd row plate"
  )
  Assert.equal(
    FieldUiAssetCache.ASSET.OPTIONS_ROW_EVEN,
    "hgss.options.row_even",
    "the runtime asset index names the even row plate"
  )
  Assert.equal(
    FieldUiAssetCache.ASSET.OPTIONS_ROW_FRAME,
    "hgss.options.row_frame",
    "the runtime asset index names the frame plate"
  )
  local oddImage = FieldUiAssetCache.assetDir() .. "/options-row-odd.png"
  local evenImage = FieldUiAssetCache.assetDir() .. "/options-row-even.png"
  local frameImage = FieldUiAssetCache.assetDir() .. "/options-row-frame.png"
  local oddBytes = assert(bundle.files[oddImage], "the odd row plate is staged")
  local evenBytes = assert(bundle.files[evenImage], "the even row plate is staged")
  local frameBytes = assert(bundle.files[frameImage], "the frame plate is staged")
  local function stagedRgba(bytes, what, wantWidth, wantHeight)
    local width, height, rgba = PngReader.rgba(bytes)
    Assert.equal(width, wantWidth, what .. " width")
    Assert.equal(height, wantHeight, what .. " height")
    return rgba
  end
  local oddRgba = stagedRgba(oddBytes, "the odd row plate", 256, 24)
  local evenRgba = stagedRgba(evenBytes, "the even row plate", 256, 24)
  local frameRgba = stagedRgba(frameBytes, "the frame plate", 256, 72)
  local function assertOpaque(rgba, what)
    for index = 4, #rgba, 4 do
      if string.byte(rgba, index) ~= 255 then
        Assert.fail(what .. " pixel " .. math.floor(index / 4) .. " is not opaque")
      end
    end
  end
  assertOpaque(oddRgba, "the odd row plate")
  assertOpaque(evenRgba, "the even row plate")
  assertOpaque(frameRgba, "the frame plate")
  Assert.isTrue(oddRgba ~= evenRgba, "odd and even plates keep their alternating bands")
  Assert.isTrue(frameRgba ~= oddRgba, "the frame plate is its own compound item")
  local indexed = {}
  for _, background in ipairs(assert(bundle.backgrounds, "the compiler publishes its backdrop index")) do
    indexed[background.key] = background.asset
  end
  Assert.isTrue(indexed["hgss.options.row_odd"] ~= nil, "the odd plate is indexed")
  Assert.isTrue(indexed["hgss.options.row_even"] ~= nil, "the even plate is indexed")
  Assert.isTrue(indexed["hgss.options.row_frame"] ~= nil, "the frame plate is indexed")
  local FieldUiCompiler = require("romdump.src.digest.ui.FieldUiCompiler")
  local full = assert(FieldUiCompiler.compile(romFs))
  Assert.equal(full.manifest.options.version, 7, "the field-UI class carries the row-plate section")
  Assert.isTrue(FieldUiAssetCache.validateManifest(full.manifest), "the extended class still validates")
  local stale = assert(FieldUiCompiler.compile(romFs))
  stale.manifest.options.version = 4
  local staleOk, staleErr = FieldUiAssetCache.validateManifest(stale.manifest)
  Assert.isFalse(staleOk, "a stale class without the row contract is not ready")
  Assert.equal(assert(staleErr).code, "FIELD_UI_MANIFEST_INVALID")
  local missing = assert(FieldUiCompiler.compile(romFs))
  missing.manifest.options.rowBackings = nil
  local missingOk, missingErr = FieldUiAssetCache.validateManifest(missing.manifest)
  Assert.isFalse(missingOk, "a class without row plates is not ready")
  Assert.equal(assert(missingErr).code, "FIELD_UI_MANIFEST_INVALID")
  local missized = assert(FieldUiCompiler.compile(romFs))
  missized.manifest.assets["hgss.options.row_even"].height = 32
  local sizedOk, sizedErr = FieldUiAssetCache.validateManifest(missized.manifest)
  Assert.isFalse(sizedOk, "a missized row plate is rejected")
  Assert.equal(assert(sizedErr).code, "FIELD_UI_MANIFEST_INVALID")
end

-- The scrub filler is audited band backing, not an invented color: every
-- recorded filler tile is opaque, carries only its band's background
-- palette entries, and the mid-band filler is one flat color. The check
-- decodes the source tiles directly, never through the plate builder.
function T.row_plate_filler_is_plain_audited_band_backing(romFs, versionId)
  local Sources = optionsSources()
  local plates = assert(Sources.rowPlates, "the producer records its audited plate material")
  local archive = assert(romFs:openNarc(Sources.archive.symbol))
  local function decoded(kind, memberId)
    local decodedValue, err = G2dDecoder[kind](plain(archive, memberId), { label = "options:" .. memberId })
    assert(decodedValue, tostring(err and err.message or err))
    return decodedValue
  end
  local char = decoded("decodeChar", Sources.members.faceChar)
  local tileBytes = char.depth == 3 and 32 or 64
  local function indices(tile)
    local raw = char.tiles:sub(tile * tileBytes + 1, (tile + 1) * tileBytes)
    local seen = {}
    if char.depth == 3 then
      for i = 1, #raw do
        local byte = string.byte(raw, i)
        seen[byte % 16] = true
        seen[math.floor(byte / 16)] = true
      end
    else
      for i = 1, #raw do
        seen[string.byte(raw, i)] = true
      end
    end
    local list = {}
    for index in pairs(seen) do
      list[#list + 1] = index
    end
    table.sort(list)
    return list
  end
  local bands = {
    odd = { fillers = plates.oddFillers, allowed = { [1] = true, [4] = true } },
    even = { fillers = plates.evenFillers, allowed = { [1] = true, [6] = true } },
  }
  for _, band in ipairs({ "odd", "even" }) do
    local spec = bands[band]
    Assert.equal(#spec.fillers, 3, "the " .. band .. " band records one filler per tile row")
    for position, tile in ipairs(spec.fillers) do
      local found = indices(tile)
      Assert.isTrue(#found >= 1, "filler tile " .. tile .. " carries pixels")
      for _, index in ipairs(found) do
        Assert.isTrue(spec.allowed[index] == true, "filler tile " .. tile .. " stays in its band backing")
      end
      if position == 2 then
        Assert.equal(#found, 1, "the " .. band .. " mid-band filler is one flat color")
      end
    end
  end
end

-- The outer window frame matches the decoded MAIN base bytes exactly:
-- the top/bottom rows carry the row separators and the border columns
-- close the window, while the compound frame item reuses the odd band
-- rows. The leveled-interior contract (one flat backing per band inside
-- the frame) lives with row_plates_flatten_interior_to_band_backing; this
-- test keeps the frame and composition facts. The reference is the
-- decoded source base, never the plate builder under test.
function T.row_plates_keep_the_source_frame(romFs, versionId)
  local bundle = compileOptions(romFs, versionId)
  local Sources = optionsSources()
  local archive = assert(romFs:openNarc(Sources.archive.symbol))
  local function decoded(kind, memberId)
    local decodedValue, err = G2dDecoder[kind](plain(archive, memberId), { label = "options:" .. memberId })
    assert(decodedValue, tostring(err and err.message or err))
    return decodedValue
  end
  local baseScreen = decoded("decodeScreen", Sources.members.faceScreen)
  local baseRender = G2dRasterizer.renderScreen(
    decoded("decodeChar", Sources.members.faceChar),
    { colors = decoded("decodePalette", Sources.members.facePalette).colors },
    baseScreen,
    { asset = "options", member = Sources.members.faceScreen },
    { backdrop = true }
  )
  local rows = {}
  for y = 0, 191 do
    rows[#rows + 1] = baseRender.pixels:sub(y * 256 * 4 + 1, (y + 1) * 256 * 4)
  end
  local controlsRgba = table.concat(rows)
  local function plateRgba(name)
    local bytes = assert(bundle.files[FieldUiAssetCache.assetDir() .. name], name .. " is staged")
    local width, height, rgba = PngReader.rgba(bytes)
    Assert.equal(width, 256, name .. " width")
    return height, rgba
  end
  local oddHeight, oddRgba = plateRgba("/options-row-odd.png")
  local evenHeight, evenRgba = plateRgba("/options-row-even.png")
  local frameHeight, frameRgba = plateRgba("/options-row-frame.png")
  Assert.equal(oddHeight, 24, "the odd plate height")
  Assert.equal(evenHeight, 24, "the even plate height")
  Assert.equal(frameHeight, 72, "the frame plate height")
  local function rowSpan(rgba, width, y, x0, x1)
    return rgba:sub((y * width + x0) * 4 + 1, (y * width + x1 + 1) * 4)
  end
  local bands = {
    { rgba = oddRgba, height = 24, baseY = 24, baseTileRow = 3, name = "odd" },
    { rgba = evenRgba, height = 24, baseY = 48, baseTileRow = 6, name = "even" },
  }
  for _, band in ipairs(bands) do
    for _, y in ipairs({ 0, band.height - 1 }) do
      Assert.equal(
        rowSpan(band.rgba, 256, y, 0, 255),
        rowSpan(controlsRgba, 256, band.baseY + y, 0, 255),
        "the " .. band.name .. " plate keeps its source separator row " .. y
      )
    end
    for y = 1, band.height - 2 do
      Assert.equal(
        rowSpan(band.rgba, 256, y, 0, 3),
        rowSpan(controlsRgba, 256, band.baseY + y, 0, 3),
        "the " .. band.name .. " plate keeps its source left border at row " .. y
      )
      Assert.equal(
        rowSpan(band.rgba, 256, y, 252, 255),
        rowSpan(controlsRgba, 256, band.baseY + y, 252, 255),
        "the " .. band.name .. " plate keeps its source right border at row " .. y
      )
    end
  end
  for y = 0, 22 do
    Assert.equal(
      rowSpan(frameRgba, 256, y, 0, 255),
      rowSpan(oddRgba, 256, y, 0, 255),
      "the frame selector band matches the odd band at row " .. y
    )
  end
  -- Row 23 closes the frame's first segment inside the item, so it levels
  -- to the flat interior; the odd plate keeps it as its bottom separator.
  Assert.equal(
    rowSpan(frameRgba, 256, 23, 4, 251),
    rowSpan(oddRgba, 256, 12, 4, 251),
    "the frame selector band levels its interior segment boundary"
  )
  for y = 24, 63 do
    Assert.equal(
      rowSpan(frameRgba, 256, y, 0, 255),
      rowSpan(oddRgba, 256, 8 + (y - 24) % 8, 0, 255),
      "the frame extension repeats the odd mid-band interior at row " .. y
    )
  end
  for y = 64, 71 do
    Assert.equal(
      rowSpan(frameRgba, 256, y, 0, 255),
      rowSpan(oddRgba, 256, 16 + (y - 64), 0, 255),
      "the frame lower edge matches the odd lower edge at row " .. y
    )
  end
end

-- The scrolling plates level every interior pixel inside the outer window
-- frame to one flat band backing so custom option layouts can relocate
-- controls: no native divider, separator, control-side backing, divider
-- remnant, or lighter edge-cap strip survives beside the pills, and the
-- flat is the decoded source filler backing, never an invented color. The
-- reference is the decoded source base, never the plate builder under test.
function T.row_plates_flatten_interior_to_band_backing(romFs, versionId)
  local bundle = compileOptions(romFs, versionId)
  local Sources = optionsSources()
  assert(Sources.rowPlates, "the producer records its audited plate material")
  local archive = assert(romFs:openNarc(Sources.archive.symbol))
  local function decoded(kind, memberId)
    local decodedValue, err = G2dDecoder[kind](plain(archive, memberId), { label = "options:" .. memberId })
    assert(decodedValue, tostring(err and err.message or err))
    return decodedValue
  end
  local baseScreen = decoded("decodeScreen", Sources.members.faceScreen)
  local baseRender = G2dRasterizer.renderScreen(
    decoded("decodeChar", Sources.members.faceChar),
    { colors = decoded("decodePalette", Sources.members.facePalette).colors },
    baseScreen,
    { asset = "options", member = Sources.members.faceScreen },
    { backdrop = true }
  )
  local rows = {}
  for y = 0, 191 do
    rows[#rows + 1] = baseRender.pixels:sub(y * 256 * 4 + 1, (y + 1) * 256 * 4)
  end
  local controlsRgba = table.concat(rows)
  local function plateRgba(name, wantHeight)
    local bytes = assert(bundle.files[FieldUiAssetCache.assetDir() .. name], name .. " is staged")
    local width, height, rgba = PngReader.rgba(bytes)
    Assert.equal(width, 256, name .. " width")
    Assert.equal(height, wantHeight, name .. " height")
    return rgba
  end
  local oddRgba = plateRgba("/options-row-odd.png", 24)
  local evenRgba = plateRgba("/options-row-even.png", 24)
  local frameBytes = assert(bundle.files[FieldUiAssetCache.assetDir() .. "/options-row-frame.png"], "row-frame is staged")
  local frameWidth, frameHeight, frameRgba = PngReader.rgba(frameBytes)
  Assert.equal(frameWidth, 256, "row-frame width")
  Assert.equal(frameHeight, 72, "row-frame height")
  local function pixel(rgba, width, x, y)
    return rgba:sub((y * width + x) * 4 + 1, (y * width + x) * 4 + 4)
  end
  local bands = {
    { rgba = oddRgba, baseY = 24, name = "odd" },
    { rgba = evenRgba, baseY = 48, name = "even" },
  }
  local flats = {}
  for _, band in ipairs(bands) do
    local flat = pixel(band.rgba, 256, 8, 12)
    flats[band.name] = flat
    Assert.equal(
      flat,
      pixel(controlsRgba, 256, 8, band.baseY + 12),
      "the " .. band.name .. " interior levels to its source filler backing"
    )
    for y = 1, 22 do
      for x = 4, 251 do
        local where = string.format("the %s plate at %d,%d", band.name, x, y)
        Assert.equal(pixel(band.rgba, 256, x, y), flat, where .. " flattens inside the frame")
      end
    end
  end
  Assert.equal(
    pixel(frameRgba, 256, 8, 36),
    flats.odd,
    "the frame interior shares the odd band backing"
  )
  for y = 1, 70 do
    for x = 4, 251 do
      Assert.equal(
        pixel(frameRgba, 256, x, y),
        flats.odd,
        string.format("the frame plate at %d,%d flattens inside the frame", x, y)
      )
    end
  end
end

-- The product divider inks match the audited native divider tiles: the
-- odd mid-band tile 14 carries palette-2 index 3 and the even mid-band
-- tile 40 carries index 5 on the controls screen, so a source revision
-- carrying different divider ink fails here instead of drifting the
-- product constants silently. Test-only cross-boundary require, mirroring
-- game tests over ROM helpers.
function T.product_divider_inks_match_the_audited_tiles(romFs, _)
  local ok, Interface = pcall(require, "game.hgss.src.options.OptionsInterface")
  Assert.isTrue(ok, "OptionsInterface loads: " .. tostring(Interface))
  local Sources = optionsSources()
  local plates = assert(Sources.rowPlates, "the producer records its audited plate material")
  local archive = assert(romFs:openNarc(Sources.archive.symbol))
  local function decoded(kind, memberId)
    local decodedValue, err = G2dDecoder[kind](plain(archive, memberId), { label = "options:" .. memberId })
    assert(decodedValue, tostring(err and err.message or err))
    return decodedValue
  end
  local palette = decoded("decodePalette", Sources.members.facePalette)
  local function ink(index, what)
    local color = assert(palette.colors[index + 1], what .. " resolves its palette entry")
    return { r = color.r, g = color.g, b = color.b }
  end
  Assert.deepEqual(Interface.DIVIDER_INK.odd, ink(3, "odd divider"), "odd divider ink matches audited tile-14 ink")
  Assert.deepEqual(
    Interface.DIVIDER_INK.even,
    ink(5, "even divider"),
    "even divider ink matches audited tile-40 ink"
  )
  local screen = decoded("decodeScreen", Sources.members.faceScreen)
  local oddTileRow = assert(plates.oddBand, "the producer records its odd band").midTileRow
  local evenTileRow = assert(plates.evenBand, "the producer records its even band").midTileRow
  local oddEntry = screen.entries[oddTileRow * 32 + plates.faceFirstColumn + 1]
  local evenEntry = screen.entries[evenTileRow * 32 + plates.faceFirstColumn + 1]
  Assert.equal(oddEntry.tile, 14, "the odd divider column carries tile 14")
  Assert.equal(evenEntry.tile, 40, "the even divider column carries tile 40")
  local char = decoded("decodeChar", Sources.members.faceChar)
  local tileBytes = char.depth == 3 and 32 or 64
  local function indices(tile)
    local raw = char.tiles:sub(tile * tileBytes + 1, (tile + 1) * tileBytes)
    local seen = {}
    if char.depth == 3 then
      for i = 1, #raw do
        local byte = string.byte(raw, i)
        seen[byte % 16] = true
        seen[math.floor(byte / 16)] = true
      end
    else
      for i = 1, #raw do
        seen[string.byte(raw, i)] = true
      end
    end
    return seen
  end
  local oddSeen = indices(14)
  Assert.isTrue(oddSeen[3] == true, "odd divider tile 14 carries its edge ink")
  local evenSeen = indices(40)
  Assert.isTrue(evenSeen[5] == true, "even divider tile 40 carries its edge ink")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
suite.metadata.derivedAssets = { "field-ui:global" }
return suite
