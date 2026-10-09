-- Bounded summary selection: closed pages, member navigation, protected
-- move picking and single-owned reordering over an injected facts view.
-- The controller never touches the domain; publication belongs to the
-- injected reorder command, which move_pick mode never receives.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local SummaryController = require("libs.hgss.src.ui.SummaryController")
local SummaryModel = require("libs.hgss.src.ui.SummaryModel")
local SummaryPresentationFixture = require("tests.support.SummaryPresentationFixture")

local T = {}

-- Native paired-group behavior below: Left/Right walk info, skills and
-- performance with wrap, Up/Down scan members without wrapping, eggs gate
-- group changes while staying reachable from info, detail and ribbon
-- phases isolate their input, reorder publishes whole entries once
-- through the injected command, pickers never publish, and picture epochs
-- with one-shot effects stay off the draw path. Facts here are read-only
-- snapshot values shaped like the model projection; the controller must
-- never mutate them, and the tests never reference retired page names.

local OPEN_GATES = { interactive = true, playback = true }
local CLOSED_GATES = { interactive = false, playback = false }

local function nativeMoves()
  return {
    { kind = "move", moveSlot = 0, key = "TACKLE", name = "Tackle", pp = 10, ppUps = 1 },
    { kind = "move", moveSlot = 1, key = "GROWL", name = "Growl", pp = 40, ppUps = 0 },
    { kind = "move", moveSlot = 2, key = "RAZOR_LEAF", name = "Razor Leaf", pp = 25, ppUps = 2 },
    { kind = "move", moveSlot = 3, key = "SYNTHESIS", name = "Synthesis", pp = 5, ppUps = 3 },
  }
end

local function nativeState(overrides)
  local state = {
    revision = 7,
    roster = { { isEgg = false }, { isEgg = false } },
    ribbons = {},
    contextKey = "day13|regional",
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      state[key] = value
    end
  end
  return state
end

local function nativeModel(state)
  return {
    refresh = function(slot)
      local spec = state.roster[slot + 1]
      assert(spec ~= nil, "refresh needs an occupied party slot")
      local moves = nil
      if state.movesBySlot ~= nil then
        moves = state.movesBySlot[slot + 1]
      end
      if moves == nil then
        moves = nativeMoves()
      end
      local roster = {}
      for index, member in ipairs(state.roster) do
        roster[index] = { slot = index - 1, isEgg = member.isEgg == true }
      end
      return {
        revision = state.revision,
        slot = slot,
        slotCount = #state.roster,
        roster = roster,
        isEgg = spec.isEgg == true,
        moves = moves,
        ribbons = state.ribbons or {},
        performance = state.performance,
        contextKey = state.contextKey or "day13|regional",
        pictureKey = spec.isEgg == true and "EGG" or "CHIKORITA",
        identity = { species = spec.isEgg == true and "EGG" or "CHIKORITA", personality = 4242 },
      }
    end,
  }
end

local function nativeOpen(opts)
  opts = opts or {}
  local state = opts.state or nativeState()
  local manifest = opts.manifest or SummaryPresentationFixture.manifest()
  local hitTest = opts.hitTest or function()
    return nil
  end
  local reorder = opts.reorderMoves
  if reorder == nil and (opts.mode or "summary") == "summary" then
    reorder = function()
      error("unexpected reorder publication", 0)
    end
  end
  local controllerOpts = {
    mode = opts.mode or "summary",
    model = opts.model or nativeModel(state),
    request = opts.request,
    reorderMoves = reorder,
    resolveLayout = function()
      return { hitTest = hitTest }
    end,
    manifest = manifest,
    allowReorder = opts.allowReorder,
    initialSlot = opts.initialSlot,
    allowCancel = opts.allowCancel,
    showMemberCursor = opts.showMemberCursor,
  }
  if opts.readNavigation ~= nil then
    controllerOpts.readNavigation = opts.readNavigation
  end
  if controllerOpts.allowReorder == nil then
    controllerOpts.allowReorder = true
  end
  return SummaryController.new(controllerOpts), state
end

local function nativeStep(controller, events, gates)
  controller:updateFixed(events or {}, gates or OPEN_GATES)
  return controller:status()
end

local function drain(controller)
  Assert.notNil(controller.takeEffects, "the controller drains one-shot semantic effects")
  local effects = controller:takeEffects()
  assert(type(effects) == "table", "drained effects arrive as an array")
  return effects
end

local function settlePhase(controller, phase, gates)
  local status = controller:status()
  for _ = 1, 120 do
    if status.phase == phase then
      return status
    end
    controller:updateFixed({}, gates or OPEN_GATES)
    status = controller:status()
  end
  Assert.equal(status.phase, phase, "the transition settles into its detail phase")
  return status
end

local function navCell()
  local cell = { sample = nil }
  local function read()
    return cell.sample
  end
  return cell, read
end

local function fixedHitboxes(targets)
  return function(x, y)
    for _, entry in ipairs(targets) do
      if x >= entry.x0 and x < entry.x1 and y >= entry.y0 and y < entry.y1 then
        return entry.target
      end
    end
    return nil
  end
end

local function earnedRibbons(count)
  local out = {}
  for index = 1, count do
    out[index] = { key = "ribbon_" .. index, name = "Ribbon " .. index, description = "Description " .. index }
  end
  return out
end

local function openPerformanceDetail(ribbonCount)
  local controller = nativeOpen({ state = nativeState({ ribbons = earnedRibbons(ribbonCount) }) })
  nativeStep(controller, {})
  nativeStep(controller, { { type = "navigate", direction = "right" } })
  nativeStep(controller, { { type = "navigate", direction = "right" } })
  nativeStep(controller, { { type = "confirm" } })
  return controller
end

local function liveService(catalog, seed)
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  return HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(seed):capture()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  })
end

local function giftSpecies(service, species, level)
  local added = service:giveMon({
    species = species,
    level = level or 5,
    heldItem = "NONE",
    form = 0,
    location = 7,
    date = CatalogFixture.metDate(),
  })
  Assert.isTrue(added, "setup gift must enter the party")
end

local function editPartyMon(service, slot, edit)
  local revision = service:partyRevision()
  local copy = service:partyMon(slot)
  edit(copy)
  local preparation, reason = service:preparePartyChanges(revision, { { slot = slot, mon = copy } })
  Assert.isNil(reason, "setup edit must prepare cleanly")
  Assert.notNil(preparation, "setup edit must produce a preparation")
  Assert.isTrue(preparation.isCurrent(), "setup edit must stay current")
  preparation.publish()
end

local function distinctMoves()
  return {
    { move = "TACKLE", pp = 10, ppUps = 1 },
    { move = "GROWL", pp = 40, ppUps = 0 },
    { move = "RAZOR_LEAF", pp = 25, ppUps = 2 },
    { move = "SYNTHESIS", pp = 5, ppUps = 3 },
  }
end

local function serviceModel(service, context, manifest)
  return {
    refresh = function(slot)
      return SummaryModel.build(service, slot, context, manifest)
    end,
  }
end

function T.directional_input_walks_groups_and_scans_members_without_wrap()
  local controller = nativeOpen({ state = nativeState({ roster = { {}, {}, {} } }) })
  local status = nativeStep(controller, {})
  Assert.equal(status.group, "info", "ordinary browsing starts on the info group")
  Assert.equal(status.slot, 0, "browsing starts on the requested member")
  status = nativeStep(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(status.group, "skills", "right steps into skills")
  status = nativeStep(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(status.group, "performance", "right steps into performance")
  status = nativeStep(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(status.group, "info", "groups wrap forward")
  status = nativeStep(controller, { { type = "navigate", direction = "left" } })
  Assert.equal(status.group, "performance", "groups wrap backward")
  status = nativeStep(controller, { { type = "navigate", direction = "down" } })
  Assert.equal(status.slot, 1, "down scans forward")
  Assert.equal(status.group, "performance", "member scans keep the group")
  status = nativeStep(controller, { { type = "navigate", direction = "down" } })
  Assert.equal(status.slot, 2, "down reaches the end")
  status = nativeStep(controller, { { type = "navigate", direction = "down" } })
  Assert.equal(status.slot, 2, "member scans stop at the end instead of wrapping")
  status = nativeStep(controller, { { type = "navigate", direction = "up" } })
  Assert.equal(status.slot, 1, "up scans back")
  status = nativeStep(controller, { { type = "navigate", direction = "up" } })
  status = nativeStep(controller, { { type = "navigate", direction = "up" } })
  Assert.equal(status.slot, 0, "member scans stop at the start instead of wrapping")
end

function T.single_batches_resolve_one_branch_in_source_priority()
  local controller = nativeOpen({ state = nativeState({ roster = { {}, {}, {} } }) })
  nativeStep(controller, {})
  local status = nativeStep(controller, {
    { type = "navigate", direction = "right" },
    { type = "navigate", direction = "right" },
  })
  Assert.equal(status.group, "skills", "one tick resolves one group step")
  Assert.equal(status.slot, 0, "the discarded edge moves no member")
  status = nativeStep(controller, {
    { type = "navigate", direction = "down" },
    { type = "navigate", direction = "right" },
  })
  Assert.equal(status.group, "performance", "right outranks down in one batch")
  Assert.equal(status.slot, 0, "the lower-priority scan is discarded")
  status = nativeStep(controller, {
    { type = "navigate", direction = "left" },
    { type = "navigate", direction = "right" },
  })
  Assert.equal(status.group, "skills", "left outranks right in one batch")
end

function T.egg_members_gate_group_changes_but_stay_reachable_from_info()
  local controller, _ = nativeOpen({
    state = nativeState({ roster = { { isEgg = false }, { isEgg = true }, { isEgg = false } } }),
  })
  nativeStep(controller, {})
  nativeStep(controller, { { type = "navigate", direction = "down" } })
  Assert.equal(controller:status().slot, 1, "eggs stay eligible on info")
  local status = nativeStep(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(status.group, "info", "group changes stay disabled with an egg selected")
  Assert.equal(status.slot, 1, "the gated group change moves no member")
  status = nativeStep(controller, { { type = "navigate", direction = "left" } })
  Assert.equal(status.group, "info", "both group directions stay disabled with an egg selected")
  status = nativeStep(controller, { { type = "navigate", direction = "down" } })
  Assert.equal(status.slot, 2, "info still reaches past the egg")
  status = nativeStep(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(status.group, "skills", "group changes resume past the egg")
  status = nativeStep(controller, { { type = "navigate", direction = "down" } })
  Assert.equal(status.slot, 2, "skills stop at the last eligible member")
  status = nativeStep(controller, { { type = "navigate", direction = "up" } })
  Assert.equal(status.slot, 0, "skills skip the egg while scanning")
  local lone = nativeOpen({
    state = nativeState({ roster = { { isEgg = true }, { isEgg = true }, { isEgg = false } } }),
    initialSlot = 2,
  })
  nativeStep(lone, {})
  nativeStep(lone, { { type = "navigate", direction = "right" } })
  Assert.equal(lone:status().group, "skills", "group changes work with a hatched selection")
  local loneStatus = nativeStep(lone, { { type = "navigate", direction = "down" } })
  Assert.equal(loneStatus.slot, 2, "a lone eligible member stays selected")
  loneStatus = nativeStep(lone, { { type = "navigate", direction = "up" } })
  Assert.equal(loneStatus.slot, 2, "a lone eligible member stays selected upward too")
end

function T.hidden_performance_keeps_its_group_without_rows()
  local controller = nativeOpen({ state = nativeState({ performance = nil }) })
  nativeStep(controller, {})
  nativeStep(controller, { { type = "navigate", direction = "right" } })
  local status = nativeStep(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(status.group, "performance", "hidden performance keeps its group")
  Assert.isNil(status.facts.performance, "hidden performance exposes no rows")
  Assert.notNil(status.facts.ribbons, "hidden performance keeps its ribbons")
end

function T.fresh_presses_act_once_while_holds_repeat_on_the_source_cadence()
  local cell, read = navCell()
  local controller = nativeOpen({ state = nativeState({ roster = { {}, {} } }), readNavigation = read })
  nativeStep(controller, {})
  cell.sample = { tick = 0, active = true, pressedDirection = "right", heldDirection = "right" }
  local status = nativeStep(controller, {})
  Assert.equal(status.group, "skills", "a fresh press acts once")
  cell.sample = { tick = 1, active = true }
  status = nativeStep(controller, {})
  status = nativeStep(controller, {})
  Assert.equal(status.group, "skills", "release ends the gesture without repeats")
  cell.sample = { tick = 10, active = true, heldDirection = "right" }
  for tick = 10, 17 do
    cell.sample.tick = tick
    status = nativeStep(controller, {})
  end
  Assert.equal(status.group, "skills", "held input waits out the start delay")
  cell.sample.tick = 18
  status = nativeStep(controller, {})
  Assert.equal(status.group, "performance", "held input repeats after eight ticks")
  for tick = 19, 21 do
    cell.sample.tick = tick
    status = nativeStep(controller, {})
  end
  Assert.equal(status.group, "performance", "repeats hold their four-tick interval")
  cell.sample.tick = 22
  status = nativeStep(controller, {})
  Assert.equal(status.group, "info", "repeats keep wrapping groups")
end

function T.repeat_state_resets_on_release_direction_change_and_duplicate_ticks()
  local cell, read = navCell()
  local controller = nativeOpen({ state = nativeState({ roster = { {}, {} } }), readNavigation = read })
  nativeStep(controller, {})
  cell.sample = { tick = 0, active = true, heldDirection = "right" }
  local status = nil
  for tick = 0, 8 do
    cell.sample.tick = tick
    status = nativeStep(controller, {})
  end
  Assert.equal(status.group, "skills", "a held direction fires after the start delay")
  cell.sample = { tick = 8, active = true, heldDirection = "right" }
  status = nativeStep(controller, {})
  Assert.equal(status.group, "skills", "a duplicate tick never replays its edge")
  cell.sample = { tick = 9, active = true }
  status = nativeStep(controller, {})
  Assert.equal(status.group, "skills", "release holds the group")
  cell.sample = { tick = 10, active = true, pressedDirection = "right", heldDirection = "right" }
  status = nativeStep(controller, {})
  Assert.equal(status.group, "performance", "a fresh press after release acts at once")
  cell.sample = { tick = 11, active = true, heldDirection = "left" }
  for tick = 11, 17 do
    cell.sample.tick = tick
    status = nativeStep(controller, {})
  end
  Assert.equal(status.group, "performance", "an opposite hold restarts the delay")
  cell.sample.tick = 18
  status = nativeStep(controller, {})
  Assert.equal(status.group, "skills", "the restarted hold fires leftward after eight ticks")
end

function T.detail_phases_answer_only_fresh_presses()
  local cell, read = navCell()
  local controller = nativeOpen({ state = nativeState(), readNavigation = read })
  nativeStep(controller, {})
  cell.sample = { tick = 0, active = true, pressedDirection = "right", heldDirection = "right" }
  nativeStep(controller, {})
  cell.sample = nil
  nativeStep(controller, { { type = "confirm" } })
  local status = settlePhase(controller, "move_detail")
  Assert.equal(status.moveSlot, 0, "confirmation opens the first existing row")
  cell.sample = { tick = 1, active = true, heldDirection = "down" }
  for tick = 1, 12 do
    cell.sample.tick = tick
    status = nativeStep(controller, {})
  end
  Assert.equal(status.moveSlot, 0, "detail ignores held repeats")
  cell.sample = { tick = 13, active = true, pressedDirection = "down", heldDirection = "down" }
  status = nativeStep(controller, {})
  Assert.equal(status.moveSlot, 1, "detail answers a fresh press")
end

function T.empty_group_configurations_fail_instead_of_looping()
  local manifest = SummaryPresentationFixture.manifest()
  manifest.groups = {}
  local ok, _ = pcall(function()
    local controller = nativeOpen({ manifest = manifest })
    nativeStep(controller, {})
    nativeStep(controller, { { type = "navigate", direction = "right" } })
  end)
  Assert.isFalse(ok, "a zero-enabled-group configuration fails instead of looping")
end

function T.pointer_down_activates_exactly_once_without_up_duplication()
  local hitTest = fixedHitboxes({
    { x0 = 0, x1 = 64, y0 = 0, y1 = 32, target = { kind = "move", index = 1 } },
  })
  local controller = nativeOpen({ hitTest = hitTest })
  nativeStep(controller, {})
  nativeStep(controller, { { type = "navigate", direction = "right" } })
  local status = nativeStep(controller, { { type = "pointer_down", pointerId = "touch:1", x = 10, y = 10 } })
  Assert.equal(status.phase, "move_opening", "touch activates on down")
  status = settlePhase(controller, "move_detail")
  Assert.equal(status.moveSlot, 1, "touch selects the touched row")
  status = nativeStep(controller, { { type = "pointer_up", pointerId = "touch:1", x = 10, y = 10 } })
  Assert.equal(status.phase, "move_detail", "release duplicates nothing")
  Assert.equal(status.moveSlot, 1, "release keeps the touched row")
  Assert.isNil(status.reorderSource, "release never synthesizes a second confirmation")
  Assert.isNil(controller:takeResult(), "touch plus release completes nothing")
  status = nativeStep(controller, { { type = "pointer_up", pointerId = "touch:1", x = 10, y = 10 } })
  Assert.equal(status.phase, "move_detail", "a stray release stays inert")
end

function T.pointer_edges_honor_half_open_hit_areas()
  local boxes = { { x0 = 10, x1 = 20, y0 = 10, y1 = 20, target = { kind = "move", index = 0 } } }
  local function probeDown(x, y)
    local controller = nativeOpen({ hitTest = fixedHitboxes(boxes) })
    nativeStep(controller, {})
    nativeStep(controller, { { type = "navigate", direction = "right" } })
    return nativeStep(controller, { { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  end
  Assert.equal(probeDown(10, 15).phase, "move_opening", "the low edge activates")
  Assert.equal(probeDown(19, 15).phase, "move_opening", "the cell before the high edge activates")
  Assert.equal(probeDown(9, 15).phase, "root", "just outside the low edge stays inert")
  Assert.equal(probeDown(20, 15).phase, "root", "the high edge stays exclusive")
  Assert.equal(probeDown(15, 9).phase, "root", "just above the band stays inert")
  Assert.equal(probeDown(15, 20).phase, "root", "the bottom edge stays exclusive")
end

function T.group_touches_follow_native_tabs()
  local hitTest = fixedHitboxes({
    { x0 = 0, x1 = 32, y0 = 160, y1 = 192, target = { kind = "group", group = "info" } },
    { x0 = 32, x1 = 64, y0 = 160, y1 = 192, target = { kind = "group", group = "skills" } },
    { x0 = 64, x1 = 96, y0 = 160, y1 = 192, target = { kind = "group", group = "performance" } },
  })
  local controller = nativeOpen({ hitTest = hitTest })
  nativeStep(controller, {})
  local status = nativeStep(controller, { { type = "pointer_down", pointerId = "touch:1", x = 48, y = 170 } })
  Assert.equal(status.group, "skills", "touch selects the touched group")
  status = nativeStep(controller, { { type = "pointer_up", pointerId = "touch:1", x = 48, y = 170 } })
  Assert.equal(status.group, "skills", "release keeps the touched group")
  status = nativeStep(controller, { { type = "pointer_down", pointerId = "touch:1", x = 48, y = 170 } })
  Assert.equal(status.group, "skills", "reselecting the active tab changes nothing")
  Assert.isNil(controller:takeResult(), "tab touches complete nothing")
end

function T.member_touches_select_the_touched_eligible_member()
  local hitTest = fixedHitboxes({
    { x0 = 0, x1 = 32, y0 = 0, y1 = 32, target = { kind = "member", slot = 2, direction = 1 } },
  })
  local controller = nativeOpen({ state = nativeState({ roster = { {}, {}, {} } }), hitTest = hitTest })
  nativeStep(controller, {})
  local status = nativeStep(controller, { { type = "pointer_down", pointerId = "touch:1", x = 10, y = 10 } })
  Assert.equal(status.slot, 2, "touch selects the touched member directly")
  status = nativeStep(controller, { { type = "pointer_up", pointerId = "touch:1", x = 10, y = 10 } })
  Assert.equal(status.slot, 2, "release keeps the touched member")
end

function T.touches_outside_targets_and_on_the_main_pane_stay_inert()
  local controller = nativeOpen({})
  nativeStep(controller, {})
  local status = nativeStep(controller, { { type = "pointer_down", pointerId = "touch:1", x = 200, y = 100 } })
  Assert.equal(status.group, "info", "an untargeted press changes no group")
  Assert.equal(status.slot, 0, "an untargeted press changes no member")
  status = nativeStep(controller, { { type = "pointer_up", pointerId = "touch:1", x = 10, y = 10 } })
  Assert.equal(status.group, "info", "a release without a press activates nothing")
  Assert.isNil(controller:takeResult(), "inert touches complete nothing")
end

function T.ribbon_detail_opens_only_with_earned_ribbons_and_cancel_returns_to_the_group()
  local empty = nativeOpen({ state = nativeState({ ribbons = {} }) })
  nativeStep(empty, {})
  nativeStep(empty, { { type = "navigate", direction = "right" } })
  nativeStep(empty, { { type = "navigate", direction = "right" } })
  local status = nativeStep(empty, { { type = "confirm" } })
  Assert.equal(status.group, "performance", "an empty ribbon list holds its group")
  Assert.equal(status.phase, "root", "an empty ribbon list opens no detail")
  Assert.isNil(empty:takeResult(), "an empty ribbon list completes nothing")
  local controller = openPerformanceDetail(10)
  status = settlePhase(controller, "ribbon_detail")
  Assert.equal(status.ribbonIndex, 0, "the ribbon pane starts on the first earned ribbon")
  Assert.equal(status.ribbonPage, 0, "the ribbon pane starts on the first page")
  status = nativeStep(controller, { { type = "cancel" } })
  Assert.equal(status.phase, "ribbon_closing", "ribbon cancellation stages its reverse motion")
  status = settlePhase(controller, "root")
  Assert.equal(status.group, "performance", "ribbon cancellation keeps the ribbons group")
  Assert.isTrue(status.open, "ribbon cancellation never exits the summary")
  Assert.isNil(controller:takeResult(), "ribbon cancellation completes nothing")
end

function T.ribbon_cursor_walks_every_earned_ribbon_without_absent_stops()
  local controller = openPerformanceDetail(10)
  settlePhase(controller, "ribbon_detail")
  local seen = {}
  local order = { "right", "down", "left", "up" }
  for _ = 1, 12 do
    for _, direction in ipairs(order) do
      for _ = 1, 9 do
        local status = nativeStep(controller, { { type = "navigate", direction = direction } })
        local index = status.ribbonIndex
        Assert.isTrue(type(index) == "number" and index >= 0 and index < 10, "the cursor rests only on earned ribbons")
        Assert.equal(status.ribbonPage, math.floor(index / 9), "pages track the logical index")
        Assert.notNil(status.facts.ribbons[index + 1], "every cursor stop resolves its earned record")
        seen[index] = true
      end
    end
  end
  for index = 0, 9 do
    Assert.isTrue(seen[index] == true, "earned ribbon " .. index .. " stays reachable")
  end
end

function T.ribbon_boundaries_hold_from_zero_to_a_full_census()
  local solo = openPerformanceDetail(1)
  local status = settlePhase(solo, "ribbon_detail")
  Assert.equal(status.ribbonIndex, 0, "a lone ribbon starts selected")
  for _, direction in ipairs({ "right", "down", "left", "up" }) do
    for _ = 1, 4 do
      status = nativeStep(solo, { { type = "navigate", direction = direction } })
      Assert.equal(status.ribbonIndex, 0, "a lone ribbon never loses its cursor")
      Assert.equal(status.ribbonPage, 0, "a lone ribbon never turns its page")
    end
  end
  local full = openPerformanceDetail(80)
  settlePhase(full, "ribbon_detail")
  for _, direction in ipairs({ "right", "down", "left", "up" }) do
    for _ = 1, 10 do
      status = nativeStep(full, { { type = "navigate", direction = direction } })
      local index = status.ribbonIndex
      Assert.isTrue(type(index) == "number" and index >= 0 and index < 80, "a full census never strands its cursor")
      Assert.equal(status.ribbonPage, math.floor(index / 9), "census pages track the logical index")
    end
  end
end

function T.ribbon_touches_open_the_touched_cell_while_blanks_stay_inert()
  local hitTest = fixedHitboxes({
    { x0 = 64, x1 = 96, y0 = 64, y1 = 96, target = { kind = "ribbon", index = 5 } },
  })
  local controller = nativeOpen({ state = nativeState({ ribbons = earnedRibbons(9) }), hitTest = hitTest })
  nativeStep(controller, {})
  nativeStep(controller, { { type = "navigate", direction = "right" } })
  nativeStep(controller, { { type = "navigate", direction = "right" } })
  local status = nativeStep(controller, { { type = "pointer_down", pointerId = "touch:1", x = 200, y = 150 } })
  Assert.equal(status.phase, "root", "blank grid cells stay ineligible")
  status = nativeStep(controller, { { type = "pointer_up", pointerId = "touch:1", x = 200, y = 150 } })
  Assert.equal(status.phase, "root", "blank releases activate nothing")
  status = nativeStep(controller, { { type = "pointer_down", pointerId = "touch:1", x = 70, y = 70 } })
  Assert.equal(status.phase, "ribbon_opening", "ribbon touch opens its pane")
  status = settlePhase(controller, "ribbon_detail")
  Assert.equal(status.ribbonIndex, 5, "ribbon touch selects the touched cell")
end

function T.move_detail_opens_on_the_first_existing_row_without_publishing()
  local moves = {
    { kind = "empty", moveSlot = 0 },
    { kind = "move", moveSlot = 1, key = "GROWL", name = "Growl", pp = 40, ppUps = 0 },
    { kind = "move", moveSlot = 2, key = "RAZOR_LEAF", name = "Razor Leaf", pp = 25, ppUps = 2 },
    { kind = "empty", moveSlot = 3 },
  }
  local controller = nativeOpen({ state = nativeState({ movesBySlot = { moves } }) })
  nativeStep(controller, {})
  nativeStep(controller, { { type = "navigate", direction = "right" } })
  local status = nativeStep(controller, { { type = "confirm" } })
  Assert.equal(status.phase, "move_opening", "confirmation opens the move pane")
  status = nativeStep(controller, { { type = "confirm" } })
  Assert.isTrue(
    status.phase == "move_opening" or status.phase == "move_detail",
    "transition edges never double as detail input"
  )
  status = settlePhase(controller, "move_detail")
  Assert.equal(status.moveSlot, 1, "detail selects the first existing row")
  Assert.isNil(status.reorderSource, "opening detail arms nothing")
  Assert.isNil(controller:takeResult(), "opening detail completes nothing")
end

function T.detail_navigation_wraps_over_occupied_rows_and_holds_members()
  local moves = {
    { kind = "move", moveSlot = 0, key = "TACKLE", name = "Tackle", pp = 10, ppUps = 1 },
    { kind = "empty", moveSlot = 1 },
    { kind = "move", moveSlot = 2, key = "RAZOR_LEAF", name = "Razor Leaf", pp = 25, ppUps = 2 },
    { kind = "move", moveSlot = 3, key = "SYNTHESIS", name = "Synthesis", pp = 5, ppUps = 3 },
  }
  local controller = nativeOpen({ state = nativeState({ movesBySlot = { moves } }) })
  nativeStep(controller, {})
  nativeStep(controller, { { type = "navigate", direction = "right" } })
  nativeStep(controller, { { type = "confirm" } })
  settlePhase(controller, "move_detail")
  local status = nativeStep(controller, { { type = "navigate", direction = "down" } })
  Assert.equal(status.moveSlot, 2, "detail skips empty rows forward")
  status = nativeStep(controller, { { type = "navigate", direction = "down" } })
  Assert.equal(status.moveSlot, 3, "detail follows source order")
  status = nativeStep(controller, { { type = "navigate", direction = "down" } })
  Assert.equal(status.moveSlot, 0, "detail wraps over occupied rows")
  status = nativeStep(controller, { { type = "navigate", direction = "up" } })
  Assert.equal(status.moveSlot, 3, "detail wraps backward over occupied rows")
  status = nativeStep(controller, { { type = "navigate", direction = "left" } })
  Assert.equal(status.moveSlot, 3, "lateral input never leaves the detail row")
  Assert.equal(status.slot, 0, "lateral input never changes members behind detail")
  status = nativeStep(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(status.moveSlot, 3, "both lateral directions hold the detail row")
  Assert.equal(status.slot, 0, "both lateral directions hold the member")
end

function T.distinct_slot_gestures_swap_whole_entries_exactly_once()
  local catalog = CatalogFixture.makeCatalog()
  local service = liveService(catalog, 0x30303030)
  giftSpecies(service, "CHIKORITA", 5)
  giftSpecies(service, "TOTODILE", 5)
  editPartyMon(service, 0, function(copy)
    copy.moves = distinctMoves()
  end)
  local manifest = SummaryPresentationFixture.manifest()
  local context = SummaryPresentationFixture.context(2)
  local before = service:capture()
  local revision = service:partyRevision()
  local calls = {}
  local controller, _ = nativeOpen({
    model = serviceModel(service, context, manifest),
    manifest = manifest,
    reorderMoves = function(slot, a, b, expectedRevision)
      calls[#calls + 1] = { slot = slot, a = a, b = b, revision = expectedRevision }
      if expectedRevision ~= service:partyRevision() then
        return { kind = "stale" }
      end
      editPartyMon(service, slot, function(copy)
        copy.moves[a + 1], copy.moves[b + 1] = copy.moves[b + 1], copy.moves[a + 1]
      end)
      return { kind = "changed" }
    end,
  })
  local status = nativeStep(controller, {})
  Assert.equal(status.group, "info", "the reorder flow starts on info")
  status = nativeStep(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(status.group, "skills", "the reorder flow reaches skills")
  Assert.deepEqual(service:capture(), before, "browsing leaves saves and generator draws alone")
  status = nativeStep(controller, { { type = "confirm" } })
  Assert.equal(status.phase, "move_opening", "the reorder flow opens detail")
  status = settlePhase(controller, "move_detail")
  Assert.equal(status.moveSlot, 0, "detail starts on the first existing row")
  Assert.equal(#calls, 0, "entering detail publishes nothing")
  Assert.deepEqual(service:capture(), before, "inspecting detail writes nothing")
  status = nativeStep(controller, { { type = "navigate", direction = "down" } })
  Assert.equal(status.moveSlot, 1, "the gesture reaches its target row")
  status = nativeStep(controller, { { type = "confirm" } })
  Assert.equal(status.phase, "move_reorder", "confirmation arms the source row")
  Assert.equal(status.reorderSource, 0, "the armed source is exact")
  Assert.equal(#calls, 0, "arming publishes nothing")
  status = nativeStep(controller, { { type = "navigate", direction = "down" } })
  Assert.equal(status.moveSlot, 1, "detail holds still while armed")
  status = nativeStep(controller, { { type = "confirm" } })
  Assert.equal(#calls, 1, "the completed gesture publishes exactly once")
  Assert.equal(calls[1].slot, 0, "the published party slot is exact")
  Assert.equal(calls[1].a, 0, "the published source row is exact")
  Assert.equal(calls[1].b, 1, "the published target row is exact")
  Assert.equal(calls[1].revision, revision, "the observed revision guards the swap")
  status = settlePhase(controller, "move_detail")
  Assert.isNil(status.reorderSource, "a published gesture disarms")
  Assert.equal(status.facts.moves[1].key, "GROWL", "the swap reorders its rows")
  Assert.equal(status.facts.moves[1].pp, 40, "swapped rows keep their power points")
  Assert.equal(status.facts.moves[1].ppUps, 0, "swapped rows keep their point ups")
  Assert.equal(status.facts.moves[2].key, "TACKLE", "whole entries travel together")
  Assert.equal(status.facts.moves[2].pp, 10, "whole entries keep their power points")
  Assert.equal(status.facts.moves[2].ppUps, 1, "whole entries keep their point ups")
  Assert.equal(service:partyRevision(), revision + 1, "the swap advances the revision once")
  local after = service:capture()
  Assert.deepEqual(after.rng, before.rng, "reordering consumes no generator draws")
  Assert.isNil(controller:takeResult(), "reordering never closes the summary")
  drain(controller)
  Assert.deepEqual(drain(controller), {}, "effects drain exactly once")
end

function T.same_row_confirmation_disarms_silently()
  local controller = nativeOpen({})
  nativeStep(controller, {})
  nativeStep(controller, { { type = "navigate", direction = "right" } })
  nativeStep(controller, { { type = "confirm" } })
  settlePhase(controller, "move_detail")
  nativeStep(controller, { { type = "navigate", direction = "down" } })
  local status = nativeStep(controller, { { type = "confirm" } })
  Assert.equal(status.phase, "move_reorder", "confirmation arms the current row")
  status = nativeStep(controller, { { type = "confirm" } })
  Assert.equal(status.phase, "move_detail", "same-row confirmation disarms")
  Assert.isNil(status.reorderSource, "the source clears without publication")
  Assert.isNil(controller:takeResult(), "a no-op gesture completes nothing")
end

function T.stale_armed_gestures_refresh_without_publishing()
  local controller, state = nativeOpen({})
  nativeStep(controller, {})
  nativeStep(controller, { { type = "navigate", direction = "right" } })
  nativeStep(controller, { { type = "confirm" } })
  settlePhase(controller, "move_detail")
  nativeStep(controller, { { type = "confirm" } })
  Assert.equal(controller:status().phase, "move_reorder", "the gesture arms first")
  state.revision = state.revision + 1
  local status = nativeStep(controller, { { type = "navigate", direction = "down" } })
  Assert.isNil(status.reorderSource, "drift drops the armed gesture")
  Assert.notNil(status.notice, "drift surfaces a notice")
  Assert.isNil(controller:takeResult(), "drift completes nothing")
  status = nativeStep(controller, { { type = "confirm" } })
  Assert.isNil(controller:takeResult(), "a late confirmation applies no stale swap")
  Assert.equal(status.phase, "move_detail", "a late confirmation only arms anew")
end

function T.detail_cancel_returns_to_skills_and_reorder_cancel_disarms()
  local controller = nativeOpen({})
  nativeStep(controller, {})
  nativeStep(controller, { { type = "navigate", direction = "right" } })
  nativeStep(controller, { { type = "confirm" } })
  settlePhase(controller, "move_detail")
  local status = nativeStep(controller, { { type = "cancel" } })
  Assert.equal(status.phase, "move_closing", "detail cancellation stages its reverse motion")
  status = settlePhase(controller, "root")
  Assert.equal(status.group, "skills", "detail cancellation keeps skills, not info")
  Assert.isNil(controller:takeResult(), "detail cancellation completes nothing")
  nativeStep(controller, { { type = "confirm" } })
  settlePhase(controller, "move_detail")
  nativeStep(controller, { { type = "confirm" } })
  Assert.equal(controller:status().phase, "move_reorder", "the gesture arms again")
  status = nativeStep(controller, { { type = "cancel" } })
  Assert.equal(status.phase, "move_detail", "reorder cancellation disarms into detail")
  Assert.isNil(status.reorderSource, "reorder cancellation clears its source")
  Assert.isNil(controller:takeResult(), "reorder cancellation completes nothing")
end

function T.inspect_only_capability_preserves_details_without_arming()
  local controller = nativeOpen({ allowReorder = false })
  nativeStep(controller, {})
  nativeStep(controller, { { type = "navigate", direction = "right" } })
  nativeStep(controller, { { type = "confirm" } })
  local status = settlePhase(controller, "move_detail")
  Assert.equal(status.moveSlot, 0, "inspect-only browsing still reads details")
  status = nativeStep(controller, { { type = "confirm" } })
  Assert.equal(status.phase, "move_detail", "inspect-only confirmation never arms")
  Assert.isNil(status.reorderSource, "inspect-only browsing records no source")
  status = nativeStep(controller, { { type = "navigate", direction = "down" } })
  status = nativeStep(controller, { { type = "confirm" } })
  Assert.isNil(status.reorderSource, "inspect-only browsing never publishes")
  Assert.isNil(controller:takeResult(), "inspect-only browsing completes nothing")
end

function T.emptied_party_recovers_cancelled_once()
  local controller, state = nativeOpen({ state = nativeState({ roster = { {} } }) })
  nativeStep(controller, {})
  Assert.equal(controller:status().group, "info", "the flow starts normally")
  state.roster = {}
  state.revision = state.revision + 1
  local ok, message = pcall(function()
    nativeStep(controller, {})
  end)
  Assert.isTrue(ok, "an emptied party recovers instead of failing: " .. tostring(message))
  local result = controller:takeResult()
  Assert.notNil(result, "an emptied party reports its recovery once")
  Assert.equal(result.kind, "cancelled", "the recovery never invents a member")
  Assert.isNil(controller:takeResult(), "the recovery reports exactly once")
end

function T.picker_selects_an_existing_slot_with_the_live_revision_and_leaves_saves_alone()
  local catalog = CatalogFixture.makeCatalog()
  local service = liveService(catalog, 0x30303030)
  giftSpecies(service, "CHIKORITA", 5)
  giftSpecies(service, "TOTODILE", 5)
  editPartyMon(service, 0, function(copy)
    copy.moves = distinctMoves()
  end)
  local manifest = SummaryPresentationFixture.manifest()
  local context = SummaryPresentationFixture.context(2)
  local before = service:capture()
  local controller = nativeOpen({
    mode = "move_pick",
    model = serviceModel(service, context, manifest),
    manifest = manifest,
    request = { context = "pp_restore" },
    allowReorder = false,
  })
  local status = nativeStep(controller, {}, CLOSED_GATES)
  Assert.isTrue(status.open, "the picker waits out entry readiness")
  Assert.isNil(controller:takeResult(), "the picker selects nothing before readiness")
  status = nativeStep(controller, { { type = "confirm" } }, CLOSED_GATES)
  Assert.isNil(controller:takeResult(), "gated input is discarded, not replayed")
  status = nativeStep(controller, {}, OPEN_GATES)
  Assert.equal(status.group, "skills", "the picker opens on the move selection state")
  Assert.isNil(controller:takeResult(), "readiness alone selects nothing")
  status = nativeStep(controller, { { type = "confirm" } })
  Assert.isFalse(status.open, "selection terminates the pick")
  local result = controller:takeResult()
  Assert.notNil(result, "selection reports its record")
  Assert.equal(result.kind, "move_selected", "ordinary rows select")
  Assert.equal(result.slot, 0, "the pick carries its member")
  Assert.isTrue(result.moveSlot >= 0 and result.moveSlot <= 3, "the pick carries an owned slot")
  Assert.equal(result.partyRevision, service:partyRevision(), "the pick carries the live revision")
  Assert.deepEqual(service:capture(), before, "picking publishes nothing and draws no rng")
  Assert.isNil(controller:takeResult(), "selection reports exactly once")
end

function T.protected_rows_notice_and_block_until_cancel_acknowledges()
  local controller = nativeOpen({
    mode = "move_pick",
    request = { context = "replace_machine", protected = { [2] = "hm" } },
    allowReorder = false,
  })
  nativeStep(controller, {})
  nativeStep(controller, { { type = "navigate", direction = "down" } })
  local status = nativeStep(controller, { { type = "confirm" } })
  Assert.isTrue(status.open, "a protected choice stays open")
  Assert.isNil(controller:takeResult(), "a protected choice reports no result")
  Assert.notNil(status.notice, "a protected choice explains itself")
  Assert.equal(status.notice.reason, "hm", "the notice names its protection")
  status = nativeStep(controller, { { type = "navigate", direction = "up" } })
  Assert.equal(status.moveSlot, 0, "the cursor still travels under the notice")
  status = nativeStep(controller, { { type = "confirm" } })
  Assert.isNil(controller:takeResult(), "row selection cannot complete under the notice")
  Assert.isTrue(status.open, "the modal notice holds the picker open")
  status = nativeStep(controller, { { type = "cancel" } })
  Assert.isTrue(status.open, "acknowledging keeps the picker open")
  Assert.isNil(status.notice, "acknowledging clears the notice")
  Assert.isNil(controller:takeResult(), "acknowledging completes nothing")
  status = nativeStep(controller, { { type = "confirm" } })
  local result = controller:takeResult()
  Assert.notNil(result, "selection completes after acknowledgement")
  Assert.equal(result.kind, "move_selected", "the acknowledged pick selects")
  Assert.equal(result.moveSlot, 0, "the acknowledged pick carries its row")
end

function T.prospective_fifth_row_declines_as_cancelled_not_slot_four()
  local function openProspective()
    return nativeOpen({
      mode = "move_pick",
      request = { context = "replace_machine", prospectiveMove = "RAZOR_LEAF" },
      allowReorder = false,
    })
  end
  local controller = openProspective()
  nativeStep(controller, {})
  Assert.equal(#controller:status().facts.moves, 4, "the preview never grows the owned rows")
  for _ = 1, 4 do
    nativeStep(controller, { { type = "navigate", direction = "down" } })
  end
  local status = nativeStep(controller, { { type = "confirm" } })
  local result = controller:takeResult()
  Assert.notNil(result, "the prospective row answers")
  Assert.equal(result.kind, "cancelled", "declining replacement cancels")
  Assert.isNil(result.moveSlot, "declining never reports slot four")
  Assert.isFalse(status.open, "declining terminates the pick")
  local back = openProspective()
  nativeStep(back, {})
  for _ = 1, 4 do
    nativeStep(back, { { type = "navigate", direction = "down" } })
  end
  nativeStep(back, { { type = "navigate", direction = "up" } })
  nativeStep(back, { { type = "confirm" } })
  result = back:takeResult()
  Assert.notNil(result, "stepping back answers too")
  Assert.equal(result.kind, "move_selected", "the owned row behind the preview still selects")
  Assert.equal(result.moveSlot, 3, "the owned row behind the preview is exact")
end

function T.picker_without_a_prospect_invents_no_fifth_row()
  local controller = nativeOpen({
    mode = "move_pick",
    request = { context = "pp_restore" },
    allowReorder = false,
  })
  nativeStep(controller, {})
  for _ = 1, 4 do
    nativeStep(controller, { { type = "navigate", direction = "down" } })
  end
  nativeStep(controller, { { type = "confirm" } })
  local result = controller:takeResult()
  Assert.notNil(result, "the sweep answers")
  Assert.equal(result.kind, "move_selected", "ordinary contexts select owned rows")
  Assert.isTrue(result.moveSlot >= 0 and result.moveSlot <= 3, "ordinary contexts report owned slots only")
end

function T.empty_rows_never_select()
  local moves = {
    { kind = "move", moveSlot = 0, key = "TACKLE", name = "Tackle", pp = 10, ppUps = 1 },
    { kind = "empty", moveSlot = 1 },
    { kind = "move", moveSlot = 2, key = "RAZOR_LEAF", name = "Razor Leaf", pp = 25, ppUps = 2 },
    { kind = "move", moveSlot = 3, key = "SYNTHESIS", name = "Synthesis", pp = 5, ppUps = 3 },
  }
  local controller = nativeOpen({
    mode = "move_pick",
    model = nativeModel(nativeState({ movesBySlot = { moves } })),
    request = { context = "pp_up" },
    allowReorder = false,
  })
  nativeStep(controller, {})
  local status = nativeStep(controller, { { type = "navigate", direction = "down" } })
  Assert.equal(status.moveSlot, 1, "the picker cursor visits empty rows")
  status = nativeStep(controller, { { type = "confirm" } })
  Assert.isTrue(status.open, "an empty choice stays open")
  Assert.isNil(controller:takeResult(), "an empty choice reports no result")
  Assert.notNil(status.notice, "an empty choice explains itself")
end

function T.cancellation_honors_allow_cancel_on_every_route()
  local function openPicker(cancellable)
    return nativeOpen({
      mode = "move_pick",
      request = { context = "pp_restore" },
      allowReorder = false,
      allowCancel = cancellable,
    })
  end
  local controller = openPicker(true)
  nativeStep(controller, {})
  nativeStep(controller, { { type = "cancel" } })
  Assert.equal(controller:takeResult().kind, "cancelled", "cancellation cancels when allowed")
  controller = openPicker(true)
  nativeStep(controller, {})
  nativeStep(controller, { { type = "dismiss" } })
  Assert.equal(controller:takeResult().kind, "cancelled", "outside dismissal cancels when allowed")
  controller = openPicker(false)
  nativeStep(controller, {})
  local status = nativeStep(controller, { { type = "cancel" } })
  Assert.isTrue(status.open, "cancellation holds when forbidden")
  Assert.isNil(controller:takeResult(), "forbidden cancellation reports nothing")
  status = nativeStep(controller, { { type = "dismiss" } })
  Assert.isTrue(status.open, "dismissal holds when forbidden")
  Assert.isNil(controller:takeResult(), "forbidden dismissal reports nothing")
  local exiting = nativeOpen({
    mode = "move_pick",
    request = { context = "pp_restore" },
    allowReorder = false,
    allowCancel = false,
    hitTest = function()
      return { kind = "return" }
    end,
  })
  nativeStep(exiting, {})
  status = nativeStep(exiting, { { type = "pointer_down", pointerId = "touch:1", x = 4, y = 4 } })
  status = nativeStep(exiting, { { type = "pointer_up", pointerId = "touch:1", x = 4, y = 4 } })
  Assert.isTrue(status.open, "exit touches hold when forbidden")
  Assert.isNil(exiting:takeResult(), "forbidden exit touches report nothing")
  exiting:dispose()
  Assert.isNil(exiting:takeResult(), "disposal invents no completion")
  Assert.isFalse(exiting:status().open, "disposal still releases the instance")
end

function T.summary_root_cancel_honors_allow_cancel()
  local controller = nativeOpen({ allowCancel = false })
  nativeStep(controller, {})
  local status = nativeStep(controller, { { type = "cancel" } })
  Assert.isTrue(status.open, "root cancellation holds when forbidden")
  Assert.isNil(controller:takeResult(), "forbidden root cancellation reports nothing")
end

function T.picture_epochs_advance_only_on_member_or_appearance_change()
  local controller, state = nativeOpen({})
  local status = nativeStep(controller, {})
  Assert.equal(status.pictureEpoch, 0, "browsing opens on the first picture epoch")
  Assert.notNil(status.picture, "the entry frame selects its picture")
  status = nativeStep(controller, {})
  status = nativeStep(controller, {})
  Assert.equal(status.pictureEpoch, 0, "idle ticks keep the epoch")
  status = nativeStep(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(status.pictureEpoch, 0, "group changes never restart the picture")
  state.contextKey = "day14|regional"
  status = nativeStep(controller, {})
  Assert.equal(status.pictureEpoch, 0, "context-only refreshes never restart the picture")
  status = nativeStep(controller, { { type = "navigate", direction = "down" } })
  Assert.equal(status.pictureEpoch, 1, "member changes advance the epoch")
  status = nativeStep(controller, { { type = "navigate", direction = "up" } })
  Assert.equal(status.pictureEpoch, 2, "epochs never recycle within one opening")
end

function T.cries_drain_once_with_their_epoch_and_eggs_stay_silent()
  local function collectCries(controller, ticks)
    local cries = {}
    for _ = 1, ticks do
      nativeStep(controller, {})
      for _, effect in ipairs(drain(controller)) do
        if effect.kind == "cry" then
          cries[#cries + 1] = effect
        end
      end
    end
    return cries
  end
  local controller = nativeOpen({})
  nativeStep(controller, {})
  drain(controller)
  local cries = collectCries(controller, 5)
  Assert.equal(#cries, 1, "the entry cry drains exactly once")
  Assert.equal(cries[1].pictureEpoch, 0, "the entry cry carries its epoch")
  Assert.equal(cries[1].slot, 0, "the entry cry carries its member")
  nativeStep(controller, { { type = "navigate", direction = "down" } })
  drain(controller)
  cries = collectCries(controller, 5)
  Assert.equal(#cries, 1, "the new member cries exactly once")
  Assert.equal(cries[1].pictureEpoch, 1, "the new cry carries the new epoch")
  Assert.equal(cries[1].slot, 1, "the new cry carries the new member")
  for _, cry in ipairs(cries) do
    Assert.isTrue(cry.pictureEpoch ~= 0, "old epochs never cry after a switch")
  end
  local eggy = nativeOpen({ state = nativeState({ roster = { { isEgg = false }, { isEgg = true } } }) })
  nativeStep(eggy, {})
  drain(eggy)
  nativeStep(eggy, { { type = "navigate", direction = "down" } })
  drain(eggy)
  cries = collectCries(eggy, 6)
  Assert.equal(#cries, 0, "eggs never borrow a species cry")
end

function T.status_reads_and_pointer_traffic_never_advance_playback()
  local controller = nativeOpen({})
  nativeStep(controller, {})
  drain(controller)
  local picture = controller:status().picture
  for _ = 1, 5 do
    Assert.deepEqual(controller:status().picture, picture, "repeated status reads hold the sample")
  end
  nativeStep(controller, { { type = "pointer_down", pointerId = "touch:1", x = 200, y = 100 } })
  nativeStep(controller, { { type = "pointer_up", pointerId = "touch:1", x = 200, y = 100 } })
  Assert.deepEqual(controller:status().picture, picture, "pointer traffic holds the sample")
  Assert.equal(controller:status().pictureEpoch, 0, "pointer traffic holds the epoch")
  Assert.deepEqual(drain(controller), {}, "reads and pointers queue no effects")
end

-- Retired page-behavior coverage restated on the native contract: root
-- cancellation, detail nesting, axis separation, picker cursor shape,
-- construction gates, command outcomes, empty details, and touch exits.

function T.cancel_on_info_returns_the_displayed_slot()
  local controller = nativeOpen({ initialSlot = 1 })
  nativeStep(controller, {})
  local status = nativeStep(controller, { { type = "cancel" } })
  Assert.isFalse(status.open, "cancellation closes the summary")
  local result = assert(controller:takeResult(), "a terminal gesture reports its result")
  Assert.equal(result.kind, "return", "closing reports a return")
  Assert.equal(result.slot, 1, "party resumes on the displayed member")
  Assert.isNil(controller:takeResult(), "the return reports exactly once")
end

function T.detail_cancel_steps_back_to_skills_before_closing()
  local controller = nativeOpen({})
  nativeStep(controller, {})
  nativeStep(controller, { { type = "navigate", direction = "right" } })
  nativeStep(controller, { { type = "confirm" } })
  settlePhase(controller, "move_detail")
  local status = nativeStep(controller, { { type = "cancel" } })
  Assert.isTrue(status.open, "detail cancellation steps back first")
  Assert.equal(status.phase, "move_closing", "detail cancellation stages its reverse motion")
  status = settlePhase(controller, "root")
  Assert.equal(status.group, "skills", "detail cancellation keeps skills")
  Assert.isNil(controller:takeResult(), "stepping back reports no terminal result")
  nativeStep(controller, { { type = "cancel" } })
  Assert.equal(controller:takeResult().kind, "return", "a second cancellation closes")
end

function T.group_and_member_axes_hold_their_dimensions()
  local controller = nativeOpen({ state = nativeState({ roster = { {}, {}, {} } }) })
  nativeStep(controller, {})
  local status = nativeStep(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(status.group, "skills", "lateral input walks groups")
  Assert.equal(status.slot, 0, "lateral input holds the member")
  status = nativeStep(controller, { { type = "navigate", direction = "down" } })
  Assert.equal(status.slot, 1, "vertical input scans members")
  Assert.equal(status.group, "skills", "vertical input holds the group")
  Assert.isNil(status.moveSlot, "member scans carry no move cursor")
end

function T.picker_cursor_selects_its_exact_owned_row()
  local controller = nativeOpen({
    mode = "move_pick",
    request = { context = "pp_restore" },
    allowReorder = false,
  })
  nativeStep(controller, {})
  local status = nativeStep(controller, { { type = "navigate", direction = "down" } })
  Assert.equal(status.moveSlot, 1, "the picker cursor visits owned rows")
  nativeStep(controller, { { type = "confirm" } })
  local result = assert(controller:takeResult(), "selection reports its record")
  Assert.equal(result.kind, "move_selected", "ordinary rows select")
  Assert.equal(result.moveSlot, 1, "the zero-based move slot is exact")
  Assert.equal(result.slot, 0, "the pick carries its member")
  Assert.equal(result.partyRevision, 7, "the observed revision qualifies the pick")
  Assert.isNil(controller:takeResult(), "selection reports exactly once")
end

function T.picker_construction_bars_reorder_commands_and_holds_its_member()
  local rejected = pcall(SummaryController.new, {
    mode = "move_pick",
    model = nativeModel(nativeState()),
    request = { context = "replace_machine", protected = {} },
    reorderMoves = function()
      return { kind = "changed" }
    end,
    resolveLayout = function()
      return {
        hitTest = function()
          return nil
        end,
      }
    end,
    manifest = SummaryPresentationFixture.manifest(),
  })
  Assert.isFalse(rejected, "the picker refuses a reorder command by construction")
  local controller = nativeOpen({
    mode = "move_pick",
    request = { context = "replace_machine", protected = {} },
    allowReorder = false,
  })
  nativeStep(controller, {})
  local status = nativeStep(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(status.slot, 0, "the picker holds its member")
  Assert.equal(status.group, "skills", "the picker holds its group")
  status = nativeStep(controller, { { type = "navigate", direction = "up" } })
  Assert.equal(status.moveSlot, 0, "the picker cursor clamps at the first row")
end

function T.mode_construction_rejects_mismatched_shapes()
  local model = nativeModel(nativeState())
  local function resolveLayout()
    return {
      hitTest = function()
        return nil
      end,
    }
  end
  Assert.isFalse(
    pcall(SummaryController.new, {
      mode = "summary",
      model = model,
      request = { context = "pp_restore" },
      reorderMoves = function()
        return { kind = "changed" }
      end,
      resolveLayout = resolveLayout,
      manifest = SummaryPresentationFixture.manifest(),
    }),
    "ordinary browsing carries no picker request"
  )
  Assert.isFalse(
    pcall(SummaryController.new, {
      mode = "summary",
      model = model,
      resolveLayout = resolveLayout,
      manifest = SummaryPresentationFixture.manifest(),
    }),
    "ordinary browsing reorders through its command"
  )
  Assert.isFalse(
    pcall(SummaryController.new, {
      mode = "move_pick",
      model = model,
      resolveLayout = resolveLayout,
      manifest = SummaryPresentationFixture.manifest(),
    }),
    "picking carries its request"
  )
end

function T.reorder_command_contract_reports_once_and_rejects_unknown_outcomes()
  local calls = 0
  local controller = nativeOpen({
    reorderMoves = function(_, _, _, _)
      calls = calls + 1
      if calls == 1 then
        return { kind = "changed" }
      end
      return { kind = "bogus" }
    end,
  })
  nativeStep(controller, {})
  nativeStep(controller, { { type = "navigate", direction = "right" } })
  nativeStep(controller, { { type = "confirm" } })
  settlePhase(controller, "move_detail")
  nativeStep(controller, { { type = "navigate", direction = "down" } })
  nativeStep(controller, { { type = "confirm" } })
  nativeStep(controller, { { type = "navigate", direction = "down" } })
  nativeStep(controller, { { type = "confirm" } })
  Assert.equal(calls, 1, "the completed gesture publishes exactly once")
  Assert.isNil(controller:takeResult(), "reordering never closes the summary")
  nativeStep(controller, { { type = "navigate", direction = "down" } })
  nativeStep(controller, { { type = "confirm" } })
  nativeStep(controller, { { type = "navigate", direction = "down" } })
  local err = Assert.throws(function()
    nativeStep(controller, { { type = "confirm" } })
  end)
  Assert.notNil(tostring(err):find("unknown reorder outcome", 1, true), "unexpected outcomes fail loudly")
end

function T.stale_command_answers_refresh_without_closing()
  local controller = nativeOpen({
    reorderMoves = function()
      return { kind = "stale" }
    end,
  })
  nativeStep(controller, {})
  nativeStep(controller, { { type = "navigate", direction = "right" } })
  nativeStep(controller, { { type = "confirm" } })
  settlePhase(controller, "move_detail")
  nativeStep(controller, { { type = "navigate", direction = "down" } })
  nativeStep(controller, { { type = "confirm" } })
  nativeStep(controller, { { type = "navigate", direction = "down" } })
  nativeStep(controller, { { type = "confirm" } })
  local status = controller:status()
  Assert.equal(status.phase, "move_detail", "a stale answer returns to detail")
  Assert.isNil(status.reorderSource, "a stale answer disarms the source")
  Assert.notNil(status.notice, "a stale answer surfaces a notice")
  Assert.isNil(controller:takeResult(), "stale publication never closes")
end

function T.empty_details_carry_no_cursor_and_arm_nothing()
  local moves = {
    { kind = "empty", moveSlot = 0 },
    { kind = "empty", moveSlot = 1 },
    { kind = "empty", moveSlot = 2 },
    { kind = "empty", moveSlot = 3 },
  }
  local controller = nativeOpen({ state = nativeState({ movesBySlot = { moves } }) })
  nativeStep(controller, {})
  nativeStep(controller, { { type = "navigate", direction = "right" } })
  nativeStep(controller, { { type = "confirm" } })
  local status = settlePhase(controller, "move_detail")
  Assert.isNil(status.moveSlot, "an empty detail carries no cursor")
  status = nativeStep(controller, { { type = "confirm" } })
  Assert.equal(status.phase, "move_detail", "empty confirmation arms nothing")
  Assert.isNil(status.reorderSource, "empty confirmation publishes nothing")
  status = nativeStep(controller, { { type = "navigate", direction = "down" } })
  Assert.isNil(status.moveSlot, "empty navigation finds no row")
  status = nativeStep(controller, { { type = "cancel" } })
  Assert.equal(status.phase, "move_closing", "empty detail still stages its reverse motion")
  status = settlePhase(controller, "root")
  Assert.equal(status.group, "skills", "empty detail keeps skills")
  Assert.isNil(controller:takeResult(), "empty browsing completes nothing")
end

function T.return_touches_follow_the_cancel_path()
  local hitTest = fixedHitboxes({
    { x0 = 0, x1 = 32, y0 = 160, y1 = 192, target = { kind = "return" } },
  })
  local controller = nativeOpen({ hitTest = hitTest })
  nativeStep(controller, {})
  nativeStep(controller, { { type = "pointer_down", pointerId = "touch:1", x = 4, y = 170 } })
  nativeStep(controller, { { type = "pointer_up", pointerId = "touch:1", x = 4, y = 170 } })
  local result = assert(controller:takeResult(), "exit touches report")
  Assert.equal(result.kind, "return", "exit touches return")
  Assert.equal(result.slot, 0, "exit touches carry the member")
  local held = nativeOpen({ hitTest = hitTest, allowCancel = false })
  nativeStep(held, {})
  local status = nativeStep(held, { { type = "pointer_down", pointerId = "touch:1", x = 4, y = 170 } })
  status = nativeStep(held, { { type = "pointer_up", pointerId = "touch:1", x = 4, y = 170 } })
  Assert.isTrue(status.open, "forbidden exit touches hold the summary")
  Assert.isNil(held:takeResult(), "forbidden exit touches report nothing")
end

function T.picture_blend_reaches_status_by_value_detached_by_identity()
  local manifest = SummaryPresentationFixture.manifest()
  local compiled = assert(manifest.pictures.CHIKORITA, "the family carries the selected picture")
  local firstSample = assert(compiled.samples[1], "the picture carries its samples")
  firstSample.paletteBlend = { coefficient = 9, target = { r = 31, g = 4, b = 19 } }
  local controller = nativeOpen({ manifest = manifest })
  nativeStep(controller, {})
  local status = controller:status()
  Assert.notNil(status.picture, "the entry frame selects its picture")
  Assert.deepEqual(
    status.picture.paletteBlend,
    firstSample.paletteBlend,
    "the compiled blend reaches controller status by value"
  )
  Assert.isTrue(
    status.picture.paletteBlend ~= firstSample.paletteBlend,
    "the returned blend never aliases the compiled sample"
  )
  Assert.isTrue(
    status.picture.paletteBlend.target ~= firstSample.paletteBlend.target,
    "the nested target never aliases the compiled sample"
  )
  status.picture.paletteBlend.coefficient = -1
  status.picture.paletteBlend.target.r = -1
  local reread = controller:status()
  Assert.deepEqual(reread.picture.paletteBlend, firstSample.paletteBlend, "external mutation cannot reach later status")
  nativeStep(controller, {})
  Assert.deepEqual(controller:status().picture.paletteBlend, firstSample.paletteBlend, "idle ticks keep the blend")
end

function T.move_detail_open_and_close_follow_the_generated_x_track()
  local manifest = SummaryPresentationFixture.manifest()
  local track = assert(manifest.transitions.moveDetail, "the family carries the move detail track")
  Assert.equal(track.axis, "x", "the move track runs along x")
  Assert.deepEqual(track.positions, { 0, 64, 128 }, "the move track carries its source positions")
  local controller = nativeOpen({ manifest = manifest })
  nativeStep(controller, {})
  nativeStep(controller, { { type = "navigate", direction = "right" } })
  local opening = nativeStep(controller, { { type = "confirm" } })
  Assert.equal(opening.phase, "move_opening", "confirmation stages the move transition")
  local staged = assert(opening.transition, "the staged transition publishes its sample")
  Assert.equal(staged.kind, "moveDetail", "the staged transition names its track")
  Assert.equal(staged.direction, "open", "the staged transition opens")
  Assert.equal(staged.axis, "x", "the staged transition runs along the generated axis")
  Assert.equal(staged.offset, 0, "the staged transition starts at the generated origin")
  Assert.isTrue(type(opening.spriteTick) == "number", "the staged status carries its animation tick")
  local held = nativeStep(controller, { { type = "navigate", direction = "down" } })
  Assert.equal(held.slot, 0, "transitional input moves no member")
  Assert.equal(held.group, "skills", "transitional input moves no group")
  -- The transitional tick advances the motion while discarding its edge,
  -- so the staged origin is recorded here and the trace continues below.
  local offsets = { staged.offset }
  local status = controller:status()
  for _ = 1, 12 do
    if status.phase == "move_detail" and status.transition == nil then
      break
    end
    local sample = assert(status.transition, "the opening transition stays sampled until stable detail")
    Assert.equal(sample.kind, "moveDetail", "opening samples name their track")
    Assert.equal(sample.direction, "open", "opening samples keep their direction")
    Assert.equal(sample.axis, "x", "opening samples run along the generated axis")
    offsets[#offsets + 1] = sample.offset
    status = nativeStep(controller, {})
  end
  Assert.equal(status.phase, "move_detail", "the opening trace settles into detail")
  Assert.isNil(status.transition, "stable detail carries no transition")
  Assert.deepEqual(offsets, { 0, 64, 128 }, "opening exposes every generated position in order")
  Assert.isTrue(
    type(status.spriteTick) == "number" and status.spriteTick > (opening.spriteTick or -1),
    "fixed updates advance the animation tick"
  )
  local closing = nativeStep(controller, { { type = "cancel" } })
  Assert.equal(closing.phase, "move_closing", "cancelling detail stages the reverse transition")
  local returning = {}
  status = closing
  for _ = 1, 12 do
    if status.phase == "root" and status.transition == nil then
      break
    end
    local sample = assert(status.transition, "the closing transition stays sampled until the root")
    Assert.equal(sample.kind, "moveDetail", "closing samples name their track")
    Assert.equal(sample.direction, "close", "closing samples keep their direction")
    Assert.equal(sample.axis, "x", "closing samples run along the generated axis")
    returning[#returning + 1] = sample.offset
    status = nativeStep(controller, {})
  end
  Assert.equal(status.phase, "root", "the closing trace returns to browsing")
  Assert.isNil(status.transition, "the root carries no transition")
  Assert.deepEqual(returning, { 128, 64, 0 }, "closing reverses the generated positions")
  Assert.equal(status.group, "skills", "closing keeps the skills group")
  Assert.isNil(controller:takeResult(), "nested transitions complete nothing")
end

function T.ribbon_detail_open_and_close_follow_the_generated_y_track()
  local manifest = SummaryPresentationFixture.manifest()
  local track = assert(manifest.transitions.ribbonDetail, "the family carries the ribbon detail track")
  Assert.equal(track.axis, "y", "the ribbon track runs along y")
  Assert.deepEqual(track.positions, { 0, 36, 72 }, "the ribbon track carries its source positions")
  local controller = nativeOpen({ manifest = manifest, state = nativeState({ ribbons = earnedRibbons(10) }) })
  nativeStep(controller, {})
  nativeStep(controller, { { type = "navigate", direction = "right" } })
  nativeStep(controller, { { type = "navigate", direction = "right" } })
  local opening = nativeStep(controller, { { type = "confirm" } })
  Assert.equal(opening.phase, "ribbon_opening", "confirmation stages the ribbon transition")
  local staged = assert(opening.transition, "the staged transition publishes its sample")
  Assert.equal(staged.kind, "ribbonDetail", "the staged transition names its track")
  Assert.equal(staged.direction, "open", "the staged transition opens")
  Assert.equal(staged.axis, "y", "the staged transition runs along the generated axis")
  Assert.equal(staged.offset, 0, "the staged transition starts at the generated origin")
  local held = nativeStep(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(held.ribbonIndex, 0, "transitional input moves no ribbon cursor")
  -- The transitional tick advances the motion while discarding its edge,
  -- so the staged origin is recorded here and the trace continues below.
  local offsets = { staged.offset }
  local status = controller:status()
  for _ = 1, 12 do
    if status.phase == "ribbon_detail" and status.transition == nil then
      break
    end
    local sample = assert(status.transition, "the opening transition stays sampled until stable detail")
    Assert.equal(sample.kind, "ribbonDetail", "opening samples name their track")
    Assert.equal(sample.direction, "open", "opening samples keep their direction")
    Assert.equal(sample.axis, "y", "opening samples run along the generated axis")
    offsets[#offsets + 1] = sample.offset
    status = nativeStep(controller, {})
  end
  Assert.equal(status.phase, "ribbon_detail", "the opening trace settles into detail")
  Assert.isNil(status.transition, "stable detail carries no transition")
  Assert.deepEqual(offsets, { 0, 36, 72 }, "opening exposes every generated position in order")
  local closing = nativeStep(controller, { { type = "cancel" } })
  Assert.equal(closing.phase, "ribbon_closing", "cancelling detail stages the reverse transition")
  local returning = {}
  status = closing
  for _ = 1, 12 do
    if status.phase == "root" and status.transition == nil then
      break
    end
    local sample = assert(status.transition, "the closing transition stays sampled until the root")
    Assert.equal(sample.kind, "ribbonDetail", "closing samples name their track")
    Assert.equal(sample.direction, "close", "closing samples keep their direction")
    Assert.equal(sample.axis, "y", "closing samples run along the generated axis")
    returning[#returning + 1] = sample.offset
    status = nativeStep(controller, {})
  end
  Assert.equal(status.phase, "root", "the closing trace returns to browsing")
  Assert.isNil(status.transition, "the root carries no transition")
  Assert.deepEqual(returning, { 72, 36, 0 }, "closing reverses the generated positions")
  Assert.equal(status.group, "performance", "closing keeps the ribbons group")
  Assert.isTrue(status.open, "closing the ribbon pane never exits the summary")
  Assert.isNil(controller:takeResult(), "nested transitions complete nothing")
end

function T.member_cursor_chrome_follows_its_explicit_capability()
  local concealed, _ = nativeOpen({ showMemberCursor = false })
  local status = nativeStep(concealed, {})
  Assert.isFalse(status.showMemberCursor, "detached status hides the party member cursor")
  nativeStep(concealed, { { type = "navigate", direction = "down" } })
  local moved = concealed:status()
  Assert.equal(moved.slot, 1, "navigation still scans members without the chrome")
  Assert.isFalse(moved.showMemberCursor, "navigation never restores the chrome")
  local shown, _ = nativeOpen()
  Assert.isTrue(nativeStep(shown, {}).showMemberCursor, "party status keeps the member cursor by default")
end

function T.opening_motion_advances_through_discarded_action_edges()
  local manifest = SummaryPresentationFixture.manifest()
  local controller = nativeOpen({ manifest = manifest })
  nativeStep(controller, {})
  nativeStep(controller, { { type = "navigate", direction = "right" } })
  local staged = nativeStep(controller, { { type = "confirm" } })
  Assert.equal(staged.phase, "move_opening", "confirmation stages the move transition")
  local stagedSample = assert(staged.transition, "the staged move transition publishes its sample")
  Assert.equal(stagedSample.offset, 0, "the staged move transition starts at the generated origin")
  Assert.equal(staged.moveSlot, 0, "the staged move transition keeps its row")
  local status = nativeStep(controller, { { type = "navigate", direction = "down" } })
  local first = assert(status.transition, "action input keeps the move transition sampled")
  Assert.equal(first.offset, 64, "navigation input advances the opening motion")
  Assert.equal(status.phase, "move_opening", "navigation input never settles the motion early")
  Assert.equal(status.moveSlot, 0, "transitional navigation moves no detail cursor")
  Assert.equal(status.slot, 0, "transitional navigation moves no member")
  Assert.equal(status.group, "skills", "transitional navigation moves no group")
  status = nativeStep(controller, {
    { type = "confirm" },
    { type = "dismiss" },
    { type = "navigate", direction = "up" },
  })
  local second = assert(status.transition, "a multi-edge tick keeps the move transition sampled")
  Assert.equal(second.offset, 128, "a multi-edge tick advances the motion exactly once")
  Assert.equal(status.phase, "move_opening", "a multi-edge tick never settles the motion early")
  Assert.equal(status.moveSlot, 0, "a multi-edge tick arms no reorder")
  Assert.isNil(status.reorderSource, "a multi-edge tick publishes no reorder")
  status = nativeStep(controller, { { type = "cancel" } })
  Assert.equal(status.phase, "move_detail", "the terminal action tick still settles into detail")
  Assert.isNil(status.transition, "stable detail carries no transition")
  Assert.equal(status.moveSlot, 0, "terminal input selects no new row")
  Assert.equal(status.slot, 0, "terminal input moves no member")
  Assert.equal(status.group, "skills", "terminal input moves no group")
  Assert.isTrue(status.open, "terminal input never exits the summary")
  Assert.isNil(controller:takeResult(), "discarded opening input completes nothing")
  local ribbons = nativeOpen({
    manifest = manifest,
    state = nativeState({ ribbons = earnedRibbons(10) }),
  })
  nativeStep(ribbons, {})
  nativeStep(ribbons, { { type = "navigate", direction = "right" } })
  nativeStep(ribbons, { { type = "navigate", direction = "right" } })
  local ribbonStaged = nativeStep(ribbons, { { type = "confirm" } })
  Assert.equal(ribbonStaged.phase, "ribbon_opening", "confirmation stages the ribbon transition")
  local ribbonSample = assert(ribbonStaged.transition, "the staged ribbon transition publishes its sample")
  Assert.equal(ribbonSample.offset, 0, "the staged ribbon transition starts at the generated origin")
  Assert.equal(ribbonStaged.ribbonIndex, 0, "the staged ribbon transition keeps its cell")
  local ribbonStatus = nativeStep(ribbons, { { type = "dismiss" } })
  local ribbonFirst = assert(ribbonStatus.transition, "action input keeps the ribbon transition sampled")
  Assert.equal(ribbonFirst.offset, 36, "dismissal input advances the ribbon motion")
  Assert.equal(ribbonStatus.phase, "ribbon_opening", "dismissal input never settles the motion early")
  Assert.equal(ribbonStatus.ribbonIndex, 0, "transitional dismissal moves no ribbon cursor")
  ribbonStatus = nativeStep(ribbons, {
    { type = "navigate", direction = "right" },
    { type = "cancel" },
  })
  local ribbonSecond = assert(ribbonStatus.transition, "a multi-edge tick keeps the ribbon transition sampled")
  Assert.equal(ribbonSecond.offset, 72, "a multi-edge tick advances the ribbon motion exactly once")
  Assert.equal(ribbonStatus.phase, "ribbon_opening", "a multi-edge tick never settles the ribbon early")
  Assert.equal(ribbonStatus.ribbonIndex, 0, "a multi-edge tick moves no ribbon cursor")
  ribbonStatus = nativeStep(ribbons, { { type = "confirm" } })
  Assert.equal(ribbonStatus.phase, "ribbon_detail", "the terminal action tick still settles into detail")
  Assert.isNil(ribbonStatus.transition, "stable ribbon detail carries no transition")
  Assert.equal(ribbonStatus.ribbonIndex, 0, "terminal input selects no new cell")
  Assert.isTrue(ribbonStatus.open, "terminal input never exits the summary")
  Assert.isNil(ribbons:takeResult(), "discarded ribbon opening input completes nothing")
end

function T.closing_terminal_ticks_settle_without_running_their_input()
  local manifest = SummaryPresentationFixture.manifest()
  local controller = nativeOpen({ manifest = manifest })
  nativeStep(controller, {})
  nativeStep(controller, { { type = "navigate", direction = "right" } })
  nativeStep(controller, { { type = "confirm" } })
  settlePhase(controller, "move_detail")
  local closing = nativeStep(controller, { { type = "cancel" } })
  Assert.equal(closing.phase, "move_closing", "cancelling detail stages the reverse motion")
  local closingSample = assert(closing.transition, "the staged closing transition publishes its sample")
  Assert.equal(closingSample.offset, 128, "the staged closing transition starts at the generated end")
  local status = nativeStep(controller, { { type = "navigate", direction = "right" } })
  local first = assert(status.transition, "closing input keeps the reverse motion sampled")
  Assert.equal(first.offset, 64, "navigation input advances the closing motion")
  Assert.equal(status.phase, "move_closing", "navigation input never settles the motion early")
  Assert.equal(status.group, "skills", "transitional navigation moves no group")
  Assert.equal(status.slot, 0, "transitional navigation moves no member")
  status = nativeStep(controller, { { type = "confirm" } })
  local second = assert(status.transition, "confirmation input keeps the reverse motion sampled")
  Assert.equal(second.offset, 0, "confirmation input advances the closing motion")
  Assert.equal(status.phase, "move_closing", "confirmation input never settles the motion early")
  status = nativeStep(controller, { { type = "cancel" } })
  Assert.equal(status.phase, "root", "the terminal action tick still returns to browsing")
  Assert.isNil(status.transition, "the root carries no transition")
  Assert.equal(status.group, "skills", "terminal cancellation never leaves the group")
  Assert.isTrue(status.open, "terminal cancellation never exits the summary")
  Assert.isNil(controller:takeResult(), "discarded closing input completes nothing")
  status = nativeStep(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(status.group, "performance", "a clean edge works after the terminal tick")
  Assert.equal(status.phase, "root", "the clean edge browses normally")
  local ribbonController = nativeOpen({
    manifest = manifest,
    state = nativeState({ ribbons = earnedRibbons(10) }),
  })
  nativeStep(ribbonController, {})
  nativeStep(ribbonController, { { type = "navigate", direction = "right" } })
  nativeStep(ribbonController, { { type = "navigate", direction = "right" } })
  nativeStep(ribbonController, { { type = "confirm" } })
  settlePhase(ribbonController, "ribbon_detail")
  local ribbonClosing = nativeStep(ribbonController, { { type = "cancel" } })
  Assert.equal(ribbonClosing.phase, "ribbon_closing", "cancelling ribbon detail stages its reverse motion")
  local ribbonSample = assert(ribbonClosing.transition, "the staged ribbon closing publishes its sample")
  Assert.equal(ribbonSample.offset, 72, "the staged ribbon closing starts at the generated end")
  local ribbonStatus = nativeStep(ribbonController, { { type = "dismiss" } })
  local ribbonFirst = assert(ribbonStatus.transition, "closing input keeps the ribbon reverse sampled")
  Assert.equal(ribbonFirst.offset, 36, "dismissal input advances the ribbon closing")
  Assert.equal(ribbonStatus.phase, "ribbon_closing", "dismissal input never settles the motion early")
  ribbonStatus = nativeStep(ribbonController, {
    { type = "navigate", direction = "left" },
    { type = "cancel" },
  })
  local ribbonSecond = assert(ribbonStatus.transition, "a multi-edge tick keeps the ribbon closing sampled")
  Assert.equal(ribbonSecond.offset, 0, "a multi-edge closing tick advances exactly once")
  Assert.equal(ribbonStatus.phase, "ribbon_closing", "a multi-edge tick never settles the ribbon early")
  ribbonStatus = nativeStep(ribbonController, { { type = "confirm" } })
  Assert.equal(ribbonStatus.phase, "root", "the terminal ribbon tick still returns to browsing")
  Assert.isNil(ribbonStatus.transition, "the ribbon root carries no transition")
  Assert.equal(ribbonStatus.group, "performance", "terminal confirmation never reopens detail")
  Assert.isTrue(ribbonStatus.open, "terminal confirmation never exits the summary")
  Assert.isNil(ribbonController:takeResult(), "discarded ribbon closing input completes nothing")
  ribbonStatus = nativeStep(ribbonController, { { type = "navigate", direction = "right" } })
  Assert.equal(ribbonStatus.group, "info", "a clean ribbon edge works after the terminal tick")
  Assert.equal(ribbonStatus.phase, "root", "the clean ribbon edge browses normally")
end

function T.every_material_context_input_refreshes_retained_facts()
  local catalog = CatalogFixture.makeCatalog()
  local service = liveService(catalog, 0x70106002)
  giftSpecies(service, "CHIKORITA", 5)
  giftSpecies(service, "TOTODILE", 5)
  editPartyMon(service, 0, function(copy)
    copy.ribbons = { ds1 = 2147483649, gba = 16777216, ds2 = 0 }
  end)
  local manifest = SummaryPresentationFixture.manifest()
  local current = SummaryPresentationFixture.context(2)
  local projection = SummaryModel.newProjection(service, function()
    return current
  end, manifest)
  local controller, _ = nativeOpen({
    model = {
      refresh = function(slot)
        return projection.refresh(slot)
      end,
    },
    manifest = manifest,
  })
  Assert.isTrue(controller:refreshFacts(), "the facts reconcile")
  local facts = assert(controller:status().facts, "status publishes its facts")
  Assert.isTrue(controller:refreshFacts(), "an unchanged refresh stays active")
  Assert.isTrue(controller:status().facts == facts, "an unchanged refresh reuses its facts")
  Assert.equal(controller:status().pictureEpoch, 0, "context-only traffic never restarts the picture")
  local revision = service:partyRevision()
  local function expectRefresh(note)
    Assert.equal(service:partyRevision(), revision, note .. " moves no party revision")
    Assert.isTrue(controller:refreshFacts(), note .. " stays active")
    local next = assert(controller:status().facts, note .. " publishes its facts")
    Assert.isTrue(next ~= facts, note .. " replaces its facts")
    Assert.equal(controller:status().pictureEpoch, 0, note .. " never restarts the picture")
    facts = next
  end
  current = SummaryPresentationFixture.context(2, { dayOfMonth = 14 })
  expectRefresh("a changed day")
  current.profile.name = "NEWHOPE"
  expectRefresh("a changed profile name")
  current.profile.trainerId = current.profile.trainerId + 1
  expectRefresh("a changed profile identity")
  current.profile.gender = 1 - current.profile.gender
  expectRefresh("a changed profile gender")
  current.dexMode = "national"
  expectRefresh("a changed dex mode")
  Assert.equal(facts.info.dexNumber, 152, "the national mode selects the national dex number")
  current.aprijuiceBySlot[1] = { power = 10, stamina = 0, skill = 0, jump = 0, speed = 0 }
  expectRefresh("a changed aprijuice row")
  current.specialRibbonDescriptions[2] = "CHANGED SLOT TWO"
  expectRefresh("a changed special description")
  current.performanceEnabled = false
  expectRefresh("disabled performance")
  Assert.isNil(facts.performance, "disabled performance exposes no rows")
  current.performanceEnabled = true
  expectRefresh("reenabled performance")
  Assert.equal(#facts.performance, 5, "reenabled performance exposes five rows")
  editPartyMon(service, 0, function(copy)
    copy.nickname = "LEAFY"
  end)
  revision = service:partyRevision()
  Assert.isTrue(controller:refreshFacts(), "a source revision stays active")
  local revised = assert(controller:status().facts, "a source revision publishes its facts")
  Assert.isTrue(revised ~= facts, "a source revision replaces its facts")
  Assert.equal(revised.identity.nickname, "LEAFY", "a source revision carries the new nickname")
  facts = revised
  local status = nativeStep(controller, { { type = "navigate", direction = "down" } })
  Assert.equal(status.slot, 1, "navigation changes the member")
  Assert.isTrue(status.facts ~= facts, "a changed member replaces its facts")
  Assert.equal(status.pictureEpoch, 1, "a changed member advances the epoch exactly once")
end

return { tests = T }
