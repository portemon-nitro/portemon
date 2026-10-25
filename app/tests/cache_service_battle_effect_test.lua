-- Lazy battle effect publication over the process cache service: one cold
-- effect shares a single worker identity across repeated requests and
-- urgency promotion, a cancelled generation never publishes into a later
-- one, and the selected-game host demands effects through the existing
-- closure convention. No dump is needed; the controller is a deterministic
-- in-memory host.

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
    threads[#threads + 1] = thread
    return thread
  end
  return { newChannel = newChannel, newThread = newThread, threads = threads }
end

local function cacheService()
  return require("app.src.CacheService")
end

local function provisionerModule()
  return require("app.src.DerivedAssetProvisioner")
end

function T.cold_effect_requests_share_one_worker_identity_with_promotion()
  local Service = cacheService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  local firstOk, firstId = pcall(service.request, service, epoch, {
    requestKind = "battle-effect",
    effectKey = "synthetic-probe",
    urgency = "near",
  })
  Assert.isTrue(
    firstOk and type(firstId) == "number",
    "one cold effect request registers its worker identity: " .. tostring(firstId)
  )
  local secondOk, secondId = pcall(service.request, service, epoch, {
    requestKind = "battle-effect",
    effectKey = "synthetic-probe",
    urgency = "near",
  })
  Assert.isTrue(secondOk, "a repeated cold effect request stays idempotent")
  Assert.equal(secondId, firstId, "repeated requests share one active job per effect identity")
  local promotedOk, promotedId = pcall(service.request, service, epoch, {
    requestKind = "battle-effect",
    effectKey = "synthetic-probe",
    urgency = "required",
  })
  Assert.isTrue(promotedOk, "urgency promotion keeps the shared identity")
  Assert.equal(promotedId, firstId, "promotion strengthens the existing job instead of duplicating it")
  local otherOk, otherId = pcall(service.request, service, epoch, {
    requestKind = "battle-effect",
    effectKey = "synthetic-unrelated",
    urgency = "required",
  })
  Assert.isTrue(otherOk and otherId ~= firstId, "an unrelated effect keeps its own worker identity")
  service:update()
  local effectCommands = 0
  local command = service._command:pop()
  while command ~= nil do
    if command.op == "request" and command.requestKind == "battle-effect" then
      effectCommands = effectCommands + 1
    end
    command = service._command:pop()
  end
  Assert.equal(effectCommands, 2, "two distinct effects leave exactly two worker requests")
  service:shutdown()
end

function T.cancelled_generations_never_publish_into_later_ones()
  local Service = cacheService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local first = assert(service:select({ versionId = "heartgold", development = true }))
  local firstOk, firstId = pcall(service.request, service, first, {
    requestKind = "battle-effect",
    effectKey = "synthetic-probe",
    urgency = "required",
  })
  Assert.isTrue(firstOk and type(firstId) == "number", "the first generation stages its effect")
  service:update()
  service:retire(first)
  local second = assert(service:select({ versionId = "heartgold", development = true }))
  Assert.isTrue(second ~= first, "staging moves to a fresh generation after cancellation")
  local freshOk, _ = pcall(service.request, service, second, {
    requestKind = "battle-effect",
    effectKey = "synthetic-probe",
    urgency = "required",
  })
  Assert.isTrue(freshOk, "the new generation may restage the same effect")
  service:injectReply({ op = "request-result", epoch = first, requestId = firstId, state = "ready" })
  service:update()
  local ready, failure = service:observe(second, { requestKind = "battle-effect", effectKey = "synthetic-probe" })
  Assert.isNil(ready, "a late publication from the cancelled generation never lands in the new one")
  Assert.isNil(failure, "a late publication reports no new-generation failure")
  local Provisioner = provisionerModule()
  local provisioner = Provisioner.new({ versionId = "heartgold", service = service })
  local gameHost = provisioner:gameHost()
  Assert.isTrue(type(gameHost.requestBattleEffect) == "function", "the selected-game host demands lazy battle effects")
  provisioner:dispose()
  service:shutdown()
end

function T.effect_host_keys_validate_and_never_alias_scenes()
  local Service = cacheService()
  local Provisioner = provisionerModule()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local provisioner = Provisioner.new({ versionId = "heartgold", service = service })
  local gameHost = provisioner:gameHost()
  Assert.isTrue(
    type(gameHost.requestBattleEffect) == "function",
    "the selected-game host demands lazy battle effects beside scenes"
  )
  local pending, pendingErr = gameHost.requestBattleEffect("synthetic-probe", "near")
  Assert.isNil(pending, "an unstaged effect observes no readiness")
  Assert.isNil(pendingErr, "an unstaged effect observes no failure")
  local promoted, promotedErr = gameHost.requestBattleEffect("synthetic-probe", "required")
  Assert.isNil(promoted, "a promoted effect still observes no readiness")
  Assert.isNil(promotedErr, "a promoted effect still observes no failure")
  service:update()
  local effectCommands, sceneCommands = 0, 0
  local command = service._command:pop()
  while command ~= nil do
    if command.op == "request" then
      if command.requestKind == "battle-effect" then
        effectCommands = effectCommands + 1
      elseif command.requestKind == "battle-scene" then
        sceneCommands = sceneCommands + 1
      end
    end
    command = service._command:pop()
  end
  Assert.equal(effectCommands, 1, "repeated effect demands share one worker request")
  Assert.equal(sceneCommands, 0, "effect demands never alias scene jobs")
  for _, badKey in ipairs({ "", "has/slash", 7 }) do
    local ok, _ = pcall(function()
      gameHost.requestBattleEffect(badKey, "required")
    end)
    Assert.isFalse(ok, "a malformed effect key never leaves the game thread: " .. tostring(badKey))
  end
  provisioner:dispose()
  service:shutdown()
end

-- The work every battle shares (the global presentation catalog with its
-- music and voice banks) is one selector-free demand: repeated host calls
-- coalesce into one controller request carrying urgency alone, a stray
-- selector never rides it, and the controller dispatches the single
-- registered global job.
function T.shared_battle_presentation_demand_is_selector_free_and_global()
  local Service = cacheService()
  local Provisioner = provisionerModule()
  local service = assert(Service.new({ thread = newChannelHost() }))
  local provisioner = Provisioner.new({ versionId = "heartgold", service = service })
  local gameHost = provisioner:gameHost()
  local pending, pendingErr = gameHost.requestBattlePresentation("near")
  Assert.isNil(pending, "the unstaged catalog observes no readiness")
  Assert.isNil(pendingErr, "the unstaged catalog observes no failure")
  gameHost.requestBattlePresentation("near")
  service:update()
  local commands = {}
  local command = service._command:pop()
  while command ~= nil do
    if command.op == "request" then
      commands[#commands + 1] = command
    end
    command = service._command:pop()
  end
  Assert.equal(#commands, 1, "repeated shared demands coalesce into one worker request")
  Assert.equal(commands[1].requestKind, "battle-presentation", "the demand names the shared battle catalog")
  Assert.equal(commands[1].urgency, "near", "the demand carries its urgency")
  Assert.isNil(commands[1].sceneKey, "the shared demand carries no scene selector")
  Assert.isNil(commands[1].effectKey, "the shared demand carries no effect selector")
  local strayOk = pcall(service.request, service, provisioner.epoch, {
    requestKind = "battle-presentation",
    urgency = "near",
    sceneKey = "general/grass/day",
  })
  Assert.isFalse(strayOk, "a scene selector never rides the shared battle demand")
  provisioner:dispose()
  service:shutdown()

  local Worker = require("romdump.src.build.CacheControllerWorker").Worker
  local worker = Worker.new({
    pop = function()
      return nil
    end,
  }, { push = function() end })
  local calls = {}
  worker.session = {
    requestJob = function(_, kind, key, urgency)
      calls[#calls + 1] = kind .. ":" .. key .. "@" .. urgency
      return false, nil
    end,
  }
  worker:_invoke({ requestKind = "battle-presentation", urgency = "near" })
  Assert.deepEqual(calls, { "battle-presentation:global@near" }, "the controller dispatches the global job")
end

return { tests = T }
