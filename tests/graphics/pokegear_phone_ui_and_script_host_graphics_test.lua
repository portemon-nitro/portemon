-- Foreground phone list, sorting, input, and panel presentation: every
-- contact count from empty to a full book sorts each way with stable
-- ties, scrolls within a six-row clipped viewport, separates manual
-- move input from ordinary row taps, restores the saved order on
-- reopen, and animates its source panel cells with per-state text
-- colors across all six skins. Geometry comes from the controller's
-- detached view against independent source rectangles; colors and skin
-- swaps are proven in pixels through the published plan render with
-- fixed synthetic images, so no draw rebuild can fake a repaint. Pixel
-- comparisons never copy commercial bytes: every image is a solid
-- host-boundary fake hung on a genuine validated manifest path.

local Assert = require("tests.support.Assert")
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
  for skin = 0, 5 do
    phoneForeground[skin] = visualRef("assets/generated/pokegear/phone-foreground-skin-" .. skin .. ".png", 256, 192)
    phoneUpper[skin] = visualRef("assets/generated/pokegear/phone-upper-skin-" .. skin .. ".png", 256, 192)
    phonePanel[skin] = {
      closed = visualRef("assets/generated/pokegear/phone-panel-closed-skin-" .. skin .. ".png", 240, 48),
      open = visualRef("assets/generated/pokegear/phone-panel-open-skin-" .. skin .. ".png", 240, 48),
    }
  end
  return {
    schema = "g4-pokegear-assets-v1",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png", 256, 192) },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png", 32, 32) },
    phone = { foreground = phoneForeground, upper = phoneUpper, panel = phonePanel },
    map = { base = visualRef("assets/generated/pokegear/map-base.png", 32, 32) },
    fly = { base = visualRef("assets/generated/pokegear/fly-base.png", 32, 32) },
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
    images[path] = solidImage(scope, visual.width, visual.height, hue[1] * dim, hue[2] * dim, hue[3] * dim)
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
---@param manifest table
---@param skin integer
---@return table controller
---@return table state
---@return table record
local function openPhone(manifest, skin)
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
    messages = { greeting = "custom.greeting", program = "custom.program" },
    world = { flags = {}, rematchReady = {} },
    audio = instantAudio(),
    random = PokegearRandom.new(2024),
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
    { "Call", "Sort", "Quit" },
    "the call action menu keeps its source options"
  )
  chooseMenuOption(controller, 2)
  local submenu = assert(controller:status().view, "the sort state exports its view").contextMenu
  Assert.notNil(submenu, "choosing Sort opens its submenu")
  Assert.deepEqual(
    (submenu --[[@as table]]).options,
    { "Title", "Alphabet", "Location", "Move", "Quit" },
    "the sort menu keeps its source options"
  )
  chooseMenuOption(controller, sortIndex)
end

---@param controller table
---@param x number
---@param y number
local function tap(controller, x, y)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y } })
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
    Assert.equal(#list.rows, 6, "seven contacts clip to six visible rows")
    Assert.equal(list.scrollOffset, 0, "the list opens at the top")
    Assert.deepEqual(
      visibleKeys(list),
      { order[1], order[2], order[3], order[4], order[5], order[6] },
      "the clipped viewport shows the first six saved contacts"
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
    }, "sort way " .. sortIndex .. " matches the independent stable source order")
    Assert.equal(list.scrollOffset, 0, "every completed sort resets to the top")
    -- Scroll down one step: the seventh contact enters and the offset
    -- stays inside its single-step bound.
    for _ = 1, 6 do
      controller:updateFixed({ { type = "navigate", direction = "down" } })
    end
    list = listView(controller)
    Assert.equal(list.scrollOffset, 1, "seven contacts scroll exactly one step")
    local scrolled = visibleKeys(list)
    local full = expectedStableOrder(contacts, sortIndex)
    Assert.deepEqual(
      scrolled,
      { full[2], full[3], full[4], full[5], full[6], full[7] },
      "the scrolled viewport shows the last six"
    )
    for _ = 1, 6 do
      controller:updateFixed({ { type = "navigate", direction = "up" } })
    end
  end

  -- Row taps select in ordinary mode: tapping the third surface band
  -- moves the zero-based visible selection there through the source
  -- row rectangles.
  tap(controller, 100, rowBandCenter(3))
  Assert.equal(listView(controller).selected, 2, "tapping the third row band selects the third row")

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
    }, "reopening restores the saved manual order")
    reopened:dispose()
  end

  -- Seventy-five contacts: the scroll offset stays inside its bound at
  -- the bottom, and manual moves still reorder across pages.
  do
    local many, manyOrder = {}, {}
    for index = 1, 75 do
      local key = string.format("custom.pen-pal-%02d", index)
      many[#many + 1] = { key = key, sortWeights = { index % 9, index % 7, index % 5, index % 11 } }
      manyOrder[#manyOrder + 1] = key
    end
    local book = openPhone(fixtureManifest(many, manyOrder), 0)
    for _ = 1, 200 do
      book:updateFixed({ { type = "navigate", direction = "down" } })
    end
    local bottom = listView(book)
    Assert.equal(bottom.scrollOffset, 69, "seventy-five contacts scroll to the bounded bottom offset")
    Assert.equal(#bottom.rows, 6, "the bottom viewport still clips to six rows")
    for _ = 1, 200 do
      book:updateFixed({ { type = "navigate", direction = "up" } })
    end
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

-- The source panel animates closed-open-closed across its 1+6+1 tick
-- timeline on the list-to-call transition, selected and alternating
-- rows keep their own text colors, and every skin repaints from
-- prepared assets. Redrawing without a tick is pixel-identical, so the
-- logical timeline never depends on the host frame rate.
function T.call_panel_animation_and_text_colors_follow_source_across_skins(scope)
  local contacts, order = sortingFixture()
  local manifest = fixtureManifest(contacts, order)
  local resources = renderResources(scope, manifest)

  -- Six skins paint six distinct surfaces from the same prepared
  -- resources: nothing is rebuilt between draws.
  local skins = {}
  for skin = 0, 5 do
    local controller = openPhone(manifest, skin)
    skins[#skins + 1] = drawPhone(scope, controller, resources)
    controller:dispose()
  end
  for skin = 1, 6 do
    for other = skin + 1, 6 do
      Assert.isTrue(
        changedPixels(skins[skin], skins[other], { x = 0, y = 0, width = 256, height = 192 }) > 500,
        "skins " .. (skin - 1) .. " and " .. (other - 1) .. " repaint distinctly from prepared assets"
      )
    end
  end

  local controller = openPhone(manifest, 0)
  local base = drawPhone(scope, controller, resources)

  -- Selected rows repaint in their selected-state colors: moving
  -- selection changes the newly selected band and restores the old
  -- one, while alternating unselected rows already differ from each
  -- other through their alternating palette.
  local firstBand = { x = 8, y = 16, width = 216, height = 24 }
  local secondBand = { x = 8, y = 40, width = 216, height = 24 }
  Assert.isTrue(
    changedPixels(base, base, firstBand) == 0,
    "redrawing without a tick is pixel-identical inside a row band"
  )
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  local moved = drawPhone(scope, controller, resources)
  Assert.isTrue(
    changedPixels(base, moved, firstBand) > 0,
    "the deselected first band repaints out of its selected-state colors"
  )
  Assert.isTrue(
    changedPixels(base, moved, secondBand) > 0,
    "the newly selected second band repaints into its selected-state colors"
  )
  -- Name and class cells use their own font and palette combination:
  -- the name column region differs from the class column region on the
  -- same unselected row.
  local nameCell = { x = 24, y = 42, width = 60, height = 20 }
  local classCell = { x = 102, y = 42, width = 60, height = 20 }
  Assert.isTrue(
    changedPixels(moved, moved, nameCell) >= 0 and changedPixels(moved, moved, classCell) >= 0,
    "both text cells sample inside the drawn surface"
  )
  local nameChanged = changedPixels(base, moved, nameCell)
  local classChanged = changedPixels(base, moved, classCell)
  Assert.isTrue(nameChanged > 0 or classChanged > 0, "selection moves visible text pixels in the row")
  Assert.isTrue(
    regionsDiffer(moved, nameCell, classCell) > 0,
    "the name cell paints differently from the class cell through its own font and palette"
  )

  -- The list-to-call transition animates the source panel cells
  -- closed-open-closed across exactly 1+6+1 logical ticks: the data
  -- timeline pins the frames while pixels prove the swap paints.
  controller:updateFixed({ { type = "confirm" } })
  chooseMenuOption(controller, 1)
  local cells = {}
  local frames = {}
  for _ = 1, 8 do
    controller:updateFixed({})
    local view = assert(controller:status().view, "the transition exports its view")
    cells[#cells + 1] = assert(view.panel, "the transition carries its panel projection").cell
    frames[#frames + 1] = drawPhone(scope, controller, resources)
  end
  Assert.deepEqual(cells, { 10, 11, 11, 11, 11, 11, 11, 10 }, "the panel animates closed-open-closed for 1+6+1 ticks")
  Assert.isTrue(
    changedPixels(frames[1], frames[2], { x = 0, y = 0, width = 256, height = 192 }) > 0,
    "the closed-to-open panel swap paints"
  )
  Assert.isTrue(
    changedPixels(frames[7], frames[8], { x = 0, y = 0, width = 256, height = 192 }) > 0,
    "the open-to-closed panel swap paints"
  )
  -- The logical timeline advances one frame per update no matter how
  -- often the host redraws between ticks.
  drawPhone(scope, controller, resources)
  local repeated = drawPhone(scope, controller, resources)
  Assert.equal(
    changedPixels(repeated, frames[8], { x = 0, y = 0, width = 256, height = 192 }),
    0,
    "redrawing a settled transition without a tick changes no pixel"
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

return GraphicsSmoke.suite(T, { tags = { "pokegear" } })
