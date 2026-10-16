-- Bounded opt-in census for the retained-session memory baseline.
-- Test and performance support only: it never participates in production
-- composition, never retains a live resource or sample buffer, and never
-- probes the process on its own. Callers gather checkpoint facts through
-- public owner seams and hand externally sampled RSS/HWM in explicitly;
-- every value the trace stores is a scalar (number, string, boolean, nil).
-- Frame times accumulate into fixed-size numeric buckets, snapshots into a
-- fixed-size ring, so a long replay cannot grow the observer itself.

---@class AssetMemoryTrace
---@field CHECKPOINTS string[] canonical checkpoint order for one retained-session replay
---@field HISTORY_LIMIT integer maximum retained snapshots per tracer
---@field FRAME_BUCKETS integer fixed frame-time bucket count
---@field FRAME_BUCKET_MS number frame-time bucket width in milliseconds
local AssetMemoryTrace = {}
AssetMemoryTrace.__index = AssetMemoryTrace

-- Canonical checkpoint order for one retained-session replay. A journey
-- captures the subset its setup can reach (a fresh save has no party, so
-- summary/pc/battle legs need stocked saves owned by later traces) and the
-- trace asserts the captured labels follow this order.
AssetMemoryTrace.CHECKPOINTS =
  { "field-entry", "travel", "bag", "summary", "pc", "battle", "return-to-field" }

-- Bounded observer storage: at most 64 snapshots and 32 five-millisecond
-- buckets (0-160ms, overflow clamps into the last bucket and is counted).
AssetMemoryTrace.HISTORY_LIMIT = 64
AssetMemoryTrace.FRAME_BUCKETS = 32
AssetMemoryTrace.FRAME_BUCKET_MS = 5

---@param name string
---@return integer|nil position of the checkpoint in the canonical order, or nil for ad-hoc labels
function AssetMemoryTrace.checkpointIndex(name)
  for index, checkpoint in ipairs(AssetMemoryTrace.CHECKPOINTS) do
    if checkpoint == name then
      return index
    end
  end
  return nil
end

-- Explicit checkpoint-only Lua heap read. The tracer never calls this
-- itself: callers invoke it once per named checkpoint, never per frame.
---@return number kilobytes reported by collectgarbage at the checkpoint
function AssetMemoryTrace.luaKilobytes()
  return collectgarbage("count")
end

-- Normalizes one love.graphics-shaped namespace into scalar GPU facts.
-- Never touches the real love namespace: the caller injects the namespace
-- (or nil when graphics are unavailable), so headless runs stay headless.
---@param graphics table|nil namespace exposing getStats, or nil without graphics
---@return table scalar facts with an explicit available flag, never zeros for missing data
function AssetMemoryTrace.readGraphicsStats(graphics)
  if type(graphics) ~= "table" or type(graphics.getStats) ~= "function" then
    return { available = false }
  end
  local ok, stats = pcall(graphics.getStats)
  if not ok or type(stats) ~= "table" then
    return { available = false }
  end
  local facts = { available = true }
  if type(stats.images) == "number" then
    facts.images = stats.images
  end
  if type(stats.canvases) == "number" then
    facts.canvases = stats.canvases
  end
  if type(stats.texturememory) == "number" then
    facts.textureBytes = stats.texturememory
  end
  return facts
end

-- Reads renderer identity from one love.graphics-shaped namespace without
-- creating anything. Returns an explicit unavailable marker when there is
-- no graphics namespace or the query fails.
---@param graphics table|nil namespace exposing getRendererInfo, or nil without graphics
---@return table scalar renderer facts with an explicit available flag
function AssetMemoryTrace.rendererIdentity(graphics)
  if type(graphics) ~= "table" or type(graphics.getRendererInfo) ~= "function" then
    return { available = false }
  end
  local ok, name, version, vendor, device = pcall(graphics.getRendererInfo)
  if not ok or type(name) ~= "string" then
    return { available = false }
  end
  local facts = { available = true, name = name }
  if type(version) == "string" then
    facts.version = version
  end
  if type(vendor) == "string" then
    facts.vendor = vendor
  end
  if type(device) == "string" then
    facts.device = device
  end
  return facts
end

-- Names the pinned baseline artifact for one source generation and one
-- renderer so repeat runs with the same cache warmness stay comparable.
-- Both inputs are sanitized to filename-safe slugs; distinct renderers
-- always produce distinct names.
---@param sourceSha string full hex digest of the derived-cache source generation
---@param rendererName string|nil renderer name, or nil when graphics are unavailable
---@return string artifact file name carrying the short SHA and the renderer slug
function AssetMemoryTrace.baselineFileName(sourceSha, rendererName)
  assert(type(sourceSha) == "string" and #sourceSha > 0, "baseline file name needs a source SHA")
  local shortSha = sourceSha:sub(1, 7):gsub("[^A-Za-z0-9]", "")
  if shortSha == "" then
    shortSha = "unknown-source"
  end
  local slug = type(rendererName) == "string" and rendererName:lower():gsub("[^a-z0-9]+", "-"):gsub(
    "^%-+",
    ""
  ):gsub("%-+$", "")
  if type(slug) ~= "string" or slug == "" then
    slug = "unknown-renderer"
  end
  return "asset-memory-baseline-" .. shortSha .. "-" .. slug .. ".json"
end

---@class AssetMemoryTracer
---@field private _enabled boolean
---@field private _history table[] fixed-size ring of stored snapshot records
---@field private _start integer ring start index (1-based) of the oldest retained record
---@field private _count integer snapshots ever recorded
---@field private _buckets integer[] fixed-size frame-time bucket counts
---@field private _frames integer frame times ever observed
---@field private _frameSumMs number sum of observed frame times in milliseconds
---@field private _overflowFrames integer observations at or above the last bucket edge
local Tracer = {}
Tracer.__index = Tracer

---@param opts { enabled?: boolean }|nil
---@return AssetMemoryTracer
function AssetMemoryTrace.new(opts)
  opts = opts or {}
  local enabled = opts.enabled
  if enabled == nil then
    enabled = true
  end
  local buckets = {}
  for index = 1, AssetMemoryTrace.FRAME_BUCKETS do
    buckets[index] = 0
  end
  return setmetatable({
    _enabled = enabled == true,
    _history = {},
    _start = 1,
    _count = 0,
    _buckets = buckets,
    _frames = 0,
    _frameSumMs = 0,
    _overflowFrames = 0,
  }, Tracer)
end

---@return boolean
function Tracer:isEnabled()
  return self._enabled
end

-- Observes one frame duration without allocating: exactly one numeric
-- bucket counter moves. A no-op while sampling is disabled. Never calls
-- collectgarbage.
---@param dtMs number frame duration in milliseconds, must be finite and non-negative
function Tracer:observeFrameTime(dtMs)
  assert(type(dtMs) == "number" and dtMs >= 0 and dtMs < math.huge, "frame time must be a finite non-negative number")
  if not self._enabled then
    return
  end
  local bucket = math.floor(dtMs / AssetMemoryTrace.FRAME_BUCKET_MS) + 1
  if bucket > AssetMemoryTrace.FRAME_BUCKETS then
    bucket = AssetMemoryTrace.FRAME_BUCKETS
    self._overflowFrames = self._overflowFrames + 1
  end
  self._buckets[bucket] = self._buckets[bucket] + 1
  self._frames = self._frames + 1
  self._frameSumMs = self._frameSumMs + dtMs
end

---@return integer fixed bucket count, unchanged no matter how many frames were observed
function Tracer:bucketCount()
  return #self._buckets
end

-- Estimates one percentile from the fixed buckets as the bucket midpoint.
-- Returns nil before the first observation.
---@param p number percentile in [0, 100]
---@return number|nil bucket midpoint in milliseconds, or nil with no observations
function Tracer:framePercentile(p)
  assert(type(p) == "number" and p >= 0 and p <= 100, "percentile must be in [0, 100]")
  if self._frames == 0 then
    return nil
  end
  local rank = (p / 100) * self._frames
  if rank < 1 then
    rank = 1
  end
  local seen = 0
  for index = 1, AssetMemoryTrace.FRAME_BUCKETS do
    seen = seen + self._buckets[index]
    if seen >= rank then
      return (index - 0.5) * AssetMemoryTrace.FRAME_BUCKET_MS
    end
  end
  return (AssetMemoryTrace.FRAME_BUCKETS - 0.5) * AssetMemoryTrace.FRAME_BUCKET_MS
end

-- Scalar-only frame summary, or nil before the first observation.
---@return table|nil { count: integer, meanMs: number, p50Ms: number, p95Ms: number, p99Ms: number, overflowFrames: integer }
function Tracer:frameSummary()
  if self._frames == 0 then
    return nil
  end
  return {
    count = self._frames,
    meanMs = self._frameSumMs / self._frames,
    p50Ms = assert(self:framePercentile(50)),
    p95Ms = assert(self:framePercentile(95)),
    p99Ms = assert(self:framePercentile(99)),
    overflowFrames = self._overflowFrames,
  }
end

local function checkScalarFacts(facts)
  assert(type(facts) == "table", "snapshot facts must be a table of scalars")
  for key, value in pairs(facts) do
    local valueType = type(value)
    if valueType ~= "number" and valueType ~= "string" and valueType ~= "boolean" and value ~= nil then
      error("snapshot fact '" .. tostring(key) .. "' must be a scalar, got " .. valueType, 0)
    end
  end
end

-- Records one named checkpoint. Returns nil and retains nothing while
-- sampling is disabled. Fact values are copied as scalars, so later caller
-- mutation cannot rewrite history, and live tables are refused outright.
---@param label string checkpoint name, canonically one of CHECKPOINTS
---@param facts table<string, number|string|boolean|nil> scalar attribution facts
---@return table|nil the stored record { seq: integer, label: string, facts: table }, or nil when disabled
function Tracer:snapshot(label, facts)
  assert(type(label) == "string" and label ~= "", "snapshot needs a non-empty label")
  checkScalarFacts(facts)
  if not self._enabled then
    return nil
  end
  local stored = {}
  for key, value in pairs(facts) do
    stored[key] = value
  end
  self._count = self._count + 1
  local record = { seq = self._count, label = label, facts = stored }
  if #self._history < AssetMemoryTrace.HISTORY_LIMIT then
    self._history[#self._history + 1] = record
  else
    self._history[self._start] = record
    self._start = (self._start % AssetMemoryTrace.HISTORY_LIMIT) + 1
  end
  return record
end

---@return integer snapshots ever recorded, including overwritten ones
function Tracer:snapshotCount()
  return self._count
end

---@return integer snapshots overwritten by the bound, always zero while under the limit
function Tracer:droppedSnapshots()
  return self._count - #self._history
end

-- Returns retained records oldest-first as fresh shells. The facts tables
-- are shared read-only views of stored history.
---@return table[] { seq: integer, label: string, facts: table } oldest first
function Tracer:history()
  local out = {}
  for offset = 0, #self._history - 1 do
    local index = ((self._start - 1 + offset) % AssetMemoryTrace.HISTORY_LIMIT) + 1
    local record = self._history[index]
    out[#out + 1] = { seq = record.seq, label = record.label, facts = record.facts }
  end
  return out
end

local function escapeJsonString(value)
  return value:gsub('[%c\\"]', function(char)
    if char == '"' then
      return '\\"'
    end
    if char == "\\" then
      return "\\\\"
    end
    return string.format("\\u%04x", string.byte(char))
  end)
end

local function encodeJson(value, depth)
  assert((depth or 0) < 16, "trace JSON exceeds the supported nesting depth")
  local valueType = type(value)
  if valueType == "nil" then
    return "null"
  end
  if valueType == "boolean" then
    return value and "true" or "false"
  end
  if valueType == "number" then
    assert(value == value and value ~= math.huge and value ~= -math.huge, "trace JSON needs finite numbers")
    return tostring(value)
  end
  if valueType == "string" then
    return '"' .. escapeJsonString(value) .. '"'
  end
  assert(valueType == "table", "trace JSON encodes only scalars, arrays, and string-keyed records")
  local count = #value
  local keyCount = 0
  for _ in pairs(value) do
    keyCount = keyCount + 1
  end
  if keyCount == 0 then
    return "[]"
  end
  if keyCount == count then
    local parts = {}
    for index = 1, count do
      parts[#parts + 1] = encodeJson(value[index], (depth or 0) + 1)
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for key in pairs(value) do
    assert(type(key) == "string", "trace JSON records need string keys")
    keys[#keys + 1] = key
  end
  table.sort(keys)
  local parts = {}
  for _, key in ipairs(keys) do
    if value[key] ~= nil then
      parts[#parts + 1] = '"' .. escapeJsonString(key) .. '":' .. encodeJson(value[key], (depth or 0) + 1)
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- Serializes retained history plus the frame summary through the stable
-- schema: sorted record keys, oldest-first rows, scalars only.
---@return string deterministic JSON document
function Tracer:toJson()
  return encodeJson({ history = self:history(), summary = self:frameSummary() })
end

-- Serializes retained history in long CSV form with a stable header:
-- seq,label,metric,value. One row per scalar fact, oldest first.
---@return string csv document with a stable header row
function Tracer:toCsv()
  local lines = { "seq,label,metric,value" }
  for _, record in ipairs(self:history()) do
    local keys = {}
    for key in pairs(record.facts) do
      keys[#keys + 1] = key
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
      lines[#lines + 1] = string.format(
        "%d,%s,%s,%s",
        record.seq,
        tostring(record.label),
        tostring(key),
        tostring(record.facts[key])
      )
    end
  end
  return table.concat(lines, "\n") .. "\n"
end

return AssetMemoryTrace
