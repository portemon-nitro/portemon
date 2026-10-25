-- Where the post-commit area-preview selection originates: the real field
-- world-swap coordinator injects one side-effect-free selector that reads only
-- the compiled field-entry manifest and the host-local clock. The source guard
-- is the original source map's environment (never the destination's), the
-- destination must be a listed preview destination, and the sampled hour picks
-- one of four immutable time slots. The transition engine consumes the
-- selector; this suite proves the selection owner in isolation.

local Assert = require("tests.support.Assert")
local FieldEntryAssetCache = require("libs.assets.src.field.FieldEntryAssetCache")
local FieldWorldSwapCoordinator = require("game.hgss.src.field.FieldWorldSwapCoordinator")

local T = {}

local LISTED_OUTDOOR = 60
local LISTED_CAVE = 176
local UNLISTED = 999

-- The compiled field-entry manifest the runtime borrows as a strict structural
-- contract: nine banner styles with their own text palettes and the
-- per-destination four preview slots. Every indexed asset is referenced.
local function previewManifest()
  local assets = {}
  local bannerStyles = {}
  local bannerTextPalettes = {}
  for style = 0, FieldEntryAssetCache.BANNER_STYLE_COUNT - 1 do
    local key = "banner." .. style
    assets[key] = {
      image = FieldEntryAssetCache.assetDir() .. "/banner-" .. style .. ".png",
      width = FieldEntryAssetCache.BANNER_WIDTH,
      height = FieldEntryAssetCache.BANNER_HEIGHT,
    }
    bannerStyles[style] = key
    bannerTextPalettes[style] = {
      foreground = { r = 248, g = 248, b = 248 },
      shadow = { r = 88, g = 88, b = 88 },
      background = { r = 0, g = 0, b = 0 },
    }
  end
  local function slots(prefix)
    local set = {}
    for slot = 0, FieldEntryAssetCache.PREVIEW_SLOTS - 1 do
      local key = prefix .. "." .. slot
      assets[key] = {
        image = FieldEntryAssetCache.assetDir() .. "/" .. prefix .. "-" .. slot .. ".png",
        width = FieldEntryAssetCache.PREVIEW_WIDTH,
        height = FieldEntryAssetCache.PREVIEW_HEIGHT,
      }
      set[slot] = key
    end
    return set
  end
  return {
    schema = FieldEntryAssetCache.SCHEMA,
    reference = { width = FieldEntryAssetCache.PREVIEW_WIDTH, height = FieldEntryAssetCache.PREVIEW_HEIGHT },
    assets = assets,
    bannerStyles = bannerStyles,
    bannerTextPalettes = bannerTextPalettes,
    bannerStyleByMapId = { [LISTED_OUTDOOR] = 1 },
    previewByMapId = {
      [LISTED_OUTDOOR] = slots("preview.60"),
      [LISTED_CAVE] = slots("preview.176"),
    },
  }
end

-- The host-local clock boundary: reports one local civil hour and counts how
-- many times the selection owner samples it.
local function clockAt(hour)
  local clock = { hour = hour, samples = 0 }
  clock.nowLocal = function(self)
    self.samples = self.samples + 1
    return { hour = self.hour }
  end
  return clock
end

local function mapAt(mapId, environment)
  return { mapId = mapId, fieldData = { transitionEnvironment = environment } }
end

local function selector(manifest, clock)
  local runtime = {
    mapLoader = {
      requestWarp = function()
        return true
      end,
    },
    fieldEntryManifest = manifest,
    localClock = clock,
  }
  local coordinator = FieldWorldSwapCoordinator.new(runtime)
  local transition = coordinator:createTransition(runtime, nil, nil, function() end)
  Assert.isTrue(
    type(transition.selectPreview) == "function",
    "the world-swap coordinator injects the post-commit preview selector"
  )
  return transition.selectPreview
end

function T.the_source_environment_guards_the_preview_independently_of_the_destination()
  local manifest = previewManifest()
  local select = selector(manifest, clockAt(12))

  local outdoor = select(mapAt(33, "outdoors"), mapAt(LISTED_OUTDOOR, "outdoors"), 0)
  Assert.notNil(outdoor, "an outdoor source into a listed destination selects its preview")

  Assert.isNil(
    select(mapAt(176, "cave"), mapAt(LISTED_OUTDOOR, "outdoors"), 0),
    "a cave source never selects a preview, even for a listed destination"
  )

  Assert.notNil(
    select(mapAt(33, "outdoors"), mapAt(LISTED_CAVE, "cave"), 0),
    "an eligible destination may itself be a cave map; the guard reads the source only"
  )
end

function T.an_unlisted_destination_selects_no_preview()
  local manifest = previewManifest()
  local select = selector(manifest, clockAt(12))
  Assert.isNil(
    select(mapAt(33, "outdoors"), mapAt(UNLISTED, "cave"), 0),
    "a destination without compiled preview slots selects nothing"
  )
end

function T.the_sampled_hour_selects_the_exact_time_slot()
  local manifest = previewManifest()
  local clock = clockAt(0)
  local select = selector(manifest, clock)
  local slots = assert(manifest.previewByMapId[LISTED_OUTDOOR])
  for _, case in ipairs({
    { hour = 0, slot = 3 },
    { hour = 3, slot = 3 },
    { hour = 4, slot = 0 },
    { hour = 9, slot = 0 },
    { hour = 10, slot = 1 },
    { hour = 16, slot = 1 },
    { hour = 17, slot = 2 },
    { hour = 19, slot = 2 },
    { hour = 20, slot = 3 },
    { hour = 23, slot = 3 },
  }) do
    clock.hour = case.hour
    local selected = assert(
      select(mapAt(33, "outdoors"), mapAt(LISTED_OUTDOOR, "outdoors"), 0),
      "hour " .. case.hour .. " selects a listed preview"
    )
    Assert.equal(selected.timeSlot, case.slot, "hour " .. case.hour .. " maps to its source time slot")
    Assert.equal(selected.imageKey, slots[case.slot], "the slot resolves the manifest's semantic image key")
  end
end

function T.the_clock_is_sampled_once_per_selection()
  local manifest = previewManifest()
  local clock = clockAt(12)
  local select = selector(manifest, clock)
  Assert.equal(clock.samples, 0, "no selection samples the clock before it is asked")
  select(mapAt(33, "outdoors"), mapAt(LISTED_OUTDOOR, "outdoors"), 0)
  Assert.equal(clock.samples, 1, "one committed selection samples the clock exactly once")
  select(mapAt(33, "outdoors"), mapAt(LISTED_OUTDOOR, "outdoors"), 0)
  Assert.equal(clock.samples, 2, "each committed selection samples the clock exactly once")
end

function T.the_selection_snapshot_carries_the_profile_id_and_a_frozen_key()
  local manifest = previewManifest()
  local clock = clockAt(12)
  local select = selector(manifest, clock)
  local selected =
    assert(select(mapAt(33, "outdoors"), mapAt(LISTED_CAVE, "cave"), 8), "the listed destination selects")
  Assert.equal(selected.profileId, 8, "the selection carries the originating transition profile")
  Assert.equal(
    selected.imageKey,
    assert(manifest.previewByMapId[LISTED_CAVE])[1],
    "the selection names the slot image key"
  )
  Assert.equal(selected.timeSlot, 1, "the selection names the sampled slot")
  Assert.keySet(selected, "imageKey,profileId,timeSlot", "the selection snapshot is only its frozen fields")
end

function T.a_malformed_clock_hour_or_missing_slot_fails_loudly()
  local manifest = previewManifest()
  local clock = clockAt(12)
  local select = selector(manifest, clock)
  for _, malformed in ipairs({ -1, 24 }) do
    clock.hour = malformed
    Assert.throws(function()
      select(mapAt(33, "outdoors"), mapAt(LISTED_OUTDOOR, "outdoors"), 0)
    end, "a malformed local clock hour must fail selection: " .. tostring(malformed))
  end

  local missingNight = previewManifest()
  local partial = { [0] = assert(missingNight.previewByMapId[LISTED_OUTDOOR])[0] }
  partial[1] = assert(missingNight.previewByMapId[LISTED_OUTDOOR])[1]
  partial[2] = assert(missingNight.previewByMapId[LISTED_OUTDOOR])[2]
  missingNight.previewByMapId[LISTED_OUTDOOR] = partial
  local partialSelect = selector(missingNight, clockAt(22))
  Assert.throws(function()
    partialSelect(mapAt(33, "outdoors"), mapAt(LISTED_OUTDOOR, "outdoors"), 0)
  end, "a listed destination missing its selected slot fails selection")
end

return { tests = T }
