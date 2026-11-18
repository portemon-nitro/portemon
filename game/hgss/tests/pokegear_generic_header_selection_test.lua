-- Generic header-table selection for trainer calls: the compiled
-- outgoing/incoming tables resolve through the source gates in order,
-- terminators report the empty script, and script types 1 and 2 draw the
-- chatter species pair from trainer parties and encounter slots.
-- Deterministic draws replay the companion streams with no hidden
-- randomness.

local Assert = require("tests.support.Assert")
local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
local PokegearState = require("libs.hgss.src.save.PokegearState")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

local CONTACT = "custom.trainer-joey"

-- A source header table pads to its eight rows with the 255 terminator
-- gate, so scenarios name only the rows they exercise.
---@param rows table[]
---@return table[] eight-row source header table
local function headerTable(rows)
  local table_ = {}
  for index = 1, 8 do
    table_[index] = rows[index] or { 255, 0, 0, 0 }
  end
  assert(#rows <= 8, "a source header table never exceeds its eight rows")
  return table_
end

---@param headers table? compiled generic header tables or nil
---@return table catalog
local function fixtureCatalog(headers)
  return {
    contacts = {
      {
        key = CONTACT,
        family = "trainer",
        id = 10,
        entryType = 0,
        trainerClass = 2,
        trainerId = 8,
        mapId = 34,
        gift = 45,
        phoneScriptIfLocal = 29,
        greetingMsgSet = 0,
        rematchWeekday = 1,
        rematchTimeOfDay = 1,
        randomCallGroup = 1,
        genericHeaders = headers,
      },
    },
    contactOrder = { CONTACT },
    locations = { { key = "custom.new-bark" } },
    callDefinitions = {
      [30] = { kind = "none" },
      [33] = { kind = "rematch" },
      [34] = { kind = "rematch" },
      [35] = { kind = "none" },
    },
  }
end

---@return table messages stub resolving script lines and the call greeting
local function fixtureMessages()
  return {
    greeting = "greet",
    resolveLine = function(_, _, scriptId)
      return { tokens = { { kind = "glyph", text = "line" .. scriptId } } }
    end,
    resolveContactEntry = function(_, _, entry)
      return { tokens = { { kind = "glyph", text = "entry" .. entry } } }
    end,
    resolveCallGreeting = function(_, _, _, _)
      return { tokens = { { kind = "glyph", text = "greet" } } }
    end,
    resolvePhoneUiMessage = function(_, id)
      return { text = "hang" .. id, tokens = { { kind = "glyph", text = "h" } } }
    end,
  }
end

---@param gateFacts table frozen gate facts behind callFacts
---@param species table? species draw recorders and pools
---@return table world stub
local function fixtureWorld(gateFacts, species)
  return {
    nativeSelectorFacts = function()
      return { localMap = false }
    end,
    callFacts = function()
      local facts = { localMap = false }
      for key, value in pairs(gateFacts or {}) do
        facts[key] = value
      end
      return facts
    end,
    queryRematch = function()
      return nil
    end,
    trainerPartySpecies = function(_, trainerId)
      if species ~= nil then
        species.trainer = trainerId
      end
      return (species and species.party) or { "rattata", "rattata" }
    end,
    encounterSpecies = function(_, mapId, band, class)
      if species ~= nil then
        species.map, species.band, species.class = mapId, band, class
      end
      return (species and species.slots) or { "rattata", "pidgey" }
    end,
    textSpeed = "mid",
  }
end

-- Opens one generic-header call over the real engine: the compiled
-- catalog, the state owner, and the two source dial stages settle before
-- the header resolves, so every scenario starts at its branch.
---@param opts { seed: integer, headers: table?, gateFacts: table?, species: table?, direction: string?, definitions: table?, world: table?, messages: table?, prepare: fun(state: table)? }
---@return table call, table handle, table state, table world
local function openCall(opts)
  local catalog = fixtureCatalog(opts.headers)
  if opts.definitions ~= nil then
    catalog.callDefinitions = opts.definitions
  end
  local state = PokegearState.new({ seed = opts.seed }, { catalog = catalog } --[[catalog refs]])
  state:registerContact(CONTACT)
  if opts.prepare ~= nil then
    opts.prepare(state)
  end
  local world = opts.world or fixtureWorld(opts.gateFacts, opts.species)
  local call = PhoneCall.new({
    state = state,
    catalog = catalog,
    messages = opts.messages or fixtureMessages(),
    world = world,
    random = PokegearRandom.new(opts.seed),
  })
  local handle = call:begin({
    id = "generic-1",
    contact = CONTACT,
    direction = opts.direction or "outgoing",
    kind = "ordinary",
  })
  call:step(handle, {})
  call:step(handle, {})
  return call, handle, state, world
end

-- A passing rematch gate resolves its script: tower cleared, seeking
-- staged, weekday and time inside the window.
function T.tests.rematch_gate_resolves_its_script()
  local world = fixtureWorld({ towerCleared = true, weekday = 1, timeOfDay = 1 })
  world.queryRematch = function()
    return { stage = 1, wins = 0 }
  end
  local call, handle = openCall({
    seed = 7,
    headers = { outgoing = headerTable({ { 2, 100, 0, 34 } }), incoming = headerTable({}) },
    world = world,
  })
  local view = call:view(handle)
  Assert.equal(view.stage, "message", "the passing gate reaches its message")
  Assert.isNil(view.result, "the resolved script plays instead of failing")
end

-- Seeking callers skip the plain rematch gate: the gift gate below wins
-- instead when a staged gift is present.
function T.tests.seeking_callers_skip_the_plain_rematch_gate()
  local gateWorld = fixtureWorld({ towerCleared = true })
  gateWorld.queryRematch = function()
    return { stage = 1, wins = 0 }
  end
  local call, handle = openCall({
    seed = 7,
    headers = {
      outgoing = headerTable({ { 2, 100, 0, 34 }, { 8, 100, 0, 30 } }),
      incoming = headerTable({}),
    },
    world = gateWorld,
    prepare = function(state)
      state:setContactReward(CONTACT, { item = "POTION", quantity = 1 })
    end,
  })
  local view = call:view(handle)
  Assert.equal(view.stage, "message", "the gift gate wins after the rematch gate fails")
  Assert.isNil(view.result, "the gift script plays instead of failing")
end

-- The window, contest-day, and takeover gates each resolve their
-- script when their facts hold, and fall through otherwise.
function T.tests.window_contest_and_takeover_gates_read_their_facts()
  local definitions = {
    [30] = { kind = "none" },
    [33] = { kind = "rematch" },
    [34] = { kind = "rematch" },
    [35] = { kind = "none" },
    [40] = { kind = "none" },
    [41] = { kind = "none" },
    [42] = { kind = "none" },
  }
  local gatedRows = { { 3, 100, 0, 40 }, { 4, 100, 0, 41 }, { 5, 100, 0, 42 }, { 1, 100, 0, 30 } }
  local function resolveWith(facts)
    local call, handle = openCall({
      seed = 7,
      headers = { outgoing = headerTable(gatedRows), incoming = headerTable({}) },
      gateFacts = facts,
      definitions = definitions,
    })
    return call:view(handle)
  end
  local window = resolveWith({ towerCleared = true, weekday = 1, timeOfDay = 1 })
  Assert.equal(window.stage, "message", "the rematch window resolves inside its window")
  Assert.equal(window.lines[2].text, "line40", "the window gate selects its script")
  local offWindow = resolveWith({ towerCleared = true, weekday = 2, timeOfDay = 1 })
  Assert.equal(offWindow.stage, "message", "a missed window falls through to the contest row")
  Assert.equal(offWindow.lines[1].text, "greet", "the greeting prints before the script")
  Assert.equal(offWindow.lines[2].text, "line41", "the contest gate selects its script")
  local contest = resolveWith({ towerCleared = true, weekday = 4, timeOfDay = 1 })
  Assert.equal(contest.stage, "message", "a contest day resolves the contest row")
  Assert.equal(contest.lines[2].text, "line41", "a second contest day stays on its row")
  local takeover = resolveWith({ towerCleared = true, weekday = 0, timeOfDay = 1, takeover = true })
  Assert.equal(takeover.stage, "message", "a takeover resolves the takeover row")
  Assert.equal(takeover.lines[2].text, "line42", "the takeover gate selects its script")
end

-- A nil terminator stops the scan and reports the empty script, which
-- fails loudly through the missing definition instead of playing a
-- plausible row.
function T.tests.terminator_reports_the_empty_script()
  local definitions = { [30] = { kind = "none" }, [33] = { kind = "rematch" } }
  local strictMessages = fixtureMessages()
  strictMessages.resolveLine = function(_, _, scriptId)
    if definitions[scriptId] == nil then
      local Errors = require("libs.errors.src.Errors")
      local ScriptErrors = require("libs.script.src.errors")
      local failure = Errors.new(ScriptErrors.FEATURE_UNAVAILABLE, "missing script " .. tostring(scriptId), {})
      error({ code = failure.code, message = failure.message, context = failure.context, domain = "phone" })
    end
    return { tokens = { { kind = "glyph", text = "line" .. scriptId } } }
  end
  local call, handle = openCall({
    seed = 7,
    headers = { outgoing = headerTable({}), incoming = headerTable({}) },
    definitions = definitions,
    messages = strictMessages,
  })
  local view = call:view(handle)
  Assert.notNil(view.result, "the empty script terminates the call instead of playing text")
  assert(view.result ~= nil, "terminal result asserted above")
  Assert.notNil(view.result.error, "the unresolvable script carries its attribution")
end

-- Script types 1 and 2 draw the species pair from the trainer party and
-- the encounter slots and publish it for the text resolver.
function T.tests.chatter_scripts_draw_the_species_pair()
  local species = { party = { "rattata", "pidgey" }, slots = { "caterpie", "weedle" } }
  local messages = fixtureMessages()
  openCall({
    seed = 7,
    headers = { outgoing = headerTable({ { 1, 100, 1, 35 } }), incoming = headerTable({}) },
    gateFacts = { timeOfDay = 1 },
    species = species,
    messages = messages,
  })
  Assert.equal(species.trainer, 8, "the party draw reads the caller trainer number")
  Assert.equal(species.map, 34, "the encounter draw reads the caller map")
  Assert.equal(species.band, "day", "time band one reads the day slots")
  Assert.equal(species.class, 2, "the encounter draw reads the caller class")
  local buffer = messages.speciesStaging
  Assert.notNil(buffer, "the species pair stages through the message facade")
  assert(type(buffer) == "table", "species staging staged above")
  local pair = buffer[CONTACT]
  Assert.notNil(pair, "the buffer carries the caller pair")
  assert(type(pair) == "table", "caller pair published above")
  Assert.isTrue(pair.a == "rattata" or pair.a == "pidgey", "species A comes from the party")
  Assert.isTrue(pair.b == "caterpie" or pair.b == "weedle", "species B comes from the encounter slots")
end

return T
