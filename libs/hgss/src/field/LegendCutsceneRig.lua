-- Shared camera lease and screen-fade clocks behind the Bell Tower and
-- Whirl Islands legend cutscenes. The scenes keep their own state shapes;
-- this module only moves the retail camera and fade arithmetic both scenes
-- must agree on.

local LegendCutsceneRig = {}

-- The retail field camera distance every legend cutscene pose keeps, in tiles.
LegendCutsceneRig.FIELD_CAMERA_DISTANCE = 0x29AEC1 / 4096 / 16

---@param position table<string, number>
---@return table<string, number>
function LegendCutsceneRig.copyPosition(position)
  return { x = position.x, y = position.y, z = position.z }
end

---@param position table<string, number>
---@param offset table<string, number>|number[]
---@return table<string, number>
function LegendCutsceneRig.offsetPosition(position, offset)
  local x, y, z
  if offset.x ~= nil then
    x, y, z = offset.x, offset.y, offset.z
  else
    x, y, z = offset[1], offset[2], offset[3]
  end
  return { x = position.x + x, y = position.y + y, z = position.z + z }
end

---@param camera table<string, unknown>
---@return table<string, unknown>
function LegendCutsceneRig.snapshotCamera(camera)
  return {
    target = LegendCutsceneRig.copyPosition(camera.target),
    distance = camera.distance,
    rawPerspective = camera:rawPerspective(),
    near = camera.near,
    far = camera.far,
  }
end

-- Applies one cutscene pose and skips render interpolation so the cut never
-- smears across the previous frame.
---@param camera table<string, unknown>
---@param player table<string, number>
---@param target table<string, number>
---@param angle integer
---@param perspective integer
---@param options table<string, unknown>?
function LegendCutsceneRig.applyPose(camera, player, target, angle, perspective, options)
  options = options or {}
  camera:setCutscenePose(
    target,
    options.distance or LegendCutsceneRig.FIELD_CAMERA_DISTANCE,
    angle,
    perspective,
    player,
    options.angleY,
    options.near,
    options.far
  )
  camera:collapseRenderInterpolation()
end

-- Interpolates a cutscene pose from `from` toward `to` by progress.
-- Angles are 16-bit turns: the profile pitch is signed while the pose
-- table's is not, so the interpolation takes the short way round.
---@param from table<string, unknown>
---@param to table<string, unknown>
---@param progress number
---@return table<string, number> target
---@return integer angle
---@return integer perspective
function LegendCutsceneRig.interpolatePose(from, to, progress)
  local target = {
    x = from.target.x + (to.target.x - from.target.x) * progress,
    y = from.target.y + (to.target.y - from.target.y) * progress,
    z = from.target.z + (to.target.z - from.target.z) * progress,
  }
  local delta = (to.angle - from.angle + 0x8000) % 0x10000 - 0x8000
  local angle = math.floor(from.angle + delta * progress + 0.5) % 0x10000
  local perspective = math.floor(from.perspective + (to.perspective - from.perspective) * progress + 0.5)
  return target, angle, perspective
end

-- Advances a background camera translation one tick toward `to`, applying
-- the interpolated pose. Returns true once the translation has finished.
---@param camera table<string, unknown>
---@param player table<string, number>
---@param transition table<string, unknown>
---@param to table<string, unknown>
---@param distance number?
---@return boolean finished
function LegendCutsceneRig.tickTransition(camera, player, transition, to, distance)
  transition.frame = transition.frame + 1
  local target, angle, perspective =
    LegendCutsceneRig.interpolatePose(transition.start, to, math.min(1, transition.frame / transition.duration))
  LegendCutsceneRig.applyPose(camera, player, target, angle, perspective, { distance = distance })
  return transition.frame >= transition.duration
end

---@param fade table<string, unknown>
---@return table<string, unknown>
function LegendCutsceneRig.startFade(fade)
  return {
    color = fade.color,
    direction = fade.direction,
    duration = fade.duration,
    frame = 0,
    alpha = fade.direction == "in" and 1 or 0,
  }
end

-- Advances a screen fade one tick. Returns true once the fade has finished.
---@param fade table<string, unknown>
---@return boolean finished
function LegendCutsceneRig.tickFade(fade)
  fade.frame = fade.frame + 1
  local progress = math.min(1, fade.frame / fade.duration)
  fade.alpha = fade.direction == "in" and (1 - progress) or progress
  return fade.frame >= fade.duration
end

return LegendCutsceneRig
