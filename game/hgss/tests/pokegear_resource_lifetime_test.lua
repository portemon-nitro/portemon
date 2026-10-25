-- Bounded resource and input ownership for the pocket gear: repeated
-- viewing leaves no durable trace, a refused normal entry unwinds without
-- holding resources, repeated scripted open/close cycles leave no pending
-- state behind, and repeated polling never advances durable facts. Every
-- scenario composes the real feature bundle over real state, calendar,
-- and draw streams with synthetic catalogs; only host time, input,
-- audio output, and the save root are faked. No machine-speed threshold
-- appears anywhere: bounds are counted lifecycles, not wall-clock gates.

local Assert = require("tests.support.Assert")
local PokegearState = require("libs.hgss.src.save.PokegearState")
local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
local PokegearCalendar = require("game.hgss.src.pokegear.PokegearCalendar")
local PokegearComposition = require("game.hgss.src.pokegear.PokegearComposition")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

local MOM_KEY = "custom.mom"
local NEIGHBOR_KEY = "custom.neighbor"
local TRAINER_KEY = "custom.trainer-plain"
local TRIGGER_PLACE = "custom.place"

---@param path string
---@return table a compiled visual reference
local function visualRef(path)
  return { image = path, width = 32, height = 32, anchorX = 0, anchorY = 0 }
end

---@return table the synthetic compiled asset family
local function assetFamily(catalog)
  return {
    catalog = catalog,
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png") },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png") },
    phone = { panel = visualRef("assets/generated/pokegear/phone-panel.png") },
    map = { base = visualRef("assets/generated/pokegear/map-base.png") },
    fly = { base = visualRef("assets/generated/pokegear/fly-base.png") },
    radio = { dial = visualRef("assets/generated/pokegear/radio-dial.png") },
    text = {},
    sequences = {},
  }
end

---@return table the synthetic compiled contact catalog
local function contactCatalog()
  return {
    contacts = {
      { key = MOM_KEY, family = "mother", id = 1, trainer = 201, gift = 61, map = 0, sortWeight = 10 },
      { key = NEIGHBOR_KEY, family = "friend", id = 10, trainer = 2, gift = 34, map = 8, sortWeight = 20 },
      { key = TRAINER_KEY, family = "trainer", id = 30, trainer = 108, gift = 398, map = 259, sortWeight = 30 },
    },
    contactOrder = { MOM_KEY, NEIGHBOR_KEY, TRAINER_KEY },
    callTriggers = {},
    momPurchases = {},
    locations = {
      { key = TRIGGER_PLACE, mapRef = 8 },
    },
  }
end

---@return table state, catalog, streams, and calendar
local function companion()
  local catalog = contactCatalog()
  local state = PokegearState.new({ seed = 4177 }, { catalog = catalog })
  local random = PokegearRandom.new(4177)
  local calendar = PokegearCalendar.new(state)
  return { state = state, catalog = catalog, random = random, calendar = calendar }
end

---@param friends table
---@return table bundle, table runtime the composed bundle and its fake owner
local function composeGear(friends)
  local runtime = {
    session = { currentMap = { mapSectionNativeId = 8 } },
    eventState = {
      isFlagSet = function()
        return false
      end,
    },
    pokegearState = friends.state,
    pokegearRandom = friends.random,
    pokegearCalendar = friends.calendar,
    pokegearCatalog = friends.catalog,
    presentationDisplay = {
      width = 256,
      height = 192,
      topology = ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 256, height = 192 },
        role = "world",
        touch = false,
      }),
      pixelRatio = 1,
      signature = "pokegear-lifetime-test",
    },
    localClock = {
      nowLocal = function()
        return { year = 2000, month = 1, day = 1, hour = 12, minute = 0, second = 0 }
      end,
    },
    radioMusicIs = function(_, _)
      return false
    end,
    -- The normal phone card reads its context labels through the live
    -- message provider at open; the default bank serves every entry
    -- with a distinct string so composed browse entry stays usable.
    messageProvider = {
      acquireBank = function()
        return {}
      end,
      releaseBank = function() end,
      get = function(_, bank, entry)
        return { text = "text " .. bank .. ":" .. entry }
      end,
    },
  }
  local bundle = PokegearComposition.compose(runtime, {
    state = friends.state,
    catalog = friends.catalog,
    assets = assetFamily(friends.catalog),
    clock = runtime.localClock,
    audio = nil,
    messages = { greeting = "test.greeting.ref" },
  })
  runtime.pokegear = bundle
  return bundle, runtime
end

---@param state table
---@return table phone snapshot copy
local function phoneSnapshot(state)
  local phone = state:readPhone()
  local copy = { contactOrder = {}, triggers = {}, history = {} }
  for index, key in ipairs(phone.contactOrder) do
    copy.contactOrder[index] = key
  end
  for key, value in pairs(phone.triggers) do
    copy.triggers[key] = value
  end
  for key, value in pairs(phone.history) do
    copy.history[key] = value
  end
  return copy
end

-- Repeated viewing leaves no durable trace: twenty-five open, tick, and
-- dispose cycles over a registered contact keep the revision and the full
-- phone snapshot identical, so inspection draws never become writes.
function T.tests.repeated_viewing_leaves_no_durable_trace()
  local friends = companion()
  local bundle = composeGear(friends)
  friends.state:registerContact(MOM_KEY)
  local revisionBefore = friends.state:revision()
  local phoneBefore = phoneSnapshot(friends.state)
  for _ = 1, 25 do
    local screen = bundle.screenFactory({ kind = "browse" })
    for _ = 1, 30 do
      screen:updateFixed({})
    end
    Assert.isNil(screen:takeResult(), "idling reports no terminal result")
    screen:dispose()
  end
  Assert.equal(friends.state:revision(), revisionBefore, "repeated viewing must commit no durable fact")
  Assert.deepEqual(phoneSnapshot(friends.state), phoneBefore, "repeated viewing must not rearrange phone facts")
  bundle:dispose()
end

-- A refused normal entry unwinds without holding resources: while the
-- scripted application holds the feature lease the factory names the
-- lease and commits nothing, and closing the scripted application
-- resumes normal entry with identical durable facts.
function T.tests.refused_normal_entry_unwinds_without_holding_resources()
  local friends = companion()
  local bundle = composeGear(friends)
  friends.state:registerContact(NEIGHBOR_KEY)
  local revisionBefore = friends.state:revision()
  local phoneBefore = phoneSnapshot(friends.state)
  local host = bundle.scriptHost
  local handle = host:open({
    mode = "call",
    request = { id = "lease-lifetime", contact = NEIGHBOR_KEY, direction = "outgoing", kind = "ordinary" },
    parentOwner = "script:lifetime",
  })
  local failure = Assert.throws(function()
    bundle.screenFactory({ kind = "browse" })
  end, "the normal entry never double-steps a scripted screen")
  Assert.notNil(tostring(failure):find("lease", 1, true), "the refusal names the held lease")
  Assert.equal(friends.state:revision(), revisionBefore, "a refused entry must commit no durable fact")
  Assert.deepEqual(phoneSnapshot(friends.state), phoneBefore, "a refused entry must not rearrange phone facts")
  host:close(handle)
  local screen = bundle.screenFactory({ kind = "browse" })
  Assert.notNil(screen, "closing the scripted application resumes normal entry")
  screen:dispose()
  Assert.equal(friends.state:revision(), revisionBefore, "the resumed entry must commit no durable fact")
  bundle:dispose()
end

-- Repeated scripted open and close cycles leave no pending state behind:
-- twenty ordinary call handles open and close with the contact list,
-- triggers, and history identical before and after, and the bundle stays
-- usable for normal entry afterwards.
function T.tests.repeated_scripted_cycles_leave_no_pending_state_behind()
  local friends = companion()
  local bundle = composeGear(friends)
  friends.state:registerContact(NEIGHBOR_KEY)
  local revisionBefore = friends.state:revision()
  local phoneBefore = phoneSnapshot(friends.state)
  local host = bundle.scriptHost
  for index = 1, 20 do
    local handle = host:open({
      mode = "call",
      request = { id = "cycle-" .. index, contact = NEIGHBOR_KEY, direction = "outgoing", kind = "ordinary" },
      parentOwner = "script:cycle",
    })
    host:close(handle)
  end
  Assert.equal(friends.state:revision(), revisionBefore, "cancelled scripted cycles must commit no durable fact")
  Assert.deepEqual(phoneSnapshot(friends.state), phoneBefore, "cancelled scripted cycles must raise no trigger")
  local screen = bundle.screenFactory({ kind = "browse" })
  Assert.notNil(screen, "the bundle stays usable for normal entry after the cycles")
  screen:dispose()
  bundle:dispose()
end

-- Repeated incoming polling never advances durable facts: with no
-- trigger staged, fifty notification reads keep the revision stable and
-- report no ring, so status reads stay pure.
function T.tests.repeated_incoming_polling_advances_no_durable_fact()
  local friends = companion()
  local bundle = composeGear(friends)
  friends.state:registerContact(MOM_KEY)
  local revisionBefore = friends.state:revision()
  local incoming = bundle.incoming
  for _ = 1, 50 do
    Assert.isFalse(incoming:notification(), "an untriggered scheduler must report no ring")
  end
  Assert.equal(friends.state:revision(), revisionBefore, "polling must commit no durable fact")
  Assert.deepEqual(phoneSnapshot(friends.state).triggers, {}, "polling must stage no trigger")
  bundle:dispose()
end

return T
