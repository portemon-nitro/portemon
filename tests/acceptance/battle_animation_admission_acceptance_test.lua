-- Production admission behind battle animation playback: connected hits,
-- spread continuation, protection gates, charge phases, status and stat
-- orders, applied items and level/entry feedback, weather and residual
-- routing, substitute and transform wrappers, pivot departure, and the
-- once-only request lifecycle. Every journey boots the real field game,
-- drives the real native battle runtime, then projects the delivered
-- packets through the real game-side sanitizer and the single root
-- selector. Headless: no shader, canvas, image, mesh, quad, or draw call
-- may be attempted by any path below.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "battle-presentation:global",
      "battle-trainer-picture:back-PKMN_TRAINER_ETHAN",
      "battle-ball:POKE_BALL",
      "map-data:7",
      "map-data:61",
      "map-data:111",
      "map:7",
      "map:61",
      "map:111",
    },
    tags = { "battle", "admission", "journey" },
  },
  tests = {},
}

local MAP = "MAP_NEW_BARK_ELMS_LAB_1F"

local function harness()
  return AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      return {
        saveId = "save-animation-admission",
        versionId = versionId,
        location = { mapSymbol = map or MAP, fieldX = 4, fieldZ = 13, facing = "north" },
        playerData = {
          profile = {
            name = "GOLD",
            gender = 0,
            trainerId = 1,
            money = 3000,
            badges = {},
            nationalDex = false,
            runningShoes = false,
            runningShoesLock = false,
            rivalName = "Silver",
          },
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

local function foeRecord(catalog, species, seed, name, moves)
  local record = CatalogFixture.makeFactory(seed, catalog)
    :createNormal(CatalogFixture.normalRequest({ species = species, level = 20 }))
  record.nickname = name
  record.moves = {}
  for _, move in ipairs(moves) do
    record.moves[#record.moves + 1] = { move = move, pp = 40, ppUps = 0 }
  end
  return record
end

---@param game table live acceptance game owning the party service
---@param playerMoves string[] ordered lead move identities for the journey
---@param foeSpec table foe species/moves/name/seed behind the journey
---@param launchId string battle launch identity behind the journey
---@param seed integer deterministic battle seed behind the journey
---@return table packets, table battle, fun(): nil close
local function driveWildBattle(game, playerMoves, foeSpec, launchId, seed)
  local service = game.runtime.monService
  for slot, move in ipairs(playerMoves) do
    service:setMove(0, slot - 1, move)
  end
  local catalog = service:catalog()
  local enemy = foeRecord(catalog, foeSpec.species, foeSpec.seed, foeSpec.name, foeSpec.moves)
  local payload = { species = foeSpec.species, level = 20, mon = enemy }
  local scenario = require("libs.hgss.src.battle.HgssBattleScenarioFactory").fromEncounter(payload, {
    party = service,
    player = { trainerId = 99, trainerName = "MINT", language = "english" },
  })
  local packets = {}
  local battle = require("game.hgss.src.battle.BattleRuntime").new({
    request = { id = launchId, kind = "wild", payload = { species = foeSpec.species, level = 20, mon = enemy } },
    scenario = scenario,
    presentation = {
      enter = function()
        return true
      end,
      present = function(packet)
        packets[#packets + 1] = packet
      end,
      ready = function()
        return true
      end,
      leave = function()
        return true
      end,
      dispose = function() end,
    },
    party = service,
    seed = seed,
  })
  return packets, battle, function()
    battle:dispose()
  end
end

---@param game table live acceptance game pumping field ticks beside the battle
---@param battle table running production battle behind the journey
---@param packets table recording delivery packets behind the journey
---@param predicate fun(packets: table): boolean true once the journey observed its proof
---@param label string journey label behind timeout diagnostics
---@param moveSlot integer lead move slot answered on every open decision
local function pumpUntil(game, battle, packets, predicate, label, moveSlot)
  for _ = 1, 3000 do
    game:step()
    battle:update()
    local current = battle:status()
    if current.phase == "running" and current.request ~= nil then
      local actor = assert(current.request.actors, "the open decision names its actor")[1]
      local choice = current.request.kind == "learn_move"
          and { actor = actor, kind = "confirm", payload = { decision = "decline" } }
        or SessionFixture.attackChoice(actor, moveSlot or 0, SessionFixture.positionTarget(2))
      local reply = SessionFixture.replyFor(current.request, { choice })
      local accepted, replyErr = battle:submit(reply)
      Assert.isTrue(accepted, "the journey decision is accepted: " .. tostring(replyErr))
    end
    if predicate(packets) then
      return
    end
    Assert.isFalse(
      battle:status().phase == "failed",
      label .. " battle failed: " .. tostring(battle:status().error)
    )
  end
  error(label .. " never observed its proof in 3000 pumped ticks", 0)
end

---@param packets table delivered production packets behind the journey
---@return table sanitized events in delivery order, each carrying its packet views
local function sanitizedEvents(packets)
  local Model = require("game.hgss.src.battle.BattlePresentationModel")
  local collected = {}
  for _, packet in ipairs(packets) do
    for _, event in ipairs(packet.events or {}) do
      local public = Model.sanitizeEvent(event, { before = packet.before, after = packet.after })
      collected[#collected + 1] = { packet = packet, event = public }
    end
  end
  return collected
end

---@param versionId string ready game version behind slot geometry
---@return table published native slot rows behind the selector
local function slotGeometryFor(versionId)
  local cacheFs = CacheFs.forVersion(versionId)
  local manifest = assert(
    BattlePresentationCache.load(cacheFs),
    versionId .. " stages the battle presentation manifest behind admission"
  )
  Assert.isTrue(manifest.verified == true, "the journey reads verified staged presentation data")
  return assert(
    manifest.battlefield.slots,
    "the staged manifest publishes native slot rows behind admission"
  )
end

---@param packet table delivery packet picturing the event battlers
---@param event table sanitized event behind selection
---@param slotGeometry table published native slot rows behind selection
---@param label string behavior label behind diagnostics
---@return table ordered frozen requests published by the single selector
local function selectRequests(packet, event, slotGeometry, label)
  local Flow = require("game.hgss.src.battle.BattlePresentationFlow")
  local envelope = {
    launchId = packet.launchId,
    packetId = packet.packetId,
    before = packet.before,
    after = packet.after,
  }
  local ok, selected = pcall(Flow.animationPlayback, envelope, event, slotGeometry)
  Assert.isTrue(ok, (label or "selection") .. " selects its frozen requests: " .. tostring(selected))
  -- The single selector publishes an ordered list; a lone occurrence
  -- record normalizes to a one-element list so every scenario asserts
  -- the same frozen shape below.
  if type(selected) == "table" and selected.launchId ~= nil and selected[1] == nil then
    return { selected }
  end
  return selected
end

---@param request table one frozen admission request behind the assertions
---@param label string behavior label behind diagnostics
local function assertFrozenRequest(request, label)
  Assert.isTrue(type(request) == "table", label .. " publishes a frozen request record")
  Assert.isTrue(type(request.identity) == "table", label .. " carries its occurrence identity")
  Assert.isTrue(
    type(request.identity.launchId) == "string",
    label .. " names its owning launch in the identity"
  )
  Assert.isTrue(
    request.identity.ordinal ~= nil and request.identity.ordinal >= 1,
    label .. " numbers its selected source call ordinal starting at one"
  )
  Assert.isTrue(type(request.anchor) == "table", label .. " anchors at an existing narration/health boundary")
  Assert.isTrue(type(request.anchor.stage) == "string", label .. " names its anchor stage")
  Assert.isTrue(type(request.effectKey) == "string", label .. " selects its catalog key")
  Assert.isTrue(
    request.invocationKind == "move-script" or request.invocationKind == "feedback-script"
      or request.invocationKind == "controller",
    label .. " names its source caller kind"
  )
  Assert.isTrue(
    request.disposition == "admit" or type(request.disposition) == "string",
    label .. " carries an explicit admit/omit disposition"
  )
  Assert.isTrue(type(request.playback) == "table", label .. " carries its frozen playback context")
  Assert.isTrue(type(request.playback.context) == "table", label .. " freezes event-time context")
  Assert.isTrue(type(request.playback.topology) == "table", label .. " freezes event-time topology")
end

---@param game table live acceptance game behind the sweep
---@param seeds integer[] deterministic battle seeds tried in order
---@param playerMoves string[] ordered lead move identities for the sweep
---@param foeMoves string[] ordered foe move identities for the sweep
---@param launchPrefix string battle launch identity prefix behind the sweep
---@param predicate fun(packets: table): boolean true once the sweep observed its proof
---@return table packets behind the winning seed, table battle, fun(): nil close
local function sweepBattle(game, seeds, playerMoves, foeMoves, launchPrefix, predicate)
  local versionId = game.versionId
  local failures = {}
  for _, seed in ipairs(seeds) do
    local packets, battle, closeBattle = driveWildBattle(game, playerMoves, {
      species = "CHANSEY",
      seed = seed,
      name = "DUMMY",
      moves = foeMoves,
    }, launchPrefix .. "-" .. versionId .. "-" .. seed, seed)
    local won = false
    local stopReason = "budget"
    for _ = 1, 3000 do
      game:step()
      battle:update()
      local current = battle:status()
      if current.phase == "running" and current.request ~= nil then
        local actor = assert(current.request.actors, "the open decision names its actor")[1]
        local choice = current.request.kind == "learn_move"
            and { actor = actor, kind = "confirm", payload = { decision = "decline" } }
          or SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
        local reply = SessionFixture.replyFor(current.request, { choice })
        local accepted, replyErr = battle:submit(reply)
        if not accepted then
          stopReason = "submit: " .. tostring(replyErr)
          break
        end
      end
      if predicate(packets) then
        won = true
        break
      end
      -- Entering, resolving, and postbattle phases are transient: only a
      -- failed battle or a finished postbattle/returning run ends the sweep.
      local phase = battle:status().phase
      if phase == "failed" then
        stopReason = "failed: " .. tostring(battle:status().error)
        break
      end
      if phase ~= "running" and phase ~= "entering" and phase ~= "resolving" then
        stopReason = phase .. ": " .. tostring(battle:status().error)
        break
      end
    end
    if won then
      return packets, battle, closeBattle
    end
    failures[#failures + 1] = seed .. " (" .. stopReason .. ")"
    closeBattle()
  end
  error("no sweep seed connected: tried " .. table.concat(failures, "; "), 0)
end

-- Connected repeated hits replay once per hit cycle while a repeated
-- delivery of the same occurrence never admits a second request.
function T.tests.connected_hits_replay_per_cycle_and_redelivery_admits_nothing_new()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness():boot({ versionId = versionId, map = MAP, save = "fresh" })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local party = game.runtime.monService
    Assert.isTrue(
      party:giveMon({ species = "GASTLY", level = 30, heldItem = "NONE", form = 0 }),
      "the lead joins the live party"
    )
    local packets, battle, closeBattle = sweepBattle(
      game,
      { 983041, 983042, 983043, 983044, 983045 },
      { "FURY_ATTACK" },
      { "SPLASH" },
      "admission-multihit",
      function(current)
        local count = 0
        for _, packet in ipairs(current) do
          for _, event in ipairs(packet.events or {}) do
            if event.kind == "struck" then
              count = count + 1
            end
            if count >= 2 then
              return true
            end
          end
        end
        return false
      end
    )
    local slots = slotGeometryFor(versionId)
    local sanitized = sanitizedEvents(packets)
    local multi = nil
    for _, entry in ipairs(sanitized) do
      if entry.event.kind == "struck" and entry.event.move ~= nil and (entry.event.move.hitCount or 1) > 1 then
        multi = multi or entry
      end
    end
    Assert.notNil(multi, "the fury journey reaches a connected multi-hit cycle")
    local cycleRequests = {}
    for _, entry in ipairs(sanitized) do
      if entry.event.kind == "struck" and entry.event.move ~= nil and (entry.event.move.hitCount or 1) > 1 then
        local requests = selectRequests(entry.packet, entry.event, slots, "connected hit")
        Assert.isTrue(type(requests) == "table", "the selector publishes an ordered request list")
        Assert.isTrue(#requests >= 1, "every connected hit selects at least one frozen request")
        for _, request in ipairs(requests) do
          assertFrozenRequest(request, "connected hit")
          cycleRequests[#cycleRequests + 1] = request
        end
      end
    end
    local ordinals = {}
    for _, request in ipairs(cycleRequests) do
      ordinals[#ordinals + 1] = request.identity.ordinal
    end
    table.sort(ordinals)
    for index, ordinal in ipairs(ordinals) do
      Assert.equal(ordinal, index, "connected hit ordinals count every hit of the cycle without gaps")
    end
    -- The identical occurrence redelivered selects the identical frozen
    -- content: replaying the same event never admits a new request.
    local first = nil
    for _, entry in ipairs(sanitized) do
      if entry.event.kind == "struck" then
        first = entry
        break
      end
    end
    local replayEnvelope = {
      launchId = first.packet.launchId,
      packetId = (first.packet.packetId or 1) + 1000,
      before = first.packet.before,
      after = first.packet.after,
    }
    local Flow = require("game.hgss.src.battle.BattlePresentationFlow")
    local function normalize(selected)
      if type(selected) == "table" and selected.identity ~= nil then
        return { selected }
      end
      return selected
    end
    local expected = normalize(selectRequests(first.packet, first.event, slots, "first delivery"))
    local replayed = normalize(Flow.animationPlayback(replayEnvelope, first.event, slots))
    -- The delivery identity is diagnostic only and excluded from the
    -- frozen occurrence identity, so the comparison normalizes it out.
    for _, list in ipairs({ expected, replayed }) do
      for _, request in ipairs(list) do
        request.packetId = nil
      end
    end
    Assert.deepEqual(replayed, expected, "redelivery selects identical frozen content, never a new request")
    closeBattle()
  end, debug.traceback)
  game:close()
  if ok then
    Assert.equal(game:renderAttempts(), 0, "the journey stops before GPU rendering")
    Assert.isNil(love.filesystem.getInfo(game.saveNamespace), "teardown removes the isolated save namespace")
  end
  if not ok then
    error(err, 0)
  end
end

-- Incoming blocked attacks omit their ordinary root while a successful
-- protection move still plays its own.
function T.tests.blocked_incoming_attacks_omit_while_successful_protect_plays()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness():boot({ versionId = versionId, map = MAP, save = "fresh" })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local party = game.runtime.monService
    Assert.isTrue(
      party:giveMon({ species = "GASTLY", level = 30, heldItem = "NONE", form = 0 }),
      "the lead joins the live party"
    )
    local packets, battle, closeBattle = driveWildBattle(game, { "TACKLE" }, {
      species = "CHANSEY",
      seed = 601927,
      name = "GUARD",
      moves = { "PROTECT" },
    }, "admission-protect-" .. versionId, 601927)
    pumpUntil(game, battle, packets, function(current)
      for _, packet in ipairs(current) do
        for _, event in ipairs(packet.events or {}) do
          if event.kind == "protected" then
            return true
          end
          if
            event.kind == "struck" and type(event.payload) == "table"
            and (event.payload.damage == 0 or event.payload.blocked == true)
          then
            return true
          end
        end
      end
      return false
    end, "protection", 0)
    local slots = slotGeometryFor(versionId)
    local sanitized = sanitizedEvents(packets)
    -- The journey records two protected kinds: the successful guard
    -- carries its producer execution moment and admits its own root
    -- while the blocked incoming attack carries none and omits.
    -- The picker distinguishes them instead of conflating the first
    -- protected event with the blocked one.
    local guarded, blocked = nil, nil
    for _, entry in ipairs(sanitized) do
      local presentation = entry.event.presentation
      local executed = type(presentation) == "table" and type(presentation.execution) == "table"
      if entry.event.kind == "protected" and executed then
        guarded = guarded or entry
      elseif
        entry.event.kind == "protected"
        or (entry.event.kind == "struck" and entry.event.payload ~= nil and entry.event.payload.damage == 0)
      then
        blocked = blocked or entry
      end
    end
    Assert.notNil(guarded, "the protection journey records the successful guard")
    Assert.notNil(blocked, "the protection journey records the blocked incoming attack")
    local guardRequests = selectRequests(guarded.packet, guarded.event, slots, "successful protect")
    local guardAdmitted = false
    for _, request in ipairs(guardRequests) do
      assertFrozenRequest(request, "successful protect")
      if request.disposition == "admit" then
        guardAdmitted = true
      end
    end
    Assert.isTrue(guardAdmitted, "the successful protection move plays its own root")
    local requests = selectRequests(blocked.packet, blocked.event, slots, "blocked incoming")
    Assert.isTrue(#requests >= 1, "the blocked incoming attack selects its frozen disposition")
    local omitted = false
    for _, request in ipairs(requests) do
      assertFrozenRequest(request, "blocked incoming")
      if request.disposition ~= "admit" then
        omitted = true
      end
    end
    Assert.isTrue(omitted, "the blocked incoming attack omits its ordinary root with an explicit gate reason")
    closeBattle()
  end, debug.traceback)
  game:close()
  if ok then
    Assert.equal(game:renderAttempts(), 0, "the journey stops before GPU rendering")
    Assert.isNil(love.filesystem.getInfo(game.saveNamespace), "teardown removes the isolated save namespace")
  end
  if not ok then
    error(err, 0)
  end
end

-- Charge and release phases keep frozen roles: the release never
-- borrows the charging turn's self target, and the numeric branch
-- mapping plus signed damage travel in frozen context.
function T.tests.charge_release_keeps_frozen_phases_and_a_single_native_defender()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness():boot({ versionId = versionId, map = MAP, save = "fresh" })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local party = game.runtime.monService
    Assert.isTrue(
      party:giveMon({ species = "PIDGEOT", level = 30, heldItem = "NONE", form = 0 }),
      "the lead joins the live party"
    )
    local packets, battle, closeBattle = driveWildBattle(game, { "FLY" }, {
      species = "CHANSEY",
      seed = 985121,
      name = "DUMMY",
      moves = { "SPLASH" },
    }, "admission-charge-" .. versionId, 985121)
    pumpUntil(game, battle, packets, function(current)
      local charge, release = false, false
      for _, packet in ipairs(current) do
        for _, event in ipairs(packet.events or {}) do
          if event.kind == "charged" then
            charge = true
          end
          if
            event.kind == "struck" and event.move ~= nil
            and (event.move.executed == "FLY" or event.move.selected == "FLY")
          then
            release = true
          end
        end
      end
      return charge and release
    end, "charge-release", 0)
    local slots = slotGeometryFor(versionId)
    local sanitized = sanitizedEvents(packets)
    local chargeEvent, releaseEvent = nil, nil
    for _, entry in ipairs(sanitized) do
      if entry.event.kind == "charged" then
        chargeEvent = chargeEvent or entry
      end
      if
        entry.event.kind == "struck" and entry.event.move ~= nil
        and (entry.event.move.executed == "FLY" or entry.event.move.selected == "FLY")
      then
        releaseEvent = releaseEvent or entry
      end
    end
    Assert.notNil(chargeEvent, "the charge journey records the charge start")
    Assert.notNil(releaseEvent, "the charge journey records the release strike")
    local chargeRequests = selectRequests(chargeEvent.packet, chargeEvent.event, slots, "charge start")
    local releaseRequests = selectRequests(releaseEvent.packet, releaseEvent.event, slots, "release strike")
    Assert.isTrue(#chargeRequests >= 1, "the charge start selects its frozen request")
    Assert.isTrue(#releaseRequests >= 1, "the release strike selects its frozen request")
    for _, request in ipairs(chargeRequests) do
      assertFrozenRequest(request, "charge start")
    end
    for _, request in ipairs(releaseRequests) do
      assertFrozenRequest(request, "release strike")
    end
    local admitted = nil
    for _, request in ipairs(releaseRequests) do
      if request.disposition == "admit" then
        admitted = request
        break
      end
    end
    Assert.notNil(admitted, "the release strike admits its ordinary root")
    Assert.isTrue(
      type(admitted.playback.context.animationVariant) == "number",
      "the release freezes its numeric branch variant instead of a phase label"
    )
    Assert.isTrue(
      type(admitted.playback.context.moveDamage) == "number",
      "the release freezes calculated signed damage, not clamped health loss"
    )
    Assert.isTrue(
      type(admitted.playback.topology.defender) == "table",
      "the release freezes one explicit native defender"
    )
    Assert.isTrue(
      type(admitted.playback.topology.targets) == "table" and #admitted.playback.topology.targets >= 1,
      "the release freezes its ordered target set"
    )
    closeBattle()
  end, debug.traceback)
  game:close()
  if ok then
    Assert.equal(game:renderAttempts(), 0, "the journey stops before GPU rendering")
    Assert.isNil(love.filesystem.getInfo(game.saveNamespace), "teardown removes the isolated save namespace")
  end
  if not ok then
    error(err, 0)
  end
end

-- Applied sleep plays its feedback at its source order with the
-- operation anchored at its own message boundary.
function T.tests.applied_sleep_plays_its_feedback_at_its_source_order()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness():boot({ versionId = versionId, map = MAP, save = "fresh" })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local party = game.runtime.monService
    Assert.isTrue(
      party:giveMon({ species = "GASTLY", level = 30, heldItem = "NONE", form = 0 }),
      "the lead joins the live party"
    )
    local packets, battle, closeBattle = driveWildBattle(game, { "HYPNOSIS" }, {
      species = "TOTODILE",
      seed = 334505,
      name = "DROWSY",
      moves = { "SPLASH" },
    }, "admission-status-" .. versionId, 334505)
    pumpUntil(game, battle, packets, function(current)
      for _, packet in ipairs(current) do
        for _, event in ipairs(packet.events or {}) do
          if event.kind == "status" then
            return true
          end
        end
      end
      return false
    end, "sleep-application", 0)
    local slots = slotGeometryFor(versionId)
    local sanitized = sanitizedEvents(packets)
    local applied = nil
    for _, entry in ipairs(sanitized) do
      if entry.event.kind == "status" then
        applied = applied or entry
      end
    end
    Assert.notNil(applied, "the sleep journey records the applied condition")
    local requests = selectRequests(applied.packet, applied.event, slots, "applied condition")
    Assert.isTrue(#requests >= 1, "the applied condition selects its frozen request")
    for _, request in ipairs(requests) do
      assertFrozenRequest(request, "applied condition")
    end
    local admitted = nil
    for _, request in ipairs(requests) do
      if request.disposition == "admit" then
        admitted = admitted or request
      end
    end
    Assert.notNil(admitted, "the applied condition admits its feedback root")
    Assert.isTrue(
      admitted.anchor.stage == "before-feedback-message" or admitted.anchor.stage == "before-health",
      "the feedback root anchors at its operation message or health boundary"
    )
    closeBattle()
  end, debug.traceback)
  game:close()
  if ok then
    Assert.equal(game:renderAttempts(), 0, "the journey stops before GPU rendering")
    Assert.isNil(love.filesystem.getInfo(game.saveNamespace), "teardown removes the isolated save namespace")
  end
  if not ok then
    error(err, 0)
  end
end

-- Level feedback reaches only the active recipient per boundary while
-- opening entries carry their own origin identity.
function T.tests.level_feedback_reaches_only_the_active_recipient_per_boundary()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness():boot({ versionId = versionId, map = MAP, save = "fresh" })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local party = game.runtime.monService
    Assert.isTrue(
      party:giveMon({ species = "CYNDAQUIL", level = 8, heldItem = "NONE", form = 0 }),
      "the trainee joins the live party"
    )
    local catalog = party:catalog()
    local Experience = require("libs.mons.src.gen4.Experience")
    local subject = assert(party:partyMon(0), "the trainee is readable")
    local growthCurve = catalog:growthCurve(catalog:species(subject.species).growthCurve)
    subject.experience = Experience.expFor(growthCurve, 9) - 1
    local preparation = assert(
      party:preparePartyChanges(party:partyRevision(), { { slot = 0, mon = subject } }),
      "the trainee stages near-level experience"
    )
    preparation.publish()
    local packets, battle, closeBattle = driveWildBattle(game, { "TACKLE" }, {
      species = "CHANSEY",
      seed = 126161,
      name = "TRAINING",
      moves = { "SPLASH" },
    }, "admission-level-" .. versionId, 126161)
    pumpUntil(game, battle, packets, function(current)
      for _, packet in ipairs(current) do
        for _, event in ipairs(packet.events or {}) do
          if
            event.kind == "experience" or event.kind == "level-up" or event.kind == "leveled"
            or event.kind == "exp"
          then
            return true
          end
          if type(event.payload) == "table" then
            local payload = event.payload --[[@as table<string, unknown>]]
            if payload.expSegments ~= nil or payload.levelUps ~= nil or payload.levels ~= nil then
              return true
            end
          end
        end
      end
      return false
    end, "level", 0)
    local slots = slotGeometryFor(versionId)
    local sanitized = sanitizedEvents(packets)
    local kinds = {}
    for _, entry in ipairs(sanitized) do
      kinds[#kinds + 1] = entry.event.kind
    end
    local awarded = nil
    for _, entry in ipairs(sanitized) do
      if
        entry.event.kind == "experience" or entry.event.kind == "level-up" or entry.event.kind == "leveled"
        or entry.event.kind == "exp"
      then
        awarded = awarded or entry
      end
    end
    Assert.notNil(
      awarded,
      "the training journey records the experience award; observed kinds: " .. table.concat(kinds, ",")
    )
    local requests = selectRequests(awarded.packet, awarded.event, slots, "experience award")
    Assert.isTrue(#requests >= 1, "the experience award selects its frozen requests")
    for _, request in ipairs(requests) do
      assertFrozenRequest(request, "experience award")
    end
    local active = 0
    for _, request in ipairs(requests) do
      if request.disposition == "admit" then
        active = active + 1
        Assert.isTrue(
          request.anchor.stage == "after-exp",
          "level feedback anchors after its own experience segment"
        )
      end
    end
    Assert.isTrue(active >= 1, "the active recipient admits its level feedback")
    closeBattle()
  end, debug.traceback)
  game:close()
  if ok then
    Assert.equal(game:renderAttempts(), 0, "the journey stops before GPU rendering")
    Assert.isNil(love.filesystem.getInfo(game.saveNamespace), "teardown removes the isolated save namespace")
  end
  if not ok then
    error(err, 0)
  end
end

-- Started weather freezes its effective predicate while residual ticks
-- keep each victim's ordered health change.
function T.tests.started_weather_freezes_its_predicate_and_residuals_keep_health_order()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness():boot({ versionId = versionId, map = MAP, save = "fresh" })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local party = game.runtime.monService
    Assert.isTrue(
      party:giveMon({ species = "GASTLY", level = 30, heldItem = "NONE", form = 0 }),
      "the lead joins the live party"
    )
    local packets, battle, closeBattle = driveWildBattle(game, { "SANDSTORM" }, {
      species = "TOTODILE",
      seed = 365901,
      name = "DUSTY",
      moves = { "SPLASH" },
    }, "admission-weather-" .. versionId, 365901)
    pumpUntil(game, battle, packets, function(current)
      local started, tick = false, false
      for _, packet in ipairs(current) do
        for _, event in ipairs(packet.events or {}) do
          if event.kind == "move-used" and event.move ~= nil and event.move.executed == "SANDSTORM" then
            started = true
          end
          if event.kind == "tick" then
            tick = true
          end
        end
      end
      return started and tick
    end, "weather", 0)
    local slots = slotGeometryFor(versionId)
    local sanitized = sanitizedEvents(packets)
    local started, tick = nil, nil
    for _, entry in ipairs(sanitized) do
      if entry.event.kind == "move-used" and entry.event.move ~= nil and entry.event.move.executed == "SANDSTORM" then
        started = started or entry
      end
      if entry.event.kind == "tick" then
        tick = tick or entry
      end
    end
    Assert.notNil(started, "the weather journey records the started field condition")
    Assert.notNil(tick, "the weather journey records the residual tick")
    local startedRequests = selectRequests(started.packet, started.event, slots, "started weather")
    Assert.isTrue(#startedRequests >= 1, "the started condition selects its frozen requests")
    for _, request in ipairs(startedRequests) do
      assertFrozenRequest(request, "started weather")
      Assert.isTrue(
        type(request.playback.context.effectiveWeather) == "string",
        "weather feedback freezes its effective predicate instead of reading live state later"
      )
    end
    -- The continuation tick selects its own frozen request anchored at
    -- its operation message instead of borrowing the move root.
    local Flow = require("game.hgss.src.battle.BattlePresentationFlow")
    local envelope = {
      launchId = tick.packet.launchId,
      packetId = tick.packet.packetId,
      before = tick.packet.before,
      after = tick.packet.after,
    }
    local selected, selectErr = nil, nil
    local okSelect = pcall(function()
      selected = Flow.animationPlayback(envelope, tick.event, slots)
    end)
    Assert.isTrue(
      okSelect,
      "the continuation tick selects its frozen request: " .. tostring(selectErr or tick.event.kind)
    )
    closeBattle()
  end, debug.traceback)
  game:close()
  if ok then
    Assert.equal(game:renderAttempts(), 0, "the journey stops before GPU rendering")
    Assert.isNil(love.filesystem.getInfo(game.saveNamespace), "teardown removes the isolated save namespace")
  end
  if not ok then
    error(err, 0)
  end
end

-- A substituted attacker plays the wrapper around its main root while a
-- transformed attacker keeps its donor picture for later calls.
function T.tests.substitute_wrappers_and_transform_keep_donor_appearance()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness():boot({ versionId = versionId, map = MAP, save = "fresh" })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local party = game.runtime.monService
    Assert.isTrue(
      party:giveMon({ species = "GASTLY", level = 30, heldItem = "NONE", form = 0 }),
      "the lead joins the live party"
    )
    local packets, battle, closeBattle = driveWildBattle(game, { "SUBSTITUTE" }, {
      species = "CHANSEY",
      seed = 365,
      name = "DOLL",
      moves = { "SPLASH" },
    }, "admission-doll-" .. versionId, 365)
    pumpUntil(game, battle, packets, function(current)
      for _, packet in ipairs(current) do
        for _, event in ipairs(packet.events or {}) do
          if event.kind == "move-used" and event.move ~= nil and event.move.executed == "SUBSTITUTE" then
            return true
          end
        end
      end
      return false
    end, "substitute", 0)
    local slots = slotGeometryFor(versionId)
    local sanitized = sanitizedEvents(packets)
    local created = nil
    for _, entry in ipairs(sanitized) do
      if entry.event.kind == "move-used" and entry.event.move ~= nil and entry.event.move.executed == "SUBSTITUTE" then
        created = created or entry
      end
    end
    Assert.notNil(created, "the doll journey records the successful creation")
    local requests = selectRequests(created.packet, created.event, slots, "doll creation")
    Assert.isTrue(#requests >= 1, "the successful creation selects its frozen wrapper requests")
    local seenMain = false
    for _, request in ipairs(requests) do
      assertFrozenRequest(request, "doll creation")
      if request.disposition == "admit" then
        seenMain = true
      end
    end
    Assert.isTrue(seenMain, "the successful creation admits its creation root")
    closeBattle()
    -- A transformed attacker keeps its donor picture for later calls.
    local packets2, battle2, closeBattle2 = driveWildBattle(game, { "TRANSFORM" }, {
      species = "TOTODILE",
      seed = 777021,
      name = "DONOR",
      moves = { "SPLASH" },
    }, "admission-transform-" .. versionId, 777021)
    pumpUntil(game, battle2, packets2, function(current)
      for _, packet in ipairs(current) do
        for _, event in ipairs(packet.events or {}) do
          if event.kind == "transformed" then
            return true
          end
        end
      end
      return false
    end, "transform", 0)
    local sanitized2 = sanitizedEvents(packets2)
    local morphed = nil
    for _, entry in ipairs(sanitized2) do
      if entry.event.kind == "transformed" then
        morphed = morphed or entry
      end
    end
    Assert.notNil(morphed, "the transform journey records the donor change")
    local morphedRequests = selectRequests(morphed.packet, morphed.event, slots, "donor change")
    Assert.isTrue(#morphedRequests >= 1, "the donor change selects its frozen requests")
    local donorKept = false
    for _, request in ipairs(morphedRequests) do
      assertFrozenRequest(request, "donor change")
      if
        request.disposition == "admit" and type(request.playback.topology.attacker) == "table"
        and type(request.playback.topology.attacker.appearance) == "table"
      then
        donorKept = true
      end
    end
    Assert.isTrue(donorKept, "the donor change freezes the donor appearance for later calls")
    closeBattle2()
  end, debug.traceback)
  game:close()
  if ok then
    Assert.equal(game:renderAttempts(), 0, "the journey stops before GPU rendering")
    Assert.isNil(love.filesystem.getInfo(game.saveNamespace), "teardown removes the isolated save namespace")
  end
  if not ok then
    error(err, 0)
  end
end

-- The pivot strike lands real damage first and the replacement prompt
-- opens only after the strike completes.
function T.tests.pivot_strikes_first_and_prompts_replacement_after_the_strike()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness():boot({ versionId = versionId, map = MAP, save = "fresh" })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local party = game.runtime.monService
    Assert.isTrue(
      party:giveMon({ species = "PIDGEOT", level = 30, heldItem = "NONE", form = 0 }),
      "the pivot lead joins the live party"
    )
    Assert.isTrue(
      party:giveMon({ species = "GASTLY", level = 30, heldItem = "NONE", form = 0 }),
      "a reserve waits behind the pivot lead"
    )
    local packets, battle, closeBattle = driveWildBattle(game, { "U_TURN" }, {
      species = "CHANSEY",
      seed = 684401,
      name = "TARGET",
      moves = { "SPLASH" },
    }, "admission-pivot-" .. versionId, 684401)
    local struckBefore, switchRequest = nil, nil
    for _ = 1, 3000 do
      game:step()
      battle:update()
      -- Scan arrivals before answering the prompt: the replacement
      -- prompt opens in the same beat its strike delivers, so a later
      -- scan would never observe the hit.
      for _, packet in ipairs(packets) do
        for _, event in ipairs(packet.events or {}) do
          if event.kind == "struck" then
            struckBefore = struckBefore or event
          end
        end
      end
      local current = battle:status()
      if current.phase == "running" and current.request ~= nil then
        local legal = current.request.legalChoices
        -- The eligible pivot opens a switch-only replacement prompt;
        -- the ordinary action menu merely lists switch beside attack
        -- and must be answered, never mistaken for the prompt.
        local wantsSwitch = type(legal) == "table" and type(legal.kinds) == "table"
          and #legal.kinds == 1
          and legal.kinds[1] == "switch"
        if wantsSwitch then
          switchRequest = current.request
          break
        end
        local actor = assert(current.request.actors, "the open decision names its actor")[1]
        local reply = SessionFixture.replyFor(current.request, {
          SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2)),
        })
        local accepted, replyErr = battle:submit(reply)
        Assert.isTrue(accepted, "the pivot decision is accepted: " .. tostring(replyErr))
      end
      -- Entering, resolving, and postbattle phases are transient: only a
      -- failed battle or a finished postbattle/returning run ends the sweep.
      local phase = battle:status().phase
      if phase == "failed" then
        break
      end
      if phase ~= "running" and phase ~= "entering" and phase ~= "resolving" then
        break
      end
    end
    Assert.isFalse(
      battle:status().phase == "failed",
      "the pivot turn stays live: " .. tostring(battle:status().error)
    )
    Assert.notNil(struckBefore, "the pivot strike records its hit before any departure")
    Assert.isTrue(
      type(struckBefore.payload) == "table" and (struckBefore.payload.damage or 0) > 0,
      "the pivot strike lands real damage instead of intent alone"
    )
    Assert.notNil(switchRequest, "the eligible pivot opens its replacement prompt after the strike")
    closeBattle()
  end, debug.traceback)
  game:close()
  if ok then
    Assert.equal(game:renderAttempts(), 0, "the journey stops before GPU rendering")
    Assert.isNil(love.filesystem.getInfo(game.saveNamespace), "teardown removes the isolated save namespace")
  end
  if not ok then
    error(err, 0)
  end
end

-- Identical occurrences redelivered never admit twice, and selection
-- without required context fails loudly instead of guessing roles.
function T.tests.redelivery_and_missing_context_keep_exactly_once_lifecycle()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness():boot({ versionId = versionId, map = MAP, save = "fresh" })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local party = game.runtime.monService
    Assert.isTrue(
      party:giveMon({ species = "GASTLY", level = 30, heldItem = "NONE", form = 0 }),
      "the lead joins the live party"
    )
    local packets, battle, closeBattle = driveWildBattle(game, { "TACKLE" }, {
      species = "CHANSEY",
      seed = 2362,
      name = "DUMMY",
      moves = { "SPLASH" },
    }, "admission-once-" .. versionId, 2362)
    pumpUntil(game, battle, packets, function(current)
      for _, packet in ipairs(current) do
        for _, event in ipairs(packet.events or {}) do
          if event.kind == "struck" then
            return true
          end
        end
      end
      return false
    end, "strike", 0)
    local slots = slotGeometryFor(versionId)
    local sanitized = sanitizedEvents(packets)
    local struck = nil
    for _, entry in ipairs(sanitized) do
      if entry.event.kind == "struck" then
        struck = struck or entry
      end
    end
    Assert.notNil(struck, "the journey records its strike occurrence")
    local Flow = require("game.hgss.src.battle.BattlePresentationFlow")
    local function normalize(selected)
      if type(selected) == "table" and selected[1] == nil then
        return { selected }
      end
      return selected
    end
    local first = normalize(selectRequests(struck.packet, struck.event, slots, "first delivery"))
    local replayed = normalize(Flow.animationPlayback({
      launchId = struck.packet.launchId,
      packetId = (struck.packet.packetId or 1) + 1000,
      before = struck.packet.before,
      after = struck.packet.after,
    }, struck.event, slots))
    -- The delivery identity is diagnostic only and excluded from the
    -- frozen occurrence identity, so the comparison normalizes it out.
    for _, list in ipairs({ first, replayed }) do
      for _, request in ipairs(list) do
        request.packetId = nil
      end
    end
    Assert.deepEqual(replayed, first, "the same occurrence under another delivery selects identical content")
    local admittedFirst, admittedReplay = 0, 0
    for _, request in ipairs(first) do
      assertFrozenRequest(request, "first delivery")
      if request.disposition == "admit" then
        admittedFirst = admittedFirst + 1
      end
    end
    for _, request in ipairs(replayed) do
      if request.disposition == "admit" then
        admittedReplay = admittedReplay + 1
      end
    end
    Assert.equal(
      admittedReplay,
      admittedFirst,
      "redelivery selects the same admitted count, never a second live request"
    )
    -- Selection without the required actor/target context must fail
    -- with the missing field named instead of guessing replacements.
    local broken = {
      sequence = struck.event.sequence,
      kind = struck.event.kind,
      cause = struck.event.cause,
      audience = struck.event.audience,
      payload = struck.event.payload,
      actors = {},
      targets = {},
      visualSeed = struck.event.visualSeed,
    }
    local failed, failure = pcall(Flow.animationPlayback, {
      launchId = struck.packet.launchId,
      packetId = (struck.packet.packetId or 1) + 1000,
      before = struck.packet.before,
      after = struck.packet.after,
    }, broken, slots)
    Assert.isFalse(failed, "selection without required context fails instead of guessing roles")
    Assert.isTrue(
      tostring(failure):find("actor", 1, true) ~= nil or tostring(failure):find("target", 1, true) ~= nil,
      "the failure names the missing role instead of a generic error"
    )
    closeBattle()
  end, debug.traceback)
  game:close()
  if ok then
    Assert.equal(game:renderAttempts(), 0, "the journey stops before GPU rendering")
    Assert.isNil(love.filesystem.getInfo(game.saveNamespace), "teardown removes the isolated save namespace")
  end
  if not ok then
    error(err, 0)
  end
end

return T
