-- The pristine launcher entry is authored UI: it must render independently
-- of a ROM/cache and offer a usable pointer target on desktop and touch hosts.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local ImportState = require("app.src.launcher.ImportState")

local T = {}

function T.pristine_entry_fills_common_window_shapes_without_a_rom(scope)
  local importer = {
    status = function()
      return { state = "idle" }
    end,
  }
  local state = ImportState.new(importer, nil)

  for _, dimensions in ipairs({ { 480, 360 }, { 800, 450 }, { 360, 640 } }) do
    local width, height = dimensions[1], dimensions[2]
    local canvas = scope:own(love.graphics.newCanvas(width, height))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    state:draw()
    love.graphics.setCanvas()
    local image = canvas:newImageData()
    local _, _, _, alpha = image:getPixel(0, 0)
    Assert.isTrue(alpha > 0, "the authored entry must cover the full drawable")
  end
end

function T.mouse_and_touch_entry_targets_open_the_injected_picker(_)
  local pickerCalls = 0
  local importer = {
    status = function()
      return { state = "idle" }
    end,
  }
  local state = ImportState.new(importer, nil, {
    onPick = function()
      pickerCalls = pickerCalls + 1
    end,
  })

  Assert.equal(type(state.mousepressed), "function", "mouse input must reach the picker affordance")
  Assert.equal(type(state.touchpressed), "function", "touch input must reach the picker affordance")
  state:mousepressed(400, 300, 1, false, 1)
  state:touchpressed("touch", 400, 300, 0, 0, 1)

  Assert.equal(pickerCalls, 2, "each mouse or touch gesture opens the picker once")
end

return GraphicsSmoke.suite(T)
