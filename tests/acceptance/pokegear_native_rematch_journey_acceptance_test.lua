-- A native phone invitation resumes through its authored field trainer
-- script, existing battle owner, and source win branch without GPU rendering.

local Assert = require("tests.support.Assert")
local Fixture = require("tests.support.PokegearJourneyFixture")
local LocalClock = require("game.src.LocalClock")
local CivilDate = require("libs.hgss.src.field.CivilDate")
local PokegearSources = require("romdump.src.config.PokegearSources")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

local DERIVED_ASSETS = {
  "field-runtime",
  "map:34",
  "map:67",
  "map-data:34",
  "map-data:67",
  "map:33",
  "map:60",
  "map-data:33",
  "map-data:60",
  "battle-presentation:global",
  "message-bank:728",
}
for _, bankId in ipairs(PokegearSources.phoneMessageBankIds()) do
  DERIVED_ASSETS[#DERIVED_ASSETS + 1] = "message-bank:" .. tostring(bankId)
end

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = DERIVED_ASSETS,
    tags = { "pokegear" },
  },
  tests = {},
}

local function contactByPhoneId(catalog, phoneId)
  for _, contact in ipairs(catalog.contacts) do
    if contact.id == phoneId then
      return contact
    end
  end
  error("the compiled phonebook contains native contact " .. tostring(phoneId), 0)
end

local function finishCall(host, handle)
  for _ = 1, 120 do
    local result = host:result(handle)
    if result ~= nil then
      return result
    end
    host:step(handle, { { type = "confirm" } })
  end
  error("the composed phone invitation reaches a terminal result", 0)
end

local function rematchObject(game)
  local fieldData = assert(game.runtime.runtimeMap.fieldData, "Route 30 supplies its compiled object events")
  for _, event in ipairs(fieldData.events.objects) do
    if event.eventFlag == Fixture.FLAGS.FLAG_HIDE_ROUTE_30_YOUNGSTER_JOEY then
      local actorId = game.runtime.actors:actorIdForMapIndex(event.objectEventId)
      if actorId ~= nil then
        return actorId, Fixture.VARS.VAR_SPECIAL_x8004
      end
    end
  end
  error(
    "Route 30 exposes the authored Joey actor and its native trainer identity variable (hideFlag="
      .. tostring(game.runtime.eventState:isFlagSet(Fixture.FLAGS.FLAG_HIDE_ROUTE_30_YOUNGSTER_JOEY))
      .. ",position="
      .. tostring(game:snapshot().player.fieldX)
      .. ","
      .. tostring(game:snapshot().player.fieldZ)
      .. ",entry="
      .. tostring(game.runtime.session.mapEntryStage ~= nil)
      .. ")",
    0
  )
end

local function alignInvitationWindow(sample, contact)
  Assert.isTrue(
    type(contact.rematchWeekday) == "number" and contact.rematchWeekday >= 0 and contact.rematchWeekday <= 6,
    "the native phonebook contact declares an invitation weekday"
  )
  Assert.isTrue(
    type(contact.rematchTime) == "number" and contact.rematchTime >= 0 and contact.rematchTime <= 2,
    "the native phonebook contact declares an invitation time"
  )
  for _ = 1, 7 do
    local _, weekday = CivilDate.parts(sample)
    if weekday == contact.rematchWeekday then
      break
    end
    sample.day = sample.day + 1
  end
  local _, weekday = CivilDate.parts(sample)
  Assert.equal(
    weekday,
    contact.rematchWeekday,
    "the phone invitation starts inside Joey's source weekday window"
  )
  sample.hour = ({ [0] = 7, [1] = 12, [2] = 21 })[contact.rematchTime]
end

local function startInteraction(game, actorId)
  local actor = assert(game.runtime.actors:getById(actorId), "the native rematch trainer remains present")
  local position = actor:getFieldPosition()
  local candidates = {
    { fieldX = position.fieldX, fieldZ = position.fieldZ + 1, facing = "north" },
    { fieldX = position.fieldX, fieldZ = position.fieldZ - 1, facing = "south" },
    { fieldX = position.fieldX + 1, fieldZ = position.fieldZ, facing = "west" },
    { fieldX = position.fieldX - 1, fieldZ = position.fieldZ, facing = "east" },
  }
  local FieldMovement = require("tests.acceptance.support.FieldMovement")
  for _, tile in ipairs(candidates) do
    if FieldMovement.route(game, tile) ~= nil then
      game:moveTo(tile)
      game:face(tile.facing)
      game:pressAction()
      if game:interaction().actorId == actorId then
        return
      end
      Assert.isTrue(Fixture.drainField(game, 240), "an adjacent interaction settles before trying another side")
    end
  end
  local current = game:snapshot()
  local finalPosition = assert(game.runtime.actors:getById(actorId)):getFieldPosition()
  local interaction = game:interaction()
  error(
    "production movement reaches and talks to the native rematch trainer (player="
      .. tostring(current.player.fieldX)
      .. ","
      .. tostring(current.player.fieldZ)
      .. ";actor="
      .. tostring(finalPosition.fieldX)
      .. ","
      .. tostring(finalPosition.fieldZ)
      .. ";target="
      .. tostring(interaction.actorId)
      .. ")",
    0
  )
end

local resolvePreparedWildEncounter

local function walkFieldPath(game, segments, targetMapId)
  local deltas = { east = { 1, 0 }, west = { -1, 0 }, north = { 0, -1 }, south = { 0, 1 } }
  for segmentIndex, segment in ipairs(segments) do
    local segmentStart = game:snapshot()
    if segment.target ~= nil then
      game:moveTo(segment.target)
      local reached = game:snapshot()
      Assert.equal(reached.player.fieldX, segment.target.fieldX, "production route reaches its source column")
      Assert.equal(reached.player.fieldZ, segment.target.fieldZ, "production route reaches its source row")
    else
    for stepIndex = 1, segment.steps do
      local before = game:snapshot()
      if before.player.facing ~= segment.direction then
        game:face(segment.direction)
      end
      game:move(segment.direction)
      local snapshot = game:advanceUntil(
        "production field step "
          .. segmentIndex
          .. "."
          .. stepIndex
          .. " toward map "
          .. targetMapId
          .. " from "
          .. before.mapSymbol
          .. ":"
          .. before.player.fieldX
          .. ","
          .. before.player.fieldZ,
        function(current)
          return current.mapId ~= before.mapId
            or current.player.motion == "idle"
              and (current.player.fieldX ~= before.player.fieldX or current.player.fieldZ ~= before.player.fieldZ)
        end,
        120
      )
      if snapshot.mapId == before.mapId then
        local delta = deltas[segment.direction]
        Assert.equal(snapshot.player.fieldX, before.player.fieldX + delta[1], "production input advances one column")
        Assert.equal(snapshot.player.fieldZ, before.player.fieldZ + delta[2], "production input advances one row")
      else
        Assert.equal(snapshot.mapId, targetMapId, "source road movement crosses into the expected map")
        Fixture.settleArrival(game, assert(snapshot.mapSymbol, "source road transition names its destination"))
      end
      if snapshot.dialogue.modal or game.runtime.scripts.scheduler:foregroundEnvironmentId() ~= nil then
        local settled = Fixture.settleScripting(game, 480)
        if not settled then
          local current = game:snapshot()
          error(
            "a source road scene settles during travel (map="
              .. tostring(current.mapSymbol)
              .. ",position="
              .. tostring(current.player.fieldX)
              .. ","
              .. tostring(current.player.fieldZ)
              .. ",locked="
              .. tostring(current.fieldLocked)
              .. ",foreground="
              .. tostring(game.runtime.scripts.scheduler:foregroundEnvironmentId())
              .. ",script="
              .. tostring(game.runtime.scripts.scheduler:foregroundScriptId())
              .. ",fault="
              .. tostring(game.runtime.errorText)
              .. ")",
            0
          )
        end
      end
      local pending = game.runtime.pendingEncounter
      if pending ~= nil then
        Assert.notNil(pending.id, "the prepared route encounter retains its native identity")
        resolvePreparedWildEncounter(game)
      end
    end
    if segment.settledPosition ~= nil then
      local settled = game:snapshot()
      Assert.equal(settled.mapId, 34, "the Route 30 coordinate scene keeps the player on the source map")
      Assert.equal(settled.player.fieldX, segment.settledPosition.fieldX, "the source coordinate scene settles at its column")
      Assert.equal(settled.player.fieldZ, segment.settledPosition.fieldZ, "the source coordinate scene settles at its row")
    elseif segment.target == nil and game:snapshot().mapId == segmentStart.mapId then
      local delta = deltas[segment.direction]
      local segmentEnd = game:snapshot()
      Assert.equal(
        segmentEnd.player.fieldX,
        segmentStart.player.fieldX + delta[1] * segment.steps,
        "the source route segment preserves its expected column"
      )
      Assert.equal(
        segmentEnd.player.fieldZ,
        segmentStart.player.fieldZ + delta[2] * segment.steps,
        "the source route segment preserves its expected row"
      )
    end
  end
  end
  Assert.equal(game:snapshot().mapId, targetMapId, "the production field path reaches its source destination map")
end

local function settleBattle(game, battle)
  local SessionFixture = require("libs.battle.tests.session_fixture")
  for _ = 1, 1200 do
    local status = battle:status()
    if status.phase == "complete" or status.phase == "failed" then
      return status
    end
    game:step()
    status = battle:status()
    if status.phase == "running" and status.request ~= nil then
      local choices = {}
      for _, actor in ipairs(status.request.actors) do
        choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
      end
      local accepted, replyErr = battle:submit(SessionFixture.replyFor(status.request, choices))
      Assert.isTrue(accepted, "the live trainer battle accepts a legal player decision: " .. tostring(replyErr))
    end
  end
  error("the native trainer battle reaches a terminal result within its semantic request budget", 0)
end

local function commitBattleThroughRuntime(game, previousReceipt, expectedResult)
  game:advanceUntil("the field battle coordinator commits its result", function()
    local result = game.runtime:lastBattleResult()
    return result ~= nil and result ~= previousReceipt
  end, 240)
  Assert.equal(game.runtime:lastBattleResult().result, expectedResult, "the production coordinator publishes the expected battle result")
end

resolvePreparedWildEncounter = function(game)
  local runtime = game.runtime
  local pending = assert(runtime.pendingEncounter, "source travel retains its prepared encounter until launch")
  local encounterMon = assert(pending.mons[1].mon, "the prepared encounter owns its wild mon")
  local derived = runtime.monService:derive(encounterMon)
  local previousResult = runtime:lastBattleResult()
  runtime:startBattle({
    request = {
      id = "pokegear-journey-route-wild",
      kind = "wild",
      payload = {
        attemptId = pending.id,
        species = encounterMon.species,
        level = derived.level,
      },
    },
  })
  local battle = assert(runtime.battleCoordinator:activeBattle(), "the field battle owner launches the prepared wild encounter")
  Assert.isNil(runtime.pendingEncounterId, "the normal battle launch consumes the prepared encounter once")
  local result = settleBattle(game, battle)
  Assert.equal(result.phase, "complete", "the route encounter resolves through the live battle lifetime")
  Assert.equal(result.result, "win", "the existing party wins the route encounter")
  commitBattleThroughRuntime(game, previousResult, "win")
end

local function interactUntilBattle(game, actorId)
  startInteraction(game, actorId)
  for _ = 1, 360 do
    if game.runtime.battleCoordinator:activeBattle() ~= nil then
      return assert(game.runtime.battleCoordinator:activeBattle())
    end
    local snapshot = game:snapshot()
    if game.runtime.scripts.dialogueHost:yesNoPresentation() ~= nil or snapshot.dialogue.modal then
      Fixture.pressActionEdge(game)
    else
      game:step()
    end
  end
  local snapshot = game:snapshot()
  local fault = game:recordsNamed("script.error")[1]
  local faultContext = fault and fault.payload.context or nil
  error(
    "the authored trainer conversation reaches the production battle owner (map="
      .. tostring(snapshot.mapId)
      .. ",modal="
      .. tostring(snapshot.dialogue.modal)
      .. ",foreground="
      .. tostring(game.runtime.scripts.scheduler:foregroundEnvironmentId())
      .. ",faults="
      .. tostring(Fixture.scriptFaults(game))
      .. ",faultCode="
      .. tostring(fault and fault.payload.code)
      .. ",faultMessage="
      .. tostring(fault and fault.payload.message)
      .. ",faultCommand="
      .. tostring(type(faultContext) == "table" and faultContext.command)
      .. ",faultOffset="
      .. tostring(type(faultContext) == "table" and faultContext.sourceOffset)
      .. ",faultScript="
      .. tostring(fault and fault.payload.scriptId)
      .. ")",
    0
  )
end

-- Joey's remote outgoing rematch call earns the invitation; Route 30's
-- authored object script then reads its native trainer ID and starts the
-- trainer battle through the field runtime.
function T.tests.native_invitation_starts_and_clears_the_authored_trainer_battle()
  local sample = { year = 2024, month = 1, day = 8, hour = 10, minute = 0, second = 0 }
  Fixture.withGame("MAP_ROUTE_30", function(game)
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_SAVE_BUTTON })
    -- Native Joey rematch call selection is gated by the post-Radio-Tower
    -- story fact.
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_BEAT_RADIO_TOWER_ROCKETS })
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_HIDE_ROUTE_30_BATTLERS })
    -- Post-Radio-Tower progression has completed Cherrygrove's guide and
    -- rival scenes before this rematch journey begins.
    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_HIDE_CHERRYGROVE_RIVAL })
    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_MET_PASSERBY_BOY })
    game:setWorldState({
      variable = FieldScriptSymbols.variablesByName.VAR_SCENE_CHERRYGROVE_CITY_OW,
      value = 4,
    })
    -- Radio Tower progression makes Joey visible again after the source
    -- startup script hides him during the early Route 30 scene.
    game.runtime.eventState:clearFlag(Fixture.FLAGS.FLAG_HIDE_ROUTE_30_YOUNGSTER_JOEY)
    -- Joey's first upgraded source row is column 2, gated by
    -- FLAG_UNK_97B + 2 (FLAG_UNK_97D) in the pinned native resolver.
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_UNK_97D })
    local contact = contactByPhoneId(assert(game.runtime.pokegearCatalog, "the field owns its compiled phone catalog"), 10)
    Assert.equal(contact.family, "trainer", "native phonebook entry 10 is Joey's trainer contact")
    alignInvitationWindow(sample, contact)
    -- This starts from a post-base-battle save. The native trainer-history
    -- bit is the only seeded trainer fact; the phone dialogue earns seeking.
    game:setWorldState({ flag = 0x550 + contact.trainerId })
    local party = assert(game.runtime.monService, "the route encounter uses the live party owner")
    Assert.isTrue(
      party:giveMon({ species = "CHIKORITA", level = 50, heldItem = "NONE", form = 0 }),
      "the source travel starts with a live party member"
    )

    local state = assert(game.runtime.pokegearState, "the invitation uses the durable field phone owner")
    state:registerContact(contact.key)

    walkFieldPath(game, {
      { direction = "south", steps = 9 },
      { direction = "east", steps = 1 },
      { direction = "south", steps = 4 },
      { target = { fieldX = 549, fieldZ = 383 } },
      { direction = "south", steps = 1 },
    }, 67)
    Assert.isNil(game.runtime.pendingEncounterId, "the remote invitation leg does not retain an encounter")
    local host = assert(game.runtime.pokegear.scriptHost, "the field runtime composes the production phone host")
    local handle = host:open({
      mode = "call",
      request = {
        id = "joey-native-rematch-invitation",
        contact = contact.key,
        direction = "outgoing",
        kind = "rematch",
      },
      parentOwner = "acceptance-field-script",
    })
    local call = finishCall(host, handle)
    Assert.isNil(call.error, "Joey's native invitation conversation completes successfully")
    Assert.isTrue(
      call.program == "trainer-33",
      "Joey's source window selects trainer-33, got " .. tostring(call.program)
    )
    Assert.isTrue(call.ready == true, "the native phone conversation earns the rematch invitation")
    host:close(handle)
    local staged = assert(state:queryRematch(contact.key), "the accepted invitation persists in phone state")
    Assert.isTrue(staged.stage > 0, "only the accepted phone conversation stages seeking")
    local selectedRematch = host:queryRematch(contact.key)
    Assert.isTrue(
      selectedRematch.trainerId > 0,
      "the source rematch selector chooses a native trainer after invitation; got " .. tostring(selectedRematch.trainerId)
    )
    Assert.equal(
      game.runtime.eventState:getVar(16533),
      0,
      "the unrelated Route 30 coordinate script remains inactive during the native phone journey"
    )
    Assert.isTrue(game.runtime.player:resolveStep("north") ~= nil, "the source west seam north step resolves at x549")
    game:face("north")
    game:move("north")
    local returned = game:advanceUntil("the source road returns to Route 30", function(snapshot)
      return snapshot.mapId == 34
    end, 120)
    Assert.equal(returned.mapId, 34, "northward production movement crosses back into Route 30")
    Fixture.settleArrival(game, assert(returned.mapSymbol, "source return seam names Route 30"))
    Assert.isNil(game.runtime.pendingEncounterId, "the source return seam does not retain an encounter")
    game:moveTo({ fieldX = 564, fieldZ = 376 })
    Assert.notNil(game.runtime.pendingEncounterId, "the source Route 30 crossing prepares its native wild encounter")
    resolvePreparedWildEncounter(game)
    party:removeMon(0)
    Assert.equal(game:snapshot().mapId, 34, "production movement returns to Route 30")
    Assert.isNil(
      game.runtime.pendingEncounterId,
      "the accepted invitation route has no unconsumed random encounter before Joey's battle"
    )

    Assert.isTrue(
      party:giveMon({ species = "CHIKORITA", level = 50, heldItem = "NONE", form = 0 }),
      "the live party is restored for the final Route 30 approach"
    )
    walkFieldPath(game, {
      { direction = "north", steps = 6 },
      { direction = "west", steps = 1 },
      { direction = "north", steps = 1 },
      { direction = "west", steps = 2 },
      { direction = "north", steps = 14 },
      {
        direction = "north",
        steps = 1,
        settledPosition = { fieldX = 556, fieldZ = 356 },
      },
      { direction = "east", steps = 2 },
      { direction = "north", steps = 1 },
      { direction = "east", steps = 3 },
      { direction = "north", steps = 21 },
      { direction = "west", steps = 8 },
      { direction = "north", steps = 1 },
    }, 34)
    local joeyApproach = game:snapshot()
    Assert.equal(joeyApproach.player.fieldX, 553, "production movement reaches Joey's source column")
    Assert.equal(joeyApproach.player.fieldZ, 333, "production movement reaches Joey's south-adjacent tile")
    party:removeMon(0)

    -- Losing the native rematch must preserve the staged request over a
    -- save/continue; only its authored qualified-win branch clears it.
    Assert.isTrue(
      party:giveMon({ species = "CATERPIE", level = 1, heldItem = "NONE", form = 0 }),
      "a deliberately weak live party can lose the first rematch attempt"
    )
    local actorId = rematchObject(game)
    startInteraction(game, actorId)
    local previousReceipt = game.runtime:lastBattleResult()
    local losingBattle = interactUntilBattle(game, actorId)
    local loss = settleBattle(game, losingBattle)
    Assert.equal(loss.phase, "complete", "the rematch loss resolves through the existing battle owner")
    Assert.equal(loss.result, "loss", "the prepared weak party loses the native rematch battle")
    commitBattleThroughRuntime(game, previousReceipt, "loss")
    local lossSettled = Fixture.drainField(game, 480)
    local lossSnapshot = game:snapshot()
    local lossFault = game:recordsNamed("script.error")[1]
    Assert.isTrue(
      lossSettled,
      "the source loss continuation releases field ownership (map="
        .. tostring(lossSnapshot.mapId)
        .. ",locked="
        .. tostring(lossSnapshot.fieldLocked)
        .. ",foreground="
        .. tostring(game.runtime.scripts.scheduler:foregroundEnvironmentId())
        .. ",result="
        .. tostring(game.runtime.scripts.worldState:getVar("VAR_SPECIAL_RESULT"))
        .. ",trainer="
        .. tostring(game.runtime.scripts.worldState:getVar("VAR_SPECIAL_x8004"))
        .. ",fault="
        .. tostring(lossFault and lossFault.payload.code)
        .. ",message="
        .. tostring(lossFault and lossFault.payload.message)
        .. ",script="
        .. tostring(lossFault and lossFault.payload.scriptId)
        .. ")"
    )
    Assert.isTrue(state:queryRematch(contact.key).stage > 0, "a loss leaves Joey's rematch request seeking")
    game:step()
    Assert.isTrue(
      Fixture.drainField(game, 480),
      "the source WhiteOut follow-up settles before the save/reload check"
    )
    Fixture.saveAndReload(game)
    state = assert(game.runtime.pokegearState, "the reload restores the same durable phone owner")
    staged = assert(state:queryRematch(contact.key), "save and reload restores the invitation after a loss")
    Assert.isTrue(staged.stage > 0, "save and reload preserve seeking after the trainer battle loss")

    Fixture.takeWarpTo(game, Fixture.TOWN)
    party = assert(game.runtime.monService, "the continued field runtime restores its party owner")
    party:removeMon(0)
    Assert.isTrue(
      party:giveMon({ species = "CHIKORITA", level = 50, heldItem = "NONE", form = 0 }),
      "the live party is prepared for the source return road"
    )
    local townArrival = game:snapshot()
    Assert.equal(townArrival.mapSymbol, Fixture.TOWN, "the source house warp exits to New Bark Town")
    Assert.equal(townArrival.player.fieldX, 695, "the source house warp returns to New Bark's saved column")
    Assert.equal(townArrival.player.fieldZ, 397, "the source house warp returns to New Bark's saved row")
    walkFieldPath(game, { { direction = "west", steps = 24 } }, 33)
    Assert.equal(game:snapshot().mapSymbol, "MAP_ROUTE_29", "the source town seam reaches Route 29")
    local cherrygrove = game:moveTo({ fieldX = 564, fieldZ = 392 }, 67)
    Fixture.settleArrival(game, assert(cherrygrove.mapSymbol, "the source road reaches Cherrygrove"))
    Assert.equal(cherrygrove.mapId, 67, "production road movement reaches Cherrygrove after reload")
    game:moveTo({ fieldX = 564, fieldZ = 392 })
    Assert.equal(game:snapshot().player.fieldX, 564, "production movement reaches the Cherrygrove source spawn column")
    Assert.equal(game:snapshot().player.fieldZ, 392, "production movement reaches the Cherrygrove source spawn row")
    walkFieldPath(game, {
      { direction = "west", steps = 13 },
      { direction = "north", steps = 4 },
      { direction = "west", steps = 1 },
      { direction = "north", steps = 5 },
    }, 34)
    Assert.equal(game:snapshot().mapId, 34, "production road movement returns to Route 30 after reload")

    local actorId, trainerVariable = rematchObject(game)
    local previousReceipt = game.runtime:lastBattleResult()
    local battle = interactUntilBattle(game, actorId)

    local nativeTrainerId = game.runtime.scripts.worldState:getVar(trainerVariable)
    Assert.isTrue(
      type(nativeTrainerId) == "number" and nativeTrainerId > 0,
      "native GetPhoneBookRematch writes a trainer identity before TrainerBattle"
    )
    local rematchHost = assert(game.runtime.pokegear.scriptHost, "the field keeps its composed phone host")
    local rematch = assert(rematchHost:queryRematch(contact.key), "the source query uses the same contact result")
    Assert.isTrue(
      type(rematch.trainerId) == "number" and rematch.trainerId > 0,
      "the staged source rematch selects a concrete native trainer team"
    )
    Assert.equal(
      nativeTrainerId,
      rematch.trainerId,
      "the authored opcode passes the selected native trainer identity into TrainerBattle"
    )
    local status = settleBattle(game, battle)
    Assert.equal(status.phase, "complete", "the native trainer battle commits through the field owner")
    Assert.equal(status.result, "win", "the player's live party wins the native rematch battle")

    commitBattleThroughRuntime(game, previousReceipt, "win")
    Assert.isTrue(Fixture.drainField(game, 480), "the authored win continuation releases field ownership")
    Assert.equal(
      state:queryRematch(contact.key).stage,
      0,
      "the native post-win script clears seeking after the qualified battle result"
    )
    local faults = game:recordsNamed("script.error")
    local faultDetails = {}
    for _, fault in ipairs(faults) do
      local context = fault.payload.context
      faultDetails[#faultDetails + 1] = tostring(fault.payload.scriptId)
        .. ":"
        .. tostring(fault.payload.code)
        .. ":"
        .. tostring(fault.payload.message)
        .. ":context="
        .. tostring(type(context) == "table" and context.op)
        .. "/"
        .. tostring(type(context) == "table" and context.contact)
        .. "/"
        .. tostring(type(context) == "table" and context.kind)
        .. "/"
        .. tostring(type(context) == "table" and context.sourceOffset)
    end
    Assert.equal(Fixture.scriptFaults(game), 0, "the native invitation and battle path has no script faults: " .. table.concat(faultDetails, "; "))
  end, {
    localClock = LocalClock.new(function()
      return sample
    end),
  })
end

return T
