-- Selected-game lazy effect provisioning: the host exposes one lazy effect
-- operation beside scenes, follows the existing ready/pending/error
-- convention without method-self accidents, trusts warm receipts without
-- revalidating payloads, and stages transitive task closures before
-- reporting ready while unrelated effects stay lazy.

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

local function selectGame()
  local Service = require("app.src.CacheService")
  local Provisioner = require("app.src.DerivedAssetProvisioner")
  local service = assert(Service.new({ thread = newChannelHost() }))
  local provisioner = Provisioner.new({ versionId = "heartgold", service = service })
  return service, provisioner
end

function T.effect_requests_follow_the_scene_closure_convention()
  local service, provisioner = selectGame()
  local epoch = assert(provisioner.epoch, "selection borrows an epoch")
  local gameHost = provisioner:gameHost()
  Assert.isTrue(type(gameHost.requestBattleEffect) == "function", "the selected-game host demands lazy battle effects")
  local first, firstErr = gameHost.requestBattleEffect("synthetic-probe", "required")
  Assert.isNil(first, "an unstaged effect observes no readiness")
  Assert.isNil(firstErr, "an unstaged effect observes no failure")
  local id = assert(
    service._byKey[tostring(epoch) .. ":battle-effect:synthetic-probe"],
    "the effect demand registers its selector identity"
  )
  service:update()
  service:injectReply({ op = "request-result", epoch = epoch, requestId = id, state = "ready" })
  service:update()
  local ready, failure = gameHost.requestBattleEffect("synthetic-probe", "required")
  Assert.isTrue(ready, "the pushed ready event lands in the matching effect observation")
  Assert.isNil(failure, "a ready effect carries no failure")
  local accident = gameHost.requestBattleEffect
  local accidentOk, _ = pcall(function()
    return accident("synthetic-probe", "required")
  end)
  Assert.isTrue(accidentOk, "effect requests take plain keys, never a method-style self")
  local badOk, _ = pcall(function()
    gameHost.requestBattleEffect("synthetic-probe", "eventually")
  end)
  Assert.isFalse(badOk, "unknown urgencies never leave the game thread")
  provisioner:dispose()
  service:shutdown()
end

function T.effect_failures_carry_their_cause_and_keep_good_scenes_usable()
  local service, provisioner = selectGame()
  local epoch = assert(provisioner.epoch, "selection borrows an epoch")
  local gameHost = provisioner:gameHost()
  Assert.isTrue(type(gameHost.requestBattleEffect) == "function", "the selected-game host demands lazy battle effects")
  local pending, pendingErr = gameHost.requestBattleEffect("synthetic-broken", "required")
  Assert.isNil(pending, "a broken effect starts pending")
  Assert.isNil(pendingErr, "a broken effect starts without failure")
  local id = assert(
    service._byKey[tostring(epoch) .. ":battle-effect:synthetic-broken"],
    "the broken demand registers its selector identity"
  )
  service:update()
  service:injectReply({
    op = "request-result",
    epoch = epoch,
    requestId = id,
    state = "failed",
    errorMessage = "synthetic missing companion texture",
  })
  service:update()
  local ready, failure = gameHost.requestBattleEffect("synthetic-broken", "required")
  Assert.isFalse(ready, "a corrupt effect reports no readiness")
  Assert.isTrue(
    tostring(failure):find("synthetic missing companion texture", 1, true) ~= nil,
    "the corrupt effect carries its producer cause: " .. tostring(failure)
  )
  local sceneReady, sceneErr = gameHost.requestBattleScene("general/grass/day", "near")
  Assert.isNil(sceneReady, "an unrelated scene demand stays independent of the effect failure")
  Assert.isNil(sceneErr, "an unrelated scene demand carries no effect failure")
  provisioner:dispose()
  service:shutdown()
end

function T.nested_task_closure_stages_before_ready_while_unrelated_effects_stay_lazy()
  local FakeCache = require("tests.support.FakeCache")
  local CacheFs = require("libs.storage.src.CacheFs")
  local Cache = require("libs.assets.src.battle.BattlePresentationCache")
  local AnimationSchema = require("libs.assets.src.battle.BattleAnimationSchema")
  Assert.isTrue(
    type(Cache.isEffectReady) == "function",
    "effect readiness stages the closed transitive resources before reporting ready"
  )
  assert(Cache.isEffectReady ~= nil, "effect readiness is available")
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local closedDemand = {
    key = "synthetic-parent",
    resources = { "synthetic-sound", "synthetic-model", "synthetic-texture" },
  }
  Assert.isFalse(Cache.isEffectReady(cache, closedDemand), "an unstaged transitive closure never reads ready")

  local record = {
    schema = AnimationSchema.EFFECT_SCHEMA,
    key = closedDemand.key,
    catalogIdentity = "synthetic-catalog",
    program = {
      entry = "main",
      instructions = { { op = "start-visual-task", taskKind = "positioned-sound-motion", values = {} } },
      subprograms = {},
      taskKinds = { "positioned-sound-motion" },
    },
    dependencies = closedDemand.resources,
    resources = {
      ["synthetic-sound"] = {
        kind = "sound",
        contentIdentity = string.rep("a", 40),
        payload = "effects/sound.sseq",
      },
      ["synthetic-model"] = {
        kind = "model",
        contentIdentity = string.rep("b", 40),
        payload = "effects/model.nsbmd",
      },
      ["synthetic-texture"] = {
        kind = "texture",
        contentIdentity = string.rep("c", 40),
        payload = "effects/texture.ncgr",
      },
    },
    requiredContext = {},
  }
  cache:writeLua(Cache.effectPath(closedDemand.key), record)
  cache:write(Cache.effectMarkerPath(closedDemand.key), "complete")
  Assert.isFalse(
    Cache.isEffectReady(cache, closedDemand),
    "a parent receipt stays pending until every transitive task payload is staged"
  )

  for _, payload in pairs(record.resources) do
    cache:write(payload.payload, "staged " .. payload.kind)
  end
  Assert.isTrue(
    Cache.isEffectReady(cache, closedDemand),
    "the closed parent becomes ready after every transitive task payload is staged"
  )
  for _, key in ipairs(closedDemand.resources) do
    local payload = assert(record.resources[key]).payload
    cache:remove(payload)
    Assert.isFalse(
      Cache.isEffectReady(cache, closedDemand),
      "each transitive task payload is required before readiness: " .. key
    )
    cache:write(payload, "restaged " .. key)
  end
  local missingDemand = { key = closedDemand.key }
  Assert.isFalse(
    Cache.isEffectReady(cache, missingDemand),
    "the requested closure is required instead of falling back to the record"
  )
  local expandedDemand = {
    key = closedDemand.key,
    resources = { "synthetic-sound", "synthetic-model", "synthetic-texture", "synthetic-extra" },
  }
  Assert.isFalse(Cache.isEffectReady(cache, expandedDemand), "a requested closure cannot exceed the published record")
  local missingDependency = {
    schema = record.schema,
    key = record.key,
    catalogIdentity = record.catalogIdentity,
    program = record.program,
    dependencies = { "synthetic-sound", "synthetic-model" },
    resources = record.resources,
    requiredContext = record.requiredContext,
  }
  cache:writeLua(Cache.effectPath(closedDemand.key), missingDependency)
  Assert.isFalse(
    Cache.isEffectReady(cache, closedDemand),
    "the dependency list and resource map must describe the same closure"
  )
  local unrelated = { key = "synthetic-unrelated", resources = {} }
  Assert.isFalse(Cache.isEffectReady(cache, unrelated), "an unrelated effect stays lazy beside staged work")
end

-- The selected-game effect host keeps its flat-key contract and one
-- selector identity per demanded effect: non-flat keys are rejected
-- loudly instead of pending silently, and repeated demands never
-- register duplicate or sibling jobs.
function T.effect_demands_keep_flat_keys_and_single_selector_identities()
  local service, provisioner = selectGame()
  local epoch = assert(provisioner.epoch, "selection borrows an epoch")
  local gameHost = provisioner:gameHost()
  local slashedOk = pcall(function()
    return gameHost.requestBattleEffect("HAS/SLASH", "required")
  end)
  Assert.isFalse(slashedOk, "a non-flat effect key never reaches the worker queue")
  local emptyOk = pcall(function()
    return gameHost.requestBattleEffect("", "required")
  end)
  Assert.isFalse(emptyOk, "an empty effect key never reaches the worker queue")
  gameHost.requestBattleEffect("synthetic-probe", "required")
  gameHost.requestBattleEffect("synthetic-probe", "required")
  gameHost.requestBattleEffect("synthetic-other", "required")
  local selectors = {}
  for key in pairs(service._byKey) do
    if tostring(key):find(":battle-effect:", 1, true) ~= nil then
      selectors[#selectors + 1] = key
    end
  end
  table.sort(selectors)
  Assert.equal(#selectors, 2, "two demanded effects register exactly two selector identities")
  Assert.isTrue(
    selectors[1] == tostring(epoch) .. ":battle-effect:synthetic-other"
      and selectors[2] == tostring(epoch) .. ":battle-effect:synthetic-probe",
    "each selector names exactly its demanded flat key"
  )
  provisioner:dispose()
  service:shutdown()
end

return { tests = T }
