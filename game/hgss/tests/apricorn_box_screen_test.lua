-- The Box screen owns its source messages, row selection, display plan, and session teardown.

local Assert = require("tests.support.Assert")
local ApricornBoxAssetCache = require("libs.assets.src.ApricornBoxAssetCache")
local ApricornBoxScreenState = require("game.hgss.src.apricorn.ApricornBoxScreenState")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")

local T = { tests = {} }

local KEYS =
  { "RED_APRICORN", "YLW_APRICORN", "BLU_APRICORN", "GRN_APRICORN", "PNK_APRICORN", "WHT_APRICORN", "BLK_APRICORN" }
local CENTERS = { { 27, 49 }, { 75, 65 }, { 27, 81 }, { 75, 97 }, { 27, 113 }, { 75, 129 }, { 27, 145 } }
local WINDOWS = { { 5, 6 }, { 11, 8 }, { 5, 10 }, { 11, 12 }, { 5, 14 }, { 11, 16 }, { 5, 18 } }

local function fontDef()
  local charmap = {}
  for code = 32, 126 do
    local char = string.char(code)
    charmap[char] = code
  end
  return { charmap = charmap }
end

local function compactPromptShape()
  local row = { normal = {}, selected = {} }
  return { width = 48, height = 32, yes = row, no = row }
end

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
      itemId = index + 484,
      nameMessageId = index + 6,
      descriptionMessageId = index + 39,
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
    messageBankId = 21,
    pluralBankId = 224,
    titleMessageId = 0,
    closeMessageId = 1,
    browseHeaderMessageId = 27,
    panelMessageId = 26,
    headerWindow = { x = 3, y = 1, width = 28, height = 2 },
    titleWindow = { x = 2, y = 21, width = 10, height = 2 },
    closeWindow = { x = 25, y = 21, width = 6, height = 2 },
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
  local generatedFont = fontDef()
  local messageText = {
    [0] = "Apricorn Box",
    [1] = "CLOSE",
    [7] = "Red Apricorn",
    [8] = "Ylw Apricorn",
    [9] = "Blu Apricorn",
    [10] = "Grn Apricorn",
    [11] = "Pnk Apricorn",
    [12] = "Wht Apricorn",
    [13] = "Blk Apricorn",
    [26] = "",
    [27] = "Collected Apricorns are inside.",
    [37] = "Select which Apricorns to give.",
    [38] = "Give how many?",
    [39] = "Give {STRVAR_1 51, 1, 0} {STRVAR_1 8, 0, 0}?",
    [40] = "Red Apricorn\nA red Apricorn.\nIt assails your nostrils.",
    [41] = "Ylw Apricorn\nA yellow Apricorn.\nIt has an invigorating scent.",
    [42] = "Blu Apricorn\nA blue Apricorn.\nIt smells a bit like grass.",
    [43] = "Grn Apricorn\nA green Apricorn.\nIt has a mysterious, aromatic scent.",
    [44] = "Pnk Apricorn\nA pink Apricorn.\nIt has a nice, sweet scent.",
    [45] = "Wht Apricorn\nA white Apricorn.\nIt doesn't smell like anything.",
    [46] = "Blk Apricorn\nA black Apricorn.\nIt has an indescribable scent.",
  }
  local pluralText = {
    [485] = "Red Apricorns",
    [486] = "Ylw Apricorns",
    [487] = "Blu Apricorns",
    [488] = "Grn Apricorns",
    [489] = "Pnk Apricorns",
    [490] = "Wht Apricorns",
    [491] = "Blk Apricorns",
  }
  local provider = {
    acquireBank = function(_, bankId)
      Assert.isTrue(bankId == 21 or bankId == 224, "the Box leases its label and plural banks")
      return {}
    end,
    get = function(_, bankId, messageId)
      Assert.isTrue(bankId == 21 or bankId == 224, "the Box reads its label and plural banks")
      lookups[#lookups + 1] = { bankId, messageId }
      local source = bankId == 21 and messageText or pluralText
      local text = source[messageId] or ("Apricorn " .. messageId)
      local tokens = FieldMessageText.parse(text, generatedFont)
      return { bankId = bankId, messageId = messageId, text = text, tokens = tokens }
    end,
    format = function(self, template, context, resolvers)
      return FieldMessageProvider.format(self, template, context, resolvers)
    end,
    releaseBank = function(_, bankId)
      Assert.isTrue(bankId == 21 or bankId == 224, "the Box releases its label and plural banks")
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
    fontDef = generatedFont,
    uiManifest = { yesNoPrompt = { shapes = { compact = compactPromptShape() } } },
    measureDisplay = function()
      return measurement(256, 192, "small")
    end,
  })
  return screen, function()
    return releases
  end, lookups, sounds, provider
end

local function failedOpen(stage)
  local events = { acquire = {}, release = {} }
  local provider = {
    acquireBank = function(_, bankId)
      events.acquire[#events.acquire + 1] = bankId
      if stage == "acquire" then
        return nil, "bank acquisition failed"
      end
      if stage == "pluralAcquire" and bankId == 224 then
        return nil, "plural bank acquisition failed"
      end
      return {}
    end,
    get = function(_, bankId)
      Assert.isTrue(bankId == 21 or bankId == 224, "the Box reads its label and plural banks")
      if stage == "lookup" and bankId == 21 then
        error("message lookup failed")
      end
      if stage == "pluralLookup" and bankId == 224 then
        error("plural lookup failed")
      end
      return { text = "Apricorn" }
    end,
    releaseBank = function(_, bankId)
      events.release[#events.release + 1] = bankId
    end,
  }
  local ok = pcall(ApricornBoxScreenState.new, {
    mode = "browse",
    service = {
      capture = function()
        return { apricorns = {} }
      end,
    },
    effect = function() end,
    manifest = manifest(),
    messageProvider = provider,
    fontDef = fontDef(),
    uiManifest = { yesNoPrompt = { shapes = { compact = compactPromptShape() } } },
    measureDisplay = function()
      if stage == "construction" then
        error("session composition failed")
      end
      return measurement(256, 192, "small")
    end,
  })
  Assert.isFalse(ok, "the selected constructor stage fails")
  return events
end

function T.tests.row_touch_selects_the_source_message_and_detail_and_disposal_releases_once()
  local screen, releaseCount = dependencies()
  local before = screen:status()
  Assert.equal(before.selectedIndex, 1)
  Assert.equal(before.selectedName, "Red Apricorn")
  Assert.equal(before.rows[1].quantity, 1)
  screen:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 74, y = 128 } })
  local selected = screen:status()
  Assert.equal(selected.selectedIndex, 6, "source circle 6 selects the sixth Apricorn row")
  Assert.equal(selected.selectedName, "Wht Apricorn", "the selected-detail label follows the source message id")
  Assert.equal(selected.rows[6].quantity, 6)
  screen:cancelPointerCapture()
  screen:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 74, y = 128 } })
  Assert.equal(screen:status().selectedIndex, 6, "a flow replacement cancels the held row press")
  screen:dispose()
  screen:dispose()
  Assert.equal(releaseCount(), 2, "both message-bank leases are released once")
end

function T.tests.browse_rows_expose_retail_header_description_and_chrome()
  local screen = dependencies("browse")
  local before = screen:status()
  Assert.isNil(before.flowMessage, "Bag browse keeps Kurt wording out of the view")
  Assert.equal(before.headerText, "Collected Apricorns are inside.")
  Assert.equal(before.titleText, "Apricorn Box")
  Assert.equal(before.closeText, "CLOSE")
  Assert.equal(
    before.descriptionText,
    "Red Apricorn\nA red Apricorn.\nIt assails your nostrils.",
    "the upper description follows the selected source message"
  )
  screen:updateFixed({ { type = "pointer_down", pointerId = "touch:grn", x = 75, y = 97 } })
  screen:updateFixed({ { type = "pointer_up", pointerId = "touch:grn", x = 75, y = 97 } })
  local selected = screen:status()
  Assert.equal(selected.selectedIndex, 4, "source circle 4 selects the green Apricorn row")
  Assert.equal(
    selected.descriptionText,
    "Grn Apricorn\nA green Apricorn.\nIt has a mysterious, aromatic scent.",
    "the upper description follows the new selection"
  )
  Assert.equal(selected.headerText, "Collected Apricorns are inside.", "the lower header stays put")
  screen:dispose()
end

function T.tests.kurt_quantity_exposes_the_panel_message_slot()
  local screen = dependencies("kurt_select")
  screen:updateFixed({ { type = "pointer_down", pointerId = "touch:row", x = 74, y = 128 } })
  screen:updateFixed({ { type = "pointer_up", pointerId = "touch:row", x = 74, y = 128 } })
  for _ = 1, 4 do
    screen:updateFixed({})
  end
  Assert.equal(screen:status().phase, "quantity")
  local status = screen:status()
  Assert.equal(status.phase, "quantity")
  Assert.equal(status.panelMessage, "", "retail message 26 reserves the quantity window line")
  Assert.equal(status.quantity, 1)
  Assert.equal(status.maximum, 6)
  screen:updateFixed({ { type = "confirm" } })
  Assert.equal(screen:status().phase, "quantity", "the OK press holds its beat")
  for _ = 1, 5 do
    screen:updateFixed({})
  end
  Assert.equal(screen:status().phase, "confirm")
  Assert.equal(
    screen:status().confirmationText,
    "Give 1 Wht Apricorn?",
    "a single Apricorn keeps the singular label"
  )
  screen:dispose()
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

function T.tests.message_bank_lease_is_released_once_for_each_failed_constructor_stage()
  local cases = {
    { stage = "acquire", acquire = { 21 }, release = {} },
    { stage = "lookup", acquire = { 21, 224 }, release = { 224, 21 } },
    { stage = "pluralAcquire", acquire = { 21, 224 }, release = { 21 } },
    { stage = "pluralLookup", acquire = { 21, 224 }, release = { 224, 21 } },
    { stage = "construction", acquire = { 21, 224 }, release = { 224, 21 } },
  }
  for _, case in ipairs(cases) do
    local events = failedOpen(case.stage)
    Assert.deepEqual(events.acquire, case.acquire, case.stage .. " leases the expected banks")
    Assert.deepEqual(events.release, case.release, case.stage .. " unwinds owned leases once")
  end
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
  Assert.equal(screen:status().phase, "quantity")
  Assert.equal(screen:status().cursorSequenceId, 5)
  Assert.equal(screen:status().flowMessage, "Give how many?")
  local snapshot = screen:status()
  Assert.isNil(
    snapshot.presentation.mapInput(
      { type = "pointer_down", pointerId = "touch:outside", outside = true, x = 10, y = 10 },
      snapshot
    ),
    "retail ignores touches outside the quantity overlay"
  )
  local mapped = snapshot.presentation.mapInput({ type = "pointer_down", x = 95, y = 100 }, snapshot)
  Assert.equal(mapped.type, "quantity_control")
  screen:updateFixed({
    { type = "pointer_down", pointerId = "touch:plus", x = 95, y = 100 },
    { type = "pointer_up", pointerId = "touch:plus", x = 95, y = 100 },
  })
  Assert.equal(screen:status().quantity, 2, "source quantity touch geometry changes the same value as keyboard input")
  screen:updateFixed({ { type = "confirm" } })
  Assert.equal(screen:status().phase, "quantity", "the OK press holds its beat")
  Assert.equal(screen:status().pressedAction, 1)
  for _ = 1, 5 do
    screen:updateFixed({})
  end
  Assert.equal(screen:status().phase, "confirm")
  local confirmation = screen:status()
  Assert.equal(confirmation.flowMessage, "Give 2 Wht Apricorns?")
  Assert.equal(confirmation.confirmationText, "Give 2 Wht Apricorns?")
  Assert.isTrue(confirmation.confirmationPrompt.active)
  local hiddenRow = confirmation.presentation.mapInput({ type = "pointer_down", x = 26, y = 48 }, confirmation)
  Assert.equal(hiddenRow.type, "pointer_down", "confirmation forwards raw pointer input to the prompt")
  local no = confirmation.presentation.mapInput({ type = "pointer_down", x = 150, y = 132 }, confirmation)
  Assert.equal(no.type, "pointer_down", "the visible prompt receives its logical pointer coordinates")
  screen:updateFixed({ { type = "pointer_down", pointerId = "touch:no", x = 150, y = 132 } })
  Assert.equal(screen:status().confirmationPrompt.selected, "no", "No pointer press selects its visible button")
  for _ = 1, 9 do
    screen:updateFixed({ { type = "touch_row", index = 1 } })
  end
  Assert.equal(screen:status().phase, "quantity", "No returns to editing after the prompt blink")
  Assert.equal(screen:status().selectedIndex, 6)
  Assert.equal(screen:status().quantity, 2)
  screen:updateFixed({ { type = "pointer_up", pointerId = "touch:no", x = 150, y = 132 } })
  screen:updateFixed({ { type = "confirm" } })
  Assert.equal(screen:status().phase, "quantity", "the second OK press holds its beat")
  for _ = 1, 5 do
    screen:updateFixed({})
  end
  Assert.equal(screen:status().phase, "confirm")
  screen:updateFixed({ { type = "pointer_down", pointerId = "touch:yes", x = 150, y = 100 } })
  screen:updateFixed({ { type = "pointer_up", pointerId = "touch:yes", x = 150, y = 100 } })
  for _ = 1, 9 do
    screen:updateFixed({})
  end
  screen:updateFixed({ { type = "confirm" } })
  local result = screen:takeResult()
  Assert.equal(result.selected.apricornKey, KEYS[6])
  Assert.equal(result.selected.quantity, 2)
  Assert.isTrue(#sounds >= 4, "row, quantity, and prompt actions use the composed sound port")
  screen:dispose()
end

function T.tests.box_layout_publishes_source_panes_across_display_cases()
  local screen = dependencies()
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  local function measureOne(width, height, signature)
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
  local function update(measure)
    screen._measureDisplay = function()
      return measure
    end
    screen:updateFixed({})
    return screen:status().presentation
  end
  Assert.equal(#update(measureOne(512, 384, "native")).panes, 1, "native-like Box uses the interactive source pane")
  Assert.equal(#update(measureOne(1000, 600, "wide")).panes, 2, "wide Box retains both source panes")
  Assert.equal(#update(measureOne(600, 1000, "tall")).panes, 2, "tall Box retains both source panes")
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
