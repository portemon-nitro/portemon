-- The source floor window (ScrCmd_ElevatorCurFloorBox) is a non-modal main
-- display window: the command shows it and returns in its own tick, and the
-- window lives until the script sets the observed result variable to 0xFFFF.
-- The owner never writes that sentinel itself and never blocks the script.
-- Both source messages expand through the calling script's buffered text, so
-- the injected resolver takes that text and answers the formatted-message
-- record a source text expansion produces; the window snapshots only the
-- display string the field text renderer draws.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")

local T = {}

local RESULT_VAR = "VAR_TEMP_x4001"

-- Resolved inside each test so the missing host names the behavior under test
-- instead of failing the whole suite at load time.
local function floorWindow()
  return require("game.hgss.src.field.FieldFloorWindow")
end

-- The field message provider's formatted-message shape: the expanded display
-- text plus the glyph stream behind it. The text differs from the message
-- reference so the snapshot assertions prove which value the window stores.
local function formattedMessage(ref)
  return {
    bankId = 191,
    messageId = 0,
    text = "display of " .. ref,
    tokens = {
      { kind = "glyph", code = 0x0121, text = "1", raw = { 0x0121 } },
      { kind = "eos", raw = { 0xFFFF } },
    },
    hadUnresolvedSubstitutions = false,
  }
end

local function host(opts)
  opts = opts or {}
  local variables = { [RESULT_VAR] = opts.result or 0 }
  local resolved = {}
  local instance = floorWindow().new({
    getVar = function(id)
      return variables[id] or 0
    end,
    resolveMessage = function(ref, textArgs)
      resolved[#resolved + 1] = { ref = ref, textArgs = textArgs }
      if opts.bareString then
        return "text for " .. ref
      end
      return formattedMessage(ref)
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

-- The snapshot carries display text, not the formatted-message records the
-- resolver answers: the field text renderer measures and draws strings.
function T.floor_window_snapshot_carries_the_expanded_display_text()
  local window = host()
  window:show(request())
  local snapshot = assert(window:snapshot())
  Assert.equal(snapshot.title, "display of msg.hgss.0191.00016", "the title snapshot is the expanded text")
  Assert.equal(snapshot.label, "display of msg.hgss.0191.00017", "the label snapshot is the expanded text")
  Assert.isTrue(type(snapshot.title) == "string", "the drawn title is a string")
  Assert.isTrue(type(snapshot.label) == "string", "the drawn label is a string")
end

-- The source strips both messages through the calling script's MessageFormat,
-- so the script's buffered text reaches the resolves of the title and of the
-- ordinary floor label that substitutes it.
function T.floor_window_resolves_both_messages_with_the_script_buffered_text()
  local window, _, resolved = host()
  local textArgs = { [0] = { text = "dept_store_floor_no", floor = 4 } }
  window:show(request({ floor = 4, textArgs = textArgs }))

  Assert.equal(#resolved, 2, "the window resolves its title and its floor label")
  Assert.equal(resolved[1].ref, "msg.hgss.0191.00016", "the title is the source title message")
  Assert.equal(resolved[2].ref, "msg.hgss.0191.00017", "a numbered floor resolves the substitution template")
  Assert.isTrue(resolved[1].textArgs == textArgs, "the title resolves against the script's buffered text")
  Assert.isTrue(resolved[2].textArgs == textArgs, "the floor label resolves against the script's buffered text")
end

-- A resolver answering a bare string is a broken collaborator contract: it
-- faults at the window instead of handing the renderer a value it cannot measure.
function T.floor_window_faults_when_its_resolver_answers_a_bare_string()
  local window = host({ bareString = true })
  local err = Assert.throws(function()
    window:show(request())
  end)
  Assert.isTrue(
    tostring(err):find("formatted message", 1, true) ~= nil,
    "the wrong resolver contract names the formatted-message record it requires"
  )
  Assert.isNil(window:snapshot(), "a failed show leaves no half-open window")
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
