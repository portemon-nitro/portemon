-- The fishing rod's host seam (services.fishing) over the live field
-- runtime: the encounter roll as the line goes out, the avatar's fishing
-- visual and rod pose, the bite facts the follower shapes (whether it is
-- active, surfing, and the first alive mon's friendship and mood), the
-- world random draws, and the "!" emote mark over the player or the
-- follower (field/fishing.c). It owns the pose and the mark the field
-- presentation reads, and drives the rod animation on the player visual
-- through FishingRodMotion; the FishingTask owns the timing.

local FishingRodMotion = require("libs.hgss.src.presentation.FishingRodMotion")

---@class FieldFishingHost
---@field private _runtime table<string, unknown>
---@field private _pose string? the rod pose while the fishing visual shows
---@field private _notice { onFollower: boolean, tick: integer }? the live emote mark
---@field private _motion FishingRodMotion? the rod animation while the fishing visual shows
local FieldFishingHost = {}
FieldFishingHost.__index = FieldFishingHost

local POSES = { idle = true, cast = true, bite = true, reel = true }

---@param runtime table<string, unknown> the live field runtime
---@return FieldFishingHost
function FieldFishingHost.new(runtime)
  assert(type(runtime) == "table", "the fishing host requires the field runtime")
  return setmetatable({ _runtime = runtime, _pose = nil, _notice = nil, _motion = nil }, FieldFishingHost)
end

-- Rolls the rod's encounter (FieldSystem_PerformFishEncounterCheck) and
-- answers whether a wild Pokemon will bite; a bite leaves the encounter
-- prepared for the battle launch.
---@param rod string
---@return boolean
function FieldFishingHost:cast(rod)
  local result = self._runtime:attemptFishingEncounter(rod)
  return result ~= nil and result.kind == "prepared"
end

-- The first cast pose switches the avatar to its fishing visual
-- (PLAYER_TRANSITION_FISHING); every pose then selects the rod animation.
---@param pose string idle, cast, bite, or reel
function FieldFishingHost:setPose(pose)
  assert(POSES[pose] == true, "unknown fishing pose " .. tostring(pose))
  if self._pose == nil then
    local runtime = self._runtime
    assert(runtime.playerAvatar, "fishing requires the avatar transition owner"):queueTransition("fishing")
    runtime:applyAvatarTransitions()
    self._motion = FishingRodMotion.new()
  end
  self._pose = pose
end

---@return string? the rod pose while the fishing visual shows
function FieldFishingHost:pose()
  return self._pose
end

---@return { followerActive: boolean, surfing: boolean, friendship: integer, mood: integer }
function FieldFishingHost:biteFacts()
  return self._runtime:fishingBiteFacts()
end

-- One LCRandom draw reduced below `bound`.
---@param bound integer
---@return integer
function FieldFishingHost:random(bound)
  assert(type(bound) == "number" and bound % 1 == 0 and bound > 0, "fishing draws below a positive bound")
  local scripts = assert(self._runtime.scripts, "fishing draws from the world generator")
  return (scripts.worldState.rng:nextRaw() % 65536) % bound
end

-- Spawns the "!" over the follower when it noticed the bite, else over
-- the player.
---@param onFollower boolean
function FieldFishingHost:showNotice(onFollower)
  assert(type(onFollower) == "boolean", "the fishing mark names its subject")
  self._notice = { onFollower = onFollower, tick = 0 }
end

function FieldFishingHost:clearNotice()
  self._notice = nil
end

---@return { onFollower: boolean, tick: integer }? the live emote mark
function FieldFishingHost:notice()
  return self._notice
end

-- A line that hooked nothing drops its prepared encounter.
function FieldFishingHost:discardEncounter()
  self._runtime:cancelPendingEncounter()
end

-- Stows the rod: the mark goes and the avatar returns to its durable
-- state's visual.
function FieldFishingHost:putAway()
  self._notice = nil
  if self._pose == nil then
    return
  end
  self._pose = nil
  self._motion = nil
  local runtime = self._runtime
  assert(runtime.playerVisual, "fishing animates the player visual"):releasePose()
  local avatar = assert(runtime.playerAvatar, "fishing requires the avatar transition owner")
  avatar:queueTransition(avatar:durableState())
  runtime:applyAvatarTransitions()
end

-- Advances the mark and the rod one fixed tick: the rod steps its
-- sequence frame, which the fishing sprite's per-facing sequence clip
-- draws with the rod's display offset.
function FieldFishingHost:updateFixed()
  local notice = self._notice
  if notice ~= nil then
    notice.tick = notice.tick + 1
  end
  local motion = self._motion
  if motion ~= nil then
    local runtime = self._runtime
    local player = assert(runtime.player, "fishing animates the live player")
    motion:advance(assert(self._pose, "a rod motion follows its pose"), player.facing)
    local offsetX, offsetZ = motion:offset()
    assert(runtime.playerVisual, "fishing animates the player visual"):holdPose(
      "walk",
      motion:frame(),
      offsetX,
      offsetZ
    )
  end
end

return FieldFishingHost
