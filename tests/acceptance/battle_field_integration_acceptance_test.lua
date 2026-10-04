-- Full production battle journey through one real HGSS field boot: a young
-- opener and a veteran prove voluntary switching there and back, a failed
-- ball throw, faint-driven replacement, and live Bag healing across two
-- generated wild battles; then the veteran solos a generated three-mon
-- stocked singles trainer while a benched Exp Share holder levels into a
-- move-learning prompt, and a final wild capture lands through a guaranteed
-- ball. Every battle launches through FieldRuntime, every player decision
-- answers through the runtime decision seam, the trainer answers through
-- its generated AI with its generated party, moves, and inventory, and
-- every consequence publishes through the battle committer. The suite
-- never assigns private collaborators, authors parties, stocks inventory
-- by hand, or forces single-move scaffolds.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local PlayTime = require("libs.hgss.src.save.PlayTime")

local BATTLE_RUNTIME_MODULE = "game.hgss.src.battle.BattleRuntime"
local SCENARIO_FACTORY_MODULE = "libs.hgss.src.battle.HgssBattleScenarioFactory"

local MAP = "MAP_NEW_BARK_ELMS_LAB_1F"

-- Generated identities re-validated structurally at runtime, so regenerated
-- data fails loudly instead of silently changing the journey.
local WILD_MEMBER = 1
-- A generated singles route trainer chosen for journey semantics: it leads
-- SCYTHER at 17 with KAKUNA and METAPOD at 15 behind it, carries exactly
-- one SUPER_POTION, and needs no story state to resolve in an isolated
-- boot. Three opponents force two enemy reserve replacements, the single
-- healing stock makes use-then-depletion observable, and the mid-teens band
-- lets a level-28 veteran wound without one-shotting so the stock is used.
local TRAINER_KEY = 21
-- A generated native-double route trainer chosen for the same journey
-- semantics: two level-10 openers it fields together, no story state to
-- resolve in an isolated boot, and a two-mon party so both enemies open
-- and no enemy reserve replacement enters the leg. The mid-journey party
-- (a level-28 veteran beside a teenager) closes it without scripting.
local DOUBLE_TRAINER_KEY = 10
local VETERAN_LEVEL = 28
local OPENER_LEVEL = 6
local LEARNER_LEVEL = 11

local WILD_SEED_ONE = 0xD080071
local WILD_SEED_TWO = 0xD080072
local TRAINER_SEED = 0xD080030
local DOUBLE_SEED = 0xD080074
local CAPTURE_SEED = 0xD080073

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
  error("the live party carries no " .. key .. " (moves: " .. table.concat(known, ",") .. ")", 0)
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

---@param request table<string, unknown> pending player decision under inspection
---@param wanted string choice kind under search
---@return boolean true when the request admits the kind
local function admits(request, wanted)
  local legal = request.legalChoices
  if type(legal) ~= "table" or type(legal.kinds) ~= "table" then
    return false
  end
  for _, kind in ipairs(legal.kinds) do
    if kind == wanted then
      return true
    end
  end
  return false
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

---@param game table live acceptance game behind the battle
---@param choose fun(request: table, turn: integer): table|table[] decision choice for the open
--- request, or one choice per addressed actor in actor order for multi-actor batches
---@param budget integer|nil tick bound before a stuck battle fails loudly
---@return integer answered player turns before the lifetime settled
local function runLeg(game, choose, budget)
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local runtime = game.runtime
  local turn = 0
  local ticks = 0
  while runtime.battleRuntime ~= nil and ticks < (budget or 1200) do
    local battle = runtime.battleRuntime
    local current = battle:status()
    if current.phase == "running" and current.request ~= nil then
      turn = turn + 1
      local answer = choose(current.request, turn)
      local choices = answer
      if type(answer) == "table" and answer.kind ~= nil then
        choices = { answer }
      end
      assert(type(choices) == "table", "decision drivers answer with a choice record or a choice array")
      local actors = assert(current.request.actors, "player decisions address their combatants")
      Assert.equal(#choices, #actors, "every addressed actor answers exactly once")
      for index, actor in ipairs(actors) do
        Assert.isTrue(choices[index].actor == actor, "replies preserve their addressed actor records in order")
      end
      local accepted, replyErr = battle:submit(SessionFixture.replyFor(current.request, choices))
      Assert.isTrue(accepted, "a legal decision is accepted: " .. tostring(replyErr))
    end
    runtime:updateBattle()
    ticks = ticks + 1
  end
  Assert.isNil(runtime.battleRuntime, "answered decisions settle the owned lifetime")
  return turn
end

---@param game table live acceptance game behind the journey
---@param firstEvent integer first event identity for the attempt scan
---@return integer attempt identity holding a prepared wild encounter
local function prepareWild(game, firstEvent)
  local runtime = game.runtime
  for index = firstEvent, firstEvent + 99 do
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
      return assert(attempt.attemptId, "a prepared attempt carries its identity")
    end
  end
  error("grass attempts prepare a wild encounter within budget", 0)
end

-- One amortized production boot proves the composed encounter service, two
-- wild legs (voluntary switching with a failed ball throw, then faint
-- replacement with live Bag healing), a full stocked-trainer journey with
-- trainer item use and benched move learning, and a final guaranteed
-- capture: every leg commits through the committer exactly once.
function T.tests.production_boot_runs_wild_trainer_and_capture_legs_to_commit()
  requirePresent(BATTLE_RUNTIME_MODULE, "application battle lifetime from launch to return")
  requirePresent(SCENARIO_FACTORY_MODULE, "field sources mapped to one detached scenario")
  local Committer = requirePresent(
    "libs.hgss.src.battle.HgssBattleCommitter",
    "end-to-end exactly-once result publication"
  )
  local SessionFixture = require("libs.battle.tests.session_fixture")

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

    -- An interior table with zeroed walking rates misses without an
    -- encounter, proving attempts run through the composed service.
    local interior = runtime:attemptEncounter({
      eventId = 1,
      mapId = runtime.runtimeMap.mapId,
      movement = "step",
      method = "grass",
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

    -- The journey party arrives through the live script-gift seam: a young
    -- opener that switches and falls, a veteran that closes both wild
    -- battles and solos the trainer, and a young Exp Share holder that
    -- learns from the bench. The machine-teaching seam covers the
    -- situational veteran move with toxic. Slots resolve by name so
    -- learnset order never pins the policy.
    Assert.isTrue(
      runtime.monService:giveMon({ species = "CHIKORITA", level = OPENER_LEVEL, heldItem = "NONE", form = 0 }),
      "the journey needs its young opener"
    )
    Assert.isTrue(
      runtime.monService:giveMon({ species = "CHIKORITA", level = VETERAN_LEVEL, heldItem = "NONE", form = 0 }),
      "the journey needs its veteran"
    )
    Assert.isTrue(
      runtime.monService:giveMon(
        { species = "CHIKORITA", level = LEARNER_LEVEL, heldItem = "EXP__SHARE", form = 0 }
      ),
      "the journey needs its benched learner"
    )
    Assert.equal(runtime.monService:partyCount(), 3, "all three gifts join the live party")
    runtime.monService:setMove(1, 2, "TOXIC")
    local openerGrowl = moveSlotByName(runtime.monService:partyMon(0).moves, "GROWL")
    local openerRazor = moveSlotByName(runtime.monService:partyMon(0).moves, "RAZOR_LEAF")
    local veteranLeaf = moveSlotByName(runtime.monService:partyMon(1).moves, "MAGICAL_LEAF")
    local veteranToxic = moveSlotByName(runtime.monService:partyMon(1).moves, "TOXIC")
    local learnerMoves = runtime.monService:partyMon(2).moves
    Assert.equal(#learnerMoves, 4, "the learner carries a full set into the journey")
    local openerBefore = runtime.monService:partyMon(0)
    local veteranBefore = runtime.monService:partyMon(1)
    local learnerBefore = runtime.monService:partyMon(2)
    local openerExp, openerEvs = openerBefore.experience, evTotal(openerBefore.evs)
    local veteranExp, veteranEvs = veteranBefore.experience, evTotal(veteranBefore.evs)
    local learnerExp = learnerBefore.experience
    local veteranHp = veteranBefore.condition.currentHp

    -- The live Bag stocks through its public add seam: healing for the
    -- replacement leg, ordinary balls for the failed throw, and one
    -- guaranteed ball for the closing capture.
    Assert.isTrue(runtime.bagService:add("POTION", 5), "the journey stocks its healing")
    Assert.isTrue(runtime.bagService:add("POKE_BALL", 5), "the journey stocks its balls")
    Assert.isTrue(runtime.bagService:add("MASTER_BALL", 1), "the journey stocks its guaranteed ball")

    -- Enemy combatants allocate after the last player combatant, so the
    -- opening foe identity follows the live roster size through public
    -- party facts rather than private scenario state.
    local foeOf = function()
      return runtime.monService:partyCount() + 1
    end

    -- First wild leg: the opener voluntarily exchanges to the veteran and
    -- back, a thrown ball breaks free, and the opener finishes the
    -- weakened wild mon. Nothing faints on the player side here.
    local preparedOne = prepareWild(game, 2)
    local pendingOne = assert(runtime.pendingEncounter, "the prepared encounter waits for its launch")
    local wildOne = assert(pendingOne.mons[1].mon, "the prepared encounter carries its wild mon")
    local wildOneSpecies = assert(wildOne.species, "the prepared wild mon names its species")
    local wildRecordOne = { enters = 0, frames = {}, leaves = 0, disposed = 0 }
    runtime:startBattle({
      request = {
        id = "launch-production-wild-one",
        kind = "wild",
        payload = {
          species = wildOneSpecies,
          level = runtime.monService:derive(wildOne).level,
          attemptId = preparedOne,
        },
      },
      presentation = headlessPort(wildRecordOne),
      seed = WILD_SEED_ONE,
    })
    Assert.isNil(runtime.pendingEncounterId, "the launch consumes the held preparation exactly once")
    Assert.notNil(runtime:battleStatus("launch-production-wild-one"), "the owned wild battle reports its identity")
    local foeOne = foeOf()
    local wildOneTurns = runLeg(game, function(request, turn)
      if request.kind == "learn_move" then
        error("the opening wild leg asks no learning prompt", 0)
      end
      local actor = assert(request.actors[1], "every player decision addresses its combatant")
      if not admits(request, "attack") then
        error("the opening leg loses no mon before its ball is thrown", 0)
      end
      if turn == 1 then
        Assert.equal(actor.combatant, 1, "the opener holds the opening field")
        return SessionFixture.switchChoice(actor, 2)
      end
      if turn == 2 then
        Assert.equal(actor.combatant, 2, "the veteran holds the field after the exchange")
        return SessionFixture.switchChoice(actor, 1)
      end
      if turn == 3 then
        return { actor = actor, kind = "item", payload = {
          item = "POKE_BALL",
          target = { kind = "combatant", combatant = foeOne },
        } }
      end
      return SessionFixture.attackChoice(actor, openerRazor, SessionFixture.positionTarget(2))
    end)
    Assert.isTrue(wildOneTurns >= 4, "the opening leg exchanges twice, throws, and finishes")
    Assert.isNil(runtime.errorText, "the opening wild battle settles without faulting the field")
    Assert.deepEqual(
      runtime:lastBattleResult(),
      { result = "win", sourceResult = 1 },
      "the committed opening win reports its outcome words"
    )
    local receiptOne = Committer.receipt("launch-production-wild-one")
    Assert.notNil(receiptOne, "the opening settlement records its commit receipt")
    Assert.isTrue(receiptOne.committed, "the opening receipt proves publication")
    local framesOne = wildRecordOne.frames
    local openSwitches = framePositions(framesOne, "switch", function(frame)
      return type(frame.payload) == "table" and frame.payload.position == 1
    end)
    Assert.equal(#openSwitches, 2, "the opener exchanges out and back on the player side")
    Assert.equal(framesOne[openSwitches[1]].payload.to, 2, "the voluntary exchange reaches the veteran")
    Assert.equal(framesOne[openSwitches[2]].payload.to, 1, "the return exchange brings the opener back")
    local throwsOne = framePositions(framesOne, "throw", nil)
    Assert.equal(#throwsOne, 1, "the opening leg throws exactly one ball")
    Assert.equal(framesOne[throwsOne[1]].payload.ball, "POKE_BALL", "the thrown ball is the stocked one")
    Assert.equal(
      framesOne[throwsOne[1]].payload.target,
      foeOne,
      "the thrown ball targets the wild combatant"
    )
    Assert.equal(#framePositions(framesOne, "broke_free", nil), 1, "the thrown ball breaks free")
    Assert.equal(#framePositions(framesOne, "caught", nil), 0, "the failed throw catches nothing")
    local foeFaintOne = framePositions(framesOne, "faint", function(frame)
      return type(frame.payload) == "table" and frame.payload.combatant == foeOne
    end)
    Assert.equal(#foeFaintOne, 1, "the opening leg knocks out its wild foe")
    Assert.equal(
      #framePositions(framesOne, "faint", function(frame)
        return type(frame.payload) == "table" and frame.payload.combatant ~= foeOne
      end),
      0,
      "no player mon faints in the opening leg"
    )
    Assert.equal(runtime.bagService:quantity("POKE_BALL"), 4, "the thrown ball publishes exactly once")
    Assert.equal(runtime.bagService:quantity("POTION"), 5, "no healing is consumed yet")
    Assert.equal(wildRecordOne.disposed, 1, "opening teardown releases presentation exactly once")
    local dex = assert(runtime.dexKnowledge, "the journey needs its live dex knowledge")
    Assert.isTrue(dex:isSeen(wildOneSpecies), "the opening wild mon registers seen knowledge")
    local openerAfterOne = runtime.monService:partyMon(0)
    Assert.isTrue(openerAfterOne.condition.currentHp > 0, "the opener survives its own leg")
    Assert.isTrue(
      (openerAfterOne.experience or 0) > openerExp,
      "the opener carries the opening knockout experience"
    )
    Assert.isTrue(evTotal(openerAfterOne.evs) >= openerEvs, "the opener keeps its effort values")
    Assert.equal(
      runtime.monService:derive(openerAfterOne).level,
      OPENER_LEVEL,
      "the opening reward does not level the opener"
    )
    local learnerAfterOne = runtime.monService:partyMon(2)
    Assert.isTrue(
      (learnerAfterOne.experience or 0) > learnerExp,
      "the benched holder shares the opening knockout"
    )
    Assert.equal(
      runtime.monService:derive(learnerAfterOne).level,
      LEARNER_LEVEL,
      "the opening share alone does not level the learner"
    )

    -- Second wild leg: the opener weakens nothing and falls to wild
    -- strikes, the real replacement request arrives, the veteran enters
    -- through it, heals through the live Bag, and finishes. This is the
    -- forced-replacement witness.
    local preparedTwo = prepareWild(game, 101)
    local pendingTwo = assert(runtime.pendingEncounter, "the second preparation waits for its launch")
    local wildTwo = assert(pendingTwo.mons[1].mon, "the second preparation carries its wild mon")
    local wildTwoSpecies = assert(wildTwo.species, "the second wild mon names its species")
    local wildRecordTwo = { enters = 0, frames = {}, leaves = 0, disposed = 0 }
    runtime:startBattle({
      request = {
        id = "launch-production-wild-two",
        kind = "wild",
        payload = {
          species = wildTwoSpecies,
          level = runtime.monService:derive(wildTwo).level,
          attemptId = preparedTwo,
        },
      },
      presentation = headlessPort(wildRecordTwo),
      seed = WILD_SEED_TWO,
    })
    Assert.isNil(runtime.pendingEncounterId, "the second launch consumes its preparation exactly once")
    local foeTwo = foeOf()
    local replaced, healedTwo, promptsTwo = false, false, 0
    runLeg(game, function(request)
      if request.kind == "learn_move" then
        promptsTwo = promptsTwo + 1
        local actor = assert(request.actors[1], "learning prompts address their recipient")
        return { actor = actor, kind = "confirm", payload = { decision = "decline" } }
      end
      local actor = assert(request.actors[1], "every player decision addresses its combatant")
      if not admits(request, "attack") then
        replaced = true
        return SessionFixture.switchChoice(actor, 2)
      end
      if actor.combatant == 1 then
        return SessionFixture.attackChoice(actor, openerGrowl, SessionFixture.positionTarget(2))
      end
      if not healedTwo then
        healedTwo = true
        return { actor = actor, kind = "item", payload = {
          item = "POTION",
          target = { kind = "combatant", combatant = actor.combatant },
        } }
      end
      return SessionFixture.attackChoice(actor, veteranLeaf, SessionFixture.positionTarget(2))
    end)
    Assert.isTrue(replaced, "the fallen opener is replaced through the real request")
    Assert.isTrue(healedTwo, "the veteran heals through the live Bag")
    Assert.equal(promptsTwo, 0, "the replacement leg asks no learning prompt")
    Assert.isNil(runtime.errorText, "the replacement battle settles without faulting the field")
    Assert.deepEqual(
      runtime:lastBattleResult(),
      { result = "win", sourceResult = 1 },
      "the committed replacement win reports its outcome words"
    )
    local receiptTwo = Committer.receipt("launch-production-wild-two")
    Assert.notNil(receiptTwo, "the replacement settlement records its commit receipt")
    Assert.isTrue(receiptTwo.committed, "the replacement receipt proves publication")
    local framesTwo = wildRecordTwo.frames
    local playerFaintAt = framePositions(framesTwo, "faint", function(frame)
      return type(frame.payload) == "table" and frame.payload.combatant == 1
    end)[1]
    Assert.notNil(playerFaintAt, "the opener faints on the field")
    local forcedSwitchAt = framePositions(framesTwo, "switch", function(frame)
      local payload = frame.payload
      return type(payload) == "table" and payload.position == 1 and payload.from == 1 and payload.to == 2
    end)[1]
    Assert.notNil(forcedSwitchAt, "the veteran enters through the replacement")
    Assert.isTrue(forcedSwitchAt > playerFaintAt, "the replacement follows the faint")
    local healsTwo = framePositions(framesTwo, "item", function(frame)
      local payload = frame.payload
      return type(payload) == "table" and payload.item == "POTION" and payload.inventory == "player-bag"
    end)
    Assert.equal(#healsTwo, 1, "the live Bag heals exactly once")
    Assert.isTrue(healsTwo[1] > forcedSwitchAt, "the healing lands after the replacement")
    Assert.equal(runtime.bagService:quantity("POTION"), 4, "the consumed potion publishes exactly once")
    Assert.equal(runtime.bagService:quantity("POKE_BALL"), 4, "no further ball leaves the Bag")
    Assert.equal(wildRecordTwo.disposed, 1, "replacement teardown releases presentation exactly once")
    Assert.isTrue(dex:isSeen(wildTwoSpecies), "the second wild mon registers seen knowledge")
    local openerAfterTwo = runtime.monService:partyMon(0)
    Assert.equal(openerAfterTwo.condition.currentHp, 0, "the fallen opener stays fainted")
    Assert.equal(
      runtime.monService:derive(openerAfterTwo).level,
      OPENER_LEVEL,
      "the fainted opener gains no level"
    )
    local veteranAfterTwo = runtime.monService:partyMon(1)
    Assert.isTrue(veteranAfterTwo.condition.currentHp > 0, "the veteran survives its leg")
    Assert.equal(
      runtime.monService:derive(veteranAfterTwo).level,
      VETERAN_LEVEL,
      "the replacement reward does not level the veteran"
    )
    local learnerAfterTwo = runtime.monService:partyMon(2)
    Assert.equal(
      runtime.monService:derive(learnerAfterTwo).level,
      LEARNER_LEVEL,
      "two wild shares still do not level the learner"
    )
    local learnerExpTwo = learnerAfterTwo.experience

    -- The fixed generated trainer carries its structural journey facts:
    -- a singles three-mon party, exactly one healing item, a mid-teens
    -- band, and its prize rate. Executability rides the generated corpus
    -- coverage; nothing here screens its passes or moves.
    local CacheFs = require("libs.storage.src.CacheFs")
    local BattleDataCache = require("libs.assets.src.battle.BattleDataCache")
    local compiled = BattleDataCache.loadTrainers(CacheFs.forVersion(versionId))
    Assert.isNil(compiled.programs, "generated trainer data carries no program fixture")
    local template = assert(compiled.trainers[TRAINER_KEY], "the generated catalog carries the trainer")
    Assert.equal(#template.party, 3, "the trainer fields a lead with two reserves")
    Assert.isTrue(template.doubleBattle ~= true, "the journey stays a singles battle")
    Assert.equal(#(template.items or {}), 4, "the trainer carries four source-ordered slots")
    local carried = {}
    for _, key in ipairs(template.items) do
      if key ~= "NONE" then
        carried[#carried + 1] = key
      end
    end
    Assert.deepEqual(carried, { "SUPER_POTION" }, "the carried stock is exactly one healing serving")
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

    local moneyBefore = runtime.playerData.profile.money
    local veteranHpBeforeTrainer = runtime.monService:partyMon(1).condition.currentHp
    local trainerRecord = { enters = 0, frames = {}, leaves = 0, disposed = 0 }
    local trainerPayload = { trainer = TRAINER_KEY }
    Assert.isNil(trainerPayload.party, "the launch authors no foe party")
    Assert.isNil(trainerPayload.program, "the launch supplies no AI program")
    runtime:startBattle({
      request = { id = "launch-production-trainer", kind = "trainer", payload = trainerPayload },
      presentation = headlessPort(trainerRecord),
      seed = TRAINER_SEED,
    })
    Assert.notNil(runtime:battleStatus("launch-production-trainer"), "the owned trainer battle reports its identity")

    -- The veteran opens because the opener fell in the wild: toxic first,
    -- then the never-missing leaf, while the benched full-set learner
    -- answers its levelling prompt with a combatant-only replacement.
    local foeTrainer = foeOf()
    local toxicUsed, learns, unexpectedReplacement = false, 0, 0
    local framesAtPrompt = 0
    runLeg(game, function(request)
      if request.kind == "learn_move" then
        learns = learns + 1
        local actor = assert(request.actors[1], "learning prompts address their recipient")
        Assert.equal(actor.combatant, 3, "the prompt addresses the benched learner")
        Assert.isNil(actor.activation, "learning prompts carry no entry token")
        Assert.equal(request.incomingMove, "SYNTHESIS", "the crossing level prompts the generated move")
        Assert.equal(#request.currentMoves, 4, "the prompt carries the four current moves")
        framesAtPrompt = #trainerRecord.frames
        return { actor = actor, kind = "confirm", payload = { decision = "replace", slot = 3 } }
      end
      local actor = assert(request.actors[1], "every player decision addresses its combatant")
      if not admits(request, "attack") then
        unexpectedReplacement = unexpectedReplacement + 1
        return SessionFixture.switchChoice(actor, 2)
      end
      Assert.equal(actor.combatant, 2, "the veteran holds the trainer field throughout")
      if not toxicUsed then
        toxicUsed = true
        return SessionFixture.attackChoice(actor, veteranToxic, SessionFixture.positionTarget(2))
      end
      return SessionFixture.attackChoice(actor, veteranLeaf, SessionFixture.positionTarget(2))
    end)
    Assert.isTrue(
      runtime.errorText == nil,
      "the trainer battle settles without faulting the field: " .. tostring(runtime.errorText)
    )
    Assert.equal(learns, 1, "the benched learner prompts exactly once")
    Assert.equal(unexpectedReplacement, 0, "the veteran never falls to the trainer")
    local frames = trainerRecord.frames

    -- Opening toxic and its growing residual: one application naming toxic
    -- and strictly growing tick amounts within every uninterrupted stint.
    -- Working switch intelligence may exchange the toxiced lead, which
    -- restarts the residual counter on return exactly like the native
    -- switch reset, so growth is asserted per stint instead of across
    -- the exchange.
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
    Assert.isTrue(#toxicAmounts >= 3, "the inflicted toxic drains through residual ticks")
    local stints = {}
    local openStint = nil
    local function closeStint()
      if openStint ~= nil then
        stints[#stints + 1] = openStint
        openStint = nil
      end
    end
    for _, frame in ipairs(frames) do
      if type(frame) == "table" then
        local payload = frame.payload
        if type(payload) == "table" then
          if frame.kind == "switch" or frame.kind == "faint" then
            if openStint ~= nil and payload.from == openStint.combatant then
              closeStint()
            end
            if frame.kind == "faint" and openStint ~= nil and payload.combatant == openStint.combatant then
              closeStint()
            end
          elseif frame.kind == "tick" and payload.key == "toxic" and type(payload.amount) == "number" then
            if openStint == nil or openStint.combatant ~= payload.combatant then
              closeStint()
              openStint = { combatant = payload.combatant, amounts = {} }
            end
            openStint.amounts[#openStint.amounts + 1] = payload.amount
          end
        end
      end
    end
    closeStint()
    Assert.isTrue(#stints >= 1, "toxic ticks segment into exchange-bounded stints")
    local longest = 0
    for _, stint in ipairs(stints) do
      for index = 2, #stint.amounts do
        Assert.isTrue(
          stint.amounts[index] > stint.amounts[index - 1],
          "the toxic counter grows its residual drain within every stint"
        )
      end
      if #stint.amounts > longest then
        longest = #stint.amounts
      end
    end
    Assert.isTrue(longest >= 3, "an uninterrupted stint proves multi-tick counter growth")

    -- Trainer item behavior: exactly one healing choice from battle-local
    -- trainer stock lands on a wounded trainer mon, and the depleted stock
    -- never answers again while the fight continues. Voluntary exchanges
    -- may move the wound across the party, so the healed holder is read
    -- back from the serving itself instead of assuming the opener. The
    -- wound is arranged as deep as the opening exchange allows (toxic plus
    -- never-missing leaf spam), and the missing health at heal time is
    -- read back from the public damage frames so the cap is observed
    -- rather than assumed.
    local foeReserveOne, foeReserveTwo = foeTrainer + 1, foeTrainer + 2
    local trainerParty = { [foeTrainer] = true, [foeReserveOne] = true, [foeReserveTwo] = true }
    local trainerItems = framePositions(frames, "item", function(frame)
      local payload = frame.payload
      return type(payload) == "table" and payload.inventory ~= "player-bag"
    end)
    Assert.equal(#trainerItems, 1, "the trainer spends its single stock exactly once")
    local spent = frames[trainerItems[1]].payload
    Assert.equal(spent.target.kind, "combatant", "the healing names its target kind")
    Assert.isTrue(
      trainerParty[spent.target.combatant] == true,
      "the healing lands on a wounded trainer mon"
    )
    local healTarget = spent.target.combatant
    local missingAtHeal = 0
    for index, frame in ipairs(frames) do
      if index < trainerItems[1] and type(frame) == "table" then
        local payload = frame.payload
        if type(payload) == "table" then
          if frame.kind == "struck" and payload.target == healTarget and type(payload.damage) == "number" then
            missingAtHeal = missingAtHeal + payload.damage
          elseif frame.kind == "tick" and payload.combatant == healTarget and type(payload.amount) == "number" then
            missingAtHeal = missingAtHeal + payload.amount
          end
        end
      end
    end
    Assert.isTrue(missingAtHeal > 20, "the arranged wound exceeds the old universal heal")
    local generatedPotion = runtime.itemCatalog:item("SUPER_POTION")
    local generatedPartyUse = assert(
      generatedPotion.partyUse,
      "the generated Super Potion carries its source party use"
    )
    local generatedRestore = assert(
      generatedPartyUse.restore,
      "the generated Super Potion carries its source restoration"
    )
    Assert.equal(generatedRestore.kind, "fixed", "the generated Super Potion restores a fixed amount")
    Assert.equal(generatedRestore.amount, 50, "the generated Super Potion restores its source-derived amount")
    Assert.isTrue(
      generatedRestore.amount ~= 20,
      "the generated restoration amount is not the old universal heal"
    )
    Assert.isTrue(spent.restored ~= 20, "the reported restoration is not the old universal heal")
    Assert.equal(
      spent.restored,
      math.min(generatedRestore.amount, missingAtHeal),
      "the trainer healing restores the generated amount, capped only by missing health"
    )
    Assert.equal(spent.item, "SUPER_POTION", "the spent stock is the carried healing")
    Assert.equal(
      spent.inventory,
      "trainer-1-items",
      "the spent stock comes from battle-local trainer inventory"
    )
    local firstStruckFoe = framePositions(frames, "struck", function(frame)
      local payload = frame.payload
      return type(payload) == "table" and payload.target == foeTrainer
    end)[1]
    local faintFoeLead = framePositions(frames, "faint", function(frame)
      local payload = frame.payload
      return type(payload) == "table" and payload.combatant == foeTrainer
    end)[1]
    Assert.notNil(firstStruckFoe, "the veteran wounds the opening foe")
    Assert.notNil(faintFoeLead, "the opening foe falls")
    local firstStruckHealed = framePositions(frames, "struck", function(frame)
      local payload = frame.payload
      return type(payload) == "table" and payload.target == healTarget
    end)[1]
    local faintHealed = framePositions(frames, "faint", function(frame)
      local payload = frame.payload
      return type(payload) == "table" and payload.combatant == healTarget
    end)[1]
    Assert.notNil(firstStruckHealed, "the healed holder takes its wound in the open")
    Assert.notNil(faintHealed, "the healed holder falls before the terminal win")
    Assert.isTrue(
      trainerItems[1] > firstStruckHealed and trainerItems[1] < faintHealed,
      "the trainer heals its wounded holder before it falls"
    )
    Assert.equal(
      #framePositions(frames, "item", function(frame)
        return type(frame.payload) == "table" and frame.payload.inventory == "player-bag"
      end),
      0,
      "the trainer leg consumes no player Bag stock"
    )

    -- Knockout chain with the learning interruption in the middle: every
    -- fall pulls its replacement next, voluntary exchanges never
    -- impersonate a replacement, and the battle resumes past learning
    -- into the terminal win. Rigid lead-to-reserve pairing is gone on
    -- purpose: a voluntary exchange may reorder who falls first, so the
    -- pairing is asserted causally per faint instead of by roster slot.
    local faintOrder = {}
    for index, frame in ipairs(frames) do
      if type(frame) == "table" and frame.kind == "faint" then
        local payload = frame.payload
        if type(payload) == "table" and trainerParty[payload.combatant] == true then
          faintOrder[#faintOrder + 1] = { combatant = payload.combatant, index = index }
        end
      end
    end
    Assert.equal(#faintOrder, 3, "all three trainer mons fall")
    local fallen = {}
    for position, entry in ipairs(faintOrder) do
      Assert.isTrue(fallen[entry.combatant] == nil, "no trainer mon falls twice")
      fallen[entry.combatant] = true
      if position < #faintOrder then
        local replacement = nil
        for index = entry.index + 1, #frames do
          local frame = frames[index]
          if type(frame) == "table" and frame.kind == "switch" then
            replacement = { index = index, payload = frame.payload }
            break
          end
        end
        Assert.notNil(replacement, "each fall pulls its replacement next")
        local detail = replacement.payload
        Assert.isTrue(type(detail) == "table", "replacements carry their exchange detail")
        Assert.equal(
          detail.from,
          entry.combatant,
          "the replacement answers the fall that pulled it"
        )
        Assert.isTrue(
          trainerParty[detail.to] == true and detail.to ~= entry.combatant and fallen[detail.to] == nil,
          "the replacement sends a living benched reserve"
        )
      end
    end
    Assert.isTrue(
      framesAtPrompt < faintOrder[#faintOrder].index,
      "the battle resumes past learning into the terminal fall"
    )

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
    -- prize from the generated rate, and every foe seen.
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
    for _, member in ipairs(template.party) do
      Assert.isTrue(dex:isSeen(member.species), "every sent foe registers seen knowledge")
    end

    -- Knockout progression with the learning decision: the benched holder
    -- crosses two levels on trainer shares, keeps the replaced set, and
    -- the veteran banks experience and damage without levelling.
    local learnerAfter = runtime.monService:partyMon(2)
    Assert.isTrue(
      (learnerAfter.experience or 0) > (learnerExpTwo or 0),
      "the committed learner carries the trainer shares"
    )
    Assert.equal(
      runtime.monService:derive(learnerAfter).level,
      LEARNER_LEVEL + 2,
      "the trainer shares level the benched learner twice"
    )
    Assert.equal(
      learnerAfter.moves[4].move,
      "SYNTHESIS",
      "the answered replacement lands in the named slot"
    )
    local veteranAfter = runtime.monService:partyMon(1)
    Assert.equal(
      runtime.monService:derive(veteranAfter).level,
      VETERAN_LEVEL,
      "the trainer reward does not level the veteran"
    )
    Assert.isTrue(
      (veteranAfter.experience or 0) > veteranExp,
      "the committed veteran carries the gained experience"
    )
    Assert.isTrue(evTotal(veteranAfter.evs) > veteranEvs, "the committed veteran carries effort values")
    Assert.isTrue(veteranAfter.condition.currentHp > 0, "the veteran survives the executed battle")
    Assert.isTrue(
      veteranAfter.condition.currentHp < veteranHpBeforeTrainer,
      "executed damage writes back through the live party owner"
    )
    local openerAfterTrainer = runtime.monService:partyMon(0)
    Assert.equal(openerAfterTrainer.condition.currentHp, 0, "the opener stays fainted past the trainer")
    Assert.equal(runtime.bagService:quantity("POTION"), 4, "the trainer leg spends no potion")
    Assert.equal(runtime.bagService:quantity("POKE_BALL"), 4, "the trainer leg spends no ball")
    Assert.equal(trainerRecord.disposed, 1, "trainer teardown releases presentation exactly once")
    Assert.isTrue(trainerRecord.enters >= 1, "entry presents through the port")

    -- Closing capture: the guaranteed ball lands the wild mon in the live
    -- party and dex while its stock publishes exactly once. No knockout
    -- means no further progression.
    local preparedThree = prepareWild(game, 201)
    local pendingThree = assert(runtime.pendingEncounter, "the capture preparation waits for its launch")
    local wildThree = assert(pendingThree.mons[1].mon, "the capture preparation carries its wild mon")
    local wildThreeSpecies = assert(wildThree.species, "the capture mon names its species")
    local partyBeforeCapture = runtime.monService:partyCount()
    local captureRecord = { enters = 0, frames = {}, leaves = 0, disposed = 0 }
    runtime:startBattle({
      request = {
        id = "launch-production-capture",
        kind = "wild",
        payload = {
          species = wildThreeSpecies,
          level = runtime.monService:derive(wildThree).level,
          attemptId = preparedThree,
        },
      },
      presentation = headlessPort(captureRecord),
      seed = CAPTURE_SEED,
    })
    local foeCapture = foeOf()
    runLeg(game, function(request)
      if request.kind == "learn_move" then
        local actor = assert(request.actors[1], "learning prompts address their recipient")
        return { actor = actor, kind = "confirm", payload = { decision = "decline" } }
      end
      local actor = assert(request.actors[1], "every player decision addresses its combatant")
      if not admits(request, "attack") then
        return SessionFixture.switchChoice(actor, 2)
      end
      return { actor = actor, kind = "item", payload = {
        item = "MASTER_BALL",
        target = { kind = "combatant", combatant = foeCapture },
      } }
    end)
    Assert.isNil(runtime.errorText, "the capture settles without faulting the field")
    local captureFrames = captureRecord.frames
    local captureThrows = framePositions(captureFrames, "throw", nil)
    Assert.equal(#captureThrows, 1, "the capture throws exactly one ball")
    Assert.equal(captureFrames[captureThrows[1]].payload.ball, "MASTER_BALL", "the capture uses the guaranteed ball")
    Assert.isTrue(#framePositions(captureFrames, "caught", nil) > 0, "the guaranteed ball lands its capture")
    Assert.equal(#framePositions(captureFrames, "broke_free", nil), 0, "the guaranteed ball never breaks free")
    local captureReceipt = Committer.receipt("launch-production-capture")
    Assert.notNil(captureReceipt, "the capture settlement records its commit receipt")
    Assert.isTrue(captureReceipt.committed, "the capture receipt proves publication")
    Assert.equal(#captureReceipt.placements, 1, "the capture reports its placement")
    Assert.isTrue(captureReceipt.placements[1].retained, "room in the party retains the capture")
    Assert.equal(
      runtime.monService:partyCount(),
      partyBeforeCapture + 1,
      "the caught mon lands in the live party"
    )
    local stored = runtime.monService:partyMon(partyBeforeCapture)
    Assert.equal(stored.species, wildThreeSpecies, "the appended mon keeps its species")
    Assert.equal(stored.personality, wildThree.personality, "the appended mon keeps its wild identity")
    Assert.isTrue(dex:isSeen(wildThreeSpecies), "the captured mon registers seen knowledge")
    Assert.isTrue(dex:isCaught(wildThreeSpecies), "the capture registers caught knowledge")
    Assert.equal(runtime.bagService:quantity("MASTER_BALL"), 0, "the thrown guaranteed ball publishes once")
    Assert.equal(runtime.bagService:quantity("POTION"), 4, "the capture spends no potion")
    Assert.equal(runtime.bagService:quantity("POKE_BALL"), 4, "the capture spends no ordinary ball")
    Assert.equal(captureRecord.disposed, 1, "capture teardown releases presentation exactly once")

    -- Generated native-double leg: the same boot launches a source-marked
    -- double trainer through the public battle seam with no authored
    -- scenario, answers every player actor, and proves 2v2 topology through
    -- public semantic frames before committing back to the same field.
    local doubleTemplate = assert(
      compiled.trainers[DOUBLE_TRAINER_KEY],
      "the generated catalog carries the double trainer"
    )
    Assert.isTrue(
      doubleTemplate.doubleBattle == true,
      "the double leg fields a native source-marked double trainer"
    )
    Assert.isTrue(
      type(doubleTemplate.party) == "table" and #doubleTemplate.party >= 2,
      "the double trainer opens two party members"
    )
    local doublePayload = { trainer = DOUBLE_TRAINER_KEY }
    Assert.isNil(doublePayload.party, "the double launch authors no foe party")
    Assert.isNil(doublePayload.program, "the double launch supplies no AI program")

    -- Both double combatants arrive through live mon-service behavior: a
    -- full heal revives the fallen opener, and a party swap fields the
    -- veteran beside the teenager so the arranged openers are conscious.
    runtime.monService:healParty()
    runtime.monService:swapPartyMons(0, 2)
    Assert.isTrue(
      runtime.monService:partyMon(0).condition.currentHp > 0,
      "the arranged double opener stands"
    )
    Assert.isTrue(
      runtime.monService:partyMon(1).condition.currentHp > 0,
      "the arranged double veteran stands"
    )
    local foeDoubleA = runtime.monService:partyCount() + 1
    local foeDoubleB = runtime.monService:partyCount() + 2
    local doubleRecord = { enters = 0, frames = {}, leaves = 0, disposed = 0 }
    runtime:startBattle({
      request = { id = "launch-production-double", kind = "trainer", payload = doublePayload },
      presentation = headlessPort(doubleRecord),
      seed = DOUBLE_SEED,
    })
    Assert.notNil(runtime:battleStatus("launch-production-double"), "the owned double battle reports its identity")

    -- Ordinary strikes resolve by name from each combatant's live set so
    -- learnset order never pins the policy.
    local function doubleStrikeSlot(moves)
      for _, key in ipairs({ "MAGICAL_LEAF", "RAZOR_LEAF" }) do
        for index, entry in ipairs(moves) do
          if type(entry) == "table" and entry.move == key then
            return index - 1
          end
        end
      end
      local known = {}
      for _, entry in ipairs(moves) do
        if type(entry) == "table" then
          known[#known + 1] = tostring(entry.move)
        end
      end
      error("the double combatant carries no ordinary strike (moves: " .. table.concat(known, ",") .. ")", 0)
    end
    local function doubleFoeAlive(foe)
      for _, frame in ipairs(doubleRecord.frames) do
        if type(frame) == "table" and frame.kind == "faint" then
          local payload = frame.payload
          if type(payload) == "table" and payload.combatant == foe then
            return false
          end
        end
      end
      return true
    end
    local firstDoubleActors, firstDoubleTargets = nil, nil
    runLeg(game, function(request, turn)
      if request.kind == "learn_move" then
        local actor = assert(request.actors[1], "learning prompts address their recipient")
        return { actor = actor, kind = "confirm", payload = { decision = "decline" } }
      end
      local actors = assert(request.actors, "every double decision addresses its combatants")
      if not admits(request, "attack") then
        local fielded = {}
        for _, actor in ipairs(actors) do
          fielded[actor.combatant] = true
        end
        local answers = {}
        for _, actor in ipairs(actors) do
          local reserve = nil
          for slot = 1, runtime.monService:partyCount() do
            if not fielded[slot] and runtime.monService:partyMon(slot - 1).condition.currentHp > 0 then
              reserve = slot
              break
            end
          end
          assert(reserve ~= nil, "a replaceable double faint keeps a conscious reserve")
          fielded[reserve] = true
          answers[#answers + 1] = SessionFixture.switchChoice(actor, reserve)
        end
        return answers
      end
      local spots = {
        { foe = foeDoubleA, position = 3 },
        { foe = foeDoubleB, position = 4 },
      }
      local answers = {}
      local targets = {}
      for index, actor in ipairs(actors) do
        local spot = spots[index] or spots[1]
        local other = spots[3 - index] or spots[2]
        local chosen = spot
        if not doubleFoeAlive(spot.foe) and other ~= nil and doubleFoeAlive(other.foe) then
          chosen = other
        end
        local mon = runtime.monService:partyMon(actor.combatant - 1)
        answers[#answers + 1] =
          SessionFixture.attackChoice(actor, doubleStrikeSlot(mon.moves), SessionFixture.positionTarget(chosen.position))
        targets[#targets + 1] = chosen.position
      end
      if turn == 1 then
        firstDoubleActors = {}
        for _, actor in ipairs(actors) do
          firstDoubleActors[#firstDoubleActors + 1] = actor.combatant
        end
        firstDoubleTargets = targets
      end
      return answers
    end)
    Assert.isNil(runtime.errorText, "the double battle settles without faulting the field")
    Assert.deepEqual(
      runtime:lastBattleResult(),
      { result = "win", sourceResult = 1 },
      "the committed double win reports its outcome words"
    )
    local doubleReceipt = Committer.receipt("launch-production-double")
    Assert.notNil(doubleReceipt, "the double settlement records its commit receipt")
    Assert.isTrue(doubleReceipt.committed, "the double receipt proves publication")
    Assert.notNil(firstDoubleActors, "the double battle asks its opening decision")
    Assert.equal(#firstDoubleActors, 2, "the first double batch addresses two player actors")
    Assert.isTrue(
      firstDoubleActors[1] ~= firstDoubleActors[2],
      "each double slot fields its own combatant"
    )
    local orderedActors = { firstDoubleActors[1], firstDoubleActors[2] }
    table.sort(orderedActors)
    Assert.deepEqual(orderedActors, { 1, 2 }, "the arranged openers hold the double field")
    Assert.deepEqual(firstDoubleTargets, { 3, 4 }, "the opening strikes target both enemy positions")
    local doubleFrames = doubleRecord.frames
    Assert.isTrue(
      #framePositions(doubleFrames, "struck", function(frame)
        return type(frame.payload) == "table" and frame.payload.target == foeDoubleA
      end) > 0,
      "the first enemy occupant takes damage"
    )
    Assert.isTrue(
      #framePositions(doubleFrames, "struck", function(frame)
        return type(frame.payload) == "table" and frame.payload.target == foeDoubleB
      end) > 0,
      "the second enemy occupant takes damage"
    )
    Assert.equal(doubleRecord.disposed, 1, "double teardown releases presentation exactly once")
    Assert.isTrue(doubleRecord.enters >= 1, "double entry presents through the port")
    for _, member in ipairs(doubleTemplate.party) do
      Assert.isTrue(dex:isSeen(member.species), "every double foe registers seen knowledge")
    end

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
      },
    },
  }, {})
  Assert.isNil(trainer.ruleset, "trainer fixtures carry no executor selection")
end

return T
