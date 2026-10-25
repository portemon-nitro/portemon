-- ROM conformance: the single-word map annotation selector closes its
-- evidence gate before any selector code lands. The overlay binary carries
-- the word-entry entrypoints, the graphics archive carries the exact sprite
-- members the selector binds, and the message archive carries the interface
-- banks plus all eleven word banks behind the existing PC dictionary. Word
-- identities are asserted as decimal strings and bank/member indices, never
-- as copied dump bytes. A missing dump reports a skip, never a pass,
-- through the declared dump capability.

local Assert = require("tests.support.Assert")
local Narc = require("libs.nds.src.nitro.Narc")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

-- Loads a word-entry producer module that does not exist yet at this
-- baseline. The failure names the missing behaviour instead of surfacing
-- as a suite load error, so the pre-implementation red stays attributable.
---@param moduleName string
---@param missingMessage string
---@return table
local function requireFeature(moduleName, missingMessage)
  local ok, mod = pcall(require, moduleName)
  if not ok then
    error(missingMessage, 0)
  end
  assert(type(mod) == "table", missingMessage)
  return mod --[[@as table]]
end

-- The closed selector resource set from the evidence gate: overlay 102,
-- the four sprite members of graphics archive a/0/7/6, the three
-- interface banks, and the eleven word banks of message archive a/0/2/7.
local OVERLAY_ID = 102
local OVERLAY_RAW_SIZE = 15776
local OVERLAY_DECODED_SIZE = 20992
local GRAPHICS_PATH = "a/0/7/6"
local GRAPHICS_MEMBER_COUNT = 17
local SELECTOR_MEMBERS = {
  { role = "cell", memberId = 7, rawSize = 611, compressed = true },
  { role = "anim", memberId = 8, rawSize = 669, compressed = true },
  { role = "mapping", memberId = 9, rawSize = 2093, compressed = true },
  { role = "palette", memberId = 10, rawSize = 124, compressed = false },
}
local MESSAGE_PATH = "a/0/2/7"
local INTERFACE_BANKS = { 282, 283, 284 }
local WORD_BANKS = { 237, 751, 735, 721, 285, 286, 287, 288, 289, 290, 291 }

---@param romFs table<string, unknown>
---@param path string
---@return table
local function openArchive(romFs, path)
  local reader = assert(romFs.readSourcePath, "the dump reader exposes source paths")
  local bytes, err = reader(romFs, path)
  Assert.notNil(bytes, "the dump must expose archive " .. path .. ": " .. tostring(err))
  local archive, narcErr = Narc.open(assert(bytes), path)
  Assert.notNil(archive, "archive " .. path .. " must open: " .. tostring(narcErr))
  return assert(archive)
end

-- The overlay binary carries the word-entry entrypoints at their source
-- addresses with the exact compressed size the gate measured.
function T.single_word_selector_resources_close_against_source_evidence(romFs, versionId)
  local readOverlay = assert(romFs.readOverlay, "the dump reader exposes overlays")
  local bytes, info = readOverlay(romFs, "arm9", OVERLAY_ID)
  Assert.notNil(bytes, versionId .. " must expose overlay 102")
  Assert.equal(#assert(bytes), OVERLAY_DECODED_SIZE, versionId .. " overlay 102 decodes to its gated image size")
  local reader = assert(romFs.read, "the dump reader exposes raw files")
  local raw = reader(romFs, assert(info).fileId)
  Assert.equal(#assert(raw), OVERLAY_RAW_SIZE, versionId .. " overlay 102 carries its gated compressed size")

  local graphics = openArchive(romFs, GRAPHICS_PATH)
  Assert.equal(
    graphics:memberCount(),
    GRAPHICS_MEMBER_COUNT,
    versionId .. " graphics archive " .. GRAPHICS_PATH .. " carries its full member set"
  )
  for _, expected in ipairs(SELECTOR_MEMBERS) do
    local member = assert(
      graphics:readMember(expected.memberId),
      versionId .. " selector " .. expected.role .. " member " .. expected.memberId .. " must exist in the dump"
    )
    Assert.equal(
      #member,
      expected.rawSize,
      versionId .. " selector " .. expected.role .. " member carries its gated raw size"
    )
    Assert.equal(
      string.byte(member, 1) == 0x10,
      expected.compressed,
      versionId .. " selector " .. expected.role .. " member keeps its gated compression marker"
    )
  end

  local messages = openArchive(romFs, MESSAGE_PATH)
  for _, bank in ipairs(INTERFACE_BANKS) do
    local member =
      assert(messages:readMember(bank), versionId .. " interface bank " .. bank .. " must exist in the dump")
    Assert.isTrue(#member > 0, versionId .. " interface bank " .. bank .. " is non-empty")
  end
  for _, bank in ipairs(WORD_BANKS) do
    local member = assert(messages:readMember(bank), versionId .. " word bank " .. bank .. " must exist in the dump")
    Assert.isTrue(#member > 0, versionId .. " word bank " .. bank .. " is non-empty")
  end

  -- The existing PC dictionary already splits the same eleven banks with
  -- the same counts, so the selector reuses those identities instead of
  -- minting new ones. The oracle is the checked-in PC source table, never
  -- the compiler under test.
  local PcSources = require("romdump.src.config.PcSources")
  local wordBanks =
    assert(PcSources.mailText ~= nil and PcSources.mailText.wordBanks, "the PC dictionary publishes its word banks")
  Assert.equal(#wordBanks, #WORD_BANKS, "the dictionary carries eleven word banks")
  local total = 0
  for index, entry in ipairs(wordBanks) do
    Assert.equal(entry.messageBank, WORD_BANKS[index], "dictionary bank " .. index .. " keeps its source bank identity")
    Assert.isTrue(entry.wordCount > 0, "dictionary bank " .. WORD_BANKS[index] .. " is non-empty")
    total = total + entry.wordCount
  end
  Assert.equal(total, 1495, "the eleven banks sum to the full dictionary")

  -- The word-entry source selectors are not published yet: closing the
  -- loop needs the producer owner that turns this closed set into a
  -- validated family. This failure is the intended pre-implementation
  -- red; the dump facts above already hold.
  local Sources = requireFeature(
    "romdump.src.config.PokegearWordEntrySources",
    versionId
      .. " has no single-word entry source owner yet: "
      .. "the closed selector resource set cannot compile into a validated family"
  )
  local published = Sources.wordBanks
  Assert.notNil(published, "the word-entry sources publish their word banks")
  Assert.equal(#published, #WORD_BANKS, "the word-entry family keeps all eleven word banks")
  for index, entry in ipairs(published) do
    Assert.equal(entry.messageBank, WORD_BANKS[index], "word-entry bank " .. index .. " keeps its source bank identity")
  end
end

-- Word availability follows the source groups with no save gating: every
-- dictionary word is offered in group order, the empty selection stays
-- the null word, and unknown identities fail instead of resolving to a
-- plausible neighbour.
local GROUP_COUNTS = { 496, 468, 18, 124, 38, 38, 107, 104, 47, 32, 23 }
local NULL_WORD = 0xFFFF

---@param romFs table<string, unknown>
---@param versionId string
---@return table word catalog with eleven groups in source order
local function gateCatalog(romFs, versionId)
  local messages = openArchive(romFs, MESSAGE_PATH)
  local catalog = { groups = {} }
  for index, bank in ipairs(WORD_BANKS) do
    Assert.notNil(messages:readMember(bank), versionId .. " word bank " .. bank .. " backs group " .. (index - 1))
    catalog.groups[index] = { group = index - 1, bank = bank, count = GROUP_COUNTS[index] }
  end
  return catalog
end

function T.word_availability_follows_source_groups_without_save_gating(romFs, versionId)
  local catalog = gateCatalog(romFs, versionId)

  -- The single-word selector owner is not published yet: offering,
  -- ordering, and rejecting words needs the state owner the gate
  -- specified. This failure is the intended pre-implementation red; the
  -- bank facts above already hold.
  local WordEntryScreenState = requireFeature(
    "game.hgss.src.pokegear.WordEntryScreenState",
    versionId .. " has no single-word selector owner yet: " .. "words cannot be offered in source group order"
  )
  assert(WordEntryScreenState ~= nil, "the selector owner loads above")

  -- Seen and unseen species words behave identically: the selector never
  -- consults save or dex facts, so both open and resolve.
  for _, word in ipairs({ "0", "150", "495" }) do
    local shown = WordEntryScreenState.wordsInGroup(catalog, 0, { seenSpecies = {} })
    local found = false
    for _, entry in ipairs(assert(shown, "group 0 offers its words")) do
      if entry == word then
        found = true
      end
    end
    Assert.isTrue(found, "species word " .. word .. " is offered without save gating")
  end

  -- Group order is the source group order and within-group order is bank
  -- order; dictionary completeness never bypasses the group boundaries.
  local first = WordEntryScreenState.wordsInGroup(catalog, 0, {})
  local second = WordEntryScreenState.wordsInGroup(catalog, 1, {})
  Assert.equal(#assert(first), GROUP_COUNTS[1], "the species group keeps its source count")
  Assert.equal(#assert(second), GROUP_COUNTS[2], "the move group keeps its source count")
  Assert.equal(first[1], "0", "word identities start at the decimal group base")
  Assert.equal(second[1], "496", "the move group starts where the species group ends")

  -- The null word renders empty and unknown identities fail loudly
  -- instead of resolving to a plausible neighbour.
  Assert.equal(WordEntryScreenState.wordKey(NULL_WORD), nil, "the null word carries no selectable identity")
  local ok = pcall(WordEntryScreenState.wordsInGroup, catalog, 11, {})
  Assert.isFalse(ok, "an eleventh group index past the source groups fails")
end

local suite = RomSuite.fromFacts(T)
return suite
