-- The concrete party-screen application owns its icon-preparation wait: it
-- reports pending/error preparation instead of normal selection input,
-- stays cancellable while waiting, discards held activation received
-- before readiness, and releases its preparation interest exactly once on
-- close or disposal. Swaps and close results keep their existing meaning
-- once preparation is ready.

local Assert = require("tests.support.Assert")
local PartyPresentationFixture = require("tests.support.PartyPresentationFixture")
local PartyScreenState = require("game.hgss.src.field.PartyScreenState")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local function fakeCatalog()
  return {
    species = function(_)
      return { name = "Chikorita", genderRatio = 127 }
    end,
    item = function(_, item)
      assert(item == "NONE")
      return { name = "None" }
    end,
    iconSelection = function(_, mon)
      return mon.species .. "/f" .. mon.form
    end,
  }
end

local function fakeService(calls)
  local catalog = fakeCatalog()
  return {
    partyCount = function(_)
      return 2
    end,
    partyRevision = function(_)
      return 1
    end,
    partyMon = function(_)
      return {
        species = "CHIKORITA",
        form = 0,
        isEgg = false,
        personality = 0,
        nickname = "CHIKO",
        heldItem = "NONE",
        moves = { { move = "TACKLE", pp = 35, ppUps = 0 } },
        condition = { currentHp = 20, status = 0 },
      }
    end,
    partyMonDerived = function(_)
      return { maxHp = 20, level = 5 }
    end,
    catalog = function(_)
      return catalog
    end,
    swapPartyMons = function(_, a, b)
      calls.swaps[#calls.swaps + 1] = { a, b }
    end,
  }
end

---@param ready boolean
---@param failure string?
---@param calls table<string, unknown>
---@return PartyScreenState state
---@return table<string, fun(): integer> probes
local function sourceManifest()
  local panels = {}
  local origins = { { 0, 0 }, { 128, 8 }, { 0, 48 }, { 128, 56 }, { 0, 96 }, { 128, 104 } }
  for slot, origin in ipairs(origins) do
    panels[slot] = {
      origin = { x = origin[1], y = origin[2] },
      size = { width = 128, height = 48 },
    }
  end
  local function dpadBox(up, down, leftNeighbor, rightNeighbor)
    return {
      left = 0,
      top = 0,
      width = 0,
      height = 0,
      up = up,
      down = down,
      leftNeighbor = leftNeighbor,
      rightNeighbor = rightNeighbor,
    }
  end
  local function touch(top, bottom, left, right)
    return { top = top, bottom = bottom, left = left, right = right }
  end
  return {
    panels = panels,
    windows = {
      message = { x = 16, y = 168, width = 160, height = 16 },
      context = { x = 152, y = 120, width = 96, height = 64 },
      prompt = { x = 200, y = 80 },
    },
    navigation = {
      dpad = {
        default = {
          dpadBox(7, 2, 7, 1),
          dpadBox(7, 3, 0, 2),
          dpadBox(0, 4, 1, 3),
          dpadBox(1, 5, 2, 4),
          dpadBox(2, 7, 3, 5),
          dpadBox(3, 7, 4, 7),
          dpadBox(0, 0, 0, 0),
          dpadBox(5, 1, 5, 0),
        },
      },
    },
    hitboxes = {
      touch = {
        default = {
          touch(0, 48, 0, 128),
          touch(8, 56, 128, 0),
          touch(48, 96, 0, 128),
          touch(56, 104, 128, 0),
          touch(96, 144, 0, 128),
          touch(104, 152, 128, 0),
          touch(152, 192, 200, 0),
        },
      },
    },
    contextMenu = {
      topLevel = PartyPresentationFixture.manifest().contextMenu.topLevel,
      subcontext = PartyPresentationFixture.manifest().contextMenu.subcontext,
    },
  }
end

local function openParty(ready, failure, calls, screenOptions)
  local preparations = 0
  local cancels = 0
  local service = fakeService(calls)
  local measurement = {
    width = 800,
    height = 600,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 800, height = 600 },
      role = "world",
      touch = false,
    }),
    pixelRatio = 1,
    signature = "party-screen-state-test:800x600",
  }
  local state = PartyScreenState.new({
    service = service,
    manifest = sourceManifest(),
    context = screenOptions and screenOptions.context,
    item = screenOptions and screenOptions.item,
    targetPromptKey = screenOptions and screenOptions.targetPromptKey,
    initialFocus = screenOptions and screenOptions.initialFocus,
    measureDisplay = function()
      return measurement
    end,
    prepareIcons = function(_)
      preparations = preparations + 1
      return ready, failure
    end,
    cancelIconPreparation = function()
      cancels = cancels + 1
    end,
  })
  return state,
    {
      preparations = function()
        return preparations
      end,
      cancels = function()
        return cancels
      end,
    }
end

function T.give_resume_intent_waits_for_party_opening_handoff()
  local calls = { swaps = {} }
  local state = openParty(true, nil, calls, {
    context = "give_resume",
    item = { key = "SITRUS_BERRY", bagRevision = 3 },
    initialFocus = 0,
  })
  Assert.isNil(state:takeIntent(), "construction emits no continuation intent")
  for _ = 1, 15 do
    state:updateFixed({})
    state:status()
    Assert.isNil(state:takeIntent(), "opening and settling never emit the continuation")
  end
  state:updateFixed({})
  Assert.deepEqual(
    state:takeIntent(),
    { kind = "give", slot = 0, partyRevision = 1, bagRevision = 3, item = "SITRUS_BERRY" },
    "the first interactive controller update emits the pending operation"
  )
  Assert.isNil(state:takeIntent(), "the wrapper forwards the intent once")
  state:dispose()
end

function T.target_context_exposes_its_required_prompt_key()
  local item = { key = "POTION", bagRevision = 1 }
  for _, case in ipairs({
    { context = "give_target", targetPromptKey = "giveTarget", item = item },
    { context = "item_target", targetPromptKey = "useTarget", item = item },
    { context = "item_target", targetPromptKey = "teachTarget", item = item },
  }) do
    local calls = { swaps = {} }
    local state = openParty(true, nil, calls, case)
    state:updateFixed({})
    Assert.equal(state:status().targetPromptKey, case.targetPromptKey, "target status carries its source prompt identity")
    state:dispose()
  end
end

function T.target_context_rejects_missing_or_mismatched_prompt_keys()
  local item = { key = "POTION", bagRevision = 1 }
  for _, case in ipairs({
    { context = "give_target", item = item },
    { context = "give_target", targetPromptKey = "useTarget", item = item },
    { context = "item_target", item = item },
    { context = "item_target", targetPromptKey = "giveTarget", item = item },
    { context = "item_target", targetPromptKey = "unknown", item = item },
  }) do
    local ok = pcall(function()
      openParty(true, nil, { swaps = {} }, case)
    end)
    Assert.isFalse(ok, "target contexts reject missing or invalid prompt identities")
  end
end

-- Activation held while icons prepare must not select anything: the screen
-- reports pending preparation and stays there until readiness arrives.
function T.opening_waits_for_icon_preparation_before_accepting_selection()
  local calls = { swaps = {} }
  local state, _ = openParty(false, nil, calls)
  state:updateFixed({ { type = "confirm" } })
  local status = state:status()
  Assert.equal(status.preparationState, "pending", "the screen waits for icon preparation before normal input")
  Assert.isNil(status.action, "held activation never selects while preparation is pending")
  Assert.equal(#calls.swaps, 0, "no swap fires before readiness")
  state:dispose()
end

-- Closing or disposing a waiting screen drops its preparation interest
-- exactly once; a late readiness arrival cannot reopen or draw it. The
-- same exactly-once release holds for a screen disposed after readiness.
function T.closing_releases_icon_preparation_exactly_once()
  local calls = { swaps = {} }
  local state, probes = openParty(false, nil, calls)
  state:updateFixed({})
  state:dispose()
  Assert.equal(probes.cancels(), 1, "disposal cancels the outstanding preparation exactly once")
  Assert.isNil(state:takeResult(), "disposal reports no close after cancelling")
  local readyCalls = { swaps = {} }
  local readyState, readyProbes = openParty(true, nil, readyCalls)
  readyState:updateFixed({})
  readyState:dispose()
  Assert.equal(readyProbes.cancels(), 1, "disposal releases a finished preparation exactly once")
end

-- A flexible opener for composition tests: readiness may be a fixed
-- value or a flip function, the measurement comes from a live closure,
-- and per-case interface overrides replace whole resolvers.
---@param spec { ready: boolean|fun(): boolean, failure: string?, measure: fun(): table, overrides: table? }
---@param calls table<string, unknown>
local function openManual(spec, calls)
  local preparations = 0
  local cancels = 0
  local readiness = spec.ready
  local state = PartyScreenState.new({
    service = fakeService(calls),
    manifest = sourceManifest(),
    measureDisplay = spec.measure,
    prepareIcons = function(_)
      preparations = preparations + 1
      if type(readiness) == "function" then
        return readiness()
      end
      return readiness, spec.failure
    end,
    cancelIconPreparation = function()
      cancels = cancels + 1
    end,
    overrides = spec.overrides,
  })
  return state, {
    preparations = function()
      return preparations
    end,
    cancels = function()
      return cancels
    end,
    setReady = function(ready)
      readiness = ready
    end,
  }
end

local function oneDisplayTopo(width, height)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    role = "world",
    touch = false,
  })
end

local function dualTopo()
  return ScreenTopology.dualDisplay({
    id = "world",
    rect = { x = 400, y = 100, width = 256, height = 192 },
    role = "world",
    touch = false,
  }, {
    id = "aux",
    rect = { x = 100, y = 300, width = 256, height = 192 },
    role = "auxiliary",
    touch = true,
  })
end

local function displayMeasurement(width, height, topology, signature)
  return {
    width = width,
    height = height,
    topology = topology,
    pixelRatio = 1,
    signature = signature,
  }
end

---@param calls table<string, unknown>
---@param measure fun(): table
---@param overrides table<string, unknown>?
local function openOnDisplay(calls, measure, overrides)
  return openManual({ ready = true, measure = measure, overrides = overrides }, calls)
end

-- The published pane identities with their interaction flags, in plan
-- order: the single-display content plan, the shown overlay plan, and
-- the paired detail/content plan each have one exact shape.
---@param status table<string, unknown>
---@return string
local function paneSignature(status)
  local plan = assert(status.presentation, "a ready status carries its presentation plan")
  local parts = {}
  for _, pane in ipairs(assert(plan.panes, "the plan carries its panes")) do
    parts[#parts + 1] = pane.id .. (pane.interactive and "+" or "-")
  end
  return table.concat(parts, ",")
end

-- The native content geometry that must survive host composition
-- changes: panel rectangles plus the cancel target, as plain data.
---@param status table<string, unknown>
---@return table<string, unknown>
local function nativeGeometry(status)
  local plan = assert(status.presentation, "a ready status carries its presentation plan")
  local content = assert(plan.content, "the plan carries its canonical content")
  return { slotRects = content.slotRects, cancelRect = content.cancelRect }
end

---@param status table<string, unknown>
---@return table<string, unknown> the host frame of the interaction pane
local function contentPaneFrame(status)
  local plan = assert(status.presentation, "a ready status carries its presentation plan")
  for _, pane in ipairs(assert(plan.panes, "the plan carries its panes")) do
    if pane.id == "content" then
      return assert(pane.placement.frame, "the content pane carries its host frame")
    end
  end
  error("the plan carries no content pane", 0)
end

---@param x number
---@param y number
---@param pointerId string
local function tapGesture(x, y, pointerId)
  return {
    { type = "pointer_down", pointerId = pointerId, x = x, y = y },
    { type = "pointer_up", pointerId = pointerId, x = x, y = y },
  }
end

---@param state PartyScreenState
local function drainReveal(state)
  for _ = 1, 20 do
    if state:status().phase == "interactive" then
      -- The handover and its settling tick still drop input; drive only
      -- once the screen forwards.
      state:updateFixed({})
      state:updateFixed({})
      Assert.equal(state:status().phase, "interactive", "the reveal hands over on its fixed recurrence")
      return
    end
    state:updateFixed({})
  end
  Assert.equal(state:status().phase, "interactive", "the reveal hands over on its fixed recurrence")
end

-- Once preparation is ready the existing selection, swap, and close
-- behavior is unchanged. This guards current behavior through the new
-- required collaborators: it passes before and after the wait lands.
function T.ready_preparation_preserves_selection_and_close()
  local calls = { swaps = {} }
  local state, probes = openParty(true, nil, calls)
  drainReveal(state)
  state:updateFixed({ { type = "confirm" } })
  local status = state:status()
  Assert.equal(status.action, "context", "selection input works after readiness")
  Assert.equal(#calls.swaps, 0, "opening the context menu swaps nothing")
  Assert.isNil(state:takeResult(), "opening the context menu completes nothing")
  Assert.equal(probes.cancels(), 0, "nothing cancels while the screen stays open")
  state:dispose()
end

-- A single-display host menu press toggles the detail overlay without
-- touching native content: content-only, then content plus overlay, then
-- content-only again, with identical native geometry and cursor.
function T.single_display_host_menu_toggles_the_detail_overlay_without_touching_native_content()
  local calls = { swaps = {} }
  local measure = function()
    return displayMeasurement(800, 600, oneDisplayTopo(800, 600), "toggle-content:800x600")
  end
  local state, _ = openOnDisplay(calls, measure)
  state:updateFixed({})
  drainReveal(state)
  local before = state:status()
  Assert.equal(paneSignature(before), "content+", "a single-display party starts content-only")
  state:updateFixed({ { type = "menu" } })
  local shown = state:status()
  Assert.equal(
    paneSignature(shown),
    "content+,overlay-",
    "the first host menu press shows the detail overlay"
  )
  state:updateFixed({ { type = "menu" } })
  local hidden = state:status()
  Assert.equal(paneSignature(hidden), "content+", "the second host menu press hides it again")
  Assert.deepEqual(
    nativeGeometry(shown),
    nativeGeometry(before),
    "showing the overlay changes no native geometry"
  )
  Assert.deepEqual(
    nativeGeometry(hidden),
    nativeGeometry(before),
    "hiding the overlay restores the exact native geometry"
  )
  Assert.equal(hidden.cursorNode, before.cursorNode, "the toggle never drives native selection")
  Assert.equal(hidden.action, "browse", "the toggle never starts a native action")
  Assert.isNil(state:takeResult(), "toggling completes nothing")
  state:dispose()
end

-- The toggle consumes only its own menu event: navigation around it
-- lands exactly as it would without the toggle, in either order.
function T.toggle_consumes_only_the_menu_event_and_keeps_batch_order()
  local function openNative()
    local calls = { swaps = {} }
    local measure = function()
      return displayMeasurement(800, 600, oneDisplayTopo(800, 600), "toggle-order:800x600")
    end
    return openOnDisplay(calls, measure)
  end
  local first, _ = openNative()
  first:updateFixed({})
  drainReveal(first)
  first:updateFixed({ { type = "navigate", direction = "down" }, { type = "menu" } })
  local reference, _ = openNative()
  reference:updateFixed({})
  drainReveal(reference)
  reference:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(
    first:status().cursorNode,
    reference:status().cursorNode,
    "navigation before the toggle lands identically"
  )
  Assert.equal(
    paneSignature(first:status()),
    "content+,overlay-",
    "a trailing toggle still shows the overlay"
  )
  local leading, _ = openNative()
  leading:updateFixed({})
  drainReveal(leading)
  leading:updateFixed({ { type = "menu" }, { type = "navigate", direction = "down" } })
  Assert.equal(
    leading:status().cursorNode,
    reference:status().cursorNode,
    "navigation after the toggle lands identically"
  )
  Assert.equal(
    paneSignature(leading:status()),
    "content+,overlay-",
    "a leading toggle still shows the overlay"
  )
  first:dispose()
  reference:dispose()
  leading:dispose()
end

-- A host menu press while a context menu is open changes only overlay
-- visibility: the open menu keeps its entries, focus, and pending state.
function T.host_menu_during_an_open_context_menu_changes_only_visibility()
  local calls = { swaps = {} }
  local measure = function()
    return displayMeasurement(800, 600, oneDisplayTopo(800, 600), "toggle-context:800x600")
  end
  local state, _ = openOnDisplay(calls, measure)
  state:updateFixed({})
  drainReveal(state)
  state:updateFixed({ { type = "confirm" } })
  local opened = state:status()
  Assert.equal(opened.action, "context", "confirming a slot opens the context menu")
  local menuIndex = opened.menuIndex
  local menuCount = opened.menu ~= nil and #opened.menu or 0
  Assert.isTrue(menuCount >= 2, "the open menu carries its entries")
  state:updateFixed({ { type = "menu" } })
  local shown = state:status()
  Assert.equal(
    paneSignature(shown),
    "content+,overlay-",
    "the host menu press shows the overlay above the open menu"
  )
  Assert.equal(shown.action, "context", "the toggle never advances the native menu")
  Assert.equal(shown.menuIndex, menuIndex, "the toggle keeps native menu focus")
  Assert.isTrue(shown.menu ~= nil and #shown.menu == menuCount, "the toggle keeps every menu entry")
  state:updateFixed({ { type = "menu" } })
  local hidden = state:status()
  Assert.equal(paneSignature(hidden), "content+", "toggling off returns to content-only")
  Assert.equal(hidden.action, "context", "hiding the overlay leaves the native menu open")
  Assert.equal(hidden.menuIndex, menuIndex, "hiding the overlay keeps native menu focus")
  state:dispose()
end

-- A visible overlay never steals pointer input: the same tap on the
-- native pane drives the identical controller target whether the overlay
-- is shown or not, and native content carries no host target.
function T.visible_overlay_keeps_pointer_input_on_native_content()
  local function openNative()
    local calls = { swaps = {} }
    local measure = function()
      return displayMeasurement(800, 600, oneDisplayTopo(800, 600), "toggle-pointer:800x600")
    end
    return openOnDisplay(calls, measure)
  end
  local shown, _ = openNative()
  shown:updateFixed({})
  drainReveal(shown)
  shown:updateFixed({ { type = "menu" } })
  Assert.equal(
    paneSignature(shown:status()),
    "content+,overlay-",
    "the overlay under test is actually visible"
  )
  for _, pane in
    ipairs(assert(shown:status().presentation.panes, "the shown plan carries its panes"))
  do
    if pane.id == "overlay" then
      Assert.isFalse(pane.interactive, "the visible overlay takes no pointer input")
    end
  end
  local plain, _ = openNative()
  plain:updateFixed({})
  drainReveal(plain)
  local frame = contentPaneFrame(plain:status())
  local x = frame.x + frame.width / 2
  local y = frame.y + frame.height / 2
  shown:updateFixed(tapGesture(x, y, "touch:overlay-tap"))
  plain:updateFixed(tapGesture(x, y, "touch:overlay-tap"))
  local shownStatus = shown:status()
  local plainStatus = plain:status()
  Assert.equal(
    shownStatus.cursorNode,
    plainStatus.cursorNode,
    "the same tap selects the same native target under the overlay"
  )
  Assert.equal(
    shownStatus.action,
    plainStatus.action,
    "the same tap starts the same native action under the overlay"
  )
  Assert.isNil(
    shownStatus.presentation.content.infoRect,
    "native content carries no host target"
  )
  shown:dispose()
  plain:dispose()
end

-- Wide, tall, and dual-display compositions always keep both panes: the
-- host menu press changes neither the paired layout nor native state.
function T.paired_layouts_keep_both_panes_when_the_host_menu_arrives()
  local cases = {
    {
      name = "wide",
      width = 1280,
      height = 720,
      topology = function()
        return oneDisplayTopo(1280, 720)
      end,
    },
    {
      name = "tall",
      width = 600,
      height = 1000,
      topology = function()
        return oneDisplayTopo(600, 1000)
      end,
    },
    {
      name = "dual",
      width = 800,
      height = 600,
      topology = dualTopo,
    },
  }
  for _, case in ipairs(cases) do
    local calls = { swaps = {} }
    local measure = function()
      return displayMeasurement(case.width, case.height, case.topology(), "paired:" .. case.name)
    end
    local state, _ = openOnDisplay(calls, measure)
    state:updateFixed({})
    local before = state:status()
    Assert.equal(
      paneSignature(before),
      "detail-,content+",
      "the " .. case.name .. " party pairs detail with content"
    )
    state:updateFixed({ { type = "menu" } })
    local after = state:status()
    Assert.equal(
      paneSignature(after),
      "detail-,content+",
      "the host menu press never hides paired detail on " .. case.name
    )
    Assert.equal(
      after.cursorNode,
      before.cursorNode,
      "the ignored press moves no paired cursor on " .. case.name
    )
    Assert.equal(after.action, before.action, "the ignored press starts nothing on " .. case.name)
    Assert.isTrue(after.open, "the ignored press closes nothing on " .. case.name)
    Assert.isNil(state:takeResult(), "the ignored press completes nothing on " .. case.name)
    state:dispose()
  end
end

-- A per-case composition without party panes never arms the toggle: the
-- host menu press flows through without changing the custom plan.
function T.custom_compositions_without_party_panes_ignore_the_host_menu()
  local PartyScreenInterface = require("game.hgss.src.field.PartyScreenInterface")
  local interfaces = PartyScreenInterface.defaults(sourceManifest())
  local selection = require("libs.ui.src.ApplicationLayout").selectSurfaces(
    displayMeasurement(800, 600, oneDisplayTopo(800, 600), "custom-placement:800x600")
  )
  local stolen = interfaces.nativeLike({
    measurement = displayMeasurement(800, 600, oneDisplayTopo(800, 600), "custom-placement:800x600"),
    configuration = "nativeLike",
    primary = selection.primary,
    secondary = selection.secondary,
    nativeLikeInterface = interfaces.nativeLike,
  }, { cancellable = true, cursorNode = 0 }).panes[1].placement
  local calls = { swaps = {} }
  local measure = function()
    return displayMeasurement(800, 600, oneDisplayTopo(800, 600), "custom-toggle:800x600")
  end
  local state, _ = openOnDisplay(calls, measure, {
    nativeLike = function(_, _)
      return {
        panes = { { id = "custom", placement = stolen, interactive = true } },
        frames = {},
        content = {},
        inputKey = "party-custom",
        render = function(_, _, _) end,
        mapInput = function(event, _, _)
          return event
        end,
      }
    end,
  })
  state:updateFixed({})
  Assert.equal(paneSignature(state:status()), "custom+", "the override supplies the whole plan")
  local cursorBefore = state:status().cursorNode
  state:updateFixed({ { type = "menu" } })
  local after = state:status()
  Assert.equal(paneSignature(after), "custom+", "the host menu press keeps the custom plan")
  Assert.equal(after.cursorNode, cursorBefore, "the host menu press moves no custom cursor")
  Assert.isTrue(after.open, "the host menu press closes no custom composition")
  state:dispose()
end

-- The toggle waits for icon readiness: menu presses while preparation is
-- pending or failed never arm an overlay, and readiness starts clean.
function T.detail_toggle_waits_for_icon_readiness()
  local ready = false
  local pendingCalls = { swaps = {} }
  local pendingMeasure = function()
    return displayMeasurement(800, 600, oneDisplayTopo(800, 600), "toggle-readiness:800x600")
  end
  local pending, _ = openManual({
    ready = function()
      return ready
    end,
    measure = pendingMeasure,
  }, pendingCalls)
  pending:updateFixed({ { type = "menu" } })
  local waiting = pending:status()
  Assert.equal(waiting.preparationState, "pending", "a pending screen reports its wait")
  Assert.isNil(waiting.presentation, "a pending screen publishes no overlay plan")
  ready = true
  pending:updateFixed({})
  local clean = pending:status()
  Assert.equal(clean.preparationState, "ready", "readiness arrives normally after the wait")
  Assert.equal(
    paneSignature(clean),
    "content+",
    "a menu press during the wait arms no overlay"
  )
  drainReveal(pending)
  pending:updateFixed({ { type = "menu" } })
  Assert.equal(
    paneSignature(pending:status()),
    "content+,overlay-",
    "the toggle works once preparation is ready"
  )
  pending:dispose()
  local failedCalls = { swaps = {} }
  local failedMeasure = function()
    return displayMeasurement(800, 600, oneDisplayTopo(800, 600), "toggle-failed:800x600")
  end
  local failed, _ = openManual({ ready = false, failure = "icons unavailable", measure = failedMeasure }, failedCalls)
  failed:updateFixed({ { type = "menu" } })
  local failedStatus = failed:status()
  Assert.equal(failedStatus.preparationState, "failed", "a failed screen reports its failure")
  Assert.isNil(failedStatus.presentation, "a failed screen publishes no overlay plan")
  failed:dispose()
end

-- Reflow and disposal drop only host state: a held press is cancelled
-- across measurement changes, the controller survives, returning to a
-- single-display plan stays valid, and disposal releases exactly once.
function T.reflow_and_disposal_drop_only_host_state()
  local calls = { swaps = {} }
  local current = displayMeasurement(800, 600, oneDisplayTopo(800, 600), "toggle-reflow:native")
  local state, probes = openOnDisplay(calls, function()
    return current
  end)
  state:updateFixed({})
  drainReveal(state)
  state:updateFixed({ { type = "menu" } })
  Assert.equal(
    paneSignature(state:status()),
    "content+,overlay-",
    "the overlay under test is actually visible"
  )
  local frame = contentPaneFrame(state:status())
  local x = frame.x + frame.width / 2
  local y = frame.y + frame.height / 2
  state:updateFixed({ { type = "pointer_down", pointerId = "touch:held", x = x, y = y } })
  local held = state:status()
  current = displayMeasurement(1280, 720, oneDisplayTopo(1280, 720), "toggle-reflow:wide")
  state:updateFixed({})
  local reflowed = state:status()
  Assert.equal(
    paneSignature(reflowed),
    "detail-,content+",
    "reflow presents the paired layout normally"
  )
  Assert.isTrue(reflowed.open, "reflow closes nothing")
  state:updateFixed({ { type = "pointer_up", pointerId = "touch:held", x = x, y = y } })
  local settled = state:status()
  Assert.isTrue(settled.open, "a stale release after reflow closes nothing")
  Assert.isNil(state:takeResult(), "a stale release after reflow completes nothing")
  Assert.equal(settled.action, held.action, "a stale release after reflow starts nothing")
  Assert.equal(settled.cursorNode, held.cursorNode, "a stale release after reflow moves nothing")
  current = displayMeasurement(800, 600, oneDisplayTopo(800, 600), "toggle-reflow:back")
  state:updateFixed({})
  local signature = paneSignature(state:status())
  Assert.isTrue(
    signature == "content+" or signature == "content+,overlay-",
    "returning to single-display stays a valid native-like plan"
  )
  Assert.equal(state:status().cursorNode, held.cursorNode, "reflow moves no native cursor")
  state:dispose()
  state:dispose()
  Assert.equal(probes.cancels(), 1, "double disposal releases preparation exactly once")
  Assert.isNil(state:takeResult(), "disposal reports no close after cancelling")
end

-- After icon readiness the screen reveals through a fixed wipe before
-- accepting input: the first pane advances six steps while the second
-- stays covered, then the second advances six steps while the first stays
-- clear. Status publishes the integer progress both panes render from,
-- and the recurrence is identical on single and paired topologies.
function T.opening_reveals_first_pane_before_second_over_six_steps_each()
  local cases = {
    { name = "single", width = 800, height = 600, topology = oneDisplayTopo(800, 600) },
    { name = "dual", width = 800, height = 600, topology = dualTopo() },
  }
  for _, case in ipairs(cases) do
    local calls = { swaps = {} }
    local measure = function()
      return displayMeasurement(case.width, case.height, case.topology, "opening-order:" .. case.name)
    end
    local state, _ = openOnDisplay(calls, measure)
    state:updateFixed({})
    local ready = state:status()
    Assert.equal(ready.phase, "opening", "the " .. case.name .. " party reveals before accepting input")
    Assert.notNil(ready.opening, "the " .. case.name .. " party publishes its reveal progress")
    local opening = assert(ready.opening, "the " .. case.name .. " party publishes its reveal progress")
    Assert.equal(opening.subStep, 0, "the " .. case.name .. " reveal starts fully covered")
    Assert.equal(opening.mainStep, 0, "the " .. case.name .. " reveal starts fully covered")
    local trajectory = {}
    for _ = 1, 12 do
      state:updateFixed({})
      local now = state:status()
      Assert.equal(now.phase, "opening", "the " .. case.name .. " reveal holds until both panes clear")
      local progress = assert(now.opening, "the " .. case.name .. " reveal keeps publishing progress")
      trajectory[#trajectory + 1] = { sub = progress.subStep, main = progress.mainStep }
    end
    local expected = {}
    for step = 1, 6 do
      expected[#expected + 1] = { sub = step, main = 0 }
    end
    for step = 1, 6 do
      expected[#expected + 1] = { sub = 6, main = step }
    end
    Assert.deepEqual(trajectory, expected, "the " .. case.name .. " reveal covers the first pane before the second")
    state:updateFixed({})
    local interactive = state:status()
    Assert.equal(interactive.phase, "interactive", "the " .. case.name .. " reveal hands over after twelve steps")
    Assert.isNil(interactive.opening, "the handover carries no residual cover")
    state:dispose()
  end
end

-- Navigation, activation, and dismissal sent while the panes are still
-- covered have no effect and are never replayed: the cursor, menu state,
-- and result stay untouched until the reveal completes, and only input
-- sent after the handover acts.
function T.opening_discards_navigation_and_activation_until_reveal_completes()
  local calls = { swaps = {} }
  local state, _ = openParty(true, nil, calls)
  state:updateFixed({})
  Assert.equal(state:status().phase, "opening", "the party reveals before accepting input")
  local cursorBefore = state:status().cursorNode
  local batches = {
    { { type = "navigate", direction = "down" } },
    { { type = "confirm" } },
    { { type = "navigate", direction = "right" } },
    { { type = "cancel" } },
    { { type = "navigate", direction = "up" } },
    { { type = "confirm" } },
    { { type = "navigate", direction = "left" } },
    { { type = "cancel" } },
    { { type = "navigate", direction = "down" } },
    { { type = "confirm" } },
    { { type = "navigate", direction = "down" } },
    { { type = "cancel" } },
    {},
  }
  for _, batch in ipairs(batches) do
    state:updateFixed(batch)
  end
  local settled = state:status()
  Assert.equal(settled.phase, "interactive", "the reveal completes on its fixed recurrence")
  Assert.equal(settled.cursorNode, cursorBefore, "reveal navigation never moves the cursor")
  Assert.equal(settled.action, "browse", "reveal activation never leaves browse")
  Assert.isNil(state:takeResult(), "reveal dismissal completes nothing")
  Assert.equal(#calls.swaps, 0, "reveal input swaps nothing")
  state:updateFixed({})
  Assert.equal(
    state:status().action,
    "browse",
    "discarded input is never replayed on the first interactive tick"
  )
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:status().action, "context", "only post-reveal input acts")
  Assert.isNil(state:takeResult(), "opening the context menu completes nothing")
  state:dispose()
end

-- Closing keeps its existing meaning once the screen is interactive:
-- confirming Cancel promptly reports the host close with no additional
-- reveal behavior on the way out.
function T.closing_after_interactive_uses_the_existing_close_path()
  local calls = { swaps = {} }
  local state, probes = openParty(true, nil, calls)
  for _ = 1, 20 do
    local status = state:status()
    if status.phase == "interactive" then
      break
    end
    if status.phase == nil and status.preparationState == "ready" then
      break
    end
    state:updateFixed({})
  end
  for _ = 1, 8 do
    if state:status().cursorNode == "cancel" then
      break
    end
    state:updateFixed({ { type = "navigate", direction = "up" } })
  end
  Assert.equal(state:status().cursorNode, "cancel", "navigation reaches cancel before closing")
  state:updateFixed({ { type = "confirm" } })
  local result = state:takeResult()
  Assert.notNil(result, "confirming cancel closes the screen")
  Assert.equal(result.kind, "close", "close keeps its existing host translation")
  local closed = state:status()
  Assert.isTrue(
    closed.phase == nil or closed.phase ~= "closing",
    "closing adds no reveal behavior on the way out"
  )
  Assert.isNil(state:takeResult(), "a second take reports nothing further")
  Assert.equal(probes.cancels(), 1, "closing releases the preparation interest exactly once")
  state:dispose()
end

return { tests = T }
