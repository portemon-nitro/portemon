-- Semantic cartridge selection over the real presentation/input session. Only
-- process paint/audio boundaries are recorded; geometry, focus and gestures use
-- the production launcher and shared UI mechanisms.

local Assert = require("tests.support.Assert")
local DisplayContext = require("libs.ui.src.DisplayContext")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")

local T = {}

local function editionGames(installed)
  installed = installed or {}
  return {
    { versionId = "heartgold", label = "HeartGold", installed = installed.heartgold == true },
    { versionId = "soulsilver", label = "SoulSilver", installed = installed.soulsilver == true },
  }
end

local function renderer()
  local painter = { draws = 0, views = {} }
  function painter:draw(view)
    self.draws = self.draws + 1
    self.views[#self.views + 1] = view
    if view.receipt ~= nil then
      return view.import and view.import.attemptId or view.attemptId
    end
  end
  function painter:drawDual() end
  function painter:drawButton() end
  function painter:dispose() end
  return painter
end

local function audio()
  return { play = function() end, fadeBoot = function() end, update = function() end, dispose = function() end }
end

local function displayContext(width, height, ratio, safeRect, dual)
  safeRect = safeRect or { x = 0, y = 0, width = width, height = height }
  return DisplayContext.new({
    graphics = {
      getDimensions = function()
        return width, height
      end,
      getDPIScale = function()
        return ratio or 1
      end,
    },
    topologyProvider = function()
      local surfaces
      if dual then
        surfaces = {
          {
            id = "main",
            role = "world",
            rect = { x = 0, y = 0, width = 256, height = 192 },
            safeRect = safeRect,
            touch = true,
          },
          {
            id = "aux",
            role = "auxiliary",
            rect = { x = 256, y = 0, width = 256, height = 192 },
            safeRect = { x = 256, y = 0, width = 256, height = 192 },
            touch = true,
          },
        }
      else
        surfaces = {
          {
            id = "main",
            role = "world",
            rect = { x = 0, y = 0, width = width, height = height },
            safeRect = safeRect,
            touch = true,
          },
        }
      end
      return { surfaces = surfaces }
    end,
  })
end

local function state(options)
  options = options or {}
  options.games = options.games or editionGames({ heartgold = true })
  options.renderer = options.renderer or renderer()
  options.audio = options.audio or audio()
  options.width = options.width or 320
  options.height = options.height or 240
  options.safeRect = options.safeRect or { x = 0, y = 0, width = options.width, height = options.height }
  options.pixelRatio = options.pixelRatio or 1
  options.displayContext = options.displayContext
    or displayContext(options.width, options.height, options.pixelRatio, options.safeRect)
  options.onAction = options.onAction or function() end
  options.getImportView = options.getImportView or function()
    return nil
  end
  return require("app.src.launcher.GameSelectState").new(options)
end

local function hostPoint(view, logicalX, logicalY)
  local placement = assert(view.presentation.panes[1].placement, "selection publishes its input placement")
  return LayoutGeometry.logicalToHost(placement, logicalX, logicalY)
end

local function targetPoint(view, targetId)
  local target = assert(view.layout.graph.targets[targetId], "current graph exposes " .. targetId)
  return hostPoint(view, target.rect.x + target.rect.width / 2, target.rect.y + target.rect.height / 2)
end

local function tap(selection, targetId)
  local x, y = targetPoint(selection:view(), targetId)
  selection:touchpressed("finger", x, y)
  selection:touchreleased("finger", x, y)
end

function T.root_has_two_detached_direct_cartridge_actions_for_every_input_mode()
  local actions = {}
  local selection = state({
    onAction = function(targetId)
      actions[#actions + 1] = targetId
    end,
  })
  local view = selection:view()
  Assert.equal(#view.games, 2)
  Assert.equal(view.games[1].versionId, "heartgold")
  Assert.equal(view.games[2].versionId, "soulsilver")
  Assert.equal(view.focusedId, "heartgold")
  Assert.keySet(view.games[1], "installed,label,versionId", "root edition records carry only source facts")
  Assert.keySet(view.games[2], "installed,label,versionId", "missing editions remain real records")
  Assert.isTrue(view.layout.graph.targets.heartgold ~= nil)
  Assert.isTrue(view.layout.graph.targets.soulsilver ~= nil)
  Assert.isNil(view.layout.graph.targets["add-game"])
  Assert.isNil(view.layout.graph.targets.play)

  view.games[1].installed = false
  Assert.isTrue(selection:view().games[1].installed, "painter mutation cannot alter the source snapshot")

  tap(selection, "heartgold")
  Assert.deepEqual(actions, { "heartgold" }, "one tap dispatches the installed cartridge directly")
  selection:keypressed("down")
  selection:keypressed("return")
  selection:gamepadpressed({}, "a")
  Assert.deepEqual(
    actions,
    { "heartgold", "soulsilver", "soulsilver" },
    "keyboard and controller A share direct dispatch"
  )
  selection:dispose()
end

function T.outside_cancel_drag_and_reflow_never_activate_a_stale_target()
  local actions = {}
  local selection = state({
    width = 320,
    height = 240,
    onAction = function(targetId)
      actions[#actions + 1] = targetId
    end,
  })
  selection:_dispatch({
    { type = "pointer_down", pointerId = "outside", outside = true },
    { type = "pointer_up", pointerId = "outside", x = 0, y = 0 },
    { type = "pointer_cancel", pointerId = "never-held" },
    { type = "pointer_up", pointerId = "never-held", x = 0, y = 0 },
  })
  Assert.deepEqual(actions, {}, "outside and coordinate-free cancellation are semantic misses")

  local x, y = targetPoint(selection:view(), "heartgold")
  selection:touchpressed("drag", x, y)
  selection:touchmoved("drag", x, y + 80)
  selection:touchreleased("drag", x, y + 80)
  Assert.deepEqual(actions, {}, "leaving and re-entering a cartridge does not arm activation")

  x, y = targetPoint(selection:view(), "soulsilver")
  selection:touchpressed("cancel", x, y)
  selection._session:cancelPointers()
  selection:_dispatch({ { type = "pointer_cancel", pointerId = "touch:cancel" } })
  selection:touchreleased("cancel", x, y)
  Assert.deepEqual(actions, {}, "direct and session cancellation consume the held release")

  x, y = targetPoint(selection:view(), "heartgold")
  selection:touchpressed("resize", x, y)
  selection:resize(844, 390, { x = 0, y = 0, width = 844, height = 390 }, 1)
  selection:touchreleased("resize", x, y)
  Assert.deepEqual(actions, {}, "geometry replacement invalidates the old capture before release")
  selection:dispose()
end

function T.import_and_error_modes_use_one_action_graph_for_keyboard_controller_and_touch()
  local actions = {}
  local importView = nil
  local selection = state({
    onAction = function(targetId)
      actions[#actions + 1] = targetId
      if targetId == "soulsilver" then
        importView = {
          attemptId = "choose-attempt",
          mode = "choose",
          expectedVersionId = "soulsilver",
          pickerAvailable = true,
          canCancel = true,
        }
      end
    end,
    getImportView = function()
      return importView
    end,
  })
  tap(selection, "soulsilver")
  Assert.equal(selection:view().mode, "choose")
  Assert.equal(selection:view().focusedId, nil, "operation focus is not a root edition")
  Assert.isNil(selection:view().layout.graph.targets.heartgold)
  Assert.isNil(selection:view().layout.graph.targets.soulsilver)
  Assert.notNil(selection:view().layout.graph.targets["choose-rom"])
  Assert.notNil(selection:view().layout.graph.targets.back)

  selection:keypressed("down")
  selection:keypressed("return")
  selection:gamepadpressed({}, "dpdown")
  selection:gamepadpressed({}, "a")
  tap(selection, "back")
  Assert.deepEqual(
    actions,
    { "soulsilver", "choose-rom", "back", "back" },
    "all input modes activate the same current operation targets"
  )

  importView = {
    attemptId = "error-attempt",
    mode = "error",
    expectedVersionId = "soulsilver",
    pickerAvailable = false,
    canCancel = false,
    error = "expected SoulSilver, detected HeartGold",
  }
  selection:update(0)
  Assert.equal(selection:view().mode, "error")
  Assert.isNil(selection:view().layout.graph.targets["choose-rom"], "an unavailable picker has no dead action")
  Assert.notNil(selection:view().layout.graph.targets.retry)
  Assert.notNil(selection:view().layout.graph.targets.back)
  selection:keypressed("down")
  selection:keypressed("return")
  Assert.equal(actions[#actions], "retry", "keyboard reaches the actionable retry")
  selection:gamepadpressed({}, "dpdown")
  selection:gamepadpressed({}, "a")
  Assert.equal(actions[#actions], "back", "controller B/Back follows the same graph")
  selection:dispose()
end

function T.receipt_is_acknowledged_only_by_the_current_attempts_visible_draw()
  local importView = {
    attemptId = "first-attempt",
    mode = "importing",
    expectedVersionId = "soulsilver",
    receipt = "private/HeartGold\\name.nds",
    statusText = "Checking ROM",
    canCancel = true,
  }
  local selection = state({
    getImportView = function()
      return importView
    end,
  })
  Assert.isNil(selection:paintedReceipt(), "a latched receipt is not paint evidence")
  selection:draw()
  Assert.equal(selection:paintedReceipt(), "first-attempt", "the renderer returns the exact drawn attempt token")
  selection:draw()
  Assert.equal(selection:paintedReceipt(), "first-attempt", "repeated paint keeps one stable receipt")

  importView = {
    attemptId = "second-attempt",
    mode = "receipt",
    expectedVersionId = "soulsilver",
    receipt = "SoulSilver.nds",
    statusText = "Waiting for readers",
    canCancel = true,
  }
  Assert.isNil(selection:paintedReceipt(), "replacing the attempt invalidates the old paint proof")
  selection:dispose()
end

function T.dual_surfaces_put_status_on_primary_and_both_cartridges_on_the_auxiliary_surface()
  local width, height = 512, 192
  local safe = { x = 0, y = 0, width = 256, height = 192 }
  local context = displayContext(width, height, 1, safe, true)
  local actions = {}
  local selection = state({
    games = editionGames({}),
    displayContext = context,
    width = width,
    height = height,
    safeRect = safe,
    onAction = function(targetId)
      actions[#actions + 1] = targetId
    end,
  })
  local view = selection:view()
  Assert.equal(#view.presentation.panes, 2)
  Assert.isFalse(view.presentation.panes[1].interactive, "the status surface is noninteractive")
  Assert.isTrue(view.presentation.panes[2].interactive, "the auxiliary surface owns both cartridges")
  Assert.notNil(view.layout.graph.targets.heartgold)
  Assert.notNil(view.layout.graph.targets.soulsilver)
  local placement = view.presentation.panes[2].placement
  local target = view.layout.graph.targets.soulsilver
  local x, y = LayoutGeometry.logicalToHost(
    placement,
    target.rect.x + target.rect.width / 2,
    target.rect.y + target.rect.height / 2
  )
  selection:touchpressed("finger", x, y)
  selection:touchreleased("finger", x, y)
  Assert.deepEqual(actions, { "soulsilver" }, "auxiliary input uses the same resolved action geometry")
  selection:dispose()
end

return { tests = T }
