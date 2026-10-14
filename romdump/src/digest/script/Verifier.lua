-- Translation verifier : compares the original Raw IR
-- and CFG against the lowered semantic IR. It verifies translation-accounting
-- and control-flow preservation, not full game-behavior equivalence:
--
-- 1. Every reachable source instruction is covered by one semantic node
-- or an explicit unsupported node (Nop/Dummy are the only documented
-- implementation-detail erasures).
-- 2. Every original control edge is represented by a control node.
-- 3. Every semantic side effect maps back to source offsets.
-- 4. Every source execution classification is represented by an
-- equivalent graph boundary or timing profile.
-- 5. Discarded implementation variables are proven unobservable.
-- 6. Canonicalized operands resolve to the same constants.
-- 7. Call/return balance is preserved.
-- 8. Movement sequence termination is preserved.
-- 9. No command disappears except an explicitly documented erasure.
-- 10. Unsupported instructions prevent a `complete` result.
--
-- the caller signal is cleared before the common script's following command
-- runs, matching the pinned `ScrCmd_RestartCurrentScript` bit protocol. Pure
-- domain module: no love dependency.

local Cfg = require("romdump.src.digest.script.Cfg")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local Operands = require("romdump.src.digest.script.lowering.Operands")
local SignpostCommands = require("romdump.src.reference.hgss.signpost_commands")

local Verifier = {}

-- Branch and call opcodes: their covering node must be a control node.
local CONTROL_OPS = {
  ["goto"] = true,
  goto_if = true,
  goto_compared = true,
  call_compared = true,
  if_cond = true,
  call_if = true,
  ["if"] = true,
  goto_script = true,
}

-- Blocking (native-wait) operations: an instruction classified native_wait
-- must be covered by one of these, or by an explicit unsupported node.
local BLOCKING_OPS = {
  wait_ticks = true,
  say = true,
  message = true,
  wait_input = true,
  wait_input_or_ticks = true,
  wait_movement = true,
  wait_sound = true,
  wait_cry = true,
  wait_fanfare = true,
  wait_fade = true,
  fade_music_out = true,
  fade_music_in = true,
  ask_yes_no = true,
  context_choice = true,
  choose_starter = true,
  pokemon_nickname_input = true,
  party_select = true,
  menu_exec = true,
  warp = true,
  call_common = true,
  wait_signpost_action = true,
  battle_launch = true,
  trainer_tips_print = true,
  wait_signpost = true,
  mart_open = true,
  follower_wait = true,
  follower_interact = true,
  pc_open = true,
  pc_hof_open = true,
  pokegear_open = true,
  phone_run_call = true,
  prop_animation_wait = true,
  follower_appearance = true,
  follower_recall = true,
}

-- Operations that end the run phase: yield boundaries and stops.
local YIELD_OPS = {
  yield_tick = true,
  lock_all = true,
  release_all = true,
  menu_begin = true,
  signpost_direction = true,
  signpost_set = true,
  signpost_command = true,
  stop = true,
}

-- Operations that end the script context (a stop-classified instruction
-- must be covered by one of these): plain completion and the opcode-61
-- context end that requests the Start Menu reopen hook.
local TERMINAL_OPS = {
  stop = true,
  request_start_menu = true,
}

-- The documented multi-instruction folds (they own a timing profile of their
-- own, so per-instruction classification checks do not apply to them).
-- `if` covers the conditional cross-script branch wrap; `goto_if` is the
-- label/goto fallback of a compare+GoToIf fold that the structurer could
-- not peel.
local FOLD_OPS = { say = true, if_cond = true, call_if = true, ["if"] = true, goto_if = true }

-- Whether a lowered node ends the run phase by blocking (native wait). The
-- `message` op blocks only with waitForPrint; `lock_actor` blocks only with
-- waitUntilPausable.
---@param node table<string, unknown>
---@return boolean
local function nodeBlocks(node)
  if node.op == "message" then
    return node.waitForPrint == true
  end
  if node.op == "lock_actor" then
    return node.waitUntilPausable == true
  end
  if node.op == "pc_terminal_effect" then
    return node.action == "wait"
  end
  return BLOCKING_OPS[node.op] == true
end

-- Instructions whose operand values are side effects on the script stack
-- (counted for the stack-balance and observability checks).
local CALL_OPS = { [26] = true, [29] = true }
local RETURN_OPS = { [27] = true }

-- Compare an operand raw value with a node field (varRef forms match their
-- symbolic operands).
---@param raw unknown
---@param node unknown
---@return boolean
local function operandMatches(raw, node)
  if
    type(node) == "table"
    and node.value == "var"
    and type(raw) == "number"
    and ((raw >= 0x4000 and raw < 0x4400) or (raw >= 0x8000 and raw < 0x8100))
  then
    return node.id == raw
  end
  if type(node) == "table" and type(raw) == "string" then
    if node.value == "var" then
      return node.id == raw
    end
    if node.value == "local" then
      return node.name == raw
    end
  end
  return node == raw
end

-- The per-opcode operand-equivalence checkers (item 6): `(ins, step)` ->
-- problem message or nil. Covering the high-value operand-carrying
-- instructions; the rest are checked by the generic coverage rule.
local function checkMartLaunch(ins, step)
  local kindByOpcode = { [275] = "standard", [276] = "special", [277] = "decoration", [278] = "seal" }
  local kind = kindByOpcode[ins.opcode]
  if kind == nil or step.kind ~= kind then
    return "mart launch kind changed by translation"
  end
  if kind == "standard" then
    if step.selector ~= nil then
      return "MartBuy's unused selector must not affect stock"
    end
  elseif not operandMatches(ins.operands[1].raw, step.selector) then
    return "mart selector changed by translation"
  end
end

local function checkMartQuery(ins, step)
  local kind = ins.opcode == 834 and "athlete_available" or "card_prefix"
  if step.op ~= "mart_query" or step.kind ~= kind or not operandMatches(ins.operands[1].raw, step.result) then
    return "mart query output variable changed by translation"
  end
end

local function checkPcOpen(ins, step)
  local appByOpcode = { [158] = "storage", [376] = "mailbox", [617] = "photoAlbum" }
  local app = appByOpcode[ins.opcode]
  if step.op ~= "pc_open" or step.app ~= app then
    return "PC application changed by translation"
  end
  if ins.opcode == 158 and not operandMatches(ins.operands[1].raw, step.mode) then
    return "PC storage mode changed by translation"
  end
  if ins.opcode ~= 158 and step.mode ~= nil then
    return "non-storage PC application acquired a storage mode"
  end
end

local function checkPcCount(ins, step)
  local kindByOpcode = { [377] = "mailbox", [616] = "photos", [706] = "hall_of_fame" }
  local kind = kindByOpcode[ins.opcode]
  if ins.opcode == 706 then
    if step.op ~= "pc_hof_status" or not operandMatches(ins.operands[1].raw, step.result) then
      return "Hall of Fame status output variable changed by translation"
    end
  elseif step.op ~= "pc_count" or step.kind ~= kind or not operandMatches(ins.operands[1].raw, step.result) then
    return "PC count output variable changed by translation"
  end
end

local function checkPcTerminalEffect(ins, step)
  if (ins.opcode == 308 or ins.opcode == 309) and Operands.operandValue(ins.operands[1]) ~= 90 then
    local op = ins.opcode == 308 and "prop_animation_wait" or "prop_animation_unload"
    if step.op ~= op or not operandMatches(ins.operands[1].raw, step.slot) then
      return "prop animation slot changed by translation"
    end
    return nil
  end
  local actionByOpcode = { [500] = "start", [501] = "on", [502] = "off", [308] = "wait", [309] = "release" }
  local action = actionByOpcode[ins.opcode]
  if step.op ~= "pc_terminal_effect" or step.action ~= action then
    return "terminal effect changed by translation"
  end
  if Operands.operandValue(ins.operands[1]) ~= 90 or step.prop ~= "pc_terminal" then
    return "terminal prop selector changed by translation"
  end
end

local function checkWaitFrames(ins, step)
  if step.op == "unsupported" then
    return nil
  end
  if not operandMatches(ins.operands[1].raw, step.ticks) then
    return "Wait frame count changed by translation"
  end
end

local function checkGotoTarget(ins, step)
  if step.op == "goto_script" then
    return nil
  end
  if not operandMatches(ins.operands[1].raw, step.target) then
    return "GoTo target changed by translation"
  end
end

local function checkCallTarget(ins, step)
  if step.label ~= nil then
    return nil
  end
  if not operandMatches(ins.operands[1].raw, step.target) then
    return "Call target changed by translation"
  end
end

local function checkSetFlag(ins, step)
  if not operandMatches(ins.operands[1].raw, step.flag) then
    return "SetFlag id changed by translation"
  end
end

local function checkClearFlag(ins, step)
  if not operandMatches(ins.operands[1].raw, step.flag) then
    return "ClearFlag id changed by translation"
  end
end

local function checkSetFlagVar(ins, step)
  if not operandMatches(ins.operands[1].raw, step.flag) then
    return "SetFlagVar id changed by translation"
  end
end

local function checkClearFlagVar(ins, step)
  if not operandMatches(ins.operands[1].raw, step.flag) then
    return "ClearFlagVar id changed by translation"
  end
end

local function checkAddVar(ins, step)
  if not operandMatches(ins.operands[1].raw, step.variable) or not operandMatches(ins.operands[2].raw, step.amount) then
    return "AddVar operands changed by translation"
  end
end

local function checkSubVar(ins, step)
  if not operandMatches(ins.operands[1].raw, step.variable) or not operandMatches(ins.operands[2].raw, step.amount) then
    return "SubVar operands changed by translation"
  end
end

local function checkSetVar(ins, step)
  if not operandMatches(ins.operands[1].raw, step.variable) or not operandMatches(ins.operands[2].raw, step.value) then
    return "SetVar operands changed by translation"
  end
end

local function checkCopyVar(ins, step)
  if
    not operandMatches(ins.operands[1].raw, step.destination)
    or not operandMatches(ins.operands[2].raw, step.source)
  then
    return "CopyVar operands changed by translation"
  end
end

local function checkSetOrCopyVar(ins, step)
  if not operandMatches(ins.operands[1].raw, step.variable) or not operandMatches(ins.operands[2].raw, step.value) then
    return "SetOrCopyVar operands changed by translation"
  end
end

local function checkPlaySound(ins, step)
  if not operandMatches(ins.operands[1].raw, step.sound) then
    return "PlaySE sound changed by translation"
  end
end

local function checkStopSound(ins, step)
  if not operandMatches(ins.operands[1].raw, step.sound) then
    return "StopSE sound changed by translation"
  end
end

local function checkWaitSound(ins, step)
  if not operandMatches(ins.operands[1].raw, step.sound) then
    return "WaitSE sound changed by translation"
  end
end

local function checkPlayMusic(ins, step)
  if not operandMatches(ins.operands[1].raw, step.music) then
    return "PlayBGM music changed by translation"
  end
end

local function checkTemporaryMusic(ins, step)
  if not operandMatches(ins.operands[1].raw, step.music) then
    return "TempBGM music changed by translation"
  end
end

local function checkSetSpawn(ins, step)
  if not operandMatches(ins.operands[1].raw, step.spawn) then
    return "SetSpawn id changed by translation"
  end
end

local function checkWaitInputOrTicks(ins, step)
  if not operandMatches(ins.operands[1].raw, step.ticks) then
    return "WaitButtonOrDelay ticks changed by translation"
  end
end

local function checkDirectionSignpost(ins, step)
  -- DirectionSignpost: the raw type/map must survive exactly and the
  -- message id stays the direct bank index. The final operand is an
  -- intentional, audited erasure: the source handler never reads or
  -- writes it, so the semantic node drops it (the raw decoded operands
  -- keep it for source auditing).
  local appearance = step.sourceAppearance or {}
  if appearance.type ~= ins.operands[2].raw or appearance.map ~= ins.operands[3].raw then
    return "DirectionSignpost type/map changed by translation"
  end
  local message = step.message
  local id = type(message) == "table" and message.message == "external" and message.id
  if id ~= ins.operands[1].raw then
    return "DirectionSignpost message id changed by translation"
  end
end

local function checkSetSignpostMap(ins, step)
  local appearance = step.sourceAppearance or {}
  if appearance.type ~= ins.operands[1].raw or appearance.map ~= ins.operands[2].raw then
    return "SetSignpostMap type/map changed by translation"
  end
end

local function checkSetSignpostAction(ins, step)
  -- SetSignpostAction: the raw MAPSIGNCOMMAND_* code must lower to the
  -- exact semantic command, never a default.
  if step.command ~= SignpostCommands.semanticName(ins.operands[1].raw) then
    return "SetSignpostAction command changed by translation"
  end
end

local function checkTrainerTips(ins, step)
  -- TrainerTips: the message id stays the direct bank index and the
  -- result var survives exactly.
  local message = step.message
  local id = type(message) == "table" and message.message == "external" and message.id
  if id ~= ins.operands[1].raw then
    return "TrainerTips message id changed by translation"
  end
  if not operandMatches(ins.operands[2].raw, step.result) then
    return "TrainerTips result operand changed by translation"
  end
end

local function checkWaitSignpost(ins, step)
  -- WaitSignpost: the result var survives exactly.
  if not operandMatches(ins.operands[1].raw, step.result) then
    return "WaitSignpost result operand changed by translation"
  end
end

-- Pocket-gear operand checkers: each re-derives its row's mapping from the
-- raw operands independently of the lowering functions above. Cards,
-- music effects, and trigger slots re-state the source vocabulary here so
-- a wrong lowering or a wrong sentinel fails instead of passing quietly.
local GEAR_CARD_BY_CODE = { [0] = "phone", [1] = "map", [2] = "radio" }
local GEAR_MUSIC_EFFECT_BY_CODE = { [5] = "pokeflute" }
local GEAR_ENTRY_TEMP = "VAR_TEMP_x4010"

local function checkGearCard(ins, step)
  if step.op ~= "pokegear_register_card" then
    return "opcode 145 card registration changed by translation"
  end
  if step.card ~= GEAR_CARD_BY_CODE[ins.operands[1].raw] then
    return "opcode 145 card selector changed by translation"
  end
  return nil
end

local function checkGearTriggerInner(opcode, ins, step, active)
  if step.op ~= "pokegear_set_trigger" then
    return "opcode " .. opcode .. " trigger switch changed by translation"
  end
  local raw = ins.operands[1].raw
  if type(raw) ~= "number" or step.trigger ~= string.format("gear.trigger.%d", raw) then
    return "opcode " .. opcode .. " trigger slot changed by translation"
  end
  if step.active ~= active then
    return "opcode " .. opcode .. " trigger switch value changed by translation"
  end
  return nil
end

local function checkSetPhoneTrigger(ins, step)
  local raw = ins.operands[2].raw
  if type(raw) ~= "number" then
    return "opcode 148 trigger switch value changed by translation"
  end
  return checkGearTriggerInner(148, ins, step, raw ~= 0)
end

local function checkUnsetPhoneTrigger(ins, step)
  return checkGearTriggerInner(149, ins, step, false)
end

local function checkGearContactQuery(opcode, kind)
  local function check(ins, step)
    if step.op ~= "pokegear_query" or step.kind ~= kind then
      return "opcode " .. opcode .. " contact query changed by translation"
    end
    if not operandMatches(ins.operands[1].raw, step.contact) then
      return "opcode " .. opcode .. " contact query contact changed by translation"
    end
    if not operandMatches(ins.operands[2].raw, step.result) then
      return "opcode " .. opcode .. " contact query result variable changed by translation"
    end
    return nil
  end
  return check
end

local function checkGetPhoneBookRematch(ins, step)
  if step.op ~= "phone_rematch_trainer" then
    return "opcode 142 must resolve a native trainer identity"
  end
  if not operandMatches(ins.operands[1].raw, step.contact) then
    return "opcode 142 phonebook entry changed by translation"
  end
  if not operandMatches(ins.operands[2].raw, step.result) then
    return "opcode 142 trainer result variable changed by translation"
  end
  return nil
end

local function checkClearPhoneBookRematch(ins, step)
  if step.op ~= "phone_rematch_clear" then
    return "opcode 462 must clear the addressed phonebook entry"
  end
  if not operandMatches(ins.operands[1].raw, step.contact) then
    return "opcode 462 phonebook entry changed by translation"
  end
  return nil
end

local function checkRegisterGearNumber(ins, step)
  if step.op ~= "pokegear_update" or step.kind ~= "register_contact" then
    return "opcode 146 contact registration changed by translation"
  end
  if not operandMatches(ins.operands[1].raw, step.contact) then
    return "opcode 146 registered contact changed by translation"
  end
  return nil
end

local function checkTownMap(ins, step)
  assert(ins.operands == nil or #ins.operands == 0, "town map launches carry no operands")
  if step.op ~= "pokegear_open" or step.mode ~= "townMap" then
    return "opcode 157 town map launch changed by translation"
  end
  return nil
end

local function checkSetPhoneCall(ins, step)
  if step.op ~= "phone_set_call" then
    return "opcode 430 call setup changed by translation"
  end
  if
    not operandMatches(ins.operands[1].raw, step.contact)
    or not operandMatches(ins.operands[2].raw, step.direction)
    or not operandMatches(ins.operands[3].raw, step.kind)
  then
    return "opcode 430 call setup operands changed by translation"
  end
  return nil
end

local function checkRunPhoneCall(ins, step)
  assert(ins.operands == nil or #ins.operands == 0, "call runs carry no operands")
  if step.op ~= "phone_run_call" then
    return "opcode 431 call run changed by translation"
  end
  return nil
end

local function checkLoadPhoneDat(ins, step)
  if step.op ~= "phone_resolve_contact" then
    return "opcode 460 phonebook resolution changed by translation"
  end
  if not operandMatches(ins.operands[1].raw, step.trainer) then
    return "opcode 460 phonebook trainer operand changed by translation"
  end
  if not operandMatches(ins.operands[2].raw, step.result) then
    return "opcode 460 phonebook result variable changed by translation"
  end
  return nil
end

local function checkPhoneContactMessage(ins, step)
  if step.op ~= "phone_contact_message" then
    return "opcode 461 contact message lookup changed by translation"
  end
  local kind = ins.operands[1].raw
  if type(kind) ~= "number" or step.kind ~= kind then
    return "opcode 461 contact message kind changed by translation"
  end
  local contact = step.contact
  if type(contact) ~= "table" or contact.value ~= "var" or contact.id ~= GEAR_ENTRY_TEMP then
    return "opcode 461 contact message entry temp changed by translation"
  end
  if not operandMatches(ins.operands[2].raw, step.bank) then
    return "opcode 461 contact message bank variable changed by translation"
  end
  if not operandMatches(ins.operands[3].raw, step.entry) then
    return "opcode 461 contact message entry variable changed by translation"
  end
  return nil
end

local function checkPhoneContactGift(opcode, kind)
  local function check(ins, step)
    if step.op ~= "phone_contact_gift" or step.kind ~= kind then
      return "opcode " .. opcode .. " contact gift query changed by translation"
    end
    local contact = step.contact
    if type(contact) ~= "table" or contact.value ~= "var" or contact.id ~= GEAR_ENTRY_TEMP then
      return "opcode " .. opcode .. " contact gift entry temp changed by translation"
    end
    if not operandMatches(ins.operands[1].raw, step.result) then
      return "opcode " .. opcode .. " contact gift result variable changed by translation"
    end
    return nil
  end
  return check
end

local function checkRadioMusic(ins, step)
  if step.op ~= "radio_music_query" then
    return "opcode 779 radio music query changed by translation"
  end
  if step.effect ~= GEAR_MUSIC_EFFECT_BY_CODE[ins.operands[1].raw] then
    return "opcode 779 radio effect code changed by translation"
  end
  if not operandMatches(ins.operands[2].raw, step.result) then
    return "opcode 779 radio query result variable changed by translation"
  end
  return nil
end

local function checkMomGift(ins, step)
  if step.op ~= "mom_gift_check" then
    return "opcode 813 parent gift check changed by translation"
  end
  if not operandMatches(ins.operands[1].raw, step.result) then
    return "opcode 813 parent gift result variable changed by translation"
  end
  return nil
end

local function checkMomGiftHead(ins, step)
  if step.op ~= "mom_gift_head" then
    return "opcode 811 Mom gift head changed by translation"
  end
  if #ins.operands ~= 2 then
    return "opcode 811 must preserve its two writable results"
  end
  if not operandMatches(ins.operands[1].raw, step.item) or not operandMatches(ins.operands[2].raw, step.quantity) then
    return "opcode 811 item or quantity result changed by translation"
  end
  return nil
end

local function checkMomGiftTake(ins, step)
  if step.op ~= "mom_gift_take" then
    return "opcode 812 Mom gift dequeue changed by translation"
  end
  if #ins.operands ~= 0 then
    return "opcode 812 must remain a zero-operand dequeue"
  end
  return nil
end

local function checkBuenasPassword(ins, step)
  if step.op ~= "buena_password" then
    return "opcode 821 password service changed by translation"
  end
  if not operandMatches(ins.operands[1].raw, step.firstWord) then
    return "opcode 821 password first-word variable changed by translation"
  end
  if not operandMatches(ins.operands[2].raw, step.correct) then
    return "opcode 821 password answer variable changed by translation"
  end
  return nil
end

local CHECKERS = {
  [3] = checkWaitFrames,
  [22] = checkGotoTarget,
  [26] = checkCallTarget,
  [30] = checkSetFlag,
  [31] = checkClearFlag,
  [33] = checkSetFlagVar,
  [34] = checkClearFlagVar,
  [39] = checkAddVar,
  [40] = checkSubVar,
  [41] = checkSetVar,
  [42] = checkCopyVar,
  [43] = checkSetOrCopyVar,
  [73] = checkPlaySound,
  [74] = checkStopSound,
  [75] = checkWaitSound,
  [80] = checkPlayMusic,
  [87] = checkTemporaryMusic,
  [280] = checkSetSpawn,
  [348] = checkWaitInputOrTicks,
  [55] = checkDirectionSignpost,
  [56] = checkSetSignpostMap,
  [57] = checkSetSignpostAction,
  [59] = checkTrainerTips,
  [60] = checkWaitSignpost,
  [275] = checkMartLaunch,
  [276] = checkMartLaunch,
  [277] = checkMartLaunch,
  [278] = checkMartLaunch,
  [834] = checkMartQuery,
  [835] = checkMartQuery,
  [158] = checkPcOpen,
  [376] = checkPcOpen,
  [617] = checkPcOpen,
  [377] = checkPcCount,
  [616] = checkPcCount,
  [706] = checkPcCount,
  [500] = checkPcTerminalEffect,
  [501] = checkPcTerminalEffect,
  [502] = checkPcTerminalEffect,
  [308] = checkPcTerminalEffect,
  [309] = checkPcTerminalEffect,
  [142] = checkGetPhoneBookRematch,
  [462] = checkClearPhoneBookRematch,
  [145] = checkGearCard,
  [146] = checkRegisterGearNumber,
  [147] = checkGearContactQuery(147, "contact_registered"),
  [148] = checkSetPhoneTrigger,
  [149] = checkUnsetPhoneTrigger,
  [157] = checkTownMap,
  [430] = checkSetPhoneCall,
  [431] = checkRunPhoneCall,
  [460] = checkLoadPhoneDat,
  [461] = checkPhoneContactMessage,
  [613] = checkPhoneContactGift(613, "berry"),
  [614] = checkPhoneContactGift(614, "item"),
  [779] = checkRadioMusic,
  [811] = checkMomGiftHead,
  [812] = checkMomGiftTake,
  [813] = checkMomGift,
  [821] = checkBuenasPassword,
}

-- Walk the lowered items collecting the covering node per source offset.
---@param items table[]
---@return table<integer, table<string, unknown>> byOffset
local function coveredByOffset(items)
  local byOffset = {}
  local function walk(list)
    for _, item in ipairs(list) do
      if item.provenance ~= nil then
        for _, offset in ipairs(item.provenance.offsets) do
          byOffset[offset] = item
        end
      end
      if item.op == "if" then
        walk(item.yes)
        walk(item.no)
      end
    end
  end

  walk(items)
  return byOffset
end

---@param context table<string, unknown>
---@param message string
---@param details table<string, unknown>
local function addProblem(context, message, details)
  context.report.ok = false
  context.report.problems[#context.report.problems + 1] = { message = message, context = details }
end

---@param context table<string, unknown>
---@param message string
---@param details table<string, unknown>
local function addWarning(context, message, details)
  context.report.warnings[#context.report.warnings + 1] = { message = message, context = details }
end

local function newVerificationContext(steps, script, memberIr, omissions)
  return {
    cfg = Cfg.build(script, memberIr),
    byOffset = coveredByOffset(steps),
    script = script,
    memberIr = memberIr,
    steps = steps,
    omissions = omissions,
    prelude = script.prelude == true,
    report = { ok = true, complete = false, problems = {}, warnings = {} },
  }
end

local function verifyCoverage(context)
  context.omissionsByOffset = {}
  for _, omission in ipairs(context.omissions or {}) do
    context.omissionsByOffset[omission.offset] = omission
    local validNop = omission.opcode == 0 or omission.opcode == 1
    local validDefaultReturn = omission.opcode == 815 and omission.operand == 0
    if not validNop and not validDefaultReturn then
      addProblem(
        context,
        "omission recorded for a non-erasure opcode",
        { offset = omission.offset, opcode = omission.opcode }
      )
    end
  end

  context.total = #context.script.instructions
  context.covered = 0
  context.reachable = 0
  context.reachableUnsupported = 0
  context.unsupportedNodes = {}
  context.reachableOmitted = 0
  for i, ins in ipairs(context.script.instructions) do
    local isReachable = context.cfg.reachable[context.cfg.blockOfIndex[i]] == true
    if isReachable then
      context.reachable = context.reachable + 1
    end
    local node = context.byOffset[ins.offset]
    if node ~= nil then
      context.covered = context.covered + 1
      if node.op == "unsupported" then
        context.reachableUnsupported = context.reachableUnsupported + 1
        context.unsupportedNodes[#context.unsupportedNodes + 1] = node
      end
    elseif context.omissionsByOffset[ins.offset] then
      local omission = context.omissionsByOffset[ins.offset]
      if omission.opcode ~= ins.opcode or (ins.opcode == 815 and ins.operands[1].raw ~= 0) then
        addProblem(context, "operand-constrained omission does not match source instruction", {
          offset = ins.offset,
          opcode = ins.opcode,
        })
      end
      if isReachable then
        context.reachableOmitted = context.reachableOmitted + 1
      end
    else
      addProblem(
        context,
        "instruction not covered by any semantic node",
        { offset = ins.offset, opcode = ins.opcode, name = CommandCatalog.name(ins.opcode) }
      )
    end
  end
end

local function verifyControlEdges(context)
  local controlOffsets = { [22] = true, [23] = true, [24] = true, [25] = true, [28] = true, [29] = true }
  for _, ins in ipairs(context.script.instructions) do
    if controlOffsets[ins.opcode] then
      local node = context.byOffset[ins.offset]
      if node ~= nil and node.op ~= "unsupported" and not CONTROL_OPS[node.op] then
        addProblem(
          context,
          "control edge not represented by a control node",
          { offset = ins.offset, opcode = ins.opcode, node = node.op }
        )
      end
    end
    if ins.opcode == 26 then
      local node = context.byOffset[ins.offset]
      if
        node ~= nil
        and node.op ~= "unsupported"
        and node.op ~= "call"
        and node.op ~= "call_if"
        and node.op ~= "call_compared"
      then
        addProblem(
          context,
          "call edge not represented by a call node",
          { offset = ins.offset, opcode = ins.opcode, node = node and node.op }
        )
      end
    end
  end
end

local function isCrossScriptNode(node)
  if node == nil then
    return false
  end
  if node.op == "goto_script" or (node.op == "call" and node.label ~= nil) then
    return true
  end
  if (node.op == "goto_compared" or node.op == "call_compared") and node.script ~= nil then
    return true
  end
  if node.op == "if" and node.yes and node.yes[1] then
    local inner = node.yes[1]
    return inner.op == "goto_script" or (inner.op == "call" and inner.label ~= nil)
  end
  return false
end

local function verifyBranchTargets(context)
  for _, block in pairs(context.cfg.blocks) do
    local lastIns = context.script.instructions[block.indices[#block.indices]]
    local lastNode = lastIns ~= nil and context.byOffset[lastIns.offset] or nil
    for _, succ in ipairs(block.successors) do
      if
        (succ.kind == "branch" or succ.kind == "call")
        and succ.targetIndex == nil
        and not isCrossScriptNode(lastNode)
        and (lastNode == nil or lastNode.op ~= "unsupported")
      then
        addProblem(
          context,
          "branch target does not resolve to an instruction",
          { block = block.id, entryOffset = block.entryOffset, kind = succ.kind }
        )
      end
    end
  end
end

local function verifyExecutionBoundaries(context)
  for _, ins in ipairs(context.script.instructions) do
    local node = context.byOffset[ins.offset]
    if node ~= nil and node.op ~= "unsupported" then
      local foldOffsets = node.provenance and node.provenance.offsets or {}
      if #foldOffsets > 1 then
        if not FOLD_OPS[node.op] then
          addProblem(
            context,
            "multi-instruction node is not a documented fold",
            { offset = ins.offset, opcode = ins.opcode, node = node.op }
          )
        end
      else
        local classification = CommandCatalog.classification(ins.opcode)
        local boundary = nodeBlocks(node) or YIELD_OPS[node.op] == true
        if classification == CommandCatalog.NATIVE_WAIT and not boundary then
          addProblem(
            context,
            "native-wait instruction lacks a blocking translation",
            { offset = ins.offset, opcode = ins.opcode, node = node.op }
          )
        elseif classification == CommandCatalog.YIELD and not boundary then
          addProblem(
            context,
            "yield instruction lacks a run-phase boundary",
            { offset = ins.offset, opcode = ins.opcode, node = node.op }
          )
        elseif classification == CommandCatalog.STOP and not TERMINAL_OPS[node.op] then
          addProblem(
            context,
            "stop instruction translated to a non-terminal node",
            { offset = ins.offset, opcode = ins.opcode, node = node.op }
          )
        elseif classification == CommandCatalog.CONTINUE and boundary and node.op ~= "stop" then
          addProblem(
            context,
            "same-tick instruction folded into a blocking node",
            { offset = ins.offset, opcode = ins.opcode, node = node.op }
          )
        end
      end
    end
  end
end

local function regionHasUnsupported(context, label)
  local memberLabels = context.memberLabels
  local owner = memberLabels[label]
  if owner == nil then
    return nil
  end
  local targetScript = context.memberIr.scripts[owner]
  if targetScript == nil then
    return nil
  end
  local lowered = context.loweredCache[owner]
  if lowered == nil then
    lowered = SemanticLowering.lowerScript(targetScript, context.memberIr, {})
    context.loweredCache[owner] = lowered
  end
  local inRegion = false
  for _, item in ipairs(lowered.items) do
    if item.op == "label" then
      if item.name == label then
        inRegion = true
      elseif inRegion then
        break
      end
    elseif inRegion and (item.op == "stop" or item.op == "unsupported") then
      return item.op == "unsupported"
    end
  end
  return false
end

local function verifyCrossScriptTargets(context)
  if context.memberIr == nil then
    return
  end
  context.memberLabels = {}
  for _, memberScript in pairs(context.memberIr.scripts) do
    for _, ins in ipairs(memberScript.instructions) do
      if ins.label ~= nil then
        context.memberLabels[ins.label] = memberScript.index
      end
    end
  end
  context.loweredCache = {}
  local function walkCrossScript(list)
    for _, item in ipairs(list) do
      if item.op == "goto_script" or (item.op == "call" and item.label ~= nil) then
        local targetId = item.op == "goto_script" and item.script or item.target
        if item.label ~= nil and regionHasUnsupported(context, item.label) then
          addWarning(
            context,
            "cross-script target region contains unsupported nodes",
            { scriptId = targetId, label = item.label }
          )
        end
      end
      if item.op == "if" then
        walkCrossScript(item.yes)
        walkCrossScript(item.no)
      end
    end
  end
  walkCrossScript(context.steps)
end

local function verifyOperands(context)
  for _, ins in ipairs(context.script.instructions) do
    local checker = CHECKERS[ins.opcode]
    if checker ~= nil then
      local node = context.byOffset[ins.offset]
      if node ~= nil and node.op ~= "unsupported" then
        local message = checker(ins, node)
        if message ~= nil then
          addProblem(context, message, { offset = ins.offset, opcode = ins.opcode })
        end
      end
    end
  end
end

local function verifyCallReturnBalance(context)
  for _, balanceProblem in ipairs(context.cfg.balance.problems) do
    local preludeTolerant = context.prelude
      and (
        balanceProblem.message == "return below an empty script stack"
        or balanceProblem.message == "return with no matching call"
      )
    if preludeTolerant then
      addWarning(context, balanceProblem.message, balanceProblem.context)
    else
      addProblem(context, balanceProblem.message, balanceProblem.context)
    end
  end
  for _, balanceWarning in ipairs(context.cfg.balance.warnings) do
    addWarning(context, balanceWarning.message, balanceWarning.context)
  end
  local hasCall = false
  for _, ins in ipairs(context.script.instructions) do
    if CALL_OPS[ins.opcode] then
      hasCall = true
      break
    end
  end
  if not hasCall then
    for i, ins in ipairs(context.script.instructions) do
      if RETURN_OPS[ins.opcode] then
        local blockId = context.cfg.blockOfIndex[i]
        local message = "return without any call in the script"
        local isReachable = blockId ~= nil and context.cfg.reachable[blockId] == true
        if context.prelude or not isReachable then
          addWarning(context, message, { offset = ins.offset, opcode = ins.opcode })
        else
          addProblem(context, message, { offset = ins.offset, opcode = ins.opcode })
        end
      end
    end
  end
end

local function verifyMovementTermination(context)
  for _, reference in ipairs(context.cfg.movementReferences) do
    if reference.block == nil then
      addProblem(context, "ApplyMovement references a missing movement block", { offset = reference.offset })
    elseif not reference.block.terminated then
      addProblem(context, "movement sequence lacks an EndMovement terminator", { offset = reference.offset })
    elseif #reference.block.actions == 0 then
      addProblem(context, "movement sequence is empty", { offset = reference.offset })
    end
  end
end

local function finalizeReport(context)
  local unreachable = context.total - context.reachable
  if unreachable > 0 then
    addWarning(context, "script contains unreachable instructions", { count = unreachable })
  end
  local report = context.report
  report.total = context.total
  report.reachable = context.reachable
  report.unreachable = unreachable
  report.covered = context.covered
  report.reachableOmitted = context.reachableOmitted
  report.unsupportedCount = context.reachableUnsupported
  report.unsupported = context.unsupportedNodes
  report.irreducible = context.cfg.irreducibleRegions
  report.balance = context.cfg.balance
  report.complete = report.ok
    and context.covered + #(context.omissions or {}) >= context.total
    and context.reachableUnsupported == 0
  return report
end

-- Verify one script's final structured steps against its raw instructions
-- and CFG. The steps are the post-structuring, post-scrub program that is
-- actually emitted and executed; omissions are the lowering's documented
-- erasures (the only instructions allowed to disappear).
---@param steps table[]
---@param script table<string, unknown> raw script (instructions)
---@param memberIr table<string, unknown>|nil
---@param omissions table<string, unknown>|nil
---@return table<string, unknown> report
function Verifier.verifyScript(steps, script, memberIr, omissions)
  local context = newVerificationContext(steps, script, memberIr, omissions)
  verifyCoverage(context)
  verifyControlEdges(context)
  verifyBranchTargets(context)
  verifyExecutionBoundaries(context)
  verifyCrossScriptTargets(context)
  verifyOperands(context)
  verifyCallReturnBalance(context)
  verifyMovementTermination(context)
  return finalizeReport(context)
end

return Verifier
