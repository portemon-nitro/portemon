-- Bounded summary selection: closed pages, member navigation, protected
-- move picking and single-owned reordering over an injected facts view.
-- The controller never touches the domain; publication belongs to the
-- injected reorder command, which move_pick mode never receives.

local Assert = require("tests.support.Assert")
local SummaryController = require("libs.hgss.src.ui.SummaryController")

local T = {}

local function facts(revision, slotCount, moves)
  return {
    revision = revision,
    slotCount = slotCount,
    slot = 0,
    moves = moves or {
      { key = "TACKLE", name = "Tackle" },
      { key = "GROWL", name = "Growl" },
    },
    bodyLineEstimate = 4,
    detailLineEstimate = 2,
  }
end

local function layout()
  return {
    hitTest = function()
      return nil
    end,
  }
end

local function open(opts)
  opts = opts or {}
  local current = opts.view or facts(7, 2)
  local reorder = opts.reorderMoves
  if reorder == nil and (opts.mode or "summary") == "summary" then
    reorder = function()
      error("unexpected reorder publication", 0)
    end
  end
  return SummaryController.new({
    mode = opts.mode or "summary",
    model = {
      refresh = function(slot)
        return {
          revision = current.revision,
          slotCount = current.slotCount,
          slot = slot,
          moves = current.moves,
          bodyLineEstimate = current.bodyLineEstimate,
          detailLineEstimate = current.detailLineEstimate,
        }
      end,
    },
    request = opts.request,
    reorderMoves = reorder,
    resolveLayout = layout,
    initialSlot = opts.initialSlot,
    allowCancel = opts.allowCancel,
  })
end

local function step(controller, events)
  controller:updateFixed(events)
  return controller:status()
end

function T.cancel_on_overview_returns_the_displayed_slot()
  local controller = open({ initialSlot = 1 })
  local status = step(controller, { { type = "cancel" } })
  Assert.isFalse(status.open, "cancellation closes the summary")
  local result = assert(controller:takeResult(), "a terminal gesture reports its result")
  Assert.equal(result.kind, "return", "closing reports a return")
  Assert.equal(result.slot, 1, "party resumes on the displayed member")
end

function T.cancel_on_moves_steps_back_before_closing()
  local controller = open()
  step(controller, { { type = "navigate", direction = "down" } })
  step(controller, { { type = "navigate", direction = "down" } })
  Assert.equal(controller:status().page, "moves", "two steps reach the moves page")
  local status = step(controller, { { type = "cancel" } })
  Assert.isTrue(status.open, "cancellation on moves steps back first")
  Assert.equal(status.page, "overview", "the summary returns to overview")
  Assert.isNil(controller:takeResult(), "stepping back reports no terminal result")
  step(controller, { { type = "cancel" } })
  Assert.equal(controller:takeResult().kind, "return", "a second cancellation closes")
end

function T.member_navigation_wraps_and_resets_move_selection()
  local controller = open()
  local status = step(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(status.slot, 1, "right advances the member")
  status = step(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(status.slot, 0, "navigation wraps across members")
  status = step(controller, { { type = "navigate", direction = "left" } })
  Assert.equal(status.slot, 1, "left retreats the member")
end

function T.move_pick_returns_exact_slot_and_revision()
  local controller = open({
    mode = "move_pick",
    request = { context = "pp_restore" },
  })
  step(controller, { { type = "navigate", direction = "down" } })
  step(controller, { { type = "navigate", direction = "down" } })
  step(controller, { { type = "navigate", direction = "down" } })
  Assert.equal(controller:status().moveIndex, 1, "three steps select the second row")
  step(controller, { { type = "confirm" } })
  local result = assert(controller:takeResult(), "a terminal gesture reports its result")
  Assert.equal(result.kind, "move_selected", "choice completes the pick")
  Assert.equal(result.moveSlot, 1, "the zero-based move slot is exact")
  Assert.equal(result.partyRevision, 7, "the observed revision qualifies the pick")
  Assert.equal(result.slot, 0, "the pick carries its member")
end

function T.move_pick_never_reorders_and_forbids_member_switching()
  local rejected = pcall(SummaryController.new, {
    mode = "move_pick",
    model = {
      refresh = function()
        return facts(7, 2)
      end,
    },
    request = { context = "replace_machine", protected = {} },
    reorderMoves = function()
      return { kind = "changed" }
    end,
    resolveLayout = layout,
  })
  Assert.isFalse(rejected, "the picker refuses a reorder command by construction")
  local controller = open({
    mode = "move_pick",
    request = { context = "replace_machine", protected = {} },
  })
  step(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(controller:status().slot, 0, "the picker holds its member")
  step(controller, { { type = "navigate", direction = "down" } })
  step(controller, { { type = "navigate", direction = "down" } })
  step(controller, { { type = "confirm" } })
  step(controller, { { type = "confirm" } })
  Assert.equal(controller:takeResult().kind, "move_selected", "double confirmation still picks")
end

function T.protected_choice_is_rejected_with_an_explanation()
  local controller = open({
    mode = "move_pick",
    request = { context = "replace_machine", protected = { [2] = "hm" } },
  })
  step(controller, { { type = "navigate", direction = "down" } })
  step(controller, { { type = "navigate", direction = "down" } })
  step(controller, { { type = "navigate", direction = "down" } })
  step(controller, { { type = "confirm" } })
  Assert.isNil(controller:takeResult(), "a protected choice reports no terminal result")
  local status = controller:status()
  Assert.isTrue(status.open, "the picker stays open on rejection")
  Assert.equal(status.notice.reason, "hm", "the rejection names its protection")
  Assert.equal(status.notice.moveSlot, 1, "the rejection names the attempted row")
  step(controller, { { type = "cancel" } })
  Assert.equal(controller:takeResult().kind, "cancelled", "cancellation changes nothing")
end

function T.reorder_swaps_once_through_the_owned_command()
  local seen = {}
  local controller = open({
    reorderMoves = function(slot, a, b, revision)
      seen[#seen + 1] = { slot = slot, a = a, b = b, revision = revision }
      return { kind = "changed" }
    end,
  })
  step(controller, { { type = "navigate", direction = "down" } })
  step(controller, { { type = "navigate", direction = "down" } })
  step(controller, { { type = "confirm" } })
  Assert.equal(controller:status().reorderSource, 0, "first confirmation arms the source")
  step(controller, { { type = "navigate", direction = "down" } })
  step(controller, { { type = "confirm" } })
  Assert.equal(#seen, 1, "the swap publishes exactly once")
  Assert.equal(seen[1].a, 0, "the source row is exact")
  Assert.equal(seen[1].b, 1, "the target row is exact")
  Assert.equal(seen[1].revision, 7, "the observed revision guards the swap")
  Assert.isNil(controller:takeResult(), "reordering never closes the summary")
end

function T.same_slot_reorder_is_a_no_effect_silence()
  local controller = open({
    reorderMoves = function()
      error("same-slot gestures must not reach publication", 0)
    end,
  })
  step(controller, { { type = "navigate", direction = "down" } })
  step(controller, { { type = "navigate", direction = "down" } })
  step(controller, { { type = "confirm" } })
  step(controller, { { type = "confirm" } })
  Assert.isNil(controller:status().reorderSource, "the source disarms without publication")
  Assert.isNil(controller:takeResult(), "no terminal result follows a no-op")
end

function T.revision_drift_drops_the_pending_gesture()
  local current = facts(7, 2)
  local controller = open({
    view = current,
    reorderMoves = function()
      error("a drifted gesture must not publish", 0)
    end,
  })
  step(controller, { { type = "navigate", direction = "down" } })
  step(controller, { { type = "navigate", direction = "down" } })
  step(controller, { { type = "confirm" } })
  current.revision = 8
  step(controller, { { type = "navigate", direction = "down" } })
  Assert.isNil(controller:status().reorderSource, "drift drops the armed gesture")
  Assert.equal(controller:status().notice.reason, "stale", "drift surfaces a stale notice")
  step(controller, { { type = "confirm" } })
  Assert.isNil(controller:takeResult(), "drift reports no terminal result")
end

function T.stale_publication_refreshes_without_applying()
  local controller = open({
    reorderMoves = function()
      return { kind = "stale" }
    end,
  })
  step(controller, { { type = "navigate", direction = "down" } })
  step(controller, { { type = "navigate", direction = "down" } })
  step(controller, { { type = "confirm" } })
  step(controller, { { type = "navigate", direction = "down" } })
  step(controller, { { type = "confirm" } })
  Assert.isNil(controller:status().reorderSource, "a stale answer disarms the source")
  Assert.notNil(controller:status().notice, "a stale answer surfaces a notice")
  Assert.isNil(controller:takeResult(), "stale publication never closes")
end

return { tests = T }
