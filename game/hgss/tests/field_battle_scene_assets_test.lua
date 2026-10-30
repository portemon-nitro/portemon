local Assert = require("tests.support.Assert")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")
local MonCache = require("libs.assets.src.MonCache")
local MoveIconCache = require("libs.assets.src.MoveIconCache")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SummaryModel = require("libs.hgss.src.ui.SummaryModel")

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
local SCENE_C_KEY = "general/sand/day"

-- Counts native cache reads per path while serving distinct valid scene
-- records: warmed BG3 bytes must not be reread by the later foreground
-- demand, and each scene keeps its own byte identity. The Lua-document
-- ledger exists so a settled idle round cannot hide repeated scene or
-- manifest parses behind a quiet byte-read count.
local function dualSceneCacheFs(recordA, recordB, recordC)
  local reads = {}
  local loadLuaCounts = {}
  local cacheFs = { versionId = "synthetic" }
  local records = {}
  for _, record in ipairs({ recordA, recordB, recordC }) do
    if record ~= nil then
      records[record.key] = record
    end
  end
  function cacheFs:loadLua(path)
    loadLuaCounts[path] = (loadLuaCounts[path] or 0) + 1
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
  cacheFs.loadLuaCounts = loadLuaCounts
  return cacheFs
end

-- Totals one ledger of per-path counts.
local function totalLoads(counts)
  local total = 0
  for _, count in pairs(counts) do
    total = total + count
  end
  return total
end

-- A pool double with explicit readiness control: requests enroll at the
-- caller-chosen priority, polls stay pending until the path is marked
-- ready or the poll budget lapses, and every token is either acquired
-- or cancelled exactly once while every lease is released exactly once.
-- The live ledger mirrors the shared owner's contract: a request holds
-- pool interest until acquire consumes it or cancel retires it, so a
-- test can tell an uncleared failed request apart from a forgotten
-- owner-side ticket. Cancelling an already-consumed token lands in a
-- separate stale ledger and never counts as retiring live interest.
local function scriptedPool(pendingPolls, failures)
  local pool = {
    requested = {},
    polls = {},
    acquired = {},
    released = {},
    cancelled = {},
    cancelledStale = {},
    live = {},
    readyPaths = {},
    throwPaths = {},
    nextToken = 0,
    pendingPolls = pendingPolls or 0,
    failures = failures or {},
  }
  function pool:request(path, _, priority)
    self.nextToken = self.nextToken + 1
    local token = self.nextToken
    self.requested[#self.requested + 1] = { token = token, path = path, priority = priority }
    self.live[token] = path
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
    if self.throwPaths[ticket.path] ~= nil then
      error(self.throwPaths[ticket.path], 0)
    end
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
        self.live[token] = nil
        return lease
      end
    end
    error("unknown image request token", 0)
  end
  function pool:cancel(token)
    if self.live[token] ~= nil then
      self.live[token] = nil
      self.cancelled[#self.cancelled + 1] = token
    else
      self.cancelledStale[#self.cancelledStale + 1] = token
    end
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
-- construction at entry; dynamic foe/effect demand still works. A cold
-- launch first sets the baseline the warmed path must avoid repeating,
-- and a settled scene then idles with no further document, host, or
-- pool demand until the prediction actually changes.
function T.idle_warmup_adopts_scene_group_and_fixed_art_before_first_launch()
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
  Assert.isTrue(
    (coldFs.reads[record.layers[1].characters.path] or 0) >= 1,
    "the cold launch reads its staged BG3 bytes"
  )
  Assert.isTrue(#coldPool.acquired >= 3, "the cold launch constructs its intro and terrain images")
  coldEnvelope:dispose()
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
  -- A settled scene idles with no repeated scene/manifest document
  -- loads, no staged-byte rereads, and no new host or pool demand.
  local settledLoads = totalLoads(cacheFs.loadLuaCounts)
  local settledReads = totalLoads(cacheFs.reads)
  local settledAsks = #asks
  local settledRequests = #pool.requested
  local settledAcquires = #pool.acquired
  for _ = 1, 40 do
    local usedIdle, failureIdle = envelope:advanceWarmup(SCENE_KEY, 1)
    Assert.isFalse(usedIdle == true, "a settled scene realizes no further GPU pairs")
    Assert.isNil(failureIdle, "a settled scene reports no idle failure")
  end
  local usedZero, failureZero = envelope:advanceWarmup(SCENE_KEY, 0)
  Assert.isFalse(usedZero == true, "a settled scene with zero allowance realizes nothing")
  Assert.isNil(failureZero, "a settled scene with zero allowance reports no failure")
  Assert.equal(
    totalLoads(cacheFs.loadLuaCounts),
    settledLoads,
    "settled idle parses no further Lua documents"
  )
  Assert.equal(
    totalLoads(cacheFs.reads),
    settledReads,
    "settled idle rereads no staged bytes"
  )
  Assert.equal(#asks, settledAsks, "settled idle places no further derived demand")
  Assert.equal(#pool.requested, settledRequests, "settled idle enrolls no new image tickets")
  Assert.equal(#pool.acquired, settledAcquires, "settled idle constructs no new GPU images")
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
  -- A distinct prediction resumes staging on the same envelope and
  -- eventually completes its own scene group.
  do
    local resumeFs = dualSceneCacheFs(record, sceneRecord(SCENE_B_KEY))
    local resumePool = scriptedPool(0, {})
    local resume = warmEnvelope(resumeFs, resumePool, nearHost({}, true))
    driveWarmup(resume, SCENE_KEY, 1, 64)
    local settledResumeLoads = totalLoads(resumeFs.loadLuaCounts)
    driveWarmup(resume, SCENE_B_KEY, 1, 128)
    Assert.isTrue(
      totalLoads(resumeFs.loadLuaCounts) > settledResumeLoads,
      "a changed scene stages its own documents instead of idling"
    )
    Assert.notNil(
      resume:_preparationServices().drawable("scene:" .. SCENE_B_KEY),
      "the resumed prediction completes its own scene group"
    )
    resume:dispose()
  end
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

-- A terminal speculative image failure retires its pool interest
-- exactly once without losing the diagnostic: the failed ticket is
-- cancelled, later same-key speculation never re-enrolls it while the
-- latch holds, a changed prediction does not resurrect the old token,
-- and required foreground demand for the bad art still fails aloud.
-- A throwing poll takes the same retirement path in the same journey.
function T.failed_speculative_image_request_cancels_its_pool_interest()
  local record = sceneRecord(SCENE_KEY)
  local pool = scriptedPool(0, { [record.imagePath] = "probe-scene-upload-failed" })
  local cacheFs = dualSceneCacheFs(record, sceneRecord(SCENE_B_KEY))
  local envelope = warmEnvelope(cacheFs, pool, nearHost({}, true))
  local used, failure = envelope:advanceWarmup(SCENE_KEY, 1)
  Assert.isFalse(used == true, "a failed speculative image realizes no GPU pair")
  Assert.isTrue(
    type(failure) == "string"
      and failure:find(SCENE_KEY, 1, true) ~= nil
      and failure:find(record.imagePath, 1, true) ~= nil,
    "the terminal failure names its scene key and path: " .. tostring(failure)
  )
  local failedToken = nil
  for _, entry in ipairs(pool.requested) do
    if entry.path == record.imagePath then
      failedToken = entry.token
    end
  end
  Assert.notNil(failedToken, "the failed path was enrolled exactly once")
  local function cancelCount(token)
    local count = 0
    for _, cancelled in ipairs(pool.cancelled) do
      if cancelled == token then
        count = count + 1
      end
    end
    return count
  end
  Assert.equal(cancelCount(failedToken), 1, "the terminal failed ticket is cancelled exactly once")
  Assert.isNil(pool.live[failedToken], "the failed token holds no pool interest afterwards")
  for _ = 1, 4 do
    local _, failureAgain = envelope:advanceWarmup(SCENE_KEY, 1)
    Assert.isNil(failureAgain, "latched speculation reports no further failure: " .. tostring(failureAgain))
  end
  local failedRequests = 0
  for _, entry in ipairs(pool.requested) do
    if entry.path == record.imagePath then
      failedRequests = failedRequests + 1
    end
  end
  Assert.equal(failedRequests, 1, "the latched path is never re-enrolled while the prediction holds")
  local _, switchFailure = envelope:advanceWarmup(SCENE_B_KEY, 0)
  Assert.isNil(switchFailure, "switching predictions reports no failure: " .. tostring(switchFailure))
  for _, entry in ipairs(pool.acquired) do
    Assert.isTrue(entry.token ~= failedToken, "a stale failed token is never consumed afterwards")
  end
  local _, revisitFailure = envelope:advanceWarmup(SCENE_KEY, 1)
  Assert.isTrue(
    type(revisitFailure) == "string" and revisitFailure:find(record.imagePath, 1, true) ~= nil,
    "revisiting the scene still reports the deterministic failure: " .. tostring(revisitFailure)
  )
  local revisitToken = nil
  for _, entry in ipairs(pool.requested) do
    if entry.path == record.imagePath and entry.token ~= failedToken then
      revisitToken = entry.token
    end
  end
  Assert.notNil(revisitToken, "the revisit enrolls a fresh token instead of resurrecting the old one")
  Assert.equal(cancelCount(revisitToken), 1, "the revisit failure is cancelled exactly once as well")
  Assert.equal(cancelCount(failedToken), 1, "the original failed token is never cancelled twice")
  local services = envelope:_preparationServices()
  -- The main scene image borrows through the drawable seam, not the
  -- scene-group prepare: prepare stages only intro and terrain art, so
  -- the foreground drawable is the seam that fails aloud and latches.
  local sceneDrawable, demandFailure = services.drawable("scene:" .. SCENE_KEY)
  Assert.isNil(sceneDrawable, "required demand for the bad art never reads as ready")
  Assert.isTrue(
    type(demandFailure) == "string" and demandFailure:find(record.imagePath, 1, true) ~= nil,
    "required demand still names the failing path: " .. tostring(demandFailure)
  )
  envelope:dispose()
  -- A throwing poll retires its token through the same cancellation path.
  local recordThrow = sceneRecord(SCENE_KEY)
  local throwingPool = scriptedPool(0, {})
  throwingPool.throwPaths[recordThrow.introLayer.image] = "probe-poll-threw"
  local throwingEnvelope =
    warmEnvelope(dualSceneCacheFs(recordThrow, sceneRecord(SCENE_B_KEY)), throwingPool, nearHost({}, true))
  local usedThrow, failureThrow = throwingEnvelope:advanceWarmup(SCENE_KEY, 1)
  Assert.isFalse(usedThrow == true, "a throwing poll realizes no GPU pair")
  Assert.isTrue(
    type(failureThrow) == "string"
      and failureThrow:find(SCENE_KEY, 1, true) ~= nil
      and failureThrow:find(recordThrow.introLayer.image, 1, true) ~= nil,
    "a throwing poll keeps its scene/key/path cause: " .. tostring(failureThrow)
  )
  local thrownToken = nil
  for _, entry in ipairs(throwingPool.requested) do
    if entry.path == recordThrow.introLayer.image then
      thrownToken = entry.token
    end
  end
  Assert.notNil(thrownToken, "the throwing path was enrolled")
  local thrownCancels = 0
  for _, cancelled in ipairs(throwingPool.cancelled) do
    if cancelled == thrownToken then
      thrownCancels = thrownCancels + 1
    end
  end
  Assert.equal(thrownCancels, 1, "the thrown ticket is cancelled exactly once")
  Assert.isNil(throwingPool.live[thrownToken], "the thrown token holds no pool interest afterwards")
  throwingEnvelope:dispose()
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
    for _, key in ipairs(groupKeys(SCENE_C_KEY)) do
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
  -- Partial A, then partial B, then C: neither abandoned incomplete
  -- group keeps a pin; only the current prediction may stay partial.
  do
    local recordC = sceneRecord(SCENE_C_KEY)
    local cacheFs = dualSceneCacheFs(recordA, recordB, recordC)
    local pool = scriptedPool(1000000, {})
    local envelope = warmEnvelope(cacheFs, pool, nearHost({}, true))
    pool.readyPaths[recordA.imagePath] = true
    local usedA, failureA = envelope:advanceWarmup(SCENE_KEY, 1)
    Assert.isTrue(usedA == true, "the first prediction adopts its ready scene image")
    Assert.isNil(failureA, "the partial prediction reports no failure: " .. tostring(failureA))
    local usedA2, failureA2 = envelope:advanceWarmup(SCENE_KEY, 1)
    Assert.isFalse(usedA2 == true, "nothing else is ready behind the partial prediction")
    Assert.isNil(failureA2, "the stalled partial prediction reports no failure: " .. tostring(failureA2))
    Assert.equal(#pool.acquired, 1, "the partial prediction holds exactly one scene lease")
    local leaseA = pool.acquired[1].lease
    pool.readyPaths[recordB.imagePath] = true
    pool.readyPaths[recordB.introLayer.image] = true
    local usedB, failureB = envelope:advanceWarmup(SCENE_B_KEY, 1)
    Assert.isTrue(usedB == true, "the replacement prediction adopts its own ready art")
    Assert.isNil(failureB, "the replacement reports no failure: " .. tostring(failureB))
    Assert.equal(
      releaseCount(pool, leaseA),
      1,
      "the abandoned partial group returns its lease exactly once"
    )
    local usedB2, failureB2 = envelope:advanceWarmup(SCENE_B_KEY, 1)
    Assert.isTrue(usedB2 == true, "the replacement adopts its second ready image")
    Assert.isNil(failureB2, "the partial replacement reports no failure: " .. tostring(failureB2))
    Assert.equal(#pool.acquired, 3, "the partial replacement holds exactly two scene leases")
    local leaseB1 = pool.acquired[2].lease
    local leaseB2 = pool.acquired[3].lease
    pool.readyPaths[recordC.imagePath] = true
    local usedC, failureC = envelope:advanceWarmup(SCENE_C_KEY, 1)
    Assert.isTrue(usedC == true, "the third prediction adopts its own ready art")
    Assert.isNil(failureC, "the third prediction reports no failure: " .. tostring(failureC))
    Assert.equal(
      releaseCount(pool, leaseB1),
      1,
      "the second abandoned partial group returns its first lease exactly once"
    )
    Assert.equal(
      releaseCount(pool, leaseB2),
      1,
      "the second abandoned partial group returns its second lease exactly once"
    )
    -- Drawable fresh-borrows any pool-ready path on demand, so retired
    -- predictions are proved gone through the pin and pool ledgers
    -- instead of a drawable probe that would re-enroll behind the check.
    Assert.deepEqual(
      pinnedSceneKeys(envelope),
      sorted({ "scene:" .. SCENE_C_KEY }),
      "only the current prediction keeps pins; abandoned partial groups keep none"
    )
    Assert.equal(
      releaseCount(pool, leaseB1),
      1,
      "the retired replacement still returns its first lease exactly once"
    )
    Assert.equal(
      releaseCount(pool, leaseB2),
      1,
      "the retired replacement still returns its second lease exactly once"
    )
    local function retiredSceneImageCount(ledger)
      local count = 0
      for _, entry in ipairs(ledger) do
        if entry.path == recordA.imagePath or entry.path == recordB.imagePath then
          count = count + 1
        end
      end
      return count
    end
    local requestedRetired = retiredSceneImageCount(pool.requested)
    local acquiredRetired = retiredSceneImageCount(pool.acquired)
    for _ = 1, 3 do
      local _, failureLater = envelope:advanceWarmup(SCENE_C_KEY, 1)
      Assert.isNil(failureLater, "further current-prediction warmup reports no failure: " .. tostring(failureLater))
    end
    Assert.equal(
      retiredSceneImageCount(pool.requested),
      requestedRetired,
      "further warmup enrolls no new tickets for retired predictions"
    )
    Assert.equal(
      retiredSceneImageCount(pool.acquired),
      acquiredRetired,
      "further warmup acquires no new leases for retired predictions"
    )
    local partialServices = envelope:_preparationServices()
    Assert.notNil(
      partialServices.drawable("scene:" .. SCENE_C_KEY),
      "only the current prediction keeps its partial scene"
    )
    envelope:dispose()
    for _, entry in ipairs(pool.acquired) do
      Assert.equal(
        releaseCount(pool, entry.lease),
        1,
        "disposal returns every adopted partial lease exactly once: " .. entry.path
      )
    end
  end
  -- Complete A, then partial B, then partial C: the complete
  -- predecessor stays usable until C completes, B's partial pins return
  -- once, fixed art is never treated as disposable scene art, and C's
  -- completion retires A once.
  do
    local recordC = sceneRecord(SCENE_C_KEY)
    local cacheFs = dualSceneCacheFs(recordA, recordB, recordC)
    local pool = scriptedPool(1000000, {})
    local envelope = warmEnvelope(cacheFs, pool, nearHost({}, true))
    for _, path in ipairs({
      recordA.imagePath,
      recordA.introLayer.image,
      recordA.terrainSprites.player.image,
      recordA.terrainSprites.foe.image,
      "assets/generated/battle/synthetic.png",
    }) do
      pool.readyPaths[path] = true
    end
    driveWarmup(envelope, SCENE_KEY, 1, 128)
    Assert.deepEqual(
      pinnedSceneKeys(envelope),
      sorted(groupKeys(SCENE_KEY)),
      "idle warmup completes scene A's group with its fixed art"
    )
    local priorA = {}
    for _, key in ipairs(groupKeys(SCENE_KEY)) do
      priorA[key] = envelope._warmPinned[key].lease
    end
    pool.readyPaths[recordB.imagePath] = true
    local usedB, failureB = envelope:advanceWarmup(SCENE_B_KEY, 1)
    Assert.isTrue(usedB == true, "the partial successor adopts its ready scene image")
    Assert.isNil(failureB, "the partial successor reports no failure: " .. tostring(failureB))
    Assert.notNil(
      envelope:_preparationServices().drawable("scene:" .. SCENE_KEY),
      "the complete predecessor stays usable during partial replacement"
    )
    for _, key in ipairs(groupKeys(SCENE_KEY)) do
      Assert.equal(
        releaseCount(pool, priorA[key]),
        0,
        "the complete predecessor keeps its leases during partial replacement: " .. key
      )
    end
    local leaseB = pool.acquired[#pool.acquired].lease
    pool.readyPaths[recordC.imagePath] = true
    local usedC, failureC = envelope:advanceWarmup(SCENE_C_KEY, 1)
    Assert.isTrue(usedC == true, "the third prediction adopts its own ready art")
    Assert.isNil(failureC, "the third prediction reports no failure: " .. tostring(failureC))
    Assert.equal(
      releaseCount(pool, leaseB),
      1,
      "the superseded partial group returns its lease exactly once"
    )
    Assert.notNil(
      envelope:_preparationServices().drawable("scene:" .. SCENE_KEY),
      "the complete predecessor survives a second partial replacement"
    )
    -- Drawable fresh-borrows any pool-ready path on demand, so the
    -- retired partial is proved gone through the pin and pool ledgers
    -- instead of a drawable probe that would re-enroll behind the check.
    local expectedPinned = groupKeys(SCENE_KEY)
    expectedPinned[#expectedPinned + 1] = "scene:" .. SCENE_C_KEY
    Assert.deepEqual(
      pinnedSceneKeys(envelope),
      sorted(expectedPinned),
      "the complete predecessor keeps its full group while only the current prediction stays partial"
    )
    Assert.equal(
      releaseCount(pool, leaseB),
      1,
      "the superseded partial group still returns its lease exactly once"
    )
    local function retiredBImageCount(ledger)
      local count = 0
      for _, entry in ipairs(ledger) do
        if entry.path == recordB.imagePath then
          count = count + 1
        end
      end
      return count
    end
    local requestedB = retiredBImageCount(pool.requested)
    local acquiredB = retiredBImageCount(pool.acquired)
    for _ = 1, 2 do
      local _, failureLater = envelope:advanceWarmup(SCENE_C_KEY, 1)
      Assert.isNil(failureLater, "further current-prediction warmup reports no failure: " .. tostring(failureLater))
    end
    Assert.equal(
      retiredBImageCount(pool.requested),
      requestedB,
      "further warmup enrolls no new tickets for the retired prediction"
    )
    Assert.equal(
      retiredBImageCount(pool.acquired),
      acquiredB,
      "further warmup acquires no new leases for the retired prediction"
    )
    for _, entry in ipairs(pool.acquired) do
      if entry.path == "assets/generated/battle/synthetic.png" then
        Assert.equal(
          releaseCount(pool, entry.lease),
          0,
          "fixed art is never retired as scene-specific art"
        )
      end
    end
    pool.readyPaths[recordC.introLayer.image] = true
    pool.readyPaths[recordC.terrainSprites.player.image] = true
    pool.readyPaths[recordC.terrainSprites.foe.image] = true
    driveWarmup(envelope, SCENE_C_KEY, 1, 128)
    Assert.notNil(
      envelope:_preparationServices().drawable("scene:" .. SCENE_C_KEY),
      "the third prediction completes its own scene group"
    )
    for _, key in ipairs(groupKeys(SCENE_KEY)) do
      Assert.equal(
        releaseCount(pool, priorA[key]),
        1,
        "completing the successor retires the predecessor exactly once: " .. key
      )
    end
    envelope:dispose()
  end
end

-- A predicted scene whose images never become ready validates its scene
-- and global documents once, then keeps polling tickets without rereading
-- staged files, enrolling duplicates, or realizing GPU images. A pending
-- semantic producer touches no staged files at all.
function T.pending_warmup_reuses_validated_documents_across_idle_frames()
  local record = sceneRecord(SCENE_KEY)
  do
    local pendingFs = dualSceneCacheFs(record, sceneRecord(SCENE_B_KEY))
    local pendingPool = scriptedPool(1000000, {})
    local pendingEnvelope = warmEnvelope(pendingFs, pendingPool, nearHost({}, false))
    local pendingLoads = totalLoads(pendingFs.loadLuaCounts)
    local pendingReads = totalLoads(pendingFs.reads)
    for _ = 1, 10 do
      local usedPending, failurePending = pendingEnvelope:advanceWarmup(SCENE_KEY, 1)
      Assert.isFalse(usedPending == true, "a pending producer realizes no GPU pair")
      Assert.isNil(failurePending, "a pending producer reports no failure")
    end
    Assert.equal(
      totalLoads(pendingFs.loadLuaCounts),
      pendingLoads,
      "a pending producer parses no Lua documents"
    )
    Assert.equal(totalLoads(pendingFs.reads), pendingReads, "a pending producer reads no staged bytes")
    Assert.equal(#pendingPool.requested, 0, "a pending producer enrolls no image tickets")
    pendingEnvelope:dispose()
  end
  local cacheFs = dualSceneCacheFs(record, sceneRecord(SCENE_B_KEY))
  local pool = scriptedPool(1000000, {})
  local envelope = warmEnvelope(cacheFs, pool, nearHost({}, true))
  local scenePath = BattlePresentationCache.scenePath(SCENE_KEY)
  local manifestPath = BattlePresentationCache.manifestPath()
  local usedFirst, failureFirst = envelope:advanceWarmup(SCENE_KEY, 0)
  Assert.isFalse(usedFirst == true, "an incomplete warmup realizes no GPU pair")
  Assert.isNil(failureFirst, "an incomplete warmup reports no failure: " .. tostring(failureFirst))
  Assert.equal(cacheFs.loadLuaCounts[scenePath], 1, "the first ready round validates the scene document once")
  local manifestLoads = cacheFs.loadLuaCounts[manifestPath] or 0
  local readsBefore = totalLoads(cacheFs.reads)
  local requestedBefore = #pool.requested
  Assert.isTrue(requestedBefore > 0, "the first round enrolls the scene tickets")
  for round = 1, 150 do
    local allowance = (round % 10 == 0) and 1 or 0
    local used, failure = envelope:advanceWarmup(SCENE_KEY, allowance)
    Assert.isFalse(used == true, "a pending scene realizes no GPU pair")
    Assert.isNil(failure, "a pending scene reports no failure")
  end
  Assert.equal(
    cacheFs.loadLuaCounts[scenePath],
    1,
    "pending idle rereads no scene document after the first validated plan"
  )
  Assert.equal(
    cacheFs.loadLuaCounts[manifestPath] or 0,
    manifestLoads,
    "pending idle rereads no global manifest after the first validated plan"
  )
  Assert.equal(totalLoads(cacheFs.reads), readsBefore, "pending idle rereads no staged bytes")
  Assert.equal(#pool.requested, requestedBefore, "pending idle enrolls no duplicate tickets")
  Assert.equal(#pool.acquired, 0, "pending idle constructs no GPU images")
  envelope:dispose()
end

-- A replacement prediction validates its own scene once while pending,
-- keeps the complete predecessor usable until the successor completes,
-- and reparses neither scene while tickets stay pending.
function T.replacement_prediction_validates_once_and_keeps_predecessor_until_complete()
  local recordA = sceneRecord(SCENE_KEY)
  local recordB = sceneRecord(SCENE_B_KEY)
  local cacheFs = dualSceneCacheFs(recordA, recordB)
  local pool = scriptedPool(1000000, {})
  local envelope = warmEnvelope(cacheFs, pool, nearHost({}, true))
  local scenePathA = BattlePresentationCache.scenePath(SCENE_KEY)
  local scenePathB = BattlePresentationCache.scenePath(SCENE_B_KEY)
  local manifestPath = BattlePresentationCache.manifestPath()
  for _, path in ipairs({
    recordA.imagePath,
    recordA.introLayer.image,
    recordA.terrainSprites.player.image,
    recordA.terrainSprites.foe.image,
    "assets/generated/battle/synthetic.png",
  }) do
    pool.readyPaths[path] = true
  end
  driveWarmup(envelope, SCENE_KEY, 1, 128)
  Assert.notNil(
    envelope:_preparationServices().drawable("scene:" .. SCENE_KEY),
    "the first prediction completes its scene group"
  )
  local function acquiredSceneACount()
    local count = 0
    for _, entry in ipairs(pool.acquired) do
      if
        entry.path == recordA.imagePath
        or entry.path == recordA.introLayer.image
        or entry.path == recordA.terrainSprites.player.image
        or entry.path == recordA.terrainSprites.foe.image
      then
        count = count + 1
      end
    end
    return count
  end
  local acquiredBefore = acquiredSceneACount()
  Assert.isTrue(acquiredBefore > 0, "the first prediction adopts its scene art")
  local usedB, failureB = envelope:advanceWarmup(SCENE_B_KEY, 0)
  Assert.isFalse(usedB == true, "the replacement enrolls without realizing any image pair")
  Assert.isNil(failureB, "the replacement reports no failure: " .. tostring(failureB))
  Assert.equal(cacheFs.loadLuaCounts[scenePathB], 1, "the replacement validates its scene document once")
  local manifestPending = cacheFs.loadLuaCounts[manifestPath] or 0
  for round = 1, 100 do
    local allowance = (round % 10 == 0) and 1 or 0
    local used, failure = envelope:advanceWarmup(SCENE_B_KEY, allowance)
    Assert.isFalse(used == true, "the pending replacement realizes no GPU pair")
    Assert.isNil(failure, "the pending replacement reports no failure")
  end
  Assert.equal(
    cacheFs.loadLuaCounts[scenePathA],
    1,
    "the pending replacement reparses no predecessor scene document"
  )
  Assert.equal(
    cacheFs.loadLuaCounts[scenePathB],
    1,
    "the pending replacement rereads no scene document while its images stay pending"
  )
  Assert.equal(
    cacheFs.loadLuaCounts[manifestPath] or 0,
    manifestPending,
    "the pending replacement rereads no global manifest while its images stay pending"
  )
  Assert.notNil(
    envelope:_preparationServices().drawable("scene:" .. SCENE_KEY),
    "the complete predecessor stays usable while the replacement stays pending"
  )
  for _, path in ipairs({
    recordB.imagePath,
    recordB.introLayer.image,
    recordB.terrainSprites.player.image,
    recordB.terrainSprites.foe.image,
  }) do
    pool.readyPaths[path] = true
  end
  driveWarmup(envelope, SCENE_B_KEY, 1, 128)
  Assert.notNil(
    envelope:_preparationServices().drawable("scene:" .. SCENE_B_KEY),
    "the replacement completes its own scene group"
  )
  Assert.equal(cacheFs.loadLuaCounts[scenePathA], 1, "the predecessor scene validated exactly once")
  Assert.equal(cacheFs.loadLuaCounts[scenePathB], 1, "the replacement scene validated exactly once")
  Assert.isTrue(
    (cacheFs.loadLuaCounts[manifestPath] or 0) <= 2,
    "the global manifest validates at most once per prediction"
  )
  Assert.equal(acquiredSceneACount(), acquiredBefore, "no late abandoned art publishes the predecessor scene")
  envelope:dispose()
end

-- A terminal speculative image failure stays quiet on later idle frames:
-- no document rereads, no re-enrollment, no repeated error — while the
-- required foreground demand still fails aloud and an independent valid
-- launch still prepares.
function T.failed_warmup_stays_quiet_without_rereading_documents()
  local record = sceneRecord(SCENE_KEY)
  local recordB = sceneRecord(SCENE_B_KEY)
  local cacheFs = dualSceneCacheFs(record, recordB)
  local pool = scriptedPool(0, { [record.imagePath] = "probe-scene-upload-failed" })
  local envelope = warmEnvelope(cacheFs, pool, nearHost({}, true))
  local scenePath = BattlePresentationCache.scenePath(SCENE_KEY)
  local manifestPath = BattlePresentationCache.manifestPath()
  local used, failure = envelope:advanceWarmup(SCENE_KEY, 1)
  Assert.isFalse(used == true, "a failed speculative image realizes no GPU pair")
  Assert.isTrue(
    type(failure) == "string"
      and failure:find(SCENE_KEY, 1, true) ~= nil
      and failure:find(record.imagePath, 1, true) ~= nil,
    "the terminal failure names its scene key and path: " .. tostring(failure)
  )
  local sceneLoads = cacheFs.loadLuaCounts[scenePath]
  local manifestLoads = cacheFs.loadLuaCounts[manifestPath] or 0
  local requested = #pool.requested
  for _ = 1, 150 do
    local usedIdle, failureIdle = envelope:advanceWarmup(SCENE_KEY, 0)
    Assert.isFalse(usedIdle == true, "latched speculation realizes no GPU pair")
    Assert.isNil(failureIdle, "latched speculation reports no further failure")
  end
  Assert.equal(
    cacheFs.loadLuaCounts[scenePath],
    sceneLoads,
    "latched speculation rereads no scene document"
  )
  Assert.equal(
    cacheFs.loadLuaCounts[manifestPath] or 0,
    manifestLoads,
    "latched speculation rereads no global manifest"
  )
  Assert.equal(#pool.requested, requested, "latched speculation enrolls no new tickets")
  for _ = 1, 10 do
    local usedAllowed, failureAllowed = envelope:advanceWarmup(SCENE_KEY, 1)
    Assert.isFalse(usedAllowed == true, "latched speculation stays quiet even with allowance")
    Assert.isNil(failureAllowed, "latched speculation reports no further failure with allowance")
  end
  local services = envelope:_preparationServices()
  local sceneDrawable, demandFailure = services.drawable("scene:" .. SCENE_KEY)
  Assert.isNil(sceneDrawable, "required demand for the bad art never reads as ready")
  Assert.isTrue(
    type(demandFailure) == "string" and demandFailure:find(record.imagePath, 1, true) ~= nil,
    "required demand still names the failing path: " .. tostring(demandFailure)
  )
  local readyB, failureB = services.prepare({
    launchId = "failed-warmup-independent-launch",
    scenes = { SCENE_B_KEY },
    pages = {},
    trainerPictures = {},
    battleBalls = {},
    iconKeys = {},
    audio = { roles = {}, banks = {}, cries = {} },
  })
  Assert.isTrue(readyB, "an independent valid launch still prepares: " .. tostring(failureB))
  envelope:dispose()
end

-- A launch whose cry and music banks are not yet staged waits under cover
-- instead of voicing a missing bank: preparation demands every music bank
-- and every cry species bank at required urgency and stays pending until
-- the worker stages them, so a fresh cache never reaches its send-out cry
-- with a missing audio asset (PIDGEY voices bank 16).
function T.preparation_waits_for_cry_and_music_banks_before_first_battle()
  local record = sceneRecord(SCENE_KEY)
  local pool = ledgerPool(0, {})
  local bankReady = false
  local bankAsks = {}
  local host = {
    requestAudioBank = function(bankId, urgency)
      bankAsks[#bankAsks + 1] = { bankId = bankId, urgency = urgency }
      if bankReady then
        return true
      end
      return nil
    end,
  }
  local monCatalog = {
    species = function(_, key)
      assert(key == "PIDGEY", "the probe cry names its species")
      return { nativeId = 16 }
    end,
  }
  local envelope = FieldBattlePresentation.new({
    cacheFs = stagedCacheFs(record),
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
        signature = "scene-assets-audio-gate",
      }
    end,
    graphics = {},
    imagePool = pool,
    derivedAssets = host,
    monCatalog = monCatalog,
  })
  envelope._manifest = graphicsManifest()
  local services = envelope:_preparationServices()
  local demand = {
    launchId = "cry-bank-gate",
    scenes = { SCENE_KEY },
    pages = {},
    trainerPictures = {},
    battleBalls = {},
    iconKeys = {},
    audio = { roles = {}, banks = { 7 }, cries = { "cry:PIDGEY" } },
  }
  local ready, failure = services.prepare(demand)
  Assert.isNil(failure, "an unstaged cry bank waits without failing: " .. tostring(failure))
  Assert.isFalse(ready == true, "an unstaged cry bank never prepares its launch")
  local asked = {}
  for _, ask in ipairs(bankAsks) do
    Assert.equal(ask.urgency, "required", "cry and music banks stage at required urgency")
    asked[ask.bankId] = true
  end
  Assert.isTrue(asked[7], "the music bank stages before the launch prepares")
  Assert.isTrue(asked[16], "the PIDGEY cry bank stages before the launch prepares")
  bankReady = true
  local readyStaged, failureStaged = services.prepare(demand)
  Assert.isTrue(readyStaged, "the staged cry bank prepares its launch: " .. tostring(failureStaged))
  envelope:dispose()
end

local MUSIC_ROLE = "SEQ_TEST_WILD"

-- Staged audio index mapping only the probe music role to its bank, so
-- admission and music-start demands resolve without the full catalog.
local function musicIndex()
  return {
    schema = AudioCache.INDEX_SCHEMA,
    sequences = { [11] = { bankId = 7 } },
    sequenceBySymbol = { [MUSIC_ROLE] = 11 },
  }
end

local function probeCatalog()
  return {
    species = function(_, key)
      if key == "PIDGEY" then
        return { nativeId = 16, genderRatio = 127 }
      end
      if key == "CHIKORITA" then
        return { nativeId = 152, genderRatio = 127 }
      end
      error("unknown probe species: " .. tostring(key), 0)
    end,
  }
end

local function probeMon(species)
  return {
    species = species,
    form = 0,
    personality = 0x12345678,
    origin = { trainerId = 1 },
  }
end

-- Recording derived-asset host behind admission and music-start demands:
-- every method records its urgency and answers from one readiness flag.
local function recordingDemands(host)
  host.asks = {}
  host.bankReady = false
  function host.requestBattlePresentation(urgency)
    host.asks[#host.asks + 1] = { method = "presentation", urgency = urgency }
    if host.bankReady then
      return true
    end
    return nil
  end
  function host.requestBattleScene(sceneKey, urgency)
    host.asks[#host.asks + 1] = { method = "scene", id = sceneKey, urgency = urgency }
    if host.bankReady then
      return true
    end
    return nil
  end
  function host.requestMonPortraitPage(pageId, urgency)
    host.asks[#host.asks + 1] = { method = "portrait", id = pageId, urgency = urgency }
    if host.bankReady then
      return true
    end
    return nil
  end
  function host.requestAudioBank(bankId, urgency)
    host.asks[#host.asks + 1] = { method = "audioBank", id = bankId, urgency = urgency }
    if host.bankReady then
      return true
    end
    return nil
  end
  return host
end

local function admissionCacheFs(record, portraits)
  local cacheFs = stagedCacheFs(record)
  local baseLoad = cacheFs.loadLua
  function cacheFs:loadLua(path)
    if path == AudioCache.indexPath() then
      return musicIndex()
    end
    if path == MonCache.portraitManifestPath() then
      return { entries = portraits }
    end
    return baseLoad(self, path)
  end
  return cacheFs
end

local function admissionEnvelope(cacheFs, pool, host, catalog, audio)
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
        signature = "scene-assets-admission",
      }
    end,
    graphics = {},
    imagePool = pool,
    derivedAssets = host,
    monCatalog = catalog,
    audio = audio,
  })
  envelope._manifest = graphicsManifest()
  return envelope
end

local function askedSet(asks)
  local seen = {}
  for _, ask in ipairs(asks) do
    Assert.equal(ask.urgency, "required", "admission stages its launch demands at required urgency")
    local key = ask.method .. ":" .. tostring(ask.id)
    seen[key] = true
  end
  return seen
end

-- Admission enrolls the whole launch closure at required urgency before
-- any tick runs: the shared global, the scene, the music bank, and the
-- lead and foe portrait pages with their cry banks. The worker then
-- builds throughout the transition instead of starting at first packet.
function T.admission_preseeds_launch_closure_at_required_urgency()
  local record = sceneRecord(SCENE_KEY)
  local catalog = probeCatalog()
  local leadMon, foeMon = probeMon("CHIKORITA"), probeMon("PIDGEY")
  local leadSelector = SummaryModel.portraitSelectorFor(catalog, leadMon)
  local foeSelector = SummaryModel.portraitSelectorFor(catalog, foeMon)
  local cacheFs = admissionCacheFs(record, {
    [leadSelector] = { pageId = 5 },
    [foeSelector] = { pageId = 3 },
  })
  local pool = ledgerPool(0, {})
  local host = recordingDemands({})
  local envelope = admissionEnvelope(cacheFs, pool, host, catalog, nil)
  envelope:factory()({
    launchId = "admission-preseed",
    kind = "wild",
    environment = { sceneKey = SCENE_KEY },
    textSpeed = "fastest",
    audio = { playMusic = function()
      return true
    end },
    musicRole = MUSIC_ROLE,
    leadMon = leadMon,
    foeMon = foeMon,
    host = {},
  })
  local seen = askedSet(host.asks)
  Assert.isTrue(seen["presentation:nil"], "admission demands the shared global first")
  Assert.isTrue(seen["scene:" .. SCENE_KEY], "admission demands the scene at required urgency")
  Assert.isTrue(seen["audioBank:7"], "admission demands the music bank at required urgency")
  Assert.isTrue(seen["audioBank:152"], "admission demands the lead cry bank at required urgency")
  Assert.isTrue(seen["audioBank:16"], "admission demands the foe cry bank at required urgency")
  Assert.isTrue(seen["portrait:5"], "admission demands the lead portrait page at required urgency")
  Assert.isTrue(seen["portrait:3"], "admission demands the foe portrait page at required urgency")
  envelope:dispose()
end

-- Battle music waits for its staged files and suspends the field policy
-- on the same tick it voices: an unstaged bank holds without failing
-- and without silencing the field, and admission itself never suspends.
function T.battle_music_waits_for_staged_files_and_suspends_with_the_start()
  local record = sceneRecord(SCENE_KEY)
  local cacheFs = admissionCacheFs(record, {})
  local pool = ledgerPool(0, {})
  local host = recordingDemands({})
  local controller = { suspends = {}, plays = {} }
  function controller:suspendFieldPolicy(token)
    self.suspends[#self.suspends + 1] = token
  end
  function controller:playMusic(symbol)
    self.plays[#self.plays + 1] = symbol
    return true
  end
  local envelope = admissionEnvelope(cacheFs, pool, host, probeCatalog(), controller)
  envelope:factory()({
    launchId = "music-gate",
    kind = "wild",
    environment = { sceneKey = SCENE_KEY },
    textSpeed = "fastest",
    audio = controller,
    musicRole = MUSIC_ROLE,
    host = {},
  })
  Assert.equal(#controller.suspends, 0, "admission never suspends the field policy")
  envelope:_startBattleMusic()
  Assert.equal(#controller.suspends, 0, "an unstaged music bank holds without suspending the field")
  Assert.equal(#controller.plays, 0, "an unstaged music bank holds without voicing")
  Assert.isNil(envelope:musicNote(), "an unstaged music bank records no start note")
  host.bankReady = true
  envelope:_startBattleMusic()
  Assert.deepEqual(controller.suspends, { "music-gate" }, "the staged start suspends the field policy once")
  Assert.deepEqual(controller.plays, { MUSIC_ROLE }, "the staged start voices its role once")
  Assert.equal(envelope:musicNote(), "started:" .. MUSIC_ROLE, "the staged start records its note")
  envelope:_startBattleMusic()
  Assert.equal(#controller.plays, 1, "the music start latches exactly once")
  envelope:dispose()
end

return { tests = T }
