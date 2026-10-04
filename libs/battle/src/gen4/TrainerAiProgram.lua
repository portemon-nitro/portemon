-- Private semantic transcription of the reachable trainer-AI programs
-- (pret/pokeheartgold src/battle/trainer_ai.c and
-- asm/overlay_10_trainer_ai.s ov10_02220AAC).
--
-- The runtime never reads ROM bytes or numeric source offsets: each
-- generated-corpus flag bit maps to a semantic command list executed by
-- the interpreter in libs/battle/src/gen4/TrainerAi.lua through the
-- dispatch behind asm ov10_0221C278 (table ov10_0222B0B4). Commands name
-- their operand semantics; ordering within a program is significant.
-- Anything the interpreter cannot dispatch fails closed instead of
-- falling back to a heuristic choice.

---@class TrainerAiProgram
local TrainerAiProgram = {}

-- Stored-threshold branch mark: per-slot thresholds span 85..100, so a
-- branch below this mark fires for roughly half the stored range.
TrainerAiProgram.CHANCE_MARK = 93

-- Routine-draw sites transcribed per program. The source command handlers
-- behind ov10_0221C278 table ov10_0222B0B4 entries 0 through 3
-- (ov10_0221C384, ov10_0221C3C4, ov10_0221C404, ov10_0221C444) spend one
-- shared-stream draw per execution and then conditionally skip ahead; the
-- interpreter draws once per usable slot for every site the slot reaches.
-- Guards name numeric move effects (MoveTbl effect IDs read from the
-- session move facts) and, where the source program gates on the opening
-- turn, the first-turn mark. A site with ko set draws only when the
-- damage preview reaches the foe's remaining health (the source knockout
-- branch); ko false draws only below it. Bits 5 and 6 also reach
-- routine-draw commands in the source programs, but their branch guards
-- need control-flow transcription beyond effect and turn facts, so this
-- table carries no sites for them yet.
TrainerAiProgram.PROGRAMS = {
  -- Bad-move check: every usable slot earns its matchup points while a
  -- negated strike falls below scoreless status attempts.
  [0] = {
    perSlot = {
      { op = "add_matchup" },
      { op = "punish_immune", amount = 10 },
    },
    perProgram = {},
  },
  -- Faint-seeking: weaker strikes lose a point while a doubly effective
  -- strike earns two when the stored threshold favors the slot.
  [1] = {
    perSlot = {
      { op = "punish_weaker", amount = 1 },
      { op = "bonus_if_doubly_effective", amount = 2 },
    },
    perProgram = {},
  },
  -- Effectiveness emphasis: clearly super-effective strikes gain while
  -- resisted ones lose; immunities stay with the bad-move check.
  [2] = {
    perSlot = {
      { op = "bonus_if_effective", amount = 2 },
      { op = "punish_if_resisted", amount = 2 },
    },
    perProgram = {},
  },
  -- Same-type preference: reliable same-type strikes gain while
  -- off-type attempts lose one.
  [3] = {
    perSlot = {
      { op = "prefer_stab", bonus = 2, penalty = 1 },
    },
    perProgram = {},
  },
  -- Knockout awareness: strikes whose damage preview reaches the foe's
  -- remaining health gain for the finish.
  [5] = {
    perSlot = {
      { op = "bonus_if_knockout", amount = 3 },
    },
    perProgram = {},
  },
  -- Type-aware setup continuation: strikes earn their matchup points
  -- while a negated strike falls off, and the pivot strike keeps its
  -- points so a setup line completes its baton pass instead of
  -- scattering.
  [6] = {
    perSlot = {
      { op = "add_matchup" },
      { op = "punish_immune", amount = 10 },
      { op = "bonus_if_baton_pass", amount = 4 },
    },
    perProgram = {},
  },
  -- Unpredictability: a small deterministic bonus lands on the
  -- lowest-index usable slot without drawing.
  [9] = {
    perSlot = {},
    perProgram = {
      { op = "bonus_first_slot", amount = 1 },
    },
  },
}

-- Per-bit routine-draw sites in program order. The interpreter evaluates
-- every site for every usable slot after that bit's score commands;
-- score commands draw nothing, so this matches the source stream position.
-- Effect sets transcribe the source membership tests verbatim (opcodes 47
-- and 26 operand lists in program order); turn0 transcribes the source
-- total-turns gate that only passes on the opening turn.
---@type table<integer, table<integer, { effects: table<integer, boolean>, turn0: boolean?, ko: boolean? }>>
TrainerAiProgram.DRAW_SITES = {
  -- Bad-move check: the effect ladder converges on one routine draw,
  -- and the knockout branch carries its own effect ladder to a second
  -- site. The two sites are exclusive through the knockout check.
  [0] = {
    { effects = { [7] = true, [170] = true, [248] = true }, turn0 = false, ko = false },
    {
      effects = { [7] = true, [170] = true, [248] = true, [148] = true, [103] = true },
      turn0 = false,
      ko = true,
    },
  },
  [1] = {},
  -- Effectiveness emphasis: the opening-turn gate plus a sixty-entry
  -- effect membership test reach one routine draw.
  [2] = {
    {
      effects = {
        [10] = true,
        [11] = true,
        [12] = true,
        [13] = true,
        [14] = true,
        [15] = true,
        [16] = true,
        [18] = true,
        [19] = true,
        [20] = true,
        [21] = true,
        [22] = true,
        [23] = true,
        [24] = true,
        [30] = true,
        [35] = true,
        [54] = true,
        [47] = true,
        [49] = true,
        [50] = true,
        [51] = true,
        [52] = true,
        [53] = true,
        [55] = true,
        [56] = true,
        [58] = true,
        [59] = true,
        [60] = true,
        [61] = true,
        [62] = true,
        [63] = true,
        [64] = true,
        [65] = true,
        [66] = true,
        [67] = true,
        [79] = true,
        [84] = true,
        [108] = true,
        [109] = true,
        [118] = true,
        [213] = true,
        [187] = true,
        [156] = true,
        [165] = true,
        [166] = true,
        [167] = true,
        [181] = true,
        [192] = true,
        [199] = true,
        [205] = true,
        [206] = true,
        [208] = true,
        [211] = true,
        [225] = true,
        [226] = true,
        [240] = true,
        [252] = true,
        [258] = true,
        [261] = true,
      },
      turn0 = true,
      ko = nil,
    },
  },
  -- Same-type preference: one effect membership test reaches one draw.
  [3] = {
    {
      effects = {
        [38] = true,
        [43] = true,
        [49] = true,
        [83] = true,
        [88] = true,
        [89] = true,
        [98] = true,
        [118] = true,
        [120] = true,
        [122] = true,
        [140] = true,
        [142] = true,
        [144] = true,
        [170] = true,
        [185] = true,
        [199] = true,
        [219] = true,
        [226] = true,
        [227] = true,
        [230] = true,
        [241] = true,
        [248] = true,
      },
      turn0 = false,
      ko = nil,
    },
  },
  [5] = {},
  [6] = {},
  -- Unpredictability: one effect membership test reaches one draw.
  [9] = {
    {
      effects = {
        [1] = true,
        [18] = true,
        [19] = true,
        [23] = true,
        [24] = true,
        [49] = true,
        [58] = true,
        [59] = true,
        [60] = true,
        [62] = true,
        [66] = true,
        [67] = true,
        [84] = true,
        [90] = true,
        [100] = true,
        [112] = true,
        [118] = true,
        [120] = true,
        [165] = true,
        [166] = true,
        [167] = true,
        [173] = true,
        [187] = true,
        [188] = true,
        [192] = true,
        [197] = true,
        [199] = true,
        [205] = true,
        [213] = true,
        [232] = true,
        [234] = true,
        [249] = true,
        [258] = true,
        [265] = true,
      },
      turn0 = false,
      ko = nil,
    },
  },
}

return TrainerAiProgram
