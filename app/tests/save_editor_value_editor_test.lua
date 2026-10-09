-- User-visible numeric value editing contract for the Save Editor.

local Assert = require("tests.support.Assert")
local Controller = require("app.src.saveeditor.SaveEditorController")
local FieldInput = require("libs.hgss.src.field.FieldInput")
local SaveEditorState = require("app.src.saveeditor.SaveEditorState")

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

local function finishChoiceFilter(editor)
  while editor:snapshot().pending do
    editor:update(256)
  end
end

function T.direct_decimal_entry_confirms_the_exact_value()
  local editor = integerEditor(2400, 0, 999999)

  Assert.isTrue(editor:textinput("73125"), "printable decimal input should update the draft")
  Assert.isTrue(editor:press("confirm"), "a valid direct value should confirm")
  Assert.deepEqual(editor:result(), { kind = "confirm", value = 73125 })
end

function T.directional_adjustment_confirms_without_typing()
  local editor = integerEditor(128, 0, 999)

  Assert.isTrue(editor:press("up"), "Up adjusts an integer by one")
  Assert.isTrue(editor:press("confirm"), "the adjusted value should confirm")
  Assert.deepEqual(editor:result(), { kind = "confirm", value = 129 })
end

function T.directional_input_selects_places_and_applies_radix_power_arithmetic()
  local decimal = SaveEditorValueEditor.new({
    kind = "integer",
    value = 20,
    min = 0,
    max = 25,
    base = "decimal",
  })
  Assert.equal(decimal:snapshot().kind, "number", "ordinary integers use the shared number modal")
  Assert.isTrue(decimal:press("up"))
  Assert.equal(decimal:snapshot().parsedValue, 21)
  Assert.isTrue(decimal:press("left"))
  Assert.equal(decimal:snapshot().selectedPlace, 1, "Left selects the tens place")
  Assert.equal(decimal:snapshot().parsedValue, 21, "selecting a place does not mutate the value")
  Assert.isTrue(decimal:press("up"))
  Assert.equal(decimal:snapshot().parsedValue, 25, "Up adjusts by the selected place and clamps")
  Assert.isTrue(decimal:press("right"))
  Assert.equal(decimal:snapshot().selectedPlace, 0, "Right selects the units place")
  Assert.isTrue(decimal:press("down"))
  Assert.equal(decimal:snapshot().parsedValue, 24, "Down subtracts one from the selected units place")

  local hexadecimal = SaveEditorValueEditor.new({
    kind = "integer",
    value = 0x1A2,
    min = 0,
    max = 0xFFF,
    base = "hex",
  })
  Assert.equal(hexadecimal:snapshot().kind, "number", "raw values use the same modal kind")
  Assert.isTrue(hexadecimal:press("left"))
  Assert.equal(hexadecimal:snapshot().selectedPlace, 1)
  Assert.isTrue(hexadecimal:press("up"))
  Assert.equal(hexadecimal:snapshot().parsedValue, 0x1B2, "hexadecimal tens use a radix-sixteen place")
  Assert.equal(hexadecimal:snapshot().buffer, "1B2", "hexadecimal presentation remains uppercase")
  Assert.isTrue(hexadecimal:selectPlace(2))
  Assert.isTrue(hexadecimal:adjustPlace(-1))
  Assert.equal(hexadecimal:snapshot().buffer, "0B2", "direct adjustments restore padded hexadecimal display")
end

function T.invalid_integer_buffers_recover_from_the_last_valid_value_on_arrow_input()
  local cases = {
    { value = 123, minimum = 0, maximum = 999, base = "decimal", invalid = "9999999", delta = 1, expected = 124 },
    { value = 1, minimum = 1, maximum = 99, base = "decimal", invalid = "letters", delta = 1, expected = 2 },
    { value = 99, minimum = 1, maximum = 99, base = "decimal", invalid = "x", delta = 1, expected = 99 },
    { value = 0x1A2, minimum = 0, maximum = 0xFFF, base = "hex", invalid = "G", delta = 1, expected = 0x1A3 },
  }
  for _, case in ipairs(cases) do
    local editor = SaveEditorValueEditor.new({
      kind = "integer",
      value = case.value,
      min = case.minimum,
      max = case.maximum,
      base = case.base,
    })
    Assert.isTrue(editor:textinput(case.invalid), "invalid input remains visible until an arrow is requested")
    if case.invalid == "x" then
      Assert.isTrue(editor:press("backspace"), "backspace can produce an empty numeric buffer")
      Assert.equal(editor:snapshot().buffer, "", "empty text remains an editable invalid buffer")
    end
    Assert.isFalse(editor:submit(), "invalid input still cannot be confirmed before correction")
    Assert.isNil(editor:result(), "rejected input stays in the editor")
    Assert.isTrue(editor:adjustPlace(case.delta), "an arrow recovers from the invalid buffer")
    Assert.equal(editor:snapshot().parsedValue, case.expected, "the delta starts from the last valid value")
    Assert.isTrue(editor:submit(), "the recovered value can be explicitly confirmed")
    Assert.deepEqual(editor:result(), { kind = "confirm", value = case.expected })
  end
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
  local editor =
    SaveEditorValueEditor.new({ kind = "integer", value = 0x80000000, min = 0, max = 0xFFFFFFFF, base = "hex" })
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

function T.integer_projection_uses_maximum_radix_and_pads_valid_digits()
  local cases = {
    { minimum = 0, maximum = 0, base = "decimal", count = 1, value = 0, digits = "0" },
    { minimum = 7, maximum = 7, base = "decimal", count = 1, value = 7, digits = "7" },
    { minimum = 0, maximum = 9, base = "decimal", count = 1, value = 1, digits = "1" },
    { minimum = 0, maximum = 10, base = "decimal", count = 2, value = 1, digits = "01" },
    { minimum = 1, maximum = 100, base = "decimal", count = 3, value = 1, digits = "001" },
    { minimum = 0, maximum = 255, base = "decimal", count = 3, value = 1, digits = "001" },
    { minimum = 2000, maximum = 2255, base = "decimal", count = 4, value = 2000, digits = "2000" },
    { minimum = 0, maximum = 999999, base = "decimal", count = 6, value = 1, digits = "000001" },
    { minimum = 0, maximum = 0xFFFFFFFF, base = "decimal", count = 10, value = 1, digits = "0000000001" },
    { minimum = 0, maximum = 0xFFFFFFFF, base = "hex", count = 8, value = 0xAF, digits = "000000AF" },
  }

  for _, case in ipairs(cases) do
    local editor = SaveEditorValueEditor.new({
      kind = "integer",
      value = case.value,
      min = case.minimum,
      max = case.maximum,
      base = case.base,
    })
    local snapshot = editor:snapshot()
    Assert.equal(snapshot.digitCount, case.count, "digit count follows the maximum in " .. case.base)
    Assert.equal(table.concat(snapshot.digits), case.digits, "valid display digits are padded in " .. case.base)
    Assert.equal(snapshot.selectedPlace, 0, "opening selects the least-significant place")
    if case.minimum == case.maximum then
      Assert.isFalse(editor:adjustPlace(1), "a fixed range cannot be changed")
      Assert.equal(editor:snapshot().parsedValue, case.value, "a fixed range remains exact")
    end
  end
end

function T.place_selection_and_arithmetic_use_radix_powers_with_bounds()
  local decimal = SaveEditorValueEditor.new({
    kind = "integer",
    value = 99,
    min = 0,
    max = 2255,
    base = "decimal",
  })
  Assert.isTrue(type(decimal.selectPlace) == "function", "numeric editing exposes place selection")
  Assert.isTrue(type(decimal.adjustPlace) == "function", "numeric editing exposes place arithmetic")
  Assert.isTrue(decimal:selectPlace(0))
  Assert.isTrue(decimal:adjustPlace(1))
  Assert.equal(decimal:snapshot().parsedValue, 100, "adding one to 99 carries into the next place")
  Assert.equal(decimal:snapshot().buffer, "0100", "accepted arithmetic restores padded display")
  Assert.isTrue(decimal:selectPlace(1))
  Assert.isTrue(decimal:adjustPlace(-1))
  Assert.equal(decimal:snapshot().parsedValue, 90, "the selected tens place subtracts ten")

  local hexadecimal = SaveEditorValueEditor.new({
    kind = "integer",
    value = 0xFF,
    min = 0,
    max = 0xFFFFFFFF,
    base = "hex",
  })
  Assert.isTrue(hexadecimal:adjustPlace(1))
  Assert.equal(hexadecimal:snapshot().parsedValue, 0x100, "hex place arithmetic carries in radix sixteen")
  Assert.equal(table.concat(hexadecimal:snapshot().digits), "00000100")

  local bounded = SaveEditorValueEditor.new({
    kind = "integer",
    value = 9,
    min = 1,
    max = 10,
    base = "decimal",
  })
  Assert.isTrue(bounded:adjustPlace(1))
  Assert.equal(bounded:snapshot().parsedValue, 10, "increment clamps at the exact maximum")
  Assert.isFalse(bounded:adjustPlace(1), "a second increment at the maximum is not a mutation")
  Assert.equal(bounded:snapshot().parsedValue, 10)
end

function T.large_choice_catalog_reuses_its_filtered_order_until_the_query_changes()
  Assert.isTrue(loaded)
  local options = {}
  for index = 1, 10000 do
    local key = string.format("K%05d", index)
    options[index] = { key = key, label = "Choice " .. index }
  end
  local editor = SaveEditorValueEditor.new({ kind = "choice", value = "K00001", options = options })
  local opening = editor:snapshot()
  Assert.equal(#opening.options, 10000, "the catalog exposes every logical choice")
  Assert.isTrue(editor:snapshot().options == opening.options, "repeated snapshots reuse the cached order")
  Assert.isTrue(editor:moveChoice(5), "browsing moves the selection")
  Assert.isTrue(editor:snapshot().options == opening.options, "browsing never rebuilds the cached order")
  Assert.equal(editor:snapshot().selectedKey, "K00006", "browsing still advances the selection")
  Assert.isTrue(editor:textinput("K000"), "filtering narrows the catalog")
  finishChoiceFilter(editor)
  local narrowed = editor:snapshot()
  Assert.isFalse(narrowed.options == opening.options, "a changed query rebuilds the filtered order once")
  Assert.isTrue(#narrowed.options < 10000 and #narrowed.options > 0, "the filter narrows without emptying")
  Assert.isTrue(editor:snapshot().options == narrowed.options, "the rebuilt filter is reused while stable")
  Assert.isTrue(editor:press("backspace"), "backspace edits the query")
  finishChoiceFilter(editor)
  local widened = editor:snapshot()
  Assert.isFalse(widened.options == narrowed.options, "query edits rebuild exactly once")
  Assert.isTrue(editor:snapshot().options == widened.options, "the widened filter is reused while stable")
  Assert.isTrue(editor:press("clear_search"), "clearing restores the catalog")
  finishChoiceFilter(editor)
  local restored = editor:snapshot()
  Assert.equal(#restored.options, 10000, "clearing restores every logical choice")
  Assert.isTrue(editor:snapshot().options == restored.options, "the restored order is reused while stable")
end

function T.stable_large_choice_snapshots_and_layout_do_not_walk_the_logical_catalog()
  local function stableVisits(count)
    local options = {}
    for index = 1, count do
      local key = string.format("K%05d", index)
      options[index] = { key = key, label = "Choice " .. index }
    end
    local editor = SaveEditorValueEditor.new({
      kind = "choice",
      value = options[count].key,
      options = options,
    })
    local opening = editor:snapshot()
    local watched = { [opening.options] = "options", [opening.rowTargets] = "row targets" }
    local visits = { options = 0, ["row targets"] = 0 }
    local originalIpairs = ipairs
    _G.ipairs = function(value)
      local kind = watched[value]
      if kind == nil then
        return originalIpairs(value)
      end
      local function nextValue(_, index)
        index = index + 1
        local item = value[index]
        if item == nil then
          return nil
        end
        visits[kind] = visits[kind] + 1
        return index, item
      end
      return nextValue, value, 0
    end
    local ok, result = xpcall(function()
      for _ = 1, 3 do
        editor:snapshot()
      end
      local layout = SaveEditorLayout.compute(
        {
          section = "Bag",
          status = "ready",
          ready = true,
          dirty = false,
          bagRows = {},
          valueEditor = opening,
          scope = { id = "value:choice", epoch = 1, kind = "value", focusId = "choice:" .. options[count].key },
          scrollOffsets = {},
        },
        256,
        192,
        {
          lineHeight = 14,
          measure = function(text)
            return #text * 7
          end,
        }
      )
      return layout
    end, debug.traceback)
    _G.ipairs = originalIpairs
    if not ok then
      error(result, 0)
    end
    return visits, result
  end

  local smallVisits = stableVisits(100)
  local largeVisits, largeLayout = stableVisits(10000)
  local total = largeVisits.options + largeVisits["row targets"]
  local smallTotal = smallVisits.options + smallVisits["row targets"]
  Assert.isTrue(
    total <= smallTotal + 8,
    string.format(
      "stable work grew with catalog size: 100=%d/%d, 10000=%d/%d",
      smallVisits.options,
      smallVisits["row targets"],
      largeVisits.options,
      largeVisits["row targets"]
    )
  )
  Assert.isTrue(
    largeLayout.targets["choice:K10000"] ~= nil and largeLayout.viewports["value:choice"].offset > 0,
    "the selected logical row near the end remains addressable and visible"
  )
end

function T.choice_snapshot_carries_stable_row_identity_for_visible_layout()
  Assert.isTrue(loaded)
  local options = {}
  for index = 1, 50 do
    options[index] = { key = string.format("K%02d", index), label = "Choice " .. index }
  end
  local editor = SaveEditorValueEditor.new({ kind = "choice", value = "K01", options = options })
  local snapshot = editor:snapshot()
  Assert.equal(#snapshot.rowTargets, 50, "the snapshot carries the complete logical order")
  Assert.equal(snapshot.rowTargets[1], "choice:K01", "row targets use the stable row identity")
  Assert.equal(snapshot.indexByTarget["choice:K25"], 25, "the index map resolves stable identities")
  Assert.isTrue(editor:snapshot().rowTargets == snapshot.rowTargets, "the row order is reused while stable")
  Assert.isTrue(editor:snapshot().indexByTarget == snapshot.indexByTarget, "the index map is reused while stable")
  editor:textinput("K1")
  finishChoiceFilter(editor)
  local narrowed = editor:snapshot()
  Assert.isFalse(narrowed.rowTargets == snapshot.rowTargets, "a changed query rebuilds the row identity once")
  Assert.equal(narrowed.indexByTarget[narrowed.rowTargets[1]], 1, "the rebuilt index map stays consistent")
end

function T.choice_selection_uses_index_membership_without_submitting_or_scanning()
  Assert.isTrue(loaded)
  local options = {}
  for index = 1, 10000 do
    local key = string.format("K%05d", index)
    options[index] = { key = key, label = "Choice " .. index }
  end
  local editor = SaveEditorValueEditor.new({ kind = "choice", value = "K00001", options = options })
  local snapshot = editor:snapshot()
  local sourceOptions = editor._options
  local scans = 0
  local originalIpairs = ipairs
  _G.ipairs = function(value)
    if value ~= sourceOptions then
      return originalIpairs(value)
    end
    return function(_, index)
      index = index + 1
      if value[index] == nil then
        return nil
      end
      scans = scans + 1
      return index, value[index]
    end,
      value,
      0
  end
  local ok, failure = xpcall(function()
    Assert.isTrue(type(editor.selectChoice) == "function", "choice owners expose direct indexed selection")
    Assert.isTrue(editor:selectChoice("K09999"), "a current logical key selects directly")
    Assert.equal(editor:snapshot().selectedKey, "K09999")
    Assert.equal(scans, 0, "direct selection does not scan the catalog")
    Assert.isFalse(editor:selectChoice("unknown"), "an unknown key cannot reuse a stale numeric index")
    Assert.equal(editor:snapshot().selectedKey, "K09999", "a rejected key leaves selection unchanged")
    Assert.isNil(editor:result(), "selection remains separate from submission")
  end, debug.traceback)
  _G.ipairs = originalIpairs
  if not ok then
    error(failure, 0)
  end
  Assert.equal(snapshot.selectedKey, "K00001", "selection never mutates its earlier snapshot")
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
  local layout = SaveEditorLayout.compute(
    {
      section = "Bag",
      status = "ready",
      ready = true,
      dirty = false,
      bagRows = {},
      valueEditor = opening,
      scope = { id = "value:choice", epoch = 1 },
      scrollOffsets = {},
    },
    256,
    192,
    {
      lineHeight = 14,
      measure = function(text)
        return #text * 7
      end,
    }
  )
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
  local layout = SaveEditorLayout.compute(
    {
      section = "Bag",
      status = "ready",
      ready = true,
      dirty = false,
      bagRows = {},
      valueEditor = opening,
      scope = { id = "value:choice", epoch = 1 },
      scrollOffsets = {},
    },
    256,
    192,
    {
      lineHeight = 14,
      measure = function(text)
        return #text * 7
      end,
    }
  )
  local selectedVisible = layout.targets["choice:K18"] ~= nil and layout.viewports["value:choice"].offset > 0
  editor:textinput("no matching choice")
  local backspaceRecovered = editor:press("backspace")
  local clearRecovered = editor:press("clear_search")
  finishChoiceFilter(editor)
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

function T.repeated_key_adjustment_preserves_decimal_and_hexadecimal_display()
  local decimal = integerEditor(128, 0, 999)
  Assert.isTrue(decimal:press("up"))
  Assert.isTrue(decimal:press("up"))
  Assert.equal(decimal:snapshot().buffer, "130", "repeated Up presses add one each time")

  local hexadecimal = SaveEditorValueEditor.new({
    kind = "integer",
    value = 0x1A2,
    min = 0,
    max = 0xFFF,
    base = "hex",
  })
  Assert.isTrue(hexadecimal:press("left"))
  Assert.isTrue(hexadecimal:press("left"))
  Assert.equal(hexadecimal:snapshot().selectedPlace, 2, "Left selects the hundreds place")
  Assert.isTrue(hexadecimal:press("up"))
  Assert.equal(hexadecimal:snapshot().buffer, "2A2", "Up adjusts by the selected hexadecimal place")
end

function T.cleared_choice_filter_restores_the_opening_selection_without_publishing()
  Assert.isTrue(loaded)
  local options = {}
  for index = 1, 24 do
    options[index] = { key = string.format("K%02d", index), label = "Choice " .. index }
  end
  local editor = SaveEditorValueEditor.new({ kind = "choice", value = "K18", options = options })
  Assert.isTrue(editor:textinput("no matching choice"), "typing filters the choice rows")
  finishChoiceFilter(editor)
  Assert.deepEqual(editor:snapshot().options, {}, "a query without matches leaves zero rows")
  Assert.isNil(editor:result(), "filtering publishes no result")
  Assert.isTrue(editor:press("clear_search"), "Delete clears the choice query")
  finishChoiceFilter(editor)
  local recovered = editor:snapshot()
  Assert.equal(recovered.query, "")
  Assert.equal(#recovered.options, 24, "clearing restores every row")
  Assert.equal(recovered.selectedKey, "K18", "the opening cursor identity survives a filter-clear round trip")
  Assert.isNil(editor:result(), "clearing publishes no result")
  Assert.isTrue(editor:submit(), "the restored selection still submits")
  Assert.deepEqual(editor:result(), { kind = "confirm", value = "K18" })
end

function T.multibyte_choice_query_backspace_removes_one_glyph_without_publishing()
  Assert.isTrue(loaded)
  local options = {}
  for index = 1, 8 do
    options[index] = { key = string.format("K%02d", index), label = "Choice " .. index }
  end
  local editor = SaveEditorValueEditor.new({ kind = "choice", value = "K01", options = options })
  Assert.isTrue(editor:textinput("é"), "typing accepts a multibyte glyph")
  Assert.equal(editor:snapshot().query, "é")
  Assert.isTrue(editor:press("backspace"), "Backspace removes the complete multibyte glyph")
  finishChoiceFilter(editor)
  Assert.equal(editor:snapshot().query, "", "the query is empty after removing its only glyph")
  Assert.equal(#editor:snapshot().options, 8, "the cleared query restores every row")
  Assert.isNil(editor:result(), "query edits publish no result")
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

function T.disposal_cancels_pending_choice_work_and_is_idempotent()
  local options = {}
  for index = 1, 500 do
    options[index] = { key = string.format("K%03d", index), label = "Choice " .. tostring(index) }
  end
  local editor = SaveEditorValueEditor.new({ kind = "choice", value = "K001", options = options })
  Assert.isTrue(editor:textinput("unmatched"), "typing starts choice filtering")
  Assert.isTrue(editor:snapshot().pending, "the test owns pending sliced work")

  editor:dispose()
  editor:dispose()

  Assert.equal(editor:update(256), 0, "disposed filtering cannot advance or publish")
  Assert.isFalse(editor:submit(), "disposed editors cannot submit late input")
  Assert.isFalse(editor:cancel(), "disposed editors cannot accept late cancellation")
end

function T.number_modal_uses_range_columns_in_a_content_sized_frame()
  local metrics = {
    lineHeight = 14,
    measure = function(text)
      return #text * 7
    end,
  }
  local view = {
    section = "Player",
    status = "ready",
    ready = true,
    session = { playerName = "PLAYER", money = 3000, frameIndex = 0 },
    valueEditor = {
      kind = "number",
      buffer = "123",
      parsedValue = 123,
      minimum = 0,
      maximum = 999,
      radix = 10,
      digitCount = 3,
      digits = { "1", "2", "3" },
      selectedPlace = 0,
    },
    scope = { id = "value:integer:money", epoch = 2, kind = "value", focusId = "confirm" },
    numberControlVisuals = {
      increment = {
        normal = { image = "up", width = 12, height = 12 },
        pressed = { image = "up-p", width = 12, height = 12 },
      },
      decrement = {
        normal = { image = "down", width = 12, height = 12 },
        pressed = { image = "down-p", width = 12, height = 12 },
      },
    },
  }
  local layout = SaveEditorLayout.compute(view, 640, 480, metrics)
  local modal = assert(layout.valueModal, "the number editor owns a framed modal")
  Assert.isTrue(
    modal.width < 384 and modal.height < 192,
    "the modal stays close to its source cluster instead of scaling a 256x192 system"
  )
  Assert.equal(#layout.numberLayout.columns, 3, "the integer maximum defines three columns")
  for _, column in ipairs(layout.numberLayout.columns) do
    for _, target in ipairs({ column.upRect, column.digitRect, column.downRect }) do
      Assert.isTrue(target.x >= modal.x and target.x + target.width <= modal.x + modal.width)
      Assert.isTrue(target.y >= modal.y and target.y + target.height <= modal.y + modal.height)
    end
  end
  for _, id in ipairs({ "confirm", "cancel" }) do
    local button = assert(layout.targets[id]).rect
    Assert.isTrue(
      button.x >= modal.x and button.x + button.width <= modal.x + modal.width,
      id .. " stays inside the modal"
    )
    Assert.isTrue(
      button.y >= modal.y and button.y + button.height <= modal.y + modal.height,
      id .. " stays inside the modal"
    )
  end
end

local function closeHarness(options)
  local Controller = require("app.src.saveeditor.SaveEditorController")
  local Layout = require("app.src.saveeditor.SaveEditorLayout")
  local State = require("app.src.saveeditor.SaveEditorState")
  local ModalStack = require("app.src.saveeditor.SaveEditorModalStack")
  local controller = Controller.new()
  local results = {}
  local session = {
    revision = function()
      return 0
    end,
    discards = 0,
    saveCalls = 0,
    discard = function(self)
      self.discards = self.discards + 1
    end,
    isDirty = function()
      return options.dirty == true
    end,
    snapshot = function()
      return {
        dirtySections = { money = false, frame = false, flags = false, party = false, bag = false, location = false },
        playerName = "PLAYER",
        money = 0,
        frameIndex = 0,
        location = { mapId = 7, fieldX = 10, fieldZ = 12 },
      }
    end,
    save = function(self)
      self.saveCalls = self.saveCalls + 1
      return { ok = true }
    end,
  }
  local state = setmetatable({
    approvedExit = false,
    disposed = false,
    controller = controller,
    modalStack = ModalStack.new(),
    modalLayerSequence = 0,
    session = session,
    width = 256,
    height = 192,
    renderer = {
      metrics = function()
        return { lineHeight = 14, measure = function(text)
          return #text * 7
        end }
      end,
    },
    displayContext = { measure = function()
      return {}
    end },
    presentation = { resolve = function(_, _, view)
      local metrics = view.textMetrics
      return { content = { layout = Layout.compute(view, 256, 192, metrics) } }
    end },
    valueEditor = options.valueEditor,
    valuePurpose = options.valuePurpose,
    valueReturnFocus = options.valueReturnFocus,
    monDraft = options.monDraft,
    errorMessage = nil,
    inputTick = 0,
    numberPressUntilTick = 0,
    fieldInput = {
      beginUi = function() end,
    },
    activeScopeId = "section:Player:map-list",
    scopeEpoch = 0,
    numberHold = nil,
    numberPressTarget = nil,
    onResult = function(result)
      results[#results + 1] = result
    end,
  }, State)
  return { controller = controller, session = session, state = state, results = results }
end

function T.dirty_value_editor_enters_the_leave_flow_and_cancel_restores_focus()
  local canceled = 0
  local harness = closeHarness({
    dirty = true,
    valueEditor = {
      cancel = function()
        canceled = canceled + 1
      end,
      snapshot = function()
        return { kind = "integer" }
      end,
      result = function()
        return { kind = "cancel" }
      end,
    },
    valuePurpose = "money",
    valueReturnFocus = "money",
  })
  Assert.isTrue(harness.state:requestClose("back"), "staged value work needs an explicit leave decision")
  Assert.equal(harness.controller.modal, "leave", "the leave decision opens above the value editor")
  Assert.notNil(harness.state.closeRequest, "the close request waits for its decision")
  harness.state:_activate("cancel")
  Assert.equal(canceled, 0, "canceling leave keeps the nested value editor open")
  Assert.notNil(harness.state.valueEditor, "the value editor survives a canceled leave")
  Assert.isNil(harness.controller.modal, "canceling leave restores the previous layer")
  Assert.isNil(harness.state.closeRequest, "canceling leave retires its request")
  Assert.equal(harness.controller.focus, "money", "canceling leave restores the previous focus")
  Assert.deepEqual(harness.results, {}, "a canceled leave never leaves the editor")
end

function T.invalid_party_draft_blocks_close_save_and_keeps_the_leave_decision()
  local ErrorsModule = require("libs.errors.src.Errors")
  local harness = closeHarness({})
  harness.state.monDraft = {
    mode = function()
      return "replace"
    end,
    isDirty = function()
      return true
    end,
    validate = function()
      return nil, ErrorsModule.new("PARTY_DRAFT_INVALID", "level is out of range")
    end,
  }
  harness.state.closeRequest = {
    reason = "back",
    phase = "confirm",
    previousModal = nil,
    previousModalReturnFocus = nil,
    previousFocus = "money",
  }
  harness.controller:openModal("leave")
  harness.state:_activate("save")
  Assert.equal(harness.session.saveCalls, 0, "an invalid draft never reaches the save transaction")
  Assert.notNil(harness.state.errorMessage, "an invalid draft keeps its diagnostic")
  Assert.equal(harness.state.closeRequest.phase, "confirm", "an invalid draft keeps the leave decision")
  Assert.deepEqual(harness.results, {}, "an invalid draft never leaves the editor")
end

function T.discard_from_leave_clears_staged_work_and_reports_once()
  local harness = closeHarness({ dirty = true })
  harness.state.closeRequest = {
    reason = "back",
    phase = "confirm",
    previousModal = nil,
    previousModalReturnFocus = nil,
    previousFocus = "money",
  }
  harness.controller:openModal("leave")
  harness.state:_activate("discard")
  Assert.equal(harness.session.discards, 1, "discard abandons the staged session once")
  Assert.isNil(harness.state.closeRequest, "discard retires its request")
  Assert.deepEqual(harness.results, { { kind = "main_menu" } }, "discard reports its result once")
end

local function editingMetrics()
  return {
    lineHeight = 14,
    measure = function(text)
      return #text * 7
    end,
  }
end

local function choiceEditingHarness(optionCount)
  local controller = Controller.new()
  controller:setSection("Bag")
  local loadedEditor = require("app.src.saveeditor.SaveEditorValueEditor")
  local options = {}
  for index = 1, optionCount or 12 do
    options[index] = { key = string.format("K%02d", index), label = "Choice " .. index }
  end
  local editor = loadedEditor.new({ kind = "choice", value = options[5].key, options = options })
  local metrics = editingMetrics()
  local function buildView()
    return {
      section = "Bag",
      status = "ready",
      ready = true,
      dirty = false,
      bagRows = {},
      valueEditor = editor:snapshot(),
      scope = { id = "value:choice", epoch = 1, kind = "value", focusId = controller.focus },
      scrollOffsets = {},
    }
  end
  local function buildLayout()
    editor:update(256)
    return SaveEditorLayout.compute(buildView(), 256, 192, metrics)
  end
  local finished = 0
  local state = setmetatable({
    status = "ready",
    controller = controller,
    fieldInput = FieldInput.new(),
    inputTick = 1,
    scopeEpoch = 0,
    tickRemainder = 0,
    valueEditor = editor,
    locationPreviewMemory = {},
    _snapshot = buildView,
    _resolve = function()
      return { content = { layout = buildLayout() } }
    end,
    _finishValueEditor = function()
      finished = finished + 1
    end,
  }, SaveEditorState)
  state:_syncScope()
  state.fieldInput:beginUi(0)
  return {
    state = state,
    controller = controller,
    editor = editor,
    buildLayout = buildLayout,
    finishedCount = function()
      return finished
    end,
  }
end

function T.choice_search_text_and_backspace_edit_the_query_without_navigating()
  local harness = choiceEditingHarness()
  local controller, state, editor = harness.controller, harness.state, harness.editor
  controller:setFocus("choice:K05")

  state:textinput("K1")
  editor:update(256)
  state:update(0)
  local narrowed = harness.buildLayout().lists["value:choice"].rowTargets
  Assert.isTrue(#narrowed < 12, "typing narrows the choice rows")
  Assert.isNil(editor:result(), "filtering publishes no result")
  Assert.equal(editor:snapshot().query, "K1", "typing edits the search query")
  Assert.isNil(controller.modal, "filtering opens no modal layer")
  Assert.equal(harness.finishedCount(), 0, "filtering never retires the editor")

  state:keypressed("backspace")
  state:keyreleased("backspace")
  editor:update(256)
  Assert.equal(editor:snapshot().query, "K", "backspace removes one search glyph")
  Assert.isNil(editor:result(), "query edits publish no result")
  Assert.isNil(controller.modal, "backspace opens no modal layer")
  Assert.equal(controller.section, "Bag", "backspace never leaves its section")
  Assert.equal(harness.finishedCount(), 0, "backspace never retires the editor")

  state:keypressed("delete")
  state:keyreleased("delete")
  editor:update(256)
  local restored = harness.buildLayout().lists["value:choice"].rowTargets
  Assert.equal(editor:snapshot().query, "", "delete clears the search query")
  Assert.equal(#restored, 12, "clearing restores every choice row")
  Assert.isNil(editor:result(), "clearing publishes no result")
  Assert.equal(harness.finishedCount(), 0, "clearing never retires the editor")
end

function T.number_place_keys_adjust_digits_and_disabled_confirm_keeps_the_editor_open()
  local controller = Controller.new()
  controller:setSection("Player")
  local loadedEditor = require("app.src.saveeditor.SaveEditorValueEditor")
  local editor = loadedEditor.new({ kind = "integer", value = 123, min = 0, max = 999, base = "decimal" })
  local metrics = editingMetrics()
  local function buildView()
    return {
      section = "Player",
      status = "ready",
      ready = true,
      session = { playerName = "PLAYER", money = 123, frameIndex = 0 },
      valueEditor = editor:snapshot(),
      scope = { id = "value:integer:money", epoch = 1, kind = "value", focusId = controller.focus },
      scrollOffsets = {},
      numberControlVisuals = {
        increment = { normal = { width = 8, height = 8 } },
      },
    }
  end
  local function buildLayout()
    return SaveEditorLayout.compute(buildView(), 640, 480, metrics)
  end
  local finished = 0
  local state = setmetatable({
    status = "ready",
    controller = controller,
    fieldInput = FieldInput.new(),
    inputTick = 1,
    scopeEpoch = 0,
    tickRemainder = 0,
    valueEditor = editor,
    locationPreviewMemory = {},
    _snapshot = buildView,
    _resolve = function()
      return { content = { layout = buildLayout() } }
    end,
    _finishValueEditor = function()
      finished = finished + 1
    end,
  }, SaveEditorState)
  state:_syncScope()
  state.fieldInput:beginUi(0)
  controller:setFocus("number:place:0:up")

  state:keypressed("up")
  state:keyreleased("up")
  Assert.equal(editor:snapshot().parsedValue, 124, "Up adds one to the selected units place")
  Assert.equal(controller.focus, "number:place:0:up", "place editing keeps its digit focus")
  Assert.isNil(editor:result(), "place edits publish no result")

  state:keypressed("left")
  state:keyreleased("left")
  Assert.equal(editor:snapshot().selectedPlace, 1, "Left selects the tens place")
  Assert.equal(controller.focus, "number:place:1:up", "place selection follows the selected digit")
  Assert.isNil(editor:result(), "place selection publishes no result")

  local choice = choiceEditingHarness()
  choice.controller:setFocus("choice:K05")
  choice.state:textinput("no matching choice")
  choice.editor:update(256)
  choice.state:update(0)
  Assert.equal(
    #choice.buildLayout().lists["value:choice"].rowTargets,
    0,
    "the disabled-confirm setup leaves zero rows"
  )
  choice.controller:setFocus("confirm")
  choice.state:keypressed("return")
  choice.state:keyreleased("return")
  local semantic = choiceEditingHarness()
  semantic.controller:setFocus("choice:K05")
  semantic.state:textinput("no matching choice")
  semantic.editor:update(256)
  semantic.state:update(0)
  semantic.controller:setFocus("confirm")
  semantic.state.fieldInput:pressAction("semantic:confirm")
  semantic.state:_consumeUiInput(semantic.state.fieldInput:uiSnapshot(semantic.state.inputTick))
  Assert.equal(
    choice.state.editorFeedback,
    semantic.state.editorFeedback,
    "keyboard and semantic disabled confirms report the same diagnostic"
  )
  Assert.isNil(choice.state.editorFeedback, "a disabled confirm stays silent once focus reconciles")
  Assert.isNil(choice.editor:result(), "a disabled confirm publishes no result")
  Assert.isNil(semantic.editor:result(), "a semantic disabled confirm publishes no result")
  Assert.equal(
    choice.controller.focus,
    semantic.controller.focus,
    "keyboard and semantic disabled confirms reconcile to the same focus"
  )
  Assert.equal(choice.finishedCount(), 0, "a disabled confirm never retires the editor")

  choice.state:keypressed("escape")
  choice.state:keyreleased("escape")
  Assert.deepEqual(choice.editor:result(), { kind = "cancel" }, "escape still cancels the choice editor")
  Assert.equal(choice.finishedCount(), 1, "escape retires the editor exactly once")
end

return { tests = T }
