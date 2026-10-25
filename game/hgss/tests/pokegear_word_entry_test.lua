-- Single-word map annotation selector: the category/word/confirm graph
-- offers exactly the source group order with decimal word identities,
-- selects exactly once, cancels at every nested level without writing,
-- and rejects foreign modes, flattened catalogs, and unknown identities.

local Assert = require("tests.support.Assert")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

local GROUP_COUNTS = { 496, 468, 18, 124, 38, 38, 107, 104, 47, 32, 23 }
local WORD_BANKS = { 237, 751, 735, 721, 285, 286, 287, 288, 289, 290, 291 }

---@return table catalog with eleven groups in source order
local function wordCatalog()
  local catalog = { groups = {} }
  for index, bank in ipairs(WORD_BANKS) do
    catalog.groups[index] = { group = index - 1, bank = bank, count = GROUP_COUNTS[index] }
  end
  return catalog
end

---@param overrides table<string, unknown>?
---@return table options
local function options(overrides)
  local opts = {
    operationId = "map-word-1",
    selectedWord = false,
    wordCatalog = wordCatalog(),
    availability = {},
    assets = { catalog = { locations = {} } },
    presentation = { layout = "dual" },
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      opts[key] = value
    end
  end
  return opts
end

local function requireState()
  local ok, mod = pcall(require, "game.hgss.src.pokegear.WordEntryScreenState")
  if not ok then
    error("the map annotation has no word selector yet", 0)
  end
  return mod --[[@as table]]
end

---@param selector table
---@param count integer
---@param event table
local function repeatEvent(selector, count, event)
  for _ = 1, count do
    selector:updateFixed({ event })
  end
end

-- Drills from the category level to the indexed word of group zero and
-- confirms it through the confirmation level.
---@param selector table
---@param index integer zero-based word index within group zero
local function confirmWord(selector, index)
  selector:updateFixed({ { type = "confirm" } })
  repeatEvent(selector, index, { type = "navigate", direction = "down" })
  selector:updateFixed({ { type = "confirm" } })
  selector:updateFixed({ { type = "confirm" } })
end

function T.tests.fresh_selector_opens_on_the_category_level_without_a_result()
  local WordEntryScreenState = requireState()
  local selector = WordEntryScreenState.new(options())
  local view = selector:status()
  Assert.equal(view.mode, "single-word", "the fresh selector names its single-word mode")
  Assert.equal(view.level, "category", "the fresh selector starts on the category level")
  Assert.equal(view.group, 0, "the fresh selector starts on the first source group")
  Assert.equal(view.groupCount, 11, "the selector keeps all eleven source groups")
  Assert.equal(view.groupSize, 496, "the first group offers its source word count")
  Assert.isNil(selector:takeResult(), "the fresh selector reports no terminal result")
  selector:dispose()
end

function T.tests.confirming_through_word_choice_selects_exactly_once()
  local WordEntryScreenState = requireState()
  local selector = WordEntryScreenState.new(options())
  confirmWord(selector, 3)
  local answer = selector:takeResult()
  Assert.notNil(answer, "confirming a word reports one terminal result")
  Assert.equal(answer.operationId, "map-word-1", "the answer carries the caller operation identity")
  Assert.equal(answer.kind, "selected", "the answer selects exactly once")
  Assert.equal(answer.wordKey, "3", "the answer carries the decimal identity of the focused word")
  Assert.isNil(selector:takeResult(), "the terminal result is consumed exactly once")
  selector:dispose()
end

function T.tests.navigation_wraps_across_categories_and_within_words()
  local WordEntryScreenState = requireState()
  local selector = WordEntryScreenState.new(options())
  selector:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.equal(selector:status().group, 10, "stepping left past the first group wraps to the last")
  selector:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(selector:status().group, 0, "stepping right past the last group wraps to the first")
  selector:updateFixed({ { type = "confirm" } })
  selector:updateFixed({ { type = "navigate", direction = "up" } })
  local wrapped = selector:status()
  Assert.equal(wrapped.wordKey, "495", "stepping up past the first word wraps to the last word")
  selector:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(selector:status().wordKey, "0", "stepping down past the last word wraps to the first")
  Assert.isNil(selector:takeResult(), "navigation alone reports no terminal result")
  selector:dispose()
end

function T.tests.cancel_retreats_one_level_and_cancels_from_the_top()
  local WordEntryScreenState = requireState()
  local selector = WordEntryScreenState.new(options())
  selector:updateFixed({ { type = "confirm" } })
  Assert.equal(selector:status().level, "word", "confirming a category opens its word list")
  selector:updateFixed({ { type = "cancel" } })
  Assert.equal(selector:status().level, "category", "cancelling the word list returns to categories")
  Assert.isNil(selector:takeResult(), "retreating one level reports no terminal result")
  selector:updateFixed({ { type = "confirm" } })
  selector:updateFixed({ { type = "confirm" } })
  Assert.equal(selector:status().level, "confirm", "confirming a word asks for confirmation")
  selector:updateFixed({ { type = "cancel" } })
  Assert.equal(selector:status().level, "word", "cancelling the prompt returns to the word list")
  selector:updateFixed({ { type = "cancel" } })
  selector:updateFixed({ { type = "cancel" } })
  local answer = selector:takeResult()
  Assert.notNil(answer, "cancelling from the top level reports one terminal result")
  Assert.equal(answer.kind, "cancelled", "a top-level cancel carries no word")
  Assert.equal(answer.operationId, "map-word-1", "the cancellation carries the caller operation identity")
  selector:dispose()
end

function T.tests.foreign_modes_and_flattened_catalogs_fail_at_construction()
  local WordEntryScreenState = requireState()
  Assert.isFalse(
    pcall(
      WordEntryScreenState.new,
      options({
        presentation = { layout = "dual", mode = "mail" },
      })
    ),
    "mail-mode geometry never opens as the single-word selector"
  )
  Assert.isFalse(
    pcall(WordEntryScreenState.new, options({ wordCatalog = { groups = { { group = 0, bank = 237, count = 1495 } } } })),
    "a flattened word list never counts as the native selector"
  )
  local withoutAvailability = options()
  withoutAvailability.availability = nil
  Assert.isFalse(
    pcall(WordEntryScreenState.new, withoutAvailability),
    "a missing availability projection never falls back to permissive offering"
  )
  Assert.isFalse(
    pcall(WordEntryScreenState.new, options({ operationId = "" })),
    "an empty operation identity never opens the selector"
  )
  Assert.isFalse(
    pcall(WordEntryScreenState.new, options({ selectedWord = "not-a-word" })),
    "a non-decimal preselection never opens the selector"
  )
end

function T.tests.hidden_words_are_never_offered_and_empty_groups_confirm_nothing()
  local WordEntryScreenState = requireState()
  local offered = WordEntryScreenState.wordsInGroup(wordCatalog(), 0, { unavailable = { ["5"] = true } })
  Assert.equal(#offered, 495, "one hidden word leaves the rest of the group offered")
  local found = false
  for _, key in ipairs(offered) do
    if key == "5" then
      found = true
    end
  end
  Assert.isFalse(found, "the hidden word identity is never offered")
  Assert.equal(offered[6], "6", "hiding a word compacts the offered order without gaps")

  local hidden = {}
  for index = 0, 495 do
    hidden[tostring(index)] = true
  end
  local selector = WordEntryScreenState.new(options({ availability = { unavailable = hidden } }))
  local view = selector:status()
  Assert.equal(view.groupSize, 0, "a fully hidden group offers no words")
  Assert.isNil(view.wordKey, "a fully hidden group focuses no word")
  selector:updateFixed({ { type = "confirm" } })
  selector:updateFixed({ { type = "confirm" } })
  selector:updateFixed({ { type = "confirm" } })
  Assert.isNil(selector:takeResult(), "confirming through an empty group selects nothing")
  selector:dispose()
end

function T.tests.unknown_preselection_opens_unfocused_and_cancels_cleanly()
  local WordEntryScreenState = requireState()
  local selector = WordEntryScreenState.new(options({ selectedWord = "9000" }))
  local view = selector:status()
  Assert.equal(view.group, 0, "an unresolvable preselection falls back to the first group")
  Assert.equal(view.wordKey, "0", "an unresolvable preselection focuses the first offered word")
  selector:updateFixed({ { type = "cancel" } })
  local answer = selector:takeResult()
  Assert.notNil(answer, "cancelling after an unknown preselection still reports one result")
  Assert.equal(answer.kind, "cancelled", "the cancellation preserves the old word by carrying none")
  selector:dispose()
end

function T.tests.unknown_identities_fail_loudly_instead_of_resolving()
  local WordEntryScreenState = requireState()
  Assert.isNil(WordEntryScreenState.wordKey(0xFFFF), "the null word carries no selectable identity")
  Assert.equal(WordEntryScreenState.wordKey(42), "42", "a valid word keeps its decimal identity")
  Assert.isFalse(
    pcall(WordEntryScreenState.wordKey, 99999),
    "an out-of-range word identity never resolves to a neighbour"
  )
  Assert.isFalse(
    pcall(WordEntryScreenState.wordsInGroup, wordCatalog(), 11, {}),
    "a group index past the source groups fails"
  )
end

function T.tests.disposal_abandons_untaken_results_and_steps_nothing()
  local WordEntryScreenState = requireState()
  local selector = WordEntryScreenState.new(options())
  confirmWord(selector, 1)
  selector:dispose()
  Assert.isNil(selector:takeResult(), "disposal abandons the untaken selection")
  Assert.isFalse(pcall(selector.updateFixed, selector, {}), "a disposed selector steps nothing")
  local cancelled = WordEntryScreenState.new(options({ operationId = "map-word-9" }))
  cancelled:updateFixed({ { type = "cancel" } })
  cancelled:dispose()
  Assert.isNil(cancelled:takeResult(), "disposal abandons the untaken cancellation")
end

function T.tests.preselection_resolves_within_the_offered_order()
  local WordEntryScreenState = requireState()
  local selector =
    WordEntryScreenState.new(options({ selectedWord = "6", availability = { unavailable = { ["5"] = true } } }))
  local view = selector:status()
  Assert.equal(view.wordKey, "6", "a carried word past a hidden word still focuses its own identity")
  selector:updateFixed({ { type = "confirm" } })
  selector:updateFixed({ { type = "confirm" } })
  selector:updateFixed({ { type = "confirm" } })
  local answer = selector:takeResult()
  Assert.notNil(answer, "confirming the preselected word reports one terminal result")
  Assert.equal(answer.wordKey, "6", "the reconfirmed word keeps its decimal identity")
  selector:dispose()
end

return T
