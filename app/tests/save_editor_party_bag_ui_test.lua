-- Party and Bag editor targets remain visible and reachable in a compact viewport.

local Assert = require("tests.support.Assert")
local Controller = require("app.src.saveeditor.SaveEditorController")
local Layout = require("app.src.saveeditor.SaveEditorLayout")
local Moves = require("libs.mons.src.gen4.Moves")
local Navigation = require("app.src.saveeditor.SaveEditorNavigation")
local SaveEditorState = require("app.src.saveeditor.SaveEditorState")
local ModalStack = require("app.src.saveeditor.SaveEditorModalStack")
local PartyView = require("app.src.saveeditor.SaveEditorPartyView")
local ValueEditor = require("app.src.saveeditor.SaveEditorValueEditor")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ItemAssetSchema = require("libs.assets.src.ItemAssetSchema")
local ItemCatalog = require("libs.items.src.ItemCatalog")
local ItemFixture = require("libs.items.tests.item_fixture")

local T = {}

local function modalStackWith(kind)
  local stack = ModalStack.new()
  stack:push({
    id = "test:" .. kind,
    kind = kind,
    payload = {},
    opener = { controlId = "test:opener", regionId = "test", scrollAnchor = 0 },
  })
  return stack
end

local function hasFocus(layout, targetId)
  for _, region in ipairs(layout.focusNavigation.regions) do
    if region.logical and region.logical.indexOf and region.logical.indexOf(targetId) ~= nil then
      return true
    end
  end
  for _, control in ipairs(layout.focusNavigation.controls) do
    if control.id == targetId then
      return true
    end
  end
  return false
end

local function navigate(controller, layout, direction)
  local snapshot = {
    scope = { id = layout.scopeId, epoch = layout.scopeEpoch },
    regions = layout.focusNavigation.regions,
    controls = layout.focusNavigation.controls,
    remembered = controller.listCursors,
  }
  local focus
  for _, control in ipairs(snapshot.controls) do
    if control.id == controller.focus then
      focus = { scopeId = layout.scopeId, regionId = control.regionId, targetId = controller.focus }
      break
    end
  end
  if focus == nil then
    for _, region in ipairs(snapshot.regions) do
      if region.logical and region.logical.indexOf and region.logical.indexOf(controller.focus) ~= nil then
        focus = { scopeId = layout.scopeId, regionId = region.id, targetId = controller.focus }
        break
      end
    end
  end
  focus = Navigation.reconcile(snapshot, focus or {
    scopeId = layout.scopeId,
    regionId = "",
    targetId = controller.focus,
  }, { layout.defaultFocus })
  controller:setFocus(focus.targetId)
  local result = Navigation.resolve(snapshot, focus, direction)
  if result.kind == "move" then
    controller:setFocus(result.targetId)
  end
  return result
end

local function computeLayout(view, width, height)
  return Layout.compute(view, width, height, {
    lineHeight = 14,
    measure = function(text)
      return #text * 7
    end,
  })
end

local function bagView(rows, page0)
  local keys = { "items", "medicine", "balls", "battle_items", "berries", "mail", "key_items", "machines" }
  local tabs, pockets = {}, {}
  for index, key in ipairs(keys) do
    tabs[index] = { x = (index - 1) * 32, y = 0, width = 32, height = 32 }
    pockets[index] = { key = key }
  end
  local pageCount = math.max(1, math.ceil(#rows / 6))
  page0 = math.min(pageCount - 1, page0 or 0)
  local pageRows = {}
  for index = page0 * 6 + 1, math.min(#rows, page0 * 6 + 6) do
    pageRows[#pageRows + 1] = rows[index]
  end
  return {
    section = "Bag",
    status = "ready",
    ready = true,
    dirty = false,
    bagPocket = "balls",
    bagPocketTabRects = tabs,
    bagPocketStrip = { image = "bag/balls.png" },
    bagQuantityVisuals = {},
    bagPockets = pockets,
    bagRows = rows,
    bagPageRows = pageRows,
    bagPage0 = page0,
    bagPageCount = pageCount,
    bagSelectedItem = nil,
    bagSelectedQuantity = nil,
  }
end

local function targetCenter(layout, targetId)
  local target = assert(layout.targets[targetId], "the active page must publish " .. targetId)
  local rect = target.rect
  return rect.x + rect.width / 2, rect.y + rect.height / 2
end

function T.bag_layout_publishes_native_tabs_six_cells_and_separate_add()
  local view = bagView({ { item = "POKE_BALL", label = "Poké Ball", quantity = 3 } })
  local layout = computeLayout(view, 800, 600)
  local pocketX, pocketY = targetCenter(layout, "bag:pocket:balls")
  local itemX, itemY = targetCenter(layout, "bag:item:POKE_BALL")
  Assert.equal(Layout.hitTest(layout, view, pocketX, pocketY), "bag:pocket:balls")
  Assert.equal(Layout.hitTest(layout, view, itemX, itemY), "bag:item:POKE_BALL")
  Assert.equal(#layout.bagGrid, 1, "only occupied cells are published")
  Assert.notNil(layout.targets["bag:add"], "Add remains outside the grid")
  Assert.isNil(layout.targets["bag:pocket:choose"], "pocket names are removed")
  Assert.isNil(layout.targets["bag:quantity"], "item actions are modal-owned")
  local compact = computeLayout(view, 256, 192)
  Assert.notNil(compact.targets["bag:pocket:balls"], "compact screens retain icon tabs")
  Assert.notNil(compact.targets["bag:add"], "compact screens retain separate Add")
end

local function regionsOverlap(first, second)
  return first.x < second.x + second.width
    and second.x < first.x + first.width
    and first.y < second.y + second.height
    and second.y < first.y + first.height
end

function T.bag_cards_expose_icon_name_and_quantity_regions_without_descriptions()
  local rows = {
    {
      item = "POTION",
      iconKey = "POTION",
      label = "Potion with an intentionally long display name",
      description = "Restores a small amount of HP.",
      quantity = 999,
    },
    {
      item = "ANTIDOTE",
      iconKey = "ANTIDOTE",
      label = "Antidote",
      description = "Cures poison.",
      quantity = 1,
    },
  }
  for _, dimensions in ipairs({ { 256, 192 }, { 800, 600 } }) do
    local layout = computeLayout(bagView(rows, 0), dimensions[1], dimensions[2])
    Assert.equal(#layout.bagGrid, 2, "occupied cells are published")
    for _, card in ipairs(layout.bagGrid) do
      Assert.isNil(card.description, "cards carry no description")
      Assert.isNil(card.textRect, "cards no longer use the shared text region")
      local regions = {}
      for _, key in ipairs({ "iconRect", "nameRect", "quantityRect" }) do
        local region = assert(card[key], "cards publish " .. key)
        Assert.isTrue(region.width > 0 and region.height > 0, key .. " stays positive")
        Assert.isTrue(region.x >= card.rect.x, key .. " starts inside its card")
        Assert.isTrue(region.x + region.width <= card.rect.x + card.rect.width + 0.01, key .. " ends inside its card")
        Assert.isTrue(region.y >= card.rect.y, key .. " stays below the card top")
        Assert.isTrue(
          region.y + region.height <= card.rect.y + card.rect.height + 0.01,
          key .. " stays above the card bottom"
        )
        regions[#regions + 1] = region
      end
      for first = 1, #regions do
        for second = first + 1, #regions do
          Assert.isFalse(regionsOverlap(regions[first], regions[second]), "card content regions never overlap")
        end
      end
      Assert.notNil(layout.targets[card.targetId], "cards keep their hit targets")
    end
  end
end

local function stripView(count)
  local slots = {}
  for position = 1, 6 do
    if position <= count then
      slots[position] = {
        kind = "member",
        slot0 = position - 1,
        iconKey = "party/species-" .. position,
        label = "Member " .. position,
        level = 5,
        active = position == 1,
      }
    elseif position == count + 1 then
      slots[position] = { kind = "add", slot0 = count }
    else
      slots[position] = { kind = "empty" }
    end
  end
  return {
    section = "Party",
    status = "ready",
    ready = true,
    dirty = false,
    partyTab = "Stats",
    partySlot0 = count > 0 and 0 or nil,
    partySelector = { slots = slots },
    partyMemberCount = count,
  }
end

function T.compact_party_keeps_occupied_member_and_add_cards_reachable()
  local compact = computeLayout(stripView(5), 256, 192)
  Assert.notNil(compact.targets["party:add"], "the compact strip must keep Add visible")
  local focusable = {}
  for _, targetId in ipairs(compact.focusOrder) do
    focusable[targetId] = true
  end
  Assert.isTrue(focusable["party:slot:4"], "keyboard and controller focus must include every strip member")
  local addX, addY = targetCenter(compact, "party:add")
  Assert.equal(Layout.hitTest(compact, stripView(5), addX, addY), "party:add")
end

function T.party_strip_and_pager_fit_compact_and_tall_layouts()
  for _, size in ipairs({ { 256, 192 }, { 360, 640 }, { 800, 600 } }) do
    local view = stripView(5)
    view.partyTab = "Stats"
    view.partyStats = {
      header = {
        { id = "level", label = "Level", value = 5, targetId = "party:field:level", editor = { kind = "integer" } },
      },
      rows = {},
    }
    local layout = computeLayout(view, size[1], size[2])
    local first = assert(layout.partyStrip.slots[1])
    Assert.isTrue(first.rect.y > layout.content.y, "Party member cells keep a visible top gutter")
    for _, slot in ipairs(layout.partyStrip.slots) do
      Assert.isTrue(slot.rect.x >= layout.content.x, "member cell begins within the content pane")
      Assert.isTrue(slot.rect.x + slot.rect.width <= layout.content.x + layout.content.width)
      if slot.iconRect ~= nil then
        Assert.isTrue(slot.iconRect.y >= slot.rect.y, "member icon remains inside its touch and focus cell")
        Assert.isTrue(slot.iconRect.y + slot.iconRect.height <= slot.rect.y + slot.rect.height)
      end
    end
    local previous = assert(layout.targets["party:page:previous"]).rect
    local label = assert(layout.partyPageLabel).rect
    local nextPage = assert(layout.targets["party:page:next"]).rect
    Assert.equal(previous.y, label.y, "the pager label and arrows share a baseline")
    Assert.equal(previous.y, nextPage.y, "pager arrows share a baseline")
    Assert.equal(previous.height, label.height, "pager components have aligned control bounds")
    Assert.equal(previous.height, nextPage.height)
    Assert.isTrue(
      label.width <= #layout.partyPageLabel.text * 7 + 16,
      "the pager label uses measured text width and padding"
    )
    local clusterLeft, clusterRight = previous.x, nextPage.x + nextPage.width
    Assert.isTrue(
      math.abs((clusterLeft + clusterRight) / 2 - (layout.content.x + layout.content.width / 2)) <= 1,
      "the tight pager cluster is centered in the content pane"
    )
  end
end

function T.party_grid_places_members_and_add_in_occupied_six_cell_positions()
  for _, count in ipairs({ 0, 1, 5, 6 }) do
    local layout = computeLayout(stripView(count), 800, 600)
    Assert.equal(#layout.partyStrip.slots, 6, "the strip always spans six positions")
    for index = 0, count - 1 do
      local targetId = "party:slot:" .. index
      Assert.notNil(layout.targets[targetId], "every member stays selectable")
      local slot = assert(layout.partyStrip.slots[index + 1])
      Assert.isNil(slot.textRect, "occupied slots expose no member text geometry")
      Assert.equal(
        slot.iconRect.x,
        slot.rect.x + (slot.rect.width - slot.iconRect.width) / 2,
        "member icons stay centered"
      )
    end
    if count < 6 then
      Assert.notNil(layout.targets["party:add"], "Add marks the first empty position")
    else
      Assert.isNil(layout.targets["party:add"], "a full party offers no Add position")
    end
    for index = count + 1, 5 do
      Assert.isNil(layout.targets["party:slot:" .. index], "positions past Add stay non-focusable")
    end
  end
end
function T.party_cards_use_bounded_icon_left_geometry_and_keep_grid_edges()
  for _, width in ipairs({ 256, 1280 }) do
    local layout = computeLayout(stripView(5), width, width == 256 and 192 or 720)
    local first = assert(layout.partyStrip.slots[1])
    Assert.isTrue(first.rect.x >= layout.content.x, "strip positions stay within the content bounds")
    Assert.isNil(first.textRect, "occupied Party slots have no text geometry")
    Assert.equal(first.iconRect.x, first.rect.x + (first.rect.width - first.iconRect.width) / 2)
    if width > 280 then
      local last = assert(layout.partyStrip.slots[6])
      local stripWidth = last.rect.x + last.rect.width - first.rect.x
      Assert.isTrue(stripWidth <= layout.content.width, "the strip never exceeds its content width")
    end
    local stripController = Controller.new()
    stripController:setFocus("party:slot:0")
    navigate(stripController, layout, "right")
    Assert.equal(stripController.focus, "party:slot:1", "Right follows the declared member strip order")
    stripController:setFocus("party:slot:1")
    navigate(stripController, layout, "right")
    Assert.equal(stripController.focus, "party:slot:2", "Right follows the declared member strip order")
  end
end

function T.party_detail_actions_use_compact_rows_without_losing_reachability()
  local view = stripView(1)
  view.partyTab = "Details"
  view.partyDetails = {
    rows = {
      {
        role = "integer value",
        targetId = "party:field:trainerId",
        id = "trainerId",
        label = "Trainer ID",
        value = 123,
        enabled = true,
      },
      {
        role = "action",
        targetId = "party:field:trainerName",
        id = "trainerName",
        label = "Trainer name",
        enabled = true,
      },
      { role = "action", targetId = "party:field:nickname", id = "nickname", label = "Nickname", enabled = true },
      {
        role = "action",
        targetId = "party:use-species-name",
        id = "use-species-name",
        label = "Use species name",
        enabled = true,
      },
    },
  }
  local normalHeight
  for _, size in ipairs({ { 800, 600 }, { 1280, 720 } }) do
    local layout = computeLayout(view, size[1], size[2])
    normalHeight = assert(layout.targets["party:field:trainerId"]).rect.height
    for _, targetId in ipairs({ "party:field:trainerName", "party:field:nickname", "party:use-species-name" }) do
      local rect = assert(layout.targets[targetId], targetId .. " stays reachable").rect
      Assert.isTrue(rect.height <= normalHeight + 2, targetId .. " uses compact body height")
      Assert.isTrue(rect.height >= 20, targetId .. " keeps a usable hit target")
      Assert.equal(
        Layout.hitTest(layout, view, rect.x + rect.width / 2, rect.y + rect.height / 2),
        targetId,
        targetId .. " remains pointer reachable"
      )
    end
  end
  local compact = computeLayout(view, 256, 192)
  Assert.notNil(compact.viewports.party, "compact Details keeps its body viewport")
  Assert.isTrue(
    compact.viewports.party.contentExtent >= normalHeight * #view.partyDetails.rows,
    "compact rows remain part of the scrollable body"
  )
end
function T.bag_pages_six_items_and_keeps_add_outside_grid()
  local rows = {}
  for index = 1, 7 do
    rows[index] = { item = "ITEM_" .. index, label = "Item " .. index, quantity = index }
  end
  local first = bagView(rows, 0)
  local firstLayout = computeLayout(first, 256, 192)
  Assert.equal(#firstLayout.bagGrid, 6, "the first page publishes six occupied cells")
  Assert.isNil(firstLayout.targets["bag:item:ITEM_7"], "later page cards are not hit targets")
  Assert.isFalse(hasFocus(firstLayout, "bag:page:previous"), "Previous is not focusable on the first page")
  Assert.notNil(firstLayout.targets["bag:add"], "Add remains a separate control")
  local second = bagView(rows, 1)
  local secondLayout = computeLayout(second, 256, 192)
  Assert.equal(#secondLayout.bagGrid, 1, "the last page has no empty cards")
  Assert.notNil(secondLayout.targets["bag:item:ITEM_7"], "Next page exposes its first occupied item")
  Assert.isFalse(hasFocus(secondLayout, "bag:page:next"), "Next is not focusable on the last page")
  local actionModal = bagView(rows, 1)
  actionModal.modal = "bag-item"
  actionModal.bagSelectedItem, actionModal.bagSelectedLabel, actionModal.bagSelectedQuantity = "ITEM_7", "Item 7", 7
  actionModal.scope = { id = "decision:bag-item", epoch = 1, kind = "decision" }
  local modalLayout = computeLayout(actionModal, 256, 192)
  Assert.notNil(modalLayout.targets["bag:quantity"], "item modal offers Quantity")
  Assert.notNil(modalLayout.targets["bag:remove"], "item modal offers Remove")
  Assert.notNil(modalLayout.targets.cancel, "item modal offers Cancel")
  Assert.isNil(modalLayout.targets["bag:item:ITEM_7"], "modal scope hides background cards")
end

function T.nickname_blank_and_clear_have_distinct_raw_results()
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(0x12345678, catalog)
  local mon = factory:createNormal(CatalogFixture.normalRequest())
  mon.nickname = nil
  local context = { monCatalog = catalog, itemCatalog = CatalogFixture.makeItemCatalog() }
  local partyView = PartyView.new(context)
  local Draft = require("app.src.saveeditor.SaveEditorMonDraft")
  local draftRecord =
    Draft.new({ mode = "edit", slot0 = 0, basePartyRevision = 0, record = mon, context = { catalog = catalog } })
  local details = partyView:details(draftRecord:record(), draftRecord:projection()).rows
  local nickname
  local useSpeciesName
  for _, row in ipairs(details) do
    if row.id == "nickname" then
      nickname = row
    elseif row.id == "use-species-name" then
      useSpeciesName = row
    end
  end
  Assert.notNil(nickname)
  Assert.equal(nickname.editor.value, "", "nil nickname is displayed as blank for text entry")

  local assignedField, assignedValue
  local draft = {
    setScalar = function(_, fieldId, value)
      assignedField, assignedValue = fieldId, value
      return true
    end,
  }
  local blankState = setmetatable({
    valueEditor = {
      result = function()
        return { kind = "confirm", value = "" }
      end,
      snapshot = function()
        return { kind = "name" }
      end,
      dispose = function() end,
    },
    activeDraftField = nickname.editor,
    monDraft = draft,
    modalStack = modalStackWith("name"),
  }, SaveEditorState)
  blankState:_finishValueEditor()
  Assert.equal(assignedField, "nickname")
  Assert.equal(assignedValue, "", "confirming blank text stores an empty nickname, not nil")
  Assert.notNil(useSpeciesName, "nil must be an explicit action separate from entering an empty string")

  assignedField, assignedValue = nil, "not cleared"
  Assert.equal(
    useSpeciesName.label,
    "Use species name",
    "the explicit action is player-facing instead of technical state"
  )
  local clearState = setmetatable({
    status = "ready",
    controller = { section = "Party", partySlot0 = 0, modal = nil },
    session = {
      partySnapshot = function()
        return { members = { { slot0 = 0, mon = mon } } }
      end,
      partyRevision = function()
        return 0
      end,
      beginMonEdit = function()
        return draft
      end,
    },
    monDraft = nil,
  }, SaveEditorState)
  draft.mode = function()
    return "edit"
  end
  draft.slot0 = function()
    return 0
  end
  draft.basePartyRevision = function()
    return 0
  end
  SaveEditorState._dispatchActivationAction(clearState, { kind = "party.use-species-name" })
  Assert.equal(assignedField, "nickname")
  Assert.isNil(assignedValue, "the explicit action stores nil")
end
function T.visible_party_rows_prepare_only_their_icon_keys()
  local Renderer = require("app.src.saveeditor.SaveEditorRenderer")
  local AssetPreparationQueue = require("libs.hgss.src.presentation.AssetPreparationQueue")
  local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")
  local queueNew, providerNew = AssetPreparationQueue.new, MonIconAssetProvider.new
  local prepared, released = {}, 0
  AssetPreparationQueue.new = function()
    return {
      release = function()
        released = released + 1
      end,
    }
  end
  MonIconAssetProvider.new = function()
    return {
      prepareKeys = function(_, keys)
        prepared = keys
        return true, nil
      end,
      image = function()
        return {}
      end,
      quadFor = function()
        return {}
      end,
      dimensions = function()
        return { width = 32, height = 32 }
      end,
      release = function()
        released = released + 1
      end,
    }
  end

  local ok, err = xpcall(function()
    local renderer = Renderer.new({ text = {}, graphics = {}, versionId = "heartgold" })
    renderer:prepareVisibleIcons({ section = "Party" }, {
      content = {
        layout = {
          targets = {},
          rows = { { iconKey = "0001:0" }, { iconKey = "0004:0" } },
          partyStrip = { slots = { { iconKey = "0007:0" } } },
        },
      },
    }, {}, {})
    Assert.deepEqual(prepared, { "0001:0", "0004:0", "0007:0" }, "visible party icons must be prepared outside draw")
    renderer:dispose()
  end, debug.traceback)
  AssetPreparationQueue.new, MonIconAssetProvider.new = queueNew, providerNew
  if not ok then
    error(err, 0)
  end
  Assert.equal(released, 2, "disposing the renderer releases its icon provider and preparation queue")
end
function T.controller_cancel_clears_pending_removal()
  local controller = Controller.new()
  controller:openModal("remove")
  local state = setmetatable({
    controller = controller,
    pendingRemove = { kind = "party", slot0 = 0 },
  }, SaveEditorState)

  state:_dispatchIntent(controller:press("cancel"))

  Assert.isNil(state.pendingRemove, "Escape/gamepad cancel drops the pending removal record")
end

function T.close_cancel_restores_an_open_removal_decision_without_resolving_it()
  local controller = Controller.new()
  controller:openModal("remove")
  local pendingRemove = { kind = "party", slot0 = 0 }
  local draft = {
    mode = function()
      return "add"
    end,
  }
  local valueEditor = ValueEditor.new({ kind = "integer", value = 12, min = 0, max = 999, base = "decimal" })
  Assert.isTrue(valueEditor:textinput("x"))
  local session = {
    isDirty = function()
      return true
    end,
  }
  local state = setmetatable({
    controller = controller,
    modalStack = modalStackWith("bag-remove"),
    modalLayerSequence = 0,
    activeScopeId = "decision:remove",
    activeScopeRevision = "decision:remove",
    scopeEpoch = 0,
    inputTick = 0,
    fieldInput = { beginUi = function() end },
    numberHold = nil,
    numberPressTarget = nil,
    session = session,
    monDraft = draft,
    valueEditor = valueEditor,
    valuePurpose = "money",
    pendingRemove = pendingRemove,
  }, SaveEditorState)

  Assert.isTrue(state:requestClose("quit"), "work at all levels vetoes process exit synchronously")
  Assert.equal(state.monDraft, draft, "the close prompt leaves the mon draft live")
  Assert.equal(state.pendingRemove, pendingRemove, "the close prompt does not resolve the removal")
  state:_dispatchIntent(controller:press("cancel"))

  Assert.equal(controller.modal, "remove", "Cancel restores the decision the user was already making")
  Assert.equal(state.pendingRemove, pendingRemove, "Cancel leaves the removal pending for an explicit choice")
  Assert.equal(state.monDraft, draft, "Cancel keeps the raw draft available")
  Assert.equal(state.valueEditor, valueEditor, "Cancel keeps the nested value editor available")
  Assert.equal(valueEditor:snapshot().buffer, "x", "Cancel preserves the exact nested value buffer")
end

function T.clean_edit_draft_does_not_veto_quit()
  local controller = Controller.new()
  local draft = {
    mode = function()
      return "edit"
    end,
    isDirty = function()
      return false
    end,
  }
  local state = setmetatable({
    approvedExit = false,
    disposed = false,
    pendingLocationSave = nil,
    closeRequest = nil,
    valueEditor = nil,
    monDraft = draft,
    session = {
      isDirty = function()
        return false
      end,
    },
    controller = controller,
  }, SaveEditorState)

  Assert.isFalse(state:requestClose("quit"), "a clean edit draft is not pending user work")
  Assert.isNil(state.closeRequest, "a clean edit draft does not create a close decision")
  Assert.isNil(controller.modal, "a clean edit draft does not open the leave dialog")
end

function T.rejected_raw_field_publication_keeps_its_value_editor_recoverable()
  local editor = ValueEditor.new({ kind = "integer", value = 12, min = 0, max = 999, base = "decimal" })
  Assert.isTrue(editor:textinput("73"))
  Assert.isTrue(editor:submit())
  local draft = {
    setScalar = function()
      return false
    end,
  }
  local state = setmetatable({
    valueEditor = editor,
    valuePurpose = "party_field",
    activeDraftField = { setter = "scalar", fieldId = "experience" },
    monDraft = draft,
  }, SaveEditorState)

  Assert.isFalse(state:_finishValueEditor(), "a rejected domain write must be reported")
  Assert.equal(state.valueEditor, editor, "the editor remains live after a rejected write")
  Assert.equal(state.valuePurpose, "party_field", "the editor purpose remains attached to the buffer")
  Assert.isNil(editor:result(), "the refused confirmation becomes editable again")
  Assert.equal(editor:snapshot().buffer, "73", "the exact entered value remains available for correction")
end

function T.progress_focus_keeps_offscreen_flag_rows_reachable_with_sparse_neighbors()
  local view = {
    section = "Progress",
    status = "ready",
    ready = true,
    dirty = false,
    flagFilter = "All",
    flagRows = {},
  }
  local rowTargets, indexByTarget = {}, {}
  for index = 1, 1200 do
    view.flagRows[index] = { name = "SYNTHETIC_FLAG_" .. index, value = index % 2 == 0 }
    local targetId = "flag:SYNTHETIC_FLAG_" .. index
    rowTargets[index] = targetId
    indexByTarget[targetId] = index
  end
  view.flagRowTargets = rowTargets
  view.flagIndexByTarget = indexByTarget
  view.flagRowAt = function(index)
    return view.flagRows[index]
  end
  view.flagModel = {
    revision = 1,
    queryRevision = 0,
    pending = false,
    count = #rowTargets,
    rowTargets = rowTargets,
    indexByTarget = indexByTarget,
    idAt = function(index)
      return rowTargets[index]
    end,
    indexOf = function(targetId)
      return indexByTarget[targetId]
    end,
    rowAt = view.flagRowAt,
  }

  local layout = computeLayout(view, 800, 600)
  local middleIndex = 600
  local middle = "flag:" .. view.flagRows[middleIndex].name
  Assert.equal(#layout.lists.flags.rowTargets, 1200, "the logical flag order stays complete")
  Assert.equal(
    layout.viewports.flags.rowTargets[middleIndex],
    middle,
    "the viewport keeps the logical index of every semantic row"
  )
  Assert.isNil(layout.targets[middle], "an offscreen semantic row shares no per-frame target")
  Assert.isTrue(hasFocus(layout, middle), "an offscreen semantic row remains logically focusable")
  local visibleFirst = layout.viewports.flags.firstIndex
  local firstTarget = rowTargets[visibleFirst]
  Assert.isTrue(hasFocus(layout, firstTarget), "the first visible semantic row keeps its navigation control")
  if visibleFirst > 1 then
    local listRegion
    for _, region in ipairs(layout.focusNavigation.regions) do
      if region.id == "flags" then
        listRegion = region
      end
    end
    Assert.notNil(listRegion, "the list region retains its logical order")
  end
  Assert.isTrue(
    table.concat(layout.viewports.flags.rowTargets, "\n"):find(middle, 1, true) ~= nil,
    "the viewport still addresses the offscreen row by its logical identity"
  )

  local scrolledView = {
    section = view.section,
    status = view.status,
    ready = view.ready,
    dirty = view.dirty,
    flagFilter = view.flagFilter,
    flagRows = view.flagRows,
    flagRowAt = view.flagRowAt,
    flagModel = view.flagModel,
    flagRowTargets = view.flagRowTargets,
    flagIndexByTarget = view.flagIndexByTarget,
    scrollOffsets = { flags = (middleIndex - 2) * layout.viewports.flags.rowExtent },
  }
  local scrolled = computeLayout(scrolledView, 800, 600)
  Assert.isTrue(hasFocus(scrolled, middle), "the revealed semantic row joins the navigation controls")
  local previous = "flag:" .. view.flagRows[middleIndex - 1].name
  local following = "flag:" .. view.flagRows[middleIndex + 1].name
  Assert.isTrue(
    hasFocus(scrolled, previous) and hasFocus(scrolled, following),
    "the revealed window also materializes the immediate semantic neighbors"
  )
  Assert.notNil(scrolled.targets[middle], "the same semantic row can be revealed by its viewport")

  local controller = Controller.new()
  controller:setFocus(firstTarget)
  navigate(controller, layout, "down")
  Assert.equal(
    controller.focus,
    rowTargets[visibleFirst + 1],
    "controller movement steps through the materialized window"
  )
end

function T.disabled_bag_and_footer_actions_are_not_focusable_or_pointer_targets()
  local function assertDisabled(layout, view, targetId)
    local target = assert(layout.targets[targetId], "disabled actions remain rendered: " .. targetId)
    Assert.isFalse(target.focusable, targetId .. " is absent from keyboard/controller focus")
    Assert.isFalse(target.activationEnabled, targetId .. " remains visibly disabled")
    Assert.isNil(
      Layout.hitTest(layout, view, target.rect.x + target.rect.width / 2, target.rect.y + target.rect.height / 2),
      targetId .. " is not an activatable pointer target"
    )
    Assert.isFalse(hasFocus(layout, targetId), targetId .. " is absent from active navigation")
    for _, focusId in ipairs(layout.focusOrder) do
      Assert.isFalse(focusId == targetId, targetId .. " is absent from focus order")
    end
  end

  local bag = bagView({})
  local bagLayout = computeLayout(bag, 800, 600)
  Assert.isNil(bagLayout.targets["bag:quantity"], "normal Bag has no inline quantity action")
  Assert.isNil(bagLayout.targets["bag:remove"], "normal Bag has no inline remove action")
  assertDisabled(bagLayout, bag, "bag:page:previous")
  assertDisabled(bagLayout, bag, "bag:page:next")
  assertDisabled(bagLayout, bag, "save")

  local stats = stripView(2)
  stats.dirty = false
  local statsLayout = computeLayout(stats, 800, 600)
  Assert.isTrue(statsLayout.targets["party:page:previous"].activationEnabled, "Party Previous wraps from Stats")
  assertDisabled(statsLayout, stats, "save")
  Assert.isNil(statsLayout.targets["party:move-up"], "reorder controls are removed")
  Assert.isNil(statsLayout.targets["party:move-down"], "reorder controls are removed")
  Assert.isNil(statsLayout.targets["party:remove"], "member removal has no target")

  local details = stripView(2)
  details.partyTab = "Details"
  local detailsLayout = computeLayout(details, 800, 600)
  Assert.isTrue(detailsLayout.targets["party:page:next"].activationEnabled, "Party Next wraps from Details")
  Assert.notNil(detailsLayout.targets["back"], "the normal Back affordance remains available")
end
function T.bag_cards_stay_bounded_and_centered_on_large_screens()
  local bagRows = {}
  for index = 1, 3 do
    bagRows[index] = { item = "ITEM_" .. index, label = "Item " .. index, quantity = index }
  end
  local bagLayout = computeLayout(bagView(bagRows, 0), 1280, 720)
  local bagCard = assert(bagLayout.bagGrid[1]).rect
  Assert.isTrue(bagCard.width <= 128, "Bag cards never exceed the source cell width")
  local bagLeft, bagRight = bagCard.x, bagCard.x + bagCard.width
  for _, cell in ipairs(bagLayout.bagGrid) do
    bagLeft = math.min(bagLeft, cell.rect.x)
    bagRight = math.max(bagRight, cell.rect.x + cell.rect.width)
  end
  Assert.isTrue(
    math.abs((bagLeft - bagLayout.content.x) - (bagLayout.content.x + bagLayout.content.width - bagRight)) < 2,
    "the bounded Bag grid stays centered on large screens"
  )
end
function T.party_add_is_a_small_bounded_button_in_the_next_slot()
  for _, count in ipairs({ 0, 1, 4, 5 }) do
    for _, size in ipairs({ { 256, 192 }, { 1280, 720 } }) do
      local view = stripView(count)
      local layout = computeLayout(view, size[1], size[2])
      local add = assert(layout.targets["party:add"], count .. " members keep Add visible").rect
      local strip = assert(layout.partyStrip).slots[count + 1]
      Assert.equal(strip.kind, "add", "Add marks the first empty strip position")
      Assert.isTrue(
        add.x >= layout.content.x and add.x + add.width <= layout.content.x + layout.content.width,
        "Add stays inside the content bounds"
      )
      Assert.equal(Layout.hitTest(layout, view, add.x + add.width / 2, add.y + add.height / 2), "party:add")
    end
  end
  local full = computeLayout(stripView(6), 800, 600)
  Assert.isNil(full.targets["party:add"], "a full party offers no Add position")
end
function T.wide_bag_pocket_tabs_keep_left_and_right_on_pockets()
  local rows = { { item = "POKE_BALL", label = "Poke Ball", quantity = 3 } }
  local layout = computeLayout(bagView(rows, 0), 800, 600)
  local keys = { "items", "medicine", "balls", "battle_items", "berries", "mail", "key_items", "machines" }
  for index, key in ipairs(keys) do
    local targetId = "bag:pocket:" .. key
    local previous = keys[(index - 2) % #keys + 1]
    local following = keys[index % #keys + 1]
    Assert.isTrue(hasFocus(layout, targetId), targetId .. " stays in its navigation region")
    local controller = Controller.new()
    controller:setSection("Bag")
    controller:setFocus(targetId)
    navigate(controller, layout, "left")
    Assert.equal(controller.focus, "bag:pocket:" .. previous, targetId .. " Left stays on pockets")
    navigate(controller, layout, "right")
    Assert.equal(controller.focus, targetId, targetId .. " returns to its pocket")
  end

  local controller = Controller.new()
  controller:setSection("Bag")
  controller:setFocus("bag:pocket:balls")
  navigate(controller, layout, "left")
  Assert.equal(controller.focus, "bag:pocket:medicine", "Left from a middle pocket selects the previous pocket")
  controller:setFocus("bag:pocket:items")
  navigate(controller, layout, "left")
  Assert.equal(controller.focus, "bag:pocket:machines", "Left from the first pocket wraps to the last")
end

local function structuredMon(species, level, nickname)
  local catalog = CatalogFixture.makeCatalog()
  local context = CatalogFixture.domainContext(catalog)
  local factory = CatalogFixture.makeFactory(0x12345678, catalog)
  local mon = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level or 9 }))
  if nickname ~= nil then
    mon.nickname = nickname
  end
  local Draft = require("app.src.saveeditor.SaveEditorMonDraft")
  local draft = Draft.new({ mode = "edit", slot0 = 0, basePartyRevision = 0, record = mon, context = context })
  return catalog, context, draft:record(), draft:projection()
end

local function structuredView()
  local catalog = CatalogFixture.makeCatalog()
  local context = { monCatalog = catalog, itemCatalog = CatalogFixture.makeItemCatalog() }
  return catalog, PartyView.new(context)
end

function T.persistent_selector_lists_members_first_add_and_empty_positions()
  local catalog, view = structuredView()
  local factory = CatalogFixture.makeFactory(0x12345678, catalog)
  local members = {}
  for slot0, species in ipairs({ "CHIKORITA", "TOTODILE", "EEVEE" }) do
    members[#members + 1] = {
      slot0 = slot0 - 1,
      mon = factory:createNormal(CatalogFixture.normalRequest({ species = species })),
    }
  end
  local slots = view:selector(members, 0).slots
  Assert.equal(#slots, 6, "the strip always spans six positions")
  Assert.deepEqual(
    { slots[1].kind, slots[2].kind, slots[3].kind, slots[4].kind, slots[5].kind, slots[6].kind },
    { "member", "member", "member", "add", "empty", "empty" }
  )
  Assert.isTrue(slots[1].active, "the first member is selected by default")
  Assert.isFalse(slots[2].active or slots[3].active, "only one member stays selected")
  for index = 1, 3 do
    Assert.notNil(slots[index].iconKey, "member position " .. index .. " carries its sprite identity")
    Assert.notNil(slots[index].descriptiveLabel, "member position " .. index .. " retains descriptive metadata")
  end
  Assert.equal(slots[4].slot0, 3, "the add control marks the first empty position")

  local emptySlots = view:selector({}, nil).slots
  Assert.equal(emptySlots[1].kind, "add", "an empty party offers + Add first")
  Assert.isNil(emptySlots[1].active, "no member is selected when the party is empty")
end

function T.details_projects_canonical_nature_names_without_mutating_personality()
  local catalog, view = structuredView()
  local _, context, record = structuredMon("EEVEE", 9, "Sparky")
  local Draft = require("app.src.saveeditor.SaveEditorMonDraft")
  local Personality = require("libs.mons.src.gen4.Personality")
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  for nature = 0, 24 do
    record.personality = nature
    local projection = Draft.projectRecord(record, { catalog = catalog })
    local details = view:details(record, projection)
    local row
    for _, detail in ipairs(details.rows) do
      if detail.id == "nature" then
        row = detail
      end
    end
    Assert.notNil(row, "Details keeps the derived nature row")
    Assert.equal(projection.nature, Personality.nature(record.personality))
    Assert.equal(row.value, HgssMonService.natureName(nature), "nature is displayed by its canonical name")
    Assert.equal(record.personality, nature, "display projection leaves personality untouched")
  end

  local draft = Draft.new({
    mode = "edit",
    slot0 = 0,
    basePartyRevision = 0,
    record = record,
    context = context,
  })
  local personality = draft:record().personality
  Assert.isTrue(draft:setScalar("friendship", 150), "an unrelated current stat remains editable")
  Assert.equal(draft:record().personality, personality, "editing a current stat preserves nature source data")
end

function T.stats_projection_exposes_header_and_iv_ev_table_without_derived_values()
  local _, view = structuredView()
  local _, _, mon, projection = structuredMon("CHIKORITA", 9)
  local stats = view:stats(mon, projection)
  local headerById = {}
  for _, fact in ipairs(stats.header) do
    headerById[fact.id] = fact
  end
  for _, id in ipairs({ "level", "experience", "friendship", "currentHp", "status" }) do
    Assert.notNil(headerById[id], "the stats header exposes " .. id)
  end
  Assert.equal(headerById.level.value, projection.level)
  Assert.equal(headerById.level.editor.min, 1)
  Assert.equal(headerById.level.editor.max, 100)
  Assert.equal(headerById.friendship.editor.max, 255)
  Assert.equal(headerById.currentHp.editor.max, assert(projection.stats).hp)
  Assert.isNil(headerById.status.editor, "status stays display-only")
  Assert.notNil(headerById.status.value, "status shows its player-facing label")
  Assert.equal(#stats.rows, 6, "every battle stat keeps one IV/EV row")
  for _, row in ipairs(stats.rows) do
    Assert.isNil(row.derived, "computed stat values are not shown")
    Assert.equal(row.ivEditor.editor.min, 0)
    Assert.equal(row.ivEditor.editor.max, 31)
    Assert.equal(row.evEditor.editor.min, 0)
    Assert.equal(row.evEditor.editor.max, 255)
  end
end

function T.moves_projection_publishes_four_slots_with_allowance_labels()
  local catalog, view = structuredView()
  local _, _, mon, _ = structuredMon("EEVEE", 5)
  while #mon.moves > 2 do
    table.remove(mon.moves)
  end
  local Draft = require("app.src.saveeditor.SaveEditorMonDraft")
  local slots = view:moves(mon).slots
  Assert.equal(#slots, 4, "the moves page always spans four slots")
  Assert.deepEqual({ slots[1].kind, slots[2].kind, slots[3].kind, slots[4].kind }, { "move", "move", "add", "empty" })
  for index = 1, 2 do
    local definition = catalog:move(mon.moves[index].move)
    local maxPp = Moves.maxPp(definition.basePp, mon.moves[index].ppUps)
    Assert.isTrue(slots[index].label:find(definition.name, 1, true) ~= nil, "slot names its move")
    Assert.isTrue(
      slots[index].label:find(mon.moves[index].pp .. "/" .. maxPp, 1, true) ~= nil,
      "slot labels current and maximum PP"
    )
    Assert.equal(slots[index].slot0, index - 1)
  end
end

function T.details_projection_keeps_player_facing_fields_and_omits_technical_state()
  local _, view = structuredView()
  local _, _, eevee, eeveeProjection = structuredMon("EEVEE", 9, "Sparky")
  local rowsById = {}
  for _, row in ipairs(view:details(eevee, eeveeProjection).rows) do
    rowsById[row.id] = row
  end
  for _, id in ipairs({
    "species",
    "form",
    "nickname",
    "use-species-name",
    "nature",
    "gender",
    "shiny",
    "ability",
    "heldItem",
    "trainerName",
    "trainerGender",
    "trainerId",
    "ball",
    "game",
    "language",
    "location",
    "year",
    "month",
    "day",
    "metLevel",
  }) do
    Assert.notNil(rowsById[id], "details keeps " .. id)
  end
  Assert.notNil(rowsById.form.editor, "a multi-form species keeps its form choice")
  Assert.isNil(rowsById.nature.editor, "nature stays derived")
  Assert.isNil(rowsById.gender.editor, "gender stays derived")
  Assert.isNil(rowsById.shiny.editor, "shininess stays derived")
  for _, id in ipairs({
    "personality",
    "species-native-id",
    "form-native-id",
    "ability-native-id",
    "pid-ability-slot",
    "growth-curve",
    "exp-interval",
    "terrain",
    "move",
    "native-id",
    "type",
    "power",
    "accuracy",
    "base-pp",
    "allowed-pp",
  }) do
    Assert.isNil(rowsById[id], "details omits technical field " .. id)
  end

  local _, _, chikorita, chikoritaProjection = structuredMon("CHIKORITA", 9)
  local singleFormById = {}
  for _, row in ipairs(view:details(chikorita, chikoritaProjection).rows) do
    singleFormById[row.id] = row
  end
  Assert.isNil(singleFormById.form, "a single-form species omits the form row entirely")
end

function T.storage_allowance_stays_distinct_from_the_ordinary_maximum()
  local Errors = require("libs.errors.src.Errors")
  local MonsErrors = require("libs.mons.src.errors")
  local Mon = require("libs.mons.src.Mon")
  local NativeLegality = require("libs.mons.src.gen4.NativeLegality")
  local catalog = CatalogFixture.makeCatalog()
  local context = CatalogFixture.domainContext(catalog)
  local factory = CatalogFixture.makeFactory(0x12345678, catalog)
  -- TOXIC carries base 10: the absolute ceiling is 16 while the ordinary
  -- maximum at zero ups is 10.
  local stored = factory:createNormal(CatalogFixture.normalRequest())
  stored.moves = { { move = "TOXIC", pp = 15, ppUps = 0 } }
  local valid, canonical = pcall(Mon.validate, stored, context)
  Assert.isTrue(valid, "a record under the absolute ceiling stays admissible")
  local legal, _ = pcall(NativeLegality.project, canonical, context)
  Assert.isTrue(legal, "a record under the absolute ceiling stays representable")
  Assert.equal(Moves.maxPp(10, 0), 10, "ordinary restoration still uses the actual ups")
  local viewContext = { monCatalog = catalog, itemCatalog = CatalogFixture.makeItemCatalog() }
  local slots = PartyView.new(viewContext):moves(stored).slots
  Assert.isTrue(
    slots[1].label:find("15/10", 1, true) ~= nil,
    "the draft label shows current points against the ordinary maximum"
  )
  stored.moves = { { move = "TOXIC", pp = 17, ppUps = 0 } }
  local stillValid, recordError = pcall(Mon.validate, stored, context)
  Assert.isFalse(stillValid, "points past the absolute ceiling stay inadmissible")
  Assert.isTrue(Errors.is(recordError), "the admission failure stays structured")
  Assert.equal(recordError.code, MonsErrors.RECORD_INVALID, "the admission failure keeps its code")
  local stillLegal, legalityError = pcall(NativeLegality.project, stored, context)
  Assert.isFalse(stillLegal, "points past the absolute ceiling stay unrepresentable")
  Assert.equal(legalityError.code, MonsErrors.LEGALITY_INVALID, "the representability failure keeps its code")
  Assert.equal(stored.moves[1].pp, 17, "a rejected record keeps its stored points without repair")
end

function T.shared_pp_arithmetic_drives_items_deposit_and_editors()
  local PartyItemEffects = require("libs.hgss.src.mons.PartyItemEffects")
  local itemCatalogFor = function(bases)
    return {
      move = function(_, key)
        local base = bases[key]
        assert(base ~= nil, "test catalog is missing move " .. tostring(key))
        return { basePp = base }
      end,
      item = function()
        return { friendshipBoost = false }
      end,
    }
  end
  local itemContext = { location = 7, catalog = itemCatalogFor({ SEVEN = 7, FOUR = 4 }) }
  local derived = { level = 9, maxHp = 30 }
  local function sevenMon(pp, ppUps, key)
    return {
      species = "CHIKORITA",
      form = 0,
      heldItem = "NONE",
      isEgg = false,
      friendship = 70,
      mood = 0,
      evs = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 },
      moves = { { move = key or "SEVEN", pp = pp, ppUps = ppUps } },
      origin = { ball = "POKE_BALL" },
      egg = { location = 7 },
      condition = { currentHp = 30, effects = {} },
    }
  end
  local boost = { kind = "pp", target = "one", boost = 1 }
  local boosted = PartyItemEffects.plan(sevenMon(4, 0), { partyUse = boost }, 0, itemContext, derived)
  Assert.equal(boosted.kind, "ready")
  Assert.equal(boosted.updates.moves[1].ppUps, 1, "one up is recorded")
  Assert.equal(
    boosted.updates.moves[1].pp,
    4 + (Moves.maxPp(7, 1) - Moves.maxPp(7, 0)),
    "spent points survive the shared maximum delta"
  )
  Assert.equal(Moves.maxPp(7, 1), 8, "the custom-base boost widens to the shared maximum")
  Assert.equal(
    PartyItemEffects.plan(sevenMon(11, 3), { partyUse = boost }, 0, itemContext, derived).kind,
    "no_effect",
    "three ups stay ineligible for another boost"
  )
  Assert.equal(
    PartyItemEffects.plan(sevenMon(4, 0, "FOUR"), { partyUse = boost }, 0, itemContext, derived).kind,
    "no_effect",
    "below-minimum bases stay ineligible for boosts"
  )
  local restore = { kind = "pp", target = "one", restore = 10 }
  local restored = PartyItemEffects.plan(sevenMon(2, 3), { partyUse = restore }, 0, itemContext, derived)
  Assert.equal(restored.kind, "ready")
  Assert.equal(restored.updates.moves[1].pp, Moves.maxPp(7, 3), "restoration caps at the shared maximum")
  Assert.equal(restored.updates.moves[1].pp, 11, "the custom-base cap keeps source rounding")

  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local MonsSave = require("libs.mons.src.MonsSave")
  local Party = require("libs.mons.src.Party")
  local Lcrng = require("libs.mons.src.gen4.Lcrng")
  local ItemFixture = require("libs.items.tests.item_fixture")
  local HgssBagService = require("libs.hgss.src.items.HgssBagService")
  local PcStorageActions = require("libs.hgss.src.field.PcStorageActions")
  local catalog = CatalogFixture.makeCatalog()
  local mons = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x44444444):capture()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  })
  local factory = CatalogFixture.makeFactory(0x55555555, catalog)
  Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "EEVEE" }))))
  local spent = mons:partyMon(0)
  spent.moves[1].pp = 1
  spent.moves[1].ppUps = 2
  local staged = assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 0, mon = spent } }))
  staged.publish()
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local actions = PcStorageActions.new({ mons = mons, bag = bag })
  local preview = actions:preview({
    kind = "deposit",
    source = { kind = "party", slot = 0 },
    destination = { kind = "box", box = 0, slot = 0 },
  })
  Assert.equal(preview.kind, "allowed")
  Assert.equal(actions:commit(preview).kind, "changed")
  local deposited = assert(mons:boxMon(0, 0))
  Assert.equal(deposited.moves[1].pp, Moves.maxPp(35, 2), "deposit restores through the shared authority")
  Assert.equal(deposited.moves[1].pp, 49, "deposit keeps the two-up restoration")

  local Draft = require("app.src.saveeditor.SaveEditorMonDraft")
  local draftContext = CatalogFixture.domainContext(catalog)
  local record = factory:createNormal(CatalogFixture.normalRequest({ species = "EEVEE", level = 5 }))
  record.moves = { { move = "TOXIC", pp = 8, ppUps = 0 } }
  local draft = Draft.new({ mode = "edit", slot0 = 0, basePartyRevision = 0, record = record, context = draftContext })
  Assert.isTrue(draft:setMove(0, "ppUps", 3))
  Assert.isFalse(
    draft:setMove(0, "pp", Moves.maxPp(10, 3) + 1),
    "points above the shared maximum never enter the draft"
  )
  local viewContext = { monCatalog = catalog, itemCatalog = CatalogFixture.makeItemCatalog() }
  local moveSlots = PartyView.new(viewContext):moves(draft:record()).slots
  Assert.isTrue(
    moveSlots[1].label:find("8/" .. Moves.maxPp(10, 3), 1, true) ~= nil,
    "the moves page labels the slot against the shared maximum"
  )
  local childState = setmetatable({
    pendingMoveSlot = 0,
    modalLayerSequence = 0,
    modalStack = require("app.src.saveeditor.SaveEditorModalStack").new(),
    monDraft = draft,
    dependencies = { context = { monCatalog = catalog } },
    controller = Controller.new(),
    valueEditor = nil,
  }, SaveEditorState)
  childState.controller:setFocus("party-move:pp")
  childState:_openMoveChild("party-move:pp")
  Assert.equal(
    childState.valueEditor:snapshot().maximum,
    Moves.maxPp(10, 3),
    "the move-child editor offers the shared maximum"
  )
end

function T.party_details_project_held_item_and_ball_options_from_mixed_catalog()
  local _, _, mon, projection = structuredMon("EEVEE", 9)
  local root = ItemFixture.buildAssetRoot()
  root.items["ember:EMBER_CHARM"] = {
    name = "Ember Charm",
    nameIndefinite = "an Ember Charm",
    namePlural = "Ember Charms",
    description = "A custom held item.",
    pocket = "items",
    preventToss = false,
    selectable = false,
    isBall = false,
    friendshipBoost = false,
    icon = "ember:EMBER_CHARM",
    isHm = false,
    canHold = true,
    heldFormEffect = "none",
    partyUse = { kind = "none" },
  }
  root.items["ember:MOON_BALL"] = {
    name = "Moon Ball",
    nameIndefinite = "a Moon Ball",
    namePlural = "Moon Balls",
    description = "A custom ball.",
    pocket = "balls",
    preventToss = false,
    selectable = true,
    isBall = true,
    friendshipBoost = false,
    icon = "ember:MOON_BALL",
    isHm = false,
    canHold = false,
    heldFormEffect = "none",
    partyUse = { kind = "none" },
  }
  local context = {
    monCatalog = CatalogFixture.makeCatalog(),
    itemCatalog = ItemCatalog.fromResolved(root),
  }
  local details = PartyView.new(context):details(mon, projection)
  local rowsById = {}
  for _, row in ipairs(details.rows) do
    rowsById[row.id] = row
  end

  local heldKeys, ballKeys = {}, {}
  for _, option in ipairs(assert(rowsById.heldItem).editor.options) do
    heldKeys[option.key] = true
  end
  for _, option in ipairs(assert(rowsById.ball).editor.options) do
    ballKeys[option.key] = true
    Assert.equal(context.itemCatalog:item(option.key).pocket, "balls", "Ball choices contain only balls")
  end
  Assert.isTrue(heldKeys["ember:EMBER_CHARM"], "the namespaced held item is selectable")
  Assert.isTrue(ballKeys["ember:MOON_BALL"], "the namespaced ball is selectable")
  Assert.isTrue(ballKeys.POKE_BALL, "native ball choices remain available")
  Assert.isFalse(ballKeys["ember:EMBER_CHARM"], "non-ball custom items remain outside Ball choices")
end

function T.bag_snapshot_reuses_catalog_and_pocket_metadata_until_revision_changes()
  local pocket = next(ItemAssetSchema.POCKETS)
  local counts = { itemKeys = 0, item = 0, pocket = 0, bagSnapshot = 0 }
  local catalog = {
    itemKeyIterator = function()
      local key = 0
      return function()
        key = key + 1
        if key > 8 then
          return nil
        end
        return ({ "NONE", "ITEM_ONE", "ITEM_TWO", "ITEM_THREE", "ITEM_FOUR", "ITEM_FIVE", "ITEM_SIX", "ITEM_SEVEN" })[key]
      end
    end,
    itemKeys = function()
      counts.itemKeys = counts.itemKeys + 1
      return { "NONE", "ITEM_ONE", "ITEM_TWO", "ITEM_THREE", "ITEM_FOUR", "ITEM_FIVE", "ITEM_SIX", "ITEM_SEVEN" }
    end,
    item = function(_, key)
      counts.item = counts.item + 1
      return { name = key == "NONE" and "None" or key, icon = key, pocket = pocket, nativeId = counts.item }
    end,
    pocket = function(_, key)
      counts.pocket = counts.pocket + 1
      return { nativeId = key == pocket and 1 or 2, maxQuantity = 99 }
    end,
    orderingKey = function(_, key)
      local itemIndex = key == "NONE" and 0 or tonumber(key:match("ITEM_(%u+)$"))
      if itemIndex == nil then
        itemIndex = ({ ONE = 1, TWO = 2, THREE = 3, FOUR = 4, FIVE = 5, SIX = 6, SEVEN = 7 })[key:match("ITEM_(%u+)$")]
      end
      return string.format("0:%06d", assert(itemIndex))
    end,
  }
  local revision, quantity = 1, 2
  local session = {
    revision = function()
      return revision
    end,
    bagSnapshot = function()
      counts.bagSnapshot = counts.bagSnapshot + 1
      local entries = {}
      for index = 1, 7 do
        entries[index] = {
          item = "ITEM_" .. ({ "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN" })[index],
          quantity = index == 1 and quantity or index,
        }
      end
      return entries
    end,
  }
  local manifest = {
    interactive = {
      pocketTabs = { rects = {}, strips = { [pocket] = {} } },
      focus = { tabs = { visual = {}, targets = {} } },
      overlays = { quantity = { visuals = {} } },
    },
  }
  local state = setmetatable({
    dependencies = { context = { itemCatalog = catalog }, bagManifest = manifest },
    session = session,
    controller = { bagPocket = pocket, bagPage0 = 0, bagItemKey = "ITEM_ONE" },
  }, SaveEditorState)
  while state._bagCatalogMetadata == nil do
    state:_advanceBagCatalog(256)
  end
  local first = state:_bagView()
  local firstCounts = { itemKeys = counts.itemKeys, item = counts.item, pocket = counts.pocket }
  local second = state:_bagView()
  Assert.equal(counts.itemKeys, firstCounts.itemKeys, "stable snapshots never rescan catalog keys")
  Assert.equal(counts.item, firstCounts.item, "stable snapshots reuse item descriptors")
  Assert.equal(counts.pocket, firstCounts.pocket, "stable snapshots reuse pocket descriptors")
  Assert.equal(counts.bagSnapshot, 1, "an unchanged session revision reuses its pocket rows")
  Assert.isTrue(rawequal(first.bagRows, second.bagRows), "stable snapshots retain cached row metadata")

  state.controller.bagPage0 = 1
  local secondPage = state:_bagView()
  Assert.equal(secondPage.bagPageRows[1].item, "ITEM_SEVEN", "page changes materialize the selected six-row slice")
  Assert.equal(counts.bagSnapshot, 1, "changing pages does not reread the pocket snapshot")
  Assert.isTrue(rawequal(first.bagRows, secondPage.bagRows), "page changes retain the cached row metadata")

  quantity = 3
  revision = revision + 1
  state.controller.bagPage0 = 0
  local changed = state:_bagView()
  Assert.equal(counts.itemKeys, firstCounts.itemKeys, "a bag revision does not rebuild catalog availability")
  Assert.equal(changed.bagPageRows[1].quantity, 3, "the next revision materializes current quantities")
  Assert.equal(first.bagPageRows[1].quantity, 2, "an earlier page keeps its published quantity")
  Assert.equal(counts.bagSnapshot, 2, "a new session revision rebuilds the selected pocket once")
end

function T.first_bag_snapshot_does_not_scan_or_materialize_the_item_catalog()
  local pocket = next(ItemAssetSchema.POCKETS)
  local controller = Controller.new()
  controller:setSection("Bag")
  controller:selectBagPocket(pocket)
  local catalogVisits, itemReads, iteratorCalls = 0, 0, 0
  local catalog = {
    itemKeyIterator = function()
      iteratorCalls = iteratorCalls + 1
      local key = 0
      return function()
        key = key + 1
        if key > 600 then
          return nil
        end
        catalogVisits = catalogVisits + 1
        return "ITEM_" .. key
      end
    end,
    itemKeys = function()
      error("Bag snapshots must not request a complete item-key list")
    end,
    item = function(_, key)
      itemReads = itemReads + 1
      return { name = key, pocket = pocket, nativeId = itemReads }
    end,
    pocket = function()
      return { nativeId = 1 }
    end,
    orderingKey = function(_, key)
      return string.format("0:%06d", tonumber(key:match("ITEM_(%d+)$")) or 0)
    end,
  }
  local state = setmetatable({
    dependencies = {
      context = { itemCatalog = catalog },
      bagManifest = {
        interactive = {
          pocketTabs = { rects = {}, strips = { [pocket] = {} } },
          focus = { tabs = { visual = {}, targets = {} } },
          overlays = { quantity = { visuals = {} } },
        },
      },
    },
    session = {
      revision = function()
        return 1
      end,
      bagSnapshot = function()
        return {}
      end,
    },
    controller = controller,
    tickRemainder = 0,
    inputTick = 0,
    scopeEpoch = 0,
    numberHold = nil,
    valueEditor = nil,
    disposed = false,
    status = "ready",
  }, SaveEditorState)

  local initial = state:_bagView()
  Assert.equal(iteratorCalls, 0, "the first snapshot does not start catalog enumeration")
  Assert.equal(catalogVisits, 0, "the first snapshot does not visit item keys")
  Assert.equal(itemReads, 0, "the first snapshot does not materialize item definitions")
  Assert.equal(#initial.bagRows, 0, "the pending catalog publishes an empty Bag projection")

  local fieldInput = require("libs.hgss.src.field.FieldInput")
  state.fieldInput = fieldInput.new()
  state:update(0)
  Assert.isTrue(catalogVisits > 0 and catalogVisits <= 256, "one update prepares only its row budget")
  Assert.isTrue(itemReads > 0 and itemReads <= 256, "one update materializes only its row budget")
  for _ = 1, 2 do
    state:_advanceBagCatalog(256)
  end
  Assert.isNil(state._bagCatalogMetadata, "catalog enumeration does not synchronously sort and publish all options")
  while state._bagCatalogMetadata == nil do
    local before = catalogVisits
    state:update(0)
    Assert.isTrue(catalogVisits - before <= 256, "later updates keep catalog enumeration bounded")
  end
  Assert.equal(catalogVisits, 600, "the preparation eventually visits every item key")
  Assert.isTrue(state:_bagView().bagAddEnabled, "the completed catalog publishes its pocket options")
end

function T.bag_catalog_orders_native_and_custom_items_with_bounded_work()
  local root = ItemFixture.buildAssetRoot()
  for key, name in pairs({
    ["ember:ZEPHYR_CHIME"] = "A Charm",
    ["ember:EMBER_CHARM"] = "Z Charm",
    ["ember:MOON_CHARM"] = "Moon Charm",
  }) do
    root.items[key] = {
      name = name,
      nameIndefinite = "a " .. name,
      namePlural = name .. "s",
      description = "A custom item.",
      pocket = "items",
      preventToss = false,
      selectable = true,
      isBall = false,
      friendshipBoost = false,
      icon = key,
      isHm = false,
      canHold = true,
      heldFormEffect = "none",
      partyUse = { kind = "none" },
    }
  end
  local resolved = ItemCatalog.fromResolved(root)
  local visits, reads = 0, 0
  local catalog = {
    itemKeyIterator = function()
      local nextKey = resolved:itemKeyIterator()
      return function()
        local key = nextKey()
        if key ~= nil then
          visits = visits + 1
        end
        return key
      end
    end,
    item = function(_, key)
      reads = reads + 1
      return resolved:item(key)
    end,
    pocket = function(_, key)
      return resolved:pocket(key)
    end,
    orderingKey = function(_, key)
      return resolved:orderingKey(key)
    end,
  }
  local pocket = "items"
  local state = setmetatable({
    dependencies = {
      context = { itemCatalog = catalog },
      bagManifest = {
        interactive = {
          pocketTabs = { rects = {}, strips = { [pocket] = {} } },
          focus = { tabs = { visual = {}, targets = {} } },
          overlays = { quantity = { visuals = {} } },
        },
      },
    },
    session = {
      revision = function()
        return 1
      end,
      bagSnapshot = function()
        return {
          { item = "SOOTHE_BELL", quantity = 1 },
          { item = "ember:ZEPHYR_CHIME", quantity = 1 },
          { item = "ember:EMBER_CHARM", quantity = 1 },
          { item = "ember:MOON_CHARM", quantity = 1 },
        }
      end,
    },
    controller = { section = "Bag", bagPocket = pocket, bagPage0 = 0 },
  }, SaveEditorState)

  local updates = 0
  while state._bagCatalogMetadata == nil do
    updates = updates + 1
    Assert.isTrue(updates <= 2000, "the mixed Bag catalog reaches readiness")
    local before = visits
    local used = state:_advanceBagCatalog(7)
    Assert.isTrue(used <= 7, "each catalog step respects its work budget")
    Assert.isTrue(visits - before <= 7, "each catalog step scans only its row budget")
  end

  local options = state._bagCatalogMetadata.optionsByPocket[pocket]
  local optionKeys, optionSet = {}, {}
  for _, option in ipairs(options) do
    optionKeys[#optionKeys + 1] = option.key
    optionSet[option.key] = true
  end
  for index = 2, #optionKeys do
    Assert.isTrue(
      catalog:orderingKey(optionKeys[index - 1]) < catalog:orderingKey(optionKeys[index]),
      "the Bag options follow the authoritative native-first ordering"
    )
  end
  for _, key in ipairs({ "SOOTHE_BELL", "ember:EMBER_CHARM", "ember:MOON_CHARM", "ember:ZEPHYR_CHIME" }) do
    Assert.isTrue(optionSet[key], "the sorted options retain " .. key)
  end
  Assert.isNil(resolved:item("ember:EMBER_CHARM").nativeId, "custom items keep their semantic-only identity")

  local view = state:_bagView()
  Assert.isTrue(view.bagAddEnabled, "the completed Bag catalog enables item addition")
  Assert.equal(#view.bagRows, 4, "native and custom saved stacks resolve into Bag rows")
  Assert.equal(view.bagRows[2].item, "ember:ZEPHYR_CHIME")
  Assert.equal(view.bagRows[3].item, "ember:EMBER_CHARM")
  Assert.equal(view.bagRows[4].item, "ember:MOON_CHARM")
  view.section, view.ready, view.dirty = "Bag", true, false
  local layout = computeLayout(view, 256, 192)
  Assert.notNil(layout.targets["bag:item:ember:ZEPHYR_CHIME"], "the custom stack is an actionable Bag card")
  Assert.notNil(layout.targets["bag:add"], "the completed catalog exposes the Bag add action")
  Assert.isTrue(visits > 0 and reads > 0, "catalog construction incrementally reads resolved item keys")
end

return { tests = T }
