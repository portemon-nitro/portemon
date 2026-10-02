-- Party and Bag editor targets remain visible and reachable in a compact viewport.

local Assert = require("tests.support.Assert")
local Controller = require("app.src.saveeditor.SaveEditorController")
local Layout = require("app.src.saveeditor.SaveEditorLayout")
local SaveEditorState = require("app.src.saveeditor.SaveEditorState")
local ValueEditor = require("app.src.saveeditor.SaveEditorValueEditor")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")

local T = {}

local function targetCenter(layout, targetId)
  local target = assert(layout.targets[targetId], "the active page must publish " .. targetId)
  return target.x + target.width / 2, target.y + target.height / 2
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
    local layout = Layout.compute(navView, dimensions[1], dimensions[2])
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
  local layout = Layout.compute(view, 800, 600)
  local pocketX, pocketY = targetCenter(layout, "bag:pocket:balls")
  local itemX, itemY = targetCenter(layout, "bag:item:POKE_BALL")
  Assert.equal(Layout.hitTest(layout, view, pocketX, pocketY), "bag:pocket:balls")
  Assert.equal(Layout.hitTest(layout, view, itemX, itemY), "bag:item:POKE_BALL")
  local compact = Layout.compute(view, 256, 192)
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
  local draftLayout = Layout.compute(draft, 800, 600)
  for _, targetId in ipairs({
    "party:subpage:Identity",
    "party:subpage:Moves",
    "apply",
    "discard",
    "cancel",
  }) do
    Assert.notNil(draftLayout.targets[targetId], "draft action must be reachable: " .. targetId)
  end
  local save = draftLayout.targets.save
  Assert.isNil(
    Layout.hitTest(draftLayout, draft, save.x + save.width / 2, save.y + save.height / 2),
    "the nested draft decision must not activate the underlying Save action"
  )

  draft.modal = "remove"
  local removeLayout = Layout.compute(draft, 800, 600)
  Assert.notNil(removeLayout.targets.remove)
  Assert.notNil(removeLayout.targets.cancel)
  save = removeLayout.targets.save
  Assert.isNil(
    Layout.hitTest(removeLayout, draft, save.x + save.width / 2, save.y + save.height / 2),
    "removal confirmation must not activate the underlying Save action"
  )

  local focusable = {}
  for _, targetId in ipairs(draftLayout.focusable) do
    focusable[targetId] = true
  end
  Assert.isTrue(focusable["party:subpage:Moves"], "keyboard and controller focus must reach Party subpages")
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

  local layout = Layout.compute(view, 256, 192)

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
  local compact = Layout.compute(view, 256, 192)
  Assert.notNil(compact.targets["party:add"], "the compact Party list must keep Add visible")
  local focusable = {}
  for _, targetId in ipairs(compact.focusable) do
    focusable[targetId] = true
  end
  Assert.isTrue(focusable["party:slot:4"], "keyboard and controller focus must include clipped member rows")
  Assert.isFalse(focusable["party:empty-slot:5"], "empty slots are informational, not focusable")
  view.scrollOffset = 4
  local scrolled = Layout.compute(view, 256, 192)
  Assert.notNil(scrolled.targets["party:slot:4"], "scrolling must reveal the focused member row")
  view.scrollOffset = 5
  local emptySlot = Layout.compute(view, 256, 192)
  Assert.notNil(emptySlot.targets["party:empty-slot:5"], "scrolling must reveal an informational empty slot")
  local emptySlotX, emptySlotY = targetCenter(emptySlot, "party:empty-slot:5")
  Assert.isNil(Layout.hitTest(emptySlot, view, emptySlotX, emptySlotY))
end

function T.nickname_blank_and_clear_have_distinct_raw_results()
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(0x12345678, catalog)
  local mon = factory:createNormal(CatalogFixture.normalRequest())
  mon.nickname = nil
  local editorState = setmetatable({
    dependencies = { context = { monCatalog = catalog, itemCatalog = CatalogFixture.makeItemCatalog() } },
  }, SaveEditorState)
  local projection = { nature = require("libs.mons.src.gen4.Personality").nature(mon.personality) }
  local rows = editorState:_monRows(mon, projection, "Identity", true)
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
  local editorState = setmetatable({
    dependencies = { context = { monCatalog = catalog, itemCatalog = CatalogFixture.makeItemCatalog() } },
  }, SaveEditorState)
  local personality = require("libs.mons.src.gen4.Personality")
  local projection = { nature = personality.nature(mon.personality) }
  local rows = editorState:_monRows(mon, projection, "Identity", true)
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

  local moveRows = editorState:_monRows(mon, projection, "Moves", true)
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
    local renderer = Renderer.new({ text = {}, graphics = {} })
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

return { tests = T }
