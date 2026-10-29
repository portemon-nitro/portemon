local Assert = require("tests.support.Assert")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")
local MoveIconCache = require("libs.assets.src.MoveIconCache")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local function graphicsManifest()
  local function art(path)
    return { image = path }
  end
  local function menu(path)
    return { image = path, screens = { { image = path } } }
  end
  local path = "assets/generated/battle/synthetic.png"
  return {
    verified = true,
    pictures = { shadow = art(path) },
    hud = {
      player = art(path),
      enemy = art(path),
      doubles = {
        playerLeft = art(path),
        playerRight = art(path),
        enemyLeft = art(path),
        enemyRight = art(path),
      },
      cursor = art(path),
      arrow = art(path),
      partyGauges = { art(path), art(path) },
    },
    menus = {
      command = menu(path),
      moves = menu(path),
      target = menu(path),
      twoOption = menu(path),
      lower = { pulseMask = path },
    },
    messages = {
      roles = {
        narration = { font = "fonts/narration" },
        menu = { font = "fonts/menu" },
        hud = { font = "fonts/hud" },
      },
    },
    audioRoles = { wild = "wild", trainer = "trainer", rival = "rival", select = "select" },
  }
end

local function sceneRecord(sceneKey)
  local introPath = BattlePresentationCache.sceneIntroImagePath(sceneKey)
  local playerPath = BattlePresentationCache.sceneTerrainSpritePath(sceneKey, "player")
  local foePath = BattlePresentationCache.sceneTerrainSpritePath(sceneKey, "foe")
  local charsPath = BattlePresentationCache.sceneCharactersPath(sceneKey)
  local mapPath = BattlePresentationCache.sceneMapPath(sceneKey)
  local palettePath = BattlePresentationCache.scenePalettePath(sceneKey)
  local axes = assert(BattlePresentationCache.parseSceneKey(sceneKey), "the synthetic scene key stays valid")
  return {
    schema = BattlePresentationCache.SCENE_SCHEMA,
    key = sceneKey,
    background = axes.background,
    terrain = axes.terrain,
    time = axes.time,
    canvasWidth = 512,
    canvasHeight = 256,
    viewport = { x = 0, y = 0, width = 256, height = 192 },
    layers = {
      {
        key = "background",
        backing = { width = 512, height = 256, mapWidth = 64, mapHeight = 32 },
        viewport = { x = 0, y = 0, width = 256, height = 192 },
        scroll = { x = 0, y = 0 },
        characters = {
          key = "battle-scene/general-plain-day/background/characters",
          path = charsPath,
          format = "indexed8",
        },
        map = {
          key = "battle-scene/general-plain-day/background/map",
          path = mapPath,
          format = "tilemap",
        },
        palette = {
          key = "battle-scene/general-plain-day/background/palette",
          path = palettePath,
          format = "rgb888",
        },
      },
    },
    imagePath = BattlePresentationCache.sceneImagePath(sceneKey),
    introLayer = { image = introPath, width = 512, height = 256 },
    terrainSprites = {
      player = { image = playerPath, width = 48, height = 24, origin = { x = 24, y = 12 } },
      foe = { image = foePath, width = 40, height = 20, origin = { x = 20, y = 10 } },
    },
  }
end

local SCENE_KEY = "general/plain/day"

local function stagedCacheFs(record)
  local mapEntries = {}
  for index = 1, 2048 do
    mapEntries[index] = { tile = 0, flipH = false, flipV = false, palette = 0 }
  end
  local paletteColors = {}
  for index = 1, 256 do
    paletteColors[index] = { r = 0, g = 0, b = 0 }
  end
  local cacheFs = { versionId = "synthetic" }
  function cacheFs:loadLua(path)
    if path == BattlePresentationCache.scenePath(SCENE_KEY) then
      return record
    end
    if path == BattlePresentationCache.sceneMapPath(SCENE_KEY) then
      return { width = 512, height = 256, entries = mapEntries }
    end
    if path == BattlePresentationCache.scenePalettePath(SCENE_KEY) then
      return { colors = paletteColors }
    end
    if path == MoveIconCache.manifestPath() then
      return { schema = MoveIconCache.SCHEMA, types = {}, categories = {} }
    end
    return nil
  end
  function cacheFs:read(path)
    if path == record.layers[1].characters.path then
      return string.rep("c", 65536)
    end
    return "staged"
  end
  function cacheFs:exists(_, _)
    return true
  end
  return cacheFs
end

-- Pool whose images become ready after `pendingPolls` polls, except the
-- paths in `failures`; it ledgers every lease it hands out and takes back.
local function ledgerPool(pendingPolls, failures)
  local pool = { acquired = {}, released = {}, polls = {} }
  function pool:request(path)
    return path
  end
  function pool:poll(token)
    self.polls[token] = (self.polls[token] or 0) + 1
    if failures[token] ~= nil then
      return "failed", failures[token]
    end
    if self.polls[token] <= pendingPolls then
      return "pending"
    end
    return "ready", token
  end
  function pool:acquire(token)
    local lease = { image = { path = token } }
    self.acquired[#self.acquired + 1] = lease
    return lease
  end
  function pool:release(lease)
    self.released[#self.released + 1] = lease
  end
  return pool
end

local function newEnvelope(cacheFs, imagePool)
  local envelope = FieldBattlePresentation.new({
    cacheFs = cacheFs,
    windows = { drawWindow = function() end, drawApplicationFrame = function() end },
    text = {
      measure = function()
        return { width = 0, height = 0 }
      end,
      drawText = function() end,
    },
    measureDisplay = function()
      return {
        width = 256,
        height = 384,
        topology = ScreenTopology.dualDisplay(
          { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
          { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
        ),
        pixelRatio = 1,
        signature = "scene-assets",
      }
    end,
    graphics = {},
    imagePool = imagePool,
  })
  envelope._manifest = graphicsManifest()
  return envelope
end

local function prepareScene(services)
  return services.prepare({
    launchId = "scene-assets",
    scenes = { SCENE_KEY },
    pages = {},
    trainerPictures = {},
    battleBalls = {},
    iconKeys = {},
    audio = { roles = {}, banks = {}, cries = {} },
  })
end

local function leasePaths(leases)
  local paths = {}
  for index, lease in ipairs(leases) do
    paths[index] = lease.image.path
  end
  table.sort(paths)
  return paths
end

function T.preparation_retains_intro_and_terrain_drawables_with_source_metadata()
  local record = sceneRecord(SCENE_KEY)
  local pool = ledgerPool(2, {})
  local envelope = newEnvelope(stagedCacheFs(record), pool)
  local services = envelope:_preparationServices()
  local ready, failure = prepareScene(services)
  Assert.isTrue(ready, "the staged scene and its intro assets prepare: " .. tostring(failure))
  local layer = assert(services.sceneLayer(), "the prepared scene layer is retained")
  Assert.equal(#pool.acquired, 3, "the intro and both terrain images are leased from the shared pool")
  Assert.isTrue(layer.introLayer.drawable ~= nil, "the unbaked intro layer carries its pooled drawable")
  Assert.equal(layer.introLayer.width, record.introLayer.width, "the intro canvas size is retained")
  Assert.equal(layer.introLayer.height, record.introLayer.height, "the intro canvas size is retained")
  for _, side in ipairs({ "player", "foe" }) do
    local sprite = layer.terrainSprites[side]
    local source = record.terrainSprites[side]
    Assert.isTrue(sprite.drawable ~= nil, side .. " OBJ carries its pooled drawable")
    Assert.deepEqual(
      { sprite.width, sprite.height, sprite.origin.x, sprite.origin.y },
      { source.width, source.height, source.origin.x, source.origin.y },
      side .. " OBJ keeps its source size and origin"
    )
  end
  envelope:dispose()
  Assert.deepEqual(
    leasePaths(pool.released),
    leasePaths(pool.acquired),
    "disposal returns each retained lease exactly once"
  )
end

function T.failed_terrain_upload_returns_the_leases_it_already_holds()
  local record = sceneRecord(SCENE_KEY)
  local pool = ledgerPool(0, { [record.terrainSprites.foe.image] = "probe-foe-upload-failed" })
  local envelope = newEnvelope(stagedCacheFs(record), pool)
  local ready, failure = prepareScene(envelope:_preparationServices())
  Assert.isNil(ready, "a failed foe terrain upload never prepares the scene")
  Assert.isTrue(
    type(failure) == "string" and failure:find("probe-foe-upload-failed", 1, true) ~= nil,
    "the failed upload preserves its pool cause"
  )
  Assert.isTrue(#pool.acquired > 0, "the other images were leased before the failure")
  Assert.deepEqual(
    leasePaths(pool.released),
    leasePaths(pool.acquired),
    "every lease taken before the failure is returned"
  )
  local releasedBefore = #pool.released
  envelope:dispose()
  Assert.equal(#pool.released, releasedBefore, "disposal does not release rolled-back leases twice")
end

local SCENE_B_KEY = "general/grass/day"

-- Counts native cache reads per path while serving two distinct valid
-- scene records: warmed BG3 bytes must not be reread by the later
-- foreground demand, and each scene keeps its own byte identity.
local function dualSceneCacheFs(recordA, recordB)
  local reads = {}
  local cacheFs = { versionId = "synthetic" }
  local records = { [recordA.key] = recordA, [recordB.key] = recordB }
  function cacheFs:loadLua(path)
    for _, record in pairs(records) do
      if path == BattlePresentationCache.scenePath(record.key) then
        return record
      end
      if path == BattlePresentationCache.sceneMapPath(record.key) then
        local entries = {}
        for index = 1, 2048 do
          entries[index] = { tile = 0, flipH = false, flipV = false, palette = 0 }
        end
        return { width = 512, height = 256, entries = entries }
      end
      if path == BattlePresentationCache.scenePalettePath(record.key) then
        local colors = {}
        for index = 1, 256 do
          colors[index] = { r = 0, g = 0, b = 0 }
        end
        return { colors = colors }
      end
    end
    if path == MoveIconCache.manifestPath() then
      return { schema = MoveIconCache.SCHEMA, types = {}, categories = {} }
    end
    return nil
  end
  function cacheFs:read(path)
    reads[path] = (reads[path] or 0) + 1
    return "bytes:" .. path
  end
  function cacheFs:exists(_, _)
    return true
  end
  cacheFs.reads = reads
  return cacheFs
end

-- A pool double with explicit readiness control: requests enroll at the
-- caller-chosen priority, polls stay pending until the path is marked
-- ready or the poll budget lapses, and every token is either acquired
-- or cancelled exactly once while every lease is released exactly once.
local function scriptedPool(pendingPolls, failures)
  local pool = {
    requested = {},
    polls = {},
    acquired = {},
    released = {},
    cancelled = {},
    readyPaths = {},
    nextToken = 0,
    pendingPolls = pendingPolls or 0,
    failures = failures or {},
  }
  function pool:request(path, _, priority)
    self.nextToken = self.nextToken + 1
    local token = self.nextToken
    self.requested[#self.requested + 1] = { token = token, path = path, priority = priority }
    return token
  end
  function pool:poll(token)
    local ticket = nil
    for _, entry in ipairs(self.requested) do
      if entry.token == token then
        ticket = entry
        break
      end
    end
    assert(ticket ~= nil, "unknown image request token")
    self.polls[token] = (self.polls[token] or 0) + 1
    if self.failures[ticket.path] ~= nil then
      return "failed", self.failures[ticket.path]
    end
    if self.readyPaths[ticket.path] == true or self.polls[token] > self.pendingPolls then
      return "ready", token
    end
    return "pending"
  end
  function pool:acquire(token)
    for _, entry in ipairs(self.requested) do
      if entry.token == token then
        local lease = { image = { path = entry.path } }
        self.acquired[#self.acquired + 1] = { token = token, path = entry.path, lease = lease }
        return lease
      end
    end
    error("unknown image request token", 0)
  end
  function pool:cancel(token)
    self.cancelled[#self.cancelled + 1] = token
  end
  function pool:release(lease)
    self.released[#self.released + 1] = lease
  end
  return pool
end

local function nearHost(asks, ready)
  return {
    requestBattlePresentation = function(urgency)
      asks[#asks + 1] = { kind = "presentation", urgency = urgency }
      if ready == true then
        return true
      end
      return nil
    end,
    requestBattleScene = function(sceneKey, urgency)
      asks[#asks + 1] = { kind = "scene", sceneKey = sceneKey, urgency = urgency }
      if ready == true then
        return true
      end
      return nil
    end,
  }
end

local function warmEnvelope(cacheFs, pool, host)
  local envelope = FieldBattlePresentation.new({
    cacheFs = cacheFs,
    windows = { drawWindow = function() end, drawApplicationFrame = function() end },
    text = {
      measure = function()
        return { width = 0, height = 0 }
      end,
      drawText = function() end,
    },
    measureDisplay = function()
      return {
        width = 256,
        height = 384,
        topology = ScreenTopology.dualDisplay(
          { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
          { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
        ),
        pixelRatio = 1,
        signature = "scene-warmup",
      }
    end,
    graphics = {},
    imagePool = pool,
    derivedAssets = host,
  })
  envelope._manifest = graphicsManifest()
  return envelope
end

-- Drives idle warmup rounds until the envelope settles or the round
-- budget lapses, counting GPU-pair admissions spent.
local function driveWarmup(envelope, sceneKey, allowance, rounds)
  local spent = 0
  for _ = 1, rounds or 64 do
    local used, failure = envelope:advanceWarmup(sceneKey, allowance)
    Assert.isNil(failure, "idle warmup records no failure for a staged scene: " .. tostring(failure))
    if used == true then
      spent = spent + 1
    else
      break
    end
  end
  return spent
end

local function requestedPaths(pool)
  local paths = {}
  for _, entry in ipairs(pool.requested) do
    paths[#paths + 1] = entry.path
  end
  return paths
end

local function acquiredPaths(pool)
  local paths = {}
  for _, entry in ipairs(pool.acquired) do
    paths[#paths + 1] = entry.path
  end
  return paths
end

-- The first battle following settled idle reuses the warmed
-- scene and fixed art without duplicate native reads or GPU
-- construction at entry; dynamic foe/effect demand still works.
function T.idle_warmup_adopts_scene_group_and_fixed_art_before_first_launch()
  local record = sceneRecord(SCENE_KEY)
  local probe = warmEnvelope(stagedCacheFs(record), scriptedPool(0, {}), nearHost({}, true))
  Assert.isTrue(
    type(probe.advanceWarmup) == "function",
    "the battle envelope prewarms the predicted scene during idle field updates"
  )
  probe:dispose()
  local cacheFs = dualSceneCacheFs(record, sceneRecord(SCENE_B_KEY))
  local pool = scriptedPool(0, {})
  local asks = {}
  local envelope = warmEnvelope(cacheFs, pool, nearHost(asks, true))
  local spent = driveWarmup(envelope, SCENE_KEY, 1, 64)
  Assert.isTrue(spent >= 1, "idle rounds adopt at least one warmed image pair")
  for _, ask in ipairs(asks) do
    Assert.equal(ask.urgency, "near", "speculative semantic demand never outranks the foreground")
  end
  for _, entry in ipairs(pool.requested) do
    Assert.equal(entry.priority, "prefetch", "speculative image tickets stay below foreground demand")
  end
  local services = envelope:_preparationServices()
  local warmedScene = services.drawable("scene:" .. SCENE_KEY)
  Assert.notNil(warmedScene, "the warmed scene image answers through the canonical drawable")
  local requestedBefore = #pool.requested
  local acquiredBefore = #pool.acquired
  local sceneReadsBefore = cacheFs.reads[record.layers[1].characters.path] or 0
  local ready, failure = prepareScene(services)
  Assert.isTrue(ready, "the warmed scene prepares for its matching launch: " .. tostring(failure))
  Assert.equal(
    #pool.requested,
    requestedBefore,
    "the matching launch enrolls no new image tickets for warmed art"
  )
  Assert.equal(
    #pool.acquired,
    acquiredBefore,
    "the matching launch constructs no new GPU images for warmed art"
  )
  Assert.equal(
    cacheFs.reads[record.layers[1].characters.path] or 0,
    sceneReadsBefore,
    "the matching launch rereads no staged BG3 bytes for the warmed scene"
  )
  local layer = assert(services.sceneLayer(), "the prepared scene layer is retained")
  Assert.isTrue(layer.introLayer.drawable ~= nil, "the warmed intro layer carries its drawable")
  local foeReady, foeFailure = services.prepare({
    launchId = "warm-foe-still-demandable",
    scenes = { SCENE_KEY },
    pages = {},
    trainerPictures = { "UNKNOWN_TRAINER_FOR_WARM_PROBE" },
    battleBalls = {},
    iconKeys = {},
    audio = { roles = {}, banks = {}, cries = {} },
  })
  Assert.isNil(foeReady, "unknown foe art never reads as warm-ready")
  Assert.isTrue(
    type(foeFailure) == "string" and foeFailure ~= "",
    "the unstaged foe demand still carries its cause"
  )
  envelope:dispose()
end

-- One predicted scene group stays live under the shared
-- admission; stale tickets never publish into a newer prediction.
function T.warmup_keeps_one_scene_group_and_never_publishes_stale_tickets()
  local recordA = sceneRecord(SCENE_KEY)
  local recordB = sceneRecord(SCENE_B_KEY)
  local cacheFs = dualSceneCacheFs(recordA, recordB)
  local pool = scriptedPool(1000000, {})
  local asks = {}
  local envelope = warmEnvelope(cacheFs, pool, nearHost(asks, true))
  Assert.isTrue(
    type(envelope.advanceWarmup) == "function",
    "the battle envelope prewarms exactly one predicted scene group"
  )
  for _ = 1, 4 do
    local used, failure = envelope:advanceWarmup(SCENE_KEY, 0)
    Assert.isNil(failure, "pending warmup records no failure: " .. tostring(failure))
    Assert.isFalse(used == true, "a zero allowance enrolls without realizing any image pair")
  end
  local pendingA = #pool.requested
  Assert.isTrue(pendingA > 0, "the first prediction enrolls its scene tickets")
  for _, entry in ipairs(pool.requested) do
    Assert.equal(entry.priority, "prefetch", "speculative scene tickets stay below foreground demand")
  end
  for _ = 1, 4 do
    local used, failure = envelope:advanceWarmup(SCENE_B_KEY, 0)
    Assert.isNil(failure, "replacement warmup records no failure: " .. tostring(failure))
    Assert.isFalse(used == true, "a zero allowance enrolls without realizing any image pair")
  end
  local cancelled = {}
  for _, token in ipairs(pool.cancelled) do
    cancelled[token] = true
  end
  local staleOpen = 0
  for index = 1, pendingA do
    if cancelled[pool.requested[index].token] ~= true then
      staleOpen = staleOpen + 1
    end
  end
  Assert.equal(staleOpen, 0, "abandoned prediction tickets are all cancelled")
  pool.readyPaths[recordB.imagePath] = true
  pool.readyPaths[recordB.introLayer.image] = true
  pool.readyPaths[recordB.terrainSprites.player.image] = true
  pool.readyPaths[recordB.terrainSprites.foe.image] = true
  local spent = 0
  for _ = 1, 8 do
    local acquiredBefore = #pool.acquired
    local used, failure = envelope:advanceWarmup(SCENE_B_KEY, 1)
    Assert.isNil(failure, "ready warmup records no failure: " .. tostring(failure))
    if used == true then
      spent = spent + 1
      Assert.isTrue(
        #pool.acquired - acquiredBefore <= 1,
        "one idle update realizes at most one image pair"
      )
    else
      break
    end
  end
  Assert.isTrue(spent >= 1, "ready scene tickets are adopted under the shared admission")
  -- The replaced scene probes while its art is still unready: the
  -- demand-time borrow finds nothing staged-readable yet, while the
  -- live group answers through its warmed pin.
  local services = envelope:_preparationServices()
  Assert.isNil(
    services.drawable("scene:" .. SCENE_KEY),
    "the replaced scene keeps no drawable behind the live group"
  )
  Assert.notNil(
    services.drawable("scene:" .. SCENE_B_KEY),
    "the current prediction keeps its warmed scene drawable"
  )
  pool.readyPaths[recordA.imagePath] = true
  pool.readyPaths[recordA.introLayer.image] = true
  pool.readyPaths[recordA.terrainSprites.player.image] = true
  pool.readyPaths[recordA.terrainSprites.foe.image] = true
  local acquiredBefore = #pool.acquired
  for _ = 1, 4 do
    local _, failure = envelope:advanceWarmup(SCENE_B_KEY, 1)
    Assert.isNil(failure, "late stale completion records no failure: " .. tostring(failure))
  end
  for index = acquiredBefore + 1, #pool.acquired do
    local path = pool.acquired[index].path
    Assert.isTrue(
      path ~= recordA.imagePath
        and path ~= recordA.introLayer.image
        and path ~= recordA.terrainSprites.player.image
        and path ~= recordA.terrainSprites.foe.image,
      "a late abandoned-ticket result never publishes the old scene: " .. tostring(path)
    )
  end
  envelope:dispose()
end

-- The actual launch scene always wins; a corrupt speculative
-- attempt never blocks a valid actual launch, and required failures
-- still surface with their exact key and path.
function T.actual_scene_wins_over_predicted_warm_group()
  local recordA = sceneRecord(SCENE_KEY)
  local recordB = sceneRecord(SCENE_B_KEY)
  -- The distinguishing marker lives in a valid-range terrain sprite
  -- width: the intro canvas must preserve its native dimensions.
  recordB.terrainSprites.player.width = 111
  local cacheFs = dualSceneCacheFs(recordA, recordB)
  local pool = scriptedPool(0, {})
  local envelope = warmEnvelope(cacheFs, pool, nearHost({}, true))
  Assert.isTrue(
    type(envelope.advanceWarmup) == "function",
    "the battle envelope stages its predicted scene BG3 source data during idle"
  )
  driveWarmup(envelope, SCENE_KEY, 1, 64)
  local services = envelope:_preparationServices()
  local demandB = {
    launchId = "actual-scene-wins",
    scenes = { SCENE_B_KEY },
    pages = {},
    trainerPictures = {},
    battleBalls = {},
    iconKeys = {},
    audio = { roles = {}, banks = {}, cries = {} },
  }
  local ready, failure = services.prepare(demandB)
  Assert.isTrue(ready, "the actual scene prepares despite the warmed prediction: " .. tostring(failure))
  local layer = assert(services.sceneLayer(), "the prepared scene layer is retained")
  Assert.equal(
    layer.terrainSprites.player.width,
    recordB.terrainSprites.player.width,
    "the committed layer carries the actual scene art, not the prediction"
  )
  Assert.equal(
    layer.characters,
    "bytes:" .. recordB.layers[1].characters.path,
    "the committed BG3 bytes belong to the actual scene"
  )
  local corruptPool = scriptedPool(0, { [recordA.imagePath] = "probe-warm-corrupt" })
  local corruptEnvelope = warmEnvelope(dualSceneCacheFs(recordA, recordB), corruptPool, nearHost({}, true))
  local _, warmFailure = corruptEnvelope:advanceWarmup(SCENE_KEY, 1)
  Assert.isTrue(
    type(warmFailure) == "string"
      and warmFailure:find(SCENE_KEY, 1, true) ~= nil
      and warmFailure:find(recordA.imagePath, 1, true) ~= nil,
    "a corrupt speculative image names its scene key and path: " .. tostring(warmFailure)
  )
  local validPool = scriptedPool(0, {})
  local validEnvelope = warmEnvelope(dualSceneCacheFs(recordA, recordB), validPool, nearHost({}, true))
  local validServices = validEnvelope:_preparationServices()
  local validReady, validFailure = validServices.prepare(demandB)
  Assert.isTrue(validReady, "a valid actual scene still prepares: " .. tostring(validFailure))
  corruptEnvelope:dispose()
  validEnvelope:dispose()
  envelope:dispose()
end

-- Speculative cancellation, launch admission and teardown
-- never double-release a pooled resource or mutate an active port:
-- every ticket is cancelled or consumed once, warm-only leases return
-- once, launch-held resources survive speculation, and a late stale
-- result publishes nothing.
function T.speculative_cancellation_and_dispose_keep_foreground_leases_exactly_once()
  local recordA = sceneRecord(SCENE_KEY)
  local recordB = sceneRecord(SCENE_B_KEY)
  local cacheFs = dualSceneCacheFs(recordA, recordB)
  local pool = scriptedPool(1000000, {})
  local envelope = warmEnvelope(cacheFs, pool, nearHost({}, true))
  Assert.isTrue(
    type(envelope.advanceWarmup) == "function",
    "the battle envelope owns an independent speculative warmup lease lifecycle"
  )
  for _ = 1, 3 do
    local used, failure = envelope:advanceWarmup(SCENE_KEY, 0)
    Assert.isNil(failure, "pending warmup records no failure: " .. tostring(failure))
    Assert.isFalse(used == true, "a zero allowance realizes nothing")
  end
  local staleTokens = {}
  for _, entry in ipairs(pool.requested) do
    staleTokens[#staleTokens + 1] = entry.token
  end
  Assert.isTrue(#staleTokens > 0, "the first prediction enrolls speculative tickets")
  pool.readyPaths[recordB.imagePath] = true
  pool.readyPaths[recordB.introLayer.image] = true
  pool.readyPaths[recordB.terrainSprites.player.image] = true
  pool.readyPaths[recordB.terrainSprites.foe.image] = true
  driveWarmup(envelope, SCENE_B_KEY, 1, 64)
  local cancelled = {}
  for _, token in ipairs(pool.cancelled) do
    Assert.isNil(cancelled[token], "no speculative ticket is cancelled twice")
    cancelled[token] = true
  end
  for _, token in ipairs(staleTokens) do
    Assert.isTrue(cancelled[token] == true, "every abandoned ticket is cancelled exactly once")
  end
  -- The launch demand needs pool readiness by design: the blocking
  -- demand borrow behind it can only succeed once the worker attests
  -- the actual scene art.
  pool.readyPaths[recordA.imagePath] = true
  pool.readyPaths[recordA.introLayer.image] = true
  pool.readyPaths[recordA.terrainSprites.player.image] = true
  pool.readyPaths[recordA.terrainSprites.foe.image] = true
  local services = envelope:_preparationServices()
  local launchReady, launchFailure = services.prepare({
    launchId = "launch-survives-speculation",
    scenes = { SCENE_KEY },
    pages = {},
    trainerPictures = {},
    battleBalls = {},
    iconKeys = {},
    audio = { roles = {}, banks = {}, cries = {} },
  })
  Assert.isTrue(launchReady, "launch demand survives speculative cancellation: " .. tostring(launchFailure))
  local acquiredBefore = #pool.acquired
  for _ = 1, 4 do
    local _, failure = envelope:advanceWarmup(SCENE_B_KEY, 1)
    Assert.isNil(failure, "late stale completion records no failure: " .. tostring(failure))
  end
  Assert.equal(
    #pool.acquired,
    acquiredBefore,
    "a late stale result adopts no images behind the live scene"
  )
  local seen = {}
  for _, entry in ipairs(pool.acquired) do
    seen[entry.lease] = (seen[entry.lease] or 0) + 1
  end
  envelope:dispose()
  local releasedCount = {}
  for _, lease in ipairs(pool.released) do
    releasedCount[lease] = (releasedCount[lease] or 0) + 1
  end
  for lease, count in pairs(seen) do
    Assert.equal(
      releasedCount[lease] or 0,
      count,
      "every acquired lease is released exactly as often as it was adopted"
    )
  end
  for _, token in ipairs(pool.cancelled) do
    local consumptions = 0
    for _, entry in ipairs(pool.acquired) do
      if entry.token == token then
        consumptions = consumptions + 1
      end
    end
    Assert.isTrue(
      consumptions == 0,
      "a cancelled ticket is never consumed afterwards"
    )
  end
end

-- Cold/warm evidence through truthful boundaries -- native
-- read counts, decode/GPU construction counts and queue payloads --
-- without mistaking software-renderer timings for native approval.
function T.cold_and_warm_launches_share_handles_without_repeat_reads_or_uploads()
  local record = sceneRecord(SCENE_KEY)
  local coldFs = dualSceneCacheFs(record, sceneRecord(SCENE_B_KEY))
  local coldPool = scriptedPool(0, {})
  local coldEnvelope = warmEnvelope(coldFs, coldPool, nearHost({}, true))
  Assert.isTrue(
    type(coldEnvelope.advanceWarmup) == "function",
    "the battle envelope exposes idle warmup for cold/warm comparison"
  )
  local coldReady, coldFailure = prepareScene(coldEnvelope:_preparationServices())
  Assert.isTrue(coldReady, "the cold scene prepares: " .. tostring(coldFailure))
  local coldReads = coldFs.reads[record.layers[1].characters.path] or 0
  local coldAcquires = #coldPool.acquired
  Assert.isTrue(coldReads >= 1, "the cold launch reads its staged BG3 bytes")
  Assert.isTrue(coldAcquires >= 3, "the cold launch constructs its intro and terrain images")
  coldEnvelope:dispose()
  local warmFs = dualSceneCacheFs(record, sceneRecord(SCENE_B_KEY))
  local warmPool = scriptedPool(0, {})
  local warmEnvelope = warmEnvelope(warmFs, warmPool, nearHost({}, true))
  driveWarmup(warmEnvelope, SCENE_KEY, 1, 64)
  local warmServices = warmEnvelope:_preparationServices()
  local warmedScene = warmServices.drawable("scene:" .. SCENE_KEY)
  Assert.notNil(warmedScene, "warmup leaves the scene handle behind for the launch")
  local readsBefore = warmFs.reads[record.layers[1].characters.path] or 0
  local requestsBefore = #warmPool.requested
  local acquiresBefore = #warmPool.acquired
  local warmReady, warmFailure = prepareScene(warmServices)
  Assert.isTrue(warmReady, "the warmed scene prepares: " .. tostring(warmFailure))
  Assert.equal(
    warmFs.reads[record.layers[1].characters.path] or 0,
    readsBefore,
    "the warmed launch rereads no staged BG3 bytes"
  )
  Assert.equal(
    #warmPool.requested,
    requestsBefore,
    "the warmed launch enrolls no new image tickets for warmed art"
  )
  Assert.equal(
    #warmPool.acquired,
    acquiresBefore,
    "the warmed launch constructs no new GPU images for warmed art"
  )
  Assert.isTrue(
    warmServices.drawable("scene:" .. SCENE_KEY) == warmedScene,
    "the launch reuses the warmed scene handle itself"
  )
  warmEnvelope:dispose()
end

-- Launch-path pinning keeps one complete scene group: warming A then
-- cold-launching B retires A's whole 4-key group exactly once (no split
-- pin set), and warming A then idle-warming B to completion leaves a
-- single surviving group.
function T.launch_and_idle_replacement_keep_a_single_scene_group()
  local recordA = sceneRecord(SCENE_KEY)
  local recordB = sceneRecord(SCENE_B_KEY)
  local function groupKeys(sceneKey)
    return {
      "scene:" .. sceneKey,
      "scene-intro:" .. sceneKey,
      "scene-terrain:" .. sceneKey .. ":player",
      "scene-terrain:" .. sceneKey .. ":foe",
    }
  end
  local function pinnedSceneKeys(envelope)
    local keys = {}
    for _, key in ipairs(groupKeys(SCENE_KEY)) do
      if envelope._warmPinned[key] ~= nil then
        keys[#keys + 1] = key
      end
    end
    for _, key in ipairs(groupKeys(SCENE_B_KEY)) do
      if envelope._warmPinned[key] ~= nil then
        keys[#keys + 1] = key
      end
    end
    table.sort(keys)
    return keys
  end
  local function sorted(keys)
    local ordered = {}
    for _, key in ipairs(keys) do
      ordered[#ordered + 1] = key
    end
    table.sort(ordered)
    return ordered
  end
  local function releaseCount(pool, lease)
    local count = 0
    for _, released in ipairs(pool.released) do
      if released == lease then
        count = count + 1
      end
    end
    return count
  end
  -- Warm A, then cold-launch B: B's foreground pins complete the
  -- successor group, so A's whole group retires atomically behind it.
  do
    local cacheFs = dualSceneCacheFs(recordA, recordB)
    local pool = scriptedPool(0, {})
    local envelope = warmEnvelope(cacheFs, pool, nearHost({}, true))
    driveWarmup(envelope, SCENE_KEY, 1, 128)
    Assert.deepEqual(
      pinnedSceneKeys(envelope),
      sorted(groupKeys(SCENE_KEY)),
      "idle warmup completes scene A's group"
    )
    local priorA = {}
    for _, key in ipairs(groupKeys(SCENE_KEY)) do
      priorA[key] = envelope._warmPinned[key].lease
    end
    local services = envelope:_preparationServices()
    local ready, failure = services.prepare({
      launchId = "launch-replaces-warm-group",
      scenes = { SCENE_B_KEY },
      pages = {},
      trainerPictures = {},
      battleBalls = {},
      iconKeys = {},
      audio = { roles = {}, banks = {}, cries = {} },
    })
    Assert.isTrue(ready, "the successor scene launches behind the warmed predecessor: " .. tostring(failure))
    Assert.notNil(services.drawable("scene:" .. SCENE_B_KEY), "the successor scene image resolves")
    Assert.deepEqual(
      pinnedSceneKeys(envelope),
      sorted(groupKeys(SCENE_B_KEY)),
      "the foreground launch leaves no split pin set behind"
    )
    for _, key in ipairs(groupKeys(SCENE_KEY)) do
      Assert.equal(releaseCount(pool, priorA[key]), 1, "the retired scene returns each lease exactly once: " .. key)
    end
    for _, key in ipairs(groupKeys(SCENE_B_KEY)) do
      Assert.equal(
        releaseCount(pool, envelope._warmPinned[key].lease),
        0,
        "the surviving group keeps its leases: " .. key
      )
    end
    envelope:dispose()
  end
  -- Warm A, then idle-warm B to completion: only B's group survives.
  do
    local cacheFs = dualSceneCacheFs(recordA, recordB)
    local pool = scriptedPool(0, {})
    local envelope = warmEnvelope(cacheFs, pool, nearHost({}, true))
    driveWarmup(envelope, SCENE_KEY, 1, 128)
    local priorA = {}
    for _, key in ipairs(groupKeys(SCENE_KEY)) do
      priorA[key] = envelope._warmPinned[key].lease
    end
    driveWarmup(envelope, SCENE_B_KEY, 1, 128)
    Assert.deepEqual(
      pinnedSceneKeys(envelope),
      sorted(groupKeys(SCENE_B_KEY)),
      "idle replacement leaves a single surviving group"
    )
    for _, key in ipairs(groupKeys(SCENE_KEY)) do
      Assert.equal(releaseCount(pool, priorA[key]), 1, "idle retirement returns each lease exactly once: " .. key)
    end
    envelope:dispose()
  end
end

return { tests = T }
