-- AnimationPlayer: the field-prop checked-advance state machine -- forward
-- only, one completion notion. Frames are fixed-point (frameFx = frame *
-- FRAME_UNIT) and the player advances by one FRAME_UNIT per updateFixed().
-- HGSS's field animation manager steps 0x1000 per tick and reports done
-- through the checked advance: Field3dModelAnimation_FrameAdvanceAndCheck
-- clamps the positive terminal at numFrame << 12 and sets done there
-- in the retail ROM, so a "once" clip finishes exactly
-- when frameFx reaches frameCount * FRAME_UNIT. The frame is always clamped
-- to [0, frameCount * FRAME_UNIT] -- the checked advance stores numFrame <<
-- 12 as a valid frame -- and a decoder fed an out-of-range frame from another
-- source reproduces the SDK's last-key behavior through its own clamp.
--
-- Loop modes and passes:
--   "loop"   wrap forward at frameCount * FRAME_UNIT; with a pass count the
--            player completes at the checked terminal of its last pass
--   "once"   land on frameCount * FRAME_UNIT and mark completed (one pass)
--
-- The optional pass count mirrors the source prop-animation loop count:
-- MapPropAnimation_Init stores it and MapPropAnimationPoolList_Update stops
-- looping on the last frame once loopsDone + 1 >= loopCount
-- (src/field/map_prop_render.c). nil is unbounded; an integer >= 1 is the
-- number of passes played before completion.

-- Terminal-state policy lives here: one completion notion (isComplete), the
-- checked advance's done flag. There is no direction: playback always runs
-- forward from frame 0. The player knows nothing about clips' source formats:
-- it consumes only the frame count. Pure domain module.

local AnimationClip = require("libs.assets.src.model.AnimationClip")

-- One live player: the clip's frame count, its bounded pass count and the
-- checked-advance position the owner draws from.
---@class AnimationPlayer
---@field frameCount integer
---@field loopCount integer? nil plays unbounded
---@field loopsDone integer
---@field frameFx integer the checked-advance position, frame * FRAME_UNIT
---@field loopMode string "loop" or "once"
---@field completed boolean
local AnimationPlayer = {}
AnimationPlayer.__index = AnimationPlayer

AnimationPlayer.LOOP_MODES = { loop = true, once = true }
AnimationPlayer.FRAME_UNIT = AnimationClip.FRAME_UNIT

-- Build a player for a clip (or any object with a positive integer
-- frameCount). `loopCount` bounds the number of passes; nil plays unbounded,
-- like a looping field prop animation. The returned player is owned by the
-- caller (or an attachment) and is mutable -- two players over one clip never
-- share state.
function AnimationPlayer.new(clip, loopCount)
  assert(type(clip) == "table" and clip.frameCount ~= nil, "AnimationPlayer.new requires a clip with a frameCount")
  local frameCount = clip.frameCount
  assert(
    type(frameCount) == "number" and frameCount >= 1 and math.floor(frameCount) == frameCount,
    "clip frameCount must be a positive integer"
  )
  assert(
    loopCount == nil or (type(loopCount) == "number" and math.floor(loopCount) == loopCount and loopCount >= 1),
    "clip loopCount must be a positive integer or nil"
  )
  return setmetatable({
    frameCount = frameCount,
    loopCount = loopCount,
    loopsDone = 0,
    frameFx = 0,
    loopMode = "loop",
    completed = false,
  }, AnimationPlayer)
end

-- Advance one fixed step forward. A once-clip that reaches or passes the
-- checked-advance terminal lands exactly on it and is marked completed; so
-- does a bounded loop-mode clip on the terminal of its last pass; an
-- unbounded loop wraps at the terminal.
function AnimationPlayer:updateFixed()
  if self.completed then
    return
  end
  local stepFx = self.frameCount * AnimationPlayer.FRAME_UNIT
  local frameFx = self.frameFx + AnimationPlayer.FRAME_UNIT

  if frameFx >= stepFx then
    if self.loopMode == "once" then
      self.frameFx = stepFx
      self.completed = true
      return
    end
    if self.loopCount ~= nil then
      if self.loopsDone + 1 >= self.loopCount then
        self.frameFx = stepFx
        self.completed = true
        return
      end
      self.loopsDone = self.loopsDone + 1
    end
    -- "loop" wraps past the end; the Lua modulo yields a frame in
    -- [0, stepFx - 1] for any forward overshoot.
    self.frameFx = frameFx % stepFx
    return
  end

  self.frameFx = frameFx
end

function AnimationPlayer:isComplete()
  return self.completed
end

-- A player that already holds the clip's last frame and reports completion:
-- the source's MapPropAnimationData_GoToLastAnimationFrame applied to a paused
-- record (a reloaded prop that must stand where its one-shot ended).
---@param clip { frameCount: integer }
---@return AnimationPlayer
function AnimationPlayer.atEnd(clip)
  local player = AnimationPlayer.new(clip)
  player.loopMode = "once"
  player.frameFx = clip.frameCount * AnimationPlayer.FRAME_UNIT
  player.completed = true
  return player
end

return AnimationPlayer
