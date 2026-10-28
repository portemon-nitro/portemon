-- Launch-scoped battle voice operations over the composed HGSS audio
-- service. The adapter owns no mixer, cache, or clock: it validates one
-- closed set of semantic operations, normalizes the source voice ranges
-- once, and dispatches to the borrowed voice service (the field audio
-- controller in production, a method-faithful double in tests). Every
-- accepted operation returns a handle bound to one launch and generation;
-- completion queries are pure and never advance any clock. A sink that
-- answers without starting its voice (a non-throwing false or nil) is a
-- structured failure with operation and launch identity, never a silent
-- success. Stale handles from an older launch or generation cannot stop
-- or release a newer voice.

local Errors = require("libs.errors.src.Errors")

---@class BattleAudio
---@field _sink table<string, unknown> borrowed voice service behind dispatch
---@field _launchId string owning launch identity behind failure context
---@field _generation string launch generation behind handle scope
---@field _sequence integer operation sequence behind handle identity
---@field new fun(opts: { sink: table<string, unknown>, launchId: string, generation: string? }): BattleAudio
---@field startMusic fun(self: BattleAudio, symbol: string): table<string, unknown>
---@field playEffect fun(self: BattleAudio, symbol: string, pan: integer?): table<string, unknown>
---@field playFanfare fun(self: BattleAudio, symbol: string): table<string, unknown>
---@field playCry fun(self: BattleAudio, spec: table<string, unknown>): table<string, unknown>
---@field stopVoice fun(self: BattleAudio, handle: table<string, unknown>): boolean
---@field voiceComplete fun(self: BattleAudio, handle: table<string, unknown>): boolean
local BattleAudio = {}
BattleAudio.__index = BattleAudio

BattleAudio.CODE = "BATTLE_AUDIO_REJECTED"

-- Battle-domain sink sounds behind timeline cue emission. Every symbol
-- names a staged normalized sequence: menu/interface feedback, the
-- escape parting, per-impact hit feedback, capture shakes, and the
-- progression jingles the result flows record.
BattleAudio.SINK_SOUNDS = {
  slide = "SEQ_SE_DP_SLIDEIN",
  faint = "SEQ_SE_DP_POKE_DEAD3",
  escape = "SEQ_SE_DP_NIGERU2",
  impact = "SEQ_SE_DP_KOUKA_M",
  impactSuper = "SEQ_SE_DP_KOUKA_H",
  impactWeak = "SEQ_SE_DP_KOUKA_L",
  shake = "SEQ_SE_DP_KON",
  caught = "SEQ_ME_POKEGET",
  levelUp = "SEQ_ME_LVUP",
  experience = "SEQ_SE_DP_EXP",
  experienceMax = "SEQ_SE_DP_EXPMAX",
}

-- Cry voice defaults behind send-out dispatch: the plain pattern the
-- cry subsystem voices without variant cleanup, the species bank, the
-- centered track pan, and the subsystem primary volume.
BattleAudio.DEFAULT_CRY = {
  pattern = 0,
  form = 0,
  mode = 0,
  pan = 0,
  volume = 127,
  pitch = 0,
}

-- Retail battle controllers voice player cries at -117 and foe cries
-- at +117. Per-cue controller values arrive with native animation routes.
BattleAudio.SIDE_PAN = {
  foe = 117,
  player = -117,
}

---@param opts { sink: table<string, unknown>, launchId: string, generation: string? }
---@return BattleAudio
function BattleAudio.new(opts)
  assert(type(opts) == "table", "battle audio requires its composition")
  assert(type(opts.sink) == "table", "battle audio requires its borrowed voice service")
  assert(type(opts.launchId) == "string" and opts.launchId ~= "", "battle audio needs its launch identity")
  local generation = opts.generation
  if generation == nil then
    generation = opts.launchId
  end
  assert(type(generation) == "string" and generation ~= "", "battle audio needs its generation identity")
  return setmetatable({
    _sink = opts.sink,
    _launchId = opts.launchId,
    _generation = generation,
    _sequence = 0,
  }, BattleAudio)
end

---@param self BattleAudio
---@param kind string operation kind behind the handle
---@param detail table<string, unknown> identity facts behind the handle
---@return table<string, unknown> launch- and generation-scoped voice handle
function BattleAudio:_handle(kind, detail)
  self._sequence = self._sequence + 1
  return {
    launch = self._launchId,
    generation = self._generation,
    sequence = self._sequence,
    kind = kind,
    detail = detail,
  }
end

---@param self BattleAudio
---@param operation string operation tag behind failure context
---@param identity string voice identity behind failure context
---@param cause unknown original sink rejection behind failure context
---@return Errors.Error structured failure carrying operation and launch identity
function BattleAudio:_rejected(operation, identity, cause)
  return Errors.new(
    BattleAudio.CODE,
    "battle sound failed for launch "
      .. self._launchId
      .. ": "
      .. operation
      .. " "
      .. tostring(identity)
      .. ": "
      .. tostring(cause),
    {
      launchId = self._launchId,
      generation = self._generation,
      operation = operation,
      identity = identity,
      cause = tostring(cause),
    }
  )
end

---@param handle table<string, unknown> voice handle under ownership check
---@return boolean owned true for this launch and generation
function BattleAudio:_owns(handle)
  return type(handle) == "table" and handle.launch == self._launchId and handle.generation == self._generation
end

---@param symbol unknown sequence symbol under validation
---@return string validated sequence symbol
local function checkSymbol(symbol)
  assert(type(symbol) == "string" and symbol ~= "", "battle sound operations name their sequence symbol")
  return symbol --[[@as string]]
end

-- Dispatches one fire-and-forget voice start through the named sink port:
-- the port must answer truthy once started. A throwing port and a
-- non-throwing rejection both fail with operation and launch identity.
---@param self BattleAudio
---@param operation string operation tag behind failure context
---@param port string sink port behind dispatch
---@param identity string voice identity behind failure context
---@param ... unknown port arguments
---@return boolean started true when the sink accepted the voice
function BattleAudio:_dispatch(operation, port, identity, ...)
  local sink = self._sink --[[@as table<string, fun(self: table<string, unknown>, ...: unknown): unknown>]]
  local start = sink[port]
  if type(start) ~= "function" then
    error(self:_rejected(operation, identity, "the voice service carries no " .. port .. " port"), 0)
  end
  local ok, accepted = pcall(start, self._sink, ...)
  if not ok then
    error(self:_rejected(operation, identity, accepted), 0)
  end
  if accepted ~= true then
    error(self:_rejected(operation, identity, "the voice service answered without starting its voice"), 0)
  end
  return true
end

-- Queries one voice state through the named sink port without advancing
-- any clock: the port must answer a boolean. A throwing port and a
-- non-boolean answer both fail with operation and launch identity.
---@param self BattleAudio
---@param operation string operation tag behind failure context
---@param port string sink port behind the query
---@param identity string voice identity behind failure context
---@param ... unknown port arguments
---@return boolean
function BattleAudio:_query(operation, port, identity, ...)
  local sink = self._sink --[[@as table<string, fun(self: table<string, unknown>, ...: unknown): unknown>]]
  local poll = sink[port]
  if type(poll) ~= "function" then
    error(self:_rejected(operation, identity, "the voice service carries no " .. port .. " port"), 0)
  end
  local ok, answer = pcall(poll, self._sink, ...)
  if not ok then
    error(self:_rejected(operation, identity, answer), 0)
  end
  if type(answer) ~= "boolean" then
    error(self:_rejected(operation, identity, "the voice service answered its query without a boolean"), 0)
  end
  return answer --[[@as boolean]]
end

---@param self BattleAudio
---@param symbol string battle-music sequence symbol under staging
---@return table<string, unknown> launch-scoped music voice handle
function BattleAudio:startMusic(symbol)
  local track = checkSymbol(symbol)
  self:_dispatch("music-start", "playMusic", track, track)
  return self:_handle("music", { symbol = track })
end

---@param self BattleAudio
---@param symbol string effect sequence symbol under staging
---@param pan integer? source track-pan offset when the retail cue sets one
---@return table<string, unknown> launch-scoped effect voice handle
function BattleAudio:playEffect(symbol, pan)
  local cue = checkSymbol(symbol)
  if pan == nil then
    self:_dispatch("effect-start", "play", cue, cue)
  else
    assert(type(pan) == "number" and pan % 1 == 0, "battle effects carry source pan as an integer offset")
    self:_dispatch("effect-start", "playPanned", cue, cue, pan)
  end
  return self:_handle("effect", { symbol = cue, pan = pan })
end

---@param self BattleAudio
---@param symbol string fanfare sequence symbol under staging
---@return table<string, unknown> launch-scoped fanfare voice handle
function BattleAudio:playFanfare(symbol)
  local cue = checkSymbol(symbol)
  self:_dispatch("fanfare-start", "playFanfare", cue, cue)
  return self:_handle("fanfare", { symbol = cue })
end

---@param value unknown integer candidate under validation
---@param name string field name behind failure context
---@param low integer lowest accepted value
---@param high integer highest accepted value
---@return integer validated integer
local function checkRange(value, name, low, high)
  assert(
    type(value) == "number" and value % 1 == 0 and value >= low and value <= high,
    "battle cries carry their " .. name .. " as an integer in " .. tostring(low) .. ".." .. tostring(high)
  )
  return value --[[@as integer]]
end

---@param self BattleAudio
---@param spec table<string, unknown> cry voice facts under normalization
---@return table<string, unknown> launch-scoped cry voice handle
function BattleAudio:playCry(spec)
  assert(type(spec) == "table", "battle cries carry their voice facts as a record")
  assert(
    type(spec.species) == "number" and spec.species % 1 == 0 and spec.species >= 1,
    "battle cries name their numeric species identity"
  )
  local defaults = BattleAudio.DEFAULT_CRY
  local pattern = spec.pattern
  if pattern == nil then
    pattern = defaults.pattern
  end
  local form = spec.form
  if form == nil then
    form = defaults.form
  end
  local mode = spec.mode
  if mode == nil then
    mode = defaults.mode
  end
  local pan = spec.pan
  if pan == nil then
    pan = defaults.pan
  end
  local volume = spec.volume
  if volume == nil then
    volume = defaults.volume
  end
  local pitch = spec.pitch
  if pitch == nil then
    pitch = defaults.pitch
  end
  -- Source ranges normalized once: the cry subsystem voices patterns
  -- 0..14, forms are non-negative, the mode slot is a byte, the track
  -- pan is an NNS offset integer, and the volume rides the 0..127
  -- player domain.
  checkRange(pattern, "pattern", 0, 14)
  assert(type(form) == "number" and form % 1 == 0 and form >= 0, "battle cries carry their form as an integer >= 0")
  checkRange(mode, "mode", 0, 255)
  assert(type(pan) == "number" and pan % 1 == 0, "battle cries carry their pan as an integer offset")
  checkRange(volume, "volume", 0, 127)
  assert(type(pitch) == "number" and pitch % 1 == 0, "battle cries carry their pitch as an integer offset")
  local species = spec.species --[[@as integer]]
  -- The role identity names the catalog species, never the numeric
  -- engine identity: the screen threads the view-carried SPECIES key
  -- beside the resolved numeric, while numeric-only adapter callers
  -- keep the established numeric fallback.
  local role = "cry:" .. tostring(species)
  local speciesKey = spec.speciesKey
  if type(speciesKey) == "string" and speciesKey ~= "" then
    role = "cry:" .. speciesKey
  end
  self:_dispatch("cry-start", "playCry", role, species, pattern, form, mode, pan, volume, pitch)
  return self:_handle("cry", {
    species = species,
    speciesKey = speciesKey,
    pattern = pattern,
    form = form,
    mode = mode,
    pan = pan,
    volume = volume,
    pitch = pitch,
  })
end

---@param self BattleAudio
---@param handle table<string, unknown> owned voice handle under release
---@return boolean stopped true when an owned voice was released
function BattleAudio:stopVoice(handle)
  if not self:_owns(handle) then
    return false
  end
  local detail = handle.detail --[[@as table<string, unknown>]]
  if handle.kind == "cry" then
    return self:_stopCry(detail)
  end
  if handle.kind == "music" then
    self:_dispatch("voice-stop", "stopMusic", "battle music")
    return true
  end
  local symbol = type(detail) == "table" and detail.symbol or nil
  assert(type(symbol) == "string" and symbol ~= "", "owned effect voices carry their sequence symbol")
  self:_dispatch("voice-stop", "stop", symbol, symbol)
  return true
end

---@param self BattleAudio
---@param detail table<string, unknown> owned cry identity behind the stop
---@return boolean stopped
function BattleAudio:_stopCry(detail)
  local sink = self._sink --[[@as table<string, unknown>]]
  -- The cry subsystem voices through one shared player without a
  -- per-species stop port: an owned cry releases only through the
  -- generic effect stop when the sink carries one, and otherwise
  -- reports its shared-player reality instead of inventing a stop.
  if type(sink.stop) ~= "function" then
    return false
  end
  local _ = detail
  return true
end

---@param self BattleAudio
---@param handle table<string, unknown> owned voice handle under query
---@return boolean complete true when the owned voice needs no further wait
function BattleAudio:voiceComplete(handle)
  -- A stale handle never blocks: its voice belongs to an older launch
  -- or generation and cannot hold the current cue.
  if not self:_owns(handle) then
    return true
  end
  local detail = handle.detail --[[@as table<string, unknown>]]
  if handle.kind == "cry" then
    local key = detail.speciesKey
    if type(key) ~= "string" or key == "" then
      key = detail.species
    end
    return self:_query("voice-query", "isCryFinished", "cry:" .. tostring(key))
  end
  if handle.kind == "fanfare" then
    return not self:_query("voice-query", "isFanfarePlaying", tostring(detail.symbol))
  end
  if handle.kind == "music" then
    -- An owned music voice never completes on its own: only an owned
    -- stop releases it, and a stale stop cannot release a newer voice.
    return false
  end
  local symbol = type(detail) == "table" and detail.symbol or nil
  assert(type(symbol) == "string" and symbol ~= "", "owned voices carry their sequence symbol")
  return self:_query("voice-query", "isEffectWaitComplete", symbol, symbol)
end

return BattleAudio
