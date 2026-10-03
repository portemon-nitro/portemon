-- User-visible numeric value editing contract for the Save Editor.

local Assert = require("tests.support.Assert")

local loaded, SaveEditorValueEditor = pcall(require, "app.src.saveeditor.SaveEditorValueEditor")
local SaveEditorLayout = require("app.src.saveeditor.SaveEditorLayout")

local T = {}

local function integerEditor(value, minimum, maximum)
  Assert.isTrue(
    loaded,
    "direct numeric editing must provide a Save Editor value editor before a value can be confirmed"
  )
  return SaveEditorValueEditor.new({
    kind = "integer",
    value = value,
    min = minimum,
    max = maximum,
    base = "decimal",
  })
end

function T.direct_decimal_entry_confirms_the_exact_value()
  local editor = integerEditor(2400, 0, 999999)

  Assert.isTrue(editor:textinput("73125"), "printable decimal input should update the draft")
  Assert.isTrue(editor:press("confirm"), "a valid direct value should confirm")
  Assert.deepEqual(editor:result(), { kind = "confirm", value = 73125 })
end

function T.directional_digit_selection_and_increment_confirm_without_typing()
  local editor = integerEditor(128, 0, 999)

  Assert.isTrue(editor:press("left"), "focus should move from the units digit to the tens digit")
  Assert.isTrue(editor:press("up"), "the selected digit should increment")
  Assert.isTrue(editor:press("confirm"), "the adjusted value should confirm")
  Assert.deepEqual(editor:result(), { kind = "confirm", value = 138 })
end

function T.cancel_discards_partial_numeric_input()
  local editor = integerEditor(420, 0, 9999)

  Assert.isTrue(editor:textinput("987654"), "partial input should remain local to the editor")
  Assert.isTrue(editor:cancel(), "cancel should close the value interaction")
  Assert.deepEqual(editor:result(), { kind = "cancel" })
end

function T.explicit_submit_is_one_shot_and_rejected_values_stay_local()
  local invalid = integerEditor(12, 0, 99)
  Assert.isTrue(invalid:textinput("x"))
  Assert.isFalse(invalid:submit(), "invalid text cannot be published by an explicit close action")
  Assert.isNil(invalid:result(), "rejected values remain editable")
  Assert.isTrue(invalid:press("backspace"))
  Assert.isTrue(invalid:textinput("7"))
  Assert.isTrue(invalid:submit(), "valid text can be explicitly submitted without activating a focused key")
  Assert.deepEqual(invalid:result(), { kind = "confirm", value = 7 })
  Assert.isFalse(invalid:submit(), "a completed editor cannot submit twice")
end

function T.refused_publication_can_resume_the_exact_confirmed_buffer()
  local editor = integerEditor(12, 0, 999)
  Assert.isTrue(editor:textinput("7"))
  Assert.isTrue(editor:submit())
  Assert.isTrue(editor:retry(), "a refused publication returns its confirm buffer to editing")
  Assert.isNil(editor:result())
  Assert.equal(editor:snapshot().buffer, "7")
  Assert.isTrue(editor:textinput("3"))
  Assert.isTrue(editor:submit())
  Assert.deepEqual(editor:result(), { kind = "confirm", value = 73 })
end

function T.refused_name_publication_resumes_with_its_confirmed_text()
  local editor = SaveEditorValueEditor.new({
    kind = "name",
    nameKind = "player",
    maxLength = 7,
    initialText = "A",
    charmap = { A = 1, B = 2 },
    subject = { kind = "player", gender = 0 },
  })
  Assert.isTrue(editor:textinput("B"))
  Assert.isTrue(editor:submit())
  Assert.isTrue(editor:retry())
  Assert.equal(editor:snapshot().naming.text, "AB")
  Assert.isTrue(editor:textinput("A"), "the name editor remains interactive after a refused publication")
  Assert.isTrue(editor:submit())
  Assert.deepEqual(editor:result(), { kind = "confirm", value = "ABA" })
end

function T.cancel_target_and_semantic_back_cancel_choices_without_selecting_them()
  local choice = SaveEditorValueEditor.new({
    kind = "choice",
    value = "A",
    options = { { key = "A" }, { key = "B" } },
  })
  Assert.isTrue(choice:activateTarget("cancel"))
  Assert.deepEqual(choice:result(), { kind = "cancel" })

  local second = SaveEditorValueEditor.new({
    kind = "choice",
    value = "A",
    options = { { key = "A" }, { key = "B" } },
  })
  Assert.isTrue(second:press("back"))
  Assert.deepEqual(second:result(), { kind = "cancel" })
end

function T.invalid_or_out_of_range_numeric_text_cannot_confirm()
  for _, text in ipairs({ "12.5", "1e3", "42x", "1000" }) do
    local editor = integerEditor(12, 0, 999)
    Assert.isTrue(editor:textinput(text), "numeric text should be retained for validation")
    Assert.isFalse(editor:press("confirm"), "invalid or out-of-range input must stay unconfirmed: " .. text)
    Assert.isNil(editor:result(), "rejected input must not publish a result: " .. text)
    Assert.isTrue(editor:cancel(), "the user must still be able to cancel rejected input")
  end
end

function T.numeric_parsing_accepts_the_exact_maximum_and_rejects_non_integer_syntax()
  local decimal = integerEditor(0, 0, 999999)
  Assert.isTrue(decimal:textinput("999999"))
  Assert.isTrue(decimal:press("confirm"))
  Assert.deepEqual(decimal:result(), { kind = "confirm", value = 999999 })

  for _, text in ipairs({ "-1", "1.5", "1e3", "12tail", "1000000" }) do
    local editor = integerEditor(0, 0, 999999)
    Assert.isTrue(editor:textinput(text))
    Assert.isFalse(editor:press("confirm"), "invalid decimal input stays unconfirmed: " .. text)
  end
end

function T.hexadecimal_high_bit_values_and_digit_edits_remain_unsigned()
  Assert.isTrue(loaded)
  local editor = SaveEditorValueEditor.new({ kind = "integer", value = 0x80000000, min = 0, max = 0xFFFFFFFF, base = "hex" })
  Assert.deepEqual(editor:result(), nil)
  Assert.equal(editor:snapshot().buffer, "80000000")
  Assert.isTrue(editor:press("confirm"))
  Assert.deepEqual(editor:result(), { kind = "confirm", value = 0x80000000 })

  for _, text in ipairs({ "FFFFFFFF", "0xFFFFFFFF" }) do
    local maximum = SaveEditorValueEditor.new({ kind = "integer", value = 0, min = 0, max = 0xFFFFFFFF, base = "hex" })
    Assert.isTrue(maximum:textinput(text))
    Assert.isTrue(maximum:press("confirm"))
    Assert.deepEqual(maximum:result(), { kind = "confirm", value = 0xFFFFFFFF })
  end
  for _, text in ipairs({ "0x", "100000000", "-1", "1.5", "1g3", "FFz" }) do
    local invalid = SaveEditorValueEditor.new({ kind = "integer", value = 0, min = 0, max = 0xFFFFFFFF, base = "hex" })
    Assert.isTrue(invalid:textinput(text))
    Assert.isFalse(invalid:press("confirm"), "invalid hexadecimal input stays unconfirmed: " .. text)
  end
end

function T.choice_browsing_uses_the_full_filtered_sequence()
  Assert.isTrue(loaded)
  local options = {}
  for index = 1, 20 do
    options[index] = { key = string.format("K%02d", index), label = "Choice " .. index }
  end
  local editor = SaveEditorValueEditor.new({ kind = "choice", value = "K01", options = options })
  local opening = editor:snapshot()
  Assert.equal(#opening.options, 20)
  local layout = SaveEditorLayout.compute({
    section = "Bag",
    status = "ready",
    ready = true,
    dirty = false,
    bagRows = {},
    valueEditor = opening,
    scope = { id = "value:choice", epoch = 1 },
    scrollOffsets = {},
  }, 256, 192, { lineHeight = 14, measure = function(text) return #text * 7 end })
  Assert.isNil(layout.targets["group-previous"], "flat choice view has no group control")
  Assert.isNil(layout.targets["group-next"], "flat choice view has no group control")
  Assert.isNil(layout.targets["clear-search"], "flat choice view has no visible Clear control")
  Assert.isTrue(editor:press("down"))
  Assert.equal(editor:snapshot().selectedKey, "K02")
  Assert.isTrue(editor:textinput("Choice 1"))
  Assert.equal(editor:snapshot().options[1].key, "K01")
  Assert.isTrue(editor:press("backspace"), "search backspace removes one UTF-8 glyph")
  Assert.isTrue(editor:press("cancel"))
end

function T.choice_filter_keeps_the_opening_identity_visible_and_recovers_from_no_results()
  local options = {}
  for index = 1, 24 do
    options[index] = { key = string.format("K%02d", index), label = "Choice " .. index }
  end
  local editor = SaveEditorValueEditor.new({ kind = "choice", value = "K18", options = options })
  local opening = editor:snapshot()
  local layout = SaveEditorLayout.compute({
    section = "Bag", status = "ready", ready = true, dirty = false, bagRows = {}, valueEditor = opening,
    scope = { id = "value:choice", epoch = 1 }, scrollOffsets = {},
  }, 256, 192, { lineHeight = 14, measure = function(text) return #text * 7 end })
  local selectedVisible = layout.targets["choice:K18"] ~= nil and layout.viewports["value:choice"].offset > 0
  editor:textinput("no matching choice")
  local backspaceRecovered = editor:press("backspace")
  local clearRecovered = editor:press("clear_search")
  local recovered = editor:snapshot()
  local allOptionsReturned = #recovered.options == 24 and recovered.query == "" and recovered.selectedKey == "K18"
  local selected = editor:submit()
  local recoveredChoice = editor:result()

  local mouseCancel = SaveEditorValueEditor.new({ kind = "choice", value = "K01", options = options })
  local mouseCanceled = mouseCancel:activateTarget("cancel")
  local touchCancel = SaveEditorValueEditor.new({ kind = "choice", value = "K01", options = options })
  local touchCanceled = touchCancel:activateTarget("cancel")
  local escapeCancel = SaveEditorValueEditor.new({ kind = "choice", value = "K01", options = options })
  local escapeCanceled = escapeCancel:press("escape")
  local buttonCancel = SaveEditorValueEditor.new({ kind = "choice", value = "K01", options = options })
  local buttonCanceled = buttonCancel:press("b")

  local everyCancelHandled = mouseCanceled and touchCanceled and escapeCanceled and buttonCanceled
  local mouseResult, touchResult = mouseCancel:result(), touchCancel:result()
  local escapeResult, buttonResult = escapeCancel:result(), buttonCancel:result()
  local everyCancelResultIsTerminal = mouseResult ~= nil
    and mouseResult.kind == "cancel"
    and touchResult ~= nil
    and touchResult.kind == "cancel"
    and escapeResult ~= nil
    and escapeResult.kind == "cancel"
    and buttonResult ~= nil
    and buttonResult.kind == "cancel"
  Assert.isTrue(
    selectedVisible
      and backspaceRecovered
      and clearRecovered
      and allOptionsReturned
      and selected
      and recoveredChoice ~= nil
      and recoveredChoice.value == "K18"
      and everyCancelHandled
      and everyCancelResultIsTerminal,
    string.format(
      "selection=%s backspace=%s clear=%s restored=%s choice=%s cancels=%s terminal=%s",
      tostring(selectedVisible),
      tostring(backspaceRecovered),
      tostring(clearRecovered),
      tostring(allOptionsReturned),
      tostring(recoveredChoice and recoveredChoice.value),
      tostring(everyCancelHandled),
      tostring(everyCancelResultIsTerminal)
    )
  )
end

function T.name_action_key_activates_the_selected_glyph_without_submitting()
  local editor = SaveEditorValueEditor.new({
    kind = "name",
    nameKind = "pokemon",
    maxLength = 7,
    initialText = "A",
    charmap = { A = 1, B = 2 },
    subject = { kind = "pokemon", species = 152, form = 0 },
  })

  Assert.deepEqual(
    editor:snapshot().naming.subject,
    { kind = "pokemon", species = 152, form = 0 },
    "the naming controller receives a supported native species identity"
  )
  local beforeAction = editor:snapshot().naming.text
  Assert.isTrue(editor:press("a"), "the action key is handled by the naming control")
  Assert.isNil(editor:result(), "the action key does not submit the whole name")
  Assert.isTrue(editor:snapshot().naming.text ~= beforeAction, "the selected glyph is inserted into the active name")
end

function T.repeated_digit_adjustment_preserves_decimal_and_hexadecimal_significance()
  local decimal = integerEditor(128, 0, 999)
  Assert.isTrue(decimal:press("left"))
  Assert.isTrue(decimal:press("up"))
  Assert.isTrue(decimal:press("up"))
  Assert.equal(decimal:snapshot().buffer, "148", "both adjustments continue to target tens")

  local hexadecimal = SaveEditorValueEditor.new({
    kind = "integer",
    value = 0x1A2,
    min = 0,
    max = 0xFFF,
    base = "hex",
  })
  Assert.isTrue(hexadecimal:press("left"))
  Assert.isTrue(hexadecimal:press("up"))
  Assert.isTrue(hexadecimal:press("up"))
  Assert.equal(hexadecimal:snapshot().buffer, "1C2", "both adjustments continue to target the middle hex digit")
end

function T.name_variant_uses_naming_snapshot_and_submits_real_text()
  Assert.isTrue(loaded)
  local editor = SaveEditorValueEditor.new({
    kind = "name",
    nameKind = "player",
    maxLength = 7,
    initialText = "A",
    charmap = { A = 1, B = 2, K = 3, ["é"] = 4 },
    subject = { kind = "player", gender = 0 },
  })
  local snapshot = editor:snapshot()
  Assert.equal(snapshot.naming.kind, "player")
  Assert.equal(snapshot.naming.text, "A")
  Assert.isTrue(editor:activateTarget("lower"), "a named page control is routed to the naming screen")
  Assert.equal(editor:snapshot().naming.page, "lower", "the lower page control changes the active glyph page")
  Assert.isTrue(editor:textinput("é"))
  Assert.isTrue(editor:press("backspace"), "backspace removes the complete multibyte glyph")
  Assert.equal(editor:snapshot().naming.text, "A")
  Assert.isTrue(editor:textinput("B"))
  Assert.isTrue(editor:submit())
  Assert.deepEqual(editor:result(), { kind = "confirm", value = "AB" })

  local cancelEditor = SaveEditorValueEditor.new({
    kind = "name",
    nameKind = "player",
    maxLength = 7,
    initialText = "A",
    charmap = { A = 1 },
    subject = { kind = "player", gender = 0 },
  })
  Assert.isTrue(cancelEditor:cancel())
  Assert.deepEqual(cancelEditor:result(), { kind = "cancel" })
end

return { tests = T }
