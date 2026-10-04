-- Shared field text-window composition: one stateless helper that draws an
-- explicit content box through the borrowed frame/fill primitive and then
-- prints each supplied line at its exact window-local origin with the
-- caller's palette. The helper owns no assets, frame choice, padding, or
-- application policy; every geometry/palette decision arrives explicitly
-- from the calling renderer.

local Assert = require("tests.support.Assert")

local T = {}

local function requireHelper()
  local ok, module = pcall(require, "libs.hgss.src.ui.FieldTextWindowRenderer")
  if not ok then
    error("the shared field text-window compositor is missing: " .. tostring(module), 0)
  end
  return module
end

local function sequenceSpy()
  local spy = { order = {}, windows = {}, lines = {}, fills = {} }
  local window = {}
  function window:drawWindow(box, frameIndex, background)
    spy.order[#spy.order + 1] = "window"
    spy.windows[#spy.windows + 1] = { box = box, frameIndex = frameIndex, background = background }
  end
  local text = {}
  function text:drawTextWithPalette(content, x, y, palette)
    spy.order[#spy.order + 1] = "text"
    spy.lines[#spy.lines + 1] = { text = content, x = x, y = y, palette = palette }
  end
  function text:textWidth(content)
    return #content * 8
  end
  local graphics = {}
  function graphics:setColor(r, g, b, a)
    spy.fills[#spy.fills + 1] = { r, g, b, a }
  end
  function graphics:rectangle(mode, x, y, w, h)
    spy.fills[#spy.fills + 1] = { mode = mode, x = x, y = y, w = w, h = h }
  end
  return spy, window, text, graphics
end

local function palette()
  return {
    foreground = { r = 8, g = 16, b = 24 },
    shadow = { r = 32, g = 40, b = 48 },
    background = { r = 56, g = 64, b = 72, a = 1 },
  }
end

local function spec(spy, window, text, graphics, overrides)
  local record = {
    graphics = graphics,
    window = window,
    text = text,
    box = { x = 16, y = 8, width = 216, height = 16 },
    frameIndex = 3,
    background = { 0.9, 0.9, 0.95, 1 },
    palette = palette(),
    lines = {
      { text = "first", x = 0, y = 0 },
      { text = "second", x = 0, y = 16 },
    },
  }
  for key, value in pairs(overrides or {}) do
    record[key] = value
  end
  return record
end

function T.window_draws_first_then_each_line_at_its_window_local_origin()
  local helper = requireHelper()
  local spy, window, text, graphics = sequenceSpy()
  helper.draw(spec(spy, window, text, graphics))
  Assert.deepEqual(spy.order, { "window", "text", "text" }, "the frame/fill draws before every text line")
  Assert.equal(#spy.windows, 1, "the content box draws exactly once")
  Assert.deepEqual(
    spy.windows[1].box,
    { x = 16, y = 8, width = 216, height = 16 },
    "the window keeps the caller content box"
  )
  Assert.equal(spy.windows[1].frameIndex, 3, "the window keeps the caller frame index")
  Assert.deepEqual(spy.windows[1].background, { 0.9, 0.9, 0.95, 1 }, "the window keeps the caller fill")
  Assert.equal(#spy.lines, 2, "every supplied line prints exactly once")
  Assert.equal(spy.lines[1].text, "first", "the first line keeps its content")
  Assert.equal(spy.lines[1].x, 16, "the first line starts at the content-box origin")
  Assert.equal(spy.lines[1].y, 8, "the first line keeps the content-box top")
  Assert.equal(spy.lines[2].x, 16, "the second line starts at the content-box origin")
  Assert.equal(spy.lines[2].y, 24, "the second line keeps its explicit window-local row")
  for _, line in ipairs(spy.lines) do
    Assert.deepEqual(line.palette, palette(), "every line uses the caller palette unchanged")
  end
end

function T.repeated_calls_mirror_their_inputs_without_retained_state()
  local helper = requireHelper()
  local spy, window, text, graphics = sequenceSpy()
  helper.draw(spec(spy, window, text, graphics))
  local secondPalette = {
    foreground = { r = 1, g = 2, b = 3 },
    shadow = { r = 4, g = 5, b = 6 },
    background = { r = 7, g = 8, b = 9, a = 0 },
  }
  helper.draw(spec(spy, window, text, graphics, {
    box = { x = 0, y = 144, width = 256, height = 48 },
    frameIndex = 7,
    background = { 0.1, 0.2, 0.3, 1 },
    palette = secondPalette,
    lines = { { text = "other", x = 4, y = 2 } },
  }))
  Assert.equal(#spy.windows, 2, "each call draws its own window")
  Assert.deepEqual(
    spy.windows[2].box,
    { x = 0, y = 144, width = 256, height = 48 },
    "the second call keeps its own content box"
  )
  Assert.equal(spy.windows[2].frameIndex, 7, "the second call keeps its own frame index")
  Assert.deepEqual(spy.windows[2].background, { 0.1, 0.2, 0.3, 1 }, "the second call keeps its own fill")
  Assert.equal(#spy.lines, 3, "the second call adds only its own line")
  Assert.equal(spy.lines[3].text, "other", "the second call keeps its own content")
  Assert.equal(spy.lines[3].x, 4, "the second call keeps its own local origin")
  Assert.equal(spy.lines[3].y, 146, "the second call offsets from its own content box")
  Assert.deepEqual(spy.lines[3].palette, secondPalette, "the second call keeps its own palette")
end

function T.missing_inputs_fail_instead_of_inventing_presentation()
  local helper = requireHelper()
  local spy, window, text, graphics = sequenceSpy()
  local valid = spec(spy, window, text, graphics)
  local function without(key)
    local record = spec(spy, window, text, graphics)
    record[key] = nil
    return record
  end
  for _, key in ipairs({ "window", "text", "box", "background", "palette", "lines" }) do
    Assert.throws(function()
      helper.draw(without(key))
    end, "a missing " .. key .. " fails instead of inventing presentation")
  end
  Assert.throws(function()
    helper.draw(spec(spy, window, text, graphics, { lines = {} }))
  end, "an empty line list fails instead of drawing a bare window")
  Assert.throws(function()
    helper.draw(spec(spy, window, text, graphics, { lines = { { x = 0, y = 0 } } }))
  end, "a line without text fails instead of printing nothing")
  Assert.equal(#spy.windows, 0, "no failed call draws a window")
  Assert.equal(#spy.lines, 0, "no failed call prints a line")
  Assert.equal(valid.box.x, 16, "the valid spec stays usable after the failure sequence")
end

return { tests = T }
