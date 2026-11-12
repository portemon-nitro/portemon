-- Retail editor policy matrix: all three modes with completeness and
-- change semantics, the authored browser graph, confirmation protocol,
-- input modality, source transition counters, and one-shot terminal
-- results. Synthetic menu and catalog; no ROM data, no love, no saves.

local Assert = require("tests.support.Assert")
local EasyChatCatalog = require("libs.hgss.src.ui.EasyChatCatalog")
local EasyChatController = require("game.hgss.src.easychat.EasyChatController")

local T = {
  metadata = {
    tags = { "easychat" },
  },
  tests = {},
}

local NULL_WORD = 0xFFFF

---@param id integer
---@return table
local function wordRecord(id)
  return {
    id = id,
    tokens = { { kind = "glyph", code = 1, text = "w" .. id, raw = { 1 } } },
    eligibility = { kind = "always" },
  }
end

---@return table synthetic catalog data
local function syntheticData()
  local words = { wordRecord(7), wordRecord(42), wordRecord(100), wordRecord(101) }
  local function slot(selector)
    return { kind = "substitution", control = 0x100, name = "STRVAR_1", args = { selector } }
  end
  local templates = {
    { bank = 0, number = 0, wordCount = 1, tokens = { slot(0) } },
    { bank = 0, number = 1, wordCount = 2, tokens = { slot(0), slot(1) } },
    { bank = 4, number = 0, wordCount = 0, tokens = {} },
  }
  local groups, initials = {}, {}
  for index = 1, 12 do
    groups[index] = { key = string.format("group%02d", index - 1), labelTokens = {}, wordIds = {} }
  end
  groups[1].wordIds = { 42 }
  groups[2].wordIds = { 100, 101, 7 }
  for index = 1, 27 do
    initials[index] = { key = string.format("initial%02d", index - 1), labelTokens = {}, candidates = {} }
  end
  initials[1].candidates = { 42, { 100, 101 } }
  local grid = {}
  for index = 1, 27 do
    grid[index] = {
      char = index,
      x = index,
      y = 0,
      up = 0xFE,
      down = 0xFE,
      left = 0xFE,
      right = 0xFE,
      belowBack = 0,
      aboveBack = 0,
    }
  end
  grid[1] = { char = 1, x = 0, y = 0, up = 0xFE, down = 1, left = 2, right = 1, belowBack = 0, aboveBack = 2 }
  grid[2] = { char = 2, x = 1, y = 0, up = 0xFE, down = 2, left = 0, right = 0, belowBack = 1, aboveBack = 1 }
  grid[3] = { char = 3, x = 2, y = 0, up = 0xFE, down = 2, left = 1, right = 1, belowBack = 2, aboveBack = 0 }
  return {
    words = words,
    templates = templates,
    groups = groups,
    initials = initials,
    primoWords = {},
    unionAvatars = { choices = {}, rows = {} },
    gridCells = grid,
  }
end

local function promptShape()
  local row = { normal = {}, selected = {} }
  return { width = 48, height = 32, yes = row, no = row }
end

---@param catalog table
---@param request table
---@param observe fun(): table?
---@return table controller, table effects
local function openEditor(catalog, request, observe)
  local effects = {}
  local menu = catalog:buildMenu({ gameCleared = false, seen = {}, greetings = 0, trendy = 0 })
  local controller = EasyChatController.new({
    catalog = catalog,
    request = request,
    menu = menu,
    fontMetrics = {},
    promptShape = promptShape(),
    effect = function(sequence)
      effects[#effects + 1] = sequence
    end,
    observe = observe,
  })
  return controller, effects
end

---@return table catalog
local function realCatalog()
  return EasyChatCatalog.new(syntheticData())
end

---@param controller table
---@param events table
local function send(controller, events)
  controller:updateFixed(events)
end

---@param controller table
---@return table view
local function view(controller)
  return controller:view()
end

-- Moves focus to CONFIRM from any composition focus without wrapping.
---@param controller table
local function focusConfirm(controller)
  for _ = 1, 5 do
    send(controller, { { type = "navigate", direction = "down" } })
  end
  send(controller, { { type = "navigate", direction = "up" } })
end

-- Opens the browser and chooses the first word of the first group.
---@param controller table
local function chooseFirstWord(controller)
  send(controller, { { type = "confirm" } })
  for _ = 1, 10 do
    send(controller, {})
  end
  Assert.equal(view(controller).level, "categories", "confirming a field opens the categories")
  send(controller, { { type = "confirm" } })
  for _ = 1, 20 do
    send(controller, {})
  end
  Assert.equal(view(controller).level, "list", "confirming a nonempty group opens its word list")
  send(controller, { { type = "confirm" } })
  for _ = 1, 20 do
    send(controller, {})
  end
  Assert.equal(view(controller).level, "composition", "a word choice returns to composition")
end

---@param controller table
---@return table result after the exit fade
local function takeResult(controller)
  for _ = 1, 60 do
    local result = controller:takeResult()
    if result ~= nil then
      return result
    end
    send(controller, {})
  end
  error("the editor never publishes its terminal result after exit", 0)
end

-- Polls until the editor reaches the wanted level instead of assuming a
-- fixed transition length, so retail tick-count changes move both sides.
---@param controller table
---@param want string
---@param budget integer?
local function waitLevel(controller, want, budget)
  for _ = 1, (budget or 30) do
    if view(controller).level == want then
      return
    end
    send(controller, {})
  end
  error("the editor never reaches " .. want .. " (" .. tostring(view(controller).level) .. ")", 0)
end

---@param controller table
---@param x number
---@param y number
local function tap(controller, x, y)
  send(controller, { { type = "touch", phase = "down", x = x, y = y, pane = "controls" } })
end

-- Opens a touch-modality single-word editor and settles its entry fade.
---@return table controller
local function openTouchComposition()
  local controller = openEditor(realCatalog(), {
    mode = 0,
    words = { NULL_WORD, NULL_WORD },
    promptId = 0,
    alwaysConfirm = false,
    inputMode = "touch",
  }, nil)
  for _ = 1, 10 do
    send(controller, {})
  end
  return controller
end

-- Taps the composition word slot, settles the browser transition, and
-- asserts the categories level. Shared by every touch-browser journey.
---@param controller table
local function tapWordSlot(controller)
  tap(controller, 128, 24)
  waitLevel(controller, "categories")
end

-- Maps a sentence template identity to its slider-thumb center using the
-- same 2px-per-index retail mapping the controller hit-tests against.
-- Single helper so a mapping change updates one place on both sides.
---@param template table
---@return integer thumbX
local function thumbXFor(template)
  return (template.bank * 20 + template.number) * 2 + 28
end

function T.tests.mode0_word_choice_confirms_yes_with_changed_identity()
  local catalog = realCatalog()
  local controller = openEditor(catalog, {
    mode = 0,
    words = { NULL_WORD, NULL_WORD },
    promptId = 0,
    alwaysConfirm = false,
    inputMode = "buttons",
  })
  chooseFirstWord(controller)
  Assert.isNil(controller:takeResult(), "a word choice publishes nothing")
  focusConfirm(controller)
  send(controller, { { type = "confirm" } })
  local status = view(controller)
  Assert.equal(status.level, "prompt", "a complete changed draft asks its answer confirmation")
  Assert.equal(status.prompt.kind, "answer", "the complete draft takes the answer path")
  Assert.equal(status.prompt.selected, "yes", "the answer confirmation starts on YES")
  send(controller, { { type = "confirm" } })
  local result = takeResult(controller)
  Assert.equal(result.mode, 0, "the result names its single-word mode")
  Assert.isFalse(result.cancelled, "confirming YES accepts the word")
  Assert.isTrue(result.changed, "choosing a word from an empty draft counts as changed")
  Assert.equal(result.words[1], 42, "the chosen word reaches the terminal result")
  Assert.equal(result.words[2], NULL_WORD, "the single-word result carries no second word")
  Assert.equal(result.inputMode, "buttons", "the result echoes the entry modality")
  Assert.isNil(controller:takeResult(), "the terminal result publishes exactly once")
end

function T.tests.unknown_word_identities_fail_before_the_editor_opens()
  local catalog = realCatalog()
  local ok = pcall(openEditor, catalog, {
    mode = 0,
    words = { 8, NULL_WORD },
    promptId = 0,
    alwaysConfirm = false,
    inputMode = "buttons",
  })
  Assert.isFalse(ok, "an unknown single-word identity fails admission instead of drawing blank")
  local okPair = pcall(openEditor, catalog, {
    mode = 1,
    words = { 42, 8 },
    promptId = 0,
    alwaysConfirm = false,
    inputMode = "buttons",
  })
  Assert.isFalse(okPair, "an unknown paired identity fails admission")
  local okSentence = pcall(openEditor, catalog, {
    mode = 2,
    message = { bank = 0, number = 0, words = { 8, NULL_WORD } },
    promptId = 0,
    alwaysConfirm = false,
    inputMode = "buttons",
  })
  Assert.isFalse(okSentence, "an unknown sentence word fails admission instead of drawing blank")
end

function T.tests.mode0_second_word_is_required_null()
  local catalog = realCatalog()
  local ok = pcall(openEditor, catalog, {
    mode = 0,
    words = { 42, 7 },
    promptId = 0,
    alwaysConfirm = false,
    inputMode = "buttons",
  })
  Assert.isFalse(ok, "single-word mode requires its null second word")
end

function T.tests.unchanged_drafts_take_the_quit_path_with_no_first()
  local catalog = realCatalog()
  local controller = openEditor(catalog, {
    mode = 0,
    words = { NULL_WORD, NULL_WORD },
    promptId = 0,
    alwaysConfirm = false,
    inputMode = "buttons",
  })
  for _ = 1, 10 do
    send(controller, {})
  end
  focusConfirm(controller)
  send(controller, { { type = "confirm" } })
  local status = view(controller)
  Assert.equal(status.level, "prompt", "an unchanged draft still prompts")
  Assert.equal(status.prompt.kind, "quit", "an unchanged draft takes the quit path")
  Assert.equal(status.prompt.selected, "no", "the quit confirmation starts on NO")
  send(controller, { { type = "confirm" } })
  for _ = 1, 12 do
    send(controller, {})
  end
  Assert.equal(view(controller).level, "composition", "refusing the quit resumes composition")
  Assert.isNil(controller:takeResult(), "resuming publishes no result")
  focusConfirm(controller)
  send(controller, { { type = "confirm" } })
  send(controller, { { type = "navigate", direction = "down" } })
  for _ = 1, 4 do
    send(controller, {})
  end
  Assert.equal(view(controller).prompt.selected, "yes", "a vertical step toggles the quit choice")
  send(controller, { { type = "confirm" } })
  local result = takeResult(controller)
  Assert.isTrue(result.cancelled, "quitting with YES cancels the edit")
  Assert.isFalse(result.changed, "a cancelled edit reports no change")
  Assert.deepEqual(result.words, { NULL_WORD, NULL_WORD }, "cancellation returns the original payload")
end

function T.tests.cancel_key_opens_the_quit_path_and_either_vertical_toggles()
  local catalog = realCatalog()
  local controller = openEditor(catalog, {
    mode = 1,
    words = { 42, 7 },
    promptId = 0,
    alwaysConfirm = false,
    inputMode = "buttons",
  })
  for _ = 1, 10 do
    send(controller, {})
  end
  send(controller, { { type = "cancel" } })
  local status = view(controller)
  Assert.equal(status.level, "prompt", "the cancel key takes the quit path")
  Assert.equal(status.prompt.kind, "quit", "the cancel path quits")
  Assert.equal(status.prompt.selected, "no", "the cancel path starts on NO")
  send(controller, { { type = "navigate", direction = "up" } })
  for _ = 1, 4 do
    send(controller, {})
  end
  Assert.equal(view(controller).prompt.selected, "yes", "either vertical direction toggles the choice")
  send(controller, { { type = "confirm" } })
  local result = takeResult(controller)
  Assert.isTrue(result.cancelled, "the cancel path quits with YES")
  Assert.deepEqual(result.words, { 42, 7 }, "cancellation returns the original two-word payload")
end

function T.tests.forced_unchanged_drafts_accept_without_change_and_keep_full_identities()
  local catalog = realCatalog()
  local high = 42 + 0x1000
  local controller = openEditor(catalog, {
    mode = 1,
    words = { high, 7 },
    promptId = 0,
    alwaysConfirm = true,
    inputMode = "touch",
  })
  for _ = 1, 10 do
    send(controller, {})
  end
  focusConfirm(controller)
  send(controller, { { type = "confirm" } })
  local status = view(controller)
  Assert.equal(status.prompt.kind, "answer", "forced acceptance asks its answer")
  Assert.equal(status.prompt.selected, "yes", "the answer confirmation starts on YES")
  send(controller, { { type = "confirm" } })
  local result = takeResult(controller)
  Assert.isFalse(result.cancelled, "forced confirmation accepts the unchanged draft")
  Assert.isFalse(result.changed, "an unchanged forced draft reports no change")
  Assert.deepEqual(result.words, { high, 7 }, "acceptance preserves the full word identities")
  Assert.equal(result.inputMode, "touch", "the result echoes the touch entry modality")
end

function T.tests.sentence_mode_switches_templates_wraps_and_normalizes_trailing_fields()
  local catalog = realCatalog()
  local controller = openEditor(catalog, {
    mode = 2,
    message = { bank = 0, number = 1, words = { 42, 7 } },
    promptId = 0,
    alwaysConfirm = false,
    inputMode = "buttons",
  })
  for _ = 1, 10 do
    send(controller, {})
  end
  -- Template zero wraps the global index past the lower bound.
  local wrapping = openEditor(catalog, {
    mode = 2,
    message = { bank = 0, number = 0, words = { 42, NULL_WORD } },
    promptId = 0,
    alwaysConfirm = false,
    inputMode = "buttons",
  })
  for _ = 1, 10 do
    send(wrapping, {})
  end
  send(wrapping, { { type = "navigate", direction = "left" } })
  local wrapped = view(wrapping)
  Assert.equal(wrapped.template.bank, 4, "a single left step wraps the template index from zero")
  Assert.equal(wrapped.template.number, 19, "the wrapped template keeps its wrapped number")
  send(controller, { { type = "navigate", direction = "left" } })
  for _ = 1, 4 do
    send(controller, {})
  end
  local status = view(controller)
  Assert.equal(status.template.bank, 0, "a single left step moves to the previous template")
  Assert.equal(status.template.number, 0, "the previous template keeps its number")
  focusConfirm(controller)
  send(controller, { { type = "confirm" } })
  status = view(controller)
  Assert.equal(status.prompt.kind, "answer", "switching the template counts as changed")
  send(controller, { { type = "confirm" } })
  local result = takeResult(controller)
  Assert.isFalse(result.cancelled, "confirming YES accepts the sentence")
  Assert.isTrue(result.changed, "switching the template counts as changed")
  Assert.equal(result.message.bank, 0, "the accepted sentence keeps its new template identity")
  Assert.equal(result.message.number, 0, "the accepted sentence keeps its new template number")
  Assert.equal(result.message.words[1], 42, "the accepted sentence retains its required word")
  Assert.equal(result.message.words[2], NULL_WORD, "the accepted sentence normalizes its unused word")
end

function T.tests.incomplete_drafts_show_their_notice_and_dismiss_on_new_input()
  local catalog = realCatalog()
  local controller = openEditor(catalog, {
    mode = 0,
    words = { NULL_WORD, NULL_WORD },
    promptId = 0,
    alwaysConfirm = true,
    inputMode = "buttons",
  })
  for _ = 1, 10 do
    send(controller, {})
  end
  focusConfirm(controller)
  send(controller, { { type = "confirm" } })
  local status = view(controller)
  Assert.equal(status.level, "prompt", "an incomplete forced draft prompts")
  Assert.equal(status.prompt.kind, "incomplete", "the incomplete draft shows its notice")
  send(controller, { { type = "confirm" } })
  Assert.equal(view(controller).level, "composition", "a new press dismisses the notice")
  Assert.isNil(controller:takeResult(), "the notice publishes no result")
end

function T.tests.held_directions_repeat_at_eight_then_every_four()
  local catalog = realCatalog()
  local sample = { active = true }
  local controller = openEditor(catalog, {
    mode = 0,
    words = { NULL_WORD, NULL_WORD },
    promptId = 0,
    alwaysConfirm = false,
    inputMode = "buttons",
  }, function()
    return sample
  end)
  for _ = 1, 10 do
    send(controller, {})
  end
  local before = view(controller)
  sample = { active = true, pressedDirection = "down" }
  send(controller, {})
  local first = view(controller)
  Assert.isTrue(first.focus ~= before.focus, "a fresh press moves focus")
  sample = { active = true, heldDirection = "down" }
  for _ = 1, 7 do
    send(controller, {})
  end
  Assert.equal(view(controller).focus, first.focus, "held directions wait out the initial delay")
  send(controller, {})
  Assert.equal(view(controller).focus, "cancel", "the initial repeat fires on the eighth update")
  sample = { active = true }
  send(controller, {})
  sample = { active = true, pressedDirection = "up" }
  send(controller, {})
  Assert.equal(view(controller).focus, "confirm", "a fresh press after release moves again")
end

function T.tests.touch_and_held_buttons_arbitrate_the_returned_modality()
  local catalog = realCatalog()
  local buttonsHeld = false
  local controller = openEditor(catalog, {
    mode = 0,
    words = { NULL_WORD, NULL_WORD },
    promptId = 0,
    alwaysConfirm = false,
    inputMode = "buttons",
  }, function()
    return { active = true, buttonsHeld = buttonsHeld }
  end)
  for _ = 1, 10 do
    send(controller, {})
  end
  send(controller, { { type = "touch", phase = "down", x = 10, y = 10, pane = "controls" } })
  Assert.equal(view(controller).inputMode, "touch", "an unheld touch selects touch mode")
  buttonsHeld = true
  send(controller, { { type = "touch", phase = "up", x = 10, y = 10, pane = "controls" } })
  Assert.equal(view(controller).inputMode, "buttons", "a held button reclaims button mode on release")
end

function T.tests.word_list_covers_odd_rows_quit_and_back_navigation()
  local catalog = realCatalog()
  local controller = openEditor(catalog, {
    mode = 0,
    words = { NULL_WORD, NULL_WORD },
    promptId = 0,
    alwaysConfirm = false,
    inputMode = "buttons",
  }, nil)
  for _ = 1, 10 do
    send(controller, {})
  end
  send(controller, { { type = "confirm" } })
  for _ = 1, 10 do
    send(controller, {})
  end
  send(controller, { { type = "navigate", direction = "right" } })
  for _ = 1, 4 do
    send(controller, {})
  end
  send(controller, { { type = "confirm" } })
  for _ = 1, 20 do
    send(controller, {})
  end
  Assert.equal(view(controller).level, "list", "the second group offers a three-word list")
  local list = view(controller).list
  Assert.equal(list.topRow, 0, "a short list never scrolls")
  -- Two downs reach the odd last row, a third focuses QUIT, up restores.
  send(controller, { { type = "navigate", direction = "down" } })
  send(controller, { { type = "navigate", direction = "down" } })
  send(controller, { { type = "navigate", direction = "down" } })
  Assert.isTrue(view(controller).list.quit, "bottom down focuses QUIT")
  send(controller, { { type = "navigate", direction = "up" } })
  Assert.isFalse(view(controller).list.quit, "up from QUIT restores the prior row")
  send(controller, { { type = "cancel" } })
  for _ = 1, 20 do
    send(controller, {})
  end
  Assert.equal(view(controller).level, "categories", "leaving the list returns to its categories")
end

function T.tests.category_back_and_tab_rules_follow_the_source_neighbors()
  local catalog = realCatalog()
  local controller = openEditor(catalog, {
    mode = 0,
    words = { NULL_WORD, NULL_WORD },
    promptId = 0,
    alwaysConfirm = false,
    inputMode = "buttons",
  }, nil)
  for _ = 1, 10 do
    send(controller, {})
  end
  send(controller, { { type = "confirm" } })
  for _ = 1, 10 do
    send(controller, {})
  end
  -- Group 9 (last row) then down enters BACK.
  for _ = 1, 3 do
    send(controller, { { type = "navigate", direction = "down" } })
  end
  send(controller, { { type = "navigate", direction = "right" } })
  send(controller, { { type = "navigate", direction = "right" } })
  send(controller, { { type = "navigate", direction = "down" } })
  Assert.equal(view(controller).browser.group, 0xFE, "down from the last row enters BACK")
  send(controller, { { type = "navigate", direction = "up" } })
  Assert.isTrue(view(controller).browser.group ~= 0xFE, "up from BACK returns to the grid")
  -- The shoulder select swaps the browser tab and resets the selection.
  send(controller, { { type = "button", button = "select" } })
  for _ = 1, 20 do
    send(controller, {})
  end
  local browser = view(controller).browser
  Assert.equal(browser.tab, "abc", "select swaps the browser tab")
  Assert.equal(browser.group, 0, "select resets the selection to zero")
end

function T.tests.transitions_gate_input_until_their_fixed_tick_counts_elapse()
  local catalog = realCatalog()
  local controller = openEditor(catalog, {
    mode = 0,
    words = { NULL_WORD, NULL_WORD },
    promptId = 0,
    alwaysConfirm = false,
    inputMode = "buttons",
  }, nil)
  for _ = 1, 10 do
    send(controller, {})
  end
  send(controller, { { type = "confirm" } })
  send(controller, { { type = "confirm" } })
  for _ = 1, 3 do
    send(controller, {})
  end
  Assert.equal(view(controller).level, "composition", "the gated confirm never opens anything early")
  for _ = 1, 10 do
    send(controller, {})
  end
  send(controller, { { type = "confirm" } })
  for _ = 1, 20 do
    send(controller, {})
  end
  Assert.equal(view(controller).level, "list", "the retried confirm opens the list after the transition")
end

function T.tests.prompt_verdicts_publish_after_the_confirmation_blink_only()
  local catalog = realCatalog()
  local controller = openEditor(catalog, {
    mode = 0,
    words = { 42, NULL_WORD },
    promptId = 0,
    alwaysConfirm = true,
    inputMode = "buttons",
  }, nil)
  for _ = 1, 10 do
    send(controller, {})
  end
  focusConfirm(controller)
  send(controller, { { type = "confirm" } })
  Assert.equal(view(controller).prompt.kind, "answer", "the forced draft asks its answer")
  send(controller, { { type = "confirm" } })
  for _ = 1, 5 do
    send(controller, {})
  end
  Assert.isNil(controller:takeResult(), "no result publishes before the blink completes")
  local result = takeResult(controller)
  Assert.isFalse(result.cancelled, "the blinked YES accepts")
end

-- A pointer-only journey completes the editor: tapping the word slot
-- opens the browser, tapping a category cell opens its word list,
-- tapping a list word returns to composition, and tapping the drawn
-- CONFIRM answers YES without any button navigation.
function T.tests.touch_only_journey_selects_a_word_and_confirms()
  local controller = openTouchComposition()
  tapWordSlot(controller)
  tap(controller, 48, 64)
  waitLevel(controller, "list")
  tap(controller, 68, 56)
  waitLevel(controller, "composition")
  Assert.equal(view(controller).inputMode, "touch", "the pointer journey stays in touch modality")
  tap(controller, 224, 120)
  Assert.equal(view(controller).level, "prompt", "tapping CONFIRM asks its answer")
  tap(controller, 224, 112)
  local result = takeResult(controller)
  Assert.isFalse(result.cancelled, "tapping YES accepts the word")
  Assert.equal(result.words[1], 42, "the touched word reaches the terminal result")
end

-- The ABC tab and its authored grid cells answer touch: switching tabs
-- resets the selection, and tapping the first initial opens its list.
function T.tests.touch_switches_tabs_and_selects_an_abc_cell()
  local controller = openTouchComposition()
  tapWordSlot(controller)
  tap(controller, 196, 21)
  waitLevel(controller, "abc", 30)
  local browser = view(controller).browser
  Assert.equal(browser.tab, "abc", "tapping the right tab switches to ABC")
  Assert.equal(browser.group, 0, "switching tabs resets the selection")
  -- Synthetic grid cell 0 sits at x=0,y=0, so its screen box opens at
  -- (20,64) with a 16px extent.
  tap(controller, 24, 68)
  waitLevel(controller, "list", 30)
  tap(controller, 68, 56)
  waitLevel(controller, "composition", 30)
end

-- Sentence-mode template arrows answer touch on either pane, and the
-- slider thumb drags the template index without opening the browser.
function T.tests.touch_template_arrows_and_slider_drag()
  local catalog = realCatalog()
  local controller = openEditor(catalog, {
    mode = 2,
    message = { bank = 0, number = 1, words = { 42, 7 } },
    promptId = 0,
    alwaysConfirm = false,
    inputMode = "touch",
  }, nil)
  for _ = 1, 10 do
    send(controller, {})
  end
  local before = view(controller).template
  tap(controller, 24, 64)
  local afterArrow = view(controller).template
  Assert.isTrue(afterArrow.bank ~= before.bank or afterArrow.number ~= before.number, "the left arrow moves the template")
  local thumbX = thumbXFor(afterArrow)
  send(controller, { { type = "touch", phase = "down", x = thumbX, y = 64, pane = "controls" } })
  send(controller, { { type = "touch", phase = "move", x = thumbX + 20, y = 64, pane = "controls" } })
  send(controller, { { type = "touch", phase = "up", x = thumbX + 20, y = 64, pane = "controls" } })
  local afterDrag = view(controller).template
  Assert.isTrue(
    afterDrag.bank ~= afterArrow.bank or afterDrag.number ~= afterArrow.number,
    "dragging the slider thumb moves the template index"
  )
end

return T
