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
  Assert.equal(section.version, 2)
  local DisplayTiming = require("libs.nds.src.gx.DisplayTiming")
  Assert.equal(section.animationTickSeconds, 1 / DisplayTiming.REFRESH_HZ)
  local labels = assert(section.labels, "the section carries its labels")
  for _, key in ipairs({ "title", "textSpeed", "battleScene", "battleStyle", "soundMode", "textFrame", "confirm", "quit" }) do
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
        pixels[#pixels + 1] =
          rgba:sub((y + frame.atlas.y) * width * 4 + (x + frame.atlas.x) * 4 + 1, (y + frame.atlas.y) * width * 4 + (x + frame.atlas.x) * 4 + 4)
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
  -- The unselected small face reproduces the baseline screen crop.
  do
    local char = decoded("decodeChar", 7)
    local palette = decoded("decodePalette", 2)
    local screen = decoded("decodeScreen", 17)
    local reference = G2dRasterizer.renderScreen(char, { colors = palette.colors }, screen, { asset = "options", member = 17 })
    local crop = {}
    for y = 24, 24 + 32 - 1 do
      for x = 112, 112 + 48 - 1 do
        local off = (y * reference.width + x) * 4 + 1
        crop[#crop + 1] = reference.pixels:sub(off, off + 3)
      end
    end
    Assert.deepEqual(atlasPixels(section.choices.small.unselected.frames[1]), crop)
  end
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

function T.backdrops_derive_from_the_audited_base_screens(romFs, versionId)
  local bundle = compileOptions(romFs, versionId)
  local section = assert(bundle.section, "the compiler returns its semantic section")
  Assert.equal(section.version, 2, "the options section carries its backdrop contract")
  Assert.equal(
    section.backdrops.controls,
    FieldUiAssetCache.ASSET.OPTIONS_CONTROLS_BACKGROUND,
    "the controls backdrop carries its semantic role"
  )
  Assert.equal(
    section.backdrops.preview,
    FieldUiAssetCache.ASSET.OPTIONS_PREVIEW_BACKGROUND,
    "the preview backdrop carries its semantic role"
  )
  local controlsImage = FieldUiAssetCache.assetDir() .. "/options-controls-background.png"
  local previewImage = FieldUiAssetCache.assetDir() .. "/options-preview-background.png"
  local controlsBytes = assert(bundle.files[controlsImage], "the controls backdrop is staged")
  local previewBytes = assert(bundle.files[previewImage], "the preview backdrop is staged")
  local function stagedRgba(bytes, what)
    local width, height, rgba = PngReader.rgba(bytes)
    Assert.equal(width, 256, what .. " width")
    Assert.equal(height, 192, what .. " height")
    return rgba
  end
  local controlsRgba = stagedRgba(controlsBytes, "the controls backdrop")
  local previewRgba = stagedRgba(previewBytes, "the preview backdrop")
  local Sources = optionsSources()
  local archive = assert(romFs:openNarc(Sources.archive.symbol))
  local function decoded(kind, memberId)
    local decodedValue, err = G2dDecoder[kind](plain(archive, memberId), { label = "options:" .. memberId })
    assert(decodedValue, tostring(err and err.message or err))
    return decodedValue
  end
  -- The expected visible viewport: an audited source map with palette-zero
  -- normalized to the same palette's opaque backdrop, cropped to the top
  -- 256x192 rows (or fewer for a shorter source plane).
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
  Assert.equal(controlsRgba, expectedRgba(7, 2, 17, true), "the controls backdrop matches the MAIN base")
  Assert.equal(previewRgba, expectedRgba(8, 3, 19, true), "the preview backdrop matches the SUB base")
  Assert.isTrue(
    controlsRgba ~= expectedRgba(7, 2, 18, false),
    "the controls backdrop is not the separate selection layer"
  )
  Assert.isTrue(controlsRgba ~= previewRgba, "the two backdrop roles carry distinct rasters")
  local function assertOpaque(rgba, what)
    for index = 4, #rgba, 4 do
      if string.byte(rgba, index) ~= 255 then
        Assert.fail(what .. " pixel " .. math.floor(index / 4) .. " is not opaque")
      end
    end
  end
  assertOpaque(controlsRgba, "the controls backdrop")
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
  Assert.equal(options.version, 2)
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

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
suite.metadata.derivedAssets = { "field-ui:global" }
return suite
