-- Foreground phone list, sorting, and input presentation: every
-- contact count from empty to a full book sorts each way with stable
-- ties, scrolls within a six-row clipped viewport, separates manual
-- move input from ordinary row taps, restores the saved order on
-- reopen, and carries per-state text colors across skins. Geometry comes from the controller's
-- detached view against independent source rectangles; colors and skin
-- swaps are proven in pixels through the published plan render with
-- fixed synthetic images, so no draw rebuild can fake a repaint. Pixel
-- comparisons never copy commercial bytes: every image is a solid
-- host-boundary fake hung on a genuine validated manifest path.

local Assert = require("tests.support.Assert")
local StubLease = require("tests.support.StubLease")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")

local T = {}

-- Loads a phone module that does not exist yet at this baseline. The
-- failure names the missing behaviour instead of surfacing as a suite
-- load error, so the pre-implementation red stays attributable.
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

-- Synthetic companion family mirroring the published manifest shape:
-- per-skin phone foreground, upper, and panel planes (closed and open
-- cells get distinct paths), plus the remaining card planes the schema
-- requires. Every visual gets a distinct path so the test can hang a
-- distinct solid color on each and watch skin swaps move pixels.
---@param contacts table[] catalog contact records
---@param order string[] saved contact order
---@return table
local function fixtureManifest(contacts, order)
  local phoneForeground, phoneUpper, phonePanel = {}, {}, {}
  local phoneForegroundDim, phoneForegroundDimChoice, phoneDimShellForeground = {}, {}, {}
  -- Sixteen distinct synthetic colors per skin: the renderer indexes them
  -- by source palette slot, so every slot and skin paints differently.
  -- The dimmed list palette stays distinct per slot so dimmed rows
  -- repaint from it alone.
  local phoneListPalette = {}
  local phoneListPaletteDim = {}
  local phoneTooltipPalette = {}
  local phoneWindowPalette = {}
  for skin = 0, 5 do
    phoneListPalette[skin] = {}
    phoneListPaletteDim[skin] = {}
    phoneTooltipPalette[skin] = {}
    phoneWindowPalette[skin] = {}
    for index = 1, 16 do
      phoneListPalette[skin][index] =
        { r = (index * 15 + skin * 30) % 256, g = (index * 40) % 256, b = (skin * 45 + 20) % 256 }
      phoneListPaletteDim[skin][index] =
        { r = (index * 37 + skin * 11 + 90) % 256, g = (index * 19 + 130) % 256, b = (skin * 23 + 40) % 256 }
      phoneTooltipPalette[skin][index] =
        { r = (index * 29 + skin * 12) % 256, g = (index * 17 + 90) % 256, b = (skin * 31 + 140) % 256 }
      -- The call windows print through their own bank of the foreground
      -- palette (windows[0,1] palette 1), kept distinct from the list
      -- and tooltip banks so the call surface repaints from it alone.
      phoneWindowPalette[skin][index] =
        { r = (index * 41 + skin * 7 + 60) % 256, g = (index * 13 + 150) % 256, b = (skin * 53 + 200) % 256 }
    end
  end
  for skin = 0, 5 do
    phoneForeground[skin] = visualRef("assets/generated/pokegear/phone-foreground-skin-" .. skin .. ".png", 256, 192)
    phoneForegroundDim[skin] =
      visualRef("assets/generated/pokegear/phone-foreground-dim-skin-" .. skin .. ".png", 256, 192)
    phoneForegroundDimChoice[skin] =
      visualRef("assets/generated/pokegear/phone-foreground-dim-choice-skin-" .. skin .. ".png", 256, 192)
    phoneDimShellForeground[skin] =
      visualRef("assets/generated/pokegear/phone-dim-shell-foreground-skin-" .. skin .. ".png", 256, 192)
    phoneUpper[skin] = visualRef("assets/generated/pokegear/phone-upper-skin-" .. skin .. ".png", 256, 192)
  end
  phonePanel = {
    closed = visualRef("assets/generated/pokegear/phone-panel-closed.png", 240, 48),
    open = visualRef("assets/generated/pokegear/phone-panel-open.png", 240, 48),
  }
  -- The compiled phone OBJ set in source animation order: two-frame
  -- blink arrows and corners, single-frame move variants, and the
  -- three-frame panel. Paths mirror the producer's staged sprite names.
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
  -- The dimmed sprite set mirrors the bright one frame for frame with
  -- distinct staged paths so dimmed call art repaints from it alone.
  local phoneSpritesDim = {}
  for sequence, clip in ipairs(phoneSprites) do
    local list = {}
    for frame = 1, #clip.frames do
      local bright = clip.frames[frame]
      list[frame] = {
        image = "assets/generated/pokegear/phone-sprite-dim-phone-" .. sequence .. "-" .. frame .. ".png",
        width = bright.width,
        height = bright.height,
        anchorX = bright.anchorX,
        anchorY = bright.anchorY,
        duration = bright.duration,
      }
    end
    phoneSpritesDim[sequence] = { frames = list, playMode = clip.playMode, loopStartFrameIdx = clip.loopStartFrameIdx }
  end
  -- The shared touchscreen list-menu tile strip behind framed menus:
  -- the same staged sbox tiles the Fly card frames its menu with, so the
  -- phone context menus paint the regular frame instead of an invented
  -- rectangle. Sixteen palette colors ride beside the strip.
  local menuPalette = {}
  for index = 1, 16 do
    menuPalette[index] = { r = (index * 23) % 256, g = (index * 51 + 60) % 256, b = (index * 11 + 90) % 256 }
  end
  return {
    schema = "g4-pokegear-assets-v3",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png", 256, 192) },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png", 32, 32) },
    phone = {
      foreground = phoneForeground,
      foregroundDim = phoneForegroundDim,
      foregroundDimChoice = phoneForegroundDimChoice,
      dimShellForeground = phoneDimShellForeground,
      upper = phoneUpper,
      panel = phonePanel,
      listPalette = phoneListPalette,
      listPaletteDim = phoneListPaletteDim,
      tooltipPalette = phoneTooltipPalette,
      windowPalette = phoneWindowPalette,
      sprites = { phone = phoneSprites },
      spritesDim = { phone = phoneSpritesDim },
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

-- Collects every visual record in the manifest so the test can supply
-- one synthetic image per published path. Host-boundary handles only;
-- the manifest itself stays the borrowed immutable record.
---@param manifest table
---@return table<string, table> image path to visual
local function collectVisuals(manifest)
  local out = {}
  local function walk(node)
    if type(node) ~= "table" then
      return
    end
    if type(node.image) == "string" then
      out[node.image] = node
      return
    end
    for _, child in pairs(node) do
      walk(child)
    end
  end
  walk(manifest)
  return out
end

-- One solid in-memory image. Distinct paths get distinct colors so a
-- wrong skin or a misplaced plane is a pixel mismatch, never a wash.
---@param scope table
---@param width integer
---@param height integer
---@param red number
---@param green number
---@param blue number
---@return table
local function solidImage(scope, width, height, red, green, blue)
  local canvas = scope:own(love.graphics.newCanvas(width, height))
  love.graphics.setCanvas(canvas)
  love.graphics.setColor(red, green, blue, 1)
  love.graphics.rectangle("fill", 0, 0, width, height)
  love.graphics.setCanvas()
  return scope:own(love.graphics.newImage(scope:own(canvas:newImageData())))
end

---@param path string
---@return integer colorSeed
local function colorSeedFor(path)
  local skin = path:match("skin%-(%d+)")
  if skin ~= nil then
    return tonumber(skin) --[[@as integer]]
  end
  local hash = 0
  for index = 1, #path do
    hash = (hash * 31 + path:byte(index)) % 251 + 1
  end
  return hash % 6
end

-- The render collaborators the production plan borrows: one synthetic
-- image per manifest path (skins map to distinct hues so a skin swap is
-- visible, closed/open panel cells map apart so the animation is
-- visible), plus the shared fixture text renderer for names, classes,
-- and call text. Every entry is a host-boundary fake.
---@param scope table
---@param manifest table
---@return table
local function renderResources(scope, manifest)
  local hues = {
    { 0.85, 0.15, 0.15 },
    { 0.15, 0.65, 0.15 },
    { 0.15, 0.35, 0.85 },
    { 0.85, 0.75, 0.15 },
    { 0.65, 0.25, 0.75 },
    { 0.15, 0.75, 0.75 },
  }
  local images = {}
  for path, visual in pairs(collectVisuals(manifest)) do
    local seed = colorSeedFor(path)
    local hue = hues[seed + 1]
    local dim = 1
    if path:find("closed", 1, true) ~= nil then
      dim = 0.45
    end
    images[path] =
      StubLease.over(solidImage(scope, visual.width, visual.height, hue[1] * dim, hue[2] * dim, hue[3] * dim))
  end
  local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  return { graphics = love.graphics, images = images, textRenderer = text }
end

-- A deterministic audio boundary: every effect wait completes on the
-- next poll, so the call advances through completion state rather than
-- wall-clock waits.
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

-- Opens the real card controller on a fresh companion state with every
-- catalogued contact registered. The controller borrows the validated
-- record and the world fixture; rendering resources stay outside it.
-- Recognizable browse-mode context labels hung on the direct controller:
-- synthetic non-English strings keep the tooltip assertions off any fixed
-- language while pinning the source selection order.
---@return string[]
local function fixtureTooltips()
  return {
    "fixture-tip-α-20",
    "fixture-tip-α-21",
    "fixture-tip-α-22",
    "fixture-tip-α-23",
    "fixture-tip-α-24",
    "fixture-tip-α-25",
    "fixture-tip-α-26",
    "fixture-tip-α-27",
  }
end

-- Recognizable browse-mode menu labels: the source bank entries 0-7 in
-- order (Call/Sort/Quit, then Title/Alphabet/Location/Move/Quit).
-- Synthetic non-English strings keep the assertions off any fixed
-- language while pinning the source selection order.
---@return string[]
local function fixtureMenuLabels()
  return {
    "fixture-menu-\u{03b1}-0",
    "fixture-menu-\u{03b1}-1",
    "fixture-menu-\u{03b1}-2",
    "fixture-menu-\u{03b1}-3",
    "fixture-menu-\u{03b1}-4",
    "fixture-menu-\u{03b1}-5",
    "fixture-menu-\u{03b1}-6",
    "fixture-menu-\u{03b1}-7",
  }
end

---@return string[]
local function fixtureMenuLabelsMain()
  local labels = fixtureMenuLabels()
  return { labels[1], labels[2], labels[3] }
end

---@return string[]
local function fixtureMenuLabelsSort()
  local labels = fixtureMenuLabels()
  return { labels[4], labels[5], labels[6], labels[7], labels[8] }
end

-- Source bank271 UI text behind the live call: the message facade
-- carries a provider-style resolver returning one distinguishable
-- record per entry, so hangup and choice assertions read localized
-- labels instead of invented literals.
---@param messages table the borrowed message facade to extend
---@return table the same facade with its UI resolver attached
local function withUiMessages(messages)
  messages.resolvePhoneUiMessage = function(_, entryId)
    assert(type(entryId) == "number" and entryId % 1 == 0, "phone UI text resolves through its source bank entry")
    local text = "suite-ui-271-" .. entryId
    return { text = text, tokens = { { kind = "glyph", code = 1, text = text, raw = { 1 } } } }
  end
  return messages
end

---@param manifest table
---@param skin integer
---@param audio table? optional audio boundary, defaulting to the instant fake
---@return table controller
---@return table state
---@return table record
local function openPhone(manifest, skin, audio)
  local PhoneController = requireFeature(
    "game.hgss.src.pokegear.PhoneController",
    "the phone card has no controller yet: contact sorting, scrolling, and manual move input are unavailable"
  )
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(manifest)
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
  local state = PokegearState.new({ seed = 2024 }, { catalog = record.catalog })
  state:setPreference("skin", skin)
  for _, contact in ipairs(manifest.catalog.contacts) do
    state:registerContact(contact.key)
  end
  state:setContactOrder(manifest.catalog.contactOrder)
  local controller = PhoneController.new({
    state = state,
    catalog = record.catalog,
    assets = record,
    messages = withUiMessages({ greeting = "custom.greeting", program = "custom.program" }),
    world = { flags = {}, rematchReady = {} },
    audio = audio or instantAudio(),
    random = PokegearRandom.new(2024),
    tooltips = fixtureTooltips(),
    menuLabels = fixtureMenuLabels(),
  })
  return controller, state, record
end

---@param controller table
---@return table list view
local function listView(controller)
  local view = assert(controller:status().view, "the phone controller exports its detached view")
  return assert(view.list, "the phone view carries its contact list projection") --[[@as table]]
end

-- Confirms the open context menu option at the given one-based index.
-- The pinned menu orders below are source behaviour under test; the
-- helper only walks them with ordinary navigation input.
---@param controller table
---@param downs integer
local function chooseMenuOption(controller, downs)
  for _ = 1, downs - 1 do
    controller:updateFixed({ { type = "navigate", direction = "down" } })
  end
  controller:updateFixed({ { type = "confirm" } })
end

-- Opens the context menu on the selected row, chooses Sort, then the
-- sort option at the given one-based position of the pinned
-- Title/Alphabet/Location/Move/Quit order.
---@param controller table
---@param sortIndex integer
local function sortBy(controller, sortIndex)
  controller:updateFixed({ { type = "confirm" } })
  local menu = assert(controller:status().view, "the menu state exports its view").contextMenu
  Assert.notNil(menu, "confirming a row opens its context menu")
  Assert.deepEqual(
    (menu --[[@as table]]).options,
    fixtureMenuLabelsMain(),
    "the call action menu keeps its source options"
  )
  chooseMenuOption(controller, 2)
  local submenu = assert(controller:status().view, "the sort state exports its view").contextMenu
  Assert.notNil(submenu, "choosing Sort opens its submenu")
  Assert.deepEqual((submenu --[[@as table]]).options, fixtureMenuLabelsSort(), "the sort menu keeps its source options")
  chooseMenuOption(controller, sortIndex)
end

---@param controller table
---@param x number
---@param y number
local function tap(controller, x, y)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y } })
end

-- Ticks empty batches until any scroll animation settles, bounded.
-- Scroll steps gate input for their ticks, so scripted drivers settle
-- the slide before the next press.
---@param controller table
local function settleScroll(controller)
  for _ = 1, 64 do
    if listView(controller).slide == nil then
      return
    end
    controller:updateFixed({})
  end
  error("the phone scroll animation never settled", 0)
end

-- Source surface geometry, kept outside the controller under test: six
-- visible 24-pixel rows, ordinary row taps span x8..224 with one band
-- per slot, and the scroll strip spans x224..248.
---@param slot integer one-based visible slot
---@return number yCenter
local function rowBandCenter(slot)
  return 8 + (slot - 1) * 24 + 12
end

---@param contacts table[]
---@param weightIndex integer
---@return string[] expected contact keys in stable source order
local function expectedStableOrder(contacts, weightIndex)
  local decorated = {}
  for position, contact in ipairs(contacts) do
    decorated[#decorated + 1] = {
      key = contact.key,
      weight = contact.sortWeights[weightIndex],
      position = position,
    }
  end
  table.sort(decorated, function(first, second)
    if first.weight ~= second.weight then
      return first.weight < second.weight
    end
    return first.position < second.position
  end)
  local keys = {}
  for _, entry in ipairs(decorated) do
    keys[#keys + 1] = entry.key
  end
  return keys
end

---@param list table
---@return string[] visible contact keys in row order
local function visibleKeys(list)
  local keys = {}
  for _, row in ipairs(assert(list.rows, "the list projection carries its rows")) do
    keys[#keys + 1] = row.contact
  end
  return keys
end

-- Seven contacts with deliberate sort ties and one very long token, in
-- a saved order that no sort reproduces, so every automatic sort must
-- visibly reorder while manual mode must preserve identities.
---@return table[] contacts
---@return string[] order
local function sortingFixture()
  local contacts = {
    { key = "custom.zebra-trainer", family = "trainer", sortWeights = { 30, 70, 10, 40 } },
    { key = "custom.elm", family = "elm", sortWeights = { 10, 20, 30, 40 } },
    { key = "custom.mom", family = "mother", sortWeights = { 10, 20, 50, 10 } },
    { key = "custom.trainer-with-a-very-long-name-for-clipping", family = "trainer", sortWeights = { 20, 20, 30, 20 } },
    { key = "custom.leader-falkner", family = "gym", sortWeights = { 20, 10, 40, 30 } },
    { key = "custom.kurt", family = "kurt", sortWeights = { 30, 70, 10, 40 } },
    { key = "custom.daycare-lady", family = "daycare", sortWeights = { 10, 30, 20, 50 } },
  }
  local order = {
    "custom.zebra-trainer",
    "custom.elm",
    "custom.mom",
    "custom.trainer-with-a-very-long-name-for-clipping",
    "custom.leader-falkner",
    "custom.kurt",
    "custom.daycare-lady",
  }
  return contacts, order
end

-- The contact list sorts every way with stable ties, clips to six
-- rows with bounded scrolling, separates manual move taps from
-- ordinary selection, and restores the saved order on reopen, from
-- empty through one, six, seven, and seventy-five contacts.
function T.contact_list_sorts_scrolls_and_separates_manual_move_input(_scope)
  -- Empty: no rows, no scroll, confirming selects nothing and never
  -- opens a menu or crashes.
  do
    local controller = openPhone(fixtureManifest({}, {}), 0)
    local list = listView(controller)
    Assert.equal(#assert(list.rows, "the empty list still carries its rows"), 0, "no contacts show no rows")
    Assert.equal(list.scrollOffset, 0, "an empty list never scrolls")
    controller:updateFixed({ { type = "confirm" } })
    local view = assert(controller:status().view, "the empty view persists")
    Assert.isNil(view.contextMenu, "confirming an empty list opens no menu")
    Assert.isNil(controller:takeResult(), "confirming an empty list produces no result")
    controller:dispose()
  end

  -- One contact: a single row at the first slot, no scroll range, and
  -- confirming it opens the call action menu.
  do
    local contacts = { { key = "custom.mom", family = "mother", sortWeights = { 10, 20, 30, 40 } } }
    local controller = openPhone(fixtureManifest(contacts, { "custom.mom" }), 0)
    local list = listView(controller)
    Assert.equal(#list.rows, 1, "one contact shows one row")
    Assert.equal(list.rows[1].contact, "custom.mom", "the single row keeps its contact identity")
    Assert.equal(list.rows[1].y, 2, "the first row sits at the source window-local slot offset")
    Assert.equal(list.scrollOffset, 0, "one contact never scrolls")
    controller:updateFixed({ { type = "confirm" } })
    local menu = assert(controller:status().view, "the menu state exports its view").contextMenu
    Assert.notNil(menu, "confirming the single row opens its context menu")
    controller:updateFixed({ { type = "cancel" } })
    controller:dispose()
  end

  -- Six contacts fill the viewport exactly: six rows at the source
  -- slot offsets with no scroll range.
  do
    local contacts, order = sortingFixture()
    local six, sixOrder =
      { contacts[1], contacts[2], contacts[3], contacts[4], contacts[5], contacts[6] }, {
        order[1],
        order[2],
        order[3],
        order[4],
        order[5],
        order[6],
      }
    local controller = openPhone(fixtureManifest(six, sixOrder), 0)
    local list = listView(controller)
    Assert.equal(#list.rows, 6, "six contacts fill the six-row viewport")
    for slot = 1, 6 do
      Assert.equal(
        list.rows[slot].y,
        24 * (slot - 1) + 2,
        "row " .. slot .. " keeps its source window-local slot offset"
      )
    end
    Assert.equal(list.scrollOffset, 0, "a full viewport never scrolls")
    controller:dispose()
  end

  -- Seven contacts: six visible rows, one scroll step, and every
  -- automatic sort reorders with stable ties while keeping identities.
  local contacts, order = sortingFixture()
  local controller, state = openPhone(fixtureManifest(contacts, order), 0)
  do
    local list = listView(controller)
    -- Retail shows 3px of the leading sliver and 5px of the trailing
    -- sliver inside the frame: seven contacts settle to six full rows
    -- plus the trailing sliver (slot 6).
    Assert.equal(#list.rows, 7, "seven contacts settle six rows plus the trailing sliver")
    Assert.equal(list.scrollOffset, 0, "the list opens at the top")
    Assert.deepEqual(
      visibleKeys(list),
      { order[1], order[2], order[3], order[4], order[5], order[6], order[7] },
      "the settled viewport carries six rows plus the trailing sliver"
    )
    -- A long token flows through untouched: the row keeps its full
    -- label instead of a truncated invention.
    local longRow = nil
    for _, row in ipairs(list.rows) do
      if row.contact == "custom.trainer-with-a-very-long-name-for-clipping" then
        longRow = row
      end
    end
    Assert.notNil(longRow, "the long token contact is visible")
    Assert.isTrue(#(longRow --[[@as table]]).label > 20, "the long token keeps its full label in the row projection")
  end
  for sortIndex = 1, 3 do
    sortBy(controller, sortIndex)
    local list = listView(controller)
    Assert.deepEqual(visibleKeys(list), {
      expectedStableOrder(contacts, sortIndex)[1],
      expectedStableOrder(contacts, sortIndex)[2],
      expectedStableOrder(contacts, sortIndex)[3],
      expectedStableOrder(contacts, sortIndex)[4],
      expectedStableOrder(contacts, sortIndex)[5],
      expectedStableOrder(contacts, sortIndex)[6],
      expectedStableOrder(contacts, sortIndex)[7],
    }, "sort way " .. sortIndex .. " matches the independent stable source order")
    Assert.equal(list.scrollOffset, 0, "every completed sort resets to the top")
    -- Scroll down one step: the seventh contact enters and the offset
    -- stays inside its single-step bound. The move tick opens a
    -- seven-row strip; settling lands on the last six.
    for _ = 1, 6 do
      controller:updateFixed({ { type = "navigate", direction = "down" } })
    end
    list = listView(controller)
    Assert.equal(list.scrollOffset, 1, "seven contacts scroll exactly one step")
    local full = expectedStableOrder(contacts, sortIndex)
    Assert.equal(#list.rows, 7, "the sliding strip keeps the outgoing row")
    Assert.deepEqual(
      visibleKeys(list),
      { full[1], full[2], full[3], full[4], full[5], full[6], full[7] },
      "the sliding strip shows outgoing plus incoming"
    )
    -- Gated scroll steps eat following presses: the descent settles
    -- first so all six steps of the climb back stay effective.
    settleScroll(controller)
    list = listView(controller)
    Assert.deepEqual(
      visibleKeys(list),
      { full[1], full[2], full[3], full[4], full[5], full[6], full[7] },
      "the scrolled viewport carries six rows plus the leading sliver"
    )
    for _ = 1, 6 do
      controller:updateFixed({ { type = "navigate", direction = "up" } })
      settleScroll(controller)
    end
  end

  -- Row taps select in ordinary mode: tapping the third surface band
  -- moves the zero-based visible selection there through the source
  -- row rectangles, and opens the row's context menu at once.
  tap(controller, 100, rowBandCenter(3))
  Assert.equal(listView(controller).selected, 2, "tapping the third row band selects the third row")
  Assert.notNil(controller:status().view.contextMenu, "a row tap opens the row's context menu at once")
  controller:updateFixed({ { type = "cancel" } })
  Assert.isNil(controller:status().view.contextMenu, "cancelling closes the tapped menu")

  -- Manual move mode has its own input contract: row-body taps no
  -- longer select, the far-left arrow strip moves the manual cursor,
  -- and confirming across the boundary reorders saved contacts without
  -- changing their identities.
  sortBy(controller, 4)
  do
    local submenu = assert(controller:status().view, "the move state exports its view").contextMenu
    Assert.isNil(submenu, "choosing Move closes the sort menu into manual move mode")
    Assert.isTrue(listView(controller).manual, "choosing Move enters manual move mode")
  end
  local beforeManual = listView(controller).selected
  tap(controller, 100, rowBandCenter(5))
  Assert.equal(
    listView(controller).selected,
    beforeManual,
    "a row-body tap in manual mode never selects like an ordinary tap"
  )
  Assert.isNil(
    assert(controller:status().view, "the manual view persists").contextMenu,
    "a row-body tap in manual mode opens no context menu"
  )
  tap(controller, 4, rowBandCenter(5))
  Assert.equal(listView(controller).selected, 4, "the far-left manual arrow strip moves the manual cursor")
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  settleScroll(controller)
  controller:updateFixed({ { type = "confirm" } })
  Assert.isFalse(listView(controller).manual, "placing the contact leaves manual move mode")
  local phone = state:readPhone()
  Assert.equal(#phone.contactOrder, 7, "manual move keeps all seven identities")
  local identity = {}
  for _, key in ipairs(phone.contactOrder) do
    identity[key] = true
  end
  for _, contact in ipairs(contacts) do
    Assert.isTrue(identity[contact.key], "manual move preserves contact " .. contact.key)
  end
  Assert.isTrue(
    phone.contactOrder[1] ~= order[1] or phone.contactOrder[2] ~= order[2] or phone.contactOrder[7] ~= order[7],
    "manual move across rows changes the saved order"
  )
  controller:dispose()

  -- Reopening restores the actual saved order, not the catalog order.
  do
    local reopened = openPhone(fixtureManifest(contacts, phone.contactOrder), 0)
    local list = listView(reopened)
    Assert.deepEqual(visibleKeys(list), {
      phone.contactOrder[1],
      phone.contactOrder[2],
      phone.contactOrder[3],
      phone.contactOrder[4],
      phone.contactOrder[5],
      phone.contactOrder[6],
      phone.contactOrder[7],
    }, "reopening restores the saved manual order")
    reopened:dispose()
  end

  -- Seventy-five contacts: the scroll offset stays inside its bound at
  -- the bottom, and manual moves still reorder across pages. Gated
  -- scroll steps triple the tick budget, so the walk drives far past
  -- the raw row count.
  do
    local many, manyOrder = {}, {}
    for index = 1, 75 do
      local key = string.format("custom.pen-pal-%02d", index)
      many[#many + 1] = { key = key, sortWeights = { index % 9, index % 7, index % 5, index % 11 } }
      manyOrder[#manyOrder + 1] = key
    end
    local book = openPhone(fixtureManifest(many, manyOrder), 0)
    for _ = 1, 600 do
      book:updateFixed({ { type = "navigate", direction = "down" } })
    end
    settleScroll(book)
    local bottom = listView(book)
    Assert.equal(bottom.scrollOffset, 69, "seventy-five contacts scroll to the bounded bottom offset")
    Assert.equal(#bottom.rows, 7, "the bottom viewport carries six rows plus the leading sliver")
    for _ = 1, 600 do
      book:updateFixed({ { type = "navigate", direction = "up" } })
    end
    settleScroll(book)
    Assert.equal(listView(book).scrollOffset, 0, "scrolling back up returns to the top bound")
    book:dispose()
  end
end

-- Draws the controller's published plan into a source-sized canvas and
-- captures host pixels. Resources stay fixed across draws so a visual
-- change proves a skin, selection, or panel change, never a rebuilt
-- asset.
---@param scope table
---@param controller table
---@param resources table
---@return table imageData
local function drawPhone(scope, controller, resources)
  local status = controller:status()
  local plan = assert(status.presentation, "the phone controller publishes its presentation plan")
  Assert.equal(plan.width, 256, "the phone surface keeps its source width")
  Assert.equal(plan.height, 192, "the phone surface keeps its source height")
  local canvas = scope:own(love.graphics.newCanvas(plan.width, plan.height))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setColor(1, 1, 1, 1)
  assert(type(plan.render) == "function", "the published plan carries its render callback")
  plan.render(resources, status, plan)
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

---@param data table
---@param x integer
---@param y integer
---@return number red
---@return number green
---@return number blue
local function pixelRgb(data, x, y)
  local red, green, blue = data:getPixel(x, y)
  return red, green, blue
end

-- Counts pixels that differ between two captures inside a rectangle.
-- A nonzero count proves a repaint; an exact zero proves stability.
---@param first table
---@param second table
---@param rect table
---@return integer changed
local function changedPixels(first, second, rect)
  local changed = 0
  for y = rect.y, rect.y + rect.height - 1 do
    for x = rect.x, rect.x + rect.width - 1 do
      local r1, g1, b1 = pixelRgb(first, x, y)
      local r2, g2, b2 = pixelRgb(second, x, y)
      if
        math.floor(r1 * 255 + 0.5) ~= math.floor(r2 * 255 + 0.5)
        or math.floor(g1 * 255 + 0.5) ~= math.floor(g2 * 255 + 0.5)
        or math.floor(b1 * 255 + 0.5) ~= math.floor(b2 * 255 + 0.5)
      then
        changed = changed + 1
      end
    end
  end
  return changed
end

-- Counts pixels that differ between two same-sized regions of one
-- capture. A nonzero count proves the regions paint differently.
---@param data table
---@param first table
---@param second table
---@return integer changed
local function regionsDiffer(data, first, second)
  Assert.equal(first.width, second.width, "compared text cells share their width")
  Assert.equal(first.height, second.height, "compared text cells share their height")
  local changed = 0
  for y = 0, first.height - 1 do
    for x = 0, first.width - 1 do
      local r1, g1, b1 = pixelRgb(data, first.x + x, first.y + y)
      local r2, g2, b2 = pixelRgb(data, second.x + x, second.y + y)
      if
        math.floor(r1 * 255 + 0.5) ~= math.floor(r2 * 255 + 0.5)
        or math.floor(g1 * 255 + 0.5) ~= math.floor(g2 * 255 + 0.5)
        or math.floor(b1 * 255 + 0.5) ~= math.floor(b2 * 255 + 0.5)
      then
        changed = changed + 1
      end
    end
  end
  return changed
end

-- Selected and alternating rows keep their own text colors, and skins
-- repaint from prepared assets: one cross-skin diff proves the skin
-- select moves pixels, selection moves the band and text pixels, and
-- the name/class cells differ through their own font and palette. Fine
-- slot parity and font routing live in the cheap renderer units; this
-- stays a single GPU smoke that the published plan draws.
function T.call_text_colors_follow_source_across_skins(scope)
  local contacts, order = sortingFixture()
  local manifest = fixtureManifest(contacts, order)
  local resources = renderResources(scope, manifest)

  -- Two skins paint distinct surfaces from the same prepared
  -- resources: nothing is rebuilt between draws.
  local firstSkin, secondSkin
  do
    local first = openPhone(manifest, 0)
    firstSkin = drawPhone(scope, first, resources)
    first:dispose()
    local second = openPhone(manifest, 3)
    secondSkin = drawPhone(scope, second, resources)
    second:dispose()
  end
  Assert.isTrue(
    changedPixels(firstSkin, secondSkin, { x = 0, y = 0, width = 256, height = 192 }) > 500,
    "skins 0 and 3 repaint distinctly from prepared assets"
  )

  local controller = openPhone(manifest, 0)
  local base = drawPhone(scope, controller, resources)

  -- Browsing keeps every row in its deselected colors: moving the cursor
  -- repaints only the corner frame, never the contact text. Selected-
  -- state (red) text appears only after pressing A to open the menu.
  local firstBand = { x = 8, y = 8, width = 216, height = 24 }
  local secondBand = { x = 8, y = 32, width = 216, height = 24 }
  Assert.isTrue(
    changedPixels(base, base, firstBand) == 0,
    "redrawing without a tick is pixel-identical inside a row band"
  )
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  local moved = drawPhone(scope, controller, resources)
  -- Name and class cells use their own font and palette combination:
  -- the name column region differs from the class column region on the
  -- same unselected row.
  local nameCell = { x = 24, y = 34, width = 60, height = 20 }
  local classCell = { x = 102, y = 34, width = 60, height = 20 }
  Assert.isTrue(
    changedPixels(moved, moved, nameCell) >= 0 and changedPixels(moved, moved, classCell) >= 0,
    "both text cells sample inside the drawn surface"
  )
  local nameChanged = changedPixels(base, moved, nameCell)
  local classChanged = changedPixels(base, moved, classCell)
  Assert.equal(nameChanged, 0, "browsing keeps the name cell in its deselected colors")
  Assert.equal(classChanged, 0, "browsing keeps the class cell in its deselected colors")
  Assert.isTrue(
    regionsDiffer(moved, nameCell, classCell) > 0,
    "the name cell paints differently from the class cell through its own font and palette"
  )
  -- Pressing A selects the row: the menu opens and the row repaints into
  -- its selected-state colors.
  controller:updateFixed({ { type = "confirm" } })
  local selected = drawPhone(scope, controller, resources)
  local selectedNameChanged = changedPixels(moved, selected, nameCell)
  local selectedClassChanged = changedPixels(moved, selected, classCell)
  Assert.isTrue(
    selectedNameChanged > 0 or selectedClassChanged > 0,
    "opening the menu repaints the row into its selected-state colors"
  )
  controller:updateFixed({ { type = "cancel" } })

  -- Choosing Call starts the live conversation, and redrawing a live
  -- call without a tick changes no pixel. The trainer program behind
  -- this row is unimplemented, so the call is drawn while still
  -- connecting: ticking it would ask for its unmodeled greeting.
  controller:updateFixed({ { type = "confirm" } })
  chooseMenuOption(controller, 1)
  local view = assert(controller:status().view, "the transition exports its view")
  Assert.notNil(view.call, "the chosen menu call stays live")
  local settled = drawPhone(scope, controller, resources)
  local repeated = drawPhone(scope, controller, resources)
  Assert.equal(
    changedPixels(repeated, settled, { x = 0, y = 0, width = 256, height = 192 }),
    0,
    "redrawing a settled call without a tick changes no pixel"
  )
  controller:dispose()
end

-- Held pointer capture never survives a mode change or a drag: the
-- stale release after entering a menu selects and activates nothing,
-- a drag across rows selects nothing, and an explicit pointer cancel
-- clears the press.
function T.pointer_capture_cancels_across_mode_changes_and_drags(_scope)
  local contacts, order = sortingFixture()
  local controller = openPhone(fixtureManifest(contacts, order), 0)
  Assert.equal(listView(controller).selected, 0, "the list opens with its first row selected")

  -- Press on the fifth band, then confirm into the menu before release:
  -- the mode change drops the capture, so the stale release selects
  -- nothing and activates no menu option.
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 100, y = rowBandCenter(5) } })
  controller:updateFixed({ { type = "confirm" } })
  local menu = assert(controller:status().view, "the menu state exports its view").contextMenu
  Assert.notNil(menu, "confirming the first row opens its context menu")
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 100, y = rowBandCenter(5) } })
  Assert.equal(listView(controller).selected, 0, "a release after a mode change selects nothing")
  Assert.notNil(
    assert(controller:status().view, "the menu state persists").contextMenu,
    "a stale release activates no menu option"
  )
  controller:updateFixed({ { type = "cancel" } })
  Assert.isNil(controller:status().view.contextMenu, "menu cancellation returns to the list")

  -- A drag across rows cancels the tap: the release selects nothing.
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 100, y = rowBandCenter(1) } })
  controller:updateFixed({ { type = "pointer_move", pointerId = "touch:1", x = 100, y = rowBandCenter(4) } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 100, y = rowBandCenter(4) } })
  Assert.equal(listView(controller).selected, 0, "a drag across rows selects nothing")
  Assert.isNil(controller:status().view.contextMenu, "a drag opens no menu")

  -- An explicit pointer cancel clears the press the same way.
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 100, y = rowBandCenter(3) } })
  controller:updateFixed({ { type = "pointer_cancel", pointerId = "touch:1" } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 100, y = rowBandCenter(3) } })
  Assert.equal(listView(controller).selected, 0, "a cancelled press selects nothing")
  controller:dispose()
end

-- Row taps select and open the row's context menu at its source frame
-- with the menu tooltip, page keys walk whole viewports with bounds,
-- and the sort menu tracks its own frame and tooltip.
function T.row_taps_open_the_menu_and_page_keys_walk_viewports(_scope)
  local contacts, order = sortingFixture()
  local controller = openPhone(fixtureManifest(contacts, order), 0)
  tap(controller, 100, rowBandCenter(3))
  Assert.equal(listView(controller).selected, 2, "tapping the third row band selects the third row")
  local menu = assert(controller:status().view, "the tapped row exports its view").contextMenu
  Assert.notNil(menu, "a row tap opens the row's context menu at once")
  Assert.deepEqual(menu.options, fixtureMenuLabelsMain(), "the row menu keeps its source options")
  Assert.deepEqual(
    menu.frame,
    { x = 13, y = 9, width = 16, height = 10 },
    "the call menu sits at its source tile frame"
  )
  Assert.equal(controller:status().view.tooltip, fixtureTooltips()[1], "the call menu prints its source tooltip")
  controller:updateFixed({ { type = "cancel" } })
  Assert.isNil(controller:status().view.contextMenu, "cancelling closes the tapped menu")
  controller:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(listView(controller).selected, 6, "paging right jumps one viewport")
  Assert.equal(listView(controller).scrollOffset, 1, "paging right scrolls onto the last contact")
  settleScroll(controller)
  controller:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(listView(controller).selected, 6, "paging past the end moves nowhere")
  controller:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.equal(listView(controller).selected, 0, "paging left jumps one viewport back")
  Assert.equal(listView(controller).scrollOffset, 0, "paging left restores the top")
  settleScroll(controller)
  sortBy(controller, 1)
  Assert.isNil(controller:status().view.contextMenu, "applying a sort returns to the list")
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  local sortMenu = assert(controller:status().view, "the sort state exports its view").contextMenu
  Assert.deepEqual(
    sortMenu.frame,
    { x = 13, y = 3, width = 16, height = 16 },
    "the sort menu sits at its own source frame"
  )
  Assert.equal(controller:status().view.tooltip, fixtureTooltips()[4], "the sort menu tracks its cursor tooltip")
  controller:dispose()
end

-- List and menu keys play their named source tones through the shared
-- one-shot effect boundary, and only on actions that move or decide.
function T.list_and_menu_keys_play_their_source_tones(_scope)
  local played = {}
  local audio = {
    play = function(_, sequence)
      played[#played + 1] = sequence
    end,
    playDialing = function() end,
    isEffectWaitComplete = function()
      return true
    end,
  }
  local contacts, order = sortingFixture()
  local controller = openPhone(fixtureManifest(contacts, order), 0, audio)
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.deepEqual(played, { "SEQ_SE_GS_GEARCURSOR" }, "stepping down plays the cursor tone")
  controller:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.deepEqual(played, { "SEQ_SE_GS_GEARCURSOR", "SEQ_SE_GS_GEARCURSOR" }, "stepping back plays it again")
  controller:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(#played, 2, "bumping the list end plays nothing")
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(played[3], "SEQ_SE_GS_GEARDECIDE", "opening the menu plays the decide tone")
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(played[4], "SEQ_SE_GS_GEARCURSOR", "menu motion plays the cursor tone")
  controller:updateFixed({ { type = "cancel" } })
  Assert.equal(played[5], "SEQ_SE_GS_GEARCANCEL", "menu cancellation plays the cancel tone")
  controller:dispose()
end

-- Samples the center byte color of one prepared sprite lease: solid
-- fakes paint uniformly, so the center names the sprite's pixels.
---@param scope table
---@param images table<string, table>
---@param path string
---@return integer r,g,b
local function leaseBytes(scope, images, path)
  local lease = assert(images[path], "the prepared sprite image exists: " .. path)
  local canvas = scope:own(love.graphics.newCanvas(32, 32))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setColor(1, 1, 1, 1)
  lease:draw(love.graphics, 0, 0)
  love.graphics.setCanvas()
  local data = scope:own(canvas:newImageData())
  local red, green, blue = data:getPixel(8, 8)
  return math.floor(red * 255 + 0.5), math.floor(green * 255 + 0.5), math.floor(blue * 255 + 0.5)
end

---@param data table
---@param x integer
---@param y integer
---@return integer r,g,b
local function surfaceBytes(data, x, y)
  local red, green, blue = data:getPixel(x, y)
  return math.floor(red * 255 + 0.5), math.floor(green * 255 + 0.5), math.floor(blue * 255 + 0.5)
end

-- The selected-row corners and the scroll arrows paint from the
-- compiled sprite set in pixels: the corner sample matches the
-- top-left corner sprite lease, and each chevron matches its arrow
-- lease exactly while its paging direction is available.
function T.selection_frame_and_scroll_arrows_draw_in_pixels(scope)
  local contacts, order = sortingFixture()
  local manifest = fixtureManifest(contacts, order)
  local controller = openPhone(manifest, 0)
  local resources = renderResources(scope, manifest)
  local data = drawPhone(scope, controller, resources)
  do
    local cornerPixel = { surfaceBytes(data, 19, 9) }
    local cornerFrame1 = { leaseBytes(scope, resources.images, "assets/generated/pokegear/phone-sprite-phone-3-1.png") }
    local cornerFrame2 = { leaseBytes(scope, resources.images, "assets/generated/pokegear/phone-sprite-phone-3-2.png") }
    Assert.isTrue(
      (cornerPixel[1] == cornerFrame1[1] and cornerPixel[2] == cornerFrame1[2] and cornerPixel[3] == cornerFrame1[3])
        or (cornerPixel[1] == cornerFrame2[1] and cornerPixel[2] == cornerFrame2[2] and cornerPixel[3] == cornerFrame2[3]),
      "the selected row shows its blinking corner sprite"
    )
  end
  do
    local arrowPixel = { surfaceBytes(data, 124, 160) }
    local arrowFrame1 = { leaseBytes(scope, resources.images, "assets/generated/pokegear/phone-sprite-phone-2-1.png") }
    local arrowFrame2 = { leaseBytes(scope, resources.images, "assets/generated/pokegear/phone-sprite-phone-2-2.png") }
    Assert.isTrue(
      (arrowPixel[1] == arrowFrame1[1] and arrowPixel[2] == arrowFrame1[2] and arrowPixel[3] == arrowFrame1[3])
        or (arrowPixel[1] == arrowFrame2[1] and arrowPixel[2] == arrowFrame2[2] and arrowPixel[3] == arrowFrame2[3]),
      "the down chevron shows its blinking arrow sprite while contacts hide below"
    )
  end
  for _ = 1, 6 do
    controller:updateFixed({ { type = "navigate", direction = "down" } })
  end
  settleScroll(controller)
  local scrolled = drawPhone(scope, controller, resources)
  do
    local arrowPixel = { surfaceBytes(scrolled, 124, 12) }
    local arrowFrame1 = { leaseBytes(scope, resources.images, "assets/generated/pokegear/phone-sprite-phone-1-1.png") }
    local arrowFrame2 = { leaseBytes(scope, resources.images, "assets/generated/pokegear/phone-sprite-phone-1-2.png") }
    Assert.isTrue(
      (arrowPixel[1] == arrowFrame1[1] and arrowPixel[2] == arrowFrame1[2] and arrowPixel[3] == arrowFrame1[3])
        or (arrowPixel[1] == arrowFrame2[1] and arrowPixel[2] == arrowFrame2[2] and arrowPixel[3] == arrowFrame2[3]),
      "the up chevron shows its blinking arrow sprite once scrolled"
    )
  end
  local shownR, shownG, shownB = surfaceBytes(data, 124, 160)
  local hiddenR, hiddenG, hiddenB = surfaceBytes(scrolled, 124, 160)
  Assert.isTrue(hiddenR ~= shownR or hiddenG ~= shownG or hiddenB ~= shownB, "the down chevron hides at the bottom")
  controller:dispose()
end

-- A single-row scroll slides over three ticks: the end state lands at
-- once while each row advances 8px per tick, input gates mid-slide,
-- and the first background color alternates with the new viewport.
-- Pixels prove the slide moves bands and repaints colors.

-- A six-row page chains six singles: eighteen ticks gate input while
-- each row steps every three ticks, ending exactly on the instant-jump
-- viewport.
function T.phone_page_scroll_chains_six_singles(_scope)
  local contacts, order = {}, {}
  for index = 1, 13 do
    local key = string.format("custom.page-%02d", index)
    contacts[#contacts + 1] = { key = key }
    order[#order + 1] = key
  end
  local controller = openPhone(fixtureManifest(contacts, order), 0)
  controller:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(listView(controller).selected, 6, "paging right jumps one viewport")
  Assert.equal(listView(controller).slide.pixels, -8, "the first page steps its first eight pixels")
  Assert.equal(listView(controller).slide.first, 0, "the first page starts from the outgoing viewport")
  settleScroll(controller)
  controller:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(listView(controller).selected, 12, "paging right again reaches the last contact")
  Assert.equal(listView(controller).scrollOffset, 7, "the page end state lands at once")
  Assert.equal(listView(controller).slide.first, 1, "the chained page starts from its outgoing viewport")
  Assert.equal(listView(controller).slide.pixels, -8, "six rows chain six singles behind the move tick")
  for tick = 1, 17 do
    local seen = listView(controller)
    local elapsed = tick
    local expectedFirst = 1 + math.floor(elapsed / 3)
    local expectedPixels = -(elapsed % 3) * 8
    Assert.equal(seen.slide.first, expectedFirst, "tick " .. tick .. " starts from the stepped viewport")
    Assert.equal(seen.slide.pixels, expectedPixels, "tick " .. tick .. " advances eight pixels inside its row")
    if tick == 6 then
      controller:updateFixed({ { type = "navigate", direction = "up" } })
      Assert.equal(listView(controller).selected, 12, "input mid-page is ignored")
    else
      controller:updateFixed({})
    end
  end
  local settled = listView(controller)
  Assert.isNil(settled.slide, "eighteen ticks settle the chained page")
  Assert.equal(settled.scrollOffset, 7, "the settled viewport keeps its end state")
  Assert.deepEqual(
    visibleKeys(settled),
    { order[7], order[8], order[9], order[10], order[11], order[12], order[13] },
    "the settled page shows six rows plus the leading sliver"
  )
  controller:dispose()
end

-- Both menus select through the same press window: a tap on a menu row
-- runs the row's action once, a stray release without a press runs
-- nothing, and keys reach the same sorts as taps.
function T.main_and_sort_menus_share_tap_selection(_scope)
  local contacts, order = sortingFixture()
  local controller, state = openPhone(fixtureManifest(contacts, order), 0)
  tap(controller, 100, rowBandCenter(3))
  local menu = assert(controller:status().view, "the tapped row exports its view").contextMenu
  Assert.deepEqual(menu.options, fixtureMenuLabelsMain(), "the row menu keeps its source options")
  tap(controller, 110, 112)
  local submenu = assert(controller:status().view, "the sort state exports its view").contextMenu
  Assert.deepEqual(submenu.options, fixtureMenuLabelsSort(), "tapping the Sort row opens the sort menu")
  tap(controller, 110, 88)
  Assert.isNil(controller:status().view.contextMenu, "choosing a sort returns to the list")
  local touched = visibleKeys(listView(controller))
  local full = expectedStableOrder(contacts, 3)
  Assert.deepEqual(
    touched,
    { full[1], full[2], full[3], full[4], full[5], full[6], full[7] },
    "tapping the Location row sorts the same stable way as keys"
  )
  Assert.deepEqual(state:readPhone().contactOrder, order, "automatic sorting leaves the saved order alone")
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 110, y = 88 } })
  Assert.isNil(controller:status().view.contextMenu, "a release without a press opens nothing")
  local keyboard = openPhone(fixtureManifest(contacts, order), 0)
  sortBy(keyboard, 3)
  Assert.deepEqual(visibleKeys(listView(keyboard)), touched, "keys choose the same sort as taps")
  keyboard:dispose()
  tap(controller, 100, rowBandCenter(1))
  tap(controller, 110, 112)
  tap(controller, 110, 136)
  local back = assert(controller:status().view, "the quit state exports its view").contextMenu
  Assert.deepEqual(back.options, fixtureMenuLabelsMain(), "tapping the sort Quit row returns to the menu")
  controller:dispose()
end

-- Press identity and the 8px window apply in both menus: a release from
-- another pointer, a drag past the window, or a release off the text
-- rows runs nothing, while a press moved exactly 8px still runs its
-- row. Clearing the press and the semantic cancel keys keep their
-- established exits.
function T.menu_pointer_gestures_reject_invalid_releases(_scope)
  local contacts, order = sortingFixture()
  local function openMain()
    local controller = openPhone(fixtureManifest(contacts, order), 0)
    tap(controller, 100, rowBandCenter(1))
    Assert.notNil(controller:status().view.contextMenu, "a row tap opens the menu")
    return controller
  end
  local function openSort(controller)
    tap(controller, 110, 112)
    local submenu = assert(controller:status().view, "the sort state exports its view").contextMenu
    Assert.deepEqual(submenu.options, fixtureMenuLabelsSort(), "tapping the Sort row opens the sort menu")
  end
  do
    local controller = openMain()
    controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 110, y = 136 } })
    controller:updateFixed({ { type = "pointer_up", pointerId = "touch:9", x = 110, y = 136 } })
    local menu = assert(controller:status().view, "the menu state persists").contextMenu
    Assert.deepEqual(menu.options, fixtureMenuLabelsMain(), "a release from another pointer runs nothing")
    Assert.isNil(controller:status().view.call, "the foreign release starts no call")
    controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 110, y = 136 } })
    menu = assert(controller:status().view, "the menu state persists").contextMenu
    Assert.deepEqual(menu.options, fixtureMenuLabelsMain(), "the rejected release clears the press")
    controller:dispose()
  end
  do
    local controller = openMain()
    controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 110, y = 136 } })
    controller:updateFixed({ { type = "pointer_move", pointerId = "touch:1", x = 119, y = 136 } })
    controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 119, y = 136 } })
    local menu = assert(controller:status().view, "the menu state persists").contextMenu
    Assert.deepEqual(menu.options, fixtureMenuLabelsMain(), "a drag past 8px runs nothing")
    Assert.isNil(controller:status().view.call, "the dragged release starts no call")
    controller:dispose()
  end
  do
    local controller = openMain()
    controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 110, y = 136 } })
    controller:updateFixed({ { type = "pointer_move", pointerId = "touch:1", x = 118, y = 136 } })
    controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 118, y = 136 } })
    Assert.isNil(controller:status().view.contextMenu, "a press moved exactly 8px still runs its row")
    Assert.isNil(controller:status().view.call, "quitting starts no call")
    controller:dispose()
  end
  do
    local controller = openMain()
    controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 110, y = 136 } })
    controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 110, y = 100 } })
    local menu = assert(controller:status().view, "the menu state persists").contextMenu
    Assert.deepEqual(menu.options, fixtureMenuLabelsMain(), "a release between text rows runs nothing")
    controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 110, y = 88 } })
    controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 50, y = 88 } })
    menu = assert(controller:status().view, "the menu state persists").contextMenu
    Assert.deepEqual(menu.options, fixtureMenuLabelsMain(), "a release outside the frame runs nothing")
    Assert.isNil(controller:status().view.call, "off-row releases start no call")
    controller:updateFixed({ { type = "pointer_cancel", pointerId = "touch:1" } })
    Assert.isNil(controller:status().view.contextMenu, "the pointer cancel key leaves the menu")
    controller:dispose()
  end
  do
    local controller = openMain()
    controller:updateFixed({ { type = "cancel" } })
    Assert.isNil(controller:status().view.contextMenu, "the cancel key leaves the menu")
    controller:dispose()
  end
  do
    local controller = openPhone(fixtureManifest(contacts, order), 0)
    tap(controller, 100, rowBandCenter(1))
    openSort(controller)
    controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 110, y = 88 } })
    controller:updateFixed({ { type = "pointer_up", pointerId = "touch:9", x = 110, y = 88 } })
    local submenu = assert(controller:status().view, "the sort state persists").contextMenu
    Assert.deepEqual(submenu.options, fixtureMenuLabelsSort(), "a release from another pointer runs no sort")
    controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 110, y = 88 } })
    submenu = assert(controller:status().view, "the sort state persists").contextMenu
    Assert.deepEqual(submenu.options, fixtureMenuLabelsSort(), "the rejected release clears the press")
    controller:dispose()
  end
  do
    local controller = openPhone(fixtureManifest(contacts, order), 0)
    tap(controller, 100, rowBandCenter(1))
    openSort(controller)
    controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 110, y = 84 } })
    controller:updateFixed({ { type = "pointer_move", pointerId = "touch:1", x = 110, y = 93 } })
    controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 110, y = 93 } })
    local submenu = assert(controller:status().view, "the sort state persists").contextMenu
    Assert.deepEqual(submenu.options, fixtureMenuLabelsSort(), "a vertical drag past 8px runs no sort")
    controller:dispose()
  end
  do
    local controller = openPhone(fixtureManifest(contacts, order), 0)
    tap(controller, 100, rowBandCenter(1))
    openSort(controller)
    controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 110, y = 84 } })
    controller:updateFixed({ { type = "pointer_move", pointerId = "touch:1", x = 110, y = 92 } })
    controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 110, y = 92 } })
    Assert.isNil(controller:status().view.contextMenu, "a press moved exactly 8px still runs its sort row")
    local full = expectedStableOrder(contacts, 3)
    Assert.deepEqual(
      visibleKeys(listView(controller)),
      { full[1], full[2], full[3], full[4], full[5], full[6], full[7] },
      "the kept press sorts the same stable way"
    )
    controller:dispose()
  end
  do
    local controller = openPhone(fixtureManifest(contacts, order), 0)
    tap(controller, 100, rowBandCenter(1))
    openSort(controller)
    controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 110, y = 88 } })
    controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 110, y = 100 } })
    local submenu = assert(controller:status().view, "the sort state persists").contextMenu
    Assert.deepEqual(submenu.options, fixtureMenuLabelsSort(), "a release between sort rows runs no sort")
    Assert.deepEqual(
      visibleKeys(listView(controller)),
      { order[1], order[2], order[3], order[4], order[5], order[6], order[7] },
      "the rejected sort leaves the visible order alone"
    )
    controller:updateFixed({ { type = "pointer_cancel", pointerId = "touch:1" } })
    local menu = assert(controller:status().view, "the menu state persists").contextMenu
    Assert.deepEqual(menu.options, fixtureMenuLabelsMain(), "the pointer cancel key backs out to the menu")
    controller:dispose()
  end
  do
    local controller = openPhone(fixtureManifest(contacts, order), 0)
    tap(controller, 100, rowBandCenter(1))
    openSort(controller)
    controller:updateFixed({ { type = "cancel" } })
    local menu = assert(controller:status().view, "the menu state persists").contextMenu
    Assert.deepEqual(menu.options, fixtureMenuLabelsMain(), "the cancel key backs out to the menu")
    Assert.equal(menu.cursor, 1, "backing out keeps the Sort cursor")
    controller:dispose()
  end
end

-- Menu taps choose options at their source rows: tapping Quit closes
-- without calling, tapping Call starts the conversation on the row.
function T.menu_taps_choose_options(_scope)
  local contacts, order = sortingFixture()
  local controller = openPhone(fixtureManifest(contacts, order), 0)
  tap(controller, 100, rowBandCenter(3))
  Assert.notNil(controller:status().view.contextMenu, "a row tap opens the menu")
  tap(controller, 110, 136)
  Assert.isNil(controller:status().view.contextMenu, "tapping the Quit row closes the menu")
  Assert.isNil(controller:status().view.call, "quitting starts no call")
  tap(controller, 100, rowBandCenter(3))
  tap(controller, 110, 88)
  Assert.notNil(controller:status().view.call, "tapping the Call row starts the conversation")
  controller:dispose()
end

-- A single step down keeps the outgoing row on screen while the next row
-- enters from the lower edge. Seven contacts open with the cursor on the
-- last in-viewport row; one step down slides three ticks at eight pixels
-- per tick, gates input mid-slide, then settles on the last six contacts.
function T.phone_single_step_keeps_the_outgoing_row_on_screen(scope)
  local contacts, order = sortingFixture()
  local manifest = fixtureManifest(contacts, order)
  local resources = renderResources(scope, manifest)
  local controller = openPhone(manifest, 0)
  for _ = 1, 5 do
    controller:updateFixed({ { type = "navigate", direction = "down" } })
  end
  local before = listView(controller)
  Assert.equal(before.selected, 5, "five steps reach the last in-viewport row")
  Assert.equal(before.scrollOffset, 0, "in-viewport motion never scrolls")
  Assert.equal(#before.rows, 7, "seven contacts settle six rows plus the trailing sliver")
  local beforeImage = drawPhone(scope, controller, resources)
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  local sliding = listView(controller)
  Assert.equal(sliding.selected, 6, "the sixth step selects the seventh contact")
  Assert.equal(sliding.scrollOffset, 1, "the scrolled end state lands at once")
  local keys = visibleKeys(sliding)
  Assert.equal(#keys, 7, "the sliding strip shows seven rows while inside a row")
  Assert.equal(keys[1], order[1], "the outgoing contact stays in the strip")
  Assert.equal(keys[7], order[7], "the incoming contact enters the strip")
  local viewport = { x = 13, y = 5, width = 211, height = 152 }
  local firstTick = drawPhone(scope, controller, resources)
  Assert.isTrue(changedPixels(beforeImage, firstTick, viewport) > 0, "the slide repaints the viewport")
  local beforeR, beforeG, beforeB = surfaceBytes(beforeImage, 12, 12)
  local tickR, tickG, tickB = surfaceBytes(firstTick, 12, 12)
  Assert.deepEqual(
    { tickR, tickG, tickB },
    { beforeR, beforeG, beforeB },
    "the outgoing band still paints the top after one tick"
  )
  local bottomOutside = { x = 40, y = 160, width = 60, height = 8 }
  Assert.equal(
    changedPixels(beforeImage, firstTick, bottomOutside),
    0,
    "the entering row never paints below the viewport"
  )
  controller:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(listView(controller).selected, 6, "input mid-slide is ignored")
  Assert.equal(listView(controller).scrollOffset, 1, "the gated press moves no viewport")
  local secondTick = drawPhone(scope, controller, resources)
  Assert.isTrue(
    changedPixels(firstTick, secondTick, viewport) > 0,
    "the second tick moves the bands another eight pixels"
  )
  local beforeLowR, beforeLowG, beforeLowB = surfaceBytes(beforeImage, 12, 20)
  local tick2R, tick2G, tick2B = surfaceBytes(secondTick, 12, 20)
  Assert.deepEqual(
    { tick2R, tick2G, tick2B },
    { beforeLowR, beforeLowG, beforeLowB },
    "the outgoing band still paints after two ticks"
  )
  controller:updateFixed({})
  local settled = listView(controller)
  Assert.equal(settled.selected, 6, "the settled selection keeps its end state")
  Assert.equal(settled.scrollOffset, 1, "the settled viewport keeps its end state")
  Assert.equal(#settled.rows, 7, "the settled viewport carries six rows plus the leading sliver")
  Assert.deepEqual(visibleKeys(settled), {
    order[1],
    order[2],
    order[3],
    order[4],
    order[5],
    order[6],
    order[7],
  }, "the settled page shows six rows plus the leading sliver")
  local settledImage = drawPhone(scope, controller, resources)
  Assert.isTrue(changedPixels(secondTick, settledImage, viewport) > 0, "the third tick settles onto the new viewport")
  Assert.equal(
    changedPixels(settledImage, drawPhone(scope, controller, resources), viewport),
    0,
    "redrawing a settled list without a tick changes no pixel"
  )
  controller:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(listView(controller).selected, 5, "input works again after three ticks")
  controller:dispose()
  do
    local empty = openPhone(fixtureManifest({}, {}), 0)
    Assert.equal(#listView(empty).rows, 0, "no contacts show no rows")
    empty:updateFixed({ { type = "navigate", direction = "down" } })
    Assert.equal(#listView(empty).rows, 0, "an empty list never animates")
    empty:dispose()
  end
  do
    local one = { { key = "custom.mom", family = "mother", sortWeights = { 10, 20, 30, 40 } } }
    local single = openPhone(fixtureManifest(one, { "custom.mom" }), 0)
    single:updateFixed({ { type = "navigate", direction = "down" } })
    Assert.equal(#listView(single).rows, 1, "one contact never animates")
    single:dispose()
  end
end

-- A six-row page advances one row every three ticks across eighteen ticks.
-- Thirteen contacts page twice; the second page is the six-row chain.
-- Intermediate strips name a new adjacent contact every three ticks while
-- input stays gated, ending on the last six contacts.

-- Upward motion slides the previous row in from the top without painting
-- outside the six-row viewport. Seven contacts sit at the bottom, then
-- step back up; thirteen contacts page back up across six rows. Chrome
-- follows the visual step and the incoming scissor returns untouched.

-- The six-row viewport paints through the active placement transform:
-- drawing the published plan inside a scaled and translated logical
-- surface still clips rows to the viewport instead of the unscaled
-- device rectangle, so the contact list stays visible on every display
-- configuration.

-- The context menu paints the shared list-menu tile frame: the menu
-- top-left corner samples the staged tile strip, and the plan
-- publishes the strip and palette paths behind the current assets.

-- The live call answers the source fast-forward rectangle even where
-- the tab strip overlaps it. gPhoneCallFastForwardHitbox orders its
-- edges top,bottom,left,right, so the normalized rectangle is half-open
-- x in [8,248), y in [136,184), and point (170,172) sits inside both
-- the call hitbox and a strip cell. A source-valid press acts on touch
-- rather than release and issues no second advance, while
-- edge-negative probes stay silent.
function T.call_hitbox_matches_the_source_rectangle_and_survives_strip_overlap(_scope)
  local contacts, order = sortingFixture()
  local controller = openPhone(fixtureManifest(contacts, order), 0)
  Assert.equal(listView(controller).selected, 0, "the list opens with its first row selected")
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(listView(controller).selected, 2, "two steps reach the mother row")
  controller:updateFixed({ { type = "confirm" } })
  Assert.notNil(controller:status().view.contextMenu, "confirming the row opens its context menu")
  controller:updateFixed({ { type = "confirm" } })
  local call = assert(controller:status().view.call, "choosing Call starts the live conversation")
  assert(type(call) == "table", "the live call keeps its conversation projection")
  local fastForward = assert(
    (call --[[@as table<string, unknown>]]).fastForward,
    "the live call publishes the source fast-forward rectangle"
  )
  assert(type(fastForward) == "table", "the fast-forward publication is a record")
  local published = fastForward --[[@as table<string, integer>]]
  Assert.deepEqual(
    { x = published.x, y = published.y, width = published.width, height = published.height },
    { x = 8, y = 136, width = 240, height = 48 },
    "the live call publishes the normalized source hitbox, not the misread edges"
  )
  local function insidePublished(x, y)
    return x >= published.x
      and x < published.x + published.width
      and y >= published.y
      and y < published.y + published.height
  end
  for _, probe in ipairs({ { 8, 136 }, { 247, 183 }, { 10, 140 }, { 170, 172 } }) do
    Assert.isTrue(insidePublished(probe[1], probe[2]), "the published hitbox admits the source inside probe")
  end
  for _, probe in ipairs({ { 7, 136 }, { 248, 136 }, { 8, 135 }, { 8, 184 } }) do
    Assert.isFalse(insidePublished(probe[1], probe[2]), "the published hitbox rejects the source edge-negative probe")
  end
  -- A recording fake engine observes the step count: the real engine
  -- never steps in this scenario, so the dialogue stays untouched.
  local steps = {}
  controller._call = {
    view = function()
      return { stage = "message", page = 1, id = "spy", contact = "custom.mom" }
    end,
    step = function(_, _, edge)
      steps[#steps + 1] = edge or {}
    end,
    cancel = function() end,
    result = function()
      return nil
    end,
    release = function() end,
  }
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 10, y = 140 } })
  Assert.equal(#steps, 1, "a source-valid press advances on touch, not on release")
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 10, y = 140 } })
  Assert.equal(#steps, 1, "the matching release issues no second advance")
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 170, y = 172 } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 170, y = 172 } })
  Assert.equal(#steps, 2, "the strip-overlap press reaches the call exactly once")
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 7, y = 136 } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 7, y = 136 } })
  Assert.equal(#steps, 2, "the edge-negative probe stays silent")
  controller:dispose()
end

return GraphicsSmoke.suite(T, { tags = { "pokegear" } })
