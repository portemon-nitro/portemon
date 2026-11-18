-- Foreground call stage flow: outgoing calls dial behind the connecting
-- wait while incoming calls skip it, every completed conversation waits
-- for a press behind the source SELECT tone before the staged hangup,
-- and maps without signal play the out-of-area flow instead of the
-- conversation. Deterministic fakes; no randomness leaks into the
-- assertions.

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

---@return table catalog with one static trainer contact
local function fixtureCatalog()
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
        greetingMsgSet = 255,
        rematchWeekday = 1,
        rematchTimeOfDay = 1,
        randomCallGroup = 1,
      },
    },
    contactOrder = { CONTACT },
    locations = { { key = "custom.new-bark" } },
    callDefinitions = {
      [29] = { kind = "none" },
    },
  }
end

---@return table messages stub
local function fixtureMessages()
  return {
    greeting = "greet",
    resolveLine = function(_, _, scriptId)
      return { tokens = { { kind = "glyph", text = "line" .. scriptId } } }
    end,
    resolveContactEntry = function(_, _, entry)
      return { tokens = { { kind = "glyph", text = "entry" .. entry } } }
    end,
    resolvePhoneUiMessage = function(_, id)
      return { text = "ui" .. id, tokens = { { kind = "glyph", text = "u" } } }
    end,
  }
end

---@param signaled boolean? map signal behind phoneSignal, nil for no probe
---@param extra table? extra world fields
---@return table world stub
local function fixtureWorld(signaled, extra)
  local world = {
    nativeSelectorFacts = function()
      return { localMap = true }
    end,
    queryRematch = function()
      return nil
    end,
    textSpeed = "mid",
  }
  if signaled ~= nil then
    world.phoneSignal = function()
      return signaled
    end
  end
  for key, value in pairs(extra or {}) do
    world[key] = value
  end
  return world
end

---@param seed integer
---@param direction string
---@param signaled boolean?
---@return table call, table handle, table audio log
local function openCall(seed, direction, signaled)
  local catalog = fixtureCatalog()
  local state = PokegearState.new({ seed = seed }, { catalog = catalog })
  state:registerContact(CONTACT)
  local audio = { dials = 0 }
  audio.playDialing = function()
    audio.dials = audio.dials + 1
  end
  local call = PhoneCall.new({
    state = state,
    catalog = catalog,
    messages = fixtureMessages(),
    world = fixtureWorld(signaled),
    audio = audio,
    random = PokegearRandom.new(seed),
  })
  local handle = call:begin({ id = "stage-1", contact = CONTACT, direction = direction, kind = "ordinary" })
  return call, handle, audio
end

-- Outgoing calls dial the source InitialRing: one PHONE0 tone with the
-- bank271 opening notice (entry 30), then one more tone with its own
-- notice (entry 31), each waiting for the previous tone to finish before
-- the conversation opens. Incoming calls never dial and print none of
-- the dial notices.
function T.tests.incoming_calls_skip_the_connecting_dial()
  local catalog = fixtureCatalog()
  local state = PokegearState.new({ seed = 7 }, { catalog = catalog })
  state:registerContact(CONTACT)
  local audio = { dials = 0, toneFinished = false }
  audio.playDialing = function()
    audio.dials = audio.dials + 1
  end
  audio.isEffectWaitComplete = function()
    return audio.toneFinished
  end
  ---@param direction string
  ---@param id string
  ---@return table call, table handle
  local function open(direction, id)
    local call = PhoneCall.new({
      state = state,
      catalog = catalog,
      messages = fixtureMessages(),
      world = fixtureWorld(true),
      audio = audio,
      random = PokegearRandom.new(7),
    })
    return call,
      call:begin({
        id = id,
        contact = CONTACT,
        direction = direction,
        kind = direction == "incoming" and "incoming" or "ordinary",
      })
  end
  ---@param view table
  ---@return string? first line text
  local function firstLine(view)
    local lines = view.lines
    return type(lines) == "table" and type(lines[1]) == "table" and lines[1].text or nil
  end

  local calls = {}
  local outgoing, handle = open("outgoing", "dial-1")
  calls[#calls + 1] = { outgoing, handle }
  local first = outgoing:view(handle)
  Assert.equal(first.stage, "connecting", "outgoing calls wait on the dial")
  Assert.equal(audio.dials, 1, "the first dial tone opens the call")
  Assert.equal(firstLine(first), "ui30", "the first dial prints the source opening notice")
  outgoing:step(handle, {})
  Assert.equal(audio.dials, 1, "the second tone waits for the first to finish")
  audio.toneFinished = true
  outgoing:step(handle, {})
  local second = outgoing:view(handle)
  Assert.equal(second.stage, "connecting", "the call keeps dialing after the first tone")
  Assert.equal(audio.dials, 2, "the second dial tone follows the first")
  Assert.equal(firstLine(second), "ui31", "the second dial prints its own notice")
  audio.toneFinished = false
  outgoing:step(handle, {})
  Assert.equal(outgoing:view(handle).stage, "connecting", "the conversation waits for the second tone")
  audio.toneFinished = true
  outgoing:step(handle, {})
  Assert.isTrue(outgoing:view(handle).stage ~= "connecting", "the finished dial opens the conversation")

  local dialsBeforeIncoming = audio.dials
  local incoming, inHandle = open("incoming", "dial-2")
  calls[#calls + 1] = { incoming, inHandle }
  local inView = incoming:view(inHandle)
  Assert.equal(inView.stage, "message", "incoming calls start at the conversation")
  Assert.equal(audio.dials, dialsBeforeIncoming, "incoming calls never dial")
  Assert.isTrue(firstLine(inView) ~= "ui30" and firstLine(inView) ~= "ui31", "incoming calls print no dial notice")
  for _, entry in ipairs(calls) do
    entry[1]:release(entry[2])
  end
end

-- One refused call the way the source prints it (PhoneCall_Main states
-- 255-258, the mainState = 0xFF route PhoneCall_InitContext takes when
-- the map refuses the call): the three toneless dial notices (bank271
-- entries 30-32), then the hangup tone with its three click lines
-- (entries 33-35), then the single out-of-area message (entry 37) before
-- a final press. Nothing dials, no conversation opens, and the tone
-- plays once.
---@param direction string incoming or outgoing
---@param kind string semantic call kind the caller requested
---@param id string call identity
local function assertRefusedCallPlaysTheSourceRoute(direction, kind, id)
  local played = {}
  local catalog = fixtureCatalog()
  local state = PokegearState.new({ seed = 7 }, { catalog = catalog })
  state:registerContact(CONTACT)
  local audio = {
    play = function(_, sequence)
      played[#played + 1] = sequence
    end,
  }
  local call = PhoneCall.new({
    state = state,
    catalog = catalog,
    messages = fixtureMessages(),
    world = fixtureWorld(false),
    audio = audio,
    random = PokegearRandom.new(7),
  })
  local handle = call:begin({ id = id, contact = CONTACT, direction = direction, kind = kind })
  Assert.equal(call:view(handle).stage, "noSignal", "a signal-free map opens the refused-call route")
  -- The printed entries in order, deduplicated by page: each staged page
  -- publishes one printable line, and waiting ticks republish it.
  local printed = {}
  local seen = {}
  for _ = 1, 500 do
    local shown = call:view(handle)
    seen[shown.stage] = true
    if type(shown.lines) == "table" then
      for _, line in ipairs(shown.lines) do
        local text = type(line) == "table" and line.text or nil
        if type(text) == "string" and printed[#printed] ~= text then
          printed[#printed + 1] = text
        end
      end
    end
    if shown.result ~= nil then
      break
    end
    call:step(handle, { advance = true })
  end
  Assert.deepEqual(
    printed,
    { "ui30", "ui31", "ui32", "ui33", "ui34", "ui35", "ui37" },
    "the refused call prints the dial notices, the hangup clicks, and one out-of-area message"
  )
  Assert.isTrue(seen.hangingUp, "the refused call runs the staged hangup")
  local hangupTones = 0
  for _, sequence in ipairs(played) do
    Assert.isTrue(sequence ~= PhoneCall.DIAL_SEQUENCE, "the refused call never dials")
    if sequence == PhoneCall.HANGUP_SEQUENCE then
      hangupTones = hangupTones + 1
    end
  end
  Assert.equal(hangupTones, 1, "the refused call plays the hangup tone exactly once")
  local result = assert(call:result(handle), "the refused call terminates")
  Assert.isNil(result.error, "the refused call is not an error")
end

-- A map without signal plays the refused-call route in both
-- directions: PhoneCall_InitContext refuses the call before any
-- conversation, so an incoming caller never hears a greeting either.
function T.tests.signal_free_maps_refuse_both_directions_through_the_out_of_area_flow()
  assertRefusedCallPlaysTheSourceRoute("outgoing", "ordinary", "nosignal-1")
  assertRefusedCallPlaysTheSourceRoute("incoming", "incoming", "incoming-refused-1")
end

local selectorContacts = {
  { key = "custom.elm", family = "elm", messageBank = 716 },
  { key = "custom.kenji", family = "kenji", messageBank = 706 },
  { key = "custom.baoba", family = "baoba", messageBank = 667 },
}
local selectorOrder = {}
for _, contact in ipairs(selectorContacts) do
  selectorOrder[#selectorOrder + 1] = contact.key
end
local selectorCatalog =
  { contacts = selectorContacts, contactOrder = selectorOrder, locations = {}, callDefinitions = {} }

-- The native selector resolves Elm, Kenji, and Baoba branches in
-- source order: Elm walks the badge and flag chain with its two random
-- draws, Kenji walks wait days, the active flag, seeking, and the
-- time-of-day split with its invitation side effect, and Baoba
-- off-map outgoing always resolves through Var4057 with a zero
-- default. Every expectation names a retail script id, never the
-- fallback error.
---@param key string
---@param facts table<string, unknown>
---@param native table<string, unknown>
---@param seed integer?
---@param direction string? incoming or outgoing
---@param worldExtra table<string, unknown>? additional world fields
---@return string[] line texts, table? terminal, table writes
local function drive(key, facts, native, seed, direction, worldExtra)
  local state = PokegearState.new({ seed = seed or 7 }, { catalog = selectorCatalog })
  state:registerContact(key)
  local writes = { rematches = {}, kenjiActive = {}, baobaTriggers = {} }
  local world = {
    nativeSelectorFacts = function()
      return native
    end,
    queryRematch = function()
      return nil
    end,
    setRematch = function(_, contact, record)
      writes.rematches[#writes.rematches + 1] = { contact = contact, record = record }
    end,
    setKenjiActive = function(_, active)
      writes.kenjiActive[#writes.kenjiActive + 1] = active
    end,
    applyBaobaTrigger = function(_, scriptId)
      writes.baobaTriggers[#writes.baobaTriggers + 1] = scriptId
    end,
    textSpeed = "mid",
  }
  for name, value in pairs(facts) do
    world[name] = value
  end
  for name, value in pairs(worldExtra or {}) do
    world[name] = value
  end
  local messages = fixtureMessages()
  local call = PhoneCall.new({
    state = state,
    catalog = selectorCatalog,
    messages = messages,
    world = world,
    audio = { playDialing = function() end },
    random = PokegearRandom.new(seed or 7),
  })
  local handle =
    call:begin({ id = "native-" .. key, contact = key, direction = direction or "outgoing", kind = "ordinary" })
  local texts = {}
  for _ = 1, 40 do
    local view = call:view(handle)
    if type(view.lines) == "table" then
      for _, line in ipairs(view.lines) do
        texts[#texts + 1] = tostring((line --[[@as table]]).text)
      end
    end
    if call:result(handle) ~= nil then
      break
    end
    call:step(handle, { advance = true })
  end
  return texts, call:result(handle), writes
end

---@param texts string[]
---@param ids integer[]
---@param why string
local function seenOneOf(texts, ids, why)
  local wanted = {}
  for _, id in ipairs(ids) do
    wanted["line" .. id] = true
  end
  for _, text in ipairs(texts) do
    if wanted[text] == true then
      return
    end
  end
  error("missing script line (" .. table.concat(texts, ",") .. "): " .. why, 0)
end

function T.tests.native_selector_resolves_elm_kenji_and_baoba_branches_in_source_order()
  local offMap = { localMap = false }
  local namedRival = { localMap = false, gaveRivalName = true }
  local unnamedRival = { localMap = false, gaveRivalName = false }

  local texts = (drive("custom.elm", { panicCall = true }, offMap))
  seenOneOf(texts, { 8 }, "the panic call prints script 8")
  texts = (drive("custom.elm", {}, unnamedRival))
  seenOneOf(texts, { 9 }, "the unnamed rival prints script 9")
  texts = (drive("custom.elm", { eggEvent = true }, namedRival))
  seenOneOf(texts, { 10 }, "the egg call prints script 10")
  texts = (drive("custom.elm", { eggGift = true }, namedRival))
  seenOneOf(texts, { 11 }, "the egg gift prints script 11")
  texts = (drive("custom.elm", { badges = 3 }, namedRival))
  seenOneOf(texts, { 12 }, "an unhatched egg prints script 12")
  texts = (drive("custom.elm", { badges = 3, eggHatched = true }, namedRival))
  seenOneOf(texts, { 13 }, "a hatched egg without the stone prints script 13")
  texts = (drive("custom.elm", { badges = 3, eggHatched = true, everstone = true }, namedRival))
  seenOneOf(texts, { 14, 15 }, "the everstone rolls script 14 or 15")
  texts = (drive("custom.elm", { badges = 7, takeover = true }, namedRival))
  seenOneOf(texts, { 16 }, "the takeover prints script 16")
  texts = (drive("custom.elm", { badges = 7 }, namedRival))
  seenOneOf(texts, { 17 }, "seven badges print script 17")
  texts = (drive("custom.elm", { badges = 8 }, namedRival))
  seenOneOf(texts, { 18 }, "an uncleared game prints script 18")
  texts = (drive("custom.elm", { badges = 8, gameClear = true }, namedRival))
  seenOneOf(texts, { 19 }, "a missing ticket prints script 19")
  texts = (drive("custom.elm", { badges = 8, gameClear = true, ssTicket = true, eggHatched = true }, namedRival))
  seenOneOf(texts, { 13 }, "a hatched egg without the stone prints script 13 late")
  texts = (drive("custom.elm", { badges = 8, gameClear = true, ssTicket = true }, namedRival))
  seenOneOf(texts, { 12 }, "an unhatched egg prints script 12 late")
  texts = (drive("custom.elm", { badges = 8, gameClear = true, ssTicket = true, everstone = true }, namedRival))
  seenOneOf(texts, { 20, 21 }, "an unknown pokerus prints script 20 or 21")
  texts = (
    drive("custom.elm", { badges = 8, gameClear = true, ssTicket = true, everstone = true, pokerus = true }, namedRival)
  )
  seenOneOf(texts, { 20, 21, 22 }, "a known pokerus prints script 20, 21, or 22")

  texts = (drive("custom.kenji", { kenjiWaitDays = 2 }, offMap))
  seenOneOf(texts, { 87 }, "a long wait prints script 87")
  texts = (drive("custom.kenji", { kenjiWaitDays = 1 }, offMap))
  seenOneOf(texts, { 88 }, "a one-day wait prints script 88")
  texts = (drive("custom.kenji", { kenjiWaitDays = 0, kenjiActive = true }, offMap))
  seenOneOf(texts, { 87 }, "an active errand without an invitation prints script 87")
  texts = (drive("custom.kenji", { kenjiWaitDays = 0, timeOfDay = 2 }, offMap))
  seenOneOf(texts, { 91 }, "an evening errand prints script 91")
  local dayTexts, _, dayWrites = drive("custom.kenji", { kenjiWaitDays = 0, timeOfDay = 1 }, offMap)
  seenOneOf(dayTexts, { 90 }, "a day errand prints script 90")
  Assert.equal(#dayWrites.rematches, 1, "the day errand stages its seeking invitation")
  Assert.equal(dayWrites.rematches[1].contact, "custom.kenji", "the invitation names Kenji")
  Assert.deepEqual(dayWrites.kenjiActive, { true }, "the day errand flags its active errand")
  local mornTexts, _, mornWrites = drive("custom.kenji", { kenjiWaitDays = 0, timeOfDay = 0 }, offMap)
  seenOneOf(mornTexts, { 89 }, "a morning errand prints script 89")
  Assert.equal(#mornWrites.rematches, 1, "the morning errand stages its seeking invitation")
  Assert.deepEqual(mornWrites.kenjiActive, { true }, "the morning errand flags its active errand")

  texts = (drive("custom.baoba", {}, offMap))
  seenOneOf(texts, { 147 }, "a missing safari var prints script 147")
  texts = (drive("custom.baoba", { safariTest = 3 }, offMap))
  seenOneOf(texts, { 150 }, "safari var three prints script 150")
end

-- Baoba incoming trigger scripts resolve statically with the selector
-- side effects: 142 stages the safari test through the world hook,
-- anything outside 142..146 falls back to 154, and a missing script
-- id prints the dynamic arrangement instead.
function T.tests.native_selector_applies_baoba_trigger_scripts()
  local incoming = { localMap = false }
  local texts, _, writes = drive("custom.baoba", { predefinedScript = 142 }, incoming, 7, "incoming")
  seenOneOf(texts, { 142 }, "the trigger script prints statically")
  Assert.deepEqual(writes.baobaTriggers, { 142 }, "the selector stages the trigger side effect")
  texts = (drive("custom.baoba", { predefinedScript = 155 }, incoming, 8, "incoming"))
  seenOneOf(texts, { 154 }, "an out-of-range trigger falls back to script 154")
  local arranged = drive("custom.baoba", {}, incoming, 9, "incoming", {
    read = function()
      return { count = 0, names = {} }
    end,
  })
  local found = false
  for _, text in ipairs(arranged) do
    if text == "entry38" then
      found = true
    end
  end
  Assert.isTrue(found, "a missing script id prints the empty arrangement")
  local ScriptErrors = require("libs.script.src.errors")
  local loud, terminal = drive("custom.baoba", { predefinedScript = 143 }, incoming, 10, "incoming", {
    applyBaobaTrigger = function()
      error({
        code = ScriptErrors.FEATURE_UNAVAILABLE,
        message = "phone branch needs its missing safari owner",
        context = { domain = "safari" },
        domain = "safari",
      })
    end,
  })
  Assert.notNil(terminal, "the arrangement-gated trigger terminates")
  local failure = (terminal --[[@as table]]).error
  Assert.notNil(failure, "the ungated trigger reports its missing owner")
  Assert.equal((failure --[[@as table]]).domain, "safari", "the failure names the safari domain")
end

-- The Baoba trigger hook stages Var4057 through the live event state
-- and fails with attribution where the safari arrangement owner is
-- missing: 142 writes test 4 today, 143..146 wait for the safari
-- owner instead of inventing unlock levels.
function T.tests.baoba_trigger_hook_stages_vars_and_names_its_missing_safari_owner()
  local PhoneWorldContext = require("game.hgss.src.pokegear.PhoneWorldContext")
  local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
  local varWrites = {}
  local flags = {
    isFlagSet = function()
      return false
    end,
    getVar = function()
      return 0
    end,
    setVar = function(_, var, value)
      varWrites[#varWrites + 1] = { var = var, value = value }
    end,
  }
  local world = PhoneWorldContext.new({ state = {}, runtime = {}, flags = flags })
  world:applyBaobaTrigger(142)
  local var4057 = FieldScriptSymbols.variablesByName.VAR_UNK_4057
  Assert.deepEqual(varWrites, { { var = var4057, value = 4 } }, "trigger 142 stages safari test 4")
  local ok, failure = pcall(function()
    world:applyBaobaTrigger(143)
  end)
  Assert.isFalse(ok, "a trigger needing unlock levels fails without its safari owner")
  Assert.equal(failure.domain, "safari", "the failure names the safari domain")
  Assert.equal(#varWrites, 1, "the failed trigger writes nothing")
end

return T
