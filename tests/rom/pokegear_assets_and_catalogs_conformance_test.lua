-- ROM conformance: the Pokegear family compiles from the real dump with exact
-- provenance. Every selected member of the five core graphics archives, the
-- twenty sprite resource descriptors, and the phonebook carries its source
-- path, member index, and byte hash into the published receipt; the full
-- 276-member research closure is accounted for with no invented resources;
-- and members outside the closure are explicitly classified instead of
-- silently dropped. Archive/member expectations pin the HeartGold evidence
-- anchors and the retail ROM sprite bindings independently of the
-- compiler under test. Member bytes are never committed to the repository.

local Assert = require("tests.support.Assert")
local Hashing = require("romdump.src.digest.Hashing")
local Narc = require("libs.nds.src.nitro.Narc")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

-- HeartGold evidence anchors: source path plus the closed member set the
-- family selects. Physical identities stay in provenance; they are never
-- cross-version constants.
local EXPECTED_ARCHIVES = {
  { role = "common shell", path = "a/1/4/3", firstMember = 0, lastMember = 59 },
  { role = "map and standalone fly", path = "a/1/4/4", firstMember = 0, lastMember = 69 },
  { role = "configure", path = "a/1/4/5", firstMember = 0, lastMember = 27 },
  { role = "phone", path = "a/1/4/6", firstMember = 0, lastMember = 51 },
  { role = "radio", path = "a/1/4/7", firstMember = 0, lastMember = 45 },
}

-- Retail ROM sprite bindings: CHAR/PLTT/CELL/ANIM descriptor members in
-- archive a/1/7/5 plus the header member that binds each set to graphics.
local SPRITE_ARCHIVE_PATH = "a/1/7/5"
local EXPECTED_SPRITE_BINDINGS = {
  { set = "map", char = 34, palette = 35, cell = 33, anim = 32, header = 80 },
  { set = "configure", char = 42, palette = 43, cell = 41, anim = 40, header = 82 },
  { set = "phone", char = 46, palette = 47, cell = 45, anim = 44, header = 83 },
  { set = "radio", char = 38, palette = 39, cell = 37, anim = 36, header = 81 },
}

local PHONEBOOK_PATH = "tel/pmtel_book.dat"
local PHONEBOOK_HG_BYTES = 1504

-- 60 + 70 + 28 + 52 + 46 core members plus 20 sprite descriptors.
local EXPECTED_SELECTED_COUNT = 276

local function openArchive(romFs, path)
  local bytes, err = romFs:readSourcePath(path)
  Assert.notNil(bytes, "the dump must expose archive " .. path .. ": " .. tostring(err))
  local archive, narcErr = Narc.open(assert(bytes), path)
  Assert.notNil(archive, "archive " .. path .. " must open: " .. tostring(narcErr))
  return assert(archive)
end

-- Independently hashes every selected member straight from the dump: the
-- oracle never calls the compiler under test.
local function independentHashes(romFs)
  local hashes = {}
  local count = 0
  for _, archive in ipairs(EXPECTED_ARCHIVES) do
    local opened = openArchive(romFs, archive.path)
    for memberId = archive.firstMember, archive.lastMember do
      local bytes =
        assert(opened:readMember(memberId), archive.role .. " member " .. memberId .. " must exist in the dump")
      hashes[archive.path .. ":member:" .. memberId] = Hashing.sha1hex(bytes)
      count = count + 1
    end
  end
  local sprites = openArchive(romFs, SPRITE_ARCHIVE_PATH)
  for _, binding in ipairs(EXPECTED_SPRITE_BINDINGS) do
    for _, memberId in ipairs({ binding.char, binding.palette, binding.cell, binding.anim, binding.header }) do
      local bytes = assert(
        sprites:readMember(memberId),
        binding.set .. " descriptor member " .. memberId .. " must exist in the dump"
      )
      hashes[SPRITE_ARCHIVE_PATH .. ":member:" .. memberId] = Hashing.sha1hex(bytes)
      count = count + 1
    end
  end
  return hashes, count
end

-- Collects the compiler's published selection into the same key space the
-- independent oracle uses: source path plus member index, each with a hash.
local function publishedSelection(bundle)
  local selected = {}
  local provenance = assert(bundle.provenance or bundle.dependencies, "the bundle must publish its provenance")
  local entries = provenance.entries or provenance.members or provenance
  if entries.dependencies ~= nil then
    entries = entries.dependencies
  end
  for _, entry in ipairs(entries) do
    local key = nil
    if entry.path ~= nil and entry.member ~= nil then
      key = entry.path .. ":member:" .. tostring(entry.member)
    elseif type(entry.name) == "string" then
      key = entry.name
    end
    if key ~= nil then
      selected[key] = entry.sha1 or entry.hash or entry.digest
    end
  end
  return selected
end

-- One family compilation per version, shared by every conformance test
-- in this file: the compile (NARC opens plus G2D decodes plus PNG encodes
-- for the whole family) is the dominant ROM cost here, and recompiling it
-- per test buys no new coverage. Cached bytes only; the open readers stay
-- owned by the suite hooks.
local compiledByVersion = {}
---@param romFs table
---@param versionId string
---@return table
local function compileFamily(romFs, versionId)
  local cached = compiledByVersion[versionId]
  if cached == nil then
    local loaded, PokegearAssetCompiler = pcall(require, "romdump.src.digest.ui.PokegearAssetCompiler")
    Assert.isTrue(loaded, "the pokegear family compiler must be published")
    cached = assert(
      PokegearAssetCompiler.compile(romFs, versionId),
      "the pokegear family must compile from the owned dump"
    )
    compiledByVersion[versionId] = cached
  end
  return cached
end

function T.pokegear_family_accounts_for_the_full_selected_resource_closure(romFs, versionId)
  local compiled = compileFamily(romFs, versionId)

  local expected, expectedCount = independentHashes(romFs)
  Assert.equal(expectedCount, EXPECTED_SELECTED_COUNT, "the research closure selects exactly 276 resources")

  local selected = publishedSelection(compiled)
  local publishedCount = 0
  for key, expectedHash in pairs(expected) do
    local publishedHash = selected[key]
    Assert.notNil(publishedHash, "the published selection must account for " .. key)
    Assert.equal(publishedHash, expectedHash, key .. " must carry its exact dump byte hash")
    publishedCount = publishedCount + 1
  end
  Assert.equal(publishedCount, EXPECTED_SELECTED_COUNT, "every selected resource must be accounted for exactly once")

  for _, binding in ipairs(EXPECTED_SPRITE_BINDINGS) do
    for _, memberId in ipairs({ binding.char, binding.palette, binding.cell, binding.anim, binding.header }) do
      local key = SPRITE_ARCHIVE_PATH .. ":member:" .. memberId
      Assert.notNil(selected[key], binding.set .. " must bind descriptor member " .. memberId)
    end
  end

  if versionId == "heartgold" then
    local phonebookBytes = romFs:readSourcePath(PHONEBOOK_PATH)
    if phonebookBytes ~= nil then
      Assert.equal(
        #phonebookBytes,
        PHONEBOOK_HG_BYTES,
        "the supplied HeartGold phonebook keeps its 1504-byte whole-file identity"
      )
      local selectedPhonebook = selected[PHONEBOOK_PATH]
        or selected[PHONEBOOK_PATH .. ":member:whole"]
        or selected["phonebook"]
      Assert.notNil(selectedPhonebook, "the published selection must account for the phonebook file")
    end
  end
end

-- The world map screen (member 11 of the map archive) stores row-major:
-- retail never uploads it as a VRAM hardware image but reads it
-- piece-wise through CopyToBgTilemapRect with stride width/8 behind
-- PokegearMap_DrawMapTilemap (pokegear_map_view.c). The compiled world
-- planes must match an independent row-major render of the same members,
-- and must differ from the hardware-blocked reading, or the map screen
-- shows jumbled tiles.
function T.pokegear_world_planes_compile_row_major(romFs, versionId)
  local compiled = compileFamily(romFs, versionId)
  local manifest = assert(compiled.manifest, "the bundle carries its manifest")
  local assets = assert(compiled.assets or compiled.files, "the bundle carries its staged assets")
  local selections = assert(compiled.provenance.selections, "the bundle publishes its selections")
  local worldSelection = assert(
    selections["map.world.skin0"],
    "the bundle publishes the world plane selection"
  )
  Assert.equal(
    worldSelection.members.layout,
    "linear",
    "the world plane selection declares the row-major layout"
  )
  local flySelection = assert(selections["fly.world"], "the bundle publishes the fly world selection")
  Assert.equal(flySelection.members.layout, "linear", "the fly world selection declares the row-major layout")

  local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
  local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
  local PngWriter = require("romdump.src.digest.PngEncoder")
  local Lz10 = require("romdump.src.digest.Lz10")
  local archive = openArchive(romFs, "a/1/4/4")
  local function plain(memberId)
    local bytes = assert(archive:readMember(memberId), "the map archive carries member " .. memberId)
    if string.byte(bytes, 1) == 0x10 then
      return assert(Lz10.decode(bytes))
    end
    return bytes
  end
  local character = assert(G2dDecoder.decodeChar(plain(10), {}))
  local palette = assert(G2dDecoder.decodePalette(plain(20), {}))
  local charData = { depth = character.depth, tiles = character.tiles }
  local function render(layout)
    local screen = assert(G2dDecoder.decodeScreen(plain(11), { layout = layout })) --[[@as table]]
    local image = G2dRasterizer.renderScreen(charData, palette, screen, { role = "conformance-world" })
    return PngWriter.encode(image.width, image.height, image.pixels)
  end
  local mapWorld = assert(manifest.map, "the manifest carries its map section").world
  local skinZero = assert(mapWorld[0], "the map section carries its first skin")
  local staged = assert(assets[skinZero.image], "the staged assets carry the world plane")
  Assert.equal(staged, render("linear"), "the staged world plane matches the row-major render")
  Assert.isTrue(
    staged ~= render(nil),
    "the staged world plane differs from the hardware-blocked reading"
  )
end

-- The shell OBJ set (clock digits, colon, weekday, reception, strip
-- corners) is skinned: character members 6+skin and palette members 0+skin
-- share cell member 12 and animation member 13. The manifest must carry
-- per-skin frames under sequences["shell.cursor.skins"], the skins must
-- differ from one another, and one staged frame must match an independent
-- render straight from the dump so writer and reader cannot share a
-- mistake. The legacy flat shell.cursor.<id> entries keep the skin-zero
-- frames for older readers.
function T.pokegear_shell_cursor_compiles_per_skin(romFs, versionId)
  local compiled = compileFamily(romFs, versionId)
  local manifest = assert(compiled.manifest, "the bundle carries its manifest")
  local assets = assert(compiled.assets or compiled.files, "the bundle carries its staged assets")
  local sequences = assert(manifest.sequences, "the manifest carries its sequences")
  local skins = assert(sequences["shell.cursor.skins"], "the shell cursor compiles its per-skin frames")
  for skin = 0, 5 do
    local map = assert(skins[skin], "the shell cursor carries skin " .. skin)
    -- The runtime clock strip reads sequences 1-4 and the strip corners
    -- read sequences 5-8; every skin carries the full set.
    for sequenceId = 1, 8 do
      local clip = assert(map["shell.cursor." .. sequenceId], "skin " .. skin .. " carries sequence " .. sequenceId)
      Assert.isTrue(
        type(clip.frames) == "table" and #clip.frames > 0,
        "skin " .. skin .. " sequence " .. sequenceId .. " carries its frames"
      )
    end
  end
  local legacy = assert(sequences["shell.cursor.1"], "the legacy skin-zero digit strip stays published")
  Assert.isTrue(
    type(legacy.frames) == "table" and #legacy.frames > 0,
    "the legacy skin-zero digit strip carries its frames"
  )
  local zeroFrames = assert(skins[0]["shell.cursor.1"], "skin zero carries its digit strip").frames
  local threeFrames = assert(skins[3]["shell.cursor.1"], "skin three carries its digit strip").frames
  Assert.equal(#zeroFrames, #threeFrames, "the digit strip keeps its frame count across skins")
  local differs = false
  for index, frame in ipairs(zeroFrames) do
    local other = threeFrames[index]
    Assert.notNil(other, "the digit strip frame " .. index .. " exists on both skins")
    if assets[frame.image] ~= assets[other.image] then
      differs = true
    end
  end
  Assert.isTrue(differs, "the digit frames differ across skins")

  local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
  local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
  local PngWriter = require("romdump.src.digest.PngEncoder")
  local Lz10 = require("romdump.src.digest.Lz10")
  local archive = openArchive(romFs, "a/1/4/3")
  local function plain(memberId)
    local bytes = assert(archive:readMember(memberId), "the shell archive carries member " .. memberId)
    if string.byte(bytes, 1) == 0x10 then
      return assert(Lz10.decode(bytes))
    end
    return bytes
  end
  local character = assert(G2dDecoder.decodeChar(plain(9), {}))
  local palette = assert(G2dDecoder.decodePalette(plain(3), {}))
  local cells = assert(G2dDecoder.decodeCell(plain(12), {}))
  local animation = assert(G2dDecoder.decodeAnimation(plain(13), {}))
  local sourceSequence = assert(animation.anims[1], "the cursor animation carries its digit strip")
  local rendered = G2dRasterizer.renderAnimationFrame(
    character,
    palette,
    cells,
    sourceSequence,
    1,
    { role = "conformance-shell-cursor-skin-3", frame = 0 }
  )
  local expected = PngWriter.encode(rendered.width, rendered.height, rendered.pixels)
  local staged = assert(assets[threeFrames[1].image], "the staged assets carry the skin-three digit frame")
  Assert.equal(staged, expected, "the staged skin-three digit frame matches the independent render")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
