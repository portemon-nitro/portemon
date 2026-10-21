-- Gear shell entry, card locks, strip focus, and lifecycle: opening chooses
-- the remembered application with a locked-card fallback to the setup card,
-- a scripted call forces the phone card, fixed strip slots never repack,
-- keyboard focus walks only available slots with wrap, taps switch cards
-- while same-tab, gap, and transparent-corner taps do nothing, the confirm
-- edge re-enters the selected card, two cancels close exactly once and
-- remember the last card, transitions settle without stranding resources,
-- a failed child acquisition keeps the previous owner, and repeated status
-- reads never tick clocks, animations, or draw streams.

local Assert = require("tests.support.Assert")
local LocalClock = require("game.src.LocalClock")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearCalendar = require("game.hgss.src.pokegear.PokegearCalendar")
local PokegearState = require("libs.hgss.src.save.PokegearState")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

-- Loads a shell module that does not exist yet at this baseline. The
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
---@return table
local function visualRef(path)
  return { image = path, width = 32, height = 32, anchorX = 0, anchorY = 0 }
end

-- Synthetic companion catalog with two contacts and one marked location,
-- validated through the real asset schema so the shell tests borrow only
-- genuine semantic references.
---@return table
local function fixtureManifest()
  return {
    schema = "g4-pokegear-assets-v2",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png") },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png") },
    phone = { panel = visualRef("assets/generated/pokegear/phone-panel.png") },
    map = { base = visualRef("assets/generated/pokegear/map-base.png") },
    fly = { base = visualRef("assets/generated/pokegear/fly-base.png") },
    radio = { dial = visualRef("assets/generated/pokegear/radio-dial.png") },
    catalog = {
      contacts = {
        { key = "custom.elm", family = "elm", sortWeight = 10 },
        { key = "custom.mom", family = "mother", sortWeight = 20 },
      },
      contactOrder = { "custom.elm", "custom.mom" },
      callDefinitions = {},
      callTriggers = {},
      rematches = {},
      gifts = {},
      momPurchases = {},
      locations = {
        { key = "custom.new-bark" },
      },
      flypoints = {},
      regionMap = require("tests.support.PokegearRegionMapFixture").build(),
      reception = {},
      shows = {},
      radioEffects = {},
    },
    text = {},
    sequences = {},
  }
end

---@param record table
---@return table
local function catalogRefs(record)
  return { catalog = record.catalog }
end

-- A fresh companion bucket with every card registered and every setup skin
-- unlocked, so strip tests start from the full four-card shell.
---@param record table
---@return table
local function fullCardState(record)
  local state = PokegearState.new(nil, catalogRefs(record))
  state:registerCard("map")
  state:registerCard("radio")
  state:setPreference("unlockedSkins", { 0, 1, 2, 3, 4, 5 })
  return state
end

-- A companion bucket with only the always-available cards: the setup card
-- plus phone. Map and radio slots stay present but masked blank.
---@param record table
---@return table
local function baseCardState(record)
  local state = PokegearState.new(nil, catalogRefs(record))
  state:setPreference("unlockedSkins", { 0, 1, 2, 3, 4, 5 })
  return state
end

---@param moment table
---@return table
local function civilSample(moment)
  local clock = LocalClock.new(function()
    return {
      year = moment.year,
      month = moment.month,
      day = moment.day,
      hour = moment.hour,
      minute = moment.minute,
      second = moment.second,
    }
  end)
  return clock:nowLocal()
end

---@param width number
---@param height number
---@param touch boolean
---@return table
local function displayFacts(width, height, touch)
  return {
    width = width,
    height = height,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = width, height = height },
      role = "world",
      touch = touch,
    }),
    pixelRatio = 1,
    signature = "pokegear-shell-test:" .. width .. "x" .. height .. (touch and ":touch" or ":keys"),
  }
end

-- Source strip geometry, kept outside the shell under test: five fixed
-- slot centers shared by every card mask, with the touch rectangles the
-- source pairs with its nonzero-pixel mask.
local SLOT_CENTERS_X = { 32, 80, 128, 176, 230 }
local SLOT_CENTER_Y = 176
local SLOT_RECTS = {
  { x0 = 8, x1 = 56 },
  { x0 = 56, x1 = 104 },
  { x0 = 104, x1 = 152 },
  { x0 = 152, x1 = 200 },
  { x0 = 206, x1 = 254 },
}
local STRIP_TOP, STRIP_BOTTOM = 160, 192

-- Closed stub child factories through the prescribed children[tab]
-- seam: each stub records construction, ticks, received events, and
-- disposal, and reports a calm idle status. Test-only fakes at the host
-- boundary; production registration stays gated until real cards land.
---@param log table
---@param options table<string, unknown>?
---@return table<string, fun(context: table): table>
local function stubChildren(log, options)
  options = options or {}
  local failTab = options.failTab --[[@as string?]]
  local failOnBuild = options.failOnBuild --[[@as integer?]]
  local builds = {}
  local children = {}
  for _, tab in ipairs({ "configure", "radio", "map", "phone" }) do
    builds[tab] = 0
    children[tab] = function(context)
      builds[tab] = builds[tab] + 1
      log.builds[#log.builds + 1] = tab .. "#" .. builds[tab]
      if failTab == tab and builds[tab] == (failOnBuild or 1) then
        error("stub " .. tab .. " acquisition failed", 0)
      end
      assert(type(context) == "table", "child factories receive a context record")
      local child = {
        tab = tab,
        updates = 0,
        disposes = 0,
        events = {},
        disposed = false,
      }
      function child:updateFixed(mapped)
        assert(not self.disposed, "a disposed card steps nothing")
        self.updates = self.updates + 1
        for _, event in ipairs(assert(mapped, "card input must be an event list")) do
          self.events[#self.events + 1] = event.type
        end
      end
      function child:status()
        return { open = true, tab = tab, busy = false, dismissible = true }
      end
      function child:takeResult()
        return nil
      end
      function child:dispose()
        if not self.disposed then
          self.disposed = true
          self.disposes = self.disposes + 1
          log.disposals[#log.disposals + 1] = tab
        end
      end
      log.children[tab] = child
      return child
    end
  end
  return children
end

---@return table
local function freshLog()
  return { builds = {}, disposals = {}, children = {}, effects = {} }
end

-- Opens the real shell against stub cards. Fails naming the missing shell
-- behaviour while the shell modules are absent.
---@param params table
---@return table box { shell: table, state: table, record: table, log: table, box: table, moment: table }
local function openShell(params)
  local PokegearScreenState = requireFeature(
    "game.hgss.src.pokegear.PokegearScreenState",
    "the gear shell has no screen owner yet: entry, card locks, strip focus, and remembered cards are unavailable"
  )
  local PokegearInterface = requireFeature(
    "game.hgss.src.pokegear.PokegearInterface",
    "the gear shell has no presentation owner yet: matched information/controls plans and pointer mapping are unavailable"
  )
  local record = PokegearAssetSchema.validate(params.manifest or fixtureManifest())
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local state = params.state or fullCardState(record)
  local log = params.log or freshLog()
  local box = { facts = params.facts or displayFacts(512, 192, params.touch ~= false) }
  local moment = params.moment or { year = 2024, month = 5, day = 6, hour = 12, minute = 34, second = 56 }
  local clock = LocalClock.new(function()
    return {
      year = moment.year,
      month = moment.month,
      day = moment.day,
      hour = moment.hour,
      minute = moment.minute,
      second = moment.second,
    }
  end)
  local shell = PokegearScreenState.new({
    state = state,
    assets = record,
    clock = clock,
    children = params.children or stubChildren(log, params.childOptions),
    presentation = PokegearInterface.defaults(),
    effect = function(sequence)
      assert(type(sequence) == "string" and sequence ~= "", "shell sound effects name a sequence")
      log.effects[#log.effects + 1] = sequence
    end,
    entry = params.entry or { kind = "browse" },
    measureDisplay = function()
      return box.facts
    end,
  })
  return { shell = shell, state = state, record = record, log = log, box = box, moment = moment }
end

-- Ticks empty batches until the shell reports a settled transition or the
-- bound is reached. Transition length is source behaviour; the bound only
-- guards against a stuck shell.
---@param shell table
---@param limit integer?
local function settle(shell, limit)
  for _ = 1, limit or 120 do
    local status = shell:status()
    local transition = status.transition
    if transition == nil or transition.completed == true then
      return
    end
    shell:updateFixed({})
  end
  local transition = shell:status().transition
  Assert.isTrue(transition == nil or transition.completed == true, "the shell transition must settle within its bound")
end

---@param status table
---@return table
local function controlsPane(status)
  local plan = assert(status.presentation, "the shell publishes its presentation plan")
  for _, pane in ipairs(assert(plan.panes, "the plan carries its panes")) do
    if pane.id == "controls" then
      return pane
    end
  end
  error("the shell plan must carry the controls pane", 0)
end

-- Maps one source-local controls point to host units through the published
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

---@param shell table
---@param slotIndex integer
---@return number x
---@return number y
local function slotCenter(shell, slotIndex)
  local placement = assert(controlsPane(shell:status()).placement, "the controls pane carries its placement")
  local frame = placement.frame
  local scale = placement.scale
  Assert.near(frame.width / scale, 256, 1e-6, "the controls surface keeps its 256-wide source geometry")
  Assert.near(frame.height / scale, 192, 1e-6, "the controls surface keeps its 192-tall source geometry")
  return toHost(placement, SLOT_CENTERS_X[slotIndex], SLOT_CENTER_Y)
end

---@param shell table
---@param x number
---@param y number
local function tap(shell, x, y)
  shell:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  shell:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y } })
end

---@param shell table
---@param event table
local function press(shell, event)
  shell:updateFixed({ event })
end

-- Taps every fixed slot center and records the per-slot outcome. The
-- slot-to-card mapping itself is source behaviour under test, so the test
-- learns it by tapping rather than asserting an invented order.
---@param shell table
---@return table outcomes { tab: string, switched: boolean }[5]
local function learnSlots(shell)
  local outcomes = {}
  for slot = 1, 4 do
    local x, y = slotCenter(shell, slot)
    local before = shell:status().tab
    local effectsBefore = 0
    tap(shell, x, y)
    settle(shell)
    local after = shell:status().tab
    outcomes[slot] = { tab = after, switched = after ~= before }
  end
  return outcomes
end

-- Finds a slot whose tap switches to a card different from the current
-- one. The mapping itself is learned, never invented.
---@param shell table
---@param outcomes table
---@param avoid string?
---@return integer slot
local function switchSlot(shell, outcomes, avoid)
  local current = shell:status().tab
  for slot, outcome in ipairs(outcomes) do
    if outcome.switched and outcome.tab ~= current and outcome.tab ~= avoid then
      return slot
    end
  end
  error("no switching slot leaves " .. tostring(current), 0)
end

function T.tests.fixed_strip_slots_focus_and_remembered_cards()
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")

  -- Every remembered card opens directly; the fresh save defaults to phone.
  for _, remembered in ipairs({ "phone", "map", "radio", "configure" }) do
    local state = fullCardState(record)
    state:setPreference("lastApp", remembered)
    local opened = openShell({ state = state, manifest = fixtureManifest() })
    settle(opened.shell)
    Assert.equal(opened.shell:status().tab, remembered, "opening remembers " .. remembered)
    Assert.equal(opened.shell:status().focus, remembered, "strip focus starts on the remembered card")
    opened.shell:dispose()
  end
  do
    local fresh = PokegearState.new(nil, catalogRefs(record))
    Assert.equal(fresh:readPreferences().lastApp, "phone", "the initial save defaults to phone")
  end

  -- A remembered card lost to a save edit falls back to the setup card.
  do
    local state = baseCardState(record)
    state:setPreference("lastApp", "map")
    local opened = openShell({ state = state, manifest = fixtureManifest() })
    settle(opened.shell)
    Assert.equal(opened.shell:status().tab, "configure", "an unavailable remembered card opens the setup card")
    opened.shell:dispose()
  end

  -- A scripted call forces the phone card even when setup was remembered.
  do
    local state = fullCardState(record)
    state:setPreference("lastApp", "configure")
    local opened = openShell({ state = state, manifest = fixtureManifest(), entry = { kind = "call" } })
    settle(opened.shell)
    Assert.equal(opened.shell:status().tab, "phone", "a scripted call forces the phone card")
    opened.shell:dispose()
  end

  local host = openShell({ manifest = fixtureManifest() })
  settle(host.shell)
  local mapping = learnSlots(host.shell)
  local reached = { phone = true }
  for _, outcome in ipairs(mapping) do
    if outcome.switched then
      reached[outcome.tab] = true
    end
  end
  for _, tab in ipairs({ "configure", "radio", "map", "phone" }) do
    Assert.isTrue(reached[tab], "every card answers its fixed slot: " .. tab)
  end
  do
    local effectsBefore = #host.log.effects
    local current = host.shell:status().tab
    local targetSlot = nil
    for slot, outcome in ipairs(mapping) do
      if outcome.switched and outcome.tab ~= current then
        targetSlot = slot
        break
      end
    end
    if targetSlot ~= nil then
      local x, y = slotCenter(host.shell, targetSlot)
      tap(host.shell, x, y)
      settle(host.shell)
      Assert.isTrue(#host.log.effects > effectsBefore, "switching cards plays a sound")
    end
  end

  -- Locked slots never repack: available slots land on the same card as
  -- the full shell learned, while masked slots keep the current card.
  -- Outcomes compare per tap, never absolute trajectories.
  do
    local locked = openShell({ state = baseCardState(record), manifest = fixtureManifest() })
    settle(locked.shell)
    for slot = 1, 4 do
      local x, y = slotCenter(locked.shell, slot)
      local beforeTap = locked.shell:status().tab
      tap(locked.shell, x, y)
      settle(locked.shell)
      local fullTab = mapping[slot].tab
      local fullSwitched = mapping[slot].switched
      if fullSwitched and (fullTab == "configure" or fullTab == "phone") then
        Assert.equal(locked.shell:status().tab, fullTab, "available slot " .. slot .. " keeps its fixed mapping")
      else
        Assert.equal(
          locked.shell:status().tab,
          beforeTap,
          "masked or blank slot " .. slot .. " never enters a locked card"
        )
      end
    end
    locked.shell:dispose()
  end

  -- Same-tab taps do nothing: no sound, no transition, no child churn.
  do
    local current = host.shell:status().tab
    local slot = nil
    for index, outcome in ipairs(mapping) do
      if outcome.switched and outcome.tab == current then
        slot = index
        break
      end
    end
    if slot == nil then
      for index, outcome in ipairs(mapping) do
        if outcome.tab == current then
          slot = index
          break
        end
      end
    end
    assert(slot ~= nil, "the current card owns a fixed slot")
    local x, y = slotCenter(host.shell, slot)
    local effectsBefore = #host.log.effects
    local buildsBefore = #host.log.builds
    tap(host.shell, x, y)
    Assert.equal(host.shell:status().tab, current, "a same-tab tap keeps the card")
    Assert.equal(#host.log.effects, effectsBefore, "a same-tab tap plays no sound")
    Assert.equal(#host.log.builds, buildsBefore, "a same-tab tap builds no child")
    local transition = host.shell:status().transition
    Assert.isTrue(transition == nil or transition.completed == true, "a same-tab tap starts no transition")
  end

  -- Blank strip pixels do nothing: the gap between the fourth and fifth
  -- zones, a row above the strip, and the transparent extreme corners of
  -- every tab rectangle (rounded source cells leave rect corners empty;
  -- rectangle entry alone must not switch).
  do
    local effectsBefore = #host.log.effects
    local current = host.shell:status().tab
    local placement = assert(controlsPane(host.shell:status()).placement, "the controls pane is published")
    local gapX, gapY = toHost(placement, 203, 176)
    tap(host.shell, gapX, gapY)
    local aboveX, aboveY = toHost(placement, 128, 150)
    tap(host.shell, aboveX, aboveY)
    for _, rect in ipairs(SLOT_RECTS) do
      local cornerX, cornerY = toHost(placement, rect.x0 + 1, STRIP_TOP + 1)
      tap(host.shell, cornerX, cornerY)
      local farX, farY = toHost(placement, rect.x1 - 1, STRIP_BOTTOM - 1)
      tap(host.shell, farX, farY)
    end
    Assert.equal(host.shell:status().tab, current, "blank and transparent strip pixels keep the card")
    Assert.equal(#host.log.effects, effectsBefore, "blank and transparent strip pixels play no sound")
    Assert.isNil(host.shell:takeResult(), "ignored taps produce no result")
  end

  -- Keyboard focus walks only available slots with wrap, and the confirmed
  -- card follows focus. Focus is a semantic card identity, never a number.
  -- Directional input on the strip never leaks into the parked card: the
  -- strip owns its keys, the child owns only in-card input.
  do
    local keys = openShell({
      state = baseCardState(record),
      manifest = fixtureManifest(),
      touch = false,
    })
    settle(keys.shell)
    press(keys.shell, { type = "cancel" })
    Assert.isNil(keys.shell:takeResult(), "the first cancel returns focus without closing")
    local seen = {}
    for _ = 1, 8 do
      press(keys.shell, { type = "navigate", direction = "right" })
      local focus = keys.shell:status().focus
      Assert.isTrue(type(focus) == "string", "strip focus is a semantic card identity")
      seen[#seen + 1] = focus
    end
    local reachedSet = {}
    for _, focus in ipairs(seen) do
      reachedSet[focus] = true
    end
    Assert.isTrue(reachedSet.configure, "keyboard focus reaches the setup card")
    Assert.isTrue(reachedSet.phone, "keyboard focus reaches the phone card")
    for _, focus in ipairs(seen) do
      Assert.isTrue(focus == "configure" or focus == "phone", "keyboard focus skips masked slots")
    end
    local period = nil
    for candidate = 1, #seen do
      local wraps = true
      for index = 1, #seen - candidate do
        if seen[index] ~= seen[index + candidate] then
          wraps = false
          break
        end
      end
      if wraps then
        period = candidate
        break
      end
    end
    Assert.equal(period, 2, "strip focus wraps over exactly the two available slots")
    local parked = assert(keys.log.children.phone, "the parked phone card exists")
    for _, eventType in ipairs(parked.events) do
      Assert.isTrue(eventType ~= "navigate", "strip keys never leak into the parked card")
    end
    -- One new press advances exactly one slot: no held-key repeat globally.
    local first = keys.shell:status().focus
    press(keys.shell, { type = "navigate", direction = "right" })
    Assert.isTrue(keys.shell:status().focus ~= first, "one press advances strip focus")
    -- Confirming the focused card enters it.
    local focus = keys.shell:status().focus
    press(keys.shell, { type = "confirm" })
    settle(keys.shell)
    Assert.equal(keys.shell:status().tab, focus, "confirming strip focus enters that card")
    -- Confirming the already selected card re-enters it audibly.
    local effectsBefore = #keys.log.effects
    press(keys.shell, { type = "confirm" })
    Assert.equal(keys.shell:status().tab, focus, "re-confirming the selected card keeps it")
    Assert.isTrue(#keys.log.effects > effectsBefore, "re-confirming the selected card answers audibly")
    local entered = assert(keys.log.children[focus], "the entered card exists")
    local heardConfirm = false
    for _, eventType in ipairs(entered.events) do
      if eventType == "confirm" then
        heardConfirm = true
      end
    end
    Assert.isTrue(heardConfirm, "the entered card receives the reselect confirm")
    keys.shell:dispose()
  end

  -- Two cancels close exactly once and remember the actual last card.
  do
    local closer = openShell({ manifest = fixtureManifest() })
    settle(closer.shell)
    local targetSlot = nil
    for slot, outcome in ipairs(mapping) do
      if outcome.switched and outcome.tab ~= closer.shell:status().tab then
        targetSlot = slot
        break
      end
    end
    assert(targetSlot ~= nil, "a switch target exists")
    local x, y = slotCenter(closer.shell, targetSlot)
    tap(closer.shell, x, y)
    settle(closer.shell)
    local entered = closer.shell:status().tab
    press(closer.shell, { type = "cancel" })
    Assert.isNil(closer.shell:takeResult(), "the first cancel returns focus without closing")
    press(closer.shell, { type = "cancel" })
    local result = assert(closer.shell:takeResult(), "the second cancel closes the shell")
    Assert.equal(result.kind, "close", "the shell only returns close")
    Assert.isNil(closer.shell:takeResult(), "the close is reported exactly once")
    Assert.equal(closer.state:readPreferences().lastApp, entered, "a completed exit remembers the actual last card")
    closer.shell:dispose()
  end
  host.shell:dispose()
end

function T.tests.shell_lifecycle_failure_and_non_rendering_clock()
  local PokegearScreenState = requireFeature(
    "game.hgss.src.pokegear.PokegearScreenState",
    "the gear shell has no lifecycle owner yet: acquisition, failure, disposal, and clock purity are unavailable"
  )
  assert(PokegearScreenState ~= nil, "shell lifecycle needs its screen owner")

  -- Missing collaborators fail at construction, never on first draw.
  Assert.throws(function()
    PokegearScreenState.new(nil --[[@as table]])
  end, "a shell without options fails")
  do
    local record = PokegearAssetSchema.validate(fixtureManifest())
    Assert.notNil(record, "the synthetic companion catalog must validate")
    assert(record ~= nil, "synthetic catalog validated above")
    local PokegearInterface = requireFeature(
      "game.hgss.src.pokegear.PokegearInterface",
      "the gear shell has no presentation owner yet: construction cannot validate its interface set"
    )
    Assert.throws(function()
      PokegearScreenState.new({
        state = fullCardState(record),
        assets = record,
        clock = LocalClock.new(function()
          return { year = 2024, month = 5, day = 6, hour = 12, minute = 0, second = 0 }
        end),
        presentation = PokegearInterface.defaults(),
        effect = function(_) end,
        entry = { kind = "browse" },
        measureDisplay = function()
          return displayFacts(512, 192, true)
        end,
      })
    end, "a shell without a closed child set fails")
  end

  local host = openShell({ manifest = fixtureManifest() })
  settle(host.shell)

  -- The common clock reads civil time through the injected clock: hour,
  -- minute, and the local weekday match the independent calendar oracle.
  do
    local sample = civilSample({ year = 2024, month = 5, day = 6, hour = 12, minute = 34, second = 56 })
    local clock = assert(host.shell:status().clock, "the shell publishes its clock strip")
    Assert.equal(clock.hour, 12, "the clock strip reads the injected hour")
    Assert.equal(clock.minute, 34, "the clock strip reads the injected minute")
    Assert.equal(
      clock.weekday,
      PokegearCalendar.weekday(sample),
      "the clock strip reads the local weekday from civil time alone"
    )
    Assert.isTrue(type(clock.signal) == "boolean", "the reception indicator is a plain flag")
  end

  -- Repeated status reads between ticks change nothing: identical
  -- snapshots, silent children, an untouched save bucket, and a frozen
  -- colon frame. Drawing must never tick the shell.
  do
    local before = host.shell:status()
    local bucket = host.state:capture()
    local updates = {}
    for _, child in pairs(host.log.children) do
      updates[child] = child.updates
    end
    for _ = 1, 5 do
      local again = host.shell:status()
      Assert.deepEqual(again, before, "status reads perform no mutation")
    end
    for child, count in pairs(updates) do
      Assert.equal(child.updates, count, "status reads never tick a child")
    end
    Assert.deepEqual(host.state:capture(), bucket, "status reads draw no random stream and write nothing")
    local colonBefore = assert(host.shell:status().clock, "the clock strip is published").colon
    host.shell:status()
    Assert.equal(
      assert(host.shell:status().clock, "the clock strip is published").colon,
      colonBefore,
      "status reads never advance the colon animation"
    )
  end

  -- The colon animation advances on source ticks, not on reads: thirty
  -- ticks move its native sequence while the wall clock stands still.
  do
    local first = assert(host.shell:status().clock, "the clock strip is published").colon
    for _ = 1, 30 do
      host.shell:updateFixed({})
    end
    local thirtieth = assert(host.shell:status().clock, "the clock strip is published").colon
    Assert.isTrue(thirtieth ~= first, "thirty source ticks advance the native colon sequence")
  end

  -- Opening and tab switches run fades to completion: coefficients are
  -- numeric while active, the strip stays published throughout, and every
  -- acquisition settles exactly once with no orphaned child.
  do
    local fresh = openShell({ manifest = fixtureManifest() })
    local opening = fresh.shell:status().transition
    Assert.notNil(opening, "opening runs a transition")
    Assert.isTrue(type(opening.coefficient) == "number", "transition coefficients are numeric")
    settle(fresh.shell)
    local outcomes = learnSlots(fresh.shell)
    local targetSlot = switchSlot(fresh.shell, outcomes)
    local x, y = slotCenter(fresh.shell, targetSlot)
    local buildsBefore = #fresh.log.builds
    tap(fresh.shell, x, y)
    local switching = fresh.shell:status().transition
    Assert.notNil(switching, "a tab switch runs a transition")
    local stripVisible = controlsPane(fresh.shell:status())
    Assert.notNil(stripVisible, "the selected strip stays published through the switch")
    settle(fresh.shell)
    Assert.equal(#fresh.log.builds, buildsBefore + 1, "a switch acquires exactly one child")
    local transition = fresh.shell:status().transition
    Assert.isTrue(transition == nil or transition.completed == true, "the switch transition completes")
    local disposals = {}
    for _, tab in ipairs(fresh.log.disposals) do
      disposals[tab] = (disposals[tab] or 0) + 1
    end
    local built = {}
    for _, build in ipairs(fresh.log.builds) do
      local tab = build:match("^(%a+)#")
      built[tab] = (built[tab] or 0) + 1
    end
    local active = fresh.shell:status().tab
    for tab, count in pairs(built) do
      Assert.equal(
        disposals[tab] or 0,
        count - (tab == active and 1 or 0),
        "every replaced " .. tab .. " child disposes exactly once"
      )
    end
    fresh.shell:dispose()
  end

  -- A failing second acquisition keeps the last valid owner: opening
  -- builds the first card, the next acquisition throws, the previous card
  -- stays active and undisposed, nothing publishes a result, and a later
  -- healthy acquisition still succeeds, proving the failure is contained.
  do
    local probe = openShell({ manifest = fixtureManifest() })
    settle(probe.shell)
    local learned = learnSlots(probe.shell)
    local mapSlot = nil
    local otherSlot = nil
    for slot, outcome in ipairs(learned) do
      if outcome.switched and outcome.tab == "map" then
        mapSlot = slot
      end
      if outcome.switched and outcome.tab ~= "map" and otherSlot == nil then
        otherSlot = slot
      end
    end
    probe.shell:dispose()
    Assert.notNil(mapSlot, "the map card answers a fixed slot")
    Assert.notNil(otherSlot, "another card answers a fixed slot")
    assert(mapSlot ~= nil and otherSlot ~= nil, "slots learned above")
    local log = freshLog()
    local failing = openShell({ manifest = fixtureManifest(), log = log, childOptions = { failTab = "map" } })
    settle(failing.shell)
    local otherTab = learned[otherSlot].tab
    local ox, oy = slotCenter(failing.shell, otherSlot)
    tap(failing.shell, ox, oy)
    settle(failing.shell)
    Assert.equal(failing.shell:status().tab, otherTab, "the healthy acquisition succeeds")
    local mapX, mapY = slotCenter(failing.shell, mapSlot)
    local ok, err = pcall(function()
      tap(failing.shell, mapX, mapY)
    end)
    Assert.isFalse(ok, "the failing acquisition raises")
    Assert.notNil(tostring(err):find("map", 1, true), "the acquisition failure names its card")
    Assert.equal(failing.shell:status().tab, otherTab, "failure keeps the last valid owner")
    Assert.isNil(failing.shell:takeResult(), "a failed switch publishes no result")
    local survivor = assert(log.children[otherTab], "the surviving card exists")
    Assert.isFalse(survivor.disposed, "failure never disposes the surviving owner")
    local radioSlot = nil
    for slot, outcome in ipairs(learned) do
      if outcome.switched and outcome.tab ~= "map" and outcome.tab ~= otherTab then
        radioSlot = slot
        break
      end
    end
    if radioSlot ~= nil then
      local rx, ry = slotCenter(failing.shell, radioSlot)
      tap(failing.shell, rx, ry)
      settle(failing.shell)
      Assert.equal(
        failing.shell:status().tab,
        learned[radioSlot].tab,
        "a later healthy acquisition succeeds after the failure"
      )
    end
    failing.shell:dispose()
  end

  -- Closing mid-transition still releases everything exactly once, both
  -- on the opening fade and on a tab-switch fade.
  do
    local rushed = openShell({ manifest = fixtureManifest() })
    Assert.notNil(rushed.shell:status().transition, "the opening fade is a transition")
    press(rushed.shell, { type = "cancel" })
    press(rushed.shell, { type = "cancel" })
    local opened = assert(rushed.shell:takeResult(), "a close during opening still reports")
    Assert.equal(opened.kind, "close", "the rushed close only returns close")
    rushed.shell:dispose()
    Assert.equal(#rushed.log.disposals, 1, "the rushed open releases its single child")
  end
  do
    local probe = openShell({ manifest = fixtureManifest() })
    settle(probe.shell)
    local learned = learnSlots(probe.shell)
    probe.shell:dispose()
    local rushed = openShell({ manifest = fixtureManifest() })
    settle(rushed.shell)
    local targetSlot = switchSlot(rushed.shell, learned)
    local x, y = slotCenter(rushed.shell, targetSlot)
    tap(rushed.shell, x, y)
    Assert.notNil(rushed.shell:status().transition, "the switch fade is a transition")
    press(rushed.shell, { type = "cancel" })
    press(rushed.shell, { type = "cancel" })
    local result = assert(rushed.shell:takeResult(), "a close during a switch still reports")
    Assert.equal(result.kind, "close", "the rushed switch close only returns close")
    rushed.shell:dispose()
    local counts = {}
    for _, tab in ipairs(rushed.log.disposals) do
      counts[tab] = (counts[tab] or 0) + 1
    end
    for tab, count in pairs(counts) do
      Assert.equal(count, 1, "rushed child " .. tab .. " disposes exactly once")
    end
  end

  -- Disposal is idempotent and terminal: it discards a pending close, a
  -- second disposal is silent, and a disposed shell steps nothing.
  do
    press(host.shell, { type = "cancel" })
    host.shell:dispose()
    Assert.isNil(host.shell:takeResult(), "disposal discards the pending close")
    host.shell:dispose()
    local ok, _ = pcall(function()
      host.shell:updateFixed({})
    end)
    Assert.isFalse(ok, "a disposed shell steps nothing")
  end
end

-- Construction rejects malformed options at the boundary instead of failing
-- on first draw: unknown entry kinds, missing card factories, factories
-- returning nothing usable, and missing display facts all fail up front.
function T.tests.shell_construction_rejects_malformed_options()
  local PokegearScreenState = requireFeature(
    "game.hgss.src.pokegear.PokegearScreenState",
    "the gear shell has no screen owner yet: malformed construction cannot fail"
  )
  local PokegearInterface = requireFeature(
    "game.hgss.src.pokegear.PokegearInterface",
    "the gear shell has no presentation owner yet: malformed construction cannot fail"
  )
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local function validOptions(overrides)
    local options = {
      state = fullCardState(record),
      assets = record,
      clock = LocalClock.new(function()
        return { year = 2024, month = 5, day = 6, hour = 12, minute = 0, second = 0 }
      end),
      children = stubChildren(freshLog()),
      presentation = PokegearInterface.defaults(),
      effect = function(_) end,
      entry = { kind = "browse" },
      measureDisplay = function()
        return displayFacts(512, 192, true)
      end,
    }
    if overrides ~= nil then
      for key, value in pairs(overrides) do
        options[key] = value
      end
    end
    return options
  end
  Assert.throws(function()
    PokegearScreenState.new(nil --[[@as table]])
  end, "a shell without options fails")
  Assert.throws(function()
    PokegearScreenState.new(validOptions({ entry = { kind = "fly" } }))
  end, "a shell with an unknown entry kind fails")
  Assert.throws(function()
    local options = validOptions()
    options.children = stubChildren(freshLog())
    options.children.map = nil
    PokegearScreenState.new(options)
  end, "a shell with a missing card factory fails")
  Assert.throws(function()
    local options = validOptions()
    options.children = stubChildren(freshLog())
    options.children.phone = function(_)
      return nil --[[@as table]]
    end
    PokegearScreenState.new(options)
  end, "a shell whose factory returns nothing usable fails")
  Assert.throws(function()
    local options = validOptions()
    options.children = stubChildren(freshLog())
    options.children.phone = function(_)
      return {
        updateFixed = function(_) end,
        status = function()
          return {}
        end,
        takeResult = function()
          return nil
        end,
      }
    end
    PokegearScreenState.new(options)
  end, "a shell whose factory returns a partial controller fails")
  Assert.throws(function()
    PokegearScreenState.new(validOptions({ measureDisplay = 0 }))
  end, "a shell without display facts fails")
end

-- Strip edges follow half-open bands with rounded corners: the shared band
-- edge belongs to the right-hand slot, the top strip row stays live, the
-- bottom row edge stays outside, and locked or transparent taps change
-- nothing, play nothing, and publish nothing.
function T.tests.strip_edges_and_masked_slots_reject_selection()
  local host = openShell({ manifest = fixtureManifest() })
  settle(host.shell)
  Assert.equal(host.shell:status().tab, "phone", "the full shell opens on the phone card")
  local effectsBefore = #host.log.effects
  -- The shared band edge at x56 belongs to the second slot: tapping it
  -- enters the radio card with sound.
  do
    local placement = assert(controlsPane(host.shell:status()).placement, "the controls pane is published")
    local edgeX, edgeY = toHost(placement, 56, 176)
    tap(host.shell, edgeX, edgeY)
    settle(host.shell)
    Assert.equal(host.shell:status().tab, "radio", "the shared band edge selects the right-hand slot")
    Assert.isTrue(#host.log.effects > effectsBefore, "the edge selection plays a sound")
  end
  -- The top strip row is live: tapping the current card's top edge keeps
  -- the card silently, and the transparent band corner does the same.
  do
    local placement = assert(controlsPane(host.shell:status()).placement, "the controls pane is published")
    local topX, topY = toHost(placement, 80, 160)
    local before = #host.log.effects
    tap(host.shell, topX, topY)
    Assert.equal(host.shell:status().tab, "radio", "the top strip row keeps the card")
    Assert.equal(#host.log.effects, before, "the top strip row plays no sound")
    local cornerX, cornerY = toHost(placement, 55, 161)
    tap(host.shell, cornerX, cornerY)
    Assert.equal(host.shell:status().tab, "radio", "the transparent band corner keeps the card")
    Assert.equal(#host.log.effects, before, "the transparent band corner plays no sound")
    Assert.isNil(host.shell:takeResult(), "rejected taps publish no result")
  end
  host.shell:dispose()
  -- A masked slot never enters its locked card: no switch, no sound, no
  -- result, and the remembered card still falls back to setup at open.
  do
    local record = PokegearAssetSchema.validate(fixtureManifest())
    Assert.notNil(record, "the synthetic companion catalog must validate")
    assert(record ~= nil, "synthetic catalog validated above")
    local locked = openShell({ state = baseCardState(record), manifest = fixtureManifest() })
    settle(locked.shell)
    local placement = assert(controlsPane(locked.shell:status()).placement, "the controls pane is published")
    local mapX, mapY = toHost(placement, 128, 176)
    local before = #locked.log.effects
    tap(locked.shell, mapX, mapY)
    Assert.equal(locked.shell:status().tab, "phone", "a masked slot never enters its locked card")
    Assert.equal(#locked.log.effects, before, "a masked slot plays no sound")
    Assert.isNil(locked.shell:takeResult(), "a masked tap publishes no result")
    locked.shell:dispose()
  end
end

-- Each single-card mask keeps the fixed strip: available slots land on the
-- same card as the full shell, masked slots keep the current card.
function T.tests.single_card_masks_keep_fixed_positions()
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic companion catalog must validate")
  assert(record ~= nil, "synthetic catalog validated above")
  local full = openShell({ manifest = fixtureManifest() })
  settle(full.shell)
  local mapping = learnSlots(full.shell)
  full.shell:dispose()
  for _, card in ipairs({ "map", "radio" }) do
    local state = PokegearState.new(nil, catalogRefs(record))
    state:registerCard(card)
    state:setPreference("unlockedSkins", { 0, 1, 2, 3, 4, 5 })
    local masked = openShell({ state = state, manifest = fixtureManifest() })
    settle(masked.shell)
    for slot = 1, 4 do
      local x, y = slotCenter(masked.shell, slot)
      local beforeTap = masked.shell:status().tab
      tap(masked.shell, x, y)
      settle(masked.shell)
      local fullTab = mapping[slot].tab
      if mapping[slot].switched and (fullTab == "configure" or fullTab == "phone" or fullTab == card) then
        Assert.equal(masked.shell:status().tab, fullTab, card .. " mask keeps available slot " .. slot)
      else
        Assert.equal(masked.shell:status().tab, beforeTap, card .. " mask holds masked slot " .. slot)
      end
    end
    masked.shell:dispose()
  end
end

-- The close is reported exactly once: a second take surrenders nothing, and
-- disposal stays silent while remembering the actual last card.
function T.tests.close_is_reported_once_and_disposal_is_silent()
  local host = openShell({ manifest = fixtureManifest() })
  settle(host.shell)
  local mapping = learnSlots(host.shell)
  local targetSlot = switchSlot(host.shell, mapping)
  local x, y = slotCenter(host.shell, targetSlot)
  tap(host.shell, x, y)
  settle(host.shell)
  local entered = host.shell:status().tab
  press(host.shell, { type = "cancel" })
  press(host.shell, { type = "cancel" })
  local result = assert(host.shell:takeResult(), "the second cancel closes the shell")
  Assert.equal(result.kind, "close", "the shell only returns close")
  Assert.isNil(host.shell:takeResult(), "the close is reported exactly once")
  press(host.shell, { type = "cancel" })
  Assert.isNil(host.shell:takeResult(), "a close after close reports nothing")
  host.shell:dispose()
  Assert.isNil(host.shell:takeResult(), "disposal reports no close")
  host.shell:dispose()
  Assert.equal(host.state:readPreferences().lastApp, entered, "a completed exit remembers the actual last card")
end

function T.tests.configuration_accepts_all_source_skins_with_an_old_saved_subset()
  local ConfigureController = require("game.hgss.src.pokegear.ConfigureController")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic companion catalog must validate")
  assert(record ~= nil, "synthetic catalog validated above")
  local state = PokegearState.new(nil, catalogRefs(record))
  state:setPreference("unlockedSkins", { 0 })

  local keyboard = ConfigureController.new({ state = state, assets = fixtureManifest() })
  for _ = 1, 5 do
    keyboard:updateFixed({ { type = "navigate", direction = "right" } })
  end
  keyboard:updateFixed({ { type = "confirm" } })
  Assert.isTrue(keyboard:status().menuOpen, "keyboard focus can open the source skin five menu")
  keyboard:updateFixed({ { type = "confirm" } })
  Assert.equal(state:readPreferences().skin, 5, "keyboard selection persists source skin five")
  keyboard:dispose()

  state:setPreference("skin", 0)
  local pointer = ConfigureController.new({ state = state, assets = fixtureManifest() })
  pointer:updateFixed({ { type = "pointer_down", x = 208, y = 116 } })
  pointer:updateFixed({ { type = "confirm" } })
  Assert.isTrue(pointer:status().menuOpen, "pointer selection can open the source skin five menu")
  pointer:updateFixed({ { type = "confirm" } })
  Assert.equal(state:readPreferences().skin, 5, "pointer selection persists source skin five")
  pointer:dispose()
end

function T.tests.shell_prepares_the_active_cards_presentation_images()
  local FieldState = require("game.hgss.src.field.FieldState")
  local PokegearRenderer = require("libs.hgss.src.presentation.PokegearRenderer")
  local path = "assets/generated/pokegear/phone-upper-skin-0.png"
  local requested = {}
  local pool = {
    request = function(_, imagePath)
      requested[imagePath] = true
      return imagePath
    end,
    poll = function()
      return "ready"
    end,
    acquire = function()
      return { image = {} }
    end,
  }
  local oldDraw = PokegearRenderer.draw
  local oldLove = love
  local observed
  PokegearRenderer.draw = function(_, _, plan)
    observed = plan
  end
  love = { graphics = {} }
  local ok, err = pcall(FieldState._drawPokegearApplication, {
    runtime = { imageAssets = pool },
  }, {}, {
    tab = "phone",
    focus = "application",
    presentation = { content = { slots = {} } },
    child = {
      presentation = {
        content = { upper = path },
      },
    },
  })
  PokegearRenderer.draw = oldDraw
  love = oldLove
  assert(ok, tostring(err))
  Assert.isTrue(requested[path], "the shell prepares the active phone card's upper image")
  Assert.notNil(observed, "the shell publishes the resolved plan to its renderer")
end

-- Small resizes within and across the near-native hysteresis band change no
-- logical state: card, focus, and remembered-card preference all hold.
function T.tests.small_resizes_keep_logical_state()
  local host = openShell({ manifest = fixtureManifest(), touch = false })
  settle(host.shell)
  press(host.shell, { type = "cancel" })
  Assert.isNil(host.shell:takeResult(), "the first cancel returns focus without closing")
  local tab, focus = host.shell:status().tab, host.shell:status().focus
  host.box.facts = displayFacts(514, 194, false)
  host.shell:updateFixed({})
  Assert.equal(host.shell:status().tab, tab, "a small wide resize keeps the card")
  Assert.equal(host.shell:status().focus, focus, "a small wide resize keeps strip focus")
  Assert.isNil(host.shell:takeResult(), "a small resize publishes no result")
  host.box.facts = displayFacts(256, 192, false)
  host.shell:updateFixed({})
  Assert.equal(host.shell:status().tab, tab, "a near-native entry keeps the card")
  Assert.equal(host.shell:status().focus, focus, "a near-native entry keeps strip focus")
  host.box.facts = displayFacts(258, 194, false)
  host.shell:updateFixed({})
  Assert.equal(host.shell:status().tab, tab, "a resize inside the retain band keeps the card")
  Assert.equal(host.shell:status().focus, focus, "a resize inside the retain band keeps strip focus")
  Assert.isNil(host.shell:takeResult(), "a hysteresis resize publishes no result")
  Assert.equal(host.state:readPreferences().lastApp, "phone", "resizes never touch the remembered card")
  host.shell:dispose()
end

return T
