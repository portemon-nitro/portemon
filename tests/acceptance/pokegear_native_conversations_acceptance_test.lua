-- Native incoming and outgoing Mom conversations run through the composed
-- field phone owner and the user's generated HGSS text assets.

local Assert = require("tests.support.Assert")
local Fixture = require("tests.support.PokegearJourneyFixture")
local LocalClock = require("game.src.LocalClock")
local PhoneRewards = require("game.hgss.src.pokegear.PhoneRewards")
local PokegearSources = require("romdump.src.config.PokegearSources")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local CivilDate = require("libs.hgss.src.field.CivilDate")
local DaycareState = require("libs.hgss.src.save.DaycareState")

local DERIVED_ASSETS = {}
DERIVED_ASSETS[#DERIVED_ASSETS + 1] = "map-data:31"
DERIVED_ASSETS[#DERIVED_ASSETS + 1] = "map-data:47"
DERIVED_ASSETS[#DERIVED_ASSETS + 1] = "map-data:48"
DERIVED_ASSETS[#DERIVED_ASSETS + 1] = "message-bank:730"
DERIVED_ASSETS[#DERIVED_ASSETS + 1] = "message-bank:271"
DERIVED_ASSETS[#DERIVED_ASSETS + 1] = "message-bank:279"
DERIVED_ASSETS[#DERIVED_ASSETS + 1] = "message-bank:280"
DERIVED_ASSETS[#DERIVED_ASSETS + 1] = "message-bank:428"
for _, key in ipairs(Fixture.JOURNEY_ASSETS) do
  DERIVED_ASSETS[#DERIVED_ASSETS + 1] = key
end
for _, bankId in ipairs(PokegearSources.phoneMessageBankIds()) do
  DERIVED_ASSETS[#DERIVED_ASSETS + 1] = "message-bank:" .. tostring(bankId)
end

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = DERIVED_ASSETS,
    tags = { "pokegear" },
  },
  tests = {},
}

local function contactByFamily(catalog, family)
  for _, contact in ipairs(catalog.contacts) do
    if contact.family == family then
      return contact
    end
  end
  error("the native phonebook has a " .. family .. " contact", 0)
end

local function actionEdge(game)
  game.runtime:pressAction()
  game:step()
  game.runtime:releaseAction()
end

local function phoneView(game)
  local application = assert(game.runtime.applicationHost:status().application, "the gear owns the Phone card")
  local child = assert(application.child, "the Phone card publishes its live view")
  return assert(child.view, "the Phone card publishes its detached phone view")
end

local function callThroughPhoneMenu(game, contact)
  local printedPages = {}
  local rows = phoneView(game).list.rows
  local selected = nil
  for index, row in ipairs(rows) do
    if row.contact == contact.key then
      selected = index - 1
      break
    end
  end
  selected = assert(selected, "the registered native caller appears in the Phone list")
  for _ = 1, #rows do
    if phoneView(game).list.selected == selected then
      break
    end
    game.runtime:press("south")
    game:step()
    game.runtime:release("south")
  end
  Assert.equal(phoneView(game).list.selected, selected, "the Phone list selects the requested native caller")
  actionEdge(game)
  actionEdge(game)
  local sawPage = false
  local lastCall = nil
  for _ = 1, 160 do
    local call = phoneView(game).call
    if call == nil then
      break
    end
    lastCall = call
    Assert.equal(call.contact, contact.key, "the active call preserves its selected native contact")
    for _, page in ipairs(call.lines or {}) do
      Assert.isTrue(
        type(page.text) == "string" and page.text ~= "",
        "native phone pages resolve to printable text: "
          .. tostring(page.text)
          .. " tokens="
          .. tostring(type(page.tokens) == "table" and #page.tokens or nil)
      )
      Assert.isFalse(page.text:find("msg.hgss.", 1, true) ~= nil, "a call never displays an unresolved message key")
      printedPages[#printedPages + 1] = page.text
      sawPage = true
    end
    if call.stage == "choice" then
      actionEdge(game)
    elseif call.stage == "hangingUp" then
      game:step()
    else
      actionEdge(game)
    end
  end
  Assert.isTrue(
    sawPage,
    "native caller "
      .. contact.key
      .. " presents at least one resolved conversation page; last stage: "
      .. tostring(lastCall and lastCall.stage)
  )
  Assert.isNil(phoneView(game).call, "the call returns to the contact list after its conversation")
  return printedPages
end

local function continueWithSavedRecord(game, record, firstPublication)
  local runtime = game.runtime
  local store = assert(runtime.saveStore, "the production runtime owns the acceptance save store")
  if firstPublication then
    Assert.isTrue(store:publishFirst(record), "the seeded save publishes through the production store")
  else
    Assert.isTrue(store:save(record), "the updated save publishes through the production store")
  end
  local persisted = assert(store:load(record.saveId), "the production store reloads the saved record")
  game:_disposeRuntime()
  local restoredRuntime = game.harness:_newRuntime(
    persisted,
    game.saveNamespace,
    game.faults,
    game.lifecycle,
    game.fieldOptions,
    false
  )
  game.runtime = restoredRuntime
  game.hosts = restoredRuntime.scriptHosts or {}
  game.runtimeDisposed = false
  game.disposeErr = nil
  game.saveStatus = restoredRuntime.saveStatus
  game:waitForFieldEntry()
  Assert.isTrue(Fixture.settleField(game), "the continued save settles back to an owned field")
  Assert.deepEqual(
    restoredRuntime.daycareState:capture(),
    persisted.daycare,
    "production restore consumes the persisted Day Care owner"
  )
  return restoredRuntime
end

function T.tests.native_mom_gift_ring_completes_without_granting_queued_item()
  local sample = { year = 2024, month = 1, day = 8, hour = 10, minute = 0, second = 0 }
  local clock = LocalClock.new(function()
    return {
      year = sample.year,
      month = sample.month,
      day = sample.day,
      hour = sample.hour,
      minute = sample.minute,
      second = sample.second,
    }
  end)
  Fixture.withGame(Fixture.TOWN, function(game)
    Fixture.compositionGates(game)
    local runtime = game.runtime
    local catalog = assert(runtime.pokegearCatalog, "the field runtime owns the native phone catalog")
    local mom = contactByFamily(catalog, "mother")
    local state = assert(runtime.pokegearState, "the field runtime owns Mom's durable gift queue")
    state:registerContact(mom.key)
    state:setMom({ balance = 0, purchases = {}, gifts = { { item = "POTION", quantity = 1 } } })

    local calls = assert(runtime.incomingCalls, "the field runtime owns native ring policy")
    calls:setTrigger(PhoneRewards.MOM_GIFT_TRIGGER, true)
    sample.minute = sample.minute + 1
    game:advanceUntil("the current Mom gift trigger rings", function()
      return calls:notification() ~= false
    end, 120)
    local notice = assert(calls:notification(), "the actual trigger publishes Mom's incoming ring")
    Assert.equal(notice.contactKey, mom.key, "the actual trigger selects native Mom")

    local handle = calls:accept("acceptance:incoming-mom")
    Assert.isFalse(calls:notification(), "acceptance consumes the ringing opportunity")
    local host = assert(runtime.pokegear.scriptHost, "the field runtime owns the composed call host")
    for _ = 1, 120 do
      if host:result(handle) ~= nil then
        break
      end
      host:step(handle, { { type = "advance" } })
    end
    local incomingResult = assert(host:result(handle), "the accepted native call reaches a terminal result")
    Assert.isNil(incomingResult.error, "the incoming Mom conversation succeeds instead of ending as an error")
    Assert.equal(incomingResult.contact, mom.key, "the terminal result retains the native Mom identity")
    Assert.deepEqual(
      state:readPhone().mom.gifts,
      { { item = "POTION", quantity = 1 } },
      "the call acknowledges dialogue without granting or consuming the queued Bag gift"
    )
    host:close(handle)
    Assert.equal(Fixture.scriptFaults(game), 0, "the composed incoming Mom call finishes without field script faults")
  end, { localClock = clock })
end

function T.tests.after_rival_mom_call_presents_native_savings_dialogue()
  Fixture.withGame(Fixture.TOWN, function(game)
    local runtime = game.runtime
    local catalog = assert(runtime.pokegearCatalog, "the field runtime owns the native phone catalog")
    local mom = contactByFamily(catalog, "mother")
    assert(runtime.pokegearState, "the field runtime owns the registered phonebook")
    local events = assert(runtime.eventState, "the field owns Mom's source story flags")
    events:setFlag(Fixture.FLAGS.FLAG_GAVE_RIVAL_NAME_TO_OFFICER)
    events:setFlag(Fixture.FLAGS.FLAG_TALKED_TO_MOM_AFTER_NAMING_RIVAL)
    events:clearFlag(Fixture.FLAGS.FLAG_SYS_MOMS_SAVINGS)
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })

    local host = assert(runtime.pokegear.scriptHost, "the field runtime owns the composed call host")
    local handle = host:open({
      mode = "call",
      request = {
        id = "acceptance:after-rival-mom",
        contact = mom.key,
        direction = "outgoing",
        kind = "ordinary",
      },
      parentOwner = "acceptance-mom-after-rival",
    })
    for _ = 1, 120 do
      if host:result(handle) ~= nil then
        break
      end
      host:step(handle, { { type = "confirm" } })
    end
    local result = assert(host:result(handle), "the native Mom choice reaches a terminal result")
    Assert.isNil(
      result.error,
      "the native Mom dialogue resolves its generated text: "
        .. tostring(type(result.error) == "table" and result.error.message or result.error)
    )
    Assert.isTrue(
      events:isFlagSet(Fixture.FLAGS.FLAG_SYS_MOMS_SAVINGS),
      "confirming the native choice updates Mom's source savings flag"
    )
    Assert.equal(Fixture.scriptFaults(game), 0, "the composed after-rival call finishes without field script faults")
    host:close(handle)
  end)
end

function T.tests.irwin_incoming_story_consumes_trigger_and_marks_source_one_shot()
  Fixture.withGame(Fixture.TOWN, function(game)
    local runtime = game.runtime
    local catalog = assert(runtime.pokegearCatalog, "the field runtime owns the native phone catalog")
    local irwin = contactByFamily(catalog, "irwin")
    local state = assert(runtime.pokegearState, "the field runtime owns registered phone contacts")
    state:registerContact(irwin.key)
    local profile = assert(runtime.playerData.profile, "the runtime owns the native badge profile")
    profile.badges = 0x2004 -- Marsh and Plain badges, in source badge order.
    local flags = assert(runtime.eventState, "the field runtime owns native story flags")
    flags:setFlag(FieldScriptSymbols.flagsByName.FLAG_UNK_998)
    local host = assert(runtime.pokegear.scriptHost, "the field runtime owns the composed call host")
    local handle = host:open({
      mode = "call",
      request = {
        id = "acceptance:irwin-incoming-story",
        contact = irwin.key,
        direction = "incoming",
        kind = "incoming",
      },
      parentOwner = "acceptance-irwin-story",
    })
    for _ = 1, 120 do
      if host:result(handle) ~= nil then
        break
      end
      host:step(handle, { { type = "confirm" } })
    end
    local result = assert(host:result(handle), "the incoming Irwin source page reaches a terminal result")
    Assert.isNil(result.error, "the incoming Irwin source page resolves successfully")
    Assert.isFalse(flags:isFlagSet(FieldScriptSymbols.flagsByName.FLAG_UNK_998), "Irwin consumes the source trigger")
    Assert.isTrue(flags:isFlagSet(FieldScriptSymbols.flagsByName.FLAG_UNK_9A3), "Irwin records the Marsh one-shot")
    host:close(handle)
  end)
end

function T.tests.kenji_eligible_remote_call_persists_the_source_active_and_seeking_effects()
  local clock = LocalClock.new(function()
    return { year = 2024, month = 1, day = 8, hour = 12, minute = 0, second = 0 }
  end)
  Fixture.withGame(Fixture.TOWN, function(game)
    local runtime = game.runtime
    local catalog = assert(runtime.pokegearCatalog, "the field runtime owns the compiled caller records")
    local kenji = contactByFamily(catalog, "kenji")
    local session = assert(runtime.session, "the field runtime owns the current map section")
    Assert.isFalse(
      kenji.map == session.currentMap.mapSectionNativeId,
      "the Kenji effect scenario calls from a map outside his phonebook entry"
    )
    Assert.equal(runtime.localClock:nowLocal().hour, 12, "the Kenji effect scenario uses daytime")
    local state = assert(runtime.pokegearState, "the field runtime owns Kenji's saved caller facts")
    state:registerContact(kenji.key)
    state:setKenji({ waitDays = 0, active = false })
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })

    local host = assert(runtime.pokegear.scriptHost, "the field runtime owns the composed call host")
    local handle = host:open({
      mode = "call",
      request = {
        id = "acceptance:kenji-eligible",
        contact = kenji.key,
        direction = "outgoing",
        kind = "ordinary",
      },
      parentOwner = "acceptance-kenji-source-call",
    })
    Assert.isNil(host:result(handle), "an eligible remote Kenji call takes the live conversation path")
    for _ = 1, 20 do
      if state:readPhone().kenji.active then
        break
      end
      host:step(handle, { { type = "confirm" } })
    end
    local savedKenji = state:readPhone().kenji
    Assert.equal(savedKenji.waitDays, 0, "the source wait remains unchanged by the call offer")
    Assert.isTrue(savedKenji.active, "an eligible daytime call persists Kenji's active flag")
    local seeking = state:queryRematch(kenji.key)
    Assert.notNil(seeking, "the source call marks this contact as seeking")
    Assert.equal(seeking.stage, 1, "the native seeking effect uses the existing rematch owner")
    for _ = 1, 120 do
      if host:result(handle) ~= nil then
        break
      end
      host:step(handle, { { type = "confirm" } })
    end
    local result = assert(host:result(handle), "the native Kenji conversation reaches a terminal result")
    Assert.isNil(result.error, "the native Kenji conversation resolves its source-selected message")
    host:close(handle)
  end, { localClock = clock })
end

function T.tests.joey_call_presents_its_native_generic_program()
  Fixture.withGame(Fixture.TOWN, function(game)
    local catalog = assert(game.runtime.pokegearCatalog, "the field runtime owns the compiled caller records")
    local joey = nil
    for _, contact in ipairs(catalog.contacts) do
      if contact.id == 10 then
        joey = contact
      end
    end
    joey = assert(joey, "native phonebook slot ten is Joey")
    Assert.equal(joey.family, "trainer", "Joey uses the native generic trainer family")
    local state = assert(game.runtime.pokegearState, "the field runtime owns the registered callers")
    state:registerContact(joey.key)
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })

    Fixture.openGearThroughMenu(game)
    game:advanceUntil("the Phone opening transition completes", function()
      local application = game.runtime.applicationHost:status().application
      return application ~= nil and application.transition == nil
    end, 40)
    local pages = callThroughPhoneMenu(game, joey)
    local text = table.concat(pages, "\n")
    Assert.isTrue(text:find("moves", 1, true) ~= nil, "Joey's selected generic definition resolves its native phrase")
    Assert.isFalse(text:find("STRVAR_1", 1, true) ~= nil, "generic type-one trainer and encounter names resolve in the real call")
    Assert.isTrue(text:find("All right. Later!", 1, true) ~= nil, "Joey's source conversation reaches its closing page")
    Assert.equal(Fixture.scriptFaults(game), 0, "Joey's native call finishes without field script faults")
  end)
end

function T.tests.daycare_native_calls_render_saved_growth_egg_and_compatibility_facts()
  Fixture.withGame(Fixture.TOWN, function(game)
    local runtime = game.runtime
    local catalog = assert(runtime.pokegearCatalog)
    local lady = nil
    local man = nil
    for _, contact in ipairs(catalog.contacts) do
      if contact.family == "daycare" then
        if contact.id == 7 then lady = contact end
        if contact.id == 6 then man = contact end
      end
    end
    lady = assert(lady, "the native Day Care lady is in the phonebook")
    man = assert(man, "the native Day Care man is in the phonebook")
    local bucket = {
      schema = DaycareState.SCHEMA,
      mons = {
        { species = "CHIKORITA", nickname = "SPROUT", personality = 0, experience = 0, steps = 100000, otId = 11 },
        { species = "CYNDAQUIL", nickname = "EMBER", personality = 255, experience = 0, steps = 100000, otId = 22 },
      },
      eggPid = 0,
    }
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })
    local captured = assert(runtime:captureGameSave(), "the production field capture carries the Day Care owner")
    captured.daycare = bucket
    runtime = continueWithSavedRecord(game, captured, true)
    Assert.deepEqual(runtime.daycareState:capture(), bucket, "the continued runtime preserves both source Day Care slots")
    runtime.pokegearState:registerContact(lady.key)
    runtime.pokegearState:registerContact(man.key)

    Fixture.openGearThroughMenu(game)
    game:advanceUntil("the Phone opening transition completes", function()
      local application = runtime.applicationHost:status().application
      return application ~= nil and application.transition == nil
    end, 40)
    local ladyText = table.concat(callThroughPhoneMenu(game, lady), "\n")
    Assert.isTrue(ladyText:find("SPROUT", 1, true) ~= nil, "Day Care lady text receives the saved nickname")
    Assert.isTrue(ladyText:find("EMBER", 1, true) ~= nil, "each occupied Day Care slot keeps its order")
    Assert.isFalse(ladyText:find("STRVAR_1", 1, true) ~= nil, "Day Care growth substitutions are resolved")

    local manText = table.concat(callThroughPhoneMenu(game, man), "\n")
    Assert.isTrue(manText:find("SPROUT", 1, true) ~= nil, "Day Care man dialogue names the first saved mon")
    Assert.isTrue(manText:find("EMBER", 1, true) ~= nil, "Day Care man dialogue names the second saved mon")
    Assert.isFalse(manText:find("STRVAR_1", 1, true) ~= nil, "Day Care compatibility substitution is resolved")

    Fixture.closeGearThroughMenu(game)
    local eggRecord = assert(runtime:captureGameSave(), "the field captures the continued phone save")
    eggRecord.daycare = {
      schema = DaycareState.SCHEMA,
      mons = bucket.mons,
      eggPid = 0x12345678,
    }
    runtime = continueWithSavedRecord(game, eggRecord, false)
    Fixture.openGearThroughMenu(game)
    game:advanceUntil("the continued Phone opening transition completes", function()
      local application = runtime.applicationHost:status().application
      return application ~= nil and application.transition == nil
    end, 40)
    local eggText = table.concat(callThroughPhoneMenu(game, man), "\n")
    Assert.isTrue(eggText:lower():find("egg", 1, true) ~= nil, "Day Care man presents the saved egg branch")
    Assert.equal(Fixture.scriptFaults(game), 0, "Day Care native calls finish without field script faults")
  end)
end

function T.tests.baoba_incoming_page_renders_saved_safari_area_names()
  Fixture.withGame(Fixture.TOWN, function(game)
    local runtime = game.runtime
    local contact = contactByFamily(runtime.pokegearCatalog, "baoba")
    local areas = { 0, 11, 4 }
    runtime.pokegearState:registerContact(contact.key)
    runtime.pokegearState:setSafariAreas(areas)
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })

    local provider = runtime.messageProvider
    local originalFormat = provider.format
    local formattedTexts = {}
    local safariNames = {}
    provider.format = function(self, template, context, resolvers)
      local formatted = originalFormat(self, template, context, resolvers)
      formattedTexts[#formattedTexts + 1] = formatted.text
      if template.bankId == PokegearSources.safariAreaMessageBank then
        safariNames[template.messageId] = formatted.text
      end
      return formatted
    end
    local host = runtime.pokegear.scriptHost
    local handle = host:open({
      mode = "call",
      request = {
        id = "acceptance:baoba-arrangement",
        contact = contact.key,
        direction = "incoming",
        kind = "incoming",
      },
      parentOwner = "acceptance-baoba-arrangement",
    })
    for _ = 1, 120 do
      if host:result(handle) ~= nil then break end
      host:step(handle, { { type = "confirm" } })
    end
    local result = assert(host:result(handle), "Baoba's incoming native program reaches a terminal result")
    Assert.isNil(result.error, "Baoba's arrangement page resolves bank 428 area names")
    local firstArea = safariNames[0]
    local secondArea = safariNames[11]
    local thirdArea = safariNames[4]
    local baobaPage = formattedTexts[#formattedTexts]
    Assert.isTrue(type(firstArea) == "string" and firstArea ~= "", "the first area name resolves from its native entry")
    Assert.isTrue(type(secondArea) == "string" and secondArea ~= "", "the second area name resolves from its native entry")
    Assert.isTrue(type(thirdArea) == "string" and thirdArea ~= "", "the third area name resolves from its native entry")
    Assert.isTrue(
      baobaPage:find(firstArea, 1, true) ~= nil,
      "Baoba's rendered page includes the first saved area: page="
        .. tostring(baobaPage)
        .. " area="
        .. tostring(firstArea)
        .. " formatted="
        .. table.concat(formattedTexts, " | ")
    )
    Assert.isTrue(baobaPage:find(secondArea, 1, true) ~= nil, "Baoba's rendered page includes the second saved area")
    Assert.isTrue(baobaPage:find(thirdArea, 1, true) ~= nil, "Baoba's rendered page includes the third saved area")
    Assert.isFalse(baobaPage:find("STRVAR_1", 1, true) ~= nil, "Baoba's area substitutions are resolved")
    host:close(handle)
  end)
end

function T.tests.joey_scheduled_rematch_call_persists_its_native_seeking_effect()
  local sample = { year = 2024, month = 1, day = 1, hour = 12, minute = 0, second = 0 }
  local clock = LocalClock.new(function()
    return {
      year = sample.year,
      month = sample.month,
      day = sample.day,
      hour = sample.hour,
      minute = sample.minute,
      second = sample.second,
    }
  end)
  Fixture.withGame(Fixture.TOWN, function(game)
    local runtime = game.runtime
    local catalog = assert(runtime.pokegearCatalog, "the field runtime owns the compiled caller records")
    local joey = nil
    for _, contact in ipairs(catalog.contacts) do
      if contact.id == 10 then
        joey = contact
      end
    end
    joey = assert(joey, "native phonebook slot ten is Joey")
    local _, weekday = CivilDate.parts(sample)
    while weekday ~= joey.rematchWeekday do
      sample.day = sample.day + 1
      if sample.day > 7 then
        sample.day = 1
      end
      _, weekday = CivilDate.parts(sample)
    end
    sample.hour = joey.rematchTime == 0 and 5 or joey.rematchTime == 2 and 21 or 12
    local session = assert(runtime.session, "the field runtime owns the current map section")
    Assert.isFalse(
      joey.map == session.currentMap.mapSectionNativeId,
      "the rematch scenario calls Joey from outside his phonebook map section"
    )
    local state = assert(runtime.pokegearState, "the field runtime owns persisted phone contacts")
    state:registerContact(joey.key)
    runtime.eventState:setFlag(FieldScriptSymbols.flagsByName.FLAG_BEAT_RADIO_TOWER_ROCKETS)
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })

    Fixture.openGearThroughMenu(game)
    game:advanceUntil("the Phone opening transition completes", function()
      local application = runtime.applicationHost:status().application
      return application ~= nil and application.transition == nil
    end, 40)
    local pages = callThroughPhoneMenu(game, joey)
    local dialogue = table.concat(pages, "\n")
    Assert.isTrue(dialogue:find("where I’ll be.", 1, true) ~= nil, "the selected rematch page resolves Joey's caller landmark")
    Assert.isFalse(dialogue:find("STRVAR_1", 1, true) ~= nil, "the rematch page contains no unresolved native substitution")
    local seeking = state:queryRematch(joey.key)
    Assert.notNil(seeking, "the selected Joey definition commits through the existing rematch owner")
    Assert.equal(seeking.stage, 1, "the source rematch definition marks Joey as seeking")
  end, { localClock = clock })
end

function T.tests.native_gym_invitation_uses_its_source_window_and_persists_stage()
  local sample = { year = 2024, month = 1, day = 1, hour = 12, minute = 0, second = 0 }
  local clock = LocalClock.new(function()
    return {
      year = sample.year,
      month = sample.month,
      day = sample.day,
      hour = sample.hour,
      minute = sample.minute,
      second = sample.second,
    }
  end)
  Fixture.withGame(Fixture.TOWN, function(game)
    local runtime = game.runtime
    local catalog = assert(runtime.pokegearCatalog, "the field runtime owns native gym contacts")
    local leader = contactByFamily(catalog, "gym")
    Assert.isTrue(leader.rematchWeekday >= 0 and leader.rematchWeekday <= 6, "the Gym window uses its source weekday")
    Assert.isTrue(leader.rematchTime >= 0 and leader.rematchTime <= 2, "the Gym window uses its source time")
    local _, weekday = CivilDate.parts(sample)
    for _ = 1, 7 do
      if weekday == leader.rematchWeekday then
        break
      end
      sample.day = sample.day + 1
      _, weekday = CivilDate.parts(sample)
    end
    Assert.equal(weekday, leader.rematchWeekday, "the deterministic clock reaches the native Gym weekday")
    sample.hour = ({ [0] = 5, [1] = 12, [2] = 21 })[leader.rematchTime]

    local session = assert(runtime.session, "the field session owns the current map section")
    Assert.isFalse(
      leader.map == session.currentMap.mapSectionNativeId,
      "the accepted Gym call starts outside the source contact's map section"
    )
    local state = assert(runtime.pokegearState, "the field runtime owns durable rematch invitations")
    state:registerContact(leader.key)
    local profile = assert(runtime.playerData.profile, "the runtime owns the native badge profile")
    profile.badges = 0xFFFF
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })

    Fixture.openGearThroughMenu(game)
    game:advanceUntil("the Phone opening transition completes", function()
      local application = runtime.applicationHost:status().application
      return application ~= nil and application.transition == nil
    end, 40)
    local pages = callThroughPhoneMenu(game, leader)
    Assert.isTrue(#pages > 0, "the Gym contact prints its native invitation dialogue")
    local application = assert(runtime.applicationHost:status().application, "the Phone card remains open")
    local card = assert(application.child, "the Phone card publishes its status")
    Assert.isNil(card.callError, "the source-window Gym invitation completes without a call error")
    local invitation = assert(state:queryRematch(leader.key), "the accepted Gym invitation persists in phone state")
    Assert.equal(invitation.stage, 1, "the source invitation starts the native rematch stage")
    Assert.equal(Fixture.scriptFaults(game), 0, "the production-composed Gym call finishes without script faults")
  end, { localClock = clock })
end

function T.tests.friend_native_outgoing_call_resolves_its_map_follow_up()
  Fixture.withGame(Fixture.TOWN, function(game)
    local runtime = game.runtime
    local catalog = assert(runtime.pokegearCatalog, "the field runtime owns the compiled phone catalog")
    local friend = contactByFamily(catalog, "friend")
    local currentMap = assert(runtime.session.currentMap, "the field session owns the current native map")
    local currentMapPhrase = nil
    for _, phrase in ipairs(catalog.friendMapPhrases) do
      if phrase.mapId == currentMap.mapId then
        currentMapPhrase = phrase
        break
      end
    end
    Assert.notNil(currentMapPhrase, "the current native map resolves through Friend's compiled source phrase table")
    local state = assert(runtime.pokegearState, "the field runtime owns registered callers")
    state:registerContact(friend.key)
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })

    Fixture.openGearThroughMenu(game)
    game:advanceUntil("the Phone opening transition completes", function()
      local application = runtime.applicationHost:status().application
      return application ~= nil and application.transition == nil
    end, 40)
    local pages = callThroughPhoneMenu(game, friend)
    local text = table.concat(pages, "\n")
    Assert.isTrue(#pages >= 2, "Friend's native outgoing call includes its map or topic follow-up")
    Assert.isFalse(text:find("STRVAR_1", 1, true) ~= nil, "Friend's source map phrase resolves through the native catalog")
    Assert.equal(Fixture.scriptFaults(game), 0, "Friend's source follow-up completes without field script faults")

    runtime.eventState:setFlag(FieldScriptSymbols.flagsByName.FLAG_SYS_FLYPOINT_PALLET)
    local host = assert(runtime.pokegear.scriptHost, "the field runtime owns the composed incoming call host")
    local handle = host:open({
      mode = "call",
      request = {
        id = "acceptance:friend-incoming-follow-up",
        contact = friend.key,
        direction = "incoming",
        kind = "incoming",
      },
      parentOwner = "acceptance-friend-incoming",
    })
    local incomingPages = {}
    for _ = 1, 120 do
      if host:result(handle) ~= nil then
        break
      end
      local active = assert(host._active, "the incoming call owns the foreground child")
      local controller = assert(active.controller, "the foreground child is the composed phone controller")
      local view = controller:status().view.call
      if type(view) == "table" and type(view.lines) == "table" then
        for _, page in ipairs(view.lines) do
          incomingPages[#incomingPages + 1] = page.text
        end
      end
      host:step(handle, { { type = "advance" } })
    end
    local result = assert(host:result(handle), "Friend's incoming source program reaches a terminal result")
    Assert.isNil(result.error, "Friend's incoming map/topic branch resolves successfully")
    Assert.equal(result.contact, friend.key, "Friend's incoming call retains its catalog identity")
    Assert.isTrue(#incomingPages >= 2, "Friend's incoming type-11 program renders its response page")
    Assert.isFalse(
      table.concat(incomingPages, "\n"):find("STRVAR_1", 1, true) ~= nil,
      "Friend's incoming response resolves against the compiled map and flypoint table"
    )
    host:close(handle)
  end)
end

function T.tests.elm_scripted_intro_zero_resolves_through_the_composed_call_host()
  Fixture.withGame(Fixture.TOWN, function(game)
    local runtime = game.runtime
    local catalog = assert(runtime.pokegearCatalog, "the field runtime owns the compiled caller records")
    local elm = contactByFamily(catalog, "elm")
    local state = assert(runtime.pokegearState, "the field runtime owns registered callers")
    state:registerContact(elm.key)
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })
    local host = assert(runtime.pokegear.scriptHost, "the field runtime owns the composed call host")
    local handle = host:open({
      mode = "call",
      request = {
        id = "acceptance:elm-scripted-intro-zero",
        contact = elm.key,
        direction = "incoming",
        kind = "predefined",
        scriptedCallType = 2,
        predefinedScriptId = 0,
      },
      parentOwner = "acceptance-elm-scripted-intro",
    })
    local pages = {}
    for _ = 1, 120 do
      if host:result(handle) ~= nil then
        break
      end
      local active = assert(host._active, "the accepted call owns the host's foreground child")
      local controller = assert(active.controller, "the foreground child is the composed PhoneController")
      local view = controller:status().view.call
      if type(view) == "table" and type(view.lines) == "table" then
        for _, page in ipairs(view.lines) do
          pages[#pages + 1] = page.text
        end
      end
      host:step(handle, { { type = "advance" } })
    end
    local result = assert(host:result(handle), "Elm's predefined intro reaches a terminal result")
    Assert.isNil(result.error, "Elm's index-zero source intro resolves without an error")
    Assert.equal(result.contact, elm.key, "the composed call retains Elm's native contact identity")
    local dialogue = table.concat(pages, "\n")
    Assert.isTrue(dialogue ~= "", "the generated Elm text bank supplies the predefined intro page")
    Assert.isFalse(dialogue:find("STRVAR_1", 1, true) ~= nil, "the predefined intro has no unresolved substitutions")
    host:close(handle)
  end)
end

function T.tests.kurt_remote_call_uses_source_apricorn_order_pages()
  Fixture.withGame(Fixture.TOWN, function(game)
    local runtime = game.runtime
    local catalog = assert(runtime.pokegearCatalog, "the field runtime owns the compiled caller records")
    local kurt = contactByFamily(catalog, "kurt")
    local state = assert(runtime.pokegearState, "the field runtime owns registered callers")
    state:registerContact(kurt.key)
    local mart = assert(runtime.martService, "the field runtime owns Kurt's pending Apricorn order")
    Assert.isTrue(mart:tryGiveApricorn("RED_APRICORN", 1), "the test stages one source Apricorn")
    Assert.isTrue(mart:submitKurt("RED_APRICORN", 1), "Kurt accepts the source Apricorn order")
    runtime.eventState:setFlag(FieldScriptSymbols.flagsByName.FLAG_UNK_127)
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })

    Fixture.openGearThroughMenu(game)
    game:advanceUntil("the Phone opening transition completes", function()
      local application = runtime.applicationHost:status().application
      return application ~= nil and application.transition == nil
    end, 40)
    local pages = callThroughPhoneMenu(game, kurt)
    local text = table.concat(pages, "\n")
    Assert.isTrue(
      text:find("My old man had something he", 1, true) ~= nil,
      "FLAG_UNK_127 selects Kurt's repeat-caller opening"
    )
    Assert.isTrue(
      text:find("turned all the Apricorns", 1, true) ~= nil,
      "the pending source order selects Kurt's completion page"
    )
    Assert.isTrue(text:find("Level Ball", 1, true) ~= nil, "the source Apricorn maps to its compiled Ball name")
    Assert.equal(Fixture.scriptFaults(game), 0, "Kurt's native order call finishes without field script faults")
  end)
end

function T.tests.oak_call_presents_its_native_special_program()
  Fixture.withGame(Fixture.TOWN, function(game)
    local catalog = assert(game.runtime.pokegearCatalog, "the field runtime owns the compiled caller records")
    local oak = nil
    for _, contact in ipairs(catalog.contacts) do
      if contact.id == 2 then
        oak = contact
        break
      end
    end
    oak = assert(oak, "native phonebook slot two is Oak")
    Assert.equal(oak.family, "oak", "Oak uses his dedicated native phone family")
    local state = assert(game.runtime.pokegearState, "the field runtime owns the registered caller")
    state:registerContact(oak.key)
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })

    Fixture.openGearThroughMenu(game)
    game:advanceUntil("the Phone opening transition completes", function()
      local application = game.runtime.applicationHost:status().application
      return application ~= nil and application.transition == nil
    end, 40)
    callThroughPhoneMenu(game, oak)
    Assert.equal(Fixture.scriptFaults(game), 0, "Oak's native call finishes without field script faults")
  end)
end

function T.tests.compiled_nontrainer_contacts_have_successful_native_outgoing_calls()
  Fixture.withGame(Fixture.TOWN, function(game)
    local runtime = game.runtime
    local catalog = assert(runtime.pokegearCatalog, "the field runtime owns all compiled native contacts")
    local state = assert(runtime.pokegearState, "the field runtime owns registered phone contacts")
    local host = assert(runtime.pokegear.scriptHost, "the field runtime owns the composed call host")
    local contacts = {}
    for _, contact in ipairs(catalog.contacts) do
      if contact.family ~= "trainer" then
        contacts[#contacts + 1] = contact
      end
    end
    for _, contact in ipairs(contacts) do
      state:registerContact(contact.key)
    end
    for _, contact in ipairs(contacts) do
      local ok, handle = pcall(host.open, host, {
        mode = "call",
        request = {
          id = "acceptance-native:" .. contact.key,
          contact = contact.key,
          direction = "outgoing",
          kind = "ordinary",
        },
        parentOwner = "acceptance-native-phone-matrix",
      })
      if not ok then
        local failure = handle
        local detail = type(failure) == "table" and failure.message or failure
        error("native outgoing " .. contact.key .. " failed to open: " .. tostring(detail), 0)
      end
      for _ = 1, 120 do
        if host:result(handle) ~= nil then
          break
        end
        host:step(handle, { { type = "confirm" } })
      end
      local result = host:result(handle)
      Assert.notNil(
        result,
        "native outgoing " .. contact.family .. " contact " .. contact.key .. " reaches a terminal outcome"
      )
      result = assert(result)
      Assert.isNil(
        result.error,
        "native outgoing "
          .. contact.family
          .. " contact "
          .. contact.key
          .. " completes instead of falling through: "
          .. tostring(type(result.error) == "table" and (result.error.message or result.error.code) or result.error)
      )
      host:close(handle)
    end
  end)
end

function T.tests.unavailable_native_text_is_not_reported_as_success()
  Fixture.withGame(Fixture.TOWN, function(game)
    local runtime = game.runtime
    local catalog = assert(runtime.pokegearCatalog, "the field runtime owns the compiled native definitions")
    local mom = contactByFamily(catalog, "mother")
    local state = assert(runtime.pokegearState, "the field runtime owns Mom's phone state")
    state:registerContact(mom.key)

    local wrongBank = nil
    for _, bankId in ipairs(PokegearSources.phoneMessageBankIds()) do
      if bankId ~= mom.messageBank then
        wrongBank = bankId
        break
      end
    end
    local bank = assert(wrongBank, "the source catalog includes a distinct caller bank")
    for _, scriptId in ipairs({ 23, 25, 26 }) do
      local definition =
        assert(catalog.callDefinitions[scriptId], "Mom's source selector can choose a numeric definition")
      definition.male.bank = bank
      definition.female.bank = bank
    end
    local events = assert(runtime.eventState, "the field owns the source story flags")
    events:clearFlag(FieldScriptSymbols.flagsByName.FLAG_GAVE_RIVAL_NAME_TO_OFFICER)
    events:clearFlag(FieldScriptSymbols.flagsByName.FLAG_TALKED_TO_MOM_AFTER_NAMING_RIVAL)

    local before = state:readPhone()
    local host = assert(runtime.pokegear.scriptHost, "the field runtime owns the composed script host")
    local handle = host:open({
      mode = "call",
      request = { id = "acceptance-missing-native-text", contact = mom.key, direction = "outgoing", kind = "ordinary" },
      parentOwner = "acceptance-field-script",
    })
    for _ = 1, 120 do
      if host:result(handle) ~= nil then
        break
      end
      host:step(handle, { { type = "advance" } })
    end
    local result = assert(host:result(handle), "the malformed native message reaches a terminal host outcome")
    Assert.notNil(result.error, "a wrong-bank native definition remains an attributed error")
    Assert.isFalse(result.ready == true, "an unavailable message cannot appear ready or successful")
    Assert.deepEqual(state:readPhone(), before, "a missing native page applies no phone-state effect")
    host:close(handle)
  end)
end

function T.tests.unavailable_native_text_does_not_acknowledge_an_incoming_ring()
  local sample = { year = 2024, month = 1, day = 8, hour = 10, minute = 0, second = 0 }
  local clock = LocalClock.new(function()
    return {
      year = sample.year,
      month = sample.month,
      day = sample.day,
      hour = sample.hour,
      minute = sample.minute,
      second = sample.second,
    }
  end)
  Fixture.withGame(Fixture.TOWN, function(game)
    local runtime = game.runtime
    local catalog = assert(runtime.pokegearCatalog, "the field runtime owns the compiled native definitions")
    local mom = contactByFamily(catalog, "mother")
    local state = assert(runtime.pokegearState, "the field runtime owns Mom's trigger state")
    state:registerContact(mom.key)
    local wrongBank = nil
    for _, bankId in ipairs(PokegearSources.phoneMessageBankIds()) do
      if bankId ~= mom.messageBank then
        wrongBank = bankId
        break
      end
    end
    local bank = assert(wrongBank, "the source catalog includes a distinct caller bank")
    for _, definition in pairs(catalog.callDefinitions) do
      definition.male.bank = bank
      definition.female.bank = bank
    end

    local calls = assert(runtime.incomingCalls, "the field runtime owns native ring policy")
    calls:setTrigger(PhoneRewards.MOM_GIFT_TRIGGER, true)
    sample.minute = sample.minute + 1
    game:advanceUntil("the current Mom gift trigger rings", function()
      return calls:notification() ~= false
    end, 120)
    assert(calls:notification(), "the actual source trigger publishes Mom's incoming ring")
    local handle = assert(calls:accept("acceptance:missing-text-incoming"), "the ring enters the composed call host")
    local host = assert(runtime.pokegear.scriptHost, "the field runtime owns the composed call host")
    for _ = 1, 120 do
      if host:result(handle) ~= nil then
        break
      end
      host:step(handle, { { type = "advance" } })
    end
    local result = assert(host:result(handle), "the missing-text incoming call reaches a terminal host outcome")
    Assert.notNil(result.error, "an incoming call without native text remains an attributed failure")
    Assert.isFalse(result.ready == true, "an unavailable incoming page cannot report successful readiness")
    Assert.isTrue(
      state:readPhone().triggers[PhoneRewards.MOM_GIFT_TRIGGER] == true,
      "a failed native incoming call does not acknowledge or consume its trigger"
    )
    host:close(handle)
  end, { localClock = clock })
end

return T
