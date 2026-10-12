-- Validation for the generated Bag interaction section.
local Checks = require("libs.assets.src.BagManifestChecks")
local Validate = require("libs.assets.src.Validate")

local InteractiveValidation = {}
local POINT_KEYS = { x = true, y = true }

---@param interactiveData table<string, unknown>
---@param constantsForValidation { POCKETS: string[], POCKET_SET: table<string, boolean>, TAB_COUNT: integer, SLOT_COUNT: integer, PANE_WIDTH: integer, PANE_HEIGHT: integer }
---@return true
function InteractiveValidation.validate(interactiveData, constantsForValidation)
  local validationContext = {}
  local POCKET_SET = constantsForValidation.POCKET_SET
  local function checkRect(value, checkContext, what)
    Checks.checkRect(value, checkContext, what, constantsForValidation.PANE_WIDTH, constantsForValidation.PANE_HEIGHT)
  end
  local function checkPoint(value, checkContext, what)
    Checks.checkPoint(value, checkContext, what, constantsForValidation.PANE_WIDTH, constantsForValidation.PANE_HEIGHT)
  end
  ---@alias BagTextSegment
  ---| { kind: "text", value: string }
  ---| { kind: "item" }
  ---| { kind: "quantity" }
  ---| { kind: "total" }

  -- Semantic action text and prompt templates. Labels are non-empty localized
  -- strings keyed by runtime action; templates are non-empty contiguous
  -- segment arrays over the closed text/item/quantity vocabulary. Adjacent
  -- text segments must have been coalesced by the producer; only the toss
  -- confirmation template may carry a quantity placeholder.
  local TEXT_ACTIONS = {
    toss = true,
    move = true,
    register = true,
    unregister = true,
    cancel = true,
    confirm = true,
    use = true,
    give = true,
  }

  local function checkSegment(segment, schemaContext, what, allowedKinds)
    if type(segment) ~= "table" then
      Checks.reject(what .. " must be a record", schemaContext)
    end
    if type(segment.kind) ~= "string" or allowedKinds[segment.kind] ~= true then
      Checks.reject(what .. " carries an unsupported segment kind " .. tostring(segment.kind), schemaContext)
    end
    if segment.kind == "text" then
      Checks.checkKeys(segment, { kind = true, value = true }, schemaContext, what)
      if type(segment.value) ~= "string" or segment.value == "" then
        Checks.reject(what .. ".value must be a non-empty string", schemaContext)
      end
    else
      Checks.checkKeys(segment, { kind = true }, schemaContext, what)
    end
  end

  local TEMPLATE_KEYS = { segments = true }

  local function checkTemplate(template, schemaContext, what, allowedKinds)
    Checks.checkRecord(template, TEMPLATE_KEYS, schemaContext, what)
    if not Validate.isArray(template.segments) or #template.segments == 0 then
      Checks.reject(what .. ".segments must be a non-empty contiguous array", schemaContext)
    end
    local sawItem, sawQuantity, sawTotal = false, false, false
    for index, segment in ipairs(template.segments) do
      checkSegment(segment, schemaContext, what .. ".segments[" .. index .. "]", allowedKinds)
      if segment.kind == "item" then
        sawItem = true
      elseif segment.kind == "quantity" then
        sawQuantity = true
      elseif segment.kind == "total" then
        sawTotal = true
      end
      if
        index > 1
        and segment.kind == "text"
        and type(template.segments[index - 1]) == "table"
        and template.segments[index - 1].kind == "text"
      then
        Checks.reject(what .. " carries adjacent text segments that must be coalesced", schemaContext)
      end
    end
    return sawItem, sawQuantity, sawTotal
  end

  -- The post-choice acknowledgement names the removed copies, so its template
  -- must expand through both the picked amount and the selected item: a
  -- text-only record cannot feed the acknowledgement presentation.
  ---@param template table<string, unknown>?
  ---@param schemaContext table<string, unknown>
  local function checkTossResult(template, schemaContext)
    local quantityKinds = { text = true, item = true, quantity = true }
    local sawItem, sawQuantity = checkTemplate(template, schemaContext, "interactive.text.tossResult", quantityKinds)
    if not sawItem or not sawQuantity then
      Checks.reject("interactive.text.tossResult must name the removed item and quantity", schemaContext)
    end
  end

  local function checkText(text, schemaContext)
    Checks.checkRecord(text, {
      actions = true,
      movePrompt = true,
      tossConfirm = true,
      tossResult = true,
      selectedItem = true,
    }, schemaContext, "interactive.text")
    local actions = text.actions
    Checks.checkRecord(actions, TEXT_ACTIONS, schemaContext, "interactive.text.actions")
    for action in pairs(TEXT_ACTIONS) do
      if type(actions[action]) ~= "string" or actions[action] == "" then
        Checks.reject("interactive.text.actions." .. action .. " must be a non-empty label", schemaContext)
      end
    end
    local itemKinds = { text = true, item = true }
    local quantityKinds = { text = true, item = true, quantity = true }
    checkTemplate(text.movePrompt, schemaContext, "interactive.text.movePrompt", itemKinds)
    checkTemplate(text.tossConfirm, schemaContext, "interactive.text.tossConfirm", quantityKinds)
    checkTossResult(text.tossResult, schemaContext)
    checkTemplate(text.selectedItem, schemaContext, "interactive.text.selectedItem", itemKinds)
  end

  -- Registration-slot markers: two distinct 40x16 images with the slot-local
  -- blit offset. The offset must keep the marker inside every canonical item
  -- slot, so validation receives the already-checked slot records.
  local REGISTRATION_WIDTH = 40
  local REGISTRATION_HEIGHT = 16

  local function checkRegistration(registration, slots, schemaContext)
    Checks.checkRecord(
      registration,
      { slot1 = true, slot2 = true, offset = true },
      schemaContext,
      "interactive.itemSlots.registration"
    )
    for _, slot in ipairs({ "slot1", "slot2" }) do
      Checks.checkImage(registration[slot], schemaContext, "interactive.itemSlots.registration." .. slot)
      if registration[slot].width ~= REGISTRATION_WIDTH or registration[slot].height ~= REGISTRATION_HEIGHT then
        Checks.reject("interactive.itemSlots.registration." .. slot .. " must be exactly 40x16", schemaContext)
      end
    end
    checkPoint(registration.offset, schemaContext, "interactive.itemSlots.registration.offset")
    for index, slot in ipairs(slots) do
      if
        registration.offset.x + REGISTRATION_WIDTH > slot.rect.width
        or registration.offset.y + REGISTRATION_HEIGHT > slot.rect.height
      then
        Checks.reject(
          "interactive.itemSlots.registration.offset escapes item slot " .. index .. " when applied slot-locally",
          schemaContext
        )
      end
    end
  end

  local function checkLocalPoint(value, bounds, schemaContext, what)
    Checks.checkRecord(value, POINT_KEYS, schemaContext, what)
    for _, axis in ipairs({ "x", "y" }) do
      Checks.checkInteger(value[axis], schemaContext, what .. "." .. axis, 0, nil, "a non-negative integer")
    end
    local limit = { x = bounds.width, y = bounds.height }
    for _, axis in ipairs({ "x", "y" }) do
      if value[axis] > limit[axis] then
        Checks.reject(what .. "." .. axis .. " escapes its text window", schemaContext)
      end
    end
  end

  local function checkContained(inner, outer, schemaContext, what)
    if
      inner.x < outer.x
      or inner.y < outer.y
      or inner.x + inner.width > outer.x + outer.width
      or inner.y + inner.height > outer.y + outer.height
    then
      Checks.reject(what .. " escapes its containing rect", schemaContext)
    end
  end

  -- Semantic focus: one static source-derived visual per focus class with the
  -- canonical target points the visual is drawn at. Tab/item/action classes
  -- carry target arrays of exact cardinality; Cancel carries one target
  -- point. No animation timeline or source identity reaches the manifest.
  local function checkFocusTargets(targets, expected, schemaContext, what)
    Checks.checkFixedArray(
      targets,
      expected,
      schemaContext,
      what .. " must carry exactly " .. expected .. " target points"
    )
    for index, target in ipairs(targets) do
      checkPoint(target, schemaContext, what .. "[" .. index .. "]")
    end
  end

  local function checkFocusClass(class, expected, schemaContext, what)
    Checks.checkRecord(class, { visual = true, targets = true }, schemaContext, what)
    Checks.checkVisual(class.visual, schemaContext, what .. ".visual")
    checkFocusTargets(class.targets, expected, schemaContext, what .. ".targets")
  end

  local function checkFocus(focus, schemaContext)
    Checks.checkRecord(
      focus,
      { tabs = true, items = true, cancel = true, actions = true },
      schemaContext,
      "interactive.focus"
    )
    checkFocusClass(focus.tabs, constantsForValidation.TAB_COUNT, schemaContext, "interactive.focus.tabs")
    checkFocusClass(focus.items, constantsForValidation.SLOT_COUNT, schemaContext, "interactive.focus.items")
    local cancel = focus.cancel
    Checks.checkRecord(cancel, { visual = true, target = true }, schemaContext, "interactive.focus.cancel")
    Checks.checkVisual(cancel.visual, schemaContext, "interactive.focus.cancel.visual")
    checkPoint(cancel.target, schemaContext, "interactive.focus.cancel.target")
    checkFocusClass(focus.actions, 4, schemaContext, "interactive.focus.actions")
  end

  -- The modal confirmation placement is plain layout data: the compact
  -- prompt at a non-negative integral position with a supported initial
  -- selection opens the destructive confirmation.
  ---@param prompt table<string, unknown>
  ---@param schemaContext table<string, unknown>
  local function checkTossPrompt(prompt, schemaContext)
    Checks.checkRecord(
      prompt,
      { x = true, y = true, shape = true, initialSelection = true },
      schemaContext,
      "interactive.overlays.tossPrompt"
    )
    for _, axis in ipairs({ "x", "y" }) do
      Checks.checkInteger(
        prompt[axis],
        schemaContext,
        "interactive.overlays.tossPrompt." .. axis,
        0,
        nil,
        "a non-negative integer"
      )
    end
    if prompt.shape ~= "compact" then
      Checks.reject("interactive.overlays.tossPrompt must use the compact prompt shape", schemaContext)
    end
    if prompt.initialSelection ~= "yes" and prompt.initialSelection ~= "no" then
      Checks.reject("interactive.overlays.tossPrompt must preselect a supported choice", schemaContext)
    end
  end

  -- One realized count-variant background: a static visual using the
  -- canonical pane size.
  local function checkCountBackground(visual, visualWhat, schemaContext)
    Checks.checkVisual(visual, schemaContext, visualWhat)
    if visual.width ~= constantsForValidation.PANE_WIDTH or visual.height ~= constantsForValidation.PANE_HEIGHT then
      Checks.reject(visualWhat .. " must use the canonical pane size", schemaContext)
    end
  end

  local COUNT_KEYS = { [0] = true, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true }

  -- Lower-pane backgrounds: seven browse count variants per pocket (an
  -- array), seven action and quantity count variants per pocket (keyed by
  -- visible count 0..6), and seven move count variants per pocket each
  -- carrying the origin-absent variant plus one variant per visible
  -- original-item cell. No standalone confirmation surface survives.
  local function checkPaneBackgrounds(backgrounds, schemaContext)
    Checks.checkRecord(backgrounds, {
      browse = true,
      action = true,
      quantity = true,
      move = true,
    }, schemaContext, "interactive.backgrounds")
    for _, state in ipairs({ "action", "quantity" }) do
      local pockets = backgrounds[state]
      local what = "interactive.backgrounds." .. state
      Checks.checkRecord(pockets, POCKET_SET, schemaContext, what, "a pocket record")
      for _, pocket in ipairs(constantsForValidation.POCKETS) do
        local perPocket = pockets[pocket]
        local pocketWhat = what .. "." .. pocket
        Checks.checkRecord(perPocket, COUNT_KEYS, schemaContext, pocketWhat, "a visible-count record")
        for count = 0, 6 do
          checkCountBackground(perPocket[count], pocketWhat .. "[" .. count .. "]", schemaContext)
        end
      end
    end
    do
      local move = backgrounds.move
      local what = "interactive.backgrounds.move"
      Checks.checkRecord(move, POCKET_SET, schemaContext, what, "a pocket record")
      local originKeys =
        { none = true, ["0"] = true, ["1"] = true, ["2"] = true, ["3"] = true, ["4"] = true, ["5"] = true }
      for _, pocket in ipairs(constantsForValidation.POCKETS) do
        local perPocket = move[pocket]
        local pocketWhat = what .. "." .. pocket
        Checks.checkRecord(perPocket, COUNT_KEYS, schemaContext, pocketWhat, "a visible-count record")
        for count = 0, 6 do
          local perCount = perPocket[count]
          local countWhat = pocketWhat .. "[" .. count .. "]"
          Checks.checkRecord(perCount, originKeys, schemaContext, countWhat, "a move-origin record")
          checkCountBackground(perCount.none, countWhat .. ".none", schemaContext)
          for _, origin in ipairs({ "0", "1", "2", "3", "4", "5" }) do
            checkCountBackground(perCount[origin], countWhat .. "[" .. origin .. "]", schemaContext)
          end
        end
      end
    end
    local browse = backgrounds.browse
    Checks.checkRecord(browse, POCKET_SET, schemaContext, "interactive.backgrounds.browse", "a pocket record")
    for _, pocket in ipairs(constantsForValidation.POCKETS) do
      local what = "interactive.backgrounds.browse." .. pocket
      local variants = browse[pocket]
      Checks.checkFixedArray(variants, 7, schemaContext, what .. " must carry exactly seven count visuals")
      for index, visual in ipairs(variants) do
        Checks.checkVisual(visual, schemaContext, what .. "[" .. index .. "]")
        if visual.width ~= constantsForValidation.PANE_WIDTH or visual.height ~= constantsForValidation.PANE_HEIGHT then
          Checks.reject(what .. "[" .. index .. "] must use the canonical pane size", schemaContext)
        end
      end
    end
  end

  local function checkPocketTabs(pocketTabs, schemaContext)
    Checks.checkRecord(pocketTabs, { rects = true, strips = true }, schemaContext, "interactive.pocketTabs")
    Checks.checkFixedArray(
      pocketTabs.rects,
      constantsForValidation.TAB_COUNT,
      schemaContext,
      "interactive.pocketTabs.rects must carry exactly eight tab rectangles"
    )
    for index, tab in ipairs(pocketTabs.rects) do
      checkRect(tab, schemaContext, "interactive.pocketTabs.rects[" .. index .. "]")
    end
    -- One final 256x32 strip visual per active pocket, carrying the persistent
    -- selected-pocket treatment independently of transient focus. Exactly the
    -- eight canonical pocket keys, no extras.
    Checks.checkRecord(pocketTabs.strips, POCKET_SET, schemaContext, "interactive.pocketTabs.strips", "a pocket record")
    for _, pocket in ipairs(constantsForValidation.POCKETS) do
      local visual = pocketTabs.strips[pocket]
      local what = "interactive.pocketTabs.strips." .. pocket
      Checks.checkVisual(visual, schemaContext, what)
      if visual.width ~= 256 or visual.height ~= 32 then
        Checks.reject(what .. " must be exactly 256x32", schemaContext)
      end
    end
  end

  local function checkItemSlotList(itemSlots, schemaContext)
    Checks.checkRecord(itemSlots, { slots = true, registration = true }, schemaContext, "interactive.itemSlots")
    Checks.checkFixedArray(
      itemSlots.slots,
      constantsForValidation.SLOT_COUNT,
      schemaContext,
      "interactive.itemSlots.slots must carry exactly six item slots"
    )
    for index, slot in ipairs(itemSlots.slots) do
      local what = "interactive.itemSlots.slots[" .. index .. "]"
      Checks.checkRecord(
        slot,
        { rect = true, textRect = true, iconCenter = true, nameAt = true, quantityAt = true },
        schemaContext,
        what
      )
      checkRect(slot.rect, schemaContext, what .. ".rect")
      checkRect(slot.textRect, schemaContext, what .. ".textRect")
      checkContained(slot.textRect, slot.rect, schemaContext, what .. ".textRect")
      checkPoint(slot.iconCenter, schemaContext, what .. ".iconCenter")
      checkLocalPoint(slot.nameAt, slot.textRect, schemaContext, what .. ".nameAt")
      checkLocalPoint(slot.quantityAt, slot.textRect, schemaContext, what .. ".quantityAt")
    end
  end

  -- Quantity stepper order fixed by the source layout: +100/+10/+1 then
  -- -100/-10/-1.
  local EXPECTED_QUANTITY_CONTROLS = {
    { delta = 100, role = "increment" },
    { delta = 10, role = "increment" },
    { delta = 1, role = "increment" },
    { delta = -100, role = "decrement" },
    { delta = -10, role = "decrement" },
    { delta = -1, role = "decrement" },
  }

  local function checkActionMenu(actionMenu, schemaContext)
    Checks.checkRecord(actionMenu, { face = true, slots = true }, schemaContext, "interactive.overlays.actionMenu")
    Checks.checkVisual(actionMenu.face, schemaContext, "interactive.overlays.actionMenu.face")
    Checks.checkFixedArray(
      actionMenu.slots,
      4,
      schemaContext,
      "interactive.overlays.actionMenu.slots must carry exactly four action slots"
    )
    for index, slot in ipairs(actionMenu.slots) do
      local what = "interactive.overlays.actionMenu.slots[" .. index .. "]"
      Checks.checkRecord(slot, { center = true, textRect = true, hitRect = true }, schemaContext, what)
      checkPoint(slot.center, schemaContext, what .. ".center")
      checkRect(slot.textRect, schemaContext, what .. ".textRect")
      checkRect(slot.hitRect, schemaContext, what .. ".hitRect")
    end
  end

  -- The browse-confirm selection entry: the Bag-local one-shot frame
  -- sequence bridging browse confirmation and the stable action menu. Frame
  -- count follows the source animation; each frame is one realized visual
  -- with its positive source duration, playback stays once, and the total
  -- is the exact duration sum the controller clock consumes.
  local function checkSelectionEntry(entry, schemaContext)
    Checks.checkRecord(
      entry,
      { frames = true, playback = true, totalTicks = true },
      schemaContext,
      "interactive.selectionEntry"
    )
    if not Validate.isArray(entry.frames) or #entry.frames == 0 then
      Checks.reject("interactive.selectionEntry.frames must be a non-empty contiguous array", schemaContext)
    end
    if entry.playback ~= "once" then
      Checks.reject("interactive.selectionEntry.playback must be once", schemaContext)
    end
    local totalTicks = 0
    for index, frame in ipairs(entry.frames) do
      local what = "interactive.selectionEntry.frames[" .. index .. "]"
      if type(frame) ~= "table" then
        Checks.reject(what .. " must be a semantic visual", schemaContext)
      end
      Checks.checkRecord(
        frame,
        { image = true, width = true, height = true, offset = true, durationTicks = true },
        schemaContext,
        what
      )
      Checks.checkImageFields(frame, schemaContext, what)
      if frame.offset ~= nil then
        Checks.checkOffset(frame.offset, schemaContext, what .. ".offset")
      end
      Checks.checkInteger(frame.durationTicks, schemaContext, what .. ".durationTicks", 1, nil, "a positive integer")
      totalTicks = totalTicks + frame.durationTicks
    end
    Checks.checkInteger(
      entry.totalTicks,
      schemaContext,
      "interactive.selectionEntry.totalTicks",
      1,
      nil,
      "a positive integer"
    )
    if entry.totalTicks ~= totalTicks then
      Checks.reject("interactive.selectionEntry.totalTicks must equal its frame duration sum", schemaContext)
    end
  end

  local function checkQuantityOverlay(quantity, schemaContext)
    Checks.checkRecord(quantity, {
      digits = true,
      controls = true,
      visuals = true,
      pressTicks = true,
      confirm = true,
      cancel = true,
      cancelHitRect = true,
    }, schemaContext, "interactive.overlays.quantity")
    Checks.checkFixedArray(
      quantity.digits,
      3,
      schemaContext,
      "interactive.overlays.quantity.digits must carry exactly three digit rectangles"
    )
    for index, digit in ipairs(quantity.digits) do
      checkRect(digit, schemaContext, "interactive.overlays.quantity.digits[" .. index .. "]")
    end
    Checks.checkFixedArray(
      quantity.controls,
      #EXPECTED_QUANTITY_CONTROLS,
      schemaContext,
      "interactive.overlays.quantity.controls must carry exactly six controls"
    )
    for index, control in ipairs(quantity.controls) do
      local expected = EXPECTED_QUANTITY_CONTROLS[index]
      local what = "interactive.overlays.quantity.controls[" .. index .. "]"
      Checks.checkRecord(control, { delta = true, role = true, center = true, hitRect = true }, schemaContext, what)
      if control.delta ~= expected.delta or control.role ~= expected.role then
        Checks.reject(what .. " has the wrong source order", schemaContext)
      end
      checkPoint(control.center, schemaContext, what .. ".center")
      checkRect(control.hitRect, schemaContext, what .. ".hitRect")
    end
    Checks.checkRecord(
      quantity.visuals,
      { increment = true, decrement = true },
      schemaContext,
      "interactive.overlays.quantity.visuals"
    )
    for _, role in ipairs({ "increment", "decrement" }) do
      local visual = quantity.visuals[role]
      local what = "interactive.overlays.quantity.visuals." .. role
      Checks.checkRecord(visual, { normal = true, pressed = true }, schemaContext, what)
      Checks.checkVisual(visual.normal, schemaContext, what .. ".normal")
      Checks.checkVisual(visual.pressed, schemaContext, what .. ".pressed")
    end
    Checks.checkInteger(
      quantity.pressTicks,
      schemaContext,
      "interactive.overlays.quantity.pressTicks",
      1,
      nil,
      "a positive integer"
    )
    local confirm = quantity.confirm
    Checks.checkRecord(
      confirm,
      { visual = true, center = true, hitRect = true, labelAt = true },
      schemaContext,
      "interactive.overlays.quantity.confirm"
    )
    Checks.checkVisual(confirm.visual, schemaContext, "interactive.overlays.quantity.confirm.visual")
    checkPoint(confirm.center, schemaContext, "interactive.overlays.quantity.confirm.center")
    checkRect(confirm.hitRect, schemaContext, "interactive.overlays.quantity.confirm.hitRect")
    checkPoint(confirm.labelAt, schemaContext, "interactive.overlays.quantity.confirm.labelAt")
    local cancel = quantity.cancel
    Checks.checkRecord(
      cancel,
      { visual = true, center = true, labelAt = true },
      schemaContext,
      "interactive.overlays.quantity.cancel"
    )
    Checks.checkVisual(cancel.visual, schemaContext, "interactive.overlays.quantity.cancel.visual")
    checkPoint(cancel.center, schemaContext, "interactive.overlays.quantity.cancel.center")
    checkPoint(cancel.labelAt, schemaContext, "interactive.overlays.quantity.cancel.labelAt")
    checkRect(quantity.cancelHitRect, schemaContext, "interactive.overlays.quantity.cancelHitRect")
  end

  local function checkSale(sale, schemaContext)
    Checks.checkRecord(sale, {
      pressTicks = true,
      quantityBackground = true,
      digits = true,
      controls = true,
      confirm = true,
      cancel = true,
      selectedItem = true,
      money = true,
      total = true,
      compactPrompt = true,
      messages = true,
    }, schemaContext, "interactive.sale")
    Checks.checkInteger(sale.pressTicks, schemaContext, "interactive.sale.pressTicks", 1, nil, "a positive integer")
    Checks.checkImage(sale.quantityBackground, schemaContext, "interactive.sale.quantityBackground")
    if
      sale.quantityBackground.width ~= constantsForValidation.PANE_WIDTH
      or sale.quantityBackground.height ~= constantsForValidation.PANE_HEIGHT
    then
      Checks.reject("interactive.sale.quantityBackground must cover the lower pane", schemaContext)
    end
    Checks.checkFixedArray(
      sale.digits,
      2,
      schemaContext,
      "interactive.sale.digits must carry exactly two digit rectangles"
    )
    for index, digit in ipairs(sale.digits) do
      checkRect(digit, schemaContext, "interactive.sale.digits[" .. index .. "]")
    end
    local expected = {
      { delta = 10, role = "increment" },
      { delta = 1, role = "increment" },
      { delta = -10, role = "decrement" },
      { delta = -1, role = "decrement" },
    }
    Checks.checkFixedArray(
      sale.controls,
      #expected,
      schemaContext,
      "interactive.sale.controls must carry four controls"
    )
    for index, control in ipairs(sale.controls) do
      local what = "interactive.sale.controls[" .. index .. "]"
      Checks.checkRecord(control, { delta = true, role = true, center = true, hitRect = true }, schemaContext, what)
      if control.delta ~= expected[index].delta or control.role ~= expected[index].role then
        Checks.reject(what .. " has the wrong sale adjustment", schemaContext)
      end
      checkPoint(control.center, schemaContext, what .. ".center")
      checkRect(control.hitRect, schemaContext, what .. ".hitRect")
    end
    for _, key in ipairs({ "confirm", "cancel" }) do
      local control = sale[key]
      local what = "interactive.sale." .. key
      Checks.checkRecord(control, { visual = true, center = true, hitRect = true, labelAt = true }, schemaContext, what)
      Checks.checkVisual(control.visual, schemaContext, what .. ".visual")
      checkPoint(control.center, schemaContext, what .. ".center")
      checkRect(control.hitRect, schemaContext, what .. ".hitRect")
      checkPoint(control.labelAt, schemaContext, what .. ".labelAt")
    end
    Checks.checkRecord(sale.selectedItem, {
      iconCenter = true,
      textRect = true,
      nameAt = true,
      quantityAt = true,
    }, schemaContext, "interactive.sale.selectedItem")
    checkPoint(sale.selectedItem.iconCenter, schemaContext, "interactive.sale.selectedItem.iconCenter")
    checkRect(sale.selectedItem.textRect, schemaContext, "interactive.sale.selectedItem.textRect")
    checkLocalPoint(
      sale.selectedItem.nameAt,
      sale.selectedItem.textRect,
      schemaContext,
      "interactive.sale.selectedItem.nameAt"
    )
    checkLocalPoint(
      sale.selectedItem.quantityAt,
      sale.selectedItem.textRect,
      schemaContext,
      "interactive.sale.selectedItem.quantityAt"
    )
    for _, key in ipairs({ "money", "total" }) do
      local box = sale[key]
      local what = "interactive.sale." .. key
      Checks.checkRecord(box, {
        x = true,
        y = true,
        width = true,
        height = true,
        fontId = true,
        textX = true,
        textY = true,
        alignment = true,
        paletteRole = true,
      }, schemaContext, what)
      checkRect({ x = box.x, y = box.y, width = box.width, height = box.height }, schemaContext, what)
      Checks.checkInteger(box.fontId, schemaContext, what .. ".fontId", 0, nil, "a non-negative integer")
      checkPoint({ x = box.textX, y = box.textY }, schemaContext, what .. " text origin")
      if box.alignment ~= "left" and box.alignment ~= "center" and box.alignment ~= "right" then
        Checks.reject(what .. ".alignment must be left, center, or right", schemaContext)
      end
      if type(box.paletteRole) ~= "string" or box.paletteRole == "" then
        Checks.reject(what .. ".paletteRole must be a semantic role", schemaContext)
      end
    end
    Checks.checkRecord(
      sale.compactPrompt,
      { x = true, y = true, shape = true, initialSelection = true },
      schemaContext,
      "interactive.sale.compactPrompt"
    )
    checkPoint({ x = sale.compactPrompt.x, y = sale.compactPrompt.y }, schemaContext, "interactive.sale.compactPrompt")
    if sale.compactPrompt.shape ~= "compact" or sale.compactPrompt.initialSelection ~= "yes" then
      Checks.reject("interactive.sale.compactPrompt must be the compact YES prompt", schemaContext)
    end
    local messages = sale.messages
    Checks.checkRecord(
      messages,
      { notSellable = true, quantity = true, offer = true, result = true },
      schemaContext,
      "interactive.sale.messages"
    )
    local saleKinds = { text = true, item = true, quantity = true, total = true }
    local requirements = {
      notSellable = { item = true },
      quantity = { item = true },
      offer = { total = true },
      result = { item = true, total = true },
    }
    for _, key in ipairs({ "notSellable", "quantity", "offer", "result" }) do
      local hasItem, hasQuantity, hasTotal =
        checkTemplate(messages[key], schemaContext, "interactive.sale.messages." .. key, saleKinds)
      local required = requirements[key]
      if
        (required.item and not hasItem)
        or (required.quantity and not hasQuantity)
        or (required.total and not hasTotal)
      then
        Checks.reject("interactive.sale.messages." .. key .. " omits a required sale value", schemaContext)
      end
    end
  end

  -- The retained selected-item panel: the selected icon center plus the
  -- dedicated item text window with its explicit name/quantity anchors.
  local function checkSelectedItem(panel, schemaContext)
    Checks.checkRecord(panel, {
      iconCenter = true,
      textRect = true,
      nameAt = true,
      quantityAt = true,
    }, schemaContext, "interactive.overlays.selectedItem")
    checkPoint(panel.iconCenter, schemaContext, "interactive.overlays.selectedItem.iconCenter")
    checkRect(panel.textRect, schemaContext, "interactive.overlays.selectedItem.textRect")
    checkLocalPoint(panel.nameAt, panel.textRect, schemaContext, "interactive.overlays.selectedItem.nameAt")
    checkLocalPoint(panel.quantityAt, panel.textRect, schemaContext, "interactive.overlays.selectedItem.quantityAt")
  end

  -- Lower-message geometry: the short framed window for action/move
  -- messages and the tall framed window for toss confirmation/result.
  local function checkMessages(messages, schemaContext)
    Checks.checkRecord(messages, { selected = true, modal = true }, schemaContext, "interactive.overlays.messages")
    for _, key in ipairs({ "selected", "modal" }) do
      local window = messages[key]
      local what = "interactive.overlays.messages." .. key
      Checks.checkRecord(window, { contentRect = true }, schemaContext, what)
      checkRect(window.contentRect, schemaContext, what .. ".contentRect")
    end
  end

  local function checkOverlays(overlays, schemaContext)
    Checks.checkRecord(overlays, {
      actionMenu = true,
      quantity = true,
      descriptionFallback = true,
      tossPrompt = true,
      selectedItem = true,
      messages = true,
    }, schemaContext, "interactive.overlays")
    checkTossPrompt(overlays.tossPrompt, schemaContext)
    checkActionMenu(overlays.actionMenu, schemaContext)
    checkQuantityOverlay(overlays.quantity, schemaContext)
    checkSelectedItem(overlays.selectedItem, schemaContext)
    checkMessages(overlays.messages, schemaContext)
    local fallback = overlays.descriptionFallback
    Checks.checkRecord(
      fallback,
      { frame = true, textRect = true },
      schemaContext,
      "interactive.overlays.descriptionFallback"
    )
    checkRect(fallback.frame, schemaContext, "interactive.overlays.descriptionFallback.frame")
    checkRect(fallback.textRect, schemaContext, "interactive.overlays.descriptionFallback.textRect")
  end

  -- Activation feedback: the generated palette-flash total plus the
  -- normal/selected control visuals the renderer phases while latched.
  local function checkFeedbackVisuals(visuals, schemaContext, what)
    Checks.checkRecord(visuals, { normal = true, selected = true }, schemaContext, what)
    Checks.checkVisual(visuals.normal, schemaContext, what .. ".normal")
    Checks.checkVisual(visuals.selected, schemaContext, what .. ".selected")
  end

  local function checkFeedback(feedback, schemaContext)
    Checks.checkRecord(feedback, {
      totalTicks = true,
      actionFace = true,
      cancelFace = true,
      quantityConfirm = true,
      quantityCancel = true,
    }, schemaContext, "interactive.feedback")
    Checks.checkInteger(
      feedback.totalTicks,
      schemaContext,
      "interactive.feedback.totalTicks",
      1,
      nil,
      "a positive integer"
    )
    checkFeedbackVisuals(feedback.actionFace, schemaContext, "interactive.feedback.actionFace")
    checkFeedbackVisuals(feedback.cancelFace, schemaContext, "interactive.feedback.cancelFace")
    checkFeedbackVisuals(feedback.quantityConfirm, schemaContext, "interactive.feedback.quantityConfirm")
    checkFeedbackVisuals(feedback.quantityCancel, schemaContext, "interactive.feedback.quantityCancel")
  end

  -- Move commit clips: one one-shot sequence per reorder kind reusing the
  -- selection-entry sequence contract, plus the original/candidate target
  -- cursor visuals.
  local function checkMoveTransition(moveTransition, schemaContext)
    Checks.checkRecord(
      moveTransition,
      { unchanged = true, changed = true },
      schemaContext,
      "interactive.moveTransition"
    )
    checkSelectionEntry(moveTransition.unchanged, schemaContext)
    checkSelectionEntry(moveTransition.changed, schemaContext)
  end

  local function checkMoveCursor(moveCursor, schemaContext)
    Checks.checkRecord(moveCursor, { original = true, candidate = true }, schemaContext, "interactive.moveCursor")
    Checks.checkVisual(moveCursor.original, schemaContext, "interactive.moveCursor.original")
    Checks.checkVisual(moveCursor.candidate, schemaContext, "interactive.moveCursor.candidate")
  end

  local function checkInteractive(interactiveSection, schemaContext)
    Checks.checkRecord(interactiveSection, {
      backgrounds = true,
      pocketTabs = true,
      itemSlots = true,
      focus = true,
      pageIndicator = true,
      cancel = true,
      text = true,
      selectionEntry = true,
      overlays = true,
      feedback = true,
      moveTransition = true,
      moveCursor = true,
      sale = true,
    }, schemaContext, "interactive")
    checkPaneBackgrounds(interactiveSection.backgrounds, schemaContext)
    local pocketTabs = interactiveSection.pocketTabs
    checkPocketTabs(pocketTabs, schemaContext)
    local itemSlots = interactiveSection.itemSlots
    checkItemSlotList(itemSlots, schemaContext)
    checkFocus(interactiveSection.focus, schemaContext)
    local pageIndicator = interactiveSection.pageIndicator
    Checks.checkRecord(pageIndicator, { rect = true, textAt = true }, schemaContext, "interactive.pageIndicator")
    checkRect(pageIndicator.rect, schemaContext, "interactive.pageIndicator.rect")
    checkPoint(pageIndicator.textAt, schemaContext, "interactive.pageIndicator.textAt")
    local cancel = interactiveSection.cancel
    Checks.checkRecord(cancel, { rect = true, textRect = true, labelRect = true }, schemaContext, "interactive.cancel")
    checkRect(cancel.rect, schemaContext, "interactive.cancel.rect")
    checkRect(cancel.textRect, schemaContext, "interactive.cancel.textRect")
    checkContained(cancel.textRect, cancel.rect, schemaContext, "interactive.cancel.textRect")
    checkRect(cancel.labelRect, schemaContext, "interactive.cancel.labelRect")
    checkContained(cancel.labelRect, cancel.rect, schemaContext, "interactive.cancel.labelRect")
    if cancel.labelRect.x * 2 + cancel.labelRect.width ~= cancel.rect.x * 2 + cancel.rect.width then
      Checks.reject("interactive.cancel.labelRect must be horizontally centered on the cancel control", schemaContext)
    end
    checkText(interactiveSection.text, schemaContext)
    checkSelectionEntry(interactiveSection.selectionEntry, schemaContext)
    checkFeedback(interactiveSection.feedback, schemaContext)
    checkMoveTransition(interactiveSection.moveTransition, schemaContext)
    checkMoveCursor(interactiveSection.moveCursor, schemaContext)
    checkRegistration(itemSlots.registration, itemSlots.slots, schemaContext)
    checkOverlays(interactiveSection.overlays, schemaContext)
    checkSale(interactiveSection.sale, schemaContext)
  end

  checkInteractive(interactiveData, validationContext)
  return true
end

return InteractiveValidation
