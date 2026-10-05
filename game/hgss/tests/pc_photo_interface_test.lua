-- The album pairs its rendered photo viewport and input mapping under each
-- supported application display layout.

local Assert = require("tests.support.Assert")
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local function interfaceModule()
  local ok, module = pcall(require, "game.hgss.src.pc.PhotoAlbumInterface")
  Assert.isTrue(ok, "Photo Album display layouts must be paired render and input resolvers")
  return assert(module)
end

local function measurement(width, height, topology, signature)
  return {
    width = width,
    height = height,
    topology = topology,
    pixelRatio = 1,
    signature = signature,
  }
end

local function displays()
  return {
    dualDisplay = measurement(
      912,
      684,
      ScreenTopology.dualDisplay({
        id = "world",
        rect = { x = 400, y = 100, width = 256, height = 192 },
        role = "world",
        touch = false,
      }, {
        id = "aux",
        rect = { x = 100, y = 300, width = 256, height = 192 },
        role = "auxiliary",
        touch = true,
      }),
      "photo-dual"
    ),
    nativeLike = measurement(
      640,
      480,
      ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 640, height = 480 },
        role = "world",
        touch = false,
      }),
      "photo-native"
    ),
    wide = measurement(
      1280,
      720,
      ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 1280, height = 720 },
        role = "world",
        touch = false,
      }),
      "photo-wide"
    ),
    tall = measurement(
      390,
      844,
      ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 20, y = 30, width = 390, height = 844 },
        role = "world",
        touch = false,
      }),
      "photo-tall"
    ),
  }
end

local function manifest()
  return {
    photoAlbum = {
      ui = { backgrounds = {}, sprites = {}, animations = {} },
      geometry = {
        list = { rows = 3 },
        actions = { entries = 4 },
        confirmation = { choices = 2 },
        viewerViewport = { x = 4, y = 3, width = 248, height = 185 },
      },
    },
  }
end

local function containsViewport(value, seen)
  if type(value) ~= "table" then
    return false
  end
  if seen[value] then
    return false
  end
  seen[value] = true
  if value.x == 4 and value.y == 3 and value.width == 248 and value.height == 185 then
    return true
  end
  for _, child in pairs(value) do
    if containsViewport(child, seen) then
      return true
    end
  end
  return false
end

function T.viewer_geometry_and_input_resolve_together_for_each_display_shape()
  local interfaces = interfaceModule().defaults(manifest())
  local expectedInputKey
  for configuration, display in pairs(displays()) do
    Assert.isTrue(type(interfaces[configuration]) == "function", configuration .. " has a paired resolver")
    local session = ApplicationPresentation.new(interfaces)
    local views = {
      {
        phase = "list",
        occupiedSlots = { 0 },
        selectedSlot = 0,
        visiblePhotos = { { slot = 0, photo = { party = {} } } },
      },
      { phase = "actions", occupiedSlots = { 0 }, selectedSlot = 0, selectedAction = "view" },
      { phase = "delete_confirm", occupiedSlots = { 0 }, selectedSlot = 0, deleteChoice = "yes" },
      {
        phase = "move_target",
        occupiedSlots = { 0, 8 },
        selectedSlot = 0,
        visiblePhotos = { { slot = 0, photo = { party = {} } }, { slot = 8, photo = { party = {} } } },
      },
      {
        phase = "viewer",
        occupiedSlots = { 0, 8 },
        selectedSlot = 0,
        selectedIndex = 1,
        viewer = { phase = "ready", view = { opaque = true } },
      },
    }
    local view = views[#views]
    local plan = session:resolve(display, view)
    Assert.isTrue(type(plan.render) == "function", configuration .. " resolves its viewer renderer")
    Assert.isTrue(type(plan.mapInput) == "function", configuration .. " resolves matching viewer input")
    Assert.isTrue(
      type(plan.inputKey) == "string" and plan.inputKey ~= "",
      configuration .. " has stable input identity"
    )
    Assert.isTrue(containsViewport(plan, {}), configuration .. " keeps the source photo viewport and clipping")
    if expectedInputKey == nil then
      expectedInputKey = plan.inputKey
    else
      Assert.equal(plan.inputKey, expectedInputKey, "each display layout keeps the same viewer input contract")
    end
    local mapped = session:mapInput({ { type = "navigate", direction = "right" } }, view)
    Assert.deepEqual(
      mapped,
      { { type = "navigate", direction = "right" } },
      "keyboard next is shared by the resolved plan"
    )
    local expected = {
      { type = "activate", target = "photo", slot = 0 },
      { type = "activate", target = "action", action = "view" },
      { type = "activate", target = "delete-choice", choice = "yes" },
      { type = "activate", target = "photo", slot = 0 },
      { type = "activate", target = "viewer", action = "next" },
    }
    for index, screen in ipairs(views) do
      local screenPlan = session:resolve(display, screen)
      local control
      for _, candidate in ipairs(screenPlan.controls) do
        if
          (index == 1 and candidate.target == "photo")
          or (index == 2 and candidate.action == "view")
          or (index == 3 and candidate.choice == "yes")
          or (index == 4 and candidate.target == "photo")
          or (index == 5 and candidate.action == "next")
        then
          control = candidate
          break
        end
      end
      Assert.notNil(control, configuration .. " renders the control it accepts")
      local rect = assert(control).rect
      local hit = screenPlan.mapInput(
        { type = "pointer_down", x = rect.x + rect.width / 2, y = rect.y + rect.height / 2 },
        screen,
        screenPlan
      )
      Assert.deepEqual(hit, expected[index], configuration .. " hit testing targets the rendered control")
      for _, renderedControl in ipairs(screenPlan.controls) do
        local targetRect = renderedControl.rect
        local targetHit = screenPlan.mapInput({
          type = "pointer_down",
          x = targetRect.x + targetRect.width / 2,
          y = targetRect.y + targetRect.height / 2,
        }, screen, screenPlan)
        if renderedControl.enabled == false then
          Assert.isNil(targetHit, configuration .. " disabled viewer buttons cannot activate")
        elseif renderedControl.target == "photo" then
          Assert.deepEqual(
            targetHit,
            { type = "activate", target = "photo", slot = renderedControl.slot },
            configuration .. " photo art hit matches its persistent slot"
          )
        elseif renderedControl.target == "action" then
          Assert.deepEqual(
            targetHit,
            { type = "activate", target = "action", action = renderedControl.action },
            configuration .. " action hit matches its label"
          )
        elseif renderedControl.target == "delete-choice" then
          Assert.deepEqual(
            targetHit,
            { type = "activate", target = "delete-choice", choice = renderedControl.choice },
            configuration .. " confirmation hit matches its choice"
          )
        else
          Assert.deepEqual(
            targetHit,
            { type = "activate", target = "viewer", action = renderedControl.action },
            configuration .. " viewer sprite hit matches its action"
          )
        end
      end
    end
    session:dispose()
  end
end

return { tests = T }
