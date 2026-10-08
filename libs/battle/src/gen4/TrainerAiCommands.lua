-- Closed opcode dispatch for the trainer interpreter
-- (pret/pokeheartgold asm/overlay_10_trainer_ai.s ov10_0221C278 dispatcher
-- with table ov10_0222B0B4 over the word stream at ov10_02220AAC). One
-- fixed table maps exactly the transcribed opcode set to small command
-- functions; handlers consume operands in source order and return the
-- original next word index, end-of-slot, or abort marker. Unknown
-- opcodes and missing battle facts fail closed with the original
-- structured errors. Nothing here is a registration surface, and nothing
-- reaches back into the program facade.

local BattleErrors = require("libs.battle.src.errors")
local Data = require("libs.battle.src.gen4.TrainerAiProgramData")
local Context = require("libs.battle.src.gen4.TrainerAiContext")
local Preview = require("libs.battle.src.gen4.TrainerAiPreview")

---@class TrainerAiCommands
local Commands = {}

-- Forward declaration for the ordered-history factor defined below.
local partyHistoryFactor
-- Opcodes 0-3 spend exactly one shared-stream draw when the command
-- executes, reduce it modulo 256, and skip the jump distance on </>/==/!=
-- respectively (handlers ov10_0221C384/C3C4/C404/C444). The draw happens
-- before the comparison, so reaching the command always consumes.
---@param state TrainerAiProgramState command state under execution
---@param limit integer threshold under comparison
---@param jump integer relative word distance under the taken branch
---@param kind integer 0/1/2/3 selecting the comparison
---@return integer? jump target under the taken branch, nil to fall through
local function randomGate(state, limit, jump, kind)
  local roll = Context.drawNow(state) % 256
  local take = false
  if kind == 0 then
    take = roll < limit
  elseif kind == 1 then
    take = roll > limit
  elseif kind == 2 then
    take = roll == limit
  else
    take = roll ~= limit
  end
  if take then
    return jump
  end
  return nil
end
---@param state TrainerAiProgramState command state under inspection
---@param battler integer battler identity under the percent read
---@return integer health percentage 0..100 of the battler
local function healthPercent(state, battler)
  local record = Context.battlerFacts(state, battler)
  local hp = record.hp --[[@as integer]]
  local maxHp = record.maxHp --[[@as integer]]
  if maxHp <= 0 then
    return 0
  end
  return math.floor((100 * hp) / maxHp)
end
-- Health-percentage conditional jumps (handlers ov10_0221C4B8/C510/C568/C5C0
-- for opcodes 5/6/7/8): 100 * hp / maxHp with integer division compares
-- against the operand as >=/<=/==/!= and skips the jump distance.
---@param state TrainerAiProgramState command state under execution
---@param selector integer battler selector under evaluation
---@param value integer percentage under comparison
---@param jump integer relative word distance under the taken branch
---@param kind integer 5/6/7/8 selecting the comparison
---@return integer? jump target under the taken branch, nil to fall through
local function healthGate(state, selector, value, jump, kind)
  local percent = healthPercent(state, Context.resolveBattler(state, selector))
  local take = false
  if kind == 5 then
    take = percent >= value
  elseif kind == 6 then
    take = percent <= value
  elseif kind == 7 then
    take = percent == value
  else
    take = percent ~= value
  end
  if take then
    return jump
  end
  return nil
end
-- Battler word bit-test jumps (handlers ov10_0221C618/C664 for opcodes 9/10
-- on the status word, ov10_0221C6B0/C6FC for opcodes 11/12 on the
-- secondary status word, ov10_0221C748/C790 for opcodes 13/14 on the
-- battler word at 0x2DC0): the masked test jumps on nonzero/zero.
---@param state TrainerAiProgramState command state under execution
---@param selector integer battler selector under evaluation
---@param mask integer bit mask under the test
---@param jump integer relative word distance under the taken branch
---@param field string battler fact under the test
---@param nonzero boolean true jumps when masked bits are set
---@return integer? jump target under the taken branch, nil to fall through
local function bitGate(state, selector, mask, jump, field, nonzero)
  local record = Context.battlerFacts(state, Context.resolveBattler(state, selector))
  local word = record[field] --[[@as integer]]
  if mask <= 0 or mask >= 4294967296 or mask % 1 ~= 0 then
    error(BattleErrors.missingBehavior("trainer programs test status bits", { mask = mask }))
  end
  -- The native masked test jumps when any masked bit is set.
  local hit = false
  local bit = 1
  local rest = mask
  while rest > 0 do
    if rest % 2 == 1 and (math.floor(word / bit) % 2) == 1 then
      hit = true
      break
    end
    rest = math.floor(rest / 2)
    bit = bit * 2
  end
  if hit == nonzero then
    return jump
  end
  return nil
end
-- Scratch-register ordered and identity jumps (handlers ov10_0221C878/C8A8
-- for opcodes 17/18, ov10_0221C938/C968 for opcodes 21/22, ov10_0221CEA4/CED4
-- for opcodes 34/35): the word scratch compares signed for 17/18 and
-- tests bits for 21/22.
---@param state TrainerAiProgramState command state under execution
---@param limit integer threshold under comparison
---@param jump integer relative word distance under the taken branch
---@param kind integer opcode selecting the comparison
---@return integer? jump target under the taken branch, nil to fall through
local function scratchGate(state, limit, jump, kind)
  local scratch = Context.asSigned(state.scratch % 4294967296)
  local take = false
  if kind == 17 then
    take = scratch < limit
  elseif kind == 18 then
    take = scratch > limit
  elseif kind == 34 then
    take = state.scratch == (limit % 4294967296)
  else
    take = state.scratch ~= (limit % 4294967296)
  end
  if take then
    return jump
  end
  return nil
end
-- Scratch bit-test jumps (handlers ov10_0221C938/C968): the word scratch
-- tests the mask for nonzero/zero membership.
---@param state TrainerAiProgramState command state under execution
---@param mask integer bit mask under the test
---@param jump integer relative word distance under the taken branch
---@param nonzero boolean true jumps when masked bits are set
---@return integer? jump target under the taken branch, nil to fall through
local function scratchBitGate(state, mask, jump, nonzero)
  if mask <= 0 or mask >= 4294967296 or mask % 1 ~= 0 then
    error(BattleErrors.missingBehavior("trainer programs test scratch bits", { mask = mask }))
  end
  local word = state.scratch % 4294967296
  local hit = false
  local bit = 1
  local rest = mask
  while rest > 0 do
    if rest % 2 == 1 and (math.floor(word / bit) % 2) == 1 then
      hit = true
      break
    end
    rest = math.floor(rest / 2)
    bit = bit * 2
  end
  if hit == nonzero then
    return jump
  end
  return nil
end
-- Current-move identity jumps (handlers ov10_0221C8D8/C908 for opcodes
-- 19/20 on the word scratch, ov10_0221C998/C9C8 for opcodes 23/24 on the
-- current move halfword): equality with the operand skips or falls
-- through per opcode polarity.
---@param value integer identity under comparison
---@param identity integer operand identity under comparison
---@param jump integer relative word distance under the taken branch
---@param equal boolean true jumps on equality
---@return integer? jump target under the taken branch, nil to fall through
local function identityGate(value, identity, jump, equal)
  if (value == identity) == equal then
    return jump
  end
  return nil
end
-- Inline membership jumps (handlers ov10_0221C9F8 for opcode 25,
-- ov10_0221CA4C for opcode 26): the word list at program words past the
-- operands ends at the -1 sentinel; opcode 25 jumps when the word scratch
-- matches a listed word, opcode 26 jumps when the scan exhausts without a
-- match.
---@param state TrainerAiProgramState command state under execution
---@param pc integer absolute word index of the command under execution
---@param offset integer relative word distance from past-operands to the list
---@param jump integer relative word distance under the taken branch
---@param member boolean true jumps on membership (opcode 25)
---@return integer? jump target under the taken branch, nil to fall through
local function listGate(state, pc, offset, jump, member)
  local words = Data.WORDS
  local after = pc + 3
  local found = false
  local index = 0
  while true do
    local word = Context.wordAt(words, after + offset + index)
    if word == 4294967295 then
      break
    end
    if word == (state.scratch % 4294967296) then
      found = true
      break
    end
    index = index + 1
    if index > 512 then
      error(BattleErrors.missingBehavior("trainer programs terminate their word lists", {}))
    end
  end
  if found == member then
    return after + jump
  end
  return nil
end
---@param state TrainerAiProgramState command state under execution
---@param moveId integer numeric move identity under power resolution
---@return integer compiled move power, zero for status moves
local function movePowerOf(state, moveId)
  if moveId == 0 then
    return 0
  end
  local facts = state.facts --[[@as table<string, unknown>]]
  local byId = facts.moveById --[[@as table<integer, table<string, unknown>>]]
  local record = byId[moveId]
  if type(record) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move facts", {
      move = moveId,
    }))
  end
  local power = record.power
  if type(power) ~= "number" or power % 1 ~= 0 or power < 0 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move power", {
      move = moveId,
    }))
  end
  return power --[[@as integer]]
end
-- Damaging-move roster jumps (handlers ov10_0221CA9C/CB00): opcode 27
-- jumps when the attacker holds no damaging move, opcode 28 jumps when it
-- holds at least one. Empty move identities never qualify.
---@param state TrainerAiProgramState command state under execution
---@param jump integer relative word distance under the taken branch
---@param present boolean true jumps when a damaging move is present
---@return integer? jump target under the taken branch, nil to fall through
local function damagingGate(state, jump, present)
  local facts = state.facts --[[@as table<string, unknown>]]
  local battler = facts.atk --[[@as integer]]
  local found = false
  for _, moveId in ipairs(Context.battlerMoveIds(state, battler)) do
    if moveId ~= 0 and movePowerOf(state, moveId) > 0 then
      found = true
      break
    end
  end
  if found == present then
    return jump
  end
  return nil
end
-- Current-move detail loads (handlers ov10_0221CD10 for opcode 31 reading
-- power, ov10_0221E178 for opcode 93 reading category, ov10_0221D084 for
-- opcode 40 reading effect, ov10_0221D068 for opcode 39 reading the
-- identity itself): the scratch register takes the fact for the move
-- under execution.
---@param state TrainerAiProgramState command state under execution
---@param field string move detail under the load
local function loadCurDetail(state, field)
  local facts = state.facts --[[@as table<string, unknown>]]
  local byId = facts.moveById --[[@as table<integer, table<string, unknown>>]]
  local record = byId[state.cur]
  if type(record) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move facts", {
      move = state.cur,
    }))
  end
  if field == "id" then
    state.scratch = state.cur
    return
  end
  local value = record[field]
  if type(value) == "string" then
    if field == "category" then
      if value == "physical" then
        state.scratch = 0
      elseif value == "special" then
        state.scratch = 1
      elseif value == "status" then
        state.scratch = 2
      else
        error(BattleErrors.missingBehavior("trainer evaluation reads its move category", {
          move = state.cur,
        }))
      end
      return
    end
    if field == "moveType" then
      local ids = Data.TYPE_IDS --[[@as table<string, integer>]]
      local numeric = ids[value]
      if numeric == nil then
        error(BattleErrors.missingBehavior("trainer evaluation reads its move type", { move = state.cur }))
      end
      state.scratch = numeric
      return
    end
  end
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move facts", {
      move = state.cur,
      field = field,
    }))
  end
  state.scratch = value --[[@as integer]]
end
-- Battler fact loads into scratch (handler ov10_0221CB80 for opcode 30):
-- the operand selects attacker/target type identities, the current move
-- type, or partner type identities. Partner battlers absent from the
-- battle read zero, matching zero-initialized battle memory.
---@param state TrainerAiProgramState command state under execution
---@param mode integer load selector under evaluation
local function loadBattlerFact(state, mode)
  local facts = state.facts --[[@as table<string, unknown>]]
  local atk = facts.atk --[[@as integer]]
  local tgt = facts.tgt --[[@as integer]]
  if mode == 4 then
    loadCurDetail(state, "moveType")
    return
  end
  local battler = nil ---@type integer?
  local field = "t1"
  if mode == 0 then
    battler = tgt
  elseif mode == 1 then
    battler = atk
  elseif mode == 2 then
    battler = tgt
    field = "t2"
  elseif mode == 3 then
    battler = atk
    field = "t2"
  elseif mode == 5 then
    battler = Context.partnerOf(tgt)
  elseif mode == 6 then
    battler = Context.partnerOf(atk)
  elseif mode == 7 then
    battler = Context.partnerOf(tgt)
  elseif mode == 8 then
    battler = Context.partnerOf(atk)
  else
    error(BattleErrors.missingBehavior("trainer programs load their battler facts", { mode = mode }))
  end
  assert(battler ~= nil, "battler fact loads resolve their battler")
  local record = Context.battlerFacts(state, battler)
  local value = record[field] --[[@as integer]]
  state.scratch = value
end
-- Eligible party count into scratch (handler ov10_0221CF8C for opcode
-- 38): counts conscious non-egg party members outside the battler's own
-- and partner slots. Empty and egg slots never occur in modeled battles
-- and fail closed if a roster ever carries them.
---@param state TrainerAiProgramState command state under execution
---@param selector integer battler selector owning the party under the count
local function countParty(state, selector)
  local facts = state.facts --[[@as table<string, unknown>]]
  local battler = Context.resolveBattler(state, selector)
  local parties = facts.parties --[[@as table<integer, table<integer, table<string, unknown>>>]]
  local members = parties[battler]
  if type(members) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its party facts", { battler = battler }))
  end
  local own = facts.partyIndex --[[@as table<integer, integer>]]
  local partner = facts.partyPartner --[[@as table<integer, integer>]]
  local count = 0
  for index, member in ipairs(members) do
    local entry = member --[[@as table<string, unknown>]]
    if index ~= own[battler] and index ~= partner[battler] then
      local hp = entry.hp
      local species = entry.species
      if type(hp) ~= "number" or hp % 1 ~= 0 then
        error(BattleErrors.missingBehavior("trainer evaluation reads its party health", {}))
      end
      if hp > 0 then
        if type(species) ~= "string" or species == "" or species == "EGG" then
          error(BattleErrors.missingBehavior("trainer evaluation reads its party species", {}))
        end
        count = count + 1
      end
    end
  end
  state.scratch = count
end
-- Attacking-side decider into scratch (handler ov10_0221D0A8 for opcode
-- 41): suppressed abilities clear to zero; the attacker and third-selector
-- cases store the battler ability; a stored entry ability wins next; the
-- trapping trio stores directly; otherwise the species abilities decide
-- with a parity draw on disagreement, defaulting to the nonzero one.
-- Species abilities resolve through the evaluation facts; battlers without
-- a modeled species ability pair fail closed.
---@param state TrainerAiProgramState command state under execution
---@param selector integer battler selector under evaluation
local function decideAttackerSide(state, selector)
  local facts = state.facts --[[@as table<string, unknown>]]
  local battler = Context.resolveBattler(state, selector)
  local record = Context.battlerFacts(state, battler)
  if record.suppressed == true then
    state.scratch = 0
    return
  end
  local atk = facts.atk --[[@as integer]]
  local ability = record.ability --[[@as integer]]
  if battler == atk or selector == 3 then
    state.scratch = ability
    return
  end
  local stored = record.entryAbility --[[@as integer]]
  if stored == nil then
    stored = ability
  end
  if stored ~= 0 then
    state.scratch = stored
    return
  end
  if Data.TRAPPING_IDS[ability] == true then
    state.scratch = ability
    return
  end
  local pair = record.speciesAbilities
  if type(pair) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its species abilities", {}))
  end
  local first = pair[1] --[[@as integer]]
  local second = pair[2] --[[@as integer]]
  if first == 0 or second == 0 then
    if first ~= 0 then
      state.scratch = first
    else
      state.scratch = second
    end
    return
  end
  local roll = Context.drawNow(state)
  if roll % 2 == 1 then
    state.scratch = first
  else
    state.scratch = second
  end
end
-- Party status scans (handlers ov10_0221D3AC/D4A0): opcode 44 jumps when
-- some eligible party member carries a masked status, opcode 45 jumps
-- when some eligible member is clear of it. Eligibility matches the
-- party count (conscious, non-egg, outside own and partner slots).
---@param state TrainerAiProgramState command state under execution
---@param selector integer battler selector owning the party under the scan
---@param mask integer status bits under the test
---@param jump integer relative word distance under the taken branch
---@param present boolean true jumps when a masked status is present
---@return integer? jump target under the taken branch, nil to fall through
local function partyStatusGate(state, selector, mask, jump, present)
  local facts = state.facts --[[@as table<string, unknown>]]
  local battler = Context.resolveBattler(state, selector)
  local parties = facts.parties --[[@as table<integer, table<integer, table<string, unknown>>>]]
  local members = parties[battler]
  if type(members) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its party facts", { battler = battler }))
  end
  local own = facts.partyIndex --[[@as table<integer, integer>]]
  local partner = facts.partyPartner --[[@as table<integer, integer>]]
  if mask <= 0 or mask >= 4294967296 or mask % 1 ~= 0 then
    error(BattleErrors.missingBehavior("trainer programs test party status bits", { mask = mask }))
  end
  for index, member in ipairs(members) do
    local entry = member --[[@as table<string, unknown>]]
    if index ~= own[battler] and index ~= partner[battler] then
      local hp = entry.hp --[[@as integer]]
      local species = entry.species --[[@as string]]
      if hp ~= 0 and species ~= nil and species ~= "" and species ~= "EGG" then
        local status = entry.status --[[@as integer]]
        if type(status) ~= "number" then
          error(BattleErrors.missingBehavior("trainer evaluation reads its party status", {}))
        end
        local hit = false
        local bit = 1
        local rest = mask
        while rest > 0 do
          if rest % 2 == 1 and (math.floor(status / bit) % 2) == 1 then
            hit = true
            break
          end
          rest = math.floor(rest / 2)
          bit = bit * 2
        end
        if hit == present then
          return jump
        end
      end
    end
  end
  return nil
end
-- Field weather classifier into scratch (handler ov10_0221D594 for opcode
-- 46): rain scores 2, sandstorm 3, sunlight 1, hail 4, fog 5, defaulting
-- to 0. The evaluation facts carry the classified field value.
---@param state TrainerAiProgramState command state under execution
local function classifyWeather(state)
  local facts = state.facts --[[@as table<string, unknown>]]
  local weather = facts.weatherClass --[[@as integer]]
  if type(weather) ~= "number" or weather % 1 ~= 0 or weather < 0 or weather > 5 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its field weather", {}))
  end
  state.scratch = weather
end
-- Known-move roster jumps (handlers ov10_0221DA24 for opcode 55,
-- ov10_0221DAE4 for opcode 56): mode 0 scans the entry move cache, mode
-- 1 the live moveset, mode 3 the live moveset of a conscious holder;
-- other modes return at once. Opcode 55 jumps when the move is found,
-- opcode 56 when it is missing; a fainted mode-3 holder never jumps.
---@param state TrainerAiProgramState command state under execution
---@param mode integer roster selector under the scan
---@param moveId integer numeric move identity under the search
---@param jump integer relative word distance under the taken branch
---@param present boolean true jumps when the move is present
---@return integer? jump target under the taken branch, nil to fall through
local function knownMoveGate(state, mode, moveId, jump, present)
  local facts = state.facts --[[@as table<string, unknown>]]
  local atk = facts.atk --[[@as integer]]
  local record = Context.battlerFacts(state, atk)
  if mode == 0 then
    local cache = record.entryMoves
    if type(cache) ~= "table" then
      error(BattleErrors.missingBehavior("trainer evaluation reads its entry moves", {}))
    end
    for _, identity in
      ipairs(cache --[[@as table<integer, integer>]])
    do
      if identity == moveId then
        if present then
          return jump
        end
        return nil
      end
    end
    if not present then
      return jump
    end
    return nil
  elseif mode == 1 or mode == 3 then
    if
      mode == 3
      and record.hp --[[@as integer]]
        <= 0
    then
      return nil
    end
    for _, identity in ipairs(Context.battlerMoveIds(state, atk)) do
      if identity == moveId then
        if present then
          return jump
        end
        return nil
      end
    end
    if not present then
      return jump
    end
    return nil
  end
  -- Mode 2 and other selectors return at once without scanning.
  return nil
end
-- Move-effect roster jumps (handlers ov10_0221DBA4 for opcode 57,
-- ov10_0221DC48 for opcode 58): mode 0 scans the entry move cache, mode
-- 1 the live moveset, and other modes return at once, for a move
-- carrying the operand effect. Opcode 57 jumps when such a move is
-- present, opcode 58 when absent.
---@param state TrainerAiProgramState command state under execution
---@param mode integer roster selector under the scan
---@param effect integer numeric move effect under the search
---@param jump integer relative word distance under the taken branch
---@param present boolean true jumps when the effect is present
---@return integer? jump target under the taken branch, nil to fall through
local function effectRosterGate(state, mode, effect, jump, present)
  local facts = state.facts --[[@as table<string, unknown>]]
  local atk = facts.atk --[[@as integer]]
  local byId = facts.moveById --[[@as table<integer, table<string, unknown>>]]
  local found = false
  if mode == 0 then
    local record = Context.battlerFacts(state, atk)
    local cache = record.entryMoves
    if type(cache) ~= "table" then
      error(BattleErrors.missingBehavior("trainer evaluation reads its entry moves", {}))
    end
    for _, moveId in
      ipairs(cache --[[@as table<integer, integer>]])
    do
      if moveId ~= 0 then
        local detail = byId[moveId]
        if type(detail) ~= "table" then
          error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move facts", {
            move = moveId,
          }))
        end
        if detail.effect == effect then
          found = true
          break
        end
      end
    end
  elseif mode == 1 then
    for _, moveId in ipairs(Context.battlerMoveIds(state, atk)) do
      if moveId ~= 0 then
        local detail = byId[moveId]
        if type(detail) ~= "table" then
          error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move facts", {
            move = moveId,
          }))
        end
        if detail.effect == effect then
          found = true
          break
        end
      end
    end
  else
    return nil
  end
  if found == present then
    return jump
  end
  return nil
end
-- Locked-move jumps (handler ov10_0221DD5C for opcode 60): mode 0 tests
-- the encore hold, mode 1 the disable hold, and other modes the encore
-- hold again; a match with the current move jumps. Holds arrive as
-- numeric move identities, zero for no hold.
---@param state TrainerAiProgramState command state under execution
---@param mode integer hold selector under the test
---@param jump integer relative word distance under the taken branch
---@return integer? jump target under the taken branch, nil to fall through
local function lockedMoveGate(state, mode, jump)
  local facts = state.facts --[[@as table<string, unknown>]]
  local held = facts.lockedMoves --[[@as table<string, integer>]]
  local hold = 0
  if mode == 1 then
    hold = held.disable or 0
  else
    hold = held.encore or 0
  end
  if hold == state.cur then
    return jump
  end
  return nil
end
-- Stat-stage conditional jumps (handlers ov10_0221D67C, ov10_0221D6D0,
-- ov10_0221D724, ov10_0221D778 for
-- opcodes 49/50/51/52): the battler's signed stage at the operand index
-- compares as </>/==/!= and skips the jump distance. Stages arrive in
-- native 0..12 centering.
---@param state TrainerAiProgramState command state under execution
---@param selector integer battler selector under evaluation
---@param index integer stage index under evaluation
---@param value integer stage value under comparison
---@param jump integer relative word distance under the taken branch
---@param kind integer opcode selecting the comparison
---@return integer? jump target under the taken branch, nil to fall through
local function stageGate(state, selector, index, value, jump, kind)
  local record = Context.battlerFacts(state, Context.resolveBattler(state, selector))
  local stages = record.stages --[[@as table<integer, integer>]]
  local stage = stages[index + 1]
  if type(stage) ~= "number" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its battle-local stages", {}))
  end
  local take = false
  if kind == 49 then
    take = stage < value
  elseif kind == 50 then
    take = stage > value
  elseif kind == 51 then
    take = stage == value
  else
    take = stage ~= value
  end
  if take then
    return jump
  end
  return nil
end
-- Program-entry guard (handler ov10_0221ED80 for opcode 81): attacker
-- and target of different parity fall through into the program; equal
-- parity skips to the operand distance (the shared program end). Trainer
-- evaluations always address a foe, so the guard always falls through in
-- singles; doubles candidates check it per target.
---@param state TrainerAiProgramState command state under execution
---@param jump integer relative word distance under the taken branch
---@return integer? jump target under the taken branch, nil to fall through
local function entryGuard(state, jump)
  local facts = state.facts --[[@as table<string, unknown>]]
  local atk = facts.atk --[[@as integer]]
  local tgt = facts.tgt --[[@as integer]]
  if (atk % 2) == (tgt % 2) then
    return jump
  end
  return nil
end
-- Move-effect conditional jumps (handlers ov10_0221D60C, ov10_0221D644): the effect
-- of the current move compares for equality (opcode 47) or inequality
-- (opcode 48) and skips the jump distance.
---@param state TrainerAiProgramState command state under execution
---@param effect integer numeric move effect under comparison
---@param jump integer relative word distance under the taken branch
---@param equal boolean true jumps on equality
---@return integer? jump target under the taken branch, nil to fall through
local function effectGate(state, effect, jump, equal)
  local facts = state.facts --[[@as table<string, unknown>]]
  local byId = facts.moveById --[[@as table<integer, table<string, unknown>>]]
  local record = byId[state.cur]
  if type(record) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move facts", {
      move = state.cur,
    }))
  end
  if (record.effect == effect) == equal then
    return jump
  end
  return nil
end
-- Speed-order conditional jumps (handlers ov10_0221CF04/CF48):
-- CheckSortSpeed orders the attacker and target with the operand flag;
-- opcode 36 jumps when the comparison matches the operand, opcode 37
-- when it differs.
---@param state TrainerAiProgramState command state under execution
---@param expect integer expected comparison result under the test
---@param jump integer relative word distance under the taken branch
---@param equal boolean true jumps on equality
---@return integer? jump target under the taken branch, nil to fall through
local function speedGate(state, expect, jump, equal)
  local result = Context.compareSpeed(state)
  if (result == expect) == equal then
    return jump
  end
  return nil
end
-- Single-operand battler loads into scratch (handlers ov10_0221DDF0 for
-- opcode 64 reading the held item, ov10_0221EA44 for opcode 66 reading
-- the low item nibble, ov10_0221EAC8 for opcode 68 reading a shifted
-- battler word, ov10_0221EB00 for opcode 69 reading the battle type,
-- ov10_0221EB18 for opcode 70 reading the recycled item, ov10_0221E5B0
-- for opcode 100 summing raised stages, ov10_0221E0BC for opcode 90
-- reading fling power, ov10_0221EDF8 for opcode 108 reading ability).
-- Unmapped facts fail closed; held-item facts resolve through the
-- evaluation item table.
---@param state TrainerAiProgramState command state under execution
---@param selector integer battler selector under evaluation
---@param kind integer opcode selecting the load
local function singleLoad(state, selector, kind)
  local facts = state.facts --[[@as table<string, unknown>]]
  local battler = Context.resolveBattler(state, selector)
  local record = Context.battlerFacts(state, battler)
  if kind == 64 then
    state.scratch = record.item --[[@as integer]]
  elseif kind == 66 then
    local gender = record.gender
    if gender ~= 0 and gender ~= 1 and gender ~= 2 then
      error(BattleErrors.missingBehavior("trainer evaluation reads its battler gender", {}))
    end
    state.scratch = gender
  elseif kind == 68 then
    partyHistoryFactor(state, battler)
  elseif kind == 69 then
    local battleType = facts.battleType --[[@as integer]]
    state.scratch = battleType
  elseif kind == 70 then
    local recycle = facts.recycle --[[@as table<integer, integer>]]
    state.scratch = recycle[battler] or 0
  elseif kind == 100 then
    local stages = record.stages --[[@as table<integer, integer>]]
    local total = 0
    for index = 1, 8 do
      local stage = stages[index] --[[@as integer]]
      if stage > 6 then
        total = total + (stage - 6)
      end
    end
    state.scratch = total
  elseif kind == 90 then
    local fling = record.flingPower
    if fling == nil then
      error(BattleErrors.missingBehavior("trainer evaluation reads its fling power", {}))
    end
    state.scratch = fling --[[@as integer]]
  elseif kind == 108 then
    state.scratch = record.ability --[[@as integer]]
  else
    error(BattleErrors.missingBehavior("trainer programs load their battler facts", { kind = kind }))
  end
end
-- Ordered distinct-move history factor (lastResortMoves tracking): the
-- evaluation facts carry the attacker's distinct used move identities in
-- first-use order. Beyond-range positions read zero; in-range positions
-- resolve in order; malformed entries fail closed.
---@param usedIds integer[] distinct used move identities under the factor
---@param position integer 1-based history position under the read
---@return integer move identity at the position, 0 when absent
local function historyAt(usedIds, position)
  if #usedIds == 1 and position <= 1 then
    local only = usedIds[1]
    if type(only) ~= "number" then
      error(BattleErrors.missingBehavior("trainer evaluation reads its ordered move history", {}))
    end
    return only
  end
  if #usedIds < position then
    return 0
  end
  local id = usedIds[position]
  if type(id) ~= "number" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its ordered move history", {}))
  end
  return id
end
-- History-scaled matchup factor into scratch (handler ov10_0221EAC8 for
-- opcode 68): bits of the first distinct used move select the factor;
-- fresh histories read zero.
---@param state TrainerAiProgramState command state under execution
---@param battler integer battler identity owning the history
function partyHistoryFactor(state, battler)
  local facts = state.facts --[[@as table<string, unknown>]]
  local histories = facts.usedIds --[[@as table<integer, integer[]>]]
  local used = histories[battler] or {}
  local first = historyAt(used, 1)
  state.scratch = math.floor(first / 32) % 8
end
-- Field-condition jump (handler ov10_0221DEF0 for opcode 86): the field
-- condition word tests the mask for any set bit.
---@param state TrainerAiProgramState command state under execution
---@param mask integer field bits under the test
---@param jump integer relative word distance under the taken branch
---@return integer? jump target under the taken branch, nil to fall through
local function fieldGate(state, mask, jump)
  local facts = state.facts --[[@as table<string, unknown>]]
  local word = facts.fieldWord --[[@as integer]]
  if mask <= 0 or mask >= 4294967296 or mask % 1 ~= 0 then
    error(BattleErrors.missingBehavior("trainer programs test field bits", { mask = mask }))
  end
  local hit = false
  local bit = 1
  local rest = mask
  while rest > 0 do
    if rest % 2 == 1 and (math.floor(word / bit) % 2) == 1 then
      hit = true
      break
    end
    rest = math.floor(rest / 2)
    bit = bit * 2
  end
  if hit then
    return jump
  end
  return nil
end
-- Side-flag jumps (handlers ov10_0221C7D8/C828): the battler's side word
-- tests the mask for nonzero (opcode 15) or zero (opcode 16) membership.
---@param state TrainerAiProgramState command state under execution
---@param selector integer battler selector under evaluation
---@param mask integer side bits under the test
---@param jump integer relative word distance under the taken branch
---@param nonzero boolean true jumps when masked bits are set
---@return integer? jump target under the taken branch, nil to fall through
local function sideGate(state, selector, mask, jump, nonzero)
  local facts = state.facts --[[@as table<string, unknown>]]
  local sideWords = facts.sideWords --[[@as table<integer, integer>]]
  local battler = Context.resolveBattler(state, selector)
  local word = sideWords[battler % 2] or 0
  if mask <= 0 or mask >= 4294967296 or mask % 1 ~= 0 then
    error(BattleErrors.missingBehavior("trainer programs test side bits", { mask = mask }))
  end
  local hit = false
  local bit = 1
  local rest = mask
  while rest > 0 do
    if rest % 2 == 1 and (math.floor(word / bit) % 2) == 1 then
      hit = true
      break
    end
    rest = math.floor(rest / 2)
    bit = bit * 2
  end
  if hit == nonzero then
    return jump
  end
  return nil
end
-- Target word byte checks (handlers ov10_0221ED10 for opcode 79 reading
-- the second byte of the target battler word, ov10_0221ED48 for opcode
-- 80 with inverted polarity): a nonzero byte jumps (79) or falls through
-- (80). The evaluation facts carry the byte per battler.
---@param state TrainerAiProgramState command state under execution
---@param jump integer relative word distance under the taken branch
---@param nonzero boolean true jumps when the byte is set
---@return integer? jump target under the taken branch, nil to fall through
local function targetByteGate(state, jump, nonzero)
  local facts = state.facts --[[@as table<string, unknown>]]
  local tgt = facts.tgt --[[@as integer]]
  local record = Context.battlerFacts(state, tgt)
  local byte = record.w88b1
  if byte == nil then
    error(BattleErrors.missingBehavior("trainer evaluation reads its target byte", {}))
  end
  if (byte ~= 0) == nonzero then
    return jump
  end
  return nil
end
-- Dual-type match clearing into scratch (handler ov10_0221CCB4 for opcode
-- 82): when the battler's first type differs from the first operand while
-- the second type matches the second, the scratch register clears to
-- zero; otherwise it is untouched.
---@param state TrainerAiProgramState command state under execution
---@param selector integer battler selector under evaluation
---@param first integer first type identity under comparison
---@param second integer second type identity under comparison
local function dualTypeClear(state, selector, first, second)
  local record = Context.battlerFacts(state, Context.resolveBattler(state, selector))
  if record.t1 ~= first and record.t2 == second then
    state.scratch = 0
  end
end
-- Sign-bit jump (handler ov10_0221EDB4 for opcode 84): the battler word
-- at 0x2DC8 jumps when its top bit is set. The evaluation facts carry
-- the word sign per battler.
---@param state TrainerAiProgramState command state under execution
---@param selector integer battler selector under evaluation
---@param jump integer relative word distance under the taken branch
---@return integer? jump target under the taken branch, nil to fall through
local function signGate(state, selector, jump)
  local record = Context.battlerFacts(state, Context.resolveBattler(state, selector))
  local negative = record.w88neg
  if negative == nil then
    error(BattleErrors.missingBehavior("trainer evaluation reads its battler word", {}))
  end
  if negative == true then
    return jump
  end
  return nil
end
-- Held-item identity jump with parity-selected fact (handler ov10_0221DE88
-- for opcode 85): equal battler/attacker parity reads the held item,
-- differing parity reads the per-battler halfword fact; a match with the
-- operand jumps. The halfword fact is not modeled and fails closed when
-- its path is taken.
---@param state TrainerAiProgramState command state under execution
---@param selector integer battler selector under evaluation
---@param expect integer identity under comparison
---@param jump integer relative word distance under the taken branch
---@return integer? jump target under the taken branch, nil to fall through
local function heldItemGate(state, selector, expect, jump)
  local facts = state.facts --[[@as table<string, unknown>]]
  local battler = Context.resolveBattler(state, selector)
  local atk = facts.atk --[[@as integer]]
  local value = nil ---@type integer?
  if (battler % 2) == (atk % 2) then
    value = Context.battlerFacts(state, battler).item --[[@as integer]]
  else
    error(BattleErrors.missingBehavior("trainer evaluation reads its per-battler fact", {
      battler = battler,
    }))
  end
  if value == expect then
    return jump
  end
  return nil
end
-- Current-slot power-point load (handler ov10_0221E0EC for opcode 91):
-- the scratch register takes the remaining power points of the
-- attacker's move in the slot under execution.
---@param state TrainerAiProgramState command state under execution
local function loadSlotPp(state)
  local facts = state.facts --[[@as table<string, unknown>]]
  local atk = facts.atk --[[@as integer]]
  local record = Context.battlerFacts(state, atk)
  local pp = record.pp --[[@as table<integer, integer>]]
  local value = pp[state.slot + 1]
  if value == nil then
    error(BattleErrors.missingBehavior("trainer evaluation reads its remaining power points", {}))
  end
  state.scratch = value
end
-- Moveset-size jump (handler ov10_0221E11C for opcode 92): battlers with
-- more than one move jump. Empty identities never count.
---@param state TrainerAiProgramState command state under execution
---@param selector integer battler selector under evaluation
---@param jump integer relative word distance under the taken branch
---@return integer? jump target under the taken branch, nil to fall through
local function movesetGate(state, selector, jump)
  local count = 0
  for _, moveId in ipairs(Context.battlerMoveIds(state, Context.resolveBattler(state, selector))) do
    if moveId ~= 0 then
      count = count + 1
    end
  end
  if count > 1 then
    return jump
  end
  return nil
end
-- Previous-move category load (handler ov10_0221E19C for opcode 94): the
-- scratch register takes the category of the target's previous move,
-- defaulting through the evaluation last-move facts.
---@param state TrainerAiProgramState command state under execution
local function loadPrevCategory(state)
  local facts = state.facts --[[@as table<string, unknown>]]
  local tgt = facts.tgt --[[@as integer]]
  local lasts = facts.lastMove --[[@as table<integer, integer>]]
  local moveId = lasts[tgt] or 0
  local byId = facts.moveById --[[@as table<integer, table<string, unknown>>]]
  local record = byId[moveId]
  if type(record) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move facts", {
      move = moveId,
    }))
  end
  local category = record.category
  if category == "physical" then
    state.scratch = 0
  elseif category == "special" then
    state.scratch = 1
  elseif category == "status" then
    state.scratch = 2
  else
    error(BattleErrors.missingBehavior("trainer evaluation reads its move category", { move = moveId }))
  end
end
-- Recent-entry flag into scratch (handler ov10_0221EA7C for opcode
-- 67): the scratch register takes 1 when the resolved battler's entry
-- word at 0x2DD4 reads at or past total turns, else 0. Records without
-- the word fail closed; absent battlers read the zeroed word.
---@param state TrainerAiProgramState command state under execution
---@param selector integer battler selector under evaluation
local function entryRecency(state, selector)
  local facts = state.facts --[[@as table<string, unknown>]]
  local record = Context.battlerFacts(state, Context.resolveBattler(state, selector))
  local word = record.w94
  if word == nil then
    error(BattleErrors.missingBehavior("trainer evaluation reads its battler word", {}))
  end
  local totalTurns = facts.round --[[@as integer]] - 1
  if word >= totalTurns then
    state.scratch = 1
  else
    state.scratch = 0
  end
end
-- Turn-advantage difference into scratch (handler ov10_0221E290 for
-- opcode 96): total turns minus the battler word at 0x2DD4.
---@param state TrainerAiProgramState command state under execution
---@param selector integer battler selector under evaluation
local function turnAdvantage(state, selector)
  local facts = state.facts --[[@as table<string, unknown>]]
  local record = Context.battlerFacts(state, Context.resolveBattler(state, selector))
  local word = record.w94
  if word == nil then
    error(BattleErrors.missingBehavior("trainer evaluation reads its battler word", {}))
  end
  state.scratch = facts.round --[[@as integer]] - 1 - word
end
-- Stage-difference into scratch (handler ov10_0221E600 for opcode 101):
-- the selector battler's stage minus the attacker stage at the operand
-- index, both in native centering.
---@param state TrainerAiProgramState command state under execution
---@param selector integer battler selector under evaluation
---@param index integer stage index under comparison
local function stageDifference(state, selector, index)
  local facts = state.facts --[[@as table<string, unknown>]]
  local atk = facts.atk --[[@as integer]]
  local first = Context.battlerFacts(state, Context.resolveBattler(state, selector))
  local second = Context.battlerFacts(state, atk)
  local a = (first.stages --[[@as table<integer, integer>]])[index + 1]
  local b = (second.stages --[[@as table<integer, integer>]])[index + 1]
  if type(a) ~= "number" or type(b) ~= "number" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its battle-local stages", {}))
  end
  state.scratch = (a - b) % 4294967296
end
-- Opcode 0 command: transcribed operand order and outcome vocabulary.
local function h00_random(state, op, _, after, arg)
  local target = randomGate(state, arg(1), arg(2), op)
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 4 command: transcribed operand order and outcome vocabulary.
local function h04_points(state, _, _, after, arg)
  Context.addPoints(state.points, state.slot, arg(1))
  return after
end
-- Opcode 5 command: transcribed operand order and outcome vocabulary.
local function h05_health(state, op, _, after, arg)
  local target = healthGate(state, arg(1), arg(2), arg(3), op)
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 9 command: transcribed operand order and outcome vocabulary.
local function h09_status_bit(state, op, _, after, arg)
  local target = bitGate(state, arg(1), arg(2), arg(3), "status", op == 9)
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 11 command: transcribed operand order and outcome vocabulary.
local function h11_status2_bit(state, op, _, after, arg)
  local target = bitGate(state, arg(1), arg(2), arg(3), "status2", op == 11)
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 13 command: transcribed operand order and outcome vocabulary.
local function h13_move_flags_bit(state, op, _, after, arg)
  local target = bitGate(state, arg(1), arg(2), arg(3), "moveFlags", op == 13)
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 15 command: transcribed operand order and outcome vocabulary.
local function h15_side(state, op, _, after, arg)
  local target = sideGate(state, arg(1), arg(2), arg(3), op == 15)
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 17 command: transcribed operand order and outcome vocabulary.
local function h17_scratch(state, op, _, after, arg)
  local target = scratchGate(state, arg(1), arg(2), op)
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 19 command: transcribed operand order and outcome vocabulary.
local function h19_identity(state, op, _, after, arg)
  local value = state.scratch % 4294967296
  local target = identityGate(value, arg(1) % 4294967296, arg(2), op == 19)
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 21 command: transcribed operand order and outcome vocabulary.
local function h21_scratch_bit(state, op, _, after, arg)
  local target = scratchBitGate(state, arg(1), arg(2), op == 21)
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 23 command: transcribed operand order and outcome vocabulary.
local function h23_cur_identity(state, op, _, after, arg)
  local target = identityGate(state.cur, arg(1), arg(2), op == 23)
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 25 command: transcribed operand order and outcome vocabulary.
local function h25_list(state, op, pc, after, arg)
  local target = listGate(state, pc, arg(1), arg(2), op == 25)
  if target ~= nil then
    return target
  end
  return after
end
-- Opcode 27 command: transcribed operand order and outcome vocabulary.
local function h27_damaging(state, op, _, after, arg)
  local target = damagingGate(state, arg(1), op == 28)
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 29 command: transcribed operand order and outcome vocabulary.
local function h29_round(state, _, _, after, _)
  local facts = state.facts --[[@as table<string, unknown>]]
  state.scratch = facts.round --[[@as integer]] - 1
  return after
end
-- Opcode 30 command: transcribed operand order and outcome vocabulary.
local function h30_battler_fact(state, _, _, after, arg)
  loadBattlerFact(state, arg(1))
  return after
end
-- Opcode 31 command: transcribed operand order and outcome vocabulary.
local function h31_cur_power(state, _, _, after, _)
  loadCurDetail(state, "power")
  return after
end
-- Opcode 32 command: transcribed operand order and outcome vocabulary.
local function h32_matchup_rank(state, _, _, after, arg)
  state.scratch = Preview.matchupRank(state, arg(1))
  return after
end
-- Opcode 33 command: transcribed operand order and outcome vocabulary.
local function h33_last_move(state, _, _, after, arg)
  local facts = state.facts --[[@as table<string, unknown>]]
  local lasts = facts.lastMove --[[@as table<integer, integer>]]
  state.scratch = lasts[Context.resolveBattler(state, arg(1))] or 0
  return after
end
-- Opcode 34 command: transcribed operand order and outcome vocabulary.
local function h34_scratch_equal(state, op, _, after, arg)
  local target = scratchGate(state, arg(1), arg(2), op)
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 36 command: transcribed operand order and outcome vocabulary.
local function h36_speed(state, op, _, after, arg)
  local target = speedGate(state, arg(1), arg(2), op == 36)
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 38 command: transcribed operand order and outcome vocabulary.
local function h38_party_count(state, _, _, after, arg)
  countParty(state, arg(1))
  return after
end
-- Opcode 39 command: transcribed operand order and outcome vocabulary.
local function h39_cur_to_scratch(state, _, _, after, _)
  state.scratch = state.cur
  return after
end
-- Opcode 40 command: transcribed operand order and outcome vocabulary.
local function h40_cur_effect(state, _, _, after, _)
  loadCurDetail(state, "effect")
  return after
end
-- Opcode 41 command: transcribed operand order and outcome vocabulary.
local function h41_attacker_side(state, _, _, after, arg)
  decideAttackerSide(state, arg(1))
  return after
end
-- Opcode 42 command: transcribed operand order and outcome vocabulary.
local function h42_max_damage(state, _, _, after, _)
  Preview.maxDamageClass(state)
  return after
end
-- Opcode 43 command: transcribed operand order and outcome vocabulary.
local function h43_damage_class(state, _, _, after, arg)
  local target = Preview.damageClassGate(state, arg(1), arg(2))
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 44 command: transcribed operand order and outcome vocabulary.
local function h44_party_status(state, op, _, after, arg)
  local target = partyStatusGate(state, arg(1), arg(2), arg(3), op == 44)
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 46 command: transcribed operand order and outcome vocabulary.
local function h46_weather(state, _, _, after, _)
  classifyWeather(state)
  return after
end
-- Opcode 47 command: transcribed operand order and outcome vocabulary.
local function h47_effect(state, op, _, after, arg)
  local target = effectGate(state, arg(1), arg(2), op == 47)
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 49 command: transcribed operand order and outcome vocabulary.
local function h49_stage(state, op, _, after, arg)
  local target = stageGate(state, arg(1), arg(2), arg(3), arg(4), op)
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 53 command: transcribed operand order and outcome vocabulary.
local function h53_knockout(state, op, _, after, arg)
  local target = Preview.knockoutGate(state, arg(1), arg(2), op)
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 55 command: transcribed operand order and outcome vocabulary.
local function h55_known_move(state, op, _, after, arg)
  local target = knownMoveGate(state, arg(1), arg(2), arg(3), op == 55)
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 57 command: transcribed operand order and outcome vocabulary.
local function h57_effect_roster(state, op, _, after, arg)
  local target = effectRosterGate(state, arg(1), arg(2), arg(3), op == 57)
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 59 command: transcribed operand order and outcome vocabulary.
local function h59_encore(state, _, _, after, arg)
  local target = Preview.encoreGate(state, arg(1), arg(3))
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 60 command: transcribed operand order and outcome vocabulary.
local function h60_locked_move(state, _, _, after, arg)
  local target = lockedMoveGate(state, arg(1), arg(2))
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 61 command: transcribed operand order and outcome vocabulary.
local function h61_abort(_, _, _, _, _)
  return "abort"
end
-- Opcode 62 command: transcribed operand order and outcome vocabulary.
local function h62_unsupported(state, op, _, _, _)
  error(BattleErrors.missingBehavior("trainer programs dispatch their transcribed commands", {
    bit = state.bit,
    op = op,
  }))
end
-- Opcode 64 command: transcribed operand order and outcome vocabulary.
local function h64_single(state, op, _, after, arg)
  singleLoad(state, arg(1), op)
  return after
end
-- Opcode 67 command: transcribed operand order and outcome vocabulary.
local function h67_recency(state, _, _, after, arg)
  entryRecency(state, arg(1))
  return after
end
-- Opcode 65 command: transcribed operand order and outcome vocabulary.
local function h65_item_effect(state, _, _, after, arg)
  Preview.itemEffectLoad(state, arg(1))
  return after
end
-- Opcode 71 command: transcribed operand order and outcome vocabulary.
local function h71_move_detail(state, op, _, after, _)
  Preview.moveDetailLoad(state, op)
  return after
end
-- Opcode 74 command: transcribed operand order and outcome vocabulary.
local function h74_protect_class(state, _, _, after, arg)
  Preview.protectClassLoad(state, arg(1))
  return after
end
-- Opcode 75 command: transcribed operand order and outcome vocabulary.
local function h75_unsupported_jump(state, op, _, _, _)
  error(BattleErrors.missingBehavior("trainer programs dispatch their transcribed commands", {
    bit = state.bit,
    op = op,
  }))
end
-- Opcode 76 command: transcribed operand order and outcome vocabulary.
local function h76_jump(_, _, _, after, arg)
  return after + arg(1)
end
-- Opcode 77 command: transcribed operand order and outcome vocabulary.
local function h77_endslot(_, _, _, _, _)
  return "endslot"
end
-- Opcode 79 command: transcribed operand order and outcome vocabulary.
local function h79_target_byte(state, _, _, after, arg)
  local target = targetByteGate(state, arg(1), true)
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 80 command: transcribed operand order and outcome vocabulary.
local function h80_target_byte_zero(state, _, _, after, arg)
  local target = targetByteGate(state, arg(1), false)
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 81 command: transcribed operand order and outcome vocabulary.
local function h81_entry_guard(state, _, _, after, arg)
  local target = entryGuard(state, arg(1))
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 82 command: transcribed operand order and outcome vocabulary.
local function h82_dual_type(state, _, _, after, arg)
  dualTypeClear(state, arg(1), arg(2), arg(3))
  return after
end
-- Opcode 83 command: transcribed operand order and outcome vocabulary.
local function h83_category(state, _, _, after, arg)
  Preview.categoryDecide(state, arg(1), arg(2))
  return after
end
-- Opcode 84 command: transcribed operand order and outcome vocabulary.
local function h84_sign(state, _, _, after, arg)
  local target = signGate(state, arg(1), arg(2))
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 85 command: transcribed operand order and outcome vocabulary.
local function h85_held_item(state, _, _, after, arg)
  local target = heldItemGate(state, arg(1), arg(2), arg(3))
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 86 command: transcribed operand order and outcome vocabulary.
local function h86_field(state, _, _, after, arg)
  local target = fieldGate(state, arg(1), arg(2))
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 88 command: transcribed operand order and outcome vocabulary.
local function h88_species_hp(state, _, _, after, arg)
  local target = Preview.speciesHpGate(state, arg(1), arg(2))
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 87 command: transcribed operand order and outcome vocabulary.
local function h87_unsupported_side(state, op, _, _, _)
  error(BattleErrors.missingBehavior("trainer programs read their side structures", {
    bit = state.bit,
    op = op,
  }))
end
-- Opcode 89 command: transcribed operand order and outcome vocabulary.
local function h89_pp_use(state, _, _, after, arg)
  local target = Preview.ppUseGate(state, arg(1), arg(2))
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 90 command: transcribed operand order and outcome vocabulary.
local function h90_single_fling(state, _, _, after, arg)
  singleLoad(state, arg(1), 90)
  return after
end
-- Opcode 91 command: transcribed operand order and outcome vocabulary.
local function h91_slot_pp(state, _, _, after, _)
  loadSlotPp(state)
  return after
end
-- Opcode 92 command: transcribed operand order and outcome vocabulary.
local function h92_moveset(state, _, _, after, arg)
  local target = movesetGate(state, arg(1), arg(2))
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 93 command: transcribed operand order and outcome vocabulary.
local function h93_cur_category(state, _, _, after, _)
  loadCurDetail(state, "category")
  return after
end
-- Opcode 94 command: transcribed operand order and outcome vocabulary.
local function h94_prev_category(state, _, _, after, _)
  loadPrevCategory(state)
  return after
end
-- Opcode 95 command: transcribed operand order and outcome vocabulary.
local function h95_speed_rank(state, _, _, after, arg)
  state.scratch = Preview.speedRank(state, arg(1))
  return after
end
-- Opcode 96 command: transcribed operand order and outcome vocabulary.
local function h96_turn_advantage(state, _, _, after, arg)
  turnAdvantage(state, arg(1))
  return after
end
-- Opcode 97 command: transcribed operand order and outcome vocabulary.
local function h97_party_matchup(state, _, _, after, arg)
  local target = Preview.partyMatchupGate(state, arg(1), arg(2))
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 98 command: transcribed operand order and outcome vocabulary.
local function h98_stay(state, _, _, after, arg)
  local target = Preview.stayCheck(state, arg(1))
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 99 command: transcribed operand order and outcome vocabulary.
local function h99_matchup_compare(state, _, _, after, arg)
  local target = Preview.matchupCompareGate(state, arg(1), arg(2), arg(3))
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 100 command: transcribed operand order and outcome vocabulary.
local function h100_single_stages(state, _, _, after, arg)
  singleLoad(state, arg(1), 100)
  return after
end
-- Opcode 101 command: transcribed operand order and outcome vocabulary.
local function h101_stage_difference(state, _, _, after, arg)
  stageDifference(state, arg(1), arg(2))
  return after
end
-- Opcode 102 command: transcribed operand order and outcome vocabulary.
local function h102_stat_compare(state, op, _, after, arg)
  local target = Preview.statCompareGate(state, arg(1), arg(2), arg(3), op)
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 105 command: transcribed operand order and outcome vocabulary.
local function h105_ally_rank(state, _, _, after, arg)
  state.scratch = Preview.allyMatchupRank(state, arg(1))
  return after
end
-- Opcode 106 command: transcribed operand order and outcome vocabulary.
local function h106_switch_in(state, op, _, after, arg)
  local target = Preview.switchInGate(state, arg(1), arg(2), op == 106)
  if target ~= nil then
    return after + target
  end
  return after
end
-- Opcode 108 command: transcribed operand order and outcome vocabulary.
local function h108_single_ability(state, _, _, after, arg)
  singleLoad(state, arg(1), 108)
  return after
end

-- Fixed dispatch over exactly the transcribed opcode set. Slots without a
-- transcribed command stay absent and fail closed at the call site. Every
-- handler consumes operands in source order from the shared reader and
-- returns the original next word index, end-of-slot, or abort marker.
---@alias TrainerAiCommand fun(state: TrainerAiProgramState, op: integer, pc: integer, after: integer, arg: fun(index: integer): integer): integer|string
---@type table<integer, TrainerAiCommand>
local handlers = {
  [0] = h00_random,
  [1] = h00_random,
  [2] = h00_random,
  [3] = h00_random,
  [4] = h04_points,
  [5] = h05_health,
  [6] = h05_health,
  [7] = h05_health,
  [8] = h05_health,
  [9] = h09_status_bit,
  [10] = h09_status_bit,
  [11] = h11_status2_bit,
  [12] = h11_status2_bit,
  [13] = h13_move_flags_bit,
  [14] = h13_move_flags_bit,
  [15] = h15_side,
  [16] = h15_side,
  [17] = h17_scratch,
  [18] = h17_scratch,
  [19] = h19_identity,
  [20] = h19_identity,
  [21] = h21_scratch_bit,
  [22] = h21_scratch_bit,
  [23] = h23_cur_identity,
  [24] = h23_cur_identity,
  [25] = h25_list,
  [26] = h25_list,
  [27] = h27_damaging,
  [28] = h27_damaging,
  [29] = h29_round,
  [30] = h30_battler_fact,
  [31] = h31_cur_power,
  [32] = h32_matchup_rank,
  [33] = h33_last_move,
  [34] = h34_scratch_equal,
  [35] = h34_scratch_equal,
  [36] = h36_speed,
  [37] = h36_speed,
  [38] = h38_party_count,
  [39] = h39_cur_to_scratch,
  [40] = h40_cur_effect,
  [41] = h41_attacker_side,
  [42] = h42_max_damage,
  [43] = h43_damage_class,
  [44] = h44_party_status,
  [45] = h44_party_status,
  [46] = h46_weather,
  [47] = h47_effect,
  [48] = h47_effect,
  [49] = h49_stage,
  [50] = h49_stage,
  [51] = h49_stage,
  [52] = h49_stage,
  [53] = h53_knockout,
  [54] = h53_knockout,
  [55] = h55_known_move,
  [56] = h55_known_move,
  [57] = h57_effect_roster,
  [58] = h57_effect_roster,
  [59] = h59_encore,
  [60] = h60_locked_move,
  [61] = h61_abort,
  [62] = h62_unsupported,
  [63] = h62_unsupported,
  [64] = h64_single,
  [65] = h65_item_effect,
  [66] = h64_single,
  [67] = h67_recency,
  [68] = h64_single,
  [69] = h64_single,
  [70] = h64_single,
  [71] = h71_move_detail,
  [72] = h71_move_detail,
  [73] = h71_move_detail,
  [74] = h74_protect_class,
  [75] = h75_unsupported_jump,
  [76] = h76_jump,
  [77] = h77_endslot,
  [79] = h79_target_byte,
  [80] = h80_target_byte_zero,
  [81] = h81_entry_guard,
  [82] = h82_dual_type,
  [83] = h83_category,
  [84] = h84_sign,
  [85] = h85_held_item,
  [86] = h86_field,
  [87] = h87_unsupported_side,
  [88] = h88_species_hp,
  [89] = h89_pp_use,
  [90] = h90_single_fling,
  [91] = h91_slot_pp,
  [92] = h92_moveset,
  [93] = h93_cur_category,
  [94] = h94_prev_category,
  [95] = h95_speed_rank,
  [96] = h96_turn_advantage,
  [97] = h97_party_matchup,
  [98] = h98_stay,
  [99] = h99_matchup_compare,
  [100] = h100_single_stages,
  [101] = h101_stage_difference,
  [102] = h102_stat_compare,
  [103] = h102_stat_compare,
  [104] = h102_stat_compare,
  [105] = h105_ally_rank,
  [106] = h106_switch_in,
  [107] = h106_switch_in,
  [108] = h108_single_ability,
}

--- Executes one program command at the program counter.
---@param state TrainerAiProgramState command state under execution
---@param op integer opcode under dispatch
---@param pc integer absolute word index of the command
---@return integer|string next program counter, 'endslot', or 'abort'
function Commands.execute(state, op, pc)
  local words = Data.WORDS
  local after = pc + 1 + (Data.ARITY[op] or 0)
  local function arg(index)
    return Context.signed(Context.wordAt(words, pc + index))
  end
  local handler = handlers[op]
  if handler == nil then
    error(BattleErrors.missingBehavior("trainer programs dispatch their transcribed commands", {
      bit = state.bit,
      op = op,
    }))
  end
  return handler(state, op, pc, after, arg)
end

-- Dispatch reads stay single-sourced in the context owner; the command
-- owner surfaces the fetch its facade step shares.
Commands.fetchOp = Context.fetchOp

return Commands
