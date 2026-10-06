-- Ordered directional candidate resolution over an explicitly supplied graph.
-- The resolver skips absent candidates, returns the current node when nothing
-- is present, and fails loudly on programmer errors. Consumers own graph
-- construction, focus state, and navigation policy.

local Assert = require("tests.support.Assert")

local T = {}

local function focusGraphModule()
  local ok, mod = pcall(require, "libs.ui.src.FocusGraph")
  Assert.isTrue(ok, "directional focus primitive is missing: " .. tostring(mod))
  return mod
end

function T.returns_the_first_present_candidate()
  local FocusGraph = focusGraphModule()
  local graph = {
    here = { up = { "a", "b" }, down = {}, left = {}, right = {} },
    a = { up = {}, down = {}, left = {}, right = {} },
    b = { up = {}, down = {}, left = {}, right = {} },
  }
  Assert.equal(FocusGraph.move(graph, "here", "up"), "a")
end

function T.skips_absent_candidates_in_declared_order()
  local FocusGraph = focusGraphModule()
  local graph = {
    here = { up = { "missing", "second", "third" }, down = {}, left = {}, right = {} },
    second = { up = {}, down = {}, left = {}, right = {} },
    third = { up = {}, down = {}, left = {}, right = {} },
  }
  Assert.equal(FocusGraph.move(graph, "here", "up"), "second")
end

function T.returns_the_current_node_when_no_candidate_is_present()
  local FocusGraph = focusGraphModule()
  local graph = {
    here = { up = { "ghost-a", "ghost-b" }, down = {}, left = {}, right = {} },
  }
  Assert.equal(FocusGraph.move(graph, "here", "up"), "here")
  local empty = {
    here = { up = {}, down = {}, left = {}, right = {} },
  }
  Assert.equal(FocusGraph.move(empty, "here", "right"), "here")
end

function T.supports_integer_node_ids()
  local FocusGraph = focusGraphModule()
  local graph = {
    [0] = { up = {}, down = { 3, 0, 1 }, left = {}, right = { 4, 0, 0 } },
    [1] = { up = {}, down = {}, left = {}, right = {} },
    [3] = { up = {}, down = {}, left = {}, right = {} },
    [4] = { up = {}, down = {}, left = {}, right = {} },
  }
  Assert.equal(FocusGraph.move(graph, 0, "right"), 4)
  local hole = {
    [1] = { up = { 0, 3, 2 }, down = {}, left = {}, right = {} },
    [3] = { up = {}, down = {}, left = {}, right = {} },
  }
  Assert.equal(FocusGraph.move(hole, 1, "up"), 3)
end

function T.rejects_an_unknown_direction()
  local FocusGraph = focusGraphModule()
  local graph = {
    here = { up = {}, down = {}, left = {}, right = {} },
  }
  Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- test deliberately exercises an unknown direction
    FocusGraph.move(graph, "here", "diagonal")
  end, "an unknown direction must fail loudly")
end

function T.rejects_a_missing_current_node()
  local FocusGraph = focusGraphModule()
  local graph = {
    here = { up = {}, down = {}, left = {}, right = {} },
  }
  Assert.throws(function()
    FocusGraph.move(graph, "elsewhere", "up")
  end, "a missing current node must fail loudly")
end

function T.rejects_a_direction_field_that_is_not_an_ordered_list()
  local FocusGraph = focusGraphModule()
  local graph = {
    here = { up = "not-a-list", down = {}, left = {}, right = {} },
  }
  Assert.throws(function()
    FocusGraph.move(graph, "here", "up")
  end, "a direction field that is not an array must fail loudly")
end

function T.reconcile_keeps_the_live_current_target()
  local FocusGraph = focusGraphModule()
  Assert.isTrue(type(FocusGraph.reconcile) == "function", "the reconciliation primitive is missing")
  local graph = {
    here = { up = {}, down = {}, left = {}, right = {} },
    fallback = { up = {}, down = {}, left = {}, right = {} },
  }
  Assert.equal(FocusGraph.reconcile(graph, "here", { "fallback" }), "here")
end

function T.reconcile_selects_the_first_present_fallback()
  local FocusGraph = focusGraphModule()
  Assert.isTrue(type(FocusGraph.reconcile) == "function", "the reconciliation primitive is missing")
  local graph = {
    second = { up = {}, down = {}, left = {}, right = {} },
    third = { up = {}, down = {}, left = {}, right = {} },
  }
  Assert.equal(FocusGraph.reconcile(graph, "gone", { "missing", "second", "third" }), "second")
  Assert.equal(FocusGraph.reconcile(graph, nil, { "missing", "third" }), "third")
end

function T.reconcile_accepts_integer_node_ids()
  local FocusGraph = focusGraphModule()
  Assert.isTrue(type(FocusGraph.reconcile) == "function", "the reconciliation primitive is missing")
  local graph = {
    [1] = { up = {}, down = {}, left = {}, right = {} },
    [3] = { up = {}, down = {}, left = {}, right = {} },
  }
  Assert.equal(FocusGraph.reconcile(graph, 0, { 2, 3 }), 3)
  Assert.equal(FocusGraph.reconcile(graph, 1, { 3 }), 1)
end

function T.reconcile_rejects_malformed_inputs_and_exhausted_fallbacks()
  local FocusGraph = focusGraphModule()
  Assert.isTrue(type(FocusGraph.reconcile) == "function", "the reconciliation primitive is missing")
  local graph = {
    here = { up = {}, down = {}, left = {}, right = {} },
  }
  Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- test deliberately exercises a malformed graph
    FocusGraph.reconcile(nil, "here", { "here" })
  end, "a missing graph must fail loudly")
  Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- test deliberately exercises a malformed fallback list
    FocusGraph.reconcile(graph, "gone", "here")
  end, "a fallback list that is not an array must fail loudly")
  Assert.throws(function()
    FocusGraph.reconcile(graph, "gone", { "missing" })
  end, "exhausted fallbacks must fail loudly")
  Assert.throws(function()
    FocusGraph.reconcile(graph, nil, {})
  end, "an empty fallback list must fail loudly")
end

function T.reconcile_never_mutates_the_graph_or_fallbacks()
  local FocusGraph = focusGraphModule()
  Assert.isTrue(type(FocusGraph.reconcile) == "function", "the reconciliation primitive is missing")
  local graph = {
    here = { up = {}, down = {}, left = {}, right = {} },
  }
  local fallbacks = { "missing", "here" }
  Assert.equal(FocusGraph.reconcile(graph, "gone", fallbacks), "here")
  Assert.deepEqual(fallbacks, { "missing", "here" }, "fallback lists must be left untouched")
  Assert.isNil(graph["missing"], "absent candidates must not be materialized")
  Assert.isNil(graph["gone"], "absent current ids must not be materialized")
end

function T.never_mutates_the_graph()
  local FocusGraph = focusGraphModule()
  local graph = {
    here = { up = { "missing", "there" }, down = {}, left = {}, right = {} },
    there = { up = {}, down = {}, left = {}, right = {} },
  }
  local before = {
    here = { up = { "missing", "there" } },
  }
  Assert.equal(FocusGraph.move(graph, "here", "up"), "there")
  Assert.deepEqual(graph.here.up, before.here.up, "candidate lists must be left untouched")
  Assert.isNil(graph["missing"], "absent candidates must not be materialized")
end

return { tests = T }
