-- Raw mon edits stay local while each independent derived preview uses the
-- production Generation-IV catalog and formula owners.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")

local T = {}

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, item in pairs(value) do
    result[key] = copy(item)
  end
  return result
end

local function fixtureMon()
  local catalog = CatalogFixture.makeCatalog()
  local context = CatalogFixture.domainContext(catalog)
  local Mon = require("libs.mons.src.Mon")
  local factory = CatalogFixture.makeFactory(0x12345678, catalog)
  local mon = factory:createNormal(CatalogFixture.normalRequest({ level = 9 }))
  mon.markings = 5
  mon.contest = { cool = 1, beauty = 2, cute = 3, smart = 4, tough = 5, sheen = 6 }
  mon.ribbons = { ds1 = 17, gba = 23, ds2 = 31 }
  mon.egg = { location = 12, date = { year = 2008, month = 2, day = 29 } }
  mon.capsule = { id = 4, seals = { { x = 12, y = 34, graphic = 56 } } }
  mon.mail = {}
  return catalog, context, Mon.validate(mon, context)
end

local function assertProjectionMatches(candidate, context, projection)
  local Experience = require("libs.mons.src.gen4.Experience")
  local Personality = require("libs.mons.src.gen4.Personality")
  local Stats = require("libs.mons.src.gen4.Stats")
  local species = context.catalog:species(candidate.species)
  local form = context.catalog:form(candidate.species, candidate.form)
  local level = Experience.level(context.catalog:growthCurve(species.growthCurve), candidate.experience)
  local nature = Personality.nature(candidate.personality)
  local maxStats = Stats.calculate(form.baseStats, candidate.ivs, candidate.evs, level, nature)
  if candidate.species == "SHEDINJA" then
    maxStats.hp = 1
  end
  Assert.equal(projection.level, level)
  Assert.equal(projection.nature, nature)
  Assert.equal(projection.gender, Personality.gender(species.genderRatio, candidate.personality))
  Assert.equal(projection.shiny, Personality.shiny(candidate.origin.trainerId, candidate.personality))
  Assert.deepEqual(projection.stats, maxStats)
end

local function draftFor(record, context)
  local Draft = require("app.src.saveeditor.SaveEditorMonDraft")
  return Draft.new({
    mode = "edit",
    slot0 = 0,
    basePartyRevision = 3,
    record = record,
    context = context,
  })
end

local function validMon(catalog, species, level)
  local factory = CatalogFixture.makeFactory(0x13572468, catalog)
  return factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level }))
end

function T.raw_edits_project_independently_and_never_repair_or_drop_other_fields()
  local catalog, context, original = fixtureMon()
  local Mon = require("libs.mons.src.Mon")
  local NativeLegality = require("libs.mons.src.gen4.NativeLegality")
  local Experience = require("libs.mons.src.gen4.Experience")
  local Personality = require("libs.mons.src.gen4.Personality")
  local Draft = require("app.src.saveeditor.SaveEditorMonDraft")

  local draft = Draft.new({
    mode = "edit",
    slot0 = 0,
    basePartyRevision = 7,
    record = original,
    context = context,
  })
  Assert.deepEqual(draft:record(), original)
  assertProjectionMatches(original, context, draft:projection())

  -- PID affects its own derived properties; independently stored ability is
  -- left alone even when the selected PID parity selects another slot.
  local initialAbility = original.ability
  local personality = original.personality + 1
  Assert.isTrue(draft:setScalar("personality", personality))
  Assert.equal(draft:record().ability, initialAbility)
  local projected = draft:projection()
  assertProjectionMatches(draft:record(), context, projected)

  -- Species and form edits keep experience and ability raw. EEVEE uses the
  -- medium-fast curve, so 130 EXP projects to a different level than the
  -- original medium-slow curve without changing the stored EXP.
  Assert.isTrue(draft:setScalar("experience", 130))
  Assert.equal(draft:projection().level, Experience.level(catalog:growthCurve("medium_slow"), 130))
  Assert.isTrue(draft:setScalar("species", "EEVEE"))
  Assert.isTrue(draft:setScalar("ability", "RUN_AWAY"))
  Assert.isTrue(draft:setScalar("personality", 0xFFFFFFFF))
  Assert.equal(draft:record().ability, "RUN_AWAY")
  Assert.equal(Personality.abilitySlot(#catalog:form("EEVEE", 0).abilities, 0xFFFFFFFF), 2)
  Assert.isTrue(draft:setScalar("form", 1))
  Assert.equal(draft:record().experience, 130)
  Assert.equal(draft:record().ability, "RUN_AWAY")
  Assert.equal(draft:projection().level, Experience.level(catalog:growthCurve("medium_fast"), 130))

  -- A permitted ability remains independent from PID parity. The form change
  -- and invalid HP remain visible as validation conflicts, while valid
  -- PID/EXP/species dependencies still refresh their previews.
  Assert.isFalse(draft:projection().shiny)
  Assert.isTrue(draft:setOrigin("trainerId", 0xFFFFFFFF))
  Assert.isTrue(draft:projection().shiny)
  Assert.isTrue(draft:setScalar("currentHp", 999))
  Assert.isTrue(draft:setMet("level", 99))
  local conflicted = draft:record()
  Assert.equal(conflicted.ability, "RUN_AWAY")
  Assert.equal(conflicted.personality, 0xFFFFFFFF)
  Assert.equal(conflicted.experience, 130)
  Assert.equal(conflicted.species, "EEVEE")
  Assert.equal(conflicted.form, 1)
  Assert.equal(conflicted.condition.currentHp, 999)
  Assert.equal(conflicted.met.level, 99)
  assertProjectionMatches(conflicted, context, draft:projection())
  local invalid, invalidError = draft:validate()
  Assert.isNil(invalid)
  Assert.notNil(invalidError, "a semantic conflict must keep the draft unappliable")

  Assert.isTrue(draft:setScalar("ability", "ADAPTABILITY"))
  local invalidHp, invalidHpError = draft:validate()
  Assert.isNil(invalidHp)
  Assert.notNil(invalidHpError, "excess current HP must continue to block application")
  Assert.isTrue(draft:setScalar("currentHp", 1))
  -- Correct only the actual conflicts. Historical met level remains raw while
  -- projection continues to derive the current level from experience.
  local historicalMetLevel = draft:record().met.level
  local corrected = draft:record()
  assertProjectionMatches(corrected, context, draft:projection())
  local valid, validError = draft:validate()
  Assert.isNil(validError)
  Assert.deepEqual(valid, Mon.validate(corrected, context))
  Assert.notNil(NativeLegality.project(valid, context))
  Assert.equal(valid.met.level, historicalMetLevel)
  Assert.equal(valid.met.level, 99)
  Assert.equal(draft:projection().level, Experience.level(catalog:growthCurve("medium_fast"), 130))
  Assert.isTrue(valid.met.level ~= draft:projection().level)
  Assert.equal(valid.personality, 0xFFFFFFFF)
  Assert.equal(valid.experience, 130)
  Assert.equal(valid.species, "EEVEE")
  Assert.equal(valid.form, 1)
  Assert.equal(valid.ability, "ADAPTABILITY")
  Assert.equal(valid.origin.trainerId, 0xFFFFFFFF)
  for _, field in ipairs({ "markings", "contest", "ribbons", "egg", "capsule", "mail" }) do
    Assert.deepEqual(valid[field], original[field], "raw editing preserves " .. field)
  end
  Assert.isNil(valid.level, "derived values never become persisted fields")
  Assert.deepEqual(original, Mon.validate(original, context), "editing a draft never mutates its source record")
end

function T.nature_gender_and_trainer_identity_previews_follow_production_owners()
  local catalog, context, original = fixtureMon()
  local Personality = require("libs.mons.src.gen4.Personality")
  local draft = draftFor(original, context)

  for nature = 0, 24 do
    Assert.isTrue(draft:setScalar("personality", nature))
    Assert.equal(draft:projection().nature, Personality.nature(nature))
  end

  -- The compact shared catalog fixture has a real genderless species but no
  -- single-sex entry, so exercise both fixed ratios through the real catalog
  -- constructor with otherwise unchanged fixture species data.
  local shedinja = draftFor(validMon(catalog, "SHEDINJA", 5), context)
  Assert.equal(shedinja:projection().gender, "genderless")

  local MonCatalog = require("libs.mons.src.MonCatalog")
  for _, case in ipairs({ { ratio = 0, gender = "male" }, { ratio = 254, gender = "female" } }) do
    local root = copy(CatalogFixture.buildAssetRoot())
    root.species.EEVEE.genderRatio = case.ratio
    local singleGenderCatalog = MonCatalog.new(root, CatalogFixture.makeItemCatalog())
    local singleGenderContext = CatalogFixture.domainContext(singleGenderCatalog)
    local eevee = validMon(singleGenderCatalog, "EEVEE", 5)
    local singleGenderDraft = draftFor(eevee, singleGenderContext)
    Assert.equal(singleGenderDraft:projection().gender, case.gender)
  end

  Assert.isTrue(draft:setScalar("personality", 0))
  Assert.isTrue(draft:setOrigin("trainerId", 0))
  Assert.isTrue(draft:projection().shiny)
  Assert.isTrue(draft:setOrigin("trainerId", 8))
  Assert.isFalse(draft:projection().shiny)
end

function T.experience_curve_boundaries_shedinja_hp_and_ev_total_use_current_rules()
  local catalog, context = CatalogFixture.makeCatalog(), nil
  context = CatalogFixture.domainContext(catalog)
  local Experience = require("libs.mons.src.gen4.Experience")
  local Errors = require("libs.errors.src.Errors")
  local draft = draftFor(validMon(catalog, "CHIKORITA", 9), context)

  for _, speciesKey in ipairs({ "CHIKORITA", "EEVEE" }) do
    Assert.isTrue(draft:setScalar("species", speciesKey))
    local species = catalog:species(speciesKey)
    local curve = catalog:growthCurve(species.growthCurve)
    for _, level in ipairs({ 1, 5, 100 }) do
      local threshold = Experience.expFor(curve, level)
      Assert.isTrue(draft:setScalar("experience", threshold))
      Assert.equal(draft:projection().level, Experience.level(curve, threshold))
      if level > 1 then
        Assert.isTrue(draft:setScalar("experience", threshold - 1))
        Assert.equal(draft:projection().level, Experience.level(curve, threshold - 1))
      end
    end
    Assert.isTrue(draft:setScalar("experience", curve[100] + 1))
    Assert.isNil(draft:projection().level, "experience beyond the catalog level-100 bound has no level preview")
    Assert.isNil(draft:projection().stats, "stats cannot retain a stale level preview")
  end

  local shedinja = draftFor(validMon(catalog, "SHEDINJA", 5), context)
  Assert.equal(shedinja:projection().stats.hp, 1)
  local legalShedinja, shedinjaError = shedinja:validate()
  Assert.isNil(shedinjaError)
  Assert.notNil(legalShedinja)

  local evDraft = draftFor(validMon(catalog, "EEVEE", 5), context)
  for _, stat in ipairs({ "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }) do
    Assert.isTrue(evDraft:setEV(stat, 0))
  end
  Assert.isTrue(evDraft:setEV("hp", 200))
  Assert.isTrue(evDraft:setEV("attack", 200))
  Assert.isTrue(evDraft:setEV("defense", 110))
  Assert.notNil(evDraft:projection().stats, "the 510 EV boundary has a valid stat preview")
  local legalBoundary, boundaryError = evDraft:validate()
  Assert.isNil(boundaryError)
  Assert.notNil(legalBoundary)

  Assert.isTrue(evDraft:setEV("defense", 111))
  Assert.isNil(evDraft:projection().stats, "an invalid EV total has no current stat preview")
  local invalidEv, invalidEvError = evDraft:validate()
  Assert.isNil(invalidEv)
  Assert.isTrue(Errors.is(invalidEvError))
  Assert.equal(invalidEvError.code, "MON_RECORD_INVALID", "Mon.validate owns the EV-total record contract")
end

function T.primitive_date_limits_and_move_validation_remain_owned_by_the_catalog()
  local catalog, context, original = fixtureMon()
  local draft = draftFor(original, context)

  local priorRecord = copy(draft:record())
  for _, field in ipairs({
    { "year", 1999 },
    { "year", 2256 },
    { "month", 0 },
    { "month", 13 },
    { "day", 0 },
    { "day", 32 },
    { "location", 65536 },
    { "terrain", 256 },
    { "level", 0 },
    { "level", 101 },
  }) do
    Assert.isFalse(draft:setMet(field[1], field[2]), "out-of-range met value should not enter the raw draft")
  end
  Assert.isFalse(draft:setOrigin("trainerId", 4294967296))
  Assert.isFalse(draft:setOrigin("trainerGender", 2))
  Assert.isFalse(draft:setIV("hp", 32))
  Assert.isFalse(draft:setEV("hp", 256))
  Assert.isFalse(draft:setScalar("level", 10), "derived level has no setter")
  Assert.isFalse(draft:setScalar("nature", 1), "derived nature has no setter")

  Assert.deepEqual(draft:record(), priorRecord, "rejected primitive values leave the candidate unchanged")

  local initial = draft:record()
  local first = initial.moves[1]
  Assert.isTrue(draft:setMove(0, "move", "HARDEN"))
  local replaced = draft:record().moves[1]
  Assert.equal(replaced.move, "HARDEN")
  Assert.equal(replaced.pp, first.pp, "changing a move key preserves current PP")
  Assert.equal(replaced.ppUps, first.ppUps, "changing a move key preserves PP Ups")

  local addDraft = draftFor(initial, context)
  local unusedMove
  for _, key in ipairs({ "HARDEN", "TAIL_WHIP", "CUT", "TOXIC" }) do
    local used = false
    for _, move in ipairs(initial.moves) do
      if move.move == key then
        used = true
      end
    end
    if not used then
      unusedMove = key
      break
    end
  end
  Assert.notNil(unusedMove, "fixture has an unused catalog move for explicit Add")
  Assert.isTrue(addDraft:removeMove(#initial.moves - 1))
  local reducedMoves = addDraft:record().moves
  Assert.isTrue(addDraft:addMove(unusedMove))
  local added = addDraft:record().moves[#initial.moves]
  Assert.equal(added.move, unusedMove)
  Assert.equal(added.pp, catalog:move(unusedMove).basePp)
  Assert.equal(added.ppUps, 0)
  Assert.isTrue(addDraft:removeMove(#initial.moves - 1))
  Assert.deepEqual(addDraft:record().moves, reducedMoves, "remove compacts the dense move list")

  local duplicateDraft = draftFor(initial, context)
  Assert.isTrue(duplicateDraft:removeMove(#initial.moves - 1))
  Assert.isTrue(duplicateDraft:addMove(first.move))
  local duplicateRecord = duplicateDraft:record()
  Assert.equal(duplicateRecord.moves[#duplicateRecord.moves].move, first.move)
  local invalidDuplicate, duplicateError = duplicateDraft:validate()
  Assert.isNil(invalidDuplicate)
  Assert.notNil(duplicateError, "duplicate move conflicts are shown without automatic removal")

  local ppDraft = draftFor(initial, context)
  local moveDefinition = catalog:move(first.move)
  local maxPp = moveDefinition.basePp + 3 * math.floor(moveDefinition.basePp / 5)
  Assert.isTrue(ppDraft:setMove(0, "pp", maxPp + 1))
  Assert.isFalse(ppDraft:setMove(0, "ppUps", 4), "PP-Up count uses its own native field range")
  local invalidPp, ppError = ppDraft:validate()
  Assert.isNil(invalidPp)
  Assert.notNil(ppError, "PP over the catalog maximum remains a validation conflict")
end

return { tests = T }
