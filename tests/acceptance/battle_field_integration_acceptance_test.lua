-- Field-owned battle acceptance: a prepared wild encounter and a native
-- trainer launch each run through the field runtime production battle face
-- (startBattle/updateBattle/battleStatus/lastBattleResult), answer
-- decisions through the runtime decision seam, settle through native
-- mechanics, and return the field with committed consequences. Synthetic
-- catalogs and full mon records only; no renderer, no caller-authored
-- trainer parties, no injected prizes, no capture injection.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local BATTLE_RUNTIME_MODULE = "game.hgss.src.battle.BattleRuntime"
local SCENARIO_FACTORY_MODULE = "libs.hgss.src.battle.HgssBattleScenarioFactory"
local COMMITTER_MODULE = "libs.hgss.src.battle.HgssBattleCommitter"
local SESSION_MODULE = "libs.battle.src.BattleSession"
local EXECUTOR_MODULE = "libs.battle.src.gen4.HgssSessionExecutor"

local T = {
  metadata = {
    capabilities = {},
    derivedAssets = {},
    tags = { "field", "battle", "acceptance" },
  },
  tests = {},
}

---@param name string module path under test
---@param behavior string missing owner under test
---@return table the loaded battle owner
local function requirePresent(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing battle owner: " .. behavior .. " (" .. name .. ")")
  assert(loaded ~= nil, "the battle module loads")
  return loaded --[[@as table]]
end

---@param record table readiness and call counters owned by the test
---@return table headless presentation port acknowledging immediately
local function headlessPort(record)
  return {
    enter = function(_plan)
      record.enters = record.enters + 1
      return true
    end,
    present = function(frame)
      record.frames[#record.frames + 1] = frame
    end,
    leave = function(_plan)
      record.leaves = record.leaves + 1
      return true
    end,
    dispose = function()
      record.disposed = record.disposed + 1
    end,
  }
end

---@param species string
---@param level integer
---@param seed integer
---@param catalog table shared synthetic domain catalog
---@return table full mon-domain record striking with a covered move only
local function foeRecord(species, level, seed, catalog)
  local factory = CatalogFixture.makeFactory(seed, catalog)
  local record = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level }))
  record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return record
end

---@param catalog table shared synthetic domain catalog
---@param leadLevel integer lead level fixing the witness damage band
---@return table party owner holding one fixed lead
local function newPartyOwner(catalog, leadLevel)
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local owner = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x22222222):capture(), catalog:fingerprint()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = 7,
    date = CatalogFixture.metDate(),
  })
  local factory = CatalogFixture.makeFactory(0x33333333, catalog)
  local lead = factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA", level = leadLevel }))
  -- The witness move stays on the implemented path: the acceptance
  -- contract chooses covered moves rather than unsupported mechanics.
  lead.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  Assert.isTrue(owner:addMon(lead), "the acceptance lifetime needs its live party lead")
  return owner
end

---@return table dex knowledge over the acceptance species set
local function newDexOwner()
  local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")
  return PokedexKnowledge.new({ species = { CHIKORITA = true, TOTODILE = true } })
end

---@param money integer pocket money the player record carries
---@return table player record and its validation context
local function playerFacts(money)
  local record = {
    profile = { name = "GOLD", gender = 0, trainerId = 1, money = money, badges = 0 },
    options = { textFrame = 0, textSpeed = "fastest" },
  }
  local context = { charmap = CatalogFixture.CHARMAP, frameIndexes = { [0] = true } }
  return { record = record, context = context }
end

---@param overrides table<string, unknown>|nil
---@return table<string, unknown> native-identity member template
local function nativeMember(overrides)
  local member = {
    species = "CHIKORITA",
    form = 0,
    level = 5,
    difficulty = 3,
    heldItem = "NONE",
    moves = { "TACKLE" },
    friendship = 70,
    identityPolicy = "native_pid",
    identityParams = { genderOverride = 0, abilityOverride = 0, capsule = 0 },
  }
  for key, value in pairs(overrides or {}) do
    member[key] = value
  end
  return member
end

---@param monCatalog table shared synthetic domain catalog
---@return table composed trainer catalog and materializer over synthetic producer data
local function syntheticTrainerComposition(monCatalog)
  local Catalog = requirePresent("libs.hgss.src.battle.HgssTrainerCatalog", "immutable trainer templates")
  local Factory = requirePresent("libs.hgss.src.battle.HgssTrainerFactory", "native trainer materialization")
  -- Class 2 pays rate 4; the ordered party holds one level-4 member, so
  -- a win awards the final level times the native base times the class
  -- rate. A single member keeps the whole materialized party on the
  -- field at once: benched reserves are never sent out by the native
  -- session in this tranche, so only a lone foe can be knocked out
  -- honestly inside the session round bound.
  local compiled = {
    trainers = {
      [8] = {
        trainerClass = 2,
        nameReference = { trainerIndex = 8 },
        party = {
          nativeMember({ species = "TOTODILE", level = 4 }),
        },
        aiPasses = {},
        doubleBattle = false,
        items = {},
        prizeMoney = { trainerClass = 2, classRate = 4 },
      },
    },
    programs = {
      [8] = { key = "field_youngster", revision = "native-1", instructions = {}, entryPoints = {} },
    },
  }
  local catalog = Catalog.new(compiled)
  local factory = Factory.new({
    catalog = catalog,
    monCatalog = monCatalog,
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    game = "heartgold",
    language = "english",
  })
  return { catalog = catalog, factory = factory }
end

---@param fields table<string, unknown> runtime fields backing the launch
---@return table field runtime fake carrying the production battle face
---@return boolean[] input freeze record owned by the test
local function fieldRuntime(fields)
  local battleFlags = {}
  local runtime = setmetatable({
    battleRuntime = nil,
    battlePresentation = nil,
    pendingEncounterId = nil,
    pendingEncounter = nil,
    _lastBattleResult = nil,
    errorText = nil,
    _encounters = nil,
    _launchCounter = nil,
    session = {
      setBattleActive = function(_, active)
        battleFlags[#battleFlags + 1] = active
      end,
    },
    scripts = { worldState = { rng = {} } },
  }, FieldRuntime)
  for key, value in pairs(fields) do
    runtime[key] = value
  end
  return runtime, battleFlags
end

---@param runtime table field runtime owning the battle
---@param budget integer|nil tick bound before a stuck battle fails loudly
local function driveToSettled(runtime, budget)
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local ticks = 0
  while runtime.battleRuntime ~= nil and ticks < (budget or 1200) do
    local battle = runtime.battleRuntime
    local current = battle:status()
    if current.phase == "running" and current.request ~= nil then
      local choices = {}
      for _, actor in ipairs(assert(current.request.actors, "a decision request names its actors")) do
        choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
      end
      local accepted, replyErr = battle:submit(SessionFixture.replyFor(current.request, choices))
      Assert.isTrue(accepted, "a legal decision is accepted: " .. tostring(replyErr))
    end
    runtime:updateBattle()
    ticks = ticks + 1
  end
  Assert.isNil(runtime.battleRuntime, "answered decisions settle the owned lifetime")
end

---@param frames table[] presented frames recorded by the headless port
---@return integer[] damage payloads of native struck frames in order
local function struckDamages(frames)
  local damages = {}
  for _, frame in ipairs(frames) do
    if type(frame) == "table" and frame.kind == "struck" then
      local payload = frame.payload --[[@as table<string, unknown>]]
      assert(type(payload) == "table" and type(payload.damage) == "number", "struck frames carry damage")
      damages[#damages + 1] = payload.damage --[[@as integer]]
    end
  end
  return damages
end

---@param frames table[] presented frames recorded by the headless port
local function assertNativeStrikesOnly(frames)
  local fixed, mechanic, heavy = 0, 0, false
  for _, frame in ipairs(frames) do
    if type(frame) == "table" then
      if frame.kind == "strike" then
        fixed = fixed + 1
      elseif frame.kind == "struck" then
        mechanic = mechanic + 1
        local payload = frame.payload --[[@as table<string, unknown>]]
        if type(payload) == "table" and type(payload.damage) == "number" and payload.damage > 1 then
          heavy = true
        end
      end
    end
  end
  Assert.equal(fixed, 0, "production attacks never settle as fixed one-point strikes")
  Assert.isTrue(mechanic > 0, "production attacks settle through move mechanics")
  Assert.isTrue(heavy, "a real strike with nontrivial combatants deals more than one point")
end

-- A prepared wild encounter carrying a real full wild mon runs
-- the native session/controller path headlessly and returns the field
-- with committed party consequences and released input.
function T.tests.prepared_wild_encounter_runs_native_mechanics_and_returns()
  requirePresent(BATTLE_RUNTIME_MODULE, "application battle lifetime from launch to return")
  requirePresent(SCENARIO_FACTORY_MODULE, "field sources mapped to one detached scenario")
  local Committer = requirePresent(COMMITTER_MODULE, "end-to-end exactly-once result publication")

  local monCatalog = CatalogFixture.makeCatalog()
  local party = newPartyOwner(monCatalog, 20)
  local dex = newDexOwner()
  local facts = playerFacts(3000)
  local foe = foeRecord("TOTODILE", 7, 0x5EED0007, monCatalog)
  local prepared = {
    id = 71,
    mons = { { mon = foe } },
    format = "wild-single",
    environment = { weather = "none" },
  }
  local consumed = {}
  local runtime, battleFlags = fieldRuntime({
    monService = party,
    dexKnowledge = dex,
    playerData = facts.record,
    playerDataContext = facts.context,
    monCatalog = monCatalog,
    pendingEncounterId = 71,
    pendingEncounter = prepared,
    _encounters = {
      consume = function(_, attemptId)
        consumed[#consumed + 1] = attemptId
        return prepared
      end,
    },
  })
  local leadBefore = party:partyMon(0).condition.currentHp

  local launchId = "launch-wild-field-1"
  local portRecord = { enters = 0, frames = {}, leaves = 0, disposed = 0 }
  -- No attempt identity rides the request: the held preparation is
  -- consumed exactly once through the normal wild launch path.
  runtime:startBattle({
    request = { id = launchId, kind = "wild", payload = { species = "TOTODILE", level = 7 } },
    presentation = headlessPort(portRecord),
    seed = 0xB1AC0007,
  })
  Assert.deepEqual(consumed, { 71 }, "the launch consumes the held preparation exactly once")
  Assert.deepEqual(battleFlags, { true }, "the launch freezes field input")
  local opening = runtime:battleStatus(launchId)
  Assert.notNil(opening, "the owned battle reports its launch identity")
  Assert.isNil(runtime:battleStatus("no-such-launch"), "unknown identities report no battle")

  driveToSettled(runtime)
  Assert.isNil(runtime.errorText, "the wild battle settles without faulting the field")
  Assert.deepEqual(
    battleFlags,
    { true, false },
    "terminal disposal freezes exactly once, then releases"
  )
  Assert.deepEqual(
    runtime:lastBattleResult(),
    { result = "win", sourceResult = 1 },
    "the committed wild win reports its outcome words"
  )
  local receipt = Committer.receipt(launchId)
  Assert.notNil(receipt, "settlement records its commit receipt")
  Assert.isTrue(receipt.committed, "the receipt proves publication, not simulation alone")
  Assert.deepEqual(receipt.rewards, {}, "a wild win invents no prize")
  Assert.isNil(receipt.player, "a wild win moves no money")
  local leadAfter = party:partyMon(0).condition.currentHp
  Assert.isTrue(leadAfter > 0, "the live lead survives the executed battle")
  Assert.isTrue(leadAfter < leadBefore, "executed damage writes back through the live party owner")
  Assert.equal(party:partyCount(), 1, "no capture is invented on the attack path")
  Assert.isTrue(dex:isSeen("TOTODILE"), "the fought foe registers seen knowledge")
  assertNativeStrikesOnly(portRecord.frames)
  Assert.isTrue(portRecord.enters >= 1, "entry presents through the port")
  Assert.equal(portRecord.disposed, 1, "terminal disposal releases presentation exactly once")
end

-- A native trainer identity with no caller party or prize
-- materializes its source party, executes natively, pays the exact native
-- prize once, and returns the field with released input.
function T.tests.native_trainer_identity_materializes_pays_and_returns()
  requirePresent(BATTLE_RUNTIME_MODULE, "application battle lifetime from launch to return")
  requirePresent(SCENARIO_FACTORY_MODULE, "field sources mapped to one detached scenario")
  local Committer = requirePresent(COMMITTER_MODULE, "end-to-end exactly-once result publication")

  local monCatalog = CatalogFixture.makeCatalog()
  -- The lead outranks the lone compiled member far enough to knock it
  -- out with real damage inside the session round bound: no fixture
  -- health or outcome is ever staged to force the win.
  local party = newPartyOwner(monCatalog, 25)
  local dex = newDexOwner()
  local facts = playerFacts(3000)
  local composition = syntheticTrainerComposition(monCatalog)
  local runtime, battleFlags = fieldRuntime({
    monService = party,
    dexKnowledge = dex,
    playerData = facts.record,
    playerDataContext = facts.context,
    monCatalog = monCatalog,
    _trainerCatalog = composition.catalog,
    _trainerFactory = composition.factory,
  })

  local launchId = "launch-trainer-field-1"
  local portRecord = { enters = 0, frames = {}, leaves = 0, disposed = 0 }
  -- The launch carries the numeric trainer identity only: the compiled
  -- party, controller program, and prize facts all resolve inside the
  -- production trainer path. The trainers-array shape carries the same
  -- bare identity the single-trainer form would; the launch validator
  -- only accepts trainer identities as strings or inside that array, so
  -- the array keeps the witness on a supported request shape (see notes).
  runtime:startBattle({
    request = { id = launchId, kind = "trainer", payload = { trainers = { { id = 8 } } } },
    presentation = headlessPort(portRecord),
    seed = 0xB1AC0008,
  })
  Assert.deepEqual(battleFlags, { true }, "the trainer launch freezes field input")
  Assert.notNil(runtime:battleStatus(launchId), "the owned trainer battle reports its launch identity")

  driveToSettled(runtime)
  Assert.isNil(
    runtime.errorText,
    "the trainer battle settles without faulting the field: " .. tostring(runtime.errorText)
  )
  Assert.deepEqual(battleFlags, { true, false }, "the trainer return releases field input")
  Assert.deepEqual(
    runtime:lastBattleResult(),
    { result = "win", sourceResult = 1 },
    "the committed trainer win reports win with the won source word"
  )
  local receipt = Committer.receipt(launchId)
  Assert.notNil(receipt, "the trainer settlement records its commit receipt")
  Assert.isTrue(receipt.committed, "the trainer receipt proves publication")
  -- Independently fixed expectation: the final party level (4) times the
  -- native base (4) times the compiled class rate (4) is 64, even though
  -- the lead party member outranks it.
  Assert.equal(receipt.rewards.amount, 64, "the prize uses the final party level and class rate")
  Assert.equal(receipt.player.profile.money, 3064, "the receipt carries the credited money candidate")
  Assert.equal(facts.record.profile.money, 3000, "staging never touches the input record")
  Assert.isTrue(dex:isSeen("TOTODILE"), "the materialized party member registers seen knowledge")
  assertNativeStrikesOnly(portRecord.frames)
  Assert.equal(portRecord.disposed, 1, "trainer teardown releases presentation exactly once")
end

-- The same fixed seed and decisions replay the same semantic stream:
-- result words, native damage sequence, and reward facts all match.
function T.tests.same_seed_replays_the_same_semantic_stream()
  requirePresent(BATTLE_RUNTIME_MODULE, "application battle lifetime from launch to return")
  local Committer = requirePresent(COMMITTER_MODULE, "end-to-end exactly-once result publication")

  ---@param launchId string distinct launch identity per replay leg
  ---@return table last battle result, integer[] struck damages, table receipt rewards
  local function runWildLeg(launchId)
    local monCatalog = CatalogFixture.makeCatalog()
    local party = newPartyOwner(monCatalog, 20)
    local foe = foeRecord("TOTODILE", 7, 0x5EED0007, monCatalog)
    local prepared = {
      id = 71,
      mons = { { mon = foe } },
      format = "wild-single",
      environment = { weather = "none" },
    }
    local runtime = fieldRuntime({
      monService = party,
      dexKnowledge = newDexOwner(),
      monCatalog = monCatalog,
      pendingEncounterId = 71,
      pendingEncounter = prepared,
      _encounters = {
        consume = function()
          return prepared
        end,
      },
    })
    local portRecord = { enters = 0, frames = {}, leaves = 0, disposed = 0 }
    runtime:startBattle({
      request = { id = launchId, kind = "wild", payload = { species = "TOTODILE", level = 7 } },
      presentation = headlessPort(portRecord),
      seed = 0xB1AC0007,
    })
    driveToSettled(runtime)
    Assert.isNil(runtime.errorText, "each replay leg settles without faulting the field")
    return {
      result = runtime:lastBattleResult(),
      damages = struckDamages(portRecord.frames),
      rewards = Committer.receipt(launchId).rewards,
    }
  end

  local first = runWildLeg("launch-wild-replay-a")
  local second = runWildLeg("launch-wild-replay-b")
  Assert.deepEqual(second.result, first.result, "the replay reports the same outcome words")
  Assert.deepEqual(second.damages, first.damages, "the replay deals the same native damage sequence")
  Assert.deepEqual(second.rewards, first.rewards, "the replay stages the same reward facts")
  Assert.isTrue(#first.damages > 0, "the compared stream exercises real strikes")
end

-- An unknown native trainer identity fails preparation before any battle
-- owns the field: no lifetime starts, input never freezes, and no result
-- or fault is recorded.
function T.tests.unknown_trainer_identity_fails_without_freezing_the_field()
  local monCatalog = CatalogFixture.makeCatalog()
  local composition = syntheticTrainerComposition(monCatalog)
  local runtime, battleFlags = fieldRuntime({
    monService = newPartyOwner(monCatalog, 25),
    monCatalog = monCatalog,
    _trainerCatalog = composition.catalog,
    _trainerFactory = composition.factory,
  })
  local ok, err = pcall(runtime.startBattle, runtime, {
    request = { id = "launch-unknown-trainer", kind = "trainer", payload = { trainers = { { id = 9999 } } } },
  })
  Assert.isFalse(ok, "an unknown trainer identity fails preparation")
  local message = tostring(err):lower()
  Assert.isTrue(message:find("9999", 1, true) ~= nil, "the failure names the missing identity")
  Assert.isTrue(message:find("unknown", 1, true) ~= nil, "the failure reports an unknown trainer")
  Assert.isNil(runtime.battleRuntime, "no battle lifetime starts for an unknown trainer")
  Assert.deepEqual(battleFlags, {}, "preparation failure never freezes field input")
  Assert.isNil(runtime:lastBattleResult(), "a failed preparation records no outcome words")
  Assert.isNil(runtime.errorText, "a refused launch is not a field fault")
end

-- Static composition guard: these fixtures never select the scripted
-- scaffold executor. The scaffold marker exists, the native executor
-- differs from it, and factory-built scenarios carry no executor
-- selection for tests to override.
function T.tests.acceptance_fixtures_never_select_the_scripted_scaffold()
  local BattleSession = requirePresent(SESSION_MODULE, "common session entry seam")
  local Executor = requirePresent(EXECUTOR_MODULE, "native HGSS session executor")
  local ScenarioFactory = requirePresent(SCENARIO_FACTORY_MODULE, "field sources mapped to one detached scenario")
  Assert.equal(
    BattleSession.EXECUTABLE_RULESET,
    "test:scripted",
    "the scaffold marker stays the documented scripted value"
  )
  Assert.isTrue(
    Executor.RULESET ~= BattleSession.EXECUTABLE_RULESET,
    "the native executor never selects the scripted scaffold"
  )
  local wild = ScenarioFactory.fromEncounter({ species = "TOTODILE", level = 4 }, {})
  Assert.isNil(wild.ruleset, "wild fixtures carry no executor selection")
  local trainer = ScenarioFactory.fromTrainer({
    id = "launch-static-trainer",
    trainers = {
      {
        id = 8,
        party = { foeRecord("TOTODILE", 4, 0xB1AC0009, CatalogFixture.makeCatalog()) },
        program = { key = "field", revision = "native-1", instructions = {}, entryPoints = {} },
      },
    },
  }, {})
  Assert.isNil(trainer.ruleset, "trainer fixtures carry no executor selection")
end

return T
