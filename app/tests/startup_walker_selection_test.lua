-- One selected walking pair travels the epoch cache host as a keyed demand:
-- the same pair deduplicates to one worker request, another pair stays its
-- own pending request, and only demanded pairs ever leave the game thread.

local Assert = require("tests.support.Assert")

local T = {}

local function newChannelHost()
  local function newChannel()
    local queue = {}
    local channel = {}
    function channel:push(value)
      queue[#queue + 1] = value
      return true
    end
    function channel:pop()
      if #queue == 0 then
        return nil
      end
      return table.remove(queue, 1)
    end
    function channel:demand(_)
      return table.remove(queue, 1)
    end
    function channel:count()
      return #queue
    end
    return channel
  end
  local threads = {}
  local function newThread(source)
    local thread = { source = source, starts = 0, waits = 0, alive = true }
    function thread:start(...)
      return true
    end
    function thread:wait()
      self.waits = self.waits + 1
      self.alive = false
      return true
    end
    function thread:isRunning()
      return self.alive
    end
    function thread:getError()
      return nil
    end
    threads[#threads + 1] = thread
    return thread
  end
  return { newChannel = newChannel, newThread = newThread, threads = threads }
end

local function selectGame()
  local CacheService = require("app.src.CacheService")
  local DerivedAssetProvisioner = require("app.src.DerivedAssetProvisioner")
  local service = assert(CacheService.new({ thread = newChannelHost() }))
  local provisioner = DerivedAssetProvisioner.new({ versionId = "heartgold", service = service })
  return service, provisioner
end

local function drainCommands(service)
  local commands = {}
  local command = service._command:pop()
  while command ~= nil do
    commands[#commands + 1] = command
    command = service._command:pop()
  end
  return commands
end

function T.startup_walker_requests_dedupe_by_pair_and_leave_other_pairs_pending()
  local service, provisioner = selectGame()
  local epoch = assert(provisioner.epoch, "the selection borrows an epoch")
  local gameHost = provisioner:gameHost()
  Assert.isTrue(
    type(gameHost.requestStartupWalker) == "function",
    "the selected game host demands its walking pair"
  )
  local pending, pendingErr = gameHost.requestStartupWalker(5, "required")
  Assert.isNil(pending, "an unbuilt pair observes no readiness")
  Assert.isNil(pendingErr, "an unbuilt pair observes no failure")
  local first = service:request(epoch, { requestKind = "startup-walker", pairIndex = 5, urgency = "required" })
  Assert.notNil(first, "the pair selector routes to the worker")
  local second = service:request(epoch, { requestKind = "startup-walker", pairIndex = 5, urgency = "near" })
  Assert.equal(second, first, "the same pair deduplicates to one worker request")
  local other = service:request(epoch, { requestKind = "startup-walker", pairIndex = 6, urgency = "required" })
  Assert.isTrue(other ~= first, "another pair stays its own worker request")
  service:update()
  local pairKeys = {}
  for _, command in ipairs(drainCommands(service)) do
    if command.op == "request" and command.requestKind == "startup-walker" then
      pairKeys[#pairKeys + 1] = command.pairIndex
    end
  end
  Assert.equal(#pairKeys, 2, "only the two demanded pairs leave the game thread")
  local seen = {}
  for _, pairIndex in ipairs(pairKeys) do
    seen[pairIndex] = true
  end
  Assert.isTrue(seen[5] == true and seen[6] == true, "the worker sees exactly the demanded pairs")
  local stillPending, _ = service:observe(epoch, { requestKind = "startup-walker", pairIndex = 6 })
  Assert.isNil(stillPending, "the second pair stays pending before its answer lands")
  service:injectReply({ op = "request-result", epoch = epoch, requestId = first, state = "ready" })
  service:update()
  local ready, failure = gameHost.requestStartupWalker(5, "required")
  Assert.isTrue(ready, "the pushed ready event lands in the matching pair observation")
  Assert.isNil(failure, "a ready pair carries no failure")
  local otherPending, _ = gameHost.requestStartupWalker(6, "required")
  Assert.isNil(otherPending, "the other pair stays pending after the first pair completes")
  provisioner:dispose()
  service:shutdown()
end

function T.startup_walker_requests_reject_indexes_outside_the_thirty_two_choices()
  local service, provisioner = selectGame()
  local gameHost = provisioner:gameHost()
  Assert.isTrue(
    type(gameHost.requestStartupWalker) == "function",
    "the selected game host demands its walking pair"
  )
  for _, badIndex in ipairs({ 0, 33, 2.5, "5" }) do
    local ok, _ = pcall(function()
      gameHost.requestStartupWalker(badIndex, "required")
    end)
    Assert.isFalse(ok, "pair index " .. tostring(badIndex) .. " never leaves the game thread")
  end
  service:update()
  for _, command in ipairs(drainCommands(service)) do
    Assert.isFalse(
      command.requestKind == "startup-walker",
      "a rejected pair index queues no worker request"
    )
  end
  provisioner:dispose()
  service:shutdown()
end

return { tests = T }
