-- Radio planes, masks, slide, and pulse on every layout: the six skin
-- planes repaint from prepared assets, the information text panel travels
-- exactly eighty source pixels in eight ten-pixel steps and settles, the
-- pulse sprite sits on the tuned cursor and follows its animation frames
-- while an untuned dial shows none, focus corners answer focus, every
-- drawn radio pixel stays inside its own semantic pane on wide, tall,
-- near-native, and dual displays, and drawn cursor pixels round-trip
-- through the same published placement the pointer inverse uses. Panel
-- travel is measured from pixels without freezing panel size or direction;
-- animation durations stay with the source payloads.

local Assert = require("tests.support.Assert")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local LocalClock = require("game.src.LocalClock")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearState = require("libs.hgss.src.save.PokegearState")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

-- Loads a radio module that does not exist yet at this baseline. The
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

-- Synthetic companion family mirroring the published manifest shape, with
-- the radio text panel, two pulse frames, and one focus-corner visual
-- beside the per-skin planes. Every visual gets a distinct path so the
-- test can hang a distinct solid color on each.
---@return table
local function fixtureManifest()
  local skins = { 0, 1, 2, 3, 4, 5 }
  local shellForeground, shellInformation = {}, {}
  local radioMain, radioSecond, radioUpper, radioPanel = {}, {}, {}, {}
  for skin = 0, 5 do
    shellForeground[skin] = visualRef("assets/generated/pokegear/shell-foreground-skin-" .. skin .. ".png", 256, 192)
    shellInformation[skin] = visualRef("assets/generated/pokegear/shell-information-skin-" .. skin .. ".png", 256, 192)
    radioMain[skin] = visualRef("assets/generated/pokegear/radio-main-skin-" .. skin .. ".png", 256, 192)
    radioSecond[skin] = visualRef("assets/generated/pokegear/radio-second-skin-" .. skin .. ".png", 256, 192)
    radioUpper[skin] = visualRef("assets/generated/pokegear/radio-upper-skin-" .. skin .. ".png", 256, 192)
    radioPanel[skin] = visualRef("assets/generated/pokegear/radio-panel-skin-" .. skin .. ".png", 240, 64)
  end
  return {
    schema = "g4-pokegear-assets-v1",
    skins = skins,
    shell = { foreground = shellForeground, information = shellInformation },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png", 256, 192) },
    phone = { panel = visualRef("assets/generated/pokegear/phone-panel.png", 256, 192) },
    map = { base = visualRef("assets/generated/pokegear/map-base.png", 256, 192) },
    fly = { base = visualRef("assets/generated/pokegear/fly-base.png", 256, 192) },
    radio = {
      main = radioMain,
      second = radioSecond,
      upper = radioUpper,
      panel = radioPanel,
      pulse = {
        visualRef("assets/generated/pokegear/radio-pulse-frame-0.png", 16, 16),
        visualRef("assets/generated/pokegear/radio-pulse-frame-1.png", 16, 16),
      },
      corner = visualRef("assets/generated/pokegear/radio-corner.png", 16, 16),
    },
    catalog = {
      contacts = {},
      contactOrder = {},
      callDefinitions = {},
      callTriggers = {},
      rematches = {},
      gifts = {},
      momPurchases = {},
      locations = {},
      flypoints = {},
      reception = {},
      shows = {},
      radioEffects = {},
    },
    text = {},
    sequences = {},
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
-- skin, a misplaced plane, or a mistimed frame is a pixel mismatch.
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
---@return integer color seed
local function colorSeedFor(path)
  -- Every plane role gets its own color per skin, except the control
  -- base and the information upper plane which share one hue across
  -- panes: opaque test solids stack, so the lower control plane is
  -- occluded in-pane and same-pane sharing is what once made a
  -- misplaced plane read as a pixel match. Cross-pane sharing stays
  -- measurable because each pane is window-clipped and the containment
  -- scans below pin every color to its own pane. The shared pulse and
  -- corner visuals keep fixed seeds distinct from the skin-zero control
  -- letter they are measured against.
  local skin = tonumber(path:match("skin%-(%d+)") or "0") or 0
  if path:find("radio-main", 1, true) then
    return skin % 6
  end
  if path:find("radio-second", 1, true) then
    return (skin + 2) % 6
  end
  if path:find("radio-upper", 1, true) then
    return skin % 6
  end
  if path:find("radio-panel", 1, true) then
    return (skin + 1) % 6
  end
  if path:find("pulse-frame-0", 1, true) then
    return 3
  end
  if path:find("pulse-frame-1", 1, true) then
    return 5
  end
  if path:find("corner", 1, true) then
    return 4
  end
  if path:match("skin%-(%d+)") ~= nil then
    return skin % 6
  end
  local hash = 0
  for index = 1, #path do
    hash = (hash * 31 + path:byte(index)) % 251 + 1
  end
  return hash % 6
end

-- The render collaborators the production plan borrows: the host graphics,
-- one synthetic image per manifest path, and the shared fixture text
-- renderer. Every entry is a host-boundary fake.
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
    local hue = hues[colorSeedFor(path) + 1]
    images[path] = solidImage(scope, visual.width, visual.height, hue[1], hue[2], hue[3])
  end
  local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  return { graphics = love.graphics, images = images, textRenderer = text }
end

---@param width number
---@param height number
---@param topology table
---@return table display facts
local function displayFacts(width, height, topology)
  return {
    width = width,
    height = height,
    topology = topology,
    pixelRatio = 1,
    signature = "pokegear-radio-graphics:" .. width .. "x" .. height,
  }
end

---@param width number
---@param height number
---@return table single-display facts
local function singleDisplay(width, height)
  return displayFacts(
    width,
    height,
    ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = width, height = height },
      role = "world",
      touch = true,
    })
  )
end

---@return table dual-display facts
local function dualFacts()
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

-- Closed stub child factories: the shell renders through its real plan
-- while every card reports a quiet rectangle. Test-only fakes at the host
-- boundary.
---@return table<string, fun(context: table): table>
local function stubChildren()
  local children = {}
  for _, tab in ipairs({ "configure", "radio", "map", "phone" }) do
    children[tab] = function(context)
      assert(type(context) == "table", "child factories receive a context record")
      local child = {}
      function child:updateFixed(_)
        return nil
      end
      function child:status()
        return { open = true, tab = tab, busy = false, dismissible = true }
      end
      function child:takeResult()
        return nil
      end
      function child:dispose()
        return nil
      end
      return child
    end
  end
  return children
end

---@param manifest table
---@param facts table
---@return table shell, table record
local function openShell(manifest, facts)
  local PokegearScreenState = requireFeature(
    "game.hgss.src.pokegear.PokegearScreenState",
    "the gear shell has no screen owner yet: radio planes have no published display plan"
  )
  local PokegearInterface = requireFeature(
    "game.hgss.src.pokegear.PokegearInterface",
    "the gear shell has no presentation owner yet: radio planes have no matched placement"
  )
  local record = PokegearAssetSchema.validate(manifest)
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local state = PokegearState.new(nil, { catalog = record.catalog })
  state:registerCard("map")
  state:registerCard("radio")
  local box = { facts = facts }
  local shell = PokegearScreenState.new({
    state = state,
    assets = record,
    clock = LocalClock.new(function()
      return { year = 2024, month = 5, day = 6, hour = 12, minute = 34, second = 56 }
    end),
    children = stubChildren(),
    presentation = PokegearInterface.defaults(),
    effect = function(_) end,
    entry = { kind = "browse" },
    measureDisplay = function()
      return box.facts
    end,
  })
  for _ = 1, 120 do
    local transition = shell:status().transition
    if transition == nil or transition.completed == true then
      break
    end
    shell:updateFixed({})
  end
  return shell, record
end

---@param status table
---@param id string
---@return table pane
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

-- Inverts the published placement back to source units through the same
-- contract the pointer path uses.
---@param placement table
---@param hostX number
---@param hostY number
---@return number x
---@return number y
local function toSource(placement, hostX, hostY)
  local frame = assert(placement.frame, "the pane placement carries its frame")
  local scale = assert(placement.scale, "the pane placement carries its scale")
  local origin = placement.origin or frame
  return (hostX - origin.x) / scale, (hostY - origin.y) / scale
end

---@param manifest table
---@param skin integer
---@return table content with resolved image paths and panel text
local function radioContent(manifest, skin)
  local radio = assert(manifest.radio, "the companion family carries its radio visuals")
  return {
    main = radio.main[skin].image,
    second = radio.second[skin].image,
    upper = radio.upper[skin].image,
    panel = radio.panel[skin].image,
    pulseFrames = { radio.pulse[1].image, radio.pulse[2].image },
    corner = radio.corner.image,
    title = "Radio",
    body = { "Now playing" },
  }
end

---@param opts table<string, unknown>?
---@return table radio view
local function radioView(opts)
  local given = opts or {}
  return {
    skin = given.skin or 0,
    cursor = given.cursor or { x = 112, y = 76 },
    station = given.station == nil and 0 or given.station,
    signal = given.signal == nil and 2 or given.signal,
    slideStep = given.slideStep or 0,
    pulseFrame = given.pulseFrame or 0,
    focused = given.focused == nil and true or given.focused,
  }
end

-- Draws the radio panes through the production renderer over the published
-- pane placements and captures host pixels.
---@param scope table
---@param resources table
---@param panes table<string, table> pane id to placement
---@param content table
---@param view table
---@param width integer
---@param height integer
---@return table imageData
local function drawRadio(scope, resources, panes, content, view, width, height)
  local Renderer = requireFeature(
    "libs.hgss.src.presentation.PokegearRadioRenderer",
    "radio panels have no renderer yet: planes, slide, and pulse draw nothing"
  )
  local canvas = scope:own(love.graphics.newCanvas(width, height))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setColor(1, 1, 1, 1)
  Renderer.drawPanes(resources.graphics, resources.images, resources.textRenderer, content, view, panes)
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

---@param red number
---@param green number
---@param blue number
---@param want table
---@return boolean close in solid-color space
local function matchesColor(red, green, blue, want)
  return math.abs(red - want[1]) < 0.01 and math.abs(green - want[2]) < 0.01 and math.abs(blue - want[3]) < 0.01
end

---@param path string
---@return table solid color hung on the path
local function colorFor(path)
  local hues = {
    { 0.85, 0.15, 0.15 },
    { 0.15, 0.65, 0.15 },
    { 0.15, 0.35, 0.85 },
    { 0.85, 0.75, 0.15 },
    { 0.65, 0.25, 0.75 },
    { 0.15, 0.75, 0.75 },
  }
  return hues[colorSeedFor(path) + 1]
end

---@param data table
---@param frame table display rectangle
---@param color table
---@return integer count of matching pixels inside the frame
local function countIn(data, frame, color)
  local found = 0
  -- Half-open coverage: the far edge column belongs to the neighboring
  -- pane, so a same-hue neighbor edge must never read as owned paint.
  local x0 = math.max(0, math.floor(frame.x))
  local y0 = math.max(0, math.floor(frame.y))
  local x1 = math.min(data:getWidth() - 1, math.ceil(frame.x + frame.width) - 1)
  local y1 = math.min(data:getHeight() - 1, math.ceil(frame.y + frame.height) - 1)
  for y = y0, y1 do
    for x = x0, x1 do
      local red, green, blue, alpha = data:getPixel(x, y)
      if alpha > 0.01 and matchesColor(red, green, blue, color) then
        found = found + 1
      end
    end
  end
  return found
end

---@param data table
---@param color table
---@return table<number, table> matching host pixels outside every frame
local function outsideAll(data, frames, color)
  local function inside(x, y)
    for _, frame in ipairs(frames) do
      if x >= frame.x and x < frame.x + frame.width and y >= frame.y and y < frame.y + frame.height then
        return true
      end
    end
    return false
  end
  -- Stride two: containment strays from pane-sized visuals cannot hide
  -- between sampled pixels, and full-canvas exact scans stay affordable.
  local strays = {}
  for y = 0, data:getHeight() - 1, 2 do
    for x = 0, data:getWidth() - 1, 2 do
      local red, green, blue, alpha = data:getPixel(x, y)
      if alpha > 0.01 and matchesColor(red, green, blue, color) and not inside(x, y) then
        strays[#strays + 1] = { x = x, y = y }
      end
    end
  end
  return strays
end

---@param data table
---@param frame table display rectangle
---@param color table
---@return table? bounding box of the color inside the frame
local function boundsIn(data, frame, color)
  local box = nil
  -- Half-open coverage, matching countIn: neighboring-pane edge pixels
  -- stay out of the measured box.
  local x0 = math.max(0, math.floor(frame.x))
  local y0 = math.max(0, math.floor(frame.y))
  local x1 = math.min(data:getWidth() - 1, math.ceil(frame.x + frame.width) - 1)
  local y1 = math.min(data:getHeight() - 1, math.ceil(frame.y + frame.height) - 1)
  for y = y0, y1 do
    for x = x0, x1 do
      local red, green, blue, alpha = data:getPixel(x, y)
      if alpha > 0.01 and matchesColor(red, green, blue, color) then
        if box == nil then
          box = { minX = x, minY = y, maxX = x, maxY = y }
        else
          box.minX = math.min(box.minX, x)
          box.minY = math.min(box.minY, y)
          box.maxX = math.max(box.maxX, x)
          box.maxY = math.max(box.maxY, y)
        end
      end
    end
  end
  return box
end

function T.radio_transitions_and_palette_layering_match_source_on_every_layout(scope)
  local manifest = fixtureManifest()
  local layouts = {
    { kind = "wide", facts = singleDisplay(512, 192), width = 512, height = 192 },
    { kind = "tall", facts = singleDisplay(256, 384), width = 256, height = 384 },
    { kind = "native", facts = singleDisplay(512, 384), width = 512, height = 384 },
    { kind = "dual", facts = dualFacts(), width = 256, height = 384 },
  }
  for _, layout in ipairs(layouts) do
    local shell, _ = openShell(manifest, layout.facts)
    local status = shell:status()
    local infoPlacement = assert(findPane(status, "information").placement, layout.kind .. " places information")
    local controlsPlacement = assert(findPane(status, "controls").placement, layout.kind .. " places controls")
    local panes = { information = infoPlacement, controls = controlsPlacement }
    local resources = renderResources(scope, manifest)
    local content = radioContent(manifest, 0)
    local panelColor = colorFor(content.panel)
    local secondColor = colorFor(content.second)
    local upperColor = colorFor(content.upper)
    local pulseColor0 = colorFor(content.pulseFrames[1])
    local pulseColor1 = colorFor(content.pulseFrames[2])
    local cornerColor = colorFor(content.corner)
    local infoFrame = assert(infoPlacement.frame, layout.kind .. " frames information")
    local controlsFrame = assert(controlsPlacement.frame, layout.kind .. " frames controls")

    -- The text panel travels eighty source pixels in eight ten-pixel
    -- steps, then settles: size never changes, exactly one axis moves,
    -- every step advances ten, and further steps hold still.
    local boxes = {}
    for step = 0, 8 do
      local data =
        drawRadio(scope, resources, panes, content, radioView({ slideStep = step }), layout.width, layout.height)
      boxes[step] = boundsIn(data, infoFrame, panelColor)
      Assert.notNil(boxes[step], layout.kind .. " draws the text panel at slide step " .. step)
    end
    local first, last = boxes[0], assert(boxes[8], "the settled panel reads above")
    Assert.equal(last.maxX - last.minX, first.maxX - first.minX, layout.kind .. " keeps the panel width while sliding")
    Assert.equal(last.maxY - last.minY, first.maxY - first.minY, layout.kind .. " keeps the panel height while sliding")
    local dx, dy = last.minX - first.minX, last.minY - first.minY
    local axis = nil
    if math.abs(dx) == 80 and dy == 0 then
      axis = "x"
    elseif dx == 0 and math.abs(dy) == 80 then
      axis = "y"
    end
    Assert.notNil(axis, layout.kind .. " slides the panel eighty pixels along one axis")
    local sign = axis == "x" and (dx > 0 and 1 or -1) or (dy > 0 and 1 or -1)
    for step = 1, 7 do
      local box = assert(boxes[step], layout.kind .. " reads slide step " .. step)
      local along = axis == "x" and (box.minX - first.minX) or (box.minY - first.minY)
      Assert.equal(along, sign * step * 10, layout.kind .. " advances ten pixels at slide step " .. step)
    end
    local settled =
      drawRadio(scope, resources, panes, content, radioView({ slideStep = 8 }), layout.width, layout.height)
    local past = drawRadio(scope, resources, panes, content, radioView({ slideStep = 9 }), layout.width, layout.height)
    Assert.deepEqual(
      boundsIn(past, infoFrame, panelColor),
      boundsIn(settled, infoFrame, panelColor),
      layout.kind .. " holds the panel still past the eighth step"
    )

    -- The pulse sprite sits on the tuned cursor and follows its frames;
    -- an untuned dial shows no pulse anywhere in the controls pane.
    local tuned = drawRadio(scope, resources, panes, content, radioView({ slideStep = 8 }), layout.width, layout.height)
    local hostX, hostY = toHost(controlsPlacement, 112, 76)
    local red, green, blue, alpha = tuned:getPixel(math.floor(hostX), math.floor(hostY))
    Assert.isTrue(alpha > 0.01, layout.kind .. " paints the tuned cursor")
    Assert.isTrue(
      matchesColor(red, green, blue, pulseColor0),
      layout.kind .. " seats the pulse sprite on the tuned cursor"
    )
    local framed = drawRadio(
      scope,
      resources,
      panes,
      content,
      radioView({ slideStep = 8, pulseFrame = 1 }),
      layout.width,
      layout.height
    )
    local red1, green1, blue1, _ = framed:getPixel(math.floor(hostX), math.floor(hostY))
    Assert.isTrue(
      matchesColor(red1, green1, blue1, pulseColor1),
      layout.kind .. " advances the pulse sprite with its frame"
    )
    local untuned = drawRadio(
      scope,
      resources,
      panes,
      content,
      radioView({ slideStep = 8, station = 255, signal = 0 }),
      layout.width,
      layout.height
    )
    Assert.equal(
      countIn(untuned, controlsFrame, pulseColor0) + countIn(untuned, controlsFrame, pulseColor1),
      0,
      layout.kind .. " hides the pulse sprite with no station tuned"
    )
    local weak =
      drawRadio(scope, resources, panes, content, radioView({ slideStep = 8, signal = 1 }), layout.width, layout.height)
    local weakRed, weakGreen, weakBlue, weakAlpha = weak:getPixel(math.floor(hostX), math.floor(hostY))
    Assert.isTrue(
      weakAlpha > 0.01 and matchesColor(weakRed, weakGreen, weakBlue, pulseColor0),
      layout.kind .. " keeps the pulse sprite on a weak but tuned station"
    )

    -- Each native plane paints its own pane: the second control plane
    -- covers the controls pane over the base plane, and the
    -- information upper plane covers the information pane under the
    -- text and panel. Control paint never reads inside information and
    -- vice versa, so neither plane is flattened into one unmasked panel.
    Assert.isTrue(
      countIn(tuned, controlsFrame, secondColor) > 0,
      layout.kind .. " paints the second control plane over its pane"
    )
    Assert.isTrue(
      countIn(tuned, infoFrame, upperColor) > 0,
      layout.kind .. " paints the information upper plane over its pane"
    )
    Assert.equal(
      countIn(tuned, infoFrame, secondColor),
      0,
      layout.kind .. " keeps control paint out of the information pane"
    )

    -- Focus corners answer focus, and every radio pixel stays inside its
    -- own semantic pane, so the shared clock and strip regions elsewhere
    -- never take radio paint on any layout.
    Assert.isTrue(countIn(tuned, controlsFrame, cornerColor) > 0, layout.kind .. " draws focus corners while focused")
    local blurred = drawRadio(
      scope,
      resources,
      panes,
      content,
      radioView({ slideStep = 8, focused = false }),
      layout.width,
      layout.height
    )
    Assert.equal(countIn(blurred, controlsFrame, cornerColor), 0, layout.kind .. " lifts focus corners without focus")
    for step = 0, 8, 4 do
      local data =
        drawRadio(scope, resources, panes, content, radioView({ slideStep = step }), layout.width, layout.height)
      Assert.deepEqual(
        outsideAll(data, { infoFrame }, panelColor),
        {},
        layout.kind .. " keeps panel paint inside the information pane at step " .. step
      )
      Assert.deepEqual(
        outsideAll(data, { controlsFrame }, pulseColor0),
        {},
        layout.kind .. " keeps pulse paint inside the controls pane at step " .. step
      )
    end

    -- Drawn cursor pixels round-trip through the published placement back
    -- to source units, so pointer input and rendered placement agree.
    local backX, backY = toSource(controlsPlacement, hostX, hostY)
    Assert.isTrue(
      math.abs(backX - 112) < 0.51 and math.abs(backY - 76) < 0.51,
      layout.kind .. " maps the drawn cursor back to its dial point"
    )

    -- A skin swap repaints from prepared assets while a repeated draw is
    -- byte-stable: no render-time randomness or mutation.
    local other = radioContent(manifest, 1)
    local swapped =
      drawRadio(scope, resources, panes, other, radioView({ skin = 1, slideStep = 8 }), layout.width, layout.height)
    local differences = 0
    local samples = 0
    for y = 0, tuned:getHeight() - 1, 16 do
      for x = 0, tuned:getWidth() - 1, 16 do
        samples = samples + 1
        local r0, g0, b0, a0 = tuned:getPixel(x, y)
        local r1, g1, b1, a1 = swapped:getPixel(x, y)
        if math.abs(r0 - r1) + math.abs(g0 - g1) + math.abs(b0 - b1) + math.abs(a0 - a1) > 0.01 then
          differences = differences + 1
        end
      end
    end
    Assert.isTrue(samples > 0 and differences > 0, layout.kind .. " repaints the skin swap from prepared assets")
    local again = drawRadio(scope, resources, panes, content, radioView({ slideStep = 8 }), layout.width, layout.height)
    local drift = 0
    for y = 0, tuned:getHeight() - 1, 16 do
      for x = 0, tuned:getWidth() - 1, 16 do
        local r0, g0, b0, a0 = tuned:getPixel(x, y)
        local r2, g2, b2, a2 = again:getPixel(x, y)
        if math.abs(r0 - r2) + math.abs(g0 - g2) + math.abs(b0 - b2) + math.abs(a0 - a2) > 0.001 then
          drift = drift + 1
        end
      end
    end
    Assert.equal(drift, 0, layout.kind .. " draws deterministically with no render-time randomness")
    shell:dispose()
  end
end

return GraphicsSmoke.suite(T, { tags = { "pokegear" } })
