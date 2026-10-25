-- Search criteria, editor transactions, ordered filtering, nonuniform
-- sliders, and result membership: every search editor through the public
-- fixed-update projection. Real knowledge owner and compact synthetic
-- catalogs with deliberate order ties; only readiness is stubbed. No
-- renderer, GPU, audio device, ROM, or worker is touched.

local Assert = require("tests.support.Assert")
local PokedexDexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")
local PokedexSources = require("romdump.src.config.PokedexSources")

local CONTROLLER_MODULE = "game.hgss.src.pokedex.PokedexController"
local SEARCH_MODULE = "game.hgss.src.pokedex.PokedexSearch"

local T = {}

---@param behavior string missing browser behavior under test
---@return table the loaded browser controller owner
local function requirePresent(behavior)
  local ok, loaded = pcall(require, CONTROLLER_MODULE)
  Assert.isTrue(ok, "missing browser state owner: " .. behavior .. " (" .. CONTROLLER_MODULE .. ")")
  assert(loaded ~= nil, "the browser module loads")
  return loaded --[[@as table]]
end

local function catalogs()
  local monCatalog = PokedexDexFixture.makeCatalog()
  local catalog = PokedexDexFixture.buildPokedexCatalog()
  return monCatalog, catalog
end

-- Attaches the published editor option order to a synthetic catalog and
-- admits every ordered key, so the runtime can resolve each position to
-- a declared option exactly like it does against generated data.
local function withPublishedOptionOrder(catalog)
  local criteria = assert(catalog.criteria, "the synthetic catalog carries its search criteria")
  local typeOrder = {}
  for _, name in ipairs(PokedexSources.typeOrder) do
    typeOrder[#typeOrder + 1] = name
  end
  typeOrder[#typeOrder + 1] = "unrestricted"
  local shapeOrder = {}
  for _, name in ipairs(PokedexSources.shapeOrder) do
    shapeOrder[#shapeOrder + 1] = name
  end
  shapeOrder[#shapeOrder + 1] = "unrestricted"
  criteria.typeOptionOrder = typeOrder
  criteria.shapeOptionOrder = shapeOrder
  local types = assert(criteria.types, "the synthetic catalog carries its type lists")
  for _, name in ipairs(PokedexSources.typeOrder) do
    if types[name] == nil then
      types[name] = { "CHIKORITA" }
    end
  end
  local shapes = assert(criteria.shapes, "the synthetic catalog carries its shape lists")
  for _, name in ipairs(PokedexSources.shapeOrder) do
    if shapes[name] == nil then
      shapes[name] = { "CHIKORITA" }
    end
  end
  return catalog
end

local function enabledOwner(monCatalog, catalog)
  local owner = PokedexKnowledge.new(PokedexDexFixture.refs(monCatalog, catalog))
  owner:prepareChanges({ flags = { dexEnabled = true, nationalDex = true } }):publish()
  return owner
end

---@param owner table knowledge owner under test
---@param monCatalog table resolved mon catalog
---@param fields table specimen fields
---@param kind string|nil observation kind
local function observe(owner, monCatalog, fields, kind)
  local specimen = owner:describe(PokedexDexFixture.makeMon(monCatalog, fields))
  owner:prepareChanges({ observations = { { kind = kind or "caught", specimen = specimen } } }):publish()
end

local function newBrowser(PokedexController, owner, monCatalog, catalog)
  return PokedexController.new({
    catalog = catalog,
    monCatalog = monCatalog,
    dex = owner,
    playerGender = "male",
    playerPosition = { mapX = 10, mapY = 10 },
    nativeLanguage = "english",
  })
end

---@param controller table browser under test
---@return table preparation carrying the currently demanded ready key
local function readyPrep(controller)
  return { readyKey = controller:view().key }
end

---@param controller table browser under test
---@param events table|nil semantic batch for one fixed update
local function tick(controller, events)
  controller:updateFixed(events or {}, readyPrep(controller))
end

---@param controller table browser under test
---@param count integer fixed updates to advance with no input
local function idle(controller, count)
  for _ = 1, count do
    tick(controller)
  end
end

local function openSearch(controller)
  tick(controller, { { type = "drag", target = "cover", phase = "begin", value = 0 } })
  tick(controller, { { type = "drag", target = "cover", phase = "move", value = 200 } })
  tick(controller, { { type = "drag", target = "cover", phase = "end", value = 64 } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "grid", "the cover drag reaches the grid before searching")
  tick(controller, { { type = "y" } })
  idle(controller, 10)
  Assert.equal(controller:view().page, "search", "the criteria root opens from the grid")
end

---@param controller table browser under test
local function runSearch(controller)
  tick(controller, { { type = "start" } })
  idle(controller, 250)
end

---@param controller table browser under test
---@return table result entries in slot order
local function resultEntries(controller)
  Assert.equal(controller:view().page, "results", "the search completes onto the result grid")
  return controller:view().grid.buffers[1].entries
end

---@param entries table result entries in slot order
---@return string[] species keys excluding the return slot
local function resultSpecies(entries)
  local species = {}
  for _, entry in ipairs(entries) do
    if entry.returnToSearch ~= true then
      species[#species + 1] = entry.species
    end
  end
  return species
end

local function catchAllDisplayed(owner, monCatalog)
  for _, key in ipairs(PokedexDexFixture.DISPLAY_ORDER) do
    observe(owner, monCatalog, { species = key, personality = 31 })
  end
end

function T.numerical_search_preserves_dex_order_through_ties()
  local PokedexController = requirePresent("complete search and editor behavior")
  local monCatalog, catalog = catalogs()
  local owner = enabledOwner(monCatalog, catalog)
  catchAllDisplayed(owner, monCatalog)
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openSearch(controller)
  runSearch(controller)
  local species = resultSpecies(resultEntries(controller))
  Assert.deepEqual(species, PokedexDexFixture.DISPLAY_ORDER, "numerical search keeps the source dex order")
  controller:dispose()
end

function T.seen_only_members_survive_permitted_filters_and_vanish_from_caught_only_filters()
  local PokedexController = requirePresent("complete search and editor behavior")
  local monCatalog, catalog = catalogs()
  local owner = enabledOwner(monCatalog, catalog)
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 }, "seen")
  observe(owner, monCatalog, { species = "TOTODILE", personality = 31 }, "caught")
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openSearch(controller)
  runSearch(controller)
  local species = resultSpecies(resultEntries(controller))
  Assert.deepEqual(species, { "CHIKORITA", "TOTODILE" }, "numerical search admits seen-only members")
  controller:dispose()
  local narrowed = newBrowser(PokedexController, owner, monCatalog, catalog)
  openSearch(narrowed)
  tick(narrowed, { { type = "activate", action = "criterion", value = "order" } })
  idle(narrowed, 5)
  tick(narrowed, { { type = "activate", action = "editor-choice", value = "heaviest" } })
  idle(narrowed, 5)
  tick(narrowed, { { type = "activate", action = "editor-ok" } })
  idle(narrowed, 5)
  runSearch(narrowed)
  Assert.deepEqual(resultSpecies(resultEntries(narrowed)), { "TOTODILE" }, "measurement orders require caught members")
  narrowed:dispose()
end

function T.type_criteria_match_either_original_type_without_slot_bias()
  local PokedexController = requirePresent("complete search and editor behavior")
  local monCatalog, catalog = catalogs()
  catalog.criteria.types = {
    dual = { "CHIKORITA", "TOTODILE", "EEVEE" },
    single = { "TOTODILE", "PICHU" },
  }
  withPublishedOptionOrder(catalog)
  local owner = enabledOwner(monCatalog, catalog)
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 31 })
  observe(owner, monCatalog, { species = "TOTODILE", personality = 31 })
  observe(owner, monCatalog, { species = "EEVEE", personality = 31 })
  observe(owner, monCatalog, { species = "PICHU", personality = 31 })
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openSearch(controller)
  tick(controller, { { type = "activate", action = "criterion", value = "type" } })
  idle(controller, 5)
  tick(controller, { { type = "activate", action = "editor-choice", value = "dual" } })
  idle(controller, 5)
  tick(controller, { { type = "activate", action = "editor-ok" } })
  idle(controller, 5)
  runSearch(controller)
  Assert.deepEqual(
    resultSpecies(resultEntries(controller)),
    { "CHIKORITA", "TOTODILE", "EEVEE" },
    "a constrained type matches either original type in dex order"
  )
  controller:dispose()
end

function T.type_editor_shifts_full_slots_and_treats_second_as_noop()
  local PokedexController = requirePresent("complete search and editor behavior")
  local monCatalog, catalog = catalogs()
  catalog.criteria.types = {
    first = { "CHIKORITA" },
    second = { "TOTODILE" },
    third = { "EEVEE" },
  }
  withPublishedOptionOrder(catalog)
  local owner = enabledOwner(monCatalog, catalog)
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 31 })
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openSearch(controller)
  tick(controller, { { type = "activate", action = "criterion", value = "type" } })
  idle(controller, 5)
  tick(controller, { { type = "activate", action = "editor-choice", value = "first" } })
  idle(controller, 5)
  tick(controller, { { type = "activate", action = "editor-choice", value = "second" } })
  idle(controller, 5)
  tick(controller, { { type = "activate", action = "editor-choice", value = "third" } })
  idle(controller, 5)
  local editor = controller:view().search.editor
  Assert.deepEqual(editor.types, { "second", "third" }, "a full editor shifts first out before placing the new type")
  tick(controller, { { type = "activate", action = "editor-choice", value = "third" } })
  idle(controller, 5)
  Assert.deepEqual(
    controller:view().search.editor.types,
    { "second", "third" },
    "selecting the already-second type is a no-op"
  )
  tick(controller, { { type = "activate", action = "editor-cancel" } })
  idle(controller, 5)
  Assert.isNil(controller:view().search.editor, "cancel leaves the type editor")
  runSearch(controller)
  Assert.deepEqual(
    resultSpecies(resultEntries(controller)),
    { "CHIKORITA" },
    "cancelled editor choices never reach the submitted criteria"
  )
  controller:dispose()
end

function T.editor_ok_retains_and_cancel_restores_the_backup()
  local PokedexController = requirePresent("complete search and editor behavior")
  local monCatalog, catalog = catalogs()
  local owner = enabledOwner(monCatalog, catalog)
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 31 })
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openSearch(controller)
  tick(controller, { { type = "activate", action = "criterion", value = "order" } })
  idle(controller, 5)
  tick(controller, { { type = "activate", action = "editor-choice", value = "tallest" } })
  idle(controller, 5)
  tick(controller, { { type = "activate", action = "editor-ok" } })
  idle(controller, 5)
  Assert.equal(controller:view().search.criteria.order, "tallest", "editor-ok retains its choice")
  tick(controller, { { type = "activate", action = "criterion", value = "order" } })
  idle(controller, 5)
  tick(controller, { { type = "activate", action = "editor-choice", value = "shortest" } })
  idle(controller, 5)
  tick(controller, { { type = "activate", action = "editor-cancel" } })
  idle(controller, 5)
  Assert.equal(controller:view().search.criteria.order, "tallest", "editor cancel restores the exact pre-entry backup")
  controller:dispose()
end

function T.unknown_area_matches_kanto_or_unknown_without_johto_before_national()
  local PokedexController = requirePresent("complete search and editor behavior")
  local monCatalog, catalog = catalogs()
  catalog.criteria.areas = { johto = { "CHIKORITA" }, kanto = { "TOTODILE" }, unknown = { "CUSTOM_IN" } }
  local owner = PokedexKnowledge.new(PokedexDexFixture.refs(monCatalog, catalog))
  owner:prepareChanges({ flags = { dexEnabled = true } }):publish()
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 31 })
  observe(owner, monCatalog, { species = "TOTODILE", personality = 31 })
  observe(owner, monCatalog, { species = "CUSTOM_IN", personality = 31 })
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openSearch(controller)
  tick(controller, { { type = "activate", action = "criterion", value = "area" } })
  idle(controller, 5)
  local editor = controller:view().search.editor
  Assert.isFalse(editor.choices.kanto.enabled, "kanto stays disabled before the national unlock")
  tick(controller, { { type = "activate", action = "editor-choice", value = "unknown" } })
  idle(controller, 5)
  tick(controller, { { type = "activate", action = "editor-ok" } })
  idle(controller, 5)
  runSearch(controller)
  Assert.deepEqual(
    resultSpecies(resultEntries(controller)),
    { "TOTODILE", "CUSTOM_IN" },
    "unknown matches kanto or unknown members without johto ones"
  )
  controller:dispose()
end

function T.slider_arrow_operations_accelerate_and_reset_on_release()
  local PokedexController = requirePresent("complete search and editor behavior")
  local monCatalog, catalog = catalogs()
  local owner = enabledOwner(monCatalog, catalog)
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 31 })
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openSearch(controller)
  tick(controller, { { type = "activate", action = "criterion", value = "height" } })
  idle(controller, 5)
  tick(controller, {
    { type = "activate", action = "slider-step", criterion = "height", endpoint = "min", direction = 1 },
  })
  idle(controller, 30)
  local first = controller:view().search.slider
  Assert.equal(first.value, 1, "the first arrow operation steps by one")
  for _ = 2, 8 do
    tick(controller, {
      { type = "activate", action = "slider-step", criterion = "height", endpoint = "min", direction = 1 },
    })
    idle(controller, 30)
  end
  local eighth = controller:view().search.slider
  Assert.equal(eighth.value - first.value, 14, "the eighth consecutive operation steps by eight")
  tick(controller, { { type = "held", left = false, right = false, touch = false } })
  idle(controller, 5)
  tick(controller, {
    { type = "activate", action = "slider-step", criterion = "height", endpoint = "min", direction = 1 },
  })
  idle(controller, 30)
  Assert.equal(
    controller:view().search.slider.value - eighth.value,
    1,
    "a genuinely released idle poll resets the acceleration"
  )
  tick(controller, { { type = "activate", action = "editor-cancel" } })
  idle(controller, 5)
  Assert.equal(
    controller:view().search.criteria.height.min,
    0,
    "cancelling the slider editor restores the full-range endpoint"
  )
  controller:dispose()
end

function T.slider_drag_may_cross_but_invalid_release_restores_its_endpoint()
  local PokedexController = requirePresent("complete search and editor behavior")
  local monCatalog, catalog = catalogs()
  local owner = enabledOwner(monCatalog, catalog)
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 31 })
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openSearch(controller)
  tick(controller, { { type = "activate", action = "criterion", value = "weight" } })
  idle(controller, 5)
  tick(controller, { { type = "drag", target = "weight-min", phase = "begin", value = 10 } })
  tick(controller, { { type = "drag", target = "weight-min", phase = "move", value = 140 } })
  Assert.equal(controller:view().search.slider.value, 140, "a drag may cross the other endpoint while held")
  tick(controller, { { type = "drag", target = "weight-min", phase = "cancel", value = 140 } })
  idle(controller, 5)
  Assert.equal(controller:view().search.slider.value, 0, "capture cancellation restores the committed endpoint")
  controller:dispose()
end

function T.simultaneous_start_wins_over_touch_and_grid_edges()
  local PokedexController = requirePresent("complete search and editor behavior")
  local monCatalog, catalog = catalogs()
  local owner = enabledOwner(monCatalog, catalog)
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 31 })
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openSearch(controller)
  tick(controller, {
    { type = "start" },
    { type = "drag", target = "cover", phase = "begin", value = 0 },
  })
  idle(controller, 250)
  Assert.equal(controller:view().page, "results", "the fresh-start shortcut runs the search ahead of touch handling")
  controller:dispose()
end

function T.fifteen_results_gain_a_return_page_and_keep_filtered_origin()
  local PokedexController = requirePresent("complete search and editor behavior")
  local monCatalog, catalog = catalogs()
  local owner = enabledOwner(monCatalog, catalog)
  for index, key in ipairs(PokedexDexFixture.DISPLAY_ORDER) do
    if index <= 15 then
      observe(owner, monCatalog, { species = key, personality = 31 })
    end
  end
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openSearch(controller)
  runSearch(controller)
  local view = controller:view()
  Assert.equal(view.page, "results", "fifteen matches complete onto the result grid")
  Assert.equal(view.grid.lastPage, 1, "fifteen matches plus the return slot need an extra page")
  local firstEntries = view.grid.buffers[1].entries
  Assert.isTrue(firstEntries[1].returnToSearch, "the global first slot returns to criteria")
  Assert.equal(firstEntries[16].species, "BURMY", "the second page starts with the fifteenth match")
  Assert.isFalse(firstEntries[16].returnToSearch, "the second page first slot is a genuine specimen")
  controller:drainEffects()
  tick(controller, { { type = "r" } })
  Assert.equal(controller:view().grid.page, 1, "page-next reaches the second results page")
  Assert.equal(controller:view().selection.species, "BURMY", "the second page cursor selects its match")
  controller:drainEffects()
  tick(controller, { { type = "menu" } })
  local effects = controller:drainEffects()
  Assert.equal(#effects, 1, "crying the second page first slot emits one effect")
  Assert.equal(effects[1].kind, "cry", "the effect is a cry request")
  Assert.equal(effects[1].species, "BURMY", "the cry names the fifteenth match")
  tick(controller, { { type = "confirm" } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "area", "confirming the second page first slot opens its entry")
  Assert.equal(controller:view().selection.species, "BURMY", "the opened entry is the fifteenth match")
  tick(controller, { { type = "cancel" } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "results", "leaving the entry restores its results origin")
  Assert.equal(controller:view().grid.page, 1, "the origin keeps its second page")
  Assert.equal(controller:view().grid.cursor, 0, "the origin keeps its first-column cursor")
  tick(controller, { { type = "l" } })
  Assert.equal(controller:view().grid.page, 0, "page-prev returns to the first results page")
  tick(controller, { { type = "confirm" } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "search", "only the global first slot restores criteria")
  controller:dispose()
end

function T.johto_search_hides_national_only_species()
  local PokedexController = requirePresent("regional search membership")
  local monCatalog, catalog = catalogs()
  local owner = PokedexKnowledge.new(PokedexDexFixture.refs(monCatalog, catalog))
  owner:prepareChanges({ flags = { dexEnabled = true } }):publish()
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 31 })
  observe(owner, monCatalog, { species = "TOTODILE", personality = 31 })
  observe(owner, monCatalog, { species = "EEVEE", personality = 31 })
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openSearch(controller)
  runSearch(controller)
  Assert.deepEqual(
    resultSpecies(resultEntries(controller)),
    { "CHIKORITA", "TOTODILE" },
    "a johto search never leaks its seen national-only species"
  )
  controller:dispose()
end

function T.slider_drag_restores_the_committed_bound_on_cancel_and_invalid_release()
  local PokedexController = requirePresent("transactional slider drags")
  local monCatalog, catalog = catalogs()
  local owner = enabledOwner(monCatalog, catalog)
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 31 })
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openSearch(controller)
  tick(controller, { { type = "activate", action = "criterion", value = "height" } })
  idle(controller, 5)
  tick(controller, { { type = "drag", target = "height-max", phase = "begin", value = 120 } })
  tick(controller, { { type = "drag", target = "height-max", phase = "end", value = 120 } })
  idle(controller, 5)
  tick(controller, { { type = "drag", target = "height-min", phase = "begin", value = 12 } })
  tick(controller, { { type = "drag", target = "height-min", phase = "end", value = 12 } })
  idle(controller, 5)
  Assert.equal(controller:view().search.criteria.height.min, 12, "a released drag commits its bound")
  tick(controller, { { type = "drag", target = "height-min", phase = "begin", value = 45 } })
  tick(controller, { { type = "drag", target = "height-min", phase = "move", value = 130 } })
  Assert.equal(controller:view().search.slider.value, 130, "a drag may cross the other endpoint while held")
  tick(controller, { { type = "drag", target = "height-min", phase = "cancel", value = 130 } })
  idle(controller, 5)
  Assert.equal(controller:view().search.slider.value, 12, "cancelling restores the committed bound, not the touch-down")
  Assert.equal(controller:view().search.criteria.height.min, 12, "cancelling never mutates the committed criteria")
  tick(controller, { { type = "drag", target = "height-min", phase = "begin", value = 45 } })
  tick(controller, { { type = "drag", target = "height-min", phase = "move", value = 130 } })
  tick(controller, { { type = "drag", target = "height-min", phase = "end", value = 130 } })
  idle(controller, 5)
  Assert.equal(
    controller:view().search.criteria.height.min,
    12,
    "an invalid crossing release restores the committed bound"
  )
  tick(controller, { { type = "drag", target = "height-min", phase = "begin", value = 45 } })
  tick(controller, { { type = "drag", target = "height-min", phase = "move", value = 60 } })
  tick(controller, { { type = "drag", target = "height-min", phase = "end", value = 60 } })
  idle(controller, 5)
  Assert.equal(controller:view().search.criteria.height.min, 60, "a legal release commits its bound")
  tick(controller, { { type = "activate", action = "editor-cancel" } })
  idle(controller, 5)
  Assert.equal(controller:view().search.criteria.height.min, 0, "cancelling the editor still rolls back both endpoints")
  controller:dispose()
end

-- The projected editor view names its kind behind one spelling: the
-- touch interface, compact rows, and role projections all read `kind`
-- while criteria transactions read `criterion`, so an editor missing
-- either spelling silently misroutes one consumer family.
function T.open_editors_project_their_kind_alongside_the_criterion()
  local PokedexController = requirePresent("editor view spelling")
  local monCatalog, catalog = catalogs()
  local owner = enabledOwner(monCatalog, catalog)
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 31 })
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openSearch(controller)
  tick(controller, { { type = "activate", action = "criterion", value = "height" } })
  idle(controller, 5)
  local editor = controller:view().search.editor
  Assert.notNil(editor, "activating a criterion opens its editor")
  Assert.equal(editor.criterion, "height", "the projected editor keeps its criterion spelling")
  Assert.equal(editor.kind, "height", "the projected editor names its kind spelling")
  tick(controller, { { type = "activate", action = "editor-cancel" } })
  idle(controller, 5)
  Assert.isNil(controller:view().search.editor, "cancel leaves the height editor")
  controller:dispose()
end

function T.editor_option_lists_follow_the_published_option_order()
  local ok, PokedexSearch = pcall(require, SEARCH_MODULE)
  Assert.isTrue(ok, "missing search criteria owner (" .. SEARCH_MODULE .. ")")
  assert(PokedexSearch ~= nil, "the search module loads")
  local monCatalog, catalog = catalogs()
  withPublishedOptionOrder(catalog)
  local owner = enabledOwner(monCatalog, catalog)
  local search = PokedexSearch.new({ catalog = catalog, dex = owner })
  Assert.deepEqual(
    PokedexSearch.CRITERIA,
    { "order", "letter", "type", "height", "weight", "area", "shape" },
    "the criteria sequence keeps the visible order"
  )
  local expectedTypes = {}
  for _, name in ipairs(PokedexSources.typeOrder) do
    expectedTypes[#expectedTypes + 1] = name
  end
  expectedTypes[#expectedTypes + 1] = "unrestricted"
  local types = search:editorOptions("type")
  Assert.deepEqual(types, expectedTypes, "the type options keep the published order with Any last")
  Assert.equal(#types, 18, "the type options stage every type plus the clearing choice")
  types[1] = "tampered"
  Assert.equal(search:editorOptions("type")[1], "normal", "the type options detach from the borrowed catalog")
  local expectedShapes = {}
  for _, name in ipairs(PokedexSources.shapeOrder) do
    expectedShapes[#expectedShapes + 1] = name
  end
  expectedShapes[#expectedShapes + 1] = "unrestricted"
  local shapes = search:editorOptions("shape")
  Assert.deepEqual(shapes, expectedShapes, "the shape options keep the published order with Any last")
  Assert.equal(#shapes, 15, "the shape options stage every shape plus the clearing choice")
  local expectedLetters = {}
  for code = string.byte("A"), string.byte("Z") do
    expectedLetters[#expectedLetters + 1] = string.char(code)
  end
  expectedLetters[#expectedLetters + 1] = "unrestricted"
  Assert.deepEqual(search:editorOptions("letter"), expectedLetters, "the letter options end with the clearing choice")
  Assert.deepEqual(
    search:editorOptions("area"),
    { "johto", "kanto", "unknown", "unrestricted" },
    "the area options keep their scope order with Any last"
  )
  search:openEditor("letter")
  search:choose("C")
  Assert.equal(search:criteria().letter, "c", "choosing a letter stages its filter")
  search:choose("unrestricted")
  Assert.isNil(search:criteria().letter, "choosing the final letter choice clears the filter")
  search:closeEditor(true)
  search:openEditor("type")
  search:choose("fighting")
  search:closeEditor(true)
  Assert.equal(search:criteria().type1, "fighting", "choosing a published type stages its filter")
  search:openEditor("type")
  search:choose("unrestricted")
  search:closeEditor(true)
  Assert.isNil(search:criteria().type1, "choosing the final type choice clears the filter")
end

return { tests = T }
