-- Ordered logical variants, the forms list, comparison pairing/cycling,
-- and historyless fallback: the forms page through the public
-- fixed-update projection. Real knowledge owner and compact synthetic
-- catalogs covering every source policy family; only readiness is
-- stubbed. No renderer, GPU, audio device, ROM, or worker is touched.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local PokedexDexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
local PokedexForms = require("game.hgss.src.pokedex.PokedexForms")
local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")
local PokedexSave = require("libs.hgss.src.save.PokedexSave")

local CONTROLLER_MODULE = "game.hgss.src.pokedex.PokedexController"

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

local function enabledOwner(monCatalog, catalog)
  local owner = PokedexKnowledge.new(PokedexDexFixture.refs(monCatalog, catalog))
  owner:prepareChanges({ flags = { dexEnabled = true, nationalDex = true } }):publish()
  return owner
end

---@param owner table knowledge owner under test
---@param monCatalog table resolved mon catalog
---@param species string species to record
---@param personality integer pinned personality
---@param form integer|nil physical form
---@param kind string|nil observation kind
local function record(owner, monCatalog, species, personality, form, kind)
  local specimen = owner:describe(PokedexDexFixture.makeMon(monCatalog, {
    species = species,
    personality = personality,
    form = form or 0,
  }))
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

---@param controller table browser under test
---@param species string entry to open through the grid
local function openForms(controller, species)
  tick(controller, { { type = "drag", target = "cover", phase = "begin", value = 0 } })
  tick(controller, { { type = "drag", target = "cover", phase = "move", value = 200 } })
  tick(controller, { { type = "drag", target = "cover", phase = "end", value = 64 } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "grid", "the cover drag reaches the grid before the entry")
  local entries = controller:view().grid.buffers[1].entries
  local cursor = controller:view().grid.cursor
  local target = nil
  for index, entry in ipairs(entries) do
    if entry.species == species then
      target = index - 1
    end
  end
  assert(target ~= nil, "the fixture species is on the grid")
  local moves = target - cursor
  local direction = moves > 0 and "right" or "left"
  for _ = 1, math.abs(moves) do
    tick(controller, { { type = "navigate", direction = direction } })
  end
  tick(controller, { { type = "confirm" } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "area", "the entry opens on its area page")
  tick(controller, { { type = "activate", action = "entry-tab", value = "forms" } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "forms", "the entry tab reaches the forms page")
end

---@param controller table browser under test
---@return table forms projection snapshot
local function formsOf(controller)
  Assert.equal(controller:view().page, "forms", "the browser rests on the forms page")
  return controller:view().forms
end

local function variantForms(variants)
  local forms = {}
  for _, variant in ipairs(variants) do
    forms[#forms + 1] = variant.form
  end
  return forms
end

function T.ordinary_species_list_genders_in_arrival_order_and_genderless_lists_one()
  local PokedexController = requirePresent("ordered variants and form comparison")
  local monCatalog, catalog = catalogs()
  local owner = enabledOwner(monCatalog, catalog)
  record(owner, monCatalog, "CHIKORITA", 0, 0, "seen")
  record(owner, monCatalog, "CHIKORITA", 31, 0, "seen")
  record(owner, monCatalog, "SHEDINJA", 4294967295, 0)
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openForms(controller, "CHIKORITA")
  local variants = formsOf(controller).variants
  Assert.equal(#variants, 2, "an ordinary dimorphic species lists two variants")
  Assert.deepEqual(
    { variants[1].gender, variants[2].gender },
    { "female", "male" },
    "ordinary variants follow first-gender then first-different arrival"
  )
  Assert.deepEqual(variantForms(variants), { 0, 0 }, "identical artwork never invents a second form")
  controller:dispose()
  local genderless = newBrowser(PokedexController, owner, monCatalog, catalog)
  openForms(genderless, "SHEDINJA")
  Assert.equal(#formsOf(genderless).variants, 1, "a genderless species lists exactly one variant")
  genderless:dispose()
end

function T.unown_keeps_seen_order_and_pichu_keeps_three_logical_variants()
  local PokedexController = requirePresent("ordered variants and form comparison")
  local monCatalog, catalog = catalogs()
  local owner = enabledOwner(monCatalog, catalog)
  record(owner, monCatalog, "UNOWN", 0, 5, "seen")
  record(owner, monCatalog, "UNOWN", 0, 0, "seen")
  record(owner, monCatalog, "UNOWN", 0, 13, "seen")
  record(owner, monCatalog, "UNOWN", 0, 0, "caught")
  record(owner, monCatalog, "UNOWN", 0, 5, "caught")
  record(owner, monCatalog, "PICHU", 127, 0, "seen")
  record(owner, monCatalog, "PICHU", 0, 0, "seen")
  record(owner, monCatalog, "PICHU", 0, 1, "caught")
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openForms(controller, "UNOWN")
  Assert.deepEqual(
    variantForms(formsOf(controller).variants),
    { 5, 0, 13 },
    "unown variants follow seen arrival order, never caught order"
  )
  Assert.equal(#formsOf(controller).variants, 3, "repeat observations never duplicate unown variants")
  controller:dispose()
  local pichu = newBrowser(PokedexController, owner, monCatalog, catalog)
  openForms(pichu, "PICHU")
  local variants = formsOf(pichu).variants
  Assert.equal(#variants, 3, "pichu keeps its three logical variants")
  Assert.deepEqual(
    { variants[1].id, variants[2].id, variants[3].id },
    { 0, 1, 2 },
    "pichu logical ids arrive in observation order"
  )
  Assert.deepEqual(variantForms(variants), { 0, 0, 1 }, "pichu logical variants resolve to physical forms")
  Assert.deepEqual(
    { variants[1].gender, variants[2].gender, variants[3].gender },
    { "male", "female", "female" },
    "pichu variants never form a gender-by-form cross-product"
  )
  pichu:dispose()
end

function T.automatic_families_offer_declared_forms_once_known()
  local PokedexController = requirePresent("ordered variants and form comparison")
  local monCatalog, catalog = catalogs()
  local owner = enabledOwner(monCatalog, catalog)
  record(owner, monCatalog, "CASTFORM", 0, 2, "seen")
  record(owner, monCatalog, "CHERRIM", 0, 1)
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openForms(controller, "CASTFORM")
  Assert.deepEqual(
    variantForms(formsOf(controller).variants),
    { 0, 1, 2, 3 },
    "a known castform offers all four declared forms"
  )
  controller:dispose()
  local cherrim = newBrowser(PokedexController, owner, monCatalog, catalog)
  openForms(cherrim, "CHERRIM")
  Assert.deepEqual(variantForms(formsOf(cherrim).variants), { 0, 1 }, "a known cherrim offers both declared forms")
  cherrim:dispose()
end

function T.spinda_uses_first_personality_in_front_and_baseline_behind()
  local PokedexController = requirePresent("ordered variants and form comparison")
  local monCatalog, catalog = catalogs()
  local owner = enabledOwner(monCatalog, catalog)
  record(owner, monCatalog, "SPINDA", 12345, 0)
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openForms(controller, "SPINDA")
  Assert.equal(#formsOf(controller).variants, 1, "spinda lists a single variant")
  local pictures = controller:view().pictures
  local front, back = nil, nil
  for _, picture in ipairs(pictures) do
    if picture.facing == "front" then
      front = picture
    elseif picture.facing == "back" then
      back = picture
    end
  end
  Assert.notNil(front, "the forms page carries a front picture")
  Assert.notNil(back, "the forms page carries a back picture")
  Assert.equal(front.specimen.personality, 12345, "the front picture uses the first observed personality")
  Assert.equal(back.specimen.personality, 0, "the back picture uses the baseline personality")
  controller:dispose()
end

function T.historyless_known_species_fall_back_without_mutating_history()
  local PokedexController = requirePresent("ordered variants and form comparison")
  local monCatalog, catalog = catalogs()
  local migrated = PokedexSave.migrate({
    schema = "hgss-pokedex-v1",
    stateVersion = 1,
    seen = { "CHIKORITA", "TOTODILE" },
    caught = { "TOTODILE" },
  }, PokedexDexFixture.refs(monCatalog, catalog))
  local owner = PokedexKnowledge.restore(migrated, PokedexDexFixture.refs(monCatalog, catalog))
  Assert.isTrue(owner:isSeen("CHIKORITA"), "the migrated seen bit survives")
  Assert.deepEqual(owner:observedGenders("CHIKORITA"), {}, "the migrated species carries no invented gender")
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openForms(controller, "CHIKORITA")
  Assert.equal(#formsOf(controller).variants, 1, "the historyless fallback presents a single legal variant")
  Assert.deepEqual(owner:observedGenders("CHIKORITA"), {}, "presenting the fallback persists no invented observation")
  Assert.deepEqual(owner:bucket().history, migrated.history, "the saved history is untouched by browsing")
  controller:dispose()
end

function T.two_variant_comparison_flips_and_exits_without_cycling()
  local PokedexController = requirePresent("ordered variants and form comparison")
  local monCatalog, catalog = catalogs()
  local owner = enabledOwner(monCatalog, catalog)
  record(owner, monCatalog, "SHELLOS", 0, 0, "seen")
  record(owner, monCatalog, "SHELLOS", 0, 1, "seen")
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openForms(controller, "SHELLOS")
  Assert.equal(#formsOf(controller).variants, 2, "the fixture shellos carries two variants")
  tick(controller, { { type = "activate", action = "compare" } })
  idle(controller, 20)
  local comparison = formsOf(controller).comparison
  Assert.notNil(comparison, "compare opens the comparison with two variants")
  Assert.deepEqual(comparison.indices, { 0, 1 }, "comparison pairs the current row with the other variant")
  tick(controller, { { type = "activate", action = "compare-flip" } })
  idle(controller, 10)
  local flipped = formsOf(controller).comparison
  Assert.equal(flipped.facing, "back", "compare-flip turns both pictures")
  tick(controller, { { type = "activate", action = "compare-cycle", side = 0, delta = 1 } })
  idle(controller, 10)
  Assert.deepEqual(formsOf(controller).comparison.indices, { 0, 1 }, "cycling is inert with only two variants")
  tick(controller, { { type = "cancel" } })
  idle(controller, 10)
  Assert.isNil(controller:view().forms.comparison, "leaving comparison tears it down")
  Assert.equal(controller:view().page, "forms", "leaving comparison returns to the forms list")
  controller:dispose()
end

function T.wide_comparison_cycles_sides_while_skipping_the_other_index()
  local PokedexController = requirePresent("ordered variants and form comparison")
  local monCatalog, catalog = catalogs()
  local owner = enabledOwner(monCatalog, catalog)
  for form = 0, 5 do
    record(owner, monCatalog, "ROTOM", 0, form, "seen")
  end
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openForms(controller, "ROTOM")
  Assert.equal(#formsOf(controller).variants, 6, "the fixture rotom carries six variants")
  tick(controller, { { type = "activate", action = "compare" } })
  idle(controller, 20)
  local comparison = formsOf(controller).comparison
  Assert.deepEqual(comparison.indices, { 0, 1 }, "comparison starts from the current row outward")
  Assert.equal(comparison.activeSide, 0, "comparison starts on side zero facing front")
  tick(controller, { { type = "activate", action = "compare-cycle", side = 0, delta = 1 } })
  idle(controller, 10)
  local cycled = formsOf(controller).comparison
  Assert.equal(cycled.indices[1], 2, "cycling advances the selecting side past the other index")
  Assert.equal(cycled.indices[2], 1, "cycling never disturbs the other side")
  tick(controller, { { type = "activate", action = "compare-side", value = 1 } })
  idle(controller, 10)
  Assert.equal(formsOf(controller).comparison.activeSide, 1, "side selection switches the active side")
  local pictures = controller:view().pictures
  Assert.equal(#pictures, 2, "comparison projects exactly two picture slots")
  Assert.deepEqual({ pictures[1].slot, pictures[2].slot }, { 0, 1 }, "comparison slots run left then right")
  local variants = formsOf(controller).variants
  local indices = formsOf(controller).comparison.indices
  Assert.equal(pictures[1].specimen.form, variants[indices[1] + 1].form, "the left slot shows its selected variant")
  Assert.equal(pictures[2].specimen.form, variants[indices[2] + 1].form, "the right slot shows its selected variant")
  Assert.equal(pictures[1].facing, "front", "both slots share the selected facing")
  Assert.equal(pictures[2].facing, "front", "both slots share the selected facing")
  local keyBefore = controller:view().key
  tick(controller, { { type = "activate", action = "compare-flip" } })
  idle(controller, 10)
  local flippedPictures = controller:view().pictures
  Assert.equal(#flippedPictures, 2, "flipping keeps exactly two picture slots")
  Assert.equal(flippedPictures[1].facing, "back", "flipping turns the left slot")
  Assert.equal(flippedPictures[2].facing, "back", "flipping turns the right slot in synchrony")
  Assert.isTrue(controller:view().key ~= keyBefore, "flipping advances the picture generation")
  controller:dispose()
end

function T.two_variant_comparison_projects_one_picture_per_side()
  local PokedexController = requirePresent("ordered variants and form comparison")
  local monCatalog, catalog = catalogs()
  local owner = enabledOwner(monCatalog, catalog)
  record(owner, monCatalog, "SHELLOS", 0, 0, "seen")
  record(owner, monCatalog, "SHELLOS", 0, 1, "seen")
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openForms(controller, "SHELLOS")
  tick(controller, { { type = "activate", action = "compare" } })
  idle(controller, 20)
  local pictures = controller:view().pictures
  Assert.equal(#pictures, 2, "comparison projects one picture per selected side")
  Assert.deepEqual({ pictures[1].slot, pictures[2].slot }, { 0, 1 }, "comparison slots run left then right")
  Assert.deepEqual(
    { pictures[1].specimen.form, pictures[2].specimen.form },
    { 0, 1 },
    "comparison slots show their selected physical forms"
  )
  controller:dispose()
end

function T.forms_list_motion_rejects_short_two_row_commands()
  local PokedexController = requirePresent("ordered variants and form comparison")
  local monCatalog, catalog = catalogs()
  local owner = enabledOwner(monCatalog, catalog)
  for form = 0, 27 do
    record(owner, monCatalog, "UNOWN", 0, form, "seen")
  end
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openForms(controller, "UNOWN")
  local forms = formsOf(controller)
  Assert.equal(#forms.variants, 28, "all twenty-eight unown variants list")
  Assert.equal(forms.scrollbar.length, 22, "twenty-eight rows select the densest authored thumb")
  Assert.equal(forms.row, 0, "the forms list starts on its first row")
  tick(controller, { { type = "navigate", direction = "down" } })
  idle(controller, 10)
  Assert.equal(formsOf(controller).row, 1, "a one-row move advances one row")
  tick(controller, { { type = "navigate", direction = "up" } })
  idle(controller, 10)
  tick(controller, { { type = "navigate", direction = "up" } })
  idle(controller, 10)
  Assert.equal(formsOf(controller).row, 0, "directional moves clamp at the first row")
  local last = #formsOf(controller).variants - 1
  tick(controller, { { type = "activate", action = "forms-row", value = last } })
  idle(controller, 10)
  Assert.equal(formsOf(controller).row, last, "a touch command selects its in-range row")
  tick(controller, { { type = "activate", action = "forms-row", value = last + 2 } })
  idle(controller, 10)
  Assert.equal(formsOf(controller).row, last, "a two-row command past the end never degrades into a one-row move")
  controller:dispose()
end

function T.single_variant_species_offer_no_comparison()
  local PokedexController = requirePresent("ordered variants and form comparison")
  local monCatalog, catalog = catalogs()
  local owner = enabledOwner(monCatalog, catalog)
  record(owner, monCatalog, "SHEDINJA", 4294967295, 0)
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog)
  openForms(controller, "SHEDINJA")
  tick(controller, { { type = "activate", action = "compare" } })
  idle(controller, 10)
  Assert.isNil(controller:view().forms.comparison, "comparison needs at least two variants")
  Assert.equal(controller:view().page, "forms", "the rejected compare stays on the forms list")
  controller:dispose()
end

-- A comparison that cannot move reports no change: cycling a two-form
-- pairing or reselecting the active side leaves the indices alone and
-- answers false, and a closed comparison answers false as well.
-- Out-of-range sides and steps still fail with the structured policy error.
function T.two_form_comparison_reports_no_change_when_nothing_moves()
  local monCatalog, catalog = catalogs()
  local owner = enabledOwner(monCatalog, catalog)
  record(owner, monCatalog, "SHELLOS", 0, 0, "seen")
  record(owner, monCatalog, "SHELLOS", 0, 1, "seen")
  local forms = PokedexForms.new({ catalog = catalog, monCatalog = monCatalog, dex = owner, species = "SHELLOS" })
  Assert.equal(forms:count(), 2, "the shellos entry carries two variants")
  Assert.isTrue(forms:openComparison(), "the pair opens its comparison")
  Assert.deepEqual(forms:comparison().indices, { 0, 1 }, "the pair starts from the current row outward")
  Assert.equal(forms:comparison().activeSide, 0, "the comparison starts on side zero")
  local badSide, sideErr = pcall(function()
    forms:setActiveSide(2)
  end)
  Assert.isFalse(badSide, "an out-of-range side fails instead of selecting")
  assert(Errors.is(sideErr), "the side failure carries its structured detail")
  Assert.equal(sideErr.code, "POKEDEX_INVALID", "the side failure keeps its policy code")
  local badCycleSide, cycleSideErr = pcall(function()
    forms:cycle(2, 1)
  end)
  Assert.isFalse(badCycleSide, "cycling an out-of-range side fails instead of stepping")
  assert(Errors.is(cycleSideErr), "the cycling side failure carries its structured detail")
  Assert.equal(cycleSideErr.code, "POKEDEX_INVALID", "the cycling side failure keeps its policy code")
  local badDelta, deltaErr = pcall(function()
    forms:cycle(0, 0)
  end)
  Assert.isFalse(badDelta, "a zero step fails instead of cycling")
  assert(Errors.is(deltaErr), "the step failure carries its structured detail")
  Assert.equal(deltaErr.code, "POKEDEX_INVALID", "the step failure keeps its policy code")
  Assert.isFalse(forms:cycle(0, 1), "cycling a two-form pairing changes nothing")
  Assert.isFalse(forms:cycle(1, -1), "cycling the other two-form side changes nothing")
  Assert.deepEqual(forms:comparison().indices, { 0, 1 }, "the quiet cycles keep both indices")
  Assert.equal(forms:comparison().facing, "front", "the quiet cycles keep the facing")
  Assert.isFalse(forms:setActiveSide(0), "reselecting the active side changes nothing")
  Assert.equal(forms:comparison().activeSide, 0, "the quiet reselect keeps the active side")
  forms:closeComparison()
  Assert.isFalse(forms:cycle(0, 1), "cycling a closed comparison changes nothing")
  Assert.isFalse(forms:setActiveSide(1), "selecting into a closed comparison changes nothing")
end

-- A comparison that actually moves reports its change: stepping a wide
-- pairing past the other index or switching sides mutates the pairing
-- and answers true.
function T.wide_comparison_reports_each_real_change()
  local monCatalog, catalog = catalogs()
  local owner = enabledOwner(monCatalog, catalog)
  record(owner, monCatalog, "PICHU", 127, 0, "seen")
  record(owner, monCatalog, "PICHU", 0, 0, "seen")
  record(owner, monCatalog, "PICHU", 0, 1, "caught")
  local forms = PokedexForms.new({ catalog = catalog, monCatalog = monCatalog, dex = owner, species = "PICHU" })
  Assert.equal(forms:count(), 3, "the pichu entry carries three logical variants")
  Assert.isTrue(forms:openComparison(), "the triple opens its comparison")
  Assert.deepEqual(forms:comparison().indices, { 0, 1 }, "the comparison starts from the current row outward")
  Assert.isTrue(forms:cycle(0, 1), "stepping a wide pairing reports its change")
  Assert.deepEqual(forms:comparison().indices, { 2, 1 }, "the step advances past the other index")
  Assert.isTrue(forms:setActiveSide(1), "switching sides reports its change")
  Assert.equal(forms:comparison().activeSide, 1, "the switch moves the active side")
  Assert.isTrue(forms:cycle(1, -1), "stepping the other side reports its change")
  Assert.deepEqual(forms:comparison().indices, { 2, 0 }, "the other step advances past the first index")
end

return { tests = T }
