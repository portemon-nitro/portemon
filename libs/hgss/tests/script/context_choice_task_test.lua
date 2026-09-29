-- Contextual two-choice task semantics: the host translates geometry into
-- row focus events and this task owns only selection state and the result.

local Assert = require("tests.support.Assert")
local ContextChoiceProvider = require("libs.hgss.src.interaction.ContextChoiceProvider")
local ContextChoiceTask = require("libs.hgss.src.script.tasks.ContextChoiceTask")

local T = {}

local function ctxWithChoice()
  local provider = ContextChoiceProvider.new()
  return {
    services = { contextChoice = provider },
    input = { uiEvents = {} },
  }, provider
end

function T.focus_selects_the_host_row_before_confirm()
  local ctx, provider = ctxWithChoice()
  local state = ContextChoiceTask.create(nil, ctx)
  ContextChoiceTask.poll(state, ctx)
  Assert.isTrue(provider:isActive(), "the task opens the provider while waiting")
  ctx.input.uiEvents = { { type = "focus", row = 1 } }
  ContextChoiceTask.poll(state, ctx)
  Assert.equal(state.selected, 1, "a host focus updates task selection")
  Assert.equal(assert(provider:status()).selected, 1, "a host focus updates provider selection")
  ctx.input.uiEvents = { { type = "confirm" } }
  local outcome = ContextChoiceTask.poll(state, ctx)
  Assert.isTrue(outcome.complete, "confirm completes the waiting choice")
  Assert.equal(outcome.result, 1, "confirm answers the focused row")
end

function T.focus_row_is_validated()
  local ctx, _ = ctxWithChoice()
  local state = ContextChoiceTask.create(nil, ctx)
  ContextChoiceTask.poll(state, ctx)
  ctx.input.uiEvents = { { type = "focus", row = 2 } }
  local ok, _ = pcall(ContextChoiceTask.poll, state, ctx)
  Assert.isFalse(ok, "a focus outside the two rows fails loudly")
end

function T.keyboard_navigation_after_pointer_focus_starts_from_provider_selection()
  local ctx, provider = ctxWithChoice()
  local state = ContextChoiceTask.create(nil, ctx)
  ContextChoiceTask.poll(state, ctx)
  ctx.input.uiEvents = { { type = "focus", row = 1 } }
  ContextChoiceTask.poll(state, ctx)
  ctx.input.uiEvents = { { type = "navigate", direction = "up" } }
  ContextChoiceTask.poll(state, ctx)
  Assert.equal(state.selected, 0, "keyboard navigation moves from the focused row")
  Assert.equal(assert(provider:status()).selected, 0, "the provider follows keyboard navigation")
end

function T.unknown_events_stay_loud()
  local ctx, _ = ctxWithChoice()
  local state = ContextChoiceTask.create(nil, ctx)
  ContextChoiceTask.poll(state, ctx)
  ctx.input.uiEvents = { { type = "hover" } }
  local ok, _ = pcall(ContextChoiceTask.poll, state, ctx)
  Assert.isFalse(ok, "unknown task events must not pass silently")
end

return { tests = T }
