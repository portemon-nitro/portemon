-- ROM conformance: every native caller selects its source program. The
-- compiled phonebook catalog carries all seventy-five native contacts with
-- distinct semantic keys fully covered by the contact order, and each
-- selector early return from the source-ordered branch tables resolves to
-- its own program identity with its own draw order. Expectations pin the
-- native contact count and the branch order independently of the dispatch
-- implementation under test. Member bytes are never committed to the
-- repository.

local Assert = require("tests.support.Assert")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

-- Seventy-five native callers: the supplied HeartGold phonebook keeps its
-- whole-file identity of one count word plus seventy-five fixed records.
local NATIVE_CONTACT_COUNT = 75

-- Source-ordered selector branches with one context vector each. Every
-- early return needs its own counterexample: the listed facts select the
-- named program, and flipping the decisive fact must leave it.
---@return table[]
local function selectorVectors()
  return {
    { family = "elm-predefined", facts = { predefinedScript = "elm-intro" }, program = "elm-predefined" },
    { family = "elm", facts = { localMap = true }, program = "elm-local-map" },
    { family = "elm", facts = { panicCall = true }, program = "elm-panic" },
    { family = "elm", facts = { rivalUnnamed = true }, program = "elm-rival" },
    { family = "elm", facts = { eggEvent = true }, program = "elm-egg" },
    { family = "elm", facts = { badges = 0, rockets = false }, program = "elm-early" },
    { family = "elm", facts = { gameClear = true }, program = "elm-clear" },
    { family = "elm", facts = { pokerus = true }, program = "elm-pokerus" },
    { family = "oak", facts = { dexSeen = 10, dexCaught = 5 }, program = "oak-evaluation" },
    { family = "mother", facts = { savingsChoice = true }, program = "mother-savings" },
    { family = "generic", facts = { weekday = "monday", hour = 9 }, program = "generic-weekday" },
    { family = "gym", facts = { weekday = "saturday", morning = true }, program = "gym-rematch" },
    { family = "buena", facts = { passwordKnown = true }, program = "buena-reward" },
    { family = "bill", facts = { pcFreeSlots = 3 }, program = "bill-advice" },
  }
end

function T.every_native_caller_selects_its_source_program(romFs, versionId)
  local PokegearAssetCompiler = require("romdump.src.digest.ui.PokegearAssetCompiler")
  local bundle = PokegearAssetCompiler.compile(romFs, versionId)
  local compiled = assert(bundle, "the pokegear family must compile from the owned dump")
  local manifest = assert(compiled.manifest, "the compiled family must publish its manifest")
  local catalog = assert(manifest.catalog, "the compiled family must publish its contact catalog")

  -- The compiled catalog accounts for every native caller exactly once.
  Assert.equal(
    #catalog.contacts,
    NATIVE_CONTACT_COUNT,
    "the compiled phonebook carries all seventy-five native contacts"
  )
  local seen = {}
  for index, contact in ipairs(catalog.contacts) do
    Assert.notNil(contact.key, "contact " .. index .. " carries a semantic key")
    Assert.isNil(seen[contact.key], "contact key " .. tostring(contact.key) .. " appears exactly once")
    seen[contact.key] = true
  end
  Assert.equal(#catalog.contactOrder, NATIVE_CONTACT_COUNT, "the contact order covers every native caller")
  for _, key in ipairs(catalog.contactOrder) do
    Assert.isTrue(seen[key] == true, "ordered contact " .. tostring(key) .. " is a compiled native caller")
  end

  -- With the native caller set proven, dispatch must resolve every
  -- source-ordered selector vector to its own program: no reachable caller
  -- may fall through to an all-purpose default conversation.
  local ok, PhoneCall = pcall(require, "game.hgss.src.pokegear.PhoneCall")
  if not ok then
    error(
      "phone conversation dispatch is not implemented yet: no native caller can select its source program",
      0
    )
  end
  assert(type(PhoneCall) == "table", "phone conversation dispatch is not implemented yet")
  for _, vector in ipairs(selectorVectors()) do
    local selected = PhoneCall.selectProgram(vector.family, vector.facts)
    Assert.equal(selected, vector.program, vector.family .. " selects its source program for its vector")
  end
  local dispatched = {}
  for _, vector in ipairs(selectorVectors()) do
    dispatched[vector.program] = true
  end
  local distinct = 0
  for _ in pairs(dispatched) do
    distinct = distinct + 1
  end
  Assert.isTrue(distinct > 1, "selector vectors resolve to distinct programs, never one default")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
