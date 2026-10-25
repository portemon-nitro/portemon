-- Build-only source labels for the native battle animation interpreter.
-- Dispatch labels follow overlay_07.s::ov07_02234DE8 at the pinned commit;
-- this inventory contains no inferred opcode aliases or runtime identities.

local BattleAnimationSources = {}

BattleAnimationSources.provenance = {
  repo = "pret/pokeheartgold",
  commit = "9d8b7591f09b65804da2fb2dfd56f320633e0d36",
  sources = {
    "asm/overlay_07.s",
    "asm/overlay_01_021EFB38.s",
    "asm/overlay_12_battle_controller.s",
    "src/battle/battle_command.c",
    "src/battle/battle_system.c",
  },
}

BattleAnimationSources.ANIMATION_NARCS = {
  "NARC_a_0_0_7",
  "NARC_a_0_0_8",
  "NARC_a_0_2_2",
  "NARC_a_0_2_3",
  "NARC_a_0_2_4",
  "NARC_a_0_2_5",
}
BattleAnimationSources.LOWER_NARC = "NARC_a_0_0_7"
BattleAnimationSources.SCENE_NARC = "NARC_a_0_0_8"
BattleAnimationSources.TRANSITION_NARC = "NARC_a_1_0_9"
BattleAnimationSources.MOVE_NARC = "NARC_a_0_1_0"
-- Audio banks that hold every sequence a battle animation voices. Effect
-- voices play from the shared audio cache, so the global battle catalog
-- every effect stages on depends on these banks; a voice outside them fails
-- its effect closure.
BattleAnimationSources.EFFECT_SOUND_BANKS = { "BANK_BASIC", "BANK_SE_BATTLE" }
BattleAnimationSources.SUPPORTING_OVERLAYS = { 114, 115, 116, 117, 118, 119, 120 }

-- Named script categories from include/constants/battle_subscript.h. NONE is
-- excluded because it is not an animation request category.
local NON_MOVE_ANIMATION_ROOTS = {
  [1] = "BATTLE_ANIMATION_ASLEEP",
  [2] = "BATTLE_ANIMATION_POISONED",
  [3] = "BATTLE_ANIMATION_BURNED",
  [4] = "BATTLE_ANIMATION_FROZEN",
  [5] = "BATTLE_ANIMATION_PARALYZED",
  [6] = "BATTLE_ANIMATION_CONFUSED",
  [7] = "BATTLE_ANIMATION_INFATUATED",
  [8] = "BATTLE_ANIMATION_LEVEL_UP",
  [9] = "BATTLE_ANIMATION_BAG_ITEM",
  [10] = "BATTLE_ANIMATION_HELD_ITEM",
  [11] = "BATTLE_ANIMATION_SHINY",
  [12] = "BATTLE_ANIMATION_STAT_BOOST",
  [13] = "BATTLE_ANIMATION_STAT_DROP",
  [14] = "BATTLE_ANIMATION_RESTORE_HP",
  [15] = "BATTLE_ANIMATION_SUB_OUT",
  [16] = "BATTLE_ANIMATION_SUB_IN",
  [17] = "BATTLE_ANIMATION_ITEM_ESCAPE",
  [18] = "BATTLE_ANIMATION_WEATHER_FOG",
  [19] = "BATTLE_ANIMATION_WEATHER_RAIN",
  [20] = "BATTLE_ANIMATION_WEATHER_HAIL",
  [21] = "BATTLE_ANIMATION_WEATHER_SAND",
  [22] = "BATTLE_ANIMATION_WEATHER_SUN",
  [25] = "BATTLE_ANIMATION_SUBSTITUTE_IN",
  [26] = "BATTLE_ANIMATION_SUBSTITUTE_OUT",
  [27] = "BATTLE_ANIMATION_HAPPY",
  [28] = "BATTLE_ANIMATION_EATING",
  [29] = "BATTLE_ANIMATION_ANGRY",
  [30] = "BATTLE_ANIMATION_DAMAGE_CURSE",
  [31] = "BATTLE_ANIMATION_DAMAGE_NIGHTMARE",
  [32] = "BATTLE_ANIMATION_DAMAGE_LEECH_SEED",
  [33] = "BATTLE_ANIMATION_DAMAGE_BIND",
  [34] = "BATTLE_ANIMATION_DAMAGE_WRAP",
  [35] = "BATTLE_ANIMATION_DAMAGE_FIRE_SPIN",
  [36] = "BATTLE_ANIMATION_DAMAGE_MAGMA_STORM",
  [37] = "BATTLE_ANIMATION_DAMAGE_CLAMP",
  [38] = "BATTLE_ANIMATION_DAMAGE_WHIRLPOOL",
  [39] = "BATTLE_ANIMATION_DAMAGE_SAND_TOMB",
  [40] = "BATTLE_ANIMATION_DAMAGE_INGRAIN",
}

-- Build-only inputs whose source-selected resources or callbacks are supplied
-- by the presentation producer. Operand positions are one-based in the
-- handler's source-ordered operand vector.
BattleAnimationSources.SOURCE_INPUTS = {
  [45] = { role = "battle-animation-callback", selectorOperand = 1, countOperand = 2, maximumParameters = 10 },
  [21] = {
    role = "battle-background",
    operandCount = 1,
    resourceSlots = { "character", "palette", "screenDefault", "screenAlternate" },
    selectorOperand = 1,
  },
  [46] = { role = "battler-particle-action", operandCount = 3, callbackOperand = 3 },
  [47] = { role = "battler-particle-action", operandCount = 4, callbackOperand = 4 },
  [48] = {
    role = "battler-particle-action",
    operandCount = 8,
    candidateResNoOperands = { 2, 3, 4, 5, 6, 7 },
    callbackOperand = 8,
    contextFields = { "attackerBattlerType", "targetBattlerType" },
  },
  [49] = {
    role = "battler-particle-action",
    operandCount = 6,
    candidateResNoOperands = { 2, 3, 4, 5 },
    callbackOperand = 6,
    contextFields = { "attackerBattlerType", "targetBattlerType" },
  },
  [51] = {
    role = "battler-particle-resource",
    operandCount = 2,
    resourceSlots = { "particle" },
    memberOperand = 2,
    archiveSymbol = "NARC_a_0_2_9",
    decoder = "spl",
    kind = "particle",
  },
  [57] = {
    role = "managed-sprite-resource-set",
    operandCount = 1,
    resourceSlots = { "character", "palette", "cell", "animation" },
  },
  [58] = {
    role = "battler-sprite-resource-set",
    operandCount = 4,
    battlerTargetOperand = 1,
    spriteSlotOperand = 2,
    animationModeOperand = 3,
  },
  [74] = {
    role = "sprite-character",
    operandCount = 2,
    resourceSlots = { "character" },
    memberOperand = 2,
    archiveSymbol = "NARC_a_0_2_2",
    decoder = "char",
    kind = "texture",
  },
  [75] = {
    role = "sprite-palette",
    operandCount = 3,
    resourceSlots = { "palette" },
    memberOperand = 2,
    archiveSymbol = "NARC_a_0_2_3",
    decoder = "palette",
    kind = "palette",
  },
  [76] = {
    role = "sprite-cell",
    operandCount = 2,
    resourceSlots = { "cell" },
    memberOperand = 2,
    archiveSymbol = "NARC_a_0_2_4",
    decoder = "cell",
    kind = "cell",
  },
  [77] = {
    role = "sprite-animation",
    operandCount = 2,
    resourceSlots = { "animation" },
    memberOperand = 2,
    archiveSymbol = "NARC_a_0_2_5",
    decoder = "animation",
    kind = "animation",
  },
  [78] = {
    role = "configured-sprite-action",
    fixedOperandCount = 9,
    resourceSlots = { "character", "palette", "cell", "animation", "multiCell", "multiAnimation" },
    resourceOperands = {
      character = 3,
      palette = 4,
      cell = 5,
      animation = 6,
      multiCell = 7,
      multiAnimation = 8,
    },
    selectorOperand = 2,
    countOperand = 9,
  },
  [79] = {
    role = "managed-sprite-template",
    operandCount = 8,
    resourceSlots = { "character", "palette", "cell", "animation", "multiCell", "multiAnimation" },
    resourceOperands = {
      character = 3,
      palette = 4,
      cell = 5,
      animation = 6,
      multiCell = 7,
      multiAnimation = 8,
    },
    resourceFormats = {
      character = { decoder = "char", kind = "texture" },
      palette = { decoder = "palette", kind = "palette" },
      cell = { decoder = "cell", kind = "cell" },
      animation = { decoder = "animation", kind = "animation" },
      multiCell = { decoder = "multiCell", kind = "multi-cell" },
      multiAnimation = { decoder = "multiCellAnimation", kind = "multi-cell-animation" },
    },
  },
}

local BATTLER_POSITION_INDEX = {
  ["solo-player"] = 0,
  ["solo-enemy"] = 1,
  ["player-side-slot-1"] = 2,
  ["enemy-side-slot-1"] = 3,
  ["player-side-slot-2"] = 4,
  ["enemy-side-slot-2"] = 5,
}

local BATTLER_POSITION_BY_INDEX = {
  [0] = "solo-player",
  [1] = "solo-enemy",
  [2] = "player-side-slot-1",
  [3] = "enemy-side-slot-1",
  [4] = "player-side-slot-2",
  [5] = "enemy-side-slot-2",
}

-- Selector rows are attacker battler types and columns are target battler
-- types, matching ov07_0221CCF4/ov07_0221CD4C and their pinned lookup tables.
-- 0xFF is the source assertion path, not a selectable parameter.
local BATTLER_PARTICLE_CANDIDATES = {
  [48] = {
    { 255, 1, 255, 255, 255, 255 },
    { 4, 255, 255, 255, 255, 255 },
    { 255, 255, 255, 3, 255, 1 },
    { 255, 255, 6, 255, 4, 255 },
    { 255, 255, 255, 1, 255, 2 },
    { 255, 255, 4, 255, 5, 255 },
  },
  [49] = {
    { 255, 255, 255, 255, 255, 255 },
    { 255, 255, 255, 255, 255, 255 },
    { 255, 255, 255, 255, 0, 255 },
    { 255, 255, 255, 255, 255, 1 },
    { 255, 255, 1, 255, 255, 255 },
    { 255, 255, 255, 0, 255, 255 },
  },
}

local PARTICLE_ACTION_PROFILES = {
  [0] = "particle-emitter-default",
  [1] = "particle-emitter-camera-relative",
  [2] = "particle-emitter-world-position",
  [3] = "particle-emitter-active-battler-relative",
  [4] = "particle-emitter-target-battler-relative",
  [5] = "particle-emitter-position-pair-primary-primary",
  [6] = "particle-emitter-position-pair-primary-secondary",
  [7] = "particle-emitter-position-pair-primary-partner",
  [8] = "particle-emitter-position-pair-primary-opponent",
  [9] = "particle-emitter-position-pair-primary-opposing-partner",
  [10] = "particle-emitter-position-pair-primary-active",
  [11] = "particle-emitter-position-pair-secondary-primary",
  [12] = "particle-emitter-position-pair-secondary-secondary",
  [13] = "particle-emitter-position-pair-secondary-partner",
  [14] = "particle-emitter-position-pair-secondary-opponent",
  [15] = "particle-emitter-position-pair-secondary-opposing-partner",
  [16] = "particle-emitter-position-pair-secondary-active",
  [17] = "particle-emitter-battler-class-camera-position",
  [18] = "particle-emitter-randomized-position",
  [19] = "particle-emitter-battler-pair-position",
  [20] = "particle-emitter-battler-pair-orientation",
  [21] = "particle-emitter-active-pair-position",
  [22] = "particle-emitter-default",
}

-- Callback table ov07_0223649C maps to the continuation routines below.
-- Task names describe the continuation's observed sprite/picture effects;
-- the native callback index and function addresses stay in this source catalog.
local CONFIGURED_SPRITE_TASKS = {
  { taskKind = "multi-sprite-position-tick", context = "sprite-system" },
  { taskKind = "sprite-affine-scale-draw-transition", context = "battle-sprite" },
  { taskKind = "sprite-animation-position-transition", context = "battle-sprite" },
  { taskKind = "pokemon-picture-multi-sprite-animation", context = "pokemon-picture" },
  { taskKind = "sprite-affine-rotation-motion", context = "battle-sprite" },
  { taskKind = "pokemon-picture-sprite-position-transition", context = "pokemon-picture" },
  { taskKind = "pokemon-picture-affine-transition", context = "pokemon-picture" },
  { taskKind = "sprite-alpha-transition", context = "pokemon-picture" },
  { taskKind = "pokemon-picture-palette-fade", context = "pokemon-picture" },
  { taskKind = "pokemon-picture-animation-palette-fade", context = "pokemon-picture" },
  { taskKind = "pokemon-picture-relative-sprite-path-transition", context = "pokemon-picture" },
  { taskKind = "sprite-brightness-transition", context = "battle-display" },
  { taskKind = "pokemon-picture-animation", context = "pokemon-picture" },
  { taskKind = "pokemon-picture-animation-speed-transition", context = "pokemon-picture" },
  { taskKind = "sprite-affine-animation", context = "pokemon-picture" },
  { taskKind = "pokemon-picture-oam-animation-transition", context = "pokemon-picture" },
  { taskKind = "pokemon-picture-animation-position-transition", context = "pokemon-picture" },
  { taskKind = "sprite-affine-rotation-transition", context = "battle-sprite" },
  { taskKind = "sprite-animation-completion", context = "battle-sprite" },
  { taskKind = "sprite-animation-affine-scale-transition", context = "battle-sprite" },
  { taskKind = "sprite-flip-animation-transition", context = "battle-sprite" },
  { taskKind = "sprite-randomized-affine-motion", context = "battle-sprite" },
  { taskKind = "sprite-flip-and-offset-transition", context = "battle-sprite" },
  { taskKind = "pokemon-picture-randomized-position-motion", context = "pokemon-picture" },
  { taskKind = "pokemon-picture-priority-motion", context = "pokemon-picture" },
  { taskKind = "sprite-position-offset", context = "battle-sprite" },
  { taskKind = "sprite-affine-transform-motion", context = "battle-sprite" },
  { taskKind = "sprite-animation-lifecycle", context = "battle-sprite" },
  { taskKind = "sprite-affine-animation-lifecycle", context = "battle-sprite" },
  { taskKind = "multi-sprite-battler-animation", context = "pokemon-picture" },
  { taskKind = "multi-sprite-position-transition", context = "battle-sprite" },
  { taskKind = "sprite-animation-palette-offset", context = "battle-palette" },
  { taskKind = "multi-sprite-picture-animation", context = "pokemon-picture" },
}

local CONFIGURED_SPRITE_PARAMETERS = {
  [1] = { { name = "spriteCount", index = 1, encoding = "signed32" } },
  [3] = { { name = "spriteCount", index = 1, encoding = "signed32" } },
  [17] = {
    { name = "spriteSpacingX", index = 1, encoding = "signed16" },
    { name = "spriteSpacingY", index = 2, encoding = "signed16" },
    { name = "positionTransitionTicks", index = 3, encoding = "unsigned16" },
    { name = "rotationAngle", index = 4, encoding = "unsigned32" },
  },
  [19] = { { name = "spriteCount", index = 1, encoding = "unsigned8" } },
  [20] = { { name = "spriteCount", index = 1, encoding = "unsigned8" } },
  [25] = {
    { name = "offsetX", index = 1, encoding = "signed16" },
    { name = "offsetY", index = 2, encoding = "signed16" },
  },
}

BattleAnimationSources.CONFIGURED_SPRITE_TASK_COUNT = #CONFIGURED_SPRITE_TASKS

-- Build-only member rows from overlay_07.s::ov07_02234F48. Each row is
-- {character, palette, screen-default, screen-alternate, auxiliary}; the
-- runtime-selected screen column is chosen by ov07_0221DDB0.
BattleAnimationSources.BACKGROUND_MEMBER_ROWS = {
  { 59, 295, 56, 57, 58 },
  { 59, 295, 56, 57, 58 },
  { 119, 319, 120, 120, 120 },
  { 59, 295, 56, 57, 58 },
  { 59, 295, 56, 57, 58 },
  { 59, 330, 56, 57, 58 },
  { 63, 296, 60, 61, 62 },
  { 142, 334, 143, 144, 143 },
  { 63, 337, 60, 61, 62 },
  { 64, 297, 65, 65, 65 },
  { 64, 297, 65, 65, 65 },
  { 119, 320, 120, 120, 120 },
  { 64, 329, 65, 65, 65 },
  { 64, 336, 65, 65, 65 },
  { 119, 318, 120, 120, 120 },
  { 70, 300, 66, 66, 66 },
  { 70, 308, 66, 66, 66 },
  { 119, 317, 120, 120, 120 },
  { 70, 308, 66, 66, 66 },
  { 75, 301, 76, 76, 74 },
  { 83, 303, 80, 81, 82 },
  { 89, 305, 86, 87, 88 },
  { 93, 306, 90, 91, 92 },
  { 94, 307, 95, 95, 95 },
  { 99, 310, 100, 100, 100 },
  { 102, 311, 103, 103, 101 },
  { 108, 312, 107, 107, 107 },
  { 108, 348, 107, 107, 107 },
  { 109, 313, 110, 110, 110 },
  { 111, 314, 112, 112, 112 },
  { 109, 313, 110, 110, 110 },
  { 118, 316, 115, 116, 117 },
  { 118, 316, 115, 116, 117 },
  { 118, 316, 115, 116, 117 },
  { 125, 324, 126, 126, 126 },
  { 130, 326, 131, 131, 129 },
  { 132, 327, 133, 133, 134 },
  { 139, 332, 137, 138, 138 },
  { 140, 333, 141, 141, 141 },
  { 145, 335, 146, 146, 146 },
  { 150, 338, 147, 148, 149 },
  { 154, 339, 151, 152, 153 },
  { 155, 340, 156, 156, 156 },
  { 157, 341, 158, 158, 158 },
  { 159, 342, 160, 160, 160 },
  { 164, 343, 161, 162, 163 },
  { 165, 344, 166, 166, 166 },
  { 46, 290, 47, 47, 47 },
  { 167, 345, 168, 169, 168 },
  { 167, 347, 168, 169, 168 },
  { 170, 346, 172, 171, 171 },
  { 72, 299, 73, 73, 73 },
  { 84, 304, 85, 85, 85 },
  { 79, 302, 77, 78, 77 },
  { 113, 315, 114, 114, 114 },
  { 123, 323, 124, 124, 124 },
  { 121, 322, 122, 122, 122 },
  { 135, 331, 136, 136, 136 },
  { 98, 309, 96, 97, 96 },
}

BattleAnimationSources.BATTLER_PICTURE_TARGETS = {
  [0] = "active-position-first",
  [1] = "active-position-second",
  [2] = "first-battler-for-active-position-first",
  [3] = "first-battler-for-active-position-second",
  [4] = "first-battler-state-zero-or-two",
  [5] = "first-battler-state-one-or-three",
  [6] = "first-battler-state-four",
  [7] = "first-battler-state-five",
}

-- Native SPL members with a source-resolved semantic identity.
BattleAnimationSources.PARTICLE_RESOURCES = {
  [64] = "battle/particle/tackle",
  [27] = "battle/particle/asleep",
  [79] = "battle/particle/supersonic",
}

-- Build-only archive routes for semantic particle identities. These physical
-- member selectors are consumed by the presentation producer and never enter
-- normalized animation IR.
BattleAnimationSources.PARTICLE_SOURCE_INPUTS = {
  ["battle/particle/tackle"] = {
    archiveSymbol = "NARC_a_0_2_9",
    memberId = 64,
    decoder = "spl",
    kind = "particle",
  },
  ["battle/particle/asleep"] = {
    archiveSymbol = "NARC_a_0_2_9",
    memberId = 27,
    decoder = "spl",
    kind = "particle",
  },
  ["battle/particle/supersonic"] = {
    archiveSymbol = "NARC_a_0_2_9",
    memberId = 79,
    decoder = "spl",
    kind = "particle",
  },
}

BattleAnimationSources.VISUAL_TASK_KINDS = {
  [0] = "battle-background-blend-transition",
  [1] = "battle-palette-fade",
  [2] = "battle-presentation-state-reset",
  [3] = "battle-background-position-transition",
  [4] = "battle-background-resource-load",
  [5] = "battle-presentation-resource-cleanup",
}

BattleAnimationSources.VISUAL_UPDATE_KINDS = {
  [0] = "no-axis-change",
  [1] = "increase-x",
  [2] = "decrease-x",
  [3] = "increase-y",
  [4] = "decrease-y",
  [5] = "increase-x-and-y",
  [6] = "decrease-x-and-y",
}

BattleAnimationSources.SIDE_MASK_BRANCHES = { 3, 12, 48, 192 }

BattleAnimationSources.SPRITE_EFFECT_MODES = {
  [0] = "first-battler-class-priority-gate",
  [1] = "second-battler-class-priority-forward",
  [2] = "first-battler-class-priority-alternate",
  [3] = "second-battler-class-priority-reverse",
}

BattleAnimationSources.HANDLER_LABELS = {
  "ov07_0221C6EC",
  "ov07_0221C70C",
  "ov07_0221C934",
  "ov07_0221C974",
  "ov07_0221C9C0",
  "ov07_0221F098",
  "ov07_0221D5A8",
  "ov07_0221D5AC",
  "ov07_0221F3F4",
  "ov07_0221F424",
  "ov07_0221D02C",
  "ov07_0221D05C",
  "ov07_0221C72C",
  "ov07_0221D148",
  "ov07_0221D2B0",
  "ov07_0221D2E4",
  "ov07_0221ED44",
  "ov07_0221EE74",
  "ov07_0221EEC0",
  "ov07_0221EF14",
  "ov07_0221EF34",
  "ov07_0221EF54",
  "ov07_0221F0CC",
  "ov07_0221F104",
  "ov07_0221F120",
  "ov07_0221F2DC",
  "ov07_0221F340",
  "ov07_0221F42C",
  "ov07_0221F398",
  "ov07_0221F39C",
  "ov07_0221D088",
  "ov07_0221D5B0",
  "ov07_0221D718",
  "ov07_0221D0C0",
  "ov07_0221F024",
  "ov07_0221F1C0",
  "ov07_0221F238",
  "ov07_0221F084",
  "ov07_0221F088",
  "ov07_0221F08C",
  "ov07_0221DD0C",
  "ov07_0221DD10",
  "ov07_0221F090",
  "ov07_0221F094",
  "ov07_0221F0B0",
  "ov07_0221D0E8",
  "ov07_0221CBC0",
  "ov07_0221CC54",
  "ov07_0221CDA4",
  "ov07_0221CE5C",
  "ov07_0221CF14",
  "ov07_0221CF54",
  "ov07_0221CFA8",
  "ov07_0221D000",
  "ov07_0221F8AC",
  "ov07_0221F814",
  "ov07_0221D740",
  "ov07_0221D7B8",
  "ov07_0221D874",
  "ov07_0221DA74",
  "ov07_0221DAA0",
  "ov07_0221DCC0",
  "ov07_0221DCD4",
  "ov07_0221DCF0",
  "ov07_0221D174",
  "ov07_0221F81C",
  "ov07_0221F880",
  "ov07_0221C74C",
  "ov07_0221C8CC",
  "ov07_0221C910",
  "ov07_0221D1B8",
  "ov07_0221D214",
  "ov07_0221D270",
  "ov07_0221F430",
  "ov07_0221F4CC",
  "ov07_0221F514",
  "ov07_0221F574",
  "ov07_0221F5BC",
  "ov07_0221F604",
  "ov07_0221F710",
  "ov07_0221F7C4",
  "ov07_0221F7F0",
  "ov07_0221DAF4",
  "ov07_0221DCA8",
  "ov07_0221C6B4",
  "ov07_0221D374",
  "ov07_0221ED94",
  "ov07_0221D23C",
}

BattleAnimationSources.DISPATCH_EXTENT_BYTES = 0x160
BattleAnimationSources.DISPATCH_ENTRIES = 88

---@param opcode integer
---@return string|nil pinned handler label
function BattleAnimationSources.handlerLabel(opcode)
  return BattleAnimationSources.HANDLER_LABELS[opcode + 1]
end

---@param opcode integer
---@return table<string, unknown>|nil source resolver role and operand schema
function BattleAnimationSources.sourceInput(opcode)
  return BattleAnimationSources.SOURCE_INPUTS[opcode]
end

---@param selector integer source-only callback selector
---@param parameterWords? integer[] copied callback context words
---@return { taskKind: string, context: string, parameters: table<string, integer> }|nil semantic configured-sprite task
---@return string|nil unresolved selector reason
function BattleAnimationSources.resolveConfiguredSpriteAction(selector, parameterWords)
  if type(selector) ~= "number" or selector % 1 ~= 0 or selector < 0 then
    return nil, "configured sprite callback selector is invalid"
  end
  local task = CONFIGURED_SPRITE_TASKS[selector + 1]
  if task == nil then
    return nil, "configured sprite callback selector is outside the pinned table"
  end
  local parameters = {}
  for _, field in ipairs(CONFIGURED_SPRITE_PARAMETERS[selector] or {}) do
    local value = parameterWords and parameterWords[field.index] or 0
    if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > 0xFFFFFFFF then
      return nil, "configured sprite parameter word is invalid"
    end
    if field.encoding == "signed16" then
      value = value % 0x10000
      if value >= 0x8000 then
        value = value - 0x10000
      end
    elseif field.encoding == "unsigned16" then
      value = value % 0x10000
    elseif field.encoding == "unsigned8" then
      value = value % 0x100
    elseif field.encoding == "signed32" and value >= 0x80000000 then
      value = value - 0x100000000
    end
    parameters[field.name] = value
  end
  return { taskKind = task.taskKind, context = task.context, parameters = parameters }
end

---@return integer pinned configured sprite callback count
function BattleAnimationSources.configuredSpriteCallbackCount()
  return #CONFIGURED_SPRITE_TASKS
end

local function signed16(value)
  value = value % 0x10000
  return value >= 0x8000 and value - 0x10000 or value
end

local function signed32(value)
  return value >= 0x80000000 and value - 0x100000000 or value
end

local function signed8(value)
  value = value % 0x100
  return value >= 0x80 and value - 0x100 or value
end

-- Native battler-role flags behind the linear-slide and position-reset
-- selectors (battle_anim_funcs.c: the attacker/defender role switch):
-- only these four name a picture target, anything else asserts natively.
local function linearRoleTargets(role)
  local targets = {
    [2] = "attacker",
    [4] = "attacker-related-position-when-paired",
    [8] = "target",
    [16] = "target-related-position-when-paired",
  }
  return targets[role]
end

---@param operands integer[] selector, declared count, then source callback words
---@return table<string, unknown>|nil semantic callback plan
---@return string|nil unresolved selection reason
function BattleAnimationSources.resolveBattleAnimationCallback(operands)
  if type(operands) ~= "table" or #operands < 2 then
    return nil, "battle animation callback frame is truncated"
  end
  local selector = operands[1]
  local count = operands[2]
  if type(count) ~= "number" or count % 1 ~= 0 or count < 0 or count > 10 or #operands ~= count + 2 then
    return nil, "battle animation callback parameter count is invalid"
  end
  if selector == 6 then
    return {
      callback = "pokemon-picture-five-phase-affine-size-transition",
      taskKind = "pokemon-picture-five-phase-affine-size-transition",
      context = "pokemon-picture",
      battlerTarget = "attacker",
      parameters = {},
    }
  end
  if selector == 28 then
    -- The source reads the u16 animation context value populated from movePower.
    return {
      callback = "battle-background-four-picture-move-power-transition",
      taskKind = "battle-background-four-picture-move-power-transition",
      context = "battle-display",
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
  end
  if selector == 41 then
    return {
      callback = "battle-display-window-palette-transition",
      taskKind = "battle-display-window-palette-transition",
      context = "battle-display",
      parameters = {},
    }
  end
  if selector == 51 then
    local pictureTargets = {
      [258] = "active-battler",
      [260] = "active-battler-pair-when-enabled",
      [264] = "opposing-battler",
      [272] = "opposing-battler-pair-when-enabled",
    }
    local pictureTarget = pictureTargets[operands[5] or 0]
    if pictureTarget == nil then
      return nil, "selected horizontal picture offset follows its source assertion path"
    end
    return {
      callback = "pokemon-picture-selected-horizontal-offset-transition",
      taskKind = "pokemon-picture-selected-horizontal-offset-transition",
      context = "pokemon-picture",
      parameters = {
        pictureTarget = pictureTarget,
        durationTicks = (operands[3] or 0) % 0x10000,
        signedOffset = signed16(operands[4] or 0),
      },
    }
  end
  if selector == 36 then
    local flags = operands[7]
    if count ~= 5 then
      return nil, "background transition callback requires five source operands"
    end
    local positionMask = flags % 0x80
    local pictureSets = {}
    if positionMask % 0x80 >= 0x40 then
      pictureSets[1] = "all-battler-positions"
    elseif positionMask % 0x40 >= 0x20 then
      pictureSets[1] = "other-battler-positions"
    else
      if positionMask % 0x04 >= 0x02 then
        pictureSets[#pictureSets + 1] = "active-battler"
      end
      if positionMask % 0x08 >= 0x04 then
        pictureSets[#pictureSets + 1] = "active-battler-pair-when-enabled"
      end
      if positionMask % 0x10 >= 0x08 then
        pictureSets[#pictureSets + 1] = "opposing-battler"
      end
      if positionMask % 0x20 >= 0x10 then
        pictureSets[#pictureSets + 1] = "opposing-battler-pair-when-enabled"
      end
    end
    return {
      callback = "battle-background-position-transition",
      taskKind = "battle-background-blend-transition",
      context = "battle-display",
      parameters = {
        offsetX = signed16(operands[3]),
        offsetY = signed16(operands[4]),
        ticksPerStep = signed16(operands[5]),
        steps = signed16(operands[6]),
        pictureSets = pictureSets,
        pictureAttributeOffset = flags % 0x200 >= 0x100,
        managedSpriteOffset = flags % 0x400 >= 0x200,
        backgroundPositionEnabled = flags % 0x800 >= 0x400,
      },
    }
  elseif selector == 37 then
    return {
      callback = "pokemon-picture-target-background-slide",
      taskKind = "pokemon-picture-target-background-slide",
      context = "battle-display",
      battlerTarget = "target",
      parameters = {},
    }
  elseif selector == 38 then
    local spriteSlots = {}
    local spriteMask = operands[3] or 0
    for slot = 0, 3 do
      if math.floor(spriteMask / (2 ^ slot)) % 2 == 1 then
        spriteSlots[#spriteSlots + 1] = "sprite-context-slot-" .. slot
      end
    end
    return {
      callback = "battle-sprite-blend-alpha-transition",
      taskKind = "battle-sprite-blend-alpha-transition",
      context = "battle-display",
      parameters = {
        oamModeSpriteSlots = spriteSlots,
        startCoefficientA = signed16(operands[4] or 0),
        targetCoefficientA = signed32(operands[5] or 0),
        startCoefficientB = signed16(operands[6] or 0),
        targetCoefficientB = signed32(operands[8] or 0),
        durationTicks = signed16(operands[7] or 0),
      },
    }
  elseif selector == 71 then
    local mask = operands[3] or 0
    local pictureSets = {}
    if mask % 0x80 >= 0x40 then
      pictureSets[1] = "all-battler-positions"
    elseif mask % 0x40 >= 0x20 then
      pictureSets[1] = "other-battler-positions"
    else
      if mask % 0x04 >= 0x02 then
        pictureSets[#pictureSets + 1] = "active-battler"
      end
      if mask % 0x08 >= 0x04 then
        pictureSets[#pictureSets + 1] = "active-battler-pair-when-enabled"
      end
      if mask % 0x10 >= 0x08 then
        pictureSets[#pictureSets + 1] = "opposing-battler"
      end
      if mask % 0x20 >= 0x10 then
        pictureSets[#pictureSets + 1] = "opposing-battler-pair-when-enabled"
      end
    end
    return {
      callback = "pokemon-picture-selected-pair-transition",
      taskKind = "pokemon-picture-selected-pair-transition",
      context = "pokemon-picture",
      parameters = { pictureSets = pictureSets },
    }
  elseif selector == 74 then
    -- The interpreter's +8 palette-mode field is initialized to zero and has no writer.
    -- The source's nonzero field branches therefore cannot narrow this to 48 entries.
    if (operands[3] or 0) == 0 then
      return { op = "copy-main-background-palette-to-fade-buffer" }
    end
    return { op = "grayscale-main-background-fade-buffer" }
  elseif selector == 70 then
    return {
      callback = "pokemon-picture-affine-blend-palette-transition",
      taskKind = "pokemon-picture-affine-blend-palette-transition",
      context = "battle-display",
      parameters = {},
    }
  elseif selector == 34 then
    if count < 5 or count > 6 then
      return nil, "picture palette pulse callback requires five or six source operands"
    end
    local pictureTargets = {
      [2] = "attacker",
      [4] = "attacker-related-position-when-paired",
      [8] = "target",
      [16] = "target-related-position-when-paired",
      [0x802] = "first-battler-state-zero-or-two",
      [0x804] = "first-battler-state-four",
      [0x808] = "first-battler-state-one-or-three",
      [0x810] = "first-battler-state-five",
    }
    local battlerTarget = pictureTargets[operands[3]]
    if battlerTarget == nil then
      return nil, "picture palette pulse callback follows its source assertion path"
    end
    return {
      callback = "pokemon-picture-repeated-palette-fade",
      taskKind = "pokemon-picture-repeated-palette-fade",
      context = "pokemon-picture",
      parameters = {
        pictureTarget = battlerTarget,
        framesPerStep = operands[4],
        repeatCount = math.max(1, signed32(operands[5])),
        targetColor = signed32(operands[6]),
        fadeExtent = operands[7],
        pauseTicks = operands[8] or 0,
      },
    }
  elseif selector == 35 then
    if count < 8 then
      return nil, "managed sprite scale pulse requires eight source operands"
    end
    local spriteContextSlot = operands[10]
    if spriteContextSlot > 4 then
      return nil, "managed sprite scale pulse sprite context slot is outside the source table"
    end
    local battlerTarget = operands[3] == 0 and "attacker" or "target"
    local packedDurations = operands[9]
    return {
      callback = "pokemon-picture-managed-sprite-scale-pulse-" .. battlerTarget,
      taskKind = "pokemon-picture-managed-sprite-scale-pulse",
      context = "battle-sprite",
      battlerTarget = battlerTarget,
      parameters = {
        spriteContextSlot = spriteContextSlot,
        blendCoefficient = operands[4],
        scaleStart = signed16(operands[5]),
        scaleDivisor = signed16(operands[7]),
        scaleEnd = signed16(operands[6]),
        repeatCount = operands[8],
        firstDurationTicks = signed16(math.floor(packedDurations / 0x10000)),
        returnDurationTicks = packedDurations % 0x10000,
      },
    }
  elseif selector == 77 then
    if count < 3 then
      return nil, "selected picture position transition requires three source operands"
    end
    local pictureTargets = {
      [2] = "attacker",
      [4] = "attacker-related-position-when-paired",
      [8] = "target",
      [16] = "target-related-position-when-paired",
    }
    local pictureTarget = pictureTargets[operands[4]]
    if pictureTarget == nil then
      return nil, "selected picture position transition follows its source assertion path"
    end
    return {
      callback = "pokemon-picture-selected-position-transition",
      taskKind = "pokemon-picture-selected-position-transition",
      context = "pokemon-picture",
      parameters = {
        pictureTarget = pictureTarget,
        positionBasis = operands[3] == 0 and "battle-position-anchors" or "selected-picture-origin",
        durationTicks = operands[5] % 0x10000,
      },
    }
  elseif selector == 68 then
    if count < 5 then
      return nil, "alternating background scroll requires five source operands"
    end
    return {
      callback = "battle-background-alternating-scroll-transition",
      taskKind = "battle-background-alternating-scroll-transition",
      context = "battle-display",
      parameters = {
        horizontalOffset = signed16(operands[3]),
        verticalOffset = signed16(operands[4]),
        ticksPerDirection = operands[5],
        directionChanges = operands[6],
        phaseIntervalTicks = operands[7],
        backgroundLayer = (operands[8] or 0) == 0 and "battle-background-layer-3" or "battle-background-layer-2",
      },
    }
  elseif selector == 76 then
    if count ~= 1 then
      return nil, "background scanline sine-wave callback requires one duration operand"
    end
    return {
      callback = "battle-background-scanline-sine-wave-transition",
      taskKind = "battle-background-scanline-sine-wave-transition",
      context = "battle-display",
      parameters = {
        backgroundLayer = "battle-background-layer-3",
        durationTicks = operands[3],
      },
    }
  elseif selector == 75 then
    local spriteContextSlot = operands[3] or 0
    if spriteContextSlot >= 5 then
      return nil, "battle sprite appearance context slot is outside the source table"
    end
    local spritePriorityByOperand = {
      [0] = "front",
      [1] = "middle",
      [2] = "back",
      [3] = "middle",
      [0xFF] = "unchanged",
    }
    local spritePriority = spritePriorityByOperand[operands[5] or 0]
    if spritePriority == nil then
      return nil, "battle sprite appearance priority follows an unsupported source path"
    end
    local battlerPriorityProfiles = {
      [0] = { battler = "attacker", pattern = "standard" },
      [1] = { battler = "target", pattern = "standard" },
      [2] = { battler = "attacker", pattern = "reversed" },
      [3] = { battler = "target", pattern = "reversed" },
    }
    local battlerPriority = (operands[6] or 0) ~= 0xFF and battlerPriorityProfiles[operands[7] or 0] or nil
    return {
      callback = "battle-sprite-priority-appearance-transition",
      taskKind = "battle-sprite-priority-appearance-transition",
      context = "battle-display",
      parameters = {
        spriteContextSlot = spriteContextSlot,
        durationTicks = operands[4] or 0,
        spritePriority = spritePriority,
        baseDrawPriorityEnabled = (operands[6] or 0) ~= 0xFF,
        baseDrawPriority = (operands[6] or 0) == 0xFF and 0 or (operands[6] or 0),
        drawPriorityBattler = battlerPriority and battlerPriority.battler or "none",
        drawPriorityPattern = battlerPriority and battlerPriority.pattern or "unchanged",
        hideWhenNotDoubleBattle = operands[7] == 2 or operands[7] == 3,
        appearanceMotionEnabled = (operands[8] or 0) ~= 0,
        appearanceBlendProfile = (operands[9] or 0) == 0 and "primary" or "alternate",
      },
    }
  elseif selector == 42 then
    local pictureTargetBySourceState = {
      [0x102] = "attacker",
      [0x104] = "attacker",
      [0x108] = "target",
      [0x110] = "target",
      [0x800] = "first-battler-state-zero-or-two",
      [0x802] = "first-battler-state-four",
      [0x808] = "first-battler-state-one-or-three",
      [0x810] = "first-battler-state-five",
    }
    local pictureTarget = pictureTargetBySourceState[operands[3] or 0]
    if pictureTarget == nil then
      return { op = "noop" }
    end
    local packedCycles = operands[9] or 0
    local packedDurations = operands[10] or 0
    local interpolationDivisor = signed16(operands[8] or 0)
    if interpolationDivisor == 0 then
      return nil, "cyclic picture position callback interpolation divisor is zero"
    end
    return {
      callback = "pokemon-picture-cyclic-two-phase-position-transition",
      taskKind = "pokemon-picture-cyclic-two-phase-position-transition",
      context = "pokemon-picture",
      parameters = {
        pictureTarget = pictureTarget,
        startX = signed32(operands[4] or 0),
        endX = signed32(operands[5] or 0),
        startY = signed32(operands[6] or 0),
        endY = signed32(operands[7] or 0),
        interpolationDivisor = interpolationDivisor,
        additionalCycles = packedCycles % 0x10000,
        repeatDelayTicks = signed16(math.floor(packedCycles / 0x10000)),
        firstDurationTicks = signed16(math.floor(packedDurations / 0x10000)),
        returnDurationTicks = packedDurations % 0x10000,
      },
    }
  elseif selector == 44 or selector == 45 then
    if count < 7 then
      return nil, "battle background callback requires its palette destination operand"
    end
    local rowIndex = operands[3] or 0
    local row = BattleAnimationSources.BACKGROUND_MEMBER_ROWS[rowIndex + 1]
    if row == nil then
      return nil, "battle background callback selector is outside the pinned table"
    end
    local taskKind = selector == 44 and "battle-background-alpha-scroll-transition"
      or "battle-background-sprite-slide-transition"
    local callback = selector == 44 and "battle-background-alpha-scroll-transition"
      or "battle-background-sprite-slide-transition"
    return {
      callback = callback,
      taskKind = taskKind,
      context = "battle-display",
      runtimeSelection = "battle-background-three-way-screen-selection",
      parameters = {
        backgroundLayer = "battle-background-layer-2",
        initialScrollX = signed16(operands[4] or 0),
        initialScrollY = signed16(operands[5] or 0),
        horizontalStep = signed16(operands[6] or 0),
        verticalStep = signed16(operands[7] or 0),
        pairedPositionTransformEnabled = (operands[8] or 0) ~= 0,
        paletteTarget = "battle-animation-palette-target",
        durationTicks = signed16(operands[10] or 0),
      },
      sourceSelections = {
        character = {
          archiveSymbol = BattleAnimationSources.LOWER_NARC,
          memberId = row[1],
          decoder = "char",
          kind = "texture",
        },
        palette = {
          archiveSymbol = BattleAnimationSources.LOWER_NARC,
          memberId = row[2],
          decoder = "palette",
          kind = "palette",
        },
        screenDefault = {
          archiveSymbol = BattleAnimationSources.LOWER_NARC,
          memberId = row[3],
          decoder = "screen",
          kind = "map",
        },
        screenBattlerClassFour = {
          archiveSymbol = BattleAnimationSources.LOWER_NARC,
          memberId = row[4],
          decoder = "screen",
          kind = "map",
        },
        screenContextFlag = {
          archiveSymbol = BattleAnimationSources.LOWER_NARC,
          memberId = row[5],
          decoder = "screen",
          kind = "map",
        },
      },
    }
  elseif selector == 33 then
    if count ~= 5 then
      return nil, "palette fade callback requires five source operands"
    end
    local paletteTargets = {
      [0] = "battle-animation-palette-target",
      [1] = "main-extra-background-0",
      [2] = "main-extra-background-1",
    }
    local paletteTarget = paletteTargets[operands[3]]
    if paletteTarget == nil then
      return nil, "palette fade callback follows its source assertion path"
    end
    return {
      callback = "pokemon-picture-and-battle-palette-fade",
      taskKind = "pokemon-picture-and-battle-palette-fade",
      context = "battle-palette",
      parameters = {
        paletteTarget = paletteTarget,
        wait = signed8(operands[4]),
        startCoefficient = operands[5] % 0x100,
        endCoefficient = operands[6] % 0x100,
        nextColor = operands[7] % 0x10000,
      },
    }
  elseif selector == 40 then
    if count ~= 2 then
      return nil, "vanished picture callback requires its two source operands"
    end
    local mask = operands[3]
    local pictureSets = {}
    if mask % 0x80 >= 0x40 then
      pictureSets[1] = "all-battler-positions"
    elseif mask % 0x40 >= 0x20 then
      pictureSets[1] = "other-battler-positions"
    else
      if mask % 0x04 >= 0x02 then
        pictureSets[#pictureSets + 1] = "active-battler"
      end
      if mask % 0x08 >= 0x04 then
        pictureSets[#pictureSets + 1] = "active-battler-pair-when-enabled"
      end
      if mask % 0x10 >= 0x08 then
        pictureSets[#pictureSets + 1] = "opposing-battler"
      end
      if mask % 0x20 >= 0x10 then
        pictureSets[#pictureSets + 1] = "opposing-battler-pair-when-enabled"
      end
    end
    return {
      op = "set-pokemon-picture-vanished",
      pictureSets = pictureSets,
      vanished = operands[4] ~= 0,
    }
  elseif selector == 65 then
    local spriteContextSlot = operands[3] or 0
    if spriteContextSlot > 70 then
      return nil, "particle emitter path callback has an invalid sprite-context slot"
    end
    local pairOrders = {
      [0] = "attacker-target",
      [1] = "target-attacker",
    }
    local pairOrder = pairOrders[operands[9] or 0]
    if pairOrder == nil then
      return nil, "particle emitter path callback has an invalid battler pair order"
    end
    local packedProgress = operands[10] or 0
    local completionLimit = packedProgress % 0x10000
    if completionLimit == 0 then
      completionLimit = 0xFF
    end
    return {
      callback = "battle-particle-emitter-battler-path",
      taskKind = "battle-particle-emitter-battler-path",
      context = "battle-particle-emitter",
      parameters = {
        spriteContextSlot = spriteContextSlot,
        offsetX = signed16(operands[4]),
        offsetY = signed16(operands[5]),
        leadingInterpolationSteps = signed16(operands[6]),
        sinePeriodDivisor = signed16(operands[7]),
        interpolationDurationTicks = (operands[8] or 0) % 0x10000,
        pairOrder = pairOrder,
        initialInterpolationSteps = math.floor(packedProgress / 0x10000),
        completionLimit = completionLimit,
        sinusoidalOffset = (operands[11] or 0) ~= 0,
      },
    }
  elseif selector == 66 then
    local emitterContextSlot = operands[3] or 0
    if emitterContextSlot > 9 then
      return nil, "particle emitter curved path context slot is outside the source table"
    end
    local battlerOrderByOperand = {
      [0] = "attacker-target",
      [1] = "target-attacker",
    }
    local battlerOrder = battlerOrderByOperand[operands[9] or 0]
    if battlerOrder == nil then
      return nil, "particle emitter curved path has an invalid battler order"
    end
    local packedProgress = operands[10] or 0
    local completionLimit = packedProgress % 0x10000
    if completionLimit == 0 then
      completionLimit = 0xFF
    end
    return {
      callback = "battle-particle-emitter-curved-battler-path",
      taskKind = "battle-particle-emitter-curved-battler-path",
      context = "battle-particle-emitter",
      parameters = {
        emitterContextSlot = emitterContextSlot,
        horizontalOffset = signed16(operands[4] or 0),
        verticalOffset = signed16(operands[5] or 0),
        durationTicks = signed16(operands[6] or 0),
        curveControl = signed16(operands[7] or 0),
        curveScale = signed32(operands[8] or 0),
        battlerOrder = battlerOrder,
        initialInterpolationSteps = math.floor(packedProgress / 0x10000),
        completionLimit = completionLimit,
        sinusoidalOffset = (operands[11] or 0) ~= 0,
      },
    }
  elseif selector == 67 then
    local pictureTargets = {
      [2] = "active-battler",
      [4] = "active-battler-pair-when-enabled",
      [8] = "opposing-battler",
      [16] = "opposing-battler-pair-when-enabled",
    }
    local pictureTarget = pictureTargets[operands[3] or 0]
    if pictureTarget == nil then
      return nil, "selected picture vertical offset follows its source assertion path"
    end
    return {
      callback = "pokemon-picture-vertical-offset-visibility-transition",
      taskKind = "pokemon-picture-vertical-offset-visibility-transition",
      context = "pokemon-picture",
      parameters = {
        pictureTarget = pictureTarget,
        offsetStep = signed16(operands[6] or 0),
        ticksPerStep = operands[7] or 0,
        applyVisibilityOffset = (operands[8] or 0) ~= 0,
      },
    }
  elseif selector == 57 then
    if count ~= 4 then
      return nil, "Pokepic offset transition requires four source operands"
    end
    local pictureTargets = {
      [258] = "active-battler",
      [260] = "active-battler-pair-when-enabled",
      [264] = "opposing-battler",
      [276] = "opposing-battler-pair-when-enabled",
    }
    local pictureTarget = pictureTargets[operands[6]]
    if pictureTarget == nil then
      return nil, "Pokepic offset transition follows its source assertion path"
    end
    return {
      callback = "pokemon-picture-offset-transition",
      taskKind = "pokemon-picture-position-offset-transition",
      context = "pokemon-picture",
      parameters = {
        pictureTarget = pictureTarget,
        durationTicks = signed16(operands[3]),
        offsetX = signed16(operands[4]),
        offsetY = signed16(operands[5]),
      },
    }
  elseif selector == 60 then
    if count ~= 3 then
      return nil, "picture position-path callback requires three source operands"
    end
    local positionPath = operands[3] % 0x80 >= 0x40 and "all-battler-positions"
      or operands[3] % 0x40 >= 0x20 and "active-and-related-pair"
      or "selected-position-anchors"
    local selectedAnchors = positionPath == "selected-position-anchors"
    return {
      callback = "pokemon-picture-position-path-transition",
      taskKind = "pokemon-picture-position-path-transition",
      context = "pokemon-picture",
      parameters = {
        positionPath = positionPath,
        attackerAnchor = selectedAnchors and operands[3] % 4 >= 2 or false,
        attackerRelatedAnchor = selectedAnchors and operands[3] % 8 >= 4 or false,
        targetAnchor = selectedAnchors and operands[3] % 16 >= 8 or false,
        targetRelatedAnchor = selectedAnchors and operands[3] % 32 >= 16 or false,
        stepMultiplier = operands[4],
        durationTicks = operands[5],
      },
    }
  elseif selector == 78 then
    if count ~= 1 then
      return nil, "managed sprite frame-loop parameter shape is invalid"
    end
    local frameTicks = operands[3] == 0 and 3 or operands[3]
    return {
      callback = "managed-sprite-frame-loop",
      taskKind = "managed-sprite-draw-loop",
      context = "sprite-system",
      parameters = { frameTicks = frameTicks },
    }
  elseif selector == 79 then
    return {
      callback = "pokemon-picture-target-priority-transition",
      taskKind = "pokemon-picture-target-priority-transition",
      context = "pokemon-picture",
      battlerTarget = "target",
      parameters = {},
    }
  elseif selector == 11 then
    return {
      callback = "pokemon-picture-scale-position-transition",
      taskKind = "pokemon-picture-scale-position-transition",
      context = "pokemon-picture",
      parameters = {},
    }
  elseif selector == 18 then
    return {
      callback = "pokemon-picture-palette-fade",
      taskKind = "pokemon-picture-palette-fade",
      context = "pokemon-picture",
      parameters = {},
    }
  elseif selector == 8 then
    return {
      callback = "pokemon-picture-double-sprite-scale-settle",
      taskKind = "pokemon-picture-double-sprite-scale-settle",
      context = "pokemon-picture",
      parameters = {},
    }
  elseif selector == 7 then
    return {
      callback = "pokemon-picture-four-sprite-wave-transition",
      taskKind = "pokemon-picture-four-sprite-wave-transition",
      context = "pokemon-picture",
      parameters = {},
    }
  elseif selector == 4 then
    local mode = operands[6] or 0
    local battlerTarget = (mode == 0 or mode == 2) and "target" or "attacker"
    local pivotMode = mode == 1 and "explicit-pivot" or "derived-pivot"
    local callback = "pokemon-picture-z-rotation-" .. battlerTarget .. "-" .. pivotMode
    local parameters = {
      startAngle = (operands[3] or 0) % 0x10000,
      targetAngle = (operands[4] or 0) % 0x10000,
      durationTicks = operands[5] or 0,
      reverseDirection = mode == 2,
    }
    if mode == 1 then
      parameters.pivotX = signed16(operands[7] or 0)
      parameters.pivotY = signed16(operands[8] or 0)
    end
    return {
      callback = callback,
      taskKind = "pokemon-picture-z-rotation-transition",
      context = "pokemon-picture",
      battlerTarget = battlerTarget,
      parameters = parameters,
    }
  elseif selector == 5 then
    return {
      callback = "pokemon-picture-palette-fade-position-transition",
      taskKind = "pokemon-picture-palette-fade-position-transition",
      context = "pokemon-picture",
      parameters = {
        approachOffset = signed16(operands[3] or 0),
        settleOffset = signed16(operands[4] or 0),
        approachTicks = operands[5] or 0,
        settleTicks = operands[6] or 0,
      },
    }
  elseif selector == 10 then
    local mode = operands[5] or 0
    local modeDefinitions = {
      [2] = { callback = "pokemon-picture-sinusoidal-position-attacker", battlerTarget = "attacker" },
      [4] = { callback = "pokemon-picture-sinusoidal-position-attacker-pair", battlerTarget = "attacker" },
      [8] = { callback = "pokemon-picture-sinusoidal-position-target", battlerTarget = "target" },
      [16] = { callback = "pokemon-picture-sinusoidal-position-target-pair", battlerTarget = "target" },
    }
    local modeDefinition = modeDefinitions[mode]
    if modeDefinition == nil then
      return nil, "picture sinusoidal callback follows its source assertion path"
    end
    return {
      callback = modeDefinition.callback,
      taskKind = "pokemon-picture-sinusoidal-position-motion",
      context = "pokemon-picture",
      battlerTarget = modeDefinition.battlerTarget,
      parameters = {
        oscillationCycles = operands[3] or 0,
        durationTicks = operands[4] or 0,
      },
    }
  elseif selector == 9 then
    return {
      callback = "pokemon-picture-battler-pair-scale-transition",
      taskKind = "pokemon-picture-battler-pair-scale-transition",
      context = "pokemon-picture",
      parameters = {},
    }
  elseif selector == 12 then
    return {
      callback = "battle-background-pokepic-slide",
      taskKind = "battle-background-pokepic-slide",
      context = "battle-display",
      parameters = {},
    }
  elseif selector == 13 then
    return {
      callback = "pokemon-picture-palette-pulse-position-transition",
      taskKind = "pokemon-picture-palette-pulse-position-transition",
      context = "pokemon-picture",
      parameters = {},
    }
  elseif selector == 14 then
    return {
      callback = "pokemon-picture-table-driven-position-transition",
      taskKind = "pokemon-picture-table-driven-position-transition",
      context = "pokemon-picture",
      parameters = {},
    }
  elseif selector == 15 then
    return {
      callback = "pokemon-picture-and-battle-palette-fade-cycle",
      taskKind = "pokemon-picture-and-battle-palette-fade-cycle",
      context = "battle-palette",
      parameters = {},
    }
  elseif selector == 16 then
    return {
      callback = "pokemon-picture-battle-palette-fade-cycle",
      taskKind = "pokemon-picture-battle-palette-fade-cycle",
      context = "battle-palette",
      parameters = {},
    }
  elseif selector == 17 then
    return {
      callback = "sprite-affine-scale-and-blend-transition",
      taskKind = "sprite-affine-scale-and-blend-transition",
      context = "battle-sprite",
      parameters = {},
    }
  elseif selector == 19 then
    return {
      callback = "pokemon-picture-repeated-scale-position-transition",
      taskKind = "pokemon-picture-repeated-scale-position-transition",
      context = "pokemon-picture",
      parameters = {},
    }
  elseif selector == 20 then
    return {
      callback = "battle-background-picture-wipe-transition",
      taskKind = "battle-background-picture-wipe-transition",
      context = "battle-display",
      parameters = {},
    }
  elseif selector == 22 then
    return {
      callback = "pokemon-picture-three-sprite-affine-transition",
      taskKind = "pokemon-picture-three-sprite-affine-transition",
      context = "pokemon-picture",
      parameters = {},
    }
  elseif selector == 23 then
    return {
      callback = "pokemon-picture-vanish-and-restore-transition",
      taskKind = "pokemon-picture-vanish-and-restore-transition",
      context = "pokemon-picture",
      parameters = {},
    }
  elseif selector == 24 then
    return {
      callback = "battle-background-picture-palette-scroll",
      taskKind = "battle-background-picture-palette-scroll",
      context = "battle-display",
      parameters = {},
    }
  elseif selector == 25 then
    local battlerTarget = (operands[3] or 0) == 0 and "attacker" or "target"
    return {
      callback = "pokemon-picture-entry-offset-" .. battlerTarget,
      taskKind = "pokemon-picture-entry-offset-transition",
      context = "pokemon-picture",
      battlerTarget = battlerTarget,
      parameters = {},
    }
  elseif selector == 29 then
    return {
      callback = "pokemon-picture-oscillating-axis-motion",
      taskKind = "pokemon-picture-oscillating-axis-motion",
      context = "pokemon-picture",
      parameters = {},
    }
  elseif selector == 30 then
    return {
      callback = "pokemon-picture-two-battler-crossing-motion",
      taskKind = "pokemon-picture-two-battler-crossing-motion",
      context = "pokemon-picture",
      parameters = {},
    }
  elseif selector == 31 then
    return {
      callback = "pokemon-picture-two-phase-entry-motion",
      taskKind = "pokemon-picture-two-phase-entry-motion",
      context = "pokemon-picture",
      parameters = {},
    }
  elseif selector == 32 then
    return {
      callback = "pokemon-picture-managed-sprite-affine-pair-transition",
      taskKind = "pokemon-picture-managed-sprite-affine-pair-transition",
      context = "pokemon-picture",
      parameters = {},
    }
  elseif selector == 73 then
    local spriteContextSlot = operands[3]
    if spriteContextSlot > 9 then
      return nil, "paired picture interpolation sprite context slot is outside the source table"
    end
    local packedTiming = operands[8] or 0
    local battlerTarget = operands[4] == 0 and "attacker" or "target"
    return {
      callback = "pokemon-picture-paired-position-interpolation-" .. battlerTarget,
      taskKind = "pokemon-picture-paired-position-interpolation",
      context = "pokemon-picture",
      battlerTarget = battlerTarget,
      parameters = {
        spriteContextSlot = spriteContextSlot,
        reverseEndpoints = operands[5] ~= 0,
        endpointX = signed16(operands[6]),
        endpointY = signed16(operands[7]),
        initialSteps = math.floor(packedTiming / 0x10000),
        stepIntervalTicks = packedTiming % 0x10000,
      },
    }
  elseif selector == 26 then
    local battlerTarget = (operands[3] or 0) == 0 and "target" or "attacker"
    return {
      callback = "pokemon-picture-randomized-position-motion-" .. battlerTarget,
      taskKind = "pokemon-picture-randomized-position-motion",
      context = "pokemon-picture",
      battlerTarget = battlerTarget,
      parameters = {},
    }
  elseif selector == 27 then
    if operands[3] == 0 then
      return {
        callback = "battle-background-picture-scroll-oscillation",
        taskKind = "battle-background-picture-scroll-oscillation",
        context = "battle-display",
        parameters = {
          directionState = (operands[4] or 0) % 256,
          phaseIndex = (operands[5] or 0) % 256,
        },
      }
    end
    return {
      callback = "battle-background-picture-coordinate-sweep",
      taskKind = "battle-background-picture-coordinate-sweep",
      context = "battle-display",
      parameters = {
        startX = signed16(operands[4] or 0),
        startY = signed16(operands[5] or 0),
        deltaX = signed16(operands[6] or 0),
        deltaY = signed16(operands[7] or 0),
      },
    }
  elseif selector == 49 then
    return {
      callback = "pokemon-picture-affine-sprite-entry-transition",
      taskKind = "pokemon-picture-affine-sprite-entry-transition",
      context = "pokemon-picture",
      parameters = {},
    }
  elseif selector == 50 then
    return {
      callback = "pokemon-picture-repeated-vanish-transition",
      taskKind = "pokemon-picture-repeated-vanish-transition",
      context = "pokemon-picture",
      parameters = {
        toggleCount = ((operands[3] or 0) * 2) % 0x100000000,
        intervalTicks = operands[4] or 0,
      },
    }
  elseif selector == 52 then
    if count ~= 3 then
      return nil, "picture position-offset callback requires three source operands"
    end
    local pictureTargets = {
      [258] = "active-battler",
      [260] = "active-battler-pair-when-enabled",
      [264] = "opposing-battler",
      [272] = "opposing-battler-pair-when-enabled",
    }
    local pictureTarget = pictureTargets[operands[5]]
    if pictureTarget == nil then
      return nil, "picture position-offset callback follows its source assertion path"
    end
    return {
      callback = "pokemon-picture-selected-position-offset-transition",
      taskKind = "pokemon-picture-selected-position-offset-transition",
      context = "pokemon-picture",
      parameters = {
        pictureTarget = pictureTarget,
        durationTicks = operands[3],
        signedOffset = signed16(operands[4]),
      },
    }
  elseif selector == 53 then
    if count < 5 then
      return nil, "picture scale transition requires five source operands"
    end
    return {
      callback = "pokemon-picture-two-phase-scale-transition",
      taskKind = "pokemon-picture-two-phase-scale-transition",
      context = "pokemon-picture",
      parameters = {
        firstEndpoint = signed16(operands[3]),
        firstDurationTicks = operands[5],
        phaseDelayTicks = operands[7] % 0x100,
        secondEndpointX = signed16(operands[3]),
        secondEndpointY = signed16(operands[4]),
        secondDurationTicks = operands[6],
      },
    }
  elseif selector == 47 then
    return {
      callback = "pokemon-picture-height-position-transition",
      taskKind = "pokemon-picture-height-position-transition",
      context = "pokemon-picture",
      parameters = {},
    }
  elseif selector == 48 then
    -- DefenderKnockback (battle_anim_effects.c) reads no source words:
    -- a five-tick linear displacement (one dispatch tick plus four
    -- motion ticks), a seventeen-tick shake (InitShake interval 1,
    -- count 4: four phases per count, plus the transition tick), and a
    -- five-tick return plus the snap tick run 29 ticks. The generic
    -- visual body holds that boundary with no patch: the side-directed
    -- jolt has no static expression, so the run stays timing-accurate
    -- instead of inventing motion.
    if count ~= 0 then
      return nil, "defender knockback callback follows its source assertion path"
    end
    return {
      callback = "pokemon-picture-defender-knockback",
      taskKind = "pokemon-picture-defender-knockback",
      context = "pokemon-picture",
      battlerTarget = "target",
      parameters = { durationTicks = 29 },
    }
  elseif selector == 59 then
    -- AttackerDashAfterimages (battle_anim_move_effects.c) never reads
    -- its single source word; the linear-motion update reports TRUE
    -- while moving (battle_anim_util.c), so the out leg (slowest of
    -- the 3/6/8 motions) retires on its ninth update and the back leg
    -- (slowest of 3/6/9) on its tenth, plus the two dispatch ticks and
    -- the destroy tick run 22 ticks. The afterimage sprites and blend
    -- have no scene expression, so the run holds the boundary.
    if count ~= 1 then
      return nil, "attacker dash callback follows its source assertion path"
    end
    return {
      callback = "pokemon-picture-attacker-dash-afterimages",
      taskKind = "pokemon-picture-attacker-dash-afterimages",
      context = "pokemon-picture",
      battlerTarget = "attacker",
      parameters = { durationTicks = 22 },
    }
  elseif selector == 61 then
    -- MoveBattlerLinear (battle_anim_funcs.c) slides the role's pictures
    -- to the offscreen edge of its side over its duration word. The exit
    -- direction resolves at runtime from the occurrence side type
    -- (player-side battlers exit left, foe-side battlers exit right);
    -- the 144-pixel run lands the solo foe exactly on the native 336
    -- edge and clears every other slot offscreen. Roles outside the
    -- native attacker/defender flag set stay loud. The target travels
    -- in parameters (like the palette-pulse selector): one callback
    -- profile cannot pin a varying battler target.
    if count ~= 2 then
      return nil, "linear offscreen callback follows its source assertion path"
    end
    local linearTarget = linearRoleTargets(operands[3])
    if linearTarget == nil then
      return nil, "linear offscreen callback follows its source assertion path"
    end
    return {
      callback = "pokemon-picture-linear-offscreen-transition",
      taskKind = "pokemon-picture-linear-offscreen-transition",
      context = "pokemon-picture",
      parameters = {
        durationTicks = operands[4],
        offscreenDistance = 144,
        exitOwnSide = true,
        pictureTarget = linearTarget,
      },
    }
  elseif selector == 62 then
    -- ResetBattlerPosition (battle_anim_funcs.c) snaps the role's picture
    -- home at once. The slide task's teardown already restores the base
    -- position, so the reset lowers as a validated marker with no timing
    -- boundary; every native role maps to its picture target.
    if count ~= 1 then
      return nil, "reset position callback follows its source assertion path"
    end
    local resetTarget = linearRoleTargets(operands[3])
    if resetTarget == nil then
      return nil, "reset position callback follows its source assertion path"
    end
    return {
      callback = "pokemon-picture-reset-position-transition",
      taskKind = "pokemon-picture-reset-position-transition",
      context = "pokemon-picture",
      parameters = { pictureTarget = resetTarget },
    }
  elseif selector == 55 then
    return {
      callback = "pokemon-picture-vanish-affine-transition",
      taskKind = "pokemon-picture-vanish-affine-transition",
      context = "pokemon-picture",
      parameters = {},
    }
  elseif selector == 56 then
    return {
      callback = "battle-sprite-affine-appearance-transition",
      taskKind = "battle-sprite-affine-appearance-transition",
      context = "battle-sprite",
      parameters = {},
    }
  elseif selector == 58 then
    return {
      callback = "pokemon-picture-three-sprite-position-wave-transition",
      taskKind = "pokemon-picture-three-sprite-position-wave-transition",
      context = "pokemon-picture",
      parameters = {},
    }
  elseif selector == 43 then
    return {
      callback = "pokemon-picture-reciprocal-position-palette-transition",
      taskKind = "pokemon-picture-reciprocal-position-palette-transition",
      context = "pokemon-picture",
      parameters = {},
    }
  elseif selector == 69 then
    local spriteContextSlot = operands[3] or 0
    if spriteContextSlot > 4 then
      return nil, "mosaic transition sprite context slot is outside the source table"
    end
    -- BattleAnimTask_SpriteMosaic steps both mosaic sizes by step each
    -- tick until either reaches target (0 when step < 0, else 15), then
    -- retires on the following tick; a zero step never reaches either
    -- target, so the counted task would wedge the script wait forever.
    local step = signed16(operands[4] or 0)
    if step == 0 then
      return nil, "mosaic transition step of zero never reaches its target"
    end
    local target = step < 0 and 0 or 15
    local sizeH, sizeV = operands[5] or 0, operands[6] or 0
    local durationTicks = 1
    if sizeH ~= target and sizeV ~= target then
      local writes = 0
      while true do
        if step < 0 then
          if sizeH + step > 0 then
            sizeH, sizeV = sizeH + step, sizeV + step
          else
            sizeH, sizeV = target, target
          end
        else
          if sizeH + step < 15 then
            sizeH, sizeV = sizeH + step, sizeV + step
          else
            sizeH, sizeV = target, target
          end
        end
        writes = writes + 1
        if writes > 64 then
          return nil, "mosaic transition sizes never reach their target"
        end
        if sizeH == target or sizeV == target then
          break
        end
      end
      durationTicks = writes + 1
    end
    return {
      callback = "battle-sprite-mosaic-transition",
      taskKind = "battle-sprite-mosaic-transition",
      context = "battle-sprite",
      parameters = {
        spriteContextSlot = spriteContextSlot,
        step = step,
        initialHorizontal = operands[5] or 0,
        initialVertical = operands[6] or 0,
        durationTicks = durationTicks,
      },
    }
  elseif selector == 72 then
    local spriteContextSlot = operands[3] or 0
    local callbackContextSlot = operands[12] or 0
    if spriteContextSlot > 70 then
      return nil, "sinusoidal sprite motion slot is outside the source sprite context table"
    end
    if callbackContextSlot > 70 then
      return nil, "sinusoidal sprite callback slot is outside the source callback context table"
    end
    return {
      callback = "battle-sprite-sinusoidal-position-animation",
      taskKind = "battle-sprite-sinusoidal-position-animation",
      context = "battle-sprite",
      parameters = {
        spriteContextSlot = spriteContextSlot,
        callbackContextSlot = callbackContextSlot,
        positionSource = (operands[11] or 0) == 0 and "first-active-position" or "second-active-position",
        horizontalStartAngleDegrees = signed32(operands[4] or 0),
        horizontalEndAngleDegrees = signed32(operands[5] or 0),
        verticalStartAngleDegrees = signed32(operands[6] or 0),
        verticalEndAngleDegrees = signed32(operands[7] or 0),
        horizontalAmplitude = signed32(operands[8] or 0),
        verticalAmplitude = signed32(operands[9] or 0),
        durationTicks = operands[10] or 0,
      },
    }
  elseif selector >= 80 and selector <= 83 then
    -- BattleAnimTask_ObjWindowBgScroll (battle_anim_effects.c) runs
    -- every panel kind through the same boundary: one setup tick, one
    -- blend-setup tick, twenty-two hold ticks (timer 0 through 21),
    -- twelve blend-out ticks (blend 12/4 stepping to 0/16), and the
    -- destroy tick, for 37 ticks. All four Func bodies hardcode the
    -- same hold and blend; only the scroll velocity (the lowered
    -- offsets) and the graphic/target selection vary, and none of
    -- those gate completion, so no lowered operand can wedge the run.
    local offsetY = ({ [80] = 3, [81] = -3, [82] = 3, [83] = -6 })[selector]
    local callback = offsetY == 3 and "battle-sprite-panel-slide-down"
      or offsetY == -3 and "battle-sprite-panel-slide-up"
      or "battle-sprite-panel-slide-far-up"
    return {
      callback = callback,
      taskKind = "battle-sprite-panel-slide",
      context = "sprite-system",
      parameters = {
        firstPanelOffsetX = 0,
        firstPanelOffsetY = offsetY,
        secondPanelOffsetX = 12,
        secondPanelOffsetY = 4,
        durationTicks = 37,
      },
    }
  end
  return nil, "battle animation callback selector is outside the normalized source set"
end

---@param opcode integer
---@param attackerType string semantic battler position
---@param targetType string semantic battler position
---@return integer|nil zero-based source candidate index, or nil for the source assertion path
function BattleAnimationSources.battlerParticleCandidate(opcode, attackerType, targetType)
  local tableRows = assert(BATTLER_PARTICLE_CANDIDATES[opcode], "unsupported battler particle handler")
  local attackerIndex = assert(BATTLER_POSITION_INDEX[attackerType], "unknown attacker battler position")
  local targetIndex = assert(BATTLER_POSITION_INDEX[targetType], "unknown target battler position")
  local sourceValue = tableRows[attackerIndex + 1][targetIndex + 1]
  if sourceValue == 255 then
    return nil
  end
  return opcode == 48 and sourceValue - 1 or sourceValue
end

---@param battlerIndex integer
---@return string|nil semantic battle position
function BattleAnimationSources.resolveBattlerPosition(battlerIndex)
  return BATTLER_POSITION_BY_INDEX[battlerIndex]
end

---@param opcode integer
---@param operands integer[] source-ordered handler operands
---@return table<string, unknown>|nil semantic action plan
---@return string|nil unresolved plan reason
function BattleAnimationSources.resolveBattlerParticleAction(opcode, operands)
  local definition = BattleAnimationSources.SOURCE_INPUTS[opcode]
  if definition == nil or definition.role ~= "battler-particle-action" then
    return nil, "opcode has no battler particle action"
  end
  if #operands ~= definition.operandCount then
    return nil, "battler particle operand shape is invalid"
  end
  local taskKind = "battler-effect-continuation"
  if opcode == 46 or opcode == 47 then
    local profile = PARTICLE_ACTION_PROFILES[operands[definition.callbackOperand]]
    if profile == nil then
      return nil, "particle callback selector is outside the pinned initializer table"
    end
    local resourceOperand = opcode == 46 and 2 or 3
    return {
      actionProfile = profile,
      sourceEmitterSelections = { resource = operands[resourceOperand] },
      taskKind = taskKind,
    }
  end

  local profile = PARTICLE_ACTION_PROFILES[operands[definition.callbackOperand]]
  if profile == nil then
    return nil, "particle callback table index is outside the pinned initializer table"
  end
  local candidateResNoOperands = definition.candidateResNoOperands
  local sourceEmitterSelections = {}
  for _, attackerPosition in ipairs({
    "solo-player",
    "solo-enemy",
    "player-side-slot-1",
    "enemy-side-slot-1",
    "player-side-slot-2",
    "enemy-side-slot-2",
  }) do
    for _, targetPosition in ipairs({
      "solo-player",
      "solo-enemy",
      "player-side-slot-1",
      "enemy-side-slot-1",
      "player-side-slot-2",
      "enemy-side-slot-2",
    }) do
      local candidate = BattleAnimationSources.battlerParticleCandidate(opcode, attackerPosition, targetPosition)
      local resNo = "source-assert"
      if candidate ~= nil then
        resNo = operands[candidateResNoOperands[candidate + 1]]
      end
      sourceEmitterSelections[attackerPosition .. "/" .. targetPosition] = resNo
    end
  end
  return {
    actionProfile = profile,
    runtimeSelection = "battler-particle-position-pair",
    sourceEmitterSelections = sourceEmitterSelections,
    taskKind = taskKind,
  }
end

---@param role string semantic source selection role
---@param operands integer[] source-ordered producer operands
---@return table<string, unknown>|nil semantic task/resource selection
---@return string|nil unresolved selection reason
function BattleAnimationSources.resolveSourceSelection(role, operands)
  if role == "battle-animation-callback" then
    return BattleAnimationSources.resolveBattleAnimationCallback(operands)
  end
  if role == "battler-particle-action" then
    local opcodeByOperandCount = { [3] = 46, [4] = 47, [8] = 48, [6] = 49 }
    local opcode = opcodeByOperandCount[#operands]
    if opcode == nil then
      return nil, "battler particle operand shape is invalid"
    end
    return BattleAnimationSources.resolveBattlerParticleAction(opcode, operands)
  end
  if role == "battler-particle-resource" then
    local sourceInput = BattleAnimationSources.SOURCE_INPUTS[51]
    if #operands ~= sourceInput.operandCount then
      return nil, "particle resource operand shape is invalid"
    end
    local resourceKey = BattleAnimationSources.resolveParticleResource(operands[sourceInput.memberOperand])
    if resourceKey == nil then
      return nil, "particle member has no semantic resource identity"
    end
    return {
      resourceKeys = { particle = resourceKey },
      sourceSelections = {
        particle = {
          archiveSymbol = sourceInput.archiveSymbol,
          memberId = operands[sourceInput.memberOperand],
          decoder = sourceInput.decoder,
          kind = sourceInput.kind,
        },
      },
    }
  end
  for opcode, sourceInput in pairs(BattleAnimationSources.SOURCE_INPUTS) do
    if sourceInput.role == role then
      if sourceInput.operandCount ~= nil and #operands ~= sourceInput.operandCount then
        return nil, "source input operand shape is invalid"
      end
      if opcode == 21 then
        local row = BattleAnimationSources.BACKGROUND_MEMBER_ROWS[operands[1] + 1]
        if row == nil then
          return nil, "battle background selector is outside the pinned table"
        end
        local archiveSymbol = BattleAnimationSources.LOWER_NARC
        return {
          sourceSelections = {
            character = { archiveSymbol = archiveSymbol, memberId = row[1], decoder = "char", kind = "texture" },
            palette = { archiveSymbol = archiveSymbol, memberId = row[2], decoder = "palette", kind = "palette" },
            screenDefault = { archiveSymbol = archiveSymbol, memberId = row[3], decoder = "screen", kind = "map" },
            screenAlternate = { archiveSymbol = archiveSymbol, memberId = row[4], decoder = "screen", kind = "map" },
          },
          runtimeSelection = "battle-background-screen-selection",
        }
      elseif opcode >= 46 and opcode <= 49 then
        return BattleAnimationSources.resolveBattlerParticleAction(opcode, operands)
      elseif opcode == 57 then
        local archiveSymbol = BattleAnimationSources.SCENE_NARC
        return {
          sourceSelections = {
            character = { archiveSymbol = archiveSymbol, memberId = 76, decoder = "char", kind = "texture" },
            palette = { archiveSymbol = archiveSymbol, memberId = 75, decoder = "palette", kind = "palette" },
            cell = { archiveSymbol = archiveSymbol, memberId = 77, decoder = "cell", kind = "cell" },
            animation = { archiveSymbol = archiveSymbol, memberId = 78, decoder = "animation", kind = "animation" },
          },
          runtimeSelection = "battler-resource-selection",
        }
      elseif opcode == 58 then
        local battlerTarget = BattleAnimationSources.BATTLER_PICTURE_TARGETS[operands[1]]
        if battlerTarget == nil then
          return nil, "battler picture target selector is outside the source table"
        end
        return {
          battlerTarget = battlerTarget,
          runtimeSelection = "battler-pokemon-picture-resource",
        }
      elseif opcode == 78 then
        if #operands < 9 or operands[9] > 10 or #operands ~= 9 + operands[9] then
          return nil, "configured sprite operand shape is invalid"
        end
        local parameterWords = {}
        for index = 10, #operands do
          parameterWords[index - 9] = operands[index]
        end
        local action, reason = BattleAnimationSources.resolveConfiguredSpriteAction(operands[2], parameterWords)
        if action == nil then
          return nil, reason
        end
        return action
      elseif sourceInput.memberOperand ~= nil then
        return {
          sourceSelections = {
            [sourceInput.resourceSlots[1]] = {
              archiveSymbol = sourceInput.archiveSymbol,
              memberId = operands[sourceInput.memberOperand],
              decoder = sourceInput.decoder,
              kind = sourceInput.kind,
            },
          },
        }
      end
    end
  end
  return nil, "source selection role has no pinned route table"
end

---@param opcode integer
---@return boolean
function BattleAnimationSources.isSourceNoop(opcode)
  return opcode == 6
    or opcode == 7
    or (opcode >= 27 and opcode <= 28)
    or (opcode >= 37 and opcode <= 43)
    or opcode == 54
end

---@param memberId integer producer-only SPL member selector
---@return string|nil semantic particle resource key
function BattleAnimationSources.resolveParticleResource(memberId)
  return BattleAnimationSources.PARTICLE_RESOURCES[memberId]
end

---@param resourceKey string semantic particle identity
---@return table<string, unknown>|nil producer-only particle source descriptor
function BattleAnimationSources.resolveParticleSource(resourceKey)
  return BattleAnimationSources.PARTICLE_SOURCE_INPUTS[resourceKey]
end

---@param selector integer producer-only visual task table selector
---@return string|nil semantic task kind
function BattleAnimationSources.resolveVisualTaskKind(selector)
  return BattleAnimationSources.VISUAL_TASK_KINDS[selector]
end

---@param selector integer producer-only visual update selector
---@return string|nil semantic axis adjustment
function BattleAnimationSources.resolveVisualUpdateKind(selector)
  return BattleAnimationSources.VISUAL_UPDATE_KINDS[selector]
end

---@param selector integer producer-only effect mode selector
---@return string semantic draw behavior
function BattleAnimationSources.resolveSpriteEffectMode(selector)
  return BattleAnimationSources.SPRITE_EFFECT_MODES[selector] or "retain-source-draw-state"
end

---@return integer
function BattleAnimationSources.handlerCount()
  return #BattleAnimationSources.HANDLER_LABELS
end

---@param effectKey string semantic route key
---@return { kind: "move", key: string, moveId: integer, archiveSymbol: string, memberId: integer }|{ kind: "battle-animation", key: string, animationCategory: integer, archiveSymbol: string, memberId: integer }|nil
function BattleAnimationSources.resolveSemanticRoute(effectKey)
  local MonSources = require("romdump.src.config.MonSources")
  for moveId, moveKey in pairs(MonSources.moveKeys) do
    if moveKey == effectKey and moveId ~= 0 then
      return {
        kind = "move",
        key = moveKey,
        moveId = moveId,
        archiveSymbol = BattleAnimationSources.MOVE_NARC,
        memberId = moveId,
      }
    end
  end
  for animationCategory, rootKey in pairs(NON_MOVE_ANIMATION_ROOTS) do
    if rootKey == effectKey then
      return {
        kind = "battle-animation",
        key = rootKey,
        animationCategory = animationCategory,
        archiveSymbol = "NARC_a_0_6_1",
        memberId = animationCategory,
      }
    end
  end
  return nil
end

---@return { kind: string, key: string, moveId: integer|nil, animationCategory: integer|nil, archiveSymbol: string, memberId: integer }[] finite HeartGold move and named battle-animation roots
function BattleAnimationSources.listSemanticRoots()
  local roots = {}
  local MonSources = require("romdump.src.config.MonSources")
  for moveId = 1, 467 do
    local moveKey = assert(MonSources.moveKeys[moveId], "missing pinned move identity")
    roots[#roots + 1] = {
      kind = "move",
      key = moveKey,
      moveId = moveId,
      archiveSymbol = BattleAnimationSources.MOVE_NARC,
      memberId = moveId,
    }
  end
  for animationCategory, rootKey in pairs(NON_MOVE_ANIMATION_ROOTS) do
    roots[#roots + 1] = {
      kind = "battle-animation",
      key = rootKey,
      animationCategory = animationCategory,
      archiveSymbol = "NARC_a_0_6_1",
      memberId = animationCategory,
    }
  end
  table.sort(roots, function(left, right)
    if left.kind ~= right.kind then
      return left.kind < right.kind
    end
    return (left.moveId or left.animationCategory) < (right.moveId or right.animationCategory)
  end)
  return roots
end

return BattleAnimationSources
