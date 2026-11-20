-- Ordinary window configuration. The ordinary boot path must seed the reference
-- size before applying independent environment overrides, and invalid
-- overrides must fail with the offending variable named. The reference size is
-- also a presentation contract: the whole-pixel presentation can only fill the
-- host window when the host is an exact integer multiple of the native pane.

local Assert = require("tests.support.Assert")
local NativeDisplay = require("libs.ui.src.NativeDisplay")
local PixelScale = require("libs.ui.src.PixelScale")
local WindowConfig = require("game.src.WindowConfig")

local T = {}

local function withOrdinaryConf(env, fn)
  local savedArg = arg
  local savedGetenv = os.getenv
  local savedConf = love.conf
  arg = {}
  os.getenv = function(name)
    local v = env[name]
    if v ~= nil then
      return v
    end
    return nil
  end
  local t = { window = {}, modules = {} }
  local ok, err = pcall(function()
    love.conf(t)
    fn(t)
  end)
  arg = savedArg
  os.getenv = savedGetenv
  love.conf = savedConf
  if not ok then
    error(err, 0)
  end
end

local function assertInvalid(env, expectedVar)
  local savedArg = arg
  local savedGetenv = os.getenv
  local savedConf = love.conf
  arg = {}
  os.getenv = function(name)
    local v = env[name]
    if v ~= nil then
      return v
    end
    return nil
  end
  local t = { window = {}, modules = {} }
  local ok, err = pcall(function()
    love.conf(t)
  end)
  arg = savedArg
  os.getenv = savedGetenv
  love.conf = savedConf
  Assert.isFalse(ok, "invalid environment must raise")
  Assert.notNil(err, "error must name " .. expectedVar)
  local message = err --[[@as string]]
  Assert.notNil(message:find(expectedVar, 1, true), "error must name " .. expectedVar)
end

function T.ordinary_configuration_defaults_to_reference_size()
  withOrdinaryConf({}, function(t)
    Assert.equal(t.window.width, WindowConfig.REFERENCE_WIDTH)
    Assert.equal(t.window.height, WindowConfig.REFERENCE_HEIGHT)
    Assert.isTrue(t.window.resizable)
    Assert.equal(t.window.vsync, 1)
  end)
end

function T.width_override_replaces_only_width()
  withOrdinaryConf({ PORTEMON_WINDOW_WIDTH = "800" }, function(t)
    Assert.equal(t.window.width, 800)
    Assert.equal(t.window.height, WindowConfig.REFERENCE_HEIGHT)
  end)
end

function T.height_override_replaces_only_height()
  withOrdinaryConf({ PORTEMON_WINDOW_HEIGHT = "600" }, function(t)
    Assert.equal(t.window.width, WindowConfig.REFERENCE_WIDTH)
    Assert.equal(t.window.height, 600)
  end)
end

function T.both_dimensions_override_together()
  withOrdinaryConf({ PORTEMON_WINDOW_WIDTH = "800", PORTEMON_WINDOW_HEIGHT = "600" }, function(t)
    Assert.equal(t.window.width, 800)
    Assert.equal(t.window.height, 600)
  end)
end

function T.invalid_width_is_rejected()
  assertInvalid({ PORTEMON_WINDOW_WIDTH = "0" }, "PORTEMON_WINDOW_WIDTH")
end

function T.invalid_height_is_rejected()
  assertInvalid({ PORTEMON_WINDOW_HEIGHT = "garbage" }, "PORTEMON_WINDOW_HEIGHT")
end

-- The default window shows exactly one native top screen at a single whole
-- pixel scale: no letterbox, no fractional scale. A size that only nearly
-- matches the pane (a non-integer multiple) would silently shrink every
-- fixed-size HGSS presentation into the window's centre.
function T.default_window_fits_one_native_top_screen_exactly()
  withOrdinaryConf({}, function(t)
    local bounds = { x = 0, y = 0, width = t.window.width, height = t.window.height }
    local placement = assert(
      PixelScale.placeFixed(bounds, NativeDisplay.WIDTH, NativeDisplay.HEIGHT),
      "the default window must place a native top screen"
    )
    Assert.equal(
      placement.pixelScale * NativeDisplay.WIDTH,
      t.window.width,
      "the default window width must be a whole number of native top screens"
    )
    Assert.equal(
      placement.pixelScale * NativeDisplay.HEIGHT,
      t.window.height,
      "the default window height must be a whole number of native top screens"
    )
    Assert.equal(placement.frame.x, 0, "the native top screen must start at the window origin")
    Assert.equal(placement.frame.y, 0, "the native top screen must start at the window origin")
  end)
end

return { tests = T }
