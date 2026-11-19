-- Script service injection: the composed scheduler carries the travel
-- owner, the field-move runtime, and the live game-stats owner to the
-- tasks and operations that consume them. A set_spawn slice updates the
-- injected travel through the scheduler; a pending field_move slice reaches
-- the injected runtime; a source game-score slice credits the injected
-- stats owner. Override slices install through the override layer like any
-- source script. No planning vocabulary here.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FakeCache = require("tests.support.FakeCache")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScripts = require("game.hgss.src.field.FieldScripts")
local FieldTravelState = require("libs.hgss.src.field.FieldTravelState")
local GameStats = require("libs.hgss.src.mons.GameStats")
local HoOhAppearanceFixture = require("tests.support.HoOhAppearanceFixture")
local LuaWriter = require("libs.codec.src.LuaWriter")
local MonNamingState = require("game.hgss.src.field.MonNamingState")
local PlayerData = require("libs.hgss.src.save.PlayerData")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptErrors = require("libs.script.src.errors")
local ScriptOverrides = require("libs.assets.src.ScriptOverrides")

local T = { tests = {} }

local SCRIPT_GENERATION = string.rep("a", 40)
local SCRIPT_MARKER = "scripts-test-marker"

local function testCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:write(ScriptCache.markerPath(), SCRIPT_MARKER)
  cache:write(ScriptCache.generationMarkerPath(SCRIPT_GENERATION), SCRIPT_MARKER)
  cache:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = SCRIPT_GENERATION,
    marker = SCRIPT_MARKER,
  })
  cache:writeLua(ScriptCache.generationIndexPath(SCRIPT_GENERATION), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = SCRIPT_GENERATION,
    marker = SCRIPT_MARKER,
    resources = {},
  })
  return cache
end

local function overrideFs(files)
  local ids = {}
  for id in pairs(files) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  local manifest = "return {"
  for index, id in ipairs(ids) do
    manifest = manifest .. string.format("%q%s", id, index < #ids and ", " or "")
  end
  manifest = manifest .. "}\n"
  return {
    read = function(_, path)
      if path == ScriptOverrides.MANIFEST then
        return manifest
      end
      for id, content in pairs(files) do
        if path == ScriptOverrides.DIR .. "/" .. id .. ".lua" then
          return content
        end
      end
      return nil
    end,
  }
end

local function stubActors()
  local function noop() end
  return {
    getActor = function()
      return nil
    end,
    show = noop,
    hide = noop,
    setPosition = noop,
    setFacing = noop,
    setMovementType = noop,
    setAnimationPaused = noop,
    getPosition = function()
      return { fieldX = 0, fieldZ = 0, worldY = 0 }
    end,
    getFacing = function()
      return "south"
    end,
    numericId = function()
      return nil
    end,
    actorIdForMapIndex = function()
      return nil
    end,
    cameraTargetId = function()
      return nil
    end,
    partnerId = function()
      return nil
    end,
    isVisible = function()
      return true
    end,
    setPresentationOffset = noop,
    clearPresentationOffset = noop,
    removePresence = noop,
    materializeObject = noop,
  }
end

local function sliceChunk(id, steps)
  local lines = { "return {", "  api = 1,", '  id = "' .. id .. '",', "  steps = {" }
  for _, step in ipairs(steps) do
    if step.op == "set_spawn" then
      lines[#lines + 1] = '    { op = "set_spawn", spawn = "' .. step.spawn .. '" },'
    elseif step.op == "set_special_spawn" then
      lines[#lines + 1] = string.format(
        '    { op = "set_special_spawn", map = %q, fieldX = %d, fieldZ = %d, warpId = %d, direction = %q },',
        step.map,
        step.fieldX,
        step.fieldZ,
        step.warpId,
        step.direction
      )
    elseif step.op == "field_move" then
      lines[#lines + 1] = '    { op = "field_move", source = "pending" },'
    elseif step.op == "game_score_event" then
      lines[#lines + 1] = string.format('    { op = "game_score_event", event = %d },', step.event)
    elseif step.op == "battle_launch" then
      lines[#lines + 1] =
        '    { op = "battle_launch", kind = "wild", details = { species = "TOTODILE", level = 4 }, result = { value = "var", id = "VAR_TEMP_x4001" } },'
    elseif step.op == "battle_result" then
      lines[#lines + 1] = '    { op = "battle_result", result = { value = "var", id = "VAR_TEMP_x4002" } },'
    else
      error(
        "services harness covers set_spawn, set_special_spawn, pending field_move, game_score_event, and battle ops only",
        0
      )
    end
  end
  lines[#lines + 1] = "  },"
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n")
end

local function composeSlice(services, id, steps)
  local function noop() end
  local chunk = services.encode or sliceChunk
  local args = {
    cacheFs = testCache(),
    overrideFs = overrideFs({ [id] = chunk(id, steps) }),
    eventState = FieldEventState.new(),
    actors = stubActors(),
    player = { fieldX = 1, fieldZ = 2, worldY = 0, facing = "south" },
    profile = services.profile or { gender = 0, name = "Gold", badges = {} },
    dialogue = { isModal = noop },
    messageProvider = {},
    layout = function()
      return {}
    end,
    fontDef = services.fontDef or { charmap = {} },
    signpost = { isModal = true, updateFixed = noop },
    windowStyles = {
      resolve = function()
        return {}
      end,
    },
    transition = {},
    mapLoader = {},
    sourceMap = { fieldData = { mapId = 7, scriptBankId = 3, initScripts = {} } },
    auxiliaryUi = { advance = noop },
    menu = {},
    contextChoice = {},
    travel = services.travel,
    fieldMoves = services.fieldMoves,
    battle = services.battle,
    gameStats = services.gameStats,
    monNaming = services.monNaming,
  }
  return FieldScripts.new(args --[[@as FieldScriptsOptions]])
end

-- A slice chunk serialized from a DSL step table: nested steps and value
-- descriptors travel exactly as authored instead of through a hand emitter.
local function encodedChunk(id, steps)
  return LuaWriter.encode({ api = 1, id = id, steps = steps })
end

-- The shared field naming host the production field wires into script
-- services, with the same controller, session, and generated charmap.
local function namingHost()
  return MonNamingState.new({
    effect = function() end,
    charmap = CatalogFixture.CHARMAP,
    measureDisplay = function()
      return {
        width = 800,
        height = 600,
        topology = ScreenTopology.oneDisplay({
          id = "main",
          rect = { x = 0, y = 0, width = 800, height = 600 },
          role = "world",
          touch = true,
        }),
        pixelRatio = 1,
        signature = "rival-naming:800x600",
      }
    end,
  })
end

local SAVE_CONTEXT = { charmap = CatalogFixture.CHARMAP, frameIndexes = { [0] = true } }

-- The live saved player record, validated by its owning module.
local function savedPlayer(rivalName)
  return assert(PlayerData.validate({
    profile = {
      name = "GOLD",
      rivalName = rivalName,
      gender = 0,
      trainerId = 0,
      money = 3000,
      badges = {},
      nationalDex = false,
      runningShoes = false,
      runningShoesLock = false,
      unionAvatar = 0,
    },
    options = {
      textFrame = 0,
      textSpeed = "mid",
      battleStyle = "shift",
      battleScene = true,
      soundMode = "stereo",
      battleSpeed = 1,
    },
  }, SAVE_CONTEXT))
end

-- Step the platform until the naming screen owns the field, bounded so a
-- missing block fails instead of spinning.
local function stepUntilNaming(platform, naming, firstTick)
  for index = 1, 32 do
    platform.scheduler:step(firstTick + index, nil)
    if naming:isActive() then
      return firstTick + index
    end
  end
  return nil
end

local function driveSlice(services, id, steps, tick)
  local platform = composeSlice(services, id, steps)
  local composed = assert(platform.composition:effective(id), "the slice must compose")
  platform.scheduler:createForeground(composed, nil, tick or 100)
  platform.scheduler:step(tick or 100, nil)
  return platform
end

function T.tests.set_spawn_updates_the_injected_travel_service()
  local travel = FieldTravelState.new({ lastHealSpawn = "SPAWN_NEW_BARK" })
  driveSlice({ travel = travel, fieldMoves = nil }, "test.travel_slice", {
    { op = "set_spawn", spawn = "SPAWN_GOLDENROD" },
  })
  Assert.equal(travel:capture().lastHealSpawn, "SPAWN_GOLDENROD", "set_spawn records on the injected travel owner")
end

function T.tests.set_special_spawn_writes_durable_copied_travel_state()
  local travel = FieldTravelState.new({ lastHealSpawn = "SPAWN_NEW_BARK" })
  driveSlice({ travel = travel, fieldMoves = nil }, "test.special_slice", {
    { op = "set_special_spawn", map = "MAP_NEW_BARK", fieldX = 688, fieldZ = 393, warpId = -1, direction = "south" },
  })
  Assert.deepEqual(travel:specialSpawn(), {
    map = "MAP_NEW_BARK",
    fieldX = 688,
    fieldZ = 393,
    warpId = -1,
    direction = "south",
  }, "opcode 582 writes the durable travel owner through the script maps service")
  Assert.deepEqual(travel:capture().specialSpawn, {
    map = "MAP_NEW_BARK",
    fieldX = 688,
    fieldZ = 393,
    warpId = -1,
    direction = "south",
  }, "the opcode-582 value survives travel capture")
end

-- A composed source score slice credits the live game-stats owner it was
-- wired with: nothing at composition time, once per executed command, on the
-- same saved score the trainer card reads.
function T.tests.script_score_slice_credits_the_injected_stats_owner()
  local stats = GameStats.new({ species = { CHIKORITA = true } })
  local platform = composeSlice({ travel = nil, fieldMoves = nil, gameStats = stats }, "test.score_slice", {
    { op = "game_score_event", event = 1 },
    { op = "game_score_event", event = 21 },
  })
  Assert.equal(stats:score(), 0, "composing a script scores nothing before it runs")
  local composed = assert(platform.composition:effective("test.score_slice"))
  platform.scheduler:createForeground(composed, nil, 100)
  platform.scheduler:step(100, nil)
  Assert.equal(stats:score(), 21, "one execution credits each source event's weight once")
  platform.scheduler:createForeground(composed, nil, 200)
  platform.scheduler:step(200, nil)
  Assert.equal(stats:score(), 42, "the next execution credits the events again")
  Assert.equal(stats:bucket().score, 42, "the credited score is the persisted score")
end

-- A score slice composed without a game-stats owner faults at the command
-- instead of succeeding through a scratch or per-script score. The scheduler
-- contains a structured fault on the running context, so the fault is
-- observed on the instance the foreground created: the slice ends there and
-- no composable owner is left to credit the event.
function T.tests.script_score_slice_faults_without_a_stats_owner()
  local platform = composeSlice({ travel = nil, fieldMoves = nil, gameStats = nil }, "test.score_missing", {
    { op = "game_score_event", event = 1 },
  })
  local composed = assert(platform.composition:effective("test.score_missing"))
  local instanceId = platform.scheduler:createForeground(composed, nil, 100)
  -- An ended root leaves the live set, so the test keeps the instance the
  -- foreground created and reads its terminal state after the step.
  local running = assert(platform.scheduler:instance(instanceId), "the score slice must start")
  platform.scheduler:step(100, nil)
  Assert.equal(running.status, "faulted", "a scripted score without a game-stats owner faults the script")
  Assert.equal(running.endReason, ScriptErrors.SCRIPT_SERVICE_MISSING, "the fault names the missing service")
  Assert.isNil(platform.scheduler:instance(instanceId), "the faulted score slice leaves no live script")
end

function T.tests.pending_field_move_reaches_the_injected_runtime()
  local takes = 0
  local fieldMoves = {
    takePending = function(_)
      takes = takes + 1
      error("no pending request queued", 0)
    end,
  }
  local ok, err = pcall(driveSlice, { travel = nil, fieldMoves = fieldMoves }, "test.moves_slice", {
    { op = "field_move", source = "pending" },
  })
  Assert.isFalse(ok, "an empty pending queue faults instead of succeeding")
  Assert.equal(takes, 1, "the task reads the injected runtime exactly once")
  Assert.isTrue(tostring(err):find("pending") ~= nil, "the fault names the missing queue: " .. tostring(err))
end

function T.tests.script_battle_launch_suspends_on_the_host_and_resumes_committed()
  local launches = {}
  local battleHost = {
    launchBattle = function(_, spec)
      launches[#launches + 1] = spec
      return "script-launch-1"
    end,
    battleStatus = function(_)
      return { phase = "complete", committed = true, result = "win", sourceResult = 1 }
    end,
    lastBattleResult = function(_)
      return { result = "win", sourceResult = 1 }
    end,
  }
  local platform = driveSlice({ travel = nil, fieldMoves = nil, battle = battleHost }, "test.battle_slice", {
    { op = "battle_launch" },
    { op = "battle_result" },
  })
  for _ = 1, 8 do
    platform.scheduler:step(100 + _, nil)
  end
  Assert.equal(#launches, 1, "the launch reaches the injected host exactly once")
  Assert.equal(launches[1].kind, "wild")
  Assert.equal(launches[1].details.species, "TOTODILE", "launch details evaluate before the host")
  local symbols = require("libs.assets.src.field.FieldScriptSymbols")
  Assert.equal(
    platform.worldState:getVar(symbols.variablesByName.VAR_TEMP_x4001),
    1,
    "the completed task writes its outcome code"
  )
  Assert.equal(
    platform.worldState:getVar(symbols.variablesByName.VAR_TEMP_x4002),
    1,
    "the script resumes on the committed result"
  )
end

-- The production Trainer Card service contributes no Frontier star: with
-- every flag set and a complete dex the count stops at four, and the
-- composition needs no runtime Frontier records owner to answer.
function T.tests.production_trainer_card_service_counts_no_frontier_star()
  local targetModule = "game.hgss.src.field.FieldScripts"
  local composeModule = "game.hgss.src.field.FieldScriptComposition"
  local seen = {}
  local double = {
    new = function(opts)
      seen.opts = opts
      return { scheduler = {}, worldState = {}, blackoutFlow = {} }
    end,
  }
  local savedTarget = package.loaded[targetModule]
  local savedCompose = package.loaded[composeModule]
  package.loaded[targetModule] = double
  package.loaded[composeModule] = nil
  local ok, err = pcall(function()
    local compose = require(composeModule).compose
    local runtime = {
      applicationHost = {
        requestReopen = function() end,
      },
      applyAvatarTransitions = function()
        return {}
      end,
      _setLiveWeather = function() end,
      overrideFs = {},
      eventState = {
        setFlag = function() end,
      },
      pokedexCatalog = {},
      actors = {},
      player = {},
      playerAvatar = nil,
      playerData = { profile = {}, options = { textFrame = 0 } },
      versionId = "heartgold",
      runtimeMap = { mapId = 61 },
      actorConfig = {
        apricorn = {
          depletedTreeSpriteId = 262,
          treeSpriteIdByKey = {
            RED_APRICORN = 263,
            YLW_APRICORN = 264,
            BLU_APRICORN = 265,
            GRN_APRICORN = 266,
            PNK_APRICORN = 267,
            WHT_APRICORN = 268,
            BLK_APRICORN = 269,
          },
          fruitSpriteIdByKey = {
            RED_APRICORN = 270,
            YLW_APRICORN = 271,
            BLU_APRICORN = 272,
            GRN_APRICORN = 273,
            PNK_APRICORN = 274,
            WHT_APRICORN = 275,
            BLK_APRICORN = 276,
          },
        },
      },
      overworld = {
        phase = function()
          return "present"
        end,
      },
      fieldTerrainEffectController = {},
      scriptHosts = nil,
      screenFade = require("libs.hgss.src.transition.FieldScriptScreenFade").new(),
      auxiliaryFieldUi = {},
      contextChoiceProvider = {},
      menuHost = {},
      dialogue = {},
      messageProvider = {},
      signpost = {},
      windowStyles = {},
      transition = {},
      mapLoader = {},
      kurtBoxHost = {},
      easyChatCatalog = {},
      easyChatState = {},
      pokegearRandom = {},
      easyChatScriptHost = {},
      dexKnowledge = {
        isNationalDexComplete = function()
          return true
        end,
        countSeen = function()
          return 0
        end,
        countCaught = function()
          return 0
        end,
        prepareChanges = function()
          error("the star-count stub never stages dex changes", 0)
        end,
      },
      scripts = {
        worldState = {
          isFlagSet = function()
            return true
          end,
        },
      },
      fashionCase = {},
    }
    local result = compose(runtime, {
      cacheFs = {
        loadLua = function()
          return HoOhAppearanceFixture.core()
        end,
      },
      layoutMessage = function(message)
        return message
      end,
      fontDef = {},
      audioService = {
        play = function() end,
        playMusic = function() end,
        playCry = function() end,
        stop = function() end,
        moveSequenceVolume = function() end,
      },
      followerInteractionCatalog = {},
      followerReactionTicks = {},
      mons = {},
      itemCatalog = {},
      followingMon = {},
      clock = {},
    })
    Assert.notNil(result.scripts, "composition still yields its scripts")
    local service = assert(seen.opts and seen.opts.trainerCardStars, "composition wires the star service")
    Assert.equal(service.count(), 4, "every flag plus a complete dex still counts no Frontier star")
  end)
  package.loaded[targetModule] = savedTarget
  package.loaded[composeModule] = savedCompose
  if not ok then
    error(err, 0)
  end
end

-- Retail `include/constants/flags.h::TRAINER_FLAG_BASE`.
local TRAINER_FLAG_BASE = 0x550

local function submitRivalName(platform, tick, name)
  local events = {}
  for _ = 1, 7 do
    events[#events + 1] = { type = "cancel" }
  end
  events[#events + 1] = { type = "text", text = name }
  platform.scheduler:step(tick, { uiEvents = events })
  platform.scheduler:step(tick + 1, { uiEvents = { { type = "name_control", id = "ok" } } })
end

-- Poll until the naming host releases the field, running an optional
-- observation after every step; returns the release tick or nil.
local function stepUntilNamingClosed(platform, naming, firstTick, observe)
  for index = 1, 40 do
    platform.scheduler:step(firstTick + index, nil)
    if observe ~= nil then
      observe()
    end
    if not naming:isActive() then
      return firstTick + index
    end
  end
  return nil
end

local function battleHost(outcome)
  local launches = {}
  local sourceResult = outcome == "win" and 1 or 0
  return {
    launchBattle = function(_, spec)
      launches[#launches + 1] = spec
      return "script-launch-1"
    end,
    battleStatus = function()
      return { phase = "complete", committed = true, result = outcome, sourceResult = sourceResult }
    end,
    lastBattleResult = function()
      return { result = outcome, sourceResult = sourceResult }
    end,
  },
    launches
end

-- A composed rival battle: the script launches its own battle, branches on
-- the committed result, and only the winning branch flags the trainer and
-- runs the source rival naming wait.
local function rivalBattleSteps()
  return {
    {
      op = "battle_launch",
      kind = "trainer",
      details = { trainer = 3 },
      result = { value = "var", id = "VAR_TEMP_x4001" },
    },
    { op = "battle_result", result = { value = "var", id = "VAR_TEMP_x4001" } },
    {
      op = "if",
      condition = {
        condition = "compare",
        operator = "eq",
        left = { value = "var", id = "VAR_TEMP_x4001" },
        right = 1,
      },
      yes = {
        { op = "set_flag", flag = { value = "trainer_flag_id", trainer = 3 } },
        { op = "rival_naming", result = { value = "var", id = "VAR_TEMP_x4003" } },
        { op = "set_var", variable = "VAR_TEMP_x4002", value = 1 },
      },
      no = {
        { op = "set_var", variable = "VAR_TEMP_x4002", value = 2 },
      },
    },
  }
end

-- The source rival-naming wait runs the one shared field naming screen and
-- publishes the accepted name to the live saved profile; the script resumes
-- only after the screen closes.
function T.tests.rival_naming_blocks_then_publishes_the_accepted_name_to_the_saved_profile()
  local record = savedPlayer("SILVER")
  local naming = namingHost()
  local platform = composeSlice(
    {
      travel = nil,
      fieldMoves = nil,
      monNaming = naming,
      profile = record.profile,
      fontDef = { charmap = CatalogFixture.CHARMAP },
      encode = encodedChunk,
    },
    "test.rival_naming",
    {
      { op = "rival_naming", result = { value = "var", id = "VAR_TEMP_x4003" } },
      { op = "set_var", variable = "VAR_TEMP_x4002", value = 7 },
    }
  )
  local composed = assert(platform.composition:effective("test.rival_naming"), "the rival naming slice must compose")
  local instanceId = platform.scheduler:createForeground(composed, nil, 100)
  local running = assert(platform.scheduler:instance(instanceId))
  local openedAt = assert(stepUntilNaming(platform, naming, 100), "the script blocks on the naming screen")
  Assert.equal(running.status, "blocked", "the script instance blocks on the naming task")
  Assert.notNil(running.waitingTaskId, "the blocking task owns the script continuation")
  Assert.equal(record.profile.rivalName, "SILVER", "the saved rival name is untouched before acceptance")
  Assert.equal(platform.worldState:getVar("VAR_TEMP_x4002"), 0, "no script step runs behind the naming screen")

  submitRivalName(platform, openedAt + 1, "SOUL")
  Assert.equal(record.profile.rivalName, "SILVER", "editing the name publishes nothing yet")
  local closedAt = assert(
    stepUntilNamingClosed(platform, naming, openedAt + 2, function()
      Assert.equal(
        platform.worldState:getVar("VAR_TEMP_x4002"),
        0,
        "the script resumes only after the naming screen closes"
      )
    end),
    "the naming screen settles after its OK press"
  )
  for index = 1, 3 do
    platform.scheduler:step(closedAt + index, nil)
  end

  Assert.isFalse(naming:isActive(), "the modal released the field")
  Assert.equal(record.profile.rivalName, "SOUL", "the accepted name lands on the live saved profile")
  Assert.equal(platform.player:rivalName(), "SOUL", "dialogue reads the new rival name immediately")
  Assert.equal(
    platform.worldState:getVar("VAR_TEMP_x4003"),
    0,
    "the source result variable receives the accepted result code"
  )
  Assert.equal(platform.worldState:getVar("VAR_TEMP_x4002"), 7, "the resumed script ran to its end")

  local captured = assert(PlayerData.validate({ profile = record.profile, options = record.options }, SAVE_CONTEXT))
  Assert.equal(captured.profile.rivalName, "SOUL", "the captured save carries the new rival name")
  platform.player:setProfile(captured.profile)
  Assert.equal(platform.player:rivalName(), "SOUL", "a reloaded save still shows the new rival name")
end

-- The live name write re-checks the saved-profile name contract, so a name the
-- generated field font cannot encode -- or one outside the 1..7-glyph limit --
-- faults before it reaches the profile or any later save capture.
function T.tests.rival_name_write_rejects_unusable_names_and_keeps_the_profile()
  local record = savedPlayer("SILVER")
  local platform = composeSlice({
    travel = nil,
    fieldMoves = nil,
    profile = record.profile,
    fontDef = { charmap = CatalogFixture.CHARMAP },
    encode = encodedChunk,
  }, "test.rival_name_write", { { op = "set_var", variable = "VAR_TEMP_x4002", value = 1 } })
  -- The generated charmap holds the uppercase letters and only the lowercase
  -- glyphs the default rival name uses, so "o" and "u" are unencodable.
  for _, rejected in ipairs({ "Soul", "", "TOOLONGNAME" }) do
    local err = Assert.throws(function()
      platform.player:setRivalName(rejected)
    end)
    Assert.equal(
      err and err.code,
      "PLAYER_DATA_NAME_INVALID",
      "rival name " .. tostring(rejected) .. " must be rejected"
    )
    Assert.equal(record.profile.rivalName, "SILVER", "a rejected name leaves the live profile untouched")
    Assert.equal(platform.player:rivalName(), "SILVER", "the script-visible rival name stays the accepted one")
  end
  platform.player:setRivalName("SOUL")
  Assert.equal(record.profile.rivalName, "SOUL", "an encodable name inside the limit is published")
end

-- A scripted rival battle keeps its supported launch and outcome: the
-- script-owned branch decides the trainer flag and the following naming, and
-- a loss neither awards a flag nor opens the naming screen.
function T.tests.rival_battle_outcome_gates_the_trainer_flag_and_the_following_naming()
  local record = savedPlayer("SILVER")
  local winHost, winLaunches = battleHost("win")
  local winNaming = namingHost()
  local platform = composeSlice({
    travel = nil,
    fieldMoves = nil,
    battle = winHost,
    monNaming = winNaming,
    profile = record.profile,
    fontDef = { charmap = CatalogFixture.CHARMAP },
    encode = encodedChunk,
  }, "test.rival_battle", rivalBattleSteps())
  local composed = assert(platform.composition:effective("test.rival_battle"), "the rival battle slice must compose")
  local instanceId = platform.scheduler:createForeground(composed, nil, 300)
  local running = assert(platform.scheduler:instance(instanceId))
  local openedAt = assert(stepUntilNaming(platform, winNaming, 300), "the winning branch reaches rival naming")
  Assert.equal(running.status, "blocked", "the script still blocks on the naming task")
  Assert.notNil(running.waitingTaskId, "the naming task owns the script continuation")
  Assert.equal(#winLaunches, 1, "the script launched its own rival battle once")
  Assert.equal(winLaunches[1].kind, "trainer")
  Assert.isTrue(platform.worldState:isFlagSet(TRAINER_FLAG_BASE + 3), "the winning branch flags the defeated trainer")
  Assert.equal(platform.worldState:getVar("VAR_TEMP_x4002"), 0, "naming blocks before the following script step")

  submitRivalName(platform, openedAt + 1, "SOUL")
  local closedAt = assert(stepUntilNamingClosed(platform, winNaming, openedAt + 2), "the naming screen settles")
  for index = 1, 3 do
    platform.scheduler:step(closedAt + index, nil)
  end
  Assert.equal(record.profile.rivalName, "SOUL", "the winning branch named the rival")
  Assert.equal(platform.worldState:getVar("VAR_TEMP_x4002"), 1, "the winning branch ran to its end")

  local lostRecord = savedPlayer("SILVER")
  local lostHost, lostLaunches = battleHost("loss")
  local lostNaming = namingHost()
  local lostPlatform = composeSlice({
    travel = nil,
    fieldMoves = nil,
    battle = lostHost,
    monNaming = lostNaming,
    profile = lostRecord.profile,
    fontDef = { charmap = CatalogFixture.CHARMAP },
    encode = encodedChunk,
  }, "test.rival_battle", rivalBattleSteps())
  local lostComposed = assert(lostPlatform.composition:effective("test.rival_battle"))
  lostPlatform.scheduler:createForeground(lostComposed, nil, 500)
  for index = 1, 32 do
    lostPlatform.scheduler:step(500 + index, nil)
  end
  Assert.equal(#lostLaunches, 1, "the losing branch still runs the scripted battle")
  Assert.isFalse(
    lostPlatform.worldState:isFlagSet(TRAINER_FLAG_BASE + 3),
    "a lost battle awards no trainer flag by itself"
  )
  Assert.isFalse(lostNaming:isActive(), "the losing branch never opens the naming screen")
  Assert.equal(lostRecord.profile.rivalName, "SILVER", "the losing branch keeps the saved rival name")
  Assert.equal(lostPlatform.worldState:getVar("VAR_TEMP_x4002"), 2, "the losing branch ran to its end")
  Assert.isFalse(FieldEventState.new():isFlagSet(TRAINER_FLAG_BASE + 3), "a new game carries no defeated trainer")
end

return T
