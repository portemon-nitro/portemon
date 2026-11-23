-- Authoritative live game stats: the single durable owner of the unique
-- species counter, the trainer-card score, and the League-win total,
-- independent of present party or dex history. Retail increments the unique counter blindly on
-- every completed evolution (EVO_STATE_REGISTER + shed side product,
-- unconditional) and scores a receipt iff the species is not yet
-- dex-caught (GameStats_IncSpeciesCaught). The owner mirrors both: each
-- staged unique_caught observation adds one to the counter even for an
-- already-registered species, while the counted set records every
-- species that has ever appeared in a published batch as the freshness
-- authority for headless seams without dex access. describe projects one
-- detached registration record from an admitted mon for capture and
-- evolution producers; changes stage as one-use revision-based candidates
-- and publish exactly once through the same prepared-candidate
-- convention as the party, bag, and dex owners.
--
-- Retail sources (tmp/refs/pokeheartgold): evolution publishes its
-- unique increment plus register score on EVO_STATE_REGISTER
-- (src/evolution_scene.c:729-740) and again for the shed side product
-- in ApplyEvolutionEffects (src/evolution_scene.c:1052-1054); captures
-- register through GameStats_IncSpeciesCaught, which awards the
-- register score only while the species is still uncaught
-- (src/game_stats.c:385-389, via UpdatePokedexWithReceivedSpecies in
-- src/update_dex_received.c:13-21). The register event
-- SCORE_EVENT_REGISTER_SPECIES_CAUGHT 21 carries 20 points via
-- sScoreMods[21] (src/game_stats.c) and the total caps at 99999999 in
-- GameStats_AddScore (src/game_stats.c:371-379). Scripted score events
-- enter through ScrCmd_AddSpecialGameStat (src/scrcmd_c.c), whose operand
-- selects a weight from that same sScoreMods table. The source's
-- GAME_STAT_LEAGUE_WINS counter is incremented once by the League ending
-- (src/game_clear.c::CallTask_GameClear) and persists beside the score.

local Errors = require("libs.errors.src.Errors")

---@class GameStats
---@field private _allowed table<string, boolean>
---@field private _counted table<string, boolean> species ever staged in a published batch
---@field private _unique integer blind unique-registration total
---@field private _score integer
---@field private _mailWritten integer written-Mail total
---@field private _stepsBiked integer steps taken on the Bicycle
---@field private _leagueWins integer recorded League wins
---@field private _revision integer
local GameStats = {}
GameStats.__index = GameStats

-- Semantic score event behind the register observation. Retail names it
-- SCORE_EVENT_REGISTER_SPECIES_CAUGHT 21
-- (include/constants/game_stats.h:87); the numeric id never crosses this
-- seam.
GameStats.SCORE_EVENT_REGISTER_SPECIES_CAUGHT = "register_species_caught"

-- Authoritative points per score event. The register entry grounds in
-- sScoreMods[21] = 20 (src/game_stats.c); callers assert their staged
-- points and the owner verifies them, so no producer can invent a value.
GameStats.SCORE_POINTS = {
  register_species_caught = 20,
}

-- Retail score ceiling enforced by GameStats_AddScore
-- (src/game_stats.c:371-379). Unique registrations need no ceiling: the
-- admitted species set bounds them. The written-Mail counter caps at
-- 999999 (src/game_stats.c:276-287).
GameStats.SCORE_CAP = 99999999
GameStats.MAIL_WRITTEN_CAP = 999999
-- GAME_STAT_STEPS_BIKED saturates at the extra-wide word ceiling.
GameStats.STEPS_BIKED_CAP = 999999999

-- GameStats_Inc caps every u16 statistic at GAME_STAT_MAX 9999
-- (src/game_stats.c).
GameStats.LEAGUE_WINS_CAP = 9999

-- The source's sScoreMods table (src/game_stats.c), indexed by the
-- ScrCmd_AddSpecialGameStat operand. It stays private: the score an event
-- awards is the owner's business, so no producer or script supplies points.
local SCRIPT_SCORE_MODS = {
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  2,
  2,
  2,
  2,
  3,
  3,
  7,
  7,
  7,
  10,
  10,
  11,
  11,
  11,
  20,
  30,
  35,
  40,
  500,
  10000,
  7,
  7,
  7,
  7,
  1000,
  11,
  20,
  10,
  15,
  11,
  11,
  10,
  10,
}

-- The table above is a 0-based copy of the source's 40 events; a drifted
-- entry count would silently renumber every later weight.
assert(#SCRIPT_SCORE_MODS == 40, "the source score table has 40 events")

-- One source script score event index into the private weight table.
---@param value unknown
---@return integer|nil eventId
local function checkScriptScoreEvent(value)
  if type(value) ~= "number" or value % 1 ~= 0 then
    return nil
  end
  if SCRIPT_SCORE_MODS[value + 1] == nil then
    return nil
  end
  return value
end

---@param message string
---@param context table<string, unknown>
local function fail(message, context)
  Errors.raise("GAME_STATS_INVALID", message, context)
end

---@param species unknown
---@return table<string, boolean>
local function checkSpeciesSet(species)
  if type(species) ~= "table" then
    fail("game stats require a resolved species set", {})
  end
  assert(type(species) == "table", "game stats read their species set")
  local allowed = {}
  for key, known in pairs(species) do
    if type(key) ~= "string" or key == "" or known ~= true then
      fail("game stats species must map keys to true", { species = key })
    end
    allowed[key] = true
  end
  if next(allowed) == nil then
    fail("game stats require a non-empty species set", {})
  end
  return allowed
end

---@param allowed table<string, boolean>
---@param species unknown
---@return string
local function checkKey(allowed, species)
  if type(species) ~= "string" or allowed[species] ~= true then
    fail("game stats name an unknown species", { species = species })
  end
  return species
end

---@param value unknown
---@param what string
local function checkDenseList(value, what)
  if type(value) ~= "table" then
    fail("game stats " .. what .. " must be an array", {})
  end
  assert(type(value) == "table", "game stats read their staged arrays")
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
      fail("game stats " .. what .. " must be a dense array", {})
    end
    count = count + 1
  end
  for index = 1, count do
    if value[index] == nil then
      fail("game stats " .. what .. " must be a dense array", {})
    end
  end
end

---@param set table<string, boolean>
---@return table<string, boolean> detached copy
local function copySet(set)
  local copy = {}
  for key in pairs(set) do
    copy[key] = true
  end
  return copy
end

-- Adds points to a score under the retail ceiling.
---@param score integer
---@param points integer
---@return integer
local function cappedScore(score, points)
  local total = score + points
  if total > GameStats.SCORE_CAP then
    return GameStats.SCORE_CAP
  end
  return total
end

-- Builds fresh stats over the resolved species set with nothing counted
-- and a zero score.
---@param args { species: table<string, boolean> }
---@return GameStats
function GameStats.new(args)
  if type(args) ~= "table" then
    fail("game stats require a construction record", {})
  end
  return setmetatable({
    _allowed = checkSpeciesSet(args.species),
    _counted = {},
    _unique = 0,
    _score = 0,
    _mailWritten = 0,
    _stepsBiked = 0,
    _leagueWins = 0,
    _revision = 0,
  }, GameStats)
end

-- Rebuilds stats from a validated or migrated persisted bucket over the
-- same resolved species set. Unknown saved references fail; a missing
-- bucket starts empty.
---@param bucket table<string, unknown>?
---@param refs { species: table<string, boolean> }
---@return GameStats
function GameStats.restore(bucket, refs)
  if type(refs) ~= "table" then
    fail("stats restore requires a reference record", {})
  end
  local GameStatsSave = require("libs.hgss.src.save.GameStatsSave")
  local valid = GameStatsSave.migrate(bucket, refs)
  local stats = GameStats.new({ species = refs.species })
  for _, key in ipairs(valid.uniqueCaught) do
    stats._counted[key] = true
  end
  stats._unique = valid.uniqueTotal
  stats._score = valid.score
  stats._mailWritten = valid.mailWritten
  stats._stepsBiked = valid.stepsBiked
  stats._leagueWins = valid.leagueWins
  return stats
end

-- Projects one detached registration record from an admitted mon: the
-- semantic species and the egg state. Reads primitives only; the mon is
-- never mutated, copied wholesale, or revalidated.
---@param mon table<string, unknown>
---@return { species: string, isEgg: boolean }
function GameStats:describe(mon)
  if type(mon) ~= "table" then
    fail("stats description requires an admitted mon", {})
  end
  local record = mon --[[@as table<string, unknown>]]
  local speciesKey = record.species
  if type(speciesKey) ~= "string" or self._allowed[speciesKey] ~= true then
    fail("stats description names an unknown species", { species = speciesKey })
  end
  if type(record.isEgg) ~= "boolean" then
    fail("stats description egg flag must be a boolean", { species = speciesKey })
  end
  return { species = speciesKey, isEgg = record.isEgg }
end

-- Answers whether the species has ever appeared in a published batch.
-- Producers without dex access use this as the freshness authority;
-- receipt paths with dex access gate on the dex caught flag instead.
---@param key string
---@return boolean
function GameStats:isCounted(key)
  checkKey(self._allowed, key)
  return self._counted[key] == true
end

-- Reads the blind unique-registration total: every published
-- unique_caught observation adds one, including re-registrations,
-- exactly like the retail counter.
---@return integer
function GameStats:uniqueCount()
  return self._unique
end

---@return integer
function GameStats:score()
  return self._score
end

-- Reads the written-Mail total: one per successful new-letter custody,
-- capped at the retail ceiling.
---@return integer
function GameStats:mailWrittenCount()
  return self._mailWritten
end

-- Reads the steps-biked total behind the Bike Shop call.
---@return integer
function GameStats:stepsBikedCount()
  return self._stepsBiked
end

-- Counts one step taken on the Bicycle (PlayerAvatar_CountStep in
-- src/player_avatar_movement.c), saturating at the retail ceiling.
function GameStats:countBikedStep()
  if self._stepsBiked < GameStats.STEPS_BIKED_CAP then
    self._stepsBiked = self._stepsBiked + 1
    self._revision = self._revision + 1
  end
end

-- Reads the recorded League-win total: one per completed source clear
-- (GameStats_Inc(GAME_STAT_LEAGUE_WINS)), capped at the source ceiling.
---@return integer
function GameStats:leagueWins()
  return self._leagueWins
end

---@return integer
function GameStats:revision()
  return self._revision
end

-- Stages an ordered observation batch without touching live stats. Each
-- unique_caught observation adds one to the blind unique total, even
-- for an already-registered species, mirroring the retail counter behind
-- EVO_STATE_REGISTER and the shed side product. A score observation
-- names its semantic event, its earning species, and its points; the
-- owner verifies the points against the authoritative table. A
-- script_score_event observation names one source score event index and
-- the owner resolves its weight from the private sScoreMods table. Every
-- score change caps at the retail ceiling, and only the observations that
-- earn a species mark it in the counted set. Validation completes before
-- any field of the live owner mutates; a later invalid observation cannot
-- partially add an earlier valid one. The one-use candidate publishes
-- exactly once and only while current, advancing the revision exactly
-- when the batch changed anything; a repeated or stale publication fails
-- before touching state.
---@class StatsPreparation
---@field changed boolean
---@field isCurrent fun(): boolean
---@field publish fun()
---@param changes { observations: { kind: string, species: string?, event: string|integer?, points: integer? }[] }
---@return StatsPreparation
function GameStats:prepareChanges(changes)
  if type(changes) ~= "table" then
    fail("stats changes must be a record", {})
  end
  for key in pairs(changes) do
    if key ~= "observations" then
      fail("stats changes contain an unknown field", { field = key })
    end
  end
  local request = changes --[[@as table<string, unknown>]]
  if request.observations == nil then
    fail("stats changes carry their observations", {})
  end
  checkDenseList(request.observations, "observations")
  local allowed = self._allowed
  local observations = {}
  for index, entry in ipairs(request.observations) do
    if type(entry) ~= "table" then
      fail("stats observations carry kind and payload records", {})
    end
    local staged = entry --[[@as table<string, unknown>]]
    if staged.kind == "unique_caught" then
      for key in pairs(staged) do
        if key ~= "kind" and key ~= "species" then
          fail("stats observations carry kind and payload records", { field = key })
        end
      end
      observations[index] = { kind = "unique_caught", species = checkKey(allowed, staged.species) }
    elseif staged.kind == "score" then
      for key in pairs(staged) do
        if key ~= "kind" and key ~= "species" and key ~= "event" and key ~= "points" then
          fail("stats observations carry kind and payload records", { field = key })
        end
      end
      if type(staged.event) ~= "string" or GameStats.SCORE_POINTS[staged.event] == nil then
        fail("stats observation names an unknown score event", { event = staged.event })
      end
      local event = staged.event --[[@as string]]
      if type(staged.points) ~= "number" or staged.points % 1 ~= 0 or staged.points < 0 then
        fail("stats score points must be a non-negative integer", { event = event })
      end
      if staged.points ~= GameStats.SCORE_POINTS[event] then
        fail("stats score points mismatch their authoritative event value", { event = event })
      end
      local species = checkKey(allowed, staged.species)
      observations[index] = { kind = "score", species = species, event = event, points = staged.points }
    elseif staged.kind == "mail_written" then
      -- One written letter adds one to the Mail count under its own
      -- ceiling and one to the score under the shared ceiling, without
      -- marking any species as counted.
      for key in pairs(staged) do
        if key ~= "kind" then
          fail("stats observations carry kind and payload records", { field = key })
        end
      end
      observations[index] = { kind = "mail_written" }
    elseif staged.kind == "league_win" then
      -- One completed League ending awards the source League-win statistic
      -- (src/game_clear.c::CallTask_GameClear). It earns no score and marks
      -- no species.
      for key in pairs(staged) do
        if key ~= "kind" then
          fail("stats observations carry kind and payload records", { field = key })
        end
      end
      observations[index] = { kind = "league_win" }
    elseif staged.kind == "script_score_event" then
      -- One source script score event (ScrCmd_AddSpecialGameStat): the
      -- owner resolves the weight from its private table, so a producer
      -- names the event only. Only the award operation below stages this
      -- kind; it marks no species as counted and writes no Mail.
      for key in pairs(staged) do
        if key ~= "kind" and key ~= "event" then
          fail("stats observations carry kind and payload records", { field = key })
        end
      end
      local eventId = checkScriptScoreEvent(staged.event)
      if eventId == nil then
        fail("stats observation names a source score event outside the table", { event = staged.event })
      end
      observations[index] = { kind = "script_score_event", points = SCRIPT_SCORE_MODS[eventId + 1] }
    else
      fail("stats observation names an unknown kind", { kind = staged.kind })
    end
  end
  local scratchCounted = copySet(self._counted)
  local scratchUnique = self._unique
  local scratchScore = self._score
  local scratchMailWritten = self._mailWritten
  local scratchLeagueWins = self._leagueWins
  local changed = false
  for _, observation in ipairs(observations) do
    if observation.kind == "unique_caught" then
      scratchUnique = scratchUnique + 1
      scratchCounted[observation.species] = true
      changed = true
    elseif observation.kind == "mail_written" then
      if scratchMailWritten < GameStats.MAIL_WRITTEN_CAP then
        scratchMailWritten = scratchMailWritten + 1
        changed = true
      end
      local total = cappedScore(scratchScore, 1)
      if total ~= scratchScore then
        scratchScore = total
        changed = true
      end
    elseif observation.kind == "league_win" then
      if scratchLeagueWins < GameStats.LEAGUE_WINS_CAP then
        scratchLeagueWins = scratchLeagueWins + 1
        changed = true
      end
    elseif observation.kind == "script_score_event" then
      local total = cappedScore(scratchScore, observation.points)
      if total ~= scratchScore then
        scratchScore = total
        changed = true
      end
    else
      local total = cappedScore(scratchScore, observation.points)
      if total ~= scratchScore then
        scratchScore = total
        changed = true
      end
      scratchCounted[observation.species] = true
    end
  end
  local capturedRevision = self._revision
  local consumed = false
  local function isCurrent()
    return (not consumed) and self._revision == capturedRevision
  end
  local function publish()
    if consumed then
      fail("stats preparation already published", {})
    end
    if self._revision ~= capturedRevision then
      fail("stats preparation is stale", {})
    end
    consumed = true
    self._counted = scratchCounted
    self._unique = scratchUnique
    self._score = scratchScore
    self._mailWritten = scratchMailWritten
    self._leagueWins = scratchLeagueWins
    if changed then
      self._revision = self._revision + 1
    end
  end
  return { changed = changed, isCurrent = isCurrent, publish = publish }
end

-- Applies one source script score event: ScrCmd_AddSpecialGameStat
-- (src/scrcmd_c.c) names an index into sScoreMods and GameStats_AddScore
-- adds that weight under the retail ceiling (src/game_stats.c). The award
-- stages and publishes through the same revisioned preparation as every
-- other score observation, so it never bypasses the cap or the saved
-- bucket, and an index the source table does not have is invalid input
-- rather than a zero-point event.
---@param eventId integer
function GameStats:awardScriptScoreEvent(eventId)
  local event = checkScriptScoreEvent(eventId)
  if event == nil then
    fail("source score event is outside the source table", { event = eventId })
  end
  self:prepareChanges({ observations = { { kind = "script_score_event", event = event } } }):publish()
end

-- Applies the one source League-win award through the same revisioned
-- preparation as every other statistic.
function GameStats:awardLeagueWin()
  self:prepareChanges({ observations = { { kind = "league_win" } } }):publish()
end

-- Reads the persistable bucket: the sorted registration set (freshness
-- authority), the blind unique total, the bounded score, and the
-- bounded written-Mail, steps-biked, and League-win totals. The result is
-- detached; callers cannot mutate live owner state through it.
---@return table<string, unknown> detached canonical v4 bucket
function GameStats:bucket()
  local GameStatsSave = require("libs.hgss.src.save.GameStatsSave")
  local uniqueCaught = {}
  for key in pairs(self._counted) do
    uniqueCaught[#uniqueCaught + 1] = key
  end
  table.sort(uniqueCaught)
  return {
    schema = GameStatsSave.SCHEMA,
    stateVersion = GameStatsSave.STATE_VERSION,
    uniqueCaught = uniqueCaught,
    uniqueTotal = self._unique,
    score = self._score,
    mailWritten = self._mailWritten,
    stepsBiked = self._stepsBiked,
    leagueWins = self._leagueWins,
  }
end

return GameStats
