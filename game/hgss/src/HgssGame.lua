-- Composes the concrete HeartGold/SoulSilver application over the generic game host.

local Game = require("game.src.Game")
local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
local SaveFs = require("libs.storage.src.SaveFs")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local NewGame = require("game.hgss.src.newgame.NewGame")
local NewGameInitialization = require("game.hgss.src.newgame.NewGameInitialization")
local FirstPlayCachePreparation = require("game.hgss.src.newgame.FirstPlayCachePreparation")
local NewGamePreparationState = require("game.hgss.src.newgame.NewGamePreparationState")
local PreparedFieldEntry = require("game.hgss.src.field.PreparedFieldEntry")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldPreparationState = require("game.hgss.src.field.FieldPreparationState")
local OakIntroComposition = require("game.hgss.src.newgame.OakIntroComposition")
local CacheFs = require("libs.storage.src.CacheFs")
local DisplayContext = require("libs.ui.src.DisplayContext")
local FieldMapLoader = require("libs.hgss.src.world.FieldMapLoader")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MonCache = require("libs.assets.src.MonCache")
local MonCatalog = require("libs.mons.src.MonCatalog")
local ItemCache = require("libs.assets.src.ItemCache")
local ItemCatalog = require("libs.items.src.ItemCatalog")

---@class HgssGameOptions
---@field versionId string
---@field entry HgssGameEntry
---@field onExit fun(result: table<string, unknown>|nil)
---@field development boolean?
---@field derivedAssets table<string, function> semantic derived-asset host for gated field entry
---@field fieldMapLoader table<string, unknown>? borrowed metadata-only loader for entry planning
---@field topologyProvider (fun(width: number, height: number): ScreenTopology)? actual host surfaces for every entry route
---@field presentationOverrides table<string, table<string, unknown>>? per-case function overrides by application
---@field martStockResolver (fun(descriptor: table<string, unknown>, context: table<string, unknown>, catalog: table<string, unknown>): table<string, unknown>)? optional game-root mart stock provider

---@class HgssGameNewGameEntry
---@field kind "new_game"

---@class HgssGameContinueEntry
---@field kind "continue"
---@field saveId string

---@alias HgssGameEntry HgssGameNewGameEntry|HgssGameContinueEntry

local HgssGame = {}

local function fieldStateOptions(options, saveStore, extra, shared)
  local fieldOptions = {
    development = options.development == true,
    saveStore = saveStore,
    derivedAssets = options.derivedAssets,
    martStockResolver = options.martStockResolver,
  }
  if extra then
    for key, value in pairs(extra) do
      fieldOptions[key] = value
    end
  end
  if shared then
    for key, value in pairs(shared) do
      fieldOptions[key] = value
    end
  end
  return fieldOptions
end

local function newGameCandidate(saveStore, versionId)
  -- The domain catalog behind the unpublished mons bucket resolves lazily
  -- inside candidate construction, so application routing never touches
  -- cache IO: the catalog gates bucket creation while the bucket itself
  -- carries no catalog identity.
  local function loadMonCatalog()
    local cacheFs = CacheFs.forVersion(versionId)
    return MonCatalog.new(MonCache.loadCatalog(cacheFs), ItemCatalog.new(ItemCache.loadCatalog(cacheFs)))
  end
  return NewGame.createCandidate({
    saveService = saveStore,
    versionId = versionId,
    eventState = FieldEventState.new(),
    scriptSymbols = FieldScriptSymbols,
    mapIdentity = NewGameInitialization.initialLocation(versionId),
    catalogLoader = loadMonCatalog,
    nowSeconds = os.time(),
  })
end

-- Validates and copies the product-root override record once: only the
-- four case function fields merge per application, unknown case keys and
-- non-functions fail at composition. Unknown application entries ride
-- along copied for their owning slice; each owner consumes only its entry.
---@param overrides table<string, unknown>?
---@return table<string, table<string, fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown>>>?
local function copyPresentationOverrides(overrides)
  if overrides == nil then
    return nil
  end
  assert(type(overrides) == "table", "presentation overrides must be a record")
  local cases = { dualDisplay = true, nativeLike = true, wide = true, tall = true }
  local copied = {}
  for applicationId, entry in pairs(overrides) do
    assert(type(entry) == "table", "the overrides for " .. tostring(applicationId) .. " must be a record")
    local entryCopy = {}
    for key, fn in pairs(entry) do
      assert(cases[key] == true, "unknown presentation override case " .. tostring(key))
      assert(type(fn) == "function", "the override for " .. tostring(key) .. " must be a function")
      entryCopy[key] = fn
    end
    copied[applicationId] = entryCopy
  end
  return copied
end

---@param options HgssGameOptions
---@param game Game
---@param saveStore table<string, unknown>
---@param versionId string
local function installRoutes(options, game, saveStore, versionId)
  -- One actual-display measurement owner and one copied override record
  -- for each retail route, shared by field and Oak presentation.
  local displayContext = DisplayContext.new({ topologyProvider = options.topologyProvider })
  local presentationOverrides = copyPresentationOverrides(options.presentationOverrides)
  local derivedAssets = assert(options.derivedAssets, "HgssGame requires the derived-asset host")
  local oakPrepared -- forward: the Oak lifetime owns the staged bedroom entry
  local function returnToMainMenu()
    game:exit({ kind = "main_menu" })
  end
  local function enterField(record, extraOptions)
    game:setState(FieldState.new(
      record,
      fieldStateOptions(options, saveStore, extraOptions, {
        displayContext = displayContext,
        presentationOverrides = presentationOverrides,
      })
    ))
  end
  local function entryLoader()
    -- The borrowed composition loader plans entry geometry; otherwise a
    -- temporary metadata-only loader over the version cache. Planning
    -- acquires no entries, scenes, or GPU resources through it.
    if options.fieldMapLoader ~= nil then
      return assert(options.fieldMapLoader)
    end
    local cacheFs = CacheFs.forVersion(versionId)
    -- This factory runs once entry planning is ready, so a missing
    -- manifest is a visible preparation failure, not a manual prerequisite:
    -- the preparation state latches the returned diagnostic instead of
    -- entering the field.
    local world, worldError = cacheFs:loadLua(MapAssetCache.worldPath())
    if world == nil then
      return nil, worldError or "field world metadata is unavailable although entry planning is ready"
    end
    return FieldMapLoader.new(cacheFs, world, { derivedAssets = derivedAssets })
  end
  local function enterPreparation(preparationOptions)
    game:setState(FieldPreparationState.new({
      kind = preparationOptions.kind,
      saveId = preparationOptions.saveId,
      candidate = preparationOptions.candidate,
      versionId = versionId,
      derivedAssets = derivedAssets,
      saveStore = saveStore,
      createLoader = entryLoader,
      enterField = enterField,
      onCancel = returnToMainMenu,
    }))
  end

  local function locationMatches(a, b)
    return type(a) == "table"
      and type(b) == "table"
      and a.mapSymbol == b.mapSymbol
      and a.fieldX == b.fieldX
      and a.fieldZ == b.fieldZ
  end

  local function onOakComplete(result)
    assert(type(result) == "table" and result.playerData ~= nil, "Oak intro completed without a finalized game")
    -- Initialization applies exactly once to the finalized candidate before
    -- the staged bedroom transfers into the field; waiting updates never
    -- apply it again.
    local finalized = NewGameInitialization.apply(result)
    -- The bedroom was staged for the candidate opening: a diverging
    -- finalized location is a route/data invariant failure, never a silent
    -- rebuild behind a second preparation screen.
    local prepared = assert(oakPrepared, "Oak completed without its prepared field entry")
    oakPrepared = nil
    assert(
      locationMatches(finalized.location, prepared.location),
      "finalized New Game location diverges from the prepared field entry"
    )
    local transfer = prepared:take()
    -- Construction is binary: the field installs directly behind the
    -- covered-entry reveal, and a failure releases the unclaimed transfer
    -- exactly once before propagating.
    local okField, fieldErr = pcall(enterField, finalized, { preparedEntry = transfer, initialFadeIn = true })
    if not okField then
      transfer:dispose()
      error(fieldErr, 0)
    end
  end

  local function bootOakIntro()
    local candidate = newGameCandidate(saveStore, versionId)
    -- The actual opening bedroom stages while the intro plays: the Oak
    -- state polls the entry every update and the final black handoff waits
    -- for its readiness, so the handoff transfers resident resources
    -- directly into the field. The Oak state owns the entry from
    -- composition on; a failed composition releases it here so no
    -- half-built staging escapes.
    local prepared = PreparedFieldEntry.new({
      versionId = versionId,
      derivedAssets = derivedAssets,
      location = candidate.location,
    })
    oakPrepared = prepared
    prepared:poll()
    local ok, stateOrError = pcall(OakIntroComposition.compose, {
      candidate = candidate,
      versionId = versionId,
      onComplete = onOakComplete,
      displayContext = displayContext,
      namingOverrides = presentationOverrides ~= nil and presentationOverrides.naming or nil,
      preparedEntry = prepared,
    })
    if not ok then
      if oakPrepared == prepared then
        oakPrepared = nil
      end
      prepared:dispose()
      error(stateOrError, 0)
    end
    game:setState(stateOrError)
  end

  local function startNewGame()
    -- New Game waits for its semantic intro closure: the candidate and
    -- Oak composition run only inside the ready transfer, so a cold
    -- partial cache shows preparation instead of missing-asset failure.
    game:setState(NewGamePreparationState.new({
      derivedAssets = derivedAssets,
      onReady = bootOakIntro,
      onCancel = returnToMainMenu,
    }))
  end

  if options.entry.kind == "new_game" then
    startNewGame()
  else
    -- Continue enters preparation immediately: the preparation state
    -- loads the saved record at once and overlaps destination demand
    -- with static runtime readiness.
    enterPreparation({ kind = "continue", saveId = options.entry.saveId })
  end
end

-- App-facing first-play preparation for the import path: builds
-- the HGSS semantic-demand coordinator over the borrowed provisioner
-- host. No milestone/location policy lives here; the coordinator owns
-- which closures constitute first play. The optional completion gateway
-- carries the durable attestation answers owned by the import
-- orchestration boundary; the fresh-import path omits it and always
-- compiles the closure.
---@param options { versionId: string, derivedAssets: table<string, function>, completion: table<string, function>? }
---@return FirstPlayCachePreparation
function HgssGame.newFirstPlayCachePreparation(options)
  return FirstPlayCachePreparation.new(options)
end

---@param options HgssGameOptions
---@return Game
function HgssGame.new(options)
  assert(type(options) == "table", "HgssGame requires options")
  local versionId = assert(options.versionId, "HgssGame requires a versionId")
  assert(type(versionId) == "string" and versionId ~= "", "HgssGame versionId is invalid")
  assert(type(options.onExit) == "function", "HgssGame requires an onExit callback")
  local entry = options.entry
  assert(type(entry) == "table", "HgssGame requires an explicit entry")
  if entry.kind ~= "new_game" then
    assert(entry.kind == "continue", "HgssGame entry kind is invalid")
    assert(type(entry.saveId) == "string" and entry.saveId ~= "", "Continue entry saveId is invalid")
  end

  local game = Game.new({ onExit = options.onExit })

  local saveStore = GameSaveStore.new(SaveFs.global())
  installRoutes(options, game, saveStore, versionId)
  return game
end

return HgssGame
