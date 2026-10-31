-- Battle cue/wait/message cadence against the retail battle scripts and the
-- shared source cadence (libs/hgss/src/field/SourceTick.lua,
-- libs/hgss/src/ui/TextSpeedPolicy.lua): waits carry decomp frame counts
-- one-to-one in source ticks, post-print holds carry only the script wait
-- behind the line (BtlCmd_WaitTime, BtlCmd_WaitButtonABTime, the
-- printer's own \r auto-scroll, or a task frame counter), and the
-- narration reveal steps two printer updates per source tick. Headless:
-- hand-built delivery-shaped packets drive the real cue player; sounds
-- drain into a recording sink and held sound voices are steered by an
-- explicit probe.

local Assert = require("tests.support.Assert")
local BattleTimeline = require("game.hgss.tests.support.BattleTimelineFixture")
local SourceTick = require("libs.hgss.src.field.SourceTick")

local T = {}
local TICK = SourceTick.DT

---@return table recording sound-cue sink
local function sink()
  local records = { played = {} }
  function records.sound(cue)
    records.played[#records.played + 1] = cue
  end
  return records
end

---@param combatant integer
---@param hp integer
---@param maxHp integer
---@return table checkpoint fragment for one combatant
local function checkpoint(combatant, hp, maxHp)
  return {
    activation = combatant,
    controller = combatant == 1 and "player" or "wild",
    experience = 100,
    form = 0,
    hp = hp,
    maxHp = maxHp,
    participant = combatant,
    position = combatant,
    side = combatant == 1 and 1 or 2,
    species = "EEVEE",
  }
end

---@return table detached dynamic view with a full-health player lead and foe
local function openingView()
  local function record(combatant, hp, own)
    return {
      combatant = combatant,
      participant = combatant,
      side = own and 1 or 2,
      controller = own and "player" or "wild",
      active = true,
      hp = hp,
      maxHp = combatant == 1 and 52 or 57,
      species = "EEVEE",
      form = 0,
      name = own and "LEAD" or "FOE",
      ballKey = "POKE_BALL",
      level = 20,
      selector = own and "back" or "front",
      moves = own and { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } } or nil,
      experience = 8000,
    }
  end
  return {
    round = 1,
    status = "running",
    own = { record(1, 52, true) },
    foes = { record(3, 57, false) },
    participants = {},
    playerTrainer = { classKey = "PKMN_TRAINER_ETHAN" },
  }
end

---@param id integer packet identity under test driving
---@param events table ordered sanitized events under test driving
---@param after table detached after view under test driving
---@return table delivery-shaped packet
local function packet(id, events, after)
  return {
    launchId = "cadence-probe",
    packetId = id,
    events = events,
    before = openingView(),
    after = after,
    request = nil,
    result = nil,
  }
end

---@param kind string
---@param fields table extra event fields under test driving
---@return table one sanitized event
local function event(kind, fields)
  local built = {
    sequence = 1,
    kind = kind,
    cause = { key = "TACKLE" },
    audience = "public",
    payload = {},
    after = { hp = {}, combatants = {} },
  }
  for key, value in pairs(fields) do
    built[key] = value
  end
  return built
end

---@param timeline table cue player under test driving
---@param soundComplete (fun(cue: table<string, unknown>): boolean)? held-voice probe
local function advance(timeline, soundComplete)
  timeline:update(TICK, function(_)
    return true
  end, soundComplete)
end

---@param timeline table cue player under test driving
---@param budget integer maximum source ticks before giving up
---@param soundComplete (fun(cue: table<string, unknown>): boolean)? held-voice probe
local function drain(timeline, budget, soundComplete)
  for _ = 1, budget do
    advance(timeline, soundComplete)
    if timeline:settled() then
      break
    end
  end
end

-- subscript_0076_AttackMessageAndAnimation prints the attack line, waits
-- only for the link barrier, and starts the move animation: no timed
-- hold separates the revealed line from its visual.
function T.attack_announcement_releases_its_visual_without_a_product_hold()
  local timeline = BattleTimeline.new({ sound = function(_) end, textSpeed = "fastest" })
  timeline:reset(openingView())
  local strike = event("move-used", {
    actionId = 9,
    actors = { { combatant = 1 } },
    move = { selected = "TACKLE", executed = "TACKLE", phase = "direct" },
    payload = { user = 1 },
  })
  Assert.isTrue(timeline:present(packet(1, { strike }, openingView())), "the use event is accepted")
  for _ = 1, 200 do
    advance(timeline)
    if timeline:message() == "LEAD used Tackle!" then
      break
    end
  end
  Assert.equal(timeline:message(), "LEAD used Tackle!", "the attack line reveals")
  advance(timeline)
  advance(timeline)
  Assert.isTrue(
    timeline:settled(),
    "the revealed attack line releases its visual without a product hold"
  )
end

-- A narration page without a retail script wait behind it carries no
-- hold of its own: the script continues immediately once printing ends.
function T.default_narration_carries_no_hold()
  local timeline = BattleTimeline.new({ sound = function(_) end, textSpeed = "fastest" })
  timeline:reset(openingView())
  timeline:announce("HELLO", false)
  for _ = 1, 5 do
    advance(timeline)
  end
  Assert.isTrue(timeline:settled(), "a hold-free page settles with its reveal")
end

-- subscript_0021_MoveFollowupMessage holds the previous page with
-- WaitButtonABTime 15 before the effectiveness line: A/B skips it.
function T.super_effective_pre_message_hold_answers_acknowledgement()
  local function struckTimeline()
    local timeline = BattleTimeline.new({ sound = function(_) end, textSpeed = "fastest" })
    timeline:reset(openingView())
    local after = openingView()
    after.foes[1].hp = 56
    local struck = event("struck", {
      actionId = 9,
      actors = { { combatant = 1 } },
      move = { selected = "TACKLE", executed = "TACKLE", phase = "direct" },
      payload = { target = 3, damage = 1, hitIndex = 1, effectiveness = "super", noBlink = true },
      after = { hp = { [1] = 52, [3] = 56 } },
    })
    Assert.isTrue(timeline:present(packet(1, { struck }, after)), "the struck event is accepted")
    return timeline
  end
  local quiet = 0
  do
    local timeline = struckTimeline()
    for _ = 1, 600 do
      advance(timeline)
      if timeline:settled() then
        break
      end
      if not timeline:messageActive() and timeline:levelUpStats() == nil then
        quiet = quiet + 1
      end
    end
    Assert.isTrue(timeline:settled(), "the super-effective sequence drains")
    Assert.equal(
      quiet,
      16,
      "one health tick plus the fifteen-tick effectiveness beat run without narration"
    )
  end
  do
    local timeline = struckTimeline()
    for _ = 1, 600 do
      advance(timeline)
      local shown = nil
      for _, entry in ipairs(timeline:battlers()) do
        if entry.combatant == 3 then
          shown = entry
        end
      end
      if shown ~= nil and shown.hp == 56 and not timeline:messageActive() then
        break
      end
    end
    advance(timeline)
    Assert.isTrue(timeline:ack(), "acknowledgement consumes the skippable effectiveness beat")
    for _ = 1, 3 do
      advance(timeline)
    end
    Assert.isTrue(
      timeline:messageActive(),
      "skipping the beat reaches the effectiveness line within three ticks"
    )
  end
end

-- battle_anim_ball.c: CaptureStateShakeWait counts to 14, the wobble
-- sounds BOWA on its fifth frame and ends on its twelfth, and
-- STATE_GET_POKEMON_BALL_SHAKE_DECREMENT waits 12 more frames: 19 + 19.
function T.capture_shake_matches_the_source_frame_cycle()
  local timeline = BattleTimeline.new({ sound = function(_) end, textSpeed = "fastest" })
  timeline:reset(openingView())
  local shake = event("shake", {
    actors = { { combatant = 1 } },
    targets = { { combatant = 3 } },
    payload = { index = 1 },
    after = { hp = { [1] = 52, [3] = 20 } },
  })
  Assert.isTrue(timeline:present(packet(1, { shake }, openingView())), "the shake is accepted")
  local ticks = 0
  for _ = 1, 200 do
    advance(timeline)
    ticks = ticks + 1
    if timeline:settled() then
      break
    end
  end
  Assert.isTrue(timeline:settled(), "the lone shake drains")
  Assert.equal(ticks, 38, "the shake holds fourteen plus five, then seven plus twelve frames")
end

-- battle_command.c STATE_GET_POKEMON_BALL_BLOCKED/_NO_STEALING: each
-- blocked line prints, then the task counts 30 frames once printing ends.
-- Neither line ends in \r, so no auto-scroll extends them.
function T.trainer_blocked_lines_hold_the_source_thirty_frame_beat()
  local timeline = BattleTimeline.new({ sound = function(_) end, textSpeed = "fastest" })
  timeline:reset(openingView())
  local throw = event("throw", {
    actors = { { combatant = 1 } },
    targets = { { combatant = 3 } },
    payload = { user = 1, ball = "POKE_BALL", target = 3, blocked = true },
    after = { hp = { [1] = 52, [3] = 57 } },
  })
  Assert.isTrue(timeline:present(packet(1, { throw }, openingView())), "the blocked throw is accepted")
  for _ = 1, 400 do
    advance(timeline)
    if timeline:message() == "The Trainer blocked the Ball!" then
      break
    end
  end
  Assert.equal(
    timeline:message(),
    "The Trainer blocked the Ball!",
    "the blocked line reveals"
  )
  for _ = 1, 29 do
    advance(timeline)
  end
  Assert.isTrue(
    timeline:messageActive() and timeline:message() == "The Trainer blocked the Ball!",
    "the blocked line holds its thirty-frame beat"
  )
  for _ = 1, 400 do
    advance(timeline)
    if timeline:message():find("thief", 1, true) ~= nil then
      break
    end
  end
  Assert.isTrue(
    timeline:message():find("thief", 1, true) ~= nil,
    "the refusal line follows the blocked line"
  )
  for _ = 1, 20 do
    advance(timeline)
  end
  Assert.isTrue(timeline:messageActive(), "the refusal line holds its thirty-frame beat")
  drain(timeline, 400)
  Assert.isTrue(timeline:settled(), "the blocked sequence drains")
end

-- battle_command.c STATE_GET_POKEMON_BREAK_OUT_MESSAGE/_DONE: the
-- break-out line prints (msg_0197_00863 has no \r), then the task counts
-- 30 frames once printing ends.
function T.broke_free_holds_the_source_thirty_frame_beat()
  local timeline = BattleTimeline.new({ sound = function(_) end, textSpeed = "fastest" })
  timeline:reset(openingView())
  local wording = "Oh, no! The foe broke free!"
  local broke = event("broke_free", {
    payload = { shakes = 1 },
    after = { hp = { [1] = 52, [3] = 57 } },
  })
  Assert.isTrue(
    timeline:present(packet(1, { broke }, openingView()), { [1] = wording }),
    "the break-out is accepted with its selected wording"
  )
  for _ = 1, 200 do
    advance(timeline)
    if timeline:message() == wording then
      break
    end
  end
  Assert.equal(timeline:message(), wording, "the break-out line reveals")
  for _ = 1, 20 do
    advance(timeline)
  end
  Assert.isTrue(timeline:messageActive(), "the break-out line holds its thirty-frame beat")
  drain(timeline, 200)
  Assert.isTrue(timeline:settled(), "the break-out drains without an extra wait")
end

-- battle_command.c STATE_GET_POKEMON_GOTCHA: the capture BGM starts as
-- the Gotcha line begins printing (msg_0197_00867 ends in \r, so the
-- printer's own hundred-update auto-scroll extends it), and
-- STATE_GET_POKEMON_CHECK_MON_DATA counts 30 more frames once printing
-- ends. The fanfare never gates the message.
function T.gotcha_overlaps_its_fanfare_and_holds_the_source_tail()
  local timeline = BattleTimeline.new({ sound = function(_) end, textSpeed = "fastest" })
  timeline:reset(openingView())
  local caught = event("caught", {
    actors = { { combatant = 1 } },
    targets = { { combatant = 3 } },
    payload = { shakes = 3 },
    after = { hp = { [1] = 52, [3] = 20 } },
  })
  Assert.isTrue(timeline:present(packet(1, { caught }, openingView())), "the capture is accepted")
  local neverFinishes = function(_)
    return false
  end
  for _ = 1, 3 do
    advance(timeline, neverFinishes)
  end
  Assert.isTrue(
    timeline:message() ~= "",
    "the Gotcha line starts printing while its fanfare is still voicing"
  )
  for _ = 1, 200 do
    advance(timeline, neverFinishes)
    if timeline:message() == "Gotcha! FOE was caught!" then
      break
    end
  end
  Assert.equal(timeline:message(), "Gotcha! FOE was caught!", "the Gotcha line reveals")
  for _ = 1, 70 do
    advance(timeline, neverFinishes)
  end
  Assert.isTrue(
    timeline:messageActive(),
    "the Gotcha line holds its auto-scroll plus thirty-frame tail"
  )
  drain(timeline, 200, neverFinishes)
  Assert.isTrue(timeline:settled(), "the capture drains once the tail completes")
end

-- battle_command.c STATE_GET_EXP_LEARNED_MOVE_WAIT: the move-learning
-- lines (msg_0197_00004/msg_0197_01188 end in \r) hold only for the
-- printer, including its hundred-update auto-scroll.
function T.learned_line_carries_the_source_auto_scroll()
  local timeline = BattleTimeline.new({ sound = function(_) end, textSpeed = "fastest" })
  timeline:reset(openingView())
  local learn = event("learn", {
    payload = { combatant = 1, move = "TACKLE" },
    after = { hp = { [1] = 52, [3] = 57 } },
  })
  Assert.isTrue(timeline:present(packet(1, { learn }, openingView())), "the lesson is accepted")
  local wording = nil
  for _ = 1, 200 do
    advance(timeline)
    if timeline:message() ~= "" then
      wording = timeline:message()
      local frozen = wording
      advance(timeline)
      if timeline:message() == frozen then
        wording = frozen
        break
      end
    end
  end
  Assert.notNil(wording, "the learned line reveals")
  for _ = 1, 40 do
    advance(timeline)
  end
  Assert.isTrue(timeline:messageActive(), "the learned line holds its auto-scroll beat")
  drain(timeline, 200)
  Assert.isTrue(timeline:settled(), "the lesson drains")
end

-- battle_controller_opponent.c bag menu task: every bag line prints, then
-- the task counts 30 frames once printing ends (no \r auto-scroll).
function T.bag_use_line_holds_the_menu_task_beat()
  local timeline = BattleTimeline.new({ sound = function(_) end, textSpeed = "fastest" })
  timeline:reset(openingView())
  local used = event("item", {
    payload = { item = "POTION" },
    after = { hp = { [1] = 52, [3] = 57 } },
  })
  Assert.isTrue(timeline:present(packet(1, { used }, openingView())), "the bag use is accepted")
  for _ = 1, 200 do
    advance(timeline)
    if timeline:message() == "Used the POTION!" then
      break
    end
  end
  Assert.equal(timeline:message(), "Used the POTION!", "the bag line reveals")
  for _ = 1, 20 do
    advance(timeline)
  end
  Assert.isTrue(timeline:messageActive(), "the bag line holds its thirty-frame beat")
  drain(timeline, 200)
  Assert.isTrue(timeline:settled(), "the bag use drains")
end

-- battle_command.c STATE_GET_EXP_WAIT_LEVEL_UP_MESSAGE_PRINT: the
-- level line (msg_0197_00003 ends in \r) holds for the printer,
-- including its hundred-update auto-scroll, before the summary.
function T.level_up_line_auto_scrolls_before_its_summary()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(cue)
      sounds.sound(cue)
    end,
    textSpeed = "fastest",
  })
  timeline:reset(openingView())
  local stats = { maxHp = 10, attack = 10, defense = 10, specialAttack = 10, specialDefense = 10, speed = 10 }
  local afterStats = { maxHp = 11, attack = 11, defense = 11, specialAttack = 11, specialDefense = 11, speed = 11 }
  local reward = event("exp", {
    payload = {
      combatant = 1,
      gained = 10,
      levelUps = { { level = 21, statsBefore = stats, statsAfter = afterStats } },
    },
    after = { hp = { [1] = 52, [3] = 57 } },
  })
  Assert.isTrue(timeline:present(packet(1, { reward }, openingView())), "the reward is accepted")
  local alwaysFinishes = function(_)
    return true
  end
  for _ = 1, 600 do
    advance(timeline, alwaysFinishes)
    if timeline:message() == "LEAD grew to Lv. 21!" then
      break
    end
  end
  Assert.equal(timeline:message(), "LEAD grew to Lv. 21!", "the level line reveals")
  for _ = 1, 40 do
    advance(timeline, alwaysFinishes)
  end
  Assert.isNil(
    timeline:levelUpStats(),
    "the summary waits out the level line auto-scroll"
  )
  Assert.isTrue(timeline:messageActive(), "the level line is still showing")
end

-- subscript_0000_StartEncounter ends after the player-side slide and its
-- healthbar: no timed wait separates the send-out from the hide that
-- releases command input.
function T.wild_intro_settles_without_a_trailing_product_wait()
  local timeline = BattleTimeline.new({ sound = function(_) end, textSpeed = "fastest" })
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, true)
  local revealTick = nil
  local hideTick = nil
  for tick = 1, 2000 do
    advance(timeline)
    local shown = nil
    for _, entry in ipairs(timeline:battlers()) do
      if entry.combatant == 1 then
        shown = entry
      end
    end
    if revealTick == nil and shown ~= nil and shown.visible then
      revealTick = tick
    end
    local presentation = timeline:openingPresentation()
    -- The stage flag tracks its sprite and flips when the exit parks
    -- it, always ahead of the reveal poof: only a post-reveal hide
    -- settles the intro, so the break waits for the reveal first.
    if revealTick ~= nil and presentation ~= nil and presentation.playerTrainerVisible == false then
      hideTick = tick
      break
    end
  end
  Assert.notNil(revealTick, "the player send-out reveals")
  Assert.notNil(hideTick, "the intro hides its trainers")
  Assert.isTrue(
    hideTick - revealTick <= 120,
    "the send-out settles into the hide without a trailing product wait"
  )
end

return { tests = T }
