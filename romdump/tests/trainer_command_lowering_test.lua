-- Trainer engagement command lowering: the native standard-trainer family reads
-- its slot indices, trainer identities and message kinds through ScriptGetVar,
-- answers its queries through typed output references, and keeps the source's
-- operand order, including 574's destination-before-object layout and the two
-- battle-launch shapes' trailing selector bytes.

local Assert = require("tests.support.Assert")
local BattleHandlers = require("romdump.src.digest.script.lowering.BattleHandlers")
local FieldHandlers = require("romdump.src.digest.script.lowering.FieldHandlers")
local ScriptCommands = require("romdump.src.catalog.hgss.script_commands")

local T = {}

local function raw(value)
  return { raw = value }
end

local function instruction(opcode, operands)
  return { opcode = opcode, offset = 12, operands = operands or {} }
end

local function lower(opcode, operands)
  return assert(FieldHandlers[opcode])(instruction(opcode, operands))
end

-- The declared source timing of every command in the family.
function T.trainer_family_carries_its_source_dispositions()
  local expected = {
    [168] = { "continue_same_tick", "trainer_approach_start" },
    [169] = { "yield_next_tick", "trainer_approach_step" },
    [170] = { "continue_same_tick", "trainer_encounter_type" },
    [171] = { "continue_same_tick", "trainer_engagement_number" },
    [212] = { "continue_same_tick", "trainer_active_number" },
    [214] = { "native_wait", "trainer_message" },
    [215] = { "continue_same_tick", "trainer_message_params" },
    [216] = { "continue_same_tick", "trainer_rematch_message_params" },
    [217] = { "continue_same_tick", "trainer_is_double" },
    [218] = { "yield_next_tick", "trainer_encounter_music" },
    [222] = { "continue_same_tick", "party_can_double_battle" },
    [454] = { "continue_same_tick", "trainer_last_talked_movement" },
    [574] = { "continue_same_tick", "object_movement_type" },
  }
  for opcode, result in pairs(expected) do
    Assert.equal(ScriptCommands.byOpcode[opcode].classification, result[1], "opcode " .. opcode)
    Assert.equal(ScriptCommands.byOpcode[opcode].disposition, "supported", "opcode " .. opcode)
  end
end

-- A literal operand and a source variable are different things: a literal
-- stays a scalar, a variable reference keeps its variable identity.
function T.slot_and_trainer_operands_preserve_literal_versus_variable_semantics()
  local start = lower(168, { raw(1) })
  Assert.equal(start.index, 1, "a literal slot index stays a scalar")

  local variable = lower(168, { raw("VAR_SPECIAL_RESULT") })
  Assert.deepEqual(variable.index, { value = "var", id = "VAR_SPECIAL_RESULT" })

  local step = lower(169, { raw(0), raw("VAR_SPECIAL_x8004") })
  Assert.equal(step.index, 0)
  Assert.deepEqual(step.result, { value = "var", id = "VAR_SPECIAL_x8004" })

  local message = lower(214, { raw(46), raw("VAR_SPECIAL_x8000") })
  Assert.equal(message.trainer, 46, "a literal trainer number stays scalar")
  Assert.deepEqual(message.kind, { value = "var", id = "VAR_SPECIAL_x8000" })

  local music = lower(218, { raw("VAR_SPECIAL_x8004") })
  Assert.deepEqual(music.trainer, { value = "var", id = "VAR_SPECIAL_x8004" })
end

-- The three message-parameter outputs keep the source's operand order, and the
-- running-script queries carry only their output.
function T.message_parameters_and_context_queries_keep_their_outputs()
  local params = lower(215, { raw("VAR_SPECIAL_x8000"), raw("VAR_SPECIAL_x8001"), raw("VAR_SPECIAL_x8002") })
  Assert.equal(params.intro.id, "VAR_SPECIAL_x8000")
  Assert.equal(params.after.id, "VAR_SPECIAL_x8001")
  Assert.equal(params.shortIntro.id, "VAR_SPECIAL_x8002")

  local rematch = lower(216, { raw("VAR_SPECIAL_A"), raw("VAR_SPECIAL_B"), raw("VAR_SPECIAL_C") })
  Assert.equal(rematch.op, "trainer_rematch_message_params")
  Assert.equal(rematch.shortIntro.id, "VAR_SPECIAL_C")

  local active = lower(212, { raw("VAR_SPECIAL_x8004") })
  Assert.equal(active.result.id, "VAR_SPECIAL_x8004")
  Assert.isNil(active.trainer, "the running script's trainer identity never rides an operand")
end

-- ScrCmd_GetObjectMovementType reads its destination variable first and the
-- object operand second, and the engine's last-interacted variable is the
-- trigger's own actor.
function T.object_movement_type_reads_destination_then_object()
  local node = lower(574, { raw("VAR_SPECIAL_x8001"), raw("VAR_SPECIAL_LAST_TALKED") })
  Assert.equal(node.op, "object_movement_type")
  Assert.equal(node.result.id, "VAR_SPECIAL_x8001", "the first operand is the destination")
  Assert.deepEqual(node.actor, { ref = "actor", special = "last_talked" })
end

-- TrainerBattle carries both opponent identities through ScriptGetVar and its
-- two trailing raw selector bytes; MultiBattle leads with the ally identity.
function T.battle_launches_keep_their_operand_layout()
  local battle = assert(FieldHandlers[213])(instruction(213, {
    raw("VAR_SPECIAL_x8004"),
    raw("VAR_SPECIAL_x8005"),
    raw(1),
    raw(0),
  }))
  Assert.equal(battle.op, "battle_launch")
  Assert.equal(battle.kind, "trainer")
  Assert.deepEqual(battle.details.trainer, { value = "var", id = "VAR_SPECIAL_x8004" })
  Assert.deepEqual(battle.details.trainer2, { value = "var", id = "VAR_SPECIAL_x8005" })
  Assert.equal(battle.details.healOnLoss, 1, "the third raw byte is the single-opponent heal selector")
  Assert.equal(battle.details.followSlot, 0, "the fourth raw byte is the follow-mon selector")

  local multi = assert(BattleHandlers.multiBattle(instruction(562, {
    raw(675),
    raw("VAR_SPECIAL_x8004"),
    raw("VAR_SPECIAL_x8005"),
    raw(1),
  })))
  Assert.equal(multi.details.partner, 675, "the leading operand is the ally trainer")
  Assert.deepEqual(multi.details.trainer, { value = "var", id = "VAR_SPECIAL_x8004" })
  Assert.deepEqual(multi.details.trainer2, { value = "var", id = "VAR_SPECIAL_x8005" })
  Assert.equal(multi.details.followSlot, 1)
  Assert.isNil(multi.details.healOnLoss, "a multi battle never carries the single-opponent heal byte")
end

return { tests = T }
