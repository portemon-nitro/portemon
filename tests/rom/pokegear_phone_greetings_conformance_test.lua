-- Phone greeting references against the owned dump: every native contact
-- carries its source message bank beside its phone-script selector, every
-- referenced bank is demandable through the existing bank pipeline, every
-- selected native script resolves both gendered lines, and one real outgoing call plus one real scripted 430/431
-- call complete end-to-end with those references. Structural facts and
-- bank/entry/token identities only; no retail message text is asserted
-- or printed. A missing dump reports a skip, never a pass, through the
-- declared dump capability.

local Assert = require("tests.support.Assert")
local RomSuite = require("tests.rom.support.RomSuite")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
local PokegearSources = require("romdump.src.config.PokegearSources")
local BinaryReader = require("libs.codec.src.BinaryReader")

local T = {}

local MOM_FAMILY = "mother"
local ELM_FAMILY = "elm"

---@param romFs table<string, unknown>
---@param versionId string
---@return table<string, unknown> the compiled contact catalog
local function compileCatalog(romFs, versionId)
  local loaded, PokegearAssetCompiler = pcall(require, "romdump.src.digest.ui.PokegearAssetCompiler")
  Assert.isTrue(loaded, "the pokegear family compiler must be published before greetings can be proven")
  assert(type(PokegearAssetCompiler) == "table", "the family compiler loads above")
  local bundle = PokegearAssetCompiler.compile(romFs, versionId)
  local compiled = assert(bundle, versionId .. " must compile the pokegear family")
  return assert(compiled.manifest.catalog, versionId .. " must publish its contact catalog")
end

---@param catalog table<string, unknown>
---@param family string
---@return table<string, unknown> the unique compiled contact in the requested family
local function contactInFamily(catalog, family)
  local found = nil
  for _, record in ipairs(assert(catalog.contacts, "the phone catalog carries native contacts")) do
    local contact = record --[[@as table<string, unknown>]]
    if contact.family == family then
      assert(found == nil, "the source phone catalog has one " .. family .. " contact")
      found = contact
    end
  end
  return assert(found, "the source phone catalog has a " .. family .. " contact")
end

-- Builds the shared greeting references exactly the way the field runtime
-- does: one msg.hgss identity per native contact from that contact's
-- message bank and greeting number, with the first catalogued caller's
-- real reference as the shared lease token. Production owner:
-- FieldRuntime._composePokegearFeature.
---@param catalog table<string, unknown>
---@return table<string, unknown>
local function greetingMessages(catalog, versionId)
  local messages = {}
  local provider = assert(FieldMessageProvider.new(CacheFs.forVersion(versionId)))
  local resolvers = {}
  local firstRef = nil
  local byKey = {}
  for _, record in ipairs(assert(catalog.contacts, "greeting references read the compiled contacts")) do
    local contact = record --[[@as table<string, unknown>]]
    byKey[
      contact.key --[[@as string]]
    ] = contact
    local ref = string.format("msg.hgss.%d.%d", contact.messageBank, contact.greeting)
    messages[
      contact.key --[[@as string]]
    ] = ref
    if firstRef == nil then
      firstRef = ref
    end
  end
  messages.greeting = assert(firstRef, "greeting references need at least one compiled contact")
  local function resolveMessage(bankId, entry)
    assert(provider:acquireBank(bankId), "the phone message bank is available")
    local template = assert(provider:get(bankId, entry), "the phone message entry is available")
    local formatted = provider:format(template, { playerName = "GOLD" }, resolvers)
    provider:releaseBank(bankId)
    return formatted
  end
  local function resolveName(_, key)
    local contact = assert(byKey[key], "caller names resolve through the compiled contacts")
    return resolveMessage(contact.name.bank, contact.name.entry).text
  end
  local function resolveClass(_, key)
    local contact = assert(byKey[key], "caller classes resolve through the compiled contacts")
    if contact.class.kind == "blank" then
      return ""
    end
    return resolveMessage(contact.class.bank, contact.class.entry).text
  end
  local function resolveLine(_, key, scriptId)
    local contact = assert(byKey[key], "caller dialogue resolves through the compiled contacts")
    local definition = assert(catalog.callDefinitions[scriptId], "caller dialogue has a native definition")
    assert(definition.male.bank == contact.messageBank, "the selected script belongs to its caller bank")
    return resolveMessage(definition.male.bank, definition.male.entry)
  end
  messages.resolveName = resolveName
  messages.resolveClass = resolveClass
  messages.resolveLine = resolveLine
  local function dispose()
    provider:dispose()
  end
  messages.dispose = dispose
  return messages
end

---@param version string
---@return table<string, unknown> font definition
local function fontDef(version)
  local def = assert(CacheFs.forVersion(version):loadLua("data/generated/field/font/font-0.lua"))
  return def --[[@as table<string, unknown>]]
end

---@param def table<string, unknown>
---@return table<integer, fun(): table> player-name resolvers behind greeting substitutions
local function nameResolvers(def)
  local resolvers = {}
  for _, control in ipairs({ 0x0100, 0x0101, 0x0102, 0x0103 }) do
    resolvers[control] = function()
      return FieldMessageProvider.asciiGlyphTokens("GOLD", def)
    end
  end
  return resolvers
end

function T.contacts_carry_their_source_message_bank(romFs, versionId)
  local catalog = compileCatalog(romFs, versionId)
  Assert.equal(#catalog.contacts, 75, "the compiled phonebook must carry all seventy-five native contacts")
  local byId = {}
  for _, record in ipairs(catalog.contacts) do
    local contact = record --[[@as table<string, unknown>]]
    Assert.equal(
      contact.messageBank,
      PokegearSources.phoneMessageBanks[
        contact.id --[[@as integer]] + 1
      ],
      "contact " .. tostring(contact.id) .. " reads its source bank"
    )
    byId[
      contact.id --[[@as integer]]
    ] = contact
  end
  local mom = contactInFamily(catalog, MOM_FAMILY)
  local elm = contactInFamily(catalog, ELM_FAMILY)
  Assert.equal(mom, byId[0], "the first native phonebook ID is Mom")
  Assert.equal(elm, byId[1], "the second native phonebook ID is Elm")
  Assert.equal(mom.messageBank, PokegearSources.phoneMessageBanks[mom.id + 1], "Mom reads her source message bank")
  Assert.equal(elm.messageBank, PokegearSources.phoneMessageBanks[elm.id + 1], "Elm reads his source message bank")
  Assert.equal(mom.messageBank, 664, "the mother greeting reads bank 664")
  Assert.equal(elm.messageBank, 716, "the Elm greeting reads bank 716")
  Assert.equal(mom.class.kind, "blank", "Mom's trainer class has no label")
  Assert.equal(elm.class.bank, 271, "the professor phone-only class uses bank 271")
  Assert.equal(
    elm.class.entry,
    elm.trainerClass
      - PokegearSources.phoneClassLabels.professorClass
      + PokegearSources.phoneClassLabels.specialFirstEntry,
    "the professor class entry follows the native class code"
  )
  Assert.deepEqual(
    catalog.landmarkLabels,
    { bank = 279, fallbackBank = 280, fallbackEntry = 2 },
    "landmark resolver references come from the generated source catalog"
  )
end

-- One pass over the supplied phonebook checks every compiled contact's
-- source order, native selector fields, and (for trainer contacts) both
-- complete eight-slot generic header arrays. Header rows are compiled from
-- the available decomp table, whose checkout is not the declared pin; this
-- proves preservation and linkage, not exact-pin provenance. No caller home
-- is booted here; production journeys remain separate representative cases.
function T.all_contacts_preserve_source_selectors_and_ordered_headers(romFs, versionId)
  local catalog = compileCatalog(romFs, versionId)
  local bytes = assert(romFs:readSourcePath(PokegearSources.phonebook.path))
  local source = BinaryReader.new(bytes, "phonebook-contact-matrix")
  local count = source:u32le(0)
  Assert.equal(count, 75, "the supplied phonebook has seventy-five native records")
  Assert.equal(#catalog.contacts, count, "the compiled catalog preserves every source contact")
  local headerTypeSeen = {}
  for sourceIndex = 0, count - 1 do
    local contact = catalog.contacts[sourceIndex + 1]
    local base = 4 + sourceIndex * PokegearSources.phonebook.recordBytes
    local contactId = source:u8(base)
    Assert.equal(contact.sourceIndex, sourceIndex, "contact order preserves phonebook row " .. sourceIndex)
    Assert.equal(contact.id, contactId, "row " .. sourceIndex .. " preserves its source contact ID")
    Assert.equal(contact.entryType, source:u8(base + 1), "contact type preserves phonebook byte 1")
    Assert.equal(contact.unknown2, source:u8(base + 2), "contact byte 2 remains source-derived")
    Assert.equal(
      contact.family,
      PokegearSources.phoneContactFamilies[contactId + 1],
      "contact family follows its native ID"
    )
    Assert.equal(
      contact.messageBank,
      PokegearSources.phoneMessageBanks[contactId + 1],
      "contact bank follows its native ID"
    )
    Assert.equal(contact.trainerClass, source:u8(base + 3), "contact class preserves phonebook byte 3")
    Assert.equal(contact.trainerId, source:u16le(base + 4), "contact trainer ID preserves phonebook halfword 4")
    Assert.equal(contact.mapId, source:u16le(base + 6), "contact map preserves phonebook halfword 6")
    Assert.equal(contact.gift, source:u16le(base + 8), "contact gift preserves phonebook halfword 8")
    local localScript = source:u16le(base + 10)
    Assert.equal(contact.localScript, localScript, "contact local selector preserves phonebook halfword 10")
    Assert.equal(contact.greeting, localScript, "native call selector preserves its phonebook value")
    Assert.equal(contact.rematchWeekday, source:u8(base + 13), "contact weekday preserves phonebook byte 13")
    Assert.equal(contact.rematchTime, source:u8(base + 14), "contact time preserves phonebook byte 14")
    Assert.equal(contact.unknown12, source:u8(base + 12), "contact byte 12 remains source-derived")
    Assert.equal(contact.unknown15, source:u8(base + 15), "contact byte 15 remains source-derived")
    for weightIndex = 1, 4 do
      Assert.equal(
        contact.sortWeights[weightIndex],
        source:u8(base + 15 + weightIndex),
        "contact sorting weight " .. weightIndex .. " preserves its phonebook byte"
      )
    end
    local definition =
      assert(catalog.callDefinitions[contact.greeting], "contact " .. contactId .. " has a selected native definition")
    Assert.equal(definition.male.bank, contact.messageBank, "male definition stays in the selected caller bank")
    Assert.equal(definition.female.bank, contact.messageBank, "female definition stays in the selected caller bank")
    if contact.family == "trainer" then
      local sourceHeaders = assert(
        PokegearSources.genericPhoneHeaders[contactId],
        "trainer contact " .. contactId .. " has source header rows"
      )
      for _, direction in ipairs({ "incoming", "outgoing" }) do
        local rows = assert(contact.genericCallHeaders[direction], "trainer headers preserve each call direction")
        Assert.equal(#rows, 8, "trainer " .. contactId .. " preserves all eight " .. direction .. " slots")
        local sourceRows = assert(sourceHeaders[direction], "source headers preserve both directions")
        for slot = 1, 8 do
          local row = rows[slot]
          local sourceRow = sourceRows[slot]
          Assert.equal(
            row.type,
            sourceRow[1],
            "trainer " .. contactId .. " " .. direction .. " slot " .. slot .. " type"
          )
          Assert.equal(
            row.chance,
            sourceRow[2],
            "trainer " .. contactId .. " " .. direction .. " slot " .. slot .. " chance"
          )
          Assert.equal(
            row.scriptType,
            sourceRow[3],
            "trainer " .. contactId .. " " .. direction .. " slot " .. slot .. " script type"
          )
          Assert.equal(
            row.scriptId,
            sourceRow[4],
            "trainer " .. contactId .. " " .. direction .. " slot " .. slot .. " selector"
          )
          if row.type ~= 0 and row.type ~= 255 then
            headerTypeSeen[row.scriptType] = true
            local headerDefinition = assert(
              catalog.callDefinitions[row.scriptId],
              "active trainer header selector " .. row.scriptId .. " maps to a compiled definition"
            )
            Assert.equal(
              headerDefinition.male.bank,
              contact.messageBank,
              "header definition male line uses caller bank"
            )
            Assert.equal(
              headerDefinition.female.bank,
              contact.messageBank,
              "header definition female line uses caller bank"
            )
          end
        end
      end
    end
  end
  for _, scriptType in ipairs({ 0, 1, 2 }) do
    Assert.isTrue(headerTypeSeen[scriptType] == true, "the full trainer matrix carries script type " .. scriptType)
  end
end

-- Every referenced greeting bank is demandable through the existing bank
-- pipeline: acquiring and releasing each one succeeds with no missing
-- bank. This is the producer provisioning proof for the phone banks.
function T.greeting_banks_are_demandable(romFs, versionId)
  local catalog = compileCatalog(romFs, versionId)
  local provider = assert(FieldMessageProvider.new(CacheFs.forVersion(versionId)))
  local seen = {}
  for _, record in ipairs(catalog.contacts) do
    local contact = record --[[@as table<string, unknown>]]
    local bank = contact.messageBank --[[@as integer]]
    if seen[bank] ~= true then
      seen[bank] = true
      local acquired, acquireErr = provider:acquireBank(bank)
      Assert.notNil(acquired, "greeting bank " .. bank .. " must be demandable: " .. tostring(acquireErr))
      Assert.equal((acquired --[[@as table<string, unknown>]]).bankId, bank, "the demandable bank carries its identity")
      provider:releaseBank(bank)
    end
  end
  local count = 0
  for _ in pairs(seen) do
    count = count + 1
  end
  Assert.equal(count, 75, "all seventy-five greeting banks are demandable")
  provider:dispose()
end

-- Where greeting dialogue text stands: each (bank, greeting-number) pair
-- reports whether the number resolves as a direct bank entry and whether
-- its tokens format through the existing machinery. The greeting number is
-- a phone-script selector, so pairs whose number exceeds their bank only
-- resolve through the script table: they are reported with bank/entry
-- evidence and never invented. No token preparation may fail.
function T.greeting_entries_report_their_standing(romFs, versionId)
  local catalog = compileCatalog(romFs, versionId)
  local def = fontDef(versionId)
  local resolvers = nameResolvers(def)
  local provider = assert(FieldMessageProvider.new(CacheFs.forVersion(versionId)))
  local clean, unresolved, unmapped, faulted = 0, {}, {}, {}
  for _, record in ipairs(catalog.contacts) do
    local contact = record --[[@as table<string, unknown>]]
    local bank = contact.messageBank --[[@as integer]]
    local scriptId = contact.greeting --[[@as integer]]
    local definition =
      assert(catalog.callDefinitions[scriptId], "every phonebook script selector maps to a native phone definition")
    Assert.equal(definition.male.bank, bank, "the selected caller script uses its message bank")
    Assert.equal(definition.female.bank, bank, "the selected caller script keeps its gendered text in that bank")
    local acquired, acquireErr = provider:acquireBank(bank)
    Assert.notNil(
      acquired,
      "greeting bank " .. bank .. " must be demandable for " .. tostring(contact.key) .. ": " .. tostring(acquireErr)
    )
    local bankCount = (acquired --[[@as table<string, unknown>]]).messageCount --[[@as integer]]
    local where = "bank "
      .. bank
      .. " number "
      .. scriptId
      .. " ("
      .. tostring(contact.key)
      .. ", bank holds "
      .. bankCount
      .. ")"
    for _, gender in ipairs({ "male", "female" }) do
      local entry = definition[gender].entry
      local template, templateErr = provider:get(bank, entry)
      if template == nil then
        unmapped[#unmapped + 1] = where
          .. " "
          .. gender
          .. ": "
          .. tostring(templateErr and templateErr.code or templateErr)
      else
        local ok, formatted = pcall(provider.format, provider, template, { playerName = "GOLD" }, resolvers)
        if ok then
          if
            (formatted --[[@as table<string, unknown>]]).hadUnresolvedSubstitutions == true
          then
            unresolved[#unresolved + 1] = "bank " .. bank .. " entry " .. entry .. " (" .. tostring(contact.key) .. ")"
          else
            clean = clean + 1
          end
        else
          faulted[#faulted + 1] = "bank "
            .. bank
            .. " entry "
            .. entry
            .. " ("
            .. tostring(contact.key)
            .. "): "
            .. tostring(formatted)
        end
      end
    end
    provider:releaseBank(bank)
  end
  print(
    "phone script dialogue: "
      .. clean
      .. " clean, "
      .. #unresolved
      .. " unresolved, "
      .. #unmapped
      .. " missing, "
      .. #faulted
      .. " faulted"
  )
  for _, line in ipairs(unresolved) do
    print("phone greeting unresolved: " .. line)
  end
  for _, line in ipairs(unmapped) do
    print("phone greeting script-routed: " .. line)
  end
  for _, line in ipairs(faulted) do
    print("phone greeting fault: " .. line)
  end
  Assert.equal(clean + #unresolved + #unmapped + #faulted, 150, "every native caller script line reports its standing")
  Assert.equal(#unmapped, 0, "every caller script definition resolves to a compiled message")
  Assert.equal(#faulted, 0, "no caller script line may fail token preparation")
  provider:dispose()
end

---@param catalog table<string, unknown>
---@param messages table<string, unknown>
---@return table host, table state the real script host over the compiled owners
local function openHost(catalog, messages)
  local PokegearScriptHost = require("game.hgss.src.pokegear.PokegearScriptHost")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
  local state = PokegearState.new({ seed = 4242 }, { catalog = catalog })
  return PokegearScriptHost.new({
    state = state,
    catalog = catalog,
    messages = messages,
    world = {
      flags = {},
      canCall = function()
        return true
      end,
      player = { x = 5, y = 7 },
      nativeSelectorFacts = function()
        return { localMap = true }
      end,
    },
    audio = {
      playDialing = function() end,
      playHangup = function() end,
    },
    random = PokegearRandom.new(4242),
  }),
    state
end

-- Steps the host until the call reports its terminal result.
---@param host table
---@param handle table
---@return table terminal result
local function settleCall(host, handle)
  for _ = 1, 60 do
    local result = host:result(handle)
    if result ~= nil then
      return result --[[@as table]]
    end
    host:step(handle, { { type = "advance" } })
  end
  error("the real greeting call never reached its terminal result", 0)
end

function T.outgoing_call_completes_with_real_greeting_refs(romFs, versionId)
  local catalog = compileCatalog(romFs, versionId)
  local messages = greetingMessages(catalog, versionId)
  local mom = contactInFamily(catalog, MOM_FAMILY)
  local elm = contactInFamily(catalog, ELM_FAMILY)
  Assert.equal(
    messages[mom.key],
    "msg.hgss." .. mom.messageBank .. "." .. mom.greeting,
    "the Mom reference names her source bank and selector"
  )
  Assert.equal(
    messages[elm.key],
    "msg.hgss." .. elm.messageBank .. "." .. elm.greeting,
    "the Elm reference names his source bank and selector"
  )
  local host, state = openHost(catalog, messages)
  state:registerContact(mom.key)
  local handle = host:open({
    mode = "call",
    request = { id = "greeting-outgoing-1", contact = mom.key, direction = "outgoing", kind = "ordinary" },
    parentOwner = "script:greeting-proof",
  })
  local result = settleCall(host, handle)
  Assert.equal(result.contact, mom.key, "the outgoing call completes for its contact")
  host:close(handle)
  messages.dispose(messages)
end

function T.scripted_call_completes_through_the_real_task_and_host(romFs, versionId)
  local catalog = compileCatalog(romFs, versionId)
  local messages = greetingMessages(catalog, versionId)
  local host, state = openHost(catalog, messages)
  local mom = contactInFamily(catalog, MOM_FAMILY)
  state:registerContact(mom.key)
  local FieldScriptComposition = require("game.hgss.src.field.FieldScriptComposition")
  local Runtime = require("libs.script.src.Runtime")
  local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
  local services = {
    pokegearApplications = host,
    phoneContactIndex = assert(
      FieldScriptComposition.phoneContactIndex(catalog),
      "the scripted call resolves numbers through the compiled index"
    ),
  }
  local run = {
    instance = { scriptId = "test.panic", mode = "foreground", instanceId = "panic-1" },
    services = services,
    semantics = RuntimeValues,
    scheduler = {
      createTask = function()
        error("the scripted setup never blocks", 0)
      end,
    },
    tick = 9,
  }
  -- The phonebook number is source-derived; the current map facts select Mom's local reply.
  Assert.equal(
    Runtime.executeNode({ op = "phone_set_call", contact = mom.id, direction = "outgoing", kind = 0 }, run),
    Runtime.OUTCOME_CONTINUE,
    "the scripted setup stages same-tick"
  )
  local staged = {}
  run.scheduler = {
    createTask = function(_, taskType, spec)
      staged[#staged + 1] = { type = taskType, spec = spec }
      return "task-staged"
    end,
  }
  Assert.equal(
    Runtime.executeNode({ op = "phone_run_call" }, run),
    Runtime.OUTCOME_BLOCK,
    "the run consumes and blocks"
  )
  Assert.equal(#staged, 1, "the run blocks on exactly one application task")
  Assert.equal(staged[1].spec.request.contact, mom.key, "the source phonebook number stages Mom")
  Assert.equal(staged[1].spec.request.direction, "outgoing", "the native local selector takes the outgoing path")
  local PokegearApplicationTask = require("libs.hgss.src.script.tasks.PokegearApplicationTask")
  local taskCtx = { services = { pokegearApplications = host }, input = { uiEvents = {} } }
  local taskState = PokegearApplicationTask.create({
    kind = "call",
    request = staged[1].spec.request,
    parentOwner = "script:test.panic",
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
  Assert.isTrue(done, "the scripted local call completes through its task and host")
  Assert.isFalse(host:isActive(), "completion releases the feature lease")
  messages.dispose(messages)
  local elm = contactInFamily(catalog, ELM_FAMILY)
  local definition = assert(catalog.callDefinitions[elm.greeting])
  Assert.equal(definition.male.bank, elm.messageBank, "the compiled Elm call script uses Elm's message bank")
  local provider = assert(FieldMessageProvider.new(CacheFs.forVersion(versionId)))
  local elmBank = assert(provider:acquireBank(definition.male.bank))
  Assert.isTrue(definition.male.entry < elmBank.messageCount, "the Elm call script entry exists in its message bank")
  local template = assert(provider:get(definition.male.bank, definition.male.entry))
  Assert.isTrue(type(template.tokens) == "table" and #template.tokens > 0, "the Elm script line carries real tokens")
  provider:releaseBank(definition.male.bank)
  provider:dispose()
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
local derived = { "field-font:global" }
for _, bankId in ipairs(PokegearSources.phoneMessageBankIds()) do
  derived[#derived + 1] = "message-bank:" .. tostring(bankId)
end
suite.metadata.derivedAssets = derived
return suite
