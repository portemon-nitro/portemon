-- Script party selection through the persistent script-owned host: the
-- task opens one PartyScreenState in pick context per selection, persists
-- semantic focus (slot or cancel) across polls, translates exactly one
-- slot-or-cancellation outcome into the instance-scoped source handoff,
-- and closes the host exactly once. Selection mutates no party state.
-- Only the named eligibility policy, the cancel permission, and the
-- cursor serialize; the live screen is rebuilt from value-only state.
-- Source sentinel translation lives here alone: the host only ever emits
-- the semantic selected/cancelled records.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Errors = require("libs.errors.src.Errors")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PartySelectTask = require("libs.hgss.src.script.tasks.PartySelectTask")
local ScriptErrors = require("libs.script.src.errors")

local T = {}

local function openService()
  local catalog = CatalogFixture.makeCatalog()
  return HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0xAAAAAAAA):capture(), catalog:fingerprint()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  })
end

local function give(service, species)
  Assert.isTrue(
    service:giveMon({
      species = species,
      level = 5,
      heldItem = "NONE",
      form = 0,
      location = 7,
      date = CatalogFixture.metDate(),
    }),
    "setup gift must enter the party"
  )
end

local function request(overrides)
  local base = {
    mode = "select",
    initialSlot = 0,
    eligibility = { policy = "occupied" },
    allowCancel = true,
  }
  for key, value in pairs(overrides or {}) do
    base[key] = value
  end
  return { request = base }
end

-- Scripted host behind the task-owned open/step/result/focus/close
-- protocol. It asserts the protocol shape (opaque handle identity, event
-- list input) and returns canned focus/results; it never reimplements
-- navigation — the real focus/result chain lives in the host and
-- scheduler journeys.
local function hostDouble()
  local host = { opens = {}, steps = {}, closes = 0, active = nil, nextId = 0 }
  host.script = { focus = 0, result = nil }
  function host:open(openRequest)
    assert(type(openRequest) == "table", "the host opens from a value-only request")
    assert(type(openRequest.allowCancel) == "boolean", "the host open carries the cancel permission")
    assert(type(openRequest.policy) == "string", "the host open carries the named policy")
    if self.active ~= nil then
      error("a script party selection is already open", 0)
    end
    self.nextId = self.nextId + 1
    local handle = { id = self.nextId }
    self.active = { handle = handle, focus = openRequest.focus }
    self.opens[#self.opens + 1] = openRequest
    return handle
  end
  function host:activeHandle()
    if self.active == nil then
      return nil
    end
    return self.active.handle
  end
  function host:step(handle, events)
    assert(self.active ~= nil and handle == self.active.handle, "steps drive the open selection")
    assert(type(events) == "table", "steps carry the scheduler event list")
    self.steps[#self.steps + 1] = events
    return { open = true, focus = self.script.focus }
  end
  function host:result(handle)
    assert(self.active ~= nil and handle == self.active.handle, "results read the open selection")
    return self.script.result
  end
  function host:focus(handle)
    assert(self.active ~= nil and handle == self.active.handle, "focus reads the open selection")
    return self.script.focus
  end
  function host:close(handle)
    assert(self.active ~= nil and handle == self.active.handle, "close releases the open selection")
    self.active = nil
    self.closes = self.closes + 1
  end
  function host:status()
    if self.active == nil then
      return nil
    end
    return { open = true, focus = self.script.focus }
  end
  return host
end

local function context(service, host, input)
  return {
    services = { mons = service, partySelection = host },
    input = input or {},
    tick = 7,
    instance = { locals = {} },
  }
end

function T.selection_completes_with_the_zero_based_slot()
  local service = openService()
  give(service, "CHIKORITA")
  give(service, "TOTODILE")
  local host = hostDouble()
  host.script.result = { kind = "selected", slot = 1 }
  local revision = service:partyRevision()
  local state = PartySelectTask.create(request(), context(service, host))
  local parked = context(service, host, { uiEvents = {} })
  local outcome = PartySelectTask.poll(state, parked)
  Assert.isTrue(outcome.complete, "the translated selection completes the task")
  Assert.equal(parked.instance.locals.__party_selection, 1, "the task parks the zero-based slot on the instance")
  Assert.equal(service:partyRevision(), revision, "selection mutates no party state")
  Assert.equal(host.closes, 1, "completion closes the host exactly once")
end

function T.cancel_completes_with_the_source_cancellation_value()
  local service = openService()
  give(service, "CHIKORITA")
  local host = hostDouble()
  host.script.result = { kind = "cancelled" }
  local state = PartySelectTask.create(request(), context(service, host))
  local parked = context(service, host, { uiEvents = {} })
  local outcome = PartySelectTask.poll(state, parked)
  Assert.isTrue(outcome.complete)
  Assert.equal(parked.instance.locals.__party_selection, 255, "cancel translates to the source result-command value")
  Assert.equal(service:partyCount(), 1, "cancel removes nothing")
end

function T.pending_polls_persist_semantic_focus()
  local service = openService()
  give(service, "CHIKORITA")
  give(service, "TOTODILE")
  local host = hostDouble()
  host.script.focus = 1
  local state = PartySelectTask.create(request(), context(service, host))
  local outcome = PartySelectTask.poll(state, context(service, host, { uiEvents = {} }))
  Assert.isFalse(outcome.complete, "an unanswered selection stays pending")
  Assert.equal(state.focus, 1, "polls persist the numeric cursor for save/restore")
  Assert.equal(#host.opens, 1, "the host opens once and persists across polls")
  outcome = PartySelectTask.poll(state, context(service, host, { uiEvents = {} }))
  Assert.isFalse(outcome.complete)
  Assert.equal(#host.opens, 1, "later polls reuse the open selection instead of reopening")
end

function T.cancel_focus_persists_between_polls()
  local service = openService()
  give(service, "CHIKORITA")
  local host = hostDouble()
  host.script.focus = "cancel"
  local state = PartySelectTask.create(request(), context(service, host))
  local outcome = PartySelectTask.poll(state, context(service, host, { uiEvents = {} }))
  Assert.isFalse(outcome.complete, "resting on cancel completes nothing")
  Assert.equal(state.focus, "cancel", "the cancel affordance persists as focus, never as a party slot")
  Assert.isNil(PartySelectTask.validate(state), "cancel focus serializes cleanly")
  host.script.result = { kind = "cancelled" }
  outcome = PartySelectTask.poll(state, context(service, host, { uiEvents = {} }))
  Assert.isTrue(outcome.complete, "confirming from cancel focus completes")
end

function T.forbidden_cancel_stays_pending()
  local service = openService()
  give(service, "CHIKORITA")
  local host = hostDouble()
  local state = PartySelectTask.create(request({ allowCancel = false }), context(service, host))
  local openRequest = host.opens[1]
  Assert.isNil(openRequest, "nothing opens before the first poll")
  local outcome = PartySelectTask.poll(state, context(service, host, { uiEvents = {} }))
  Assert.isFalse(outcome.complete)
  Assert.equal(host.opens[1].allowCancel, false, "the host open carries the cancel refusal")
end

function T.task_marks_the_current_version()
  Assert.equal(PartySelectTask.version, 2, "script selection persists the current task shape")
end

function T.previous_shape_fails_validation()
  Assert.isTrue(
    PartySelectTask.validate({ policy = "occupied", allowCancel = true, selectedSlot = 1 }) ~= nil,
    "a cursor without semantic focus is not the current shape"
  )
  Assert.isTrue(
    PartySelectTask.validate({ policy = "occupied", allowCancel = true, focus = 6 }) ~= nil,
    "a focus outside 0..5 fails validation"
  )
  Assert.isTrue(
    PartySelectTask.validate({ policy = "trade_only", allowCancel = true, focus = 0 }) ~= nil,
    "unknown policies fail validation"
  )
  Assert.isNil(
    PartySelectTask.validate({ policy = "occupied", allowCancel = true, focus = 0, completed = false }),
    "fresh task state validates"
  )
  Assert.isNil(
    PartySelectTask.validate({ policy = "occupied", allowCancel = true, focus = "cancel", completed = false }),
    "cancel focus validates"
  )
end

function T.unknown_policies_fail_before_opening()
  local service = openService()
  give(service, "CHIKORITA")
  local host = hostDouble()
  Assert.throws(function()
    PartySelectTask.create(request({ eligibility = { policy = "trade_only" } }), context(service, host))
  end, "an unknown eligibility policy fails explicitly")
  Assert.equal(#host.opens, 0, "a rejected request never opens the host")
end

function T.missing_host_faults_loudly()
  local service = openService()
  give(service, "CHIKORITA")
  local ok, err = pcall(function()
    PartySelectTask.create(request(), { services = { mons = service }, input = {}, tick = 1 })
  end)
  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(err))
  Assert.equal((err --[[@as Errors.Error]]).code, ScriptErrors.SCRIPT_SERVICE_MISSING)
end

function T.completed_selection_never_reopens()
  local service = openService()
  give(service, "CHIKORITA")
  local host = hostDouble()
  host.script.result = { kind = "selected", slot = 0 }
  local state = PartySelectTask.create(request(), context(service, host))
  local parked = context(service, host, { uiEvents = {} })
  Assert.isTrue(PartySelectTask.poll(state, parked).complete)
  Assert.equal(host.closes, 1)
  local again = PartySelectTask.poll(state, context(service, host, { uiEvents = {} }))
  Assert.isTrue(again.complete, "a completed selection stays complete")
  Assert.equal(#host.opens, 1, "completion never reopens the host")
  Assert.equal(host.closes, 1, "completion never closes twice")
end

function T.scheduler_events_drive_the_host_step()
  local service = openService()
  give(service, "CHIKORITA")
  local host = hostDouble()
  local state = PartySelectTask.create(request(), context(service, host))
  local batch = { { type = "navigate", direction = "down" } }
  PartySelectTask.poll(state, context(service, host, { uiEvents = batch }))
  Assert.equal(#host.steps, 1, "each poll steps the host exactly once")
  Assert.equal(host.steps[1], batch, "the poll forwards the scheduler batch untouched")
end

function T.cancel_releases_an_open_host_once()
  local service = openService()
  give(service, "CHIKORITA")
  local host = hostDouble()
  local state = PartySelectTask.create(request(), context(service, host))
  PartySelectTask.poll(state, context(service, host, { uiEvents = {} }))
  Assert.equal(#host.opens, 1)
  PartySelectTask.cancel(state, "abandoned", context(service, host))
  Assert.equal(host.closes, 1, "cancellation releases the open selection")
  Assert.equal(state.cancelled, "abandoned")
  PartySelectTask.cancel(state, "abandoned", context(service, host))
  Assert.equal(host.closes, 1, "a second cancel never closes twice")
end

function T.cancel_without_a_driver_marks_only()
  local service = openService()
  give(service, "CHIKORITA")
  local host = hostDouble()
  local state = PartySelectTask.create(request(), context(service, host))
  PartySelectTask.cancel(state, "abandoned")
  Assert.equal(state.cancelled, "abandoned", "driverless cancellation still records its reason")
  Assert.equal(host.closes, 0, "nothing opens, nothing closes")
end

return { tests = T }
