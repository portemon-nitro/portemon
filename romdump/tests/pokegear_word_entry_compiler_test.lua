-- Single-word entry producer: the source selectors publish the closed
-- overlay/graphics/message set with HeartGold validation, and the compiler
-- turns that set into source-neutral category data plus sprite frames
-- through the existing G2d and message mechanisms. Synthetic archives prove
-- the shape; the dump holds the only commercial bytes.

local Assert = require("tests.support.Assert")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")

local T = {}

local function u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end

local function u32(v)
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

local function swap4(magic)
  return magic:reverse()
end

local function container(magic, blocks)
  local body = {}
  local size = 0x10
  for _, blk in ipairs(blocks) do
    body[#body + 1] = blk
    size = size + #blk
  end
  return magic .. string.char(0xFF, 0xFE) .. u16(0x0100) .. u32(size) .. u16(0x10) .. u16(#blocks) .. table.concat(body)
end

local function block(magic, payload)
  return swap4(magic) .. u32(8 + #payload) .. payload
end

local function charData(tiles)
  local payload = u16(8) .. u16(0x20) .. u32(3) .. u16(0) .. u16(0) .. u32(0) .. u32(tiles * 32) .. u32(0x18)
  local body = {}
  for _ = 1, tiles do
    body[#body + 1] = string.rep(string.char(0x11), 32)
  end
  return container("RGCN", { block("CHAR", payload .. table.concat(body)) })
end

local function palette256()
  local body = {}
  for i = 1, 256 do
    body[#body + 1] = u16((i * 0x39B) % 0x8000)
  end
  local bytes = table.concat(body)
  local ttlp = "TTLP" .. u32(24 + #bytes) .. u32(3) .. u32(0) .. u32(#bytes) .. u32(16) .. bytes
  return "RLCN" .. string.char(0xFF, 0xFE) .. u16(0x0100) .. u32(0x10 + #ttlp) .. u16(0x10) .. u16(1) .. ttlp
end

local function cellData()
  local meta = u16(1) .. u16(0) .. u32(0)
  local attr = u16(0) .. u16(0) .. u16(0)
  return container(
    "RECN",
    { block("CEBK", u16(1) .. u16(0) .. u32(0x18) .. u32(0) .. string.rep("\0", 12) .. meta .. attr) }
  )
end

local function animData()
  local header = u16(1) .. u16(1) .. u32(0x18) .. u32(0x28) .. u32(0x30) .. string.rep("\0", 8)
  local sequence = u16(1) .. u16(0) .. u32(0x00010000) .. u32(1) .. u32(0)
  local frame = u32(0) .. u16(4) .. u16(0)
  local property = u16(0)
  return container("RNAN", { block("ABNK", header .. sequence .. frame .. property) })
end

local function narc(members)
  local btaf = u16(#members) .. u16(0)
  local running = 0
  for _, bytes in ipairs(members) do
    btaf = btaf .. u32(running) .. u32(running + #bytes)
    running = running + #bytes
  end
  local function narcBlock(magic, payload)
    return magic .. u32(8 + #payload) .. payload
  end
  return "NARC"
    .. string.char(0xFF, 0xFE)
    .. u16(0x0100)
    .. u32(0x10 + #narcBlock("BTAF", btaf) + #narcBlock("GMIF", table.concat(members)))
    .. u16(0x10)
    .. u16(2)
    .. narcBlock("BTAF", btaf)
    .. narcBlock("GMIF", table.concat(members))
end

local GROUP_COUNTS = { 496, 468, 18, 124, 38, 38, 107, 104, 47, 32, 23 }
local WORD_BANKS = { 237, 751, 735, 721, 285, 286, 287, 288, 289, 290, 291 }

local function tinyMessage()
  return { { 0x0041, 0xFFFF } }
end

local function messageMembers(counts)
  local highest = 0
  for _, bank in ipairs(WORD_BANKS) do
    highest = math.max(highest, bank)
  end
  for _, bank in ipairs({ 282, 283, 284 }) do
    highest = math.max(highest, bank)
  end
  local members = {}
  for memberId = 0, highest do
    members[memberId + 1] = FieldMessageBank.encodeForTests(tinyMessage(), 7)
  end
  for index, bank in ipairs(WORD_BANKS) do
    local messages = {}
    for _ = 1, (counts and counts[index] or GROUP_COUNTS[index]) do
      messages[#messages + 1] = { 0x0041, 0xFFFF }
    end
    members[bank + 1] = FieldMessageBank.encodeForTests(messages, 7)
  end
  return members
end

local function graphicsMembers()
  local members = {}
  for memberId = 0, 16 do
    members[memberId + 1] = "member-" .. memberId
  end
  members[7 + 1] = cellData()
  members[8 + 1] = animData()
  members[9 + 1] = charData(2)
  members[10 + 1] = palette256()
  return members
end

---@param overrides table<string, unknown>?
---@return table romFs stub
local function stubRomFs(overrides)
  local graphics = narc(graphicsMembers())
  local messages = narc(messageMembers())
  local Narc = require("libs.nds.src.nitro.Narc")
  local romFs = {
    _version = "heartgold",
    _metadata = { sha1 = "rom-sha" },
    metadata = function(self)
      return self._metadata
    end,
    version = function(self)
      return self._version
    end,
    readSourcePath = function(_, path)
      assert(path == "a/0/7/6", "unexpected source path " .. tostring(path))
      return graphics
    end,
    openNarc = function(_, alias)
      assert(alias == "messages", "unexpected archive " .. tostring(alias))
      return assert(Narc.open(messages, alias))
    end,
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      romFs[key] = value
    end
  end
  return romFs
end

local function requireSources()
  local ok, mod = pcall(require, "romdump.src.config.PokegearWordEntrySources")
  if not ok then
    error("the single-word entry source owner is not published yet", 0)
  end
  return mod --[[@as table]]
end

local function requireCompiler()
  local ok, mod = pcall(require, "romdump.src.digest.ui.PokegearWordEntryCompiler")
  if not ok then
    error("the single-word entry compiler is not published yet", 0)
  end
  return mod --[[@as table]]
end

function T.closed_selector_set_matches_the_pc_dictionary_identities()
  local Sources = requireSources()
  Assert.equal(Sources.overlay.fileId, 102, "the selector owns overlay 102")
  Assert.equal(Sources.overlay.rawSize, 15776, "the overlay keeps its gated compressed size")
  Assert.equal(Sources.overlay.decodedSize, 20992, "the overlay keeps its gated decoded size")
  Assert.equal(Sources.graphics.path, "a/0/7/6", "the sprite set lives in its gated archive")
  Assert.equal(Sources.graphics.memberCount, 17, "the sprite archive keeps its member count")
  Assert.equal(Sources.graphics.members.cell, 7, "the cell member keeps its source selection")
  Assert.equal(Sources.graphics.members.animation, 8, "the animation member keeps its source selection")
  Assert.equal(Sources.messages.interfaceBanks[1], 282, "the interface banks start at 282")
  local PcSources = require("romdump.src.config.PcSources")
  Assert.equal(#Sources.wordBanks, 11, "the word-entry family keeps all eleven word banks")
  for index, entry in ipairs(Sources.wordBanks) do
    local pcEntry = PcSources.mailText.wordBanks[index]
    Assert.equal(entry.messageBank, pcEntry.messageBank, "word-entry bank " .. index .. " reuses the dictionary bank")
    Assert.equal(entry.wordCount, pcEntry.wordCount, "word-entry bank " .. index .. " reuses the dictionary count")
    Assert.equal(entry.firstWordId, pcEntry.firstWordId, "word-entry bank " .. index .. " reuses the dictionary base")
  end
  local total = 0
  for _, entry in ipairs(Sources.wordBanks) do
    total = total + entry.wordCount
  end
  Assert.equal(total, 1495, "the eleven banks sum to the full dictionary")
  Assert.isTrue(Sources.versions.heartgold == true, "heartgold selectors are validated")
  Assert.isFalse(
    pcall(Sources.wordBankRecords, "soulsilver"),
    "unverified soulsilver selectors fail loudly instead of compiling"
  )
end

function T.synthetic_closed_set_compiles_to_a_valid_section_with_frames()
  local Compiler = requireCompiler()
  local bundle = Compiler.compile(stubRomFs(), "heartgold")
  Assert.notNil(bundle, "the synthetic closed set must compile")
  Assert.notNil(bundle.marker, "the bundle carries its marker")
  Assert.notNil(bundle.section, "the bundle carries its word-entry section")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record, err = PokegearAssetSchema.validateWordEntry(bundle.section)
  Assert.notNil(record, "the compiled section validates: " .. tostring(err and err.message or err))
  Assert.equal(#bundle.section.groups, 11, "the section keeps all eleven groups")
  Assert.equal(bundle.section.groups[1].firstWordId, 0, "the species group starts at the decimal group base")
  Assert.equal(bundle.section.groups[2].firstWordId, 496, "the move group starts where species ends")
  Assert.notNil(bundle.section.cursor, "the section carries its cursor sequences")
  Assert.isTrue(#bundle.section.cursor.sequences >= 1, "the cursor keeps at least one source sequence")
  Assert.isTrue(#bundle.section.cursor.sequences[1].frames >= 1, "the first cursor sequence stages at least one frame")
  local staged = 0
  for path in pairs(bundle.assets) do
    if path:find("word-entry-", 1, true) ~= nil then
      staged = staged + 1
    end
  end
  Assert.isTrue(staged >= 1, "the bundle stages its word-entry images")
end

function T.incomplete_or_mismatched_source_sets_fail_before_publication()
  local Compiler = requireCompiler()
  Assert.isFalse(
    pcall(Compiler.compile, stubRomFs(), "soulsilver"),
    "an unverified version never compiles the selector"
  )
  local short = {}
  for memberId = 0, 9 do
    short[memberId + 1] = "member-" .. memberId
  end
  Assert.isFalse(
    pcall(
      Compiler.compile,
      stubRomFs({
        readSourcePath = function()
          return narc(short)
        end,
      }),
      "heartgold"
    ),
    "a truncated sprite archive never compiles the selector"
  )
  local wrongCounts = {}
  for index, count in ipairs(GROUP_COUNTS) do
    wrongCounts[index] = count
  end
  wrongCounts[1] = 12
  Assert.isFalse(
    pcall(function()
      local Narc = require("libs.nds.src.nitro.Narc")
      local romFs = stubRomFs()
      local messages = narc(messageMembers(wrongCounts))
      romFs.openNarc = function()
        return assert(Narc.open(messages, "messages"))
      end
      return Compiler.compile(romFs, "heartgold")
    end),
    "a word bank with a mismatched count never compiles the selector"
  )
end

return { tests = T }
