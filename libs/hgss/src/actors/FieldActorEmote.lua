-- The overhead emote shared by pokeheartgold's movement emote
-- (ov01_02200614, asm/overlay_01_022001E4.s) and follower reaction
-- (ov01_02203CB8, asm/overlay_01_02203A18.s) field effects: both pin one icon
-- above a map object's presented position and run the same entrance bounce
-- before their own body. Progress ticks count effect updates, so tick 1 is
-- the first presented update.

local FieldActorEmote = {}

-- Both effects add (0, 0x20000, 0x1000) fx32 to the map object's presented
-- position on every update: two tiles up and a sixteenth of a tile forward.
FieldActorEmote.ANCHOR_OFFSET = { x = 0, y = 2, z = 1 / 16 }

-- The entrance bounce starts at velocity 6 and loses 2 per update until it
-- lands; the landing update is the last bounce update.
local BOUNCE_OFFSET_Y = { 6 / 16, 10 / 16, 12 / 16, 12 / 16, 10 / 16, 6 / 16, 0 }
local BOUNCE_TICKS = #BOUNCE_OFFSET_Y

-- A reaction holds its final pattern frame for two updates after the clip and
-- removes itself on the next.
local REACTION_TAIL_TICKS = 2

local function requireTick(progressTicks)
  assert(
    type(progressTicks) == "number" and progressTicks % 1 == 0 and progressTicks >= 0,
    "emote progress must be a non-negative integer"
  )
  return progressTicks
end

---@param progressTicks integer
---@return number offsetY tiles above the anchor
function FieldActorEmote.bounceOffsetY(progressTicks)
  return BOUNCE_OFFSET_Y[requireTick(progressTicks)] or 0
end

-- The reaction's pattern clip starts once the bounce lands; clip frame f is
-- shown after f pattern updates, and the final frame holds through the tail.
---@param progressTicks integer
---@param frameCount integer
---@return integer
function FieldActorEmote.reactionFrame(progressTicks, frameCount)
  return math.max(0, math.min(requireTick(progressTicks) - BOUNCE_TICKS, frameCount))
end

-- The reaction action duration: its removal update follows the bounce, the
-- clip, and the tail.
---@param frameCount integer
---@return integer
function FieldActorEmote.reactionTicks(frameCount)
  assert(type(frameCount) == "number" and frameCount % 1 == 0 and frameCount > 0, "reaction frame count is invalid")
  return BOUNCE_TICKS + frameCount + REACTION_TAIL_TICKS + 1
end

return FieldActorEmote
