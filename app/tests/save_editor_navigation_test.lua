-- Regional focus resolution for the Save Editor's semantic navigation model.

local Assert = require("tests.support.Assert")
local Controller = require("app.src.saveeditor.SaveEditorController")
local Layout = require("app.src.saveeditor.SaveEditorLayout")
local SaveEditorState = require("app.src.saveeditor.SaveEditorState")

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

return T
