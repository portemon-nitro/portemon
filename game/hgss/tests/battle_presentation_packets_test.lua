-- Packet projection over captured event-time facts: sanitized
-- playback events keep explicit actor/target identities with visible
-- names and appearance, typed message arguments and branch parameters,
-- ordered checkpoints, and an independent visual seed, while mistyped
-- facts fail loudly and hidden move sets never ride along. Delivery
-- integration replays a real production battle through the real cue
-- player: every packet plays once across packet identities, replays and
-- stale completions never queue again, and legacy emissions without
-- facts still play. Synthetic catalogs only; no ROM capability.

local Assert = require("tests.support.Assert")
local Model = require("game.hgss.src.battle.BattlePresentationModel")

local T = {}

---@return table<string, unknown> detached dynamic view picturing one own lead and one foe
local function views()
  local function record(combatant, hp, maxHp, own)
    return {
      combatant = combatant,
      participant = combatant,
      side = own and 1 or 2,
      controller = own and "player" or "wild",
      active = true,
      position = combatant,
      activation = combatant,
      hp = hp,
      maxHp = maxHp,
      species = "EEVEE",
      form = 0,
      name = own and "LEAD" or "FOE",
      level = 20,
      selector = own and "back" or "front",
      portraitSelector = "eevee-portrait-" .. (own and "back" or "front"),
    }
  end
  return {
    before = { own = { record(1, 20, 25, true) }, foes = { record(3, 22, 22, false) } },
    after = { own = { record(1, 20, 25, true) }, foes = { record(3, 14, 22, false) } },
  }
end

---@return table<string, unknown> native-shaped strike event carrying full playback facts
local function struckEvent()
  return {
    sequence = 7,
    kind = "struck",
    cause = { kind = "move", key = "TACKLE" },
    audience = "public",
    payload = { target = 3, hitIndex = 1, damage = 8 },
    observation = { hp = { [1] = 20, [3] = 14 }, combatants = {} },
    actors = { { combatant = 1, activation = 1, position = 1, side = 1 } },
    targets = { { combatant = 3, activation = 3, position = 2, side = 2 } },
    move = { selected = "TACKLE", executed = "TACKLE", phase = "direct", hitOrdinal = 1, hitCount = 1 },
    flowKey = "strike",
    effectKey = "TACKLE",
    checkpoints = { { combatant = 3, hp = 14, maxHp = 22 } },
    visualSeed = 99,
  }
end

-- Full playback facts survive sanitizing with visible names and
-- appearance resolved from the sanitized views only.
function T.full_facts_keep_identities_names_and_checkpoints()
  local pair = views()
  local public = Model.sanitizeEvent(struckEvent(), pair)
  Assert.equal(#public.actors, 1, "the strike keeps its single user")
  Assert.equal(public.actors[1].combatant, 1, "the user keeps its combatant identity")
  Assert.equal(public.actors[1].activation, 1, "the user keeps its entry token")
  Assert.equal(public.actors[1].name, "LEAD", "the user resolves its visible name")
  Assert.equal(public.actors[1].appearance, "eevee-portrait-back", "the user resolves its appearance")
  Assert.equal(public.targets[1].name, "FOE", "the recipient resolves its visible name")
  Assert.equal(public.move.selected, "TACKLE", "the selected identity survives")
  Assert.equal(public.move.executed, "TACKLE", "the executed identity survives")
  Assert.equal(public.move.hitOrdinal, 1, "the hit ordinal survives")
  Assert.equal(public.flowKey, "strike", "the route survives")
  Assert.equal(public.effectKey, "TACKLE", "the route selection survives")
  Assert.equal(public.visualSeed, 99, "the independent visual seed survives untouched")
  Assert.equal(#public.checkpoints, 1, "the ordered checkpoints survive")
  Assert.equal(public.checkpoints[1].hp, 14, "checkpoints keep displayed health")
  Assert.equal(public.checkpoints[1].maxHp, 22, "checkpoints keep the health ceiling")
  Assert.equal(public.messageArgs.damage, 8, "message arguments carry the typed branch value")
  Assert.equal(public.messageArgs.targetName, "FOE", "message arguments carry the visible recipient")
  Assert.equal(public.messageArgs.reason, "TACKLE", "message arguments carry the semantic reason")
  Assert.equal(public.parameters.damage, 8, "branch parameters carry the typed value")
  Assert.isTrue(public.messageArgs.moves == nil, "message arguments never carry move sets")
  Assert.isTrue(public.parameters.moves == nil, "branch parameters never carry move sets")
end

-- Legacy emissions without facts still sanitize: identities stay
-- empty, the route defaults to the kind, and the visual seed defaults
-- deterministically instead of vanishing.
function T.legacy_emissions_without_facts_still_sanitize()
  local event = {
    sequence = 3,
    kind = "healed",
    cause = { kind = "residual", key = "poison" },
    audience = "public",
    payload = { target = 1, restored = 5 },
    observation = { hp = { [1] = 20 } },
  }
  local public = Model.sanitizeEvent(event, views())
  Assert.deepEqual(public.actors, {}, "legacy events keep empty identities instead of guesses")
  Assert.deepEqual(public.targets, {}, "legacy events keep empty targets instead of guesses")
  Assert.equal(public.flowKey, "healed", "the route defaults to the honest kind")
  Assert.isTrue(type(public.visualSeed) == "number", "legacy events gain their deterministic seed")
  Assert.isTrue(type(public.messageArgs) == "table", "legacy events carry message arguments")
  Assert.isTrue(type(public.parameters) == "table", "legacy events carry branch parameters")
end

-- Mistyped playback facts fail loudly at the projection boundary:
-- an unresolved required fact is a producer failure, never a guess.
function T.mistyped_facts_fail_loudly_at_the_boundary()
  local pair = views()
  local actors = struckEvent()
  actors.actors = { { combatant = "one" } }
  Assert.throws(function()
    Model.sanitizeEvent(actors, pair)
  end, "a non-numeric combatant fails")
  local move = struckEvent()
  move.move = { selected = "TACKLE" }
  Assert.throws(function()
    Model.sanitizeEvent(move, pair)
  end, "a move without its execution fails")
  local checkpoints = struckEvent()
  checkpoints.checkpoints = { { combatant = 3, hp = 14 } }
  Assert.throws(function()
    Model.sanitizeEvent(checkpoints, pair)
  end, "a checkpoint without its ceiling fails")
end

-- Nested payload records never leak into message or branch facts, and
-- unknown combatants resolve no names: packets stay visible-only.
function T.hidden_records_never_ride_message_or_branch_facts()
  local event = struckEvent()
  event.payload = { target = 3, hitIndex = 1, damage = 8, moves = { "TACKLE", "GROWL" } }
  event.actors = { { combatant = 9, activation = 40 } }
  local public = Model.sanitizeEvent(event, views())
  Assert.isTrue(public.messageArgs.moves == nil, "message arguments skip nested move sets")
  Assert.isTrue(public.parameters.moves == nil, "branch parameters skip nested move sets")
  Assert.isTrue(public.actors[1].name == nil, "unknown battlers resolve no names")
  Assert.isTrue(public.actors[1].appearance == nil, "unknown battlers resolve no appearance")
  Assert.equal(public.actors[1].combatant, 9, "the identity itself still rides for later disclosure")
end

-- A resolved variable power survives sanitizing as a detached u16:
-- the playback move keeps the executed value, later kernel edits never
-- reach the packet, events without a resolved value omit the fact, and
-- malformed values fail loudly instead of publishing a guess.
function T.resolved_power_survives_sanitizing_detached()
  local event = struckEvent()
  event.cause = { kind = "move", key = "MAGNITUDE" }
  event.move = { selected = "MAGNITUDE", executed = "MAGNITUDE", phase = "direct", power = 90 }
  local public = Model.sanitizeEvent(event, views())
  Assert.equal(public.move.power, 90, "the sanitized move keeps the executed value")
  event.move.power = 10
  Assert.equal(public.move.power, 90, "later kernel edits never reach the packet")
  local plain = struckEvent()
  local sanitizedPlain = Model.sanitizeEvent(plain, views())
  Assert.isNil(sanitizedPlain.move.power, "events without a resolved value omit the fact")
  for _, bad in ipairs({ 1.5, -1, 65536, "90" }) do
    local broken = struckEvent()
    broken.move.power = bad
    Assert.throws(function()
      Model.sanitizeEvent(broken, views())
    end, "a malformed resolved value fails loudly: " .. tostring(bad))
  end
end

-- Packets resolve names across their before/after views and stay
-- detached from the kernel frame and the supplied views.
function T.packets_resolve_names_and_stay_detached()
  local pair = views()
  local frame = { events = { struckEvent() } }
  local packet = Model.packet(pair.before, frame, pair.after, { launchId = "launch-packets", packetId = 4 })
  Assert.equal(packet.launchId, "launch-packets", "the packet keeps its launch identity")
  Assert.equal(packet.packetId, 4, "the packet keeps its monotonic identity")
  Assert.equal(#packet.events, 1, "the packet carries its ordered events")
  Assert.equal(packet.events[1].targets[1].name, "FOE", "names resolve across the packet views")
  packet.events[1].payload.damage = 999
  packet.before.foes[1].hp = 1
  Assert.equal(frame.events[1].payload.damage, 8, "mutating the packet never reaches the kernel frame")
  Assert.equal(pair.after.foes[1].hp, 14, "mutating the packet never reaches the supplied views")
end

---@param specs table[] lead/reserve descriptions under test preparation
---@return table live party owner holding the described members
local function makeParty(specs)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local Lcrng = require("libs.mons.src.gen4.Lcrng")
  local MonsSave = require("libs.mons.src.MonsSave")
  local Party = require("libs.mons.src.Party")
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
    local record = factory:createNormal(CatalogFixture.normalRequest({ species = spec.species, level = spec.level }))
    record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
    Assert.isTrue(owner:addMon(record), "the delivery path needs its live party member")
  end
  return owner
end

-- A real production battle replays exactly once through the cue
-- player: every delivery plays under its event identity, a replay
-- under new packet identities queues nothing more, a stale completion
-- never unblocks, and draining lands each checkpoint a single time.
function T.production_deliveries_replay_exactly_once_end_to_end()
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")
  local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")
  local HgssBagService = require("libs.hgss.src.items.HgssBagService")
  local ItemFixture = require("libs.items.tests.item_fixture")
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local party = makeParty({
    { species = "EEVEE", level = 20, seed = 0x55550001 },
    { species = "EEVEE", level = 5, seed = 0x55550002 },
  })
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(0x5EED0099, catalog)
  local foe = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE", level = 4 }))
  foe.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  local launch = {
    id = "launch-packets-once",
    kind = "wild",
    payload = {
      attemptId = "once-attempt",
      species = "TOTODILE",
      form = 0,
      level = 4,
      personality = 1,
      ability = "TORRENT",
    },
  }
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launch.id .. "-attempt", mon = foe },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local held = { ready = true, packets = {} }
  local port = {
    enter = function()
      return true
    end,
    present = function(packet)
      held.packets[#held.packets + 1] = packet
    end,
    ready = function()
      return held.ready
    end,
    leave = function()
      return true
    end,
    dispose = function() end,
  }
  local battle = BattleRuntime.new({
    request = launch,
    scenario = scenario,
    party = party,
    bag = bag,
    presentation = port,
    seed = 0x00D9A001,
  })
  local opening = nil
  for _ = 1, 400 do
    battle:update()
    local current = battle:status()
    if current.phase == "running" and current.request ~= nil then
      opening = current
      break
    end
  end
  opening = assert(opening, "the battle asks for its opening decision")
  local request = assert(opening.request, "the opening decision is exposed")
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
  Assert.isTrue(#held.packets > 0, "the answered turn delivers its packets")
  -- The answered production packets carry selected native effects, so the
  -- cue player requires its animation collaborator. This exactly-once
  -- scenario owns delivery identity rather than native playback, so effects
  -- settle at once here; the live screen suite owns real completion.
  local settledEffects = {}
  function settledEffects.start(cue)
    assert(type(cue) == "table" and cue.effectKey ~= nil, "native cues carry their selected key")
    return { effectKey = cue.effectKey }
  end
  function settledEffects.status(_handle)
    return "complete"
  end
  function settledEffects.cancel(_handle) end
  local player = BattleTimeline.new({ effects = settledEffects })
  local function cueCount()
    local queue = player._queue --[[@as table<integer, unknown>]]
    local active = player._active
    return #queue + (active ~= nil and 1 or 0)
  end
  for _, packet in ipairs(held.packets) do
    Assert.isTrue(player:present(packet), "every production packet plays once")
  end
  local cues = cueCount()
  Assert.isTrue(cues > 0, "the deliveries queue their visible cues")
  -- Event identity drives exactly-once: only deliveries carrying
  -- events replay, while empty deliveries queue nothing either way.
  for _, packet in ipairs(held.packets) do
    if type(packet.events) == "table" and #packet.events > 0 then
      local replay = {}
      for key, value in pairs(packet) do
        replay[key] = value
      end
      replay.packetId = packet.packetId --[[@as integer]]
        + 5000
      Assert.isTrue(player:present(replay) == false, "a replay under a new packet identity queues nothing more")
    end
  end
  Assert.equal(cueCount(), cues, "replays queue no further visible cues")
  local stale = {
    launchId = launch.id,
    packetId = 9999,
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
    before = held.packets[1].before,
    after = held.packets[1].after,
  }
  Assert.isTrue(player:present(stale) == false, "a stale completion never unblocks a newer request")
  for _ = 1, 3600 do
    player:update(1 / 60, function(_)
      return true
    end)
    if player:settled() then
      break
    end
  end
  Assert.isTrue(player:settled(), "every delivery drains exactly once")
  battle:dispose()
end

-- Legacy emissions without playback facts still play through the cue
-- player instead of vanishing behind a diagnostic.
function T.legacy_emissions_without_facts_still_play()
  local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")
  local player = BattleTimeline.new({})
  local view = views().after
  Assert.isTrue(
    player:present({
      launchId = "launch-packets-legacy",
      packetId = 1,
      events = {
        {
          sequence = 4242,
          kind = "struck",
          cause = { key = "TACKLE" },
          audience = "public",
          payload = { target = 3, damage = 8, hitIndex = 1 },
          after = { hp = { [1] = 20, [3] = 14 } },
        },
      },
      before = views().before,
      after = view,
    }),
    "a legacy delivery without facts is accepted"
  )
  Assert.isTrue(#player._queue > 0, "the legacy delivery queues its visible cues")
end

return { tests = T }
