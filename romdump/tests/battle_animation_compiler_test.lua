-- Native command streams are decoded with source cursor widths and semantic
-- selectors. Invalid framing never produces a normalized program.

local Assert = require("tests.support.Assert")

local T = {}

local function compiler()
  return require("romdump.src.digest.battle.BattleAnimationCompiler")
end

local function u32(value)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

function T.dispatch_labels_cover_the_native_table_without_the_guard_overrun()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  Assert.equal(Sources.DISPATCH_EXTENT_BYTES, 0x160, "pinned table byte extent stays explicit")
  Assert.equal(Sources.handlerCount(), 88, "all native table entries have labels")
  Assert.equal(Sources.handlerLabel(0), "ov07_0221C6EC", "first pointer matches the source table")
  Assert.equal(Sources.handlerLabel(87), "ov07_0221D23C", "last pointer matches the source table")
  Assert.isNil(Sources.handlerLabel(88), "the source guard does not invent a table entry")
end

function T.callback_count_controls_cursor_and_resolves_to_semantic_identity()
  local callback = "battle/callback/impact"
  local program = assert(compiler().compile({
    key = "synthetic-callback-block",
    stream = table.concat({ u32(45), u32(7), u32(2), u32(0x11223344), u32(0x55667788), u32(54) }),
    callbacks = { [7] = callback },
  }))
  Assert.equal(#program.instructions, 2, "variable payload words stay inside the callback operation")
  Assert.equal(program.instructions[1].op, "replace-parameters-and-call", "source side effect is preserved")
  Assert.equal(program.instructions[1].callback, callback, "producer selector is resolved before publication")
  Assert.deepEqual(program.instructions[1].values, { 0x11223344, 0x55667788 }, "counted values decode in order")
  Assert.equal(program.instructions[2].op, "noop", "cursor lands at the next source opcode")
  Assert.isNil(program.instructions[2].nativeOpcode, "runtime IR contains no dispatch identity")
end

function T.interpreter_wait_consumes_one_operand_before_the_next_command()
  local program = assert(compiler().compile({
    key = "interpreter-wait-cursor",
    stream = u32(0) .. u32(12) .. u32(9),
  }))
  Assert.equal(#program.instructions, 2, "opcode 0 consumes one operand and leaves the following opcode intact")
  Assert.equal(program.instructions[1].op, "interpreter-wait")
  Assert.deepEqual(program.instructions[1].values, { 12 })
  Assert.equal(program.instructions[2].op, "reset-blend-alpha")
end

function T.parameter_store_outside_the_ten_slots_is_ignored_after_consuming_its_frame()
  local program = assert(compiler().compile({
    key = "out-of-range-parameter-store",
    stream = table.concat({ u32(12), u32(10), u32(123), u32(9) }),
  }))
  Assert.equal(program.instructions[1].op, "noop", "ov07_0221C72C ignores a slot at or above ten")
  Assert.equal(program.instructions[2].op, "reset-blend-alpha", "the store still consumes its two operands")
end

function T.interpreter_counter_wait_preserves_pending_and_zero_cursor_paths()
  local program = assert(compiler().compile({
    key = "interpreter-counter-wait-cursor-paths",
    stream = table.concat({ u32(1), u32(9), u32(12), u32(0), u32(7), u32(54) }),
  }))
  local wait = program.instructions[1]
  Assert.equal(wait.op, "wait-interpreter-counter", "opcode 1 waits on the interpreter counter")
  Assert.equal(
    wait.cursorRule,
    "pending-redispatch-current-opcode; zero-advances-past-current-opcode",
    "ov07_0221C70C redispatches the current opcode while pending and advances past it at zero"
  )
  Assert.equal(wait.branchTarget, 1, "the pending path loops to opcode 1")
  Assert.equal(program.instructions[2].op, "reset-blend-alpha", "the zero-counter path falls through to opcode 9")
  Assert.equal(program.instructions[3].op, "set-parameter", "execution continues with the command after opcode 9")
  Assert.deepEqual(program.instructions[3].values, { 0, 7 }, "the following command operands remain intact")
end

function T.subprogram_call_uses_count_operand_and_returns_to_next_command()
  local program = assert(compiler().compile({
    key = "subprogram-call-cursor",
    stream = table.concat({
      u32(10),
      u32(4),
      u32(12),
      u32(0),
      u32(7),
      u32(9),
      u32(54),
    }),
  }))
  local instructionAtOffset = {}
  for index, offset in ipairs(program.sourceOffsets) do
    instructionAtOffset[offset] = index
  end
  local callIndex = assert(instructionAtOffset[0], "the entry command is retained")
  local call = program.instructions[callIndex]
  Assert.equal(call.op, "call-subprogram")
  Assert.equal(call.branchTarget, instructionAtOffset[20], "the source count selects the subprogram target")
  Assert.isNil(call.alternateTarget, "the operand-word retry is not a reachable instruction edge")
  Assert.equal(call.returnTarget, instructionAtOffset[8], "return resumes immediately after the count operand")
  Assert.equal(
    call.cursorRule,
    "call-first-free-subprogram-slot; all-slots-busy-redispatch-count-word",
    "the dynamic full-stack behavior remains explicit in normalized IR"
  )
  Assert.isNil(instructionAtOffset[4], "the count operand is not traversed as a reachable command")
  Assert.equal(program.instructions[instructionAtOffset[8]].op, "set-parameter")
  Assert.equal(program.instructions[instructionAtOffset[20]].op, "reset-blend-alpha")
end

function T.sound_action_opcode25_consumes_its_source_frame_and_preserves_following_commands()
  local sound = "audio/sequence/test-action-sound"
  local program = compiler().compile({
    key = "sound-action-opcode25-cursor",
    stream = table.concat({
      u32(25),
      u32(7),
      u32(0xFFFFFF85),
      u32(4),
      u32(3),
      u32(9),
      u32(12),
      u32(0),
      u32(7),
      u32(54),
    }),
    sounds = { [7] = sound },
  })
  Assert.equal(#program.instructions, 4, "source cursor resumes at opcode 9 after four opcode25 operands")
  Assert.equal(program.instructions[1].op, "submit-sound-action")
  Assert.equal(program.instructions[1].sound, sound)
  Assert.deepEqual(program.instructions[1].values, { -123, 4, 3 })
  Assert.equal(program.instructions[2].op, "reset-blend-alpha", "the command at byte 20 is dispatched")
  Assert.equal(program.instructions[3].op, "set-parameter", "the command after opcode 9 remains aligned")
  Assert.deepEqual(program.instructions[3].values, { 0, 7 })
  Assert.equal(program.instructions[4].op, "noop", "opcode54 after opcode12 is dispatched")
end

function T.sound_action_opcode26_consumes_its_source_frame_and_preserves_following_commands()
  local sound = "audio/sequence/test-delayed-sound"
  local program = compiler().compile({
    key = "sound-action-opcode26-operands",
    stream = table.concat({
      u32(26),
      u32(7),
      u32(0xFFFFFF8B),
      u32(13),
      u32(9),
      u32(12),
      u32(0),
      u32(7),
      u32(54),
    }),
    sounds = { [7] = sound },
  })
  Assert.equal(#program.instructions, 4, "opcode26 consumes its sound and two modifier words")
  Assert.equal(program.instructions[1].sound, sound)
  Assert.deepEqual(program.instructions[1].values, { -117, 13 })
  Assert.equal(program.instructions[2].op, "reset-blend-alpha", "the command at byte 16 is dispatched")
  Assert.equal(program.instructions[3].op, "set-parameter")
  Assert.deepEqual(program.instructions[3].values, { 0, 7 })
  Assert.equal(program.instructions[4].op, "noop")
end

function T.brightness_transition_consumes_one_word_and_preserves_following_commands()
  local program = compiler().compile({
    key = "brightness-transition-cursor",
    stream = table.concat({ u32(85), u32(0x1234), u32(9), u32(12), u32(0), u32(7), u32(54) }),
  })
  Assert.equal(#program.instructions, 4, "opcode85 advances over its selector to opcode 9")
  Assert.equal(program.instructions[1].op, "start-brightness-transition")
  Assert.deepEqual(program.instructions[1].values, { 0x34 })
  Assert.equal(program.instructions[2].op, "reset-blend-alpha", "the command at byte 8 is dispatched")
  Assert.equal(program.instructions[3].op, "set-parameter")
  Assert.deepEqual(program.instructions[3].values, { 0, 7 })
  Assert.equal(program.instructions[4].op, "noop")
end

function T.sound_motion_handlers_leave_the_next_dispatch_after_five_payload_words()
  local cases = { 24, 35, 36 }
  for _, opcode in ipairs(cases) do
    local program = assert(compiler().compile({
      key = "sound-motion-cursor-" .. opcode,
      stream = table.concat({
        u32(opcode),
        u32(7),
        u32(1),
        u32(2),
        u32(3),
        u32(4),
        u32(54),
      }),
      sounds = { [7] = "audio/sequence/test-motion" },
    }))
    Assert.equal(#program.instructions, 2, "opcode " .. opcode .. " consumes five source operands")
    Assert.equal(program.instructions[1].op, "submit-sound-action")
    Assert.equal(program.instructions[2].op, "noop", "opcode " .. opcode .. " leaves the next dispatch intact")
  end
end

function T.tackle_callback_selectors_resolve_to_typed_semantic_tasks()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plans = {
    {
      selector = 78,
      operands = { 78, 1, 0 },
      callback = "managed-sprite-frame-loop",
      task = "managed-sprite-draw-loop",
    },
    { selector = 57, operands = { 57, 4, 2, 14, 0xfffffff8, 258 }, callback = "pokemon-picture-offset-transition" },
    { selector = 36, operands = { 36, 5, 1, 0, 1, 2, 264 }, callback = "battle-background-position-transition" },
  }
  for _, expected in ipairs(plans) do
    local plan = assert(Sources.resolveSourceSelection("battle-animation-callback", expected.operands))
    Assert.equal(plan.callback, expected.callback, "native callback selector maps to a semantic callback key")
    Assert.isNil(plan.selector, "native selector is producer-only")
    Assert.isNil(plan.address, "native callback address is producer-only")
    if expected.task ~= nil then
      Assert.equal(plan.taskKind, expected.task)
    end
    Assert.isTrue(type(plan.parameters) == "table", "callback words normalize into typed task parameters")
  end
  local unresolved = Sources.resolveSourceSelection("battle-animation-callback", { 45, 0 })
  Assert.isNil(unresolved, "unmapped callback selectors remain closed")

  local program = compiler().compile({
    key = "tackle-callbacks",
    stream = table.concat({
      u32(45),
      u32(78),
      u32(1),
      u32(0),
      u32(45),
      u32(57),
      u32(4),
      u32(2),
      u32(14),
      u32(0xfffffff8),
      u32(258),
      u32(45),
      u32(36),
      u32(5),
      u32(1),
      u32(0),
      u32(1),
      u32(2),
      u32(264),
    }),
    resolveSourceInput = function(role, operands)
      return Sources.resolveSourceSelection(role, operands)
    end,
  })
  Assert.equal(program.instructions[1].op, "invoke-battle-animation-callback")
  Assert.equal(program.instructions[1].callback, "managed-sprite-frame-loop")
  Assert.equal(program.instructions[1].parameters.frameTicks, 3, "zero selects the source default frame count")
  Assert.deepEqual(program.instructions[2].parameters, {
    pictureTarget = "active-battler",
    durationTicks = 2,
    offsetX = 14,
    offsetY = -8,
  })
  Assert.deepEqual(program.instructions[3].parameters, {
    offsetX = 1,
    offsetY = 0,
    ticksPerStep = 1,
    steps = 2,
    pictureSets = { "opposing-battler" },
    pictureAttributeOffset = true,
    managedSpriteOffset = false,
    backgroundPositionEnabled = false,
  })
end

function T.newly_observed_picture_callbacks_lower_to_typed_semantic_tasks()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local cases = {
    {
      operands = { 11, 2, 99, 77 },
      callback = "pokemon-picture-scale-position-transition",
      taskKind = "pokemon-picture-scale-position-transition",
    },
    {
      operands = { 18, 1, 25 },
      callback = "pokemon-picture-palette-fade",
      taskKind = "pokemon-picture-palette-fade",
    },
    {
      operands = { 55, 0 },
      callback = "pokemon-picture-vanish-affine-transition",
      taskKind = "pokemon-picture-vanish-affine-transition",
    },
    {
      operands = { 47, 0 },
      callback = "pokemon-picture-height-position-transition",
      taskKind = "pokemon-picture-height-position-transition",
    },
    {
      operands = { 56, 0 },
      callback = "battle-sprite-affine-appearance-transition",
      taskKind = "battle-sprite-affine-appearance-transition",
      context = "battle-sprite",
    },
    {
      operands = { 58, 0 },
      callback = "pokemon-picture-three-sprite-position-wave-transition",
      taskKind = "pokemon-picture-three-sprite-position-wave-transition",
    },
    {
      operands = { 43, 0 },
      callback = "pokemon-picture-reciprocal-position-palette-transition",
      taskKind = "pokemon-picture-reciprocal-position-palette-transition",
    },
    {
      operands = { 50, 2, 3, 12 },
      callback = "pokemon-picture-repeated-vanish-transition",
      taskKind = "pokemon-picture-repeated-vanish-transition",
      parameters = { toggleCount = 6, intervalTicks = 12 },
    },
    {
      operands = { 69, 4, 2, 0xfffe, 4, 12 },
      callback = "battle-sprite-mosaic-transition",
      taskKind = "battle-sprite-mosaic-transition",
      context = "battle-sprite",
      parameters = {
        spriteContextSlot = 2,
        step = -2,
        initialHorizontal = 4,
        initialVertical = 12,
        durationTicks = 3,
      },
    },
  }
  for _, expected in ipairs(cases) do
    local plan = Sources.resolveSourceSelection("battle-animation-callback", expected.operands)
    Assert.equal(plan.callback, expected.callback, "source callback maps to a named picture action")
    Assert.equal(plan.taskKind, expected.taskKind, "picture action selects an executable task kind")
    Assert.equal(plan.context, expected.context or "pokemon-picture", "source body declares its semantic context")
    Assert.deepEqual(
      plan.parameters,
      expected.parameters or {},
      "callback context words are reduced to source-named parameters"
    )
  end
  local invalidMosaicSlot = Sources.resolveSourceSelection("battle-animation-callback", { 69, 1, 5 })
  Assert.isNil(invalidMosaicSlot, "native mosaic helper asserts for sprite context slots above four")
  local invalidMosaicStep = Sources.resolveSourceSelection("battle-animation-callback", { 69, 4, 1, 0, 4, 4 })
  Assert.isNil(invalidMosaicStep, "a zero mosaic step never terminates so the producer rejects it")

  local program = compiler().compile({
    key = "picture-callbacks",
    stream = table.concat({
      u32(45),
      u32(11),
      u32(0),
      u32(45),
      u32(18),
      u32(0),
      u32(45),
      u32(55),
      u32(0),
      u32(45),
      u32(47),
      u32(0),
      u32(45),
      u32(56),
      u32(0),
      u32(45),
      u32(58),
      u32(0),
      u32(45),
      u32(43),
      u32(0),
      u32(45),
      u32(50),
      u32(2),
      u32(3),
      u32(12),
      u32(45),
      u32(69),
      u32(4),
      u32(2),
      u32(0xfffe),
      u32(4),
      u32(12),
    }),
    resolveSourceInput = function(role, operands)
      return Sources.resolveSourceSelection(role, operands)
    end,
  })
  Assert.equal(program.instructions[1].taskKind, "pokemon-picture-scale-position-transition")
  Assert.equal(program.instructions[2].taskKind, "pokemon-picture-palette-fade")
  Assert.equal(program.instructions[3].callback, "pokemon-picture-vanish-affine-transition")
  Assert.equal(program.instructions[3].taskContext, "pokemon-picture")
  Assert.deepEqual(program.instructions[3].parameters, {})
  Assert.equal(program.instructions[4].callback, "pokemon-picture-height-position-transition")
  Assert.deepEqual(program.instructions[4].parameters, {})
  Assert.equal(program.instructions[5].callback, "battle-sprite-affine-appearance-transition")
  Assert.equal(program.instructions[5].taskContext, "battle-sprite")
  Assert.deepEqual(program.instructions[5].parameters, {})
  Assert.equal(program.instructions[6].callback, "pokemon-picture-three-sprite-position-wave-transition")
  Assert.deepEqual(program.instructions[6].parameters, {})
  Assert.equal(program.instructions[7].callback, "pokemon-picture-reciprocal-position-palette-transition")
  Assert.deepEqual(program.instructions[7].parameters, {})
  Assert.equal(program.instructions[8].callback, "pokemon-picture-repeated-vanish-transition")
  Assert.deepEqual(program.instructions[8].parameters, { toggleCount = 6, intervalTicks = 12 })
  Assert.equal(program.instructions[9].callback, "battle-sprite-mosaic-transition")
  Assert.deepEqual(program.instructions[9].parameters, {
    spriteContextSlot = 2,
    step = -2,
    initialHorizontal = 4,
    initialVertical = 12,
    durationTicks = 3,
  })
  Assert.isNil(program.instructions[1].selector, "callback selector stays out of normalized IR")
end

function T.picture_entry_callback_normalizes_to_its_visibility_transition()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = Sources.resolveBattleAnimationCallback({ 23, 0 })
  Assert.deepEqual(plan, {
    callback = "pokemon-picture-vanish-and-restore-transition",
    taskKind = "pokemon-picture-vanish-and-restore-transition",
    context = "pokemon-picture",
    parameters = {},
  })
end

function T.target_picture_priority_callback_has_a_closed_transition_task()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan, reason = Sources.resolveBattleAnimationCallback({ 79, 0 })
  Assert.isNil(reason)
  Assert.deepEqual(plan, {
    callback = "pokemon-picture-target-priority-transition",
    taskKind = "pokemon-picture-target-priority-transition",
    context = "pokemon-picture",
    battlerTarget = "target",
    parameters = {},
  })
end

function T.target_picture_bg_slide_callback_has_a_closed_transition_task()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan, reason = Sources.resolveBattleAnimationCallback({ 37, 0 })
  Assert.isNil(reason)
  Assert.deepEqual(plan, {
    callback = "pokemon-picture-target-background-slide",
    taskKind = "pokemon-picture-target-background-slide",
    context = "battle-display",
    battlerTarget = "target",
    parameters = {},
  })
end

function T.battler_blend_alpha_callback_normalizes_its_sprite_and_timing_inputs()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan, reason = Sources.resolveBattleAnimationCallback({ 38, 6, 5, 2, 10, 4, 6, 12 })
  Assert.isNil(reason)
  Assert.deepEqual(plan, {
    callback = "battle-sprite-blend-alpha-transition",
    taskKind = "battle-sprite-blend-alpha-transition",
    context = "battle-display",
    parameters = {
      oamModeSpriteSlots = { "sprite-context-slot-0", "sprite-context-slot-2" },
      startCoefficientA = 2,
      targetCoefficientA = 10,
      startCoefficientB = 4,
      targetCoefficientB = 12,
      durationTicks = 6,
    },
  })
  local program = assert(compiler().compile({
    key = "battler-blend-alpha-callback",
    stream = table.concat({ u32(45), u32(38), u32(6), u32(5), u32(2), u32(10), u32(4), u32(6), u32(12) }),
    resolveSourceInput = function(role, operands)
      return Sources.resolveSourceSelection(role, operands)
    end,
  }))
  Assert.equal(program.instructions[1].taskKind, "battle-sprite-blend-alpha-transition")
  Assert.isNil(program.instructions[1].selector)
end

function T.paired_picture_transition_normalizes_its_source_selected_picture_sets()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plans = {
    { operands = { 71, 1, 0x40 }, pictureSets = { "all-battler-positions" } },
    { operands = { 71, 1, 0x20 }, pictureSets = { "other-battler-positions" } },
    { operands = { 71, 1, 0x0a }, pictureSets = { "active-battler", "opposing-battler" } },
  }
  for _, test in ipairs(plans) do
    local plan, reason = Sources.resolveBattleAnimationCallback(test.operands)
    Assert.isNil(reason)
    Assert.deepEqual(plan, {
      callback = "pokemon-picture-selected-pair-transition",
      taskKind = "pokemon-picture-selected-pair-transition",
      context = "pokemon-picture",
      parameters = { pictureSets = test.pictureSets },
    })
  end
end

function T.picture_affine_blend_callback_has_its_contextual_task_contract()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan, reason = Sources.resolveBattleAnimationCallback({ 70, 0 })
  Assert.isNil(reason)
  Assert.deepEqual(plan, {
    callback = "pokemon-picture-affine-blend-palette-transition",
    taskKind = "pokemon-picture-affine-blend-palette-transition",
    context = "battle-display",
    parameters = {},
  })
end

function T.background_picture_scroll_callback_preserves_its_two_source_modes()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plans = {
    {
      operands = { 27, 6, 0, 1, 4, 99, 88, 77 },
      callback = "battle-background-picture-scroll-oscillation",
      taskKind = "battle-background-picture-scroll-oscillation",
      parameters = { directionState = 1, phaseIndex = 4 },
    },
    {
      operands = { 27, 6, 1, 0xfffe, 3, 0xfffc, 7, 77 },
      callback = "battle-background-picture-coordinate-sweep",
      taskKind = "battle-background-picture-coordinate-sweep",
      parameters = { startX = -2, startY = 3, deltaX = -4, deltaY = 7 },
    },
  }
  for _, expected in ipairs(plans) do
    local plan = Sources.resolveSourceSelection("battle-animation-callback", expected.operands)
    Assert.deepEqual(plan, {
      callback = expected.callback,
      taskKind = expected.taskKind,
      context = "battle-display",
      parameters = expected.parameters,
    }, "selector 27 normalizes only the fields used by the selected continuation")
  end
  local program = compiler().compile({
    key = "background-picture-scroll-callback",
    stream = table.concat({ u32(45), u32(27), u32(6), u32(1), u32(0xfffe), u32(3), u32(0xfffc), u32(7), u32(77) }),
    resolveSourceInput = function(role, operands)
      return Sources.resolveSourceSelection(role, operands)
    end,
  })
  Assert.equal(program.instructions[1].callback, "battle-background-picture-coordinate-sweep")
  Assert.equal(program.instructions[1].taskKind, "battle-background-picture-coordinate-sweep")
  Assert.deepEqual(program.instructions[1].parameters, plans[2].parameters)
  Assert.isNil(program.instructions[1].selector, "native callback selector remains producer-only")
end

function T.vanished_picture_callback_lowers_source_masks_to_named_picture_sets()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local cases = {
    { mask = 0x40, pictureSets = { "all-battler-positions" } },
    { mask = 0x20, pictureSets = { "other-battler-positions" } },
    { mask = 0x02, pictureSets = { "active-battler" } },
    { mask = 0x04, pictureSets = { "active-battler-pair-when-enabled" } },
    { mask = 0x08, pictureSets = { "opposing-battler" } },
    { mask = 0x10, pictureSets = { "opposing-battler-pair-when-enabled" } },
    {
      mask = 0x0a,
      pictureSets = { "active-battler", "opposing-battler" },
    },
  }
  for _, expected in ipairs(cases) do
    local resolved = Sources.resolveBattleAnimationCallback({ 40, 2, expected.mask, 1 })
    Assert.deepEqual(resolved, {
      op = "set-pokemon-picture-vanished",
      pictureSets = expected.pictureSets,
      vanished = true,
    }, "selector40 masks map to source-derived semantic battler picture sets")
    local program = assert(compiler().compile({
      key = "vanished-picture-callback",
      stream = table.concat({ u32(45), u32(40), u32(2), u32(expected.mask), u32(1) }),
      resolveSourceInput = function(role, operands)
        if role == "battle-animation-callback" then
          return Sources.resolveBattleAnimationCallback(operands)
        end
      end,
    }))
    Assert.deepEqual(program.instructions[1], {
      op = "set-pokemon-picture-vanished",
      pictureSets = expected.pictureSets,
      vanished = true,
    }, "the synchronous setter is a direct semantic operation")
  end
end

function T.battler_picture_affine_sprite_pair_callback_has_a_typed_task()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = Sources.resolveSourceSelection("battle-animation-callback", { 32, 0 })
  Assert.deepEqual(plan, {
    callback = "pokemon-picture-managed-sprite-affine-pair-transition",
    taskKind = "pokemon-picture-managed-sprite-affine-pair-transition",
    context = "pokemon-picture",
    parameters = {},
  }, "selector 32 lowers its two-picture sprite transition without unused callback words")
  local program = compiler().compile({
    key = "picture-affine-pair-callback",
    stream = u32(45) .. u32(32) .. u32(0),
    resolveSourceInput = function(role, operands)
      return Sources.resolveSourceSelection(role, operands)
    end,
  })
  Assert.equal(program.instructions[1].taskKind, "pokemon-picture-managed-sprite-affine-pair-transition")
  Assert.isNil(program.instructions[1].selector)
end

function T.palette_and_picture_fade_callback_has_its_own_semantic_task()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan, reason = Sources.resolveSourceSelection("battle-animation-callback", { 15, 0 })
  Assert.isNil(reason)
  Assert.deepEqual(plan, {
    callback = "pokemon-picture-and-battle-palette-fade-cycle",
    taskKind = "pokemon-picture-and-battle-palette-fade-cycle",
    context = "battle-palette",
    parameters = {},
  })
end

function T.palette_fade_callback_decodes_its_context_and_fixed_buffer_targets()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local contextual, reason = Sources.resolveBattleAnimationCallback({ 33, 5, 0, 1, 0, 12, 0 })
  Assert.isNil(reason)
  Assert.deepEqual(contextual, {
    callback = "pokemon-picture-and-battle-palette-fade",
    taskKind = "pokemon-picture-and-battle-palette-fade",
    context = "battle-palette",
    parameters = {
      paletteTarget = "battle-animation-palette-target",
      wait = 1,
      startCoefficient = 0,
      endCoefficient = 12,
      nextColor = 0,
    },
  }, "mode zero uses the typed battle-animation palette target")

  local mainExtraZero = Sources.resolveBattleAnimationCallback({ 33, 5, 1, 1, 0, 12, 0 })
  Assert.equal(mainExtraZero.parameters.paletteTarget, "main-extra-background-0")
  local mainExtraOne = Sources.resolveBattleAnimationCallback({ 33, 5, 2, 1, 0, 12, 0 })
  Assert.equal(mainExtraOne.parameters.paletteTarget, "main-extra-background-1")
  local invalid, invalidReason = Sources.resolveBattleAnimationCallback({ 33, 5, 3, 1, 0, 12, 0 })
  Assert.isNil(invalid, "unsupported target mode follows the source assertion")
  Assert.equal(invalidReason, "palette fade callback follows its source assertion path")

  local program = assert(compiler().compile({
    key = "palette-fade-callback",
    stream = table.concat({ u32(45), u32(33), u32(5), u32(0), u32(1), u32(0), u32(12), u32(0) }),
    resolveSourceInput = function(role, operands)
      return Sources.resolveSourceSelection(role, operands)
    end,
  }))
  Assert.equal(program.instructions[1].taskKind, "pokemon-picture-and-battle-palette-fade")
  Assert.deepEqual(program.instructions[1].parameters, contextual.parameters)
  Assert.isNil(program.instructions[1].selector, "the native callback selector stays producer-only")
  Assert.isTrue(require("libs.assets.src.battle.BattleAnimationSchema").assertProgram({
    entry = program.entry,
    instructions = program.instructions,
    subprograms = program.subprograms,
    taskKinds = program.taskKinds,
  }))
  local invalidInstruction = {}
  for field, value in pairs(program.instructions[1]) do
    invalidInstruction[field] = value
  end
  invalidInstruction.parameters = {}
  for field, value in pairs(program.instructions[1].parameters) do
    invalidInstruction.parameters[field] = value
  end
  invalidInstruction.parameters.paletteTarget = 0x100
  local valid = pcall(require("libs.assets.src.battle.BattleAnimationSchema").assertProgram, {
    entry = program.entry,
    instructions = { invalidInstruction, program.instructions[2] },
    subprograms = program.subprograms,
    taskKinds = program.taskKinds,
  })
  Assert.isFalse(valid, "raw palette buffer masks cannot pass the normalized callback schema")
end

function T.supersonic_particle_path_callback_lowers_its_emitter_and_timing_context()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan, reason = Sources.resolveBattleAnimationCallback({ 65, 6, 1, 0, 0, 0, 14, 64 })
  Assert.isNil(reason)
  Assert.deepEqual(plan, {
    callback = "battle-particle-emitter-battler-path",
    taskKind = "battle-particle-emitter-battler-path",
    context = "battle-particle-emitter",
    parameters = {
      spriteContextSlot = 1,
      offsetX = 0,
      offsetY = 0,
      leadingInterpolationSteps = 0,
      sinePeriodDivisor = 14,
      interpolationDurationTicks = 64,
      pairOrder = "attacker-target",
      initialInterpolationSteps = 0,
      completionLimit = 255,
      sinusoidalOffset = false,
    },
  }, "callback words retain their typed sprite context and normalized interpolation controls")

  local program = assert(compiler().compile({
    key = "supersonic-particle-path",
    stream = table.concat({ u32(45), u32(65), u32(6), u32(1), u32(0), u32(0), u32(0), u32(14), u32(64), u32(54) }),
    resolveSourceInput = function(role, operands)
      return Sources.resolveSourceSelection(role, operands)
    end,
  }))
  Assert.equal(program.instructions[1].taskKind, "battle-particle-emitter-battler-path")
  Assert.isNil(program.instructions[1].selector, "callback selector stays producer-only")
  Assert.equal(program.instructions[1].parameters.spriteContextSlot, 1)
  Assert.equal(program.instructions[1].parameters.interpolationDurationTicks, 64)
  Assert.equal(program.instructions[2].op, "noop", "the count-framed callback leaves the following opcode intact")
  Assert.isTrue(require("libs.assets.src.battle.BattleAnimationSchema").assertProgram({
    entry = program.entry,
    instructions = program.instructions,
    subprograms = program.subprograms,
    taskKinds = program.taskKinds,
  }))

  local contextual = Sources.resolveBattleAnimationCallback({
    65,
    9,
    1,
    0,
    0,
    0,
    14,
    64,
    1,
    0x00030005,
    1,
  })
  Assert.deepEqual(contextual.parameters, {
    spriteContextSlot = 1,
    offsetX = 0,
    offsetY = 0,
    leadingInterpolationSteps = 0,
    sinePeriodDivisor = 14,
    interpolationDurationTicks = 64,
    pairOrder = "target-attacker",
    initialInterpolationSteps = 3,
    completionLimit = 5,
    sinusoidalOffset = true,
  }, "optional source words select the typed position order and timing behavior")

  local invalid, invalidReason = Sources.resolveBattleAnimationCallback({ 65, 7, 1, 0, 0, 0, 14, 64, 2 })
  Assert.isNil(invalid)
  Assert.equal(invalidReason, "particle emitter path callback has an invalid battler pair order")
end

function T.four_sprite_picture_wave_callback_has_a_named_task()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan, reason = Sources.resolveSourceSelection("battle-animation-callback", { 7, 1, 0 })
  Assert.isNil(reason)
  Assert.deepEqual(plan, {
    callback = "pokemon-picture-four-sprite-wave-transition",
    taskKind = "pokemon-picture-four-sprite-wave-transition",
    context = "pokemon-picture",
    parameters = {},
  })
end

function T.picture_position_offset_callback_maps_each_source_mode_and_rejects_assertion_modes()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local cases = {
    { mode = 258, target = "active-battler" },
    { mode = 260, target = "active-battler-pair-when-enabled" },
    { mode = 264, target = "opposing-battler" },
    { mode = 272, target = "opposing-battler-pair-when-enabled" },
  }
  for _, case in ipairs(cases) do
    local plan, reason = Sources.resolveSourceSelection("battle-animation-callback", { 52, 3, 8, 0xFFFE, case.mode })
    Assert.isNil(reason)
    Assert.deepEqual(plan, {
      callback = "pokemon-picture-selected-position-offset-transition",
      taskKind = "pokemon-picture-selected-position-offset-transition",
      context = "pokemon-picture",
      parameters = {
        pictureTarget = case.target,
        durationTicks = 8,
        signedOffset = -2,
      },
    })
  end
  local invalid, reason = Sources.resolveSourceSelection("battle-animation-callback", { 52, 3, 8, 2, 257 })
  Assert.isNil(invalid)
  Assert.equal(reason, "picture position-offset callback follows its source assertion path")
  local program = assert(compiler().compile({
    key = "selected-picture-position-offset",
    stream = table.concat({ u32(45), u32(52), u32(3), u32(8), u32(0xFFFE), u32(260) }),
    resolveSourceInput = function(role, operands)
      return Sources.resolveSourceSelection(role, operands)
    end,
  }))
  Assert.equal(program.instructions[1].op, "invoke-battle-animation-callback")
  Assert.deepEqual(program.instructions[1].parameters, {
    pictureTarget = "active-battler-pair-when-enabled",
    durationTicks = 8,
    signedOffset = -2,
  })
  Assert.isTrue(require("libs.assets.src.battle.BattleAnimationSchema").assertProgram({
    entry = program.entry,
    instructions = program.instructions,
    subprograms = program.subprograms,
    taskKinds = program.taskKinds,
  }))
end

function T.synchronous_palette_callback_lowers_its_two_fixed_buffer_operations()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local cases = {
    { words = {}, op = "copy-main-background-palette-to-fade-buffer" },
    { words = { 1 }, op = "grayscale-main-background-fade-buffer" },
    { words = { 0, 0xFFFFFFFF }, op = "copy-main-background-palette-to-fade-buffer" },
  }
  for _, case in ipairs(cases) do
    local streamWords = { 45, 74, #case.words }
    for _, word in ipairs(case.words) do
      streamWords[#streamWords + 1] = word
    end
    local stream = {}
    for _, word in ipairs(streamWords) do
      stream[#stream + 1] = u32(word)
    end
    local program = assert(compiler().compile({
      key = "synchronous-palette-operation",
      stream = table.concat(stream),
      resolveSourceInput = function(role, operands)
        return Sources.resolveSourceSelection(role, operands)
      end,
    }))
    Assert.equal(program.instructions[1].op, case.op, "callback selector resolves to its immediate palette operation")
    Assert.equal(#program.instructions, 1, "the counted callback frame is consumed exactly once")
    Assert.isNil(program.instructions[1].callback, "the synchronous operation has no runtime callback key")
  end
end

function T.picture_rotation_callback_normalizes_target_and_rotation_fields()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan, reason = Sources.resolveSourceSelection("battle-animation-callback", { 4, 3, 0xFFFF, 0xF942, 2 })
  Assert.isNil(reason)
  Assert.deepEqual(plan, {
    callback = "pokemon-picture-z-rotation-target-derived-pivot",
    taskKind = "pokemon-picture-z-rotation-transition",
    context = "pokemon-picture",
    battlerTarget = "target",
    parameters = {
      startAngle = 0xFFFF,
      targetAngle = 0xF942,
      durationTicks = 2,
      reverseDirection = false,
    },
  })
  local explicitPivotPlan =
    assert(Sources.resolveSourceSelection("battle-animation-callback", { 4, 6, 0x10002, 3, 1, 1, 0xFFFE, 7 }))
  Assert.deepEqual(explicitPivotPlan, {
    callback = "pokemon-picture-z-rotation-attacker-explicit-pivot",
    taskKind = "pokemon-picture-z-rotation-transition",
    context = "pokemon-picture",
    battlerTarget = "attacker",
    parameters = {
      startAngle = 2,
      targetAngle = 3,
      durationTicks = 1,
      reverseDirection = false,
      pivotX = -2,
      pivotY = 7,
    },
  })
end

function T.paired_picture_interpolation_callback_lowers_source_context_and_motion_fields()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan, reason =
    Sources.resolveSourceSelection("battle-animation-callback", { 73, 6, 6, 2, 1, 0xFFFE, 0x0003, 0x00040005 })
  Assert.isNil(reason)
  Assert.deepEqual(plan, {
    callback = "pokemon-picture-paired-position-interpolation-target",
    taskKind = "pokemon-picture-paired-position-interpolation",
    context = "pokemon-picture",
    battlerTarget = "target",
    parameters = {
      spriteContextSlot = 6,
      reverseEndpoints = true,
      endpointX = -2,
      endpointY = 3,
      initialSteps = 4,
      stepIntervalTicks = 5,
    },
  })

  local program, compileReason = compiler().compile({
    key = "paired-picture-interpolation",
    stream = table.concat({ u32(45), u32(73), u32(6), u32(6), u32(2), u32(1), u32(0xFFFE), u32(3), u32(0x00040005) }),
    resolveSourceInput = function(role, operands)
      return Sources.resolveSourceSelection(role, operands)
    end,
  })
  Assert.isNil(compileReason)
  Assert.equal(program.instructions[1].callback, "pokemon-picture-paired-position-interpolation-target")
  Assert.deepEqual(program.instructions[1].parameters, plan.parameters)
  Assert.isNil(program.instructions[1].selector, "native callback selector remains source-only")

  local fiveArgumentPlan =
    assert(Sources.resolveSourceSelection("battle-animation-callback", { 73, 5, 0, 1, 0, 10, 4 }))
  Assert.deepEqual(fiveArgumentPlan.parameters, {
    spriteContextSlot = 0,
    reverseEndpoints = false,
    endpointX = 10,
    endpointY = 4,
    initialSteps = 0,
    stepIntervalTicks = 0,
  }, "the native callback frame zero-fills omitted context words")
end

function T.randomized_picture_motion_selects_the_source_attacker_or_target()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local cases = {
    { operands = { 26, 0 }, battlerTarget = "target" },
    { operands = { 26, 1, 0 }, battlerTarget = "target" },
    { operands = { 26, 1, 1 }, battlerTarget = "attacker" },
    { operands = { 26, 1, 0xffffffff }, battlerTarget = "attacker" },
    { operands = { 26, 2, 1, 0 }, battlerTarget = "attacker" },
  }
  for _, expected in ipairs(cases) do
    local plan = Sources.resolveSourceSelection("battle-animation-callback", expected.operands)
    Assert.equal(plan.taskKind, "pokemon-picture-randomized-position-motion")
    Assert.equal(plan.battlerTarget, expected.battlerTarget, "selector chooses the copied attacker/target battler ID")
    Assert.deepEqual(plan.parameters, {}, "randomized motion reads live battler state, not extra callback words")
  end

  local stream = table.concat({ u32(45), u32(26), u32(1), u32(0), u32(45), u32(26), u32(1), u32(1) })
  local program = compiler().compile({
    key = "randomized-picture-motion",
    stream = stream,
    resolveSourceInput = function(role, operands)
      return Sources.resolveSourceSelection(role, operands)
    end,
  })
  Assert.equal(program.instructions[1].battlerTarget, "target")
  Assert.equal(program.instructions[2].battlerTarget, "attacker")
  Assert.isNil(program.instructions[1].values, "native selector operands do not escape into runtime IR")
end

function T.battler_motion_callbacks_lower_to_their_native_tasks()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  -- DefenderKnockback (MEGAHORN) reads no source words: a five-tick
  -- linear displacement (one dispatch tick plus four motion ticks), a
  -- seventeen-tick shake (sixteen motion ticks plus the transition tick),
  -- and a five-tick return plus the snap tick keep the defender's
  -- picture busy for 29 ticks.
  local knockback = Sources.resolveBattleAnimationCallback({ 48, 0 })
  Assert.deepEqual(knockback, {
    callback = "pokemon-picture-defender-knockback",
    taskKind = "pokemon-picture-defender-knockback",
    context = "pokemon-picture",
    battlerTarget = "target",
    parameters = { durationTicks = 29 },
  })
  -- AttackerDashAfterimages (SHADOW_PUNCH) carries one source word the
  -- native body never reads; its out leg (eight ticks) and back leg
  -- (nine ticks) plus the two dispatch ticks run 20 ticks.
  local dash = Sources.resolveBattleAnimationCallback({ 59, 1, 0 })
  Assert.deepEqual(dash, {
    callback = "pokemon-picture-attacker-dash-afterimages",
    taskKind = "pokemon-picture-attacker-dash-afterimages",
    context = "pokemon-picture",
    battlerTarget = "attacker",
    parameters = { durationTicks = 20 },
  })
  -- MoveBattlerLinear (WHIRLWIND, ROAR) slides the defender offscreen
  -- over its duration word; the foe exits toward its own side.
  local linear = Sources.resolveBattleAnimationCallback({ 61, 2, 8, 20 })
  Assert.deepEqual(linear, {
    callback = "pokemon-picture-linear-offscreen-transition",
    taskKind = "pokemon-picture-linear-offscreen-transition",
    context = "pokemon-picture",
    parameters = {
      durationTicks = 20,
      offscreenDistance = 144,
      exitOwnSide = true,
      pictureTarget = "target",
    },
  })
  local linearAttacker = Sources.resolveBattleAnimationCallback({ 61, 2, 2, 20 })
  Assert.equal(
    linearAttacker.parameters.pictureTarget,
    "attacker",
    "attacker roles slide their own side too"
  )
  -- ResetBattlerPosition (WHIRLWIND, ROAR) snaps the role home at once:
  -- a validated marker with no timing boundary.
  local reset = Sources.resolveBattleAnimationCallback({ 62, 1, 8 })
  Assert.deepEqual(reset, {
    callback = "pokemon-picture-reset-position-transition",
    taskKind = "pokemon-picture-reset-position-transition",
    context = "pokemon-picture",
    parameters = { pictureTarget = "target" },
  })
  local badLinear, badLinearReason = Sources.resolveBattleAnimationCallback({ 61, 2, 0, 20 })
  Assert.isNil(badLinear, "a role outside the native flag set slides nowhere")
  Assert.equal(
    badLinearReason,
    "linear offscreen callback follows its source assertion path",
    "the unhandled role stays loud"
  )
  local badKnockback, _ = Sources.resolveBattleAnimationCallback({ 48, 1, 0 })
  Assert.isNil(badKnockback, "knockback reads no source words")
  local badDash, _ = Sources.resolveBattleAnimationCallback({ 59, 0 })
  Assert.isNil(badDash, "the dash trailer word is mandatory framing")
  local badReset, _ = Sources.resolveBattleAnimationCallback({ 62, 2, 8, 0 })
  Assert.isNil(badReset, "reset reads exactly its role word")
end

function T.battle_sprite_panel_callbacks_lower_to_typed_offsets()  local Sources = require("romdump.src.config.BattleAnimationSources")
  local cases = {
    { selector = 80, callback = "battle-sprite-panel-slide-down", offsetY = 3 },
    { selector = 81, callback = "battle-sprite-panel-slide-up", offsetY = -3 },
    { selector = 82, callback = "battle-sprite-panel-slide-down", offsetY = 3 },
    { selector = 83, callback = "battle-sprite-panel-slide-far-up", offsetY = -6 },
  }
  for _, expected in ipairs(cases) do
    local plan = Sources.resolveSourceSelection("battle-animation-callback", { expected.selector, 0 })
    Assert.equal(plan.callback, expected.callback)
    Assert.equal(plan.taskKind, "battle-sprite-panel-slide")
    Assert.equal(plan.context, "sprite-system")
    Assert.deepEqual(plan.parameters, {
      firstPanelOffsetX = 0,
      firstPanelOffsetY = expected.offsetY,
      secondPanelOffsetX = 12,
      secondPanelOffsetY = 4,
    })
  end

  local stream = table.concat({ u32(45), u32(80), u32(0), u32(45), u32(82), u32(0) })
  local program = compiler().compile({
    key = "battle-sprite-panel-callbacks",
    stream = stream,
    resolveSourceInput = function(role, operands)
      return Sources.resolveSourceSelection(role, operands)
    end,
  })
  Assert.equal(program.instructions[1].callback, "battle-sprite-panel-slide-down")
  Assert.equal(program.instructions[2].callback, "battle-sprite-panel-slide-down")
  Assert.isNil(program.instructions[1].selector, "callback selectors stay producer-only")
end

function T.double_sprite_picture_scale_callback_has_a_named_task()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = Sources.resolveSourceSelection("battle-animation-callback", { 8, 0 })
  Assert.equal(plan.callback, "pokemon-picture-double-sprite-scale-settle")
  Assert.equal(plan.taskKind, "pokemon-picture-double-sprite-scale-settle")
  Assert.equal(plan.context, "pokemon-picture")
  Assert.deepEqual(plan.parameters, {})

  local program = compiler().compile({
    key = "double-sprite-picture-scale",
    stream = u32(45) .. u32(8) .. u32(0),
    resolveSourceInput = function(role, operands)
      return Sources.resolveSourceSelection(role, operands)
    end,
  })
  Assert.equal(program.instructions[1].taskKind, "pokemon-picture-double-sprite-scale-settle")
  Assert.isNil(program.instructions[1].selector, "callback selector remains producer-only")
end

function T.battler_pair_picture_scale_callback_has_a_named_task()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = Sources.resolveSourceSelection("battle-animation-callback", { 9, 0 })
  Assert.equal(plan.callback, "pokemon-picture-battler-pair-scale-transition")
  Assert.equal(plan.taskKind, "pokemon-picture-battler-pair-scale-transition")
  Assert.equal(plan.context, "pokemon-picture")
  Assert.deepEqual(plan.parameters, {})
end

function T.battle_background_picture_slide_callback_has_a_named_task()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = Sources.resolveSourceSelection("battle-animation-callback", { 12, 0 })
  Assert.equal(plan.callback, "battle-background-pokepic-slide")
  Assert.equal(plan.taskKind, "battle-background-pokepic-slide")
  Assert.equal(plan.context, "battle-display")
  Assert.deepEqual(plan.parameters, {})
end

function T.picture_palette_pulse_callbacks_have_named_tasks()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  for selector, callback in pairs({
    [13] = "pokemon-picture-palette-pulse-position-transition",
    [14] = "pokemon-picture-table-driven-position-transition",
  }) do
    local plan = Sources.resolveSourceSelection("battle-animation-callback", { selector, 0 })
    Assert.equal(plan.callback, callback)
    Assert.equal(plan.taskKind, callback)
    Assert.equal(plan.context, "pokemon-picture")
    Assert.deepEqual(plan.parameters, {})
  end
end

function T.picture_and_battle_palette_fade_callback_has_a_named_task()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = Sources.resolveSourceSelection("battle-animation-callback", { 16, 0 })
  Assert.equal(plan.callback, "pokemon-picture-battle-palette-fade-cycle")
  Assert.equal(plan.taskKind, "pokemon-picture-battle-palette-fade-cycle")
  Assert.equal(plan.context, "battle-palette")
  Assert.deepEqual(plan.parameters, {})
end

function T.sprite_affine_scale_callback_has_a_named_task()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = Sources.resolveSourceSelection("battle-animation-callback", { 17, 0 })
  Assert.equal(plan.callback, "sprite-affine-scale-and-blend-transition")
  Assert.equal(plan.taskKind, "sprite-affine-scale-and-blend-transition")
  Assert.equal(plan.context, "battle-sprite")
  Assert.deepEqual(plan.parameters, {})
end

function T.picture_repeated_scale_position_callback_has_a_named_task()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = Sources.resolveSourceSelection("battle-animation-callback", { 19, 0 })
  Assert.equal(plan.callback, "pokemon-picture-repeated-scale-position-transition")
  Assert.equal(plan.taskKind, "pokemon-picture-repeated-scale-position-transition")
  Assert.equal(plan.context, "pokemon-picture")
  Assert.deepEqual(plan.parameters, {})
end

function T.background_picture_wipe_callback_has_a_named_task()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = Sources.resolveSourceSelection("battle-animation-callback", { 20, 0 })
  Assert.equal(plan.callback, "battle-background-picture-wipe-transition")
  Assert.equal(plan.taskKind, "battle-background-picture-wipe-transition")
  Assert.equal(plan.context, "battle-display")
  Assert.deepEqual(plan.parameters, {})
end

function T.three_sprite_affine_picture_transition_has_a_named_task()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = Sources.resolveSourceSelection("battle-animation-callback", { 22, 0 })
  Assert.equal(plan.callback, "pokemon-picture-three-sprite-affine-transition")
  Assert.equal(plan.taskKind, "pokemon-picture-three-sprite-affine-transition")
  Assert.equal(plan.context, "pokemon-picture")
  Assert.deepEqual(plan.parameters, {})
end

function T.background_picture_palette_scroll_has_a_named_task()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = Sources.resolveSourceSelection("battle-animation-callback", { 24, 0 })
  Assert.equal(plan.callback, "battle-background-picture-palette-scroll")
  Assert.equal(plan.taskKind, "battle-background-picture-palette-scroll")
  Assert.equal(plan.context, "battle-display")
  Assert.deepEqual(plan.parameters, {})
end

function T.pokepic_offset_callback_normalizes_its_battler_selector()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  for _, case in ipairs({
    { operand = 0, target = "attacker" },
    { operand = 1, target = "target" },
    { operand = 0xffffffff, target = "target" },
  }) do
    local plan = Sources.resolveSourceSelection("battle-animation-callback", { 25, 1, case.operand })
    Assert.equal(plan.callback, "pokemon-picture-entry-offset-" .. case.target)
    Assert.equal(plan.taskKind, "pokemon-picture-entry-offset-transition")
    Assert.equal(plan.battlerTarget, case.target)
    Assert.deepEqual(plan.parameters, {})
  end
end

function T.pokepic_oscillating_axis_motion_has_a_named_task()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = Sources.resolveSourceSelection("battle-animation-callback", { 29, 0 })
  Assert.equal(plan.callback, "pokemon-picture-oscillating-axis-motion")
  Assert.equal(plan.taskKind, "pokemon-picture-oscillating-axis-motion")
  Assert.equal(plan.context, "pokemon-picture")
  Assert.deepEqual(plan.parameters, {})
end

function T.two_battler_picture_crossing_motion_has_a_named_task()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = Sources.resolveSourceSelection("battle-animation-callback", { 30, 0 })
  Assert.equal(plan.callback, "pokemon-picture-two-battler-crossing-motion")
  Assert.equal(plan.taskKind, "pokemon-picture-two-battler-crossing-motion")
  Assert.equal(plan.context, "pokemon-picture")
  Assert.deepEqual(plan.parameters, {})
end

function T.picture_two_phase_entry_motion_has_a_named_task()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = Sources.resolveSourceSelection("battle-animation-callback", { 31, 0 })
  Assert.equal(plan.callback, "pokemon-picture-two-phase-entry-motion")
  Assert.equal(plan.taskKind, "pokemon-picture-two-phase-entry-motion")
  Assert.equal(plan.context, "pokemon-picture")
  Assert.deepEqual(plan.parameters, {})
end

function T.picture_palette_fade_position_callback_normalizes_source_fields()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = Sources.resolveSourceSelection("battle-animation-callback", { 5, 4, 70, 120, 10, 5 })
  Assert.equal(plan.callback, "pokemon-picture-palette-fade-position-transition")
  Assert.equal(plan.taskKind, "pokemon-picture-palette-fade-position-transition")
  Assert.equal(plan.context, "pokemon-picture")
  Assert.deepEqual(plan.parameters, {
    approachOffset = 70,
    settleOffset = 120,
    approachTicks = 10,
    settleTicks = 5,
  })
  Assert.isNil(plan.selector, "native selector stays out of semantic callback plan")
end

function T.picture_sinusoidal_callback_maps_each_source_battler_mode()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  for _, case in ipairs({
    { mode = 2, callback = "pokemon-picture-sinusoidal-position-attacker", target = "attacker", paired = false },
    { mode = 4, callback = "pokemon-picture-sinusoidal-position-attacker-pair", target = "attacker", paired = true },
    { mode = 8, callback = "pokemon-picture-sinusoidal-position-target", target = "target", paired = false },
    { mode = 16, callback = "pokemon-picture-sinusoidal-position-target-pair", target = "target", paired = true },
  }) do
    local plan = Sources.resolveSourceSelection("battle-animation-callback", { 10, 3, 7, 10, case.mode })
    Assert.equal(plan.callback, case.callback)
    Assert.equal(plan.taskKind, "pokemon-picture-sinusoidal-position-motion")
    Assert.equal(plan.context, "pokemon-picture")
    Assert.equal(plan.battlerTarget, case.target)
    Assert.deepEqual(plan.parameters, {
      oscillationCycles = 7,
      durationTicks = 10,
    })
    Assert.isNil(plan.selector, "native selector stays out of semantic callback plan")
  end
  local invalid, reason = Sources.resolveSourceSelection("battle-animation-callback", { 10, 3, 7, 10, 3 })
  Assert.isNil(invalid, "initializer asserts outside its four source modes")
  Assert.isTrue(reason:find("assert", 1, true) ~= nil, "assert path is diagnosed explicitly")
end

function T.picture_position_path_callback_normalizes_every_source_mask_branch()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  for mask = 0, 0x7F do
    local plan = Sources.resolveSourceSelection("battle-animation-callback", { 60, 3, mask, 2, 12 })
    local route = mask % 0x80 >= 0x40 and "all-battler-positions"
      or mask % 0x40 >= 0x20 and "active-and-related-pair"
      or "selected-position-anchors"
    Assert.equal(plan.callback, "pokemon-picture-position-path-transition")
    Assert.equal(plan.taskKind, "pokemon-picture-position-path-transition")
    Assert.equal(plan.context, "pokemon-picture")
    Assert.deepEqual(plan.parameters, {
      positionPath = route,
      attackerAnchor = route == "selected-position-anchors" and mask % 4 >= 2,
      attackerRelatedAnchor = route == "selected-position-anchors" and mask % 8 >= 4,
      targetAnchor = route == "selected-position-anchors" and mask % 16 >= 8,
      targetRelatedAnchor = route == "selected-position-anchors" and mask % 32 >= 16,
      stepMultiplier = 2,
      durationTicks = 12,
    })
    Assert.isNil(plan.selector, "native callback selector remains producer-only")
  end

  local ignoredHighBits = Sources.resolveSourceSelection("battle-animation-callback", { 60, 3, 0x80000002, 1, 9 })
  Assert.equal(ignoredHighBits.parameters.positionPath, "selected-position-anchors")
  Assert.isTrue(ignoredHighBits.parameters.attackerAnchor, "native helper ignores bits outside its tested mask")

  local program = compiler().compile({
    key = "picture-position-path-callback",
    stream = table.concat({ u32(45), u32(60), u32(3), u32(2), u32(1), u32(12), u32(9) }),
    resolveSourceInput = function(role, operands)
      return Sources.resolveSourceSelection(role, operands)
    end,
  })
  Assert.equal(program.instructions[1].callback, "pokemon-picture-position-path-transition")
  Assert.deepEqual(program.instructions[1].parameters, {
    positionPath = "selected-position-anchors",
    attackerAnchor = true,
    attackerRelatedAnchor = false,
    targetAnchor = false,
    targetRelatedAnchor = false,
    stepMultiplier = 1,
    durationTicks = 12,
  })
  Assert.isNil(program.instructions[1].selector, "runtime instruction has no native callback selector")

  local malformed, reason = Sources.resolveSourceSelection("battle-animation-callback", { 60, 2, 2, 1 })
  Assert.isNil(malformed, "callback rejects an invalid source operand shape")
  Assert.isTrue(reason:find("three source operands", 1, true) ~= nil, "invalid frame is diagnosed by its source shape")
end

function T.picture_palette_pulse_callback_maps_picture_and_timing_operands()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = Sources.resolveSourceSelection("battle-animation-callback", { 34, 6, 2, 0, 1, 31, 10, 0 })
  Assert.equal(plan.callback, "pokemon-picture-repeated-palette-fade")
  Assert.equal(plan.taskKind, "pokemon-picture-repeated-palette-fade")
  Assert.equal(plan.context, "pokemon-picture")
  Assert.deepEqual(plan.parameters, {
    fadeExtent = 10,
    framesPerStep = 0,
    pauseTicks = 0,
    pictureTarget = "attacker",
    repeatCount = 1,
    targetColor = 31,
  })
  Assert.isNil(plan.selector, "native callback selector remains producer-only")

  local program = compiler().compile({
    key = "picture-repeated-palette-fade",
    stream = table.concat({
      u32(45),
      u32(34),
      u32(6),
      u32(2),
      u32(0),
      u32(1),
      u32(31),
      u32(10),
      u32(0),
      u32(9),
    }),
    resolveSourceInput = function(role, operands)
      return Sources.resolveSourceSelection(role, operands)
    end,
  })
  Assert.equal(program.instructions[1].taskKind, "pokemon-picture-repeated-palette-fade")
  Assert.equal(program.instructions[1].parameters.pictureTarget, "attacker")
  Assert.isNil(program.instructions[1].selector, "runtime instruction has no native callback selector")

  for _, case in ipairs({
    { selector = 2, target = "attacker" },
    { selector = 4, target = "attacker-related-position-when-paired" },
    { selector = 8, target = "target" },
    { selector = 16, target = "target-related-position-when-paired" },
    { selector = 0x802, target = "first-battler-state-zero-or-two" },
    { selector = 0x804, target = "first-battler-state-four" },
    { selector = 0x808, target = "first-battler-state-one-or-three" },
    { selector = 0x810, target = "first-battler-state-five" },
  }) do
    local selected =
      Sources.resolveSourceSelection("battle-animation-callback", { 34, 6, case.selector, 1, 2, 3, 4, 5 })
    Assert.equal(selected.parameters.pictureTarget, case.target, "source selector maps to a semantic picture target")
    Assert.equal(selected.parameters.repeatCount, 2)
  end

  local invalid, reason = Sources.resolveSourceSelection("battle-animation-callback", { 34, 6, 0, 0, 1, 31, 10, 0 })
  Assert.isNil(invalid, "initializer source assertion selector is rejected")
  Assert.isTrue(reason:find("assert", 1, true) ~= nil, "invalid picture selection retains the source assertion reason")

  local omittedFinalParameter = Sources.resolveSourceSelection("battle-animation-callback", { 34, 5, 2, 0, 1, 31, 10 })
  Assert.equal(omittedFinalParameter.parameters.pauseTicks, 0)
  local shortProgram = compiler().compile({
    key = "picture-repeated-palette-fade-default-pause",
    stream = table.concat({ u32(45), u32(34), u32(5), u32(2), u32(0), u32(1), u32(31), u32(10), u32(9) }),
    resolveSourceInput = function(role, operands)
      return Sources.resolveSourceSelection(role, operands)
    end,
  })
  Assert.equal(shortProgram.instructions[1].parameters.pauseTicks, 0)
  Assert.equal(shortProgram.instructions[2].op, "reset-blend-alpha", "five values preserve the callback cursor")
end

function T.particle_emitter_curved_path_callback_normalizes_all_source_fields()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan =
    Sources.resolveSourceSelection("battle-animation-callback", { 66, 9, 1, 3, 4, 12, 7, 64, 1, 0x00050002, 1 })
  Assert.equal(plan.callback, "battle-particle-emitter-curved-battler-path")
  Assert.equal(plan.taskKind, "battle-particle-emitter-curved-battler-path")
  Assert.equal(plan.context, "battle-particle-emitter")
  Assert.deepEqual(plan.parameters, {
    emitterContextSlot = 1,
    horizontalOffset = 3,
    verticalOffset = 4,
    durationTicks = 12,
    curveControl = 7,
    curveScale = 64,
    battlerOrder = "target-attacker",
    initialInterpolationSteps = 5,
    completionLimit = 2,
    sinusoidalOffset = true,
  })
  local program = compiler().compile({
    key = "particle-emitter-curved-path",
    stream = table.concat({
      u32(45),
      u32(66),
      u32(9),
      u32(1),
      u32(3),
      u32(4),
      u32(12),
      u32(7),
      u32(64),
      u32(1),
      u32(0x00050002),
      u32(1),
      u32(9),
    }),
    resolveSourceInput = function(role, operands)
      return Sources.resolveSourceSelection(role, operands)
    end,
  })
  Assert.equal(program.instructions[1].callback, "battle-particle-emitter-curved-battler-path")
  Assert.equal(program.instructions[1].taskKind, "battle-particle-emitter-curved-battler-path")
  Assert.isNil(program.instructions[1].selector, "runtime callback instruction omits the native selector")

  local malformed, reason =
    Sources.resolveSourceSelection("battle-animation-callback", { 66, 9, 10, 3, 4, 12, 7, 64, 1, 0x00050002, 1 })
  Assert.isNil(malformed, "callback rejects a context slot outside the interpreter table")
  Assert.isTrue(reason:find("context slot", 1, true) ~= nil, "invalid context slot is source diagnosed")
end

function T.picture_affine_sprite_entry_callback_has_no_runtime_selector_parameter()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  for _, operand in ipairs({ 0, 1 }) do
    local plan = Sources.resolveSourceSelection("battle-animation-callback", { 49, 1, operand })
    Assert.equal(plan.callback, "pokemon-picture-affine-sprite-entry-transition")
    Assert.equal(plan.taskKind, "pokemon-picture-affine-sprite-entry-transition")
    Assert.equal(plan.context, "pokemon-picture")
    Assert.deepEqual(plan.parameters, {})
    Assert.isNil(plan.selector, "native selector stays out of semantic callback plan")
  end
end

function T.semantic_animation_roots_include_native_move_and_named_category_routes()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local roots = Sources.listSemanticRoots()
  Assert.equal(#roots, 505, "source roots are the 467 move IDs and 38 named non-move categories")
  local move = Sources.resolveSemanticRoute("TACKLE")
  Assert.equal(move.kind, "move")
  Assert.equal(move.archiveSymbol, "NARC_a_0_1_0")
  Assert.equal(move.memberId, 33)
  local category = Sources.resolveSemanticRoute("BATTLE_ANIMATION_ASLEEP")
  Assert.equal(category.kind, "battle-animation")
  Assert.equal(category.archiveSymbol, "NARC_a_0_6_1")
  Assert.equal(category.memberId, 1)
  Assert.equal(category.animationCategory, 1)
  Assert.isNil(Sources.resolveSemanticRoute("BATTLE_ANIMATION_NONE"), "NONE is not a visual root")
end

function T.unresolved_selector_truncation_and_opcode_88_fail_with_offsets()
  local cases = {
    { key = "unresolved-callback", stream = u32(45) .. u32(7) .. u32(0) },
    { key = "truncated-count", stream = u32(45) .. u32(7) },
    { key = "truncated-values", stream = u32(45) .. u32(7) .. u32(1) },
    { key = "guard-overrun", stream = u32(88) },
  }
  local stateDependentCursor = {
    [1] = true,
    [2] = true,
    [10] = true,
    [13] = true,
    [14] = true,
    [19] = true,
    [20] = true,
    [29] = true,
    [50] = true,
    [64] = true,
    [66] = true,
    [70] = true,
    [71] = true,
    [72] = true,
    [84] = true,
    [87] = true,
  }
  for _, case in ipairs(cases) do
    local ok, err = pcall(compiler().compile, { key = case.key, stream = case.stream, callbacks = {} })
    Assert.isFalse(ok, case.key .. " must fail closed")
    Assert.isTrue(tostring(err):find(case.key, 1, true) ~= nil, case.key .. " reports the program")
    Assert.isTrue(tostring(err):find("offset", 1, true) ~= nil, case.key .. " reports its source offset")
  end
end

function T.word_count_skip_resolves_to_a_source_instruction_boundary()
  local program = assert(compiler().compile({
    key = "synthetic-word-skip",
    stream = table.concat({ u32(15), u32(2), u32(0xfeed), u32(54) }),
  }))
  Assert.equal(#program.instructions, 2, "the skipped word is not misread as an opcode")
  Assert.equal(program.instructions[1].op, "skip-words", "unconditional source skip is preserved")
  Assert.equal(program.instructions[1].target, 2, "byte target normalizes to the next instruction index")
  local ok, err = pcall(compiler().compile, { key = "skip-past-end", stream = u32(15) .. u32(2) })
  Assert.isFalse(ok, "a skip beyond the native member is rejected")
  Assert.isTrue(tostring(err):find("offset", 1, true) ~= nil, "bad skip reports its source offset")
end

function T.sound_selectors_publish_only_resolved_semantic_keys()
  local program = assert(compiler().compile({
    key = "synthetic-sound-command",
    stream = u32(5) .. u32(0x1002) .. u32(9),
    sounds = { [0x1002] = "battle/sound/hit" },
  }))
  Assert.equal(program.instructions[1].op, "play-sound", "native play command preserves its side effect")
  Assert.equal(program.instructions[1].sound, "battle/sound/hit", "native sound ID resolves before IR publication")
  Assert.isNil(program.instructions[1].callback, "sound mapping is not confused with callback mapping")
  Assert.equal(program.instructions[2].op, "reset-blend-alpha", "opcode 5 consumes only its sound operand")
end

function T.none_sound_selector_lowers_to_no_audio_instruction()
  local program = assert(compiler().compile({ key = "no-sound", stream = u32(5) .. u32(0) }))
  Assert.equal(program.instructions[1].op, "noop", "PlaySE receives no audible sequence for the none selector")
  Assert.isNil(program.instructions[1].sound, "the none sequence is not a semantic audio dependency")
end

function T.positioned_none_sound_consumes_its_pan_word_without_audio()
  local program = assert(compiler().compile({
    key = "positioned-no-sound",
    stream = table.concat({ u32(22), u32(0), u32(0x7f), u32(9) }),
  }))
  Assert.equal(program.instructions[1].op, "noop", "positioned PlaySE with SEQ_NONE has no audible effect")
  Assert.isNil(program.instructions[1].sound, "the none sequence does not become an audio dependency")
  Assert.equal(program.instructions[2].op, "reset-blend-alpha", "the handler consumes its pan word")
end

function T.positioned_sound_uses_the_normalized_sound_identity_and_signed_pan()
  local sound = "battle/audio/hit"
  local program = assert(compiler().compile({
    key = "positioned-sound",
    stream = u32(22) .. u32(0x1234) .. u32(0xfffffffe) .. u32(54),
    sounds = { [0x1234] = sound },
  }))
  Assert.equal(program.instructions[1].op, "play-positioned-sound", "source sequence is played with spatialization")
  Assert.equal(program.instructions[1].sound, sound, "native audio ID resolves to a semantic catalog key")
  Assert.deepEqual(program.instructions[1].values, { -2 }, "pan operand uses signed low-byte conversion")
  Assert.equal(program.instructions[2].op, "noop", "following opcode starts after both sound operands")
end

function T.sound_action_records_lower_to_typed_audio_tasks()
  local sound = "SEQ_GS_TITLE"
  local stream = table.concat({
    u32(23),
    u32(0xfffffffe),
    u32(24),
    u32(1004),
    u32(0xff),
    u32(2),
    u32(3),
    u32(1),
    u32(25),
    u32(1004),
    u32(0xfe),
    u32(5),
    u32(6),
    u32(26),
    u32(1004),
    u32(0xfd),
    u32(7),
    u32(35),
    u32(1004),
    u32(0xfc),
    u32(0xfb),
    u32(0xfa),
    u32(8),
    u32(36),
    u32(1004),
    u32(0xf9),
    u32(0xf8),
    u32(0xf7),
    u32(9),
    u32(54),
  })
  local program = assert(compiler().compile({ key = "audio-action-records", stream = stream }))
  Assert.equal(program.instructions[1].op, "stop-positioned-sound", "opcode 23 updates the positioned sound")
  Assert.deepEqual(program.instructions[1].values, { -2 }, "position selector narrows as signed byte")
  local expected = {
    { taskKind = "positioned-sound-motion", values = { -1, 2, 3, 1 } },
    { taskKind = "repeated-sound-playback", values = { -2, 5, 6 } },
    { taskKind = "delayed-sound-playback", values = { -3, 7 } },
    { taskKind = "positioned-sound-motion", values = { -4, -5, -6, 8 } },
    { taskKind = "positioned-sound-motion", values = { -7, -8, -9, 9 } },
  }
  for index, expectation in ipairs(expected) do
    local instruction = program.instructions[index + 1]
    Assert.equal(instruction.op, "submit-sound-action", "source action record lowers to an audio task")
    Assert.equal(instruction.sound, sound, "source sound resolves through the normalized sequence catalog")
    Assert.equal(instruction.taskKind, expectation.taskKind, "callback behavior has a semantic task kind")
    Assert.deepEqual(instruction.values, expectation.values, "record parameters preserve source conversions")
  end
  Assert.equal(program.instructions[7].op, "noop", "all action records preserve their full cursor layout")
  Assert.deepEqual(
    program.taskKinds,
    { "positioned-sound-motion", "repeated-sound-playback", "delayed-sound-playback" },
    "program task inventory closes over the task kinds it schedules"
  )
  Assert.isTrue(
    require("libs.assets.src.battle.BattleAnimationSchema").assertProgram({
      entry = program.entry,
      instructions = program.instructions,
      subprograms = program.subprograms,
      taskKinds = program.taskKinds,
    }),
    "audio task kinds conform to the closed normalized program schema"
  )
end

function T.sound_selectors_resolve_from_the_audio_identity_catalog_without_native_ids()
  local program = assert(compiler().compile({
    key = "catalog-sound",
    stream = u32(22) .. u32(1004) .. u32(0) .. u32(54),
  }))
  Assert.equal(program.instructions[1].sound, "SEQ_GS_TITLE", "source sequence selector resolves canonically")
  Assert.isNil(program.instructions[1].soundId, "native sequence number does not enter runtime IR")
end

function T.stateful_or_resource_unresolved_handlers_do_not_gain_guessed_operations()
  local ok, err = pcall(compiler().compile, {
    key = "unresolved-native-context",
    stream = table.concat({ u32(46), u32(1), u32(2), u32(3) }),
  })
  Assert.isFalse(ok, "task handler cannot be assigned a fabricated generic task")
  Assert.isTrue(
    tostring(err):find("unresolved particle action profile", 1, true) ~= nil,
    "the unresolved task selector is identified by its semantic role"
  )
end

function T.battler_animation_destination_form_uses_its_four_word_source_frame()
  local ok, err = pcall(compiler().compile, {
    key = "four-word-battler-animation-destination",
    stream = table.concat({ u32(47), u32(1), u32(2), u32(3), u32(4), u32(54) }),
  })
  Assert.isFalse(ok, "unresolved callback selection remains fail-closed")
  Assert.equal(
    err.context.cursorOffset,
    20,
    "source handler consumes battler, destination, and two action words before failing closed"
  )

  local Sources = require("romdump.src.config.BattleAnimationSources")
  local program = assert(compiler().compile({
    key = "four-word-battler-animation-destination-valid",
    stream = table.concat({ u32(47), u32(1), u32(2), u32(3), u32(4), u32(54) }),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "battler-particle-action", "opcode 47 uses its source particle route")
      local action = assert(Sources.resolveSourceSelection(role, operands))
      action.resource = "battle/particle-emitter/destination"
      return action
    end,
  }))
  Assert.equal(program.instructions[1].op, "create-parameterized-battler-effect", "destination particle setup lowers")
  Assert.equal(
    program.instructions[1].actionProfile,
    "particle-emitter-target-battler-relative",
    "selector maps to its semantic profile"
  )
  Assert.equal(program.instructions[1].emitterPosition, "solo-enemy", "source slot is normalized to a battler position")
  Assert.equal(program.instructions[1].resource, "battle/particle-emitter/destination")
  Assert.equal(program.instructions[1].continuationSlot, 2, "destination slot retains its continuation semantics")
  Assert.deepEqual(program.sourceOffsets, { 0, 20 }, "producer provenance aligns byte offsets to instruction order")
  Assert.isNil(program.instructions[1].values, "native res_no and callback selector stay out of runtime values")
  Assert.equal(program.instructions[2].op, "noop", "the four-word frame reaches the following command")
end

function T.particle_continuation_slot_uses_the_source_allocated_table_bound()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local function compile(slot)
    return compiler().compile({
      key = "particle-continuation-slot-bound",
      stream = table.concat({ u32(47), u32(1), u32(slot), u32(0), u32(3), u32(54) }),
      resolveSourceInput = function(role, operands)
        local action = assert(Sources.resolveSourceSelection(role, operands))
        action.resource = "battle/particle-emitter/continuation-bound"
        return action
      end,
    })
  end

  local program = assert(compile(70))
  Assert.equal(program.instructions[1].continuationSlot, 70, "the final allocated slot is retained")

  local ok, err = pcall(compile, 71)
  Assert.isFalse(ok, "a continuation slot beyond the allocated table fails closed")
  Assert.equal(err.code, "BATTLE_ANIMATION_STREAM_INVALID")
  Assert.equal(err.context.offset, 0, "failure points to the source opcode")
  Assert.equal(err.context.cursorOffset, 8, "failure points to the continuation slot word")
end

function T.battler_particle_context_tables_select_by_attacker_and_target_position()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local positions = {
    "solo-player",
    "solo-enemy",
    "player-side-slot-1",
    "enemy-side-slot-1",
    "player-side-slot-2",
    "enemy-side-slot-2",
  }
  local expected = {
    [48] = {
      ["solo-player/solo-enemy"] = 0,
      ["solo-enemy/solo-player"] = 3,
      ["player-side-slot-1/enemy-side-slot-1"] = 2,
      ["player-side-slot-1/enemy-side-slot-2"] = 0,
      ["enemy-side-slot-1/player-side-slot-1"] = 5,
      ["enemy-side-slot-1/player-side-slot-2"] = 3,
      ["player-side-slot-2/enemy-side-slot-1"] = 0,
      ["player-side-slot-2/enemy-side-slot-2"] = 1,
      ["enemy-side-slot-2/player-side-slot-1"] = 3,
      ["enemy-side-slot-2/player-side-slot-2"] = 4,
    },
    [49] = {
      ["player-side-slot-1/player-side-slot-2"] = 0,
      ["enemy-side-slot-1/enemy-side-slot-2"] = 1,
      ["player-side-slot-2/player-side-slot-1"] = 1,
      ["enemy-side-slot-2/enemy-side-slot-1"] = 0,
    },
  }
  for opcode, choices in pairs(expected) do
    for attackerIndex, attackerType in ipairs(positions) do
      for targetIndex, targetType in ipairs(positions) do
        Assert.equal(
          Sources.battlerParticleCandidate(opcode, attackerType, targetType),
          choices[attackerType .. "/" .. targetType],
          "source table selects or asserts for named attacker/target battler positions "
            .. attackerIndex
            .. "/"
            .. targetIndex
        )
      end
    end
  end
end

function T.particle_initializer_table_resolves_all_profiles_without_native_selectors()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local positions = {
    "solo-player",
    "solo-enemy",
    "player-side-slot-1",
    "enemy-side-slot-1",
    "player-side-slot-2",
    "enemy-side-slot-2",
  }
  local profileBySelector = {}
  for selector = 0, 22 do
    local plan = assert(Sources.resolveBattlerParticleAction(46, { 0, 0x55, selector }))
    profileBySelector[selector] = plan.actionProfile
    Assert.equal(plan.taskKind, "battler-effect-continuation", "each initializer belongs to the typed effect task")
    Assert.isTrue(type(plan.actionProfile) == "string", "every initializer has a semantic action profile")
    Assert.equal(plan.sourceEmitterSelections.resource, 0x55, "the fixed APS emitter ordinal remains producer-only")
    Assert.isNil(plan.selector, "source callback selector stays out of the action plan")
  end
  local destination = assert(Sources.resolveBattlerParticleAction(47, { 2, 5, 0x66, 4 }))
  Assert.equal(
    destination.sourceEmitterSelections.resource,
    0x66,
    "opcode47 selects its APS ordinal from operand three"
  )
  Assert.equal(
    profileBySelector[0],
    "particle-emitter-default",
    "source-proven empty initializer has a semantic identity"
  )
  Assert.equal(profileBySelector[22], profileBySelector[0], "the second empty initializer is a source-proven alias")

  local operands48 = { 0, 0, 11, 12, 13, 14, 15, 4 }
  local operands49 = { 0, 0, 21, 22, 23, 4 }
  for _, input in ipairs({ { 48, operands48 }, { 49, operands49 } }) do
    local opcode, operands = input[1], input[2]
    local plan = assert(Sources.resolveBattlerParticleAction(opcode, operands))
    local candidates = Sources.SOURCE_INPUTS[opcode].candidateResNoOperands
    local caseCount = 0
    for _, attacker in ipairs(positions) do
      for _, target in ipairs(positions) do
        local candidate = Sources.battlerParticleCandidate(opcode, attacker, target)
        local expectedResNo = "source-assert"
        if candidate ~= nil then
          expectedResNo = operands[candidates[candidate + 1]]
        end
        Assert.equal(
          plan.sourceEmitterSelections[attacker .. "/" .. target],
          expectedResNo,
          "the complete attacker/target relation preserves its producer-only res_no selection or source assertion"
        )
        caseCount = caseCount + 1
      end
    end
    Assert.equal(caseCount, 36, "each context table lowers all side and slot pairs")
    Assert.equal(plan.actionProfile, profileBySelector[4], "the final callback-table index selects the action profile")
    Assert.isNil(plan.callbackCases, "position-pair res_no choices do not select callback profiles")
    Assert.equal(plan.runtimeSelection, "battler-particle-position-pair", "runtime choice has a typed semantic enum")
  end
end

function T.position_pair_particle_handlers_select_res_no_and_final_callback_separately()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local expected = {
    {
      opcode = 48,
      operands = { 2, 9, 11, 12, 13, 14, 15, 4 },
      callback = "particle-emitter-target-battler-relative",
      pair = "solo-player/solo-enemy",
      resNo = 9,
    },
    {
      opcode = 49,
      operands = { 3, 9, 10, 11, 12, 4 },
      callback = "particle-emitter-target-battler-relative",
      pair = "player-side-slot-1/player-side-slot-2",
      resNo = 9,
    },
  }
  for _, case in ipairs(expected) do
    local definition = Sources.SOURCE_INPUTS[case.opcode]
    Assert.equal(definition.callbackOperand, #case.operands, "only the trailing table index chooses the callback")
    Assert.equal(definition.candidateResNoOperands[1], 2, "candidate values are res_no words")
    local plan = Sources.resolveBattlerParticleAction(case.opcode, case.operands)
    Assert.equal(plan.actionProfile, case.callback, "all position pairs share the final callback-table selection")
    Assert.isNil(plan.callbackCases, "candidate res_no operands are never interpreted as callbacks")
    Assert.equal(plan.sourceEmitterSelections[case.pair], case.resNo, "selected res_no stays producer-only")
  end
end

function T.position_pair_particle_lowering_carries_semantic_resources_not_res_no_values()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local positions = {
    "solo-player",
    "solo-enemy",
    "player-side-slot-1",
    "enemy-side-slot-1",
    "player-side-slot-2",
    "enemy-side-slot-2",
  }
  local resourceCases = {}
  for _, attacker in ipairs(positions) do
    for _, target in ipairs(positions) do
      resourceCases[attacker .. "/" .. target] = "battle/particle-emitter/test"
    end
  end
  resourceCases["solo-player/solo-enemy"] = "source-assert"
  local program = assert(compiler().compile({
    key = "position-pair-particle-resources",
    stream = table.concat({
      u32(48),
      u32(1),
      u32(0),
      u32(1),
      u32(2),
      u32(3),
      u32(4),
      u32(5),
      u32(4),
      u32(54),
    }),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "battler-particle-action", "position-pair handler requests producer-resolved emitters")
      Assert.equal(operands[8], 4, "the last word chooses the fixed callback action profile")
      return {
        actionProfile = "particle-emitter-target-battler-relative",
        taskKind = "battler-effect-continuation",
        runtimeSelection = "battler-particle-position-pair",
        emitterPosition = "solo-player",
        resourceCases = resourceCases,
      }
    end,
  }))
  local instruction = program.instructions[1]
  Assert.equal(instruction.op, "create-parameterized-battler-effect")
  Assert.equal(instruction.actionProfile, "particle-emitter-target-battler-relative")
  Assert.deepEqual(instruction.resourceCases, resourceCases, "source selections lower to semantic emitter keys")
  Assert.isNil(instruction.values, "native res_no and callback words do not enter runtime values")
  Assert.equal(instruction.emitterPosition, "solo-enemy", "the effect slot is a semantic battler position")
  Assert.isNil(instruction.callbackCases, "resource selection is not mislabeled callback dispatch")

  local opcode49Operands = { 2, 9, 10, 11, 12, 4 }
  local opcode49Words = { u32(49) }
  for _, operand in ipairs(opcode49Operands) do
    opcode49Words[#opcode49Words + 1] = u32(operand)
  end
  opcode49Words[#opcode49Words + 1] = u32(54)
  local opcode49Program = assert(compiler().compile({
    key = "opcode49-position-pair-particle-resources",
    stream = table.concat(opcode49Words),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "battler-particle-action", "opcode49 resolves its source particle action")
      Assert.deepEqual(operands, opcode49Operands, "opcode49 forwards its six source operands")
      local selection = assert(Sources.resolveSourceSelection(role, operands))
      local cases = {}
      for _, attacker in ipairs(positions) do
        for _, target in ipairs(positions) do
          local candidate = Sources.battlerParticleCandidate(49, attacker, target)
          cases[attacker .. "/" .. target] = candidate == nil and "source-assert"
            or "battle/particle-emitter/candidate-" .. candidate
        end
      end
      return {
        actionProfile = selection.actionProfile,
        taskKind = selection.taskKind,
        runtimeSelection = selection.runtimeSelection,
        resourceCases = cases,
      }
    end,
  }))
  local opcode49Instruction = opcode49Program.instructions[1]
  Assert.equal(opcode49Instruction.op, "create-parameterized-battler-effect")
  Assert.equal(opcode49Instruction.actionProfile, "particle-emitter-target-battler-relative")
  Assert.equal(opcode49Instruction.runtimeSelection, "battler-particle-position-pair")
  Assert.equal(
    opcode49Instruction.resourceCases["player-side-slot-1/player-side-slot-2"],
    "battle/particle-emitter/candidate-0",
    "opcode49 preserves the source-selected semantic resource for its valid pair"
  )
  Assert.equal(
    opcode49Instruction.resourceCases["solo-player/solo-enemy"],
    "source-assert",
    "opcode49 preserves native source-assert positions"
  )
  Assert.isNil(opcode49Instruction.values, "opcode49 native resource selectors stay out of runtime values")
  Assert.equal(opcode49Program.instructions[2].op, "noop", "opcode49 consumes its exact six-word payload")
end

function T.particle_emitter_slot_indices_resolve_to_closed_battler_positions()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local expected = {
    "solo-player",
    "solo-enemy",
    "player-side-slot-1",
    "enemy-side-slot-1",
    "player-side-slot-2",
    "enemy-side-slot-2",
  }
  for index, position in ipairs(expected) do
    Assert.equal(Sources.resolveBattlerPosition(index - 1), position, "effect slot maps to a semantic position")
  end
  Assert.isNil(Sources.resolveBattlerPosition(6), "out-of-range effect slots do not reach the runtime")
end

function T.configured_sprite_callbacks_resolve_to_closed_semantic_tasks()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local taskKinds = {}
  local threeSpriteAnimation = Sources.resolveConfiguredSpriteAction(0)
  Assert.equal(threeSpriteAnimation.taskKind, "multi-sprite-position-tick")
  Assert.equal(threeSpriteAnimation.context, "sprite-system")
  local pokemonPictureAffineAnimation = Sources.resolveConfiguredSpriteAction(14)
  Assert.equal(pokemonPictureAffineAnimation.taskKind, "sprite-affine-animation")
  Assert.equal(pokemonPictureAffineAnimation.context, "pokemon-picture")
  local pokemonPictureBlend = Sources.resolveConfiguredSpriteAction(7)
  Assert.equal(pokemonPictureBlend.taskKind, "sprite-alpha-transition")
  Assert.equal(pokemonPictureBlend.context, "pokemon-picture")
  local pokemonPictureSpritePath = Sources.resolveConfiguredSpriteAction(10)
  Assert.equal(pokemonPictureSpritePath.taskKind, "pokemon-picture-relative-sprite-path-transition")
  Assert.equal(pokemonPictureSpritePath.context, "pokemon-picture")
  local offsetTask = Sources.resolveConfiguredSpriteAction(25, { 0xffff8001, 0x00010002 })
  Assert.deepEqual(offsetTask.parameters, { offsetX = -32767, offsetY = 2 })
  local ignoredParameters = Sources.resolveConfiguredSpriteAction(21, { 0x12345678 })
  Assert.deepEqual(ignoredParameters.parameters, {})
  local rotationTransition = Sources.resolveConfiguredSpriteAction(17, {
    0xFFFF8001,
    0x00007FFF,
    0x12345678,
    0x87654321,
  })
  Assert.deepEqual(rotationTransition.parameters, {
    spriteSpacingX = -32767,
    spriteSpacingY = 32767,
    positionTransitionTicks = 0x5678,
    rotationAngle = 0x87654321,
  }, "selector 17 narrows only spacing and duration before the affine transition")
  local callbackCount = Sources.configuredSpriteCallbackCount()
  for selector = 0, callbackCount - 1 do
    local plan = Sources.resolveConfiguredSpriteAction(selector)
    Assert.isTrue(type(plan) == "table", "every configured sprite callback resolves")
    Assert.isTrue(type(plan.taskKind) == "string", "every callback names its executable semantic task")
    Assert.isTrue(type(plan.context) == "string", "every callback declares its typed context")
    Assert.isNil(plan.selector, "native callback selector is producer-only")
    Assert.isNil(plan.address, "native callback address is producer-only")
    taskKinds[plan.taskKind] = true
    Assert.isTrue(
      require("libs.assets.src.battle.BattleAnimationSchema").assertProgram({
        entry = "main",
        instructions = {
          {
            op = "create-configured-sprite",
            parameters = plan.parameters,
            taskKind = plan.taskKind,
            taskContext = plan.context,
            resourceKeys = {
              character = "battle/sprite/test/character",
              palette = "battle/sprite/test/palette",
              cell = "battle/sprite/test/cell",
              animation = "battle/sprite/test/animation",
              multiCell = "battle/sprite/test/multi-cell",
              multiAnimation = "battle/sprite/test/multi-animation",
            },
          },
        },
        subprograms = {},
        taskKinds = { plan.taskKind },
      }),
      "every callback task is admitted by the closed executable IR schema"
    )
    local stream = table.concat({
      u32(78),
      u32(2),
      u32(selector),
      u32(0),
      u32(1),
      u32(2),
      u32(3),
      u32(4),
      u32(1),
      u32(1),
      u32(0x1122),
      u32(54),
    })
    local decoded = assert(compiler().compile({
      key = "configured-sprite-selector-" .. selector,
      stream = stream,
      resolveSourceInput = function(role, operands)
        Assert.equal(role, "configured-sprite-action", "all configured tasks use the same semantic producer role")
        local result = assert(Sources.resolveSourceSelection(role, operands))
        result.resourceKeys = {
          character = "battle/sprite/test/character",
          palette = "battle/sprite/test/palette",
          cell = "battle/sprite/test/cell",
          animation = "battle/sprite/test/animation",
          multiCell = "battle/sprite/test/multi-cell",
          multiAnimation = "battle/sprite/test/multi-animation",
        }
        return result
      end,
    }))
    Assert.equal(decoded.instructions[1].taskKind, plan.taskKind, "every selector lowers to its source task kind")
    Assert.equal(decoded.instructions[1].taskContext, plan.context, "every selector preserves its typed context")
    local expectedParameters = assert(Sources.resolveConfiguredSpriteAction(selector, { 0x1122 })).parameters
    Assert.deepEqual(
      decoded.instructions[1].parameters,
      expectedParameters,
      "only source-used parameters enter typed IR"
    )
    Assert.equal(decoded.instructions[2].op, "noop", "all source frames land on the following instruction")
  end
  Assert.isTrue(taskKinds["sprite-animation-lifecycle"], "animation lifecycle has a named task")
  Assert.isTrue(taskKinds["pokemon-picture-palette-fade"], "picture palette fades have a named task")
  local plan, reason = Sources.resolveConfiguredSpriteAction(callbackCount)
  Assert.isNil(plan, "selector beyond the pinned callback table is rejected")
  Assert.isTrue(reason:find("outside", 1, true) ~= nil, "invalid callback selector has a precise reason")
end

function T.configured_sprite_dispatch_lowers_resources_task_context_and_script_parameters()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local program = assert(compiler().compile({
    key = "configured-sprite-task",
    stream = table.concat({
      u32(78),
      u32(4),
      u32(8),
      u32(10),
      u32(11),
      u32(12),
      u32(13),
      u32(14),
      u32(15),
      u32(2),
      u32(0x1234),
      u32(0x5678),
      u32(54),
    }),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "configured-sprite-action", "opcode 78 uses a source-backed task role")
      Assert.deepEqual(
        operands,
        { 4, 8, 10, 11, 12, 13, 14, 15, 2, 0x1234, 0x5678 },
        "resolver sees the full source frame"
      )
      local action = assert(Sources.resolveSourceSelection("configured-sprite-action", operands))
      action.resourceKeys = {
        character = "battle/sprite/character",
        palette = "battle/sprite/palette",
        cell = "battle/sprite/cell",
        animation = "battle/sprite/animation",
        multiCell = "battle/sprite/multi-cell",
        multiAnimation = "battle/sprite/multi-animation",
      }
      return action
    end,
  }))
  local instruction = program.instructions[1]
  Assert.equal(instruction.op, "create-configured-sprite", "callback creates and configures its sprite")
  Assert.equal(instruction.taskKind, "pokemon-picture-palette-fade", "callback resolves to a semantic task")
  Assert.equal(instruction.taskContext, "pokemon-picture", "callback declares its typed task context")
  Assert.deepEqual(instruction.parameters, {}, "unused source parameters are cursor-validated but not published")
  Assert.equal(instruction.resourceKeys.character, "battle/sprite/character", "character resource is semantic")
  Assert.equal(
    instruction.resourceKeys.multiAnimation,
    "battle/sprite/multi-animation",
    "multi-animation role is semantic"
  )
  Assert.isNil(instruction.selector, "callback selector is producer-only")
  Assert.isNil(instruction.managerSlot, "manager slot is producer-only")
  Assert.equal(program.instructions[2].op, "noop", "dynamic parameter count advances to the following opcode")
  Assert.isTrue(
    require("libs.assets.src.battle.BattleAnimationSchema").assertProgram({
      entry = program.entry,
      instructions = program.instructions,
      subprograms = program.subprograms,
      taskKinds = program.taskKinds,
    }),
    "configured sprite operation fits the closed animation schema"
  )
end

function T.selector_53_lowers_both_picture_scale_interpolation_phases()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = assert(Sources.resolveBattleAnimationCallback({ 53, 5, 0xfffffff8, 7, 9, 3, 11 }))
  Assert.equal(plan.callback, "pokemon-picture-two-phase-scale-transition")
  Assert.equal(plan.taskKind, "pokemon-picture-two-phase-scale-transition")
  Assert.equal(plan.context, "pokemon-picture")
  Assert.deepEqual(plan.parameters, {
    firstEndpoint = -8,
    firstDurationTicks = 9,
    phaseDelayTicks = 11,
    secondEndpointX = -8,
    secondEndpointY = 7,
    secondDurationTicks = 3,
  })

  local program = assert(compiler().compile({
    key = "selector-53-scale-transition",
    stream = table.concat({ u32(45), u32(53), u32(5), u32(0xfffffff8), u32(7), u32(9), u32(3), u32(11), u32(54) }),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "battle-animation-callback")
      return Sources.resolveBattleAnimationCallback(operands)
    end,
  }))
  Assert.equal(program.instructions[1].taskKind, "pokemon-picture-two-phase-scale-transition")
  Assert.deepEqual(program.instructions[1].parameters, plan.parameters)
  Assert.equal(program.instructions[2].op, "noop", "the five source words preserve the following cursor")
end

function T.selector_35_lowers_picture_relative_managed_sprite_scale_cycles()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local operands = { 35, 8, 0, 4, 20, 30, 5, 2, 0xfffeffff, 1 }
  local plan = assert(Sources.resolveBattleAnimationCallback(operands))
  Assert.equal(plan.callback, "pokemon-picture-managed-sprite-scale-pulse-attacker")
  Assert.equal(plan.taskKind, "pokemon-picture-managed-sprite-scale-pulse")
  Assert.equal(plan.context, "battle-sprite")
  Assert.deepEqual(plan.parameters, {
    spriteContextSlot = 1,
    blendCoefficient = 4,
    scaleStart = 20,
    scaleDivisor = 5,
    scaleEnd = 30,
    repeatCount = 2,
    firstDurationTicks = -2,
    returnDurationTicks = 0xffff,
  })

  local program = assert(compiler().compile({
    key = "selector-35-managed-sprite-scale",
    stream = table.concat({
      u32(45),
      u32(35),
      u32(8),
      u32(0),
      u32(4),
      u32(20),
      u32(30),
      u32(5),
      u32(2),
      u32(0xfffeffff),
      u32(1),
      u32(54),
    }),
    resolveSourceInput = function(role, sourceOperands)
      Assert.equal(role, "battle-animation-callback")
      return Sources.resolveBattleAnimationCallback(sourceOperands)
    end,
  }))
  Assert.equal(program.instructions[1].callback, plan.callback)
  Assert.deepEqual(program.instructions[1].parameters, plan.parameters)
  Assert.equal(program.instructions[2].op, "noop", "the eight callback words preserve the following cursor")

  operands[10] = 5
  local invalidSlot, reason = Sources.resolveBattleAnimationCallback(operands)
  Assert.isNil(invalidSlot, "the source sprite-context lookup asserts outside its five slots")
  Assert.isTrue(reason:find("sprite context slot", 1, true) ~= nil)
end

function T.selector_77_lowers_closed_picture_target_and_position_basis()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local operands = { 77, 3, 1, 4, 0x1234001e }
  local plan = assert(Sources.resolveBattleAnimationCallback(operands))
  Assert.equal(plan.callback, "pokemon-picture-selected-position-transition")
  Assert.equal(plan.taskKind, "pokemon-picture-selected-position-transition")
  Assert.equal(plan.context, "pokemon-picture")
  Assert.deepEqual(plan.parameters, {
    pictureTarget = "attacker-related-position-when-paired",
    positionBasis = "selected-picture-origin",
    durationTicks = 30,
  })

  local program = assert(compiler().compile({
    key = "selector-77-selected-position",
    stream = table.concat({ u32(45), u32(77), u32(3), u32(1), u32(4), u32(0x1234001e), u32(54) }),
    resolveSourceInput = function(role, sourceOperands)
      Assert.equal(role, "battle-animation-callback")
      return Sources.resolveBattleAnimationCallback(sourceOperands)
    end,
  }))
  Assert.equal(program.instructions[1].taskKind, plan.taskKind)
  Assert.deepEqual(program.instructions[1].parameters, plan.parameters)
  Assert.equal(program.instructions[2].op, "noop", "the three callback words preserve the next cursor")

  operands[4] = 3
  local invalidTarget, reason = Sources.resolveBattleAnimationCallback(operands)
  Assert.isNil(invalidTarget, "the source asserts for a picture selector outside four cases")
  Assert.isTrue(reason:find("source assertion", 1, true) ~= nil)
end

function T.selector_68_lowers_alternating_background_scroll_parameters()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = assert(Sources.resolveBattleAnimationCallback({ 68, 6, 0xfffffffd, 4, 4, 5, 8, 1 }))
  Assert.equal(plan.callback, "battle-background-alternating-scroll-transition")
  Assert.equal(plan.taskKind, "battle-background-alternating-scroll-transition")
  Assert.equal(plan.context, "battle-display")
  Assert.deepEqual(plan.parameters, {
    horizontalOffset = -3,
    verticalOffset = 4,
    ticksPerDirection = 4,
    directionChanges = 5,
    phaseIntervalTicks = 8,
    backgroundLayer = "battle-background-layer-2",
  })
  local program = assert(compiler().compile({
    key = "selector-68-background-scroll",
    stream = table.concat({
      u32(45),
      u32(68),
      u32(6),
      u32(0xfffffffd),
      u32(4),
      u32(4),
      u32(5),
      u32(8),
      u32(1),
      u32(54),
    }),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "battle-animation-callback")
      return Sources.resolveBattleAnimationCallback(operands)
    end,
  }))
  Assert.equal(program.instructions[1].taskKind, plan.taskKind)
  Assert.deepEqual(program.instructions[1].parameters, plan.parameters)
  Assert.equal(program.instructions[2].op, "noop", "the six callback words preserve the following cursor")
end

function T.selector_68_uses_zero_for_the_unprovided_sixth_callback_slot()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = assert(Sources.resolveBattleAnimationCallback({ 68, 5, 5, 0, 1, 3, 0 }))
  Assert.equal(plan.parameters.backgroundLayer, "battle-background-layer-3")

  local program = assert(compiler().compile({
    key = "selector-68-defaulted-background-layer",
    stream = table.concat({ u32(45), u32(68), u32(5), u32(5), u32(0), u32(1), u32(3), u32(0), u32(54) }),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "battle-animation-callback")
      return Sources.resolveBattleAnimationCallback(operands)
    end,
  }))
  Assert.equal(program.instructions[1].parameters.backgroundLayer, "battle-background-layer-3")
  Assert.equal(program.instructions[2].op, "noop", "five callback words preserve the following cursor")
end

function T.selector_6_normalizes_its_constant_five_phase_pokepic_affine_transition()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = assert(Sources.resolveBattleAnimationCallback({ 6, 1, 0 }))
  Assert.equal(plan.callback, "pokemon-picture-five-phase-affine-size-transition")
  Assert.equal(plan.taskKind, "pokemon-picture-five-phase-affine-size-transition")
  Assert.equal(plan.context, "pokemon-picture")
  Assert.equal(plan.battlerTarget, "attacker")
  Assert.deepEqual(plan.parameters, {})
  local program = assert(compiler().compile({
    key = "selector-6-affine-size-transition",
    stream = table.concat({ u32(45), u32(6), u32(1), u32(0), u32(54) }),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "battle-animation-callback")
      return Sources.resolveBattleAnimationCallback(operands)
    end,
  }))
  Assert.equal(program.instructions[1].taskKind, plan.taskKind)
  Assert.equal(program.instructions[1].battlerTarget, "attacker")
  Assert.deepEqual(program.instructions[1].parameters, {})
  Assert.equal(program.instructions[2].op, "noop")
end

function T.selector_51_maps_the_source_picture_target_and_horizontal_offset()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local cases = {
    { selector = 258, target = "active-battler" },
    { selector = 260, target = "active-battler-pair-when-enabled" },
    { selector = 264, target = "opposing-battler" },
    { selector = 272, target = "opposing-battler-pair-when-enabled" },
  }
  for _, case in ipairs(cases) do
    local plan = assert(Sources.resolveBattleAnimationCallback({ 51, 3, 18, 0xFFFF, case.selector }))
    Assert.equal(plan.callback, "pokemon-picture-selected-horizontal-offset-transition")
    Assert.equal(plan.taskKind, plan.callback)
    Assert.equal(plan.parameters.pictureTarget, case.target)
    Assert.equal(plan.parameters.durationTicks, 18)
    Assert.equal(plan.parameters.signedOffset, -1)
  end
  local invalid, reason = Sources.resolveBattleAnimationCallback({ 51, 3, 18, 1, 257 })
  Assert.isNil(invalid)
  Assert.isTrue(reason:find("source assertion", 1, true) ~= nil)

  local program = assert(compiler().compile({
    key = "selector-51-picture-horizontal-offset",
    stream = table.concat({ u32(45), u32(51), u32(3), u32(18), u32(0xFFFF), u32(258), u32(54) }),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "battle-animation-callback")
      return Sources.resolveBattleAnimationCallback(operands)
    end,
  }))
  Assert.equal(program.instructions[1].parameters.pictureTarget, "active-battler")
  Assert.equal(program.instructions[2].op, "noop")
end

function T.selector_67_maps_selected_picture_step_and_visibility_mode()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = assert(Sources.resolveBattleAnimationCallback({ 67, 5, 2, 0, 0, 6, 8 }))
  Assert.equal(plan.callback, "pokemon-picture-vertical-offset-visibility-transition")
  Assert.equal(plan.taskKind, plan.callback)
  Assert.equal(plan.parameters.pictureTarget, "active-battler")
  Assert.equal(plan.parameters.offsetStep, 6)
  Assert.equal(plan.parameters.ticksPerStep, 8)
  Assert.equal(plan.parameters.applyVisibilityOffset, false)

  local visibilityPlan = assert(Sources.resolveBattleAnimationCallback({ 67, 6, 4, 0, 0, 4, 3, 1 }))
  Assert.equal(visibilityPlan.parameters.pictureTarget, "active-battler-pair-when-enabled")
  Assert.equal(visibilityPlan.parameters.applyVisibilityOffset, true)
  local invalid, reason = Sources.resolveBattleAnimationCallback({ 67, 3, 1, 0, 0 })
  Assert.isNil(invalid)
  Assert.isTrue(reason:find("source assertion", 1, true) ~= nil)

  local program = assert(compiler().compile({
    key = "selector-67-picture-vertical-step",
    stream = table.concat({ u32(45), u32(67), u32(5), u32(2), u32(0), u32(0), u32(6), u32(8), u32(54) }),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "battle-animation-callback")
      return Sources.resolveBattleAnimationCallback(operands)
    end,
  }))
  Assert.equal(program.instructions[1].taskKind, plan.taskKind)
  Assert.equal(program.instructions[2].op, "noop")
end

function T.selector_76_uses_its_source_duration_for_the_background_sine_wave()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = assert(Sources.resolveBattleAnimationCallback({ 76, 1, 130 }))
  Assert.equal(plan.callback, "battle-background-scanline-sine-wave-transition")
  Assert.equal(plan.taskKind, "battle-background-scanline-sine-wave-transition")
  Assert.equal(plan.context, "battle-display")
  Assert.deepEqual(plan.parameters, {
    backgroundLayer = "battle-background-layer-3",
    durationTicks = 130,
  })
  local program = assert(compiler().compile({
    key = "selector-76-background-sine-wave",
    stream = table.concat({ u32(45), u32(76), u32(1), u32(130), u32(54) }),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "battle-animation-callback")
      return Sources.resolveBattleAnimationCallback(operands)
    end,
  }))
  Assert.equal(program.instructions[1].taskKind, plan.taskKind)
  Assert.deepEqual(program.instructions[1].parameters, plan.parameters)
  Assert.equal(program.instructions[2].op, "noop", "the duration word reaches the next instruction")
end

function T.selector_57_maps_its_source_battler_and_offset_interpolation()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = assert(Sources.resolveBattleAnimationCallback({ 57, 4, 4, 0, 8, 264 }))
  Assert.equal(plan.callback, "pokemon-picture-offset-transition")
  Assert.equal(plan.taskKind, "pokemon-picture-position-offset-transition")
  Assert.equal(plan.context, "pokemon-picture")
  Assert.deepEqual(plan.parameters, {
    pictureTarget = "opposing-battler",
    durationTicks = 4,
    offsetX = 0,
    offsetY = 8,
  })
  local program = assert(compiler().compile({
    key = "selector-57-offset-transition",
    stream = table.concat({ u32(45), u32(57), u32(4), u32(4), u32(0), u32(8), u32(264), u32(54) }),
    resolveSourceInput = function(role, operands)
      return Sources.resolveSourceSelection(role, operands)
    end,
  }))
  Assert.deepEqual(program.instructions[1].parameters, plan.parameters)
  Assert.equal(program.instructions[2].op, "noop", "the four operands preserve the following cursor")
end

function T.selector_36_maps_source_position_mask_and_transition_modes()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = assert(Sources.resolveBattleAnimationCallback({ 36, 5, 2, 0, 1, 6, 258 }))
  Assert.equal(plan.taskKind, "battle-background-blend-transition")
  Assert.deepEqual(plan.parameters, {
    offsetX = 2,
    offsetY = 0,
    ticksPerStep = 1,
    steps = 6,
    pictureSets = { "active-battler" },
    pictureAttributeOffset = true,
    managedSpriteOffset = false,
    backgroundPositionEnabled = false,
  })
  local spriteMode = assert(Sources.resolveBattleAnimationCallback({ 36, 5, 1, 0, 1, 8, 514 }))
  Assert.deepEqual(spriteMode.parameters.pictureSets, { "active-battler" })
  Assert.isFalse(spriteMode.parameters.pictureAttributeOffset)
  Assert.isTrue(spriteMode.parameters.managedSpriteOffset)
  local allPositions = assert(Sources.resolveBattleAnimationCallback({ 36, 5, 1, 0, 1, 8, 320 }))
  Assert.deepEqual(allPositions.parameters.pictureSets, { "all-battler-positions" })
  local invalidCount, reason = Sources.resolveBattleAnimationCallback({ 36, 4, 2, 0, 1, 6 })
  Assert.isNil(invalidCount)
  Assert.isTrue(reason:find("five source operands", 1, true) ~= nil)
end

function T.selector_72_lowers_managed_sprite_sinusoidal_motion_and_context_slots()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local operands = { 72, 10, 2, 15, 75, 45, 135, 4, 6, 3, 0, 5 }
  local plan = assert(Sources.resolveBattleAnimationCallback(operands))
  Assert.equal(plan.callback, "battle-sprite-sinusoidal-position-animation")
  Assert.equal(plan.taskKind, "battle-sprite-sinusoidal-position-animation")
  Assert.equal(plan.context, "battle-sprite")
  Assert.deepEqual(plan.parameters, {
    spriteContextSlot = 2,
    callbackContextSlot = 5,
    positionSource = "first-active-position",
    horizontalStartAngleDegrees = 15,
    horizontalEndAngleDegrees = 75,
    verticalStartAngleDegrees = 45,
    verticalEndAngleDegrees = 135,
    horizontalAmplitude = 4,
    verticalAmplitude = 6,
    durationTicks = 3,
  })

  local program = assert(compiler().compile({
    key = "selector-72-sinusoidal-sprite-motion",
    stream = table.concat({
      u32(45),
      u32(72),
      u32(10),
      u32(2),
      u32(15),
      u32(75),
      u32(45),
      u32(135),
      u32(4),
      u32(6),
      u32(3),
      u32(0),
      u32(5),
      u32(54),
    }),
    resolveSourceInput = function(role, sourceOperands)
      Assert.equal(role, "battle-animation-callback")
      return Sources.resolveBattleAnimationCallback(sourceOperands)
    end,
  }))
  Assert.equal(program.instructions[1].callback, plan.callback)
  Assert.deepEqual(program.instructions[1].parameters, plan.parameters)
  Assert.isNil(program.instructions[1].sourceSelections)
  Assert.equal(program.instructions[2].op, "noop", "all ten callback words preserve the next cursor")

  operands[3] = 71
  local invalidSpriteSlot, spriteReason = Sources.resolveBattleAnimationCallback(operands)
  Assert.isNil(invalidSpriteSlot)
  Assert.isTrue(spriteReason:find("sprite context table", 1, true) ~= nil)
  operands[3] = 2
  operands[12] = 71
  local invalidCallbackSlot, callbackReason = Sources.resolveBattleAnimationCallback(operands)
  Assert.isNil(invalidCallbackSlot)
  Assert.isTrue(callbackReason:find("callback context table", 1, true) ~= nil)

  operands[12] = 5
  operands[11] = 1
  local secondPosition = assert(Sources.resolveBattleAnimationCallback(operands))
  Assert.equal(secondPosition.parameters.positionSource, "second-active-position")
end

function T.selector_75_lowers_registered_sprite_priority_and_appearance_context()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = assert(Sources.resolveBattleAnimationCallback({ 75, 7, 2, 12, 2, 20, 3, 1, 1 }))
  Assert.equal(plan.callback, "battle-sprite-priority-appearance-transition")
  Assert.equal(plan.taskKind, "battle-sprite-priority-appearance-transition")
  Assert.equal(plan.context, "battle-display")
  Assert.deepEqual(plan.parameters, {
    spriteContextSlot = 2,
    durationTicks = 12,
    spritePriority = "back",
    baseDrawPriorityEnabled = true,
    baseDrawPriority = 20,
    drawPriorityBattler = "target",
    drawPriorityPattern = "reversed",
    hideWhenNotDoubleBattle = true,
    appearanceMotionEnabled = true,
    appearanceBlendProfile = "alternate",
  })
  local program = assert(compiler().compile({
    key = "selector-75-registered-sprite-appearance",
    stream = table.concat({
      u32(45),
      u32(75),
      u32(7),
      u32(2),
      u32(12),
      u32(2),
      u32(20),
      u32(3),
      u32(1),
      u32(1),
      u32(54),
    }),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "battle-animation-callback")
      return Sources.resolveBattleAnimationCallback(operands)
    end,
  }))
  Assert.equal(program.instructions[1].taskKind, plan.taskKind)
  Assert.deepEqual(program.instructions[1].parameters, plan.parameters)
  Assert.equal(program.instructions[2].op, "noop", "the seven callback words preserve the next cursor")

  local battlerByMode = { "attacker", "target", "attacker", "target" }
  local patternByMode = { "standard", "standard", "reversed", "reversed" }
  for mode = 0, 3 do
    local modePlan = assert(Sources.resolveBattleAnimationCallback({ 75, 7, 0, 0, 0xFF, 20, mode, 0, 0 }))
    Assert.equal(modePlan.parameters.drawPriorityBattler, battlerByMode[mode + 1])
    Assert.equal(modePlan.parameters.drawPriorityPattern, patternByMode[mode + 1])
    Assert.equal(modePlan.parameters.hideWhenNotDoubleBattle, mode >= 2)
  end
  local noDrawPriority = assert(Sources.resolveBattleAnimationCallback({ 75, 7, 0, 0, 0xFF, 0xFF, 2, 0, 0 }))
  Assert.equal(noDrawPriority.parameters.drawPriorityBattler, "none")
  Assert.equal(noDrawPriority.parameters.drawPriorityPattern, "unchanged")
  local invalidSprite, reason = Sources.resolveBattleAnimationCallback({ 75, 7, 5, 0, 0, 0, 0, 0, 0 })
  Assert.isNil(invalidSprite, "the source asserts for a sprite registry slot outside 0–4")
  Assert.isTrue(reason:find("outside the source table", 1, true) ~= nil)
end

function T.selector_42_lowers_source_selected_cyclic_picture_position_transitions()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = assert(Sources.resolveBattleAnimationCallback({
    42,
    8,
    0x102,
    10,
    20,
    30,
    40,
    5,
    0x00020003,
    0x00070005,
  }))
  Assert.equal(plan.callback, "pokemon-picture-cyclic-two-phase-position-transition")
  Assert.equal(plan.taskKind, "pokemon-picture-cyclic-two-phase-position-transition")
  Assert.equal(plan.context, "pokemon-picture")
  Assert.deepEqual(plan.parameters, {
    pictureTarget = "attacker",
    startX = 10,
    endX = 20,
    startY = 30,
    endY = 40,
    interpolationDivisor = 5,
    additionalCycles = 3,
    repeatDelayTicks = 2,
    firstDurationTicks = 7,
    returnDurationTicks = 5,
  })
  local program = assert(compiler().compile({
    key = "selector-42-cyclic-position",
    stream = table.concat({
      u32(45),
      u32(42),
      u32(8),
      u32(0x102),
      u32(10),
      u32(20),
      u32(30),
      u32(40),
      u32(5),
      u32(0x00020003),
      u32(0x00070005),
      u32(54),
    }),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "battle-animation-callback")
      return Sources.resolveBattleAnimationCallback(operands)
    end,
  }))
  Assert.equal(program.instructions[1].taskKind, plan.taskKind)
  Assert.deepEqual(program.instructions[1].parameters, plan.parameters)
  Assert.equal(program.instructions[2].op, "noop", "the eight callback words preserve the next cursor")
end

function T.selector_42_unmatched_picture_state_lowers_its_source_noop()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = assert(Sources.resolveBattleAnimationCallback({ 42, 8, 0x999, 10, 20, 30, 40, 5, 0, 0 }))
  Assert.equal(plan.op, "noop")
  local program = assert(compiler().compile({
    key = "selector-42-unmatched-picture-state",
    stream = table.concat({
      u32(45),
      u32(42),
      u32(8),
      u32(0x999),
      u32(10),
      u32(20),
      u32(30),
      u32(40),
      u32(5),
      u32(0),
      u32(0),
      u32(54),
    }),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "battle-animation-callback")
      return Sources.resolveBattleAnimationCallback(operands)
    end,
  }))
  Assert.equal(program.instructions[1].op, "noop")
  Assert.equal(program.instructions[2].op, "noop", "the callback frame still advances over eight parameters")
end

function T.selector_28_uses_the_event_move_power_profile_and_four_picture_transition()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = assert(Sources.resolveBattleAnimationCallback({ 28, 0 }))
  Assert.equal(plan.callback, "battle-background-four-picture-move-power-transition")
  Assert.equal(plan.taskKind, plan.callback)
  Assert.equal(plan.context, "battle-display")
  Assert.deepEqual(plan.parameters, {
    backgroundLayer = "battle-background-layer-3",
    pictureSets = { "all-battler-positions" },
    durationTicks = 10,
    defaultProfile = 0,
    profileByMovePower = {
      { movePower = 30, profile = 1 },
      { movePower = 50, profile = 2 },
      { movePower = 70, profile = 3 },
      { movePower = 90, profile = 4 },
      { movePower = 110, profile = 5 },
      { movePower = 150, profile = 6 },
    },
  })

  local program = assert(compiler().compile({
    key = "move-power-picture-transition",
    stream = table.concat({ u32(45), u32(28), u32(0), u32(54) }),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "battle-animation-callback")
      return Sources.resolveBattleAnimationCallback(operands)
    end,
  }))
  local instruction = program.instructions[1]
  Assert.equal(instruction.op, "invoke-battle-animation-callback")
  Assert.equal(instruction.callback, plan.callback)
  Assert.deepEqual(instruction.parameters, plan.parameters)
  Assert.equal(program.instructions[2].op, "noop", "the zero-word callback leaves the cursor at the next command")

  local parameterizedFrame = assert(compiler().compile({
    key = "move-power-picture-transition-counted-frame",
    stream = table.concat({ u32(45), u32(28), u32(2), u32(0x12345678), u32(0x87654321), u32(54) }),
    resolveSourceInput = function(_, operands)
      return Sources.resolveBattleAnimationCallback(operands)
    end,
  }))
  Assert.equal(parameterizedFrame.instructions[1].callback, plan.callback)
  Assert.equal(parameterizedFrame.instructions[2].op, "noop", "ignored callback words still advance the source cursor")
end

function T.selector_52_uses_the_source_valid_opposing_pair_target()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = assert(Sources.resolveBattleAnimationCallback({ 52, 3, 4, -20, 272 }))
  Assert.equal(plan.callback, "pokemon-picture-selected-position-offset-transition")
  Assert.equal(plan.parameters.pictureTarget, "opposing-battler-pair-when-enabled")
  Assert.equal(plan.parameters.durationTicks, 4)
  Assert.equal(plan.parameters.signedOffset, -20)
  local invalid, reason = Sources.resolveBattleAnimationCallback({ 52, 3, 4, -20, 274 })
  Assert.isNil(invalid, "the native callback asserts for an unsupported picture target")
  Assert.equal(reason, "picture position-offset callback follows its source assertion path")
end

function T.background_callbacks_44_and_45_lower_three_way_resources_and_typed_motion()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local expectedTaskKinds = {
    [44] = "battle-background-alpha-scroll-transition",
    [45] = "battle-background-sprite-slide-transition",
  }
  for selector = 44, 45 do
    local shortPlan, shortReason = Sources.resolveBattleAnimationCallback({ selector, 6, 0, 10, 20, -2, 3, 1 })
    Assert.isNil(shortPlan)
    Assert.equal(shortReason, "battle background callback requires its palette destination operand")
    local minimumPlan = assert(Sources.resolveBattleAnimationCallback({ selector, 7, 0, 10, 20, -2, 3, 1, 4 }))
    Assert.equal(minimumPlan.parameters.durationTicks, 0, "the source zero-fills omitted callback parameter slots")

    local plan = assert(Sources.resolveBattleAnimationCallback({ selector, 8, 0, 10, 20, -2, 3, 1, 4, 12 }))
    Assert.equal(plan.taskKind, expectedTaskKinds[selector])
    Assert.equal(plan.context, "battle-display")
    Assert.equal(plan.runtimeSelection, "battle-background-three-way-screen-selection")
    Assert.equal(plan.parameters.backgroundLayer, "battle-background-layer-2")
    Assert.equal(plan.parameters.initialScrollX, 10)
    Assert.equal(plan.parameters.initialScrollY, 20)
    Assert.equal(plan.parameters.horizontalStep, -2)
    Assert.equal(plan.parameters.verticalStep, 3)
    Assert.equal(plan.parameters.pairedPositionTransformEnabled, true)
    Assert.equal(plan.parameters.paletteTarget, "battle-animation-palette-target")
    Assert.equal(plan.parameters.durationTicks, 12)
    Assert.deepEqual(plan.sourceSelections, {
      character = { archiveSymbol = "NARC_a_0_0_7", memberId = 59, decoder = "char", kind = "texture" },
      palette = { archiveSymbol = "NARC_a_0_0_7", memberId = 295, decoder = "palette", kind = "palette" },
      screenDefault = { archiveSymbol = "NARC_a_0_0_7", memberId = 56, decoder = "screen", kind = "map" },
      screenBattlerClassFour = { archiveSymbol = "NARC_a_0_0_7", memberId = 57, decoder = "screen", kind = "map" },
      screenContextFlag = { archiveSymbol = "NARC_a_0_0_7", memberId = 58, decoder = "screen", kind = "map" },
    })
    local program = assert(compiler().compile({
      key = "background-callback-" .. tostring(selector),
      stream = table.concat({
        u32(45),
        u32(selector),
        u32(8),
        u32(0),
        u32(10),
        u32(20),
        u32(0xFFFFFFFE),
        u32(3),
        u32(1),
        u32(4),
        u32(12),
        u32(54),
      }),
      resolveSourceInput = function(role, operands)
        Assert.equal(role, "battle-animation-callback")
        local resolved = assert(Sources.resolveBattleAnimationCallback(operands))
        resolved.resourceKeys = {
          character = "battle/test/background-character",
          palette = "battle/test/background-palette",
          screenDefault = "battle/test/background-screen-default",
          screenBattlerClassFour = "battle/test/background-screen-class-four",
          screenContextFlag = "battle/test/background-screen-context-flag",
        }
        resolved.sourceSelections = nil
        return resolved
      end,
    }))
    local instruction = program.instructions[1]
    Assert.equal(instruction.taskKind, expectedTaskKinds[selector])
    Assert.equal(instruction.runtimeSelection, "battle-background-three-way-screen-selection")
    Assert.deepEqual(instruction.resourceKeys, {
      character = "battle/test/background-character",
      palette = "battle/test/background-palette",
      screenDefault = "battle/test/background-screen-default",
      screenBattlerClassFour = "battle/test/background-screen-class-four",
      screenContextFlag = "battle/test/background-screen-context-flag",
    })
    Assert.isNil(instruction.sourceSelections, "physical source selectors stay producer-only")
    Assert.equal(program.instructions[2].op, "noop", "eight callback values preserve the next cursor")
  end
end

function T.configured_sprite_rotation_frame_lowers_used_words_and_skips_unused_words()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local parameters = { 0xFFFF8001, 0x00007FFF, 0x12345678, 0x87654321, 0xCAFEBABE, 0xDEADBEEF }
  local streamParts = {
    u32(78),
    u32(4),
    u32(17),
    u32(10),
    u32(11),
    u32(12),
    u32(13),
    u32(14),
    u32(15),
    u32(#parameters),
  }
  for _, value in ipairs(parameters) do
    streamParts[#streamParts + 1] = u32(value)
  end
  streamParts[#streamParts + 1] = u32(54)
  local program = assert(compiler().compile({
    key = "configured-sprite-rotation-frame",
    stream = table.concat(streamParts),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "configured-sprite-action", "rotation callback uses its source semantic route")
      local action = assert(Sources.resolveSourceSelection(role, operands))
      action.resourceKeys = {
        character = "battle/sprite/character",
        palette = "battle/sprite/palette",
        cell = "battle/sprite/cell",
        animation = "battle/sprite/animation",
        multiCell = "battle/sprite/multi-cell",
        multiAnimation = "battle/sprite/multi-animation",
      }
      return action
    end,
  }))
  Assert.deepEqual(program.instructions[1].parameters, {
    spriteSpacingX = -32767,
    spriteSpacingY = 32767,
    positionTransitionTicks = 0x5678,
    rotationAngle = 0x87654321,
  }, "only the four values used by the callback enter its typed task parameters")
  Assert.equal(program.instructions[2].op, "noop", "all declared parameter words advance the source cursor")
end

function T.invalid_configured_sprite_callback_reports_the_selector_offset()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local ok, err = pcall(compiler().compile, {
    key = "invalid-configured-sprite-selector",
    stream = table.concat({ u32(78), u32(4), u32(33), u32(10), u32(11), u32(12), u32(13), u32(14), u32(15), u32(0) }),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "configured-sprite-action", "selector is checked through its semantic route")
      return Sources.resolveSourceSelection(role, operands)
    end,
  })
  Assert.isFalse(ok, "selector outside the pinned callback table is rejected")
  Assert.equal(err.context.cursorOffset, 8, "bad selector reports its word in the source member")
  Assert.isTrue(
    tostring(err):find("outside the pinned table", 1, true) ~= nil,
    "failure identifies the source table bound"
  )
end

function T.battler_particle_effects_lower_to_typed_profiles_and_position_pair_cases()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local program = assert(compiler().compile({
    key = "battler-particle-profiles",
    stream = table.concat({
      u32(46),
      u32(1),
      u32(0x234),
      u32(0),
      u32(48),
      u32(1),
      u32(0),
      u32(1),
      u32(2),
      u32(3),
      u32(4),
      u32(5),
      u32(4),
      u32(54),
    }),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "battler-particle-action", "particle effects request their semantic source plan")
      local action = assert(Sources.resolveSourceSelection(role, operands))
      if #operands == 3 then
        action.resource = "battle/particle-emitter/direct"
      else
        action.emitterPosition = "solo-enemy"
        action.resourceCases = {}
        for _, attacker in ipairs({
          "solo-player",
          "solo-enemy",
          "player-side-slot-1",
          "enemy-side-slot-1",
          "player-side-slot-2",
          "enemy-side-slot-2",
        }) do
          for _, target in ipairs({
            "solo-player",
            "solo-enemy",
            "player-side-slot-1",
            "enemy-side-slot-1",
            "player-side-slot-2",
            "enemy-side-slot-2",
          }) do
            local candidate = Sources.battlerParticleCandidate(48, attacker, target)
            action.resourceCases[attacker .. "/" .. target] = candidate == nil and "source-assert"
              or "battle/particle-emitter/candidate-" .. candidate
          end
        end
      end
      action.emitterPosition = action.emitterPosition or "solo-player"
      return action
    end,
  }))
  Assert.equal(program.instructions[1].op, "create-parameterized-battler-effect", "opcode 46 creates an SPL effect")
  Assert.equal(
    program.instructions[1].actionProfile,
    "particle-emitter-default",
    "direct callback maps to a semantic action profile"
  )
  Assert.equal(program.instructions[1].taskKind, "battler-effect-continuation", "effect uses its typed task")
  Assert.equal(
    program.instructions[1].resource,
    "battle/particle-emitter/direct",
    "resolved emitter identity enters IR"
  )
  Assert.equal(program.instructions[1].emitterPosition, "solo-enemy", "emitter slot is normalized to a position")
  Assert.isNil(program.instructions[1].values, "native res_no and callback selectors are not runtime values")
  Assert.equal(program.instructions[2].runtimeSelection, "battler-particle-position-pair", "context choice is explicit")
  Assert.equal(
    program.instructions[2].resourceCases["solo-player/solo-enemy"],
    "battle/particle-emitter/candidate-0",
    "first source selection is attached to the complete semantic position pair"
  )
  Assert.equal(
    program.instructions[2].resourceCases["solo-enemy/solo-player"],
    "battle/particle-emitter/candidate-3",
    "second source selection preserves the reverse semantic position pair"
  )
  local pairCount = 0
  for _ in pairs(program.instructions[2].resourceCases) do
    pairCount = pairCount + 1
  end
  Assert.equal(pairCount, 36, "semantic decision map covers every attacker/target position pair")
  Assert.isNil(program.instructions[2].candidateIndex, "native candidate ordinals stay producer-only")
  Assert.equal(program.instructions[3].op, "noop", "particle handlers consume their exact source frames")
  Assert.isTrue(
    require("libs.assets.src.battle.BattleAnimationSchema").assertProgram({
      entry = program.entry,
      instructions = program.instructions,
      subprograms = program.subprograms,
      taskKinds = program.taskKinds,
    }),
    "particle profile and pair map obey the closed semantic schema"
  )
end

function T.configure_from_script_callbacks_consume_their_inline_config()
  -- Callback 17 (ConfigureFromScript) reads a [skip, count, count words]
  -- trailer inline during dispatch (BattleAnimSystem_ReadScriptArgs via
  -- BattleAnimEmitterCb_ConfigureFromScript). The trailer words are cursor
  -- framing, never opcodes: without consuming them the decoder dispatches
  -- the skip word (55, Invalid55) as a source assertion and truncates the
  -- member, abandoning the real continuation (GUST member 16 repeats this
  -- shape twice; every retail callback-17 instance carries skip=55,
  -- count=6). The trailer values never enter the action plan; per-emitter
  -- placement refinement stays future work.
  local words = { u32(46), u32(0), u32(0), u32(17), u32(55), u32(6) }
  for _ = 1, 6 do
    words[#words + 1] = u32(0)
  end
  words[#words + 1] = u32(4)
  local program = assert(compiler().compile({
    key = "configure-from-script-trailer",
    stream = table.concat(words),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "battler-particle-action", "the emitter word asks for its particle plan")
      Assert.deepEqual(operands, { 0, 0, 17 }, "only the three base operands enter the plan")
      return {
        actionProfile = "particle-emitter-default",
        taskKind = "battler-effect-continuation",
        resource = "battle/particle-emitter/configured",
      }
    end,
  }))
  Assert.equal(#program.instructions, 2, "the trailer words never become instructions")
  Assert.equal(
    program.instructions[1].op,
    "create-parameterized-battler-effect",
    "the emitter word keeps its own operation"
  )
  Assert.equal(
    program.instructions[2].op,
    "reset-battle-presentation",
    "the continuation past the trailer stays reachable"
  )
  local badWords = { u32(46), u32(0), u32(0), u32(17), u32(55), u32(7) }
  for _ = 1, 7 do
    badWords[#badWords + 1] = u32(0)
  end
  local ok, err = pcall(compiler().compile, {
    key = "configure-from-script-bad-count",
    stream = table.concat(badWords),
    resolveSourceInput = function()
      return {
        actionProfile = "particle-emitter-default",
        taskKind = "battler-effect-continuation",
        resource = "battle/particle-emitter/configured",
      }
    end,
  })
  Assert.isFalse(ok, "a config count the source reader rejects never lowers")
  Assert.isTrue(
    tostring(err):find("disagrees with the source reader", 1, true) ~= nil,
    "the rejected count names its reader"
  )
end

function T.clear_background_plane_with_trailing_45_keeps_cursor_aligned()
  -- ClearBattlerBg normally takes one source word, but a trailing 45
  -- extends the frame by one word (observed once: EXTRASENSORY member 326
  -- lowers [32,0,45] with the third word consumed). Without consuming it
  -- the decoder misreads the 45 as an opcode and desyncs into its
  -- operands; the following interpreter-state branch (JumpIfContextField01
  -- reads an uninitialized field, so its taken arm is never evaluated and
  -- discovery follows only the fall-through) then queues a garbage target
  -- and the member fails to compile.
  local words = { u32(32), u32(0), u32(45), u32(33), u32(5), u32(4) }
  local program = assert(compiler().compile({ key = "clear-plane-trailing-45", stream = table.concat(words) }))
  Assert.equal(#program.instructions, 3, "every word lands on an instruction boundary")
  Assert.equal(program.instructions[1].op, "clear-background-plane", "the plane word keeps its operation")
  Assert.equal(
    program.instructions[2].op,
    "branch-on-interpreter-state",
    "the following branch decodes in place"
  )
  Assert.equal(
    program.instructions[3].op,
    "reset-battle-presentation",
    "the continuation past the branch stays reachable"
  )
end

function T.every_dispatch_entry_has_a_source_framed_decode_or_a_source_failure()
  local cases = {
    { 21, { 0 }, "unresolved battle background resource" },
    { 46, { 0, 0, 0 }, "unresolved particle action profile" },
    { 47, { 0, 0, 0, 0 }, "unresolved particle action profile" },
    { 48, { 0, 0, 0, 0, 0, 0, 0, 0 }, "unresolved particle action profile" },
    { 49, { 0, 0, 0, 0, 0, 0 }, "unresolved particle action profile" },
    { 57, { 0 }, "unresolved managed sprite resources" },
    { 74, { 0, 0 }, "unresolved sprite-character" },
    { 75, { 0, 0, 0 }, "unresolved sprite-palette" },
    { 76, { 0, 0 }, "unresolved sprite-cell" },
    { 77, { 0, 0 }, "unresolved sprite-animation" },
    { 78, { 0, 0, 0, 0, 0, 0, 0, 0, 0 }, "unresolved configured sprite action" },
    { 79, { 0, 0, 0, 0, 0, 0, 0, 0 }, "unresolved managed sprite template" },
  }
  local stateDependentCursor = {
    [13] = true,
    [14] = true,
    [64] = true,
    [72] = true,
  }
  for _, case in ipairs(cases) do
    local opcode, operands, expectedDependency = case[1], case[2], case[3]
    local words = { u32(opcode) }
    for _, operand in ipairs(operands) do
      words[#words + 1] = u32(operand)
    end
    local ok, err = pcall(compiler().compile, { key = "dispatch-" .. opcode, stream = table.concat(words) })
    Assert.isFalse(ok, "source-dependent handler " .. opcode .. " must fail closed without its native context")
    Assert.isTrue(
      tostring(err):find(expectedDependency, 1, true) ~= nil,
      "handler " .. opcode .. " identifies the unresolved source dependency"
    )
    if not stateDependentCursor[opcode] then
      Assert.isTrue(tostring(err):find("unresolved", 1, true) ~= nil, "handler " .. opcode .. " fails closed")
    end
    local expectedCursor = stateDependentCursor[opcode] and 4 or 4 + #operands * 4
    Assert.equal(
      err.context.cursorOffset,
      expectedCursor,
      "handler " .. opcode .. " validates or identifies its source cursor framing"
    )
    if stateDependentCursor[opcode] then
      Assert.isTrue(
        tostring(err):find("live interpreter state", 1, true) ~= nil,
        "handler " .. opcode .. " names the state-dependent cursor"
      )
    end
  end
  local battlerPicture = assert(compiler().compile({
    key = "dispatch-58",
    stream = table.concat({ u32(58), u32(0), u32(2), u32(1), u32(0x4e23) }),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "battler-sprite-resource-set", "handler 58 requests its source-backed dynamic resource route")
      Assert.deepEqual(operands, { 0, 2, 1, 0x4e23 }, "handler 58 validates all four source operands")
      return {
        battlerTarget = "active-position-first",
        runtimeSelection = "battler-pokemon-picture-resource",
      }
    end,
  }))
  Assert.equal(battlerPicture.instructions[1].op, "create-pokemon-sprite", "handler 58 lowers its sprite side effect")
end

function T.sprite_manager_creation_does_not_consume_the_following_dispatch_word()
  local ok, err = pcall(compiler().compile, {
    key = "sprite-manager-followed-by-resource-load",
    stream = table.concat({ u32(56), u32(57), u32(0), u32(22), u32(1984), u32(0xffffff8b), u32(58) }),
  })
  Assert.isFalse(ok, "opcode 57 dispatches immediately after opcode 56")
  Assert.equal(err.context.offset, 4, "opcode 57 begins immediately after the manager opcode")
  Assert.equal(err.context.cursorOffset, 12, "the unresolved opcode-57 resource selector has a source cursor")
  Assert.isTrue(
    tostring(err):find("unresolved managed sprite resources", 1, true) ~= nil,
    "the source stream reaches opcode 57 resource resolution"
  )
end

function T.assert_only_dispatch_preserves_its_nonadvancing_source_handler()
  local program = assert(compiler().compile({
    key = "assert-only-dispatch",
    stream = table.concat({ u32(55), u32(54) }),
  }))
  Assert.equal(#program.instructions, 1, "the nonadvancing source handler makes following words unreachable")
  Assert.equal(program.instructions[1].op, "source-assertion", "dispatch 55 remains an explicit diagnostic operation")
  Assert.equal(
    program.instructions[1].target,
    2,
    "a tripped assertion service terminates past the stream end"
  )
  Assert.equal(
    program.instructions[1].cursorRule,
    "invoke-assert-service; redispatch-current-word-if-it-returns",
    "the assertion service and unchanged source cursor remain explicit"
  )
  Assert.isTrue(
    require("libs.assets.src.battle.BattleAnimationSchema").assertProgram({
      entry = program.entry,
      instructions = program.instructions,
      subprograms = program.subprograms,
      taskKinds = program.taskKinds,
    }),
    "the source-special failure remains a closed semantic operation"
  )
end

function T.source_input_resolver_lowers_semantic_resources_without_native_selectors()
  local receivedRole
  local receivedOperands
  local program = assert(compiler().compile({
    key = "synthetic-background-resource",
    stream = u32(21) .. u32(0x1234),
    resolveSourceInput = function(role, operands)
      receivedRole = role
      receivedOperands = operands
      return {
        resourceKeys = {
          character = "battle/background/test/character",
          palette = "battle/background/test/palette",
          screenDefault = "battle/background/test/screen-default",
          screenAlternate = "battle/background/test/screen-alternate",
        },
        runtimeSelection = "battle-background-screen-selection",
      }
    end,
  }))
  Assert.equal(receivedRole, "battle-background", "source role remains semantic")
  Assert.deepEqual(receivedOperands, { 0x1234 }, "producer receives source-ordered operands")
  Assert.equal(program.instructions[1].op, "load-battle-background", "background side effect is normalized")
  Assert.deepEqual(program.instructions[1].resourceKeys, {
    character = "battle/background/test/character",
    palette = "battle/background/test/palette",
    screenDefault = "battle/background/test/screen-default",
    screenAlternate = "battle/background/test/screen-alternate",
  }, "only semantic resource keys enter the instruction")
  Assert.equal(
    program.instructions[1].runtimeSelection,
    "battle-background-screen-selection",
    "dynamic screen choice is represented by a typed enum"
  )
  Assert.isNil(program.instructions[1].values, "native selector is absent from runtime IR")
end

function T.managed_sprite_creation_lowers_all_six_typed_resource_roles()
  local expected = {
    character = "battle/sprite/example/character",
    palette = "battle/sprite/example/palette",
    cell = "battle/sprite/example/cell",
    animation = "battle/sprite/example/animation",
    multiCell = "battle/sprite/example/multi-cell",
    multiAnimation = "battle/sprite/example/multi-animation",
  }
  local program = assert(compiler().compile({
    key = "managed-sprite-six-resources",
    stream = table.concat({ u32(79), u32(2), u32(3), u32(10), u32(11), u32(12), u32(13), u32(14), u32(15) }),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "managed-sprite-template", "handler 79 asks the producer to resolve its sprite template")
      Assert.deepEqual(
        operands,
        { 2, 3, 10, 11, 12, 13, 14, 15 },
        "all six native resource references reach the producer"
      )
      return { resourceKeys = expected }
    end,
  }))
  local instruction = program.instructions[1]
  Assert.equal(instruction.op, "create-managed-sprite", "handler 79 creates a managed sprite")
  Assert.deepEqual(instruction.values, { 2, 3 }, "manager and retained sprite slot remain semantic operands")
  Assert.deepEqual(instruction.resourceKeys, expected, "six source resources lower to semantic keys")
  Assert.isNil(instruction.nativeOpcode, "native dispatch indexes stay outside runtime IR")
end

function T.managed_sprite_creation_omits_only_source_absent_multi_resource_roles()
  local required = {
    character = "battle/sprite/example/character",
    palette = "battle/sprite/example/palette",
    cell = "battle/sprite/example/cell",
    animation = "battle/sprite/example/animation",
  }
  local program = assert(compiler().compile({
    key = "managed-sprite-optional-multi-resources",
    stream = table.concat({
      u32(79),
      u32(2),
      u32(3),
      u32(10),
      u32(11),
      u32(12),
      u32(13),
      u32(0xffffffff),
      u32(0xffffffff),
    }),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "managed-sprite-template", "managed sprite resolves source resource identities")
      Assert.deepEqual(operands, { 2, 3, 10, 11, 12, 13, 0xffffffff, 0xffffffff }, "absent roles retain source order")
      return { resourceKeys = required }
    end,
  }))
  Assert.deepEqual(program.instructions[1].resourceKeys, required, "only present semantic resources enter the IR")
  local nonSentinel = assert(compiler().compile({
    key = "managed-sprite-missing-present-multi-resource",
    stream = table.concat({ u32(79), u32(2), u32(3), u32(10), u32(11), u32(12), u32(13), u32(14), u32(0xffffffff) }),
    resolveSourceInput = function()
      return { resourceKeys = required }
    end,
  }))
  Assert.deepEqual(
    nonSentinel.instructions[1].resourceKeys,
    required,
    "an optional native identity with no prior source load remains absent"
  )
end

function T.battle_background_source_plan_uses_the_pinned_row_and_state_selected_screen_pair()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local plan = assert(Sources.resolveSourceSelection("battle-background", { 0 }))
  Assert.deepEqual(plan.sourceSelections, {
    character = { archiveSymbol = "NARC_a_0_0_7", memberId = 59, decoder = "char", kind = "texture" },
    palette = { archiveSymbol = "NARC_a_0_0_7", memberId = 295, decoder = "palette", kind = "palette" },
    screenDefault = { archiveSymbol = "NARC_a_0_0_7", memberId = 56, decoder = "screen", kind = "map" },
    screenAlternate = { archiveSymbol = "NARC_a_0_0_7", memberId = 57, decoder = "screen", kind = "map" },
  }, "the source row supplies exact build-only members for all runtime choices")
  Assert.equal(
    plan.runtimeSelection,
    "battle-background-screen-selection",
    "the source-state decision remains a typed runtime selection"
  )
  local invalid, reason = Sources.resolveSourceSelection("battle-background", { 59 })
  Assert.isNil(invalid, "selector beyond the pinned table is rejected")
  Assert.equal(reason, "battle background selector is outside the pinned table", "bad selector is distinguished")
end

function T.fixed_sprite_resource_handlers_lower_to_semantic_keys()
  local cases = {
    {
      opcode = 57,
      operands = { 3 },
      role = "managed-sprite-resource-set",
      op = "load-managed-sprite-resources",
      keys = { character = "character", palette = "palette", cell = "cell", animation = "animation" },
      values = nil,
    },
    {
      opcode = 74,
      operands = { 2, 19 },
      role = "sprite-character",
      op = "load-sprite-character",
      keys = { character = "character" },
      values = { 2 },
    },
    {
      opcode = 75,
      operands = { 1, 23, 4 },
      role = "sprite-palette",
      op = "load-sprite-palette",
      keys = { palette = "palette" },
      values = { 1, 4 },
    },
    {
      opcode = 76,
      operands = { 0, 7 },
      role = "sprite-cell",
      op = "load-sprite-cell",
      keys = { cell = "cell" },
      values = { 0 },
    },
    {
      opcode = 77,
      operands = { 4, 8 },
      role = "sprite-animation",
      op = "load-sprite-animation",
      keys = { animation = "animation" },
      values = { 4 },
    },
  }
  for _, case in ipairs(cases) do
    local opcode = case.opcode
    local operands = case.operands
    local seenOperands
    local words = { u32(opcode) }
    for _, operand in ipairs(operands) do
      words[#words + 1] = u32(operand)
    end
    local program = assert(compiler().compile({
      key = "synthetic-sprite-resource-" .. opcode,
      stream = table.concat(words),
      resolveSourceInput = function(role, values)
        Assert.equal(role, case.role, "the source resource role is explicit")
        seenOperands = values
        local resourceKeys = {}
        for slot, suffix in pairs(case.keys) do
          resourceKeys[slot] = "battle/sprite/test/" .. suffix
        end
        return {
          resourceKeys = resourceKeys,
          runtimeSelection = opcode == 57 and "battler-resource-selection" or nil,
        }
      end,
    }))
    local instruction = program.instructions[1]
    Assert.equal(instruction.op, case.op, "the source side effect is retained")
    Assert.deepEqual(instruction.values, case.values, "only semantic manager/palette parameters remain")
    Assert.deepEqual(seenOperands, operands, "producer resolves source-ordered operands")
    local expectedKeys = {}
    for slot, suffix in pairs(case.keys) do
      expectedKeys[slot] = "battle/sprite/test/" .. suffix
    end
    Assert.deepEqual(instruction.resourceKeys, expectedKeys, "runtime IR uses semantic resource keys")
    if opcode == 57 then
      Assert.equal(instruction.runtimeSelection, "battler-resource-selection", "battler resource slot is typed")
    end
  end
end

function T.sprite_resource_source_plans_use_pinned_archives_and_members()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local managed = assert(Sources.resolveSourceSelection("managed-sprite-resource-set", { 3 }))
  Assert.deepEqual(managed.sourceSelections, {
    character = { archiveSymbol = "NARC_a_0_0_8", memberId = 76, decoder = "char", kind = "texture" },
    palette = { archiveSymbol = "NARC_a_0_0_8", memberId = 75, decoder = "palette", kind = "palette" },
    cell = { archiveSymbol = "NARC_a_0_0_8", memberId = 77, decoder = "cell", kind = "cell" },
    animation = { archiveSymbol = "NARC_a_0_0_8", memberId = 78, decoder = "animation", kind = "animation" },
  }, "op57 loads its source-fixed resource set")
  Assert.equal(managed.runtimeSelection, "battler-resource-selection", "op57 tags resources by battler state")
  local cases = {
    { "sprite-character", { 2, 19 }, "NARC_a_0_2_2", "character", 19, "char", "texture" },
    { "sprite-palette", { 1, 23, 4 }, "NARC_a_0_2_3", "palette", 23, "palette", "palette" },
    { "sprite-cell", { 0, 7 }, "NARC_a_0_2_4", "cell", 7, "cell", "cell" },
    { "sprite-animation", { 4, 8 }, "NARC_a_0_2_5", "animation", 8, "animation", "animation" },
  }
  for _, case in ipairs(cases) do
    local role, operands = case[1], case[2]
    local plan = assert(Sources.resolveSourceSelection(role, operands))
    Assert.deepEqual(plan.sourceSelections, {
      [case[4]] = {
        archiveSymbol = case[3],
        memberId = case[5],
        decoder = case[6],
        kind = case[7],
      },
    }, role .. " resolves its source member without retaining the resource tag")
  end
end

function T.battler_pokemon_sprite_uses_semantic_target_and_conditional_animation_task()
  local program = assert(compiler().compile({
    key = "synthetic-battler-pokemon-sprite",
    stream = table.concat({ u32(58), u32(0), u32(2), u32(1), u32(0x4e23) }),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "battler-sprite-resource-set", "source role identifies battler picture selection")
      Assert.deepEqual(operands, { 0, 2, 1, 0x4e23 }, "producer sees every source operand in order")
      return {
        battlerTarget = "active-position-first",
        runtimeSelection = "battler-pokemon-picture-resource",
      }
    end,
  }))
  local instruction = program.instructions[1]
  Assert.equal(instruction.op, "create-pokemon-sprite", "the source creates the Pokémon sprite")
  Assert.deepEqual(instruction.values, { 2 }, "only the semantic sprite slot remains numeric")
  Assert.equal(instruction.battlerTarget, "active-position-first", "native target selector is normalized")
  Assert.equal(instruction.runtimeSelection, "battler-pokemon-picture-resource", "sprite resources follow the battler")
  Assert.equal(instruction.taskKind, "pokemon-picture-animation", "source-selected animation task is typed")
  Assert.equal(
    instruction.taskStartRule,
    "picture-active-and-animation-attribute",
    "animation starts only when the source picture supports it"
  )
end

function T.parameter_and_state_branches_normalize_targets_without_source_offsets()
  local parameterProgram = assert(compiler().compile({
    key = "parameter-branch",
    stream = table.concat({ u32(30), u32(2), u32(9), u32(16), u32(54) }),
  }))
  Assert.equal(
    parameterProgram.instructions[1].op,
    "branch-on-parameter",
    "parameter condition has a semantic operation"
  )
  Assert.deepEqual(parameterProgram.instructions[1].values, { 2, 9 }, "parameter operands preserve their meaning")
  Assert.equal(parameterProgram.instructions[1].branchTarget, 2, "source byte target resolves to an instruction index")
  Assert.isNil(parameterProgram.instructions[1].sourceOffset, "normalized branch omits its source byte target")

  local stateProgram = assert(compiler().compile({
    key = "state-branch",
    stream = table.concat({ u32(33), u32(8), u32(54) }),
  }))
  Assert.equal(stateProgram.instructions[1].op, "branch-on-interpreter-state", "state predicate is explicit")
  Assert.isNil(
    stateProgram.instructions[1].branchTarget,
    "the untaken interpreter-state arm stages no discovery destination"
  )
  Assert.deepEqual(stateProgram.instructions[1].values, {}, "the state branch carries no operands")
  Assert.equal(#stateProgram.instructions, 2, "discovery continues past the state branch")
end

function T.battle_field_branch_decodes_the_source_count_target_and_fallthrough()
  local program = assert(compiler().compile({
    key = "battle-field-branch",
    stream = table.concat({ u32(14), u32(7), u32(2), u32(54), u32(54) }),
  }))
  local branch = program.instructions[1]
  Assert.equal(branch.op, "branch-on-battle-field", "opcode 14 compares the battle field")
  Assert.deepEqual(branch.values, { 7 }, "battle field comparison value is preserved")
  Assert.equal(branch.branchTarget, 3, "matching comparison branches to the count-derived target")
  Assert.equal(program.instructions[2].op, "noop", "nonmatching path advances one word after the count")
  Assert.equal(program.instructions[3].op, "noop", "matching path target is reachable in the decoded CFG")
end

function T.flag_and_side_branches_preserve_both_count_derived_cursor_destinations()
  local flagProgram = assert(compiler().compile({
    key = "battle-flag-cursor-branch",
    stream = table.concat({ u32(13), u32(2), u32(2), u32(54), u32(54), u32(54) }),
  }))
  Assert.equal(flagProgram.instructions[1].op, "branch-on-battle-flag", "opcode 13 tests the battle flag")
  Assert.deepEqual(flagProgram.instructions[1].values, { 1 }, "flag mask is normalized")
  Assert.equal(flagProgram.instructions[1].alternateTarget, 2, "unset flag advances from its count word")
  Assert.equal(flagProgram.instructions[1].branchTarget, 3, "set flag skips one word before reading its count")

  local sideProgram = assert(compiler().compile({
    key = "battle-side-cursor-branch",
    stream = table.concat({ u32(64), u32(0), u32(1), u32(1), u32(54) }),
  }))
  Assert.equal(sideProgram.instructions[1].op, "branch-on-side-predicate", "opcode 64 compares its resolved side")
  Assert.equal(sideProgram.instructions[1].alternateTarget, 2, "ordinary side result uses the first count")
  Assert.equal(sideProgram.instructions[1].branchTarget, 3, "special side result uses the extra-word count")
end

function T.side_equality_and_battle_flag_branches_keep_distinct_cursor_destinations()
  local sideStream = { u32(72), u32(2) }
  for _ = 1, 60 do
    sideStream[#sideStream + 1] = u32(54)
  end
  local sideProgram = assert(compiler().compile({
    key = "side-equality-cursor-branch",
    stream = table.concat(sideStream),
  }))
  Assert.equal(sideProgram.instructions[1].op, "branch-on-side-equality", "opcode 72 compares the two side classes")
  Assert.equal(sideProgram.instructions[1].alternateTarget, 2, "unequal side classes advance to start+8")
  Assert.equal(sideProgram.instructions[1].branchTarget, 3, "equal side classes branch to start+4+count*4")

  local flagProgram = assert(compiler().compile({
    key = "battle-state-flag-cursor-branch",
    stream = table.concat({ u32(87), u32(0), u32(2), u32(54), u32(54), u32(54) }),
  }))
  Assert.equal(flagProgram.instructions[1].op, "branch-on-battle-flag", "opcode 87 tests battle-state bit 1")
  Assert.deepEqual(flagProgram.instructions[1].values, { 2 }, "state flag mask remains semantic")
  Assert.equal(flagProgram.instructions[1].alternateTarget, 2, "clear flag consumes the branch count word")
  Assert.equal(flagProgram.instructions[1].branchTarget, 3, "set flag follows the count-derived destination")
end

function T.cry_wait_preserves_the_finished_and_unfinished_cursor_paths()
  local program = assert(compiler().compile({
    key = "cry-wait-cursor-branch",
    stream = table.concat({ u32(66), u32(54), u32(54) }),
  }))
  local wait = program.instructions[1]
  Assert.equal(wait.op, "wait-for-cry", "opcode 66 waits on the cry state")
  Assert.deepEqual(wait.values, { 54 }, "the native cry parameter remains a value")
  Assert.isNil(wait.sound, "the cry parameter is not a sound sequence")
  Assert.equal(wait.branchTarget, 1, "finished cry leaves the cursor on the current opcode")
  Assert.equal(wait.alternateTarget, 2, "unfinished cry consumes its operand")
end

function T.play_cry_consumes_three_native_words_before_dispatching_the_next_command()
  local program = assert(compiler().compile({
    key = "play-cry-source-frame",
    stream = table.concat({ u32(65), u32(10), u32(0xffffff8b), u32(127), u32(54) }),
  }))
  Assert.equal(#program.instructions, 2, "opcode 65 consumes exactly three payload words")
  Assert.equal(program.instructions[1].op, "play-cry")
  Assert.deepEqual(program.instructions[1].values, { 10, -117, 127 })
  Assert.equal(program.instructions[2].op, "noop", "the following command is dispatched after three payload words")
end

function T.visual_task_selectors_resolve_to_closed_semantic_task_kinds()
  local program = assert(compiler().compile({
    key = "visual-task-dispatch",
    stream = table.concat({ u32(16), u32(9), u32(0x12340004), u32(18), u32(7), u32(0xabcd0002) }),
  }))
  Assert.equal(program.instructions[1].op, "start-visual-task", "opcode 16 schedules its selected task")
  Assert.equal(
    program.instructions[1].taskKind,
    "battle-background-resource-load",
    "selector 4 resolves from the pinned table"
  )
  Assert.deepEqual(
    program.instructions[1].values,
    { 9, 0x1234 },
    "task arguments preserve the full first word and packed high half"
  )
  Assert.equal(
    program.instructions[2].taskKind,
    "battle-presentation-resource-cleanup",
    "opcode 18 adds three before table selection"
  )
  Assert.deepEqual(program.instructions[2].values, { 7, 0xabcd }, "opcode 18 preserves its task arguments")

  local ok, err = pcall(compiler().compile, {
    key = "visual-task-invalid-selector",
    stream = table.concat({ u32(16), u32(0), u32(6) }),
  })
  Assert.isFalse(ok, "out-of-range task-table selector fails closed")
  Assert.equal(err.context.cursorOffset, 12, "invalid selector is rejected after its full source frame")
end

function T.context_selected_visual_task_preserves_all_source_alternatives()
  local program = assert(compiler().compile({
    key = "context-selected-task",
    stream = table.concat({ u32(34), u32(11), u32(22), u32(33) }),
  }))
  local task = program.instructions[1]
  Assert.equal(task.op, "schedule-battle-task", "opcode 34 schedules its source task")
  Assert.equal(task.taskKind, "battle-background-blend-transition", "initializer selects visual callback zero")
  Assert.equal(
    task.taskInputRule,
    "helper-equals-one-then-side-class-equals-three-else-first",
    "runtime selection priority follows the pinned comparisons"
  )
  Assert.deepEqual(task.values, { 11, 22, 33 }, "all three candidate task inputs remain ordered")
end

function T.side_mask_branch_preserves_each_source_table_destination()
  local program = assert(compiler().compile({
    key = "side-mask-cursor-branches",
    stream = table.concat({ u32(70), u32(1), u32(1), u32(1), u32(1), u32(1), u32(1), u32(54) }),
  }))
  local branch = program.instructions[1]
  Assert.equal(branch.op, "branch-on-side-mask", "opcode 70 branches from its active-side mask")
  Assert.deepEqual(branch.branchCases, {
    { sideMask = 0, target = 2 },
    { sideMask = 3, target = 3 },
    { sideMask = 12, target = 4 },
    { sideMask = 48, target = 5 },
    { sideMask = 192, target = 6 },
    { otherwise = true, target = 7 },
  }, "each source mask-table match retains its count-derived destination")
  Assert.isTrue(
    require("libs.assets.src.battle.BattleAnimationSchema").assertProgram({
      entry = program.entry,
      instructions = program.instructions,
      subprograms = program.subprograms,
      taskKinds = program.taskKinds,
    }),
    "the branch table conforms to the closed program schema"
  )
end

function T.interpreter_state_task_branch_preserves_count_and_consumed_word_paths()
  local program = assert(compiler().compile({
    key = "interpreter-task-state-branch",
    stream = table.concat({ u32(71), u32(2), u32(54), u32(54), u32(54) }),
  }))
  local branch = program.instructions[1]
  Assert.equal(branch.op, "branch-on-interpreter-state", "opcode 71 branches on its context helper result")
  Assert.deepEqual(branch.values, { 1 }, "source predicate compares the helper result to one")
  Assert.equal(branch.alternateTarget, 2, "other helper results continue immediately after the count word")
  Assert.equal(branch.branchTarget, 3, "helper result one targets count words from the count field")
  Assert.equal(program.instructions[2].op, "noop", "the false path begins at the first following command")
  Assert.equal(program.instructions[3].op, "noop", "the true path remains a parsed instruction boundary")
end

function T.nested_branch_compilation_visits_each_source_target_before_boundary_validation()
  local program = compiler().compile({
    key = "nested-branch-targets",
    stream = table.concat({
      u32(71),
      u32(6),
      u32(64),
      u32(0),
      u32(5),
      u32(6),
      u32(0),
      u32(56),
      u32(9),
      u32(9),
      u32(9),
      u32(9),
    }),
  })
  Assert.equal(program.instructions[1].op, "branch-on-interpreter-state")
  Assert.equal(program.instructions[1].branchTarget, 3, "state match target is decoded after the lower alternate path")
  Assert.equal(program.instructions[1].alternateTarget, 2)
  Assert.equal(program.instructions[2].op, "branch-on-side-predicate")
  Assert.equal(program.instructions[2].branchTarget, 7)
  Assert.equal(program.instructions[2].alternateTarget, 5)
  Assert.equal(program.instructions[3].op, "create-managed-sprite-manager")
end

function T.manager_lifecycle_handlers_lower_their_source_side_effects()
  local program = assert(compiler().compile({
    key = "manager-lifecycle",
    stream = table.concat({ u32(56), u32(59), u32(54) }),
  }))
  Assert.equal(program.instructions[1].op, "create-managed-sprite-manager", "opcode 56 creates the source manager")
  Assert.equal(program.instructions[2].op, "dispose-shared-sprite-manager", "opcode 59 disposes the shared manager")
  Assert.equal(program.instructions[3].op, "noop", "the command after disposal is dispatched next")
  Assert.isTrue(require("libs.assets.src.battle.BattleAnimationSchema").assertProgram({
    entry = program.entry,
    instructions = program.instructions,
    subprograms = program.subprograms,
    taskKinds = program.taskKinds,
  }))
end

function T.sprite_manager_disposal_does_not_consume_the_next_command()
  local program = assert(compiler().compile({
    key = "sprite-manager-disposal-cursor",
    stream = table.concat({ u32(59), u32(54) }),
  }))
  Assert.equal(#program.instructions, 2, "opcode 59 consumes only itself and dispatches the next command")
  Assert.equal(program.instructions[1].op, "dispose-shared-sprite-manager")
  Assert.equal(program.instructions[2].op, "noop", "opcode 54 immediately follows manager disposal")
end

function T.manager_capacity_and_disposal_source_inputs_are_notified_in_command_order()
  local calls = {}
  local program = assert(compiler().compile({
    key = "managed-sprite-manager-source-state",
    stream = table.concat({
      u32(73),
      u32(2),
      u32(5),
      u32(11),
      u32(12),
      u32(13),
      u32(14),
      u32(15),
      u32(16),
      u32(80),
      u32(2),
    }),
    resolveSourceInput = function(role, operands)
      calls[#calls + 1] = { role = role, operands = operands }
      return {}
    end,
  }))
  Assert.deepEqual(calls, {
    {
      role = "managed-sprite-manager-capacities",
      operands = { 2, 5, 11, 12, 13, 14, 15, 16 },
    },
    { role = "managed-sprite-manager-disposal", operands = { 2 } },
  }, "manager source state updates follow the native command order")
  Assert.equal(program.instructions[1].op, "create-sprite-manager")
  Assert.deepEqual(program.instructions[1].values, { 2, 5, 11, 12, 13, 14, 15, 16 })
  Assert.equal(program.instructions[2].op, "dispose-sprite-manager")
  Assert.deepEqual(program.instructions[2].values, { 2 })
end

function T.effect_and_cry_handlers_lower_their_source_side_effects()
  local program = assert(compiler().compile({
    key = "effect-and-cry-lifecycle",
    stream = table.concat({ u32(53), u32(2), u32(65), u32(0x1234), u32(0xfffffffe), u32(7), u32(67), u32(0) }),
  }))
  Assert.equal(program.instructions[1].op, "destroy-battler-effect", "opcode 53 destroys its indexed effect")
  Assert.deepEqual(program.instructions[1].values, { 2 }, "effect index remains the semantic operand")
  Assert.equal(program.instructions[2].op, "play-cry", "opcode 65 starts the source cry action")
  Assert.deepEqual(program.instructions[2].values, { 0x1234, -2, 7 }, "cry operands preserve source narrowing")
  Assert.equal(program.instructions[3].op, "clear-parameters", "opcode 67 clears the context parameter block")
  Assert.equal(#program.instructions, 3, "ignored words stay within their owning handlers")
end

function T.secondary_battler_effect_constructor_preserves_its_live_parameters()
  local program = assert(compiler().compile({
    key = "secondary-battler-effect",
    stream = table.concat({ u32(52), u32(2), u32(0xdeadbeef), u32(7), u32(54) }),
  }))
  local effect = program.instructions[1]
  Assert.equal(effect.op, "create-parameterized-battler-effect", "opcode 52 invokes its fixed-size effect constructor")
  Assert.equal(effect.taskKind, "battler-effect-continuation", "created effect uses its source continuation")
  Assert.deepEqual(effect.values, { 2, 7 }, "the battler and constructor parameter are read around one skipped word")
  Assert.equal(program.instructions[2].op, "noop", "the constructor consumes three operand words")
  Assert.deepEqual(program.taskKinds, { "battler-effect-continuation" }, "program closes over the effect continuation")
end

function T.loop_slots_preserve_available_busy_and_repeat_cursor_paths()
  local program = assert(compiler().compile({
    key = "loop-slot-control-flow",
    stream = table.concat({ u32(2), u32(1), u32(54), u32(3), u32(54) }),
  }))
  local reserve = program.instructions[1]
  Assert.equal(reserve.op, "reserve-loop-slot", "opcode 2 reserves one source loop slot")
  Assert.deepEqual(reserve.values, { 1 }, "loop count is narrowed to the source byte")
  Assert.equal(
    reserve.cursorRule,
    "advance-to-body-when-loop-slot-free; otherwise-redispatch-count-word",
    "full source loop tables redispatch the count word instead of taking a static branch"
  )
  Assert.equal(reserve.branchTarget, 2, "available slots enter the command after the count")
  Assert.equal(reserve.resumeTarget, 2, "opcode 3 repeats the body after the count")
  Assert.isNil(reserve.alternateTarget, "occupied-slot retry has no static instruction target")
  local advance = program.instructions[3]
  Assert.equal(advance.op, "advance-loop-slot", "opcode 3 advances the active loop slot")
  Assert.equal(
    advance.cursorRule,
    "rewind-to-active-loop-body-until-count",
    "source counter either rewinds or clears the active slot"
  )
  Assert.equal(program.instructions[4].op, "noop", "opcode 3 consumes no word after its own dispatch word")
  Assert.equal(program.sourceOffsets[4], 16, "the next command stays at the word immediately after opcode 3")
  Assert.isTrue(
    require("libs.assets.src.battle.BattleAnimationSchema").assertProgram({
      entry = program.entry,
      instructions = program.instructions,
      subprograms = program.subprograms,
      taskKinds = program.taskKinds,
    }),
    "the dynamic retry semantics remain in the closed program contract"
  )
end

function T.return_slots_preserve_subprogram_entry_and_return_cursor()
  local program = assert(compiler().compile({
    key = "subprogram-return-control-flow",
    stream = table.concat({ u32(10), u32(3), u32(54), u32(54), u32(11), u32(54), u32(54) }),
  }))
  local instructionAtOffset = {}
  for index, offset in ipairs(program.sourceOffsets) do
    instructionAtOffset[offset] = index
  end
  local call = program.instructions[assert(instructionAtOffset[0])]
  Assert.equal(call.op, "call-subprogram", "opcode 10 records a return slot and calls a block")
  Assert.isNil(call.alternateTarget, "the full-stack cursor is dynamic, not a static dispatch edge")
  Assert.equal(call.branchTarget, instructionAtOffset[16], "available return slot enters the counted block")
  Assert.equal(call.returnTarget, instructionAtOffset[8], "call saves the instruction after its count word")
  Assert.equal(call.cursorRule, "call-first-free-subprogram-slot; all-slots-busy-redispatch-count-word")
  local returnInstruction = program.instructions[instructionAtOffset[16]]
  Assert.equal(returnInstruction.op, "return-subprogram", "opcode 11 returns from the latest active slot")
  Assert.equal(
    returnInstruction.cursorRule,
    "return-to-active-subprogram-slot",
    "return cursor is the saved normalized target"
  )
end

function T.managed_sprite_effect_preserves_mode_slots_and_task_start_condition()
  local program = assert(compiler().compile({
    key = "managed-sprite-effect",
    stream = table.concat({ u32(82), u32(1), u32(3), u32(2), u32(54) }),
  }))
  local effect = program.instructions[1]
  Assert.equal(effect.op, "start-sprite-effect", "opcode 82 configures a managed sprite effect")
  Assert.deepEqual(effect.values, { 3, 2 }, "both selected sprite slots are retained")
  Assert.equal(
    effect.mode,
    "second-battler-class-priority-forward",
    "source mode is normalized to its context-dependent draw rule"
  )
  Assert.equal(effect.taskKind, "managed-sprite-draw-loop", "the source task keeps drawing the sprite system")
  Assert.equal(effect.taskStartRule, "battle-helper-equals-one", "task creation uses the source helper condition")
  Assert.equal(program.instructions[2].op, "noop", "opcode 82 consumes all three words")

  local expectedModes = {
    [0] = "first-battler-class-priority-gate",
    [2] = "first-battler-class-priority-alternate",
    [3] = "second-battler-class-priority-reverse",
    [4] = "retain-source-draw-state",
  }
  for mode, expected in pairs(expectedModes) do
    local variant = assert(compiler().compile({
      key = "managed-sprite-effect-mode-" .. mode,
      stream = table.concat({ u32(82), u32(mode), u32(3), u32(2) }),
    }))
    Assert.equal(variant.instructions[1].mode, expected, "source mode maps to a closed draw rule")
  end
end

function T.visual_record_update_resolves_task_and_signed_axis_adjustment()
  local program = assert(compiler().compile({
    key = "visual-record-axis-update",
    stream = table.concat({ u32(86), u32(11), u32(0xabcd0004), u32(0x0001ffff) }),
  }))
  local update = program.instructions[1]
  Assert.equal(update.op, "update-battle-visual", "opcode 86 updates its newly allocated visual record")
  Assert.equal(
    update.taskKind,
    "battle-background-resource-load",
    "callback selector resolves through the source task table"
  )
  Assert.equal(update.updateKind, "increase-x", "packed operation selector maps to a named axis change")
  Assert.deepEqual(update.values, { 11, 0xabcd, -1 }, "record arguments and signed delta are normalized")
  Assert.deepEqual(
    program.taskKinds,
    { "battle-background-resource-load" },
    "task inventory uses the resolved semantic kind"
  )

  local ok, err = pcall(compiler().compile, {
    key = "visual-record-invalid-update",
    stream = table.concat({ u32(86), u32(11), u32(0x00060004), u32(0x00070001) }),
  })
  Assert.isFalse(ok, "unknown task selector fails closed")
  Assert.equal(err.context.cursorOffset, 16, "invalid task selector is rejected after the complete frame")

  ok, err = pcall(compiler().compile, {
    key = "visual-record-invalid-axis-update",
    stream = table.concat({ u32(86), u32(11), u32(0xabcd0004), u32(0x0007ffff) }),
  })
  Assert.isFalse(ok, "the source assertion rejects an unknown axis operation")
  Assert.equal(err.context.cursorOffset, 16, "invalid axis operation is rejected after the complete frame")
end

function T.battler_state_byte_handlers_preserve_index_and_byte_narrowing()
  local program = assert(compiler().compile({
    key = "battler-state-bytes",
    stream = table.concat({ u32(62), u32(12), u32(0x1234), u32(63), u32(16), u32(0x1fe), u32(54) }),
  }))
  Assert.equal(program.instructions[1].op, "set-battler-state-byte", "opcode 62 updates the state byte")
  Assert.deepEqual(
    program.instructions[1].values,
    { 12, 0x34 },
    "state byte assignment keeps indexed slot and u8 value"
  )
  Assert.equal(program.instructions[2].op, "set-battler-effect-byte", "opcode 63 updates the effect byte")
  Assert.deepEqual(program.instructions[2].values, { 16, 0xfe }, "effect byte assignment narrows the value")
end

function T.presentation_record_handlers_lower_their_distinct_submissions()
  local program = assert(compiler().compile({
    key = "presentation-records",
    stream = u32(68) .. u32(2) .. u32(69) .. u32(3) .. u32(54),
  }))
  Assert.equal(program.instructions[1].op, "submit-presentation-layout", "opcode 68 submits the selected layout")
  Assert.deepEqual(program.instructions[1].values, { 2 }, "layout selector is preserved")
  Assert.equal(program.instructions[2].op, "submit-presentation-update", "opcode 69 submits the update record")
  Assert.deepEqual(program.instructions[2].values, { 3 }, "update selector is preserved")
end

function T.destroy_task_slot_handler_preserves_the_selected_slot()
  local program = assert(compiler().compile({
    key = "destroy-task-slot",
    stream = u32(61) .. u32(4) .. u32(54),
  }))
  Assert.equal(program.instructions[1].op, "destroy-effect-slot", "opcode 61 destroys the indexed task-backed effect")
  Assert.deepEqual(program.instructions[1].values, { 4 }, "special slot index remains a semantic value")
end

function T.particle_creation_resolves_the_source_resource_to_a_semantic_key()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local program = assert(compiler().compile({
    key = "tackle-particle",
    stream = u32(51) .. u32(2) .. u32(64) .. u32(54),
  }))
  Assert.equal(program.instructions[1].op, "create-battler-effect", "opcode 51 creates a battle particle")
  Assert.equal(program.instructions[1].resource, "battle/particle/tackle", "SPL member resolves to a semantic key")
  Assert.equal(program.instructions[1].emitterPosition, "player-side-slot-1", "battler slot is a semantic position")
  Assert.equal(program.instructions[2].op, "noop", "the resource selector is consumed by the creation operation")

  local supersonic = assert(compiler().compile({
    key = "supersonic-particle",
    stream = u32(51) .. u32(0) .. u32(79) .. u32(54),
  }))
  Assert.equal(supersonic.instructions[1].resource, "battle/particle/supersonic")
  Assert.deepEqual(
    Sources.resolveParticleSource("battle/particle/supersonic"),
    { archiveSymbol = "NARC_a_0_2_9", memberId = 79, decoder = "spl", kind = "particle" },
    "source maps the observed SUPERSONIC member to a semantic SPL identity"
  )

  local asleep = assert(compiler().compile({
    key = "asleep-particle",
    stream = u32(51) .. u32(2) .. u32(27) .. u32(54),
  }))
  Assert.equal(
    asleep.instructions[1].resource,
    "battle/particle/asleep",
    "status animation resolves to a semantic particle identity"
  )
  Assert.deepEqual(
    Sources.resolveParticleSource("battle/particle/asleep"),
    { archiveSymbol = "NARC_a_0_2_9", memberId = 27, decoder = "spl", kind = "particle" },
    "producer resolves the semantic particle identity to its pinned source"
  )

  local ok, err = pcall(compiler().compile, {
    key = "unresolved-particle",
    stream = u32(51) .. u32(2) .. u32(65),
  })
  Assert.isFalse(ok, "an unbound particle selector cannot become a runtime resource id")
  Assert.equal(err.context.cursorOffset, 12, "unresolved resource reports the parsed cursor")
end

function T.particle_creation_routes_its_member_through_the_build_source_resolver()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local resolvedSource = false
  local program = assert(compiler().compile({
    key = "resolved-particle-member",
    stream = table.concat({ u32(51), u32(2), u32(27) }),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "battler-particle-resource", "opcode51 declares the loaded APS source")
      Assert.deepEqual(operands, { 2, 27 }, "the source role receives battler and member operands")
      resolvedSource = true
      local selection = assert(Sources.resolveSourceSelection(role, operands))
      return { resourceKeys = selection.resourceKeys }
    end,
  }))
  Assert.isTrue(resolvedSource, "opcode51 must use its producer source route")
  Assert.equal(program.instructions[1].resource, "battle/particle/asleep")
  Assert.equal(
    program.instructions[1].emitterPosition,
    "player-side-slot-1",
    "only the semantic battler context remains in IR"
  )
end

function T.pokemon_picture_modes_preserve_the_optional_animation_task()
  local program = assert(compiler().compile({
    key = "pokemon-picture-modes",
    stream = table.concat({ u32(31), u32(1), u32(1), u32(31), u32(2), u32(0), u32(54) }),
  }))
  Assert.equal(program.instructions[1].op, "show-pokemon-picture", "opcode 31 shows the selected battler picture")
  Assert.equal(program.instructions[1].taskKind, "pokemon-picture-animation", "mode one installs its source task")
  Assert.deepEqual(program.instructions[1].values, { 1, 1 }, "picture selection and mode remain semantic operands")
  Assert.isNil(program.instructions[2].taskKind, "other picture modes do not schedule that task")
  Assert.deepEqual(program.taskKinds, { "pokemon-picture-animation" }, "program inventory includes its used task")
end

function T.wait_handlers_preserve_their_runtime_dependent_cursor_rules()
  local cases = {
    {
      opcode = 1,
      op = "wait-interpreter-counter",
      cursorRule = "pending-redispatch-current-opcode; zero-advances-past-current-opcode",
      branchTarget = 1,
    },
    { opcode = 19, op = "wait-for-battle-phase", value = 2, cursorRule = "advance-when-phase-matches" },
    { opcode = 20, op = "wait-for-battle-phase", value = 0, cursorRule = "advance-when-phase-matches" },
    { opcode = 29, op = "wait-for-sound", value = 90, cursorRule = "advance-when-sound-finishes" },
    { opcode = 50, op = "wait-for-battler-effects", cursorRule = "advance-when-effects-finish" },
    { opcode = 84, op = "wait-for-confirm-input", value = 1, cursorRule = "advance-when-confirm-input-matches" },
  }
  for _, case in ipairs(cases) do
    local program = assert(compiler().compile({
      key = "source-wait-" .. case.opcode,
      stream = u32(case.opcode) .. u32(54),
    }))
    local wait = program.instructions[1]
    Assert.equal(wait.op, case.op, "wait opcode " .. case.opcode .. " has a semantic operation")
    Assert.equal(
      wait.cursorRule,
      case.cursorRule,
      "wait opcode " .. case.opcode .. " preserves conditional advancement"
    )
    if case.value ~= nil then
      Assert.deepEqual(wait.values, { case.value }, "wait opcode " .. case.opcode .. " preserves source predicate data")
    end
    if case.branchTarget ~= nil then
      Assert.equal(
        wait.branchTarget,
        case.branchTarget,
        "wait opcode " .. case.opcode .. " preserves its conditional target"
      )
    end
    Assert.equal(program.instructions[2].op, "noop", "the next opcode is not consumed as an operand")
  end
end

-- Computed source-timing durations ride the normalized program: the
-- mosaic and panel lowerings now emit durationTicks, and the callback
-- schema admits it, so schema-validated compilation accepts them.
---@return nil
function T.computed_callback_durations_pass_the_normalized_callback_schema()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local Schema = require("libs.assets.src.battle.BattleAnimationSchema")
  local function assertSchema(program, key)
    Assert.isTrue(Schema.assertProgram({
      entry = program.entry,
      instructions = program.instructions,
      subprograms = program.subprograms,
      taskKinds = program.taskKinds,
    }), key .. " with computed durationTicks passes the normalized callback schema")
  end
  local mosaic = assert(compiler().compile({
    key = "mosaic-with-computed-duration",
    stream = table.concat({ u32(45), u32(69), u32(4), u32(2), u32(0xFFFE), u32(4), u32(12) }),
    resolveSourceInput = function(role, operands)
      return Sources.resolveSourceSelection(role, operands)
    end,
  }))
  Assert.equal(mosaic.instructions[1].callback, "battle-sprite-mosaic-transition")
  Assert.equal(mosaic.instructions[1].parameters.durationTicks, 3)
  assertSchema(mosaic, "mosaic")
end

return { tests = T }
