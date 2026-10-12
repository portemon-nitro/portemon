-- Map annotation word choice: confirming one word commits exactly one
-- slot, cancelling at any nested level preserves the old word, stale
-- results fail without touching marking state, and every return restores
-- the recorded map session. The native single-word mode renders its own
-- source layout and answers host input; mail-mode geometry and flattened
-- word lists are rejected, never silently accepted. The scenarios run
-- through the real region map controller with a narrow word-entry
-- handoff plus synthetic gate-derived fixtures until the selector lands.

local Assert = require("tests.support.Assert")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearState = require("libs.hgss.src.save.PokegearState")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

-- Loads a word-entry module that does not exist yet at this baseline. The
-- failure names the missing behaviour instead of surfacing as a suite
-- load error, so the pre-implementation red stays attributable.
---@param moduleName string
---@param missingMessage string
---@return table
local function requireFeature(moduleName, missingMessage)
  local ok, mod = pcall(require, moduleName)
  if not ok then
    error(missingMessage, 0)
  end
  assert(type(mod) == "table", missingMessage)
  return mod --[[@as table]]
end

---@param path string
---@return table
local function visualRef(path)
  return { image = path, width = 32, height = 32, anchorX = 0, anchorY = 0 }
end

-- Synthetic companion catalog with one annotation location, validated
-- through the real asset schema so the journey borrows only genuine
-- semantic references.
---@return table
local function fixtureManifest()
  return {
    schema = "g4-pokegear-assets-v1",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png") },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png") },
    phone = { panel = visualRef("assets/generated/pokegear/phone-panel.png") },
    map = { base = visualRef("assets/generated/pokegear/map-base.png") },
    fly = { base = visualRef("assets/generated/pokegear/fly-base.png") },
    radio = { dial = visualRef("assets/generated/pokegear/radio-dial.png") },
    catalog = {
      contacts = {},
      contactOrder = {},
      callDefinitions = {},
      callTriggers = {},
      rematches = {},
      gifts = {},
      momPurchases = {},
      locations = {
        { key = "test.place.violet" },
      },
      flypoints = {},
      reception = {},
      shows = {},
      radioEffects = {},
    },
    text = {},
    sequences = {},
  }
end

-- Gate-derived word catalog: eleven groups in source order with source
-- counts; identities are decimal strings from the group base.
local GROUP_COUNTS = { 496, 468, 18, 124, 38, 38, 107, 104, 47, 32, 23 }
local WORD_BANKS = { 237, 751, 735, 721, 285, 286, 287, 288, 289, 290, 291 }

---@return table catalog
local function gateWordCatalog()
  local catalog = { groups = {} }
  for index, bank in ipairs(WORD_BANKS) do
    catalog.groups[index] = { group = index - 1, bank = bank, count = GROUP_COUNTS[index] }
  end
  return catalog
end

---@return table context
local function mapContext()
  return {
    fieldMap = "test.field.violet",
    location = "test.place.violet",
    matrixX = 64,
    matrixY = 32,
    region = "johto",
    unlockLevel = 1,
    specialMode = nil,
    playerGender = "boy",
  }
end

---@param state table
---@param validated table
---@return table map
local function openMap(state, validated)
  local MapController = require("game.hgss.src.pokegear.MapController")
  return MapController.new({
    state = state,
    assets = validated,
    mapContext = mapContext(),
    phoneProjection = function(_)
      return {}
    end,
    roamerProjection = {},
    wordEntry = { open = function(_) end, step = function() end, result = function()
      return nil
    end, cancel = function() end },
  })
end

-- Enters marking mode through the real entrance transition, then taps a
-- word slot: input is gated while the transition runs, exactly like the
-- retail flow.
---@param map table
---@param slot integer
---@return table request
local function tapWordSlot(map, slot)
  map:updateFixed({ { type = "confirm" } })
  for _ = 1, 12 do
    map:updateFixed({})
  end
  local status = map:status()
  local view = assert(status.view, "the open map publishes its view")
  Assert.equal(status.markingMode, "marking", "the entrance transition reaches marking mode")
  local panel = assert(view.markingPanel, "marking mode publishes its panel")
  local rect = assert(panel.words[slot], "word slot " .. slot .. " publishes its hit region")
  local point = { x = rect.x + rect.width / 2, y = rect.y + rect.height / 2 }
  map:updateFixed({ { type = "pointer_down", pointerId = 1, x = point.x, y = point.y } })
  map:updateFixed({ { type = "pointer_up", pointerId = 1, x = point.x, y = point.y } })
  local request = map:takeWordRequest()
  Assert.notNil(request, "tapping a word slot pends one typed request")
  return assert(request)
end

-- Adapts the selector terminal result onto the map result contract: a
-- selected word carries its decimal identity, a cancellation preserves
-- the old word.
---@param answer table<string, unknown>
---@return table<string, unknown>
local function toMapAnswer(answer)
  assert(type(answer.operationId) == "string", "selector answers carry their operation identity")
  if answer.kind == "cancelled" then
    return { operationId = answer.operationId, result = { cancelled = true } }
  end
  Assert.equal(answer.kind, "selected", "selector answers select or cancel exactly once")
  assert(type(answer.wordKey) == "string", "selected answers carry the decimal word identity")
  return { operationId = answer.operationId, result = { word = answer.wordKey } }
end

-- Confirming one word writes exactly one slot and restores the recorded
-- session; cancelling preserves the old word with the same restore; stale
-- and replayed results fail without touching marking state.
function T.tests.annotation_word_choice_commits_once_and_restores_the_map()
  local WordEntryScreenState = requireFeature(
    "game.hgss.src.pokegear.WordEntryScreenState",
    "the map annotation has no word selector yet: "
      .. "confirming a word cannot commit one slot and restore the map session"
  )
  local validated = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(validated, "the synthetic companion catalog must validate through the asset schema")
  assert(validated ~= nil, "synthetic catalog validated above")
  local catalog = validated.catalog
  local state = PokegearState.new({ seed = 44021 }, { catalog = catalog })
  local map = openMap(state, validated)
  local words = gateWordCatalog()

  local request = tapWordSlot(map, 2)
  Assert.equal(request.slot, 2, "the request names its word slot")
  Assert.equal(request.locationKey, "test.place.violet", "the request names its location")
  local session = assert(request.session, "the request carries the recorded map session")
  Assert.isTrue(map:status().busy, "the map reports busy while the word edit pends")

  local selector = WordEntryScreenState.new({
    operationId = request.operationId,
    selectedWord = request.oldWord,
    wordCatalog = words,
    availability = {},
    assets = validated,
    presentation = { layout = "dual" },
  })
  selector:updateFixed({ { type = "confirm" } })
  for _ = 1, 42 do
    selector:updateFixed({ { type = "navigate", direction = "down" } })
  end
  selector:updateFixed({ { type = "confirm" } })
  selector:updateFixed({ { type = "confirm" } })
  local answer = selector:takeResult()
  Assert.notNil(answer, "confirming reports one terminal result")
  map:acceptWordResult(toMapAnswer(assert(answer)))
  selector:dispose()

  local after = map:status()
  Assert.isFalse(after.busy, "the map leaves busy once the word resolves")
  Assert.equal(after.view.marking.words[2], "42", "exactly the tapped slot commits the chosen word")
  Assert.equal(after.view.marking.words[1], false, "untouched slots keep their empty state")
  Assert.deepEqual(after.view.pan, session.pan, "the word return restores the recorded pan")
  Assert.equal(after.view.zoomCells, session.zoomCells, "the word return restores the recorded zoom")
  Assert.deepEqual(after.view.cursor, session.cursor, "the word return restores the recorded cursor")
  Assert.equal(after.markingMode, session.markingMode, "the word return restores marking mode")

  -- Cancelling at the nested selector level preserves the committed word
  -- and restores the same session snapshot shape.
  local cancelRequest = tapWordSlot(map, 2)
  Assert.equal(cancelRequest.oldWord, "42", "reopening a filled slot carries the committed word")
  local cancelSelector = WordEntryScreenState.new({
    operationId = cancelRequest.operationId,
    selectedWord = cancelRequest.oldWord,
    wordCatalog = words,
    availability = {},
    assets = validated,
    presentation = { layout = "dual" },
  })
  cancelSelector:updateFixed({ { type = "cancel" } })
  local cancelAnswer = cancelSelector:takeResult()
  Assert.notNil(cancelAnswer, "cancelling reports one terminal result")
  map:acceptWordResult(toMapAnswer(assert(cancelAnswer)))
  cancelSelector:dispose()
  local kept = map:status()
  Assert.equal(kept.view.marking.words[2], "42", "a cancelled edit preserves the committed word")
  Assert.deepEqual(kept.view.pan, cancelRequest.session.pan, "a cancel restores the recorded pan")

  -- A stale identity and a replayed identity both fail, and neither moves
  -- marking state.
  local marked = map:status().view.marking
  local staleOk = pcall(map.acceptWordResult, map, {
    operationId = "map-word-404",
    result = { word = "9" },
  })
  Assert.isFalse(staleOk, "an unknown word operation fails")
  local replayOk = pcall(map.acceptWordResult, map, {
    operationId = cancelRequest.operationId,
    result = { word = "9" },
  })
  Assert.isFalse(replayOk, "a replayed word result fails")
  Assert.deepEqual(
    map:status().view.marking,
    marked,
    "failed word results leave marking state untouched"
  )
  map:dispose()
end

-- The selector renders its own single-word mode and answers host input
-- through the shared semantic vocabulary; mail-mode geometry and a
-- flattened word list are rejected instead of silently accepted.
function T.tests.single_word_selector_renders_its_own_mode_and_rejects_substitutes()
  local WordEntryScreenState = requireFeature(
    "game.hgss.src.pokegear.WordEntryScreenState",
    "the map annotation has no word selector yet: "
      .. "the single-word mode cannot render or answer host input"
  )
  local Renderer = requireFeature(
    "libs.hgss.src.presentation.PokegearWordEntryRenderer",
    "the map annotation has no word renderer yet: "
      .. "the single-word mode cannot project its source layout"
  )
  local validated = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(validated, "the synthetic companion catalog must validate through the asset schema")
  assert(validated ~= nil, "synthetic catalog validated above")
  local words = gateWordCatalog()

  local selector = WordEntryScreenState.new({
    operationId = "map-word-1",
    selectedWord = false,
    wordCatalog = words,
    availability = {},
    assets = validated,
    presentation = { layout = "dual" },
  })
  local first = selector:status()
  Assert.notNil(first, "the selector publishes its status")
  local plan = Renderer.layout(first)
  Assert.notNil(plan, "the renderer projects a layout plan without drawing")
  Assert.equal(plan.mode, "single-word", "the plan names the single-word mode")

  -- Controller navigation and the matching touch point advance the same
  -- focus: host input stays in the shared semantic vocabulary.
  selector:updateFixed({ { type = "navigate", direction = "right" } })
  local byButton = selector:status()
  selector:updateFixed({ { type = "cancel" } })
  selector:updateFixed({ { type = "navigate", direction = "right" } })
  local andBack = selector:status()
  Assert.deepEqual(andBack, byButton, "one navigation step moves focus deterministically")

  -- Mail-mode geometry is a different mode, not a skin of this one: a
  -- mail request against the single-word selector fails loudly.
  local mailOk = pcall(WordEntryScreenState.new, {
    operationId = "map-word-2",
    selectedWord = false,
    wordCatalog = words,
    availability = {},
    assets = validated,
    presentation = { layout = "dual", mode = "mail" },
  })
  Assert.isFalse(mailOk, "mail-mode geometry never opens as the single-word selector")

  -- A flattened word list is not the native selector: collapsing the
  -- eleven source groups into one unsorted pool fails validation instead
  -- of rendering a fake flat list.
  local flat = { groups = { { group = 0, bank = 237, count = 1495 } } }
  local flatOk = pcall(WordEntryScreenState.new, {
    operationId = "map-word-3",
    selectedWord = false,
    wordCatalog = flat,
    availability = {},
    assets = validated,
    presentation = { layout = "dual" },
  })
  Assert.isFalse(flatOk, "a flattened word list never counts as the native selector")
  selector:dispose()
end

return T
