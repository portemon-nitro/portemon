-- Production FieldState launches for native encounter transitions. The
-- selected game's real derived-asset host and FieldState compositor remain
-- in the path; only audio output is a deterministic host adapter.

local Assert = require("tests.support.Assert")
local CacheService = require("app.src.CacheService")
local DerivedAssetProvisioner = require("app.src.DerivedAssetProvisioner")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldState = require("game.hgss.src.field.FieldState")
local BattleDataCache = require("libs.assets.src.battle.BattleDataCache")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local BattleEncounterSelector = require("libs.hgss.src.transition.BattleEncounterSelector")
local BattleEncounterTransition = require("libs.hgss.src.transition.BattleEncounterTransition")
local TransitionFamilyFactory = require("libs.hgss.src.transition.TransitionFamilyFactory")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local FashionCaseState = require("libs.hgss.src.save.FashionCaseState")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {}

local VERSION = "heartgold"

local function gameRecord()
  return {
    saveId = "save-00000001",
    versionId = VERSION,
    location = { mapSymbol = "MAP_NEW_BARK", fieldX = 10, fieldZ = 10, facing = "south" },
    playerData = {
      profile = {
        name = "GOLD",
        rivalName = "Silver",
        gender = 0,
        trainerId = 1,
        money = 3000,
        badges = 0,
        nationalDex = false,
        runningShoes = false,
        runningShoesLock = false,
      },
      options = { textSpeed = "fastest", textFrame = 0 },
    },
    fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
    fashionCase = FashionCaseState.empty(),
    playTime = PlayTime.new(),
    worldState = FieldEventState.new(),
    mons = require("tests.support.MonBucket").emptyForVersion(VERSION),
    bag = require("libs.hgss.src.save.BagSave").empty(),
    mart = require("libs.hgss.src.save.MartSave").empty(),
  }
end

local function digest(image)
  local hash = 2166136261
  for y = 0, image:getHeight() - 1 do
    for x = 0, image:getWidth() - 1 do
      local red, green, blue, alpha = image:getPixel(x, y)
      for _, channel in ipairs({ red, green, blue, alpha }) do
        hash = (hash * 16777619 + math.floor(channel * 255 + 0.5)) % 4294967296
      end
    end
  end
  return hash
end

local bootFieldWithHost

local function bootField(scope)
  local service = CacheService.new()
  local provisioner = DerivedAssetProvisioner.new({
    service = service,
    versionId = VERSION,
    development = true,
    developmentRepositoryRoot = love.filesystem.getSourceBaseDirectory(),
  })
  scope:own({
    release = function()
      provisioner:dispose()
      service:shutdown()
    end,
  })
  return bootFieldWithHost(scope, provisioner:gameHost(), service)
end

bootFieldWithHost = function(scope, derivedAssets, service)
  local audioOutput = require("tests.acceptance.support.FakeAudioOutput").new()
  local state = FieldState.new(gameRecord(), {
    derivedAssets = derivedAssets,
    audioOutput = audioOutput,
  })
  scope:own({
    release = function()
      state:dispose()
    end,
  })
  local width, height = love.graphics.getDimensions()
  local target = scope:own(love.graphics.newCanvas(width, height))
  local function draw()
    love.graphics.setCanvas(target)
    love.graphics.clear(0, 0, 0, 0)
    state:draw()
    love.graphics.setCanvas()
    return scope:own(target:newImageData())
  end
  local function tick(dt)
    service:update()
    state:update(dt)
  end
  for _ = 1, 480 do
    tick(1 / 30)
    draw()
    if state.runtime.session.mapEntryStage == nil then
      break
    end
  end
  Assert.equal(state.runtime.session.mapEntryStage, nil, "production field boot reaches its presented map")
  Assert.isTrue(
    state.runtime.monService:giveMon({ species = "CHIKORITA", level = 9 }),
    "real field battle has a living lead"
  )
  return state, tick, draw, audioOutput, service
end

local function startWildTransition(state)
  local launchId = state.runtime:launchBattle({
    kind = "wild",
    details = { species = "CATERPIE", level = 3 },
  })
  Assert.isTrue(type(launchId) == "string", "the production field coordinator issues the battle identity")
  return launchId
end

local function startSpecialTrainerTransition(state)
  local trainers = assert(BattleDataCache.loadTrainers(state.runtime.cacheFs)).trainers
  local trainerIds = {}
  for trainerId in pairs(trainers) do
    trainerIds[#trainerIds + 1] = trainerId
  end
  table.sort(trainerIds, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local trainerId = assert(trainerIds[1], "HeartGold trainer catalog has a launchable trainer")
  local launchId = state.runtime:launchBattle({
    kind = "trainer",
    details = { trainer = trainerId, specialBattle = true },
  })
  Assert.isTrue(type(launchId) == "string", "the production field coordinator issues the trainer identity")
  return launchId
end

local function trainerIdForClass(state, trainerClass)
  local trainers = assert(BattleDataCache.loadTrainers(state.runtime.cacheFs)).trainers
  local trainerIds = {}
  for trainerId, trainer in pairs(trainers) do
    if trainer.trainerClass == trainerClass then
      trainerIds[#trainerIds + 1] = trainerId
    end
  end
  table.sort(trainerIds, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return assert(trainerIds[1], "HeartGold catalog contains a trainer for " .. trainerClass)
end

local function sourceSelectorContexts(transitions)
  local contexts = {}
  local function add(context)
    local selection = BattleEncounterSelector.resolve(transitions, context)
    contexts[selection.routeKey] = contexts[selection.routeKey] or context
  end
  local function base(kind)
    return {
      kind = kind,
      doubleBattle = false,
      specialBattle = false,
      alternateTransition = false,
      playerGender = "male",
      terrain = "plain",
      timeOfDay = "day",
    }
  end
  for trainerClass in pairs(transitions.selection.trainerClassRoutes) do
    local context = base("trainer")
    context.trainerClass = trainerClass
    add(context)
  end
  for wildSpecies in pairs(transitions.selection.wildSpeciesRoutes) do
    local context = base("wild")
    context.wildSpecies = wildSpecies
    context.wildSetupFallback = false
    add(context)
  end
  local knownTrainerClass = next(transitions.selection.trainerClassRoutes)
  for _, variant in ipairs({
    { doubleBattle = true },
    { specialBattle = true },
    { alternateTransition = true },
    { specialBattle = true, doubleBattle = true },
  }) do
    local context = base("trainer")
    context.trainerClass = knownTrainerClass or "SOURCE_UNKNOWN_TRAINER"
    context.specialBattle = variant.specialBattle == true
    context.doubleBattle = variant.doubleBattle == true
    context.alternateTransition = variant.alternateTransition == true
    add(context)
  end
  local unknownTrainer = base("trainer")
  unknownTrainer.trainerClass = "SOURCE_UNKNOWN_TRAINER"
  add(unknownTrainer)
  local wildFallback = base("wild")
  wildFallback.wildSpecies = "CATERPIE"
  wildFallback.wildSetupFallback = true
  add(wildFallback)
  local wildDoublesFallback = base("wild")
  wildDoublesFallback.wildSpecies = "CATERPIE"
  wildDoublesFallback.wildSetupFallback = true
  wildDoublesFallback.doubleBattle = true
  add(wildDoublesFallback)
  for _, fallback in ipairs(transitions.selection.fallbackRoutes) do
    local context = base(fallback.battleKind)
    context.terrain = fallback.terrain
    context.timeOfDay = fallback.timeOfDay
    if fallback.battleKind == "trainer" then
      context.trainerClass = "SOURCE_UNKNOWN_TRAINER"
    else
      context.wildSpecies = "CATERPIE"
      context.wildSetupFallback = true
    end
    add(context)
  end
  for routeKey, context in pairs(contexts) do
    local needsGender = false
    for _, input in ipairs(assert(transitions.routes[routeKey]).requiredContext) do
      needsGender = needsGender or input == "playerGender"
    end
    if needsGender then
      local male = {}
      local female = {}
      for key, value in pairs(context) do
        male[key] = value
        female[key] = value
      end
      male.playerGender = "male"
      female.playerGender = "female"
      contexts[routeKey] = { male, female }
    else
      contexts[routeKey] = { context }
    end
  end
  return contexts
end

function T.A43_field_launch_executes_its_selected_native_route_to_completion(scope)
  Assert.isTrue(RomImporter.isReady(VERSION), "HeartGold dump and derived cache are required")
  local state, tick, draw = bootField(scope)
  local launchId = startWildTransition(state)
  for _ = 1, 240 do
    tick(1 / 30)
    draw()
    local status = state.battleEnvelope:transitionStatus()
    if status == nil or status.phase == "complete" or status.phase == "failed" then
      break
    end
  end
  local status = state.battleEnvelope:transitionStatus()
  Assert.isTrue(status ~= nil, "field launch retains its selected transition owner")
  Assert.equal(status.routeKey, "wild/generic", "ordinary wild launch selects the source generic-wild route")
  Assert.equal(status.phase, "complete", "every selected native task reaches its declared completion")
  Assert.isTrue(state.runtime:battleStatus(launchId) ~= nil, "battle construction follows native transition completion")
end

function T.A43_field_launch_executes_its_selected_special_trainer_route_to_completion(scope)
  Assert.isTrue(RomImporter.isReady(VERSION), "HeartGold dump and derived cache are required")
  local state, tick, draw = bootField(scope)
  local launchId = startSpecialTrainerTransition(state)
  for _ = 1, 240 do
    tick(1 / 30)
    draw()
    local status = state.battleEnvelope:transitionStatus()
    if status == nil or status.phase == "complete" or status.phase == "failed" then
      break
    end
  end
  local status = state.battleEnvelope:transitionStatus()
  Assert.isTrue(status ~= nil, "trainer launch retains its selected transition owner")
  Assert.equal(status.routeKey, "trainer/generic", "source special-trainer fallback selects the generic route")
  Assert.equal(status.phase, "complete", "selected trainer callback reaches its declared completion")
  Assert.isTrue(
    state.runtime:battleStatus(launchId) ~= nil,
    "trainer construction follows native transition completion"
  )
end

function T.A43_production_engine_closes_every_selector_reachable_compiled_route(scope)
  Assert.isTrue(RomImporter.isReady(VERSION), "HeartGold dump and derived cache are required")
  local state, _, _, _, service = bootField(scope)
  local manifest = assert(BattlePresentationCache.load(state.runtime.cacheFs))
  local transitions = manifest.transitions
  local contexts = sourceSelectorContexts(transitions)
  local routeKeys = {}
  for routeKey in pairs(transitions.routes) do
    routeKeys[#routeKeys + 1] = routeKey
  end
  table.sort(routeKeys)
  local failures = {}
  for _, routeKey in ipairs(routeKeys) do
    local routeContexts = contexts[routeKey]
    if routeContexts == nil then
      failures[#failures + 1] = routeKey .. ": no source-normalized selector context reaches this compiled route"
    else
      for _, context in ipairs(routeContexts) do
        local audioOperations = {}
        local transition = BattleEncounterTransition.new({
          manifest = manifest,
          cacheFs = state.runtime.cacheFs,
          battleAssets = state.runtime.derivedAssets,
          sceneKey = assert(manifest.scenes[1]).key,
          audioOperations = {
            emit = function(_, operation)
              audioOperations[#audioOperations + 1] = operation
            end,
          },
          effectFactory = function(route, resources, launchContext)
            return TransitionFamilyFactory.new(route, resources, love.graphics, {
              camera = state.runtime.camera,
              fieldRenderer = assert(state.presentationResources.renderer),
            }, launchContext)
          end,
        })
        local capture = nil
        local cleaned = false
        local function cleanup()
          if cleaned then
            return
          end
          cleaned = true
          if capture ~= nil then
            capture:dispose()
            capture = nil
          end
          transition:dispose()
        end
        scope:own({ release = cleanup })
        local phase = nil
        local routeError = nil
        for _ = 1, 600 do
          local ok, result = pcall(transition.prepare, transition, context)
          if not ok then
            routeError = result
            break
          end
          phase = result
          if phase == "ready" then
            break
          end
          service:update()
        end
        if routeError == nil and phase == "ready" then
          local ok, result = pcall(transition.start, transition)
          if not ok then
            routeError = result
          else
            capture = state:_captureTransitionLayers()
            transition:acceptFieldLayers(capture)
            local status = transition:status()
            for _ = 1, 5000 do
              if status.phase ~= "running" then
                break
              end
              local stepOk, stepError = pcall(transition.stepSourceTick, transition)
              if not stepOk then
                routeError = stepError
                break
              end
              status = transition:status()
              if status.phase == "running" and transition:frame().requiresCurrentFieldLayers == true then
                local nextCapture = state:_captureTransitionLayers()
                transition:acceptFieldLayers(nextCapture)
                if capture ~= nil then
                  capture:dispose()
                end
                capture = nextCapture
              end
            end
            if routeError == nil and status.phase ~= "complete" then
              routeError = "native callback did not reach completion within the source-tick bound"
            end
            if routeError == nil then
              local selected = BattleEncounterSelector.resolve(transitions, context)
              local operation = audioOperations[1]
              if operation == nil or operation.kind ~= "start-battle-music" or operation.role ~= selected.musicRole then
                routeError = "callback did not emit its selected typed battle-music identity"
              end
            end
          end
        elseif routeError == nil then
          routeError = "selected scene receipt did not become ready within the source-tick bound"
        end
        cleanup()
        if transition._resources ~= nil then
          routeError = routeError or "transition disposal retained decoded route resources"
        end
        if transition._effect ~= nil then
          routeError = routeError or "transition disposal retained its native callback task"
        end
        if routeError ~= nil then
          failures[#failures + 1] = routeKey .. " (" .. context.playerGender .. "): " .. tostring(routeError)
        end
      end
    end
  end
  Assert.equal(
    #failures,
    0,
    "every compiled route has a normalized source context, completes through the production family, and releases resources: "
      .. table.concat(failures, " | ")
  )
end

local function assertMechanismPixels(scope, scenario)
  Assert.isTrue(RomImporter.isReady(VERSION), "HeartGold dump and derived cache are required")
  local state, tick, draw = bootField(scope)
  local manifest = assert(BattlePresentationCache.load(state.runtime.cacheFs))
  local expectedRoute = scenario.route(manifest.transitions, state)
  local route = assert(manifest.transitions.routes[expectedRoute], "source-derived mechanism route is compiled")
  Assert.equal(route.role, scenario.role, "compiled route retains its source family role")
  if scenario.taskKind ~= nil then
    Assert.equal(route.task.kind, scenario.taskKind, "compiled route carries the source task kind")
  end
  local baseline = digest(draw())
  local launchId = scenario.launch(state)
  local changedFrames = {}
  local selectedRoute = nil
  local complete = false
  for _ = 1, 240 do
    tick(1 / 30)
    local image = draw()
    local status = state.battleEnvelope:transitionStatus()
    if status ~= nil then
      selectedRoute = status.routeKey
      Assert.equal(status.routeKey, expectedRoute, "real FieldState inputs select the source-derived route")
      if status.phase == "running" then
        local imageHash = digest(image)
        if imageHash ~= baseline and changedFrames[#changedFrames] ~= imageHash then
          changedFrames[#changedFrames + 1] = imageHash
        end
      elseif status.phase == "complete" then
        complete = true
        break
      elseif status.phase == "failed" then
        break
      end
    else
      local launchStatus = state.runtime:battleStatus(launchId)
      error(
        scenario.mechanism
          .. " route failed before producing a native frame: "
          .. tostring(launchStatus and launchStatus.error),
        0
      )
    end
  end
  Assert.equal(selectedRoute, expectedRoute, scenario.mechanism .. " route remains selected during its native task")
  Assert.isTrue(complete, scenario.mechanism .. " native task reaches its source completion boundary")
  Assert.isTrue(
    #changedFrames > 0,
    scenario.mechanism .. " produces intermediate pixel changes in production FieldState composition"
  )
end

function T.A44_brightness_fallback_changes_composed_field_pixels(scope)
  assertMechanismPixels(scope, {
    mechanism = "brightness-only",
    role = "plain-wild-fallback",
    route = function(transitions)
      local fallback = transitions.selection.fallbackRoutes
      for _, time in ipairs({ "day", "late" }) do
        for _, row in ipairs(fallback) do
          if row.terrain == "plain" and row.timeOfDay == time and row.battleKind == "wild" then
            return row.route
          end
        end
      end
      error("source fallback catalog has a plain wild route")
    end,
    launch = function(state)
      local launchId = state.runtime:launchBattle({
        kind = "wild",
        details = { species = "CATERPIE", wildSetupFallback = true },
      })
      return assert(launchId)
    end,
  })
end

function T.A44_captured_field_feedback_changes_composed_pixels(scope)
  assertMechanismPixels(scope, {
    mechanism = "captured-field distortion",
    role = "camera-and-fade-transition",
    taskKind = "field-camera-pose-sequence",
    route = function(transitions)
      return assert(transitions.selection.wildSpeciesRoutes.GROUDON)
    end,
    launch = function(state)
      return assert(state.runtime:launchBattle({ kind = "wild", details = { species = "GROUDON", level = 40 } }))
    end,
  })
end

function T.A44_scanline_window_trainer_changes_composed_pixels(scope)
  assertMechanismPixels(scope, {
    mechanism = "scanline/window",
    role = "trainer-transition",
    route = function(transitions)
      return assert(transitions.selection.trainerClassRoutes.EXECUTIVE_PETREL)
    end,
    launch = function(state)
      local trainerId = trainerIdForClass(state, "EXECUTIVE_PETREL")
      return assert(state.runtime:launchBattle({ kind = "trainer", details = { trainer = trainerId } }))
    end,
  })
end

function T.A44_sprite_heavy_wild_changes_composed_pixels(scope)
  assertMechanismPixels(scope, {
    mechanism = "sprite-heavy",
    role = "generic-wild-transition",
    route = function(transitions)
      return transitions.selection.wildRules.fallbackRoute
    end,
    launch = function(state)
      return startWildTransition(state)
    end,
  })
end

function T.A44_camera_model_route_changes_composed_pixels(scope)
  assertMechanismPixels(scope, {
    mechanism = "model-heavy",
    role = "camera-and-fade-transition",
    taskKind = "field-camera-perspective-distance-fade",
    route = function(transitions)
      return assert(transitions.selection.wildSpeciesRoutes.HO_OH)
    end,
    launch = function(state)
      return assert(state.runtime:launchBattle({ kind = "wild", details = { species = "HO_OH", level = 45 } }))
    end,
  })
end

function T.A45_field_transition_survives_resize_and_update_partition_changes(scope)
  Assert.isTrue(RomImporter.isReady(VERSION), "HeartGold dump and derived cache are required")
  local state, tick, draw = bootField(scope)
  local manifest = assert(BattlePresentationCache.load(state.runtime.cacheFs))
  local expectedMusic = assert(manifest.transitions.selection.wildRules.fallbackMusicRole)
  startWildTransition(state)
  tick(1 / 30)
  draw()
  local firstSourceFrame = digest(draw())
  local beforeResize = assert(state.battleEnvelope:transitionStatus())
  Assert.equal(
    state.battleEnvelope:musicNote(),
    "started:" .. expectedMusic,
    "the selected semantic music role reaches the typed audio operation"
  )
  local width, height = love.graphics.getDimensions()
  state:resize(width + 80, height + 40)
  local afterResize = assert(state.battleEnvelope:transitionStatus())
  Assert.equal(afterResize.routeKey, beforeResize.routeKey, "resize preserves the selected semantic route")
  Assert.equal(afterResize.phase, beforeResize.phase, "resize does not advance native task state")
  state:resize(width, height)
  Assert.equal(digest(draw()), firstSourceFrame, "resize round-trip preserves the composed source-tick frame")
  for _ = 1, 240 do
    tick(1 / 60)
    tick(1 / 60)
    draw()
    local status = state.battleEnvelope:transitionStatus()
    if status == nil or status.phase == "complete" or status.phase == "failed" then
      break
    end
  end
  local final = state.battleEnvelope:transitionStatus()
  Assert.isTrue(final ~= nil, "resize and equivalent update partitions retain the transition status")
  Assert.equal(final.routeKey, "wild/generic", "host schedule does not change the source-selected route")
  Assert.equal(final.phase, "complete", "host schedule does not restart or strand the native task")
end

function T.A46_started_transition_draw_failure_reaches_field_recovery(scope)
  Assert.isTrue(RomImporter.isReady(VERSION), "HeartGold dump and derived cache are required")
  local state, tick, draw = bootField(scope)
  local launchId = startWildTransition(state)
  local originalDraw = love.graphics.draw
  local injected = false
  local drawsThisFrame = 0
  local idleDrawCount = 0
  love.graphics.draw = function(...)
    drawsThisFrame = drawsThisFrame + 1
    local transition = state.battleEnvelope:transitionStatus()
    if transition ~= nil and transition.phase == "running" and drawsThisFrame > idleDrawCount and not injected then
      injected = true
      error("injected transition platform draw failure")
    end
    return originalDraw(...)
  end
  local ok, result = xpcall(function()
    -- Establish the real field renderer's idle draw count. The trap fires on
    -- an additional draw owned by the running transition renderer.
    draw()
    idleDrawCount = drawsThisFrame
    tick(1 / 30)
    draw()
    Assert.isTrue(injected, "a real native transition platform draw reached the injected failure")
    for _ = 1, 12 do
      tick(1 / 30)
      local status = state.runtime:battleStatus(launchId)
      if status ~= nil and status.phase == "aborting" then
        break
      end
    end
    local status = assert(state.runtime:battleStatus(launchId), "the original launch remains observable")
    Assert.equal(status.phase, "aborting", "post-start renderer failure enters C01 recovery")
    Assert.isTrue(
      tostring(status.error):find("injected transition platform draw failure", 1, true) ~= nil,
      "C01 retains the original platform failure"
    )
    Assert.isNil(
      state.battleEnvelope:transitionStatus(),
      "failed post-start draw releases native route and captured planes"
    )
  end, debug.traceback)
  love.graphics.draw = originalDraw
  if not ok then
    error(result, 0)
  end
end

function T.A46_selected_transition_resource_failure_keeps_launch_identity(scope)
  Assert.isTrue(RomImporter.isReady(VERSION), "HeartGold dump and derived cache are required")
  local state, tick = bootField(scope)
  local cacheFs = state.runtime.cacheFs
  local manifest = assert(BattlePresentationCache.load(cacheFs), "the real generated transition manifest is loaded")
  local route = assert(manifest.transitions.routes["wild/generic"], "source selector route is staged")
  local resourceKey = assert(route.resources and route.resources[1], "selected route declares transitive resources")
  local descriptor = assert(manifest.resources[resourceKey], "selected route resource has a generated descriptor")
  local originalLoadLua = cacheFs.loadLua
  cacheFs.loadLua = function(self, path)
    if path == descriptor.path then
      return nil, "injected selected transition resource failure"
    end
    return originalLoadLua(self, path)
  end
  local ok, result = xpcall(function()
    local launchId = startWildTransition(state)
    for _ = 1, 12 do
      tick(1 / 30)
      local status = state.runtime:battleStatus(launchId)
      if status ~= nil and status.phase == "aborting" then
        break
      end
    end
    local status =
      assert(state.runtime:battleStatus(launchId), "failed launch remains observable by its issued identity")
    Assert.equal(status.phase, "aborting", "missing selected resource takes the safe uncommitted failure path")
    Assert.isTrue(
      tostring(status.error):find("injected selected transition resource failure", 1, true) ~= nil,
      "safe failure retains the original staged-resource cause"
    )
    Assert.isTrue(
      state.battleEnvelope:transitionStatus() == nil,
      "failed preparation disposes the transition and its launch-owned capture"
    )
  end, debug.traceback)
  cacheFs.loadLua = originalLoadLua
  if not ok then
    error(result, 0)
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump", "derived_assets" }
suite.metadata.derivedAssets = {
  "field-runtime",
  "map:60",
  "battle-presentation:global",
}
suite.metadata.tags = { "field", "battle", "transition" }
return suite
