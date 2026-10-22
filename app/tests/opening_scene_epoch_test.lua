-- The numbered opening scene rides the epoch cache host like any keyed
-- demand: retiring the epoch revokes observation, and a background demand
-- strengthens to required through one promote.

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
  local function newThread(_)
    local thread = { alive = true }
    function thread:start(...)
      return true
    end
    function thread:wait()
      self.alive = false
      return true
    end
    function thread:isRunning()
      return self.alive
    end
    function thread:getError()
      return nil
    end
    return thread
  end
  return { newChannel = newChannel, newThread = newThread }
end

local function selectGame()
  local CacheService = require("app.src.CacheService")
  local DerivedAssetProvisioner = require("app.src.DerivedAssetProvisioner")
  local service = assert(CacheService.new({ thread = newChannelHost() }))
  local provisioner = DerivedAssetProvisioner.new({ versionId = "soulsilver", service = service })
  return service, provisioner
end

function T.opening_scene_requests_promote_from_near_to_required()
  local service, provisioner = selectGame()
  local epoch = assert(provisioner.epoch, "the selection borrows an epoch")
  local gameHost = provisioner:gameHost()
  local first = service:request(epoch, { requestKind = "opening-scene", sceneNumber = 3, urgency = "near" })
  Assert.notNil(first, "the near scene demand routes to the worker")
  service:update()
  local requested = 0
  local command = service._command:pop()
  while command ~= nil do
    if command.op == "request" then
      requested = requested + 1
    end
    command = service._command:pop()
  end
  Assert.equal(requested, 1, "the scene leaves the game thread once")
  local second = service:request(epoch, { requestKind = "opening-scene", sceneNumber = 3, urgency = "required" })
  Assert.equal(second, first, "strengthening keeps the one worker request")
  service:update()
  local promoted = 0
  command = service._command:pop()
  while command ~= nil do
    if command.op == "promote" then
      promoted = promoted + 1
    end
    Assert.isTrue(command.op ~= "request", "no second scene request leaves the game thread")
    command = service._command:pop()
  end
  Assert.equal(promoted, 1, "the near demand strengthens through one promote")
  provisioner:dispose()
  service:shutdown()
end

function T.opening_scene_requests_go_stale_with_their_epoch()
  local service, provisioner = selectGame()
  local epoch = assert(provisioner.epoch, "the selection borrows an epoch")
  local gameHost = provisioner:gameHost()
  local first = service:request(epoch, { requestKind = "opening-scene", sceneNumber = 1, urgency = "required" })
  Assert.notNil(first, "the scene demand routes to the worker")
  provisioner:dispose()
  local stale = service:request(epoch, { requestKind = "opening-scene", sceneNumber = 1, urgency = "required" })
  Assert.isNil(stale, "a retired epoch queues no scene request")
  local ready, failure = service:observe(epoch, { requestKind = "opening-scene", sceneNumber = 1 })
  Assert.isNil(ready, "a retired epoch observes no readiness")
  Assert.isNil(failure, "a retired epoch observes no failure")
  local ok, _ = pcall(function()
    gameHost.requestOpeningScene(1, "required")
  end)
  Assert.isFalse(ok, "the retired host demands no scene")
  service:shutdown()
end

function T.opening_scene_failures_land_in_the_matching_scene_only()
  local service, provisioner = selectGame()
  local epoch = assert(provisioner.epoch, "the selection borrows an epoch")
  local gameHost = provisioner:gameHost()
  gameHost.requestOpeningScene(1, "required")
  gameHost.requestOpeningScene(5, "required")
  service:update()
  service:update()
  local ids = {}
  local command = service._command:pop()
  while command ~= nil do
    if command.op == "request" and command.requestKind == "opening-scene" then
      ids[command.sceneNumber] = command.requestId
    end
    command = service._command:pop()
  end
  Assert.notNil(ids[1], "scene 1 leaves the game thread")
  Assert.notNil(ids[5], "scene 5 leaves the game thread")
  service:injectReply({
    op = "request-result",
    epoch = epoch,
    requestId = ids[1],
    state = "failed",
    errorMessage = "boom",
  })
  service:update()
  local ready, failure = gameHost.requestOpeningScene(1, "required")
  Assert.isNil(ready, "the failed scene never reads ready")
  Assert.notNil(failure, "the failed scene carries its cause")
  local otherReady, otherFailure = gameHost.requestOpeningScene(5, "required")
  Assert.isNil(otherReady, "the sibling scene stays pending after the failure")
  Assert.isNil(otherFailure, "the sibling scene carries no failure")
  provisioner:dispose()
  service:shutdown()
end

return { tests = T }
