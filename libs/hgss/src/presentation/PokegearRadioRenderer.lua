-- The radio card's exact frame composition: the two independent native
-- control planes stacked full-pane, the information-side upper plane
-- full-pane under the text, the information text panel sliding eighty
-- host pixels in eight ten-pixel steps, the pulse sprite seated on the
-- tuned cursor with its source frames, and focus corners answering
-- focus. Consumes resolved image paths, the detached radio view, and
-- the matched pane placements only; allocates no images while drawing.
-- Pure presentation: no love globals, the host graphics namespace
-- arrives through resources, and draw performs no update, query,
-- mutation, or source parsing.

---@class PokegearRadioRenderer
local PokegearRadioRenderer = {}

local SLIDE_STEPS = 8
local SLIDE_PIXELS = 10
local TEXT_LINE_HEIGHT = 16

---@param images table<string, unknown> pooled atlas leases by generated path
---@param path string
---@return table<string, unknown> pooled atlas lease behind the plane
local function preparedImage(images, path)
  assert(type(path) == "string", "the radio plan resolves its image paths")
  local lease = images[path]
  assert(lease ~= nil, "the radio render needs its prepared image")
  return lease
end

---@param placement table<string, unknown>
---@return table<string, number> frame, number scale, table<string, number> origin
local function placementParts(placement)
  assert(type(placement) == "table", "the radio render borrows its pane placements")
  local frame = assert(placement.frame, "pane placements carry their frames")
  assert(type(frame) == "table", "pane frames read as records")
  local typed = frame --[[@as table<string, number>]]
  assert(type(typed.x) == "number" and type(typed.y) == "number", "pane frames carry their origins")
  assert(type(typed.width) == "number" and type(typed.height) == "number", "pane frames carry their sizes")
  local scale = placement.scale
  assert(type(scale) == "number" and scale > 0, "pane placements carry their scales")
  local origin = placement.origin or frame
  assert(type(origin) == "table", "pane placements resolve their origins")
  return typed, scale, origin --[[@as table<string, number>]]
end

---@param placement table<string, unknown>
---@param sourceX number
---@param sourceY number
---@return number x, number y host point through the published placement
local function toHost(placement, sourceX, sourceY)
  local _, scale, origin = placementParts(placement)
  local typed = origin --[[@as table<string, number>]]
  return typed.x + sourceX * scale, typed.y + sourceY * scale
end

---@param graphics table<string, unknown> host graphics namespace
---@param lease table<string, unknown> pooled atlas lease behind the plane
---@param x number
---@param y number
---@param width number
---@param height number
local function drawStretched(graphics, lease, x, y, width, height)
  local image = assert(lease.image, "atlas leases carry their resolved image")
  local getWidth = assert(image.getWidth, "prepared images carry their widths")
  local getHeight = assert(image.getHeight, "prepared images carry their heights")
  assert(type(getWidth) == "function" and type(getHeight) == "function", "prepared images size")
  local nativeWidth = getWidth(image)
  local nativeHeight = getHeight(image)
  assert(type(nativeWidth) == "number" and nativeWidth > 0, "prepared images size")
  assert(type(nativeHeight) == "number" and nativeHeight > 0, "prepared images size")
  lease:draw(graphics, x, y, 0, width / nativeWidth, height / nativeHeight)
end

---@param graphics table<string, unknown>
---@param frame table<string, number>
local function scissorFrame(graphics, frame)
  local setScissor = assert(graphics.setScissor, "the host graphics clips panes")
  assert(type(setScissor) == "function", "the host graphics clips panes")
  setScissor(frame.x, frame.y, frame.width, frame.height)
end

---@param graphics table<string, unknown>
local function resetScissor(graphics)
  local setScissor = assert(graphics.setScissor, "the host graphics clips panes")
  assert(type(setScissor) == "function", "the host graphics clips panes")
  setScissor()
end

-- Draws the radio panes over the matched information/controls placements:
-- the two control planes stacked full-pane, then the pulse sprite and
-- focus corners; the information upper plane full-pane, then the text,
-- then the sliding panel. Runs in host units through the published
-- placements so drawn cursor pixels round-trip through the pointer
-- inverse. Each plane draws independently over its own full pane under
-- the pane window clip; no plane is banded into an invented sub-region
-- and the information-side upper plane never paints the controls pane.
---@param graphics table<string, unknown> the host graphics namespace
---@param images table<string, unknown> borrowed prepared images by path
---@param textRenderer table<string, unknown>? borrowed text primitives
---@param content table<string, unknown> the plan payload with resolved paths
---@param view table<string, unknown> the detached radio view
---@param panes table<string, unknown> pane id to matched placement
function PokegearRadioRenderer.drawPanes(graphics, images, textRenderer, content, view, panes)
  assert(type(graphics) == "table", "the radio render borrows its host graphics")
  assert(type(images) == "table", "the radio render borrows its prepared images")
  assert(type(content) == "table", "the radio render reads its plan payload")
  assert(type(view) == "table", "the radio render reads its detached view")
  assert(type(panes) == "table", "the radio render borrows its pane placements")
  local infoPlacement = assert(panes.information, "the radio plan places its information pane")
  local controlsPlacement = assert(panes.controls, "the radio plan places its controls pane")
  local infoFrame = placementParts(infoPlacement)
  assert(type(infoFrame) == "table", "the information pane carries its frame")
  local controlsFrame = placementParts(controlsPlacement)
  assert(type(controlsFrame) == "table", "the controls pane carries its frame")
  local cursor = assert(view.cursor, "the radio view carries its tuner cursor")
  assert(type(cursor) == "table", "the radio view carries its tuner cursor")
  assert(type(cursor.x) == "number" and type(cursor.y) == "number", "the tuner cursor carries its dial point")
  local station = assert(view.station, "the radio view carries its tuned station")
  assert(type(station) == "number", "the tuned station reads as a number")
  local slideStep = assert(view.slideStep, "the radio view carries its panel slide step")
  assert(type(slideStep) == "number", "the panel slide step reads as a number")
  local pulseFrame = assert(view.pulseFrame, "the radio view carries its pulse frame")
  assert(type(pulseFrame) == "number", "the pulse frame reads as a number")
  assert(view.focused ~= nil, "the radio view carries its focus")
  local setColor = assert(graphics.setColor, "the host graphics sets colors")
  assert(type(setColor) == "function", "the host graphics sets colors")

  -- Controls pane: the two native control planes (MAIN BG3 then BG2)
  -- each drawn independently over the full pane under the pane window
  -- clip, the pulse sprite on the tuned cursor, and the focus corners.
  scissorFrame(graphics, controlsFrame)
  setColor(1, 1, 1, 1)
  drawStretched(
    graphics,
    preparedImage(images, content.main),
    controlsFrame.x,
    controlsFrame.y,
    controlsFrame.width,
    controlsFrame.height
  )
  drawStretched(
    graphics,
    preparedImage(images, content.second),
    controlsFrame.x,
    controlsFrame.y,
    controlsFrame.width,
    controlsFrame.height
  )
  if station ~= 255 then
    local pulseFrames = assert(content.pulseFrames, "the radio plan resolves its pulse frames")
    assert(type(pulseFrames) == "table", "the radio plan resolves its pulse frames")
    local pulse = preparedImage(images, assert(pulseFrames[pulseFrame + 1], "the radio view selects a pulse frame"))
    local hostX, hostY = toHost(controlsPlacement, cursor.x, cursor.y)
    local _, scale = placementParts(controlsPlacement)
    local pulseImage = assert(pulse.image, "atlas leases carry their resolved image")
    local getWidth = assert(pulseImage.getWidth, "prepared images carry their widths")
    local getHeight = assert(pulseImage.getHeight, "prepared images carry their heights")
    local nativeWidth = getWidth(pulseImage) --[[@as number]]
    local nativeHeight = getHeight(pulseImage) --[[@as number]]
    pulse:draw(graphics, hostX - (nativeWidth * scale) / 2, hostY - (nativeHeight * scale) / 2, 0, scale, scale)
  end
  if view.focused == true then
    local corner = preparedImage(images, content.corner)
    local cornerImage = assert(corner.image, "atlas leases carry their resolved image")
    local getWidth = assert(cornerImage.getWidth, "prepared images carry their widths")
    local getHeight = assert(cornerImage.getHeight, "prepared images carry their heights")
    local cornerWidth = getWidth(cornerImage) --[[@as number]]
    local cornerHeight = getHeight(cornerImage) --[[@as number]]
    corner:draw(graphics, controlsFrame.x, controlsFrame.y)
    corner:draw(graphics, controlsFrame.x + controlsFrame.width - cornerWidth, controlsFrame.y)
    corner:draw(graphics, controlsFrame.x, controlsFrame.y + controlsFrame.height - cornerHeight)
    corner:draw(
      graphics,
      controlsFrame.x + controlsFrame.width - cornerWidth,
      controlsFrame.y + controlsFrame.height - cornerHeight
    )
  end
  resetScissor(graphics)

  -- Information pane: the native information-side upper plane (SUB3)
  -- drawn independently over the full pane under the pane window clip,
  -- then the host/body text, then the sliding panel as the pane's moving
  -- plane-colored paint under its source window masks.
  scissorFrame(graphics, infoFrame)
  setColor(1, 1, 1, 1)
  drawStretched(
    graphics,
    preparedImage(images, content.upper),
    infoFrame.x,
    infoFrame.y,
    infoFrame.width,
    infoFrame.height
  )
  if textRenderer ~= nil and type(textRenderer.drawText) == "function" then
    local drawText = textRenderer.drawText
    assert(type(drawText) == "function", "the text primitives draw lines")
    if type(content.title) == "string" then
      drawText(textRenderer, content.title, infoFrame.x + 8, infoFrame.y + 8)
    end
    local body = content.body
    if type(body) == "table" then
      for index, line in ipairs(body) do
        if type(line) == "string" then
          drawText(textRenderer, line, infoFrame.x + 8, infoFrame.y + 8 + index * TEXT_LINE_HEIGHT)
        end
      end
    end
  end
  local clampedStep = slideStep
  if clampedStep < 0 then
    clampedStep = 0
  elseif clampedStep > SLIDE_STEPS then
    clampedStep = SLIDE_STEPS
  end
  local panelWidth = infoFrame.width - SLIDE_STEPS * SLIDE_PIXELS
  assert(panelWidth > 0, "the information pane fits the panel slide")
  local panel = preparedImage(images, content.panel)
  local panelImage = assert(panel.image, "atlas leases carry their resolved image")
  local panelGetWidth = assert(panelImage.getWidth, "prepared images carry their widths")
  local panelGetHeight = assert(panelImage.getHeight, "prepared images carry their heights")
  local panelNativeWidth = panelGetWidth(panelImage) --[[@as number]]
  local panelNativeHeight = panelGetHeight(panelImage) --[[@as number]]
  assert(type(panelNativeWidth) == "number" and panelNativeWidth > 0, "prepared images size")
  assert(type(panelNativeHeight) == "number" and panelNativeHeight > 0, "prepared images size")
  local panelHeight = panelWidth * panelNativeHeight / panelNativeWidth
  local panelY = infoFrame.y + (infoFrame.height - panelHeight) / 2
  panel:draw(
    graphics,
    infoFrame.x + clampedStep * SLIDE_PIXELS,
    panelY,
    0,
    panelWidth / panelNativeWidth,
    panelHeight / panelNativeHeight
  )
  resetScissor(graphics)
  setColor(1, 1, 1, 1)
end

return PokegearRadioRenderer
