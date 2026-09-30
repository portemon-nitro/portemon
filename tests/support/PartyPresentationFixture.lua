-- Synthetic source-shaped party presentation manifest for unit and
-- component tests: the validated v3 sections the native layout,
-- controller, and renderer consume, without ROM-derived pixels. Icon
-- timelines use the array shape (loopFrom/playback plus one record per
-- frame); context menus carry per-count entries with frame/text
-- rectangles, touch targets, wrap navigation, and lateral links on the
-- top-level section only; numeric placement points follow the compiled
-- convention (level/current/slash/max origins inside the HP window, the
-- current value right-aligning inside its three-digit field). Geometry is
-- internally consistent but invented: exact source values are proved
-- against the real manifest in the graphics layer, never here.

local PartyPresentationFixture = {}

local function image(path, width, height)
  return { image = path, width = width, height = height }
end

local function frame(path, width, height)
  return {
    image = path,
    width = width,
    height = height,
    offset = { x = 0, y = 0 },
    durationTicks = 1,
  }
end

local function sequence(path, width, height)
  return { frames = { frame(path, width, height) }, loopFrom = 1, playback = "static" }
end

local function color(r, g, b)
  return { r = r, g = g, b = b }
end

local function textRole(fr, fg, fb, sr, sg, sb, br, bg, bb)
  return {
    foreground = color(fr, fg, fb),
    shadow = color(sr, sg, sb),
    background = color(br, bg, bb),
  }
end

local ORIGINS = { { 0, 0 }, { 128, 8 }, { 0, 48 }, { 128, 56 }, { 0, 96 }, { 128, 104 } }

local function panels()
  local out = {}
  for slot, origin in ipairs(ORIGINS) do
    out[slot] = {
      origin = { x = origin[1], y = origin[2] },
      iconAnchor = { x = origin[1] + 30, y = origin[2] + 16 },
      ballAnchor = { x = origin[1] + 16, y = origin[2] + 14 },
      heldAnchor = { x = origin[1] + 38, y = origin[2] + 24 },
      capsuleAnchor = { x = origin[1] + 46, y = origin[2] + 24 },
      statusRect = { x = origin[1] + 24, y = origin[2] + 40, width = 24, height = 8 },
      cursorSequence = 1,
      size = { width = 128, height = 48 },
      chrome = {
        normal = image("assets/generated/party/panel.png", 128, 48),
        selected = image("assets/generated/party/panel-selected.png", 128, 48),
        fainted = image("assets/generated/party/panel-fainted.png", 128, 48),
        selectedFainted = image("assets/generated/party/panel-selected-fainted.png", 128, 48),
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
  return out
end

-- Synthetic top-level topology: vertical wrap plus a lateral relation
-- that differs from the vertical one, so tests can tell which neighbor
-- map an implementation followed.
---@param count integer entries in 2..8
---@return table[]
local function topLevelEntries(count)
  local half = math.floor(count / 2)
  local entries = {}
  for index = 1, count do
    local column = (index - 1) % 2
    local row = math.floor((index - 1) / 2)
    entries[index] = {
      textRect = { x = column * 128 + 8, y = 24 + row * 32 + 8, width = 112, height = 16 },
      frameRect = { x = column * 128, y = 24 + row * 32, width = 128, height = 32 },
      frameShape = "standard",
      style = index == count and "cancel" or "command",
      touch = {
        top = 24 + row * 32,
        bottom = 24 + row * 32 + 32,
        left = column * 128,
        right = column == 1 and 0 or 128,
      },
      up = ((index - 2) % count) + 1,
      down = (index % count) + 1,
      left = ((index - 1 + half) % count) + 1,
      right = ((index - 1 - half) % count) + 1,
    }
    -- The odd tail entry has no same-row partner; it keeps the wrap
    -- neighbor instead of addressing itself.
    if count % 2 == 1 and index == count then
      entries[index].left = ((index - 2) % count) + 1
      entries[index].right = (index % count) + 1
    end
  end
  return entries
end

---@param count integer entries in 2..5
---@return table[]
local function subcontextEntries(count)
  local entries = {}
  for index = 1, count do
    entries[index] = {
      textRect = { x = 160, y = 96 + (index - 1) * 18 + 2, width = 80, height = 14 },
      frameRect = { x = 152, y = 96 + (index - 1) * 18, width = 96, height = 18 },
      frameShape = "standard",
      style = index == count and "cancel" or "command",
      touch = { top = 96 + (index - 1) * 18, bottom = 96 + index * 18, left = 152, right = 0 },
      up = ((index - 2) % count) + 1,
      down = (index % count) + 1,
    }
  end
  return entries
end

local function dpadBox(up, down, leftNeighbor, rightNeighbor)
  return {
    left = 0,
    top = 0,
    width = 0,
    height = 0,
    up = up,
    down = down,
    leftNeighbor = leftNeighbor,
    rightNeighbor = rightNeighbor,
  }
end

local function touch(top, bottom, left, right)
  return { top = top, bottom = bottom, left = left, right = right }
end

local function defaultTouch()
  return {
    touch(0, 48, 0, 128),
    touch(8, 56, 128, 0),
    touch(48, 96, 0, 128),
    touch(56, 104, 128, 0),
    touch(96, 144, 0, 128),
    touch(104, 152, 128, 0),
    touch(152, 192, 200, 0),
  }
end

---@param totalTicks integer timeline length
---@param secondFrame integer? atlas frame for the second keyframe
---@param secondDuration integer? ticks for the second keyframe
---@return table timeline in array shape
local function timeline(totalTicks, secondFrame, secondDuration)
  if secondFrame == nil then
    return {
      loopFrom = 1,
      playback = "static",
      { iconFrame = 1, durationTicks = totalTicks, translateX = 0, translateY = 0 },
    }
  end
  local firstDuration = totalTicks - (secondDuration or 0)
  return {
    loopFrom = 1,
    playback = "loop",
    { iconFrame = 1, durationTicks = firstDuration, translateX = 0, translateY = 0 },
    { iconFrame = secondFrame, durationTicks = (secondDuration or 0), translateX = 1, translateY = 0 },
  }
end

---@return table<string, unknown> synthetic v3-shaped party manifest
function PartyPresentationFixture.manifest()
  local digits = {}
  for digit = 0, 9 do
    digits[digit + 1] = image("assets/generated/party/digit-" .. digit .. ".png", 8, 8)
  end
  local topLevel = {}
  for count = 2, 8 do
    topLevel[count] = topLevelEntries(count)
  end
  local subcontext = {}
  for count = 2, 5 do
    subcontext[count] = subcontextEntries(count)
  end
  local dpadDefault = {
    dpadBox(7, 2, 7, 1),
    dpadBox(7, 3, 0, 2),
    dpadBox(0, 4, 1, 3),
    dpadBox(1, 5, 2, 4),
    dpadBox(2, 7, 3, 5),
    dpadBox(3, 7, 4, 7),
    dpadBox(0, 0, 0, 0),
    dpadBox(5, 1, 5, 0),
  }
  return {
    schema = "g4-party-presentation-v3",
    panes = {
      main = { width = 256, height = 192 },
      sub = { width = 256, height = 192 },
    },
    panels = panels(),
    controls = {
      cancel = {
        anchor = { x = 232, y = 176 },
        label = "CANCEL",
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
    windows = {
      browse = { x = 8, y = 144, width = 176, height = 40 },
      context = { x = 152, y = 120, width = 96, height = 64 },
      action = { x = 8, y = 136, width = 176, height = 48 },
      prompt = { x = 200, y = 80 },
    },
    visuals = {
      cursor = { sequences = { sequence("assets/generated/party/cursor.png", 128, 48) } },
      balls = {
        sequences = {
          sequence("assets/generated/party/ball-0.png"),
          sequence("assets/generated/party/ball-1.png"),
        },
      },
      buttons = {
        sequences = {
          sequence("assets/generated/party/button-normal.png", 56, 32),
          sequence("assets/generated/party/button-selected.png", 56, 32),
        },
      },
      held = { sequences = {
        sequence("assets/generated/party/held.png", 8, 8),
        sequence("assets/generated/party/mail.png", 8, 8),
        sequence("assets/generated/party/capsule.png", 8, 8),
      } },
      status = {
        paralysis = image("assets/generated/party/status-paralysis.png", 24, 8),
        freeze = image("assets/generated/party/status-freeze.png", 24, 8),
        sleep = image("assets/generated/party/status-sleep.png", 24, 8),
        poison = image("assets/generated/party/status-poison.png", 24, 8),
        burn = image("assets/generated/party/status-burn.png", 24, 8),
        faint = image("assets/generated/party/status-faint.png", 24, 8),
      },
      feedback = {
        frames = { frame("assets/generated/party/feedback.png", 16, 16) },
        loopFrom = 1,
        playback = "static",
      },
      backdropMain = image("assets/generated/party/backdrop-main.png", 256, 256),
      backdropSub = image("assets/generated/party/backdrop-sub.png", 256, 256),
      detailSub = image("assets/generated/party/detail-sub.png", 256, 256),
      decoration = image("assets/generated/party/decoration.png", 32, 32),
      auxPanel = image("assets/generated/party/aux-panel.png", 128, 48),
      hpBars = {
        green = image("assets/generated/party/hp-green.png", 48, 4),
        yellow = image("assets/generated/party/hp-yellow.png", 48, 4),
        red = image("assets/generated/party/hp-red.png", 48, 4),
      },
    },
    iconAnimations = {
      sequences = {
        timeline(1),
        timeline(8, 2, 4),
        timeline(12, 2, 6),
        timeline(24, 2, 12),
        timeline(40, 2, 20),
        {
          loopFrom = 1,
          playback = "loop",
          { iconFrame = 1, durationTicks = 32, translateX = 0, translateY = 0 },
          { iconFrame = 1, durationTicks = 2, translateX = 1, translateY = 0 },
          { iconFrame = 1, durationTicks = 2, translateX = -1, translateY = 0 },
        },
      },
    },
    contextMenu = {
      topLevel = topLevel,
      subcontext = subcontext,
      textPalette = {
        raised = color(84, 84, 84),
        depressed = color(248, 248, 248),
      },
      fillPalette = {
        raised = color(232, 216, 184),
        depressed = color(88, 80, 72),
      },
      frames = {
        standard = {
          raised = image("assets/generated/party/menu-standard-raised.png", 128, 32),
          selected = image("assets/generated/party/menu-standard-selected.png", 128, 32),
          pressed = image("assets/generated/party/menu-standard-pressed.png", 128, 32),
        },
        cancel = {
          raised = image("assets/generated/party/menu-cancel-raised.png", 56, 40),
          selected = image("assets/generated/party/menu-cancel-selected.png", 56, 40),
          pressed = image("assets/generated/party/menu-cancel-pressed.png", 56, 40),
        },
      },
    },
    navigation = {
      dpad = {
        default = dpadDefault,
        alternate = dpadDefault,
        union = dpadDefault,
        contest = dpadDefault,
      },
    },
    hitboxes = {
      touch = {
        default = defaultTouch(),
        alternate = defaultTouch(),
        context = defaultTouch(),
      },
    },
    text = {
      labels = {
        cancel = "CANCEL",
        male = "M",
        female = "F",
        summary = "SUMMARY",
        quit = "QUIT",
      },
      templates = {
        chooseMon = { segments = { { kind = "text", value = "Choose a POKéMON." } } },
        itemAction = {
          segments = {
            { kind = "text", value = "Do what with" },
            { kind = "lineBreak" },
            { kind = "name" },
            { kind = "text", value = "?" },
          },
        },
      },
      roles = {
        ordinary = textRole(250, 250, 250, 120, 120, 128, 40, 40, 48),
        male = textRole(80, 144, 248, 32, 48, 120, 40, 40, 48),
        female = textRole(248, 144, 160, 120, 48, 64, 40, 40, 48),
      },
    },
    numberGlyphs = {
      advance = 8,
      height = 8,
      digits = digits,
      slash = image("assets/generated/party/slash.png", 8, 8),
      level = image("assets/generated/party/level.png", 16, 8),
      placement = {
        level = { x = 5, y = 2 },
        current = { x = 0, y = 2 },
        slash = { x = 28, y = 2 },
        max = { x = 36, y = 2 },
      },
    },
    shinyLeaves = {
      anchors = { { x = 1, y = 1 }, { x = 2, y = 2 }, { x = 3, y = 3 }, { x = 4, y = 4 }, { x = 5, y = 5 } },
      crownAnchor = { x = 6, y = 6 },
      leafSequence = 6,
      crownSequence = 7,
      paletteBank = 3,
      leaves = {
        frames = { frame("assets/generated/party/leaf.png", 8, 8) },
        loopFrom = 1,
        playback = "static",
      },
      crown = {
        frames = { frame("assets/generated/party/crown.png", 8, 8) },
        loopFrom = 1,
        playback = "static",
      },
    },
  }
end

return PartyPresentationFixture
