local Assert = require("tests.support.Assert")
local FieldHandlers = require("romdump.src.digest.script.lowering.FieldHandlers")
local ScriptCommands = require("romdump.src.catalog.hgss.script_commands")

local T = {}

local function raw(value)
  return { raw = value }
end

local function instruction(opcode, operands)
  return { opcode = opcode, offset = 12, operands = operands or {} }
end

function T.lifecycle_map_query_and_prop_commands_have_source_dispositions()
  local expected = {
    [102] = { "continue_same_tick", "camera_focus_set" },
    [103] = { "continue_same_tick", "camera_focus_clear" },
    [184] = { "continue_same_tick", "player_on_bike_check" },
    [187] = { "continue_same_tick", "player_state" },
    [590] = { "continue_same_tick", "trainer_card_stars" },
    [292] = { "continue_same_tick", "check_running_shoes" },
    [293] = { "continue_same_tick", "award_running_shoes" },
    [484] = { "continue_same_tick", "weekday" },
    [307] = { "continue_same_tick", "prop_animation_load" },
    [310] = { "continue_same_tick", "prop_animation_play" },
    [311] = { "continue_same_tick", "prop_animation_play" },
    [436] = { "native_wait", "overworld_leave" },
    [446] = { "continue_same_tick", "current_map_id" },
    [561] = { "continue_same_tick", "shake_camera" },
    [759] = { "yield_to_task", "legend_cutscene_lugia_eye_glimmer" },
    [767] = { "continue_same_tick", "legend_cutscene_lugia_arrives_begin" },
    [768] = { "continue_same_tick", "legend_cutscene_lugia_arrives_end" },
    [769] = { "yield_to_task", "legend_cutscene_lugia_arrives_camera_pan" },
    [379] = { "continue_same_tick", "time_of_day" },
    [437] = { "continue_same_tick", "discard_value" },
    [490] = { "continue_same_tick", "discard_value" },
    [810] = { "native_wait", "celebi_time_travel" },
    [487] = { "native_wait", "pokemon_center_heal" },
  }
  for opcode, result in pairs(expected) do
    Assert.equal(ScriptCommands.byOpcode[opcode].classification, result[1])
    local operands
    if opcode == 307 then
      operands = { raw(2), raw(1), raw(5), raw(9), raw(7) }
    elseif opcode == 310 or opcode == 311 or opcode == 446 or opcode == 487 then
      operands = { raw(4) }
    elseif opcode == 184 or opcode == 187 or opcode == 379 or opcode == 590 or opcode == 292 or opcode == 484 then
      operands = { raw("VAR_RESULT") }
    elseif opcode == 437 or opcode == 490 then
      operands = { raw("VAR_TEMP") }
    elseif opcode == 102 then
      operands = { raw("VAR_X"), raw("VAR_Y") }
    elseif opcode == 561 then
      operands = { raw(3), raw(3), raw(15), raw(5) }
    end
    local node = assert(FieldHandlers[opcode])(instruction(opcode, operands))
    Assert.equal(node.op, result[2])
    Assert.isNil(node.command, "source opcode must not leak into semantic operations")
    if opcode == 307 then
      Assert.deepEqual(node.fieldX, { value = "scaled_coordinate", coordinate = 5, chunkOffset = 2 })
      Assert.deepEqual(node.fieldZ, { value = "scaled_coordinate", coordinate = 9, chunkOffset = 1 })
      Assert.equal(node.slot, 7)
    elseif opcode == 561 then
      Assert.equal(node.amplitudeX, 3)
      Assert.equal(node.amplitudeY, 3)
      Assert.equal(node.intervalTicks, 5)
      Assert.equal(node.count, 15)
    elseif opcode == 310 then
      Assert.equal(node.direction, "forward")
    elseif opcode == 311 then
      Assert.equal(node.direction, "reverse")
    elseif opcode == 487 then
      Assert.equal(node.count, 4)
    elseif opcode == 184 or opcode == 187 or opcode == 379 or opcode == 590 or opcode == 292 or opcode == 484 then
      Assert.deepEqual(node.result, { value = "var", id = "VAR_RESULT" })
    elseif opcode == 437 or opcode == 490 then
      Assert.deepEqual(node.value, { value = "var", id = "VAR_TEMP" })
    elseif opcode == 102 then
      Assert.deepEqual(node.fieldX, { value = "var", id = "VAR_X" })
      Assert.deepEqual(node.fieldZ, { value = "var", id = "VAR_Y" })
    end
  end
end

function T.lugia_reveal_commands_lower_to_their_legend_operations()
  local expected = {
    [759] = { op = "legend_cutscene_lugia_eye_glimmer" },
    [767] = { op = "legend_cutscene_lugia_arrives_begin" },
    [768] = { op = "legend_cutscene_lugia_arrives_end" },
    [769] = { op = "legend_cutscene_lugia_arrives_camera_pan" },
  }
  for opcode, node in pairs(expected) do
    Assert.deepEqual(assert(FieldHandlers[opcode])(instruction(opcode)), node)
  end
end

function T.screen_shake_maps_its_four_source_operands()
  local node = assert(FieldHandlers[561])(instruction(561, { raw(3), raw(3), raw(15), raw(5) }))
  Assert.deepEqual(node, {
    op = "shake_camera",
    amplitudeX = 3,
    amplitudeY = 3,
    intervalTicks = 5,
    count = 15,
  })
  local varying = assert(FieldHandlers[561])(instruction(561, { raw(3), raw("VAR_TEMP"), raw(15), raw(5) }))
  Assert.equal(varying.op, "unsupported", "variable shake operands stay explicit")
  Assert.equal(varying.command, 561)
end

function T.whiteout_commands_share_one_blocking_semantic_operation()
  for _, opcode in ipairs({ 219, 279 }) do
    Assert.equal(ScriptCommands.byOpcode[opcode].classification, "native_wait")
    local node = assert(FieldHandlers[opcode])(instruction(opcode))
    Assert.deepEqual(node, { op = "whiteout" })
  end
end

return { tests = T }
