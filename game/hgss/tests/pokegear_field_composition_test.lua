-- Field composition for the pocket gear: the concrete bundle wires
-- real state, catalog, clock, and audio into its screen factory, script
-- host, incoming owner, and radio reader; source opcodes execute through
-- injected services; and the save gate refuses live controllers. Every
-- journey here uses real providers with synthetic catalogs; only host
-- time, input, audio output, and the save root are faked.

local Assert = require("tests.support.Assert")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
local PokegearState = require("libs.hgss.src.save.PokegearState")
local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
local PokegearCalendar = require("game.hgss.src.pokegear.PokegearCalendar")
local PokegearSources = require("romdump.src.config.PokegearSources")
local MapReference = require("romdump.src.reference.hgss.maps")
local PokegearComposition = require("game.hgss.src.pokegear.PokegearComposition")
local FieldMenuCompositionCoordinator = require("game.hgss.src.field.FieldMenuCompositionCoordinator")
local FieldSaveCoordinator = require("game.hgss.src.field.FieldSaveCoordinator")
local FieldScriptComposition = require("game.hgss.src.field.FieldScriptComposition")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local S = require("gen4.script")

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
    map = require("tests.support.PokegearMapFixture").manifest().map,
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
    momPurchases = {
      { kind = "berry", nativeItemId = 149 },
      { kind = "berry", nativeItemId = 150 },
      { kind = "berry", nativeItemId = 151 },
      { kind = "berry", nativeItemId = 152 },
      { kind = "berry", nativeItemId = 153 },
      { kind = "berry", nativeItemId = 154 },
      { kind = "berry", nativeItemId = 155 },
      { kind = "berry", nativeItemId = 156 },
      { kind = "berry", nativeItemId = 157 },
      { kind = "berry", nativeItemId = 158 },
      { kind = "berry", nativeItemId = 159 },
      { kind = "berry", nativeItemId = 160 },
      { kind = "berry", nativeItemId = 161 },
      { kind = "berry", nativeItemId = 162 },
      { kind = "berry", nativeItemId = 163 },
      { kind = "berry", nativeItemId = 164 },
      { kind = "berry", nativeItemId = 165 },
    },
    locations = PokegearSources.mapLocationRecords("heartgold"),
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
---@param latch string? the latched radio sequence behind queries
---@return table bundle, table runtime the composed bundle and its fake owner
local function composeGear(friends, latch)
  local newBark = assert(MapReference.byId[60], "the field fixture uses the native New Bark map header")
  friends.catalog.callPermissions = {
    [newBark.id] = {
      incoming = newBark.incomingCalls,
      outgoing = newBark.outgoingCalls,
    },
  }
  local runtime = {
    pokegearState = friends.state,
    pokegearRandom = friends.random,
    pokegearCalendar = friends.calendar,
    pokegearCatalog = friends.catalog,
    session = {
      currentMap = {
        mapId = newBark.id,
        mapSymbol = "MAP_NEW_BARK",
        mapSectionNativeId = 60,
        fieldData = { transitionEnvironment = "outdoors" },
      },
    },
    eventState = {
      isFlagSet = function()
        return false
      end,
    },
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
      signature = "pokegear-composition-test",
    },
    localClock = {
      nowLocal = function()
        return { year = 2000, month = 1, day = 1, hour = 12, minute = 0, second = 0 }
      end,
    },
    radioMusicIs = function(_, effect)
      return latch == effect
    end,
    itemCatalog = {
      itemKeyByNativeId = function(_, nativeId)
        return "custom.item-" .. tostring(nativeId)
      end,
      item = function(_, itemKey)
        local nativeId = tonumber(itemKey:match("custom.item%-(%d+)"))
        if itemKey == "POTION" then
          nativeId = 34
        end
        return { nativeId = nativeId }
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

---@return table item catalog double translating native ids by prefix
local function stubItemCatalog()
  return {
    itemKeyByNativeId = function(_, nativeId)
      return "custom.item-" .. tostring(nativeId)
    end,
    item = function(_, itemKey)
      local nativeId = tonumber(itemKey:match("custom.item%-(%d+)"))
      if itemKey == "POTION" then
        nativeId = 34
      end
      return { nativeId = nativeId }
    end,
  }
end

---@param bundle table
---@param friends table
---@return table services behind the new script operations
local function scriptServices(bundle, friends)
  return {
    pokegearApplications = bundle.scriptHost,
    phoneContactIndex = assert(
      FieldScriptComposition.phoneContactIndex(friends.catalog),
      "contact index builds over the synthetic catalog"
    ),
    pokegearState = friends.state,
    phoneGifts = assert(
      FieldScriptComposition.phoneGiftQueries(friends.state, friends.catalog, friends.random, stubItemCatalog()),
      "gift queries build over the synthetic owners"
    ),
    radioMusic = bundle.radioEffects,
  }
end

---@param services table
---@return table run, table variables scheduler-shaped run context behind handler execution
local function handlerRun(services)
  local variables = {}
  local run = {
    instance = { scriptId = "test.gear", mode = "foreground", instanceId = "gear-1" },
    services = services,
    semantics = RuntimeValues,
    scheduler = {
      createTask = function()
        error("unit handlers never block", 0)
      end,
    },
    tick = 7,
  }
  run.services.world = {
    getVar = function(_, id)
      return variables[id] or 0
    end,
    setVar = function(_, id, value)
      variables[id] = value
    end,
  }
  return run, variables
end

function T.tests.composition_exposes_its_closed_bundle()
  local friends = companion()
  local bundle = composeGear(friends)
  Assert.notNil(bundle.screenFactory, "the bundle carries its screen factory")
  Assert.notNil(bundle.scriptHost, "the bundle carries its script host")
  Assert.notNil(bundle.incoming, "the bundle carries its incoming owner")
  Assert.notNil(bundle.radioEffects, "the bundle carries its radio reader")
  Assert.notNil(bundle.dispose, "the bundle carries its disposal")
  local count = 0
  for _ in pairs(bundle) do
    count = count + 1
  end
  Assert.equal(count, 5, "the bundle stays closed")
end

function T.tests.screen_factory_builds_a_usable_phone_screen()
  local friends = companion()
  local bundle = composeGear(friends)
  local screen = bundle.screenFactory({ kind = "browse" })
  Assert.notNil(screen, "the factory returns a usable screen")
  local status = screen:status()
  Assert.equal(status.tab, "phone", "a fresh shell opens its remembered phone tab")
  for _ = 1, 30 do
    screen:updateFixed({})
  end
  Assert.equal(screen:status().tab, "phone", "the idle shell keeps its single owner across ticks")
  Assert.isNil(screen:takeResult(), "idling reports no terminal result")
  screen:dispose()
end

-- The composed map tab samples the live roamer owner once at open: the
-- roaming record projects, other lifecycles stay out, and sampling moves
-- nothing. Production never substitutes an empty snapshot.
function T.tests.composed_map_tab_samples_live_roamers_without_moving_them()
  local friends = companion()
  -- The region map carries New Bark's source map so the live roamer sits on a visible location.
  local regionMap = require("tests.support.PokegearRegionMapFixture").build()
  regionMap.locations[1].mapId = 60
  regionMap.locations[1].mapSymbol = "MAP_NEW_BARK"
  regionMap.locations[1].x, regionMap.locations[1].y = 21, 14
  friends.catalog.regionMap = regionMap
  friends.state:registerCard("map")
  friends.state:setPreference("lastApp", "map")
  local HgssRoamerState = require("libs.hgss.src.encounters.HgssRoamerState")
  local EncounterSave = require("libs.hgss.src.save.EncounterSave")
  local function record(key, species, location, lifecycle)
    return {
      key = key,
      stateVersion = EncounterSave.STATE_VERSION,
      mon = { species = species },
      location = location,
      lifecycle = lifecycle,
      revision = 0,
    }
  end
  local roamers = HgssRoamerState.new({
    records = {
      record("test.roamer.raikou", "RAIKOU", 60, "roaming"),
      record("test.roamer.entei", "ENTEI", 61, "caught"),
    },
    species = { RAIKOU = true, ENTEI = true },
    maps = { [60] = true, [61] = true },
  })
  local bundle, runtime = composeGear(friends)
  runtime.session = {
    currentMap = {
      mapSymbol = "MAP_NEW_BARK",
      mapSectionNativeId = 60,
      fieldData = { transitionEnvironment = "outdoors" },
    },
  }
  runtime.player = { fieldX = 695, fieldZ = 397 }
  runtime.playerData = { profile = { gender = 0 } }
  runtime.roamerState = roamers
  runtime.messageProvider = {
    acquireBank = function()
      return {}
    end,
    releaseBank = function() end,
    get = function(_, bank, entry)
      return { text = "text " .. bank .. ":" .. entry }
    end,
  }
  runtime.scripts = {
    worldState = {
      isFlagSet = function()
        return false
      end,
    },
  }
  local screen = bundle.screenFactory({ kind = "browse" })
  Assert.equal(screen:status().tab, "map", "the remembered map tab opens through the factory")
  local child = (screen:status().child --[[@as table]]).view --[[@as table]]
  Assert.notNil(child, "the composed map publishes its view")
  local drawn = (child.sprites --[[@as table]]).roamers --[[@as table]]
  Assert.equal(#drawn, 1, "only the roaming record projects from live owners")
  Assert.equal((drawn[1] --[[@as table]]).frame, 1, "the roaming record is Raikou")
  Assert.equal(
    (roamers:capture().roamers --[[@as table]])["test.roamer.raikou"].location,
    60,
    "sampling moves no roamer"
  )
  screen:dispose()
end

function T.tests.screen_factory_refuses_while_the_script_lease_is_held()
  local friends = companion()
  local bundle = composeGear(friends)
  friends.state:registerContact(NEIGHBOR_KEY)
  local host = bundle.scriptHost
  local handle = host:open({
    mode = "call",
    request = { id = "lease-1", contact = NEIGHBOR_KEY, direction = "outgoing", kind = "ordinary" },
    parentOwner = "script:lease",
  })
  local ok, err = pcall(bundle.screenFactory, { kind = "browse" })
  Assert.isFalse(ok, "the normal entry never double-steps a scripted screen")
  Assert.notNil(tostring(err):find("lease", 1, true), "the refusal names the held lease")
  host:close(handle)
  local screen = bundle.screenFactory({ kind = "browse" })
  Assert.notNil(screen, "closing the scripted application resumes normal entry")
  screen:dispose()
end

function T.tests.disposal_releases_exactly_once_and_keeps_durable_facts()
  local friends = companion()
  local bundle = composeGear(friends)
  friends.state:registerContact(MOM_KEY)
  friends.state:setTrigger("gear.trigger.5", true)
  bundle:dispose()
  bundle:dispose()
  Assert.deepEqual(friends.state:readPhone().contactOrder, { MOM_KEY }, "disposal preserves committed contacts")
  Assert.deepEqual(
    friends.state:readPhone().triggers,
    { ["gear.trigger.5"] = true },
    "disposal preserves pending triggers"
  )
end

function T.tests.incoming_owner_enters_through_the_real_host()
  local friends = companion()
  local bundle = composeGear(friends)
  friends.state:registerContact(NEIGHBOR_KEY)
  Assert.isFalse(bundle.incoming:notification(), "no call rings before its trigger")
  friends.state:setTrigger("gear.trigger.5", true)
  Assert.isFalse(bundle.incoming:notification(), "unknown trigger slots ring nothing")
  friends.state:setTrigger("gear.trigger.5", false)
  Assert.deepEqual(friends.state:readPhone().triggers, {}, "clearing leaves no residue")
end

function T.tests.disposal_factory_after_teardown_fails()
  local friends = companion()
  local bundle = composeGear(friends)
  bundle:dispose()
  local ok, err = pcall(bundle.screenFactory, { kind = "browse" })
  Assert.isFalse(ok, "a disposed composition opens nothing")
  Assert.notNil(tostring(err):find("disposed", 1, true), "the refusal names its teardown")
end

function T.tests.menu_catalogue_registers_the_gear_destination()
  local friends = companion()
  local bundle = composeGear(friends)
  local coordinator = FieldMenuCompositionCoordinator.new({ pokegear = bundle })
  local found = false
  for _, descriptor in ipairs(coordinator:applicationDescriptors()) do
    if descriptor.id == FieldApplicationIds.POKEGEAR then
      found = true
      Assert.isTrue(type(descriptor.factory) == "function", "the gear destination carries a factory")
      local screen = descriptor.factory()
      Assert.notNil(screen, "the registered factory returns a usable screen")
      screen:dispose()
    end
  end
  Assert.isTrue(found, "the field catalogue registers the gear destination")
end

function T.tests.card_registration_follows_source_bit_semantics()
  local friends = companion()
  local bundle = composeGear(friends)
  local run = handlerRun(scriptServices(bundle, friends))
  Assert.equal(
    Runtime.executeNode({ op = "pokegear_register_card", card = "map" }, run),
    Runtime.OUTCOME_CONTINUE,
    "map registration commits same-tick"
  )
  Assert.isTrue(friends.state:capture().registeredCards.map == true, "the map bit sets")
  Assert.equal(
    Runtime.executeNode({ op = "pokegear_register_card", card = "radio" }, run),
    Runtime.OUTCOME_CONTINUE,
    "radio registration commits same-tick"
  )
  Assert.isTrue(friends.state:capture().registeredCards.radio == true, "the radio bit sets")
  Assert.equal(
    Runtime.executeNode({ op = "pokegear_register_card", card = "phone" }, run),
    Runtime.OUTCOME_CONTINUE,
    "re-registering the base card commits same-tick"
  )
  Assert.deepEqual(friends.state:capture().registeredCards, { phone = true }, "the base card clears both optional bits")
end

function T.tests.repeated_registration_never_duplicates_or_resorts()
  local friends = companion()
  local bundle = composeGear(friends)
  local run = handlerRun(scriptServices(bundle, friends))
  local update = { op = "pokegear_update", kind = "register_contact", contact = 1 }
  Assert.equal(Runtime.executeNode(update, run), Runtime.OUTCOME_CONTINUE, "first registration commits")
  Assert.equal(Runtime.executeNode(update, run), Runtime.OUTCOME_CONTINUE, "repeats stay silent successes")
  Assert.deepEqual(friends.state:readPhone().contactOrder, { MOM_KEY }, "repeats never duplicate")
  local run2, vars2 = handlerRun(scriptServices(bundle, friends))
  Assert.equal(
    Runtime.executeNode({
      op = "pokegear_query",
      kind = "contact_registered",
      contact = 1,
      result = { value = "var", id = "seen" },
    }, run2),
    Runtime.OUTCOME_CONTINUE,
    "queries resolve same-tick"
  )
  Assert.equal(vars2.seen, 1, "the registered contact reads back registered")
end

function T.tests.unknown_contacts_and_selectors_fail_loudly()
  local friends = companion()
  local bundle = composeGear(friends)
  local run = handlerRun(scriptServices(bundle, friends))
  local okContact, errContact =
    pcall(Runtime.executeNode, { op = "pokegear_update", kind = "register_contact", contact = 999 }, run)
  Assert.isFalse(okContact, "unknown contact numbers never register")
  Assert.notNil(tostring(errContact):find("999", 1, true), "the failure names its number")
  local okDirection, errDirection = pcall(Runtime.executeNode, {
    op = "phone_set_call",
    contact = NEIGHBOR_KEY,
    direction = 9,
    kind = 0,
  }, run)
  Assert.isFalse(okDirection, "unknown direction codes never stage")
  Assert.equal(errDirection.code, "SCRIPT_INVALID_REFERENCE", "the failure carries its vocabulary")
  local okKind, errKind = pcall(Runtime.executeNode, {
    op = "phone_set_call",
    contact = NEIGHBOR_KEY,
    direction = 2,
    kind = 9,
  }, run)
  Assert.isFalse(okKind, "unknown kind codes never stage")
  Assert.equal(errKind.code, "SCRIPT_INVALID_REFERENCE", "the failure carries its vocabulary")
  local okTrigger, errTrigger =
    pcall(Runtime.executeNode, { op = "pokegear_set_trigger", trigger = 300, active = true }, run)
  Assert.isFalse(okTrigger, "out-of-range slots never switch")
  Assert.notNil(tostring(errTrigger):find("300", 1, true), "the failure names its slot")
end

function T.tests.setup_and_run_keep_their_native_sequencing()
  local friends = companion()
  local bundle = composeGear(friends)
  friends.state:registerContact(NEIGHBOR_KEY)
  local services = scriptServices(bundle, friends)
  local staged = {}
  local run = handlerRun(services)
  run.scheduler = {
    createTask = function(_, taskType, spec)
      staged[#staged + 1] = { type = taskType, spec = spec }
      return "task-staged"
    end,
  }
  Assert.equal(
    Runtime.executeNode({ op = "phone_set_call", contact = 10, direction = 2, kind = 0 }, run),
    Runtime.OUTCOME_CONTINUE,
    "numeric setup stages without blocking"
  )
  Assert.equal(Runtime.executeNode({ op = "phone_run_call" }, run), Runtime.OUTCOME_BLOCK, "run consumes and blocks")
  Assert.equal(#staged, 1, "run blocks on exactly one application task")
  Assert.equal(staged[1].type, "pokegear_application", "the task is the companion application")
  Assert.equal(staged[1].spec.kind, "call", "the staged call opens its child")
  Assert.equal(staged[1].spec.request.contact, NEIGHBOR_KEY, "numbers translate at the boundary")
  Assert.equal(staged[1].spec.request.direction, "incoming", "the observed code stages incoming")
  Assert.equal(staged[1].spec.request.kind, "ordinary", "the observed code stages ordinary")
  local lonelyRun = handlerRun(services)
  local ok, err = pcall(Runtime.executeNode, { op = "phone_run_call" }, lonelyRun)
  Assert.isFalse(ok, "running without a staged request faults")
  Assert.notNil(
    tostring(err):find("staged", 1, true) or tostring(err):find("phone_run_call", 1, true),
    "the failure names its operation"
  )
end

function T.tests.staged_calls_complete_through_the_real_task_and_host()
  local friends = companion()
  local bundle = composeGear(friends)
  friends.state:registerContact(NEIGHBOR_KEY)
  local host = bundle.scriptHost
  local PokegearApplicationTask = require("libs.hgss.src.script.tasks.PokegearApplicationTask")
  local taskCtx = { services = { pokegearApplications = host }, input = { uiEvents = {} } }
  local taskState = PokegearApplicationTask.create({
    kind = "call",
    request = { id = "task-1", contact = NEIGHBOR_KEY, direction = "outgoing", kind = "ordinary" },
    parentOwner = "script:task",
  }, taskCtx)
  taskCtx.input = { uiEvents = { { type = "advance" } } }
  local done = false
  for _ = 1, 60 do
    local polled = PokegearApplicationTask.poll(taskState, taskCtx)
    if polled.complete then
      done = true
      break
    end
  end
  Assert.isTrue(done, "the staged call completes through its task and host")
  Assert.isFalse(host:isActive(), "completion releases the feature lease")
  Assert.isTrue(host:isStableForSave(), "completion resumes save capture")
end

function T.tests.trigger_switches_roundtrip_through_save_state()
  local friends = companion()
  local bundle = composeGear(friends)
  local run = handlerRun(scriptServices(bundle, friends))
  Assert.equal(
    Runtime.executeNode({ op = "pokegear_set_trigger", trigger = 5, active = true }, run),
    Runtime.OUTCOME_CONTINUE,
    "setting commits same-tick"
  )
  Assert.deepEqual(friends.state:readPhone().triggers, { ["gear.trigger.5"] = true }, "numbers fold to the canon")
  Assert.equal(
    Runtime.executeNode({ op = "pokegear_set_trigger", trigger = "gear.trigger.5", active = false }, run),
    Runtime.OUTCOME_CONTINUE,
    "clearing commits same-tick"
  )
  Assert.deepEqual(friends.state:readPhone().triggers, {}, "clearing leaves no residue")
end

function T.tests.phonebook_resolution_uses_the_source_none_sentinel()
  local friends = companion()
  local bundle = composeGear(friends)
  local run2, vars2 = handlerRun(scriptServices(bundle, friends))
  Assert.equal(
    Runtime.executeNode({
      op = "phone_resolve_contact",
      trainer = 2,
      result = { value = "var", id = "entry" },
    }, run2),
    Runtime.OUTCOME_CONTINUE,
    "trainer numbers resolve same-tick"
  )
  Assert.equal(vars2.entry, 10, "trainer 2 answers phonebook entry 10")
  local run3, vars3 = handlerRun(scriptServices(bundle, friends))
  Assert.equal(
    Runtime.executeNode({
      op = "phone_resolve_contact",
      trainer = 4242,
      result = { value = "var", id = "entry" },
    }, run3),
    Runtime.OUTCOME_CONTINUE,
    "unknown trainers answer same-tick"
  )
  Assert.equal(vars3.entry, 255, "unknown trainers answer the none sentinel")
end

function T.tests.contact_messages_fail_honestly_without_phone_data()
  local friends = companion()
  local bundle = composeGear(friends)
  local run = handlerRun(scriptServices(bundle, friends))
  local ok, err = pcall(Runtime.executeNode, {
    op = "phone_contact_message",
    contact = NEIGHBOR_KEY,
    kind = 2,
    bank = { value = "var", id = "bank" },
    entry = { value = "var", id = "entry" },
  }, run)
  Assert.isFalse(ok, "unserved message pairs never fabricate")
  Assert.equal(err.code, "FEATURE_UNAVAILABLE", "the failure names its absent data")
end

function T.tests.gift_queries_answer_waiting_gifts_or_zero()
  local friends = companion()
  local bundle = composeGear(friends)
  friends.state:registerContact(NEIGHBOR_KEY)
  friends.state:registerContact(TRAINER_KEY)
  friends.state:setContactReward(TRAINER_KEY, { item = "POTION", quantity = 1 })
  local run, vars = handlerRun(scriptServices(bundle, friends))
  Assert.equal(
    Runtime.executeNode({
      op = "phone_contact_gift",
      contact = 10,
      kind = "berry",
      result = { value = "var", id = "berry" },
    }, run),
    Runtime.OUTCOME_CONTINUE,
    "berry queries resolve same-tick"
  )
  Assert.isTrue(
    type(vars.berry) == "number" and vars.berry >= 149 and vars.berry <= 165,
    "fresh berries return a native item ID"
  )
  Assert.equal(
    Runtime.executeNode({
      op = "phone_contact_gift",
      contact = 30,
      kind = "item",
      result = { value = "var", id = "gift" },
    }, run),
    Runtime.OUTCOME_CONTINUE,
    "staged rewards report instead of stacking"
  )
  Assert.equal(vars.gift, 34, "the waiting gift reports its native item ID")
  Assert.equal(
    Runtime.executeNode({
      op = "phone_contact_gift",
      contact = 30,
      kind = "berry",
      result = { value = "var", id = "berry2" },
    }, run),
    Runtime.OUTCOME_CONTINUE,
    "staged rewards cover every kind"
  )
  Assert.equal(vars.berry2, 34, "pending rewards answer with their native item ID before any draw")
  local run2, vars2 = handlerRun(scriptServices(bundle, friends))
  Assert.equal(
    Runtime.executeNode({ op = "mom_gift_check", result = { value = "var", id = "mom" } }, run2),
    Runtime.OUTCOME_CONTINUE,
    "parent gifts resolve same-tick"
  )
  Assert.equal(vars2.mom, 0, "an empty queue answers numeric zero")
end

function T.tests.parent_gift_check_returns_boolean_for_a_non_one_item_id()
  local friends = companion()
  local bundle = composeGear(friends)
  local run, vars = handlerRun(scriptServices(bundle, friends))
  Runtime.executeNode({ op = "mom_gift_check", result = { value = "var", id = "empty" } }, run)
  Assert.equal(vars.empty, 0, "an empty queue returns BOOL zero")

  friends.state:setMom({
    balance = 0,
    purchases = {},
    gifts = { { item = "custom.item-42", quantity = 2 } },
  })

  local revision = friends.state:revision()
  Assert.equal(
    Runtime.executeNode({ op = "mom_gift_check", result = { value = "var", id = "hasGift" } }, run),
    Runtime.OUTCOME_CONTINUE,
    "the source gift check completes synchronously"
  )
  Assert.equal(vars.hasGift, 1, "the gift check returns BOOL instead of native item ID 42")
  Runtime.executeNode({ op = "mom_gift_check", result = { value = "var", id = "hasGiftAgain" } }, run)
  Assert.equal(vars.hasGiftAgain, 1, "repeated gift checks preserve the boolean result")
  Assert.equal(friends.state:revision(), revision, "gift checks never mutate the saved queue")
end

function T.tests.parent_gift_head_and_take_preserve_fifo_across_boolean_checks()
  local friends = companion()
  local bundle = composeGear(friends)
  friends.state:setMom({
    balance = 0,
    purchases = {},
    gifts = {
      { item = "custom.item-42", quantity = 2 },
      { item = "custom.item-73", quantity = 3 },
    },
  })
  local run, vars = handlerRun(scriptServices(bundle, friends))

  Runtime.executeNode({
    op = "mom_gift_head",
    item = { value = "var", id = "item" },
    quantity = { value = "var", id = "quantity" },
  }, run)
  Assert.equal(vars.item, 42, "the head query keeps the first native item ID")
  Assert.equal(vars.quantity, 2, "the head query keeps the first quantity")

  Runtime.executeNode({ op = "mom_gift_take" }, run)
  Assert.equal(friends.state:readPhone().mom.gifts[1].item, "custom.item-73", "take advances the FIFO once")
  Runtime.executeNode({
    op = "mom_gift_head",
    item = { value = "var", id = "nextItem" },
    quantity = { value = "var", id = "nextQuantity" },
  }, run)
  Assert.equal(vars.nextItem, 73, "the next head keeps its native item ID")
  Assert.equal(vars.nextQuantity, 3, "the next head keeps its native quantity")
  Runtime.executeNode({ op = "mom_gift_check", result = { value = "var", id = "nextHasGift" } }, run)
  Assert.equal(vars.nextHasGift, 1, "the second gift also returns strict BOOL instead of native item ID 73")

  Runtime.executeNode({ op = "mom_gift_take" }, run)
  Assert.deepEqual(friends.state:readPhone().mom.gifts, {}, "the second take empties the FIFO")
  Runtime.executeNode({ op = "mom_gift_check", result = { value = "var", id = "empty" } }, run)
  Assert.equal(vars.empty, 0, "an empty queue returns strict BOOL zero")
end

function T.tests.radio_queries_compare_the_audio_latch()
  local friends = companion()
  local bundle = composeGear(friends, "pokeflute")
  local run, vars = handlerRun(scriptServices(bundle, friends))
  Assert.equal(
    Runtime.executeNode({
      op = "radio_music_query",
      effect = "pokeflute",
      result = { value = "var", id = "flute" },
    }, run),
    Runtime.OUTCOME_CONTINUE,
    "latch queries resolve same-tick"
  )
  Assert.equal(vars.flute, 1, "the latched effect compares true")
  local run2, vars2 = handlerRun(scriptServices(bundle, friends))
  Assert.equal(
    Runtime.executeNode({
      op = "radio_music_query",
      effect = "march",
      result = { value = "var", id = "march" },
    }, run2),
    Runtime.OUTCOME_CONTINUE,
    "other effects resolve same-tick"
  )
  Assert.equal(vars2.march, 0, "unlatched effects compare false")
end

function T.tests.password_splitting_covers_its_boundaries()
  local friends = companion()
  local bundle = composeGear(friends)
  local cases = {
    { password = 0, first = 40, correct = 0 },
    { password = 1, first = 40, correct = 1 },
    { password = 2, first = 40, correct = 2 },
    { password = 3, first = 43, correct = 0 },
    { password = 28, first = 67, correct = 1 },
    { password = 29, first = 67, correct = 2 },
  }
  for _, example in ipairs(cases) do
    local run, vars = handlerRun(scriptServices(bundle, friends))
    vars.passwordVar = example.password
    Assert.equal(
      Runtime.executeNode({
        op = "buena_password",
        password = { value = "var", id = "passwordVar" },
        firstWord = { value = "var", id = "first" },
        correct = { value = "var", id = "answer" },
      }, run),
      Runtime.OUTCOME_CONTINUE,
      "password " .. example.password .. " splits same-tick"
    )
    Assert.equal(vars.first, example.first, "password " .. example.password .. " opens its triple")
    Assert.equal(vars.answer, example.correct, "password " .. example.password .. " names its winner")
    Assert.isTrue(vars.first + vars.answer == 40 + (example.password % 30), "the winner stays the announced entry")
  end
end

function T.tests.new_builders_validate_and_reject_their_shapes()
  Assert.isTrue(
    S.validate(S.script({
      api = 1,
      id = "test.gear_shapes",
      steps = {
        S.pokegearRegisterCard({ card = "map" }),
        S.pokegearSetTrigger({ trigger = 5, active = true }),
        S.phoneResolveContact({ trainer = S.var("t"), result = S.var("r") }),
        S.phoneContactMessage({ contact = "custom.mom", kind = 2, bank = S.var("b"), entry = S.var("e") }),
        S.phoneContactGift({ contact = "custom.mom", kind = "berry", result = S.var("r") }),
        S.radioMusicQuery({ effect = "pokeflute", result = S.var("r") }),
        S.momGiftCheck({ result = S.var("r") }),
        S.buenaPassword({ firstWord = S.var("f"), correct = S.var("c") }),
        S.stop(),
      },
    })),
    "the new operations validate"
  )
  Assert.isNil(
    S.validate(S.script({
      api = 1,
      id = "test.gear_bad_card",
      steps = { S.pokegearRegisterCard({ card = "signal" }), S.stop() },
    })),
    "open card vocabularies never validate"
  )
  Assert.isNil(
    S.validate(S.script({
      api = 1,
      id = "test.gear_bad_gift",
      steps = { S.phoneContactGift({ contact = "custom.mom", kind = "candy", result = S.var("r") }), S.stop() },
    })),
    "open gift kinds never validate"
  )
  Assert.isNil(
    S.validate(S.script({
      api = 1,
      id = "test.gear_bad_effect",
      steps = { S.radioMusicQuery({ effect = "static", result = S.var("r") }), S.stop() },
    })),
    "open music effects never validate"
  )
end

function T.tests.bare_fly_stays_gated_at_the_task()
  local PokegearApplicationTask = require("libs.hgss.src.script.tasks.PokegearApplicationTask")
  local friends = companion()
  local bundle = composeGear(friends)
  local taskCtx = { services = { pokegearApplications = bundle.scriptHost }, input = { uiEvents = {} } }
  local ok, err = pcall(PokegearApplicationTask.create, { kind = "fly", parentOwner = "script:fly" }, taskCtx)
  Assert.isFalse(ok, "a bare fly entry never opens a selector")
  Assert.notNil(tostring(err):find("fly", 1, true), "the refusal names its missing selection")
  local townMap = PokegearApplicationTask.create({ kind = "townMap", parentOwner = "script:map" }, taskCtx)
  Assert.equal(townMap.kind, "townMap", "the view-only map keeps its task vocabulary")
end

function T.tests.save_gate_denies_live_controllers_and_defers_to_later_gates()
  local friends = companion()
  local bundle = composeGear(friends)
  friends.state:registerContact(NEIGHBOR_KEY)
  local idleHost = {
    isActive = function()
      return false
    end,
  }
  local coordinator = FieldSaveCoordinator.new({
    pokegear = bundle,
    pcApplicationHost = idleHost,
    battleCoordinator = {
      activeBattle = function()
        return nil
      end,
      hasLaunch = function()
        return false
      end,
    },
  })
  local host = bundle.scriptHost
  local handle = host:open({
    mode = "call",
    request = { id = "save-1", contact = NEIGHBOR_KEY, direction = "outgoing", kind = "ordinary" },
    parentOwner = "script:save",
  })
  local record, reason = coordinator:capture(false)
  Assert.isNil(record, "an active controller captures nothing")
  Assert.notNil(reason, "the denial names its busy owner")
  host:close(handle)
  local martBusy = {
    pokegear = bundle,
    pcApplicationHost = idleHost,
    pokemonMenu = nil,
    session = {
      player = { motion = "idle" },
      transition = { phase = "idle" },
      mapEntryController = {
        isActive = function()
          return false
        end,
      },
      dialogue = {
        isModal = function()
          return false
        end,
      },
      signpost = {
        isModal = function()
          return false
        end,
      },
      applicationHost = nil,
    },
    martHost = {
      isActive = function()
        return true
      end,
    },
    battleCoordinator = {
      activeBattle = function()
        return nil
      end,
      hasLaunch = function()
        return false
      end,
    },
  }
  local record2, reason2 = FieldSaveCoordinator.new(martBusy):capture(false)
  Assert.isNil(record2, "later gates still refuse after the companion gate passes")
  Assert.notNil(tostring(reason2):find("mart", 1, true), "the later gate keeps its own reason")
end

function T.tests.composition_requires_shared_message_references()
  local ScriptErrors = require("libs.script.src.errors")
  local friends = companion()
  local runtime = {
    pokegearRandom = friends.random,
    pokegearCalendar = friends.calendar,
    presentationDisplay = {
      width = 256,
      height = 192,
      pixelRatio = 1,
      signature = "pokegear-messages-test",
    },
    localClock = {
      nowLocal = function()
        return { year = 2000, month = 1, day = 1, hour = 12, minute = 0, second = 0 }
      end,
    },
    radioMusicIs = function(_, _)
      return false
    end,
  }
  local ok, err = pcall(PokegearComposition.compose, runtime, {
    state = friends.state,
    catalog = friends.catalog,
    assets = assetFamily(friends.catalog),
    clock = runtime.localClock,
    audio = nil,
  })
  Assert.isFalse(ok, "a composition without message references never assembles silently")
  Assert.equal(err.code, ScriptErrors.SCRIPT_SERVICE_MISSING, "the refusal carries its attribution")
  Assert.notNil(tostring(err.message):find("message references", 1, true), "the refusal names its missing owner")
end

function T.tests.composition_rejects_the_unresolved_greeting_sentinel()
  local friends = companion()
  local runtime = {
    pokegearRandom = friends.random,
    pokegearCalendar = friends.calendar,
    presentationDisplay = {
      width = 256,
      height = 192,
      pixelRatio = 1,
      signature = "pokegear-sentinel-test",
    },
    localClock = {
      nowLocal = function()
        return { year = 2000, month = 1, day = 1, hour = 12, minute = 0, second = 0 }
      end,
    },
    radioMusicIs = function(_, _)
      return false
    end,
  }
  local ok = pcall(PokegearComposition.compose, runtime, {
    state = friends.state,
    catalog = friends.catalog,
    assets = assetFamily(friends.catalog),
    clock = runtime.localClock,
    audio = nil,
    messages = { greeting = "phone.greeting.unresolved" },
  })
  Assert.isFalse(ok, "the unresolved sentinel is never installed silently")
end

---@param mapSymbol string
---@param setFlags integer[] field flag identities read as set
---@return table runtime double behind channel selection
local function radioRuntime(mapSymbol, setFlags)
  local set = {}
  for _, id in ipairs(setFlags) do
    set[id] = true
  end
  return {
    session = { currentMap = { mapSymbol = mapSymbol } },
    scripts = {
      worldState = {
        isFlagSet = function(_, id)
          return set[id] == true
        end,
      },
    },
  }
end

---@return table catalog double with region-carrying compiled locations and source-order reception sets
local function regionCatalog()
  return {
    locations = {
      { key = "test.place.pallet", fieldMap = "MAP_PALLET", region = "kanto" },
      { key = "test.place.violet", fieldMap = "MAP_VIOLET", region = "johto" },
    },
    reception = {
      alph = { "MAP_RUINS_OF_ALPH_UNDERGROUND_HALL" },
      mahogany = { "MAP_MAHOGANY" },
      forbidden = { "MAP_UNION" },
    },
  }
end

function T.tests.radio_facts_resolve_region_and_story_flags_from_compiled_data()
  local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
  local flagsByName = FieldScriptSymbols.flagsByName
  local runtime = radioRuntime("MAP_PALLET", { flagsByName.FLAG_RESTORED_POWER, flagsByName.FLAG_GOT_EXPN_CARD })
  local facts = PokegearComposition.radioFacts(runtime, regionCatalog())
  Assert.equal(facts.map.key, "MAP_PALLET", "channel selection names its live map")
  Assert.equal(facts.map.region, "kanto", "the region resolves through the compiled location table")
  Assert.isTrue(facts.flags.powerRestored, "restored power reads its field flag")
  Assert.isTrue(facts.flags.kantoExpansion, "the expansion card reads its field flag")
  Assert.isFalse(facts.flags.hideoutCleared, "an unset hideout flag reads clear")
  Assert.isFalse(facts.flags.rocketTakeover, "an unset takeover flag reads clear")
  local cleared = PokegearComposition.radioFacts(
    radioRuntime("MAP_VIOLET", {
      flagsByName.FLAG_ROCKET_HIDEOUT_CLEARED,
      flagsByName.FLAG_ROCKET_TAKEOVER_ACTIVE,
    }),
    regionCatalog()
  )
  Assert.equal(cleared.map.region, "johto", "the second map resolves its own region")
  Assert.isFalse(cleared.flags.powerRestored, "an unset power flag reads clear")
  Assert.isTrue(cleared.flags.hideoutCleared, "the cleared hideout reads its field flag")
  Assert.isTrue(cleared.flags.rocketTakeover, "the active takeover reads its field flag")
end

function T.tests.radio_facts_refuse_maps_without_compiled_coverage()
  local ok, err = pcall(PokegearComposition.radioFacts, radioRuntime("MAP_UNCOMPILED", {}), regionCatalog())
  Assert.isFalse(ok, "a map without compiled coverage never defaults to Johto")
  Assert.equal(err.code, "FEATURE_UNAVAILABLE", "the refusal carries its attribution")
  Assert.notNil(tostring(err.message):find("MAP_UNCOMPILED", 1, true), "the refusal names its map")
end

function T.tests.radio_facts_resolve_reception_sets_without_a_location_record()
  local RadioReception = require("game.hgss.src.pokegear.RadioReception")
  local forbidden = PokegearComposition.radioFacts(radioRuntime("MAP_UNION", {}), regionCatalog())
  Assert.equal(forbidden.map.key, "MAP_UNION", "the forbidden map names itself")
  Assert.isFalse(forbidden.map.allowsRadio, "the forbidden set closes the radio permission")
  Assert.equal(RadioReception.forContext(forbidden.map, forbidden.flags), "none", "a forbidden map tunes nothing")
  local alph = PokegearComposition.radioFacts(radioRuntime("MAP_RUINS_OF_ALPH_UNDERGROUND_HALL", {}), regionCatalog())
  Assert.isTrue(alph.map.allowsRadio, "a region-less special map keeps its permission")
  Assert.isTrue(alph.map.alph, "the Alph set marks its member")
  Assert.isFalse(alph.map.mahogany, "the Alph member is not a Mahogany member")
  Assert.equal(RadioReception.forContext(alph.map, alph.flags), "alph", "an Alph map tunes its own table")
  local mahogany = PokegearComposition.radioFacts(radioRuntime("MAP_MAHOGANY", {}), regionCatalog())
  Assert.isTrue(mahogany.map.mahogany, "the Mahogany set marks its member")
  Assert.isFalse(mahogany.map.alph, "the Mahogany member is not an Alph member")
  Assert.equal(
    RadioReception.forContext(mahogany.map, mahogany.flags),
    "mahogany",
    "a standing-hideout Mahogany map tunes its own table"
  )
end

function T.tests.radio_facts_reach_every_reception_table_in_production_resolution()
  local RadioReception = require("game.hgss.src.pokegear.RadioReception")
  local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
  local flagsByName = FieldScriptSymbols.flagsByName
  local catalog = regionCatalog()
  local cases = {
    { map = "MAP_UNION", flags = {}, key = "none", why = "a forbidden map tunes nothing" },
    {
      map = "MAP_RUINS_OF_ALPH_UNDERGROUND_HALL",
      flags = {},
      key = "alph",
      why = "an Alph map tunes its own table",
    },
    { map = "MAP_PALLET", flags = {}, key = "none", why = "Kanto stays silent before the restored power" },
    {
      map = "MAP_PALLET",
      flags = { flagsByName.FLAG_RESTORED_POWER },
      key = "kanto",
      why = "a powered Kanto map tunes its table",
    },
    {
      map = "MAP_PALLET",
      flags = { flagsByName.FLAG_RESTORED_POWER, flagsByName.FLAG_GOT_EXPN_CARD },
      key = "kanto-expn",
      why = "an expansion-card Kanto map tunes its table",
    },
    {
      map = "MAP_MAHOGANY",
      flags = {},
      key = "mahogany",
      why = "a standing-hideout Mahogany map tunes its table",
    },
    {
      map = "MAP_MAHOGANY",
      flags = { flagsByName.FLAG_ROCKET_HIDEOUT_CLEARED, flagsByName.FLAG_ROCKET_TAKEOVER_ACTIVE },
      key = "rocket",
      why = "a cleared-hideout takeover tunes its table",
    },
    { map = "MAP_VIOLET", flags = {}, key = "johto", why = "an ordinary Johto map tunes its table" },
  }
  local seen = {}
  for _, case in ipairs(cases) do
    local facts = PokegearComposition.radioFacts(radioRuntime(case.map, case.flags), catalog)
    Assert.equal(RadioReception.forContext(facts.map, facts.flags), case.key, case.why .. " (" .. case.map .. ")")
    seen[case.key] = true
  end
  for _, key in ipairs({ "none", "alph", "kanto", "kanto-expn", "mahogany", "rocket", "johto" }) do
    Assert.isTrue(seen[key] == true, "production resolution reaches the " .. key .. " table")
  end
end

return T
