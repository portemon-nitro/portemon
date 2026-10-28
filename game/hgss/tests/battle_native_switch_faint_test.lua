-- Frozen acceptance for voluntary switch, forced replacement, and faint
-- presentation through the cue player: only the affected activation
-- changes, the departing cry and picture/HUD tasks complete before the
-- matching decision resumes, and surviving doubles slots never move or
-- inherit the old occupant's effect. Native mechanism: the
-- health-bar slide tasks stagger battler boxes by source ticks while the
-- wait holds on outstanding controller work (BtlCmd_HealthbarSlideIn,
-- BtlCmd_Wait in src/battle/battle_command.c). Headless: hand-built
-- delivery-shaped packets drive the real cue player and the recording
-- sound sink; no dump capability is needed. The setup guards below are
-- green on the current boundary; the cry and sequencing gates stay red
-- until the native playback lands.

local Assert = require("tests.support.Assert")
local BattleAudio = require("libs.hgss.src.audio.BattleAudio")
local BattleTimeline = require("game.hgss.tests.support.BattleTimelineFixture")
local SourceTick = require("libs.hgss.src.field.SourceTick")

local T = {}
local TICK = SourceTick.DT

---@return table recording sound-intent sink
local function sink()
  local records = { played = {} }
  function records.sound(name)
    records.played[#records.played + 1] = name
  end
  return records
end

---@param combatant integer
---@param name string
---@param species string
---@param hp integer
---@param maxHp integer
---@param own boolean
---@return table displayed battler record under test driving
local function entry(combatant, name, species, hp, maxHp, own)
  return {
    combatant = combatant,
    participant = combatant,
    side = own and 1 or 2,
    controller = own and "player" or "wild",
    active = true,
    position = combatant,
    activation = combatant,
    hp = hp,
    maxHp = maxHp,
    species = species,
    form = 0,
    name = name,
    level = 20,
    selector = own and "back" or "front",
    moves = own and { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } } or nil,
    experience = 8000,
  }
end

---@return table detached doubles view with two live leads and two foes
local function doublesView()
  return {
    round = 1,
    status = "running",
    own = {
      entry(1, "LEFTY", "EEVEE", 52, 52, true),
      entry(2, "RIGHTY", "SHINX", 38, 38, true),
    },
    foes = {
      entry(3, "FOE-A", "GEODUDE", 45, 45, false),
      entry(4, "FOE-B", "ZUBAT", 30, 33, false),
    },
    participants = {},
  }
end

---@param id integer
---@param events table
---@param after table
---@return table delivery-shaped replacement packet
local function replacementPacket(id, events, after)
  return {
    launchId = "switch-faint-probe",
    packetId = id,
    events = events,
    before = doublesView(),
    after = after,
    request = nil,
    result = nil,
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

function T.voluntary_switch_moves_only_the_affected_slot()
  local timeline = BattleTimeline.new({})
  timeline:reset(doublesView())
  local after = doublesView()
  after.own[1] = entry(5, "BACKUP", "STARLY", 40, 40, true)
  after.own[1].position = 1
  after.own[1].activation = 5
  local packet = replacementPacket(1, {
    {
      sequence = 1,
      kind = "switch",
      cause = { key = "SWITCH" },
      audience = "public",
      payload = { from = 1, to = 5 },
      after = { hp = { [1] = 52, [2] = 38, [3] = 45, [4] = 30 } },
    },
  }, after)
  Assert.isTrue(timeline:present(packet), "the switch packet is accepted")
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "the withdrawal and reveal tasks complete")
  Assert.isFalse(battler(timeline:battlers(), 1).visible, "the departed slot hides")
  Assert.isTrue(battler(timeline:battlers(), 5).visible, "the incoming slot reveals")
  Assert.isTrue(battler(timeline:battlers(), 2).visible, "the surviving partner never leaves")
  Assert.equal(battler(timeline:battlers(), 2).hp, 38, "the surviving partner keeps its health")
  Assert.equal(battler(timeline:battlers(), 4).hp, 30, "the foe side never moves")
end

function T.faint_queues_its_cry_before_the_vanish_completes()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(name)
      sounds.sound(name)
    end,
  })
  timeline:reset(doublesView())
  local mid = doublesView()
  mid.foes[1].hp = 0
  local packet = replacementPacket(1, {
    {
      sequence = 1,
      kind = "struck",
      cause = { key = "TACKLE" },
      audience = "public",
      actors = { { combatant = 1 } },
      targets = { { combatant = 3 } },
      move = { executed = "TACKLE" },
      payload = { target = 3, damage = 45 },
      after = { hp = { [1] = 52, [2] = 38, [3] = 0, [4] = 30 } },
    },
    {
      sequence = 2,
      kind = "faint",
      cause = { key = "TACKLE" },
      audience = "public",
      payload = { combatant = 3, activation = 3, position = 3 },
      after = { hp = { [1] = 52, [2] = 38, [3] = 0, [4] = 30 } },
    },
  }, mid)
  Assert.isTrue(timeline:present(packet), "the knockout packet is accepted")
  local faintMessageAfterVanish = false
  for _ = 1, 3000 do
    timeline:update(TICK, function(_)
      return true
    end)
    if timeline:message():find("fainted", 1, true) ~= nil then
      faintMessageAfterVanish = not battler(timeline:battlers(), 3).visible
      break
    end
  end
  Assert.isTrue(faintMessageAfterVanish, "the faint message follows the battler vanish cue")
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "the knockout drains fully")
  Assert.isFalse(battler(timeline:battlers(), 3).visible, "the fainted battler hides")
  local cried = false
  local cryPattern = nil
  local cryFoe = nil
  for _, name in ipairs(sounds.played) do
    if name == "cry:GEODUDE" then
      cried = true
    elseif type(name) == "table" and name.kind == "cry" and name.species == "GEODUDE" then
      cryPattern = name.pattern
      cryFoe = name.foe
    end
  end
  Assert.isTrue(cried, "the faint carries its battler cry through the ordered audio sink")
  Assert.equal(cryPattern, 5, "the faint cry uses the source faint pattern")
  Assert.isTrue(cryFoe, "the faint cry carries the foe side")
  Assert.isTrue(type(BattleAudio.SINK_SOUNDS.faint) == "string", "the native faint sound has a semantic role")
  local deathEffect = false
  for _, cue in ipairs(sounds.played) do
    if type(cue) == "table" and cue.symbol == BattleAudio.SINK_SOUNDS.faint then
      deathEffect = true
      Assert.isTrue(cue.foe, "the faint sound carries the foe side for panning")
      Assert.equal(cue.pan, BattleAudio.SIDE_PAN.foe, "the faint sound uses the source foe pan")
    end
  end
  Assert.isTrue(deathEffect, "the faint plays the native death effect")
  Assert.isTrue(battler(timeline:battlers(), 4).visible, "the surviving foe never leaves its slot")
end

function T.faint_death_sound_waits_for_the_pattern_five_cry()
  local timeline = BattleTimeline.new({})
  timeline:reset(doublesView())
  timeline:intro(doublesView(), true)
  drain(timeline, 3000)
  timeline:drainSounds()
  local after = doublesView()
  after.foes[1].hp = 0
  Assert.isTrue(
    timeline:present(replacementPacket(1, {
      {
        sequence = 1,
        kind = "faint",
        cause = { key = "TACKLE" },
        audience = "public",
        payload = { combatant = 3, activation = 3, position = 3 },
      },
    }, after)),
    "the faint is accepted"
  )
  local cryFinished = false
  local function advance()
    timeline:update(TICK, function(_)
      return true
    end, function(_)
      return cryFinished
    end)
  end
  advance()
  local cry = timeline:drainSounds()
  Assert.equal(
    #cry,
    1,
    "the faint begins with one cry cue (" .. tostring(#cry) .. ", " .. tostring(cry[1] and cry[1].kind) .. ")"
  )
  Assert.equal(cry[1].kind, "cry", "the source cry cue starts first")
  Assert.equal(cry[1].pattern, 5, "the source faint pattern starts")
  advance()
  Assert.equal(#timeline:drainSounds(), 0, "the faint sound waits while the cry remains active")
  Assert.isTrue(battler(timeline:battlers(), 3).visible, "the picture remains while its cry is active")
  cryFinished = true
  local effect = {}
  for _ = 1, 4 do
    advance()
    effect = timeline:drainSounds()
    if #effect > 0 then
      break
    end
  end
  Assert.equal(#effect, 1, "the faint sound starts after the cry completes")
  Assert.equal(effect[1].symbol, BattleAudio.SINK_SOUNDS.faint, "the source faint sound follows the cry")
  Assert.equal(effect[1].pan, BattleAudio.SIDE_PAN.foe, "the faint sound keeps the source side pan")
end

function T.faint_slides_the_health_box_after_the_picture_disappears()
  local timeline = BattleTimeline.new({})
  local before = doublesView()
  before.foes[1].height = 16
  timeline:reset(before)
  local after = doublesView()
  after.foes[1].hp = 0
  Assert.isTrue(
    timeline:present(replacementPacket(1, {
      {
        sequence = 1,
        kind = "faint",
        cause = { key = "TACKLE" },
        audience = "public",
        payload = { combatant = 3, activation = 3, position = 3 },
      },
    }, after)),
    "the faint is accepted"
  )
  local observedSlide = false
  local firstCrop = nil
  for _ = 1, 100 do
    timeline:update(TICK, function(_)
      return true
    end)
    local fainted = battler(timeline:battlers(), 3)
    if firstCrop == nil and fainted.pictureVisible == true then
      firstCrop = { height = fainted.pictureHeight, y = fainted.pictureYOffset }
    end
    if fainted.visible == false and fainted.hudVisible == true and fainted.hudOffsetX == -24 then
      observedSlide = true
      break
    end
  end
  Assert.notNil(firstCrop, "the faint publishes its cropped picture state")
  Assert.equal(firstCrop.height, 56, "the first sink step removes eight pixels below the species crop")
  Assert.equal(firstCrop.y, 8, "the first sink step moves the picture down eight pixels")
  Assert.isTrue(observedSlide, "the enemy health box slides left after its picture disappears")
  drain(timeline, 3000)
  Assert.isFalse(battler(timeline:battlers(), 3).hudVisible, "the health box hides when its slide completes")
  Assert.isTrue(battler(timeline:battlers(), 4).visible, "the other opponent remains visible")
end

function T.faint_lowers_the_picture_before_applying_its_source_crop()
  local before = doublesView()
  before.foes[1].portraitSelector = "foe"
  local timeline = BattleTimeline.new({
    faintAppearance = function(_)
      return { height = 16, shadowHeight = 16 }
    end,
  })
  timeline:reset(before)
  timeline:intro(before, true)
  drain(timeline, 3000)
  local after = doublesView()
  after.foes[1].hp = 0
  Assert.isTrue(
    timeline:present(replacementPacket(1, {
      { sequence = 1, kind = "faint", cause = { key = "TACKLE" }, audience = "public", payload = { combatant = 3 } },
    }, after)),
    "the faint is accepted"
  )
  for _ = 1, 100 do
    timeline:update(TICK, function(_)
      return true
    end)
    local shown = battler(timeline:battlers(), 3)
    if shown.shadowHeight ~= nil then
      Assert.equal(shown.shadowHeight, 8, "the picture descends eight pixels while retaining its shadow")
      Assert.isFalse(shown.pictureVisible == true, "the source crop begins after the elevation reaches zero")
      timeline:update(TICK, function(_)
        return true
      end)
      shown = battler(timeline:battlers(), 3)
      Assert.equal(shown.shadowHeight, 0, "the elevation reaches ground level")
      return
    end
  end
  error("the faint never lowered its source elevation", 0)
end

function T.player_faint_slides_the_health_box_to_the_right()
  local timeline = BattleTimeline.new({})
  timeline:reset(doublesView())
  timeline:intro(doublesView(), true)
  drain(timeline, 3000)
  local after = doublesView()
  after.own[1].hp = 0
  Assert.isTrue(
    timeline:present(replacementPacket(1, {
      {
        sequence = 1,
        kind = "faint",
        cause = { key = "TACKLE" },
        audience = "public",
        payload = { combatant = 1, activation = 1, position = 1 },
      },
    }, after)),
    "the player faint is accepted"
  )
  local observedSlide = false
  local priorMessage = timeline:messageId()
  for _ = 1, 100 do
    timeline:update(TICK, function(_)
      return true
    end)
    local fainted = battler(timeline:battlers(), 1)
    if fainted.visible == false and fainted.hudVisible == true and fainted.hudOffsetX == 24 then
      observedSlide = true
      break
    end
  end
  Assert.isTrue(observedSlide, "the player health box slides right after its picture disappears")
  for step = 2, 6 do
    timeline:update(TICK, function(_)
      return true
    end)
    Assert.equal(battler(timeline:battlers(), 1).hudOffsetX, step * 24, "the box advances 24 pixels per source tick")
    if step == 2 then
      Assert.isTrue(timeline:messageId() ~= priorMessage, "faint narration starts while the health box slides")
      Assert.isTrue(battler(timeline:battlers(), 1).hudVisible, "the slide continues while narration prints")
      timeline:ack()
      timeline:ack()
    end
  end
  timeline:update(TICK, function(_)
    return true
  end)
  Assert.equal(battler(timeline:battlers(), 1).hudOffsetX, 160, "the box clamps at its source exit offset")
  local faintMessage = timeline:messageId()
  for _ = 1, 10 do
    timeline:update(TICK, function(_)
      return true
    end)
  end
  Assert.equal(timeline:messageId(), faintMessage, "input before the slide ends does not skip the later source wait")
  Assert.isTrue(timeline:busy(), "the source wait still holds after the health box exits")
  drain(timeline, 3000)
  Assert.isFalse(battler(timeline:battlers(), 1).hudVisible, "the player box hides when its slide completes")
  Assert.isTrue(battler(timeline:battlers(), 2).visible, "the other player remains visible")
end

function T.substitution_is_sequenced_by_the_flow_owner()
  local ok, Flow = pcall(require, "game.hgss.src.battle.BattlePresentationFlow")
  Assert.isTrue(ok, "the ordered battle flow owner resolves through the battle boundary")
  Assert.notNil(Flow, "the flow owner loads")
end

return { tests = T }
