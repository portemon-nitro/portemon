-- Phone greeting references against the owned dump: every native contact
-- carries its source message bank beside its greeting number, every
-- referenced bank is demandable through the existing bank pipeline, every
-- greeting number reports its resolution standing with bank/entry
-- evidence, and one real outgoing call plus one real scripted 430/431
-- call complete end-to-end with those references. Structural facts and
-- bank/entry/token identities only; no retail message text is asserted
-- or printed. A missing dump reports a skip, never a pass, through the
-- declared dump capability.

local Assert = require("tests.support.Assert")
local RomSuite = require("tests.rom.support.RomSuite")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
local PokegearSources = require("romdump.src.config.PokegearSources")

local T = {}

local MOM_KEY = "hg.trainer.200.map.0.contact.0"
local ELM_KEY = "hg.trainer.201.map.0.contact.1"

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
  local byKey = {}
  for _, record in ipairs(catalog.contacts) do
    local contact = record --[[@as table<string, unknown>]]
    Assert.equal(
      contact.messageBank,
      PokegearSources.phoneMessageBanks[
        contact.id --[[@as integer]] + 1
      ],
      "contact " .. tostring(contact.id) .. " reads its source bank"
    )
    byKey[
      contact.key --[[@as string]]
    ] = contact
  end
  Assert.equal(byKey[MOM_KEY].messageBank, 664, "the mother greeting reads bank 664")
  Assert.equal(byKey[ELM_KEY].messageBank, 716, "the elm greeting reads bank 716")
  Assert.equal(byKey[MOM_KEY].greeting, 23, "the mother greeting reads number 23")
  Assert.equal(byKey[ELM_KEY].greeting, 1, "the elm greeting reads number 1")
  Assert.equal(byKey[MOM_KEY].class.kind, "blank", "Mom's trainer class has no label")
  Assert.equal(byKey[ELM_KEY].class.bank, 271, "the professor phone-only class uses bank 271")
  Assert.equal(
    byKey[ELM_KEY].class.entry,
    byKey[ELM_KEY].trainer - 201 + 38,
    "the professor class entry follows the native class code"
  )
  Assert.deepEqual(
    catalog.landmarkLabels,
    { bank = 279, fallbackBank = 280, fallbackEntry = 2 },
    "landmark resolver references come from the generated source catalog"
  )
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
    local entry = contact.greeting --[[@as integer]]
    local acquired, acquireErr = provider:acquireBank(bank)
    Assert.notNil(
      acquired,
      "greeting bank " .. bank .. " must be demandable for " .. tostring(contact.key) .. ": " .. tostring(acquireErr)
    )
    local bankCount = (acquired --[[@as table<string, unknown>]]).messageCount --[[@as integer]]
    local where = "bank "
      .. bank
      .. " number "
      .. entry
      .. " ("
      .. tostring(contact.key)
      .. ", bank holds "
      .. bankCount
      .. ")"
    local template, templateErr = provider:get(bank, entry)
    if template == nil then
      unmapped[#unmapped + 1] = where .. ": " .. tostring(templateErr and templateErr.code or templateErr)
    else
      local ok, formatted = pcall(provider.format, provider, template, { playerName = "GOLD" }, resolvers)
      if ok then
        if
          (formatted --[[@as table<string, unknown>]]).hadUnresolvedSubstitutions == true
        then
          unresolved[#unresolved + 1] = "bank " .. bank .. " entry " .. entry .. " (" .. tostring(contact.key) .. ")"
        else
          clean = clean + 1
          print("phone greeting clean: " .. where)
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
    provider:releaseBank(bank)
  end
  print(
    "phone greetings: "
      .. clean
      .. " clean, "
      .. #unresolved
      .. " with unresolved substitutions, "
      .. #unmapped
      .. " script-routed, "
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
  Assert.equal(clean + #unresolved + #unmapped + #faulted, 75, "every native greeting reports its standing")
  Assert.equal(#faulted, 0, "no greeting may fail its token preparation")
  local byKey = {}
  for _, record in ipairs(catalog.contacts) do
    local contact = record --[[@as table<string, unknown>]]
    byKey[
      contact.key --[[@as string]]
    ] = contact
  end
  for _, key in ipairs({ ELM_KEY }) do
    local contact = byKey[key]
    local template =
      assert(provider:acquireBank(contact.messageBank) and provider:get(contact.messageBank, contact.greeting))
    local formatted = provider:format(template, { playerName = "GOLD" }, resolvers)
    Assert.isFalse(formatted.hadUnresolvedSubstitutions, key .. " formats cleanly through the token machinery")
    provider:releaseBank(contact.messageBank)
  end
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
      rematchReady = {},
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
  Assert.equal(messages[ELM_KEY], "msg.hgss.716.1", "the elm reference names its bank and entry")
  Assert.equal(messages[MOM_KEY], "msg.hgss.664.23", "the mother reference names its bank and entry")
  local host, state = openHost(catalog, messages)
  state:registerContact(MOM_KEY)
  local handle = host:open({
    mode = "call",
    request = { id = "greeting-outgoing-1", contact = MOM_KEY, direction = "outgoing", kind = "ordinary" },
    parentOwner = "script:greeting-proof",
  })
  local result = settleCall(host, handle)
  Assert.equal(result.contact, MOM_KEY, "the outgoing call completes for its contact")
  host:close(handle)
  messages.dispose(messages)
  -- The frozen lease token resolves through the same bank pipeline: the
  -- provider serves the referenced bank and entry with real tokens.
  local provider = assert(FieldMessageProvider.new(CacheFs.forVersion(versionId)))
  local bank, entry = messages.greeting:match("^msg%.hgss%.(%d+)%.(%d+)$")
  Assert.notNil(bank, "the lease token stays a bank reference")
  Assert.notNil(provider:acquireBank(tonumber(bank)))
  local template = assert(provider:get(tonumber(bank), tonumber(entry)))
  Assert.isTrue(type(template.text) == "string" and template.text ~= "", "the token text is real bank copy")
  Assert.isTrue(type(template.tokens) == "table" and #template.tokens > 0, "the token stream is real")
  provider:releaseBank(tonumber(bank))
  provider:dispose()
end

function T.scripted_call_completes_through_the_real_task_and_host(romFs, versionId)
  local catalog = compileCatalog(romFs, versionId)
  local messages = greetingMessages(catalog, versionId)
  local host, state = openHost(catalog, messages)
  state:registerContact(MOM_KEY)
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
  local mom = nil
  for _, contact in ipairs(catalog.contacts) do
    if contact.key == MOM_KEY then
      mom = contact
      break
    end
  end
  mom = assert(mom, "the compiled phonebook carries Mom")
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
  Assert.equal(staged[1].spec.request.contact, MOM_KEY, "the source phonebook number stages Mom")
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
  local provider = assert(FieldMessageProvider.new(CacheFs.forVersion(versionId)))
  local elmBank = assert(provider:acquireBank(716))
  Assert.equal(elmBank.messageCount, 45, "the elm bank holds entries 0..44")
  local template = assert(provider:get(716, 1))
  Assert.isTrue(type(template.tokens) == "table" and #template.tokens > 0, "the elm entry carries real tokens")
  provider:releaseBank(716)
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
