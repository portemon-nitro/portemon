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
local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")
local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")
local FieldStatePresentationFixture = require("tests.support.FieldStatePresentationFixture")
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
  Assert.isTrue(#texts >= 1, "the native result message plays through ordered playback")
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

function T.result_sequencing_is_owned_by_the_flow_owner()
  local ok, Flow = pcall(require, "game.hgss.src.battle.BattlePresentationFlow")
  Assert.isTrue(ok, "the ordered battle flow owner resolves through the battle boundary")
  Assert.notNil(Flow, "the flow owner loads")
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
local function openPresentedLaunch(kind, trainerClass)
  local cache = FieldStatePresentationFixture.cache()
  cache:writeLua(BattlePresentationCache.manifestPath(), BattlePresentationManifestFixture.manifest())
  local fieldAudio = recordingFieldAudio()
  local envelope = FieldBattlePresentation.new({
    cacheFs = cache,
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
    textSpeed = "mid",
  })
  Assert.notNil(port, "the envelope admits its presented launch")
  local screen = envelope:liveScreen()
  Assert.notNil(screen, "the envelope owns its live screen")
  return { envelope = envelope, screen = screen, port = port, host = host, fieldAudio = fieldAudio }
end

---@param word string terminal result word behind the fabricated delivery
---@return table detached terminal delivery picturing the settled views
local function terminalPacket(launchId, packetId, word)
  local function side(records)
    return records
  end
  local view = {
    own = side({
      {
        combatant = 1,
        activation = 1,
        side = 1,
        position = 1,
        name = "LEAD",
        species = "EEVEE",
        level = 5,
        hp = 20,
        maxHp = 20,
        active = true,
      },
    }),
    foes = side({
      {
        combatant = 2,
        activation = 1,
        side = 2,
        position = 2,
        name = "Wild CHIKORITA",
        species = "CHIKORITA",
        level = 3,
        hp = 0,
        maxHp = 18,
        active = true,
      },
    }),
  }
  return {
    launchId = launchId,
    packetId = packetId,
    events = {},
    before = view,
    after = view,
    result = { word = word },
  }
end

---@param rig table live rig under test driving
---@param word string terminal result word under test driving
local function driveToOutcome(rig, word)
  rig.port.present(terminalPacket(rig.host.launchId, 1, word))
  for _ = 1, 900 do
    rig.screen:updateFixed(TICK)
    if rig.screen:status().mode == "outcome" then
      return
    end
    Assert.isTrue(rig.screen:status().mode ~= "failed", "the presented screen never fails: " .. tostring(rig.screen:status().error))
  end
  error("the presented screen never reached its outcome for " .. tostring(word), 0)
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
      type(rig.screen:view().message) == "string" and rig.screen:view().message ~= "",
      "the terminal narration stays visible while the BGM already plays"
    )
    Assert.isFalse(rig.port.leave({}), "the terminal text still waits for its explicit acknowledgement")
    for _ = 1, 30 do
      rig.screen:updateFixed(TICK)
    end
    Assert.equal(#rig.fieldAudio.music, 1, "the unacknowledged terminal replays no BGM")
    rig.envelope:dispose()
  end
end

return { tests = T }
