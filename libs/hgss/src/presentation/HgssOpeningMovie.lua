-- Five-scene retail opening movie session. Plays the normalized opening
-- scenes in order at the 30 Hz source tick: per-engine layered 2D
-- backgrounds with clip-offset sprite instances, three town model segments,
-- and the nine starter emitter sequences, with the source skip gate and
-- bounded scene GPU ownership.
-- Authority: retail src/intro_movie.c (scene order and skip ownership) and
-- src/intro_movie_scene_1..5.c (per-scene state programs and effect timing).

local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local Contract = require("libs.assets.src.DerivedAssetContract")
local DisplayContext = require("libs.ui.src.DisplayContext")
local Errors = require("libs.errors.src.Errors")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local Matrix4 = require("libs.math.src.Matrix4")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")
local StartupAssetCache = require("libs.assets.src.StartupAssetCache")

---@class HgssOpeningMovie
---@field versionId string
---@field cacheFs table<string, unknown>
---@field graphics table<string, unknown>
---@field displayContext DisplayContext
---@field width number
---@field height number
---@field scenes table[]
---@field generationId string
---@field currentIndex integer
---@field finished boolean
---@field skipEligible boolean
---@field pendingFinish boolean
---@field disposed boolean
---@field current OpeningMovieSlot|nil active scene slot
---@field nextSlot OpeningMovieSlot|nil prefetched scene slot
---@field mainCanvas love.Canvas? fixed main-engine source target (256x192)
---@field subCanvas love.Canvas? fixed sub-engine source target (256x192)
---@field townScratch love.Canvas? fixed town composite scratch (256x192), allocated only when a scene stages towns
local HgssOpeningMovie = {}
HgssOpeningMovie.__index = HgssOpeningMovie

local SOURCE_WIDTH, SOURCE_HEIGHT = 256, 192
-- Ops whose `effect` field starts a waitable effect when the event fires.
-- Started names (plus started emitter groups and compiled sprite clips)
-- are the only identities a later wait may name.
-- Scene-4 starter particles are a closed consumer of the nine compiled
-- emitter records (src/intro_movie_scene_4.c starter sets): emission and
-- particle lifetimes, generation rate, origin, velocity, fields, color,
-- alpha, scale, and texture all come from the manifest. One world unit maps
-- to WORLD_TO_SOURCE_PX source pixels around the 256x192 stage center;
-- world +Y (the emitter axis of all nine records) maps to screen up. The
-- only randomness left is the uniform disc/axis spawn offset and the
-- initial spin within the recorded rotation range -- the retail SPL library
-- draws these from its own RNG stream, so the player draws them from its
-- deterministic per-slot stream seeded by the manifest seed (never
-- math.randomseed, never the global state).
local WORLD_TO_SOURCE_PX = 16
local STAGE_CENTER_X, STAGE_CENTER_Y = 128, 96
local GPU_NEAR, GPU_FAR = 1, 5000
-- Retail town field angle behind the scene-3 camera: the compiled town
-- track carries this fovAngle, and a bundle without one keeps the same
-- retail town lens instead of borrowing the title lens.
local TOWN_HALF_ANGLE_INDEX = 0x981
local TOWN_DEFAULT_DISTANCE = 410.922119140625
local TOWN_DEFAULT_TARGET = { 0, 0, 96 }
local NOON_HALF_SECONDS = 43200

local EFFECT_START_OPS = {
  setBlend = true,
  setScroll = true,
  setFade = true,
  circleWipe = true,
  window = true,
}

---@param reason string
---@param context Errors.Context?
---@return Errors.Error error value
local function invalid(reason, context)
  return Errors.new("HGSS_OPENING_MOVIE_INVALID", "opening movie bundle is invalid: " .. reason, {
    reason = reason,
    context = context,
  })
end

---@param value unknown
---@return boolean
local function isInteger(value)
  return type(value) == "number" and value % 1 == 0 and value ~= math.huge and value ~= -math.huge
end

-- C-style truncation toward zero: negative fractional shares round up,
-- never down to the next whole pixel the way a floor would.
---@param n number
---@return integer
local function truncTowardZero(n)
  return n >= 0 and math.floor(n) or math.ceil(n)
end

---@param color unknown
---@return number r, number g, number b
local function emitterColorChannels(color)
  local source = color --[[@as table<string, unknown>]]
  local r = (type(source) == "table" and (source.r or source[1])) or 1
  local g = (type(source) == "table" and (source.g or source[2])) or 1
  local b = (type(source) == "table" and (source.b or source[3])) or 1
  return r, --[[@as number]]
    g, --[[@as number]]
    b --[[@as number]]
end

---@class OpeningMovieSlot
---@field manifest table<string, unknown>
---@field sceneNumber integer
---@field images table[]
---@field imageByPath table<string, love.Image>
---@field applied table<integer, boolean>
---@field released boolean
---@field sceneTick integer
---@field stepIndex integer
---@field stepElapsed integer
---@field rng integer
---@field scrolls table<string, table<string, unknown>> live per-slot scroll programs by engine and slot
---@field imageExtents table<string, { width: integer, height: integer }> native extents by staged image path
---@field effects table<string, table<string, unknown>> started timed and emitter effects by name
---@field programEffects table<string, boolean> effect identities the program starts on some step
---@field programClips table<string, boolean> clip identities the program assigns on some step
---@field backgrounds table<string, table<integer, table<string, unknown>>> live layers by source engine and slot
---@field spriteInstances table<string, table<string, unknown>> live sprites by instance identity
---@field spriteOrder string[] instance identities in appearance order
---@field clipIds table<string, table<string, unknown>> compiled sprite clips by staged identity
---@field clipStarts table<string, integer> latest assignment tick by compiled clip identity
---@field mainPhysical string physical screen carrying the main engine output
---@field emitters table[] live emitter runtimes with their record-driven particles
---@field emitterRecords table<integer, table<string, unknown>> compiled emitter records by source id
---@field activeTown string?
---@field townClipTicks table<string, integer>
---@field cameraDistance number?
---@field lightingMap number?
---@field fade table<string, unknown>?
---@field wipe table<string, unknown>?
---@field blend table<string, unknown>?
---@field palette table<string, unknown>?
---@field windows table<string, OpeningMovieWindow> live engine-local window state by source engine
---@field townVisible boolean source town stage contributes to main BG0
---@field pool GpuAssetPool?
---@field renderer FieldRenderer?
---@field towns { name: string?, index: integer?, instance: ModelInstance }[]
---@field townEnv table<string, unknown>?
---@field townEnvKey number?

---@class OpeningMovieWindow
---@field enabled boolean whether window clipping constrains the owning engine
---@field win0 table<string, unknown>? running WIN0 pan program with sampled rect
---@field win1 table<string, unknown>? WIN1 rectangle override with its inside mask
---@field win1Source string? "manual" once a direct override supersedes the helper span
---@field outsideMask integer plane mask where neither window covers

---@param manifest table<string, unknown> staged opening scene bundle
---@param sceneNumber integer expected 1..5 position
---@param versionId string
---@param generationId string
local function checkBundleShape(manifest, sceneNumber, versionId, generationId)
  -- Bundle records (art extents, hashes, emitter fields, and the step graph)
  -- are validated once by the generated-asset reader. The player only checks
  -- the bundle identity, edition, generation, and position plus the program
  -- shape its scheduler indexes: steps own their events, and every event and
  -- step carries the clock and completion fields the interpreter reads.
  if type(manifest) ~= "table" then
    error(invalid("opening scene manifest must be a table", { scene = sceneNumber }), 0)
  end
  if manifest.schema ~= Contract.startupOpeningScene.schema then
    error(invalid("opening scene manifest schema does not match", { scene = sceneNumber }), 0)
  end
  if manifest.versionId ~= versionId then
    error(invalid("opening scene manifest edition does not match", { scene = sceneNumber }), 0)
  end
  if type(manifest.generationId) ~= "string" or manifest.generationId == "" then
    error(invalid("opening scene manifest generation is missing", { scene = sceneNumber }), 0)
  end
  if manifest.generationId ~= generationId then
    error(invalid("opening scene manifest generation does not match", { scene = sceneNumber }), 0)
  end
  if manifest.sceneNumber ~= sceneNumber then
    error(invalid("opening scene manifest names another scene", { scene = sceneNumber }), 0)
  end
  if manifest.sourceTickRate ~= Contract.startupOpeningScene.tickRate then
    error(invalid("opening scene manifest runs outside the source frame rate", { scene = sceneNumber }), 0)
  end
  if
    type(manifest.layers) ~= "table"
    or type(manifest.layers.main) ~= "table"
    or type(manifest.layers.sub) ~= "table"
  then
    error(invalid("opening scene keeps its main and sub engine layers", { scene = sceneNumber }), 0)
  end
  if type(manifest.spriteClips) ~= "table" then
    error(invalid("opening scene sprite clips are malformed", { scene = sceneNumber }), 0)
  end
  if type(manifest.models) ~= "table" or type(manifest.particles) ~= "table" then
    error(invalid("opening scene stage state is malformed", { scene = sceneNumber }), 0)
  end
  local timeline = manifest.timeline
  if type(timeline) ~= "table" or type(timeline.steps) ~= "table" or type(timeline.events) ~= "table" then
    error(invalid("opening scene timeline is malformed", { scene = sceneNumber }), 0)
  end
  if #timeline.events == 0 then
    error(invalid("opening scene timeline carries no events", { scene = sceneNumber }), 0)
  end
  for _, event in ipairs(timeline.events) do
    if
      type(event) ~= "table"
      or type(event.op) ~= "string"
      or type(event.stepId) ~= "string"
      or not isInteger(event.atStepTick)
      or event.atStepTick < 0
    then
      error(invalid("opening scene event carries no source step clock", { scene = sceneNumber }), 0)
    end
  end
  for _, step in ipairs(timeline.steps) do
    if type(step) ~= "table" or type(step.id) ~= "string" or type(step.events) ~= "table" or #step.events == 0 then
      error(invalid("opening scene step is malformed", { scene = sceneNumber }), 0)
    end
    local finish = step["until"]
    if type(finish) ~= "table" or (finish.kind ~= "duration" and finish.kind ~= "effect") then
      error(invalid("opening scene step completion is malformed", { scene = sceneNumber }), 0)
    end
    for _, index in ipairs(step.events) do
      local owned = timeline.events[index]
      if not isInteger(index) or owned == nil or owned.stepId ~= step.id then
        error(invalid("opening scene step references no owned event", { scene = sceneNumber }), 0)
      end
    end
  end
end

---@param self HgssOpeningMovie
---@param target love.Canvas? owned target receiving the settle fill
local function settleReleasedHandles(self, target)
  -- The host batches textured draws, so a just-released handle can still
  -- read back as live (holding real memory) until later graphics work
  -- runs. One untextured fill into an owned target settles the queue
  -- without staging another texture; it never hides a genuine leak since
  -- only released handles are affected.
  if target == nil then
    return
  end
  local graphics = self.graphics
  local previous = graphics.getCanvas()
  graphics.push("all")
  -- Settle-only work must never fail construction or teardown: the
  -- pcall exists solely to guarantee the pushed scope is restored.
  pcall(function()
    graphics.setCanvas(target)
    graphics.setColor(0, 0, 0, 0)
    graphics.rectangle("fill", 0, 0, 1, 1)
    graphics.setCanvas(previous)
  end)
  graphics.pop()
end

---@param slot OpeningMovieSlot scene slot to tear down
local function releaseSlot(slot)
  if slot.released then
    return
  end
  slot.released = true
  local images, pool, renderer = slot.images, slot.pool, slot.renderer
  slot.images, slot.imageByPath, slot.pool, slot.renderer, slot.towns = {}, {}, nil, nil, {}
  for _, image in ipairs(images) do
    image:release()
  end
  if pool ~= nil then
    pool:release()
  end
  if renderer ~= nil then
    renderer:release()
  end
end

---@param graphics table<string, unknown> injected love.graphics-compatible namespace
---@param bytes string staged file bytes
---@param path string staged path used as image identity
---@return love.Image image handle
local function newSceneImage(graphics, bytes, path)
  local filesystem = love and love.filesystem
  if filesystem ~= nil and type(filesystem.newFileData) == "function" then
    local ok, data = pcall(filesystem.newFileData, bytes, path)
    if ok then
      local image = graphics.newImage(data)
      if image.setFilter ~= nil then
        image:setFilter("nearest", "nearest")
      end
      return image
    end
  end
  local image = graphics.newImage(bytes)
  if image.setFilter ~= nil then
    image:setFilter("nearest", "nearest")
  end
  return image
end

---@param slot OpeningMovieSlot scene slot collecting its GPU handles
---@param self HgssOpeningMovie
---@param path string staged asset path
---@return love.Image image handle
local function acquireImage(slot, self, path)
  local bytes = self.cacheFs:read(path)
  if type(bytes) ~= "string" then
    error(invalid("opening scene staged art is missing", { scene = slot.sceneNumber, path = path }), 0)
  end
  local image = newSceneImage(self.graphics, bytes, path)
  slot.images[#slot.images + 1] = image
  slot.imageByPath[path] = image
  return image
end

---@param descriptor table<string, unknown> normalized dynamic model descriptor
---@param clips table[] compiled animation channels staged with the scene
---@return table<string, unknown> descriptor copy carrying its animation channels
local function withSceneClips(descriptor, clips)
  local copy = {}
  for key, value in pairs(descriptor) do
    copy[key] = value
  end
  -- The town animation set is named once per town: the descriptor and the
  -- staged clip list carry the same clip identities by design, so the merge
  -- never double-counts one set. One identity can still name two different
  -- channels (the joint transform set and the material scroll set share the
  -- town id): those are distinct channels the renderer plays together, so
  -- the later channel keeps a qualified runtime identity instead of being
  -- dropped or colliding at assembly.
  copy.animations = {}
  local seen = {}
  local function sameChannel(first, clip)
    return first == clip or (first.category == clip.category and first.kind == clip.kind)
  end
  local function stage(clip)
    if type(clip) ~= "table" then
      return
    end
    if clip.id == nil then
      copy.animations[#copy.animations + 1] = clip
      return
    end
    local first = seen[clip.id]
    if first == nil then
      seen[clip.id] = clip
      copy.animations[#copy.animations + 1] = clip
      return
    end
    if sameChannel(first, clip) then
      return
    end
    local qualifiedId = clip.id .. ":" .. tostring(clip.category)
    local previous = seen[qualifiedId]
    if previous ~= nil then
      if sameChannel(previous, clip) then
        return
      end
      return
    end
    local qualified = {}
    for key, value in pairs(clip) do
      qualified[key] = value
    end
    qualified.id = qualifiedId
    seen[qualifiedId] = qualified
    copy.animations[#copy.animations + 1] = qualified
  end
  if type(descriptor.animations) == "table" then
    for _, clip in ipairs(descriptor.animations) do
      stage(clip)
    end
  end
  if type(clips) == "table" then
    for _, clip in ipairs(clips) do
      stage(clip)
    end
  end
  return copy
end

-- Builds one town model instance through the shared model renderer path:
-- the normalized descriptor becomes a definition, every staged material
-- texture is read eagerly in manifest order, geometry resolves through the
-- scene-local GPU pool, and the instance plays the staged animation
-- channels its compiled definition actually binds. A town without a
-- bindable animation clip is malformed town data and fails here.
---@param self HgssOpeningMovie
---@param slot OpeningMovieSlot scene slot gaining the town stage
---@param model table<string, unknown> compiled town model record
---@param position integer 1-based town position in manifest order
local function buildTownModel(self, slot, model, position)
  local town = (type(model) == "table" and model.name) or ("town-" .. tostring(position))
  if type(model) ~= "table" or type(model.descriptor) ~= "table" or type(model.descriptor.dynamic) ~= "table" then
    error(
      invalid("opening scene town descriptor carries no stage geometry", {
        scene = slot.sceneNumber,
        town = town,
      }),
      0
    )
  end
  local merged = withSceneClips(model.descriptor, model.clips)
  for _, clip in ipairs(merged.animations) do
    if type(clip) ~= "table" or (clip.id == nil and clip.name == nil) then
      error(
        invalid("opening scene town carries no bindable animation clip", {
          scene = slot.sceneNumber,
          town = town,
        }),
        0
      )
    end
  end
  local key = "opening-scene:" .. slot.sceneNumber .. ":" .. tostring(town)
  local definition = ModelDefinition.fromNitroDescriptor(merged, { key = key })
  -- Every staged material texture is read eagerly in manifest order, so a
  -- missing town texture fails the acquisition instead of surfacing later
  -- (or never) through lazy draw-time resolution.
  for _, material in ipairs(definition.materials) do
    if material.texture ~= nil and slot.imageByPath[material.texture] == nil then
      acquireImage(slot, self, material.texture)
    end
  end
  local wraps = SceneDescriptor.wrapByMaterial(definition.materials)
  local function resolveImage(path, materialId)
    if path == nil then
      return nil
    end
    local handle = slot.imageByPath[path]
    if handle == nil then
      handle = acquireImage(slot, self, path)
    end
    local wrap = wraps[materialId]
    if wrap ~= nil and handle.setWrap ~= nil then
      handle:setWrap(wrap.x, wrap.y)
    end
    return handle
  end
  local instance = ModelInstance.new(definition, {
    resolveImage = resolveImage,
  })
  local played = 0
  for _, clip in ipairs(definition.animations) do
    local name = type(clip) == "table" and (clip.id or clip.name)
    if name ~= nil then
      local clipOk = pcall(instance.play, instance, name, { loopMode = "loop" })
      if clipOk then
        played = played + 1
      end
    end
  end
  if played == 0 then
    error(
      invalid("opening scene town carries no bindable animation clip", {
        scene = slot.sceneNumber,
        town = town,
      }),
      0
    )
  end
  local meshes = {}
  for _, mesh in ipairs(definition.meshes) do
    local resource = slot.pool:meshFor(mesh.geometry)
    mesh.center = resource.center
    meshes[mesh.id] = resource.mesh
  end
  instance.renderMeshesById = meshes
  instance:evaluatePose()
  slot.towns[#slot.towns + 1] = { name = model.name, index = model.index, instance = instance }
end

-- Builds the town model instances through the shared model renderer path:
-- normalized descriptors become definitions, geometry resolves through a
-- scene-local GPU pool, and each instance plays the staged animation
-- channels its compiled definition actually binds. Any failure aborts the
-- whole stage with a typed scene error so the slot acquisition rolls back
-- instead of drawing a partial town.
---@param self HgssOpeningMovie
---@param slot OpeningMovieSlot scene slot gaining the town stage
local function buildTownStage(self, slot)
  local pool = GpuAssetPool.new(self.cacheFs, { graphics = self.graphics })
  slot.pool = pool
  local renderer = FieldRenderer.new({ clearColor = { 0, 0, 0, 0 }, graphics = self.graphics })
  slot.renderer = renderer
  for index, model in ipairs(slot.manifest.models) do
    local ok, failure = pcall(buildTownModel, self, slot, model, index)
    if not ok then
      if type(failure) == "table" and failure.code == "HGSS_OPENING_MOVIE_INVALID" then
        error(failure, 0)
      end
      error(
        invalid("opening scene town stage cannot be acquired", {
          scene = slot.sceneNumber,
          town = type(model) == "table" and model.name or nil,
          cause = Errors.format(failure),
        }),
        0
      )
    end
  end
end

---@param self HgssOpeningMovie
---@param manifest table<string, unknown> validated scene bundle
---@return OpeningMovieSlot slot acquired scene slot
local function acquireSlot(self, manifest)
  ---@type OpeningMovieSlot
  local slot = {
    manifest = manifest,
    sceneNumber = manifest.sceneNumber,
    images = {},
    imageByPath = {},
    applied = {},
    released = false,
    sceneTick = 0,
    stepIndex = 1,
    stepElapsed = 0,
    rng = (manifest.particles.seed or 0) * 131 + manifest.sceneNumber * 7919 + 17,
    scrolls = {},
    effects = {},
    programEffects = {},
    programClips = {},
    backgrounds = { main = {}, sub = {} },
    imageExtents = {},
    spriteInstances = {},
    spriteOrder = {},
    clipIds = {},
    clipStarts = {},
    mainPhysical = "upper",
    emitters = {},
    emitterRecords = {},
    activeTown = nil,
    townClipTicks = {},
    cameraDistance = nil,
    lightingMap = nil,
    fade = nil,
    wipe = nil,
    blend = nil,
    palette = nil,
    windows = {
      main = { enabled = false, win0 = nil, win1 = nil, win1Source = nil, outsideMask = 0 },
      sub = { enabled = false, win0 = nil, win1 = nil, win1Source = nil, outsideMask = 0 },
    },
    townVisible = false,
    pool = nil,
    renderer = nil,
    towns = {},
  }
  local ok, failure = pcall(function()
    for _, engine in ipairs({ "main", "sub" }) do
      for _, layer in ipairs(manifest.layers[engine]) do
        if slot.imageByPath[layer.image] == nil then
          acquireImage(slot, self, layer.image)
        end
        slot.imageExtents[layer.image] = { width = layer.width, height = layer.height }
        if type(layer.variants) == "table" then
          for _, alternate in ipairs(layer.variants) do
            if slot.imageByPath[alternate.image] == nil then
              acquireImage(slot, self, alternate.image)
            end
            slot.imageExtents[alternate.image] = { width = alternate.width, height = alternate.height }
          end
        end
        -- Every compiled slot starts with its authored enable state,
        -- source priority, and native image extents; later setLayer events
        -- replace the copied image, visibility, priority, and extents per
        -- slot. Slots the program never touches keep their staged
        -- visibility, hidden or shown.
        slot.backgrounds[engine][layer.bgSlot] = {
          bgSlot = layer.bgSlot,
          image = layer.image,
          priority = layer.priority,
          visible = layer.initialVisible,
          width = layer.width,
          height = layer.height,
          scrollX = 0,
          scrollY = 0,
        }
      end
    end
    for _, clip in ipairs(manifest.spriteClips) do
      slot.clipIds[clip.id] = clip
      if slot.imageByPath[clip.id] == nil then
        acquireImage(slot, self, clip.id)
      end
    end
    -- Waits bind against the whole program, not just the current step:
    -- an effect or clip the program starts in a later step advances the
    -- waiting step by zero and orders through the wait, while a name the
    -- program never starts is invalid. Record every program-bound identity
    -- so step completion can tell the two apart without guessing.
    for _, event in ipairs(manifest.timeline.events) do
      if EFFECT_START_OPS[event.op] == true and type(event.effect) == "string" then
        slot.programEffects[event.effect] = true
      elseif event.op == "startEmitters" and type(event.group) == "string" then
        slot.programEffects["emitters-" .. event.group] = true
      elseif event.op == "setSpriteClip" and type(event.clipId) == "string" then
        slot.programClips[event.clipId] = true
      end
    end
    -- Stage each compiled particle texture once per scene acquisition: the
    -- images join the slot graph, so they release with the scene and the
    -- current/next two-scene bound covers them with no extra accounting.
    local particles = manifest.particles
    if type(particles) == "table" and type(particles.textures) == "table" then
      for _, texture in ipairs(particles.textures) do
        if slot.imageByPath[texture.image] == nil then
          acquireImage(slot, self, texture.image)
        end
      end
    end
    slot.emitterRecords = {}
    if type(particles) == "table" and type(particles.emitters) == "table" then
      for _, emitter in ipairs(particles.emitters) do
        if slot.imageByPath[emitter.textureImage] == nil then
          error(
            invalid("opening scene emitter names unstaged particle art", {
              scene = slot.sceneNumber,
              emitter = emitter.id,
            }),
            0
          )
        end
        slot.emitterRecords[emitter.id] = emitter
      end
    end
    if #manifest.models > 0 then
      -- The town stage is strict: any failed town model, clip, texture, or
      -- mesh acquisition aborts the whole scene with a typed scene error.
      -- A failed acquisition never becomes a drawable scene.
      buildTownStage(self, slot)
    end
  end)
  if not ok then
    releaseSlot(slot)
    if type(failure) == "table" and type(failure.code) == "string" then
      error(failure, 0)
    end
    error(
      invalid("opening scene acquisition failed", {
        scene = manifest.sceneNumber,
        cause = Errors.format(failure),
      }),
      0
    )
  end
  return slot
end

---@param slot OpeningMovieSlot scene slot owning the deterministic particle seed
---@return integer next local random value
local function rngNext(slot)
  slot.rng = (slot.rng * 1103515245 + 12345) % 2147483648
  return slot.rng
end

---@param slot OpeningMovieSlot scene slot
---@param name string|nil timed effect name
---@param ticks integer|nil source tick count; nil completes immediately
local function startTimedEffect(slot, name, ticks)
  if name == nil then
    return
  end
  if ticks == nil then
    slot.effects[name] = { started = true, done = true }
    return
  end
  slot.effects[name] = { started = true, done = false, remaining = ticks, total = ticks }
end

---@param slot OpeningMovieSlot scene slot
---@param clipId string staged sprite clip identity
---@return integer summed frame durations bounding the clip wait
local function clipTotalTicks(slot, clipId)
  local clip = slot.clipIds[clipId]
  assert(clip ~= nil, "opening scene clip wait names a compiled clip")
  local total = 0
  for _, frame in ipairs(clip.frames) do
    total = total + (frame.duration or 1)
  end
  return math.max(total, 1)
end

---@param slot OpeningMovieSlot scene slot
---@param name string compiled clip identity ending its wait
---@return boolean true once the clip has played its summed frame durations
local function clipWaitDone(slot, name)
  local start = slot.clipStarts[name]
  if start == nil then
    error(
      invalid("opening scene waits on a clip that never started", {
        scene = slot.sceneNumber,
        effect = name,
      }),
      0
    )
  end
  return (slot.sceneTick - start) >= clipTotalTicks(slot, name)
end

---@param slot OpeningMovieSlot scene slot
---@param group string starter group behind an emitter effect
---@return boolean true once every particle of the group has expired
local function emittersDone(slot, group)
  local effect = slot.effects["emitters-" .. group]
  if effect == nil then
    error(invalid("opening scene waits on emitters that never started", { group = group }), 0)
  end
  return effect.done
end

---@param slot OpeningMovieSlot scene slot
---@param group string starter group to ignite
---@param ids integer[] source emitter ids of the group
local function startEmitters(slot, group, ids)
  local effect = slot.effects["emitters-" .. group]
  if effect == nil then
    effect = { started = true, done = false }
    slot.effects["emitters-" .. group] = effect
  else
    effect.started = true
    if effect.done then
      effect.done = false
    end
  end
  for _, id in ipairs(ids) do
    local record = slot.emitterRecords[id]
    if record == nil then
      error(invalid("opening scene emitter start names no compiled emitter", { emitter = id }), 0)
    end
    if record.group ~= group then
      error(invalid("opening scene emitter start leaves its source group", { emitter = id, group = group }), 0)
    end
    slot.emitters[#slot.emitters + 1] = {
      id = id,
      group = group,
      record = record,
      age = 0,
      credit = 0,
      particles = {},
    }
  end
end

---@param record table<string, unknown> compiled starter emitter record
---@return number originX, number originY source-pixel emission origin
local function emitterOrigin(record)
  local position = record.position --[[@as { x: number, y: number, z: number }]]
  return STAGE_CENTER_X + position.x * WORLD_TO_SOURCE_PX, STAGE_CENTER_Y - position.y * WORLD_TO_SOURCE_PX
end

---@param record table<string, unknown> compiled starter emitter record
---@return number axisX, number axisY normalized screen-space emission axis
local function emitterScreenAxis(record)
  local axis = record.axis --[[@as { x: number, y: number, z: number }]]
  local length = math.sqrt(axis.x * axis.x + axis.y * axis.y)
  if length <= 0 then
    return 0, -1
  end
  return axis.x / length, -axis.y / length
end

---@param record table<string, unknown> compiled starter emitter record
---@return number spinRate radians added to each particle per source tick
local function emitterSpinRate(record)
  local fields = record.fields --[[@as table<string, unknown>[] ]]
  for _, field in ipairs(fields) do
    local entry = field --[[@as table<string, unknown>]]
    if entry.kind == "spin" then
      return entry.rotation --[[@as number]] / 65536 * 2 * math.pi
    end
  end
  return 0
end

---@param slot OpeningMovieSlot scene slot
---@param runtime table<string, unknown> live emitter runtime gaining one particle
local function spawnParticle(slot, runtime)
  local record = runtime.record --[[@as table<string, unknown>]]
  local radius = record.radius --[[@as number]]
  local length = record.length --[[@as number]]
  local originX, originY = emitterOrigin(record)
  local axisX, axisY = emitterScreenAxis(record)
  local angle = (rngNext(slot) % 3600) / 3600 * 2 * math.pi
  local radial = (rngNext(slot) % 1000) / 1000
  local along = ((rngNext(slot) % 1000) / 1000 - 0.5) * length * WORLD_TO_SOURCE_PX
  local spread = radius * WORLD_TO_SOURCE_PX * radial
  local velocity = record.velocity --[[@as { initial: number, axis: number }]]
  local speed = velocity.initial * WORLD_TO_SOURCE_PX
  local drift = velocity.axis * WORLD_TO_SOURCE_PX
  local rotation = record.rotation --[[@as { min: number, max: number }]]
  local spin = 0
  if rotation.max ~= rotation.min then
    local span = math.floor(rotation.max - rotation.min + 1)
    spin = rotation.min + (rngNext(slot) % span)
  else
    spin = rotation.min
  end
  local life = record.particleLife --[[@as integer]]
  runtime.particles[#runtime.particles + 1] = {
    x = originX + math.cos(angle) * spread + axisX * along,
    y = originY + math.sin(angle) * spread + axisY * along,
    vx = axisX * speed - axisY * drift,
    vy = axisY * speed + axisX * drift,
    life = life,
    maxLife = life,
    rot = spin / 65536 * 2 * math.pi + emitterSpinRate(record),
  }
end

---@param record table<string, unknown> compiled starter emitter record
---@param particle table<string, unknown> live particle gaining field acceleration
---@param originX number source-pixel emitter origin
---@param originY number source-pixel emitter origin
local function applyEmitterFields(record, particle, originX, originY)
  local fields = record.fields --[[@as table<string, unknown>[] ]]
  for _, field in ipairs(fields) do
    local entry = field --[[@as table<string, unknown>]]
    if entry.kind == "gravity" then
      local magnitude = entry.magnitude --[[@as { x: number, y: number, z: number }]]
      particle.vx = particle.vx --[[@as number]] + magnitude.x * WORLD_TO_SOURCE_PX
      particle.vy = particle.vy --[[@as number]] - magnitude.y * WORLD_TO_SOURCE_PX
    elseif entry.kind == "magnet" then
      local target = entry.position --[[@as { x: number, y: number, z: number }]]
      local dx = originX + target.x * WORLD_TO_SOURCE_PX - particle.x --[[@as number]]
      local dy = originY - target.y * WORLD_TO_SOURCE_PX - particle.y --[[@as number]]
      local distance = math.sqrt(dx * dx + dy * dy)
      if distance > 1e-6 then
        local pull = entry.magnitude --[[@as number]] * WORLD_TO_SOURCE_PX
        particle.vx = particle.vx --[[@as number]] + dx / distance * pull
        particle.vy = particle.vy --[[@as number]] + dy / distance * pull
      end
    end
    -- Spin advances the rendered rotation (see spawnParticle); it carries
    -- no trajectory term in the observed records.
  end
end

---@param slot OpeningMovieSlot scene slot
---@param group string starter group to advance one source tick
local function advanceEmitters(slot, group)
  for _, runtime in ipairs(slot.emitters) do
    if runtime.group == group then
      local record = runtime.record --[[@as table<string, unknown>]]
      runtime.age = runtime.age --[[@as integer]] + 1
      local emitterLife = record.emitterLife --[[@as integer]]
      if runtime.age <= emitterLife then
        local generation = record.generation --[[@as { count: number, interval: integer }]]
        runtime.credit = runtime.credit --[[@as number]] + generation.count / generation.interval
        local due = math.floor(runtime.credit --[[@as number]])
        runtime.credit = runtime.credit --[[@as number]] - due
        for _ = 1, due do
          spawnParticle(slot, runtime)
        end
      end
      local originX, originY = emitterOrigin(record)
      local spin = emitterSpinRate(record)
      local live = {}
      for _, particle in ipairs(runtime.particles) do
        local entry = particle --[[@as table<string, unknown>]]
        applyEmitterFields(record, entry, originX, originY)
        entry.x = entry.x --[[@as number]] + entry.vx --[[@as number]]
        entry.y = entry.y --[[@as number]] + entry.vy --[[@as number]]
        entry.rot = entry.rot --[[@as number]] + spin
        entry.life = entry.life --[[@as integer]] - 1
        if
          entry.life --[[@as integer]]
          > 0
        then
          live[#live + 1] = entry
        end
      end
      runtime.particles = live
    end
  end
  for name, effect in pairs(slot.effects) do
    local effectGroup = name:match("^emitters%-(.+)$")
    if effectGroup ~= nil and not effect.done then
      local live = false
      for _, runtime in ipairs(slot.emitters) do
        if runtime.group == effectGroup then
          local record = runtime.record --[[@as table<string, unknown>]]
          if
            runtime.age --[[@as integer]]
              <= record.emitterLife --[[@as integer]]
            or #runtime.particles > 0
          then
            live = true
            break
          end
        end
      end
      if not live then
        effect.done = true
      end
    end
  end
end

---@param slot OpeningMovieSlot scene slot
---@param engine unknown source engine naming the window owner
---@return OpeningMovieWindow target engine window state
local function windowState(slot, engine)
  local state = slot.windows[engine]
  if state == nil then
    error(
      invalid("opening scene window names no source engine", {
        scene = slot.sceneNumber,
        engine = engine,
      }),
      0
    )
  end
  return state
end

---@param rect table<string, integer> source pixel rectangle
---@return table<string, integer> private copy the program may sample into
local function copyWindowRect(rect)
  return { x1 = rect.x1, y1 = rect.y1, x2 = rect.x2, y2 = rect.y2 }
end

-- Samples one rectangle edge the way the source pan task does: C integer
-- division truncates toward zero, so a negative edge must round up, never
-- down to the next whole pixel the way a floor would.
---@param origin integer pan start edge
---@param target integer pan end edge
---@param elapsed integer source frames since the pan started
---@param duration integer authored pan length in source frames
---@return integer sampled edge
local function sampleWindowEdge(origin, target, elapsed, duration)
  local drift = target - origin
  if drift == 0 then
    return origin
  end
  local quotient = drift * elapsed / duration
  if quotient >= 0 then
    return origin + math.floor(quotient)
  end
  return origin + math.ceil(quotient)
end

---@param slot OpeningMovieSlot scene slot
---@param event table<string, unknown> authored window program event
local function startWindowProgram(slot, event)
  local state = windowState(slot, event.engine)
  -- A new assignment supersedes the running pan on the same engine: the
  -- superseded wait completes at once instead of hanging the step graph
  -- after the new rectangles take over.
  local running = state.win0
  if running ~= nil and running.effect ~= nil then
    local effect = slot.effects[running.effect]
    if effect ~= nil then
      effect.done = true
    end
  end
  local program = {
    from = copyWindowRect(event.from),
    to = copyWindowRect(event.to),
    ticks = event.ticks,
    elapsed = 0,
    rect = copyWindowRect(event.from),
    insideMask = event.insideMask,
    effect = event.effect,
  }
  if event.ticks == 0 then
    program.rect = copyWindowRect(event.to)
    if event.effect ~= nil then
      slot.effects[event.effect] = { started = true, done = true }
    end
  elseif event.effect ~= nil then
    -- Completion is driven by the owning engine program in the continuous
    -- step below, never by toggling display visibility, so only the engine
    -- that runs the pan can retire its wait.
    slot.effects[event.effect] = { started = true, done = false }
  end
  state.win0 = program
  state.outsideMask = event.outsideMask
  state.enabled = true
end

---@param self HgssOpeningMovie
---@param slot OpeningMovieSlot scene slot
---@param event table<string, unknown> authored timeline event
local function applyEvent(self, slot, event)
  local op = event.op
  if op == "setLayer" then
    local engineLayers = slot.backgrounds[event.engine]
    local background = engineLayers ~= nil and engineLayers[event.bgSlot] or nil
    if background == nil then
      error(
        invalid("opening scene layer names no compiled background slot", {
          scene = slot.sceneNumber,
          engine = event.engine,
          bgSlot = event.bgSlot,
        }),
        0
      )
    end
    background.image = event.image
    background.visible = event.visible
    background.priority = event.priority
    -- The sampled image and its native dimensions change atomically:
    -- later viewport math follows the newly selected art, never extents
    -- inherited from the previous image.
    local extents = slot.imageExtents ~= nil and slot.imageExtents[event.image] or nil
    if extents == nil then
      error(
        invalid("opening scene layer points outside its compiled slot images", {
          scene = slot.sceneNumber,
          engine = event.engine,
          bgSlot = event.bgSlot,
        }),
        0
      )
    end
    background.width = extents.width
    background.height = extents.height
  elseif op == "setPalette" then
    slot.palette = event
  elseif op == "setScroll" then
    -- A slot scroll pans one compiled background by an absolute source
    -- displacement, never a per-tick speed. A target scroll names a
    -- sprite group instead of a slot; no current program emits one, so only
    -- its named effect starts while no displacement is recorded.
    if event.engine ~= nil then
      local engineLayers = slot.backgrounds[event.engine]
      local background = engineLayers ~= nil and engineLayers[event.bgSlot] or nil
      if background == nil then
        error(
          invalid("opening scene scroll names no compiled background slot", {
            scene = slot.sceneNumber,
            engine = event.engine,
            bgSlot = event.bgSlot,
          }),
          0
        )
      end
      -- Zero-duration displacements land at once, negative durations drift
      -- every source tick, and positive durations interpolate from the
      -- staged origin. A later start on the same engine slot replaces the
      -- running program; immediate starts schedule no effect wait.
      local key = event.engine .. ":" .. event.bgSlot
      if event.ticks == 0 then
        background.scrollX = background.scrollX + event.dx
        background.scrollY = background.scrollY + event.dy
        slot.scrolls[key] = nil
      elseif event.ticks == -1 then
        slot.scrolls[key] = {
          ticks = -1,
          dx = event.dx,
          dy = event.dy,
          background = background,
        }
      else
        slot.scrolls[key] = {
          ticks = event.ticks,
          elapsed = 0,
          originX = background.scrollX,
          originY = background.scrollY,
          dx = event.dx,
          dy = event.dy,
          background = background,
        }
        startTimedEffect(slot, event.effect, event.ticks)
      end
    else
      startTimedEffect(slot, event.effect, event.ticks)
    end
  elseif op == "setBlend" then
    slot.blend = { effect = event.effect, from = event.from, to = event.to, ticks = event.ticks, elapsed = 0 }
    startTimedEffect(slot, event.effect, event.ticks)
  elseif op == "window" then
    startWindowProgram(slot, event)
  elseif op == "setWindowSecondary" then
    -- A direct second-register override replaces only the second rectangle
    -- and its mask on the same engine; the running WIN0 program and the
    -- outside mask stay exactly as the source left them.
    local state = windowState(slot, event.engine)
    state.win1 = { rect = copyWindowRect(event.rect), insideMask = event.insideMask }
    state.win1Source = "manual"
  elseif op == "setWindowVisible" then
    -- Display visibility only gates clipping; stored rectangles, masks, and
    -- running waits survive the toggle either way.
    windowState(slot, event.engine).enabled = event.visible
  elseif op == "setModelVisible" then
    -- The town meshes and renderer stay staged until the slot retires;
    -- only the draw contribution stops here.
    slot.townVisible = event.visible
  elseif op == "circleWipe" then
    slot.wipe = { mode = event.mode, ticks = event.ticks or 18, elapsed = 0 }
    startTimedEffect(slot, event.effect, event.ticks)
  elseif op == "setSpriteClip" then
    local instance = slot.spriteInstances[event.instanceId]
    if instance == nil then
      instance = { tick = 0, visible = false, quads = {} }
      slot.spriteInstances[event.instanceId] = instance
      slot.spriteOrder[#slot.spriteOrder + 1] = event.instanceId
    end
    instance.engine = event.engine
    instance.x = event.x
    instance.y = event.y
    instance.drawOrder = event.drawOrder
    instance.clipId = event.clipId
    instance.tick = 0
    instance.quads = {}
    slot.clipStarts[event.clipId] = slot.sceneTick
  elseif op == "spriteVisible" then
    local instance = slot.spriteInstances[event.instanceId]
    if instance == nil then
      instance = { tick = 0, visible = event.visible, quads = {} }
      slot.spriteInstances[event.instanceId] = instance
      slot.spriteOrder[#slot.spriteOrder + 1] = event.instanceId
    end
    instance.engine = event.engine
    instance.x = event.x
    instance.y = event.y
    instance.drawOrder = event.drawOrder
    instance.visible = event.visible
  elseif op == "setModelClip" then
    slot.activeTown = event.model
    slot.townClipTicks[event.model] = 0
    slot.townVisible = true
  elseif op == "setCamera" then
    slot.cameraDistance = event.distance
  elseif op == "setLighting" then
    slot.lightingMap = event.map
  elseif op == "startEmitters" then
    startEmitters(slot, event.group, event.emitters)
  elseif op == "setScreenMapping" then
    slot.mainPhysical = event.mainPhysical
  elseif op == "setFade" then
    slot.fade = { kind = event.kind, ticks = event.ticks, elapsed = 0 }
    startTimedEffect(slot, event.effect, event.ticks)
  elseif op == "waitTicks" then
    -- Duration steps own the wait; the event only marks the authored beat.
  elseif op == "waitEffects" then
    -- A wait names a started effect, a compiled clip, or an effect the
    -- program starts on a later step; anything else never started.
    for _, name in ipairs(event.effects) do
      local group = name:match("^emitters%-(.+)$")
      if group ~= nil then
        if slot.effects[name] == nil and slot.programEffects[name] ~= true then
          error(invalid("opening scene waits on emitters that never started", { effect = name }), 0)
        end
      elseif slot.effects[name] == nil and slot.clipIds[name] == nil and slot.programEffects[name] ~= true then
        error(
          invalid("opening scene effect wait names no started effect", {
            scene = slot.sceneNumber,
            effect = name,
          }),
          0
        )
      end
    end
  elseif op == "enableSkip" then
    if slot.sceneNumber ~= 1 then
      error(invalid("only opening scene 1 opens the movie skip gate", { scene = slot.sceneNumber }), 0)
    end
    self.skipEligible = true
  elseif op == "finish" then
    self.pendingFinish = true
  else
    error(invalid("opening scene event is outside the closed movie grammar", { op = op }), 0)
  end
end

---@param self HgssOpeningMovie
---@param slot OpeningMovieSlot scene slot
local function applyDueEvents(self, slot)
  local steps = slot.manifest.timeline.steps
  local events = slot.manifest.timeline.events
  local step = steps[slot.stepIndex]
  if step == nil then
    return
  end
  for _, index in ipairs(step.events) do
    if not slot.applied[index] and events[index].atStepTick <= slot.stepElapsed then
      slot.applied[index] = true
      applyEvent(self, slot, events[index])
    end
  end
end

---@param slot OpeningMovieSlot scene slot
---@param engine string source engine owning the sampled program
local function advanceWindowProgram(slot, engine)
  local state = slot.windows[engine]
  local program = state.win0
  if program == nil or program.ticks == 0 or program.elapsed >= program.ticks then
    return
  end
  -- Absolute resampling from the staged endpoints: no incremental drift,
  -- and the final tick lands exactly on the authored target rectangle.
  program.elapsed = program.elapsed + 1
  if program.elapsed >= program.ticks then
    program.rect = copyWindowRect(program.to)
    if program.effect ~= nil then
      local effect = slot.effects[program.effect]
      if effect ~= nil then
        effect.done = true
      end
    end
    return
  end
  program.rect = {
    x1 = sampleWindowEdge(program.from.x1, program.to.x1, program.elapsed, program.ticks),
    y1 = sampleWindowEdge(program.from.y1, program.to.y1, program.elapsed, program.ticks),
    x2 = sampleWindowEdge(program.from.x2, program.to.x2, program.elapsed, program.ticks),
    y2 = sampleWindowEdge(program.from.y2, program.to.y2, program.elapsed, program.ticks),
  }
end

---@param slot OpeningMovieSlot scene slot
local function advanceContinuous(slot)
  -- Absolute resampling from the staged origin: no incremental drift,
  -- and the final tick lands exactly on the full displacement while
  -- later ticks retain it. Only fixed source ticks mutate offsets.
  for _, scroll in pairs(slot.scrolls) do
    if scroll.ticks == -1 then
      scroll.background.scrollX = scroll.background.scrollX + scroll.dx
      scroll.background.scrollY = scroll.background.scrollY + scroll.dy
    elseif scroll.ticks > 0 and scroll.elapsed < scroll.ticks then
      scroll.elapsed = scroll.elapsed + 1
      scroll.background.scrollX = scroll.originX + truncTowardZero(scroll.dx * scroll.elapsed / scroll.ticks)
      scroll.background.scrollY = scroll.originY + truncTowardZero(scroll.dy * scroll.elapsed / scroll.ticks)
    end
  end
  for _, effect in pairs(slot.effects) do
    if not effect.done and effect.remaining ~= nil then
      effect.remaining = effect.remaining - 1
      if effect.remaining <= 0 then
        effect.done = true
      end
    end
  end
  if slot.blend ~= nil and slot.blend.elapsed < slot.blend.ticks then
    slot.blend.elapsed = slot.blend.elapsed + 1
  end
  if slot.fade ~= nil and slot.fade.elapsed < slot.fade.ticks then
    slot.fade.elapsed = slot.fade.elapsed + 1
  end
  if slot.wipe ~= nil then
    -- A finished iris retires instead of covering later art: the source
    -- wipe task destroys itself and restores the display on finish, so a
    -- completed cover must reveal what the program stages underneath it.
    if slot.wipe.elapsed < slot.wipe.ticks then
      slot.wipe.elapsed = slot.wipe.elapsed + 1
    else
      slot.wipe = nil
    end
  end
  -- Each engine program advances on the source tick alone; host draws,
  -- resizes, and physical screen flips never resample it.
  advanceWindowProgram(slot, "main")
  advanceWindowProgram(slot, "sub")
  for _, sprite in pairs(slot.spriteInstances) do
    sprite.tick = sprite.tick + 1
  end
  for name in pairs(slot.townClipTicks) do
    slot.townClipTicks[name] = slot.townClipTicks[name] + 1
  end
  for name in pairs(slot.effects) do
    local group = name:match("^emitters%-(.+)$")
    if group ~= nil then
      advanceEmitters(slot, group)
    end
  end
  for _, town in ipairs(slot.towns) do
    town.instance:updateFixed()
    town.instance:evaluatePose()
  end
end

---@param slot OpeningMovieSlot scene slot
---@return number longest authored tick count inside the step
local function stepOwnTicks(slot)
  local steps = slot.manifest.timeline.steps
  local events = slot.manifest.timeline.events
  local step = steps[slot.stepIndex]
  if step == nil then
    return 0
  end
  local longest = 0
  for _, index in ipairs(step.events) do
    local ticks = events[index].ticks
    if type(ticks) == "number" and ticks > longest then
      longest = ticks
    end
  end
  return longest
end

---@param slot OpeningMovieSlot scene slot
---@param step table<string, unknown> active step
---@param name string awaited effect, emitter group, or compiled clip identity
---@return boolean true when the step still means to start the waitable
local function stepStartsEffectLater(slot, step, name)
  local events = slot.manifest.timeline.events
  for _, index in ipairs(step.events) do
    if not slot.applied[index] then
      local event = events[index]
      if event ~= nil then
        if EFFECT_START_OPS[event.op] == true and event.effect == name then
          return true
        end
        if event.op == "startEmitters" and "emitters-" .. tostring(event.group) == name then
          return true
        end
        if event.op == "setSpriteClip" and slot.clipIds[name] ~= nil and event.clipId == name then
          return true
        end
      end
    end
  end
  return false
end

---@param slot OpeningMovieSlot scene slot
---@return boolean true when the active step has run its source course
local function stepComplete(slot)
  local steps = slot.manifest.timeline.steps
  local step = steps[slot.stepIndex]
  if step == nil then
    return true
  end
  local finish = step["until"]
  if finish.kind == "duration" then
    return slot.stepElapsed >= finish.ticks
  end
  -- A wait bound to a start the current step still means to fire stays
  -- open; a wait bound to a start living on a later step advances by zero
  -- so that later step can start it; a name the program never binds is
  -- invalid and never counts as complete.
  local name = finish.effect
  local group = name:match("^emitters%-(.+)$")
  if group ~= nil then
    if slot.effects[name] ~= nil then
      return emittersDone(slot, group)
    end
    if stepStartsEffectLater(slot, step, name) then
      return false
    end
    if slot.programEffects[name] == true then
      return true
    end
    error(
      invalid("opening scene waits on emitters that never started", {
        scene = slot.sceneNumber,
        step = step.id,
        group = group,
      }),
      0
    )
  end
  if slot.effects[name] ~= nil then
    return slot.stepElapsed >= stepOwnTicks(slot) and slot.effects[name].done
  end
  if slot.clipIds[name] ~= nil then
    if slot.clipStarts[name] == nil then
      if stepStartsEffectLater(slot, step, name) then
        return false
      end
      if slot.programClips[name] ~= true then
        error(
          invalid("opening scene waits on a clip that never started", {
            scene = slot.sceneNumber,
            step = step.id,
            effect = name,
          }),
          0
        )
      end
      return true
    end
    return slot.stepElapsed >= stepOwnTicks(slot) and clipWaitDone(slot, name)
  end
  if stepStartsEffectLater(slot, step, name) then
    return false
  end
  if slot.programEffects[name] == true then
    return true
  end
  error(
    invalid("opening scene waits on an effect that never started", {
      scene = slot.sceneNumber,
      step = step.id,
      effect = name,
    }),
    0
  )
end

---@param self HgssOpeningMovie
local function ensureNext(self)
  if self.currentIndex >= 5 or self.nextSlot ~= nil then
    return
  end
  self.nextSlot = acquireSlot(self, self.scenes[self.currentIndex + 1])
end

---@param self HgssOpeningMovie
local function finishCurrentScene(self)
  local finished = self.currentIndex >= 5
  if finished then
    self.finished = true
    self.pendingFinish = false
    return
  end
  local old = assert(self.current)
  local replacement = self.nextSlot
  self.nextSlot = nil
  if replacement == nil then
    replacement = acquireSlot(self, self.scenes[self.currentIndex + 1])
  end
  self.currentIndex = self.currentIndex + 1
  self.current = replacement
  self.pendingFinish = false
  -- The incoming scene's first source step is already due: immediate
  -- placements land before its first render and its scroll programs
  -- start from the staged origins. Prefetched and transient slots never
  -- apply early, so their tick-zero programs cannot leak movie-level
  -- effects into the still-playing scene.
  applyDueEvents(self, self.current)
  releaseSlot(old)
end

-- Source activity for the single-screen shot policy: an engine is active
-- while it owns a visible background slot, a visible sprite instance, the
-- live town stage on main BG0, or live starter particles on main.
-- Position on the stage is irrelevant here; placement only selects which
-- authored output fills the host, it never invents or hides source output.
---@param slot OpeningMovieSlot scene slot
---@param engine string source engine owning the candidate output
---@return boolean true when the engine carries authored output this frame
local function engineActive(slot, engine)
  local backgrounds = slot.backgrounds[engine]
  if type(backgrounds) == "table" then
    for _, background in pairs(backgrounds) do
      if background.visible then
        return true
      end
    end
  end
  for _, instance in pairs(slot.spriteInstances) do
    if instance.engine == engine and instance.visible then
      return true
    end
  end
  -- Retained town resources alone never count: only a town the source
  -- still shows keeps the main target live, so the rival-only beat after
  -- the authored stop falls through to the sub panels.
  if engine == "main" then
    if slot.townVisible and slot.activeTown ~= nil and slot.renderer ~= nil and #slot.towns > 0 then
      return true
    end
    for _, runtime in ipairs(slot.emitters) do
      if #runtime.particles > 0 then
        return true
      end
    end
  end
  return false
end

-- Beats that keep both physical outputs on a single host screen: the
-- scene-4 hero compositions and the scene-5 panorama are coequal by
-- source authorship, so no single-screen stage may discard either side.
---@param slot OpeningMovieSlot scene slot
---@return boolean true when the beat must present both physical roles
local function shotIsPaired(slot)
  return slot.sceneNumber == 4 or slot.sceneNumber == 5
end

-- Selects the engine whose output fills a single-screen stage on a
-- single-role beat. Exactly one active engine wins; a tie (or no active
-- engine yet) deterministically keeps the main engine, which the source
-- entry mapping then places on its authored physical screen.
---@param slot OpeningMovieSlot scene slot
---@return string source engine owning the active single-role output
local function activeEngine(slot)
  local mainActive, subActive = engineActive(slot, "main"), engineActive(slot, "sub")
  if subActive and not mainActive then
    return "sub"
  end
  return "main"
end

-- Loads the five strictly validated scene manifests for the selected edition
-- in retail order. This is the movie-owner scene-loading seam through which
-- the app startup owner reaches generated opening scenes: callers keep the owned
-- manifests and pass them to the constructor, which retains its input shape.
---@param cacheFs table<string, unknown> generated cache access
---@param versionId string selected edition
---@return table[]? scenes five validated manifests in retail order
---@return unknown? failure first scene load failure
function HgssOpeningMovie.loadValidatedScenes(cacheFs, versionId)
  local scenes = {}
  for sceneNumber = 1, 5 do
    local manifest, failure = StartupAssetCache.loadOpeningScene(cacheFs, sceneNumber, versionId)
    if manifest == nil then
      return nil, failure
    end
    scenes[sceneNumber] = manifest
  end
  return scenes, nil
end

---@param options { versionId: string, scenes: table<string, unknown>[], cacheFs: table<string, unknown>, width: number, height: number, graphics?: table<string, unknown>, displayContext?: DisplayContext }
---@return HgssOpeningMovie
function HgssOpeningMovie.new(options)
  assert(type(options) == "table", "opening movie requires composition options")
  assert(options.versionId == "heartgold" or options.versionId == "soulsilver", "opening movie edition is invalid")
  assert(type(options.scenes) == "table", "opening movie requires five validated scene bundles")
  assert(options.cacheFs and type(options.cacheFs.read) == "function", "opening movie requires generated cache access")
  assert(
    type(options.width) == "number" and options.width > 0 and type(options.height) == "number" and options.height > 0,
    "opening movie dimensions must be positive"
  )
  local graphics = options.graphics or love.graphics
  assert(type(graphics) == "table", "opening movie requires a graphics namespace")
  local displayContext = options.displayContext or DisplayContext.new({ graphics = graphics })
  local scenes = options.scenes
  for sceneNumber = 1, 5 do
    if scenes[sceneNumber] == nil then
      error(invalid("opening movie needs all five scenes in retail order", { scene = sceneNumber }), 0)
    end
  end
  if #scenes ~= 5 then
    error(invalid("opening movie needs all five scenes in retail order", { count = #scenes }), 0)
  end
  local first = scenes[1]
  if type(first) ~= "table" or type(first.generationId) ~= "string" or first.generationId == "" then
    error(invalid("opening movie generation is missing", {}), 0)
  end
  for sceneNumber = 1, 5 do
    checkBundleShape(scenes[sceneNumber], sceneNumber, options.versionId, first.generationId)
  end
  local self = setmetatable({
    versionId = options.versionId,
    cacheFs = options.cacheFs,
    graphics = graphics,
    displayContext = displayContext,
    width = options.width,
    height = options.height,
    scenes = scenes,
    generationId = first.generationId,
    currentIndex = 1,
    finished = false,
    skipEligible = false,
    pendingFinish = false,
    disposed = false,
    current = nil,
    nextSlot = nil,
    mainCanvas = nil,
    subCanvas = nil,
    townScratch = nil,
  }, HgssOpeningMovie)
  -- Bounded readiness: the two fixed source-engine targets are the only
  -- movie canvases, and every scene is strictly acquired plus
  -- offscreen-rendered before the movie becomes visible. Only the first
  -- two slots stay resident; each later scene is a transient that
  -- releases before the next acquires, so at most two retained graphs
  -- plus one transient coexist, and the source clock never advances
  -- during preparation.
  local transient = nil
  local ok, failure = pcall(function()
    self.mainCanvas = graphics.newCanvas(SOURCE_WIDTH, SOURCE_HEIGHT, {
      format = "rgba8",
      readable = true,
      dpiscale = 1,
    })
    self.subCanvas = graphics.newCanvas(SOURCE_WIDTH, SOURCE_HEIGHT, {
      format = "rgba8",
      readable = true,
      dpiscale = 1,
    })
    for _, canvas in ipairs({ self.mainCanvas, self.subCanvas }) do
      if canvas.setFilter ~= nil then
        canvas:setFilter("nearest", "nearest")
      end
    end
    -- The 3D town stage resolves through the shared field renderer,
    -- which presents with a replacing blit: compositing the town over
    -- the sub-engine panels needs a fixed intermediate target rather
    -- than wiping the panels or hiding the town beneath them. Standing
    -- canvas budget is two 256x192 role targets plus this one fixed
    -- 256x192 town scratch, 3*256*192*4 bytes peak, far under the
    -- 1 GiB startup target; no canvas scales with host pixels.
    local stagesTowns = false
    for sceneNumber = 1, 5 do
      if type(scenes[sceneNumber].models) == "table" and #scenes[sceneNumber].models > 0 then
        stagesTowns = true
        break
      end
    end
    if stagesTowns then
      self.townScratch = graphics.newCanvas(SOURCE_WIDTH, SOURCE_HEIGHT, {
        format = "rgba8",
        readable = true,
        dpiscale = 1,
      })
      if self.townScratch.setFilter ~= nil then
        self.townScratch:setFilter("nearest", "nearest")
      end
    end
    -- The retained slots transfer ownership to the movie as soon as each
    -- acquisition succeeds, so the existing dispose path owns them on any
    -- later error; the transient is one local that never aliases them.
    self.current = acquireSlot(self, scenes[1])
    -- The opening frame is already authored: tick-zero programs land
    -- before the first render, so the preflight frame shows first-frame
    -- pixels without advancing the source clock.
    applyDueEvents(self, self.current)
    self:_renderRoles(self.current)
    self.nextSlot = acquireSlot(self, scenes[2])
    self:_renderRoles(self.nextSlot)
    for sceneNumber = 3, 5 do
      transient = acquireSlot(self, scenes[sceneNumber])
      self:_renderRoles(transient)
      releaseSlot(transient)
      transient = nil
      -- Reclaim the transient preflight handles promptly instead of leaving
      -- them queued behind the next acquisition: the retained targets keep
      -- only current and next scene graphs resident from here on.
      settleReleasedHandles(self, self.mainCanvas)
    end
  end)
  if not ok then
    if transient ~= nil then
      releaseSlot(transient)
    end
    transient = nil
    self:dispose()
    error(failure, 0)
  end
  return self
end

function HgssOpeningMovie:updateFixed()
  assert(not self.disposed, "disposed movie cannot advance")
  if self.finished then
    return
  end
  ensureNext(self)
  local slot = assert(self.current)
  slot.sceneTick = slot.sceneTick + 1
  slot.stepElapsed = slot.stepElapsed + 1
  applyDueEvents(self, slot)
  advanceContinuous(slot)
  local guard = 0
  while not self.finished do
    guard = guard + 1
    assert(guard < 4096, "opening movie step cascade cannot settle")
    if not stepComplete(slot) then
      break
    end
    if self.pendingFinish then
      finishCurrentScene(self)
      break
    end
    local steps = slot.manifest.timeline.steps
    slot.stepIndex = slot.stepIndex + 1
    slot.stepElapsed = 0
    if slot.stepIndex > #steps then
      finishCurrentScene(self)
      break
    end
    applyDueEvents(self, slot)
  end
end

---@return boolean
function HgssOpeningMovie:skipAllowed()
  return self.skipEligible and not self.finished and not self.disposed
end

---@return boolean true when an eligible skip finishes the movie
function HgssOpeningMovie:requestSkip()
  if self.disposed or self.finished or not self.skipEligible then
    return false
  end
  self.finished = true
  self.pendingFinish = false
  return true
end

---@return boolean
function HgssOpeningMovie:isFinished()
  return self.finished
end

---@return integer
function HgssOpeningMovie:sceneNumber()
  return self.currentIndex
end

---@param width number
---@param height number
function HgssOpeningMovie:resize(width, height)
  -- Host placement only: the fixed source targets never resize, so a
  -- resize cannot fail, cannot stretch a stale target, and never touches
  -- the source tick or scene identity.
  assert(width > 0 and height > 0, "movie dimensions must be positive")
  self.width, self.height = width, height
end

-- Copies a measured host rectangle so composition planning never mutates
-- the layout-owned bounds it was given.
---@param rect { x: number, y: number, width: number, height: number }
---@return { x: number, y: number, width: number, height: number }
local function copyRect(rect)
  return { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
end

---@param slot OpeningMovieSlot scene slot
---@param clipId string staged sprite clip identity
---@return table<string, unknown>? clip record
local function clipById(slot, clipId)
  for _, clip in ipairs(slot.manifest.spriteClips) do
    if clip.id == clipId then
      return clip
    end
  end
  return nil
end

---@param sprite table<string, unknown> sprite animation state
---@param clip table<string, unknown> staged sprite clip record
---@return integer 1-based frame index
local function spriteFrameIndex(sprite, clip)
  local count = clip.frameCount or 1
  if count <= 1 then
    return 1
  end
  if type(clip.frames) == "table" and #clip.frames > 0 then
    local total = 0
    for _, frame in ipairs(clip.frames) do
      total = total + (frame.duration or 1)
    end
    total = math.max(total, 1)
    local elapsed = sprite.tick % total
    for index, frame in ipairs(clip.frames) do
      local duration = frame.duration or 1
      if elapsed < duration then
        return index
      end
      elapsed = elapsed - duration
    end
    return #clip.frames
  end
  return (math.floor(sprite.tick / 8) % count) + 1
end

---@param slot OpeningMovieSlot scene slot
---@param engine string source engine owning the drawn layers
---@return table<integer, table<string, unknown>> visible backgrounds back-to-front
local function sortedBackgrounds(slot, engine)
  local collected = {}
  local group = slot.backgrounds[engine]
  if type(group) == "table" then
    for _, background in pairs(group) do
      if background.visible then
        collected[#collected + 1] = background
      end
    end
  end
  -- Lower numeric priority is frontmost, so it paints later: collect
  -- back-to-front with a deterministic slot tie-break.
  table.sort(collected, function(a, b)
    if a.priority ~= b.priority then
      return a.priority > b.priority
    end
    return a.bgSlot < b.bgSlot
  end)
  return collected
end

---@param slot OpeningMovieSlot scene slot
---@return number layer alpha following the active blend program
local function layerAlpha(slot)
  local blend = slot.blend
  if blend == nil or blend.ticks <= 0 then
    return 1
  end
  return 1 - 0.5 * math.min(blend.elapsed / blend.ticks, 1)
end

-- Semantic mapping only; placement remains owned by _render.
-- Source engine is main/sub; only physical screen role changes on flip.
-- Numeric lower BG priority paints later in the source engine target.
---@param mask integer five-bit source plane mask (BG0..BG3, OBJ)
---@param planeIndex integer background slot 0..3, or 4 for OBJ pixels
---@return boolean true when the plane paints where the mask selects it
local function maskAllows(mask, planeIndex)
  return math.floor(mask / (2 ^ planeIndex)) % 2 == 1
end

---@param rect table<string, integer> source rectangle with inclusive edges
---@return integer x1, integer y1, integer x2, integer y2 half-open span clipped to the source canvas
local function canvasSpan(rect)
  return math.max(rect.x1, 0),
    math.max(rect.y1, 0),
    math.min(rect.x2 + 1, SOURCE_WIDTH),
    math.min(rect.y2 + 1, SOURCE_HEIGHT)
end

-- Resolves the two hardware spans for one engine: the running WIN0 pan and
-- the WIN1 override, each with its inside mask, plus the outside mask.
-- Returns nil while clipping is disabled or no span covers anything, so a
-- plane paints its whole target in one draw exactly as before.
---@param slot OpeningMovieSlot scene slot
---@param engine string source engine owning the window registers
---@return table<string, unknown>? spans with win0, win1, and outside mask
local function windowSpans(slot, engine)
  local state = slot.windows[engine]
  if state == nil or not state.enabled then
    return nil
  end
  local win0, win1 = nil, nil
  local program = state.win0
  if program ~= nil and program.rect ~= nil then
    local outer = program.rect
    local y1 = math.max(outer.y1, 0)
    local y2 = math.min(outer.y2 + 1, SOURCE_HEIGHT)
    if y1 < y2 then
      if outer.x1 == 0 and outer.x2 == 255 then
        -- Full-width helper: the source spans the display with two
        -- touching rectangles carrying the same inside mask, so a later
        -- direct override replaces exactly the second one.
        win0 = { x1 = 0, y1 = y1, x2 = SOURCE_WIDTH / 2, y2 = y2, mask = program.insideMask }
        if state.win1Source ~= "manual" then
          win1 = { x1 = SOURCE_WIDTH / 2, y1 = y1, x2 = SOURCE_WIDTH, y2 = y2, mask = program.insideMask }
        end
      else
        local x1 = math.max(outer.x1, 0)
        local x2 = math.min(outer.x2 + 1, SOURCE_WIDTH)
        if x1 < x2 then
          win0 = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, mask = program.insideMask }
        end
      end
    end
  end
  if state.win1Source == "manual" and state.win1 ~= nil then
    local x1, y1, x2, y2 = canvasSpan(state.win1.rect)
    if x1 < x2 and y1 < y2 then
      win1 = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, mask = state.win1.insideMask }
    else
      win1 = nil
    end
  end
  if win0 == nil and win1 == nil then
    return nil
  end
  return { win0 = win0, win1 = win1, outside = state.outsideMask }
end

-- Partitions the source canvas along the active span edges and merges each
-- row into the disjoint rectangles where one plane may paint. WIN0 wins
-- over WIN1 on overlap; anything else follows the outside mask.
---@param spans table<string, unknown>? resolved engine spans
---@param planeIndex integer background slot 0..3, or 4 for OBJ pixels
---@return table<integer, integer[]>? allowed rectangles, or nil for one full draw
local function maskRegions(spans, planeIndex)
  if spans == nil then
    return nil
  end
  local win0, win1 = spans.win0, spans.win1
  local outside = spans.outside
  local xs, ys = { 0, SOURCE_WIDTH }, { 0, SOURCE_HEIGHT }
  for _, span in ipairs({ win0, win1 }) do
    if span ~= nil then
      xs[#xs + 1] = span.x1
      xs[#xs + 1] = span.x2
      ys[#ys + 1] = span.y1
      ys[#ys + 1] = span.y2
    end
  end
  table.sort(xs)
  table.sort(ys)
  local regions = {}
  for y = 1, #ys - 1 do
    local y1, y2 = ys[y], ys[y + 1]
    if y1 < y2 then
      local runX1 = nil
      for x = 1, #xs - 1 do
        local x1, x2 = xs[x], xs[x + 1]
        if x1 < x2 then
          local mask = outside
          if win1 ~= nil and x1 >= win1.x1 and x2 <= win1.x2 and y1 >= win1.y1 and y2 <= win1.y2 then
            mask = win1.mask
          end
          if win0 ~= nil and x1 >= win0.x1 and x2 <= win0.x2 and y1 >= win0.y1 and y2 <= win0.y2 then
            mask = win0.mask
          end
          if maskAllows(mask, planeIndex) then
            if runX1 == nil then
              runX1 = x1
            end
          elseif runX1 ~= nil then
            regions[#regions + 1] = { runX1, y1, x1 - runX1, y2 - y1 }
            runX1 = nil
          end
        end
      end
      if runX1 ~= nil then
        regions[#regions + 1] = { runX1, y1, SOURCE_WIDTH - runX1, y2 - y1 }
      end
    end
  end
  return regions
end

-- Draws one plane only where its own mask bit allows it, restoring the
-- borrowed graphics scope per region even when the plane draw throws.
---@param self HgssOpeningMovie
---@param slot OpeningMovieSlot scene slot
---@param engine string source engine owning the plane
---@param planeIndex integer background slot 0..3, or 4 for OBJ pixels
---@param draw fun() plane draw callback
local function drawPlaneClipped(self, slot, engine, planeIndex, draw)
  local regions = maskRegions(windowSpans(slot, engine), planeIndex)
  if regions == nil then
    draw()
    return
  end
  local graphics = self.graphics
  for _, region in ipairs(regions) do
    graphics.push("all")
    local ok, failure = pcall(function()
      graphics.intersectScissor(region[1], region[2], region[3], region[4])
      draw()
    end)
    graphics.pop()
    if not ok then
      error(failure, 0)
    end
  end
end

---@param value unknown raw channel value in 0..1
---@return integer quantized 5-bit channel
local function channel31(value)
  if type(value) ~= "number" then
    return 0
  end
  return math.max(0, math.min(31, math.floor(value * 31 + 0.5)))
end

---@param value unknown raw triple in array, color (r/g/b), or vector (x/y/z) shape
---@return number[] normalized triple with numeric channels
local function tripleOrZero(value)
  if type(value) ~= "table" then
    return { 0, 0, 0 }
  end
  local function channel(valueChannel)
    return (type(valueChannel) == "number") and valueChannel or 0
  end
  return {
    channel(value[1] or value.r or value.x),
    channel(value[2] or value.g or value.y),
    channel(value[3] or value.b or value.z),
  }
end

---@param triple unknown 0..1 RGB triple in either array or named shape
---@return integer packed RGB555 register
local function toRgb555(triple)
  if triple == nil then
    return 0
  end
  local rgb = tripleOrZero(triple)
  return channel31(rgb[1]) + 32 * channel31(rgb[2]) + 1024 * channel31(rgb[3])
end

---@param slot OpeningMovieSlot scene slot
---@return number town index backing the active model or lighting step
local function activeTownIndex(slot)
  if slot.lightingMap ~= nil then
    return slot.lightingMap
  end
  for index, town in ipairs(slot.towns) do
    if town.name == slot.activeTown then
      return town.index or (index - 1)
    end
  end
  return 0
end

---@param slot OpeningMovieSlot scene slot
---@return { name: string?, index: integer?, instance: ModelInstance }? staged town record owning the drawn stage, bind fallback included
local function stagedTown(slot)
  local active = slot.towns[1]
  for _, town in ipairs(slot.towns) do
    if town.name == slot.activeTown then
      active = town
      break
    end
  end
  return active
end

-- Model-units-to-tiles factor carried by the staged town program: staged
-- camera facts (target, distance) arrive in model units while the renderer
-- consumes tiles, so the camera converts through this factor. The field is
-- required on every staged town program; a program without one is malformed
-- staged data and fails loudly instead of framing empty ground.
---@param slot OpeningMovieSlot scene slot
---@return number model-units-to-tiles factor
local function townCameraUnit(slot)
  local town = stagedTown(slot)
  local instance = town ~= nil and town.instance or nil
  local definition = instance ~= nil and instance.definition or nil
  local backend = definition ~= nil and definition.backend or nil
  local program = backend ~= nil and backend.program or nil
  local unit = program ~= nil and program.tileScale or nil
  assert(type(unit) == "number" and unit > 0, "town stage carries no tile scale")
  return unit
end

---@param slot OpeningMovieSlot scene slot
---@return table<string, unknown> render environment with source town lighting
local function townEnvironment(slot)
  local lighting = slot.manifest.lighting
  local towns = (type(lighting) == "table") and lighting.towns or nil
  local record = (type(towns) == "table") and towns[activeTownIndex(slot) + 1] or nil
  local vectors = (type(record) == "table") and record.vectors or nil
  local colors = (type(record) == "table") and record.colors or nil
  if slot.townEnvKey ~= activeTownIndex(slot) or slot.townEnv == nil then
    local lights = {}
    for index = 1, 4 do
      local rawVector = (type(vectors) == "table") and vectors[index] or nil
      local rawColor = (type(colors) == "table") and colors[index] or nil
      local color = tripleOrZero(rawColor)
      local vector = tripleOrZero(rawVector)
      local lit = (color[1] + color[2] + color[3]) > 0
      lights[index] = {
        enabled = lit,
        color = lit and { color[1], color[2], color[3] } or { 0, 0, 0 },
        direction = { vector[1], vector[2], vector[3] },
        colorRgb555 = lit and toRgb555(color) or 0,
        vectorFx12 = {
          math.floor(vector[1] * 4096 + 0.5),
          math.floor(vector[2] * 4096 + 0.5),
          math.floor(vector[3] * 4096 + 0.5),
        },
      }
    end
    slot.townEnv = {
      lighting = {
        records = {
          {
            endHalfSeconds = NOON_HALF_SECONDS * 2,
            lights = lights,
            diffuseRgb555 = toRgb555(record and record.diffuse),
            ambientRgb555 = toRgb555(record and record.ambient),
            specularRgb555 = toRgb555(record and record.specular),
            emissionRgb555 = toRgb555(record and record.emission),
          },
        },
      },
      edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
      fog = {
        enabled = false,
        color = 0,
        offset = 0,
        slope = 0,
        alpha = 0,
        table = {
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
        },
      },
    }
    slot.townEnvKey = activeTownIndex(slot)
  end
  return slot.townEnv
end

---@param slot OpeningMovieSlot scene slot
---@return table<string, unknown> camera track for the shared field renderer
local function townCamera(slot)
  -- The retail town camera orbits its target by the compiled fixed-point
  -- angle at the staged distance, and the projection carries the compiled
  -- town field angle on the source 4:3 frame. Host layout never widens
  -- this lens; the compositor places the projected frame.
  local unit = townCameraUnit(slot)
  local camera = slot.manifest.camera
  local stagedTarget = (camera and camera.target) or TOWN_DEFAULT_TARGET
  local target = { stagedTarget[1] * unit, stagedTarget[2] * unit, stagedTarget[3] * unit }
  local stagedDistance = slot.cameraDistance or (camera and camera.distance) or TOWN_DEFAULT_DISTANCE
  local distance = stagedDistance * unit
  local angle = (camera and camera.angle) or { 0, 0, 0, 0 }
  local pitch = ((angle[1] or 0) / 65536) * (2 * math.pi)
  local yaw = ((angle[2] or 0) / 65536) * (2 * math.pi)
  local eye = {
    target[1] + math.sin(yaw) * distance * math.cos(pitch),
    target[2] - math.sin(pitch) * distance,
    target[3] + math.cos(yaw) * distance * math.cos(pitch),
  }
  local viewMatrix = Matrix4.lookAt(eye, target, { 0, 1, 0 })
  local halfAngle = (((camera and camera.fovAngle) or TOWN_HALF_ANGLE_INDEX) / 65536) * (2 * math.pi)
  local projectionMatrix = Matrix4.perspective(2 * halfAngle, SOURCE_WIDTH / SOURCE_HEIGHT, GPU_NEAR, GPU_FAR)
  local function cameraView()
    return viewMatrix
  end
  local function cameraProjection()
    return projectionMatrix
  end
  return {
    far = GPU_FAR,
    zoom = 1,
    view = cameraView,
    projection = cameraProjection,
    billboardProjection = cameraProjection,
  }
end

local function worldDrawItems(instance, meshes)
  local items = instance:drawItems(meshes)
  for _, item in ipairs(items) do
    item.worldSpace = true
  end
  return items
end

---@param slot OpeningMovieSlot scene slot
---@param rect { x: number, y: number, width: number, height: number } device-space role rectangle
local function drawTowns(slot, rect)
  local active = stagedTown(slot)
  if active == nil or active.instance == nil then
    return
  end
  local instance = active.instance
  local meshes = assert(instance.renderMeshesById)
  local items = worldDrawItems(instance, meshes)
  local viewport = {
    worldViewport = { x = rect.x, y = rect.y, width = rect.width, height = rect.height },
    referenceFrame = { x = rect.x, y = rect.y, width = rect.width, height = rect.height },
  }
  slot.renderer:draw(townEnvironment(slot), townCamera(slot), { items }, nil, viewport, 1)
end

---@param slot OpeningMovieSlot scene slot
---@param role string upper or lower
---@return string source engine owning the role output
local function roleEngine(slot, role)
  if (role == "upper") == (slot.mainPhysical == "upper") then
    return "main"
  end
  return "sub"
end

---@param self HgssOpeningMovie
---@param slot OpeningMovieSlot scene slot
---@param engine string source engine owning the drawn instances
local function drawSprites(self, slot, engine)
  local graphics = self.graphics
  local staged = {}
  for order, instanceId in ipairs(slot.spriteOrder) do
    local instance = slot.spriteInstances[instanceId]
    if instance ~= nil and instance.engine == engine and instance.visible and instance.clipId ~= nil then
      staged[#staged + 1] = { order = order, instance = instance }
    end
  end
  table.sort(staged, function(a, b)
    local anterior = a.instance.drawOrder or 0
    local posterior = b.instance.drawOrder or 0
    if anterior ~= posterior then
      return anterior < posterior
    end
    return a.order < b.order
  end)
  for _, entry in ipairs(staged) do
    local sprite = entry.instance
    local image = slot.imageByPath[sprite.clipId]
    if image ~= nil then
      local clip = clipById(slot, sprite.clipId)
      local frame = (clip ~= nil) and spriteFrameIndex(sprite, clip) or 1
      local record = clip ~= nil and type(clip.frames) == "table" and clip.frames[frame] or nil
      local offsetX, offsetY = 0, 0
      if type(record) == "table" then
        offsetX = record.offsetX or 0
        offsetY = record.offsetY or 0
      end
      local x, y = sprite.x + offsetX, sprite.y + offsetY
      local quad = nil
      if type(record) == "table" then
        if type(record.x) == "number" and type(record.width) == "number" and record.width > 0 then
          quad = sprite.quads[frame]
          if quad == nil then
            local imageWidth, imageHeight = image:getWidth(), image:getHeight()
            local clipped = pcall(function()
              sprite.quads[frame] = graphics.newQuad(
                math.max(record.x, 0),
                math.max(record.y or 0, 0),
                math.min(record.width, imageWidth),
                math.min(record.height or imageHeight, imageHeight),
                imageWidth,
                imageHeight
              )
            end)
            if clipped then
              quad = sprite.quads[frame]
            end
          end
        end
      end
      if quad ~= nil then
        graphics.draw(image, quad, x, y)
      else
        graphics.draw(image, x, y)
      end
    end
  end
end

---@param slot OpeningMovieSlot scene slot
local function drawParticles(self, slot)
  local graphics = self.graphics
  -- Each live particle paints its own recorded texture, tinted by the
  -- recorded base color, faded by the recorded base alpha (linearly to
  -- zero over its life when the record carries the alpha animation flag),
  -- and drawn at the recorded base scale (settling to half size when the
  -- record carries the scale animation flag).
  for _, runtime in ipairs(slot.emitters) do
    local record = runtime.record --[[@as table<string, unknown>]]
    local textureImage = record.textureImage --[[@as string]]
    local image = slot.imageByPath[textureImage]
    assert(image ~= nil, "opening scene staged particle art is missing: " .. tostring(textureImage))
    local imageWidth, imageHeight = image:getWidth(), image:getHeight()
    local tintR, tintG, tintB = emitterColorChannels(record.baseColor)
    local baseAlpha = record.baseAlpha --[[@as number]] / 31
    local baseScale = record.baseScale --[[@as number]]
    local animations = record.animations --[[@as table<string, unknown>]]
    for _, particle in ipairs(runtime.particles) do
      local entry = particle --[[@as table<string, unknown>]]
      local life = entry.life --[[@as integer]]
      if life > 0 then
        local maxLife = entry.maxLife --[[@as integer]]
        local fade = 1
        if animations.alpha == true then
          fade = life / maxLife
        end
        local scale = baseScale
        if animations.scale == true then
          scale = scale * (0.5 + 0.5 * life / maxLife)
        end
        graphics.setColor(tintR, tintG, tintB, baseAlpha * fade)
        graphics.draw(
          image,
          entry.x --[[@as number]],
          entry.y --[[@as number]],
          entry.rot --[[@as number]],
          scale,
          scale,
          imageWidth / 2,
          imageHeight / 2
        )
      end
    end
  end
  graphics.setColor(1, 1, 1, 1)
end

---@param slot OpeningMovieSlot scene slot
local function drawFade(self, slot)
  local fade = slot.fade
  if fade == nil then
    return
  end
  local progress = math.min(fade.elapsed / math.max(fade.ticks, 1), 1)
  local kind = fade.kind or ""
  local clearing = kind:find("in", 1, true) ~= nil or kind:find("open", 1, true) ~= nil
  local alpha = clearing and (1 - progress) or progress
  local white = kind:find("white", 1, true) ~= nil
  if white then
    self.graphics.setColor(1, 1, 1, alpha)
  else
    self.graphics.setColor(0, 0, 0, alpha)
  end
  self.graphics.rectangle("fill", 0, 0, SOURCE_WIDTH, SOURCE_HEIGHT)
  self.graphics.setColor(1, 1, 1, 1)
end

---@param slot OpeningMovieSlot scene slot
local function drawWipe(self, slot)
  local wipe = slot.wipe
  if wipe == nil then
    return
  end
  local progress = math.min(wipe.elapsed / math.max(wipe.ticks, 1), 1)
  local hole = (wipe.mode == "in") and progress or (1 - progress)
  if hole <= 0 then
    self.graphics.setColor(0, 0, 0, 1)
    self.graphics.rectangle("fill", 0, 0, SOURCE_WIDTH, SOURCE_HEIGHT)
    self.graphics.setColor(1, 1, 1, 1)
    return
  end
  if hole >= 1 then
    return
  end
  local graphics = self.graphics
  graphics.setColor(0, 0, 0, 1)
  local halfWidth, halfHeight = (SOURCE_WIDTH / 2) * hole, (SOURCE_HEIGHT / 2) * hole
  local left, top = SOURCE_WIDTH / 2 - halfWidth, SOURCE_HEIGHT / 2 - halfHeight
  graphics.rectangle("fill", 0, 0, SOURCE_WIDTH, top)
  graphics.rectangle("fill", 0, top + halfHeight * 2, SOURCE_WIDTH, SOURCE_HEIGHT - top - halfHeight * 2)
  graphics.rectangle("fill", 0, top, left, halfHeight * 2)
  graphics.rectangle("fill", left + halfWidth * 2, top, SOURCE_WIDTH - left - halfWidth * 2, halfHeight * 2)
  graphics.setColor(1, 1, 1, 1)
end

---@param self HgssOpeningMovie
---@param canvas love.Canvas fixed role target to project
---@param rect { x: number, y: number, width: number, height: number } host pane receiving the role
---@param cover boolean true fills (crops) the pane, false fits (letterboxes) it
function HgssOpeningMovie:_blitRole(canvas, rect, cover)
  local graphics = self.graphics
  local scale
  if cover then
    scale = math.max(rect.width / SOURCE_WIDTH, rect.height / SOURCE_HEIGHT)
  else
    scale = math.min(rect.width / SOURCE_WIDTH, rect.height / SOURCE_HEIGHT)
  end
  local drawnWidth, drawnHeight = SOURCE_WIDTH * scale, SOURCE_HEIGHT * scale
  local x = rect.x + (rect.width - drawnWidth) / 2
  local y = rect.y + (rect.height - drawnHeight) / 2
  graphics.push("all")
  local ok, failure = pcall(function()
    graphics.intersectScissor(rect.x, rect.y, rect.width, rect.height)
    graphics.draw(canvas, x, y, 0, scale, scale)
  end)
  graphics.pop()
  if not ok then
    error(failure, 0)
  end
end

---@param slot OpeningMovieSlot scene slot
---@return boolean true when the town stage contributes main BG0 pixels now
local function townDrawable(slot)
  return slot.townVisible and slot.activeTown ~= nil and slot.renderer ~= nil and #slot.towns > 0
end

---@param slot OpeningMovieSlot scene slot
---@return boolean true while starter particles remain alive
local function particlesLive(slot)
  for _, runtime in ipairs(slot.emitters) do
    if #runtime.particles > 0 then
      return true
    end
  end
  return false
end

-- Samples the 256x192 engine viewport out of the full native BG texture
-- at the signed source offsets with Euclidean wrap. Positive offsets
-- sample farther into the source map (content moves left), so the viewport
-- splits at the wrap seams into as many as four partial quads drawn at
-- exact source positions; no shifted single blit and no uncovered strips.
---@param self HgssOpeningMovie
---@param image love.Image staged native BG texture
---@param background table<string, unknown> live BG slot with width, height, scrollX, scrollY
local function drawWrappedBackground(self, image, background)
  local graphics = self.graphics
  local width = background.width --[[@as integer]]
  local height = background.height --[[@as integer]]
  local offsetX = ((background.scrollX % width) + width) % width
  local offsetY = ((background.scrollY % height) + height) % height
  local firstW = math.min(width - offsetX, SOURCE_WIDTH)
  local firstH = math.min(height - offsetY, SOURCE_HEIGHT)
  local columns = { { sx = offsetX, dx = 0, w = firstW } }
  if firstW < SOURCE_WIDTH then
    columns[#columns + 1] = { sx = 0, dx = firstW, w = SOURCE_WIDTH - firstW }
  end
  local rows = { { sy = offsetY, dy = 0, h = firstH } }
  if firstH < SOURCE_HEIGHT then
    rows[#rows + 1] = { sy = 0, dy = firstH, h = SOURCE_HEIGHT - firstH }
  end
  for _, column in ipairs(columns) do
    for _, row in ipairs(rows) do
      graphics.draw(image, graphics.newQuad(column.sx, row.sy, column.w, row.h, width, height), column.dx, row.dy)
    end
  end
end

---@param self HgssOpeningMovie
---@param slot OpeningMovieSlot scene slot
---@param canvas love.Canvas fixed role target receiving the engine output
---@param engine string source engine rendered into its fixed role target
function HgssOpeningMovie:_renderEngine(slot, canvas, engine)
  local graphics = self.graphics
  -- The town stage resolves once into the fixed scratch target (its
  -- presentation blit replaces); the plane pass below composites the same
  -- scratch into each allowed region instead of re-rendering 3D per clip.
  -- It belongs to main BG0 while the source shows it, composited over the
  -- 2D panels at priority 0 instead of into the other engine.
  if engine == "main" and townDrawable(slot) then
    local scratch = assert(self.townScratch, "town stage requires its composite scratch")
    graphics.setCanvas(scratch)
    graphics.clear(0, 0, 0, 0)
    drawTowns(slot, { x = 0, y = 0, width = SOURCE_WIDTH, height = SOURCE_HEIGHT })
    graphics.setCanvas(canvas)
  end
  -- One ordered plane list per engine: enabled 2D slots back-to-front,
  -- the main BG0 3D stage at priority 0, OBJ sprites above every BG, then
  -- the unmasked fade and wipe overlays.
  local planes = {}
  for _, background in ipairs(sortedBackgrounds(slot, engine)) do
    planes[#planes + 1] =
      { priority = background.priority, bgSlot = background.bgSlot, kind = 0, background = background }
  end
  if engine == "main" then
    if townDrawable(slot) then
      planes[#planes + 1] = { priority = 0, bgSlot = 0, kind = 1 }
    end
    if particlesLive(slot) then
      planes[#planes + 1] = { priority = 0, bgSlot = 0, kind = 2 }
    end
  end
  table.sort(planes, function(a, b)
    if a.priority ~= b.priority then
      return a.priority > b.priority
    end
    if a.bgSlot ~= b.bgSlot then
      return a.bgSlot < b.bgSlot
    end
    return a.kind < b.kind
  end)
  for index, plane in ipairs(planes) do
    if plane.kind == 0 then
      local background = plane.background
      local image = slot.imageByPath[background.image]
      if image ~= nil then
        local frontmost = index == #planes
        drawPlaneClipped(self, slot, engine, background.bgSlot, function()
          if frontmost then
            graphics.setColor(1, 1, 1, layerAlpha(slot))
          else
            graphics.setColor(1, 1, 1, 1)
          end
          drawWrappedBackground(self, image, background)
        end)
      end
    elseif plane.kind == 1 then
      drawPlaneClipped(self, slot, engine, 0, function()
        local scratch = assert(self.townScratch, "town stage requires its composite scratch")
        graphics.setColor(1, 1, 1, 1)
        graphics.setBlendMode("alpha", "premultiplied")
        graphics.draw(scratch, 0, 0)
        graphics.setBlendMode("alpha", "alphamultiply")
      end)
    else
      -- Starter particles emit on the main 3D output alone; the physical
      -- mapping below moves that whole target, never a second copy.
      drawPlaneClipped(self, slot, engine, 0, function()
        drawParticles(self, slot)
      end)
    end
  end
  graphics.setColor(1, 1, 1, 1)
  drawPlaneClipped(self, slot, engine, 4, function()
    drawSprites(self, slot, engine)
  end)
  drawFade(self, slot)
  drawWipe(self, slot)
end

---@param self HgssOpeningMovie
---@param slot OpeningMovieSlot scene slot
function HgssOpeningMovie:_renderRoles(slot)
  local graphics = self.graphics
  local previous = graphics.getCanvas()
  graphics.push("all")
  local ok, failure = pcall(function()
    assert(self.mainCanvas ~= nil and self.subCanvas ~= nil, "movie role targets are missing")
    graphics.setCanvas(self.mainCanvas)
    graphics.clear(0, 0, 0, 1)
    self:_renderEngine(slot, self.mainCanvas, "main")
    graphics.setCanvas(self.subCanvas)
    graphics.clear(0, 0, 0, 1)
    self:_renderEngine(slot, self.subCanvas, "sub")
    graphics.setCanvas(previous)
  end)
  graphics.pop()
  if not ok then
    error(failure, 0)
  end
end

function HgssOpeningMovie:_render()
  local slot = self.current
  if slot == nil or self.mainCanvas == nil or self.subCanvas == nil then
    return
  end
  local graphics = self.graphics
  -- Both source engines render exactly once into their fixed targets;
  -- host layout below only selects which authored outputs fill the stage.
  self:_renderRoles(slot)
  local measurement = self.displayContext:measure(self.width, self.height)
  local configuration = ApplicationLayout.classify(measurement, nil)
  local selection = ApplicationLayout.selectSurfaces(measurement)
  local primary = selection.primary.usableBounds
  if primary == nil then
    primary = { x = 0, y = 0, width = self.width, height = self.height }
  end
  local upperCanvas = (roleEngine(slot, "upper") == "main") and self.mainCanvas or self.subCanvas
  local lowerCanvas = (roleEngine(slot, "upper") == "main") and self.subCanvas or self.mainCanvas
  assert(upperCanvas ~= nil, "movie role targets are missing")
  assert(lowerCanvas ~= nil, "movie role targets are missing")
  graphics.clear(0, 0, 0, 1)
  if configuration == "dualDisplay" and selection.secondary ~= nil and selection.secondary.usableBounds ~= nil then
    -- Each physical surface is its own source screen: fill it like the
    -- tall panes below, preserving the 4:3 projection without squeezing.
    self:_blitRole(upperCanvas, copyRect(primary), true)
    self:_blitRole(lowerCanvas, copyRect(selection.secondary.usableBounds), true)
    return
  end
  if configuration == "tall" then
    local half = primary.height / 2
    self:_blitRole(upperCanvas, { x = primary.x, y = primary.y, width = primary.width, height = half }, true)
    self:_blitRole(lowerCanvas, {
      x = primary.x,
      y = primary.y + half,
      width = primary.width,
      height = primary.height - half,
    }, true)
    return
  end
  if shotIsPaired(slot) then
    -- Coequal beats keep both outputs on one stage with no overlay strip:
    -- stacked as one 256x384 frame on compact/native stages, side by side
    -- as one 512x192 pair on wide stages, each fit inside the safe bounds.
    -- Tall and dual stages always stack (or surface) both roles above.
    if configuration == "wide" then
      local scale = math.min(primary.width / (SOURCE_WIDTH * 2), primary.height / SOURCE_HEIGHT)
      local paneWidth, paneHeight = SOURCE_WIDTH * scale, SOURCE_HEIGHT * scale
      local x = primary.x + (primary.width - paneWidth * 2) / 2
      local y = primary.y + (primary.height - paneHeight) / 2
      self:_blitRole(upperCanvas, { x = x, y = y, width = paneWidth, height = paneHeight }, false)
      self:_blitRole(lowerCanvas, { x = x + paneWidth, y = y, width = paneWidth, height = paneHeight }, false)
      return
    end
    local scale = math.min(primary.width / SOURCE_WIDTH, primary.height / (SOURCE_HEIGHT * 2))
    local paneWidth, paneHeight = SOURCE_WIDTH * scale, SOURCE_HEIGHT * scale
    local x = primary.x + (primary.width - paneWidth) / 2
    local y = primary.y + (primary.height - paneHeight * 2) / 2
    self:_blitRole(upperCanvas, { x = x, y = y, width = paneWidth, height = paneHeight }, false)
    self:_blitRole(lowerCanvas, { x = x, y = y + paneHeight, width = paneWidth, height = paneHeight }, false)
    return
  end
  local activeCanvas = (activeEngine(slot) == "main") and self.mainCanvas or self.subCanvas
  assert(activeCanvas ~= nil, "movie role targets are missing")
  self:_blitRole(activeCanvas, copyRect(primary), false)
end

function HgssOpeningMovie:draw()
  if self.disposed then
    return
  end
  if self.mainCanvas == nil or self.subCanvas == nil then
    return
  end
  local graphics = self.graphics
  graphics.push("all")
  local ok, failure = pcall(function()
    self:_render()
  end)
  graphics.pop()
  if not ok then
    error(failure, 0)
  end
end

function HgssOpeningMovie:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  local current, nextSlot, mainCanvas, subCanvas, townScratch =
    self.current, self.nextSlot, self.mainCanvas, self.subCanvas, self.townScratch
  self.current, self.nextSlot, self.mainCanvas, self.subCanvas, self.townScratch = nil, nil, nil, nil, nil
  if current ~= nil then
    releaseSlot(current)
  end
  if nextSlot ~= nil then
    releaseSlot(nextSlot)
  end
  -- Settle retired scene handles before releasing the targets that drew
  -- them, so teardown leaves no queued (but logically released) handles
  -- behind.
  settleReleasedHandles(self, mainCanvas)
  if mainCanvas ~= nil then
    mainCanvas:release()
  end
  if subCanvas ~= nil then
    subCanvas:release()
  end
  if townScratch ~= nil then
    townScratch:release()
  end
end

return HgssOpeningMovie
