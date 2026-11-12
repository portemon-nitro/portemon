-- Word-script semantic surface and async result protocol: the word
-- operation constructors admit their exact operands through the shared
-- schema, validation, and compiler without flattening identities to
-- text; word message references evaluate to detached numeric payloads;
-- and the script-owned editor task initializes launch words, waits on
-- its single host child, and publishes ordered source results exactly
-- once with no scalar scheduler result. Synthetic vectors only.

local Assert = require("tests.support.Assert")

local T = {
  metadata = {
    tags = { "easychat" },
  },
  tests = {},
}

local NULL_WORD = 0xFFFF

-- Loads a word-script module that does not exist yet at this baseline.
-- The failure names the missing behaviour instead of surfacing as a
-- suite load error, so the pre-implementation red stays attributable.
---@param moduleName string
---@param missingMessage string
---@return table
local function requireFeature(moduleName, missingMessage)
  local ok, mod = pcall(require, moduleName)
  if not ok then
    error(missingMessage, 0)
  end
  assert(type(mod) == "table", missingMessage)
  return mod --[[@as table]]
end

---@return table task module
local function requireTask()
  local Task = requireFeature(
    "libs.hgss.src.script.tasks.EasyChatTask",
    "the field script has no word editor task yet: no word script can leave the field, wait on the editor, or publish ordered results"
  )
  Assert.equal(Task.type, "easy_chat", "the word editor task carries its source task identity")
  Assert.equal(Task.version, 1, "the word editor task carries its protocol version")
  return Task
end

-- Compiles one word operation through the production authoring path:
-- constructor, schema admission, validation, and graph compilation with
-- compiler-assigned node identities. Returns the compiled node.
---@param step table
---@return table node
local function compileStep(step)
  local Dsl = require("libs.script.src.Dsl")
  local Compiler = require("libs.script.src.Compiler")
  local script = Dsl.script({ api = 1, id = "test.word_script", steps = { step } })
  local graph = assert(Compiler.compile(script), "a well-formed word operation must compile")
  local count = 0
  for _ in pairs(graph.nodes) do
    count = count + 1
  end
  Assert.equal(count, 1, "one word step compiles to one node")
  local node = assert(graph.nodes[graph.entry], "the compiled word node is addressable")
  node.nodeId = graph.entry
  return node
end

---@return table world state resolving retail variable names
local function testWorld()
  local WorldState = require("libs.hgss.src.script.WorldState")
  local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
  return WorldState.new({
    catalogs = { flags = FieldScriptSymbols.flagsByName, variables = FieldScriptSymbols.variablesByName },
  })
end

-- A scripted domain service answering the exact request/commit surface
-- the task drives: canned editor requests plus a record of committed
-- wrapper results. The task owns lifecycle and publication order; this
-- double owns only domain mapping.
---@param request table
---@return table service, table record
local function stubService(request)
  local record = { commits = {}, greetings = 0 }
  local service = {}
  function service:requestForKind(kind, inputMode)
    record.kind = kind
    record.inputMode = inputMode
    return request
  end
  function service:requestForGreeting(inputMode)
    record.greetingInputMode = inputMode
    return request
  end
  function service:commitWrapper(kind, result)
    record.commits[#record.commits + 1] = { kind = kind, result = result }
  end
  function service:commitGreeting(result)
    record.greetings = record.greetings + 1
    record.greetingResult = result
  end
  return service, record
end

-- A fake single-child host in the style of the other script-owned
-- application tasks: opens once, steps on every owning tick, publishes
-- its canned terminal result once, and releases idempotently.
---@param result table|nil
---@param resultAfterSteps integer?
---@return table ctx, table state
local function contextWithHost(result, resultAfterSteps)
  local world = testWorld()
  local hostState = { opens = 0, steps = 0, closes = 0, cancels = 0, active = nil, stored = result }
  local host = {}
  function host:open(request)
    hostState.opens = hostState.opens + 1
    hostState.request = request
    hostState.active = { id = hostState.opens }
    return hostState.active
  end
  function host:activeHandle()
    return hostState.active
  end
  function host:step(handle, events)
    Assert.equal(handle, hostState.active, "the task steps only its live child")
    hostState.steps = hostState.steps + 1
    hostState.events = events
  end
  function host:result(handle)
    Assert.equal(handle, hostState.active, "the task reads only its live child")
    if hostState.steps < (resultAfterSteps or 1) then
      return nil
    end
    local value = hostState.stored
    hostState.stored = nil
    return value
  end
  function host:close(handle)
    Assert.equal(handle, hostState.active, "the task closes only its live child")
    hostState.closes = hostState.closes + 1
    hostState.active = nil
  end
  function host:cancel(reason)
    Assert.equal(type(reason), "string", "host cancellation carries its reason")
    hostState.cancels = hostState.cancels + 1
    hostState.active = nil
  end
  local overworld = { leaves = 0, restores = 0 }
  local lifecycle = {}
  function lifecycle:leave()
    overworld.leaves = overworld.leaves + 1
  end
  function lifecycle:restore()
    overworld.restores = overworld.restores + 1
  end
  local ctx = {
    services = {
      easyChatService = nil,
      easyChatScriptHost = host,
      world = world,
      overworld = lifecycle,
    },
    input = { uiEvents = {} },
    instance = { scriptId = "test.word_script", locals = {} },
    tick = 7,
  }
  return ctx, hostState, overworld, world
end

-- The pair editor writes source-ordered results exactly once: result
-- first, then both words, with no scalar scheduler result, so an output
-- aliasing the result can never observe a torn write.
function T.tests.pair_editor_publishes_result_before_words_with_alias_safety()
  local Task = requireTask()
  local Dsl = require("libs.script.src.Dsl")
  local service, _ = stubService({ mode = 1 })
  local node = compileStep(Dsl.easyChatEdit({
    kind = 1,
    result = Dsl.var("VAR_UNK_407C"),
    word1 = Dsl.var("VAR_UNK_407D"),
    word2 = Dsl.var("VAR_UNK_407C"),
  }))
  local ctx, host, _, world = contextWithHost({
    mode = 1,
    words = { 41, 42 },
    cancelled = false,
    changed = true,
  })
  ctx.services.easyChatService = service
  local state = Task.create({ node = node }, ctx)
  Assert.isFalse(Task.poll(state, ctx).complete, "the task waits while the editor owns the child")
  local outcome = Task.poll(state, ctx)
  Assert.isTrue(outcome.complete, "the consumed terminal result completes the task")
  Assert.isNil(outcome.result, "a completed word poll publishes no scalar scheduler result")
  Assert.equal(world:getVar("VAR_UNK_407C"), 42, "an aliased word output keeps the later source-ordered write")
  Assert.equal(world:getVar("VAR_UNK_407D"), 41, "the first word output keeps its source-ordered write")
  Assert.equal(host.closes, 1, "the consumed child closes exactly once")
  local again = Task.poll(state, ctx)
  Assert.isTrue(again.complete, "a completed poll stays complete")
  Assert.equal(host.opens, 1, "a completed poll never reopens its child")
  Assert.equal(world:getVar("VAR_UNK_407C"), 42, "a repeated poll never republishes")
end

-- Ordinary edit terminals share one lifecycle and publication contract:
-- accepting, cancelling, or leaving the draft unchanged restores the
-- suspended field exactly once, closes the child exactly once, stays
-- complete on repeat polls, and publishes ordered outputs (result one
-- plus both words on change, result zero with words held otherwise).
function T.tests.ordinary_edits_restore_once_and_publish_ordered_outputs()
  local Task = requireTask()
  local Dsl = require("libs.script.src.Dsl")
  local cases = {
    {
      terminal = { mode = 1, words = { 41, 42 }, cancelled = false, changed = true },
      resultVar = 1,
      words = { 41, 42 },
      commits = 1,
    },
    {
      terminal = { mode = 1, words = { 41, 42 }, cancelled = true, changed = false },
      resultVar = 0,
      words = { NULL_WORD, NULL_WORD },
      commits = 0,
    },
    {
      terminal = { mode = 1, words = { 41, 42 }, cancelled = false, changed = false },
      resultVar = 0,
      words = { NULL_WORD, NULL_WORD },
      commits = 0,
    },
  }
  for _, case in ipairs(cases) do
    local service, record = stubService({ mode = 1 })
    local node = compileStep(Dsl.easyChatEdit({
      kind = 1,
      result = Dsl.var("VAR_UNK_407C"),
      word1 = Dsl.var("VAR_UNK_407D"),
      word2 = Dsl.var("VAR_UNK_407F"),
    }))
    local ctx, host, overworld, world = contextWithHost(case.terminal)
    ctx.services.easyChatService = service
    local state = Task.create({ node = node }, ctx)
    Assert.equal(overworld.leaves, 1, "creating the task suspends the field once")
    Assert.equal(overworld.restores, 0, "creation suspends without restoring")
    Assert.isFalse(Task.poll(state, ctx).complete, "the task waits while the editor owns the child")
    Assert.isTrue(Task.poll(state, ctx).complete, "the terminal result completes the task")
    Assert.equal(overworld.restores, 1, "a finished ordinary edit restores the field once")
    Assert.equal(host.closes, 1, "the consumed child closes exactly once")
    Assert.equal(world:getVar("VAR_UNK_407C"), case.resultVar, "the result output names the terminal verdict")
    Assert.equal(world:getVar("VAR_UNK_407D"), case.words[1], "the first word keeps its source-ordered write")
    Assert.equal(world:getVar("VAR_UNK_407F"), case.words[2], "the second word keeps its source-ordered write")
    Assert.equal(#record.commits, case.commits, "the wrapper commit runs only on accepted change")
    Assert.isTrue(Task.poll(state, ctx).complete, "a completed poll stays complete")
    Assert.equal(overworld.restores, 1, "a repeated poll never restores again")
    Assert.equal(world:getVar("VAR_UNK_407C"), case.resultVar, "a repeated poll never republishes")
  end
end

-- A request-construction failure never suspends the field: the lifecycle
-- stays present when the service cannot build the editor request.
function T.tests.request_failure_never_suspends_the_field()
  local Task = requireTask()
  local Dsl = require("libs.script.src.Dsl")
  local node = compileStep(Dsl.easyChatEdit({
    kind = 1,
    result = Dsl.var("VAR_UNK_407C"),
    word1 = Dsl.var("VAR_UNK_407D"),
    word2 = Dsl.var("VAR_UNK_407F"),
  }))
  local ctx, _, overworld, _ = contextWithHost(nil, 100)
  ctx.services.easyChatService = {
    requestForKind = function(_)
      error("injected request failure", 0)
    end,
    requestForGreeting = function(_)
      error("injected request failure", 0)
    end,
  }
  local ok, err = pcall(Task.create, { node = node }, ctx)
  Assert.isFalse(ok, "a failing request propagates its error")
  Assert.isTrue(tostring(err):find("injected request failure", 1, true) ~= nil)
  Assert.equal(overworld.leaves, 0, "a failed request never suspends the field")
  Assert.equal(overworld.restores, 0, "a failed request never restores either")
end

-- Launch initializes both pair words to empty before the editor opens:
-- the previous variable contents never leak into the draft.
function T.tests.pair_launch_initializes_both_words_to_empty()
  local Task = requireTask()
  local Dsl = require("libs.script.src.Dsl")
  local service, record = stubService({ mode = 1 })
  local node = compileStep(Dsl.easyChatEdit({
    kind = 1,
    result = Dsl.var("VAR_UNK_407C"),
    word1 = Dsl.var("VAR_UNK_407D"),
    word2 = Dsl.var("VAR_UNK_407F"),
  }))
  local ctx, _, _, world = contextWithHost(nil, 100)
  ctx.services.easyChatService = service
  world:setVar("VAR_UNK_407D", 41)
  world:setVar("VAR_UNK_407F", 42)
  Task.create({ node = node }, ctx)
  Assert.equal(record.kind, 1, "the task maps the literal pair kind before opening")
  Assert.equal(world:getVar("VAR_UNK_407D"), NULL_WORD, "launch clears the first word output")
  Assert.equal(world:getVar("VAR_UNK_407F"), NULL_WORD, "launch clears the second word output")
  local waiting = Task.create({ node = node }, ctx)
  Assert.isFalse(Task.poll(waiting, ctx).complete, "the task waits on its child")
end

-- Early task cancellation releases the owned child without publishing.
function T.tests.early_cancellation_releases_the_child_without_publishing()
  local Task = requireTask()
  local Dsl = require("libs.script.src.Dsl")
  local service, _ = stubService({ mode = 1 })
  local node = compileStep(Dsl.easyChatEdit({
    kind = 1,
    result = Dsl.var("VAR_UNK_407C"),
    word1 = Dsl.var("VAR_UNK_407D"),
    word2 = Dsl.var("VAR_UNK_407F"),
  }))
  local ctx, host, _, world = contextWithHost(nil, 100)
  ctx.services.easyChatService = service
  local state = Task.create({ node = node }, ctx)
  Assert.isFalse(Task.poll(state, ctx).complete, "the task waits while the editor owns the child")
  Task.cancel(state, "script cancelled", ctx)
  Assert.equal(host.cancels, 1, "cancellation releases the owned child exactly once")
  Assert.equal(world:getVar("VAR_UNK_407C"), 0, "cancellation publishes no result")
end

-- A word operation round-trips its exact operands through authoring:
-- validation admits it, compilation detaches it, and mutating the
-- authored record afterwards cannot move the compiled node.
function T.tests.word_operations_round_trip_exact_operands_through_authoring()
  requireTask()
  local Dsl = require("libs.script.src.Dsl")
  local Validator = require("libs.script.src.Validator")
  local draft = {
    kind = 2,
    result = Dsl.var("VAR_UNK_407C"),
    word1 = Dsl.var("VAR_UNK_407D"),
  }
  local step = Dsl.easyChatEdit(draft)
  local script = Dsl.script({ api = 1, id = "test.word_round_trip", steps = { step } })
  local ok, err = Validator.validate(script)
  Assert.isTrue(ok == true, "a well-formed word edit validates: " .. tostring(err))
  local node = compileStep(Dsl.easyChatEdit(draft))
  Assert.notNil(node.nodeId, "the compiled word node carries its identity")
  draft.kind = 5
  Assert.equal(node.kind, 2, "compilation detaches the evaluated kind from later authoring mutation")
end

-- The instant printer request is admitted only on a non-waiting word
-- message: waiting word dialogue keeps the ordinary cadence.
function T.tests.instant_printing_is_admitted_only_for_nonwaiting_word_messages()
  requireTask()
  local Dsl = require("libs.script.src.Dsl")
  local Validator = require("libs.script.src.Validator")
  local instant = Dsl.script({
    api = 1,
    id = "test.word_instant",
    steps = {
      Dsl.message({ message = Dsl.easyChatMessage(0, 0, 41, NULL_WORD), waitForPrint = false, instant = true }),
    },
  })
  local ok, err = Validator.validate(instant)
  Assert.isTrue(ok == true, "an instant non-waiting word message validates: " .. tostring(err))
  local waiting = Dsl.script({
    api = 1,
    id = "test.word_waiting_instant",
    steps = {
      Dsl.message({ message = Dsl.easyChatMessage(0, 0, 41, NULL_WORD), waitForPrint = true, instant = true }),
    },
  })
  local waitingOk = Validator.validate(waiting)
  Assert.isFalse(waitingOk == true, "an instant waiting message is rejected")
end

-- A word message reference evaluates to a detached numeric payload:
-- banks, numbers, and both words survive, and later variable writes
-- cannot move the evaluated snapshot.
function T.tests.word_message_references_evaluate_to_detached_payloads()
  requireTask()
  local Dsl = require("libs.script.src.Dsl")
  local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
  local world = testWorld()
  world:setVar("VAR_UNK_407C", 41)
  local run = {
    services = { world = world },
    instance = { scriptId = "test.word_message", locals = {} },
    node = { nodeId = "test-node" },
  }
  local payload = RuntimeValues.evaluateMessage(Dsl.easyChatMessage(0, 3, 41, NULL_WORD), run)
  Assert.equal(payload.bank, 0, "evaluation keeps the sentence bank")
  Assert.equal(payload.number, 3, "evaluation keeps the sentence number")
  Assert.deepEqual(payload.words, { 41, NULL_WORD }, "evaluation keeps both word identities")
  world:setVar("VAR_UNK_407C", 7)
  Assert.deepEqual(payload.words, { 41, NULL_WORD }, "the evaluated payload ignores later variable writes")
end

return T
