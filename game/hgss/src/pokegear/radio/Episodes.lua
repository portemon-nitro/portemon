-- The six episodic broadcasts: talk, search party, serial drama, the
-- password show, trainer profiles, and town people. Each program keeps its
-- own table, condition, draw, and effect semantics behind one shared
-- line-printing shape; semantically different programs are never collapsed
-- to one line loop.

local RadioWorldContext = require("game.hgss.src.pokegear.RadioWorldContext")

---@class RadioEpisodeShow
---@field key string
---@field title string?
---@field host string?
---@field printer table<string, unknown>
---@field episodeId integer
---@field update fun(self: RadioEpisodeShow)
local Episodes = {}

Episodes.TALK_KEY = "radio.talk"
Episodes.SEARCH_PARTY_KEY = "radio.search-party"
Episodes.SERIAL_DRAMA_KEY = "radio.serial-drama"
Episodes.BUENA_KEY = "radio.buena"
Episodes.TRAINER_PROFILES_KEY = "radio.trainer-profiles"
Episodes.TOWN_PEOPLE_KEY = "radio.town-people"

Episodes.JINGLE_SEQUENCE = "radio.talk.jingle"

local TALK_TITLE_BANK, TALK_TITLE_ENTRY = 501, 1
local TALK_INTRO_BANK, TALK_INTRO_ENTRY = 501, 2
local TALK_OUTBREAK_BANK, TALK_OUTBREAK_ENTRY = 501, 3
local TALK_DETAIL_BANK, TALK_DETAIL_ENTRY = 501, 5
local TALK_PAIR_BANK, TALK_PAIR_COUNT = 502, 5
local TALK_PAIR_BASE = 1

local SEARCH_TITLE_BANK, SEARCH_TITLE_ENTRY = 503, 1
local SEARCH_LINES_BANK, SEARCH_FIRST_ENTRY, SEARCH_LINE_COUNT = 503, 2, 4
local DRAMA_TITLE_BANK, DRAMA_TITLE_ENTRY = 504, 1
local DRAMA_LINES_BANK, DRAMA_FIRST_ENTRY, DRAMA_LINE_COUNT = 504, 2, 4
local PROFILES_TITLE_BANK, PROFILES_TITLE_ENTRY = 505, 1
local PROFILES_LINES_BANK, PROFILES_FIRST_ENTRY, PROFILES_LINE_COUNT = 505, 2, 4
local TOWN_TITLE_BANK, TOWN_TITLE_ENTRY = 506, 1
local TOWN_LINES_BANK, TOWN_FIRST_ENTRY, TOWN_LINE_COUNT = 506, 2, 4

local BUENA_INTRO_BANK, BUENA_INTRO_ENTRY = 411, 1
local BUENA_CONTINUE_BANK, BUENA_CONTINUE_ENTRY = 411, 2
local BUENA_MESSAGE4_BANK, BUENA_MESSAGE4_ENTRY = 411, 3
local BUENA_TOKEN_BANK, BUENA_TOKEN_BASE = 66, 40
local BUENA_REPLY_BANK = 411
local BUENA_REPLY_WITH_CARD, BUENA_REPLY_WITHOUT_CARD = 4, 5
-- The heard flag commits when the third pushed line (the message that
-- initializes the password answer) prints, never at tune or title time.
local BUENA_HEARD_LINE = 3

local BUENA_CARD_ITEM = "BLUE_CARD"

-- Talk landmark selection: the eligible landmark token set with its
-- explicit filter list and the flypoint-gated tokens. The gated tokens
-- stay shut without the real flypoint facts, and the unseen preference
-- keeps table order while no dex-seen facts are recorded.
local TALK_LANDMARKS = { 3, 5, 6, 9, 11, 14, 15, 19, 21, 22, 26, 29, 47, 48 }
local TALK_FILTERED = { [9] = true, [22] = true }
local TALK_GATED = { [47] = true, [48] = true }
local TALK_STEP_DIVISOR = 3
local TALK_PHRASE_MODULO = 13
local TALK_SPECIES_TOKENS = 493

---@param services table<string, unknown>
---@return table<string, unknown> messages, table<string, unknown> printer
local function lineServices(services)
  local messages = assert(services.messages, "episodic broadcasts need a message formatter")
  assert(type(messages) == "table", "episodic broadcasts keep a message formatter")
  assert(type(messages.line) == "function", "the message formatter answers line requests")
  local printer = assert(services.printer, "episodic broadcasts need a line printer")
  assert(type(printer) == "table", "episodic broadcasts keep a line printer")
  assert(type(printer.push) == "function", "the line printer queues originals")
  return messages, printer
end

---@param lineText unknown
---@return string
local function originalText(lineText)
  assert(type(lineText) == "table" and type(lineText.text) == "string", "broadcast lines read as text")
  return lineText.text
end

-- Opens one episodic program: its title and host lines are requested at
-- once, its body lines print in order, and its emit and update hooks carry
-- the program-specific effects. Completed programs stay quiescent.
---@param showKey string
---@param services table<string, unknown>
---@param titleRef { bank: integer, entry: integer }
---@param hostRef { bank: integer, entry: integer }?
---@param lineSpecs table<integer, { bank: integer, entry: integer, params: table<string, unknown>? }>
---@param hooks { onEmit: fun(index: integer)?, onUpdate: fun(show: RadioEpisodeShow)?, episodeId: integer? }?
---@return RadioEpisodeShow
local function openProgram(showKey, services, titleRef, hostRef, lineSpecs, hooks)
  local messages, printer = lineServices(services)
  local titleLine = messages:line(titleRef.bank, titleRef.entry)
  local hostText = nil
  if hostRef ~= nil then
    hostText = originalText(messages:line(hostRef.bank, hostRef.entry))
  end
  for _, spec in ipairs(lineSpecs) do
    printer:push(originalText(messages:line(spec.bank, spec.entry, spec.params)))
  end
  if hooks ~= nil and hooks.onEmit ~= nil then
    local emitHook = assert(hooks.onEmit, "episodic broadcasts keep their emit hook")
    local function forwardEmit(index)
      emitHook(index)
    end
    printer.onEmit = forwardEmit
  end
  local show = {
    key = showKey,
    title = originalText(titleLine),
    host = hostText,
    printer = printer,
    episodeId = (hooks ~= nil and hooks.episodeId) or 0,
  }
  function show.update(self)
    if hooks ~= nil and hooks.onUpdate ~= nil then
      local updateHook = assert(hooks.onUpdate, "episodic broadcasts keep their update hook")
      updateHook(self)
    end
  end
  return show --[[@as RadioEpisodeShow]]
end

---@param pool table<integer, integer>
---@param draw integer
---@return integer
local function pickFrom(pool, draw)
  assert(#pool > 0, "talk selections choose from an open landmark pool")
  return pool[(draw % #pool) + 1]
end

-- Builds the talk broadcast lines: the introduction, the outbreak
-- announcement only while an outbreak is active, and the five
-- landmark/species pairs with their flavor parameters. Draws stay in
-- update/begin time; reads never draw.
---@param services table<string, unknown>
---@return table<integer, { bank: integer, entry: integer, params: table<string, unknown>? }>
local function buildTalkLines(services)
  local random = assert(services.random, "the talk broadcast needs its draw stream")
  assert(type(random) == "table", "the talk broadcast keeps its draw stream")
  assert(type(random.lc) == "function", "the draw stream answers labelled draws")
  local world = assert(services.world, "the talk broadcast needs its world facts")
  assert(type(world) == "table", "the talk broadcast keeps its world projection")
  assert(type(world.dailySwarm) == "function", "the world projection answers the daily swarm")

  local step = ((random:lc("talk-step") % TALK_STEP_DIVISOR) + 1) * 2
  local phrase1 = random:lc("talk-phrase-1") % TALK_PHRASE_MODULO
  local phrase2 = random:lc("talk-phrase-2") % TALK_PHRASE_MODULO
  local pool = {}
  for _, landmark in ipairs(TALK_LANDMARKS) do
    if TALK_FILTERED[landmark] ~= true and TALK_GATED[landmark] ~= true then
      pool[#pool + 1] = landmark
    end
  end

  local specs = {
    { bank = TALK_INTRO_BANK, entry = TALK_INTRO_ENTRY },
  }
  local swarm = world:dailySwarm()
  assert(type(swarm) == "table", "the daily swarm reads as a record")
  if swarm.active == true then
    local info = RadioWorldContext.swarmInfoFromSeed(assert(swarm.seed, "an active outbreak carries its seed"))
    specs[#specs + 1] = {
      bank = TALK_OUTBREAK_BANK,
      entry = TALK_OUTBREAK_ENTRY,
      params = { species = info.species, landmark = info.landmark },
    }
    specs[#specs + 1] = {
      bank = TALK_DETAIL_BANK,
      entry = TALK_DETAIL_ENTRY,
      params = { species = info.species, landmark = info.landmark },
    }
  end
  for pair = 1, TALK_PAIR_COUNT do
    local landmark = pickFrom(pool, random:lc("talk-pair-" .. pair))
    local species = (random:lc("talk-species-" .. pair) % TALK_SPECIES_TOKENS) + 1
    specs[#specs + 1] = {
      bank = TALK_PAIR_BANK,
      entry = TALK_PAIR_BASE + pair - 1,
      params = {
        landmark = landmark,
        species = species,
        step = step,
        phrase1 = (phrase1 + (pair - 1) * step) % TALK_PHRASE_MODULO,
        phrase2 = (phrase2 + (pair - 1) * step) % TALK_PHRASE_MODULO,
      },
    }
  end
  return specs
end

---@param showKey string
---@param services table<string, unknown>
---@return RadioEpisodeShow
local function newTalk(showKey, services)
  assert(showKey == Episodes.TALK_KEY, "the talk broadcast opens its own show")
  local audio = assert(services.audio, "the talk broadcast needs its audio facade")
  assert(type(audio) == "table", "the talk broadcast keeps its audio facade")
  local jingled = false
  local function playJingleOnComplete(show)
    if jingled then
      return
    end
    local printer = show.printer
    assert(type(printer) == "table", "the talk broadcast keeps its line printer")
    local state = printer.state
    assert(type(state) == "function", "the line printer reports its progress")
    if state(printer).complete ~= true then
      return
    end
    local playRadio = audio.playRadio
    assert(type(playRadio) == "function", "the audio facade starts radio sequences")
    jingled = playRadio(audio, Episodes.JINGLE_SEQUENCE) == true
  end
  return openProgram(
    showKey,
    services,
    { bank = TALK_TITLE_BANK, entry = TALK_TITLE_ENTRY },
    {
      bank = TALK_INTRO_BANK,
      entry = TALK_INTRO_ENTRY,
    },
    buildTalkLines(services),
    {
      episodeId = 0,
      onUpdate = playJingleOnComplete,
    }
  )
end

---@param bank integer
---@param firstEntry integer
---@param lineCount integer
---@param episode integer
---@return table<integer, { bank: integer, entry: integer, params: table<string, unknown>? }>
local function serialLines(bank, firstEntry, lineCount, episode)
  local specs = {}
  for line = 1, lineCount do
    specs[#specs + 1] = { bank = bank, entry = firstEntry + line - 1, params = { episode = episode } }
  end
  return specs
end

---@param services table<string, unknown>
---@param slots integer
---@return integer
local function dateEpisode(services, slots)
  assert(slots > 0, "serial broadcasts select from a non-empty episode rotation")
  local clock = assert(services.clock, "serial broadcasts need their civil clock")
  assert(type(clock) == "table", "serial broadcasts keep their civil clock")
  local now = clock.nowLocal
  assert(type(now) == "function", "the civil clock answers local samples")
  local sample = now(clock)
  assert(type(sample) == "table" and type(sample.day) == "number", "civil samples carry their day")
  return math.floor(sample.day % slots)
end

---@param showKey string
---@param services table<string, unknown>
---@return RadioEpisodeShow
local function newSearchParty(showKey, services)
  assert(showKey == Episodes.SEARCH_PARTY_KEY, "the search party opens its own show")
  local episode = dateEpisode(services, 4)
  return openProgram(showKey, services, { bank = SEARCH_TITLE_BANK, entry = SEARCH_TITLE_ENTRY }, {
    bank = SEARCH_LINES_BANK,
    entry = SEARCH_FIRST_ENTRY,
  }, serialLines(SEARCH_LINES_BANK, SEARCH_FIRST_ENTRY, SEARCH_LINE_COUNT, episode), { episodeId = episode })
end

---@param showKey string
---@param services table<string, unknown>
---@return RadioEpisodeShow
local function newSerialDrama(showKey, services)
  assert(showKey == Episodes.SERIAL_DRAMA_KEY, "the serial drama opens its own show")
  local episode = dateEpisode(services, 6)
  return openProgram(showKey, services, { bank = DRAMA_TITLE_BANK, entry = DRAMA_TITLE_ENTRY }, {
    bank = DRAMA_LINES_BANK,
    entry = DRAMA_FIRST_ENTRY,
  }, serialLines(DRAMA_LINES_BANK, DRAMA_FIRST_ENTRY, DRAMA_LINE_COUNT, episode), { episodeId = episode })
end

---@param showKey string
---@param services table<string, unknown>
---@return RadioEpisodeShow
local function newBuena(showKey, services)
  assert(showKey == Episodes.BUENA_KEY, "the password show opens its own broadcast")
  local world = assert(services.world, "the password show needs its world facts")
  assert(type(world) == "table", "the password show keeps its world projection")
  assert(type(world.buenaPassword) == "function", "the world projection answers the password identity")
  assert(type(world.hasItem) == "function", "the world projection answers inventory facts")
  assert(type(world.markBuenaHeard) == "function", "the world projection commits the heard flag")
  local password = math.floor(world:buenaPassword())
  assert(
    type(password) == "number" and password % 1 == 0 and password >= 0 and password < 30,
    "the broadcast password stays a thirty-entry index"
  )
  local withCard = world:hasItem(BUENA_CARD_ITEM, 1) == true
  local reply = withCard and BUENA_REPLY_WITH_CARD or BUENA_REPLY_WITHOUT_CARD
  local function commitHeardOnMessage(index)
    if index == BUENA_HEARD_LINE then
      world:markBuenaHeard()
    end
  end
  return openProgram(showKey, services, { bank = BUENA_INTRO_BANK, entry = BUENA_INTRO_ENTRY }, {
    bank = BUENA_CONTINUE_BANK,
    entry = BUENA_CONTINUE_ENTRY,
  }, {
    { bank = BUENA_INTRO_BANK, entry = BUENA_INTRO_ENTRY },
    { bank = BUENA_CONTINUE_BANK, entry = BUENA_CONTINUE_ENTRY },
    { bank = BUENA_MESSAGE4_BANK, entry = BUENA_MESSAGE4_ENTRY },
    {
      bank = BUENA_TOKEN_BANK,
      entry = BUENA_TOKEN_BASE + password,
      params = { password = password },
    },
    { bank = BUENA_REPLY_BANK, entry = reply, params = { password = password } },
  }, {
    episodeId = password,
    onEmit = commitHeardOnMessage,
  })
end

---@param showKey string
---@param services table<string, unknown>
---@return RadioEpisodeShow
local function newTrainerProfiles(showKey, services)
  assert(showKey == Episodes.TRAINER_PROFILES_KEY, "trainer profiles open their own show")
  return openProgram(showKey, services, { bank = PROFILES_TITLE_BANK, entry = PROFILES_TITLE_ENTRY }, {
    bank = PROFILES_LINES_BANK,
    entry = PROFILES_FIRST_ENTRY,
  }, serialLines(PROFILES_LINES_BANK, PROFILES_FIRST_ENTRY, PROFILES_LINE_COUNT, 0), { episodeId = 0 })
end

---@param showKey string
---@param services table<string, unknown>
---@return RadioEpisodeShow
local function newTownPeople(showKey, services)
  assert(showKey == Episodes.TOWN_PEOPLE_KEY, "town people open their own show")
  return openProgram(showKey, services, { bank = TOWN_TITLE_BANK, entry = TOWN_TITLE_ENTRY }, {
    bank = TOWN_LINES_BANK,
    entry = TOWN_FIRST_ENTRY,
  }, serialLines(TOWN_LINES_BANK, TOWN_FIRST_ENTRY, TOWN_LINE_COUNT, 0), { episodeId = 0 })
end

-- Opens one of the six episodic broadcasts by its semantic show key. The
-- mapping is fixed; unknown keys are a programming error, never a quiet
-- generic broadcast.
---@param showKey string
---@param services table<string, unknown>
---@return RadioEpisodeShow
function Episodes.newShow(showKey, services)
  if showKey == Episodes.TALK_KEY then
    return newTalk(showKey, services)
  end
  if showKey == Episodes.SEARCH_PARTY_KEY then
    return newSearchParty(showKey, services)
  end
  if showKey == Episodes.SERIAL_DRAMA_KEY then
    return newSerialDrama(showKey, services)
  end
  if showKey == Episodes.BUENA_KEY then
    return newBuena(showKey, services)
  end
  if showKey == Episodes.TRAINER_PROFILES_KEY then
    return newTrainerProfiles(showKey, services)
  end
  if showKey == Episodes.TOWN_PEOPLE_KEY then
    return newTownPeople(showKey, services)
  end
  error("unknown episodic broadcast " .. tostring(showKey), 0)
end

return Episodes
