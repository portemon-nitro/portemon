-- Incoming calls across the real field composition: a competing field
-- claim owns the tick while an eligible call waits, ringing never opens
-- a second modal on its own, preemption clears only transient ring state
-- while the pending trigger survives, and only genuine producer facts
-- raise triggers while absent world systems stay silent. The field side
-- runs through the real FieldSession with deterministic collaborator
-- stand-ins in the established session-test shape; the gear side runs
-- through the real companion state, calendar, random streams, phone
-- policy, reward, and world-context providers. Only host audio, host
-- input snapshots, and the companion application lease are recording
-- boundaries; maps, scripts, actors, messages, and saves are never
-- faked. Full boot-harness journeys stay with the final composition
-- gate: this layer proves the session-to-coordinator priority seam with
-- deterministic claims. No derived assets are required. No ROM data is
-- required.

local Assert = require("tests.support.Assert")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearCalendar = require("game.hgss.src.pokegear.PokegearCalendar")
local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
local PokegearState = require("libs.hgss.src.save.PokegearState")
local PhoneRewards = require("game.hgss.src.pokegear.PhoneRewards")
local PhoneWorldContext = require("game.hgss.src.pokegear.PhoneWorldContext")
local FieldSession = require("libs.hgss.src.field.FieldSession")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

-- Loads the incoming-call coordinator that does not exist yet at this
-- baseline. The failure names the missing behaviour instead of surfacing
-- as a suite load error, so the pre-implementation red stays attributable.
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

local MOM_KEY = "custom.mom"
local TRAINER_KEY = "custom.trainer-plain"
local BILL_KEY = "custom.bill"
local OAK_KEY = "custom.oak"
local MOM_TRIGGER = PhoneRewards.MOM_GIFT_TRIGGER
local BILL_TRIGGER = "custom.bill-pc-full"
local OAK_TRIGGER = "custom.oak-dex-threshold"

---@param path string
---@return table
local function visualRef(path)
  return { image = path, width = 32, height = 32, anchorX = 0, anchorY = 0 }
end

---@param key string
---@param name string
---@param weight integer
---@return table
local function contactRecord(key, name, weight, family)
  return { key = key, name = name, sortWeight = weight, family = family }
end

-- The durable trigger facts the coordinator selects from. Each record
-- carries the trigger key, its owning contact, and the source call kind:
-- kind 3 is an event trigger that clears at acceptance. The record shape
-- is the proposal the coordinator adopts; the single-fire behaviour
-- below is the locked contract.
---@param key string
---@param contact string
---@param kind integer
---@return table
local function triggerRecord(key, contact, kind)
  return { key = key, contact = contact, kind = kind }
end

---@param contacts table[]
---@param triggers table[]
---@return table
local function fixtureManifest(contacts, triggers)
  local order = {}
  for _, contact in ipairs(contacts) do
    order[#order + 1] = contact.key
  end
  return {
    schema = "g4-pokegear-assets-v1",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png") },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png") },
    phone = { panel = visualRef("assets/generated/pokegear/phone-panel.png") },
    map = { base = visualRef("assets/generated/pokegear/map-base.png") },
    fly = { base = visualRef("assets/generated/pokegear/fly-base.png") },
    radio = { dial = visualRef("assets/generated/pokegear/radio-dial.png") },
    catalog = {
      contacts = contacts,
      contactOrder = order,
      callDefinitions = {},
      callTriggers = triggers,
      rematches = {},
      gifts = {},
      momPurchases = {},
      locations = {
        { key = "custom.new-bark" },
      },
      flypoints = {},
      reception = {},
      shows = {},
      radioEffects = {},
    },
    text = {},
    sequences = {},
  }
end

-- One civil sample on a fixed morning that never crosses a day boundary,
-- so expectations need no date arithmetic. Minutes past the hour carry
-- into the hour, keeping every sample a valid civil time.
---@param minute integer
---@param second integer?
---@return table<string, integer>
local function moment(minute, second)
  return {
    year = 2024,
    month = 1,
    day = 8,
    hour = 10 + math.floor(minute / 60),
    minute = minute % 60,
    second = second or 0,
  }
end

---@param overrides table<string, unknown>?
---@return table<string, unknown>
local function opportunityArgs(overrides)
  local args = {
    mapKey = "custom.new-bark-town",
    movementState = "none",
    higherPriorityClaimed = false,
  }
  for key, value in pairs(overrides or {}) do
    args[key] = value
  end
  return args
end

---@param stuck boolean?
---@return table
local function ringAudio(stuck)
  local audio = { plays = {}, playing = false, stops = 0, stuck = stuck == true }
  ---@param sequence string
  function audio:playRing(sequence)
    self.plays[#self.plays + 1] = sequence
    self.playing = true
  end
  function audio:isRingPlaying()
    return self.playing == true
  end
  function audio:completeRing()
    if not self.stuck then
      self.playing = false
    end
  end
  function audio:stopRing()
    self.stops = self.stops + 1
  end
  return audio
end

---@return table
local function recordingHost()
  local host = { opens = {} }
  ---@param args table<string, unknown>
  ---@return table
  function host:open(args)
    assert(type(args) == "table", "companion opens carry their request record")
    self.opens[#self.opens + 1] = args
    return { id = #self.opens }
  end
  function host:isActive()
    return false
  end
  return host
end

-- A coordinator over real companion providers with the durable trigger
-- facts under test. Only the coordinator itself is the behaviour under
-- test; the host is fixed at construction.
---@param seed integer
---@param contacts table[]
---@param triggers table[]
---@param setTriggers string[]
---@return table
local function freshCoordinator(seed, contacts, triggers, setTriggers)
  local IncomingCalls = requireFeature(
    "game.hgss.src.pokegear.IncomingCalls",
    "incoming calls have no field coordinator yet: the session has no pending-caller opportunity to route"
  )
  local record = PokegearAssetSchema.validate(fixtureManifest(contacts, triggers))
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local state = PokegearState.new({ seed = seed }, { catalog = record.catalog })
  for _, contact in ipairs(contacts) do
    state:registerContact(contact.key)
  end
  for _, key in ipairs(setTriggers) do
    state:setTrigger(key, true)
  end
  local trace = {}
  local host = recordingHost()
  return {
    calls = IncomingCalls.new({
      state = state,
      catalog = record.catalog,
      calendar = PokegearCalendar.new(state),
      random = PokegearRandom.new(seed, { trace = trace, traceLimit = 4096 }),
      world = PhoneWorldContext.new({ state = state, flags = {} }),
      host = host,
      audio = ringAudio(false),
    }),
    state = state,
    trace = trace,
    record = record,
    host = host,
  }
end

---@param calls table
local function driveEligible(calls)
  calls:onFieldClock(moment(0))
  calls:onFieldClock(moment(10))
  calls:onFieldClock(moment(20))
end

-- Finds a seed whose first eight random-gate draws all fail, so silence
-- sweeps stay deterministic no matter how many evaluations they drive.
-- Labels never perturb stream values, so the throwaway probe predicts
-- the coordinator's draws exactly.
---@return integer
local function findSilentSeed()
  for seed = 1, 100000 do
    local probe = PokegearRandom.new(seed)
    local silent = true
    for _ = 1, 8 do
      if probe:mt("probe") % 100 <= 50 then
        silent = false
        break
      end
    end
    if silent then
      return seed
    end
  end
  error("the seed scan finds no eight-fold silent gate seed", 0)
  return -1
end

-- The real field session in the established session-test shape: every
-- tick collaborator the session steps is present, input stays idle, and
-- only the script lock, battle flag, and menu modality move under test
-- control. The incoming-call collaborator rides the optional
-- construction seam the coordinator owns.
---@param opts table<string, unknown>
---@return table session, table controls
local function makeFieldSession(opts)
  local controls = {
    scriptOwnsInput = false,
    menuModal = false,
  }
  local player = {
    fieldX = 4,
    fieldZ = 13,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "idle",
    updateFixed = function()
      return false
    end,
    collisionCandidates = function(self)
      return { { fieldX = self.fieldX, fieldZ = self.fieldZ, surfaceId = self.surfaceId } }
    end,
    collisionCandidatesInto = function(self, out)
      local current = out[1]
      if current == nil then
        current = {}
        out[1] = current
      end
      current.fieldX = self.fieldX
      current.fieldZ = self.fieldZ
      current.surfaceId = self.surfaceId
      out[2] = nil
      return out
    end,
    collapseRenderInterpolation = function() end,
    clearGesturePresentation = function() end,
    presentationState = function(self)
      return {
        locomotionActive = self.motion == "walking",
        gesturePose = nil,
        gestureTick = nil,
        gestureOffsetY = 0,
      }
    end,
    presentationStateInto = function(self, out)
      out.locomotionActive = self.motion == "walking"
      out.gesturePose = nil
      out.gestureTick = nil
      out.gestureOffsetY = 0
      return out
    end,
  }
  local scheduler = {
    step = function() end,
    playerInputLocked = function()
      return controls.scriptOwnsInput
    end,
    playerInputOwned = function()
      return controls.scriptOwnsInput
    end,
    foregroundEnvironmentId = function()
      return nil
    end,
    autonomousActorsLocked = function()
      return false
    end,
    autonomousActorLocked = function()
      return false
    end,
  }
  local menuHost = {
    isModal = function()
      return controls.menuModal
    end,
    inputEvents = function(_, events)
      return events
    end,
    advance = function() end,
  }
  local session = FieldSession.new({
    versionId = "heartgold",
    currentMap = { mapId = 61, fieldData = { events = { warps = {} } }, updateAnimated = function() end },
    player = player,
    camera = { updateFixed = function() end },
    transition = {
      phase = "idle",
      locked = false,
      updateFixed = function() end,
      start = function()
        error("no warp", 0)
      end,
    },
    actors = {
      beginFixedStep = function() end,
      step = function() end,
    },
    input = {
      snapshot = function()
        return {}
      end,
      uiSnapshot = function()
        return {}
      end,
      clearEdges = function() end,
    },
    dialogue = {
      isModal = function()
        return false
      end,
    },
    scriptScheduler = scheduler,
    scriptClient = {
      consume = function()
        return require("libs.hgss.src.script.ScriptInteractionClient").RESULTS.blocked
      end,
    },
    menuHost = menuHost,
    contextChoice = {
      isActive = function()
        return false
      end,
    },
    contextChoicePresentation = function()
      return nil
    end,
    signpost = {
      isModal = function()
        return false
      end,
    },
    applicationHost = {
      isActive = function()
        return false
      end,
      updateFixed = function() end,
      requestOpen = function()
        return false
      end,
      takeReopen = function()
        return false
      end,
    },
    pcApplications = {
      isActive = function()
        return false
      end,
      cancelPointerCapture = function() end,
    },
    interactions = {
      resolve = function()
        return nil
      end,
    },
    fieldEntranceIndicator = { updateFixed = function() end },
    eventResolver = {
      resolveCoordinate = function()
        return nil
      end,
      resolvePassiveSign = function()
        return nil
      end,
    },
    eventState = {
      getVar = function() end,
    },
    incomingCalls = opts.incomingCalls,
  })
  return session, controls
end

-- A competing field claim owns the tick while an eligible call waits:
-- script ownership, battle activity, and menu modality each suppress the
-- ring through the real session, ringing never opens a modal on its own,
-- and preemption clears only transient state while the trigger survives.
function T.tests.a_competing_field_claim_owns_the_tick_and_ringing_never_opens_a_second_modal()
  local rig = freshCoordinator(4242, {
    contactRecord(MOM_KEY, "MOM", 10, "mother"),
    contactRecord(TRAINER_KEY, "JACE", 20, "trainer"),
  }, { triggerRecord(MOM_TRIGGER, MOM_KEY, 3) }, { MOM_TRIGGER })
  local calls = rig.calls
  driveEligible(calls)
  local session, controls = makeFieldSession({ incomingCalls = calls })

  -- A foreground script owns the tick: no ring starts and the companion
  -- lease stays untouched.
  controls.scriptOwnsInput = true
  session:updateFixed({})
  Assert.isFalse(calls:notification(), "a script-owned tick never rings")
  Assert.equal(#rig.host.opens, 0, "a script-owned tick opens no companion modal")
  controls.scriptOwnsInput = false

  -- An active battle owns the tick the same way.
  session:setBattleActive(true)
  session:updateFixed({})
  Assert.isFalse(calls:notification(), "a battle-active tick never rings")
  Assert.equal(#rig.host.opens, 0, "a battle-active tick opens no companion modal")
  session:setBattleActive(false)

  -- A modal menu owns the tick the same way.
  controls.menuModal = true
  session:updateFixed({})
  Assert.isFalse(calls:notification(), "a menu-modal tick never rings")
  Assert.equal(#rig.host.opens, 0, "a menu-modal tick opens no companion modal")
  controls.menuModal = false

  -- With every claim released, the next stable tick rings without
  -- opening anything: the ring waits for acceptance, never steals input.
  session:updateFixed({})
  local ringing = calls:notification()
  Assert.notNil(ringing, "the released tick rings the waiting caller")
  assert(type(ringing) == "table", "ringing publishes its caller view")
  Assert.equal(ringing.contactKey, MOM_KEY, "the released tick rings the pending trigger owner")
  Assert.equal(#rig.host.opens, 0, "ringing starts no companion modal on its own")

  -- A higher-priority event during the ring clears only transient state:
  -- the view goes quiet but the pending trigger survives, and the next
  -- stable tick rings again.
  controls.menuModal = true
  session:updateFixed({})
  Assert.isFalse(calls:notification(), "a higher-priority event quiets the active ring")
  Assert.isTrue(
    rig.state:readPhone().triggers[MOM_TRIGGER] == true,
    "preemption preserves the pending event trigger"
  )
  Assert.equal(#rig.host.opens, 0, "preemption opens no companion modal")
  controls.menuModal = false
  session:updateFixed({})
  local again = calls:notification()
  Assert.notNil(again, "the surviving trigger rings again on the next stable tick")
  assert(type(again) == "table", "ringing publishes its caller view")
  Assert.equal(again.contactKey, MOM_KEY, "the re-ring still names the trigger owner")

  -- The direct transient seam agrees: clearing for no signal quiets the
  -- view without touching the trigger, and only acceptance opens the
  -- host, exactly once.
  calls:resetTransient("no-signal")
  Assert.isFalse(calls:notification(), "clearing transient state quiets the view")
  Assert.isTrue(
    rig.state:readPhone().triggers[MOM_TRIGGER] == true,
    "clearing transient state preserves the pending event trigger"
  )
  session:updateFixed({})
  Assert.notNil(calls:notification(), "the trigger re-rings after the transient clear")
  calls:accept("field:test-parent")
  Assert.equal(#rig.host.opens, 1, "only acceptance opens the companion modal, exactly once")
  Assert.isFalse(calls:notification(), "acceptance ends the ring")
  calls:dispose()
end

-- Only genuine producer facts raise triggers and each fires once: an
-- earned savings purchase rings its owner a single time, a genuinely
-- full box reads full while absent box data fails with attribution and
-- raises nothing, below-threshold and absent dex facts stay silent, and
-- absent daycare, safari, and kurt systems never fabricate a call across
-- a long silence sweep.
function T.tests.only_genuine_producer_facts_raise_triggers_and_absent_owners_stay_silent()
  local contacts = {
    contactRecord(MOM_KEY, "MOM", 10, "mother"),
    contactRecord(BILL_KEY, "BILL", 20, "bill"),
    contactRecord(OAK_KEY, "OAK", 30, "oak"),
  }
  local triggers = {
    triggerRecord(MOM_TRIGGER, MOM_KEY, 3),
    triggerRecord(BILL_TRIGGER, BILL_KEY, 3),
    triggerRecord(OAK_TRIGGER, OAK_KEY, 3),
  }
  local seed = findSilentSeed()

  -- An earned savings purchase is a genuine producer fact: the real
  -- reward path sets the gift trigger, the coordinator rings its owner,
  -- acceptance clears it, and the next eligible tick stays silent.
  do
    local rig = freshCoordinator(seed, contacts, triggers, {})
    local candidate = PhoneRewards.preparePurchases(rig.state:revision(), {
      state = rig.state,
      balance = 950,
      previousBalance = 800,
      random = PokegearRandom.new(seed),
    })
    candidate.publish()
    Assert.isTrue(
      rig.state:readPhone().triggers[MOM_TRIGGER] == true,
      "the earned purchase sets the gift trigger through the real reward path"
    )
    driveEligible(rig.calls)
    rig.calls:onOpportunity(opportunityArgs())
    local ringing = rig.calls:notification()
    Assert.notNil(ringing, "the genuine purchase trigger rings")
    assert(type(ringing) == "table", "ringing publishes its caller view")
    Assert.equal(ringing.contactKey, MOM_KEY, "the purchase trigger rings its owner")
    Assert.equal(#rig.host.opens, 0, "the genuine ring opens no modal before acceptance")
    rig.calls:accept("field:test-parent")
    Assert.deepEqual(rig.state:readPhone().triggers, {}, "the fired trigger clears at acceptance")
    rig.calls:onFieldClock(moment(30))
    rig.calls:onOpportunity(opportunityArgs())
    Assert.isFalse(rig.calls:notification(), "the fired trigger never rings twice")
    Assert.equal(#rig.trace, 2, "the single re-evaluation draws only its failing gate")
    rig.calls:dispose()
  end

  -- A genuinely full box is a fact while absent box data is an attributed
  -- failure: the full read reports zero free slots, the absent read names
  -- its missing owner and raises no trigger, and the placed full-box
  -- trigger fires exactly once.
  do
    local rig = freshCoordinator(seed, contacts, triggers, {})
    local full = PhoneWorldContext.new({ state = rig.state, flags = {}, pc = { freeSlots = 0 } })
    Assert.equal(full:read("bill.pc-free"), 0, "a genuinely full box reports zero free slots")
    local bare = PhoneWorldContext.new({ state = rig.state, flags = {} })
    local failure = Assert.throws(function()
      bare:read("bill.pc-free")
    end, "absent box data must fail instead of inventing a full box")
    Assert.equal((failure --[[@as table]]).domain, "pc", "the absent box failure attributes the pc domain")
    Assert.deepEqual(rig.state:readPhone().triggers, {}, "the absent box raises no trigger")
    rig.state:setTrigger(BILL_TRIGGER, true)
    driveEligible(rig.calls)
    rig.calls:onOpportunity(opportunityArgs())
    local ringing = rig.calls:notification()
    Assert.notNil(ringing, "the genuine full-box trigger rings")
    assert(type(ringing) == "table", "ringing publishes its caller view")
    Assert.equal(ringing.contactKey, BILL_KEY, "the full-box trigger rings its owner")
    rig.calls:accept("field:test-parent")
    Assert.deepEqual(rig.state:readPhone().triggers, {}, "the fired trigger clears at acceptance")
    rig.calls:onFieldClock(moment(30))
    rig.calls:onOpportunity(opportunityArgs())
    Assert.isFalse(rig.calls:notification(), "the fired trigger never rings twice")
    rig.calls:dispose()
  end

  -- Below-threshold dex knowledge stays silent while a genuine
  -- at-threshold fact is honoured once; absent dex knowledge fails with
  -- attribution and raises nothing.
  do
    local rig = freshCoordinator(seed, contacts, triggers, {})
    local low = PhoneWorldContext.new({ state = rig.state, flags = {}, dex = { seen = 5, caught = 2 } })
    Assert.equal(low:read("dex.seen"), 5, "below-threshold dex knowledge reads through")
    driveEligible(rig.calls)
    rig.calls:onOpportunity(opportunityArgs())
    Assert.isFalse(rig.calls:notification(), "below-threshold knowledge without a trigger stays silent")
    Assert.deepEqual(rig.state:readPhone().triggers, {}, "below-threshold knowledge raises no trigger")
    local missing = PhoneWorldContext.new({ state = rig.state, flags = {} })
    local failure = Assert.throws(function()
      missing:read("dex.seen")
    end, "absent dex knowledge must fail instead of inventing a threshold")
    Assert.equal((failure --[[@as table]]).domain, "dex", "the absent dex failure attributes the dex domain")
    local high = PhoneWorldContext.new({ state = rig.state, flags = {}, dex = { seen = 200, caught = 100 } })
    Assert.equal(high:read("dex.seen"), 200, "at-threshold dex knowledge reads through")
    rig.state:setTrigger(OAK_TRIGGER, true)
    rig.calls:onFieldClock(moment(30))
    rig.calls:onOpportunity(opportunityArgs())
    local ringing = rig.calls:notification()
    Assert.notNil(ringing, "the genuine threshold trigger rings")
    assert(type(ringing) == "table", "ringing publishes its caller view")
    Assert.equal(ringing.contactKey, OAK_KEY, "the threshold trigger rings its owner")
    rig.calls:accept("field:test-parent")
    Assert.deepEqual(rig.state:readPhone().triggers, {}, "the fired trigger clears at acceptance")
    rig.calls:onFieldClock(moment(40))
    rig.calls:onOpportunity(opportunityArgs())
    Assert.isFalse(rig.calls:notification(), "the fired trigger never rings twice")
    rig.calls:dispose()
  end

  -- Absent daycare, safari, and kurt systems never fabricate a call: each
  -- read fails naming its domain, and a long sweep of eligible ticks
  -- with no triggers raises nothing and draws only failing gates.
  do
    local rig = freshCoordinator(seed, contacts, triggers, {})
    local bare = PhoneWorldContext.new({ state = rig.state, flags = {} })
    for _, key in ipairs({ "daycare.egg", "safari.test", "kurt.production" }) do
      local failure = Assert.throws(function()
        bare:read(key)
      end, "absent " .. key .. " must fail instead of fabricating a call")
      local domain = key:match("^([^.]+)%.")
      Assert.equal((failure --[[@as table]]).domain, domain, "the absent failure attributes " .. domain)
    end
    rig.calls:onFieldClock(moment(0))
    rig.calls:onFieldClock(moment(10))
    for minute = 20, 80, 10 do
      rig.calls:onFieldClock(moment(minute))
      rig.calls:onOpportunity(opportunityArgs())
      Assert.isFalse(rig.calls:notification(), "minute " .. minute .. " with no producers stays silent")
    end
    Assert.deepEqual(rig.state:readPhone().triggers, {}, "the sweep raises no trigger")
    Assert.isFalse(
      rig.calls:notification(),
      "polling after the sweep stays silent"
    )
    for _, entry in ipairs(rig.trace) do
      Assert.equal(entry.stream, "mt", "the sweep draws only random gates")
      assert(type(entry.value) == "number", "gate draw recorded above")
      Assert.isTrue(entry.value % 100 > 50, "every swept gate fails")
    end
    rig.calls:dispose()
  end
end

return T
