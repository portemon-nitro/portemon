-- Battle animation records expose only closed semantic operations.

local Assert = require("tests.support.Assert")

local T = {}

local function schema()
  return require("libs.assets.src.battle.BattleAnimationSchema")
end

local function program(instruction)
  return { entry = "main", instructions = { instruction }, subprograms = {}, taskKinds = {} }
end

function T.program_schema_rejects_unknown_operations_and_native_dispatch_identity()
  local ok, err = pcall(schema().assertProgram, program({ op = "native-opcode-91", values = { 3 } }))
  Assert.isFalse(ok, "an arbitrary operation cannot enter normalized IR")
  Assert.isTrue(tostring(err):find("operation", 1, true) ~= nil, "unknown operation has a schema diagnostic")

  ok = pcall(schema().assertProgram, program({ op = "set-parameter", values = { 2, 4 }, nativeOpcode = 12 }))
  Assert.isFalse(ok, "source dispatch identity cannot enter normalized IR")
end

function T.program_schema_accepts_a_typed_semantic_operation()
  Assert.isTrue(schema().assertProgram(program({ op = "set-parameter", values = { 2, 4 } })))
end

function T.synchronous_palette_buffer_operations_are_closed()
  Assert.isTrue(schema().assertProgram(program({ op = "copy-main-background-palette-to-fade-buffer" })))
  Assert.isTrue(schema().assertProgram(program({ op = "grayscale-main-background-fade-buffer" })))
  Assert.isFalse(pcall(schema().assertProgram, program({ op = "native-palette-mode-1" })))
end

function T.interpreter_counter_wait_requires_both_source_cursor_paths()
  local instructions = {
    {
      op = "wait-interpreter-counter",
      cursorRule = "pending-redispatch-current-opcode; zero-advances-past-current-opcode",
      branchTarget = 1,
    },
    { op = "noop" },
    { op = "noop" },
  }
  local sourceWait = {
    entry = "main",
    instructions = instructions,
    subprograms = {},
    taskKinds = {},
  }
  Assert.isTrue(schema().assertProgram(sourceWait))

  instructions[1].branchTarget = nil
  Assert.isFalse(pcall(schema().assertProgram, sourceWait), "pending self-loop target is required")
  instructions[1].branchTarget = 1
  instructions[1].cursorRule = "advance-when-counter-zero"
  Assert.isFalse(pcall(schema().assertProgram, sourceWait), "the pending path remains explicit in the cursor rule")
  instructions[1].cursorRule = "pending-redispatch-current-opcode; zero-advances-past-current-opcode"
  instructions[1].branchTarget = 5
  Assert.isFalse(pcall(schema().assertProgram, sourceWait), "pending self-loop target must remain within the instruction boundary")
end

function T.subprogram_call_schema_keeps_stack_saturation_as_a_cursor_rule()
  local instructions = {
    {
      op = "call-subprogram",
      branchTarget = 2,
      returnTarget = 2,
      cursorRule = "call-first-free-subprogram-slot; all-slots-busy-redispatch-count-word",
    },
    { op = "return-subprogram", cursorRule = "return-to-active-subprogram-slot" },
  }
  local sourceCall = {
    entry = "main",
    instructions = instructions,
    subprograms = {},
    taskKinds = {},
  }
  Assert.isTrue(schema().assertProgram(sourceCall))
  instructions[1].alternateTarget = 2
  Assert.isFalse(pcall(schema().assertProgram, sourceCall), "the unreachable operand cursor is not a static edge")
end

function T.vanished_picture_operation_has_closed_semantic_picture_sets()
  local instruction = {
    op = "set-pokemon-picture-vanished",
    pictureSets = { "all-battler-positions", "opposing-battler-pair-when-enabled" },
    vanished = true,
  }
  Assert.isTrue(schema().assertProgram(program(instruction)))
  instruction.pictureSets[2] = "native-mask-0x10"
  local ok = pcall(schema().assertProgram, program(instruction))
  Assert.isFalse(ok, "source masks cannot enter runtime picture-set selections")
  instruction.pictureSets = { "active-battler" }
  instruction.vanished = 1
  ok = pcall(schema().assertProgram, program(instruction))
  Assert.isFalse(ok, "vanished state has a boolean semantic type")
end

function T.animation_callback_schema_closes_tackle_semantics_and_parameters()
  local instruction = {
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-offset-transition",
    taskKind = "pokemon-picture-position-offset-transition",
    taskContext = "pokemon-picture",
    parameters = {
      pictureTarget = "active-battler",
      durationTicks = 2,
      offsetX = 14,
      offsetY = -8,
    },
  }
  Assert.isTrue(schema().assertProgram(program(instruction)))
  instruction.callback = "native-selector-57"
  local ok = pcall(schema().assertProgram, program(instruction))
  Assert.isFalse(ok, "native callback selectors cannot enter normalized IR")
  instruction.callback = "pokemon-picture-offset-transition"
  instruction.parameters.pictureTarget = "native-selector-57"
  ok = pcall(schema().assertProgram, program(instruction))
  Assert.isFalse(ok, "picture targets are closed semantic values")
  instruction.parameters.pictureTarget = "active-battler"
  instruction.parameters.offsetY = 0x8000
  ok = pcall(schema().assertProgram, program(instruction))
  Assert.isFalse(ok, "picture offsets must preserve their signed source width")
end

function T.move_power_picture_transition_requires_a_typed_event_input_and_fixed_mapping()
  local instruction = {
    op = "invoke-battle-animation-callback",
    callback = "battle-background-four-picture-move-power-transition",
    taskKind = "battle-background-four-picture-move-power-transition",
    taskContext = "battle-display",
    parameters = {
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
    },
  }
  local effect = {
    schema = "g4-battle-effect-v1",
    key = "move-power-picture-transition",
    catalogIdentity = "synthetic-catalog",
    program = program(instruction),
    dependencies = {},
    resources = {},
    requiredContext = {},
  }
  Assert.isTrue(schema().assertProgram(effect.program))
  effect.requiredContext.battlerTopology = { type = "battle-animation-battler-topology" }
  Assert.isFalse(pcall(schema().assertEffect, effect), "move-power transition requires its event-time input")
  effect.requiredContext.movePower = { type = "battle-animation-move-power-u16" }
  Assert.isTrue(schema().assertEffect(effect))

  effect.requiredContext.movePower.type = "native-context-word"
  Assert.isFalse(pcall(schema().assertEffect, effect), "move power context is semantic and u16-bounded")
  effect.requiredContext.movePower.type = "battle-animation-move-power-u16"
  instruction.parameters.profileByMovePower[1].profile = 0
  Assert.isFalse(pcall(schema().assertEffect, effect), "source move-power cases retain their profile mapping")
  instruction.parameters.profileByMovePower[1].profile = 1
  instruction.parameters.defaultProfile = 1
  Assert.isFalse(pcall(schema().assertEffect, effect), "other u16 values use the source default profile")
end

function T.target_picture_priority_callback_has_a_strict_task_contract()
  local instruction = {
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-target-priority-transition",
    taskKind = "pokemon-picture-target-priority-transition",
    taskContext = "pokemon-picture",
    battlerTarget = "target",
    parameters = {},
  }
  Assert.isTrue(schema().assertProgram(program(instruction)))
  instruction.battlerTarget = "attacker"
  Assert.isFalse(pcall(schema().assertProgram, program(instruction)))
end

function T.target_picture_bg_slide_callback_has_a_strict_task_contract()
  Assert.isTrue(schema().assertProgram(program({
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-target-background-slide",
    taskKind = "pokemon-picture-target-background-slide",
    taskContext = "battle-display",
    battlerTarget = "target",
    parameters = {},
  })))
end

function T.two_phase_picture_scale_callback_has_typed_source_parameters()
  local instruction = {
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-two-phase-scale-transition",
    taskKind = "pokemon-picture-two-phase-scale-transition",
    taskContext = "pokemon-picture",
    parameters = {
      firstEndpoint = -8,
      firstDurationTicks = 9,
      phaseDelayTicks = 11,
      secondEndpointX = -8,
      secondEndpointY = 7,
      secondDurationTicks = 3,
    },
  }
  Assert.isTrue(schema().assertProgram(program(instruction)))
  instruction.parameters.phaseDelayTicks = 256
  Assert.isFalse(pcall(schema().assertProgram, program(instruction)))
  instruction.parameters.phaseDelayTicks = 11
  instruction.parameters.firstEndpoint = 0x8000
  Assert.isFalse(pcall(schema().assertProgram, program(instruction)))
end

function T.managed_sprite_scale_pulse_declares_its_sprite_context_dependency()
  local instruction = {
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-managed-sprite-scale-pulse-attacker",
    taskKind = "pokemon-picture-managed-sprite-scale-pulse",
    taskContext = "battle-sprite",
    battlerTarget = "attacker",
    parameters = {
      spriteContextSlot = 1,
      blendCoefficient = 4,
      scaleStart = 20,
      scaleDivisor = 5,
      scaleEnd = 30,
      repeatCount = 2,
      firstDurationTicks = -2,
      returnDurationTicks = 0xffff,
    },
  }
  Assert.isTrue(schema().assertProgram(program(instruction)))
  instruction.parameters.spriteContextSlot = 5
  Assert.isFalse(pcall(schema().assertProgram, program(instruction)))
end

function T.selected_position_transition_requires_topology_and_closed_targets()
  local instruction = {
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-selected-position-transition",
    taskKind = "pokemon-picture-selected-position-transition",
    taskContext = "pokemon-picture",
    parameters = {
      pictureTarget = "attacker-related-position-when-paired",
      positionBasis = "selected-picture-origin",
      durationTicks = 30,
    },
  }
  Assert.isTrue(schema().assertProgram(program(instruction)))
  instruction.parameters.pictureTarget = "native-selector-4"
  Assert.isFalse(pcall(schema().assertProgram, program(instruction)))
  instruction.parameters.pictureTarget = "attacker"
  instruction.parameters.durationTicks = 0x10000
  Assert.isFalse(pcall(schema().assertProgram, program(instruction)))
end

function T.alternating_background_scroll_has_typed_offsets_and_layer()
  local instruction = {
    op = "invoke-battle-animation-callback",
    callback = "battle-background-alternating-scroll-transition",
    taskKind = "battle-background-alternating-scroll-transition",
    taskContext = "battle-display",
    parameters = {
      horizontalOffset = -3,
      verticalOffset = 4,
      ticksPerDirection = 4,
      directionChanges = 5,
      phaseIntervalTicks = 8,
      backgroundLayer = "battle-background-layer-2",
    },
  }
  Assert.isTrue(schema().assertProgram(program(instruction)))
  instruction.parameters.backgroundLayer = "native-layer-2"
  Assert.isFalse(pcall(schema().assertProgram, program(instruction)))
end

function T.scanline_sine_wave_callback_has_a_closed_layer_and_duration()
  local instruction = {
    op = "invoke-battle-animation-callback",
    callback = "battle-background-scanline-sine-wave-transition",
    taskKind = "battle-background-scanline-sine-wave-transition",
    taskContext = "battle-display",
    parameters = {
      backgroundLayer = "battle-background-layer-3",
      durationTicks = 0,
    },
  }
  Assert.isTrue(schema().assertProgram(program(instruction)))
  instruction.parameters.backgroundLayer = "battle-background-layer-2"
  Assert.isFalse(pcall(schema().assertProgram, program(instruction)))
  instruction.parameters.backgroundLayer = "battle-background-layer-3"
  instruction.parameters.durationTicks = -1
  Assert.isFalse(pcall(schema().assertProgram, program(instruction)))
end

function T.background_alpha_slide_callbacks_require_the_five_selected_resources()
  local instruction = {
    op = "invoke-battle-animation-callback",
    callback = "battle-background-alpha-scroll-transition",
    taskKind = "battle-background-alpha-scroll-transition",
    taskContext = "battle-display",
    runtimeSelection = "battle-background-three-way-screen-selection",
    resourceKeys = {
      character = "battle/test/background-character",
      palette = "battle/test/background-palette",
      screenDefault = "battle/test/background-screen-default",
      screenBattlerClassFour = "battle/test/background-screen-class-four",
      screenContextFlag = "battle/test/background-screen-context-flag",
    },
    parameters = {
      backgroundLayer = "battle-background-layer-2",
      initialScrollX = 10,
      initialScrollY = -20,
      horizontalStep = 2,
      verticalStep = -3,
      pairedPositionTransformEnabled = true,
      paletteTarget = "battle-animation-palette-target",
      durationTicks = 12,
    },
  }
  Assert.isTrue(schema().assertProgram(program(instruction)))
  instruction.runtimeSelection = "battle-background-screen-selection"
  Assert.isFalse(pcall(schema().assertProgram, program(instruction)))
  instruction.runtimeSelection = "battle-background-three-way-screen-selection"
  instruction.resourceKeys.screenContextFlag = nil
  Assert.isFalse(pcall(schema().assertProgram, program(instruction)))
  instruction.resourceKeys.screenContextFlag = "battle/test/background-screen-context-flag"
  instruction.resourceKeys.sourceScreenSelector = "battle/test/raw-selector"
  Assert.isFalse(pcall(schema().assertProgram, program(instruction)))
end

function T.sprite_priority_appearance_requires_topology_and_registered_sprite_context()
  local instruction = {
    op = "invoke-battle-animation-callback",
    callback = "battle-sprite-priority-appearance-transition",
    taskKind = "battle-sprite-priority-appearance-transition",
    taskContext = "battle-display",
    parameters = {
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
    },
  }
  local effect = {
    schema = "g4-battle-effect-v1",
    key = "sprite-priority-appearance-effect",
    catalogIdentity = "synthetic-catalog",
    program = program(instruction),
    dependencies = {},
    resources = {},
    requiredContext = {},
  }
  Assert.isFalse(pcall(schema().assertEffect, effect))
  effect.requiredContext.battlerTopology = { type = "battle-animation-battler-topology" }
  effect.requiredContext.spriteContextTable = { type = "battle-animation-sprite-context-table" }
  Assert.isTrue(schema().assertEffect(effect))
  instruction.parameters.spriteContextSlot = 5
  Assert.isFalse(pcall(schema().assertEffect, effect))
end

function T.cyclic_picture_position_transition_requires_battler_topology()
  local effect = {
    schema = "g4-battle-effect-v1",
    key = "cyclic-picture-position-effect",
    catalogIdentity = "synthetic-catalog",
    program = program({
      op = "invoke-battle-animation-callback",
      callback = "pokemon-picture-cyclic-two-phase-position-transition",
      taskKind = "pokemon-picture-cyclic-two-phase-position-transition",
      taskContext = "pokemon-picture",
      parameters = {
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
      },
    }),
    dependencies = {},
    resources = {},
    requiredContext = {},
  }
  Assert.isFalse(pcall(schema().assertEffect, effect))
  effect.requiredContext.battlerTopology = { type = "battle-animation-battler-topology" }
  Assert.isTrue(schema().assertEffect(effect))
end

function T.battler_blend_alpha_callback_has_typed_sprite_and_coefficient_fields()
  local instruction = {
    op = "invoke-battle-animation-callback",
    callback = "battle-sprite-blend-alpha-transition",
    taskKind = "battle-sprite-blend-alpha-transition",
    taskContext = "battle-display",
    parameters = {
      oamModeSpriteSlots = { "sprite-context-slot-0", "sprite-context-slot-2" },
      startCoefficientA = 2,
      targetCoefficientA = 10,
      startCoefficientB = 4,
      targetCoefficientB = 12,
      durationTicks = 6,
    },
  }
  Assert.isTrue(schema().assertProgram(program(instruction)))
  instruction.parameters.oamModeSpriteSlots[2] = "source-mask-bit-2"
  Assert.isFalse(pcall(schema().assertProgram, program(instruction)))

  instruction.parameters.oamModeSpriteSlots = { "sprite-context-slot-0" }
  local effect = {
    schema = "g4-battle-effect-v1",
    key = "blend-alpha-effect",
    catalogIdentity = "synthetic-catalog",
    program = program(instruction),
    dependencies = {},
    resources = {},
    requiredContext = {},
  }
  Assert.isFalse(pcall(schema().assertEffect, effect), "selected managed sprites require their semantic context table")
  effect.requiredContext.spriteContextTable = { type = "battle-animation-sprite-context-table" }
  Assert.isTrue(schema().assertEffect(effect))
end

function T.selected_picture_pair_callback_requires_a_closed_topology_context()
  local instruction = {
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-selected-pair-transition",
    taskKind = "pokemon-picture-selected-pair-transition",
    taskContext = "pokemon-picture",
    parameters = { pictureSets = { "active-battler", "opposing-battler" } },
  }
  Assert.isTrue(schema().assertProgram(program(instruction)))
  instruction.parameters.pictureSets[2] = "native-mask-bit-4"
  Assert.isFalse(pcall(schema().assertProgram, program(instruction)))
  instruction.parameters.pictureSets = { "active-battler" }
  local effect = {
    schema = "g4-battle-effect-v1",
    key = "selected-picture-pair-effect",
    catalogIdentity = "synthetic-catalog",
    program = program(instruction),
    dependencies = {},
    resources = {},
    requiredContext = {},
  }
  Assert.isFalse(pcall(schema().assertEffect, effect), "pair selection requires battler topology")
  effect.requiredContext.battlerTopology = { type = "battle-animation-battler-topology" }
  Assert.isTrue(schema().assertEffect(effect))
end

function T.picture_affine_blend_callback_requires_registered_sprite_context()
  local effect = {
    schema = "g4-battle-effect-v1",
    key = "picture-affine-blend-effect",
    catalogIdentity = "synthetic-catalog",
    program = program({
      op = "invoke-battle-animation-callback",
      callback = "pokemon-picture-affine-blend-palette-transition",
      taskKind = "pokemon-picture-affine-blend-palette-transition",
      taskContext = "battle-display",
      parameters = {},
    }),
    dependencies = {},
    resources = {},
    requiredContext = {},
  }
  Assert.isFalse(pcall(schema().assertEffect, effect))
  effect.requiredContext.spriteContextTable = { type = "battle-animation-sprite-context-table" }
  Assert.isTrue(schema().assertEffect(effect))
end

function T.picture_vanish_affine_callback_has_a_closed_task_contract()
  Assert.isTrue(schema().assertProgram(program({
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-vanish-affine-transition",
    taskKind = "pokemon-picture-vanish-affine-transition",
    taskContext = "pokemon-picture",
    parameters = {},
  })))
end

function T.repeated_picture_vanish_callback_has_typed_toggle_parameters()
  local instruction = {
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-repeated-vanish-transition",
    taskKind = "pokemon-picture-repeated-vanish-transition",
    taskContext = "pokemon-picture",
    parameters = { toggleCount = 6, intervalTicks = 12 },
  }
  Assert.isTrue(schema().assertProgram(program(instruction)))
  instruction.parameters.toggleCount = 0x100000000
  Assert.isFalse(pcall(schema().assertProgram, program(instruction)), "toggle count is a source word")
end

function T.battle_sprite_mosaic_callback_limits_its_context_slot()
  local instruction = {
    op = "invoke-battle-animation-callback",
    callback = "battle-sprite-mosaic-transition",
    taskKind = "battle-sprite-mosaic-transition",
    taskContext = "battle-sprite",
    parameters = {
      spriteContextSlot = 4,
      step = -2,
      initialHorizontal = 4,
      initialVertical = 12,
    },
  }
  Assert.isTrue(schema().assertProgram(program(instruction)))
  instruction.parameters.spriteContextSlot = 5
  Assert.isFalse(pcall(schema().assertProgram, program(instruction)), "source helper accepts slots zero through four")
end

function T.picture_height_position_callback_has_a_closed_task_contract()
  Assert.isTrue(schema().assertProgram(program({
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-height-position-transition",
    taskKind = "pokemon-picture-height-position-transition",
    taskContext = "pokemon-picture",
    parameters = {},
  })))
end

function T.sprite_affine_appearance_callback_has_a_closed_task_contract()
  Assert.isTrue(schema().assertProgram(program({
    op = "invoke-battle-animation-callback",
    callback = "battle-sprite-affine-appearance-transition",
    taskKind = "battle-sprite-affine-appearance-transition",
    taskContext = "battle-sprite",
    parameters = {},
  })))
end

function T.three_sprite_position_wave_callback_has_a_closed_task_contract()
  Assert.isTrue(schema().assertProgram(program({
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-three-sprite-position-wave-transition",
    taskKind = "pokemon-picture-three-sprite-position-wave-transition",
    taskContext = "pokemon-picture",
    parameters = {},
  })))
end

function T.reciprocal_position_palette_callback_has_a_closed_task_contract()
  Assert.isTrue(schema().assertProgram(program({
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-reciprocal-position-palette-transition",
    taskKind = "pokemon-picture-reciprocal-position-palette-transition",
    taskContext = "pokemon-picture",
    parameters = {},
  })))
end

function T.battle_palette_callback_schema_names_pokemon_picture_fades()
  Assert.isTrue(schema().assertProgram(program({
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-and-battle-palette-fade-cycle",
    taskKind = "pokemon-picture-and-battle-palette-fade-cycle",
    taskContext = "battle-palette",
    parameters = {},
  })))
end

function T.particle_emitter_curved_path_callback_has_a_typed_context_and_curve_contract()
  local instruction = {
    op = "invoke-battle-animation-callback",
    callback = "battle-particle-emitter-curved-battler-path",
    taskKind = "battle-particle-emitter-curved-battler-path",
    taskContext = "battle-particle-emitter",
    parameters = {
      emitterContextSlot = 1,
      horizontalOffset = -3,
      verticalOffset = 4,
      durationTicks = 12,
      curveControl = 7,
      curveScale = 64,
      battlerOrder = "target-attacker",
      initialInterpolationSteps = 5,
      completionLimit = 2,
      sinusoidalOffset = true,
    },
  }
  Assert.isTrue(schema().assertProgram(program(instruction)))
  instruction.parameters.emitterContextSlot = 10
  local ok = pcall(schema().assertProgram, program(instruction))
  Assert.isFalse(ok, "particle emitter context slots index only the ten declared interpreter slots")
  instruction.parameters.emitterContextSlot = 1
  instruction.parameters.battlerOrder = "native-selector-1"
  ok = pcall(schema().assertProgram, program(instruction))
  Assert.isFalse(ok, "native pair-order selector values cannot enter runtime IR")
end

function T.particle_continuation_slot_covers_the_source_allocated_seventy_one_entry_table()
  local instruction = {
    op = "create-parameterized-battler-effect",
    actionProfile = "particle-emitter-target-battler-relative",
    emitterPosition = "solo-player",
    taskKind = "battler-effect-continuation",
    resource = "battle/particle-emitter/example",
    continuationSlot = 70,
  }
  Assert.isTrue(schema().assertProgram(program(instruction)), "the last allocated continuation slot is valid")
  instruction.continuationSlot = 71
  local ok = pcall(schema().assertProgram, program(instruction))
  Assert.isFalse(ok, "continuation slots cannot exceed the source allocated table")
end

function T.four_sprite_wave_callback_schema_has_a_closed_task_kind()
  Assert.isTrue(schema().assertProgram(program({
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-four-sprite-wave-transition",
    taskKind = "pokemon-picture-four-sprite-wave-transition",
    taskContext = "pokemon-picture",
    parameters = {},
  })))
end

function T.picture_rotation_callback_schema_closes_target_and_pivot_modes()
  local instruction = {
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-z-rotation-target-derived-pivot",
    taskKind = "pokemon-picture-z-rotation-transition",
    taskContext = "pokemon-picture",
    battlerTarget = "target",
    parameters = {
      startAngle = 0xFFFF,
      targetAngle = 0xF942,
      durationTicks = 2,
      reverseDirection = false,
    },
  }
  Assert.isTrue(schema().assertProgram(program(instruction)))
  instruction.callback = "pokemon-picture-z-rotation-attacker-explicit-pivot"
  instruction.battlerTarget = "attacker"
  instruction.parameters.pivotX = -4
  instruction.parameters.pivotY = 12
  Assert.isTrue(schema().assertProgram(program(instruction)))
  instruction.parameters.pivotY = 0x8000
  local ok = pcall(schema().assertProgram, program(instruction))
  Assert.isFalse(ok, "explicit pivot coordinates are signed halfwords")
end

function T.animation_callback_schema_accepts_source_traced_picture_tasks()
  for _, item in ipairs({
    {
      callback = "pokemon-picture-scale-position-transition",
      taskKind = "pokemon-picture-scale-position-transition",
    },
    {
      callback = "pokemon-picture-palette-fade",
      taskKind = "pokemon-picture-palette-fade",
    },
  }) do
    local instruction = {
      op = "invoke-battle-animation-callback",
      callback = item.callback,
      taskKind = item.taskKind,
      taskContext = "pokemon-picture",
      parameters = {},
    }
    Assert.isTrue(schema().assertProgram(program(instruction)), "source-traced picture callback has a closed task contract")
  end
end

function T.picture_palette_fade_position_schema_bounds_its_typed_parameters()
  local instruction = {
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-palette-fade-position-transition",
    taskKind = "pokemon-picture-palette-fade-position-transition",
    taskContext = "pokemon-picture",
    parameters = { approachOffset = -1, settleOffset = 120, approachTicks = 10, settleTicks = 5 },
  }
  Assert.isTrue(schema().assertProgram(program(instruction)))
  instruction.parameters.approachOffset = 0x8000
  local ok = pcall(schema().assertProgram, program(instruction))
  Assert.isFalse(ok, "picture offsets are signed source halfwords")
end

function T.background_picture_scroll_callback_schema_closes_its_mode_parameters()
  for _, instruction in ipairs({
    {
      op = "invoke-battle-animation-callback",
      callback = "battle-background-picture-scroll-oscillation",
      taskKind = "battle-background-picture-scroll-oscillation",
      taskContext = "battle-display",
      parameters = { directionState = 1, phaseIndex = 4 },
    },
    {
      op = "invoke-battle-animation-callback",
      callback = "battle-background-picture-coordinate-sweep",
      taskKind = "battle-background-picture-coordinate-sweep",
      taskContext = "battle-display",
      parameters = { startX = -2, startY = 3, deltaX = -4, deltaY = 7 },
    },
  }) do
    Assert.isTrue(schema().assertProgram(program(instruction)), "selector 27 mode has its closed semantic profile")
  end
end

function T.picture_affine_sprite_pair_callback_schema_requires_its_named_task()
  Assert.isTrue(schema().assertProgram(program({
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-managed-sprite-affine-pair-transition",
    taskKind = "pokemon-picture-managed-sprite-affine-pair-transition",
    taskContext = "pokemon-picture",
    parameters = {},
  })))
end

function T.picture_sinusoidal_callback_schema_closes_battler_and_partner_modes()
  for _, case in ipairs({
    { callback = "pokemon-picture-sinusoidal-position-attacker", target = "attacker" },
    { callback = "pokemon-picture-sinusoidal-position-attacker-pair", target = "attacker" },
    { callback = "pokemon-picture-sinusoidal-position-target", target = "target" },
    { callback = "pokemon-picture-sinusoidal-position-target-pair", target = "target" },
  }) do
    Assert.isTrue(schema().assertProgram(program({
      op = "invoke-battle-animation-callback",
      callback = case.callback,
      taskKind = "pokemon-picture-sinusoidal-position-motion",
      taskContext = "pokemon-picture",
      battlerTarget = case.target,
      parameters = { oscillationCycles = 7, durationTicks = 10 },
    })), "source mode has a named semantic contract")
  end
end

function T.picture_affine_sprite_entry_schema_has_a_closed_empty_parameter_shape()
  Assert.isTrue(schema().assertProgram(program({
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-affine-sprite-entry-transition",
    taskKind = "pokemon-picture-affine-sprite-entry-transition",
    taskContext = "pokemon-picture",
    parameters = {},
  })))
  local ok = pcall(schema().assertProgram, program({
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-affine-sprite-entry-transition",
    taskKind = "pokemon-picture-affine-sprite-entry-transition",
    taskContext = "pokemon-picture",
    parameters = { selector = 49 },
  }))
  Assert.isFalse(ok, "native selector is not an executable task parameter")
end

function T.animation_callback_schema_keeps_randomized_motion_target_typed()
    for _, target in ipairs({ "attacker", "target" }) do
    local instruction = {
      op = "invoke-battle-animation-callback",
      callback = "pokemon-picture-randomized-position-motion-" .. target,
      taskKind = "pokemon-picture-randomized-position-motion",
      taskContext = "pokemon-picture",
      battlerTarget = target,
      parameters = {},
    }
    Assert.isTrue(schema().assertProgram(program(instruction)), "battler role is source-normalized")
  end
end

function T.animation_callback_schema_closes_panel_slide_profiles_and_offsets()
  for _, callback in ipairs({
    "battle-sprite-panel-slide-down",
    "battle-sprite-panel-slide-up",
    "battle-sprite-panel-slide-far-up",
  }) do
    local instruction = {
      op = "invoke-battle-animation-callback",
      callback = callback,
      taskKind = "battle-sprite-panel-slide",
      taskContext = "sprite-system",
      parameters = {
        firstPanelOffsetX = 0,
        firstPanelOffsetY = -6,
        secondPanelOffsetX = 12,
        secondPanelOffsetY = 4,
      },
    }
    Assert.isTrue(schema().assertProgram(program(instruction)), "panel slide has a closed semantic callback profile")
    instruction.parameters.firstPanelOffsetY = 0x8000
    local ok = pcall(schema().assertProgram, program(instruction))
    Assert.isFalse(ok, "panel offsets preserve signed halfword bounds")
  end
end

function T.animation_callback_schema_accepts_double_sprite_scale_settle()
  Assert.isTrue(schema().assertProgram(program({
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-double-sprite-scale-settle",
    taskKind = "pokemon-picture-double-sprite-scale-settle",
    taskContext = "pokemon-picture",
    parameters = {},
  })), "the source callback has a named task contract")
end

function T.animation_callback_schema_accepts_battler_pair_scale_transition()
  Assert.isTrue(schema().assertProgram(program({
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-battler-pair-scale-transition",
    taskKind = "pokemon-picture-battler-pair-scale-transition",
    taskContext = "pokemon-picture",
    parameters = {},
  })), "the battler-pair picture transition has a closed task contract")
end

function T.animation_callback_schema_accepts_background_picture_slide()
  Assert.isTrue(schema().assertProgram(program({
    op = "invoke-battle-animation-callback",
    callback = "battle-background-pokepic-slide",
    taskKind = "battle-background-pokepic-slide",
    taskContext = "battle-display",
    parameters = {},
  })), "the background and picture transition has a named task contract")
end

function T.animation_callback_schema_accepts_picture_pulse_and_table_motion()
  for _, callback in ipairs({
    "pokemon-picture-palette-pulse-position-transition",
    "pokemon-picture-table-driven-position-transition",
  }) do
    Assert.isTrue(schema().assertProgram(program({
      op = "invoke-battle-animation-callback",
      callback = callback,
      taskKind = callback,
      taskContext = "pokemon-picture",
      parameters = {},
    })), "picture callback resolves to a closed task profile")
  end
end

function T.animation_callback_schema_accepts_battle_picture_palette_fade_cycle()
  Assert.isTrue(schema().assertProgram(program({
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-battle-palette-fade-cycle",
    taskKind = "pokemon-picture-battle-palette-fade-cycle",
    taskContext = "battle-palette",
    parameters = {},
  })), "the callback owns both battle palette and picture fade state")
end

function T.animation_callback_schema_accepts_sprite_affine_scale_and_blend()
  Assert.isTrue(schema().assertProgram(program({
    op = "invoke-battle-animation-callback",
    callback = "sprite-affine-scale-and-blend-transition",
    taskKind = "sprite-affine-scale-and-blend-transition",
    taskContext = "battle-sprite",
    parameters = {},
  })), "the sprite affine callback has a closed task profile")
end

function T.animation_callback_schema_accepts_repeated_picture_scale_motion()
  Assert.isTrue(schema().assertProgram(program({
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-repeated-scale-position-transition",
    taskKind = "pokemon-picture-repeated-scale-position-transition",
    taskContext = "pokemon-picture",
    parameters = {},
  })), "the picture scale and position transition has a closed task profile")
end

function T.animation_callback_schema_accepts_background_picture_wipe()
  Assert.isTrue(schema().assertProgram(program({
    op = "invoke-battle-animation-callback",
    callback = "battle-background-picture-wipe-transition",
    taskKind = "battle-background-picture-wipe-transition",
    taskContext = "battle-display",
    parameters = {},
  })), "the battle picture wipe has a closed task profile")
end

function T.animation_callback_schema_accepts_three_sprite_affine_picture_transition()
  Assert.isTrue(schema().assertProgram(program({
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-three-sprite-affine-transition",
    taskKind = "pokemon-picture-three-sprite-affine-transition",
    taskContext = "pokemon-picture",
    parameters = {},
  })), "the three-sprite affine picture action has a closed task profile")
end

function T.animation_callback_schema_accepts_background_picture_palette_scroll()
  Assert.isTrue(schema().assertProgram(program({
    op = "invoke-battle-animation-callback",
    callback = "battle-background-picture-palette-scroll",
    taskKind = "battle-background-picture-palette-scroll",
    taskContext = "battle-display",
    parameters = {},
  })), "the background picture palette scroll has a closed task profile")
end

function T.animation_callback_schema_types_the_pokepic_entry_battler()
  for _, target in ipairs({ "attacker", "target" }) do
    Assert.isTrue(schema().assertProgram(program({
      op = "invoke-battle-animation-callback",
      callback = "pokemon-picture-entry-offset-" .. target,
      taskKind = "pokemon-picture-entry-offset-transition",
      taskContext = "pokemon-picture",
      battlerTarget = target,
      parameters = {},
    })), "the source selector is normalized to an attacker or target role")
  end
end

function T.animation_callback_schema_accepts_oscillating_picture_axis_motion()
  Assert.isTrue(schema().assertProgram(program({
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-oscillating-axis-motion",
    taskKind = "pokemon-picture-oscillating-axis-motion",
    taskContext = "pokemon-picture",
    parameters = {},
  })), "the oscillating picture motion has a closed semantic task")
end

function T.animation_callback_schema_accepts_two_battler_picture_crossing_motion()
  Assert.isTrue(schema().assertProgram(program({
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-two-battler-crossing-motion",
    taskKind = "pokemon-picture-two-battler-crossing-motion",
    taskContext = "pokemon-picture",
    parameters = {},
  })), "the two-battler picture movement has a closed task profile")
end

function T.animation_callback_schema_accepts_picture_two_phase_entry_motion()
  Assert.isTrue(schema().assertProgram(program({
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-two-phase-entry-motion",
    taskKind = "pokemon-picture-two-phase-entry-motion",
    taskContext = "pokemon-picture",
    parameters = {},
  })), "the picture entry motion has a closed task profile")
end

function T.particle_effect_schema_closes_emitter_resources_and_every_position_pair()
  local resourceCases = {}
  local positions = {
    "solo-player",
    "solo-enemy",
    "player-side-slot-1",
    "enemy-side-slot-1",
    "player-side-slot-2",
    "enemy-side-slot-2",
  }
  for _, attacker in ipairs(positions) do
    for _, target in ipairs(positions) do
      resourceCases[attacker .. "/" .. target] = "battle/particle-emitter/test"
    end
  end
  Assert.isTrue(schema().assertProgram(program({
    op = "create-parameterized-battler-effect",
    taskKind = "battler-effect-continuation",
    actionProfile = "particle-emitter-default",
    emitterPosition = "solo-player",
    resource = "battle/particle-emitter/test",
  })), "direct particle callbacks use a staged emitter resource")
  Assert.isTrue(schema().assertProgram(program({
    op = "create-parameterized-battler-effect",
    taskKind = "battler-effect-continuation",
    actionProfile = "particle-emitter-target-battler-relative",
    emitterPosition = "solo-player",
    resourceCases = resourceCases,
    runtimeSelection = "battler-particle-position-pair",
  })), "dynamic dispatch preserves each semantic emitter resource pair")
  resourceCases["solo-player/solo-enemy"] = "source-assert"
  Assert.isTrue(schema().assertProgram(program({
    op = "create-parameterized-battler-effect",
    taskKind = "battler-effect-continuation",
    actionProfile = "particle-emitter-target-battler-relative",
    emitterPosition = "solo-player",
    resourceCases = resourceCases,
    runtimeSelection = "battler-particle-position-pair",
  })), "source assertion cells remain explicit and closed")
  resourceCases["solo-player/solo-enemy"] = "native-selector-4"
  local ok = pcall(schema().assertProgram, program({
    op = "create-parameterized-battler-effect",
    taskKind = "battler-effect-continuation",
    actionProfile = "particle-emitter-target-battler-relative",
    emitterPosition = "solo-player",
    resourceCases = resourceCases,
    runtimeSelection = "battler-particle-position-pair",
  }))
  Assert.isFalse(ok, "native resource selectors cannot enter runtime resource cases")
end

function T.managed_sprite_requires_four_base_resources_and_allows_optional_multi_resources()
  local instruction = {
    op = "create-managed-sprite",
    values = { 0, 2 },
    resourceKeys = {
      character = "battle/sprite/example/character",
      palette = "battle/sprite/example/palette",
      cell = "battle/sprite/example/cell",
      animation = "battle/sprite/example/animation",
      multiCell = "battle/sprite/example/multi-cell",
      multiAnimation = "battle/sprite/example/multi-animation",
    },
  }
  Assert.isTrue(schema().assertProgram(program(instruction)))
  instruction.resourceKeys.multiAnimation = nil
  instruction.resourceKeys.multiCell = nil
  Assert.isTrue(schema().assertProgram(program(instruction)), "optional multi-resource roles may both be absent")
  instruction.resourceKeys.animation = nil
  local ok = pcall(schema().assertProgram, program(instruction))
  Assert.isFalse(ok, "the four base sprite resource roles remain required")
  instruction.resourceKeys.animation = "battle/sprite/example/animation"
  instruction.resourceKeys.multiAnimation = "battle/sprite/example/multi-animation"
  instruction.resourceKeys.unknown = "battle/sprite/example/unknown"
  ok = pcall(schema().assertProgram, program(instruction))
  Assert.isFalse(ok, "unknown sprite resource roles are rejected")
end

function T.configured_sprite_allows_source_disabled_multicell_roles()
  local instruction = {
    op = "create-configured-sprite",
    parameters = {},
    taskKind = "pokemon-picture-palette-fade",
    taskContext = "pokemon-picture",
    resourceKeys = {
      character = "battle/sprite/example/character",
      palette = "battle/sprite/example/palette",
      cell = "battle/sprite/example/cell",
      animation = "battle/sprite/example/animation",
      multiCell = "battle/sprite/example/multi-cell",
      multiAnimation = "battle/sprite/example/multi-animation",
    },
  }
  Assert.isTrue(schema().assertProgram(program(instruction)), "configured sprite tasks have typed resources/context")
  instruction.resourceKeys.multiCell = nil
  instruction.resourceKeys.multiAnimation = nil
  Assert.isTrue(schema().assertProgram(program(instruction)), "source-disabled MCEL/MANM roles may be omitted")
  instruction.resourceKeys.animation = nil
  local ok = pcall(schema().assertProgram, program(instruction))
  Assert.isFalse(ok, "the four active sprite resource roles remain required")
  instruction.resourceKeys.animation = "battle/sprite/example/animation"
  instruction.taskKind = "sprite-callback-8"
  ok = pcall(schema().assertProgram, program(instruction))
  Assert.isFalse(ok, "opaque callback profile names are rejected")
  instruction.taskKind = "pokemon-picture-palette-fade"
  instruction.taskContext = "native-callback-context"
  ok = pcall(schema().assertProgram, program(instruction))
  Assert.isFalse(ok, "runtime task context comes from the closed semantic inventory")
end

function T.configured_sprite_parameters_are_named_and_task_specific()
  local instruction = {
    op = "create-configured-sprite",
    parameters = { offsetX = -12, offsetY = 8 },
    taskKind = "sprite-position-offset",
    taskContext = "battle-sprite",
    resourceKeys = {
      character = "battle/sprite/example/character",
      palette = "battle/sprite/example/palette",
      cell = "battle/sprite/example/cell",
      animation = "battle/sprite/example/animation",
      multiCell = "battle/sprite/example/multi-cell",
      multiAnimation = "battle/sprite/example/multi-animation",
    },
  }
  Assert.isTrue(schema().assertProgram(program(instruction)), "position offsets have named signed fields")
  instruction.parameters.offsetX = 0x8000
  local ok = pcall(schema().assertProgram, program(instruction))
  Assert.isFalse(ok, "signed 16-bit source offsets cannot exceed their source range")
  instruction.parameters = { spriteCount = 3 }
  ok = pcall(schema().assertProgram, program(instruction))
  Assert.isFalse(ok, "task parameters from a different callback are rejected")
end

function T.program_schema_rejects_wrong_fixed_operand_counts()
  local ok = pcall(schema().assertProgram, program({ op = "dispose-sprite-manager", values = { 0, 1 } }))
  Assert.isFalse(ok, "fixed-width operations reject extra operands")
end

function T.program_schema_accepts_semantic_background_resources_and_closed_selection()
  Assert.isTrue(schema().assertProgram(program({
    op = "load-battle-background",
    resourceKeys = {
      character = "battle/background/test/character",
      palette = "battle/background/test/palette",
      screenDefault = "battle/background/test/screen-default",
      screenAlternate = "battle/background/test/screen-alternate",
    },
    runtimeSelection = "battle-background-screen-selection",
  })))
  local ok = pcall(
    schema().assertProgram,
    program({
      op = "load-battle-background",
      resourceKeys = {
        character = "battle/background/test/character",
        palette = "battle/background/test/palette",
        screenDefault = "battle/background/test/screen-default",
        screenAlternate = "battle/background/test/screen-alternate",
      },
      runtimeSelection = "native-selector-2",
    })
  )
  Assert.isFalse(ok, "unresolved selector numbers cannot become runtime enum values")
end

function T.effect_resources_require_semantic_payload_identity()
  local effect = {
    schema = "g4-battle-effect-v1",
    key = "synthetic-effect",
    catalogIdentity = "synthetic-catalog",
    program = program({ op = "set-parameter", values = { 0, 1 } }),
    dependencies = { "battle/sound/test", "battle/background/test/map", "battle/particle/test" },
    resources = {
      ["battle/sound/test"] = {
        kind = "sound",
        payload = "battle/sound/test.sseq",
        contentIdentity = string.rep("a", 40),
      },
      ["battle/background/test/map"] = {
        kind = "map",
        payload = "battle/background/test/map.bin",
        contentIdentity = string.rep("b", 40),
      },
      ["battle/particle/test"] = {
        kind = "particle",
        payload = "battle/particle/test.lua",
        contentIdentity = string.rep("c", 40),
      },
    },
    requiredContext = {},
  }
  Assert.isTrue(schema().assertEffect(effect), "typed payload with a SHA-1 content identity validates")
  effect.resources["battle/sound/test"].contentIdentity = nil
  local ok = pcall(schema().assertEffect, effect)
  Assert.isFalse(ok, "resource descriptors without a content identity are rejected")
  effect.resources["battle/sound/test"].contentIdentity = "short"
  ok = pcall(schema().assertEffect, effect)
  Assert.isFalse(ok, "resource content identities must be SHA-1 shaped")
end

function T.effect_context_is_a_closed_typed_layout_and_resources_cover_instruction_keys()
  local resourceKey = "audio/sequence/SEQ_SE_DP_050"
  local effect = {
    schema = "g4-battle-effect-v1",
    key = "typed-context-effect",
    catalogIdentity = "synthetic-catalog",
    program = program({ op = "play-sound", sound = resourceKey }),
    dependencies = { resourceKey },
    resources = {
      [resourceKey] = {
        kind = "sound",
        payload = "data/generated/battle/resources/audio/sequence/SEQ_SE_DP_050.lua",
        contentIdentity = string.rep("c", 40),
      },
    },
    requiredContext = { attackerPosition = { type = "battler-position" } },
  }
  Assert.isTrue(schema().assertEffect(effect))
  effect.requiredContext.attackerPosition.type = "native-battler-type"
  local ok = pcall(schema().assertEffect, effect)
  Assert.isFalse(ok, "context fields use a closed semantic type vocabulary")
  effect.requiredContext.attackerPosition.type = "battler-position"
  effect.resources[resourceKey] = nil
  effect.dependencies = {}
  ok = pcall(schema().assertEffect, effect)
  Assert.isFalse(ok, "every instruction resource key is part of the declared resource closure")
end

function T.position_pair_particle_resources_are_closed_over_staged_emitters()
  local resourceKey = "battle/particle-emitter/content-addressed"
  local resourceCases = {}
  local positions = {
    "solo-player",
    "solo-enemy",
    "player-side-slot-1",
    "enemy-side-slot-1",
    "player-side-slot-2",
    "enemy-side-slot-2",
  }
  for _, attacker in ipairs(positions) do
    for _, target in ipairs(positions) do
      resourceCases[attacker .. "/" .. target] = "source-assert"
    end
  end
  resourceCases["solo-player/solo-enemy"] = resourceKey
  local effect = {
    schema = "g4-battle-effect-v1",
    key = "particle-emitter-closure",
    catalogIdentity = "synthetic-catalog",
    program = program({
      op = "create-parameterized-battler-effect",
      taskKind = "battler-effect-continuation",
      actionProfile = "particle-emitter-target-battler-relative",
      emitterPosition = "solo-player",
      resourceCases = resourceCases,
      runtimeSelection = "battler-particle-position-pair",
    }),
    dependencies = { resourceKey },
    resources = {
      [resourceKey] = {
        kind = "particle-emitter",
        payload = "data/generated/battle/resources/particle-emitter.lua",
        contentIdentity = string.rep("d", 40),
      },
    },
    requiredContext = {},
  }
  Assert.isTrue(schema().assertEffect(effect), "semantic emitter cases resolve to staged resources")
  effect.resources[resourceKey].kind = "particle"
  local wrongKind = pcall(schema().assertEffect, effect)
  Assert.isFalse(wrongKind, "emitter selections require normalized particle-emitter resources")
  effect.resources[resourceKey].kind = "particle-emitter"
  effect.resources[resourceKey] = nil
  effect.dependencies = {}
  local ok = pcall(schema().assertEffect, effect)
  Assert.isFalse(ok, "resource cases cannot reference an unstaged emitter")
end

function T.vanished_picture_operation_requires_source_battler_topology()
  local effect = {
    schema = "g4-battle-effect-v1",
    key = "vanished-picture-effect",
    catalogIdentity = "synthetic-catalog",
    program = program({
      op = "set-pokemon-picture-vanished",
      pictureSets = { "other-battler-positions" },
      vanished = false,
    }),
    dependencies = {},
    resources = {},
    requiredContext = {},
  }
  local ok = pcall(schema().assertEffect, effect)
  Assert.isFalse(ok, "the operation requires declared battler topology context")
  effect.requiredContext.battlerTopology = { type = "battle-animation-battler-topology" }
  Assert.isTrue(schema().assertEffect(effect))
  effect.requiredContext.battlerTopology.type = "native-battler-slots"
  ok = pcall(schema().assertEffect, effect)
  Assert.isFalse(ok, "source position slots cannot enter runtime context")
end

function T.position_offset_callback_declares_its_battler_topology()
  local effect = {
    schema = "g4-battle-effect-v1",
    key = "position-offset-effect",
    catalogIdentity = "synthetic-catalog",
    program = program({
      op = "invoke-battle-animation-callback",
      callback = "pokemon-picture-selected-position-offset-transition",
      taskKind = "pokemon-picture-selected-position-offset-transition",
      taskContext = "pokemon-picture",
      parameters = {
        pictureTarget = "active-battler-pair-when-enabled",
        durationTicks = 8,
        signedOffset = -2,
      },
    }),
    dependencies = {},
    resources = {},
    requiredContext = {},
  }
  local ok = pcall(schema().assertEffect, effect)
  Assert.isFalse(ok, "the callback needs declared battler topology")
  effect.requiredContext.battlerTopology = { type = "battle-animation-battler-topology" }
  Assert.isTrue(schema().assertEffect(effect))
end

function T.interpolated_picture_effect_declares_its_sprite_context_table()
  local instruction = {
    op = "invoke-battle-animation-callback",
    callback = "pokemon-picture-paired-position-interpolation-target",
    taskKind = "pokemon-picture-paired-position-interpolation",
    taskContext = "pokemon-picture",
    battlerTarget = "target",
    parameters = {
      spriteContextSlot = 0,
      reverseEndpoints = false,
      endpointX = 10,
      endpointY = 4,
      initialSteps = 0,
      stepIntervalTicks = 0,
    },
  }
  local effect = {
    schema = "g4-battle-effect-v1",
    key = "sprite-context-effect",
    catalogIdentity = "synthetic-catalog",
    program = program(instruction),
    dependencies = {},
    resources = {},
    requiredContext = {},
  }
  local ok = pcall(schema().assertEffect, effect)
  Assert.isFalse(ok, "interpolation requires the declared sprite-context table")
  effect.requiredContext.spriteContextTable = { type = "battle-animation-sprite-context-table" }
  Assert.isTrue(schema().assertEffect(effect), "the sprite-context table uses a named semantic context type")
  effect.requiredContext.spriteContextTable.type = "native-callback-arguments"
  ok = pcall(schema().assertEffect, effect)
  Assert.isFalse(ok, "source ABI arrays cannot be declared as runtime context")
end

function T.effect_resource_descriptors_accept_typed_multicell_formats()
  local effect = {
    schema = "g4-battle-effect-v1",
    key = "synthetic-multicell-effect",
    catalogIdentity = "synthetic-catalog",
    program = program({ op = "set-parameter", values = { 0, 1 } }),
    dependencies = { "battle/sprite/example/multi-cell", "battle/sprite/example/multi-animation" },
    resources = {
      ["battle/sprite/example/multi-cell"] = {
        kind = "multi-cell",
        payload = "battle/sprite/example/multi-cell.bin",
        contentIdentity = string.rep("a", 40),
      },
      ["battle/sprite/example/multi-animation"] = {
        kind = "multi-cell-animation",
        payload = "battle/sprite/example/multi-animation.bin",
        contentIdentity = string.rep("b", 40),
      },
    },
    requiredContext = {},
  }
  Assert.isTrue(schema().assertEffect(effect))
  effect.resources["battle/sprite/example/multi-cell"].kind = "sprite-template"
  local ok = pcall(schema().assertEffect, effect)
  Assert.isFalse(ok, "source roles require the exact semantic resource kind")
end

return { tests = T }
