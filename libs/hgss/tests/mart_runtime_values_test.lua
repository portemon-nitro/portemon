-- Mart script operands resolve at the HGSS semantics boundary.

local Assert = require("tests.support.Assert")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")

local T = {}

function T.mart_descriptors_snapshot_custom_stock_and_evaluate_selectors_once()
  local reads = 0
  local run = {
    instance = { scriptId = "test.mart_values" },
    services = {
      world = {
        getVar = function(_, id)
          Assert.equal(id, "SELECTOR")
          reads = reads + 1
          return 4
        end,
      },
    },
  }
  local stock = { entries = { { key = "first", unitPrice = 100 } } }
  local descriptor = RuntimeValues.martTaskSpec({
    kind = "special",
    selector = { value = "var", id = "SELECTOR" },
    stock = stock,
  }, run)
  Assert.equal(reads, 1)
  Assert.equal(descriptor.selector, 4)
  Assert.isFalse(descriptor.stock == stock)
  stock.entries[1].unitPrice = 200
  Assert.equal(descriptor.stock.entries[1].unitPrice, 100)
end

function T.mart_queries_normalize_boolean_and_bound_card_prefix()
  local run = {
    instance = { scriptId = "test.mart_values" },
    services = {
      mart = {
        query = function(_, kind)
          if kind == "athlete_available" then
            return true
          end
          return 27
        end,
      },
    },
  }
  Assert.equal(RuntimeValues.martQuery("athlete_available", run), 1)
  Assert.equal(RuntimeValues.martQuery("card_prefix", run), 27)
end

function T.invalid_mart_selector_and_missing_query_service_fail()
  local run = {
    instance = { scriptId = "test.mart_values" },
    services = { world = { getVar = function() return "invalid" end } },
  }
  local selectorOk = pcall(RuntimeValues.martTaskSpec, {
    kind = "special",
    selector = { value = "var", id = "SELECTOR" },
  }, run)
  Assert.isFalse(selectorOk)
  local queryOk = pcall(RuntimeValues.martQuery, "card_prefix", run)
  Assert.isFalse(queryOk)
end

return { tests = T }
