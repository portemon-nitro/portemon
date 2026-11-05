-- Call-layering contract: the live phone call splits across the two
-- source surfaces (MAIN_3 contact list above, SUB_2 speech/name below),
-- carries no panel animation across the menu-to-call transition, offers
-- in-call choices as a shared 24px list-menu projection on the call
-- surface, and renders call text from window/palette source refs.
-- Synthetic catalog, real production controller plus the real phone
-- renderer, recording (non-GPU) host fakes; the scenarios stop before
-- GPU rendering and stay red until the call-layering implementation lands.

local Assert = require("tests.support.Assert")

local T = {
  metadata = {
    tags = { "pokegear", "phone", "d4" },
  },
  tests = {},
}

---@param moduleName string
---@param missingMessage string
---@return table
local function requireFeature(moduleName, missingMessage)
  local ok, mod = pcall(require, moduleName)
  if not ok then
    error(missingMessage, 0)
  end
  assert(type(mod) == "table", missingMessage)
  return mod --[[@as table]]
end

---@param path string
---@param width integer
---@param height integer
---@return table
local function visualRef(path, width, height)
  return { image = path, width = width, height = height, anchorX = 0, anchorY = 0 }
end

-- Synthetic companion family with a mother contact (choice-bearing
-- ordinary call) and a service contact, mirroring the published
-- manifest shape including every presentation plane the call-layering contract
-- observes: per-skin foreground/upper planes, panel cells, the sixteen
-- list and tooltip palette colors per skin, the compiled phone OBJ set,
-- and the shared list-menu tile strip beside its palette.
---@return table
local function fixtureManifest()
  local contacts = {
    {
      key = "custom.mom",
      family = "mother",
      sortWeight = 10,
      rematchWeekday = 6,
      rematchTime = 0,
    },
    { key = "custom.trainer-plain", family = "kurt", sortWeight = 20 },
  }
  local order = { "custom.mom", "custom.trainer-plain" }
  local phoneForeground, phoneUpper = {}, {}
  local phoneListPalette, phoneTooltipPalette = {}, {}
  for skin = 0, 5 do
    phoneListPalette[skin] = {}
    phoneTooltipPalette[skin] = {}
    for index = 1, 16 do
      phoneListPalette[skin][index] =
        { r = (index * 15 + skin * 30) % 256, g = (index * 40) % 256, b = (skin * 45 + 20) % 256 }
      phoneTooltipPalette[skin][index] =
        { r = (index * 29 + skin * 12) % 256, g = (index * 17 + 90) % 256, b = (skin * 31 + 140) % 256 }
    end
  end
  for skin = 0, 5 do
    phoneForeground[skin] = visualRef("assets/generated/pokegear/phone-foreground-skin-" .. skin .. ".png", 256, 192)
    phoneUpper[skin] = visualRef("assets/generated/pokegear/phone-upper-skin-" .. skin .. ".png", 256, 192)
  end
  local phonePanel = {
    closed = visualRef("assets/generated/pokegear/phone-panel-closed.png", 240, 48),
    open = visualRef("assets/generated/pokegear/phone-panel-open.png", 240, 48),
  }
  local phoneSpriteCounts = { 2, 2, 2, 2, 2, 2, 1, 1, 3 }
  local phoneSpriteWidths = { 16, 16, 16, 16, 16, 16, 32, 32, 240 }
  local phoneSpriteHeights = { 16, 16, 16, 16, 16, 16, 32, 32, 48 }
  local phoneSprites = {}
  for sequence, frames in ipairs(phoneSpriteCounts) do
    local list = {}
    for frame = 1, frames do
      list[frame] = {
        image = "assets/generated/pokegear/phone-sprite-phone-" .. sequence .. "-" .. frame .. ".png",
        width = phoneSpriteWidths[sequence],
        height = phoneSpriteHeights[sequence],
        anchorX = -math.floor(phoneSpriteWidths[sequence] / 2),
        anchorY = -math.floor(phoneSpriteHeights[sequence] / 2),
        duration = 1,
      }
    end
    phoneSprites[sequence] = { frames = list, playMode = "forward", loopStartFrameIdx = 0 }
  end
  local menuPalette = {}
  for index = 1, 16 do
    menuPalette[index] = { r = (index * 23) % 256, g = (index * 51 + 60) % 256, b = (index * 11 + 90) % 256 }
  end
  return {
    schema = "g4-pokegear-assets-v2",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png", 256, 192) },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png", 32, 32) },
    phone = {
      foreground = phoneForeground,
      upper = phoneUpper,
      panel = phonePanel,
      listPalette = phoneListPalette,
      tooltipPalette = phoneTooltipPalette,
      sprites = { phone = phoneSprites },
    },
    map = { base = visualRef("assets/generated/pokegear/map-base.png", 32, 32) },
    fly = {
      base = visualRef("assets/generated/pokegear/fly-base.png", 32, 32),
      menuTiles = visualRef("assets/generated/pokegear/fly-menu-tiles.png", 256, 16),
      menuPalette = menuPalette,
    },
    radio = { dial = visualRef("assets/generated/pokegear/radio-dial.png", 32, 32) },
    catalog = {
      contacts = contacts,
      contactOrder = order,
      callDefinitions = {},
      callTriggers = {},
      rematches = {},
      gifts = {},
      momPurchases = {},
      locations = {
        { key = "custom.new-bark" },
      },
      flypoints = {},
      regionMap = require("tests.support.PokegearRegionMapFixture").build(),
      reception = {},
      shows = {},
      radioEffects = {},
    },
    text = {},
    sequences = {},
  }
end

-- The borrowed world behind the mother ordinary call: no savings choice
-- yet (so the opening branch owes its save/keep choice), local-map
-- selector facts (so the native script identity resolves), and the
-- savings write the choice commits.
---@return table
local function worldFixture()
  local flags = {}
  return {
    flags = flags,
    read = function(_, key)
      return flags[key]
    end,
    setMomSavingsChoice = function(_, choice)
      flags["mom.savings-choice"] = choice
      flags.savingsChoice = choice
    end,
    rematchReady = {},
    rematches = {},
    queryRematch = function()
      return nil
    end,
    nativeSelectorFacts = function()
      return {
        localMap = true,
        gaveRivalName = false,
        talkedAfterNamingRival = false,
        eggCallPending = false,
      }
    end,
    storyTier = 2,
    weekday = 6,
    timeOfDay = 0,
    teamsByTier = { [2] = { tier = 2, members = { { species = "custom.pidgeotto", level = 13 } } } },
    player = { x = 5, y = 7 },
  }
end

---@return table
local function instantAudio()
  local completed = true
  return {
    playDialing = function()
      completed = false
    end,
    isEffectWaitComplete = function()
      local done = completed
      completed = true
      return done
    end,
  }
end

---@return table
local function messageRefs()
  return {
    invitation = "custom.invitation",
    accept = "custom.accept",
    resolveLine = function()
      return { tokens = { { kind = "glyph", code = 1, text = "X", raw = { 1 } } } }
    end,
  }
end

---@return string[]
local function fixtureTooltips()
  return {
    "fixture-tip-20",
    "fixture-tip-21",
    "fixture-tip-22",
    "fixture-tip-23",
    "fixture-tip-24",
    "fixture-tip-25",
    "fixture-tip-26",
    "fixture-tip-27",
  }
end

---@return string[]
local function fixtureMenuLabels()
  return {
    "fixture-menu-0",
    "fixture-menu-1",
    "fixture-menu-2",
    "fixture-menu-3",
    "fixture-menu-4",
    "fixture-menu-5",
    "fixture-menu-6",
    "fixture-menu-7",
  }
end

-- Opens the real card controller on a fresh companion state with every
-- catalogued contact registered, through the validated synthetic
-- record. Callers place menu calls through semantic confirm input.
---@return table controller
---@return table record
local function openMenuController()
  local PhoneController = requireFeature(
    "game.hgss.src.pokegear.PhoneController",
    "the phone card has no controller yet: the call layering has no menu entry to split across panes"
  )
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
  local state = PokegearState.new({ seed = 2024 }, { catalog = record.catalog })
  for _, contact in ipairs(record.catalog.contacts) do
    state:registerContact(contact.key)
  end
  state:setContactOrder(record.catalog.contactOrder)
  local world = worldFixture()
  world.flags["mom.savings-choice"] = false
  local controller = PhoneController.new({
    state = state,
    catalog = record.catalog,
    assets = record,
    messages = messageRefs(),
    world = world,
    audio = instantAudio(),
    random = PokegearRandom.new(2024),
    tooltips = fixtureTooltips(),
    menuLabels = fixtureMenuLabels(),
  })
  return controller, record
end

-- Walks the real list UI into a menu call on the first (mother)
-- contact: confirm opens its action menu, confirm chooses Call.
---@param controller table
local function placeMenuCall(controller)
  Assert.equal(
    controller:status().view.list.selected,
    0,
    "the menu list opens with the mother contact selected"
  )
  controller:updateFixed({ { type = "confirm" } })
  local menu = assert(controller:status().view, "the menu state exports its view").contextMenu
  Assert.notNil(menu, "confirming the contact opens its action menu")
  controller:updateFixed({ { type = "confirm" } })
  Assert.notNil(controller:status().view.call, "choosing Call starts the live conversation")
end

-- Advances the live conversation through semantic advance input until
-- the mother program owes its save/keep choice. The bound only guards
-- against a stuck call; a healthy call owes its choice within a few
-- fixed steps with no wall-clock waits.
---@param controller table
---@return table the detached view at the owed choice
local function driveToOwedChoice(controller)
  for _ = 1, 24 do
    local view = controller:status().view
    local call = view.call
    if type(call) == "table" and call.stage == "choice" then
      return view
    end
    controller:updateFixed({ { type = "advance" } })
  end
  error("the mother call never reached its owed save/keep choice", 0)
end

-- Recording (non-GPU) render collaborators: every graphics call is
-- captured in the log, every prepared image is a recording stub lease,
-- and text primitives record their lines and palette use. Nothing here
-- touches love or allocates GPU resources.
---@return table resources
---@return table log
local function recordingResources()
  local log = {}
  local current = { 1, 1, 1, 1 }
  local graphics = {}
  function graphics.push()
    log[#log + 1] = { op = "push" }
  end
  function graphics.pop()
    log[#log + 1] = { op = "pop" }
  end
  function graphics.origin()
  end
  function graphics.translate(_, _)
  end
  function graphics.scale(_, _)
  end
  function graphics.intersectScissor(_, _, _, _)
  end
  function graphics.getScissor()
    return 0, 0, 256, 192
  end
  function graphics.transformPoint(x, y)
    return x, y
  end
  function graphics.quad()
    return {}
  end
  function graphics.newQuad()
    return {}
  end
  function graphics.setColor(r, g, b, a)
    current = { r, g, b, a }
  end
  function graphics.rectangle(mode, x, y, width, height)
    log[#log + 1] = { op = "rect", mode = mode, color = { current[1], current[2], current[3], current[4] }, x = x, y = y, width = width, height = height }
  end
  local function stubLease(path)
    local lease = { image = { getDimensions = function()
      return 256, 16
    end }, path = path }
    function lease:draw(_, x, y)
      log[#log + 1] = { op = "image", path = path, x = x, y = y }
    end
    function lease:drawQuad(_, _, dx, dy)
      log[#log + 1] = { op = "quad", path = path, x = dx, y = dy }
    end
    return lease
  end
  local images = setmetatable({}, {
    __index = function(store, path)
      local lease = stubLease(path)
      store[path] = lease
      return lease
    end,
  })
  local function textRenderer()
    return {
      drawText = function(_, line, x, y)
        log[#log + 1] = { op = "text", plain = true, line = tostring(line), x = x, y = y }
      end,
      drawTextWithPalette = function(_, line, x, y, colors)
        log[#log + 1] = { op = "text", plain = false, line = tostring(line), x = x, y = y, colors = colors }
      end,
      textWidth = function(_, line)
        return #tostring(line) * 8
      end,
    }
  end
  local text = textRenderer()
  return {
    graphics = graphics,
    images = images,
    textRenderer = text,
    phoneNameTextRenderer = textRenderer(),
  },
    log
end

---@param left number
---@param top number
---@param width number
---@param height number
---@return table
local function rectOf(left, top, width, height)
  return { x0 = left, y0 = top, x1 = left + width, y1 = top + height }
end

---@param record table
---@param area table
---@return boolean
local function rectHits(record, area)
  return record.x < area.x1 and record.x + record.width > area.x0 and record.y < area.y1
    and record.y + record.height > area.y0
end

---@param record table
---@param area table
---@return boolean
local function textHits(record, area)
  return record.x >= area.x0 and record.x < area.x1 and record.y >= area.y0 and record.y < area.y1
end

-- Source window geometry in pixels: the SUB_2 speech window (tiles
-- x2/y19 27x4) and name window (tiles x4/y16 9x2), and the MAIN_3 six
-- 24px contact rows starting at surface y16.
local SPEECH_RECT = rectOf(16, 152, 216, 32)
local NAME_RECT = rectOf(32, 128, 72, 16)
local LIST_BAND = rectOf(8, 16, 216, 144)

---@param palette table sixteen one-based source colors
---@param color number[]
---@return boolean
local function colorTracesToPalette(palette, color)
  if color[1] == 1 and color[2] == 1 and color[3] == 1 then
    return true
  end
  for _, entry in ipairs(palette) do
    if
      math.abs((entry.r / 255) - color[1]) < 1e-9
      and math.abs((entry.g / 255) - color[2]) < 1e-9
      and math.abs((entry.b / 255) - color[3]) < 1e-9
    then
      return true
    end
  end
  return false
end

-- Locates the owed-choice menu projection on the call surface: either a
-- dedicated top-level projection or a menu carried by the call view,
-- with one 24px row per owed choice, distinct from the speech text.
---@param view table
---@return table? menu projection
local function findChoiceMenu(view)
  local candidates = { view.callMenu }
  if type(view.call) == "table" then
    candidates[#candidates + 1] = view.call.menu
  end
  for _, candidate in ipairs(candidates) do
    if type(candidate) == "table" then
      return candidate
    end
  end
  return nil
end

-- Derives the owed-choice menu exclusion rect in pixels from the
-- published callMenu frame (tiles, the same geometry the renderer
-- draws): the shared list-menu frame spans x..x+width+1 tiles across
-- and y..y+height-1 tiles down. Nil while no choice menu is owed, so
-- non-menu states keep full-strictness counters.
---@param view table
---@return table? pixel rect with x0/y0/x1/y1 fields
local function choiceMenuRect(view)
  local menu = findChoiceMenu(view)
  if type(menu) ~= "table" then
    return nil
  end
  local frame = (menu --[[@as table<string, unknown>]]).frame
  if type(frame) ~= "table" then
    return nil
  end
  local tile = frame --[[@as table<string, integer>]]
  assert(
    type(tile.x) == "number"
      and type(tile.y) == "number"
      and type(tile.width) == "number"
      and type(tile.height) == "number",
    "the owed-choice menu carries its window frame in tiles"
  )
  return {
    x0 = tile.x * 8,
    y0 = tile.y * 8,
    x1 = (tile.x + tile.width + 2) * 8,
    y1 = (tile.y + tile.height) * 8,
  }
end

-- (1) during a live call the information pane carries the live contact
-- list while the controls pane carries the call speech/name (the
-- MAIN_3/SUB_2 split). The information render must paint the list rows
-- and list text; the controls render must paint the call windows and
-- must not paint any list row.
function T.tests.live_call_splits_list_and_speech_across_panes()
  local controller = openMenuController()
  placeMenuCall(controller)
  local view = driveToOwedChoice(controller)
  Assert.notNil(view.list, "the live call keeps its contact list projection")
  Assert.notNil(view.call, "the live call keeps its conversation projection")

  local PokegearPhoneRenderer = requireFeature(
    "libs.hgss.src.presentation.PokegearPhoneRenderer",
    "the phone card has no renderer yet: the MAIN/SUB pane split cannot paint its live call"
  )
  local status = controller:status()
  local content = assert(status.presentation, "the live call publishes its plan").content

  local infoResources, infoLog = recordingResources()
  PokegearPhoneRenderer.drawInformation(infoResources, content)
  local infoFills, infoListText = 0, 0
  for _, record in ipairs(infoLog) do
    if record.op == "rect" and record.mode == "fill" and rectHits(record, LIST_BAND) then
      infoFills = infoFills + 1
    end
    if record.op == "text" and record.plain == false and textHits(record, LIST_BAND) then
      infoListText = infoListText + 1
    end
  end
  Assert.isTrue(
    infoFills > 0,
    "the information pane paints the live contact list rows during the call"
  )
  Assert.isTrue(
    infoListText > 0,
    "the information pane paints the live contact names and classes during the call"
  )

  local controlsResources, controlsLog = recordingResources()
  PokegearPhoneRenderer.draw(controlsResources, view, content)
  -- Call-window fills and the tile-drawn owed-choice menu are the
  -- call surface's own paints: list-leak detection excludes fills
  -- and palette text inside the speech/name windows and the
  -- published choice-menu frame, so a contact-list leak (which
  -- paints every row and both text columns outside those rects)
  -- still trips both counters.
  local menuArea = choiceMenuRect(view)
  local controlsListRows, controlsListText, controlsCallText = 0, 0, 0
  for _, record in ipairs(controlsLog) do
    if
      record.op == "rect"
      and record.mode == "fill"
      and rectHits(record, LIST_BAND)
      and not rectHits(record, SPEECH_RECT)
      and not rectHits(record, NAME_RECT)
      and (menuArea == nil or not rectHits(record, menuArea)) then
      controlsListRows = controlsListRows + 1
    end
    if
      record.op == "text"
      and record.plain == false
      and not textHits(record, SPEECH_RECT)
      and not textHits(record, NAME_RECT)
      and (menuArea == nil or not textHits(record, menuArea))
    then
      controlsListText = controlsListText + 1
    end
    if record.op == "text" and (textHits(record, SPEECH_RECT) or textHits(record, NAME_RECT)) then
      controlsCallText = controlsCallText + 1
    end
  end
  Assert.equal(
    controlsListRows,
    0,
    "the controls pane never repaints the contact list rows during the call"
  )
  Assert.equal(
    controlsListText,
    0,
    "the controls pane never repaints list palette text during the call"
  )
  Assert.isTrue(controlsCallText > 0, "the controls pane paints the call speech and name")
  controller:dispose()
end

-- (2) no panel projection appears across a menu-call transition. The
-- 1+6+1 PANEL_TIMELINE has no decomp source, so choosing Call from the
-- action menu must publish neither a panel cell nor a transition while
-- the conversation starts and settles.
function T.tests.menu_call_transition_publishes_no_panel()
  local controller = openMenuController()
  Assert.equal(
    controller:status().view.list.selected,
    0,
    "the menu list opens with the mother contact selected"
  )
  controller:updateFixed({ { type = "confirm" } })
  Assert.notNil(
    controller:status().view.contextMenu,
    "confirming the contact opens its action menu"
  )
  controller:updateFixed({ { type = "confirm" } })
  for tick = 1, 10 do
    local live = controller:status().view
    Assert.notNil(live.call, "the chosen menu call stays live across tick " .. tick)
    Assert.isNil(live.panel, "no panel projection appears across the menu-call transition (tick " .. tick .. ")")
    Assert.isNil(
      live.transition,
      "no transition projection appears across the menu-call transition (tick " .. tick .. ")"
    )
    controller:updateFixed({ { type = "advance" } })
  end
  controller:dispose()
end

-- (3) in-call choices are a 24px menu projection on the call surface,
-- not in-speech rows. The owed choices ride the shared
-- TouchscreenListMenu geometry (one 24px row per option with a 16px
-- text band) and paint through its tile strip; no choice label paints
-- inside the speech window.
function T.tests.in_call_choices_project_as_shared_list_menu()
  local controller = openMenuController()
  placeMenuCall(controller)
  local view = driveToOwedChoice(controller)
  local owed = assert(view.call, "the owed choice keeps its conversation projection").choices
  Assert.deepEqual(owed, { "save", "keep" }, "the mother call owes its save/keep choice")

  local menu = findChoiceMenu(view)
  Assert.notNil(menu, "the owed choices are exposed as a menu projection on the call surface")
  local projection = assert(menu, "owed-choice menu projection present")
  local labels = assert(projection.options or projection.labels, "the choice menu carries its option labels")
  Assert.deepEqual(labels, { "save", "keep" }, "the choice menu carries the owed choice labels")
  local rows = assert(projection.rows or projection.entries, "the choice menu carries its option rows")
  Assert.equal(#rows, 2, "the choice menu carries one row per owed choice")
  local pitch = (rows[2].y or rows[2].top) - (rows[1].y or rows[1].top)
  Assert.equal(pitch, 24, "the choice menu uses the shared 24px list-menu row pitch")

  local PokegearPhoneRenderer = requireFeature(
    "libs.hgss.src.presentation.PokegearPhoneRenderer",
    "the phone card has no renderer yet: the owed choices cannot paint through the shared list-menu frame"
  )
  local status = controller:status()
  local content = assert(status.presentation, "the live call publishes its plan").content
  local menuTiles = assert(content.menuTiles, "the call plan resolves its shared list-menu tile strip")
  local resources, log = recordingResources()
  PokegearPhoneRenderer.draw(resources, view, content)
  local stripPaints, inSpeechChoices = 0, 0
  for _, record in ipairs(log) do
    if (record.op == "image" or record.op == "quad") and record.path == menuTiles then
      stripPaints = stripPaints + 1
    end
    if
      record.op == "text"
      and textHits(record, SPEECH_RECT)
      and (record.line == "save" or record.line == "keep")
    then
      inSpeechChoices = inSpeechChoices + 1
    end
  end
  Assert.isTrue(
    stripPaints > 0,
    "the owed choices paint through the shared touchscreen list-menu tile strip"
  )
  Assert.equal(inSpeechChoices, 0, "no owed choice paints as an in-speech row")
  controller:dispose()
end

-- (4) call text renders from window/palette source refs. Every fill
-- behind the speech and name windows traces to a source palette entry
-- (never an invented RGBA triple), and every call line prints through
-- palette text primitives (never plain fills-backed text).
function T.tests.call_text_renders_from_window_and_palette_refs()
  local controller = openMenuController()
  placeMenuCall(controller)
  local view = driveToOwedChoice(controller)
  Assert.notNil(view.call, "the live call keeps its conversation projection")

  local PokegearPhoneRenderer = requireFeature(
    "libs.hgss.src.presentation.PokegearPhoneRenderer",
    "the phone card has no renderer yet: call text cannot trace to its window and palette refs"
  )
  local status = controller:status()
  local content = assert(status.presentation, "the live call publishes its plan").content
  local palette = {}
  for _, bank in ipairs({ content.listPalette, content.menuPalette, content.tooltipPalette }) do
    if type(bank) == "table" then
      for _, entry in ipairs(bank) do
        palette[#palette + 1] = entry
      end
    end
  end
  Assert.isTrue(#palette > 0, "the call plan carries its source palette banks")

  local resources, log = recordingResources()
  PokegearPhoneRenderer.draw(resources, view, content)
  local windowFills, inventedFills, plainCallText = 0, 0, 0
  for _, record in ipairs(log) do
    if record.op == "rect" and record.mode == "fill" and (rectHits(record, SPEECH_RECT) or rectHits(record, NAME_RECT)) then
      windowFills = windowFills + 1
      if not colorTracesToPalette(palette, record.color) then
        inventedFills = inventedFills + 1
      end
    end
    if
      record.op == "text"
      and record.plain == true
      and (textHits(record, SPEECH_RECT) or textHits(record, NAME_RECT))
    then
      plainCallText = plainCallText + 1
    end
  end
  Assert.isTrue(windowFills > 0, "the call windows paint behind the speech and name")
  Assert.equal(inventedFills, 0, "no call window fill uses an invented RGBA triple")
  Assert.equal(plainCallText, 0, "no call line prints without its window palette")
  controller:dispose()
end

return T
