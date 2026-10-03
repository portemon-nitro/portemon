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
    text = {
      name = rect(originX + 48, originY + 8, 72, 16),
      level = rect(originX + 0, originY + 32, 48, 16),
      gender = { x = originX + 112, y = originY + 8 },
    },
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

local function colorRef(red, green, blue)
  return { r = red, g = green, b = blue, a = 255 }
end

local function iconTimeline(period)
  return { { iconFrame = 1, durationTicks = period, translateX = 0, translateY = 0 }, loopFrom = 1, playback = "static" }
end

local function menuLayout(count, lateral)
  local layout = {}
  for index = 1, count do
    layout[index] = {
      textRect = rect(8, 8 + (index - 1) * 16, 112, 16),
      frameRect = rect(0, (index - 1) * 16, 128, 32),
      frameShape = "standard",
      style = index <= 4 and "raised" or "field",
      touch = touch((index - 1) * 16, index * 16, 0, 128),
      up = index == 1 and count or index - 1,
      down = index == count and 1 or index + 1,
    }
    if lateral then
      layout[index].left = index == 1 and count or index - 1
      layout[index].right = index == count and 1 or index + 1
    end
  end
  return layout
end

-- The presentation contract under test: exact icon timelines, resolved text
-- roles, window-relative numeric placement, semantic message windows with
-- the confirm anchor, count-complete menu layouts, and generated frame
-- visuals. Values are synthetic; only the contract shape is under test.
local function v3manifest()
  local data = manifest()
  data.schema = "g4-party-presentation-v3"
  data.iconAnimations = {
    sequences = {
      iconTimeline(1),
      iconTimeline(8),
      iconTimeline(12),
      iconTimeline(24),
      iconTimeline(40),
      {
        { iconFrame = 1, durationTicks = 32, translateX = 0, translateY = 0 },
        { iconFrame = 2, durationTicks = 2, translateX = 1, translateY = 0 },
        { iconFrame = 1, durationTicks = 2, translateX = -1, translateY = 0 },
        loopFrom = 1,
        playback = "loop",
      },
    },
  }
  data.text.roles = {
    ordinary = {
      foreground = colorRef(248, 248, 248),
      shadow = colorRef(88, 88, 88),
      background = colorRef(0, 0, 0),
    },
    male = {
      foreground = colorRef(48, 144, 248),
      shadow = colorRef(16, 48, 120),
      background = colorRef(0, 0, 0),
    },
    female = {
      foreground = colorRef(248, 120, 184),
      shadow = colorRef(120, 24, 72),
      background = colorRef(0, 0, 0),
    },
  }
  data.text.labels.male = "M"
  data.text.labels.female = "F"
  data.numberGlyphs.placement = {
    level = { x = 5, y = 2 },
    current = { x = 0, y = 2 },
    slash = { x = 28, y = 2 },
    max = { x = 36, y = 2 },
  }
  data.windows = {
    browse = rect(16, 168, 160, 16),
    context = rect(8, 64, 128, 24),
    action = rect(8, 120, 160, 16),
    prompt = { x = 200, y = 80 },
  }
  local topLevel = {}
  for count = 2, 8 do
    topLevel[count] = menuLayout(count, true)
  end
  local subcontext = {}
  for count = 2, 5 do
    subcontext[count] = menuLayout(count, false)
  end
  data.contextMenu = {
    topLevel = topLevel,
    subcontext = subcontext,
    textPalette = { raised = colorRef(248, 248, 248), depressed = colorRef(248, 0, 0) },
    fillPalette = { raised = colorRef(0, 0, 248), depressed = colorRef(0, 248, 0) },
    frames = {
      standard = {
        raised = imageRef("assets/generated/party/context-standard-raised.png", 128, 32),
        selected = imageRef("assets/generated/party/context-standard-selected.png", 128, 32),
        pressed = imageRef("assets/generated/party/context-standard-pressed.png", 128, 32),
      },
      cancel = {
        raised = imageRef("assets/generated/party/context-cancel-raised.png", 56, 40),
        selected = imageRef("assets/generated/party/context-cancel-selected.png", 56, 40),
        pressed = imageRef("assets/generated/party/context-cancel-pressed.png", 56, 40),
      },
    },
  }
  data.controls.cancel.label = "Cancel"
  data.controls.cancel.textRect = rect(200, 168, 48, 16)
  data.controls.cancel.align = "center"
  return data
end


-- The next presentation contract: semantic context text roles replace the
-- flat button palettes, every panel carries switch-selection chrome, and
-- the empty-take and full-bag templates are present. Values are synthetic;
-- only the contract shape is under test.
local function textRoleTriple(fg, sh, bg)
  return { foreground = fg, shadow = sh, background = bg }
end

local function v6manifest()
  local data = v3manifest()
  data.schema = "g4-party-presentation-v6"
  local commandRaised = textRoleTriple(colorRef(248, 248, 248), colorRef(88, 88, 88), colorRef(0, 0, 0))
  local commandDepressed = textRoleTriple(colorRef(248, 248, 248), colorRef(88, 88, 88), colorRef(40, 40, 40))
  local fieldRaised = textRoleTriple(colorRef(132, 197, 247), colorRef(0, 82, 165), colorRef(0, 0, 0))
  local fieldDepressed = textRoleTriple(colorRef(132, 197, 247), colorRef(0, 82, 165), colorRef(40, 40, 40))
  data.contextMenu.textPalette = nil
  data.contextMenu.fillPalette = nil
  data.contextMenu.textRoles = {
    command = { raised = commandRaised, depressed = commandDepressed },
    field = { raised = fieldRaised, depressed = fieldDepressed },
    cancel = { raised = commandRaised, depressed = commandDepressed },
  }
  for _, panel in ipairs(data.panels) do
    panel.chrome.switchSelection = imageRef("assets/generated/party/panel-switch-selection.png", 128, 48)
  end
  data.text.templates.takeNoItem = { segments = { { kind = "text", value = "Nothing held." } } }
  data.text.templates.bagFull = { segments = { { kind = "text", value = "The Bag is full." } } }
  local runtimeMessages = {
    { "chooseMon", "Choose a POKEMON." },
    { "moveTarget", "Move to where?" },
    { "giveTarget", "Give to which POKEMON?" },
    { "useTarget", "Use on which POKEMON?" },
    { "teachTarget", "Teach which POKEMON?" },
    { "itemAction", "What to do with the item?" },
    { "switchHeldPrompt", "Switch the held items?" },
    { "switchHeldResult", "Switched the held items." },
    { "giveHeldItem", "Gave the item to hold." },
  }
  for _, entry in ipairs(runtimeMessages) do
    data.text.templates[entry[1]] = { segments = { { kind = "text", value = entry[2] } } }
  end
  data.text.messageRole = textRoleTriple(colorRef(250, 246, 217), colorRef(144, 128, 96), colorRef(48, 40, 32))
  return data
end

function T.valid_manifest_passes_schema()
  Assert.isTrue(PartyAssetSchema.isValidManifest(v6manifest()), "the assembled family is valid")
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
    local bad = v6manifest()
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
  Assert.isTrue(PartyAssetSchema.isValidManifest(v6manifest()), "the complete runtime prefixes are valid")
end

function T.rejects_sequence_group_with_non_array_keys()
  local bad = v6manifest()
  bad.visuals.balls.sequences.extra = bad.visuals.balls.sequences[1]
  Assert.isFalse(
    PartyAssetSchema.isValidManifest(bad),
    "a hash key must not widen a sequence group past its dense prefix"
  )
  local err = Assert.throws(function()
    PartyAssetSchema.assertManifest(bad)
  end)
  Assert.notNil(tostring(err):find("PARTY_MANIFEST_INVALID"), "rejections carry the protocol code")
end

function T.rejects_sequence_group_with_a_hole_before_later_sequences()
  local bad = v6manifest()
  bad.visuals.held.sequences[1] = nil
  Assert.isFalse(
    PartyAssetSchema.isValidManifest(bad),
    "a missing required index must not hide behind a later sequence"
  )
  local err = Assert.throws(function()
    PartyAssetSchema.assertManifest(bad)
  end)
  Assert.notNil(tostring(err):find("PARTY_MANIFEST_INVALID"), "rejections carry the protocol code")
end

function T.producer_tail_sequences_remain_validated()
  local currentProducer = v6manifest()
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
  local bad = v6manifest()
  bad.panels[6] = nil
  Assert.throws(function()
    PartyAssetSchema.assertManifest(bad)
  end)
end

function T.schema_rejects_each_missing_panel_chrome_state()
  for _, state in ipairs({ "normal", "selected", "fainted", "selectedFainted", "switchSelection" }) do
    local bad = v6manifest()
    bad.panels[1].chrome[state] = nil
    Assert.isFalse(PartyAssetSchema.isValidManifest(bad), state .. " panel chrome is required")
  end
end

function T.schema_rejects_missing_v2_presentation_facts()
  local missingGeometry = v6manifest()
  missingGeometry.panels[1].iconAnchor = nil
  Assert.isFalse(PartyAssetSchema.isValidManifest(missingGeometry), "panel sprite geometry is required")

  local missingControl = v6manifest()
  missingControl.controls.cancel.anchor = nil
  Assert.isFalse(PartyAssetSchema.isValidManifest(missingControl), "the Cancel anchor is required")

  local missingHp = v6manifest()
  missingHp.visuals.hpBars = nil
  Assert.isFalse(PartyAssetSchema.isValidManifest(missingHp), "source HP strips are required")

  local missingDetail = v6manifest()
  missingDetail.detail.statusAnchor = nil
  Assert.isFalse(PartyAssetSchema.isValidManifest(missingDetail), "upper detail geometry is required")
end

function T.schema_requires_exact_semantic_status_visuals()
  local missing = v6manifest()
  missing.visuals.status.poison = nil
  Assert.isFalse(PartyAssetSchema.isValidManifest(missing), "every semantic status visual is required")

  local extra = v6manifest()
  extra.visuals.status.ok = imageRef("assets/generated/party/status-ok.png", 24, 8)
  Assert.isFalse(PartyAssetSchema.isValidManifest(extra), "healthy status is not a runtime visual")

  local wrongDimensions = v6manifest()
  wrongDimensions.visuals.status.faint = imageRef("assets/generated/party/status-faint.png", 24, 9)
  Assert.isFalse(PartyAssetSchema.isValidManifest(wrongDimensions), "status visuals keep their 24x8 size")
end

function T.schema_accepts_strict_detail_points_beyond_the_visible_pane()
  local complete = v6manifest()
  Assert.isTrue(PartyAssetSchema.isValidManifest(complete), "rest geometry extends into the full detail surface")

  local extra = v6manifest()
  extra.detail.sourceSequence = 1
  Assert.isFalse(PartyAssetSchema.isValidManifest(extra), "detail geometry has no source sequence field")

  local fractional = v6manifest()
  fractional.detail.statusAnchor.x = 50.5
  Assert.isFalse(PartyAssetSchema.isValidManifest(fractional), "detail points are integral")

  local outOfRange = v6manifest()
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
  local bad = v6manifest()
  bad.hitboxes.touch.default[1] = touch(0, 48, 200, 128)
  Assert.throws(function()
    PartyAssetSchema.assertManifest(bad)
  end)
  local cropped = v6manifest()
  cropped.visuals.held.sequences[1].frames[1].offset = { x = -4, y = -2 }
  Assert.isTrue(PartyAssetSchema.isValidManifest(cropped), "negative sprite crop offsets stay valid")
end

function T.modded_animated_visuals_pass_without_a_fixed_frame_count()
  local modded = v6manifest()
  modded.visuals.balls.sequences[1].frames[2] = frameRef("assets/generated/party/ball-1.png", 40, 40, 12)
  Assert.isTrue(PartyAssetSchema.isValidManifest(modded), "animated visual frame counts and sizes remain flexible")
end

function T.schema_rejects_source_identities_in_the_runtime_manifest()
  local bad = v6manifest()
  bad.visuals.cursor.sequences[1].frames[1].memberId = 5
  Assert.throws(function()
    PartyAssetSchema.assertManifest(bad)
  end)
end

function T.schema_identity_is_the_current_contract()
  Assert.equal(PartyAssetSchema.SCHEMA, "g4-party-presentation-v6")
  Assert.equal(PartyAssetSchema.SCHEMA, DerivedAssetContract.party.schema)
  Assert.equal(PartyCache.FORMAT, DerivedAssetContract.party.cacheFormat)
end

function T.complete_v6_family_passes_schema()
  Assert.isTrue(PartyAssetSchema.isValidManifest(v6manifest()), "the complete v6 family is valid")
end

function T.stale_v2_manifest_is_rejected()
  Assert.isFalse(PartyAssetSchema.isValidManifest(manifest()), "period-only presentation data is stale")
  local err = Assert.throws(function()
    PartyAssetSchema.assertManifest(manifest())
  end)
  Assert.notNil(tostring(err):find("PARTY_MANIFEST_INVALID"), "rejections carry the protocol code")
end

function T.schema_identity_matches_the_party_contract_at_v6()
  Assert.equal(PartyAssetSchema.SCHEMA, "g4-party-presentation-v6")
  Assert.equal(PartyAssetSchema.SCHEMA, DerivedAssetContract.party.schema)
  Assert.equal(PartyCache.FORMAT, "party-cache-v1")
  Assert.equal(PartyCache.FORMAT, DerivedAssetContract.party.cacheFormat)
end

function T.rejects_a_manifest_missing_icon_timelines()
  local bad = v6manifest()
  bad.iconAnimations = nil
  Assert.isFalse(PartyAssetSchema.isValidManifest(bad), "exact icon timelines are required")
end

function T.rejects_icon_frames_outside_the_two_frame_contract()
  local bad = v6manifest()
  bad.iconAnimations.sequences[1][1].iconFrame = 3
  Assert.isFalse(PartyAssetSchema.isValidManifest(bad), "timelines reference the two atlas frames only")
  local mistimed = v6manifest()
  mistimed.iconAnimations.sequences[2][1].durationTicks = 0
  Assert.isFalse(PartyAssetSchema.isValidManifest(mistimed), "timeline durations stay positive")
end

function T.rejects_unsupported_menu_counts()
  local extra = v6manifest()
  extra.contextMenu.topLevel[9] = menuLayout(2, true)
  Assert.isFalse(PartyAssetSchema.isValidManifest(extra), "top-level counts stop at eight")
  local missing = v6manifest()
  missing.contextMenu.topLevel[2] = nil
  Assert.isFalse(PartyAssetSchema.isValidManifest(missing), "top-level layouts are count-complete")
  local extraSub = v6manifest()
  extraSub.contextMenu.subcontext[6] = menuLayout(2, false)
  Assert.isFalse(PartyAssetSchema.isValidManifest(extraSub), "subcontext counts stop at five")
end

function T.rejects_menu_entries_missing_navigation_touch_or_frame_shape()
  local noTouch = v6manifest()
  noTouch.contextMenu.topLevel[2][1].touch = nil
  Assert.isFalse(PartyAssetSchema.isValidManifest(noTouch), "menu touch targets are required")
  local noLateral = v6manifest()
  noLateral.contextMenu.topLevel[2][1].left = nil
  Assert.isFalse(PartyAssetSchema.isValidManifest(noLateral), "top-level lateral navigation is required")
  local badShape = v6manifest()
  badShape.contextMenu.subcontext[2][1].frameShape = "wide"
  Assert.isFalse(PartyAssetSchema.isValidManifest(badShape), "frame shapes stay native")
end

function T.rejects_malformed_text_role_colors()
  local bad = v6manifest()
  bad.text.roles.ordinary.foreground.r = 300
  Assert.isFalse(PartyAssetSchema.isValidManifest(bad), "role colors stay inside the byte range")
  local missing = v6manifest()
  missing.text.roles.male = nil
  Assert.isFalse(PartyAssetSchema.isValidManifest(missing), "every text role is required")
  local noLabels = v6manifest()
  noLabels.text.labels.male = nil
  Assert.isFalse(PartyAssetSchema.isValidManifest(noLabels), "gender labels are required")
end

function T.rejects_runtime_records_leaking_source_identities()
  local bad = v6manifest()
  bad.contextMenu.topLevel[2][1].memberId = 5
  local err = Assert.throws(function()
    PartyAssetSchema.assertManifest(bad)
  end)
  Assert.notNil(tostring(err):find("PARTY_MANIFEST_INVALID"), "rejections carry the protocol code")
end

function T.schema_rejects_panels_missing_or_misplacing_the_gender_origin()
  local missing = v6manifest()
  missing.panels[1].text.gender = nil
  Assert.isFalse(PartyAssetSchema.isValidManifest(missing), "the fixed gender origin is required")
  local err = Assert.throws(function()
    PartyAssetSchema.assertManifest(missing)
  end)
  Assert.notNil(tostring(err):find("PARTY_MANIFEST_INVALID"), "rejections carry the protocol code")
  local malformed = v6manifest()
  malformed.panels[1].text.gender = { x = "112", y = 8 }
  Assert.isFalse(PartyAssetSchema.isValidManifest(malformed), "the gender origin stays an integral point")
end

function T.rejects_a_manifest_missing_a_context_visual()
  local bad = v6manifest()
  bad.contextMenu.frames.standard.selected = nil
  Assert.isFalse(PartyAssetSchema.isValidManifest(bad), "every frame state visual is required")
end

function T.context_text_roles_cover_command_field_and_cancel_states()
  Assert.isTrue(PartyAssetSchema.isValidManifest(v6manifest()), "complete semantic roles are valid")
  local missing = v6manifest()
  missing.contextMenu.textRoles = nil
  Assert.isFalse(PartyAssetSchema.isValidManifest(missing), "semantic text roles are required")
  for _, name in ipairs({ "command", "field", "cancel" }) do
    local partial = v6manifest()
    partial.contextMenu.textRoles[name] = nil
    Assert.isFalse(PartyAssetSchema.isValidManifest(partial), "the " .. name .. " role is required")
    local flat = v6manifest()
    flat.contextMenu.textRoles[name].raised.foreground = nil
    Assert.isFalse(PartyAssetSchema.isValidManifest(flat), "the " .. name .. " role keeps its triple")
  end
  local complete = v6manifest()
  local fieldInk = complete.contextMenu.textRoles.field.raised.foreground
  local commandInk = complete.contextMenu.textRoles.command.raised.foreground
  Assert.isTrue(
    fieldInk.r ~= commandInk.r or fieldInk.g ~= commandInk.g or fieldInk.b ~= commandInk.b,
    "field entries keep their own foreground ink"
  )
end

function T.switch_selection_chrome_is_required()
  Assert.isTrue(PartyAssetSchema.isValidManifest(v6manifest()), "the extended presentation family is valid")
  local missingChrome = v6manifest()
  missingChrome.panels[1].chrome.switchSelection = nil
  Assert.isFalse(PartyAssetSchema.isValidManifest(missingChrome), "switch-selection chrome is required")
  Assert.equal(PartyAssetSchema.SCHEMA, "g4-party-presentation-v6")
  Assert.equal(PartyAssetSchema.SCHEMA, DerivedAssetContract.party.schema)
  Assert.isFalse(PartyAssetSchema.isValidManifest(v3manifest()), "the previous presentation contract is stale")
end

function T.runtime_messages_are_required_at_the_schema_boundary()
  local required = {
    "chooseMon",
    "moveTarget",
    "giveTarget",
    "useTarget",
    "teachTarget",
    "itemAction",
    "takeNoItem",
    "bagFull",
    "switchHeldPrompt",
    "switchHeldResult",
    "giveHeldItem",
  }
  Assert.isTrue(PartyAssetSchema.isValidManifest(v6manifest()), "the complete family is valid")
  local accepted = {}
  for _, name in ipairs(required) do
    local bad = v6manifest()
    bad.text.templates[name] = nil
    if PartyAssetSchema.isValidManifest(bad) then
      accepted[#accepted + 1] = name
    else
      local err = Assert.throws(function()
        PartyAssetSchema.assertManifest(bad)
      end)
      Assert.notNil(
        tostring(err):find("PARTY_MANIFEST_INVALID"),
        name .. " rejection uses the manifest error family"
      )
    end
  end
  Assert.isTrue(#accepted == 0, "incomplete families passed: " .. table.concat(accepted, ", "))
  local hollow = v6manifest()
  hollow.text.templates.takeNoItem = { segments = {} }
  Assert.isFalse(
    PartyAssetSchema.isValidManifest(hollow),
    "a required template without segments stays invalid"
  )
end

function T.unlisted_message_templates_remain_valid()
  local complete = v6manifest()
  Assert.notNil(complete.text.templates.switchPrompt, "the fixture carries an unlisted template")
  Assert.isTrue(PartyAssetSchema.isValidManifest(complete), "unlisted valid templates stay accepted")
end

function T.lower_message_role_is_required()
  local missing = v6manifest()
  missing.text.messageRole = nil
  Assert.isFalse(PartyAssetSchema.isValidManifest(missing), "the lower-message role is required")
  local malformed = v6manifest()
  malformed.text.messageRole = { foreground = colorRef(248, 248, 248) }
  Assert.isFalse(PartyAssetSchema.isValidManifest(malformed), "the lower-message role keeps its triple")
end

function T.party_contract_identity_is_v6_and_previous_schema_is_stale()
  Assert.equal(PartyAssetSchema.SCHEMA, "g4-party-presentation-v6")
  Assert.equal(DerivedAssetContract.party.schema, "g4-party-presentation-v6")
  Assert.equal(PartyCache.SCHEMA, "g4-party-presentation-v6")
  Assert.equal(PartyCache.FORMAT, "party-cache-v1")
  local stale = v6manifest()
  stale.schema = "g4-party-presentation-v5"
  Assert.isFalse(PartyAssetSchema.isValidManifest(stale), "the previous presentation contract is stale")
end

return { tests = T }
