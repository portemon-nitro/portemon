-- Gear setup-card commit and host display plan: the six-skin setup surface
-- refuses locked confirmations, cancels without writing, commits the
-- confirmed skin through the single mutation boundary, swaps every
-- affected visual from already prepared assets, and spotlights its context
-- menu by dimming everything except the window and the selected thumbnail;
-- every host configuration keeps the information and controls panes in
-- their source roles, pointer taps reach the drawn tab through the same
-- published plan, a resize during a held press cancels the stale release,
-- and border presses never click through into the field.

local Assert = require("tests.support.Assert")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local LocalClock = require("game.src.LocalClock")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearState = require("libs.hgss.src.save.PokegearState")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

-- Loads a shell module that does not exist yet at this baseline. The
-- failure names the missing behaviour instead of surfacing as a suite load
-- error, so the pre-implementation red stays attributable.
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
-- per-skin shell, setup, phone, map, and radio planes, one shell cursor
-- animation with source durations, and the immutable semantic catalogs.
-- Every visual gets a distinct path so the test can hang a distinct solid
-- color on each and watch skin swaps move pixels.
---@return table
local function fixtureManifest()
  local skins, shellForeground, shellInformation = {}, {}, {}
  local configureForeground, configurePatch = {}, {}
  local phoneForeground, phoneUpper = {}, {}
  local radioMain, radioSecond, radioUpper = {}, {}, {}
  local mapForeground, mapUpper = {}, {}
  for skin = 0, 5 do
    skins[skin] = visualRef("assets/generated/pokegear/shell-foreground-skin-" .. skin .. ".png", 256, 192)
    shellForeground[skin] = visualRef("assets/generated/pokegear/shell-foreground-skin-" .. skin .. ".png", 256, 192)
    shellInformation[skin] = visualRef("assets/generated/pokegear/shell-information-skin-" .. skin .. ".png", 256, 192)
    configureForeground[skin] =
      visualRef("assets/generated/pokegear/configure-foreground-skin-" .. skin .. ".png", 256, 192)
    configurePatch[skin] = visualRef("assets/generated/pokegear/configure-patch-skin-" .. skin .. ".png", 48, 40)
    phoneForeground[skin] = visualRef("assets/generated/pokegear/phone-foreground-skin-" .. skin .. ".png", 256, 192)
    phoneUpper[skin] = visualRef("assets/generated/pokegear/phone-upper-skin-" .. skin .. ".png", 256, 192)
    radioMain[skin] = visualRef("assets/generated/pokegear/radio-main-skin-" .. skin .. ".png", 256, 192)
    radioSecond[skin] = visualRef("assets/generated/pokegear/radio-second-skin-" .. skin .. ".png", 256, 192)
    radioUpper[skin] = visualRef("assets/generated/pokegear/radio-upper-skin-" .. skin .. ".png", 256, 192)
    mapForeground[skin] = visualRef("assets/generated/pokegear/map-foreground-skin-" .. skin .. ".png", 256, 192)
    mapUpper[skin] = visualRef("assets/generated/pokegear/map-upper-skin-" .. skin .. ".png", 256, 192)
  end
  return {
    schema = "g4-pokegear-assets-v3",
    skins = skins,
    shell = { foreground = shellForeground, information = shellInformation },
    configure = { foreground = configureForeground, patch = configurePatch },
    phone = { foreground = phoneForeground, upper = phoneUpper },
    map = {
      foreground = mapForeground,
      upper = mapUpper,
      world = visualRef("assets/generated/pokegear/map-world.png", 256, 192),
      upperBase = visualRef("assets/generated/pokegear/map-upper-base.png", 256, 192),
    },
    fly = { pairs = { visualRef("assets/generated/pokegear/fly-pair-1.png", 256, 192) } },
    radio = { main = radioMain, second = radioSecond, upper = radioUpper },
    catalog = {
      contacts = {
        { key = "custom.elm", family = "elm", sortWeight = 10 },
        { key = "custom.mom", family = "mother", sortWeight = 20 },
      },
      contactOrder = { "custom.elm", "custom.mom" },
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
    sequences = {
      ["shell.cursor.main"] = {
        playMode = "forward_loop",
        loopStart = 0,
        frames = {
          {
            image = "assets/generated/pokegear/shell-cursor-main-1.png",
            width = 16,
            height = 16,
            anchorX = 0,
            anchorY = 0,
            durationTicks = 8,
          },
        },
      },
    },
  }
end

-- Collects every visual record in the manifest so the test can supply one
-- synthetic image per published path. Host-boundary handles only; the
-- manifest itself stays the borrowed immutable record.
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

-- One solid in-memory image. Distinct paths get distinct colors so a wrong
-- skin or a misplaced plane is a pixel mismatch, never a wash.
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

-- The render collaborators the production plan borrows: the host graphics,
-- one synthetic image per manifest path (skins map to distinct hues so a
-- skin swap is visible), and the shared fixture text renderer for clock
-- and card text. Every entry is a host-boundary fake; production
-- registration of real cards stays gated.
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
    images[path] = solidImage(scope, visual.width, visual.height, hue[1], hue[2], hue[3])
  end
  local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  return { graphics = love.graphics, images = images, textRenderer = text }
end

---@param width number
---@param height number
---@param topology table
---@param pixelRatio number?
---@return table
local function displayFacts(width, height, topology, pixelRatio)
  return {
    width = width,
    height = height,
    topology = topology,
    pixelRatio = pixelRatio or 1,
    signature = "pokegear-graphics:" .. width .. "x" .. height .. "@" .. (pixelRatio or 1),
  }
end

---@param width number
---@param height number
---@param pixelRatio number?
---@return table
local function singleDisplay(width, height, pixelRatio)
  return displayFacts(
    width,
    height,
    ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = width, height = height },
      role = "world",
      touch = true,
    }),
    pixelRatio
  )
end

-- Source strip geometry, kept outside the shell under test: five fixed
-- slot centers with the touch rectangles the source pairs with its
-- nonzero-pixel mask.
local SLOT_CENTERS_X = { 32, 80, 128, 176, 230 }
local SLOT_CENTER_Y = 176

-- Setup thumbnail geometry, kept outside the controller under test: six
-- fixed cells centered at x48/128/208, y44/116, each 48 wide and 40 tall.
local THUMBNAIL_COLUMNS = { 24, 104, 184 }
local THUMBNAIL_ROWS = { 24, 96 }

---@return table rects row-major skin 0..5
local function expectedThumbnails()
  local rects = {}
  for row = 1, 2 do
    for column = 1, 3 do
      rects[#rects + 1] = { x = THUMBNAIL_COLUMNS[column], y = THUMBNAIL_ROWS[row], width = 48, height = 40 }
    end
  end
  return rects
end

-- Closed stub child factories through the prescribed children[tab] seam.
-- Test-only fakes at the host boundary; the setup factory is overridden
-- with the real controller where the scenario needs it.
---@param log table
---@return table<string, fun(context: table): table>
local function stubSiblings(log)
  local children = {}
  for _, tab in ipairs({ "configure", "radio", "map", "phone" }) do
    children[tab] = function(context)
      assert(type(context) == "table", "child factories receive a context record")
      local child = { updates = 0, disposed = false }
      function child:updateFixed(mapped)
        self.updates = self.updates + 1
        assert(type(mapped) == "table", "card input must be an event list")
      end
      function child:status()
        return { open = true, tab = tab, busy = false, dismissible = true }
      end
      function child:takeResult()
        return nil
      end
      function child:dispose()
        self.disposed = true
      end
      log[tab] = child
      return child
    end
  end
  return children
end

---@param manifest table
---@return table state
local function fullCardState(manifest)
  local record = PokegearAssetSchema.validate(manifest)
  assert(record ~= nil, "synthetic catalog validated above")
  local state = PokegearState.new(nil, { catalog = record.catalog })
  state:registerCard("map")
  state:registerCard("radio")
  state:setPreference("unlockedSkins", { 0, 1, 2, 3, 4, 5 })
  return state
end

---@param params table
---@return table box
local function openShell(params)
  local PokegearScreenState = requireFeature(
    "game.hgss.src.pokegear.PokegearScreenState",
    "the gear shell has no screen owner yet: the setup surface and its display plan cannot render"
  )
  local PokegearInterface = requireFeature(
    "game.hgss.src.pokegear.PokegearInterface",
    "the gear shell has no presentation owner yet: matched information/controls plans cannot render"
  )
  local record = PokegearAssetSchema.validate(params.manifest)
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local log = { effects = {}, configure = nil, siblings = {} }
  local children = stubSiblings(log.siblings)
  if params.configureFactory ~= nil then
    children.configure = params.configureFactory
  end
  local box = { facts = params.facts }
  local shell = PokegearScreenState.new({
    state = params.state,
    assets = record,
    clock = LocalClock.new(function()
      return { year = 2024, month = 5, day = 6, hour = 12, minute = 34, second = 56 }
    end),
    children = children,
    presentation = PokegearInterface.defaults(),
    effect = function(sequence)
      log.effects[#log.effects + 1] = sequence
    end,
    entry = params.entry or { kind = "browse" },
    measureDisplay = function()
      return box.facts
    end,
  })
  return { shell = shell, state = params.state, record = record, log = log, box = box }
end

-- Ticks empty batches until the shell reports a settled transition or the
-- bound is reached. The bound only guards against a stuck shell.
---@param shell table
local function settle(shell)
  for _ = 1, 120 do
    local transition = shell:status().transition
    if transition == nil or transition.completed == true then
      return
    end
    shell:updateFixed({})
  end
  local transition = shell:status().transition
  Assert.isTrue(transition == nil or transition.completed == true, "the shell transition must settle")
end

---@param status table
---@param id string
---@return table
local function findPane(status, id)
  local plan = assert(status.presentation, "the shell publishes its presentation plan")
  for _, pane in ipairs(assert(plan.panes, "the plan carries its panes")) do
    if pane.id == id then
      return pane
    end
  end
  error("the shell plan must carry the " .. id .. " pane", 0)
end

-- Maps one source-local surface point to host units through the published
-- placement's documented frame/scale/origin contract.
---@param placement table
---@param sourceX number
---@param sourceY number
---@return number x
---@return number y
local function toHost(placement, sourceX, sourceY)
  local frame = assert(placement.frame, "the pane placement carries its frame")
  local scale = assert(placement.scale, "the pane placement carries its scale")
  local origin = placement.origin or frame
  return origin.x + sourceX * scale, origin.y + sourceY * scale
end

---@param shell table
---@param slotIndex integer
---@return number x
---@return number y
local function slotCenter(shell, slotIndex)
  local placement = assert(findPane(shell:status(), "controls").placement, "the controls pane is placed")
  return toHost(placement, SLOT_CENTERS_X[slotIndex], SLOT_CENTER_Y)
end

---@param shell table
---@param x number
---@param y number
local function tap(shell, x, y)
  shell:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  shell:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y } })
end

-- Draws the shell's published plan through the production render callback
-- and captures host pixels. Resources stay fixed across draws so a visual
-- change proves a skin or menu change, never a rebuilt asset.
---@param scope table
---@param shell table
---@param resources table
---@param width integer
---@param height integer
---@return table imageData
local function drawShell(scope, shell, resources, width, height)
  local status = shell:status()
  local plan = assert(status.presentation, "the shell publishes its presentation plan")
  local canvas = scope:own(love.graphics.newCanvas(width, height))
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
---@return number alpha
local function pixel(data, x, y)
  return data:getPixel(x, y)
end

---@param red number
---@param green number
---@param blue number
---@return number luminance
local function luminance(red, green, blue)
  return 0.299 * red + 0.587 * green + 0.114 * blue
end

---@param rect table
---@return number area
local function area(rect)
  return rect.width * rect.height
end

---@param first table
---@param second table
---@return boolean overlaps
local function overlaps(first, second)
  return first.x < second.x + second.width
    and second.x < first.x + first.width
    and first.y < second.y + second.height
    and second.y < first.y + first.height
end

-- Crawls the setup cursor graph with directional presses until the cursor
-- reaches the target skin. The graph itself is source behaviour under
-- test, so the test explores it instead of asserting invented edges.
---@param shell table
---@param configure table
---@param target integer
local function driveCursorTo(shell, configure, target)
  for _ = 1, 6 do
    if configure:status().cursor == target then
      return
    end
    for _, direction in ipairs({ "right", "down", "left", "up" }) do
      shell:updateFixed({ { type = "navigate", direction = direction } })
      if configure:status().cursor == target then
        return
      end
    end
  end
  Assert.equal(configure:status().cursor, target, "the setup cursor reaches skin " .. target)
end

function T.setup_skin_selection_commits_and_spotlights(scope)
  local ConfigureController = requireFeature(
    "game.hgss.src.pokegear.ConfigureController",
    "the gear setup card has no controller yet: skin commit, cancel, and menu spotlight are unavailable"
  )
  local manifest = fixtureManifest()
  local record = PokegearAssetSchema.validate(manifest)
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")

  local state = PokegearState.new(nil, { catalog = record.catalog })
  state:registerCard("map")
  state:registerCard("radio")
  state:setPreference("lastApp", "configure")
  state:setPreference("unlockedSkins", { 0, 1, 2, 3, 4, 5 })
  local revisionAtOpen = state:revision()

  local configureHandle = {}
  local host = openShell({
    state = state,
    manifest = manifest,
    facts = singleDisplay(512, 192),
    configureFactory = function(context)
      assert(type(context) == "table", "the setup factory receives a context record")
      local controller = ConfigureController.new({
        state = state,
        assets = record,
        effect = function(_) end,
      })
      configureHandle.controller = controller
      return controller
    end,
  })
  settle(host.shell)
  Assert.equal(host.shell:status().tab, "configure", "the remembered setup card opens")
  local configure = assert(configureHandle.controller, "the setup factory built the real controller")

  -- The detached view carries all six fixed thumbnail cells at their
  -- source rectangles, independent of the controller under test.
  do
    local view = assert(configure:status().view, "the setup controller exports its detached view")
    local expected = expectedThumbnails()
    Assert.notNil(view.thumbnails, "the setup view carries its thumbnail cells")
    for skin = 0, 5 do
      Assert.deepEqual(view.thumbnails[skin], expected[skin + 1], "setup cell " .. skin .. " keeps its source rect")
    end
  end

  -- Every compiled source cell is available even if a stale saved subset
  -- is present. Child navigation never moves strip focus either: the card
  -- owns its directional input while it is active.
  driveCursorTo(host.shell, configure, 5)
  Assert.equal(host.shell:status().focus, "configure", "setup navigation keeps strip focus on the card")
  host.shell:updateFixed({ { type = "confirm" } })
  Assert.isTrue(configure:status().menuOpen, "confirming source skin five opens its context menu")
  Assert.equal(state:readPreferences().skin, 0, "opening the skin menu writes nothing")
  Assert.equal(state:revision(), revisionAtOpen, "opening the skin menu moves no revision")
  host.shell:updateFixed({ { type = "cancel" } })
  Assert.isFalse(configure:status().menuOpen, "cancelling closes the skin context menu")

  -- Opening the context menu then cancelling leaves the saved skin alone.
  driveCursorTo(host.shell, configure, 2)
  host.shell:updateFixed({ { type = "confirm" } })
  Assert.isTrue(configure:status().menuOpen, "confirming an unlocked skin opens its context menu")
  local menuView = assert(configure:status().view, "the menu state exports its view")
  local menuRect = assert(menuView.menu, "the open menu publishes its window rect")
  local selectedRect = assert(menuView.thumbnails, "the menu state keeps its cells")[2]
  Assert.isFalse(overlaps(menuRect, selectedRect), "the context window never covers the selected thumbnail")
  local spotlights = assert(menuView.spotlight, "the open menu publishes its spotlight rectangles")
  Assert.isTrue(#spotlights > 0, "the spotlight dims through explicit rectangles")
  local covered = 0
  for index, rect in ipairs(spotlights) do
    Assert.isTrue(rect.x >= 0 and rect.y >= 0, "spotlight rectangle " .. index .. " stays on the surface")
    Assert.isTrue(
      rect.x + rect.width <= 256 and rect.y + rect.height <= 192,
      "spotlight rectangle " .. index .. " stays inside the surface"
    )
    Assert.isFalse(overlaps(rect, menuRect), "spotlight rectangle " .. index .. " exempts the menu window")
    Assert.isFalse(overlaps(rect, selectedRect), "spotlight rectangle " .. index .. " exempts the thumbnail")
    for other = index + 1, #spotlights do
      Assert.isFalse(overlaps(rect, spotlights[other]), "spotlight rectangles never double-dim")
    end
    covered = covered + area(rect)
  end
  Assert.equal(
    covered,
    256 * 192 - area(menuRect) - area(selectedRect),
    "the spotlight dims exactly everything except the window and the thumbnail"
  )
  Assert.equal(menuView.selectedSkin, 2, "the spotlight view names the semantic selected skin")
  Assert.isTrue(configure:status().cursorFrozen, "the cursor animation freezes in the confirmation state")
  host.shell:updateFixed({ { type = "cancel" } })
  Assert.isFalse(configure:status().menuOpen, "cancelling closes the context menu")
  Assert.equal(state:readPreferences().skin, 0, "cancelling the menu writes no skin")
  Assert.equal(state:revision(), revisionAtOpen, "menu navigation and cancel move no revision")

  -- The baseline draw proves the committed-skin comparison below starts
  -- from skin 0 with fixed resources: nothing is rebuilt between draws.
  local resources = renderResources(scope, manifest)
  local baseline = drawShell(scope, host.shell, resources, 512, 192)

  -- Confirming a source skin writes once at the confirmation boundary
  -- and swaps every affected visual without any asset rebuild.
  driveCursorTo(host.shell, configure, 3)
  local beforeConfirm = state:revision()
  host.shell:updateFixed({ { type = "confirm" } })
  Assert.isTrue(configure:status().menuOpen, "confirming an unlocked skin opens its context menu first")
  Assert.equal(state:revision(), beforeConfirm, "opening the menu writes no skin yet")
  host.shell:updateFixed({ { type = "confirm" } })
  Assert.equal(state:readPreferences().skin, 3, "confirming the menu commits the selected skin")
  Assert.equal(state:revision(), beforeConfirm + 1, "one confirmation advances exactly one revision")
  Assert.isFalse(configure:status().menuOpen, "the committed menu closes")
  settle(host.shell)
  local swapped = drawShell(scope, host.shell, resources, 512, 192)
  local changed = 0
  for y = 0, 191 do
    for x = 0, 511 do
      local r1, g1, b1, a1 = pixel(baseline, x, y)
      local r2, g2, b2, a2 = pixel(swapped, x, y)
      if
        math.floor(r1 * 255 + 0.5) ~= math.floor(r2 * 255 + 0.5)
        or math.floor(g1 * 255 + 0.5) ~= math.floor(g2 * 255 + 0.5)
        or math.floor(b1 * 255 + 0.5) ~= math.floor(b2 * 255 + 0.5)
        or math.floor(a1 * 255 + 0.5) ~= math.floor(a2 * 255 + 0.5)
      then
        changed = changed + 1
      end
    end
  end
  Assert.isTrue(changed > 500, "the committed skin repaints the shell from prepared assets")

  -- Spotlight pixels: with the menu open, a dimmed spotlight sample is
  -- strictly darker than the same point menu-closed, while the selected
  -- thumbnail sample is pixel-identical.
  driveCursorTo(host.shell, configure, 1)
  host.shell:updateFixed({ { type = "confirm" } })
  Assert.isTrue(configure:status().menuOpen, "the spotlight draw starts from an open menu")
  local lit = drawShell(scope, host.shell, resources, 512, 192)
  local openView = assert(configure:status().view, "the open menu exports its view")
  local openMenu = assert(openView.menu, "the open menu publishes its window")
  local openThumb = assert(openView.thumbnails, "the open menu keeps its cells")[1]
  local openSpot = assert(openView.spotlight, "the open menu publishes its spotlight")[1]
  host.shell:updateFixed({ { type = "cancel" } })
  local unlit = drawShell(scope, host.shell, resources, 512, 192)
  local controlsPlacement = assert(findPane(host.shell:status(), "controls").placement, "the controls pane is placed")
  local dimX, dimY = toHost(controlsPlacement, openSpot.x + openSpot.width / 2, openSpot.y + openSpot.height / 2)
  local thumbX, thumbY =
    toHost(controlsPlacement, openThumb.x + openThumb.width / 2, openThumb.y + openThumb.height / 2)
  local menuX, menuY = toHost(controlsPlacement, openMenu.x + openMenu.width / 2, openMenu.y + openMenu.height / 2)
  local dimR1, dimG1, dimB1, _ = pixel(lit, math.floor(dimX), math.floor(dimY))
  local dimR2, dimG2, dimB2, _ = pixel(unlit, math.floor(dimX), math.floor(dimY))
  Assert.isTrue(
    luminance(dimR1, dimG1, dimB1) < luminance(dimR2, dimG2, dimB2) - 0.05,
    "the spotlight sample dims with the menu open"
  )
  local thumbR1, thumbG1, thumbB1, thumbA1 = pixel(lit, math.floor(thumbX), math.floor(thumbY))
  local thumbR2, thumbG2, thumbB2, thumbA2 = pixel(unlit, math.floor(thumbX), math.floor(thumbY))
  Assert.near(thumbR1, thumbR2, 1e-3, "the selected thumbnail keeps its red under the menu")
  Assert.near(thumbG1, thumbG2, 1e-3, "the selected thumbnail keeps its green under the menu")
  Assert.near(thumbB1, thumbB2, 1e-3, "the selected thumbnail keeps its blue under the menu")
  Assert.near(thumbA1, thumbA2, 1e-3, "the selected thumbnail keeps its alpha under the menu")
  local menuR1, menuG1, menuB1, _ = pixel(lit, math.floor(menuX), math.floor(menuY))
  local menuR2, menuG2, menuB2, _ = pixel(unlit, math.floor(menuX), math.floor(menuY))
  Assert.isTrue(
    math.floor(menuR1 * 255 + 0.5) ~= math.floor(menuR2 * 255 + 0.5)
      or math.floor(menuG1 * 255 + 0.5) ~= math.floor(menuG2 * 255 + 0.5)
      or math.floor(menuB1 * 255 + 0.5) ~= math.floor(menuB2 * 255 + 0.5),
    "the context window paints over the dimmed surface"
  )
  host.shell:dispose()
end

function T.display_plan_keeps_roles_and_pointer_targets(scope)
  requireFeature(
    "game.hgss.src.pokegear.PokegearScreenState",
    "the gear shell has no screen owner yet: display roles and pointer targets cannot render"
  )
  local manifest = fixtureManifest()

  -- One shell per host configuration; the strip mapping is learned once on
  -- the wide pair and must hold everywhere else without repacking.
  local wide = openShell({
    state = fullCardState(manifest),
    manifest = manifest,
    facts = singleDisplay(512, 192),
  })
  settle(wide.shell)
  local mapping = {}
  for slot = 1, 4 do
    local x, y = slotCenter(wide.shell, slot)
    local before = wide.shell:status().tab
    tap(wide.shell, x, y)
    settle(wide.shell)
    mapping[slot] = wide.shell:status().tab
    if wide.shell:status().tab ~= before then
      settle(wide.shell)
    end
  end
  local reached = {}
  for _, tab in pairs(mapping) do
    reached[tab] = true
  end
  for _, tab in ipairs({ "configure", "radio", "map", "phone" }) do
    Assert.isTrue(reached[tab], "every card answers its fixed slot on the wide pair: " .. tab)
  end

  -- Role checks per configuration: wide keeps information left of
  -- controls, tall and near-native stack information above controls, and
  -- the physical pair maps each pane to its intended screen.
  local function checkRoles(facts, kind)
    local host = openShell({ state = fullCardState(manifest), manifest = manifest, facts = facts })
    settle(host.shell)
    local status = host.shell:status()
    local plan = assert(status.presentation, kind .. " publishes its presentation plan")
    Assert.equal(#plan.panes, 2, kind .. " keeps both semantic panes")
    Assert.isTrue(type(plan.inputKey) == "string" and plan.inputKey ~= "", kind .. " names its input geometry")
    local info = findPane(status, "information")
    local controls = findPane(status, "controls")
    Assert.isTrue(controls.interactive, kind .. " keeps the controls pane interactive")
    local infoFrame = assert(info.placement, kind .. " places its information pane").frame
    local controlsFrame = assert(controls.placement, kind .. " places its controls pane").frame
    if kind == "wide" then
      Assert.isTrue(
        infoFrame.x + infoFrame.width <= controlsFrame.x + 1e-6,
        "the wide pair keeps information left of controls"
      )
    elseif kind == "tall" or kind == "tallish" or kind == "square" then
      Assert.isTrue(
        infoFrame.y + infoFrame.height <= controlsFrame.y + 1e-6,
        kind .. " stacks information above controls"
      )
    elseif kind == "dual" then
      local worldRect = { x = 0, y = 0, width = 256, height = 192 }
      local auxRect = { x = 0, y = 192, width = 256, height = 192 }
      Assert.isTrue(
        infoFrame.x >= worldRect.x
          and infoFrame.y >= worldRect.y
          and infoFrame.x + infoFrame.width <= worldRect.x + worldRect.width
          and infoFrame.y + infoFrame.height <= worldRect.y + worldRect.height,
        "the physical pair keeps information on the upper screen"
      )
      Assert.isTrue(
        controlsFrame.x >= auxRect.x
          and controlsFrame.y >= auxRect.y
          and controlsFrame.x + controlsFrame.width <= auxRect.x + auxRect.width
          and controlsFrame.y + controlsFrame.height <= auxRect.y + auxRect.height,
        "the physical pair keeps controls on the lower screen"
      )
    end
    return host
  end

  local tall = checkRoles(singleDisplay(256, 384), "tall")
  local square = checkRoles(singleDisplay(640, 480), "square")
  local native = checkRoles(singleDisplay(256, 192), "tallish")
  local hidpi = checkRoles(singleDisplay(512, 192, 2), "wide")
  local tiny = checkRoles(singleDisplay(200, 100), "wide")
  local dual = checkRoles(
    displayFacts(
      256,
      384,
      ScreenTopology.dualDisplay({
        id = "world",
        rect = { x = 0, y = 0, width = 256, height = 192 },
        role = "world",
        touch = false,
      }, {
        id = "aux",
        rect = { x = 0, y = 192, width = 256, height = 192 },
        role = "auxiliary",
        touch = true,
      })
    ),
    "dual"
  )

  -- Clicks reach the drawn tab on every configuration through the same
  -- published plan: the learned wide mapping holds without repacking.
  for _, named in ipairs({
    { host = tall, kind = "tall" },
    { host = square, kind = "square" },
    { host = native, kind = "tallish" },
    { host = hidpi, kind = "wide-hidpi" },
    { host = tiny, kind = "wide-tiny" },
    { host = dual, kind = "dual" },
  }) do
    for slot = 1, 4 do
      local x, y = slotCenter(named.host.shell, slot)
      tap(named.host.shell, x, y)
      settle(named.host.shell)
      Assert.equal(
        named.host.shell:status().tab,
        mapping[slot],
        named.kind .. " keeps the fixed slot mapping at slot " .. slot
      )
    end
  end

  -- A resize during a held press cancels the stale release: the down
  -- targets one card, the geometry changes, and the up switches nothing.
  do
    local held = wide
    local before = held.shell:status().tab
    local targetSlot = nil
    for slot = 1, 4 do
      if mapping[slot] ~= before then
        targetSlot = slot
        break
      end
    end
    assert(targetSlot ~= nil, "a switch target exists")
    local x, y = slotCenter(held.shell, targetSlot)
    held.shell:updateFixed({ { type = "pointer_down", pointerId = "touch:9", x = x, y = y } })
    held.box.facts = singleDisplay(640, 480)
    held.shell:updateFixed({})
    held.shell:updateFixed({ { type = "pointer_up", pointerId = "touch:9", x = x, y = y } })
    Assert.equal(held.shell:status().tab, before, "the resized release switches no card")
    Assert.isNil(held.shell:takeResult(), "the cancelled release produces no result")
  end

  -- Border presses never click through: on the underfilled 4:3 frame an
  -- outside press is consumed as the browsable dismissal, switching no
  -- card and reaching no field behind the shell.
  do
    local bordered = square
    local before = bordered.shell:status().tab
    local plan = assert(bordered.shell:status().presentation, "the bordered plan is published")
    local outer = assert(plan.frames, "the underfilled plan carries its outer frame")[1].placement.frame
    local outsideX, outsideY = outer.x - 5, outer.y - 5
    Assert.isTrue(outsideX >= 0 and outsideY >= 0, "the probe stays on the host display")
    tap(bordered.shell, outsideX, outsideY)
    local result = assert(bordered.shell:takeResult(), "the border press is consumed by the shell")
    Assert.equal(result.kind, "close", "the border press dismisses instead of clicking through")
    Assert.equal(bordered.shell:status().tab, before, "the border press switches no card")
    bordered.shell:dispose()
  end

  -- Both panes reach the GPU on the exact-fit wide pair: opaque content in
  -- the information frame and in the controls frame. The wide shell
  -- returns to its exact-fit facts first so placements match the canvas.
  do
    wide.box.facts = singleDisplay(512, 192)
    wide.shell:updateFixed({})
    settle(wide.shell)
    local resources = renderResources(scope, manifest)
    local data = drawShell(scope, wide.shell, resources, 512, 192)
    local status = wide.shell:status()
    for _, paneId in ipairs({ "information", "controls" }) do
      local frame = assert(findPane(status, paneId).placement, paneId .. " is placed").frame
      local opaque = 0
      for y = math.floor(frame.y), math.floor(frame.y + frame.height) - 1 do
        for x = math.floor(frame.x), math.floor(frame.x + frame.width) - 1 do
          local _, _, _, alpha = pixel(data, x, y)
          if alpha > 0.5 then
            opaque = opaque + 1
          end
        end
      end
      Assert.isTrue(opaque > 100, paneId .. " paints opaque content in its frame")
    end
  end

  wide.shell:dispose()
  tall.shell:dispose()
  native.shell:dispose()
  hidpi.shell:dispose()
  tiny.shell:dispose()
  dual.shell:dispose()
end

-- Samples a small cross of both panes so a repaint anywhere on the shell
-- changes the signature.
---@param data table
---@return string
local function paintSignature(data)
  local parts = {}
  for _, point in ipairs({ { 10, 10 }, { 300, 100 }, { 100, 150 }, { 400, 50 }, { 200, 96 } }) do
    local red, green, blue, alpha = pixel(data, point[1], point[2])
    parts[#parts + 1] = string.format(
      "%d:%d:%d:%d",
      math.floor(red * 255 + 0.5),
      math.floor(green * 255 + 0.5),
      math.floor(blue * 255 + 0.5),
      math.floor(alpha * 255 + 0.5)
    )
  end
  return table.concat(parts, "|")
end

-- Every committed skin repaints the shell from the same prepared assets:
-- six commits through one controller yield six distinct paintings with
-- one revision each and no asset rebuild between draws.
function T.every_skin_repaints_from_prepared_assets(scope)
  local ConfigureController = requireFeature(
    "game.hgss.src.pokegear.ConfigureController",
    "the gear setup card has no controller yet: per-skin repaints are unavailable"
  )
  local manifest = fixtureManifest()
  local record = PokegearAssetSchema.validate(manifest)
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local state = fullCardState(manifest)
  state:setPreference("lastApp", "configure")
  local configureHandle = {}
  local host = openShell({
    state = state,
    manifest = manifest,
    facts = singleDisplay(512, 192),
    configureFactory = function(context)
      local controller = ConfigureController.new({
        state = state,
        assets = record,
        effect = function(_) end,
      })
      configureHandle.controller = controller
      return controller
    end,
  })
  settle(host.shell)
  local configure = assert(configureHandle.controller, "the setup factory built the real controller")
  local resources = renderResources(scope, manifest)
  local seen = {}
  for _, skin in ipairs({ 1, 2, 3, 4, 5, 0 }) do
    driveCursorTo(host.shell, configure, skin)
    local beforeConfirm = state:revision()
    host.shell:updateFixed({ { type = "confirm" } })
    host.shell:updateFixed({ { type = "confirm" } })
    Assert.equal(state:readPreferences().skin, skin, "skin " .. skin .. " commits")
    Assert.equal(state:revision(), beforeConfirm + 1, "skin " .. skin .. " advances exactly one revision")
    settle(host.shell)
    local signature = paintSignature(drawShell(scope, host.shell, resources, 512, 192))
    Assert.isNil(seen[signature], "skin " .. skin .. " paints distinctly from prepared assets")
    seen[signature] = skin
  end
  host.shell:dispose()
end

-- Unprepared graphics fail before drawing: a missing compiled image or a
-- missing host graphics namespace raises instead of painting a plausible
-- empty shell.
function T.unprepared_graphics_fail_before_drawing(scope)
  local manifest = fixtureManifest()
  local host = openShell({ state = fullCardState(manifest), manifest = manifest, facts = singleDisplay(512, 192) })
  settle(host.shell)
  local status = host.shell:status()
  local plan = assert(status.presentation, "the shell publishes its presentation plan")
  local resources = renderResources(scope, manifest)
  local _, emptyErr = pcall(function()
    plan.render({ graphics = resources.graphics, images = {}, textRenderer = resources.textRenderer }, status, plan)
  end)
  Assert.notNil(emptyErr, "drawing without prepared images fails")
  Assert.notNil(tostring(emptyErr):find("prepared", 1, true), "the missing-image failure names its prepared image")
  Assert.throws(function()
    plan.render({ images = resources.images, textRenderer = resources.textRenderer }, status, plan)
  end, "drawing without host graphics fails")
  host.shell:dispose()
end

-- The spotlight stays exact when the context window overlaps a
-- non-selected cell: coverage still dims everything except the window and
-- the selected thumbnail, with no double-dimmed overlap.
function T.spotlight_covers_a_menu_overlapping_other_cells(scope)
  local ConfigureController = requireFeature(
    "game.hgss.src.pokegear.ConfigureController",
    "the gear setup card has no controller yet: overlapping spotlight coverage is unavailable"
  )
  local manifest = fixtureManifest()
  local record = PokegearAssetSchema.validate(manifest)
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local state = fullCardState(manifest)
  state:setPreference("lastApp", "configure")
  local configureHandle = {}
  local host = openShell({
    state = state,
    manifest = manifest,
    facts = singleDisplay(512, 192),
    configureFactory = function(context)
      local controller = ConfigureController.new({
        state = state,
        assets = record,
        effect = function(_) end,
      })
      configureHandle.controller = controller
      return controller
    end,
  })
  settle(host.shell)
  local configure = assert(configureHandle.controller, "the setup factory built the real controller")
  -- Skin 4 sits at x104..152, y96..136, overlapping the context window's
  -- y120..136 band over x104..152: the union math below is independent of
  -- the controller under test.
  driveCursorTo(host.shell, configure, 4)
  host.shell:updateFixed({ { type = "confirm" } })
  Assert.isTrue(configure:status().menuOpen, "confirming skin 4 opens its context menu")
  local menuView = assert(configure:status().view, "the open menu exports its view")
  local menuRect = assert(menuView.menu, "the open menu publishes its window rect")
  local selectedRect = assert(menuView.thumbnails, "the menu state keeps its cells")[4]
  local spotlights = assert(menuView.spotlight, "the open menu publishes its spotlight rectangles")
  local covered = 0
  for index, rect in ipairs(spotlights) do
    Assert.isTrue(rect.x >= 0 and rect.y >= 0, "spotlight rectangle " .. index .. " stays on the surface")
    Assert.isTrue(
      rect.x + rect.width <= 256 and rect.y + rect.height <= 192,
      "spotlight rectangle " .. index .. " stays inside the surface"
    )
    Assert.isFalse(overlaps(rect, menuRect), "spotlight rectangle " .. index .. " exempts the menu window")
    Assert.isFalse(overlaps(rect, selectedRect), "spotlight rectangle " .. index .. " exempts the thumbnail")
    for other = index + 1, #spotlights do
      Assert.isFalse(overlaps(rect, spotlights[other]), "spotlight rectangles never double-dim")
    end
    covered = covered + area(rect)
  end
  Assert.equal(covered, 256 * 192 - 3840 - 1920 + 768, "the spotlight dims exactly the menu/thumbnail union")
  local resources = renderResources(scope, manifest)
  local lit = drawShell(scope, host.shell, resources, 512, 192)
  local openSpot = spotlights[1]
  host.shell:updateFixed({ { type = "cancel" } })
  local unlit = drawShell(scope, host.shell, resources, 512, 192)
  local controlsPlacement = assert(findPane(host.shell:status(), "controls").placement, "the controls pane is placed")
  local dimX, dimY = toHost(controlsPlacement, openSpot.x + openSpot.width / 2, openSpot.y + openSpot.height / 2)
  local dimR1, dimG1, dimB1, _ = pixel(lit, math.floor(dimX), math.floor(dimY))
  local dimR2, dimG2, dimB2, _ = pixel(unlit, math.floor(dimX), math.floor(dimY))
  Assert.isTrue(
    luminance(dimR1, dimG1, dimB1) < luminance(dimR2, dimG2, dimB2) - 0.05,
    "the overlapping spotlight sample dims with the menu open"
  )
  host.shell:dispose()
end

return GraphicsSmoke.suite(T, { tags = { "pokegear" } })
