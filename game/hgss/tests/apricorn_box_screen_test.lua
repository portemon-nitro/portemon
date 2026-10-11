-- The Box screen owns its source messages, row selection, display plan, and session teardown.

local Assert = require("tests.support.Assert")
local ApricornBoxAssetCache = require("libs.assets.src.ApricornBoxAssetCache")
local ApricornBoxScreenState = require("game.hgss.src.apricorn.ApricornBoxScreenState")

local T = { tests = {} }

local KEYS =
  { "RED_APRICORN", "BLU_APRICORN", "YLW_APRICORN", "GRN_APRICORN", "PNK_APRICORN", "WHT_APRICORN", "BLK_APRICORN" }
local CENTERS = { { 27, 49 }, { 75, 65 }, { 27, 81 }, { 75, 97 }, { 27, 113 }, { 75, 129 }, { 27, 145 } }
local WINDOWS = { { 5, 6 }, { 11, 8 }, { 5, 10 }, { 11, 12 }, { 5, 14 }, { 11, 16 }, { 5, 18 } }

local function cursorStates()
  local states = {}
  for _, sequenceId in ipairs({ 0, 3, 4, 5 }) do
    states[sequenceId] = {
      playMode = "forward",
      totalTicks = 1,
      frames = {
        {
          image = ApricornBoxAssetCache.assetDir() .. "/cursor-" .. sequenceId .. ".png",
          width = 12,
          height = 12,
          offsetX = 0,
          offsetY = 0,
          durationTicks = 1,
        },
      },
    }
  end
  return states
end

local function manifest()
  local rows = {}
  for index, key in ipairs(KEYS) do
    local center, window = CENTERS[index], WINDOWS[index]
    rows[index] = {
      apricornKey = key,
      nameMessageId = index + 6,
      icon = {
        x = center[1],
        y = center[2],
        playMode = "forward_loop",
        totalTicks = 2,
        frames = {
          {
            image = ApricornBoxAssetCache.assetDir() .. "/icon-" .. index .. ".png",
            width = 16,
            height = 16,
            offsetX = 0,
            offsetY = 0,
            durationTicks = 2,
          },
        },
      },
      quantity = {
        window = { x = window[1], y = window[2], width = 2, height = 2 },
        alignment = "center",
        textWidth = 16,
        textHeight = 16,
        color = 2,
      },
    }
  end
  return {
    schema = ApricornBoxAssetCache.SCHEMA,
    upper = {
      image = ApricornBoxAssetCache.assetDir() .. "/upper-background.png",
      width = 256,
      height = 192,
      offsetX = 0,
      offsetY = 0,
    },
    lower = {
      image = ApricornBoxAssetCache.assetDir() .. "/lower-background.png",
      width = 256,
      height = 192,
      offsetX = 0,
      offsetY = 0,
    },
    actionMenu = {
      image = ApricornBoxAssetCache.assetDir() .. "/action-menu-tiles.png",
      width = 216,
      height = 8,
      offsetX = 0,
      offsetY = 0,
      charOffset = 31,
    },
    messageBankId = 27,
    messageMemberId = 21,
    actionMessageIds = { 2, 3, 4, 5, 6 },
    flowMessageIds = { selection = 37, quantity = 38, confirmation = 39 },
    modeMessages = { 25, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48 },
    controls = {
      sourceTable = { 0, 2, 1, 0, 0, 4, 3, 0, 0, 6, 5, 0, 3, 4, 0, 11, 0, 0, 58, 0, 31, 0, 48, 0 },
      windowCount = 3,
      windowOriginTiles = { x = 14, y = 8 },
      windowWidthTiles = 22,
      selection = 0,
      quantityHitboxes = {
        { x = 104, y = 136, width = 16, height = 48 },
        { x = 128, y = 136, width = 16, height = 48 },
        { x = 88, y = 94, width = 16, height = 14 },
        { x = 128, y = 94, width = 16, height = 14 },
        { x = 88, y = 74, width = 16, height = 14 },
        { x = 128, y = 74, width = 16, height = 14 },
      },
      actions = {
        browse = { x = 22, y = 14, width = 8, windowCount = 3, messageIds = { 2, 3, 4 } },
        kurtSelect = { x = 17, y = 12, width = 8, windowCount = 2, messageIds = { 5, 6 } },
      },
    },
    rowHitboxes = {
      { x = 26, y = 48, radius = 24 },
      { x = 74, y = 64, radius = 24 },
      { x = 26, y = 80, radius = 24 },
      { x = 74, y = 96, radius = 24 },
      { x = 26, y = 112, radius = 24 },
      { x = 74, y = 128, radius = 24 },
      { x = 26, y = 144, radius = 24 },
    },
    selectedDetail = {
      window = { bg = 7, x = 2, y = 17, width = 28, height = 6, palette = 12, baseTile = 0x358 },
      messageWindowIndex = 4,
    },
    selectionCursor = {
      image = ApricornBoxAssetCache.assetDir() .. "/selection-cursor.png",
      width = 12,
      height = 12,
      offsetX = 0,
      offsetY = 0,
      states = cursorStates(),
    },
    rows = rows,
  }
end

local function measurement(width, height, signature)
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  return {
    width = width,
    height = height,
    pixelRatio = 1,
    signature = signature,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = width, height = height },
      role = "world",
      touch = true,
    }),
  }
end

local function dependencies(mode)
  local releases, lookups = 0, {}
  local sounds = {}
  local provider = {
    acquireBank = function(_, bankId)
      Assert.equal(bankId, 27)
      return {}
    end,
    get = function(_, bankId, messageId)
      Assert.equal(bankId, 27)
      lookups[#lookups + 1] = messageId
      return { text = "Apricorn " .. messageId }
    end,
    releaseBank = function(_, bankId)
      Assert.equal(bankId, 27)
      releases = releases + 1
    end,
  }
  local stock = {}
  for index, key in ipairs(KEYS) do
    stock[key] = index
  end
  local service = {
    capture = function()
      return { apricorns = stock }
    end,
  }
  local screen = ApricornBoxScreenState.new({
    mode = mode or "browse",
    service = service,
    effect = function(sequence)
      sounds[#sounds + 1] = sequence
    end,
    manifest = manifest(),
    messageProvider = provider,
    measureDisplay = function()
      return measurement(256, 192, "small")
    end,
  })
  return screen, function()
    return releases
  end, lookups, sounds
end

function T.tests.row_touch_selects_the_source_message_and_detail_and_disposal_releases_once()
  local screen, releaseCount = dependencies()
  local before = screen:status()
  Assert.equal(before.selectedIndex, 1)
  Assert.equal(before.selectedName, "Apricorn 7")
  Assert.equal(before.rows[1].quantity, 1)
  screen:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 74, y = 128 } })
  local selected = screen:status()
  Assert.equal(selected.selectedIndex, 6, "source circle 6 selects the sixth Apricorn row")
  Assert.equal(selected.selectedName, "Apricorn 12", "the selected-detail label follows the source message id")
  Assert.equal(selected.rows[6].quantity, 6)
  screen:cancelPointerCapture()
  screen:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 74, y = 128 } })
  Assert.equal(screen:status().selectedIndex, 6, "a flow replacement cancels the held row press")
  screen:dispose()
  screen:dispose()
  Assert.equal(releaseCount(), 1, "the message-bank lease is released once")
end

function T.tests.display_measurement_is_resolved_again_on_each_fixed_update()
  local screen, _, _ = dependencies()
  local first = screen:status().presentation
  screen._measureDisplay = function()
    return measurement(512, 384, "large")
  end
  screen:updateFixed({})
  local second = screen:status().presentation
  Assert.isTrue(first ~= second, "a changed display measurement publishes a new presentation plan")
  Assert.equal(screen:status().animationTick, 1, "fixed updates advance source animation timing")
  screen:dispose()
end

function T.tests.kurt_touch_select_delay_quantity_controls_and_confirmation_are_composed()
  local screen, _, _, sounds = dependencies("kurt_select")
  screen:updateFixed({ { type = "pointer_down", pointerId = "touch:row", x = 74, y = 128 } })
  screen:updateFixed({ { type = "pointer_up", pointerId = "touch:row", x = 74, y = 128 } })
  Assert.equal(screen:status().selectedIndex, 6)
  Assert.equal(screen:status().phase, "selection_delay")
  Assert.equal(screen:status().cursorSequenceId, 4)
  for _ = 1, 4 do
    screen:updateFixed({})
  end
  Assert.equal(screen:status().phase, "actions")
  Assert.equal(screen:status().cursorSequenceId, 5)
  Assert.equal(screen:status().flowMessage, "Apricorn 37")
  local actionPlan = screen:status().presentation
  local action = actionPlan.mapInput({ type = "pointer_down", x = 153, y = 105 }, screen:status())
  Assert.equal(action.type, "action_control", "mode-specific source list windows map touch to semantic actions")
  screen:updateFixed({
    { type = "pointer_down", pointerId = "touch:ok", x = 153, y = 105 },
    { type = "pointer_up", pointerId = "touch:ok", x = 153, y = 105 },
  })
  Assert.equal(screen:status().selectedAction, 1)
  Assert.equal(screen:status().phase, "quantity")
  Assert.equal(screen:status().flowMessage, "Apricorn 38")
  local snapshot = screen:status()
  local mapped = snapshot.presentation.mapInput({ type = "pointer_down", x = 95, y = 100 }, snapshot)
  Assert.equal(mapped.type, "quantity_control")
  screen:updateFixed({ { type = "pointer_down", pointerId = "touch:plus", x = 95, y = 100 } })
  Assert.equal(screen:status().quantity, 2, "source quantity touch geometry changes the same value as keyboard input")
  screen:updateFixed({ { type = "confirm" } })
  Assert.equal(screen:status().phase, "confirm")
  Assert.equal(screen:status().flowMessage, "Apricorn 39")
  screen:updateFixed({ { type = "confirm" } })
  local result = screen:takeResult()
  Assert.equal(result.selected.apricornKey, KEYS[6])
  Assert.equal(result.selected.quantity, 2)
  Assert.isTrue(#sounds >= 4, "row, quantity, and prompt actions use the composed sound port")
  screen:dispose()
end

function T.tests.browse_actions_keep_mode_specific_rows_and_taste_returns_to_browsing()
  local screen = dependencies("browse")
  screen:updateFixed({ { type = "pointer_down", pointerId = "touch:row", x = 26, y = 48 } })
  local status = screen:status()
  Assert.equal(status.phase, "actions")
  Assert.equal(status.cursorSequenceId, 5)
  Assert.equal(status.controls.actions.browse.windowCount, 3)
  local touch = status.presentation.mapInput({ type = "pointer_down", x = 193, y = 169 }, status)
  Assert.equal(touch.type, "action_control")
  Assert.equal(touch.index, 3, "the source third action window maps to the third browse action")
  screen:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(screen:status().selectedAction, 2)
  screen:updateFixed({ { type = "confirm" } })
  Assert.equal(screen:status().phase, "row_return_delay")
  Assert.equal(screen:status().cursorSequenceId, 4)
  for _ = 1, 4 do
    screen:updateFixed({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(screen:status().phase, "browse")
  Assert.equal(screen:status().cursorSequenceId, 3)
  Assert.equal(screen:status().selectedIndex, 1, "return transition holds row input until the source animation ends")
  Assert.equal(screen:takeResult(), nil, "browse-only action does not change Bag state")
  screen:dispose()
end

function T.tests.box_layout_keeps_native_panes_in_the_supported_display_cases()
  local screen = dependencies()
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  local function update(width, height, signature)
    screen._measureDisplay = function()
      return {
        width = width,
        height = height,
        pixelRatio = 1,
        signature = signature,
        topology = ScreenTopology.oneDisplay({
          id = "main",
          rect = { x = 0, y = 0, width = width, height = height },
          role = "world",
          touch = true,
        }),
      }
    end
    screen:updateFixed({})
    return screen:status().presentation
  end
  Assert.equal(#update(512, 384, "native").panes, 1, "native-like Box uses the interactive source pane")
  Assert.equal(#update(1000, 600, "wide").panes, 2, "wide Box retains both source panes")
  Assert.equal(#update(600, 1000, "tall").panes, 2, "tall Box retains both source panes")
  screen:dispose()
end

function T.tests.dual_display_publishes_both_source_panes()
  local screen = dependencies()
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  screen._measureDisplay = function()
    return {
      width = 520,
      height = 192,
      pixelRatio = 1,
      signature = "dual",
      topology = ScreenTopology.dualDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 256, height = 192 },
        role = "world",
        touch = false,
      }, {
        id = "touch",
        rect = { x = 264, y = 0, width = 256, height = 192 },
        role = "auxiliary",
        touch = true,
      }),
    }
  end
  screen:updateFixed({})
  local plan = screen:status().presentation
  Assert.equal(#plan.panes, 2)
  Assert.equal(plan.panes[1].id, "upper")
  Assert.equal(plan.panes[2].id, "lower")
  screen:dispose()
end

return T
