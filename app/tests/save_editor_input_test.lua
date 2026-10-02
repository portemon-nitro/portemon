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
      Layout.compute(notice, 256, 192).targets.notice,
      "the ready shell gives the ignored import notice a visible warning row"
    )
    local view = state:view()
    local layout = Layout.compute(view, 256, 192)
    local moneyRect = targetFor(layout, view, "money")
    click(state, selectedPane(view), moneyRect, false)
    state:keypressed("return")
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
    state:keypressed("backspace")
    local groupTarget = Layout.compute(progressView, 256, 192).targets["group-next"]
    click(state, selectedPane(progressView), groupTarget, false)
    Assert.equal(state:view().flagFilter, "All", "touch can browse all progress flags")
    local allFlags = state:view()
    click(state, selectedPane(allFlags), Layout.compute(allFlags, 256, 192).targets["group-next"], false)
    Assert.notNil(state:view().flagGroup, "touch can browse an initial-letter flag group")
    state:gamepadpressed(joystick, "dpdown")
    Assert.isFalse(state:view().focus == progressView.focus, "vertical input must move among flag rows")
    state:gamepadpressed(joystick, "a")
    progressView = state:view()
    local progressLayout = Layout.compute(progressView, 256, 192)
    local toggleRows = semanticRows(progressView, "toggle")
    Assert.isTrue(#toggleRows > 0, "Progress must expose named flag toggle rows")
    local toggleRect = targetFor(progressLayout, progressView, "flag")
    click(state, selectedPane(progressView), toggleRect, false)
    state:keypressed("escape")
    local leaveView = state:view()
    local discardRect = targetFor(Layout.compute(leaveView, 256, 192), leaveView, "discard")
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
    local layout = Layout.compute(view, 256, 192)
    local pane = selectedPane(view)
    Assert.isTrue(pane.placement.frame.y >= 192, "the complete interactive page belongs on the touch auxiliary")
    local moneyRect = targetFor(layout, view, "money")
    click(state, pane, moneyRect, true)
    state:textinput("4300")
    state:keypressed("return")
    local dirtyView = state:view()
    local saveRect = targetFor(Layout.compute(dirtyView, 256, 192), dirtyView, "save")
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
    click(state, selectedPane(view), targetFor(Layout.compute(view, 256, 192), view, "money"), false)
    state:keypressed("return")
    state:textinput("4200")
    state:keypressed("return")

    local dirty = state:view()
    click(state, selectedPane(dirty), targetFor(Layout.compute(dirty, 256, 192), dirty, "save"), false)
    local failed = state:view()
    Assert.isTrue(failed.dirty, "a failed close-save keeps staged values dirty")
    Assert.isTrue(failed.errorMessage ~= nil, "the ready editor shows the save failure")
    Assert.notNil(
      Layout.compute(failed, 256, 192).targets["error-notice"],
      "the failed save message is rendered while the close choice remains available"
    )

    Assert.isTrue(App.quit(), "root quit is vetoed while staged changes need a decision")
    Assert.isTrue(App.state == state and not state.disposed, "the real App boundary retains the editor after veto")
    local modal = state:view()
    click(state, selectedPane(modal), targetFor(Layout.compute(modal, 256, 192), modal, "discard"), false)
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
    local layout = Layout.compute(view, 256, 192)
    local zoom = assert(layout.targets["location:zoom-in"], "Location exposes a reachable zoom control")
    local before = copy(view.session.location)
    local revision = view.session.revision
    click(state, selectedPane(view), zoom, false)
    Assert.deepEqual(state:view().session.location, before, "zooming changes only the view")
    Assert.equal(state:view().session.revision, revision, "view controls do not revise the save transaction")

    local joystick = {} --[[@as love.Joystick]]
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
    click(state, selectedPane(view), targetFor(Layout.compute(view, 256, 192), view, "money"), false)
    Assert.isTrue(state:requestClose("quit"), "an open value draft must veto root quit")
    Assert.equal(state:view().modal, "leave")
    Assert.isFalse(state:view().dirty, "the modal keeps the draft local until an explicit resolution")
    Assert.equal(assert(fixture.store:load(fixture.saveId)).playerData.profile.money, fixture.initialMoney)
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
    Assert.notNil(Layout.compute(draft, 800, 600).targets["party:apply"], "the new member draft exposes Apply")
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
