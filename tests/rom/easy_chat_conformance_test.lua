-- Shared word editor source closure: the dictionary, template, menu, and
-- consumer tables compile from the pinned archives in both editions, and
-- the compiled records load through the standalone cache and catalog with
-- exact identities. Word identities are asserted as counts, bank/member
-- indices, and numeric identities, never as copied dump bytes.

local Assert = require("tests.support.Assert")
local Narc = require("libs.nds.src.nitro.Narc")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local MESSAGE_PATH = "a/0/2/7"
local GRAPHICS_PATH = "a/0/7/6"
local GRAPHICS_MEMBER_COUNT = 17
local INTERFACE_BANKS = { 282, 283, 284 }
local WORD_BANK_IDS = { 237, 751, 735, 721, 285, 286, 287, 288, 289, 290, 291 }
local TEMPLATE_BANK_IDS = { 292, 293, 294, 295, 296 }
local EXPECTED_WORDS = 1495
local EXPECTED_GROUPS = 12
local EXPECTED_INITIALS = 27
local EXPECTED_TEMPLATES = 100
local EXPECTED_PASSWORD_WORDS = 351
local EXPECTED_AVATAR_ROWS = 16
local EXPECTED_AVATAR_CHOICE_ROWS = 8
local EXPECTED_AVATAR_CHOICE_WIDTH = 4
local NULL_WORD = 0xFFFF
local UNKNOWN_WORD = 0x0FFF
local ZERO_SLOT_TEMPLATES = { { 4, 5 }, { 4, 8 }, { 4, 13 }, { 4, 15 }, { 4, 16 }, { 4, 17 } }

-- Loads a word editor producer module that does not exist yet at this
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

---@param archive table
---@param bank integer
---@param versionId string
---@param what string
local function assertBankNonEmpty(archive, bank, versionId, what)
  local member = archive:readMember(bank)
  Assert.notNil(member, versionId .. " " .. what .. " bank " .. bank .. " must exist in the dump")
  Assert.isTrue(#member > 0, versionId .. " " .. what .. " bank " .. bank .. " is non-empty")
end

-- Collects every numeric word identity a candidate array offers. Candidates
-- are single identities or ordered alternative arrays; the first known
-- alternative wins at menu build time, so every alternative must resolve.
---@param candidates table
---@param out table<integer, boolean>
local function collectCandidates(candidates, out)
  for _, candidate in ipairs(candidates) do
    if type(candidate) == "table" then
      for _, alternative in ipairs(candidate) do
        out[alternative] = true
      end
    else
      out[candidate] = true
    end
  end
end

-- The compiled catalog keeps the full word, menu, template, password, and
-- avatar closure: exact raw and curated counts, all one hundred template
-- identities with valid slot counts, resolvable group/initial/password
-- references, null-word handling, and loud unknown identities. The
-- presentation bundle validates with non-empty layers and sequences.
function T.compiled_catalog_keeps_the_full_word_menu_template_and_consumer_closure(romFs, versionId)
  local messages = openArchive(romFs, MESSAGE_PATH)
  for _, bank in ipairs(INTERFACE_BANKS) do
    assertBankNonEmpty(messages, bank, versionId, "interface")
  end
  for _, bank in ipairs(WORD_BANK_IDS) do
    assertBankNonEmpty(messages, bank, versionId, "word")
  end
  for _, bank in ipairs(TEMPLATE_BANK_IDS) do
    assertBankNonEmpty(messages, bank, versionId, "sentence template")
  end

  local graphics = openArchive(romFs, GRAPHICS_PATH)
  Assert.equal(
    graphics:memberCount(),
    GRAPHICS_MEMBER_COUNT,
    versionId .. " editor graphics archive " .. GRAPHICS_PATH .. " carries its full member set"
  )

  -- The standalone word editor producer is not published yet: turning the
  -- closed archive set into a validated family needs its compiler owner.
  -- This failure is the intended pre-implementation red; the archive
  -- facts above already hold.
  local Compiler = requireFeature(
    "romdump.src.digest.ui.EasyChatCompiler",
    versionId
      .. " has no shared word editor producer yet: "
      .. "the closed archive set cannot compile into a validated family"
  )
  local MonCatalogCompiler = require("romdump.src.digest.mons.MonCatalogCompiler")
  local ItemFixture = require("libs.items.tests.item_fixture")
  local MonCatalog = require("libs.mons.src.MonCatalog")
  local monRoot = assert(
    MonCatalogCompiler.compileCatalog(romFs, { versionId = versionId }),
    versionId .. " compiles its mon catalog for the species join"
  )
  local monCatalog = MonCatalog.new(monRoot, ItemFixture.makeCatalog())
  local data, dataErr = Compiler.compileData(romFs, versionId, monCatalog)
  Assert.notNil(data, versionId .. " compiles its word editor data: " .. tostring(dataErr))
  assert(data ~= nil, "compiled data asserted above")

  local Schema = requireFeature(
    "libs.assets.src.EasyChatAssetSchema",
    versionId .. " has no shared word editor schema yet: " .. "the compiled family cannot validate its records"
  )
  local valid, reason = Schema.validateCatalog(data)
  Assert.isTrue(valid ~= nil and valid ~= false, versionId .. " compiled catalog validates: " .. tostring(reason))

  local Catalog = requireFeature(
    "libs.hgss.src.ui.EasyChatCatalog",
    versionId .. " has no shared word editor catalog yet: " .. "compiled records cannot resolve words or sentences"
  )
  local catalog = Catalog.new(data)

  Assert.equal(#data.words, EXPECTED_WORDS, versionId .. " keeps every raw dictionary row")
  Assert.equal(#data.groups, EXPECTED_GROUPS, versionId .. " keeps all twelve curated categories")
  Assert.equal(#data.initials, EXPECTED_INITIALS, versionId .. " keeps all twenty-seven authored initial lists")
  Assert.equal(#data.templates, EXPECTED_TEMPLATES, versionId .. " keeps all one hundred sentence templates")
  Assert.equal(#data.primoWords, EXPECTED_PASSWORD_WORDS, versionId .. " keeps the full password word order")
  Assert.equal(#data.unionAvatars.rows, EXPECTED_AVATAR_ROWS, versionId .. " keeps all sixteen avatar attribute rows")
  Assert.equal(
    #data.unionAvatars.choices,
    EXPECTED_AVATAR_CHOICE_ROWS,
    versionId .. " keeps all eight avatar choice rows"
  )
  for row = 1, EXPECTED_AVATAR_CHOICE_ROWS do
    Assert.equal(
      #data.unionAvatars.choices[row],
      EXPECTED_AVATAR_CHOICE_WIDTH,
      versionId .. " avatar choice row " .. row .. " offers four entries"
    )
  end
  for row = 1, EXPECTED_AVATAR_ROWS do
    local record = data.unionAvatars.rows[row]
    Assert.isTrue(
      type(record.spriteId) == "number" and type(record.classId) == "number",
      versionId .. " avatar row " .. row .. " carries its sprite and class identities"
    )
  end

  -- Every logical bank/number identity resolves with a valid slot count,
  -- and the known zero-slot templates complete without words.
  for bank = 0, 4 do
    for number = 0, 19 do
      local template = catalog:template(bank, number)
      Assert.notNil(template, versionId .. " template bank " .. bank .. " number " .. number .. " resolves")
      assert(template ~= nil, "template identity asserted above")
      Assert.equal(template.bank, bank, versionId .. " template keeps its logical bank")
      Assert.equal(template.number, number, versionId .. " template keeps its logical number")
      Assert.isTrue(
        template.wordCount == 0 or template.wordCount == 1 or template.wordCount == 2,
        versionId .. " template bank " .. bank .. " number " .. number .. " has a valid slot count"
      )
    end
  end
  for _, identity in ipairs(ZERO_SLOT_TEMPLATES) do
    local template = assert(
      catalog:template(identity[1], identity[2]),
      versionId .. " zero-slot template bank " .. identity[1] .. " number " .. identity[2] .. " resolves"
    )
    Assert.equal(template.wordCount, 0, versionId .. " the fenced template completes without words")
  end

  -- Every curated reference resolves through the catalog: group entries,
  -- initial candidates with all their alternatives, and password words.
  -- The bundle is self-contained, never a view over another dictionary.
  local referenced = {}
  for _, group in ipairs(data.groups) do
    for _, wordId in ipairs(assert(group.wordIds, versionId .. " category lists carry their ordered identities")) do
      referenced[wordId] = true
    end
  end
  for _, initial in ipairs(data.initials) do
    collectCandidates(
      assert(initial.candidates, versionId .. " initial lists carry their candidate arrays"),
      referenced
    )
  end
  for _, wordId in ipairs(data.primoWords) do
    referenced[wordId] = true
  end
  local resolved = 0
  for wordId in pairs(referenced) do
    Assert.notNil(catalog:wordTokens(wordId), versionId .. " referenced word identity " .. wordId .. " resolves")
    resolved = resolved + 1
  end
  Assert.isTrue(resolved > EXPECTED_WORDS - 30, versionId .. " the curated closure spans the dictionary")

  -- The null identity carries no fragment, and an unknown decoded row
  -- fails loudly instead of resolving to a plausible neighbour.
  Assert.deepEqual(catalog:wordTokens(NULL_WORD), {}, versionId .. " the null word carries no fragment")
  local unknownOk = pcall(catalog.wordTokens, catalog, UNKNOWN_WORD)
  Assert.isFalse(unknownOk, versionId .. " an unknown decoded identity fails")

  -- A complete sentence built from the first template expands to
  -- non-empty fragments through the same resolver.
  local firstTemplate = assert(data.templates[1], versionId .. " the compiled templates are dense")
  local firstWordId = assert(data.words[1].id, versionId .. " word records carry explicit identities")
  local words = { NULL_WORD, NULL_WORD }
  for slot = 1, firstTemplate.wordCount do
    words[slot] = firstWordId
  end
  local message = { bank = firstTemplate.bank, number = firstTemplate.number, words = words }
  Assert.equal(catalog:messageStatus(message), "complete", versionId .. " the filled first template reads complete")
  Assert.isTrue(#catalog:expandMessage(message) > 0, versionId .. " the filled first template expands to fragments")

  local presentation, presentationErr = Compiler.compilePresentation(romFs, versionId, data)
  Assert.notNil(presentation, versionId .. " compiles its editor presentation: " .. tostring(presentationErr))
  assert(presentation ~= nil, "compiled presentation asserted above")
  local manifestOk, manifestReason = Schema.validateManifest(presentation.manifest)
  Assert.isTrue(
    manifestOk ~= nil and manifestOk ~= false,
    versionId .. " compiled presentation validates: " .. tostring(manifestReason)
  )
  local manifest = assert(presentation.manifest, versionId .. " the presentation bundle carries its manifest")
  Assert.isTrue(#manifest.layers > 0, versionId .. " the presentation keeps its native layers")
  Assert.isTrue(#manifest.sequences > 0, versionId .. " the presentation keeps its animation sequences")
  for _, sequence in ipairs(manifest.sequences) do
    for _, frame in ipairs(assert(sequence.frames, versionId .. " sequences carry frames")) do
      Assert.notNil(frame.image, versionId .. " sequence frames name their image")
      Assert.isTrue(
        type(frame.duration) == "number" and type(frame.originX) == "number" and type(frame.originY) == "number",
        versionId .. " sequence frames carry timing and anchor facts"
      )
    end
  end
end

local suite = RomSuite.fromFacts(T)
suite.metadata.tags = { "easychat" }
return suite
