-- Closed normalized battle-animation operation inventory for the
-- battle-private interpreter. Every entry of the native dispatch table
-- (asm/battle_anim_data.s sBattleAnimScriptCmdTable, 88 entries) has a
-- C03 normalization rule in romdump; this module gives each normalized
-- operation its execution disposition. It owns no state: the player
-- builds one capability facade per occurrence and this module drives the
-- program counter, scratch values, loop/call stacks, waits, voices,
-- leases, and task construction through that facade.
-- Native step loop: src/battle/battle_anim_system.c
-- BattleAnimSystem_ExecuteCommands runs immediate instructions in one
-- quantum until a delay parks it; waits re-dispatch their own operation
-- while pending (WaitForTasks, WaitForSoundTasks, WaitForParticles) and
-- End completes only after particles, both task counters, and voices
-- drain (with the 90-tick voice escape).

---@class BattleAnimationExec player capability facade behind one occurrence
---@field advance fun() move to the next instruction in stream order
---@field jump fun(target: unknown) move to a validated instruction index
---@field park fun(wait: table<string, unknown>): string yield the source quantum on a named wait
---@field wait fun(): table<string, unknown>? current parked wait, when present
---@field setWait fun(wait: table<string, unknown>) replace the parked wait
---@field clearWait fun() drop the parked wait after its condition releases
---@field fail fun(reason: string) tear down and fail the occurrence with provenance
---@field spawn fun(kind: unknown, group: string, args: table<string, unknown>): table<string, unknown>? construct and own one factory task
---@field lease fun(key: unknown): table<string, unknown>? stage one launch-owned resource lease
---@field play fun(key: unknown, extra: unknown?): string? start and own one voice
---@field playCry fun(values: table<integer, integer>): string? start and own one cry voice
---@field stopSound fun(sound: unknown) stop every owned unfinished voice behind one sound
---@field voiceFinished fun(key: string): boolean? true once the owned voice needs no further wait
---@field unfinishedVoice fun(): string? most recent unfinished owned sound voice, when present
---@field unfinishedCry fun(): string? most recent unfinished owned cry voice, when present
---@field cryFinished fun(): boolean? true once owned cry voices need no further wait
---@field stageVoice fun(index: integer): string? stage, start, and monitor one awaited voice
---@field retireVoiceMonitor fun(voice: string) dispose the monitor behind a released voice wait
---@field count fun(group: string): integer owned unretired tasks behind one native counter
---@field rawCompleted fun(): boolean true once a raw task retired through completion
---@field getParam fun(slot: integer): integer read one scratch parameter
---@field setParam fun(slot: integer, value: integer) write one scratch parameter
---@field zeroParams fun() clear the ten-slot scratch context
---@field callDepth fun(): integer current subprogram nesting depth
---@field pushCall fun(target: integer) push one validated return destination
---@field popCall fun(): integer? pop one return destination, when present
---@field loopBegin fun(count: integer, start: integer): boolean claim one free loop slot
---@field loopAdvance fun(): string advance the innermost active loop
---@field loopStart fun(): integer rewind destination behind the innermost active loop
---@field activationFor fun(selector: integer): table<string, unknown>? resolve one battler identity
---@field movePhase fun(): string? admitted occurrence move phase ("charge" or "direct"), when carried
---@field topology fun(): table<string, unknown>? event-time semantic slots behind pair selection, when carried
---@field eventIdentity fun(): table<string, unknown>? event identity behind pair diagnostics, when carried
---@field note fun(entry: table<string, unknown>) journal one visual intent under ownership

---@class BattleAnimationCommands
local BattleAnimationCommands = {}

-- Operations that yield the source quantum while pending. A static
-- control cycle is only a zero-time cycle when no operation on the cycle
-- can park: loop-slot rewinds are bounded by their admitted count, so
-- only conditional and call edges participate in cycle detection.
BattleAnimationCommands.WAIT_CLASS_OPS = {
  ["wait-interpreter-counter"] = true,
  ["interpreter-wait"] = true,
  ["wait-for-sound"] = true,
  ["wait-for-battler-effects"] = true,
  ["wait-for-cry"] = true,
  ["wait-for-confirm-input"] = true,
  ["wait-for-battle-phase"] = true,
}

---@param count integer instruction count under admission
---@param target unknown branch destination under validation
---@return boolean inside true for a validated instruction index
local function validTarget(count, target)
  return type(target) == "number" and target % 1 == 0 and target >= 1 and target <= count + 1
end

-- Validates one instruction beyond the shared program shape: every
-- control destination must land on an instruction boundary (or the
-- stream-end boundary), and every task-spawning operation must name the
-- task kind the factory constructs. Structural failures return false so
-- the player can refuse admission without raising.
---@param instruction table<string, unknown> normalized instruction under admission
---@param index integer one-based instruction position under validation
---@param count integer instruction count bounding control destinations
---@return boolean admitted
---@return string? reason structural rejection cause under diagnosis
function BattleAnimationCommands.admit(instruction, index, count)
  local _ = index
  if type(instruction) ~= "table" then
    return false, "instruction is not a record"
  end
  local op = instruction.op
  if type(op) ~= "string" then
    return false, "instruction carries no operation"
  end
  for _, field in ipairs({ "target", "branchTarget", "alternateTarget", "returnTarget", "resumeTarget" }) do
    local target = instruction[field]
    if target ~= nil and not validTarget(count, target) then
      return false, field .. " leaves the instruction stream"
    end
  end
  local cases = instruction.branchCases
  if cases ~= nil then
    if type(cases) ~= "table" then
      return false, "branch cases are not a record"
    end
    for caseIndex, case in ipairs(cases) do
      if type(case) ~= "table" or not validTarget(count, case.target) then
        return false, "branch case " .. caseIndex .. " leaves the instruction stream"
      end
    end
  end
  for _, rule in ipairs({ "taskInputRule", "taskStartRule" }) do
    local value = instruction[rule]
    if value ~= nil and (type(value) ~= "string" or value == "") then
      return false, rule .. " is not a passthrough rule string"
    end
  end
  if op == "branch-on-parameter" then
    local values = instruction.values
    if type(values) ~= "table" or #values ~= 2 then
      return false, "parameter branches carry their slot and expected value"
    end
    if type(values[1]) ~= "number" or values[1] % 1 ~= 0 or values[1] < 0 or values[1] > 9 then
      return false, "parameter branches address the ten-slot scratch context"
    end
  end
  if op == "reserve-loop-slot" then
    local values = instruction.values
    if type(values) ~= "table" or type(values[1]) ~= "number" or values[1] % 1 ~= 0 or values[1] < 1 then
      return false, "loop slots reserve a positive iteration count"
    end
  end
  local spawnersRequiringKind = {
    ["schedule-battle-task"] = true,
    ["start-visual-task"] = true,
    ["update-battle-visual"] = true,
    ["start-sprite-effect"] = true,
    ["submit-sound-action"] = true,
    ["submit-battle-action"] = true,
    ["start-battler-effect"] = true,
    ["create-parameterized-battler-effect"] = true,
    ["create-battler-effect"] = true,
    ["create-configured-sprite"] = true,
  }
  if spawnersRequiringKind[op] and (type(instruction.taskKind) ~= "string" or instruction.taskKind == "") then
    return false, op .. " names no task kind"
  end
  if op == "replace-parameters-and-call" then
    if type(instruction.callback) ~= "string" or instruction.callback == "" then
      return false, "parameter calls name their semantic callback"
    end
  end
  for _, soundOp in ipairs({ "play-sound", "stop-sound", "play-positioned-sound" }) do
    if op == soundOp and (type(instruction.sound) ~= "string" or instruction.sound == "") then
      return false, soundOp .. " names no sound"
    end
  end
  for _, resourceOp in ipairs({
    "load-battle-background",
    "load-managed-sprite-resources",
    "load-sprite-character",
    "load-sprite-palette",
    "load-sprite-cell",
    "load-sprite-animation",
    "create-managed-sprite",
  }) do
    if op == resourceOp and type(instruction.resourceKeys) ~= "table" then
      return false, resourceOp .. " stages no semantic resources"
    end
  end
  if op == "show-pokemon-picture" then
    local values = instruction.values
    if type(values) ~= "table" or #values ~= 2 then
      return false, "picture shows carry their battler selector and mode"
    end
    if values[2] == 1 and (type(instruction.taskKind) ~= "string" or instruction.taskKind == "") then
      return false, "animated picture shows name their picture task kind"
    end
  end
  for _, waitOp in ipairs({ "wait-for-cry", "wait-for-confirm-input", "wait-for-battle-phase" }) do
    if op == waitOp and (type(instruction.values) ~= "table" or #instruction.values < 1) then
      return false, waitOp .. " carries no wait operand"
    end
  end
  return true, nil
end

---@param instructions table<integer, table<string, unknown>> normalized stream under analysis
---@param index integer one-based instruction position
---@return integer[] static successor positions excluding bounded loop rewinds
local function successors(instructions, index)
  local instruction = instructions[index]
  local next = {}
  local count = #instructions
  local function link(target)
    if validTarget(count, target) and target <= count then
      next[#next + 1] = target
    end
  end
  local op = instruction.op
  if op == "source-assertion" then
    return next
  end
  if op ~= "call-subprogram" and op ~= "skip-words" then
    link(index + 1)
  end
  if op == "skip-words" then
    link(instruction.target)
  else
    link(instruction.branchTarget)
    link(instruction.alternateTarget)
    link(instruction.returnTarget)
    link(instruction.resumeTarget)
  end
  if type(instruction.branchCases) == "table" then
    for _, case in ipairs(instruction.branchCases) do
      if type(case) == "table" then
        link(case.target)
      end
    end
  end
  return next
end

-- Detects a static zero-time control cycle: a control-flow cycle whose
-- operations can never park the source quantum. Conditional self-loops
-- and branch/call rings without a wait-class operation would spin inside
-- one native ExecuteCommands quantum forever, so they are malformed
-- data. Bounded loop-slot rewinds never participate: their admitted
-- count guarantees termination.
---@param instructions table<integer, table<string, unknown>> normalized stream under analysis
---@return table<string, unknown>? fault zero-time cycle provenance when malformed
function BattleAnimationCommands.checkCycles(instructions)
  local color = {}
  local stack = {}
  local function visit(node)
    color[node] = "open"
    stack[#stack + 1] = node
    for _, nextNode in ipairs(successors(instructions, node)) do
      if color[nextNode] == "open" then
        local cycle = {}
        local inside = false
        for _, frame in ipairs(stack) do
          if frame == nextNode then
            inside = true
          end
          if inside then
            cycle[#cycle + 1] = frame
          end
        end
        local parks = false
        for _, frame in ipairs(cycle) do
          if BattleAnimationCommands.WAIT_CLASS_OPS[instructions[frame].op] then
            parks = true
            break
          end
        end
        if not parks then
          return {
            index = nextNode,
            op = instructions[nextNode].op,
            reason = "zero-time control cycle without a source yield",
          }
        end
      elseif color[nextNode] == nil then
        local fault = visit(nextNode)
        if fault ~= nil then
          return fault
        end
      end
    end
    stack[#stack] = nil
    color[node] = "closed"
    return nil
  end
  for index = 1, #instructions do
    if color[index] == nil then
      local fault = visit(index)
      if fault ~= nil then
        return fault
      end
    end
  end
  return nil
end

local function executeTickWait(exec, instruction, index)
  local wait = exec.wait()
  if wait ~= nil and wait.kind == "tick" and wait.index == index then
    wait.remaining = wait.remaining - 1
    if wait.remaining <= 0 then
      exec.clearWait()
      exec.advance()
      return "continue"
    end
    return exec.park(wait)
  end
  local values = instruction.values --[[@as table<integer, integer>]]
  if values[1] <= 0 then
    exec.advance()
    return "continue"
  end
  return exec.park({ kind = "tick", index = index, remaining = values[1] })
end

local function executeStagingWait(exec, instruction, index)
  local _ = instruction
  local wait = exec.wait()
  if wait ~= nil and wait.kind == "staging" and wait.index == index then
    wait.remaining = wait.remaining - 1
    if wait.remaining <= 0 then
      exec.clearWait()
      exec.advance()
      return "continue"
    end
    return exec.park(wait)
  end
  return exec.park({ kind = "staging", index = index, remaining = 2 })
end

local function executeSoundWait(exec, instruction, index)
  local _ = instruction
  local voice = exec.unfinishedVoice()
  if voice == nil then
    -- First execution arms the wait and lets the immediate chain
    -- proceed: downstream work, including the tasks a later effects
    -- wait names, must still construct in this quantum. A later visit
    -- parks while the staged voice remains unfinished.
    if exec.stageVoice(index) == nil then
      return "done"
    end
    exec.advance()
    return "continue"
  end
  local wait = exec.wait()
  if wait == nil or wait.kind ~= "voice" or wait.voice ~= voice then
    local parked = { kind = "voice", index = index, voice = voice, parked = 0 }
    exec.setWait(parked)
    return exec.park(parked)
  end
  local finished = exec.voiceFinished(voice)
  if finished == nil then
    return "done"
  end
  if finished then
    exec.retireVoiceMonitor(voice)
    exec.clearWait()
    exec.advance()
    return "continue"
  end
  wait.parked = wait.parked + 1
  if wait.parked > 90 then
    exec.retireVoiceMonitor(voice)
    exec.clearWait()
    exec.advance()
    return "continue"
  end
  return exec.park(wait)
end

---@type table<string, fun(exec: BattleAnimationExec, instruction: table<string, unknown>, index: integer): string>
local Handlers = {}

function Handlers.noop(exec, instruction, index)
  local _ = instruction
  local _ = index
  exec.advance()
  return "continue"
end

local function handleInterpreterWait(exec, instruction, index)
  return executeTickWait(exec, instruction, index)
end
Handlers["interpreter-wait"] = handleInterpreterWait

local function handleWaitInterpreterCounter(exec, instruction, index)
  local _ = instruction
  local _ = index
  if exec.count("general") == 0 then
    exec.advance()
    return "continue"
  end
  return exec.park({ kind = "counter", index = index })
end
Handlers["wait-interpreter-counter"] = handleWaitInterpreterCounter

local function handleWaitForSound(exec, instruction, index)
  return executeSoundWait(exec, instruction, index)
end
Handlers["wait-for-sound"] = handleWaitForSound

-- Bounded backstop behind battler-effects waits: a stuck task can
-- never hang the occurrence, and the release is journaled instead of
-- passing silently.
local EFFECTS_ESCAPE_TICKS = 16

local function handleWaitForBattlerEffects(exec, instruction, index)
  local _ = instruction
  local function released(wait)
    if wait ~= nil and wait.kind == "effects" and wait.index == index then
      exec.clearWait()
    end
  end
  -- Particle work drains completely; raw visual work releases on its
  -- first completion because unawaited raw tasks stay owned past the
  -- main stream by design.
  if exec.count("particle") == 0 and (exec.count("raw") == 0 or exec.rawCompleted()) then
    released(exec.wait())
    exec.advance()
    return "continue"
  end
  local wait = exec.wait()
  if wait == nil or wait.kind ~= "effects" or wait.index ~= index then
    local parked = { kind = "effects", index = index, parked = 0 }
    exec.setWait(parked)
    return exec.park(parked)
  end
  wait.parked = wait.parked + 1
  if wait.parked > EFFECTS_ESCAPE_TICKS then
    exec.note({ op = "wait-for-battler-effects", index = index, escape = "effects-wait backstop" })
    exec.clearWait()
    exec.advance()
    return "continue"
  end
  return exec.park(wait)
end
Handlers["wait-for-battler-effects"] = handleWaitForBattlerEffects

local function handleWaitForCry(exec, instruction, index)
  if exec.unfinishedCry() == nil then
    exec.jump(instruction.alternateTarget)
    return "continue"
  end
  local finished = exec.cryFinished()
  if finished == nil then
    return "done"
  end
  if finished then
    exec.jump(instruction.alternateTarget)
    return "continue"
  end
  exec.jump(instruction.branchTarget)
  return exec.park({ kind = "cry", index = index })
end
Handlers["wait-for-cry"] = handleWaitForCry

local function handleWaitForConfirmInput(exec, instruction, index)
  local _ = instruction
  local _ = index
  exec.fail("confirm-input waits need a playback confirm context the packet does not carry")
  return "done"
end
Handlers["wait-for-confirm-input"] = handleWaitForConfirmInput

local function handleWaitForBattlePhase(exec, instruction, index)
  local _ = instruction
  local _ = index
  exec.fail("battle-phase waits need a playback phase context the packet does not carry")
  return "done"
end
Handlers["wait-for-battle-phase"] = handleWaitForBattlePhase

local function handleSetParameter(exec, instruction, index)
  local _ = index
  local values = instruction.values --[[@as table<integer, integer>]]
  if values[1] >= 0 and values[1] < 10 then
    exec.setParam(values[1], values[2])
  end
  exec.advance()
  return "continue"
end
Handlers["set-parameter"] = handleSetParameter

local function handleClearParameters(exec, instruction, index)
  local _ = instruction
  local _ = index
  exec.zeroParams()
  exec.advance()
  return "continue"
end
Handlers["clear-parameters"] = handleClearParameters

local function handleBranchOnParameter(exec, instruction, index)
  local _ = index
  local values = instruction.values --[[@as table<integer, integer>]]
  if exec.getParam(values[1]) == values[2] then
    exec.jump(instruction.branchTarget)
  else
    exec.advance()
  end
  return "continue"
end
Handlers["branch-on-parameter"] = handleBranchOnParameter

local function failContextField(exec, name)
  exec.fail(name .. " reads a battle context field the playback packet does not carry")
  return "done"
end

local function handleBranchOnInterpreterState(exec, instruction, index)
  local _ = instruction
  local _ = index
  return failContextField(exec, "interpreter-state branches")
end
Handlers["branch-on-interpreter-state"] = handleBranchOnInterpreterState

local function handleBranchOnBattleField(exec, instruction, index)
  local _ = instruction
  local _ = index
  return failContextField(exec, "battle-field branches")
end
Handlers["branch-on-battle-field"] = handleBranchOnBattleField

-- Charge/strike dispatch behind native opcode 13 (ov07_0221D148 at
-- pret/pokeheartgold asm/overlay_07.s:2712-2737, dispatch index 13 at
-- asm/overlay_07.s:51439-51453): the handler tests bit 0 of the
-- battle-flag halfword and reads the first script word (the
-- compiler-lowered alternateTarget) when the bit is clear, the second
-- word (the branchTarget) when the bit is set. Charge-turn executions
-- observe the bit clear and strike-turn executions observe it set, so
-- the charge occurrence advances through the fallthrough charge half
-- and the direct (strike) occurrence jumps to the strike half. Any
-- other operand, or a missing or malformed move phase, fails closed
-- with provenance instead of guessing a presentation path.
local function handleBranchOnBattleFlag(exec, instruction, index)
  local _ = index
  local values = instruction.values --[[@as table<integer, integer>?]]
  if type(values) == "table" and #values == 1 and values[1] == 1 then
    local phase = exec.movePhase()
    if phase == nil then
      return failContextField(exec, "battle-flag branches")
    end
    if phase == "charge" then
      exec.advance()
    else
      exec.jump(instruction.branchTarget)
    end
    return "continue"
  end
  return failContextField(exec, "battle-flag branches")
end
Handlers["branch-on-battle-flag"] = handleBranchOnBattleFlag

local function handleBranchOnSideMask(exec, instruction, index)
  local _ = instruction
  local _ = index
  return failContextField(exec, "side-mask branches")
end
Handlers["branch-on-side-mask"] = handleBranchOnSideMask

-- Native side classes behind ov07_0223192C: an even native battler
-- position (the player side) reads class 3, an odd position (the foe
-- side) reads class 4. The locked event topology already carries the
-- native sideType 0..5 per battler, so the class follows sideType
-- parity; the semantic slot name covers records that carry no type.
local PLAYER_SIDE_SLOTS = {
  ["solo-player"] = true,
  ["player-side-slot-1"] = true,
  ["player-side-slot-2"] = true,
}
local ENEMY_SIDE_SLOTS = {
  ["solo-enemy"] = true,
  ["enemy-side-slot-1"] = true,
  ["enemy-side-slot-2"] = true,
}

---@param record table<string, unknown>? topology battler entry under classification
---@return string? side native side class: "player" (class 3) or "enemy" (class 4)
local function sideClassOf(record)
  if type(record) ~= "table" then
    return nil
  end
  local sideType = record.sideType
  if sideType ~= nil then
    if type(sideType) == "number" and sideType % 1 == 0 and sideType >= 0 and sideType <= 5 then
      if sideType % 2 == 0 then
        return "player"
      end
      return "enemy"
    end
    return nil
  end
  if PLAYER_SIDE_SLOTS[record.slot] then
    return "player"
  end
  if ENEMY_SIDE_SLOTS[record.slot] then
    return "enemy"
  end
  return nil
end

---@param exec BattleAnimationExec player capability facade behind one occurrence
---@return table<string, unknown>? topology event-time semantic slots behind side branches, when carried
local function lockedTopology(exec)
  if type(exec.topology) ~= "function" then
    return nil
  end
  local ok, resolved = pcall(exec.topology)
  if ok and type(resolved) == "table" then
    return resolved --[[@as table<string, unknown>]]
  end
  return nil
end

local function handleBranchOnSidePredicate(exec, instruction, index)
  local _ = index
  local values = instruction.values --[[@as table<integer, integer>?]]
  if type(values) ~= "table" or type(values[1]) ~= "number" then
    exec.fail("side-predicate branches carry no side selector")
    return "done"
  end
  -- ov07_0221D174 tests the attacker side on selector zero and the
  -- target side on any other selector, then takes its special branch
  -- target only on the enemy side class.
  local topology = lockedTopology(exec)
  local side = nil ---@type string?
  local targetCount = 0
  if type(topology) == "table" then
    if values[1] == 0 then
      side = sideClassOf(topology.attacker --[[@as table<string, unknown>?]])
    else
      local targets = topology.targets --[[@as table<integer, table<string, unknown>>?]]
      if type(targets) == "table" then
        targetCount = #targets
        if targetCount == 1 then
          side = sideClassOf(targets[1])
        end
      end
    end
  end
  if side == nil then
    if targetCount > 1 then
      exec.fail("side-predicate branches need one event target but the packet carries " .. tostring(targetCount))
    else
      exec.fail("side-predicate branches read a battle side the playback packet does not carry")
    end
    return "done"
  end
  if side == "enemy" then
    exec.jump(instruction.branchTarget)
  else
    exec.jump(instruction.alternateTarget)
  end
  return "continue"
end
Handlers["branch-on-side-predicate"] = handleBranchOnSidePredicate

local function handleBranchOnSideEquality(exec, instruction, index)
  local _ = index
  -- ov07_0221D270 compares the attacker side class against the target
  -- side class: equal sides take the count-derived branch target,
  -- mixed sides fall through to the alternate target. A spread names
  -- no single native target, so it fails instead of guessing one.
  local topology = lockedTopology(exec)
  local attackerSide = sideClassOf(type(topology) == "table" and topology.attacker or nil)
  local targetSide = nil ---@type string?
  local targetCount = 0
  if type(topology) == "table" and type(topology.targets) == "table" then
    local targets = topology.targets --[[@as table<integer, table<string, unknown>>]]
    targetCount = #targets
    if targetCount == 1 then
      targetSide = sideClassOf(targets[1])
    end
  end
  if attackerSide == nil or targetSide == nil then
    if targetCount > 1 then
      exec.fail("side-equality branches need one event target but the packet carries " .. tostring(targetCount))
    else
      exec.fail("side-equality branches read a battle side the playback packet does not carry")
    end
    return "done"
  end
  if attackerSide == targetSide then
    exec.jump(instruction.branchTarget)
  else
    exec.jump(instruction.alternateTarget)
  end
  return "continue"
end
Handlers["branch-on-side-equality"] = handleBranchOnSideEquality

local function handleBranchOnPictureState(exec, instruction, index)
  local _ = instruction
  local _ = index
  return failContextField(exec, "picture-state branches")
end
Handlers["branch-on-picture-state"] = handleBranchOnPictureState

local function handleCallSubprogram(exec, instruction, index)
  local _ = index
  if exec.callDepth() >= 3 then
    exec.fail("subprogram calls exceed the three native return slots")
    return "done"
  end
  exec.pushCall(instruction.returnTarget)
  exec.jump(instruction.branchTarget)
  return "continue"
end
Handlers["call-subprogram"] = handleCallSubprogram

local function handleReturnSubprogram(exec, instruction, index)
  local _ = instruction
  local _ = index
  local target = exec.popCall()
  if target ~= nil then
    exec.jump(target)
  else
    exec.advance()
  end
  return "continue"
end
Handlers["return-subprogram"] = handleReturnSubprogram

local function handleReserveLoopSlot(exec, instruction, index)
  local _ = index
  local values = instruction.values --[[@as table<integer, integer>]]
  if not exec.loopBegin(values[1], instruction.branchTarget) then
    exec.fail("loop slots are saturated")
    return "done"
  end
  exec.jump(instruction.branchTarget)
  return "continue"
end
Handlers["reserve-loop-slot"] = handleReserveLoopSlot

local function handleAdvanceLoopSlot(exec, instruction, index)
  local _ = index
  local _ = instruction
  local outcome = exec.loopAdvance()
  if outcome == "rewound" then
    exec.jump(exec.loopStart())
  else
    exec.advance()
  end
  return "continue"
end
Handlers["advance-loop-slot"] = handleAdvanceLoopSlot

local function handleSkipWords(exec, instruction, index)
  local _ = index
  exec.jump(instruction.target)
  return "continue"
end
Handlers["skip-words"] = handleSkipWords

local function handleSourceAssertion(exec, instruction, index)
  local _ = instruction
  local _ = index
  exec.fail("the native source assertion tripped")
  return "done"
end
Handlers["source-assertion"] = handleSourceAssertion

local function handleResetBattlePresentation(exec, instruction, index)
  local _ = instruction
  -- The normalized reset applies presentation-state restoration inline
  -- and never ends the occurrence on its own: lowered branch and call
  -- layouts provably emit instructions past a reset, so completion stays
  -- with the stream-end boundary and its source-condition verify.
  exec.note({ op = "reset-battle-presentation", index = index })
  exec.advance()
  return "continue"
end
Handlers["reset-battle-presentation"] = handleResetBattlePresentation

local function noteVisual(exec, instruction, index)
  exec.note({ op = instruction.op, index = index })
  exec.advance()
  return "continue"
end

local function handlePlaySound(exec, instruction, index)
  if exec.play(instruction.sound) == nil then
    return "done"
  end
  exec.note({ op = "play-sound", index = index, sound = instruction.sound })
  exec.advance()
  return "continue"
end
Handlers["play-sound"] = handlePlaySound

local function handleStopSound(exec, instruction, index)
  exec.stopSound(instruction.sound)
  exec.note({ op = "stop-sound", index = index, sound = instruction.sound })
  exec.advance()
  return "continue"
end
Handlers["stop-sound"] = handleStopSound

local function handlePlayPositionedSound(exec, instruction, index)
  local values = instruction.values --[[@as table<integer, integer>]]
  if exec.play(instruction.sound, values[1]) == nil then
    return "done"
  end
  exec.note({ op = "play-positioned-sound", index = index, sound = instruction.sound })
  exec.advance()
  return "continue"
end
Handlers["play-positioned-sound"] = handlePlayPositionedSound

local function handleStopPositionedSound(exec, instruction, index)
  local _ = instruction
  -- The operand carries source pan, not a voice identity: with no
  -- resolvable owned voice the stop is journaled for the audio adapter
  -- seam rather than aimed at an unrelated voice.
  exec.note({ op = "stop-positioned-sound", index = index })
  exec.advance()
  return "continue"
end
Handlers["stop-positioned-sound"] = handleStopPositionedSound

local function handlePlayCry(exec, instruction, index)
  local values = instruction.values --[[@as table<integer, integer>]]
  if exec.playCry(values) == nil then
    return "done"
  end
  exec.note({ op = "play-cry", index = index })
  exec.advance()
  return "continue"
end
Handlers["play-cry"] = handlePlayCry

local function spawnRaw(exec, instruction, index, group)
  local record = exec.spawn(instruction.taskKind, group, {
    values = instruction.values,
    taskInputRule = instruction.taskInputRule,
    taskStartRule = instruction.taskStartRule,
    updateKind = instruction.updateKind,
    mode = instruction.mode,
  })
  if record == nil then
    return "done"
  end
  exec.note({ op = instruction.op, index = index, task = instruction.taskKind })
  exec.advance()
  return "continue"
end

local function handleScheduleBattleTask(exec, instruction, index)
  return spawnRaw(exec, instruction, index, "raw")
end
Handlers["schedule-battle-task"] = handleScheduleBattleTask

local function handleStartVisualTask(exec, instruction, index)
  return spawnRaw(exec, instruction, index, "raw")
end
Handlers["start-visual-task"] = handleStartVisualTask

local function handleUpdateBattleVisual(exec, instruction, index)
  return spawnRaw(exec, instruction, index, "raw")
end
Handlers["update-battle-visual"] = handleUpdateBattleVisual

local function handleStartSpriteEffect(exec, instruction, index)
  return spawnRaw(exec, instruction, index, "raw")
end
Handlers["start-sprite-effect"] = handleStartSpriteEffect

local function handleSubmitSoundAction(exec, instruction, index)
  local record = exec.spawn(instruction.taskKind, "sound", {
    sound = instruction.sound,
    values = instruction.values,
  })
  if record == nil then
    return "done"
  end
  exec.note({ op = "submit-sound-action", index = index, task = instruction.taskKind })
  exec.advance()
  return "continue"
end
Handlers["submit-sound-action"] = handleSubmitSoundAction

local function handleSubmitBattleAction(exec, instruction, index)
  local record = exec.spawn(instruction.taskKind, "general", { values = instruction.values })
  if record == nil then
    return "done"
  end
  exec.note({ op = "submit-battle-action", index = index, task = instruction.taskKind })
  exec.advance()
  return "continue"
end
Handlers["submit-battle-action"] = handleSubmitBattleAction

local function handleStartBattlerEffect(exec, instruction, index)
  local record = exec.spawn(instruction.taskKind, "general", { values = instruction.values })
  if record == nil then
    return "done"
  end
  exec.note({ op = "start-battler-effect", index = index, task = instruction.taskKind })
  exec.advance()
  return "continue"
end
Handlers["start-battler-effect"] = handleStartBattlerEffect

local function handleInvokeBattleAnimationCallback(exec, instruction, index)
  local record = exec.spawn(instruction.taskKind, "general", {
    callback = instruction.callback,
    taskContext = instruction.taskContext,
    battlerTarget = instruction.battlerTarget,
    parameters = instruction.parameters,
    resourceKeys = instruction.resourceKeys,
    runtimeSelection = instruction.runtimeSelection,
  })
  if record == nil then
    return "done"
  end
  exec.note({ op = "invoke-battle-animation-callback", index = index, task = instruction.taskKind })
  exec.advance()
  return "continue"
end
Handlers["invoke-battle-animation-callback"] = handleInvokeBattleAnimationCallback

local function handleReplaceParametersAndCall(exec, instruction, index)
  local record = exec.spawn(instruction.callback, "general", { values = instruction.values })
  if record == nil then
    return "done"
  end
  exec.note({ op = "replace-parameters-and-call", index = index, task = instruction.callback })
  exec.advance()
  return "continue"
end
Handlers["replace-parameters-and-call"] = handleReplaceParametersAndCall

local function handleCreateBattlerEffect(exec, instruction, index)
  -- A parked staging wait means this instruction already staged its
  -- dependency and child on its first visit: resume the wait instead
  -- of acquiring a second time. A real loop revisit after the wait
  -- cleared stages anew because no wait is held then.
  local parked = exec.wait()
  if parked ~= nil and parked.kind == "staging" and parked.index == index then
    return executeStagingWait(exec, instruction, index)
  end
  if exec.lease(instruction.resource) == nil then
    return "done"
  end
  local record = exec.spawn(instruction.taskKind, "particle", {
    emitterPosition = instruction.emitterPosition,
    resource = instruction.resource,
  })
  if record == nil then
    return "done"
  end
  exec.note({ op = "create-battler-effect", index = index, task = instruction.taskKind })
  return executeStagingWait(exec, instruction, index)
end
Handlers["create-battler-effect"] = handleCreateBattlerEffect

-- Names the effect behind a position-pair diagnostic: the admitted
-- event effect key when the occurrence carries one, otherwise the
-- normalized program identity already recorded on the failure detail.
---@param exec BattleAnimationExec player capability facade behind one occurrence
---@return string effect identity behind pair diagnostics
local function pairEffectName(exec)
  if type(exec.eventIdentity) == "function" then
    local ok, event = pcall(exec.eventIdentity)
    if ok and type(event) == "table" and type(event.effectKey) == "string" then
      return event.effectKey
    end
  end
  return "unknown effect"
end

local function handleCreateParameterizedBattlerEffect(exec, instruction, index)
  if instruction.resourceCases ~= nil then
    -- Same parked-resumption guard as the plain battler effect: the
    -- held staging wait already owns this visit's dependency and child.
    local parked = exec.wait()
    if parked ~= nil and parked.kind == "staging" and parked.index == index then
      return executeStagingWait(exec, instruction, index)
    end
    local topology = nil
    if type(exec.topology) == "function" then
      local ok, resolved = pcall(exec.topology)
      if ok and type(resolved) == "table" then
        topology = resolved --[[@as table<string, unknown>]]
      end
    end
    if type(topology) ~= "table" then
      exec.fail("runtime-selected particle resources need an emitter topology the packet does not carry")
      return "done"
    end
    local attacker = topology.attacker --[[@as table<string, unknown>?]]
    if type(attacker) ~= "table" or type(attacker.slot) ~= "string" then
      exec.fail("runtime-selected particle resources need an attacker slot the packet does not carry")
      return "done"
    end
    local targets = topology.targets --[[@as table<integer, table<string, unknown>>?]]
    if type(targets) ~= "table" or #targets == 0 then
      exec.fail("runtime-selected particle resources need an event target the packet does not carry")
      return "done"
    end
    local target = nil ---@type table<string, unknown>?
    if #targets == 1 then
      target = targets[1]
    else
      local ordinal = nil ---@type integer?
      if type(instruction.targetOrdinal) == "number" then
        ordinal = instruction.targetOrdinal --[[@as integer]]
      elseif type(instruction.battlerTarget) == "number" then
        ordinal = instruction.battlerTarget --[[@as integer]]
      end
      if type(ordinal) == "number" and targets[ordinal + 1] ~= nil then
        target = targets[ordinal + 1]
      else
        exec.fail(
          "runtime-selected particle resources need one event target but the packet carries " .. tostring(#targets)
        )
        return "done"
      end
    end
    if type(target) ~= "table" or type(target.slot) ~= "string" then
      exec.fail("runtime-selected particle resources need a target slot the packet does not carry")
      return "done"
    end
    local pairKey = attacker.slot .. "/" .. target.slot
    local effectName = pairEffectName(exec)
    local selected = instruction.resourceCases[pairKey]
    if selected == nil then
      exec.fail("native position pair " .. pairKey .. " for effect " .. effectName .. " has no published resource")
      return "done"
    end
    if selected == "source-assert" then
      exec.fail("native position pair " .. pairKey .. " for effect " .. effectName .. " is a source assertion")
      return "done"
    end
    if type(selected) ~= "string" or selected == "" then
      exec.fail("native position pair " .. pairKey .. " for effect " .. effectName .. " has no published resource")
      return "done"
    end
    if exec.lease(selected) == nil then
      return "done"
    end
    local record = exec.spawn(instruction.taskKind, "particle", {
      actionProfile = instruction.actionProfile,
      emitterPosition = instruction.emitterPosition,
      resource = selected,
      continuationSlot = instruction.continuationSlot,
      values = instruction.values,
    })
    if record == nil then
      return "done"
    end
    exec.note({ op = "create-parameterized-battler-effect", index = index, task = instruction.taskKind })
    return executeStagingWait(exec, instruction, index)
  end
  if type(instruction.resource) ~= "string" or instruction.resource == "" then
    exec.fail("parameterized battler effects stage a semantic particle resource")
    return "done"
  end
  -- Same parked-resumption guard as the plain battler effect: the
  -- held staging wait already owns this visit's dependency and child.
  local parked = exec.wait()
  if parked ~= nil and parked.kind == "staging" and parked.index == index then
    return executeStagingWait(exec, instruction, index)
  end
  if exec.lease(instruction.resource) == nil then
    return "done"
  end
  local record = exec.spawn(instruction.taskKind, "particle", {
    actionProfile = instruction.actionProfile,
    emitterPosition = instruction.emitterPosition,
    resource = instruction.resource,
    continuationSlot = instruction.continuationSlot,
    values = instruction.values,
  })
  if record == nil then
    return "done"
  end
  exec.note({ op = "create-parameterized-battler-effect", index = index, task = instruction.taskKind })
  return executeStagingWait(exec, instruction, index)
end
Handlers["create-parameterized-battler-effect"] = handleCreateParameterizedBattlerEffect

local function handleCreateConfiguredSprite(exec, instruction, index)
  for _, key in pairs(instruction.resourceKeys) do
    if exec.lease(key) == nil then
      return "done"
    end
  end
  local record = exec.spawn(instruction.taskKind, "raw", {
    taskContext = instruction.taskContext,
    parameters = instruction.parameters,
  })
  if record == nil then
    return "done"
  end
  exec.note({ op = "create-configured-sprite", index = index, task = instruction.taskKind })
  exec.advance()
  return "continue"
end
Handlers["create-configured-sprite"] = handleCreateConfiguredSprite

local function handleDestroyBattlerEffect(exec, instruction, index)
  return noteVisual(exec, instruction, index)
end
Handlers["destroy-battler-effect"] = handleDestroyBattlerEffect

local function handleShowPokemonPicture(exec, instruction, index)
  local values = instruction.values --[[@as table<integer, integer>]]
  local identity = exec.activationFor(values[1])
  if identity == nil then
    exec.fail("picture shows need a battler topology the packet does not carry")
    return "done"
  end
  if values[2] == 1 then
    local record = exec.spawn(instruction.taskKind, "raw", {
      battlerSelector = values[1],
      mode = values[2],
      activation = identity,
    })
    if record == nil then
      return "done"
    end
  end
  exec.note({ op = "show-pokemon-picture", index = index, activation = identity })
  exec.advance()
  return "continue"
end
Handlers["show-pokemon-picture"] = handleShowPokemonPicture

local function handleCreatePokemonSprite(exec, instruction, index)
  if instruction.taskKind ~= nil then
    local record = exec.spawn(instruction.taskKind, "raw", {
      values = instruction.values,
      battlerTarget = instruction.battlerTarget,
      runtimeSelection = instruction.runtimeSelection,
    })
    if record == nil then
      return "done"
    end
  end
  exec.note({ op = "create-pokemon-sprite", index = index, battlerTarget = instruction.battlerTarget })
  exec.advance()
  return "continue"
end
Handlers["create-pokemon-sprite"] = handleCreatePokemonSprite

local function handleSetPokemonPictureVanished(exec, instruction, index)
  exec.note({
    op = "set-pokemon-picture-vanished",
    index = index,
    vanished = instruction.vanished,
    pictureSets = instruction.pictureSets,
  })
  exec.advance()
  return "continue"
end
Handlers["set-pokemon-picture-vanished"] = handleSetPokemonPictureVanished

local function handleSetBlendAlpha(exec, instruction, index)
  return noteVisual(exec, instruction, index)
end
Handlers["set-blend-alpha"] = handleSetBlendAlpha

local function handleResetBlendAlpha(exec, instruction, index)
  return noteVisual(exec, instruction, index)
end
Handlers["reset-blend-alpha"] = handleResetBlendAlpha

local function handleSetBackgroundComponent(exec, instruction, index)
  return noteVisual(exec, instruction, index)
end
Handlers["set-background-component"] = handleSetBackgroundComponent

local function handleClearBackgroundPlane(exec, instruction, index)
  return noteVisual(exec, instruction, index)
end
Handlers["clear-background-plane"] = handleClearBackgroundPlane

local function handleCopyMainBackgroundPaletteToFadeBuffer(exec, instruction, index)
  return noteVisual(exec, instruction, index)
end
Handlers["copy-main-background-palette-to-fade-buffer"] = handleCopyMainBackgroundPaletteToFadeBuffer

local function handleGrayscaleMainBackgroundFadeBuffer(exec, instruction, index)
  return noteVisual(exec, instruction, index)
end
Handlers["grayscale-main-background-fade-buffer"] = handleGrayscaleMainBackgroundFadeBuffer

local function handleSubmitPresentationLayout(exec, instruction, index)
  return noteVisual(exec, instruction, index)
end
Handlers["submit-presentation-layout"] = handleSubmitPresentationLayout

local function handleSubmitPresentationUpdate(exec, instruction, index)
  return noteVisual(exec, instruction, index)
end
Handlers["submit-presentation-update"] = handleSubmitPresentationUpdate

local function handleSetManagedSpriteDrawFlag(exec, instruction, index)
  return noteVisual(exec, instruction, index)
end
Handlers["set-managed-sprite-draw-flag"] = handleSetManagedSpriteDrawFlag

local function handleSetSpriteDrawFlag(exec, instruction, index)
  return noteVisual(exec, instruction, index)
end
Handlers["set-sprite-draw-flag"] = handleSetSpriteDrawFlag

local function handleClearSpriteSlot(exec, instruction, index)
  return noteVisual(exec, instruction, index)
end
Handlers["clear-sprite-slot"] = handleClearSpriteSlot

local function handleClearEffectSlot(exec, instruction, index)
  return noteVisual(exec, instruction, index)
end
Handlers["clear-effect-slot"] = handleClearEffectSlot

local function handleDestroyEffectSlot(exec, instruction, index)
  return noteVisual(exec, instruction, index)
end
Handlers["destroy-effect-slot"] = handleDestroyEffectSlot

local function handleDeleteManagedSprite(exec, instruction, index)
  return noteVisual(exec, instruction, index)
end
Handlers["delete-managed-sprite"] = handleDeleteManagedSprite

local function handleDisposeSpriteManager(exec, instruction, index)
  return noteVisual(exec, instruction, index)
end
Handlers["dispose-sprite-manager"] = handleDisposeSpriteManager

local function handleDisposeSharedSpriteManager(exec, instruction, index)
  return noteVisual(exec, instruction, index)
end
Handlers["dispose-shared-sprite-manager"] = handleDisposeSharedSpriteManager

local function handleCreateManagedSpriteManager(exec, instruction, index)
  return noteVisual(exec, instruction, index)
end
Handlers["create-managed-sprite-manager"] = handleCreateManagedSpriteManager

local function handleCreateSpriteManager(exec, instruction, index)
  return noteVisual(exec, instruction, index)
end
Handlers["create-sprite-manager"] = handleCreateSpriteManager

local function handleClearPokemonPicture(exec, instruction, index)
  return noteVisual(exec, instruction, index)
end
Handlers["clear-pokemon-picture"] = handleClearPokemonPicture

local function handleStartBrightnessTransition(exec, instruction, index)
  return noteVisual(exec, instruction, index)
end
Handlers["start-brightness-transition"] = handleStartBrightnessTransition

local function handleSetBattlerStateByte(exec, instruction, index)
  return noteVisual(exec, instruction, index)
end
Handlers["set-battler-state-byte"] = handleSetBattlerStateByte

local function handleSetBattlerEffectByte(exec, instruction, index)
  return noteVisual(exec, instruction, index)
end
Handlers["set-battler-effect-byte"] = handleSetBattlerEffectByte

local function stageResourceKeys(exec, instruction, index)
  for _, key in pairs(instruction.resourceKeys) do
    if exec.lease(key) == nil then
      return "done"
    end
  end
  exec.note({ op = instruction.op, index = index })
  exec.advance()
  return "continue"
end

local function handleLoadBattleBackground(exec, instruction, index)
  return stageResourceKeys(exec, instruction, index)
end
Handlers["load-battle-background"] = handleLoadBattleBackground

local function handleLoadManagedSpriteResources(exec, instruction, index)
  return stageResourceKeys(exec, instruction, index)
end
Handlers["load-managed-sprite-resources"] = handleLoadManagedSpriteResources

local function handleLoadSpriteCharacter(exec, instruction, index)
  return stageResourceKeys(exec, instruction, index)
end
Handlers["load-sprite-character"] = handleLoadSpriteCharacter

local function handleLoadSpritePalette(exec, instruction, index)
  return stageResourceKeys(exec, instruction, index)
end
Handlers["load-sprite-palette"] = handleLoadSpritePalette

local function handleLoadSpriteCell(exec, instruction, index)
  return stageResourceKeys(exec, instruction, index)
end
Handlers["load-sprite-cell"] = handleLoadSpriteCell

local function handleLoadSpriteAnimation(exec, instruction, index)
  return stageResourceKeys(exec, instruction, index)
end
Handlers["load-sprite-animation"] = handleLoadSpriteAnimation

local function handleCreateManagedSprite(exec, instruction, index)
  return stageResourceKeys(exec, instruction, index)
end
Handlers["create-managed-sprite"] = handleCreateManagedSprite

-- Executes one instruction through the player facade. Returns continue
-- while the immediate chain may proceed in the same source quantum,
-- park when the instruction yields the quantum to a later source tick,
-- and done when the occurrence reached a terminal state.
---@param exec BattleAnimationExec player capability facade for one occurrence
---@param instruction table<string, unknown> normalized instruction under execution
--- Dispositions are the strings continue, park, and done.
---@param index integer one-based instruction position under provenance
---@return string
function BattleAnimationCommands.execute(exec, instruction, index)
  local handler = Handlers[instruction.op]
  if handler == nil then
    exec.fail("unknown normalized operation " .. tostring(instruction.op))
    return "done"
  end
  return handler(exec, instruction, index)
end

return BattleAnimationCommands
