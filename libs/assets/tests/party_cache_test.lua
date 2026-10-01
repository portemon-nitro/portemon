-- Readiness scenarios for the party presentation family: the family is
-- ready only with an exact marker, a valid manifest, and every referenced
-- artifact present. Fixtures are synthetic; the ROM suite proves the real
-- family.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local PartyCache = require("libs.assets.src.PartyCache")

local T = {}

local function imageRef(path, width, height)
  return { image = path, width = width, height = height }
end

local function frameRef(path, width, height, durationTicks)
  return { image = path, width = width, height = height, durationTicks = durationTicks }
end

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

local function touch(top, bottom, left, right)
  return { top = top, bottom = bottom, left = left, right = right }
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
      statusRect = rect(origin[1] + 24, origin[2] + 40, 24, 8),
      cursorSequence = 1,
      chrome = {
        normal = imageRef("assets/generated/party/panel-normal.png", 128, 48),
        selected = imageRef("assets/generated/party/panel-selected.png", 128, 48),
        fainted = imageRef("assets/generated/party/panel-fainted.png", 128, 48),
        selectedFainted = imageRef("assets/generated/party/panel-selected-fainted.png", 128, 48),
        switchSelection = imageRef("assets/generated/party/panel-switch-selection.png", 128, 48),
      },
      text = {
        name = rect(origin[1] + 48, origin[2] + 8, 72, 16),
        level = rect(origin[1] + 0, origin[2] + 32, 48, 16),
        gender = { x = origin[1] + 112, y = origin[2] + 8 },
      },
      hp = {
        bar = rect(origin[1] + 64, origin[2] + 24, 48, 8),
        number = rect(origin[1] + 56, origin[2] + 32, 64, 16),
      },
      compat = rect(origin[1] + 48, origin[2] + 32, 80, 16),
    }
  end
  local digits = {}
  for digit = 0, 9 do
    digits[digit + 1] = imageRef("assets/generated/party/digit-" .. digit .. ".png", 8, 8)
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
        textRect = rect(8, 8, 112, 16),
        frameRect = rect(0, 0, 128, 32),
        frameShape = "standard",
        style = "raised",
        touch = touch(0, 32, 0, 128),
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
  local function frameVisual(path, width, height)
    return { image = path, width = width, height = height }
  end
  return {
    schema = "g4-party-presentation-v4",
    panes = {
      main = { width = 256, height = 192 },
      sub = { width = 256, height = 192 },
    },
    panels = panels,
    windows = {
      browse = rect(16, 168, 160, 16),
      context = rect(16, 152, 104, 32),
      action = rect(16, 152, 216, 32),
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
          raised = frameVisual("assets/generated/party/context-standard-raised.png", 128, 32),
          selected = frameVisual("assets/generated/party/context-standard-selected.png", 128, 32),
          pressed = frameVisual("assets/generated/party/context-standard-pressed.png", 128, 32),
        },
        cancel = {
          raised = frameVisual("assets/generated/party/context-cancel-raised.png", 56, 40),
          selected = frameVisual("assets/generated/party/context-cancel-selected.png", 56, 40),
          pressed = frameVisual("assets/generated/party/context-cancel-pressed.png", 56, 40),
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
        paralysis = imageRef("assets/generated/party/status-paralysis.png", 24, 8),
        freeze = imageRef("assets/generated/party/status-freeze.png", 24, 8),
        sleep = imageRef("assets/generated/party/status-sleep.png", 24, 8),
        poison = imageRef("assets/generated/party/status-poison.png", 24, 8),
        burn = imageRef("assets/generated/party/status-burn.png", 24, 8),
        faint = imageRef("assets/generated/party/status-faint.png", 24, 8),
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
        green = imageRef("assets/generated/party/hp-green.png", 48, 4),
        yellow = imageRef("assets/generated/party/hp-yellow.png", 48, 4),
        red = imageRef("assets/generated/party/hp-red.png", 48, 4),
      },
    },
    controls = {
      cancel = {
        anchor = { x = 232, y = 176 },
        label = "Cancel",
        textRect = rect(200, 168, 48, 16),
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
        default = { touch(0, 48, 0, 128) },
        alternate = { touch(0, 48, 0, 128) },
        context = { touch(0, 48, 0, 128) },
      },
    },
    text = {
      labels = { cancel = "Cancel", male = "M", female = "F" },
      templates = {
        switchPrompt = { segments = { { kind = "text", value = "Switch?" } } },
        takeNoItem = { segments = { { kind = "text", value = "Nothing held." } } },
      },
      roles = { ordinary = role(), male = role(), female = role() },
    },
    numberGlyphs = {
      advance = 8,
      height = 8,
      digits = digits,
      slash = imageRef("assets/generated/party/slash.png", 8, 8),
      level = imageRef("assets/generated/party/level.png", 16, 8),
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

local function writeReady(cache, marker)
  local data = manifest()
  cache:writeLua(PartyCache.manifestPath(), data)
  for _, path in ipairs(PartyCache.referencedPaths(data)) do
    cache:write(path, "pixels")
  end
  cache:writeLua(PartyCache.provenancePath(), { cacheFormat = PartyCache.FORMAT, schema = "g4-party-presentation-v4" })
  cache:write(PartyCache.markerPath(), marker)
end

function T.missing_image_is_not_ready()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = PartyCache.marker("abc", "dep")
  cache:writeLua(PartyCache.manifestPath(), manifest())
  cache:writeLua(PartyCache.provenancePath(), { cacheFormat = PartyCache.FORMAT, schema = "g4-party-presentation-v4" })
  cache:write(PartyCache.markerPath(), marker)
  Assert.isFalse(PartyCache.isReady(cache, marker), "referenced images must all exist")
end

function T.stale_format_is_not_ready()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  writeReady(cache, PartyCache.marker("abc", "dep"))
  Assert.isFalse(PartyCache.isReady(cache, "party-v0:abc:dep"), "a marker from another format never reads as current")
end

function T.missing_marker_is_not_ready()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local data = manifest()
  cache:writeLua(PartyCache.manifestPath(), data)
  for _, path in ipairs(PartyCache.referencedPaths(data)) do
    cache:write(path, "pixels")
  end
  cache:writeLua(PartyCache.provenancePath(), { cacheFormat = PartyCache.FORMAT, schema = "g4-party-presentation-v4" })
  Assert.isFalse(PartyCache.isReady(cache, PartyCache.marker("abc", "dep")), "no marker means not ready")
end

function T.current_valid_family_is_ready()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = PartyCache.marker("abc", "dep")
  writeReady(cache, marker)
  Assert.isTrue(PartyCache.isReady(cache, marker), "the complete family reads as ready")
  local loaded = PartyCache.loadManifest(cache)
  Assert.equal(loaded.schema, "g4-party-presentation-v4")
end

-- The presentation contract under test extends the synthetic family with
-- exact icon timelines, text roles, numeric placement, semantic windows,
-- count-complete menu layouts, and the six generated frame visuals.
-- Values are synthetic; only readiness participation is under test.
local function v4manifest()
  local data = manifest()
  data.schema = "g4-party-presentation-v4"
  local sequences = {}
  for sequenceNo = 1, 6 do
    sequences[sequenceNo] =
      { { iconFrame = 1, durationTicks = 1, translateX = 0, translateY = 0 }, loopFrom = 1, playback = "static" }
  end
  data.iconAnimations = { sequences = sequences }
  local function role()
    return {
      foreground = { r = 248, g = 248, b = 248, a = 255 },
      shadow = { r = 88, g = 88, b = 88, a = 255 },
      background = { r = 0, g = 0, b = 0, a = 255 },
    }
  end
  data.text.roles = { ordinary = role(), male = role(), female = role() }
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
  local function layout(count, lateral)
    local entries = {}
    for index = 1, count do
      entries[index] = {
        textRect = rect(8, 8, 112, 16),
        frameRect = rect(0, 0, 128, 32),
        frameShape = "standard",
        style = "raised",
        touch = touch(0, 32, 0, 128),
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
  local function frameVisual(path, width, height)
    return { image = path, width = width, height = height }
  end
  data.contextMenu = {
    topLevel = topLevel,
    subcontext = subcontext,
    textRoles = {
      command = { raised = role(), depressed = role() },
      field = { raised = role(), depressed = role() },
      cancel = { raised = role(), depressed = role() },
    },
    frames = {
      standard = {
        raised = frameVisual("assets/generated/party/context-standard-raised.png", 128, 32),
        selected = frameVisual("assets/generated/party/context-standard-selected.png", 128, 32),
        pressed = frameVisual("assets/generated/party/context-standard-pressed.png", 128, 32),
      },
      cancel = {
        raised = frameVisual("assets/generated/party/context-cancel-raised.png", 56, 40),
        selected = frameVisual("assets/generated/party/context-cancel-selected.png", 56, 40),
        pressed = frameVisual("assets/generated/party/context-cancel-pressed.png", 56, 40),
      },
    },
  }
  data.controls.cancel.label = "Cancel"
  data.controls.cancel.textRect = rect(200, 168, 48, 16)
  data.controls.cancel.align = "center"
  return data
end

local function contextFramePaths()
  return {
    "assets/generated/party/context-standard-raised.png",
    "assets/generated/party/context-standard-selected.png",
    "assets/generated/party/context-standard-pressed.png",
    "assets/generated/party/context-cancel-raised.png",
    "assets/generated/party/context-cancel-selected.png",
    "assets/generated/party/context-cancel-pressed.png",
  }
end

local function writeReadyV4(cache, marker)
  local data = v4manifest()
  cache:writeLua(PartyCache.manifestPath(), data)
  for _, path in ipairs(PartyCache.referencedPaths(data)) do
    cache:write(path, "pixels")
  end
  cache:writeLua(PartyCache.provenancePath(), { cacheFormat = PartyCache.FORMAT, schema = "g4-party-presentation-v4" })
  cache:write(PartyCache.markerPath(), marker)
end

function T.complete_v4_family_is_ready()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = PartyCache.marker("abc", "dep")
  writeReadyV4(cache, marker)
  Assert.isTrue(PartyCache.isReady(cache, marker), "the complete v4 family reads as ready")
  local loaded = PartyCache.loadManifest(cache)
  Assert.equal(loaded.schema, "g4-party-presentation-v4")
end

function T.stale_v3_family_is_not_ready()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = PartyCache.marker("abc", "dep")
  for _, path in ipairs(PartyCache.referencedPaths(v4manifest())) do
    cache:write(path, "pixels")
  end
  local stale = v4manifest()
  stale.schema = "g4-party-presentation-v3"
  stale.contextMenu.textRoles = nil
  stale.contextMenu.textPalette = {
    raised = { r = 248, g = 248, b = 248, a = 255 },
    depressed = { r = 248, g = 0, b = 0, a = 255 },
  }
  stale.contextMenu.fillPalette = {
    raised = { r = 0, g = 0, b = 248, a = 255 },
    depressed = { r = 0, g = 248, b = 0, a = 255 },
  }
  for _, panel in ipairs(stale.panels) do
    panel.chrome.switchSelection = nil
  end
  stale.text.templates.takeNoItem = nil
  cache:writeLua(PartyCache.manifestPath(), stale)
  cache:writeLua(PartyCache.provenancePath(), { cacheFormat = PartyCache.FORMAT, schema = "g4-party-presentation-v3" })
  cache:write(PartyCache.markerPath(), marker)
  Assert.isFalse(PartyCache.isReady(cache, marker), "the previous family never reads as ready")
end

function T.missing_context_frame_is_not_ready()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = PartyCache.marker("abc", "dep")
  writeReadyV4(cache, marker)
  cache:remove(contextFramePaths()[1])
  Assert.isFalse(PartyCache.isReady(cache, marker), "every generated frame visual must exist")
end

function T.context_frame_paths_are_referenced_exactly_once()
  local counts = {}
  for _, path in ipairs(PartyCache.referencedPaths(v4manifest())) do
    counts[path] = (counts[path] or 0) + 1
  end
  for _, path in ipairs(contextFramePaths()) do
    Assert.equal(counts[path], 1, path .. " participates in readiness exactly once")
  end
end

return { tests = T }
