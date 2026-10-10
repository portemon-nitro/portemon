-- Detached battle presentation boundary: the runtime owns one battle
-- lifetime and exposes only detached, ordered, exactly-once delivery to
-- its presentation port. The frontend opens from a detached scenario and
-- session snapshot (never the live session, RNG, trainer policy, or
-- unrevealed enemy state), paces whole-turn mechanics frames through
-- event-time checkpoints, answers pure engine-owned decision options by
-- copying prepared choice fragments, and settles through the existing
-- committer exactly once with truthful capture/flee words.
--
-- These scenarios run the real application runtime over the real native
-- session, scenario factory, and committer with a recording port. No LOVE
-- rendering and no generated UI pixels are involved. Each scenario first
-- asserts its missing boundary, so the run stays red until the provider
-- lands; kernel behavior that already holds is asserted as guards beside
-- the red line.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local T = {}

---@param record table readiness and call counters owned by the test
---@return table headless presentation port with controllable readiness
local function headlessPort(record)
  return {
    enter = function(_plan)
      record.enters = record.enters + 1
      return true
    end,
    -- The five-operation port delivers detached packets; the headless
    -- fake unwraps their ordered events so the damage-equality probes
    -- below keep reading the same kernel event payloads.
    present = function(packet)
      for _, event in ipairs(packet.events) do
        record.frames[#record.frames + 1] = event
      end
    end,
    ready = function()
      return true
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

---@return table minimal recording bag double holding one Master Ball
local function masterBallBag()
  local stock = { MASTER_BALL = 1 }
  local revision = 0
  local bag = {}
  function bag:capture()
    return { pockets = { balls = { { item = "MASTER_BALL", quantity = stock.MASTER_BALL } } } }
  end
  function bag:revision()
    return revision
  end
  function bag:quantity(item)
    return stock[item] or 0
  end
  function bag:prepareInventoryChanges(expected, deltas)
    Assert.equal(expected, revision, "the staged preparation carries the construction revision")
    for _, delta in ipairs(deltas) do
      Assert.equal(delta.op, "take", "the capture spends its ball through a take delta")
      Assert.equal(delta.item, "MASTER_BALL", "the take delta names the thrown ball")
      Assert.isTrue(delta.quantity <= stock.MASTER_BALL, "the double never overspends its stock")
    end
    local liveRevision = revision
    local spent = 0
    for _, delta in ipairs(deltas) do
      spent = spent + delta.quantity
    end
    local prep = {}
    function prep:isCurrent()
      return revision == liveRevision
    end
    function prep:publish()
      stock.MASTER_BALL = stock.MASTER_BALL - spent
      revision = revision + 1
    end
    return prep
  end
  return bag
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

---@param species string catalog species key under test preparation
---@param level integer battle level under test preparation
---@param seed integer fixed generator state under test preparation
---@param moves table|nil explicit move set replacing the default single strike
---@return table battle foe record with the requested move set
local function foeWithMoves(species, level, seed, moves)
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(seed, catalog)
  local foe = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level }))
  foe.moves = moves
  return foe
end

---@param spec table lead/reserve description under test preparation
---@return table live party owner holding the described pair
local function makeParty(leadSpec, reserveSpec)
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
  for _, spec in ipairs({ leadSpec, reserveSpec }) do
    local factory = CatalogFixture.makeFactory(spec.seed, catalog)
    local req = { species = spec.species, level = spec.level }
    if spec.ability ~= nil then
      req.ability = spec.ability
    end
    local record = tackleOnly(factory:createNormal(CatalogFixture.normalRequest(req)))
    Assert.isTrue(owner:addMon(record), "the presentation path needs its live party member")
  end
  return owner
end

---@param id string launch identity under test preparation
---@return table wild launch request carrying the required species payload
local function wildLaunch(id)
  return {
    id = id,
    kind = "wild",
    payload = {
      attemptId = id .. "-attempt",
      species = "EEVEE",
      form = 0,
      level = 4,
      personality = 1,
      ability = "RUN_AWAY",
    },
  }
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

---@param options table projected decision options under inspection
---@param combatant integer roster identity that must stay hidden
---@return boolean true when no option references the hidden combatant
local function hidesCombatant(options, combatant)
  local actors = options.actors or options.options
  if type(actors) ~= "table" then
    return serializeShape(options):find("combatant=" .. tostring(combatant), 1, true) == nil
  end
  for _, entry in
    ipairs(actors --[[@as table<integer, unknown>]])
  do
    if type(entry) == "table" then
      local record = entry --[[@as table<string, unknown>]]
      if record.combatant == combatant then
        return false
      end
      local choices = record.choices or record.options
      if type(choices) == "table" then
        for _, choice in
          ipairs(choices --[[@as table<integer, unknown>]])
        do
          if serializeShape(choice):find("combatant=" .. tostring(combatant), 1, true) ~= nil then
            return false
          end
        end
      end
    end
  end
  return true
end

-- Opening decisions project pure selectable options: one native read
-- returns the current request identity with only player-selectable,
-- fully addressed choice fragments, while enemy reserves, move lists,
-- and submitted plans stay hidden. Reads never reserve, roll, or seal;
-- stale, mistargeted, and duplicate replies are refused without effects.
function T.opening_decisions_project_pure_selectable_options()
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local party = makeParty(
    { species = "EEVEE", level = 20, seed = 0x33333333 },
    { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" }
  )
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local foe = foeRecord("EEVEE", 20, 0x5EED0002)
  local launch = wildLaunch("launch-presentation-options")
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launch.id .. "-attempt", mon = foe },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local portRecord = { ready = true, enters = 0, frames = {}, leaves = 0, disposed = 0 }
  local battle = startBattle(launch, scenario, party, bag, headlessPort(portRecord), 0x12345678)

  local opening = driveToDecision(battle, 400)
  Assert.equal(opening.phase, "running", "the presentation battle asks for its opening decision")
  local request = assert(opening.request, "the opening decision is exposed")

  -- The pure native options read is the missing provider boundary: the
  -- reduced controller view carries no selectable-options projection.
  Assert.isTrue(
    type(battle.decisionOptions) == "function",
    "the runtime projects pure engine-owned decision options for its open request"
  )
  local options = battle:decisionOptions(request.requestId)
  Assert.equal(options.requestId, request.requestId, "options answer the current request identity")
  Assert.equal(options.epoch, request.epoch, "options carry the current epoch")
  Assert.equal(options.controller, request.controller, "options answer the owning controller")
  Assert.equal(#options.actors, #request.actors, "options address every requested actor once")
  local actorOptions = assert(options.actors[1], "the opening options address the lead")
  Assert.equal(actorOptions.kind, "action", "the opening options form the ordinary action union member")
  Assert.notNil(actorOptions.choices, "every selectable option is present")
  Assert.isTrue(#actorOptions.choices > 0, "the opening turn offers at least one selectable option")
  for _, option in ipairs(actorOptions.choices) do
    local entry = option --[[@as table<string, unknown>]]
    Assert.isTrue(type(entry.id) == "string" and entry.id ~= "", "selectable options carry a semantic identity")
    Assert.notNil(entry.display, "selectable options carry display facts")
    Assert.isTrue(type(entry.enabled) == "boolean", "selectable options name their availability")
    Assert.notNil(entry.choice, "selectable options carry a complete validated choice fragment")
  end

  -- Enemy secrets stay hidden: benched foe combatants never appear, and
  -- the option move entries never exceed the player's own move count.
  local foeReserve = nil
  for _, seed in ipairs(scenario.participants[2].roster) do
    if seed.id ~= request.actors[1].combatant then
      foeReserve = foeReserve or seed.id
    end
  end
  if foeReserve ~= nil then
    Assert.isTrue(hidesCombatant(options, foeReserve), "projected options never reference unrevealed enemy reserves")
  end
  local moveCount = 0
  for _, option in ipairs(actorOptions.choices) do
    local entry = option --[[@as table<string, unknown>]]
    if entry.role == "move" or (type(entry.id) == "string" and entry.id:find("move")) then
      moveCount = moveCount + 1
      local choice = entry.choice --[[@as table<string, unknown>]]
      local payload = choice.payload --[[@as table<string, unknown>]]
      Assert.isTrue(type(payload.moveSlot) == "number", "move options name their zero-based slot")
    end
  end
  Assert.isTrue(moveCount <= 4, "action options never exceed the four move slots")

  -- The product opening DTO is the missing filtering boundary: the
  -- frontend builds from a detached snapshot, never the live session.
  local okModel, model = pcall(require, "game.hgss.src.battle.BattlePresentationModel")
  Assert.isTrue(okModel, "the product presentation boundary builds detached opening views from runtime snapshots")
  assert(model ~= nil, "the presentation model loads")
  Assert.isTrue(type(model.opening) == "function", "the product boundary derives the detached opening view")
  Assert.isTrue(type(model.packet) == "function", "the product boundary sanitizes detached delivery packets")

  -- Enumeration is pure: mutating a copy changes no later read, and an
  -- options-heavy twin deals identical damage to an untouched twin.
  local first = battle:decisionOptions(request.requestId)
  first.actors[1].choices[1].choice.actor.combatant = -9999
  first.actors[1].choices[1].enabled = "mutated"
  local second = battle:decisionOptions(request.requestId)
  Assert.deepEqual(second, battle:decisionOptions(request.requestId), "repeated reads stay identical")
  Assert.isTrue(
    second.actors[1].choices[1].enabled ~= "mutated",
    "mutating a returned copy never reaches the kernel or a later read"
  )
  local twinPort = { ready = true, enters = 0, frames = {}, leaves = 0, disposed = 0 }
  local twinParty = makeParty(
    { species = "EEVEE", level = 20, seed = 0x33333333 },
    { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" }
  )
  local twinBag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local twin = startBattle(
    wildLaunch("launch-presentation-twin"),
    ScenarioFactory.fromEncounter(
      { attemptId = "twin-attempt", mon = foeRecord("EEVEE", 20, 0x5EED0002) },
      { party = twinParty, bag = twinBag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
    ),
    twinParty,
    twinBag,
    headlessPort(twinPort),
    0x12345678
  )
  local twinOpening = driveToDecision(twin, 400)
  local twinRequest = assert(twinOpening.request, "the twin asks for the same opening decision")
  battle:decisionOptions(request.requestId)
  battle:decisionOptions(request.requestId)
  local actor = assert(request.actors[1], "the opening decision addresses its lead")
  local twinActor = assert(twinRequest.actors[1], "the twin decision addresses its lead")
  Assert.isTrue(
    battle:submit(SessionFixture.replyFor(request, {
      SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2)),
    })),
    "a submitted opening strike is accepted after repeated options reads"
  )
  Assert.isTrue(
    twin:submit(SessionFixture.replyFor(twinRequest, {
      SessionFixture.attackChoice(twinActor, 0, SessionFixture.positionTarget(2)),
    })),
    "the untouched twin answers the identical strike"
  )
  local function struckDamage(record)
    for _, frame in ipairs(record.frames) do
      if type(frame) == "table" and frame.kind == "struck" then
        local payload = frame.payload --[[@as table<string, unknown>]]
        return payload.damage
      end
    end
    return nil
  end
  for _ = 1, 60 do
    battle:update()
    twin:update()
  end
  Assert.equal(
    struckDamage(portRecord),
    struckDamage(twinPort),
    "options reads leave mechanics draws and damage unchanged"
  )
  battle:dispose()
  twin:dispose()
end

-- Rejected replies keep the open request: stale epochs, mistargeted
-- entry tokens, and duplicate seals are refused without consuming
-- randomness, items, PP, or reservations, and the same decision stays
-- answerable with a corrected selection.
function T.rejected_replies_keep_the_open_request()
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local party = makeParty(
    { species = "EEVEE", level = 20, seed = 0x33333333 },
    { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" }
  )
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local foe = foeRecord("EEVEE", 20, 0x5EED0002)
  local launch = wildLaunch("launch-presentation-latch")
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launch.id .. "-attempt", mon = foe },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local portRecord = { ready = true, enters = 0, frames = {}, leaves = 0, disposed = 0 }
  local battle = startBattle(launch, scenario, party, bag, headlessPort(portRecord), 0x12345678)

  local opening = driveToDecision(battle, 400)
  local request = assert(opening.request, "the latch battle asks for its opening decision")
  local actor = assert(request.actors[1], "the opening decision addresses its lead")
  local function attackWith(overrides)
    local addressed = { combatant = actor.combatant, activation = actor.activation }
    for key, value in pairs(overrides.actor or {}) do
      addressed[key] = value
    end
    local reply = {
      requestId = overrides.requestId or request.requestId,
      epoch = (overrides.epoch ~= nil) and overrides.epoch or request.epoch,
      controller = request.controller,
      choices = {
        {
          actor = addressed,
          kind = "attack",
          payload = { moveSlot = 0, target = { kind = "position", position = 2 } },
        },
      },
    }
    return reply
  end

  local stale, staleErr = battle:submit(attackWith({ epoch = (request.epoch or 0) + 1 }))
  Assert.isFalse(stale, "a stale epoch never seals")
  Assert.notNil(staleErr, "a stale epoch names its input error")
  Assert.equal(battle:status().request.requestId, request.requestId, "a stale epoch keeps the same decision open")
  local mistargeted, mistargetedErr = battle:submit(attackWith({ actor = { activation = -7 } }))
  Assert.isFalse(mistargeted, "a mistargeted entry token never seals")
  Assert.notNil(mistargetedErr, "a mistargeted entry token names its input error")
  local accepted, acceptedErr = battle:submit(attackWith({}))
  Assert.isTrue(accepted, "the corrected selection seals once")
  Assert.isNil(acceptedErr, "the sealed selection carries no input error")
  local duplicate, duplicateErr = battle:submit(attackWith({}))
  Assert.isFalse(duplicate, "a second copy of the sealed reply never seals again")
  Assert.notNil(duplicateErr, "a duplicate seal names its input error")
  battle:dispose()
end

-- Forced replacement options admit only eligible reserves: the prompt
-- addresses the bereaved side without a live entry token, and answering
-- through a projected fragment brings the chosen reserve in.
function T.forced_replacement_options_cover_only_eligible_reserves()
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local party = makeParty(
    { species = "EEVEE", level = 5, seed = 0x33333333 },
    { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" }
  )
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local foe = foeWithMoves("EEVEE", 30, 0x5EED0002, { { move = "TACKLE", pp = 35, ppUps = 0 } })
  local launch = wildLaunch("launch-presentation-replacement")
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launch.id .. "-attempt", mon = foe },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local portRecord = { ready = true, enters = 0, frames = {}, leaves = 0, disposed = 0 }
  local battle = startBattle(launch, scenario, party, bag, headlessPort(portRecord), 0x12345678)

  local replacement = nil
  for _ = 1, 800 do
    battle:update()
    local current = battle:status()
    Assert.isTrue(current.phase ~= "failed", "the knockout battle never fails")
    if current.phase == "running" and current.request ~= nil then
      local kinds = assert(current.request.legalChoices, "every decision carries its admitted vocabulary").kinds
      local onlySwitch = #kinds == 1 and kinds[1] == "switch"
      if onlySwitch then
        replacement = current.request
        break
      end
      local addressed = assert(current.request.actors[1], "every decision addresses its combatant")
      local ok, err = battle:submit(SessionFixture.replyFor(current.request, {
        SessionFixture.attackChoice(addressed, 0, SessionFixture.positionTarget(2)),
      }))
      Assert.isTrue(ok, "the doomed lead keeps striking until it faints: " .. tostring(err))
    end
    if current.phase == "complete" or current.phase == "failed" then
      break
    end
  end
  replacement = assert(replacement, "the knockout opens a forced replacement decision")
  -- The kernel binds replacement replies by obligation token: actors
  -- address the fainted combatant with the entry token of its ended
  -- entry, so a repeated faint of one combatant stays distinguishable.
  -- That binding is preserved, not a frontend defect.
  Assert.equal(#replacement.actors, 1, "the replacement prompt addresses its bereaved side once")
  local bereaved = replacement.actors[1] --[[@as table<string, unknown>]]
  Assert.isTrue(type(bereaved.combatant) == "number", "replacement addresses the fainted combatant")
  Assert.isTrue(type(bereaved.activation) == "number", "replacement keeps its obligation token")

  -- The pure native options read is the missing provider boundary for
  -- every request union member, not just ordinary actions.
  Assert.isTrue(
    type(battle.decisionOptions) == "function",
    "the runtime projects pure engine-owned decision options for forced replacement"
  )
  local options = battle:decisionOptions(replacement.requestId)
  Assert.equal(options.requestId, replacement.requestId, "replacement options answer the current prompt")
  Assert.equal(#options.actors, 1, "the replacement prompt addresses its bereaved side once")
  Assert.equal(options.actors[1].kind, "replacement", "replacement options form their own union member")
  local reserve = nil
  for _, seed in ipairs(scenario.participants[1].roster) do
    if seed.id ~= replacement.actors[1].combatant then
      reserve = seed.id
    end
  end
  reserve = assert(reserve, "the production roster carries its reserve")
  local chosen = nil
  for _, option in ipairs(options.actors[1].choices) do
    local entry = option --[[@as table<string, unknown>]]
    local choice = entry.choice --[[@as table<string, unknown>]]
    local payload = choice.payload --[[@as table<string, unknown>]]
    if payload.replacement == reserve then
      chosen = entry
      Assert.isTrue(entry.enabled, "the living unreserved reserve stays selectable")
    end
  end
  Assert.notNil(chosen, "the eligible reserve is projected")
  Assert.isTrue(
    battle:submit({
      requestId = replacement.requestId,
      epoch = replacement.epoch,
      controller = replacement.controller,
      choices = {
        (chosen --[[@as table<string, unknown>]]).choice,
      },
    }),
    "answering through the projected fragment brings the reserve in"
  )
  battle:dispose()
end

-- Learning options address the held recipient: the prompt names its
-- incoming move and held move set without an entry token, and the
-- projected replace fragment learns exactly the chosen slot.
function T.learning_options_address_the_held_recipient()
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local party = makeParty(
    { species = "EEVEE", level = 5, seed = 0x33333333 },
    { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" }
  )
  do
    local lead = party:partyMon(0)
    lead.moves = {
      { move = "TACKLE", pp = 35, ppUps = 0 },
      { move = "TAIL_WHIP", pp = 30, ppUps = 0 },
      { move = "GROWL", pp = 40, ppUps = 0 },
      { move = "LEER", pp = 30, ppUps = 0 },
    }
    local prep = party:preparePartyBatch(party:partyRevision(), { { slot = 0, mon = lead } }, {})
    Assert.notNil(prep, "the full move set stages against the live party")
    prep.publish()
  end
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local foe = foeWithMoves("EEVEE", 30, 0x5EED0002, { { move = "GROWL", pp = 40, ppUps = 0 } })
  foe.condition.currentHp = 1
  local launch = wildLaunch("launch-presentation-learning")
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launch.id .. "-attempt", mon = foe },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local portRecord = { ready = true, enters = 0, frames = {}, leaves = 0, disposed = 0 }
  local battle = startBattle(launch, scenario, party, bag, headlessPort(portRecord), 0x12345678)

  local prompt = nil
  for _ = 1, 800 do
    battle:update()
    local current = battle:status()
    Assert.isTrue(current.phase ~= "failed", "the learning battle never fails")
    if current.phase == "running" and current.request ~= nil then
      if current.request.kind == "learn_move" or current.request.incomingMove ~= nil then
        prompt = current.request
        break
      end
      local addressed = assert(current.request.actors[1], "every decision addresses its combatant")
      local ok, err = battle:submit(SessionFixture.replyFor(current.request, {
        SessionFixture.attackChoice(addressed, 0, SessionFixture.positionTarget(2)),
      }))
      Assert.isTrue(ok, "the opening strike is accepted: " .. tostring(err))
    end
    if current.phase == "complete" or current.phase == "failed" then
      break
    end
  end
  prompt = assert(prompt, "crossing the learning level opens its interactive prompt")
  Assert.equal(prompt.incomingMove, "SAND_ATTACK", "the prompt names the incoming move")
  Assert.isTrue(type(prompt.currentMoves) == "table", "the prompt carries its held move set")
  for _, addressed in ipairs(prompt.actors) do
    local entry = addressed --[[@as table<string, unknown>]]
    Assert.isNil(entry.activation, "learning answers carry no entry token")
  end

  -- The pure native options read is the missing provider boundary for
  -- the learning union member as well.
  Assert.isTrue(
    type(battle.decisionOptions) == "function",
    "the runtime projects pure engine-owned decision options for move learning"
  )
  local options = battle:decisionOptions(prompt.requestId)
  Assert.equal(options.requestId, prompt.requestId, "learning options answer the current prompt")
  Assert.equal(options.actors[1].kind, "learn_move", "learning options form their own union member")
  Assert.equal(options.actors[1].incomingMove, "SAND_ATTACK", "learning options mirror the held recipient facts")
  local replace = nil
  local decline = nil
  for _, option in ipairs(options.actors[1].choices) do
    local entry = option --[[@as table<string, unknown>]]
    local choice = entry.choice --[[@as table<string, unknown>]]
    local payload = choice.payload --[[@as table<string, unknown>]]
    Assert.equal(choice.kind, "confirm", "learning fragments confirm the prompt")
    if payload.decision == "replace" then
      replace = entry
      Assert.isTrue(type(payload.slot) == "number", "replacements name a zero-based move slot")
    elseif payload.decision == "decline" then
      decline = entry
    end
  end
  Assert.notNil(replace, "the held move set offers a replacement")
  Assert.notNil(decline, "the prompt offers its decline")
  Assert.isTrue(
    battle:submit({
      requestId = prompt.requestId,
      epoch = prompt.epoch,
      controller = prompt.controller,
      choices = {
        (replace --[[@as table<string, unknown>]]).choice,
      },
    }),
    "answering through the projected replace fragment is accepted"
  )
  for _ = 1, 400 do
    battle:update()
    local current = battle:status()
    if current.phase == "complete" or current.phase == "failed" then
      break
    end
  end
  Assert.equal(battle:status().phase, "complete", "the answered prompt settles the battle")
  battle:dispose()
end

-- Packets deliver once in order with back-pressure: while the port is
-- not ready the runtime neither advances nor republishes; every packet
-- carries identity, ordered events with event-time checkpoints, and
-- detached before/after views; the terminal outcome arrives exactly
-- once; and delayed presentation matches the immediate headless trace.
function T.packets_deliver_once_in_order_with_back_pressure()
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local party = makeParty(
    { species = "EEVEE", level = 20, seed = 0x33333333 },
    { species = "EEVEE", level = 20, seed = 0x44444444, ability = "RUN_AWAY" }
  )
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local foe = foeRecord("EEVEE", 20, 0x5EED0002)
  local launch = wildLaunch("launch-presentation-packets")
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launch.id .. "-attempt", mon = foe },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local held = {
    ready = false,
    enters = 0,
    packets = {},
    enterPlans = {},
    readyCalls = 0,
    leaves = 0,
    leavePlans = {},
    disposed = 0,
  }
  local battle = startBattle(launch, scenario, party, bag, recordingPort(held), 0x12345678)

  for _ = 1, 30 do
    battle:update()
  end
  -- Back-pressure is the missing provider behavior: the old port has no
  -- readiness gate, so the lifetime advances regardless of the hold.
  Assert.isTrue(held.readyCalls > 0, "the runtime consults presentation readiness before advancing")
  Assert.equal(#held.packets, 0, "no packet is delivered while the port is not ready")
  Assert.equal(battle:status().phase, "preparing", "the lifetime waits instead of running ahead while held")

  held.ready = true
  local opening = driveToDecision(battle, 400)
  Assert.equal(opening.phase, "running", "release lets the lifetime proceed")
  local request = assert(opening.request, "the released battle asks for its decision")
  local firstId = request.requestId
  for _ = 1, 10 do
    battle:update()
  end
  Assert.equal(
    battle:status().request.requestId,
    firstId,
    "an unchanged waiting request is never republished while polling"
  )

  -- Every packet carries identity, ordered events, and detached views;
  -- every event carries its event-time checkpoint beside its sequence,
  -- cause, action, and hit identity.
  local actor = assert(request.actors[1], "the packet decision addresses its lead")
  Assert.isTrue(
    battle:submit(SessionFixture.replyFor(request, {
      SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2)),
    })),
    "the packeted strike is accepted"
  )
  for _ = 1, 120 do
    battle:update()
    local current = battle:status()
    if current.phase ~= "running" then
      break
    end
    if current.request ~= nil and current.request.requestId ~= firstId then
      break
    end
  end
  Assert.isTrue(#held.packets > 0, "the answered turn delivers its packets")
  local lastId = 0
  for _, packet in ipairs(held.packets) do
    local record = packet --[[@as table<string, unknown>]]
    Assert.equal(record.launchId, launch.id, "packets carry their launch identity")
    Assert.isTrue(type(record.packetId) == "number", "packets carry a monotonic per-launch identity")
    Assert.isTrue(record.packetId --[[@as integer]] > lastId, "packet identities increase in delivery order")
    lastId = record.packetId --[[@as integer]]
    Assert.isTrue(type(record.events) == "table", "packets carry their ordered events")
    Assert.notNil(record.before, "packets carry their detached before view")
    Assert.notNil(record.after, "packets carry their detached after view for reconciliation")
    for _, event in
      ipairs(record.events --[[@as table<integer, unknown>]])
    do
      local entry = event --[[@as table<string, unknown>]]
      Assert.isTrue(type(entry.sequence) == "number", "packet events retain their sequence identity")
      Assert.isTrue(type(entry.kind) == "string", "packet events retain their kind")
      Assert.notNil(entry.cause, "packet events retain their cause")
      local checkpoint = entry.after --[[@as table<string, unknown>]]
      Assert.isTrue(type(checkpoint) == "table", "packet events carry their event-time checkpoint")
      Assert.isTrue(type(checkpoint.hp) == "table", "checkpoints record observable health per combatant")
    end
  end

  -- One turn with a strike on each side carries two distinct event-time
  -- checkpoints: the past is never reconstructed from the final future.
  local struckAfter = {}
  for _, packet in ipairs(held.packets) do
    for _, event in
      ipairs((packet --[[@as table<string, unknown>]]).events --[[@as table<integer, unknown>]])
    do
      local entry = event --[[@as table<string, unknown>]]
      if entry.kind == "struck" then
        local checkpoint = entry.after --[[@as table<string, unknown>]]
        struckAfter[#struckAfter + 1] = serializeShape(checkpoint.hp)
      end
    end
  end
  Assert.isTrue(#struckAfter >= 2, "the traded turn tells a strike on each side")
  Assert.isTrue(struckAfter[1] ~= struckAfter[2], "two hits in one frame carry different event-time checkpoints")

  -- Packets are detached: mutating a delivered packet changes neither
  -- the kernel, the saved request, nor a subsequent packet.
  local beforeCount = #held.packets
  local firstPacket = held.packets[1] --[[@as table<string, unknown>]]
  firstPacket.packetId = -1
  firstPacket.events = {}
  for _ = 1, 1200 do
    battle:update()
    local current = battle:status()
    if current.phase == "complete" or current.phase == "failed" then
      break
    end
    if current.phase == "running" and current.request ~= nil then
      local pending = current.request
      local addressed = assert(pending.actors[1], "every later decision addresses its combatant")
      battle:submit(SessionFixture.replyFor(pending, {
        SessionFixture.attackChoice(addressed, 0, SessionFixture.positionTarget(2)),
      }))
    end
  end
  Assert.equal(battle:status().phase, "complete", "mutating a packet never disturbs the kernel lifetime")
  Assert.isTrue(#held.packets > beforeCount, "later packets arrive intact after an earlier mutation")
  local outcomes = 0
  for _, packet in ipairs(held.packets) do
    local record = packet --[[@as table<string, unknown>]]
    if record.result ~= nil then
      outcomes = outcomes + 1
    end
  end
  Assert.equal(outcomes, 1, "the terminal outcome is published exactly once")

  -- Delayed presentation matches the immediate headless trace for
  -- identical replies: readiness postpones but never alters mechanics.
  local function damageTrace(useHold)
    local twinParty = makeParty(
      { species = "EEVEE", level = 20, seed = 0x33333333 },
      { species = "EEVEE", level = 20, seed = 0x44444444, ability = "RUN_AWAY" }
    )
    local twinBag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
    local twinFoe = foeRecord("EEVEE", 20, 0x5EED0002)
    local twinLaunch = wildLaunch(useHold and "launch-twin-held" or "launch-twin-direct")
    local twinScenario = ScenarioFactory.fromEncounter(
      { attemptId = twinLaunch.id .. "-attempt", mon = twinFoe },
      { party = twinParty, bag = twinBag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
    )
    local record = {
      ready = not useHold,
      enters = 0,
      packets = {},
      enterPlans = {},
      readyCalls = 0,
      leaves = 0,
      leavePlans = {},
      disposed = 0,
    }
    local port = recordingPort(record)
    if not useHold then
      port = headlessPort({ ready = true, enters = 0, frames = {}, leaves = 0, disposed = 0 })
    end
    local twin = startBattle(twinLaunch, twinScenario, twinParty, twinBag, port, 0x12345678)
    if useHold then
      for _ = 1, 25 do
        twin:update()
      end
      record.ready = true
    end
    local answered = nil
    for _ = 1, 1200 do
      twin:update()
      local current = twin:status()
      if current.phase == "complete" or current.phase == "failed" then
        break
      end
      if current.phase == "running" and current.request ~= nil and current.request.requestId ~= answered then
        answered = current.request.requestId
        local addressed = assert(current.request.actors[1], "every twin decision addresses its combatant")
        twin:submit(SessionFixture.replyFor(current.request, {
          SessionFixture.attackChoice(addressed, 0, SessionFixture.positionTarget(2)),
        }))
      end
    end
    Assert.equal(twin:status().phase, "complete", "both twins settle")
    twin:dispose()
    return twinParty:partyMon(0).condition.currentHp, twinParty:partyMon(1).condition.currentHp
  end
  local directHp0, directHp1 = damageTrace(false)
  local heldHp0, heldHp1 = damageTrace(true)
  Assert.equal(heldHp0, directHp0, "delayed presentation keeps the lead health trace")
  Assert.equal(heldHp1, directHp1, "delayed presentation keeps the reserve health trace")
  battle:dispose()
end

-- Capture and escape settle as continuing outcomes: a caught or fled
-- battle with both sides standing reports capture/flee through the
-- runtime and the script-visible result code, commits its ledger once,
-- and never fabricates a draw, a loss, or a blackout conclusion.
function T.capture_and_escape_settle_as_continuing_outcomes()
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local Committer = require("libs.hgss.src.battle.HgssBattleCommitter")
  local BattleTask = require("libs.hgss.src.script.tasks.BattleTask")

  -- Capture leaves the opponent standing with full health.
  do
    local party = makeParty(
      { species = "EEVEE", level = 20, seed = 0x33333333 },
      { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" }
    )
    local bag = masterBallBag()
    local foe = foeRecord("TOTODILE", 4, 0x5EED0002)
    local launch = wildLaunch("launch-presentation-capture")
    local scenario = ScenarioFactory.fromEncounter(
      { attemptId = launch.id .. "-attempt", mon = foe },
      { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
    )
    local portRecord = { ready = true, enters = 0, frames = {}, leaves = 0, disposed = 0 }
    local battle = startBattle(launch, scenario, party, bag, headlessPort(portRecord), 0x12345678)
    local opening = driveToDecision(battle, 400)
    local request = assert(opening.request, "the capture battle asks for its opening decision")
    local actor = assert(request.actors[1], "the opening decision addresses its lead")
    local thrown, throwErr = battle:submit(SessionFixture.replyFor(request, {
      {
        actor = actor,
        kind = "item",
        payload = { item = "MASTER_BALL", target = { kind = "combatant", combatant = 2 } },
      },
    }))
    Assert.isTrue(thrown, "the guaranteed throw is accepted: " .. tostring(throwErr))
    for _ = 1, 800 do
      battle:update()
      local current = battle:status()
      if current.phase == "complete" or current.phase == "failed" then
        break
      end
    end
    -- Native captured with surviving health on both sides must never
    -- reach the health-based draw inference.
    local final = battle:status()
    Assert.equal(final.phase, "complete", "the caught battle settles")
    Assert.equal(final.result, "capture", "a caught battle with both sides standing reports capture, not draw")
    Assert.equal(final.sourceResult, BattleTask.SOURCE_WON, "capture maps to the script-visible won code")
    Assert.isTrue(party:partyMon(0).condition.currentHp > 0, "the thrower is still standing")
    Assert.equal(bag:quantity("MASTER_BALL"), 0, "the thrown ball publishes exactly once")
    local receipt = assert(Committer.receipt(launch.id), "completion carries its committer receipt")
    Assert.isTrue(receipt.committed, "the capture commits through the existing committer")
    battle:update()
    battle:update()
    Assert.equal(bag:quantity("MASTER_BALL"), 0, "repeated terminal polls never consume again")
    Assert.deepEqual(Committer.receipt(launch.id), receipt, "repeated terminal polls never republish")
    battle:dispose()
  end

  -- Successful escape leaves both sides standing with full health.
  do
    local party = makeParty(
      { species = "EEVEE", level = 20, seed = 0x55555555, ability = "RUN_AWAY" },
      { species = "EEVEE", level = 5, seed = 0x66666666, ability = "RUN_AWAY" }
    )
    local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
    local foe = foeRecord("TOTODILE", 4, 0x5EED0007)
    local launch = wildLaunch("launch-presentation-escape")
    local scenario = ScenarioFactory.fromEncounter(
      { attemptId = launch.id .. "-attempt", mon = foe },
      { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
    )
    local portRecord = { ready = true, enters = 0, frames = {}, leaves = 0, disposed = 0 }
    local battle = startBattle(launch, scenario, party, bag, headlessPort(portRecord), 0x12345678)
    local opening = driveToDecision(battle, 400)
    local request = assert(opening.request, "the escape battle asks for its opening decision")
    local actor = assert(request.actors[1], "the opening decision addresses its lead")
    local fled, fledErr = battle:submit(SessionFixture.replyFor(request, {
      { actor = actor, kind = "run", payload = {} },
    }))
    Assert.isTrue(fled, "the assured run is accepted: " .. tostring(fledErr))
    for _ = 1, 800 do
      battle:update()
      local current = battle:status()
      if current.phase == "complete" or current.phase == "failed" then
        break
      end
    end
    -- Native escaped with surviving health on both sides must never
    -- reach the health-based draw inference either.
    local final = battle:status()
    Assert.equal(final.phase, "complete", "the fled battle settles")
    Assert.equal(final.result, "flee", "a fled battle with both sides standing reports flee, not draw")
    Assert.equal(final.sourceResult, BattleTask.SOURCE_NOT_WON, "escape maps to the script-visible not-won code")
    Assert.isTrue(final.result ~= "loss", "a successful escape never fabricates a blackout conclusion")
    battle:dispose()
  end
end

return { tests = T }
