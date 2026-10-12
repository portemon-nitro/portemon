-- The single-word entry presentation: the gate-established selector plan
-- plus its host draw. The plan binds the source sprite members, the
-- background member/layer binding, the interface banks, and the input
-- facts without invented pixels; composition resolves prepared image paths
-- onto it. Consumes the selector's detached status only; allocates no
-- images while drawing. Pure presentation: no love globals, the host
-- graphics namespace arrives through resources.

---@class PokegearWordEntryRenderer
local PokegearWordEntryRenderer = {}

-- Source sprite members behind the selector cursor and sprite proxies.
PokegearWordEntryRenderer.SPRITES = { cell = 7, animation = 8, mapping = 9, palette = 10 }

-- Background screen member 0 and character member 1 behind layers 0 and 4.
PokegearWordEntryRenderer.BACKGROUND = { screenMember = 0, charMember = 1, layers = { 0, 4 } }

-- Interface message banks behind the selector windows.
PokegearWordEntryRenderer.INTERFACE_BANKS = { 282, 283, 284 }

-- Five touch hitboxes with touch-held tracking and the confirm sound.
PokegearWordEntryRenderer.INPUT = { hitboxes = 5, touchYMin = 0x1C, touchYMax = 0xE2, confirmSound = 1500 }

---@param status table<string, unknown>
local function checkStatus(status)
  assert(type(status) == "table", "the word-entry render needs its selector status")
  assert(status.mode == "single-word", "only the single-word mode lays out the word selector")
end

-- Projects the selector layout plan from its detached status: focus plus
-- the source bindings the host draw consumes. No drawing happens here.
---@param status table<string, unknown> the detached selector view
---@return table<string, unknown> plan
function PokegearWordEntryRenderer.layout(status)
  checkStatus(status)
  local sprites = PokegearWordEntryRenderer.SPRITES
  local background = PokegearWordEntryRenderer.BACKGROUND
  local input = PokegearWordEntryRenderer.INPUT
  return {
    mode = "single-word",
    focus = {
      level = status.level,
      group = status.group,
      index = status.index,
      wordKey = status.wordKey,
    },
    groups = status.groupCount,
    groupSize = status.groupSize,
    sprites = {
      cell = sprites.cell,
      animation = sprites.animation,
      mapping = sprites.mapping,
      palette = sprites.palette,
    },
    background = {
      screenMember = background.screenMember,
      charMember = background.charMember,
      layers = { background.layers[1], background.layers[2] },
    },
    text = { interfaceBanks = { 282, 283, 284 } },
    input = {
      hitboxes = input.hitboxes,
      touchYMin = input.touchYMin,
      touchYMax = input.touchYMax,
      confirmSound = input.confirmSound,
    },
  }
end

-- Draws the selector inside the caller-owned transform: the prepared panel
-- image at the origin when composition resolved one, then the focused word
-- identity through the text primitive. Positions stay at the caller
-- origin; no selector pixel geometry is invented here.
---@param graphics love.graphics
---@param images table<string, unknown> borrowed prepared images by path
---@param text table<string, unknown>? borrowed text primitives
---@param content table<string, unknown> the plan payload with resolved paths
---@param view table<string, unknown> the detached selector view
function PokegearWordEntryRenderer.drawPane(graphics, images, text, content, view)
  assert(graphics ~= nil, "the word-entry render borrows its host graphics")
  assert(type(images) == "table", "the word-entry render borrows its prepared images")
  assert(type(content) == "table", "the word-entry render needs its plan payload")
  checkStatus(view)
  graphics.setColor(1, 1, 1, 1)
  local panelPath = content.panel
  if type(panelPath) == "string" then
    local panel = images[panelPath]
    if panel ~= nil then
      graphics.draw(panel, 0, 0)
    end
  end
  if text ~= nil and type(text.drawText) == "function" and view.wordKey ~= nil then
    assert(type(view.wordKey) == "string", "the focused word keeps its decimal identity")
    text:drawText(view.wordKey, 0, 0)
  end
  graphics.setColor(1, 1, 1, 1)
end

return PokegearWordEntryRenderer
