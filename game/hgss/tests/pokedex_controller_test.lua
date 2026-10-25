-- Browser cover, sparse numbered grid, result feedback/origin, language
-- disclosure, and preparation lifecycle: the top-level browser state
-- through its public fixed-update projection. Real knowledge owner and
-- compact synthetic catalogs; only readiness/effect execution is stubbed.
-- No renderer, GPU, audio device, ROM, or worker is touched.

local Assert = require("tests.support.Assert")
local PokedexDexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")
local PokedexSources = require("romdump.src.config.PokedexSources")

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

-- Attaches the published editor option order to a synthetic catalog and
-- admits every ordered key, so pointer cells and keyboard steps resolve
-- the same declared option exactly like they do against generated data.
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
---@return string[] drained sound roles and music actions in drain order
local function drainSoundRoles(controller)
  local roles = {}
  for _, effect in ipairs(controller:drainEffects()) do
    if effect.kind == "sound" then
      roles[#roles + 1] = effect.role
    elseif effect.kind == "music" then
      roles[#roles + 1] = "music:" .. tostring(effect.action)
    end
  end
  return roles
end

---@param roles string[] drained sound roles and music actions
---@param role string sound role or music action under test
---@return boolean whether the role was drained
local function hasSoundRole(roles, role)
  for _, name in ipairs(roles) do
    if name == role then
      return true
    end
  end
  return false
end

---@param controller table browser under test
---@param events table semantic batch applied with matching readiness
local function press(controller, events)
  tick(controller, events)
end

local function openGrid(controller)
  -- The cover drag still opens the sparse list; cover confirm and START
  -- now slide straight into the cursor entry like the retail cover path.
  tick(controller, { { type = "drag", target = "cover", phase = "begin", value = 0 } })
  tick(controller, { { type = "drag", target = "cover", phase = "move", value = 200 } })
  tick(controller, { { type = "drag", target = "cover", phase = "end", value = 64 } })
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

function T.cover_confirm_and_start_open_the_cursor_entry_directly()
  local PokedexController = requirePresent("cover, sparse numbered grid, and resume")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  observe(owner, monCatalog, { species = "WORMADAM", personality = 0 })
  observe(owner, monCatalog, { species = "ROTOM", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  Assert.equal(controller:view().page, "cover", "a fresh open starts on the cover")
  controller:drainEffects()
  press(controller, { { type = "confirm" } })
  idle(controller, 10)
  Assert.equal(controller:view().page, "area", "cover confirm opens the cursor entry directly")
  Assert.equal(controller:view().selection.species, "CHIKORITA", "the entry names the cursor species")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_BUTTON01"),
    "cover confirm opens with the decide tone"
  )
  press(controller, { { type = "cancel" } })
  idle(controller, 40)
  local grid = controller:view()
  Assert.equal(grid.page, "grid", "cancelling the entry restores its grid origin")
  Assert.equal(#grid.grid.buffers[1].entries, 30, "the staged buffer carries thirty semantic entries")
  local slots = grid.grid.buffers[1].entries
  Assert.equal(slots[1].species, "CHIKORITA", "a seen member occupies dexNumber minus one")
  Assert.equal(slots[1].dexNumber, 1, "the first slot carries its national number")
  Assert.isFalse(slots[2].seen, "unseen holes are blank but retain their number")
  Assert.equal(slots[2].dexNumber, 2, "blank holes keep their numbers")
  Assert.equal(slots[16].species, "WORMADAM", "the sixteenth seen member sits at slot fifteen")
  Assert.equal(slots[18].species, "ROTOM", "the highest seen member sets the list length")
  Assert.equal(grid.grid.lastPage, 1, "eighteen members spill onto a second page")
  press(controller, { { type = "start" } })
  Assert.equal(controller:view().page, "cover", "start on the grid returns to the cover")
  controller:drainEffects()
  press(controller, { { type = "start" } })
  idle(controller, 10)
  Assert.equal(controller:view().page, "area", "cover START opens the cursor entry directly")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_BUTTON01"),
    "cover START opens with the decide tone"
  )
  press(controller, { { type = "cancel" } })
  idle(controller, 40)
  press(controller, { { type = "navigate", direction = "right" } })
  Assert.isFalse(controller:view().selection.seen, "the cursor may rest on a trailing blank")
  controller:drainEffects()
  press(controller, { { type = "confirm" } })
  idle(controller, 10)
  Assert.equal(controller:view().page, "grid", "confirming a blank grid slot opens no entry")
  Assert.deepEqual(controller:drainEffects(), {}, "a blank grid confirm emits no cry or transition effect")
  press(controller, { { type = "start" } })
  Assert.equal(controller:view().page, "cover", "the grid keeps its cursor under the cover")
  controller:drainEffects()
  press(controller, { { type = "confirm" } })
  idle(controller, 10)
  Assert.equal(controller:view().page, "cover", "confirming a blank cursor opens no entry")
  Assert.deepEqual(drainSoundRoles(controller), {}, "a blank cover confirm stays silent")
  press(controller, { { type = "start" } })
  idle(controller, 10)
  Assert.equal(controller:view().page, "cover", "START on a blank cursor opens no entry")
  Assert.deepEqual(drainSoundRoles(controller), {}, "a blank cover START stays silent")
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
  controller:drainEffects()
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

function T.entry_key_tabs_follow_the_retail_per_screen_map()
  local PokedexController = requirePresent("retail per-screen entry tabs")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "EEVEE", personality = 31 }, "caught")
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  openEntry(controller, "EEVEE")
  controller:drainEffects()
  press(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(controller:view().page, "size", "area right reaches size on a caught entry")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN03"),
    "the area tab key plays the cursor tone"
  )
  press(controller, { { type = "navigate", direction = "left" } })
  Assert.equal(controller:view().page, "area", "size left returns to area")
  press(controller, { { type = "navigate", direction = "left" } })
  Assert.equal(controller:view().page, "return", "area left reaches the back tab")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN03"),
    "the back tab key plays the cursor tone"
  )
  press(controller, { { type = "navigate", direction = "left" } })
  Assert.equal(controller:view().page, "forms", "back left reaches forms")
  press(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(controller:view().page, "return", "forms right reaches the back tab")
  press(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(controller:view().page, "area", "back right returns to area")
  press(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(controller:view().page, "size", "area right reaches size again")
  press(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(controller:view().page, "forms", "size right reaches forms")
  press(controller, { { type = "navigate", direction = "left" } })
  Assert.equal(controller:view().page, "size", "forms left reaches size on a caught entry")
  press(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(controller:view().page, "forms", "size right reaches forms again")
  press(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(controller:view().page, "return", "forms right reaches the back tab again")
  press(controller, { { type = "confirm" } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "grid", "confirming back restores the originating grid")
  controller:dispose()
  local seenOnly = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(seenOnly)
  openEntry(seenOnly, "CHIKORITA")
  press(seenOnly, { { type = "navigate", direction = "right" } })
  Assert.equal(seenOnly:view().page, "forms", "a seen-only entry skips its unavailable size tab")
  press(seenOnly, { { type = "navigate", direction = "left" } })
  Assert.equal(seenOnly:view().page, "area", "forms left falls back to area without size")
  press(seenOnly, { { type = "navigate", direction = "right" } })
  Assert.equal(seenOnly:view().page, "forms", "area right still skips size")
  press(seenOnly, { { type = "navigate", direction = "right" } })
  Assert.equal(seenOnly:view().page, "return", "forms right reaches back without size")
  press(seenOnly, { { type = "activate", action = "return-list" } })
  idle(seenOnly, 40)
  Assert.equal(seenOnly:view().page, "grid", "the back action restores the grid by touch")
  seenOnly:dispose()
end

local TEXT_KINDS = {
  ui = true,
  species_name = true,
  category = true,
  flavor = true,
  height = true,
  weight = true,
  numeric = true,
  area_name = true,
  named_ui = true,
  player_name = true,
}

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
      Assert.isTrue(
        type(slot.value) == "string" and slot.value:find("^%d+$") ~= nil,
        "count slots carry formatted digits"
      )
    elseif slot.kind == "area_name" then
      Assert.isTrue(type(slot.bankId) == "number", "area slots name their source bank")
      Assert.isTrue(type(slot.messageId) == "number", "area slots name their source entry")
    elseif slot.kind == "named_ui" then
      Assert.isTrue(type(slot.messageId) == "number", "named interface slots reference their source message")
      Assert.isTrue(type(slot.species) == "string", "named interface slots name their specimen")
      Assert.isTrue(type(slot.language) == "string", "named interface slots name their language binding")
    elseif slot.kind == "player_name" then
      Assert.isTrue(type(slot.value) == "string" and slot.value ~= "", "player slots carry their trainer name")
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

function T.active_slider_drag_settles_while_new_generation_is_pending()
  local PokedexController = requirePresent("slider transaction readiness exception")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  observe(owner, monCatalog, { species = "TOTODILE", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  press(controller, { { type = "y" } })
  Assert.equal(controller:view().page, "search", "grid Y reaches the search root")
  press(controller, { { type = "activate", action = "criterion", value = "height" } })
  Assert.notNil(controller:view().search.editor, "the height editor opens")
  local committed = controller:view().key
  tick(controller, { { type = "drag", target = "height-min", phase = "begin", value = 10 } })
  Assert.isTrue(controller:view().search.slider.captured, "the begin captures the drag")
  local bumped = controller:view().key
  Assert.isTrue(bumped ~= committed, "the begin advances the visual generation")
  local stale = { readyKey = committed }
  -- A mismatched endpoint never mutates the captured bound.
  tick(controller, { { type = "drag", target = "height-max", phase = "move", value = 120 } }, stale)
  Assert.equal(controller:view().search.criteria.height.min, 10, "a mismatched move keeps the captured bound")
  Assert.isTrue(controller:view().search.slider.captured, "a mismatched move keeps the drag")
  -- The captured continuation settles even though the new generation is
  -- still unready; unrelated navigation stays gated.
  tick(controller, { { type = "drag", target = "height-min", phase = "move", value = 78 } }, stale)
  Assert.equal(controller:view().search.criteria.height.min, 78, "a pending move stages the captured bound")
  local beforeNavigate = controller:view().key
  tick(controller, { { type = "navigate", direction = "down" } }, stale)
  Assert.equal(controller:view().key, beforeNavigate, "navigation stays gated while assets are pending")
  tick(controller, { { type = "drag", target = "height-min", phase = "end", value = 78 } }, stale)
  Assert.isFalse(controller:view().search.slider.captured, "a pending end clears the drag")
  Assert.equal(controller:view().search.criteria.height.min, 78, "a pending end commits the captured bound")
  Assert.equal(controller:view().search.criteria.height.max, 152, "a pending end leaves the other bound alone")
  -- Cancellation under a stale key restores the pre-drag bound.
  tick(controller, { { type = "drag", target = "height-min", phase = "begin", value = 40 } })
  local secondBump = controller:view().key
  tick(controller, { { type = "drag", target = "height-min", phase = "move", value = 100 } }, {
    readyKey = secondBump,
  })
  Assert.equal(controller:view().search.criteria.height.min, 100, "the second move stages the bound")
  tick(controller, { { type = "drag", target = "height-min", phase = "cancel" } }, { readyKey = committed })
  Assert.isFalse(controller:view().search.slider.captured, "a pending cancel clears the drag")
  Assert.equal(controller:view().search.criteria.height.min, 78, "a pending cancel restores the pre-drag bound")
  controller:dispose()
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
  -- Keyboard focus walks the visible criteria in order, then run and
  -- reset, before wrapping back to the start.
  local traversal = { "letter", "type", "height", "weight", "area", "shape", "run", "reset", "order" }
  for _, focus in ipairs(traversal) do
    press(controller, { { type = "navigate", direction = "down" } })
    Assert.equal(controller:view().search.focus, focus, "search focus steps to " .. focus)
  end
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
  Assert.equal(#editor.options, 27, "the option list stages every letter plus the clearing choice")
  Assert.equal(editor.options[1], "A", "the option list starts with the first letter")
  Assert.equal(editor.options[27], "unrestricted", "the option list ends with the clearing choice")
  controller:dispose()
end

function T.search_pointer_and_keyboard_choose_the_same_published_option()
  local PokedexController = requirePresent("search editor option parity")
  local monCatalog, catalog = catalogs()
  withPublishedOptionOrder(catalog)
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 31 }, "caught")
  observe(owner, monCatalog, { species = "TOTODILE", personality = 31 }, "caught")
  observe(owner, monCatalog, { species = "CUSTOM_IN", personality = 31 }, "caught")
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  press(controller, { { type = "y" } })
  Assert.equal(controller:view().page, "search", "grid Y reaches the criteria root")
  -- A pointer-shaped choice of the first published type stages it.
  press(controller, { { type = "activate", action = "criterion", value = "type" } })
  local editor = controller:view().search.editor
  Assert.notNil(editor, "the type editor opens")
  Assert.notNil(editor.options, "the type editor projects its option list")
  Assert.equal(#editor.options, 18, "the type editor stages every type plus the clearing choice")
  Assert.equal(editor.options[1], "normal", "the first published type opens the list")
  Assert.equal(editor.options[18], "unrestricted", "the clearing choice closes the list")
  press(controller, { { type = "activate", action = "editor-choice", value = editor.options[1] } })
  press(controller, { { type = "activate", action = "editor-ok" } })
  Assert.equal(controller:view().search.criteria.type1, "normal", "the pointer choice stages the first type")
  -- A keyboard step from that staged choice stages the next published type.
  press(controller, { { type = "activate", action = "criterion", value = "type" } })
  press(controller, { { type = "navigate", direction = "down" } })
  Assert.equal(controller:view().search.editor.focus, "fighting", "the keyboard step reaches the second published type")
  press(controller, { { type = "confirm" } })
  press(controller, { { type = "activate", action = "editor-ok" } })
  local staged = controller:view().search.criteria
  Assert.equal(staged.type1, "normal", "the pointer choice survives the keyboard staging")
  Assert.equal(staged.type2, "fighting", "the keyboard choice stages the second type")
  -- The last published shape clears its filter by pointer.
  press(controller, { { type = "activate", action = "criterion", value = "shape" } })
  local shapeEditor = controller:view().search.editor
  Assert.notNil(shapeEditor, "the shape editor opens")
  Assert.notNil(shapeEditor.options, "the shape editor projects its option list")
  Assert.equal(#shapeEditor.options, 15, "the shape editor stages every shape plus the clearing choice")
  Assert.equal(shapeEditor.options[1], "quadruped", "the first published shape opens the list")
  press(controller, { { type = "activate", action = "editor-choice", value = shapeEditor.options[15] } })
  press(controller, { { type = "activate", action = "editor-ok" } })
  Assert.isNil(controller:view().search.criteria.shape, "the last shape choice clears the filter")
  -- The search still runs through the unchanged evaluator for a staged letter.
  press(controller, { { type = "activate", action = "search-reset" } })
  press(controller, {
    { type = "activate", action = "criterion", value = "letter" },
    { type = "activate", action = "editor-choice", value = "C" },
    { type = "activate", action = "editor-ok" },
  })
  press(controller, { { type = "start" } })
  idle(controller, 250)
  Assert.equal(controller:view().page, "results", "the staged search completes onto the result grid")
  local species = {}
  for _, entry in ipairs(controller:view().grid.buffers[1].entries) do
    if entry.returnToSearch ~= true then
      species[#species + 1] = entry.species
    end
  end
  Assert.deepEqual(species, { "CHIKORITA", "CUSTOM_IN" }, "the letter search keeps its evaluator membership")
  controller:dispose()
  -- A locked scope never stages through the pointer path either.
  local lockedOwner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(lockedOwner, monCatalog, { species = "CHIKORITA", personality = 31 }, "caught")
  local locked = PokedexController.new(baseArgs(lockedOwner, monCatalog, catalog))
  openGrid(locked)
  press(locked, { { type = "y" } })
  press(locked, { { type = "activate", action = "criterion", value = "area" } })
  press(locked, { { type = "activate", action = "editor-choice", value = "kanto" } })
  Assert.isNil(locked:view().search.criteria.area, "the locked scope never stages through pointer input")
  press(locked, { { type = "activate", action = "editor-choice", value = "unknown" } })
  press(locked, { { type = "activate", action = "editor-ok" } })
  Assert.equal(locked:view().search.criteria.area, "unknown", "an unlocked scope still stages")
  locked:dispose()
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
  Assert.equal(controller:view().search.feedback.phase, "rise", "the completed run rises with its result list")
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

-- The criteria root publishes every source caption, the current staged value
-- behind each one, and the run/reset/back buttons through the native UI
-- bank, so no selectable row stays unlabeled.
function T.search_criteria_page_lists_real_captions_values_and_buttons()
  local PokedexController = requirePresent("search criteria text demand")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  press(controller, { { type = "y" } })
  Assert.equal(controller:view().page, "search", "grid Y reaches the criteria root")
  checkTextSlots(controller:view())
  local slots = {}
  for _, slot in ipairs(controller:view().text) do
    slots[slot.role] = slot
  end
  local captions = {
    ["search.caption-order"] = 26,
    ["search.caption-letter"] = 27,
    ["search.caption-type"] = 28,
    ["search.caption-height"] = 29,
    ["search.caption-weight"] = 30,
    ["search.caption-area"] = 31,
    ["search.caption-shape"] = 32,
  }
  for role, messageId in pairs(captions) do
    local slot = slots[role]
    Assert.notNil(slot, "the criteria root captions " .. role)
    Assert.equal(slot.kind, "ui", role .. " rides the native UI bank")
    Assert.equal(slot.messageId, messageId, role .. " keeps its source entry")
  end
  Assert.equal(slots["search.value-order"].messageId, 41, "the default order stages its sort label")
  Assert.equal(slots["search.value-letter"].messageId, 113, "the unset letter stages the empty mark")
  Assert.equal(slots["search.value-type-1"].messageId, 64, "the unset first type stages the empty mark")
  Assert.equal(slots["search.value-type-2"].messageId, 64, "the unset second type stages the empty mark")
  Assert.equal(slots["search.value-area"].messageId, 68, "the unset area stages the empty mark")
  Assert.equal(slots["search.value-height-min"].kind, "ui", "the height floor rides the native bank")
  Assert.equal(slots["search.value-height-min"].messageId, 175, "the height floor uses its source template")
  Assert.equal(slots["search.value-height-min"].fields[0], "0", "the height floor converts its major unit")
  Assert.equal(slots["search.value-height-min"].fields[1], "00", "the height floor converts its minor unit")
  Assert.equal(slots["search.value-height-max"].messageId, 175, "the height ceiling uses its source template")
  Assert.equal(slots["search.value-height-max"].fields[0], "99", "the height ceiling converts its major unit")
  Assert.equal(slots["search.value-height-max"].fields[1], "00", "the height ceiling converts its minor unit")
  Assert.equal(slots["search.value-weight-min"].messageId, 38, "the weight floor uses its source template")
  Assert.equal(slots["search.value-weight-min"].fields[0], "0", "the weight floor converts its major unit")
  Assert.equal(slots["search.value-weight-min"].fields[1], "0", "the weight floor converts its minor unit")
  Assert.equal(slots["search.value-weight-max"].messageId, 38, "the weight ceiling uses its source template")
  Assert.equal(slots["search.value-weight-max"].fields[0], "9999", "the weight ceiling converts its major unit")
  Assert.equal(slots["search.value-weight-max"].fields[1], "0", "the weight ceiling converts its minor unit")
  Assert.equal(slots["search.button-run"].messageId, 36, "the run button keeps its source entry")
  Assert.equal(slots["search.button-reset"].messageId, 35, "the reset button keeps its source entry")
  Assert.equal(slots["search.button-back"].messageId, 37, "the back button keeps its source entry")
  controller:dispose()
end

-- Every option editor publishes one source label per choice plus the
-- commit/cancel pair: six sorts, 27 letter marks, the catalog type set
-- with its empty mark, four scopes, and integer slider bounds. The shape
-- editor publishes its caption and buttons only; its choices are art.
function T.search_option_editors_list_their_source_choices()
  local PokedexController = requirePresent("search editor text demand")
  local monCatalog, catalog = catalogs()
  withPublishedOptionOrder(catalog)
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  press(controller, { { type = "y" } })
  local function openEditor(kind)
    press(controller, { { type = "activate", action = "criterion", value = kind } })
    Assert.equal(controller:view().search.editor.criterion, kind, "the " .. kind .. " editor opens")
    local slots = {}
    for _, slot in ipairs(controller:view().text) do
      slots[slot.role] = slot
    end
    return slots
  end
  local function closeEditor()
    press(controller, { { type = "cancel" } })
    Assert.isNil(controller:view().search.editor, "cancelling closes the editor")
  end
  local order = openEditor("order")
  Assert.equal(order["search.option-order-numerical"].messageId, 41, "the numerical sort keeps its entry")
  Assert.equal(order["search.option-order-alphabetical"].messageId, 42, "the alphabetical sort keeps its entry")
  Assert.equal(order["search.button-ok"].messageId, 39, "the order editor commits through its source entry")
  Assert.equal(order["search.button-cancel"].messageId, 40, "the order editor cancels through its source entry")
  closeEditor()
  local letter = openEditor("letter")
  Assert.equal(letter["search.option-letter-A"].messageId, 69, "the A mark keeps its source entry")
  Assert.equal(letter["search.option-letter-Z"].messageId, 94, "the Z mark keeps its source entry")
  Assert.equal(
    letter["search.option-letter-unrestricted"].messageId,
    113,
    "the letter empty mark keeps its source entry"
  )
  local letterMarks = 0
  for role in pairs(letter) do
    if role:find("^search%.option%-letter%-", 1) ~= nil then
      letterMarks = letterMarks + 1
    end
  end
  Assert.equal(letterMarks, 27, "the letter editor publishes all 27 marks")
  closeEditor()
  local kind = openEditor("type")
  Assert.equal(kind["search.option-type-normal"].messageId, 58, "the normal type keeps its source entry")
  Assert.equal(kind["search.option-type-unrestricted"].messageId, 64, "the type empty mark keeps its source entry")
  closeEditor()
  local area = openEditor("area")
  Assert.equal(area["search.option-area-johto"].messageId, 65, "the johto scope keeps its source entry")
  Assert.equal(area["search.option-area-kanto"].messageId, 66, "the kanto scope keeps its source entry")
  Assert.equal(area["search.option-area-unknown"].messageId, 67, "the unknown scope keeps its source entry")
  Assert.equal(area["search.option-area-unrestricted"].messageId, 68, "the area empty mark keeps its source entry")
  closeEditor()
  local height = openEditor("height")
  Assert.equal(height["search.current-height-min"].kind, "ui", "the height floor rides the native bank")
  Assert.equal(height["search.current-height-min"].messageId, 175, "the height floor uses its source template")
  Assert.equal(height["search.current-height-min"].fields[0], "0", "the height floor converts its major unit")
  Assert.equal(height["search.current-height-min"].fields[1], "00", "the height floor converts its minor unit")
  Assert.equal(height["search.current-height-max"].messageId, 175, "the height ceiling uses its source template")
  Assert.equal(height["search.current-height-max"].fields[0], "99", "the height ceiling converts its major unit")
  Assert.equal(height["search.button-ok"].messageId, 39, "the slider editor commits through its source entry")
  closeEditor()
  local weight = openEditor("weight")
  Assert.equal(weight["search.current-weight-min"].kind, "ui", "the weight floor rides the native bank")
  Assert.equal(weight["search.current-weight-min"].messageId, 38, "the weight floor uses its source template")
  Assert.equal(weight["search.current-weight-min"].fields[0], "0", "the weight floor converts its major unit")
  Assert.equal(weight["search.current-weight-min"].fields[1], "0", "the weight floor converts its minor unit")
  Assert.equal(weight["search.current-weight-max"].messageId, 38, "the weight ceiling uses its source template")
  Assert.equal(weight["search.current-weight-max"].fields[0], "9999", "the weight ceiling converts its major unit")
  closeEditor()
  local shape = openEditor("shape")
  Assert.notNil(shape["search.title-shape"], "the shape editor keeps its caption")
  Assert.notNil(shape["search.button-ok"], "the shape editor keeps its commit button")
  local shapeOptions = 0
  for role in pairs(shape) do
    if role:find("^search%.option%-shape%-", 1) ~= nil then
      shapeOptions = shapeOptions + 1
    end
  end
  Assert.equal(shapeOptions, 0, "the shape editor publishes no invented option labels")
  closeEditor()
  controller:dispose()
end

-- START inside an editor commits it like its OK button: the staged
-- choice persists, the editor closes, and no search runs.
function T.editor_start_commits_without_running_the_search()
  local PokedexController = requirePresent("editor START commit")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  press(controller, { { type = "y" } })
  press(controller, { { type = "activate", action = "criterion", value = "letter" } })
  press(controller, { { type = "activate", action = "editor-choice", value = "C" } })
  controller:drainEffects()
  press(controller, { { type = "start" } })
  Assert.isNil(controller:view().search.editor, "editor START closes the editor")
  Assert.equal(controller:view().search.criteria.letter, "c", "editor START keeps the staged choice")
  Assert.isNil(controller:view().search.feedback, "editor START runs no search")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "editor START commits with the touch tone"
  )
  controller:dispose()
end

-- The results page renames the highlighted seen species exactly like the
-- grid does; the leading return slot clears the selection and publishes
-- neither number nor name.
function T.results_page_keeps_the_highlighted_identity_and_hides_the_return_slot()
  local PokedexController = requirePresent("results identity text demand")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  observe(owner, monCatalog, { species = "TOTODILE", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  press(controller, { { type = "y" } })
  press(controller, { { type = "start" } })
  idle(controller, 200)
  Assert.equal(controller:view().page, "results", "the completed search lands on the result grid")
  -- Landing highlights the leading return slot, so step onto the first
  -- result before asserting its identity; the committed return-slot
  -- landing behavior stands.
  press(controller, { { type = "navigate", direction = "right" } })
  local function roles()
    local found = {}
    for _, slot in ipairs(controller:view().text) do
      found[slot.role] = slot
    end
    return found
  end
  local highlighted = roles()
  Assert.notNil(highlighted["search.results"], "the results page publishes its count")
  Assert.notNil(highlighted["grid.selected-name"], "the highlighted result keeps its name")
  Assert.notNil(highlighted["grid.selected-number"], "the highlighted result keeps its number")
  for _ = 1, 35 do
    if controller:view().selection.species == nil then
      break
    end
    press(controller, { { type = "navigate", direction = "left" } })
  end
  Assert.isNil(controller:view().selection.species, "the walk ends on the leading return slot")
  local cleared = roles()
  Assert.isNil(cleared["grid.selected-name"], "the return slot names no species")
  Assert.isNil(cleared["grid.selected-number"], "the return slot numbers no species")
  controller:dispose()
end

-- The area page reports its daypart and viewed region through the native
-- UI bank; the return tab names its cancel and return-to-list actions.
function T.entry_area_reports_its_daypart_region_and_return_actions()
  local PokedexController = requirePresent("area and return text demand")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "EEVEE", personality = 31 }, "caught")
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  openEntry(controller, "EEVEE")
  local area = {}
  for _, slot in ipairs(controller:view().text) do
    area[slot.role] = slot
  end
  Assert.notNil(area["area.time"], "the area page reports its daypart")
  Assert.equal(area["area.time"].kind, "ui", "the daypart rides the native UI bank")
  Assert.equal(area["area.time"].messageId, 129, "the fresh entry opens on the morning mark")
  Assert.isNil(area["area.location"], "the fresh entry leaves the first row window blank like the source")
  press(controller, { { type = "navigate", direction = "down" } })
  local scrolled = {}
  for _, slot in ipairs(controller:view().text) do
    scrolled[slot.role] = slot
  end
  Assert.equal(scrolled["area.location"].messageId, 134, "the scrolled region row keeps its source entry")
  press(controller, { { type = "activate", action = "area-time", value = 2 } })
  local night = {}
  for _, slot in ipairs(controller:view().text) do
    night[slot.role] = slot
  end
  Assert.equal(night["area.time"].messageId, 131, "the night selector moves to the night mark")
  press(controller, { { type = "navigate", direction = "right" } })
  press(controller, { { type = "navigate", direction = "right" } })
  press(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(controller:view().page, "return", "cycling reaches the back tab")
  local back = {}
  for _, slot in ipairs(controller:view().text) do
    back[slot.role] = slot
  end
  Assert.equal(back["return.title"].messageId, 173, "the back tab keeps its cancel entry")
  Assert.equal(back["return.action"].messageId, 174, "the back tab keeps its return-to-list entry")
  controller:dispose()
end

-- The forms page reports its title, species header, selected form name
-- and visible rows through the species-specific form-name policy, and
-- the comparison pairs both sides with their source labels.
function T.entry_forms_reports_selected_rows_and_comparison_names()
  local PokedexController = requirePresent("forms text demand")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  local function recordForm(species, personality, form, kind)
    local specimen = owner:describe(PokedexDexFixture.makeMon(monCatalog, {
      species = species,
      personality = personality,
      form = form,
    }))
    owner:prepareChanges({ observations = { { kind = kind, specimen = specimen } } }):publish()
  end
  recordForm("PICHU", 127, 0, "seen")
  recordForm("PICHU", 0, 0, "seen")
  recordForm("PICHU", 0, 1, "caught")
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  openEntry(controller, "PICHU")
  press(controller, { { type = "activate", action = "entry-tab", value = "forms" } })
  Assert.equal(controller:view().page, "forms", "the entry tab reaches the forms page")
  local function roles()
    checkTextSlots(controller:view())
    local found = {}
    for _, slot in ipairs(controller:view().text) do
      found[slot.role] = slot
    end
    return found
  end
  local resting = roles()
  Assert.equal(resting["forms.title"].messageId, 170, "the forms page keeps its title")
  Assert.equal(resting["forms.header"].kind, "named_ui", "the species header names its specimen")
  Assert.equal(resting["forms.selected"].messageId, 114, "the first variant names the spiky-eared mark")
  Assert.equal(resting["forms.caption"].messageId, 168, "the multi-form list keeps its caption")
  Assert.isNil(resting["forms.row-1"], "the window above the first variant stays blank")
  Assert.equal(resting["forms.row-2"].messageId, 114, "the first window names the first variant")
  Assert.equal(resting["forms.row-3"].messageId, 114, "the second window names the second variant")
  Assert.equal(resting["forms.row-4"].messageId, 115, "the next row names the other form")
  Assert.isNil(resting["forms.row-5"], "rows past the last variant stay blank")
  Assert.isNil(resting["forms.row-6"], "rows past the last variant stay blank")
  press(controller, { { type = "navigate", direction = "down" } })
  press(controller, { { type = "navigate", direction = "down" } })
  local moved = roles()
  Assert.equal(moved["forms.selected"].messageId, 115, "the moved cursor names the other form")
  Assert.equal(moved["forms.row-1"].messageId, 114, "the scrolled top window names the second variant")
  Assert.equal(moved["forms.row-2"].messageId, 115, "the centered row follows the cursor")
  Assert.isNil(moved["forms.row-3"], "windows past the last variant stay blank")
  press(controller, { { type = "activate", action = "compare" } })
  local compared = roles()
  Assert.equal(compared["forms.compare-caption"].messageId, 170, "the comparison keeps its title")
  Assert.equal(compared["forms.compare-label-left"].messageId, 171, "the comparison labels its left side")
  Assert.equal(compared["forms.compare-label-right"].messageId, 172, "the comparison labels its right side")
  Assert.equal(compared["forms.compare-left"].messageId, 115, "the comparison names the selected variant")
  Assert.equal(compared["forms.compare-right"].messageId, 114, "the comparison names the other variant")
  controller:dispose()
end

-- The size page reports its title, species and trainer names plus the
-- gendered measurement rows; without a trainer name the player slot is
-- omitted rather than invented.
function T.entry_size_reports_trainer_backed_measurements()
  local PokedexController = requirePresent("size text demand")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "EEVEE", personality = 31 }, "caught")
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog, { playerName = "GOLD" }))
  openGrid(controller)
  openEntry(controller, "EEVEE")
  press(controller, { { type = "activate", action = "entry-tab", value = "size" } })
  Assert.equal(controller:view().page, "size", "the entry tab reaches the size page")
  checkTextSlots(controller:view())
  local sized = {}
  for _, slot in ipairs(controller:view().text) do
    sized[slot.role] = slot
  end
  Assert.equal(sized["size.title"].messageId, 143, "the size page keeps its title")
  Assert.equal(sized["size.species-name"].species, "EEVEE", "the size page names its specimen")
  Assert.equal(sized["size.player-name"].value, "GOLD", "the size page names its trainer")
  Assert.equal(sized["size.caption-height"].messageId, 136, "the height pane keeps its caption")
  Assert.equal(sized["size.gender-height"].messageId, 138, "the male profile keeps its height word")
  Assert.equal(sized["size.caption-weight"].messageId, 137, "the weight pane keeps its caption")
  Assert.equal(sized["size.gender-weight"].messageId, 140, "the male profile keeps its weight word")
  Assert.notNil(sized["size.species-weight"], "the size page weighs its specimen in its own window")
  controller:dispose()
  local unnamed = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(unnamed)
  openEntry(unnamed, "EEVEE")
  press(unnamed, { { type = "activate", action = "entry-tab", value = "size" } })
  checkTextSlots(unnamed:view())
  local anonymous = {}
  for _, slot in ipairs(unnamed:view().text) do
    anonymous[slot.role] = slot
  end
  Assert.isNil(anonymous["size.player-name"], "a missing trainer name publishes no player slot")
  Assert.notNil(anonymous["size.title"], "the size page still titles without a trainer name")
  unnamed:dispose()
end

-- The selected species carries one bounded bank-backed detail family for
-- the adapted inspector: number and name for seen-only highlights, plus
-- category, flavor, height, and weight for caught ones. Unseen slots
-- publish no detail at all.
function T.grid_selection_carries_compact_detail_strings_for_caught_species()
  local PokedexController = requirePresent("selected detail text demand")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "EEVEE", personality = 31 }, "caught")
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  local details = {}
  for _, slot in ipairs(controller:view().text) do
    details[slot.role] = slot
  end
  Assert.notNil(details["compact.detail-number"], "the selection numbers its detail")
  Assert.notNil(details["compact.detail-name"], "the selection names its detail")
  controller:dispose()
  local caughtOnly = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(caughtOnly)
  for _ = 1, 35 do
    if caughtOnly:view().selection.species == "EEVEE" then
      break
    end
    press(caughtOnly, { { type = "navigate", direction = "right" } })
  end
  Assert.equal(caughtOnly:view().selection.species, "EEVEE", "the cursor reaches the caught species")
  local caught = {}
  for _, slot in ipairs(caughtOnly:view().text) do
    caught[slot.role] = slot
  end
  Assert.notNil(caught["compact.detail-category"], "a caught selection classifies its detail")
  Assert.notNil(caught["compact.detail-flavor"], "a caught selection describes its detail")
  Assert.notNil(caught["compact.detail-height"], "a caught selection measures its detail")
  Assert.notNil(caught["compact.detail-weight"], "a caught selection weighs its detail")
  caughtOnly:dispose()
  local seenOnly = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(seenOnly)
  local seen = {}
  for _, slot in ipairs(seenOnly:view().text) do
    seen[slot.role] = slot
  end
  Assert.notNil(seen["compact.detail-name"], "a seen-only selection still names its detail")
  Assert.isNil(seen["compact.detail-flavor"], "a seen-only selection hides its protected description")
  seenOnly:dispose()
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

---@param objects table[] detached sprite intents under test
---@param subject string intent subject under test
---@return table? the first intent naming the subject
local function findObject(objects, subject)
  Assert.isTrue(type(objects) == "table", "the projection carries its sprite intents")
  for _, intent in ipairs(objects) do
    if type(intent) == "table" and intent.subject == subject then
      return intent
    end
  end
  return nil
end

---@param intent table sprite intent under test
local function checkIntentShape(intent)
  Assert.isTrue(type(intent.subject) == "string" and intent.subject ~= "", "intents name their subject")
  Assert.isTrue(type(intent.choice) == "string" and intent.choice ~= "", "intents name their choice")
  Assert.isTrue(intent.pane == "controls" or intent.pane == "information", "intents name their pane")
  Assert.isTrue(type(intent.x) == "number" and intent.x % 1 == 0, "intents carry integer x")
  Assert.isTrue(type(intent.y) == "number" and intent.y % 1 == 0, "intents carry integer y")
  Assert.isTrue(type(intent.age) == "number" and intent.age % 1 == 0 and intent.age >= 0, "intents carry their age")
end

-- The grid cursor tracks the selected slot while the arrows and the
-- thumb follow the page: the focus sits at the native slot origin, the
-- up arrow dims on the first page, the thumb bucket and y follow the
-- sparse length, and repeated projections without accepted steps move
-- nothing while the demand key stays quiet across pure animation ticks.
function T.grid_cursor_arrows_and_scrollbar_follow_selection_and_pages()
  local PokedexController = requirePresent("grid sprite intents")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  observe(owner, monCatalog, { species = "EEVEE", personality = 31 }, "caught")
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  local key = controller:view().key
  local view = controller:view()
  Assert.equal(view.selection.species, "CHIKORITA", "the cursor starts on the first slot")
  Assert.isNil(findObject(view.objects, "type-1"), "no art projects before the cursor moves")
  local cursor = assert(findObject(view.objects, "cursor"), "the grid projects its focus")
  checkIntentShape(cursor)
  Assert.equal(cursor.pane, "controls", "the focus paints on the touch pane")
  Assert.equal(cursor.x, 48 + 40 * (view.grid.cursor % 5), "the focus tracks its column")
  Assert.equal(cursor.y, 24 + 40 * math.floor(view.grid.cursor / 5), "the focus tracks its row")
  local up = assert(findObject(view.objects, "arrow-up"), "the grid projects its up arrow")
  Assert.equal(up.choice, "disabled", "the up arrow dims on the first page")
  Assert.equal(up.x, 242, "the up arrow keeps its native column")
  Assert.equal(up.y, 12, "the up arrow keeps its native row")
  local down = assert(findObject(view.objects, "arrow-down"), "the grid projects its down arrow")
  Assert.equal(down.choice, "disabled", "a single page dims the down arrow too")
  local thumb = assert(findObject(view.objects, "scrollbar"), "the grid projects its thumb")
  Assert.equal(thumb.x, 242, "the thumb keeps its native column")
  Assert.equal(thumb.y, view.grid.scrollbar.position, "the thumb y follows the scrolled page")
  local firstAge = cursor.age
  view = controller:view()
  local again = assert(findObject(view.objects, "cursor"), "repeated projections keep the focus")
  Assert.equal(again.age, firstAge, "no accepted step advances no intent age")
  Assert.equal(again.x, cursor.x, "no accepted step moves no intent")
  Assert.equal(controller:view().key, key, "projections never bump the demand key")
  idle(controller, 3)
  Assert.equal(controller:view().key, key, "pure animation ticks keep the demand key quiet")
  view = controller:view()
  local ticked = assert(findObject(view.objects, "cursor"), "animation ticks keep the focus")
  Assert.isTrue(ticked.age > firstAge, "accepted ticks age the installed choice")
  press(controller, { { type = "navigate", direction = "right" } })
  view = controller:view()
  local moved = assert(findObject(view.objects, "cursor"), "navigation keeps a focus")
  Assert.equal(moved.age, 0, "moving the cursor restarts its age")
  Assert.equal(moved.x, 48 + 40 * (view.grid.cursor % 5), "the moved focus tracks its column")
  controller:dispose()
end

-- The caught selection shows its type art and footprint while a
-- seen-only selection hides every protected sprite: the type choices
-- name the catalog types, the footprint names the species, and the
-- caught mark follows the caught flag.
function T.caught_selection_shows_type_and_footprint_art()
  local PokedexController = requirePresent("selection sprite intents")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "EEVEE", personality = 31 }, "caught")
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  for _ = 1, 8 do
    if controller:view().selection.species == "EEVEE" then
      break
    end
    press(controller, { { type = "navigate", direction = "right" } })
  end
  local view = controller:view()
  Assert.equal(view.selection.species, "EEVEE", "the cursor reaches the caught selection")
  local first = assert(findObject(view.objects, "type-1"), "the caught selection projects its first type")
  checkIntentShape(first)
  Assert.equal(first.choice, "normal", "the first type names the catalog type")
  Assert.equal(first.x, 168, "the first type keeps its native column")
  Assert.equal(first.y, 72, "the first type keeps its native row")
  Assert.isNil(findObject(view.objects, "type-2"), "a single-type selection projects no second type")
  local foot = assert(findObject(view.objects, "footprint"), "the caught selection projects its footprint")
  Assert.equal(foot.choice, "EEVEE", "the footprint names the selected species")
  Assert.equal(foot.x, 120, "the footprint keeps its native column")
  Assert.equal(foot.y, 80, "the footprint keeps its native row")
  local mark = assert(findObject(view.objects, "caught-mark"), "the caught selection projects its mark")
  Assert.equal(mark.x, 112, "the caught mark keeps its native column")
  Assert.equal(mark.y, 32, "the caught mark keeps its native row")
  for _ = 1, 40 do
    if controller:view().selection.species == "CHIKORITA" then
      break
    end
    press(controller, { { type = "navigate", direction = "right" } })
  end
  view = controller:view()
  Assert.equal(view.selection.species, "CHIKORITA", "the cursor reaches the seen-only selection")
  Assert.isNil(findObject(view.objects, "type-1"), "a seen-only selection hides its types")
  Assert.isNil(findObject(view.objects, "footprint"), "a seen-only selection hides its footprint")
  Assert.isNil(findObject(view.objects, "caught-mark"), "a seen-only selection hides its mark")
  controller:dispose()
end

-- The entry tab cursor names the active tab: area, size, forms and the
-- back panel each carry the cursor at the native tab origin while the
-- demand key stays quiet on pure time steps.
function T.entry_tab_cursor_tracks_the_active_tab()
  local PokedexController = requirePresent("entry sprite intents")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "EEVEE", personality = 31 }, "caught")
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  for _ = 1, 40 do
    if controller:view().selection.species == "EEVEE" then
      break
    end
    press(controller, { { type = "navigate", direction = "right" } })
  end
  press(controller, { { type = "confirm" } })
  idle(controller, 40)
  local pages = { area = 0, size = 1, forms = 2, ["return"] = 3 }
  for _, page in ipairs({ "area", "size", "forms", "return" }) do
    local view = controller:view()
    Assert.equal(view.page, page, "the entry sits on " .. page)
    local tab = assert(findObject(view.objects, "tab-cursor"), page .. " projects its tab cursor")
    checkIntentShape(tab)
    Assert.equal(tab.pane, "controls", "the tab cursor paints on the touch pane")
    Assert.equal(tab.x, 32 + 64 * pages[page], "the " .. page .. " tab keeps its native column")
    Assert.equal(tab.y, 176, "the tab cursor keeps its native row")
    press(controller, { { type = "navigate", direction = "right" } })
    idle(controller, 2)
  end
  controller:dispose()
end

-- The area page projects its player, time cursor and habitat markers:
-- the player follows the captured cell with the regional shift, the
-- time cursor rides its daypart row, and every visible row marker
-- arrives as a separate instance at the native map position.
function T.area_subjects_project_player_time_and_markers()
  local PokedexController = requirePresent("area sprite intents")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "EEVEE", personality = 7 }, "caught")
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  for _ = 1, 8 do
    if controller:view().selection.species == "EEVEE" then
      break
    end
    press(controller, { { type = "navigate", direction = "right" } })
  end
  press(controller, { { type = "confirm" } })
  idle(controller, 40)
  local view = controller:view()
  Assert.equal(view.page, "area", "confirming a caught entry opens its area")
  local player = assert(findObject(view.objects, "player"), "the area projects its player marker")
  checkIntentShape(player)
  Assert.equal(player.pane, "information", "the player paints on the upper pane")
  Assert.equal(player.x, view.area.player.x * 8 + 68, "the player tracks the captured column")
  Assert.equal(player.y, view.area.player.y * 8 + 44, "the player tracks the captured row")
  local time = assert(findObject(view.objects, "time-cursor"), "the area projects its time cursor")
  Assert.equal(time.x, 32, "the time cursor keeps its native column")
  Assert.equal(time.y, 76 + 32 * view.area.time, "the time cursor rides its daypart row")
  local markers = {}
  for _, intent in ipairs(assert(view.objects, "the area carries its intents")) do
    if intent.subject == "marker" then
      checkIntentShape(intent)
      markers[#markers + 1] = intent
    end
  end
  Assert.isTrue(#markers >= 1, "the area projects its visible habitat markers")
  local instances = {}
  for _, marker in ipairs(markers) do
    Assert.isTrue(type(marker.instance) == "number", "repeated markers carry their instance")
    Assert.isNil(instances[marker.instance], "marker instances stay distinct")
    instances[marker.instance] = true
  end
  local scroll = assert(findObject(view.objects, "scrollbar"), "the area projects its scrollbar")
  Assert.equal(scroll.x, 242, "the area thumb keeps its native column")
  controller:dispose()
end

-- The size page projects its pans, beam and trainer: both pans ride
-- the published beam positions, the beam anchors stay fixed, and the
-- trainer names the captured gender while motion advances the figures.
function T.size_subjects_follow_figures_and_pans()
  local PokedexController = requirePresent("size sprite intents")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "EEVEE", personality = 31 }, "caught")
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  for _ = 1, 40 do
    if controller:view().selection.species == "EEVEE" then
      break
    end
    press(controller, { { type = "navigate", direction = "right" } })
  end
  press(controller, { { type = "confirm" } })
  idle(controller, 40)
  press(controller, { { type = "navigate", direction = "right" } })
  idle(controller, 40)
  local view = controller:view()
  Assert.equal(view.page, "size", "the caught entry reaches its size")
  local left = assert(findObject(view.objects, "pan-left"), "the size projects its left pan")
  checkIntentShape(left)
  Assert.equal(left.pane, "controls", "the pans paint on the touch pane")
  Assert.equal(left.x, view.size.pans[1].x, "the left pan tracks the published beam")
  local right = assert(findObject(view.objects, "pan-right"), "the size projects its right pan")
  Assert.equal(right.x, view.size.pans[2].x, "the right pan tracks the published beam")
  local trainer = assert(findObject(view.objects, "trainer"), "the size projects its trainer")
  Assert.equal(trainer.choice, "male", "the trainer names the captured gender")
  local figures = assert(view.size.figures, "the size projects its figures")
  local y0 = assert(figures[1], "the size projects its mon figure").y
  idle(controller, 25)
  local dropped = controller:view()
  local y1 = assert(assert(dropped.size.figures, "the figures persist")[1], "the mon figure persists").y
  Assert.isTrue(y1 > y0, "accepted ticks drop the published figures")
  controller:dispose()
end

-- The forms page projects its scrollbar and arrows while the compare
-- screen swaps in its frame and side selector: the selector follows
-- the published active side and the frame appears only in compare.
function T.forms_subjects_follow_row_and_comparison()
  local PokedexController = requirePresent("forms sprite intents")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "UNOWN", personality = 0 }, "caught")
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  for _ = 1, 60 do
    if controller:view().selection.species == "UNOWN" then
      break
    end
    press(controller, { { type = "navigate", direction = "right" } })
  end
  press(controller, { { type = "confirm" } })
  idle(controller, 40)
  press(controller, { { type = "navigate", direction = "right" } })
  idle(controller, 5)
  press(controller, { { type = "navigate", direction = "right" } })
  idle(controller, 40)
  local view = controller:view()
  Assert.equal(view.page, "forms", "the entry reaches its forms")
  local scroll = assert(findObject(view.objects, "scrollbar"), "the forms project their scrollbar")
  Assert.equal(scroll.y, view.forms.scrollbar.position, "the thumb y follows the row")
  Assert.isNil(findObject(view.objects, "compare-side"), "the list hides the compare selector")
  controller:dispose()
end

-- The height editor projects both slider handles with their digits and
-- limits: the handles ride the published bounds, the digits spell the
-- converted values, and the limit arrows reflect the slider ends.
function T.search_slider_subjects_follow_both_handles_and_digits()
  local PokedexController = requirePresent("slider sprite intents")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  press(controller, { { type = "y" } })
  press(controller, { { type = "activate", action = "criterion", value = "height" } })
  local view = controller:view()
  Assert.notNil(view.search.editor, "the height editor opens")
  local maxHandle = assert(findObject(view.objects, "slider-max"), "the editor projects its max handle")
  checkIntentShape(maxHandle)
  Assert.equal(maxHandle.choice, "height", "the max handle names its editor")
  Assert.equal(maxHandle.x, 52 + view.search.criteria.height.max, "the max handle rides its published bound")
  local minHandle = assert(findObject(view.objects, "slider-min"), "the editor projects its min handle")
  Assert.equal(minHandle.x, 52 + view.search.criteria.height.min, "the min handle rides its bound")
  local digits = {}
  for _, intent in ipairs(assert(view.objects, "the editor carries its intents")) do
    if intent.subject == "digit-max-1" then
      digits[#digits + 1] = intent
    end
  end
  Assert.isTrue(#digits >= 1, "the max handle spells its value in digits")
  local cursor = assert(findObject(view.objects, "slider-cursor"), "the editor projects its cursor")
  Assert.equal(cursor.x, maxHandle.x, "the cursor follows the max handle")
  controller:dispose()
end

-- The search feedback projects its phased subjects: the label art
-- shows while the gate holds, the rise follows, and the intents carry
-- their accepted phase age instead of wall-clock time.
function T.search_feedback_projects_phased_subjects()
  local PokedexController = requirePresent("feedback sprite intents")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  for _, key in ipairs({ "CHIKORITA", "TOTODILE" }) do
    observe(owner, monCatalog, { species = key, personality = 0 })
  end
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  press(controller, { { type = "y" } })
  press(controller, { { type = "start" } })
  local view = controller:view()
  Assert.notNil(view.search.feedback, "search start enters the feedback sequence")
  local label = assert(findObject(view.objects, "feedback"), "the feedback projects its art")
  checkIntentShape(label)
  Assert.equal(label.choice, "label", "the gate phase shows the label art")
  Assert.equal(label.x, 128, "the feedback keeps its native column")
  Assert.equal(label.y, 80, "the feedback keeps its native row")
  Assert.equal(label.pane, "information", "the feedback paints on the upper pane")
  idle(controller, 30)
  view = controller:view()
  local rise = assert(findObject(view.objects, "feedback"), "the rise phase keeps its art")
  Assert.equal(rise.choice, "rise", "the rise phase shows the rise art")
  Assert.isTrue(rise.age < label.age + 40, "the phase change restarts the intent age")
  controller:dispose()
end

-- A staged body shape shows its icon only where the source shows it:
-- the criteria root and the shape editor carry the icon at their
-- native origins while every other option editor hides it, and the
-- icon follows the staged value back onto the root. A caught search
-- result keeps the same mark art as the grid while a seen-only
-- result hides every protected sprite.
function T.shape_icon_and_results_mark_follow_only_their_visible_pages()
  local PokedexController = requirePresent("shape and result sprite intents")
  local monCatalog, catalog = catalogs()
  withPublishedOptionOrder(catalog)
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  observe(owner, monCatalog, { species = "EEVEE", personality = 31 }, "caught")
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  press(controller, { { type = "y" } })
  Assert.equal(controller:view().page, "search", "grid Y reaches the criteria root")
  local function iconOf(view)
    if type(view.objects) ~= "table" then
      return nil
    end
    return findObject(view.objects, "body-icon")
  end
  Assert.isNil(iconOf(controller:view()), "no staged shape projects no icon")
  press(controller, { { type = "activate", action = "criterion", value = "shape" } })
  press(controller, { { type = "activate", action = "editor-choice", value = "quadruped" } })
  press(controller, { { type = "activate", action = "editor-ok" } })
  Assert.isNil(controller:view().search.editor, "confirming the shape choice returns to the root")
  local rootIcon = assert(iconOf(controller:view()), "the root projects the staged shape")
  checkIntentShape(rootIcon)
  Assert.equal(rootIcon.choice, "quadruped", "the root icon names the staged shape")
  Assert.equal(rootIcon.pane, "controls", "the root icon paints on the touch pane")
  Assert.equal(rootIcon.x, 224, "the root icon keeps its native column")
  Assert.equal(rootIcon.y, 72, "the root icon keeps its native row")
  press(controller, { { type = "activate", action = "criterion", value = "shape" } })
  local shapeIcon = assert(iconOf(controller:view()), "the shape editor keeps its icon")
  checkIntentShape(shapeIcon)
  Assert.equal(shapeIcon.choice, "quadruped", "the shape editor names the staged shape")
  Assert.equal(shapeIcon.x, 152, "the shape editor keeps its native column")
  Assert.equal(shapeIcon.y, 20, "the shape editor keeps its native row")
  press(controller, { { type = "cancel" } })
  Assert.isNil(controller:view().search.editor, "cancelling the shape editor returns to the root")
  for _, kind in ipairs({ "order", "letter", "type", "height", "weight", "area" }) do
    press(controller, { { type = "activate", action = "criterion", value = kind } })
    Assert.notNil(controller:view().search.editor, "the " .. kind .. " editor opens")
    Assert.isNil(iconOf(controller:view()), "the " .. kind .. " editor hides the staged shape")
    press(controller, { { type = "cancel" } })
    Assert.isNil(controller:view().search.editor, "cancelling the " .. kind .. " editor returns to the root")
  end
  local returned = assert(iconOf(controller:view()), "returning to the root restores the staged shape")
  Assert.equal(returned.x, 224, "the restored icon keeps its native column")
  Assert.equal(returned.y, 72, "the restored icon keeps its native row")
  press(controller, { { type = "start" } })
  idle(controller, 200)
  Assert.equal(controller:view().page, "results", "the completed search lands on the result grid")
  for _ = 1, 40 do
    if controller:view().selection.species == "EEVEE" then
      break
    end
    press(controller, { { type = "navigate", direction = "right" } })
  end
  local caughtView = controller:view()
  Assert.equal(caughtView.selection.species, "EEVEE", "the walk reaches the caught result")
  local mark = assert(findObject(caughtView.objects, "caught-mark"), "the caught result projects its mark")
  checkIntentShape(mark)
  Assert.equal(mark.choice, "shown", "the result mark uses the shown choice")
  Assert.equal(mark.pane, "information", "the result mark paints on the upper pane")
  Assert.equal(mark.x, 112, "the result mark keeps its native column")
  Assert.equal(mark.y, 32, "the result mark keeps its native row")
  Assert.notNil(findObject(caughtView.objects, "footprint"), "the caught result projects its footprint")
  for _ = 1, 40 do
    if controller:view().selection.species == "CHIKORITA" then
      break
    end
    press(controller, { { type = "navigate", direction = "right" } })
  end
  local seenView = controller:view()
  Assert.equal(seenView.selection.species, "CHIKORITA", "the walk reaches the seen-only result")
  Assert.isNil(findObject(seenView.objects, "caught-mark"), "a seen-only result hides its mark")
  Assert.isNil(findObject(seenView.objects, "footprint"), "a seen-only result hides its footprint")
  Assert.isNil(findObject(seenView.objects, "type-1"), "a seen-only result hides its types")
  controller:dispose()
end

-- The six visible area rows name the same habitat the cursor selects:
-- the first legal window shows the region entry, scrolling and direct
-- row taps keep every visible label on its source row, and windows past
-- the list stay blank instead of borrowing the neighbour name.
function T.area_list_names_the_same_habitat_the_cursor_selects()
  local PokedexController = requirePresent("area row label identity")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "EEVEE", personality = 31 }, "caught")
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  openEntry(controller, "EEVEE")
  local function slotsByRole(view)
    checkTextSlots(view)
    local found = {}
    for _, slot in ipairs(view.text) do
      found[slot.role] = slot
    end
    return found
  end
  local function checkCursor(expectedRow)
    local view = controller:view()
    Assert.equal(view.page, "area", "the entry stays on its area list")
    Assert.equal(view.area.row, expectedRow, "the cursor rests on the expected habitat row")
    local found = slotsByRole(view)
    local rows = assert(view.area.rows, "the area projects its rows")
    local geometry = assert(catalog.areaGeometry, "the catalog carries its area geometry")
    for position = 1, 6 do
      local arrayIndex = view.area.row + position - 1
      local role = position == 1 and "area.location" or ("area.row-" .. position)
      if arrayIndex < 1 or arrayIndex > #rows then
        Assert.isNil(found[role], "window past the list stays blank at cursor " .. expectedRow)
      else
        local row = assert(rows[arrayIndex], "the window row exists")
        local slot = assert(found[role], "cursor " .. expectedRow .. " window " .. position .. " names its row")
        if row.kind == "all" then
          Assert.equal(slot.kind, "ui", "the region entry rides the native bank")
          Assert.equal(slot.messageId, 134, "the johto region entry keeps its source entry")
        else
          Assert.equal(slot.kind, "area_name", "habitat rows resolve their landmark name")
          local record = assert(geometry[row.mapKey], "the habitat row maps its geometry")
          Assert.equal(slot.bankId, record.name.bankId, "the habitat row keeps its name bank")
          Assert.equal(slot.messageId, record.name.messageId, "the habitat row keeps its name entry")
        end
      end
    end
  end
  checkCursor(0)
  Assert.notNil(slotsByRole(controller:view())["area.row-2"], "the first legal window shows the region entry")
  press(controller, { { type = "navigate", direction = "down" } })
  checkCursor(1)
  press(controller, { { type = "navigate", direction = "down" } })
  checkCursor(2)
  Assert.equal(
    slotsByRole(controller:view())["area.location"].kind,
    "area_name",
    "the last window location names its habitat"
  )
  press(controller, { { type = "activate", action = "area-row", value = 0 } })
  checkCursor(0)
  controller:dispose()
end

-- The six visible form rows name the same variant the cursor selects:
-- the first legal window shows the first variant, scrolling keeps every
-- visible label on its source variant, and windows past the list stay
-- blank while the comparison still pairs both sides.
function T.forms_list_names_the_same_variant_the_cursor_selects()
  local PokedexController = requirePresent("forms row label identity")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  local function recordForm(species, personality, form, kind)
    local specimen = owner:describe(PokedexDexFixture.makeMon(monCatalog, {
      species = species,
      personality = personality,
      form = form,
    }))
    owner:prepareChanges({ observations = { { kind = kind, specimen = specimen } } }):publish()
  end
  recordForm("PICHU", 127, 0, "seen")
  recordForm("PICHU", 0, 0, "seen")
  recordForm("PICHU", 0, 1, "caught")
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  openEntry(controller, "PICHU")
  press(controller, { { type = "activate", action = "entry-tab", value = "forms" } })
  Assert.equal(controller:view().page, "forms", "the entry tab reaches the forms list")
  local function roles()
    checkTextSlots(controller:view())
    local found = {}
    for _, slot in ipairs(controller:view().text) do
      found[slot.role] = slot
    end
    return found
  end
  local resting = roles()
  Assert.equal(resting["forms.selected"].messageId, 114, "the first variant names the spiky-eared mark")
  Assert.notNil(resting["forms.row-2"], "the first legal window shows the first variant")
  Assert.equal(resting["forms.row-2"].messageId, 114, "the first window names the first variant")
  Assert.equal(resting["forms.row-3"].messageId, 114, "the second window names the second variant")
  Assert.equal(resting["forms.row-4"].messageId, 115, "the third window names the other form")
  Assert.isNil(resting["forms.row-5"], "windows past the variants stay blank")
  press(controller, { { type = "navigate", direction = "down" } })
  local middle = roles()
  Assert.equal(middle["forms.selected"].messageId, 114, "the middle cursor names the second variant")
  Assert.equal(middle["forms.row-1"].messageId, 114, "the scrolled top window follows the cursor")
  Assert.equal(middle["forms.row-2"].messageId, 114, "the centered window follows the cursor")
  Assert.equal(middle["forms.row-3"].messageId, 115, "the next window names the other form")
  press(controller, { { type = "navigate", direction = "down" } })
  local last = roles()
  Assert.equal(last["forms.selected"].messageId, 115, "the last cursor names the other form")
  Assert.equal(last["forms.row-1"].messageId, 114, "the last top window names the second variant")
  Assert.equal(last["forms.row-2"].messageId, 115, "the last centered window names the other form")
  Assert.isNil(last["forms.row-3"], "windows past the last variant stay blank")
  press(controller, { { type = "activate", action = "compare" } })
  local compared = roles()
  Assert.equal(compared["forms.compare-left"].messageId, 115, "the comparison names the selected variant")
  Assert.equal(compared["forms.compare-right"].messageId, 114, "the comparison names the other variant")
  controller:dispose()
end

-- Every staged slider window shows the same physical source quantity
-- through the native height and weight templates instead of the raw
-- step index: root values, open editor values, and the results recap
-- share one conversion from the catalog slider table.
function T.slider_windows_show_physical_quantities_through_source_templates()
  local PokedexController = requirePresent("slider physical text projection")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 }, "caught")
  observe(owner, monCatalog, { species = "TOTODILE", personality = 0 }, "caught")
  observe(owner, monCatalog, { species = "SPINDA", personality = 0 }, "caught")
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  press(controller, { { type = "y" } })
  Assert.equal(controller:view().page, "search", "grid Y reaches the search criteria")
  local function slots()
    checkTextSlots(controller:view())
    local found = {}
    for _, slot in ipairs(controller:view().text) do
      found[slot.role] = slot
    end
    return found
  end
  local root = slots()
  local function checkPhysical(slot, messageId, first, second, what)
    Assert.notNil(slot, "the staged window publishes " .. what)
    Assert.equal(slot.kind, "ui", "staged quantities ride the native bank instead of raw steps")
    Assert.equal(slot.messageId, messageId, "staged quantities use their source template")
    Assert.equal(slot.fields[0], first, "the major unit matches the source conversion (" .. what .. ")")
    Assert.equal(slot.fields[1], second, "the minor unit matches the source conversion (" .. what .. ")")
  end
  checkPhysical(root["search.value-height-min"], 175, "0", "00", "root height floor")
  checkPhysical(root["search.value-height-max"], 175, "99", "00", "root height ceiling")
  checkPhysical(root["search.value-weight-min"], 38, "0", "0", "root weight floor")
  checkPhysical(root["search.value-weight-max"], 38, "9999", "0", "root weight ceiling")
  press(controller, { { type = "activate", action = "criterion", value = "height" } })
  local height = slots()
  checkPhysical(height["search.current-height-min"], 175, "0", "00", "editor height floor")
  checkPhysical(height["search.current-height-max"], 175, "99", "00", "editor height ceiling")
  tick(controller, { { type = "drag", target = "height-min", phase = "begin", value = 10 } })
  tick(controller, { { type = "drag", target = "height-min", phase = "end", value = 10 } })
  checkPhysical(slots()["search.current-height-min"], 175, "3", "03", "a moved height bound follows its physical value")
  press(controller, { { type = "activate", action = "editor-ok" } })
  press(controller, { { type = "activate", action = "criterion", value = "weight" } })
  local weight = slots()
  checkPhysical(weight["search.current-weight-min"], 38, "0", "0", "editor weight floor")
  checkPhysical(weight["search.current-weight-max"], 38, "9999", "0", "editor weight ceiling")
  tick(controller, { { type = "drag", target = "weight-min", phase = "begin", value = 10 } })
  tick(controller, { { type = "drag", target = "weight-min", phase = "end", value = 10 } })
  checkPhysical(slots()["search.current-weight-min"], 38, "2", "2", "a moved weight bound follows its physical value")
  press(controller, { { type = "activate", action = "editor-ok" } })
  press(controller, { { type = "start" } })
  idle(controller, 200)
  Assert.equal(controller:view().page, "results", "the completed search lands on its recap")
  press(controller, { { type = "navigate", direction = "left" } })
  press(controller, { { type = "navigate", direction = "left" } })
  press(controller, { { type = "navigate", direction = "left" } })
  local recap = slots()
  checkPhysical(
    assert(recap["search.summary-value-height-min"], "recap carries its height floor"),
    175,
    "3",
    "03",
    "recap height floor"
  )
  checkPhysical(
    assert(recap["search.summary-value-weight-min"], "recap carries its weight floor"),
    38,
    "2",
    "2",
    "recap weight floor"
  )
  controller:dispose()
end

-- Slider digits spell the same physical value as the staged text and
-- keep trailing positions when leading slots stay hidden: a short
-- height keeps its inch digits and a tiny weight keeps its last two
-- digit sprites instead of stopping at the first hidden slot.
function T.slider_digits_keep_trailing_positions_when_leading_slots_hide()
  local PokedexController = requirePresent("slider digit visibility")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  press(controller, { { type = "y" } })
  press(controller, { { type = "activate", action = "criterion", value = "height" } })
  local view = controller:view()
  Assert.notNil(view.search.editor, "the height editor opens on its floor and ceiling")
  local function intents()
    local found = {}
    for _, intent in ipairs(assert(controller:view().objects, "the editor carries its intents")) do
      if type(intent) == "table" and type(intent.subject) == "string" then
        found[intent.subject] = intent
      end
    end
    return found
  end
  local height = intents()
  Assert.isNil(height["digit-min-1"], "a short height hides its foot tens")
  Assert.equal(
    assert(height["digit-min-2"], "a short height keeps its foot units").choice,
    "d0",
    "the foot units spell zero"
  )
  Assert.equal(
    assert(height["digit-min-3"], "a short height keeps its inch tens").choice,
    "d0",
    "the inch tens spell zero"
  )
  Assert.equal(
    assert(height["digit-min-4"], "a short height keeps its inch units").choice,
    "d0",
    "the inch units spell zero"
  )
  Assert.equal(
    assert(height["digit-max-1"], "the ceiling spells its foot tens").choice,
    "d9",
    "the sentinel foot tens spell nine"
  )
  Assert.equal(
    assert(height["digit-max-2"], "the ceiling spells its foot units").choice,
    "d9",
    "the sentinel foot units spell nine"
  )
  Assert.equal(
    assert(height["digit-max-3"], "the ceiling spells its inch tens").choice,
    "d0",
    "the sentinel inch tens spell zero"
  )
  Assert.equal(
    assert(height["digit-max-4"], "the ceiling spells its inch units").choice,
    "d0",
    "the sentinel inch units spell zero"
  )
  press(controller, { { type = "cancel" } })
  press(controller, { { type = "activate", action = "criterion", value = "weight" } })
  local weight = intents()
  Assert.isNil(weight["digit-min-1"], "a tiny weight hides its thousands")
  Assert.isNil(weight["digit-min-2"], "a tiny weight hides its hundreds")
  Assert.isNil(weight["digit-min-3"], "a tiny weight hides its tens when the value stays zero")
  Assert.equal(assert(weight["digit-min-4"], "a tiny weight keeps its ones").choice, "d0", "the ones spell zero")
  Assert.equal(assert(weight["digit-min-5"], "a tiny weight keeps its tenths").choice, "d0", "the tenths spell zero")
  Assert.equal(
    assert(weight["digit-max-1"], "the ceiling spells its thousands").choice,
    "d9",
    "the sentinel thousands spell nine"
  )
  Assert.equal(
    assert(weight["digit-max-5"], "the ceiling spells its tenths").choice,
    "d0",
    "the sentinel tenths spell zero"
  )
  controller:dispose()
end

-- The display projection never changes what the search finds and never
-- publishes a plausible unit when its source template is missing: the
-- same slider steps resolve the same members before and after text
-- projection, and a catalog without measurement templates fails closed.
function T.slider_display_leaves_search_membership_and_failures_closed()
  local PokedexController = requirePresent("slider search invariance")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  observe(owner, monCatalog, { species = "TOTODILE", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  press(controller, { { type = "y" } })
  local before = controller._search:run()
  Assert.isTrue(#before >= 1, "the default criteria resolve their members")
  checkTextSlots(controller:view())
  local after = controller._search:run()
  Assert.deepEqual(after, before, "projecting the display text changes no member")
  press(controller, { { type = "activate", action = "criterion", value = "height" } })
  tick(controller, { { type = "drag", target = "height-min", phase = "begin", value = 10 } })
  tick(controller, { { type = "drag", target = "height-min", phase = "end", value = 10 } })
  local narrowed = controller._search:run()
  Assert.isTrue(#narrowed <= #before, "narrowing the slider never invents members")
  controller:dispose()
  local _, goodCatalog = catalogs()
  local badSearchText = {}
  for key, value in pairs(goodCatalog.searchText) do
    if key ~= "measureTemplates" then
      badSearchText[key] = value
    end
  end
  local badCatalog = {}
  for key, value in pairs(goodCatalog) do
    badCatalog[key] = value
  end
  badCatalog.searchText = badSearchText
  local badOwner = ownerWithFlags(monCatalog, badCatalog, { dexEnabled = true })
  observe(badOwner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local bad = PokedexController.new(baseArgs(badOwner, monCatalog, badCatalog))
  openGrid(bad)
  press(bad, { { type = "y" } })
  local ok, failure = pcall(function()
    return bad:view().text
  end)
  Assert.isFalse(ok, "a catalog without measurement templates fails closed instead of showing a step")
  Assert.isTrue(type(failure) == "string" or type(failure) == "table", "the missing template reports its cause")
  bad:dispose()
end

-- The trainer pin agrees with the painted dungeon marker: a pin inside
-- the shifted tall silhouette reports inside even though the old
-- unshifted square would miss it, and a pin past the tall edge reports
-- outside. The outdoor road keeps its existing silhouette and center.
function T.trainer_inside_state_follows_the_painted_dungeon_marker()
  local PokedexController = requirePresent("trainer within-marker classification")
  local monCatalog, catalog = catalogs()
  catalog.areaGeometry["custom.tall-hollow"] = {
    kind = "dungeon",
    region = "johto",
    mapKey = "custom.tall-hollow",
    name = { bankId = 1, messageId = 11 },
    position = { x = 11, y = 6 },
    markerShape = 6,
    markerOffsetPx = { x = 0, y = 4 },
  }
  catalog.areaGeometry["custom.plain-road"] = {
    kind = "outdoor",
    region = "johto",
    mapKey = "custom.plain-road",
    name = { bankId = 1, messageId = 12 },
    rect = { x = 4, y = 2, width = 4, height = 2 },
    markerMask = {},
  }
  catalog.areaOrder = { "custom.plain-road", "custom.tall-hollow" }
  catalog.habitats["EEVEE"] = {
    morning = { outdoor = { "custom.plain-road" }, dungeon = { "custom.tall-hollow" } },
    day = { outdoor = {}, dungeon = {} },
    night = { outdoor = {}, dungeon = {} },
    other = { outdoor = {}, dungeon = {} },
  }
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "EEVEE", personality = 31 }, "caught")
  local inside =
    PokedexController.new(baseArgs(owner, monCatalog, catalog, { playerPosition = { mapX = 11, mapY = 7 } }))
  openGrid(inside)
  openEntry(inside, "EEVEE")
  local view = inside:view()
  local markers = {}
  local foundPlayer = nil
  for _, intent in ipairs(assert(view.objects, "the area carries its intents")) do
    if intent.subject == "marker" then
      checkIntentShape(intent)
      markers[#markers + 1] = intent
    elseif intent.subject == "player" then
      foundPlayer = intent
    end
  end
  Assert.equal(#markers, 2, "the road and the hollow both paint")
  Assert.equal(markers[1].choice, "shape3", "the road keeps its wide silhouette")
  Assert.equal(markers[1].x, 112, "the road keeps its column")
  Assert.equal(markers[1].y, 64, "the road keeps its row")
  Assert.equal(markers[2].choice, "shape6", "the hollow paints its tall silhouette")
  Assert.equal(markers[2].x, 156, "the hollow paints its shifted column")
  Assert.equal(markers[2].y, 96, "the hollow paints its shifted row")
  local player = assert(foundPlayer, "the area projects its trainer pin")
  checkIntentShape(player)
  Assert.equal(player.choice, "male-here", "the pin inside the shifted tall marker reports inside")
  Assert.equal(player.x, 156, "the inside pin keeps its column")
  Assert.equal(player.y, 100, "the inside pin keeps its row")
  inside:dispose()
  local outside =
    PokedexController.new(baseArgs(owner, monCatalog, catalog, { playerPosition = { mapX = 11, mapY = 8 } }))
  openGrid(outside)
  openEntry(outside, "EEVEE")
  local farView = outside:view()
  local foundFarMarker = nil
  local foundFarPlayer = nil
  for _, intent in ipairs(assert(farView.objects, "the far area carries its intents")) do
    if intent.subject == "marker" and intent.instance == 2 then
      foundFarMarker = intent
    elseif intent.subject == "player" then
      foundFarPlayer = intent
    end
  end
  local farMarker = assert(foundFarMarker, "the far page still paints the hollow")
  Assert.equal(farMarker.choice, "shape6", "the far page keeps the tall silhouette")
  Assert.equal(farMarker.x, 156, "the far hollow keeps its shifted column")
  Assert.equal(farMarker.y, 96, "the far hollow keeps its shifted row")
  local farPlayer = assert(foundFarPlayer, "the far page projects its trainer pin")
  Assert.equal(farPlayer.choice, "male", "the pin past the tall marker edge reports outside")
  Assert.equal(farPlayer.x, 156, "the outside pin keeps its column")
  Assert.equal(farPlayer.y, 108, "the outside pin keeps its row")
  outside:dispose()
end

-- Retail cursor, page, and touch-open tones: d-pad cursor moves play
-- ZKN03, page turns and touch slot changes play ZKN04, a same-tap
-- entry open plays ZKN04, and a same-tap blank stays silent.
function T.retail_key_moves_and_touch_opens_play_their_list_tones()
  local PokedexController = requirePresent("retail list cursor and page tones")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  observe(owner, monCatalog, { species = "WORMADAM", personality = 0 })
  observe(owner, monCatalog, { species = "ROTOM", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "music:duck"),
    "opening ducks the field music for the dex scene"
  )
  openGrid(controller)
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_BUTTON01"),
    "beginning the cover drag plays the decide tone"
  )
  press(controller, { { type = "navigate", direction = "right" } })
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN03"),
    "a d-pad cursor move plays the cursor tone"
  )
  press(controller, { { type = "r" } })
  Assert.equal(controller:view().grid.page, 1, "page-next turns the page")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "a page turn plays the touch tone"
  )
  press(controller, { { type = "r" } })
  Assert.equal(controller:view().grid.page, 1, "page-next clamps at the last page")
  Assert.deepEqual(drainSoundRoles(controller), {}, "a clamped page turn stays silent")
  press(controller, { { type = "l" } })
  Assert.equal(controller:view().grid.page, 0, "page-prev turns the page")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "page-prev plays the touch tone"
  )
  press(controller, { { type = "activate", action = "grid-slot", value = 2 } })
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "a touch slot change plays the touch tone"
  )
  press(controller, { { type = "activate", action = "grid-slot", value = 2 } })
  Assert.equal(controller:view().page, "grid", "a same-tap blank opens no entry")
  Assert.deepEqual(drainSoundRoles(controller), {}, "a same-tap blank stays silent")
  press(controller, { { type = "activate", action = "grid-slot", value = 0 } })
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "a touch move onto the seen slot plays the touch tone"
  )
  press(controller, { { type = "activate", action = "grid-slot", value = 0 } })
  Assert.equal(controller:view().page, "area", "a same-tap seen slot opens its entry")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "a touch entry open plays the touch tone"
  )
  press(controller, { { type = "cancel" } })
  Assert.equal(controller:view().page, "grid", "cancelling the entry returns to the grid")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_GEARCANCEL"),
    "cancelling the entry plays the cancel tone"
  )
  press(controller, { { type = "start" } })
  Assert.equal(controller:view().page, "cover", "start returns to the cover")
  Assert.isFalse(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_BUTTON01"),
    "start on the grid returns silently like the source list START key"
  )
  controller:dispose()
end

-- Retail cover tones: dex-mode switches play ZKN_BUTTON8, the search
-- shortcut plays ZKN04, confirms play BUTTON01, and closing plays
-- GEARCANCEL with the music restore.
function T.retail_cover_plays_decide_mode_and_search_tones()
  local PokedexController = requirePresent("retail cover tones")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  Assert.equal(controller:view().page, "cover", "a fresh open starts on the cover")
  controller:drainEffects()
  press(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(controller:view().mode, "johto", "cover right selects johto")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN_BUTTON8"),
    "a dex-mode switch plays the mode tone"
  )
  press(controller, { { type = "navigate", direction = "left" } })
  Assert.equal(controller:view().mode, "national", "cover left selects national")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN_BUTTON8"),
    "switching back plays the mode tone"
  )
  press(controller, { { type = "activate", action = "mode", value = "johto" } })
  Assert.equal(controller:view().mode, "johto", "touch selects johto")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN_BUTTON8"),
    "a touch dex-mode switch plays the mode tone"
  )
  press(controller, { { type = "activate", action = "mode", value = "johto" } })
  Assert.deepEqual(drainSoundRoles(controller), {}, "an unchanged dex-mode switch stays silent")
  press(controller, { { type = "y" } })
  Assert.equal(controller:view().page, "search", "cover Y reaches the search root")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "the search shortcut plays the touch tone"
  )
  press(controller, { { type = "cancel" } })
  Assert.equal(controller:view().page, "grid", "cancelling the search returns to the grid")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_GEARCANCEL"),
    "cancelling the search plays the cancel tone"
  )
  press(controller, { { type = "start" } })
  Assert.equal(controller:view().page, "cover", "start returns to the cover")
  Assert.isFalse(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_BUTTON01"),
    "start on the grid returns silently like the source list START key"
  )
  press(controller, { { type = "confirm" } })
  idle(controller, 10)
  Assert.equal(controller:view().page, "area", "cover confirm opens the cursor entry directly")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_BUTTON01"),
    "cover confirm plays the decide tone"
  )
  press(controller, { { type = "cancel" } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "grid", "cancelling the entry restores its grid origin")
  controller:dispose()
  local closer = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  closer:drainEffects()
  press(closer, { { type = "cancel" } })
  idle(closer, 40)
  Assert.deepEqual(closer:takeResult(), { kind = "close" }, "cover cancel closes the application")
  local closing = drainSoundRoles(closer)
  Assert.isTrue(
    hasSoundRole(closing, "SEQ_SE_GS_GEARCANCEL"),
    "closing the cover plays the cancel tone"
  )
  Assert.isTrue(
    hasSoundRole(closing, "music:restore"),
    "closing restores the field music"
  )
  closer:dispose()
end

-- Retail cancel paths: every B edge behind the browser plays exactly
-- one GEARCANCEL, including editor dismissal, search and result
-- dismissal, entry return, comparison dismissal, and the back tab.
function T.retail_cancel_paths_play_the_cancel_tone()
  local PokedexController = requirePresent("retail cancel tones")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  observe(owner, monCatalog, { species = "TOTODILE", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  press(controller, { { type = "y" } })
  press(controller, { { type = "activate", action = "criterion", value = "letter" } })
  Assert.notNil(controller:view().search.editor, "the letter editor opens")
  controller:drainEffects()
  press(controller, { { type = "cancel" } })
  Assert.isNil(controller:view().search.editor, "cancelling closes the editor")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_GEARCANCEL"),
    "cancelling the editor plays the cancel tone"
  )
  press(controller, { { type = "cancel" } })
  Assert.equal(controller:view().page, "grid", "cancelling the search returns to the grid")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_GEARCANCEL"),
    "cancelling the search plays the cancel tone"
  )
  press(controller, { { type = "y" } })
  press(controller, { { type = "start" } })
  idle(controller, 200)
  Assert.equal(controller:view().page, "results", "the completed search lands on the result grid")
  controller:drainEffects()
  press(controller, { { type = "cancel" } })
  Assert.equal(controller:view().page, "grid", "cancelling the results returns to the grid")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_GEARCANCEL"),
    "cancelling the results plays the cancel tone"
  )
  press(controller, { { type = "confirm" } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "area", "confirming opens the entry")
  controller:drainEffects()
  press(controller, { { type = "cancel" } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "grid", "cancelling the entry returns to the grid")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_GEARCANCEL"),
    "cancelling the entry plays the cancel tone"
  )
  Assert.isNil(controller:takeResult(), "entry cancels never close the application")
  press(controller, { { type = "confirm" } })
  idle(controller, 40)
  press(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(controller:view().page, "forms", "a seen-only entry skips its missing size tab")
  press(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(controller:view().page, "return", "cycling reaches the back tab")
  controller:drainEffects()
  press(controller, { { type = "confirm" } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "grid", "confirming the back tab returns to the grid")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_GEARCANCEL"),
    "confirming the back tab plays the cancel tone"
  )
  press(controller, { { type = "confirm" } })
  idle(controller, 40)
  press(controller, { { type = "navigate", direction = "right" } })
  press(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(controller:view().page, "return", "cycling reaches the back tab again")
  controller:drainEffects()
  press(controller, { { type = "activate", action = "return-list" } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "grid", "the back action returns to the grid")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_GEARCANCEL"),
    "the back action plays the cancel tone"
  )
  controller:dispose()
end

-- Retail entry tones: key tab, row, region, and time switches play
-- ZKN03 while their touch twins play ZKN04, and both return gestures
-- play GEARCANCEL.
function T.retail_entry_pages_play_key_and_touch_tones()
  local PokedexController = requirePresent("retail entry tones")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "EEVEE", personality = 31 }, "caught")
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  openEntry(controller, "EEVEE")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "opening the entry by key plays the touch tone"
  )
  press(controller, { { type = "confirm" } })
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN03"),
    "cycling the daypart by key plays the cursor tone"
  )
  press(controller, { { type = "activate", action = "area-time", value = 2 } })
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "touching the daypart plays the touch tone"
  )
  -- The time switch rebuilds behind a refresh; rows stay inert until it settles.
  idle(controller, 40)
  press(controller, { { type = "navigate", direction = "down" } })
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN03"),
    "scrolling the area rows by key plays the cursor tone"
  )
  press(controller, { { type = "activate", action = "area-row", value = 0 } })
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "touching an area row plays the touch tone"
  )
  press(controller, { { type = "select" } })
  Assert.equal(controller:view().area.region, "kanto", "the region key switches to kanto")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN03"),
    "switching regions by key plays the cursor tone"
  )
  press(controller, { { type = "activate", action = "area-region", value = "johto" } })
  Assert.equal(controller:view().area.region, "johto", "the touch region returns to johto")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "touching the region plays the touch tone"
  )
  press(controller, { { type = "l" } })
  Assert.equal(controller:view().area.region, "johto", "the johto key stays inert on johto")
  Assert.deepEqual(
    drainSoundRoles(controller),
    {},
    "a region switch with no change stays silent"
  )
  press(controller, { { type = "r" } })
  Assert.equal(controller:view().area.region, "kanto", "the kanto key switches regions")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN03"),
    "switching regions by shoulder key plays the cursor tone"
  )
  press(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(controller:view().page, "size", "the caught entry cycles into size")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN03"),
    "cycling tabs by key plays the cursor tone"
  )
  idle(controller, 60)
  Assert.equal(controller:view().size.weight.phase, "drop", "the weight figures start their drop")
  controller:drainEffects()
  press(controller, { { type = "activate", action = "size-restart", value = 0 } })
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "touching the size restart plays the touch tone"
  )
  press(controller, { { type = "activate", action = "entry-tab", value = "return" } })
  Assert.equal(controller:view().page, "return", "the touch tab reaches the back panel")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "touching the entry tab plays the touch tone"
  )
  press(controller, { { type = "confirm" } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "grid", "confirming the back tab returns to the grid")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_GEARCANCEL"),
    "confirming the back tab plays the cancel tone"
  )
  controller:dispose()
end

-- Retail forms and comparison tones: list rows and tab switches
-- follow the key/touch split, compare cycling plays ZKN03 by key
-- and ZKN04 by touch, and dismissing the comparison plays
-- GEARCANCEL.
function T.retail_forms_and_comparison_play_key_and_touch_tones()
  local PokedexController = requirePresent("retail forms tones")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  local function recordForm(species, personality, form, kind)
    local specimen = owner:describe(PokedexDexFixture.makeMon(monCatalog, {
      species = species,
      personality = personality,
      form = form,
    }))
    owner:prepareChanges({ observations = { { kind = kind, specimen = specimen } } }):publish()
  end
  recordForm("PICHU", 127, 0, "seen")
  recordForm("PICHU", 0, 0, "seen")
  recordForm("PICHU", 0, 1, "caught")
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  openEntry(controller, "PICHU")
  press(controller, { { type = "activate", action = "entry-tab", value = "forms" } })
  Assert.equal(controller:view().page, "forms", "the entry tab reaches the forms page")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "touching the entry tab plays the touch tone"
  )
  Assert.equal(#controller:view().forms.variants, 3, "the pichu list carries three seen forms")
  press(controller, { { type = "navigate", direction = "down" } })
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN03"),
    "scrolling the form rows by key plays the cursor tone"
  )
  press(controller, { { type = "activate", action = "forms-row", value = 0 } })
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "touching a form row plays the touch tone"
  )
  controller:drainEffects()
  press(controller, { { type = "confirm" } })
  Assert.notNil(controller:view().forms.comparison, "confirming the list opens the comparison")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "confirming the list plays the touch tone"
  )
  local before = controller:view().forms.comparison
  Assert.equal(before.activeSide, 0, "the comparison starts on the left side")
  press(controller, { { type = "navigate", direction = "right" } })
  local switched = controller:view().forms.comparison
  Assert.equal(switched.activeSide, 1, "right switches to the right side")
  Assert.deepEqual(switched.indices, before.indices, "switching sides steps no form")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN03"),
    "switching the compare side by key plays the cursor tone"
  )
  press(controller, { { type = "navigate", direction = "right" } })
  Assert.deepEqual(
    drainSoundRoles(controller),
    {},
    "an unchanged compare side stays silent"
  )
  press(controller, { { type = "navigate", direction = "left" } })
  Assert.equal(controller:view().forms.comparison.activeSide, 0, "left switches back to the left side")
  Assert.deepEqual(
    controller:view().forms.comparison.indices,
    before.indices,
    "switching back steps no form either"
  )
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN03"),
    "switching back by key plays the cursor tone"
  )
  press(controller, { { type = "navigate", direction = "down" } })
  local stepped = controller:view().forms.comparison
  Assert.isTrue(
    stepped.indices[1] ~= before.indices[1] or stepped.indices[2] ~= before.indices[2],
    "down steps the active side past the other side index"
  )
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN03"),
    "cycling the compare forms by key plays the cursor tone"
  )
  press(controller, { { type = "menu" } })
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "flipping the compare faces plays the touch tone"
  )
  press(controller, { { type = "activate", action = "compare-side", value = 1 } })
  Assert.equal(controller:view().forms.comparison.activeSide, 1, "touch selects the right side")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "touching the compare side plays the touch tone"
  )
  press(controller, { { type = "confirm" } })
  Assert.isNil(controller:view().forms.comparison, "confirming closes the comparison")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_GEARCANCEL"),
    "confirming the comparison plays the cancel tone"
  )
  press(controller, { { type = "activate", action = "compare-back" } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "grid", "the compare back action returns to the grid")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_GEARCANCEL"),
    "the compare back action plays the cancel tone"
  )
  controller:dispose()
  local pairOwner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  local function recordPairForm(personality, form, kind)
    local specimen = pairOwner:describe(PokedexDexFixture.makeMon(monCatalog, {
      species = "PICHU",
      personality = personality,
      form = form,
    }))
    pairOwner:prepareChanges({ observations = { { kind = kind, specimen = specimen } } }):publish()
  end
  recordPairForm(127, 0, "seen")
  recordPairForm(0, 0, "seen")
  local pair = PokedexController.new(baseArgs(pairOwner, monCatalog, catalog))
  openGrid(pair)
  openEntry(pair, "PICHU")
  press(pair, { { type = "activate", action = "entry-tab", value = "forms" } })
  Assert.equal(#pair:view().forms.variants, 2, "the pair list carries two seen forms")
  press(pair, { { type = "activate", action = "compare" } })
  Assert.notNil(pair:view().forms.comparison, "the touch compare opens the two-form comparison")
  pair:drainEffects()
  press(pair, { { type = "navigate", direction = "right" } })
  Assert.equal(pair:view().forms.comparison.activeSide, 0, "side keys stay inert below three forms")
  Assert.deepEqual(drainSoundRoles(pair), {}, "side keys below three forms stay silent")
  press(pair, { { type = "navigate", direction = "left" } })
  Assert.equal(pair:view().forms.comparison.activeSide, 0, "the other side key stays inert too")
  Assert.deepEqual(drainSoundRoles(pair), {}, "the other side key stays silent too")
  pair:dispose()
  local singleOwner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(singleOwner, monCatalog, { species = "EEVEE", personality = 31 }, "caught")
  local single = PokedexController.new(baseArgs(singleOwner, monCatalog, catalog))
  openGrid(single)
  openEntry(single, "EEVEE")
  press(single, { { type = "activate", action = "entry-tab", value = "forms" } })
  single:drainEffects()
  press(single, { { type = "confirm" } })
  Assert.isNil(single:view().forms.comparison, "confirming a single form opens no comparison")
  Assert.deepEqual(drainSoundRoles(single), {}, "confirming a single form stays silent")
  single:dispose()
end

function T.size_confirm_always_restarts_the_finished_weight_check()
  local PokedexController = requirePresent("retail size restart")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "EEVEE", personality = 31 }, "caught")
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  openEntry(controller, "EEVEE")
  press(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(controller:view().page, "size", "area right reaches size on a caught entry")
  idle(controller, 60)
  for _ = 1, 2000 do
    local phase = controller:view().size.weight.phase
    if phase ~= "drop" and phase ~= "tilt" and phase ~= "beam" and phase ~= "thrown" and phase ~= "escape" then
      break
    end
    tick(controller, {})
  end
  local settled = controller:view().size.weight.phase
  Assert.isTrue(
    settled == "landed" or settled == "even" or settled == "escaped",
    "the weight check settles before the restart (" .. tostring(settled) .. ")"
  )
  controller:drainEffects()
  press(controller, { { type = "confirm" } })
  Assert.equal(controller:view().page, "size", "confirming stays on the size page")
  Assert.equal(controller:view().size.weight.phase, "setup", "confirming rebuilds the finished check")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN03"),
    "confirming the restart plays the cursor tone"
  )
  idle(controller, 60)
  Assert.equal(controller:view().size.weight.phase, "drop", "the rebuilt check starts its drop")
  controller:drainEffects()
  press(controller, { { type = "activate", action = "size-restart" } })
  Assert.equal(controller:view().size.weight.phase, "setup", "touching restart rebuilds the check")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "touching the size restart plays the touch tone"
  )
  controller:dispose()
end

function T.keyboard_x_cries_the_cursor_species_like_menu()
  local PokedexController = requirePresent("retail keyboard cry")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  observe(owner, monCatalog, { species = "TOTODILE", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  Assert.equal(controller:view().selection.species, "CHIKORITA", "the cursor starts on chikorita")
  controller:drainEffects()
  press(controller, { { type = "x" } })
  local keyed = controller:drainEffects()
  Assert.equal(#keyed, 1, "keyboard X emits one effect")
  Assert.equal(keyed[1].kind, "cry", "keyboard X requests a cry")
  press(controller, { { type = "menu" } })
  local touched = controller:drainEffects()
  Assert.equal(#touched, 1, "the menu cry emits one effect")
  Assert.equal(touched[1].species, keyed[1].species, "keyboard X names the same species as menu")
  Assert.equal(touched[1].form, keyed[1].form, "keyboard X uses the same form as menu")
  press(controller, { { type = "confirm" } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "area", "confirming opens the entry")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "opening the entry by key plays the touch tone"
  )
  press(controller, { { type = "x" } })
  Assert.deepEqual(controller:drainEffects(), {}, "keyboard X stays inert on the area page")
  Assert.equal(controller:view().page, "area", "keyboard X never leaves the area page")
  press(controller, { { type = "cancel" } })
  idle(controller, 40)
  press(controller, { { type = "y" } })
  press(controller, { { type = "start" } })
  idle(controller, 200)
  Assert.equal(controller:view().page, "results", "the completed search lands on the result grid")
  controller:drainEffects()
  press(controller, { { type = "x" } })
  Assert.deepEqual(controller:drainEffects(), {}, "keyboard X stays silent on the return slot")
  press(controller, { { type = "navigate", direction = "right" } })
  local species = controller:view().selection.species
  Assert.notNil(species, "the cursor reaches a result species")
  controller:drainEffects()
  press(controller, { { type = "x" } })
  local resultCry = controller:drainEffects()
  Assert.equal(#resultCry, 1, "keyboard X cries the result species")
  Assert.equal(resultCry[1].kind, "cry", "the result effect is a cry request")
  Assert.equal(resultCry[1].species, species, "the result cry names the cursor species")
  controller:dispose()
end

-- Retail search tones: focus and editor cursor moves play ZKN03,
-- slider arrow steps and every commit touch play ZKN04, slider drags
-- play ZKN03 on change, cancels play GEARCANCEL, START plays
-- BUTTON01, and the completed search chimes ZUKAN06 with Z_SEARCH.
function T.retail_search_plays_key_and_touch_tones_with_found_chime()
  local PokedexController = requirePresent("retail search tones")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  observe(owner, monCatalog, { species = "TOTODILE", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  controller:drainEffects()
  press(controller, { { type = "y" } })
  Assert.equal(controller:view().page, "search", "grid Y reaches the criteria root")
  Assert.deepEqual(drainSoundRoles(controller), {}, "opening the search by key stays silent")
  press(controller, { { type = "navigate", direction = "down" } })
  Assert.equal(controller:view().search.focus, "letter", "search focus steps to the letter criterion")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN03"),
    "moving the search focus plays the cursor tone"
  )
  press(controller, { { type = "confirm" } })
  Assert.notNil(controller:view().search.editor, "confirm opens the focused letter editor")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "confirming the search focus plays the touch tone"
  )
  press(controller, { { type = "navigate", direction = "down" } })
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN03"),
    "moving inside the editor plays the cursor tone"
  )
  press(controller, { { type = "confirm" } })
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "choosing the editor option plays the touch tone"
  )
  press(controller, { { type = "cancel" } })
  Assert.isNil(controller:view().search.editor, "cancelling closes the editor")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_GEARCANCEL"),
    "cancelling the editor plays the cancel tone"
  )
  press(controller, { { type = "activate", action = "criterion", value = "height" } })
  Assert.notNil(controller:view().search.editor, "the height editor opens")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "touching the criterion plays the touch tone"
  )
  press(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(
    controller:view().search.criteria.height.min,
    1,
    "the right step raises the height floor"
  )
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "stepping the slider by key plays the touch tone"
  )
  press(controller, { { type = "navigate", direction = "left" } })
  press(controller, { { type = "navigate", direction = "left" } })
  Assert.equal(
    controller:view().search.criteria.height.min,
    0,
    "the left steps lower the height floor to its clamp"
  )
  Assert.deepEqual(
    drainSoundRoles(controller),
    { "SEQ_SE_GS_ZKN04" },
    "only the changing slider step plays the touch tone"
  )
  tick(controller, { { type = "drag", target = "height-min", phase = "begin", value = 10 } })
  Assert.deepEqual(drainSoundRoles(controller), {}, "beginning the slider drag stays silent")
  tick(controller, { { type = "drag", target = "height-min", phase = "move", value = 78 } })
  Assert.equal(
    controller:view().search.criteria.height.min,
    78,
    "the drag stages the captured bound"
  )
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN03"),
    "dragging the slider plays the cursor tone on change"
  )
  tick(controller, { { type = "drag", target = "height-min", phase = "move", value = 78 } })
  Assert.deepEqual(drainSoundRoles(controller), {}, "an unchanged slider drag stays silent")
  tick(controller, { { type = "drag", target = "height-min", phase = "end", value = 78 } })
  Assert.deepEqual(drainSoundRoles(controller), {}, "ending the slider drag stays silent")
  press(controller, { { type = "activate", action = "editor-ok" } })
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "committing the editor plays the touch tone"
  )
  press(controller, { { type = "activate", action = "search-reset" } })
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN04"),
    "touching reset plays the touch tone"
  )
  for _ = 1, 4 do
    press(controller, { { type = "navigate", direction = "down" } })
  end
  Assert.equal(controller:view().search.focus, "run", "search focus steps to the run action")
  controller:drainEffects()
  press(controller, { { type = "start" } })
  Assert.notNil(controller:view().search.feedback, "search start enters the feedback sequence")
  local started = drainSoundRoles(controller)
  Assert.isFalse(
    hasSoundRole(started, "SEQ_SE_GS_BUTTON01"),
    "search start runs without the decide tone"
  )
  Assert.isTrue(
    hasSoundRole(started, "SEQ_SE_DP_Z_SEARCH"),
    "search start keeps its search tone"
  )
  idle(controller, 200)
  Assert.equal(controller:view().page, "results", "the completed search lands on the result grid")
  local finished = drainSoundRoles(controller)
  Assert.isTrue(
    hasSoundRole(finished, "SEQ_SE_GS_ZUKAN06"),
    "the completed search chimes its results-found tone"
  )
  controller:dispose()
end

-- Retail scrollbar and cover drag tones: paging the list by drag
-- plays ZKN03 on change, and beginning the cover drag plays
-- BUTTON01 while the rest of the gesture stays silent.
function T.retail_drags_play_scroll_and_decide_tones()
  local PokedexController = requirePresent("retail drag tones")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  observe(owner, monCatalog, { species = "WORMADAM", personality = 0 })
  observe(owner, monCatalog, { species = "ROTOM", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  tick(controller, { { type = "drag", target = "cover", phase = "begin", value = 0 } })
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_BUTTON01"),
    "beginning the cover drag plays the decide tone"
  )
  tick(controller, { { type = "drag", target = "cover", phase = "move", value = 200 } })
  Assert.deepEqual(drainSoundRoles(controller), {}, "moving the cover drag stays silent")
  tick(controller, { { type = "drag", target = "cover", phase = "end", value = 200 } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "grid", "completing the cover drag opens the grid")
  Assert.deepEqual(drainSoundRoles(controller), {}, "completing the cover drag stays silent")
  tick(controller, { { type = "drag", target = "grid-scroll", phase = "end", value = 1 } })
  Assert.equal(controller:view().grid.page, 1, "the scrollbar drag turns the page")
  Assert.isTrue(
    hasSoundRole(drainSoundRoles(controller), "SEQ_SE_GS_ZKN03"),
    "paging the scrollbar plays the cursor tone"
  )
  tick(controller, { { type = "drag", target = "grid-scroll", phase = "end", value = 1 } })
  Assert.deepEqual(drainSoundRoles(controller), {}, "an unchanged scrollbar drag stays silent")
  controller:dispose()
end

-- Language flag icons ride the grid beside the selected entry: without
-- the international view nothing projects, while a foreign-caught
-- species shows its dimmed flag plus the highlighted native flag
-- right-aligned from the native columns, with the current-language icon
-- on the touch pane. SELECT cycling itself is untouched.
function T.language_flags_gate_on_the_international_view_and_right_align()
  local PokedexController = requirePresent("language flag icons")
  local monCatalog, catalog = catalogs()
  local gated = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(gated, monCatalog, { species = "EEVEE", personality = 31 }, "caught")
  local closed = PokedexController.new(baseArgs(gated, monCatalog, catalog))
  openGrid(closed)
  for _ = 1, 40 do
    if closed:view().selection.species == "EEVEE" then
      break
    end
    press(closed, { { type = "navigate", direction = "right" } })
  end
  local shut = closed:view()
  Assert.equal(shut.selection.species, "EEVEE", "the cursor reaches the caught selection")
  Assert.isNil(findObject(shut.objects, "lang-flag"), "a closed view hides its language flags")
  Assert.isNil(findObject(shut.objects, "lang-current"), "a closed view hides its current icon")
  closed:dispose()
  local open = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(open, monCatalog, { species = "EEVEE", personality = 31, language = "french" }, "caught")
  observe(open, monCatalog, { species = "CHIKORITA", personality = 0 })
  local controller = PokedexController.new(baseArgs(open, monCatalog, catalog))
  openGrid(controller)
  for _ = 1, 40 do
    if controller:view().selection.species == "EEVEE" then
      break
    end
    press(controller, { { type = "navigate", direction = "right" } })
  end
  local view = controller:view()
  Assert.equal(view.selection.species, "EEVEE", "the cursor reaches the foreign-caught selection")
  local flags = {}
  for _, intent in ipairs(assert(view.objects, "the grid carries its intents")) do
    if intent.subject == "lang-flag" then
      checkIntentShape(intent)
      flags[#flags + 1] = intent
    end
  end
  Assert.equal(#flags, 2, "the native flag joins the one caught foreign flag")
  local byChoice = {}
  for _, intent in ipairs(flags) do
    byChoice[intent.choice] = intent
  end
  local french = assert(byChoice["french-dim"], "the unshown caught flag dims")
  Assert.equal(french.pane, "information", "the flags paint on the upper pane")
  Assert.equal(french.x, 244, "the first shown flag anchors at the right edge")
  Assert.equal(french.y, 8, "the flags keep their native row")
  local english = assert(byChoice["english"], "the shown native flag highlights")
  Assert.equal(english.x, 220, "the next shown flag steps one slot left")
  Assert.equal(english.y, 8, "the highlighted flag keeps its native row")
  local current = assert(findObject(view.objects, "lang-current"), "the grid projects its current icon")
  checkIntentShape(current)
  Assert.equal(current.choice, "english", "the current icon names the shown language")
  Assert.equal(current.pane, "controls", "the current icon paints on the touch pane")
  Assert.equal(current.x, 92, "the current icon keeps its native column")
  Assert.equal(current.y, 136, "the current icon keeps its native row")
  controller:dispose()
end

-- The weight trainer figure rides its own pan beside the fixed height
-- portrait: the figure starts over the left pan and drops with the
-- published simulation while the portrait stays on its authored column.
function T.size_weight_figure_rides_its_pan()
  local PokedexController = requirePresent("size weight figure")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "EEVEE", personality = 31 }, "caught")
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  for _ = 1, 40 do
    if controller:view().selection.species == "EEVEE" then
      break
    end
    press(controller, { { type = "navigate", direction = "right" } })
  end
  press(controller, { { type = "confirm" } })
  idle(controller, 40)
  press(controller, { { type = "navigate", direction = "right" } })
  idle(controller, 40)
  local view = controller:view()
  Assert.equal(view.page, "size", "the caught entry reaches its size")
  local trainers = {}
  for _, intent in ipairs(assert(view.objects, "the size carries its intents")) do
    if intent.subject == "trainer" then
      checkIntentShape(intent)
      trainers[#trainers + 1] = intent
    end
  end
  Assert.equal(#trainers, 2, "the portrait and the weight figure both project")
  local portrait, figure = nil, nil
  for _, intent in ipairs(trainers) do
    if intent.x == 184 then
      portrait = intent
    else
      figure = intent
    end
  end
  portrait = assert(portrait, "the height portrait keeps its authored column")
  Assert.equal(portrait.x, 184, "the height portrait keeps its authored column")
  figure = assert(figure, "the weight figure projects beside its pan")
  Assert.equal(figure.x, view.size.pans[1].x, "the figure tracks its pan column")
  local figures = assert(view.size.figures, "the size projects its figures")
  local trainerY = nil
  for _, record in ipairs(figures) do
    if record.side == "trainer" then
      trainerY = record.y
    end
  end
  Assert.equal(figure.y, trainerY, "the figure tracks its simulated height")
  idle(controller, 25)
  local dropped = controller:view()
  local nextY = nil
  for _, record in ipairs(assert(dropped.size.figures, "the figures persist")) do
    if record.side == "trainer" then
      nextY = record.y
    end
  end
  Assert.isTrue(nextY ~= trainerY, "accepted ticks move the simulated figure")
  local moved = nil
  for _, intent in ipairs(assert(dropped.objects, "the dropped size carries its intents")) do
    if intent.subject == "trainer" and intent.x ~= 184 then
      moved = intent
    end
  end
  moved = assert(moved, "the moved figure still projects")
  Assert.equal(moved.y, nextY, "the figure intent follows the simulation")
  controller:dispose()
end

-- Special area markers paint beside their backed dungeon and classify
-- the pin: the Diglett extra rides at its fixed native pixels while the
-- dungeon keeps its own silhouette, and the pin inside the extra
-- reports inside.
function T.special_markers_paint_beside_their_backed_dungeon()
  local PokedexController = requirePresent("special area markers")
  local monCatalog, catalog = catalogs()
  catalog.areaGeometry["dex-dungeon-23"] = {
    kind = "dungeon",
    region = "johto",
    mapKey = "dex-dungeon-23",
    name = { bankId = 1, messageId = 11 },
    position = { x = 5, y = 5 },
    markerShape = 0,
    markerOffsetPx = { x = 0, y = 0 },
  }
  catalog.areaOrder = { "dex-dungeon-23" }
  catalog.habitats["EEVEE"] = {
    morning = { outdoor = {}, dungeon = { "dex-dungeon-23" } },
    day = { outdoor = {}, dungeon = {} },
    night = { outdoor = {}, dungeon = {} },
    other = { outdoor = {}, dungeon = {} },
  }
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "EEVEE", personality = 31 }, "caught")
  local controller =
    PokedexController.new(baseArgs(owner, monCatalog, catalog, { playerPosition = { mapX = 10, mapY = 4 } }))
  openGrid(controller)
  openEntry(controller, "EEVEE")
  local view = controller:view()
  Assert.equal(view.page, "area", "the entry opens on its area page")
  local specials = assert(view.area.specialMarkers, "the area projects its special markers")
  Assert.equal(#specials, 1, "the backed dungeon carries its one extra marker")
  Assert.equal(specials[1].position.x, 148, "the extra keeps its fixed column")
  Assert.equal(specials[1].position.y, 76, "the extra keeps its fixed row")
  local foundExtra, foundPlayer = nil, nil
  for _, intent in ipairs(assert(view.objects, "the area carries its intents")) do
    if intent.subject == "marker" and intent.x == 148 and intent.y == 76 then
      checkIntentShape(intent)
      foundExtra = intent
    elseif intent.subject == "player" then
      foundPlayer = intent
    end
  end
  foundExtra = assert(foundExtra, "the extra marker paints as a shape-0 marker")
  Assert.equal(foundExtra.choice, "shape0", "the extra paints its authored silhouette")
  local player = assert(foundPlayer, "the area projects its trainer pin")
  Assert.equal(player.choice, "male-here", "the pin inside the extra marker reports inside")
  controller:dispose()
end

-- Entry tab switches fade out/in and flash the pressed tab: the page
-- swaps at once for logic while the shared fade envelope covers the
-- swap and the 4-tick flash names the pressed control.
function T.entry_tab_switch_fades_and_flashes_the_pressed_tab()
  local PokedexController = requirePresent("entry tab fade and flash")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "EEVEE", personality = 31 }, "caught")
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  openEntry(controller, "EEVEE")
  press(controller, { { type = "activate", action = "entry-tab", value = "size" } })
  local view = controller:view()
  Assert.equal(view.page, "size", "the tab switch lands on the size page")
  Assert.equal(view.visual.transition.phase, "fade", "the tab switch starts the fade envelope")
  Assert.equal(#view.visual.paletteFades, 2, "the fade publishes both pane fades")
  Assert.isTrue(view.visual.paletteFades[1].coeff > 0, "the fade starts away from zero")
  Assert.isTrue(view.visual.flash.active, "the pressed tab flashes")
  Assert.equal(view.visual.flash.target, "entry-tab:size", "the flash names the pressed tab")
  idle(controller, 4)
  Assert.isFalse(controller:view().visual.flash.active, "the pressed flash clears after 4 ticks")
  idle(controller, 8)
  local settled = controller:view().visual
  Assert.equal(settled.transition.phase, "rest", "the fade envelope settles back to rest")
  Assert.equal(#settled.paletteFades, 0, "the settled fade publishes no panes")
  controller:dispose()
end

-- The size restart rebuilds the check under the same fade envelope and
-- flashes its restart control for 4 ticks.
function T.size_restart_fades_and_flashes_its_control()
  local PokedexController = requirePresent("size restart fade and flash")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "EEVEE", personality = 31 }, "caught")
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  openEntry(controller, "EEVEE")
  press(controller, { { type = "activate", action = "entry-tab", value = "size" } })
  idle(controller, 10)
  press(controller, { { type = "activate", action = "size-restart" } })
  local view = controller:view()
  Assert.equal(view.page, "size", "the restart stays on the size page")
  Assert.equal(view.size.weight.phase, "setup", "the restart rebuilds the check")
  Assert.equal(view.visual.transition.phase, "fade", "the restart starts the fade envelope")
  Assert.isTrue(view.visual.flash.active, "the restart control flashes")
  Assert.equal(view.visual.flash.target, "size-restart", "the flash names the restart control")
  idle(controller, 4)
  Assert.isFalse(controller:view().visual.flash.active, "the restart flash clears after 4 ticks")
  controller:dispose()
end

-- The search feedback gates match the compiled sprite animation dwell
-- totals: label 28, rise 52, retract 20, with the verifiable 32-tick
-- hold and the 60-tick empty timeout kept as fixed policy ticks.
function T.search_feedback_gates_match_their_authored_animation_dwells()
  local PokedexController = requirePresent("search feedback gate constants")
  Assert.equal(PokedexController.FEED_LABEL_TICKS, 28, "the label gate matches its animation dwell")
  Assert.equal(PokedexController.FEED_RISE_TICKS, 52, "the rise gate matches its animation dwell")
  Assert.equal(PokedexController.FEED_RETRACT_TICKS, 20, "the retract gate matches its animation dwell")
  Assert.equal(PokedexController.FEED_HOLD_TICKS, 32, "the hold keeps its verifiable wait")
  Assert.equal(PokedexController.FEED_TIMEOUT_TICKS, 60, "the empty timeout keeps its verifiable wait")
end

-- Held comparison gestures that move nothing stay silent: with two forms
-- key cycling, touch cycling, and reselecting the active side change no
-- index and drain no cursor or touch tone.
function T.unmoved_comparison_gestures_stay_silent()
  local PokedexController = requirePresent("quiet comparison gestures")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "PICHU", personality = 127, form = 0 }, "seen")
  observe(owner, monCatalog, { species = "PICHU", personality = 0, form = 0 }, "seen")
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  openEntry(controller, "PICHU")
  press(controller, { { type = "activate", action = "entry-tab", value = "forms" } })
  Assert.equal(#controller:view().forms.variants, 2, "the pair list carries two seen forms")
  press(controller, { { type = "activate", action = "compare" } })
  Assert.notNil(controller:view().forms.comparison, "the touch compare opens the two-form comparison")
  Assert.deepEqual(
    controller:view().forms.comparison.indices,
    { 0, 1 },
    "the pair starts from the current row outward"
  )
  controller:drainEffects()
  press(controller, { { type = "navigate", direction = "up" } })
  Assert.deepEqual(drainSoundRoles(controller), {}, "key cycling a pair stays silent")
  press(controller, { { type = "navigate", direction = "down" } })
  Assert.deepEqual(drainSoundRoles(controller), {}, "key cycling a pair the other way stays silent")
  press(controller, { { type = "activate", action = "compare-cycle", side = 0, delta = 1 } })
  Assert.deepEqual(drainSoundRoles(controller), {}, "touch cycling a pair stays silent")
  press(controller, { { type = "activate", action = "compare-side", value = 0 } })
  Assert.deepEqual(drainSoundRoles(controller), {}, "reselecting the active side stays silent")
  Assert.deepEqual(controller:view().forms.comparison.indices, { 0, 1 }, "the quiet gestures keep both indices")
  Assert.equal(controller:view().forms.comparison.activeSide, 0, "the quiet gestures keep the active side")
  controller:dispose()
end

-- Moved comparison gestures keep their tones: with three forms each key
-- cycle and side switch plays one cursor tone and each touch cycle and
-- side selection plays one touch tone, with the indices tracking them.
function T.moved_comparison_gestures_keep_their_key_and_touch_tones()
  local PokedexController = requirePresent("moved comparison gestures")
  local monCatalog, catalog = catalogs()
  local owner = ownerWithFlags(monCatalog, catalog, { dexEnabled = true, nationalDex = true })
  observe(owner, monCatalog, { species = "PICHU", personality = 127, form = 0 }, "seen")
  observe(owner, monCatalog, { species = "PICHU", personality = 0, form = 0 }, "seen")
  observe(owner, monCatalog, { species = "PICHU", personality = 0, form = 1 }, "caught")
  local controller = PokedexController.new(baseArgs(owner, monCatalog, catalog))
  openGrid(controller)
  openEntry(controller, "PICHU")
  press(controller, { { type = "activate", action = "entry-tab", value = "forms" } })
  Assert.equal(#controller:view().forms.variants, 3, "the pichu list carries three seen forms")
  press(controller, { { type = "confirm" } })
  Assert.notNil(controller:view().forms.comparison, "confirming the list opens the comparison")
  local startFirst = controller:view().forms.comparison.indices[1]
  local startSecond = controller:view().forms.comparison.indices[2]
  controller:drainEffects()
  press(controller, { { type = "navigate", direction = "down" } })
  Assert.deepEqual(drainSoundRoles(controller), { "SEQ_SE_GS_ZKN03" }, "a key cycle plays one cursor tone")
  local stepped = controller:view().forms.comparison.indices
  Assert.isTrue(
    stepped[1] ~= startFirst or stepped[2] ~= startSecond,
    "the key cycle moves an index"
  )
  press(controller, { { type = "navigate", direction = "right" } })
  Assert.equal(controller:view().forms.comparison.activeSide, 1, "the key switch moves the active side")
  Assert.deepEqual(drainSoundRoles(controller), { "SEQ_SE_GS_ZKN03" }, "a key side switch plays one cursor tone")
  press(controller, { { type = "activate", action = "compare-cycle", side = 1, delta = 1 } })
  Assert.deepEqual(drainSoundRoles(controller), { "SEQ_SE_GS_ZKN04" }, "a touch cycle plays one touch tone")
  local touched = controller:view().forms.comparison.indices
  Assert.isTrue(
    touched[1] ~= stepped[1] or touched[2] ~= stepped[2],
    "the touch cycle moves an index"
  )
  press(controller, { { type = "activate", action = "compare-side", value = 0 } })
  Assert.equal(controller:view().forms.comparison.activeSide, 0, "the touch selection moves the active side")
  Assert.deepEqual(drainSoundRoles(controller), { "SEQ_SE_GS_ZKN04" }, "a touch side selection plays one touch tone")
  controller:dispose()
end

return { tests = T }
