-- Party and Bag editor targets remain visible and reachable in a compact viewport.

local Assert = require("tests.support.Assert")
local Controller = require("app.src.saveeditor.SaveEditorController")
local Layout = require("app.src.saveeditor.SaveEditorLayout")
local SaveEditorState = require("app.src.saveeditor.SaveEditorState")
local PartyView = require("app.src.saveeditor.SaveEditorPartyView")
local ValueEditor = require("app.src.saveeditor.SaveEditorValueEditor")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")

local T = {}
local function computeLayout(view, width, height)
  return Layout.compute(view, width, height, {
    lineHeight = 14,
    measure = function(text)
      return #text * 7
    end,
  })
end

local function targetCenter(layout, targetId)
  local target = assert(layout.targets[targetId], "the active page must publish " .. targetId)
  local rect = target.rect
  return rect.x + rect.width / 2, rect.y + rect.height / 2
end

function T.party_layout_exposes_raw_and_readonly_fields_and_keeps_u32_edit_reachable()
  local controllerSections = Controller.new():snapshot().sections
  Assert.deepEqual(controllerSections, { "Location", "Player", "Party", "Bag", "Progress" })
  local navView = {
    section = "Party",
    status = "ready",
    ready = true,
    dirty = false,
    partyPage = "draft",
    partyRows = {
      {
        role = "integer value",
        targetId = "party:field:personality",
        id = "personality",
        label = "Personality",
        value = 4294967295,
      },
      {
        role = "read-only value",
        targetId = "party:readonly:level",
        id = "level",
        label = "Level",
        value = 100,
      },
      {
        role = "read-only value",
        targetId = "party:readonly:nature",
        id = "nature",
        label = "Nature",
        value = "Hardy",
      },
      {
        role = "read-only value",
        targetId = "party:readonly:max-hp",
        id = "max-hp",
        label = "Maximum HP",
        value = 312,
      },
    },
  }

  for _, dimensions in ipairs({ { 256, 192 }, { 800, 600 } }) do
    local layout = computeLayout(navView, dimensions[1], dimensions[2])
    local sectionTargets = {}
    for _, row in ipairs(layout.navigation) do
      sectionTargets[row.targetId] = true
    end
    if dimensions[1] >= 400 then
      Assert.isTrue(sectionTargets["section:Party"], "Party must be an enabled section")
      Assert.isTrue(sectionTargets["section:Bag"], "Bag must be an enabled section")
    else
      Assert.isTrue(sectionTargets.section, "compact screens must expose a touchable section chooser")
    end

    local requiredTargets = dimensions[1] >= 400
        and {
          "party:field:personality",
          "party:readonly:level",
          "party:readonly:nature",
          "party:readonly:max-hp",
        }
      or { "party:field:personality" }
    for _, targetId in ipairs(requiredTargets) do
      local x, y = targetCenter(layout, targetId)
      Assert.equal(Layout.hitTest(layout, navView, x, y), targetId)
    end
  end

  local editor = ValueEditor.new({
    kind = "integer",
    value = 0,
    min = 0,
    max = 4294967295,
    base = "decimal",
  })
  Assert.isTrue(editor:textinput("4294967295"))
  Assert.isTrue(editor:press("confirm"), "the largest unsigned value must be enterable and confirmable")
  Assert.deepEqual(editor:result(), { kind = "confirm", value = 4294967295 })
end

function T.bag_layout_exposes_catalog_pockets_and_quantity_targets()
  local view = {
    section = "Bag",
    status = "ready",
    ready = true,
    dirty = false,
    bagPocket = "balls",
    bagPocketLabel = "Balls",
    bagSelectedItem = "POKE_BALL",
    bagSelectedQuantity = 3,
    bagPockets = {
      { key = "items", label = "Items" },
      { key = "balls", label = "Balls" },
      { key = "key_items", label = "Key Items" },
    },
    bagRows = {
      { item = "POKE_BALL", label = "Poké Ball", quantity = 3 },
    },
  }
  local layout = computeLayout(view, 800, 600)
  local pocketX, pocketY = targetCenter(layout, "bag:pocket:balls")
  local itemX, itemY = targetCenter(layout, "bag:item:POKE_BALL")
  Assert.equal(Layout.hitTest(layout, view, pocketX, pocketY), "bag:pocket:balls")
  Assert.equal(Layout.hitTest(layout, view, itemX, itemY), "bag:item:POKE_BALL")
  local compact = computeLayout(view, 256, 192)
  Assert.notNil(compact.targets["bag:pocket:choose"], "compact screens must offer a touchable pocket chooser")
  Assert.notNil(compact.targets["bag:quantity"], "quantity editing must remain reachable on compact screens")
end

function T.party_draft_and_remove_modals_publish_their_own_actions()
  local draft = {
    section = "Party",
    status = "ready",
    ready = true,
    dirty = true,
    partyPage = "draft",
    partySubpage = "Identity",
    partySubpages = { "Identity", "Training", "Stats", "Moves", "Origin" },
    partyRows = {},
    partyValid = true,
    modal = "draft",
    focus = "cancel",
  }
  draft.modal = nil
  local pageLayout = computeLayout(draft, 800, 600)
  local pageFocus = {}
  for _, targetId in ipairs(pageLayout.focusOrder) do
    pageFocus[targetId] = true
  end
  Assert.isTrue(pageFocus["party:subpage:Moves"], "keyboard and controller focus must reach Party subpages")

  draft.modal = "draft"
  local draftLayout = computeLayout(draft, 800, 600)
  Assert.isNil(draftLayout.targets["party:subpage:Identity"], "the decision scope excludes draft navigation")
  for _, targetId in ipairs({
    "apply",
    "discard",
    "cancel",
  }) do
    Assert.notNil(draftLayout.targets[targetId], "draft action must be reachable: " .. targetId)
  end
  Assert.isNil(draftLayout.targets.save, "the nested draft decision excludes the underlying Save action")

  draft.modal = "remove"
  local removeLayout = computeLayout(draft, 800, 600)
  Assert.notNil(removeLayout.targets.remove)
  Assert.notNil(removeLayout.targets.cancel)
  Assert.isNil(removeLayout.targets.save, "removal confirmation excludes the underlying Save action")
end

function T.invalid_draft_modal_filters_disabled_apply_before_focus_and_confirmation()
  local State = require("app.src.saveeditor.SaveEditorState")
  local controller = Controller.new()
  controller:setSection("Party")
  controller:openModal("draft")
  local view = {
    section = "Party",
    status = "ready",
    ready = true,
    dirty = true,
    partyPage = "draft",
    partyValid = false,
    modal = "draft",
    scope = { id = "modal:draft", epoch = 1, kind = "decision", focusId = "cancel" },
    partyRows = {},
  }
  local layout = computeLayout(view, 640, 480)
  Assert.isFalse(layout.targets.apply.activationEnabled, "invalid Apply remains visible and disabled")
  Assert.isNil(layout.focusGraph.apply, "disabled Apply is excluded from the active focus graph")

  local validationCalls = 0
  local state = setmetatable({
    status = "ready",
    controller = controller,
    monDraft = {
      validate = function()
        validationCalls = validationCalls + 1
        return nil, "invalid draft"
      end,
    },
    pendingDraftAction = nil,
    errorMessage = nil,
    _snapshot = function() return view end,
    _resolve = function() return { content = { layout = layout } } end,
  }, State)

  local directions = { "left", "up", "right", "down", "left", "right" }
  local focusAlwaysEnabled = true
  for _, direction in ipairs(directions) do
    state:_consumeUiInput({ { type = "navigate", direction = direction } })
    focusAlwaysEnabled = focusAlwaysEnabled and layout.focusGraph[state.controller.focus] ~= nil
  end
  controller:setFocus("apply")
  state:_consumeUiInput({ { type = "confirm" } })
  Assert.isTrue(
    focusAlwaysEnabled and validationCalls == 0 and controller.focus ~= "apply",
    string.format(
      "directional and stale focus cannot activate disabled Apply (enabled focus=%s validation=%d focus=%s)",
      tostring(focusAlwaysEnabled),
      validationCalls,
      tostring(controller.focus)
    )
  )
end

function T.party_draft_actions_remain_visible_beside_a_long_raw_page()
  local view = {
    section = "Party",
    status = "ready",
    ready = true,
    dirty = true,
    partyPage = "draft",
    partyDirty = true,
    partyValid = true,
    partySubpage = "Identity",
    partySubpages = { "Identity", "Training", "Stats", "Moves", "Origin" },
    partyRows = {},
  }
  for index = 1, 24 do
    view.partyRows[#view.partyRows + 1] = {
      role = "integer value",
      targetId = "party:field:" .. index,
      label = "Raw field " .. index,
      value = index,
    }
  end

  local layout = computeLayout(view, 256, 192)

  Assert.notNil(layout.targets["party:apply"], "the compact raw editor keeps Apply visible")
  Assert.notNil(layout.targets["party:discard"], "the compact raw editor keeps Discard visible")
  Assert.notNil(layout.targets["party:cancel"], "the compact raw editor keeps Cancel visible")
  Assert.notNil(layout.targets["party:field:1"], "the compact raw editor shows its current rows")
  Assert.isNil(layout.targets["party:field:24"], "later raw rows scroll without displacing the decisions")
end

function T.compact_party_keeps_add_visible_and_hidden_members_in_keyboard_focus_order()
  local view = {
    section = "Party",
    status = "ready",
    ready = true,
    dirty = false,
    partyPage = "list",
    partyCanAdd = true,
    partyMemberCount = 5,
    partyRows = {},
  }
  for slot0 = 0, 4 do
    view.partyRows[#view.partyRows + 1] = {
      role = "action",
      targetId = "party:slot:" .. slot0,
      label = "Member " .. (slot0 + 1),
    }
  end
  view.partyRows[#view.partyRows + 1] = {
    role = "read-only value",
    targetId = "party:empty-slot:5",
    label = "Empty slot 6",
  }
  local compact = computeLayout(view, 256, 192)
  Assert.notNil(compact.targets["party:add"], "the compact Party list must keep Add visible")
  local focusable = {}
  for _, targetId in ipairs(compact.focusOrder) do
    focusable[targetId] = true
  end
  Assert.isTrue(focusable["party:slot:4"], "keyboard and controller focus must include clipped member rows")
  Assert.isFalse(focusable["party:empty-slot:5"], "empty slots are informational, not focusable")
  view.scrollOffset = 4
  local scrolled = computeLayout(view, 256, 192)
  Assert.notNil(scrolled.targets["party:slot:4"], "scrolling must reveal the focused member row")
  view.scrollOffset = 5
  local emptySlot = computeLayout(view, 256, 192)
  Assert.notNil(emptySlot.targets["party:empty-slot:5"], "scrolling must reveal an informational empty slot")
  local emptySlotX, emptySlotY = targetCenter(emptySlot, "party:empty-slot:5")
  Assert.isNil(Layout.hitTest(emptySlot, view, emptySlotX, emptySlotY))
end

function T.compact_bag_keeps_fixed_actions_reachable_beside_a_long_scrolling_list()
  local view = {
    section = "Bag",
    status = "ready",
    ready = true,
    dirty = false,
    bagPocket = "items",
    bagPocketLabel = "Items",
    bagSelectedItem = "POTION",
    bagSelectedQuantity = 3,
    bagRows = {},
  }
  for index = 1, 40 do
    view.bagRows[index] = {
      item = "ITEM_" .. index,
      label = "Item " .. index,
      quantity = index,
    }
  end

  local layout = computeLayout(view, 256, 192)
  local missingActions = {}
  for _, targetId in ipairs({ "bag:pocket:choose", "bag:quantity", "bag:remove", "bag:add", "save", "back" }) do
    if layout.targets[targetId] == nil then
      missingActions[#missingActions + 1] = targetId
    end
  end
  local firstRowsReachable = true
  for _, firstIndex in ipairs({ 1, 9, 25, 37 }) do
    view.scrollOffset = firstIndex - 1
    local scrolled = computeLayout(view, 256, 192)
    firstRowsReachable = firstRowsReachable and scrolled.targets["bag:item:ITEM_" .. firstIndex] ~= nil
  end
  view.scrollOffset = 0
  layout = computeLayout(view, 256, 192)
  local noBodyActionOverlap = true
  local actionRects = {
    layout.targets["bag:quantity"],
    layout.targets["bag:remove"],
    layout.targets["bag:add"],
  }
  for index = 1, 40 do
    local row = layout.targets["bag:item:ITEM_" .. index]
    if row ~= nil then
      row = row.rect
      for _, action in ipairs(actionRects) do
        if action ~= nil then
          action = action.rect
          noBodyActionOverlap = noBodyActionOverlap
            and (row.y + row.height <= action.y or action.y + action.height <= row.y)
        end
      end
    end
  end
  local shortPocket = {
    section = "Bag",
    status = "ready",
    ready = true,
    dirty = false,
    bagPocket = "key_items",
    bagPocketLabel = "Key Items",
    bagRows = {
      { item = "BICYCLE", label = "Bicycle", quantity = 1 },
      { item = "CARD_KEY", label = "Card Key", quantity = 1 },
    },
    scrollOffset = 0,
  }
  local shortLayout = computeLayout(shortPocket, 256, 192)
  local readonlyHelp = {
    section = "Party",
    status = "ready",
    ready = true,
    dirty = false,
    partyPage = "detail",
    partySlot0 = 0,
    partyLastSlot0 = 0,
    partyRows = {
      {
        role = "read-only value",
        targetId = "party:readonly:help",
        label = "Derived values cannot be edited.",
        value = nil,
      },
    },
  }
  local helpLayout = computeLayout(readonlyHelp, 256, 192)
  local compactLayoutComplete = missingActions[#missingActions] == nil
    and firstRowsReachable
    and noBodyActionOverlap
    and shortLayout.targets["bag:item:BICYCLE"] ~= nil
    and helpLayout.targets["party:readonly:help"] ~= nil
    and layout.targets["bag:item:ITEM_1"] ~= nil
    and layout.targets["bag:item:ITEM_40"] == nil
  Assert.isTrue(
    compactLayoutComplete,
    string.format(
      "missing=%s rows=%s overlap=%s short=%s help=%s first=%s lastOffscreen=%s",
      table.concat(missingActions, ","),
      tostring(firstRowsReachable),
      tostring(noBodyActionOverlap),
      tostring(shortLayout.targets["bag:item:BICYCLE"] ~= nil),
      tostring(helpLayout.targets["party:readonly:help"] ~= nil),
      tostring(layout.targets["bag:item:ITEM_1"] ~= nil),
      tostring(layout.targets["bag:item:ITEM_40"] == nil)
    )
  )
end

function T.nickname_blank_and_clear_have_distinct_raw_results()
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(0x12345678, catalog)
  local mon = factory:createNormal(CatalogFixture.normalRequest())
  mon.nickname = nil
  local context = { monCatalog = catalog, itemCatalog = CatalogFixture.makeItemCatalog() }
  local partyView = PartyView.new(context)
  local projection = { nature = require("libs.mons.src.gen4.Personality").nature(mon.personality) }
  local rows = PartyView.rows(partyView, mon, projection, "Identity", true)
  local nickname
  local clearAction
  for _, row in ipairs(rows) do
    if row.id == "nickname" then
      nickname = row
    elseif row.targetId == "party:clear-nickname" then
      clearAction = row
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
    },
    activeDraftField = nickname.editor,
    monDraft = draft,
  }, SaveEditorState)
  blankState:_finishValueEditor()
  Assert.equal(assignedField, "nickname")
  Assert.equal(assignedValue, "", "confirming blank text stores an empty nickname, not nil")
  Assert.notNil(clearAction, "nil must be an explicit action separate from entering an empty string")

  assignedField, assignedValue = nil, "not cleared"
  local clearState = setmetatable({
    status = "ready",
    controller = { modal = nil },
    monDraft = draft,
  }, SaveEditorState)
  clearState:_activate("party:clear-nickname")
  Assert.equal(assignedField, "nickname")
  Assert.isNil(assignedValue, "the explicit clear action stores nil")
end

function T.identity_explains_native_ids_and_pid_ability_slot_without_editing_them()
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(0x12345678, catalog)
  local mon = factory:createNormal(CatalogFixture.normalRequest())
  local context = { monCatalog = catalog, itemCatalog = CatalogFixture.makeItemCatalog() }
  local partyView = PartyView.new(context)
  local personality = require("libs.mons.src.gen4.Personality")
  local projection = { nature = personality.nature(mon.personality) }
  local rows = PartyView.rows(partyView, mon, projection, "Identity", true)
  local fields = {}
  for _, row in ipairs(rows) do
    fields[row.id] = row
  end
  local species = catalog:species(mon.species)
  local form = catalog:form(mon.species, mon.form)
  Assert.equal(fields["species-native-id"].value, species.nativeId)
  Assert.equal(fields["form-native-id"].value, mon.form)
  Assert.equal(fields["ability-native-id"].value, catalog:ability(mon.ability).nativeId)
  Assert.equal(fields["pid-ability-slot"].value, personality.abilitySlot(#form.abilities, mon.personality))
  for _, fieldId in ipairs({ "species-native-id", "form-native-id", "ability-native-id", "pid-ability-slot" }) do
    Assert.equal(fields[fieldId].enabled, false, fieldId .. " is explanatory only")
  end

  local moveRows = PartyView.rows(partyView, mon, projection, "Moves", true)
  local moveFields = {}
  for _, row in ipairs(moveRows) do
    if row.id ~= nil then
      moveFields[row.id] = row
    end
  end
  local firstMove = mon.moves[1]
  local moveDefinition = catalog:move(firstMove.move)
  Assert.equal(
    moveFields["move:0:allowed-pp"].value,
    moveDefinition.basePp + math.floor(moveDefinition.basePp * firstMove.ppUps / 5),
    "the Moves page explains the PP limit for the current PP Ups"
  )
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
      release = function()
        released = released + 1
      end,
    }
  end

  local ok, err = xpcall(function()
    local renderer = Renderer.new({ text = {}, graphics = {}, versionId = "heartgold" })
    renderer:prepareVisibleIcons({ section = "Party", partyPage = "list" }, {
      content = { layout = { rows = { { iconKey = "0001:0" }, { iconKey = "0004:0" } } } },
    }, {}, {})
    Assert.deepEqual(prepared, { "0001:0", "0004:0" }, "visible party icons must be prepared outside draw")
    renderer:dispose()
  end, debug.traceback)
  AssetPreparationQueue.new, MonIconAssetProvider.new = queueNew, providerNew
  if not ok then
    error(err, 0)
  end
  Assert.equal(released, 2, "disposing the renderer releases its icon provider and preparation queue")
end

function T.controller_cancel_discards_a_deferred_party_navigation_intent()
  local State = require("app.src.saveeditor.SaveEditorState")
  local controller = Controller.new()
  controller:openModal("draft")
  local state = setmetatable({
    controller = controller,
    monDraft = {},
    pendingDraftAction = { kind = "section", section = "Bag" },
  }, State)

  state:_dispatchIntent(controller:press("cancel"))

  Assert.isNil(controller.modal, "Escape/gamepad cancel closes the nested draft choice")
  Assert.isNil(state.pendingDraftAction, "a canceled navigation cannot run after a later draft decision")
  Assert.notNil(state.monDraft, "Cancel leaves the current raw draft open for more editing")
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

function T.canceling_a_raw_draft_does_not_discard_the_session()
  local controller = Controller.new()
  controller:openModal("draft")
  local draft = {
    mode = function()
      return "add"
    end,
  }
  local discarded = 0
  local session = {
    discard = function()
      discarded = discarded + 1
    end,
  }
  local state = setmetatable({
    controller = controller,
    session = session,
    monDraft = draft,
    pendingDraftAction = { kind = "section", section = "Bag" },
  }, SaveEditorState)

  state:_resolveDraftChoice("cancel")

  Assert.equal(state.monDraft, draft, "cancel leaves the local raw transaction open")
  Assert.equal(discarded, 0, "canceling a raw transaction does not discard staged Session work")
  Assert.isNil(state.pendingDraftAction, "a canceled draft decision drops its deferred action")
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
  for index = 1, 1200 do
    view.flagRows[index] = { name = "SYNTHETIC_FLAG_" .. index, value = index % 2 == 0 }
  end

  local layout = computeLayout(view, 800, 600)
  local middleIndex = 600
  local previous = "flag:" .. view.flagRows[middleIndex - 1].name
  local middle = "flag:" .. view.flagRows[middleIndex].name
  local following = "flag:" .. view.flagRows[middleIndex + 1].name
  local middleNode = assert(layout.focusGraph[middle], "every semantic flag row has a focus node")

  Assert.deepEqual(middleNode.up, { previous }, "a flag row links to its immediate semantic predecessor")
  Assert.deepEqual(middleNode.down, { following }, "a flag row links to its immediate semantic successor")
  Assert.isNil(layout.targets[middle], "the middle synthetic row starts offscreen")
  Assert.isTrue(table.concat(layout.viewports.flags.rowTargets, "\n"):find(middle, 1, true) ~= nil)

  local scrolledView = {
    section = view.section,
    status = view.status,
    ready = view.ready,
    dirty = view.dirty,
    flagFilter = view.flagFilter,
    flagRows = view.flagRows,
    scrollOffsets = { ["flags:All"] = (middleIndex - 1) * layout.viewports.flags.rowExtent },
  }
  Assert.notNil(
    computeLayout(scrolledView, 800, 600).targets[middle],
    "the same semantic row can be revealed by its viewport"
  )

  local controller = Controller.new()
  controller:setFocus("flag:" .. view.flagRows[1].name)
  for _ = 1, middleIndex - 1 do
    controller:moveFocus(layout.focusGraph, "down")
  end
  Assert.equal(controller.focus, middle, "controller movement reaches an offscreen semantic row")
  Assert.equal(layout.viewports.flags.rowTargets[middleIndex], middle, "the viewport can reveal the focused row")
end

function T.disabled_bag_party_and_footer_actions_are_not_focusable_or_pointer_targets()
  local function assertDisabled(layout, view, targetId)
    local target = assert(layout.targets[targetId], "disabled actions remain rendered: " .. targetId)
    Assert.isFalse(target.focusable, targetId .. " is absent from keyboard/controller focus")
    Assert.isFalse(target.activationEnabled, targetId .. " remains visibly disabled")
    Assert.isNil(
      Layout.hitTest(layout, view, target.rect.x + target.rect.width / 2, target.rect.y + target.rect.height / 2),
      targetId .. " is not an activatable pointer target"
    )
    Assert.isFalse(layout.focusGraph[targetId] ~= nil, targetId .. " is absent from the active focus graph")
    for _, focusId in ipairs(layout.focusOrder) do
      Assert.isFalse(focusId == targetId, targetId .. " is absent from focus order")
    end
  end

  local bag = {
    section = "Bag",
    status = "ready",
    ready = true,
    dirty = false,
    bagPocket = "items",
    bagPocketLabel = "Items",
    bagRows = {},
  }
  local bagLayout = computeLayout(bag, 800, 600)
  assertDisabled(bagLayout, bag, "bag:quantity")
  assertDisabled(bagLayout, bag, "bag:remove")
  assertDisabled(bagLayout, bag, "save")

  local party = {
    section = "Party",
    status = "ready",
    ready = true,
    dirty = true,
    partyPage = "draft",
    partyRows = {},
    partyValid = false,
  }
  assertDisabled(computeLayout(party, 800, 600), party, "party:apply")

  party.partyPage = "detail"
  party.partySlot0 = 0
  party.partyLastSlot0 = 0
  assertDisabled(computeLayout(party, 800, 600), party, "party:move-up")
  assertDisabled(computeLayout(party, 800, 600), party, "party:move-down")
end

return { tests = T }
