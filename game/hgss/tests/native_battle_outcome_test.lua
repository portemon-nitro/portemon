-- The battle host's native outcome projection: the source's own 0..6 word is
-- derived from the settled generic word plus the terminal flight side, a
-- flight without its side refuses to project one, and the generic words stay
-- exactly what they were.

local Assert = require("tests.support.Assert")
local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")

local T = {}

---@param outcome table<string, unknown>
---@return table<string, unknown> the runtime with only its terminal outcome bound
local function runtimeWithOutcome(outcome)
  return setmetatable({ _outcome = outcome }, BattleRuntime)
end

function T.the_source_words_are_their_own_closed_set()
  Assert.deepEqual(BattleRuntime.NATIVE_OUTCOME, {
    none = 0,
    win = 1,
    loss = 2,
    draw = 3,
    capture = 4,
    playerFled = 5,
    foeFled = 6,
  })
end

function T.every_settled_word_projects_its_native_code()
  local cases = {
    { word = "win", outcome = { kind = "no_actors" }, native = 1 },
    { word = "loss", outcome = { kind = "no_actors" }, native = 2 },
    { word = "draw", outcome = { kind = "no_actors" }, native = 3 },
    { word = "capture", outcome = { kind = "captured" }, native = 4 },
    { word = "flee", outcome = { kind = "escaped", fledSide = "player" }, native = 5 },
    { word = "flee", outcome = { kind = "escaped", fledSide = "foe" }, native = 6 },
  }
  for _, case in ipairs(cases) do
    local runtime = runtimeWithOutcome(case.outcome)
    Assert.equal(runtime:_mapNativeOutcome(case.word), case.native, case.word .. " projects its own source code")
  end
end

function T.a_flight_without_its_side_refuses_to_project()
  local runtime = runtimeWithOutcome({ kind = "escaped" })
  local err = Assert.throws(function()
    runtime:_mapNativeOutcome("flee")
  end)
  Assert.equal(tostring(err):match("must name the side that left") ~= nil, true, "the flight names its side")
end

function T.an_unknown_generic_word_refuses_to_project()
  local runtime = runtimeWithOutcome({ kind = "no_actors" })
  Assert.throws(function()
    runtime:_mapNativeOutcome("victory")
  end)
end

return { tests = T }
