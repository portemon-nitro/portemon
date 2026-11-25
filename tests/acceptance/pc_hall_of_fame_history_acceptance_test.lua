-- The source PC's Hall of Fame history through the production field
-- composition. A cleared save's PC root offers the source's own Hall of Fame
-- entry; its validity query answers in the same tick, the blocking showcase
-- child owns the field until it closes, and the source overlay returns to the
-- field afterwards. An invalid history never opens a child and takes the
-- source warning path instead. A save envelope published before this slice
-- keeps every prior owner and never invents the first-clear date it could not
-- have stored. Only audio, fade and clock host boundaries are recorded - the
-- PC host, map, scripts, save store and history owner stay production-owned,
-- and the render trap stays active throughout.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldStatePresentationFixture = require("tests.support.FieldStatePresentationFixture")
local LuaWriter = require("libs.codec.src.LuaWriter")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "audio-bank:702",
      "message-bank:40",
      "message-bank:191",
      "map-data:64",
      "map:64",
      "map-data:69",
      "map:69",
      "map-data:306",
      "map:306",
      "message-bank:528",
      "pc:global",
    },
    tags = { "field", "pc", "ending", "save" },
  },
  tests = {},
}

local POKECENTER = "MAP_CHERRYGROVE_POKECENTER_1F"
-- The migrated save is published from the Hall of Fame room the ending runs in.
local HOF_ROOM = "MAP_POKEMON_LEAGUE_HALL_OF_FAME"
local PC_STANDARD_SCRIPT = "common.pokecenter_pc"
-- The source Center's own south entrance spawn.
local CENTER_SPAWN = { fieldX = 8, fieldZ = 13, facing = "north" }

-- The retired envelope this slice migrates from and the state every prior
-- owner keeps across it.
local LEGACY_GAME_SCHEMA = "g4-game-save-v15"
local LEGACY_SYS_INFO_SCHEMA = "hgss-sys-info-v1"
local LEGACY_GAME_STATS_SCHEMA = "hgss-stats-v2"
local LEGACY_GAME_STATS_STATE_VERSION = 2

local HOF_BUCKET_SCHEMA = "hgss-hall-of-fame-v1"

local FLAG_GAME_CLEAR = assert(FieldScriptSymbols.flagsByName.FLAG_GAME_CLEAR)
local FLAG_HIDE_COMM_CLUB_CLOSED_LADIES = FieldScriptSymbols.flagsByName.FLAG_HIDE_COMM_CLUB_CLOSED_LADIES
local VAR_SPECIAL_RESULT = assert(FieldScriptSymbols.variablesByName.VAR_SPECIAL_RESULT)

-- TILE_BEHAVIOR_PC has source value 131.
local SOURCE_PC_METATILE_BEHAVIOR = 131
-- The source PC root menu's own Hall of Fame entry result.
local HOF_MENU_VALUE = 2
-- The source PC's warning for a history it cannot read (msg_0040_00094).
local INVALID_HISTORY_MESSAGE = 94

---@param value unknown
---@return unknown
local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, item in pairs(value) do
    copy[key] = deepCopy(item)
  end
  return copy
end

-- The one recorded clear the source showcase reads: newest first, a whole
-- party team with its own local date.
---@param species string
---@param level integer
---@return table
local function historyRecord(species, level)
  return {
    date = { year = 2000, month = 1, day = 1 },
    party = {
      {
        species = species,
        level = level,
        form = 0,
        personality = 1,
        otId = 1,
        otName = "GOLD",
        nickname = species,
        moves = { "FLAMETHROWER", "EMBER", "TACKLE", "GROWL" },
      },
    },
  }
end

---@param records table[]
---@param total integer
---@return table
local function historyBucket(records, total)
  return { schema = HOF_BUCKET_SCHEMA, stateVersion = 1, total = total, records = records }
end

-- Captures the journey's save from a settled field: a capture needs every
-- autonomous actor settled, so the scenario advances the fixed tick until the
-- production save entry accepts the field.
---@param game table acceptance game
---@param label string capture context
---@return table the captured record
local function settledCapture(game, label)
  local lastError = nil
  for _ = 1, 480 do
    local ok, record = pcall(game.runtime.captureGameSave, game.runtime)
    if ok and record ~= nil then
      return record
    end
    lastError = ok and "capture returned no record" or tostring(record)
    game:step()
  end
  error("the settled field never accepted its save: " .. label .. "; last failure: " .. tostring(lastError), 0)
end

-- Publishes the journey's own save with the given recorded history and returns
-- the record the production store loads back.
---@param game table acceptance game
---@param bucket table the Hall of Fame bucket to persist
---@return table loaded record
local function publishHistory(game, bucket)
  local store = assert(game.runtime.saveStore, "the field runtime owns its save store")
  local record = settledCapture(game, "the Hall of Fame history")
  record.hallOfFame = bucket
  Assert.isTrue(store:publishFirst(record), "the history publishes through the production store")
  local saveId = assert(record.saveId, "a captured save names its identity")
  return assert(store:load(saveId), "the published save loads through the production store")
end

---@param options table
---@return AcceptanceHarness
local function harnessWith(options)
  local harness = AcceptanceHarness.new()
  local createGame = harness.gameFactory
  harness.gameFactory = function(versionId, map)
    local game = createGame(versionId, map)
    local worldState = FieldEventState.new()
    worldState:setFlag(FLAG_HIDE_COMM_CLUB_CLOSED_LADIES)
    if options.cleared then
      worldState:setFlag(FLAG_GAME_CLEAR)
    end
    game.location = {
      mapSymbol = options.mapSymbol or POKECENTER,
      fieldX = options.fieldX or CENTER_SPAWN.fieldX,
      fieldZ = options.fieldZ or CENTER_SPAWN.fieldZ,
      facing = options.facing or CENTER_SPAWN.facing,
    }
    game.worldState = worldState
    if options.hallOfFame ~= nil then
      game.hallOfFame = options.hallOfFame
    end
    if options.holdHofScene then
      worldState:setVar(assert(FieldScriptSymbols.variablesByName.VAR_TEMP_x4001), 1)
    end
    return game
  end
  return harness
end

---@param harness AcceptanceHarness
---@param save table|nil the loaded record to continue from
---@param mapSymbol string? field map to boot
---@return table game
local function bootCenter(harness, save, mapSymbol)
  return harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = mapSymbol or POKECENTER,
    save = save ~= nil and "continue" or "fresh",
    fieldOptions = {
      recordingScriptHosts = true,
      audioHost = "recording",
      derivedAssets = FieldStatePresentationFixture.iconHost().derivedAssets,
    },
  })
end

local function pressAction(game)
  game.runtime:pressAction()
  game:step()
  game.runtime:releaseAction()
end

local function pressCancel(game)
  game.runtime:pressCancel()
  game:step()
  game.runtime:releaseCancel()
end

local function activeMenuTask(game)
  for _, task in ipairs(game.runtime.scripts.scheduler:tasks()) do
    if task.taskType == "menu" then
      return task
    end
  end
  return nil
end

local function selectMenuValue(game, value)
  local task = assert(activeMenuTask(game), "the source PC menu is active")
  local targetIndex
  for index, item in ipairs(task.state.menuDefinition.items) do
    if item.value == value then
      targetIndex = index - 1
      break
    end
  end
  assert(targetIndex ~= nil, "the current source PC menu contains the requested entry")
  for _ = 1, #task.state.menuDefinition.items do
    local selectedIndex = task.state.selectedIndex
    if selectedIndex == targetIndex then
      break
    end
    game:step({ direction = selectedIndex < targetIndex and "south" or "north" })
    task = assert(activeMenuTask(game), "the source menu stays active while navigating")
  end
  Assert.equal(task.state.selectedIndex, targetIndex, "field input focuses the requested source menu entry")
  pressAction(game)
end

-- Faults the generated source PC shell published, with the source command
-- each one could not complete.
---@param game table acceptance game
---@return string[]
local function shellFaults(game)
  local faults = {}
  for _, record in ipairs(game:recordsForScript(PC_STANDARD_SCRIPT, "script.error")) do
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

---@param game table acceptance game
---@param what string assertion context
local function assertShellClean(game, what)
  local faults = shellFaults(game)
  Assert.equal(#faults, 0, what .. " completes every native operation: " .. table.concat(faults, ","))
end

-- Steps the fixed tick without touching source input: the shell's own
-- post-selection path has no dialogue to answer, and pressing there would
-- activate a menu the scenario never asked for.
---@param game table acceptance game
---@param label string boundary description
---@param predicate fun(snapshot: table): boolean
---@param maxTicks integer
---@return table snapshot
local function waitForShell(game, label, predicate, maxTicks)
  for _ = 1, maxTicks do
    local snapshot = game:snapshot()
    if predicate(snapshot) then
      return snapshot
    end
    local faults = shellFaults(game)
    if #faults > 0 then
      error("the source PC shell could not reach " .. label .. ": " .. table.concat(faults, ","), 0)
    end
    game:step()
  end
  error(
    "the source PC shell never reached "
      .. label
      .. "; locked="
      .. tostring(game:snapshot().fieldLocked)
      .. ", pcChild="
      .. tostring(game.runtime.pcApplicationHost and game.runtime.pcApplicationHost:isActive())
      .. ", modal="
      .. tostring(game:snapshot().dialogue.modal)
      .. ", tick="
      .. tostring(game:snapshot().tick),
    0
  )
end

local function advanceSourceUntil(game, label, predicate, maxTicks)
  for _ = 1, maxTicks do
    local snapshot = game:snapshot()
    if predicate(snapshot) then
      return snapshot
    end
    local faults = shellFaults(game)
    if #faults > 0 then
      error("the source PC shell could not reach " .. label .. ": " .. table.concat(faults, ","), 0)
    end
    if snapshot.dialogue.modal then
      pressAction(game)
    else
      game:step()
    end
  end
  error(
    "timed out waiting for "
      .. label
      .. "; locked="
      .. tostring(game:snapshot().fieldLocked)
      .. ", foreground="
      .. tostring(game:snapshot().foregroundScript)
      .. ", pcChild="
      .. tostring(game.runtime.pcApplicationHost and game.runtime.pcApplicationHost:isActive())
      .. ", tick="
      .. tostring(game:snapshot().tick),
    0
  )
end

local function pcTile(game)
  local map = game.runtime.runtimeMap
  local origin = assert(map.coordinateOrigin, "the composed Center has a field coordinate origin")
  for localZ = 0, 31 do
    for localX = 0, 31 do
      if map.collision:containsLocal(localX, localZ) then
        local cell = map.collision:getLocal(localX, localZ)
        if cell.behavior == SOURCE_PC_METATILE_BEHAVIOR then
          local standX, standZ = localX, localZ + 1
          if
            map.collision:containsLocal(standX, standZ)
            and not map.collision:getLocal(standX, standZ).blocked
          then
            return {
              fieldX = origin.x + localX,
              fieldZ = origin.z + localZ,
              stand = { fieldX = origin.x + standX, fieldZ = origin.z + standZ },
            }
          end
        end
      end
    end
  end
  return nil
end

local function openSourcePcRoot(game)
  local pc = assert(pcTile(game), "the generated Center has an accessible PC tile")
  game:moveTo(pc.stand)
  game:face("north")
  game:pressAction()
  Assert.equal(game:interaction().scriptId, PC_STANDARD_SCRIPT, "the source PC metatile starts its canonical shell")
  advanceSourceUntil(game, "the source PC root menu", function()
    return activeMenuTask(game) ~= nil
  end, 240)
end

local function exitSourcePc(game)
  local task = assert(activeMenuTask(game), "the generated source PC has an active menu")
  local logoff
  for _, item in ipairs(task.state.menuDefinition.items) do
    if item.message and item.message.id == 66 then
      logoff = item
      break
    end
  end
  assert(logoff ~= nil, "the cleared source PC root exposes its logoff entry")
  selectMenuValue(game, logoff.value)
  advanceSourceUntil(game, "the source PC shell releases field input", function(snapshot)
    return not snapshot.fieldLocked and not (snapshot.menu and snapshot.menu.modal)
  end, 480)
end

-- Selects the source PC's own Hall of Fame entry and returns what the shell did
-- next: the status word its query published and whether the showcase child
-- took the field. Source prompt windows are answered; the warning window and
-- the opened child are the boundaries this returns on.
---@param game table acceptance game
---@return { host: table, child: boolean, status: integer, warned: boolean }
local function enterHallOfFame(game)
  local host = assert(game.runtime.pcApplicationHost, "the production field owns the PC application host")
  selectMenuValue(game, HOF_MENU_VALUE)
  for _ = 1, 480 do
    assertShellClean(game, "the source PC shell")
    local snapshot = game:snapshot()
    local status = game.runtime.scripts.worldState:getVar(VAR_SPECIAL_RESULT)
    if host:isActive() then
      return { host = host, child = true, status = status, warned = false }
    end
    if snapshot.dialogue.modal and snapshot.dialogue.messageId == INVALID_HISTORY_MESSAGE then
      return { host = host, child = false, status = status, warned = true }
    end
    if snapshot.dialogue.modal then
      pressAction(game)
    else
      game:step()
    end
  end
  error("the source PC shell never answered its own Hall of Fame entry", 0)
end

-- The source PC's Hall of Fame entry answers its validity in the same tick, and
-- only a readable history opens the blocking showcase child: the child keeps the
-- field until it closes, then the source overlay returns to the shell. An
-- unreadable history takes the source warning path and opens no child at all.
function T.tests.source_pc_hall_of_fame_entry_blocks_the_script_until_the_showcase_closes()
  local records = { historyRecord("TYPHLOSION", 60) }
  local readable = bootCenter(harnessWith({ cleared = true, hallOfFame = historyBucket(records, 1) }))
  local ok, err = xpcall(function()
    readable:waitForFieldEntry()
    readable:waitForFieldReady(480)
    openSourcePcRoot(readable)

    local entry = enterHallOfFame(readable)
    Assert.equal(
      entry.status,
      0,
      "the validity query answers zero for a readable history in the same tick (observed "
        .. tostring(entry.status)
        .. ")"
    )
    Assert.isTrue(entry.child, "a readable history opens the source showcase child")
    Assert.equal(
      entry.host:status().app,
      "hallOfFame",
      "the source Hall of Fame entry opens the shared showcase child"
    )
    Assert.isTrue(readable.runtime.screenFade:isOpaque(), "the source overlay opens behind its own screen fade")

    -- The child owns the field: advancing never returns to the PC shell while
    -- it lives, and the field never consumes its input.
    local before = readable:snapshot()
    for _ = 1, 60 do
      readable:step()
    end
    Assert.isTrue(entry.host:isActive(), "the showcase child keeps owning the field until it closes")
    Assert.equal(activeMenuTask(readable), nil, "the source shell waits for the showcase child")
    Assert.equal(
      readable:snapshot().player.fieldX,
      before.player.fieldX,
      "the showcase consumes input instead of the field"
    )
    Assert.equal(
      readable:snapshot().player.fieldZ,
      before.player.fieldZ,
      "the showcase consumes input instead of the field"
    )

    -- Closing the child with the source cancel input returns the script to the
    -- field and back to the shell.
    pressCancel(readable)
    waitForShell(readable, "the closed showcase", function()
      return not entry.host:isActive()
    end, 480)
    Assert.isFalse(entry.host:isActive(), "the source cancel input closes the showcase child")
    waitForShell(readable, "the source shell return", function()
      return activeMenuTask(readable) ~= nil
    end, 960)
    exitSourcePc(readable)
    Assert.equal(readable:renderAttempts(), 0, "the Hall of Fame PC acceptance stops before GPU rendering")
  end, debug.traceback)
  readable:close()
  if not ok then
    error(err, 0)
  end

  -- The same entry against a history the save cannot serve.
  local unreadable = bootCenter(harnessWith({ cleared = true, hallOfFame = historyBucket({}, 1) }))
  local unreadableOk, unreadableErr = xpcall(function()
    unreadable:waitForFieldEntry()
    unreadable:waitForFieldReady(480)
    openSourcePcRoot(unreadable)
    local entry = enterHallOfFame(unreadable)
    Assert.equal(
      entry.status,
      1,
      "the validity query answers one for an unreadable history in the same tick (observed "
        .. tostring(entry.status)
        .. ")"
    )
    Assert.isFalse(entry.child, "an unreadable history never opens a blank showcase")
    Assert.isTrue(entry.warned, "the source shell warns instead of opening a showcase")
  end, debug.traceback)
  unreadable:close()
  if not unreadableOk then
    error(unreadableErr, 0)
  end
end

-- The save envelope this slice inherits keeps every prior owner and never
-- invents the first-clear date an already-cleared save could not have stored.
function T.tests.previous_save_envelope_keeps_prior_owners_and_an_unknown_first_clear_date()
  local game = bootCenter(harnessWith({
    cleared = true,
    mapSymbol = HOF_ROOM,
    fieldX = 6,
    fieldZ = 22,
    facing = "north",
    holdHofScene = true,
  }), nil, HOF_ROOM)
  local loaded
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    game:waitForFieldReady(480)
    local store = assert(game.runtime.saveStore, "the field runtime owns its save store")
    local captured = settledCapture(game, "the inherited envelope")
    local saveId = assert(captured.saveId, "a captured save names its identity")
    Assert.isTrue(store:publishFirst(captured), "the journey publishes its first save")

    -- Rewrite the published payload as the envelope this slice inherits: every
    -- bucket is one the journey really captured, only the envelope and the two
    -- owned buckets belong to the earlier release.
    local legacy = deepCopy(captured)
    legacy.schema = LEGACY_GAME_SCHEMA
    legacy.sysInfo = { schema = LEGACY_SYS_INFO_SCHEMA, mysteryGiftActive = false }
    legacy.gameStats.schema = LEGACY_GAME_STATS_SCHEMA
    legacy.gameStats.stateVersion = LEGACY_GAME_STATS_STATE_VERSION
    -- The earlier stats bucket predates the League-win counter, the Day Care
    -- counters, and the Battle Point counters it never had.
    legacy.gameStats.leagueWins = nil
    legacy.gameStats.daycareDeposits = nil
    legacy.gameStats.eggsHatched = nil
    legacy.gameStats.battlePointsReceived = nil
    legacy.gameStats.battlePointsSpent = nil
    legacy.hallOfFame = nil
    -- The saved coin balance arrives with the later envelope, so this
    -- predecessor carries no coin field.
    legacy.playerData.profile.coins = nil
    -- The earlier release never wrote a Day Care bucket or a Battle Point
    -- wallet.
    legacy.daycare = nil
    legacy.battlePoints = nil
    local payloadDirectory = game.saveNamespace .. "/global/games"
    assert(love.filesystem.createDirectory(payloadDirectory), "the acceptance save root holds its payload directory")
    assert(
      love.filesystem.write(payloadDirectory .. "/" .. saveId .. ".lua", LuaWriter.encode(legacy)),
      "the inherited payload is written"
    )
    loaded = assert(store:load(saveId), "the production store loads the inherited save")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end

  local resumed = AcceptanceHarness.new({
    gameFactory = function()
      return loaded
    end,
  }):boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = HOF_ROOM,
    save = "continue",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  local resumedOk, resumedErr = xpcall(function()
    resumed:waitForFieldEntry()
    local restored = settledCapture(resumed, "the migrated journey")
    Assert.equal(restored.schema, "g4-game-save-v19", "loading an inherited save republishes the current envelope")
    Assert.equal(
      restored.sysInfo.firstClearAt,
      false,
      "a cleared save that never stored a first-clear moment keeps it unknown instead of inventing one"
    )
    Assert.equal(restored.sysInfo.mysteryGiftActive, false, "the prior system-info flag survives the migration")
    Assert.equal(restored.gameStats.leagueWins, 0, "the League-win counter starts from the value the save had")
    Assert.equal(restored.gameStats.stateVersion, 5, "the game-stats bucket moves to its current state version")
    Assert.equal(restored.hallOfFame.schema, HOF_BUCKET_SCHEMA, "the migrated save owns a current history bucket")
    Assert.equal(restored.hallOfFame.total, 0, "the migration invents no recorded clear")
    Assert.equal(#restored.hallOfFame.records, 0, "the migration invents no retained record")
    Assert.deepEqual(
      restored.gymmick,
      loaded.gymmick,
      "the migration keeps the gym mechanism state the save carried"
    )
    Assert.deepEqual(
      restored.encounters,
      loaded.encounters,
      "the migration keeps the roamer and encounter state the save carried"
    )
    Assert.equal(restored.playerData.profile.name, loaded.playerData.profile.name, "the migration keeps the profile")
    Assert.equal(restored.saveId, loaded.saveId, "the migration keeps the save identity")
    Assert.isTrue(
      resumed.runtime.scripts.worldState:isFlagSet(FLAG_GAME_CLEAR),
      "the migrated save keeps the game-clear flag it carried"
    )
  end, debug.traceback)
  resumed:close()
  if not resumedOk then
    error(resumedErr, 0)
  end
end

return T
