-- The Pokegear asset manifest is a closed source-neutral contract: valid
-- custom records validate without ROM identities, duplicate semantic keys
-- and dangling order references fail naming the offender, malformed visuals
-- and animations are rejected, and unknown top-level sections never pass.

local Assert = require("tests.support.Assert")

local T = {}

local function visualRef(path)
  return { image = path, width = 64, height = 64, anchorX = 0, anchorY = 0 }
end

local function customManifest()
  return {
    schema = "g4-pokegear-assets-v1",
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
    },
    text = {},
    sequences = {},
  }
end

function T.valid_custom_records_validate_without_source_identities()
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record, err = PokegearAssetSchema.validate(customManifest())
  Assert.notNil(record, "valid custom records must validate: " .. tostring(err and err.message or err))
  Assert.equal(record.schema, "g4-pokegear-assets-v1", "validation preserves the schema identity")
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
        { image = "assets/generated/pokegear/cursor-0.png", width = 16, height = 16, anchorX = 0, anchorY = 0, duration = 8 },
        { image = "assets/generated/pokegear/cursor-1.png", width = 16, height = 16, anchorX = 1, anchorY = 0, duration = 8 },
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
        { image = "assets/generated/pokegear/cursor-0.png", width = 16, height = 16, anchorX = 0, anchorY = 0, duration = 8 },
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
        { image = "assets/generated/pokegear/cursor-0.png", width = 16, height = 16, anchorX = 0, anchorY = 0, duration = 8 },
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
        { image = "assets/generated/pokegear/cursor-0.png", width = 16, height = 16, anchorX = 0, anchorY = 0, duration = 0 },
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

return { tests = T }
