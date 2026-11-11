-- Shared word editor producer: exact dictionary, menu, template, and
-- consumer tables compile from synthetic archives, the editor graphics
-- compile to validated layers and sequences, and malformed source fails
-- the whole bundle. Synthetic archives only; the dump holds the only
-- commercial bytes and the ROM suite proves the full closure.

local Assert = require("tests.support.Assert")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")

local T = {
  metadata = {
    tags = { "easychat" },
  },
  tests = {},
}

local function u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end

local function u32(v)
  return string.char(
    v % 256,
    math.floor(v / 256) % 256,
    math.floor(v / 65536) % 256,
    math.floor(v / 16777216) % 16777216
  )
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

local function charBlock(tiles)
  local body = string.rep(string.char(0x11), tiles * 32)
  local payload = u16(8) .. u16(0x20) .. u32(3) .. u16(0) .. u16(0) .. u32(0) .. u32(#body) .. u32(0x18) .. body
  return block("CHAR", payload)
end

local function paletteBlock()
  local body = {}
  for i = 1, 16 do
    body[#body + 1] = u16((i * 0x39B) % 0x8000)
  end
  local bytes = table.concat(body)
  local ttlp = "TTLP" .. u32(24 + #bytes) .. u32(3) .. u32(0) .. u32(#bytes) .. u32(16) .. bytes
  return "RLCN" .. string.char(0xFF, 0xFE) .. u16(0x0100) .. u32(0x10 + #ttlp) .. u16(0x10) .. u16(1) .. ttlp
end

local function screenBlock(width, height)
  local count = math.floor(width / 8) * math.floor(height / 8)
  local body = {}
  for _ = 1, count do
    body[#body + 1] = u16(0)
  end
  return block("SCRN", u16(width) .. u16(height) .. u32(0) .. u32(count * 2) .. table.concat(body))
end

local function cellBlock()
  local meta = u16(1) .. u16(0) .. u32(0)
  local attr = u16(0) .. u16(0) .. u16(0)
  return container(
    "RECN",
    { block("CEBK", u16(1) .. u16(0) .. u32(0x18) .. u32(0) .. string.rep("\0", 12) .. meta .. attr) }
  )
end

-- Builds an animation chunk with the requested sequence count, one
-- four-tick frame per sequence over a single shared empty cell.
---@param sequenceCount integer
local function animBlock(sequenceCount)
  local animsOffset, framesOffset = 0x18, 0x18 + sequenceCount * 16
  local dataOffset = framesOffset + sequenceCount * 8
  local header = u16(sequenceCount)
    .. u16(sequenceCount)
    .. u32(animsOffset)
    .. u32(framesOffset)
    .. u32(dataOffset)
    .. string.rep("\0", 8)
  local sequences, frames = {}, {}
  for _ = 1, sequenceCount do
    sequences[#sequences + 1] = u16(1) .. u16(0) .. u32(0x00010000) .. u32(1) .. u32(#frames * 8)
    frames[#frames + 1] = u32(0) .. u16(4) .. u16(0)
  end
  return container("RNAN", { block("ABNK", header .. table.concat(sequences) .. table.concat(frames) .. u16(0)) })
end

-- Minimal LZ10 literal-only encoder: the header plus one flag byte per
-- eight literal bytes. Synthetic members only.
---@param plain string
---@return string
local function lz10encode(plain)
  local out =
    { string.char(0x10), string.char(#plain % 256, math.floor(#plain / 256) % 256, math.floor(#plain / 65536) % 256) }
  local index = 1
  while index <= #plain do
    local chunk = plain:sub(index, index + 7)
    out[#out + 1] = string.char(0)
    out[#out + 1] = chunk
    index = index + 8
  end
  return table.concat(out)
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

local WORD_BANK_IDS = { 237, 751, 735, 721, 285, 286, 287, 288, 289, 290, 291 }
local WORD_BANK_COUNTS = { 496, 468, 18, 124, 38, 38, 107, 104, 47, 32, 23 }
local TEMPLATE_PHYSICAL = { 294, 296, 292, 293, 295 }
local GLYPH_A = { 0x012B, 0xFFFF }

---@param slotCount integer substitution slots in the message
---@return integer[] raw code units
local function templateMessage(slotCount)
  local units = { 0x012B }
  for selector = 0, slotCount - 1 do
    units[#units + 1] = 0xFFFE
    units[#units + 1] = 0x0100
    units[#units + 1] = 1
    units[#units + 1] = selector
  end
  units[#units + 1] = 0xFFFF
  return units
end

---@param templateSlots table<integer, integer>? physical bank -> forced slot count for message 0
---@return table members zero-based archive members
local function messageMembers(templateSlots)
  local highest = 751
  local members = {}
  for memberId = 0, highest do
    members[memberId + 1] = FieldMessageBank.encodeForTests({ GLYPH_A }, 7)
  end
  for _ = 1, 12 do
    members[282 + 1] = FieldMessageBank.encodeForTests(
      {
        GLYPH_A,
        GLYPH_A,
        GLYPH_A,
        GLYPH_A,
        GLYPH_A,
        GLYPH_A,
        GLYPH_A,
        GLYPH_A,
        GLYPH_A,
        GLYPH_A,
        GLYPH_A,
        GLYPH_A,
        GLYPH_A,
      },
      7
    )
    members[283 + 1] = FieldMessageBank.encodeForTests(
      {
        GLYPH_A,
        GLYPH_A,
        GLYPH_A,
        GLYPH_A,
        GLYPH_A,
        GLYPH_A,
        GLYPH_A,
        GLYPH_A,
        GLYPH_A,
        GLYPH_A,
        GLYPH_A,
        GLYPH_A,
        GLYPH_A,
      },
      7
    )
  end
  members[284 + 1] = FieldMessageBank.encodeForTests({ GLYPH_A, GLYPH_A, GLYPH_A }, 7)
  for index, bankId in ipairs(WORD_BANK_IDS) do
    local messages = {}
    for _ = 1, WORD_BANK_COUNTS[index] do
      messages[#messages + 1] = GLYPH_A
    end
    members[bankId + 1] = FieldMessageBank.encodeForTests(messages, 7)
  end
  for _, bankId in ipairs(TEMPLATE_PHYSICAL) do
    local messages = {}
    for number = 0, 19 do
      local slots = 1
      if templateSlots ~= nil and templateSlots[bankId] ~= nil and number == 0 then
        slots = templateSlots[bankId]
      end
      messages[#messages + 1] = templateMessage(slots)
    end
    members[bankId + 1] = FieldMessageBank.encodeForTests(messages, 7)
  end
  return members
end

---@param sequenceCount integer? animation sequences, default 28
---@return table members zero-based archive members
local function graphicsMembers(sequenceCount)
  local members = {}
  for memberId = 0, 16 do
    members[memberId + 1] = "member-" .. memberId
  end
  members[0 + 1] = container("RGCN", { screenBlock(256, 192) })
  members[1 + 1] = container("RGCN", { charBlock(32) })
  members[2 + 1] = container("RGCN", { screenBlock(512, 256) })
  members[3 + 1] = container("RGCN", { charBlock(32) })
  members[4 + 1] = container("RGCN", { screenBlock(256, 192) })
  members[5 + 1] = container("RGCN", { charBlock(112) })
  members[6 + 1] = paletteBlock()
  members[7 + 1] = cellBlock()
  members[8 + 1] = animBlock(sequenceCount or 28)
  members[9 + 1] = container("RGCN", { charBlock(410) })
  members[10 + 1] = paletteBlock()
  members[11 + 1] = container("RGCN", { screenBlock(256, 192) })
  members[12 + 1] = container("RGCN", { charBlock(8) })
  members[13 + 1] = paletteBlock()
  members[14 + 1] = container("RGCN", { screenBlock(88, 96) })
  members[15 + 1] = container("RGCN", { screenBlock(256, 256) })
  members[16 + 1] = paletteBlock()
  local encoded = {}
  local lz10 = {
    [0] = true,
    [1] = true,
    [2] = true,
    [3] = true,
    [4] = true,
    [5] = true,
    [7] = true,
    [8] = true,
    [9] = true,
    [11] = true,
    [12] = true,
  }
  for memberId = 0, 16 do
    if lz10[memberId] then
      encoded[memberId + 1] = lz10encode(members[memberId + 1])
    else
      encoded[memberId + 1] = members[memberId + 1]
    end
  end
  return encoded
end

---@param overrides table<string, unknown>?
---@return table romFs stub
local function stubRomFs(overrides)
  local graphics = narc(graphicsMembers())
  local messages = narc(messageMembers())
  if overrides ~= nil and overrides.graphicsMembers ~= nil then
    graphics = narc(overrides.graphicsMembers)
  end
  if overrides ~= nil and overrides.messageMembers ~= nil then
    messages = narc(overrides.messageMembers)
  end
  local Narc = require("libs.nds.src.nitro.Narc")
  local romFs = {
    _metadata = { sha1 = "rom-sha" },
    metadata = function(self)
      return self._metadata
    end,
    readSourcePath = function(_, path)
      assert(path == "a/0/2/7" or path == "a/0/7/6", "unexpected source path " .. tostring(path))
      if path == "a/0/7/6" then
        return graphics
      end
      return messages
    end,
    openNarc = function(_, alias)
      assert(alias == "messages", "unexpected archive " .. tostring(alias))
      return assert(Narc.open(messages, alias))
    end,
  }
  return romFs
end

---@return table mon catalog stub joining every species
local function stubMonCatalog()
  return {
    speciesKeyByNativeId = function(_, nativeId)
      return "SPECIES_" .. nativeId
    end,
  }
end

function T.tests.synthetic_archives_compile_to_a_validated_data_closure()
  local Compiler = require("romdump.src.digest.ui.EasyChatCompiler")
  local data, dataErr = Compiler.compileData(stubRomFs(), "heartgold", stubMonCatalog())
  Assert.notNil(data, "the synthetic archives compile their data: " .. tostring(dataErr))
  assert(data ~= nil, "data checked above")
  Assert.equal(#data.words, 1495, "the synthetic dictionary keeps every raw row")
  Assert.equal(#data.templates, 100, "the synthetic family keeps one hundred templates")
  Assert.equal(#data.groups, 12, "the synthetic family keeps twelve categories")
  Assert.equal(#data.initials, 27, "the synthetic family keeps twenty-seven initial lists")
  Assert.equal(#data.primoWords, 351, "the synthetic family keeps the password word order")
  Assert.equal(#data.unionAvatars.rows, 16, "the synthetic family keeps sixteen avatar rows")
  Assert.equal(#data.gridCells, 27, "the synthetic family keeps its grid geometry")
  Assert.equal(data.templates[1].wordCount, 1, "the template slot counts derive from substitution tokens")
  local Schema = require("libs.assets.src.EasyChatAssetSchema")
  local valid, reason = Schema.validateCatalog(data)
  Assert.isTrue(valid ~= nil and valid ~= false, "the synthetic data validates: " .. tostring(reason))
  local Catalog = require("libs.hgss.src.ui.EasyChatCatalog")
  local catalog = Catalog.new(data)
  Assert.equal(catalog:template(0, 0).wordCount, 1, "the catalog resolves the compiled templates")
end

function T.tests.synthetic_archives_compile_to_a_validated_presentation_closure()
  local Compiler = require("romdump.src.digest.ui.EasyChatCompiler")
  local data = Compiler.compileData(stubRomFs(), "heartgold", stubMonCatalog())
  local bundle = Compiler.compilePresentation(stubRomFs(), "heartgold", assert(data))
  Assert.notNil(bundle, "the synthetic archives compile their presentation")
  assert(bundle ~= nil, "bundle checked above")
  local Schema = require("libs.assets.src.EasyChatAssetSchema")
  local valid, reason = Schema.validateManifest(bundle.manifest)
  Assert.isTrue(valid ~= nil and valid ~= false, "the synthetic presentation validates: " .. tostring(reason))
  local Cache = require("libs.assets.src.EasyChatCache")
  local paths = Cache.referencedPaths(bundle.manifest)
  Assert.isTrue(#paths > 0, "the presentation references its images")
  for _, path in ipairs(paths) do
    Assert.notNil(bundle.assets[path], "the bundle carries referenced asset " .. path)
  end
end

function T.tests.short_word_banks_fail_the_whole_bundle()
  local Compiler = require("romdump.src.digest.ui.EasyChatCompiler")
  local members = messageMembers()
  members[237 + 1] = FieldMessageBank.encodeForTests({ GLYPH_A }, 7)
  local short = Compiler.compileData(stubRomFs({ messageMembers = members }), "heartgold", stubMonCatalog())
  Assert.isNil(short, "a short word bank fails the data bundle")
end

function T.tests.unmapped_species_fail_the_whole_bundle()
  local Compiler = require("romdump.src.digest.ui.EasyChatCompiler")
  local monCatalog = {
    speciesKeyByNativeId = function()
      error("unknown native species identity", 0)
    end,
  }
  local missing = Compiler.compileData(stubRomFs(), "heartgold", monCatalog)
  Assert.isNil(missing, "a species without a catalog mapping fails the data bundle")
end

function T.tests.templates_beyond_two_slots_fail_the_whole_bundle()
  local Compiler = require("romdump.src.digest.ui.EasyChatCompiler")
  local members = messageMembers({ [294] = 3 })
  local crowded = Compiler.compileData(stubRomFs({ messageMembers = members }), "heartgold", stubMonCatalog())
  Assert.isNil(crowded, "a three-slot template fails the data bundle")
end

function T.tests.short_animation_sets_fail_the_presentation_bundle()
  local Compiler = require("romdump.src.digest.ui.EasyChatCompiler")
  local data = Compiler.compileData(stubRomFs(), "heartgold", stubMonCatalog())
  local romFs = stubRomFs({ graphicsMembers = graphicsMembers(1) })
  local short = Compiler.compilePresentation(romFs, "heartgold", assert(data))
  Assert.isNil(short, "a short animation set fails the presentation bundle")
end

function T.tests.unsupported_versions_fail_loudly()
  local Compiler = require("romdump.src.digest.ui.EasyChatCompiler")
  local unsupported = Compiler.compileData(stubRomFs(), "soulsilver-x", stubMonCatalog())
  Assert.isNil(unsupported, "an unsupported version fails instead of compiling")
end

return T
