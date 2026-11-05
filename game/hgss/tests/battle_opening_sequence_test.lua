-- Opening orchestration against subscript_0000_StartEncounter: the wild
-- path prints Go! immediately after the encounter line, every opening
-- send-out holds its health box until the scripted slide, the trainer
-- player throw settles like its foe throw, and the handoff leaves no
-- gauges or intro terrain behind.

local Assert = require("tests.support.Assert")
local BattleTimelineFixture = require("game.hgss.tests.support.BattleTimelineFixture")

local T = {}
local TICK = 1 / 30

local function record(combatant, name, species, own, controller)
  return {
    combatant = combatant,
    participant = combatant,
    side = own and 1 or 2,
    controller = controller or (own and "player" or "wild"),
    active = true,
    position = combatant,
    activation = combatant,
    hp = 50,
    maxHp = 50,
    species = species,
    form = 0,
    name = name,
    level = 10,
    ballKey = "POKE_BALL",
    moves = { { move = "TACKLE", name = "Tackle" } },
  }
end

local function openingView()
  return {
    round = 1,
    status = "running",
    own = { record(1, "LEAD", "EEVEE", true) },
    foes = { record(3, "FOE", "CHIKORITA", false) },
    participants = {},
    playerTrainer = { classKey = "PKMN_TRAINER_ETHAN", name = "ETHAN" },
    foeTrainers = { { classKey = "YOUNGSTER", name = "JOEY" } },
    playerName = "ETHAN",
  }
end

---@param timeline table cue player under inspection
---@return table[] ordered queued cues
local function queued(timeline)
  return timeline._queue
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

function T.wild_has_no_idle_wait_between_encounter_line_and_go()
  local timeline = BattleTimelineFixture.new({})
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, true)
  local queue = queued(timeline)
  local encounterIndex, goIndex = nil, nil
  for index, cue in ipairs(queue) do
    if cue.kind == "message" and type(cue.text) == "string" then
      if cue.text:find("appeared!") ~= nil and encounterIndex == nil then
        encounterIndex = index
      elseif cue.text:find("Go!") ~= nil and encounterIndex ~= nil and goIndex == nil then
        goIndex = index
      end
    end
  end
  Assert.notNil(encounterIndex, "the wild opening prints its encounter line")
  Assert.notNil(goIndex, "the wild opening prints Go! after the encounter line")
  for index = encounterIndex + 1, goIndex - 1 do
    Assert.isFalse(queue[index].kind == "wait", "Go! follows the encounter line with no idle wait")
  end
end

function T.opening_reveals_hold_hud_until_their_slide()
  for _, wild in ipairs({ true, false }) do
    local timeline = BattleTimelineFixture.new({})
    local view = openingView()
    timeline:reset(view)
    timeline:intro(view, wild)
    local queue = queued(timeline)
    local reveals = {}
    for index, cue in ipairs(queue) do
      if cue.kind == "reveal" then
        reveals[#reveals + 1] = { cue = cue, index = index }
      end
    end
    Assert.isTrue(#reveals >= 1, "the opening reveals its sent-out battlers")
    for _, entry in ipairs(reveals) do
      Assert.isTrue(entry.cue.holdHud == true, "opening reveals hold their health box")
      local combatant = entry.cue.combatant
      local found = false
      for later = entry.index + 1, #queue do
        local next = queue[later]
        if next.kind == "hud-slide" and next.combatant == combatant and next.direction == "in" then
          found = true
          break
        end
      end
      Assert.isTrue(found, "combatant " .. tostring(combatant) .. " slides its health box in after its reveal")
    end
  end
end

function T.trainer_player_throw_settles_like_its_foe_throw()
  local timeline = BattleTimelineFixture.new({})
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, false)
  local queue = queued(timeline)
  local goIndex = nil
  for index, cue in ipairs(queue) do
    if cue.kind == "message" and type(cue.text) == "string" and cue.text:find("Go!") ~= nil then
      goIndex = index
      break
    end
  end
  Assert.notNil(goIndex, "the trainer opening prints Go! for the player lead")
  local hasSettleWait, hasSlide = false, false
  for index = goIndex + 1, #queue do
    local cue = queue[index]
    if cue.kind == "wait" and cue.duration == 96 then
      hasSettleWait = true
    end
    if cue.kind == "hud-slide" and cue.combatant == 1 and cue.direction == "in" then
      hasSlide = true
    end
    if cue.kind == "opening-presentation" then
      break
    end
  end
  Assert.isTrue(hasSettleWait, "the player throw settles 96 ticks like the scripted WaitTime")
  Assert.isTrue(hasSlide, "the player health box slides in after its settle")
end

function T.wild_handoff_leaves_no_gauges_behind()
  local timeline = BattleTimelineFixture.new({})
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, true)
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "the wild opening drains fully")
  local opening = timeline:openingPresentation()
  Assert.notNil(opening, "the drained opening keeps its presentation")
  Assert.equal(opening.playerGaugeVisible, true, "the wild handoff shows the player row for command input")
  Assert.equal(opening.enemyGaugeVisible, false, "the wild handoff keeps the enemy row hidden")
end

function T.trainer_handoff_publishes_both_command_rows()
  local timeline = BattleTimelineFixture.new({})
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, false)
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "the trainer opening drains fully")
  local opening = timeline:openingPresentation()
  Assert.notNil(opening, "the drained opening keeps its presentation")
  Assert.equal(opening.playerGaugeVisible, true, "the trainer handoff shows the player row for command input")
  Assert.equal(opening.enemyGaugeVisible, true, "the trainer handoff shows the enemy row for command input")
end

function T.trainer_handoff_clears_intro_terrain()
  local timeline = BattleTimelineFixture.new({})
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, false)
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "the trainer opening drains fully")
  local opening = timeline:openingPresentation()
  Assert.notNil(opening, "the drained opening keeps its presentation")
  for _, slide in ipairs(opening.terrainSlides or {}) do
    Assert.equal(slide.visible, false, "intro terrain hands off to the battle background")
  end
end

function T.wild_terrain_stays_through_the_encounter_line()
  local timeline = BattleTimelineFixture.new({})
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, true)
  local seen = false
  for _ = 1, 3000 do
    timeline:update(TICK, function(_)
      return true
    end)
    local message = timeline:message()
    if type(message) == "string" and message:find("appeared!") ~= nil then
      seen = true
      break
    end
    if timeline:settled() then
      break
    end
  end
  Assert.isTrue(seen, "the encounter line reaches the screen")
  local opening = timeline:openingPresentation()
  Assert.notNil(opening, "the encounter line keeps its presentation")
  for _, slide in ipairs(opening.terrainSlides or {}) do
    Assert.equal(slide.visible, true, "intro terrain stays up through the encounter line")
  end
end

function T.wild_foe_slide_travels_offscreen_to_settled()
  local timeline = BattleTimelineFixture.new({})
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, true)
  local function foeOffset()
    for _, shown in ipairs(timeline:battlers()) do
      if shown.combatant == 3 then
        return shown.pictureXOffset
      end
    end
    error("the wild foe stays installed through its slide", 0)
  end
  Assert.equal(foeOffset(), -272, "the wild foe starts offscreen at source x=-80")
  for _ = 1, 40 do
    timeline:update(TICK, function(_)
      return true
    end)
  end
  local traveled = foeOffset()
  Assert.isTrue(type(traveled) == "number" and traveled > -272, "the wild foe slides right off its start")
  Assert.isTrue(traveled <= 0, "the wild foe never overshoots its settled position")
end

return { tests = T }
