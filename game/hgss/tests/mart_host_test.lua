-- The field-owned mart host stages one child and publishes one task handle.

local Assert = require("tests.support.Assert")
local MartHost = require("game.hgss.src.mart.MartHost")

local T = {}

local function hostOptions(overrides)
  local state = {
    dates = 0,
    resolves = 0,
    opened = 0,
    closed = 0,
    cleared = 0,
    cancelled = 0,
    steps = 0,
    disposed = 0,
    childResult = nil,
  }
  local service = {
    processDate = function(_, date)
      state.dates = state.dates + 1
      Assert.deepEqual(date, { year = 2026, month = 10, day = 3 })
      return { weekday = 6, dayOrdinal = 100000 }
    end,
    cardPrefix = function()
      return 4
    end,
    athleteAvailable = function(_, stock)
      Assert.equal(stock.key, "athlete")
      return true
    end,
    openBuy = function(_, stock)
      state.opened = state.opened + 1
      state.stock = stock
      return {
        closed = false,
        close = function(session)
          session.closed = true
          state.closed = state.closed + 1
        end,
      }
    end,
    openSell = function()
      state.opened = state.opened + 1
      return {
        closed = false,
        close = function(session)
          session.closed = true
          state.closed = state.closed + 1
        end,
      }
    end,
  }
  local child = {
    status = function()
      return { open = true, state = "browse", presentation = {} }
    end,
    step = function()
      state.steps = state.steps + 1
    end,
    updateFixed = function()
      state.steps = state.steps + 1
    end,
    takeResult = function()
      local result = state.childResult
      state.childResult = nil
      return result
    end,
    cancelPointerCapture = function()
      state.cancelled = state.cancelled + 1
    end,
    dispose = function()
      state.disposed = state.disposed + 1
    end,
    refreshPresentation = function()
      state.refreshed = (state.refreshed or 0) + 1
    end,
  }
  local catalog = { mart = {}, items = {} }
  local options = {
    service = service,
    catalog = catalog,
    profile = { badges = 19, nationalDex = true, runningShoes = false, runningShoesLock = false },
    localDate = function()
      return { year = 2026, month = 10, day = 3 }
    end,
    stockResolver = function(descriptor, context, catalogPair)
      state.resolves = state.resolves + 1
      Assert.isTrue(descriptor.kind == "standard" or descriptor.kind == "athlete")
      Assert.equal(context.badges, 19)
      Assert.isTrue(context.nationalDex)
      Assert.equal(context.weekday, 6)
      Assert.equal(context.dayOrdinal, 100000)
      Assert.equal(context.cardPrefix, 4)
      Assert.isFalse(context.readFlag(0x09A))
      Assert.equal(context.readVariable(0x123), 0)
      Assert.equal(catalogPair, catalog)
      local resolvedKind = descriptor.kind
      context.badges = 0
      descriptor.kind = "sell"
      return { key = resolvedKind, entries = {} }
    end,
    getFlag = function()
      return false
    end,
    getVar = function()
      return 0
    end,
    createBuy = function()
      return child
    end,
    createSell = function()
      return child
    end,
    clearUi = function()
      state.cleared = state.cleared + 1
    end,
  }
  for key, value in pairs(overrides or {}) do
    options[key] = value
  end
  return MartHost.new(options), state
end

function T.open_stages_child_and_returns_a_read_only_presentation()
  local host, state = hostOptions()
  local handle = host:open("script:1", { kind = "standard" })
  Assert.isTrue(host:isActive())
  Assert.equal(host:activeHandle(), handle)
  Assert.equal(state.dates, 1)
  Assert.equal(state.resolves, 1)
  Assert.equal(state.opened, 1)
  Assert.equal(state.cleared, 1)
  local status = host:status()
  Assert.equal(status.state, "browse")
  Assert.equal(status.martKind, "buy")
  Assert.equal(state.steps, 0, "presentation reads never drive the child")
  host:refreshPresentation()
  Assert.equal(state.refreshed, 1)
end

function T.one_child_step_and_terminal_field_return_close_the_owned_session()
  local host, state = hostOptions()
  local handle = host:open("script:2", { kind = "standard" })
  host:step(handle, { { type = "confirm" } })
  Assert.equal(state.steps, 1)
  Assert.isNil(host:result(handle), "a live child has no terminal result")
  state.childResult = { kind = "close" }
  host:step(handle, {})
  Assert.isTrue(host:isActive(), "the task owns the handle through its return boundary")
  Assert.equal(state.closed, 1)
  Assert.equal(state.disposed, 1)
  Assert.equal(state.cancelled, 1)
  Assert.deepEqual(host:result(handle), { kind = "close" })
  Assert.isNil(host:result(handle), "a terminal child result is consumed once")
  host:close(handle)
  Assert.isFalse(host:isActive())
  Assert.equal(state.cleared, 2)
end

function T.custom_stock_bypasses_default_resolution_and_failed_child_never_publishes()
  local host, state = hostOptions()
  host:open("script:3", { kind = "custom", stock = { key = "custom", entries = {} } })
  Assert.equal(state.resolves, 0, "custom stock is already resolved by the schema contract")
  host:dispose()
  Assert.isFalse(host:isActive())

  local failed, failedState = hostOptions({
    createBuy = function()
      error("child allocation failed")
    end,
  })
  local ok = pcall(function()
    failed:open("script:4", { kind = "standard" })
  end)
  Assert.isFalse(ok)
  Assert.isFalse(failed:isActive())
  Assert.equal(failedState.closed, 1, "staged sessions close on child failure")
  Assert.equal(failedState.cleared, 0, "failed staging does not acquire the field UI lock")
end

function T.sell_uses_the_bag_child_and_queries_retain_the_opening_context()
  local sellChild = {
    status = function()
      return { open = true, state = "browse", presentation = {} }
    end,
    updateFixed = function() end,
    takeResult = function()
      return nil
    end,
    cancelPointerCapture = function() end,
    dispose = function() end,
    refreshPresentation = function() end,
  }
  local host, state = hostOptions({
    createSell = function(session)
      Assert.isFalse(session.closed)
      return sellChild
    end,
  })
  local handle = host:open("script:5", { kind = "sell" })
  Assert.equal(state.resolves, 0, "sale stock is owned by MartService rather than the buy resolver")
  Assert.equal(host:status().martKind, "sell", "sale presents the existing Bag child")
  Assert.equal(host:query("athlete_available"), 1)
  Assert.equal(state.dates, 1, "an active query reuses the opening date context")
  host:dispose()
  host:dispose()
  Assert.isFalse(host:isActive())
  Assert.equal(state.closed, 1)
end

return { tests = T }
