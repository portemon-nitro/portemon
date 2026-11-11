-- The word editor handoff through the gear shell: a pending map word
-- request opens the shared editor over the retained map card, the shell
-- owns its raw batch and input key exclusively while open, and the
-- terminal result settles once through the single map settlement path.
-- Stub cards and editor doubles at the host boundary; the shell, request
-- identity, and settlement rules stay production.

local Assert = require("tests.support.Assert")
local LocalClock = require("game.src.LocalClock")
local PokegearScreenState = require("game.hgss.src.pokegear.PokegearScreenState")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

-- A minimal shell presentation: the handoff owns input routing and the
-- child lifetime, never the gear visuals.
local function stubPlan()
  return {
    panes = {},
    frames = {},
    content = {},
    inputKey = "pokegear-stub",
    render = function() end,
    mapInput = function(event)
      return event
    end,
  }
end

local function stubPresentation()
  return {
    dualDisplay = function()
      return stubPlan()
    end,
    nativeLike = function()
      return stubPlan()
    end,
    wide = function()
      return stubPlan()
    end,
    tall = function()
      return stubPlan()
    end,
  }
end

local T = {
  metadata = {
    tags = { "easychat" },
  },
  tests = {},
}

local NULL_WORD = 0xFFFF

---@return table civil clock
local function stubClock()
  return LocalClock.new(function()
    return { year = 2024, month = 5, day = 6, hour = 12, minute = 34, second = 56 }
  end)
end

---@return table display measurement
local function displayFacts()
  return {
    width = 512,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "world", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "aux", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
    ),
    pixelRatio = 1,
    signature = "easy-chat-shell-test",
  }
end

---@return table stub companion state with the map card available
local function stubState()
  return {
    readPreferences = function()
      return { lastApp = "map", skin = 0 }
    end,
    setPreference = function() end,
    capture = function()
      return { registeredCards = { map = true } }
    end,
  }
end

-- A stub map card: confirms pend one typed word request, ticks park while
-- pending, and the single settlement path records its answers.
---@return table child
local function stubMapCard()
  local child = {
    updates = 0,
    disposed = false,
    pending = nil,
    settled = {},
    captures = 0,
    operations = 0,
  }
  function child:updateFixed(events)
    assert(not self.disposed, "a disposed card steps nothing")
    if self.pending ~= nil then
      return
    end
    self.updates = self.updates + 1
    for _, event in ipairs(assert(events, "card input must be an event list")) do
      if event.type == "confirm" then
        self.operations = self.operations + 1
        self.pending = {
          mapSymbol = "MAP_A",
          slot = 1,
          oldWord = false,
          operationId = "map-word-" .. self.operations,
          session = {},
          inputMode = "touch",
        }
      end
    end
  end
  function child:status()
    return {
      open = true,
      tab = "map",
      busy = self.pending ~= nil,
      dismissible = self.pending == nil,
      nestedCancel = self.pending ~= nil,
      stripHidden = false,
      view = { mode = "marking", world = {} },
    }
  end
  function child:takeResult()
    return nil
  end
  function child:dispose()
    self.disposed = true
  end
  function child:takeWordRequest()
    local request = self.pending
    self.pending = nil
    return request
  end
  function child:acceptWordResult(answer)
    assert(type(answer) == "table" and type(answer.operationId) == "string", "answers name their operation")
    self.settled[#self.settled + 1] = answer
    return nil
  end
  function child:cancelWordCapture()
    self.captures = self.captures + 1
  end
  function child:cancelPointerCapture() end
  return child
end

-- A scripted editor child: readies on its second step, then publishes
-- one terminal result.
---@param result table terminal payload
---@return table child, table calls
local function scriptedEditor(result)
  local calls = { updates = 0, disposes = 0, cancels = 0 }
  local child = {
    uiInput = { buttons = { l = true } },
    _calls = calls,
    _result = result,
    _published = false,
  }
  function child:updateFixed(events)
    assert(type(events) == "table", "editor input must be an event list")
    self._calls.updates = self._calls.updates + 1
  end
  function child:status()
    return { uiInput = "easy-chat", view = { level = "composition" } }
  end
  function child:takeResult()
    if self._calls.updates >= 2 and not self._published then
      self._published = true
      return self._result
    end
    return nil
  end
  function child:dispose()
    self._calls.disposes = self._calls.disposes + 1
  end
  function child:cancelPointerCapture()
    self._calls.cancels = self._calls.cancels + 1
  end
  return child, calls
end

---@param map table
---@param factory fun(request: table): table
---@return table shell
local function openShell(map, factory)
  return PokegearScreenState.new({
    state = stubState(),
    assets = {},
    clock = stubClock(),
    children = {
      configure = function()
        error("unexpected card", 0)
      end,
      radio = function()
        error("unexpected card", 0)
      end,
      map = function()
        return map
      end,
      phone = function()
        error("unexpected card", 0)
      end,
    },
    presentation = stubPresentation(),
    effect = function() end,
    entry = { kind = "browse" },
    measureDisplay = displayFacts,
    openEasyChat = factory,
  })
end

local function settleFade(shell, count)
  for _ = 1, count or 30 do
    shell:updateFixed({})
    if shell:status().easyChat ~= nil then
      return
    end
  end
  error("the word editor child never opens", 0)
end

function T.tests.pending_requests_open_the_editor_over_the_parked_map()
  local map = stubMapCard()
  local opened = {}
  local shell = openShell(map, function(request)
    opened[#opened + 1] = request
    return scriptedEditor({ cancelled = false, words = { 1234, NULL_WORD }, inputMode = "buttons" })
  end)
  shell:updateFixed({})
  local updatesBefore = map.updates
  shell:updateFixed({ { type = "confirm" } })
  shell:updateFixed({ { type = "confirm" } })
  Assert.isNil(shell:status().easyChat, "no child opens before the map pends its request")
  settleFade(shell)
  local editor = assert(shell:status().easyChat, "the pending request opens the shell-owned child")
  Assert.equal(editor.uiInput, "easy-chat", "the editor child owns the display input key")
  Assert.equal(shell.uiInput.buttons.l, true, "the shell publishes the child input profile")
  Assert.deepEqual(
    opened[1],
    { mode = 0, words = { NULL_WORD, NULL_WORD }, promptId = 0, alwaysConfirm = false, inputMode = "touch" },
    "the shell opens the editor over the retained map with the pending payload"
  )
  local parked = map.updates
  shell:updateFixed({})
  Assert.equal(map.updates, parked, "the retained map stays parked while the child owns display")
  Assert.equal(updatesBefore < parked, true, "the map stepped before the handoff")
end

function T.tests.accepted_results_settle_once_and_restore_the_retained_map()
  local map = stubMapCard()
  local editor, calls = scriptedEditor({ cancelled = false, words = { 1234, NULL_WORD }, inputMode = "buttons" })
  local shell = openShell(map, function()
    return editor
  end)
  shell:updateFixed({})
  shell:updateFixed({ { type = "confirm" } })
  shell:updateFixed({ { type = "confirm" } })
  settleFade(shell)
  for _ = 1, 12 do
    shell:updateFixed({})
    if shell:status().easyChat == nil then
      break
    end
  end
  Assert.isNil(shell:status().easyChat, "the exited child leaves the shell")
  Assert.equal(#map.settled, 1, "the terminal result settles exactly once")
  local answer = map.settled[1]
  Assert.equal(answer.operationId, "map-word-1", "the settlement names the pending operation")
  Assert.deepEqual(
    answer.result,
    { cancelled = false, word = "1234", inputMode = "buttons" },
    "the accepted word converts once to its decimal identity"
  )
  Assert.equal(calls.disposes, 1, "the settled child disposes exactly once")
  Assert.isNil(shell.uiInput, "the shell restores its own input profile")
  local parked = map.updates
  for _ = 1, 10 do
    shell:updateFixed({})
  end
  Assert.isTrue(map.updates > parked, "ordinary map input resumes after the return")
end

function T.tests.cancelled_results_preserve_the_marking()
  local map = stubMapCard()
  local editor = scriptedEditor({ cancelled = true, words = { NULL_WORD, NULL_WORD }, inputMode = "touch" })
  local shell = openShell(map, function()
    return editor
  end)
  shell:updateFixed({})
  shell:updateFixed({ { type = "confirm" } })
  shell:updateFixed({ { type = "confirm" } })
  settleFade(shell)
  for _ = 1, 12 do
    shell:updateFixed({})
    if shell:status().easyChat == nil then
      break
    end
  end
  Assert.equal(#map.settled, 1, "a cancelled edit settles exactly once")
  Assert.isTrue(map.settled[1].result.cancelled, "the cancellation preserves the marking")
  Assert.isNil(shell:status().easyChat, "the cancelled child leaves the shell")
end

function T.tests.factory_failures_unblock_the_pending_edit_and_propagate()
  local map = stubMapCard()
  local shell = openShell(map, function()
    error("editor image pool failure", 0)
  end)
  shell:updateFixed({})
  shell:updateFixed({ { type = "confirm" } })
  shell:updateFixed({ { type = "confirm" } })
  local ok, err = pcall(settleFade, shell, 30)
  Assert.isFalse(ok, "a failed open propagates its original cause")
  Assert.isTrue(
    tostring(err):find("editor image pool failure", 1, true) ~= nil,
    "the original cause propagates: " .. tostring(err)
  )
  Assert.isNil(shell:status().easyChat, "a failed open owns no child")
  Assert.equal(#map.settled, 1, "the failed open unblocks the pending edit")
  Assert.isTrue(map.settled[1].result.cancelled, "the unblocked edit preserves its marking")
end

return T
