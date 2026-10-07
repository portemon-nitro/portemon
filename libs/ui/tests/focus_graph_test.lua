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

function T.spatial_candidate_prefers_a_beam_neighbor_to_a_closer_diagonal()
  local FocusGraph = focusGraphModule()
  Assert.isTrue(type(FocusGraph.spatialCandidate) == "function", "spatial rectangle ranking is missing")

  local result = FocusGraph.spatialCandidate({ x = 0, y = 0, width = 10, height = 10 }, {
    { id = "diagonal", rect = { x = 11, y = 11, width = 2, height = 2 }, order = 1 },
    { id = "beam", rect = { x = 14, y = 2, width = 8, height = 6 }, order = 2 },
  }, "right")
  Assert.equal(result, "beam", "perpendicular beam overlap outranks a closer diagonal")
end

function T.spatial_candidate_uses_edge_distance_then_declaration_order()
  local FocusGraph = focusGraphModule()
  Assert.isTrue(type(FocusGraph.spatialCandidate) == "function", "spatial rectangle ranking is missing")

  local source = { x = 0, y = 0, width = 10, height = 10 }
  local candidates = {
    { id = "far", rect = { x = 24, y = 1, width = 2, height = 8 }, order = 1 },
    { id = "first-tie", rect = { x = 12, y = 1, width = 2, height = 8 }, order = 3 },
    { id = "near", rect = { x = 15, y = 1, width = 2, height = 8 }, order = 2 },
    { id = "second-tie", rect = { x = 12, y = 1, width = 2, height = 8 }, order = 4 },
  }
  Assert.equal(
    FocusGraph.spatialCandidate(source, candidates, "right"),
    "first-tie",
    "edge gap wins first and declaration order resolves an exact tie"
  )
end

function T.spatial_candidate_is_directional_and_invariant_under_translation_and_scale()
  local FocusGraph = focusGraphModule()
  Assert.isTrue(type(FocusGraph.spatialCandidate) == "function", "spatial rectangle ranking is missing")

  local candidates = {
    { id = "up", rect = { x = 12, y = 0, width = 10, height = 8 }, order = 1 },
    { id = "down", rect = { x = 12, y = 24, width = 10, height = 8 }, order = 2 },
    { id = "left", rect = { x = 0, y = 12, width = 8, height = 10 }, order = 3 },
    { id = "right", rect = { x = 24, y = 12, width = 8, height = 10 }, order = 4 },
  }
  local source = { x = 10, y = 10, width = 10, height = 10 }
  for _, direction in ipairs({ "up", "down", "left", "right" }) do
    Assert.equal(FocusGraph.spatialCandidate(source, candidates, direction), direction)
  end

  local translatedSource = { x = 1010, y = -490, width = 10, height = 10 }
  local translated = {}
  for index, candidate in ipairs(candidates) do
    translated[index] = {
      id = candidate.id,
      order = candidate.order,
      rect = {
        x = candidate.rect.x + 1000,
        y = candidate.rect.y - 500,
        width = candidate.rect.width,
        height = candidate.rect.height,
      },
    }
  end
  Assert.equal(FocusGraph.spatialCandidate(translatedSource, translated, "right"), "right")

  local scaledSource = { x = 20, y = 20, width = 20, height = 20 }
  local scaled = {}
  for index, candidate in ipairs(candidates) do
    scaled[index] = {
      id = candidate.id,
      order = candidate.order,
      rect = {
        x = candidate.rect.x * 2,
        y = candidate.rect.y * 2,
        width = candidate.rect.width * 2,
        height = candidate.rect.height * 2,
      },
    }
  end
  Assert.equal(FocusGraph.spatialCandidate(scaledSource, scaled, "right"), "right")
  Assert.isNil(FocusGraph.spatialCandidate(source, {}, "left"), "no forward candidate returns nil")
end

return { tests = T }
