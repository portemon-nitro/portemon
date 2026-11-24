-- Game-side field-script platform construction: builds the registry from the
-- compiled script cache plus explicit overrides, composition, the full task
-- registry, service adapters, and the scheduler + interaction client the
-- session steps. FieldState wires the result into FieldSession.

local Bindings = require("libs.hgss.src.script.Bindings")
local Errors = require("libs.errors.src.Errors")
local PlayerData = require("libs.hgss.src.save.PlayerData")
local ScriptErrors = require("libs.script.src.errors")
local ScriptActorWorld = require("libs.hgss.src.script.ScriptActorWorld")
local ScriptDialogueHost = require("libs.hgss.src.script.ScriptDialogueHost")
local FieldYesNoController = require("libs.hgss.src.ui.FieldYesNoController")
local ScriptMenuHost = require("libs.hgss.src.script.ScriptMenuHost")
local ScriptSignpostHost = require("libs.hgss.src.script.ScriptSignpostHost")
local ScriptInteractionClient = require("libs.hgss.src.script.ScriptInteractionClient")
local ScriptMapsService = require("libs.hgss.src.script.ScriptMapsService")
local PlayerProgression = require("libs.hgss.src.save.PlayerProgression")
local WorldState = require("libs.hgss.src.script.WorldState")
local Scheduler = require("libs.script.src.Scheduler")
local Composition = require("libs.script.src.Composition")
local ScriptLoader = require("libs.script.src.ScriptLoader")
local TaskRegistry = require("libs.script.src.TaskRegistry")
local HgssScript = require("libs.hgss.src.script.Composition")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local MapInitScriptController = require("libs.hgss.src.field.MapInitScriptController")
local FollowerInteractionEngine = require("libs.hgss.src.field.FollowerInteractionEngine")
local FieldMoveCue = require("game.hgss.src.field.FieldMoveCue")
local FieldMoneyBox = require("game.hgss.src.field.FieldMoneyBox")
local FieldFloorWindow = require("game.hgss.src.field.FieldFloorWindow")

-- The player facade the script services consume: position/facing/gender/name
-- plus the mutation hooks the movement tasks use (the player can be a
-- scripted actor only while the field is locked). The facade holds the live
-- FieldPlayer by reference so map swaps can rebind it.
---@class ScriptPlayerFacade
---@field private _player FieldPlayer|nil
---@field private _profile table<string, unknown>|nil { gender: integer, name: string, rivalName: string }
---@field private _charmap table<string, unknown> the generated field font charmap live name writes are validated against
---@field private _avatarState table<string, unknown>|nil avatar transition owner for queue/apply consumers
---@field private _avatarApplier fun(): table<string, unknown>|nil materializes pending transitions through the owning runtime composition
local ScriptPlayerFacade = {}
ScriptPlayerFacade.__index = ScriptPlayerFacade

-- Script-visible PLAYER_STATE_* values from the retail ROM. The value follows the live avatar's
-- visual state, including temporary field-action poses.
local PLAYER_STATE_CODE = {
  walking = 0,
  cycling = 1,
  surfing = 2,
  rocket = 3,
  use_hm = 4,
  watering = 5,
  pokeathlon = 6,
  fishing = 7,
  poketch = 8,
  saving = 9,
  heal = 10,
  ladder = 11,
  rocket_heal = 12,
  apricorn_shake = 13,
  rocket_saving = 14,
}

---@param player FieldPlayer
---@param charmap table<string, unknown> the generated field font charmap live name writes are validated against
---@return ScriptPlayerFacade
local function playerFacade(player, charmap)
  assert(type(charmap) == "table", "field scripts require the generated field charmap")
  return setmetatable({
    _player = player,
    _profile = nil,
    _charmap = charmap,
  }, ScriptPlayerFacade)
end

function ScriptPlayerFacade:setPlayer(player)
  self._player = player
end

-- Wire the avatar transition owner once the composition owns one; transition
-- queue/apply consumers reach it through this facade only. The owner must
-- carry the queue/apply shape so direct setter callers cannot bypass the
-- composition validation.
---@param avatarState table<string, unknown>
function ScriptPlayerFacade:setAvatarState(avatarState)
  assert(
    type(avatarState.queueTransition) == "function" and type(avatarState.applyTransitions) == "function",
    "field scripts require a queue/apply-shaped avatar transition owner"
  )
  self._avatarState = avatarState
end

-- Wire the runtime materializer that applies pending transitions with their
-- visual and sound effects. Queue/apply consumers require it: an apply
-- without one fails instead of moving avatar state without presenting it.
---@param applier fun(): table<string, unknown>|nil
function ScriptPlayerFacade:setAvatarApplier(applier)
  assert(type(applier) == "function", "the avatar applier must be callable")
  self._avatarApplier = applier
end

-- Queue one semantic transition by opaque name. Never touches logical
-- movement, coordinates, or facing; pending membership belongs to the
-- transition owner, not to the live player instance.
---@param name string
function ScriptPlayerFacade:queueAvatarTransition(name)
  assert(type(name) == "string", "avatar transition name must be a string")
  local owner = self._avatarState
  if owner == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "player facade has no avatar transition owner", {})
  end
  (owner --[[@as table]]):queueTransition(name)
end

-- Apply every pending transition in source order and continue same-tick
-- through the runtime materializer, so the final visual and sound effects
-- apply through the owning composition. An apply without a materializer is
-- a composition fault: avatar state must never move without presenting it.
---@return table<string, unknown>|nil
function ScriptPlayerFacade:applyAvatarTransitions()
  local applier = self._avatarApplier
  if applier ~= nil then
    return applier()
  end
  Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "player facade has no avatar transition materializer", {})
end

-- Wire the real player profile (gender and names) when the game owns one;
-- until then profile-dependent operations fault instead of fabricating
-- values.
---@param profile table<string, unknown> { gender: integer, name: string, rivalName: string }
function ScriptPlayerFacade:setProfile(profile)
  self._profile = profile
end

function ScriptPlayerFacade:position()
  local player = assert(self._player, "player facade has no live player")
  return { fieldX = player.fieldX, fieldZ = player.fieldZ, worldY = player.worldY }
end

function ScriptPlayerFacade:facing()
  local player = assert(self._player, "player facade has no live player")
  return player.facing
end

function ScriptPlayerFacade:gender()
  local profile = self._profile
  if profile == nil or profile.gender == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "no player profile is wired; gendered messages cannot resolve",
      {}
    )
  end
  return profile --[[@as { gender: integer, name: string }]].gender
end

function ScriptPlayerFacade:name()
  local profile = self._profile
  if profile == nil or profile.name == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "no player profile is wired; player-name text cannot resolve", {})
  end
  return profile --[[@as { gender: integer, name: string }]].name
end

function ScriptPlayerFacade:rivalName()
  local profile = self._profile
  if profile == nil or profile.rivalName == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "no player profile is wired; rival-name text cannot resolve", {})
  end
  return profile --[[@as { rivalName: string }]].rivalName
end

-- Store the accepted rival name on the live profile the rival battle, the
-- message substitution, and the save capture already read. The naming screen
-- owns input, so an accepted name is already made of glyphs the generated
-- charmap encodes; this boundary re-checks the saved-profile name contract
-- (string, 1..7 glyphs, field-charmap encodable) before publishing, so a
-- rejected name leaves the live profile untouched.
---@param name string
function ScriptPlayerFacade:setRivalName(name)
  local profile = self._profile
  if profile == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "no player profile is wired; the rival name cannot be stored", {})
  end
  ---@cast profile table<string, unknown>
  PlayerData.validateName(name, "rival", self._charmap)
  profile.rivalName = name
end

function ScriptPlayerFacade:stateCode()
  local avatar = self._avatarState
  assert(avatar and type(avatar.status) == "function", "field scripts require a player avatar state owner")
  local stateName = avatar:status().visualState
  local code = PLAYER_STATE_CODE[stateName]
  assert(code ~= nil, "unknown player avatar state " .. tostring(stateName))
  return code
end

function ScriptPlayerFacade:turn(direction)
  local player = assert(self._player, "player facade has no live player")
  assert(player.turn, "player facade requires turn")
  player:turn(direction)
end

function ScriptPlayerFacade:setPosition(position)
  local player = assert(self._player, "player facade has no live player")
  assert(player.setScriptPosition, "player facade requires setScriptPosition")
  player:setScriptPosition(position)
end

function ScriptPlayerFacade:beginScriptedAction(action)
  local player = assert(self._player, "player facade has no live player")
  assert(player.beginScriptedAction, "player missing beginScriptedAction")
  player:beginScriptedAction(action)
end

function ScriptPlayerFacade:advanceScriptedAction(progressTicks, durationTicks)
  local player = assert(self._player, "player facade has no live player")
  assert(player.advanceScriptedAction, "player missing advanceScriptedAction")
  player:advanceScriptedAction(progressTicks, durationTicks)
end

function ScriptPlayerFacade:commitScriptedAction()
  local player = assert(self._player, "player facade has no live player")
  assert(player.commitScriptedAction, "player missing commitScriptedAction")
  player:commitScriptedAction()
end

function ScriptPlayerFacade:cancelScriptedMovement()
  local player = assert(self._player, "player facade has no live player")
  assert(player.cancelScriptedMovement, "player missing cancelScriptedMovement")
  player:cancelScriptedMovement()
end

function ScriptPlayerFacade:isScriptedMoving()
  local player = assert(self._player, "player facade has no live player")
  assert(player.isScriptedMoving, "player missing isScriptedMoving")
  return player:isScriptedMoving()
end

-- The script money operations: source arithmetic over the one borrowed live
-- profile and window mutations delegated to the field money box. The facade
-- never copies the balance, and the money box reads the same profile, so the
-- mart, battle rewards, Trainer Card and the save all observe one wallet.
---@class MoneyService
---@field private _profile table<string, unknown>
---@field private _box FieldMoneyBox
local MoneyService = {}
MoneyService.__index = MoneyService

---@param amount unknown
local function checkSourceAmount(amount)
  assert(
    type(amount) == "number" and amount % 1 == 0 and amount >= 0,
    "a source money amount must be a non-negative integer"
  )
end

---@param profile table<string, unknown>
---@param box FieldMoneyBox
---@return MoneyService
function MoneyService.new(profile, box)
  return setmetatable({ _profile = profile, _box = box }, MoneyService)
end

---@param amount integer
function MoneyService:add(amount)
  checkSourceAmount(amount)
  self._profile.money = math.min(PlayerData.MAX_MONEY, self._profile.money + amount)
end

---@param amount integer
function MoneyService:subtract(amount)
  checkSourceAmount(amount)
  self._profile.money = math.max(0, self._profile.money - amount)
end

---@param amount integer
---@return boolean
function MoneyService:hasEnough(amount)
  checkSourceAmount(amount)
  local money = self._profile.money --[[@as integer]]
  return money >= amount
end

---@param tileX integer
---@param tileY integer
function MoneyService:showBox(tileX, tileY)
  self._box:show(tileX, tileY)
end

function MoneyService:updateBox()
  self._box:update()
end

function MoneyService:hideBox()
  self._box:hide()
end

---@class FieldScriptsOptions
---@field cacheFs CacheFs
---@field overrideFs table<string, unknown> read-shaped filesystem for data/scripts/overrides
---@field eventState FieldEventState
---@field actors FieldActorManager
---@field player FieldPlayer
---@field profile table<string, unknown>|nil { gender: integer, name: string }
---@field dialogue FieldDialogueController
---@field messageProvider FieldMessageProvider
---@field layout fun(formatted: table<string, unknown>): table<string, unknown>
---@field fontDef table<string, unknown> the generated field font: glyph metrics and the charmap both dialogue and name writes resolve
---@field frameIndex integer|nil player-selected HGSS user-frame index for dialogue requests
---@field signpost FieldSignpostController the fixed-tick signpost controller the host advances
---@field windowStyles FieldWindowStyles the immutable per-runtime window style catalogue the high-level sign ops resolve appearances against
---@field transition FieldTransition
---@field mapLoader FieldMapLoader
---@field sourceMap RuntimeFieldMap
---@field seedText string|nil
---@field audio table<string, unknown>|nil optional audio backend (absent -> SCRIPT_SERVICE_MISSING on use)
---@field fieldAudio table<string, unknown>|nil field audio policy owner
---@field weather table<string, unknown>|nil optional live-weather backend
---@field camera table<string, unknown>|nil optional camera backend
---@field screen table<string, unknown>|nil optional screen backend
---@field events table<string, unknown>|nil optional event sink
---@field auxiliaryUi AuxiliaryFieldUi logical auxiliary field UI state
---@field contextChoice ContextChoiceProvider contextual two-choice provider
---@field menu FieldMenuHost modal field menu host
---@field yesNoHost FieldYesNoHost? live choice presentation host shared with the session and field draw
---@field startMenuReopen table<string, unknown>|nil optional { request: fun() } service for the opcode-61 Start Menu reopen (absent -> SCRIPT_SERVICE_MISSING on use)
---@field effects table<string, unknown>|nil semantic field-effect controller (absent -> SCRIPT_SERVICE_MISSING on reveal)
---@field playerAvatar table<string, unknown>|nil avatar transition owner wired into the player facade (required together with avatarApplier)
---@field avatarApplier (fun(): table<string, unknown>|nil)|nil pending-transition materializer wired into the player facade (required together with playerAvatar)
---@field mons table<string, unknown>|nil the live HGSS mon service for mon/party script operations and text (absent -> SCRIPT_SERVICE_MISSING on use)
---@field daycare table<string, unknown>|nil the live Day Care service behind the care command family (absent -> SCRIPT_SERVICE_MISSING on use)
---@field pokedex table<string, unknown>|nil the narrow dex count and grant service for dex script operations (absent -> SCRIPT_SERVICE_MISSING on use)
---@field specialMonGifts table<string, unknown>|nil the game-side special-gift host for the Spiky-Ear Pichu opcode (absent -> SCRIPT_SERVICE_MISSING on use)
---@field items table<string, unknown>|nil the live HGSS Bag service for generic Bag/item script operations (absent -> SCRIPT_SERVICE_MISSING on use)
---@field itemCatalog table<string, unknown>|nil the shared item catalog for item/pocket/TM/berry text (absent -> SCRIPT_UNSUPPORTED_REACHABLE on use)
---@field starterProvider table<string, unknown>|nil the default starter roster for the blocking starter task (absent -> SCRIPT_SERVICE_MISSING on use)
---@field starterChoice table<string, unknown>|nil the modal starter-choice surface the blocking task opens and closes (absent -> SCRIPT_SERVICE_MISSING on use)
---@field partySelection table<string, unknown>|nil the modal script-party surface the blocking selection task opens and closes (absent -> SCRIPT_SERVICE_MISSING on use)
---@field mart table<string, unknown>|nil the script-owned mart child host (absent -> SCRIPT_SERVICE_MISSING on use)
---@field travel table<string, unknown>|nil the durable travel owner for spawn updates (absent -> SCRIPT_SERVICE_MISSING on use)
---@field gameStats table<string, unknown>|nil the live game-stats owner behind script score events (absent -> SCRIPT_SERVICE_MISSING on use)
---@field fieldMoves table<string, unknown>|nil the field-move runtime for task execution (absent -> SCRIPT_SERVICE_MISSING on use)
---@field fieldMoveAftermath table<string, unknown>|nil the Rock Smash / Headbutt aftermath service (absent -> SCRIPT_SERVICE_MISSING on use)
---@field sweetScent table<string, unknown>|nil the Sweet Scent host seam for the scent task (absent -> SCRIPT_SERVICE_MISSING on use)
---@field fishing table<string, unknown>|nil the fishing rod host seam for the fishing task (absent -> SCRIPT_SERVICE_MISSING on use)
---@field bicycle table<string, unknown>|nil the bike mount/dismount service (absent -> SCRIPT_SERVICE_MISSING on use)
---@field monNaming table<string, unknown>|nil the shared field naming host behind nickname and rival naming commands (absent -> SCRIPT_SERVICE_MISSING on use)
---@field pokemonCare table<string, unknown>|nil the script-owned care child host behind the hatch application (absent -> SCRIPT_SERVICE_MISSING on use)
---@field followingMon table<string, unknown>|nil the live following-mon controller for follower script operations (absent -> SCRIPT_SERVICE_MISSING on use)
---@field celebiCinematic table<string, unknown>|nil runtime-owned Celebi scene service used by the time-travel task
---@field legendCutscene table<string, unknown>|nil runtime-owned legend cutscene command state
---@field followerTransition table<string, unknown>|nil the transient follower-transition owner the nonblocking transition command starts (absent -> SCRIPT_SERVICE_MISSING on use)
---@field pokemonCenterHeal table<string, unknown>|nil runtime-owned Pokémon Center choreography
---@field starterBalls table<string, unknown>|nil the Elm starter-ball runtime-prop controller (absent -> SCRIPT_SERVICE_MISSING on use)
---@field followerInteractionCatalog table<string, unknown> validated generated follower-interaction catalog
---@field followerReactionTicks table<string, integer>|nil follower reaction emote kind -> emote action duration (required with the catalog)
---@field clock table<string, unknown> live local clock
---@field fashionCase table<string, unknown> live fashion accessory inventory
---@field pcApplications table<string, unknown> the script-owned PC application host
---@field pcTerminal table<string, unknown> source PC terminal effects
---@field pokegearApplications table<string, unknown>|nil the script-owned companion host behind calls and town-map opens (absent -> SCRIPT_SERVICE_MISSING on use)
---@field phoneCalls table<string, unknown>|nil the field's phone call manager behind staged and forced calls (absent -> SCRIPT_SERVICE_MISSING on use)
---@field phoneContactIndex table<string, unknown>|nil the compiled phonebook index { byId, byTrainer } for number resolution (absent -> SCRIPT_SERVICE_MISSING on use)
---@field pokegearState table<string, unknown>|nil the durable companion state behind card and trigger writes (absent -> SCRIPT_SERVICE_MISSING on use)
---@field phoneGifts table<string, unknown>|nil the contact and parent gift query adapter (absent -> SCRIPT_SERVICE_MISSING on use)
---@field radioMusic table<string, unknown>|nil the audio-derived radio music query (absent -> SCRIPT_SERVICE_MISSING on use)
---@field battle table<string, unknown>|nil the battle host for script battle tasks (absent -> SCRIPT_SERVICE_MISSING on use)
---@field roamers table<string, unknown>|nil the field roamer owner behind native slot creation (absent -> SCRIPT_SERVICE_MISSING on use)
---@field monPicture table<string, unknown>|nil the field Pokémon picture window behind opcodes 452/453 (absent -> SCRIPT_SERVICE_MISSING on use)
---@field versionId string|nil the selected game version (heartgold/soulsilver) behind GetGameVersion
---@field sysInfo table<string, unknown>|nil the live sysInfo owner behind SetMysteryGiftActive (absent -> SCRIPT_SERVICE_MISSING on use)
---@field timeOfDay table<string, unknown> RTC-derived time-of-day service
---@field trainerCardStars table<string, unknown> source-derived Trainer Card star query
---@field apricorn table<string, unknown> source tree and Apricorn inventory adapter
---@field apricornKurt table<string, unknown>? Kurt order and native Ball adapter
---@field kurtBoxHost table<string, unknown>? script-owned Kurt Box child host
---@field overworld table<string, unknown>|nil the shared field lifecycle owner
---@field easyChatCatalog table<string, unknown>? the shared word catalog behind editor requests and buffered text
---@field easyChatState table<string, unknown>? the authoritative saved word state
---@field easyChatRandom table<string, unknown>? the labeled random stream behind trendy learning
---@field easyChatScriptHost table<string, unknown>? the script-owned word editor child host
---@field easyChatContexts table<string, unknown>? explicit parent command envelopes for deferred features
---@field propAnimations table<string, unknown>|nil the map-scoped one-shot prop slot owner
---@field gymMechanism table<string, unknown>|nil the active gym mechanism the gym task drives (absent -> SCRIPT_SERVICE_MISSING on use)
---@field trainerEncounter table<string, unknown>|nil the field trainer engagement owner the standard trainer commands read (absent -> SCRIPT_SERVICE_MISSING on use)
---@field rocketHideout table<string, unknown>|nil the field's Rocket effect owner the trap and alarm tasks drive (absent -> SCRIPT_SERVICE_MISSING on use)
---@field legendEvents table<string, unknown>|nil the field's legendary-story scene owner the scene task drives (absent -> SCRIPT_SERVICE_MISSING on use)
---@field gameClear table<string, unknown>|nil the League ending's transaction owner behind 163 (absent -> SCRIPT_SERVICE_MISSING on use)
---@field blackout { loader: table<string, unknown>, sourceMap: fun(): table<string, unknown> }? blackout flow construction inputs
---@field blackoutFlow FieldBlackoutFlow? runtime-owned whiteout presentation and recovery flow

---@class FieldScripts
---@field registry table<string, unknown>
---@field composition Composition
---@field bindings table<string, unknown>
---@field scheduler Scheduler
---@field client ScriptInteractionClient
---@field worldState WorldState
---@field dialogueHost ScriptDialogueHost
---@field mapsService ScriptMapsService
---@field menuHost ScriptMenuHost
---@field signpostHost ScriptSignpostHost
---@field followerInteractionEngine FollowerInteractionEngine?
---@field player ScriptPlayerFacade
---@field cacheFs table<string, unknown> CacheFs-shaped
---@field overrideFs table<string, unknown> read-shaped filesystem for data/scripts/overrides
---@field taskRegistry TaskRegistry the live registered-task registry
---@field initController MapInitScriptController
---@field blackoutFlow FieldBlackoutFlow?
---@field moneyBox FieldMoneyBox the one transient source money window the field draw renders
---@field mapSource RuntimeFieldMap the active runtime map map-scoped script state is bound to
---@field propAnimations table<string, unknown>|nil
---@field floorWindow FieldFloorWindow the source floor box the field presents and releases
local FieldScripts = {}
FieldScripts.__index = FieldScripts

-- Trusted override modules execute with the host module loader and normal
-- Lua globals; generated cache content keeps the minimal deterministic
-- environment inside the loader regardless of this callback.
local function trustedRequire(name)
  return require(name)
end

-- The naming screen carries its own message bank: `NamingScreen_SetDefaultName`
-- (src/naming_screen.c) reads FIRST_DEFAULT_NAME_RIVAL from bank 254 when the
-- player commits an empty rival name -- row 84 under HEARTGOLD and row 85
-- otherwise. Reading the bank needs no map header or field script bank, so the
-- producer lists it explicitly.
local NAMING_SCREEN_MESSAGE_BANK_ID = 254
local RIVAL_DEFAULT_NAME_HEARTGOLD_MESSAGE_ID = 84
local RIVAL_DEFAULT_NAME_SOULSILVER_MESSAGE_ID = 85

-- The generated default-name row the selected edition reads. The retail split
-- is compile-time (`#ifdef HEARTGOLD`), so every non-HeartGold edition reads
-- the 85 row.
---@param versionId string
---@return integer
local function rivalDefaultNameMessageId(versionId)
  if versionId == "heartgold" then
    return RIVAL_DEFAULT_NAME_HEARTGOLD_MESSAGE_ID
  end
  return RIVAL_DEFAULT_NAME_SOULSILVER_MESSAGE_ID
end

-- Read one generated message as display text with scoped bank ownership: the
-- bank is released after a successful read and also released before rethrowing
-- the provider's original fault, so a missing bank or row surfaces its
-- structured error instead of a substitute literal.
---@param provider FieldMessageProvider
---@param bankId integer
---@param messageId integer
---@return string
local function scopedMessageText(provider, bankId, messageId)
  local acquired, acquireErr = provider:acquireBank(bankId)
  if not acquired then
    error(acquireErr, 0)
  end
  local template, templateErr = provider:get(bankId, messageId)
  if not template then
    provider:releaseBank(bankId)
    error(templateErr, 0)
  end
  provider:releaseBank(bankId)
  return template.text
end

-- The generated default name the naming screen stores for an empty entry. The
-- naming task asks for it once, when rival naming starts, so the bank read
-- stays lazy: a composition that never runs rival naming never acquires the
-- naming screen's bank, and a missing bank or row surfaces the provider's
-- structured error instead of a literal.
---@param provider FieldMessageProvider
---@param versionId string
---@return fun(): string
local function rivalDefaultNameResolver(provider, versionId)
  local messageId = rivalDefaultNameMessageId(versionId)
  local function resolveDefaultName()
    return scopedMessageText(provider, NAMING_SCREEN_MESSAGE_BANK_ID, messageId)
  end
  return resolveDefaultName
end

-- opts.overrideFs: love.filesystem-shaped read access for the repo
-- `data/scripts/overrides` tree (the game mounts `data` before calling).
---@param opts FieldScriptsOptions
---@return FieldScripts
function FieldScripts.new(opts)
  assert(
    type(opts) == "table" and opts.cacheFs and opts.overrideFs and opts.eventState and opts.actors and opts.player,
    "field scripts require cache, overrides, world, and actors"
  )
  assert(
    opts.dialogue and opts.messageProvider and opts.layout and opts.fontDef,
    "field scripts require the dialogue stack"
  )
  assert(opts.signpost and opts.signpost.isModal, "field scripts require the signpost controller")
  assert(opts.windowStyles and opts.windowStyles.resolve, "field scripts require the window style catalogue")
  assert(
    opts.transition and opts.mapLoader and opts.sourceMap and opts.auxiliaryUi and opts.menu and opts.contextChoice,
    "field scripts require transition, auxiliary UI, context choice, and menu host"
  )
  assert(
    (opts.playerAvatar == nil) == (opts.avatarApplier == nil),
    "field scripts require playerAvatar and avatarApplier together"
  )

  -- The registry is always installed lazily: only the generated layer's
  -- presence comes from the index, and each script decodes on first use,
  -- so no gameplay pass decodes the corpus up front. The override layer
  -- is always loaded eagerly under the trusted policy: override modules
  -- execute with normal Lua globals and the host module loader, while
  -- generated cache content keeps the minimal deterministic environment
  -- inside the loader.
  local builtins = HgssScript.builtins()
  local registry = ScriptLoader.buildRegistry(opts.cacheFs, opts.overrideFs, trustedRequire, {
    lazy = true,
    builtins = builtins,
  })
  local composition = Composition.new(registry)
  local bindings = Bindings.new()

  local worldState = WorldState.new({
    eventState = opts.eventState,
    catalogs = {
      flags = FieldScriptSymbols.flagsByName,
      variables = FieldScriptSymbols.variablesByName,
    },
    seed = opts.seedText or opts.cacheFs.versionId,
  })
  local player = playerFacade(opts.player, opts.fontDef.charmap)
  -- The real player profile (gender and name) is wired when the game owns
  -- one; without it, profile-dependent operations fault instead of
  -- fabricating values.
  if opts.profile ~= nil then
    player:setProfile(opts.profile)
  end
  -- The avatar transition owner is runtime-owned; the facade only carries it
  -- for transition queue/apply consumers.
  if opts.playerAvatar ~= nil then
    player:setAvatarState(opts.playerAvatar)
    player:setAvatarApplier(assert(opts.avatarApplier))
  end
  local actors = ScriptActorWorld.new(opts.actors --[[@as ScriptActorManager]], player)
  local followerInteractionEngine = nil
  if opts.followerInteractionCatalog ~= nil then
    followerInteractionEngine = FollowerInteractionEngine.new({
      catalog = opts.followerInteractionCatalog,
      reactionTicks = assert(opts.followerReactionTicks, "follower reaction emote durations are required"),
      mons = assert(opts.mons),
      items = assert(opts.itemCatalog),
      fashionCase = assert(opts.fashionCase),
      world = worldState,
      actors = opts.actors,
      followingMon = assert(opts.followingMon),
      runtimeMap = opts.sourceMap,
      player = player,
      clock = assert(opts.clock),
    })
  end
  local dialogueHost = ScriptDialogueHost.new({
    controller = opts.dialogue,
    yesNoController = FieldYesNoController.new({ audio = opts.audio }),
    yesNoHost = opts.yesNoHost,
    provider = opts.messageProvider,
    layout = opts.layout,
    fontDef = opts.fontDef,
    player = player,
    world = worldState,
    mons = opts.mons,
    items = opts.itemCatalog,
    locationNames = opts.followerInteractionCatalog and opts.followerInteractionCatalog.locationNames,
    frameIndex = opts.frameIndex,
    easyChatCatalog = opts.easyChatCatalog,
  })
  -- The script-owned word editor service over the shared catalog and
  -- saved state, the live profile, mons, world, random stream, and
  -- message provider. Absent catalogs keep the operation unfabricated:
  -- word commands fault on use instead of answering through a fake.
  local easyChatService = nil
  if opts.easyChatCatalog ~= nil then
    local EasyChatScriptService = require("game.hgss.src.easychat.EasyChatScriptService")
    easyChatService = EasyChatScriptService.new({
      catalog = opts.easyChatCatalog,
      state = assert(opts.easyChatState, "word scripts require the saved word state"),
      profile = assert(opts.profile, "word scripts require the player profile"),
      mons = assert(opts.mons, "word scripts require the mon service"),
      world = worldState,
      random = assert(opts.easyChatRandom, "word scripts require the labeled random stream"),
      messageProvider = assert(opts.messageProvider, "word scripts require the message provider"),
      contexts = opts.easyChatContexts,
    })
  end
  local mapsService = ScriptMapsService.new({
    transition = opts.transition,
    loader = opts.mapLoader,
    sourceMap = opts.sourceMap,
    screen = opts.screen,
    travel = opts.travel,
  })
  local function resolveText(message)
    return dialogueHost:resolveMessage(message, {}, {})
  end
  local function substitutionResolvers(template, textArgs)
    return dialogueHost:substitutionResolvers(template, {}, textArgs)
  end
  local menuHost = ScriptMenuHost.new({
    provider = opts.messageProvider,
    resolveText = resolveText,
    substitutionResolvers = substitutionResolvers,
  })
  -- The signpost host reuses the dialogue host's public message-resolution
  -- operation through injection; it never reaches an underscored helper or
  -- duplicates substitution semantics.
  local function resolveMessage(message, messageBindings, textArgs)
    return dialogueHost:resolveMessage(message, messageBindings, textArgs)
  end
  local signpostHost = ScriptSignpostHost.new({
    controller = opts.signpost,
    resolveMessage = resolveMessage,
  })
  -- The source floor box: one non-modal window whose lifetime is the script
  -- variable the command names. The host observes that variable each script
  -- tick and on field teardown; the scheduler-facing service adds the live map
  -- whose floor label applies and the calling script's buffered text, which the
  -- ordinary floor label substitutes into its message.
  local function floorWindowGetVar(id)
    return worldState:getVar(id)
  end
  local function floorWindowResolveMessage(ref, textArgs)
    return dialogueHost:resolveMessage(ref, {}, textArgs)
  end
  local floorWindowHost = FieldFloorWindow.new({
    getVar = floorWindowGetVar,
    resolveMessage = floorWindowResolveMessage,
  })

  -- The transient source money window and its script facade. The box borrows
  -- the live profile for the displayed balance; the facade moves that same
  -- profile. Without a profile no facade is synthesized, so money commands
  -- keep their missing-service fault instead of writing a scratch wallet.
  local moneyBox = FieldMoneyBox.new({
    profile = opts.profile,
    messages = opts.messageProvider,
  })
  local moneyService = nil
  if opts.profile ~= nil then
    moneyService = MoneyService.new(opts.profile, moneyBox)
  end

  -- The generated rival default name is wired only when the runtime knows the
  -- selected edition: without one there is no row to read, and the naming task
  -- keeps its missing-service fault.
  local rivalDefaultName = nil
  if opts.versionId ~= nil then
    rivalDefaultName = rivalDefaultNameResolver(opts.messageProvider, opts.versionId)
  end

  ---@class FieldScriptsPlatform: FieldScripts
  ---@field initController MapInitScriptController
  ---@field blackoutFlow FieldBlackoutFlow?
  local platform = setmetatable({
    registry = registry,
    cacheFs = opts.cacheFs,
    overrideFs = opts.overrideFs,
    composition = composition,
    bindings = bindings,
    worldState = worldState,
    dialogueHost = dialogueHost,
    mapsService = mapsService,
    menuHost = menuHost,
    signpostHost = signpostHost,
    followerInteractionEngine = followerInteractionEngine,
    player = player,
    mapSource = opts.sourceMap,
    propAnimations = opts.propAnimations,
    moneyBox = moneyBox,
    floorWindow = floorWindowHost,
  }, FieldScripts)
  if opts.propAnimations ~= nil then
    opts.propAnimations:bindMap(opts.sourceMap)
  end

  -- The live badge progression borrows the supplied profile: badge reads
  -- observe the persisted set and awards mutate it in place. Without a
  -- profile no facade is synthesized, so badge operations keep their
  -- missing-service fault instead of reading zero badges.
  local progression = nil
  if opts.profile ~= nil then
    progression = PlayerProgression.new(opts.profile)
  end

  -- The live task registry: the scheduler routes through it.
  local liveTaskRegistry = HgssScript.registerTasks(TaskRegistry.new())

  local blackoutFlow
  if opts.blackout ~= nil then
    local FieldBlackoutFlow = require("game.hgss.src.field.FieldBlackoutFlow")
    blackoutFlow = FieldBlackoutFlow.new({
      cacheFs = opts.cacheFs,
      loader = opts.blackout.loader,
      transition = opts.transition,
      sourceMap = opts.blackout.sourceMap,
      world = worldState,
      mons = opts.mons,
      travel = opts.travel,
      audio = opts.audio,
      overworld = opts.overworld,
      resolveMessage = resolveMessage,
    })
    platform.blackoutFlow = blackoutFlow
  end

  local scheduler
  local function advanceAsync()
    floorWindowHost:poll()
    opts.auxiliaryUi:advance()
    dialogueHost:advance(scheduler:currentInput())
    -- The signpost controller is pure and fixed-tick: exactly one step per
    -- scheduler tick, commands and printer together.
    signpostHost:advance(scheduler:currentInput())
  end
  local function resolveComposition(id)
    return composition:effective(id)
  end
  -- The scheduler-facing floor-box service adds the live map whose floor label
  -- table applies to the placement the command names, and the script's buffered
  -- text the floor label message expands.
  local function floorWindowShow(_, request)
    floorWindowHost:show({
      map = platform.mapSource.mapSymbol,
      tileX = request.tileX,
      tileY = request.tileY,
      floor = request.floor,
      textArgs = request.textArgs or {},
      result = request.result,
    })
  end
  scheduler = Scheduler.new({
    services = {
      world = worldState,
      actors = actors,
      player = player,
      dialogue = dialogueHost,
      maps = mapsService,
      clock = opts.clock,
      floorWindow = { show = floorWindowShow },
      overworld = opts.overworld,
      propAnimations = opts.propAnimations,
      gymMechanism = opts.gymMechanism,
      trainerEncounter = opts.trainerEncounter,
      rocketHideout = opts.rocketHideout,
      legendEvents = opts.legendEvents,
      gameClear = opts.gameClear,
      -- Optional backends: an absent service faults the operation that
      -- needs it (SCRIPT_SERVICE_MISSING) instead of silently succeeding.
      -- The production game wires real audio/camera/screen/events here when
      -- those subsystems land; tests inject deterministic fakes.
      audio = opts.audio,
      fieldAudio = opts.fieldAudio,
      weather = opts.weather,
      camera = opts.camera,
      screen = opts.screen,
      events = opts.events,
      auxiliaryUi = opts.auxiliaryUi,
      progression = progression,
      contextChoice = opts.contextChoice,
      menu = opts.menu,
      scriptMenu = menuHost,
      signpost = signpostHost,
      windowStyles = opts.windowStyles,
      startMenuReopen = opts.startMenuReopen,
      effects = opts.effects,
      terrainEffects = opts.effects,
      mons = opts.mons,
      daycare = opts.daycare,
      pokedex = opts.pokedex,
      specialMonGifts = opts.specialMonGifts,
      items = opts.items,
      starterProvider = opts.starterProvider,
      starterChoice = opts.starterChoice,
      partySelection = opts.partySelection,
      mart = opts.mart,
      money = moneyService,
      travel = opts.travel,
      gameStats = opts.gameStats,
      fieldMoves = opts.fieldMoves,
      fieldMoveAftermath = opts.fieldMoveAftermath,
      sweetScent = opts.sweetScent,
      fishing = opts.fishing,
      bicycle = opts.bicycle,
      fieldMoveCue = FieldMoveCue.new(opts.mons),
      monNaming = opts.monNaming,
      pokemonCare = opts.pokemonCare,
      rivalDefaultName = rivalDefaultName,
      followingMon = opts.followingMon,
      celebiCinematic = opts.celebiCinematic,
      legendCutscene = opts.legendCutscene,
      followerInteraction = followerInteractionEngine,
      followerTransition = opts.followerTransition,
      pokemonCenterHeal = opts.pokemonCenterHeal,
      blackout = blackoutFlow,
      timeOfDay = opts.timeOfDay,
      trainerCardStars = opts.trainerCardStars,
      apricorn = opts.apricorn,
      apricornKurt = opts.apricornKurt,
      kurtBoxHost = opts.kurtBoxHost,
      starterBalls = opts.starterBalls,
      pcApplications = opts.pcApplications,
      pcTerminal = opts.pcTerminal,
      pokegearApplications = opts.pokegearApplications,
      phoneCalls = opts.phoneCalls,
      phoneContactIndex = opts.phoneContactIndex,
      pokegearState = opts.pokegearState,
      phoneGifts = opts.phoneGifts,
      radioMusic = opts.radioMusic,
      battle = opts.battle,
      roamers = opts.roamers,
      monPicture = opts.monPicture,
      gameVersion = opts.versionId,
      versionId = opts.versionId,
      sysInfo = opts.sysInfo,
      easyChatService = easyChatService,
      easyChatScriptHost = opts.easyChatScriptHost,
      advanceAsync = advanceAsync,
    },
    taskRegistry = liveTaskRegistry,
    semantics = HgssScript.semantics(),
    resolveComposition = resolveComposition,
  })
  platform.scheduler = scheduler
  platform.taskRegistry = liveTaskRegistry
  local function compose(id)
    return composition:effective(id)
  end
  platform.client = ScriptInteractionClient.new({
    bindings = bindings,
    compose = compose,
    scheduler = scheduler,
    worldState = worldState,
    scriptBankId = opts.sourceMap.fieldData.scriptBankId,
  })
  platform.initController = MapInitScriptController.new({
    rules = opts.sourceMap.fieldData.initScripts,
    mapId = opts.sourceMap.fieldData.mapId,
    world = worldState,
    scriptClient = platform.client,
  })
  return platform
end

-- Rebind every map-scoped script collaborator (maps service, script-client
-- bank id, init-controller rules/map id, and mapSource) to sourceMap. Shared
-- by the discontinuous and seamless active-map entry points below so both
-- always establish the same complete destination map context.
---@param self FieldScripts
---@param sourceMap RuntimeFieldMap
local function rebindMapContext(self, sourceMap)
  self.mapsService:setSourceMap(sourceMap)
  self.client:setScriptBankId(sourceMap.fieldData.scriptBankId)
  self.initController:setRules(sourceMap.fieldData.initScripts, sourceMap.fieldData.mapId)
  self.mapSource = sourceMap
  if self.followerInteractionEngine ~= nil then
    self.followerInteractionEngine.runtimeMap = sourceMap
  end
  if self.propAnimations ~= nil then
    self.propAnimations:bindMap(sourceMap)
  end
end

-- Rebind the facade and warp source after a map swap (the player and the
-- current map are replaced by the transition). The transient source money
-- window belongs to the map that opened it, so a swap closes it exactly once
-- before the destination map publishes.
---@param player FieldPlayer
---@param sourceMap RuntimeFieldMap
function FieldScripts:onMapSwap(player, sourceMap)
  self.player:setPlayer(player)
  self.moneyBox:dispose()
  rebindMapContext(self, sourceMap)
end

---@param sourceMap RuntimeFieldMap
function FieldScripts:onZoneChange(sourceMap)
  rebindMapContext(self, sourceMap)
end

return FieldScripts
