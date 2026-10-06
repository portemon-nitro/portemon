-- Retail Elm and Nurse Joy healing scripts exercise the production field
-- composition and its blocking healing flows.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local BagSave = require("libs.hgss.src.save.BagSave")
local MonBucket = require("tests.support.MonBucket")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "map-data:61",
      "map:61",
      "message-bank:543",
      "message-bank:40",
      "audio-bank:702",
      "map-data:69",
      "map:69",
      "message-bank:552",
      "encounters:global",
      "trainers:global",
    },
    tags = { "field", "script-primitives", "elm" },
  },
  tests = {},
}

local MAP = "MAP_NEW_BARK_ELMS_LAB_1F"
local CENTER_MAP = "MAP_CHERRYGROVE_POKECENTER_1F"
local ELM_HEAL_SCRIPT = "vanilla.hgss.scr_seq.0843.script_013"
local CENTER_OBJECT_SCRIPT = "vanilla.hgss.scr_seq.0852.script_000"
local NURSE_JOY_SCRIPT = "common.nurse_joy"
local FLAG_GOT_STARTER = FieldScriptSymbols.flagsByName.FLAG_GOT_STARTER
local CENTER_OVERLAP_REMOVAL_FLAG = 789

local function harness()
  return AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      local worldState = FieldEventState.new()
      worldState:setFlag(FLAG_GOT_STARTER)
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
        worldState = worldState,
        mons = require("tests.support.MonBucket").emptyForVersion(versionId),
        bag = require("libs.hgss.src.save.BagSave").empty(),
      }
    end,
  })
end

local function damagedParty(game)
  local mons = game.runtime.monService
  mons:createStarter("CHIKORITA", {
    location = game.runtime.runtimeMap.mapId,
    date = { year = 2000, month = 1, day = 1 },
  })
  local mon = mons:removeMon(0)
  mon.condition.currentHp = 1
  Assert.isTrue(mons:addMon(mon), "the damaged starter returns to its production party slot")
  return mons
end

local function nurseJoyHarness()
  return AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      local worldState = FieldEventState.new()
      -- Map 69 has two source objects on the same tile. Retail flag 789
      -- removes the source event object that overlaps the Nurse Joy path.
      worldState:setFlag(CENTER_OVERLAP_REMOVAL_FLAG)
      return {
        saveId = "save-00000002",
        versionId = versionId,
        location = { mapSymbol = map or CENTER_MAP, fieldX = 8, fieldZ = 12, facing = "north" },
        playerData = {
          profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0 },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        fieldTravel = { lastHealSpawn = "SPAWN_CHERRYGROVE" },
        playTime = PlayTime.new(),
        worldState = worldState,
        mons = MonBucket.emptyForVersion(versionId),
        bag = BagSave.empty(),
      }
    end,
  })
end

local function damagedThreeMonParty(game)
  local mons = game.runtime.monService
  for _, species in ipairs({ "CHIKORITA", "CYNDAQUIL", "TOTODILE" }) do
    mons:createStarter(species, {
      location = game.runtime.runtimeMap.mapId,
      date = { year = 2000, month = 1, day = 1 },
    })
    local slot = mons:partyCount() - 1
    local mon = mons:removeMon(slot)
    mon.condition.currentHp = 1
    Assert.isTrue(mons:addMon(mon), "the damaged party member returns to its production slot")
  end
  return mons
end

function T.tests.elm_healing_choice_runs_the_blocking_overworld_lifecycle()
  local game = harness():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local mons = damagedParty(game)
    local hpBefore = mons:partyMon(0).condition.currentHp
    local revisionBeforeHealing = mons:partyRevision()
    local sawOpaqueBlack = false
    local sawAbsent = false
    local sawRestoredPresence = false
    game:startScript(ELM_HEAL_SCRIPT)

    local ended = false
    local sawHealingChoice = false
    for _ = 1, 180 do
      local fade = game.runtime.screenFade:status()
      if fade.color == "black" and fade.coefficient == 16 then
        sawOpaqueBlack = true
      end
      local phase = game.runtime.overworld:phase()
      sawAbsent = sawAbsent or phase == "absent"
      sawRestoredPresence = sawRestoredPresence or (sawAbsent and phase == "present")
      if game.runtime.errorText ~= nil then
        break
      end
      for _, record in ipairs(game:recordsNamed("script.ended")) do
        if record.payload.scriptId == ELM_HEAL_SCRIPT then
          ended = true
        end
      end
      if ended then
        break
      end
      if game:contextChoiceStatus() ~= nil then
        sawHealingChoice = true
        game:pressAction()
      elseif game:snapshot().dialogue.modal then
        game:pressAction()
      else
        game:step()
      end
    end

    Assert.isNil(game.runtime.errorText, "Elm's generated healing path must not reach an unsupported command")
    Assert.isTrue(sawOpaqueBlack, "the source script reaches a fully black screen before healing")
    Assert.isTrue(sawAbsent, "C01 reaches its absent phase during Elm's source sequence")
    Assert.isTrue(sawRestoredPresence, "C01 restores presence before the script ends")
    Assert.equal(mons:partyRevision(), revisionBeforeHealing + 1, "the source HealParty mutates the live party once")
    local monAfter = mons:partyMon(0)
    Assert.isTrue(monAfter.condition.currentHp > hpBefore, "the production party owner heals the damaged starter")
    local fanfares = {}
    for _, effect in ipairs(game:hostEffects()) do
      if effect:sub(1, #"fanfare:") == "fanfare:" then
        fanfares[#fanfares + 1] = effect
      end
    end
    Assert.equal(#fanfares, 1, "Elm's source fanfare plays once without an extra machine fanfare")
    Assert.equal(fanfares[1], "fanfare:SEQ_ME_ASA", "the source fanfare is the healing audio")
    local completion = nil
    for _, record in ipairs(game:recordsNamed("script.ended")) do
      if record.payload.scriptId == ELM_HEAL_SCRIPT then
        completion = record.payload
      end
    end
    Assert.notNil(completion, "the generated healing path must reach its source end")
    Assert.isTrue(sawHealingChoice, "the generated healing path must reach its production choice before lifecycle")
    local completedScript = assert(completion)
    if completedScript.completed ~= true then
      Assert.equal(
        completedScript.reason,
        "SCRIPT_UNSUPPORTED_REACHABLE",
        "an incomplete healing path must identify the missing source lifecycle command"
      )
    end
    Assert.isTrue(
      completedScript.completed == true,
      "leave/restore must block until the source script can continue; reason=" .. tostring(completedScript.reason)
    )
    local settled = game:advanceUntil("Elm's lab returns to an idle field", function()
      return game:snapshot().transition.phase == "idle" and not game:snapshot().fieldLocked
    end, 120)
    Assert.equal(settled.mapSymbol, MAP, "lifecycle restoration keeps the active lab map")
    Assert.equal(settled.transition.phase, "idle", "the source fades settle around the lifecycle sequence")
    Assert.equal(game.runtime.screenFade:status().coefficient, 0, "the source fade-in completes before release")
    Assert.isFalse(game:snapshot().fieldLocked, "the source ReleaseAll returns ordinary field input")
    Assert.equal(game:renderAttempts(), 0, "field-script acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.nurse_joy_heals_through_the_blocking_common_script_flow()
  local game = nurseJoyHarness():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = CENTER_MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local mons = damagedThreeMonParty(game)
    local hpBefore = {}
    for slot = 0, mons:partyCount() - 1 do
      hpBefore[slot] = mons:partyMon(slot).condition.currentHp
    end
    local revisionBeforeHealing = mons:partyRevision()
    local player = game:snapshot().player
    Assert.equal(player.fieldX, 8, "the player begins on the source tile facing Nurse Joy")
    Assert.equal(player.fieldZ, 12, "the source interaction tile is beside the Nurse Joy actor")
    Assert.equal(player.facing, "north", "the player faces the Nurse Joy actor")

    local flow = assert(game.runtime.pokemonCenterHeal, "the production field runtime exposes the center-healing flow")
    local idleFlow = flow:status()
    Assert.isTrue(type(idleFlow.balls) == "table", "an idle healing flow exposes no temporary presentation instances")
    local generatedEffect = assert(
      game.runtime.fieldEffectAssets.effects.pokemon_center_heal,
      "the loaded field-effect family includes the generated center-healing definition"
    )
    local expectedBallPositions = assert(
      generatedEffect.ballPositions,
      "the generated center-healing definition exposes source-ordered ball roles and offsets"
    )
    local nurse = assert(game.runtime.actors:getById("map:69:object:0"), "the live Nurse Joy actor remains installed")

    game:pressAction()
    local interaction = game:interaction()
    Assert.equal(interaction.kind, "object", "Action must resolve through the production map object")
    Assert.equal(interaction.actorId, "map:69:object:0", "the source _0F89 branch selects the Nurse Joy actor")
    Assert.equal(interaction.scriptId, CENTER_OBJECT_SCRIPT, "the Nurse Joy map object starts its retail local script")
    Assert.equal(interaction.scriptSource, "vanilla", "the center interaction stays on the retail script path")

    local firstGiveTick, firstNurseMoveTick = nil, nil
    local sawNurseFacingChange = false
    local previousNurseFacing = nurse.facing
    local nurseFacingChanges = {}
    local function observeNurseFacing()
      if nurse.facing ~= previousNurseFacing then
        sawNurseFacingChange = true
        firstNurseMoveTick = firstNurseMoveTick or game:snapshot().tick
        nurseFacingChanges[#nurseFacingChanges + 1] = nurse.facing
        previousNurseFacing = nurse.facing
      end
    end
    local initialFlow = flow:status()
    for _ = 1, 120 do
      observeNurseFacing()
      local tick = game:snapshot().tick
      local playerGesture = game.runtime.player:presentationState().gesturePose
      if playerGesture == "give" and firstGiveTick == nil then
        firstGiveTick = tick
      end
      if initialFlow.phase ~= "idle" or game.runtime.errorText ~= nil then
        break
      end
      if game:contextChoiceStatus() ~= nil or game:snapshot().dialogue.modal then
        game:pressAction()
      else
        game:step()
      end
      initialFlow = flow:status()
    end
    local scriptErrors = game:recordsNamed("script.error")
    local scriptEnds = game:recordsNamed("script.ended")
    local firstError = scriptErrors[1] and scriptErrors[1].payload or nil
    local firstMessage = firstError and firstError.context and firstError.context.message or nil
    Assert.equal(
      initialFlow.count,
      3,
      "PartyCountNotEgg passes the live party count to the healing flow; phase="
        .. tostring(initialFlow.phase)
        .. ", flowError="
        .. tostring(initialFlow.error)
        .. ", runtimeError="
        .. tostring(game.runtime.errorText)
        .. ", scriptErrors="
        .. tostring(#scriptErrors)
        .. ", firstScriptError="
        .. tostring(scriptErrors[1] and scriptErrors[1].payload.code)
        .. ":"
        .. tostring(scriptErrors[1] and scriptErrors[1].payload.message)
        .. "@"
        .. tostring(firstError and firstError.scriptId)
        .. "/"
        .. tostring(type(firstMessage) == "table" and firstMessage.message)
        .. "/"
        .. tostring(type(firstMessage) == "table" and firstMessage.id)
        .. "/"
        .. tostring(type(firstMessage) == "table" and firstMessage.bank)
        .. ", secondScriptError="
        .. tostring(scriptErrors[2] and scriptErrors[2].payload.code)
        .. ":"
        .. tostring(scriptErrors[2] and scriptErrors[2].payload.message)
        .. ", scriptEnds="
        .. tostring(#scriptEnds)
    )
    local ballSnapshots = {}
    local spawnTicks = {}
    local sawBothAnimations = false
    local sawFanfare = false
    local sawAnimationAndFanfareTogether = false
    local sawBlockedFlow = false
    local firstReceiveTick, firstNurseBowTick, dialogueAfterBowTick = nil, nil, nil
    local bothAnimationsTick, fanfareTick = nil, nil
    local flowCompleteTick = nil
    local commonInstanceId = nil
    local observedScriptTaskTypes = {}
    local followerAppearanceCompletedAtTick = nil
    local ended = false
    local elapsed = 0
    local function observeFlow()
      local status = flow:status()
      Assert.isNil(status.error, "the source healing-machine flow completes without a runtime error")
      if status.phase == "complete" and flowCompleteTick == nil then
        flowCompleteTick = game:snapshot().tick
      end
      local balls = status.balls
      Assert.isTrue(type(balls) == "table", "the flow status exposes ordered temporary-ball positions")
      local previousBallCount = #ballSnapshots > 0 and #ballSnapshots[#ballSnapshots] or 0
      if #balls > previousBallCount then
        ballSnapshots[#ballSnapshots + 1] = balls
        spawnTicks[#spawnTicks + 1] = game:snapshot().tick
      end
      for index, ball in ipairs(balls) do
        local expected =
          assert(expectedBallPositions[index], "generated ball offset exists for each source party member")
        Assert.equal(ball.role, expected.role, "temporary balls preserve generated source role order")
        Assert.deepEqual(ball.offset, expected.offset, "temporary balls preserve generated source offsets")
        Assert.isTrue(type(ball.position) == "table", "each temporary ball exposes its read-only presentation position")
      end
      if status.ballAnimation == "playing" and status.machineAnimation == "playing" then
        sawBothAnimations = true
        bothAnimationsTick = bothAnimationsTick or game:snapshot().tick
      end
      if status.fanfare == "playing" then
        sawFanfare = true
        fanfareTick = fanfareTick or game:snapshot().tick
      end
      sawAnimationAndFanfareTogether = sawAnimationAndFanfareTogether
        or (status.ballAnimation == "playing" and status.machineAnimation == "playing" and status.fanfare == "playing")
      if status.phase ~= "complete" then
        sawBlockedFlow = sawBlockedFlow or game:snapshot().fieldLocked
      end
      local tick = game:snapshot().tick
      local playerGesture = game.runtime.player:presentationState().gesturePose
      if playerGesture == "give" and firstGiveTick == nil then
        firstGiveTick = tick
      elseif playerGesture == "receive" and firstReceiveTick == nil then
        firstReceiveTick = tick
      end
      local nursePresentation = nurse:presentationState()
      if nursePresentation.gesturePose == "nurse_bow" and firstNurseBowTick == nil then
        firstNurseBowTick = tick
      end
      if firstNurseBowTick ~= nil and game:snapshot().dialogue.modal then
        dialogueAfterBowTick = tick
      end
      local nurseAction = nurse:currentAction()
      observeNurseFacing()
      local commonRuns = game:recordsForScript(NURSE_JOY_SCRIPT)
      if #commonRuns == 1 then
        commonInstanceId = commonRuns[1].payload.instanceId
        for _, record in ipairs(game:recordsNamed("script.task_started")) do
          if record.payload.instanceId == commonInstanceId then
            observedScriptTaskTypes[record.payload.taskType] = true
          end
        end
        for _, record in ipairs(game:recordsNamed("script.task_ended")) do
          if record.payload.instanceId == commonInstanceId and record.payload.taskType == "follower_appearance" then
            followerAppearanceCompletedAtTick = record.payload.completedAtTick
          end
        end
      end
      return status
    end

    observeFlow()
    for _ = 1, 6000 do
      elapsed = elapsed + 1
      if game.runtime.errorText ~= nil then
        break
      end
      for _, record in ipairs(game:recordsNamed("script.ended")) do
        if record.payload.scriptId == CENTER_OBJECT_SCRIPT then
          ended = true
          break
        end
      end
      if ended then
        break
      end
      observeFlow()
      if game:contextChoiceStatus() ~= nil or game:snapshot().dialogue.modal then
        game:pressAction()
      else
        game:step()
      end
    end

    Assert.isNil(game.runtime.errorText, "the retail Nurse Joy sequence must not fault")
    Assert.isTrue(ended, "the local Nurse Joy script returns after its blocking common script")
    Assert.equal(#game:recordsForScript(CENTER_OBJECT_SCRIPT), 1, "the interaction starts its local source script once")
    local commonStarts = game:recordsForScript(NURSE_JOY_SCRIPT)
    Assert.equal(#commonStarts, 1, "the local map script calls the canonical common Nurse Joy script once")
    Assert.isTrue(elapsed < 6000, "the source common script reaches its conclusion")
    Assert.equal(#ballSnapshots, 3, "three source-ordered temporary balls appear one at a time")
    for index = 1, 2 do
      Assert.equal(#ballSnapshots[index], index, "each spawn snapshot retains the ordered source prefix")
      Assert.equal(#ballSnapshots[index + 1], index + 1, "each spawn adds one temporary ball")
      Assert.equal(spawnTicks[index + 1] - spawnTicks[index], 14, "successive balls are separated by the full delay and transition sequence")
    end
    Assert.isTrue(sawBothAnimations, "the machine and balls animate together after spawning")
    Assert.isTrue(sawFanfare, "the healing-machine fanfare begins while the common script is blocked")
    Assert.isTrue(
      sawAnimationAndFanfareTogether,
      "the common script stays blocked while animations and the healing fanfare run together"
    )
    Assert.isTrue(sawBlockedFlow, "the script retains the field lock through the blocking healing presentation")
    Assert.notNil(firstGiveTick, "the production common script runs the player give gesture")
    Assert.notNil(firstReceiveTick, "the production common script runs the player receive gesture")
    Assert.notNil(firstNurseMoveTick, "the production common script runs Nurse Joy's scripted movement")
    Assert.isTrue(sawNurseFacingChange, "the production common script turns Nurse Joy toward the player")
    Assert.deepEqual(
      nurseFacingChanges,
      { "west", "south" },
      "the source movement turns the nurse west before healing and south after"
    )
    Assert.notNil(flowCompleteTick, "the machine animation and fanfare gates finish before continuation")
    Assert.isTrue(firstGiveTick < spawnTicks[1], "the player give gesture precedes the machine sequence")
    Assert.isTrue(firstNurseMoveTick < spawnTicks[1], "Nurse Joy's source movement precedes the machine sequence")
    Assert.notNil(bothAnimationsTick, "the source machine and temporary-ball animations start together")
    Assert.notNil(fanfareTick, "the machine starts its source healing fanfare")
    Assert.equal(bothAnimationsTick - spawnTicks[3], 14, "the machine waits for the same post-ball delay sequence after the final ball")
    Assert.isTrue(bothAnimationsTick <= fanfareTick, "the healing fanfare starts with the paired animations")
    Assert.isTrue(fanfareTick < flowCompleteTick, "the flow waits for its fanfare before completing")
    Assert.isTrue(flowCompleteTick < firstReceiveTick, "player receive starts after the blocking machine flow")
    Assert.notNil(firstNurseBowTick, "the production common script runs Nurse Joy's bow gesture")
    Assert.isTrue(firstReceiveTick < firstNurseBowTick, "player receive precedes Nurse Joy's bow")
    Assert.notNil(dialogueAfterBowTick, "the source common script opens dialogue after the nurse bows")
    Assert.isTrue(firstNurseBowTick < dialogueAfterBowTick, "Nurse Joy bows before the post-healing dialogue")
    Assert.isTrue(observedScriptTaskTypes.movement, "scheduler records include the common script movement tasks")
    Assert.isTrue(
      observedScriptTaskTypes.follower_appearance,
      "the common Nurse Joy script waits on the follower-appearance task"
    )
    Assert.notNil(followerAppearanceCompletedAtTick, "the common follower-appearance task completes")
    Assert.isTrue(
      followerAppearanceCompletedAtTick < spawnTicks[1],
      "the common script finishes follower appearance before the healing sequence begins"
    )
    local commonEndIndex, localEndIndex = nil, nil
    for index, record in ipairs(game:recordsNamed("script.ended")) do
      if record.payload.scriptId == NURSE_JOY_SCRIPT then
        commonEndIndex = index
      elseif record.payload.scriptId == CENTER_OBJECT_SCRIPT then
        localEndIndex = index
      end
    end
    Assert.notNil(commonEndIndex, "the common child script has a completion record")
    Assert.notNil(localEndIndex, "the local map script has a completion record")
    Assert.isTrue(commonEndIndex < localEndIndex, "the common Nurse Joy flow completes before its local caller")
    local effects = game:hostEffects()
    local ballSounds, machineFanfares = 0, 0
    for _, effect in ipairs(effects) do
      if effect == "audio:SEQ_SE_DP_BOWA" then
        ballSounds = ballSounds + 1
      elseif effect == "fanfare:SEQ_ME_ASA" then
        machineFanfares = machineFanfares + 1
      end
    end
    Assert.equal(ballSounds, 3, "each spawned ball plays one placement sound in source order")
    Assert.equal(machineFanfares, 1, "the machine plays one healing fanfare")
    local finalFlow = flow:status()
    Assert.equal(finalFlow.phase, "complete", "the flow completes only after animation and fanfare finish")
    Assert.equal(#finalFlow.balls, 0, "all temporary balls are removed before script continuation")
    Assert.equal(
      mons:partyRevision(),
      revisionBeforeHealing + 3,
      "HealParty publishes one live update per damaged member"
    )
    for slot = 0, mons:partyCount() - 1 do
      Assert.isTrue(
        mons:partyMon(slot).condition.currentHp > hpBefore[slot],
        "the existing party owner heals member " .. tostring(slot)
      )
    end
    Assert.isFalse(game:snapshot().fieldLocked, "ReleaseAll restores ordinary field input")
    Assert.equal(game:renderAttempts(), 0, "field-script acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
