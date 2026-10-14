-- The companion feature's deterministic draw pair: the existing Gen-IV
-- linear stream for source LCRandom widths and a private MT19937 stream
-- for source MTRandom widths. Both streams start from the companion seed
-- boundary, advance only at labelled caller sites, and resume from scalar
-- captures; an optional bounded caller-owned sink records labels without
-- drawing. Pure domain module: no love dependency.

local bit = require("bit")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local PokegearState = require("libs.hgss.src.save.PokegearState")
local U32 = require("libs.codec.src.U32")

---@class PokegearRandom
---@field private _lc Gen4Lcrng
---@field private _mt table<integer, integer>
---@field private _mti integer
---@field private _trace table<integer, table<string, unknown>>?
---@field private _traceLimit integer
local PokegearRandom = {}
PokegearRandom.__index = PokegearRandom

local MT_N = 624
local MT_M = 397
local MT_MATRIX_A = 0x9908b0df
local MT_UPPER_MASK = 0x80000000
local MT_LOWER_MASK = 0x7fffffff
local MT_TEMPER_MASK_B = 0x9d2c5680
local MT_TEMPER_MASK_C = 0xefc60000

local DEFAULT_TRACE_LIMIT = 256

---@param value number
---@return integer
local function toU32(value)
  if value < 0 then
    return math.floor(value + U32.MOD)
  end
  return math.floor(value)
end

---@param seed integer
---@param trace table<integer, table<string, unknown>>?
---@param traceLimit integer
---@return PokegearRandom
local function build(seed, trace, traceLimit)
  local fresh = PokegearState.freshRandom(seed)
  assert(type(fresh.mt) == "table", "companion draws start from the shared initial state")
  local mt = fresh.mt
  assert(type(mt) == "table" and type(mt.state) == "table", "companion draws copy the source state array")
  local state = {}
  for index = 1, MT_N do
    state[index] = mt.state[index]
  end
  return setmetatable({
    _lc = Lcrng.new(seed),
    _mt = state,
    _mti = mt.index,
    _trace = trace,
    _traceLimit = traceLimit,
  }, PokegearRandom)
end

---@param opts unknown
---@return table<integer, table<string, unknown>>? trace, integer limit
local function checkTraceOpts(opts)
  if opts == nil then
    return nil, DEFAULT_TRACE_LIMIT
  end
  assert(type(opts) == "table", "companion draw options stay a record")
  for key in pairs(opts) do
    if key ~= "trace" and key ~= "traceLimit" then
      error("pokegear draw options carry only a trace sink and its bound", 0)
    end
  end
  assert(type(opts) == "table", "companion draw options read the trace sink")
  local trace = opts.trace
  local limit = opts.traceLimit
  if trace ~= nil then
    assert(type(trace) == "table", "companion draws record into a caller-owned table")
  end
  if limit == nil then
    limit = DEFAULT_TRACE_LIMIT
  end
  assert(
    type(limit) == "number" and limit % 1 == 0 and limit >= 0,
    "companion trace bound stays a non-negative integer"
  )
  return trace, limit
end

-- Starts both streams from one unsigned seed. The seed is required: menu
-- or polling paths never reseed from host time.
---@param seed integer
---@param opts { trace: table<integer, table<string, unknown>>?, traceLimit: integer? }?
---@return PokegearRandom
function PokegearRandom.new(seed, opts)
  assert(
    type(seed) == "number" and seed % 1 == 0 and seed >= 0 and seed <= U32.MAX,
    "companion draws start from an unsigned 32-bit seed"
  )
  local trace, limit = checkTraceOpts(opts)
  return build(seed, trace, limit)
end

-- Resumes both streams from a scalar capture. Malformed snapshots fail
-- instead of drawing.
---@param snapshot unknown
---@return PokegearRandom
function PokegearRandom.restore(snapshot)
  local canonical = PokegearState.validateRandomBucket(snapshot)
  assert(type(canonical.lc) == "table" and type(canonical.mt) == "table", "restoration reads both draw streams")
  local lc = canonical.lc
  local mt = canonical.mt
  assert(type(lc) == "table" and type(mt) == "table", "restoration copies draw state")
  local state = {}
  assert(type(mt.state) == "table", "restoration copies the source state array")
  for index = 1, MT_N do
    state[index] = mt.state[index]
  end
  return setmetatable({
    _lc = Lcrng.restore({ state = lc.state, calls = lc.calls }),
    _mt = state,
    _mti = mt.index,
    _trace = nil,
    _traceLimit = DEFAULT_TRACE_LIMIT,
  }, PokegearRandom)
end

---@param stream string
---@param label string
---@param value integer
function PokegearRandom:_record(stream, label, value)
  local trace = self._trace
  if trace == nil or #trace >= self._traceLimit then
    return
  end
  trace[#trace + 1] = { stream = stream, label = label, value = value }
end

-- Advances the source twist once the state array is exhausted, following
-- the reference recurrence with exact 32-bit arithmetic.
function PokegearRandom:_twist()
  local mt = self._mt
  for index = 0, MT_N - 1 do
    local first = mt[index + 1]
    local second = mt[((index + 1) % MT_N) + 1]
    assert(type(first) == "number" and type(second) == "number", "companion twist reads state entries")
    local combined = bit.bor(bit.band(first, MT_UPPER_MASK), bit.band(second, MT_LOWER_MASK))
    local mixed = mt[((index + MT_M) % MT_N) + 1]
    assert(type(mixed) == "number", "companion twist reads the recurrence entry")
    local next = bit.bxor(mixed, bit.rshift(combined, 1))
    if bit.band(combined, 1) ~= 0 then
      next = bit.bxor(next, MT_MATRIX_A)
    end
    mt[index + 1] = toU32(next)
  end
  self._mti = 0
end

---@param value integer
---@return integer tempered output
local function temper(value)
  local worked = bit.bxor(value, bit.rshift(value, 11))
  worked = bit.bxor(worked, bit.band(bit.lshift(worked, 7), MT_TEMPER_MASK_B))
  worked = bit.bxor(worked, bit.band(bit.lshift(worked, 15), MT_TEMPER_MASK_C))
  worked = bit.bxor(worked, bit.rshift(worked, 18))
  return toU32(worked)
end

-- Draws the source 16-bit value at a labelled caller site. Modulo and
-- integer division stay at the caller, including rejected selections.
---@param label string
---@return integer
function PokegearRandom:lc(label)
  assert(type(label) == "string" and label ~= "", "companion linear draws carry a label")
  local value = self._lc:nextU16()
  self:_record("lc", label, value)
  return value
end

-- Draws the source 32-bit value at a labelled caller site. Display and
-- status reads never call this path.
---@param label string
---@return integer
function PokegearRandom:mt(label)
  assert(type(label) == "string" and label ~= "", "companion source draws carry a label")
  if self._mti >= MT_N then
    self:_twist()
  end
  local raw = self._mt[self._mti + 1]
  assert(type(raw) == "number", "companion source draws read state entries")
  self._mti = self._mti + 1
  local value = temper(raw)
  self:_record("mt", label, value)
  return value
end

-- Captures both streams as scalar state without drawing.
---@return table<string, unknown>
function PokegearRandom:capture()
  local lc = self._lc:capture()
  local state = {}
  for index = 1, MT_N do
    state[index] = self._mt[index]
  end
  return {
    lc = { state = lc.state, calls = lc.calls },
    mt = { index = self._mti, state = state },
  }
end

-- Captures both streams and the bounded diagnostic trace position for one
-- native call's text transaction. A failed message lookup restores this
-- point so retries consume the same source draws.
---@return { state: table<string, unknown>, traceLength: integer? }
function PokegearRandom:checkpoint()
  return {
    state = self:capture(),
    traceLength = self._trace ~= nil and #self._trace or nil,
  }
end

-- Restores one same-owner checkpoint in place. In-place restore preserves
-- the stream object shared by the phone menu, field host, and world owners.
---@param checkpoint { state: table<string, unknown>, traceLength: integer? }
function PokegearRandom:restoreCheckpoint(checkpoint)
  assert(type(checkpoint) == "table", "random rollback needs its captured checkpoint")
  for key in pairs(checkpoint) do
    assert(key == "state" or key == "traceLength", "random checkpoints carry only stream state and trace length")
  end
  local state = checkpoint.state
  assert(type(state) == "table", "random rollback restores its saved stream state")
  local restored = PokegearRandom.restore(state)
  self._lc = restored._lc
  self._mt = restored._mt
  self._mti = restored._mti
  local trace = self._trace
  if trace ~= nil then
    local traceLength = checkpoint.traceLength
    assert(
      type(traceLength) == "number" and traceLength % 1 == 0 and traceLength >= 0,
      "traced random checkpoints preserve their trace position"
    )
    while #trace > traceLength do
      trace[#trace] = nil
    end
  else
    assert(checkpoint.traceLength == nil, "untraced streams do not restore a trace position")
  end
end

return PokegearRandom
