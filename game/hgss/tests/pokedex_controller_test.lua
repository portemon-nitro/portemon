-- Browser cover, sparse numbered grid, result feedback/origin, language
-- disclosure, and preparation lifecycle: the top-level browser state
-- through its public fixed-update projection. Real knowledge owner and
-- compact synthetic catalogs; only readiness/effect execution is stubbed.
-- No renderer, GPU, audio device, ROM, or worker is touched.

local Assert = require("tests.support.Assert")
local PokedexDexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")

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

local function ownerWithFlags(monCatalog, catalog, flags)
  local owner = PokedexKnowledge.new(PokedexDexFixture.refs(monCatalog, catalog))
  owner:prepareChanges({ flags = flags }):publish()
  return owner
end

---@param owner table knowledge owner under test
---@param monCatalog table resolved mon catalog
---@param fields table specimen fields
---@param kind string|nil observation kind
local function observe(owner, monCatalog, fields, kind)
  local specimen = owner:describe(PokedexDexFixture.makeMon(monCatalog, fields))
  owner:prepareChanges({ observations = { { kind = kind or "seen", specimen = specimen } } }):publish()
end

local function baseArgs(owner, monCatalog, catalog, extra)
  local args = {
    catalog = catalog,
    monCatalog = monCatalog,
    dex = owner,
    playerGender = "male",
    playerPosition = { mapX = 10, mapY = 10 },
    nativeLanguage = "english",
  }
  if extra ~= nil then
    for key, value in pairs(extra) do
      args[key] = value
    end
  end
  return args
end

---@param controller table browser under test
---@return table preparation carrying the currently demanded ready key
local function readyPrep(controller)
  return { readyKey = controller:view().key }
end

---@param controller table browser under test
---@param events table|nil semantic batch for one fixed update
---@param preparation table|nil readiness for the update
local function tick(controller, events, preparation)
  controller:updateFixed(events or {}, preparation or readyPrep(controller))
end

---@param controller table browser under test
---@param count integer fixed updates to advance with no input
local function idle(controller, count)
  for _ = 1, count do
    tick(controller, {})
  end
end

---@param controller table browser under test
---@param events table semantic batch applied with matching readiness
local function press(controller, events)
  tick(controller, events)
end

local function openGrid(controller)
  press(controller, { { type = "confirm" } })
  idle(controller, 40)
end

local AUTHOR_LENGTHS = { 110, 102, 94, 86, 78, 70, 62, 54, 46, 38, 30, 22 }

local function isAuthoredLength(length)
  for _, allowed in ipairs(AUTHOR_LENGTHS) do
    if allowed == length then
      return true
    end
  end
  return false
end

function T.cover_opens_the_sparse_grid_and_blank_slots_stay_selectable()
  local PokedexController = requirePresent("cover, sparse numbered grid, and resume")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  observe(owner, monCatalog, { species = "WORMADAM", personality = 0 })
  observe(owner, monCatalog, { species = "ROTOM", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  Assert.equal(controller:view().page, "cover", "a fresh open starts on the cover")
  openGrid(controller)
  local view = controller:view()
  Assert.equal(view.page, "grid", "cover confirm opens the regular grid")
  Assert.equal(view.mode, "national", "unset resume with national capability defaults to national")
  Assert.notNil(view.grid, "the grid projection is present")
  Assert.equal(#view.grid.buffers[1].entries, 30, "the staged buffer carries thirty semantic entries")
  local slots = view.grid.buffers[1].entries
  Assert.equal(slots[1].species, "CHIKORITA", "a seen member occupies dexNumber minus one")
  Assert.equal(slots[1].dexNumber, 1, "the first slot carries its national number")
  Assert.isFalse(slots[2].seen, "unseen holes are blank but retain their number")
  Assert.equal(slots[2].dexNumber, 2, "blank holes keep their numbers")
  Assert.equal(slots[16].species, "WORMADAM", "the sixteenth seen member sits at slot fifteen")
  Assert.equal(slots[18].species, "ROTOM", "the highest seen member sets the list length")
  Assert.equal(view.grid.lastPage, 1, "eighteen members spill onto a second page")
  press(controller, { { type = "navigate", direction = "right" } })
  view = controller:view()
  Assert.equal(view.selection.species, nil, "the cursor may rest on a trailing blank")
  Assert.isFalse(view.selection.seen, "a blank selection reports unseen")
  press(controller, { { type = "confirm" } })
  idle(controller, 10)
  Assert.equal(controller:view().page, "grid", "confirming a blank opens no entry")
  Assert.deepEqual(controller:drainEffects(), {}, "a blank confirm emits no cry or transition effect")
  controller:dispose()
end

function T.cover_direction_switches_modes_and_cover_close_exits_once()
  local PokedexController = requirePresent("cover, sparse numbered grid, and resume")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  Assert.equal(controller:view().mode, "national", "unset resume with national capability defaults to national")
  press(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(controller:view().mode, "johto", "cover right selects johto")
  press(controller, { { type = "navigate", direction = "left" } })
  Assert.equal(controller:view().mode, "national", "cover left selects national")
  press(controller, { { type = "cancel" } })
  idle(controller, 40)
  local result = controller:takeResult()
  Assert.deepEqual(result, { kind = "close" }, "cover cancel closes the application exactly once")
  Assert.isNil(controller:takeResult(), "the close result is one-use")
  controller:dispose()
end

function T.cover_drag_thresholds_complete_or_snap_back()
  local PokedexController = requirePresent("cover, sparse numbered grid, and resume")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  tick(controller, { { type = "drag", target = "cover", phase = "begin", value = 0 } })
  tick(controller, { { type = "drag", target = "cover", phase = "move", value = 40 } })
  tick(controller, { { type = "drag", target = "cover", phase = "end", value = 63 } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "cover", "releasing below 64 snaps the cover back")
  Assert.equal(controller:view().visual.coverOffset, 0, "the snapped cover rests at zero offset")
  tick(controller, { { type = "drag", target = "cover", phase = "begin", value = 0 } })
  tick(controller, { { type = "drag", target = "cover", phase = "move", value = 200 } })
  tick(controller, { { type = "drag", target = "cover", phase = "end", value = 64 } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "grid", "releasing at 64 completes the opening")
  tick(controller, { { type = "drag", target = "cover", phase = "begin", value = 256 } })
  tick(controller, { { type = "drag", target = "cover", phase = "move", value = 200 } })
  tick(controller, { { type = "drag", target = "cover", phase = "end", value = 192 } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "grid", "releasing at 192 snaps the grid back open")
  tick(controller, { { type = "drag", target = "cover", phase = "begin", value = 256 } })
  tick(controller, { { type = "drag", target = "cover", phase = "end", value = 191 } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "cover", "releasing below 192 completes the cover return")
  controller:dispose()
end

function T.grid_crossings_page_and_selected_cry_uses_first_physical_form()
  local PokedexController = requirePresent("cover, sparse numbered grid, and resume")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  observe(owner, monCatalog, { species = "WORMADAM", personality = 0 })
  observe(owner, monCatalog, { species = "ROTOM", personality = 0 })
  observe(owner, monCatalog, { species = "PICHU", personality = 0, form = 1 }, "caught")
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  press(controller, { { type = "navigate", direction = "left" } })
  Assert.equal(controller:view().grid.cursor, 14, "linear left across zero wraps to the previous page end")
  Assert.equal(controller:view().grid.page, 1, "the crossing lands on the last page")
  press(controller, { { type = "navigate", direction = "down" } })
  Assert.equal(controller:view().grid.page, 0, "vertical crossing preserves the column across pages")
  Assert.equal(controller:view().grid.cursor, 4, "the crossing lands on the pichu cursor")
  press(controller, { { type = "l" } })
  Assert.equal(controller:view().grid.page, 0, "page-prev clamps at the first page")
  Assert.equal(controller:view().grid.cursor, 4, "page-prev keeps the cursor")
  press(controller, { { type = "r" } })
  Assert.equal(controller:view().grid.page, 1, "page-next advances preserving the cursor")
  Assert.equal(controller:view().grid.cursor, 4, "page-next keeps the cursor")
  press(controller, { { type = "r" } })
  Assert.equal(controller:view().grid.page, 1, "paging clamps at the last page")
  Assert.equal(controller:view().grid.cursor, 4, "clamped page-next keeps the cursor")
  press(controller, { { type = "l" } })
  Assert.equal(controller:view().grid.page, 0, "page-prev returns to the first page")
  Assert.equal(controller:view().grid.cursor, 4, "page-prev returns to the pichu cursor")
  local scrollbar = controller:view().grid.scrollbar
  Assert.isTrue(isAuthoredLength(scrollbar.length), "the scrollbar length is one of the authored values")
  local minY = 21 + math.floor(scrollbar.length / 2)
  Assert.equal(scrollbar.position, minY, "the first page rests at the logical track top")
  for _ = 1, 2 do
    press(controller, { { type = "navigate", direction = "down" } })
    press(controller, { { type = "navigate", direction = "up" } })
  end
  for _ = 1, 2 do
    press(controller, { { type = "navigate", direction = "left" } })
    press(controller, { { type = "navigate", direction = "right" } })
  end
  local selection = controller:view().selection
  Assert.equal(selection.species, "PICHU", "the cursor reaches the caught pichu slot")
  press(controller, { { type = "menu" } })
  local effects = controller:drainEffects()
  Assert.equal(#effects, 1, "a nonblank cry request emits one effect")
  Assert.equal(effects[1].kind, "cry", "the effect is a cry request")
  Assert.equal(effects[1].species, "PICHU", "the cry names the selected species")
  Assert.equal(effects[1].form, 1, "the cry uses the first observed physical form, not the logical id")
  Assert.deepEqual(controller:drainEffects(), {}, "effects drain exactly once")
  controller:dispose()
end

function T.empty_history_stays_safe_and_resume_round_trips()
  local PokedexController = requirePresent("cover, sparse numbered grid, and resume")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  local view = controller:view()
  Assert.equal(view.page, "grid", "an empty history still opens the grid")
  Assert.equal(view.grid.lastPage, 0, "the empty list guards the page count at zero")
  Assert.isFalse(view.selection.seen, "the empty cursor is blank")
  press(controller, { { type = "confirm" } })
  idle(controller, 10)
  Assert.equal(controller:view().page, "grid", "no endpoint opens a blank entry")
  controller:dispose()
  observe(owner, monCatalog, { species = "TOTODILE", personality = 0 })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local resumed = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(resumed)
  Assert.equal(resumed:view().selection.species, "CHIKORITA", "the cursor starts on the first seen member")
  press(resumed, { { type = "navigate", direction = "right" } })
  Assert.equal(resumed:view().selection.species, "TOTODILE", "the cursor moves to the second member")
  press(resumed, { { type = "confirm" } })
  idle(resumed, 40)
  Assert.equal(resumed:view().page, "area", "confirming a nonblank selection opens its entry")
  press(resumed, { { type = "cancel" } })
  idle(resumed, 40)
  local effects = resumed:drainEffects()
  local resume = nil
  for _, effect in ipairs(effects) do
    if effect.kind == "resume" then
      resume = effect
    end
  end
  Assert.notNil(resume, "normal close emits a resume effect")
  Assert.equal(resume.species, "TOTODILE", "close captures the last eligible selection")
  Assert.equal(resume.mode, "johto", "close captures the active mode")
  resumed:dispose()
end

function T.result_feedback_runs_source_timing_and_origin_restores()
  local PokedexController = requirePresent("result feedback timing and return origin")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  for _, key in ipairs(PokedexDexFixture.DISPLAY_ORDER) do
    observe(owner, monCatalog, { species = key, personality = 0 })
    if key == "ROTOM" then
      break
    end
  end
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  press(controller, { { type = "y" } })
  Assert.equal(controller:view().page, "search", "grid Y reaches the criteria root")
  press(controller, { { type = "start" } })
  local feedback = controller:view().search
  Assert.notNil(feedback, "search start enters the feedback sequence")
  Assert.notNil(feedback.feedback, "the loading feedback is present")
  for _ = 1, 27 do
    tick(controller, {})
    Assert.notNil(controller:view().search.feedback, "the loading label holds for its full gate")
  end
  press(controller, { { type = "confirm" } })
  tick(controller, {})
  Assert.notNil(controller:view().search, "input during the wait never skips the feedback")
  idle(controller, 200)
  local view = controller:view()
  Assert.equal(view.page, "results", "the completed search lands on the result grid")
  Assert.equal(view.origin, "search", "results record their criteria origin")
  Assert.isTrue(view.grid.buffers[1].entries[1].returnToSearch, "slot zero returns to criteria")
  press(controller, { { type = "start" } })
  idle(controller, 5)
  Assert.equal(controller:view().page, "results", "start is inert on the result grid")
  press(controller, { { type = "confirm" } })
  idle(controller, 10)
  Assert.equal(controller:view().page, "search", "activating the return slot restores criteria")
  controller:dispose()
end

function T.empty_results_retract_before_accepting_fresh_edges()
  local PokedexController = requirePresent("result feedback timing and return origin")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  press(controller, { { type = "y" } })
  press(controller, {
    { type = "activate", action = "criterion", value = "letter" },
    { type = "activate", action = "editor-choice", value = "Z" },
  })
  idle(controller, 5)
  press(controller, { { type = "activate", action = "editor-ok" } })
  idle(controller, 5)
  press(controller, { { type = "start" } })
  for _ = 1, 27 do
    tick(controller, {})
    Assert.notNil(controller:view().search.feedback, "the empty search waits for the same label gate")
  end
  press(controller, { { type = "confirm" } })
  tick(controller, {})
  Assert.notNil(controller:view().search, "stale edges during the retract never skip ahead")
  idle(controller, 60)
  local effects = controller:drainEffects()
  local sounded = false
  for _, effect in ipairs(effects) do
    if effect.kind == "sound" and effect.role == "SEQ_SE_DP_CUSTOM06" then
      sounded = true
    end
  end
  Assert.isTrue(sounded, "the empty path plays its dedicated sound after the retract")
  press(controller, { { type = "confirm" } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "search", "a fresh edge after the failure returns to criteria")
  controller:dispose()
end

function T.acquired_languages_cycle_and_seen_only_hides_protected_details()
  local PokedexController = requirePresent("acquired language disclosure and caught-only details")
  local monCatalog, catalog = catalogs()
  local owner =
    ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true, enabledInternational = true })
  observe(owner, monCatalog, { species = "EEVEE", personality = 31, language = "french" }, "caught")
  observe(owner, monCatalog, { species = "EEVEE", personality = 32, language = "german" }, "caught")
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  for _ = 1, 3 do
    press(controller, { { type = "navigate", direction = "right" } })
  end
  Assert.equal(controller:view().selection.species, "EEVEE", "the cursor reaches the caught species")
  press(controller, { { type = "select" } })
  Assert.equal(controller:view().selection.language, "french", "select cycles to the first acquired language")
  press(controller, { { type = "select" } })
  Assert.equal(controller:view().selection.language, "german", "select cycles through every acquired language")
  press(controller, { { type = "select" } })
  Assert.equal(controller:view().selection.language, "english", "the cycle skips unavailable languages")
  press(controller, { { type = "confirm" } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "area", "confirming opens the caught entry")
  local pictures = controller:view().pictures
  Assert.equal(pictures[1].mode, "portrait", "a caught entry shows its portrait")
  press(controller, { { type = "cancel" } })
  idle(controller, 40)
  for _ = 1, 3 do
    press(controller, { { type = "navigate", direction = "left" } })
  end
  press(controller, { { type = "select" } })
  press(controller, { { type = "confirm" } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "area", "confirming opens the seen-only entry")
  Assert.equal(controller:view().selection.language, "english", "species change resets an invalid foreign choice")
  local seenPictures = controller:view().pictures
  Assert.equal(seenPictures[1].mode, "silhouette", "a seen-only entry hides its portrait")
  controller:dispose()
end

function T.mismatched_readiness_freezes_resource_phases_but_never_close()
  local PokedexController = requirePresent("atomic preparation and one-use lifecycle")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  local firstKey = controller:view().key
  openGrid(controller)
  local gridKey = controller:view().key
  Assert.isTrue(gridKey ~= firstKey, "a page change increments the generation key")
  local frozen = controller:view()
  tick(controller, { { type = "navigate", direction = "right" } }, { readyKey = firstKey })
  Assert.deepEqual(controller:view().selection, frozen.selection, "a stale key freezes resource-gated input")
  press(controller, { { type = "cancel" } }, { readyKey = "obsolete-generation" })
  idle(controller, 40)
  Assert.notNil(controller:takeResult(), "terminal close stays possible with an obsolete key")
  Assert.isNil(controller:takeResult(), "the terminal result is one-use")
  controller:dispose()
  controller:dispose()
end

function T.unexpected_knowledge_revision_rebuilds_without_inventing_history()
  local PokedexController = requirePresent("atomic preparation and one-use lifecycle")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  Assert.equal(controller:view().selection.species, "CHIKORITA", "the cursor starts on the seen species")
  observe(owner, monCatalog, { species = "TOTODILE", personality = 0 })
  tick(controller, {})
  local view = controller:view()
  Assert.equal(view.selection.species, "CHIKORITA", "the rebuild preserves the eligible selection")
  Assert.equal(view.counts.seen, 2, "the rebuilt counts reflect current authoritative history")
  Assert.isFalse(owner:isCaught("TOTODILE"), "the rebuild invents no caught history")
  controller:cancelPointerCapture()
  tick(controller, {})
  Assert.equal(controller:view().selection.species, "CHIKORITA", "capture cancellation keeps a coherent view")
  controller:dispose()
end

function T.johto_mode_lists_only_regional_members_with_regional_numbers()
  local PokedexController = requirePresent("regional ordering, selection, and mode switching")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  observe(owner, monCatalog, { species = "TOTODILE", personality = 0 })
  observe(owner, monCatalog, { species = "EEVEE", personality = 0 })
  observe(owner, monCatalog, { species = "CUSTOM_IN", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  Assert.equal(controller:view().mode, "johto", "unset resume without national capability defaults to johto")
  openGrid(controller)
  local view = controller:view()
  Assert.equal(view.grid.lastPage, 0, "three regional members fit on a single johto page")
  local slots = view.grid.buffers[1].entries
  Assert.equal(slots[1].species, "CHIKORITA", "the johto list starts with chikorita")
  Assert.equal(slots[1].dexNumber, 1, "chikorita carries its johto number")
  Assert.equal(slots[2].species, "TOTODILE", "the johto list continues in johto order")
  Assert.equal(slots[2].dexNumber, 2, "totodile carries its johto number")
  Assert.equal(slots[3].species, "CUSTOM_IN", "the johto list ends with its third member")
  Assert.equal(slots[3].dexNumber, 3, "the third member carries its johto number")
  for _, entry in ipairs(slots) do
    Assert.isTrue(entry.species ~= "EEVEE", "a national-only species never leaks into the johto grid")
  end
  Assert.equal(view.selection.dexNumber, 1, "the initial selection carries its johto number")
  Assert.equal(view.counts.seen, 3, "johto counts exclude national-only sightings")
  press(controller, { { type = "navigate", direction = "left" } })
  Assert.equal(controller:view().mode, "johto", "cover directions never unlock the national list")
  controller:dispose()
end

function T.mode_switch_reconciles_selection_without_touching_history()
  local PokedexController = requirePresent("regional ordering, selection, and mode switching")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  observe(owner, monCatalog, { species = "EEVEE", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  Assert.equal(controller:view().mode, "national", "an unlocked dex defaults to the national list")
  openGrid(controller)
  for _ = 1, 3 do
    press(controller, { { type = "navigate", direction = "right" } })
  end
  Assert.equal(controller:view().selection.species, "EEVEE", "the cursor reaches the national-only species")
  press(controller, { { type = "cancel" } })
  idle(controller, 40)
  Assert.notNil(controller:takeResult(), "closing the grid captures the national resume")
  local switched = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  press(switched, { { type = "navigate", direction = "right" } })
  Assert.equal(switched:view().mode, "johto", "cover right selects the johto list")
  openGrid(switched)
  local view = switched:view()
  for _, entry in ipairs(view.grid.buffers[1].entries) do
    Assert.isTrue(entry.species ~= "EEVEE", "switching to johto drops the national-only selection")
  end
  Assert.equal(view.selection.species, "CHIKORITA", "an ineligible resume falls back to the first johto member")
  Assert.equal(view.selection.dexNumber, 1, "the fallback carries its johto number")
  press(switched, { { type = "cancel" } })
  idle(switched, 40)
  local effects = switched:drainEffects()
  local resume = nil
  for _, effect in ipairs(effects) do
    if effect.kind == "resume" then
      resume = effect
    end
  end
  Assert.notNil(resume, "johto close still emits its resume")
  Assert.equal(resume.mode, "johto", "the resume records the active regional mode")
  Assert.isTrue(owner:isSeen("EEVEE"), "mode switching invents no history change")
  controller:dispose()
  switched:dispose()
end

function T.knowledge_revision_keeps_regional_cursor()
  local PokedexController = requirePresent("regional ordering, selection, and mode switching")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  observe(owner, monCatalog, { species = "CUSTOM_IN", personality = 0 })
  tick(controller, {})
  local view = controller:view()
  Assert.equal(view.selection.species, "CHIKORITA", "the rebuild preserves the eligible johto selection")
  Assert.equal(view.selection.dexNumber, 1, "the rebuilt selection keeps its johto number")
  Assert.equal(view.grid.lastPage, 0, "the rebuilt johto list still fits on one page")
  controller:dispose()
end

---@param controller table browser under test
local function reachEmptyWait(controller)
  openGrid(controller)
  press(controller, { { type = "y" } })
  press(controller, {
    { type = "activate", action = "criterion", value = "letter" },
    { type = "activate", action = "editor-choice", value = "Z" },
  })
  idle(controller, 5)
  press(controller, { { type = "activate", action = "editor-ok" } })
  idle(controller, 5)
  press(controller, { { type = "start" } })
  for _ = 1, 300 do
    local search = controller:view().search
    if search ~= nil and search.feedback ~= nil and search.feedback.phase == "wait" then
      return
    end
    tick(controller, {})
  end
  Assert.isTrue(false, "the empty search reaches its dismissible wait")
end

function T.empty_wait_answers_fresh_a_b_and_touch_but_ignores_held_and_timeout()
  local PokedexController = requirePresent("empty search dismissal and timeout")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local confirmCase = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  reachEmptyWait(confirmCase)
  press(confirmCase, { { type = "confirm" } })
  idle(confirmCase, 10)
  Assert.equal(confirmCase:view().page, "search", "a fresh A press dismisses the empty wait")
  Assert.isNil(confirmCase:view().search.feedback, "dismissal clears the feedback sequence")
  confirmCase:dispose()
  local cancelCase = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  reachEmptyWait(cancelCase)
  press(cancelCase, { { type = "cancel" } })
  idle(cancelCase, 10)
  Assert.equal(cancelCase:view().page, "search", "a fresh B press dismisses the empty wait")
  Assert.isNil(cancelCase:takeResult(), "dismissing with B never closes the application")
  cancelCase:dispose()
  local touchCase = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  reachEmptyWait(touchCase)
  press(touchCase, { { type = "drag", target = "cover", phase = "begin", value = 0 } })
  idle(touchCase, 10)
  Assert.equal(touchCase:view().page, "search", "a fresh touch dismisses the empty wait")
  touchCase:dispose()
  local heldCase = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  reachEmptyWait(heldCase)
  press(heldCase, { { type = "held", left = true, right = false, touch = false } })
  tick(heldCase, {})
  Assert.notNil(heldCase:view().search.feedback, "a held key never dismisses the empty wait")
  press(heldCase, { { type = "navigate", direction = "right" } })
  tick(heldCase, {})
  Assert.notNil(heldCase:view().search.feedback, "navigation never dismisses the empty wait")
  heldCase:dispose()
  local timeoutCase = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  reachEmptyWait(timeoutCase)
  idle(timeoutCase, 70)
  Assert.equal(timeoutCase:view().page, "search", "the untouched wait returns to criteria at its timeout")
  timeoutCase:dispose()
end

---@param controller table browser under test
---@param species string entry to open through the grid
local function openEntry(controller, species)
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
    press(controller, { { type = "navigate", direction = direction } })
  end
  press(controller, { { type = "confirm" } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "area", "the entry opens on its area page")
end

function T.entry_tabs_cycle_through_back_and_skip_missing_size()
  local PokedexController = requirePresent("four-tab entry cycling")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "EEVEE", personality = 31 }, "caught")
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  openEntry(controller, "EEVEE")
  press(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(controller:view().page, "size", "the caught entry cycles area into size")
  press(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(controller:view().page, "forms", "size cycles into forms")
  press(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(controller:view().page, "return", "forms cycles into the fourth back tab")
  press(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(controller:view().page, "area", "the fourth tab wraps back to area")
  press(controller, { { type = "navigate", direction = "left" } })
  Assert.equal(controller:view().page, "return", "reverse cycling reaches the fourth tab from area")
  press(controller, { { type = "confirm" } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "grid", "confirming back restores the originating grid")
  controller:dispose()
  local seenOnly = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(seenOnly)
  openEntry(seenOnly, "CHIKORITA")
  press(seenOnly, { { type = "navigate", direction = "right" } })
  Assert.equal(seenOnly:view().page, "forms", "a seen-only entry skips its unavailable size tab")
  press(seenOnly, { { type = "navigate", direction = "right" } })
  Assert.equal(seenOnly:view().page, "return", "cycling still reaches back without size")
  press(seenOnly, { { type = "activate", action = "return-list" } })
  idle(seenOnly, 40)
  Assert.equal(seenOnly:view().page, "grid", "the back action restores the grid by touch")
  seenOnly:dispose()
end

local TEXT_KINDS = { ui = true, species_name = true, category = true, flavor = true, height = true, weight = true, numeric = true }

---@param view table detached browser projection
local function checkTextSlots(view)
  Assert.isTrue(type(view.text) == "table", "the projection carries its semantic text slots")
  local roles = {}
  for _, slot in ipairs(view.text) do
    Assert.isTrue(type(slot.role) == "string", "every text slot names its visible window role")
    Assert.isTrue(TEXT_KINDS[slot.kind] == true, "every text slot uses the shared kind union")
    Assert.isNil(roles[slot.role], "text roles stay unique within a view")
    roles[slot.role] = true
    if slot.kind == "ui" then
      Assert.isTrue(type(slot.messageId) == "number", "interface slots reference their source message")
    elseif slot.kind == "numeric" then
      Assert.isTrue(type(slot.value) == "string" and slot.value:find("^%d+$") ~= nil, "count slots carry formatted digits")
    else
      Assert.isTrue(type(slot.species) == "string", "species slots name their specimen")
      if slot.kind == "species_name" or slot.kind == "category" or slot.kind == "flavor" then
        Assert.isTrue(type(slot.language) == "string", "entry bank slots name their language binding")
      end
    end
  end
  return roles
end

function T.browser_text_slots_reference_semantic_bank_roles()
  local PokedexController = requirePresent("semantic text slot projection")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "EEVEE", personality = 31 }, "caught")
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  local gridRoles = checkTextSlots(controller:view())
  Assert.notNil(gridRoles["grid.seen-count"], "the grid counts its seen members")
  Assert.notNil(gridRoles["grid.caught-count"], "the grid counts its caught members")
  Assert.notNil(gridRoles["grid.selected-number"], "the grid numbers its regional selection")
  Assert.notNil(gridRoles["grid.selected-name"], "the grid names its selection")
  openEntry(controller, "EEVEE")
  local entryRoles = checkTextSlots(controller:view())
  Assert.notNil(entryRoles["entry.species-name"], "the entry names its specimen")
  Assert.notNil(entryRoles["entry.dex-number"], "the entry numbers its specimen")
  Assert.notNil(entryRoles["entry.category"], "a caught entry classifies its specimen")
  Assert.notNil(entryRoles["entry.flavor"], "a caught entry describes its specimen")
  Assert.notNil(entryRoles["entry.height"], "a caught entry measures its specimen")
  Assert.notNil(entryRoles["entry.weight"], "a caught entry weighs its specimen")
  controller:dispose()
  local seenOnly = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(seenOnly)
  openEntry(seenOnly, "CHIKORITA")
  local seenRoles = checkTextSlots(seenOnly:view())
  Assert.notNil(seenRoles["entry.species-name"], "a seen-only entry still names its specimen")
  Assert.isNil(seenRoles["entry.flavor"], "a seen-only entry hides its protected description")
  seenOnly:dispose()
end

function T.area_pan_starts_settled_on_the_johto_scroll()
  local PokedexController = requirePresent("area map pan projection")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "EEVEE", personality = 31 }, "caught")
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  local cover = controller:view().areaPan
  Assert.notNil(cover, "the projection carries its area pan state")
  Assert.equal(cover.region, 0, "the pan starts on the johto region")
  Assert.equal(cover.offset, -72, "the pan starts on the settled johto scroll")
  openGrid(controller)
  openEntry(controller, "EEVEE")
  local area = controller:view().areaPan
  Assert.notNil(area, "the entry projection carries its area pan state")
  Assert.equal(area.region, 0, "the area page starts on the johto region")
  Assert.equal(area.offset, -72, "the area page starts on the settled johto scroll")
  controller:dispose()
end

function T.area_pan_travels_eight_pixels_per_frame_to_kanto()
  local PokedexController = requirePresent("area map pan projection")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "EEVEE", personality = 31 }, "caught")
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  openEntry(controller, "EEVEE")
  press(controller, { { type = "r" } })
  Assert.equal(controller:view().area.region, "kanto", "the kanto selector travels with national unlocked")
  local switched = controller:view().areaPan
  Assert.equal(switched.region, 1, "the pan follows the kanto region at once")
  Assert.equal(switched.offset, -72, "the travel starts from the johto scroll without snapping")
  press(controller, {})
  Assert.equal(controller:view().areaPan.offset, -64, "the first travel frame advances eight pixels")
  press(controller, {})
  Assert.equal(controller:view().areaPan.offset, -56, "the second travel frame advances eight more pixels")
  idle(controller, 20)
  local settled = controller:view().areaPan
  Assert.equal(settled.region, 1, "the settled pan stays on the kanto region")
  Assert.equal(settled.offset, 104, "twenty-two travel frames settle on the kanto scroll")
  idle(controller, 10)
  Assert.equal(controller:view().areaPan.offset, 104, "the settled kanto scroll holds")
  controller:dispose()
end

function T.area_pan_returns_to_johto_and_pins_without_national()
  local PokedexController = requirePresent("area map pan projection")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "EEVEE", personality = 31 }, "caught")
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  openEntry(controller, "EEVEE")
  press(controller, { { type = "r" } })
  idle(controller, 22)
  Assert.equal(controller:view().areaPan.offset, 104, "the kanto leg settles before returning")
  press(controller, { { type = "l" } })
  Assert.equal(controller:view().area.region, "johto", "the johto selector travels back")
  local switched = controller:view().areaPan
  Assert.equal(switched.region, 0, "the pan follows the johto region at once")
  Assert.equal(switched.offset, 104, "the return starts from the kanto scroll without snapping")
  press(controller, {})
  Assert.equal(controller:view().areaPan.offset, 96, "the first return frame retreats eight pixels")
  idle(controller, 21)
  Assert.equal(controller:view().areaPan.offset, -72, "twenty-two return frames settle on the johto scroll")
  controller:dispose()
  local locked = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(locked, monCatalog, { species = "CHIKORITA", personality = 0 })
  local johtoOnly = PokedexController.new(baseArgs(locked, monCatalog, catalog))
  openGrid(johtoOnly)
  openEntry(johtoOnly, "CHIKORITA")
  press(johtoOnly, { { type = "r" } })
  idle(johtoOnly, 10)
  Assert.equal(johtoOnly:view().area.region, "johto", "the kanto selector stays inert before the national unlock")
  local pinned = johtoOnly:view().areaPan
  Assert.equal(pinned.region, 0, "the johto-only pan pins the johto region")
  Assert.equal(pinned.offset, -72, "the johto-only pan pins the settled johto scroll")
  johtoOnly:dispose()
end


function T.search_keyboard_focus_traverses_criteria_and_confirms()
  local PokedexController = requirePresent("source search keyboard focus")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  observe(owner, monCatalog, { species = "TOTODILE", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  press(controller, { { type = "y" } })
  Assert.equal(controller:view().page, "search", "grid Y reaches the criteria root")
  Assert.equal(controller:view().search.focus, "order", "search focus starts on the order criterion")
  press(controller, { { type = "navigate", direction = "down" } })
  Assert.equal(controller:view().search.focus, "letter", "search focus steps to the letter criterion")
  press(controller, { { type = "confirm" } })
  local editorView = controller:view().search.editor
  Assert.notNil(editorView, "confirm opens the focused criterion editor")
  Assert.equal(editorView.criterion, "letter", "confirm opens the focused letter editor")
  local firstOption = controller:view().search.editor.focus
  press(controller, { { type = "navigate", direction = "down" } })
  Assert.isTrue(
    controller:view().search.editor.focus ~= firstOption,
    "search focus steps within the open editor options"
  )
  press(controller, { { type = "confirm" } })
  press(controller, { { type = "cancel" } })
  Assert.isNil(controller:view().search.editor, "cancelling closes the editor without running")
  Assert.equal(controller:view().page, "search", "cancelling the editor returns to criteria")
  press(controller, { { type = "start" } })
  Assert.notNil(controller:view().search.feedback, "search start enters the feedback sequence")
  controller:dispose()
end

function T.search_reset_restores_criteria_without_leaving_search()
  local PokedexController = requirePresent("search reset action")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  press(controller, { { type = "y" } })
  press(controller, {
    { type = "activate", action = "criterion", value = "letter" },
    { type = "activate", action = "editor-choice", value = "C" },
    { type = "activate", action = "editor-ok" },
  })
  idle(controller, 2)
  Assert.equal(controller:view().search.criteria.letter, "c", "the editor choice stages its criterion")
  press(controller, { { type = "activate", action = "search-reset" } })
  Assert.equal(controller:view().page, "search", "reset stays on the criteria root")
  Assert.isNil(controller:view().search.criteria.letter, "reset clears the staged letter")
  controller:dispose()
end

function T.search_editor_projects_its_option_list_for_touch_selection()
  local PokedexController = requirePresent("search editor option projection")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  press(controller, { { type = "y" } })
  press(controller, { { type = "activate", action = "criterion", value = "letter" } })
  local editor = controller:view().search.editor
  Assert.notNil(editor, "the letter editor opens")
  Assert.notNil(editor.options, "the editor projects its touch option list")
  Assert.equal(editor.options[1], "unrestricted", "the option list starts unrestricted")
  Assert.equal(editor.options[2], "A", "the option list carries the source letters")
  controller:dispose()
end

-- The search feedback text follows the native result-count template
-- (bank 802 entry 15, field 0 bound to the completed count) once the
-- run resolves, and stays unpublished while the count is unknown, so no
-- raw formatter marker ever reaches preparation.
function T.search_feedback_publishes_the_result_count_once_resolved()
  local PokedexController = requirePresent("search feedback text demand")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  observe(owner, monCatalog, { species = "TOTODILE", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  press(controller, { { type = "y" } })
  press(controller, { { type = "start" } })
  Assert.notNil(controller:view().search.feedback, "search start enters the feedback sequence")
  local function feedbackSlot(view)
    for _, slot in ipairs(view.text) do
      if type(slot) == "table" and slot.role == "search.feedback" then
        return slot
      end
    end
    return nil
  end
  Assert.isNil(feedbackSlot(controller:view()), "the label phase publishes no count it has not run")
  idle(controller, 30)
  Assert.equal(
    controller:view().search.feedback.phase,
    "rise",
    "the completed run rises with its result list"
  )
  local slot = feedbackSlot(controller:view())
  Assert.notNil(slot, "the rise phase publishes its result count")
  Assert.equal(slot.kind, "ui", "the count rides the native UI template")
  Assert.equal(slot.messageId, 15, "the count uses the native result-count entry")
  idle(controller, 200)
  local view = controller:view()
  Assert.equal(view.page, "results", "the completed search lands on the result grid")
  local results = nil
  for _, result in ipairs(view.text) do
    if type(result) == "table" and result.role == "search.results" then
      results = result
    end
  end
  Assert.notNil(results, "the results page publishes its count")
  Assert.equal(
    slot.fields ~= nil and slot.fields[0] or nil,
    string.format("%03d", tonumber(results.value)),
    "the feedback count matches the published result count"
  )
  controller:dispose()
end

-- An empty run retracts without ever publishing a count: the feedback
-- window stays absent instead of painting an unbound template.
function T.empty_search_publishes_no_feedback_count()
  local PokedexController = requirePresent("empty search feedback text demand")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  press(controller, { { type = "y" } })
  press(controller, {
    { type = "activate", action = "criterion", value = "letter" },
    { type = "activate", action = "editor-choice", value = "Z" },
  })
  idle(controller, 5)
  press(controller, { { type = "activate", action = "editor-ok" } })
  idle(controller, 5)
  press(controller, { { type = "start" } })
  for _ = 1, 90 do
    tick(controller, {})
    for _, slot in ipairs(controller:view().text) do
      Assert.isTrue(
        type(slot) ~= "table" or slot.role ~= "search.feedback",
        "no feedback phase publishes a count for zero results"
      )
    end
    if controller:view().page ~= "search" then
      break
    end
  end
  controller:dispose()
end

return { tests = T }
