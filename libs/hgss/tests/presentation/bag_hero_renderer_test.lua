-- Bag hero model realization: gendered model selection, pocket pose and
-- pattern synchronization to the presenter-owned semantic frame, and
-- exactly-once GPU resource ownership. The presenter selects pocket state
-- and advances the frame on the fixed cadence; this renderer only
-- materializes that semantic time into animation players, so repeated draws
-- at one frame never advance playback. Model and renderer collaborators are
-- narrow recording doubles; no graphics context is required.

local Assert = require("tests.support.Assert")
local ControllableImageOwner = require("tests.support.ControllableImageOwner")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local FakeGraphics = require("tests.support.FakeGraphics").new
local FakePreparationQueue = require("tests.support.FakePreparationQueue")
local SynchronousWaitProbe = require("tests.support.SynchronousWaitProbe")

local HERO_MODULE = "libs.hgss.src.presentation.BagHeroRenderer"
local POOL_MODULE = "libs.hgss.src.presentation.GpuAssetPool"
local DEFINITION_MODULE = "libs.hgss.src.presentation.ModelDefinition"
local INSTANCE_MODULE = "libs.hgss.src.presentation.ModelInstance"
local RENDERER_MODULE = "libs.hgss.src.presentation.FieldRenderer"
local SCENE_MODULE = "libs.hgss.src.presentation.SceneDescriptor"

local T = {}

local POCKETS = { "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }

local function imageRef(path)
  return { image = path, width = 256, height = 192 }
end

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

local function constantChannel()
  return { source = "constant", value = 0 }
end

local function trsClip(id, semanticName)
  return {
    id = id,
    name = id,
    category = "joint",
    kind = "trs",
    frameCount = 4,
    tracks = { { target = 0, targetIndex = 0 } },
    semanticNames = { semanticName },
    compiled = {
      anmFlags = 0,
      rotData = {},
      pivotData = { { 0, 0, 0, 0, 0 } },
      targets = {
        {
          nodeIndex = 0,
          channels = {
            trans = { x = constantChannel(), y = constantChannel(), z = constantChannel() },
            rot = constantChannel(),
            scale = { x = constantChannel(), y = constantChannel(), z = constantChannel() },
          },
        },
      },
    },
  }
end

local function dynamicMaterial()
  return {
    id = 0,
    name = "widget",
    baseColor = { r = 255, g = 255, b = 255, a = 255 },
    colors = {
      diffuse = { r = 255, g = 255, b = 255 },
      ambient = { r = 255, g = 255, b = 255 },
      specular = { r = 255, g = 255, b = 255 },
      emission = { r = 0, g = 0, b = 0 },
    },
    alphaMode = "opaque",
    polygonMode = "modulation",
    doubleSided = false,
    polygonAlpha = 31,
    texMtxMode = 0,
    texWidth = 64,
    texHeight = 64,
    wrap = { x = "clamp", y = "clamp" },
    flip = { x = false, y = false },
    diffuse = { r = 255, g = 255, b = 255, a = 255 },
  }
end

local function heroDescriptor(gender)
  local clips = {}
  for _, pocket in ipairs(POCKETS) do
    clips[#clips + 1] = trsClip(gender .. ".pose." .. pocket, "pocket." .. pocket .. ".pose")
    clips[#clips + 1] = trsClip(gender .. ".pattern." .. pocket, "pocket." .. pocket .. ".pattern")
  end
  clips[#clips + 1] = trsClip(gender .. ".material", "bag.material")
  return {
    schema = ModelAsset.SCHEMA,
    kind = "nitro-dynamic",
    dynamic = { nodes = {}, transformProgram = {}, batches = {} },
    materials = { dynamicMaterial() },
    animations = clips,
  }
end

local function validManifest()
  local states = {}
  for _, pocket in ipairs(POCKETS) do
    states[#states + 1] = {
      pocket = pocket,
      pose = "pocket." .. pocket .. ".pose",
      pattern = "pocket." .. pocket .. ".pattern",
    }
  end
  return {
    schema = "g4-bag-assets-v21",
    logicalSize = { width = 256, height = 192 },
    hero = {
      background = {
        male = imageRef("assets/generated/bag/hero-backdrop-male.png"),
        female = imageRef("assets/generated/bag/hero-backdrop-female.png"),
      },
      description = {
        frame = {
          image = "assets/generated/bag/description-frame.png",
          rect = rect(0, 144, 256, 48),
        },
        textRect = rect(20, 144, 228, 40),
      },
      model = { male = heroDescriptor("male"), female = heroDescriptor("female") },
      animations = {
        states = states,
        material = { male = "male.material", female = "female.material" },
      },
      presentation = {
        camera = {
          target = { x = 0, y = 0, z = 0 },
          distance = 339.9,
          angleXDegrees = 328.4,
          angleYDegrees = 28.3,
          perspectiveType = 0,
          perspectiveAngle = 256,
          clipNear = 123.0,
          clipFar = 1700.0,
        },
        transform = {
          translation = { x = 0, y = -45, z = 0 },
          rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
          scale = { x = 1, y = 1, z = 1 },
        },
        lights = {
          count = 4,
          color = { r = 31, g = 31, b = 31 },
          vectors = {
            { x = 1, y = 0, z = 0 },
            { x = 1, y = 0, z = 0 },
            { x = 1, y = 0, z = 0 },
            { x = 1, y = 0, z = 0 },
          },
        },
        materials = {
          diffuse = { r = 15, g = 15, b = 15 },
          ambient = { r = 10, g = 10, b = 10 },
          specular = { r = 15, g = 15, b = 15 },
          emission = { r = 15, g = 15, b = 15 },
        },
        edgeColors = {
          { r = 10, g = 10, b = 10 },
          { r = 15, g = 9, b = 4 },
          { r = 20, g = 20, b = 20 },
          { r = 0, g = 0, b = 0 },
          { r = 0, g = 0, b = 0 },
          { r = 0, g = 0, b = 0 },
          { r = 0, g = 0, b = 0 },
          { r = 0, g = 0, b = 0 },
        },
      },
    },
  }
end

---@param pocket string
---@param frame integer
---@param framing { angleXDegrees: number, angleYDegrees: number, distance: number, modelY: number }?
---@return { pocket: string, pose: string, pattern: string, frame: integer, framing: table }
local function heroStatus(pocket, frame, framing)
  return {
    pocket = pocket,
    pose = "pocket." .. pocket .. ".pose",
    pattern = "pocket." .. pocket .. ".pattern",
    frame = frame,
    framing = framing or { angleXDegrees = 328.4, angleYDegrees = 28.3, distance = 339.9, modelY = -45 },
  }
end

local function heroPlacement()
  return {
    frame = { x = 0, y = 0, width = 256, height = 192 },
    origin = { x = 0, y = 0 },
    scale = 1,
    logicalWidth = 256,
    logicalHeight = 192,
    clipRect = { x = 0, y = 0, width = 256, height = 192 },
    pixelScale = 1,
    pixelRatio = 1,
    visibleLogicalRect = { x = 0, y = 0, width = 256, height = 192 },
    crop = { left = 0, right = 0, top = 0, bottom = 0 },
  }
end

-- The hero realizes through the presentation preparation worker: this stand-in
-- answers ready requests for already-prepared geometry.
local function fakePreparationQueue()
  return FakePreparationQueue.new()
end

local function stubCache()
  return {
    read = function(_)
      return nil
    end,
  }
end

-- Recording doubles for the shared model stack. The hero renderer must reuse
-- the production model machinery; these doubles stand in for GPU-backed
-- collaborators so frame synchronization is deterministic without graphics.
local function makeDoubles()
  local rec = {
    descriptors = {},
    definitionKeys = {},
    instances = {},
    pools = {},
    renderers = {},
    draws = {},
    meshRequests = {},
    failMesh = false,
    failDefinition = false,
  }
  local poolModule = {}
  local PoolClass = {}
  PoolClass.__index = PoolClass
  function PoolClass:meshFor(path)
    rec.meshRequests[#rec.meshRequests + 1] = tostring(path)
    if rec.failMesh then
      error("injected mesh failure for " .. tostring(path), 0)
    end
    return { mesh = "mesh:" .. tostring(path), center = { 0, 0, 0 } }
  end
  function PoolClass:preparedMesh(path, await)
    assert(type(await) == "function", "prepared mesh realization needs the preparation await")
    await("g4gx", tostring(path))
    return self:meshFor(path)
  end
  function PoolClass:imageFor(path)
    return { path = path }
  end
  function PoolClass:build(fn)
    return fn()
  end
  function PoolClass:release()
    self.releaseCount = self.releaseCount + 1
  end
  function poolModule.new()
    local pool = setmetatable({ releaseCount = 0 }, PoolClass)
    rec.pools[#rec.pools + 1] = pool
    return pool
  end
  local definitionModule = {}
  function definitionModule.fromNitroDescriptor(desc, opts)
    if rec.failDefinition then
      error("injected definition failure", 0)
    end
    rec.descriptors[#rec.descriptors + 1] = desc
    rec.definitionKeys[#rec.definitionKeys + 1] = opts and opts.key or nil
    local geometry = "bag-hero/" .. tostring(opts and opts.key or "hero") .. "/geometry-0"
    local definition = {
      key = opts and opts.key,
      animations = desc.animations,
      materials = desc.materials or {},
      meshes = { { id = "hero-mesh-0", geometry = geometry } },
    }
    function definition:animation(nameOrSemantic)
      for _, clip in ipairs(self.animations) do
        if clip.name == nameOrSemantic or clip.id == nameOrSemantic then
          return clip
        end
        for _, semantic in ipairs(clip.semanticNames) do
          if semantic == nameOrSemantic then
            return clip
          end
        end
      end
      return nil
    end
    function definition:binding()
      return {}
    end
    return definition
  end
  local instanceModule = {}
  function instanceModule.new(definition, opts)
    local instance = {
      resolveImage = opts and opts.resolveImage or nil,
      definition = definition,
      transform = nil,
      attachments = {},
      plays = {},
      stops = {},
      drawItemsCalls = 0,
    }
    function instance:play(nameOrSemantic, playOpts)
      local clip = definition:animation(nameOrSemantic)
      if clip == nil then
        error("unknown clip " .. tostring(nameOrSemantic), 0)
      end
      local player = { count = 0 }
      function player:updateFixed()
        self.count = self.count + 1
      end
      local attachment = { clip = clip, player = player, loopMode = playOpts and playOpts.loopMode or nil }
      self.attachments[#self.attachments + 1] = attachment
      self.plays[#self.plays + 1] = nameOrSemantic
      return attachment
    end
    function instance:stop(nameOrHandle)
      self.stops[#self.stops + 1] = nameOrHandle
      if type(nameOrHandle) == "table" then
        for index, attachment in ipairs(self.attachments) do
          if attachment == nameOrHandle then
            table.remove(self.attachments, index)
            return 1
          end
        end
        return 0
      end
      local removed = 0
      for index = #self.attachments, 1, -1 do
        local attachment = self.attachments[index]
        local clip = attachment.clip
        local matches = clip.name == nameOrHandle or clip.id == nameOrHandle
        if not matches then
          for _, semantic in ipairs(clip.semanticNames) do
            if semantic == nameOrHandle then
              matches = true
              break
            end
          end
        end
        if matches then
          table.remove(self.attachments, index)
          removed = removed + 1
        end
      end
      return removed
    end
    function instance:evaluatePose() end
    function instance:evaluateMaterials() end
    function instance:effectiveMaterial(materialIndex)
      local material = self.definition.materials[materialIndex + 1]
      if material ~= nil and material.texture ~= nil and self.resolveImage ~= nil then
        return { image = self.resolveImage(material.texture, materialIndex) }
      end
      return {}
    end
    function instance:updateFixed()
      for _, attachment in ipairs(self.attachments) do
        attachment.player:updateFixed()
      end
    end
    function instance:drawItems()
      self.drawItemsCalls = self.drawItemsCalls + 1
      return {}
    end
    rec.instances[#rec.instances + 1] = instance
    return instance
  end
  local rendererModule = {}
  function rendererModule.new()
    local renderer = { draws = 0, releaseCount = 0 }
    function renderer:draw(...)
      self.draws = self.draws + 1
      rec.draws[#rec.draws + 1] = { ... }
    end
    function renderer:release()
      self.releaseCount = self.releaseCount + 1
    end
    rec.renderers[#rec.renderers + 1] = renderer
    return renderer
  end
  local sceneModule = {
    MIRRORED_REPEAT = "mirror",
  }
  function sceneModule.wrap()
    return { x = "clamp", y = "clamp" }
  end
  return rec,
    {
      [POOL_MODULE] = poolModule,
      [DEFINITION_MODULE] = definitionModule,
      [INSTANCE_MODULE] = instanceModule,
      [RENDERER_MODULE] = rendererModule,
      [SCENE_MODULE] = sceneModule,
    }
end

local DOUBLE_NAMES = { POOL_MODULE, DEFINITION_MODULE, INSTANCE_MODULE, RENDERER_MODULE, SCENE_MODULE }

local function installDoubles(doubles)
  local saved = {}
  for _, name in ipairs(DOUBLE_NAMES) do
    saved[name] = package.loaded[name]
    package.loaded[name] = doubles[name]
  end
  package.loaded[HERO_MODULE] = nil
  return saved
end

local function restoreDoubles(saved)
  for _, name in ipairs(DOUBLE_NAMES) do
    package.loaded[name] = saved[name]
  end
  package.loaded[HERO_MODULE] = nil
end

local function requireHero()
  local ok, mod = pcall(require, HERO_MODULE)
  Assert.isTrue(ok, "the bag hero pane owns its model realization collaborator")
  return assert(mod)
end

---@param fn fun(rec: table)
local function withDoubles(fn)
  local rec, doubles = makeDoubles()
  local saved = installDoubles(doubles)
  local ok, err = pcall(fn, rec)
  restoreDoubles(saved)
  if not ok then
    error(err, 0)
  end
end

---@param instance table
---@return integer[]
local function playerCounts(instance)
  local counts = {}
  for index, attachment in ipairs(instance.attachments) do
    counts[index] = attachment.player.count
  end
  return counts
end

---@param rec table
---@return table
local function activeInstance(rec)
  Assert.isTrue(#rec.instances >= 1, "a draw realizes its hero model instance")
  return rec.instances[#rec.instances]
end

function T.construction_accepts_the_generated_manifest_and_rejects_gaps()
  withDoubles(function()
    local Hero = requireHero()
    local graphics = FakeGraphics({})
    local renderer = Hero.new({ assetPreparation = fakePreparationQueue(), cacheFs = stubCache(), manifest = validManifest(), graphics = graphics })
    renderer:release()
    Assert.throws(function()
      Hero.new({ manifest = validManifest(), graphics = graphics })
    end, "construction without asset access fails")
    Assert.throws(function()
      Hero.new({ assetPreparation = fakePreparationQueue(), cacheFs = stubCache(), graphics = graphics })
    end, "construction without the manifest fails")
    local missingModel = validManifest()
    missingModel.hero.model = nil
    Assert.throws(function()
      Hero.new({ assetPreparation = fakePreparationQueue(), cacheFs = stubCache(), manifest = missingModel, graphics = graphics })
    end, "construction without hero models fails")
    local missingAnimations = validManifest()
    missingAnimations.hero.animations = nil
    Assert.throws(function()
      Hero.new({ assetPreparation = fakePreparationQueue(), cacheFs = stubCache(), manifest = missingAnimations, graphics = graphics })
    end, "construction without hero animation states fails")
    local missingPresentation = validManifest()
    missingPresentation.hero.presentation = nil
    Assert.throws(function()
      Hero.new({ assetPreparation = fakePreparationQueue(), cacheFs = stubCache(), manifest = missingPresentation, graphics = graphics })
    end, "construction without hero presentation fails")
    local missingVectors = validManifest()
    missingVectors.hero.presentation.lights.vectors = nil
    Assert.throws(function()
      Hero.new({ assetPreparation = fakePreparationQueue(), cacheFs = stubCache(), manifest = missingVectors, graphics = graphics })
    end, "construction without hero light vectors fails")
  end)
end

function T.rejects_non_four_light_counts()
  withDoubles(function()
    local Hero = requireHero()
    for _, count in ipairs({ 3, 5 }) do
      local invalid = validManifest()
      invalid.hero.presentation.lights.count = count
      Assert.throws(function()
        Hero.new({ assetPreparation = fakePreparationQueue(), cacheFs = stubCache(), manifest = invalid })
      end, "the hero rejects light count " .. count)
    end
  end)
end

-- The scene lighting registers come from the generated manifest materials,
-- never from hardcoded renderer constants: distinct register colors land in
-- the shared lighting record with the DS RGB555 packing.
function T.scene_registers_come_from_the_manifest_materials()
  withDoubles(function()
    local Hero = requireHero()
    local manifest = validManifest()
    manifest.hero.presentation.materials = {
      diffuse = { r = 1, g = 2, b = 3 },
      ambient = { r = 4, g = 5, b = 6 },
      specular = { r = 7, g = 8, b = 9 },
      emission = { r = 10, g = 11, b = 12 },
    }
    local renderer = Hero.new({ assetPreparation = fakePreparationQueue(), cacheFs = stubCache(), manifest = manifest, graphics = FakeGraphics({}) })
    local record = assert(renderer._sceneRuntime.lighting.records[1], "the scene carries its lighting record")
    Assert.equal(record.diffuseRgb555, 1 + 32 * 2 + 1024 * 3, "diffuse follows the manifest")
    Assert.equal(record.ambientRgb555, 4 + 32 * 5 + 1024 * 6, "ambient follows the manifest")
    Assert.equal(record.specularRgb555, 7 + 32 * 8 + 1024 * 9, "specular follows the manifest")
    Assert.equal(record.emissionRgb555, 10 + 32 * 11 + 1024 * 12, "emission follows the manifest")
    renderer:release()
    local missingMaterials = validManifest()
    missingMaterials.hero.presentation.materials = nil
    Assert.throws(function()
      Hero.new({ assetPreparation = fakePreparationQueue(), cacheFs = stubCache(), manifest = missingMaterials, graphics = FakeGraphics({}) })
    end, "construction without hero material registers fails")
  end)
end

function T.first_draw_realizes_only_the_requested_gender()
  withDoubles(function(rec)
    local Hero = requireHero()
    local manifest = validManifest()
    local renderer = Hero.new({ assetPreparation = fakePreparationQueue(), cacheFs = stubCache(), manifest = manifest, graphics = FakeGraphics({}) })
    renderer:draw("male", heroStatus("items", 0), heroPlacement())
    Assert.equal(#rec.descriptors, 1, "the first draw realizes one gender model")
    Assert.isTrue(rec.descriptors[1] == manifest.hero.model.male, "the male draw realizes the male descriptor")
    renderer:draw("male", heroStatus("items", 0), heroPlacement())
    Assert.equal(#rec.descriptors, 1, "a repeated male draw realizes nothing further")
    renderer:draw("female", heroStatus("items", 0), heroPlacement())
    Assert.equal(#rec.descriptors, 2, "the first female draw realizes the second gender lazily")
    Assert.isTrue(rec.descriptors[2] == manifest.hero.model.female, "the female draw realizes the female descriptor")
    renderer:release()
  end)
end

function T.semantic_clips_resolve_to_descriptor_clips_and_reject_unknown_state()
  withDoubles(function(rec)
    local Hero = requireHero()
    local manifest = validManifest()
    local renderer = Hero.new({ assetPreparation = fakePreparationQueue(), cacheFs = stubCache(), manifest = manifest, graphics = FakeGraphics({}) })
    renderer:draw("male", heroStatus("balls", 0), heroPlacement())
    local instance = activeInstance(rec)
    local playedIds = {}
    for _, attachment in ipairs(instance.attachments) do
      playedIds[attachment.clip.id] = true
    end
    Assert.isTrue(playedIds["male.pose.balls"] == true, "the pocket pose resolves by semantic name")
    Assert.isTrue(playedIds["male.pattern.balls"] == true, "the pocket pattern resolves by semantic name")
    Assert.isTrue(playedIds["male.material"] == true, "the gender material resolves by clip id")
    Assert.throws(function()
      renderer:draw("male", {
        pocket = "balls",
        pose = "pocket.bogus.pose",
        pattern = "pocket.balls.pattern",
        frame = 0,
        framing = { angleXDegrees = 328.4, angleYDegrees = 28.3, distance = 339.9, modelY = -45 },
      }, heroPlacement())
    end, "an unresolvable pose clip fails loudly")
    Assert.throws(function()
      renderer:draw("other", heroStatus("balls", 0), heroPlacement())
    end, "an unknown gender fails loudly")
    renderer:release()
  end)
end

function T.frame_zero_starts_without_extra_advancement()
  withDoubles(function(rec)
    local Hero = requireHero()
    local renderer = Hero.new({ assetPreparation = fakePreparationQueue(), cacheFs = stubCache(), manifest = validManifest(), graphics = FakeGraphics({}) })
    renderer:draw("female", heroStatus("medicine", 0), heroPlacement())
    Assert.deepEqual(playerCounts(activeInstance(rec)), { 0, 0, 0 }, "frame zero plays without fast-forward")
    renderer:release()
  end)
end

function T.frame_advance_catches_up_by_the_exact_delta_and_repeated_draws_hold()
  withDoubles(function(rec)
    local Hero = requireHero()
    local renderer = Hero.new({ assetPreparation = fakePreparationQueue(), cacheFs = stubCache(), manifest = validManifest(), graphics = FakeGraphics({}) })
    renderer:draw("male", heroStatus("items", 0), heroPlacement())
    Assert.deepEqual(playerCounts(activeInstance(rec)), { 0, 0, 0 }, "the opening frame holds")
    renderer:draw("male", heroStatus("items", 3), heroPlacement())
    Assert.deepEqual(
      playerCounts(activeInstance(rec)),
      { 3, 3, 3 },
      "three semantic frames advance every player by three steps"
    )
    renderer:draw("male", heroStatus("items", 3), heroPlacement())
    Assert.deepEqual(playerCounts(activeInstance(rec)), { 3, 3, 3 }, "a repeated draw at one frame advances nothing")
    renderer:draw("male", heroStatus("items", 5), heroPlacement())
    Assert.deepEqual(
      playerCounts(activeInstance(rec)),
      { 5, 5, 5 },
      "the next delta advances every player to the new frame"
    )
    renderer:release()
  end)
end

function T.pocket_change_restarts_clips_without_retaining_old_state()
  withDoubles(function(rec)
    local Hero = requireHero()
    local renderer = Hero.new({ assetPreparation = fakePreparationQueue(), cacheFs = stubCache(), manifest = validManifest(), graphics = FakeGraphics({}) })
    renderer:draw("male", heroStatus("items", 4), heroPlacement())
    local first = activeInstance(rec)
    Assert.deepEqual(playerCounts(first), { 4, 4, 4 }, "the opening pocket catches up")
    local stopsBefore = #first.stops
    renderer:draw("male", heroStatus("balls", 0), heroPlacement())
    Assert.isTrue(#first.stops > stopsBefore, "the pocket switch stops the previous clips")
    local second = activeInstance(rec)
    local playedIds = {}
    for _, attachment in ipairs(second.attachments) do
      playedIds[attachment.clip.id] = true
    end
    Assert.isNil(playedIds["male.pose.items"], "the old pose does not survive the switch")
    Assert.isTrue(playedIds["male.pose.balls"] == true, "the new pocket pose plays")
    Assert.deepEqual(playerCounts(second), { 0, 0, 0 }, "the switched pocket restarts at frame zero")
    renderer:release()
  end)
end

function T.backward_frame_restarts_and_catches_up_instead_of_running_backward()
  withDoubles(function(rec)
    local Hero = requireHero()
    local renderer = Hero.new({ assetPreparation = fakePreparationQueue(), cacheFs = stubCache(), manifest = validManifest(), graphics = FakeGraphics({}) })
    renderer:draw("male", heroStatus("items", 5), heroPlacement())
    Assert.deepEqual(playerCounts(activeInstance(rec)), { 5, 5, 5 }, "the opening frame catches up")
    renderer:draw("male", heroStatus("items", 2), heroPlacement())
    local instance = activeInstance(rec)
    Assert.isTrue(#instance.stops >= 1, "a backward frame restarts the active clips")
    Assert.deepEqual(playerCounts(instance), { 2, 2, 2 }, "the restarted clips catch up to the earlier frame")
    renderer:release()
  end)
end

function T.draw_leaves_the_presenter_owned_status_record_untouched()
  withDoubles(function(rec)
    local Hero = requireHero()
    local renderer = Hero.new({ assetPreparation = fakePreparationQueue(), cacheFs = stubCache(), manifest = validManifest(), graphics = FakeGraphics({}) })
    local status = heroStatus("tmhm", 2)
    renderer:draw("male", status, heroPlacement())
    renderer:draw("male", status, heroPlacement())
    Assert.equal(status.frame, 2, "draws never advance the semantic frame they were given")
    Assert.equal(status.pocket, "tmhm", "draws never reselect the pocket they were given")
    Assert.deepEqual(playerCounts(activeInstance(rec)), { 2, 2, 2 }, "the second identical draw holds the frame")
    renderer:release()
  end)
end

function T.realization_failure_unwinds_acquired_resources_exactly_once()
  withDoubles(function(rec)
    local Hero = requireHero()
    local renderer = Hero.new({ assetPreparation = fakePreparationQueue(), cacheFs = stubCache(), manifest = validManifest(), graphics = FakeGraphics({}) })
    rec.failMesh = true
    Assert.throws(function()
      renderer:draw("male", heroStatus("items", 0), heroPlacement())
    end, "a realization failure surfaces instead of substituting geometry")
    Assert.equal(
      rec.meshRequests[1],
      "bag-hero/bag-hero:male/geometry-0",
      "the failure occurs while acquiring the definition mesh geometry"
    )
    local releases = 0
    for _, pool in ipairs(rec.pools) do
      releases = releases + pool.releaseCount
    end
    Assert.equal(releases, 1, "a failed realization releases its partial resources once")
    renderer:release()
    local settled = 0
    for _, pool in ipairs(rec.pools) do
      settled = settled + pool.releaseCount
    end
    for _, owned in ipairs(rec.renderers) do
      settled = settled + owned.releaseCount
    end
    Assert.isTrue(settled >= 1, "teardown after failure stays safe")
  end)
end

function T.target_creation_failure_leaves_realization_teardown_safe()
  withDoubles(function(rec)
    local Hero = requireHero()
    local renderer = Hero.new({
      assetPreparation = fakePreparationQueue(),
      cacheFs = stubCache(),
      manifest = validManifest(),
      graphics = FakeGraphics({ failOnCanvasCall = 1 }),
    })
    Assert.throws(function()
      renderer:draw("male", heroStatus("items", 0), heroPlacement())
    end, "a private target creation failure surfaces")
    Assert.equal(#rec.instances, 1, "target failure occurs after model realization")
    Assert.equal(#rec.pools, 1, "target failure leaves one owned asset pool")
    Assert.equal(#rec.renderers, 1, "target failure leaves one owned field renderer")
    renderer:release()
    Assert.equal(rec.pools[1].releaseCount, 1, "target failure teardown releases the asset pool once")
    Assert.equal(rec.renderers[1].releaseCount, 1, "target failure teardown releases the field renderer once")
    renderer:release()
    Assert.equal(rec.pools[1].releaseCount, 1, "repeated target-failure teardown never releases the pool twice")
    Assert.equal(rec.renderers[1].releaseCount, 1, "repeated target-failure teardown never releases the renderer twice")
  end)
end

function T.repeated_release_stays_a_safe_no_op()
  withDoubles(function(rec)
    local Hero = requireHero()
    local renderer = Hero.new({ assetPreparation = fakePreparationQueue(), cacheFs = stubCache(), manifest = validManifest(), graphics = FakeGraphics({}) })
    renderer:draw("male", heroStatus("items", 0), heroPlacement())
    renderer:release()
    local releases = 0
    for _, pool in ipairs(rec.pools) do
      releases = releases + pool.releaseCount
    end
    for _, owned in ipairs(rec.renderers) do
      releases = releases + owned.releaseCount
    end
    Assert.isTrue(releases >= 1, "the first release frees owned resources")
    renderer:release()
    renderer:release()
    local settled = 0
    for _, pool in ipairs(rec.pools) do
      settled = settled + pool.releaseCount
    end
    for _, owned in ipairs(rec.renderers) do
      settled = settled + owned.releaseCount
    end
    Assert.equal(settled, releases, "repeated releases never free twice")
  end)
end

function T.renders_through_a_reused_private_canonical_target()
  withDoubles(function(rec)
    local Hero = requireHero()
    local callerCanvas = {}
    local callerShader = {}
    local graphics = FakeGraphics({
      canvas = callerCanvas,
      shader = callerShader,
      blendMode = "add",
      blendAlpha = "alphamultiply",
      depthMode = "less",
      depthWrite = true,
      wireframe = true,
      cullMode = "front",
      color = { 0.2, 0.3, 0.4, 0.5 },
      scissor = { 3, 4, 50, 60 },
    })
    local renderer = Hero.new({ assetPreparation = fakePreparationQueue(), cacheFs = stubCache(), manifest = validManifest(), graphics = graphics })
    local placement = {
      frame = { x = 12, y = 20, width = 512, height = 384 },
      scale = 2,
      logicalWidth = 256,
      logicalHeight = 192,
    }

    renderer:draw("male", heroStatus("items", 0), placement)
    renderer:draw("male", heroStatus("items", 0), placement)

    Assert.equal(#graphics.canvases, 1, "the canonical model target is allocated once")
    Assert.deepEqual(
      graphics.blendModes[1],
      { "alpha", "alphamultiply" },
      "the straight-alpha GX result uses straight-alpha composition"
    )
    local target = graphics.canvases[1]
    Assert.equal(target.width, 256, "the private target has canonical width")
    Assert.equal(target.height, 192, "the private target has canonical height")
    Assert.equal(graphics.getCanvas(), callerCanvas, "the caller canvas is restored after composition")
    Assert.isTrue(graphics.getShader() == callerShader, "the caller shader is restored after composition")
    local blendMode, blendAlpha = graphics.getBlendMode()
    Assert.equal(blendMode, "add", "the caller blend mode is restored after composition")
    Assert.equal(blendAlpha, "alphamultiply", "the caller alpha blend mode is restored after composition")
    local depthMode, depthWrite = graphics.getDepthMode()
    Assert.equal(depthMode, "less", "the caller depth mode is restored after composition")
    Assert.equal(depthWrite, true, "the caller depth-write state is restored after composition")
    Assert.isTrue(graphics.isWireframe(), "the caller wireframe state is restored after composition")
    Assert.equal(graphics.getMeshCullMode(), "front", "the caller cull mode is restored after composition")
    local red, green, blue, alpha = graphics.getColor()
    Assert.deepEqual(
      { red, green, blue, alpha },
      { 0.2, 0.3, 0.4, 0.5 },
      "the caller color is restored after composition"
    )
    Assert.deepEqual({ graphics.getScissor() }, { 3, 4, 50, 60 }, "the caller scissor is restored after composition")
    Assert.equal(#graphics.draws, 2, "each hero draw composites one private target")
    Assert.isTrue(graphics.draws[1].image == target, "the private target is composited over the caller")
    Assert.isTrue(graphics.draws[2].image == target, "the private target is reused")
    Assert.equal(#rec.draws, 2, "GX is invoked once per semantic draw")
    renderer:release()
    Assert.equal(target.releaseCount, 1, "release disposes the private target once")
  end)
end

-- Changing only the interpolated framing rebuilds the camera view and
-- the model base height while the projection and the canonical
-- composition path stay untouched: the same pocket, clips, frame, and
-- host placement render through a moved camera over the same projection.
function T.framing_only_change_moves_the_view_and_base_height()
  withDoubles(function()
    local Hero = requireHero()
    local renderer = Hero.new({ assetPreparation = fakePreparationQueue(), cacheFs = stubCache(), manifest = validManifest(), graphics = FakeGraphics({}) })
    local placement = heroPlacement()
    local firstFraming = { angleXDegrees = 328.4, angleYDegrees = 28.3, distance = 339.9, modelY = -45 }
    local secondFraming = { angleXDegrees = 10, angleYDegrees = 350, distance = 200, modelY = 5 }
    renderer:draw("male", heroStatus("items", 0, firstFraming), placement)
    local function copy(matrix)
      local out = {}
      for index = 1, 16 do
        out[index] = matrix[index]
      end
      return out
    end
    local firstView, firstProjection, firstModel =
      copy(renderer._view), copy(renderer._projection), copy(renderer._modelTransform)
    renderer:draw("male", heroStatus("items", 0, secondFraming), placement)
    local function differs(first, second)
      for index = 1, 16 do
        if math.abs(first[index] - second[index]) > 1e-9 then
          return true
        end
      end
      return false
    end
    local function identical(first, second)
      return not differs(first, second)
    end
    Assert.isTrue(differs(firstView, renderer._view), "the reframed camera moves the composed view")
    Assert.isTrue(differs(firstModel, renderer._modelTransform), "the reframed height moves the model transform")
    Assert.isTrue(identical(firstProjection, renderer._projection), "the reframed camera keeps the static projection")
    renderer:draw("male", heroStatus("items", 0, secondFraming), placement)
    Assert.isTrue(identical(firstProjection, renderer._projection), "a repeated framing holds the projection")
    Assert.throws(function()
      renderer:draw(
        "male",
        { pocket = "items", pose = "pocket.items.pose", pattern = "pocket.items.pattern", frame = 0 },
        placement
      )
    end, "a status without framing fails instead of reusing the static camera")
    renderer:release()
  end)
end

function T.scene_edge_colors_come_from_the_generated_records()
  withDoubles(function()
    local Hero = requireHero()
    local manifest = validManifest()
    manifest.schema = "g4-bag-assets-v21"
    manifest.hero.presentation.edgeColors = {
      { r = 10, g = 10, b = 10 },
      { r = 15, g = 9, b = 4 },
      { r = 20, g = 20, b = 20 },
      { r = 0, g = 0, b = 0 },
      { r = 0, g = 0, b = 0 },
      { r = 0, g = 0, b = 0 },
      { r = 0, g = 0, b = 0 },
      { r = 0, g = 0, b = 0 },
    }
    local renderer = Hero.new({ assetPreparation = fakePreparationQueue(), cacheFs = stubCache(), manifest = manifest, graphics = FakeGraphics({}) })
    local edgeColors = assert(renderer._sceneRuntime.edgeColors, "the scene carries its edge table")
    local records = assert(manifest.hero.presentation.edgeColors, "the manifest carries its edge records")
    for index = 0, 7 do
      local record = assert(records[index + 1], "edge record " .. index .. " is generated")
      Assert.equal(
        edgeColors[index],
        record.r + 32 * record.g + 1024 * record.b,
        "edge entry " .. index .. " packs its generated record"
      )
    end
    Assert.isNil(edgeColors[8], "the edge table carries no ninth entry")
    renderer:release()
    local missing = validManifest()
    missing.schema = "g4-bag-assets-v21"
    missing.hero.presentation.edgeColors = nil
    Assert.throws(function()
      Hero.new({ assetPreparation = fakePreparationQueue(), cacheFs = stubCache(), manifest = missing, graphics = FakeGraphics({}) })
    end, "construction without generated edge colors fails instead of rendering unlit edges")
  end)
end

-- The bag's update phase stages the hero through the presentation worker: the
-- first prepared frame reports not-ready while the worker is busy, no model
-- bank decodes and no mesh uploads happen yet, and the model is resident (and
-- drawable) once the worker answers.
function T.staged_preparation_realizes_the_hero_before_the_first_draw()
  withDoubles(function(rec)
    local Hero = requireHero()
    local queue = FakePreparationQueue.new({ pending = true })
    local renderer = Hero.new({
      assetPreparation = queue,
      cacheFs = stubCache(),
      manifest = validManifest(),
      graphics = FakeGraphics({}),
    })
    Assert.isFalse(renderer:prepare("male", 1), "a pending worker keeps the hero unprepared")
    Assert.isFalse(renderer:isReady("male"), "nothing is drawable while the worker is pending")
    Assert.equal(#rec.meshRequests, 0, "the pending stage requests no upload work")
    Assert.equal(#rec.instances, 0, "the pending stage publishes no model instance")

    queue.pending = false
    local ready = false
    for _ = 1, 20 do
      if renderer:prepare("male", 1) then
        ready = true
        break
      end
    end
    Assert.isTrue(ready, "the staged realization completes once the worker answers")
    Assert.isTrue(renderer:isReady("male"), "the realized gender reports drawable")
    Assert.equal(#queue.requests, 1, "one prepared bank request serves the hero model")
    Assert.equal(queue.requests[1].kind, "g4gx", "the hero geometry arrives as a model bank")
    Assert.isTrue(#rec.meshRequests >= 1, "the realized stage uploads the hero mesh")

    renderer:draw("male", heroStatus("items", 0), heroPlacement())
    Assert.equal(#rec.draws, 1, "the staged realization draws its canonical model once")
    renderer:release()
  end)
end

-- Advance a staged hero realization until it suspends on the supplied ticket
-- source, whose request log is empty until the build reaches that stage.
local function advanceToTicket(renderer, requests)
  for _ = 1, 8 do
    if #requests > 0 then
      return
    end
    renderer:prepare("male", 1)
  end
  Assert.isTrue(#requests > 0, "the staged hero reaches its pending ticket")
end

-- One hero material sampling a real texture reference, so a staged
-- realization borrows through the session image owner.
local function texturedManifest()
  local manifest = validManifest()
  manifest.hero.model.male = heroDescriptor("male")
  manifest.hero.model.male.materials = {
    { id = 0, name = "hero", texture = "assets/generated/bag/hero.png", wrap = { x = "clamp", y = "clamp" } },
  }
  return manifest
end

-- One staged hero suspended on a published ticket of `source`, then left
-- through `exitPath`. Both exits own the same obligation: the abandoned build
-- drops the interest it was suspended on exactly once at that ticket's owner,
-- so its packet stops being charged to the session, a late worker reply
-- publishes nothing, and the realized mesh is disposed once.
---@param source string "geometry" (preparation queue) or "image" (shared owner)
---@param exitPath string "release" or "failure"
local function assertPendingTicketDroppedOnExit(source, exitPath)
  withDoubles(function(rec)
    local Hero = requireHero()
    local owner = nil
    local queue
    if source == "image" then
      queue = fakePreparationQueue()
      owner = ControllableImageOwner.new()
    else
      queue = FakePreparationQueue.new({ deferred = true, payloadBytes = 2048 })
    end
    local renderer = Hero.new({
      assetPreparation = queue,
      cacheFs = stubCache(),
      manifest = owner ~= nil and texturedManifest() or validManifest(),
      graphics = FakeGraphics({}),
      imageAssets = owner,
    })
    local tickets = owner ~= nil and owner.requests or queue.requests
    advanceToTicket(renderer, tickets)
    Assert.equal(#tickets, 1, "the staged hero suspends on one " .. source .. " ticket")
    local ticket = tickets[1].token
    local ticketOwner = owner ~= nil and owner or queue
    Assert.isTrue(ticketOwner:publish(ticket), "the worker publishes the pending " .. source)
    Assert.equal(ticketOwner.readyBytes, 2048, "the published payload is charged to the ready budget")

    if exitPath == "release" then
      renderer:release()
      renderer:release()
    else
      if owner ~= nil then
        owner:failNow("injected shared image failure")
      else
        queue:failPoll("preparation queue reply is malformed")
      end
      local ok, err = pcall(renderer.prepare, renderer, "male", 1)
      Assert.isFalse(ok, "a " .. source .. " fault fails the staged realization")
      local cause = owner ~= nil and "injected shared image failure" or "preparation queue reply"
      Assert.isTrue(
        tostring(err):find(cause, 1, true) ~= nil,
        "the " .. source .. " cause propagates instead of a cancellation error"
      )
      renderer:release()
    end

    local label = exitPath .. " on a pending " .. source .. " ticket"
    Assert.equal(#ticketOwner.cancelCalls, 1, label .. " cancels that ticket exactly once")
    Assert.equal(ticketOwner.cancelCalls[1], ticket, label .. " cancels the ticket it was suspended on")
    Assert.equal(ticketOwner.readyBytes, 0, label .. " leaves no payload charged")
    Assert.isFalse(ticketOwner:publish(ticket), label .. " discards a late worker reply")
    if owner ~= nil then
      Assert.equal(owner:outstandingLeases(), 0, label .. " takes no lease for the dropped ticket")
    end
    Assert.isFalse(renderer:isReady("male"), label .. " publishes no resident model")
    Assert.equal(rec.pools[1].releaseCount, 1, label .. " disposes its pool exactly once")
  end)
end

-- The explicit blocking draw entry waits for a cold hero texture by sleeping
-- for the session image owner instead of polling it: the hero realizes once the
-- worker replies, within a bounded number of polls.
function T.blocking_draw_waits_for_a_cold_texture_without_hot_polling()
  withDoubles(function(rec)
    local Hero = requireHero()
    local owner = ControllableImageOwner.new()
    local renderer = Hero.new({
      assetPreparation = fakePreparationQueue(),
      cacheFs = stubCache(),
      manifest = texturedManifest(),
      graphics = FakeGraphics({}),
      imageAssets = owner,
    })
    local probe = SynchronousWaitProbe.new(owner, { publishAfterSleeps = 2 })
    probe:install()
    local ok, failure = pcall(renderer.draw, renderer, "male", heroStatus("items", 0), heroPlacement())
    probe:restore()
    Assert.isTrue(ok, "the blocking hero draw completes: " .. tostring(failure))
    Assert.isTrue(probe.sleeps >= 1, "the blocking wait handed the CPU to the worker instead of polling it")
    Assert.isTrue(renderer:isReady("male"), "the completed draw leaves the hero realized")
    Assert.equal(#rec.draws, 1, "the realized hero draws its canonical model once")
    renderer:release()
    Assert.equal(owner:outstandingLeases(), 0, "releasing the renderer returns every borrowed lease")
  end)
end

-- A staged hero abandoned while its preparation ticket is still owed drops that
-- interest on release, whichever owner the ticket belongs to.
function T.release_drops_the_pending_preparation_and_shared_image_tickets_once()
  assertPendingTicketDroppedOnExit("geometry", "release")
  assertPendingTicketDroppedOnExit("image", "release")
end

-- A staged hero that fails while its preparation ticket is still owed drops
-- that interest without masking the cause, whichever owner the ticket belongs
-- to.
function T.failure_drops_the_pending_preparation_and_shared_image_tickets_once()
  assertPendingTicketDroppedOnExit("geometry", "failure")
  assertPendingTicketDroppedOnExit("image", "failure")
end

-- A native texture bank selection keys a hero material borrow exactly like a
-- PNG path does: the shared owner receives the reference itself, materials
-- sharing one identity and wrap share one borrow, and the blocking draw entry
-- realizes through the same key. Concatenating the reference as if it were a
-- path is the failure this covers.
function T.native_texture_references_borrow_through_the_shared_owner()
  withDoubles(function(rec)
    local Hero = requireHero()
    local sharedTexture = {
      file = "assets/generated/bag/hero-bank.g4tx",
      textureName = "hero",
      paletteName = "hero-pack",
    }
    local manifest = validManifest()
    manifest.hero.model.male = heroDescriptor("male")
    manifest.hero.model.male.materials = {
      { id = 0, name = "hero", texture = sharedTexture, wrap = { x = "clamp", y = "clamp" } },
      { id = 1, name = "hero-again", texture = sharedTexture, wrap = { x = "clamp", y = "clamp" } },
    }
    local requests, acquired, released = {}, {}, {}
    local owner = {
      request = function(_, path, sampler, priority)
        requests[#requests + 1] = { path = path, wrapX = sampler.wrapX, priority = priority }
        return #requests
      end,
      poll = function(_, _)
        return "ready"
      end,
      acquire = function(_, token)
        local lease = { image = { token = token }, palette = nil, kind = "rgba8" }
        acquired[#acquired + 1] = lease
        return lease
      end,
      release = function(_, lease)
        released[#released + 1] = lease
      end,
      cancel = function(_, _) end,
    }
    local renderer = Hero.new({
      assetPreparation = fakePreparationQueue(),
      cacheFs = stubCache(),
      manifest = manifest,
      graphics = FakeGraphics({}),
      imageAssets = owner,
    })
    renderer:draw("male", heroStatus("items", 0), heroPlacement())
    Assert.equal(#requests, 1, "two materials sharing one native texture borrow it once")
    Assert.equal(requests[1].path, sharedTexture, "the shared owner receives the reference itself")
    Assert.equal(requests[1].wrapX, "clamp", "the borrow carries the resolved sampler wrap")
    Assert.equal(#acquired, 1, "one lease backs the shared handle")
    renderer:release()
    Assert.equal(#released, 1, "release returns the one borrowed lease")
  end)
end

return { tests = T }
