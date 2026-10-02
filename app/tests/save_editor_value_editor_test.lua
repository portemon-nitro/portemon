-- User-visible numeric value editing contract for the Save Editor.

local Assert = require("tests.support.Assert")

local loaded, SaveEditorValueEditor = pcall(require, "app.src.saveeditor.SaveEditorValueEditor")

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

function T.choice_browsing_pages_groups_and_search_keeps_every_key_selectable()
  Assert.isTrue(loaded)
  local options = {}
  for index = 1, 20 do
    options[index] = { key = string.format("K%02d", index), label = "Choice " .. index }
  end
  local editor = SaveEditorValueEditor.new({ kind = "choice", value = "K01", options = options })
  Assert.equal(editor:snapshot().pageCount, 3)
  Assert.isTrue(editor:press("page_next"))
  Assert.equal(editor:snapshot().options[1].key, "K09")
  Assert.isTrue(editor:press("group_next"))
  Assert.equal(editor:snapshot().group, "K")
  Assert.isTrue(editor:textinput("Choice 1"))
  Assert.equal(editor:snapshot().options[1].key, "K01")
  Assert.isTrue(editor:press("backspace"), "search backspace removes one UTF-8 glyph")
  Assert.isTrue(editor:press("cancel"))
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
  Assert.isTrue(editor:textinput("é"))
  Assert.isTrue(editor:press("backspace"), "backspace removes the complete multibyte glyph")
  Assert.equal(editor:snapshot().naming.text, "A")
  Assert.isTrue(editor:textinput("B"))
  Assert.isTrue(editor:press("confirm"))
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
