-- Frozen acceptance for win, flee, capture, defeat, and draw result
-- presentation through the cue player: the native result sequence (its
-- message, music transfer, and acknowledgement) plays through ordered
-- playback exactly once, the committed receipt is never duplicated, and
-- the field return never appears early. Native mechanism: the
-- controller/effect/audio/printer barriers complete before the result
-- commits, and the outcome acknowledgement is required only where the
-- source requires it. Headless: hand-built delivery-shaped packets drive
-- the real cue player and the recording sound sink; no dump capability is
-- needed. The setup guards below are green on the current boundary; the
-- result-sequence gates stay red until the native playback lands.

local Assert = require("tests.support.Assert")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local BattlePresentationManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local BattleTimeline = require("game.hgss.tests.support.BattleTimelineFixture")
local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")
local FieldStatePresentationFixture = require("tests.support.FieldStatePresentationFixture")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}
local TICK = 1 / 30

---@return table recording sound-intent sink
local function sink()
  local records = { played = {} }
  function records.sound(name)
    records.played[#records.played + 1] = name
  end
  return records
end

---@return table detached dynamic view with a live lead and a foe
local function openingView()
  local function entry(combatant, own)
    return {
      combatant = combatant,
      participant = combatant,
      side = own and 1 or 2,
      controller = own and "player" or "wild",
      active = true,
      position = combatant,
      activation = combatant,
      hp = own and 52 or 57,
      maxHp = own and 52 or 57,
      species = "EEVEE",
      form = 0,
      name = own and "LEAD" or "FOE",
      level = 20,
      selector = own and "back" or "front",
      moves = own and { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } } or nil,
      experience = 8000,
    }
  end
  return {
    round = 1,
    status = "running",
    own = { entry(1, true) },
    foes = { entry(3, false) },
    participants = {},
  }
end

---@param id integer
---@param events table ordered sanitized events under test driving
---@param result table? committed terminal receipt carried by the delivery
---@return table delivery-shaped result packet
local function resultPacket(id, events, result)
  return {
    launchId = "outcome-probe",
    packetId = id,
    events = events,
    before = openingView(),
    after = openingView(),
    request = nil,
    result = result,
  }
end

---@return table kernel-shaped failed-escape event under test driving
local function failedEscape()
  return {
    sequence = 1,
    kind = "flee",
    cause = { key = "FLEE" },
    audience = "public",
    actors = { { combatant = 1 } },
    targets = { { combatant = 1 } },
    payload = { combatant = 1, escaped = false },
    after = { hp = { [1] = 52, [3] = 57 } },
  }
end

---@param timeline table cue player under test driving
---@param budget integer maximum source ticks before giving up
local function drain(timeline, budget)
  for _ = 1, budget do
    timeline:update(TICK, function(_)
      return true
    end)
    if timeline:settled() then
      break
    end
  end
end

---@param timeline table cue player under test driving
---@return table ordered fully revealed narration texts
local function collectMessages(timeline)
  local seen = {}
  local texts = {}
  for _ = 1, 3000 do
    timeline:update(TICK, function(_)
      return true
    end)
    local id = timeline:messageId()
    if id ~= 0 and seen[id] == nil and timeline:ack() then
      seen[id] = true
      texts[#texts + 1] = timeline:message()
    end
    if timeline:settled() then
      break
    end
  end
  return texts
end

---@param battlers table displayed battler facts under inspection
---@param combatant integer
---@return table the displayed facts for one combatant
local function battler(battlers, combatant)
  for _, entry in ipairs(battlers) do
    if entry.combatant == combatant then
      return entry
    end
  end
  error("no displayed battler " .. tostring(combatant), 0)
end

function T.failed_escape_narrates_and_leaves_the_launch_running()
  local timeline = BattleTimeline.new({})
  timeline:reset(openingView())
  Assert.isTrue(timeline:present(resultPacket(1, { failedEscape() }, nil)), "the failed-escape packet is accepted")
  local texts = collectMessages(timeline)
  Assert.isTrue(timeline:settled(), "the failed escape drains")
  Assert.isTrue(#texts >= 1, "the failed escape narrates its moment in order")
  Assert.isTrue(battler(timeline:battlers(), 3).visible, "the foe stays displayed after a failed escape")
end

function T.repeat_result_delivery_replays_nothing()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(name)
      sounds.sound(name)
    end,
  })
  timeline:reset(openingView())
  Assert.isTrue(timeline:present(resultPacket(1, {}, { word = "win" })), "the result-bearing delivery is accepted")
  drain(timeline, 3000)
  local played = #sounds.played
  Assert.isFalse(timeline:present(resultPacket(1, {}, { word = "win" })), "the repeated result delivery is rejected")
  drain(timeline, 3000)
  Assert.equal(#sounds.played, played, "the committed receipt never replays its presentation")
end

function T.won_result_plays_its_ordered_terminal_sequence_once()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(name)
      sounds.sound(name)
    end,
  })
  timeline:reset(openingView())
  Assert.isTrue(timeline:present(resultPacket(1, {}, { word = "win" })), "the win result delivery is accepted")
  local texts = collectMessages(timeline)
  Assert.isTrue(timeline:settled(), "the result sequence drains fully")
  Assert.equal(#texts, 0, "wild victory text is carried by earlier faint messages only")
  -- Native victory is a plain BGM swap (PlayBGM SEQ_GS_WIN2 for wild wins,
  -- battle_controller_player.c / battle_command.c), never a fanfare: the
  -- wild win voices its victory music through a music cue.
  local music = nil
  for _, played in ipairs(sounds.played) do
    if type(played) == "table" and played.kind == "music" then
      music = played
    end
  end
  Assert.notNil(music, "the wild win voices its victory music cue")
  Assert.equal(music.symbol, "SEQ_GS_WIN2", "the wild victory keeps its native wild-win symbol")
  Assert.isFalse(timeline:present(resultPacket(1, {}, { word = "win" })), "the same result never plays twice")
end

---@return table caller-owned dual-surface display facts
local function dualMeasurement()
  return {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" },
      "outcome-music:dual"
    ),
    pixelRatio = 1,
    signature = "outcome-music:dual",
  }
end

---@return table recording text boundary keeping every drawn string
local function recordingText()
  local text = { draws = {} }
  function text.measure(content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(content, x, y)
    text.draws[#text.draws + 1] = { content = tostring(content), x = x, y = y }
  end
  return text
end

---@return table recording window-frame boundary
local function recordingWindows()
  local windows = { calls = {} }
  function windows.drawWindow(box, frameKey, background)
    windows.calls[#windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  function windows.drawApplicationFrame(box, frameKey)
    windows.calls[#windows.calls + 1] = { box = box, frame = frameKey }
  end
  return windows
end

-- A strict method-faithful field audio double: the recorded BGM start
-- answers true exactly when the production voice contract accepts it,
-- so a silent or miscounted swap fails instead of passing quietly.
---@return table recording field audio double with a strict playMusic port
local function recordingFieldAudio()
  local audio = { music = {} }
  function audio:playMusic(symbol)
    audio.music[#audio.music + 1] = symbol
    return true
  end
  return audio
end

---@return table silent cue-audio boundary behind the live screen
local function silentScreenAudio()
  return {
    play = function(_, _)
      return true
    end,
  }
end

---@param launchId string owning launch identity under test driving
---@return table stub launch host holding its phase with recorded notifications
local function stubHost(launchId)
  local host = { launchId = launchId, notifies = {} }
  function host.status()
    return { phase = "active" }
  end
  function host.advance() end
  function host.submit(_)
    return false, { message = "no open request" }
  end
  function host.notify(event, detail)
    host.notifies[#host.notifies + 1] = { event = event, detail = detail }
  end
  return host
end

---@param kind string launch kind behind the BGM lookup
---@param trainerClass string? trainer class key behind the class route
---@return table live rig with the real envelope, screen, port, and recording audio
local function openPresentedLaunch(kind, trainerClass, textSpeed)
  local cache = FieldStatePresentationFixture.cache()
  cache:writeLua(BattlePresentationCache.manifestPath(), BattlePresentationManifestFixture.manifest())
  local fieldAudio = recordingFieldAudio()
  local envelope = FieldBattlePresentation.new({
    cacheFs = cache,
    monCatalog = CatalogFixture.makeCatalog(),
    windows = recordingWindows(),
    text = recordingText(),
    audio = silentScreenAudio(),
    measureDisplay = function()
      return dualMeasurement()
    end,
  })
  local launchId = "outcome-music-" .. kind .. "-" .. tostring(trainerClass or "wild")
  local host = stubHost(launchId)
  local port = envelope:factory()({
    launchId = launchId,
    environment = { sceneKey = "general/grass/day" },
    host = host,
    audio = fieldAudio,
    kind = kind,
    trainerClass = trainerClass,
    textSpeed = textSpeed or "mid",
  })
  Assert.notNil(port, "the envelope admits its presented launch")
  port.enter({ kind = kind })
  local screen = envelope:liveScreen()
  Assert.notNil(screen, "the envelope owns its live screen")
  return {
    envelope = envelope,
    screen = screen,
    port = port,
    host = host,
    fieldAudio = fieldAudio,
    kind = kind,
    trainerClass = trainerClass,
  }
end

---@param word string terminal result word behind the fabricated delivery
---@param trainerClass string? opponent class for trainer result messages
---@param money integer? detached reward/penalty amount from the commit owner
---@return table detached terminal delivery picturing the settled views
local function terminalPacket(launchId, packetId, word, events, trainerClass, money)
  local function side(records)
    return records
  end
  local view = {
    playerName = "MINT",
    playerTrainer = { classKey = "PKMN_TRAINER_ETHAN", name = "MINT" },
    own = side({
      {
        combatant = 1,
        activation = 1,
        side = 1,
        position = 1,
        name = "LEAD",
        species = "EEVEE",
        ballKey = "POKE_BALL",
        level = 5,
        hp = 20,
        maxHp = 20,
        active = true,
      },
    }),
    foes = side({
      {
        combatant = 2,
        participant = trainerClass ~= nil and 2 or nil,
        activation = 1,
        side = 2,
        position = 2,
        name = "Wild CHIKORITA",
        species = "CHIKORITA",
        ballKey = "POKE_BALL",
        level = 3,
        hp = 0,
        maxHp = 18,
        active = true,
      },
    }),
    participants = trainerClass ~= nil and {
      { participant = 2, side = 2, controller = "trainer:2" },
    } or {},
    foeTrainers = trainerClass ~= nil and {
      {
        classKey = trainerClass,
        name = "JACK",
        loseSpeechKey = "battle/trainer-speech/trainer-speech:596c78eb41b3a00c1ffb497f476cfa0a92d5ef7e",
      },
    } or {},
  }
  local result = { word = word }
  if word == "loss" then
    result.moneyLost = money or 0
  elseif word == "win" and trainerClass ~= nil then
    result.moneyGained = money or 0
  end
  return {
    launchId = launchId,
    packetId = packetId,
    events = events or {},
    before = view,
    after = view,
    result = result,
  }
end

---@param source table? source item or ability fact, absent for ordinary flight
---@return table successful escaped event with its source narration facts
local function successfulEscape(source)
  local payload = { combatant = 1, activation = 1, escaped = true, reason = "guaranteed", attempts = 0 }
  if source ~= nil then
    payload.escapeSource = source
  end
  return {
    sequence = 1,
    kind = "flee",
    cause = { key = "FLEE", combatant = 1 },
    audience = "public",
    payload = payload,
    messageArgs = { combatantName = "LEAD" },
    after = { hp = { [1] = 52, [3] = 57 } },
  }
end

---@param rig table live rig under test driving
---@param word string terminal result word under test driving
local function driveToOutcome(rig, word)
  local trainerClass = rig.kind == "trainer" and (rig.trainerClass or "YOUNGSTER") or nil
  rig.port.present(terminalPacket(rig.host.launchId, 1, word, nil, trainerClass, 250))
  for _ = 1, 900 do
    rig.screen:updateFixed(TICK)
    if rig.screen:status().mode == "outcome" then
      return
    end
    Assert.isTrue(
      rig.screen:status().mode ~= "failed",
      "the presented screen never fails: " .. tostring(rig.screen:status().error)
    )
  end
  error("the presented screen never reached its outcome for " .. tostring(word), 0)
end

---@param rig table live screen under a timed terminal message
---@param ending string visible final text fragment identifying the completed page
---@param afterId integer? preceding message identity that the page must follow
---@return integer message identity after its final glyph is printed
local function waitForCompleteOutcomeMessage(rig, ending, afterId)
  local pages, previousId = {}, nil
  for _ = 1, 180 do
    local message = rig.screen:view().message
    local id = rig.screen._timeline:messageId()
    if id ~= previousId then
      pages[#pages + 1] = tostring(id) .. ": " .. message
      previousId = id
    elseif #pages > 0 then
      pages[#pages] = tostring(id) .. ": " .. message
    end
    if (afterId == nil or id > afterId) and message:find(ending, 1, true) ~= nil then
      return rig.screen._timeline:messageId()
    end
    rig.screen:updateFixed(TICK)
  end
  error(
    "terminal outcome never printed "
      .. ending
      .. ": "
      .. tostring(rig.screen:view().message)
      .. " ["
      .. table.concat(pages, " | ")
      .. "]",
    0
  )
end

-- Victory and capture BGM swaps fire on the terminal presentation beat:
-- one class-correct track per winning launch before the terminal text
-- is acknowledged, while the message stays open for its explicit ack.
function T.won_and_captured_launches_swap_their_victory_bgm_before_ack()
  local cases = {
    { kind = "wild", trainerClass = nil, word = "capture", symbol = "SEQ_GS_WIN2" },
    { kind = "wild", trainerClass = nil, word = "win", symbol = "SEQ_GS_WIN2" },
    { kind = "trainer", trainerClass = nil, word = "win", symbol = "SEQ_GS_WIN1" },
    { kind = "trainer", trainerClass = "LEADER_FALKNER", word = "win", symbol = "SEQ_GS_WIN3" },
  }
  for _, case in ipairs(cases) do
    local rig = openPresentedLaunch(case.kind, case.trainerClass)
    driveToOutcome(rig, case.word)
    Assert.equal(#rig.fieldAudio.music, 1, case.word .. " voices exactly one victory BGM")
    Assert.equal(rig.fieldAudio.music[1], case.symbol, case.word .. " keeps its source victory track")
    Assert.isTrue(
      type(rig.screen:view().message) == "string",
      "the presented screen retains a message view while the BGM already plays"
    )
    if case.kind == "trainer" then
      Assert.isFalse(rig.port.leave({}), "the trainer source sequence remains timed without acknowledgment")
    else
      Assert.isTrue(rig.port.leave({}), "wild wins and captures need no extra terminal page")
    end
    for _ = 1, 30 do
      rig.screen:updateFixed(TICK)
    end
    Assert.equal(#rig.fieldAudio.music, 1, "the unacknowledged terminal replays no BGM")
    if case.kind == "trainer" then
      Assert.isFalse(rig.port.leave({}), "trainer speech and payout remain in the source sequence")
    else
      Assert.isTrue(rig.port.leave({}), "no-text terminal results return without acknowledgment")
    end
    rig.envelope:dispose()
  end
end

function T.successful_flight_uses_source_variant_and_auto_advances_after_30_ticks()
  local cases = {
    { source = nil, fragments = { "Got away safely" } },
    { source = { kind = "item", key = "SMOKE_BALL" }, fragments = { "LEAD", "Smoke Ball" } },
    { source = { kind = "ability", key = "RUN_AWAY" }, fragments = { "LEAD", "Run Away" } },
  }
  for _, case in ipairs(cases) do
    local rig = openPresentedLaunch("wild", nil, "fastest")
    rig.port.present(terminalPacket(rig.host.launchId, 1, "flee", { successfulEscape(case.source) }))
    for _ = 1, 900 do
      rig.screen:updateFixed(TICK)
      if rig.screen:status().mode == "outcome" then
        break
      end
    end
    Assert.equal(rig.screen:status().mode, "outcome", "successful flight opens its terminal source message")
    for _ = 1, 120 do
      local page = rig.screen:view().message
      local complete = true
      for _, fragment in ipairs(case.fragments) do
        if page:find(fragment, 1, true) == nil then
          complete = false
          break
        end
      end
      if complete and page:find("!", 1, true) ~= nil then
        break
      end
      rig.screen:updateFixed(TICK)
    end
    local message = rig.screen:view().message
    for _, fragment in ipairs(case.fragments) do
      Assert.isTrue(
        message:find(fragment, 1, true) ~= nil,
        "the source flight variant includes " .. fragment .. " in " .. tostring(message)
      )
    end
    Assert.isFalse(rig.port.leave({}), "successful flight waits for its source interval")
    for _ = 1, 28 do
      rig.screen:updateFixed(TICK)
    end
    Assert.isFalse(rig.port.leave({}), "the final source wait tick has not elapsed early")
    rig.screen:updateFixed(TICK)
    Assert.isFalse(rig.port.leave({}), "field return waits until the settled source frame")
    rig.screen:updateFixed(TICK)
    Assert.isTrue(rig.port.leave({}), "successful flight returns without an acknowledgment")
    rig.envelope:dispose()
  end
end

function T.trainer_loss_uses_ordered_bank_pages_and_exact_source_waits()
  local rig = openPresentedLaunch("trainer", "YOUNGSTER", "fastest")
  rig.port.present(terminalPacket(rig.host.launchId, 1, "loss", nil, "YOUNGSTER", 250))
  for _ = 1, 900 do
    rig.screen:updateFixed(TICK)
    if rig.screen:status().mode == "outcome" then
      break
    end
  end
  Assert.equal(rig.screen:status().mode, "outcome", "the committed loss opens its source sequence")
  local firstId = waitForCompleteOutcomeMessage(rig, "usable Pokémon!")
  Assert.isTrue(rig.screen:view().message:find("MINT", 1, true) ~= nil, "the first loss line names the player")
  for _ = 1, 28 do
    rig.screen:updateFixed(TICK)
  end
  Assert.equal(rig.screen._timeline:messageId(), firstId, "the first loss line holds for 30 source ticks")
  Assert.isFalse(rig.port.leave({}), "the loss sequence never leaves before its final page")
  rig.screen:updateFixed(TICK)
  rig.screen:updateFixed(TICK)
  local moneyId = waitForCompleteOutcomeMessage(rig, "to the winner.", firstId)
  Assert.isTrue(moneyId > firstId, "the trainer payout follows the defeat line")
  Assert.isTrue(rig.screen:view().message:find("$250", 1, true) ~= nil, "trainer payout uses the committed exact money")
  for _ = 1, 28 do
    rig.screen:updateFixed(TICK)
  end
  Assert.equal(rig.screen._timeline:messageId(), moneyId, "the payout line holds for 30 source ticks")
  rig.screen:updateFixed(TICK)
  rig.screen:updateFixed(TICK)
  local ellipsisId = waitForCompleteOutcomeMessage(rig, "... ... ... ...", moneyId)
  Assert.isTrue(ellipsisId > moneyId, "ellipsis follows the payout")
  for _ = 1, 28 do
    rig.screen:updateFixed(TICK)
  end
  Assert.equal(rig.screen._timeline:messageId(), ellipsisId, "ellipsis holds for 30 source ticks")
  rig.screen:updateFixed(TICK)
  rig.screen:updateFixed(TICK)
  local blackoutId = waitForCompleteOutcomeMessage(rig, "blacked out!", ellipsisId)
  Assert.isTrue(blackoutId > ellipsisId, "blackout follows ellipsis")
  Assert.isTrue(rig.screen:view().message:find("MINT", 1, true) ~= nil, "the blackout line uses the player-name token")
  for _ = 1, 28 do
    rig.screen:updateFixed(TICK)
  end
  Assert.equal(rig.screen._timeline:messageId(), blackoutId, "blackout holds for 30 source ticks")
  Assert.isFalse(rig.port.leave({}), "the final source wait has not elapsed early")
  rig.screen:updateFixed(TICK)
  Assert.isTrue(rig.port.leave({}), "the settled trainer loss returns without an outcome acknowledgment")
  rig.envelope:dispose()
end

function T.trainer_win_uses_lose_speech_then_the_planned_prize()
  local rig = openPresentedLaunch("trainer", "YOUNGSTER", "fastest")
  rig.port.present(terminalPacket(rig.host.launchId, 1, "win", nil, "YOUNGSTER", 250))
  for _ = 1, 900 do
    rig.screen:updateFixed(TICK)
    if rig.screen:status().mode == "outcome" then
      break
    end
  end
  Assert.equal(rig.screen:status().mode, "outcome", "the trainer win opens its source sequence")
  local defeatedId = waitForCompleteOutcomeMessage(rig, "JACK!")
  Assert.isTrue(rig.screen:view().message:find("Youngster", 1, true) ~= nil, "msg 839 names the trainer class")
  for _ = 1, 14 do
    rig.screen:updateFixed(TICK)
  end
  Assert.equal(rig.screen._timeline:messageId(), defeatedId, "msg 839 holds for 15 source ticks")
  Assert.isFalse(rig.port.leave({}), "the trainer win cannot leave before its response")
  local speechId = waitForCompleteOutcomeMessage(rig, "Trainer reacts to defeat.", defeatedId)
  Assert.isTrue(speechId > defeatedId, "the source trainer loss speech follows msg 839")
  for _ = 1, 58 do
    rig.screen:updateFixed(TICK)
  end
  Assert.equal(rig.screen._timeline:messageId(), speechId, "trainer loss speech holds for 60 source ticks")
  local payoutId = waitForCompleteOutcomeMessage(rig, "for winning!", speechId)
  Assert.isTrue(payoutId > speechId, "the trainer prize follows the source loss speech")
  Assert.isTrue(rig.screen:view().message:find("$250", 1, true) ~= nil, "msg 33 uses the committed trainer prize")
  Assert.isTrue(rig.screen:view().message:find("MINT", 1, true) ~= nil, "msg 33 names the player")
  for _ = 1, 58 do
    rig.screen:updateFixed(TICK)
  end
  Assert.equal(rig.screen._timeline:messageId(), payoutId, "the trainer prize holds for 60 source ticks")
  Assert.isFalse(rig.port.leave({}), "the prize wait is required")
  rig.screen:updateFixed(TICK)
  Assert.isTrue(rig.port.leave({}), "the settled trainer win returns without an acknowledgment")
  rig.envelope:dispose()
end

function T.capture_result_does_not_repeat_the_caught_event_gotcha()
  local timeline = BattleTimeline.new({})
  timeline:reset(openingView())
  local caught = {
    sequence = 1,
    kind = "caught",
    cause = { key = "CAPTURE" },
    audience = "public",
    targets = { { combatant = 2 } },
    payload = { shakes = 3 },
    after = { hp = { [1] = 52, [2] = 0 } },
  }
  Assert.isTrue(
    timeline:present(resultPacket(1, { caught }, { word = "capture" })),
    "the successful capture event and terminal receipt share one delivery"
  )
  local messages = collectMessages(timeline)
  local gotchaCount = 0
  for _, message in ipairs(messages) do
    if message:find("Gotcha!", 1, true) ~= nil then
      gotchaCount = gotchaCount + 1
    end
  end
  Assert.equal(gotchaCount, 1, "the caught event carries one Gotcha line and the result repeats none")
  Assert.isTrue(timeline:settled(), "the capture receipt drains without an additional terminal page")
end

return { tests = T }
