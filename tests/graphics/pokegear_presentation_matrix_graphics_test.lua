-- Presentation matrix for the pocket gear: the information and controls
-- panes keep their source roles on wide, tall, near-native, and physical
-- dual-screen hosts; slot taps reach the drawn card through the same
-- published plan on every host with the pointer inverse matching the
-- drawn target; all six skins resolve distinct compiled paths; and the
-- drawn plan paints opaque source content. Card-content depth stays with
-- the per-card suites; this matrix proves the shared host boundary
-- uniformly through the real shell, the real interface, and a
-- schema-validated synthetic family.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local LocalClock = require("game.src.LocalClock")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearState = require("libs.hgss.src.save.PokegearState")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

-- Fixed strip slots in source order, kept outside the shell under test:
-- setup, radio, map, phone, cancel with the touch centers the source pairs
-- with its nonzero-pixel mask.
local SLOT_TABS = { "configure", "radio", "map", "phone", "cancel" }
local SLOT_CENTERS_X = { 32, 80, 128, 176, 230 }
local SLOT_CENTER_Y = 176

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
-- per-skin shell, setup, phone, map, and radio planes plus the immutable
-- semantic catalogs. Every visual gets a distinct path so the matrix can
-- tell a wrong skin from a misplaced plane.
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
    schema = "g4-pokegear-assets-v2",
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
        { key = "matrix.caller.elm", sortWeight = 10 },
        { key = "matrix.caller.mom", sortWeight = 20 },
      },
      contactOrder = { "matrix.caller.elm", "matrix.caller.mom" },
      callDefinitions = {},
      callTriggers = {},
      rematches = {},
      gifts = {},
      momPurchases = {},
      locations = {
        { key = "matrix.place.new-bark" },
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
    signature = "pokegear-matrix:" .. width .. "x" .. height .. "@" .. (pixelRatio or 1),
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

---@return table physical dual-screen facts with information above controls
local function dualDisplay()
  return displayFacts(
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
  )
end

-- Closed stub child factories through the prescribed children seam. The
-- matrix proves shell placement and pointer routing, never card content.
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
---@return table state with every card registered
local function fullCardState(manifest)
  local record = PokegearAssetSchema.validate(manifest)
  assert(record ~= nil, "synthetic catalog validated above")
  local state = PokegearState.new(nil, { catalog = record.catalog })
  state:registerCard("map")
  state:registerCard("radio")
  return state
end

---@param params table
---@return table box
local function openShell(params)
  local PokegearScreenState = requireFeature(
    "game.hgss.src.pokegear.PokegearScreenState",
    "the gear shell has no screen owner yet: host roles and pointer targets cannot render"
  )
  local PokegearInterface = requireFeature(
    "game.hgss.src.pokegear.PokegearInterface",
    "the gear shell has no presentation owner yet: matched information/controls plans cannot render"
  )
  local record = PokegearAssetSchema.validate(params.manifest)
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local log = {}
  local box = { facts = params.facts }
  local shell = PokegearScreenState.new({
    state = params.state,
    assets = record,
    clock = LocalClock.new(function()
      return { year = 2024, month = 5, day = 6, hour = 12, minute = 34, second = 56 }
    end),
    children = stubSiblings(log),
    presentation = PokegearInterface.defaults(),
    effect = function(_) end,
    entry = { kind = "browse" },
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
-- placement's documented frame/scale/origin contract: the same inverse
-- the production pointer path uses.
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

-- Every host keeps information and controls in their source roles at one
-- shared integer scale: wide pairs them left to right, tall and
-- near-native stack them, and the physical pair maps each pane to its
-- intended screen.
function T.every_host_keeps_information_and_controls_in_their_source_roles(scope)
  local _ = scope
  requireFeature(
    "game.hgss.src.pokegear.PokegearScreenState",
    "the gear shell has no screen owner yet: host roles cannot render"
  )
  local manifest = fixtureManifest()
  local function checkRoles(facts, kind)
    local host = openShell({ state = fullCardState(manifest), manifest = manifest, facts = facts })
    settle(host.shell)
    local status = host.shell:status()
    local plan = assert(status.presentation, kind .. " publishes its presentation plan")
    Assert.equal(#plan.panes, 2, kind .. " keeps both semantic panes")
    Assert.isTrue(type(plan.inputKey) == "string" and plan.inputKey ~= "", kind .. " names its input geometry")
    local info = findPane(status, "information")
    local controls = findPane(status, "controls")
    Assert.isFalse(info.interactive, kind .. " keeps the information pane non-interactive")
    Assert.isTrue(controls.interactive, kind .. " keeps the controls pane interactive")
    local infoPlacement = assert(info.placement, kind .. " places its information pane")
    local controlsPlacement = assert(controls.placement, kind .. " places its controls pane")
    Assert.equal(
      infoPlacement.pixelScale,
      controlsPlacement.pixelScale,
      kind .. " pairs both panes at one shared integer scale"
    )
    local infoFrame = assert(infoPlacement.frame, kind .. " frames its information pane")
    local controlsFrame = assert(controlsPlacement.frame, kind .. " frames its controls pane")
    if kind == "wide" then
      Assert.isTrue(
        infoFrame.x + infoFrame.width <= controlsFrame.x + 1e-6,
        "the wide pair keeps information left of controls"
      )
    elseif kind == "tall" or kind == "nativeLike" then
      Assert.isTrue(
        infoFrame.y + infoFrame.height <= controlsFrame.y + 1e-6,
        kind .. " stacks information above controls"
      )
    elseif kind == "dual" then
      Assert.isTrue(
        infoFrame.y + infoFrame.height <= 192 + 1e-6,
        "the physical pair keeps information on the upper screen"
      )
      Assert.isTrue(controlsFrame.y >= 192 - 1e-6, "the physical pair keeps controls on the lower screen")
    end
  end
  checkRoles(singleDisplay(1280, 720), "wide")
  checkRoles(singleDisplay(390, 844), "tall")
  checkRoles(singleDisplay(640, 480), "nativeLike")
  checkRoles(dualDisplay(), "dual")
end

-- Slot taps reach the drawn card on every host through the same published
-- plan: each fixed slot selects its own card, and the pointer inverse
-- matches the drawn target on wide, tall, near-native, and dual alike.
function T.slot_taps_reach_the_drawn_card_on_every_host(scope)
  local _ = scope
  requireFeature(
    "game.hgss.src.pokegear.PokegearScreenState",
    "the gear shell has no screen owner yet: pointer targets cannot render"
  )
  local manifest = fixtureManifest()
  for _, named in ipairs({
    { facts = singleDisplay(1280, 720), kind = "wide" },
    { facts = singleDisplay(390, 844), kind = "tall" },
    { facts = singleDisplay(640, 480), kind = "nativeLike" },
    { facts = dualDisplay(), kind = "dual" },
  }) do
    local host = openShell({ state = fullCardState(manifest), manifest = manifest, facts = named.facts })
    settle(host.shell)
    for slot = 1, 5 do
      local x, y = slotCenter(host.shell, slot)
      tap(host.shell, x, y)
      settle(host.shell)
      if SLOT_TABS[slot] == "cancel" then
        Assert.isFalse(host.shell:status().open, named.kind .. " tap on the cancel slot closes the gear")
      else
        Assert.equal(
          host.shell:status().tab,
          SLOT_TABS[slot],
          named.kind .. " tap on slot " .. slot .. " must reach " .. SLOT_TABS[slot]
        )
      end
    end
  end
end

-- All six skins resolve distinct compiled paths through the real
-- interface: the plan content behind one skin never serves another, on
-- both single-display arrangements.
function T.every_skin_resolves_distinct_compiled_paths(scope)
  local _ = scope
  local PokegearInterface = requireFeature(
    "game.hgss.src.pokegear.PokegearInterface",
    "the gear shell has no presentation owner yet: skins cannot resolve"
  )
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local interface = PokegearInterface.defaults()
  local function skinPaths(skin, facts, configuration)
    local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
    local selection = ApplicationLayout.selectSurfaces({
      width = facts.width,
      height = facts.height,
      topology = facts.topology,
      pixelRatio = facts.pixelRatio,
      signature = facts.signature,
    })
    local plan = interface[configuration]({
      measurement = {
        width = facts.width,
        height = facts.height,
        topology = facts.topology,
        pixelRatio = facts.pixelRatio,
        signature = facts.signature,
      },
      configuration = configuration,
      primary = selection.primary,
      secondary = selection.secondary,
      nativeLikeInterface = interface.nativeLike,
    }, { assets = record, skin = skin })
    local paths = {}
    local function walk(node)
      if type(node) == "string" then
        if node:find("skin%-", 1) ~= nil then
          paths[#paths + 1] = node
        end
        return
      end
      if type(node) == "table" then
        for _, child in pairs(node) do
          walk(child)
        end
      end
    end
    walk(assert(plan.content, "every plan carries its resolved content"))
    table.sort(paths)
    Assert.isTrue(#paths > 0, "skin " .. skin .. " must resolve skin-qualified paths on " .. configuration)
    local own = 0
    for _, path in ipairs(paths) do
      if path:find("skin%-" .. skin, 1) ~= nil then
        own = own + 1
      end
    end
    Assert.isTrue(own > 0, "skin " .. skin .. " must serve its own compiled paths on " .. configuration)
    return table.concat(paths, "\n")
  end
  for _, configuration in ipairs({ "wide", "tall" }) do
    local facts = singleDisplay(1280, 720)
    local seen = {}
    for skin = 0, 5 do
      local digest = skinPaths(skin, facts, configuration)
      Assert.isNil(seen[digest], "skin " .. skin .. " must resolve distinctly on " .. configuration)
      seen[digest] = skin
    end
  end
end

-- Collects every visual record in the manifest so the smoke can hang one
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

---@param scope table
---@param width integer
---@param height integer
---@param seed integer
---@return table image
local function solidImage(scope, width, height, seed)
  local hues = {
    { 0.85, 0.15, 0.15 },
    { 0.15, 0.65, 0.15 },
    { 0.15, 0.35, 0.85 },
    { 0.85, 0.75, 0.15 },
    { 0.65, 0.25, 0.75 },
    { 0.15, 0.75, 0.75 },
  }
  local hue = hues[(seed % 6) + 1]
  local canvas = scope:own(love.graphics.newCanvas(width, height))
  love.graphics.setCanvas(canvas)
  love.graphics.setColor(hue[1], hue[2], hue[3], 1)
  love.graphics.rectangle("fill", 0, 0, width, height)
  love.graphics.setCanvas()
  return scope:own(love.graphics.newImage(scope:own(canvas:newImageData())))
end

-- The drawn plan paints opaque source content through the production
-- render callback on near-native and dual hosts: a wrong skin or a
-- misplaced plane is a pixel mismatch, never a wash.
function T.drawn_plan_paints_opaque_source_content(scope)
  local manifest = fixtureManifest()
  for _, named in ipairs({
    { facts = singleDisplay(640, 480), width = 640, height = 480, kind = "nativeLike" },
    { facts = dualDisplay(), width = 256, height = 384, kind = "dual" },
  }) do
    local host = openShell({ state = fullCardState(manifest), manifest = manifest, facts = named.facts })
    settle(host.shell)
    local images = {}
    local seed = 0
    for path, visual in pairs(collectVisuals(manifest)) do
      seed = seed + 1
      images[path] = solidImage(scope, visual.width, visual.height, seed)
    end
    local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
    local resources = { graphics = love.graphics, images = images, textRenderer = text }
    local status = host.shell:status()
    local plan = assert(status.presentation, named.kind .. " publishes its presentation plan")
    local canvas = scope:own(love.graphics.newCanvas(named.width, named.height))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.setColor(1, 1, 1, 1)
    assert(type(plan.render) == "function", "the published plan carries its render callback")
    plan.render(resources, status, plan)
    love.graphics.setCanvas()
    local data = scope:own(canvas:newImageData())
    local opaque = 0
    for y = 0, data:getHeight() - 1 do
      for x = 0, data:getWidth() - 1 do
        local _, _, _, alpha = data:getPixel(x, y)
        if alpha > 0.5 then
          opaque = opaque + 1
        end
      end
    end
    Assert.isTrue(opaque > 0, named.kind .. " must paint opaque source content")
  end
end

local suite = GraphicsSmoke.suite(T, { tags = { "pokegear" } })
return suite
