-- Compile-time evaluation of the native front-picture animation for one
-- species: the ten front frame records from the picture metadata archive
-- joined with the selected motion/palette program into a finite sequence
-- of complete per-tick visual samples with exact termination. Producer
-- only; runtime code must never require this module.
--
-- Source basis (every recurrence below transcribes the pinned decomp
-- rather than observed gameplay):
-- * The 89-byte metadata record holds two 43-byte entries (three header
--   bytes plus ten 4-byte frame records) and three trailing species
--   attributes. The entry layout transcribes src/pokemon.c
--   `NARC_ReadPokepicAnimScript` (the ten `PokepicAnimScript` records) and
--   `sub_0207294C` (front entry for animation mode 2, header byte 1 as the
--   motion program, header byte 2 as the motion delay, header byte 0 as
--   the cry delay).
-- * Each frame record is `{ next, duration, xOffset, unk }` per
--   include/pokepic.h. The per-tick recurrence (step advance, delay
--   countdown, counted loop records, terminal record) transcribes
--   src/pokepic.c `Pokepic_RunAnimInternal` and the `Pokepic_StartAnim`
--   initialization. Loop records repeat a bounded number of visits, so
--   frame evaluation always terminates; anything outside the ten records
--   is malformed.
-- * The motion program is a word stream over the 34-entry dispatch in
--   asm/unk_02016EDC.s (`_020F61F8`). The task recurrence transcribes
--   `sub_020170C4` (motion delay countdown, per-tick channel phase,
--   finish teardown) and `sub_020170FC` (restore/fade gating, the bounded
--   per-tick opcode burst with its source 256-operation hang guard).
--   Program indices at or above 143 fall back to program 0, transcribing
--   the `cmp r6, #0x8f` guard in `sub_02016F40`. Operand bytes that select
--   registers assert the eight-register file; the kind bytes that double
--   as accumulator destinations land exactly where the source store
--   address computes them.
-- * Arithmetic is 32-bit two's-complement with C truncation division; the
--   sine/cosine content matches the ROM `FX_SinCosTable_` entries (4096
--   interleaved 4096-scale pairs, one full turn per 4096 indices) and
--   palette blending matches src/palette.c `BlendColor`.
-- Pure module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")

local bit = require("bit")

---@class SummaryPictureCompiler
local SummaryPictureCompiler = {}

SummaryPictureCompiler.ERROR = {
  SOURCE_INVALID = "SUMMARY_PICTURE_SOURCE_INVALID",
  EVALUATION_FAILED = "SUMMARY_PICTURE_MALFORMED",
}

-- Upper bound on simulated native ticks per track. Every source track
-- terminates (counted loops, finite channels, converging fades), so this
-- budget is a malformed-input guard only; reaching it fails loudly and
-- never publishes a truncated animation.
SummaryPictureCompiler.TICK_BUDGET = 65536

-- The motion dispatch carries 34 operations; the per-tick burst executes
-- at most 256 of them before the source hang guard finishes the task.
local OPCODE_COUNT = 34
local BURST_LIMIT = 256

local RECORD_COUNT = 494
local RECORD_SIZE = 89
local ENTRY_SIZE = 43
local SCRIPT_COUNT = 10
local PROGRAM_FALLBACK_LIMIT = 143

local ANCHOR_X = 208
local ANCHOR_Y = 104
local AFFINE_UNIT = 256
local ROTATION_UNIT = 65536

---@noreturn
local function sourceError(message, context)
  error(Errors.new(SummaryPictureCompiler.ERROR.SOURCE_INVALID, "summary picture " .. message, context or {}), 0)
end

---@noreturn
local function malformed(message, context)
  error(Errors.new(SummaryPictureCompiler.ERROR.EVALUATION_FAILED, "summary picture " .. message, context or {}), 0)
end

local function toU32(value)
  return value % 4294967296
end

local function toS32(value)
  local wrapped = value % 4294967296
  if wrapped >= 2147483648 then
    return wrapped - 4294967296
  end
  return wrapped
end

local function add32(a, b)
  return toS32(a + b)
end

local function mul32(a, b)
  local au, bu = toU32(a), toU32(b)
  local a0, a1 = au % 65536, math.floor(au / 65536)
  local b0, b1 = bu % 65536, math.floor(bu / 65536)
  local low = a0 * b0
  local mid = (a0 * b1 + a1 * b0) % 65536
  return toS32(low + mid * 65536)
end

local function div32(a, b)
  if b == 0 then
    malformed("integer division by zero", {})
  end
  ---@cast b integer
  local quotient = math.floor(math.abs(a) / math.abs(b))
  if (a < 0) ~= (b < 0) then
    quotient = -quotient
  end
  return quotient
end

local function asr32(value, shift)
  return bit.arshift(toS32(value), shift)
end

local function wrapU16(value)
  return bit.band(toS32(value), 0xFFFF)
end

local function lowByte(word)
  return bit.band(word, 0xFF)
end

local function s8(byte)
  if byte >= 128 then
    return byte - 256
  end
  return byte
end

-- The ROM sine/cosine content, verified entry-for-entry against the dumped
-- image: interleaved 4096-scale pairs with one full turn per 4096 indices.
local function sinTable(index)
  return math.floor(math.sin((index * 2 * math.pi) / 4096) * 4096 + 0.5)
end

local function cosTable(index)
  return math.floor(math.cos((index * 2 * math.pi) / 4096) * 4096 + 0.5)
end

local function openArchive(romFs, symbol, role)
  local archive, err = romFs:openNarc(symbol)
  if not archive then
    sourceError("the " .. role .. " archive does not open: " .. Errors.format(err), {})
  end
  assert(archive ~= nil, "unopenable archives fail above")
  return archive
end

local function readMember(archive, memberId, role, dependencies)
  local member, err = archive:readMember(memberId)
  if not member then
    sourceError("member " .. memberId .. " is unreadable: " .. Errors.format(err), { role = role, memberId = memberId })
  end
  assert(member ~= nil, "unreadable members fail above")
  dependencies[#dependencies + 1] = { name = role .. ":member:" .. memberId, sha1 = Hashing.sha1hex(member) }
  return member
end

local function readWords(member, role)
  if #member % 4 ~= 0 then
    sourceError("the motion program is not a word stream", { role = role, bytes = #member })
  end
  local words = {}
  for offset = 1, #member, 4 do
    local word = string.byte(member, offset)
      + string.byte(member, offset + 1) * 256
      + string.byte(member, offset + 2) * 65536
      + string.byte(member, offset + 3) * 16777216
    words[#words + 1] = toS32(word)
  end
  return words
end

local function decodeRecord(member, species, role)
  if #member ~= RECORD_COUNT * RECORD_SIZE then
    sourceError("the picture metadata has an unexpected size", { role = role, bytes = #member })
  end
  if species < 0 or species >= RECORD_COUNT then
    sourceError("the species selects no metadata record", { role = role, species = species })
  end
  local base = species * RECORD_SIZE
  local entry = member:sub(base + 1, base + ENTRY_SIZE)
  local header = { string.byte(entry, 1), string.byte(entry, 2), string.byte(entry, 3) }
  local script = {}
  for index = 0, SCRIPT_COUNT - 1 do
    local offset = 3 + index * 4
    script[index + 1] = {
      next = s8(string.byte(entry, offset + 1)),
      duration = string.byte(entry, offset + 2),
      xOffset = s8(string.byte(entry, offset + 3)),
    }
  end
  local tail = member:sub(base + ENTRY_SIZE * 2 + 1, base + RECORD_SIZE)
  return {
    cryDelay = header[1],
    program = header[2],
    motionDelay = header[3],
    script = script,
    placement = { offsetX = s8(string.byte(tail, 1)), offsetY = s8(string.byte(tail, 2)) },
  }
end

-- Attribute numbers transcribe the POKEPIC_* enum order in
-- include/pokepic.h: 0 X, 1 Y, 9 ZROT, 10 XPIVOT, 12 AFFINEW, 13 AFFINEH,
-- 14 VISIBLE, 30 FADE, 31 FADE_COLOR, 32 FADE_BLDY, 33 FADE_BLDY_TARGET,
-- 34 FADE_SPEED.
local ATTR_X = 0
local ATTR_Y = 1
local ATTR_ZROT = 9
local ATTR_AFFINEW = 12
local ATTR_AFFINEH = 13
local ATTR_VISIBLE = 14
local ATTR_FADE = 30
local ATTR_FADE_COLOR = 31
local ATTR_FADE_BLDY = 32
local ATTR_FADE_BLDY_TARGET = 33
local ATTR_FADE_SPEED = 34

local function newMachine(words, record)
  return {
    words = words,
    wordCount = #words,
    pc = 0,
    regs = { 0, 0, 0, 0, 0, 0, 0, 0 },
    acc = { [0x60] = 0, [0x64] = 0, [0x68] = 0, [0x6C] = 0, [0x70] = 0, [0x74] = 0, [0x78] = 0 },
    loopStart = nil,
    loopTotal = 0,
    loopCount = 0,
    delay = record.motionDelay,
    attrs = {
      [ATTR_X] = ANCHOR_X,
      [ATTR_Y] = ANCHOR_Y,
      [ATTR_AFFINEW] = AFFINE_UNIT,
      [ATTR_AFFINEH] = AFFINE_UNIT,
      [ATTR_VISIBLE] = 1,
    },
    savedX = ANCHOR_X,
    savedY = ANCHOR_Y,
    sign = 0,
    fade = { active = false, cur = 0, endValue = 0, counter = 0, length = 0, target = 0, started = false },
    lastBlend = nil,
    channels = { nil, nil, nil, nil },
    restoreFlag = false,
    fadeMode = 0x1C,
    fadeWait = false,
    done = false,
    finished = false,
    destroyed = false,
  }
end

-- Consumes one program word past the opcode. The program counter addresses
-- zero-based word indices; the opcode word itself is skipped by the caller
-- after dispatch, exactly as the source post-dispatch advance does.
local function fetch(machine)
  local word = machine.words[machine.pc + 2]
  if word == nil then
    malformed("the motion program escapes its member", { pc = machine.pc })
  end
  machine.pc = machine.pc + 1
  return word
end

local function peek(machine)
  local word = machine.words[machine.pc + 1]
  if word == nil then
    malformed("the motion program escapes its member", { pc = machine.pc })
  end
  return word
end

-- Reads one register-index operand word; the source asserts the value
-- addresses one of the eight registers.
local function fetchReg(machine, what)
  local index = lowByte(fetch(machine))
  if index > 7 then
    malformed(what .. " selects no register: " .. tostring(index), {})
  end
  return index + 1
end

-- Reads one immediate word operand.
local function fetchImm(machine)
  return fetch(machine)
end

-- Resolves one imm-or-register operand pair: the kind word selects a
-- following immediate (0x14) or register (0x15) word.
local function fetchOperand(machine, what)
  local kind = lowByte(fetch(machine))
  if kind == 0x14 then
    return fetchImm(machine)
  elseif kind == 0x15 then
    return machine.regs[fetchReg(machine, what)]
  else
    malformed(what .. " carries an unknown operand kind: " .. tostring(kind), {})
    error("unreachable operand", 0)
  end
end

local function setAttr(machine, attr, value)
  if attr == ATTR_FADE then
    machine.fade.active = value ~= 0
  elseif attr == ATTR_FADE_COLOR then
    machine.fade.target = toS32(value)
  elseif attr == ATTR_FADE_BLDY then
    machine.fade.cur = toS32(value)
    machine.fade.started = true
  elseif attr == ATTR_FADE_BLDY_TARGET then
    machine.fade.endValue = toS32(value)
  elseif attr == ATTR_FADE_SPEED then
    machine.fade.counter = toS32(value)
  else
    machine.attrs[attr] = toS32(value)
  end
end

local function addAttr(machine, attr, value)
  if attr == ATTR_FADE then
    local level = (machine.fade.active and 1 or 0) + value
    machine.fade.active = level ~= 0
  elseif attr == ATTR_FADE_COLOR then
    machine.fade.target = add32(machine.fade.target, value)
  elseif attr == ATTR_FADE_BLDY then
    machine.fade.cur = add32(machine.fade.cur, value)
    machine.fade.started = true
  elseif attr == ATTR_FADE_BLDY_TARGET then
    machine.fade.endValue = add32(machine.fade.endValue, value)
  elseif attr == ATTR_FADE_SPEED then
    machine.fade.counter = add32(machine.fade.counter, value)
  else
    machine.attrs[attr] = add32(machine.attrs[attr] or 0, value)
  end
end

-- Restores the affine/position attributes from the accumulators,
-- transcribing sub_020179D4 and sub_02017A1C, including the conditional
-- Y nudge and its fade-state vocabulary.
local function applyRestore(machine)
  if machine.sign ~= 0 then
    machine.attrs[ATTR_X] = toS32(machine.savedX - (machine.acc[0x60] + machine.acc[0x68]))
  else
    machine.attrs[ATTR_X] = toS32(machine.savedX + (machine.acc[0x60] + machine.acc[0x68]))
  end
  machine.attrs[ATTR_Y] = toS32(machine.savedY + (machine.acc[0x64] + machine.acc[0x6C]))
  machine.attrs[ATTR_AFFINEW] = toS32(AFFINE_UNIT + machine.acc[0x70])
  machine.attrs[ATTR_AFFINEH] = toS32(AFFINE_UNIT + machine.acc[0x74])
  machine.attrs[ATTR_ZROT] = wrapU16(machine.acc[0x78])
  if machine.fadeMode == 0x1B then
    if machine.acc[0x74] < 0 then
      local step = machine.acc[0x74]
      local adjust = asr32(step + asr32(step, 31) + asr32(asr32(step, 31), 29), 3)
      addAttr(machine, ATTR_Y, -adjust)
    end
  elseif machine.fadeMode == 0x1D then
    if machine.acc[0x74] ~= 0 then
      local step = machine.acc[0x74]
      local adjust = asr32(step + asr32(step, 31) + asr32(asr32(step, 31), 29), 3)
      addAttr(machine, ATTR_Y, -adjust)
    end
  elseif machine.fadeMode ~= 0x1C then
    malformed("the fade state escapes its vocabulary: " .. tostring(machine.fadeMode), {})
  end
end

-- Channel target binding transcribes sub_02017BF8: selector 0x23-0x27
-- binds one channel-local slot with one task accumulator.
local CHANNEL_TARGETS = {
  [0x23] = { acc = 0x68 },
  [0x24] = { acc = 0x6C },
  [0x25] = { acc = 0x70 },
  [0x26] = { acc = 0x74 },
  [0x27] = { acc = 0x78 },
}

-- Channel worker arity transcribes the _020F61BC dispatch: sine envelope
-- (6 params), normalized sine envelope (6 params), linear ramp (4 params),
-- interpolating quotient (3 params), clamped accumulator (4 params). The
-- sine workers read their target selector from the second word, the rest
-- from the first.
local CHANNEL_PARAMS = { 6, 6, 4, 3, 4 }
local CHANNEL_TARGET_SECOND = { true, true, false, false, false }

-- Combines one channel output into its accumulator, transcribing
-- sub_02017BC8: 0x18 replaces, 0x19 adds the bind-time snapshot, 0x1A
-- accumulates.
local function combineChannel(machine, channel)
  local mode = channel.mode
  if mode == 0x18 then
    machine.acc[channel.acc] = toS32(channel.output)
  elseif mode == 0x19 then
    machine.acc[channel.acc] = toS32(channel.snap + channel.output)
  elseif mode == 0x1A then
    machine.acc[channel.acc] = add32(machine.acc[channel.acc], channel.output)
  else
    malformed("the channel combine mode escapes its vocabulary: " .. tostring(mode), {})
  end
end

local function waveOutput(channel, angle)
  local amplitude = channel.params[3]
  local scaled = 0
  if channel.wave == 0 then
    scaled = asr32(mul32(sinTable(angle), amplitude), 12)
  elseif channel.wave == 1 then
    scaled = asr32(mul32(cosTable(angle), amplitude), 12)
  elseif channel.wave == 2 then
    scaled = -asr32(mul32(sinTable(angle), amplitude), 12)
  elseif channel.wave == 3 then
    scaled = -asr32(mul32(cosTable(angle), amplitude), 12)
  else
    malformed("the wave selects no sine variant: " .. tostring(channel.wave), {})
  end
  return scaled
end

local function runChannelWorker(machine, channel)
  local kind = channel.kind
  if kind == 0 then
    local value = wrapU16(add32(mul32(channel.count + 1, channel.params[4]), channel.params[5]))
    channel.output = waveOutput(channel, asr32(value, 4))
    combineChannel(machine, channel)
    channel.count = channel.count + 1
    if channel.count >= channel.params[6] then
      channel.active = false
    end
  elseif kind == 1 then
    local progress = div32(mul32(channel.count + 1, channel.params[4]), channel.params[6])
    local value = wrapU16(add32(progress, channel.params[5]))
    channel.output = waveOutput(channel, asr32(value, 4))
    combineChannel(machine, channel)
    channel.count = channel.count + 1
    if channel.count >= channel.params[6] then
      channel.active = false
    end
  elseif kind == 2 then
    channel.output = add32(channel.output, add32(channel.params[2], mul32(channel.count, channel.params[3])))
    combineChannel(machine, channel)
    channel.count = channel.count + 1
    if channel.count >= channel.params[4] then
      channel.active = false
    end
  elseif kind == 3 then
    local value = div32(mul32(channel.count + 1, channel.params[2]), channel.params[3])
    channel.output = value
    combineChannel(machine, channel)
    channel.count = channel.count + 1
    if channel.count >= channel.params[3] then
      channel.active = false
    end
  elseif kind == 4 then
    local delta = add32(channel.params[2], mul32(channel.count, channel.params[3]))
    local current = add32(channel.output, delta)
    channel.output = current
    local limit = channel.params[4]
    if channel.mode == 0x18 or channel.mode == 0x1A then
      if (delta < 0 and current > limit) or (delta >= 0 and current >= limit) then
        channel.output = limit
        channel.active = false
      end
    elseif channel.mode == 0x19 then
      local reached = channel.snap + current
      if (delta < 0 and reached > limit) or (delta >= 0 and reached >= limit) then
        channel.output = add32(current, toS32(limit - reached))
        channel.active = false
      end
    else
      malformed("the channel combine mode escapes its vocabulary: " .. tostring(channel.mode), {})
    end
    combineChannel(machine, channel)
    channel.count = channel.count + 1
  else
    malformed("the channel kind escapes its vocabulary: " .. tostring(kind), {})
  end
end

-- Initializes one motion channel, transcribing sub_02017C78: two operand
-- bytes, the worker parameter words, the accumulator binding, and the
-- immediate first worker run when no start delay was given.
local function initChannel(machine, kind)
  local slot = nil
  for index = 1, 4 do
    local present = machine.channels[index]
    if present == nil or present.active == false then
      slot = index
      break
    end
  end
  if slot == nil then
    malformed("the motion program exceeds its four channels", {})
  end
  assert(slot ~= nil, "exhausted motion channels fail above")
  local mode = lowByte(fetch(machine))
  local startDelay = lowByte(fetch(machine))
  local params = {}
  for _ = 1, CHANNEL_PARAMS[kind + 1] do
    params[#params + 1] = fetchImm(machine)
  end
  local selector = params[CHANNEL_TARGET_SECOND[kind + 1] and 2 or 1]
  local target = CHANNEL_TARGETS[selector]
  if target == nil then
    malformed("the channel target escapes its vocabulary: " .. tostring(selector), {})
  end
  assert(target ~= nil, "unknown channel targets fail above")
  if mode ~= 0x18 and mode ~= 0x19 and mode ~= 0x1A then
    malformed("the channel combine mode escapes its vocabulary: " .. tostring(mode), {})
  end
  local channel = {
    active = true,
    kind = kind,
    params = params,
    mode = mode,
    acc = target.acc,
    snap = machine.acc[target.acc],
    output = 0,
    count = 0,
    wave = 0,
    delay = startDelay,
  }
  if kind == 0 or kind == 1 then
    channel.wave = params[1] - 0x1E
    if channel.wave < 0 or channel.wave > 3 then
      malformed("the wave selects no sine variant: " .. tostring(params[1]), {})
    end
  end
  machine.channels[slot] = channel
  if startDelay == 0 then
    runChannelWorker(machine, channel)
  else
    channel.delay = startDelay - 1
  end
end

-- Executes one opcode of the motion word stream. Every handler consumes
-- exactly the words its source counterpart reads past the opcode; the
-- kind bytes that double as accumulator destinations land exactly where
-- the source store address computes them.
local function executeOpcode(machine, opcode)
  if opcode == 0 then
    setAttr(machine, ATTR_X, machine.savedX)
    setAttr(machine, ATTR_Y, machine.savedY)
    setAttr(machine, ATTR_ZROT, 0)
    setAttr(machine, 10, 0)
    setAttr(machine, ATTR_AFFINEW, AFFINE_UNIT)
    setAttr(machine, ATTR_AFFINEH, AFFINE_UNIT)
    machine.done = true
    machine.finished = true
  elseif opcode == 1 then
    machine.done = true
  elseif opcode == 2 then
    setAttr(machine, ATTR_X, machine.savedX)
    setAttr(machine, ATTR_Y, machine.savedY)
    setAttr(machine, ATTR_ZROT, 0)
    setAttr(machine, 10, 0)
    setAttr(machine, ATTR_AFFINEW, AFFINE_UNIT)
    setAttr(machine, ATTR_AFFINEH, AFFINE_UNIT)
  elseif opcode == 3 then
    local kindA = lowByte(fetch(machine))
    local lhs, rhs
    if kindA == 0x14 then
      local index = fetchReg(machine, "conditional")
      lhs = machine.regs[index]
      rhs = fetchImm(machine)
    elseif kindA == 0x15 then
      local leftIndex = fetchReg(machine, "conditional")
      local rightIndex = fetchReg(machine, "conditional")
      lhs = machine.regs[leftIndex]
      rhs = machine.regs[rightIndex]
    else
      malformed("the conditional carries an unknown operand kind: " .. tostring(kindA), {})
      error("unreachable conditional", 0)
    end
    local cond = lowByte(fetch(machine))
    if cond ~= 0x0F and cond ~= 0x10 and cond ~= 0x11 then
      malformed("the conditional escapes its vocabulary: " .. tostring(cond), {})
    end
    local kindB = lowByte(fetch(machine))
    local dst, value
    if kindB == 0x14 then
      dst = fetchReg(machine, "conditional")
      value = fetchImm(machine)
    elseif kindB == 0x15 then
      dst = fetchReg(machine, "conditional")
      value = machine.regs[fetchReg(machine, "conditional")]
    else
      malformed("the conditional carries an unknown operand kind: " .. tostring(kindB), {})
      error("unreachable conditional", 0)
    end
    local outcome = 0x11
    if lhs < rhs then
      outcome = 0x0F
    elseif lhs > rhs then
      outcome = 0x10
    end
    if cond == outcome then
      machine.regs[dst] = toS32(value)
    end
  elseif opcode == 4 then
    local index = fetchReg(machine, "assign")
    machine.pc = machine.pc + 1
    local value = machine.words[machine.pc + 1]
    if value == nil then
      malformed("the motion program escapes its member", { pc = machine.pc })
    end
    machine.regs[index] = value
  elseif opcode == 5 then
    local src = fetchReg(machine, "copy")
    local dst = fetchReg(machine, "copy")
    machine.regs[dst] = machine.regs[src]
  elseif opcode == 6 or opcode == 7 then
    fetchReg(machine, "arithmetic")
    local kind = lowByte(fetch(machine))
    local left, right
    if kind == 0x12 then
      left = machine.regs[fetchReg(machine, "arithmetic")]
      right = fetchImm(machine)
    elseif kind == 0x13 then
      left = machine.regs[fetchReg(machine, "arithmetic")]
      right = machine.regs[fetchReg(machine, "arithmetic")]
    else
      malformed("the arithmetic carries an unknown operand kind: " .. tostring(kind), {})
      error("unreachable arithmetic", 0)
    end
    local value = 0
    if opcode == 6 then
      value = add32(left, right)
    else
      value = mul32(left, right)
    end
    -- The kind word doubles as the destination: 0x12 writes 0x6C,
    -- 0x13 writes 0x70.
    if kind == 0x12 then
      machine.acc[0x6C] = value
    else
      machine.acc[0x70] = value
    end
  elseif opcode == 8 then
    fetchReg(machine, "arithmetic")
    local kindA = lowByte(fetch(machine))
    local kindB = lowByte(fetch(machine))
    local left, right
    if kindA == 0x12 then
      left = fetchImm(machine)
    elseif kindA == 0x13 then
      left = machine.regs[fetchReg(machine, "arithmetic")]
    else
      malformed("the arithmetic carries an unknown operand kind: " .. tostring(kindA), {})
      error("unreachable arithmetic", 0)
    end
    if kindB == 0x12 then
      right = fetchImm(machine)
    elseif kindB == 0x13 then
      right = machine.regs[fetchReg(machine, "arithmetic")]
    else
      malformed("the arithmetic carries an unknown operand kind: " .. tostring(kindB), {})
      error("unreachable arithmetic", 0)
    end
    if kindB == 0x12 then
      machine.acc[0x6C] = toS32(left - right)
    else
      machine.acc[0x70] = toS32(left - right)
    end
  elseif opcode == 9 or opcode == 10 then
    fetchReg(machine, "division")
    local kindA = lowByte(fetch(machine))
    local kindB = lowByte(fetch(machine))
    local left, right
    if kindA == 0x12 then
      left = fetchImm(machine)
    elseif kindA == 0x13 then
      left = machine.regs[fetchReg(machine, "division")]
    else
      malformed("the division carries an unknown operand kind: " .. tostring(kindA), {})
      error("unreachable division", 0)
    end
    if kindB == 0x12 then
      right = fetchImm(machine)
    elseif kindB == 0x13 then
      right = machine.regs[fetchReg(machine, "division")]
    else
      malformed("the division carries an unknown operand kind: " .. tostring(kindB), {})
      error("unreachable division", 0)
    end
    local quotient = div32(left, right)
    local value = quotient
    if opcode == 10 then
      value = toS32(left - mul32(quotient, right))
    end
    if kindB == 0x12 then
      machine.acc[0x6C] = value
    else
      machine.acc[0x70] = value
    end
  elseif opcode == 11 then
    if machine.loopStart ~= nil then
      malformed("the motion program nests its loops", {})
    end
    local count = fetchImm(machine)
    machine.loopStart = machine.pc
    machine.loopTotal = count
    machine.loopCount = 0
  elseif opcode == 12 then
    if machine.loopStart == nil then
      malformed("the motion program continues no loop", {})
    end
    machine.loopCount = machine.loopCount + 1
    if machine.loopCount >= machine.loopTotal then
      machine.loopStart = nil
      machine.loopTotal = 0
      machine.loopCount = 0
    else
      machine.pc = machine.loopStart
    end
  elseif opcode == 13 then
    local attr = fetchImm(machine)
    local index = fetchReg(machine, "attribute")
    setAttr(machine, attr, machine.regs[index])
  elseif opcode == 14 then
    local attr = fetchImm(machine)
    local index = fetchReg(machine, "attribute")
    addAttr(machine, attr, machine.regs[index])
  elseif opcode == 15 then
    local attr = fetchImm(machine)
    local value = fetchOperand(machine, "attribute")
    local mode = lowByte(fetch(machine))
    if mode == 0x16 then
      setAttr(machine, attr, value)
    elseif mode == 0x17 then
      addAttr(machine, attr, value)
    else
      malformed("the attribute mode escapes its vocabulary: " .. tostring(mode), {})
    end
  elseif opcode == 16 or opcode == 17 then
    fetchReg(machine, "sine")
    local src = fetchReg(machine, "sine")
    local base = machine.regs[src]
    local kindA = lowByte(fetch(machine))
    if kindA == 0x14 then
      fetchImm(machine)
    elseif kindA == 0x15 then
      fetchReg(machine, "sine")
    else
      malformed("the sine carries an unknown operand kind: " .. tostring(kindA), {})
    end
    local kindB = lowByte(fetch(machine))
    local amplitude
    if kindB == 0x14 then
      amplitude = fetchImm(machine)
    elseif kindB == 0x15 then
      amplitude = machine.regs[fetchReg(machine, "sine")]
    else
      malformed("the sine carries an unknown operand kind: " .. tostring(kindB), {})
      error("unreachable sine", 0)
    end
    -- The first operand only advances the stream; the sum wraps the
    -- source register with the surviving operand, and the trailing kind
    -- doubles as the destination: 0x14 writes 0x74, 0x15 writes 0x78.
    local angle = wrapU16(add32(base, amplitude))
    local output = 0
    if opcode == 16 then
      output = asr32(mul32(sinTable(asr32(angle, 4)), amplitude), 12)
    else
      output = asr32(mul32(cosTable(asr32(angle, 4)), amplitude), 12)
    end
    if kindB == 0x14 then
      machine.acc[0x74] = output
    else
      machine.acc[0x78] = output
    end
  elseif opcode == 18 then
    local index = fetchReg(machine, "accumulator")
    local kind = lowByte(fetch(machine))
    if kind == 8 then
      machine.acc[0x60] = machine.regs[index]
    elseif kind == 9 then
      machine.acc[0x64] = machine.regs[index]
    else
      malformed("the accumulator selector escapes its vocabulary: " .. tostring(kind), {})
    end
  elseif opcode == 19 then
    local index = fetchReg(machine, "accumulator")
    local kind = lowByte(fetch(machine))
    if kind == 8 then
      machine.acc[0x60] = add32(machine.acc[0x60], machine.regs[index])
    elseif kind == 9 then
      machine.acc[0x64] = add32(machine.acc[0x64], machine.regs[index])
    else
      malformed("the accumulator selector escapes its vocabulary: " .. tostring(kind), {})
    end
  elseif opcode == 20 then
    local selector = lowByte(fetch(machine))
    if selector < 8 or selector > 0x0E then
      malformed("the accumulator selector escapes its vocabulary: " .. tostring(selector), {})
    end
    local address = 0x60 + (selector - 8) * 4
    local value = fetchOperand(machine, "accumulator")
    local mode = lowByte(fetch(machine))
    if mode == 0x16 then
      machine.acc[address] = toS32(value)
    elseif mode == 0x17 then
      machine.acc[address] = add32(machine.acc[address], value)
    else
      malformed("the accumulator mode escapes its vocabulary: " .. tostring(mode), {})
    end
  elseif opcode == 21 or opcode == 22 then
    applyRestore(machine)
  elseif opcode == 23 then
    local index = fetchReg(machine, "accumulator")
    machine.pc = machine.pc + 1
    local selector = machine.words[machine.pc + 1]
    if selector == nil then
      malformed("the motion program escapes its member", { pc = machine.pc })
    end
    local low = lowByte(selector)
    if low == 8 or low == 0x0A then
      machine.acc[0x68] = machine.regs[index]
    elseif low == 9 or low == 0x0B then
      machine.acc[0x6C] = machine.regs[index]
    else
      malformed("the accumulator selector escapes its vocabulary: " .. tostring(selector), {})
    end
  elseif opcode == 24 then
    machine.restoreFlag = true
  elseif opcode == 25 then
    local mode = lowByte(fetch(machine))
    if mode ~= 0x1B and mode ~= 0x1C and mode ~= 0x1D then
      malformed("the fade state escapes its vocabulary: " .. tostring(mode), {})
    end
    machine.fadeMode = mode
  elseif opcode == 26 or opcode == 27 or opcode == 28 or opcode == 29 or opcode == 30 then
    initChannel(machine, opcode - 26)
  elseif opcode == 31 then
    machine.delay = toU32(fetchImm(machine))
    machine.done = true
  elseif opcode == 32 then
    local start = lowByte(fetch(machine))
    local finish = lowByte(fetch(machine))
    local framesPer = lowByte(fetch(machine))
    local target = fetchImm(machine)
    machine.fade.active = true
    machine.fade.cur = toS32(start)
    machine.fade.endValue = toS32(finish)
    machine.fade.counter = 0
    machine.fade.length = toU32(framesPer)
    machine.fade.target = toS32(target)
    machine.fade.started = true
  elseif opcode == 33 then
    if machine.fade.active then
      machine.fadeWait = true
      machine.done = true
    end
  else
    malformed("the motion program selects no operation: " .. tostring(opcode), {})
  end
end

-- One native tick of the motion task, transcribing sub_020170C4 with its
-- channel phase, restore/fade gating, and finish teardown.
local function motionTick(machine)
  if machine.destroyed then
    return
  end
  if machine.delay > 0 then
    machine.delay = machine.delay - 1
  else
    machine.done = false
    local idle = 0
    for index = 1, 4 do
      local channel = machine.channels[index]
      if channel == nil or channel.active == false then
        idle = idle + 1
      elseif channel.delay > 0 then
        channel.delay = channel.delay - 1
      else
        runChannelWorker(machine, channel)
      end
    end
    if idle == 4 then
      machine.restoreFlag = false
    end
    if not machine.restoreFlag then
      if machine.fadeWait then
        if machine.fade.active then
          -- The burst waits for the palette fade to converge.
        else
          machine.fadeWait = false
        end
      end
      if not (machine.fadeWait and machine.fade.active) then
        for _ = 1, BURST_LIMIT do
          local opcode = peek(machine)
          if opcode < 0 or opcode >= OPCODE_COUNT then
            malformed("the motion program selects no operation: " .. tostring(opcode), {})
          end
          executeOpcode(machine, opcode)
          if machine.finished then
            break
          end
          machine.pc = machine.pc + 1
          if machine.done then
            break
          end
          -- A raised restore flag applies once and ends the burst
          -- here, so channel blocks animate across ticks.
          if machine.restoreFlag then
            applyRestore(machine)
            break
          end
        end
        if not machine.finished and not machine.done and not machine.restoreFlag then
          machine.finished = true
        end
      end
    else
      applyRestore(machine)
    end
  end
  if machine.finished then
    machine.destroyed = true
  end
end

-- One native tick of the palette fade stepper, transcribing the
-- fade-advance branch of the picture manager update: the blend applies at
-- the current coefficient, then the coefficient walks toward its end.
local function fadeTick(machine)
  local fade = machine.fade
  if not fade.active then
    return
  end
  if fade.counter == 0 then
    fade.counter = fade.length
    local target = bit.band(fade.target, 0x7FFF)
    machine.lastBlend = {
      target = {
        r = bit.band(target, 31),
        g = bit.band(bit.rshift(target, 5), 31),
        b = bit.band(bit.rshift(target, 10), 31),
      },
      coefficient = fade.cur,
    }
    if fade.cur == fade.endValue then
      fade.active = false
    elseif fade.cur > fade.endValue then
      fade.cur = fade.cur - 1
    else
      fade.cur = fade.cur + 1
    end
  else
    fade.counter = fade.counter - 1
  end
end

local function newFrameState(script)
  local state = {
    script = script,
    active = false,
    id = 0,
    step = 0,
    delay = 0,
    xOffset = 0,
    timers = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
  }
  if script[1].next ~= -1 then
    state.active = true
    state.step = script[1].next
    state.delay = script[1].duration
    state.xOffset = script[1].xOffset
  end
  return state
end

local function checkScriptId(id, what)
  if id < 0 or id >= SCRIPT_COUNT then
    malformed("the frame script escapes its records: " .. tostring(what), { id = id })
  end
  return id + 1
end

-- One native tick of the frame interpreter, transcribing
-- `Pokepic_RunAnimInternal`.
local function frameTick(state)
  if not state.active then
    return
  end
  if state.delay == 0 then
    local id = state.id + 1
    local record = nil
    while true do
      -- Advancing past the last record finishes the animation, exactly
      -- as the source out-of-range check does.
      if id >= SCRIPT_COUNT then
        break
      end
      record = state.script[checkScriptId(id, "loop")]
      if record.next >= -1 then
        break
      end
      state.timers[id + 1] = state.timers[id + 1] + 1
      if record.duration == state.timers[id + 1] or record.duration == 0 then
        state.timers[id + 1] = 0
        id = id + 1
      else
        id = -2 - record.next
        if id < 0 then
          malformed("the frame script escapes its records: loop", { id = id })
        end
      end
    end
    if id >= SCRIPT_COUNT or record == nil or record.next == -1 then
      state.step = 0
      state.active = false
      state.xOffset = 0
    else
      state.step = record.next
      state.delay = record.duration
      state.xOffset = record.xOffset
    end
    state.id = id
  else
    state.delay = state.delay - 1
  end
end

local function sampleOf(machine, frame)
  local sample = {
    durationTicks = 1,
    frameIndex = frame.step,
    offsetX = frame.xOffset + (machine.attrs[ATTR_X] - ANCHOR_X),
    offsetY = (machine.attrs[ATTR_Y] or 0) - ANCHOR_Y,
    scaleX = (machine.attrs[ATTR_AFFINEW] or AFFINE_UNIT) / AFFINE_UNIT,
    scaleY = (machine.attrs[ATTR_AFFINEH] or AFFINE_UNIT) / AFFINE_UNIT,
    rotationTurns = (machine.attrs[ATTR_ZROT] or 0) / ROTATION_UNIT,
    visible = (machine.attrs[ATTR_VISIBLE] or 0) ~= 0,
  }
  local blend = machine.lastBlend
  if blend ~= nil and blend.coefficient ~= 0 then
    sample.paletteBlend = {
      target = { r = blend.target.r, g = blend.target.g, b = blend.target.b },
      coefficient = blend.coefficient,
    }
  end
  return sample
end

local function samplesEqual(left, right)
  if
    left.frameIndex ~= right.frameIndex
    or left.offsetX ~= right.offsetX
    or left.offsetY ~= right.offsetY
    or left.scaleX ~= right.scaleX
    or left.scaleY ~= right.scaleY
    or left.rotationTurns ~= right.rotationTurns
    or left.visible ~= right.visible
  then
    return false
  end
  local leftBlend, rightBlend = left.paletteBlend, right.paletteBlend
  if (leftBlend == nil) ~= (rightBlend == nil) then
    return false
  end
  if leftBlend ~= nil and rightBlend ~= nil then
    return leftBlend.coefficient == rightBlend.coefficient
      and leftBlend.target.r == rightBlend.target.r
      and leftBlend.target.g == rightBlend.target.g
      and leftBlend.target.b == rightBlend.target.b
  end
  return true
end

local function stateKey(machine, frame)
  local parts = {
    "pc=" .. machine.pc,
    "delay=" .. machine.delay,
    "loop=" .. tostring(machine.loopStart) .. ":" .. machine.loopCount .. ":" .. machine.loopTotal,
    "flags=" .. tostring(machine.restoreFlag) .. "," .. machine.fadeMode .. "," .. tostring(machine.fadeWait),
    "regs=" .. table.concat(machine.regs, ","),
    "acc="
      .. machine.acc[0x60]
      .. ","
      .. machine.acc[0x64]
      .. ","
      .. machine.acc[0x68]
      .. ","
      .. machine.acc[0x6C]
      .. ","
      .. machine.acc[0x70]
      .. ","
      .. machine.acc[0x74]
      .. ","
      .. machine.acc[0x78],
    "attrs=" .. tostring(machine.attrs[ATTR_X]) .. "," .. tostring(machine.attrs[ATTR_Y]) .. "," .. tostring(
      machine.attrs[ATTR_ZROT]
    ) .. "," .. tostring(machine.attrs[ATTR_AFFINEW]) .. "," .. tostring(machine.attrs[ATTR_AFFINEH]) .. "," .. tostring(
      machine.attrs[ATTR_VISIBLE]
    ),
    "fade="
      .. tostring(machine.fade.active)
      .. ","
      .. machine.fade.cur
      .. ","
      .. machine.fade.endValue
      .. ","
      .. machine.fade.counter
      .. ","
      .. machine.fade.length
      .. ","
      .. machine.fade.target,
    "frame="
      .. tostring(frame.active)
      .. ","
      .. frame.id
      .. ","
      .. frame.step
      .. ","
      .. frame.delay
      .. ","
      .. frame.xOffset
      .. ","
      .. table.concat(frame.timers, ","),
  }
  for index = 1, 4 do
    local channel = machine.channels[index]
    if channel == nil or channel.active == false then
      parts[#parts + 1] = "ch" .. index .. "=-"
    else
      parts[#parts + 1] = "ch"
        .. index
        .. "="
        .. channel.kind
        .. ":"
        .. channel.count
        .. ":"
        .. channel.delay
        .. ":"
        .. channel.output
        .. ":"
        .. table.concat(channel.params, ",")
    end
  end
  return table.concat(parts, "|")
end

-- Simulates one picture track to its exact end: the motion task runs to
-- its teardown while the frame interpreter runs to its terminal record.
-- Identical complete samples compress into single runs; a repeated
-- complete interpreter state proves a cycle instead of a longer track.
local function simulate(words, record)
  local machine = newMachine(words, record)
  local frame = newFrameState(record.script)
  local samples = {}
  local seen = {}
  local tick = 0
  while true do
    if tick >= SummaryPictureCompiler.TICK_BUDGET then
      malformed("the picture animation exceeds its tick budget", { ticks = tick })
    end
    local key = stateKey(machine, frame)
    local first = seen[key]
    if first ~= nil then
      local track = { samples = {}, loopFrom = first + 1 }
      for index = 1, #samples do
        track.samples[index] = samples[index]
      end
      return track
    end
    seen[key] = #samples
    motionTick(machine)
    fadeTick(machine)
    frameTick(frame)
    local sample = sampleOf(machine, frame)
    local previous = samples[#samples]
    if previous ~= nil and samplesEqual(previous, sample) then
      previous.durationTicks = previous.durationTicks + 1
    else
      samples[#samples + 1] = sample
    end
    tick = tick + 1
    if machine.destroyed and not frame.active and not machine.fade.active then
      return { samples = samples, terminal = {} }
    end
  end
end

---@param romFs table<string, unknown>
---@param selections table[]
---@return table<string, unknown>|nil bundle
---@return unknown? error
function SummaryPictureCompiler.compile(romFs, selections)
  if romFs == nil or type(romFs.openNarc) ~= "function" then
    sourceError("picture compilation requires a source archive reader", {})
  end
  if type(selections) ~= "table" then
    sourceError("picture compilation requires its selections", {})
  end
  local ok, result = xpcall(function()
    local dependencies = {}
    local metadata = openArchive(romFs, "NARC_a_1_8_0", "picture metadata")
    local metadataBytes = readMember(metadata, 0, "picture metadata", dependencies)
    local motion = openArchive(romFs, "NARC_a_0_9_0", "motion programs")
    local memberCount = motion:memberCount()
    local programs = {}
    local tracks = {}
    local used = {}
    for _, selection in ipairs(selections) do
      assert(type(selection) == "table" and type(selection.key) == "string", "picture selections carry keys")
      local species = selection.species
      if selection.egg == true then
        -- Eggs own no metadata record (494 records cover species 0-493);
        -- record 0 is the empty record, so the egg track reuses its
        -- static timing while the egg artwork resolves separately.
        species = 0
      end
      if type(species) ~= "number" or species % 1 ~= 0 then
        sourceError("the picture selection names no species", { key = selection.key })
      end
      ---@cast species integer
      local record = decodeRecord(metadataBytes, species, "picture metadata")
      local programId = record.program
      if programId >= PROGRAM_FALLBACK_LIMIT then
        programId = 0
      end
      if programId >= memberCount then
        sourceError("the motion program is missing", { program = programId, members = memberCount })
      end
      local words = programs[programId]
      if words == nil then
        words = readWords(readMember(motion, programId, "motion programs", dependencies), "motion programs")
        programs[programId] = words
      end
      local okTrack, track = xpcall(function()
        return simulate(words, record)
      end, function(e)
        if Errors.is(e) then
          return e
        end
        return { raw = e, trace = debug.traceback("", 2) }
      end)
      if not okTrack then
        if Errors.is(track) then
          ---@cast track Errors.Error
          track.context = track.context or {}
          track.context.selection = selection.key
          track.context.species = species
          track.context.program = programId
          error(track, 0)
        end
        error(track.raw, 0)
      end
      assert(track ~= nil, "missing picture tracks fail above")
      track.cryDelayTicks = record.cryDelay
      track.placement = record.placement
      tracks[selection.key] = track
      used[programId] = true
    end
    local programList = {}
    for programId in pairs(used) do
      programList[#programList + 1] = programId
    end
    table.sort(programList)
    return { tracks = tracks, programs = programList, dependencies = dependencies }
  end, function(e)
    if Errors.is(e) then
      return e
    end
    return { raw = e, trace = debug.traceback("", 2) }
  end)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  if type(result) == "table" and result.trace then
    error(result.raw, 0)
  end
  error(result, 0)
end

return SummaryPictureCompiler
