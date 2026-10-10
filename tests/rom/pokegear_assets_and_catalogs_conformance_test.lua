-- ROM conformance: the Pokegear family compiles from the real dump with exact
-- provenance. Every selected member of the five core graphics archives, the
-- twenty sprite resource descriptors, and the phonebook carries its source
-- path, member index, and byte hash into the published receipt; the full
-- 276-member research closure is accounted for with no invented resources;
-- and members outside the closure are explicitly classified instead of
-- silently dropped. Archive/member expectations pin the HeartGold evidence
-- anchors and the decomp-derived sprite bindings independently of the
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

-- Decomp-derived sprite bindings: CHAR/PLTT/CELL/ANIM descriptor members in
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
      local bytes = assert(
        opened:readMember(memberId),
        archive.role .. " member " .. memberId .. " must exist in the dump"
      )
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

function T.pokegear_family_accounts_for_the_full_selected_resource_closure(romFs, versionId)
  local loaded, PokegearAssetCompiler =
    pcall(require, "romdump.src.digest.ui.PokegearAssetCompiler")
  Assert.isTrue(
    loaded,
    "the pokegear family compiler must be published before the selected closure can be proven"
  )
  local bundle = PokegearAssetCompiler.compile(romFs, versionId)
  local compiled = assert(bundle, "the pokegear family must compile from the owned dump")

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

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
