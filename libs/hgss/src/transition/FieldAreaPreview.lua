-- Pure elapsed-time controller for a time-aware scenic area preview: the
-- black brightness-in cover, the one-source hold, the image alpha reveal
-- blend, and the freshly-pressed-A hold skip, with no map, GPU, input, or
-- LÖVE knowledge. The transition engine owns the field clock and feeds this
-- controller one source frame per field tick.

---@class FieldAreaPreview
---@field imageKey string the immutable selected semantic preview image key
---@field timeSlot integer the immutable sampled time slot
---@field stage "fade_in"|"hold"|"blend_out"|"complete"
---@field ticks integer elapsed ticks within the current stage
---@field skipPending boolean a fresh action asked to release the hold
local FieldAreaPreview = {}
FieldAreaPreview.__index = FieldAreaPreview

-- Retail shows sixteen display-frame palette steps, a sixty-one display-frame
-- hold, and sixteen alpha steps (one every two display frames) for the reveal.
-- Under the field's thirty-hertz fixed clock those become eight, thirty-one,
-- and sixteen fixed ticks.
FieldAreaPreview.FADE_TICKS = 8
FieldAreaPreview.HOLD_TICKS = 31
FieldAreaPreview.BLEND_TICKS = 16

---@param imageKey string
---@param timeSlot integer
---@return FieldAreaPreview
function FieldAreaPreview.new(imageKey, timeSlot)
  assert(type(imageKey) == "string" and imageKey ~= "", "area preview image key required")
  assert(
    type(timeSlot) == "number" and timeSlot % 1 == 0 and timeSlot >= 0,
    "area preview time slot must be a non-negative integer"
  )
  return setmetatable({
    imageKey = imageKey,
    timeSlot = timeSlot,
    stage = "fade_in",
    ticks = 0,
    skipPending = false,
  }, FieldAreaPreview)
end

---@return boolean
function FieldAreaPreview:isComplete()
  return self.stage == "complete"
end

-- Requests that the remaining hold end on the next source frame. Only a hold
-- is skippable: the cover and the reveal always run their full spans.
function FieldAreaPreview:skipHold()
  if self.stage == "hold" then
    self.skipPending = true
  end
end

local function beginBlend(self)
  self.stage = "blend_out"
  self.ticks = 0
end

function FieldAreaPreview:updateSourceFrame()
  if self.stage == "complete" then
    return
  end
  if self.stage == "fade_in" then
    self.ticks = self.ticks + 1
    if self.ticks >= FieldAreaPreview.FADE_TICKS then
      self.stage = "hold"
      self.ticks = 0
    end
    return
  end
  if self.stage == "hold" then
    if self.skipPending then
      self.skipPending = false
      beginBlend(self)
      return
    end
    self.ticks = self.ticks + 1
    if self.ticks >= FieldAreaPreview.HOLD_TICKS then
      beginBlend(self)
    end
    return
  end
  self.ticks = self.ticks + 1
  if self.ticks >= FieldAreaPreview.BLEND_TICKS then
    self.stage = "complete"
    self.ticks = FieldAreaPreview.BLEND_TICKS
  end
end

-- The semantic view of the preview: the immutable selection plus the current
-- stage and alphas. The black cover falls across the fade-in, the image holds
-- opaque, and the image alpha reveals the committed world through the blend.
---@return { imageKey: string, timeSlot: integer, stage: string, blackAlpha: number, imageAlpha: number }
function FieldAreaPreview:status()
  local blackAlpha = 0
  local imageAlpha = 1
  if self.stage == "fade_in" then
    blackAlpha = 1 - self.ticks / FieldAreaPreview.FADE_TICKS
  elseif self.stage == "blend_out" then
    imageAlpha = 1 - self.ticks / FieldAreaPreview.BLEND_TICKS
  elseif self.stage == "complete" then
    imageAlpha = 0
  end
  return {
    imageKey = self.imageKey,
    timeSlot = self.timeSlot,
    stage = self.stage,
    blackAlpha = blackAlpha,
    imageAlpha = imageAlpha,
  }
end

return FieldAreaPreview
