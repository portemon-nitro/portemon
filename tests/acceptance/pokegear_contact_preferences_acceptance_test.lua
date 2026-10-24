-- Source-backed phonebook and preference behavior through the production
-- field runtime, gear shell, input path, and save store.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local Fixture = require("tests.support.PokegearJourneyFixture")
local PokegearCache = require("libs.assets.src.PokegearCache")
local CacheFs = require("libs.storage.src.CacheFs")

local DERIVED_ASSETS = {}
for _, key in ipairs(Fixture.JOURNEY_ASSETS) do
  DERIVED_ASSETS[#DERIVED_ASSETS + 1] = key
end
-- The setup card reads its CHANGE/QUIT context labels from bank 270.
DERIVED_ASSETS[#DERIVED_ASSETS + 1] = "message-bank:270"

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = DERIVED_ASSETS,
    tags = { "pokegear" },
  },
  tests = {},
}

local function direction(game, value)
  local fieldDirection = ({ up = "north", down = "south", left = "west", right = "east" })[value]
  assert(fieldDirection ~= nil, "acceptance input maps UI directions to field directions")
  game.runtime:press(fieldDirection)
  game:step()
  game.runtime:release(fieldDirection)
end

local function confirm(game)
  game.runtime:pressAction()
  game:step()
  game.runtime:releaseAction()
end

local function cancel(game)
  game.runtime:pressCancel()
  game:step()
  game.runtime:releaseCancel()
end

local function application(game)
  return assert(game.runtime.applicationHost:status().application, "the open gear publishes its application view")
end

local function openConfigure(game)
  Fixture.openGearThroughMenu(game)
  cancel(game)
  direction(game, "left")
  confirm(game)
  Assert.equal(application(game).tab, "configure", "the Configure card opens through the gear strip")
end

local function nativeMom(catalog)
  local found = nil
  for _, contact in ipairs(catalog.contacts) do
    if contact.id == 0 then
      Assert.equal(contact.family, "mother", "native phonebook contact zero is Mom")
      Assert.isTrue(found == nil, "the source catalog defines one native contact zero")
      found = contact
    end
  end
  return assert(found, "the compiled HGSS catalog contains native phonebook contact zero")
end

function T.tests.fresh_and_saved_field_bootstrap_register_native_mom_once()
  Fixture.withGame(Fixture.TOWN, function(game)
    local manifest = PokegearCache.loadManifest(CacheFs.forVersion(AcceptanceHarness.defaultVersion()))
    local catalog = assert(manifest.catalog, "the prepared ROM cache publishes the phone catalog")
    local mom = nativeMom(catalog)
    local state = assert(game.runtime.pokegearState, "the field runtime owns phonebook state")

    Assert.deepEqual(
      state:readPhone().contactOrder,
      { mom.key },
      "a fresh field runtime registers only Mom from native phonebook defaults"
    )
    Assert.deepEqual(state:readPhone().contacts, { [mom.key] = {} }, "Mom is registered through the phonebook owner")

    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_SAVE_BUTTON })
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })
    Fixture.saveAndReload(game)
    state = assert(game.runtime.pokegearState, "the loaded field runtime owns restored phonebook state")
    Assert.deepEqual(state:readPhone().contactOrder, { mom.key }, "the real save roundtrip retains exactly one Mom row")

    local revision = state:revision()
    state:registerContact(mom.key)
    Assert.equal(state:revision(), revision, "registering the already seeded Mom is a no-op")
    game:restart()
    state = assert(game.runtime.pokegearState, "the repeated runtime bind retains its phonebook owner")
    Assert.deepEqual(state:readPhone().contactOrder, { mom.key }, "repeated composition does not duplicate Mom")
    Assert.equal(game:renderAttempts(), 0, "phonebook acceptance stops before GPU rendering")
  end)
end

function T.tests.saved_v9_skin_subset_can_select_and_persist_skin_five()
  Fixture.withGame(Fixture.TOWN, function(game)
    local state = assert(game.runtime.pokegearState, "the field runtime owns Configure preferences")
    state:setPreference("skin", 0)
    state:setPreference("unlockedSkins", { 0 })
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_SAVE_BUTTON })
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })
    Fixture.saveAndReload(game)

    state = assert(game.runtime.pokegearState, "the restored field runtime owns old v9 preferences")
    Assert.deepEqual(
      state:readPreferences().unlockedSkins,
      { 0, 1, 2, 3, 4, 5 },
      "runtime binding publishes all six source Configure skins for an older valid preference subset"
    )
    openConfigure(game)
    Assert.deepEqual(application(game).unlockedSkins, { 0, 1, 2, 3, 4, 5 }, "all six Configure cells are enabled")
    -- Right wraps within its row and down crosses rows, so skin five is
    -- right, right, down from skin zero.
    direction(game, "right")
    direction(game, "right")
    direction(game, "down")
    confirm(game)
    Assert.isTrue(application(game).child.menuOpen, "skin five opens its normal Configure selection menu")
    confirm(game)
    Assert.equal(state:readPreferences().skin, 5, "the player can select skin five through production input")

    Fixture.closeGearThroughMenu(game)
    Fixture.saveAndReload(game)
    state = assert(game.runtime.pokegearState, "the reloaded runtime restores the selected skin")
    Assert.equal(state:readPreferences().skin, 5, "the real save pipeline persists skin five")
    Assert.deepEqual(
      state:readPreferences().unlockedSkins,
      { 0, 1, 2, 3, 4, 5 },
      "all six styles remain available after reload"
    )
    Assert.equal(game:renderAttempts(), 0, "Configure acceptance stops before GPU rendering")
  end)
end

function T.tests.manual_phone_order_is_shown_moved_and_saved_independently_of_auto_sort()
  Fixture.withGame(Fixture.TOWN, function(game)
    local manifest = PokegearCache.loadManifest(CacheFs.forVersion(AcceptanceHarness.defaultVersion()))
    local catalog = assert(manifest.catalog, "the prepared ROM cache publishes native contact identities")
    local mom = nativeMom(catalog)
    local keys = { mom.key }
    for _, contact in ipairs(catalog.contacts) do
      if contact.id ~= 0 and #keys < 3 then
        keys[#keys + 1] = contact.key
      end
    end
    Assert.equal(#keys, 3, "the compiled catalog provides two additional source contacts")
    local state = assert(game.runtime.pokegearState, "the field runtime owns phone ordering")
    for _, key in ipairs(keys) do
      state:registerContact(key)
    end
    local sourceOrder = state:readPhone().contactOrder
    local manualOrder = { sourceOrder[3], sourceOrder[1], sourceOrder[2] }
    state:setContactOrder(manualOrder)
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_SAVE_BUTTON })
    game:setWorldState({ flag = Fixture.FLAGS.FLAG_GOT_POKEGEAR })

    Fixture.openGearThroughMenu(game)
    local phone = assert(application(game).child.view, "the phone card publishes its real catalog rows")
    local visible = {}
    for _, row in ipairs(phone.list.rows) do
      visible[#visible + 1] = row.contact
    end
    Assert.deepEqual(visible, manualOrder, "the Phone card opens in the saved manual order")

    confirm(game)
    direction(game, "down")
    confirm(game)
    for _ = 1, 3 do
      direction(game, "down")
    end
    confirm(game)
    confirm(game)
    direction(game, "down")
    direction(game, "down")
    confirm(game)
    local moved = { manualOrder[2], manualOrder[3], manualOrder[1] }
    Assert.deepEqual(
      state:readPhone().contactOrder,
      moved,
      "manual Move updates the durable order through the Phone UI"
    )

    confirm(game)
    direction(game, "down")
    confirm(game)
    confirm(game)
    Assert.deepEqual(state:readPhone().contactOrder, moved, "automatic Title sort changes only the session view")

    Fixture.closeGearThroughMenu(game)
    Fixture.saveAndReload(game)
    state = assert(game.runtime.pokegearState, "the loaded runtime restores the manually moved order")
    Assert.deepEqual(state:readPhone().contactOrder, moved, "the real save pipeline preserves manual order")
    Fixture.openGearThroughMenu(game)
    phone = assert(application(game).child.view, "the reopened Phone card publishes rows")
    visible = {}
    for _, row in ipairs(phone.list.rows) do
      visible[#visible + 1] = row.contact
    end
    Assert.deepEqual(visible, moved, "reopening Phone after reload reproduces manual order")
    Assert.equal(game:renderAttempts(), 0, "phone ordering acceptance stops before GPU rendering")
  end)
end

return T
