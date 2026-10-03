-- Producer/consumer compatibility between generated trainer records and the
-- executable battle runtime: every AI pass emitted by the trainer compiler
-- resolves through the runtime pass compiler, and every distinct move that
-- can materialize on a trainer combatant executes through ordinary native
-- move execution without reaching missing-behavior fallback. Diagnostics
-- name trainer, move, and pass identities only; commercial payloads are
-- never serialized. Probes use fixed seeds so failures reproduce.

local Assert = require("tests.support.Assert")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local PROBE_SEED_BASE = 445100
local PROBE_ACTION_ID = 701

local compiledBattleByVersion = {}
local compiledTrainersByVersion = {}
local compiledMonRootByVersion = {}
local compiledItemsByVersion = {}

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

function T.generated_trainer_ai_passes_parse_through_the_native_session(romFs, versionId)
  local TrainerCatalogCompiler = require("romdump.src.digest.battle.TrainerCatalogCompiler")
  Assert.isTrue(
    type(TrainerCatalogCompiler.compileFromDump) == "function",
    "the trainer compiler publishes the generated catalog"
  )
  local TrainerAi = require("libs.battle.src.gen4.TrainerAi")
  Assert.isTrue(type(TrainerAi.parsePasses) == "function", "the native session parses trainer pass facts")
  local compiled = compileTrainers(romFs, versionId)
  local ids = sortedTrainerIds(compiled)
  Assert.isTrue(#ids > 0, "the dump must yield at least one trainer record")
  for _, trainerIndex in ipairs(ids) do
    local entry = (compiled.trainers --[[@as table<integer, unknown>]])[trainerIndex]
    local record = entry --[[@as table<string, unknown>]]
    local passes = record.aiPasses --[[@as table<integer, unknown>]]
    Assert.isTrue(type(passes) == "table", "trainer " .. trainerIndex .. " keeps its named AI passes")
    for _, pass in ipairs(passes) do
      Assert.isTrue(pass ~= "ai_pass_7", "trainer " .. trainerIndex .. " keeps the doubles fact out of the pass list")
    end
    local ok, err = pcall(TrainerAi.parsePasses, passes)
    Assert.isTrue(
      ok,
      "trainer " .. trainerIndex .. " passes [" .. describePasses(passes) .. "] parse: " .. tostring(err)
    )
  end
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

---@param moves table<string, unknown> distinct move keys under ordering
---@return string[] sorted move keys for deterministic probing
local function sortedMoveKeys(moves)
  local keys = {}
  for key in pairs(moves) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

---@return table<string, unknown> session type chart over the complete native matrix
local function nativeChart()
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
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
  local BattleContent = require("libs.battle.src.BattleContent")
  local content = BattleContent.new(builder:freeze(), behaviors:freeze())
  local chart = content:typeChart(Executor.RULESET)
  assert(chart ~= nil, "the native chart resolves for the probe ruleset")
  return chart --[[@as table<string, unknown>]]
end

---@return table live battle state with two healthy combatants over real owners
local function probeState()
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local contracts = SessionFixture.sessionContracts()
  local scenario = SessionFixture.buildScenario({
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "scripted", { SessionFixture.combatant(1, 11) }),
      SessionFixture.participant(2, 2, "scripted", { SessionFixture.combatant(2, 23) }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
    inventories = {},
  })
  return contracts.State.create(contracts.Scenario.validate(scenario))
end

---@param state table live battle state under execution
---@return table genuine mechanics context over that state
local function probeContext(state)
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local Context = SessionFixture.requirePresent(
    "libs.battle.src.BattleContext",
    "the validated mutation surface owns mechanics writes"
  )
  return Context.wrap(state)
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

---@param moveKey string trainer move identity under probing
---@param moveFacts table<string, unknown> real compiled move facts for the version
---@param chart table<string, unknown> session type chart for the probe
---@param seed integer fixed seed for this probe
local function probeMove(moveKey, moveFacts, chart, seed)
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local BattleRng = require("libs.battle.src.gen4.BattleRng")
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  local state = probeState()
  local ctx = probeContext(state)
  local inputs = {
    actionId = PROBE_ACTION_ID,
    actor = { combatant = 1 },
    requestedMove = moveKey,
    executingMove = moveKey,
    ppOwnerSlot = 0,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = { { move = moveKey, pp = 10, ppUps = 0 } },
    moveFacts = moveFacts,
    combat = { level = 50, attack = 120, defense = 90 },
    attackerTypes = { "normal" },
    defenderTypes = { [2] = { "normal" } },
    typeChart = chart,
    friendship = 255,
    usable = { "TACKLE" },
    party = { "TACKLE", "EMBER" },
    userMoves = { "TACKLE", "EMBER", moveKey },
    copiedMove = "TACKLE",
    gravity = false,
    healBlock = false,
    -- Sleep Talk only speaks while its user sleeps; every other
    -- identity ignores the flag.
    userAsleep = moveKey == "SLEEP_TALK",
    stream = BattleRng.new(seed),
  }
  local node = Execution.start(inputs)
  for _ = 1, 8 do
    node = Execution.step(ctx, node)
    local record = node --[[@as table<string, unknown>]]
    if record.kind == "complete" and record.frame == nil then
      return
    end
  end
  error("move " .. moveKey .. " never settled its execution frame", 0)
end

function T.materialized_trainer_moves_execute_without_missing_behavior(romFs, versionId)
  local compiled = compileTrainers(romFs, versionId)
  local battle = compileBattleData(romFs, versionId)
  local monRoot = compileMonRoot(romFs, versionId)
  local Catalog = require("libs.hgss.src.battle.HgssTrainerCatalog")
  local Factory = require("libs.hgss.src.battle.HgssTrainerFactory")
  local MonCatalog = require("libs.mons.src.MonCatalog")
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local MonSources = require("romdump.src.config.MonSources")
  local BattleRng = require("libs.battle.src.gen4.BattleRng")
  local catalog = Catalog.new(compiled)
  local items = ItemCatalog.new(compileItems(romFs, versionId))
  local monCatalog = MonCatalog.new(monRoot, items)
  local factory = Factory.new({
    catalog = catalog,
    monCatalog = monCatalog,
    charmap = validationCharmap(monRoot),
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    game = versionId,
    language = MonSources.versionLanguages[versionId],
  })
  local ids = sortedTrainerIds(compiled)
  Assert.isTrue(#ids > 0, "the dump must yield at least one trainer record")
  local representative = {}
  for _, trainerIndex in ipairs(ids) do
    local ok, built = pcall(factory.build, factory, {
      catalog = catalog,
      trainerKey = trainerIndex,
      trainerId = trainerIndex,
      rivalName = "SILVER",
      rng = BattleRng.new(PROBE_SEED_BASE),
    })
    Assert.isTrue(ok, "trainer " .. trainerIndex .. " materializes: " .. tostring(built))
    local party = (built --[[@as table<string, unknown>]]).mons --[[@as table<integer, unknown>]]
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
  local moveFacts = battle.moves --[[@as table<string, unknown>]]
  local chart = nativeChart()
  local keys = sortedMoveKeys(representative)
  Assert.isTrue(#keys > 0, "the generated parties must materialize at least one move")
  for index, moveKey in ipairs(keys) do
    Assert.notNil(
      moveFacts[moveKey],
      "trainer move " .. moveKey .. " from trainer " .. tostring(representative[moveKey]) .. " keeps compiled facts"
    )
    local ok, err = pcall(probeMove, moveKey, moveFacts, chart, PROBE_SEED_BASE + index)
    if not ok then
      if isMissingBehavior(err) then
        error(
          "trainer "
            .. tostring(representative[moveKey])
            .. " move "
            .. moveKey
            .. " has no executable behavior: "
            .. tostring(err),
          0
        )
      end
      error(
        "trainer " .. tostring(representative[moveKey]) .. " move " .. moveKey .. " probe failed: " .. tostring(err),
        0
      )
    end
  end
end

return RomSuite.fromFacts(T)
