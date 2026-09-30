-- Contract scenarios for the generated party presentation class. Fixtures
-- model the public manifest only; source archive/member identities belong to
-- the producer dependency record and are intentionally absent.

local Assert = require("tests.support.Assert")
local PartyAssetSchema = require("libs.assets.src.PartyAssetSchema")
local PartyCache = require("libs.assets.src.PartyCache")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")

local T = {}

local function imageRef(path, width, height)
  return { image = path, width = width or 32, height = height or 32 }
end

local function frameRef(path, width, height, durationTicks)
  return { image = path, width = width or 32, height = height or 32, durationTicks = durationTicks or 8 }
end

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

local function touch(top, bottom, left, right)
  return { top = top, bottom = bottom, left = left, right = right }
end

local function panel(originX, originY)
  return {
    origin = { x = originX, y = originY },
    size = { width = 128, height = 48 },
    iconAnchor = { x = originX + 30, y = originY + 16 },
    ballAnchor = { x = originX + 16, y = originY + 14 },
    heldAnchor = { x = originX + 38, y = originY + 24 },
    capsuleAnchor = { x = originX + 46, y = originY + 24 },
    statusRect = rect(originX + 24, originY + 40, 24, 8),
    cursorSequence = 1,
    chrome = {
      normal = imageRef("assets/generated/party/panel-normal.png", 128, 48),
      selected = imageRef("assets/generated/party/panel-selected.png", 128, 48),
      fainted = imageRef("assets/generated/party/panel-fainted.png", 128, 48),
      selectedFainted = imageRef("assets/generated/party/panel-selected-fainted.png", 128, 48),
    },
    text = { name = rect(originX + 48, originY + 8, 72, 16), level = rect(originX + 0, originY + 32, 48, 16) },
    hp = { bar = rect(originX + 64, originY + 24, 48, 8), number = rect(originX + 56, originY + 32, 64, 16) },
    compat = rect(originX + 48, originY + 32, 80, 16),
  }
end

local function manifest()
  local panels = {}
  local origins = { { 0, 0 }, { 128, 8 }, { 0, 48 }, { 128, 56 }, { 0, 96 }, { 128, 104 } }
  for slot, origin in ipairs(origins) do
    panels[slot] = panel(origin[1], origin[2])
  end
  local digits = {}
  for digit = 0, 9 do
    digits[digit + 1] = imageRef("assets/generated/party/digit-" .. digit .. ".png", 8, 8)
  end
  local dpadRow = {}
  for entry = 1, 8 do
    dpadRow[entry] =
      { left = 64, top = 25, width = 0, height = 0, up = 7, down = 2, leftNeighbor = 7, rightNeighbor = 1 }
  end
  return {
    schema = "g4-party-presentation-v2",
    panes = {
      main = { width = 256, height = 192 },
      sub = { width = 256, height = 192 },
    },
    panels = panels,
    windows = {
      message = rect(16, 168, 160, 16),
      context = rect(152, 120, 96, 64),
    },
    visuals = {
      cursor = {
        sequences = {
          { frames = { frameRef("assets/generated/party/cursor-0.png") }, loopFrom = 1, playback = "static" },
        },
      },
      balls = {
        sequences = {
          { frames = { frameRef("assets/generated/party/ball-0.png") }, loopFrom = 1, playback = "static" },
          { frames = { frameRef("assets/generated/party/ball-1.png") }, loopFrom = 1, playback = "static" },
        },
      },
      buttons = {
        sequences = {
          { frames = { frameRef("assets/generated/party/button-0.png") }, loopFrom = 1, playback = "static" },
          { frames = { frameRef("assets/generated/party/button-1.png") }, loopFrom = 1, playback = "static" },
        },
      },
      held = {
        sequences = {
          { frames = { frameRef("assets/generated/party/held-0.png", 8, 8) }, loopFrom = 1, playback = "static" },
          { frames = { frameRef("assets/generated/party/held-1.png", 8, 8) }, loopFrom = 1, playback = "static" },
          { frames = { frameRef("assets/generated/party/held-2.png", 8, 8) }, loopFrom = 1, playback = "static" },
        },
      },
      status = {
        paralysis = imageRef("assets/generated/party/status-paralysis.png", 24, 8),
        freeze = imageRef("assets/generated/party/status-freeze.png", 24, 8),
        sleep = imageRef("assets/generated/party/status-sleep.png", 24, 8),
        poison = imageRef("assets/generated/party/status-poison.png", 24, 8),
        burn = imageRef("assets/generated/party/status-burn.png", 24, 8),
        faint = imageRef("assets/generated/party/status-faint.png", 24, 8),
      },
      feedback = {
        frames = {
          frameRef("assets/generated/party/feedback-0.png", 16, 16, 3),
          frameRef("assets/generated/party/feedback-1.png", 16, 16, 2),
        },
        loopFrom = 1,
        playback = "once",
        hideAtFrame = 3,
      },
      backdropMain = imageRef("assets/generated/party/backdrop-main.png", 256, 256),
      backdropSub = imageRef("assets/generated/party/backdrop-sub.png", 256, 256),
      detailSub = imageRef("assets/generated/party/detail-sub.png", 256, 256),
      decoration = imageRef("assets/generated/party/decoration.png", 128, 16),
      auxPanel = imageRef("assets/generated/party/panel-aux.png", 128, 48),
      hpBars = {
        green = imageRef("assets/generated/party/hp-green.png", 48, 4),
        yellow = imageRef("assets/generated/party/hp-yellow.png", 48, 4),
        red = imageRef("assets/generated/party/hp-red.png", 48, 4),
      },
    },
    controls = { cancel = { anchor = { x = 232, y = 176 } } },
    detail = {
      iconAnchor = { x = 30, y = 200 },
      statusAnchor = { x = 50, y = 220 },
      nicknameTextOrigin = { x = 56, y = 192 },
      heldItemTextOrigin = { x = 138, y = 212 },
    },
    iconAnimations = {
      periods = { 1, 8, 12, 24, 40, 36 },
      replacementDurations = { 32, 2, 2 },
      replacementShift = { 0, 1, -1 },
    },
    navigation = {
      dpad = { default = dpadRow, alternate = dpadRow, union = dpadRow, contest = dpadRow },
    },
    hitboxes = {
      touch = {
        default = { touch(0, 48, 0, 128), touch(8, 56, 128, 0) },
        alternate = { touch(0, 48, 0, 128), touch(0, 48, 128, 0) },
        context = { touch(0, 48, 0, 128), touch(160, 176, 200, 0) },
      },
    },
    text = {
      labels = { cancel = "Cancel" },
      templates = { switchPrompt = { segments = { { kind = "text", value = "Switch?" } } } },
    },
    numberGlyphs = {
      advance = 8,
      height = 8,
      digits = digits,
      slash = imageRef("assets/generated/party/slash.png", 8, 8),
      level = imageRef("assets/generated/party/level.png", 16, 8),
    },
    shinyLeaves = {
      anchors = {
        { x = 91, y = 182 },
        { x = 101, y = 182 },
        { x = 111, y = 182 },
        { x = 121, y = 182 },
        { x = 131, y = 182 },
      },
      crownAnchor = { x = 111, y = 182 },
      leafSequence = 6,
      crownSequence = 7,
      paletteBank = 1,
      leaves = {
        frames = { frameRef("assets/generated/party/leaf-0.png", 16, 16, 4) },
        loopFrom = 1,
        playback = "loop",
      },
      crown = {
        frames = { frameRef("assets/generated/party/crown-0.png", 16, 16, 4) },
        loopFrom = 1,
        playback = "loop",
      },
    },
  }
end

function T.valid_manifest_passes_schema()
  Assert.isTrue(PartyAssetSchema.isValidManifest(manifest()), "the assembled family is valid")
end

function T.runtime_required_sequence_prefixes_are_mandatory()
  local cases = {
    { name = "balls", count = 1 },
    { name = "buttons", count = 1 },
    { name = "held", count = 1 },
    { name = "held", count = 2 },
  }
  local accepted = {}
  for _, case in ipairs(cases) do
    local bad = manifest()
    local sequences = bad.visuals[case.name].sequences
    while #sequences > case.count do
      table.remove(sequences)
    end
    local ok, err = pcall(function()
      PartyAssetSchema.assertManifest(bad)
    end)
    if ok then
      accepted[#accepted + 1] = case.name .. "=" .. case.count
    else
      Assert.notNil(tostring(err):find("PARTY_MANIFEST_INVALID"), case.name .. " rejection uses the manifest error family")
    end
  end
  Assert.isTrue(#accepted == 0, "incomplete runtime prefixes passed: " .. table.concat(accepted, ", "))
  Assert.isTrue(PartyAssetSchema.isValidManifest(manifest()), "the complete runtime prefixes are valid")
end

function T.producer_tail_sequences_remain_validated()
  local currentProducer = manifest()
  currentProducer.visuals.buttons.sequences[3] = {
    frames = { frameRef("assets/generated/party/button-2.png") },
    loopFrom = 1,
    playback = "static",
  }
  currentProducer.visuals.buttons.sequences[4] = {
    frames = { frameRef("assets/generated/party/button-3.png") },
    loopFrom = 1,
    playback = "static",
  }
  Assert.isTrue(PartyAssetSchema.isValidManifest(currentProducer), "the producer's four-button output is valid")

  currentProducer.visuals.buttons.sequences[4].frames[1].image = "assets/generated/bag/other.png"
  Assert.isFalse(PartyAssetSchema.isValidManifest(currentProducer), "producer-tail sequences still receive structural validation")
end

function T.schema_rejects_malformed_references()
  local bad = manifest()
  bad.visuals.cursor.sequences[1].frames[1].image = "assets/generated/bag/other.png"
  local err = Assert.throws(function()
    PartyAssetSchema.assertManifest(bad)
  end)
  Assert.notNil(tostring(err):find("PARTY_MANIFEST_INVALID"), "rejections carry the protocol code")
end

function T.schema_rejects_non_integer_durations()
  local bad = manifest()
  bad.visuals.feedback.frames[1].durationTicks = 1.5
  Assert.throws(function()
    PartyAssetSchema.assertManifest(bad)
  end)
end

function T.schema_rejects_a_missing_panel_state()
  local bad = manifest()
  bad.panels[6] = nil
  Assert.throws(function()
    PartyAssetSchema.assertManifest(bad)
  end)
end

function T.schema_rejects_each_missing_panel_chrome_state()
  for _, state in ipairs({ "normal", "selected", "fainted", "selectedFainted" }) do
    local bad = manifest()
    bad.panels[1].chrome[state] = nil
    Assert.isFalse(PartyAssetSchema.isValidManifest(bad), state .. " panel chrome is required")
  end
end

function T.schema_rejects_missing_v2_presentation_facts()
  local missingGeometry = manifest()
  missingGeometry.panels[1].iconAnchor = nil
  Assert.isFalse(PartyAssetSchema.isValidManifest(missingGeometry), "panel sprite geometry is required")

  local missingControl = manifest()
  missingControl.controls.cancel.anchor = nil
  Assert.isFalse(PartyAssetSchema.isValidManifest(missingControl), "the Cancel anchor is required")

  local missingHp = manifest()
  missingHp.visuals.hpBars = nil
  Assert.isFalse(PartyAssetSchema.isValidManifest(missingHp), "source HP strips are required")

  local missingDetail = manifest()
  missingDetail.detail.statusAnchor = nil
  Assert.isFalse(PartyAssetSchema.isValidManifest(missingDetail), "upper detail geometry is required")
end

function T.schema_requires_exact_semantic_status_visuals()
  local missing = manifest()
  missing.visuals.status.poison = nil
  Assert.isFalse(PartyAssetSchema.isValidManifest(missing), "every semantic status visual is required")

  local extra = manifest()
  extra.visuals.status.ok = imageRef("assets/generated/party/status-ok.png", 24, 8)
  Assert.isFalse(PartyAssetSchema.isValidManifest(extra), "healthy status is not a runtime visual")

  local wrongDimensions = manifest()
  wrongDimensions.visuals.status.faint = imageRef("assets/generated/party/status-faint.png", 24, 9)
  Assert.isFalse(PartyAssetSchema.isValidManifest(wrongDimensions), "status visuals keep their 24x8 size")
end

function T.schema_accepts_strict_detail_points_beyond_the_visible_pane()
  local complete = manifest()
  Assert.isTrue(PartyAssetSchema.isValidManifest(complete), "rest geometry extends into the full detail surface")

  local extra = manifest()
  extra.detail.sourceSequence = 1
  Assert.isFalse(PartyAssetSchema.isValidManifest(extra), "detail geometry has no source sequence field")

  local fractional = manifest()
  fractional.detail.statusAnchor.x = 50.5
  Assert.isFalse(PartyAssetSchema.isValidManifest(fractional), "detail points are integral")

  local outOfRange = manifest()
  outOfRange.detail.heldItemTextOrigin.y = 256
  Assert.isFalse(PartyAssetSchema.isValidManifest(outOfRange), "detail points fit the 256-pixel source surface")
end

function T.schema_rejects_a_v1_manifest()
  local stale = manifest()
  stale.schema = "g4-party-presentation-v1"
  stale.controls = nil
  stale.visuals.hpBars = nil
  for _, panelRecord in ipairs(stale.panels) do
    panelRecord.iconAnchor = nil
    panelRecord.ballAnchor = nil
    panelRecord.heldAnchor = nil
    panelRecord.capsuleAnchor = nil
    panelRecord.statusRect = nil
    panelRecord.cursorSequence = nil
    panelRecord.chrome = { normal = imageRef("assets/generated/party/panel-normal.png", 128, 48) }
  end
  Assert.isFalse(PartyAssetSchema.isValidManifest(stale), "v1 presentation data is stale")
end

function T.schema_rejects_off_pane_hitboxes_but_permits_negative_crop_offsets()
  local bad = manifest()
  bad.hitboxes.touch.default[1] = touch(0, 48, 200, 128)
  Assert.throws(function()
    PartyAssetSchema.assertManifest(bad)
  end)
  local cropped = manifest()
  cropped.visuals.held.sequences[1].frames[1].offset = { x = -4, y = -2 }
  Assert.isTrue(PartyAssetSchema.isValidManifest(cropped), "negative sprite crop offsets stay valid")
end

function T.modded_animated_visuals_pass_without_a_fixed_frame_count()
  local modded = manifest()
  modded.visuals.balls.sequences[1].frames[2] = frameRef("assets/generated/party/ball-1.png", 40, 40, 12)
  Assert.isTrue(PartyAssetSchema.isValidManifest(modded), "animated visual frame counts and sizes remain flexible")
end

function T.schema_rejects_source_identities_in_the_runtime_manifest()
  local bad = manifest()
  bad.visuals.cursor.sequences[1].frames[1].memberId = 5
  Assert.throws(function()
    PartyAssetSchema.assertManifest(bad)
  end)
end

function T.schema_identity_is_the_current_contract()
  Assert.equal(PartyAssetSchema.SCHEMA, "g4-party-presentation-v2")
  Assert.equal(PartyAssetSchema.SCHEMA, DerivedAssetContract.party.schema)
  Assert.equal(PartyCache.FORMAT, DerivedAssetContract.party.cacheFormat)
end

return { tests = T }
