-- Johto League clear through the production field composition. The Hall of
-- Fame room's own frame scene walks the player and Lance through the source
-- choreography, plays the machine's ball effect, registers the party, publishes
-- one atomic saved game and rolls the original credits; the run then hands the
-- host its own main-menu route. Continuing from that published save lands in
-- the source post-clear room with exactly one immutable record and one League
-- win. A failed final publication keeps the previous disk state and retries the
-- same staged candidate, and the ending never claims a save it did not make.
-- Only audio, fade, clock and the host's route callback are recorded - the
-- field, map, scripts, save store and every domain owner stay production-owned,
-- and the render trap stays active throughout.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldBattleDriver = require("tests.acceptance.support.FieldBattleDriver")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "map:306",
      "map-data:306",
      "message-bank:528",
      -- The post-clear destination the committed save restores: the player's
      -- own room (map 64), not Saffron (map 59).
      "map:64",
      "map-data:64",
      "message-bank:14",
      -- Mount Silver's summit, where the source Red ending lives.
      "map:465",
      "map-data:465",
      "message-bank:126",
      -- The League ending's own generated bundle: registration, showcase
      -- and credit-roll sections the congratulations and roll draw.
      "ending:global",
      -- The save-status window (bank 40) and the recorded party's icon
      -- pages the registration receipt admits outside draw. Without them
      -- the congratulations holds its phase instead of publishing cold.
      "message-bank:40",
      "mon-catalog:global",
      "mon-layout:global",
      "mon-icon-page:20",
      "mon-icon-page:29",
    },
    tags = { "field", "script", "ending", "save" },
  },
  tests = {},
}

local HOF_ROOM = "MAP_POKEMON_LEAGUE_HALL_OF_FAME"
-- The room's own frame-entry scene (scr_seq 0825 is this map's script member).
local ENDING_SCRIPT = "vanilla.hgss.scr_seq.0825.script_000"
local HOF_APPROACH = { fieldX = 6, fieldZ = 22, facing = "north" }

-- The committed post-clear destination is the player's own room at the source
-- location_backup.c tile, not the room the League battle left the player in.
local POST_CLEAR_ROOM = "MAP_NEW_BARK_PLAYER_HOUSE_2F"
local POST_CLEAR_TILE = { fieldX = 6, fieldZ = 6 }

-- Mount Silver's summit object runs the source Red ending (scr_seq 0107).
local RED_ROOM = "MAP_MOUNT_SILVER_CAVE_SUMMIT"
local RED_SCRIPT = "vanilla.hgss.scr_seq.0107.script_000"
local RED_APPROACH = { fieldX = 30, fieldZ = 12, facing = "north" }

local HOF_BUCKET_SCHEMA = "hgss-hall-of-fame-v1"

local FLAG_GAME_CLEAR = assert(FieldScriptSymbols.flagsByName.FLAG_GAME_CLEAR)
local VAR_ROAMER_ENTEI_STATUS = assert(FieldScriptSymbols.variablesByName.VAR_ROAMER_ENTEI_STATUS)
local VAR_ROAMER_RAIKOU_STATUS = assert(FieldScriptSymbols.variablesByName.VAR_ROAMER_RAIKOU_STATUS)
local VAR_ROAMER_LATIAS_STATUS = assert(FieldScriptSymbols.variablesByName.VAR_ROAMER_LATIAS_STATUS)
-- The room's frame table starts its scene while this source word is 0; holding
-- it off lets a scenario publish the save the player carried into the League.
local VAR_HOF_FRAME_ENTRY = assert(FieldScriptSymbols.variablesByName.VAR_TEMP_x4001)

-- Source roamer status words: 1 marks a captured roamer the ending leaves
-- alone, 3 one the player never met.
local ROAMER_CAPTURED = 1
local ROAMER_UNMET = 3

-- The prepared party members the clear registers, in party order.
local PARTY = {
  { species = "TYPHLOSION", level = 60, move = "FLAMETHROWER" },
  { species = "PIDGEOT", level = 55, move = "AERIAL_ACE" },
}

-- credits.c CREDITS_FRAMES: the full source roll a first clear plays. A skip
-- input on a later clear ends the credits far before it.
local SOURCE_CREDITS_FRAMES = 4976
-- The 0825 room scene's own source chain before the game-clear transaction:
-- 31 walked tiles at the source 8 ticks each, its printed name message, the
-- 514 machine effect and its fade. The clear is only reachable after it.
-- The registration then reveals every recorded member (541 source ticks
-- each) before the whole-party photo and the save the budget waits for.
local SCENE_AND_ENDING_TICKS = 2600
-- The skip window after the retried publication: the save-status sound (32)
-- and fades (8+30+1+60) run on the source timeline before the host route,
-- so the window covers the roll skip plus The End's own fade-out.
local SKIP_WINDOW_TICKS = 400
-- The ending's own source dialogue and The End screen answer these inputs.
local START_PRESS_INTERVAL = 30

---@param options table
---@return AcceptanceHarness
local function harnessAt(options)
  local harness = AcceptanceHarness.new()
  local createGame = harness.gameFactory
  harness.gameFactory = function(versionId, map)
    local worldState = FieldEventState.new()
    if options.cleared then
      worldState:setFlag(FLAG_GAME_CLEAR)
    end
    if options.holdFrameScene then
      worldState:setVar(VAR_HOF_FRAME_ENTRY, 1)
    end
    for variable, value in pairs(options.variables or {}) do
      worldState:setVar(variable, value)
    end
    local game = createGame(versionId, map)
    game.location = {
      mapSymbol = options.mapSymbol,
      fieldX = options.fieldX,
      fieldZ = options.fieldZ,
      facing = options.facing,
    }
    game.worldState = worldState
    return game
  end
  return harness
end

---@param game table acceptance game
---@param routes table recorded host route calls
---@return table game
local function bootEnding(game, routes)
  local booted = game
  -- The Hall of Fame room's frame scene owns the field from its first settled
  -- boundary, so the party the clear registers is prepared through the
  -- production mon owner before the scene runs.
  local party = assert(booted.runtime.monService, "the field runtime owns its mon service")
  for slot0, member in ipairs(PARTY) do
    Assert.isTrue(
      party:giveMon({ species = member.species, level = member.level, form = 0, heldItem = "NONE" }),
      "the prepared party member enters through the production gift operation"
    )
    party:setMove(slot0 - 1, 0, member.move)
  end
  Assert.equal(routes.count, 0, "the ending does not hand the host a route before the scene runs")
  return booted
end

---@param harness AcceptanceHarness
---@return table game, table routes
local function bootHofEnding(harness)
  local routes = { count = 0 }
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = HOF_ROOM,
    save = "fresh",
    fieldOptions = {
      recordingScriptHosts = true,
      audioHost = "recording",
      returnToMainMenu = function()
        routes.count = routes.count + 1
      end,
    },
  })
  return bootEnding(game, routes), routes
end

---@param game table acceptance game
---@return string the published payload bytes on disk
local function payloadBytes(game)
  local saveId = assert(game.runtime.saveId, "the runtime owns its save identity")
  local path = assert(game.saveNamespace, "the acceptance game owns its save namespace")
    .. "/global/games/"
    .. saveId
    .. ".lua"
  return assert(love.filesystem.read(path), "the published save payload is on disk")
end

---@param game table acceptance game
---@return table the record the production store loads back
local function publishedRecord(game)
  local store = assert(game.runtime.saveStore, "the field runtime owns its save store")
  local saveId = assert(game.runtime.saveId, "the runtime owns its save identity")
  return assert(store:load(saveId), "the published save loads through the production store")
end

---@param game table acceptance game
---@param scriptId string? ending script identity, the Johto room's by default
---@return string[] faults the ending script published
local function endingFaults(game, scriptId)
  local faults = {}
  for _, record in ipairs(game:recordsForScript(scriptId or ENDING_SCRIPT, "script.error")) do
    local payload = record.payload or {}
    local context = payload.context or {}
    faults[#faults + 1] = string.format(
      "%s/%s/%s",
      tostring(payload.code),
      tostring(context.command or context.originalName or "unknown"),
      tostring(payload.message)
    )
  end
  return faults
end

-- Advances the fixed tick, answering source dialogue and the ending's The End
-- screen, until the caller's boundary is reached, the ending script faults, or
-- the budget runs out. Returns the tick the boundary was observed at.
---@param game table acceptance game
---@param scriptId string the ending scene under test
---@param label string boundary description
---@param done fun(): boolean
---@param maxTicks integer
---@return integer tick
local function advanceEnding(game, scriptId, label, done, maxTicks)
  for step = 1, maxTicks do
    if done() then
      return game:snapshot().tick
    end
    if #endingFaults(game, scriptId) > 0 then
      return game:snapshot().tick
    end
    if game:snapshot().dialogue.modal then
      game:pressAction()
    else
      -- The registration and The End advance on A/B/touch (never START),
      -- while a later clear's roll skips on START/touch. Drive both edges
      -- so one driver covers every ending phase.
      if step % START_PRESS_INTERVAL == 0 then
        game.runtime:pressMenu()
        game:step()
        game.runtime:releaseMenu()
      elseif step % 10 == 0 then
        game:pressAction()
      else
        game:step()
      end
    end
  end
  error(
    "the source League ending did not reach "
      .. label
      .. "; foreground="
      .. tostring(game:snapshot().foregroundScript)
      .. ", modal="
      .. tostring(game:snapshot().dialogue.modal)
      .. ", saveStatus="
      .. tostring(game.runtime.saveStatus)
      .. ", tick="
      .. tostring(game:snapshot().tick),
    0
  )
end

---@param game table acceptance game
---@return table the published Hall of Fame bucket
local function hallOfFameBucket(game)
  local bucket = assert(publishedRecord(game).hallOfFame, "the current save carries the Hall of Fame bucket")
  Assert.equal(bucket.schema, HOF_BUCKET_SCHEMA, "the saved history carries its own schema identity")
  return bucket
end

---@param game table acceptance game
---@return integer the saved League-win statistic
local function leagueWins(game)
  return publishedRecord(game).gameStats.leagueWins
end

---@param bucket table the published Hall of Fame bucket
---@param expected table[] the party the clear registered
---@param what string assertion context
local function assertRecordedParty(bucket, expected, what)
  Assert.equal(#bucket.records, 1, what .. " retains exactly one record")
  local record = bucket.records[1]
  Assert.equal(#record.party, #expected, what .. " snapshots the non-Egg party")
  for index, member in ipairs(expected) do
    local captured = record.party[index]
    Assert.equal(captured.species, member.species, what .. " keeps party slot " .. index .. " by species")
    Assert.equal(captured.level, member.level, what .. " keeps party slot " .. index .. " by level")
    Assert.equal(captured.otName, "GOLD", what .. " keeps the party's own trainer name")
    Assert.equal(#captured.moves, 4, what .. " keeps four move slots")
    Assert.equal(captured.moves[1], member.move, what .. " keeps the party's leading move")
  end
  Assert.equal(record.date.year, 2000, what .. " stamps the host-local clear date")
  Assert.equal(record.date.month, 1, what .. " stamps the host-local clear month")
  Assert.equal(record.date.day, 1, what .. " stamps the host-local clear day")
end

-- The legal decision kinds one open production battle request offers.
---@param request table open player request
---@return table<string, boolean>
local function offeredKinds(request)
  local kinds = assert(
    request.legalChoices and request.legalChoices.kinds,
    "a decision request lists its legal decision kinds"
  ) --[[@as string[] ]]
  local offers = {}
  for _, kind in ipairs(kinds) do
    offers[kind] = true
  end
  return offers
end

-- Drives one battle the field launched the way a player fighting to the end
-- would: strike when a strike is offered, acknowledge a source prompt
-- otherwise, and replace a fainted party member with the next legal reserve.
-- The battle's own reply validation decides which reserve identity binds, so
-- this borrows no battle or party internals.
---@param game table acceptance game owning the production field runtime
---@param label string boundary description
---@param maxTicks integer
local function fightBattleToTheEnd(game, label, maxTicks)
  local answered = nil
  for _ = 1, maxTicks do
    local battle = game.runtime.battleCoordinator:activeBattle()
    if battle == nil then
      return
    end
    local status = battle:status()
    if status.phase == "failed" then
      error("the field battle application failed: " .. tostring(status.error), 0)
    end
    if status.phase == "running" and status.request ~= nil and status.request.requestId ~= answered then
      local request = status.request
      answered = request.requestId
      local offers = offeredKinds(request)
      if offers["switch"] and not offers.attack then
        local accepted = false
        for reserve = 1, 12 do
          local choices = {}
          for _, actor in ipairs(assert(request.actors, "a replacement request names its entries")) do
            choices[#choices + 1] = SessionFixture.switchChoice(actor, reserve)
          end
          accepted = battle:submit(SessionFixture.replyFor(request, choices)) == true
          if accepted then
            break
          end
        end
        Assert.isTrue(accepted, "the source battle accepts the next legal reserve")
      else
        local choices = {}
        for _, actor in ipairs(assert(request.actors, "a decision request names its actors")) do
          choices[#choices + 1] = offers.attack
              and SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(FieldBattleDriver.FOE_POSITION))
            or SessionFixture.confirmChoice(actor)
        end
        Assert.isTrue(
          battle:submit(SessionFixture.replyFor(request, choices)) == true,
          "the source battle accepts the player's legal decision"
        )
      end
    end
    game:step()
  end
  error("the source battle did not release the field: " .. label, 0)
end

-- The first clear: the room's own scene, the machine effect, one published
-- record, the source credits and the host's main-menu route.
function T.tests.first_clear_publishes_one_record_and_continues_in_the_post_clear_room()
  local game, routes = bootHofEnding(harnessAt({
    mapSymbol = HOF_ROOM,
    fieldX = HOF_APPROACH.fieldX,
    fieldZ = HOF_APPROACH.fieldZ,
    facing = HOF_APPROACH.facing,
  }))
  local loaded
  local ok, err = xpcall(function()
    advanceEnding(game, ENDING_SCRIPT, "its published save", function()
      return routes.count > 0
    end, SOURCE_CREDITS_FRAMES + 2600)

    local faults = endingFaults(game)
    Assert.equal(#faults, 0, "the room's own scene completes every native operation: " .. table.concat(faults, ","))
    Assert.equal(routes.count, 1, "the ending hands the host its main-menu route exactly once")
    Assert.isNil(
      game:snapshot().foregroundScript,
      "the suspended ending script is cancelled instead of resuming the source tail"
    )
    Assert.equal(
      #game:recordsForScript(ENDING_SCRIPT, "script.started"),
      1,
      "the room's frame scene runs exactly once"
    )

    local bucket = hallOfFameBucket(game)
    Assert.equal(bucket.total, 1, "the first clear records one history entry")
    assertRecordedParty(bucket, PARTY, "the first clear")

    local saved = publishedRecord(game)
    Assert.isTrue(
      saved.sysInfo.firstClearAt ~= nil and saved.sysInfo.firstClearAt ~= false,
      "the first clear keeps the host-local moment the game was first cleared"
    )
    Assert.equal(saved.gameStats.leagueWins, 1, "the first Johto clear counts one League win")
    Assert.isTrue(
      game.runtime.scripts.worldState:isFlagSet(FLAG_GAME_CLEAR),
      "the published ending sets the authoritative game-clear flag"
    )
    loaded = saved
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end

  -- Continue through the production store: the committed post-clear room, the
  -- same single record, and its own post-clear entry scripts.
  local resumed = AcceptanceHarness.new({
    gameFactory = function()
      return loaded
    end,
  }):boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = POST_CLEAR_ROOM,
    save = "continue",
    -- The continued journey starts from the save the ending published.
    seedSave = loaded,
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  local resumedOk, resumedErr = xpcall(function()
    resumed:waitForFieldEntry()
    resumed:waitForFieldReady(480)
    local snapshot = resumed:snapshot()
    Assert.equal(snapshot.mapSymbol, POST_CLEAR_ROOM, "Continue restores the committed post-clear room")
    Assert.equal(snapshot.player.fieldX, POST_CLEAR_TILE.fieldX, "Continue restores the source post-clear tile")
    Assert.equal(snapshot.player.fieldZ, POST_CLEAR_TILE.fieldZ, "Continue restores the source post-clear tile depth")
    Assert.isTrue(
      resumed.runtime.scripts.worldState:isFlagSet(FLAG_GAME_CLEAR),
      "Continue keeps the game-clear flag the ending committed"
    )
    local continued = publishedRecord(resumed)
    Assert.equal(continued.hallOfFame.total, 1, "Continue keeps exactly one recorded clear")
    Assert.equal(continued.gameStats.leagueWins, 1, "Continue keeps exactly one League win")
    Assert.deepEqual(
      continued.hallOfFame,
      loaded.hallOfFame,
      "the continued save republishes the recorded history unchanged"
    )

    -- The history is a snapshot: owning a party afterwards never rewrites it.
    local party = assert(resumed.runtime.monService, "the continued field owns its mon service")
    party:setMove(0, 0, "EMBER")
    party:setMove(1, 0, "TACKLE")
    local recaptured = assert(resumed.runtime:captureGameSave(), "the continued field captures its own save")
    Assert.deepEqual(
      recaptured.hallOfFame,
      loaded.hallOfFame,
      "later party changes never alter a recorded clear"
    )
    Assert.equal(resumed:renderAttempts(), 0, "the ending acceptance stops before GPU rendering")
  end, debug.traceback)
  resumed:close()
  if not resumedOk then
    error(resumedErr, 0)
  end
end

-- A failed final publication keeps the previous save on disk, reports the
-- failure instead of claiming success, and retries the same staged candidate.
function T.tests.failed_final_save_keeps_disk_state_and_retries_the_same_candidate()
  local game, routes = bootHofEnding(harnessAt({
    mapSymbol = HOF_ROOM,
    fieldX = HOF_APPROACH.fieldX,
    fieldZ = HOF_APPROACH.fieldZ,
    facing = HOF_APPROACH.facing,
    holdFrameScene = true,
  }))
  local ok, err = xpcall(function()
    -- The player's own save before the ending: this is the state a failed
    -- final publication must leave untouched.
    game:waitForFieldEntry()
    game:waitForFieldReady(480)
    local store = assert(game.runtime.saveStore, "the field runtime owns its save store")
    Assert.isTrue(
      store:publishFirst(assert(game.runtime:captureGameSave(), "the field captures its own save")),
      "the journey publishes its ordinary save"
    )
    local beforeBytes = payloadBytes(game)
    local beforeRecord = publishedRecord(game)
    local beforeRng = game.runtime.scripts.worldState.rng:serialize()

    -- Release the room's own frame scene, then fail its final publication.
    game:setWorldState({ variable = VAR_HOF_FRAME_ENTRY, value = 0 })
    game:failNextSave()
    -- The room's own scene walks its source movements, prints its name
    -- message, plays the machine effect and fades before 163 can begin: the
    -- failure is reported only after that whole source chain ran.
    advanceEnding(game, ENDING_SCRIPT, "its reported save failure", function()
      local status = game.runtime.saveStatus
      return type(status) == "string" and status:find("Save failed", 1, true) ~= nil
    end, SCENE_AND_ENDING_TICKS)

    local faults = endingFaults(game)
    Assert.equal(#faults, 0, "the room's own scene completes every native operation: " .. table.concat(faults, ","))
    local status = game.runtime.saveStatus
    Assert.isTrue(
      type(status) == "string" and status:find("Save failed", 1, true) ~= nil,
      "the ending reports the final save it could not make instead of claiming success"
    )
    Assert.equal(routes.count, 0, "the ending never reaches the host route before its save is published")
    Assert.equal(payloadBytes(game), beforeBytes, "a failed final save leaves the published save on disk untouched")
    local afterFailure = publishedRecord(game)
    Assert.deepEqual(afterFailure.hallOfFame, beforeRecord.hallOfFame, "a failed final save records no clear")
    Assert.equal(afterFailure.gameStats.leagueWins, beforeRecord.gameStats.leagueWins, "a failed save awards no win")

    -- The retry is the source save-status input: one action edge retries the
    -- same staged candidate, drawing nothing new from the world stream.
    game:pressAction()
    advanceEnding(game, ENDING_SCRIPT, "the retried publication", function()
      return routes.count > 0
    end, SOURCE_CREDITS_FRAMES + 2600)

    Assert.equal(routes.count, 1, "the retried ending publishes once and hands the host its route")
    local retriedFaults = endingFaults(game)
    Assert.equal(
      #retriedFaults,
      0,
      "the retried ending completes every native operation: " .. table.concat(retriedFaults, ",")
    )
    local published = publishedRecord(game)
    Assert.equal(published.hallOfFame.total, 1, "the retry publishes the one prepared record, never a second")
    assertRecordedParty(published.hallOfFame, PARTY, "the retried publication")
    Assert.equal(published.gameStats.leagueWins, 1, "the retry counts the one League win")
    Assert.deepEqual(
      game.runtime.scripts.worldState.rng:serialize(),
      beforeRng,
      "the retry neither redraws nor advances the committed world stream"
    )
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- A repeat clear appends one more record and lets the source credits be
-- skipped, while a first clear never does.
function T.tests.repeat_clear_appends_a_record_and_allows_skipping_the_source_credits()
  local game, routes = bootHofEnding(harnessAt({
    mapSymbol = HOF_ROOM,
    fieldX = HOF_APPROACH.fieldX,
    fieldZ = HOF_APPROACH.fieldZ,
    facing = HOF_APPROACH.facing,
    cleared = true,
    holdFrameScene = true,
  }))
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    game:waitForFieldReady(480)
    local store = assert(game.runtime.saveStore, "the field runtime owns its save store")
    Assert.isTrue(
      store:publishFirst(assert(game.runtime:captureGameSave(), "the field captures its own save")),
      "the previously cleared journey publishes its save"
    )
    local winsBefore = leagueWins(game)
    game:setWorldState({ variable = VAR_HOF_FRAME_ENTRY, value = 0 })

    -- The ending publishes its own recorded clear before the credits start;
    -- the journey's earlier ordinary save carries the empty history bucket.
    advanceEnding(game, ENDING_SCRIPT, "the start of its credits", function()
      return (publishedRecord(game).hallOfFame.total or 0) > 0
    end, SCENE_AND_ENDING_TICKS)
    local faults = endingFaults(game)
    Assert.equal(#faults, 0, "the room's own scene completes every native operation: " .. table.concat(faults, ","))
    local publishedAt = game:snapshot().tick

    -- The source skip input on a later clear ends the credits long before the
    -- full roll would.
    game.runtime:pressMenu()
    game:step()
    game.runtime:releaseMenu()
    advanceEnding(game, ENDING_SCRIPT, "the skipped credits", function()
      return routes.count > 0
    end, SKIP_WINDOW_TICKS)

    Assert.equal(routes.count, 1, "the skipped credits hand the host its main-menu route")
    Assert.isTrue(
      game:snapshot().tick - publishedAt < SOURCE_CREDITS_FRAMES,
      "a later clear's credits end on the source skip input instead of the full roll"
    )
    local bucket = hallOfFameBucket(game)
    Assert.equal(bucket.total, 1, "a repeat clear appends one entry to the history it found")
    assertRecordedParty(bucket, PARTY, "the appended clear")
    Assert.equal(leagueWins(game), winsBefore + 1, "a repeat Johto clear counts one more League win")
    Assert.equal(
      publishedRecord(game).sysInfo.firstClearAt,
      false,
      "a save that was already cleared keeps its unknown first-clear date instead of inventing one"
    )
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The source ending recreates only the roamers a previous battle defeated, so
-- the post-League graph matches what the player actually left behind. The
-- journey creates the slots through the production creation owner, settles a
-- defeat and a capture through the battle commit owner, publishes and continues
-- from that save, and only then runs the room's own scene.
function T.tests.post_league_ending_recreates_only_the_defeated_roamers()
  local game, routes = bootHofEnding(harnessAt({
    mapSymbol = HOF_ROOM,
    fieldX = HOF_APPROACH.fieldX,
    fieldZ = HOF_APPROACH.fieldZ,
    facing = HOF_APPROACH.facing,
    holdFrameScene = true,
    variables = {
      [VAR_ROAMER_LATIAS_STATUS] = ROAMER_UNMET,
    },
  }))
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    game:waitForFieldReady(480)
    local roamers = assert(game.runtime.roamerState, "the field runtime owns its roamer state")
    local HgssBattleCommitter = require("libs.hgss.src.battle.HgssBattleCommitter")
    -- The two source slots the player already met: Raikou enters the journey
    -- and is captured, Entei enters and is defeated. Both outcomes stage
    -- through the battle commit owner and publish their source status word.
    local function commitOutcome(key, outcome, revision, result)
      local receipt = HgssBattleCommitter.commit(HgssBattleCommitter.prepare({
        outcome = { id = "acceptance:" .. key .. ":" .. outcome, result = result },
        roamer = {
          owner = roamers,
          key = key,
          outcome = outcome,
          expectedRevision = revision,
          details = {},
        },
      }))
      game.runtime:_publishRoamerStatus(receipt.roamer)
      return receipt.roamer
    end
    game.runtime:createNativeRoamer(0)
    game.runtime:createNativeRoamer(1)
    commitOutcome("native.raikou", "captured", 0, "capture")
    local defeated = commitOutcome("native.entei", "defeated", 0, "win")
    Assert.equal(defeated.lifecycle, "defeated", "the committed battle leaves the defeated Entei record")
    local defeatedIdentity = defeated.mon.personality

    -- Publish and continue from that settled state: the restored owner owns the
    -- terminal records, not a live launch artifact.
    local store = assert(game.runtime.saveStore, "the field runtime owns its save store")
    Assert.isTrue(
      store:publishFirst(assert(game.runtime:captureGameSave(), "the defeated journey captures its save")),
      "the defeated journey publishes its save"
    )
    game:restart()
    game:waitForFieldEntry()
    game:waitForFieldReady(480)
    roamers = assert(game.runtime.roamerState, "the continued runtime owns its roamer state")
    local before = roamers:capture()
    Assert.equal(
      assert(before.roamers["native.entei"], "Continue restores the defeated Entei").lifecycle,
      "defeated",
      "Continue restores the defeated record instead of a bare status word"
    )
    Assert.equal(
      assert(before.roamers["native.raikou"], "Continue restores the captured Raikou").lifecycle,
      "caught",
      "Continue restores the captured record"
    )
    Assert.isNil(before.roamers["native.latias"], "a roamer never met starts with no live record")

    game:setWorldState({ variable = VAR_HOF_FRAME_ENTRY, value = 0 })
    advanceEnding(game, ENDING_SCRIPT, "its published save", function()
      return routes.count > 0
    end, SOURCE_CREDITS_FRAMES + 2600)

    local faults = endingFaults(game)
    Assert.equal(#faults, 0, "the room's own scene completes every native operation: " .. table.concat(faults, ","))
    local world = game.runtime.scripts.worldState
    Assert.equal(world:getVar(VAR_ROAMER_ENTEI_STATUS), 0, "the recreated Entei slot returns to the source status")
    Assert.equal(
      world:getVar(VAR_ROAMER_RAIKOU_STATUS),
      ROAMER_CAPTURED,
      "the captured Raikou keeps the status that keeps it gone"
    )
    Assert.equal(
      world:getVar(VAR_ROAMER_LATIAS_STATUS),
      ROAMER_UNMET,
      "a roamer never met keeps the status the ending never touches"
    )
    local after = roamers:capture()
    local entei = assert(after.roamers["native.entei"], "the ending recreates the defeated Entei")
    Assert.equal(entei.lifecycle, "roaming", "the recreated Entei roams again")
    Assert.equal(entei.mon.species, "ENTEI", "the recreated Entei keeps its source species")
    Assert.equal(entei.revision, 2, "the recreation invalidates the defeated revision")
    Assert.isTrue(entei.mon.personality ~= defeatedIdentity, "the recreation materializes a fresh identity")
    Assert.equal(
      assert(after.roamers["native.raikou"], "the ending keeps the captured record").lifecycle,
      "caught",
      "the ending never recreates a captured roamer"
    )
    Assert.isNil(after.roamers["native.latias"], "the ending never creates a roamer the player never met")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The Red ending runs the same game-clear policy with a nonzero raw operand: it
-- rolls the credits but registers no Johto Hall of Fame entry and counts no
-- League win.
function T.tests.red_ending_records_no_johto_entry_and_no_league_win()
  local routes = { count = 0 }
  local game = harnessAt({
    mapSymbol = RED_ROOM,
    fieldX = RED_APPROACH.fieldX,
    fieldZ = RED_APPROACH.fieldZ,
    facing = RED_APPROACH.facing,
  }):boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = RED_ROOM,
    save = "fresh",
    fieldOptions = {
      recordingScriptHosts = true,
      audioHost = "recording",
      returnToMainMenu = function()
        routes.count = routes.count + 1
      end,
    },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    -- A level-100 party with a never-missing move: the summit battle is a real
    -- source battle, so the scenario has to win it rather than skip it.
    local party = assert(game.runtime.monService, "the field runtime owns its mon service")
    for slot0 = 0, 5 do
      Assert.isTrue(
        party:giveMon({ species = "MEWTWO", level = 100, form = 0, heldItem = "NONE" }),
        "the prepared battle party enters through the production gift operation"
      )
      while party:countMonMoves(slot0) > 0 do
        party:deleteMove(slot0, 0)
      end
      party:setMove(slot0, 0, "AURA_SPHERE")
    end
    game:waitForFieldReady(480)

    local store = assert(game.runtime.saveStore, "the field runtime owns its save store")
    Assert.isTrue(
      store:publishFirst(assert(game.runtime:captureGameSave(), "the field captures its own save")),
      "the Red journey publishes its ordinary save"
    )
    local before = publishedRecord(game)

    game:pressAction()
    Assert.equal(game:interaction().scriptId, RED_SCRIPT, "Red's own object starts its source scene")
    advanceEnding(game, RED_SCRIPT, "its launched source battle", function()
      return game.runtime.battleCoordinator:activeBattle() ~= nil
    end, 600)
    local launchFaults = endingFaults(game, RED_SCRIPT)
    Assert.equal(#launchFaults, 0, "Red's own scene completes every native operation: " .. table.concat(launchFaults, ","))
    fightBattleToTheEnd(game, "the source Red battle", 8000)

    advanceEnding(game, RED_SCRIPT, "its published save", function()
      return routes.count > 0
    end, SOURCE_CREDITS_FRAMES + 6000)
    local endingRedFaults = endingFaults(game, RED_SCRIPT)
    Assert.equal(
      #endingRedFaults,
      0,
      "the Red ending completes every native operation: " .. table.concat(endingRedFaults, ",")
    )

    local published = publishedRecord(game)
    Assert.equal(
      published.gameStats.leagueWins,
      before.gameStats.leagueWins,
      "the Red ending counts no Johto League win"
    )
    Assert.equal(
      published.hallOfFame.total,
      before.hallOfFame.total,
      "the Red ending never advances the Johto record sequence"
    )
    Assert.equal(
      #published.hallOfFame.records,
      #before.hallOfFame.records,
      "the Red ending registers no Johto Hall of Fame record"
    )
    Assert.equal(routes.count, 1, "the Red ending still hands the host its main-menu route")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
