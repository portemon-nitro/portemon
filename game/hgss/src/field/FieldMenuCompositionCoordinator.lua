-- Owns the field runtime's menu/presentation-surface composition: the start
-- menu, the Bag/Pokemon menu join, the application catalogue the start menu
-- dispatches into, the follower-transition owner, and the field audio
-- composition.

local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local FieldAudio = require("game.hgss.src.audio.FieldAudio")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FollowingMonTransitionController = require("libs.hgss.src.field.FollowingMonTransitionController")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local PcCache = require("libs.assets.src.PcCache")
local MenuProtocol = require("libs.assets.src.MenuProtocol")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")
local StartMenuPolicy = require("libs.hgss.src.ui.StartMenuPolicy")
local StartMenuState = require("game.hgss.src.field.StartMenuState")
local TextSpeedPolicy = require("libs.hgss.src.ui.TextSpeedPolicy")
local TimeOfDayProps = require("libs.hgss.src.presentation.TimeOfDayProps")
local TrainerCardScreenState = require("game.hgss.src.field.TrainerCardScreenState")

-- The audio-output sample rate of the production composition (the mixer and
-- the LÖVE sink render at this rate, the DS SPU rate; source waves are
-- ratio-scaled, so the pitch is preserved at any output rate).
local AUDIO_SAMPLE_RATE = 32768

-- Builds headless follower-transition part instances: deterministic frame
-- counters with the controller's timing contract and no GPU state.
-- Presentation replaces this factory with renderer-backed model instances.
local function headlessTransitionFactory()
  local function buildPart(part, descriptor)
    local frameCount = 0
    if part == "animated" then
      local animations = descriptor.animations
      assert(type(animations) == "table", "transition animated part requires its clip")
      local clip = animations[1]
      assert(type(clip) == "table" and type(clip.frameCount) == "number", "transition clip requires its frame count")
      frameCount = clip.frameCount
    end
    local player = { part = part, frame = 0, frameCount = frameCount, complete = false, disposed = false }
    function player:updateFixed()
      self.frame = self.frame + 1
      if self.frame >= self.frameCount then
        self.complete = true
      end
    end
    function player:isComplete()
      return self.complete
    end
    function player:reset()
      self.frame = 0
      self.complete = false
    end
    function player:dispose()
      self.disposed = true
    end
    return player
  end
  return buildPart
end

-- Cardinal facing deltas for the facing-tile read below.
local MENU_FACING_DELTAS = {
  north = { fieldX = 0, fieldZ = -1 },
  south = { fieldX = 0, fieldZ = 1 },
  west = { fieldX = -1, fieldZ = 0 },
  east = { fieldX = 1, fieldZ = 0 },
}

-- Helper: determine if this port has implemented the destination application
-- for an action kind.
local function implementationAvailable(runtime, entry)
  if entry.actionKind == "field_action" then
    return entry.id == "vanilla.save" and runtime.saveStore ~= nil
  end
  if entry.actionKind == "application" then
    return entry.targetApplication ~= nil and runtime.applications:has(entry.targetApplication)
  end
  return false
end

---@class FieldMenuCompositionCoordinator
---@field runtime FieldRuntime
local FieldMenuCompositionCoordinator = {}
FieldMenuCompositionCoordinator.__index = FieldMenuCompositionCoordinator

---@param runtime FieldRuntime
---@return FieldMenuCompositionCoordinator
function FieldMenuCompositionCoordinator.new(runtime)
  return setmetatable({ runtime = runtime }, FieldMenuCompositionCoordinator)
end

-- The field application catalogue: the registry holds child destinations
-- only, and the runtime registers the production destinations itself. Each
-- factory must return a fully usable controller or raise. The catalogue is
-- immutable after construction; canonical unimplemented destinations get
-- capability state, never dummy factories. The Start Menu is not a registry
-- entry: the application host composes it through its own menu factory.
-- A method (rather than an inline block in _load) so the boot closure stays
-- under the VM upvalue limit: file-level owners are upvalues of this small
-- method instead of the giant boot function.
---@return { id: string, factory: fun(...): table<string, unknown> }[] application descriptors for FieldApplicationRegistry.new
function FieldMenuCompositionCoordinator:applicationDescriptors()
  local runtime = self.runtime
  local function playSequence(sequence)
    if runtime.audio then
      runtime.audio:play(sequence)
    end
  end
  local function trainerCardFactory()
    -- The Trainer Card factory wraps the close-input-only controller in
    -- its presentation session, keeping the authoritative profile fields
    -- with the existing controller ownership.
    local cardOverrides = runtime.presentationOverrides ~= nil and runtime.presentationOverrides.trainer_card or nil
    local function measureDisplay()
      return runtime.presentationDisplay
    end
    return TrainerCardScreenState.new({
      profile = runtime.playerData.profile,
      playTimeSeconds = runtime.playTime:seconds(),
      effect = playSequence,
      measureDisplay = measureDisplay,
      overrides = cardOverrides,
    })
  end
  local function partyScreenFactory()
    local composition = assert(runtime.pokemonMenu, "the pokemon application requires the menu composition")
    return composition.makePartyFlow()
  end
  local function bagFactory()
    local composition = assert(runtime.pokemonMenu, "the bag application requires the menu composition")
    return composition.makeBagFlow()
  end
  return {
    {
      id = FieldApplicationIds.TRAINER_CARD,
      factory = trainerCardFactory,
    },
    {
      id = FieldApplicationIds.POKEMON,
      factory = partyScreenFactory,
    },
    {
      id = FieldApplicationIds.BAG,
      factory = bagFactory,
    },
  }
end

-- The Start Menu composition step: build the final action list from the
-- authoritative world-state unlock flags (read through FieldScriptSymbols,
-- never raw numbers) and the registered destination capabilities. The source
-- policy produces source-present entries; the runtime separates source
-- enablement from implementation capability and combines them to set the final
-- enabled state. Construct the controller with the selection remembered
-- across a child-application round trip. Return nil only when no source-present
-- actions exist; disabled entries are visible and remain in the menu.
---@param rememberedActionId string?
---@return StartMenuState? nil when the source has no present actions
function FieldMenuCompositionCoordinator:composeStartMenu(rememberedActionId)
  local runtime = self.runtime
  local world = runtime.scripts.worldState
  local flags = FieldScriptSymbols.flagsByName

  -- Source policy: returns all present actions (regardless of implementation)
  local sourceEntries = StartMenuPolicy.actions({
    hasPokedex = world:isFlagSet(flags.FLAG_GOT_POKEDEX),
    hasStarter = world:isFlagSet(flags.FLAG_GOT_STARTER),
    bagUnlocked = world:isFlagSet(flags.FLAG_GOT_BAG),
    hasPokegear = world:isFlagSet(flags.FLAG_GOT_POKEGEAR),
    trainerCardUnlocked = world:isFlagSet(flags.FLAG_GOT_TRAINER_CARD),
    saveUnlocked = world:isFlagSet(flags.FLAG_GOT_SAVE_BUTTON),
    optionsUnlocked = world:isFlagSet(flags.FLAG_GOT_OPTIONS_BUTTON),
  })

  if #sourceEntries == 0 then
    return nil
  end

  local function playMenuSequence(sequence)
    if runtime.audio then
      runtime.audio:play(sequence)
    end
  end

  -- Compose source policy with implementation capability: set enabled to
  -- true only when both source-enabled AND implementation-available. The
  -- party action additionally requires an owned mon: an empty party must
  -- never offer a usable route into the party screen, even past the
  -- starter progression gate.
  --
  -- The normal visual composition admits exactly the icon-backed entries:
  -- the manifest's action-to-icon map for the normal context intersects the
  -- source-present policy list. The cancel sentinel and the bookkeeping
  -- specials carry no icon slot, so they stay source-policy facts but are
  -- not visual buttons. Icon-backed entries keep their source and
  -- implementation enabled state (a disabled visual entry renders and
  -- confirms as a no-op). Labels resolve per icon-table row: the
  -- player-name row carries the live player name, never baked text; static
  -- rows resolve their label-bank message through the pinned source label
  -- bank (a missing bank or message id is a composition failure, never an
  -- unlabeled icon).
  local startMenuSection =
    assert(runtime.uiManifest.startMenu, "the field UI manifest must carry the start menu section")
  local actionIcons = assert(startMenuSection.actionIcons, "the field UI manifest must carry the start menu action map")
  local iconTable = assert(startMenuSection.iconTable, "the field UI manifest must carry the start menu icon table")
  local profile =
    assert(runtime.playerData and runtime.playerData.profile, "the start menu requires the player profile")
  local playerName = assert(profile.name, "the start menu requires the player name")
  local entries = {}
  for _, source in ipairs(sourceEntries) do
    local icon = actionIcons[source.id]
    if icon ~= nil then
      local implemented = implementationAvailable(runtime, source)
      local enabled = source.sourceEnabled and implemented
      if enabled and source.id == "vanilla.pokemon" then
        enabled = runtime.monService:partyCount() > 0
      end
      if enabled and source.id == "vanilla.bag" then
        enabled = runtime.bagService ~= nil and runtime.bagCursor ~= nil and runtime.itemCatalog ~= nil
      end
      local row = assert(iconTable[icon + 1], "action " .. source.id .. " maps outside the start menu icon table")
      local label
      if row.labelKind == "player_name" then
        label = playerName
      else
        assert(type(row.label) == "number", "action " .. source.id .. " has no static start menu label")
        local template, labelErr = runtime.messageProvider:get(MenuProtocol.START_MENU_MESSAGE_BANK, row.label)
        if template == nil then
          error(labelErr, 0)
        end
        label = template.text
      end
      entries[#entries + 1] = {
        id = source.id,
        displayPosition = source.displayPosition,
        actionKind = source.actionKind,
        targetApplication = source.targetApplication,
        sourcePresent = true,
        sourceEnabled = source.sourceEnabled,
        implemented = implemented,
        enabled = enabled,
        icon = icon,
        label = label,
      }
    end
  end

  if #entries == 0 then
    return nil
  end

  local startMenuInteractive =
    assert(startMenuSection.interactive, "the field UI manifest must carry the start menu interactive record")
  local startMenuOverrides = runtime.presentationOverrides ~= nil and runtime.presentationOverrides.start_menu or nil
  local function measureDisplay()
    return runtime.presentationDisplay
  end
  return StartMenuState.new({
    entries = entries,
    interactive = startMenuInteractive,
    rememberedActionId = rememberedActionId,
    effect = playMenuSequence,
    measureDisplay = measureDisplay,
    overrides = startMenuOverrides,
  })
end

-- Composes the one live Bag service and the runtime-only field cursor
-- outside the boot closure (which sits close to LuaJIT's per-function
-- upvalue limit). The bucket is the validated continue record or the
-- unpublished new-game bucket; a missing bucket fails loudly instead of
-- synthesizing an empty bag at boot.
---@param activeGame table<string, unknown>
---@param loadedGame table<string, unknown>?
function FieldMenuCompositionCoordinator:composeBag(activeGame, loadedGame)
  local runtime = self.runtime
  local HgssBagService = require("libs.hgss.src.items.HgssBagService")
  local BagCursor = require("libs.hgss.src.items.BagCursor")
  local bucket = loadedGame and loadedGame.bag or assert(activeGame.bag, "finalized game bag bucket is required")
  runtime.bagService = HgssBagService.new({ catalog = runtime.itemCatalog, bag = bucket })
  runtime.bagCursor = BagCursor.new()
end

-- Builds the explicit read-only Summary display context per open: the
-- trainer profile identity, the captured civil day, regional Dex mode
-- (no national-Dex owner exists on this path), zero aprijuice modifiers
-- for each current party member (no Aprijuice persistence exists here),
-- performance enablement from the world flag, and the source-initial
-- special-ribbon descriptions resolved through the message bank. These
-- current-owner limits are explicit values, never inferred flags.
---@param innerRuntime table<string, unknown> the live field runtime
---@param manifest table<string, unknown> the validated summary family
---@return fun(): table<string, unknown> context provider
local function summaryContextProvider(innerRuntime, manifest)
  local performance = assert(manifest.performance, "the summary family carries performance rules")
  assert(type(performance) == "table", "performance rules are a record")
  local zero = assert(performance.zeroAprijuice, "performance rules carry the zero modifiers")
  assert(type(zero) == "table", "zero modifiers are a record")
  local ribbons = assert(manifest.ribbons, "the summary family carries ribbon definitions")
  assert(type(ribbons) == "table", "ribbon definitions are a record")
  local initials =
    assert(ribbons.initialSpecialDescriptions, "ribbon definitions carry the source-initial special descriptions")
  assert(type(initials) == "table", "initial special descriptions are a record")
  local choices = assert(ribbons.descriptionChoices, "ribbon definitions carry description choices")
  assert(type(choices) == "table", "description choices are a record")
  local bank = assert(choices.base, "description choices carry their message bank")
  assert(type(bank) == "number", "description message banks are numeric")
  local function provide()
    local playerData = assert(innerRuntime.playerData, "the menu composition requires the player data")
    local profile = assert(playerData.profile, "the menu composition requires the player profile")
    local day = assert(innerRuntime.localClock, "the menu composition requires its clock"):nowLocal().day
    assert(type(day) == "number", "the civil day stays numeric")
    local eventState = assert(innerRuntime.eventState, "the menu composition requires the event state")
    local performanceEnabled = eventState:isFlagSet(FieldScriptSymbols.flagsByName.FLAG_UNK_982) == true
    local count = assert(innerRuntime.monService, "the menu composition requires the mon service"):partyCount()
    assert(type(count) == "number" and count >= 1, "summary contexts need a non-empty party")
    local rows = {}
    for _ = 1, count do
      rows[#rows + 1] = {
        power = zero.power,
        stamina = zero.stamina,
        skill = zero.skill,
        jump = zero.jump,
        speed = zero.speed,
      }
    end
    local provider = assert(innerRuntime.messageProvider, "special descriptions resolve through messages")
    local specials = {}
    for slot = 1, 14 do
      local initial = initials[slot]
      if type(initial) == "string" and initial ~= "" then
        specials[slot] = initial
      else
        assert(type(initial) == "number", "source-initial special selections stay numeric")
        local template, messageErr = provider:get(bank, initial)
        assert(template ~= nil, "special-ribbon message unavailable: " .. tostring(messageErr))
        local text = assert(template.text, "special-ribbon messages carry text")
        assert(type(text) == "string" and text ~= "", "special-ribbon messages carry display text")
        specials[slot] = text
      end
    end
    return {
      profile = { trainerId = profile.trainerId, name = profile.name, gender = profile.gender },
      dayOfMonth = day,
      dexMode = "regional",
      performanceEnabled = performanceEnabled,
      aprijuiceBySlot = rows,
      specialRibbonDescriptions = specials,
    }
  end
  return provide
end

-- Composes the one live Pokemon menu composition outside the boot
-- closure (which sits close to LuaJIT's per-function upvalue limit).
-- Joins the live mon/Bag services, manifests, display facts, and field
-- ports into PartyActions, the single field-move runtime/world pair,
-- and Bag/Party flow factories. Missing collaborators fail loudly
-- instead of opening half-built menus.
---@param cacheFs table<string, unknown> version cache reader for cited spawn landings
function FieldMenuCompositionCoordinator:composePokemonMenu(cacheFs)
  local runtime = self.runtime
  local PokemonMenuComposition = require("game.hgss.src.field.PokemonMenuComposition")
  local BagCache = require("libs.assets.src.BagCache")
  local PartyCache = require("libs.assets.src.PartyCache")
  local SummaryCache = require("libs.assets.src.SummaryCache")
  local ScriptMapsService = require("libs.hgss.src.script.ScriptMapsService")
  local avatar = assert(runtime.avatar, "the menu composition requires the player avatar")
  assert(avatar.gender == 0 or avatar.gender == 1, "the bag hero gender is unsupported")
  local heroGender = avatar.gender == 0 and "male" or "female"
  local function measureDisplay()
    return runtime.presentationDisplay
  end
  local lane = ScriptMapsService.new({
    transition = assert(runtime.transition, "menu-origin returns require the live transition"),
    loader = assert(runtime.mapLoader, "menu-origin returns require the map loader"),
    sourceMap = assert(runtime.runtimeMap, "menu-origin returns require the active map"),
  })
  runtime.menuLaneWarps = lane
  -- The warp port always serves the live map: the lane instance keeps
  -- no stale source across map swaps because every call re-reads it
  -- first. Ordinary fade lifecycle, never script-authored cover.
  local function startLaneWarp(_, target)
    lane:setSourceMap(assert(runtime.runtimeMap, "menu-origin returns require the active map"))
    return lane:startWarp(target)
  end
  local function laneWarpDone(_)
    return lane:warpDone()
  end
  local function lanePendingError(_)
    return lane:pendingError()
  end
  local function resolveLaneWarp(_, ref)
    return lane:resolve(ref)
  end
  local warps = {
    startWarp = startLaneWarp,
    warpDone = laneWarpDone,
    pendingError = lanePendingError,
    resolve = resolveLaneWarp,
  }
  local function changeLiveWeather(_, weatherId)
    runtime:_setLiveWeather(assert(runtime.runtimeMap, "flash needs the active map"), weatherId)
  end
  local function dispatchFlashReaction(_, kind)
    assert(kind == "alph_flash", "unknown field reaction " .. tostring(kind))
    -- Chamber illumination state for the compiled map content:
    -- the flash flag is the only illumination owner available.
    assert(runtime.eventState, "field reactions require the event state"):setFlag(
      FieldScriptSymbols.flagsByName.FLAG_SYS_FLASH
    )
  end
  local function readCurrentMap()
    local map = assert(runtime.runtimeMap, "field context needs the active map")
    return { symbol = map.mapSymbol, id = map.mapId, fieldUse = map.fieldData.fieldUse }
  end
  local function readRuntimeMap()
    return assert(runtime.runtimeMap, "field context needs the active map")
  end
  local worldPorts = {
    actors = assert(runtime.actors, "the menu composition requires the actor manager"),
    events = assert(runtime.eventState, "the menu composition requires the event state"),
    maps = {
      current = readCurrentMap,
      runtimeMap = readRuntimeMap,
    },
    player = self:menuPlayerPort(),
    profile = assert(
      runtime.playerData and runtime.playerData.profile,
      "the menu composition requires the player profile"
    ),
    weather = {
      change = changeLiveWeather,
    },
    reactions = {
      dispatch = dispatchFlashReaction,
    },
    warps = warps,
  }
  -- The icon preparation binding belongs to the presentation lifetime
  -- and may postdate this composition: the closures resolve it per
  -- flow construction, when a screen is actually opened.
  ---@param iconKeys string[]
  ---@return boolean, string?
  local function prepareMenuIcons(iconKeys)
    local binding = assert(runtime._partyIconPreparation, "the menu composition requires its icon preparation binding")
    return binding.prepare(iconKeys)
  end
  local function cancelMenuIconPreparation()
    local binding = assert(runtime._partyIconPreparation, "the menu composition requires its icon preparation binding")
    binding.cancel()
  end
  -- The bag's semantic sound boundary and text cadence bind once at the
  -- menu composition root: effects delegate to the composed audio service
  -- and lower modules never read player options or audio services.
  local function playBagSequence(sequence)
    if runtime.audio then
      runtime.audio:play(sequence)
    end
  end
  -- Summary cries play through the composed field audio service under
  -- the same borrowed-audio rule: a host without audio stays silent.
  local function playSummaryCry(species, pattern)
    if runtime.audio then
      runtime.audio:playCry(species, pattern)
    end
  end
  local bagTextPolicy = TextSpeedPolicy.forSpeed(
    assert(runtime.playerData and runtime.playerData.options and runtime.playerData.options.textSpeed)
  )
  local summaryManifest = SummaryCache.loadManifest(cacheFs)
  -- The preparation factory stays late-bound through the runtime
  -- because presentation resources postdate this composition: the
  -- binding resolves per summary open, when a screen is actually
  -- constructed. Navigation observes the already-created input sample
  -- without snapshotting twice.
  local function acquireSummaryPreparation()
    local binding = assert(runtime._summaryPreparation, "summary opens require the presented preparation binding")
    return binding.acquire()
  end
  local function readSummaryNavigation()
    return assert(runtime.input, "summary navigation needs the field input"):lastUiNavigation()
  end
  runtime.pokemonMenu = PokemonMenuComposition.create({
    effect = playBagSequence,
    playCry = playSummaryCry,
    textPolicy = bagTextPolicy,
    summaryManifest = summaryManifest,
    summaryContext = summaryContextProvider(runtime, summaryManifest),
    readSummaryNavigation = readSummaryNavigation,
    acquireSummaryPreparation = acquireSummaryPreparation,
    mons = assert(runtime.monService, "the menu composition requires the live mon service"),
    bag = assert(runtime.bagService, "the menu composition requires the live bag service"),
    mailbox = assert(runtime.mailbox, "the menu composition requires the live Mailbox"),
    photoAlbum = assert(runtime.photoAlbum, "the menu composition requires the live Photo Album"),
    pcManifest = PcCache.loadManifest(cacheFs),
    profile = assert(
      runtime.playerData and runtime.playerData.profile,
      "the menu composition requires the player profile"
    ),
    versionId = runtime.versionId,
    cacheFs = cacheFs,
    derivedAssets = assert(runtime.derivedAssets, "the menu composition requires semantic asset access"),
    charmap = assert(
      runtime.fontDef and runtime.fontDef.charmap,
      "the menu composition requires the generated charmap"
    ),
    bagCursor = assert(runtime.bagCursor, "the menu composition requires the runtime bag cursor"),
    itemCatalog = assert(runtime.itemCatalog, "the menu composition requires the shared item catalog"),
    monCatalog = assert(runtime.monCatalog, "the menu composition requires the shared mon catalog"),
    bagManifest = BagCache.loadManifest(cacheFs),
    partyManifest = PartyCache.loadManifest(cacheFs),
    uiManifest = assert(runtime.uiManifest, "the menu composition requires the validated field-UI manifest"),
    heroGender = heroGender,
    measureDisplay = measureDisplay,
    contextSources = self:menuFieldSources(),
    worldPorts = worldPorts,
    fieldTravel = runtime.fieldTravel,
    overrides = runtime.presentationOverrides,
    prepareIcons = prepareMenuIcons,
    cancelIconPreparation = cancelMenuIconPreparation,
  })
end

-- The field world player facade over the live player and avatar: tile
-- reads from the player, avatar transitions from the avatar owner.
-- Mirrors the return-move acceptance shape; missing owners fail the
-- composition loudly instead of planning against dead ports.
---@return table<string, unknown>
function FieldMenuCompositionCoordinator:menuPlayerPort()
  local runtime = self.runtime
  local player = assert(runtime.player, "the menu composition requires the live player")
  local avatar = assert(runtime.playerAvatar, "the menu composition requires the avatar transition owner")
  local function readPosition(_)
    return { fieldX = player.fieldX, fieldZ = player.fieldZ, worldY = player.worldY }
  end
  local function readFacing(_)
    return player.facing
  end
  local function beginPlayerAction(_, action)
    return player:beginScriptedAction(action)
  end
  local function advancePlayerAction(_, progressTicks, durationTicks)
    return player:advanceScriptedAction(progressTicks, durationTicks)
  end
  local function commitPlayerAction(_)
    return player:commitScriptedAction()
  end
  local function cancelPlayerMovement(_)
    return player:cancelScriptedMovement()
  end
  local function playerMoving(_)
    return player:isScriptedMoving()
  end
  local function queuePlayerTransition(_, name)
    return avatar:queueTransition(name)
  end
  local function applyPlayerTransitions(_)
    return runtime:applyAvatarTransitions()
  end
  return {
    position = readPosition,
    facing = readFacing,
    beginScriptedAction = beginPlayerAction,
    advanceScriptedAction = advancePlayerAction,
    commitScriptedAction = commitPlayerAction,
    cancelScriptedMovement = cancelPlayerMovement,
    isScriptedMoving = playerMoving,
    queueAvatarTransition = queuePlayerTransition,
    applyAvatarTransitions = applyPlayerTransitions,
  }
end

-- Live world reads for one eligibility check: badges, map identity and
-- generated policy, avatar mode, follower state, and facing-tile facts
-- resolved through the live collision and actor owners. States with no
-- owner in this engine (human escorts, costumes, safari/park zones,
-- recording input, weather fog for the out-of-scope Defog check) read
-- as their absent value with the reason beside them.
---@return fun(): table<string, unknown>
function FieldMenuCompositionCoordinator:menuFieldSources()
  local runtime = self.runtime
  local function readSources()
    local profile = assert(runtime.playerData and runtime.playerData.profile, "field context needs the player profile")
    local runtimeMap = assert(runtime.runtimeMap, "field context needs the active map")
    local player = assert(runtime.player, "field context needs the live player")
    local fieldData = assert(runtimeMap.fieldData, "field context needs the compiled map record")
    local delta = assert(MENU_FACING_DELTAS[player.facing], "field context needs a cardinal facing")
    local toX, toZ = player.fieldX + delta.fieldX, player.fieldZ + delta.fieldZ
    local actors = assert(runtime.actors, "field context needs actors")
    local facingActor = nil
    for _, actor in ipairs(actors:actorsOf(runtimeMap.mapId)) do
      local at = actors:getPosition(actor.actorId)
      if at ~= nil and at.fieldX == toX and at.fieldZ == toZ then
        local event = actor.sourceEvent
        facingActor = {
          identity = actor.actorId,
          obstacleKind = event and event.obstacleKind or nil,
          mapSymbol = runtimeMap.mapSymbol,
          fieldX = toX,
          fieldZ = toZ,
        }
        break
      end
    end
    local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, toX, toZ)
    local cell = runtimeMap.collision:getLocal(localX, localZ)
    local behavior = cell and cell.behavior or nil
    local avatar = assert(runtime.playerAvatar, "field context needs the avatar transition owner")
    local follower = runtime.followingMon
    return {
      badges = profile.badges,
      mapSymbol = runtimeMap.mapSymbol,
      mapId = runtimeMap.mapId,
      fieldUse = fieldData.fieldUse,
      weatherId = runtimeMap.effectiveWeatherId,
      avatarMode = avatar:status().durableState,
      humanFollower = false,
      followingMon = follower ~= nil and follower:isVisible() == true,
      rocketCostume = false,
      safari = false,
      palPark = false,
      surfEdge = behavior ~= nil and MetatileBehavior.isSurfableWater(behavior),
      facingWaterfall = behavior == MetatileBehavior.BEHAVIOR.WATERFALL,
      facingWhirlpool = behavior == MetatileBehavior.BEHAVIOR.WHIRLPOOL,
      climbTile = behavior == MetatileBehavior.BEHAVIOR.ROCK_CLIMB_NORTH_SOUTH
        or behavior == MetatileBehavior.BEHAVIOR.ROCK_CLIMB_EAST_WEST,
      headbuttTree = facingActor ~= nil and facingActor.obstacleKind == "headbutt_tree",
      foggy = false,
      chatterOpen = false,
      facingActor = facingActor,
    }
  end
  return readSources
end

-- Composes the one follower-transition owner outside the boot closure
-- (which sits close to LuaJIT's per-function upvalue limit). The generated
-- definition loads through the ready cache path; the controller validates it
-- strictly, so a missing or malformed definition fails the boot loudly.
---@param cacheFs CacheFs
function FieldMenuCompositionCoordinator:composeFollowerTransition(cacheFs)
  local runtime = self.runtime
  local transitionEntry = assert(
    runtime.fieldEntranceIndicatorAsset.index.effects.follower_transition,
    "field-effect index is missing follower_transition"
  )
  local definition =
    assert(cacheFs:loadLua(transitionEntry.path), "field-effect definition is missing: follower_transition")
  runtime.followerTransitionDefinition = definition
  runtime.followingMonTransition = FollowingMonTransitionController.new({
    actors = runtime.actors,
    definition = definition,
    modelFactory = headlessTransitionFactory(),
  })
end

-- The production audio composition and the script audio service are
-- independent axes: the composition is constructed when no recording
-- script audio adapter is injected OR an audio-output host is explicitly
-- provided (a recording adapter then stays the script service while the
-- production renderer/output composition still exists). FieldAudio.compose
-- wires HGSS field policy over the NDS sound runtime, supplies the cry
-- boundary, and builds the LÖVE sink over the injected audio-output host
-- boundary (acceptance fakes it; production defaults to the love.audio +
-- love.sound namespaces, and a host with no audio module has no sink to
-- pump). The caller consumes only the composed service and sink; the
-- FieldAudioController owns the map music/soundplate field policy through
-- enterMap, resolving each map's music through the injected
-- fieldDataForMap lookup. The day/night source defaults to the wall-clock
-- IsNighttime predicate (hours 0-3 and 20-23, the bandForHour nite band);
-- tests and hosts inject a deterministic one.
---@param cacheFs unknown
---@param restoredAudio table<string, unknown>? the restored save's audio bucket, when resuming
---@return table<string, unknown> audioService the GameSound instance, or the injected recording adapter
function FieldMenuCompositionCoordinator:composeAudio(cacheFs, restoredAudio)
  local runtime = self.runtime
  assert(type(cacheFs) == "table" and type(cacheFs.loadLua) == "function", "field runtime cache reader required")
  ---@cast cacheFs CacheFs
  local audioService = runtime.scriptHosts and runtime.scriptHosts.audio
  if audioService == nil or runtime.audioOutput ~= nil then
    local function defaultDayNight()
      return TimeOfDayProps.bandForHour(runtime.localClock:nowLocal().hour) == "nite" and "night" or "day"
    end
    runtime.mapMusicDayNight = runtime.dayNight or defaultDayNight
    local world =
      assert(cacheFs:loadLua(MapAssetCache.worldPath()), "world.lua missing -- run `scripts/buildcache.sh` first")
    local function fieldPosition()
      return runtime.player.fieldX, runtime.player.fieldZ
    end
    local function fieldDataForMap(mapIdOrSymbol)
      local mapId = mapIdOrSymbol
      if type(mapIdOrSymbol) == "string" then
        mapId = world.bySymbol and world.bySymbol[mapIdOrSymbol]
      end
      if mapId == nil then
        error("unknown map symbol " .. tostring(mapIdOrSymbol))
      end
      local mapData = cacheFs:loadLua(FieldMapDataCache.fieldPath(mapId))
      if mapData == nil then
        return nil
      end
      if type(mapData) ~= "table" then
        error("missing field data for map " .. tostring(mapIdOrSymbol) .. " (" .. tostring(mapId) .. ")")
      end
      if mapData.schema ~= FieldMapDataCache.FIELD_SCHEMA then
        error("field data schema mismatch for map " .. tostring(mapId))
      end
      if mapData.mapId ~= mapId then
        error("field data mapId mismatch for map " .. tostring(mapId))
      end
      return mapData
    end
    local audio = FieldAudio.compose({
      cacheFs = cacheFs,
      outputRate = AUDIO_SAMPLE_RATE,
      eventState = runtime.eventState,
      fieldPosition = fieldPosition,
      dayNight = runtime.mapMusicDayNight,
      fieldDataForMap = fieldDataForMap,
      outputHost = runtime.audioOutput,
    })
    runtime.audio = audio.service
    runtime.audioSink = audio.sink
    if audioService == nil then
      audioService = runtime.audio
    end
    -- Initialize the FieldAudioController with the current map.
    -- Fresh boot: no override. Resume: restore the persisted override.
    runtime.audio:enterMap(runtime.runtimeMap, {
      play = true,
      restoredMusicOverride = restoredAudio and restoredAudio.fieldMusicOverride or nil,
    })
  end
  assert(audioService ~= nil, "field runtime audio composition must produce a service")
  return audioService
end

return FieldMenuCompositionCoordinator
