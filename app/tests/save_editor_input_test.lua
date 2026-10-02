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
  return Layout.compute(view, width, height, assert(view.textMetrics, "input journey uses the editor's borrowed text metrics"))
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

local function selectSection(state, Layout, section)
  local _ = Layout
  state.controller:setSection(section)
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

local function withEditor(width, height, topology, fn)
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
    graphics = love.graphics,
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
    local groupTarget = computeLayout(Layout, progressView, 256, 192).targets["group-next"]
    click(state, selectedPane(progressView), groupTarget, false)
    Assert.equal(state:view().flagFilter, "All", "touch can browse all progress flags")
    local allFlags = state:view()
    click(state, selectedPane(allFlags), computeLayout(Layout, allFlags, 256, 192).targets["group-next"], false)
    Assert.notNil(state:view().flagGroup, "touch can browse an initial-letter flag group")
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

function T.tests.location_cursor_inspection_and_zoom_do_not_stage_a_destination()
  local _, Layout = stateModule()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = true,
    role = "world",
  })
  withEditor(256, 192, topology, function(state, fixture)
    for _ = 1, 8 do
      if state.locationService:snapshot().status.state == "ready" then
        break
      end
      state:update(0)
    end
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
    Assert.equal(view.focus, "location:grid", "Location opens with its grid as the keyboard focus")
    local before = copy(view.session.location)
    local revision = view.session.revision
    local joystick = {} --[[@as love.Joystick]]
    state:gamepadpressed(joystick, "a")
    state:gamepadreleased(joystick, "a")
    Assert.isTrue(state:view().locationGridMode, "Action enters the focused map grid")
    local layout = computeLayout(Layout, state:view(), 256, 192)
    local zoom = assert(layout.targets["location:zoom-in"], "Location exposes a reachable zoom control")
    click(state, selectedPane(state:view()), zoom, false)
    Assert.deepEqual(state:view().session.location, before, "zooming changes only the view")
    Assert.equal(state:view().session.revision, revision, "view controls do not revise the save transaction")
    state:gamepadpressed(joystick, "dpdown")
    local inspected = state:view()
    Assert.isTrue(
      inspected.locationNavigation.cursor.fieldX ~= before.fieldX
        or inspected.locationNavigation.cursor.fieldZ ~= before.fieldZ,
      "D-pad moves the inspection cursor independently of the staged destination"
    )
    Assert.deepEqual(inspected.session.location, before, "cursor movement does not stage a location")
    state:gamepadpressed(joystick, "b")
    Assert.deepEqual(state:view().session.location, before, "canceling inspection leaves the destination unchanged")
  end)
end

function T.tests.save_blocks_when_destination_revalidation_changes_any_location_field()
  withEditor(640, 480, ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 640, height = 480 },
    touch = false,
    role = "world",
  }), function(state, fixture)
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
      Assert.deepEqual(state.session:snapshot().location, staged, "the staged destination remains available to correct")
      Assert.deepEqual(fixture.store:load(fixture.saveId), fixture.initial, "the canonical save remains untouched")
      Assert.isTrue(state.session:isDirty(), "blocking a stale resolve preserves the full edit transaction")
      state:_discard(false)
    end
  end)
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
        string.format("Action at %s selected %s; current=%s focus=%s", target, section, selectedView.section, tostring(selectedView.focus))
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
    local beforeAxis = view.focus
    state:gamepadaxis(joystick, "leftx", 0.8)
    state:update(0.5)
    local analogMoved = state:view().focus ~= beforeAxis
    local visitedSections = {}
    for section, visited in pairs(seen) do
      if visited then visitedSections[#visitedSections + 1] = section end
    end
    table.sort(visitedSections)
    Assert.isTrue(
      reachedAllSections,
      "paired keyboard and D-pad input reaches all editor sections; visited " .. table.concat(visitedSections, ", ")
    )
    Assert.isTrue(analogMoved, "an analog threshold moves the focused control")
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
      "nickname target click opens naming editor; focus " .. tostring(nameView.focus) .. ", captured " .. tostring(state.controller.capturedTarget)
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
    local unicodeIncluded = unicodeGlyph ~= nil and withUnicode ~= nil
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
    Assert.equal(touchNameView.valueEditor and touchNameView.valueEditor.kind, "name", "touch reopens the naming editor")
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
    state:_activate("party:apply")
    Assert.equal(#state.session:partySnapshot().members, 1, "Apply publishes exactly one selected member")
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
