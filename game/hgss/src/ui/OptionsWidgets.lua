-- Concrete chrome painting for the generated option controls: choice
-- pills, frame arrow cycles, project-authored slider rails with thumbs
-- and focus treatment, and footer action chrome. Text arrangement lives
-- in the Options renderer; these routines paint art only. Every visual
-- state resolves through prepared caller-owned viewports: the renderer
-- builds each frame Quad once outside draw and lends a lookup, so this
-- module never allocates images or quads. Missing art fails explicitly
-- and the borrowed graphics color is restored even on failure. The module
-- borrows its lease, lookup, and graphics namespace per call and retains
-- no state.

local OptionsWidgets = {}

---@alias OptionsWidgets.Rect { x: number, y: number, width: number, height: number }
---@alias OptionsWidgets.Point { x: number, y: number }
---@alias OptionsWidgets.Color { r: number, g: number, b: number, a: number? }
---@class OptionsWidgets.TextCollaborator caller text service behind window fills
---@field drawTokens fun(self: OptionsWidgets.TextCollaborator, tokens: table<integer, unknown>, x: number, y: number, role: string, sourceRole: string?)
---@field drawPlain fun(self: OptionsWidgets.TextCollaborator, line: string, x: number, y: number, role: string)
---@field measureTokens fun(self: OptionsWidgets.TextCollaborator, tokens: table<integer, unknown>, sourceRole: string?): number
---@field measurePlain fun(self: OptionsWidgets.TextCollaborator, line: string): number
---@field drawPreviewTokens fun(self: OptionsWidgets.TextCollaborator, tokens: table<integer, unknown>, x: number, y: number)
---@field windowBackgroundColor fun(self: OptionsWidgets.TextCollaborator): number[]
---@alias OptionsWidgets.SequenceFrame { image: string, atlas: OptionsWidgets.Rect, offset: OptionsWidgets.Point, ticks: integer }
---@alias OptionsWidgets.CompiledSequence { frames: OptionsWidgets.SequenceFrame[], loop: boolean, bounds: OptionsWidgets.Rect }
---@alias OptionsWidgets.ChoiceStates { unselected: OptionsWidgets.CompiledSequence, selected: OptionsWidgets.CompiledSequence }
---@alias OptionsWidgets.ArrowPair { idle: OptionsWidgets.CompiledSequence, pressed: OptionsWidgets.CompiledSequence }
---@alias OptionsWidgets.ArrowSet { left: OptionsWidgets.ArrowPair, right: OptionsWidgets.ArrowPair }
---@alias OptionsWidgets.ActionStates { normal: OptionsWidgets.CompiledSequence, focused: OptionsWidgets.CompiledSequence, pressed: OptionsWidgets.CompiledSequence, pressedFocused: OptionsWidgets.CompiledSequence }
---@alias OptionsWidgets.SliderGeometry { rect: OptionsWidgets.Rect, trackStartX: number, trackEndX: number, centerY: number, thumbRect: OptionsWidgets.Rect, count: integer, index: integer }
---@alias OptionsWidgets.SliderStyle { rail: OptionsWidgets.Color, fill: OptionsWidgets.Color, thumb: OptionsWidgets.Color, thumbEdge: OptionsWidgets.Color, focus: OptionsWidgets.Color }

local function point(value, name)
  assert(type(value) == "table", name .. " is required")
  assert(
    type(value.x) == "number" and value.x == value.x and type(value.y) == "number" and value.y == value.y,
    name .. " must carry finite coordinates"
  )
  return value
end

local function color(value, name)
  assert(type(value) == "table", name .. " is required")
  for _, channel in ipairs({ "r", "g", "b" }) do
    assert(
      type(value[channel]) == "number" and value[channel] >= 0 and value[channel] <= 1,
      name .. " channel " .. channel .. " must be a 0..1 component"
    )
  end
  return value.r, value.g, value.b, value.a == nil and 1 or value.a
end

local function withColor(graphics, fn)
  local r, g, b, a = graphics.getColor()
  local ok, err = pcall(fn)
  graphics.setColor(r, g, b, a)
  if not ok then
    error(err, 0)
  end
end

local function frameAt(sequence, ageTicks, what)
  assert(type(sequence) == "table" and type(sequence.frames) == "table", what .. " must be a compiled sequence")
  assert(#sequence.frames >= 1, what .. " must carry at least one frame")
  assert(
    type(ageTicks) == "number" and ageTicks == ageTicks and ageTicks >= 0,
    what .. " animation age must be a non-negative tick count"
  )
  local total = 0
  for _, frame in ipairs(sequence.frames) do
    assert(
      type(frame.ticks) == "number" and frame.ticks % 1 == 0 and frame.ticks >= 0,
      what .. " frame durations must be non-negative integers"
    )
    total = total + frame.ticks
  end
  assert(total > 0, what .. " animation must advance")
  local age = ageTicks
  if sequence.loop then
    age = age % total
  elseif age >= total then
    return sequence.frames[#sequence.frames]
  end
  for _, frame in ipairs(sequence.frames) do
    if age < frame.ticks then
      return frame
    end
    age = age - frame.ticks
  end
  return sequence.frames[#sequence.frames]
end

local function drawFrame(graphics, chrome, quadFor, frame, anchorX, anchorY, what)
  assert(type(frame) == "table", what .. " frame is required")
  assert(type(frame.image) == "string" and frame.image ~= "", what .. " frame must name its atlas")
  assert(type(frame.atlas) == "table", what .. " frame must carry its atlas rect")
  local atlas = frame.atlas
  assert(type(frame.offset) == "table", what .. " frame must carry its offset")
  local offset = frame.offset
  local image = assert(chrome.image, what .. " lease must carry its resolved image")
  local imageWidth, imageHeight = image:getWidth(), image:getHeight()
  if
    atlas.x < 0
    or atlas.y < 0
    or atlas.width <= 0
    or atlas.height <= 0
    or atlas.x + atlas.width > imageWidth
    or atlas.y + atlas.height > imageHeight
  then
    error(what .. " frame escapes its atlas rect", 0)
  end
  assert(type(quadFor) == "function", what .. " drawing borrows its prepared quad lookup")
  local quad = quadFor(frame)
  assert(quad ~= nil, what .. " frame was never prepared")
  chrome:drawQuad(graphics, quad, anchorX + offset.x, anchorY + offset.y)
end

-- Paints one choice pill: chrome art only, no label. The renderer draws
-- the value glyphs after every pill so text shares one layout owner.
---@param graphics love.graphics borrowed graphics namespace
---@param chrome ImageAssetPoolLease borrowed chrome lease, never retained
---@param quadFor fun(frame: OptionsWidgets.SequenceFrame): love.Quad caller-owned prepared viewport lookup
---@param choice OptionsWidgets.ChoiceStates { unselected, selected } compiled choice sequences
---@param anchor OptionsWidgets.Point control anchor in logical pixels
---@param selected boolean whether the selected pill replaces the face patch
---@param ageTicks integer source ticks since the state was entered
function OptionsWidgets.drawChoice(graphics, chrome, quadFor, choice, anchor, selected, ageTicks)
  assert(type(choice) == "table" and choice.unselected ~= nil and choice.selected ~= nil, "choice needs both states")
  local anchorPoint = point(anchor, "choice anchor")
  withColor(graphics, function()
    local sequence = selected and choice.selected or choice.unselected
    drawFrame(graphics, chrome, quadFor, frameAt(sequence, ageTicks, "choice"), anchorPoint.x, anchorPoint.y, "choice")
  end)
end

-- Paints one frame arrow pair: chrome art only, no value label. The
-- renderer centers the value glyphs between the arrows.
---@param graphics love.graphics borrowed graphics namespace
---@param chrome ImageAssetPoolLease borrowed chrome lease, never retained
---@param quadFor fun(frame: OptionsWidgets.SequenceFrame): love.Quad caller-owned prepared viewport lookup
---@param arrows OptionsWidgets.ArrowSet { left = { idle, pressed }, right = { idle, pressed } }
---@param leftAnchor OptionsWidgets.Point left arrow anchor in logical pixels
---@param rightAnchor OptionsWidgets.Point right arrow anchor in logical pixels
---@param pressed string? "left", "right", or nil for the idle pair
---@param ageTicks integer source ticks since the press began
function OptionsWidgets.drawCycle(graphics, chrome, quadFor, arrows, leftAnchor, rightAnchor, pressed, ageTicks)
  assert(type(arrows) == "table" and arrows.left ~= nil and arrows.right ~= nil, "cycle needs both arrows")
  assert(pressed == nil or pressed == "left" or pressed == "right", "cycle press names a side or stays idle")
  local leftPoint = point(leftAnchor, "left arrow anchor")
  local rightPoint = point(rightAnchor, "right arrow anchor")
  withColor(graphics, function()
    local leftSequence = pressed == "left" and arrows.left.pressed or arrows.left.idle
    local rightSequence = pressed == "right" and arrows.right.pressed or arrows.right.idle
    drawFrame(
      graphics,
      chrome,
      quadFor,
      frameAt(leftSequence, ageTicks, "left arrow"),
      leftPoint.x,
      leftPoint.y,
      "arrow"
    )
    drawFrame(
      graphics,
      chrome,
      quadFor,
      frameAt(rightSequence, ageTicks, "right arrow"),
      rightPoint.x,
      rightPoint.y,
      "arrow"
    )
  end)
end

---@param graphics love.graphics borrowed graphics namespace
---@param resolved OptionsWidgets.SliderGeometry caller-owned Slider.resolve geometry
---@param focused boolean whether the focus outline surrounds the slider
---@param style OptionsWidgets.SliderStyle project-authored { rail, fill, thumb, thumbEdge, focus } 0..1 colors
function OptionsWidgets.drawSlider(graphics, resolved, focused, style)
  assert(type(resolved) == "table", "slider painting needs its resolved geometry")
  assert(
    type(resolved.trackStartX) == "number"
      and type(resolved.trackEndX) == "number"
      and resolved.trackEndX > resolved.trackStartX,
    "slider painting needs its usable track"
  )
  assert(type(resolved.thumbRect) == "table", "slider needs its thumb rect")
  local thumb = resolved.thumbRect
  assert(type(style) == "table", "slider painting needs its project-authored style")
  local railR, railG, railB, railA = color(assert(style.rail, "slider style needs its rail treatment"), "rail")
  local fillR, fillG, fillB, fillA = color(assert(style.fill, "slider style needs its fill treatment"), "fill")
  local thumbR, thumbG, thumbB, thumbA = color(assert(style.thumb, "slider style needs its thumb treatment"), "thumb")
  local edgeR, edgeG, edgeB, edgeA =
    color(assert(style.thumbEdge, "slider style needs its thumb edge treatment"), "thumbEdge")
  local railY = math.floor(resolved.centerY - 1 + 0.5)
  local thumbCenterX = thumb.x + thumb.width / 2
  withColor(graphics, function()
    graphics.setColor(railR, railG, railB, railA)
    graphics.rectangle("fill", resolved.trackStartX, railY, resolved.trackEndX - resolved.trackStartX, 2)
    graphics.setColor(fillR, fillG, fillB, fillA)
    graphics.rectangle("fill", resolved.trackStartX, railY, thumbCenterX - resolved.trackStartX, 2)
    graphics.setColor(thumbR, thumbG, thumbB, thumbA)
    graphics.rectangle("fill", thumb.x, thumb.y, thumb.width, thumb.height)
    graphics.setColor(edgeR, edgeG, edgeB, edgeA)
    graphics.rectangle("line", thumb.x + 0.5, thumb.y + 0.5, thumb.width - 1, thumb.height - 1)
    if focused then
      local focusR, focusG, focusB, focusA =
        color(assert(style.focus, "slider style needs its focus treatment"), "focus")
      graphics.setColor(focusR, focusG, focusB, focusA)
      graphics.rectangle(
        "line",
        resolved.rect.x - 2 + 0.5,
        resolved.rect.y - 2 + 0.5,
        resolved.rect.width + 4 - 1,
        resolved.rect.height + 4 - 1
      )
    end
  end)
end

-- Paints one footer action: chrome art only, no label. The renderer draws
-- the Confirm/Quit glyphs inside their own label windows.
---@param graphics love.graphics borrowed graphics namespace
---@param chrome ImageAssetPoolLease borrowed chrome lease, never retained
---@param quadFor fun(frame: OptionsWidgets.SequenceFrame): love.Quad caller-owned prepared viewport lookup
---@param action OptionsWidgets.ActionStates { normal, focused, pressed, pressedFocused } compiled footer sequences
---@param anchor OptionsWidgets.Point action anchor in logical pixels
---@param state string one of normal, focused, pressed, pressedFocused
---@param ageTicks integer source ticks since the state was entered
function OptionsWidgets.drawAction(graphics, chrome, quadFor, action, anchor, state, ageTicks)
  assert(
    state == "normal" or state == "focused" or state == "pressed" or state == "pressedFocused",
    "footer actions draw a compiled state"
  )
  assert(type(action) == "table" and action[state] ~= nil, "footer actions carry every compiled state")
  local anchorPoint = point(anchor, "action anchor")
  withColor(graphics, function()
    drawFrame(
      graphics,
      chrome,
      quadFor,
      frameAt(action[state], ageTicks, "action"),
      anchorPoint.x,
      anchorPoint.y,
      "action"
    )
  end)
end

return OptionsWidgets
