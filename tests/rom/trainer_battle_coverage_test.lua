-- Producer/consumer compatibility between generated trainer records and the
-- executable battle runtime: every generated AI pass answers through a real
-- native trainer decision with a recorded deterministic replay, every
-- distinct move that can materialize on a trainer combatant reaches a
-- concrete runtime handler (a dispatch gate: it fails on missing behavior
-- but normal source-valid failed, miss, and no-effect outcomes from modeled
-- handlers still count as reached), and every distinct carried trainer item
-- is considered and executed from real session stock in a source-eligible
-- state. Structured missing behavior is the only implementation-gap signal.
-- Diagnostics name trainer, move, item, and pass identities only; commercial
-- payloads are never serialized. Derived identity sets stay local to each
-- run in memory; no list is written or committed. Probes use fixed seeds so
-- failures reproduce.

local Assert = require("tests.support.Assert")
local RomSuite = require("tests.rom.support.RomSuite")
local SessionFixture = require("libs.battle.tests.session_fixture")
local TrainerAi = require("libs.battle.src.gen4.TrainerAi")

local T = {}

local PROBE_SEED_BASE = 445100
local TRAINER_STOCK_ID = "trainer-stock"

local compiledBattleByVersion = {}
local compiledTrainersByVersion = {}
local compiledMonRootByVersion = {}
local compiledItemsByVersion = {}
local bundleByVersion = {}
local builtPartiesByVersion = {}
local sharedContent = nil

---@param record table<string, unknown> versioned compilation cache under read
---@param versionId string ready dump this evidence binds to
---@return table<string, unknown> cached record for the version
local function cachedRecord(record, versionId)
  return record[versionId] --[[@as table<string, unknown>]]
end

---@param romFs table ready dump under compilation
---@param versionId string ready dump this evidence binds to
---@return table<string, unknown> compiled battle data for the version
local function compileBattleData(romFs, versionId)
  if compiledBattleByVersion[versionId] == nil then
    local BattleDataCompiler = require("romdump.src.digest.battle.BattleDataCompiler")
    compiledBattleByVersion[versionId] = assert(BattleDataCompiler.compileFromDump(romFs, { versionId = versionId }))
  end
  return cachedRecord(compiledBattleByVersion, versionId)
end

---@param romFs table ready dump under compilation
---@param versionId string ready dump this evidence binds to
---@return table<string, unknown> compiled trainer catalog for the version
local function compileTrainers(romFs, versionId)
  if compiledTrainersByVersion[versionId] == nil then
    local TrainerCatalogCompiler = require("romdump.src.digest.battle.TrainerCatalogCompiler")
    compiledTrainersByVersion[versionId] =
      assert(TrainerCatalogCompiler.compileFromDump(romFs, { versionId = versionId }))
  end
  return cachedRecord(compiledTrainersByVersion, versionId)
end

---@param romFs table ready dump under compilation
---@param versionId string ready dump this evidence binds to
---@return table<string, unknown> compiled item catalog for the version
local function compileItems(romFs, versionId)
  if compiledItemsByVersion[versionId] == nil then
    local ItemCatalogCompiler = require("romdump.src.digest.items.ItemCatalogCompiler")
    compiledItemsByVersion[versionId] = assert(ItemCatalogCompiler.compileCatalog(romFs, { versionId = versionId }))
  end
  return cachedRecord(compiledItemsByVersion, versionId)
end

---@param romFs table ready dump under compilation
---@param versionId string ready dump this evidence binds to
---@return table<string, unknown> compiled mon root for the version
local function compileMonRoot(romFs, versionId)
  if compiledMonRootByVersion[versionId] == nil then
    local MonCatalogCompiler = require("romdump.src.digest.mons.MonCatalogCompiler")
    compiledMonRootByVersion[versionId] = assert(MonCatalogCompiler.compileCatalog(romFs, { versionId = versionId }))
  end
  return cachedRecord(compiledMonRootByVersion, versionId)
end

---@param record table<string, unknown> trainer records under ordering
---@return integer[] sorted trainer identities for deterministic diagnostics
local function sortedTrainerIds(record)
  local trainers = record.trainers --[[@as table<integer, unknown>]]
  local ids = {}
  for trainerIndex in pairs(trainers) do
    ids[#ids + 1] = trainerIndex
  end
  table.sort(ids)
  return ids
end

---@param passes unknown candidate pass list under reporting
---@return string readable pass identities for diagnostics
local function describePasses(passes)
  if type(passes) ~= "table" then
    return tostring(passes)
  end
  local names = {}
  for _, pass in
    ipairs(passes --[[@as table<integer, unknown>]])
  do
    names[#names + 1] = tostring(pass)
  end
  return table.concat(names, ",")
end

---@param failures table<integer, table<string, string>> accepted-configuration missing-behavior diagnostics in traversal order
---@return string one deterministic line per trainer carrying trainer, passes, and reason
local function formatSupportedFailures(failures)
  local lines = {}
  for _, failure in ipairs(failures) do
    lines[#lines + 1] = "trainer "
      .. failure.trainer
      .. " passes ["
      .. failure.passes
      .. "] missing behavior: "
      .. failure.reason
  end
  return table.concat(lines, "\n")
end

---@param entries table<string, unknown> distinct semantic keys under ordering
---@return string[] sorted keys for deterministic probing
local function sortedKeys(entries)
  local keys = {}
  for key in pairs(entries) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

---@param value unknown detached copy without shared mutable battle state
---@return unknown copy for independent fixture combatants
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local input = value --[[@as table<unknown, unknown>]]
  local out = {}
  for key, item in pairs(input) do
    out[key] = copyValue(item)
  end
  return out
end

---@return table frozen battle content carrying the native ruleset over the real chart
local function nativeContent()
  if sharedContent == nil then
    local ContentBuilder = require("libs.content.src.ContentBuilder")
    local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
    local BattleContent = require("libs.battle.src.BattleContent")
    local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
    local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
    local builder = ContentBuilder.new()
    NativeTypeChart.install(builder, "trainer-coverage-tests")
    local behaviors = BattleBehaviorBuilder.new()
    behaviors:registerRuleset(
      Executor.RULESET,
      { key = Executor.RULESET, chart = Executor.RULESET },
      "trainer-coverage-tests"
    )
    -- Native singles/doubles formats stay unregistered on purpose: the
    -- session then resolves them through the real native topology owner,
    -- which validates the composed layout instead of trusting it.
    sharedContent = BattleContent.new(builder:freeze(), behaviors:freeze())
  end
  assert(sharedContent ~= nil, "the native content composes once")
  return sharedContent --[[@as table]]
end

---@param monRoot table<string, unknown> compiled mon root carrying display names
---@return table<string, integer> glyph coverage for generated trainer records
local function validationCharmap(monRoot)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
  local coverage = {}
  for glyph, code in pairs(CatalogFixture.CHARMAP) do
    coverage[glyph] = code
  end
  local nextCode = 0x1000
  ---@param text unknown candidate display text under coverage
  local function coverText(text)
    if type(text) ~= "string" then
      return
    end
    for glyph in Utf8Glyphs.iter(text) do
      if coverage[glyph] == nil then
        coverage[glyph] = nextCode
        nextCode = nextCode + 1
      end
    end
  end
  local species = monRoot.species --[[@as table<string, unknown>]]
  for _, record in pairs(species) do
    coverText((record --[[@as table<string, unknown>]]).name)
  end
  coverText("SILVER")
  coverText("TRAINER")
  return coverage
end

---@param romFs table ready dump under materialization
---@param versionId string ready dump this evidence binds to
---@return table<string, unknown> compilers, catalogs, factory, and content for the version
local function bundleFor(romFs, versionId)
  if bundleByVersion[versionId] == nil then
    local compiled = compileTrainers(romFs, versionId)
    local battle = compileBattleData(romFs, versionId)
    local monRoot = compileMonRoot(romFs, versionId)
    local items = compileItems(romFs, versionId)
    local Catalog = require("libs.hgss.src.battle.HgssTrainerCatalog")
    local Factory = require("libs.hgss.src.battle.HgssTrainerFactory")
    local MonCatalog = require("libs.mons.src.MonCatalog")
    local ItemCatalog = require("libs.items.src.ItemCatalog")
    local CatalogFixture = require("libs.mons.tests.catalog_fixture")
    local MonSources = require("romdump.src.config.MonSources")
    local catalog = Catalog.new(compiled)
    local itemCatalog = ItemCatalog.new(items)
    local monCatalog = MonCatalog.new(monRoot, itemCatalog)
    bundleByVersion[versionId] = {
      compiled = compiled,
      battle = battle,
      catalog = catalog,
      monCatalog = monCatalog,
      factory = Factory.new({
        catalog = catalog,
        monCatalog = monCatalog,
        charmap = validationCharmap(monRoot),
        games = CatalogFixture.GAMES,
        languages = CatalogFixture.LANGUAGES,
        game = versionId,
        language = MonSources.versionLanguages[versionId],
      }),
      content = nativeContent(),
      moveFacts = nil,
      itemFacts = nil,
    }
  end
  return bundleByVersion[versionId] --[[@as table<string, unknown>]]
end

---@param bundle table<string, unknown> versioned compilers and catalogs under materialization
---@param versionId string ready dump this evidence binds to
---@param trainerIndex integer generated trainer identity under materialization
---@return table<string, unknown> built party with its native metadata
local function builtParty(bundle, versionId, trainerIndex)
  local perVersion = builtPartiesByVersion[versionId]
  if perVersion == nil then
    perVersion = {}
    builtPartiesByVersion[versionId] = perVersion
  end
  local store = perVersion --[[@as table<integer, unknown>]]
  if store[trainerIndex] == nil then
    local BattleRng = require("libs.battle.src.gen4.BattleRng")
    local factory = bundle.factory --[[@as table<string, unknown>]]
    local build = factory.build --[[@as fun(self: table<string, unknown>, context: table<string, unknown>)]]
    local ok, built = pcall(build, factory, {
      catalog = bundle.catalog,
      trainerKey = trainerIndex,
      trainerId = trainerIndex,
      rivalName = "SILVER",
      rng = BattleRng.new(PROBE_SEED_BASE),
    })
    Assert.isTrue(ok, "trainer " .. trainerIndex .. " materializes: " .. tostring(built))
    store[trainerIndex] = built
  end
  return store[trainerIndex] --[[@as table<string, unknown>]]
end

---@param bundle table<string, unknown> versioned compilers and catalogs under fact resolution
---@return table<string, table<string, unknown>> immutable move facts for native sessions
local function sessionMoveFacts(bundle)
  if bundle.moveFacts == nil then
    local battle = bundle.battle --[[@as table<string, unknown>]]
    local facts = {}
    for key, record in
      pairs(battle.moves --[[@as table<string, unknown>]])
    do
      facts[
        key --[[@as string]]
      ] = record
    end
    if facts.STRUGGLE == nil then
      local monCatalog = bundle.monCatalog --[[@as table<string, unknown>]]
      local lookup = monCatalog.move --[[@as fun(self: table<string, unknown>, key: string)]]
      local ok, fallback = pcall(lookup, monCatalog, "STRUGGLE")
      if ok then
        facts.STRUGGLE = fallback
      end
    end
    bundle.moveFacts = facts
  end
  return bundle.moveFacts --[[@as table<string, table<string, unknown>>]]
end

---@param bundle table<string, unknown> versioned compilers and catalogs under fact resolution
---@param seeds table<integer, table<string, unknown>> combatant seeds under fact resolution
---@return table<string, table<integer, table<string, unknown>>> static species facts for the seeds
local function sessionSpeciesFacts(bundle, seeds)
  local monCatalog = bundle.monCatalog --[[@as table<string, unknown>]]
  local facts = {}
  for _, seed in ipairs(seeds) do
    local mon = (seed --[[@as table<string, unknown>]]).mon --[[@as table<string, unknown>]]
    local species = mon.species --[[@as string]]
    local form = mon.form --[[@as integer]]
    if facts[species] == nil or facts[species][form] == nil then
      local speciesLookup = monCatalog.species --[[@as fun(self: table<string, unknown>, key: string)]]
      local formLookup = monCatalog.form --[[@as fun(self: table<string, unknown>, key: string, form: integer)]]
      local curveLookup =
        monCatalog.growthCurve --[[@as fun(self: table<string, unknown>, key: string)]]
      local okSpecies, speciesRecord = pcall(speciesLookup, monCatalog, species)
      if not okSpecies or type(speciesRecord) ~= "table" then
        error("species " .. tostring(species) .. " resolves no catalog facts", 0)
      end
      local resolved = speciesRecord --[[@as table<string, unknown>]]
      local okForm, formRecord = pcall(formLookup, monCatalog, species, form)
      if not okForm or type(formRecord) ~= "table" then
        error("species " .. tostring(species) .. " form " .. tostring(form) .. " resolves no form facts", 0)
      end
      local formResolved = formRecord --[[@as table<string, unknown>]]
      if type(formResolved.baseStats) ~= "table" then
        error("species " .. tostring(species) .. " carries no base stats", 0)
      end
      if type(formResolved.types) ~= "table" or #formResolved.types == 0 then
        error("species " .. tostring(species) .. " carries no semantic types", 0)
      end
      if type(formResolved.levelUpMoves) ~= "table" then
        error("species " .. tostring(species) .. " carries no learnset", 0)
      end
      if type(resolved.growthCurve) ~= "string" then
        error("species " .. tostring(species) .. " names no growth curve", 0)
      end
      local okCurve, curve = pcall(curveLookup, monCatalog, resolved.growthCurve)
      if not okCurve or type(curve) ~= "table" then
        error("species " .. tostring(species) .. " resolves no growth curve", 0)
      end
      if type(resolved.baseExpYield) ~= "number" then
        error("species " .. tostring(species) .. " carries no experience yield", 0)
      end
      if type(resolved.evYield) ~= "table" then
        error("species " .. tostring(species) .. " carries no effort yield", 0)
      end
      if type(resolved.genderRatio) ~= "number" then
        error("species " .. tostring(species) .. " carries no gender ratio", 0)
      end
      local types = {} ---@type string[]
      for _, key in
        ipairs(formResolved.types --[[@as string[] ]])
      do
        if type(key) ~= "string" or key == "" then
          error("species " .. tostring(species) .. " carries an unnamed type", 0)
        end
        types[#types + 1] = key --[[@as string]]
      end
      -- Species weights travel for weight-law strikes; records without
      -- a weight stay absent and fail loudly in their handler.
      local weightHg = nil
      if type(resolved.weight) == "number" then
        weightHg = resolved.weight
      end
      local bucket = facts[species]
      if bucket == nil then
        bucket = {}
        facts[species] = bucket
      end
      bucket[form] = {
        baseStats = copyValue(formResolved.baseStats),
        growthCurve = copyValue(curve),
        types = types,
        levelUpMoves = copyValue(formResolved.levelUpMoves),
        baseExpYield = resolved.baseExpYield,
        evYield = copyValue(resolved.evYield),
        genderRatio = resolved.genderRatio,
        weightHg = weightHg,
      }
    end
  end
  return facts
end

---@param bundle table<string, unknown> versioned compilers and catalogs under fact resolution
---@param keys string[] carried item keys under projection
---@param seeds table<integer, table<string, unknown>>? combatant seeds carrying held items under projection
---@return table<string, table<string, unknown>> immutable item facts for the carried and held keys
local function sessionItemFacts(bundle, keys, seeds)
  -- Union caching keeps the facts independent of probe order: every
  -- call projects its missing keys into the shared map and never
  -- removes, so passes, moves, and items legs observe the same map.
  if bundle.itemFacts == nil then
    bundle.itemFacts = {}
  end
  local facts = bundle.itemFacts --[[@as table<string, table<string, unknown>>]]
  local function projectInventory(key)
    if facts[key] ~= nil then
      return
    end
    local CaptureContext = require("libs.battle.src.gen4.CaptureContext")
    local monCatalog = bundle.monCatalog --[[@as table<string, unknown>]]
    local lookup = monCatalog.item --[[@as fun(self: table<string, unknown>, key: string)]]
    if not CaptureContext.isBall(key) then
      local ok, definition = pcall(lookup, monCatalog, key)
      if ok and type(definition) == "table" and type(definition.partyUse) == "table" then
        local projected = { partyUse = copyValue(definition.partyUse) } --[[@as table<string, unknown>]]
        if type(definition.battleUse) == "table" then
          projected.battleUse = copyValue(definition.battleUse)
        end
        -- Canonical held behavior rides beside the use facts so trainer
        -- evaluation reads held effects through this same map.
        if type(definition.heldBehavior) == "table" then
          projected.heldBehavior = copyValue(definition.heldBehavior)
        end
        facts[key] = projected
      end
    end
  end
  local function projectHeld(held)
    if type(held) ~= "string" or held == "" or held == "NONE" then
      return
    end
    local monCatalog = bundle.monCatalog --[[@as table<string, unknown>]]
    local lookup = monCatalog.item --[[@as fun(self: table<string, unknown>, key: string)]]
    local ok, definition = pcall(lookup, monCatalog, held)
    if not ok or type(definition) ~= "table" then
      return
    end
    local resolved = definition --[[@as table<string, unknown>]]
    -- Held entries exist for throw facts and canonical held behavior:
    -- trainer evaluation reads held effects through this same map, so a
    -- held-behavior record alone is a complete projected family.
    if
      type(resolved.naturalGift) ~= "table"
      and type(resolved.fling) ~= "table"
      and type(resolved.heldBehavior) ~= "table"
    then
      return
    end
    local projected = facts[held]
    if projected == nil then
      projected = {}
      facts[held] = projected
    end
    if type(resolved.naturalGift) == "table" and projected.naturalGift == nil then
      projected.naturalGift = copyValue(resolved.naturalGift)
    end
    if type(resolved.fling) == "table" and projected.fling == nil then
      projected.fling = copyValue(resolved.fling)
    end
    if type(resolved.heldBehavior) == "table" and projected.heldBehavior == nil then
      projected.heldBehavior = copyValue(resolved.heldBehavior)
    end
  end
  for _, key in ipairs(keys) do
    projectInventory(key)
  end
  if type(seeds) == "table" then
    for _, seed in ipairs(seeds) do
      if type(seed) == "table" then
        local mon = (seed --[[@as table<string, unknown>]]).mon
        if type(mon) == "table" then
          projectHeld((mon --[[@as table<string, unknown>]]).heldItem)
        end
      end
    end
  end
  return facts --[[@as table<string, table<string, unknown>>]]
end

---@param err unknown probe failure under classification
---@return boolean true when the failure names missing runtime behavior or facts
local function isMissingBehavior(err)
  local Errors = require("libs.errors.src.Errors")
  if Errors.is(err) then
    local record = err --[[@as table<string, unknown>]]
    if record.code == "BATTLE_MISSING_BEHAVIOR" then
      return true
    end
  end
  return false
end

---@param frame table waiting battle frame under inspection
---@param controller string decision producer owning the wanted request
---@return table the pending decision request for the controller
local function requestFor(frame, controller)
  for _, request in ipairs(frame.request.requests) do
    if request.controller == controller then
      return request
    end
  end
  error("the " .. controller .. " request stays open", 0)
end

---@param id integer nonreused positive combatant identity
---@param mon table<string, unknown> detached battle mon record for the seed
---@return table combatant seed carrying the record
local function seedFor(id, mon)
  return { id = id, mon = mon, source = { kind = "probe", owner = "probe", key = "probe-" .. id } }
end

---@param participant table<string, unknown> scenario participant under context
---@param passes table<integer, unknown> generated pass facts for the trainer side
local function withPasses(participant, passes)
  participant.context = { aiPasses = copyValue(passes) }
end

---@param bundle table<string, unknown> versioned compilers and catalogs under session construction
---@param seeds table<integer, table<string, unknown>> combatant seeds under fact resolution
---@param itemKeys string[]? carried item keys under projection, none without stock
---@return table<string, table<string, unknown>> move facts for the session
---@return table<string, table<integer, table<string, unknown>>> species facts for the session
---@return table<string, table<string, unknown>> item facts for the session
local function factsFor(bundle, seeds, itemKeys)
  return sessionMoveFacts(bundle), sessionSpeciesFacts(bundle, seeds), sessionItemFacts(bundle, itemKeys or {}, seeds)
end

---@param bundle table<string, unknown> versioned compilers and catalogs under session construction
---@param versionId string ready dump this evidence binds to
---@param trainerIndex integer generated trainer identity owning the enemy side
---@param passes table<integer, unknown> generated pass facts for the trainer side
---@param doubles boolean true for the two-slot native topology
---@return table live native session over the trainer engagement
local function trainerSession(bundle, versionId, trainerIndex, passes, doubles)
  local Battle = require("gen4.battle")
  local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
  local built = builtParty(bundle, versionId, trainerIndex)
  local mons = built.mons --[[@as table<integer, unknown>]]
  Assert.isTrue(#mons > 0, "trainer " .. trainerIndex .. " fields at least one combatant")
  local function holder(slot)
    local member = mons[slot] or mons[1]
    return copyValue(member) --[[@as table<string, unknown>]]
  end
  local controller = "trainer:" .. trainerIndex
  local sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) }
  local participants = {}
  local positions = {}
  local seeds = {}
  if not doubles then
    local alpha = seedFor(1, holder(1))
    local beta = seedFor(2, holder(1))
    seeds = { alpha, beta }
    local probe = SessionFixture.participant(1, 1, "alpha", { alpha })
    probe.context = {}
    local foe = SessionFixture.participant(2, 2, controller, { beta })
    withPasses(foe, passes)
    participants = { probe, foe }
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    }
  else
    local first = seedFor(1, holder(1))
    local second = seedFor(2, holder(2))
    local third = seedFor(3, holder(1))
    local fourth = seedFor(4, holder(2))
    seeds = { first, second, third, fourth }
    local probe = SessionFixture.participant(1, 1, "alpha", { first, second })
    probe.context = {}
    local foe = SessionFixture.participant(2, 2, controller, { third, fourth })
    withPasses(foe, passes)
    participants = { probe, foe }
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 1, { 1 }, 2),
      SessionFixture.position(3, 2, { 2 }, 3),
      SessionFixture.position(4, 2, { 2 }, 4),
    }
  end
  local moveFacts, speciesFacts, itemFacts = factsFor(bundle, seeds, {})
  return Battle.newSession({
    ruleset = Executor.RULESET,
    format = doubles and "doubles" or "singles",
    sides = sides,
    participants = participants,
    positions = positions,
    inventories = {},
    environment = { weather = "none" },
    random = { seed = PROBE_SEED_BASE + trainerIndex },
    formatState = {},
    moveFacts = moveFacts,
    speciesFacts = speciesFacts,
    itemFacts = itemFacts,
  }, bundle.content)
end

---@param choices table<integer, unknown> trainer decision choices under signature
---@return string readable choice signature for replay comparison
local function choicesSignature(choices)
  local parts = {}
  for _, choice in ipairs(choices) do
    local entry = choice --[[@as table<string, unknown>]]
    local payload = entry.payload --[[@as table<string, unknown>]]
    local detail = tostring(entry.kind)
    if type(payload) == "table" then
      if payload.moveSlot ~= nil then
        detail = detail .. ":" .. tostring(payload.moveSlot)
      end
      if type(payload.target) == "table" then
        detail = detail .. "@" .. tostring((payload.target --[[@as table<string, unknown>]]).position)
      end
      if payload.item ~= nil then
        detail = detail .. ":" .. tostring(payload.item)
      end
      if payload.replacement ~= nil then
        detail = detail .. ":" .. tostring(payload.replacement)
      end
    end
    parts[#parts + 1] = detail
  end
  return table.concat(parts, ",")
end

---@param signature string recorded choice signature under the attack check
---@return boolean true when every answered choice is an attack
local function signatureAttacks(signature)
  if signature == "" then
    return false
  end
  for part in string.gmatch(signature, "[^,]+") do
    if string.sub(part, 1, 7) ~= "attack:" then
      return false
    end
  end
  return true
end

---@param bundle table<string, unknown> versioned compilers and catalogs under session construction
---@param versionId string ready dump this evidence binds to
---@param trainerIndex integer generated trainer identity owning the enemy side
---@param passes table<integer, unknown> generated pass facts for the trainer side
---@param doubles boolean true for the two-slot topology under the probe
---@return string choice signature for the probe
---@return integer shared-stream draws consumed by the probe answer
local function probeDecision(bundle, versionId, trainerIndex, passes, doubles)
  local session = trainerSession(bundle, versionId, trainerIndex, passes, doubles)
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "trainer " .. trainerIndex .. " reaches its coverage decision")
  local wanted = requestFor(opening, "trainer:" .. trainerIndex)
  local callsBefore = session:capture().rng.calls
  local reply = session:answerTrainer(wanted)
  local delta = session:capture().rng.calls - callsBefore
  local signature = choicesSignature(reply.choices --[[@as table<integer, unknown>]])
  session:dispose()
  return signature, delta
end

---@param trainer string trainer identity under classification
---@param passes table<integer, unknown> unchanged generated pass list under classification
---@param unsupported table<integer, table<string, string>> unsupported diagnostics in traversal order
---@return boolean true when the production policy accepts the list
local function classifyTrainerPasses(trainer, passes, unsupported)
  local parseOk, parsedOrErr = pcall(TrainerAi.parsePasses, passes)
  if parseOk then
    return true
  end
  if isMissingBehavior(parsedOrErr) then
    unsupported[#unsupported + 1] = {
      trainer = trainer,
      passes = describePasses(passes),
      reason = tostring(parsedOrErr),
    }
    return false
  end
  error(
    "trainer "
      .. trainer
      .. " passes ["
      .. describePasses(passes)
      .. "] malformed pass metadata: "
      .. tostring(parsedOrErr),
    0
  )
end

---@param unsupported table<integer, table<string, string>> unsupported diagnostics in traversal order
---@param supported table<integer, table<string, string>> accepted-but-unexecutable diagnostics in traversal order
local function checkTrainerCorpusFitsSupport(unsupported, supported)
  if #unsupported == 0 and #supported == 0 then
    return
  end
  local sections = {}
  if #unsupported > 0 then
    sections[#sections + 1] = "unsupported trainer pass lists:\n" .. formatSupportedFailures(unsupported)
  end
  if #supported > 0 then
    sections[#sections + 1] = "accepted trainer pass lists miss executable behavior:\n"
      .. formatSupportedFailures(supported)
  end
  error("generated trainer passes miss executable behavior:\n" .. table.concat(sections, "\n"), 0)
end

function T.generated_trainer_passes_answer_through_the_native_session(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local compiled = bundle.compiled --[[@as table<string, unknown>]]
  local ids = sortedTrainerIds(compiled)
  Assert.isTrue(#ids > 0, "the dump must yield at least one trainer record")
  local seenDouble = false
  local seenPasses = 0
  local executedByTrainer = {} ---@type table<integer, boolean>
  local supportedFailures = {} ---@type table<integer, table<string, string>>
  local unsupportedPasses = {} ---@type table<integer, table<string, string>>
  local doublesByTrainer = {} ---@type table<integer, boolean>
  local passesByTrainer = {} ---@type table<integer, table<integer, unknown>>
  local doubleIds = {} ---@type integer[]
  for _, trainerIndex in ipairs(ids) do
    local entry = (compiled.trainers --[[@as table<integer, unknown>]])[trainerIndex]
    local record = entry --[[@as table<string, unknown>]]
    local passes = record.aiPasses --[[@as table<integer, unknown>]]
    Assert.isTrue(type(passes) == "table", "trainer " .. trainerIndex .. " keeps its named AI passes")
    for _, pass in ipairs(passes) do
      Assert.isTrue(pass ~= "ai_pass_7", "trainer " .. trainerIndex .. " keeps the doubles fact out of the pass list")
      seenPasses = seenPasses + 1
    end
    local doubles = record.doubleBattle == true
    if doubles then
      seenDouble = true
      if #doubleIds < 5 then
        doubleIds[#doubleIds + 1] = trainerIndex
      end
    end
    doublesByTrainer[trainerIndex] = doubles
    passesByTrainer[trainerIndex] = passes
    -- The trainer policy owns the supported pass surface: only pass lists
    -- it accepts reach the session below. Lists it rejects stay recorded
    -- and never execute here; the gate after the sweep fails on them.
    if classifyTrainerPasses(tostring(trainerIndex), passes, unsupportedPasses) then
      local session = trainerSession(bundle, versionId, trainerIndex, passes, doubles)
      local opening = SessionFixture.driveUntilSettled(session)
      Assert.equal(opening.status, "waiting", "trainer " .. trainerIndex .. " reaches its opening decision")
      local wanted = requestFor(opening, "trainer:" .. trainerIndex)
      local ok, reply = pcall(function()
        return session:answerTrainer(wanted)
      end)
      if not ok then
        if isMissingBehavior(reply) then
          supportedFailures[#supportedFailures + 1] = {
            trainer = tostring(trainerIndex),
            passes = describePasses(passes),
            reason = tostring(reply),
          }
          session:dispose()
        else
          session:dispose()
          error(
            "trainer "
              .. trainerIndex
              .. " passes ["
              .. describePasses(passes)
              .. "] raw decision failure: "
              .. tostring(reply),
            0
          )
        end
      else
        local answered = reply --[[@as table<string, unknown>]]
        Assert.equal(
          answered.requestId,
          wanted.requestId,
          "trainer " .. trainerIndex .. " answers its open request identity"
        )
        Assert.equal(answered.epoch, wanted.epoch, "trainer " .. trainerIndex .. " answers its open request epoch")
        Assert.equal(
          answered.controller,
          wanted.controller,
          "trainer " .. trainerIndex .. " answers under its own controller"
        )
        Assert.equal(
          #(answered.choices --[[@as table<integer, unknown>]]),
          #wanted.actors,
          "trainer " .. trainerIndex .. " answers every addressed actor"
        )
        local stored, submitErr = session:submit(answered)
        Assert.isTrue(stored, "trainer " .. trainerIndex .. " reply binds: " .. tostring(submitErr))
        session:dispose()
        executedByTrainer[trainerIndex] = true
      end
    end
  end
  Assert.isTrue(seenDouble, "the corpus holds at least one native double trainer for the topology gate")
  Assert.isTrue(seenPasses > 0, "the corpus must yield at least one generated pass for the coverage gate")
  -- A rejected pass list is a gap in claimed support, never a waived
  -- skip, and an accepted pass list that still misses behavior is one
  -- too: fail once after the full sweep with one deterministic line per
  -- trainer so a single passing trainer cannot mask other trainers.
  -- Unsupported trainers stay out of the executed counts below.
  checkTrainerCorpusFitsSupport(unsupportedPasses, supportedFailures)
  -- Every executed configuration replays its opening decision
  -- deterministically: the same passes answer with the same choices at
  -- the same shared-stream cost on a fresh session. This is coverage
  -- plus determinism: it proves each executable pass list dispatches and
  -- replays, never that the answer matches native intent (only the
  -- owner-level program cases prove that, and they run without a dump).
  local executed = 0
  for _, trainerIndex in ipairs(ids) do
    if executedByTrainer[trainerIndex] then
      executed = executed + 1
      local passes = passesByTrainer[trainerIndex]
      local doubles = doublesByTrainer[trainerIndex]
      local firstOk, signature, delta = pcall(probeDecision, bundle, versionId, trainerIndex, passes, doubles)
      if not firstOk then
        error(
          "trainer " .. trainerIndex .. " replays its coverage decision nondeterministically: " .. tostring(signature),
          0
        )
      end
      local rerunSignature, rerunDelta = probeDecision(bundle, versionId, trainerIndex, passes, doubles)
      Assert.deepEqual(
        rerunSignature,
        signature,
        "trainer " .. trainerIndex .. " replays its coverage decision"
      )
      Assert.equal(rerunDelta, delta, "trainer " .. trainerIndex .. " replays its coverage draw count")
      Assert.isTrue(delta > 0, "trainer " .. trainerIndex .. " coverage answer draws from the shared stream")
    end
  end
  Assert.isTrue(
    executed > 0,
    "at least one generated trainer executes its coverage decision (unsupported pass lists: "
      .. #unsupportedPasses
      .. ")"
  )
  -- At least one executed double trainer exercises the doubles selector:
  -- both positions answer attacks at live opposing slots with a recorded
  -- deterministic draw count, not two independent singles answers.
  -- Trainers with unsupported pass lists never execute, so only executed
  -- trainers can cover the topology.
  local doublesCovered = false
  for _, trainerIndex in ipairs(doubleIds) do
    if executedByTrainer[trainerIndex] then
      local signature, delta = probeDecision(bundle, versionId, trainerIndex, passesByTrainer[trainerIndex], true)
      if signatureAttacks(signature) then
        for part in string.gmatch(signature, "[^,]+") do
          local slot = string.match(part, "@(.*)$")
          Assert.isTrue(
            slot == "1" or slot == "2",
            "trainer " .. trainerIndex .. " doubles strikes address a live opposing slot"
          )
        end
        local rerunSignature, rerunDelta =
          probeDecision(bundle, versionId, trainerIndex, passesByTrainer[trainerIndex], true)
        Assert.deepEqual(
          rerunSignature,
          signature,
          "trainer " .. trainerIndex .. " replays its doubles coverage decision"
        )
        Assert.equal(rerunDelta, delta, "trainer " .. trainerIndex .. " replays its doubles coverage draw count")
        Assert.isTrue(delta > 0, "trainer " .. trainerIndex .. " doubles answer draws from the shared stream")
        doublesCovered = true
        break
      end
    end
  end
  Assert.isTrue(
    doublesCovered,
    "an executed doubles trainer answers attacks on both slots (unsupported pass lists: "
      .. #unsupportedPasses
      .. ")"
  )
end

-- A source pass list the production policy rejects must fail the corpus
-- gate instead of staying a silent skip, while the same arbitrary input
-- still fails closed when handed to production directly. The rejected
-- input is discovered by asking the production policy itself, never from
-- a copied support list, and no dump data is read here.
function T.rejected_pass_lists_fail_the_corpus_gate_while_production_stays_closed(_, versionId)
  local rejected = nil
  for candidateBit = 0, 31 do
    local candidate = "ai_pass_" .. candidateBit
    if not pcall(TrainerAi.parsePasses, { candidate }) then
      rejected = candidate
      break
    end
  end
  Assert.notNil(rejected, "the production policy still rejects at least one pass name")
  local probe = rejected --[[@as string]]
  local unsupported = {} ---@type table<integer, table<string, string>>
  Assert.isFalse(
    classifyTrainerPasses("synthetic:" .. versionId, { probe }, unsupported),
    "the rejected pass list stays out of execution"
  )
  Assert.equal(#unsupported, 1, "the rejected pass list records exactly one diagnostic")
  Assert.isTrue(
    string.find(unsupported[1].trainer, "synthetic:", 1, true) ~= nil,
    "the diagnostic keeps the trainer identity"
  )
  Assert.equal(unsupported[1].passes, probe, "the diagnostic keeps the original pass list")
  Assert.isTrue(
    string.find(unsupported[1].reason, probe, 1, true) ~= nil,
    "the diagnostic keeps the original production reason"
  )
  local gateFailure = Assert.throws(function()
    checkTrainerCorpusFitsSupport(unsupported, {})
  end, "an unsupported source pass list fails the corpus gate")
  Assert.isTrue(
    string.find(tostring(gateFailure), probe, 1, true) ~= nil,
    "the gate failure names the rejected pass"
  )
  local directFailure = Assert.throws(function()
    TrainerAi.parsePasses({ probe })
  end, "production still rejects the same arbitrary pass")
  Assert.isTrue(isMissingBehavior(directFailure), "the production rejection stays structured missing behavior")
end

---@param mons table<integer, unknown> materialized party members under the move search
---@param moveKey string trainer move identity under the search
---@return integer member slot naturally carrying the move, else the lead slot
local function holderSlot(mons, moveKey)
  for slot, mon in ipairs(mons) do
    for _, entry in
      ipairs((mon --[[@as table<string, unknown>]]).moves --[[@as table<integer, unknown>]])
    do
      if (entry --[[@as table<string, unknown>]]).move == moveKey then
        return slot
      end
    end
  end
  return 1
end

-- Dispatch gate over the generated trainer move corpus: every distinct
-- materialized move reaches a concrete runtime handler without missing
-- behavior. This proves reachability, not conditional semantics: a normal
-- source-valid failed, miss, or no-effect result still counts as reached,
-- while focused family suites own the per-branch trigger cases.
function T.materialized_trainer_moves_reach_concrete_runtime_behavior(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local compiled = bundle.compiled --[[@as table<string, unknown>]]
  local Battle = require("gen4.battle")
  local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
  local ids = sortedTrainerIds(compiled)
  Assert.isTrue(#ids > 0, "the dump must yield at least one trainer record")
  local representative = {}
  for _, trainerIndex in ipairs(ids) do
    local built = builtParty(bundle, versionId, trainerIndex)
    local party = built.mons --[[@as table<integer, unknown>]]
    for _, mon in ipairs(party) do
      local entries = (mon --[[@as table<string, unknown>]]).moves --[[@as table<integer, unknown>]]
      for _, entry in ipairs(entries) do
        local key = (entry --[[@as table<string, unknown>]]).move --[[@as string]]
        if representative[key] == nil then
          representative[key] = trainerIndex
        end
      end
    end
  end
  local moveFacts = sessionMoveFacts(bundle)
  Assert.notNil(moveFacts.TACKLE, "the compiled facts carry the fixture strike")
  local tacklePp = (moveFacts.TACKLE --[[@as table<string, unknown>]]).basePp --[[@as integer]]
  Assert.isTrue(type(tacklePp) == "number" and tacklePp >= 1, "the fixture strike carries usable power points")
  local keys = sortedKeys(representative)
  Assert.isTrue(#keys > 0, "the generated parties must materialize at least one move")
  for index, moveKey in ipairs(keys) do
    local facts = moveFacts[moveKey]
    Assert.notNil(
      facts,
      "trainer move " .. moveKey .. " from trainer " .. tostring(representative[moveKey]) .. " keeps compiled facts"
    )
    local basePp = (facts --[[@as table<string, unknown>]]).basePp
    Assert.isTrue(
      type(basePp) == "number" and basePp >= 1,
      "trainer move " .. moveKey .. " carries usable power points"
    )
    local built = builtParty(bundle, versionId, representative[moveKey])
    local party = built.mons --[[@as table<integer, unknown>]]
    local attacker = copyValue(party[holderSlot(party, moveKey)]) --[[@as table<string, unknown>]]
    attacker.moves = attacker.moves --[[@as table<integer, unknown>]]
    attacker.moves[1] = { move = moveKey, pp = basePp, ppUps = 0 }
    local defender = nil
    if #party > 1 then
      local slot = holderSlot(party, moveKey) == 1 and 2 or 1
      defender = copyValue(party[slot]) --[[@as table<string, unknown>]]
    else
      defender = copyValue(party[1]) --[[@as table<string, unknown>]]
    end
    defender.moves = defender.moves --[[@as table<integer, unknown>]]
    defender.moves[1] = { move = "TACKLE", pp = tacklePp, ppUps = 0 }
    local alpha = seedFor(1, attacker)
    local beta = seedFor(2, defender)
    local _, speciesFacts, probeItemFacts = factsFor(bundle, { alpha, beta }, {})
    local probe = SessionFixture.participant(1, 1, "alpha", { alpha })
    probe.context = {}
    local foe = SessionFixture.participant(2, 2, "beta", { beta })
    foe.context = {}
    local session = Battle.newSession({
      ruleset = Executor.RULESET,
      format = "singles",
      sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
      participants = { probe, foe },
      positions = {
        SessionFixture.position(1, 1, { 1 }, 1),
        SessionFixture.position(2, 2, { 2 }, 2),
      },
      inventories = {},
      environment = { weather = "none" },
      random = { seed = PROBE_SEED_BASE + index },
      formatState = {},
      moveFacts = moveFacts,
      speciesFacts = speciesFacts,
      itemFacts = probeItemFacts,
    }, bundle.content)
    local opening = SessionFixture.driveUntilSettled(session)
    Assert.equal(opening.status, "waiting", "trainer move " .. moveKey .. " reaches its opening decision")
    local alphaRequest = requestFor(opening, "alpha")
    local betaRequest = requestFor(opening, "beta")
    local alphaActor = assert(alphaRequest.actors[1], "the owning request addresses its lead")
    local betaActor = assert(betaRequest.actors[1], "the opposing request addresses its lead")
    local storedAlpha, alphaErr = session:submit(
      SessionFixture.replyFor(alphaRequest, {
        SessionFixture.attackChoice(alphaActor, 0, SessionFixture.positionTarget(2)),
      })
    )
    Assert.isTrue(storedAlpha, "trainer move " .. moveKey .. " choice binds: " .. tostring(alphaErr))
    local storedBeta, betaErr = session:submit(
      SessionFixture.replyFor(betaRequest, {
        SessionFixture.attackChoice(betaActor, 0, SessionFixture.positionTarget(1)),
      })
    )
    Assert.isTrue(storedBeta, "the opposing choice binds: " .. tostring(betaErr))
    local ok, turnErr = pcall(function()
      return session:advance(1024)
    end)
    if not ok then
      if isMissingBehavior(turnErr) then
        error(
          "trainer "
            .. tostring(representative[moveKey])
            .. " move "
            .. moveKey
            .. " has no executable behavior: "
            .. tostring(turnErr),
          0
        )
      end
      error(
        "trainer " .. tostring(representative[moveKey]) .. " move " .. moveKey .. " turn failed: " .. tostring(turnErr),
        0
      )
    end
    session:dispose()
  end
end

---@param partyUse table<string, unknown>? generated semantic record under cure inspection
---@return string[] sorted cure flags the record enables
local function enabledCures(partyUse)
  local flags = {}
  if type(partyUse) ~= "table" then
    return flags
  end
  local cures = (partyUse --[[@as table<string, unknown>]]).cures
  if type(cures) ~= "table" then
    return flags
  end
  for flag, enabled in
    pairs(cures --[[@as table<string, unknown>]])
  do
    if enabled == true then
      flags[#flags + 1] = flag --[[@as string]]
    end
  end
  table.sort(flags)
  return flags
end

---@param flag string generated cure flag under holder mapping
---@return string holder condition key the flag clears
local function holderConditionFor(flag)
  if flag == "poison" then
    return "poison"
  end
  return flag
end

---@param key string holder condition key under state shaping
---@return table<string, unknown> typed condition state for the holder record
local function holderStateFor(key)
  if key == "sleep" then
    return { turns = 3 }
  end
  return {}
end

---@param reply table<string, unknown> trainer decision reply under inspection
---@param itemKey string carried item identity under the search
---@return table<string, unknown>? the serving choice for the item, when present
local function servingChoice(reply, itemKey)
  for _, choice in
    ipairs(reply.choices --[[@as table<integer, unknown>]])
  do
    local entry = choice --[[@as table<string, unknown>]]
    if entry.kind == "item" and type(entry.payload) == "table" then
      local payload = entry.payload --[[@as table<string, unknown>]]
      if payload.item == itemKey then
        return entry
      end
    end
  end
  return nil
end

---@param choices table<integer, unknown> trainer decision choices under reporting
---@return string readable choice kinds for diagnostics
local function describeChoices(choices)
  local kinds = {}
  for _, choice in ipairs(choices) do
    local entry = choice --[[@as table<string, unknown>]]
    local payload = entry.payload --[[@as table<string, unknown>]]
    local detail = tostring(entry.kind)
    if type(payload) == "table" and payload.item ~= nil then
      detail = detail .. ":" .. tostring(payload.item)
    end
    kinds[#kinds + 1] = detail
  end
  return table.concat(kinds, ",")
end

function T.carried_trainer_items_execute_from_session_stock(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local compiled = bundle.compiled --[[@as table<string, unknown>]]
  local Battle = require("gen4.battle")
  local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
  local CaptureContext = require("libs.battle.src.gen4.CaptureContext")
  local ids = sortedTrainerIds(compiled)
  Assert.isTrue(#ids > 0, "the dump must yield at least one trainer record")
  local representative = {}
  for _, trainerIndex in ipairs(ids) do
    local built = builtParty(bundle, versionId, trainerIndex)
    for _, key in
      ipairs(built.items --[[@as table<integer, unknown>]])
    do
      -- Gap positions are not servings and never probe.
      if key ~= "NONE" and representative[key --[[@as string]]] == nil then
        representative[key --[[@as string]]] = trainerIndex
      end
    end
  end
  local keys = sortedKeys(representative)
  Assert.isTrue(#keys > 0, "the generated trainers must carry at least one item")
  -- Every carried identity is probed even when an earlier one already
  -- failed, so one run records the complete executable-behavior gap list;
  -- nothing here exempts an identity, the run still fails on any gap.
  local failures = {}
  for _, itemKey in ipairs(keys) do
    local probeOk, probeErr = pcall(function()
    local trainerIndex = representative[itemKey]
    local built = builtParty(bundle, versionId, trainerIndex)
    local party = built.mons --[[@as table<integer, unknown>]]
    Assert.isTrue(#party > 0, "trainer " .. trainerIndex .. " fields its item holder")
    local partyUse = nil
    do
      local monCatalog = bundle.monCatalog --[[@as table<string, unknown>]]
      local lookup = monCatalog.item --[[@as fun(self: table<string, unknown>, key: string)]]
      local ok, definition = pcall(lookup, monCatalog, itemKey)
      if ok and type(definition) == "table" and type(definition.partyUse) == "table" then
        partyUse = definition.partyUse
      end
    end
    local holder = copyValue(party[1]) --[[@as table<string, unknown>]]
    local holderMon = holder --[[@as table<string, unknown>]]
    local holderCondition = holderMon.condition --[[@as table<string, unknown>]]
    holderCondition.currentHp = 1
    holderCondition.effects = {}
    local cures = enabledCures(partyUse)
    if #cures > 0 then
      local holderKey = holderConditionFor(cures[1])
      holderCondition.effects = { { key = holderKey, version = 1, state = holderStateFor(holderKey) } }
    end
    local first = seedFor(1, copyValue(party[1]) --[[@as table<string, unknown>]])
    local reserve = seedFor(3, copyValue(party[1]) --[[@as table<string, unknown>]])
    local second = seedFor(2, holder)
    local trainerSeeds = { first, reserve, second }
    local moveFacts, speciesFacts, itemFacts = factsFor(bundle, trainerSeeds, keys)
    local stock = SessionFixture.inventory(TRAINER_STOCK_ID, { 2 }, { [itemKey] = 2 })
    local foe = SessionFixture.participant(1, 1, "alpha", { first, reserve })
    foe.context = {}
    local trainer = SessionFixture.participant(2, 2, "trainer:" .. trainerIndex, { second }, TRAINER_STOCK_ID)
    withPasses(trainer, built.aiPasses --[[@as table<integer, unknown>]])
    -- The probe stock holds two units of the single probed identity, so
    -- the compact slots carry that identity twice in source multiplicity.
    trainer.context.trainerItems = { itemKey, itemKey }
    local session = Battle.newSession({
      ruleset = Executor.RULESET,
      format = "singles",
      sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
      participants = { foe, trainer },
      positions = {
        SessionFixture.position(1, 1, { 1 }, 1),
        SessionFixture.position(2, 2, { 2 }, 2),
      },
      inventories = { stock },
      environment = { weather = "none" },
      random = { seed = PROBE_SEED_BASE + trainerIndex },
      formatState = {},
      moveFacts = moveFacts,
      speciesFacts = speciesFacts,
      itemFacts = itemFacts,
    }, bundle.content)
    local opening = SessionFixture.driveUntilSettled(session)
    Assert.equal(opening.status, "waiting", "trainer item " .. itemKey .. " reaches its opening decision")
    local wanted = requestFor(opening, "trainer:" .. trainerIndex)
    local ok, reply = pcall(function()
      return session:answerTrainer(wanted)
    end)
    if not ok then
      if isMissingBehavior(reply) then
        error(
          "trainer " .. trainerIndex .. " item " .. itemKey .. " has no executable behavior: " .. tostring(reply),
          0
        )
      end
      error("trainer " .. trainerIndex .. " item " .. itemKey .. " consideration failed: " .. tostring(reply), 0)
    end
    local answered = reply --[[@as table<string, unknown>]]
    local serving = servingChoice(answered, itemKey)
    if serving == nil then
      if CaptureContext.isBall(itemKey) then
        session:dispose()
      else
        error(
          "trainer "
            .. trainerIndex
            .. " item "
            .. itemKey
            .. " was refused selection in its eligible state, choices ["
            .. describeChoices(answered.choices --[[@as table<integer, unknown>]])
            .. "]",
          0
        )
      end
    else
      local before = session:capture()
      local hpBefore = before.combatants[2].hp --[[@as integer]]
      local maxHp = before.combatants[2].maxHp --[[@as integer]]
      Assert.isTrue(type(maxHp) == "number", "trainer item " .. itemKey .. " holder carries its health ceiling")
      local ledgerBefore = #(before.ledger --[[@as table<integer, unknown>]])
      local storedTrainer, trainerErr = session:submit(answered)
      Assert.isTrue(storedTrainer, "trainer item " .. itemKey .. " serving binds: " .. tostring(trainerErr))
      local foeRequest = requestFor(opening, "alpha")
      local foeActor = assert(foeRequest.actors[1], "the opposing request addresses its lead")
      local storedFoe, foeErr = session:submit(
        SessionFixture.replyFor(foeRequest, { SessionFixture.switchChoice(foeActor, 3) })
      )
      Assert.isTrue(storedFoe, "the opposing exchange binds: " .. tostring(foeErr))
      local turnOk, turn = pcall(function()
        return session:advance(1024)
      end)
      if not turnOk then
        if isMissingBehavior(turn) then
          error(
            "trainer " .. trainerIndex .. " item " .. itemKey .. " has no executable behavior: " .. tostring(turn),
            0
          )
        end
        error("trainer " .. trainerIndex .. " item " .. itemKey .. " turn failed: " .. tostring(turn), 0)
      end
      local served = nil
      for _, event in
        ipairs((turn --[[@as table<string, unknown>]]).events --[[@as table<integer, unknown>]])
      do
        local entry = event --[[@as table<string, unknown>]]
        if entry.kind == "item" and type(entry.payload) == "table" then
          local payload = entry.payload --[[@as table<string, unknown>]]
          if payload.item == itemKey then
            served = entry
          end
        end
      end
      Assert.notNil(served, "trainer " .. trainerIndex .. " item " .. itemKey .. " announces its serving")
      local servedPayload = (served --[[@as table<string, unknown>]]).payload --[[@as table<string, unknown>]]
      Assert.equal(servedPayload.inventory, TRAINER_STOCK_ID, "the serving names the trainer stock")
      local settled = session:capture()
      local stockAfter = settled.inventories[TRAINER_STOCK_ID] --[[@as table<string, unknown>]]
      Assert.equal(
        (stockAfter.quantities --[[@as table<string, integer>]])[itemKey],
        1,
        "trainer item " .. itemKey .. " consumes exactly one unit"
      )
      local ledgerAfter = settled.ledger --[[@as table<integer, unknown>]]
      Assert.equal(
        #ledgerAfter,
        ledgerBefore + 1,
        "trainer item " .. itemKey .. " writes exactly one ledger delta"
      )
      local delta = ledgerAfter[#ledgerAfter] --[[@as table<string, unknown>]]
      Assert.equal(delta.item, itemKey, "the ledger delta names the served item")
      Assert.equal(delta.delta, -1, "the ledger delta consumes exactly one unit")
      local holderAfter = settled.combatants[2] --[[@as table<string, unknown>]]
      if partyUse ~= nil and (partyUse --[[@as table<string, unknown>]]).restore ~= nil then
        Assert.isTrue(
          holderAfter.hp --[[@as integer]] > hpBefore,
          "trainer item " .. itemKey .. " restores the holder"
        )
        Assert.isTrue(
          holderAfter.hp --[[@as integer]] <= maxHp,
          "trainer item " .. itemKey .. " respects the health ceiling"
        )
      end
      if #cures > 0 then
        local afterMon = holderAfter.mon --[[@as table<string, unknown>]]
        local afterCondition = afterMon.condition --[[@as table<string, unknown>]]
        Assert.deepEqual(
          afterCondition.effects,
          {},
          "trainer item " .. itemKey .. " clears the holder condition"
        )
      end
      session:dispose()
    end
    end)
    if not probeOk then
      failures[#failures + 1] = tostring(probeErr)
    end
  end
  if #failures > 0 then
    error("the generated trainer items miss executable behavior:\n" .. table.concat(failures, "\n"), 0)
  end
end

return RomSuite.fromFacts(T)
