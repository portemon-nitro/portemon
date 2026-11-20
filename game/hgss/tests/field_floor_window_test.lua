-- The source floor window (ScrCmd_ElevatorCurFloorBox) is a non-modal main
-- display window: the command shows it and returns in its own tick, and the
-- window lives until the script sets the observed result variable to 0xFFFF.
-- The owner never writes that sentinel itself and never blocks the script.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")

local T = {}

local RESULT_VAR = "VAR_TEMP_x4001"

-- Resolved inside each test so the missing host names the behavior under test
-- instead of failing the whole suite at load time.
local function floorWindow()
  return require("game.hgss.src.field.FieldFloorWindow")
end

local function host(opts)
  opts = opts or {}
  local variables = { [RESULT_VAR] = opts.result or 0 }
  local resolved = {}
  local instance = floorWindow().new({
    getVar = function(id)
      return variables[id] or 0
    end,
    resolveMessage = function(ref)
      resolved[#resolved + 1] = ref
      return "text for " .. ref
    end,
  })
  return instance, variables, resolved
end

local function request(overrides)
  local value = {
    map = "MAP_GOLDENROD_DEPARTMENT_STORE_ELEVATOR",
    tileX = 2,
    tileY = 3,
    floor = 4,
    result = { value = "var", id = RESULT_VAR },
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

function T.floor_window_shows_the_source_title_and_floor_label()
  local window = host()
  Assert.isNil(window:snapshot(), "no window exists before the source command runs")

  window:show(request({ floor = 0 }))
  local snapshot = assert(window:snapshot(), "the shown window is present immediately")
  Assert.equal(snapshot.tileX, 2, "the window sits at the source tile x")
  Assert.equal(snapshot.tileY, 3, "the window sits at the source tile y")
  Assert.equal(snapshot.heightTiles, 4, "the source window is four tiles high")
  Assert.equal(snapshot.floor, 0)
  Assert.equal(snapshot.titleMessage, "msg.hgss.0191.00016", "the source title message is unchanged")
  Assert.equal(snapshot.labelMessage, "msg.hgss.0191.00122", "the department store elevator names its basement floor")

  -- Every other floor of that elevator carries the ordinary floor label.
  local upperFloor = host()
  upperFloor:show(request({ floor = 4 }))
  Assert.equal(
    assert(upperFloor:snapshot()).labelMessage,
    "msg.hgss.0191.00017",
    "a numbered floor of the same elevator uses the ordinary label"
  )
  Assert.equal(snapshot.result.id, RESULT_VAR, "the window observes the source result variable")

  local defaultLabel = host()
  defaultLabel:show(request({ map = "MAP_OLIVINE_LIGHTHOUSE_ELEVATOR", floor = 2 }))
  Assert.equal(
    assert(defaultLabel:snapshot()).labelMessage,
    "msg.hgss.0191.00017",
    "an ordinal floor label is the default source message"
  )

  local condominiums = host()
  condominiums:show(request({ map = "MAP_CELADON_CONDOMINIUMS_LEFT_ELEVATOR", floor = 3 }))
  Assert.equal(
    assert(condominiums:snapshot()).labelMessage,
    "msg.hgss.0191.00125",
    "the condominiums elevator labels its roof floor with its own message"
  )
end

function T.floor_window_closes_only_when_the_result_variable_reaches_its_sentinel()
  local window, variables = host({ result = 0 })
  window:show(request())
  window:poll()
  Assert.notNil(window:snapshot(), "an unrelated result value keeps the window open")
  Assert.equal(variables[RESULT_VAR], 0, "polling the window never writes the result variable")

  variables[RESULT_VAR] = 6
  window:poll()
  Assert.notNil(window:snapshot(), "a floor number is not the closing sentinel")

  variables[RESULT_VAR] = 0xFFFF
  window:poll()
  Assert.isNil(window:snapshot(), "the source sentinel releases the window")
  window:poll()
  window:dispose()
  Assert.isNil(window:snapshot(), "a released window stays released")
end

function T.floor_window_disposal_releases_an_open_window_once()
  local window = host()
  window:show(request())
  window:dispose()
  Assert.isNil(window:snapshot(), "field teardown closes an open window")
  window:dispose()
  Assert.isNil(window:snapshot())

  window:show(request({ tileY = 1 }))
  Assert.notNil(window:snapshot(), "a later source command opens its own window again")
end

function T.floor_window_rejects_a_second_show_while_it_is_open()
  local window = host()
  window:show(request())
  local err = Assert.throws(function()
    window:show(request({ tileY = 5 }))
  end)
  Assert.isTrue(Errors.is(err), "a second open window is an attributed failure")
  Assert.equal(assert(window:snapshot()).tileY, 3, "the first window keeps its own placement")
end

return { tests = T }
