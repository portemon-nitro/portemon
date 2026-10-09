-- Regional focus resolution for the Save Editor's semantic navigation model.

local Assert = require("tests.support.Assert")
local Controller = require("app.src.saveeditor.SaveEditorController")
local FieldInput = require("libs.hgss.src.field.FieldInput")
local Layout = require("app.src.saveeditor.SaveEditorLayout")
local SaveEditorState = require("app.src.saveeditor.SaveEditorState")
local ValueEditor = require("app.src.saveeditor.SaveEditorValueEditor")

local T = { tests = {} }

local function navigationModule()
  local ok, navigation = pcall(require, "app.src.saveeditor.SaveEditorNavigation")
  Assert.isTrue(ok and type(navigation) == "table", "regional Save Editor focus routing is not implemented")
  Assert.isTrue(type(navigation.resolve) == "function", "regional directional resolution is missing")
  Assert.isTrue(type(navigation.reconcile) == "function", "logical focus reconciliation is missing")
  return navigation
end

local function control(id, regionId, x, y, width, height, order, overrides)
  return {
    id = id,
    regionId = regionId,
    rect = { x = x, y = y, width = width, height = height },
    order = order,
    eligible = true,
    action = { kind = "activate", targetId = id },
    overrides = overrides,
  }
end

local function focus(regionId, targetId)
  return { scopeId = "editor", regionId = regionId, targetId = targetId }
end

function T.tests.regional_movement_stays_local_before_taking_a_declared_exit()
  local Navigation = navigationModule()
  local snapshot = {
    scope = { id = "editor", epoch = 1 },
    regions = {
      {
        id = "rail",
        rect = { x = 0, y = 0, width = 20, height = 120 },
        kind = "spatial",
        order = 1,
        defaultId = "section:Party",
      },
      {
        id = "party",
        rect = { x = 24, y = 20, width = 140, height = 24 },
        kind = "row",
        order = 2,
        defaultId = "party:1",
        logical = {
          count = 2,
          idAt = function(index)
            return ({ "party:1", "party:2" })[index]
          end,
          indexOf = function(id)
            if id == "party:1" then
              return 1
            end
            if id == "party:2" then
              return 2
            end
            return nil
          end,
        },
        exits = { left = { kind = "region", id = "rail", entry = "spatial", fallback = "stop" } },
      },
    },
    controls = {
      control("section:Party", "rail", 2, 20, 16, 16, 1),
      control("party:1", "party", 26, 24, 24, 16, 2),
      control("party:2", "party", 56, 24, 24, 16, 3),
    },
  }

  local move = Navigation.resolve(snapshot, focus("party", "party:1"), "right")
  Assert.equal(move.kind, "move", "the first direction resolves to a focus move")
  Assert.equal(move.targetId, "party:2", "movement stays within the current Party strip")
  Assert.equal(move.regionId, "party", "the local move stays in its region")

  local exit = Navigation.resolve(snapshot, focus("party", "party:1"), "left")
  Assert.equal(exit.kind, "move", "the declared exit resolves a move")
  Assert.equal(exit.targetId, "section:Party", "the boundary exit enters the section rail")
  Assert.equal(exit.regionId, "rail", "only boundary movement changes regions")
end

function T.tests.logical_lists_keep_offscreen_identity_and_reveal_the_next_row()
  local Navigation = navigationModule()
  local rowIds = {}
  for index = 1, 80 do
    rowIds[index] = "flag:" .. index
  end
  local snapshot = {
    scope = { id = "editor", epoch = 2 },
    regions = {
      {
        id = "flags",
        rect = { x = 40, y = 20, width = 180, height = 120 },
        kind = "list",
        viewportId = "flags",
        order = 1,
        defaultId = rowIds[1],
        logical = {
          count = #rowIds,
          idAt = function(index)
            return rowIds[index]
          end,
          indexOf = function(id)
            for index, rowId in ipairs(rowIds) do
              if rowId == id then
                return index
              end
            end
            return nil
          end,
        },
      },
    },
    controls = {
      control(rowIds[1], "flags", 44, 24, 150, 12, 1),
      control(rowIds[2], "flags", 44, 38, 150, 12, 2),
      control(rowIds[3], "flags", 44, 52, 150, 12, 3),
    },
  }

  local remembered = focus("flags", rowIds[40])
  local move = Navigation.resolve(snapshot, remembered, "down")
  Assert.equal(move.kind, "move", "Down resolves a logical row move")
  Assert.equal(move.targetId, rowIds[41], "Down advances one logical row outside the visible window")
  Assert.equal(move.regionId, "flags", "logical row movement remains in the list region")
  Assert.equal(move.reveal.index, 41, "the destination requests viewport reveal")
end

function T.tests.entering_a_list_region_focuses_its_remembered_row_without_activation()
  local Navigation = navigationModule()
  local rowIds = { "flag:1", "flag:2", "flag:3", "flag:40" }
  local snapshot = {
    scope = { id = "editor", epoch = 2 },
    regions = {
      {
        id = "rail",
        rect = { x = 0, y = 0, width = 20, height = 120 },
        kind = "spatial",
        order = 1,
        defaultId = "section:Progress",
      },
      {
        id = "flags",
        rect = { x = 32, y = 24, width = 180, height = 100 },
        kind = "list",
        viewportId = "flags",
        order = 2,
        defaultId = rowIds[1],
        logical = {
          count = #rowIds,
          idAt = function(index)
            return rowIds[index]
          end,
          indexOf = function(id)
            for index, rowId in ipairs(rowIds) do
              if rowId == id then
                return index
              end
            end
            return nil
          end,
        },
      },
    },
    controls = {
      control("section:Progress", "rail", 2, 28, 16, 16, 1),
      control(rowIds[1], "flags", 40, 32, 140, 16, 2),
      control(rowIds[2], "flags", 40, 52, 140, 16, 3),
    },
    remembered = { flags = rowIds[4] },
  }

  local entered = Navigation.resolve(snapshot, focus("rail", "section:Progress"), "right")
  Assert.equal(entered.kind, "move", "entering the list region moves logical focus")
  Assert.equal(entered.targetId, rowIds[4], "entry restores the remembered logical row immediately")
  Assert.equal(entered.regionId, "flags", "the remembered row belongs to the list region")
  Assert.equal(entered.reveal.index, 4, "entry reveals the remembered row when it is offscreen")
end

function T.tests.entering_a_logical_region_can_reveal_its_offscreen_default()
  local Navigation = navigationModule()
  local rowIds = { "party:header:level", "party:header:experience" }
  local snapshot = {
    scope = { id = "editor", epoch = 2 },
    regions = {
      {
        id = "footer",
        kind = "spatial",
        order = 1,
        defaultId = "back",
        exits = { up = { kind = "region", id = "header", entry = "remembered", fallback = "stop" } },
      },
      {
        id = "header",
        kind = "row",
        order = 2,
        viewportId = "party",
        defaultId = rowIds[1],
        logical = {
          count = #rowIds,
          idAt = function(index)
            return rowIds[index]
          end,
          indexOf = function(id)
            for index, rowId in ipairs(rowIds) do
              if rowId == id then
                return index
              end
            end
            return nil
          end,
        },
      },
    },
    controls = { control("back", "footer", 100, 100, 60, 24, 1) },
  }

  local entered = Navigation.resolve(snapshot, focus("footer", "back"), "up")
  Assert.equal(entered.kind, "move", "directional entry can select a logical row outside the visible window")
  Assert.equal(entered.targetId, rowIds[1], "entry chooses the declared logical default")
  Assert.equal(entered.regionId, "header", "focus enters the requested semantic region")
  Assert.equal(entered.reveal.viewportId, "party", "entry requests a viewport reveal")
  Assert.equal(entered.reveal.index, 1, "the offscreen default retains its logical position")
end

function T.tests.static_logical_regions_do_not_request_viewport_reveals()
  local Navigation = navigationModule()
  local snapshot = {
    scope = { id = "editor", epoch = 1 },
    regions = {
      {
        id = "party:members",
        kind = "row",
        order = 1,
        defaultId = "party:slot:0",
        logical = {
          count = 2,
          idAt = function(index)
            return ({ "party:slot:0", "party:slot:1" })[index]
          end,
          indexOf = function(id)
            return id == "party:slot:0" and 1 or id == "party:slot:1" and 2 or nil
          end,
        },
      },
    },
    controls = {
      control("party:slot:0", "party:members", 0, 0, 20, 20, 1),
      control("party:slot:1", "party:members", 22, 0, 20, 20, 2),
    },
  }

  local move = Navigation.resolve(snapshot, focus("party:members", "party:slot:0"), "right")
  Assert.equal(move.targetId, "party:slot:1", "static members remain navigable")
  Assert.isNil(move.reveal, "static members never request viewport scrolling")
end

function T.tests.reconciliation_moves_focus_with_its_published_region()
  local Navigation = navigationModule()
  local snapshot = {
    scope = { id = "editor", epoch = 2 },
    regions = {
      { id = "old", kind = "row", order = 1, defaultId = "shared" },
      { id = "new", kind = "row", order = 2, defaultId = "shared" },
    },
    controls = { control("shared", "new", 20, 0, 20, 20, 1) },
  }

  local reconciled = Navigation.reconcile(snapshot, focus("old", "shared"), {})

  Assert.equal(reconciled.regionId, "new", "the control's current region owns focus after reflow")
  Assert.equal(reconciled.targetId, "shared", "reconciliation preserves the moved target")
end

function T.tests.disabled_targets_and_explicit_stops_never_escape_the_active_region()
  local Navigation = navigationModule()
  local snapshot = {
    scope = { id = "editor", epoch = 4 },
    regions = {
      {
        id = "decision",
        rect = { x = 80, y = 60, width = 64, height = 24 },
        kind = "spatial",
        order = 1,
        defaultId = "cancel",
      },
    },
    controls = {
      control("cancel", "decision", 80, 60, 24, 20, 1, { right = { kind = "stop" } }),
      control("confirm", "decision", 120, 60, 24, 20, 2),
      (function()
        local disabled = control("disabled", "decision", 108, 60, 18, 20, 3)
        disabled.eligible = false
        return disabled
      end)(),
    },
  }

  local stopped = Navigation.resolve(snapshot, focus("decision", "cancel"), "right")
  Assert.equal(stopped.kind, "stay", "an explicit stop prevents modal escape")
  Assert.equal(stopped.regionId, "decision", "a stop retains the active decision region")

  local automatic = Navigation.resolve(snapshot, focus("decision", "cancel"), "right")
  Assert.equal(automatic.kind, "stay", "a disabled destination cannot replace an explicit stop")
end

function T.tests.empty_logical_lists_reconcile_to_the_declared_inert_target()
  local Navigation = navigationModule()
  local snapshot = {
    scope = { id = "editor", epoch = 3 },
    regions = {
      {
        id = "flags",
        rect = { x = 32, y = 24, width = 180, height = 100 },
        kind = "list",
        order = 1,
        defaultId = "flags:empty",
        logical = {
          count = 0,
          idAt = function()
            return nil
          end,
          indexOf = function()
            return nil
          end,
        },
      },
    },
    controls = {
      control("flags:empty", "flags", 40, 32, 140, 20, 1),
    },
  }

  local emptyFocus = focus("flags", "flags:empty")
  Assert.equal(
    Navigation.reconcile(snapshot, emptyFocus, { "flags:empty" }),
    emptyFocus,
    "an empty list preserves its declared inert target"
  )
  local move = Navigation.resolve(snapshot, emptyFocus, "down")
  Assert.equal(move.kind, "stay", "an empty list remains escapable without inventing a row")
end

function T.tests.regional_focus_uses_the_live_save_editor_layout_and_controller_adapter()
  local controller = Controller.new()
  local view = {
    status = "ready",
    ready = true,
    dirty = false,
    sectionDirty = false,
    section = "Player",
    scope = controller:snapshot().scope,
    session = { playerName = "PLAYER", money = 3000, frameIndex = 0 },
  }
  local layout = Layout.compute(view, 800, 600, {
    lineHeight = 14,
    measure = function(text)
      return #text * 7
    end,
  })
  controller:setFocus("money")
  local state = setmetatable({ controller = controller, valueEditor = nil }, SaveEditorState)

  SaveEditorState._navigate(state, layout, "down")

  Assert.equal(controller.focus, "dialogue-frame", "the live Player form moves by its published geometry")
  Assert.equal(controller.section, "Player", "focus movement does not activate or change the selected section")
end

function T.tests.navigation_debug_overlay_shows_the_current_region_and_resolver_reasons()
  local controller = Controller.new()
  local layout = Layout.compute({
    status = "ready",
    ready = true,
    dirty = false,
    sectionDirty = false,
    section = "Player",
    scope = controller:snapshot().scope,
    session = { playerName = "PLAYER", money = 3000, frameIndex = 0 },
  }, 800, 600, {
    lineHeight = 14,
    measure = function(text)
      return #text * 7
    end,
  })
  controller:setFocus("money")
  controller.scopeId, controller.scopeEpoch = layout.scopeId, layout.scopeEpoch
  local lines = {}
  local transforms = {}
  local graphics = {
    push = function() end,
    pop = function() end,
    origin = function() end,
    intersectScissor = function() end,
    translate = function(x, y)
      transforms[#transforms + 1] = { x = x, y = y }
    end,
    scale = function(x, y)
      transforms[#transforms + 1] = { x = x, y = y }
    end,
    setColor = function() end,
    rectangle = function() end,
    print = function(text)
      lines[#lines + 1] = text
    end,
  }
  local state = {
    navigationDebug = true,
    controller = controller,
    renderer = { graphics = graphics },
    valueEditor = nil,
  }

  SaveEditorState._drawNavigationDebug(state, {
    layout = layout,
    presentation = {
      panes = {
        {
          interactive = true,
          placement = {
            frame = { x = 10, y = 20, width = 640, height = 480 },
            origin = { x = 12, y = 24 },
            clipRect = { x = 10, y = 20, width = 640, height = 480 },
            logicalWidth = 320,
            logicalHeight = 240,
            scale = 2,
          },
        },
      },
    },
  })

  Assert.equal(#lines, 5, "the overlay includes focus identity and four resolver results")
  Assert.equal(transforms[1].x, 12, "the focus outline uses the interactive pane origin")
  Assert.equal(transforms[2].x, 2, "the focus outline uses the interactive pane scale")
  Assert.isTrue(lines[1]:find("body / money", 1, true) ~= nil, "the overlay identifies the active region")
  Assert.isTrue(lines[2]:find("up: stop", 1, true) ~= nil, "the overlay reports the resolver diagnostic reason")
end

local function choiceDeviceMetrics()
  return {
    lineHeight = 14,
    measure = function(text)
      return #text * 7
    end,
  }
end

local function choiceDeviceHarness(optionCount)
  local controller = Controller.new()
  controller:setSection("Bag")
  local options = {}
  for index = 1, optionCount or 12 do
    options[index] = { key = string.format("K%02d", index), label = "Choice " .. index }
  end
  local editor = ValueEditor.new({ kind = "choice", value = options[5].key, options = options })
  local metrics = choiceDeviceMetrics()
  local function buildView()
    return {
      section = "Bag",
      status = "ready",
      ready = true,
      dirty = false,
      bagRows = {},
      valueEditor = editor:snapshot(),
      scope = { id = "value:choice", epoch = 1, kind = "value", focusId = controller.focus },
      scrollOffsets = {},
    }
  end
  local function buildLayout()
    editor:update(256)
    return Layout.compute(buildView(), 256, 192, metrics)
  end
  local finished = 0
  local state = setmetatable({
    status = "ready",
    controller = controller,
    fieldInput = FieldInput.new(),
    inputTick = 1,
    scopeEpoch = 0,
    tickRemainder = 0,
    valueEditor = editor,
    locationPreviewMemory = {},
    _snapshot = buildView,
    _resolve = function()
      return { content = { layout = buildLayout() } }
    end,
    _finishValueEditor = function()
      finished = finished + 1
    end,
  }, SaveEditorState)
  state:_syncScope()
  state.fieldInput:beginUi(0)
  return {
    state = state,
    controller = controller,
    editor = editor,
    finishedCount = function()
      return finished
    end,
  }
end

local function driveChoiceMove(harness, device)
  if device == "keyboard" then
    harness.state:keypressed("down")
    harness.state:keyreleased("down")
  elseif device == "gamepad" then
    harness.state:gamepadpressed(nil, "dpdown")
    harness.state:gamepadreleased(nil, "dpdown")
  else
    harness.state:_consumeUiInput({ { type = "navigate", direction = "down" } })
  end
end

local function driveChoiceConfirm(harness, device)
  if device == "keyboard" then
    harness.state:keypressed("return")
    harness.state:keyreleased("return")
  elseif device == "gamepad" then
    harness.state:gamepadpressed(nil, "a")
    harness.state:gamepadreleased(nil, "a")
  else
    harness.state:_consumeUiInput({ { type = "confirm" } })
  end
end

function T.tests.keyboard_gamepad_and_semantic_choice_input_agree_and_release_pointer_capture()
  local navigated = {}
  for _, device in ipairs({ "keyboard", "gamepad", "semantic" }) do
    local harness = choiceDeviceHarness()
    harness.controller:setFocus("choice:K05")
    harness.controller:pointer({
      type = "pointer_down",
      pointerId = "mouse:1",
      targetId = "choice:K05",
      x = 10,
      y = 10,
    })
    driveChoiceMove(harness, device)
    navigated[device] = harness
  end

  for _, device in ipairs({ "keyboard", "gamepad", "semantic" }) do
    local harness = navigated[device]
    Assert.equal(harness.controller.focus, "choice:K06", device .. " Down moves one logical choice row")
    Assert.isNil(
      harness.controller.capturedTarget,
      device .. " navigation releases the in-flight pointer capture"
    )
    Assert.isNil(harness.controller.pointerId, device .. " navigation releases the pointer identity")
    Assert.isTrue(harness.controller.focusVisible, device .. " navigation keeps keyboard focus visible")
    Assert.isNil(harness.controller.modal, device .. " navigation opens no modal layer")
    Assert.equal(harness.controller.section, "Bag", device .. " navigation stays in its section")
  end
  Assert.equal(
    navigated.keyboard.controller.scrollOffsets["value:choice"],
    navigated.gamepad.controller.scrollOffsets["value:choice"],
    "keyboard and gamepad choice scrolling agree"
  )
  Assert.equal(
    navigated.keyboard.controller.scrollOffsets["value:choice"],
    navigated.semantic.controller.scrollOffsets["value:choice"],
    "keyboard and semantic choice scrolling agree"
  )

  for _, device in ipairs({ "keyboard", "gamepad", "semantic" }) do
    local stale = navigated[device].controller:pointer({
      type = "pointer_up",
      pointerId = "mouse:1",
      targetId = "choice:K05",
      x = 10,
      y = 10,
    })
    Assert.isNil(stale, device .. " releases capture so the previous row cannot activate late")
  end

  local committed = {}
  for _, device in ipairs({ "keyboard", "gamepad", "semantic" }) do
    local harness = choiceDeviceHarness()
    harness.controller:setFocus("choice:K05")
    driveChoiceConfirm(harness, device)
    committed[device] = harness
  end
  for _, device in ipairs({ "keyboard", "gamepad", "semantic" }) do
    local harness = committed[device]
    Assert.deepEqual(
      harness.editor:result(),
      { kind = "confirm", value = "K05" },
      device .. " confirm commits the focused choice exactly once"
    )
    Assert.equal(harness.finishedCount(), 1, device .. " confirm retires the editor exactly once")
    Assert.equal(harness.controller.focus, "choice:K05", device .. " confirm keeps the committed focus")
    Assert.isNil(harness.state.editorFeedback, device .. " confirm reports no diagnostic")
    Assert.isNil(harness.controller.modal, device .. " confirm opens no modal layer")
  end
end

return T
