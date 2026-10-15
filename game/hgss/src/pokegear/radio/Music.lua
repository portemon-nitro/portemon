-- The music broadcast: weekday, dex, and card-gated track selection with
-- the tune-in introduction, the jingle wait, and the after-intro music
-- start. The tune-in sample feeds the introduction; the after-intro sample
-- governs the music selection. Music starts only once the jingle handle
-- completes through the audio facade, never after a hardcoded duration.

local Errors = require("libs.errors.src.Errors")
local PokegearCalendar = require("game.hgss.src.pokegear.PokegearCalendar")

---@class RadioMusicShow
---@field key string
---@field title string?
---@field host string?
---@field printer table<string, unknown>
---@field episodeId integer
---@field update fun(self: RadioMusicShow)
local Music = {}

Music.SHOW_KEY = "radio.music"
Music.JINGLE_SEQUENCE = "radio.music.jingle"
Music.MARCH_SEQUENCE = "radio.music.march"
Music.LULLABY_SEQUENCE = "radio.music.lullaby"
Music.HOENN_SEQUENCE = "radio.music.hoenn"
Music.SINNOH_SEQUENCE = "radio.music.sinnoh"

Music.ERROR = {
  SEQUENCE_UNAVAILABLE = "POKEGEAR_RADIO_SEQUENCE_UNAVAILABLE",
}

local TITLE_BANK, TITLE_ENTRY = 500, 1
local INTRO_BANK, INTRO_ENTRY = 500, 2
local DAY_BANK = 500
local DAY_MARCH, DAY_LULLABY, DAY_HOENN, DAY_SINNOH = 10, 11, 12, 13
local DAY_CARD_SELECTION, DAY_MARCH_ALTERNATE = 14, 15

local CARD_ITEM = "BLUE_CARD"
local CARD_SELECTION_DIVISOR = 25000
local CARD_SELECTION_SLICE = 1000
local CARD_SELECTION_ENTRIES = 25

---@param index integer
---@return string
local function cardSequence(index)
  assert(index >= 0 and index < CARD_SELECTION_ENTRIES, "the card selection stays inside its source table")
  return string.format("radio.music.card.%02d", index + 1)
end

---@param services table<string, unknown>
---@param moment table<string, integer>
---@return string sequence, integer dayEntry
local function selectTrack(services, moment)
  local world = assert(services.world, "the music broadcast reads its world facts")
  assert(type(world) == "table", "the music broadcast keeps its world projection")
  local weekday = PokegearCalendar.weekday(moment)
  if weekday == 0 or weekday == 4 then
    return Music.MARCH_SEQUENCE, DAY_MARCH
  end
  if weekday == 1 or weekday == 5 then
    return Music.LULLABY_SEQUENCE, DAY_LULLABY
  end
  local hasDex = world.hasNationalDex
  assert(type(hasDex) == "function", "the world projection answers the national-dex fact")
  local national = hasDex(world) == true
  if weekday == 2 then
    if national then
      return Music.HOENN_SEQUENCE, DAY_HOENN
    end
    return Music.MARCH_SEQUENCE, DAY_MARCH
  end
  if weekday == 3 then
    if national then
      return Music.SINNOH_SEQUENCE, DAY_SINNOH
    end
    return Music.LULLABY_SEQUENCE, DAY_LULLABY
  end
  assert(weekday == 6, "the music weekday stays inside its seven-day matrix")
  local hasItem = world.hasItem
  assert(type(hasItem) == "function", "the world projection answers inventory facts")
  if hasItem(world, CARD_ITEM, 1) == true then
    local random = assert(services.random, "the card selection draws its source stream")
    assert(type(random) == "table", "the music broadcast keeps its draw stream")
    local draw = random.lc
    assert(type(draw) == "function", "the draw stream answers labelled draws")
    local pick = draw(random, "music-card-selection")
    local index = math.floor((pick % CARD_SELECTION_DIVISOR) / CARD_SELECTION_SLICE)
    assert(index >= 0 and index < CARD_SELECTION_ENTRIES, "the card selection stays inside its source table")
    return cardSequence(index), DAY_CARD_SELECTION
  end
  return Music.MARCH_SEQUENCE, DAY_MARCH_ALTERNATE
end

-- Opens the music broadcast for one tune-in: the introduction prints and
-- the jingle starts at once, while the music selection waits for the
-- after-intro sample at jingle completion.
---@param showKey string
---@param services table<string, unknown>
---@return RadioMusicShow
function Music.newShow(showKey, services)
  assert(showKey == Music.SHOW_KEY, "the music broadcast opens its own show")
  assert(type(services) == "table", "the music broadcast needs its services")
  local messages = assert(services.messages, "the music broadcast needs its message formatter")
  assert(type(messages) == "table", "the music broadcast keeps its message formatter")
  local line = messages.line
  assert(type(line) == "function", "the message formatter answers line requests")
  local audio = assert(services.audio, "the music broadcast needs its audio facade")
  assert(type(audio) == "table", "the music broadcast keeps its audio facade")
  local clock = assert(services.clock, "the music broadcast needs its civil clock")
  assert(type(clock) == "table", "the music broadcast keeps its civil clock")
  local printer = assert(services.printer, "the music broadcast needs its line printer")
  assert(type(printer) == "table", "the music broadcast keeps its line printer")

  local tuneSample = clock.nowLocal(clock)
  local titleLine = line(messages, TITLE_BANK, TITLE_ENTRY)
  assert(type(titleLine) == "table" and type(titleLine.text) == "string", "the title line reads as text")
  local hostLine = line(messages, INTRO_BANK, INTRO_ENTRY)
  assert(type(hostLine) == "table" and type(hostLine.text) == "string", "the host line reads as text")
  local introLine = line(messages, INTRO_BANK, INTRO_ENTRY)
  assert(type(introLine) == "table" and type(introLine.text) == "string", "the intro line reads as text")
  local push = printer.push
  assert(type(push) == "function", "the line printer queues originals")
  push(printer, introLine.text)

  local playRadio = audio.playRadio
  assert(type(playRadio) == "function", "the audio facade starts radio sequences")
  if playRadio(audio, Music.JINGLE_SEQUENCE) ~= true then
    Errors.raise(
      Music.ERROR.SEQUENCE_UNAVAILABLE,
      "the music broadcast cannot start its jingle",
      { show = Music.SHOW_KEY, sequence = Music.JINGLE_SEQUENCE }
    )
  end

  local show = {
    key = Music.SHOW_KEY,
    title = titleLine.text,
    host = hostLine.text,
    printer = printer,
    episodeId = PokegearCalendar.weekday(tuneSample),
    phase = "intro",
  }

  function show.update(self)
    if self.phase ~= "intro" then
      return
    end
    local playing = audio.radioIsPlaying
    assert(type(playing) == "function", "the audio facade reports playback liveness")
    if playing(audio) == true then
      return
    end
    local afterSample = clock.nowLocal(clock)
    local sequence, dayEntry = selectTrack(services, afterSample)
    local dayLine = line(messages, DAY_BANK, dayEntry)
    assert(type(dayLine) == "table" and type(dayLine.text) == "string", "the day line reads as text")
    push(printer, dayLine.text)
    if playRadio(audio, sequence) ~= true then
      Errors.raise(
        Music.ERROR.SEQUENCE_UNAVAILABLE,
        "the music broadcast cannot start its selected track",
        { show = Music.SHOW_KEY, sequence = sequence }
      )
    end
    self.phase = "music"
    self.episodeId = PokegearCalendar.weekday(afterSample)
  end

  return show --[[@as RadioMusicShow]]
end

return Music
