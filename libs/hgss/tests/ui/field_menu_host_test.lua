-- FieldMenuHost resolves live menu geometry and translates host input through it.

local Assert = require("tests.support.Assert")
local FieldInput = require("libs.hgss.src.field.FieldInput")
local FieldMenuHost = require("libs.hgss.src.ui.FieldMenuHost")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

---@param opts table
---@return FieldMenuHost
local function makeHost(opts)
  opts.measureText = opts.measureText or function(text)
    return #text * 8
  end
  ---@cast opts FieldMenuHost.Options
  return FieldMenuHost.new(opts --[[@as FieldMenuHost.Options]])
end

function T.uses_the_supplied_auxiliary_surface_for_automatic_menus()
  local host = makeHost({
    width = 1280,
    height = 720,
    input = FieldInput.new(),
    screenTopology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 960, height = 720 }, touch = false, role = "world" },
      { id = "auxiliary", rect = { x = 960, y = 0, width = 320, height = 720 }, touch = true, role = "auxiliary" }
    ),
  })
  host:sync({
    menuDefinition = {
      items = { { text = { text = "Take" }, value = 10 } },
      cancellable = false,
    },
    selectedIndex = 0,
  }, 100)

  local layout = host:presentation().layout
  Assert.equal(layout.surface.id, "auxiliary")
  Assert.equal(layout.placement.scale, 320 / 256, "the auxiliary surface carries the whole reference space")
end

function T.keeps_the_supplied_topology_when_the_host_resizes()
  local host = makeHost({
    width = 1280,
    height = 720,
    input = FieldInput.new(),
    screenTopology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 960, height = 720 }, touch = false, role = "world" },
      { id = "auxiliary", rect = { x = 960, y = 0, width = 320, height = 720 }, touch = true, role = "auxiliary" }
    ),
  })
  host:resize(1920, 1080)
  host:sync({
    menuDefinition = {
      items = { { text = { text = "Take" }, value = 10 } },
      cancellable = false,
    },
    selectedIndex = 0,
  }, 100)

  Assert.equal(host:presentation().layout.surface.id, "auxiliary")
end

function T.replaces_a_supplied_topology_and_rebuilds_active_geometry()
  local host = makeHost({
    width = 256,
    height = 192,
    input = FieldInput.new(),
    screenTopology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      touch = false,
      role = "world",
    }),
  })
  host:sync({
    menuDefinition = { items = { { text = "Take", value = 10 } }, cancellable = true },
    selectedIndex = 0,
  }, 100)
  host:setScreenTopology(ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 390, height = 844 },
    touch = true,
    role = "world",
  }))

  Assert.isTrue(host:presentation().layout.surface.touch)
  Assert.notNil(host:presentation().layout.cancelRect)
end

function T.routes_the_touch_cancel_affordance_on_matching_release()
  local host = makeHost({
    width = 256,
    height = 192,
    input = FieldInput.new(),
    screenTopology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      touch = true,
      role = "world",
    }),
  })
  host:sync({
    menuDefinition = {
      items = { { text = { text = "Take" }, value = 10 } },
      cancellable = true,
    },
    selectedIndex = 0,
  }, 100)

  local cancel = assert(host:presentation().layout.cancelRect)
  local events = host:inputEvents({
    {
      type = "pointer_down",
      x = cancel.x + cancel.width / 2,
      y = cancel.y + cancel.height / 2,
    },
  })

  Assert.equal(events[1].type, "pointer_down")
  Assert.isNil(events[1].itemIndex)
  events = host:inputEvents({
    {
      type = "pointer_up",
      x = cancel.x + cancel.width / 2,
      y = cancel.y + cancel.height / 2,
      dragged = false,
    },
  })
  Assert.equal(events[1].type, "cancel")
end

function T.default_desktop_host_does_not_create_touch_affordances()
  local host = makeHost({ width = 256, height = 192, input = FieldInput.new() })
  host:sync({
    menuDefinition = {
      items = { { text = "Take", value = 10 } },
      cancellable = true,
    },
    selectedIndex = 0,
  }, 100)

  local layout = host:presentation().layout
  Assert.isFalse(layout.surface.touch)
  Assert.isNil(layout.cancelRect)
end

function T.anchors_to_the_supplied_central_region_at_the_field_scale()
  local bounds = { x = 240, y = 0, width = 1440, height = 1080 }
  local host = makeHost({
    width = 1920,
    height = 1080,
    input = FieldInput.new(),
    presentation = function()
      return { bounds = bounds, preferredScale = 3 }
    end,
  })
  host:sync(
    { menuDefinition = { items = { { text = "W", value = 10 } }, cancellable = false }, selectedIndex = 0 },
    100
  )

  local layout = host:presentation().layout
  Assert.equal(layout.placement.scale, 3)
  Assert.equal(layout.placement.origin.x, bounds.x + bounds.width - 256 * 3)
  local snapshot = host:snapshot()
  local row = snapshot.itemRects[0]
  Assert.equal(row.height, 16 * 3, "snapshot rows are published in host coordinates")
  Assert.isTrue(row.x >= layout.placement.origin.x and row.x + row.width <= layout.placement.origin.x + 256 * 3)
end

function T.horizontal_navigation_does_not_change_focus_in_a_relaid_out_single_column_menu()
  local host = makeHost({ width = 256, height = 192, input = FieldInput.new() })
  local state = {
    menuDefinition = {
      items = { { text = "First", value = 1 }, { text = "Second", value = 2 } },
      cancellable = false,
    },
    selectedIndex = 1,
  }
  host:sync(state, 100)
  host:resize(390, 844)

  Assert.deepEqual(host:inputEvents({ { type = "navigate", direction = "left" } }), {})
  Assert.equal(host:presentation().status.selectedIndex, 1)
  Assert.deepEqual(host:inputEvents({ { type = "navigate", direction = "right" } }), {})
  Assert.equal(host:presentation().status.selectedIndex, 1)
end

function T.batched_navigation_uses_each_layout_resolved_focus_target_in_order()
  local host = makeHost({ width = 256, height = 192, input = FieldInput.new() })
  host:sync({
    menuDefinition = {
      items = { { text = "First", value = 1 }, { text = "Second", value = 2 }, { text = "Third", value = 3 } },
      cancellable = false,
    },
    selectedIndex = 0,
  }, 100)

  Assert.deepEqual(
    host:inputEvents({
      { type = "navigate", direction = "down" },
      { type = "navigate", direction = "down" },
    }),
    {
      { type = "focus", itemIndex = 1 },
      { type = "focus", itemIndex = 2 },
    }
  )
end

function T.touch_drag_moves_focus_through_a_clipped_menu()
  local host = makeHost({
    width = 256,
    height = 192,
    input = FieldInput.new(),
    screenTopology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      touch = true,
      role = "world",
    }),
  })
  local items = {}
  for index = 1, 12 do
    items[index] = { text = "Item " .. index, value = index }
  end
  host:sync({ menuDefinition = { items = items, cancellable = false }, selectedIndex = 0 }, 100)
  local layout = host:presentation().layout
  local x = layout.scrollViewport.x + 4
  local y = layout.scrollViewport.y + layout.scrollViewport.height - 4

  host:inputEvents({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  local events = host:inputEvents({ { type = "pointer_move", pointerId = "touch:1", x = x, y = y - 80 } })

  Assert.equal(events[1].type, "focus")
  Assert.isTrue(events[1].itemIndex > 0)
end

function T.only_the_first_pointer_can_control_a_menu_gesture()
  local host = makeHost({ width = 256, height = 192, input = FieldInput.new() })
  host:sync({
    menuDefinition = {
      items = { { text = "First", value = 1 }, { text = "Second", value = 2 } },
      cancellable = false,
    },
    selectedIndex = 0,
  }, 100)
  local layout = host:presentation().layout
  local first = layout.itemRects[0]
  local second = layout.itemRects[1]

  local events = host:inputEvents({
    { type = "pointer_down", pointerId = "touch:1", x = first.x + 1, y = first.y + 1 },
    { type = "pointer_down", pointerId = "touch:2", x = second.x + 1, y = second.y + 1 },
    { type = "pointer_up", pointerId = "touch:2", x = second.x + 1, y = second.y + 1, dragged = false },
    { type = "pointer_up", pointerId = "touch:1", x = first.x + 1, y = first.y + 1, dragged = false },
  })

  Assert.deepEqual(events, {
    { type = "pointer_down", itemIndex = 0 },
    { type = "pointer_up", itemIndex = 0, dragged = false },
  })
end

return { tests = T }
