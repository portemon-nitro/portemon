-- Production admission behind battle animation playback: the two
-- composition risks that only a live battle can prove. A connected
-- multi-hit cycle replays once per hit with gapless ordinals through the
-- real sanitizer and selector, and a redelivered occurrence selects
-- identical frozen content without admitting a second live request while
-- selection without required context fails naming the missing role.
-- Per-scenario semantics (protection gates, charge phases, status and
-- residual routing, substitute wrappers, pivot departure) belong to the
-- headless flow-selection suite, which covers every scenario without
-- booting the field game. Every journey below boots the real field game,
-- drives the real native battle runtime, then projects the delivered
-- packets through the real game-side sanitizer and the single root
-- selector. Headless: no shader, canvas, image, mesh, quad, or draw call
-- may be attempted by any path below.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FinalizedGameFixture = require("tests.support.FinalizedGameFixture")
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
      return FinalizedGameFixture.build(versionId, {
        saveId = "save-animation-admission",
        location = { mapSymbol = map or MAP, fieldX = 4, fieldZ = 13, facing = "north" },
        mons = require("tests.support.MonBucket").emptyForVersion(versionId, 7),
      })
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
    Assert.isFalse(battle:status().phase == "failed", label .. " battle failed: " .. tostring(battle:status().error))
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
  return assert(manifest.battlefield.slots, "the staged manifest publishes native slot rows behind admission")
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
  Assert.isTrue(type(request.identity.launchId) == "string", label .. " names its owning launch in the identity")
  Assert.isTrue(
    request.identity.ordinal ~= nil and request.identity.ordinal >= 1,
    label .. " numbers its selected source call ordinal starting at one"
  )
  Assert.isTrue(type(request.anchor) == "table", label .. " anchors at an existing narration/health boundary")
  Assert.isTrue(type(request.anchor.stage) == "string", label .. " names its anchor stage")
  Assert.isTrue(type(request.effectKey) == "string", label .. " selects its catalog key")
  Assert.isTrue(
    request.invocationKind == "move-script"
      or request.invocationKind == "feedback-script"
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
