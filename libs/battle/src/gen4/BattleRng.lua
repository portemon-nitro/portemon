-- Native battle random stream. The battle owns one labeled stream over the
-- exact Generation-IV recurrence (state * 1103515245 + 24691 mod 2^32, upper
-- 16 bits returned) delegated to the established generator owner, so every
-- draw replays identically for the same seed. Each draw names its call-site
-- label and carries the semantic cause that ordered it; discarded draws
-- still advance the stream, snapshots capture the exact position, and
-- reading a snapshot never draws. Zero is a valid state and output. No host
-- randomness or wall clock feeds this stream anywhere.

local Lcrng = require("libs.mons.src.gen4.Lcrng")
local U32 = require("libs.codec.src.U32")

---@class BattleRngSnapshot
---@field algorithm string
---@field state integer
---@field calls integer

---@class BattleRngTraceEntry
---@field label string
---@field ordinal integer
---@field value integer
---@field cause table<string, unknown>

---@class BattleRng
---@field private _generator Gen4Lcrng
---@field private _trace BattleRngTraceEntry[]
local BattleRng = {}
BattleRng.__index = BattleRng

BattleRng.ALGORITHM = "gen4-lcrng"

---@param seedU32 integer
---@return BattleRng
function BattleRng.new(seedU32)
  assert(
    type(seedU32) == "number" and seedU32 % 1 == 0 and seedU32 >= 0 and seedU32 <= U32.MAX,
    "battle streams start from an unsigned 32-bit seed"
  )
  return setmetatable({ _generator = Lcrng.new(seedU32), _trace = {} }, BattleRng)
end

---@param snapshot BattleRngSnapshot
---@return BattleRng
function BattleRng.restore(snapshot)
  assert(type(snapshot) == "table", "battle snapshots restore from a record")
  assert(snapshot.algorithm == BattleRng.ALGORITHM, "battle snapshots carry the native stream identity")
  assert(
    type(snapshot.state) == "number" and snapshot.state % 1 == 0 and snapshot.state >= 0 and snapshot.state <= U32.MAX,
    "battle snapshots carry an unsigned 32-bit state"
  )
  assert(
    type(snapshot.calls) == "number" and snapshot.calls % 1 == 0 and snapshot.calls >= 0,
    "battle snapshots carry a non-negative call count"
  )
  local generator = Lcrng.restore({ state = snapshot.state, calls = snapshot.calls })
  return setmetatable({ _generator = generator, _trace = {} }, BattleRng)
end

---@param label string call-site identity recorded with the draw
---@param cause table<string, unknown> semantic reason that ordered the draw
---@return integer upper 16 bits of the advanced state
function BattleRng:nextU16(label, cause)
  assert(type(label) == "string" and label ~= "", "labeled draws name their call site")
  assert(type(cause) == "table", "labeled draws carry their semantic cause")
  local value = self._generator:nextU16()
  local position = self._generator:capture()
  self._trace[#self._trace + 1] = { label = label, ordinal = position.calls, value = value, cause = cause }
  return value
end

---@return BattleRngSnapshot detached position reading that consumes no draws
function BattleRng:capture()
  local position = self._generator:capture()
  return { algorithm = BattleRng.ALGORITHM, state = position.state, calls = position.calls }
end

return BattleRng
