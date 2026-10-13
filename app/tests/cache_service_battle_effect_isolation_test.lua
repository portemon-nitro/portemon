-- Lower-level effect isolation over the cache transport: effect and scene
-- identities never alias, malformed keys and urgencies never leave the
-- game thread, and terminal observations keep their shape across repeats.
-- No dump is needed; the controller is a deterministic in-memory host.

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
  local function newThread(source)
    local thread = { source = source, starts = 0, waits = 0, alive = true }
    function thread:start(...)
      self.starts = self.starts + 1
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
    return thread
  end
  return { newChannel = newChannel, newThread = newThread }
end

function T.effect_and_scene_identities_never_alias()
  local Service = require("app.src.CacheService")
  local service = assert(Service.new({ thread = newChannelHost() }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  local effectOk, effectId = pcall(service.request, service, epoch, {
    requestKind = "battle-effect",
    effectKey = "synthetic-isolation",
    urgency = "near",
  })
  Assert.isTrue(effectOk and type(effectId) == "number", "the effect registers its identity")
  local sceneOk, sceneId = pcall(service.request, service, epoch, {
    requestKind = "battle-scene",
    sceneKey = "general/grass/day",
    urgency = "near",
  })
  Assert.isTrue(sceneOk and type(sceneId) == "number", "the scene registers its identity")
  Assert.isTrue(effectId ~= sceneId, "effect and scene identities never alias")
  local ready, failure = service:observe(epoch, { requestKind = "battle-effect", effectKey = "synthetic-isolation" })
  Assert.isNil(ready, "an unstaged effect observes no readiness")
  Assert.isNil(failure, "an unstaged effect observes no failure")
  service:shutdown()
end

function T.malformed_effect_demands_never_leave_the_game_thread()
  local Service = require("app.src.CacheService")
  local Provisioner = require("app.src.DerivedAssetProvisioner")
  local service = assert(Service.new({ thread = newChannelHost() }))
  local provisioner = Provisioner.new({ versionId = "heartgold", service = service })
  local gameHost = provisioner:gameHost()
  for _, badKey in ipairs({ "", "has/slash", "a/b/c" }) do
    local ok, _ = pcall(function()
      gameHost.requestBattleEffect(badKey, "required")
    end)
    Assert.isFalse(ok, "a malformed effect key never leaves the game thread: " .. tostring(badKey))
  end
  local badUrgencyOk, _ = pcall(function()
    gameHost.requestBattleEffect("synthetic-isolation", "eventually")
  end)
  Assert.isFalse(badUrgencyOk, "an unknown urgency never leaves the game thread")
  local badTypeOk, _ = pcall(function()
    gameHost.requestBattleEffect(7, "required")
  end)
  Assert.isFalse(badTypeOk, "a non-string effect key never leaves the game thread")
  provisioner:dispose()
  service:shutdown()
end

function T.terminal_effect_observations_keep_their_shape()
  local Service = require("app.src.CacheService")
  local Provisioner = require("app.src.DerivedAssetProvisioner")
  local service = assert(Service.new({ thread = newChannelHost() }))
  local provisioner = Provisioner.new({ versionId = "heartgold", service = service })
  local epoch = assert(provisioner.epoch, "selection borrows an epoch")
  local gameHost = provisioner:gameHost()
  local pending, pendingErr = gameHost.requestBattleEffect("synthetic-shape", "required")
  Assert.isNil(pending, "an unstaged effect starts pending")
  Assert.isNil(pendingErr, "an unstaged effect starts without failure")
  local id = assert(
    service._byKey[tostring(epoch) .. ":battle-effect:synthetic-shape"],
    "the demand registers its selector identity"
  )
  service:update()
  local coldRequests = 0
  local command = service._command:pop()
  while command ~= nil do
    if command.op == "request" and command.requestKind == "battle-effect" then
      coldRequests = coldRequests + 1
      Assert.equal(command.requestId, id, "the cold demand dispatches its registered identity")
    end
    command = service._command:pop()
  end
  Assert.equal(coldRequests, 1, "the cold demand dispatches one worker request")
  service:injectReply({ op = "request-result", epoch = epoch, requestId = id, state = "ready" })
  service:update()
  local ready, failure = gameHost.requestBattleEffect("synthetic-shape", "required")
  Assert.isTrue(ready, "the ready observation reports readiness")
  Assert.isNil(failure, "a ready observation carries no failure")
  local again, againErr = gameHost.requestBattleEffect("synthetic-shape", "required")
  Assert.isTrue(again, "a warm observation trusts its receipt")
  Assert.isNil(againErr, "a warm observation carries no failure")
  service:update()
  command = service._command:pop()
  while command ~= nil do
    Assert.isFalse(
      command.op == "request" and command.requestKind == "battle-effect",
      "a warm receipt does not enqueue another worker request"
    )
    command = service._command:pop()
  end
  provisioner:dispose()
  service:shutdown()
end

return { tests = T }
