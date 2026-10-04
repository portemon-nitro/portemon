-- Semantic lowering : classifies every raw
-- instruction from the pinned implementations and folds supported opcodes
-- into DSL steps with attached provenance. Execution classifications
-- (continue_same_tick / yield_next_tick / native_wait / stop / unsupported)
-- come from the command catalog; folding (Compare+GoToIf -> condition,
-- NPCMsg+WaitButton+CloseMsg -> say) never erases an unmodeled yield
-- boundary. Every instruction keeps source offsets and opcodes in
-- provenance. Pure domain module: no love dependency.

local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local ScriptIdentity = require("libs.assets.src.ScriptIdentity")
local Operands = require("romdump.src.digest.script.lowering.Operands")
local ControlHandlers = require("romdump.src.digest.script.lowering.ControlHandlers")
local FieldHandlers = require("romdump.src.digest.script.lowering.FieldHandlers")
local AudioHandlers = require("romdump.src.digest.script.lowering.AudioHandlers")

local SemanticLowering = {}

-- HGSS GoToIf condition codes.
local CONDITION_OPERATORS = { [0] = "lt", [1] = "eq", [2] = "gt", [3] = "le", [4] = "ge", [5] = "ne" }

-- The explicit unsupported node for one instruction. Commands the
-- authoritative catalog marks deferred keep their dependency category and
-- source-backed explanation on the node; anything else keeps the generic
-- lowering reason. The runtime fails only if a script reaches the node.
---@param ins table<string, unknown>
---@param reason string
---@return table<string, unknown>
local function unsupportedStep(ins, reason)
  local arguments = {}
  for index, operand in ipairs(ins.operands) do
    arguments[index] = Operands.operandValue(operand)
  end
  local deferral = CommandCatalog.deferredReason(ins.opcode)
  if CommandCatalog.disposition(ins.opcode) == "deferred" and deferral ~= nil then
    reason = "deferred (" .. deferral .. ")"
    local note = CommandCatalog.deferredNote(ins.opcode)
    if note ~= nil then
      reason = reason .. ": " .. note
    end
  end
  return {
    op = "unsupported",
    command = ins.opcode,
    originalName = CommandCatalog.name(ins.opcode),
    arguments = arguments,
    sourceOffset = ins.offset,
    reason = reason,
  }
end

-- One step with provenance.
---@param step table<string, unknown>
---@param offsets integer[]
---@param opcodes integer[]
---@return table<string, unknown>
local function withProvenance(step, offsets, opcodes)
  step.provenance = { offsets = offsets, opcodes = opcodes }
  return step
end

-- Compose the source-semantic handler families once, rejecting duplicate opcodes.
local function mergeHandlerRegistry(target, sourceRegistry)
  for opcode, handler in pairs(sourceRegistry) do
    assert(target[opcode] == nil, "duplicate script lowering handler for opcode " .. tostring(opcode))
    target[opcode] = handler
  end
end

local function buildHandlers()
  local handlers = {}
  mergeHandlerRegistry(handlers, ControlHandlers)
  mergeHandlerRegistry(handlers, FieldHandlers)
  mergeHandlerRegistry(handlers, AudioHandlers)
  return handlers
end

local HANDLERS = buildHandlers()

-- Fold a compare/flag instruction with a following GoToIf/CallIf into one
-- conditional item, or nil when the pattern does not apply (the compare
-- result is consumed by the immediately following branch).
---@param ins table<string, unknown>
---@param branch table<string, unknown>
---@return table<string, unknown>|nil item
local function foldConditional(ins, branch)
  local conditionCode = Operands.operandValue(branch.operands[1])
  local operator = CONDITION_OPERATORS[conditionCode]
  if operator == nil then
    return nil
  end
  local target = Operands.operandValue(branch.operands[2])
  local condition
  if ins.opcode == 17 or ins.opcode == 18 then
    condition = {
      condition = "compare",
      operator = operator,
      left = Operands.varRef(ins.operands[1]),
      right = Operands.varRef(ins.operands[2]),
    }
  elseif ins.opcode == 32 then
    local expected
    if conditionCode == 1 then
      expected = true
    elseif conditionCode == 0 or conditionCode == 5 then
      expected = false
    else
      return nil
    end
    condition = { condition = "flag", id = Operands.operandValue(ins.operands[1]), expected = expected }
  else
    return nil
  end
  return {
    op = branch.opcode == 29 and "call_if" or "if_cond",
    condition = condition,
    target = target,
    provenance = {
      offsets = { ins.offset, branch.offset },
      opcodes = { ins.opcode, branch.opcode },
    },
  }
end

-- The NPCMsg + WaitButton + CloseMsg triplet folds into `say` with the hgss
-- timing profile. Returns the say item plus the
-- number of instructions consumed (3), or nil.
---@param messageStep table<string, unknown>
---@param waitIns table<string, unknown>
---@param closeIns table<string, unknown>
---@return table<string, unknown>|nil say
local function foldSay(messageStep, waitIns, closeIns)
  if waitIns.opcode ~= 50 then
    return nil
  end
  if closeIns.opcode ~= 53 then
    return nil
  end
  return {
    op = "say",
    message = messageStep.message,
    provenance = {
      offsets = { messageStep.provenance.offsets[1], waitIns.offset, closeIns.offset },
      opcodes = { messageStep.provenance.opcodes[1], waitIns.opcode, closeIns.opcode },
    },
  }
end

-- An unconsumed NPCMsg/GenderMsgBox becomes the primitive `message` op with
-- the native print wait (opcodes 45 and 132).
---@param step table<string, unknown>
---@return table<string, unknown>
local function toMessageStep(step)
  local message = step.message
  return {
    op = "message",
    message = message,
    waitForPrint = true,
  }
end

-- One cross-script call payload naming the target script by its public id.
-- The entry label rides along only for interior targets; a script-body
-- target carries no label.
---@param scriptId string
---@param label string|nil
---@return table<string, unknown>
local function crossScriptCall(scriptId, label)
  local step = { op = "call", target = scriptId }
  if label ~= nil then
    step.label = label
  end
  return step
end

-- One cross-script jump payload naming the target script by its public id.
---@param scriptId string
---@param label string|nil
---@return table<string, unknown>
local function crossScriptJump(scriptId, label)
  local jump = { op = "goto_script", script = scriptId }
  if label ~= nil then
    jump.label = label
  end
  return jump
end

-- One conditional wrapper around a cross-script branch payload.
---@param condition table<string, unknown>
---@param branch table<string, unknown>
---@param provenance table<string, unknown>|nil
---@return table<string, unknown>
local function wrapConditional(condition, branch, provenance)
  return {
    op = "if",
    condition = condition,
    yes = { branch },
    no = {},
    provenance = provenance,
  }
end

-- Lower one script's instruction list into semantic items. `memberIr` holds
-- the movement blocks. Folding never erases an unmodeled yield boundary.
-- `opts.stdCatalog` (SourceCatalog) resolves CallStd targets; without it
-- targets stay mechanical `common.std_<id>`. The returned table carries the
-- `omissions` (Nop/Dummy erasures) for the verifier.
---@param script table<string, unknown>
---@param memberIr table<string, unknown>
---@param opts table<string, unknown>
---@return table<string, unknown> lowered
function SemanticLowering.lowerScript(script, memberIr, opts)
  local items = {}
  local unsupported = {}
  local omissions = {}
  local index = 1
  local instructions = script.instructions

  local ctx = {
    stdCatalog = opts.stdCatalog,
  }

  -- Script-local labels: branch and call targets must resolve inside the
  -- script. The pinned sources share tails across scripts: a branch may
  -- jump into another script's label region or into another script's entry.
  -- Such a branch becomes a runtime-resolved cross-script reference
  -- (`goto_script`, or `call` with a label) naming the target script by its
  -- public id, resolved through the composition registry at runtime like
  -- the raw-Lua escape hatch. A target that resolves to no script in the
  -- member stays an explicit unsupported node.
  local scriptLabels = {}
  for _, ins in ipairs(instructions) do
    if ins.label ~= nil then
      scriptLabels[ins.label] = true
    end
  end
  local memberLabels = {}
  local memberBodyLabels = {}
  for memberIndex, memberScript in pairs(memberIr.scripts) do
    memberBodyLabels[memberScript.label] = memberIndex
    for _, ins in ipairs(memberScript.instructions) do
      if ins.label ~= nil then
        memberLabels[ins.label] = memberIndex
      end
    end
  end
  local function publicIdFor(ownerIndex)
    if opts.publicIdFor ~= nil then
      return opts.publicIdFor(memberIr.member, ownerIndex)
    end
    return ScriptIdentity.formatVanilla(memberIr.member, ownerIndex)
  end
  local CONTROL_TARGET_OPS = {
    ["goto"] = true,
    goto_if = true,
    if_cond = true,
    call_if = true,
    call = true,
    goto_compared = true,
    call_compared = true,
  }
  local function resolveControlTargets(list)
    for i, item in ipairs(list) do
      if item.target ~= nil and CONTROL_TARGET_OPS[item.op] then
        local target = item.target
        local owner
        if type(target) == "string" and not scriptLabels[target] then
          owner = memberLabels[target] or memberBodyLabels[target]
        end
        if owner ~= nil then
          local scriptId = publicIdFor(owner)
          local label = memberLabels[target] ~= nil and target or nil
          local provenance = item.provenance
          if item.op == "goto" then
            local step = crossScriptJump(scriptId, label)
            step.provenance = provenance
            list[i] = step
          elseif item.op == "call" then
            local step = crossScriptCall(scriptId, label)
            step.provenance = provenance
            list[i] = step
          elseif item.op == "call_if" then
            list[i] = wrapConditional(item.condition, crossScriptCall(scriptId, label), provenance)
          elseif item.op == "goto_if" or item.op == "if_cond" then
            -- A conditional cross-script jump.
            list[i] = wrapConditional(item.condition, crossScriptJump(scriptId, label), provenance)
          else
            -- The compare-state fallback forms preserve the source compare
            -- state; a cross-script target rides the same runtime state via
            -- the additive script/label fields.
            local step = {
              op = item.op,
              operator = item.operator,
              script = scriptId,
              provenance = provenance,
            }
            if label ~= nil then
              step.label = label
            end
            list[i] = step
          end
        elseif type(target) ~= "string" or not scriptLabels[target] then
          local provenance = item.provenance
          local branchOffset = provenance and provenance.offsets[#provenance.offsets]
          local branchOpcode = provenance and provenance.opcodes[#provenance.opcodes]
          local step = {
            op = "unsupported",
            command = branchOpcode or 0,
            originalName = CommandCatalog.name(branchOpcode or 0),
            arguments = {},
            sourceOffset = branchOffset or 0,
            reason = "branch target does not exist in this member",
            provenance = provenance,
          }
          list[i] = step
          unsupported[#unsupported + 1] = step
        end
      end
    end
  end

  -- Label markers: the first instruction after an offset label carries it;
  -- the emitted item (or the fold consuming that instruction) receives a
  -- preceding label step so the structurer can resolve branch targets.
  local function pushLabel(ins)
    if ins.label ~= nil then
      items[#items + 1] = { op = "label", name = ins.label, offset = ins.offset }
    end
  end

  -- An unconsumed fold participant becomes its primitive step.
  local function lowerUnfolded(ins)
    local primitive
    if ins.opcode == 53 then
      primitive = { op = "close_message", erase = true }
    elseif ins.opcode == 28 or ins.opcode == 29 then
      local operator = CONDITION_OPERATORS[Operands.operandValue(ins.operands[1])] or "eq"
      primitive = {
        op = ins.opcode == 29 and "call_compared" or "goto_compared",
        operator = operator,
        target = Operands.operandValue(ins.operands[2]),
      }
    end
    if primitive ~= nil then
      local prim = withProvenance(primitive, { ins.offset }, { ins.opcode })
      return { prim }, { ins }, nil
    end
    local fallbackStep = {
      op = "unsupported",
      command = ins.opcode,
      originalName = CommandCatalog.name(ins.opcode),
      arguments = {},
      sourceOffset = ins.offset,
      reason = "unconsumed compare-state op without a DSL carrier",
    }
    local fallback = withProvenance(fallbackStep, { ins.offset }, { ins.opcode })
    return { fallback }, { ins }, { unsupported = fallback }
  end

  -- Lower one instruction through the existing handler. Returns the items
  -- to append (provenance already attached), the instructions whose label
  -- steps precede them, and the omission/unsupported disposition.
  local function lowerSingle(ins)
    local handler = HANDLERS[ins.opcode]
    if handler == nil then
      local step = unsupportedStep(ins, "opcode has no semantic lowering")
      step = withProvenance(step, { ins.offset }, { ins.opcode })
      return { step }, { ins }, { unsupported = step }
    end
    local step = handler(ins, memberIr, { offsets = { ins.offset }, opcodes = { ins.opcode } }, ctx)
    if step == nil then
      -- An explicitly erased implementation-detail instruction (Nop and
      -- Dummy, rows 0-1): record the omission for the verifier's
      -- no-disappearing-command check while retaining its source label for
      -- branches that target this instruction.
      return {}, { ins }, {
        omission = { offset = ins.offset, opcode = ins.opcode, operand = ins.operands[1] and ins.operands[1].raw },
      }
    end
    if step == "unfolded" then
      return lowerUnfolded(ins)
    end
    if type(step) == "table" and type(step.steps) == "table" then
      -- One instruction lowering to several canonical operations (e.g.
      -- MovePersonFacing: position then facing); all steps share the
      -- instruction's provenance.
      local grouped = {}
      for _, subStep in ipairs(step.steps) do
        if subStep.op == "yield_tick" then
          grouped[#grouped + 1] = subStep
        else
          grouped[#grouped + 1] = withProvenance(subStep, { ins.offset }, { ins.opcode })
        end
      end
      return grouped, { ins }, nil
    end
    if step.op == "release_all" then
      -- The source command unconditionally yields one frame after
      -- unpausing. The synthesized yield has
      -- no source instruction of its own, so it carries no provenance
      -- (its node id is structural, avoiding a duplicate with the
      -- release node's src: id).
      local release = withProvenance(step, { ins.offset }, { ins.opcode })
      return { release, { op = "yield_tick" } }, { ins }, nil
    end
    if step.op == "npc_msg" or step.op == "npc_msg_var" then
      step = toMessageStep(step)
    end
    step = withProvenance(step, { ins.offset }, { ins.opcode })
    if step.op == "unsupported" then
      return { step }, { ins }, { unsupported = step }
    end
    return { step }, { ins }, nil
  end

  -- Lower the fold or instruction at position `at`. Fold selection keeps
  -- its order (compare/flag plus GoToIf/CallIf first, then the message
  -- triplet) and its labeled-entry rule; a fold consumes two or three
  -- instructions only under the current opcode and no-interior-label
  -- conditions. Returns the items to append, the consumed count, the
  -- label sources, and the omission/unsupported disposition.
  local function lowerAt(at)
    local ins = instructions[at]
    local nextIns = instructions[at + 1]
    local handler = HANDLERS[ins.opcode]
    -- Compare/flag + GoToIf/CallIf fold (both remain same-tick). The fold
    -- never spans a labeled instruction: a branch target landing on the
    -- second instruction must enter at the branch (with the caller's
    -- compare state), not at the folded operation's start.
    if
      handler ~= nil
      and nextIns ~= nil
      and (nextIns.opcode == 28 or nextIns.opcode == 29)
      and (ins.opcode == 17 or ins.opcode == 18 or ins.opcode == 32)
      and nextIns.label == nil
    then
      local folded = foldConditional(ins, nextIns)
      if folded ~= nil then
        return { folded }, 2, { ins, nextIns }, nil
      end
    end
    -- NPCMsg/GenderMsgBox + WaitButton + CloseMsg -> say. Same labeled-entry
    -- rule: an entry point on the wait or close instruction keeps the three
    -- instructions separate.
    if
      handler ~= nil
      and nextIns ~= nil
      and instructions[at + 2] ~= nil
      and (ins.opcode == 45 or ins.opcode == 132 or ins.opcode == 47)
      and nextIns.label == nil
      and instructions[at + 2].label == nil
    then
      local probe = handler(ins, memberIr, {}, ctx)
      if type(probe) == "table" and (probe.op == "npc_msg" or probe.op == "npc_msg_var") then
        probe = withProvenance(probe, { ins.offset }, { ins.opcode })
        local say = foldSay(probe, nextIns, instructions[at + 2])
        if say ~= nil then
          return { say }, 3, { ins, nextIns, instructions[at + 2] }, nil
        end
      end
    end
    local appended, labelSources, diagnosis = lowerSingle(ins)
    return appended, 1, labelSources, diagnosis
  end

  -- One index -> ordered fold/handler decision -> local emission with exact
  -- provenance/diagnostic rules -> index advanced by consumed count.
  while index <= #instructions do
    local appended, consumed, labelSources, diagnosis = lowerAt(index)
    for _, source in ipairs(labelSources) do
      pushLabel(source)
    end
    for _, item in ipairs(appended) do
      items[#items + 1] = item
    end
    if diagnosis ~= nil then
      if diagnosis.omission ~= nil then
        omissions[#omissions + 1] = diagnosis.omission
      end
      if diagnosis.unsupported ~= nil then
        unsupported[#unsupported + 1] = diagnosis.unsupported
      end
    end
    index = index + consumed
  end
  resolveControlTargets(items)
  return { items = items, unsupported = unsupported, omissions = omissions }
end

return SemanticLowering
