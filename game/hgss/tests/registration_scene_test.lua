-- The Hall of Fame registration application: every recorded member gets its
-- own reveal with exact source stage timings before the whole-party photo
-- waits for the terminal acknowledgment. Cries fire with their baked delays,
-- input is ignored everywhere except the photo wait (A/B/touch, never
-- START), and the scene exposes one deterministic snapshot per tick.

local Assert = require("tests.support.Assert")
local RegistrationScene = require("game.hgss.src.ending.RegistrationScene")

local T = { tests = {} }

local function party(count)
  local members = {}
  for index = 1, count or 1 do
    members[index] = {
      species = "SPECIES_" .. index,
      form = 0,
      gender = "male",
      owLarge = false,
    }
  end
  return members
end

local function tracksFor(species, backDelay, frontDelay)
  local steps = {}
  for index = 1, 10 do
    steps[index] = { next = 0, duration = 1, xOffset = 0 }
  end
  steps[2] = { next = -1, duration = 0, xOffset = 0 }
  local tracks = {}
  tracks[species] = {
    front = { cryDelay = frontDelay, steps = steps },
    back = { cryDelay = backDelay, steps = steps },
    heights = { [0] = { male = 40, female = 40 } },
  }
  return tracks
end

local function noInput()
  return {}
end

local function step(scene, input)
  scene:step(input or noInput())
end

-- Drains one stage boundary: steps until the stage name changes, returning
-- the ticks spent (the source count includes the terminal tick).
---@param scene table
---@param maxTicks integer
---@return string stage, integer ticks
local function stepToNextStage(scene, maxTicks)
  local before = scene:status().stage
  for tick = 1, maxTicks or 1000 do
    step(scene)
    local status = scene:status()
    if status.stage ~= before or status.phase ~= "indiv" then
      return status.stage, tick
    end
  end
  error("the registration scene never left stage " .. tostring(before), 0)
end

function T.tests.single_reveal_runs_exact_source_stage_timings()
  local scene = RegistrationScene.new({ party = party(1), tracks = tracksFor("SPECIES_1", 5, 7) })
  local status = scene:status()
  Assert.equal(status.phase, "indiv", "the reveal opens on the individual scenes")
  Assert.equal(status.monIndex, 0, "the reveal opens with the first recorded member")
  Assert.equal(status.side, "left", "the first reveal plays on the left side")
  local expected = {
    { "fly_in_back", 11 },
    { "back_cry", 1 },
    { "hold_back", 51 },
    { "fly_in_ow", 7 },
    { "anim_ow", 1 },
    { "hold_ow", 21 },
    { "show_header", 1 },
    { "hold_header", 61 },
    { "fly_in_front", 9 },
    { "silhouette", 1 },
    { "hold_front", 41 },
    { "print_species", 1 },
    { "hold_species", 21 },
    { "print_caught", 1 },
    { "hold_caught", 241 },
    { "fly_out", 11 },
    { "tail_delay", 61 },
  }
  -- Each visited stage runs exactly its source frame count, in order;
  -- the last member's tail delay hands over to the whole party.
  for _, want in ipairs(expected) do
    local before = scene:status()
    Assert.equal(before.stage, want[1], "the reveal enters " .. want[1])
    local ticks = 0
    while scene:status().stage == want[1] and scene:status().phase == "indiv" do
      step(scene)
      ticks = ticks + 1
      Assert.isTrue(ticks <= want[2], "stage " .. want[1] .. " never overruns")
    end
    Assert.equal(ticks, want[2], "stage " .. want[1] .. " runs its source frame count")
  end
  Assert.equal(scene:status().phase, "whole", "the last reveal hands over to the whole party")
end

function T.tests.reveal_alternates_sides_and_advances_mon_index()
  local scene = RegistrationScene.new({ party = party(2), tracks = tracksFor("SPECIES_1", 5, 7) })
  Assert.equal(scene:status().side, "left", "the first reveal plays left")
  -- Drain the first member's 17 stages into the second member.
  for _ = 1, 17 do
    stepToNextStage(scene, 1000)
  end
  local status = scene:status()
  Assert.equal(status.phase, "indiv", "a second member still reveals individually")
  Assert.equal(status.monIndex, 1, "the reveal advances to the second member")
  Assert.equal(status.side, "right", "the second reveal plays on the right side")
end

function T.tests.cries_fire_with_their_baked_delays()
  local scene = RegistrationScene.new({ party = party(1), tracks = tracksFor("SPECIES_1", 5, 7) })
  -- back_cry is the second stage; its cry lands one task tick plus the
  -- baked back delay later.
  stepToNextStage(scene, 1000)
  Assert.equal(scene:status().stage, "back_cry", "the reveal reaches the back cry")
  step(scene)
  local cues = scene:takeCues()
  Assert.equal(#cues, 0, "the back cry waits out its baked delay")
  for _ = 1, 5 do
    step(scene)
  end
  cues = scene:takeCues()
  Assert.equal(#cues, 1, "the back cry fires once its delay elapses")
  Assert.equal(cues[1].kind, "cry", "the back cue is a cry")
  Assert.equal(cues[1].species, "SPECIES_1", "the back cue names the revealed species")
  -- The front cry fires the same way at the species print.
  while scene:status().stage ~= "print_species" do
    step(scene)
  end
  step(scene)
  Assert.equal(#scene:takeCues(), 0, "the front cry waits out its baked delay")
  for _ = 1, 7 do
    step(scene)
  end
  cues = scene:takeCues()
  Assert.equal(#cues, 1, "the front cry fires once its delay elapses")
  Assert.equal(cues[1].kind, "cry", "the front cue is a cry")
end

function T.tests.registration_ignores_input_until_the_photo_wait()
  local scene = RegistrationScene.new({ party = party(1), tracks = tracksFor("SPECIES_1", 5, 7) })
  local acted = { actionPressed = true }
  local started = { actionPressed = true }
  local touched = { uiEvents = { { type = "pointer_down" } } }
  for _ = 1, 100 do
    step(scene, acted)
    step(scene, started)
    scene:step({ menuPressed = true })
    step(scene, touched)
  end
  local status = scene:status()
  Assert.isFalse(status.photoWait, "input during the reveals never reaches a photo wait")
  Assert.equal(status.phase, "indiv", "input during the reveals never skips a member")
  for _, cue in ipairs(scene:takeCues()) do
    Assert.equal(cue.kind, "cry", "timer-driven cries still fire while input is ignored")
  end
end

function T.tests.photo_wait_answers_terminal_input_only()
  local scene = RegistrationScene.new({ party = party(0) })
  -- An empty party still stages its whole-party photo.
  local status = scene:status()
  Assert.equal(status.phase, "whole", "an empty party still stages its photo")
  while not scene:status().photoWait do
    step(scene)
  end
  for _ = 1, 30 do
    scene:step({ menuPressed = true })
  end
  Assert.isTrue(scene:status().photoWait, "START alone never advances the photo wait")
  scene:step({ actionPressed = true })
  Assert.isFalse(scene:status().photoWait, "A advances the photo wait")
  Assert.isTrue(scene:isDone() == false, "the accepted photo still plays its flashes out")
end

function T.tests.photo_wait_also_answers_cancel_and_touch()
  for _, input in ipairs({ { cancelPressed = true }, { uiEvents = { { type = "pointer_down" } } } }) do
    local scene = RegistrationScene.new({ party = party(0) })
    while not scene:status().photoWait do
      step(scene)
    end
    scene:step(input)
    Assert.isFalse(scene:status().photoWait, "the photo wait answers its terminal input")
  end
end

return T
