-- Normalized battle effect and program contract: one independently
-- requested effect artifact carries a closed executable program with its
-- transitive resources and typed context. Runtime-facing records use
-- semantic keys only: native dispatch identities never validate.
-- Follows asm/overlay_07.s ov07_02234DE8
-- (pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36).
-- Love-free and filesystem-free.

local SchemaCheck = require("libs.assets.src.SchemaCheck")
local Validate = require("libs.assets.src.Validate")

---@class BattleAnimationSchema
local BattleAnimationSchema = {}

BattleAnimationSchema.EFFECT_SCHEMA = "g4-battle-effect-v3"

local CODE_EFFECT = "BATTLE_EFFECT_INVALID"

-- overlay_07 allocates 0x47 words at work+0xc0 for particle continuations.
local MAX_PARTICLE_CONTINUATION_SLOT = 0x46

local RESOURCE_KINDS = {
  map = true,
  texture = true,
  model = true,
  palette = true,
  cell = true,
  animation = true,
  particle = true,
  ["particle-emitter"] = true,
  ["multi-cell"] = true,
  ["multi-cell-animation"] = true,
  message = true,
}

local REQUIRED_CONTEXT_FIELDS = {
  actors = "battle-actors",
  targets = "target-actors",
  attackerPosition = "battler-position",
  targetPosition = "battler-position",
  spriteContextTable = "battle-animation-sprite-context-table",
  battlerTopology = "battle-animation-battler-topology",
  movePower = "battle-animation-move-power-u16",
}

local OPERATIONS = {
  ["interpreter-wait"] = { values = 1 },
  ["play-sound"] = { sound = true },
  noop = {},
  ["set-blend-alpha"] = { values = 2 },
  ["reset-blend-alpha"] = {},
  ["set-parameter"] = { values = 2 },
  ["set-background-component"] = { values = 2 },
  ["skip-words"] = { target = true },
  ["clear-background-plane"] = { values = 1 },
  ["stop-sound"] = { sound = true },
  ["replace-parameters-and-call"] = { callback = true, values = true },
  ["invoke-battle-animation-callback"] = {
    callback = true,
    taskKind = true,
    taskContext = true,
    battlerTarget = true,
    parameters = true,
    resourceKeys = true,
    runtimeSelection = true,
  },
  ["copy-main-background-palette-to-fade-buffer"] = {},
  ["grayscale-main-background-fade-buffer"] = {},
  ["set-pokemon-picture-vanished"] = { pictureSets = true, vanished = true },
  ["delete-managed-sprite"] = { values = 1 },
  ["clear-parameters"] = {},
  ["create-sprite-manager"] = { values = 8 },
  ["dispose-sprite-manager"] = { values = 1 },
  ["set-managed-sprite-draw-flag"] = { values = 2 },
  ["clear-effect-slot"] = { values = 1 },
  ["start-brightness-transition"] = { values = 1 },
  ["wait-interpreter-counter"] = { cursorRule = true, branchTarget = true },
  ["source-assertion"] = { target = true, cursorRule = true },
  ["reserve-loop-slot"] = {
    values = true,
    branchTarget = true,
    resumeTarget = true,
    cursorRule = true,
  },
  ["advance-loop-slot"] = { cursorRule = true },
  ["reset-battle-presentation"] = {},
  ["call-subprogram"] = { branchTarget = true, cursorRule = true, returnTarget = true },
  ["return-subprogram"] = { cursorRule = true },
  ["branch-on-battle-field"] = { values = true, branchTarget = true },
  ["branch-on-parameter"] = { values = true, branchTarget = true },
  ["start-visual-task"] = { taskKind = true, values = true },
  ["wait-for-battle-phase"] = { cursorRule = true, values = 1 },
  ["load-battle-background"] = { resourceKeys = true, runtimeSelection = true },
  ["play-positioned-sound"] = { sound = true, values = true },
  ["stop-positioned-sound"] = { values = true },
  ["submit-sound-action"] = { sound = true, taskKind = true, values = true },
  ["submit-battle-action"] = { values = true, taskKind = true },
  ["branch-on-interpreter-state"] = { values = true, branchTarget = true, alternateTarget = true },
  ["show-pokemon-picture"] = { values = true, taskKind = true },
  ["clear-pokemon-picture"] = { values = true },
  ["schedule-battle-task"] = { taskKind = true, taskInputRule = true, values = true },
  ["wait-for-sound"] = { cursorRule = true, values = 1 },
  ["branch-on-picture-state"] = { values = true, branchTarget = true },
  ["create-battler-effect"] = { emitterPosition = true, resource = true, taskKind = true },
  ["create-parameterized-battler-effect"] = {
    values = true,
    taskKind = true,
    actionProfile = true,
    resource = true,
    resourceCases = true,
    runtimeSelection = true,
    emitterPosition = true,
    continuationSlot = true,
  },
  ["wait-for-battler-effects"] = { cursorRule = true },
  ["start-battler-effect"] = { values = true, taskKind = true },
  ["destroy-battler-effect"] = { values = true },
  ["create-managed-sprite-manager"] = {},
  ["load-managed-sprite-resources"] = { resourceKeys = true, runtimeSelection = true },
  ["create-pokemon-sprite"] = {
    values = 1,
    taskKind = true,
    taskStartRule = true,
    runtimeSelection = true,
    battlerTarget = true,
  },
  ["dispose-shared-sprite-manager"] = {},
  ["destroy-effect-slot"] = { values = true },
  ["set-battler-state-byte"] = { values = 2 },
  ["set-battler-effect-byte"] = { values = 2 },
  ["play-cry"] = { values = true },
  ["wait-for-cry"] = { values = true, cursorRule = true, branchTarget = true, alternateTarget = true },
  ["submit-presentation-layout"] = { values = true },
  ["submit-presentation-update"] = { values = true },
  ["branch-on-side-mask"] = { branchCases = true },
  ["branch-on-side-predicate"] = { values = true, branchTarget = true, alternateTarget = true },
  ["branch-on-side-equality"] = { values = true, branchTarget = true, alternateTarget = true },
  ["load-sprite-character"] = { values = 1, resourceKeys = true },
  ["load-sprite-palette"] = { values = 2, resourceKeys = true },
  ["load-sprite-cell"] = { values = 1, resourceKeys = true },
  ["load-sprite-animation"] = { values = 1, resourceKeys = true },
  ["create-configured-sprite"] = {
    parameters = true,
    taskKind = true,
    taskContext = true,
    resourceKeys = true,
  },
  ["create-managed-sprite"] = { values = 2, resourceKeys = true },
  ["set-sprite-draw-flag"] = { values = true },
  ["start-sprite-effect"] = { values = 2, taskKind = true, taskStartRule = true, mode = true },
  ["clear-sprite-slot"] = { values = true },
  ["wait-for-confirm-input"] = { cursorRule = true, values = 1 },
  ["update-battle-visual"] = { taskKind = true, updateKind = true, values = 3 },
  ["branch-on-battle-flag"] = { values = true, branchTarget = true, alternateTarget = true },
}

local TASK_KINDS = {
  ["positioned-sound-motion"] = true,
  ["repeated-sound-playback"] = true,
  ["delayed-sound-playback"] = true,
  ["pokemon-picture-animation"] = true,
  ["battle-background-blend-transition"] = true,
  ["battle-palette-fade"] = true,
  ["battle-presentation-state-reset"] = true,
  ["battle-background-position-transition"] = true,
  ["pokemon-picture-position-offset-transition"] = true,
  ["pokemon-picture-scale-position-transition"] = true,
  ["pokemon-picture-two-phase-scale-transition"] = true,
  ["pokemon-picture-five-phase-affine-size-transition"] = true,
  ["pokemon-picture-selected-horizontal-offset-transition"] = true,
  ["pokemon-picture-vertical-offset-visibility-transition"] = true,
  ["pokemon-picture-managed-sprite-scale-pulse"] = true,
  ["pokemon-picture-selected-position-transition"] = true,
  ["battle-background-alternating-scroll-transition"] = true,
  ["battle-background-scanline-sine-wave-transition"] = true,
  ["battle-background-alpha-scroll-transition"] = true,
  ["battle-background-sprite-slide-transition"] = true,
  ["battle-sprite-sinusoidal-position-animation"] = true,
  ["battle-sprite-priority-appearance-transition"] = true,
  ["pokemon-picture-cyclic-two-phase-position-transition"] = true,
  ["pokemon-picture-defender-knockback"] = true,
  ["pokemon-picture-palette-fade-position-transition"] = true,
  ["pokemon-picture-sinusoidal-position-motion"] = true,
  ["pokemon-picture-affine-sprite-entry-transition"] = true,
  ["pokemon-picture-height-position-transition"] = true,
  ["pokemon-picture-linear-offscreen-transition"] = true,
  ["pokemon-picture-vanish-affine-transition"] = true,
  ["pokemon-picture-repeated-vanish-transition"] = true,
  ["pokemon-picture-reset-position-transition"] = true,
  ["pokemon-picture-target-priority-transition"] = true,
  ["pokemon-picture-selected-position-offset-transition"] = true,
  ["pokemon-picture-target-background-slide"] = true,
  ["battle-sprite-blend-alpha-transition"] = true,
  ["pokemon-picture-selected-pair-transition"] = true,
  ["pokemon-picture-affine-blend-palette-transition"] = true,
  ["battle-background-four-picture-move-power-transition"] = true,
  ["battle-display-window-palette-transition"] = true,
  ["battle-sprite-mosaic-transition"] = true,
  ["battle-background-resource-load"] = true,
  ["battle-presentation-resource-cleanup"] = true,
  ["battler-effect-continuation"] = true,
  ["managed-sprite-draw-loop"] = true,
  ["battle-particle-emitter-battler-path"] = true,
  ["battle-particle-emitter-curved-battler-path"] = true,
  ["multi-sprite-position-tick"] = true,
  ["sprite-affine-scale-draw-transition"] = true,
  ["sprite-animation-position-transition"] = true,
  ["pokemon-picture-multi-sprite-animation"] = true,
  ["sprite-affine-rotation-motion"] = true,
  ["pokemon-picture-sprite-position-transition"] = true,
  ["pokemon-picture-affine-transition"] = true,
  ["sprite-alpha-transition"] = true,
  ["pokemon-picture-palette-fade"] = true,
  ["pokemon-picture-animation-palette-fade"] = true,
  ["pokemon-picture-relative-sprite-path-transition"] = true,
  ["sprite-brightness-transition"] = true,
  ["pokemon-picture-animation-speed-transition"] = true,
  ["pokemon-picture-attacker-dash-afterimages"] = true,
  ["sprite-affine-animation"] = true,
  ["pokemon-picture-oam-animation-transition"] = true,
  ["pokemon-picture-animation-position-transition"] = true,
  ["sprite-affine-rotation-transition"] = true,
  ["sprite-animation-completion"] = true,
  ["sprite-animation-affine-scale-transition"] = true,
  ["battle-sprite-affine-appearance-transition"] = true,
  ["pokemon-picture-three-sprite-position-wave-transition"] = true,
  ["pokemon-picture-reciprocal-position-palette-transition"] = true,
  ["sprite-flip-animation-transition"] = true,
  ["sprite-randomized-affine-motion"] = true,
  ["sprite-flip-and-offset-transition"] = true,
  ["pokemon-picture-randomized-position-motion"] = true,
  ["pokemon-picture-entry-offset-transition"] = true,
  ["pokemon-picture-oscillating-axis-motion"] = true,
  ["pokemon-picture-two-battler-crossing-motion"] = true,
  ["pokemon-picture-two-phase-entry-motion"] = true,
  ["pokemon-picture-paired-position-interpolation"] = true,
  ["battle-sprite-panel-slide"] = true,
  ["pokemon-picture-double-sprite-scale-settle"] = true,
  ["pokemon-picture-battler-pair-scale-transition"] = true,
  ["battle-background-pokepic-slide"] = true,
  ["pokemon-picture-palette-pulse-position-transition"] = true,
  ["pokemon-picture-table-driven-position-transition"] = true,
  ["pokemon-picture-position-path-transition"] = true,
  ["pokemon-picture-repeated-palette-fade"] = true,
  ["pokemon-picture-battle-palette-fade-cycle"] = true,
  ["pokemon-picture-and-battle-palette-fade-cycle"] = true,
  ["pokemon-picture-and-battle-palette-fade"] = true,
  ["pokemon-picture-four-sprite-wave-transition"] = true,
  ["pokemon-picture-z-rotation-transition"] = true,
  ["sprite-affine-scale-and-blend-transition"] = true,
  ["pokemon-picture-repeated-scale-position-transition"] = true,
  ["battle-background-picture-wipe-transition"] = true,
  ["battle-background-picture-scroll-oscillation"] = true,
  ["battle-background-picture-coordinate-sweep"] = true,
  ["pokemon-picture-managed-sprite-affine-pair-transition"] = true,
  ["pokemon-picture-vanish-and-restore-transition"] = true,
  ["pokemon-picture-three-sprite-affine-transition"] = true,
  ["battle-background-picture-palette-scroll"] = true,
  ["pokemon-picture-priority-motion"] = true,
  ["sprite-position-offset"] = true,
  ["sprite-affine-transform-motion"] = true,
  ["sprite-animation-lifecycle"] = true,
  ["sprite-affine-animation-lifecycle"] = true,
  ["multi-sprite-battler-animation"] = true,
  ["multi-sprite-position-transition"] = true,
  ["sprite-animation-palette-offset"] = true,
  ["multi-sprite-picture-animation"] = true,
}

local TASK_CONTEXTS = {
  ["battle-sprite"] = true,
  ["sprite-system"] = true,
  ["pokemon-picture"] = true,
  ["battle-palette"] = true,
  ["battle-display"] = true,
  ["battle-particle-emitter"] = true,
}

local PICTURE_SETS = {
  ["all-battler-positions"] = true,
  ["other-battler-positions"] = true,
  ["active-battler"] = true,
  ["active-battler-pair-when-enabled"] = true,
  ["opposing-battler"] = true,
  ["opposing-battler-pair-when-enabled"] = true,
}

local CONFIGURED_SPRITE_TASK_CONTEXTS = {
  ["multi-sprite-position-tick"] = "sprite-system",
  ["sprite-affine-scale-draw-transition"] = "battle-sprite",
  ["sprite-animation-position-transition"] = "battle-sprite",
  ["pokemon-picture-multi-sprite-animation"] = "pokemon-picture",
  ["sprite-affine-rotation-motion"] = "battle-sprite",
  ["pokemon-picture-sprite-position-transition"] = "pokemon-picture",
  ["pokemon-picture-affine-transition"] = "pokemon-picture",
  ["sprite-alpha-transition"] = "pokemon-picture",
  ["pokemon-picture-palette-fade"] = "pokemon-picture",
  ["pokemon-picture-animation-palette-fade"] = "pokemon-picture",
  ["pokemon-picture-relative-sprite-path-transition"] = "pokemon-picture",
  ["sprite-brightness-transition"] = "battle-display",
  ["pokemon-picture-animation"] = "pokemon-picture",
  ["pokemon-picture-animation-speed-transition"] = "pokemon-picture",
  ["sprite-affine-animation"] = "pokemon-picture",
  ["pokemon-picture-oam-animation-transition"] = "pokemon-picture",
  ["pokemon-picture-animation-position-transition"] = "pokemon-picture",
  ["sprite-affine-rotation-transition"] = "battle-sprite",
  ["sprite-animation-completion"] = "battle-sprite",
  ["sprite-animation-affine-scale-transition"] = "battle-sprite",
  ["sprite-flip-animation-transition"] = "battle-sprite",
  ["sprite-randomized-affine-motion"] = "battle-sprite",
  ["sprite-flip-and-offset-transition"] = "battle-sprite",
  ["pokemon-picture-randomized-position-motion"] = "pokemon-picture",
  ["pokemon-picture-priority-motion"] = "pokemon-picture",
  ["sprite-position-offset"] = "battle-sprite",
  ["sprite-affine-transform-motion"] = "battle-sprite",
  ["sprite-animation-lifecycle"] = "battle-sprite",
  ["sprite-affine-animation-lifecycle"] = "battle-sprite",
  ["multi-sprite-battler-animation"] = "pokemon-picture",
  ["multi-sprite-position-transition"] = "battle-sprite",
  ["sprite-animation-palette-offset"] = "battle-palette",
  ["multi-sprite-picture-animation"] = "pokemon-picture",
}

local CONFIGURED_SPRITE_TASK_PARAMETERS = {
  ["sprite-affine-scale-draw-transition"] = {
    spriteCount = { min = -0x80000000, max = 0x7FFFFFFF },
  },
  ["pokemon-picture-multi-sprite-animation"] = {
    spriteCount = { min = -0x80000000, max = 0x7FFFFFFF },
  },
  ["sprite-affine-rotation-transition"] = {
    spriteSpacingX = { min = -0x8000, max = 0x7FFF },
    spriteSpacingY = { min = -0x8000, max = 0x7FFF },
    positionTransitionTicks = { min = 0, max = 0xFFFF },
    rotationAngle = { min = 0, max = 0xFFFFFFFF },
  },
  ["sprite-animation-affine-scale-transition"] = {
    spriteCount = { min = 0, max = 0xFF },
  },
  ["sprite-flip-animation-transition"] = {
    spriteCount = { min = 0, max = 0xFF },
  },
  ["sprite-position-offset"] = {
    offsetX = { min = -0x8000, max = 0x7FFF },
    offsetY = { min = -0x8000, max = 0x7FFF },
  },
}

local TASK_START_RULES = {
  ["battle-helper-equals-one"] = true,
  ["picture-active-and-animation-attribute"] = true,
}

local VISUAL_UPDATE_KINDS = {
  ["no-axis-change"] = true,
  ["increase-x"] = true,
  ["decrease-x"] = true,
  ["increase-y"] = true,
  ["decrease-y"] = true,
  ["increase-x-and-y"] = true,
  ["decrease-x-and-y"] = true,
}

local RUNTIME_SELECTIONS = {
  ["battle-background-screen-selection"] = true,
  ["battle-background-three-way-screen-selection"] = true,
  ["battler-resource-selection"] = true,
  ["battler-pokemon-picture-resource"] = true,
  ["battler-particle-position-pair"] = true,
}

local PARTICLE_ACTION_PROFILES = {
  ["particle-emitter-default"] = true,
  ["particle-emitter-camera-relative"] = true,
  ["particle-emitter-world-position"] = true,
  ["particle-emitter-active-battler-relative"] = true,
  ["particle-emitter-target-battler-relative"] = true,
  ["particle-emitter-position-pair-primary-primary"] = true,
  ["particle-emitter-position-pair-primary-secondary"] = true,
  ["particle-emitter-position-pair-primary-partner"] = true,
  ["particle-emitter-position-pair-primary-opponent"] = true,
  ["particle-emitter-position-pair-primary-opposing-partner"] = true,
  ["particle-emitter-position-pair-primary-active"] = true,
  ["particle-emitter-position-pair-secondary-primary"] = true,
  ["particle-emitter-position-pair-secondary-secondary"] = true,
  ["particle-emitter-position-pair-secondary-partner"] = true,
  ["particle-emitter-position-pair-secondary-opponent"] = true,
  ["particle-emitter-position-pair-secondary-opposing-partner"] = true,
  ["particle-emitter-position-pair-secondary-active"] = true,
  ["particle-emitter-battler-class-camera-position"] = true,
  ["particle-emitter-randomized-position"] = true,
  ["particle-emitter-battler-pair-position"] = true,
  ["particle-emitter-battler-pair-orientation"] = true,
  ["particle-emitter-active-pair-position"] = true,
}

local BATTLER_POSITION_KEYS = {
  "solo-player",
  "solo-enemy",
  "player-side-slot-1",
  "enemy-side-slot-1",
  "player-side-slot-2",
  "enemy-side-slot-2",
}

local BATTLER_POSITION_SET = {}
for _, position in ipairs(BATTLER_POSITION_KEYS) do
  BATTLER_POSITION_SET[position] = true
end

local BATTLER_TARGETS = {
  ["active-battler"] = true,
  attacker = true,
  target = true,
  ["active-position-first"] = true,
  ["active-position-second"] = true,
  ["first-battler-for-active-position-first"] = true,
  ["first-battler-for-active-position-second"] = true,
  ["first-battler-state-zero-or-two"] = true,
  ["first-battler-state-one-or-three"] = true,
  ["first-battler-state-four"] = true,
  ["first-battler-state-five"] = true,
}

local MOVE_POWER_PROFILE_MAP = {
  { movePower = 30, profile = 1 },
  { movePower = 50, profile = 2 },
  { movePower = 70, profile = 3 },
  { movePower = 90, profile = 4 },
  { movePower = 110, profile = 5 },
  { movePower = 150, profile = 6 },
}

local ANIMATION_CALLBACKS = {
  ["battle-display-window-palette-transition"] = {
    taskKind = "battle-display-window-palette-transition",
    taskContext = "battle-display",
    parameters = {},
  },
  ["pokemon-picture-vertical-offset-visibility-transition"] = {
    taskKind = "pokemon-picture-vertical-offset-visibility-transition",
    taskContext = "pokemon-picture",
    requiresBattlerTopology = true,
    parameters = {
      pictureTarget = { type = "enum", values = PICTURE_SETS },
      offsetStep = { min = -0x8000, max = 0x7FFF },
      ticksPerStep = { min = 0, max = 0xFFFFFFFF },
      applyVisibilityOffset = { type = "boolean" },
    },
  },
  ["pokemon-picture-selected-horizontal-offset-transition"] = {
    taskKind = "pokemon-picture-selected-horizontal-offset-transition",
    taskContext = "pokemon-picture",
    requiresBattlerTopology = true,
    parameters = {
      pictureTarget = { type = "enum", values = PICTURE_SETS },
      durationTicks = { min = 0, max = 0xFFFF },
      signedOffset = { min = -0x8000, max = 0x7FFF },
    },
  },
  ["pokemon-picture-five-phase-affine-size-transition"] = {
    taskKind = "pokemon-picture-five-phase-affine-size-transition",
    taskContext = "pokemon-picture",
    battlerTarget = "attacker",
    parameters = {},
  },
  ["battle-sprite-sinusoidal-position-animation"] = {
    taskKind = "battle-sprite-sinusoidal-position-animation",
    taskContext = "battle-sprite",
    requiresBattlerTopology = true,
    requiresSpriteContextTable = true,
    parameters = {
      spriteContextSlot = { min = 0, max = 70 },
      callbackContextSlot = { min = 0, max = 70 },
      positionSource = {
        type = "enum",
        values = {
          ["first-active-position"] = true,
          ["second-active-position"] = true,
        },
      },
      horizontalStartAngleDegrees = { min = -0x80000000, max = 0x7FFFFFFF },
      horizontalEndAngleDegrees = { min = -0x80000000, max = 0x7FFFFFFF },
      verticalStartAngleDegrees = { min = -0x80000000, max = 0x7FFFFFFF },
      verticalEndAngleDegrees = { min = -0x80000000, max = 0x7FFFFFFF },
      horizontalAmplitude = { min = -0x80000000, max = 0x7FFFFFFF },
      verticalAmplitude = { min = -0x80000000, max = 0x7FFFFFFF },
      durationTicks = { min = 0, max = 0xFFFFFFFF },
    },
  },
  ["battle-background-alpha-scroll-transition"] = {
    taskKind = "battle-background-alpha-scroll-transition",
    taskContext = "battle-display",
    requiresBattlerTopology = true,
    runtimeSelection = "battle-background-three-way-screen-selection",
    resourceSlots = { "character", "palette", "screenDefault", "screenBattlerClassFour", "screenContextFlag" },
    parameters = {
      backgroundLayer = { type = "enum", values = { ["battle-background-layer-2"] = true } },
      initialScrollX = { min = -0x8000, max = 0x7FFF },
      initialScrollY = { min = -0x8000, max = 0x7FFF },
      horizontalStep = { min = -0x8000, max = 0x7FFF },
      verticalStep = { min = -0x8000, max = 0x7FFF },
      pairedPositionTransformEnabled = { type = "boolean" },
      paletteTarget = { type = "enum", values = { ["battle-animation-palette-target"] = true } },
      durationTicks = { min = -0x8000, max = 0x7FFF },
    },
  },
  ["battle-background-sprite-slide-transition"] = {
    taskKind = "battle-background-sprite-slide-transition",
    taskContext = "battle-display",
    requiresBattlerTopology = true,
    runtimeSelection = "battle-background-three-way-screen-selection",
    resourceSlots = { "character", "palette", "screenDefault", "screenBattlerClassFour", "screenContextFlag" },
    parameters = {
      backgroundLayer = { type = "enum", values = { ["battle-background-layer-2"] = true } },
      initialScrollX = { min = -0x8000, max = 0x7FFF },
      initialScrollY = { min = -0x8000, max = 0x7FFF },
      horizontalStep = { min = -0x8000, max = 0x7FFF },
      verticalStep = { min = -0x8000, max = 0x7FFF },
      pairedPositionTransformEnabled = { type = "boolean" },
      paletteTarget = { type = "enum", values = { ["battle-animation-palette-target"] = true } },
      durationTicks = { min = -0x8000, max = 0x7FFF },
    },
  },
  ["pokemon-picture-affine-blend-palette-transition"] = {
    taskKind = "pokemon-picture-affine-blend-palette-transition",
    taskContext = "battle-display",
    requiresSpriteContextTable = true,
    parameters = {},
  },
  ["battle-background-four-picture-move-power-transition"] = {
    taskKind = "battle-background-four-picture-move-power-transition",
    taskContext = "battle-display",
    requiresBattlerTopology = true,
    requiresMovePower = true,
    parameters = {
      backgroundLayer = { type = "enum", values = { ["battle-background-layer-3"] = true } },
      pictureSets = {
        type = "enum-array",
        minLength = 1,
        maxLength = 1,
        values = { ["all-battler-positions"] = true },
      },
      durationTicks = { min = 10, max = 10 },
      defaultProfile = { min = 0, max = 0 },
      profileByMovePower = { type = "move-power-profile-map" },
    },
  },
  ["pokemon-picture-selected-pair-transition"] = {
    taskKind = "pokemon-picture-selected-pair-transition",
    taskContext = "pokemon-picture",
    parameters = {
      pictureSets = {
        type = "enum-array",
        minLength = 0,
        maxLength = 4,
        values = PICTURE_SETS,
      },
    },
  },
  ["battle-sprite-blend-alpha-transition"] = {
    taskKind = "battle-sprite-blend-alpha-transition",
    taskContext = "battle-display",
    parameters = {
      oamModeSpriteSlots = {
        type = "enum-array",
        minLength = 0,
        maxLength = 4,
        values = {
          ["sprite-context-slot-0"] = true,
          ["sprite-context-slot-1"] = true,
          ["sprite-context-slot-2"] = true,
          ["sprite-context-slot-3"] = true,
        },
      },
      startCoefficientA = { min = -0x8000, max = 0x7FFF },
      targetCoefficientA = { min = -0x80000000, max = 0x7FFFFFFF },
      startCoefficientB = { min = -0x8000, max = 0x7FFF },
      targetCoefficientB = { min = -0x80000000, max = 0x7FFFFFFF },
      durationTicks = { min = -0x8000, max = 0x7FFF },
    },
  },
  ["pokemon-picture-target-background-slide"] = {
    taskKind = "pokemon-picture-target-background-slide",
    taskContext = "battle-display",
    battlerTarget = "target",
    parameters = {},
  },
  ["pokemon-picture-target-priority-transition"] = {
    taskKind = "pokemon-picture-target-priority-transition",
    taskContext = "pokemon-picture",
    battlerTarget = "target",
    parameters = {},
  },
  ["pokemon-picture-selected-position-offset-transition"] = {
    taskKind = "pokemon-picture-selected-position-offset-transition",
    taskContext = "pokemon-picture",
    requiresBattlerTopology = true,
    parameters = {
      pictureTarget = {
        type = "enum",
        values = {
          ["active-battler"] = true,
          ["active-battler-pair-when-enabled"] = true,
          ["opposing-battler"] = true,
          ["opposing-battler-pair-when-enabled"] = true,
        },
      },
      durationTicks = { min = 0, max = 0xFFFFFFFF },
      signedOffset = { min = -0x8000, max = 0x7FFF },
    },
  },
  ["pokemon-picture-two-phase-scale-transition"] = {
    taskKind = "pokemon-picture-two-phase-scale-transition",
    taskContext = "pokemon-picture",
    parameters = {
      firstEndpoint = { min = -0x8000, max = 0x7FFF },
      firstDurationTicks = { min = 0, max = 0xFFFFFFFF },
      phaseDelayTicks = { min = 0, max = 0xFF },
      secondEndpointX = { min = -0x8000, max = 0x7FFF },
      secondEndpointY = { min = -0x8000, max = 0x7FFF },
      secondDurationTicks = { min = 0, max = 0xFFFFFFFF },
    },
  },
  ["pokemon-picture-managed-sprite-scale-pulse-attacker"] = {
    taskKind = "pokemon-picture-managed-sprite-scale-pulse",
    taskContext = "battle-sprite",
    battlerTarget = "attacker",
    requiresSpriteContextTable = true,
    parameters = {
      spriteContextSlot = { min = 0, max = 4 },
      blendCoefficient = { min = 0, max = 0xFFFFFFFF },
      scaleStart = { min = -0x8000, max = 0x7FFF },
      scaleDivisor = { min = -0x8000, max = 0x7FFF },
      scaleEnd = { min = -0x8000, max = 0x7FFF },
      repeatCount = { min = 0, max = 0xFFFFFFFF },
      firstDurationTicks = { min = -0x8000, max = 0x7FFF },
      returnDurationTicks = { min = 0, max = 0xFFFF },
    },
  },
  ["pokemon-picture-managed-sprite-scale-pulse-target"] = {
    taskKind = "pokemon-picture-managed-sprite-scale-pulse",
    taskContext = "battle-sprite",
    battlerTarget = "target",
    requiresSpriteContextTable = true,
    parameters = {
      spriteContextSlot = { min = 0, max = 4 },
      blendCoefficient = { min = 0, max = 0xFFFFFFFF },
      scaleStart = { min = -0x8000, max = 0x7FFF },
      scaleDivisor = { min = -0x8000, max = 0x7FFF },
      scaleEnd = { min = -0x8000, max = 0x7FFF },
      repeatCount = { min = 0, max = 0xFFFFFFFF },
      firstDurationTicks = { min = -0x8000, max = 0x7FFF },
      returnDurationTicks = { min = 0, max = 0xFFFF },
    },
  },
  ["pokemon-picture-selected-position-transition"] = {
    taskKind = "pokemon-picture-selected-position-transition",
    taskContext = "pokemon-picture",
    requiresBattlerTopology = true,
    parameters = {
      pictureTarget = {
        type = "enum",
        values = {
          attacker = true,
          ["attacker-related-position-when-paired"] = true,
          target = true,
          ["target-related-position-when-paired"] = true,
        },
      },
      positionBasis = {
        type = "enum",
        values = {
          ["battle-position-anchors"] = true,
          ["selected-picture-origin"] = true,
        },
      },
      durationTicks = { min = 0, max = 0xFFFF },
    },
  },
  ["battle-sprite-priority-appearance-transition"] = {
    taskKind = "battle-sprite-priority-appearance-transition",
    taskContext = "battle-display",
    requiresBattlerTopology = true,
    requiresSpriteContextTable = true,
    parameters = {
      spriteContextSlot = { min = 0, max = 4 },
      durationTicks = { min = 0, max = 0xFFFFFFFF },
      spritePriority = {
        type = "enum",
        values = { front = true, middle = true, back = true, unchanged = true },
      },
      baseDrawPriorityEnabled = { type = "boolean" },
      baseDrawPriority = { min = 0, max = 0xFFFFFFFF },
      drawPriorityBattler = {
        type = "enum",
        values = { attacker = true, target = true, none = true },
      },
      drawPriorityPattern = {
        type = "enum",
        values = { standard = true, reversed = true, unchanged = true },
      },
      hideWhenNotDoubleBattle = { type = "boolean" },
      appearanceMotionEnabled = { type = "boolean" },
      appearanceBlendProfile = {
        type = "enum",
        values = { primary = true, alternate = true },
      },
    },
  },
  ["pokemon-picture-cyclic-two-phase-position-transition"] = {
    taskKind = "pokemon-picture-cyclic-two-phase-position-transition",
    taskContext = "pokemon-picture",
    requiresBattlerTopology = true,
    parameters = {
      pictureTarget = {
        type = "enum",
        values = {
          attacker = true,
          target = true,
          ["first-battler-state-zero-or-two"] = true,
          ["first-battler-state-four"] = true,
          ["first-battler-state-one-or-three"] = true,
          ["first-battler-state-five"] = true,
        },
      },
      startX = { min = -0x80000000, max = 0x7FFFFFFF },
      endX = { min = -0x80000000, max = 0x7FFFFFFF },
      startY = { min = -0x80000000, max = 0x7FFFFFFF },
      endY = { min = -0x80000000, max = 0x7FFFFFFF },
      interpolationDivisor = { min = -0x8000, max = 0x7FFF },
      additionalCycles = { min = 0, max = 0xFFFF },
      repeatDelayTicks = { min = -0x8000, max = 0x7FFF },
      firstDurationTicks = { min = -0x8000, max = 0x7FFF },
      returnDurationTicks = { min = 0, max = 0xFFFF },
    },
  },
  ["battle-background-alternating-scroll-transition"] = {
    taskKind = "battle-background-alternating-scroll-transition",
    taskContext = "battle-display",
    parameters = {
      horizontalOffset = { min = -0x8000, max = 0x7FFF },
      verticalOffset = { min = -0x8000, max = 0x7FFF },
      ticksPerDirection = { min = 0, max = 0xFFFFFFFF },
      directionChanges = { min = 0, max = 0xFFFFFFFF },
      phaseIntervalTicks = { min = 0, max = 0xFFFFFFFF },
      backgroundLayer = {
        type = "enum",
        values = {
          ["battle-background-layer-2"] = true,
          ["battle-background-layer-3"] = true,
        },
      },
    },
  },
  ["battle-background-scanline-sine-wave-transition"] = {
    taskKind = "battle-background-scanline-sine-wave-transition",
    taskContext = "battle-display",
    parameters = {
      backgroundLayer = {
        type = "enum",
        values = { ["battle-background-layer-3"] = true },
      },
      durationTicks = { min = 0, max = 0xFFFFFFFF },
    },
  },
  ["pokemon-picture-entry-offset-attacker"] = {
    taskKind = "pokemon-picture-entry-offset-transition",
    taskContext = "pokemon-picture",
    battlerTarget = "attacker",
    parameters = {},
  },
  ["pokemon-picture-entry-offset-target"] = {
    taskKind = "pokemon-picture-entry-offset-transition",
    taskContext = "pokemon-picture",
    battlerTarget = "target",
    parameters = {},
  },
  ["pokemon-picture-oscillating-axis-motion"] = {
    taskKind = "pokemon-picture-oscillating-axis-motion",
    taskContext = "pokemon-picture",
    parameters = {},
  },
  ["pokemon-picture-two-battler-crossing-motion"] = {
    taskKind = "pokemon-picture-two-battler-crossing-motion",
    taskContext = "pokemon-picture",
    parameters = {},
  },
  ["pokemon-picture-paired-position-interpolation-attacker"] = {
    taskKind = "pokemon-picture-paired-position-interpolation",
    taskContext = "pokemon-picture",
    battlerTarget = "attacker",
    parameters = {
      spriteContextSlot = { min = 0, max = 9 },
      reverseEndpoints = { type = "boolean" },
      endpointX = { min = -0x8000, max = 0x7FFF },
      endpointY = { min = -0x8000, max = 0x7FFF },
      initialSteps = { min = 0, max = 0xFFFF },
      stepIntervalTicks = { min = 0, max = 0xFFFF },
    },
  },
  ["pokemon-picture-paired-position-interpolation-target"] = {
    taskKind = "pokemon-picture-paired-position-interpolation",
    taskContext = "pokemon-picture",
    battlerTarget = "target",
    parameters = {
      spriteContextSlot = { min = 0, max = 9 },
      reverseEndpoints = { type = "boolean" },
      endpointX = { min = -0x8000, max = 0x7FFF },
      endpointY = { min = -0x8000, max = 0x7FFF },
      initialSteps = { min = 0, max = 0xFFFF },
      stepIntervalTicks = { min = 0, max = 0xFFFF },
    },
  },
  ["pokemon-picture-two-phase-entry-motion"] = {
    taskKind = "pokemon-picture-two-phase-entry-motion",
    taskContext = "pokemon-picture",
    parameters = {},
  },
  ["pokemon-picture-paired-position-interpolation"] = {
    taskKind = "pokemon-picture-paired-position-interpolation",
    taskContext = "pokemon-picture",
    battlerTarget = "target",
    parameters = {
      spriteContextSlot = { min = 0, max = 9 },
      reverseEndpoints = { type = "boolean" },
      endpointX = { min = -0x8000, max = 0x7FFF },
      endpointY = { min = -0x8000, max = 0x7FFF },
      initialSteps = { min = 0, max = 0xFFFF },
      stepIntervalTicks = { min = 0, max = 0xFFFF },
    },
  },
  ["pokemon-picture-double-sprite-scale-settle"] = {
    taskKind = "pokemon-picture-double-sprite-scale-settle",
    taskContext = "pokemon-picture",
    parameters = {},
  },
  ["pokemon-picture-battler-pair-scale-transition"] = {
    taskKind = "pokemon-picture-battler-pair-scale-transition",
    taskContext = "pokemon-picture",
    parameters = {},
  },
  ["battle-background-pokepic-slide"] = {
    taskKind = "battle-background-pokepic-slide",
    taskContext = "battle-display",
    parameters = {},
  },
  ["pokemon-picture-palette-pulse-position-transition"] = {
    taskKind = "pokemon-picture-palette-pulse-position-transition",
    taskContext = "pokemon-picture",
    parameters = {},
  },
  ["pokemon-picture-table-driven-position-transition"] = {
    taskKind = "pokemon-picture-table-driven-position-transition",
    taskContext = "pokemon-picture",
    parameters = {},
  },
  ["pokemon-picture-position-path-transition"] = {
    taskKind = "pokemon-picture-position-path-transition",
    taskContext = "pokemon-picture",
    parameters = {
      positionPath = {
        type = "enum",
        values = {
          ["all-battler-positions"] = true,
          ["active-and-related-pair"] = true,
          ["selected-position-anchors"] = true,
        },
      },
      attackerAnchor = { type = "boolean" },
      attackerRelatedAnchor = { type = "boolean" },
      targetAnchor = { type = "boolean" },
      targetRelatedAnchor = { type = "boolean" },
      stepMultiplier = { min = 0, max = 0xFFFFFFFF },
      durationTicks = { min = 0, max = 0xFFFFFFFF },
    },
  },
  ["pokemon-picture-repeated-palette-fade"] = {
    taskKind = "pokemon-picture-repeated-palette-fade",
    taskContext = "pokemon-picture",
    parameters = {
      pictureTarget = {
        type = "enum",
        values = {
          attacker = true,
          target = true,
          ["attacker-related-position-when-paired"] = true,
          ["target-related-position-when-paired"] = true,
          ["first-battler-state-zero-or-two"] = true,
          ["first-battler-state-four"] = true,
          ["first-battler-state-one-or-three"] = true,
          ["first-battler-state-five"] = true,
        },
      },
      framesPerStep = { min = 0, max = 0xFFFFFFFF },
      repeatCount = { min = 1, max = 0x7FFFFFFF },
      targetColor = { min = -0x80000000, max = 0x7FFFFFFF },
      fadeExtent = { min = 0, max = 0xFFFFFFFF },
      pauseTicks = { min = 0, max = 0xFFFFFFFF },
    },
  },
  ["pokemon-picture-battle-palette-fade-cycle"] = {
    taskKind = "pokemon-picture-battle-palette-fade-cycle",
    taskContext = "battle-palette",
    parameters = {},
  },
  ["pokemon-picture-and-battle-palette-fade-cycle"] = {
    taskKind = "pokemon-picture-and-battle-palette-fade-cycle",
    taskContext = "battle-palette",
    parameters = {},
  },
  ["pokemon-picture-and-battle-palette-fade"] = {
    taskKind = "pokemon-picture-and-battle-palette-fade",
    taskContext = "battle-palette",
    parameters = {
      paletteTarget = {
        type = "enum",
        values = {
          ["battle-animation-palette-target"] = true,
          ["main-extra-background-0"] = true,
          ["main-extra-background-1"] = true,
        },
      },
      wait = { min = -0x80, max = 0x7F },
      startCoefficient = { min = 0, max = 0xFF },
      endCoefficient = { min = 0, max = 0xFF },
      nextColor = { min = 0, max = 0xFFFF },
    },
  },
  ["pokemon-picture-four-sprite-wave-transition"] = {
    taskKind = "pokemon-picture-four-sprite-wave-transition",
    taskContext = "pokemon-picture",
    parameters = {},
  },
  ["pokemon-picture-z-rotation-target-derived-pivot"] = {
    taskKind = "pokemon-picture-z-rotation-transition",
    taskContext = "pokemon-picture",
    battlerTarget = "target",
    parameters = {
      startAngle = { min = 0, max = 0xFFFF },
      targetAngle = { min = 0, max = 0xFFFF },
      durationTicks = { min = 0, max = 0xFFFFFFFF },
      reverseDirection = { type = "boolean" },
    },
  },
  ["pokemon-picture-z-rotation-target-explicit-pivot"] = {
    taskKind = "pokemon-picture-z-rotation-transition",
    taskContext = "pokemon-picture",
    battlerTarget = "target",
    parameters = {
      startAngle = { min = 0, max = 0xFFFF },
      targetAngle = { min = 0, max = 0xFFFF },
      durationTicks = { min = 0, max = 0xFFFFFFFF },
      reverseDirection = { type = "boolean" },
      pivotX = { min = -0x8000, max = 0x7FFF },
      pivotY = { min = -0x8000, max = 0x7FFF },
    },
  },
  ["pokemon-picture-z-rotation-attacker-derived-pivot"] = {
    taskKind = "pokemon-picture-z-rotation-transition",
    taskContext = "pokemon-picture",
    battlerTarget = "attacker",
    parameters = {
      startAngle = { min = 0, max = 0xFFFF },
      targetAngle = { min = 0, max = 0xFFFF },
      durationTicks = { min = 0, max = 0xFFFFFFFF },
      reverseDirection = { type = "boolean" },
    },
  },
  ["pokemon-picture-z-rotation-attacker-explicit-pivot"] = {
    taskKind = "pokemon-picture-z-rotation-transition",
    taskContext = "pokemon-picture",
    battlerTarget = "attacker",
    parameters = {
      startAngle = { min = 0, max = 0xFFFF },
      targetAngle = { min = 0, max = 0xFFFF },
      durationTicks = { min = 0, max = 0xFFFFFFFF },
      reverseDirection = { type = "boolean" },
      pivotX = { min = -0x8000, max = 0x7FFF },
      pivotY = { min = -0x8000, max = 0x7FFF },
    },
  },
  ["sprite-affine-scale-and-blend-transition"] = {
    taskKind = "sprite-affine-scale-and-blend-transition",
    taskContext = "battle-sprite",
    parameters = {},
  },
  ["pokemon-picture-repeated-scale-position-transition"] = {
    taskKind = "pokemon-picture-repeated-scale-position-transition",
    taskContext = "pokemon-picture",
    parameters = {},
  },
  ["battle-background-picture-wipe-transition"] = {
    taskKind = "battle-background-picture-wipe-transition",
    taskContext = "battle-display",
    parameters = {},
  },
  ["battle-background-picture-scroll-oscillation"] = {
    taskKind = "battle-background-picture-scroll-oscillation",
    taskContext = "battle-display",
    parameters = {
      directionState = { min = 0, max = 0xFF },
      phaseIndex = { min = 0, max = 0xFF },
    },
  },
  ["battle-background-picture-coordinate-sweep"] = {
    taskKind = "battle-background-picture-coordinate-sweep",
    taskContext = "battle-display",
    parameters = {
      startX = { min = -0x8000, max = 0x7FFF },
      startY = { min = -0x8000, max = 0x7FFF },
      deltaX = { min = -0x8000, max = 0x7FFF },
      deltaY = { min = -0x8000, max = 0x7FFF },
    },
  },
  ["pokemon-picture-managed-sprite-affine-pair-transition"] = {
    taskKind = "pokemon-picture-managed-sprite-affine-pair-transition",
    taskContext = "pokemon-picture",
    parameters = {},
  },
  ["pokemon-picture-vanish-and-restore-transition"] = {
    taskKind = "pokemon-picture-vanish-and-restore-transition",
    taskContext = "pokemon-picture",
    parameters = {},
  },
  ["pokemon-picture-three-sprite-affine-transition"] = {
    taskKind = "pokemon-picture-three-sprite-affine-transition",
    taskContext = "pokemon-picture",
    parameters = {},
  },
  ["battle-background-picture-palette-scroll"] = {
    taskKind = "battle-background-picture-palette-scroll",
    taskContext = "battle-display",
    parameters = {},
  },
  ["battle-sprite-panel-slide-down"] = {
    taskKind = "battle-sprite-panel-slide",
    taskContext = "sprite-system",
    parameters = {
      firstPanelOffsetX = { min = -0x8000, max = 0x7FFF },
      firstPanelOffsetY = { min = -0x8000, max = 0x7FFF },
      secondPanelOffsetX = { min = -0x8000, max = 0x7FFF },
      secondPanelOffsetY = { min = -0x8000, max = 0x7FFF },
      durationTicks = { min = 1, max = 0xFFFFFFFF },
    },
  },
  ["battle-sprite-panel-slide-up"] = {
    taskKind = "battle-sprite-panel-slide",
    taskContext = "sprite-system",
    parameters = {
      firstPanelOffsetX = { min = -0x8000, max = 0x7FFF },
      firstPanelOffsetY = { min = -0x8000, max = 0x7FFF },
      secondPanelOffsetX = { min = -0x8000, max = 0x7FFF },
      secondPanelOffsetY = { min = -0x8000, max = 0x7FFF },
      durationTicks = { min = 1, max = 0xFFFFFFFF },
    },
  },
  ["battle-sprite-panel-slide-far-up"] = {
    taskKind = "battle-sprite-panel-slide",
    taskContext = "sprite-system",
    parameters = {
      firstPanelOffsetX = { min = -0x8000, max = 0x7FFF },
      firstPanelOffsetY = { min = -0x8000, max = 0x7FFF },
      secondPanelOffsetX = { min = -0x8000, max = 0x7FFF },
      secondPanelOffsetY = { min = -0x8000, max = 0x7FFF },
      durationTicks = { min = 1, max = 0xFFFFFFFF },
    },
  },
  ["pokemon-picture-randomized-position-motion-attacker"] = {
    taskKind = "pokemon-picture-randomized-position-motion",
    taskContext = "pokemon-picture",
    battlerTarget = "attacker",
    parameters = {},
  },
  ["pokemon-picture-randomized-position-motion-target"] = {
    taskKind = "pokemon-picture-randomized-position-motion",
    taskContext = "pokemon-picture",
    battlerTarget = "target",
    parameters = {},
  },
  ["pokemon-picture-scale-position-transition"] = {
    taskKind = "pokemon-picture-scale-position-transition",
    taskContext = "pokemon-picture",
    parameters = {},
  },
  ["pokemon-picture-palette-fade-position-transition"] = {
    taskKind = "pokemon-picture-palette-fade-position-transition",
    taskContext = "pokemon-picture",
    parameters = {
      approachOffset = { min = -0x8000, max = 0x7FFF },
      settleOffset = { min = -0x8000, max = 0x7FFF },
      approachTicks = { min = 0, max = 0xFFFFFFFF },
      settleTicks = { min = 0, max = 0xFFFFFFFF },
    },
  },
  ["pokemon-picture-sinusoidal-position-attacker"] = {
    taskKind = "pokemon-picture-sinusoidal-position-motion",
    taskContext = "pokemon-picture",
    battlerTarget = "attacker",
    parameters = {
      oscillationCycles = { min = 0, max = 0xFFFFFFFF },
      durationTicks = { min = 0, max = 0xFFFFFFFF },
    },
  },
  ["pokemon-picture-sinusoidal-position-attacker-pair"] = {
    taskKind = "pokemon-picture-sinusoidal-position-motion",
    taskContext = "pokemon-picture",
    battlerTarget = "attacker",
    parameters = {
      oscillationCycles = { min = 0, max = 0xFFFFFFFF },
      durationTicks = { min = 0, max = 0xFFFFFFFF },
    },
  },
  ["pokemon-picture-sinusoidal-position-target"] = {
    taskKind = "pokemon-picture-sinusoidal-position-motion",
    taskContext = "pokemon-picture",
    battlerTarget = "target",
    parameters = {
      oscillationCycles = { min = 0, max = 0xFFFFFFFF },
      durationTicks = { min = 0, max = 0xFFFFFFFF },
    },
  },
  ["pokemon-picture-sinusoidal-position-target-pair"] = {
    taskKind = "pokemon-picture-sinusoidal-position-motion",
    taskContext = "pokemon-picture",
    battlerTarget = "target",
    parameters = {
      oscillationCycles = { min = 0, max = 0xFFFFFFFF },
      durationTicks = { min = 0, max = 0xFFFFFFFF },
    },
  },
  ["pokemon-picture-affine-sprite-entry-transition"] = {
    taskKind = "pokemon-picture-affine-sprite-entry-transition",
    taskContext = "pokemon-picture",
    parameters = {},
  },
  ["pokemon-picture-height-position-transition"] = {
    taskKind = "pokemon-picture-height-position-transition",
    taskContext = "pokemon-picture",
    parameters = {},
  },
  ["pokemon-picture-defender-knockback"] = {
    taskKind = "pokemon-picture-defender-knockback",
    taskContext = "pokemon-picture",
    battlerTarget = "target",
    parameters = {
      durationTicks = { min = 0, max = 0xFFFF },
    },
  },
  ["pokemon-picture-attacker-dash-afterimages"] = {
    taskKind = "pokemon-picture-attacker-dash-afterimages",
    taskContext = "pokemon-picture",
    battlerTarget = "attacker",
    parameters = {
      durationTicks = { min = 0, max = 0xFFFF },
    },
  },
  ["pokemon-picture-linear-offscreen-transition"] = {
    taskKind = "pokemon-picture-linear-offscreen-transition",
    taskContext = "pokemon-picture",
    requiresBattlerTopology = true,
    parameters = {
      durationTicks = { min = 0, max = 0xFFFF },
      offscreenDistance = { min = 1, max = 0x7FFF },
      exitOwnSide = { type = "boolean" },
      pictureTarget = {
        type = "enum",
        values = {
          attacker = true,
          target = true,
          ["attacker-related-position-when-paired"] = true,
          ["target-related-position-when-paired"] = true,
        },
      },
    },
  },
  ["pokemon-picture-reset-position-transition"] = {
    taskKind = "pokemon-picture-reset-position-transition",
    taskContext = "pokemon-picture",
    parameters = {
      pictureTarget = {
        type = "enum",
        values = {
          attacker = true,
          target = true,
          ["attacker-related-position-when-paired"] = true,
          ["target-related-position-when-paired"] = true,
        },
      },
    },
  },
  ["pokemon-picture-vanish-affine-transition"] = {
    taskKind = "pokemon-picture-vanish-affine-transition",
    taskContext = "pokemon-picture",
    parameters = {},
  },
  ["pokemon-picture-repeated-vanish-transition"] = {
    taskKind = "pokemon-picture-repeated-vanish-transition",
    taskContext = "pokemon-picture",
    parameters = {
      toggleCount = { min = 0, max = 0xFFFFFFFF },
      intervalTicks = { min = 0, max = 0xFFFFFFFF },
    },
  },
  ["battle-sprite-mosaic-transition"] = {
    taskKind = "battle-sprite-mosaic-transition",
    taskContext = "battle-sprite",
    parameters = {
      spriteContextSlot = { min = 0, max = 4 },
      step = { min = -0x8000, max = 0x7FFF },
      initialHorizontal = { min = 0, max = 0xFFFFFFFF },
      initialVertical = { min = 0, max = 0xFFFFFFFF },
      durationTicks = { min = 1, max = 0xFFFFFFFF },
    },
  },
  ["battle-sprite-affine-appearance-transition"] = {
    taskKind = "battle-sprite-affine-appearance-transition",
    taskContext = "battle-sprite",
    parameters = {},
  },
  ["pokemon-picture-three-sprite-position-wave-transition"] = {
    taskKind = "pokemon-picture-three-sprite-position-wave-transition",
    taskContext = "pokemon-picture",
    parameters = {},
  },
  ["pokemon-picture-reciprocal-position-palette-transition"] = {
    taskKind = "pokemon-picture-reciprocal-position-palette-transition",
    taskContext = "pokemon-picture",
    parameters = {},
  },
  ["pokemon-picture-palette-fade"] = {
    taskKind = "pokemon-picture-palette-fade",
    taskContext = "pokemon-picture",
    parameters = {},
  },
  ["battle-background-position-transition"] = {
    taskKind = "battle-background-blend-transition",
    taskContext = "battle-display",
    parameters = {
      offsetX = { min = -0x8000, max = 0x7FFF },
      offsetY = { min = -0x8000, max = 0x7FFF },
      ticksPerStep = { min = -0x8000, max = 0x7FFF },
      steps = { min = -0x8000, max = 0x7FFF },
      pictureSets = {
        type = "enum-array",
        minLength = 0,
        maxLength = 4,
        values = PICTURE_SETS,
      },
      pictureAttributeOffset = { type = "boolean" },
      managedSpriteOffset = { type = "boolean" },
      backgroundPositionEnabled = { type = "boolean" },
    },
  },
  ["pokemon-picture-offset-transition"] = {
    taskKind = "pokemon-picture-position-offset-transition",
    taskContext = "pokemon-picture",
    requiresBattlerTopology = true,
    parameters = {
      pictureTarget = { type = "enum", values = PICTURE_SETS },
      durationTicks = { min = -0x8000, max = 0x7FFF },
      offsetX = { min = -0x8000, max = 0x7FFF },
      offsetY = { min = -0x8000, max = 0x7FFF },
    },
  },
  ["managed-sprite-frame-loop"] = {
    taskKind = "managed-sprite-draw-loop",
    taskContext = "sprite-system",
    parameters = { frameTicks = { min = 1, max = 0xFFFFFFFF } },
  },
  ["battle-particle-emitter-battler-path"] = {
    taskKind = "battle-particle-emitter-battler-path",
    taskContext = "battle-particle-emitter",
    requiresSpriteContextTable = true,
    parameters = {
      spriteContextSlot = { min = 0, max = 70 },
      offsetX = { min = -0x8000, max = 0x7FFF },
      offsetY = { min = -0x8000, max = 0x7FFF },
      leadingInterpolationSteps = { min = -0x8000, max = 0x7FFF },
      sinePeriodDivisor = { min = -0x8000, max = 0x7FFF },
      interpolationDurationTicks = { min = 0, max = 0xFFFF },
      pairOrder = {
        type = "enum",
        values = {
          ["attacker-target"] = true,
          ["target-attacker"] = true,
        },
      },
      initialInterpolationSteps = { min = 0, max = 0xFFFF },
      completionLimit = { min = 0, max = 0xFF },
      sinusoidalOffset = { type = "boolean" },
    },
  },
  ["battle-particle-emitter-curved-battler-path"] = {
    taskKind = "battle-particle-emitter-curved-battler-path",
    taskContext = "battle-particle-emitter",
    parameters = {
      emitterContextSlot = { min = 0, max = 9 },
      horizontalOffset = { min = -0x8000, max = 0x7FFF },
      verticalOffset = { min = -0x8000, max = 0x7FFF },
      durationTicks = { min = -0x8000, max = 0x7FFF },
      curveControl = { min = -0x8000, max = 0x7FFF },
      curveScale = { min = -0x80000000, max = 0x7FFFFFFF },
      battlerOrder = {
        type = "enum",
        values = {
          ["attacker-target"] = true,
          ["target-attacker"] = true,
        },
      },
      initialInterpolationSteps = { min = 0, max = 0xFFFF },
      completionLimit = { min = 1, max = 0xFFFF },
      sinusoidalOffset = { type = "boolean" },
    },
  },
}

local RESOURCE_KEY_SLOTS = {
  character = true,
  palette = true,
  cell = true,
  animation = true,
  multiCell = true,
  multiAnimation = true,
  screen = true,
  screenDefault = true,
  screenAlternate = true,
  screenBattlerClassFour = true,
  screenContextFlag = true,
  template = true,
}

local RESOURCE_SLOTS_BY_OPERATION = {
  ["load-battle-background"] = { "character", "palette", "screenDefault", "screenAlternate" },
  ["load-managed-sprite-resources"] = { "character", "palette", "cell", "animation" },
  ["load-sprite-character"] = { "character" },
  ["load-sprite-palette"] = { "palette" },
  ["load-sprite-cell"] = { "cell" },
  ["load-sprite-animation"] = { "animation" },
  ["create-managed-sprite"] = { "character", "palette", "cell", "animation" },
  ["create-configured-sprite"] = { "character", "palette", "cell", "animation" },
}

local OPTIONAL_RESOURCE_SLOTS_BY_OPERATION = {
  ["create-managed-sprite"] = { multiCell = true, multiAnimation = true },
  ["create-configured-sprite"] = { multiCell = true, multiAnimation = true },
}

local SPRITE_EFFECT_MODES = {
  ["first-battler-class-priority-gate"] = true,
  ["second-battler-class-priority-forward"] = true,
  ["first-battler-class-priority-alternate"] = true,
  ["second-battler-class-priority-reverse"] = true,
  ["retain-source-draw-state"] = true,
}

local TASK_INPUT_RULES = {
  ["helper-equals-one-then-side-class-equals-three-else-first"] = true,
}

local function checkInt(value, context, code, field)
  SchemaCheck.checkInteger(value, context, code, field, 0, nil)
end

local function checkString(value, context, code, field)
  SchemaCheck.checkNonEmptyString(value, context, code, field)
end

local fail = SchemaCheck.fail

-- Producer identities never reach runtime records at any depth.
local function checkNoNativeKeys(value, context, code, field)
  if type(value) ~= "table" then
    return
  end
  for key, nested in pairs(value) do
    local text = tostring(key)
    if
      text == "memberId"
      or text == "fileId"
      or text == "narcId"
      or text == "armAddress"
      or text == "callbackAddress"
      or text == "opcodeIndex"
      or text == "nativeOpcode"
    then
      fail(code, field .. " leaks source detail '" .. text .. "'", context)
    end
    checkNoNativeKeys(nested, context, code, field .. "." .. text)
  end
end

local function checkTaskKinds(taskKinds, context, code, field)
  if not Validate.isArray(taskKinds) then
    fail(code, field .. " must carry its task kinds in order", context)
  end
  for index, kind in ipairs(taskKinds) do
    checkString(kind, context, code, field .. "[" .. index .. "]")
  end
end

local function checkInstruction(instruction, context, code, field)
  if type(instruction) ~= "table" then
    fail(code, field .. " must be a record", context)
  end
  local definition = OPERATIONS[instruction.op]
  if definition == nil then
    fail(code, field .. " carries an unknown operation: " .. tostring(instruction.op), context)
    return
  end
  local allowed = { op = true }
  for name in pairs(definition) do
    allowed[name] = true
  end
  SchemaCheck.checkRecord(instruction, allowed, context, code, field)
  if
    definition.values ~= nil
    and not (instruction.op == "create-parameterized-battler-effect" and instruction.values == nil)
  then
    local values = instruction.values
    if not Validate.isArray(values) then
      fail(code, field .. ".values must be an array", context)
      return
    end
    if type(definition.values) == "number" and #values ~= definition.values then
      fail(code, field .. ".values has the wrong number of operands", context)
    end
    for index, value in ipairs(values) do
      SchemaCheck.checkInteger(value, context, code, field .. ".values[" .. index .. "]")
    end
  elseif instruction.values ~= nil then
    fail(code, field .. ".values is not part of this operation", context)
  end
  for _, name in ipairs({ "target", "branchTarget", "alternateTarget", "resumeTarget", "returnTarget" }) do
    if instruction[name] ~= nil then
      SchemaCheck.checkInteger(instruction[name], context, code, field .. "." .. name, 1)
    end
  end
  for _, name in ipairs({
    "callback",
    "sound",
    "taskKind",
    "taskInputRule",
    "taskStartRule",
    "callKey",
    "resource",
    "emitterPosition",
    "updateKind",
    "mode",
    "runtimeSelection",
    "battlerTarget",
    "actionProfile",
    "taskContext",
  }) do
    if instruction[name] ~= nil then
      checkString(instruction[name], context, code, field .. "." .. name)
    end
  end
  if instruction.emitterPosition ~= nil and not BATTLER_POSITION_SET[instruction.emitterPosition] then
    fail(code, field .. ".emitterPosition is unknown", context)
  end
  if
    instruction.op == "create-battler-effect" and (instruction.resource == nil or instruction.emitterPosition == nil)
  then
    fail(code, field .. " requires a particle resource and emitter position", context)
  end
  if
    instruction.op == "create-parameterized-battler-effect"
    and instruction.resource ~= nil
    and instruction.resource:match("^battle/particle%-emitter/[^/]+$") == nil
  then
    fail(code, field .. ".resource must be a semantic particle-emitter key", context)
  end
  if instruction.continuationSlot ~= nil then
    SchemaCheck.checkInteger(instruction.continuationSlot, context, code, field .. ".continuationSlot")
    if instruction.continuationSlot < 0 or instruction.continuationSlot > MAX_PARTICLE_CONTINUATION_SLOT then
      fail(code, field .. ".continuationSlot is outside the 71-slot particle continuation table", context)
    end
  end
  if instruction.cursorRule ~= nil then
    local cursorRules = {
      ["pending-redispatch-current-opcode; zero-advances-past-current-opcode"] = true,
      ["advance-when-phase-matches"] = true,
      ["advance-when-sound-finishes"] = true,
      ["advance-when-effects-finish"] = true,
      ["advance-when-confirm-input-matches"] = true,
      ["invoke-assert-service; redispatch-current-word-if-it-returns"] = true,
      ["leave-on-finished-cry; otherwise-consume-stop-word"] = true,
      ["advance-to-body-when-loop-slot-free; otherwise-redispatch-count-word"] = true,
      ["rewind-to-active-loop-body-until-count"] = true,
      ["call-first-free-subprogram-slot; all-slots-busy-redispatch-count-word"] = true,
      ["return-to-active-subprogram-slot"] = true,
    }
    if cursorRules[instruction.cursorRule] ~= true then
      fail(code, field .. ".cursorRule is unknown", context)
    end
  end
  if instruction.op == "wait-interpreter-counter" then
    if instruction.cursorRule ~= "pending-redispatch-current-opcode; zero-advances-past-current-opcode" then
      fail(code, field .. ".cursorRule does not preserve both counter wait paths", context)
    end
    if instruction.branchTarget == nil then
      fail(code, field .. ".branchTarget is required for the pending self-loop", context)
    end
  end
  if instruction.op == "call-subprogram" then
    if
      instruction.cursorRule ~= "call-first-free-subprogram-slot; all-slots-busy-redispatch-count-word"
      or instruction.branchTarget == nil
      or instruction.returnTarget == nil
    then
      fail(code, field .. ".call-subprogram must preserve call, return, and saturation cursor paths", context)
    end
  end
  checkNoNativeKeys(instruction, context, code, field)
  if instruction.ticks ~= nil then
    checkInt(instruction.ticks, context, code, field .. ".ticks")
  end
  if instruction.durationTicks ~= nil then
    checkInt(instruction.durationTicks, context, code, field .. ".durationTicks")
  end
  if instruction.taskKind ~= nil then
    checkString(instruction.taskKind, context, code, field .. ".taskKind")
    if not TASK_KINDS[instruction.taskKind] then
      fail(code, field .. ".taskKind is unknown", context)
    end
  end
  if instruction.taskContext ~= nil and not TASK_CONTEXTS[instruction.taskContext] then
    fail(code, field .. ".taskContext is unknown", context)
  end
  if instruction.op == "invoke-battle-animation-callback" then
    local callbackDefinition = ANIMATION_CALLBACKS[instruction.callback]
    if callbackDefinition == nil then
      fail(code, field .. ".callback is unknown", context)
      return
    end
    if
      instruction.taskKind ~= callbackDefinition.taskKind
      or instruction.taskContext ~= callbackDefinition.taskContext
      or instruction.battlerTarget ~= callbackDefinition.battlerTarget
    then
      fail(code, field .. " has callback semantics that do not match its source profile", context)
    end
    if instruction.runtimeSelection ~= callbackDefinition.runtimeSelection then
      fail(code, field .. ".runtimeSelection does not match its source callback profile", context)
    end
    if callbackDefinition.resourceSlots ~= nil then
      if type(instruction.resourceKeys) ~= "table" then
        fail(code, field .. ".resourceKeys must contain the callback's selected resources", context)
        return
      end
      local expectedSlots = {}
      for _, slot in ipairs(callbackDefinition.resourceSlots) do
        expectedSlots[slot] = true
      end
      for slot in pairs(instruction.resourceKeys) do
        if not expectedSlots[slot] then
          fail(code, field .. ".resourceKeys has an unexpected callback resource slot", context)
        end
        expectedSlots[slot] = nil
      end
      for slot in pairs(expectedSlots) do
        fail(code, field .. ".resourceKeys is missing callback resource slot " .. slot, context)
      end
    elseif instruction.resourceKeys ~= nil then
      fail(code, field .. ".resourceKeys are not declared by this callback profile", context)
    end
    local parameters = instruction.parameters
    if type(parameters) ~= "table" then
      fail(code, field .. ".parameters must be a record", context)
      return
    end
    for name, value in pairs(parameters) do
      local parameter = callbackDefinition.parameters[name]
      if parameter == nil then
        fail(code, field .. ".parameters has an unknown field " .. tostring(name), context)
        return
      elseif parameter.type == "boolean" then
        if type(value) ~= "boolean" then
          fail(code, field .. ".parameters." .. name .. " must be boolean", context)
        end
      elseif parameter.type == "enum" then
        if type(value) ~= "string" or parameter.values[value] ~= true then
          fail(code, field .. ".parameters." .. name .. " is unknown", context)
        end
      elseif parameter.type == "enum-array" then
        if not Validate.isArray(value) then
          fail(code, field .. ".parameters." .. name .. " must be an array", context)
          return
        end
        if #value < parameter.minLength or #value > parameter.maxLength then
          fail(code, field .. ".parameters." .. name .. " has an invalid length", context)
        end
        for index, item in ipairs(value) do
          if type(item) ~= "string" or parameter.values[item] ~= true then
            fail(code, field .. ".parameters." .. name .. "[" .. index .. "] is unknown", context)
          end
        end
      elseif parameter.type == "move-power-profile-map" then
        if not Validate.isArray(value) or #value ~= #MOVE_POWER_PROFILE_MAP then
          fail(code, field .. ".parameters." .. name .. " must contain the six source move-power cases", context)
        end
        for index, expected in ipairs(MOVE_POWER_PROFILE_MAP) do
          local case = value[index]
          SchemaCheck.checkRecord(
            case,
            { movePower = true, profile = true },
            context,
            code,
            field .. ".parameters." .. name
          )
          SchemaCheck.checkInteger(
            case.movePower,
            context,
            code,
            field .. ".parameters." .. name .. "[" .. index .. "].movePower"
          )
          SchemaCheck.checkInteger(
            case.profile,
            context,
            code,
            field .. ".parameters." .. name .. "[" .. index .. "].profile"
          )
          if case.movePower ~= expected.movePower or case.profile ~= expected.profile then
            fail(
              code,
              field .. ".parameters." .. name .. " does not match the source move-power profile table",
              context
            )
          end
        end
      else
        SchemaCheck.checkInteger(value, context, code, field .. ".parameters." .. name)
        if value < parameter.min or value > parameter.max then
          fail(code, field .. ".parameters." .. name .. " is outside its source range", context)
        end
      end
    end
    for name in pairs(callbackDefinition.parameters) do
      if parameters[name] == nil then
        fail(code, field .. ".parameters omitted " .. name, context)
      end
    end
  end
  if instruction.op == "set-pokemon-picture-vanished" then
    if type(instruction.vanished) ~= "boolean" then
      fail(code, field .. ".vanished must be boolean", context)
    end
    if not Validate.isArray(instruction.pictureSets) then
      fail(code, field .. ".pictureSets must be an array", context)
    end
    for index, pictureSet in ipairs(instruction.pictureSets) do
      if not PICTURE_SETS[pictureSet] then
        fail(code, field .. ".pictureSets[" .. index .. "] is unknown", context)
      end
    end
  end
  if instruction.op == "create-configured-sprite" then
    local expectedContext = CONFIGURED_SPRITE_TASK_CONTEXTS[instruction.taskKind]
    if expectedContext == nil or instruction.taskContext ~= expectedContext then
      fail(code, field .. " has a task context that does not match its configured sprite task", context)
    end
    local parameters = instruction.parameters
    local allowedParameters = CONFIGURED_SPRITE_TASK_PARAMETERS[instruction.taskKind] or {}
    if type(parameters) ~= "table" then
      fail(code, field .. ".parameters must be a record", context)
      return
    end
    for name, value in pairs(parameters) do
      local range = allowedParameters[name]
      if range == nil then
        fail(code, field .. ".parameters has an unknown field " .. tostring(name), context)
        return
      end
      SchemaCheck.checkInteger(value, context, code, field .. ".parameters." .. name)
      if value < range.min or value > range.max then
        fail(code, field .. ".parameters." .. name .. " is outside its source range", context)
      end
    end
    for name in pairs(allowedParameters) do
      if parameters[name] == nil then
        fail(code, field .. ".parameters omitted " .. name, context)
      end
    end
  end
  if instruction.updateKind ~= nil and not VISUAL_UPDATE_KINDS[instruction.updateKind] then
    fail(code, field .. ".updateKind is unknown", context)
  end
  if instruction.mode ~= nil and not SPRITE_EFFECT_MODES[instruction.mode] then
    fail(code, field .. ".mode is unknown", context)
  end
  if instruction.runtimeSelection ~= nil and not RUNTIME_SELECTIONS[instruction.runtimeSelection] then
    fail(code, field .. ".runtimeSelection is unknown", context)
  end
  if instruction.battlerTarget ~= nil and not BATTLER_TARGETS[instruction.battlerTarget] then
    fail(code, field .. ".battlerTarget is unknown", context)
  end
  if instruction.actionProfile ~= nil and not PARTICLE_ACTION_PROFILES[instruction.actionProfile] then
    fail(code, field .. ".actionProfile is unknown", context)
  end
  if instruction.op == "create-parameterized-battler-effect" then
    if instruction.actionProfile == nil or instruction.emitterPosition == nil then
      fail(code, field .. " requires a semantic action profile and emitter position", context)
    end
    if instruction.resource ~= nil then
      if instruction.resourceCases ~= nil or instruction.runtimeSelection ~= nil then
        fail(code, field .. " fixed emitter cannot carry position-pair resource cases", context)
      end
    elseif
      instruction.resourceCases == nil
      or instruction.runtimeSelection ~= "battler-particle-position-pair"
      or instruction.continuationSlot ~= nil
    then
      fail(code, field .. " requires a fixed emitter or a position-pair resource map", context)
    end
  end
  if instruction.op == "create-parameterized-battler-effect" and instruction.resourceCases ~= nil then
    if type(instruction.resourceCases) ~= "table" then
      fail(code, field .. ".resourceCases must be a record", context)
    end
    local expectedCases = {}
    for _, attacker in ipairs(BATTLER_POSITION_KEYS) do
      for _, target in ipairs(BATTLER_POSITION_KEYS) do
        expectedCases[attacker .. "/" .. target] = true
      end
    end
    for pairKey, resourceKey in pairs(instruction.resourceCases) do
      if
        not expectedCases[pairKey]
        or type(resourceKey) ~= "string"
        or (resourceKey ~= "source-assert" and resourceKey:match("^battle/particle%-emitter/[^/]+$") == nil)
      then
        fail(code, field .. ".resourceCases has an unknown position pair or invalid resource key", context)
      end
      expectedCases[pairKey] = nil
    end
    for pairKey in pairs(expectedCases) do
      fail(code, field .. ".resourceCases is missing position pair " .. pairKey, context)
    end
  end
  if instruction.resourceKeys ~= nil then
    if type(instruction.resourceKeys) ~= "table" then
      fail(code, field .. ".resourceKeys must be a record", context)
    end
    for slot, resourceKey in pairs(instruction.resourceKeys) do
      if not RESOURCE_KEY_SLOTS[slot] then
        fail(code, field .. ".resourceKeys has an unknown slot", context)
      end
      checkString(resourceKey, context, code, field .. ".resourceKeys." .. slot)
    end
    local requiredSlots = RESOURCE_SLOTS_BY_OPERATION[instruction.op]
    if requiredSlots ~= nil then
      local expectedSlots = {}
      for _, slot in ipairs(requiredSlots) do
        expectedSlots[slot] = true
      end
      local optionalSlots = OPTIONAL_RESOURCE_SLOTS_BY_OPERATION[instruction.op] or {}
      for slot in pairs(instruction.resourceKeys) do
        if not expectedSlots[slot] and not optionalSlots[slot] then
          fail(code, field .. ".resourceKeys has an unexpected slot", context)
        end
        expectedSlots[slot] = nil
      end
      for slot in pairs(expectedSlots) do
        fail(code, field .. ".resourceKeys is missing slot " .. slot, context)
      end
    end
  elseif RESOURCE_SLOTS_BY_OPERATION[instruction.op] ~= nil then
    fail(code, field .. ".resourceKeys is required for this operation", context)
  end
  if instruction.taskInputRule ~= nil and not TASK_INPUT_RULES[instruction.taskInputRule] then
    fail(code, field .. ".taskInputRule is unknown", context)
  end
  if instruction.taskStartRule ~= nil and not TASK_START_RULES[instruction.taskStartRule] then
    fail(code, field .. ".taskStartRule is unknown", context)
  end
  if instruction.branchTarget ~= nil then
    checkInt(instruction.branchTarget, context, code, field .. ".branchTarget")
  end
  if instruction.branchCases ~= nil then
    if not Validate.isArray(instruction.branchCases) then
      fail(code, field .. ".branchCases must be an array", context)
    end
    for index, branchCase in ipairs(instruction.branchCases) do
      local branchField = field .. ".branchCases[" .. index .. "]"
      SchemaCheck.checkRecord(
        branchCase,
        { sideMask = true, otherwise = true, target = true },
        context,
        code,
        branchField
      )
      local hasMask = branchCase.sideMask ~= nil
      local hasOtherwise = branchCase.otherwise == true
      if hasMask == hasOtherwise then
        fail(code, branchField .. " must have one condition", context)
      end
      if hasMask then
        checkInt(branchCase.sideMask, context, code, branchField .. ".sideMask")
      end
      if branchCase.otherwise ~= nil and not hasOtherwise then
        fail(code, branchField .. ".otherwise must be true", context)
      end
      checkInt(branchCase.target, context, code, branchField .. ".target")
    end
  end
  if instruction.callKey ~= nil then
    checkString(instruction.callKey, context, code, field .. ".callKey")
  end
end

local function checkProgram(program, context, code, field)
  SchemaCheck.checkRecord(
    program,
    { entry = true, instructions = true, subprograms = true, taskKinds = true },
    context,
    code,
    field
  )
  checkString(program.entry, context, code, field .. ".entry")
  if not Validate.isArray(program.instructions) or #program.instructions == 0 then
    fail(code, field .. " must carry its instructions in order", context)
  end
  for index, instruction in ipairs(program.instructions) do
    checkInstruction(instruction, context, code, field .. ".instructions[" .. index .. "]")
    if instruction.op == "wait-interpreter-counter" and instruction.branchTarget ~= index then
      fail(code, field .. ".instructions[" .. index .. "].branchTarget must target its pending self-loop", context)
    end
  end
  if type(program.subprograms) ~= "table" then
    fail(code, field .. " must carry its subprograms", context)
  end
  checkNoNativeKeys(program.subprograms, context, code, field .. ".subprograms")
  checkTaskKinds(program.taskKinds, context, code, field .. ".taskKinds")
end

local function checkDependencies(dependencies, context, code, field)
  if not Validate.isArray(dependencies) then
    fail(code, field .. " must carry its members", context)
  end
  local seen = {}
  for _, value in ipairs(dependencies) do
    checkString(value, context, code, field)
    if seen[value] then
      fail(code, field .. " carries a duplicate member " .. value, context)
    end
    seen[value] = true
  end
end

local function checkResources(resources, context, code, field)
  if type(resources) ~= "table" then
    fail(code, field .. " must be a record", context)
  end
  for key, descriptor in pairs(resources) do
    checkString(key, context, code, field .. " key")
    local entry = field .. "[" .. tostring(key) .. "]"
    if type(descriptor) ~= "table" then
      fail(code, entry .. " must be a record", context)
    end
    SchemaCheck.checkRecord(descriptor, { kind = true, payload = true, contentIdentity = true }, context, code, entry)
    if RESOURCE_KINDS[descriptor.kind] == nil then
      fail(code, entry .. " carries an unknown kind: " .. tostring(descriptor.kind), context)
    end
    checkString(descriptor.payload, context, code, entry .. ".payload")
    checkString(descriptor.contentIdentity, context, code, entry .. ".contentIdentity")
    if #descriptor.contentIdentity ~= 40 or string.match(descriptor.contentIdentity, "^[0-9a-f]+$") == nil then
      fail(code, entry .. ".contentIdentity must be a lowercase SHA-1 digest", context)
    end
    checkNoNativeKeys(descriptor, context, code, entry)
  end
end

local function checkRequiredContext(requiredContext, context, code, field)
  if type(requiredContext) ~= "table" then
    fail(code, field .. " must be a record", context)
  end
  if requiredContext.battle ~= nil or requiredContext.field ~= nil then
    fail(code, field .. " never reaches battle or field objects", context)
  end
  for key, parameter in pairs(requiredContext) do
    local expectedType = REQUIRED_CONTEXT_FIELDS[key]
    if expectedType == nil then
      fail(code, field .. " carries an unknown context parameter " .. tostring(key), context)
    end
    SchemaCheck.checkRecord(parameter, { type = true }, context, code, field .. "." .. key)
    if parameter.type ~= expectedType then
      fail(code, field .. "." .. key .. " has the wrong context type", context)
    end
  end
  for key in pairs(requiredContext) do
    if REQUIRED_CONTEXT_FIELDS[key] == nil then
      fail(code, field .. " carries an unknown context parameter " .. tostring(key), context)
    end
  end
  checkNoNativeKeys(requiredContext, context, code, field)
end

local function checkProgramResourceClosure(program, dependencies, resources, context, code)
  local expected = {}
  for _, key in ipairs(dependencies) do
    expected[key] = true
    if resources[key] == nil then
      fail(code, "effect dependency has no resource descriptor: " .. key, context)
    end
  end
  for key in pairs(resources) do
    if not expected[key] then
      fail(code, "effect resource is outside its dependency closure: " .. key, context)
    end
    expected[key] = nil
  end
  for key in pairs(expected) do
    fail(code, "effect resource dependency is missing: " .. key, context)
  end
  for index, instruction in ipairs(program.instructions) do
    local refs = {}
    -- Voices play through the shared audio cache by sequence symbol; the
    -- effect stages no private sound payload for them.
    if instruction.sound ~= nil and not tostring(instruction.sound):match("^SEQ_[%w_]+$") then
      fail(
        code,
        "instruction " .. index .. " names no shared sequence symbol: " .. tostring(instruction.sound),
        context
      )
    end
    if instruction.resource ~= nil then
      refs[#refs + 1] = instruction.resource
    end
    if instruction.resourceCases ~= nil then
      for _, key in pairs(instruction.resourceCases) do
        if key ~= "source-assert" then
          refs[#refs + 1] = key
          if resources[key] ~= nil and resources[key].kind ~= "particle-emitter" then
            fail(code, "instruction " .. index .. " references a resource that is not a particle emitter", context)
          end
        end
      end
    end
    if
      instruction.op == "create-parameterized-battler-effect"
      and instruction.resource ~= nil
      and resources[instruction.resource] ~= nil
      and resources[instruction.resource].kind ~= "particle-emitter"
    then
      fail(code, "instruction " .. index .. " references a resource that is not a particle emitter", context)
    end
    if
      instruction.op == "create-battler-effect"
      and instruction.resource ~= nil
      and resources[instruction.resource] ~= nil
      and resources[instruction.resource].kind ~= "particle"
    then
      fail(code, "instruction " .. index .. " references a resource that is not a particle archive", context)
    end
    if instruction.resourceKeys ~= nil then
      for _, key in pairs(instruction.resourceKeys) do
        refs[#refs + 1] = key
      end
    end
    for _, key in ipairs(refs) do
      if resources[key] == nil then
        fail(code, "instruction " .. index .. " references an unstaged resource: " .. key, context)
      end
    end
  end
end

-- One closed effect artifact: its semantic key, the catalog generation it
-- was lowered against, one executable program, the closed dependency list,
-- the owned resource descriptors, and the typed context layout. Every
-- instruction is a tagged record; native dispatch identities never
-- validate and context never reaches battle or field objects.
function BattleAnimationSchema.assertEffect(effect)
  local context = {}
  SchemaCheck.checkRecord(effect, {
    schema = true,
    key = true,
    catalogIdentity = true,
    program = true,
    dependencies = true,
    resources = true,
    requiredContext = true,
  }, context, CODE_EFFECT, "effect")
  if effect.schema ~= BattleAnimationSchema.EFFECT_SCHEMA then
    fail(CODE_EFFECT, "effect schema must be " .. BattleAnimationSchema.EFFECT_SCHEMA, context)
  end
  checkString(effect.key, context, CODE_EFFECT, "effect key")
  if effect.key:find("/", 1, true) ~= nil then
    fail(CODE_EFFECT, "effect keys stay flat", context)
  end
  checkString(effect.catalogIdentity, context, CODE_EFFECT, "effect catalogIdentity")
  checkProgram(effect.program, context, CODE_EFFECT, "effect program")
  checkDependencies(effect.dependencies, context, CODE_EFFECT, "effect dependencies")
  checkResources(effect.resources, context, CODE_EFFECT, "effect resources")
  checkProgramResourceClosure(effect.program, effect.dependencies, effect.resources, context, CODE_EFFECT)
  checkRequiredContext(effect.requiredContext, context, CODE_EFFECT, "effect requiredContext")
  local function requiresSpriteContextTable(value)
    if type(value) ~= "table" then
      return false
    end
    if value.op == "invoke-battle-animation-callback" and value.parameters.spriteContextSlot ~= nil then
      return true
    end
    if value.op == "invoke-battle-animation-callback" and value.parameters.oamModeSpriteSlots ~= nil then
      return true
    end
    if
      value.op == "invoke-battle-animation-callback"
      and ANIMATION_CALLBACKS[value.callback] ~= nil
      and ANIMATION_CALLBACKS[value.callback].requiresSpriteContextTable == true
    then
      return true
    end
    for _, nested in pairs(value) do
      if requiresSpriteContextTable(nested) then
        return true
      end
    end
    return false
  end
  local function requiresBattlerTopology(value)
    if type(value) ~= "table" then
      return false
    end
    if value.op == "set-pokemon-picture-vanished" then
      return true
    end
    if value.op == "invoke-battle-animation-callback" and value.parameters.pictureSets ~= nil then
      return true
    end
    if
      value.op == "invoke-battle-animation-callback"
      and ANIMATION_CALLBACKS[value.callback] ~= nil
      and ANIMATION_CALLBACKS[value.callback].requiresBattlerTopology == true
    then
      return true
    end
    for _, nested in pairs(value) do
      if requiresBattlerTopology(nested) then
        return true
      end
    end
    return false
  end
  local function requiresMovePower(value)
    if type(value) ~= "table" then
      return false
    end
    if
      value.op == "invoke-battle-animation-callback"
      and ANIMATION_CALLBACKS[value.callback] ~= nil
      and ANIMATION_CALLBACKS[value.callback].requiresMovePower == true
    then
      return true
    end
    for _, nested in pairs(value) do
      if requiresMovePower(nested) then
        return true
      end
    end
    return false
  end
  if requiresSpriteContextTable(effect.program) and effect.requiredContext.spriteContextTable == nil then
    fail(CODE_EFFECT, "effect requiredContext omitted spriteContextTable", context)
  end
  if requiresBattlerTopology(effect.program) and effect.requiredContext.battlerTopology == nil then
    fail(CODE_EFFECT, "effect requiredContext omitted battlerTopology", context)
  end
  if requiresMovePower(effect.program) and effect.requiredContext.movePower == nil then
    fail(CODE_EFFECT, "effect requiredContext omitted movePower", context)
  end
  checkNoNativeKeys(effect, context, CODE_EFFECT, "effect")
  return true
end

function BattleAnimationSchema.assertProgram(program)
  local context = {}
  checkProgram(program, context, CODE_EFFECT, "program")
  return true
end

function BattleAnimationSchema.isValidEffect(effect)
  return pcall(BattleAnimationSchema.assertEffect, effect)
end

return BattleAnimationSchema
