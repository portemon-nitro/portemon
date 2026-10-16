-- Preview follower rejoin (retail MapPreviewGraphic_RunPlayerDropIn states
-- 4-5 in pret/pokeheartgold src/map_preview_graphic.c, generalized to
-- Portemon's uniform preview): when the post-commit area preview runs and a
-- partner is present, the transition rejoins the follower exactly once --
-- the MoveToPlayer + hide-until-step equivalent -- after the preview-owned
-- vertical return completes for a ladder-down arrival, or at preview
-- completion for any other profile, since the preview uniformly replaces
-- the enter choreography. The follower travels through the transition's
-- optional follower collaborator (the selectPreview injection pattern):
-- `{ isPresent, recall, rejoin }`. Absence and no present partner never
-- rejoin. This reverses the approved deviation that kept the follower
-- cleared through the preview; the ball rendering itself stays out of
-- scope -- only hook invocation and ordering are pinned here.

local Assert = require("tests.support.Assert")
local FieldTransition = require("libs.hgss.src.transition.FieldTransition")
local FieldTransitionProfile = require("libs.hgss.src.transition.FieldTransitionProfile")

local T = {}

local function previewPlayer()
  local player = {
    motion = "idle",
    facing = "south",
    exitFacing = nil,
    returnAnchorY = nil,
    returnTicks = nil,
    turnTo = nil,
    progress = 0,
    duration = 0,
  }
  function player:beginTransitionLadderDownExit(facing)
    assert(self.motion == "idle", "cannot begin a transition motion while moving")
    self.motion = "transition"
    self.exitFacing = facing
    self.progress = 0
    self.duration = 16
    return true
  end
  function player:beginTransitionVerticalReturn(anchorY, durationTicks)
    assert(self.motion == "idle", "cannot begin a vertical return while moving")
    self.motion = "transition"
    self.returnAnchorY = anchorY
    self.returnTicks = durationTicks or 16
    self.progress = 0
    self.duration = self.returnTicks
    return true
  end
  function player:turn(direction)
    self.facing = direction
    self.turnTo = direction
  end
  function player:updateFixed(_)
    if self.motion ~= "transition" then
      return false
    end
    self.progress = self.progress + 1
    if self.progress >= self.duration then
      self.motion = "idle"
      self.progress = 0
    end
    return true
  end
  return player
end

local function previewWorld(options)
  options = options or {}
  local source = { mapId = 61, fieldData = { transitionEnvironment = "outdoors" } }
  local destination = { mapId = 60, fieldData = { transitionEnvironment = "cave" } }
  local player = previewPlayer()
  local rejoinCalls = {}
  local follower = nil
  if options.follower ~= false then
    local present = options.followerPresent
    if present == nil then
      present = true
    end
    follower = {
      isPresent = function()
        return present
      end,
      recall = function() end,
      rejoin = function(reason)
        rejoinCalls[#rejoinCalls + 1] = {
          reason = reason,
          arrival = nil, -- stamped below once the transition exists
        }
      end,
    }
  end
  local events = {}
  local transition
  transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    player = player,
    follower = follower,
    resolveDestination = function()
      return {
        destinationMap = destination,
        destinationWarp = { x = 4, z = 4 },
        fieldX = 4,
        fieldZ = 4,
        surfaceId = 0,
        worldY = 10,
      }
    end,
    prepare = function(result)
      return player
    end,
    commit = function(_, _, prepared)
      events[#events + 1] = "commit"
      transition.player = prepared
    end,
    selectPreview = function(_, _, profileId)
      return { imageKey = "preview.test", timeSlot = 1, profileId = profileId }
    end,
  })
  -- Stamp each rejoin with the preview-arrival state at call time so the
  -- test can order the rejoin against the completed vertical return.
  if follower ~= nil then
    local record = follower.rejoin
    follower.rejoin = function(reason)
      record(reason)
      rejoinCalls[#rejoinCalls].arrival = transition.previewArrival
    end
  end
  return {
    transition = transition,
    source = source,
    player = player,
    events = events,
    rejoinCalls = rejoinCalls,
  }
end

local function startLadderDownPreview(world, profileId)
  world.transition:start(world.source, {
    kind = "generic",
    warp = { index = 0, x = 6, z = 16, destinationMapId = 60, destinationWarpId = 0 },
    transition = { mode = "fixed", profile = profileId or FieldTransitionProfile.LADDER_DOWN },
  }, "south")
end

local function driveToIdle(world, maxTicks)
  local ticks = 0
  while world.transition.phase ~= "idle" and world.transition.phase ~= "error" and ticks < (maxTicks or 400) do
    ticks = ticks + 1
    world.transition:updateFixed()
    world.transition:updateSourceFrame()
  end
  return ticks
end

function T.profile8_preview_rejoins_the_present_follower_once_after_the_arrival()
  local world = previewWorld({ followerPresent = true })
  startLadderDownPreview(world)
  driveToIdle(world)

  Assert.equal(world.transition.phase, "idle", "the profile-8 preview completes")
  Assert.equal(#world.rejoinCalls, 1, "the preview arrival rejoins the follower exactly once")
  Assert.equal(world.rejoinCalls[1].reason, "preview", "the rejoin carries the preview arrival reason")
  Assert.equal(
    world.rejoinCalls[1].arrival,
    "done",
    "the rejoin fires only after the preview-owned vertical return completes and faces south"
  )
end

function T.profile8_preview_never_rejoins_without_a_present_partner()
  local world = previewWorld({ followerPresent = false })
  startLadderDownPreview(world)
  driveToIdle(world)

  Assert.equal(world.transition.phase, "idle", "the profile-8 preview completes")
  Assert.deepEqual(world.rejoinCalls, {}, "the readiness gate skips the rejoin with no partner present")
end

function T.profile8_preview_never_rejoins_without_a_collaborator()
  local world = previewWorld({ follower = false })
  startLadderDownPreview(world)
  driveToIdle(world)

  Assert.equal(world.transition.phase, "idle", "the profile-8 preview completes without a follower")
  Assert.deepEqual(world.rejoinCalls, {}, "no follower collaborator means no rejoin")
end

function T.non_ladder_down_preview_rejoins_the_present_follower_once_at_completion()
  local world = previewWorld({ followerPresent = true })
  startLadderDownPreview(world, FieldTransitionProfile.ORDINARY)
  driveToIdle(world)

  Assert.equal(world.transition.phase, "idle", "the ordinary preview completes")
  Assert.equal(#world.rejoinCalls, 1, "the general preview completion rejoins the follower exactly once")
  Assert.equal(world.rejoinCalls[1].reason, "preview", "the rejoin carries the preview arrival reason")
end

return { tests = T }
