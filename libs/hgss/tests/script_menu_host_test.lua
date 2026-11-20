-- ScriptMenuHost tests: script builders retain their distinct message sources
-- and resolve complete controller requests without owning menu runtime state.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldMessageFixture = require("tests.support.FieldMessageFixture")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
local ScriptMenuHost = require("libs.hgss.src.script.ScriptMenuHost")
local MenuProtocol = require("libs.assets.src.MenuProtocol")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local FIELD = FieldMessageFixture

-- One message carrying the given display text as a single glyph.
local function labelledMessages(text)
  return { { FIELD.glyph(0x0400 + string.byte(text:sub(1, 1)), text), FIELD.eos() } }
end

local function host()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldMessageFixture.write(cache, MenuProtocol.STANDARD_MESSAGE_BANK, labelledMessages("Standard"))
  FieldMessageFixture.write(cache, 2, labelledMessages("Script"))
  local provider = assert(FieldMessageProvider.new(cache))
  local h = ScriptMenuHost.new({
    provider = provider,
    substitutionResolvers = function()
      return {}
    end,
  })
  return h, provider
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, code)
end

-- Matching message IDs must still use different banks based on the original
-- builder operation, and entry result values must not become visual indexes.
function T.resolves_standard_and_script_messages_without_changing_item_values()
  local h = host()
  local standardBuilder = h:beginMenu({
    messageSource = "standard",
    initialCursor = 0,
    cancellable = false,
    result = "VAR_RESULT",
  })
  h:addItem(standardBuilder, { messageId = 0, vanillaMetadata = 255, value = 42 })
  local standardMenu = h:execute(standardBuilder, {})
  Assert.equal(standardMenu.items[1].text.text, "Standard")
  Assert.equal(standardMenu.items[1].value, 42)
  Assert.equal(standardMenu.items[1].vanillaMetadata, 255)

  local scriptBuilder = h:beginMenu({
    messageSource = { kind = "script", bank = 2 },
    initialCursor = 0,
    cancellable = false,
    result = "VAR_RESULT",
  })
  h:addItem(scriptBuilder, { messageId = 0, vanillaMetadata = 17, value = 900 })
  local scriptMenu = h:execute(scriptBuilder, {})
  Assert.equal(scriptMenu.items[1].text.text, "Script")
  Assert.equal(scriptMenu.items[1].value, 900)
end

-- Operands are already resolved by semantic lowering before reaching this
-- pure bridge; their concrete values must be retained verbatim.
function T.retains_var_derived_item_operands_as_concrete_values()
  local h = host()
  local builder = h:beginMenu({
    messageSource = "standard",
    initialCursor = 0,
    cancellable = false,
    result = "VAR_RESULT",
  })
  h:addItem(builder, { messageId = 0, vanillaMetadata = 73, value = 401 })
  local menu = h:execute(builder, {})
  Assert.equal(menu.items[1].vanillaMetadata, 73)
  Assert.equal(menu.items[1].value, 401)
end

-- ScrCmd_MultichoiceInit* and ScrCmd_MultichoiceItemAdd carry immediate
-- geometry and item bytes: the builder keeps the native tile position for the
-- foreground layout, and the item's source value must reach the request
-- verbatim without the list menu's help-message selector.
function T.multichoice_builders_keep_source_geometry_and_immediate_item_values()
  local h = host()
  local builder = h:beginMenu({
    kind = "multichoice",
    tileX = 20,
    tileY = 6,
    messageSource = "standard",
    initialCursor = 0,
    cancellable = true,
    cancelValue = 0xFFFE,
    result = "VAR_RESULT",
  })
  h:addItem(builder, { messageId = 0, value = 200 })
  h:addItem(builder, { messageId = 0, value = 255 })
  local request = h:execute(builder, {})
  Assert.equal(request.kind, "multichoice")
  Assert.equal(request.tileX, 20)
  Assert.equal(request.tileY, 6)
  Assert.equal(request.cancelValue, 0xFFFE)
  Assert.equal(#request.items, 2)
  Assert.equal(request.items[1].value, 200)
  Assert.equal(request.items[2].value, 255)
  Assert.isNil(request.items[1].vanillaMetadata, "a source multichoice item has no list help selector")
  Assert.equal(request.items[1].text.text, "Standard")
end

-- The two builder families are one-of-kind records: an item of the other
-- family (missing its own required metadata or carrying the other one) must
-- fail through the structured script/menu error path rather than publish a
-- window with mixed semantics.
function T.builders_reject_items_from_the_other_menu_family()
  local h = host()
  local listBuilder = h:beginMenu({
    messageSource = "standard",
    initialCursor = 0,
    cancellable = false,
    result = "VAR_RESULT",
  })
  Assert.isTrue(
    Errors.is(Assert.throws(function()
      h:addItem(listBuilder, { messageId = 0, value = 1 })
    end)),
    "a source multichoice item cannot populate a list menu"
  )

  local multichoiceBuilder = h:beginMenu({
    kind = "multichoice",
    tileX = 4,
    tileY = 2,
    messageSource = "standard",
    initialCursor = 0,
    cancellable = false,
    cancelValue = 0xFFFE,
    result = "VAR_RESULT",
  })
  Assert.isTrue(
    Errors.is(Assert.throws(function()
      h:addItem(multichoiceBuilder, { messageId = 0, vanillaMetadata = 7, value = 1 })
    end)),
    "a list menu item cannot populate a source multichoice"
  )
end

-- Source-faithful 749 menus carry `messageSource = "standard"`; their
-- message ids are indices into the HGSS standard list-menu bank. The
-- protocol constant is ROM-pinned (tests/rom verifies bank 191 holds the
-- vanilla list-menu ids), so a standard menu must resolve there.
function T.standard_menu_messages_resolve_from_the_hgss_standard_bank()
  Assert.equal(MenuProtocol.STANDARD_MESSAGE_BANK, 191)
end

function T.publishes_semantic_choices_without_entering_the_imported_builder()
  local h = host()
  local menu = h:choose({
    items = {
      { text = "Take", value = 10, metadata = { hgss = 255 } },
      { text = "Leave", value = 20 },
    },
    result = { value = "var", id = "choice" },
    cancellable = true,
    cancelValue = 20,
    initialCursor = 1,
  })
  Assert.equal(menu.items[1].text.text, "Take")
  Assert.equal(menu.items[1].value, 10)
  Assert.equal(menu.items[1].metadata.hgss, 255)
  Assert.equal(menu.initialCursor, 1)
  h:beginMenu({
    messageSource = "standard",
    initialCursor = 0,
    cancellable = false,
    result = "VAR_RESULT",
  })
end

function T.semantic_choices_keep_local_text_out_of_the_vanilla_message_resolver()
  local h = host()
  h._resolveText = function()
    error("local text must not use the vanilla message resolver")
  end
  local menu = h:choose({
    items = { { text = "Take", value = 10 } },
    cancellable = false,
  })
  Assert.equal(menu.items[1].text.text, "Take")
end

function T.semantic_choices_keep_msg_prefixed_local_text_out_of_the_vanilla_message_resolver()
  local h = host()
  h._resolveText = function()
    error("local text must not use the vanilla message resolver")
  end
  local menu = h:choose({
    items = { { text = "msg.custom", value = 10 } },
    cancellable = false,
  })
  Assert.equal(menu.items[1].text.text, "msg.custom")
end

function T.semantic_choices_resolve_external_message_references()
  local h = host()
  h._resolveText = function(message)
    Assert.deepEqual(message, { message = "external", bank = 2, id = 0 })
    return { text = "External" }
  end
  local menu = h:choose({
    items = { { text = { message = "external", bank = 2, id = 0 }, value = 10 } },
    cancellable = false,
  })
  Assert.equal(menu.items[1].text.text, "External")
end

function T.semantic_choices_fault_before_publication_when_text_cannot_resolve()
  local h = host()
  throwsCode("SCRIPT_MENU_MESSAGE_UNRESOLVED", function()
    h:choose({
      items = { { text = { message = "external", bank = 2, id = 0 }, value = 10 } },
      cancellable = false,
    })
  end)
end

-- Source menu labels such as "<PLAYER>'s PC" expand against the running
-- script's buffered text, like dialogue.
function T.builder_items_expand_buffered_script_text()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldMessageFixture.write(cache, MenuProtocol.STANDARD_MESSAGE_BANK, {
    {
      FIELD.control(0x0100, { 0 }),
      FIELD.glyph(0x0453, "'s PC"),
      FIELD.eos(),
    },
  })
  local seen
  local h = ScriptMenuHost.new({
    provider = assert(FieldMessageProvider.new(cache)),
    substitutionResolvers = function(_, textArgs)
      seen = textArgs
      return {
        [0x0100] = function()
          return { { kind = "glyph", code = 0x0457, text = "GOLD" } }
        end,
      }
    end,
  })
  local builder = h:beginMenu({
    messageSource = "standard",
    initialCursor = 0,
    cancellable = false,
    result = "VAR_RESULT",
  })
  h:addItem(builder, { messageId = 0, vanillaMetadata = 255, value = 0 })
  local textArgs = { [0] = { text = "player_name" } }
  Assert.equal(h:execute(builder, textArgs).items[1].text.text, "GOLD's PC")
  Assert.equal(seen, textArgs)
end

function T.rejects_builder_misuse()
  local h = host()
  throwsCode("SCRIPT_MENU_NOT_INITIALIZED", function()
    h:addItem(nil, { messageId = 0, vanillaMetadata = 0, value = 1 })
  end)
  throwsCode("SCRIPT_MENU_NOT_INITIALIZED", function()
    h:execute(nil, {})
  end)
  throwsCode("SCRIPT_MENU_EMPTY", function()
    h:execute({ items = {} }, {})
  end)
end

-- A failed lookup does not publish a partial controller request or leave the
-- provider's acquisition pinned; the builder remains script-owned until its
-- caller decides how to report the script fault.
function T.unresolved_messages_release_the_provider_without_publishing_a_menu()
  local h, provider = host()
  local builder = h:beginMenu({
    messageSource = "standard",
    initialCursor = 0,
    cancellable = false,
    result = "VAR_RESULT",
  })
  h:addItem(builder, { messageId = 99, vanillaMetadata = 0, value = 1 })
  throwsCode("SCRIPT_MENU_MESSAGE_UNRESOLVED", function()
    h:execute(builder, {})
  end)
  Assert.equal(provider:stats().references, 0)
  local nextBuilder = h:beginMenu({
    messageSource = "standard",
    initialCursor = 0,
    cancellable = false,
    result = "VAR_RESULT",
  })
  Assert.isTrue(nextBuilder ~= builder)
end

function T.retains_an_explicit_zero_cancellation_value()
  local h = host()
  local builder = h:beginMenu({
    messageSource = "standard",
    initialCursor = 0,
    cancellable = true,
    cancelValue = 0,
    result = "VAR_RESULT",
  })
  h:addItem(builder, { messageId = 0, vanillaMetadata = 0, value = 1 })
  Assert.equal(h:execute(builder, {}).cancelValue, 0)
end

-- The retail list menu has no cancellation value: B selects the last row,
-- so a cancellable builder without one resolves to its last item value.
function T.cancellable_retail_menu_cancels_to_its_last_row_value()
  local h = host()
  local builder = h:beginMenu({
    messageSource = "standard",
    initialCursor = 0,
    cancellable = true,
    result = "VAR_RESULT",
  })
  h:addItem(builder, { messageId = 0, vanillaMetadata = 0, value = 0 })
  h:addItem(builder, { messageId = 0, vanillaMetadata = 0, value = 1 })
  h:addItem(builder, { messageId = 0, vanillaMetadata = 0, value = 2 })
  Assert.equal(h:execute(builder, {}).cancelValue, 2)
end

return { tests = T }
