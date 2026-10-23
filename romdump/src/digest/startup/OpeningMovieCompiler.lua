-- Bounded source orchestrator for one HGSS opening-movie scene. Reads only
-- that scene's source members from NARC_demo_opening_gs_opening (plus the
-- scene 4 particle member through the narrow particle compiler), decodes
-- 2D art through the shared G2D owners, scene 3 towns through the shared
-- dynamic model owner, and emits the strictly normalized source-independent
-- scene bundle: versioned manifest, staged PNG/mesh/clip files, closed
-- movie event program keyed by source engine, numeric BG slot, sprite
-- instance, and source step tick, and producer dependencies for the job
-- receipt. No LÖVE objects, no ROM handles, and no source member identities
-- cross into the manifest. Unsupported source members, animations, or
-- particle data fail the build with scene and member context; nothing is
-- guessed.

local Errors = require("libs.errors.src.Errors")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local RgbaImage = require("romdump.src.digest.ui.RgbaImage")
local Hashing = require("romdump.src.digest.Hashing")
local Lz10 = require("romdump.src.digest.Lz10")
local PngWriter = require("libs.assets.src.PngWriter")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local NitroAnimation = require("libs.nds.src.nitro.g3d.NitroAnimation")
local DynamicModelCompiler = require("romdump.src.digest.model.DynamicModelCompiler")
local MapPropAnimCompiler = require("romdump.src.digest.model.MapPropAnimCompiler")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local SceneSources = require("romdump.src.digest.startup.OpeningMovieSceneSources")
local OpeningParticleCompiler = require("romdump.src.digest.startup.OpeningParticleCompiler")

local OpeningMovieCompiler = {}

OpeningMovieCompiler.ERROR = { SOURCE_INVALID = "OPENING_MOVIE_SOURCE_INVALID" }

---@param message string
---@param context table<string, unknown>|nil
---@noreturn
local function sourceError(message, context)
  Errors.raise(OpeningMovieCompiler.ERROR.SOURCE_INVALID, message, context or {})
end

---@param archive table<string, unknown>
---@param memberId integer
---@param role string
---@param sceneNumber integer
---@param dependencies table<string, unknown>[]
---@return string
local function readMember(archive, memberId, role, sceneNumber, dependencies)
  if memberId < 0 or memberId >= archive:memberCount() then
    sourceError("opening scene source member is unavailable", {
      scene = sceneNumber,
      member = memberId,
      role = role,
      count = archive:memberCount(),
    })
  end
  local bytes, err = archive:readMember(memberId)
  if type(bytes) ~= "string" then
    sourceError("opening scene source member could not be read", {
      scene = sceneNumber,
      member = memberId,
      role = role,
      error = tostring(err),
    })
  end
  dependencies[#dependencies + 1] = { role = role, member = memberId, sha1 = Hashing.sha1hex(bytes) }
  return bytes
end

---@param bytes string
---@param role string
---@param sceneNumber integer
---@param memberId integer
---@return string plain bytes
local function plainBytes(bytes, role, sceneNumber, memberId)
  if string.byte(bytes, 1) == 0x10 then
    local plain, err = Lz10.decode(bytes)
    if plain == nil then
      sourceError("opening scene source could not be decompressed", {
        scene = sceneNumber,
        member = memberId,
        role = role,
        error = tostring(err),
      })
    end
    return assert(plain)
  end
  return bytes
end

---@param bytes string
---@param role string
---@param sceneNumber integer
---@param memberId integer
---@return { depth: integer, tiles: string } decoded char record
local function decodeChar(bytes, role, sceneNumber, memberId)
  local decoded, err = G2dDecoder.decodeChar(plainBytes(bytes, role, sceneNumber, memberId), { label = role })
  if decoded == nil then
    sourceError("opening scene background has an unexpected character format", {
      scene = sceneNumber,
      member = memberId,
      role = role,
      error = tostring(err),
    })
  end
  return assert(decoded)
end

---@param bytes string
---@param role string
---@param sceneNumber integer
---@param memberId integer
---@return { width: integer, height: integer, entries: table[] } decoded screen record
local function decodeScreen(bytes, role, sceneNumber, memberId)
  local decoded, err = G2dDecoder.decodeScreen(plainBytes(bytes, role, sceneNumber, memberId), { label = role })
  if decoded == nil then
    sourceError("opening scene background has an unexpected screen format", {
      scene = sceneNumber,
      member = memberId,
      role = role,
      error = tostring(err),
    })
  end
  return assert(decoded)
end

---@param bytes string
---@param role string
---@param sceneNumber integer
---@param memberId integer
---@return { colors: { r: integer, g: integer, b: integer }[] } decoded palette record
local function decodePalette(bytes, role, sceneNumber, memberId)
  local decoded, err = G2dDecoder.decodePalette(plainBytes(bytes, role, sceneNumber, memberId), { label = role })
  if decoded == nil then
    sourceError("opening scene background has an unexpected palette format", {
      scene = sceneNumber,
      member = memberId,
      role = role,
      error = tostring(err),
    })
  end
  return assert(decoded)
end

---@param bytes string
---@param role string
---@param sceneNumber integer
---@param memberId integer
---@return { cells: table[] } decoded cell record
local function decodeCell(bytes, role, sceneNumber, memberId)
  local decoded, err = G2dDecoder.decodeCell(plainBytes(bytes, role, sceneNumber, memberId), { label = role })
  if decoded == nil then
    sourceError("opening scene sprite has an unexpected cell format", {
      scene = sceneNumber,
      member = memberId,
      role = role,
      error = tostring(err),
    })
  end
  return assert(decoded)
end

---@param bytes string
---@param role string
---@param sceneNumber integer
---@param memberId integer
---@return { anims: table[] } decoded animation sequences
local function decodeAnimation(bytes, role, sceneNumber, memberId)
  local decoded, err = G2dDecoder.decodeAnimation(plainBytes(bytes, role, sceneNumber, memberId), { label = role })
  if decoded == nil then
    sourceError("opening scene sprite has an unexpected animation format", {
      scene = sceneNumber,
      member = memberId,
      role = role,
      error = tostring(err),
    })
  end
  return assert(decoded)
end

---@param sceneNumber integer
---@param bankName string
---@param sequence integer zero-based retail sequence
---@param animation { anims: table[] } decoded NANR sequences
---@return { frames: table[] } retail sequence record
local function playedSequence(sceneNumber, bankName, sequence, animation)
  local record = animation.anims[sequence + 1]
  if record == nil then
    sourceError("opening scene sprite is missing its played animation sequence", {
      scene = sceneNumber,
      bank = bankName,
      sequence = sequence,
    })
  end
  return assert(record)
end

---@param frames table<string, unknown>[] rendered frame images
---@param role string bank and sequence label for diagnostics
---@return table<string, unknown> filmstrip image plus per-frame records
local function filmstrip(frames, role)
  assert(#frames > 0, "opening sprite sequence carries no rendered frames: " .. role)
  local height = 0
  local width = 0
  for _, frame in ipairs(frames) do
    height = math.max(height, frame.height)
    width = width + frame.width
  end
  local rows = {}
  for row = 1, height do
    rows[row] = {}
  end
  local cursor = 0
  local records = {}
  for _, frame in ipairs(frames) do
    for row = 1, frame.height do
      rows[row][#rows[row] + 1] = frame.pixels:sub((row - 1) * frame.width * 4 + 1, row * frame.width * 4)
    end
    local blank = string.rep("\0", frame.width * 4)
    for row = frame.height + 1, height do
      rows[row][#rows[row] + 1] = blank
    end
    records[#records + 1] = {
      x = cursor,
      y = 0,
      width = frame.width,
      height = frame.height,
      offsetX = frame.offset.x,
      offsetY = frame.offset.y,
      duration = frame.duration,
    }
    cursor = cursor + frame.width
  end
  local pixels = {}
  for row = 1, height do
    pixels[#pixels + 1] = table.concat(rows[row])
  end
  return { width = width, height = height, pixels = table.concat(pixels), frames = records }
end

---@param sceneNumber integer
---@param bank table<string, unknown>
---@param charData { depth: integer, tiles: string }
---@param paletteData { colors: { r: integer, g: integer, b: integer }[] }
---@param cellData { cells: table[] }
---@param animation { anims: table[] }
---@param root string
---@param files table<string, string>
---@return table<string, unknown>[] compiled sprite clips
local function compileBank(sceneNumber, bank, charData, paletteData, cellData, animation, root, files)
  local clips = {}
  for _, sequence in ipairs(bank.sequences) do
    local played = playedSequence(sceneNumber, bank.name, sequence, animation)
    if #played.frames == 0 then
      sourceError("opening scene sprite sequence carries no frames", {
        scene = sceneNumber,
        bank = bank.name,
        sequence = sequence,
      })
    end
    local rendered = {}
    for frameIndex in ipairs(played.frames) do
      local frame = played.frames[frameIndex]
      local cell = cellData.cells[frame.cell + 1]
      if cell ~= nil and type(cell.objs) == "table" and #cell.objs == 0 then
        -- Retail blanking frames reference objectless cells: nothing is
        -- displayed, but the frame tick still elapses. Preserve the timing
        -- as a transparent frame rather than dropping it or failing.
        rendered[#rendered + 1] = {
          width = 1,
          height = 1,
          pixels = string.rep("\0", 4),
          offset = { x = 0, y = 0 },
          duration = frame.duration,
        }
      else
        local image = G2dRasterizer.renderAnimationFrame(charData, paletteData, cellData, played, frameIndex, {
          engine = "opening",
          scene = sceneNumber,
          bank = bank.name,
          sequence = sequence,
        })
        rendered[#rendered + 1] = {
          width = image.width,
          height = image.height,
          pixels = image.pixels,
          offset = image.offset,
          duration = played.frames[frameIndex].duration,
        }
      end
    end
    local strip = filmstrip(rendered, bank.name .. "-seq" .. sequence)
    local path = root .. "/sprites/" .. bank.name .. "-seq" .. sequence .. ".png"
    files[path] = PngWriter.encode(strip.width, strip.height, strip.pixels)
    local clip = {
      id = path,
      bank = bank.name,
      sequence = sequence,
      frameCount = #strip.frames,
      frames = strip.frames,
    }
    if bank.speciesId ~= nil then
      clip.speciesId = bank.speciesId
    end
    clips[#clips + 1] = clip
  end
  return clips
end

---@param model table<string, unknown> compiled dynamic model
---@param root string scene asset root the model art stages under
local function rewriteModelPaths(model, root)
  local function rewrite(path)
    assert(type(path) == "string", "compiled opening scene asset path is missing")
    local geometry = path:match("^assets/generated/maps/geometry/(.+)$")
    if geometry then
      return root .. "/geometry/" .. geometry
    end
    local texture = path:match("^assets/generated/maps/textures/(.+)$")
    if texture then
      return root .. "/textures/" .. texture
    end
    return path
  end
  for _, batch in ipairs(model.dynamic.batches) do
    batch.geometry = rewrite(batch.geometry)
  end
  for _, material in ipairs(model.materials) do
    if material.texture then
      material.texture = rewrite(material.texture)
    end
    for _, variant in ipairs(material.variants or {}) do
      variant.texture = rewrite(variant.texture)
    end
  end
end

---@param model table<string, unknown> compiled dynamic model
---@param sceneNumber integer
local function sanitizeModel(model, sceneNumber)
  local function clean(value, seen)
    if type(value) ~= "table" or seen[value] then
      return
    end
    seen[value] = true
    for key, child in pairs(value) do
      if key == "fileId" or key == "narcId" or key == "memberId" then
        value[key] = nil
      else
        if type(key) == "string" and key:find("NARC_", 1, true) then
          sourceError("opening scene model carries a source archive identity", { scene = sceneNumber })
        end
        if type(child) == "string" and child:find("NARC_", 1, true) then
          sourceError("opening scene model carries a source archive identity", { scene = sceneNumber })
        end
        clean(child, seen)
      end
    end
  end
  clean(model, {})
end

---@param archive table<string, unknown>
---@param versionId string
---@param sceneNumber integer
---@param root string
---@param files table<string, string>
---@param dependencies table<string, unknown>[]
---@return table<string, unknown>[] town model records
local function compileTowns(archive, versionId, sceneNumber, root, files, dependencies)
  local towns = SceneSources.townSet()
  local textures, meshes = {}, {}
  local models = {}
  for index, town in ipairs(towns.models) do
    local modelBytes = readMember(archive, town.model, "town-" .. town.name .. "-model", sceneNumber, dependencies)
    local decodedModel, modelErr = Nsbmd.decode(modelBytes, { alias = SceneSources.ARCHIVE, memberId = town.model })
    if
      type(decodedModel) ~= "table"
      or type(decodedModel.models) ~= "table"
      or type(decodedModel.models[1]) ~= "table"
    then
      sourceError("opening scene town model is not a textured NSBMD", {
        scene = sceneNumber,
        town = town.name,
        error = tostring(modelErr),
      })
    end
    decodedModel = assert(decodedModel)
    local modelData = assert(decodedModel.models[1])
    local modelTextures = assert(decodedModel.embeddedTextures)
    local missing = {}
    for _, material in ipairs(modelData.materials or {}) do
      if material.textureName and modelTextures.textureByName[material.textureName] == nil then
        missing[material.textureName] = true
      end
    end
    if next(missing) then
      sourceError("opening scene town model is missing a referenced base texture", {
        scene = sceneNumber,
        town = town.name,
        textures = missing,
      })
    end
    local clips = {}
    for _, memberId in ipairs(town.clips) do
      local clipBytes = readMember(archive, memberId, "town-" .. town.name .. "-animation", sceneNumber, dependencies)
      local decoded, decodeErr = NitroAnimation.decode(clipBytes, { alias = SceneSources.ARCHIVE, memberId = memberId })
      if type(decoded) ~= "table" or type(decoded.animations) ~= "table" or #decoded.animations ~= 1 then
        sourceError("opening scene town animation has an unexpected format or entry count", {
          scene = sceneNumber,
          town = town.name,
          error = tostring(decodeErr),
        })
      end
      local clip = MapPropAnimCompiler.compileDecoded(assert(decoded), {
        name = town.name,
        id = "opening-scene-3:" .. town.name,
        source = { type = "nitro", archive = SceneSources.ARCHIVE, memberId = memberId },
      })
      clip.source = nil
      clips[#clips + 1] = clip
    end
    local model, unresolved = DynamicModelCompiler.compile(modelData, decodedModel, modelTextures, { clips = clips }, {
      role = "opening-scene-3-" .. town.name,
      modelArchive = SceneSources.ARCHIVE,
      modelMemberId = town.model,
      modelName = modelData.name,
      finalizeMeshes = true,
    }, town.model, textures, meshes)
    if #unresolved > 0 then
      sourceError("opening scene town model has unresolved material resources", {
        scene = sceneNumber,
        town = town.name,
        unresolved = unresolved,
      })
    end
    model.memberId = nil
    rewriteModelPaths(model, root)
    sanitizeModel(model, sceneNumber)
    ModelAsset.validate(model)
    models[#models + 1] = { name = town.name, index = index - 1, descriptor = model, clips = clips }
  end
  local function finalizedData(value, role)
    if type(value) == "string" then
      return value
    end
    if type(value) == "table" or type(value) == "userdata" then
      if type(value.getSize) == "function" then
        return value
      end
    end
    sourceError("opening scene town asset is not finalized binary data", { scene = sceneNumber, role = role })
  end
  for sha1, mesh in pairs(meshes) do
    files[root .. "/geometry/" .. sha1 .. ".g4mesh"] = finalizedData(mesh, "geometry")
  end
  for sha1, texture in pairs(textures) do
    files[root .. "/textures/" .. sha1 .. ".png"] = finalizedData(texture.data, "texture")
  end
  local _ = versionId
  return models
end

---@param archive table<string, unknown>
---@param versionId string
---@param sceneNumber integer
---@param root string
---@param files table<string, string>
---@param dependencies table<string, unknown>[]
---@return table<string, unknown> layers record keyed by source engine
local function compileBackgrounds(archive, versionId, sceneNumber, root, files, dependencies)
  local layers = { main = {}, sub = {} }
  local seen = {}
  for _, background in ipairs(SceneSources.backgrounds(versionId, sceneNumber)) do
    if background.engine ~= "main" and background.engine ~= "sub" then
      sourceError("opening scene background names no source engine", {
        scene = sceneNumber,
        engine = background.engine,
      })
    end
    if
      type(background.bgSlot) ~= "number"
      or background.bgSlot % 1 ~= 0
      or background.bgSlot < 0
      or background.bgSlot > 3
    then
      sourceError("opening scene background carries no numeric background slot", {
        scene = sceneNumber,
        slot = background.bgSlot,
      })
    end
    local key = background.engine .. ":" .. background.bgSlot
    if seen[key] then
      sourceError("opening scene background slot is declared twice", { scene = sceneNumber, slot = key })
    end
    seen[key] = true
    local base = background.engine .. "-bg" .. background.bgSlot
    local function renderTriple(charId, screenId, paletteId, suffix, role)
      local charData = decodeChar(
        readMember(archive, charId, role .. "-characters", sceneNumber, dependencies),
        role .. "-characters",
        sceneNumber,
        charId
      )
      local screenData = decodeScreen(
        readMember(archive, screenId, role .. "-screen", sceneNumber, dependencies),
        role .. "-screen",
        sceneNumber,
        screenId
      )
      local paletteData = decodePalette(
        readMember(archive, paletteId, role .. "-palette", sceneNumber, dependencies),
        role .. "-palette",
        sceneNumber,
        paletteId
      )
      if screenData.width < 256 or screenData.height < 192 then
        sourceError("opening scene screen map is smaller than the retail display", {
          scene = sceneNumber,
          width = screenData.width,
          height = screenData.height,
        })
      end
      local rendered = G2dRasterizer.renderScreen(charData, paletteData, screenData, {
        engine = "opening",
        scene = sceneNumber,
        layer = role,
      })
      local surface = RgbaImage.crop(rendered, { x = 0, y = 0, width = 256, height = 192 }, "opening scene " .. role)
      local path = root .. "/layers/" .. base .. suffix .. ".png"
      files[path] = PngWriter.encode(surface.width, surface.height, surface.pixels)
      return path
    end
    local image = renderTriple(background.char, background.screen, background.palette, "", base)
    local variants = {}
    for index, alternate in ipairs(type(background.alternates) == "table" and background.alternates or {}) do
      variants[index] =
        renderTriple(alternate.char, alternate.screen, background.palette, "-alt" .. index, base .. "-alt" .. index)
    end
    layers[background.engine][#layers[background.engine] + 1] = {
      bgSlot = background.bgSlot,
      priority = background.priority,
      image = image,
      variants = variants,
      width = 256,
      height = 192,
      sourceHash = Hashing.sha1hex(
        tostring(background.char) .. tostring(background.screen) .. tostring(background.palette)
      ),
    }
  end
  return layers
end

---@param archive table<string, unknown>
---@param versionId string
---@param sceneNumber integer
---@param root string
---@param files table<string, string>
---@param dependencies table<string, unknown>[]
---@return table<string, unknown>[] sprite clips
local function compileObjects(archive, versionId, sceneNumber, root, files, dependencies)
  local clips = {}
  for _, bank in ipairs(SceneSources.objects(versionId, sceneNumber)) do
    local base = bank.name
    local charData = decodeChar(
      readMember(archive, bank.char, base .. "-characters", sceneNumber, dependencies),
      base .. "-characters",
      sceneNumber,
      bank.char
    )
    local paletteData = decodePalette(
      readMember(archive, bank.palette, base .. "-palette", sceneNumber, dependencies),
      base .. "-palette",
      sceneNumber,
      bank.palette
    )
    local cellData = decodeCell(
      readMember(archive, bank.cell, base .. "-cells", sceneNumber, dependencies),
      base .. "-cells",
      sceneNumber,
      bank.cell
    )
    local animation = decodeAnimation(
      readMember(archive, bank.animation, base .. "-animation", sceneNumber, dependencies),
      base .. "-animation",
      sceneNumber,
      bank.animation
    )
    for _, clip in ipairs(compileBank(sceneNumber, bank, charData, paletteData, cellData, animation, root, files)) do
      clips[#clips + 1] = clip
    end
  end
  return clips
end

-- Event program helpers. atStepTick is the single source clock: the source
-- per-step fire tick (the retail u8 step timer the state machine thresholds
-- against) within the step that owns the event. Steps order deterministically
-- and the composition has no parallel global clock. Every effect wait names
-- a started effect from the same program or a compiled sprite clip whose
-- frame durations bound the wait; steps with unknown-length waits (circle
-- wipes, particle runs, sprite animation completion) advance the composition
-- by zero and order through the effect wait.
local function event(op, stepId, atStepTick, extra)
  local record = { op = op, stepId = stepId, atStepTick = atStepTick }
  if extra ~= nil then
    for key, value in pairs(extra) do
      record[key] = value
    end
  end
  return record
end

---@param steps table<string, unknown>[]
---@param id string
---@param eventIndices integer[]
---@param wait table<string, unknown>
local function step(steps, id, eventIndices, wait)
  steps[#steps + 1] = { id = id, events = eventIndices, ["until"] = wait }
end

---@param events table<string, unknown>[]
---@return integer next event index
local function nextIndex(events)
  return #events + 1
end

---@param clips table<string, unknown>[]
---@param name string
---@param sequence integer
---@return string clip path
local function clipPath(clips, name, sequence)
  for _, clip in ipairs(clips) do
    if clip.bank == name and clip.sequence == sequence then
      return clip.id
    end
  end
  -- The played sequences always compile above, so a missing clip is a
  -- producer inconsistency rather than source data.
  error(
    Errors.new(OpeningMovieCompiler.ERROR.SOURCE_INVALID, "opening scene timeline references a missing sprite clip", {
      bank = name,
      sequence = sequence,
    }),
    0
  )
end

---@param layers table<string, unknown> compiled engine layers
---@param engine string source engine owning the slot
---@param bgSlot integer numeric background slot
---@param variant integer|nil alternate tilemap index, nil for the base image
---@return string image path
---@return integer slot priority
local function layerImage(layers, engine, bgSlot, variant)
  local group = layers[engine]
  if type(group) ~= "table" then
    sourceError("opening scene timeline references a missing source engine", { engine = engine })
  end
  for _, layer in ipairs(group) do
    if layer.bgSlot == bgSlot then
      if variant == nil then
        return layer.image, layer.priority
      end
      local alternate = layer.variants and layer.variants[variant]
      if alternate == nil then
        sourceError("opening scene timeline references a missing alternate tilemap", {
          engine = engine,
          slot = bgSlot,
          variant = variant,
        })
      end
      ---@cast alternate string
      return alternate, layer.priority
    end
  end
  sourceError("opening scene timeline references a missing background slot", { engine = engine, slot = bgSlot })
  error("unreachable background slot", 0)
end

---@param events table<string, unknown>[]
---@param layers table<string, unknown> compiled engine layers
---@param stepId string
---@param atStepTick integer
---@param engine string source engine owning the slot
---@param bgSlot integer numeric background slot
---@param variant integer|nil alternate tilemap index, nil for the base image
local function setLayerEvent(events, layers, stepId, atStepTick, engine, bgSlot, variant)
  local image, priority = layerImage(layers, engine, bgSlot, variant)
  events[#events + 1] = event("setLayer", stepId, atStepTick, {
    engine = engine,
    bgSlot = bgSlot,
    image = image,
    visible = true,
    priority = priority,
  })
end

---@param instances table<string, unknown>[] scene sprite instance declarations
---@param sprite string source sprite name
---@return table<string, unknown> instance record
local function instanceFor(instances, sprite)
  for _, instance in ipairs(instances) do
    if instance.sprite == sprite then
      return instance
    end
  end
  sourceError("opening scene timeline references a missing sprite instance", { sprite = sprite })
  error("unreachable sprite instance", 0)
end

---@param instances table<string, unknown>[] scene sprite instance declarations
---@param instanceId string stable retail sprite object identity
---@return table<string, unknown> instance record
local function instanceById(instances, instanceId)
  for _, instance in ipairs(instances) do
    if instance.id == instanceId then
      return instance
    end
  end
  sourceError("opening scene timeline references a missing sprite instance", { sprite = instanceId })
  error("unreachable sprite instance", 0)
end

-- C integer division truncates toward zero; the retail pan task samples
-- xSpeed * counter / duration with that truncation, so the step-clock
-- replay must match it exactly (floor would drift negative speeds).
---@param speed integer retail pan speed in pixels over the whole pan
---@param tick integer one-based source frame within the pan
---@param duration integer retail pan length in source frames
---@return integer sampled displacement
local function truncStep(speed, tick, duration)
  local quotient = speed * tick / duration
  if quotient >= 0 then
    return math.floor(quotient)
  end
  return math.ceil(quotient)
end

---@param events table<string, unknown>[]
---@param instances table<string, unknown>[] scene sprite instance declarations
---@param clips table<string, unknown>[] compiled sprite clips
---@param stepId string
---@param atStepTick integer
---@param sprite string source sprite name
---@param bank string sprite bank name
---@param sequence integer played animation sequence
local function showSprite(events, instances, clips, stepId, atStepTick, sprite, bank, sequence)
  local instance = instanceFor(instances, sprite)
  local clip = clipPath(clips, bank, sequence)
  events[#events + 1] = event("setSpriteClip", stepId, atStepTick, {
    instanceId = instance.id,
    engine = instance.engine,
    x = instance.x,
    y = instance.y,
    drawOrder = instance.drawOrder,
    clipId = clip,
  })
  events[#events + 1] = event("spriteVisible", stepId, atStepTick, {
    instanceId = instance.id,
    engine = instance.engine,
    x = instance.x,
    y = instance.y,
    drawOrder = instance.drawOrder,
    visible = true,
  })
end

---@param events table<string, unknown>[]
---@param instances table<string, unknown>[] scene sprite instance declarations
---@param stepId string
---@param atStepTick integer
---@param sprite string source sprite name
---@param visible boolean whether the instance shows
local function setSpriteVisible(events, instances, stepId, atStepTick, sprite, visible)
  local instance = instanceFor(instances, sprite)
  events[#events + 1] = event("spriteVisible", stepId, atStepTick, {
    instanceId = instance.id,
    engine = instance.engine,
    x = instance.x,
    y = instance.y,
    drawOrder = instance.drawOrder,
    visible = visible,
  })
end

---@param clips table<string, unknown>[]
---@param layers table<string, unknown>
---@return table<string, unknown>[], table<string, unknown>[] steps and events
local function scene1Program(clips, layers)
  local instances = SceneSources.spriteInstances(1)
  local steps, events = {}, {}
  -- Entry polarity is a sourced retail fact: each scene Init writes
  -- gSystem.screensFlipped then calls GfGfx_SwapDisplay, so scenes 1, 4,
  -- and 5 (TRUE) open with the main engine on the physical lower screen
  -- while scenes 2 and 3 (FALSE) open with it on the upper screen.
  local copyright = { nextIndex(events) }
  events[#events + 1] = event("setScreenMapping", "copyright", 0, { mainPhysical = "lower" })
  setLayerEvent(events, layers, "copyright", 0, "sub", 1)
  copyright[#copyright + 1] = #events
  setLayerEvent(events, layers, "copyright", 0, "sub", 0)
  copyright[#copyright + 1] = #events
  setLayerEvent(events, layers, "copyright", 0, "main", 0)
  copyright[#copyright + 1] = #events
  copyright[#copyright + 1] = nextIndex(events)
  events[#events + 1] = event("waitTicks", "copyright", 0, { ticks = 30 })
  step(steps, "copyright", copyright, { kind = "duration", ticks = 30 })
  local fades = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] =
    event("setBlend", "fades", 0, { effect = "blend-copyright", ticks = 60, from = 0x20, to = 0x1F })
  events[#events + 1] =
    event("setBlend", "fades", 0, { effect = "blend-copyright", ticks = 60, from = 0x20, to = 0x1F })
  step(steps, "fades", fades, { kind = "effect", effect = "blend-copyright" })
  local setup = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("waitTicks", "setup", 0, { ticks = 20 })
  events[#events + 1] = event("enableSkip", "setup", 20)
  step(steps, "setup", setup, { kind = "duration", ticks = 20 })
  local logo = { nextIndex(events) }
  events[#events + 1] = event("waitTicks", "logo", 0, { ticks = 110 })
  step(steps, "logo", logo, { kind = "duration", ticks = 110 })
  local sunrise = {}
  setLayerEvent(events, layers, "sunrise", 0, "sub", 3)
  sunrise[#sunrise + 1] = #events
  setLayerEvent(events, layers, "sunrise", 0, "main", 1)
  sunrise[#sunrise + 1] = #events
  setLayerEvent(events, layers, "sunrise", 0, "main", 2)
  sunrise[#sunrise + 1] = #events
  setLayerEvent(events, layers, "sunrise", 0, "main", 3)
  sunrise[#sunrise + 1] = #events
  sunrise[#sunrise + 1] = nextIndex(events)
  events[#events + 1] = event("waitTicks", "sunrise", 0, { ticks = 1 })
  step(steps, "sunrise", sunrise, { kind = "duration", ticks = 1 })
  local scroll = {}
  scroll[#scroll + 1] = nextIndex(events)
  events[#events + 1] = event("setBlend", "scroll", 0, { effect = "scroll-sunrise", ticks = 80, from = 0x1E })
  scroll[#scroll + 1] = nextIndex(events)
  events[#events + 1] = event("setBlend", "scroll", 0, { effect = "scroll-sunrise", ticks = 80, from = 0x1E })
  scroll[#scroll + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "scroll",
    0,
    { engine = "main", bgSlot = 1, dx = 0, dy = -0x20, ticks = 240, direction = "up", effect = "scroll-sunrise" }
  )
  scroll[#scroll + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "scroll",
    0,
    { engine = "main", bgSlot = 2, dx = 0, dy = -0x10, ticks = 240, direction = "up", effect = "scroll-sunrise" }
  )
  showSprite(events, instances, clips, "scroll", 0, "sun", "bird", 0)
  scroll[#scroll + 1] = #events - 1
  scroll[#scroll + 1] = #events
  step(steps, "scroll", scroll, { kind = "effect", effect = "scroll-sunrise" })
  local bird = { nextIndex(events) }
  events[#events + 1] = event("waitTicks", "bird", 0, { ticks = 128 })
  showSprite(events, instances, clips, "bird", 128, "bird", "bird", 1)
  bird[#bird + 1] = #events - 1
  bird[#bird + 1] = #events
  step(steps, "bird", bird, { kind = "duration", ticks = 128 })
  local run = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("waitTicks", "run", 0, { ticks = 90 })
  events[#events + 1] = event("setFade", "run", 90, { kind = "white", ticks = 65, effect = "fade-white" })
  step(steps, "run", run, { kind = "duration", ticks = 90 })
  local fade = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("waitEffects", "fade", 0, { effects = { "fade-white" } })
  events[#events + 1] = event("finish", "fade", 0)
  step(steps, "fade", fade, { kind = "effect", effect = "fade-white" })
  return steps, events
end

-- Scene 2 retail sprite motion (src/intro_movie_scene_2.c
-- IntroMovie_Scene2_Main with Task_IntroMovie_Scene2_SpritePan): the
-- ten flowers appear fixed at (128, 192) and never pan; only the six
-- heroes pan, sampling position(tick) = start + trunc(speed * tick /
-- duration) every source frame. The first (0, +0xC0, 5) pans start at
-- flyin tick 56, so their frames land in the following wait step, which
-- retail holds until the pans, the background scrolls, and the 8-tick
-- fade all finish. Each later pan starts when its wait step advances
-- and fills exactly the next named step, whose background scrolls share
-- the same length.
---@param clips table<string, unknown>[]
---@return table<string, unknown>[], table<string, unknown>[] steps and events
local function scene2Program(clips)
  local instances = SceneSources.spriteInstances(2)
  local steps, events = {}, {}
  local function showInstance(stepId, atStepTick, instanceId, bank, sequence)
    local instance = instanceById(instances, instanceId)
    local clip = clipPath(clips, bank, sequence)
    events[#events + 1] = event("setSpriteClip", stepId, atStepTick, {
      instanceId = instance.id,
      engine = instance.engine,
      x = instance.x,
      y = instance.y,
      drawOrder = instance.drawOrder,
      clipId = clip,
    })
    events[#events + 1] = event("spriteVisible", stepId, atStepTick, {
      instanceId = instance.id,
      engine = instance.engine,
      x = instance.x,
      y = instance.y,
      drawOrder = instance.drawOrder,
      visible = true,
    })
    return #events - 1, #events
  end
  local function flowerEvents(stepId, atStepTick, flower)
    local indices = {}
    for _, suffix in ipairs({ "main", "sub" }) do
      local clipEvent, visibleEvent =
        showInstance(stepId, atStepTick, "flower" .. flower .. "-" .. suffix, "flowers", (flower - 1) % 4)
      indices[#indices + 1] = clipEvent
      indices[#indices + 1] = visibleEvent
    end
    return indices
  end
  local ethanIds = { "ethan0", "ethan1", "ethan2" }
  local lyraIds = { "lyra0", "lyra1", "lyra2" }
  -- One position update per hero per source frame of a retail pan.
  ---@param stepId string owning step
  ---@param groupIds string[] hero instance ids sharing one pan start
  ---@param xSpeed integer retail horizontal speed in pixels over the pan
  ---@param ySpeed integer retail vertical speed in pixels over the pan
  ---@param duration integer retail pan length in source frames
  ---@param startX integer retail pan start x
  ---@param startY integer retail pan start y
  ---@return integer[] event indices
  local function panPositions(stepId, groupIds, xSpeed, ySpeed, duration, startX, startY)
    local indices = {}
    for tick = 1, duration do
      local x = startX + truncStep(xSpeed, tick, duration)
      local y = startY + truncStep(ySpeed, tick, duration)
      for _, instanceId in ipairs(groupIds) do
        local instance = instanceById(instances, instanceId)
        indices[#indices + 1] = nextIndex(events)
        events[#events + 1] = event("spriteVisible", stepId, tick, {
          instanceId = instance.id,
          engine = instance.engine,
          x = x,
          y = y,
          drawOrder = instance.drawOrder,
          visible = true,
        })
      end
    end
    return indices
  end
  local flyin = { nextIndex(events) }
  events[#events + 1] = event("setScreenMapping", "flyin", 0, { mainPhysical = "upper" })
  flyin[#flyin + 1] = nextIndex(events)
  events[#events + 1] = event("setFade", "flyin", 0, { kind = "white-in", ticks = 3 })
  -- Retail creation leaves ethan and lyra drawn but unanimated, so they
  -- show at their creation stations from the first step clock tick.
  for hero = 0, 2 do
    local clipIndex, visibleIndex = showInstance("flyin", 0, "ethan" .. hero, "characters", hero)
    flyin[#flyin + 1] = clipIndex
    flyin[#flyin + 1] = visibleIndex
    clipIndex, visibleIndex = showInstance("flyin", 0, "lyra" .. hero, "characters", 3 + hero)
    flyin[#flyin + 1] = clipIndex
    flyin[#flyin + 1] = visibleIndex
  end
  local flowerAt = { 1, 8, 16, 24, 28, 32, 34, 38, 42, 48 }
  for flower = 1, 10 do
    for _, index in ipairs(flowerEvents("flyin", flowerAt[flower], flower)) do
      flyin[#flyin + 1] = index
    end
  end
  flyin[#flyin + 1] = nextIndex(events)
  events[#events + 1] =
    event("setScroll", "flyin", 56, { engine = "main", bgSlot = 1, dx = 0, dy = -0xC0, ticks = 5, direction = "down" })
  flyin[#flyin + 1] = nextIndex(events)
  events[#events + 1] =
    event("setScroll", "flyin", 56, { engine = "main", bgSlot = 0, dx = 0, dy = -0xC0, ticks = 5, direction = "down" })
  flyin[#flyin + 1] = nextIndex(events)
  events[#events + 1] = event("setFade", "flyin", 56, { kind = "black-out", ticks = 8 })
  step(steps, "flyin", flyin, { kind = "duration", ticks = 56 })
  local settle = { nextIndex(events) }
  events[#events + 1] = event("waitTicks", "settle-flyin", 0, { ticks = 8 })
  for _, index in ipairs(panPositions("settle-flyin", ethanIds, 0, 0xC0, 5, 64, -96)) do
    settle[#settle + 1] = index
  end
  for _, index in ipairs(panPositions("settle-flyin", lyraIds, 0, 0xC0, 5, 320, -96)) do
    settle[#settle + 1] = index
  end
  step(steps, "settle-flyin", settle, { kind = "duration", ticks = 8 })
  ---@param id string step identifier owning the pan
  ---@param dx integer retail horizontal scroll delta in pixels
  ---@param dy integer retail vertical scroll delta in pixels
  ---@param ticks integer retail pan length in source frames
  ---@param startEthan integer[] retail pan start x/y for the ethan instances
  ---@param startLyra integer[] retail pan start x/y for the lyra instances
  local function panStep(id, dx, dy, ticks, startEthan, startLyra)
    -- Pan steps follow step order; the hero pan motion they start is the
    -- effect the step completes on, with no separate entry effect.
    -- Flowers never pan, so only background slots scroll here. Retail
    -- pans the heroes against the background scroll direction, so the
    -- sprite speeds negate the scrolled deltas.
    local indices = {}
    for _, slot in ipairs({ 1, 0 }) do
      indices[#indices + 1] = nextIndex(events)
      events[#events + 1] = event(
        "setScroll",
        id,
        0,
        { engine = "main", bgSlot = slot, dx = dx, dy = dy, ticks = ticks, direction = "pan", effect = "scroll-" .. id }
      )
    end
    for _, position in ipairs(panPositions(id, ethanIds, -dx, -dy, ticks, startEthan[1], startEthan[2])) do
      indices[#indices + 1] = position
    end
    for _, position in ipairs(panPositions(id, lyraIds, -dx, -dy, ticks, startLyra[1], startLyra[2])) do
      indices[#indices + 1] = position
    end
    step(steps, id, indices, { kind = "effect", effect = "scroll-" .. id })
  end
  panStep("slow-pan-ethan", 0x20, 0, 90, { 64, 96 }, { 320, 96 })
  panStep("fast-pan-lyra", 0x40, 0, 7, { 32, 96 }, { 288, 96 })
  panStep("slow-pan-lyra", 0x20, 0, 66, { -32, 96 }, { 224, 96 })
  local exit = {}
  exit[#exit + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "lyra-exit",
    0,
    { engine = "main", bgSlot = 1, dx = 0, dy = -0x80, ticks = 10, direction = "up", effect = "scroll-lyra-exit" }
  )
  exit[#exit + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "lyra-exit",
    0,
    { engine = "main", bgSlot = 0, dx = 0, dy = -0x40, ticks = 5, direction = "up", effect = "scroll-lyra-exit" }
  )
  for _, position in ipairs(panPositions("lyra-exit", ethanIds, 0, 0x80, 10, -64, 96)) do
    exit[#exit + 1] = position
  end
  for _, position in ipairs(panPositions("lyra-exit", lyraIds, 0, 0x80, 10, 192, 96)) do
    exit[#exit + 1] = position
  end
  step(steps, "lyra-exit", exit, { kind = "effect", effect = "scroll-lyra-exit" })
  local wipe = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("waitEffects", "wipe", 0, { effects = { "scroll-lyra-exit" } })
  events[#events + 1] = event("circleWipe", "wipe", 0, { mode = "out", effect = "wipe-circle" })
  step(steps, "wipe", wipe, { kind = "effect", effect = "wipe-circle" })
  local done = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("waitEffects", "done", 0, { effects = { "wipe-circle" } })
  events[#events + 1] = event("finish", "done", 0)
  step(steps, "done", done, { kind = "effect", effect = "wipe-circle" })
  return steps, events
end

---@param clips table<string, unknown>[]
---@param layers table<string, unknown> compiled engine layers
---@return table<string, unknown>[], table<string, unknown>[] steps and events
local function scene3Program(clips, layers)
  local instances = SceneSources.spriteInstances(3)
  local steps, events = {}, {}
  -- Phase panel table: which compiled tilemap image each rival/beast phase
  -- shows, as (engine, slot, alternate) into the compiled slot images.
  local panels = {
    ["rival-section-1"] = { engine = "sub", bgSlot = 0, variant = 1 },
    ["rival-section-2"] = { engine = "sub", bgSlot = 0, variant = 2 },
    ["rival-section-3"] = { engine = "sub", bgSlot = 0, variant = 3 },
    ["rival-whole"] = { engine = "sub", bgSlot = 0, variant = 4 },
    ["beast0"] = { engine = "sub", bgSlot = 1, variant = 1 },
    ["beast1"] = { engine = "sub", bgSlot = 2, variant = 1 },
    ["beast2"] = { engine = "sub", bgSlot = 3, variant = 1 },
  }
  local function showPanel(stepId, atStepTick, phase)
    local slot = assert(panels[phase], "opening scene 3 phase names its panel: " .. tostring(phase))
    setLayerEvent(events, layers, stepId, atStepTick, slot.engine, slot.bgSlot, slot.variant)
    return #events
  end
  local towns = { "new-bark-town", "goldenrod-city", "ecruteak-city" }
  -- Source hold thresholds (stepTimer > threshold fires at threshold + 1).
  local holds = { 40, 46, 98 }
  local firstShow = { nextIndex(events) }
  events[#events + 1] = event("setScreenMapping", "show-new-bark-town", 0, { mainPhysical = "upper" })
  -- Retail animates the silver silhouette from scene setup until the
  -- rival panels finish, so it shows at the first town beat and hides
  -- at the panels beat below.
  showSprite(events, instances, clips, "show-new-bark-town", 0, "silver-silhouette", "silver", 0)
  local silhouetteClip, silhouetteVisible = #events - 1, #events
  for town = 1, 3 do
    local show = {}
    if town == 1 then
      show[#show + 1] = firstShow[1]
      show[#show + 1] = silhouetteClip
      show[#show + 1] = silhouetteVisible
    end
    show[#show + 1] = nextIndex(events)
    events[#events + 1] = event("setModelClip", "show-" .. towns[town], 0, { model = towns[town], clip = "joint" })
    show[#show + 1] = nextIndex(events)
    events[#events + 1] =
      event("setCamera", "show-" .. towns[town], 0, { distance = 410.922119140625, angle = "sCameraParam" })
    show[#show + 1] = nextIndex(events)
    events[#events + 1] = event("setLighting", "show-" .. towns[town], 0, { map = town - 1, town = towns[town] })
    show[#show + 1] = nextIndex(events)
    events[#events + 1] = event("circleWipe", "show-" .. towns[town], 0, { mode = "in", effect = "wipe-circle" })
    show[#show + 1] = nextIndex(events)
    events[#events + 1] = event("waitTicks", "show-" .. towns[town], holds[town] + 1, { ticks = holds[town] })
    step(steps, "show-" .. towns[town], show, { kind = "duration", ticks = holds[town] + 1 })
  end
  local rival = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("waitEffects", "rival", 0, { effects = { "wipe-circle" } })
  events[#events + 1] = event("circleWipe", "rival", 0, { mode = "out", effect = "wipe-circle" })
  step(steps, "rival", rival, { kind = "effect", effect = "wipe-circle" })
  local panelsStep = { nextIndex(events) }
  events[#events + 1] = event("waitEffects", "panels", 0, { effects = { "wipe-circle" } })
  for index, delay in ipairs({ 56, 73, 92 }) do
    panelsStep[#panelsStep + 1] = showPanel("panels", delay, "rival-section-" .. index)
  end
  panelsStep[#panelsStep + 1] = nextIndex(events)
  local silhouette = instanceFor(instances, "silver-silhouette")
  events[#events + 1] = event("spriteVisible", "panels", 92, {
    instanceId = silhouette.id,
    engine = silhouette.engine,
    x = silhouette.x,
    y = silhouette.y,
    drawOrder = silhouette.drawOrder,
    visible = false,
  })
  step(steps, "panels", panelsStep, { kind = "duration", ticks = 92 })
  local borders = { nextIndex(events) }
  events[#events + 1] = event("waitTicks", "borders", 0, { ticks = 10 })
  borders[#borders + 1] = showPanel("borders", 10, "rival-whole")
  step(steps, "borders", borders, { kind = "duration", ticks = 10 })
  local aspect = { nextIndex(events) }
  events[#events + 1] = event("window", "aspect", 5, { target = "lower", kind = "narrow-y", effect = "window-aspect" })
  step(steps, "aspect", aspect, { kind = "duration", ticks = 5 })
  local narrow = { nextIndex(events) }
  events[#events + 1] = event("waitEffects", "narrow", 0, { effects = { "window-aspect" } })
  step(steps, "narrow", narrow, { kind = "effect", effect = "window-aspect" })
  local sprites = {}
  showSprite(events, instances, clips, "sprites", 56, "eusine", "eusine", 0)
  sprites[#sprites + 1] = #events - 1
  sprites[#sprites + 1] = #events
  showSprite(events, instances, clips, "sprites", 145, "unown0", "eusine", 1)
  sprites[#sprites + 1] = #events - 1
  sprites[#sprites + 1] = #events
  sprites[#sprites + 1] = nextIndex(events)
  events[#events + 1] = event("window", "sprites", 145, { target = "lower", kind = "slide-left" })
  sprites[#sprites + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "sprites",
    145,
    { engine = "sub", bgSlot = 1, dx = -116, dy = 0, ticks = 10, direction = "left", effect = "scroll-sub1" }
  )
  step(steps, "sprites", sprites, { kind = "duration", ticks = 145 })
  local entei = { nextIndex(events) }
  events[#events + 1] = event("waitEffects", "entei-exit", 0, { effects = { "scroll-sub1" } })
  step(steps, "entei-exit", entei, { kind = "effect", effect = "scroll-sub1" })
  local raikou = {}
  showSprite(events, instances, clips, "raikou", 0, "unown1", "eusine", 2)
  raikou[#raikou + 1] = #events - 1
  raikou[#raikou + 1] = #events
  raikou[#raikou + 1] = nextIndex(events)
  events[#events + 1] = event("window", "raikou", 10, { target = "lower", kind = "slide-left" })
  raikou[#raikou + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "raikou",
    10,
    { engine = "sub", bgSlot = 2, dx = -116, dy = 0, ticks = 10, direction = "left", effect = "scroll-sub2" }
  )
  step(steps, "raikou", raikou, { kind = "duration", ticks = 10 })
  local rockets = { nextIndex(events) }
  events[#events + 1] = event("waitEffects", "rockets", 0, { effects = { "scroll-sub1", "scroll-sub2" } })
  for _, beast in ipairs({ "beast0", "beast1", "beast2" }) do
    rockets[#rockets + 1] = showPanel("rockets", 0, beast)
  end
  -- The beast panels show as a zero-duration transition beat once the
  -- panel slides have finished; the beat completes on the latest slide.
  step(steps, "rockets", rockets, { kind = "effect", effect = "scroll-sub2" })
  local suicune = {}
  showSprite(events, instances, clips, "suicune", 0, "unown2", "eusine", 3)
  suicune[#suicune + 1] = #events - 1
  suicune[#suicune + 1] = #events
  suicune[#suicune + 1] = nextIndex(events)
  events[#events + 1] = event("window", "suicune", 30, { target = "lower", kind = "slide-right" })
  suicune[#suicune + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "suicune",
    30,
    { engine = "sub", bgSlot = 0, dx = 0x74, dy = 0, ticks = 10, direction = "right", effect = "scroll-sub0" }
  )
  step(steps, "suicune", suicune, { kind = "duration", ticks = 30 })
  local viewport = { nextIndex(events), nextIndex(events) + 1, nextIndex(events) + 2, nextIndex(events) + 3 }
  events[#events + 1] = event("waitEffects", "viewport", 0, { effects = { "scroll-sub0" } })
  events[#events + 1] = event("window", "viewport", 0, { target = "lower", kind = "expand" })
  events[#events + 1] =
    event("setScroll", "viewport", 0, { engine = "sub", bgSlot = 1, dx = 0, dy = -0x30, ticks = 254, direction = "up" })
  events[#events + 1] =
    event("setScroll", "viewport", 0, { engine = "sub", bgSlot = 2, dx = 0, dy = -0x20, ticks = 254, direction = "up" })
  -- The viewport hold completes when the tail scroll started by the next
  -- step finishes; effect starts may complete in a later step.
  step(steps, "viewport", viewport, { kind = "effect", effect = "scroll-sub3" })
  local viewportTail = { nextIndex(events) }
  events[#events + 1] = event(
    "setScroll",
    "viewport-tail",
    0,
    { engine = "sub", bgSlot = 3, dx = 0, dy = -0x08, ticks = 254, direction = "up", effect = "scroll-sub3" }
  )
  step(steps, "viewport-tail", viewportTail, { kind = "effect", effect = "scroll-sub3" })
  local admins = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("waitEffects", "admins", 0, { effects = { "scroll-sub1" } })
  events[#events + 1] = event("finish", "admins", 0)
  step(steps, "admins", admins, { kind = "effect", effect = "scroll-sub1" })
  return steps, events
end

---@param clips table<string, unknown>[]
---@return table<string, unknown>[], table<string, unknown>[] steps and events
local function scene4Program(clips)
  local instances = SceneSources.spriteInstances(4)
  local steps, events = {}, {}
  local fadeIn = { nextIndex(events) }
  events[#events + 1] = event("setScreenMapping", "fade-in", 0, { mainPhysical = "lower" })
  fadeIn[#fadeIn + 1] = nextIndex(events)
  events[#events + 1] = event("setFade", "fade-in", 0, { kind = "black-shutter-open", ticks = 10, effect = "fade-in" })
  step(steps, "fade-in", fadeIn, { kind = "effect", effect = "fade-in" })
  local slideIn = {}
  slideIn[#slideIn + 1] = nextIndex(events)
  events[#events + 1] = event("waitEffects", "slide-in", 0, { effects = { "fade-in" } })
  slideIn[#slideIn + 1] = nextIndex(events)
  events[#events + 1] = event("window", "slide-in", 0, { target = "upper", kind = "widen-left" })
  slideIn[#slideIn + 1] = nextIndex(events)
  events[#events + 1] = event("window", "slide-in", 0, { target = "lower", kind = "widen-right" })
  slideIn[#slideIn + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "slide-in",
    0,
    { engine = "sub", bgSlot = 1, dx = 0xC0, dy = 0, ticks = 10, direction = "right", effect = "scroll-slide-in" }
  )
  slideIn[#slideIn + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "slide-in",
    0,
    { engine = "main", bgSlot = 1, dx = -0xC0, dy = 0, ticks = 10, direction = "left", effect = "scroll-slide-in" }
  )
  showSprite(events, instances, clips, "slide-in", 0, "hand1", "hands", 0)
  slideIn[#slideIn + 1] = #events - 1
  slideIn[#slideIn + 1] = #events
  showSprite(events, instances, clips, "slide-in", 0, "hand2", "hands", 1)
  slideIn[#slideIn + 1] = #events - 1
  slideIn[#slideIn + 1] = #events
  step(steps, "slide-in", slideIn, { kind = "effect", effect = "scroll-slide-in" })
  local hold = { nextIndex(events) }
  events[#events + 1] = event("waitTicks", "hold", 26, { ticks = 25 })
  step(steps, "hold", hold, { kind = "duration", ticks = 26 })
  local slideOut = {}
  slideOut[#slideOut + 1] = nextIndex(events)
  events[#events + 1] = event("window", "slide-out", 0, { target = "upper", kind = "narrow-right" })
  slideOut[#slideOut + 1] = nextIndex(events)
  events[#events + 1] = event("window", "slide-out", 0, { target = "lower", kind = "narrow-left" })
  slideOut[#slideOut + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "slide-out",
    0,
    { engine = "sub", bgSlot = 1, dx = 0xC0, dy = 0, ticks = 10, direction = "right", effect = "scroll-slide-out" }
  )
  slideOut[#slideOut + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "slide-out",
    0,
    { engine = "main", bgSlot = 1, dx = -0xC0, dy = 0, ticks = 10, direction = "left", effect = "scroll-slide-out" }
  )
  step(steps, "slide-out", slideOut, { kind = "effect", effect = "scroll-slide-out" })
  local hide = {}
  setSpriteVisible(events, instances, "hide-hands", 0, "hand1", false)
  hide[#hide + 1] = #events
  setSpriteVisible(events, instances, "hide-hands", 0, "hand2", false)
  hide[#hide + 1] = #events
  step(steps, "hide-hands", hide, { kind = "effect", effect = "scroll-slide-out" })
  local starters = { "chikorita", "cyndaquil", "totodile" }
  local groups = { "grass", "fire", "water" }
  local emitterIds = { { 6, 7, 8 }, { 3, 4, 5 }, { 0, 1, 2 } }
  local banks = { "chikorita", "cyndaquil", "totodile" }
  for round = 1, 3 do
    local show = {}
    showSprite(events, instances, clips, "starter-" .. starters[round], 0, starters[round], banks[round], 0)
    show[#show + 1] = #events - 1
    show[#show + 1] = #events
    show[#show + 1] = nextIndex(events)
    events[#events + 1] =
      event("startEmitters", "starter-" .. starters[round], 0, { group = groups[round], emitters = emitterIds[round] })
    step(steps, "starter-" .. starters[round], show, { kind = "effect", effect = "emitters-" .. groups[round] })
    if round < 3 then
      local flip = { nextIndex(events) }
      events[#events + 1] = event(
        "setScreenMapping",
        "flip-" .. starters[round],
        0,
        round == 1 and { mainPhysical = "lower" } or { mainPhysical = "upper" }
      )
      step(steps, "flip-" .. starters[round], flip, { kind = "effect", effect = "emitters-" .. groups[round] })
    end
  end
  local finishTotodile = { nextIndex(events) }
  events[#events + 1] =
    event("setFade", "finish-totodile", 0, { kind = "black-shutter-close", ticks = 26, effect = "fade-close" })
  step(steps, "finish-totodile", finishTotodile, { kind = "effect", effect = "fade-close" })
  -- The closing sparkle waits on its own compiled clip: the animation's
  -- frame durations bound the wait, with no separate named effect.
  local sparkleClip = clipPath(clips, "hands", 2)
  local sparkle = {}
  showSprite(events, instances, clips, "sparkle", 0, "sparkles", "hands", 2)
  sparkle[#sparkle + 1] = #events - 1
  sparkle[#sparkle + 1] = #events
  step(steps, "sparkle", sparkle, { kind = "effect", effect = sparkleClip })
  local done = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("waitEffects", "done", 0, { effects = { sparkleClip } })
  events[#events + 1] = event("finish", "done", 0)
  step(steps, "done", done, { kind = "effect", effect = sparkleClip })
  return steps, events
end

---@param versionId string
---@return table<string, unknown>[], table<string, unknown>[] steps and events
local function scene5Program(versionId)
  local direction = SceneSources.scene5ScrollDirection(versionId)
  local steps, events = {}, {}
  local wipe = { nextIndex(events) }
  events[#events + 1] = event("setScreenMapping", "wipe", 0, { mainPhysical = "lower" })
  wipe[#wipe + 1] = nextIndex(events)
  events[#events + 1] = event("circleWipe", "wipe", 0, { mode = "in", ticks = 18, effect = "wipe-in" })
  step(steps, "wipe", wipe, { kind = "duration", ticks = 18 })
  local scroll = {}
  scroll[#scroll + 1] = nextIndex(events)
  events[#events + 1] = event("waitEffects", "scroll", 0, { effects = { "wipe-in" } })
  scroll[#scroll + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "scroll",
    0,
    { engine = "main", bgSlot = 1, dx = 0, dy = -0x40, ticks = 73, direction = "up", effect = "scroll-panorama" }
  )
  local paired = { { engine = "main", bgSlot = 2 }, { engine = "sub", bgSlot = 1 }, { engine = "sub", bgSlot = 2 } }
  for _, slot in ipairs(paired) do
    scroll[#scroll + 1] = nextIndex(events)
    events[#events + 1] = event("setScroll", "scroll", 0, {
      engine = slot.engine,
      bgSlot = slot.bgSlot,
      dx = 0,
      dy = direction == "left" and -0x40 or 0x40,
      ticks = 73,
      direction = direction,
      effect = "scroll-panorama",
    })
  end
  step(steps, "scroll", scroll, { kind = "effect", effect = "scroll-panorama" })
  local wait = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("waitTicks", "wait", 0, { ticks = 20 })
  events[#events + 1] = event("setFade", "wait", 20, { kind = "white", ticks = 50, effect = "fade-white" })
  step(steps, "wait", wait, { kind = "duration", ticks = 20 })
  local fade = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("waitEffects", "fade", 0, { effects = { "fade-white" } })
  events[#events + 1] = event("finish", "fade", 0)
  step(steps, "fade", fade, { kind = "effect", effect = "fade-white" })
  return steps, events
end

---@param romFs table<string, unknown> verified source reader
---@param versionId string
---@param sceneNumber integer
---@return table<string, unknown>|nil bundle
---@return Errors.Error|string|nil failure
function OpeningMovieCompiler.compile(romFs, versionId, sceneNumber)
  assert(romFs and type(romFs.openNarc) == "function", "opening movie compilation requires a ROM filesystem")
  local editions = { heartgold = true, soulsilver = true }
  if not editions[versionId] then
    return nil,
      Errors.new(
        OpeningMovieCompiler.ERROR.SOURCE_INVALID,
        "opening movie edition is unsupported",
        { versionId = versionId }
      )
  end
  if type(sceneNumber) ~= "number" or sceneNumber % 1 ~= 0 or sceneNumber < 1 or sceneNumber > 5 then
    return nil,
      Errors.new(
        OpeningMovieCompiler.ERROR.SOURCE_INVALID,
        "opening movie scene number must be an integer 1..5",
        { sceneNumber = sceneNumber }
      )
  end
  if romFs:version() ~= versionId then
    return nil,
      Errors.new(
        OpeningMovieCompiler.ERROR.SOURCE_INVALID,
        "opening movie edition does not match the source reader",
        { versionId = versionId, readerVersion = romFs:version() }
      )
  end
  local ok, bundle = pcall(function()
    return OpeningMovieCompiler.compileScene(romFs, versionId, sceneNumber)
  end)
  if not ok then
    if Errors.is(bundle) then
      return nil, bundle
    end
    error(bundle, 0)
  end
  return bundle
end

---@param romFs table<string, unknown>
---@param versionId string
---@param sceneNumber integer
---@return table<string, unknown> bundle
function OpeningMovieCompiler.compileScene(romFs, versionId, sceneNumber)
  local archive, archiveErr = romFs:openNarc(SceneSources.ARCHIVE)
  if archive == nil then
    sourceError("opening movie source archive is unavailable", {
      scene = sceneNumber,
      error = tostring(archiveErr),
    })
  end
  assert(type(archive) == "table", "unreachable: source archive failure always raises")
  local root = "assets/generated/startup/opening/" .. tostring(sceneNumber)
  local dependencies = {}
  local files = {}
  local layers = compileBackgrounds(archive, versionId, sceneNumber, root, files, dependencies)
  local clips = compileObjects(archive, versionId, sceneNumber, root, files, dependencies)
  local models = {}
  local camera, lighting = nil, nil
  if sceneNumber == 3 then
    models = compileTowns(archive, versionId, sceneNumber, root, files, dependencies)
    local towns = SceneSources.townSet()
    camera = towns.camera
    lighting = { edgeColors = towns.edgeColors, towns = towns.lighting }
  end
  local particles = { seed = 0, emitters = {} }
  if sceneNumber == 4 then
    local particleArchive, particleErr = romFs:openNarc(SceneSources.PARTICLE_ARCHIVE)
    if particleArchive == nil then
      sourceError("opening scene 4 particle archive is unavailable", {
        scene = sceneNumber,
        error = tostring(particleErr),
      })
    end
    assert(type(particleArchive) == "table", "unreachable: particle archive failure always raises")
    local memberBytes =
      readMember(particleArchive, SceneSources.PARTICLE_MEMBER, "starter-particle-resource", sceneNumber, dependencies)
    local compiled, particleCompileErr = OpeningParticleCompiler.compile(memberBytes, root)
    if compiled == nil then
      sourceError("opening scene 4 particle member could not be compiled", {
        scene = sceneNumber,
        error = tostring(particleCompileErr),
      })
    end
    local particleBundle = assert(compiled, "opening scene 4 particle bundle is unavailable")
    particles = particleBundle.particles
    for path, bytes in pairs(particleBundle.files) do
      files[path] = bytes
    end
    dependencies[#dependencies + 1] = {
      role = "starter-particles",
      member = SceneSources.PARTICLE_MEMBER,
      sha1 = particleBundle.dependencies.particleMemberHash,
    }
  end
  local steps, events
  if sceneNumber == 1 then
    steps, events = scene1Program(clips, layers)
  elseif sceneNumber == 2 then
    steps, events = scene2Program(clips)
  elseif sceneNumber == 3 then
    steps, events = scene3Program(clips, layers)
  elseif sceneNumber == 4 then
    steps, events = scene4Program(clips)
  else
    steps, events = scene5Program(versionId)
  end
  local manifest = {
    schema = SceneSources.SCHEMA,
    versionId = versionId,
    sceneNumber = sceneNumber,
    sourceTickRate = SceneSources.TICK_RATE,
    layers = layers,
    spriteClips = clips,
    models = models,
    particles = particles,
    timeline = { steps = steps, events = events },
    assets = {},
  }
  if camera ~= nil then
    manifest.camera = camera
  end
  if lighting ~= nil then
    manifest.lighting = lighting
  end
  for path in pairs(files) do
    manifest.assets[path] = true
  end
  local romMetadata = assert(romFs:metadata())
  dependencies.versionId = versionId
  dependencies.romSha1 = assert(romMetadata.sha1)
  return {
    manifest = manifest,
    files = files,
    dependencies = dependencies,
    sourceHash = Hashing.hashLua(dependencies),
  }
end

return OpeningMovieCompiler
