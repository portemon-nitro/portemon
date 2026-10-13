-- Native phone names, incoming caller labels, and call pages cross the
-- production field composition over the user's generated ROM cache. The
-- scenarios stop at detached views before the graphics host is invoked.

local Assert = require("tests.support.Assert")
local Fixture = require("tests.support.PokegearJourneyFixture")
local LocalClock = require("game.src.LocalClock")
local PokegearSources = require("romdump.src.config.PokegearSources")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

local DERIVED_ASSETS = {}
for _, key in ipairs(Fixture.JOURNEY_ASSETS) do
  DERIVED_ASSETS[#DERIVED_ASSETS + 1] = key
end
for _, bankId in ipairs({ 271, 279, 280, 664, 675, 716, 730 }) do
  DERIVED_ASSETS[#DERIVED_ASSETS + 1] = "message-bank:" .. tostring(bankId)
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

local function phoneView(game)
  local status = assert(game.runtime.applicationHost:status().application, "the gear application owns the field tick")
  local child = assert(status.child, "the Phone card publishes its child view")
  return assert(child.view, "the Phone card publishes its detached view")
end

local function contactByFamily(catalog, family)
  for _, contact in ipairs(catalog.contacts) do
    if contact.family == family then
      return contact
    end
  end
  error("the native phonebook has a " .. family .. " contact", 0)
end

local function sourceName(game, contact)
  local provider = assert(game.runtime.messageProvider, "the production field owns its message provider")
  local bankId = assert(contact.messageBank, "the native contact names its caller bank")
  local bank, acquireError = provider:acquireBank(bankId)
  assert(bank ~= nil, "the caller name bank is available in the prepared ROM cache: " .. tostring(acquireError))
  local template, readError = provider:get(bankId, 0)
  assert(template ~= nil, "the caller bank publishes entry zero: " .. tostring(readError))
  local formatted = provider:format(template, {}, {})
  provider:releaseBank(bankId)
  Assert.isFalse(formatted.hadUnresolvedSubstitutions, "caller names need no unresolved runtime substitutions")
  return formatted.text
end

local function actionEdge(game)
  game.runtime:pressAction()
  game:step()
  game.runtime:releaseAction()
end

function T.tests.native_phone_rows_use_caller_bank_names_and_class_rules()
  Fixture.withGame(Fixture.TOWN, function(game)
    local catalog = assert(game.runtime.pokegearCatalog, "the field runtime owns the ROM-derived phone catalog")
    local mom = contactByFamily(catalog, "mother")
    local elm = contactByFamily(catalog, "elm")
    local trainer = contactByFamily(catalog, "trainer")
    local state = assert(game.runtime.pokegearState, "the field runtime owns the phonebook state")
    for _, contact in ipairs({ mom, elm, trainer }) do
      state:registerContact(contact.key)
    end

    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })
    Fixture.openGearThroughMenu(game)
    local rowsByKey = {}
    for _, row in ipairs(phoneView(game).list.rows) do
      rowsByKey[row.contact] = row
    end
    for _, contact in ipairs({ mom, elm, trainer }) do
      local row = assert(rowsByKey[contact.key], "the acquired native caller appears in the Phone list")
      Assert.equal(row.label, sourceName(game, contact), "the caller name comes from bank entry zero")
      Assert.isFalse(row.label == contact.key, "the Phone list never displays an internal caller key")
      if contact == mom then
        Assert.equal(
          row.class,
          "",
          "Mom's native class window is blank, got "
            .. tostring(row.class)
            .. " from class "
            .. tostring(contact.contactClass)
            .. " rule "
            .. tostring(contact.class.kind)
            .. ":"
            .. tostring(contact.class.bank)
            .. ":"
            .. tostring(contact.class.entry)
        )
      else
        Assert.isTrue(type(row.class) == "string" and row.class ~= "", "native callers show their source class")
        Assert.isFalse(row.class == contact.key, "the class cell never displays a caller key")
      end
    end
  end)
end

function T.tests.incoming_banner_uses_the_same_rom_resolved_caller_name()
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
    local catalog = assert(game.runtime.pokegearCatalog, "the field runtime owns the ROM-derived phone catalog")
    local state = assert(game.runtime.pokegearState, "the field runtime owns the phonebook state")
    for _, contact in ipairs(catalog.contacts) do
      state:registerContact(contact.key)
    end
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })
    local trigger = assert(catalog.callTriggers[1], "the source catalog has a native incoming-call trigger")
    local calls = assert(game.runtime.incomingCalls, "the field runtime owns incoming-call policy")
    calls:setTrigger(trigger.key, true)
    sample.minute = 1
    game:step()
    game:step()

    local notice = calls:notification()
    Assert.isTrue(type(notice) == "table", "the production incoming-call policy publishes its eligible banner")
    local contact = nil
    for _, entry in ipairs(catalog.contacts) do
      if entry.key == notice.contactKey then
        contact = entry
        break
      end
    end
    contact = assert(contact, "the incoming banner caller resolves through the native phonebook")
    Assert.equal(notice.name, sourceName(game, contact), "the banner uses the caller bank's entry-zero name")
    Assert.isFalse(notice.name == notice.contactKey, "the incoming banner never exposes an internal caller key")
    Assert.equal(notice.nameTokens[1], notice.name, "the banner text token carries its resolved caller name")
  end, { localClock = clock })
end

function T.tests.phone_call_publishes_selected_rom_dialogue_through_the_field_text_path()
  Fixture.withGame(Fixture.TOWN, function(game)
    local catalog = assert(game.runtime.pokegearCatalog, "the field runtime owns the ROM-derived phone catalog")
    local mom = contactByFamily(catalog, "mother")
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })
    Fixture.openGearThroughMenu(game)
    game:advanceUntil("the opening Phone transition completes", function()
      local status = game.runtime.applicationHost:status().application
      return status ~= nil and status.transition == nil
    end, 40)
    actionEdge(game)
    actionEdge(game)
    actionEdge(game)
    local call = assert(phoneView(game).call, "the live phone call publishes its detached text view")
    Assert.equal(call.contact, mom.key, "the selected menu row starts Mom's production phone call")
    Assert.equal(
      call.stage,
      "message",
      "the selected native program must stop at a source-text wait, got " .. tostring(call.stage)
    )
    Assert.isTrue(
      type(call.lines) == "table" and #call.lines > 0,
      "the selected native call publishes ROM-resolved dialogue pages through the field text provider"
    )
    for _, page in ipairs(call.lines) do
      Assert.isTrue(type(page.text) == "string" and page.text ~= "", "each source dialogue page carries printable text")
      Assert.isFalse(page.text:find("msg.hgss.", 1, true) ~= nil, "a dialogue page never prints a message identity")
      Assert.isFalse(page.text:find("PHONE_SCRIPT", 1, true) ~= nil, "a dialogue page never prints a script label")
    end
  end)
end

function T.tests.native_phone_menu_releases_a_wrong_bank_definition()
  Fixture.withGame(Fixture.TOWN, function(game)
    local catalog = assert(game.runtime.pokegearCatalog, "the field runtime owns the ROM-derived phone catalog")
    local mom = contactByFamily(catalog, "mother")
    local state = assert(game.runtime.pokegearState, "the field runtime owns the phonebook state")
    state:registerContact(mom.key)
    local wrongBank = nil
    for _, bankId in ipairs(PokegearSources.phoneMessageBankIds()) do
      if bankId ~= mom.messageBank then
        wrongBank = bankId
        break
      end
    end
    local bank = assert(wrongBank, "the phonebook contains another caller bank")
    for _, scriptId in ipairs({ 23, 25, 26 }) do
      local definition = assert(catalog.callDefinitions[scriptId], "Mom's source branch has a native script definition")
      definition.male.bank = bank
      definition.female.bank = bank
    end

    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })
    game.runtime.eventState:clearFlag(FieldScriptSymbols.flagsByName.FLAG_GAVE_RIVAL_NAME_TO_OFFICER)
    game.runtime.eventState:clearFlag(FieldScriptSymbols.flagsByName.FLAG_TALKED_TO_MOM_AFTER_NAMING_RIVAL)
    Fixture.openGearThroughMenu(game)
    game:advanceUntil("the opening Phone transition completes", function()
      local status = game.runtime.applicationHost:status().application
      return status ~= nil and status.transition == nil
    end, 40)
    actionEdge(game)
    actionEdge(game)
    actionEdge(game)
    local call
    for _ = 1, 240 do
      call = phoneView(game).call
      if call ~= nil and call.stage == "completed" then
        break
      end
      if call == nil or call.stage == "connecting" or call.stage == "hangingUp" then
        game:step()
      else
        actionEdge(game)
      end
    end
    Assert.isNil(call, "the menu releases the unavailable call instead of retaining a detached script-host result")
    Assert.isNil(phoneView(game).call, "the failed menu call returns to the Phone list")
  end)
end

return T
