-- Field-move standard-script source lowering. Retail oracle: the retail ROM's
-- ScrCmd_CheckEscortMode (reads FLAG_HAVE_FOLLOWER), ScrCmd_StrengthFlagAction
-- (set/clear/check of FLAG_STRENGTH_ACTIVE) and ScrCmd_GetFollowPokePartyIndex
-- (first alive party slot, the same answer as ScrCmd_GetPartyLeadAlive).

local Assert = require("tests.support.Assert")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")

local T = {}

local function lower(instructions)
  local script = { instructions = instructions }
  local member = { scripts = {}, movements = {} }
  return SemanticLowering.lowerScript(script, member, { stdCatalog = {} })
end

local function instruction(opcode, offset, operands)
  return { opcode = opcode, offset = offset, operands = operands or {} }
end

local function raw(value)
  return { raw = value }
end

function T.escort_mode_check_reads_the_follower_flag()
  local lowered = lower({ instruction(299, 0x10, { raw(0x800C) }) })
  Assert.equal(#lowered.unsupported, 0)
  local node = lowered.items[1]
  Assert.equal(node.op, "set_var")
  Assert.deepEqual(node.variable, { value = "var", id = 0x800C })
  Assert.deepEqual(node.value, { value = "flag_value", flag = "FLAG_HAVE_FOLLOWER" })
end

function T.strength_flag_action_modes_use_the_flag_vocabulary()
  local lowered = lower({
    instruction(400, 0x10, { raw(1) }),
    instruction(400, 0x20, { raw(0) }),
    instruction(400, 0x30, { raw(2), raw(0x800C) }),
  })
  Assert.equal(#lowered.unsupported, 0)
  Assert.equal(lowered.items[1].op, "set_flag")
  Assert.equal(lowered.items[1].flag, "FLAG_STRENGTH_ACTIVE")
  Assert.equal(lowered.items[2].op, "clear_flag")
  Assert.equal(lowered.items[2].flag, "FLAG_STRENGTH_ACTIVE")
  Assert.equal(lowered.items[3].op, "set_var")
  Assert.deepEqual(lowered.items[3].variable, { value = "var", id = 0x800C })
  Assert.deepEqual(lowered.items[3].value, { value = "flag_value", flag = "FLAG_STRENGTH_ACTIVE" })
end

function T.follower_party_index_is_the_first_alive_slot_query()
  local lowered = lower({ instruction(727, 0x10, { raw(0x8005) }) })
  Assert.equal(#lowered.unsupported, 0)
  local node = lowered.items[1]
  Assert.equal(node.op, "party_lead_alive")
  Assert.deepEqual(node.result, { value = "var", id = 0x8005 })
end

function T.cut_in_and_effect_commands_lower_to_the_field_move_cue()
  local lowered = lower({
    instruction(183, 0x10, { raw(0x8004) }),
    instruction(560, 0x20, { raw(3), raw(0x8005) }),
  })
  Assert.equal(#lowered.unsupported, 0)
  Assert.equal(lowered.items[1].op, "field_move_cut_in")
  Assert.deepEqual(lowered.items[1].slot, { value = "var", id = 0x8004 })
  Assert.equal(lowered.items[2].op, "field_move_effect")
  Assert.equal(lowered.items[2].effect, 3)
  Assert.deepEqual(lowered.items[2].done, { value = "var", id = 0x8005 })
end

function T.follower_commands_used_by_the_field_move_scripts_lower()
  local lowered = lower({
    instruction(598, 0x10, { raw(1) }),
    instruction(728, 0x20, { raw(16), raw(2) }),
    instruction(730, 0x30, { raw(0x8006) }),
    instruction(731, 0x40, {}),
    instruction(732, 0x50, { raw(20) }),
    instruction(733, 0x60, { raw(12), raw(0x800C) }),
    instruction(734, 0x70, { raw(2) }),
    instruction(851, 0x80, { raw(1) }),
  })
  Assert.equal(#lowered.unsupported, 0)
  local items = lowered.items
  Assert.equal(items[1].op, "follower_swap_with_player")
  Assert.equal(items[2].op, "follower_gesture")
  Assert.equal(items[2].gesture, "flash")
  Assert.equal(items[2].a, 16)
  Assert.equal(items[2].b, 2)
  Assert.equal(items[3].op, "follower_inactive_or_visible")
  Assert.deepEqual(items[3].result, { value = "var", id = 0x8006 })
  Assert.equal(items[4].gesture, "grow_shrink")
  Assert.equal(items[5].op, "follower_add_mood")
  Assert.equal(items[5].amount, 20)
  Assert.equal(items[6].op, "party_lead_has_type")
  Assert.equal(items[6].type, 12)
  Assert.deepEqual(items[6].result, { value = "var", id = 0x800C })
  Assert.equal(items[7].gesture, "jump")
  Assert.equal(items[7].a, 2)
  Assert.equal(items[8].op, "buffer_capitalize")
  Assert.equal(items[8].slot, 1)
end

function T.rock_smash_item_check_and_headbutt_encounter_lower_to_aftermath_operations()
  local lowered = lower({
    instruction(753, 0x10, { raw(0x8007), raw(0x800C), raw(0x8006) }),
    instruction(754, 0x20, { raw(0x800C) }),
  })
  Assert.equal(#lowered.unsupported, 0)
  local check = lowered.items[1]
  Assert.equal(check.op, "rock_smash_item_check")
  Assert.deepEqual(check.followerUsing, { value = "var", id = 0x8007 })
  Assert.deepEqual(check.found, { value = "var", id = 0x800C })
  Assert.deepEqual(check.item, { value = "var", id = 0x8006 })
  local headbutt = lowered.items[2]
  Assert.equal(headbutt.op, "try_headbutt_encounter")
  Assert.deepEqual(headbutt.result, { value = "var", id = 0x800C })
end

function T.follower_recall_and_adjacency_query_lower_for_the_headbutt_scripts()
  local lowered = lower({
    instruction(600, 0x10, {}),
    instruction(829, 0x20, { raw(0x800C) }),
  })
  Assert.equal(#lowered.unsupported, 0)
  Assert.equal(lowered.items[1].op, "follower_recall_to_player")
  Assert.equal(lowered.items[2].op, "follower_is_next_to_player")
  Assert.deepEqual(lowered.items[2].result, { value = "var", id = 0x800C })
end

function T.swap_toward_the_follower_first_stays_unsupported()
  local lowered = lower({ instruction(598, 0x10, { raw(2) }) })
  Assert.equal(#lowered.unsupported, 1)
end

return { tests = T }
