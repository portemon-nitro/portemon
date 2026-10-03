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
local VETERAN_LEVEL = 28
local OPENER_LEVEL = 6
local LEARNER_LEVEL = 11

local WILD_SEED_ONE = 0xD080071
local WILD_SEED_TWO = 0xD080072
local TRAINER_SEED = 0xD080030
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
          profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0, nationalDex = false },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
        fashionCase = require("libs.hgss.src.save.FashionCaseState").empty(),
        playTime = PlayTime.new(),
        worldState = FieldEventState.new(),
        mons = require("tests.support.MonBucket").emptyForVersion(versionId, 7),
        bag = require("libs.hgss.src.save.BagSave").empty(),
        mart = require("libs.hgss.src.save.MartSave").empty(),
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
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x22222222):capture()),
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
    profile = { name = "GOLD", gender = 0, trainerId = 1, money = money, badges = 0, nationalDex = false },
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
---@param choose fun(request: table, turn: integer): table decision choice for the open request
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
      local choice = choose(current.request, turn)
      local accepted, replyErr = battle:submit(SessionFixture.replyFor(current.request, { choice }))
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
    Assert.equal(#(template.items or {}), 1, "the trainer carries exactly one battle item")
    Assert.equal(template.items[1], "SUPER_POTION", "the carried stock is healing")
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
    -- and strictly growing tick amounts afterwards.
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
    for index = 2, #toxicAmounts do
      Assert.isTrue(
        toxicAmounts[index] > toxicAmounts[index - 1],
        "the toxic counter grows its residual drain"
      )
    end

    -- Trainer item behavior: exactly one healing choice from battle-local
    -- trainer stock lands on the opening foe, and the depleted stock never
    -- answers again while the fight continues.
    local trainerItems = framePositions(frames, "item", function(frame)
      local payload = frame.payload
      return type(payload) == "table" and payload.inventory ~= "player-bag"
    end)
    Assert.equal(#trainerItems, 1, "the trainer spends its single stock exactly once")
    local spent = frames[trainerItems[1]].payload
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
    Assert.isTrue(
      trainerItems[1] > firstStruckFoe and trainerItems[1] < faintFoeLead,
      "the trainer heals its wounded opener before it falls"
    )
    Assert.equal(
      #framePositions(frames, "item", function(frame)
        return type(frame.payload) == "table" and frame.payload.inventory == "player-bag"
      end),
      0,
      "the trainer leg consumes no player Bag stock"
    )

    -- Knockout chain with the learning interruption in the middle: the
    -- lead falls, the prompt is answered, and both reserves replace in
    -- order before the terminal win.
    local foeReserveOne, foeReserveTwo = foeTrainer + 1, foeTrainer + 2
    local replaceOneAt = framePositions(frames, "switch", function(frame)
      local payload = frame.payload
      return type(payload) == "table" and payload.from == foeTrainer and payload.to == foeReserveOne
    end)[1]
    local replaceTwoAt = framePositions(frames, "switch", function(frame)
      local payload = frame.payload
      return type(payload) == "table" and payload.from == foeReserveOne and payload.to == foeReserveTwo
    end)[1]
    Assert.notNil(replaceOneAt, "the trainer sends its first reserve after the lead faint")
    Assert.notNil(replaceTwoAt, "the trainer sends its second reserve after the next faint")
    Assert.isTrue(replaceOneAt > framesAtPrompt, "the battle resumes past learning into replacement")
    Assert.isTrue(replaceTwoAt > replaceOneAt, "the reserves replace in order")

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
