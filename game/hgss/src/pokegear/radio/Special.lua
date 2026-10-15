-- The five special broadcasts: flute, unown, rocket, mahogany, and the
-- bounded commercial handoff. Each carries its native text and audio
-- sequence with its own return and completion rules; no broadcast mutates
-- unrelated story state.

local Errors = require("libs.errors.src.Errors")

---@class RadioSpecialShow
---@field key string
---@field title string?
---@field host string?
---@field printer table<string, unknown>
---@field episodeId integer
---@field update fun(self: RadioSpecialShow)
local Special = {}

Special.POKE_FLUTE_KEY = "radio.poke-flute"
Special.UNOWN_KEY = "radio.unown"
Special.ROCKET_KEY = "radio.rocket"
Special.MAHOGANY_KEY = "radio.mahogany"
Special.COMMERCIAL_KEY = "radio.commercial"

Special.ERROR = {
  SEQUENCE_UNAVAILABLE = "POKEGEAR_RADIO_SEQUENCE_UNAVAILABLE",
}

local FLUTE_TITLE_BANK, FLUTE_TITLE_ENTRY = 507, 1
local FLUTE_LINES_BANK, FLUTE_FIRST_ENTRY, FLUTE_LINE_COUNT = 507, 2, 2
local FLUTE_SEQUENCE = "radio.flute"
local UNOWN_TITLE_BANK, UNOWN_TITLE_ENTRY = 508, 1
local UNOWN_LINES_BANK, UNOWN_FIRST_ENTRY, UNOWN_LINE_COUNT = 508, 2, 2
local UNOWN_SEQUENCE = "radio.unown"
local ROCKET_TITLE_BANK, ROCKET_TITLE_ENTRY = 509, 1
local ROCKET_LINES_BANK, ROCKET_FIRST_ENTRY, ROCKET_LINE_COUNT = 509, 2, 2
local ROCKET_TAKEOVER_FIRST_ENTRY = 4
local ROCKET_SEQUENCE = "radio.rocket"
local MAHOGANY_TITLE_BANK, MAHOGANY_TITLE_ENTRY = 510, 1
local MAHOGANY_LINES_BANK, MAHOGANY_FIRST_ENTRY, MAHOGANY_LINE_COUNT = 510, 2, 2
local MAHOGANY_SEQUENCE = "radio.mahogany"

-- The latched audio sequence identities behind the flute and unown shows.
-- Gameplay effects and the script music query resolve through these, never
-- through the show keys above.
Special.FLUTE_SEQUENCE = FLUTE_SEQUENCE
Special.UNOWN_SEQUENCE = UNOWN_SEQUENCE

local COMMERCIAL_TITLE_BANK, COMMERCIAL_TITLE_ENTRY = 511, 1
local COMMERCIAL_LINES_BANK, COMMERCIAL_FIRST_ENTRY, COMMERCIAL_LINE_COUNT = 511, 2, 2
local COMMERCIAL_SEQUENCE = "radio.commercial"

---@param lineText unknown
---@return string
local function originalText(lineText)
  assert(type(lineText) == "table" and type(lineText.text) == "string", "broadcast lines read as text")
  return lineText.text
end

-- Starts one native audio sequence through the facade. A rejected start is
-- an attributed broadcast failure with its show context, never a silent
-- text-only broadcast.
---@param audio table<string, unknown>
---@param showKey string
---@param sequence string
local function startSequence(audio, showKey, sequence)
  local playRadio = audio.playRadio
  assert(type(playRadio) == "function", "the audio facade starts radio sequences")
  if playRadio(audio, sequence) ~= true then
    Errors.raise(
      Special.ERROR.SEQUENCE_UNAVAILABLE,
      "the special broadcast cannot start its sequence",
      { show = showKey, sequence = sequence }
    )
  end
end

-- Opens one special broadcast: its sequence starts at once while its
-- lines print in order. The commercial completes back to its caller; the
-- other specials complete quiescently with their sequence surviving.
---@param showKey string
---@param services table<string, unknown>
---@param titleRef { bank: integer, entry: integer }
---@param lineSpecs table<integer, { bank: integer, entry: integer, params: table<string, unknown>? }>
---@param sequence string
---@return RadioSpecialShow
local function openSpecial(showKey, services, titleRef, lineSpecs, sequence)
  local messages = assert(services.messages, "special broadcasts need a message formatter")
  assert(type(messages) == "table", "special broadcasts keep a message formatter")
  assert(type(messages.line) == "function", "the message formatter answers line requests")
  local audio = assert(services.audio, "special broadcasts need an audio facade")
  assert(type(audio) == "table", "special broadcasts keep an audio facade")
  local printer = assert(services.printer, "special broadcasts need a line printer")
  assert(type(printer) == "table", "special broadcasts keep a line printer")
  assert(type(printer.push) == "function", "the line printer queues originals")

  local titleLine = messages:line(titleRef.bank, titleRef.entry)
  for _, spec in ipairs(lineSpecs) do
    printer:push(originalText(messages:line(spec.bank, spec.entry, spec.params)))
  end
  startSequence(audio, showKey, sequence)

  local show = {
    key = showKey,
    title = originalText(titleLine),
    host = nil,
    printer = printer,
    episodeId = 0,
  }
  function show.update(_) end
  return show --[[@as RadioSpecialShow]]
end

---@param bank integer
---@param firstEntry integer
---@param lineCount integer
---@return table<integer, { bank: integer, entry: integer, params: table<string, unknown>? }>
local function bodyLines(bank, firstEntry, lineCount)
  ---@type table<integer, { bank: integer, entry: integer, params: table<string, unknown>? }>
  local specs = {}
  for line = 1, lineCount do
    specs[#specs + 1] = { bank = bank, entry = firstEntry + line - 1, params = nil }
  end
  return specs
end

---@param showKey string
---@param services table<string, unknown>
---@return RadioSpecialShow
local function newPokeFlute(showKey, services)
  assert(showKey == Special.POKE_FLUTE_KEY, "the flute broadcast opens its own show")
  return openSpecial(
    showKey,
    services,
    { bank = FLUTE_TITLE_BANK, entry = FLUTE_TITLE_ENTRY },
    bodyLines(FLUTE_LINES_BANK, FLUTE_FIRST_ENTRY, FLUTE_LINE_COUNT),
    FLUTE_SEQUENCE
  )
end

---@param showKey string
---@param services table<string, unknown>
---@return RadioSpecialShow
local function newUnown(showKey, services)
  assert(showKey == Special.UNOWN_KEY, "the unown broadcast opens its own show")
  return openSpecial(
    showKey,
    services,
    { bank = UNOWN_TITLE_BANK, entry = UNOWN_TITLE_ENTRY },
    bodyLines(UNOWN_LINES_BANK, UNOWN_FIRST_ENTRY, UNOWN_LINE_COUNT),
    UNOWN_SEQUENCE
  )
end

---@param showKey string
---@param services table<string, unknown>
---@return RadioSpecialShow
local function newRocket(showKey, services)
  assert(showKey == Special.ROCKET_KEY, "the rocket broadcast opens its own show")
  local world = assert(services.world, "the rocket broadcast needs its world facts")
  assert(type(world) == "table", "the rocket broadcast keeps its world projection")
  assert(type(world.rocketTakeover) == "function", "the world projection answers the takeover state")
  local firstEntry = ROCKET_FIRST_ENTRY
  if world:rocketTakeover() == true then
    firstEntry = ROCKET_TAKEOVER_FIRST_ENTRY
  end
  return openSpecial(
    showKey,
    services,
    { bank = ROCKET_TITLE_BANK, entry = ROCKET_TITLE_ENTRY },
    bodyLines(ROCKET_LINES_BANK, firstEntry, ROCKET_LINE_COUNT),
    ROCKET_SEQUENCE
  )
end

---@param showKey string
---@param services table<string, unknown>
---@return RadioSpecialShow
local function newMahogany(showKey, services)
  assert(showKey == Special.MAHOGANY_KEY, "the mahogany broadcast opens its own show")
  return openSpecial(
    showKey,
    services,
    { bank = MAHOGANY_TITLE_BANK, entry = MAHOGANY_TITLE_ENTRY },
    bodyLines(MAHOGANY_LINES_BANK, MAHOGANY_FIRST_ENTRY, MAHOGANY_LINE_COUNT),
    MAHOGANY_SEQUENCE
  )
end

---@param showKey string
---@param services table<string, unknown>
---@return RadioSpecialShow
local function newCommercial(showKey, services)
  assert(showKey == Special.COMMERCIAL_KEY, "the commercial handoff opens its own show")
  return openSpecial(
    showKey,
    services,
    { bank = COMMERCIAL_TITLE_BANK, entry = COMMERCIAL_TITLE_ENTRY },
    bodyLines(COMMERCIAL_LINES_BANK, COMMERCIAL_FIRST_ENTRY, COMMERCIAL_LINE_COUNT),
    COMMERCIAL_SEQUENCE
  )
end

-- Opens one of the five special broadcasts by its semantic show key. The
-- mapping is fixed; unknown keys are a programming error, never a quiet
-- generic broadcast.
---@param showKey string
---@param services table<string, unknown>
---@return RadioSpecialShow
function Special.newShow(showKey, services)
  if showKey == Special.POKE_FLUTE_KEY then
    return newPokeFlute(showKey, services)
  end
  if showKey == Special.UNOWN_KEY then
    return newUnown(showKey, services)
  end
  if showKey == Special.ROCKET_KEY then
    return newRocket(showKey, services)
  end
  if showKey == Special.MAHOGANY_KEY then
    return newMahogany(showKey, services)
  end
  if showKey == Special.COMMERCIAL_KEY then
    return newCommercial(showKey, services)
  end
  error("unknown special broadcast " .. tostring(showKey), 0)
end

return Special
