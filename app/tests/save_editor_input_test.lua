-- Compact and dual-surface input contracts through the editor's public state path.

local Assert = require("tests.support.Assert")
local Fixture = require("app.tests.support.SaveEditorAcceptanceFixture")
local DisplayContext = require("libs.ui.src.DisplayContext")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local SaveFs = require("libs.storage.src.SaveFs")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local App = require("app.src.App")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map-data:7", "map:7", "audio-bank:730" },
    tags = { "product", "save-editor", "input" },
  },
  tests = {},
}

local function computeLayout(Layout, view, width, height)
  if view.layout ~= nil then
    return view.layout
  end
  return Layout.compute(
    view,
    width,
    height,
    assert(view.textMetrics, "input journey uses the editor's borrowed text metrics")
  )
end

local function stateModule()
  local loaded, State = pcall(require, "app.src.saveeditor.SaveEditorState")
  Assert.isTrue(loaded, "the product must expose the same editor input path to every supported host")
  local loadedLayout, Layout = pcall(require, "app.src.saveeditor.SaveEditorLayout")
  Assert.isTrue(loadedLayout, "the editor must publish canonical logical hit targets")
  return State, Layout
end

local function visit(value, callback, seen)
  if type(value) ~= "table" then
    return
  end
  seen = seen or {}
  if seen[value] then
    return
  end
  seen[value] = true
  callback(value)
  for _, child in pairs(value) do
    visit(child, callback, seen)
  end
end

local function semanticRows(view, role)
  local rows = {}
  visit(view, function(value)
    if value.role == role then
      rows[#rows + 1] = value
    end
  end)
  return rows
end

local function semanticText(value)
  local parts = {}
  visit(value, function(entry)
    for key, child in pairs(entry) do
      if type(key) == "string" then
        parts[#parts + 1] = key
      end
      if type(child) == "string" then
        parts[#parts + 1] = child
      end
    end
  end)
  return table.concat(parts, " "):lower()
end

local function rectangles(layout)
  local found = {}
  local function collect(value, path)
    if type(value) ~= "table" then
      return
    end
    if
      type(value.x) == "number"
      and type(value.y) == "number"
      and type(value.width) == "number"
      and type(value.height) == "number"
    then
      found[#found + 1] = { id = path, rect = value, description = (path .. " " .. semanticText(value)):lower() }
    end
    for key, child in pairs(value) do
      if type(child) == "table" then
        collect(child, path .. "/" .. tostring(key))
      end
    end
  end
  collect(layout, "")
  return found
end

local function targetFor(layout, view, token)
  local lowered = token:lower()
  local row
  for _, role in ipairs({ "integer value", "toggle", "action" }) do
    for _, candidate in ipairs(semanticRows(view, role)) do
      if semanticText(candidate):find(lowered, 1, true) then
        row = candidate
        break
      end
    end
    if row then
      break
    end
  end
  Assert.notNil(row, "the semantic view must expose the " .. token .. " row role")
  local rowId = row.targetId or row.id or row.key
  local targets = rectangles(layout)
  for _, candidate in ipairs(targets) do
    if
      (rowId ~= nil and candidate.id:find(tostring(rowId), 1, true))
      or candidate.description:find(lowered, 1, true)
    then
      return candidate.rect
    end
  end
  error("the resolved layout must expose a logical target for " .. token, 2)
end

local function selectedPane(view)
  for _, pane in ipairs(assert(view.presentation).panes) do
    if pane.interactive then
      return pane
    end
  end
  error("the editor plan must publish an interactive pane", 2)
end

local function click(state, pane, rect, touch)
  rect = rect.rect or rect
  local hostX, hostY = LayoutGeometry.logicalToHost(pane.placement, rect.x + rect.width / 2, rect.y + rect.height / 2)
  if touch then
    state:touchpressed("editor-touch", hostX, hostY)
    state:touchreleased("editor-touch", hostX, hostY)
  else
    state:mousepressed(hostX, hostY, 1)
    state:mousereleased(hostX, hostY, 1)
  end
end

local function pressKey(state, key)
  state:keypressed(key)
  state:keyreleased(key)
end

local function dragViewport(state, view, viewportId, deltaY, pointerId)
  local viewport = assert(view.layout.viewports[viewportId], "the active view publishes its scroll viewport")
  local pane = selectedPane(view)
  local x = viewport.clip.x + viewport.clip.width / 2
  local y = viewport.clip.y + viewport.clip.height / 2
  local hostX, hostY = LayoutGeometry.logicalToHost(pane.placement, x, y)
  local _, endY = LayoutGeometry.logicalToHost(pane.placement, x, y + deltaY)
  state:touchpressed(pointerId, hostX, hostY)
  state:touchmoved(pointerId, hostX, endY)
  state:touchreleased(pointerId, hostX, endY)
end

local function dragRect(state, view, rect, deltaY, pointerId)
  local pane = selectedPane(view)
  local x, y = LayoutGeometry.logicalToHost(pane.placement, rect.x + rect.width / 2, rect.y + rect.height / 2)
  local _, endY =
    LayoutGeometry.logicalToHost(pane.placement, rect.x + rect.width / 2, rect.y + rect.height / 2 + deltaY)
  state:touchpressed(pointerId, x, y)
  state:touchmoved(pointerId, x, endY)
  state:touchreleased(pointerId, x, endY)
end

local function filteredMapMatches(map, query)
  query = query:lower()
  return map.symbol:lower():find(query, 1, true) ~= nil
    or map.section:lower():find(query, 1, true) ~= nil
    or tostring(map.mapId):find(query, 1, true) ~= nil
end

local function repeatedMapQuery(maps)
  local candidates = {}
  for _, map in ipairs(maps) do
    for _, source in ipairs({ map.symbol, map.section }) do
      local lowered = source:lower()
      for first = 1, #lowered - 2 do
        for last = first + 2, #lowered do
          candidates[lowered:sub(first, last)] = true
        end
      end
    end
  end
  for query in pairs(candidates) do
    local matches = {}
    for _, map in ipairs(maps) do
      if filteredMapMatches(map, query) then
        matches[#matches + 1] = map
      end
    end
    if #matches >= 2 and #matches < #maps and matches[1].mapId ~= maps[1].mapId then
      return query, matches
    end
  end
  error("the structural map catalog must contain a repeated substring with a proper filtered subset", 2)
end

local function fillBagPocket(state, minimumRows)
  local catalog = assert(state.dependencies.context.itemCatalog)
  local pocket = state.controller.bagPocket
  local present = {}
  for _, entry in ipairs(state.session:bagSnapshot(pocket)) do
    present[entry.item] = true
  end
  local count = #state.session:bagSnapshot(pocket)
  for _, itemKey in ipairs(catalog:itemKeys()) do
    if count >= minimumRows then
      break
    end
    local item = catalog:item(itemKey)
    if item.pocket == pocket and not present[itemKey] then
      local result = state.session:setBagQuantity(itemKey, 1)
      if result.ok then
        present[itemKey] = true
        count = count + 1
      end
    end
  end
  Assert.isTrue(count >= minimumRows, "the real item catalog can fill the selected Bag viewport")
end

local function selectSection(state, Layout, section)
  local _ = Layout
  state.controller:setSection(section)
end

local function assertFocusCanMove(state, interaction)
  local before = state:view()
  Assert.notNil(before.layout.focusGraph[before.focus], interaction .. " leaves focus in the active graph")
  state:keypressed("down")
  state:keyreleased("down")
  local after = state:view()
  Assert.notNil(after.layout.focusGraph[after.focus], interaction .. " keeps focus valid after directional input")
end

local function focusPath(graph, start, target)
  local queue, parents = { start }, { [start] = false }
  local directions = { "up", "down", "left", "right" }
  local index = 1
  while index <= #queue do
    local current = queue[index]
    index = index + 1
    if current == target then
      local path = {}
      while current ~= start do
        local parent = parents[current]
        table.insert(path, 1, parent.direction)
        current = parent.target
      end
      return path
    end
    for _, direction in ipairs(directions) do
      local candidate = graph[current] and graph[current][direction][1]
      if candidate ~= nil and parents[candidate] == nil then
        parents[candidate] = { target = current, direction = direction }
        queue[#queue + 1] = candidate
      end
    end
  end
  return nil
end

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[copy(key)] = copy(child)
  end
  return result
end

local function withEditor(width, height, topology, fn, pixelRatio)
  local State = stateModule()
  local fixture = Fixture.new()
  local originalGlobal = SaveFs.global
  SaveFs.global = function(backend)
    Assert.isNil(backend, "the editor uses the isolated global SaveFs selected by this fixture")
    return fixture.saveFs
  end
  local requests = {}
  local host = {
    requestMilestone = function(name, urgency)
      requests[#requests + 1] = { name = name, urgency = urgency }
      return true
    end,
    requestField = function()
      return true
    end,
    requestLogicalField = function()
      return true
    end,
    requestCell = function()
      return true
    end,
    ensureLogicalField = function()
      return true
    end,
    ensureField = function()
      return true
    end,
    ensureCell = function()
      return true
    end,
  }
  local context = DisplayContext.new({
    graphics = pixelRatio and {
      getDimensions = function()
        return width, height
      end,
      getDPIScale = function()
        return pixelRatio
      end,
    } or love.graphics,
    topologyProvider = function()
      return topology
    end,
  })
  local results = {}
  local state
  local ok, err = xpcall(function()
    state = State.new({
      versionId = fixture.versionId,
      saveId = fixture.saveId,
      width = width,
      height = height,
      derivedAssets = host,
      repositoryRoot = love.filesystem.getSourceBaseDirectory(),
      displayContext = context,
      onResult = function(result)
        results[#results + 1] = result
      end,
    })
    state:update(0)
    fn(state, fixture, requests, results)
  end, debug.traceback)
  if state then
    pcall(function()
      state:dispose()
    end)
  end
  SaveFs.global = originalGlobal
  fixture.cleanup()
  if not ok then
    error(err, 0)
  end
end

function T.tests.input_reaches_money_and_toggle_rows_on_compact_and_dual_touch()
  local _, Layout = stateModule()
  local compact = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = false,
    role = "world",
  })
  withEditor(256, 192, compact, function(state, fixture)
    selectSection(state, Layout, "Player")
    state:onImportAttempt()
    local notice = state:view()
    Assert.equal(notice.notice, "Close the editor before importing another ROM.")
    Assert.notNil(
      computeLayout(Layout, notice, 256, 192).targets.notice,
      "the ready shell gives the ignored import notice a visible warning row"
    )
    local view = state:view()
    local layout = computeLayout(Layout, view, 256, 192)
    local moneyRect = targetFor(layout, view, "money")
    click(state, selectedPane(view), moneyRect, false)
    state:textinput("4200")
    state:keypressed("return")

    local updated = state:view()
    local moneyRows = semanticRows(updated, "integer value")
    local moneyValue
    for _, row in ipairs(moneyRows) do
      if semanticText(row):find("money", 1, true) then
        moneyValue = row.value
      end
    end
    Assert.equal(moneyValue, 4200, "keyboard entry must stage the exact money value")

    local joystick = {} --[[@as love.Joystick]]
    for _ = 1, 3 do
      state:gamepadpressed(joystick, "dpright")
      state:gamepadreleased(joystick, "dpright")
    end
    local progressView = state:view()
    Assert.equal(progressView.section, "Progress")
    Assert.equal(
      progressView.focus,
      "flag:" .. progressView.flagRows[1].name,
      "Progress focus must identify an actual semantic flag row"
    )
    local focusedFlag = progressView.focus:sub(6)
    local focusedFlagId = require("libs.assets.src.field.FieldScriptSymbols").flagsByName[focusedFlag]
    local valueBeforeTextKey = progressView.session.flags[focusedFlagId]
    state:keypressed("space")
    state:textinput(" ")
    Assert.equal(state:view().query, " ", "the configured action key's printable character enters search")
    Assert.equal(
      state:view().session.flags[focusedFlagId],
      valueBeforeTextKey,
      "a query character bound to confirm must not toggle the focused flag"
    )
    state:keypressed("a")
    state:textinput("a")
    Assert.equal(state:view().query, " a", "a printable action alias enters search through textinput")
    Assert.equal(
      state:view().session.flags[focusedFlagId],
      valueBeforeTextKey,
      "a printable letter bound to a game action must not toggle the focused flag"
    )
    state:keypressed("backspace")
    state:keypressed("backspace")
    Assert.isNil(
      computeLayout(Layout, state:view(), 256, 192).targets["group-next"],
      "Progress has no letter-group control"
    )
    state:gamepadpressed(joystick, "dpdown")
    Assert.isFalse(state:view().focus == progressView.focus, "vertical input must move among flag rows")
    state:gamepadpressed(joystick, "a")
    progressView = state:view()
    local progressLayout = computeLayout(Layout, progressView, 256, 192)
    local toggleRows = semanticRows(progressView, "toggle")
    Assert.isTrue(#toggleRows > 0, "Progress must expose named flag toggle rows")
    local toggleRect = targetFor(progressLayout, progressView, "flag")
    click(state, selectedPane(progressView), toggleRect, false)
    state:keypressed("escape")
    local leaveView = state:view()
    local discardRect = targetFor(computeLayout(Layout, leaveView, 256, 192), leaveView, "discard")
    click(state, selectedPane(leaveView), discardRect, false)
    Assert.equal(
      assert(fixture.store:load(fixture.saveId)).playerData.profile.money,
      fixture.initialMoney,
      "discard must leave the published record unchanged"
    )
  end)

  local dual = ScreenTopology.dualDisplay({
    id = "upper",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = false,
    role = "world",
  }, {
    id = "lower",
    rect = { x = 0, y = 192, width = 256, height = 192 },
    touch = true,
    role = "auxiliary",
  })
  withEditor(256, 384, dual, function(state, fixture)
    selectSection(state, Layout, "Player")
    local view = state:view()
    local layout = computeLayout(Layout, view, 256, 192)
    local pane = selectedPane(view)
    Assert.isTrue(pane.placement.frame.y >= 192, "the complete interactive page belongs on the touch auxiliary")
    local moneyRect = targetFor(layout, view, "money")
    click(state, pane, moneyRect, true)
    state:textinput("4300")
    state:keypressed("return")
    local dirtyView = state:view()
    local saveRect = targetFor(computeLayout(Layout, dirtyView, 256, 192), dirtyView, "save")
    click(state, selectedPane(dirtyView), saveRect, true)
    Assert.equal(
      assert(fixture.store:load(fixture.saveId)).playerData.profile.money,
      4300,
      "touch-only Save must publish the money value"
    )
  end)
end

function T.tests.value_editor_success_and_cancel_return_to_live_caller_focus()
  local _, Layout = stateModule()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = true,
    role = "world",
  })
  withEditor(256, 192, topology, function(state)
    selectSection(state, Layout, "Player")
    local player = state:view()
    click(state, selectedPane(player), computeLayout(Layout, player, 256, 192).targets.money, true)
    state:textinput("4200")
    state:keypressed("return")
    Assert.equal(state.session:snapshot().money, 4200, "successful Money confirmation stages the value")
    assertFocusCanMove(state, "successful Money edit")

    local afterSuccess = state:view()
    click(state, selectedPane(afterSuccess), computeLayout(Layout, afterSuccess, 256, 192).targets.money, true)
    state:keypressed("escape")
    Assert.equal(state.session:snapshot().money, 4200, "cancel leaves the staged Money value unchanged")
    assertFocusCanMove(state, "canceled Money edit")

    selectSection(state, Layout, "Bag")
    local bag = state:view()
    local bagLayout = computeLayout(Layout, bag, 256, 192)
    click(state, selectedPane(bag), bagLayout.targets["bag:pocket:medicine"], true)
    Assert.equal(state:view().bagPocket, "medicine", "pocket icons select the semantic pocket directly")
    assertFocusCanMove(state, "selected Bag pocket")
  end)
end

function T.tests.compact_and_wide_bag_entry_and_leave_modal_cancel_keep_focus_valid()
  local _, Layout = stateModule()
  for _, dimensions in ipairs({ { width = 256, height = 192 }, { width = 1200, height = 600 } }) do
    local topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = dimensions.width, height = dimensions.height },
      touch = true,
      role = "world",
    })
    withEditor(dimensions.width, dimensions.height, topology, function(state)
      local view = state:view()
      if dimensions.width >= 400 then
        local layout = computeLayout(Layout, view, dimensions.width, dimensions.height)
        Assert.isTrue(layout.viewport.width >= 400, "the wide topology resolves to a wide logical layout")
        click(state, selectedPane(view), layout.targets["section:Bag"], true)
      else
        local reachedBag = false
        for _ = 1, 5 do
          local compactView = state:view()
          if compactView.section == "Bag" then
            reachedBag = true
            break
          end
          click(
            state,
            selectedPane(compactView),
            computeLayout(Layout, compactView, dimensions.width, dimensions.height).targets.section,
            true
          )
        end
        if not reachedBag then
          Assert.equal(state:view().section, "Bag", "compact section selection reaches Bag")
        end
      end
      Assert.equal(state:view().section, "Bag", "the selected topology enters Bag through its visible section control")
      assertFocusCanMove(state, "Bag section entry")

      selectSection(state, Layout, "Player")
      local player = state:view()
      click(
        state,
        selectedPane(player),
        computeLayout(Layout, player, dimensions.width, dimensions.height).targets.money,
        true
      )
      state:textinput("4200")
      state:keypressed("return")
      Assert.isTrue(state:requestClose("back"), "a dirty save opens the leave decision")
      state:keypressed("escape")
      Assert.isNil(state:view().modal, "Escape cancels the leave decision")
      assertFocusCanMove(state, "leave modal cancellation")
    end)
  end
end

function T.tests.bag_add_successor_quantity_editor_stages_once_and_cancel_stages_nothing()
  local _, Layout = stateModule()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 800, height = 500 },
    touch = true,
    role = "world",
  })
  withEditor(800, 500, topology, function(state)
    selectSection(state, Layout, "Bag")
    local initialBag = state:view()
    local initialPocket = initialBag.bagPocket
    local initialItems = state.session:bagSnapshot(initialPocket)
    local addTarget = computeLayout(Layout, initialBag, 800, 600).targets["bag:add"]
    click(state, selectedPane(initialBag), addTarget, true)

    local itemPicker = state:view()
    local item = assert(itemPicker.valueEditor.options[1], "the real item catalog has addable items")
    local choiceTarget = computeLayout(Layout, itemPicker, 800, 600).targets["choice:" .. item.key]
    click(state, selectedPane(itemPicker), assert(choiceTarget), true)

    local quantityEditor = state:view()
    Assert.equal(
      quantityEditor.valueEditor and quantityEditor.valueEditor.kind,
      "quantity",
      "choosing an item installs its quantity successor"
    )
    local revisionBeforeAdd = state.session:revision()
    state:keypressed("up")
    state:keyreleased("up")
    state:keypressed("up")
    state:keyreleased("up")
    state:keypressed("return")
    local addedItems = state.session:bagSnapshot(initialPocket)
    local addedQuantity
    for _, row in ipairs(addedItems) do
      if row.item == item.key then
        addedQuantity = row.quantity
      end
    end
    local originalItemQuantity = 0
    for _, row in ipairs(initialItems) do
      if row.item == item.key then
        originalItemQuantity = row.quantity
      end
    end
    Assert.equal(
      addedQuantity,
      originalItemQuantity + 3,
      "quantity confirmation stages the selected item's requested amount"
    )
    Assert.equal(
      state.session:revision(),
      revisionBeforeAdd + 1,
      "one quantity confirmation stages exactly one Session mutation"
    )
    assertFocusCanMove(state, "completed Bag Add")

    local beforeCancel = state.session:revision()
    local currentBag = state:view()
    click(state, selectedPane(currentBag), computeLayout(Layout, currentBag, 800, 600).targets["bag:add"], false)
    local secondPicker = state:view()
    local secondItem = assert(secondPicker.valueEditor.options[1])
    local joystick = {} --[[@as love.Joystick]]
    state:gamepadpressed(joystick, "a")
    state:gamepadreleased(joystick, "a")
    local secondQuantity = state:view()
    Assert.equal(
      secondQuantity.valueEditor and secondQuantity.valueEditor.kind,
      "quantity",
      "controller confirmation reaches quantity entry"
    )
    state:keypressed("escape")
    Assert.equal(
      state.session:revision(),
      beforeCancel,
      "canceling the quantity successor stages no inventory mutation"
    )
    Assert.deepEqual(
      state.session:bagSnapshot(initialPocket),
      addedItems,
      "canceled Add preserves the staged inventory snapshot"
    )
    Assert.equal(secondItem.key, item.key, "both chains select the same deterministic catalog entry")
    assertFocusCanMove(state, "canceled Bag Add")
  end)
end

function T.tests.canceling_bag_quantity_and_parent_modal_restores_selected_item_focus()
  local _, Layout = stateModule()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 800, height = 500 },
    touch = true,
    role = "world",
  })
  withEditor(800, 500, topology, function(state)
    selectSection(state, Layout, "Bag")
    fillBagPocket(state, 1)
    local bag = state:view()
    local item = assert(bag.bagRows[1], "the fixture Bag contains an occupied item")
    local itemTarget = "bag:item:" .. item.item
    local revision = state.session:revision()
    local inventory = copy(state.session:bagSnapshot(bag.bagPocket))

    state:_activate(itemTarget)
    Assert.equal(state:view().modal, "bag-item", "selecting a stack opens its item actions")
    state:_activate("bag:quantity")
    Assert.equal(state:view().valueEditor.kind, "quantity", "Quantity opens its nested editor")
    state:keypressed("escape")
    Assert.equal(state:view().modal, "bag-item", "the first cancel restores the parent item modal")

    state:keypressed("escape")
    local returned = state:view()
    Assert.isNil(returned.modal, "the second cancel closes the parent item modal")
    Assert.equal(returned.focus, itemTarget, "focus returns to the exact selected item card")
    Assert.equal(state.session:revision(), revision, "cancellation does not mutate the save session")
    Assert.deepEqual(state.session:bagSnapshot(bag.bagPocket), inventory, "cancellation preserves the Bag")
  end)
end

function T.tests.bag_quantity_pointer_hold_repeats_on_fixed_ticks_and_resize_stops_it()
  local _, Layout = stateModule()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 800, height = 500 },
    touch = true,
    role = "world",
  })
  withEditor(800, 500, topology, function(state)
    selectSection(state, Layout, "Bag")
    state.controller:selectBagPocket("medicine")
    local potion = state.session:setBagQuantity("POTION", 1)
    Assert.isTrue(potion.ok, "the real item catalog accepts Potion in the medicine pocket")
    local bag = state:view()
    local row = assert(bag.bagRows[1], "the selected save has an item to edit")
    click(state, selectedPane(bag), bag.layout.targets["bag:item:" .. row.item], true)
    local itemModal = state:view()
    click(state, selectedPane(itemModal), itemModal.layout.targets["bag:quantity"], true)
    local quantity = state:view()
    local original = quantity.valueEditor.value
    local pane = selectedPane(quantity)
    local target = quantity.layout.targets["bag:quantity:increment"].rect
    local x, y = LayoutGeometry.logicalToHost(pane.placement, target.x + target.width / 2, target.y + target.height / 2)
    Assert.equal(
      Layout.hitTest(quantity.layout, quantity, target.x + target.width / 2, target.y + target.height / 2),
      "bag:quantity:increment",
      "the published quantity layout identifies its increment hitbox"
    )
    state:mousepressed(x, y, 1)
    Assert.equal(state:view().valueEditor.value, original + 1, "pointer-down increments immediately")
    state:update((18 - 1) / 60)
    Assert.equal(state:view().valueEditor.value, original + 1, "hold does not repeat before the fixed delay")
    state:update(1 / 60)
    Assert.equal(state:view().valueEditor.value, original + 2, "hold repeats at the fixed delay")
    state:update(4 / 60)
    Assert.equal(state:view().valueEditor.value, original + 3, "hold repeats at the fixed interval")
    state:mousereleased(x, y, 1)
    state:update(8 / 60)
    Assert.equal(state:view().valueEditor.value, original + 3, "release stops every later repeat")

    local current = state:view()
    pane = selectedPane(current)
    target = current.layout.targets["bag:quantity:increment"].rect
    x, y = LayoutGeometry.logicalToHost(pane.placement, target.x + target.width / 2, target.y + target.height / 2)
    state:mousepressed(x, y, 1)
    local afterPress = state:view().valueEditor.value
    state:resize(800, 500)
    state:update(1)
    Assert.equal(state:view().valueEditor.value, afterPress, "resize cancels the captured hold")
  end)
end

function T.tests.failed_close_save_keeps_the_state_until_explicit_discard()
  local _, Layout = stateModule()
  local compact = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = false,
    role = "world",
  })
  withEditor(256, 192, compact, function(state, fixture)
    selectSection(state, Layout, "Player")
    local originalWrite = fixture.saveFs.backend.write
    fixture.saveFs.backend.write = function(backend, path, data)
      if path:find("editor%-backups") then
        return false
      end
      return originalWrite(backend, path, data)
    end
    local quitCount = 0
    local originalQuit = love.event.quit
    local originalState, originalProvisioner, originalService, originalEpoch =
      App.state, App.provisioner, App.service, App.epoch
    App.state, App.provisioner, App.service = state, nil, nil
    love.event.quit = function(code)
      Assert.equal(code, 0)
      quitCount = quitCount + 1
      App.quit()
    end
    local view = state:view()
    click(state, selectedPane(view), targetFor(computeLayout(Layout, view, 256, 192), view, "money"), false)
    state:textinput("4200")
    state:keypressed("return")

    local dirty = state:view()
    click(state, selectedPane(dirty), targetFor(computeLayout(Layout, dirty, 256, 192), dirty, "save"), false)
    local failed = state:view()
    Assert.isTrue(failed.dirty, "a failed close-save keeps staged values dirty")
    Assert.isTrue(failed.errorMessage ~= nil, "the ready editor shows the save failure")
    Assert.notNil(
      computeLayout(Layout, failed, 256, 192).targets["error-notice"],
      "the failed save message is rendered while the close choice remains available"
    )

    Assert.isTrue(App.quit(), "root quit is vetoed while staged changes need a decision")
    Assert.isTrue(App.state == state and not state.disposed, "the real App boundary retains the editor after veto")
    local modal = state:view()
    click(state, selectedPane(modal), targetFor(computeLayout(Layout, modal, 256, 192), modal, "discard"), false)
    Assert.equal(quitCount, 1, "explicit discard requests process shutdown once")
    Assert.isTrue(state.disposed, "approved shutdown disposes the editor through App")
    Assert.isNil(App.state, "approved shutdown clears the root state")
    love.event.quit = originalQuit
    fixture.saveFs.backend.write = originalWrite
    App.state, App.provisioner, App.service, App.epoch =
      originalState, originalProvisioner, originalService, originalEpoch
  end)
end

function T.tests.location_grid_keyboard_moves_and_selects_without_zoom_or_grid_mode()
  local _, Layout = stateModule()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = true,
    role = "world",
  })
  withEditor(256, 192, topology, function(state, _)
    for _ = 1, 8 do
      if state.locationService:snapshot().status.state == "ready" then
        break
      end
      state:update(0)
    end
    local houseMapId = assert(state.dependencies.world.bySymbol.MAP_NEW_BARK_PLAYER_HOUSE_1F)
    state.controller:chooseLocationMap(houseMapId, 4, 5)
    state:_updateLocationService()
    for _ = 1, 8 do
      if state.locationService:snapshot().status.state == "ready" then
        break
      end
      state:update(0)
    end
    state.controller:setFocus("location:grid")
    local view = state:view()
    Assert.equal(view.section, "Location", "a successfully opened editor starts on Location")
    Assert.equal(
      view.location.status.state,
      "ready",
      "the source map prepares before tile interaction: "
        .. tostring(view.location.status.reason)
        .. ", map "
        .. tostring(view.location.mapId)
        .. ", editor "
        .. tostring(state.errorMessage)
    )
    Assert.equal(view.focus, "location:grid", "Location grid is the keyboard focus")
    Assert.equal(view.location.mapId, houseMapId, "the test map remains the structural house map")
    local before = copy(view.session.location)
    local revision = view.session.revision
    local selectable
    for _, tile in ipairs(view.location.tiles) do
      if tile.selectable then
        selectable = tile
        break
      end
    end
    selectable = assert(selectable, "the real ready map includes a safe selectable tile")
    local layout = computeLayout(Layout, view, 256, 192)
    Assert.isNil(layout.targets["location:zoom-in"], "fixed-scale Location has no zoom-in action")
    Assert.isNil(layout.targets["location:zoom-out"], "fixed-scale Location has no zoom-out action")
    pressKey(state, "down")
    local inspected = state:view()
    Assert.isTrue(
      inspected.locationNavigation.cursor.fieldX ~= before.fieldX
        or inspected.locationNavigation.cursor.fieldZ ~= before.fieldZ,
      "D-pad moves the inspection cursor independently of the staged destination"
    )
    Assert.deepEqual(inspected.session.location, before, "cursor movement does not stage a location")
    Assert.isNil(inspected.locationGridMode, "Location does not require a hidden grid-navigation mode")
    for _ = 1, 8 do
      if state.locationService:snapshot().status.state == "ready" then
        break
      end
      state:update(0)
    end
    inspected = state:view()
    Assert.equal(inspected.location.status.state, "ready", "cursor movement waits for its requested viewport data")
    while state.controller.locationCursorX ~= selectable.fieldX do
      local direction = state.controller.locationCursorX < selectable.fieldX and "right" or "left"
      pressKey(state, direction)
      for _ = 1, 8 do
        if state.locationService:snapshot().status.state == "ready" then
          break
        end
        state:update(0)
      end
    end
    while state.controller.locationCursorZ ~= selectable.fieldZ do
      local direction = state.controller.locationCursorZ < selectable.fieldZ and "down" or "up"
      pressKey(state, direction)
      for _ = 1, 8 do
        if state.locationService:snapshot().status.state == "ready" then
          break
        end
        state:update(0)
      end
    end
    Assert.equal(state.controller.focus, "location:grid", "the cursor remains keyboard-focused through map movement")
    pressKey(state, "return")
    local selected = state:view().session.location
    Assert.equal(selected.fieldX, selectable.fieldX, "keyboard Confirm stages the resolved tile X")
    Assert.equal(selected.fieldZ, selectable.fieldZ, "keyboard Confirm stages the resolved tile Z")
    Assert.equal(selected.mapId, inspected.location.mapId, "keyboard Confirm keeps the structural map identity")
    Assert.isTrue(state:view().session.revision > revision, "only valid tile selection revises the save transaction")
  end)
end

function T.tests.location_view_keeps_saved_and_pending_map_identity_separate()
  withEditor(
    640,
    480,
    ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 640, height = 480 },
      touch = false,
      role = "world",
    }),
    function(state)
      for _ = 1, 8 do
        if state.locationService:snapshot().status.state == "ready" then
          break
        end
        state:update(0)
      end
      local saved = copy(state.session:snapshot().originalLocation)
      local houseMapId = assert(state.dependencies.world.bySymbol.MAP_NEW_BARK_PLAYER_HOUSE_1F)
      state.controller:openLocationMaps()
      state:textinput("new_bark_player_house_1f")
      local searched = state:view()
      local houseRow
      for _, map in ipairs(searched.location.maps) do
        if map.mapId == houseMapId then
          houseRow = map
          break
        end
      end
      houseRow = assert(houseRow, "stripped map names find the same structural map record")
      Assert.equal(houseRow.displayName, "NEW_BARK_PLAYER_HOUSE_1F", "map prefix removal is presentation-only")
      Assert.equal(houseRow.symbol, "MAP_NEW_BARK_PLAYER_HOUSE_1F", "the raw map symbol remains available for identity")
      state.controller:setFocus("location:map:" .. houseMapId)
      pressKey(state, "return")
      Assert.equal(state:view().location.mapId, houseMapId, "selecting a stripped label preserves numeric map identity")
      state.controller:chooseLocationMap(houseMapId, 4, 5)
      for _ = 1, 8 do
        state:update(0)
        if state.locationService:snapshot().status.state == "ready" then
          break
        end
      end
      local readyView = state.locationService:snapshot()
      Assert.equal(readyView.status.state, "ready", "the real Player House map data is ready")
      local pending, resolveStatus = state.locationService:resolve(houseMapId, 4, 5, readyView.generation)
      Assert.notNil(pending, "the real Player House ground resolves to a destination")
      Assert.equal(resolveStatus.state, "ready")
      Assert.isTrue(state.session:setLocation(assert(pending)).ok, "the resolved tuple stages through Session")

      local stagedView = state:view()
      Assert.equal(stagedView.savedLocation.mapId, saved.mapId, "Saved stays tied to the opening baseline map")
      Assert.equal(stagedView.pendingLocation.mapId, houseMapId, "Pending follows the staged Session destination")
      Assert.deepEqual(stagedView.savedLocation, saved, "Saved retains the full baseline location tuple")
      Assert.deepEqual(stagedView.pendingLocation, pending, "Pending retains the full staged location tuple")

      local unrelatedMapId = assert(state.dependencies.world.bySymbol.MAP_NEW_BARK_PLAYER_HOUSE_2F)
      state.controller:chooseLocationMap(unrelatedMapId, 4, 5)
      state:update(0)
      local unrelatedView = state:view()
      Assert.equal(unrelatedView.location.mapId, unrelatedMapId)
      Assert.equal(unrelatedView.savedLocation.mapId, saved.mapId)
      Assert.equal(unrelatedView.pendingLocation.mapId, houseMapId)
      Assert.equal(state.session:revision(), stagedView.session.revision, "passive browsing does not revise the save")

      state.controller:openLocationMaps()
      state:textinput("no-map-matches-this-query")
      Assert.equal(#state:view().location.maps, 0, "the map search can produce a recoverable empty result")
      state:keypressed("delete")
      Assert.isTrue(#state:view().location.maps > 0, "Clear restores the searchable structural map list")
      state:keypressed("escape")
      Assert.equal(state.controller.locationPage, "grid", "Back returns from the map list")
      Assert.isTrue(state.session:discard(), "Discard restores the original location tuple")
      Assert.deepEqual(state.session:snapshot().location, saved)
    end
  )
end

function T.tests.progress_search_reconciles_stale_flag_focus_before_confirm()
  local _, Layout = stateModule()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = true,
    role = "world",
  })
  withEditor(256, 192, topology, function(state)
    selectSection(state, Layout, "Progress")
    local initial = state:view()
    Assert.isTrue(#initial.flagRows > 1, "the real symbolic catalog supplies multiple named flags")
    local firstName = initial.flagRows[1].name
    local secondName = initial.flagRows[2].name
    state.controller:setFocus("flag:" .. firstName)

    state:textinput(secondName:gsub("^FLAG_", "", 1))
    local filtered = state:view()
    local secondVisible = false
    for _, row in ipairs(filtered.flagRows) do
      secondVisible = secondVisible or row.name == secondName
    end
    Assert.isTrue(secondVisible, "raw-name query retains the matching full identity")
    Assert.isFalse(filtered.focus == "flag:" .. firstName, "filtered-out focus moves away from the hidden row")
    Assert.notNil(filtered.layout.focusGraph[filtered.focus], "query reconciliation keeps focus in the current graph")
    Assert.equal(filtered.layout.viewports.flags.offset, 0, "changing the query resets the flags viewport")

    state:keypressed("delete")
    state:textinput(secondName)
    local rawFiltered = state:view()
    Assert.isTrue(#rawFiltered.flagRows > 0, "raw FLAG_ identity remains searchable")
    Assert.equal(rawFiltered.flagRows[1].name, secondName, "raw query keeps the complete flag identity")

    state:keypressed("delete")
    local empty = state:view()
    state:textinput("query-with-no-flag-match-782")
    empty = state:view()
    Assert.equal(#empty.flagRows, 0, "an unmatched query leaves no actionable flag rows")
    Assert.isFalse(empty.focus:sub(1, 5) == "flag:", "zero results reconcile to a safe non-flag target")
    Assert.notNil(empty.layout.focusGraph[empty.focus], "zero-result focus remains in the active graph")
    local before = copy(empty.session.flags)
    pressKey(state, "return")
    Assert.deepEqual(state:view().session.flags, before, "Confirm cannot toggle an invisible flag")

    state:keypressed("delete")
    local cleared = state:view()
    Assert.isTrue(#cleared.flagRows > 0, "clearing search restores the named list")
    Assert.notNil(cleared.layout.focusGraph[cleared.focus], "clear leaves focus in the restored graph")
    Assert.equal(cleared.focus, "flag:" .. cleared.flagRows[1].name, "clear restores a valid named-flag focus")
  end)
end

function T.tests.wide_location_map_list_owns_focus_and_scroll_while_grid_stays_visible()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 800, height = 500 },
    touch = true,
    role = "world",
  })
  withEditor(800, 500, topology, function(state)
    for _ = 1, 8 do
      if state.locationService:snapshot().status.state == "ready" then
        break
      end
      state:update(0)
    end
    local initial = state:view()
    local firstMap = assert(initial.location.maps[1], "the real map catalog is populated")
    local firstTargetId = "location:map:" .. firstMap.mapId
    Assert.notNil(initial.layout.targets[firstTargetId], "wide Location publishes its persistent map list")
    Assert.notNil(initial.layout.locationGrid, "the map grid remains visible beside the list")
    local viewport = assert(initial.layout.viewports["location:map-list"])
    Assert.isTrue(
      viewport.contentExtent > viewport.clip.height,
      "the real structural catalog overflows the map viewport"
    )

    local revision = initial.session.revision
    local originalLocation = copy(initial.session.location)
    state.controller:setFocus(firstTargetId)
    pressKey(state, "down")
    local movedDown = state:view()
    Assert.equal(movedDown.focus, "location:map:" .. initial.location.maps[2].mapId, "Down advances one map row")
    Assert.equal(movedDown.session.revision, revision, "map-row navigation does not stage a destination")
    pressKey(state, "up")
    Assert.equal(state:view().focus, firstTargetId, "Up returns to the prior map row")
    local beforeOffset = state:view().layout.viewports["location:map-list"].offset
    state:wheelmoved(0, -1)
    local scrolled = state:view()
    Assert.isTrue(
      scrolled.layout.viewports["location:map-list"].offset > beforeOffset,
      "wide map-list focus owns wheel scrolling"
    )
    Assert.notNil(scrolled.layout.focusGraph[scrolled.focus], "scroll keeps focus attached to a rendered map row")
    Assert.equal(scrolled.session.revision, revision, "scrolling and map-row focus never stages a destination")
    Assert.notNil(scrolled.layout.locationGrid, "scrolling leaves the grid visible")

    dragViewport(state, scrolled, "location:map-list", -36, "wide-map-list-drag")
    local dragged = state:view()
    Assert.isTrue(
      dragged.layout.viewports["location:map-list"].offset > scrolled.layout.viewports["location:map-list"].offset,
      "touch drag scrolls the persistent map list"
    )
    Assert.notNil(dragged.layout.locationGrid, "touch scrolling leaves the grid visible")

    local draggedViewport = assert(dragged.layout.viewports["location:map-list"])
    local visibleMapTarget
    for index = draggedViewport.firstIndex, draggedViewport.lastIndex do
      local targetId = draggedViewport.rowTargets[index]
      if dragged.layout.targets[targetId] ~= nil then
        visibleMapTarget = targetId
        break
      end
    end
    visibleMapTarget = assert(visibleMapTarget, "the scrolled map viewport exposes a clickable row")
    local selectedMapId = assert(tonumber(visibleMapTarget:match("^location:map:(%d+)$")))
    click(state, selectedPane(dragged), dragged.layout.targets[visibleMapTarget], false)
    local clicked = state:view()
    Assert.equal(state.controller.locationMapId, selectedMapId, "map click updates the browsed map identity")
    Assert.equal(clicked.location.mapId, selectedMapId, "clicking a visible map browses that structural map")
    Assert.notNil(clicked.layout.locationGrid, "map click keeps the wide grid visible")
    Assert.equal(clicked.session.revision, revision, "browsing by click does not stage a destination")
    Assert.deepEqual(clicked.session.location, originalLocation, "browsing by click keeps the staged tuple")

    state.controller:setFocus(visibleMapTarget)
    pressKey(state, "right")
    Assert.equal(state:view().focus, "location:grid", "Right moves from the map list to the grid")
    pressKey(state, "left")
    Assert.equal(
      state:view().focus,
      "location:map:" .. selectedMapId,
      "Left returns to the map row for the currently browsed map"
    )
    Assert.equal(state:view().session.revision, revision, "region transitions do not stage a destination")
  end)
end

function T.tests.save_blocks_when_destination_revalidation_changes_any_location_field()
  withEditor(
    640,
    480,
    ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 640, height = 480 },
      touch = false,
      role = "world",
    }),
    function(state, fixture)
      local fields = { "mapId", "fieldX", "fieldZ", "surfaceId", "worldY", "terrainDependencyHash" }
      for _, field in ipairs(fields) do
        local staged = copy(state.session:snapshot().location)
        staged.fieldX = staged.fieldX + 1
        Assert.isTrue(state.session:setLocation(staged).ok, "a valid tuple can be staged for save-gate verification")
        local resolved = copy(staged)
        if field == "mapId" then
          for _, map in ipairs(state.dependencies.world.maps) do
            if map.id ~= staged.mapId then
              resolved.mapId = map.id
              break
            end
          end
        elseif field == "fieldX" then
          resolved.fieldX = resolved.fieldX + 1
        elseif field == "fieldZ" then
          resolved.fieldZ = resolved.fieldZ + 1
        elseif field == "surfaceId" then
          resolved.surfaceId = resolved.surfaceId + 1
        elseif field == "worldY" then
          resolved.worldY = resolved.worldY + 1
        else
          resolved.terrainDependencyHash = resolved.terrainDependencyHash .. "-changed"
        end
        state.locationService.resolve = function()
          return resolved, { state = "ready" }
        end

        Assert.isFalse(state:_save(false), "revalidation changing " .. field .. " must block the write")
        Assert.deepEqual(
          state.session:snapshot().location,
          staged,
          "the staged destination remains available to correct"
        )
        Assert.deepEqual(fixture.store:load(fixture.saveId), fixture.initial, "the canonical save remains untouched")
        Assert.isTrue(state.session:isDirty(), "blocking a stale resolve preserves the full edit transaction")
        state:_discard(false)
      end
    end
  )
end

function T.tests.quit_with_an_unapplied_value_draft_opens_the_leave_choice()
  local _, Layout = stateModule()
  local compact = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = false,
    role = "world",
  })
  withEditor(256, 192, compact, function(state, fixture)
    selectSection(state, Layout, "Player")
    local view = state:view()
    click(state, selectedPane(view), targetFor(computeLayout(Layout, view, 256, 192), view, "money"), false)
    Assert.isTrue(state:requestClose("quit"), "an open value draft must veto root quit")
    Assert.equal(state:view().modal, "leave")
    Assert.isFalse(state:view().dirty, "the modal keeps the draft local until an explicit resolution")
    Assert.equal(assert(fixture.store:load(fixture.saveId)).playerData.profile.money, fixture.initialMoney)
  end)
end

function T.tests.location_and_all_editor_sections_are_reachable_using_paired_device_input()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 800, height = 450 },
    touch = false,
    role = "world",
  })
  withEditor(800, 450, topology, function(state)
    local seen = { Location = true }
    state:keypressed("escape")
    state:keyreleased("escape")
    local joystick = {} --[[@as love.Joystick]]
    local sectionIndex = 0
    for _, section in ipairs({ "Player", "Party", "Bag", "Progress", "Location" }) do
      local view = state:view()
      local layout = computeLayout(Layout, view, 800, 450)
      local target = "section:" .. section
      local path = focusPath(layout.focusGraph, assert(view.focus), target)
      local focusNode = layout.focusGraph[view.focus]
      Assert.notNil(
        path,
        string.format(
          "the active layout focus graph reaches %s from %s (scope=%s viewport=%dx%d target=%s node-left=%s)",
          target,
          view.focus,
          tostring(layout.scopeId),
          layout.viewport.width,
          layout.viewport.height,
          tostring(layout.targets[target] ~= nil),
          table.concat(focusNode and focusNode.left or {}, ",")
        )
      )
      for _, direction in ipairs(assert(path)) do
        sectionIndex = sectionIndex + 1
        local before = state:view()
        local edge = assert(before.layout.focusGraph[before.focus])[direction][1]
        if sectionIndex == 1 then
          local fieldDirection = ({ up = "north", down = "south", left = "west", right = "east" })[direction]
          state.fieldInput:pressDirection(fieldDirection, "route-probe")
          local probeEvents = state.fieldInput:uiSnapshot(state.inputTick)
          state.fieldInput:releaseDirection("route-probe")
          Assert.equal(
            probeEvents[1] and probeEvents[1].direction,
            direction,
            "FieldInput maps the route direction back to the matching UI edge"
          )
        end
        if sectionIndex % 2 == 1 then
          state:keypressed(direction)
          state:keyreleased(direction)
        else
          local button = ({ up = "dpup", down = "dpdown", left = "dpleft", right = "dpright" })[direction]
          state:gamepadpressed(joystick, button)
          state:gamepadreleased(joystick, button)
        end
        local after = state:view()
        Assert.equal(
          after.focus,
          edge,
          string.format(
            "%s %s edge from %s expected focus %s, got %s (section=%s scope=%s graph=%s)",
            sectionIndex % 2 == 1 and "keyboard" or "gamepad",
            direction,
            before.focus,
            tostring(edge),
            after.focus,
            after.section,
            tostring(after.scope.id),
            table.concat(before.layout.focusGraph[before.focus][direction], ",")
          )
        )
      end
      local focusedView = state:view()
      Assert.equal(
        focusedView.focus,
        target,
        string.format(
          "directional path %s from the current node reaches %s; focused=%s section=%s scope=%s",
          table.concat(assert(path), ","),
          target,
          tostring(focusedView.focus),
          focusedView.section,
          tostring(focusedView.scope.id)
        )
      )
      if sectionIndex % 2 == 0 then
        state:keypressed("return")
        state:keyreleased("return")
      else
        state:gamepadpressed(joystick, "a")
        state:gamepadreleased(joystick, "a")
      end
      local selectedView = state:view()
      Assert.equal(
        selectedView.section,
        section,
        string.format(
          "Action at %s selected %s; current=%s focus=%s",
          target,
          section,
          selectedView.section,
          tostring(selectedView.focus)
        )
      )
      seen[state:view().section] = true
    end

    for _, direction in ipairs({ "down", "down", "down", "down" }) do
      state:keypressed(direction)
      state:update(0.2)
      state:focus(false)
      state:keyreleased(direction)
      seen[state:view().section] = true
    end

    local reachedAllSections = true
    for _, section in ipairs({ "Location", "Player", "Party", "Bag", "Progress" }) do
      reachedAllSections = reachedAllSections and seen[section] == true
    end
    local view = state:view()
    Assert.isTrue(view.focus ~= nil, "focus remains defined after held repeat and focus loss")
    Assert.isTrue(state.session:setMoney(state.session:snapshot().money + 1).ok, "a valid draft enables footer actions")
    local axisView = state:view()
    local axisTarget = assert(axisView.layout.focusGraph.save.right[1])
    Assert.equal(axisTarget, "discard", "analog setup has an enabled right-hand neighbor")
    Assert.isTrue(axisView.layout.targets.save.activationEnabled)
    Assert.isTrue(axisView.layout.targets.discard.activationEnabled)
    state.controller:setFocus("save")
    local beforeAxis = state:view().focus
    state:gamepadaxis(joystick, "leftx", 0.8)
    state:update(0.5)
    local analogMoved = state:view().focus ~= beforeAxis
    local visitedSections = {}
    for section, visited in pairs(seen) do
      if visited then
        visitedSections[#visitedSections + 1] = section
      end
    end
    table.sort(visitedSections)
    Assert.isTrue(
      reachedAllSections,
      "paired keyboard and D-pad input reaches all editor sections; visited " .. table.concat(visitedSections, ", ")
    )
    Assert.isTrue(
      analogMoved,
      "an analog threshold moves the focused control from "
        .. tostring(beforeAxis)
        .. " to "
        .. tostring(state:view().focus)
        .. " in "
        .. tostring(state:view().section)
    )
  end)
end

function T.tests.added_pokemon_nickname_uses_public_naming_controls()
  local _, Layout = stateModule()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = true,
    role = "world",
  })
  withEditor(256, 192, topology, function(state)
    local view = state:view()
    for _ = 1, 2 do
      click(state, selectedPane(view), computeLayout(Layout, view, 256, 192).targets.section, true)
      view = state:view()
    end
    view = state:view()
    Assert.equal(view.section, "Party", "the compact section control reaches Party through touch input")
    click(state, selectedPane(view), computeLayout(Layout, view, 256, 192).targets["party:add"], true)

    local picker = state:view()
    Assert.equal(picker.scope.kind, "value", "Add's species picker owns the active value scope")
    local species = assert(picker.valueEditor.options[1], "the real species catalog populates Add")
    click(state, selectedPane(picker), computeLayout(Layout, picker, 256, 192).targets["choice:" .. species.key], true)

    local draft, nickname
    for _ = 1, 40 do
      draft = state:view()
      nickname = computeLayout(Layout, draft, 256, 192).targets["party:field:nickname"]
      if nickname ~= nil then
        break
      end
      state:wheelmoved(0, -1)
    end
    nickname = assert(nickname, "the raw nickname field is reachable by scrolling the draft")
    Assert.equal(draft.scope.kind, "mon-draft", "the unapplied new member owns the active Party scope")
    click(state, selectedPane(draft), nickname, true)
    local nameView = state:view()
    Assert.equal(
      nameView.valueEditor and nameView.valueEditor.kind,
      "name",
      "nickname target click opens naming editor; focus "
        .. tostring(nameView.focus)
        .. ", captured "
        .. tostring(state.controller.capturedTarget)
    )
    Assert.equal(nameView.scope.kind, "value", "the naming keyboard becomes the active nested value scope")
    local initialName = nameView.valueEditor.naming.text
    local nativeSpecies = nameView.valueEditor.naming.subject.species
    local joystick = {} --[[@as love.Joystick]]
    state:gamepadpressed(joystick, "a")
    state:gamepadreleased(joystick, "a")
    local afterAction = state:view().valueEditor
    local activatedGlyph = afterAction ~= nil and afterAction.naming.text ~= initialName
    local initialPage = afterAction and afterAction.naming.page
    local pageLayout = computeLayout(Layout, state:view(), 256, 192)
    local lowerControl = pageLayout.targets["name-control:lower"]
    if lowerControl then
      click(state, selectedPane(state:view()), lowerControl, true)
    end
    local afterPage = state:view().valueEditor
    local pageChanged = afterPage ~= nil and afterPage.naming.page ~= initialPage
    local symbolsControl = afterPage and computeLayout(Layout, state:view(), 256, 192).targets["name-control:symbols"]
    if symbolsControl then
      click(state, selectedPane(state:view()), symbolsControl, true)
    end
    local symbolsView = state:view().valueEditor
    local unicodeGlyph
    if symbolsView ~= nil then
      for _, row in ipairs(symbolsView.naming.grid) do
        for _, cell in ipairs(row) do
          if cell.kind == "glyph" and cell.glyph and cell.glyph:match("[\128-\255]") then
            unicodeGlyph = cell.glyph
            break
          end
        end
        if unicodeGlyph ~= nil then
          break
        end
      end
    end
    if unicodeGlyph ~= nil then
      state:textinput(unicodeGlyph)
    end
    local withUnicode = state:view().valueEditor
    local symbolsPage = symbolsView ~= nil and symbolsView.naming.page == "symbols"
    local unicodeIncluded = unicodeGlyph ~= nil
      and withUnicode ~= nil
      and withUnicode.naming.text:find(unicodeGlyph, 1, true) ~= nil
    local beforeDelete = withUnicode and withUnicode.naming.text
    state:keypressed("backspace")
    local afterDelete = state:view().valueEditor
    local glyphDeleted = beforeDelete ~= nil and afterDelete ~= nil and #afterDelete.naming.text < #beforeDelete
    local expectedName = afterDelete and afterDelete.naming.text
    local okLayout = afterDelete and computeLayout(Layout, state:view(), 256, 192)
    local okTarget = okLayout and okLayout.targets["name-control:ok"]
    if okTarget then
      click(state, selectedPane(state:view()), okTarget, true)
    end
    local afterOk = state:view()
    Assert.notNil(
      afterOk.layout.focusGraph[afterOk.focus],
      "successful name editing returns focus to an active Party control"
    )
    local nicknameValue
    for _, row in ipairs(afterOk.partyRows) do
      if row.targetId == "party:field:nickname" then
        nicknameValue = row.value
        break
      end
    end
    local okSubmitted = afterOk.valueEditor == nil and nicknameValue == expectedName

    local beforeClear, clearTarget
    for _ = 1, 12 do
      beforeClear = state:view()
      clearTarget = computeLayout(Layout, beforeClear, 256, 192).targets["party:clear-nickname"]
      if clearTarget ~= nil then
        break
      end
      state:wheelmoved(0, -1)
    end
    Assert.notNil(clearTarget, "Clear Nickname is visible after submitting a nickname")
    click(state, selectedPane(beforeClear), assert(clearTarget), true)
    local clearedView = state:view()
    local explicitNil = false
    for _, row in ipairs(clearedView.partyRows) do
      if row.targetId == "party:field:nickname" then
        explicitNil = row.value == nil
        break
      end
    end
    local currentLayout = computeLayout(Layout, clearedView, 256, 192)
    local nicknameTarget = currentLayout.targets["party:field:nickname"]
    if nicknameTarget == nil then
      state:wheelmoved(0, 1)
      clearedView = state:view()
      currentLayout = computeLayout(Layout, clearedView, 256, 192)
      nicknameTarget = currentLayout.targets["party:field:nickname"]
    end
    if nicknameTarget then
      click(state, selectedPane(clearedView), nicknameTarget, true)
    end
    local returnEditor = state:view().valueEditor
    local expectedReturnName
    if returnEditor then
      state:textinput("B")
      expectedReturnName = state:view().valueEditor.naming.text
      state:keypressed("return")
    end
    local afterReturn = state:view()
    local returnSubmitted = afterReturn.valueEditor == nil
    local returnedNickname
    for _, row in ipairs(afterReturn.partyRows) do
      if row.targetId == "party:field:nickname" then
        returnedNickname = row.value
        break
      end
    end
    local returnValuePublished = expectedReturnName == "B" and returnedNickname == expectedReturnName

    local returnLayout = computeLayout(Layout, afterReturn, 256, 192)
    local reopenTarget = returnLayout.targets["party:field:nickname"]
    if reopenTarget then
      click(state, selectedPane(afterReturn), reopenTarget, true)
    end
    if state:view().valueEditor then
      local cancelJoy = {} --[[@as love.Joystick]]
      state:gamepadpressed(cancelJoy, "b")
      state:gamepadreleased(cancelJoy, "b")
    end
    local afterButtonCancel = state:view()
    local buttonCanceled = afterButtonCancel.valueEditor == nil
    if afterButtonCancel.valueEditor then
      state:keypressed("escape")
    end
    local afterButtonCleanup = state:view()
    local touchReopenTarget = computeLayout(Layout, afterButtonCleanup, 256, 192).targets["party:field:nickname"]
    Assert.notNil(touchReopenTarget, "the draft nickname field remains visible after Button Cancel")
    click(state, selectedPane(afterButtonCleanup), assert(touchReopenTarget), true)
    local touchNameView = state:view()
    Assert.equal(
      touchNameView.valueEditor and touchNameView.valueEditor.kind,
      "name",
      "touch reopens the naming editor"
    )
    local touchCancelTarget = touchNameView.valueEditor
      and computeLayout(Layout, touchNameView, 256, 192).targets.cancel
    Assert.notNil(touchCancelTarget, "the naming editor publishes its touch Cancel target")
    touchCancelTarget = touchCancelTarget.rect
    local cancelPane = selectedPane(touchNameView)
    local cancelX, cancelY = LayoutGeometry.logicalToHost(
      cancelPane.placement,
      touchCancelTarget.x + touchCancelTarget.width / 2,
      touchCancelTarget.y + touchCancelTarget.height / 2
    )
    local cancelPointerId = "touch:nickname-cancel"
    local beforeCancelScope = touchNameView.scope
    state:touchpressed(cancelPointerId:sub(7), cancelX, cancelY)
    local capturedCancelTarget = state.controller.capturedTarget
    local scopeAfterDown = state:view().scope
    state:touchreleased(cancelPointerId:sub(7), cancelX, cancelY)
    local afterTouchCancel = state:view()
    local afterCancelScope = afterTouchCancel.scope
    local pendingCancel = afterTouchCancel.valueEditor and afterTouchCancel.valueEditor.result
    local touchCanceled = afterTouchCancel.valueEditor == nil
    local draftUnapplied = #state.session:partySnapshot().members == 0
    assertFocusCanMove(state, "canceled nickname editor")
    Assert.isTrue(
      type(nativeSpecies) == "number"
        and activatedGlyph
        and pageChanged
        and symbolsPage
        and unicodeIncluded
        and glyphDeleted
        and okSubmitted
        and explicitNil
        and returnSubmitted
        and returnValuePublished
        and buttonCanceled
        and touchCanceled
        and draftUnapplied,
      string.format(
        "native=%s A=%s page=%s symbols=%s Unicode=%s delete=%s OK=%s nil=%s Return=%s/%s B=%s touch=%s draft=%s target=%s captured=%s scope=%s/%s->%s/%s result=%s",
        tostring(type(nativeSpecies) == "number"),
        tostring(activatedGlyph),
        tostring(pageChanged),
        tostring(symbolsPage),
        tostring(unicodeIncluded),
        tostring(glyphDeleted),
        tostring(okSubmitted),
        tostring(explicitNil),
        tostring(returnSubmitted),
        tostring(returnValuePublished),
        tostring(buttonCanceled),
        tostring(touchCanceled),
        tostring(draftUnapplied),
        tostring(touchCancelTarget ~= nil),
        tostring(capturedCancelTarget),
        tostring(beforeCancelScope.id),
        tostring(beforeCancelScope.epoch),
        tostring(afterCancelScope.id),
        tostring(afterCancelScope.epoch),
        tostring(pendingCancel and pendingCancel.kind)
      )
    )
  end)
end

function T.tests.filtered_species_picker_recovers_and_cancels_through_pointer_devices()
  local _, Layout = stateModule()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = true,
    role = "world",
  })
  withEditor(256, 192, topology, function(state)
    local view = state:view()
    click(state, selectedPane(view), computeLayout(Layout, view, 256, 192).targets.section, true)
    view = state:view()
    click(state, selectedPane(view), computeLayout(Layout, view, 256, 192).targets.section, true)
    view = state:view()
    click(state, selectedPane(view), computeLayout(Layout, view, 256, 192).targets["party:add"], true)

    state:textinput("no matching choice")
    local unmatchedQuery = state:view().valueEditor.query
    state:keypressed("backspace")
    local recoveredQuery = state:view().valueEditor.query
    local mouseView = state:view()
    click(state, selectedPane(mouseView), computeLayout(Layout, mouseView, 256, 192).targets.cancel, false)
    local mouseCanceled = state:view().valueEditor == nil

    view = state:view()
    click(state, selectedPane(view), computeLayout(Layout, view, 256, 192).targets["party:add"], true)
    state:textinput("no matching choice")
    local touchView = state:view()
    click(state, selectedPane(touchView), computeLayout(Layout, touchView, 256, 192).targets.cancel, true)
    local touchCanceled = state:view().valueEditor == nil

    Assert.isTrue(
      recoveredQuery ~= unmatchedQuery and mouseCanceled and touchCanceled,
      string.format(
        "queryRecovered=%s mouseCanceled=%s touchCanceled=%s",
        tostring(recoveredQuery ~= unmatchedQuery),
        tostring(mouseCanceled),
        tostring(touchCanceled)
      )
    )
  end)
end

function T.tests.valid_numeric_return_submits_once_after_invalid_text_is_corrected()
  local _, Layout = stateModule()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = true,
    role = "world",
  })
  withEditor(256, 192, topology, function(state)
    local initial = state:view()
    click(state, selectedPane(initial), computeLayout(Layout, initial, 256, 192).targets.section, true)
    local view = state:view()
    Assert.equal(view.section, "Player", "the compact section control reaches Player")
    local moneyBeforeInvalid = state.session:snapshot().money
    click(state, selectedPane(view), computeLayout(Layout, view, 256, 192).targets.money, true)
    state:textinput("bad")
    state:keypressed("return")
    local invalidView = state:view()
    local invalidRetained = invalidView.valueEditor ~= nil and invalidView.valueEditor.buffer == "bad"
    local invalidDescription = semanticText(invalidView)
    local visibleFeedback = invalidDescription:find("whole number", 1, true) ~= nil
      or invalidDescription:find("allowed range", 1, true) ~= nil
      or invalidDescription:find("invalid", 1, true) ~= nil
    local unpublishedInvalid = state.session:snapshot().money == moneyBeforeInvalid
    state:keypressed("escape")

    view = state:view()
    click(state, selectedPane(view), computeLayout(Layout, view, 256, 192).targets.money, true)
    state:textinput("4201")
    state:keypressed("return")
    local submitted = state:view().valueEditor == nil and state.session:snapshot().money == 4201
    Assert.isTrue(
      invalidRetained and unpublishedInvalid and visibleFeedback and submitted,
      string.format(
        "invalidRetained=%s unpublished=%s visibleFeedback=%s oneReturnSubmitted=%s",
        tostring(invalidRetained),
        tostring(unpublishedInvalid),
        tostring(visibleFeedback),
        tostring(submitted)
      )
    )
  end)
end

function T.tests.add_species_uses_draft_identity_independent_of_choice_focus()
  local _, Layout = stateModule()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 800, height = 600 },
    touch = true,
    role = "world",
  })
  withEditor(800, 600, topology, function(state)
    selectSection(state, Layout, "Party")
    state:_activate("party:add")
    local picker = state:view()
    local species = assert(picker.valueEditor.options[1], "the species picker exposes at least one species")
    state.controller.focus = species.key
    state:_activate(species.key)

    local draft = state:view()
    Assert.isTrue(draft.unappliedDraft, "choosing a species opens a local mon draft")
    Assert.equal(#state.session:partySnapshot().members, 0, "Add does not publish a member before Apply")
    Assert.notNil(computeLayout(Layout, draft, 800, 600).targets["party:apply"], "the new member draft exposes Apply")
    local originalPersonality = assert(state.monDraft):record().personality
    local originalNature = assert(state.monDraft):projection().nature
    local updatedPersonality
    for offset = 1, 25 do
      local candidate = (originalPersonality + offset) % 4294967296
      if require("libs.mons.src.gen4.Personality").nature(candidate) ~= originalNature then
        updatedPersonality = candidate
        break
      end
    end
    Assert.notNil(updatedPersonality, "a raw personality value can change its derived nature")
    Assert.isTrue(state.monDraft:setScalar("personality", assert(updatedPersonality)))
    local projected = state:view()
    local updatedNature
    for _, row in ipairs(projected.partyRows) do
      if row.id == "nature" then
        updatedNature = row.value
      end
    end
    Assert.equal(updatedNature, state.monDraft:projection().nature, "derived detail follows the local raw draft")
    Assert.equal(#state.session:partySnapshot().members, 0, "raw draft edits remain unpublished until Apply")
    state:_activate("party:apply")
    Assert.equal(#state.session:partySnapshot().members, 1, "Apply publishes exactly one selected member")

    local appliedRecord = state.session:partySnapshot().members[1].mon
    state:_activate("party:edit")
    Assert.isTrue(state.monDraft:setScalar("friendship", appliedRecord.friendship + 1))
    state:_activate("party:discard")
    Assert.deepEqual(
      state.session:partySnapshot().members[1].mon,
      appliedRecord,
      "Discard closes a later draft without changing the already-applied session member"
    )
  end)
end

function T.tests.subpage_navigation_keeps_the_same_mon_draft_open()
  local _, Layout = stateModule()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 800, height = 600 },
    touch = true,
    role = "world",
  })
  withEditor(800, 600, topology, function(state)
    selectSection(state, Layout, "Party")
    state:_beginMonAdd("CHIKORITA")
    local draft = assert(state.monDraft)
    local view = state:view()
    state:_activate("party:subpage:Origin")

    local after = state:view()
    Assert.isNil(after.modal, "changing the current member page does not ask to resolve its draft")
    Assert.equal(after.partySubpage, "Origin")
    Assert.equal(state.monDraft, draft, "the transaction identity survives page navigation")
    Assert.equal(#state.session:partySnapshot().members, 0, "navigation does not apply a new member")
  end)
end

function T.tests.filtered_location_map_navigation_uses_the_rendered_matches()
  local _, Layout = stateModule()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 800, height = 600 },
    touch = true,
    role = "world",
  })
  withEditor(800, 600, topology, function(state)
    for _ = 1, 8 do
      if state.locationService:snapshot().status.state == "ready" then
        break
      end
      state:update(0)
    end
    state.controller:openLocationMaps()
    local catalog = state.locationService:listMaps()
    local query, matches = repeatedMapQuery(catalog)
    state:textinput(query)
    local filtered = state:view().location.maps
    local structuralMatches = {}
    for _, map in ipairs(filtered) do
      local structuralMap = {}
      for key, value in pairs(map) do
        if key ~= "displayName" then
          structuralMap[key] = value
        end
      end
      structuralMatches[#structuralMatches + 1] = structuralMap
    end
    Assert.deepEqual(
      structuralMatches,
      matches,
      "the map picker renders the same structural sequence used to choose its search query"
    )

    local expected = {}
    for _, map in ipairs(filtered) do
      expected["location:map:" .. map.mapId] = true
    end
    local navigationConsistent = true
    for _ = 1, #filtered do
      pressKey(state, "down")
      local view = state:view()
      navigationConsistent = navigationConsistent and expected[view.focus] == true
    end
    for _ = 1, #filtered do
      pressKey(state, "up")
      local view = state:view()
      navigationConsistent = navigationConsistent and expected[view.focus] == true
    end

    state.controller:openLocationMaps()
    pressKey(state, "delete")
    state:textinput(query)
    local beforeSelection = state:view()
    filtered = beforeSelection.location.maps
    local renderedTargetId
    local selectedMap
    for _, map in ipairs(filtered) do
      local targetId = "location:map:" .. map.mapId
      if beforeSelection.layout.targets[targetId] ~= nil then
        renderedTargetId, selectedMap = targetId, map
        break
      end
    end
    Assert.notNil(renderedTargetId, "the filtered map view publishes a visible result target")
    click(
      state,
      selectedPane(beforeSelection),
      assert(computeLayout(Layout, beforeSelection, 800, 600).targets[renderedTargetId]),
      true
    )
    Assert.equal(
      state:view().locationNavigation.mapId,
      selectedMap.mapId,
      "activating a rendered filtered result selects that same map"
    )
    Assert.isTrue(navigationConsistent, "map-list movement keeps focus and reveal among visible filtered matches")
  end)
end

function T.tests.wheel_input_belongs_to_the_active_choice_or_decision_scope()
  local _, Layout = stateModule()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = true,
    role = "world",
  })
  withEditor(256, 192, topology, function(state)
    selectSection(state, Layout, "Bag")
    fillBagPocket(state, 8)
    local bag = state:view()
    local bagPage = bag.bagPage0
    local selectedItemTarget = "bag:item:" .. assert(bag.bagPageRows[1]).item
    click(state, selectedPane(bag), bag.layout.targets[selectedItemTarget], true)
    local selectedBag = state:view()
    Assert.equal(selectedBag.modal, "bag-item", "selecting a Bag card opens its item actions")
    click(state, selectedPane(selectedBag), selectedBag.layout.targets["bag:quantity"], true)
    local quantity = state:view()
    Assert.equal(quantity.valueEditor.kind, "quantity", "Quantity opens the nested quantity editor")
    local quantityBagPage = quantity.bagPage0
    local quantityDraft = assert(quantity.layout.targets["value-draft"]).rect
    state:wheelmoved(0, -1)
    local afterQuantityWheel = state:view()
    local quantityWheelStable = afterQuantityWheel.bagPage0 == quantityBagPage
    dragRect(state, afterQuantityWheel, quantityDraft, -32, "quantity-scroll")
    local afterQuantityDrag = state:view()
    local quantityDragStable = afterQuantityDrag.bagPage0 == quantityBagPage
    state:keypressed("escape")
    state:keypressed("escape")
    local resumedBag = state:view()
    Assert.isNil(resumedBag.modal, "leaving Bag quantity and item actions returns to the grid")
    click(state, selectedPane(resumedBag), resumedBag.layout.targets["bag:add"], true)

    local choice = state:view()
    local choiceOffset = choice.layout.viewports["value:choice"].offset
    Assert.isTrue(
      choice.layout.viewports["value:choice"].contentExtent > choice.layout.viewports["value:choice"].clip.height,
      "the real item catalog makes the Add picker scrollable"
    )
    local options = choice.valueEditor.options
    local selectedIndex = 1
    for index, option in ipairs(options) do
      if option.key == choice.valueEditor.selectedKey then
        selectedIndex = index
        break
      end
    end
    local choiceViewport = choice.layout.viewports["value:choice"]
    local visibleRows = math.max(1, choiceViewport.lastIndex - choiceViewport.firstIndex + 1)
    state:keypressed("right")
    local pageChoice = state:view()
    local expectedPageKey = options[math.min(#options, selectedIndex + visibleRows)].key
    local choicePaged = pageChoice.valueEditor.selectedKey == expectedPageKey
    state:textinput("no matching item")
    local noResults = state:view()
    local confirmDisabled = noResults.layout.targets.confirm.activationEnabled == false
    state:keypressed("backspace")
    local backspaceFiltered = state:view().valueEditor.query == "no matching ite"
    state:keypressed("delete")
    local deleteCleared = state:view().valueEditor.query == ""
    state:wheelmoved(0, -1)
    local scrolledChoice = state:view()
    local choiceScrolled = scrolledChoice.layout.viewports["value:choice"].offset > choiceOffset
    local choiceBagStable = scrolledChoice.bagPage0 == bagPage
    local choiceBagPage = scrolledChoice.bagPage0

    state:keypressed("escape")
    state.session:setMoney(state.session:snapshot().money + 1)
    Assert.isTrue(state:requestClose("back"), "a dirty session opens its leave decision")
    local modal = state:view()
    Assert.notNil(modal.modal, "the leave decision owns the current interaction scope")
    local modalBagPage = modal.bagPage0
    state:wheelmoved(0, -1)
    local modalListStable = state:view().bagPage0 == modalBagPage
    Assert.isTrue(
      quantityWheelStable
        and quantityDragStable
        and choicePaged
        and confirmDisabled
        and backspaceFiltered
        and deleteCleared
        and choiceScrolled
        and choiceBagStable
        and modalListStable,
      string.format(
        "quantity wheel/drag=%s/%s choice page=%s empty confirm=%s backspace/delete=%s/%s choice=%s bag page=%s->%s modal=%s",
        tostring(quantityWheelStable),
        tostring(quantityDragStable),
        tostring(choicePaged),
        tostring(confirmDisabled),
        tostring(backspaceFiltered),
        tostring(deleteCleared),
        tostring(choiceScrolled),
        tostring(bagPage),
        tostring(choiceBagPage),
        tostring(modalListStable)
      )
    )
  end)
end

function T.tests.compact_section_cycling_uses_the_resolved_logical_layout()
  local _ = stateModule()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 500, height = 480 },
    touch = false,
    role = "world",
  })
  withEditor(500, 480, topology, function(state)
    state.controller:setSection("Player")
    local before = state:view()
    Assert.isTrue(before.layout.viewport.width < 400, "high-density presentation resolves a compact logical canvas")
    Assert.notNil(before.layout.targets.section, "compact layout publishes the section chooser target")
    state.controller:setFocus("money")
    state:keypressed("right")
    Assert.equal(state.controller.section, "Party", "logical compact layout cycles right to the next section")
    Assert.notNil(state:view().layout.targets.section, "the resulting section stays in compact navigation")
  end, 2)
end

function T.tests.item_choice_is_flat_filtered_and_uses_clamped_page_navigation()
  local _, Layout = stateModule()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = true,
    role = "world",
  })
  withEditor(256, 192, topology, function(state)
    selectSection(state, Layout, "Bag")
    fillBagPocket(state, 8)
    local bag = state:view()
    click(state, selectedPane(bag), bag.layout.targets["bag:add"], true)
    local choice = state:view()
    local editor = choice.valueEditor
    local viewport = assert(choice.layout.viewports["value:choice"])
    local visibleRows = math.max(1, viewport.lastIndex - viewport.firstIndex + 1)
    Assert.isTrue(#editor.options > visibleRows * 2, "the real item catalog fills multiple visible choice pages")
    Assert.isNil(choice.layout.targets["group-previous"], "choice has no group navigation target")
    Assert.isNil(choice.layout.targets["group-next"], "choice has no group navigation target")
    Assert.isNil(choice.layout.targets["clear-search"], "choice has no visible Clear target")

    state:keypressed("up")
    local clamped = state:view().valueEditor.selectedKey == editor.options[1].key
    state:keypressed("right")
    local expectedIndex = math.min(#editor.options, 1 + visibleRows)
    local paged = state:view().valueEditor.selectedKey == editor.options[expectedIndex].key

    state:textinput("no matching item")
    local noResults = state:view()
    local confirmDisabled = noResults.layout.targets.confirm.activationEnabled == false
    state:keypressed("backspace")
    local backspace = state:view().valueEditor.query == "no matching ite"
    state:keypressed("delete")
    local delete = state:view().valueEditor.query == ""
    Assert.isTrue(
      clamped and paged and confirmDisabled and backspace and delete,
      string.format(
        "choice clamps=%s pages=%s (%s expected %s; visible=%d) empty-confirm-disabled=%s backspace=%s delete=%s",
        tostring(clamped),
        tostring(paged),
        tostring(state:view().valueEditor.selectedKey),
        tostring(editor.options[expectedIndex].key),
        visibleRows,
        tostring(confirmDisabled),
        tostring(backspace),
        tostring(delete)
      )
    )
  end)
end

function T.tests.dirty_state_uses_action_enablement_and_the_existing_leave_decision()
  local _, Layout = stateModule()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 640, height = 480 },
    touch = true,
    role = "world",
  })
  withEditor(640, 480, topology, function(state)
    local clean = state:view()
    Assert.isFalse(clean.layout.targets.save.activationEnabled, "Save is disabled while the staged record is clean")
    Assert.isFalse(
      clean.layout.targets.discard.activationEnabled,
      "Discard is disabled while the staged record is clean"
    )

    Assert.isTrue(state.session:setMoney(state.session:snapshot().money + 1).ok, "money can be staged")
    local dirty = state:view()
    Assert.isTrue(dirty.layout.targets.save.activationEnabled, "Save becomes enabled after staging a change")
    Assert.isTrue(dirty.layout.targets.discard.activationEnabled, "Discard becomes enabled after staging a change")
    Assert.isTrue(state:requestClose("back"), "Back preserves the existing dirty leave decision")

    local leave = state:view()
    Assert.equal(leave.modal, "leave")
    for _, targetId in ipairs({ "save", "discard", "cancel" }) do
      Assert.notNil(
        Layout.hitTest(
          leave.layout,
          leave,
          leave.layout.targets[targetId].rect.x + 1,
          leave.layout.targets[targetId].rect.y + 1
        ),
        "leave decision retains the " .. targetId .. " action"
      )
    end
  end)
end

function T.tests.touch_drag_scrolls_each_existing_long_list_viewport()
  local _, Layout = stateModule()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = true,
    role = "world",
  })
  withEditor(256, 192, topology, function(state)
    local partyScrolled = false
    local bagPaged = false
    local flagsScrolled = false
    local choiceScrolled = false
    local mapListScrolled = false
    local partyViewport = function()
      local view = state:view()
      local viewport = assert(view.layout.viewports.party)
      Assert.isTrue(viewport.contentExtent > viewport.clip.height, "Party has a scrollable detail page")
      local before = viewport.offset
      dragViewport(state, view, "party", -36, "party-scroll")
      partyScrolled = state:view().layout.viewports.party.offset > before
    end
    selectSection(state, Layout, "Party")
    Assert.isTrue(state:_beginMonAdd("CHIKORITA"), "the real species catalog opens a Party draft")
    state:_resolveDraftChoice("apply")
    state.controller:selectPartySlot(0)
    state.controller:selectPartySubpage("Training")
    partyViewport()

    selectSection(state, Layout, "Bag")
    fillBagPocket(state, 8)
    local bag = state:view()
    Assert.isNil(bag.layout.viewports.bag, "Bag uses its six-item paged grid instead of a scrolling list")
    click(state, selectedPane(bag), bag.layout.targets["bag:page:next"], true)
    bagPaged = state:view().bagPage0 == 1

    selectSection(state, Layout, "Progress")
    state.controller.flagFilter = "All"
    local progress = state:view()
    local flags = assert(progress.layout.viewports.flags)
    Assert.isTrue(flags.contentExtent > flags.clip.height, "the real flag catalog is scrollable")
    local flagsBefore = flags.offset
    dragViewport(state, progress, "flags", -36, "flags-scroll")
    flagsScrolled = state:view().layout.viewports.flags.offset > flagsBefore

    selectSection(state, Layout, "Bag")
    local bagView = state:view()
    click(state, selectedPane(bagView), bagView.layout.targets["bag:add"], true)
    local choice = state:view()
    local choiceViewport = assert(choice.layout.viewports["value:choice"])
    Assert.isTrue(choiceViewport.contentExtent > choiceViewport.clip.height, "the item picker is scrollable")
    local choiceBefore = choiceViewport.offset
    dragViewport(state, choice, "value:choice", -36, "choice-scroll")
    choiceScrolled = state:view().layout.viewports["value:choice"].offset > choiceBefore

    state:keypressed("escape")
    selectSection(state, Layout, "Location")
    state.controller:openLocationMaps()
    local maps = state:view()
    local mapViewport = assert(maps.layout.viewports["location:map-list"])
    Assert.isTrue(mapViewport.contentExtent > mapViewport.clip.height, "the structural map list is scrollable")
    local mapBefore = mapViewport.offset
    dragViewport(state, maps, "location:map-list", -36, "map-list-scroll")
    mapListScrolled = state:view().layout.viewports["location:map-list"].offset > mapBefore
    Assert.isTrue(
      partyScrolled and bagPaged and flagsScrolled and choiceScrolled and mapListScrolled,
      string.format(
        "touch drag changes each active list offset; Bag pages by touch (Party=%s, Bag=%s, Progress=%s, choice=%s, maps=%s)",
        tostring(partyScrolled),
        tostring(bagPaged),
        tostring(flagsScrolled),
        tostring(choiceScrolled),
        tostring(mapListScrolled)
      )
    )
  end)
end

function T.tests.location_grid_drag_pans_while_map_list_and_decision_drags_do_not()
  local _, Layout = stateModule()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 800, height = 600 },
    touch = true,
    role = "world",
  })
  withEditor(800, 600, topology, function(state)
    for _ = 1, 8 do
      if state.locationService:snapshot().status.state == "ready" then
        break
      end
      state:update(0)
    end
    local view = state:view()
    local grid = assert(view.layout.locationGrid, "the ready Location page publishes its grid clip")
    local gridClip = grid.clip
    local pane = selectedPane(view)
    local x, y =
      LayoutGeometry.logicalToHost(pane.placement, gridClip.x + gridClip.width / 2, gridClip.y + gridClip.height / 2)
    local _, movedY = LayoutGeometry.logicalToHost(
      pane.placement,
      gridClip.x + gridClip.width / 2,
      gridClip.y + gridClip.height / 2 - 36
    )
    local centerBefore = copy(view.locationNavigation.center)
    state:touchpressed("grid-pan", x, y)
    state:touchmoved("grid-pan", x, movedY)
    state:touchreleased("grid-pan", x, movedY)
    local panned = state:view()
    Assert.isTrue(
      panned.locationNavigation.center.fieldX ~= centerBefore.fieldX
        or panned.locationNavigation.center.fieldZ ~= centerBefore.fieldZ,
      "dragging the Location grid pans its center"
    )

    state.controller:openLocationMaps()
    local mapList = state:view()
    local mapViewport = assert(mapList.layout.viewports["location:map-list"])
    local mapCenter = copy(mapList.locationNavigation.center)
    local mapOffset = mapViewport.offset
    dragViewport(state, mapList, "location:map-list", -36, "map-list-pan-check")
    local movedList = state:view()
    local mapListScrolled = movedList.layout.viewports["location:map-list"].offset > mapOffset
    local mapCenterStable = movedList.locationNavigation.center.fieldX == mapCenter.fieldX
      and movedList.locationNavigation.center.fieldZ == mapCenter.fieldZ

    state.controller:openModal("leave")
    local modal = state:view()
    local modalCenter = copy(modal.locationNavigation.center)
    local modalListOffset = modal.locationNavigation.mapOffset
    local modalPane = selectedPane(modal)
    local modalTarget = assert(modal.layout.targets.cancel)
    modalTarget = modalTarget.rect or modalTarget
    local downX, downY = LayoutGeometry.logicalToHost(
      modalPane.placement,
      modalTarget.x + modalTarget.width / 2,
      modalTarget.y + modalTarget.height / 2
    )
    state:touchpressed("modal-drag", downX, downY)
    state:touchmoved("modal-drag", downX, downY - 36)
    state:touchreleased("modal-drag", downX, downY - 36)
    local afterModalDrag = state:view()
    local modalCenterStable = afterModalDrag.locationNavigation.center.fieldX == modalCenter.fieldX
      and afterModalDrag.locationNavigation.center.fieldZ == modalCenter.fieldZ
    local modalListStable = afterModalDrag.locationNavigation.mapOffset == modalListOffset
    Assert.isTrue(
      mapListScrolled and mapCenterStable and modalCenterStable and modalListStable,
      string.format(
        "map-list and decision drag ownership stays scoped (listScrolled=%s, listCenterStable=%s, modalCenterStable=%s, modalListStable=%s)",
        tostring(mapListScrolled),
        tostring(mapCenterStable),
        tostring(modalCenterStable),
        tostring(modalListStable)
      )
    )
  end)
end

function T.tests.discard_reconciles_selection_after_removing_staged_member()
  local _, Layout = stateModule()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 800, height = 600 },
    touch = true,
    role = "world",
  })
  withEditor(800, 600, topology, function(state)
    selectSection(state, Layout, "Party")
    state:_beginMonAdd("CHIKORITA")
    state:_resolveDraftChoice("apply")
    Assert.equal(#state.session:partySnapshot().members, 1)
    Assert.equal(state.controller.partySlot0, 0)

    state:_discard(false)
    local view = state:view()
    Assert.equal(#state.session:partySnapshot().members, 0, "Session discard restores the baseline party")
    Assert.isNil(view.partySlot0, "navigation no longer points at the discarded member")
    Assert.equal(view.partyPage, "list", "the Party view returns to a usable baseline list")
  end)
end

function T.tests.quit_keeps_an_invalid_scalar_draft_until_close_decision()
  local _, Layout = stateModule()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 800, height = 600 },
    touch = true,
    role = "world",
  })
  withEditor(800, 600, topology, function(state)
    selectSection(state, Layout, "Party")
    state:_beginMonAdd("CHIKORITA")
    state.controller:selectPartySubpage("Training")
    local row = state:_partyField("party:field:friendship")
    Assert.notNil(row)
    state:_openEditor(row)
    state:textinput("invalid")
    local before = state:view().valueEditor.buffer
    local previousState = App.state
    App.state = state
    local veto = App.quit()
    local after = state:view()
    App.state = previousState

    Assert.isTrue(veto, "the App quit boundary synchronously vetoes while nested work is open")
    Assert.notNil(after.modal, "quit opens an explicit close decision")
    Assert.notNil(after.valueEditor, "the open scalar editor remains alive behind the close decision")
    Assert.equal(after.valueEditor.buffer, before, "close dialog preserves the invalid scalar text")
    Assert.isTrue(after.unappliedDraft, "the mon draft remains owned while close is pending")
  end)
end

return T
