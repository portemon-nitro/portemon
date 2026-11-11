-- Frozen admission requests behind the single battle root selector: one
-- ordered request list per sanitized event with occurrence identity,
-- anchor, catalog key, caller kind, explicit admit/omit disposition,
-- and frozen playback context and topology. Redelivery under another
-- packet selects identical content, and selection without required
-- roles fails naming the role instead of guessing.
-- Headless: synthetic before/after views through the real packet
-- sanitizer and the staged manifest slot geometry.

local Assert = require("tests.support.Assert")
local BattlePresentationFlow = require("game.hgss.src.battle.BattlePresentationFlow")
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")

local T = {}

local function views()
  return {
    own = { { combatant = 1, activation = 7, side = 1, position = 1, species = "GASTLY", form = 0 } },
    foes = { { combatant = 2, activation = 9, side = 2, position = 2, species = "CHANSEY", form = 0 } },
  }
end

local function packetFor(before, after, rawEvents, launchId, packetId)
  return BattlePresentationModel.packet(before, { events = rawEvents }, after, {
    launchId = launchId,
    packetId = packetId,
  })
end

local function rawEvent(sequence, kind, cause, payload, actors, targets, move, presentation)
  local event = {
    sequence = sequence,
    kind = kind,
    cause = cause,
    audience = "public",
    payload = payload,
    actors = actors,
    targets = targets,
  }
  if move ~= nil then
    event.move = move
  end
  if presentation ~= nil then
    event.presentation = presentation
  end
  return event
end

local function select(packet, event, geometry)
  return BattlePresentationFlow.animationPlayback(packet, event, geometry)
end

function T.connected_strike_admits_with_signed_damage_and_hit_ordinal()
  local geometry = ManifestFixture.manifest().battlefield.slots
  local before = views()
  -- The connected hit carries its producer execution moment: the
  -- selector reads the moment, never the legacy move phase fields.
  local execution = {
    selectedMove = "TACKLE",
    executedMove = "TACKLE",
    moment = "use",
    branch = "default",
    attacker = { combatant = 1, activation = 7 },
    defender = { combatant = 2, activation = 9 },
    targets = { { combatant = 2, activation = 9 } },
    damage = -14,
    power = 35,
    friendship = 70,
    hitOrdinal = 2,
    hitCount = 3,
    hitCycle = 1,
  }
  local packet = packetFor(before, before, {
    rawEvent(4, "struck", { kind = "move", key = "TACKLE" }, { target = 2, hitIndex = 2, damage = 12, calculated = 14 },
      { { combatant = 1, activation = 7 } }, { { combatant = 2, activation = 9 } },
      { selected = "TACKLE", executed = "TACKLE", phase = "direct", hitOrdinal = 2, hitCount = 3, power = 35 },
      { context = {}, execution = execution }),
  }, "selection-probe", 1)
  local requests = select(packet, packet.events[1], geometry)
  Assert.equal(#requests, 1, "the strike selects one frozen request")
  local request = requests[1]
  Assert.deepEqual(
    request.identity,
    { launchId = "selection-probe", origin = "event", eventSequence = 4, ordinal = 2 },
    "the request freezes its occurrence identity from the hit cycle"
  )
  Assert.deepEqual(
    request.anchor,
    { origin = "event", eventSequence = 4, stage = "after-announcement", index = 1 },
    "the strike anchors after its attack announcement"
  )
  Assert.equal(request.effectKey, "TACKLE", "the request selects its executed key")
  Assert.equal(request.invocationKind, "move-script", "the strike names its source caller kind")
  Assert.equal(request.disposition, "admit", "the connected strike admits its root")
  Assert.equal(request.playback.context.animationVariant, 0, "the ordinary strike freezes variant zero")
  Assert.equal(request.playback.context.moveDamage, -14, "the strike freezes signed calculated damage")
  Assert.equal(request.playback.context.movePower, 35, "the strike freezes resolved power")
  Assert.equal(request.playback.topology.attacker.slot, "solo-player", "the attacker keeps its event slot")
  Assert.equal(request.playback.topology.defender.slot, "solo-enemy", "the strike freezes its native defender")
  Assert.equal(#request.playback.topology.targets, 1, "the strike keeps its ordered targets")
  Assert.deepEqual(
    request.playback.identity,
    request.identity,
    "the playback identity equals the request identity"
  )
end

function T.blocked_and_unconnected_strikes_omit_with_gate_reasons()
  local geometry = ManifestFixture.manifest().battlefield.slots
  local before = views()
  local packet = packetFor(before, before, {
    rawEvent(5, "struck", { kind = "move", key = "TACKLE" }, { target = 2, hitIndex = 1, damage = 0, calculated = 0 },
      { { combatant = 1, activation = 7 } }, { { combatant = 2, activation = 9 } },
      { selected = "TACKLE", executed = "TACKLE", phase = "direct" }),
    rawEvent(6, "protected", { kind = "move", key = "TACKLE" }, { target = 1 },
      { { combatant = 2, activation = 9 } }, { { combatant = 1, activation = 7 } },
      { selected = "TACKLE", executed = "TACKLE", phase = "direct" }),
  }, "selection-probe", 2)
  local unconnected = select(packet, packet.events[1], geometry)
  Assert.equal(unconnected[1].disposition, "omit:unconnected-strike", "the scoreless strike omits its root")
  Assert.equal(unconnected[1].identity.ordinal, 1, "the omitted call keeps its ordinal")
  local blocked = select(packet, packet.events[2], geometry)
  Assert.equal(blocked[1].disposition, "omit:incoming-protected", "the protected attack omits its ordinary root")
  Assert.equal(blocked[1].effectKey, "TACKLE", "the omitted call still names its executed key")
end

function T.charge_release_keeps_variant_one_and_native_defender()
  local geometry = ManifestFixture.manifest().battlefield.slots
  local before = views()
  -- Charge phases arrive as producer execution moments: the start
  -- uses the charging turn's self target, the release freezes the
  -- native defender selected after the cleanup, never the self slot.
  local chargeStart = {
    selectedMove = "FLY",
    executedMove = "FLY",
    moment = "charge-start",
    branch = "default",
    attacker = { combatant = 1, activation = 7 },
    defender = { combatant = 1, activation = 7 },
    targets = { { combatant = 1, activation = 7 } },
    damage = 0,
    power = 90,
    friendship = 70,
  }
  local chargeRelease = {
    selectedMove = "FLY",
    executedMove = "FLY",
    moment = "charge-release",
    branch = "default",
    attacker = { combatant = 1, activation = 7 },
    defender = { combatant = 2, activation = 9 },
    targets = { { combatant = 2, activation = 9 } },
    damage = -22,
    power = 90,
    friendship = 70,
    hitOrdinal = 1,
    hitCount = 1,
    hitCycle = 1,
  }
  local packet = packetFor(before, before, {
    rawEvent(7, "charged", { kind = "move", key = "FLY" }, { target = 1 },
      { { combatant = 1, activation = 7 } }, { { combatant = 1, activation = 7 } },
      { selected = "FLY", executed = "FLY", phase = "charge" },
      { context = {}, execution = chargeStart }),
    rawEvent(8, "struck", { kind = "move", key = "FLY" },
      { target = 2, hitIndex = 1, damage = 22, calculated = 22, release = true },
      { { combatant = 1, activation = 7 } }, { { combatant = 2, activation = 9 } },
      { selected = "FLY", executed = "FLY", phase = "direct" },
      { context = {}, execution = chargeRelease }),
  }, "selection-probe", 3)
  local charge = select(packet, packet.events[1], geometry)
  Assert.equal(charge[1].disposition, "admit", "the charge start admits its root")
  Assert.equal(charge[1].playback.context.animationVariant, 0, "the charge start freezes variant zero")
  local release = select(packet, packet.events[2], geometry)
  Assert.equal(release[1].disposition, "admit", "the release strike admits its root")
  Assert.equal(release[1].playback.context.animationVariant, 1, "the release freezes variant one")
  Assert.equal(release[1].playback.context.moveDamage, -22, "the release freezes its calculated damage")
  Assert.equal(release[1].playback.topology.defender.combatant, 2, "the release keeps its native defender")
end

function T.applied_sleep_admits_while_rest_uses_its_own_move()
  local geometry = ManifestFixture.manifest().battlefield.slots
  local before = views()
  -- Applied conditions arrive as producer operations: standard
  -- applications admit their feedback member while Rest keeps only
  -- its own move root.
  local appliedOperation = {
    kind = "status-applied",
    subject = { combatant = 2, activation = 9 },
    source = { kind = "move", key = "HYPNOSIS", actor = { combatant = 1, activation = 7 } },
    condition = "sleep",
    application = "standard",
  }
  local restOperation = {
    kind = "status-applied",
    subject = { combatant = 1, activation = 7 },
    source = { kind = "move", key = "REST", actor = { combatant = 1, activation = 7 } },
    condition = "sleep",
    application = "rest",
  }
  local packet = packetFor(before, before, {
    rawEvent(9, "status", { kind = "move", key = "HYPNOSIS" }, { target = 2, key = "sleep" },
      { { combatant = 1, activation = 7 } }, { { combatant = 2, activation = 9 } }, nil,
      { context = {}, operation = appliedOperation }),
    rawEvent(10, "status", { kind = "move", key = "REST" }, { target = 1, key = "sleep" },
      { { combatant = 1, activation = 7 } }, { { combatant = 1, activation = 7 } }, nil,
      { context = {}, operation = restOperation }),
  }, "selection-probe", 4)
  local applied = select(packet, packet.events[1], geometry)
  Assert.equal(applied[1].disposition, "admit", "the applied condition admits its feedback root")
  Assert.equal(applied[1].effectKey, "BATTLE_ANIMATION_ASLEEP", "sleep selects its feedback member")
  Assert.equal(applied[1].invocationKind, "feedback-script", "feedback names its source caller kind")
  Assert.equal(applied[1].anchor.stage, "before-feedback-message", "feedback anchors at its message boundary")
  local rest = select(packet, packet.events[2], geometry)
  Assert.equal(rest[1].disposition, "omit:rest-uses-own-move", "rest keeps its move root only")
end

function T.experience_admits_per_boundary_for_the_active_recipient()
  local geometry = ManifestFixture.manifest().battlefield.slots
  local before = views()
  -- Level feedback keys off the producer's experience-awarded
  -- operation: only the active subject admits, anchored per crossed
  -- boundary, picturing the recipient instead of the defeated foe.
  local awarded = {
    kind = "experience-awarded",
    subject = { combatant = 1, activation = 7 },
    source = { kind = "system", key = "experience" },
    active = true,
    boundaries = { { fromLevel = 8, toLevel = 9, expSegment = 1 } },
  }
  local packet = packetFor(before, before, {
    rawEvent(11, "exp", { kind = "progression", combatant = 2 },
      { combatant = 1, gained = 120, expSegments = { { level = 8 } }, levelUps = { { level = 9 } } },
      { { combatant = 2, activation = 9 } }, { { combatant = 1, activation = 7 } }, nil,
      { context = {}, operation = awarded }),
  }, "selection-probe", 5)
  local requests = select(packet, packet.events[1], geometry)
  Assert.equal(#requests, 1, "one crossed level selects one request")
  Assert.equal(requests[1].disposition, "admit", "the active recipient admits its level feedback")
  Assert.equal(requests[1].effectKey, "BATTLE_ANIMATION_LEVEL_UP", "level feedback selects its member")
  Assert.equal(requests[1].anchor.stage, "after-exp", "level feedback anchors after its experience segment")
  Assert.equal(requests[1].playback.topology.attacker.combatant, 1, "level feedback pictures its recipient")
end

function T.reserve_experience_omits_without_an_event_time_slot()
  local geometry = ManifestFixture.manifest().battlefield.slots
  local before = views()
  local packet = packetFor(before, before, {
    rawEvent(12, "exp", { kind = "progression", combatant = 2 },
      { combatant = 9, gained = 60, expSegments = {}, levelUps = {} },
      { { combatant = 2 } }, { { combatant = 9 } }),
  }, "selection-probe", 6)
  local requests = select(packet, packet.events[1], geometry)
  Assert.equal(#requests, 1, "the reserve award still selects its disposition")
  Assert.isTrue(requests[1].disposition ~= "admit", "the reserve recipient admits no battler root")
end

function T.weather_residual_admits_while_unknown_residuals_omit()
  local geometry = ManifestFixture.manifest().battlefield.slots
  local before = views()
  -- Residual feedback keys off the producer's residual operation
  -- while weather continuations ride their own operation: damaging
  -- skies admit their continuation while unmapped effects omit
  -- without facts.
  local storm = {
    kind = "weather-continued",
    subject = { combatant = 2, activation = 9 },
    source = { kind = "weather", key = "SANDSTORM" },
    weather = "sand",
    passOrdinal = 1,
  }
  local packet = packetFor(before, before, {
    rawEvent(13, "tick", { kind = "residual", key = "sandstorm" }, { combatant = 2, key = "sandstorm", amount = 5 },
      { { combatant = 2, activation = 9 } }, { { combatant = 2, activation = 9 } }, nil,
      { context = {}, operation = storm }),
    rawEvent(14, "tick", { kind = "residual", key = "mystery" }, { combatant = 2, key = "mystery", amount = 5 },
      { { combatant = 2, activation = 9 } }, { { combatant = 2, activation = 9 } }),
  }, "selection-probe", 7)
  local storm = select(packet, packet.events[1], geometry)
  Assert.equal(storm[1].disposition, "admit", "the sandstorm continuation admits its root")
  Assert.equal(storm[1].effectKey, "BATTLE_ANIMATION_WEATHER_SAND", "the storm selects its weather member")
  local unknown = select(packet, packet.events[2], geometry)
  Assert.equal(
    unknown[1].disposition,
    "omit:residual-route-pending-producer-facts",
    "unmapped residuals omit with an explicit reason"
  )
end

function T.transform_keeps_its_donor_appearance()
  local geometry = ManifestFixture.manifest().battlefield.slots
  local before = views()
  -- Transform admits its primary execution while the operation
  -- carries the detached donor appearance the sanitizer projects:
  -- the selector pictures the donor, never the pre-copy user.
  local transformExecution = {
    selectedMove = "TRANSFORM",
    executedMove = "TRANSFORM",
    moment = "use",
    branch = "default",
    attacker = { combatant = 1, activation = 7 },
    defender = { combatant = 1, activation = 7 },
    targets = { { combatant = 1, activation = 7 } },
    damage = 0,
    power = 0,
    friendship = 0,
  }
  local transformOperation = {
    kind = "transform-applied",
    subject = { combatant = 1, activation = 7 },
    source = { kind = "move", key = "TRANSFORM", actor = { combatant = 1, activation = 7 } },
    donor = { combatant = 2, activation = 9 },
    donorAppearanceInput = {
      species = "CHANSEY",
      form = 0,
      personality = 42,
      origin = { trainerId = 99 },
    },
  }
  local packet = packetFor(before, before, {
    rawEvent(15, "transformed", { kind = "move", key = "TRANSFORM" }, { target = 1, copiedFrom = 2 },
      { { combatant = 1, activation = 7 } }, { { combatant = 1, activation = 7 } },
      { selected = "TRANSFORM", executed = "TRANSFORM", phase = "direct" },
      { context = {}, execution = transformExecution, operation = transformOperation }),
  }, "selection-probe", 8)
  local requests = select(packet, packet.events[1], geometry)
  Assert.equal(requests[1].disposition, "admit", "the donor change admits its root")
  local appearance = requests[1].playback.topology.attacker.appearance
  Assert.equal(type(appearance), "table", "the donor change freezes an appearance table")
  Assert.equal(appearance.species, "CHANSEY", "the frozen appearance pictures the donor species")
end

function T.switch_intent_omits_while_missing_roles_fail_loudly()
  local geometry = ManifestFixture.manifest().battlefield.slots
  local before = views()
  local packet = packetFor(before, before, {
    rawEvent(16, "switch-intent", { kind = "move", key = "U_TURN" }, { target = 1, mode = "strike-and-leave" },
      { { combatant = 1, activation = 7 } }, { { combatant = 1, activation = 7 } },
      { selected = "U_TURN", executed = "U_TURN", phase = "direct" }),
  }, "selection-probe", 9)
  local requests = select(packet, packet.events[1], geometry)
  Assert.equal(requests[1].disposition, "omit:intent-not-a-root", "the intent itself carries no root")
  local broken = {
    sequence = 16,
    kind = "struck",
    cause = { kind = "move", key = "TACKLE" },
    audience = "public",
    payload = { target = 2, hitIndex = 1, damage = 9, calculated = 9 },
    actors = {},
    targets = {},
    move = { selected = "TACKLE", executed = "TACKLE", phase = "direct" },
    visualSeed = 4242,
  }
  local failed, failure = pcall(BattlePresentationFlow.animationPlayback, {
    launchId = "selection-probe",
    packetId = 1001,
    before = before,
    after = before,
  }, broken, geometry)
  Assert.isFalse(failed, "selection without required roles fails instead of guessing")
  Assert.isTrue(
    tostring(failure):find("actor", 1, true) ~= nil,
    "the failure names the missing role: " .. tostring(failure)
  )
end

function T.redelivery_selects_identical_content_without_packet_identity()
  local geometry = ManifestFixture.manifest().battlefield.slots
  local before = views()
  local packet = packetFor(before, before, {
    rawEvent(17, "struck", { kind = "move", key = "TACKLE" }, { target = 2, hitIndex = 1, damage = 9, calculated = 11 },
      { { combatant = 1, activation = 7 } }, { { combatant = 2, activation = 9 } },
      { selected = "TACKLE", executed = "TACKLE", phase = "direct", power = 35 }),
  }, "selection-probe", 10)
  local first = select(packet, packet.events[1], geometry)
  local replayed = BattlePresentationFlow.animationPlayback({
    launchId = "selection-probe",
    packetId = 1010,
    before = before,
    after = before,
  }, packet.events[1], geometry)
  Assert.deepEqual(replayed, first, "the same occurrence under another delivery selects identical content")
end

return { tests = T }
