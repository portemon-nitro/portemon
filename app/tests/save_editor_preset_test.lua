-- Save preset parsing and atomic staging stay at the Save Editor boundary.

local Assert = require("tests.support.Assert")
local Fixture = require("app.tests.support.SaveEditorFixture")
local Session = require("app.src.saveeditor.SaveEditorSession")
local SaveEditorMonDraft = require("app.src.saveeditor.SaveEditorMonDraft")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")

local parserLoaded, SaveEditorPreset = pcall(require, "app.src.saveeditor.SaveEditorPreset")
local T = { tests = {} }

local SAMPLE = [[
-- A preset is data, not executable Lua.
return {
  schema = "portemon-save-preset-v1",
  name = "Celebi event",
  description = "Position before the event.",
  flags = { FLAG_GOT_POKEDEX = true, },
  variables = { VAR_UNK_40FE = 0 },
  items = { POTION = 5, POKE_BALL = 3 },
  party = {
    lead = { species = "CELEBI", fatefulEncounter = true, eggLocation = 0 },
    contains = { { species = "PIKACHU", level = 20 }, },
  },
  location = { map = "MAP_ILEX_FOREST", x = 16, z = 56, facing = "north" },
}
]]

local function parse(source)
  Assert.isTrue(
    parserLoaded and type(SaveEditorPreset.parse) == "function",
    "Save Editor preset parsing must accept bounded declarative Lua-table data"
  )
  return SaveEditorPreset.parse(source)
end

local function openSession(overrideSymbols)
  local fixture = Fixture.new()
  local symbols = overrideSymbols and overrideSymbols(fixture.symbols) or fixture.symbols
  local session = assert(Session.new({
    record = fixture.initial,
    context = fixture.context,
    saveStore = fixture.store,
    saveFs = fixture.saveFs,
    validateRecord = fixture.validateRecord,
    symbols = symbols,
  }))
  return fixture, session
end

local function apply(session, preset, expectedRevision, placement)
  Assert.isTrue(
    type(session.applyPreset) == "function",
    "Save Editor session must expose one atomic preset staging operation"
  )
  return session:applyPreset(preset, {
    expectedRevision = expectedRevision,
    placement = placement,
    metLocation = 7,
    date = { year = 2000, month = 1, day = 1 },
  })
end

function T.tests.literal_parser_returns_detached_v1_data()
  local preset, err = parse(SAMPLE)

  Assert.isNil(err, "the valid preset parses without an error")
  Assert.notNil(preset, "the valid preset returns data")
  Assert.equal(preset.schema, "portemon-save-preset-v1")
  Assert.equal(preset.variables.VAR_UNK_40FE, 0, "zero remains an explicit variable value")
  Assert.equal(preset.items.POKE_BALL, 3, "item values express minimum quantities")
  Assert.equal(preset.party.lead.eggLocation, 0)
  Assert.isTrue(preset.party.lead.fatefulEncounter)
  Assert.equal(preset.location.facing, "north")

  preset.flags.FLAG_GOT_POKEDEX = false
  local again = assert(parse(SAMPLE))
  Assert.isTrue(again.flags.FLAG_GOT_POKEDEX, "each parse owns a detached result")

  local quoted = assert(parse([[return {
    schema = "portemon-save-preset-v1",
    name = "Quoted \"name\"",
    description = 'It\'s valid',
    flags = { ["FLAG_GOT_POKEDEX"] = true },
  }]]))
  Assert.equal(quoted.name, 'Quoted "name"', "quoted keys and escaped double quotes are accepted")
  Assert.equal(quoted.description, "It's valid", "escaped single quotes are accepted")
  Assert.isTrue(quoted.flags.FLAG_GOT_POKEDEX, "a quoted symbol key resolves unchanged")
end

function T.tests.executable_and_malformed_sources_are_rejected_without_execution()
  _G.savePresetMustNotExecute = nil
  local preset, err = parse([[return (function() _G.savePresetMustNotExecute = true end)()]])

  Assert.isNil(preset, "executable Lua is rejected")
  Assert.notNil(err, "the parser reports a structured error")
  Assert.isNil(_G.savePresetMustNotExecute, "rejected source never executes")
  _G.savePresetMustNotExecute = nil

  for _, source in ipairs({
    SAMPLE:gsub("POKE_BALL = 3", "POKE_BALL = 3, POKE_BALL = 4"),
    SAMPLE:gsub('schema = "portemon%-save%-preset%-v1"', 'schema = "other"'),
    SAMPLE:gsub("level = 20", "level = 20, unexpected = true"),
    SAMPLE:gsub("contains = {", "contains = { [2] ="),
    SAMPLE .. " os.execute('touch /tmp/should-not-exist')",
    "return " .. string.rep("{", 13) .. "true" .. string.rep("}", 13),
    string.rep(" ", 128 * 1024 + 1),
    SAMPLE:gsub("Celebi event", "Celebi " .. string.char(0xFF)),
  }) do
    local invalid, invalidError = parse(source)
    Assert.isNil(invalid, "malformed or unsupported preset input is rejected")
    Assert.notNil(invalidError, "rejection includes a diagnostic")
  end

  local entries = {}
  for index = 1, 1025 do
    entries[index] = "key" .. index .. " = true"
  end
  local oversizedTable = "return {" .. table.concat(entries, ",") .. "}"
  local tooMany, tooManyError = parse(oversizedTable)
  Assert.isNil(tooMany, "tables over the total entry budget are rejected")
  Assert.notNil(tooManyError, "entry-budget rejection is structured")
end

function T.tests.absent_false_flag_and_zero_variable_are_semantic_noops()
  local _, session = openSession(function(symbols)
    return { flagsByName = symbols.flagsByName, variablesByName = { VAR_ZERO = 8 } }
  end)
  local before = session:snapshot().revision
  local result = apply(session, {
    schema = "portemon-save-preset-v1",
    name = "No-op values",
    description = "Leave logically absent values unchanged.",
    flags = { FLAG_GOT_POKEDEX = false },
    variables = { VAR_ZERO = 0 },
  }, before)

  Assert.isTrue(result.ok, "logical false and zero values apply successfully")
  Assert.isFalse(result.changed, "absent false and zero values do not publish")
  Assert.equal(session:snapshot().revision, before, "semantic no-op leaves the revision unchanged")
  Assert.isFalse(session:snapshot().dirtySections.flags, "semantic no-op leaves Progress clean")
end

function T.tests.flags_and_zero_variable_stage_once_without_writing_the_save()
  local fixture, session = openSession(function(symbols)
    return { flagsByName = symbols.flagsByName, variablesByName = { VAR_TEST = 7 } }
  end)
  local beforeRevision = session:snapshot().revision
  local originalSave = fixture.store:load(fixture.saveId)
  local preset = assert(parse([[
    return {
      schema = "portemon-save-preset-v1",
      name = "Progress",
      description = "Set a flag and clear a variable.",
      flags = { FLAG_GOT_POKEDEX = true },
      variables = { VAR_TEST = 0 },
    }
  ]]))

  local result = apply(session, preset, beforeRevision)

  Assert.isTrue(result.ok, "valid preset changes are staged")
  Assert.isTrue(result.changed, "the staged state reports a change")
  Assert.equal(session:snapshot().revision, beforeRevision + 1, "one preset publishes one revision")
  Assert.isTrue(session:snapshot().dirtySections.flags, "flags and variables share Progress dirty state")
  local candidateEvents = FieldEventState.new({ vars = session:captureCandidate().world.variables })
  Assert.equal(candidateEvents:getVar(7), 0, "a nonzero variable is staged as logical zero")
  Assert.deepEqual(fixture.store:load(fixture.saveId), originalSave, "preset application never writes the save")

  local saved = session:save()
  Assert.isTrue(saved.ok, "the existing manual Save publishes the staged preset")
  local reloaded = fixture.store:load(fixture.saveId)
  Assert.isTrue(reloaded.world.flags[107], "the staged flag persists through Save")
  Assert.equal(
    FieldEventState.new({ vars = reloaded.world.variables }):getVar(7),
    0,
    "the staged zero variable persists through Save"
  )
  Assert.isFalse(session:snapshot().dirtySections.flags, "Progress is clean after Save")
end

function T.tests.full_party_matches_distinct_species_requests_and_bag_minimums_idempotently()
  local fixture, session = openSession()
  for _ = 1, 6 do
    local draft = assert(session:beginMonAdd("CHIKORITA", {
      location = 7,
      date = { year = 2000, month = 1, day = 1 },
    }))
    Assert.isTrue(session:applyMonDraft(draft).ok, "a party member is staged")
  end
  local preset = assert(parse([[
    return {
      schema = "portemon-save-preset-v1",
      name = "Party and Bag",
      description = "Match two distinct members and ensure a minimum.",
      party = {
        lead = { species = "CHIKORITA", level = 5 },
        contains = { { species = "CHIKORITA" } },
      },
      items = { POKE_BALL = 5 },
    }
  ]]))

  local first = apply(session, preset, session:snapshot().revision)

  Assert.isTrue(first.ok, "matching and append requirements stage successfully")
  Assert.isTrue(first.changed, "the lead update, distinct member and Bag minimum change state")
  local party = session:partySnapshot().members
  Assert.equal(#party, 6, "matching requests succeed without room to append")
  Assert.equal(party[1].mon.species, "CHIKORITA")
  Assert.equal(
    SaveEditorMonDraft.projectRecord(party[1].mon, { catalog = fixture.context.monCatalog }).level,
    5,
    "requested level updates the matching species' semantic projection"
  )
  Assert.equal(party[2].mon.species, "CHIKORITA", "contains selects a second distinct member")
  local balls = session:bagSnapshot("balls")
  Assert.equal(#balls, 1, "the minimum creates one Bag stack")
  Assert.equal(balls[1].quantity, 5, "the Bag reaches the requested minimum")

  local revision = session:snapshot().revision
  local repeated = apply(session, preset, revision)

  Assert.isTrue(repeated.ok, "a satisfied preset can be applied again")
  Assert.isFalse(repeated.changed, "repeat application is a no-op")
  Assert.equal(session:snapshot().revision, revision, "no-op application does not bump revision")
  Assert.equal(#session:partySnapshot().members, 6, "repeat application does not duplicate party members")
  Assert.equal(session:bagSnapshot("balls")[1].quantity, 5, "repeat application does not increase Bag quantities")
end

function T.tests.variables_and_facing_reset_independently_and_stale_revisions_reject()
  local _, session = openSession(function(symbols)
    return { flagsByName = symbols.flagsByName, variablesByName = { VAR_TEST = 7 } }
  end)
  local initial = session:snapshot()
  local placement = {
    mapId = initial.location.mapId,
    fieldX = initial.location.fieldX,
    fieldZ = initial.location.fieldZ,
    worldY = initial.location.worldY,
    surfaceId = initial.location.surfaceId,
    terrainDependencyHash = initial.location.terrainDependencyHash,
  }
  local preset = {
    schema = "portemon-save-preset-v1",
    name = "Variable and facing",
    description = "Stage a zero variable and facing at the current tile.",
    variables = { VAR_TEST = 0 },
    location = { map = "MAP_TEST", x = placement.fieldX, z = placement.fieldZ, facing = "north" },
  }

  local result = apply(session, preset, initial.revision, placement)

  Assert.isTrue(result.ok, "variable and facing changes stage")
  Assert.isTrue(session:snapshot().dirtySections.flags, "variables contribute to Progress dirty state")
  Assert.isTrue(session:snapshot().dirtySections.location, "facing contributes to Location dirty state")
  Assert.isFalse(session:snapshot().locationChanged, "facing alone does not report geometry movement")
  Assert.equal(session:snapshot().facing, "north", "the new facing is visible in the session snapshot")
  Assert.isTrue(session:discardSection("Progress"), "Progress reset restores the variable")
  Assert.isFalse(session:snapshot().dirtySections.flags, "Progress is clean after its reset")
  Assert.isTrue(session:snapshot().dirtySections.location, "resetting Progress preserves facing")
  Assert.isTrue(session:discardSection("Location"), "Location reset restores facing")
  Assert.isFalse(session:snapshot().dirtySections.location, "Location is clean after its reset")

  local beforeCandidate = session:captureCandidate()
  local beforeRevision = session:snapshot().revision
  Assert.isTrue(session:setMoney(3100).ok, "a later staged edit advances the session revision")
  local stale = apply(session, {
    schema = "portemon-save-preset-v1",
    name = "Stale",
    description = "Reject a stale publication.",
    flags = { FLAG_GOT_POKEDEX = true },
  }, beforeRevision)

  Assert.isFalse(stale.ok, "stale expected revisions are rejected")
  Assert.deepEqual(session:captureCandidate().world, beforeCandidate.world, "stale rejection preserves world edits")
  Assert.equal(session:snapshot().money, 3100, "stale rejection preserves newer staged edits")
end

function T.tests.late_domain_failure_preserves_all_staged_state_and_revisions()
  local fixture, session = openSession()
  Assert.isTrue(session:setMoney(3100).ok, "an unrelated edit is staged first")
  local beforeCandidate = session:captureCandidate()
  local beforeSnapshot = session:snapshot()
  local beforePartyRevision = session:partyRevision()
  local beforeParty = session:partySnapshot()
  local beforeBag = session:bagSnapshot("balls")
  local originalSave = fixture.store:load(fixture.saveId)
  local preset = {
    schema = "portemon-save-preset-v1",
    name = "Rejected patch",
    description = "An unknown item follows a valid flag update.",
    flags = { FLAG_GOT_POKEDEX = true },
    items = { NOT_A_REAL_ITEM = 1 },
  }

  local result = apply(session, preset, beforeSnapshot.revision)

  Assert.isFalse(result.ok, "unknown catalog entries reject the whole preset")
  Assert.notNil(result.error, "rejection is structured")
  Assert.deepEqual(session:captureCandidate(), beforeCandidate, "candidate saves are unchanged after rejection")
  Assert.deepEqual(session:snapshot().dirtySections, beforeSnapshot.dirtySections, "dirty projection is unchanged")
  Assert.equal(session:snapshot().revision, beforeSnapshot.revision, "rejection does not bump session revision")
  Assert.equal(session:partyRevision(), beforePartyRevision, "rejection does not bump party revision")
  Assert.deepEqual(session:partySnapshot(), beforeParty, "party state is unchanged")
  Assert.deepEqual(session:bagSnapshot("balls"), beforeBag, "Bag state is unchanged")
  Assert.deepEqual(fixture.store:load(fixture.saveId), originalSave, "rejection does not touch the save")
end

function T.tests.programming_failure_during_catalog_lookup_is_not_reclassified()
  local _, session = openSession()
  local before = session:captureCandidate()
  local originalNew = HgssBagService.new
  HgssBagService.new = function(options)
    local candidate = originalNew(options)
    candidate.catalog = function()
      return {
        item = function()
          error("injected catalog invariant failure", 0)
        end,
      }
    end
    return candidate
  end
  local ok, result = pcall(function()
    session:applyPreset({
      schema = "portemon-save-preset-v1",
      name = "Catalog failure",
      description = "Preserve programming failures from catalog lookup.",
      items = { POTION = 1 },
    }, {
      expectedRevision = session:revision(),
      metLocation = 7,
      date = { year = 2000, month = 1, day = 1 },
    })
  end)
  HgssBagService.new = originalNew

  Assert.isFalse(ok, "programming failures escape preset application")
  Assert.equal(result, "injected catalog invariant failure", "the original invariant failure remains visible")
  Assert.deepEqual(session:captureCandidate(), before, "candidate lookup failure leaves staged data unchanged")
end

function T.tests.revision_change_during_candidate_staging_rejects_before_publication()
  local _, session = openSession()
  local before = session:snapshot()
  local beforeParty = session:partySnapshot()
  local beforePartyRevision = session:partyRevision()
  local originalNew = SaveEditorMonDraft.new
  SaveEditorMonDraft.new = function(options)
    Assert.isTrue(session:setMoney(before.money + 1).ok, "a reentrant edit advances the live session revision")
    return originalNew(options)
  end
  local ok, result = pcall(function()
    return apply(session, {
      schema = "portemon-save-preset-v1",
      name = "Concurrent edit",
      description = "Reject a candidate made stale during staging.",
      party = { contains = { { species = "CHIKORITA" } } },
    }, before.revision)
  end)
  SaveEditorMonDraft.new = originalNew
  if not ok then
    error(result, 0)
  end

  Assert.isFalse(result.ok, "a revision change during candidate work rejects the preset")
  Assert.equal(result.error.code, "SAVE_EDITOR_PRESET_STALE")
  Assert.equal(session:snapshot().money, before.money + 1, "the newer live edit remains staged")
  Assert.deepEqual(session:partySnapshot(), beforeParty, "the stale Party candidate is not published")
  Assert.equal(session:partyRevision(), beforePartyRevision, "stale publication does not bump Party revision")
end

return T
