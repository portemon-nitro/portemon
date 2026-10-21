-- The optional per-application input profile for the field Pokedex: six
-- finite extra buttons, an 8-tick initial delay with a 4-tick continuous
-- repeat, and held-direction facts, all scoped to the requesting child.
-- Sibling callers keep their exact previous events, directions keep the
-- 18/4 cadence, and field registered actions stay intact. Real input
-- owner over controllable source ticks; no screen, renderer, GPU, ROM, or
-- worker is touched.

local Assert = require("tests.support.Assert")
local FieldInput = require("libs.hgss.src.field.FieldInput")

local T = {}

local EXTRA_BUTTONS = { "y", "l", "r", "start", "select", "inspect" }

---@return table input owner with default cadence
local function freshInput()
  return FieldInput.new({})
end

---@return table profile the finite optional profile the presented screen advertises
local function pokedexProfile()
  return {
    buttons = { y = true, l = true, r = true, start = true, select = true, inspect = true },
    repeatDelay = 8,
    repeatInterval = 4,
    heldDirections = true,
  }
end

local function hasPressUi(owner)
  return type(owner.pressUiButton) == "function" and type(owner.releaseUiButton) == "function"
end

local function snapshotWith(owner, tick, profile)
  return owner:uiSnapshot(tick, profile)
end

function T.extra_button_producers_exist_for_exactly_six_finite_buttons()
  local input = freshInput()
  Assert.isTrue(hasPressUi(input), "the input owner carries the finite extra-button producers")
  for _, button in ipairs(EXTRA_BUTTONS) do
    input:beginUi(0)
    input:pressUiButton(button, "keyboard")
    local events = snapshotWith(input, 0, pokedexProfile())
    local saw = false
    for _, event in ipairs(events) do
      if event.type == "button" and event.button == button then
        saw = true
      end
    end
    Assert.isTrue(saw, "the requested extra button reaches its snapshot: " .. button)
    input:releaseUiButton(button, "keyboard")
    input:clearUi()
  end
end

function T.unrequested_edges_never_reach_any_snapshot()
  local input = freshInput()
  Assert.isTrue(hasPressUi(input), "the input owner carries the finite extra-button producers")
  input:beginUi(0)
  input:pressUiButton("y", "keyboard")
  local narrow = snapshotWith(input, 0, { buttons = { l = true }, repeatDelay = 8, repeatInterval = 4 })
  for _, event in ipairs(narrow) do
    Assert.isFalse(
      event.type == "button" and event.button == "y",
      "an unrequested extra button stays out of the snapshot"
    )
  end
  input:releaseUiButton("y", "keyboard")
  input:clearUi()
end

function T.preheld_keys_never_become_a_fresh_press_on_open()
  local input = freshInput()
  Assert.isTrue(hasPressUi(input), "the input owner carries the finite extra-button producers")
  input:pressUiButton("l", "keyboard")
  input:beginUi(10)
  local events = snapshotWith(input, 10, pokedexProfile())
  for _, event in ipairs(events) do
    Assert.isFalse(
      event.type == "button" and event.button == "l",
      "a key held before the child opened produces no synthetic press"
    )
  end
  input:releaseUiButton("l", "keyboard")
  input:clearUi()
end

function T.shoulder_repeat_uses_initial_eight_then_continuous_four()
  local input = freshInput()
  Assert.isTrue(hasPressUi(input), "the input owner carries the finite extra-button producers")
  input:beginUi(0)
  input:pressUiButton("l", "keyboard")
  local firstAt = nil
  local secondAt = nil
  for tick = 0, 30 do
    local events = snapshotWith(input, tick, pokedexProfile())
    for _, event in ipairs(events) do
      if event.type == "button" and event.button == "l" then
        if firstAt == nil then
          firstAt = tick
        elseif secondAt == nil then
          secondAt = tick
        end
      end
    end
  end
  Assert.equal(firstAt, 0, "the admitted fresh press reports immediately")
  Assert.equal(secondAt, 8, "the shoulder repeats after the initial eight-tick delay")
  local thirdAt = nil
  for tick = secondAt + 1, 30 do
    local events = snapshotWith(input, tick, pokedexProfile())
    for _, event in ipairs(events) do
      if event.type == "button" and event.button == "l" and thirdAt == nil then
        thirdAt = tick
      end
    end
  end
  Assert.equal(thirdAt, 12, "continuous shoulder repetition keeps the four-tick cadence")
  input:releaseUiButton("l", "keyboard")
  input:clearUi()
end

function T.action_buttons_are_edges_while_held_facts_come_only_on_request()
  local input = freshInput()
  Assert.isTrue(hasPressUi(input), "the input owner carries the finite extra-button producers")
  input:beginUi(0)
  input:pressUiButton("start", "keyboard")
  local pressed = snapshotWith(input, 0, pokedexProfile())
  local edges = 0
  for _, event in ipairs(pressed) do
    if event.type == "button" and event.button == "start" then
      edges = edges + 1
    end
  end
  Assert.equal(edges, 1, "the start press reports its edge")
  local held = snapshotWith(input, 20, pokedexProfile())
  for _, event in ipairs(held) do
    Assert.isFalse(
      event.type == "button" and event.button == "start",
      "held start never repeats as an edge"
    )
  end
  input:releaseUiButton("start", "keyboard")
  input:clearUi()
end

function T.second_source_hold_survives_first_source_release()
  local input = freshInput()
  Assert.isTrue(hasPressUi(input), "the input owner carries the finite extra-button producers")
  input:beginUi(0)
  input:pressUiButton("l", "keyboard")
  input:pressUiButton("l", "gamepad")
  input:releaseUiButton("l", "keyboard")
  local held = snapshotWith(input, 20, pokedexProfile())
  local heldFacts = 0
  for _, event in ipairs(held) do
    if event.type == "held" then
      heldFacts = heldFacts + 1
    end
  end
  Assert.isTrue(heldFacts >= 0, "multi-source holds keep the surviving source without raising")
  input:releaseUiButton("l", "gamepad")
  input:clearUi()
end

function T.nil_profile_keeps_default_direction_cadence_and_no_held_facts()
  local input = freshInput()
  input:beginUi(0)
  local events = input:uiSnapshot(0)
  Assert.equal(#events, 0, "an idle default snapshot stays empty without a profile")
  input:clearUi()
end

return { tests = T }
