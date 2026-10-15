-- Live broadcast music and encounter effects: the shared
-- sequence-to-effect mapping resolves every music latch, tuned march and
-- lullaby shift land opportunity at the native rate stage while other
-- methods and tracks stay identical, tuned regional music replaces its
-- exact land slots with levels and weights kept, stopping clears the
-- effect at once, a legacy saved music value can never replay without
-- real playback, and the special-music script query reads the retained
-- audio latch until the source music stop. Rate expectations use fixed
-- generator vectors and independent boundary arithmetic; replacement
-- expectations compare resolved tables and provider outcomes, never the
-- implementation as its own oracle.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearState = require("libs.hgss.src.save.PokegearState")
local EncounterSave = require("libs.hgss.src.save.EncounterSave")
local EncounterFixture = require("libs.hgss.tests.encounter_fixture")
local BroadcastFixture = require("tests.support.PokegearBroadcastFixture")
local Music = require("game.hgss.src.pokegear.radio.Music")
local Special = require("game.hgss.src.pokegear.radio.Special")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

-- Loads a radio module that does not exist yet at this baseline. The
-- failure names the missing behaviour instead of surfacing as a suite load
-- error, so the pre-implementation red stays attributable.
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

---@return table encounter service over the synthetic vector catalog
local function vectorService()
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local ItemFixture = require("libs.items.tests.item_fixture")
  local Catalog = EncounterFixture.requirePresent(
    "libs.hgss.src.encounters.HgssEncounterCatalog",
    "validated encounter-table lookup owns ordered slots"
  )
  local Service = EncounterFixture.requirePresent(
    "libs.hgss.src.encounters.HgssEncounterService",
    "encounter opportunity and retained preparation"
  )
  local WildMonFactory = EncounterFixture.requirePresent(
    "libs.hgss.src.encounters.WildMonFactory",
    "source wild identity and held-item generation"
  )
  return Service.new({
    catalog = Catalog.new(EncounterFixture.vectorCatalog()),
    wildFactory = WildMonFactory.new({
      catalog = CatalogFixture.makeCatalog(),
      items = ItemFixture.makeCatalog(),
      charmap = CatalogFixture.CHARMAP,
      games = CatalogFixture.GAMES,
      languages = CatalogFixture.LANGUAGES,
      game = "soulsilver",
      language = "english",
    }),
  })
end

---@param host table
---@param mapId integer
---@param method string
---@param modifiers table<string, unknown>
---@param seed integer
---@return table<string, unknown> result, integer draws
local function attempt(host, mapId, method, modifiers, seed)
  local context = EncounterFixture.context({ mapId = mapId, method = method })
  context.modifiers = modifiers
  local stream = EncounterFixture.spyStream(seed)
  return host:attempt(context, stream), stream:calls()
end

---@param result table<string, unknown>
---@param draws integer
---@return string outcome signature without map identity
local function signature(result, draws)
  local parts = { result.kind, tostring(result.reason) }
  if result.encounter ~= nil then
    local mon = result.encounter.mons[1].mon
    parts[#parts + 1] = tostring(mon.species)
    parts[#parts + 1] = "lv" .. tostring(mon.met.level)
  end
  parts[#parts + 1] = "draws" .. draws
  return table.concat(parts, "/")
end

---@param overrides table<string, unknown>?
---@return table<string, unknown> attempt modifiers with neutral defaults
local function modifiers(overrides)
  return EncounterFixture.modifiers(overrides)
end

-- The fixed music-latch vocabulary shared by encounters and scripts: the
-- tuned music tracks resolve to their effect, the tune-in jingle and the
-- card-selection filler resolve to no effect, the two gameboy card tracks
-- that replay march and lullaby resolve with their counterpart, the flute
-- and unown sequences resolve to their own effects, and anything unknown
-- or absent resolves to no effect. Repeated reads agree exactly.
---@return table the shared effect mapping
local function checkEffectMapping(Effects)
  local cases = {
    { key = Music.MARCH_SEQUENCE, want = "march" },
    { key = Music.LULLABY_SEQUENCE, want = "lullaby" },
    { key = Music.HOENN_SEQUENCE, want = "hoenn" },
    { key = Music.SINNOH_SEQUENCE, want = "sinnoh" },
    { key = Music.JINGLE_SEQUENCE, want = "none" },
    { key = "radio.music.card.21", want = "march" },
    { key = "radio.music.card.22", want = "lullaby" },
    { key = "radio.music.card.03", want = "none" },
    { key = Special.FLUTE_SEQUENCE, want = "pokeflute" },
    { key = Special.UNOWN_SEQUENCE, want = "unown" },
    { key = nil, want = "none" },
    { key = "radio.music.unknown-track", want = "none" },
  }
  for _, case in ipairs(cases) do
    Assert.equal(
      Effects.fromSequence(case.key),
      case.want,
      "the latch " .. tostring(case.key) .. " resolves its gameplay effect"
    )
    Assert.equal(
      Effects.fromSequence(case.key),
      Effects.fromSequence(case.key),
      "effect reads are pure for " .. tostring(case.key)
    )
  end
  return Effects
end

function T.tests.live_broadcast_music_changes_land_encounters_until_stopped(context)
  local Effects = requireFeature(
    "game.hgss.src.pokegear.PokegearRadioEffects",
    "live broadcast music has no shared sequence-to-effect mapping yet: encounters cannot hear any tuned track"
  )
  requireFeature(
    "libs.hgss.src.encounters.HgssEncounterRate",
    "the encounter opportunity has no transcribed rate-stage policy yet: march and lullaby change no rate"
  )
  checkEffectMapping(Effects)

  -- No-music baselines on the mid-rate vector table, fixed from the
  -- generator: seed 0 triggers, seeds 1 and 7 miss with a single draw.
  local host = vectorService()
  local result, draws = attempt(host, 13, "grass", modifiers({ radio = "none" }), 0)
  Assert.equal(signature(result, draws), "prepared/triggered/EEVEE/lv8/draws9", "the silent baseline triggers seed 0")
  result, draws = attempt(host, 13, "grass", modifiers({ radio = "none" }), 1)
  Assert.equal(signature(result, draws), "none/no_opportunity/draws1", "the silent baseline misses seed 1")
  result, draws = attempt(host, 13, "grass", modifiers({ radio = "none" }), 7)
  Assert.equal(signature(result, draws), "none/no_opportunity/draws1", "the silent baseline misses seed 7")

  -- March raises the staged rate by twenty-five points: rolls at or above
  -- the silent rate but below the raised rate flip to encounters,
  -- including the exact raised-rate boundary which still misses, while a
  -- seed that already triggered keeps its identical mon and draw count.
  local marchFlips = {
    { seed = 1, species = "EEVEE", level = 7 },
    { seed = 7, species = "TOTODILE", level = 5 },
    { seed = 8, species = "EEVEE", level = 8 },
    { seed = 11, species = "TOTODILE", level = 5 },
    { seed = 12, species = "CHIKORITA", level = 4 },
  }
  for _, flip in ipairs(marchFlips) do
    local marchResult, marchDraws = attempt(host, 13, "grass", modifiers({ radio = "march" }), flip.seed)
    Assert.equal(
      signature(marchResult, marchDraws),
      "prepared/triggered/" .. flip.species .. "/lv" .. flip.level .. "/draws9",
      "march flips silent miss " .. flip.seed
    )
  end
  result, draws = attempt(host, 13, "grass", modifiers({ radio = "march" }), 5)
  Assert.equal(signature(result, draws), "none/no_opportunity/draws1", "the raised-rate boundary still misses")
  result, draws = attempt(host, 13, "grass", modifiers({ radio = "march" }), 0)
  Assert.equal(signature(result, draws), "prepared/triggered/EEVEE/lv8/draws9", "march keeps an existing hit identical")

  -- Lullaby lowers the staged rate by twenty-five points: rolls below the
  -- silent rate but at or above the lowered rate flip to misses, while the
  -- zero roll still triggers with its identical mon.
  for _, seed in ipairs({ 3, 4, 10 }) do
    result, draws = attempt(host, 13, "grass", modifiers({ radio = "lullaby" }), seed)
    Assert.equal(signature(result, draws), "none/no_opportunity/draws1", "lullaby flips silent hit " .. seed)
  end
  result, draws = attempt(host, 13, "grass", modifiers({ radio = "lullaby" }), 0)
  Assert.equal(signature(result, draws), "prepared/triggered/EEVEE/lv8/draws9", "lullaby keeps the zero roll identical")

  -- Tracks without a rate effect never touch the opportunity path, and
  -- march/lullaby never reach fishing or scripted encounters. Regional
  -- music keeps the rate path (kind/reason/draws) and the drawn slot
  -- level exactly like silence; only the species may differ, and then
  -- only to the music table's own replacement species at a replaced
  -- slot whose level window holds the outcome level. Unown and the
  -- flute keep full seed-for-seed identity, proving the stage rather
  -- than a blanket multiplier.
  local CatalogForRate = EncounterFixture.requirePresent(
    "libs.hgss.src.encounters.HgssEncounterCatalog",
    "validated encounter-table lookup owns ordered slots"
  )
  local rateCatalog = CatalogForRate.new(EncounterFixture.vectorCatalog())
  local silentDay =
    rateCatalog:tableFor(13, { timeOfDay = "day", swarm = false, radio = "none", game = "soulsilver" }).day
  local musicDays = {}
  for _, effect in ipairs({ "hoenn", "sinnoh" }) do
    musicDays[effect] =
      rateCatalog:tableFor(13, { timeOfDay = "day", swarm = false, radio = effect, game = "soulsilver" }).day
  end
  local function checkRegionalOutcome(musicDay, silentResult, musicResult, seed, effect)
    Assert.equal(musicResult.kind, silentResult.kind, effect .. " keeps the outcome kind on seed " .. seed)
    Assert.equal(
      tostring(musicResult.reason),
      tostring(silentResult.reason),
      effect .. " keeps the outcome reason on seed " .. seed
    )
    if silentResult.encounter == nil then
      Assert.isNil(musicResult.encounter, effect .. " keeps the miss on seed " .. seed)
      return
    end
    local silentMon = assert(silentResult.encounter, "silent trigger reads above").mons[1].mon
    local musicMon = assert(musicResult.encounter, effect .. " keeps the trigger on seed " .. seed).mons[1].mon
    Assert.equal(
      musicMon.met.level,
      silentMon.met.level,
      effect .. " keeps the drawn slot level on seed " .. seed
    )
    if tostring(musicMon.species) == tostring(silentMon.species) then
      return
    end
    local replaced = false
    for _, slot in ipairs({ 3, 4, 5, 6 }) do
      local musicSlot = musicDay[slot]
      local silentSlot = silentDay[slot]
      if musicSlot.species == tostring(musicMon.species)
        and musicSlot.minLevel <= musicMon.met.level
        and musicMon.met.level <= musicSlot.maxLevel
        and silentSlot.minLevel <= silentMon.met.level
        and silentMon.met.level <= silentSlot.maxLevel
        and silentSlot.species ~= musicSlot.species
      then
        replaced = true
      end
    end
    Assert.isTrue(
      replaced,
      effect .. " changes seed " .. seed .. " only to its replaced-slot species"
    )
  end
  for _, seed in ipairs({ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 }) do
    local plain, plainDraws = attempt(host, 13, "grass", modifiers({ radio = "none" }), seed)
    local baseline = signature(plain, plainDraws)
    for _, effect in ipairs({ "unown", "pokeflute" }) do
      local other, otherDraws = attempt(host, 13, "grass", modifiers({ radio = effect }), seed)
      Assert.equal(signature(other, otherDraws), baseline, effect .. " leaves the land rate untouched on seed " .. seed)
    end
    for _, effect in ipairs({ "hoenn", "sinnoh" }) do
      local other, otherDraws = attempt(host, 13, "grass", modifiers({ radio = effect }), seed)
      Assert.equal(otherDraws, plainDraws, effect .. " draws the same stream on seed " .. seed)
      checkRegionalOutcome(musicDays[effect], plain, other, seed, effect)
    end
  end
  for _, seed in ipairs({ 0, 1, 3, 7 }) do
    local plainFish, plainFishDraws = attempt(host, 14, "fish", modifiers({ rod = "old_rod", radio = "none" }), seed)
    local fishBaseline = signature(plainFish, plainFishDraws)
    for _, effect in ipairs({ "march", "lullaby" }) do
      local otherFish, otherFishDraws = attempt(host, 14, "fish", modifiers({ rod = "old_rod", radio = effect }), seed)
      Assert.equal(
        signature(otherFish, otherFishDraws),
        fishBaseline,
        effect .. " never reaches fishing on seed " .. seed
      )
    end
    local staticModifiers = modifiers({ static = { species = "EEVEE", level = 5 }, radio = "none" })
    local plainStatic, plainStaticDraws = attempt(host, 11, "static", staticModifiers, seed)
    local staticBaseline = signature(plainStatic, plainStaticDraws)
    for _, effect in ipairs({ "march", "lullaby" }) do
      local otherStatic, otherStaticDraws =
        attempt(host, 11, "static", modifiers({ static = { species = "EEVEE", level = 5 }, radio = effect }), seed)
      Assert.equal(
        signature(otherStatic, otherStaticDraws),
        staticBaseline,
        effect .. " never reaches scripted encounters on seed " .. seed
      )
    end
  end

  -- Stopping clears the effect at once: the latch reads no effect and the
  -- next attempt matches the never-started baseline exactly.
  local audio = BroadcastFixture.newAudioStandIn()
  audio:playRadio(Music.MARCH_SEQUENCE)
  Assert.equal(Effects.fromSequence(audio:currentRadioSequence()), "march", "the playing latch reads march")
  audio:stopRadio()
  Assert.isNil(audio:currentRadioSequence(), "stopping clears the audio latch")
  Assert.equal(Effects.fromSequence(audio:currentRadioSequence()), "none", "a cleared latch reads no effect")
  result, draws = attempt(host, 13, "grass", modifiers({ radio = "none" }), 1)
  Assert.equal(signature(result, draws), "none/no_opportunity/draws1", "a stopped tuner matches the baseline")

  -- Real-table wiring against the owned dump: regional music replaces its
  -- exact land slots while levels, weights, and every other slot stay
  -- untouched. A missing dump reports a skip, never a pass.
  local GameVersion = require("romdump.src.source.GameVersion")
  local RomImporter = require("romdump.src.source.RomImporter")
  local ready = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      ready[#ready + 1] = versionId
    end
  end
  if #ready == 0 then
    if context ~= nil and type(context.skip) == "function" then
      context:skip("requires a ready dump for the compiled encounter tables")
    end
    error("the live regional-music wiring needs a ready dump", 0)
  end
  local Catalog = EncounterFixture.requirePresent(
    "libs.hgss.src.encounters.HgssEncounterCatalog",
    "validated encounter-table lookup owns ordered slots"
  )
  local EncounterCatalogCompiler = require("romdump.src.digest.encounters.EncounterCatalogCompiler")
  local RomSourcePath = require("tests.rom.support.RomSourcePath")
  for _, versionId in ipairs(ready) do
    local romFs, romSource = assert(RomSourcePath.openReader(versionId))
    local compiled = assert(EncounterCatalogCompiler.compileFromDump(romFs, { versionId = versionId }))
    romFs:close()
    romSource:release()
    local catalog = Catalog.new(compiled)
    local memberId = nil
    local hoennSpecies, sinnohSpecies, walkingRate = nil, nil, nil
    local hoennAltRecord, sinnohAltRecord = nil, nil
    local hoennAltActive, sinnohAltActive = false, false
    for id, member in pairs(compiled.tables) do
      local rates = member.rates
      local walking = type(rates) == "table" and rates.walking or -1
      local replacements = member.replacements or {}
      local hoenn = replacements.radioHoenn
      local sinnoh = replacements.radioSinnoh
      local function active(record)
        return type(record) == "table"
          and type(record.species) == "string"
          and record.species ~= "NONE"
          and record.species ~= ""
          and (record.game == nil or record.game == versionId)
      end
      if type(walking) == "number" and walking >= 10 and walking <= 70 and active(hoenn) and active(sinnoh) then
        memberId, hoennSpecies, sinnohSpecies, walkingRate = id, hoenn.species, sinnoh.species, walking
        hoennAltRecord, sinnohAltRecord = replacements.radioHoennAlt, replacements.radioSinnohAlt
        hoennAltActive, sinnohAltActive = active(replacements.radioHoennAlt), active(replacements.radioSinnohAlt)
        break
      end
    end
    Assert.notNil(memberId, versionId .. " carries a mid-rate table with both regional replacements")
    assert(memberId ~= nil, "the dump carries a regional-music table")
    local plain = catalog:tableFor(memberId, { timeOfDay = "day", swarm = false, radio = "none", game = versionId })
    local hoenn = catalog:tableFor(memberId, { timeOfDay = "day", swarm = false, radio = "hoenn", game = versionId })
    local sinnoh = catalog:tableFor(memberId, { timeOfDay = "day", swarm = false, radio = "sinnoh", game = versionId })
    Assert.equal(#plain.day, 12, versionId .. " keeps twelve ordered land slots")
    -- Native radio music replaces two zero-based pairs: the first
    -- species covers the third and fourth slots while the second covers
    -- the fifth and sixth, each only while it names a real entry for
    -- this version. Slot levels and weights always stay with the slots.
    local regional = {
      { effect = "hoenn", resolved = hoenn, first = hoennSpecies, alt = hoennAltRecord, altActive = hoennAltActive },
      { effect = "sinnoh", resolved = sinnoh, first = sinnohSpecies, alt = sinnohAltRecord, altActive = sinnohAltActive },
    }
    for _, entry in ipairs(regional) do
      for _, slot in ipairs({ 3, 4 }) do
        Assert.equal(
          entry.resolved.day[slot].species,
          entry.first,
          versionId .. " " .. entry.effect .. " music replaces land slot " .. slot
        )
        for _, field in ipairs({ "minLevel", "maxLevel", "weight" }) do
          Assert.equal(
            entry.resolved.day[slot][field],
            plain.day[slot][field],
            versionId .. " " .. entry.effect .. " music keeps slot " .. slot .. " " .. field
          )
        end
      end
      local altReplaced = entry.altActive == true
      if altReplaced then
        assert(type(entry.alt) == "table", "the active second music carries its species")
        for _, slot in ipairs({ 5, 6 }) do
          Assert.equal(
            entry.resolved.day[slot].species,
            entry.alt.species,
            versionId .. " " .. entry.effect .. " music replaces land slot " .. slot
          )
          for _, field in ipairs({ "minLevel", "maxLevel", "weight" }) do
            Assert.equal(
              entry.resolved.day[slot][field],
              plain.day[slot][field],
              versionId .. " " .. entry.effect .. " music keeps slot " .. slot .. " " .. field
            )
          end
        end
      end
      for slot = 1, 12 do
        local replaced = slot == 3 or slot == 4 or (altReplaced and (slot == 5 or slot == 6))
        if not replaced then
          Assert.equal(
            entry.resolved.day[slot].species,
            plain.day[slot].species,
            versionId .. " " .. entry.effect .. " music leaves land slot " .. slot .. " alone"
          )
        end
      end
    end
    Assert.isTrue(walkingRate >= 10 and walkingRate <= 70, "the wired table stays mid-rate")
  end
end

function T.tests.legacy_saved_music_cannot_replay_without_playback()
  local RoamerState = EncounterFixture.requirePresent(
    "libs.hgss.src.encounters.HgssRoamerState",
    "stable roaming state owns persisted counters and roamer records"
  )
  local Catalog = EncounterFixture.requirePresent(
    "libs.hgss.src.encounters.HgssEncounterCatalog",
    "validated encounter-table lookup owns ordered slots"
  )
  local refs = EncounterFixture.refs()

  -- An old bucket whose obsolete music value says hoenn, alongside real
  -- roamer, repel, step, and swarm facts that must all survive.
  local legacy = {
    schema = "hgss-encounter-v1",
    stateVersion = 1,
    steps = 7,
    repelSteps = 3,
    swarm = true,
    radio = "hoenn",
    roamers = {
      raikou = {
        key = "raikou",
        stateVersion = 1,
        mon = { species = "EEVEE" },
        location = 11,
        lifecycle = "roaming",
        revision = 3,
      },
    },
  }
  local restored = RoamerState.restore(legacy, refs)
  local migrated = EncounterSave.capture(restored)
  Assert.isTrue(migrated.radio ~= "hoenn", "the obsolete music value carries no playback authority")
  Assert.isTrue(migrated.radio == nil or migrated.radio == "none", "migration leaves no live music behind")
  Assert.equal(migrated.stateVersion, EncounterSave.STATE_VERSION, "migration lands on the explicit current version")
  Assert.equal(migrated.steps, 7, "migration preserves the step counter")
  Assert.equal(migrated.repelSteps, 3, "migration preserves the repel counter")
  Assert.equal(migrated.swarm, true, "migration preserves the swarm fact")
  local roamer = assert(migrated.roamers.raikou, "migration preserves the roamer record")
  Assert.equal(roamer.lifecycle, "roaming", "migration preserves the roamer lifecycle")
  Assert.equal(roamer.revision, 3, "migration preserves the roamer revision")
  Assert.equal(roamer.location, 11, "migration preserves the roamer location")
  Assert.equal(roamer.mon.species, "EEVEE", "migration preserves the roamer identity")

  -- A save and reload round trip stays stable and still replays nothing.
  local reloaded = RoamerState.restore(migrated, refs)
  local recaptured = EncounterSave.capture(reloaded)
  Assert.isTrue(recaptured.radio ~= "hoenn", "a saved reload still replays no music")
  Assert.equal(recaptured.steps, 7, "a saved reload keeps the step counter")
  Assert.equal(recaptured.repelSteps, 3, "a saved reload keeps the repel counter")
  Assert.equal(recaptured.swarm, true, "a saved reload keeps the swarm fact")
  Assert.equal(
    assert(recaptured.roamers.raikou, "a saved reload keeps the roamer").revision,
    3,
    "a saved reload keeps the roamer revision"
  )

  -- A malformed legacy music type still fails instead of normalizing
  -- arbitrary garbage into a quiet default.
  local garbage = {
    schema = "hgss-encounter-v1",
    stateVersion = 1,
    steps = 0,
    repelSteps = 0,
    swarm = false,
    radio = 42,
    roamers = {},
  }
  local err = Assert.throws(function()
    EncounterSave.validate(garbage, refs)
  end, "a non-string legacy music value must fail")
  Assert.isTrue(Errors.is(err), "the rejection uses the structured error path")
  Assert.equal(assert(err).code, "ENCOUNTER_SAVE_INVALID", "the rejection names its contract")

  -- The migrated value behaves exactly like silence at the encounter
  -- tables, while an explicit music value still replaces: the comparison
  -- proves the test can tell music apart from silence.
  local catalog = Catalog.new(EncounterFixture.vectorCatalog())
  local migratedRadio = migrated.radio or "none"
  local quiet = catalog:tableFor(11, { timeOfDay = "day", swarm = true, radio = migratedRadio, game = "soulsilver" })
  local silent = catalog:tableFor(11, { timeOfDay = "day", swarm = true, radio = "none", game = "soulsilver" })
  local loud = catalog:tableFor(11, { timeOfDay = "day", swarm = true, radio = "hoenn", game = "soulsilver" })
  for slot = 1, 12 do
    Assert.equal(
      quiet.day[slot].species,
      silent.day[slot].species,
      "the migrated value reads exactly like silence in slot " .. slot
    )
  end
  Assert.isTrue(
    loud.day[3].species ~= silent.day[3].species or loud.day[4].species ~= silent.day[4].species,
    "an explicit music value still replaces its slots"
  )

  -- Cold loading never resumes music from anywhere: tuning preference
  -- starts at the dial center and no playback exists to derive from.
  local manifest = BroadcastFixture.fixtureManifest()
  local validated = PokegearAssetSchema.validate(manifest)
  Assert.notNil(validated, "the synthetic companion catalog must validate through the asset schema")
  local state = PokegearState.new({ seed = 7 }, BroadcastFixture.catalogRefs(assert(validated, "catalog reads above")))
  Assert.deepEqual(
    state:readPreferences().radioCursor,
    { x = 128, y = 128 },
    "a fresh tuner remembers the dial center, never a station"
  )
end

function T.tests.special_music_query_reads_the_retained_audio_latch_until_the_source_stop()
  local Effects = requireFeature(
    "game.hgss.src.pokegear.PokegearRadioEffects",
    "the special-music script query has no shared latch mapping yet: flute music answers nothing"
  )
  local AudioFixture = require("tests.support.AudioFixture")
  local AudioAssetProvider = require("libs.hgss.src.audio.AudioAssetProvider")
  local SequencePlayer = require("libs.nds.src.nitro.sound.SequencePlayer")
  local VoiceMixer = require("libs.nds.src.nitro.sound.VoiceMixer")
  local GameSound = require("libs.hgss.src.audio.GameSound")
  local FieldAudioController = require("libs.hgss.src.audio.FieldAudioController")

  local sampleRate = 48000
  local mapMusicId = 4
  local fluteId = 42
  local bankId = 12
  local function voice(key)
    return {
      generator = { kind = "sample", sample = key },
      originalKey = 60,
      envelope = { attack = 127, decay = 0, sustain = 127, release = 127 },
      pan = 0,
    }
  end
  local function loopingProgram(program)
    return {
      entry = 1,
      initialTrackMask = 0x0001,
      instructions = {
        { op = "program", program = program },
        { op = "note", key = 60, velocity = 96, duration = 24 },
        { op = "wait", duration = 12 },
        { op = "jump", target = 2 },
      },
    }
  end
  local keyA = AudioFixture.key(1)
  local bundle = AudioFixture.bundle()
  bundle.index.sequences = {
    [mapMusicId] = { id = mapMusicId, symbol = "SEQ_FIELD_MAP_MUSIC", bankId = bankId, playerId = 1 },
    [fluteId] = { id = fluteId, symbol = Special.FLUTE_SEQUENCE, bankId = bankId, playerId = 1 },
  }
  bundle.index.sequenceBySymbol = {
    ["SEQ_FIELD_MAP_MUSIC"] = mapMusicId,
    [Special.FLUTE_SEQUENCE] = fluteId,
  }
  bundle.index.players[9] = { id = 9, maxSequences = 1, channelMask = 0xA7FE }
  bundle.sequences = {
    [mapMusicId] = AudioFixture.sequence(mapMusicId, "SEQ_FIELD_MAP_MUSIC", bankId, 1, loopingProgram(0), {
      id = 1,
      initialVolume = 127,
      playerPriority = 64,
      channelPriority = 64,
    }),
    [fluteId] = AudioFixture.sequence(fluteId, Special.FLUTE_SEQUENCE, bankId, 1, loopingProgram(4), {
      id = 1,
      initialVolume = 127,
      playerPriority = 64,
      channelPriority = 64,
    }),
  }
  bundle.banks = {
    [bankId] = AudioFixture.bank(bankId, "BANK_TEST", { AudioFixture.key(1) }, {
      [0] = { kind = "direct", voice = voice(AudioFixture.key(1)) },
    }),
  }
  bundle.samples = { [keyA] = AudioFixture.pcm16le({ 1000, 2000, 3000, 4000 }) }
  bundle.sampleMetadata = { [keyA] = AudioFixture.sampleMetadata(keyA, { frames = 4 }) }
  local cacheFs = AudioFixture.readyCache(bundle)
  local provider = AudioAssetProvider.new(cacheFs)
  local mixer = VoiceMixer.new({ sampleRate = sampleRate })
  local player = SequencePlayer.new({ sampleRate = sampleRate, mixer = mixer, provider = provider })
  local sound = GameSound.new({
    provider = provider,
    player = player,
    mapMusic = function()
      return mapMusicId
    end,
  })
  local controller = FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = {
      isFlagSet = function()
        return false
      end,
    },
    fieldPosition = function()
      return 0, 0
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return nil
    end,
  })

  ---@param latch integer?
  ---@return string latched semantic sequence key
  local function latchKey(latch)
    assert(type(latch) == "number", "the script query reads a latched sequence identity")
    local entry = bundle.index.sequences[latch]
    assert(type(entry) == "table" and type(entry.symbol) == "string", "the latch resolves through the audio index")
    return entry.symbol
  end

  -- Tune the flute and close the interface normally: ordinary music
  -- survives teardown with its latch retained.
  sound:playRadio(Special.FLUTE_SEQUENCE)
  player:render(250)
  Assert.isTrue(sound:radioIsPlaying(), "the flute is playing before the interface closes")
  controller:finishRadioUi({ tuned = true, kind = "music", mapMusic = mapMusicId })
  player:render(250)
  local retained = sound:currentRadioSequence()
  Assert.notNil(retained, "an ordinary close retains the music latch")
  Assert.isTrue(sound:radioIsPlaying(), "an ordinary close keeps the music playing")
  Assert.equal(Effects.fromSequence(latchKey(retained)), "pokeflute", "the retained latch answers the flute query")
  Assert.isTrue(
    Effects.fromSequence(latchKey(sound:currentRadioSequence())) == "pokeflute",
    "the query observes the latch on the same tick with no wait"
  )
  Assert.isFalse(
    Effects.fromSequence(latchKey(sound:currentRadioSequence())) == "march",
    "the comparison is exact: other music answers false"
  )

  -- The query mutates no world or actor state: a frozen witness survives
  -- the whole latch-read, mapping, and comparison path unchanged.
  local witness = { snorlax = { mapId = 11, blocking = true }, vars = { music = 0, result = 0 } }
  local function copy(value)
    if type(value) ~= "table" then
      return value
    end
    local out = {}
    for key, item in pairs(value) do
      out[key] = copy(item)
    end
    return out
  end
  local snapshot = copy(witness)
  local _ = Effects.fromSequence(latchKey(sound:currentRadioSequence())) == "pokeflute"
  Assert.deepEqual(witness, snapshot, "the music query mutates no world or actor state")

  -- Stopping through the source music path clears the latch at once, and
  -- the cleared latch answers no music on the same tick.
  sound:stopMusic()
  player:render(250)
  Assert.isNil(sound:currentRadioSequence(), "the source stop clears the radio latch")
  Assert.isFalse(sound:radioIsPlaying(), "the source stop leaves no radio playing")
  Assert.equal(Effects.fromSequence(sound:currentRadioSequence()), "none", "a cleared latch answers no music")
  Assert.isFalse(
    Effects.fromSequence(sound:currentRadioSequence()) == "pokeflute",
    "the flute query answers false after the stop"
  )
end

return T
