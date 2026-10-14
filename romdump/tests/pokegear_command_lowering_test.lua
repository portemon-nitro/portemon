-- Lowering coverage for the bounded pocket-gear script inventory: every
-- inventoried opcode carries exact executable semantics (supported
-- disposition, exact widths, same-tick versus blocking timing), lowers
-- to its closed typed gear operation instead of an unsupported node, and
-- unknown selectors fail lowering loudly instead of emitting a plausible
-- node. No ROM data is required; the corpus census lives with the
-- ROM-gated conformance suite.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

local CONTINUATION = {
  [142] = "continue_same_tick",
  [145] = "continue_same_tick",
  [146] = "continue_same_tick",
  [147] = "continue_same_tick",
  [148] = "continue_same_tick",
  [149] = "continue_same_tick",
  [157] = "native_wait",
  [430] = "continue_same_tick",
  [431] = "native_wait",
  [460] = "continue_same_tick",
  [461] = "continue_same_tick",
  [613] = "continue_same_tick",
  [614] = "continue_same_tick",
  [779] = "continue_same_tick",
  [811] = "continue_same_tick",
  [812] = "continue_same_tick",
  [813] = "continue_same_tick",
  [821] = "continue_same_tick",
}

local WIDTHS = {
  [142] = 2,
  [145] = 1,
  [146] = 1,
  [147] = 2,
  [148] = 2,
  [149] = 1,
  [157] = 0,
  [430] = 3,
  [431] = 0,
  [460] = 2,
  [461] = 3,
  [613] = 1,
  [614] = 1,
  [779] = 2,
  [811] = 2,
  [812] = 0,
  [813] = 1,
  [821] = 2,
}

---@param opcode integer
---@param operands table<integer, integer|string>
---@return table the single lowered step
local function lowerSingle(opcode, operands)
  local widths = CommandCatalog.widths(opcode) or {}
  local raw = {}
  for index = 1, #widths do
    raw[index] = { raw = operands[index] ~= nil and operands[index] or 0, width = widths[index] }
  end
  local lowered = SemanticLowering.lowerScript(
    { instructions = { { opcode = opcode, operands = raw, offset = 0 } } },
    { member = 12, scripts = {}, movements = {} },
    { stdCatalog = SourceCatalog.catalog() }
  )
  Assert.equal(#lowered.items, 1, "opcode " .. opcode .. " lowers to one step")
  return lowered.items[1]
end

function T.tests.every_inventoried_row_is_supported_with_exact_widths_and_timing()
  for opcode, expected in pairs(CONTINUATION) do
    Assert.equal(CommandCatalog.disposition(opcode), "supported", "opcode " .. opcode .. " is executable")
    Assert.equal(CommandCatalog.classification(opcode), expected, "opcode " .. opcode .. " keeps its timing")
    Assert.equal(#(CommandCatalog.widths(opcode) or {}), WIDTHS[opcode], "opcode " .. opcode .. " keeps its width")
  end
end

function T.tests.rematches_register_and_queries_lower_to_typed_nodes()
  local rematch = lowerSingle(142, { 34, "VAR_TEMP_x4001" })
  Assert.equal(rematch.op, "phone_rematch_trainer")
  Assert.equal(rematch.contact, 34, "immediate contacts ride their phonebook number")
  Assert.deepEqual(rematch.result, { value = "var", id = "VAR_TEMP_x4001" })
  local rematchVar = lowerSingle(142, { "VAR_TEMP_x4010", "VAR_SPECIAL_RESULT" })
  Assert.deepEqual(rematchVar.contact, { value = "var", id = "VAR_TEMP_x4010" }, "variable contacts stay references")
  local clear = lowerSingle(462, { "VAR_TEMP_x4010" })
  Assert.equal(clear.op, "phone_rematch_clear")
  Assert.deepEqual(clear.contact, { value = "var", id = "VAR_TEMP_x4010" })
  local register = lowerSingle(146, { 1 })
  Assert.equal(register.op, "pokegear_update")
  Assert.equal(register.kind, "register_contact")
  Assert.equal(register.contact, 1)
  local check = lowerSingle(147, { 34, "VAR_TEMP_x4001" })
  Assert.equal(check.op, "pokegear_query")
  Assert.equal(check.kind, "contact_registered")
  Assert.equal(check.contact, 34)
  Assert.deepEqual(check.result, { value = "var", id = "VAR_TEMP_x4001" })
end

function T.tests.native_trainer_script_identity_lowers_get_trainer_num_from_its_std_index()
  local command = CommandCatalog.widths(212)
  Assert.equal(#command, 1, "GetTrainerNum carries only its result variable")
  local raw = { raw = "VAR_SPECIAL_x8004", width = command[1] }
  local lowered = SemanticLowering.lowerScript(
    { index = 7, instructions = { { opcode = 212, operands = { raw }, offset = 0 } } },
    { member = 953, scripts = {}, movements = {} },
    { stdCatalog = SourceCatalog.catalog() }
  )
  Assert.equal(#lowered.items, 1)
  Assert.equal(lowered.items[1].op, "set_var")
  Assert.deepEqual(lowered.items[1].variable, { value = "var", id = "VAR_SPECIAL_x8004" })
  Assert.equal(lowered.items[1].value, 8, "source script index 7 identifies native trainer 8")
end

function T.tests.native_trainer_movement_query_keeps_last_talked_actor_reference()
  local movement = lowerSingle(574, { "VAR_SPECIAL_x8001", "VAR_SPECIAL_LAST_TALKED" })
  Assert.equal(movement.op, "actor_movement_selector")
  Assert.deepEqual(movement.result, { value = "var", id = "VAR_SPECIAL_x8001" })
  Assert.deepEqual(movement.actor, { ref = "actor", special = "last_talked" })
end

function T.tests.card_registration_names_its_closed_card()
  Assert.equal(lowerSingle(145, { 0 }).card, "phone", "the base card resets the optional bits")
  Assert.equal(lowerSingle(145, { 1 }).card, "map")
  Assert.equal(lowerSingle(145, { 2 }).card, "radio")
  Assert.equal(lowerSingle(145, { 1 }).op, "pokegear_register_card")
  local ok, err = pcall(lowerSingle, 145, { 9 })
  Assert.isFalse(ok, "unknown card selectors fail lowering")
  Assert.notNil(tostring(err):find("145", 1, true), "the failure names its opcode")
end

function T.tests.trigger_switches_fold_slots_to_durable_keys()
  local set = lowerSingle(148, { 1, 0 })
  Assert.equal(set.op, "pokegear_set_trigger")
  Assert.equal(set.trigger, "gear.trigger.1")
  Assert.isFalse(set.active, "a zero switch value clears")
  local setOn = lowerSingle(148, { 5, 1 })
  Assert.equal(setOn.trigger, "gear.trigger.5")
  Assert.isTrue(setOn.active, "a nonzero switch value commits")
  local clear = lowerSingle(149, { 12 })
  Assert.equal(clear.op, "pokegear_set_trigger")
  Assert.equal(clear.trigger, "gear.trigger.12")
  Assert.isFalse(clear.active, "the clear row never activates")
  local ok, err = pcall(lowerSingle, 148, { 300, 0 })
  Assert.isFalse(ok, "out-of-range slots fail lowering")
  Assert.notNil(tostring(err):find("148", 1, true), "the failure names its opcode")
end

function T.tests.town_map_and_calls_lower_to_their_tasks()
  local townMap = lowerSingle(157, {})
  Assert.equal(townMap.op, "pokegear_open")
  Assert.equal(townMap.mode, "townMap", "the standalone map blocks on its task")
  local setup = lowerSingle(430, { "VAR_SPECIAL_x8004", "VAR_SPECIAL_x8005", "VAR_SPECIAL_x8006" })
  Assert.equal(setup.op, "phone_set_call")
  Assert.deepEqual(setup.contact, { value = "var", id = "VAR_SPECIAL_x8004" }, "setup operands stay references")
  Assert.deepEqual(setup.direction, { value = "var", id = "VAR_SPECIAL_x8005" })
  Assert.deepEqual(setup.kind, { value = "var", id = "VAR_SPECIAL_x8006" })
  Assert.equal(lowerSingle(431, {}).op, "phone_run_call", "run stays a separate blocking operation")
end

function T.tests.phonebook_and_gift_rows_lower_to_typed_nodes()
  local resolve = lowerSingle(460, { "VAR_SPECIAL_x8004", "VAR_TEMP_x4010" })
  Assert.equal(resolve.op, "phone_resolve_contact")
  Assert.deepEqual(resolve.trainer, { value = "var", id = "VAR_SPECIAL_x8004" })
  Assert.deepEqual(resolve.result, { value = "var", id = "VAR_TEMP_x4010" })
  local message = lowerSingle(461, { 2, "VAR_SPECIAL_x8004", "VAR_SPECIAL_x8005" })
  Assert.equal(message.op, "phone_contact_message")
  Assert.equal(message.kind, 2)
  Assert.deepEqual(message.contact, { value = "var", id = "VAR_TEMP_x4010" }, "the entry temp rides explicitly")
  local berry = lowerSingle(613, { "VAR_SPECIAL_RESULT" })
  Assert.equal(berry.op, "phone_contact_gift")
  Assert.equal(berry.kind, "berry")
  Assert.deepEqual(berry.contact, { value = "var", id = "VAR_TEMP_x4010" })
  local item = lowerSingle(614, { "VAR_SPECIAL_RESULT" })
  Assert.equal(item.op, "phone_contact_gift")
  Assert.equal(item.kind, "item")
  local ok, err = pcall(lowerSingle, 461, { 9, "VAR_SPECIAL_x8004", "VAR_SPECIAL_x8005" })
  Assert.isFalse(ok, "unknown message kinds fail lowering")
  Assert.notNil(tostring(err):find("461", 1, true), "the failure names its opcode")
end

function T.tests.radio_parent_and_password_rows_lower_to_typed_nodes()
  local radio = lowerSingle(779, { 5, "VAR_SPECIAL_RESULT" })
  Assert.equal(radio.op, "radio_music_query")
  Assert.equal(radio.effect, "pokeflute")
  Assert.deepEqual(radio.result, { value = "var", id = "VAR_SPECIAL_RESULT" })
  local badRadio, badRadioErr = pcall(lowerSingle, 779, { 7, "VAR_SPECIAL_RESULT" })
  Assert.isFalse(badRadio, "unknown effect codes fail lowering")
  Assert.notNil(tostring(badRadioErr):find("779", 1, true), "the failure names its opcode")
  local mom = lowerSingle(813, { "VAR_SPECIAL_RESULT" })
  Assert.equal(mom.op, "mom_gift_check")
  Assert.deepEqual(mom.result, { value = "var", id = "VAR_SPECIAL_RESULT" })
  local password = lowerSingle(821, { "VAR_SPECIAL_x8000", "VAR_SPECIAL_x8001" })
  Assert.equal(password.op, "buena_password")
  Assert.deepEqual(password.firstWord, { value = "var", id = "VAR_SPECIAL_x8000" })
  Assert.deepEqual(password.correct, { value = "var", id = "VAR_SPECIAL_x8001" })
end

function T.tests.mom_gift_rows_lower_to_ordered_queue_operations()
  local head = lowerSingle(811, { "VAR_TEMP_x4001", "VAR_TEMP_x4002" })
  Assert.equal(head.op, "mom_gift_head")
  Assert.deepEqual(head.item, { value = "var", id = "VAR_TEMP_x4001" })
  Assert.deepEqual(head.quantity, { value = "var", id = "VAR_TEMP_x4002" })
  Assert.equal(lowerSingle(812, {}).op, "mom_gift_take")
  local check = lowerSingle(813, { "VAR_SPECIAL_RESULT" })
  Assert.equal(check.op, "mom_gift_check")
  Assert.deepEqual(check.result, { value = "var", id = "VAR_SPECIAL_RESULT" })
end

return T
