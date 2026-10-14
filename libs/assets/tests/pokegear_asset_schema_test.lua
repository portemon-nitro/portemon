-- The Pokegear asset manifest is a closed source-neutral contract: valid
-- custom records validate without ROM identities, duplicate semantic keys
-- and dangling order references fail naming the offender, malformed visuals
-- and animations are rejected, and unknown top-level sections never pass.

local Assert = require("tests.support.Assert")
local PokegearRegionMapFixture = require("tests.support.PokegearRegionMapFixture")

local T = {}

local function visualRef(path)
  return { image = path, width = 64, height = 64, anchorX = 0, anchorY = 0 }
end

local function customManifest()
  return {
    schema = "g4-pokegear-assets-v3",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png") },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png") },
    phone = { panel = visualRef("assets/generated/pokegear/phone-panel.png") },
    map = { base = visualRef("assets/generated/pokegear/map-base.png") },
    fly = { base = visualRef("assets/generated/pokegear/fly-base.png") },
    radio = { dial = visualRef("assets/generated/pokegear/radio-dial.png") },
    catalog = {
      contacts = {
        { key = "custom.elm", sortWeight = 10 },
        { key = "custom.mom", sortWeight = 20 },
      },
      contactOrder = { "custom.elm", "custom.mom" },
      callDefinitions = {},
      callTriggers = {},
      rematches = {},
      gifts = {},
      momPurchases = {},
      locations = {},
      flypoints = {},
      reception = {},
      shows = {
        { key = "custom.morning-show", title = "Custom Morning" },
      },
      radioEffects = {},
      regionMap = PokegearRegionMapFixture.build(),
    },
    text = {},
    sequences = {},
  }
end

function T.valid_custom_records_validate_without_source_identities()
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record, err = PokegearAssetSchema.validate(customManifest())
  Assert.notNil(record, "valid custom records must validate: " .. tostring(err and err.message or err))
  Assert.equal(record.schema, "g4-pokegear-assets-v3", "validation preserves the schema identity")
end

function T.region_map_is_required_and_strict()
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local function rejects(mutate, message)
    local manifest = customManifest()
    mutate(manifest.catalog.regionMap, manifest.catalog)
    local record, err = PokegearAssetSchema.validate(manifest)
    Assert.isNil(record, message)
    Assert.equal(err.code, PokegearAssetSchema.ERROR.SHAPE_INVALID, message)
  end
  rejects(function(_, catalog)
    catalog.regionMap = nil
  end, "a missing regionMap must not validate")
  rejects(function(regionMap)
    regionMap.locations = {}
  end, "an empty location list must not validate")
  rejects(function(regionMap)
    regionMap.flypoints[1].overlay.destX = 16
  end, "a bitfield-sized overlay value above 15 must not validate")
  rejects(function(regionMap)
    regionMap.locations[1].x = 1.5
  end, "a fractional coordinate must not validate")
  rejects(function(regionMap)
    regionMap.locations[1].extra = 1
  end, "an unexpected location key must not validate")
  rejects(function(regionMap)
    regionMap.flypoints[1].overlay.srcX = nil
  end, "a missing overlay key must not validate")
end

function T.friend_map_phrase_rows_preserve_a_strict_source_order_contract()
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local manifest = customManifest()
  manifest.catalog.friendMapPhrases = {}
  for index = 1, 73 do
    manifest.catalog.friendMapPhrases[index] = {
      mapId = index - 1,
      sourceIndex = index - 1,
      unlockGroup = index % 4,
    }
  end
  local valid, validErr = PokegearAssetSchema.validate(manifest)
  Assert.notNil(valid, "73 ordered Friend map records validate: " .. tostring(validErr and validErr.message or validErr))

  manifest.catalog.friendMapPhrases[4].extra = true
  local invalid, err = PokegearAssetSchema.validate(manifest)
  Assert.isNil(invalid, "Friend map records reject unknown nested fields")
  Assert.equal(err.code, PokegearAssetSchema.ERROR.SHAPE_INVALID, "unknown Friend fields return a schema error")
end

function T.duplicate_contact_keys_fail_naming_the_offender()
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local manifest = customManifest()
  manifest.catalog.contacts[2].key = "custom.elm"
  local record, err = PokegearAssetSchema.validate(manifest)
  Assert.isNil(record, "duplicate contact keys must not validate")
  Assert.notNil(err, "duplicate contact keys must carry an error")
  Assert.notNil(
    tostring(err.message or err):find("custom.elm", 1, true),
    "the duplicate failure must name the offending key"
  )
end

function T.dangling_order_references_fail_naming_the_missing_key()
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local manifest = customManifest()
  manifest.catalog.contactOrder = { "custom.elm", "custom.ghost" }
  local record, err = PokegearAssetSchema.validate(manifest)
  Assert.isNil(record, "a dangling order reference must not validate")
  Assert.notNil(err, "a dangling order reference must carry an error")
  Assert.notNil(
    tostring(err.message or err):find("custom.ghost", 1, true),
    "the dangling failure must name the missing reference"
  )
end

function T.duplicate_show_keys_fail_precisely()
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local manifest = customManifest()
  manifest.catalog.shows[2] = { key = "custom.morning-show", title = "Copy" }
  local record, err = PokegearAssetSchema.validate(manifest)
  Assert.isNil(record, "duplicate show keys must not validate")
  Assert.notNil(
    tostring((err or {}).message or err):find("custom.morning-show", 1, true),
    "the duplicate show failure must name the offending key"
  )
end

function T.malformed_visuals_are_rejected()
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local manifest = customManifest()
  manifest.shell.foreground.width = 0
  local record, err = PokegearAssetSchema.validate(manifest)
  Assert.isNil(record, "a zero-width visual must not validate")
  Assert.notNil(err, "a zero-width visual must carry an error")

  local escaped = customManifest()
  escaped.shell.foreground.image = "assets/generated/pokegear/../outside.png"
  local escapedRecord, escapedErr = PokegearAssetSchema.validate(escaped)
  Assert.isNil(escapedRecord, "an escaping asset path must not validate")
  Assert.notNil(escapedErr, "an escaping asset path must carry an error")

  local foreign = customManifest()
  foreign.shell.foreground.image = "assets/generated/pc/storage-box-pane.png"
  local foreignRecord = PokegearAssetSchema.validate(foreign)
  Assert.isNil(foreignRecord, "a visual outside the pokegear family must not validate")
end

function T.animations_keep_loop_behavior_as_play_mode_plus_loop_start()
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local manifest = customManifest()
  manifest.sequences = {
    cursor = {
      frames = {
        {
          image = "assets/generated/pokegear/cursor-0.png",
          width = 16,
          height = 16,
          anchorX = 0,
          anchorY = 0,
          duration = 8,
        },
        {
          image = "assets/generated/pokegear/cursor-1.png",
          width = 16,
          height = 16,
          anchorX = 1,
          anchorY = 0,
          duration = 8,
        },
      },
      playMode = "forward_loop",
      loopStart = 0,
    },
  }
  local record, err = PokegearAssetSchema.validate(manifest)
  Assert.notNil(record, "a well-formed animation must validate: " .. tostring(err and err.message or err))

  local booleanLoop = customManifest()
  booleanLoop.sequences = {
    cursor = {
      frames = {
        {
          image = "assets/generated/pokegear/cursor-0.png",
          width = 16,
          height = 16,
          anchorX = 0,
          anchorY = 0,
          duration = 8,
        },
      },
      playMode = "forward_loop",
      loopStart = 0,
      loop = true,
    },
  }
  Assert.isNil(PokegearAssetSchema.validate(booleanLoop), "loop behavior reduced to a boolean must not validate")

  local frameRate = customManifest()
  frameRate.sequences = {
    cursor = {
      frames = {
        {
          image = "assets/generated/pokegear/cursor-0.png",
          width = 16,
          height = 16,
          anchorX = 0,
          anchorY = 0,
          duration = 8,
        },
      },
      playMode = "forward",
      loopStart = 0,
      fps = 30,
    },
  }
  Assert.isNil(PokegearAssetSchema.validate(frameRate), "a frame rate shorthand must not validate")

  local zeroDuration = customManifest()
  zeroDuration.sequences = {
    cursor = {
      frames = {
        {
          image = "assets/generated/pokegear/cursor-0.png",
          width = 16,
          height = 16,
          anchorX = 0,
          anchorY = 0,
          duration = 0,
        },
      },
      playMode = "forward",
      loopStart = 0,
    },
  }
  Assert.isNil(PokegearAssetSchema.validate(zeroDuration), "a zero frame duration must not validate")
end

function T.closed_manifest_rejects_unknown_sections_and_bad_schemas()
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local extra = customManifest()
  extra.wordEntry = {}
  Assert.isNil(PokegearAssetSchema.validate(extra), "an unknown top-level section must not validate")

  local wrongSchema = customManifest()
  wrongSchema.schema = "g4-pokegear-assets-v0"
  Assert.isNil(PokegearAssetSchema.validate(wrongSchema), "a stale schema identity must not validate")

  local missing = customManifest()
  missing.radio = nil
  Assert.isNil(PokegearAssetSchema.validate(missing), "a missing required section must not validate")
end

function T.contact_keys_require_a_namespace()
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local manifest = customManifest()
  manifest.catalog.contacts[1].key = "elm"
  local record, err = PokegearAssetSchema.validate(manifest)
  Assert.isNil(record, "an unnamespaced contact key must not validate")
  Assert.notNil(err, "an unnamespaced contact key must carry an error")
end

local WORD_BANKS = { 237, 751, 735, 721, 285, 286, 287, 288, 289, 290, 291 }
local GROUP_COUNTS = { 496, 468, 18, 124, 38, 38, 107, 104, 47, 32, 23 }
local GROUP_BASES = { 0, 496, 964, 982, 1106, 1144, 1182, 1289, 1393, 1440, 1472 }

local function wordEntrySection()
  local groups = {}
  for index = 1, 11 do
    groups[index] =
      { group = index - 1, bank = WORD_BANKS[index], count = GROUP_COUNTS[index], firstWordId = GROUP_BASES[index] }
  end
  return {
    groups = groups,
    cursor = {
      sequences = {
        {
          frames = {
            {
              image = "assets/generated/pokegear/word-entry-cursor-1-1.png",
              width = 16,
              height = 16,
              anchorX = 0,
              anchorY = 0,
              duration = 4,
            },
          },
          playMode = "forward",
          loopStartFrameIdx = 0,
        },
      },
    },
    background = { screenMember = 0, charMember = 1, layers = { 0, 4 } },
    text = { interfaceBanks = { 282, 283, 284 }, interfaceCounts = { 14, 15, 3 } },
    input = { hitboxes = 5, touchYMin = 28, touchYMax = 226, confirmSound = 1500 },
  }
end

function T.word_entry_sections_keep_eleven_ordered_groups_and_cursor_frames()
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record, err = PokegearAssetSchema.validateWordEntry(wordEntrySection())
  Assert.notNil(record, "a well-formed word-entry section must validate: " .. tostring(err and err.message or err))
  Assert.equal(#record.groups, 11, "the section keeps all eleven source groups")

  local flat = wordEntrySection()
  flat.groups = { { group = 0, bank = 237, count = 1495, firstWordId = 0 } }
  Assert.isNil(PokegearAssetSchema.validateWordEntry(flat), "a flattened single-group section must not validate")

  local unordered = wordEntrySection()
  unordered.groups[2].group = 5
  Assert.isNil(PokegearAssetSchema.validateWordEntry(unordered), "an out-of-order group index must not validate")

  local empty = wordEntrySection()
  empty.groups[3].count = 0
  Assert.isNil(PokegearAssetSchema.validateWordEntry(empty), "an empty source group must not validate")

  local shifted = wordEntrySection()
  shifted.groups[2].firstWordId = 0
  Assert.isNil(
    PokegearAssetSchema.validateWordEntry(shifted),
    "a base that breaks the cumulative word order must not validate"
  )

  local badCursor = wordEntrySection()
  badCursor.cursor.sequences[1].frames[1].image = "assets/generated/pc/word-entry-cursor-1.png"
  Assert.isNil(
    PokegearAssetSchema.validateWordEntry(badCursor),
    "a cursor frame outside the pokegear family must not validate"
  )
end

return { tests = T }
