-- The coordinator-injected follower rejoin through production composition
-- (retail map-preview player drop-in states 4-5 and warp-panel
-- state 5): with a follower in the party, the transition the
-- real FieldWorldSwapCoordinator builds must carry the follower collaborator,
-- so a profile-8 preview arrival and a panel arrival each hand the follower
-- back onto the committed player tile, hidden until its first step, exactly
-- once -- and the first trail step re-shows the same single partner. The
-- real coordinator (prepare/commit order included), the real
-- FollowingMonController, the real FieldActorManager, and the real
-- FieldPlayer/FieldTransition run here; only the party service is a
-- scriptable fake at its documented contract, and residency publication is a
-- stub that retires the actor map the way the production residency commit
-- does. No assertion names controller internals: position, visibility,
-- identity, and lock state are the whole contract.

local Assert = require("tests.support.Assert")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local FieldTransitionProfile = require("libs.hgss.src.transition.FieldTransitionProfile")
local FieldWorldSwapCoordinator = require("game.hgss.src.field.FieldWorldSwapCoordinator")
local FollowingMonController = require("libs.hgss.src.field.FollowingMonController")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")

local T = {}

local POLICY = {
  variableSprites = { first = 101, last = 117, variableBase = 0x4020 },
}

local function terrain()
  return TerrainSurface.new({
    plates = {
      {
        id = 0,
        minX = 0,
        minZ = 0,
        maxX = 32,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 0,
        slopeClass = "flat",
      },
    },
  })
end

local function runtimeMap(mapId)
  return {
    mapId = mapId,
    mapSection = "test-section",
    mapSectionNativeId = 7,
    followMode = "ALLOW",
    coordinateOrigin = { x = 0, z = 0 },
    scene = {},
    fieldData = { events = { objects = {}, background = {}, warps = {}, coordinates = {} } },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      isBlockedLocal = function()
        return false
      end,
      getLocal = function()
        return { blocked = false, behavior = 0 }
      end,
    },
    terrain = terrain(),
    terrainDependencyHash = "test-terrain",
    fieldRegion = {},
    cameraType = 0,
    mapSymbol = "test-map",
    release = function() end,
    updateAnimated = function() end,
  }
end

local function cameraProfile()
  return {
    projectionType = "perspective",
    distanceTiles = 10,
    angleXRaw = 0,
    angleYRaw = 0,
    halfFovRadians = 0.5,
    fullVerticalFovRadians = 1.0,
    nearTiles = 1,
    farTiles = 100,
    targetOffsetTiles = { x = 0, y = 0, z = 0 },
  }
end

local function fakeAssets(known)
  local assets = {
    references = {},
    knows = function(_, spriteId)
      return known[spriteId] == true
    end,
    acquire = function(self, spriteId)
      self.references[spriteId] = (self.references[spriteId] or 0) + 1
      return { spriteId = spriteId, visual = FieldActorFixture.visual(spriteId) }
    end,
    release = function(self, spriteId)
      local count = self.references[spriteId] or 0
      assert(count > 0, "unbalanced release of spriteId " .. spriteId)
      self.references[spriteId] = count - 1
    end,
  }
  return assets
end

local function service()
  return {
    _revision = 0,
    _slot = nil,
    _mons = {},
    partyRevision = function(self)
      return self._revision
    end,
    leadAliveSlot = function(self)
      return self._slot
    end,
    partyMon = function(self, slot)
      return self._mons[slot]
    end,
    setLead = function(self, slot, record)
      self._slot = slot
      if slot ~= nil then
        self._mons[slot] = record
      end
      self._revision = self._revision + 1
    end,
  }
end

local function mon()
  return {
    species = "CHIKORITA",
    form = 0,
    personality = 0x12345678,
    isEgg = false,
    condition = { status = 0, currentHp = 20 },
  }
end

-- The component world: a follower in the party installed behind the player,
-- plus the stub runtime surface the real coordinator prepare/commit needs.
-- Residency publication retires the actor map exactly as the production
-- residency commit does; everything else is a recording stub. `mode` selects
-- the arrival under test: "panel" runs the teleport spin to an unlisted
-- destination, "preview" runs the profile-8 ladder descent into a listed
-- preview destination.
local function world(mode)
  local source = runtimeMap(61)
  local destination = runtimeMap(mode == "panel" and 60 or 62)
  local manifest = { previewByMapId = {} }
  if mode == "preview" then
    manifest.previewByMapId[62] = {
      [0] = "preview.62.0",
      [1] = "preview.62.1",
      [2] = "preview.62.2",
      [3] = "preview.62.3",
    }
  end
  local built = {
    source = source,
    destination = destination,
    manifest = manifest,
    mgr = nil,
    controller = nil,
    runtime = nil,
    transition = nil,
  }
  local mgr = FieldActorManager.new({ assets = fakeAssets({ [20153] = true, [20154] = true }), policy = POLICY })
  mgr:enterMap(source, FieldEventState.new())
  built.mgr = mgr
  local player = FieldPlayer.new({
    currentMap = source,
    fieldX = mode == "panel" and 5 or 6,
    fieldZ = mode == "panel" and 5 or 16,
    surfaceId = 0,
    facing = mode == "panel" and "north" or "south",
  })
  local runtime = {
    overworld = {
      phase = function()
        return "present"
      end,
    },
    screenFade = {
      isOpaque = function()
        return false
      end,
    },
    transition = { fadeAlpha = 0, coveredSwap = false },
    mapLoader = {
      requestWarp = function()
        return true
      end,
    },
    audio = {
      beginWarp = function() end,
      play = function() end,
      stop = function() end,
      enterMap = function() end,
    },
    scriptHosts = {},
    cameraProfiles = { [0] = cameraProfile() },
    configureCameraProjection = function(_, camera)
      camera:setProjectionAspect(4 / 3)
      camera:setZoom(1)
    end,
    playerAvatar = {
      currentSpriteId = function()
        return 101
      end,
    },
    residency = {
      prepareTransition = function()
        return {}
      end,
      commitTransition = function()
        mgr:enterMap(destination, FieldEventState.new())
      end,
    },
    fieldTerrainEffectController = {
      clear = function() end,
    },
    scripts = {
      onMapSwap = function() end,
    },
    session = {
      beginMapEntry = function() end,
    },
    zoneController = {},
    fieldTravel = nil,
    followingMonTransition = nil,
    mapNameBanner = nil,
    fieldEntryManifest = manifest,
    localClock = {
      nowLocal = function()
        return { hour = 12 }
      end,
    },
    player = player,
  }
  function runtime:_applyEffectiveWeather() end
  function runtime:_playerOccupantAt()
    return nil
  end
  built.runtime = runtime
  local svc = service()
  local controller = FollowingMonController.new({
    service = svc,
    catalog = CatalogFixture.makeCatalog(),
    actors = mgr,
    playerOf = function()
      return runtime.player
    end,
    transition = {
      start = function()
        return true
      end,
    },
  })
  built.controller = controller
  runtime.followingMon = controller
  svc:setLead(0, mon())
  for _ = 1, 4 do
    controller:update()
  end
  assert(mgr:partnerId() ~= nil, "setup installs the partner from the party lead")
  local coordinator = FieldWorldSwapCoordinator.new(runtime)
  local groundY = player.worldY
  local resolveDestination
  if mode == "panel" then
    resolveDestination = function()
      return {
        destinationMap = destination,
        destinationWarp = { x = 6, z = 6 },
        fieldX = 6,
        fieldZ = 6,
        surfaceId = 0,
        worldY = groundY,
        suppression = {},
      }
    end
  else
    resolveDestination = function()
      return {
        destinationMap = destination,
        destinationWarp = { x = 6, z = 16 },
        fieldX = 6,
        fieldZ = 16,
        surfaceId = 0,
        worldY = groundY,
        suppression = {},
      }
    end
  end
  local transition = coordinator:createTransition(runtime, function()
    return nil
  end, function()
    return nil
  end, resolveDestination)
  built.transition = transition
  runtime.transition = transition
  -- Production binds the live player onto the transition at composition
  -- (FieldRuntime line 935) and rebinds it across the swap; the test owns
  -- the same binding explicitly.
  transition.player = player
  return built
end

local function startWarp(w, mode)
  if mode == "panel" then
    w.transition:start(w.source, {
      kind = "generic",
      warp = { index = 0, x = 5, z = 5, destinationMapId = w.destination.mapId, destinationWarpId = 0 },
      transition = FieldTransitionProfile.mode(FieldTransitionProfile.MODE_PANEL),
    }, w.transition.player.facing)
  else
    w.transition:start(w.source, {
      kind = "generic",
      warp = { index = 0, x = 6, z = 16, destinationMapId = w.destination.mapId, destinationWarpId = 0 },
      transition = FieldTransitionProfile.fixed(FieldTransitionProfile.LADDER_DOWN),
    }, "south")
  end
end

local function driveToIdle(w)
  local ticks = 0
  while w.transition.phase ~= "idle" and w.transition.phase ~= "error" and ticks < 600 do
    ticks = ticks + 1
    w.transition:updateFixed()
    w.transition:updateSourceFrame()
    w.controller:update()
  end
  return ticks
end

local function partnerCount(w)
  local seen = 0
  for _, actor in ipairs(w.mgr:actorsOf(w.destination.mapId)) do
    if actor.actorId == "field:partner" then
      seen = seen + 1
    end
  end
  return seen
end

local function assertArrivedHiddenOnTile(w, arrival)
  local transition, controller, mgr, runtime = w.transition, w.controller, w.mgr, w.runtime
  Assert.equal(transition.phase, "idle", "the " .. arrival .. " transition completes with a follower in party")
  Assert.notNil(transition.completed, "the " .. arrival .. " records one completion")
  Assert.isFalse(transition.locked, "the completed " .. arrival .. " releases the field input lock")
  local partnerId = assert(mgr:partnerId(), "the " .. arrival .. " reinstalls the partner on the new map")
  Assert.equal(partnerId, "field:partner", "the rejoined follower keeps its stable actor identity")
  Assert.equal(partnerCount(w), 1, "the " .. arrival .. " installs exactly one follower, never a second")
  local position = assert(mgr:getPosition(partnerId), "the reinstalled partner position is required")
  Assert.equal(position.fieldX, runtime.player.fieldX, "the rejoined follower stands on the committed player tile")
  Assert.equal(position.fieldZ, runtime.player.fieldZ, "the rejoined follower stands on the committed player tile")
  Assert.isFalse(
    controller:isPartnerVisible(),
    "the rejoined follower stays hidden until its first trail step, like retail HideUntilStep"
  )
  return partnerId
end

-- One committed ordinary step through the real player, then settle both the
-- player and the follower trail. Answers the vacated player tile.
local function committedStep(w, direction)
  local player = w.runtime.player
  local vacated = { fieldX = player.fieldX, fieldZ = player.fieldZ }
  Assert.isTrue(player:tryStep(direction), "the reveal step must commit")
  local ticks = 0
  while ticks < 200 do
    ticks = ticks + 1
    player:updateFixed({})
    w.controller:update()
    if player.motion == "idle" and w.controller:isMovementSettled() then
      break
    end
  end
  Assert.equal(player.motion, "idle", "the reveal step resolves")
  Assert.isTrue(w.controller:isMovementSettled(), "the follower trail settles after the reveal step")
  return vacated
end

local function assertArrivalRevealsThroughTrail(w, arrival, partnerId)
  local controller, mgr = w.controller, w.mgr
  local vacated = committedStep(w, "north")
  Assert.isTrue(
    controller:isPartnerVisible(),
    "the first trail step re-shows the rejoined follower, like the retail step observation clearing HideUntilStep"
  )
  Assert.equal(mgr:partnerId(), partnerId, "the reveal keeps the one stable follower identity")
  Assert.equal(partnerCount(w), 1, "the reveal installs no second follower")
  local position = assert(mgr:getPosition(partnerId), "the revealed partner position is required")
  Assert.equal(position.fieldX, vacated.fieldX, "the revealed follower rests on the vacated player tile")
  Assert.equal(position.fieldZ, vacated.fieldZ, "the revealed follower rests on the vacated player tile")
  local next = committedStep(w, "north")
  local followed = assert(mgr:getPosition(partnerId), "the trailing partner position is required")
  Assert.equal(followed.fieldX, next.fieldX, "ordinary following resumes onto the next vacated tile")
  Assert.equal(followed.fieldZ, next.fieldZ, "ordinary following resumes onto the next vacated tile")
  Assert.isTrue(controller:isPartnerVisible(), "the follower stays visible while trailing")
end

function T.panel_arrival_hides_the_follower_on_tile_until_its_first_step()
  local w = world("panel")
  startWarp(w, "panel")
  driveToIdle(w)
  local partnerId = assertArrivedHiddenOnTile(w, "panel")
  assertArrivalRevealsThroughTrail(w, "panel", partnerId)
  w.mgr:dispose()
end

function T.profile8_preview_arrival_hides_the_follower_on_tile_until_its_first_step()
  local w = world("preview")
  startWarp(w, "preview")
  driveToIdle(w)
  local partnerId = assertArrivedHiddenOnTile(w, "profile-8 preview")
  assertArrivalRevealsThroughTrail(w, "profile-8 preview", partnerId)
  w.mgr:dispose()
end

return { tests = T }
