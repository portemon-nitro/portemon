-- The Sinjoh Mystri Stage mechanism: the closed union kind, the shared 30-frame
-- source phase clock, the choice boundary, the freeze and the exact-once model
-- release. Source reference: src/field/gymmick/sinjoh.c.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local GymMechanismState = require("libs.hgss.src.field.GymMechanismState")
local SinjohGym = require("libs.hgss.src.field.gymmick.SinjohGym")

local T = {}

local function sinjohState()
  local state = GymMechanismState.restore(nil)
  state:initialize(GymMechanismState.SINJOH)
  return state
end

local function fakeModel()
  local model = { disposed = 0, ticks = 0 }
  function model:updateFixed()
    self.ticks = self.ticks + 1
  end
  function model:dispose()
    self.disposed = self.disposed + 1
  end
  return model
end

function T.the_union_carries_the_unresolved_and_chosen_pedestal_strictly()
  local state = sinjohState()
  Assert.equal(state:kind(), "sinjoh")
  Assert.equal(state:sinjohChoice(), 0, "a stage load leaves the choice unresolved")
  state:setSinjohChoice(3)
  Assert.equal(state:capture().data.choice, 3, "the chosen pedestal is part of the settled union")
  local restored = GymMechanismState.restore(state:capture())
  Assert.equal(restored:sinjohChoice(), 3, "Continue restores the chosen pedestal")
  Assert.throws(function()
    state:setSinjohChoice(4)
  end, "a choice outside the source pedestal range is rejected")
  Assert.throws(function()
    GymMechanismState.restore({ schema = GymMechanismState.SCHEMA, kind = "sinjoh", data = {} })
  end, "a sinjoh union without its choice is malformed")
  Assert.throws(function()
    GymMechanismState.restore({ schema = GymMechanismState.SCHEMA, kind = "sinjoh", data = { choice = 1, extra = 1 } })
  end, "a sinjoh union with an unknown field is rejected")
end

function T.the_stage_clock_commits_a_choice_on_the_common_thirty_frame_boundary()
  local state = sinjohState()
  local gym = SinjohGym.new({ state = state })
  Assert.equal(gym:initialize(), 0)
  -- The idle phase ends at frame 29: the choice commits on that advance.
  for _ = 1, SinjohGym.PHASE_FRAMES - 1 do
    gym:updateFixed()
    Assert.isFalse(gym:isWaiting() == false and state:sinjohChoice() ~= 0)
  end
  gym:choose(2)
  Assert.equal(state:sinjohChoice(), 2, "the raw choice is stored before the boundary wait")
  Assert.isTrue(gym:isWaiting(), "the source waits for the shared boundary")
  local ticks = 0
  while gym:isWaiting() do
    gym:updateFixed()
    ticks = ticks + 1
    Assert.isTrue(ticks <= SinjohGym.PHASE_FRAMES + 1, "the wait stays inside one source phase")
  end
  Assert.equal(ticks, 1, "the choice commits on the very next source boundary")
  local placement = gym:presentation()[3]
  Assert.isTrue(placement.selected, "the third model is in its selected phase")
  Assert.equal(placement.frame, SinjohGym.PHASE_FRAMES, "the selected phase starts at frame 30")
end

function T.a_choice_made_mid_idle_phase_waits_for_the_next_boundary()
  local state = sinjohState()
  local gym = SinjohGym.new({ state = state })
  gym:initialize()
  for _ = 1, 10 do
    gym:updateFixed()
  end
  gym:choose(0)
  local ticks = 0
  while gym:isWaiting() do
    gym:updateFixed()
    ticks = ticks + 1
    Assert.isTrue(ticks <= SinjohGym.PHASE_FRAMES, "the unresolved phase still ends inside its own cycle")
  end
  Assert.equal(ticks, SinjohGym.PHASE_FRAMES - 10, "the wait ends exactly on the shared 30-frame boundary")
end

function T.the_stage_places_three_models_at_the_source_positions()
  local placements = SinjohGym.new({ state = sinjohState() }):presentation()
  Assert.equal(#placements, 3, "the stage carries its three source models")
  local expected = {
    { 200 / 16, 16 / 16, 248 / 16 },
    { 328 / 16, 16 / 16, 248 / 16 },
    { 264 / 16, 16 / 16, 136 / 16 },
  }
  for slot, source in ipairs(expected) do
    Assert.equal(placements[slot].x, source[1], "model " .. slot .. " keeps its source x")
    Assert.equal(placements[slot].y, source[2], "model " .. slot .. " keeps its source y")
    Assert.equal(placements[slot].z, source[3], "model " .. slot .. " keeps its source z")
    Assert.isTrue(placements[slot].visible, "a loaded stage model is drawn")
  end
end

function T.freezing_hides_the_models_without_touching_the_choice()
  local state = sinjohState()
  state:setSinjohChoice(1)
  local gym = SinjohGym.new({ state = state })
  gym:initialize()
  gym:freeze()
  Assert.isTrue(gym:isFrozen(), "the source clears the stage objects' active flags")
  for _, placement in ipairs(gym:presentation()) do
    Assert.isFalse(placement.visible, "a frozen stage model draws nothing")
  end
  Assert.equal(state:sinjohChoice(), 1, "freezing never rewrites the stored choice")
end

function T.the_stage_owns_its_three_source_models_and_releases_them_once()
  local state = sinjohState()
  local models = {}
  local gym = SinjohGym.new({
    state = state,
    modelFactory = function(slot)
      models[slot] = fakeModel()
      return models[slot]
    end,
  })
  Assert.equal(#models, 3, "the stage claims its three source models")
  gym:updatePresentation()
  Assert.equal(models[1].ticks, 1, "the presented clips advance once per fixed tick")
  gym:dispose()
  gym:dispose()
  Assert.equal(models[1].disposed, 1, "a repeated dispose releases the model exactly once")
end

function T.a_cancelled_wait_keeps_the_stored_choice_and_drops_the_boundary()
  local state = sinjohState()
  local gym = SinjohGym.new({ state = state })
  gym:initialize()
  gym:choose(3)
  gym:cancelWait()
  Assert.isFalse(gym:isWaiting(), "a cancelled wait leaves no in-flight claim")
  Assert.equal(state:sinjohChoice(), 3, "the committed choice survives the cancellation")
end

function T.an_unknown_choice_is_an_attributed_fault()
  local gym = SinjohGym.new({ state = sinjohState() })
  local err = Assert.throws(function()
    gym:choose(7)
  end)
  Assert.isTrue(Errors.is(err), "the invalid choice raises a structured error")
end

return { metadata = {}, tests = T }
