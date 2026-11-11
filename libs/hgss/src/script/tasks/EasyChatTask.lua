-- Source word-editor async protocol: one blocking script task behind the
-- pair editor, the single-word default, the Battle Tower slots, and the
-- separate terminal greeting. Creation validates its output references,
-- evaluates the launch kind, rejects the single-output wrapper kind, and
-- initializes the word outputs before leaving the field; the first poll
-- opens the single script-owned child, later polls step it through the
-- scheduler UI events, and the terminal poll consumes the detached result
-- once, publishes the source-ordered outputs with no scalar scheduler
-- result, and completes. The greeting owns its own restore and
-- both-screen field fade before it commits. Cancellation releases the
-- child, clears only its own fade lease, restores the field it left, and
-- publishes nothing. Library task only: it borrows the injected service,
-- host, lifecycle, and fade owners and names no renderer.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")

local EasyChatTask = {}

EasyChatTask.type = "easy_chat"
EasyChatTask.version = 1

EasyChatTask.NULL_WORD = 0xFFFF
EasyChatTask.GREETING_FADE_DURATION = 6
EasyChatTask.GREETING_FADE_SPEED = 1

local PHASES = {
  pending = true,
  open = true,
  restore = true,
  fade = true,
  done = true,
}

---@param node table<string, unknown>
---@return string op
local function checkOp(node)
  if type(node) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "word editor task requires its graph node", {})
  end
  local record = node --[[@as table<string, unknown>]]
  if record.op == "easy_chat_edit" then
    return "edit"
  end
  if record.op == "easy_chat_greeting" then
    return "greeting"
  end
  Errors.raise(
    ScriptErrors.SCRIPT_INVALID_REFERENCE,
    "word editor task requires an editor or greeting node",
    { op = record.op }
  )
  error("unreachable", 0)
end

---@param node table<string, unknown>
local function checkEditRefs(node)
  if type(node.result) ~= "table" or type(node.word1) ~= "table" then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "word editor task requires its result and word outputs",
      { op = node.op }
    )
  end
  if node.word2 ~= nil and type(node.word2) ~= "table" then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "word editor second word output is not a reference",
      { op = node.op }
    )
  end
end

---@param ctx table<string, unknown>
---@return table<string, unknown> word service
local function serviceFor(ctx)
  local services = ctx.services
  local service = services ~= nil and services.easyChatService or nil
  if service == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "word editor task requires its domain service", {})
  end
  return service --[[@as table<string, unknown>]]
end

---@param ctx table<string, unknown>
---@return table<string, unknown> editor host
local function hostFor(ctx)
  local services = ctx.services
  local host = services ~= nil and services.easyChatScriptHost or nil
  if host == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "word editor task requires its editor host", {})
  end
  return host --[[@as table<string, unknown>]]
end

---@param ctx table<string, unknown>
---@return table<string, unknown> field lifecycle owner
local function lifecycleFor(ctx)
  local services = ctx.services
  local lifecycle = services ~= nil and services.overworld or nil
  if lifecycle == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "word editor task requires the field lifecycle", {})
  end
  return lifecycle --[[@as table<string, unknown>]]
end

---@param ctx table<string, unknown>
---@return table<string, unknown> screen fade owner
local function screenFor(ctx)
  local services = ctx.services
  local screen = services ~= nil and services.screen or nil
  if screen == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "word editor task requires the screen fade", {})
  end
  return screen --[[@as table<string, unknown>]]
end

---@param spec table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown> state
function EasyChatTask.create(spec, ctx)
  assert(type(spec) == "table", "word editor task requires a request")
  local node = assert(spec.node, "word editor task requires its graph node")
  assert(type(ctx) == "table", "word editor task requires its context")
  local op = checkOp(node)
  if op == "greeting" then
    if type(node.result) ~= "table" then
      Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "greeting task requires its result output", { op = node.op })
    end
  else
    checkEditRefs(node)
  end
  local run = { services = ctx.services, instance = ctx.instance, node = node }
  local kind = nil
  if op == "edit" then
    kind = RuntimeValues.evaluateValue(node.kind, run)
    if kind == 1 and node.word2 == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_INVALID_REFERENCE,
        "single-output wrapper kind has no second word",
        { kind = kind }
      )
    end
    RuntimeValues.writeRef(node.word1, EasyChatTask.NULL_WORD, run)
    if node.word2 ~= nil then
      RuntimeValues.writeRef(node.word2, EasyChatTask.NULL_WORD, run)
    end
  end
  lifecycleFor(ctx):leave()
  local service = serviceFor(ctx)
  local request = nil
  if op == "greeting" then
    request = service:requestForGreeting("buttons")
  else
    request = service:requestForKind(kind, "buttons")
  end
  return {
    op = op,
    kind = kind,
    node = node,
    request = request,
    phase = "pending",
    opened = false,
    leftWorld = true,
    restored = false,
    fadeLease = nil,
    completed = false,
  }
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>? live child handle
local function openChild(state, ctx)
  local host = hostFor(ctx)
  local request = assert(state.request, "word editor task maps its request before opening")
  local ok, openErr = pcall(host.open, host, request)
  if not ok then
    if state.leftWorld == true and state.restored ~= true then
      lifecycleFor(ctx):restore()
      state.restored = true
    end
    error(openErr, 0)
  end
  state.opened = true
  state.phase = "open"
  return host:activeHandle()
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown> live child handle
local function liveHandle(state, ctx)
  local host = hostFor(ctx)
  local handle = host:activeHandle()
  if handle == nil then
    Errors.raise(
      ScriptErrors.FEATURE_UNAVAILABLE,
      "word editor handle is missing after acquisition; the editor is never recreated",
      { op = state.op }
    )
  end
  return handle --[[@as table<string, unknown>]]
end

-- Reads the editor words back in source order: the pair publishes both
-- words, a tower phrase publishes its first field, and the single-word
-- default publishes its word. A zero-field sentence legitimately keeps
-- the initialized null identity.
---@param state table<string, unknown>
---@param result table<string, unknown> terminal editor result
---@return integer first word
---@return integer? second word
local function returnedWords(state, result)
  if state.op == "greeting" then
    return EasyChatTask.NULL_WORD, nil
  end
  if state.kind == 1 then
    return result.words[1], result.words[2]
  end
  if type(state.kind) == "number" and state.kind >= 2 and state.kind <= 5 then
    return result.message.words[1], nil
  end
  return result.words[1], nil
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@param result table<string, unknown> terminal editor result
local function publishEdit(state, ctx, result)
  local node = state.node
  local run = { services = ctx.services, instance = ctx.instance, node = node }
  if result.cancelled == true or result.changed ~= true then
    RuntimeValues.writeRef(node.result, 0, run)
    return
  end
  RuntimeValues.writeRef(node.result, 1, run)
  serviceFor(ctx):commitWrapper(state.kind, result)
  local word1, word2 = returnedWords(state, result)
  RuntimeValues.writeRef(node.word1, word1, run)
  if node.word2 ~= nil then
    RuntimeValues.writeRef(node.word2, word2, run)
  end
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@param result table<string, unknown> terminal editor result
local function publishGreeting(state, ctx, result)
  local node = state.node
  local run = { services = ctx.services, instance = ctx.instance, node = node }
  if result.cancelled == true then
    RuntimeValues.writeRef(node.result, 0, run)
    return
  end
  RuntimeValues.writeRef(node.result, 1, run)
  serviceFor(ctx):commitGreeting(result)
end

-- The host stays open until the task publishes: the save owner, the
-- session capture, and the presentation draw all key on the live child,
-- so the restore and fade ticks stay gated without a second signal.
---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@param result table<string, unknown> terminal editor result
---@return table<string, unknown> completion
local function finishEdit(state, ctx, result)
  publishEdit(state, ctx, result)
  hostFor(ctx):close(liveHandle(state, ctx))
  state.phase = "done"
  state.completed = true
  return { complete = true, state = state }
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
local function beginRestore(state, ctx)
  lifecycleFor(ctx):restore()
  state.restored = true
  state.phase = "restore"
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
local function beginFade(state, ctx)
  local screen = screenFor(ctx)
  state.fadeLease = screen:startFade({
    direction = "in",
    color = "black",
    duration = EasyChatTask.GREETING_FADE_DURATION,
    speed = EasyChatTask.GREETING_FADE_SPEED,
    screenScope = "both",
  })
  state.phase = "fade"
end

---@param state table<string, unknown>
---@return boolean
local function validShape(state)
  if type(state) ~= "table" then
    return false
  end
  if state.op ~= "edit" and state.op ~= "greeting" then
    return false
  end
  if PHASES[state.phase] ~= true or type(state.completed) ~= "boolean" then
    return false
  end
  if type(state.node) ~= "table" or type(state.opened) ~= "boolean" then
    return false
  end
  if state.op == "edit" and state.kind == nil then
    return false
  end
  for key in pairs(state) do
    if
      key ~= "op"
      and key ~= "kind"
      and key ~= "node"
      and key ~= "request"
      and key ~= "phase"
      and key ~= "opened"
      and key ~= "leftWorld"
      and key ~= "restored"
      and key ~= "fadeLease"
      and key ~= "completed"
      and key ~= "cancelled"
    then
      return false
    end
  end
  return true
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function EasyChatTask.poll(state, ctx)
  assert(validShape(state), "word editor task polls a valid state")
  if state.completed then
    return { complete = true, state = state }
  end
  if not state.opened then
    openChild(state, ctx)
    return { complete = false, state = state }
  end
  local host = hostFor(ctx)
  local handle = liveHandle(state, ctx)
  local input = ctx.input or {}
  local events = (input --[[@as table<string, unknown>]]).uiEvents or {}
  assert(type(events) == "table", "word editor consumes scheduler UI events")
  local ok, stepErr = pcall(host.step, host, handle, events)
  if not ok then
    if state.leftWorld == true and state.restored ~= true then
      lifecycleFor(ctx):restore()
      state.restored = true
    end
    error(stepErr, 0)
  end
  local result = host:result(handle)
  if result == nil then
    return { complete = false, state = state }
  end
  if state.op == "greeting" then
    if state.phase == "open" then
      beginRestore(state, ctx)
      return { complete = false, state = state }
    end
    if state.phase == "restore" then
      beginFade(state, ctx)
      return { complete = false, state = state }
    end
    local screen = screenFor(ctx)
    if not screen:fadeDone() then
      return { complete = false, state = state }
    end
    screen:clearIfCurrent(state.fadeLease)
    state.fadeLease = nil
    host:close(handle)
    publishGreeting(state, ctx, result)
    state.phase = "done"
    state.completed = true
    return { complete = true, state = state }
  end
  return finishEdit(state, ctx, result)
end

---@param state table<string, unknown>
---@param reason string
---@param ctx table<string, unknown>|nil
function EasyChatTask.cancel(state, reason, ctx)
  assert(validShape(state), "word editor cancellation requires a valid state")
  assert(type(reason) == "string" and reason ~= "", "word editor cancellation requires a reason")
  if state.completed or ctx == nil then
    return
  end
  local services = ctx.services or {}
  if type(services.easyChatScriptHost) == "table" then
    (services.easyChatScriptHost --[[@as table]]):cancel(reason)
  end
  if state.fadeLease ~= nil and type(services.screen) == "table" then
    (services.screen --[[@as table]]):clearIfCurrent(state.fadeLease)
    state.fadeLease = nil
  end
  if state.leftWorld == true and state.restored ~= true and type(services.overworld) == "table" then
    (services.overworld --[[@as table]]):restore()
    state.restored = true
  end
  state.cancelled = reason
  state.completed = true
end

---@param state table<string, unknown>
---@return Errors.Error|nil
function EasyChatTask.validate(state)
  if not validShape(state) then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "word editor task state is invalid", {})
  end
  return nil
end

return EasyChatTask
