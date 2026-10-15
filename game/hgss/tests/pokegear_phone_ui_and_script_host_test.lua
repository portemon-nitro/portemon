-- Foreground phone lifetime shared by menu and script entry: one feature
-- lease admits the authorized parent, refuses unrelated owners, keeps
-- routing and save capture balanced, and never recreates a lost handle.
-- A call past its committed stage reports an attributed lifecycle fault
-- on a missing handle instead of replaying its conversation, and
-- cancellation is idempotent and terminal. Script coverage runs through
-- the real scheduler lane with injected phone services; only the host
-- audio boundary and the world fixture are fakes, and the real
-- conversation engine stages every effect underneath.

local Assert = require("tests.support.Assert")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

-- Loads a phone module that does not exist yet at this baseline. The
-- failure names the missing behaviour instead of surfacing as a suite
-- load error, so the pre-implementation red stays attributable.
---@param moduleName string
---@param missingMessage string
---@return table
local function requireFeature(moduleName, missingMessage)
  local ok, mod = pcall(require, moduleName)
  if not ok then
    error(missingMessage, 0)
  end
  assert(type(mod) == "table", missingMessage)
  return mod --[[@as table]]
end

local function visualRef(path)
  return { image = path, width = 32, height = 32, anchorX = 0, anchorY = 0 }
end

-- Synthetic companion catalog with one ordinary contact and one
-- invitation contact, validated through the real asset schema so the
-- host tests borrow only genuine semantic references.
---@return table
local function fixtureManifest()
  return {
    schema = "g4-pokegear-assets-v2",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png") },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png") },
    phone = { panel = visualRef("assets/generated/pokegear/phone-panel.png") },
    map = { base = visualRef("assets/generated/pokegear/map-base.png") },
    fly = { base = visualRef("assets/generated/pokegear/fly-base.png") },
    radio = { dial = visualRef("assets/generated/pokegear/radio-dial.png") },
    catalog = {
      contacts = {
        { key = "custom.mom", family = "mother", sortWeight = 10 },
        { key = "custom.trainer-plain", family = "kurt", sortWeight = 20 },
        {
          key = "custom.leader-falkner",
          family = "kurt",
          sortWeight = 30,
          rematchWeekday = 6,
          rematchTime = 0,
        },
      },
      contactOrder = {
        "custom.mom",
        "custom.trainer-plain",
        "custom.leader-falkner",
      },
      callDefinitions = {},
      callTriggers = {},
      rematches = {},
      gifts = {},
      momPurchases = {},
      locations = {
        { key = "custom.new-bark" },
      },
      flypoints = {},
      regionMap = require("tests.support.PokegearRegionMapFixture").build(),
      reception = {},
      shows = {},
      radioEffects = {},
    },
    text = {},
    sequences = {},
  }
end

-- A deterministic audio boundary that counts its tones: every effect
-- wait completes on the next poll, so the conversation advances through
-- completion state rather than wall-clock waits, and every dial and
-- hangup tone is counted to prove exactly-once release.
---@return table
local function countingAudio()
  local completed = true
  return {
    dials = 0,
    hangups = 0,
    playDialing = function(self)
      self.dials = self.dials + 1
      completed = false
    end,
    playHangup = function(self)
      self.hangups = self.hangups + 1
    end,
    isEffectWaitComplete = function(_)
      local done = completed
      completed = true
      return done
    end,
  }
end

---@param record table
---@return table services
local function worldFixture()
  local rematches = {}
  local rematchReady = {}
  local flags = {}
  return {
    flags = flags,
    read = function(_, key)
      return flags[key]
    end,
    setMomSavingsChoice = function(_, choice)
      flags["mom.savings-choice"] = choice
      flags.savingsChoice = choice
    end,
    rematchReady = rematchReady,
    rematches = rematches,
    queryRematch = function(_, contact)
      return rematches[contact]
    end,
    setRematch = function(_, contact, record)
      rematches[contact] = record
      rematchReady[contact] = record.stage > 0
    end,
    nativeSelectorFacts = function()
      return {
        localMap = true,
        gaveRivalName = false,
        talkedAfterNamingRival = false,
        eggCallPending = false,
      }
    end,
    storyTier = 2,
    weekday = 6,
    timeOfDay = 0,
    teamsByTier = { [2] = { tier = 2, members = { { species = "custom.pidgeotto", level = 13 } } } },
    player = { x = 5, y = 7 },
  }
end

---@param record table
---@param world table
---@param audio table
---@return table host
local function openHost(record, world, audio)
  local PokegearScriptHost = requireFeature(
    "game.hgss.src.pokegear.PokegearScriptHost",
    "the phone feature has no script host yet: menu and script entry cannot share one application lease"
  )
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
  local state = PokegearState.new({ seed = 4242 }, { catalog = record.catalog })
  state:registerContact("custom.mom")
  state:registerContact("custom.trainer-plain")
  state:registerContact("custom.leader-falkner")
  return PokegearScriptHost.new({
    state = state,
    catalog = record.catalog,
    messages = {
      greeting = "custom.greeting",
      program = "custom.program",
      resolveLine = function()
        return { tokens = { { kind = "glyph", code = 1, text = "X", raw = { 1 } } } }
      end,
    },
    world = world,
    audio = audio,
    random = PokegearRandom.new(4242),
    assets = record,
    regionMapOwners = function()
      local MapFixture = require("tests.support.PokegearMapFixture")
      return MapFixture.messages(), MapFixture.facts()
    end,
  }),
    state
end

---@param host table
---@param action string
---@return table handle
local function openCall(host, action)
  return host:open({
    mode = "call",
    request = { id = action, contact = "custom.trainer-plain", direction = "outgoing", kind = "ordinary" },
    parentOwner = "script:test-parent",
  })
end

-- Steps the host until the call reports its terminal result. The bound
-- only guards against a stuck host; a healthy call settles in a few
-- fixed steps with no wall-clock waits.
---@param host table
---@param handle table
---@return table terminal result
local function settleCall(host, handle)
  for _ = 1, 40 do
    local result = host:result(handle)
    if result ~= nil then
      return result --[[@as table]]
    end
    host:step(handle, { { type = "advance" } })
  end
  error("the foreground call never reached its terminal result", 0)
end

-- The script surface the scheduler lane needs. Each missing builder
-- fails naming its absent operation, never as a nil call, so the red
-- stays attributable to the phone script surface.
---@return table
local function phoneScriptSurface()
  local S = require("gen4.script")
  assert(
    type(S.phoneSetCall) == "function",
    "the script surface has no phone call setup operation yet: a script cannot stage its pending call request"
  )
  assert(
    type(S.phoneRunCall) == "function",
    "the script surface has no phone call run operation yet: a script cannot consume its pending call request and block"
  )
  return S
end

---@param host table
---@return table harness
local function schedulerHarness(host)
  local Registry = require("libs.script.src.Registry")
  local Composition = require("libs.script.src.Composition")
  local TaskRegistry = require("libs.script.src.TaskRegistry")
  local Scheduler = require("libs.script.src.Scheduler")
  local HgssComposition = require("libs.hgss.src.script.Composition")
  local services = { pokegearApplications = host }
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = HgssComposition.registerTasks(TaskRegistry.new())
  local scheduler = Scheduler.new({
    semantics = require("libs.hgss.src.script.RuntimeValues"),
    services = services,
    taskRegistry = taskRegistry,
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  return { registry = registry, composition = composition, scheduler = scheduler }
end

-- One modal owner with two entry paths: the authorized parent script
-- stages its pending request without taking the lease, blocks only when
-- it runs the call, refuses unrelated owners while active, never leaks
-- player movement, and keeps save capture denied until the return
-- transition settles. Cancellation releases exactly once.
function T.tests.script_application_lease_balances_input_routing_and_save_capture()
  requireFeature(
    "libs.hgss.src.script.tasks.PokegearApplicationTask",
    "the phone feature has no scheduler task yet: a script cannot wait on its foreground call"
  )
  local S = phoneScriptSurface()
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local world = worldFixture()
  world.flags["mom.savings-choice"] = false
  local audio = countingAudio()
  local host, _ = openHost(record, world, audio)

  Assert.isFalse(host:isActive(), "no call owns the lease before the script runs")
  Assert.isTrue(host:isStableForSave(), "an idle host captures saves")

  local h = schedulerHarness(host)
  local resource = S.script({
    api = 1,
    id = "test.phone_lease",
    steps = {
      S.phoneSetCall({ contact = "custom.mom", direction = "outgoing", kind = "ordinary" }),
      S.phoneRunCall(),
      S.stop(),
    },
  })
  h.registry:installBase("test.phone_lease", resource, "generated")
  local instanceId = h.scheduler:createForeground(assert(h.composition:effective("test.phone_lease")), nil, 100)

  -- Staging the pending request evaluates its operands without taking
  -- the lease or blocking the parent.
  h.scheduler:step(100, {})
  Assert.isFalse(host:isActive(), "staging the pending request takes no lease")
  Assert.notNil(h.scheduler:instance(instanceId), "the parent script stays live past its setup operation")

  -- Running the staged request takes the lease and blocks the parent.
  h.scheduler:step(101, {})
  Assert.isTrue(host:isActive(), "running the staged request takes the lease")
  Assert.isFalse(host:isStableForSave(), "an active call denies save capture")
  Assert.notNil(h.scheduler:instance(instanceId), "the parent script stays blocked while its call is live")

  -- An unrelated owner is refused while the lease is held, and the
  -- refusal leaves the authorized call untouched.
  local busy = Assert.throws(function()
    host:open({
      mode = "call",
      request = { id = "rival-1", contact = "custom.trainer-plain", direction = "outgoing", kind = "ordinary" },
      parentOwner = "script:unrelated-rival",
    })
  end, "an unrelated owner never steals the active lease")
  Assert.notNil(
    tostring(busy):find("active", 1, true)
      or tostring(busy):find("busy", 1, true)
      or tostring(busy):find("lease", 1, true),
    "the refusal names the held lease"
  )
  Assert.throws(function()
    host:open({
      mode = "townMap",
      request = { id = "map-1" },
      parentOwner = "Arrival",
    })
  end, "unrelated modal work never preempts the active call")
  Assert.isTrue(host:isActive(), "the refused admissions leave the authorized call active")

  -- Call input never moves the field player: movement-flavoured events
  -- stepped through the host leave the borrowed player position alone.
  local handle = host:activeHandle()
  Assert.notNil(handle, "the active call exposes its handle")
  host:step(handle, { { type = "move", direction = "north" }, { type = "advance" } })
  Assert.deepEqual(world.player, { x = 5, y = 7 }, "call input never leaks into field movement")

  -- The settled call reports one terminal result; the return transition
  -- keeps save capture denied until the owner closes the handle.
  for _ = 1, 40 do
    if host:result(handle) ~= nil then
      break
    end
    host:step(handle, { { type = "confirm" } })
  end
  local terminal = host:result(handle)
  Assert.notNil(terminal, "the confirmed savings choice reaches a terminal result")
  terminal = terminal --[[@as table]]
  Assert.equal(terminal.contact, "custom.mom", "the terminal result names its contact")
  Assert.equal(terminal.kind, "ordinary", "the terminal result names its call kind")
  local again = host:result(handle)
  Assert.deepEqual(again, terminal, "the terminal result reads back identically until closed")
  Assert.isFalse(host:isStableForSave(), "save capture stays denied until the return transition settles")
  host:close(handle)
  Assert.isFalse(host:isActive(), "closing the handle releases the lease")
  Assert.isTrue(host:isStableForSave(), "a closed call captures saves again")
  Assert.equal(audio.hangups, 1, "the completed call released its tones exactly once")

  -- A fresh owner is admitted once the lease is free.
  local second = host:open({
    mode = "call",
    request = { id = "second-1", contact = "custom.mom", direction = "outgoing", kind = "ordinary" },
    parentOwner = "script:second-parent",
  })
  host:cancel("test hangup")
  Assert.notNil(host:result(second), "cancelling a live call still reports its terminal result")
  Assert.isFalse(host:isActive(), "cancellation releases the lease")
  Assert.isTrue(host:isStableForSave(), "a cancelled call captures saves again")
  Assert.equal(audio.hangups, 2, "cancellation unwinds acquired tones exactly once")
  host:close(second)

  -- Task cancellation is idempotent: two cancels release once, mark the
  -- task terminal, and never reopen the line.
  local PokegearApplicationTask = require("libs.hgss.src.script.tasks.PokegearApplicationTask")
  local third = host:open({
    mode = "call",
    request = { id = "third-1", contact = "custom.mom", direction = "outgoing", kind = "ordinary" },
    parentOwner = "script:third-parent",
  })
  local cancels = 0
  local realCancel = host.cancel
  host.cancel = function(self, reason)
    cancels = cancels + 1
    return realCancel(self, reason)
  end
  local taskCtx = { services = { pokegearApplications = host }, input = { uiEvents = {} } }
  local taskState = PokegearApplicationTask.create({
    kind = "call",
    request = { id = "third-1", contact = "custom.mom", direction = "outgoing", kind = "ordinary" },
    parentOwner = "script:third-parent",
  }, taskCtx)
  PokegearApplicationTask.cancel(taskState, "test cancellation", taskCtx)
  PokegearApplicationTask.cancel(taskState, "test cancellation", taskCtx)
  Assert.equal(cancels, 1, "two task cancels release the host call exactly once")
  Assert.isFalse(host:isActive(), "the cancelled task leaves no active handle behind")
  local finished = PokegearApplicationTask.poll(taskState, taskCtx)
  Assert.isTrue(finished.complete, "the cancelled task polls terminal without reopening the line")
  Assert.isFalse(host:isActive(), "polling a cancelled task never recreates its call")
  Assert.isNil(PokegearApplicationTask.validate(taskState), "the terminal task state keeps its closed shape")
  Assert.notNil(
    PokegearApplicationTask.validate({ kind = "call", request = { id = "third-1" }, handle = {} }),
    "an open task shape carrying a live handle never validates"
  )
  host.cancel = realCancel
  host:close(third)
end

-- A call past its committed stage with a deliberately missing host
-- handle is an attributed lifecycle fault: the conversation is never
-- recreated, earlier effects are neither repeated nor undone, and
-- repeated cancellation stays terminal without replay.
function T.tests.missing_call_handle_after_commit_fails_without_replaying_effects()
  local PokegearApplicationTask = requireFeature(
    "libs.hgss.src.script.tasks.PokegearApplicationTask",
    "the phone feature has no scheduler task yet: a lost call handle cannot fail without replaying its effects"
  )
  requireFeature(
    "game.hgss.src.pokegear.PokegearScriptHost",
    "the phone feature has no script host yet: a lost call handle cannot fail without replaying its effects"
  )
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local world = worldFixture()
  local audio = countingAudio()
  local host, _ = openHost(record, world, audio)
  local taskCtx = { services = { pokegearApplications = host }, input = { uiEvents = {} } }

  -- Open through the scheduler task, then drive the source-backed
  -- savings choice through its durable effect before losing the handle.
  world.flags.savingsChoice = false
  world.flags["mom.savings-choice"] = false
  local taskState = PokegearApplicationTask.create({
    kind = "call",
    request = { id = "offer-1", contact = "custom.mom", direction = "outgoing", kind = "ordinary" },
    parentOwner = "script:invite-parent",
  }, taskCtx)
  for _ = 1, 10 do
    local polled = PokegearApplicationTask.poll(taskState, taskCtx)
    if polled.complete then
      break
    end
  end
  local handle = host:activeHandle()
  if handle ~= nil then
    for _ = 1, 20 do
      if host:result(handle) ~= nil then
        break
      end
      host:step(handle, { { type = "confirm" } })
    end
  end
  Assert.isTrue(
    world.flags.savingsChoice == true,
    "the source choice commits its durable effect before result publication"
  )
  local dialsAfterCommit = audio.dials
  Assert.isTrue(dialsAfterCommit >= 1, "the committed call dialled exactly through its audio boundary")

  -- Lose the handle out of band, as a disposed view would: the next
  -- poll is a lifecycle fault naming the missing handle, never a
  -- silent reopen that replays the conversation.
  local live = host:activeHandle()
  if live ~= nil then
    host:close(live)
  end
  Assert.isFalse(host:isActive(), "the lost handle leaves no active call behind")
  local ok, fault = pcall(PokegearApplicationTask.poll, taskState, taskCtx)
  Assert.isFalse(ok, "polling with a missing handle never succeeds")
  local faultText = tostring((type(fault) == "table" and (fault.message or fault.code)) or fault):lower()
  Assert.isTrue(
    faultText:find("handle", 1, true) ~= nil
      or faultText:find("missing", 1, true) ~= nil
      or faultText:find("stale", 1, true) ~= nil
      or faultText:find("lifecycle", 1, true) ~= nil,
    "the lifecycle fault names its missing handle"
  )
  Assert.isFalse(host:isActive(), "the fault never recreates the lost conversation")
  Assert.equal(audio.dials, dialsAfterCommit, "the fault replays no dial tone")
  Assert.isTrue(world.flags.savingsChoice == true, "the fault neither repeats nor undoes the committed choice")

  -- Repeated cancellation after the fault stays terminal: no error, no
  -- replay, no rollback.
  PokegearApplicationTask.cancel(taskState, "test cancellation", taskCtx)
  PokegearApplicationTask.cancel(taskState, "test cancellation", taskCtx)
  Assert.isFalse(host:isActive(), "cancelling a faulted task recreates nothing")
  Assert.equal(audio.dials, dialsAfterCommit, "cancellation replays no conversation audio")
  Assert.isTrue(world.flags.savingsChoice == true, "cancellation preserves the committed choice")

  -- The released line still opens fresh: the fault consumed nothing it
  -- did not own.
  local fresh = host:open({
    mode = "call",
    request = { id = "fresh-1", contact = "custom.mom", direction = "outgoing", kind = "ordinary" },
    parentOwner = "script:fresh-parent",
  })
  host:cancel("fresh call cleanup")
  host:close(fresh)
  Assert.isTrue(host:isStableForSave(), "the faulted host still settles fresh calls cleanly")
end

function T.tests.menu_calls_return_to_list_while_host_calls_retain_their_result()
  local PhoneController = requireFeature(
    "game.hgss.src.pokegear.PhoneController",
    "the phone card has no controller yet: menu calls cannot return to their contact list"
  )
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
  local state = PokegearState.new({ seed = 77 }, { catalog = record.catalog })
  state:registerContact("custom.trainer-plain")
  state:registerContact("custom.leader-falkner")
  local audio = countingAudio()
  local controller = PhoneController.new({
    state = state,
    catalog = record.catalog,
    messages = { greeting = "custom.greeting" },
    world = worldFixture(),
    audio = audio,
    random = PokegearRandom.new(77),
  })

  local function dialSelected()
    controller:updateFixed({ { type = "confirm" } })
    controller:updateFixed({ { type = "confirm" } })
    return controller:status().view.call
  end

  local first = dialSelected()
  Assert.notNil(first, "the first contact starts a menu call")
  local firstId = first.id
  controller:updateFixed({ { type = "cancel" }, { type = "cancel" } })
  local returned = controller:status()
  Assert.isFalse(returned.busy, "a completed menu call releases the child call owner")
  Assert.isFalse(returned.nestedCancel, "the returned list no longer owns nested cancel")
  Assert.isTrue(returned.dismissible, "the returned list permits gear dismissal")
  Assert.isNil(returned.view.call, "the returned list has no stale call view")
  Assert.isNil(controller:takeResult(), "a menu call result does not escape to a script host")

  controller:updateFixed({ { type = "navigate", direction = "down" } })
  local second = dialSelected()
  Assert.notNil(second, "the next registered contact starts another call")
  Assert.equal("custom.leader-falkner", second.contact, "the contact list remains usable after a call")
  Assert.isTrue(firstId ~= second.id, "each menu dial receives a distinct call id")
  controller:dispose()

  local host, _ = openHost(record, worldFixture(), countingAudio())
  local handle = openCall(host, "host-terminal")
  local terminal = settleCall(host, handle)
  Assert.deepEqual(host:result(handle), terminal, "the host retains its terminal result")
  Assert.deepEqual(host:result(handle), terminal, "the host result remains stable until close")
  host:close(handle)
  Assert.isFalse(host:isActive(), "the host closes and releases its own child once")
  Assert.throws(function()
    host:result(handle)
  end, "a closed host call rejects its stale handle")
end

-- Cancellation at each foreground stage stays terminal and exactly-once:
-- list cancellation is a no-op, menu and move cancellations return to
-- the list without persisting, and call cancellation hangs up once with
-- one terminal result. Disposal with a pending acquisition releases the
-- lease exactly once and refuses later opens.
function T.tests.call_cancellation_is_terminal_at_each_stage_and_disposal_releases_once()
  local PhoneController = requireFeature(
    "game.hgss.src.pokegear.PhoneController",
    "the phone card has no controller yet: cancellation cannot unwind each foreground stage"
  )
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
  local state = PokegearState.new({ seed = 99 }, { catalog = record.catalog })
  state:registerContact("custom.trainer-plain")
  state:registerContact("custom.leader-falkner")
  local world = worldFixture()
  local audio = countingAudio()
  local controller = PhoneController.new({
    state = state,
    catalog = record.catalog,
    messages = { greeting = "custom.greeting" },
    world = world,
    audio = audio,
    random = PokegearRandom.new(99),
  })

  -- List cancellation selects nothing and opens nothing.
  controller:updateFixed({ { type = "cancel" } })
  Assert.equal(controller:status().view.list.selected, 0, "list cancellation keeps the opening selection")
  Assert.isNil(controller:status().view.contextMenu, "list cancellation opens no menu")

  -- Menu cancellation returns to the list.
  controller:updateFixed({ { type = "confirm" } })
  Assert.notNil(controller:status().view.contextMenu, "confirming a row opens its action menu")
  controller:updateFixed({ { type = "cancel" } })
  Assert.isNil(controller:status().view.contextMenu, "menu cancellation returns to the list")

  -- Sort submenu cancellation returns to the action menu.
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(
    assert(controller:status().view, "the sort state exports its view").contextMenu.options,
    { "Title", "Alphabet", "Location", "Move", "Quit" },
    "choosing Sort opens its submenu"
  )
  controller:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(
    assert(controller:status().view, "the menu state exports its view").contextMenu.options,
    { "Call", "Sort", "Quit" },
    "sort cancellation returns to the action menu"
  )
  controller:updateFixed({ { type = "cancel" } })

  -- Manual cancellation leaves move mode without persisting the order.
  local savedBefore = state:readPhone().contactOrder
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  for _ = 1, 3 do
    controller:updateFixed({ { type = "navigate", direction = "down" } })
  end
  controller:updateFixed({ { type = "confirm" } })
  Assert.isTrue(controller:status().view.list.manual, "choosing Move enters manual move mode")
  controller:updateFixed({ { type = "cancel" } })
  Assert.isFalse(controller:status().view.list.manual, "manual cancellation leaves move mode")
  Assert.deepEqual(state:readPhone().contactOrder, savedBefore, "manual cancellation persists no order")

  -- Call cancellation hangs up exactly once with one terminal result.
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.notNil(controller:status().view.call, "choosing Call starts its conversation")
  controller:updateFixed({ { type = "cancel" } })
  local terminal = controller:takeResult()
  Assert.isNil(terminal, "a menu cancellation does not publish a script-host result")
  Assert.isFalse(controller:status().busy, "a menu cancellation returns to list mode")
  controller:updateFixed({ { type = "cancel" } })
  Assert.isNil(controller:takeResult(), "repeated cancellation does not publish a result")
  Assert.equal(audio.hangups, 1, "call cancellation unwinds its tones exactly once")
  controller:dispose()
  controller:dispose()
  Assert.isNil(controller:takeResult(), "disposal reports no further result")

  -- Host disposal with a pending acquisition releases the lease once.
  local host, _ = openHost(record, worldFixture(), countingAudio())
  host:open({
    mode = "call",
    request = { id = "dispose-1", contact = "custom.trainer-plain", direction = "outgoing", kind = "ordinary" },
    parentOwner = "script:dispose-parent",
  })
  Assert.isTrue(host:isActive(), "the pending acquisition owns the lease")
  host:dispose()
  Assert.isFalse(host:isActive(), "host disposal releases the pending acquisition")
  host:dispose()
  Assert.isNil(host:activeHandle(), "the released lease exposes no handle")
  Assert.throws(function()
    host:open({
      mode = "call",
      request = { id = "dispose-2", contact = "custom.trainer-plain", direction = "outgoing", kind = "ordinary" },
      parentOwner = "script:dispose-parent",
    })
  end, "a disposed host opens nothing")
end

function T.tests.phone_uses_saved_contact_order_and_keeps_automatic_sort_temporary()
  local PhoneController = requireFeature(
    "game.hgss.src.pokegear.PhoneController",
    "the phone card has no controller yet: saved contact order cannot be displayed"
  )
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
  local state = PokegearState.new({ seed = 99 }, { catalog = record.catalog })
  state:registerContact("custom.trainer-plain")
  state:registerContact("custom.mom")
  local function phone()
    return PhoneController.new({
      state = state,
      catalog = record.catalog,
      messages = { greeting = "custom.greeting" },
      world = worldFixture(),
      random = PokegearRandom.new(99),
    })
  end

  local controller = phone()
  local rows = controller:status().view.list.rows
  Assert.deepEqual(
    { rows[1].contact, rows[2].contact },
    { "custom.trainer-plain", "custom.mom" },
    "the phone opens in the durable registration order"
  )
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "confirm" } })
  rows = controller:status().view.list.rows
  Assert.deepEqual(
    { rows[1].contact, rows[2].contact },
    { "custom.mom", "custom.trainer-plain" },
    "automatic source sorting changes only the visible order"
  )
  Assert.deepEqual(
    state:readPhone().contactOrder,
    { "custom.trainer-plain", "custom.mom" },
    "automatic sorting leaves canonical order untouched"
  )
  controller:dispose()

  state:registerContact("custom.leader-falkner")
  local reopened = phone()
  rows = reopened:status().view.list.rows
  Assert.deepEqual(
    { rows[1].contact, rows[2].contact, rows[3].contact },
    { "custom.trainer-plain", "custom.mom", "custom.leader-falkner" },
    "new registrations append after the saved order"
  )
  reopened:dispose()
end

-- The declarative script surface stays closed and delegates meaning:
-- builders return ordinary records, the schema rejects extra keys and
-- bad enums, and runtime routes queries and updates through the
-- injected companion service while staging evaluates its operands.
function T.tests.phone_script_operations_validate_route_and_fail_with_context()
  local S = phoneScriptSurface()
  local Runtime = require("libs.script.src.Runtime")
  local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
  Assert.deepEqual(
    S.phoneSetCall({ contact = "custom.trainer-plain", direction = "outgoing", kind = "ordinary" }),
    { op = "phone_set_call", contact = "custom.trainer-plain", direction = "outgoing", kind = "ordinary" },
    "setup builds its ordinary op record"
  )
  Assert.deepEqual(S.phoneRunCall(), { op = "phone_run_call" }, "run builds its operand-free record")
  Assert.deepEqual(S.pokegearQuery({ kind = "contact_registered", contact = "custom.mom", result = S.var("seen") }), {
    op = "pokegear_query",
    kind = "contact_registered",
    contact = "custom.mom",
    result = { value = "var", id = "seen" },
  }, "query builds its typed record")
  Assert.isNil(S.pokegearInvoke, "phone operations expose no open-ended dispatch")
  Assert.isTrue(
    S.validate(S.script({
      api = 1,
      id = "test.phone_shapes",
      steps = {
        S.phoneSetCall({ contact = S.var("caller"), direction = "outgoing", kind = "rematch" }),
        S.phoneRunCall(),
        S.pokegearQuery({ kind = "rematch_ready", contact = "custom.leader-falkner", result = S.var("ready") }),
        S.pokegearUpdate({ kind = "register_contact", contact = "custom.mom" }),
        S.stop(),
      },
    })),
    "staged operands and sync operations validate"
  )
  Assert.isNil(
    S.validate(S.script({
      api = 1,
      id = "test.phone_extra",
      steps = { S.phoneSetCall({ contact = "c", direction = "outgoing", kind = "ordinary", extra = 1 }), S.stop() },
    })),
    "extra setup keys never validate"
  )
  Assert.isNil(
    S.validate(S.script({
      api = 1,
      id = "test.phone_bad_kind",
      steps = { S.pokegearQuery({ kind = "live_score", result = S.var("ready") }), S.stop() },
    })),
    "open query kinds never validate"
  )

  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local host, _ = openHost(record, worldFixture(), countingAudio())
  local variables = {}
  local worldService = {
    getVar = function(_, id)
      return variables[id] or 0
    end,
    setVar = function(_, id, value)
      variables[id] = value
    end,
    queryRematch = function(_, contact)
      return world.rematches[contact]
    end,
    setRematch = function(_, contact, record)
      world.rematches[contact] = record
    end,
  }
  local tasks = {}
  local run = {
    instance = { scriptId = "test.phone_ops", mode = "foreground", instanceId = "ops-1" },
    services = { pokegearApplications = host, world = worldService },
    semantics = RuntimeValues,
    scheduler = {
      createTask = function(_, taskType, spec)
        tasks[#tasks + 1] = { type = taskType, spec = spec }
        return "task-ops"
      end,
    },
    tick = 7,
    input = {},
  }
  Assert.equal(
    Runtime.executeNode({
      op = "pokegear_query",
      kind = "contact_registered",
      contact = "custom.trainer-plain",
      result = {
        value = "var",
        id = "plain_seen",
      },
    }, run),
    Runtime.OUTCOME_CONTINUE,
    "registration queries resolve synchronously"
  )
  Assert.equal(variables.plain_seen, 1, "an acquired contact reads back registered")
  Assert.equal(
    Runtime.executeNode({
      op = "pokegear_query",
      kind = "rematch_ready",
      contact = "custom.leader-falkner",
      result = {
        value = "var",
        id = "ready",
      },
    }, run),
    Runtime.OUTCOME_CONTINUE,
    "readiness queries resolve synchronously"
  )
  Assert.equal(variables.ready, 0, "an unstaged invitation reads back unready")
  Assert.equal(
    Runtime.executeNode({ op = "pokegear_update", kind = "register_contact", contact = "custom.mom" }, run),
    Runtime.OUTCOME_CONTINUE,
    "registration updates commit synchronously"
  )
  Assert.equal(
    Runtime.executeNode({
      op = "pokegear_query",
      kind = "contact_registered",
      contact = "custom.mom",
      result = {
        value = "var",
        id = "mom_seen",
      },
    }, run),
    Runtime.OUTCOME_CONTINUE,
    "the registered contact reads back registered"
  )
  Assert.equal(variables.mom_seen, 1, "the update committed through the durable owner")
  local updateOk, updateErr =
    pcall(Runtime.executeNode, { op = "pokegear_update", kind = "register_contact", contact = "custom.stranger" }, run)
  Assert.isFalse(updateOk, "unknown contacts never register")
  Assert.notNil(tostring(updateErr):find("custom.stranger", 1, true), "the failure names its contact")
  local directionOk, directionErr = pcall(
    Runtime.executeNode,
    { op = "phone_set_call", contact = "custom.trainer-plain", direction = "sideways", kind = "ordinary" },
    run
  )
  Assert.isFalse(directionOk, "open directions never stage")
  Assert.equal(directionErr.code, "SCRIPT_INVALID_REFERENCE", "the failure carries its closed vocabulary")
  variables.caller = "custom.leader-falkner"
  Assert.equal(
    Runtime.executeNode({
      op = "phone_set_call",
      contact = { value = "var", id = "caller" },
      direction = "outgoing",
      kind = "rematch",
    }, run),
    Runtime.OUTCOME_CONTINUE,
    "setup evaluates its operands at staging time"
  )
  Assert.deepEqual(
    host:takeStagedCall("ops-1"),
    { contact = "custom.leader-falkner", direction = "outgoing", kind = "rematch" },
    "the staged request carries its evaluated contact"
  )
  local lonelyOk, lonelyErr = pcall(Runtime.executeNode, { op = "phone_run_call" }, run)
  Assert.isFalse(lonelyOk, "running without a staged request never blocks")
  local lonelyText = tostring(lonelyErr.message or lonelyErr.code):lower()
  Assert.isTrue(
    lonelyText:find("phone", 1, true) ~= nil and lonelyText:find("pending", 1, true) ~= nil,
    "the missing-request failure carries its script context"
  )
  Assert.equal(
    Runtime.executeNode({ op = "pokegear_open", mode = "townMap" }, run),
    Runtime.OUTCOME_BLOCK,
    "explicit opens without a child still route through the shared task"
  )
  Assert.equal(tasks[#tasks].type, "pokegear_application", "the open blocks on the companion task")
  Assert.equal(tasks[#tasks].spec.kind, "townMap", "the open carries its explicit mode")
  local PokegearApplicationTask = require("libs.hgss.src.script.tasks.PokegearApplicationTask")
  -- The Town map entry has a real child: construction succeeds, the
  -- first poll opens the view-only map through the shared host, a
  -- view-only confirmation settles nothing, and cancellation closes it
  -- back to its script with no travel.
  local mapState = PokegearApplicationTask.create({
    kind = "townMap",
    parentOwner = "script:test-map",
  }, { services = { pokegearApplications = host } })
  Assert.isNil(PokegearApplicationTask.validate(mapState), "town map task state stays serializable")
  local mapServices = { services = { pokegearApplications = host }, input = { uiEvents = {} } }
  local mapOpened = PokegearApplicationTask.poll(mapState, mapServices)
  Assert.isFalse(mapOpened.complete, "opening the view-only map waits for its close")
  Assert.isTrue(host:isActive(), "the task opens the town map through the shared host")
  local mapConfirmed = PokegearApplicationTask.poll(mapState, {
    services = { pokegearApplications = host },
    input = { uiEvents = { { type = "confirm" } } },
  })
  Assert.isFalse(mapConfirmed.complete, "a view-only confirmation settles nothing")
  PokegearApplicationTask.cancel(mapState, "test map close", mapServices)
  Assert.isFalse(host:isActive(), "cancelling the town map releases the lease")
  Assert.isTrue(host:isStableForSave(), "a closed map captures saves again")
  -- Fly task construction still needs its field-move selection, which no
  -- script opcode supplies yet; the host-level Fly child stays reachable
  -- through the field-move owner instead.
  local flyOk, flyErr = pcall(PokegearApplicationTask.create, {
    kind = "fly",
    parentOwner = "script:test-fly",
  }, { services = { pokegearApplications = host } })
  Assert.isFalse(flyOk, "fly task construction waits for its field-move selection")
  Assert.equal(flyErr.code, "FEATURE_UNAVAILABLE", "the failure names its missing selection")
end

return T
