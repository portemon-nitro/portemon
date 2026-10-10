-- Twelve-show broadcast dispatcher and show lifecycle: executable
-- station translation, commercial override with episode-preserving return,
-- line-as-line print progression, and a pure status snapshot. Exactly one
-- program advances at a time; the audio facade owns any surviving sequence
-- across teardown. Reads and draws never advance, draw, or mutate
-- broadcast state.

local Episodes = require("game.hgss.src.pokegear.radio.Episodes")
local Music = require("game.hgss.src.pokegear.radio.Music")
local Special = require("game.hgss.src.pokegear.radio.Special")

---@class RadioProgram
---@field private _catalog table<string, unknown>
---@field private _world table<string, unknown>
---@field private _clock table<string, unknown>
---@field private _random table<string, unknown>
---@field private _audio table<string, unknown>
---@field private _messages table<string, unknown>
---@field private _signal string
---@field private _active table<string, unknown>?
---@field private _suspended table<string, unknown>?
---@field private _lastShow string?
---@field private _lastEpisodeId integer?
---@field private _disposed boolean
local RadioProgram = {}
RadioProgram.__index = RadioProgram

-- Native print progression: the first line waits out the tune-in delay,
-- following lines scroll at the in-episode cadence, and a completed
-- episode settles through its post-episode tail before going quiescent.
local INITIAL_DELAY_FRAMES = 45
local SCROLL_FRAMES = 8
local POST_EPISODE_DELAY_FRAMES = 15
-- Weak reception corrupts the display copy of each printed line under this
-- parameter while the original stays immutable.
local STATIC_PARAMETER = 70

local SIGNAL_CLEAR, SIGNAL_WEAK = "clear", "weak"
local STATION_FIRST, STATION_LAST = 0, 7
local COMMERCIAL_STATIONS = { [2] = true, [3] = true }
local COMMERCIAL_PERIOD, COMMERCIAL_QUOTA = 4, 2

local EPISODE_KEYS = {
  [Episodes.TALK_KEY] = true,
  [Episodes.SEARCH_PARTY_KEY] = true,
  [Episodes.SERIAL_DRAMA_KEY] = true,
  [Episodes.BUENA_KEY] = true,
  [Episodes.TRAINER_PROFILES_KEY] = true,
  [Episodes.TOWN_PEOPLE_KEY] = true,
}

local DISPATCH_KEYS = {
  Music.SHOW_KEY,
  Episodes.TALK_KEY,
  Episodes.SEARCH_PARTY_KEY,
  Episodes.SERIAL_DRAMA_KEY,
  Episodes.BUENA_KEY,
  Episodes.TRAINER_PROFILES_KEY,
  Episodes.TOWN_PEOPLE_KEY,
  Special.POKE_FLUTE_KEY,
  Special.UNOWN_KEY,
  Special.ROCKET_KEY,
  Special.MAHOGANY_KEY,
  Special.COMMERCIAL_KEY,
}

---@param text string
---@return string
local function applyStatic(text)
  local parts = {}
  for index = 1, #text do
    local byte = text:byte(index)
    if index == 1 or (((index * STATIC_PARAMETER) % 100) < STATIC_PARAMETER and byte ~= 42) then
      parts[#parts + 1] = "*"
    else
      parts[#parts + 1] = string.char(byte)
    end
  end
  return table.concat(parts)
end

---@param text string
---@param signal string
---@return string
local function renderLine(text, signal)
  if signal == SIGNAL_WEAK then
    return applyStatic(text)
  end
  return text
end

-- Shared line printer: queues original lines at setup, emits one display
-- line per print event at the native cadence, and retains every display
-- line for later reads. Emission is the only path that creates display
-- lines; signal changes only recorrupt the retained originals.
local Printer = {}
Printer.__index = Printer

---@param signal string
---@return table<string, unknown>
local function newPrinter(signal)
  return setmetatable({
    _originals = {},
    _display = {},
    _emitted = 0,
    _wait = INITIAL_DELAY_FRAMES,
    _tail = 0,
    _complete = false,
    _signal = signal,
    onEmit = nil,
  }, Printer)
end

---@param text string
function Printer:push(text)
  assert(type(text) == "string", "printed lines carry their original text")
  local originals = self._originals
  assert(type(originals) == "table", "the line printer queues originals")
  originals[#originals + 1] = text
  if self._complete == true then
    self._complete = false
    self._tail = 0
  end
end

---@param signal string
function Printer:setSignal(signal)
  assert(signal == SIGNAL_CLEAR or signal == SIGNAL_WEAK, "reception names a native signal")
  self._signal = signal
  local originals = assert(self._originals, "the line printer retains its originals")
  local display = assert(self._display, "the line printer retains its display lines")
  for index = 1, assert(self._emitted, "the line printer counts its emissions") do
    display[index] = renderLine(originals[index], signal)
  end
end

function Printer:tick()
  if self._complete == true then
    return
  end
  local originals = assert(self._originals, "the line printer queues originals")
  if assert(self._emitted, "the line printer counts its emissions") < #originals then
    self._wait = assert(self._wait, "the line printer paces its emissions") - 1
    if self._wait <= 0 then
      self._emitted = self._emitted + 1
      local display = assert(self._display, "the line printer retains its display lines")
      display[self._emitted] = renderLine(originals[self._emitted], assert(self._signal, "reception stays named"))
      if self.onEmit ~= nil then
        self.onEmit(self._emitted)
      end
      self._wait = SCROLL_FRAMES
    end
    return
  end
  self._tail = assert(self._tail, "the line printer settles its episode") + 1
  if self._tail >= POST_EPISODE_DELAY_FRAMES then
    self._complete = true
  end
end

---@return { emitted: integer, total: integer, complete: boolean }
function Printer:state()
  return {
    emitted = assert(self._emitted, "the line printer counts its emissions"),
    total = #(assert(self._originals, "the line printer queues originals")),
    complete = self._complete == true,
  }
end

---@return table<integer, string>
function Printer:displayLines()
  local display = assert(self._display, "the line printer retains its display lines")
  local copy = {}
  for index = 1, assert(self._emitted, "the line printer counts its emissions") do
    copy[#copy + 1] = display[index]
  end
  return copy
end

---@param station integer
---@param hour integer
---@return string
local function translateStation(station, hour)
  assert(
    type(station) == "number" and station % 1 == 0 and station >= STATION_FIRST and station <= STATION_LAST,
    "tuning names a native station"
  )
  assert(type(hour) == "number" and hour % 1 == 0 and hour >= 0 and hour <= 23, "schedules read a civil hour")
  if station == 0 then
    return Music.SHOW_KEY
  end
  if station == 1 then
    return Episodes.TALK_KEY
  end
  if station == 2 then
    if hour % 2 == 0 then
      return Episodes.TRAINER_PROFILES_KEY
    end
    return Episodes.TOWN_PEOPLE_KEY
  end
  if station == 3 then
    local residue = hour % 3
    if residue == 0 then
      return Episodes.SEARCH_PARTY_KEY
    end
    if residue == 1 then
      return Episodes.SERIAL_DRAMA_KEY
    end
    return Episodes.BUENA_KEY
  end
  if station == 4 then
    return Special.POKE_FLUTE_KEY
  end
  if station == 5 then
    return Special.UNOWN_KEY
  end
  if station == 6 then
    return Special.ROCKET_KEY
  end
  assert(station == 7, "tuning names a native station")
  return Special.MAHOGANY_KEY
end

---@param showKey string
---@param services table<string, unknown>
---@return table<string, unknown>
local function openShow(showKey, services)
  if showKey == Music.SHOW_KEY then
    return Music.newShow(showKey, services)
  end
  if EPISODE_KEYS[showKey] == true then
    return Episodes.newShow(showKey, services)
  end
  return Special.newShow(showKey, services)
end

---@param catalog unknown
local function checkCatalog(catalog)
  assert(type(catalog) == "table", "broadcast programs borrow a compiled catalog")
  assert(type(catalog.shows) == "table", "the broadcast catalog carries its show table")
  local keys = {}
  for _, show in ipairs(catalog.shows) do
    assert(type(show) == "table" and type(show.key) == "string", "catalog shows carry semantic keys")
    keys[show.key] = true
  end
  for _, showKey in ipairs(DISPATCH_KEYS) do
    assert(keys[showKey] == true, "the broadcast catalog covers " .. showKey)
  end
end

-- Owns one transient active program over the borrowed companions: the
-- catalog, world facts, civil clock, draw streams, audio facade, and
-- message formatter. The dispatcher mapping is fixed; there is no plugin
-- bus.
---@param opts { catalog: table<string, unknown>, world: table<string, unknown>, clock: table<string, unknown>, random: table<string, unknown>, audio: table<string, unknown>, messages: table<string, unknown> }
---@return RadioProgram
function RadioProgram.new(opts)
  assert(type(opts) == "table", "broadcast programs need their companions")
  checkCatalog(opts.catalog)
  assert(type(opts.world) == "table", "broadcast programs need their world facts")
  assert(
    type(opts.clock) == "table" and type(opts.clock.nowLocal) == "function",
    "broadcast programs need a civil clock"
  )
  assert(type(opts.random) == "table" and type(opts.random.lc) == "function", "broadcast programs need a draw stream")
  local audio = opts.audio
  assert(type(audio) == "table", "broadcast programs need an audio facade")
  assert(type(audio.playRadio) == "function", "the audio facade starts radio sequences")
  assert(type(audio.currentRadioSequence) == "function", "the audio facade reports its sequence latch")
  assert(type(audio.radioIsPlaying) == "function", "the audio facade reports playback liveness")
  assert(
    type(opts.messages) == "table" and type(opts.messages.line) == "function",
    "broadcast programs need a message formatter"
  )
  return setmetatable({
    _catalog = opts.catalog,
    _world = opts.world,
    _clock = opts.clock,
    _random = opts.random,
    _audio = audio,
    _messages = opts.messages,
    _signal = SIGNAL_CLEAR,
    _active = nil,
    _suspended = nil,
    _lastShow = nil,
    _lastEpisodeId = nil,
    _disposed = false,
  }, RadioProgram)
end

function RadioProgram:_clearActive()
  self._active = nil
end

---@param showKey string
---@param signal string
function RadioProgram:_startShow(showKey, signal)
  local printer = newPrinter(signal)
  local show = openShow(showKey, {
    messages = self._messages,
    audio = self._audio,
    random = self._random,
    world = self._world,
    clock = self._clock,
    printer = printer,
  })
  assert(type(show) == "table" and show.key == showKey, "show lifecycles open their own program")
  assert(type(show.printer) == "table", "show lifecycles print through the shared printer")
  self._active = show
  if showKey ~= Special.COMMERCIAL_KEY then
    self._lastShow = showKey
    self._lastEpisodeId = show.episodeId
  end
end

-- Tunes one physical station: samples the civil moment once, observes it
-- into the shared daily identity, and opens the scheduled show. A queued
-- commercial takes precedence exactly once before the tuned station
-- returns with its episode intact. Retuning tears the previous program
-- down exactly once and never stops surviving audio.
---@param station integer
---@param signal string
function RadioProgram:begin(station, signal)
  assert(self._disposed ~= true, "tuning after disposal is a programming error")
  assert(signal == SIGNAL_CLEAR or signal == SIGNAL_WEAK, "tuning names a native signal")
  self:_clearActive()
  self._suspended = nil
  self._signal = signal
  local now = self._clock:nowLocal(self._clock)
  assert(type(now) == "table" and type(now.hour) == "number", "civil samples carry their hour")
  local observe = self._world.observeCivilMoment
  assert(type(observe) == "function", "the world projection observes start boundaries")
  observe(self._world, now)
  self:_startStation(station, signal, now.hour, true)
end

---@param station integer
---@param signal string
---@param hour integer
---@param allowCommercial boolean
function RadioProgram:_startStation(station, signal, hour, allowCommercial)
  local showKey = translateStation(station, hour)
  if allowCommercial == true and COMMERCIAL_STATIONS[station] == true then
    local draw = self._random:lc("commercial-schedule")
    assert(type(draw) == "number", "the commercial schedule draws its source stream")
    if draw % COMMERCIAL_PERIOD < COMMERCIAL_QUOTA then
      self._suspended = { station = station, signal = signal, hour = hour }
      self:_startShow(Special.COMMERCIAL_KEY, signal)
      return
    end
  end
  self:_startShow(showKey, signal)
end

-- Advances one source tick for the active program only. Render reads never
-- arrive here.
function RadioProgram:updateFixed()
  local show = self._active
  if show == nil then
    return
  end
  assert(type(show) == "table", "the active program stays a show lifecycle")
  local step = show.update
  assert(type(step) == "function", "show lifecycles advance one source tick")
  step(show)
  local printer = show.printer
  assert(type(printer) == "table" and type(printer.tick) == "function", "show lifecycles print through the printer")
  printer:tick()
  if show.key ~= Special.COMMERCIAL_KEY then
    return
  end
  local state = printer.state
  assert(type(state) == "function", "the line printer reports its progress")
  if state(printer).complete ~= true then
    return
  end
  local suspended = self._suspended
  self._suspended = nil
  self:_clearActive()
  if suspended ~= nil then
    assert(type(suspended) == "table", "commercials resume their tuned station")
    self:_startStation(suspended.station, suspended.signal, suspended.hour, false)
  end
end

-- Changes reception on the same tuned station without restarting the show
-- or drawing randomness: only the retained display copy recorrupts.
---@param signal string
function RadioProgram:setSignal(signal)
  assert(signal == SIGNAL_CLEAR or signal == SIGNAL_WEAK, "reception names a native signal")
  if signal == self._signal then
    return
  end
  self._signal = signal
  local show = self._active
  if show == nil then
    return
  end
  local printer = show.printer
  assert(
    type(printer) == "table" and type(printer.setSignal) == "function",
    "show lifecycles print through the printer"
  )
  printer:setSignal(signal)
end

-- Pure snapshot of the running program: show identity, title, host,
-- retained display lines, scroll progress, and the audio latch. No
-- mutation, no parsing, no randomness.
---@return { show: string?, title: string?, host: string?, body: table<integer, string>, scroll: { emitted: integer, total: integer, complete: boolean }, sequence: integer|string? }
function RadioProgram:status()
  local latch = self._audio:currentRadioSequence()
  local show = self._active
  if show == nil then
    return {
      show = nil,
      title = nil,
      host = nil,
      body = {},
      scroll = { emitted = 0, total = 0, complete = true },
      sequence = latch,
    }
  end
  local printer = show.printer
  assert(type(printer) == "table", "show lifecycles print through the printer")
  local lines = printer.displayLines
  assert(type(lines) == "function", "the line printer retains its display lines")
  local progress = printer.state
  assert(type(progress) == "function", "the line printer reports its progress")
  return {
    show = show.key,
    title = show.title,
    host = show.host,
    body = lines(printer),
    scroll = progress(printer),
    sequence = latch,
  }
end

-- Ends the running program without stopping its surviving audio: the
-- audio service owns the sequence latch. Idempotent.
function RadioProgram:endProgram()
  self:_clearActive()
  self._suspended = nil
end

-- Releases the dispatcher exactly once. Ending and disposal never stop
-- surviving audio.
function RadioProgram:dispose()
  if self._disposed == true then
    return
  end
  self:_clearActive()
  self._suspended = nil
  self._disposed = true
end

return RadioProgram
