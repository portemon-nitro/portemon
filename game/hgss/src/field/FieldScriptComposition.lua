-- Builds the concrete field script hosts and scheduler-facing adapters.

local CivilDate = require("libs.hgss.src.field.CivilDate")
local FieldScripts = require("game.hgss.src.field.FieldScripts")
local ScriptSave = require("libs.script.src.ScriptSave")
local TimeOfDayProps = require("libs.hgss.src.presentation.TimeOfDayProps")
local TrainerCardStars = require("libs.hgss.src.save.TrainerCardStars")
local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local ApricornTreePresentation = require("game.hgss.src.apricorn.ApricornTreePresentation")
local KurtConversions = require("game.hgss.src.apricorn.KurtConversions")
local CelebiTimeTravelScene = require("libs.hgss.src.field.CelebiTimeTravelScene")
local HoOhAppearanceScene = require("libs.hgss.src.field.HoOhAppearanceScene")

---@class FieldScriptCompositionResult
---@field scripts FieldScripts
---@field restore fun()
---@class FieldScriptCompositionOptions
---@field cacheFs CacheFs
---@field layoutMessage fun(formatted: table<string, unknown>): table<string, unknown>
---@field fontDef table<string, unknown>
---@field audioService table<string, unknown>
---@field loadedGame table<string, unknown>?
---@field mons table<string, unknown> live HGSS mon service for mon/party script operations and text
---@field items table<string, unknown>? live HGSS Bag service for generic Bag/item script operations
---@field itemCatalog table<string, unknown> shared item catalog for item/pocket/TM/berry text
---@field followingMon table<string, unknown> the live following-mon controller for follower script operations
---@field starterProvider table<string, unknown>? the default starter roster for the blocking starter task
---@field starterChoice table<string, unknown>? the modal starter-choice surface the blocking task opens and closes
---@field partySelection table<string, unknown>? the modal script-party surface the blocking selection task opens and closes
---@field mart table<string, unknown>? the script-owned mart child host
---@field travel table<string, unknown>? the durable travel owner for spawn updates
---@field fieldMoves table<string, unknown>? the field-move runtime for task execution
---@field monNaming table<string, unknown> the script-owned Pokemon Naming Screen host
---@field followerTransition table<string, unknown>? the transient follower-transition owner the nonblocking transition command starts
---@field starterBalls table<string, unknown>? the Elm starter-ball runtime-prop controller
---@field followerInteractionCatalog table<string, unknown> validated generated interaction catalog
---@field followerReactionTicks table<string, integer> follower reaction emote kind -> emote action duration
---@field clock table<string, unknown> live local clock
---@field pcApplications table<string, unknown> script-owned PC application host
---@field pcTerminal table<string, unknown> PC terminal effect service
---@field battle table<string, unknown>? the battle host for script battle tasks (absent until the application wires it)
---@field pokemonCenterHeal table<string, unknown>? the runtime-owned blocking Pokémon Center choreography
local FieldScriptComposition = {}

local APRICORN_BY_COLOR = {
  [0] = "RED_APRICORN",
  "YLW_APRICORN",
  "BLU_APRICORN",
  "GRN_APRICORN",
  "PNK_APRICORN",
  "WHT_APRICORN",
  "BLK_APRICORN",
}

local COLOR_BY_APRICORN = {}
for colorCode = 0, 6 do
  COLOR_BY_APRICORN[APRICORN_BY_COLOR[colorCode]] = colorCode
end

-- Builds the compiled phonebook index behind contact-number resolution:
-- phonebook number to semantic key and trainer number to phonebook
-- number. Pure data over the compiled catalog; resolution failures
-- surface at the script boundary, never here.
---@param catalog table<string, unknown>?
---@return table<string, unknown>? the index, or nil without a catalog
function FieldScriptComposition.phoneContactIndex(catalog)
  if type(catalog) ~= "table" or type(catalog.contacts) ~= "table" then
    return nil
  end
  local byId, byTrainer = {}, {}
  for _, record in
    ipairs(catalog.contacts --[[@as table<integer, unknown>]])
  do
    local entry = record --[[@as table<string, unknown>]]
    if type(entry.key) == "string" and type(entry.id) == "number" then
      byId[entry.id] = entry.key
      if type(entry.trainer) == "number" then
        byTrainer[entry.trainer] = entry.id
      end
    end
  end
  return { byId = byId, byTrainer = byTrainer }
end

-- Builds the contact and parent gift query adapter over the real owners:
-- durable state for pending rewards, the compiled phonebook for fixed
-- gift items, the companion streams for berry draws, and the item
-- catalog for native-id translation. Queries are read-only: a waiting
-- staged reward reports its own key instead of stacking, an
-- unregistered contact waits for nothing, and the berry draw labels its
-- stream. A missing owner yields no adapter and the script operation
-- faults on use instead of answering a fabricated gift.
---@param state table<string, unknown>?
---@param catalog table<string, unknown>?
---@param random table<string, unknown>?
---@param itemCatalog table<string, unknown>?
---@return table<string, unknown>? the adapter, or nil without its owners
function FieldScriptComposition.phoneGiftQueries(state, catalog, random, itemCatalog)
  if
    type(state) ~= "table"
    or type(state.readPhone) ~= "function"
    or type(catalog) ~= "table"
    or type(catalog.contacts) ~= "table"
    or type(random) ~= "table"
    or type(random.lc) ~= "function"
    or type(itemCatalog) ~= "table"
    or type(itemCatalog.itemKeyByNativeId) ~= "function"
  then
    return nil
  end
  local contactsByKey = {}
  for _, record in
    ipairs(catalog.contacts --[[@as table<integer, unknown>]])
  do
    local entry = record --[[@as table<string, unknown>]]
    if type(entry.key) == "string" then
      contactsByKey[entry.key] = entry
    end
  end
  local PhoneRewards = require("game.hgss.src.pokegear.PhoneRewards")
  local adapter = {}
  local function nativeId(itemKey)
    local item = itemCatalog:item(itemKey)
    assert(type(item.nativeId) == "number", "phone gifts resolve to a native item identity")
    return item.nativeId
  end
  local function stagedReward(contactKey)
    local phone = state:readPhone()
    assert(type(phone) == "table" and type(phone.contacts) == "table", "gift queries read registered contacts")
    local entry = (phone.contacts --[[@as table<string, unknown>]])[contactKey]
    if type(entry) ~= "table" then
      return nil, false
    end
    local reward = (entry --[[@as table<string, unknown>]]).reward
    if
      type(reward) == "table" and type((reward --[[@as table<string, unknown>]]).item) == "string"
    then
      return (reward --[[@as table<string, string>]]).item, true
    end
    return nil, true
  end
  ---@param contactKey string
  ---@return string|integer the waiting item key, or numeric zero
  function adapter:berry(contactKey)
    local waiting, registered = stagedReward(contactKey)
    if waiting ~= nil then
      return nativeId(waiting)
    end
    if not registered then
      return 0
    end
    local draw = random.lc --[[@as fun(self: table<string, unknown>, label: string): integer]]
    local pick = draw(random, "contact-berry") % PhoneRewards.BERRY_CHOICES
    assert(pick >= 0 and pick < PhoneRewards.BERRY_CHOICES, "berry draws stay inside their choices")
    local berries = catalog.momPurchases --[[@as table<integer, table<string, unknown>>]]
    local berryIndex = 0
    for _, entry in ipairs(berries) do
      if entry.kind == "berry" then
        if berryIndex == pick then
          return entry.nativeItemId --[[@as integer]]
        end
        berryIndex = berryIndex + 1
      end
    end
    error("the compiled Mom berry table does not cover its source selector", 0)
  end
  ---@param contactKey string
  ---@return string|integer the waiting item key, or numeric zero
  function adapter:giftItem(contactKey)
    local waiting, registered = stagedReward(contactKey)
    if waiting ~= nil then
      return nativeId(waiting)
    end
    if not registered then
      return 0
    end
    local record = contactsByKey[contactKey]
    assert(type(record) == "table", "gift queries read catalogued contacts")
    local nativeItemId = (record --[[@as table<string, unknown>]]).gift
    assert(type(nativeItemId) == "number", "contact gifts carry their native item")
    return nativeItemId
  end
  ---@return string|integer the waiting parent gift item ID, or numeric zero
  function adapter:momGift()
    local itemId = self:peekMom()
    return itemId
  end
  ---@return integer, integer native item ID and quantity, or zero values
  function adapter:peekMom()
    local phone = state:readPhone()
    assert(type(phone) == "table", "parent gift queries read phone facts")
    local mom = (phone --[[@as table<string, unknown>]]).mom
    assert(type(mom) == "table", "parent gift queries read savings facts")
    local queue = (mom --[[@as table<string, unknown>]]).gifts
    assert(type(queue) == "table", "parent gift queries read the gift queue")
    local head = (queue --[[@as table<integer, unknown>]])[1]
    if type(head) ~= "table" then
      return 0, 0
    end
    local item = (head --[[@as table<string, unknown>]]).item
    if type(item) ~= "string" or item == "" then
      return 0, 0
    end
    local quantity = (head --[[@as table<string, unknown>]]).quantity
    assert(type(quantity) == "number" and quantity % 1 == 0 and quantity > 0, "queued gifts carry a source quantity")
    return nativeId(item), quantity
  end
  function adapter:takeMomAfterGive()
    local queue = state:readPhone().mom.gifts
    local head = queue[1]
    assert(type(head) == "table", "the source dequeue follows a pending Mom gift")
    local candidate = PhoneRewards.prepareCollection(state:revision(), { state = state, gift = head }) --[[@as { publish: fun(): table<string, unknown> }]]
    candidate.publish()
  end
  return adapter
end

local function currentTimeOfDayCode(runtime)
  return TimeOfDayProps.rtcCodeForHour(runtime.localClock:nowLocal().hour)
end

local function timeOfDayService(runtime)
  local function currentCode()
    return currentTimeOfDayCode(runtime)
  end
  local function weekday()
    local _, day = CivilDate.parts(runtime.localClock:nowLocal())
    return day
  end
  return { currentCode = currentCode, weekday = weekday }
end

-- No Frontier gameplay owns a writer yet, so the current production
-- composition supplies a stateless non-qualifying Frontier capability. The
-- source predicate inside TrainerCardStars.count stays untouched for the
-- day a real Frontier subsystem injects a qualifying record.
local function frontierNeverQualifiesForTrainerCardStar()
  return false
end

local function trainerCardStarsService(runtime)
  local function count()
    local scripts = assert(runtime.scripts, "field script runtime is assigned before script execution")
    return TrainerCardStars.count(
      scripts.worldState,
      assert(runtime.dexKnowledge, "field runtime has no dex knowledge"),
      {
        qualifiesForTrainerCardStar = frontierNeverQualifiesForTrainerCardStar,
      }
    )
  end
  return { count = count }
end

local function apricornService(runtime)
  local treePresentation = ApricornTreePresentation.new(runtime)
  runtime.apricornTreePresentation = treePresentation
  local function treeForActor(_, actorId)
    local actor = runtime.actors:getActor(actorId)
    local sourceEvent = actor and actor.sourceEvent
    local source = type(sourceEvent) == "table" and sourceEvent.apricorn or nil
    if
      type(source) ~= "table"
      or type(source.treeIndex) ~= "number"
      or source.treeIndex % 1 ~= 0
      or COLOR_BY_APRICORN[source.apricornKey] == nil
    then
      Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "Apricorn command targeted a non-tree actor", {
        actorId = actorId,
        mapId = actor and actor.mapId or nil,
        objectEventId = sourceEvent and sourceEvent.objectEventId or nil,
      })
    end
    local tree = assert(source)
    return { treeIndex = assert(tree.treeIndex), apricornKey = assert(tree.apricornKey) }
  end
  local function keyForColor(colorCode)
    assert(
      type(colorCode) == "number" and colorCode % 1 == 0 and APRICORN_BY_COLOR[colorCode] ~= nil,
      "source Apricorn color code must be from 0 to 6"
    )
    return APRICORN_BY_COLOR[colorCode]
  end
  local function colorForActor(_, actorId)
    return COLOR_BY_APRICORN[treeForActor(nil, actorId).apricornKey]
  end
  local function give(_, colorCode, quantity)
    return assert(runtime.martService, "Apricorn inventory owner is unavailable"):tryGiveApricorn(
      keyForColor(colorCode),
      quantity
    )
  end
  local function displayName(_, colorCode)
    return assert(runtime.itemCatalog, "item catalog is unavailable"):item(keyForColor(colorCode)).name
  end
  local function treeAvailable(_, treeIndex)
    return assert(runtime.martService, "Apricorn tree state owner is unavailable"):treeAvailable(treeIndex)
  end
  local function depleteTree(_, treeIndex)
    local depleted = assert(runtime.martService, "Apricorn tree state owner is unavailable"):depleteTree(treeIndex)
    if depleted then
      treePresentation:invalidateAssets()
    end
    return depleted
  end
  local function beginTreeAnimation(_, _, _)
    local avatar = assert(runtime.playerAvatar, "field runtime has no player avatar owner")
    avatar:queueTransition("apricorn_shake")
    runtime:applyAvatarTransitions()
  end
  local function advanceTreeAnimation(_, actorId, phase, frame)
    if phase == "wiggle" and frame == 0 then
      local avatar = assert(runtime.playerAvatar, "field runtime has no player avatar owner")
      avatar:queueTransition(avatar:durableState())
      runtime:applyAvatarTransitions()
      assert(runtime.audio, "field audio is unavailable"):play("SEQ_SE_GS_KI_YURERU")
      runtime.actors:setGesturePresentation(actorId, "apricorn_tree_wiggle", frame)
    elseif phase == "wiggle" then
      runtime.actors:setGesturePresentation(actorId, "apricorn_tree_wiggle", frame)
    elseif phase == "expel" then
      runtime.actors:setGesturePresentation(actorId, "apricorn_tree_expel", frame)
      if frame == 0 then
        treePresentation:spawnFruit(actorId, treeForActor(nil, actorId).apricornKey)
      end
    elseif phase == "jump" then
      treePresentation:advanceFruit(frame)
      if frame == 0 then
        assert(runtime.audio, "field audio is unavailable"):play("SEQ_SE_GS_FW255E")
        runtime.actors:clearGesturePresentation(actorId)
      end
    end
  end
  local function finishTreeAnimation(_, actorId)
    treePresentation:clearFruit()
    runtime.actors:clearGesturePresentation(actorId)
    local avatar = assert(runtime.playerAvatar, "field runtime has no player avatar owner")
    avatar:queueTransition(avatar:durableState())
    runtime:applyAvatarTransitions()
  end
  return {
    treeForActor = treeForActor,
    colorForActor = colorForActor,
    give = give,
    displayName = displayName,
    treeAvailable = treeAvailable,
    depleteTree = depleteTree,
    beginTreeAnimation = beginTreeAnimation,
    advanceTreeAnimation = advanceTreeAnimation,
    finishTreeAnimation = finishTreeAnimation,
  }
end

local function apricornKurtService(runtime)
  local function martService()
    return assert(runtime.martService, "Kurt's order state requires the MartService owner")
  end
  local function pendingOrder()
    return martService():pendingKurt()
  end
  local function pendingQuantity()
    local order = pendingOrder()
    return order and order.quantity or 0
  end
  local function pendingBallNativeId(scriptId)
    local order = pendingOrder()
    if order == nil then
      Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "Kurt Ball query requires a pending order", {
        scriptId = scriptId,
      })
    end
    local ballKey = KurtConversions.ballItemKey(order.apricornKey)
    return assert(runtime.itemCatalog, "Kurt Ball query requires the item catalog"):item(ballKey).nativeId
  end
  local function total()
    return martService():apricornTotal()
  end
  local function clear()
    return martService():clearKurt()
  end
  return {
    pendingQuantity = pendingQuantity,
    pendingBallNativeId = pendingBallNativeId,
    total = total,
    clear = clear,
  }
end

---@param runtime FieldRuntime
---@param options FieldScriptCompositionOptions
---@return FieldScriptCompositionResult
function FieldScriptComposition.compose(runtime, options)
  assert(type(options) == "table", "field script composition options are required")
  assert(options.followerInteractionCatalog ~= nil, "the validated follower interaction catalog is required")
  assert(options.followerReactionTicks ~= nil, "the follower reaction emote durations are required")
  assert(
    options.mons and options.itemCatalog and options.followingMon and options.clock,
    "follower interaction services are required"
  )
  assert(runtime.fashionCase ~= nil, "Fashion Case state is required for follower interactions")
  local function currentFieldMap()
    return runtime.session and runtime.session.currentMap or runtime.runtimeMap
  end
  local function currentFieldCamera()
    return runtime.camera
  end
  local celebiTimeTravelScene = CelebiTimeTravelScene.new({
    actors = runtime.actors,
    followingMon = options.followingMon,
    currentCamera = currentFieldCamera,
    currentMap = currentFieldMap,
  })
  runtime.celebiTimeTravelScene = celebiTimeTravelScene
  local function currentPlayerPosition()
    local player = runtime.session and runtime.session.player or runtime.player
    if player == nil then
      return nil
    end
    return { x = player.worldX, y = player.worldY, z = player.worldZ }
  end
  local function currentTimeOfDay()
    return currentTimeOfDayCode(runtime)
  end
  -- The legend flies in above its tile as a map actor: on both versions it is
  -- the fifth object of its map.
  local LEGEND_ACTOR_OBJECT_INDEX = 5
  local function legendActorId()
    local actors = assert(runtime.actors, "Ho-Oh scene requires the field actors")
    return actors, assert(actors:actorIdForMapIndex(LEGEND_ACTOR_OBJECT_INDEX), "Ho-Oh scene legend actor is missing")
  end
  local function setLegendActorHeight(tiles)
    local actors, actorId = legendActorId()
    actors:setPresentationOffset(actorId, { x = 0, y = tiles, z = 0 })
  end
  local function revealLegendActor()
    local actors, actorId = legendActorId()
    actors:show(actorId)
  end
  -- The legend object's second looping sequence; nil returns it to its idle loop.
  local function setLegendActorFlap(tick)
    local actors, actorId = legendActorId()
    if tick == nil then
      actors:clearGesturePresentation(actorId)
    else
      actors:setGesturePresentation(actorId, "legend_flap", tick)
    end
  end
  local function allowLegendActorAnimation(allowed)
    local actors, actorId = legendActorId()
    actors:setPresentationTickAllowedWhileLocked(actorId, allowed)
  end
  local legendCutscene = HoOhAppearanceScene.new({
    versionId = runtime.versionId,
    playerPosition = currentPlayerPosition,
    currentCamera = currentFieldCamera,
    timeOfDayCode = currentTimeOfDay,
    setBirdHeight = setLegendActorHeight,
    revealBird = revealLegendActor,
    setBirdFlap = setLegendActorFlap,
    setBirdAnimationAllowance = allowLegendActorAnimation,
    audio = options.audioService,
    cacheFs = options.cacheFs,
  })
  runtime.hoOhAppearanceScene = legendCutscene
  local function requestStartMenuReopen()
    runtime.applicationHost:requestReopen()
  end
  local function applyAvatarTransitionsForScripts()
    return runtime:applyAvatarTransitions()
  end
  local function changeWeather(_, weatherId)
    runtime:_setLiveWeather(assert(runtime.runtimeMap), weatherId)
  end
  local function blackoutSourceMap()
    return assert(runtime.runtimeMap, "blackout swaps require the live source map")
  end
  -- The companion script services ride the composed feature when the
  -- runtime owns one; rigs without a feature composition keep nils here
  -- and the companion operations fault on use instead of answering
  -- through a fabricated owner.
  local gear = runtime.pokegear
  local gearHost = type(gear) == "table" and gear.scriptHost or nil
  local gearRadio = type(gear) == "table" and gear.radioEffects or nil
  local gearCatalog = runtime.pokegearCatalog
  -- The Spiky-Ear Pichu gift couples two already-live owners: the party
  -- service inserts the event mon and Pokedex knowledge records the
  -- received species. The catch stages before insertion and publishes
  -- only on success, so a full party leaves both owners untouched.
  local specialMonGifts = {}
  function specialMonGifts:giveSpikyEarPichu()
    local caught = assert(runtime.dexKnowledge, "script gifts require Pokedex knowledge"):capture("PICHU")
    if not options.mons:giveSpikyEarPichu() then
      return false
    end
    assert(caught.isCurrent(), "gift Pokedex candidate became stale")
    caught.publish()
    return true
  end
  local scripts = FieldScripts.new({
    cacheFs = options.cacheFs,
    overrideFs = runtime.overrideFs,
    eventState = runtime.eventState,
    actors = runtime.actors,
    player = runtime.player,
    playerAvatar = runtime.playerAvatar,
    avatarApplier = applyAvatarTransitionsForScripts,
    profile = runtime.playerData.profile,
    dialogue = runtime.dialogue,
    messageProvider = runtime.messageProvider,
    layout = options.layoutMessage,
    fontDef = options.fontDef,
    frameIndex = runtime.playerData.options.textFrame,
    signpost = runtime.signpost,
    windowStyles = runtime.windowStyles,
    transition = runtime.transition,
    mapLoader = runtime.mapLoader,
    sourceMap = runtime.runtimeMap,
    seedText = runtime.versionId .. ":" .. runtime.runtimeMap.mapId,
    effects = runtime.fieldTerrainEffectController,
    audio = options.audioService,
    fieldAudio = runtime.audio or (runtime.scriptHosts and runtime.scriptHosts.fieldAudio),
    weather = { change = changeWeather },
    camera = runtime.scriptHosts and runtime.scriptHosts.camera,
    screen = runtime.screenFade,
    events = runtime.scriptHosts and runtime.scriptHosts.events,
    auxiliaryUi = runtime.auxiliaryFieldUi,
    contextChoice = runtime.contextChoiceProvider,
    menu = runtime.menuHost,
    yesNoHost = runtime.yesNoHost,
    startMenuReopen = { request = requestStartMenuReopen },
    mons = options.mons,
    specialMonGifts = specialMonGifts,
    items = options.items,
    itemCatalog = options.itemCatalog,
    followingMon = options.followingMon,
    celebiCinematic = celebiTimeTravelScene,
    legendCutscene = legendCutscene,
    followerInteractionCatalog = options.followerInteractionCatalog,
    followerReactionTicks = options.followerReactionTicks,
    clock = options.clock,
    fashionCase = runtime.fashionCase,
    starterProvider = options.starterProvider,
    starterChoice = options.starterChoice,
    partySelection = options.partySelection,
    mart = options.mart,
    travel = options.travel,
    fieldMoves = options.fieldMoves,
    monNaming = options.monNaming,
    followerTransition = options.followerTransition,
    starterBalls = options.starterBalls,
    pcApplications = runtime.pcApplicationHost,
    pcTerminal = runtime.pcTerminal,
    battle = options.battle,
    overworld = runtime.overworld,
    propAnimations = runtime.propAnimations,
    pokemonCenterHeal = runtime.pokemonCenterHeal,
    blackout = {
      loader = runtime.mapLoader,
      sourceMap = blackoutSourceMap,
    },
    timeOfDay = timeOfDayService(runtime),
    trainerCardStars = trainerCardStarsService(runtime),
    apricorn = apricornService(runtime),
    apricornKurt = apricornKurtService(runtime),
    kurtBoxHost = assert(runtime.kurtBoxHost, "Kurt Box host is composed before field scripts"),
    pokegearApplications = gearHost,
    phoneContactIndex = FieldScriptComposition.phoneContactIndex(gearCatalog),
    pokegearState = runtime.pokegearState,
    phoneGifts = FieldScriptComposition.phoneGiftQueries(
      runtime.pokegearState,
      gearCatalog,
      runtime.pokegearRandom,
      options.itemCatalog
    ),
    radioMusic = gearRadio,
  })
  runtime.blackoutFlow = assert(scripts.blackoutFlow)
  local function restore()
    if options.loadedGame then
      ScriptSave.restore(options.loadedGame.scripts, scripts.scheduler, 0)
      scripts.worldState:restoreRng(options.loadedGame.world)
    end
  end
  return {
    scripts = scripts,
    restore = restore,
  }
end

return FieldScriptComposition
