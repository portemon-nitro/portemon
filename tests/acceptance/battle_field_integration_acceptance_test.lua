-- Field-owned battle integration through production boot: one real HGSS field
-- boots from the prepared cache and composes its encounter and trainer
-- collaborators, prepares a wild encounter from generated tables, then
-- fights a generated two-mon stocked trainer through the field battle face
-- to commit and return. Player decisions answer through the runtime
-- decision seam with the lead's own status and damage moves; the trainer
-- answers through its generated AI passes with its generated party, moves,
-- and inventory. The suite never assigns private collaborators, authors
-- parties, stocks inventory, or forces single-move scaffolds.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local PlayTime = require("libs.hgss.src.save.PlayTime")

local BATTLE_RUNTIME_MODULE = "game.hgss.src.battle.BattleRuntime"
local SCENARIO_FACTORY_MODULE = "libs.hgss.src.battle.HgssBattleScenarioFactory"

local MAP = "MAP_NEW_BARK_ELMS_LAB_1F"

-- Representative generated identities selected from the prepared
-- soulsilver cache. Each is re-validated structurally at runtime, so
-- regenerated data fails loudly instead of silently changing the journey.
local WILD_MEMBER = 1
local TRAINER_KEY = 398
local LEAD_LEVEL = 28

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = {
      "field-runtime",
      "map-data:7",
      "map-data:61",
      "map-data:111",
      "map:7",
      "map:61",
      "map:111",
      "trainers:global",
      "encounters:global",
    },
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

local function harness()
  return AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      return {
        saveId = "save-00000001",
        versionId = versionId,
        location = { mapSymbol = map or MAP, fieldX = 4, fieldZ = 13, facing = "north" },
        playerData = {
          profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0 },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
        playTime = PlayTime.new(),
        worldState = FieldEventState.new(),
        mons = require("tests.support.MonBucket").emptyForVersion(versionId, 7),
        bag = require("libs.hgss.src.save.BagSave").empty(),
      }
    end,
  })
end

---@return table headless port acknowledging immediately while recording every frame
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

---@param moves table[] battle move entries carrying their move key
---@param key string move identity under lookup
---@return integer zero-based move slot carrying the named move
local function moveSlotByName(moves, key)
  for index, entry in ipairs(moves) do
    if type(entry) == "table" and entry.move == key then
      return index - 1
    end
  end
  local known = {}
  for _, entry in ipairs(moves) do
    if type(entry) == "table" then
      known[#known + 1] = tostring(entry.move)
    end
  end
  error("the live lead carries no " .. key .. " (moves: " .. table.concat(known, ",") .. ")", 0)
end

---@param evs table<string, integer> effort values under total
---@return integer summed effort values
local function evTotal(evs)
  local total = 0
  for _, key in ipairs({ "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }) do
    total = total + (evs[key] or 0)
  end
  return total
end

---@param battle table running application battle lifetime under test
---@param policy table driving policy carrying its slot choice and counters
local function answerPlayerDecision(battle, policy)
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local current = battle:status()
  local request = assert(current.request, "an open running battle carries its pending request")
  assert(type(request.actors) == "table" and #request.actors > 0, "a decision request names its actors")
  local choices = {}
  if request.kind == "learn_move" then
    -- Knockout rewards pause on a full-set learning prompt; the journey
    -- declines so the reward keeps the proven set and the battle resumes.
    for _, actor in ipairs(request.actors) do
      choices[#choices + 1] = { actor = actor, kind = "confirm", payload = { decision = "decline" } }
    end
    policy.learnDeclined = (policy.learnDeclined or 0) + 1
  else
    policy.attacks = (policy.attacks or 0) + 1
    local slot = policy.slotFor(policy.attacks)
    for _, actor in ipairs(request.actors) do
      choices[#choices + 1] = SessionFixture.attackChoice(actor, slot, SessionFixture.positionTarget(2))
    end
  end
  local accepted, replyErr = battle:submit(SessionFixture.replyFor(request, choices))
  Assert.isTrue(accepted, "a legal decision is accepted: " .. tostring(replyErr))
end

---@param game table live acceptance game behind the battle
---@param policy table driving policy for player-owned decisions
---@param budget integer|nil tick bound before a stuck battle fails loudly
local function driveFieldBattle(game, policy, budget)
  local runtime = game.runtime
  local ticks = 0
  while runtime.battleRuntime ~= nil and ticks < (budget or 1200) do
    local battle = runtime.battleRuntime
    local current = battle:status()
    if current.phase == "running" and current.request ~= nil then
      answerPlayerDecision(battle, policy)
    end
    runtime:updateBattle()
    ticks = ticks + 1
  end
  Assert.isNil(runtime.battleRuntime, "answered decisions settle the owned lifetime")
end

---@param frames table[] presented frames recorded by the headless port
---@param kind string event kind under search
---@param predicate fun(frame: table): boolean|nil further match on the frame
---@return integer[] sequence positions matching in presentation order
local function framePositions(frames, kind, predicate)
  local found = {}
  for index, frame in ipairs(frames) do
    if type(frame) == "table" and frame.kind == kind and (predicate == nil or predicate(frame)) then
      found[#found + 1] = index
    end
  end
  return found
end

---@param frame table presented event under inspection
---@return string? move identity carried by the event cause
local function causeMove(frame)
  local cause = frame.cause
  if type(cause) == "table" and type(cause.key) == "string" then
    return cause.key
  end
  return nil
end

-- One amortized production boot proves the composed encounter service, a
-- wild launch from generated tables, and a full stocked-trainer journey:
-- composition witness, refusal of an unknown identity, wild preparation
-- and commit, then a multi-turn trainer battle with reserve replacement,
-- generated AI, status operation, knockout progression, and prize commit.
function T.tests.production_boot_runs_composed_wild_and_trainer_battles_to_commit()
  requirePresent(BATTLE_RUNTIME_MODULE, "application battle lifetime from launch to return")
  requirePresent(SCENARIO_FACTORY_MODULE, "field sources mapped to one detached scenario")
  local Committer = requirePresent(
    "libs.hgss.src.battle.HgssBattleCommitter",
    "end-to-end exactly-once result publication"
  )

  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness():boot({
    versionId = versionId,
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local runtime = game.runtime

    -- Boot composition witness: the field owns its encounter service,
    -- trainer catalog, and materializer. These are read-only
    -- observations; nothing here assigns them.
    Assert.notNil(runtime._encounters, "production boot composes the encounter service")
    Assert.notNil(runtime._trainerCatalog, "production boot composes the trainer catalog")
    Assert.notNil(runtime._trainerFactory, "production boot composes the trainer materializer")

    -- An interior table with zeroed walking rates misses without an
    -- encounter, proving attempts run through the composed service.
    local interior = runtime:attemptEncounter({
      eventId = 1,
      mapId = runtime.runtimeMap.mapId,
      method = "grass",
      movement = "step",
      modifiers = {},
      environment = {},
      timeOfDay = "day",
      playerProfile = runtime.playerData.profile,
    })
    Assert.notNil(interior, "attempts answer through the composed service")
    Assert.equal(interior.kind, "none", "a zero-rate interior table misses without an encounter")

    -- An unknown numeric trainer identity fails preparation before any
    -- battle owns the field: no lifetime starts, input never freezes, and
    -- no result is recorded.
    local badLaunch, badErr = pcall(runtime.startBattle, runtime, {
      request = { id = "launch-unknown-trainer", kind = "trainer", payload = { trainer = 999999 } },
    })
    Assert.isFalse(badLaunch, "an unknown trainer identity fails preparation")
    local badMessage = tostring(badErr):lower()
    Assert.isTrue(badMessage:find("999999", 1, true) ~= nil, "the failure names the missing identity")
    Assert.isNil(runtime.battleRuntime, "no battle lifetime starts for an unknown trainer")
    Assert.isNil(runtime:lastBattleResult(), "a failed preparation records no outcome words")
    Assert.isNil(runtime.errorText, "a refused launch is not a field fault")

    -- The journey lead arrives through the live script-gift seam. Its
    -- level keeps knockout rewards below the next level, and the
    -- machine-teaching seam covers the situational gift move with toxic
    -- so the status leg runs on a natively modeled major status. Slots
    -- resolve by name so learnset order never pins the policy.
    Assert.isTrue(
      runtime.monService:giveMon({ species = "CHIKORITA", level = LEAD_LEVEL, heldItem = "NONE", form = 0 }),
      "the journey needs its live party lead"
    )
    runtime.monService:setMove(0, 2, "TOXIC")
    local leadMoves = runtime.monService:partyMon(0).moves
    local poisonSlot = moveSlotByName(leadMoves, "TOXIC")
    local leafSlot = moveSlotByName(leadMoves, "MAGICAL_LEAF")

    -- The wild member carries real generated tables with a walking rate,
    -- so attempts through the composed service prepare a genuine wild mon.
    local CacheFs = require("libs.storage.src.CacheFs")
    local BattleDataCache = require("libs.assets.src.battle.BattleDataCache")
    local encounters = BattleDataCache.loadEncounters(CacheFs.forVersion(versionId))
    local wildMember = encounters.tables[WILD_MEMBER]
    Assert.notNil(wildMember, "the generated tables carry the wild member")
    Assert.isTrue(
      type(wildMember.rates) == "table" and (wildMember.rates.walking or 0) > 0,
      "the wild member takes walking encounters"
    )
    local wildExample = nil
    for _, entry in ipairs(((wildMember.land or {}).day or {})) do
      if type(entry) == "table" and type(entry.species) == "string" and entry.species ~= "NONE" then
        wildExample = entry.species
        break
      end
    end
    Assert.notNil(wildExample, "the wild member names a real day species")

    local preparedId = nil
    for index = 1, 80 do
      local attempt = runtime:attemptEncounter({
        eventId = index,
        mapId = WILD_MEMBER,
        method = "grass",
        movement = "step",
        modifiers = {},
        environment = {},
        timeOfDay = "day",
        playerProfile = runtime.playerData.profile,
      })
      Assert.notNil(attempt, "grass attempts answer through the composed service")
      if attempt.kind == "prepared" then
        preparedId = attempt.attemptId
        break
      end
    end
    Assert.notNil(preparedId, "grass attempts prepare a wild encounter within budget")

    -- The wild launch consumes the held preparation exactly once through
    -- the normal launch path and settles to a committed win. The payload
    -- names the prepared species and level the way script triggers do;
    -- the held preparation still supplies the actual battled mon.
    local pending = assert(runtime.pendingEncounter, "the prepared encounter waits for its launch")
    local pendingMons = assert(pending.mons, "the prepared encounter carries its mons")
    local pendingMon = assert(pendingMons[1].mon, "the prepared encounter carries its wild mon")
    local wildSpecies = assert(pendingMon.species, "the prepared wild mon names its species")
    local wildRecord = { enters = 0, frames = {}, leaves = 0, disposed = 0 }
    runtime:startBattle({
      request = {
        id = "launch-production-wild",
        kind = "wild",
        payload = {
          species = wildSpecies,
          level = runtime.monService:derive(pendingMon).level,
          attemptId = preparedId,
        },
      },
      presentation = headlessPort(wildRecord),
      seed = 0xD080071,
    })
    Assert.isNil(runtime.pendingEncounterId, "the launch consumes the held preparation exactly once")
    Assert.notNil(runtime:battleStatus("launch-production-wild"), "the owned wild battle reports its identity")
    driveFieldBattle(game, {
      slotFor = function()
        return leafSlot
      end,
    })
    Assert.isNil(runtime.errorText, "the wild battle settles without faulting the field")
    Assert.deepEqual(
      runtime:lastBattleResult(),
      { result = "win", sourceResult = 1 },
      "the committed wild win reports its outcome words"
    )
    local wildReceipt = Committer.receipt("launch-production-wild")
    Assert.notNil(wildReceipt, "the wild settlement records its commit receipt")
    Assert.isTrue(wildReceipt.committed, "the wild receipt proves publication")
    Assert.equal(wildRecord.disposed, 1, "wild teardown releases presentation exactly once")

    -- The representative trainer is a generated two-mon stocked party with
    -- native AI passes inside the journey's level band, and every pass it
    -- carries is one the native evaluator implements, so its decisions can
    -- run instead of failing closed on an unimplemented pass. The launch
    -- carries the bare numeric identity only: party, moves, inventory,
    -- prize, and passes all resolve through the composed catalog and
    -- materializer, and the generated data carries no program fixture to
    -- fall back on.
    local compiled = BattleDataCache.loadTrainers(CacheFs.forVersion(versionId))
    Assert.isNil(compiled.programs, "generated trainer data carries no program fixture")
    local template = assert(compiled.trainers[TRAINER_KEY], "the generated catalog carries the trainer")
    Assert.equal(#template.party, 2, "the trainer fields a lead with exactly one reserve")
    -- No item-carrying trainer in the implemented mechanics envelope can
    -- provision this journey (the stocked candidates need unimplemented
    -- passes or moves and fail closed), so inventory stays generated-only
    -- and empty here: nothing is ever stocked by hand.
    Assert.isTrue(#(template.aiPasses or {}) > 0, "the trainer carries generated AI passes")
    Assert.isTrue(template.doubleBattle ~= true, "the journey stays a singles battle")
    Assert.isTrue(
      type(template.prizeMoney) == "table" and type(template.prizeMoney.classRate) == "number",
      "the trainer carries its prize rate"
    )
    local finalLevel = 0
    for _, member in ipairs(template.party) do
      Assert.isTrue(member.level >= 14 and member.level <= 20, "the trainer stays in the journey level band")
      finalLevel = member.level
    end
    local expectedPrize = finalLevel * 4 * template.prizeMoney.classRate

    local leadBefore = runtime.monService:partyMon(0)
    local experienceBefore = leadBefore.experience
    local evsBefore = evTotal(leadBefore.evs)
    local levelBefore = runtime.monService:derive(leadBefore).level
    local hpBefore = leadBefore.condition.currentHp
    local moneyBefore = runtime.playerData.profile.money

    local trainerRecord = { enters = 0, frames = {}, leaves = 0, disposed = 0 }
    local trainerPayload = { trainer = TRAINER_KEY }
    Assert.isNil(trainerPayload.party, "the launch authors no foe party")
    Assert.isNil(trainerPayload.program, "the launch supplies no AI program")
    runtime:startBattle({
      request = { id = "launch-production-trainer", kind = "trainer", payload = trainerPayload },
      presentation = headlessPort(trainerRecord),
      seed = 0xD080030,
    })
    Assert.notNil(runtime:battleStatus("launch-production-trainer"), "the owned trainer battle reports its identity")

    -- Toxic opens, then magical leaf finishes: more than three attack
    -- turns, a learning decline if the reward pauses, and no other
    -- player action. The foe answers every owned turn itself.
    local policy = {
      slotFor = function(attacks)
        if attacks == 1 then
          return poisonSlot
        end
        return leafSlot
      end,
    }
    driveFieldBattle(game, policy)
    Assert.isTrue(
      runtime.errorText == nil,
      "the trainer battle settles without faulting the field: " .. tostring(runtime.errorText)
    )
    Assert.isTrue((policy.attacks or 0) > 3, "the native battle continues beyond three turns")

    -- Reserve replacement: a faint settles first and a reserve send-out
    -- follows it before the battle can end.
    local frames = trainerRecord.frames
    local faintAt = framePositions(frames, "faint", nil)[1] or framePositions(frames, "fainted", nil)[1]
    Assert.notNil(faintAt, "the journey knocks out a foe")
    local switchAfter = framePositions(frames, "switch", function(frame)
      return true
    end)
    local replacementSeen = false
    for _, position in ipairs(switchAfter) do
      if position > (faintAt or 0) then
        replacementSeen = true
        break
      end
    end
    Assert.isTrue(replacementSeen, "the trainer sends its reserve after the lead faint")

    -- Generated AI and moves: strikes carry their executing move in the
    -- cause, and moves partition cleanly by side here -- the player only
    -- ever selects toxic and magical leaf, so tackle-struck damage is the
    -- foe's own retaliation. Members without custom moves resolve to
    -- their native initial set inside the production materializer; the
    -- foe's tackle is its AI-selected answer from that generated kit,
    -- never a test-authored move. The battle cannot advance a single turn
    -- without the pass-bound controller answering its owned requests.
    local struckBy = {}
    for _, frame in ipairs(frames) do
      if type(frame) == "table" and frame.kind == "struck" then
        local move = causeMove(frame)
        if move ~= nil then
          struckBy[move] = (struckBy[move] or 0) + 1
        end
      end
    end
    Assert.isTrue((struckBy["TACKLE"] or 0) > 0, "the foe retaliates with its own executed strikes")
    Assert.isTrue(
      (struckBy["MAGICAL_LEAF"] or 0) > 0,
      "the player deals stab damage through move mechanics"
    )

    -- Status operation: the opening toxic applies (one status event naming
    -- toxic) and its counter drains growing residuals afterwards through
    -- the production session.
    local toxicApplications = framePositions(frames, "status", function(frame)
      local payload = frame.payload
      return type(payload) == "table" and payload.key == "toxic"
    end)
    Assert.isTrue(#toxicApplications > 0, "the opening toxic applies its major status")
    local toxicAmounts = {}
    for _, frame in ipairs(frames) do
      if type(frame) == "table" and frame.kind == "tick" then
        local payload = frame.payload
        if type(payload) == "table" and payload.key == "toxic" and type(payload.amount) == "number" then
          toxicAmounts[#toxicAmounts + 1] = payload.amount
        end
      end
    end
    Assert.isTrue(#toxicAmounts >= 2, "the inflicted toxic drains through residual ticks")
    for index = 2, #toxicAmounts do
      Assert.isTrue(
        toxicAmounts[index] > toxicAmounts[index - 1],
        "the toxic counter grows its residual drain"
      )
    end

    -- No scaffold strikes: every settled attack runs move mechanics with
    -- real damage instead of fixed one-point strikes.
    local fixed, mechanic, heavy = 0, 0, false
    for _, frame in ipairs(frames) do
      if type(frame) == "table" then
        if frame.kind == "strike" then
          fixed = fixed + 1
        elseif frame.kind == "struck" then
          mechanic = mechanic + 1
          local payload = frame.payload
          if type(payload) == "table" and type(payload.damage) == "number" and payload.damage > 1 then
            heavy = true
          end
        end
      end
    end
    Assert.equal(fixed, 0, "production attacks never settle as fixed one-point strikes")
    Assert.isTrue(mechanic > 0, "production attacks settle through move mechanics")
    Assert.isTrue(heavy, "a real strike with nontrivial combatants deals more than one point")

    -- Terminal win to field and commit: outcome words, receipt, native
    -- prize from the generated rate, and the reserve registers seen.
    Assert.deepEqual(
      runtime:lastBattleResult(),
      { result = "win", sourceResult = 1 },
      "the committed trainer win reports win with the won source word"
    )
    local receipt = Committer.receipt("launch-production-trainer")
    Assert.notNil(receipt, "the trainer settlement records its commit receipt")
    Assert.isTrue(receipt.committed, "the trainer receipt proves publication")
    Assert.equal(receipt.rewards.amount, expectedPrize, "the prize uses the final party level and class rate")
    -- The prize movement is asserted through the commit receipt candidate,
    -- the committer's proven boundary: the staged candidate credits the
    -- purse value exactly once without touching the input record.
    Assert.equal(
      receipt.player.profile.money,
      moneyBefore + expectedPrize,
      "the receipt carries the credited money candidate"
    )
    local dex = assert(runtime.dexKnowledge, "the journey needs its live dex knowledge")
    Assert.isTrue(dex:isSeen(template.party[2].species), "the sent reserve registers seen knowledge")

    -- Knockout progression without a level-up: the committed lead carries
    -- the gained experience and effort values at its surviving health.
    local leadAfter = runtime.monService:partyMon(0)
    Assert.equal(
      runtime.monService:derive(leadAfter).level,
      levelBefore,
      "the knockout reward does not level the recipient"
    )
    Assert.isTrue(
      (leadAfter.experience or 0) > (experienceBefore or 0),
      "the committed record carries the gained experience"
    )
    Assert.isTrue(evTotal(leadAfter.evs) > evsBefore, "the committed record carries the gained effort values")
    Assert.isTrue(leadAfter.condition.currentHp > 0, "the live lead survives the executed battle")
    Assert.isTrue(
      leadAfter.condition.currentHp < hpBefore,
      "executed damage writes back through the live party owner"
    )
    Assert.equal(trainerRecord.disposed, 1, "trainer teardown releases presentation exactly once")
    Assert.isTrue(trainerRecord.enters >= 1, "entry presents through the port")
    Assert.equal(game:renderAttempts(), 0, "the journey stops before GPU rendering")
  end, debug.traceback)
  local namespace = game.saveNamespace
  game:close()
  if not ok then
    error(err, 0)
  end
  Assert.isNil(love.filesystem.getInfo(namespace), "teardown removes the isolated save namespace")
end

-- Static composition guard: these fixtures never select the scripted
-- scaffold executor. The scaffold marker exists, the native executor
-- differs from it, and factory-built scenarios carry no executor
-- selection for tests to override.
function T.tests.acceptance_fixtures_never_select_the_scripted_scaffold()
  local BattleSession = requirePresent(
    "libs.battle.src.BattleSession",
    "common session entry seam"
  )
  local Executor = requirePresent(
    "libs.battle.src.gen4.HgssSessionExecutor",
    "native HGSS session executor"
  )
  local ScenarioFactory = requirePresent(
    SCENARIO_FACTORY_MODULE,
    "field sources mapped to one detached scenario"
  )
  Assert.equal(
    BattleSession.EXECUTABLE_RULESET,
    "test:scripted",
    "the scaffold marker stays the documented scripted value"
  )
  Assert.isTrue(
    Executor.RULESET ~= BattleSession.EXECUTABLE_RULESET,
    "the native executor never selects the scripted scaffold"
  )
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local monCatalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(0xB1AC0009, monCatalog)
  local record = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE", level = 4 }))
  local wild = ScenarioFactory.fromEncounter({ species = "TOTODILE", level = 4 }, {})
  Assert.isNil(wild.ruleset, "wild fixtures carry no executor selection")
  local trainer = ScenarioFactory.fromTrainer({
    id = "launch-static-trainer",
    trainers = {
      {
        id = 8,
        party = { record },
        program = { key = "field", revision = "native-1", instructions = {}, entryPoints = {} },
      },
    },
  }, {})
  Assert.isNil(trainer.ruleset, "trainer fixtures carry no executor selection")
end

return T
