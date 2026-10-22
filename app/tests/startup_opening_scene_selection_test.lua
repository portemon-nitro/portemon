-- One numbered opening scene travels the epoch cache host as a keyed demand:
-- the same scene deduplicates to one worker request, another scene stays
-- its own pending request, and only demanded scenes ever leave the game
-- thread.

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

function T.opening_scene_requests_dedupe_by_scene_and_leave_other_scenes_pending()
  local service, provisioner = selectGame()
  local epoch = assert(provisioner.epoch, "the selection borrows an epoch")
  local gameHost = provisioner:gameHost()
  Assert.isTrue(
    type(gameHost.requestOpeningScene) == "function",
    "the selected game host demands its numbered opening scene"
  )
  local pending, pendingErr = gameHost.requestOpeningScene(4, "required")
  Assert.isNil(pending, "an unbuilt scene observes no readiness")
  Assert.isNil(pendingErr, "an unbuilt scene observes no failure")
  local first = service:request(epoch, { requestKind = "opening-scene", sceneNumber = 4, urgency = "required" })
  Assert.notNil(first, "the scene selector routes to the worker")
  local second = service:request(epoch, { requestKind = "opening-scene", sceneNumber = 4, urgency = "near" })
  Assert.equal(second, first, "the same scene deduplicates to one worker request")
  local other = service:request(epoch, { requestKind = "opening-scene", sceneNumber = 2, urgency = "required" })
  Assert.isTrue(other ~= first, "another scene stays its own worker request")
  service:update()
  local sceneKeys = {}
  for _, command in ipairs(drainCommands(service)) do
    if command.op == "request" and command.requestKind == "opening-scene" then
      sceneKeys[#sceneKeys + 1] = command.sceneNumber
    end
  end
  Assert.equal(#sceneKeys, 2, "only the two demanded scenes leave the game thread")
  local seen = {}
  for _, sceneNumber in ipairs(sceneKeys) do
    seen[sceneNumber] = true
  end
  Assert.isTrue(seen[4] == true and seen[2] == true, "the worker sees exactly the demanded scenes")
  local stillPending, _ = service:observe(epoch, { requestKind = "opening-scene", sceneNumber = 2 })
  Assert.isNil(stillPending, "the second scene stays pending before its answer lands")
  service:injectReply({ op = "request-result", epoch = epoch, requestId = first, state = "ready" })
  service:update()
  local ready, failure = gameHost.requestOpeningScene(4, "required")
  Assert.isTrue(ready, "the pushed ready event lands in the matching scene observation")
  Assert.isNil(failure, "a ready scene carries no failure")
  local otherPending, _ = gameHost.requestOpeningScene(2, "required")
  Assert.isNil(otherPending, "the other scene stays pending after the first scene completes")
  provisioner:dispose()
  service:shutdown()
end

function T.opening_scene_requests_reject_scene_numbers_outside_one_to_five()
  local service, provisioner = selectGame()
  local gameHost = provisioner:gameHost()
  Assert.isTrue(
    type(gameHost.requestOpeningScene) == "function",
    "the selected game host demands its numbered opening scene"
  )
  for _, badScene in ipairs({ 0, 6, 2.5, "4" }) do
    local ok, _ = pcall(function()
      gameHost.requestOpeningScene(badScene, "required")
    end)
    Assert.isFalse(ok, "scene number " .. tostring(badScene) .. " never leaves the game thread")
  end
  service:update()
  for _, command in ipairs(drainCommands(service)) do
    Assert.isFalse(command.requestKind == "opening-scene", "a rejected scene number queues no worker request")
  end
  provisioner:dispose()
  service:shutdown()
end

return { tests = T }
