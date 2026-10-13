-- Decode source-confirmed battle animation commands into semantic records.
-- Dispatch follows asm/overlay_07.s::ov07_02234DE8
-- (pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36).
-- Unknown runtime/resource inputs fail with their native member byte offset.

local Errors = require("libs.errors.src.Errors")

---@class BattleAnimationCompiler
local BattleAnimationCompiler = {}

local UNRESOLVED_SOURCE_INPUTS = {
  [21] = "battle background resource",
  [46] = "battler animation callback",
  [47] = "battler animation callback",
  [48] = "battler animation callback",
  [49] = "battler animation callback",
  [57] = "managed sprite resources",
  [58] = "battler sprite resources",
  [74] = "sprite character resource",
  [75] = "sprite palette resource",
  [76] = "sprite cell resource",
  [77] = "sprite animation resource",
  [79] = "managed sprite template",
}

---@class BattleAnimationInstruction one normalized instruction without native identities
---@field op string normalized operation
---@field values integer[]|nil source-ordered semantic parameter values
---@field callback string|nil resolved semantic callback key
---@field sound string|nil resolved semantic sound key
---@field target integer|nil normalized instruction index
---@field taskKind string|nil semantic task scheduled by this instruction
---@field taskContext string|nil semantic callback context
---@field battlerTarget string|nil semantic battler target
---@field actionProfile string|nil source-resolved action behavior
---@field resource string|nil semantic resource key
---@field resourceKeys table<string, string>|nil selected semantic resources
---@field resourceCases table<integer, string>|nil runtime-selected resources
---@field callbackCases table<integer, string>|nil runtime-selected callbacks
---@field runtimeSelection string|nil runtime source-selection rule
---@field continuationSlot integer|nil producer-derived task slot
---@field parameters table<string, unknown>|nil semantic callback parameters
---@field context string|nil semantic callback context
---@field vanished boolean|nil picture visibility state
---@field pictureSets table<string, string>|nil picture sets selected by visibility state

---@class BattleAnimationProbe source program stream
---@field key string program identity
---@field stream string|nil native little-endian u32 command stream
---@field callbacks table<integer, string>|nil explicit source-selector to semantic callback mapping
---@field sounds table<integer, string>|nil explicit sound selector to semantic sound mapping
---@field resolveSourceInput fun(role: string, operands: integer[]): table<string, unknown>|nil build-only source resolver

---@class BattleAnimationProgram one normalized program without native identities
---@field key string program identity
---@field entry string entry label
---@field instructions BattleAnimationInstruction[] normalized instructions in order
---@field subprograms table<string, unknown> empty until a source-resolved call graph is provided
---@field taskKinds string[] empty until source task selectors have semantic mappings
---@field sourceOffsets integer[] producer-only source byte offset for each instruction

local function sources()
  return require("romdump.src.config.BattleAnimationSources")
end

---@param key string
---@param offset integer
---@param message string
---@param cursorOffset integer?
---@return Errors.Error
local function decodeError(key, offset, message, cursorOffset)
  return Errors.new(
    "BATTLE_ANIMATION_STREAM_INVALID",
    "program " .. key .. " at byte offset " .. offset .. ": " .. message,
    {
      program = key,
      offset = offset,
      cursorOffset = cursorOffset,
    }
  )
end

---@param key string program key
---@param offset integer command byte offset
---@param result table<string, unknown> resolved source-selection output
---@param requiredSlots string[] semantic resource slots required by the handler
---@param optionalSlots? table<string, boolean> source-proven optional semantic resource slots
---@return table<string, string> resource keys
local function checkSourceInputResult(key, offset, result, requiredSlots, optionalSlots)
  if type(result) ~= "table" then
    error(decodeError(key, offset, "source resolver returned an invalid selection record"), 0)
  end
  for field in pairs(result) do
    if
      field ~= "resourceKeys"
      and field ~= "taskKind"
      and field ~= "callback"
      and field ~= "runtimeSelection"
      and field ~= "battlerTarget"
      and field ~= "actionProfile"
      and field ~= "callbackCases"
      and field ~= "context"
      and field ~= "parameters"
      and field ~= "op"
      and field ~= "pictureSets"
      and field ~= "vanished"
    then
      error(decodeError(key, offset, "source resolver returned an unsupported field " .. tostring(field)), 0)
    end
  end
  local resourceKeys = result.resourceKeys
  if #requiredSlots == 0 and resourceKeys == nil then
    return {}
  end
  if type(resourceKeys) ~= "table" then
    error(decodeError(key, offset, "source resolver returned no semantic resource keys"), 0)
  end
  local expected = {}
  for _, slot in ipairs(requiredSlots) do
    expected[slot] = true
  end
  local allowedOptionalSlots = optionalSlots or {}
  for slot, resourceKey in pairs(resourceKeys) do
    if
      (not expected[slot] and not allowedOptionalSlots[slot])
      or type(resourceKey) ~= "string"
      or resourceKey == ""
    then
      error(decodeError(key, offset, "source resolver returned an invalid semantic resource key"), 0)
    end
    expected[slot] = nil
  end
  for slot in pairs(expected) do
    error(decodeError(key, offset, "source resolver omitted semantic resource slot " .. slot), 0)
  end
  assert(type(resourceKeys) == "table", "validated source resources remain a table")
  return resourceKeys
end

---@param stream string
---@param key string
---@param offset integer
---@return integer
local function readWord(stream, key, offset)
  if offset < 0 or offset + 4 > #stream then
    error(decodeError(key, offset, "truncated 32-bit command word"), 0)
  end
  local a, b, c, d = string.byte(stream, offset + 1, offset + 4)
  return a + b * 256 + c * 65536 + d * 16777216
end

---@param opcode integer
---@param stream string
---@param key string
---@param start integer
---@param offset integer
---@return integer next offset
local function readUnresolvedFrame(opcode, stream, key, start, offset)
  local fixedWords = {
    [3] = 1,
    [4] = 0,
    [11] = 1,
    [16] = 2,
    [18] = 2,
    [21] = 1,
    [22] = 2,
    [23] = 1,
    [24] = 5,
    [25] = 4,
    [26] = 3,
    [30] = 3,
    [31] = 2,
    [33] = 1,
    [34] = 3,
    [35] = 5,
    [36] = 5,
    [46] = 3,
    [47] = 4,
    [48] = 8,
    [49] = 6,
    [51] = 2,
    [52] = 3,
    [53] = 1,
    [56] = 1,
    [57] = 1,
    [58] = 4,
    [61] = 1,
    [62] = 2,
    [63] = 2,
    [65] = 3,
    [68] = 1,
    [69] = 1,
    [73] = 8,
    [74] = 2,
    [75] = 3,
    [76] = 2,
    [77] = 2,
    [79] = 8,
    [82] = 3,
    [86] = 3,
  }
  if opcode == 45 then
    local count = readWord(stream, key, offset + 4)
    if count > 10 then
      error(decodeError(key, start, "parameter count exceeds the ten-slot context"), 0)
    end
    return offset + 8 + count * 4
  end
  if opcode == 78 then
    local countOffset = offset + 8 * 4
    local count = readWord(stream, key, countOffset)
    if count > 10 then
      error(decodeError(key, start, "configured sprite parameter count exceeds the ten-slot context", countOffset), 0)
    end
    for index = 0, count - 1 do
      readWord(stream, key, countOffset + 4 + index * 4)
    end
    return countOffset + 4 + count * 4
  end
  local count = fixedWords[opcode]
  if count == nil then
    error(decodeError(key, start, "cursor framing depends on live interpreter state", offset), 0)
  end
  for index = 0, count - 1 do
    readWord(stream, key, offset + index * 4)
  end
  return offset + count * 4
end

---@param value integer
---@return integer
local function signed16(value)
  value = value % 65536
  if value >= 32768 then
    return value - 65536
  end
  return value
end

---@param value integer
---@return integer
local function signed8(value)
  value = value % 256
  if value >= 128 then
    return value - 256
  end
  return value
end

---@param key string
---@param selector integer
---@param callbacks table<integer, string>|nil
---@param offset integer
---@return string resolved semantic callback key
local function resolveCallback(key, selector, callbacks, offset)
  local callback = callbacks and callbacks[selector]
  if type(callback) ~= "string" or callback == "" then
    error(decodeError(key, offset, "unresolved callback selector"), 0)
  end
  assert(type(callback) == "string" and callback ~= "", "callback resolver returns a semantic key")
  return callback
end

---@param key string
---@param selector integer
---@param sounds table<integer, string>|nil
---@param offset integer
---@return string resolved semantic sound key
local function resolveSound(key, selector, sounds, offset)
  local sound = sounds and sounds[selector]
  if sound == nil then
    sound = require("romdump.src.catalog.hgss.sndseq").byId[selector]
  end
  if type(sound) ~= "string" or sound == "" then
    error(decodeError(key, offset, "unresolved sound selector"), 0)
  end
  assert(type(sound) == "string" and sound ~= "", "sound resolver returns a semantic key")
  return sound
end

-- Decode the subset whose source cursor and observable normalized meaning are
-- fully established by the pinned handlers. Other valid handlers fail closed
-- until their runtime-dependent selectors and resources have semantic inputs.
---@param key string
---@param stream string
---@param callbacks table<integer, string>|nil
---@param sounds table<integer, string>|nil
---@param resolveSourceInput fun(role: string, operands: integer[]): table<string, unknown>|nil
---@return BattleAnimationInstruction[]
---@return integer[] instruction byte offsets
local function decodeNativeStream(key, stream, callbacks, sounds, resolveSourceInput)
  if type(stream) ~= "string" or #stream == 0 or #stream % 4 ~= 0 then
    error(decodeError(key, 0, "command stream must contain complete 32-bit words"), 0)
  end
  local instructions = {}
  local offset = 0 ---@type integer?
  local targetOffsets = {}
  local instructionOffsets = {}
  local pendingOffsets = {}
  local parsedOffsets = {}
  while true do
    while offset >= #stream or parsedOffsets[offset] do
      offset = nil
      while #pendingOffsets > 0 do
        local candidate = table.remove(pendingOffsets, 1)
        if candidate < #stream and not parsedOffsets[candidate] then
          offset = candidate
          break
        end
      end
      if offset == nil then
        break
      end
    end
    if offset == nil then
      break
    end
    local start = offset
    parsedOffsets[start] = true
    for pendingIndex = #pendingOffsets, 1, -1 do
      if pendingOffsets[pendingIndex] == start then
        table.remove(pendingOffsets, pendingIndex)
      end
    end
    instructionOffsets[#instructionOffsets + 1] = start
    local opcode = readWord(stream, key, offset)
    offset = offset + 4
    local label = sources().handlerLabel(opcode)
    if label == nil then
      error(decodeError(key, start, "unknown dispatch opcode " .. tostring(opcode)), 0)
    end
    local instruction
    if sources().isSourceNoop(opcode) then
      instruction = { op = "noop" }
    elseif opcode == 0 then
      instruction = { op = "interpreter-wait", values = { readWord(stream, key, offset) } }
      offset = offset + 4
    elseif opcode == 5 then
      local soundId = readWord(stream, key, offset) % 65536
      if soundId == 0 then
        instruction = { op = "noop" }
      else
        local soundKey = resolveSound(key, soundId, sounds, start)
        instruction = { op = "play-sound", sound = soundKey }
      end
      offset = offset + 4
    elseif opcode == 8 then
      instruction = {
        op = "set-blend-alpha",
        values = { readWord(stream, key, offset) % 65536, readWord(stream, key, offset + 4) % 65536 },
      }
      offset = offset + 8
    elseif opcode == 9 then
      instruction = { op = "reset-blend-alpha" }
    elseif opcode == 12 then
      local slot = readWord(stream, key, offset)
      local value = readWord(stream, key, offset + 4)
      instruction = slot >= 10 and { op = "noop" } or { op = "set-parameter", values = { slot, value } }
      offset = offset + 8
    elseif opcode == 17 then
      local component = readWord(stream, key, offset)
      local value = signed16(readWord(stream, key, offset + 4))
      instruction = { op = "set-background-component", values = { component, value } }
      offset = offset + 8
    elseif opcode == 15 then
      local skipWords = readWord(stream, key, offset)
      offset = offset + skipWords * 4
      if offset > #stream then
        error(decodeError(key, start, "word-count skip leaves the program"), 0)
      end
      instruction = { op = "skip-words" }
      targetOffsets[#targetOffsets + 1] = { instruction = #instructions + 1, offset = offset }
    elseif opcode == 32 then
      readWord(stream, key, offset)
      readWord(stream, key, offset + 4)
      instruction = { op = "clear-background-plane", values = { 2 } }
      offset = offset + 8
    elseif opcode == 4 then
      instruction = { op = "reset-battle-presentation" }
    elseif opcode == 56 then
      instruction = { op = "create-managed-sprite-manager" }
    elseif opcode == 59 then
      instruction = { op = "dispose-shared-sprite-manager" }
    elseif opcode == 1 then
      -- ov07_0221C70C retries this opcode while pending and advances past it at zero.
      instruction = {
        op = "wait-interpreter-counter",
        cursorRule = "pending-redispatch-current-opcode; zero-advances-past-current-opcode",
      }
      targetOffsets[#targetOffsets + 1] = {
        instruction = #instructions + 1,
        offset = start,
        field = "branchTarget",
      }
    elseif opcode == 19 or opcode == 20 then
      instruction = {
        op = "wait-for-battle-phase",
        values = { opcode == 19 and 2 or 0 },
        cursorRule = "advance-when-phase-matches",
      }
    elseif opcode == 29 then
      instruction = { op = "wait-for-sound", values = { 90 }, cursorRule = "advance-when-sound-finishes" }
    elseif opcode == 22 then
      local soundId = readWord(stream, key, offset) % 65536
      local pan = signed8(readWord(stream, key, offset + 4))
      if soundId == 0 then
        instruction = { op = "noop" }
      else
        instruction = {
          op = "play-positioned-sound",
          sound = resolveSound(key, soundId, sounds, start),
          values = { pan },
        }
      end
      offset = offset + 8
    elseif opcode == 23 then
      instruction = { op = "stop-positioned-sound", values = { signed8(readWord(stream, key, offset)) } }
      offset = offset + 4
    elseif opcode == 24 then
      local soundId = readWord(stream, key, offset) % 65536
      instruction = {
        op = "submit-sound-action",
        sound = resolveSound(key, soundId, sounds, start),
        taskKind = "positioned-sound-motion",
        values = {
          signed8(readWord(stream, key, offset + 4)),
          signed8(readWord(stream, key, offset + 8)),
          signed8(readWord(stream, key, offset + 12)),
          readWord(stream, key, offset + 16) % 256,
        },
      }
      offset = offset + 20
    elseif opcode == 25 then
      local soundId = readWord(stream, key, offset) % 65536
      instruction = {
        op = "submit-sound-action",
        sound = resolveSound(key, soundId, sounds, start),
        taskKind = "repeated-sound-playback",
        values = {
          signed8(readWord(stream, key, offset + 4)),
          readWord(stream, key, offset + 8) % 256,
          readWord(stream, key, offset + 12) % 256,
        },
      }
      offset = offset + 16
    elseif opcode == 26 then
      local soundId = readWord(stream, key, offset) % 65536
      instruction = {
        op = "submit-sound-action",
        sound = resolveSound(key, soundId, sounds, start),
        taskKind = "delayed-sound-playback",
        values = {
          signed8(readWord(stream, key, offset + 4)),
          readWord(stream, key, offset + 8) % 256,
        },
      }
      offset = offset + 12
    elseif opcode == 35 or opcode == 36 then
      local soundId = readWord(stream, key, offset) % 65536
      instruction = {
        op = "submit-sound-action",
        sound = resolveSound(key, soundId, sounds, start),
        taskKind = "positioned-sound-motion",
        values = {
          signed8(readWord(stream, key, offset + 4)),
          signed8(readWord(stream, key, offset + 8)),
          signed8(readWord(stream, key, offset + 12)),
          readWord(stream, key, offset + 16) % 256,
        },
      }
      offset = offset + 20
    elseif opcode >= 46 and opcode <= 49 then
      local definition = sources().sourceInput(opcode)
      assert(definition ~= nil and definition.operandCount ~= nil, "particle handler frame is source-declared")
      local operands = {}
      for index = 1, definition.operandCount do
        operands[index] = readWord(stream, key, offset + (index - 1) * 4)
      end
      if opcode == 47 and operands[2] > 70 then
        error(
          decodeError(key, start, "particle continuation slot is outside the source-allocated table", offset + 4),
          0
        )
      end
      local resolved = resolveSourceInput and resolveSourceInput("battler-particle-action", operands)
      if type(resolved) ~= "table" then
        error(
          decodeError(
            key,
            start,
            "handler " .. label .. " requires an unresolved particle action profile",
            offset + #operands * 4
          ),
          0
        )
      end
      assert(type(resolved) == "table", "particle resolver returns a selection table")
      if resolved.taskKind ~= "battler-effect-continuation" then
        error(
          decodeError(key, start, "particle action resolver returned an unknown task kind", offset + #operands * 4),
          0
        )
      end
      local emitterPosition = sources().resolveBattlerPosition(operands[1])
      if emitterPosition == nil then
        error(decodeError(key, start, "particle handler has an invalid battler effect slot", offset + 4), 0)
      end
      assert(type(emitterPosition) == "string", "resolved battler position is semantic")
      instruction = {
        op = "create-parameterized-battler-effect",
        actionProfile = resolved.actionProfile,
        emitterPosition = emitterPosition,
        taskKind = resolved.taskKind,
      }
      if opcode == 46 or opcode == 47 then
        if
          type(resolved.actionProfile) ~= "string"
          or type(resolved.resource) ~= "string"
          or resolved.resourceCases ~= nil
          or resolved.callbackCases ~= nil
          or resolved.runtimeSelection ~= nil
        then
          error(
            decodeError(
              key,
              start,
              "particle action resolver returned an invalid fixed resource plan",
              offset + #operands * 4
            ),
            0
          )
        end
        instruction.resource = resolved.resource
        if opcode == 47 then
          instruction.continuationSlot = operands[2]
        end
      else
        if
          resolved.runtimeSelection ~= "battler-particle-position-pair"
          or type(resolved.resourceCases) ~= "table"
          or type(resolved.actionProfile) ~= "string"
          or resolved.resource ~= nil
          or resolved.callbackCases ~= nil
        then
          error(
            decodeError(
              key,
              start,
              "particle action resolver returned an invalid position-pair resource map",
              offset + #operands * 4
            ),
            0
          )
        end
        instruction.runtimeSelection = resolved.runtimeSelection
        instruction.resourceCases = resolved.resourceCases
      end
      offset = offset + #operands * 4
    elseif opcode == 50 then
      instruction = { op = "wait-for-battler-effects", cursorRule = "advance-when-effects-finish" }
    elseif opcode == 51 then
      local battler = readWord(stream, key, offset)
      local memberId = readWord(stream, key, offset + 4)
      local resource
      if resolveSourceInput ~= nil then
        local resolved, reason = resolveSourceInput("battler-particle-resource", { battler, memberId })
        if resolved == nil then
          error(
            decodeError(key, start, "particle source is unresolved: " .. (reason or "unknown source route"), offset + 8),
            0
          )
        end
        assert(resolved ~= nil, "particle resolver returns a selection")
        resource = checkSourceInputResult(key, offset, resolved, { "particle" }).particle
      else
        resource = sources().resolveParticleResource(memberId)
      end
      if resource == nil then
        error(decodeError(key, start, "unresolved particle resource selector", offset + 8), 0)
      end
      local emitterPosition = sources().resolveBattlerPosition(battler)
      if emitterPosition == nil then
        error(decodeError(key, start, "particle creation has an invalid battler effect slot", offset + 4), 0)
      end
      instruction = {
        op = "create-battler-effect",
        emitterPosition = emitterPosition,
        resource = resource,
        taskKind = "battler-effect-continuation",
      }
      offset = offset + 8
    elseif opcode == 52 then
      instruction = {
        op = "create-parameterized-battler-effect",
        taskKind = "battler-effect-continuation",
        values = { readWord(stream, key, offset), readWord(stream, key, offset + 8) },
      }
      offset = offset + 12
    elseif opcode == 82 then
      instruction = {
        op = "start-sprite-effect",
        taskKind = "managed-sprite-draw-loop",
        taskStartRule = "battle-helper-equals-one",
        mode = sources().resolveSpriteEffectMode(readWord(stream, key, offset)),
        values = {
          readWord(stream, key, offset + 4),
          readWord(stream, key, offset + 8),
        },
      }
      offset = offset + 12
    elseif opcode == 86 then
      local firstValue = readWord(stream, key, offset)
      local packedTask = readWord(stream, key, offset + 4)
      local packedUpdate = readWord(stream, key, offset + 8)
      local taskKind = sources().resolveVisualTaskKind(packedTask % 65536)
      if taskKind == nil then
        error(decodeError(key, start, "invalid visual update task selector", offset + 12), 0)
      end
      local updateKind = sources().resolveVisualUpdateKind(math.floor(packedUpdate / 65536))
      if updateKind == nil then
        error(decodeError(key, start, "invalid visual axis adjustment", offset + 12), 0)
      end
      instruction = {
        op = "update-battle-visual",
        taskKind = taskKind,
        updateKind = updateKind,
        values = { firstValue, math.floor(packedTask / 65536), signed16(packedUpdate % 65536) },
      }
      offset = offset + 12
    elseif opcode == 53 then
      instruction = { op = "destroy-battler-effect", values = { readWord(stream, key, offset) } }
      offset = offset + 4
    elseif opcode == 84 then
      instruction = { op = "wait-for-confirm-input", values = { 1 }, cursorRule = "advance-when-confirm-input-matches" }
    elseif opcode == 30 then
      local parameter = readWord(stream, key, offset)
      local expected = readWord(stream, key, offset + 4)
      local targetOffset = readWord(stream, key, offset + 8)
      if parameter >= 10 then
        error(decodeError(key, start, "parameter index is outside the ten-slot context"), 0)
      end
      instruction = { op = "branch-on-parameter", values = { parameter, expected } }
      targetOffsets[#targetOffsets + 1] =
        { instruction = #instructions + 1, offset = targetOffset, field = "branchTarget" }
      offset = offset + 12
    elseif opcode == 31 then
      local battlerSelector = readWord(stream, key, offset)
      local mode = readWord(stream, key, offset + 4)
      instruction = { op = "show-pokemon-picture", values = { battlerSelector, mode } }
      if mode == 1 then
        instruction.taskKind = "pokemon-picture-animation"
      end
      offset = offset + 8
    elseif opcode == 33 then
      local targetOffset = readWord(stream, key, offset)
      instruction = { op = "branch-on-interpreter-state" }
      targetOffsets[#targetOffsets + 1] =
        { instruction = #instructions + 1, offset = targetOffset, field = "branchTarget" }
      offset = offset + 4
    elseif opcode == 14 then
      local expected = readWord(stream, key, offset)
      local countOffset = offset + 4
      local count = readWord(stream, key, countOffset)
      instruction = { op = "branch-on-battle-field", values = { expected } }
      targetOffsets[#targetOffsets + 1] = {
        instruction = #instructions + 1,
        offset = countOffset + count * 4,
        field = "branchTarget",
      }
      offset = offset + 8
    elseif opcode == 13 then
      local clearCountOffset = offset
      local setCountOffset = offset + 4
      local clearTarget = clearCountOffset + readWord(stream, key, clearCountOffset) * 4
      local setTarget = setCountOffset + readWord(stream, key, setCountOffset) * 4
      instruction = { op = "branch-on-battle-flag", values = { 1 } }
      targetOffsets[#targetOffsets + 1] = {
        instruction = #instructions + 1,
        offset = setTarget,
        field = "branchTarget",
      }
      targetOffsets[#targetOffsets + 1] = {
        instruction = #instructions + 1,
        offset = clearTarget,
        field = "alternateTarget",
      }
      offset = math.min(clearTarget, setTarget)
    elseif opcode == 16 or opcode == 18 then
      local action = readWord(stream, key, offset)
      local packed = readWord(stream, key, offset + 4)
      local sourceSelector = packed % 65536
      local taskSelector = sourceSelector + (opcode == 18 and 3 or 0)
      local taskKind = sources().resolveVisualTaskKind(taskSelector)
      if taskKind == nil then
        error(decodeError(key, start, "invalid visual task selector", offset + 8), 0)
      end
      instruction = {
        op = "start-visual-task",
        taskKind = taskKind,
        values = { action, math.floor(packed / 65536) },
      }
      offset = offset + 8
    elseif opcode == 2 then
      local count = readWord(stream, key, offset) % 256
      local bodyOffset = offset + 4
      instruction = {
        op = "reserve-loop-slot",
        values = { count },
        cursorRule = "advance-to-body-when-loop-slot-free; otherwise-redispatch-count-word",
      }
      targetOffsets[#targetOffsets + 1] = {
        instruction = #instructions + 1,
        offset = bodyOffset,
        field = "branchTarget",
      }
      targetOffsets[#targetOffsets + 1] = {
        instruction = #instructions + 1,
        offset = bodyOffset,
        field = "resumeTarget",
      }
      offset = bodyOffset
    elseif opcode == 10 then
      local countOffset = offset
      local count = readWord(stream, key, countOffset)
      local callTarget = countOffset + count * 4
      instruction = {
        op = "call-subprogram",
        cursorRule = "call-first-free-subprogram-slot; all-slots-busy-redispatch-count-word",
      }
      targetOffsets[#targetOffsets + 1] = {
        instruction = #instructions + 1,
        offset = callTarget,
        field = "branchTarget",
      }
      targetOffsets[#targetOffsets + 1] = {
        instruction = #instructions + 1,
        offset = offset + 4,
        field = "returnTarget",
      }
      offset = callTarget
    elseif opcode == 11 then
      instruction = {
        op = "return-subprogram",
        cursorRule = "return-to-active-subprogram-slot",
      }
      offset = offset + 4
    elseif opcode == 3 then
      instruction = {
        op = "advance-loop-slot",
        cursorRule = "rewind-to-active-loop-body-until-count",
      }
    elseif opcode == 34 then
      instruction = {
        op = "schedule-battle-task",
        taskKind = sources().resolveVisualTaskKind(0),
        taskInputRule = "helper-equals-one-then-side-class-equals-three-else-first",
        values = {
          readWord(stream, key, offset),
          readWord(stream, key, offset + 4),
          readWord(stream, key, offset + 8),
        },
      }
      offset = offset + 12
    elseif opcode == 70 then
      local branchCases = { { sideMask = 0 } }
      local maskCaseCount = #sources().SIDE_MASK_BRANCHES
      for caseIndex = 1, maskCaseCount do
        branchCases[#branchCases + 1] = { sideMask = sources().SIDE_MASK_BRANCHES[caseIndex] }
      end
      branchCases[#branchCases + 1] = { otherwise = true }
      local targetCountOffsets = { offset }
      for caseIndex = 0, maskCaseCount do
        targetCountOffsets[#targetCountOffsets + 1] = offset + 4 + caseIndex * 4
      end
      local nextOffset = #stream
      for caseIndex, countOffset in ipairs(targetCountOffsets) do
        local targetOffset = countOffset + readWord(stream, key, countOffset) * 4
        nextOffset = math.min(nextOffset, targetOffset)
        targetOffsets[#targetOffsets + 1] = {
          instruction = #instructions + 1,
          offset = targetOffset,
          caseIndex = caseIndex,
        }
      end
      instruction = { op = "branch-on-side-mask", branchCases = branchCases }
      offset = nextOffset
    elseif opcode == 71 then
      local countOffset = offset
      local count = readWord(stream, key, countOffset)
      local matchTarget = countOffset + count * 4
      local otherTarget = countOffset + 4
      instruction = { op = "branch-on-interpreter-state", values = { 1 } }
      targetOffsets[#targetOffsets + 1] = {
        instruction = #instructions + 1,
        offset = matchTarget,
        field = "branchTarget",
      }
      targetOffsets[#targetOffsets + 1] = {
        instruction = #instructions + 1,
        offset = otherTarget,
        field = "alternateTarget",
      }
      offset = math.min(matchTarget, otherTarget)
    elseif opcode == 64 then
      local selector = readWord(stream, key, offset)
      local ordinaryCountOffset = offset + 4
      local specialCountOffset = offset + 8
      local ordinaryTarget = ordinaryCountOffset + readWord(stream, key, ordinaryCountOffset) * 4
      local specialTarget = specialCountOffset + readWord(stream, key, specialCountOffset) * 4
      instruction = { op = "branch-on-side-predicate", values = { selector } }
      targetOffsets[#targetOffsets + 1] = {
        instruction = #instructions + 1,
        offset = specialTarget,
        field = "branchTarget",
      }
      targetOffsets[#targetOffsets + 1] = {
        instruction = #instructions + 1,
        offset = ordinaryTarget,
        field = "alternateTarget",
      }
      offset = math.min(ordinaryTarget, specialTarget)
    elseif opcode == 66 then
      local stopSelector = readWord(stream, key, offset)
      instruction = {
        op = "wait-for-cry",
        values = { stopSelector },
        cursorRule = "leave-on-finished-cry; otherwise-consume-stop-word",
      }
      targetOffsets[#targetOffsets + 1] = {
        instruction = #instructions + 1,
        offset = start,
        field = "branchTarget",
      }
      targetOffsets[#targetOffsets + 1] = {
        instruction = #instructions + 1,
        offset = offset + 4,
        field = "alternateTarget",
      }
      offset = offset + 4
    elseif opcode == 72 then
      local countOffset = offset
      local count = readWord(stream, key, countOffset)
      local equalTarget = countOffset + count * 4
      local unequalTarget = countOffset + 4
      instruction = { op = "branch-on-side-equality", values = {} }
      targetOffsets[#targetOffsets + 1] = {
        instruction = #instructions + 1,
        offset = equalTarget,
        field = "branchTarget",
      }
      targetOffsets[#targetOffsets + 1] = {
        instruction = #instructions + 1,
        offset = unequalTarget,
        field = "alternateTarget",
      }
      offset = math.min(equalTarget, unequalTarget)
    elseif opcode == 87 then
      local countOffset = offset + 4
      local count = readWord(stream, key, countOffset)
      local setTarget = countOffset + count * 4
      local clearTarget = countOffset + 4
      instruction = { op = "branch-on-battle-flag", values = { 2 } }
      targetOffsets[#targetOffsets + 1] = {
        instruction = #instructions + 1,
        offset = setTarget,
        field = "branchTarget",
      }
      targetOffsets[#targetOffsets + 1] = {
        instruction = #instructions + 1,
        offset = clearTarget,
        field = "alternateTarget",
      }
      offset = math.min(setTarget, clearTarget)
    elseif opcode == 44 then
      local soundId = readWord(stream, key, offset) % 65536
      local soundKey = resolveSound(key, soundId, sounds, start)
      instruction = { op = "stop-sound", sound = soundKey }
      offset = offset + 4
    elseif opcode == 45 then
      local selector = readWord(stream, key, offset)
      local count = readWord(stream, key, offset + 4)
      if count > 10 then
        error(decodeError(key, start, "parameter count exceeds the ten-slot context"), 0)
      end
      local sourceOperands = { selector, count }
      for index = 1, count do
        sourceOperands[index + 2] = readWord(stream, key, offset + 8 + (index - 1) * 4)
      end
      if resolveSourceInput ~= nil then
        local resolved, reason = resolveSourceInput("battle-animation-callback", sourceOperands)
        if resolved == nil then
          error(
            decodeError(
              key,
              start,
              "handler " .. label .. " requires an unresolved source callback: " .. (reason or "unknown source route"),
              offset
            ),
            0
          )
        end
        assert(resolved ~= nil, "callback resolver returns a selection")
        if resolved.op ~= nil then
          local resourceKeys = checkSourceInputResult(key, offset, resolved, {})
          local isVanishedOperation = resolved.op == "set-pokemon-picture-vanished"
            and type(resolved.pictureSets) == "table"
            and type(resolved.vanished) == "boolean"
          local isPaletteOperation = resolved.op == "copy-main-background-palette-to-fade-buffer"
            or resolved.op == "grayscale-main-background-fade-buffer"
          local isNoop = resolved.op == "noop"
          if not isVanishedOperation and not isPaletteOperation and not isNoop then
            error(decodeError(key, start, "source resolver returned an invalid direct callback operation", offset), 0)
          end
          if next(resourceKeys) ~= nil then
            error(decodeError(key, offset, "direct callback operation cannot return resource keys"), 0)
          end
          instruction = isNoop and { op = "noop" }
            or isVanishedOperation and {
              op = resolved.op,
              pictureSets = resolved.pictureSets,
              vanished = resolved.vanished,
            }
            or { op = resolved.op }
          offset = offset + 8 + count * 4
        else
          if
            type(resolved.callback) ~= "string"
            or resolved.callback == ""
            or type(resolved.taskKind) ~= "string"
            or type(resolved.context) ~= "string"
            or type(resolved.parameters) ~= "table"
          then
            error(decodeError(key, offset, "source resolver returned an invalid semantic callback"), 0)
          end
          local expectedSlots = {}
          if
            resolved.taskKind == "battle-background-alpha-scroll-transition"
            or resolved.taskKind == "battle-background-sprite-slide-transition"
          then
            expectedSlots = { "character", "palette", "screenDefault", "screenBattlerClassFour", "screenContextFlag" }
          end
          local checkedResourceKeys = checkSourceInputResult(key, offset, resolved, expectedSlots)
          if
            next(checkedResourceKeys) ~= nil
            and resolved.runtimeSelection ~= "battle-background-three-way-screen-selection"
          then
            error(decodeError(key, offset, "source callback resources have no runtime selection"), 0)
          end
          instruction = {
            op = "invoke-battle-animation-callback",
            callback = resolved.callback,
            taskKind = resolved.taskKind,
            taskContext = resolved.context,
            battlerTarget = resolved.battlerTarget,
            parameters = resolved.parameters,
            resourceKeys = next(checkedResourceKeys) ~= nil and checkedResourceKeys or nil,
            runtimeSelection = resolved.runtimeSelection,
          }
          offset = offset + 8 + count * 4
        end
      else
        local callback = resolveCallback(key, selector, callbacks, start)
        local values = {}
        for index = 3, #sourceOperands do
          values[index - 2] = sourceOperands[index]
        end
        instruction = { op = "replace-parameters-and-call", callback = callback, values = values }
      end
      if resolveSourceInput == nil then
        offset = offset + 8 + count * 4
      end
    elseif opcode == 60 then
      instruction = { op = "delete-managed-sprite", values = { readWord(stream, key, offset) } }
      offset = offset + 4
    elseif opcode == 61 then
      instruction = { op = "destroy-effect-slot", values = { readWord(stream, key, offset) } }
      offset = offset + 4
    elseif opcode == 62 or opcode == 63 then
      instruction = {
        op = opcode == 62 and "set-battler-state-byte" or "set-battler-effect-byte",
        values = { readWord(stream, key, offset), readWord(stream, key, offset + 4) % 256 },
      }
      offset = offset + 8
    elseif opcode == 65 then
      instruction = {
        op = "play-cry",
        values = {
          readWord(stream, key, offset),
          signed8(readWord(stream, key, offset + 4)),
          readWord(stream, key, offset + 8),
        },
      }
      offset = offset + 12
    elseif opcode == 67 then
      readWord(stream, key, offset)
      instruction = { op = "clear-parameters" }
      offset = offset + 4
    elseif opcode == 68 or opcode == 69 then
      local selector = readWord(stream, key, offset)
      if opcode == 68 and selector > 3 then
        error(decodeError(key, start, "presentation layout selector exceeds the source table"), 0)
      end
      instruction = {
        op = opcode == 68 and "submit-presentation-layout" or "submit-presentation-update",
        values = { selector },
      }
      offset = offset + 4
    elseif opcode == 21 then
      local selector = readWord(stream, key, offset)
      local resolved = resolveSourceInput and resolveSourceInput("battle-background", { selector })
      if resolved == nil then
        error(
          decodeError(key, start, "handler " .. label .. " requires unresolved battle background resource", offset + 4),
          0
        )
      end
      assert(resolved ~= nil, "background resolver returns a selection")
      if resolved.runtimeSelection ~= "battle-background-screen-selection" then
        error(decodeError(key, start, "source resolver returned an unknown battle background selection", offset + 4), 0)
      end
      instruction = {
        op = "load-battle-background",
        resourceKeys = checkSourceInputResult(key, offset + 4, resolved, {
          "character",
          "palette",
          "screenDefault",
          "screenAlternate",
        }),
        runtimeSelection = resolved.runtimeSelection,
      }
      offset = offset + 4
    elseif opcode == 57 then
      local selector = readWord(stream, key, offset)
      local resolved = resolveSourceInput and resolveSourceInput("managed-sprite-resource-set", { selector })
      if resolved == nil then
        error(
          decodeError(key, start, "handler " .. label .. " requires unresolved managed sprite resources", offset + 4),
          0
        )
      end
      assert(resolved ~= nil, "managed sprite resolver returns a selection")
      if resolved.runtimeSelection ~= "battler-resource-selection" then
        error(decodeError(key, start, "source resolver returned an unknown battler resource selection", offset + 4), 0)
      end
      instruction = {
        op = "load-managed-sprite-resources",
        resourceKeys = checkSourceInputResult(key, offset + 4, resolved, {
          "character",
          "palette",
          "cell",
          "animation",
        }),
        runtimeSelection = resolved.runtimeSelection,
      }
      offset = offset + 4
    elseif opcode == 58 then
      local operands = {
        readWord(stream, key, offset),
        readWord(stream, key, offset + 4),
        readWord(stream, key, offset + 8),
        readWord(stream, key, offset + 12),
      }
      local resolved = resolveSourceInput and resolveSourceInput("battler-sprite-resource-set", operands)
      if resolved == nil then
        error(
          decodeError(
            key,
            start,
            "handler " .. label .. " requires unresolved battler Pokémon picture selection",
            offset + 16
          ),
          0
        )
      end
      assert(resolved ~= nil, "battler sprite resolver returns a selection")
      if resolved.runtimeSelection ~= "battler-pokemon-picture-resource" then
        error(
          decodeError(key, start, "source resolver returned an unknown battler Pokémon picture selection", offset + 16),
          0
        )
      end
      checkSourceInputResult(key, offset + 16, resolved, {})
      if type(resolved.battlerTarget) ~= "string" or resolved.battlerTarget == "" then
        error(decodeError(key, start, "source resolver returned no semantic battler target", offset + 16), 0)
      end
      assert(type(resolved.battlerTarget) == "string" and resolved.battlerTarget ~= "")
      instruction = {
        op = "create-pokemon-sprite",
        values = { operands[2] },
        battlerTarget = resolved.battlerTarget,
        runtimeSelection = resolved.runtimeSelection,
      }
      if operands[3] == 1 then
        instruction.taskKind = "pokemon-picture-animation"
        instruction.taskStartRule = "picture-active-and-animation-attribute"
      end
      offset = offset + 16
    elseif opcode == 79 then
      local operands = {}
      for index = 0, 7 do
        operands[index + 1] = readWord(stream, key, offset + index * 4)
      end
      local resolved = resolveSourceInput and resolveSourceInput("managed-sprite-template", operands)
      if resolved == nil then
        error(
          decodeError(
            key,
            start,
            "handler " .. label .. " requires unresolved managed sprite template resources",
            offset + 32
          ),
          0
        )
      end
      assert(resolved ~= nil, "managed sprite template resolver returns a selection")
      local resourceKeys = checkSourceInputResult(key, offset + 32, resolved, {
        "character",
        "palette",
        "cell",
        "animation",
      }, { multiCell = true, multiAnimation = true })
      for _, optional in ipairs({ { slot = "multiCell", operand = 7 }, { slot = "multiAnimation", operand = 8 } }) do
        local absent = operands[optional.operand] == 0xffffffff
        if absent and resourceKeys[optional.slot] ~= nil then
          error(
            decodeError(key, start, "managed sprite optional resource does not match its source sentinel", offset + 32),
            0
          )
        end
      end
      instruction = {
        op = "create-managed-sprite",
        values = { operands[1], operands[2] },
        resourceKeys = resourceKeys,
      }
      offset = offset + 32
    elseif opcode == 78 then
      local operands = {}
      for index = 1, 9 do
        operands[index] = readWord(stream, key, offset + (index - 1) * 4)
      end
      local parameterCount = operands[9]
      if parameterCount > 10 then
        error(decodeError(key, start, "configured sprite parameter count exceeds the ten-slot context", offset + 32), 0)
      end
      local parameters = {}
      for index = 1, parameterCount do
        parameters[index] = readWord(stream, key, offset + 36 + (index - 1) * 4)
      end
      local sourceOperands = {}
      for _, operand in ipairs(operands) do
        sourceOperands[#sourceOperands + 1] = operand
      end
      for _, parameter in ipairs(parameters) do
        sourceOperands[#sourceOperands + 1] = parameter
      end
      local resolved, reason
      if resolveSourceInput ~= nil then
        resolved, reason = resolveSourceInput("configured-sprite-action", sourceOperands)
      end
      local instructionOffset = offset + 36 + parameterCount * 4
      if resolved == nil then
        local selectorOffset = reason and reason:find("callback selector", 1, true) and (offset + 4)
          or instructionOffset
        error(
          decodeError(
            key,
            start,
            "handler "
              .. label
              .. " requires unresolved configured sprite action: "
              .. (reason or "source selection is unavailable"),
            selectorOffset
          ),
          0
        )
      end
      assert(resolved ~= nil, "configured sprite resolver returns a selection")
      assert(resolved ~= nil, "resource resolver returns a selection")
      local resourceKeys = checkSourceInputResult(key, instructionOffset, resolved, {
        "character",
        "palette",
        "cell",
        "animation",
      }, { multiCell = true, multiAnimation = true })
      if type(resolved.taskKind) ~= "string" or resolved.taskKind == "" then
        error(decodeError(key, instructionOffset, "source resolver returned no configured sprite task kind"), 0)
      end
      if type(resolved.context) ~= "string" or resolved.context == "" then
        error(decodeError(key, instructionOffset, "source resolver returned no configured sprite context"), 0)
      end
      if type(resolved.parameters) ~= "table" then
        error(decodeError(key, instructionOffset, "source resolver returned no typed configured sprite parameters"), 0)
      end
      instruction = {
        op = "create-configured-sprite",
        parameters = resolved.parameters,
        taskKind = resolved.taskKind,
        taskContext = resolved.context,
        resourceKeys = resourceKeys,
      }
      offset = instructionOffset
    elseif opcode >= 74 and opcode <= 77 then
      local managerSlot = readWord(stream, key, offset)
      local memberSelector = readWord(stream, key, offset + 4)
      local resourceOps = {
        [74] = { role = "sprite-character", op = "load-sprite-character", slot = "character" },
        [75] = { role = "sprite-palette", op = "load-sprite-palette", slot = "palette" },
        [76] = { role = "sprite-cell", op = "load-sprite-cell", slot = "cell" },
        [77] = { role = "sprite-animation", op = "load-sprite-animation", slot = "animation" },
      }
      local resourceOp = resourceOps[opcode]
      local operands = { managerSlot, memberSelector }
      if opcode == 75 then
        operands[3] = readWord(stream, key, offset + 8)
      end
      local resolved = resolveSourceInput and resolveSourceInput(resourceOp.role, operands)
      if resolved == nil then
        error(
          decodeError(
            key,
            start,
            "handler " .. label .. " requires unresolved " .. resourceOp.role,
            offset + #operands * 4
          ),
          0
        )
      end
      assert(resolved ~= nil, "sprite resource resolver returns a selection")
      instruction = {
        op = resourceOp.op,
        resourceKeys = checkSourceInputResult(key, offset + #operands * 4, resolved, { resourceOp.slot }),
        values = opcode == 75 and { managerSlot, operands[3] } or { managerSlot },
      }
      offset = offset + #operands * 4
    elseif opcode == 73 then
      local values = {}
      for index = 1, 8 do
        values[index] = readWord(stream, key, offset + (index - 1) * 4)
      end
      if resolveSourceInput ~= nil then
        resolveSourceInput("managed-sprite-manager-capacities", values)
      end
      instruction = { op = "create-sprite-manager", values = values }
      offset = offset + 32
    elseif opcode == 80 then
      local managerIndex = readWord(stream, key, offset)
      if resolveSourceInput ~= nil then
        resolveSourceInput("managed-sprite-manager-disposal", { managerIndex })
      end
      instruction = { op = "dispose-sprite-manager", values = { managerIndex } }
      offset = offset + 4
    elseif opcode == 81 then
      instruction = {
        op = "set-managed-sprite-draw-flag",
        values = { readWord(stream, key, offset), readWord(stream, key, offset + 4) },
      }
      offset = offset + 8
    elseif opcode == 83 then
      instruction = { op = "clear-effect-slot", values = { readWord(stream, key, offset) } }
      offset = offset + 4
    elseif opcode == 85 then
      instruction = { op = "start-brightness-transition", values = { readWord(stream, key, offset) % 256 } }
      offset = offset + 4
    elseif opcode == 55 then
      instruction = {
        op = "source-assertion",
        target = #instructions + 1,
        cursorRule = "invoke-assert-service; redispatch-current-word-if-it-returns",
      }
      offset = #stream
    else
      local nextOffset = readUnresolvedFrame(opcode, stream, key, start, offset)
      local unresolvedInput = UNRESOLVED_SOURCE_INPUTS[opcode]
      if unresolvedInput == nil then
        error(decodeError(key, start, "handler " .. label .. " has no semantic lowering", nextOffset), 0)
      end
      error(decodeError(key, start, "handler " .. label .. " requires unresolved " .. unresolvedInput, nextOffset), 0)
    end
    if opcode == 13 or opcode == 64 or opcode == 66 or opcode == 71 or opcode == 72 or opcode == 87 then
      for _, branch in ipairs(targetOffsets) do
        if branch.instruction == #instructions + 1 and branch.offset > #stream then
          error(decodeError(key, start, "count-derived branch target leaves the program", branch.offset), 0)
        end
      end
    end
    local branchTargets = {}
    for _, branch in ipairs(targetOffsets) do
      if branch.instruction == #instructions + 1 then
        branchTargets[#branchTargets + 1] = branch.offset
      end
    end
    if #branchTargets > 0 then
      local currentOffset = offset
      for _, branchOffset in ipairs(branchTargets) do
        if branchOffset < #stream and not parsedOffsets[branchOffset] and branchOffset ~= currentOffset then
          pendingOffsets[#pendingOffsets + 1] = branchOffset
        end
      end
      table.sort(pendingOffsets)
      if #pendingOffsets > 0 and pendingOffsets[1] < currentOffset then
        if currentOffset < #stream and not parsedOffsets[currentOffset] then
          pendingOffsets[#pendingOffsets + 1] = currentOffset
          table.sort(pendingOffsets)
        end
        offset = table.remove(pendingOffsets, 1)
      end
    end
    instructions[#instructions + 1] = instruction
  end
  local instructionAtOffset = {}
  for index, instructionOffset in ipairs(instructionOffsets) do
    instructionAtOffset[instructionOffset] = index
  end
  for _, branch in ipairs(targetOffsets) do
    local target = instructionAtOffset[branch.offset]
    if branch.offset == #stream then
      target = #instructions + 1
    end
    if target == nil then
      error(decodeError(key, branch.offset, "skip target is not an instruction boundary"), 0)
    end
    if branch.caseIndex ~= nil then
      instructions[branch.instruction].branchCases[branch.caseIndex].target = target
    else
      instructions[branch.instruction][branch.field or "target"] = target
    end
  end
  return instructions, instructionOffsets
end

---@param key unknown
---@return string program identity
local function checkKey(key)
  if type(key) ~= "string" or key == "" then
    error(Errors.new("BATTLE_ANIMATION_PROGRAM_INVALID", "animation program carries no key", {}), 0)
  end
  return key
end

-- Decode one whole native member. Commands with a runtime-dependent cursor or
-- unresolved resource selector are rejected rather than approximated.
---@param program BattleAnimationProbe synthetic or bounded-ROM program probe
---@return BattleAnimationProgram normalized program without native identities
local function compileProgram(program)
  if type(program) ~= "table" then
    error(Errors.new("BATTLE_ANIMATION_PROGRAM_INVALID", "animation program is not a table", {}), 0)
  end
  local key = checkKey(program.key)
  if type(program.stream) ~= "string" then
    error(decodeError(key, 0, "native command stream is required"), 0)
  end
  local instructions, sourceOffsets =
    decodeNativeStream(key, program.stream, program.callbacks, program.sounds, program.resolveSourceInput)
  local taskKinds = {}
  local seenTaskKinds = {}
  for _, instruction in ipairs(instructions) do
    local taskKind = instruction.taskKind
    if taskKind ~= nil and not seenTaskKinds[taskKind] then
      seenTaskKinds[taskKind] = true
      taskKinds[#taskKinds + 1] = taskKind
    end
  end
  return {
    key = key,
    entry = "main",
    instructions = instructions,
    subprograms = {},
    taskKinds = taskKinds,
    sourceOffsets = sourceOffsets,
  }
end

-- Traverse one dependency graph to its fixpoint, reporting the closed key
-- set. Control-flow loops are preserved: visited keys are skipped, never
-- rejected as resource cycles.
---@param roots string[]
---@param edges table<string, string[]> adjacency by key
---@return string[] closed keys in deterministic order
function BattleAnimationCompiler.traverseClosure(roots, edges)
  assert(type(roots) == "table", "closure traversal requires its roots")
  assert(type(edges) == "table", "closure traversal requires its edges")
  local seen = {}
  local order = {}
  local stack = {}
  for _, root in ipairs(roots) do
    stack[#stack + 1] = root
  end
  while #stack > 0 do
    local key = table.remove(stack)
    if not seen[key] then
      seen[key] = true
      order[#order + 1] = key
      local children = edges[key]
      if type(children) == "table" then
        for _, child in ipairs(children) do
          if not seen[child] then
            stack[#stack + 1] = child
          end
        end
      end
    end
  end
  table.sort(order)
  return order
end

BattleAnimationCompiler.compile = compileProgram
BattleAnimationCompiler.compileProgram = compileProgram
BattleAnimationCompiler.lower = compileProgram
BattleAnimationCompiler.decode = compileProgram

return BattleAnimationCompiler
