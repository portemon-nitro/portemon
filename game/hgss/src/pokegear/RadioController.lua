-- The radio card's exact tuner interaction: key, touch, drag, and preset
-- handling over the source circular hit areas, station-versus-signal
-- lifecycle against the broadcast program, and tuner persistence at unload.
-- The controller owns input and selection state and asks its private
-- reception policy plus the program; it never draws. Tuning coordinates
-- persist only at the source commit point (dispose); the remembered cursor
-- is not a playing station until input tunes one. Pure input owner: no
-- love, no I/O.

---@class RadioController
---@field _state table<string, unknown> the borrowed durable companion owner
---@field _program table<string, unknown> the borrowed broadcast program
---@field _reception table<string, unknown> the borrowed channel policy
---@field _map table<string, unknown> the borrowed live map facts
---@field _flags table<string, unknown> the borrowed live story flags
---@field _receptionKey string the channel table behind the tracked selection
---@field _moved boolean whether input moved the tuner since the last recompute
---@field _cursor { x: integer, y: integer } the source tuner position
---@field _selectedButton integer the remembered preset button, 0..3
---@field _station integer the tuned station, 0..7, or 255 for none
---@field _signal integer the tuned signal: 2 clear, 1 weak, 0 none
---@field _effect fun(sequence: string)? source UI sound effect boundary
---@field _dragging boolean whether a cursor drag is open
---@field _dragId unknown the pointer identity behind the open drag
---@field _disposed boolean
local RadioController = {}
RadioController.__index = RadioController

local TUNING_CENTER_X, TUNING_CENTER_Y, TUNING_RADIUS = 128, 92, 52
local PRESS_RADIUS = 8
local NO_STATION = 255

-- Paired clear/weak circles per reception table, in source flat order:
-- each pair is { x, y, clearRadius, weakRadius }.
local CHANNEL_PAIRS = {
  johto = {
    { 112, 76, 4, 16 },
    { 152, 76, 4, 20 },
    { 96, 108, 4, 16 },
    { 136, 116, 4, 20 },
  },
  kanto = {
    { 112, 76, 4, 16 },
    { 152, 76, 4, 20 },
    { 96, 108, 4, 16 },
  },
  ["kanto-expn"] = {
    { 112, 76, 4, 16 },
    { 152, 76, 4, 20 },
    { 96, 108, 4, 16 },
    { 136, 116, 4, 20 },
    { 128, 48, 4, 8 },
  },
  alph = {
    { 128, 92, 4, 16 },
  },
  rocket = {
    { 128, 92, 38, 52 },
  },
  mahogany = {
    { 128, 92, 38, 52 },
  },
  none = {},
}

-- Single-pair tables resolve to their fixed station; channel tables map
-- the pair index to the station.
local FIXED_STATION = {
  alph = 5,
  rocket = 6,
  mahogany = 7,
}

-- Preset buttons snap through the fixed Johto centers in order even when
-- the active table has fewer stations.
local PRESET_CENTERS = {
  { x = 112, y = 76 },
  { x = 152, y = 76 },
  { x = 96, y = 108 },
  { x = 136, y = 116 },
}

---@param x number
---@param y number
---@param cx number
---@param cy number
---@param radius number
---@return boolean
local function insideStrict(x, y, cx, cy, radius)
  local dx = x - cx
  local dy = y - cy
  return dx * dx + dy * dy < radius * radius
end

---@param x number
---@param y number
---@return boolean
local function insideTuningRim(x, y)
  local dx = x - TUNING_CENTER_X
  local dy = y - TUNING_CENTER_Y
  return dx * dx + dy * dy <= TUNING_RADIUS * TUNING_RADIUS
end

---@param key string
---@param x integer
---@param y integer
---@return integer station, integer signal
local function resolveTuning(key, x, y)
  local pairs = CHANNEL_PAIRS[key] or CHANNEL_PAIRS.none
  assert(type(pairs) == "table", "the reception key carries its channel pairs")
  for index, pair in ipairs(pairs) do
    assert(type(pair) == "table", "channel pairs carry their circles")
    local cx, cy, clearRadius, weakRadius = pair[1], pair[2], pair[3], pair[4]
    assert(type(cx) == "number" and type(cy) == "number", "channel pairs carry their centers")
    local station = FIXED_STATION[key]
    if station == nil then
      station = index - 1
    end
    assert(type(station) == "number", "channel pairs map to stations")
    if insideStrict(x, y, cx, cy, clearRadius) then
      return station, 2
    end
    if insideStrict(x, y, cx, cy, weakRadius) then
      return station, 1
    end
  end
  return NO_STATION, 0
end

---@class RadioController.Options
---@field state table<string, unknown> the durable companion owner
---@field catalog table<string, unknown> the borrowed compiled asset family
---@field program table<string, unknown> the broadcast program owner
---@field reception table<string, unknown> the channel selection policy
---@field presentation table<string, unknown> the borrowed presentation owner
---@field map table<string, unknown> the live map signal facts
---@field flags table<string, unknown> the live story flags
---@field effect fun(sequence: string)? source UI sound effect boundary

---@param opts RadioController.Options
---@return RadioController
function RadioController.new(opts)
  assert(type(opts) == "table", "the radio card requires its options")
  assert(
    type(opts.state) == "table"
      and type(opts.state.readPreferences) == "function"
      and type(opts.state.setPreference) == "function",
    "the radio card requires the durable companion owner"
  )
  assert(type(opts.catalog) == "table", "the radio card borrows its compiled asset family")
  assert(
    type(opts.program) == "table"
      and type(opts.program.begin) == "function"
      and type(opts.program.setSignal) == "function"
      and type(opts.program.endProgram) == "function"
      and type(opts.program.closeStation) == "function",
    "the radio card requires its broadcast program"
  )
  assert(
    type(opts.reception) == "table" and type(opts.reception.forContext) == "function",
    "the radio card requires its channel selection policy"
  )
  assert(type(opts.presentation) == "table", "the radio card borrows its presentation owner")
  assert(type(opts.map) == "table", "the radio card borrows its live map facts")
  assert(type(opts.flags) == "table", "the radio card borrows its live story flags")
  assert(opts.effect == nil or type(opts.effect) == "function", "the radio sound boundary must be a function")
  local preferences = opts.state:readPreferences()
  assert(type(preferences) == "table", "the radio card reads its saved preferences")
  local saved = preferences.radioCursor
  assert(
    type(saved) == "table" and type(saved.x) == "number" and type(saved.y) == "number",
    "the radio card reads its remembered tuner position"
  )
  -- The remembered cursor is not a playing station: the channel table is
  -- known from construction, but the tracked selection stays silent until
  -- input moves the tuner or the table itself changes.
  local initialKey = opts.reception.forContext(opts.map, opts.flags)
  assert(type(initialKey) == "string", "channel selection names its reception table")
  return setmetatable({
    _state = opts.state,
    _catalog = opts.catalog,
    _program = opts.program,
    _reception = opts.reception,
    _presentation = opts.presentation,
    _map = opts.map,
    _flags = opts.flags,
    _cursor = { x = saved.x, y = saved.y },
    _effect = opts.effect,
    _receptionKey = initialKey,
    _moved = false,
    _selectedButton = 3,
    _station = NO_STATION,
    _signal = 0,
    _dragging = false,
    _dragId = nil,
    _disposed = false,
  }, RadioController)
end

-- Recomputes the tuned station from the cursor under the given channel
-- table and runs the source station lifecycle: a same-station signal
-- change only alters static, a changed station tears down once and opens
-- anew, and leaving every station closes the show with a music stop.
---@param key string
function RadioController:_recompute(key)
  assert(type(key) == "string", "channel selection names its reception table")
  local cursor = self._cursor
  assert(type(cursor) == "table", "the tuner keeps its cursor")
  local station, signal = resolveTuning(key, cursor.x, cursor.y)
  local program = self._program
  assert(type(program) == "table", "the tuner keeps its program")
  if station == NO_STATION then
    if self._signal ~= 0 then
      program:closeStation()
    end
    self._station = NO_STATION
    self._signal = 0
    return
  end
  local signalName = "weak"
  if signal == 2 then
    signalName = "clear"
  end
  if station == self._station then
    if signal ~= self._signal then
      program:setSignal(signalName)
    end
    self._signal = signal
    return
  end
  if self._station ~= NO_STATION then
    program:endProgram()
  end
  program:begin(station, signalName)
  self._station = station
  self._signal = signal
end

---@param direction string
---@return integer dx, integer dy
local function keySpeed(direction)
  local dx, dy = 0, 0
  if direction:find("left", 1, true) ~= nil then
    dx = -2
  elseif direction:find("right", 1, true) ~= nil then
    dx = 2
  end
  if direction:find("up", 1, true) ~= nil then
    dy = -2
  elseif direction:find("down", 1, true) ~= nil then
    dy = 2
  end
  return dx, dy
end

-- One held-key update: two source pixels per axis, X first with per-axis
-- rim gating where each pixel step is checked separately and the vertical
-- check reads the updated horizontal position. A blocked axis never drags
-- the other one along.
---@param dx integer
---@param dy integer
function RadioController:_walk(dx, dy)
  local cursor = self._cursor
  assert(type(cursor) == "table", "key motion reads the tuner position")
  local stepX = 0
  if dx > 0 then
    stepX = 1
  elseif dx < 0 then
    stepX = -1
  end
  for _ = 1, math.abs(dx) do
    if insideStrict(cursor.x + stepX, cursor.y, TUNING_CENTER_X, TUNING_CENTER_Y, TUNING_RADIUS) then
      cursor.x = cursor.x + stepX
    else
      break
    end
  end
  local stepY = 0
  if dy > 0 then
    stepY = 1
  elseif dy < 0 then
    stepY = -1
  end
  for _ = 1, math.abs(dy) do
    if insideStrict(cursor.x, cursor.y + stepY, TUNING_CENTER_X, TUNING_CENTER_Y, TUNING_RADIUS) then
      cursor.y = cursor.y + stepY
    else
      break
    end
  end
end

-- The source UI tones on the radio card: the back key, the A preset
-- step, and grabbing the tuner. Dial walks and drag motion retune
-- silently behind the broadcast program's own audio.
local CURSOR_SOUND = "SEQ_SE_GS_GEARCURSOR"
local CANCEL_SOUND = "SEQ_SE_GS_GEARCANCEL"

---@param self RadioController
---@param sequence string
local function playEffect(self, sequence)
  if self._effect ~= nil then
    self._effect(sequence)
  end
end

---@param event table<string, unknown>
function RadioController:_handle(event)
  if event.type == "navigate" and type(event.direction) == "string" then
    local dx, dy = keySpeed(event.direction)
    if dx ~= 0 or dy ~= 0 then
      local cursor = self._cursor
      assert(type(cursor) == "table", "key motion reads the tuner position")
      local beforeX, beforeY = cursor.x, cursor.y
      self:_walk(dx, dy)
      if cursor.x ~= beforeX or cursor.y ~= beforeY then
        self._moved = true
      end
    end
  elseif event.type == "confirm" then
    self._selectedButton = (self._selectedButton + 1) % 4
    local center = PRESET_CENTERS[self._selectedButton + 1]
    assert(type(center) == "table", "preset buttons snap through the fixed center table")
    self._cursor = { x = center.x, y = center.y }
    self._moved = true
    playEffect(self, CURSOR_SOUND)
  elseif event.type == "cancel" then
    -- The back key returns focus to the shell: the running show, latch,
    -- and tuner all survive. The shell owns dismissal.
    playEffect(self, CANCEL_SOUND)
  elseif event.type == "pointer_down" and type(event.x) == "number" and type(event.y) == "number" then
    local cursor = self._cursor
    assert(type(cursor) == "table", "touch input reads the tuner position")
    if
      insideStrict(event.x, event.y, TUNING_CENTER_X, TUNING_CENTER_Y, TUNING_RADIUS)
      and insideStrict(event.x, event.y, cursor.x, cursor.y, PRESS_RADIUS)
    then
      self._cursor = { x = event.x, y = event.y }
      self._dragging = true
      self._dragId = event.pointerId
      self._moved = true
      playEffect(self, CURSOR_SOUND)
    end
  elseif event.type == "pointer_move" and type(event.x) == "number" and type(event.y) == "number" then
    if self._dragging and event.pointerId == self._dragId and insideTuningRim(event.x, event.y) then
      self._cursor = { x = event.x, y = event.y }
      self._moved = true
    end
  elseif event.type == "pointer_up" then
    if self._dragging and event.pointerId == self._dragId then
      self._dragging = false
      self._dragId = nil
    end
  end
end

-- One fixed tick over the shell input list. The station recomputes when
-- input moved the tuner or the channel table itself changed, so story and
-- signal changes apply without new input while idle ticks with an
-- unchanged selection touch neither show nor audio.
---@param uiInput table[]
function RadioController:updateFixed(uiInput)
  assert(not self._disposed, "a disposed radio card steps nothing")
  assert(type(uiInput) == "table", "the radio card input must be an event list")
  for _, event in ipairs(uiInput) do
    if type(event) == "table" and type(event.type) == "string" then
      self:_handle(event)
    end
  end
  local reception = self._reception
  assert(type(reception) == "table", "the tuner keeps its channel policy")
  local key = reception.forContext(self._map, self._flags)
  assert(type(key) == "string", "channel selection names its reception table")
  if self._moved or key ~= self._receptionKey then
    self._receptionKey = key
    self._moved = false
    self:_recompute(key)
  end
end

-- The detached tuner selection: station, signal, and cursor. Fresh tables
-- per call; status performs no mutation.
---@return { station: integer, signal: integer, cursor: { x: integer, y: integer } }
function RadioController:status()
  local cursor = self._cursor
  assert(type(cursor) == "table", "the tuner publishes its cursor")
  return {
    station = self._station,
    signal = self._signal,
    cursor = { x = cursor.x, y = cursor.y },
  }
end

-- The radio card never closes itself: the shell owns dismissal, and the
-- back key only returns focus.
---@return nil
function RadioController:takeResult()
  return nil
end

-- Idempotent release of the card lifetime: persists the tuner position at
-- the source commit point and tears the show down while normal music may
-- continue through the audio owner afterward.
function RadioController:dispose()
  if self._disposed then
    return
  end
  local cursor = self._cursor
  assert(type(cursor) == "table", "unloading persists the tuner position")
  self._state:setPreference("radioCursor", { x = cursor.x, y = cursor.y })
  self._program:endProgram()
  self._disposed = true
end

return RadioController
