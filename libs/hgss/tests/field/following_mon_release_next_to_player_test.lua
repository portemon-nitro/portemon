-- FollowMonReleaseNextToPlayer at component scope (pret/pokeheartgold
-- src/scrcmd_c.c ScrCmd_FollowMonReleaseNextToPlayer): with an active
-- follower permitted on the current map, the partner lands next to the
-- player hidden until its first trail step; without a follower, or where
-- the map forbids following, it reports false and touches nothing. The
-- real FollowingMonController, the real FieldActorManager, and a live
-- player run here; only the party service is a scriptable fake at its
-- documented contract.

local Assert = require("tests.support.Assert")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
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

local function runtimeMap(mapId, followMode)
  return {
    mapId = mapId,
    mapSection = "test-section",
    mapSectionNativeId = 7,
    followMode = followMode or "ALLOW",
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

local function world(followMode)
  local sourceMap = runtimeMap(61, followMode)
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
  return { manager = mgr, player = playerRef, service = svc, controller = controller, map = sourceMap }
end

local function installFollower(w, slot)
  w.service:setLead(slot, mon())
  for _ = 1, 4 do
    w.controller:update()
  end
  return assert(w.manager:partnerId(), "setup installs the partner from the party lead")
end

function T.active_permitted_follower_lands_hidden_next_to_the_player()
  local w = world("ALLOW")
  local partnerId = installFollower(w, 0)
  w.manager:show(partnerId)
  Assert.isTrue(w.controller:releaseNextToPlayer(), "the permitted release acts")
  local snapshot = w.manager:getById(partnerId)
  Assert.notNil(snapshot, "the release keeps the installed partner")
  local position = w.manager:getPosition(partnerId)
  Assert.equal(position.fieldX, 6, "the release moves the partner onto the player tile")
  Assert.equal(position.fieldZ, 16)
  Assert.isFalse(w.manager:isVisible(partnerId), "the release hides until the first trail step")
end

function T.without_a_follower_the_release_reports_false_and_touches_nothing()
  local w = world("ALLOW")
  Assert.isFalse(w.controller:releaseNextToPlayer(), "no follower means no release")
  Assert.isNil(w.manager:partnerId(), "the refusal installs nothing")
end

function T.a_forbidden_map_refuses_without_moving_the_partner()
  local w = world("ALLOW")
  local partnerId = installFollower(w, 0)
  w.map.followMode = "PREVENT"
  local before = w.manager:getPosition(partnerId)
  Assert.isFalse(w.controller:releaseNextToPlayer(), "a forbidden map refuses the release")
  local after = w.manager:getPosition(partnerId)
  Assert.equal(after.fieldX, before.fieldX, "the refusal leaves the partner where it stands")
  Assert.equal(after.fieldZ, before.fieldZ, "the refusal leaves the partner where it stands")
end

return { tests = T }
