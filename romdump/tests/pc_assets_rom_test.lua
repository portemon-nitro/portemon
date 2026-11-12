-- Real-dump compilation exposes the retained PC presentation family.

local Assert = require("tests.support.Assert")
local Narc = require("libs.nds.src.nitro.Narc")
local RomSuite = require("tests.rom.support.RomSuite")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageTokenizer = require("romdump.src.digest.ui.FieldMessageTokenizer")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local PcSources = require("romdump.src.config.PcSources")
local charmap = require("romdump.src.catalog.hgss.charmap")
local PcAssetSchema = require("libs.assets.src.PcAssetSchema")

local T = {}
local assertSelection

function T.real_map_compilation_marks_pc_terminal_placements_by_semantic_role(romFs, _)
  local bundle =
    assert(MapAssetCompiler.compile(romFs, "MAP_CHERRYGROVE_POKECENTER_1F"), "the source Pokecenter map compiles")
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
  Assert.deepEqual(manifest.terminal, {
    slots = {
      [0] = { role = "terminal.on", playMode = "forward" },
      [1] = { role = "terminal.off", playMode = "forward" },
    },
  }, "terminal metadata retains the runtime slot policy")
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
    local expectedTokens =
      assert(FieldMessageTokenizer.tokenize(message.raw, charmap, { bankId = 279, messageId = index - 1 }))
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
    { key = "stationery", path = "a/0/7/9", memberCount = 37, selectedMemberCount = 37 },
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

  -- The retired duplicate catalog is gone: Easy Chat words and templates
  -- belong to the shared family, never to the PC manifest.
  Assert.isNil(manifest.mail.text, "PC mail carries no duplicate template catalog")
  Assert.isNil(manifest.mail.wordDictionary, "PC mail carries no duplicate word dictionary")
  Assert.isNil(manifest.text.banks[292], "PC text drops the retired MailMessage banks")
  Assert.isNil(manifest.text.banks[294], "PC text drops the retired MailMessage banks")
  local mailViewBank = assert(manifest.text.banks[233], "the MailView chrome rides ordinary text bank 233")
  local mailViewCount = 0
  for _ in pairs(mailViewBank) do
    mailViewCount = mailViewCount + 1
  end
  Assert.equal(mailViewCount, 4, "bank 233 carries exactly its four MailView messages")

  -- The write chrome is compiled per stationery type from the source
  -- members: the native BG2-over-BG3 composite, the repeated top-display
  -- backdrop, five cursor-ordered fourteen-level highlight sets, and five
  -- rect-local touch masks. Masks re-derive from independently decoded
  -- source character pixel indices: eligible unless the index is 1.
  local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
  local stationeryArchive = assert(romFs:openNarc("NARC_a_0_7_9"), "stationery source opens")
  local writeControls = {
    { x = 24, y = 24, width = 208, height = 32 },
    { x = 24, y = 64, width = 208, height = 32 },
    { x = 24, y = 104, width = 208, height = 32 },
    { x = 24, y = 148, width = 64, height = 24 },
    { x = 160, y = 148, width = 64, height = 24 },
  }
  for stationeryType = 0, 11 do
    local write = assert(
      manifest.mail.stationery[stationeryType].write,
      "stationery " .. stationeryType .. " carries its write chrome"
    )
    Assert.equal(write.background.width, 256, "the write composite keeps the native surface")
    Assert.equal(write.background.height, 192, "the write composite keeps the native surface")
    Assert.equal(write.backdrop.width, 256, "the top backdrop keeps the native surface")
    Assert.equal(write.backdrop.height, 192, "the top backdrop keeps the native surface")
    Assert.isTrue(#write.highlights == 5, "write chrome carries five cursor-ordered highlights")
    Assert.isTrue(#write.hitMasks == 5, "write chrome carries five rect-local touch masks")
    local charBytes = assert(stationeryArchive:readMember(12 + stationeryType))
    local charData = assert(G2dDecoder.decodeChar(charBytes, { label = "pc-test-char" }))
    assert(charData.depth == 3, "stationery write chrome uses 4bpp tiles")
    local buttonBytes = assert(stationeryArchive:readMember(36))
    local buttonScreen = assert(G2dDecoder.decodeScreen(buttonBytes, { label = "pc-test-buttons" }))
    local columns = math.floor(buttonScreen.width / 8)
    for position, control in ipairs(writeControls) do
      local mask = assert(write.hitMasks[position], "mask order follows source cursor order")
      Assert.equal(mask.x, control.x, "mask " .. position .. " keeps its source x")
      Assert.equal(mask.y, control.y, "mask " .. position .. " keeps its source y")
      Assert.equal(mask.width, control.width, "mask " .. position .. " keeps its source width")
      Assert.equal(mask.height, control.height, "mask " .. position .. " keeps its source height")
      Assert.equal(#mask.rows, control.height, "mask rows match the control height")
      for y = 0, control.height - 1 do
        local bits = assert(mask.rows[y + 1], "mask rows are dense")
        Assert.equal(#bits, control.width, "mask rows match the control width")
        Assert.isTrue(bits:find("[^01]") == nil, "mask rows are binary strings")
        for x = 0, control.width - 1 do
          local entry =
            buttonScreen.entries[math.floor((control.y + y) / 8) * columns + math.floor((control.x + x) / 8) + 1]
          local lx, ly = (control.x + x) % 8, (control.y + y) % 8
          if entry.flipH then
            lx = 7 - lx
          end
          if entry.flipV then
            ly = 7 - ly
          end
          local byte = string.byte(charData.tiles, entry.tile * 32 + ly * 4 + math.floor(lx / 2) + 1)
          local index = (lx % 2 == 0) and (byte % 16) or math.floor(byte / 16)
          local expected = index == 1 and "0" or "1"
          Assert.equal(
            bits:sub(x + 1, x + 1),
            expected,
            "mask bit rejects only source pixel index 1 at " .. control.x + x .. "," .. control.y + y
          )
        end
      end
      local highlight = assert(write.highlights[position], "highlight order follows source cursor order")
      Assert.equal(#highlight.frames, 14, "highlight " .. position .. " carries fourteen blend levels")
      Assert.isTrue(
        highlight.width > 0 and highlight.height > 0,
        "highlight " .. position .. " crops a non-empty rectangle"
      )
      for _, frame in ipairs(highlight.frames) do
        Assert.equal(frame.width, highlight.width, "highlight frames match their cropped rectangle")
        Assert.equal(frame.height, highlight.height, "highlight frames match their cropped rectangle")
        Assert.isTrue(
          type(bundle.assets[frame.image]) == "string",
          "highlight frame stages its compiled visual: " .. frame.image
        )
      end
      Assert.isTrue(
        bundle.assets[highlight.frames[1].image] ~= bundle.assets[highlight.frames[14].image],
        "the pulse visibly blends highlight " .. position .. " toward white"
      )
      -- The cropped rectangle matches the independently decoded users
      -- of the control pulse entry 0x22+position.
      local entry = 0x22 + position - 1
      local bank, value = math.floor(entry / 16), entry % 16
      local minX, minY, maxX, maxY = 256, 192, -1, -1
      for y = 0, 191 do
        for x = 0, 255 do
          local screenEntry = buttonScreen.entries[math.floor(y / 8) * columns + math.floor(x / 8) + 1]
          if screenEntry.palette == bank then
            local lx, ly = x % 8, y % 8
            if screenEntry.flipH then
              lx = 7 - lx
            end
            if screenEntry.flipV then
              ly = 7 - ly
            end
            local pixel = string.byte(charData.tiles, screenEntry.tile * 32 + ly * 4 + math.floor(lx / 2) + 1)
            local index = (lx % 2 == 0) and (pixel % 16) or math.floor(pixel / 16)
            if index == value and index ~= 0 then
              minX = math.min(minX, x)
              minY = math.min(minY, y)
              maxX = math.max(maxX, x)
              maxY = math.max(maxY, y)
            end
          end
        end
      end
      Assert.isTrue(maxX >= minX, "pulse entry 0x22+" .. (position - 1) .. " has source pixels")
      Assert.equal(highlight.x, minX, "highlight crops to actual changed pixels, not assumed bounds")
      Assert.equal(highlight.y, minY, "highlight crops to actual changed pixels, not assumed bounds")
      Assert.equal(highlight.width, maxX - minX + 1, "highlight crops to actual changed pixels, not assumed bounds")
      Assert.equal(highlight.height, maxY - minY + 1, "highlight crops to actual changed pixels, not assumed bounds")
    end
    assertSelection(romFs, selections, "mail.write." .. stationeryType, "a/0/7/9", {
      palette = stationeryType,
      character = stationeryType + 12,
      screen = stationeryType + 24,
      buttons = 36,
    })
  end
  Assert.isTrue(PcAssetSchema.isValidManifest(manifest), "the write chrome stays schema-compatible")
  local function staleCopy(value)
    if type(value) ~= "table" then
      return value
    end
    local out = {}
    for key, child in pairs(value) do
      out[key] = staleCopy(child)
    end
    return out
  end
  local staleManifest = staleCopy(manifest)
  staleManifest.schema = "g4-pc-v3"
  Assert.isFalse(PcAssetSchema.isValidManifest(staleManifest), "stale PC manifests rebuild instead of aliasing")
end

function T.real_source_compiles_party_mail_bank_and_sprite_roles(romFs, _)
  local loaded, PcAssetCompiler = pcall(require, "romdump.src.digest.ui.PcAssetCompiler")
  Assert.isTrue(loaded, "the PC presentation compiler is missing")
  local bundle = assert(PcAssetCompiler.compile(romFs), "the PC presentation bundle compiles")
  local manifest = assert(bundle.manifest, "the compiled family publishes its manifest")
  Assert.isTrue(PcAssetSchema.isValidManifest(manifest), "the extra party-mail bank stays schema-compatible")
  Assert.equal(PcSources.mailText.partyMailBank, 300, "the party-mail bank identity is pinned")
  local bank300 = assert(manifest.text.banks[300], "the party TakeMail message bank is compiled")
  local messageArchive = assert(romFs:openNarc("messages"), "the source message archive opens")
  local bank300Bytes = assert(messageArchive:readMember(300), "the party source text bank exists")
  local sourceBank300 = assert(FieldMessageBank.decode(bank300Bytes, { label = "pc-party-mail-source" }))
  local compiledMessageCount = 0
  for _ in pairs(bank300) do
    compiledMessageCount = compiledMessageCount + 1
  end
  Assert.equal(compiledMessageCount, #sourceBank300.messages, "every source message in bank 300 is compiled")
  local function displayText(tokens)
    local parts = {}
    for _, token in ipairs(tokens) do
      if token.kind == "glyph" then
        parts[#parts + 1] = token.text
      elseif token.kind == "line_break" then
        parts[#parts + 1] = "\n"
      end
    end
    return table.concat(parts)
  end
  for _, expected in ipairs({
    { id = 44, text = "Send the removed Mail to\nyour PC?" },
    { id = 47, text = "The Mail was sent to your PC." },
    { id = 48, text = "If the Mail is removed, its written\nmessage will be lost. Is that OK?" },
    { id = 51, text = "Your PC’s Mailbox is full." },
    { id = 52, text = "Mail was taken from the\nPokémon." },
    { id = 84, text = "The Bag is full." },
  }) do
    Assert.equal(
      displayText(assert(bank300[expected.id], "bank 300 carries message " .. expected.id)),
      expected.text,
      "bank 300 msg " .. expected.id .. " keeps its source text"
    )
  end
  Assert.deepEqual(PcSources.mailboxSpriteRoles, {
    cursor = { animations = { 4, 5 } },
    pagePrevious = { animation = 0 },
    pageNext = { animation = 1 },
    cursorGrid = {
      closeInput = 10,
      cells = {
        { x = 64, y = 16 },
        { x = 192, y = 16 },
        { x = 64, y = 48 },
        { x = 192, y = 48 },
        { x = 64, y = 80 },
        { x = 192, y = 80 },
        { x = 64, y = 112 },
        { x = 192, y = 112 },
        { x = 64, y = 144 },
        { x = 192, y = 144 },
        { x = 224, y = 176 },
      },
    },
    sprite3 = { animation = 2, x = 224, y = 176 },
  }, "mailbox sprite roles pin the decomp cursor/page-arrow animation ids")
  local animations = assert(manifest.mailbox.ui.animations, "mailbox UI animations are compiled")
  for _, animId in ipairs({ 0, 1, 2, 4, 5 }) do
    local entry = assert(animations[animId], "the sprite role animation is compiled: " .. animId)
    Assert.equal(#entry.frames, 1, "the role animation carries its single source frame: " .. animId)
  end
  for _, key in ipairs({
    "mailbox.animation.0",
    "mailbox.animation.1",
    "mailbox.animation.2",
    "mailbox.animation.4",
    "mailbox.animation.5",
  }) do
    local sequence = assert(manifest.sequences[key], "the sprite role sequence resolves: " .. key)
    Assert.equal(#sequence.frames, 1, "the role sequence carries its single source frame: " .. key)
  end
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
