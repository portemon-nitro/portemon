-- The League ending's one transaction: everything the source's game-clear path
-- (src/game_clear.c::CallTask_GameClear and Task_GameClear) owns, expressed as
-- one atomic publication.
--
-- Source order, captured once in `begin`:
--   * `previouslyCleared` is read before any game-clear write, exactly like
--     `env->gameCleared = CheckGameClearFlag(varsFlags)`;
--   * `Location_SetToPlayerRoom` / `Location_SetToOutsidePlayerHome` supply the
--     committed post-clear destination and special spawn;
--   * SetFlag966, SetGameClearFlag and the profile clear flag follow, and the
--     League-win statistic is incremented only for a Johto (vsRed == 0) clear;
--   * the first clear also stamps the first-clear moment and reinitializes the
--     recorded history before the new record.
--
-- The native path writes two separate save blocks around the Hall of Fame
-- entry. This owner adapts that to the project's atomic save contract: one
-- complete candidate is staged once, published through GameSaveStore, and only
-- a successful publication installs the prepared live owners together. A failed
-- publication keeps the previous save, keeps the same staged candidate, and
-- exposes the source save-status retry; nothing before that point is installed.

local Errors = require("libs.errors.src.Errors")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local GameStats = require("libs.hgss.src.mons.GameStats")
local HallOfFameState = require("libs.hgss.src.save.HallOfFameState")
local SysInfoState = require("libs.hgss.src.save.SysInfoState")
local GameClearState = require("game.hgss.src.ending.GameClearState")

---@class GameClearCoordinator
---@field private _options table<string, unknown>
---@field private _state GameClearState?
---@field private _active boolean
---@field private _candidate table<string, unknown>?
---@field private _entry table<string, unknown>?
---@field private _recorded boolean?
---@field private _vsRed integer
---@field private _previouslyCleared boolean
local GameClearCoordinator = {}
GameClearCoordinator.__index = GameClearCoordinator

-- src/location_backup.c sLocation_PlayerRoom and sLocation_OutsidePlayerHome:
-- the room the clear commits the player to, and the special spawn outside the
-- player's home. The native -1 warp sentinel names no destination warp event.
GameClearCoordinator.PLAYER_ROOM = {
  mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
  localX = 6,
  localZ = 6,
  facing = "north",
}
GameClearCoordinator.OUTSIDE_PLAYER_HOME = {
  mapSymbol = "MAP_NEW_BARK",
  fieldX = 695,
  fieldZ = 397,
  facing = "north",
}
GameClearCoordinator.NO_WARP_ID = -1

-- The 163-owned flag writes: SetFlag966, SetGameClearFlag, the Call _01B4
-- clear and the ending's own FLAG_UNK_25F clear.
local FLAG_GAME_CLEAR = assert(FieldScriptSymbols.flagsByName.FLAG_GAME_CLEAR)
local FLAG_UNK_966 = assert(FieldScriptSymbols.flagsByName.FLAG_UNK_966)
local FLAG_UNK_998 = assert(FieldScriptSymbols.flagsByName.FLAG_UNK_998)
local FLAG_UNK_25F = assert(FieldScriptSymbols.flagsByName.FLAG_UNK_25F)

---@param options table<string, unknown>
---@return GameClearCoordinator
function GameClearCoordinator.new(options)
  assert(type(options) == "table", "the game-clear coordinator needs its collaborators")
  for _, name in ipairs({
    "capture",
    "publish",
    "setSaveStatus",
    "worldState",
    "monService",
    "detachedMonService",
    "gameStats",
    "hallOfFame",
    "sysInfo",
    "fieldTravel",
    "date",
    "locate",
  }) do
    assert(options[name] ~= nil, "the game-clear coordinator requires " .. name)
  end
  return setmetatable({
    _options = options,
    _state = nil,
    _active = false,
    _candidate = nil,
    _entry = nil,
    _previouslyCleared = false,
    _preparationFailure = nil,
  }, GameClearCoordinator)
end

---@return boolean
function GameClearCoordinator:isActive()
  return self._active
end

-- A live ending owns the field until it either publishes or the application
-- closes, so an ordinary capture must never describe its half-applied world.
---@return boolean
function GameClearCoordinator:isStableForSave()
  return not self._active
end

---@return string
function GameClearCoordinator:phase()
  return self._state ~= nil and self._state:phase() or "idle"
end

---@return table<string, unknown>
function GameClearCoordinator:status()
  if self._state == nil then
    local idle = { phase = "idle" }
    if self._preparationFailure ~= nil then
      idle.preparationFailure = self._preparationFailure
    end
    return idle
  end
  local status = self._state:status()
  status.hasCandidate = self._candidate ~= nil
  if self._preparationFailure ~= nil then
    status.preparationFailure = self._preparationFailure
  end
  return status
end

---@param mon table<string, unknown>
---@param displayName string the mon's own nickname or its species name
---@return table<string, unknown> the source's own recorded party member
local function recordMon(mon, displayName)
  local moves = {}
  for index = 1, 4 do
    local entry = mon.moves[index]
    moves[index] = entry ~= nil and entry.move or ""
  end
  assert(type(mon.origin) == "table", "a recorded party member carries its origin record")
  return {
    species = mon.species,
    level = assert(mon.level, "a recorded party member carries its level"),
    form = mon.form,
    personality = mon.personality,
    otId = mon.origin.trainerId,
    otName = mon.origin.trainerName,
    nickname = displayName,
    moves = moves,
  }
end

-- One detached Hall of Fame record for the party the clear registers: every
-- non-Egg member, by value, with the local clear date.
---@param monService table<string, unknown>
---@param date table<string, unknown>
---@return table<string, unknown>
function GameClearCoordinator.buildEntry(monService, date)
  local party = {}
  local catalog = monService:catalog()
  for slot0 = 0, monService:partyCount() - 1 do
    local mon = monService:partyMon(slot0)
    if mon.isEgg ~= true then
      local copy = {}
      for key, value in pairs(mon) do
        copy[key] = value
      end
      copy.level = monService:partyMonDerived(slot0).level
      -- The source records the nickname buffer, which already holds the
      -- species name for a mon the player never renamed.
      local displayName = mon.nickname or catalog:species(mon.species).name
      party[#party + 1] = recordMon(copy, displayName)
    end
  end
  return { date = { year = date.year, month = date.month, day = date.day }, party = party }
end

---@param mon table<string, unknown> live non-Egg party member
---@param catalog table<string, unknown>|nil live mon catalog
---@return table<string, unknown> resolved scene member
function GameClearCoordinator.sceneMember(mon, catalog)
  assert(type(mon) == "table" and type(mon.species) == "string", "a scene member names its species")
  local form = math.floor(tonumber(mon.form) or 0)
  local gender = "male"
  local owLarge = false
  local speciesId = nil
  if catalog ~= nil then
    local okSpecies, definition = pcall(function()
      return catalog:species(mon.species)
    end)
    if okSpecies and type(definition) == "table" then
      if type(definition.nativeId) == "number" then
        speciesId = definition.nativeId
      end
      local okGender, derived = pcall(function()
        local Personality = require("libs.mons.src.gen4.Personality")
        return Personality.gender(definition.genderRatio, mon.personality)
      end)
      if okGender and derived == "female" then
        gender = "female"
      end
    end
    local okFollower, follower = pcall(function()
      if type(catalog.followerSelection) == "function" then
        return catalog:followerSelection(mon)
      end
      return nil
    end)
    if okFollower and type(follower) == "table" then
      if gender == "female" and type(follower.female) == "table" then
        follower = follower.female
      end
      owLarge = follower.size ~= nil and follower.size ~= 0
    end
  end
  return {
    species = mon.species,
    crySpecies = speciesId,
    form = form,
    gender = gender,
    owLarge = owLarge,
  }
end

-- Begin the ending for one raw vsRed word. Exclusivity is the owner's own
-- invariant: a second ending cannot start while one owns the field.
---@param vsRed integer
function GameClearCoordinator:begin(vsRed)
  if self._active then
    Errors.raise("GAME_CLEAR_BUSY", "the League ending already owns the field", { phase = self:phase() })
  end
  assert(
    type(vsRed) == "number" and vsRed % 1 == 0 and vsRed >= 0 and vsRed <= 0xFFFF,
    "the ending takes the source's raw vsRed halfword"
  )
  self._preparationFailure = nil
  self._candidate = nil
  self._entry = nil
  self._stagedDate = nil
  local options = self._options
  -- The ending demands its own generated bundle: the registration, showcase and
  -- credit-roll sections. The demand retries every fixed tick until the bundle
  -- is admitted; congratulations and the roll hold their phases meanwhile.
  -- A terminal demand failure attributes immediately instead of hanging a
  -- cold cache as pending.
  if options.requestAssets ~= nil then
    local _, requestFailure = options.requestAssets("required")
    if requestFailure ~= nil then
      self._preparationFailure = "League ending demand failed: " .. tostring(requestFailure)
    end
  end
  if options.loadPresentation ~= nil then
    local state = options.presentation
    if state ~= nil and type(state.prepare) == "function" then
      local loadFailure = options.loadPresentation()
      if loadFailure ~= nil and self._preparationFailure == nil then
        self._preparationFailure = tostring(loadFailure)
      end
    end
  end
  -- The recorded non-Egg party behind the registration reveal, snapshotted
  -- by value before any 163-owned write like env->gameCleared. Gender and
  -- follower size resolve through the live catalog so the scene and its
  -- draw never guess them; the bundle picture tracks resolve lazily in the
  -- state once the presentation is ready.
  local sceneParty = {}
  local monService = options.monService
  if monService ~= nil and type(monService.partyCount) == "function" and type(monService.partyMon) == "function" then
    local catalog = nil
    if type(monService.catalog) == "function" then
      local okCatalog, resolved = pcall(monService.catalog, monService)
      if okCatalog and type(resolved) == "table" then
        catalog = resolved
      end
    end
    local count = monService:partyCount()
    for slot0 = 0, count - 1 do
      local mon = monService:partyMon(slot0)
      if type(mon) == "table" and mon.isEgg ~= true and type(mon.species) == "string" then
        sceneParty[#sceneParty + 1] = GameClearCoordinator.sceneMember(mon, catalog)
      end
    end
  end
  -- Captured before any 163-owned write, like env->gameCleared.
  self._previouslyCleared = options.worldState:isFlagSet(FLAG_GAME_CLEAR) == true
  self._state = GameClearState.new({
    vsRed = vsRed,
    previouslyCleared = self._previouslyCleared,
    presentation = options.presentation,
    audio = options.audio,
    sceneParty = sceneParty,
    headless = options.headless == true,
  })
  self._candidate = nil
  self._entry = nil
  self._stagedDate = nil
  self._vsRed = vsRed
  self._active = true
end

-- One staged candidate for the whole ending: built once, reused by every retry
-- so a retried publication never records a second clear, redraws the stream or
-- advances a counter.
---@return table<string, unknown>|nil, string|nil
function GameClearCoordinator:_stageCandidate()
  if self._candidate ~= nil then
    return self._candidate, nil
  end
  local options = self._options
  local base, captureErr = options.capture()
  if base == nil then
    return nil, tostring(captureErr or "the field is not settled")
  end
  local date = options.date()
  self._stagedDate = { year = date.year, month = date.month, day = date.day }
  local room = GameClearCoordinator.PLAYER_ROOM
  local destination = options.locate(room.mapSymbol, room.localX, room.localZ, room.facing)
  local outsideHome = GameClearCoordinator.OUTSIDE_PLAYER_HOME
  local nonRed = self._vsRed == 0

  -- The 163-owned flag writes.
  local flags = assert(base.world.flags, "a captured world carries its flags")
  flags[FLAG_GAME_CLEAR] = true
  flags[FLAG_UNK_966] = true
  if not self._previouslyCleared then
    flags[FLAG_UNK_998] = true
  end
  flags[FLAG_UNK_25F] = nil

  -- The committed post-clear travel: the room destination and the
  -- outside-home special spawn, with the retained last-heal spawn.
  local travel = assert(base.fieldTravel, "a captured save carries its travel state")
  travel.dynamicWarp = {
    map = room.mapSymbol,
    fieldX = room.localX,
    fieldZ = room.localZ,
    warpId = GameClearCoordinator.NO_WARP_ID,
    direction = room.facing,
  }
  travel.specialSpawn = {
    map = outsideHome.mapSymbol,
    fieldX = outsideHome.fieldX,
    fieldZ = outsideHome.fieldZ,
    warpId = GameClearCoordinator.NO_WARP_ID,
    direction = outsideHome.facing,
  }

  -- The destination itself is the committed position Continue restores.
  base.mapId = destination.mapId
  base.fieldX = destination.fieldX
  base.fieldZ = destination.fieldZ
  base.worldY = destination.worldY
  base.surfaceId = destination.surfaceId
  base.terrainDependencyHash = destination.terrainDependencyHash
  base.facing = destination.facing

  -- The source heals the party before the save block.
  local detached = options.detachedMonService(assert(base.mons, "a captured save carries its party bucket"))
  detached:healParty()
  base.mons = detached:capture()

  if not self._previouslyCleared then
    local info = SysInfoState.new(base.sysInfo)
    info:setFirstClearAt(self._stagedDate)
    base.sysInfo = info:capture()
  end

  if nonRed then
    local stats = assert(base.gameStats, "a captured save carries its statistics bucket")
    assert(type(stats.leagueWins) == "number", "current statistics carry the League-win total")
    stats.leagueWins = math.min(GameStats.LEAGUE_WINS_CAP, stats.leagueWins + 1)
    self._entry = GameClearCoordinator.buildEntry(options.monService, self._stagedDate)
    local history = HallOfFameState.restore(base.hallOfFame)
    if not self._previouslyCleared then
      history:reset()
    end
    self._recorded = history:recordClear(self._entry)
    base.hallOfFame = history:capture()
  end

  self._candidate = base
  return base, nil
end

-- Install the prepared live owners after the successful publication, without
-- any callback between them: every owner applies exactly the state the
-- published candidate carries.
function GameClearCoordinator:_install()
  local options = self._options
  local world = options.worldState
  world:setFlag(FLAG_GAME_CLEAR)
  world:setFlag(FLAG_UNK_966)
  if not self._previouslyCleared then
    world:setFlag(FLAG_UNK_998)
  end
  world:clearFlag(FLAG_UNK_25F)
  local room = GameClearCoordinator.PLAYER_ROOM
  local outsideHome = GameClearCoordinator.OUTSIDE_PLAYER_HOME
  options.fieldTravel:setDynamicWarp({
    map = room.mapSymbol,
    fieldX = room.localX,
    fieldZ = room.localZ,
    warpId = GameClearCoordinator.NO_WARP_ID,
    direction = room.facing,
  })
  options.fieldTravel:setSpecialSpawn({
    map = outsideHome.mapSymbol,
    fieldX = outsideHome.fieldX,
    fieldZ = outsideHome.fieldZ,
    warpId = GameClearCoordinator.NO_WARP_ID,
    direction = outsideHome.facing,
  })
  if not self._previouslyCleared then
    assert(self._stagedDate ~= nil, "a staged candidate carries its first-clear stamp")
    options.sysInfo:setFirstClearAt(self._stagedDate)
  end
  if self._vsRed == 0 then
    options.gameStats:awardLeagueWin()
    if not self._previouslyCleared then
      options.hallOfFame:reset()
    end
    if self._recorded == true then
      assert(self._entry ~= nil, "a recorded clear carries its entry")
      assert(options.hallOfFame:recordClear(self._entry), "the live history records the published clear")
    end
  end
  options.monService:healParty()
end

-- Attempt the one publication. Returns whether the published candidate is now
-- the durable save; the failure text is the caller's save-status message.
---@param candidate table<string, unknown>
---@return boolean ok, string|nil reason
function GameClearCoordinator:_publish(candidate)
  local ok, result = pcall(self._options.publish, candidate)
  if ok then
    return true, nil
  end
  return false, tostring(Errors.is(result) and result.message or result)
end

-- One fixed tick of the ending. The state machine owns the phases, the
-- transaction owns the write, and only a successful publication advances the
-- sequence into the credits.
---@param input table<string, unknown>|nil the tick's field input snapshot
---@return string "idle"|"running"|"complete"
function GameClearCoordinator:updateFixed(input)
  if not self._active then
    return "idle"
  end
  if self._preparationFailure ~= nil then
    error(self._preparationFailure, 0)
  end
  -- A cold bundle retries every fixed tick: the demand and the admission
  -- ride the same tick the state steps, so congratulations holds until the
  -- sections are prepared instead of playing with no surfaces. A terminal
  -- preparation failure attributes and raises instead of stranding the
  -- mandatory story sequence in pending; the receipt is kept so a known
  -- failure is never retried as a cold cache.
  local options = self._options
  if options.requestAssets ~= nil then
    local _, requestFailure = options.requestAssets("required")
    if requestFailure ~= nil then
      self._preparationFailure = "League ending demand failed: " .. tostring(requestFailure)
      error(self._preparationFailure, 0)
    end
  end
  if options.loadPresentation ~= nil then
    local presentation = options.presentation
    if presentation ~= nil and type(presentation.prepare) == "function" and not presentation:isReady() then
      local loadFailure = options.loadPresentation()
      if loadFailure ~= nil then
        self._preparationFailure = tostring(loadFailure)
        error(self._preparationFailure, 0)
      end
    end
  end
  local state = assert(self._state, "an active ending owns its state machine")
  local action = state:step(input)
  if action == "publish" then
    local candidate, reason = self:_stageCandidate()
    if candidate == nil then
      self._options.setSaveStatus("Save failed: " .. tostring(reason))
      state:saveFailed()
      return "running"
    end
    local ok, publishErr = self:_publish(candidate)
    if not ok then
      self._options.setSaveStatus("Save failed: " .. tostring(publishErr))
      state:saveFailed()
      return "running"
    end
    self:_install()
    self._options.setSaveStatus(nil)
    state:saveSucceeded()
    return "running"
  end
  if action == "complete" then
    return "complete"
  end
  return "running"
end

-- Marks the saving surface as genuinely presented so the state cannot
-- publish on a fixed tick that no draw ever displayed.
function GameClearCoordinator:noteSavingPresented()
  if self._state ~= nil and type(self._state.noteSavingPresented) == "function" then
    self._state:noteSavingPresented()
  end
end

-- Release the ending. The published save (if any) stays durable; an ending the
-- application closes before its publication leaves the previous save untouched.
---@param _ string?
function GameClearCoordinator:cancel(_)
  if not self._active then
    return
  end
  self._active = false
  self._state = nil
  self._candidate = nil
  self._entry = nil
  self._stagedDate = nil
  self._preparationFailure = nil
end

-- The ending released the host route: drop the staged work, never the save.
function GameClearCoordinator:finish()
  self._active = false
  self._state = nil
  self._candidate = nil
  self._entry = nil
  self._stagedDate = nil
  self._preparationFailure = nil
end

return GameClearCoordinator
