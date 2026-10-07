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

  Assert.isFalse(evDraft:setEV("defense", 111), "an over-cap total never enters the draft")
  Assert.equal(evDraft:record().evs.defense, 110, "a rejected effort edit leaves the candidate unchanged")
  local validAfterReject, rejectError = evDraft:validate()
  Assert.isNil(rejectError)
  Assert.notNil(validAfterReject)
end

function T.level_edit_writes_threshold_experience_and_preserves_health_coherence()
  local catalog, context = CatalogFixture.makeCatalog(), nil
  context = CatalogFixture.domainContext(catalog)
  local Experience = require("libs.mons.src.gen4.Experience")
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local draft = draftFor(validMon(catalog, "CHIKORITA", 9), context)
  local curve = catalog:growthCurve("medium_slow")
  local maxHp = assert(draft:projection().stats).hp

  Assert.isFalse(draft:setLevel(0), "level below one never enters the draft")
  Assert.isFalse(draft:setLevel(101), "level above one hundred never enters the draft")
  Assert.isTrue(draft:setScalar("currentHp", maxHp - 5))
  Assert.isTrue(draft:setLevel(10))
  Assert.equal(draft:record().experience, Experience.expFor(curve, 10))
  Assert.equal(draft:projection().level, 10)
  local newMaxHp = assert(draft:projection().stats).hp
  Assert.equal(
    draft:record().condition.currentHp,
    HgssMonService.adjustHpForMaxChange(maxHp, newMaxHp, maxHp - 5),
    "a damaged member keeps its damage across the new maximum"
  )
  Assert.equal(draft:record().met.level, 10, "met level tracks the edited level")
  local valid, validError = draft:validate()
  Assert.isNil(validError)
  Assert.notNil(valid)

  local fainted = draftFor(validMon(catalog, "CHIKORITA", 9), context)
  Assert.isTrue(fainted:setScalar("currentHp", 0))
  local faintedMax = assert(fainted:projection().stats).hp
  Assert.isTrue(fainted:setLevel(10))
  Assert.equal(fainted:record().condition.currentHp, 0, "a fainted member stays fainted")
  Assert.isTrue(faintedMax >= 1, "the fixture maximum is usable")
end

function T.species_edit_preserves_numeric_experience_and_repairs_form_and_ability()
  local catalog, context = CatalogFixture.makeCatalog(), nil
  context = CatalogFixture.domainContext(catalog)
  local Experience = require("libs.mons.src.gen4.Experience")
  local Personality = require("libs.mons.src.gen4.Personality")
  local draft = draftFor(validMon(catalog, "CHIKORITA", 9), context)
  local storedExp = draft:record().experience

  Assert.isFalse(draft:setSpecies("MISSINGNO"), "unknown species never enter the draft")
  local before = copy(draft:record())
  Assert.deepEqual(draft:record(), before, "a rejected species leaves the candidate unchanged")
  Assert.isTrue(draft:setSpecies("CHIKORITA"))
  Assert.equal(draft:record().ability, "OVERGROW", "a still-permitted ability is kept")
  Assert.isFalse(draft:isDirty(), "a no-op species edit stages nothing")
  Assert.isTrue(draft:setSpecies("EEVEE"))
  Assert.equal(draft:record().experience, storedExp, "numeric experience survives the species change")
  Assert.equal(
    draft:projection().level,
    Experience.level(catalog:growthCurve("medium_fast"), storedExp),
    "the derived level follows the new growth curve"
  )
  Assert.equal(draft:record().form, 0, "a valid old form is kept when the new species defines it")
  local eeveeForm = catalog:form("EEVEE", 0)
  local expectedAbility = eeveeForm.abilities[Personality.abilitySlot(#eeveeForm.abilities, draft:record().personality)]
  Assert.equal(draft:record().ability, expectedAbility, "an unpermitted ability is repaired by personality slot")
  local validKept, keptError = draft:validate()
  Assert.isNil(keptError)
  Assert.notNil(validKept)

  -- OVERGROW is not permitted by EEVEE form 1, so moving there repairs the
  -- ability through the personality slot instead of leaving a conflict.
  Assert.isTrue(draft:setForm(1))
  Assert.equal(draft:record().form, 1)
  local repaired = catalog:form("EEVEE", 1).abilities[Personality.abilitySlot(1, draft:record().personality)]
  Assert.equal(draft:record().ability, repaired)
  local validForm, formError = draft:validate()
  Assert.isNil(formError)
  Assert.notNil(validForm)

  -- Returning to single-form CHIKORITA repairs the now-invalid form id.
  Assert.isTrue(draft:setSpecies("CHIKORITA"))
  Assert.equal(draft:record().experience, storedExp, "numeric experience still survives")
  Assert.equal(draft:record().form, 0)
  local validBack, backError = draft:validate()
  Assert.isNil(backError)
  Assert.notNil(validBack)

  Assert.isFalse(draft:setForm(7), "an undefined form never enters the draft")
  Assert.equal(draft:record().form, 0, "a rejected form leaves the candidate unchanged")
end

function T.effort_edit_rejects_total_above_the_cap_before_mutation()
  local catalog, context = CatalogFixture.makeCatalog(), nil
  context = CatalogFixture.domainContext(catalog)
  local draft = draftFor(validMon(catalog, "EEVEE", 5), context)
  for _, stat in ipairs({ "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }) do
    Assert.isTrue(draft:setEV(stat, 0))
  end
  Assert.isTrue(draft:setEV("hp", 200))
  Assert.isTrue(draft:setEV("attack", 200))
  Assert.isTrue(draft:setEV("defense", 110))
  Assert.isFalse(draft:setEV("defense", 111), "an over-cap total never enters the draft")
  Assert.equal(draft:record().evs.defense, 110, "a rejected effort edit leaves the candidate unchanged")
  local valid, validError = draft:validate()
  Assert.isNil(validError)
  Assert.notNil(valid)
end

function T.move_replacement_resets_allowance_and_pp_up_clamps_current_pp()
  local catalog, context = CatalogFixture.makeCatalog(), nil
  context = CatalogFixture.domainContext(catalog)
  local Draft = require("app.src.saveeditor.SaveEditorMonDraft")
  local draft = draftFor(validMon(catalog, "EEVEE", 5), context)
  local first = copy(draft:record().moves[1])
  local boostedMax = Draft.maxMovePp(catalog:move(first.move), 3)
  Assert.isTrue(draft:setMove(0, "ppUps", 3))
  Assert.isTrue(draft:setMove(0, "pp", boostedMax))
  Assert.isFalse(
    draft:setMove(0, "pp", boostedMax + 1),
    "power points above the current maximum never enter the draft"
  )
  Assert.equal(draft:record().moves[1].pp, boostedMax, "a rejected PP edit leaves the slot unchanged")
  Assert.isTrue(draft:setMove(0, "ppUps", 0))
  local clampedMax = Draft.maxMovePp(catalog:move(first.move), 0)
  Assert.equal(
    draft:record().moves[1].pp,
    math.min(boostedMax, clampedMax),
    "lowering PP Ups clamps current PP to the new maximum"
  )

  local replacement = catalog:move("HARDEN")
  Assert.isTrue(draft:setMove(0, "move", "HARDEN"))
  Assert.equal(draft:record().moves[1].move, "HARDEN")
  Assert.equal(draft:record().moves[1].ppUps, 0, "replacing a move resets PP Ups")
  Assert.equal(draft:record().moves[1].pp, replacement.basePp, "replacing a move restores base PP")
  Assert.isFalse(draft:setMove(0, "move", "MISSINGNO"), "unknown moves never enter the draft")
  Assert.equal(draft:record().moves[1].move, "HARDEN", "a rejected move leaves the slot unchanged")
  local valid, validError = draft:validate()
  Assert.isNil(validError)
  Assert.notNil(valid)
end

function T.direct_experience_edit_refreshes_current_health()
  local catalog, context = CatalogFixture.makeCatalog(), nil
  context = CatalogFixture.domainContext(catalog)
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local draft = draftFor(validMon(catalog, "CHIKORITA", 9), context)
  local maxHp = assert(draft:projection().stats).hp
  Assert.isTrue(draft:setScalar("currentHp", maxHp - 3))
  local curve = catalog:growthCurve("medium_slow")
  local target = curve[12]
  Assert.isTrue(draft:setExperience(target))
  Assert.equal(draft:record().experience, target)
  Assert.equal(draft:projection().level, 12)
  local newMaxHp = assert(draft:projection().stats).hp
  Assert.equal(
    draft:record().condition.currentHp,
    HgssMonService.adjustHpForMaxChange(maxHp, newMaxHp, maxHp - 3)
  )
  local valid, validError = draft:validate()
  Assert.isNil(validError)
  Assert.notNil(valid)
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
  Assert.equal(replaced.pp, catalog:move("HARDEN").basePp, "replacing a move restores base PP")
  Assert.equal(replaced.ppUps, 0, "replacing a move resets PP Ups")

  local addBase = validMon(catalog, "EEVEE", 5)
  Assert.isTrue(#addBase.moves < 4, "the young fixture member keeps an empty slot for explicit Add")
  local addDraft = draftFor(addBase, context)
  local unusedMove
  for _, key in ipairs({ "HARDEN", "TAIL_WHIP", "CUT", "TOXIC" }) do
    local used = false
    for _, move in ipairs(addBase.moves) do
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
  Assert.isTrue(addDraft:addMove(unusedMove))
  local added = addDraft:record().moves[#addBase.moves + 1]
  Assert.equal(added.move, unusedMove)
  Assert.equal(added.pp, catalog:move(unusedMove).basePp)
  Assert.equal(added.ppUps, 0)

  local duplicateDraft = draftFor(addBase, context)
  Assert.isTrue(duplicateDraft:addMove(addBase.moves[1].move))
  local duplicateRecord = duplicateDraft:record()
  Assert.equal(duplicateRecord.moves[#duplicateRecord.moves].move, addBase.moves[1].move)
  local invalidDuplicate, duplicateError = duplicateDraft:validate()
  Assert.isNil(invalidDuplicate)
  Assert.notNil(duplicateError, "duplicate move conflicts are shown without automatic removal")

  local ppDraft = draftFor(addBase, context)
  local moveDefinition = catalog:move(addBase.moves[1].move)
  local Draft = require("app.src.saveeditor.SaveEditorMonDraft")
  local currentMax = Draft.maxMovePp(moveDefinition, addBase.moves[1].ppUps)
  Assert.isFalse(ppDraft:setMove(0, "pp", currentMax + 1), "PP above the current maximum never enters the draft")
  Assert.isFalse(ppDraft:setMove(0, "ppUps", 4), "PP-Up count uses its own native field range")
  Assert.isTrue(ppDraft:setMove(0, "ppUps", 3))
  local raisedMax = Draft.maxMovePp(moveDefinition, 3)
  Assert.isTrue(ppDraft:setMove(0, "pp", raisedMax), "PP at the raised maximum is accepted")
  local invalidPp, ppError = ppDraft:validate()
  Assert.isNil(ppError)
  Assert.notNil(invalidPp)
end

return { tests = T }
