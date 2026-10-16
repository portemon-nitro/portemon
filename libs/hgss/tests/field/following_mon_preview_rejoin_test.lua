-- Profile-8 preview follower rejoin at component scope (retail
-- MapPreviewGraphic_RunPlayerDropIn states 4-5 in pret/pokeheartgold
-- src/map_preview_graphic.c): with a follower in the party, a ladder-down
-- warp that runs the post-commit area preview must hand the follower back
-- onto the player tile, hidden until its first step, exactly once -- after
-- the preview-owned arrival completes, before the transition completes. The
-- real FollowingMonController, the real FieldActorManager, and the real
-- FieldPlayer/FieldTransition run here; only the party service is a
-- scriptable fake at its documented contract. The transition reaches the
-- follower through its optional follower collaborator (the selectPreview
-- injection pattern); the test-side adapter is built from existing
-- controller APIs only, so the observable contract -- position plus
-- visibility plus ordering -- never names controller internals.

local Assert = require("tests.support.Assert")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local FieldTransition = require("libs.hgss.src.transition.FieldTransition")
local FieldTransitionProfile = require("libs.hgss.src.transition.FieldTransitionProfile")
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

-- The component world: a follower in the party, installed behind the
-- player, ready to cross a profile-8 preview transition. The follower
-- adapter over the live controller is the proposed transition seam; it
-- uses existing controller APIs only.
local function world()
  local sourceMap = runtimeMap(61)
  local destinationMap = runtimeMap(62)
  local assets = fakeAssets({ [20153] = true, [20154] = true })
  local mgr = FieldActorManager.new({ assets = assets, policy = POLICY })
  mgr:enterMap(sourceMap, FieldEventState.new())
  local playerRef = {}
  playerRef.current = FieldPlayer.new({
    currentMap = sourceMap,
    fieldX = 6,
    fieldZ = 16,
    surfaceId = 0,
    facing = "south",
  })
  local svc = service()
  local catalog = CatalogFixture.makeCatalog()
  local controller = FollowingMonController.new({
    service = svc,
    catalog = catalog,
    actors = mgr,
    playerOf = function()
      return playerRef.current
    end,
    transition = {
      start = function()
        return true
      end,
    },
  })
  svc:setLead(0, mon())
  for _ = 1, 4 do
    controller:update()
  end
  local partnerId = assert(mgr:partnerId(), "setup installs the partner from the party lead")

  local rejoinCalls = {}
  local transition
  transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    player = playerRef.current,
    follower = {
      isPresent = function()
        return controller:isSourceActive()
      end,
      recall = function() end,
      rejoin = function(reason)
        rejoinCalls[#rejoinCalls + 1] = { reason = reason, arrival = transition.previewArrival }
        -- MoveToPlayer + hide-until-step equivalent through existing
        -- controller APIs: copy the committed player tile, then hide
        -- until the trail's first step reveals the partner again.
        controller:repositionRelativeToPlayer(9, 1)
        controller:hideForRecall()
      end,
    },
    resolveDestination = function()
      return {
        destinationMap = destinationMap,
        destinationWarp = { x = 6, z = 16 },
        fieldX = 6,
        fieldZ = 16,
        surfaceId = 0,
        worldY = 10,
        suppression = {},
      }
    end,
    prepare = function(resolution)
      return FieldPlayer.new({
        currentMap = resolution.destinationMap,
        fieldX = resolution.fieldX,
        fieldZ = resolution.fieldZ,
        surfaceId = resolution.surfaceId,
        facing = "south",
      })
    end,
    commit = function(_, _, prepared)
      -- The coordinator order: the follower clears before the old map
      -- leaves residency, then the new actor map publishes.
      controller:handleMapExit()
      mgr:enterMap(destinationMap, FieldEventState.new())
      playerRef.current = prepared
      transition.player = prepared
    end,
    selectPreview = function(_, _, profileId)
      return { imageKey = "preview.test", timeSlot = 1, profileId = profileId }
    end,
  })
  transition.player = playerRef.current
  return {
    mgr = mgr,
    controller = controller,
    playerRef = playerRef,
    transition = transition,
    rejoinCalls = rejoinCalls,
    setupPartnerId = partnerId,
  }
end

function T.profile8_preview_reinstalls_the_party_follower_hidden_on_the_player_tile()
  local w = world()
  w.transition:start({ mapId = 61 }, {
    kind = "generic",
    warp = { index = 0, x = 6, z = 16, destinationMapId = 62, destinationWarpId = 0 },
    transition = { mode = "fixed", profile = FieldTransitionProfile.LADDER_DOWN },
  }, "south")

  local ticks = 0
  while w.transition.phase ~= "idle" and w.transition.phase ~= "error" and ticks < 600 do
    ticks = ticks + 1
    w.transition:updateFixed()
    w.transition:updateSourceFrame()
    w.controller:update()
  end

  Assert.equal(w.transition.phase, "idle", "the profile-8 preview transition completes with a follower in party")
  Assert.equal(#w.rejoinCalls, 1, "the preview arrival rejoins the party follower exactly once")
  Assert.equal(w.rejoinCalls[1].reason, "preview", "the rejoin carries the preview arrival reason")
  Assert.equal(
    w.rejoinCalls[1].arrival,
    "done",
    "the rejoin fires only after the preview-owned vertical return completes"
  )

  local partnerId = assert(w.mgr:partnerId(), "the preview rejoin reinstalls the partner on the new map")
  local position = assert(w.mgr:getPosition(partnerId), "the reinstalled partner position is required")
  local player = w.playerRef.current
  Assert.equal(position.fieldX, player.fieldX, "the rejoined follower stands on the committed player tile")
  Assert.equal(position.fieldZ, player.fieldZ, "the rejoined follower stands on the committed player tile")
  Assert.isFalse(
    w.controller:isPartnerVisible(),
    "the rejoined follower stays hidden until its first trail step, like retail HideUntilStep"
  )
  w.mgr:dispose()
end

return { tests = T }
