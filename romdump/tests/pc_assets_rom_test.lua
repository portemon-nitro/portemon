-- Real-dump compilation exposes the retained PC presentation family.

local Assert = require("tests.support.Assert")
local Narc = require("libs.nds.src.nitro.Narc")
local RomSuite = require("tests.rom.support.RomSuite")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageTokenizer = require("romdump.src.digest.ui.FieldMessageTokenizer")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local PcSources = require("romdump.src.config.PcSources")
local charmap = require("romdump.src.reference.hgss.charmap")
local PcAssetSchema = require("libs.assets.src.PcAssetSchema")

local T = {}
local assertSelection

function T.real_map_compilation_marks_pc_terminal_placements_by_semantic_role(romFs, _)
  local bundle = assert(
    MapAssetCompiler.compile(romFs, "MAP_CHERRYGROVE_POKECENTER_1F"),
    "the source Pokecenter map compiles"
  )
  local matched = 0
  for _, placement in ipairs(bundle.scene.buildingInstances) do
    local descriptor = assert(bundle.models[placement.modelKey], "the placement model was compiled")
    local isTerminal = false
    for _, selector in ipairs(PcSources.terminal.buildModels) do
      if bundle.dependencies.buildingArchive == selector.archiveAlias and descriptor.memberId == selector.memberId then
        isTerminal = true
        break
      end
    end
    if isTerminal then
      matched = matched + 1
      Assert.equal(
        placement.semanticRole,
        "pc_terminal",
        "source candidate building models compile to the semantic PC-terminal placement role"
      )
    end
  end
  Assert.isTrue(matched > 0, "the real Pokecenter places a source PC-terminal candidate model")
end

function T.real_source_compiles_all_wallpaper_and_stationery_variants(romFs, _)
  local loaded, PcAssetCompiler = pcall(require, "romdump.src.digest.ui.PcAssetCompiler")
  Assert.isTrue(loaded, "the PC presentation compiler is missing")
  local bundle = assert(PcAssetCompiler.compile(romFs), "the PC presentation bundle compiles")
  local manifest = assert(bundle.manifest, "the compiled family publishes its manifest")
  Assert.deepEqual(
    manifest.terminal,
    {
      slots = {
        [0] = { role = "terminal.on", playMode = "forward" },
        [1] = { role = "terminal.off", playMode = "forward" },
      },
    },
    "terminal metadata retains the runtime slot policy"
  )
  local withoutTerminal = {}
  for key, value in pairs(manifest) do
    if key ~= "terminal" then
      withoutTerminal[key] = value
    end
  end
  Assert.isFalse(PcAssetSchema.isValidManifest(withoutTerminal), "the schema requires source terminal metadata")
  Assert.isNil(manifest.terminal.buildModels, "source model selectors remain producer-side")
  local bank279 = assert(manifest.text.banks[279], "the full source landmark text bank is published")
  Assert.isTrue(type(manifest.text.banks[0]) == "table", "the Photo Album UI source text bank is published")
  Assert.isTrue(PcAssetSchema.isValidManifest(manifest), "the complete PC family passes its strict schema")
  local messageArchive = assert(romFs:openNarc("messages"), "the source message archive opens")
  local bank279Bytes = assert(messageArchive:readMember(279), "the landmark source text bank exists")
  local sourceBank279 = assert(FieldMessageBank.decode(bank279Bytes, { label = "pc-landmark-source" }))
  local compiledMessageCount = 0
  for _ in pairs(bank279) do
    compiledMessageCount = compiledMessageCount + 1
  end
  Assert.equal(compiledMessageCount, #sourceBank279.messages, "every source message in bank 279 is compiled")
  for index, message in ipairs(sourceBank279.messages) do
    local expectedTokens = assert(
      FieldMessageTokenizer.tokenize(message.raw, charmap, { bankId = 279, messageId = index - 1 })
    )
    Assert.deepEqual(bank279[index - 1], expectedTokens, "bank 279 source tokens are retained at index " .. (index - 1))
  end
  local withoutLandmarkText = {}
  for key, value in pairs(manifest) do
    withoutLandmarkText[key] = value
  end
  withoutLandmarkText.text = { banks = {} }
  for key, value in pairs(manifest.text.banks) do
    if key ~= 279 then
      withoutLandmarkText.text.banks[key] = value
    end
  end
  Assert.isFalse(PcAssetSchema.isValidManifest(withoutLandmarkText), "the schema requires source bank 279")
  Assert.isTrue(type(bundle.assets) == "table", "the compiled family returns its referenced image bytes")
  Assert.isTrue(type(bundle.provenance) == "table", "the compiled family returns source provenance")
  local archives = assert(bundle.provenance.archives)
  local selections = assert(bundle.provenance.selections)
  Assert.keySet(archives, "mailbox,photoAlbum,stationery,storage", "retained source archive inventory")
  for _, expected in ipairs({
    { key = "storage", path = "a/0/1/9", memberCount = 87, selectedMemberCount = 87 },
    { key = "mailbox", path = "a/2/5/0", memberCount = 11, selectedMemberCount = 11 },
    { key = "stationery", path = "a/0/7/9", memberCount = 37, selectedMemberCount = 36 },
    { key = "photoAlbum", path = "a/1/7/1", memberCount = 13, selectedMemberCount = 13 },
  }) do
    local archive = assert(archives[expected.key], "the compiler records " .. expected.key .. " archive provenance")
    Assert.equal(archive.path, expected.path, expected.key .. " uses the expected source archive")
    Assert.equal(archive.fileId, romFs:fileIdForPath(expected.path), expected.key .. " records its ROM file identity")
    Assert.equal(archive.memberCount, expected.memberCount, expected.key .. " archive member inventory")
    Assert.equal(
      archive.selectedMemberCount,
      expected.selectedMemberCount,
      expected.key .. " selected source member inventory"
    )
    local sourceArchive = assert(Narc.open(assert(romFs:read(expected.path))))
    Assert.equal(sourceArchive:memberCount(), expected.memberCount, expected.key .. " source NARC member count")
  end
  for bit = 0, 5 do
    for _, expected in ipairs({
      { state = "clear", tileId = 0x1a + bit },
      { state = "set", tileId = 0x3a + bit },
    }) do
      local selection = assert(
        selections["storage.markings." .. bit .. "." .. expected.state],
        "the compiler records bit-indexed " .. expected.state .. " marking tile " .. bit
      )
      Assert.equal(selection.path, "a/0/1/9", "Storage marking art resolves through its source archive")
      Assert.equal(
        selection.fileId,
        romFs:fileIdForPath("a/0/1/9"),
        "Storage marking art records its ROM file identity"
      )
      Assert.deepEqual(
        selection.members,
        { character = 6, palette = 7 },
        "Storage marking art selects the source character and palette members"
      )
      Assert.equal(selection.tileId, expected.tileId, "Storage marking state maps to its source BG tile ID")
      Assert.equal(selection.paletteBank, 0, "Storage marking tiles use BG5 palette bank zero")
    end
  end
  for path in pairs(bundle.assets) do
    local loweredPath = string.lower(path)
    Assert.isTrue(
      path:sub(1, #"assets/generated/pc/") == "assets/generated/pc/",
      "PC outputs stay in the PC asset family"
    )
    Assert.isNil(loweredPath:find("capsule", 1, true), "capsule assets are not copied into the PC family")
    Assert.isNil(loweredPath:find("species", 1, true), "species atlases are referenced, not copied into the PC family")
  end
  local wallpapers = assert(manifest.storage.wallpapers)
  local wallpaperCount = 0
  for _ in pairs(wallpapers) do
    wallpaperCount = wallpaperCount + 1
  end
  Assert.equal(wallpaperCount, 24, "all 24 wallpaper identities resolve")
  for wallpaperId = 0, 15 do
    Assert.notNil(wallpapers[wallpaperId], "default wallpaper identity resolves: " .. wallpaperId)
  end
  for wallpaperId = 32, 39 do
    Assert.notNil(wallpapers[wallpaperId], "bonus wallpaper identity resolves: " .. wallpaperId)
  end
  for _, expected in ipairs({
    { style = "standard", characterByteOffset = 0 },
    { style = "accent", characterByteOffset = 384 },
  }) do
    for sourcePaletteBank = 0, 1 do
      local selection = assert(
        selections["storage.windowFrames." .. expected.style .. ".paletteBank" .. sourcePaletteBank],
        "the compiler records the Storage " .. expected.style .. " frame with source bank " .. sourcePaletteBank
      )
      Assert.equal(selection.path, "a/0/1/9", "Storage frame art resolves through its source archive")
      Assert.equal(selection.fileId, romFs:fileIdForPath("a/0/1/9"), "Storage frame art records its ROM file identity")
      Assert.deepEqual(
        selection.members,
        { character = 64, palette = 65 },
        "Storage frame style selects the source character and palette members"
      )
      Assert.equal(selection.characterByteOffset, expected.characterByteOffset, "Storage frame source byte offset")
      Assert.equal(selection.sourcePaletteBank, sourcePaletteBank, "Storage frame local NCLR palette bank")
      Assert.equal(selection.destinationPaletteSlot, 12 + sourcePaletteBank, "Storage frame MAIN_BG palette slot")
    end
  end
  local stationery = assert(manifest.mail.stationery)
  local stationeryCount = 0
  for _ in pairs(stationery) do
    stationeryCount = stationeryCount + 1
  end
  Assert.equal(stationeryCount, 12, "all 12 stationery triplets resolve")
  for stationeryType = 0, 11 do
    local record = assert(stationery[stationeryType], "stationery identity resolves: " .. stationeryType)
    Assert.equal(
      record.itemKey,
      ({
        "GRASS_MAIL",
        "FLAME_MAIL",
        "BUBBLE_MAIL",
        "BLOOM_MAIL",
        "TUNNEL_MAIL",
        "STEEL_MAIL",
        "HEART_MAIL",
        "SNOW_MAIL",
        "SPACE_MAIL",
        "AIR_MAIL",
        "MOSAIC_MAIL",
        "BRICK_MAIL",
      })[stationeryType + 1],
      "stationery retains its semantic item-catalog identity: " .. stationeryType
    )
  end

  for wallpaperId = 0, 15 do
    assertSelection(
      romFs,
      selections,
      "storage.wallpapers." .. wallpaperId,
      "a/0/1/9",
      { character = 16 + wallpaperId, palette = 40 + wallpaperId, screen = 15 }
    )
  end
  for wallpaperId = 32, 39 do
    local artOrdinal = wallpaperId - 16
    assertSelection(
      romFs,
      selections,
      "storage.wallpapers." .. wallpaperId,
      "a/0/1/9",
      { character = 16 + artOrdinal, palette = 40 + artOrdinal, screen = 15 }
    )
  end
  for stationeryType = 0, 11 do
    assertSelection(
      romFs,
      selections,
      "mail.stationery." .. stationeryType,
      "a/0/7/9",
      { palette = stationeryType, character = stationeryType + 12, screen = stationeryType + 24 }
    )
  end
  assertSelection(
    romFs,
    selections,
    "mailbox.background",
    "a/2/5/0",
    { character = 1, screen = 0, palette = 2 },
    "main",
    3
  )
  for _, expected in ipairs({
    {
      selector = "mailbox.loader.ov103_021ECC1C.subBg7",
      members = { character = 5, screen = 4, palette = 6 },
      bg = 7,
    },
    {
      selector = "mailbox.loader.ov103_021ECC1C.mainBg3",
      members = { character = 1, screen = 0, palette = 2 },
      bg = 3,
    },
    {
      selector = "mailbox.loader.ov103_021ECC1C.mainBg1",
      members = { character = 1 },
      bg = 1,
    },
  }) do
    assertSelection(romFs, selections, expected.selector, "a/2/5/0", expected.members, expected.engine, expected.bg)
  end
  for _, expected in ipairs({
    { selector = "photoAlbum.background.albumCanvas", members = { character = 9, palette = 4, screen = 10 }, bg = 6 },
    { selector = "photoAlbum.background.albumControls", members = { character = 5, palette = 4, screen = 6 }, bg = 3 },
  }) do
    assertSelection(romFs, selections, expected.selector, "a/1/7/1", expected.members, nil, expected.bg)
  end

  local dictionary = assert(manifest.mail.wordDictionary, "mail compiles the complete Easy Chat word dictionary")
  local dictionaryCount = 0
  for _ in pairs(dictionary) do
    dictionaryCount = dictionaryCount + 1
  end
  Assert.equal(dictionaryCount, 1495, "all source Easy Chat word references resolve")
  for _, wordId in ipairs({ 0, 496, 964, 982, 1106, 1494 }) do
    Assert.isTrue(
      type(dictionary[tostring(wordId)]) == "table" and #dictionary[tostring(wordId)] > 0,
      "word reference resolves: " .. wordId
    )
  end
  local templates = assert(manifest.mail.text.templates, "MailMessage templates have semantic identities")
  local templateCount = 0
  for bankIndex, bankId in ipairs({ 294, 296, 292, 293, 295 }) do
    local messages = assert(manifest.text.banks[bankId], "the source line bank is compiled")
    for messageIndex = 0, #messages - 1 do
      local templateKey = "mail-template:" .. (bankIndex - 1) .. ":" .. messageIndex
      Assert.deepEqual(
        templates[templateKey],
        messages[messageIndex + 1],
        "Mail template maps its source bank and message"
      )
      templateCount = templateCount + 1
    end
  end
  local actualTemplateCount = 0
  for _ in pairs(templates) do
    actualTemplateCount = actualTemplateCount + 1
  end
  Assert.equal(actualTemplateCount, templateCount, "Mail template catalog has no unsupported keys")
end

assertSelection = function(romFs, selections, selector, path, members, engine, bg)
  local selection = assert(selections[selector], "the compiler records " .. selector)
  Assert.equal(selection.path, path, selector .. " resolves through the expected archive path")
  Assert.equal(selection.fileId, romFs:fileIdForPath(path), selector .. " records the selected ROM file identity")
  Assert.deepEqual(selection.members, members, selector .. " records the exact semantic member indices")
  if engine ~= nil then
    Assert.equal(selection.engine, engine, selector .. " preserves the display engine")
  end
  if bg ~= nil then
    Assert.equal(selection.bg, bg, selector .. " preserves the background layer")
  end
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
