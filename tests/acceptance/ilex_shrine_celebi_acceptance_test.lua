-- Production-composed Ilex Forest shrine contract. Boots the real field
-- runtime on MAP_ILEX_FOREST one tile south of the shrine background event
-- (16, 55) facing north, presses Action through the production interaction
-- resolver, and proves the shrine dispatch script runs instead of faulting
-- on its first instruction. The staged Celebi leg then plays the fateful
-- lead branch through the time-travel beat and asserts the Route 22 warp
-- with its script-visible state (VAR_UNK_40FE, friend visibility), while
-- sampling the production screen-fade cover on every tick: the journey
-- must show a visible interval between the cutscene's opening cover and
-- its closing white cover, never a single unbroken white hold. Exact
-- beat/swirl counts and the terminal opaque gate live in the cutscene
-- task unit contract; this scenario also traces the production scene and
-- camera state through the covered warp. Rendered model and capture pixels
-- are covered by graphics tests. The auto-started Route 22 past scene
-- (camera-target ops 102/103) remains a separate follow-up outside this contract:
-- fault assertions are scoped to the Ilex member-92 scripts.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local BagSave = require("libs.hgss.src.save.BagSave")
local MartSave = require("libs.hgss.src.save.MartSave")
local Mailbox = require("libs.hgss.src.save.Mailbox")
local PhotoAlbum = require("libs.hgss.src.save.PhotoAlbum")
local FashionCaseState = require("libs.hgss.src.save.FashionCaseState")
local LocalClock = require("game.src.LocalClock")
local CacheFs = require("libs.storage.src.CacheFs")
local MonCache = require("libs.assets.src.MonCache")
local MonCatalog = require("libs.mons.src.MonCatalog")
local ItemCache = require("libs.assets.src.ItemCache")
local ItemCatalog = require("libs.items.src.ItemCatalog")
local FieldFontLoader = require("libs.hgss.src.ui.FieldFontLoader")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local MonFactory = require("libs.mons.src.gen4.MonFactory")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local Party = require("libs.mons.src.Party")
local MonsSave = require("libs.mons.src.MonsSave")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = {
      "field-runtime",
      "map:117",
      "map-data:117",
      "script-member:92",
      "message-bank:115",
      "map:27",
      "map-data:27",
      "map-data:30",
      "map-data:32",
      "map-data:50",
      "map-data:58",
      "script-member:212",
      "field-effects:global",
    },
    tags = { "field", "shrine", "celebi", "acceptance" },
  },
  tests = {},
}

local MAP = "MAP_ILEX_FOREST"
local SHRINE = { fieldX = 16, fieldZ = 56, facing = "north" }
local ROCKETS_BEATEN = FieldScriptSymbols.flagsByName.FLAG_BEAT_RADIO_TOWER_ROCKETS
local FRIEND_HIDDEN = FieldScriptSymbols.flagsByName.FLAG_HIDE_ILEX_FOREST_FRIEND
local PROGRESS_40FE = FieldScriptSymbols.variablesByName.VAR_UNK_40FE

-- One staged party lead through the production mon factory: the same
-- script-gift policy the live service uses, with the fateful marker the
-- shrine's EVENT_CELEBI trigger reads. Level and met details never enter
-- the trigger contract.
local function leadBucket(versionId, species, fateful)
  local cacheFs = CacheFs.forVersion(versionId)
  local monRoot = MonCache.loadCatalog(cacheFs)
  local itemCatalog = ItemCatalog.new(ItemCache.loadCatalog(cacheFs))
  local monCatalog = MonCatalog.new(monRoot, itemCatalog)
  local charmap = assert(FieldFontLoader.load(cacheFs).charmap, "acceptance font carries the production charmap")
  local factory = MonFactory.new({
    catalog = monCatalog,
    rng = Lcrng.new(0xC31EB1),
    charmap = charmap,
    games = HgssMonService.GAMES,
    languages = HgssMonService.LANGUAGES,
    game = versionId,
    language = monRoot.version.language,
  })
  local mon = factory:createScriptGift({
    species = species,
    level = 5,
    profile = { name = "GOLD", gender = 0, trainerId = 1 },
    location = 7,
    date = { year = 2000, month = 1, day = 1 },
  })
  mon.fatefulEncounter = fateful
  local party = Party.new()
  Assert.isTrue(party:add(mon), "the staged lead fits the empty party")
  return MonsSave.capture(party:capture(), Lcrng.new(0x5EED):capture())
end

local function withShrineGame(fn, options)
  options = options or {}
  local clock = LocalClock.new(function()
    return { year = 2000, month = 1, day = 1, hour = 12, minute = 0, second = 0 }
  end)
  local harness = AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      local worldState = FieldEventState.new()
      for _, flag in ipairs(options.flags or {}) do
        worldState:setFlag(flag)
      end
      return {
        saveId = "save-00000001",
        versionId = versionId,
        -- Harness spawns take map-local coordinates (pre origin-offset)
        -- while SHRINE is global: Ilex Forest's origin is (0, 32), and the
        -- shrine side is unreachable on foot from the southern spawn
        -- (a Cut tree seals x=16, z=62), so start on the approach tile.
        location = { mapSymbol = map, fieldX = SHRINE.fieldX, fieldZ = SHRINE.fieldZ - 32, facing = SHRINE.facing },
        playerData = {
          profile = {
            name = "GOLD",
            gender = 0,
            trainerId = 1,
            money = 3000,
            badges = 0,
            nationalDex = false,
            runningShoes = false,
            runningShoesLock = false,
            rivalName = "Silver",
          },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
        fashionCase = FashionCaseState.empty(),
        playTime = PlayTime.new(),
        worldState = worldState,
        mons = leadBucket(versionId, options.leadSpecies or "CHIKORITA", options.fateful == true),
        bag = BagSave.empty(),
        mart = MartSave.empty(),
        mailbox = Mailbox.new():capture(),
        photoAlbum = PhotoAlbum.new():capture(),
      }
    end,
  })
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, localClock = clock },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local placed = game:snapshot()
    Assert.equal(placed.player.fieldX, SHRINE.fieldX, "the spawn lands on the shrine approach X")
    Assert.equal(placed.player.fieldZ, SHRINE.fieldZ, "the spawn lands on the shrine approach Z")
    game:face(SHRINE.facing)
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "the shrine flow must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- Faults raised by the journey scripts (Ilex member 92, Route 22 member
-- 212, Tohjo member 114). The Tohjo Giovanni battle and its post-battle
-- resume stay outside this contract.
local JOURNEY_MEMBERS = { "scr_seq.0092", "scr_seq.0212", "scr_seq.0114" }

local function journeyFaults(game)
  local faults = {}
  for _, record in ipairs(game:recordsNamed("script.error")) do
    local scriptId = record.payload and record.payload.scriptId or ""
    for _, member in ipairs(JOURNEY_MEMBERS) do
      if scriptId:find(member, 1, true) ~= nil then
        faults[#faults + 1] = record
        break
      end
    end
  end
  return faults
end

local function faultDetail(game)
  local faults = journeyFaults(game)
  if faults[1] == nil then
    return "none"
  end
  local payload = faults[1].payload or {}
  return tostring(payload.scriptId) .. "/" .. tostring(payload.code)
end

-- Return the first missing source-visible cutscene milestone. Samples are
-- collected only while the identified Celebi task exists, so earlier
-- shrine/friend fades cannot satisfy this check.
local function visibilityFailure(samples, taskId)
  local openingOpaque = false
  local beatClearRun = 0
  local earlySwirlClearRun = 0
  local closingOpaque = false
  local previousRank = 0
  local phaseRanks = { opening_out = 1, opening_in = 2, beat = 3, swirl = 4 }

  for _, sample in ipairs(samples) do
    if sample.taskId == taskId then
      local rank = phaseRanks[sample.phase]
      if rank == nil or rank < previousRank then
        return "Celebi task phases are missing or out of order"
      end
      previousRank = rank

      if sample.phase == "opening_out" and sample.coefficient == 16 then
        openingOpaque = true
      end
      if openingOpaque and sample.phase == "beat" and sample.coefficient == 0 then
        beatClearRun = beatClearRun + 1
      elseif sample.phase == "beat" then
        beatClearRun = 0
      end
      if
        openingOpaque
        and sample.phase == "swirl"
        and sample.elapsed < 80
        and sample.coefficient == 0
      then
        earlySwirlClearRun = earlySwirlClearRun + 1
      elseif sample.phase == "swirl" and sample.elapsed < 80 then
        earlySwirlClearRun = 0
      end
      if sample.phase == "swirl" and sample.elapsed >= 110 and sample.coefficient == 16 then
        closingOpaque = true
      end
    end
  end

  if not openingOpaque then
    return "Celebi task never showed its opening white cover"
  end
  if beatClearRun < 2 or earlySwirlClearRun < 2 then
    return "Celebi task never showed a clear beat and early-swirl interval"
  end
  if not closingOpaque then
    return "Celebi task never restored opaque white before its handoff"
  end
  return nil
end

local function taskEvents(game, eventName)
  local matches = {}
  for _, record in ipairs(game:recordsNamed(eventName)) do
    local payload = record.payload or {}
    if payload.taskType == "celebi_time_travel" then
      matches[#matches + 1] = payload
    end
  end
  return matches
end

-- A friend scene can supply white/clear/white samples before the Celebi
-- task starts. The task-only predicate must still reject an all-white task.
function T.tests.all_white_celebi_task_fails_visibility_counterfactual()
  local failure = visibilityFailure({
    { taskId = "friend-fade", phase = "opening_out", elapsed = 0, coefficient = 16 },
    { taskId = "friend-fade", phase = "beat", elapsed = 0, coefficient = 0 },
    { taskId = "celebi-task", phase = "opening_out", elapsed = 0, coefficient = 16 },
    { taskId = "celebi-task", phase = "opening_in", elapsed = 0, coefficient = 16 },
    { taskId = "celebi-task", phase = "beat", elapsed = 0, coefficient = 16 },
    { taskId = "celebi-task", phase = "beat", elapsed = 1, coefficient = 16 },
    { taskId = "celebi-task", phase = "swirl", elapsed = 1, coefficient = 16 },
    { taskId = "celebi-task", phase = "swirl", elapsed = 80, coefficient = 16 },
    { taskId = "celebi-task", phase = "swirl", elapsed = 110, coefficient = 16 },
  }, "celebi-task")
  Assert.equal(
    failure,
    "Celebi task never showed a clear beat and early-swirl interval",
    "the friend's earlier clear fade must not rescue an all-white Celebi task"
  )
end

-- Drive semantic Action edges until the field reaches the named map or a
-- journey script faults. When `trace` is given, collect fade samples only
-- for the actual Celebi task, keyed by its scheduler task ID. The saves and
-- derived caches stay isolated: the harness boots a per-run save namespace
-- over read-only fixtures, and this driver writes nothing back.
local function driveUntilMap(game, mapSymbol, maxTicks, trace)
  local arrived = nil
  local seenTaskIds = {}
  for _ = 1, maxTicks do
    local snapshot = game:snapshot()
    if trace ~= nil then
      for _, payload in ipairs(taskEvents(game, "script.task_started")) do
        if not seenTaskIds[payload.taskId] then
          seenTaskIds[payload.taskId] = true
          trace.taskIds[#trace.taskIds + 1] = payload.taskId
        end
      end
      local fade = assert(snapshot.screenFade, "the composed runtime owns the screen-fade controller")
      for _, task in ipairs(game.runtime.scripts.scheduler:tasks()) do
        if task.taskType == "celebi_time_travel" and seenTaskIds[task.taskId] then
          trace.samples[#trace.samples + 1] = {
            taskId = task.taskId,
            phase = task.state.phase,
            elapsed = task.state.elapsed,
            taskStatus = task.status,
            coefficient = fade.coefficient,
          }
          local camera = assert(game.runtime.camera, "the composed field owns its live camera")
          local cameraSample = {
            taskId = task.taskId,
            phase = task.state.phase,
            elapsed = task.state.elapsed,
            taskStatus = task.status,
            scene = game.runtime.celebiTimeTravelScene and game.runtime.celebiTimeTravelScene:status() or nil,
            camera = camera,
            up = { x = camera.up.x, y = camera.up.y, z = camera.up.z },
            rawPerspective = camera:rawPerspective(),
            zoom = camera.zoom,
            projectionAspect = camera.projectionAspect,
            target = { x = camera.target.x, y = camera.target.y, z = camera.target.z },
            eye = { x = camera.eye.x, y = camera.eye.y, z = camera.eye.z },
            screenScope = fade.screenScope,
            coefficient = fade.coefficient,
          }
          trace.cinematicSamples[#trace.cinematicSamples + 1] = cameraSample
          if trace.initialCamera == nil then
            trace.initialCamera = camera
            trace.initialUp = cameraSample.up
            trace.initialRawPerspective = cameraSample.rawPerspective
            trace.initialZoom = cameraSample.zoom
            trace.initialProjectionAspect = cameraSample.projectionAspect
            trace.initialTarget = cameraSample.target
            trace.initialEye = cameraSample.eye
          end
          if task.status == "active" and (task.state.phase == "opening_in" or task.state.phase == "beat" or task.state.phase == "swirl") then
            local scene = assert(
              game.runtime.celebiTimeTravelScene,
              "the live Celebi task publishes its production scene owner"
            )
            local status = scene:status()
            Assert.isTrue(status.active, "the source scene remains active through the visible task interval")
            Assert.isTrue(status.modelVisible, "the original model replaces the follower under the inbound fade")
            Assert.notNil(status.modelPosition, "the scene captures the follower's source world position")
            local followingMon = assert(game.runtime.followingMon, "the composed field owns its follower")
            local partnerId = assert(followingMon:partnerActorId(), "the staged lead has a follower actor")
            local partner = assert(game.runtime.actors:getById(partnerId), "the source follower actor remains addressable")
            local position = partner:getWorldPosition()
            Assert.equal(status.modelPosition.x, position.x, "the legend keeps the follower's source world X")
            Assert.equal(status.modelPosition.y, position.y, "the legend keeps the follower's source world Y")
            Assert.equal(status.modelPosition.z, position.z, "the legend keeps the follower's source world Z")
            Assert.isFalse(game.runtime.actors:isVisible(partnerId), "the ordinary follower stays hidden under the legend")
            if task.state.phase == "beat" or task.state.phase == "swirl" then
              trace.sceneFrames[#trace.sceneFrames + 1] = status.animationFrame
            end
          elseif task.status == "completed" then
            local scene = assert(
              game.runtime.celebiTimeTravelScene,
              "the completed Celebi task retains its production scene owner"
            )
            local status = scene:status()
            Assert.isFalse(status.active, "the source model is released at the opaque task handoff")
            Assert.isFalse(status.modelVisible, "the source model is hidden before destination presentation")
            local followingMon = assert(game.runtime.followingMon, "the composed field owns its follower")
            local partnerId = assert(followingMon:partnerActorId(), "the staged lead has a follower actor")
            Assert.isFalse(
              game.runtime.actors:isVisible(partnerId),
              "the source follower remains hidden through the covered handoff"
            )
            cameraSample.sceneInactiveAtHandoff = true
          end
        end
      end
    end
    if snapshot.mapSymbol == mapSymbol then
      arrived = snapshot
      for _ = 1, 600 do
        game:step()
      end
      break
    end
    if #journeyFaults(game) > 0 then
      break
    end
    game.runtime:pressAction()
    game:step()
    game.runtime:releaseAction()
  end
  return arrived
end

-- A fresh save carries no Rockets progress, so the shrine dispatch must
-- reach its plain-text fallback: the bike check, the Pichu pass-through,
-- and the Celebi gate all observe non-triggering state, and the shrine
-- message prints and dismisses through normal confirmation.
function T.tests.shrine_answers_its_plain_text_without_faulting()
  withShrineGame(function(game)
    local snapshot = game:pressAction()
    Assert.equal(snapshot.player.fieldX, SHRINE.fieldX, "the Action press never moves the player")
    local interaction = game.lastInteraction or {}
    Assert.equal(
      interaction.kind,
      "background",
      string.format(
        "the shrine resolves as a background event (pos=%d,%d facing=%s map=%s kind=%s)",
        snapshot.player.fieldX,
        snapshot.player.fieldZ,
        tostring(snapshot.player.facing),
        tostring(snapshot.mapSymbol),
        tostring(interaction.kind)
      )
    )
    local scriptId = assert(game.lastInteraction.scriptId, "the shrine background binds a script")
    Assert.isTrue(scriptId:find("scr_seq.0092", 1, true) ~= nil, "the shrine binds the Ilex script member")
    Assert.isTrue(scriptId:find("script_012", 1, true) ~= nil, "the shrine binds its dispatch script")

    local printed = false
    for _ = 1, 480 do
      game:step()
      if #journeyFaults(game) > 0 then
        break
      end
      if game:snapshot().dialogue.modal then
        printed = true
        break
      end
    end
    Assert.equal(
      #journeyFaults(game),
      0,
      "the shrine dispatch must not fault its bike check or gates (got " .. faultDetail(game) .. ")"
    )
    Assert.isTrue(printed, "the plain shrine text must reach its dialogue window")
    game:advanceDialogue()
    local settled = game:snapshot()
    Assert.isFalse(settled.dialogue.modal, "the shrine text must dismiss through normal confirmation")
    Assert.isFalse(settled.fieldLocked, "the plain shrine path must release the field")
  end)
end

-- The staged pre-event state (Rockets beaten, friend hidden, fateful
-- Celebi lead, untouched progress) must take the Celebi branch: the
-- friend appears, the time-travel beat completes, and the field warps to
-- Route 22 with progress set and the friend hidden again. The task-scoped
-- trace must show opening white, a clear beat and early swirl, then the
-- closing white cover; earlier friend fades do not count. After arrival the
-- field settles for 600 source ticks so Route 22 map entry admits its
-- principals, including those on tiles without a terrain plate, which keep
-- their event height. The auto-started past scene's later dialogue stays
-- outside this contract. This acceptance stops before GPU rendering and
-- observes the composed camera, scene and fade state through the covered warp.
function T.tests.celebi_branch_warps_to_route_22_with_progress_set()
  withShrineGame(function(game)
    game:pressAction()
    Assert.equal(game.lastInteraction.kind, "background", "the shrine resolves as a background event")

    local trace = { taskIds = {}, samples = {}, sceneFrames = {}, cinematicSamples = {} }
    local route22 = driveUntilMap(game, "MAP_ROUTE_22", 20000, trace)
    Assert.equal(
      #journeyFaults(game),
      0,
      "the Celebi branch must not fault through its warp (got " .. faultDetail(game) .. ")"
    )
    Assert.notNil(route22, "the Celebi branch must warp the field to Route 22")
    Assert.isTrue(#trace.taskIds > 0, "the journey never started a Celebi time-travel task")
    Assert.equal(#trace.taskIds, 1, "the journey unexpectedly started more than one Celebi time-travel task")
    local taskId = trace.taskIds[1]
    local taskEnded = false
    for _, payload in ipairs(taskEvents(game, "script.task_ended")) do
      if payload.taskId == taskId then
        taskEnded = true
      end
    end
    Assert.isTrue(taskEnded, "the observed Celebi task must complete normally")
    Assert.isTrue(#trace.samples > 0, "the observed Celebi task must have source-tick samples")
    for _, sample in ipairs(trace.samples) do
      Assert.equal(sample.taskId, taskId, "all visibility samples belong to the identified task")
    end
    local visibilityError = visibilityFailure(trace.samples, taskId)
    Assert.isNil(visibilityError, visibilityError or "the Celebi task visibility trace is valid")
    Assert.isTrue(#trace.sceneFrames > 30, "the production scene advances through the visible beat and swirl")
    for index = 2, #trace.sceneFrames do
      Assert.equal(
        trace.sceneFrames[index],
        trace.sceneFrames[index - 1] + 1,
        "the headless scene animation advances once per source frame"
      )
    end
    local function swirlSample(frame)
      for _, sample in ipairs(trace.cinematicSamples) do
        if sample.phase == "swirl" and sample.scene and sample.scene.swirlFrame == frame then
          return sample
        end
      end
      return nil
    end
    local quarterTurns = {
      { frame = 45, x = 1, y = 0 },
      { frame = 90, x = 0, y = -1 },
      { frame = 135, x = -1, y = 0 },
    }
    for _, turn in ipairs(quarterTurns) do
      local sample = assert(
        swirlSample(turn.frame),
        string.format("the composed scene must publish camera state at swirl frame %d", turn.frame)
      )
      Assert.isTrue(sample.scene.blurActive, "the visible swirl activates main-scene capture")
      Assert.equal(sample.camera, trace.initialCamera, "the swirl borrows the active field camera")
      Assert.near(sample.up.x, turn.x, 1e-9, "the camera up vector follows the source roll horizontally")
      Assert.near(sample.up.y, turn.y, 1e-9, "the camera up vector follows the source roll vertically")
      Assert.near(sample.up.z, 0, 1e-9, "the camera up vector stays in the field camera plane")
    end
    local opaqueClosing = false
    local handoff
    for _, sample in ipairs(trace.cinematicSamples) do
      if sample.phase == "swirl" and sample.scene and sample.scene.swirlFrame ~= nil then
        Assert.equal(sample.camera, trace.initialCamera, "camera ownership stays with the active map during the swirl")
        Assert.equal(sample.rawPerspective, trace.initialRawPerspective, "camera perspective stays fixed during the roll")
        Assert.equal(sample.zoom, trace.initialZoom, "camera zoom stays fixed during the roll")
        Assert.equal(sample.projectionAspect, trace.initialProjectionAspect, "camera layout aspect stays fixed during the roll")
        Assert.deepEqual(sample.target, trace.initialTarget, "the roll leaves the camera target unchanged")
        Assert.deepEqual(sample.eye, trace.initialEye, "the roll leaves the camera eye unchanged")
        if sample.elapsed >= 110 and sample.coefficient == 16 and sample.screenScope == "both" then
          opaqueClosing = true
        end
      elseif sample.taskStatus == "completed" and sample.sceneInactiveAtHandoff then
        handoff = sample
      end
    end
    Assert.isTrue(opaqueClosing, "the both-screen white cover remains opaque after its closing fade")
    Assert.notNil(handoff, "the production scene releases camera and capture state at the covered handoff")
    Assert.isFalse(handoff.scene.active, "the scene is inactive before the destination becomes visible")
    Assert.isFalse(handoff.scene.blurActive, "capture is inactive at the covered handoff")
    Assert.equal(handoff.camera, trace.initialCamera, "the borrowed camera is restored before the map warp")
    Assert.deepEqual(handoff.up, trace.initialUp, "the original camera up vector is restored at completion")
    local world = assert(game.runtime.scripts.worldState, "field world state is available")
    Assert.equal(world:getVar(PROGRESS_40FE), 1, "the time travel advances the event progress")
    Assert.isTrue(world:isFlagSet(FRIEND_HIDDEN), "the departure hides the friend again")

    -- The acceptance harness stops before graphics. Source-camera motion and
    -- capture activation are semantic scene state; rendered pixels and GPU
    -- lifetime belong to graphics tests.
    local scene = assert(
      game.runtime.celebiTimeTravelScene,
      "the production field runtime publishes the Celebi scene owner"
    )
    local inactive = scene:status()
    Assert.isFalse(inactive.active, "the covered map handoff releases the live Celebi scene")
    Assert.isFalse(inactive.modelVisible, "the legend model is hidden after the covered handoff")
    Assert.equal(inactive.animationFrame, 0, "the completed scene does not retain an active animation clock")
  end, { flags = { ROCKETS_BEATEN, FRIEND_HIDDEN }, leadSpecies = "CELEBI", fateful = true })
end

return T
