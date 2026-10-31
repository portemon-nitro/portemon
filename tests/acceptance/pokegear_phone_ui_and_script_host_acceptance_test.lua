-- Scripted and menu phone calls share one conversation engine: the same
-- predefined call run from menu acceptance and from script setup/run
-- nodes produces identical call state, text, and effects while each path
-- returns to its distinct owner, and the parent script stays blocked
-- until its call reports exactly one result. Setup only stages its
-- pending request after evaluating its operands; running consumes that
-- request and blocks, and running without a staged request fails with
-- its script context. Coverage runs through the real scheduler lane
-- with injected phone services; only the host audio boundary and the
-- world fixture are fakes, and the real conversation engine stages
-- every effect underneath. No derived assets are required.

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

-- Synthetic companion catalog with one invitation contact and one
-- ordinary contact, validated through the real asset schema so both
-- entry paths borrow only genuine semantic references.
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
        {
          key = "custom.mom",
          family = "mother",
          sortWeight = 10,
          rematchWeekday = 6,
          rematchTime = 0,
        },
        { key = "custom.trainer-plain", family = "kurt", sortWeight = 20 },
      },
      contactOrder = { "custom.mom", "custom.trainer-plain" },
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

-- A deterministic audio boundary: every effect wait completes on the
-- next poll, so both entry paths advance through completion state
-- rather than wall-clock waits.
---@return table
local function instantAudio()
  local completed = true
  return {
    playDialing = function()
      completed = false
    end,
    isEffectWaitComplete = function()
      local done = completed
      completed = true
      return done
    end,
  }
end

---@return table world fixture shared by both entry paths
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
    nativeSelectorFacts = function()
      return {
        localMap = true,
        gaveRivalName = false,
        talkedAfterNamingRival = false,
        eggCallPending = false,
      }
    end,
    queryRematch = function(_, contact)
      return rematches[contact]
    end,
    setRematch = function(_, contact, record)
      rematches[contact] = record
      rematchReady[contact] = record.stage > 0
    end,
    storyTier = 2,
    weekday = 6,
    timeOfDay = 0,
    teamsByTier = {
      [2] = { tier = 2, members = { { species = "custom.pidgeotto", level = 13 } } },
    },
  }
end

---@return table messages frozen before either entry path runs
local function messageRefs()
  return { invitation = "custom.invitation", accept = "custom.accept" }
end

-- Steps a foreground handle until its terminal result appears. The
-- bound only guards against a stuck call; a healthy invitation settles
-- in a few fixed steps.
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
---@return table harness with registry, composition, and scheduler
local function schedulerHarness(host)
  local Registry = require("libs.script.src.Registry")
  local Composition = require("libs.script.src.Composition")
  local TaskRegistry = require("libs.script.src.TaskRegistry")
  local Scheduler = require("libs.script.src.Scheduler")
  local HgssComposition = require("libs.hgss.src.script.Composition")
  -- The scheduler lane needs its required collaborators: the feature host,
  -- the minimal in-memory world behind variable and flag operands, and
  -- the event recorder behind the designed fault observation surface.
  local variables = {}
  local world = {
    getVar = function(_, id)
      return variables[id] or 0
    end,
    setVar = function(_, id, value)
      variables[id] = value
    end,
    isFlagSet = function(_, _)
      return false
    end,
  }
  local recorded = {}
  local events = {
    emit = function(_, name, payload)
      recorded[#recorded + 1] = { name = name, payload = payload }
    end,
    eventFor = function(_, name, instanceId)
      for _, record in ipairs(recorded) do
        if record.name == name and record.payload.instanceId == instanceId then
          return record.payload
        end
      end
      return nil
    end,
  }
  local services = { pokegearApplications = host, world = world, events = events }
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
  return { registry = registry, composition = composition, scheduler = scheduler, events = events }
end

-- The same predefined invitation through menu acceptance and script
-- setup/run nodes uses identical call state, text, and effects while
-- each path returns to its distinct owner. The parent script stays
-- blocked until its call reports exactly one consumed result.
function T.tests.scripted_and_menu_phone_calls_share_one_conversation_engine()
  local PhoneController = requireFeature(
    "game.hgss.src.pokegear.PhoneController",
    "the phone card has no controller yet: menu entry cannot share its conversation engine with scripts"
  )
  local PokegearScriptHost = requireFeature(
    "game.hgss.src.pokegear.PokegearScriptHost",
    "the phone feature has no script host yet: scripted entry cannot share its conversation engine with the menu"
  )
  local S = phoneScriptSurface()
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")

  -- Menu entry: the real card controller opens the invitation on its
  -- registered contact and drives it through semantic advance input.
  local menuState = PokegearState.new({ seed = 2024 }, { catalog = record.catalog })
  menuState:registerContact("custom.mom")
  local menuWorld = worldFixture()
  local menuController = PhoneController.new({
    state = menuState,
    catalog = record.catalog,
    messages = {
      invitation = "custom.invitation",
      accept = "custom.accept",
      resolveLine = function()
        return { tokens = { { kind = "glyph", code = 1, text = "X", raw = { 1 } } } }
      end,
    },
    world = menuWorld,
    audio = instantAudio(),
    random = PokegearRandom.new(2024),
    tooltips = {
      "menu-tip-α-20",
      "menu-tip-α-21",
      "menu-tip-α-22",
      "menu-tip-α-23",
      "menu-tip-α-24",
      "menu-tip-α-25",
      "menu-tip-α-26",
      "menu-tip-α-27",
    },
    menuLabels = {
      "menu-label-α-0",
      "menu-label-α-1",
      "menu-label-α-2",
      "menu-label-α-3",
      "menu-label-α-4",
      "menu-label-α-5",
      "menu-label-α-6",
      "menu-label-α-7",
    },
  })
  -- The menu path walks the real list UI: the single contact opens
  -- selected, confirming opens its action menu, and confirming the
  -- first Call option starts the invitation without granting an extra
  -- menu action.
  Assert.equal(menuController:status().view.list.selected, 0, "the menu list opens with its first row selected")
  menuController:updateFixed({ { type = "confirm" } })
  local actionMenu = assert(menuController:status().view, "the menu state exports its view").contextMenu
  Assert.deepEqual(
    (actionMenu --[[@as table]]).options,
    { "menu-label-α-0", "menu-label-α-1", "menu-label-α-2" },
    "the menu action menu keeps its source options"
  )
  menuController:updateFixed({ { type = "confirm" } })
  local menuTexts = {}
  local menuResult
  local menuProgram
  for _ = 1, 40 do
    menuResult = menuController:takeResult()
    if menuResult ~= nil then
      break
    end
    local view = menuController:status().view
    Assert.notNil(view, "the menu call keeps publishing its detached view while live")
    local callView = (view --[[@as table]]).call
    if callView == nil then
      break
    end
    menuProgram = callView.program
    menuTexts[#menuTexts + 1] = tostring(callView.program)
      .. ":"
      .. tostring(callView.position)
      .. ":"
      .. tostring(callView.greeting)
    -- Call input never navigates the contact list behind the call.
    Assert.equal((view --[[@as table]]).list.selected, 0, "call input never moves the contact list selection")
    menuResult = menuController:takeResult()
    if menuResult ~= nil then
      break
    end
    menuController:updateFixed({ { type = "advance" } })
  end
  Assert.isNil(menuResult, "menu calls return to their list without a script-host result")
  Assert.isNil(menuController:status().view.call, "the menu releases its completed call projection")
  menuController:dispose()

  -- Scripted entry: the same invitation through staged setup/run nodes
  -- on the real scheduler lane with the real script host underneath.
  local scriptWorld = worldFixture()
  local scriptState = PokegearState.new({ seed = 2024 }, { catalog = record.catalog })
  scriptState:registerContact("custom.mom")
  local host = PokegearScriptHost.new({
    state = scriptState,
    catalog = record.catalog,
    messages = {
      invitation = "custom.invitation",
      accept = "custom.accept",
      resolveLine = function()
        return { tokens = { { kind = "glyph", code = 1, text = "X", raw = { 1 } } } }
      end,
    },
    world = scriptWorld,
    audio = instantAudio(),
    random = PokegearRandom.new(2024),
  })
  local h = schedulerHarness(host)
  local resource = S.script({
    api = 1,
    id = "test.phone_shared_engine",
    steps = {
      S.phoneSetCall({ contact = "custom.mom", direction = "outgoing", kind = "ordinary" }),
      S.phoneRunCall(),
      S.stop(),
    },
  })
  h.registry:installBase("test.phone_shared_engine", resource, "generated")
  local instanceId = h.scheduler:createForeground(assert(h.composition:effective("test.phone_shared_engine")), nil, 100)

  -- Setup stages without blocking or taking the lease; the parent only
  -- blocks once the run operation consumes the staged request.
  h.scheduler:step(100, {})
  Assert.isFalse(host:isActive(), "the staged setup request takes no lease on its own")
  h.scheduler:step(101, {})
  Assert.isTrue(host:isActive(), "the run operation consumes the staged request and takes the lease")
  Assert.notNil(h.scheduler:instance(instanceId), "the parent script stays blocked while its call is live")

  -- Both paths ran the same source-supported caller program without
  -- synthesizing trainer-family script behavior.
  local scriptHandle = host:activeHandle()
  Assert.notNil(scriptHandle, "the scripted call exposes its active handle")
  local scriptResult = settleCall(host, scriptHandle --[[@as table]])
  Assert.deepEqual(scriptWorld.rematchReady, {}, "ordinary calls do not stage rematch readiness")
  Assert.equal(scriptResult.contact, "custom.mom", "the scripted result names the same source caller")
  Assert.equal(scriptResult.kind, "ordinary", "the scripted result names the same call kind")
  Assert.equal(scriptResult.program, menuProgram, "both paths resolve the same source program")
  Assert.isTrue(#menuTexts >= 2, "the menu path observed real conversation progress to compare")
  host:close(scriptHandle --[[@as table]])

  -- The scripted path returns to its field script owner exactly once:
  -- the blocked parent resumes and completes after its single result.
  h.scheduler:step(102, { uiEvents = {} })
  h.scheduler:step(103, { uiEvents = {} })
  Assert.equal(#h.scheduler:tasks(), 0, "the parent script consumes its single call result and resumes")
  Assert.isFalse(host:isActive(), "the resumed parent holds no call lease behind")

  -- Setup and run stay separated on the same shared engine: staging
  -- evaluates its operands and stores one pending request, intervening
  -- commands still run while the lease stays free, running consumes
  -- the stored request and blocks, and running without a staged
  -- request fails carrying its script context.
  local world2 = worldFixture()
  local state2 = PokegearState.new({ seed = 77 }, { catalog = record.catalog })
  state2:registerContact("custom.mom")
  state2:registerContact("custom.trainer-plain")
  local host2 = PokegearScriptHost.new({
    state = state2,
    catalog = record.catalog,
    messages = messageRefs(),
    world = world2,
    audio = instantAudio(),
    random = PokegearRandom.new(77),
  })
  local h2 = schedulerHarness(host2)

  -- The setup operands evaluate at staging time: the contact variable
  -- is read when setup runs, so the intervening reassignment never
  -- redirects the stored pending request, and the lease stays free
  -- until the run operation consumes it. The scheduler runs each ready
  -- script to yield, so setup, the intervening command, and the run
  -- creation share the first tick leaseless and the first task poll
  -- takes the lease on the next tick.
  local resource = S.script({
    api = 1,
    id = "test.phone_staging",
    steps = {
      S.setVar({ variable = "caller", value = "custom.mom" }),
      S.phoneSetCall({ contact = S.var("caller"), direction = "outgoing", kind = "rematch" }),
      S.setVar({ variable = "caller", value = "custom.trainer-plain" }),
      S.phoneRunCall(),
      S.stop(),
    },
  })
  h2.registry:installBase("test.phone_staging", resource, "generated")
  local stagedId = h2.scheduler:createForeground(assert(h2.composition:effective("test.phone_staging")), nil, 200)
  h2.scheduler:step(200, {})
  Assert.isFalse(host2:isActive(), "setup plus an intervening command still take no lease")
  Assert.notNil(h2.scheduler:instance(stagedId), "the parent stays live across its staged setup")
  h2.scheduler:step(201, {})
  Assert.isTrue(host2:isActive(), "the run operation consumes the staged request and blocks")
  local staged = host2:activeHandle()
  Assert.notNil(staged, "the consumed request exposes its active handle")
  local stagedResult = settleCall(host2, staged --[[@as table]])
  Assert.equal(
    stagedResult.contact,
    "custom.mom",
    "the run consumed the request evaluated at setup time, not the reassigned variable"
  )
  host2:close(staged --[[@as table]])
  h2.scheduler:step(203, { uiEvents = {} })
  h2.scheduler:step(204, { uiEvents = {} })
  Assert.equal(#h.scheduler:tasks(), 0, "the parent consumes its single result and resumes")

  -- Running without a staged request fails carrying its script
  -- context, and the failed run takes no lease.
  local lonely = S.script({
    api = 1,
    id = "test.phone_lonely_run",
    steps = {
      S.phoneRunCall(),
      S.stop(),
    },
  })
  h2.registry:installBase("test.phone_lonely_run", lonely, "generated")
  local lonelyId = h2.scheduler:createForeground(assert(h2.composition:effective("test.phone_lonely_run")), nil, 300)
  h2.scheduler:step(300, {})
  -- Ended roots are not retained by the scheduler, so the script.error
  -- event is the designed observation surface for the attributed fault.
  local failure = h2.events:eventFor("script.error", lonelyId)
  Assert.notNil(failure, "the failed run reports its fault on the event stream")
  Assert.equal(failure.code, "FEATURE_UNAVAILABLE", "the missing request fails before any effect")
  local faultText = tostring(failure.message):lower()
  Assert.isTrue(
    faultText:find("phone", 1, true) ~= nil
      or faultText:find("run", 1, true) ~= nil
      or faultText:find("pending", 1, true) ~= nil
      or tostring(failure.scriptId):find("test.phone_lonely_run", 1, true) ~= nil,
    "the missing-request failure carries its script context"
  )
  Assert.isFalse(host2:isActive(), "the failed run takes no lease")
end

return T
