-- Keeps editor host placement aligned with physical pixels and authored bounds.

local Assert = require("tests.support.Assert")
local Interface = require("app.src.saveeditor.SaveEditorInterface")

local T = { tests = {} }

local function context(bounds, pixelRatio, configuration)
  local surface = { id = "primary", touch = false }
  return {
    configuration = configuration,
    measurement = { pixelRatio = pixelRatio },
    primary = { surface = surface, usableBounds = bounds },
    secondary = nil,
  }
end

local function view()
  return {
    status = "opening",
    message = "Preparing save editor",
    section = "Player",
    scope = { id = "section:Player", epoch = 0 },
    textMetrics = { lineHeight = 12, measure = function(text) return #text * 6 end },
  }
end

function T.tests.wide_editor_uses_one_integer_framebuffer_scale_with_the_measured_pixel_ratio()
  local plan = Interface.resolve(context({ x = 0, y = 0, width = 1280, height = 720 }, 2, "wide"), view())
  local placement = plan.panes[1].placement

  Assert.equal(placement.pixelScale, 3, "physical density selects one preferred integer framebuffer scale")
  Assert.equal(placement.pixelRatio, 2, "the placement retains the measured host pixel ratio")
  Assert.equal(placement.scale, 1.5, "host scale is framebuffer scale divided by pixel ratio")
  Assert.equal(plan.content.width, 1280 / 1.5, "the logical canvas covers the full host width")
  Assert.equal(plan.content.height, 720 / 1.5, "the logical canvas covers the full host height")
end

function T.tests.subminimum_editor_bounds_scale_the_full_authored_canvas_down()
  local plan = Interface.resolve(context({ x = 0, y = 0, width = 128, height = 96 }, 1, "nativeLike"), view())
  local placement = plan.panes[1].placement

  Assert.equal(plan.content.width, 256, "the authored logical width remains intact")
  Assert.equal(plan.content.height, 192, "the authored logical height remains intact")
  Assert.equal(placement.scale, 0.5, "the whole authored canvas is uniformly reduced to fit")
end

return T
