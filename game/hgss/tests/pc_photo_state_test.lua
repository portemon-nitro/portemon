-- The retained album projects sparse persisted slots and mutates only the
-- confirmed source slot; viewing returns to that same slot.

local Assert = require("tests.support.Assert")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local PhotoAlbum = require("libs.hgss.src.save.PhotoAlbum")
local PcApplicationHost = require("game.hgss.src.pc.PcApplicationHost")

local T = {}

local function photo(mapSymbol, fieldX)
  return {
    schema = "g4-photo-v1",
    icon = 1,
    playerName = "GOLD",
    playerGender = 0,
    leadNickname = "LEAF",
    avatarState = "normal",
    mapSymbol = mapSymbol,
    fieldX = fieldX,
    fieldZ = 9,
    date = { year = 2010, month = 1, day = 2, weekday = 6 },
    hour = 11,
    minute = 24,
    party = {
      { species = "CHIKORITA", form = 0, gender = 1, shiny = false },
      false,
      false,
      false,
      false,
      false,
    },
    sourcePartyCount = 1,
    hiddenPropModels = { false, false },
  }
end

local function seededAlbum()
  local album = PhotoAlbum.new()
  local prepared = assert(album:prepareChanges(0, {
    { slot = 0, value = photo("MAP_FIRST", 4) },
    { slot = 8, value = photo("MAP_SECOND", 8) },
    { slot = 35, value = photo("MAP_LAST", 12) },
  }))
  prepared.publish()
  return album
end

local function manifest()
  local sprites = {}
  for index = 1, 5 do
    sprites[index] = {
      animationSpeed = 0x1000,
      initiallyAnimating = index == 5,
      initiallyVisible = index ~= 2,
    }
  end
  local animations = {}
  for animationId = 0, 9 do
    animations[animationId] = {
      frames = {
        {
          image = "assets/generated/pc/test-photo-sprite.png",
          width = 8,
          height = 8,
          anchorX = 0,
          anchorY = 0,
          duration = 1,
        },
      },
    }
  end
  return {
    photoAlbum = {
      ui = {
        backgrounds = {
          albumCanvas = {
            image = "assets/generated/pc/test-photo-canvas.png",
            width = 256,
            height = 192,
            anchorX = 0,
            anchorY = 0,
          },
          albumControls = {
            image = "assets/generated/pc/test-photo-controls.png",
            width = 256,
            height = 192,
            anchorX = 0,
            anchorY = 0,
          },
        },
        sprites = sprites,
        animations = animations,
      },
      geometry = {
        list = { fixtureRows = 3 },
        actions = { fixtureItems = 3 },
        confirmation = { fixtureChoices = 2 },
      },
    },
  }
end

local function measurement()
  local width, height = 640, 480
  return {
    width = width,
    height = height,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = width, height = height },
      role = "world",
      touch = false,
    }),
    pixelRatio = 1,
    signature = "photo-album-test:640x480",
  }
end

local function implementation()
  local ok, state = pcall(require, "game.hgss.src.pc.PhotoAlbumScreenState")
  Assert.isTrue(ok, "the Photo Album list and view behavior is implemented")
  return assert(state)
end

function T.sparse_listing_view_back_and_confirmed_delete_keep_persisted_slots()
  local PhotoAlbumScreenState = implementation()
  local album = seededAlbum()
  local created = {}
  local state = PhotoAlbumScreenState.new({
    album = album,
    manifest = manifest(),
    measureDisplay = measurement,
    audio = function() end,
    profile = { name = "GOLD", gender = 0 },
    createScene = function(record, slot)
      created[#created + 1] = { record = record, slot = slot }
      local scene = { phase = "ready" }
      function scene:request(requested)
        self.record = requested
      end
      function scene:advance() end
      function scene:status()
        return { phase = self.phase, view = { mapSymbol = self.record.mapSymbol } }
      end
      function scene:takeReady()
        return self:status().view
      end
      function scene:cancel()
        self.phase = "cancelled"
      end
      function scene:dispose() end
      return scene
    end,
  })

  local opened = state:status()
  Assert.deepEqual(opened.occupiedSlots, { 0, 8, 35 }, "the list keeps sparse source slot identities")
  Assert.equal(opened.selectedSlot, 0, "the first occupied source slot is selected")

  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:status().phase, "actions", "confirm opens the selected photo actions")
  Assert.equal(state:status().selectedAction, "view", "view is the initial photo action")
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:status().phase, "viewer", "view opens the saved scene child")
  Assert.equal(state:status().viewer.phase, "ready", "the view exposes the ready child stage")
  Assert.equal(state:status().viewer.view.mapSymbol, "MAP_FIRST", "the status carries the saved scene view")
  Assert.equal(created[1].slot, 0, "view opens the selected persisted slot")
  Assert.equal(created[1].record.mapSymbol, "MAP_FIRST", "view receives a copied saved record")
  state:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(state:status().selectedSlot, 8, "next advances to the next occupied photo slot")
  Assert.equal(created[2].slot, 8, "next prepares the exact persisted slot")
  state:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.equal(state:status().selectedSlot, 0, "previous returns to the prior occupied photo slot")
  state:updateFixed({ { type = "cancel" } })
  Assert.equal(state:status().phase, "list", "back returns from the viewer to the album")
  Assert.equal(state:status().selectedSlot, 0, "back restores the same album slot")

  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(state:status().selectedSlot, 8, "navigation skips holes but retains the source slot")
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:status().phase, "actions", "confirm opens actions for the second persisted slot")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(state:status().selectedAction, "delete", "the action list exposes delete")
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:status().phase, "delete_confirm", "delete asks before changing the saved record")
  Assert.equal(album:get(8).mapSymbol, "MAP_SECOND", "opening delete confirmation does not mutate storage")
  state:updateFixed({ { type = "cancel" } })
  Assert.equal(album:get(8).mapSymbol, "MAP_SECOND", "cancelling deletion preserves the record")

  state:updateFixed({ { type = "confirm" } })
  state:updateFixed({ { type = "navigate", direction = "down" } })
  state:updateFixed({ { type = "confirm" } })
  state:updateFixed({ { type = "confirm" } })
  Assert.isNil(album:get(8), "only confirmed deletion clears the selected persisted slot")
  Assert.equal(album:get(0).mapSymbol, "MAP_FIRST", "neighboring records stay in their slots")
  Assert.equal(album:get(35).mapSymbol, "MAP_LAST", "the final sparse slot is retained")
  Assert.equal(album:revision(), 2, "view and cancelled deletion never revise the album")

  local restored = PhotoAlbum.new(album:capture())
  Assert.equal(restored:get(8), nil, "the deletion survives an owner reload")
  Assert.equal(state:status().selectedSlot, 35, "selection advances to the next occupied slot")

  for _, expectedSlot in ipairs({ 35, 0 }) do
    Assert.equal(state:status().selectedSlot, expectedSlot, "the cursor follows the remaining source slot")
    state:updateFixed({ { type = "confirm" } })
    state:updateFixed({ { type = "navigate", direction = "down" } })
    state:updateFixed({ { type = "confirm" } })
    state:updateFixed({ { type = "confirm" } })
  end
  Assert.deepEqual(state:status().occupiedSlots, {}, "deleting the last visible photo leaves an empty list")
  Assert.isNil(state:status().selectedSlot, "an empty list has no selected source slot")
  local emptyReload = PhotoAlbum.new(album:capture())
  Assert.isNil(emptyReload:get(0), "the empty slot zero survives owner reload")
  Assert.isNil(emptyReload:get(35), "the empty final slot survives owner reload")
  state:dispose()
end

function T.move_swaps_exact_sparse_slots_in_one_album_revision()
  local PhotoAlbumScreenState = implementation()
  local album = seededAlbum()
  local state = PhotoAlbumScreenState.new({
    album = album,
    manifest = manifest(),
    measureDisplay = measurement,
    profile = { name = "GOLD", gender = 0 },
  })

  state:updateFixed({ { type = "confirm" } })
  state:updateFixed({
    { type = "navigate", direction = "down" },
    { type = "navigate", direction = "down" },
  })
  Assert.equal(state:status().selectedAction, "move", "the source actions include Move in source order")
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:status().phase, "move_target", "Move asks for a destination photo")
  Assert.equal(state:status().sourceMessageId, 7, "the source move-target message is selected")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(state:status().selectedSlot, 8, "move target selection retains the destination source slot")
  state:updateFixed({ { type = "confirm" } })

  Assert.equal(album:get(0).mapSymbol, "MAP_SECOND", "the exact destination photo moves into the source slot")
  Assert.equal(album:get(8).mapSymbol, "MAP_FIRST", "the selected photo moves into the exact destination slot")
  Assert.equal(album:get(35).mapSymbol, "MAP_LAST", "other sparse source slots stay unchanged")
  Assert.equal(album:revision(), 2, "the two-slot swap publishes atomically in one revision")
  Assert.equal(state:status().phase, "list", "a completed move returns to the album list")
  Assert.equal(state:status().selectedSlot, 8, "selection follows the moved photo to its destination")
  Assert.equal(state:status().sourceMessageId, 8, "the source move-result message is shown")
  state:dispose()
end

function T.host_fixed_steps_prepare_viewer_and_stop_after_cancel()
  local PhotoAlbumScreenState = implementation()
  local album = PhotoAlbum.new()
  local prepared = assert(album:prepareChanges(0, {
    { slot = 0, value = photo("MAP_FIRST", 4) },
    { slot = 8, value = photo("MAP_SECOND", 8) },
  }))
  prepared.publish()
  local scenes = {}
  local owner = PcApplicationHost.new({
    createStorage = function() error("Storage is not opened") end,
    createMailbox = function() error("Mailbox is not opened") end,
    createPhotoAlbum = function()
      return PhotoAlbumScreenState.new({
        album = album,
        manifest = manifest(),
        measureDisplay = measurement,
        profile = { name = "GOLD", gender = 0 },
        createScene = function(record, slot)
          local scene = { record = record, slot = slot, work = 0, takeCount = 0, disposed = false }
          function scene:request() end
          function scene:advance(units)
            assert(not self.disposed, "a disposed saved-photo scene cannot progress")
            self.work = self.work + units
          end
          function scene:status()
            if self.work < 2 then
              return { phase = "pending" }
            end
            return { phase = "ready" }
          end
          function scene:takeReady()
            self.takeCount = self.takeCount + 1
            return { mapSymbol = self.record.mapSymbol, mapSectionNativeId = 7 }
          end
          function scene:cancel() end
          function scene:dispose()
            self.disposed = true
          end
          scenes[#scenes + 1] = scene
          return scene
        end,
      })
    end,
  })
  local handle = owner:open({ app = "photoAlbum" })
  owner:setPresentationReady(handle, true)

  owner:step(handle, { { type = "confirm" } })
  owner:step(handle, { { type = "confirm" } })
  Assert.equal(owner:status().viewer.phase, "pending", "opening View starts saved-map preparation")
  Assert.equal(scenes[1].work, 1, "the host fixed tick gives the active scene one work unit")
  owner:step(handle, {})
  Assert.equal(owner:status().viewer.phase, "ready", "an empty host tick completes the delayed view")
  Assert.equal(owner:status().viewer.view.mapSymbol, "MAP_FIRST", "the screen adopts the immutable saved view")
  Assert.equal(scenes[1].work, 2, "each fixed tick contributes exactly one work unit")
  Assert.equal(scenes[1].takeCount, 1, "the ready view is adopted once")

  owner:step(handle, { { type = "navigate", direction = "right" } })
  Assert.equal(#scenes, 2, "next opens a private scene for the adjacent saved photo")
  Assert.equal(scenes[2].work, 1, "the new scene receives the navigation tick's work unit")
  owner:step(handle, { { type = "cancel" } })
  Assert.equal(owner:status().phase, "list", "cancel closes the pending viewer")
  owner:step(handle, {})
  Assert.equal(scenes[2].work, 1, "closed viewer scenes receive no later fixed-tick work")
  Assert.isTrue(scenes[2].disposed, "closing the viewer disposes its private scene")
  owner:cancel("test complete")
end

function T.cancel_from_the_root_list_returns_to_the_parent_exactly_once()
  local PhotoAlbumScreenState = implementation()
  local state = PhotoAlbumScreenState.new({
    album = seededAlbum(),
    manifest = manifest(),
    measureDisplay = measurement,
    profile = { name = "GOLD", gender = 0 },
  })

  state:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(state:takeResult(), { kind = "closed" }, "the root list returns to its script parent")
  Assert.isNil(state:takeResult(), "the parent consumes the close result once")
  state:dispose()
end

function T.retained_album_publishes_a_drawable_application_plan()
  local PhotoAlbumScreenState = implementation()
  local state = PhotoAlbumScreenState.new({
    album = seededAlbum(),
    manifest = manifest(),
    measureDisplay = measurement,
    profile = { name = "GOLD", gender = 0 },
  })

  local status = state:status()
  Assert.equal(status.presentation.inputKey, "photo-album", "the retained album publishes its interface plan")
  Assert.equal(#status.presentation.panes, 1, "the album plan owns one interactive pane")
  state:dispose()
end

return { tests = T }
