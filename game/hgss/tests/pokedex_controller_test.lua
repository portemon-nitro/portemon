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
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  observe(owner, monCatalog, { species = "WORMADAM", personality = 0 })
  observe(owner, monCatalog, { species = "ROTOM", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  Assert.equal(controller:view().page, "cover", "a fresh open starts on the cover")
  openGrid(controller)
  local view = controller:view()
  Assert.equal(view.page, "grid", "cover confirm opens the regular grid")
  Assert.equal(view.mode, "johto", "unset resume without national capability defaults to johto")
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
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
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
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, enabledInternational = true })
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

return { tests = T }
