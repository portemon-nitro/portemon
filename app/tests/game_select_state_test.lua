-- Interactive library owner contracts. The state borrows process renderers and
-- the real importer status shape; only those host/collaborator boundaries are
-- scripted. Geometry and capture remain production-composed.

local Assert = require("tests.support.Assert")
local DisplayContext = require("libs.ui.src.DisplayContext")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")

local T = {}

local function games(count)
  local result = {}
  for index = 1, count do
    local gameId = string.format("game-%02d", index)
    result[#result + 1] = {
      gameId = gameId,
      versionId = gameId,
      label = string.format("Game %02d", index),
      ready = index ~= 3,
      hasSave = index % 2 == 0,
    }
  end
  return result
end

local function renderer()
  return {
    draws = 0,
    draw = function(self)
      self.draws = self.draws + 1
    end,
    drawButton = function() end,
    dispose = function() end,
  }
end

local function audio()
  return { play = function() end, fadeBoot = function() end, update = function() end, dispose = function() end }
end

local function importer(snapshot)
  return {
    status = function()
      return snapshot
    end,
    isBusy = function()
      return snapshot.state == "reading" or snapshot.state == "verifying" or snapshot.state == "registering"
    end,
  }
end

local function state(options)
  local GameSelectState = require("app.src.launcher.GameSelectState")
  options = options or {}
  options.games = options.games or games(20)
  options.initialGameId = options.initialGameId or "game-01"
  options.pickerAvailable = true
  options.renderer = options.renderer or renderer()
  options.audio = options.audio or audio()
  options.importer = options.importer or importer({ state = "idle", canCancel = false })
  options.onPick = options.onPick or function() end
  options.onPlay = options.onPlay or function() end
  options.onCancelImport = options.onCancelImport or function() end
  options.onDismissError = options.onDismissError or function() end
  options.onQuit = options.onQuit or function() end
  return GameSelectState.new(options)
end

local function hostPoint(view, logicalX, logicalY)
  local placement = assert(view.presentation.panes[1].placement, "the library publishes its input placement")
  return LayoutGeometry.logicalToHost(placement, logicalX, logicalY)
end

function T.keyboard_and_gamepad_reach_rows_and_never_play_a_disabled_game()
  local plays = {}
  local library = state({
    onPlay = function(gameId)
      plays[#plays + 1] = gameId
    end,
  })
  library:keypressed("down")
  library:keypressed("down")
  Assert.equal(library:view().focusedId, "game-03")
  library:keypressed("return")
  Assert.deepEqual(plays, {}, "a Needs ROM row cannot launch")
  library:keypressed("up")
  library:gamepadpressed({}, "a")
  Assert.deepEqual(plays, { "game-02" }, "the enabled focused row launches through the normal action")
  library:dispose()
end

function T.row_drag_scrolls_and_press_rotate_release_activates_nothing()
  local plays = {}
  local library = state({
    onPlay = function(gameId)
      plays[#plays + 1] = gameId
    end,
  })
  library:resize(390, 844)
  local view = library:view()
  local row = assert(view.layout.list.rows["game-01"])
  local x, y = hostPoint(view, row.x + row.width / 2, row.y + row.height / 2)
  library:mousepressed(x, y, 1)
  library:mousemoved(x, y + 12, 12, false)
  library:mousereleased(x, y + 12, 1)
  Assert.deepEqual(plays, {}, "a vertical drag cancels row activation")
  Assert.isTrue(library:view().scroll.offset > 0, "the same gesture scrolls the list")

  view = library:view()
  local play = assert(view.layout.actions.play)
  x, y = hostPoint(view, play.x + play.width / 2, play.y + play.height / 2)
  library:mousepressed(x, y, 1)
  library:resize(844, 390)
  library:mousereleased(x, y, 1)
  Assert.deepEqual(plays, {}, "rotation cancels a held action before release")
  library:dispose()
end

function T.import_error_modal_has_precedence_and_dismissal_returns_the_focused_game()
  local Errors = require("libs.errors.src.Errors")
  local supplied = Errors.new("ROM_SOURCE_REQUIRED", "the managed source needs repair")
  local dismissed = {}
  local library = state({
    initialGameId = "game-04",
    failure = supplied,
    importer = importer({ state = "error", errorCode = "IMPORT_NOT_NDS", error = "older importer failure" }),
    onDismissError = function(focusedId)
      dismissed[#dismissed + 1] = focusedId
    end,
  })
  local view = library:view()
  Assert.equal(view.failure, supplied, "an explicit source failure takes precedence over terminal importer status")
  Assert.notNil(view.layout.modal, "the failure uses the one compact modal surface")
  local row = assert(view.layout.list.rows["game-04"])
  local x, y = hostPoint(view, row.x + row.width / 2, row.y + row.height / 2)
  library:mousepressed(x, y, 1)
  library:mousereleased(x, y, 1)
  Assert.equal(view.focusedId, "game-04", "the backdrop cannot change selection through the modal")
  library:keypressed("escape")
  Assert.deepEqual(dismissed, { "game-04" }, "dismissal hands the current semantic focus back to App")
  library:dispose()
end

function T.error_modal_keeps_back_and_pick_in_the_focus_graph()
  local Errors = require("libs.errors.src.Errors")
  local picks, dismissals = {}, {}
  local library = state({
    initialGameId = "game-02",
    failure = Errors.new("ROM_SOURCE_REQUIRED", "the managed source needs repair"),
    onPick = function()
      picks[#picks + 1] = true
    end,
    onDismissError = function(focusedId)
      dismissals[#dismissals + 1] = focusedId
    end,
  })
  local initial = library:view()
  Assert.equal(initial.action, "back", "the modal publishes its initial Back focus")
  Assert.notNil(initial.layout.graph.targets.back, "Back is a semantic modal focus target")
  Assert.notNil(initial.layout.graph.targets.pick, "Pick another is a semantic modal focus target")
  library:gamepadpressed({}, "dpdown")
  Assert.equal(library:view().action, "pick", "directional gamepad input reaches Pick another")
  Assert.equal(library.selectedGameId, "game-02", "modal focus never changes the underlying selection")
  library:gamepadpressed({}, "a")
  Assert.deepEqual(picks, { true }, "A activates the focused Pick another action")

  library:gamepadpressed({}, "dpdown")
  Assert.equal(library:view().action, "back", "the modal can return focus to Back")
  local modal = assert(library:view().layout.modal)
  local x, y = hostPoint(library:view(), modal.pick.x + modal.pick.width / 2, modal.pick.y + modal.pick.height / 2)
  library:touchpressed("finger", x, y)
  library:touchreleased("finger", x, y)
  Assert.deepEqual(picks, { true, true }, "touch activates the same focused Pick another geometry")
  Assert.equal(library:view().action, "pick", "pointer activation publishes the modal focus")
  library:gamepadpressed({}, "b")
  Assert.deepEqual(dismissals, { "game-02" }, "B retains the modal's Back action")
  library:dispose()
end

function T.dual_surfaces_keep_summary_noninteractive_and_actions_on_the_auxiliary_surface()
  local width, height = 512, 192
  local context = DisplayContext.new({
    graphics = {
      getDimensions = function()
        return width, height
      end,
      getDPIScale = function()
        return 1
      end,
    },
    topologyProvider = function()
      return {
        surfaces = {
          {
            id = "main",
            role = "world",
            rect = { x = 0, y = 0, width = 256, height = 192 },
            touch = true,
          },
          {
            id = "aux",
            role = "auxiliary",
            rect = { x = 256, y = 0, width = 256, height = 192 },
            touch = true,
          },
        },
      }
    end,
  })
  local plays = {}
  local library = state({
    games = games(2),
    displayContext = context,
    width = width,
    height = height,
    onPlay = function(gameId)
      plays[#plays + 1] = gameId
    end,
  })
  local view = library:view()
  Assert.equal(#view.presentation.panes, 2, "physical dual surfaces resolve two panes")
  Assert.isFalse(view.presentation.panes[1].interactive, "the primary summary pane is noninteractive")
  Assert.isTrue(view.presentation.panes[2].interactive, "the auxiliary library pane owns input")
  local placement = view.presentation.panes[2].placement
  local play = assert(view.layout.actions.play)
  local x, y = LayoutGeometry.logicalToHost(placement, play.x + play.width / 2, play.y + play.height / 2)
  library:touchpressed("finger", x, y)
  library:touchreleased("finger", x, y)
  Assert.deepEqual(plays, { "game-01" }, "auxiliary actions use the same resolved geometry as drawing")
  library:dispose()
end

function T.cancellable_import_exposes_one_focusable_touch_cancel_action()
  local cancels, quits = 0, 0
  local library = state({
    importer = importer({ state = "verifying", progress = 0.6, canCancel = true }),
    onCancelImport = function()
      cancels = cancels + 1
    end,
    onQuit = function()
      quits = quits + 1
    end,
  })
  library:markReceived("heartgold.nds")
  local view = library:view()
  local cancel = assert(view.layout.cancelRect, "cancellable import status resolves a Cancel target")
  Assert.equal(cancel.height, 44, "Cancel keeps the ordinary touch target height")
  Assert.isTrue(
    view.layout.list.viewport.y >= view.layout.statusRect.y + view.layout.statusRect.height,
    "the Cancel row reserves its space before the scrollable list"
  )
  Assert.notNil(view.layout.graph.targets.cancel, "Cancel belongs to the semantic focus graph")
  Assert.equal(view.action, nil, "opening import status does not steal game focus")
  library:keypressed("up")
  Assert.equal(library:view().action, "cancel", "keyboard focus reaches the Cancel action")
  library:gamepadpressed({}, "a")
  Assert.equal(cancels, 1, "gamepad activation uses the existing import cancellation callback")

  view = library:view()
  cancel = assert(view.layout.cancelRect)
  local x, y = hostPoint(view, cancel.x + cancel.width / 2, cancel.y + cancel.height / 2)
  library:touchpressed("finger", x, y)
  library:touchreleased("finger", x, y)
  Assert.equal(cancels, 2, "touch release inside Cancel uses the same callback")
  library:touchpressed("drag", x, y)
  library:touchmoved("drag", x, y - 60)
  library:touchreleased("drag", x, y - 60)
  Assert.equal(cancels, 2, "press-drag-away does not cancel")
  Assert.equal(quits, 0, "Cancel never falls through to ordinary quit")
  library:dispose()
end

function T.receipt_and_busy_import_keep_one_progress_session()
  local picks, cancels = 0, 0
  local running = importer({ state = "verifying", progress = 0.6, canCancel = true })
  local library = state({
    importer = running,
    onPick = function()
      picks = picks + 1
    end,
    onCancelImport = function()
      cancels = cancels + 1
    end,
  })
  library:markReceived("soulsilver.nds")
  Assert.equal(library:receivedName(), "soulsilver.nds")
  Assert.isNil(library:paintedReceipt(), "latching a receipt is not proof that it was drawn")
  library:draw()
  Assert.equal(library:paintedReceipt(), "soulsilver.nds", "the first draw acknowledges the file before work")
  library:keypressed("return")
  Assert.equal(picks, 0, "a busy importer cannot open a second picker")
  library:keypressed("return")
  Assert.equal(picks, 0, "a repeated activation cannot replace the running session")
  Assert.equal(library:receivedName(), "soulsilver.nds", "a duplicate does not reset the first receipt")
  library:keypressed("escape")
  Assert.equal(cancels, 1, "cancellable status owns the single cancel action")
  library:dispose()
end

return { tests = T }
