-- FollowMonReleaseNextToPlayer at component scope (pret/pokeheartgold
-- src/scrcmd_c.c ScrCmd_FollowMonReleaseNextToPlayer): with an active
-- follower permitted on the current map, the partner lands on the player
-- tile facing south with its visibility left alone -- a visible partner
-- stays visible through stationary ticks, a hidden partner stays hidden.
-- Without a follower, or where the map forbids following, it reports false
-- and touches nothing. Genuine map arrivals instead rejoin hidden until the
-- first trail step; the release command never arms that arrival latch. The
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

local PLAYER_TILE = { fieldX = 6, fieldZ = 16 }

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
    fieldX = PLAYER_TILE.fieldX,
    fieldZ = PLAYER_TILE.fieldZ,
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

local function tickStationary(w, count)
  for _ = 1, count do
    w.controller:update()
  end
end

local function drainPlayerStep(w)
  for _ = 1, 12 do
    if w.player.current.motion ~= "idle" then
      w.player.current:updateFixed({})
    end
    w.controller:update()
  end
end

local function assertOnPlayerTile(w, partnerId, what)
  local position = w.manager:getPosition(partnerId)
  Assert.equal(position.fieldX, PLAYER_TILE.fieldX, what .. " keeps the player fieldX")
  Assert.equal(position.fieldZ, PLAYER_TILE.fieldZ, what .. " keeps the player fieldZ")
  local actor = assert(w.manager:getById(partnerId), "the release keeps the installed partner")
  Assert.equal(actor.facing, "south", what .. " faces the partner south")
end

function T.visible_release_keeps_the_partner_visible_through_stationary_ticks()
  local w = world("ALLOW")
  local partnerId = installFollower(w, 0)
  w.manager:show(partnerId)
  Assert.isTrue(w.controller:releaseNextToPlayer(), "the permitted release acts")
  assertOnPlayerTile(w, partnerId, "the release")
  Assert.isTrue(w.manager:isVisible(partnerId), "the release preserves a visible partner")
  Assert.isTrue(w.controller:isMovementSettled(), "the release leaves no stale trail behind")
  tickStationary(w, 8)
  Assert.isTrue(w.manager:isVisible(partnerId), "stationary ticks keep the partner visible with no trail step")
  assertOnPlayerTile(w, partnerId, "the stationary release")
  w.manager:dispose()
end

function T.release_cancels_an_in_flight_trail_without_touching_visibility()
  local w = world("ALLOW")
  local partnerId = installFollower(w, 0)
  w.manager:show(partnerId)
  Assert.isTrue(w.player.current:tryStep("south"), "the fixture step must start")
  w.controller:update()
  Assert.isFalse(w.controller:isMovementSettled(), "the step starts a real follower trail")
  Assert.isTrue(w.controller:releaseNextToPlayer(), "the permitted release acts")
  Assert.isTrue(w.controller:isMovementSettled(), "the release drops the stale trail")
  assertOnPlayerTile(w, partnerId, "the release")
  Assert.isTrue(w.manager:isVisible(partnerId), "the release preserves a visible partner")
  w.manager:dispose()
end

function T.hidden_release_keeps_the_partner_hidden_through_stationary_ticks()
  local w = world("ALLOW")
  local partnerId = installFollower(w, 0)
  w.manager:hide(partnerId)
  Assert.isTrue(w.controller:releaseNextToPlayer(), "the permitted release acts")
  assertOnPlayerTile(w, partnerId, "the release")
  Assert.isFalse(w.manager:isVisible(partnerId), "the release never shows a hidden partner")
  tickStationary(w, 8)
  Assert.isFalse(w.manager:isVisible(partnerId), "stationary ticks keep the partner hidden")
  assertOnPlayerTile(w, partnerId, "the stationary release")
  w.manager:dispose()
end

function T.without_a_follower_the_release_reports_false_and_touches_nothing()
  local w = world("ALLOW")
  Assert.isFalse(w.controller:releaseNextToPlayer(), "no follower means no release")
  Assert.isNil(w.manager:partnerId(), "the refusal installs nothing")
  w.manager:dispose()
end

function T.a_forbidden_map_refuses_without_moving_the_partner()
  local w = world("ALLOW")
  local partnerId = installFollower(w, 0)
  w.manager:show(partnerId)
  w.map.followMode = "PREVENT"
  local before = w.manager:getPosition(partnerId)
  Assert.isFalse(w.controller:releaseNextToPlayer(), "a forbidden map refuses the release")
  local after = w.manager:getPosition(partnerId)
  Assert.equal(after.fieldX, before.fieldX, "the refusal leaves the partner where it stands")
  Assert.equal(after.fieldZ, before.fieldZ, "the refusal leaves the partner where it stands")
  Assert.isTrue(w.manager:isVisible(partnerId), "the refusal leaves visibility alone")
  w.manager:dispose()
end

function T.arrival_rejoin_hides_until_the_first_trail_step()
  local w = world("ALLOW")
  local partnerId = installFollower(w, 0)
  w.manager:show(partnerId)
  w.controller:rejoin("panel")
  assertOnPlayerTile(w, partnerId, "the arrival rejoin")
  Assert.isFalse(w.manager:isVisible(partnerId), "the arrival hides the rejoined partner")
  tickStationary(w, 6)
  Assert.isFalse(w.manager:isVisible(partnerId), "stationary ticks keep the arrival hidden")
  assertOnPlayerTile(w, partnerId, "the stationary arrival")
  Assert.isTrue(w.player.current:tryStep("south"), "the fixture step must start")
  w.controller:update()
  Assert.isTrue(w.manager:isVisible(partnerId), "the first observed trail step reveals the rejoined partner")
  drainPlayerStep(w)
  Assert.isTrue(w.manager:isVisible(partnerId), "the revealed partner stays visible")
  Assert.isTrue(w.controller:isMovementSettled(), "the arrival trail settles")
  Assert.equal(w.player.current.fieldZ, PLAYER_TILE.fieldZ + 1, "the player commits one tile south")
  local position = w.manager:getPosition(partnerId)
  Assert.equal(position.fieldZ, PLAYER_TILE.fieldZ, "the satisfied first step leaves the partner on the vacated tile")
  w.manager:dispose()
end

return { tests = T }
