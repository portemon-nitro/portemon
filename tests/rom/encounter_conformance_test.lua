-- Independent encounter and trainer evidence bound to each ready dump:
-- trigger, slot-ladder, and level-window selection replay branch-derived
-- vectors; the ready dump preserves ordered native slot intervals,
-- game replacements, and lookup detachment; and native trainer generation
-- maps template difficulty to individual values, applies gender-override
-- polarity, resolves the saved rival name per story branch, and leaves
-- the surrounding random stream untouched. Every expected value below is
-- transcribed from the native selection branches, the trainer data
-- source, or previously pinned vectors; nothing is read out of the
-- production functions under test.

local Assert = require("tests.support.Assert")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local SOURCE_REVISION = "0985e8718df4f25e64d6507d89c0c97c0d288981"
local FIXED_SEED = 287454020

---@param name string module path under test
---@param behavior string observable behavior the module owns
---@return table the loaded module
local function requirePresent(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing conformance behavior: " .. behavior .. " (" .. name .. ")")
  assert(loaded ~= nil, "the conformance module loads")
  return loaded --[[@as table]]
end

function T.trigger_slot_and_level_vectors_match_the_native_branches(romFs, versionId)
  Assert.notNil(romFs, "the selection oracle runs with its ready dump open")
  local Fixture = requirePresent("tests.support.BattleFidelityFixture", "independent fixture and provenance validation")
  local Selection = requirePresent(
    "libs.hgss.src.encounters.EncounterSelection",
    "native table, rate, and level selection owns trigger order"
  )
  local EncounterFixture = require("libs.hgss.tests.encounter_fixture")
  local daySlots = EncounterFixture.vectorCatalog().tables[11].land.day

  -- Opportunity boundaries fixed from the native rate comparison: rolls
  -- below the rate trigger, rolls at the boundary do not, and the empty
  -- and full rates never depend on the roll.
  local triggerRecord = {
    provenance = {
      basis = "source-derived",
      sourceRevision = SOURCE_REVISION,
      sourceLocation = "pret/pokeheartgold src/field/encounter_check.c (opportunity check)",
      evidenceIdentity = "opportunity boundaries bound to " .. versionId,
      oracleMethod = "hand transcription of the native rate comparison, cross-checked by the encounter vector suite",
    },
    input = {
      { rate = 0, roll = 50 },
      { rate = 100, roll = 50 },
      { rate = 30, roll = 29 },
      { rate = 30, roll = 30 },
    },
    expected = { false, true, true, false },
  }
  Fixture.validate(triggerRecord)
  local triggerActual = Fixture.run(function()
    local outcomes = {}
    for _, case in ipairs(triggerRecord.input) do
      outcomes[#outcomes + 1] = Selection.trigger(case.rate, case.roll)
    end
    return outcomes
  end, triggerRecord)
  Assert.isNil(
    Fixture.compare(triggerActual, { expected = triggerRecord.expected }),
    versionId .. " triggers exactly at the native rate boundary"
  )

  -- Ordered land interval widths in source order:
  -- 20,20,10,10,10,10,5,5,4,4,1,1. Spot checks below walk every ladder
  -- edge of the pinned twelve-slot table.
  local slotRecord = {
    provenance = {
      basis = "source-derived",
      sourceRevision = SOURCE_REVISION,
      sourceLocation = "pret/pokeheartgold src/field/encounter_check.c (ordered slot ladders)",
      evidenceIdentity = "land ladder edges bound to " .. versionId,
      oracleMethod = "hand transcription of the native interval widths, cross-checked by the encounter vector suite",
    },
    input = { 0, 19, 20, 40, 90, 93, 94, 97, 98, 99 },
    expected = { 1, 1, 2, 3, 9, 9, 10, 10, 11, 12 },
  }
  Fixture.validate(slotRecord)
  local slotActual = Fixture.run(function()
    local slots = {}
    for _, roll in ipairs(slotRecord.input) do
      slots[#slots + 1] = Selection.selectSlot(daySlots, roll)
    end
    return slots
  end, slotRecord)
  Assert.isNil(
    Fixture.compare(slotActual, { expected = slotRecord.expected }),
    versionId .. " walks the ordered land intervals exactly"
  )

  -- Level windows: fixed entries ignore the roll, spanned entries wrap on
  -- their width (roll 21105 mod 5 is 0).
  local levelRecord = {
    provenance = {
      basis = "source-derived",
      sourceRevision = SOURCE_REVISION,
      sourceLocation = "pret/pokeheartgold src/field/encounter_check.c (level windows)",
      evidenceIdentity = "level window edges bound to " .. versionId,
      oracleMethod = "hand transcription of the native window wrap, cross-checked by the encounter vector suite",
    },
    input = {
      { slot = { species = "EEVEE", form = 0, minLevel = 8, maxLevel = 8, weight = 10 }, roll = 0 },
      { slot = { species = "CHIKORITA", form = 0, minLevel = 5, maxLevel = 9, weight = 15 }, roll = 0 },
      { slot = { species = "CHIKORITA", form = 0, minLevel = 5, maxLevel = 9, weight = 15 }, roll = 4 },
      { slot = { species = "CHIKORITA", form = 0, minLevel = 5, maxLevel = 9, weight = 15 }, roll = 5 },
      { slot = { species = "CHIKORITA", form = 0, minLevel = 5, maxLevel = 9, weight = 15 }, roll = 21105 },
    },
    expected = { 8, 5, 9, 5, 5 },
  }
  Fixture.validate(levelRecord)
  local levelActual = Fixture.run(function()
    local levels = {}
    for _, case in ipairs(levelRecord.input) do
      levels[#levels + 1] = Selection.selectLevel(case.slot, case.roll)
    end
    return levels
  end, levelRecord)
  Assert.isNil(
    Fixture.compare(levelActual, { expected = levelRecord.expected }),
    versionId .. " stays inside the source level windows"
  )

  local shifted = { 1, 1, 2, 3, 9, 9, 10, 10, 11, 11 }
  local ladderMismatch = Fixture.compare(shifted, { expected = slotRecord.expected })
  Assert.isTrue(type(ladderMismatch) == "table", "a shifted ladder edge reports its mismatch")
  Assert.notNil(ladderMismatch.expected, "ladder mismatches carry the expected slots")
  Assert.notNil(ladderMismatch.actual, "ladder mismatches carry the actual slots")
end

function T.ready_dumps_preserve_ordered_slots_replacements_and_detachment(romFs, versionId)
  local Fixture = requirePresent("tests.support.BattleFidelityFixture", "independent fixture and provenance validation")
  local Catalog = requirePresent(
    "libs.hgss.src.encounters.HgssEncounterCatalog",
    "validated encounter-table lookup owns ordered slots"
  )
  local EncounterCatalogCompiler = require("romdump.src.digest.encounters.EncounterCatalogCompiler")
  local BattleSources = require("romdump.src.config.BattleSources")
  local compiled = assert(EncounterCatalogCompiler.compileFromDump(romFs, { versionId = versionId }))
  local catalog = Catalog.new(compiled)
  local memberId = nil
  for key in pairs(compiled.tables) do
    if memberId == nil or key < memberId then
      memberId = key
    end
  end
  Assert.notNil(memberId, versionId .. " must yield at least one encounter table")

  local weightsRecord = {
    provenance = {
      basis = "observed-rom",
      sourceRevision = versionId,
      sourceLocation = "user-owned dump, compiled native encounter tables",
      evidenceIdentity = "ordered day-slot intervals of member "
        .. tostring(memberId)
        .. " in the ready "
        .. versionId
        .. " dump",
      oracleMethod = "decoder output compared against the pinned native interval widths without reusing the decoder under test",
    },
    input = { memberId = memberId, versionId = versionId },
    expected = { weights = BattleSources.slotWeights.land },
  }
  Fixture.validate(weightsRecord)
  local weightsActual = Fixture.run(function()
    local resolved = catalog:tableFor(memberId, { timeOfDay = "day", swarm = false, radio = "none", game = versionId })
    Assert.equal(#resolved.land.day, 12, "member " .. tostring(memberId) .. " keeps twelve day slots")
    local weights = {}
    for _, entry in ipairs(resolved.land.day) do
      Assert.isTrue(type(entry.species) == "string" and entry.species ~= "", "slots resolve semantic species")
      weights[#weights + 1] = entry.weight
    end
    for name, replacement in pairs(resolved.replacements) do
      Assert.equal(replacement.game, versionId, "replacement " .. name .. " names the supported game")
    end
    return { weights = weights }
  end, weightsRecord)
  Assert.isNil(
    Fixture.compare(weightsActual, { expected = weightsRecord.expected }),
    versionId .. " preserves the ordered native slot intervals"
  )

  local probe = catalog:tableFor(memberId, { timeOfDay = "day", swarm = false, radio = "none", game = versionId })
  probe.land.day[1].species = "MUTATED"
  local fresh = catalog:tableFor(memberId, { timeOfDay = "day", swarm = false, radio = "none", game = versionId })
  Assert.isTrue(fresh.land.day[1].species ~= "MUTATED", "lookup returns detached tables")
  Assert.equal(catalog:specialTable(memberId, "safari").context, "safari", "special contexts resolve by name")
end

---@param overrides table<string, unknown>|nil template overrides
---@return table<string, unknown> native-identity member template
local function plainMember(overrides)
  local member = {
    species = "CHIKORITA",
    form = 0,
    level = 5,
    difficulty = 3,
    heldItem = "NONE",
    moves = nil,
    friendship = 70,
    identityPolicy = "native_pid",
    identityParams = { genderOverride = 0, abilityOverride = 0, capsule = 0 },
  }
  for key, value in pairs(overrides or {}) do
    member[key] = value
  end
  return member
end

-- Native trainer generation: template difficulty maps to individual
-- values through floor(difficulty*31/255), the gender-override nibble
-- selects male, and the saved rival name resolves per story branch.
-- Transcribed from the trainer data source
-- (pret/pokeheartgold src/trainer_data.c: difficulty-to-IV calculation
-- and PID/gender override polarity) and pinned by the trainer generation
-- suite, never read out of the factory under test.
function T.native_trainer_generation_maps_difficulty_applies_overrides_and_names_the_rival(romFs, versionId)
  Assert.notNil(romFs, "the trainer oracle runs with its ready dump open")
  local Fixture = requirePresent("tests.support.BattleFidelityFixture", "independent fixture and provenance validation")
  local Catalog = requirePresent(
    "libs.hgss.src.battle.HgssTrainerCatalog",
    "immutable trainer templates resolve runtime content keys"
  )
  local Factory =
    requirePresent("libs.hgss.src.battle.HgssTrainerFactory", "source trainer generation builds native parties")
  local BattleRng = require("libs.battle.src.gen4.BattleRng")
  local catalog = Catalog.new({
    trainers = {
      falkner = {
        key = "falkner",
        trainerClass = "YOUNGSTER",
        nameReference = { trainerIndex = 8 },
        party = { plainMember(), plainMember({ species = "PIDGEY", level = 6 }) },
        aiPasses = {},
        doubleBattle = false,
        items = {},
      },
      overridden = {
        key = "overridden",
        trainerClass = "YOUNGSTER",
        nameReference = { trainerIndex = 8 },
        party = {
          plainMember({
            species = "EEVEE",
            identityParams = { genderOverride = 1, abilityOverride = 1, capsule = 7 },
            form = 0,
          }),
        },
        aiPasses = {},
        doubleBattle = false,
        items = {},
      },
      rival = {
        key = "rival",
        trainerClass = "RIVAL",
        nameReference = { rival = true },
        party = { plainMember({ species = "CHIKORITA", level = 5 }) },
        aiPasses = {},
        doubleBattle = false,
        items = {},
        variants = {
          elm = { party = { plainMember({ species = "CHIKORITA", level = 5 }) } },
          finals = { party = { plainMember({ species = "MEGANIUM", level = 38 }) } },
        },
      },
    },
    programs = {},
  })
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local ItemFixture = require("libs.items.tests.item_fixture")
  local MonCatalog = require("libs.mons.src.MonCatalog")
  local MonCatalogCompiler = require("romdump.src.digest.mons.MonCatalogCompiler")
  local MonSources = require("romdump.src.config.MonSources")
  local monRoot = assert(MonCatalogCompiler.compileCatalog(romFs, { versionId = versionId }))
  local monCatalog = MonCatalog.new(monRoot, ItemFixture.makeCatalog())
  local factory = Factory.new({
    catalog = catalog,
    monCatalog = monCatalog,
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    game = versionId,
    language = MonSources.versionLanguages[versionId],
  })
  local trainerIds = { falkner = 8, overridden = 9, rival = 27 }
  ---@param trainerKey string
  ---@param stream table labeled native stream
  ---@param extra table<string, unknown>|nil
  ---@return table build context in source field order
  local function buildContext(trainerKey, stream, extra)
    local context = {
      catalog = catalog,
      trainerKey = trainerKey,
      trainerId = trainerIds[trainerKey],
      playerProfile = { name = "GOLD", id = 12345 },
      rivalName = "SILVER",
      rng = stream,
    }
    for key, value in pairs(extra or {}) do
      context[key] = value
    end
    return context
  end
  local zeroIvs = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 }

  local difficultyRecord = {
    provenance = {
      basis = "source-derived",
      sourceRevision = SOURCE_REVISION,
      sourceLocation = "pret/pokeheartgold src/trainer_data.c (difficulty-to-IV calculation)",
      evidenceIdentity = "difficulty 3 maps to zero individual values, bound to " .. versionId,
      oracleMethod = "hand transcription of floor(difficulty*31/255), cross-checked by the trainer generation suite",
    },
    input = { trainerKey = "falkner", seed = FIXED_SEED },
    expected = {
      species = "CHIKORITA",
      level = 5,
      friendship = 70,
      heldItem = "NONE",
      ivs = zeroIvs,
    },
  }
  Fixture.validate(difficultyRecord)
  local difficultyActual = Fixture.run(function()
    local MonStats = require("libs.mons.src.gen4.MonStats")
    local party = factory:build(buildContext("falkner", BattleRng.new(FIXED_SEED)))
    local mon = assert(party.mons, "built parties carry their ordered mons")[1]
    Assert.isTrue(type(mon.moves) == "table" and #mon.moves >= 1, "plain members resolve initial-learnset moves")
    return {
      species = mon.species,
      level = MonStats.derive(mon, monCatalog).level,
      friendship = mon.friendship,
      heldItem = mon.heldItem,
      ivs = mon.ivs,
    }
  end, difficultyRecord)
  Assert.isNil(
    Fixture.compare(difficultyActual, { expected = difficultyRecord.expected }),
    versionId .. " maps template difficulty to individual values exactly"
  )
  local ivMismatch = Fixture.compare({ ivs = { hp = 1 } }, { expected = { ivs = zeroIvs } })
  Assert.isTrue(type(ivMismatch) == "table", "a changed IV formula reports its mismatch")

  local overrideRecord = {
    provenance = {
      basis = "source-derived",
      sourceRevision = SOURCE_REVISION,
      sourceLocation = "pret/pokeheartgold src/trainer_data.c (PID and gender override polarity)",
      evidenceIdentity = "gender and ability overrides bound to " .. versionId,
      oracleMethod = "hand transcription of the override polarity, cross-checked by the trainer generation suite",
    },
    input = { trainerKey = "overridden", seed = FIXED_SEED },
    expected = { gender = "male", ability = "RUN_AWAY", capsule = 7 },
  }
  Fixture.validate(overrideRecord)
  local overrideActual = Fixture.run(function()
    local party = factory:build(buildContext("overridden", BattleRng.new(FIXED_SEED)))
    local mon = assert(party.mons, "built parties carry their ordered mons")[1]
    local Personality = require("libs.mons.src.gen4.Personality")
    local ratio = monCatalog:species("EEVEE").genderRatio
    Assert.equal(ratio, 31, "the dump carries the skewed EEVEE gender fact")
    return { gender = Personality.gender(ratio, mon.personality), ability = mon.ability, capsule = mon.capsule.id }
  end, overrideRecord)
  Assert.isNil(
    Fixture.compare(overrideActual, { expected = overrideRecord.expected }),
    versionId .. " applies gender and ability overrides exactly"
  )

  local rivalRecord = {
    provenance = {
      basis = "source-derived",
      sourceRevision = SOURCE_REVISION,
      sourceLocation = "pret/pokeheartgold src/trainer_data.c (rival name indirection and party variants)",
      evidenceIdentity = "rival branches bound to " .. versionId,
      oracleMethod = "hand transcription of the story-branch parties, cross-checked by the trainer generation suite",
    },
    input = { trainerKey = "rival", seed = FIXED_SEED },
    expected = {
      elmName = "SILVER",
      elmSpecies = "CHIKORITA",
      finalsSpecies = "MEGANIUM",
      renamedName = "GARY",
    },
  }
  Fixture.validate(rivalRecord)
  local rivalActual = Fixture.run(function()
    local early = factory:build(buildContext("rival", BattleRng.new(FIXED_SEED), { storyVariant = "elm" }))
    local late = factory:build(buildContext("rival", BattleRng.new(FIXED_SEED), { storyVariant = "finals" }))
    local renamed =
      factory:build(buildContext("rival", BattleRng.new(FIXED_SEED), { storyVariant = "elm", rivalName = "GARY" }))
    return {
      elmName = early.name,
      elmSpecies = assert(early.mons, "rival parties carry ordered mons")[1].species,
      finalsSpecies = assert(late.mons, "rival parties carry ordered mons")[1].species,
      renamedName = renamed.name,
    }
  end, rivalRecord)
  Assert.isNil(
    Fixture.compare(rivalActual, { expected = rivalRecord.expected }),
    versionId .. " resolves the saved rival name per story branch"
  )

  local stream = BattleRng.new(FIXED_SEED)
  local before = stream:capture()
  local first = factory:build(buildContext("falkner", stream))
  Assert.deepEqual(stream:capture(), before, "generation restores the surrounding stream position")
  local second = factory:build(buildContext("falkner", BattleRng.new(FIXED_SEED)))
  local firstMons = assert(first.mons, "built parties carry their ordered mons")
  local secondMons = assert(second.mons, "rebuilt parties carry their ordered mons")
  Assert.equal(#firstMons, #secondMons, "rebuilds keep the same slot count")
  for index, mon in ipairs(firstMons) do
    Assert.equal(mon.personality, secondMons[index].personality, "slot " .. index .. " replays its personality")
    Assert.deepEqual(mon.ivs, secondMons[index].ivs, "slot " .. index .. " replays its individual values")
  end
end

return RomSuite.fromFacts(T)
