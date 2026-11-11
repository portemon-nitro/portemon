-- The sole ordinary field Easy Chat factory: snapshots availability
-- from the live Dex, story, and unlock owners, constructs the retail
-- policy controller over the detached menu, acquires the late-bound
-- per-open lease, and builds the per-open screen. Only the controller,
-- screen, and lease are newly owned; audio stays optional in the same
-- headless sense as the existing summary closure. Construction is
-- exception safe: a failed open releases what it acquired and raises the
-- real cause before host input is captured.

local EasyChatController = require("game.hgss.src.easychat.EasyChatController")
local EasyChatScreenState = require("game.hgss.src.easychat.EasyChatScreenState")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local FieldFontLoader = require("libs.hgss.src.ui.FieldFontLoader")

---@class EasyChatComposition
local EasyChatComposition = {}

---@param runtime table<string, unknown> the owning field runtime
---@param catalog table<string, unknown> the borrowed shared word catalog
---@return { gameCleared: boolean, seen: table<string, boolean>, greetings: integer, trendy: integer }
local function snapshotAvailability(runtime, catalog)
  local state = assert(runtime.easyChatState, "the editor factory borrows the saved word state")
  local unlocks = state:readUnlocks()
  local dex = assert(runtime.dexKnowledge, "the editor factory reads the live Dex knowledge")
  assert(type(dex.isSeen) == "function", "the Dex knowledge answers species sightings")
  local events = assert(runtime.eventState, "the editor factory reads the live event store")
  assert(type(events.isFlagSet) == "function", "the event store answers flag queries")
  local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
  local gameCleared = events:isFlagSet(FieldScriptSymbols.flagsByName.FLAG_GAME_CLEAR) == true
  local seen = {}
  local okKeys, keys = pcall(catalog.seenSpeciesKeys, catalog)
  if okKeys and type(keys) == "table" then
    for _, key in ipairs(keys) do
      local okSeen, sighted = pcall(dex.isSeen, dex, key)
      if okSeen and sighted == true then
        seen[key] = true
      end
    end
  end
  return {
    gameCleared = gameCleared,
    seen = seen,
    greetings = unlocks.greetings,
    trendy = unlocks.trendy,
  }
end

---@param runtime table<string, unknown> the owning field runtime
---@param request table<string, unknown> validated open request
---@return table<string, unknown> the complete usable field editor screen
function EasyChatComposition.open(runtime, request)
  assert(type(runtime) == "table", "the editor factory needs its owning runtime")
  assert(type(request) == "table", "the editor factory requires its open request")
  local catalog = assert(runtime.easyChatCatalog, "the editor factory borrows the shared word catalog")
  assert(type(catalog.buildMenu) == "function", "the editor factory reads the shared menu")
  local state = assert(runtime.easyChatState, "the editor factory borrows the saved word state")
  assert(type(state.readUnlocks) == "function", "the editor factory reads the saved unlocks")
  local availability = snapshotAvailability(runtime, catalog)
  local menu = catalog:buildMenu(availability)
  local cacheFs = assert(runtime.cacheFs, "the editor factory borrows the derived asset cache")
  local font1 = FieldFontLoader.load(cacheFs, 1)
  local metrics = FieldDialogueTheme.fontMetrics(font1)
  local uiManifest = assert(runtime.uiManifest, "the editor factory reads the field UI manifest")
  local yesNo = assert(uiManifest.yesNoPrompt, "the field UI manifest carries its prompt section")
  local shapes = assert(yesNo.shapes, "the prompt section carries its shapes")
  local compact = assert(shapes.compact, "the prompt section carries its compact shape")
  local function playSequence(sequence)
    if runtime.audio ~= nil then
      runtime.audio:play(sequence)
    end
  end
  local input = runtime.input
  local function observeNavigation()
    if input == nil or type(input.lastUiNavigation) ~= "function" then
      return nil
    end
    return input:lastUiNavigation()
  end
  local controller = EasyChatController.new({
    catalog = catalog,
    request = request,
    menu = menu,
    fontMetrics = metrics,
    promptShape = compact,
    effect = playSequence,
    observe = observeNavigation,
  })
  local binding = runtime._easyChatPreparation
  if type(binding) ~= "table" or type(binding.acquire) ~= "function" then
    controller:dispose()
    error("easy chat opens require the bound preparation seam", 0)
  end
  local okLease, lease = pcall(binding.acquire)
  if not okLease then
    controller:dispose()
    error(lease, 0)
  end
  assert(type(lease) == "table", "the preparation binding acquires a per-open lease")
  local function measureDisplay()
    return assert(runtime.presentationDisplay, "the editor screen measures its display")
  end
  local overrides = runtime.presentationOverrides
  local easyChatOverrides = nil
  if type(overrides) == "table" then
    easyChatOverrides = overrides.easyChat
  end
  local okScreen, screen = pcall(EasyChatScreenState.new, {
    controller = controller,
    lease = lease,
    measureDisplay = measureDisplay,
    effect = playSequence,
    overrides = easyChatOverrides,
    catalog = catalog,
    menu = menu,
    cacheFs = cacheFs,
  })
  if not okScreen then
    local okRelease, releaseFailure = pcall(lease.release, lease)
    controller:dispose()
    if not okRelease then
      error(tostring(screen) .. "; lease release failed: " .. tostring(releaseFailure), 0)
    end
    error(screen, 0)
  end
  return screen
end

return EasyChatComposition
