-- Event-time playback facts at the application packet boundary: every
-- delivery names its explicit actor and target identities, ordered
-- checkpoints, move selection, and visual seed so later playback never
-- infers participants from display order, reconstructs narration from a
-- final snapshot, or rolls mechanics randomness for particles. These
-- scenarios run the real application runtime over real native sessions
-- with a recording port. Each scenario first asserts the missing
-- boundary, so the run stays red until the provider lands.

local Assert = require("tests.support.Assert")
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local T = {}

---@param record table readiness, hold flag, and packet log owned by the test
---@return table five-operation recording presentation port
local function recordingPort(record)
  return {
    enter = function(plan)
      record.enters = record.enters + 1
      record.enterPlans[#record.enterPlans + 1] = plan
      return true
    end,
    present = function(packet)
      record.packets[#record.packets + 1] = packet
    end,
    ready = function()
      record.readyCalls = record.readyCalls + 1
      return record.ready
    end,
    leave = function(plan)
      record.leaves = record.leaves + 1
      record.leavePlans[#record.leavePlans + 1] = plan
      return true
    end,
    dispose = function()
      record.disposed = record.disposed + 1
    end,
  }
end

---@param record table<string, unknown> full mon-domain record under test preparation
---@return table<string, unknown> the same record striking with a single known move
local function tackleOnly(record)
  record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return record --[[@as table<string, unknown>]]
end

---@param species string catalog species key under test preparation
---@param level integer battle level under test preparation
---@param seed integer fixed generator state under test preparation
---@return table full mon-domain record
local function foeRecord(species, level, seed)
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(seed, catalog)
  return tackleOnly(factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level })))
end

---@param specs table[] lead/reserve descriptions under test preparation
---@return table live party owner holding the described members
local function makeParty(specs)
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local catalog = CatalogFixture.makeCatalog()
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
  for _, spec in ipairs(specs) do
    local factory = CatalogFixture.makeFactory(spec.seed, catalog)
    local req = { species = spec.species, level = spec.level }
    if spec.ability ~= nil then
      req.ability = spec.ability
    end
    local record = tackleOnly(factory:createNormal(CatalogFixture.normalRequest(req)))
    Assert.isTrue(owner:addMon(record), "the packet path needs its live party member")
  end
  return owner
end

---@param launch table launch request under test driving
---@param scenario table detached production scenario under test driving
---@param party table live party owner under test driving
---@param bag table live bag owner under test driving
---@param port table presentation port under test driving
---@param seed integer fixed battle stream seed under test driving
---@return table live application battle under test driving
local function startBattle(launch, scenario, party, bag, port, seed)
  local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")
  return BattleRuntime.new({
    request = launch,
    scenario = scenario,
    party = party,
    bag = bag,
    presentation = port,
    seed = seed,
  })
end

---@param battle table<string, unknown> live application battle under test driving
---@param budget integer maximum update ticks before the driver gives up
---@return table<string, unknown> status once a player decision is open or the lifetime settled
local function driveToDecision(battle, budget)
  for _ = 1, budget do
    battle:update()
    local current = battle:status()
    if current.phase == "running" and current.request ~= nil then
      return current
    end
    if current.phase == "complete" or current.phase == "failed" then
      return current
    end
  end
  error("the battle never opened its player decision")
end

---@param value unknown
---@return string serialized shape without functions for privacy inspection
local function serializeShape(value)
  local parts = {}
  local function walk(node, depth)
    if depth > 6 then
      parts[#parts + 1] = "..."
      return
    end
    if type(node) ~= "table" then
      parts[#parts + 1] = tostring(node)
      return
    end
    parts[#parts + 1] = "{"
    local first = true
    for key, item in
      pairs(node --[[@as table<unknown, unknown>]])
    do
      if not first then
        parts[#parts + 1] = ","
      end
      first = false
      parts[#parts + 1] = tostring(key) .. "="
      walk(item, depth + 1)
    end
    parts[#parts + 1] = "}"
  end
  walk(value, 0)
  return table.concat(parts)
end

-- A doubles turn striking both foes names its true user and every
-- target with stable entry tokens, keeps ordered health and faint
-- checkpoints, and never retargets the animation onto the replacement
-- that later occupies the fainted slot.
function T.spread_move_in_doubles_names_each_target_with_stable_activation()
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local party = makeParty({
    { species = "EEVEE", level = 30, seed = 0x11111111 },
    { species = "EEVEE", level = 30, seed = 0x22222222 },
  })
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local launch =
    { id = "launch-packet-spread-doubles", kind = "trainer", payload = { trainer = "rival-packet-spread" } }
  local scenario = ScenarioFactory.fromTrainer({
    id = "packet-spread-doubles",
    trainers = {
      {
        id = "rival-packet-spread",
        class = 2,
        party = { foeRecord("TOTODILE", 4, 0x5EED0011), foeRecord("CHIKORITA", 4, 0x5EED0012) },
        partyLevels = { 4, 4 },
        prizeMoney = { trainerClass = 2, classRate = 4 },
        aiPasses = {},
        doubleBattle = true,
      },
    },
  }, { party = party, player = { trainerId = 99, trainerName = "MINT", language = "french" } })
  local record = {
    ready = true,
    enters = 0,
    packets = {},
    enterPlans = {},
    readyCalls = 0,
    leaves = 0,
    leavePlans = {},
    disposed = 0,
  }
  local battle = startBattle(launch, scenario, party, bag, recordingPort(record), 0x1234ABCD)
  local opening = driveToDecision(battle, 400)
  Assert.equal(opening.phase, "running", "the doubled battle asks for its opening decision")
  local request = assert(opening.request, "the opening decision is exposed")
  Assert.equal(#request.actors, 2, "both player slots decide the opening together")
  local first = assert(request.actors[1], "the opening names its first slot")
  local second = assert(request.actors[2], "the opening names its second slot")
  Assert.isTrue(
    battle:submit(SessionFixture.replyFor(request, {
      SessionFixture.attackChoice(first, 0, SessionFixture.positionTarget(3)),
      SessionFixture.attackChoice(second, 0, SessionFixture.positionTarget(4)),
    })),
    "the doubled strikes are accepted"
  )
  for _ = 1, 400 do
    battle:update()
    local current = battle:status()
    if current.phase == "complete" or current.phase == "failed" then
      break
    end
    if current.request ~= nil then
      break
    end
  end
  Assert.isTrue(#record.packets > 0, "the doubled turn delivers its packets")
  local struck = {}
  for _, packet in ipairs(record.packets) do
    for _, event in
      ipairs((packet --[[@as table<string, unknown>]]).events --[[@as table<integer, unknown>]])
    do
      local entry = event --[[@as table<string, unknown>]]
      if entry.kind == "struck" then
        struck[#struck + 1] = entry
      end
    end
  end
  Assert.isTrue(#struck >= 2, "the doubled turn tells a strike on each foe")
  for _, event in ipairs(struck) do
    local actors = event.actors --[[@as table<string, unknown>?]]
    Assert.isTrue(type(actors) == "table", "struck events name their explicit ordered actors")
    local targets = event.targets --[[@as table<string, unknown>?]]
    Assert.isTrue(type(targets) == "table" and #targets >= 1, "struck events name their explicit ordered targets")
    for _, actor in
      ipairs(actors --[[@as table<integer, unknown>]])
    do
      local entry = actor --[[@as table<string, unknown>]]
      Assert.isTrue(type(entry.combatant) == "number", "actors carry their combatant identity")
      Assert.isTrue(type(entry.activation) == "number", "actors carry their stable entry token")
    end
    for _, target in
      ipairs(targets --[[@as table<integer, unknown>]])
    do
      local entry = target --[[@as table<string, unknown>]]
      Assert.isTrue(type(entry.combatant) == "number", "targets carry their combatant identity")
      Assert.isTrue(type(entry.activation) == "number", "targets carry their stable entry token")
    end
    local checkpoints = event.checkpoints --[[@as table<string, unknown>?]]
    Assert.isTrue(type(checkpoints) == "table", "struck events keep their ordered display checkpoints")
    local flow = event.flowKey --[[@as string?]]
    Assert.isTrue(type(flow) == "string" and flow ~= "", "struck events select their visual flow key")
  end
  local firstTargets = (struck[1].targets --[[@as table<integer, unknown>]])[1] --[[@as table<string, unknown>]]
  local secondTargets = (struck[2].targets --[[@as table<integer, unknown>]])[1] --[[@as table<string, unknown>]]
  Assert.isTrue(
    firstTargets.combatant ~= secondTargets.combatant,
    "the two strikes address distinct foes instead of borrowing the first visible battler"
  )
  battle:dispose()
end

-- The same delivery presented twice through the cue player executes its
-- visible event once, and a stale entry completion arriving after a
-- switch never unblocks the newer request.
function T.duplicate_packets_execute_once_and_stale_activations_never_unblock()
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")
  local party = makeParty({
    { species = "EEVEE", level = 20, seed = 0x33333333 },
    { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" },
  })
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local launch = {
    id = "launch-packet-duplicate",
    kind = "wild",
    payload = {
      attemptId = "dup-attempt",
      species = "EEVEE",
      form = 0,
      level = 4,
      personality = 1,
      ability = "RUN_AWAY",
    },
  }
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launch.id .. "-attempt", mon = foeRecord("EEVEE", 4, 0x5EED0042) },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local record = {
    ready = true,
    enters = 0,
    packets = {},
    enterPlans = {},
    readyCalls = 0,
    leaves = 0,
    leavePlans = {},
    disposed = 0,
  }
  local battle = startBattle(launch, scenario, party, bag, recordingPort(record), 0x00D9A001)
  local opening = driveToDecision(battle, 400)
  local request = assert(opening.request, "the duplicate battle asks for its opening decision")
  local actor = assert(request.actors[1], "the opening decision addresses its lead")
  Assert.isTrue(
    battle:submit(SessionFixture.replyFor(request, {
      SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2)),
    })),
    "the opening strike is accepted"
  )
  for _ = 1, 200 do
    battle:update()
    local current = battle:status()
    if current.phase ~= "running" then
      break
    end
    if current.request ~= nil then
      break
    end
  end
  Assert.isTrue(#record.packets > 0, "the answered turn delivers its packets")
  local source = nil
  for _, packet in ipairs(record.packets) do
    local entry = packet --[[@as table<string, unknown>]]
    if type(entry.events) == "table" and #entry.events > 0 then
      source = entry
      break
    end
  end
  source = assert(source, "the answered turn delivers a packet carrying its events") --[[@as table<string, unknown>]]
  local player = BattleTimeline.new({})
  Assert.isTrue(player:present(source) == true, "the first delivery is accepted")
  local function cueCount()
    local queue = player._queue --[[@as table<integer, unknown>]]
    local active = player._active
    return #queue + (active ~= nil and 1 or 0)
  end
  local firstCues = cueCount()
  Assert.isTrue(firstCues > 0, "the first delivery queues its visible cues")
  local replay = {}
  for key, value in pairs(source) do
    replay[key] = value
  end
  replay.packetId = source.packetId --[[@as integer]]
    + 1000
  Assert.isTrue(player:present(replay) == false, "the same event identity delivered again executes once")
  Assert.equal(cueCount(), firstCues, "the replayed delivery queues no further visible cues")
  local stale = {
    launchId = launch.id,
    packetId = source.packetId --[[@as integer]]
      + 1001,
    events = {
      {
        sequence = 9999,
        kind = "acknowledge",
        cause = { kind = "switch", combatant = actor.combatant },
        audience = "public",
        payload = { activation = 1 },
        after = { hp = {} },
      },
    },
    before = source.before,
    after = source.after,
  }
  Assert.isTrue(player:present(stale) == false, "a stale entry completion never unblocks a newer request")
  battle:dispose()
end

-- Identical seeds with different presentation pacing replay identical
-- mechanics, while particle variation rides an independent visual seed
-- that never advances the combat stream.
function T.identical_seeds_keep_mechanics_identical_across_presentation_pacing_with_independent_visual_seed()
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local function runTwin(launchId, seed, delayed)
    local twinParty = makeParty({
      { species = "EEVEE", level = 20, seed = 0x55555555 },
      { species = "EEVEE", level = 5, seed = 0x66666666, ability = "RUN_AWAY" },
    })
    local twinBag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
    local foe = foeRecord("TOTODILE", 4, 0x5EED0099)
    local launch = {
      id = launchId,
      kind = "wild",
      payload = {
        attemptId = launchId .. "-attempt",
        species = "TOTODILE",
        form = 0,
        level = 4,
        personality = 1,
        ability = "TORRENT",
      },
    }
    local twinScenario = ScenarioFactory.fromEncounter(
      { attemptId = launch.id .. "-attempt", mon = foe },
      { party = twinParty, bag = twinBag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
    )
    local held = {
      ready = not delayed,
      enters = 0,
      packets = {},
      enterPlans = {},
      readyCalls = 0,
      leaves = 0,
      leavePlans = {},
      disposed = 0,
    }
    local battle = startBattle(launch, twinScenario, twinParty, twinBag, recordingPort(held), seed)
    if delayed then
      for _ = 1, 25 do
        battle:update()
      end
      Assert.equal(#held.packets, 0, "delayed assets hold every packet before readiness")
      held.ready = true
    end
    local opening = driveToDecision(battle, 600)
    local req = assert(opening.request, "the twin asks for its opening decision")
    local lead = assert(req.actors[1], "the twin decision addresses its lead")
    Assert.isTrue(
      battle:submit(SessionFixture.replyFor(req, {
        SessionFixture.attackChoice(lead, 0, SessionFixture.positionTarget(2)),
      })),
      "the twin strike is accepted"
    )
    for _ = 1, 400 do
      battle:update()
      local current = battle:status()
      if current.phase == "complete" or current.phase == "failed" then
        break
      end
      if current.request ~= nil then
        break
      end
    end
    local snapshot = battle:status()
    local transcript = {
      packets = held.packets,
      phase = snapshot.phase,
      partyHp = twinParty:partyMon(0).condition.currentHp,
    }
    battle:dispose()
    return transcript
  end
  local seed = 0x0BADF00D
  local prompt = runTwin("launch-packet-seed-prompt", seed, false)
  local delayed = runTwin("launch-packet-seed-delayed", seed, true)
  Assert.equal(#prompt.packets > 0, true, "the prompt twin delivers its packets")
  Assert.equal(#delayed.packets > 0, true, "the delayed twin delivers its packets after readiness")
  local function struckDamage(packets)
    local out = {}
    for _, packet in ipairs(packets) do
      for _, event in
        ipairs((packet --[[@as table<string, unknown>]]).events --[[@as table<integer, unknown>]])
      do
        local entry = event --[[@as table<string, unknown>]]
        if entry.kind == "struck" then
          local payload = entry.payload --[[@as table<string, unknown>]]
          out[#out + 1] = payload.damage
        end
      end
    end
    return out
  end
  Assert.deepEqual(struckDamage(prompt.packets), struckDamage(delayed.packets), "timing never changes dealt damage")
  Assert.equal(prompt.partyHp, delayed.partyHp, "timing never changes surviving health")
  for _, packets in ipairs({ prompt.packets, delayed.packets }) do
    for _, packet in ipairs(packets) do
      for _, event in
        ipairs((packet --[[@as table<string, unknown>]]).events --[[@as table<integer, unknown>]])
      do
        local entry = event --[[@as table<string, unknown>]]
        local visual = entry.visualSeed
        Assert.isTrue(type(visual) == "number", "every material event carries its independent visual seed")
      end
    end
  end
end

-- Trainer deliveries expose only legitimately visible battler facts:
-- benched reserves and hidden move sets never ride beside the required
-- visible names, appearance keys, and effect parameters.
function T.trainer_payloads_expose_only_visible_battler_facts()
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local party = makeParty({
    { species = "EEVEE", level = 20, seed = 0x77777777 },
    { species = "EEVEE", level = 5, seed = 0x88888888, ability = "RUN_AWAY" },
  })
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local launch = { id = "launch-packet-hidden", kind = "trainer", payload = { trainer = "rival-packet-hidden" } }
  local scenario = ScenarioFactory.fromTrainer({
    id = "packet-hidden",
    trainers = {
      {
        id = "rival-packet-hidden",
        class = 2,
        party = {
          foeRecord("TOTODILE", 5, 0x5EED00A1),
          foeRecord("CHIKORITA", 5, 0x5EED00A2),
          foeRecord("EEVEE", 5, 0x5EED00A3),
        },
        partyLevels = { 5, 5, 5 },
        prizeMoney = { trainerClass = 2, classRate = 4 },
        aiPasses = {},
      },
    },
  }, { party = party, player = { trainerId = 99, trainerName = "MINT", language = "french" } })
  local record = {
    ready = true,
    enters = 0,
    packets = {},
    enterPlans = {},
    readyCalls = 0,
    leaves = 0,
    leavePlans = {},
    disposed = 0,
  }
  local battle = startBattle(launch, scenario, party, bag, recordingPort(record), 0x0EED1234)
  local opening = driveToDecision(battle, 400)
  local request = assert(opening.request, "the trainer battle asks for its opening decision")
  local actor = assert(request.actors[1], "the opening decision addresses its lead")
  Assert.isTrue(
    battle:submit(SessionFixture.replyFor(request, {
      SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2)),
    })),
    "the trainer strike is accepted"
  )
  for _ = 1, 200 do
    battle:update()
    local current = battle:status()
    if current.phase ~= "running" then
      break
    end
    if current.request ~= nil then
      break
    end
  end
  Assert.isTrue(#record.packets > 0, "the trainer turn delivers its packets")
  -- A reserve disclosed by any delivery (for example a replacement
  -- switching in after a knockout) is visible; only reserves no
  -- delivery ever discloses must stay absent from every shape.
  local visibleFoes = {}
  for _, packet in ipairs(record.packets) do
    local afterView = (packet --[[@as table<string, unknown>]]).after --[[@as table<string, unknown>]]
    for _, foe in
      ipairs(afterView.foes --[[@as table<integer, unknown>]])
    do
      local entry = foe --[[@as table<string, unknown>]]
      visibleFoes[
        entry.combatant --[[@as integer]]
      ] = true
    end
  end
  local hiddenReserve = nil
  for _, seed in ipairs(scenario.participants[2].roster) do
    local id = (seed --[[@as table<string, unknown>]]).id --[[@as integer]]
    if visibleFoes[id] ~= true then
      hiddenReserve = hiddenReserve or id
    end
  end
  Assert.notNil(hiddenReserve, "the trainer fixture fields a benched reserve")
  for _, packet in ipairs(record.packets) do
    local entry = packet --[[@as table<string, unknown>]]
    local shape = serializeShape({ events = entry.events, party = entry.party, inventory = entry.inventory })
    Assert.isTrue(
      shape:find("combatant=" .. tostring(hiddenReserve), 1, true) == nil,
      "deliveries never reference the undisclosed reserve identity"
    )
    for _, event in
      ipairs(entry.events --[[@as table<integer, unknown>]])
    do
      local item = event --[[@as table<string, unknown>]]
      local actors = item.actors --[[@as table<string, unknown>?]]
      Assert.isTrue(type(actors) == "table", "playback events name their explicit visible actors")
      local message = item.messageArgs --[[@as table<string, unknown>?]]
      Assert.isTrue(type(message) == "table", "playback events carry typed visible message arguments")
      local payloadShape = serializeShape(item.payload)
      Assert.isTrue(payloadShape:find("moves=", 1, true) == nil, "event payloads never carry hidden move sets")
    end
  end
  battle:dispose()
end

local BRANCH_TICK = 1 / 30

local function branchView()
  return {
    own = {
      {
        combatant = 1,
        side = 1,
        controller = "alpha",
        active = true,
        position = 1,
        activation = 1,
        hp = 60,
        maxHp = 60,
        species = "EEVEE",
        form = 0,
        name = "LEAD",
        level = 20,
        moves = {
          { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 },
          { move = "THUNDER_WAVE", name = "Thunder Wave", pp = 30, maxPp = 30 },
        },
      },
    },
    foes = {
      {
        combatant = 2,
        side = 2,
        controller = "beta",
        active = true,
        position = 2,
        activation = 2,
        hp = 60,
        maxHp = 60,
        species = "EEVEE",
        form = 0,
        name = "FOE",
        level = 20,
      },
      {
        combatant = 4,
        side = 2,
        controller = "beta",
        active = true,
        position = 4,
        activation = 4,
        hp = 60,
        maxHp = 60,
        species = "EEVEE",
        form = 0,
        name = "FOE2",
        level = 20,
      },
    },
  }
end

---@param fields table<string, unknown> branch event shape under construction
---@return table<string, unknown> production-shaped event carrying the branch facts
local function branchEvent(fields)
  local event = {
    sequence = fields.sequence,
    kind = fields.kind,
    cause = { key = fields.cause, kind = "move" },
    audience = "public",
    payload = fields.payload,
    actors = { { combatant = 1 } },
    targets = fields.targets or { { combatant = 2 } },
  }
  if fields.actionId ~= nil then
    event.actionId = fields.actionId
  end
  if fields.effectKey ~= nil then
    event.effectKey = fields.effectKey
  end
  if fields.move ~= nil then
    event.move = fields.move
  end
  if fields.suppression ~= nil then
    event.suppression = fields.suppression
  end
  if fields.hp ~= nil then
    event.observation = { hp = fields.hp }
  end
  if fields.seed ~= nil then
    event.visualSeed = fields.seed
  end
  return event
end

local function tackleMove()
  return { selected = "TACKLE", executed = "TACKLE", phase = "direct" }
end

-- Drives one failure/replay/called-move branch through the real
-- sanitizer and cue player with a pending native collaborator: the
-- announcement must read before the first visual starts, the visual
-- count must stay single-shot, and the narration must name the
-- branch outcome. Returns the start records and the drained texts.
---@param name string branch name under diagnosis
---@param events table[] production-shaped events for the branch action
---@return table[] start records in start order
---@return table[] drained narration texts in completion order
local function runBranch(name, events)
  local view = branchView()
  local started = {}
  local handles = {}
  local timeline = nil
  local effects = {
    start = function(cue)
      started[#started + 1] = {
        effectKey = cue.effectKey,
        actionId = cue.actionId,
        message = timeline:message(),
        phase = cue.event ~= nil and cue.event.move ~= nil and cue.event.move.phase or nil,
      }
      local handle = { phase = "pending" }
      handles[#handles + 1] = handle
      return handle
    end,
    status = function(handle)
      return handle.phase
    end,
    cancel = function(handle)
      handle.phase = "cancelled"
      return true
    end,
  }
  timeline = BattleTimeline.new({ effects = effects })
  timeline:reset(view)
  local packet = BattlePresentationModel.packet(
    view,
    { events = events },
    view,
    { launchId = "branch-probe", packetId = 1 }
  )
  Assert.isTrue(timeline:present(packet), name .. " packet is accepted")
  local announcementTick = nil
  local firstStartTick = nil
  local seen = {}
  local texts = {}
  local tick = 0
  while tick < 6000 and (not timeline:settled() or #started == 0) do
    tick = tick + 1
    timeline:update(BRANCH_TICK, function(_)
      return true
    end)
    local id = timeline:messageId()
    if id ~= 0 and seen[id] == nil and timeline:ack() then
      seen[id] = true
      texts[#texts + 1] = timeline:message()
    end
    if announcementTick == nil and timeline:message() ~= "" then
      announcementTick = tick
    end
    if #started > 0 then
      if firstStartTick == nil then
        firstStartTick = tick
      end
      for _, handle in ipairs(handles) do
        handle.phase = "complete"
      end
    end
  end
  Assert.notNil(firstStartTick, name .. " admits its documented visual")
  Assert.notNil(announcementTick, name .. " narrates its branch outcome")
  Assert.isTrue(announcementTick < firstStartTick, name .. " narrates before its visual starts")
  for _, record in ipairs(started) do
    Assert.isTrue(record.message ~= "", name .. " visual starts behind readable narration")
  end
  Assert.isTrue(timeline:settled(), name .. " drains fully once its visual completes")
  return started, texts
end

local function countStarts(started, key)
  local total = 0
  for _, record in ipairs(started) do
    if record.effectKey == key then
      total = total + 1
    end
  end
  return total
end

local function textsContain(texts, needle)
  for _, text in ipairs(texts) do
    if tostring(text):find(needle, 1, true) ~= nil then
      return true
    end
  end
  return false
end

-- Failure, replay, and called-move branches stay single-shot: missed and
-- protected attempts keep their own documented program without a
-- successful-hit visual, charge and strike halves of one action stay
-- distinct, spread and repeated deliveries play once, and a called move
-- visualizes its executed identity.
function T.failure_replay_and_called_move_branches_stay_single_shot()
  do
    local started, texts = runBranch("status-use", {
      branchEvent({
        sequence = 1,
        kind = "move-used",
        cause = "THUNDER_WAVE",
        actionId = 11,
        effectKey = "THUNDER_WAVE",
        move = { selected = "THUNDER_WAVE", executed = "THUNDER_WAVE", phase = "direct" },
        payload = { user = 1, targets = 1 },
        seed = 101,
      }),
    })
    Assert.equal(countStarts(started, "THUNDER_WAVE"), 1, "the status use admits one visual")
    Assert.isTrue(textsContain(texts, "used Thunder Wave"), "the status use announces its attack")
  end
  do
    local started, texts = runBranch("missed", {
      branchEvent({
        sequence = 1,
        kind = "missed",
        cause = "TACKLE",
        actionId = 12,
        effectKey = "TACKLE",
        move = tackleMove(),
        payload = { target = 2 },
        suppression = { missed = true },
        seed = 102,
      }),
    })
    Assert.equal(countStarts(started, "TACKLE"), 1, "the miss keeps its documented program")
    Assert.isTrue(textsContain(texts, "missed"), "the miss narrates its outcome")
  end
  do
    local started, texts = runBranch("protected", {
      branchEvent({
        sequence = 1,
        kind = "protected",
        cause = "TACKLE",
        actionId = 13,
        effectKey = "TACKLE",
        move = tackleMove(),
        payload = { target = 2 },
        suppression = { protected = true },
        seed = 103,
      }),
    })
    Assert.equal(countStarts(started, "TACKLE"), 1, "the block keeps its documented program")
    Assert.isTrue(textsContain(texts, "protected itself"), "the block narrates its outcome")
  end
  do
    local started, texts = runBranch("charged-strike", {
      branchEvent({
        sequence = 1,
        kind = "charged",
        cause = "RAZOR_WIND",
        actionId = 14,
        effectKey = "RAZOR_WIND",
        move = { selected = "RAZOR_WIND", executed = "RAZOR_WIND", phase = "charge" },
        payload = { target = 1 },
        seed = 104,
      }),
      branchEvent({
        sequence = 2,
        kind = "struck",
        cause = "RAZOR_WIND",
        actionId = 14,
        effectKey = "RAZOR_WIND",
        move = { selected = "RAZOR_WIND", executed = "RAZOR_WIND", phase = "direct" },
        payload = { target = 2, damage = 9, hitIndex = 1 },
        hp = { [1] = 60, [2] = 51 },
        seed = 105,
      }),
    })
    Assert.equal(countStarts(started, "RAZOR_WIND"), 2, "charge and strike halves stay distinct")
    Assert.isTrue(textsContain(texts, "charge"), "the charge half narrates its setup")
    Assert.isTrue(textsContain(texts, "used RAZOR_WIND"), "the strike half announces its attack")
  end
  do
    local started, texts = runBranch("spread", {
      branchEvent({
        sequence = 1,
        kind = "struck",
        cause = "TACKLE",
        actionId = 15,
        effectKey = "TACKLE",
        move = tackleMove(),
        payload = { target = 2, damage = 8, hitIndex = 1 },
        targets = { { combatant = 2 } },
        hp = { [1] = 60, [2] = 52, [4] = 60 },
        seed = 106,
      }),
      branchEvent({
        sequence = 2,
        kind = "struck",
        cause = "TACKLE",
        actionId = 15,
        effectKey = "TACKLE",
        move = tackleMove(),
        payload = { target = 4, damage = 8, hitIndex = 1 },
        targets = { { combatant = 4 } },
        hp = { [1] = 60, [2] = 52, [4] = 52 },
        seed = 107,
      }),
    })
    Assert.equal(countStarts(started, "TACKLE"), 1, "the spread action plays one visual")
    Assert.isTrue(textsContain(texts, "used Tackle"), "the spread action announces once")
  end
  do
    local view = branchView()
    local started = {}
    local handles = {}
    local timeline = nil
    local effects = {
      start = function(cue)
        started[#started + 1] = { effectKey = cue.effectKey }
        local handle = { phase = "pending" }
        handles[#handles + 1] = handle
        return handle
      end,
      status = function(handle)
        return handle.phase
      end,
      cancel = function(handle)
        handle.phase = "cancelled"
        return true
      end,
    }
    timeline = BattleTimeline.new({ effects = effects })
    timeline:reset(view)
    local events = {
      branchEvent({
        sequence = 1,
        kind = "struck",
        cause = "TACKLE",
        actionId = 16,
        effectKey = "TACKLE",
        move = tackleMove(),
        payload = { target = 2, damage = 8, hitIndex = 1 },
        hp = { [1] = 60, [2] = 52 },
        seed = 108,
      }),
    }
    local first = BattlePresentationModel.packet(
      view,
      { events = events },
      view,
      { launchId = "branch-probe", packetId = 1 }
    )
    Assert.isTrue(timeline:present(first), "the first delivery is accepted")
    for _, handle in ipairs(handles) do
      handle.phase = "complete"
    end
    local tick = 0
    while tick < 3000 and not timeline:settled() do
      tick = tick + 1
      timeline:update(BRANCH_TICK, function(_)
        return true
      end)
    end
    local replay = BattlePresentationModel.packet(
      view,
      { events = events },
      view,
      { launchId = "branch-probe", packetId = 2 }
    )
    Assert.isFalse(timeline:present(replay), "the replayed delivery executes nothing twice")
    Assert.equal(countStarts(started, "TACKLE"), 1, "the replay starts no second visual")
  end
  do
    local started, texts = runBranch("called-move", {
      branchEvent({
        sequence = 1,
        kind = "move-used",
        cause = "TACKLE",
        actionId = 17,
        effectKey = "TACKLE",
        move = { selected = "METRONOME", executed = "TACKLE", phase = "direct" },
        payload = { user = 1, targets = 1 },
        seed = 109,
      }),
    })
    Assert.equal(countStarts(started, "TACKLE"), 1, "the called move visualizes its executed identity")
    Assert.equal(countStarts(started, "METRONOME"), 0, "the called move never visualizes its selected identity")
    Assert.isTrue(textsContain(texts, "used Tackle"), "the called move announces its executed attack")
  end
end

return { tests = T }
