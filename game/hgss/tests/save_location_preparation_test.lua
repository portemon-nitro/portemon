-- Optional saved-location preparation is metadata-only: it borrows the
-- selected semantic host, requests near-priority planning/runtime work, and
-- never creates a game, session, save normalization or first-play attestation.

local Assert = require("tests.support.Assert")
local HgssGame = require("game.hgss.src.HgssGame")
local FieldMapLoader = require("libs.hgss.src.world.FieldMapLoader")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local LuaWriter = require("libs.codec.src.LuaWriter")
local SnapshotBootFixture = require("tests.support.SnapshotBootFixture")

local T = {}

local LOCATION = { mapId = 60, fieldX = 684, fieldZ = 393 }

local function factory()
  local create = HgssGame.newSaveLocationPreparation
  Assert.equal(type(create), "function", "HgssGame must expose the saved-location preparation factory")
  return create
end

local function newChannelHost()
  local function newChannel()
    local queue = {}
    local channel = { log = {} }
    function channel:push(value)
      queue[#queue + 1] = value
      self.log[#self.log + 1] = value
      return true
    end
    function channel:pop()
      local value = table.remove(queue, 1)
      if value ~= nil then
        self.log[#self.log + 1] = value
      end
      return value
    end
    function channel:demand()
      return self:pop()
    end
    function channel:getCount()
      return #queue
    end
    return channel
  end
  local function newThread()
    local thread = { alive = true }
    function thread:start()
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

local function selectedHost()
  local CacheService = require("app.src.CacheService")
  local DerivedAssetProvisioner = require("app.src.DerivedAssetProvisioner")
  local host = newChannelHost()
  local service = CacheService.new({ thread = host })
  local provisioner = DerivedAssetProvisioner.new({ versionId = "heartgold", service = service })
  local epoch = assert(provisioner.epoch, "selection borrows a real epoch")
  local identity = SnapshotBootFixture.identity("heartgold")
  SnapshotBootFixture.install(service, {
    epoch = epoch,
    identity = identity,
    sequence = 1,
    initial = true,
    entries = {
      SnapshotBootFixture.blob(identity, MapAssetCache.worldPath(), LuaWriter.encode({ schema = "fixture-world" })),
    },
  })
  service:update()
  return service, provisioner, host
end

local function withLoaderSpy(script, fn)
  local originalNew = FieldMapLoader.new
  local record = { constructions = {}, demands = {}, releases = 0 }
  FieldMapLoader.new = function(cacheFs, world, options)
    record.constructions[#record.constructions + 1] = { cacheFs = cacheFs, world = world, options = options }
    local loader = {}
    function loader:requestLocation(mapId, fieldX, fieldZ, urgency, requestOptions)
      record.demands[#record.demands + 1] = {
        mapId = mapId,
        fieldX = fieldX,
        fieldZ = fieldZ,
        urgency = urgency,
        options = requestOptions,
      }
      if script.locationFailure ~= nil then
        return nil, script.locationFailure
      end
      return script.locationReady == true, nil
    end
    function loader:release()
      record.releases = record.releases + 1
    end
    return loader
  end
  local ok, err = xpcall(function()
    fn(record)
  end, debug.traceback)
  FieldMapLoader.new = originalNew
  if not ok then
    error(err, 0)
  end
end

function T.selected_host_requests_only_near_work_and_the_exact_global_saved_location()
  local service, provisioner = selectedHost()
  local epoch = assert(provisioner.epoch)
  local script = { locationReady = false }
  local ok, err = xpcall(function()
    withLoaderSpy(script, function(record)
      local preparation = factory()({
        versionId = "heartgold",
        entryLocation = LOCATION,
        derivedAssets = provisioner:gameHost(),
      })
      local ready, failure = preparation:poll()
      Assert.isNil(failure, "pending near work carries no failure")
      Assert.isFalse(ready == true, "saved-location preparation waits for its requests")
      Assert.equal(#record.constructions, 0, "no metadata loader exists before planning is ready")

      service:update()
      local requests = {}
      local command = service._command:pop()
      while command ~= nil do
        if command.op == "request" and command.requestKind == "milestone" then
          requests[command.name] = command
          Assert.equal(command.urgency, "near", "optional location work never outranks required movie/field work")
        end
        command = service._command:pop()
      end
      Assert.notNil(requests["field-planning"], "the job requests planning metadata")
      Assert.notNil(requests["field-runtime"], "the job requests runtime metadata")
      for _, name in ipairs({ "field-planning", "field-runtime" }) do
        service:injectReply({
          op = "request-result",
          epoch = epoch,
          requestId = requests[name].requestId,
          state = "ready",
          requiredSequence = 1,
        })
      end
      service:update()
      ready, failure = preparation:poll()
      Assert.isNil(failure, "ready milestones allow the exact location demand")
      Assert.isFalse(ready == true, "the location closure remains pending")
      Assert.equal(#record.constructions, 1, "one metadata-only loader serves the hint")
      Assert.equal(record.constructions[1].world.schema, "fixture-world", "planning reads the selected generated world")
      Assert.deepEqual(record.demands, {
        {
          mapId = 60,
          fieldX = 684,
          fieldZ = 393,
          urgency = "near",
          options = { neighborUrgency = "near" },
        },
      }, "saved global coordinates are requested once without local-to-global conversion")

      script.locationReady = true
      ready, failure = preparation:poll()
      Assert.isNil(failure)
      Assert.isTrue(ready == true, "the sticky job completes when its exact location is ready")
      preparation:dispose()
      Assert.equal(record.releases, 1, "disposal releases the metadata loader once")
    end)
  end, debug.traceback)
  provisioner:dispose()
  service:shutdown()
  if not ok then
    error(err, 0)
  end
end

function T.completion_and_failure_are_sticky_and_disposal_is_idempotent()
  local originalGameNew = HgssGame.new
  local originalNormalize = require("libs.hgss.src.save.GameSave").normalize
  local gameplayCalls, normalizeCalls = 0, 0
  HgssGame.new = function()
    gameplayCalls = gameplayCalls + 1
    error("saved-location preparation must not construct gameplay")
  end
  require("libs.hgss.src.save.GameSave").normalize = function()
    normalizeCalls = normalizeCalls + 1
    error("saved-location preparation must not normalize a save")
  end
  local ok, err = xpcall(function()
    withLoaderSpy({ locationFailure = "synthetic plot planning failure" }, function(record)
      local host = {
        getCacheFs = function()
          return {
            loadLua = function(_, path)
              Assert.equal(path, MapAssetCache.worldPath())
              return { schema = "fixture-world" }
            end,
          }
        end,
        requestMilestone = function(name, urgency)
          Assert.equal(urgency, "near")
          return name == "field-planning", nil
        end,
      }
      local preparation = factory()({ versionId = "heartgold", entryLocation = LOCATION, derivedAssets = host })
      local ready, failure = preparation:poll()
      Assert.isFalse(ready == true)
      Assert.equal(failure, "synthetic plot planning failure", "the optional cause is retained unchanged")
      local laterReady, laterFailure = preparation:poll()
      Assert.isFalse(laterReady == true, "a latched failure never becomes readiness")
      Assert.equal(laterFailure, failure, "failure is sticky across polls")
      Assert.equal(gameplayCalls, 0, "no game is constructed for a hint")
      Assert.equal(normalizeCalls, 0, "no save is normalized for a hint")
      preparation:dispose()
      preparation:dispose()
      Assert.equal(record.releases, 1, "loader release is exactly once")
      local disposedReady = preparation:poll()
      Assert.isFalse(disposedReady == true, "a disposed job never publishes readiness")
    end)
  end, debug.traceback)
  HgssGame.new = originalGameNew
  require("libs.hgss.src.save.GameSave").normalize = originalNormalize
  if not ok then
    error(err, 0)
  end
end

function T.construction_requires_a_supported_version_borrowed_host_and_valid_hint()
  local create = factory()
  local host = {
    requestMilestone = function()
      return false, nil
    end,
  }
  Assert.throws(function()
    create({ entryLocation = LOCATION, derivedAssets = host })
  end, "the selected version is required")
  Assert.throws(function()
    create({ versionId = "heartgold", entryLocation = LOCATION })
  end, "the borrowed selected host is required")
  Assert.throws(function()
    create({ versionId = "heartgold", derivedAssets = host })
  end, "a saved location is required")
  Assert.throws(function()
    create({ versionId = "heartgold", entryLocation = { mapId = -1, fieldX = 1, fieldZ = 2 }, derivedAssets = host })
  end, "map identity must be a non-negative integer")
  Assert.throws(function()
    create({ versionId = "heartgold", entryLocation = { mapId = 60, fieldX = 1.5, fieldZ = 2 }, derivedAssets = host })
  end, "saved coordinates must be finite integers")
end

return { tests = T }
