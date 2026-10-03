-- Marker-last publication tests for the party cache writer, against an
-- in-memory cache and synthetic bundles. Covers readiness, rejection of a
-- malformed class, and failed-rebuild preservation of the previous artifact.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local function contracts()
  local PartyCache = require("libs.assets.src.PartyCache")
  local PartyCacheWriter = require("romdump.src.digest.ui.PartyCacheWriter")
  return PartyCache, PartyCacheWriter
end

local function manifest()
  local panels = {}
  local origins = { { 0, 0 }, { 128, 8 }, { 0, 48 }, { 128, 56 }, { 0, 96 }, { 128, 104 } }
  for slot, origin in ipairs(origins) do
    panels[slot] = {
      origin = { x = origin[1], y = origin[2] },
      size = { width = 128, height = 48 },
      iconAnchor = { x = origin[1] + 30, y = origin[2] + 16 },
      ballAnchor = { x = origin[1] + 16, y = origin[2] + 14 },
      heldAnchor = { x = origin[1] + 38, y = origin[2] + 24 },
      capsuleAnchor = { x = origin[1] + 46, y = origin[2] + 24 },
      statusRect = { x = origin[1] + 24, y = origin[2] + 40, width = 24, height = 8 },
      cursorSequence = 1,
      chrome = {
        normal = { image = "assets/generated/party/panel-normal.png", width = 128, height = 48 },
        selected = { image = "assets/generated/party/panel-selected.png", width = 128, height = 48 },
        fainted = { image = "assets/generated/party/panel-fainted.png", width = 128, height = 48 },
        selectedFainted = { image = "assets/generated/party/panel-selected-fainted.png", width = 128, height = 48 },
        switchSelection = { image = "assets/generated/party/panel-switch-selection.png", width = 128, height = 48 },
      },
      text = {
        name = { x = origin[1] + 48, y = origin[2] + 8, width = 72, height = 16 },
        level = { x = origin[1] + 0, y = origin[2] + 32, width = 48, height = 16 },
        gender = { x = origin[1] + 112, y = origin[2] + 8 },
      },
      hp = {
        bar = { x = origin[1] + 64, y = origin[2] + 24, width = 48, height = 8 },
        number = { x = origin[1] + 56, y = origin[2] + 32, width = 64, height = 16 },
      },
      compat = { x = origin[1] + 48, y = origin[2] + 32, width = 80, height = 16 },
    }
  end
  local digits = {}
  for digit = 0, 9 do
    digits[digit + 1] = { image = "assets/generated/party/digit-" .. digit .. ".png", width = 8, height = 8 }
  end
  local anchors = {}
  for leaf = 0, 4 do
    anchors[leaf + 1] = { x = 91 + leaf * 10, y = 182 }
  end
  local dpadRow = {}
  for entry = 1, 8 do
    dpadRow[entry] =
      { left = 64, top = 25, width = 0, height = 0, up = 7, down = 2, leftNeighbor = 7, rightNeighbor = 1 }
  end
  local sequences = {}
  for sequenceNo = 1, 6 do
    sequences[sequenceNo] =
      { { iconFrame = 1, durationTicks = 1, translateX = 0, translateY = 0 }, loopFrom = 1, playback = "static" }
  end
  local function role()
    return {
      foreground = { r = 248, g = 248, b = 248, a = 255 },
      shadow = { r = 88, g = 88, b = 88, a = 255 },
      background = { r = 0, g = 0, b = 0, a = 255 },
    }
  end
  local function layout(count, lateral)
    local entries = {}
    for index = 1, count do
      entries[index] = {
        textRect = { x = 8, y = 8, width = 112, height = 16 },
        frameRect = { x = 0, y = 0, width = 128, height = 32 },
        frameShape = "standard",
        style = "raised",
        touch = { top = 0, bottom = 32, left = 0, right = 128 },
        up = 1,
        down = 1,
      }
      if lateral then
        entries[index].left = 1
        entries[index].right = 1
      end
    end
    return entries
  end
  local topLevel = {}
  for count = 2, 8 do
    topLevel[count] = layout(count, true)
  end
  local subcontext = {}
  for count = 2, 5 do
    subcontext[count] = layout(count, false)
  end
  return {
    schema = "g4-party-presentation-v6",
    panes = {
      main = { width = 256, height = 192 },
      sub = { width = 256, height = 192 },
    },
    panels = panels,
    windows = {
      browse = { x = 16, y = 168, width = 160, height = 16 },
      context = { x = 16, y = 152, width = 104, height = 32 },
      action = { x = 16, y = 152, width = 216, height = 32 },
      prompt = { x = 200, y = 80 },
    },
    contextMenu = {
      topLevel = topLevel,
      subcontext = subcontext,
      textRoles = {
        command = { raised = role(), depressed = role() },
        field = { raised = role(), depressed = role() },
        cancel = { raised = role(), depressed = role() },
      },
      frames = {
        standard = {
          raised = { image = "assets/generated/party/context-standard-raised.png", width = 128, height = 32 },
          selected = { image = "assets/generated/party/context-standard-selected.png", width = 128, height = 32 },
          pressed = { image = "assets/generated/party/context-standard-pressed.png", width = 128, height = 32 },
        },
        cancel = {
          raised = { image = "assets/generated/party/context-cancel-raised.png", width = 56, height = 40 },
          selected = { image = "assets/generated/party/context-cancel-selected.png", width = 56, height = 40 },
          pressed = { image = "assets/generated/party/context-cancel-pressed.png", width = 56, height = 40 },
        },
      },
    },
    visuals = {
      cursor = {
        sequences = {
          {
            frames = { { image = "assets/generated/party/cursor-0.png", width = 32, height = 32, durationTicks = 8 } },
            loopFrom = 1,
            playback = "static",
          },
        },
      },
      balls = {
        sequences = {
          {
            frames = { { image = "assets/generated/party/ball-0.png", width = 32, height = 32, durationTicks = 8 } },
            loopFrom = 1,
            playback = "static",
          },
          {
            frames = { { image = "assets/generated/party/ball-1.png", width = 32, height = 32, durationTicks = 8 } },
            loopFrom = 1,
            playback = "static",
          },
        },
      },
      buttons = {
        sequences = {
          {
            frames = { { image = "assets/generated/party/button-0.png", width = 32, height = 32, durationTicks = 8 } },
            loopFrom = 1,
            playback = "static",
          },
          {
            frames = { { image = "assets/generated/party/button-1.png", width = 32, height = 32, durationTicks = 8 } },
            loopFrom = 1,
            playback = "static",
          },
        },
      },
      held = {
        sequences = {
          {
            frames = { { image = "assets/generated/party/held-0.png", width = 8, height = 8, durationTicks = 8 } },
            loopFrom = 1,
            playback = "static",
          },
          {
            frames = { { image = "assets/generated/party/held-1.png", width = 8, height = 8, durationTicks = 8 } },
            loopFrom = 1,
            playback = "static",
          },
          {
            frames = { { image = "assets/generated/party/held-2.png", width = 8, height = 8, durationTicks = 8 } },
            loopFrom = 1,
            playback = "static",
          },
        },
      },
      status = {
        paralysis = { image = "assets/generated/party/status-paralysis.png", width = 24, height = 8 },
        freeze = { image = "assets/generated/party/status-freeze.png", width = 24, height = 8 },
        sleep = { image = "assets/generated/party/status-sleep.png", width = 24, height = 8 },
        poison = { image = "assets/generated/party/status-poison.png", width = 24, height = 8 },
        burn = { image = "assets/generated/party/status-burn.png", width = 24, height = 8 },
        faint = { image = "assets/generated/party/status-faint.png", width = 24, height = 8 },
      },
      feedback = {
        frames = {
          { image = "assets/generated/party/feedback-0.png", width = 16, height = 16, durationTicks = 3 },
          { image = "assets/generated/party/feedback-1.png", width = 16, height = 16, durationTicks = 2 },
        },
        loopFrom = 1,
        playback = "once",
        hideAtFrame = 3,
      },
      backdropMain = { image = "assets/generated/party/backdrop-main.png", width = 256, height = 256 },
      backdropSub = { image = "assets/generated/party/backdrop-sub.png", width = 256, height = 256 },
      detailSub = { image = "assets/generated/party/detail-sub.png", width = 256, height = 256 },
      decoration = { image = "assets/generated/party/decoration.png", width = 128, height = 16 },
      auxPanel = { image = "assets/generated/party/panel-aux.png", width = 128, height = 48 },
      hpBars = {
        green = { image = "assets/generated/party/hp-green.png", width = 48, height = 4 },
        yellow = { image = "assets/generated/party/hp-yellow.png", width = 48, height = 4 },
        red = { image = "assets/generated/party/hp-red.png", width = 48, height = 4 },
      },
    },
    controls = {
      cancel = {
        anchor = { x = 232, y = 176 },
        label = "Cancel",
        textRect = { x = 200, y = 168, width = 48, height = 16 },
        align = "center",
      },
    },
    detail = {
      iconAnchor = { x = 30, y = 200 },
      statusAnchor = { x = 50, y = 220 },
      nicknameTextOrigin = { x = 56, y = 192 },
      heldItemTextOrigin = { x = 138, y = 212 },
    },
    iconAnimations = { sequences = sequences },
    navigation = { dpad = { default = dpadRow, alternate = dpadRow, union = dpadRow, contest = dpadRow } },
    hitboxes = {
      touch = {
        default = { { top = 0, bottom = 48, left = 0, right = 128 } },
        alternate = { { top = 0, bottom = 48, left = 0, right = 128 } },
        context = { { top = 0, bottom = 48, left = 0, right = 128 } },
      },
    },
    text = {
      labels = { cancel = "Cancel", male = "M", female = "F" },
      templates = {
        switchPrompt = { segments = { { kind = "text", value = "Switch?" } } },
        chooseMon = { segments = { { kind = "text", value = "Choose a POKEMON." } } },
        moveTarget = { segments = { { kind = "text", value = "Move to where?" } } },
        giveTarget = { segments = { { kind = "text", value = "Give to which POKEMON?" } } },
        useTarget = { segments = { { kind = "text", value = "Use on which POKEMON?" } } },
        teachTarget = { segments = { { kind = "text", value = "Teach which POKEMON?" } } },
        itemAction = { segments = { { kind = "text", value = "What to do with the item?" } } },
        takeNoItem = { segments = { { kind = "text", value = "Nothing held." } } },
        bagFull = { segments = { { kind = "text", value = "The Bag is full." } } },
        switchHeldPrompt = { segments = { { kind = "text", value = "Switch the held items?" } } },
        switchHeldResult = { segments = { { kind = "text", value = "Switched the held items." } } },
        giveHeldItem = { segments = { { kind = "text", value = "Gave the item to hold." } } },
      },
      roles = { ordinary = role(), male = role(), female = role() },
      messageRole = role(),
    },
    numberGlyphs = {
      advance = 8,
      height = 8,
      digits = digits,
      slash = { image = "assets/generated/party/slash.png", width = 8, height = 8 },
      level = { image = "assets/generated/party/level.png", width = 16, height = 8 },
      placement = {
        level = { x = 5, y = 2 },
        current = { x = 0, y = 2 },
        slash = { x = 28, y = 2 },
        max = { x = 36, y = 2 },
      },
    },
    shinyLeaves = {
      anchors = anchors,
      crownAnchor = { x = 111, y = 182 },
      leafSequence = 6,
      crownSequence = 7,
      paletteBank = 1,
      leaves = {
        frames = { { image = "assets/generated/party/leaf-0.png", width = 16, height = 16, durationTicks = 4 } },
        loopFrom = 1,
        playback = "loop",
      },
      crown = {
        frames = { { image = "assets/generated/party/crown-0.png", width = 16, height = 16, durationTicks = 4 } },
        loopFrom = 1,
        playback = "loop",
      },
    },
  }
end

local function bundle(marker)
  local PartyCache = require("libs.assets.src.PartyCache")
  local data = manifest()
  local assets = {}
  for _, path in ipairs(PartyCache.referencedPaths(data)) do
    assets[path] = "pixels"
  end
  return {
    marker = marker,
    manifest = data,
    dependencies = { cacheFormat = PartyCache.FORMAT, schema = PartyCache.SCHEMA },
    assets = assets,
  }
end

function T.writes_the_class_and_reports_ready()
  local PartyCache, PartyCacheWriter = contracts()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = PartyCache.marker("abc", "dep")
  Assert.isTrue(PartyCacheWriter.write(cache, bundle(marker)), "publication reports success")
  Assert.isTrue(PartyCache.isReady(cache, marker), "ready after write")
  local loaded = PartyCache.loadManifest(cache)
  Assert.equal(loaded.schema, "g4-party-presentation-v6", "the published manifest loads back")
end

function T.rejects_a_malformed_class_without_publishing()
  local PartyCache, PartyCacheWriter = contracts()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local bad = bundle(PartyCache.marker("abc", "dep"))
  bad.manifest = { schema = "g4-party-presentation-v2" }
  local err = Assert.throws(function()
    PartyCacheWriter.write(cache, bad)
  end)
  Assert.isTrue(Errors.is(err), "malformed class must fail structurally")
  Assert.isNil(cache:read(PartyCache.markerPath()), "no ready marker after rejection")
end

-- A malformed rebuild cannot replace ready content: the rebuild fails
-- structurally, the stage is cleaned, and the prior ready tree stays
-- unchanged and loadable with no new ready marker.
function T.failed_rebuild_preserves_the_previous_artifact()
  local PartyCache, PartyCacheWriter = contracts()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local firstMarker = PartyCache.marker("abc", "dep")
  PartyCacheWriter.write(cache, bundle(firstMarker))

  local broken = bundle(PartyCache.marker("abc", "new-dep"))
  broken.manifest = nil
  Assert.throws(function()
    PartyCacheWriter.write(cache, broken)
  end)
  Assert.isTrue(PartyCache.isReady(cache, firstMarker), "the previous artifact remains ready")
  Assert.equal(cache:read(PartyCache.markerPath()), firstMarker, "the new marker never reached the live tree")
  Assert.isNil(backend:getInfo("staging/heartgold/party"), "the stage is cleaned on failure")
end

function T.published_party_manifest_carries_the_full_bag_schema()
  local PartyCache, PartyCacheWriter = contracts()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = PartyCache.marker("abc", "dep")
  Assert.isTrue(PartyCacheWriter.write(cache, bundle(marker)), "publication reports success")
  local loaded = PartyCache.loadManifest(cache)
  Assert.equal(loaded.schema, "g4-party-presentation-v6", "the published manifest declares the full-bag schema")
  Assert.notNil(loaded.text.templates.bagFull, "the published manifest carries the full-bag template")
end

return { tests = T }
