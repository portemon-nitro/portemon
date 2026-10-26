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
      local path = root .. "/layers/" .. base .. suffix .. ".png"
      files[path] = PngWriter.encode(rendered.width, rendered.height, rendered.pixels)
      return path, rendered.width, rendered.height
    end
    local image, width, height = renderTriple(background.char, background.screen, background.palette, "", base)
    local variants = {}
    for index, alternate in ipairs(type(background.alternates) == "table" and background.alternates or {}) do
      local altImage, altWidth, altHeight =
        renderTriple(alternate.char, alternate.screen, background.palette, "-alt" .. index, base .. "-alt" .. index)
      variants[index] = { image = altImage, width = altWidth, height = altHeight }
    end
    layers[background.engine][#layers[background.engine] + 1] = {
      bgSlot = background.bgSlot,
      priority = background.priority,
      image = image,
      variants = variants,
      width = width,
      height = height,
      sourceHash = Hashing.sha1hex(
        tostring(background.char) .. tostring(background.screen) .. tostring(background.palette)
      ),
      initialVisible = SceneSources.initialVisible(sceneNumber, background.engine, background.bgSlot),
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
-- wipes, particle runs, sprite animation completion) hold on their guard
-- until the named effect finishes and order through step sequence.
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
---@param onComplete integer[]|nil guarded actions firing when the wait passes
local function step(steps, id, eventIndices, wait, onComplete)
  local record = { id = id, events = eventIndices, ["until"] = wait }
  if onComplete ~= nil then
    record.onCompleteEvents = onComplete
  end
  steps[#steps + 1] = record
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
      if type(alternate) ~= "table" or type(alternate.image) ~= "string" then
        sourceError("opening scene timeline references a missing alternate tilemap", {
          engine = engine,
          slot = bgSlot,
          variant = variant,
        })
      end
      ---@cast alternate { image: string }
      return alternate.image, layer.priority
    end
  end
  sourceError("opening scene timeline references a missing background slot", { engine = engine, slot = bgSlot })
  error("unreachable background slot", 0)
end

-- Source renderer surface origins per scene: the retail
-- IntroMovie_RendererSetSurfaceCoords(mainx, mainy, subx, suby) call runs
-- (0,0,0,0) on scene 1 (no call; main-only sprites), (0,0,0,192) on
-- scene 2, (0,0,0,512) on scene 3, and (0,0,0,256) on scenes 4 and 5.
-- Every emitted sprite station subtracts its owning engine origin once so
-- the manifest carries 256x192 engine-local coordinates.
local SOURCE_SUB_ORIGIN_Y = { [1] = 0, [2] = 192, [3] = 512, [4] = 256, [5] = 256 }

---@param sceneNumber integer owning scene
---@param engine string source engine owning the sprite
---@param x number raw shared-renderer coordinate
---@param y number raw shared-renderer coordinate
---@return number engine-local x
---@return number engine-local y
local function sourceLocalPosition(sceneNumber, engine, x, y)
  if engine == "sub" then
    return x, y - assert(SOURCE_SUB_ORIGIN_Y[sceneNumber])
  end
  return x, y
end

-- Compiler-local per-slot snapshot: toggling a plane off and on preserves
-- the most recently staged tilemap instead of resetting the slot to its
-- base image, and panel swaps preserve the current enable state instead
-- of forcing the plane on.
---@param layers table<string, unknown> compiled engine layers
---@return table<string, table<integer, { image: string, priority: integer, visible: boolean }>> snapshot
local function snapshotPlanes(layers)
  local planes = {}
  for _, engine in ipairs({ "main", "sub" }) do
    planes[engine] = {}
    for _, layer in ipairs(layers[engine]) do
      planes[engine][layer.bgSlot] = { image = layer.image, priority = layer.priority, visible = layer.initialVisible }
    end
  end
  return planes
end

-- Complete plane state replacement for a slot. A variant swap stages new
-- art while preserving the current enable state; a nil variant keeps the
-- staged image while replacing the enable state.
---@param events table<string, unknown>[]
---@param planes table<string, table<integer, { image: string, priority: integer, visible: boolean }>> snapshot
---@param layers table<string, unknown> compiled engine layers
---@param stepId string
---@param atStepTick integer
---@param engine string source engine owning the slot
---@param bgSlot integer numeric background slot
---@param variant integer|nil alternate tilemap index, nil to keep the staged image
---@param visible boolean|nil plane enable state, nil to preserve the current state
local function setLayerEvent(events, planes, layers, stepId, atStepTick, engine, bgSlot, variant, visible)
  local slot = planes[engine] and planes[engine][bgSlot]
  if slot == nil then
    sourceError("opening scene layer change names a missing background slot", { engine = engine, slot = bgSlot })
  end
  assert(slot ~= nil, "unreachable: missing plane change always raises")
  if variant ~= nil then
    local image, priority = layerImage(layers, engine, bgSlot, variant)
    slot.image, slot.priority = image, priority
  end
  if visible ~= nil then
    slot.visible = visible
  end
  events[#events + 1] = event("setLayer", stepId, atStepTick, {
    engine = engine,
    bgSlot = bgSlot,
    image = slot.image,
    visible = slot.visible,
    priority = slot.priority,
  })
end

-- Complete plane state replacement for a slot that keeps its staged image.
---@param events table<string, unknown>[]
---@param planes table<string, table<integer, { image: string, priority: integer, visible: boolean }>> snapshot
---@param layers table<string, unknown> compiled engine layers
---@param stepId string
---@param atStepTick integer
---@param engine string source engine owning the slot
---@param bgSlot integer numeric background slot
---@param visible boolean plane enable state
local function setPlaneVisible(events, planes, layers, stepId, atStepTick, engine, bgSlot, visible)
  setLayerEvent(events, planes, layers, stepId, atStepTick, engine, bgSlot, nil, visible)
end

-- Source window pan lookup: the declared retail pan rows per scene.
---@param sceneNumber integer owning scene
---@param id string stable source pan identity
---@return table<string, unknown> pan declaration
local function windowPan(sceneNumber, id)
  for _, pan in ipairs(SceneSources.windowPans(sceneNumber)) do
    if pan.id == id then
      return pan
    end
  end
  sourceError("opening scene timeline references a missing window pan", { scene = sceneNumber, pan = id })
  error("unreachable window pan", 0)
end

---@param value unknown pan coordinate or mask
---@return integer validated source pixel or mask value
local function windowNumber(value)
  if type(value) ~= "number" or value % 1 ~= 0 then
    sourceError("opening scene window pan carries a non-integer coordinate", { value = value })
  end
  return value
end

-- Engine-local v3 window record from one declared source pan. whichScreen
-- 0 writes the sub-engine registers, nonzero the main-engine registers.
---@param events table<string, unknown>[]
---@param sceneNumber integer owning scene
---@param panId string stable source pan identity
---@param stepId string
---@param atStepTick integer
---@param effect string|nil waitable effect started when the duration is positive
local function emitWindow(events, sceneNumber, panId, stepId, atStepTick, effect)
  local pan = windowPan(sceneNumber, panId)
  local engine = pan.whichScreen == 0 and "sub" or "main"
  local duration = windowNumber(pan.duration)
  if effect ~= nil and duration <= 0 then
    sourceError("opening scene zero-duration window starts no effect", { pan = panId })
  end
  local record = {
    engine = engine,
    from = {
      x1 = windowNumber(pan.x1Start),
      y1 = windowNumber(pan.y1Start),
      x2 = windowNumber(pan.x2Start),
      y2 = windowNumber(pan.y2Start),
    },
    to = {
      x1 = windowNumber(pan.x1End),
      y1 = windowNumber(pan.y1End),
      x2 = windowNumber(pan.x2End),
      y2 = windowNumber(pan.y2End),
    },
    ticks = duration,
    insideMask = windowNumber(pan.winIn),
    outsideMask = windowNumber(pan.winOut),
  }
  if effect ~= nil then
    record.effect = effect
  end
  events[#events + 1] = event("window", stepId, atStepTick, record)
end

-- Direct G2/G2S WIN1 register override: immediate rect and inside mask.
---@param events table<string, unknown>[]
---@param stepId string
---@param atStepTick integer
---@param engine string source engine owning the window
---@param rect integer[] { x1, y1, x2, y2 } source pixel rectangle
---@param insideMask integer WIN1 inside plane mask
local function setWindowSecondary(events, stepId, atStepTick, engine, rect, insideMask)
  events[#events + 1] = event("setWindowSecondary", stepId, atStepTick, {
    engine = engine,
    rect = { x1 = rect[1], y1 = rect[2], x2 = rect[3], y2 = rect[4] },
    insideMask = insideMask,
  })
end

-- Whole engine-window enable switch; retains positions and masks for later.
---@param events table<string, unknown>[]
---@param stepId string
---@param atStepTick integer
---@param engine string source engine owning the window
---@param visible boolean window enable state
local function setWindowVisible(events, stepId, atStepTick, engine, visible)
  events[#events + 1] = event("setWindowVisible", stepId, atStepTick, { engine = engine, visible = visible })
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
---@param sceneNumber integer owning scene
---@param instances table<string, unknown>[] scene sprite instance declarations
---@param clips table<string, unknown>[] compiled sprite clips
---@param stepId string
---@param atStepTick integer
---@param sprite string source sprite name
---@param bank string sprite bank name
---@param sequence integer played animation sequence
local function showSprite(events, sceneNumber, instances, clips, stepId, atStepTick, sprite, bank, sequence)
  local instance = instanceFor(instances, sprite)
  local clip = clipPath(clips, bank, sequence)
  local x, y = sourceLocalPosition(sceneNumber, instance.engine, instance.x, instance.y)
  events[#events + 1] = event("setSpriteClip", stepId, atStepTick, {
    instanceId = instance.id,
    engine = instance.engine,
    x = x,
    y = y,
    drawOrder = instance.drawOrder,
    clipId = clip,
  })
  events[#events + 1] = event("spriteVisible", stepId, atStepTick, {
    instanceId = instance.id,
    engine = instance.engine,
    x = x,
    y = y,
    drawOrder = instance.drawOrder,
    visible = true,
  })
end

---@param events table<string, unknown>[]
---@param sceneNumber integer owning scene
---@param instances table<string, unknown>[] scene sprite instance declarations
---@param stepId string
---@param atStepTick integer
---@param sprite string source sprite name
---@param visible boolean whether the instance shows
local function setSpriteVisible(events, sceneNumber, instances, stepId, atStepTick, sprite, visible)
  local instance = instanceFor(instances, sprite)
  local x, y = sourceLocalPosition(sceneNumber, instance.engine, instance.x, instance.y)
  events[#events + 1] = event("spriteVisible", stepId, atStepTick, {
    instanceId = instance.id,
    engine = instance.engine,
    x = x,
    y = y,
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
  -- LoadBgGfx disables every plane after the templates enable them, so the
  -- copyright beat enables only its two planes and later beats toggle the
  -- rest on and off explicitly.
  local planes = snapshotPlanes(layers)
  -- Entry polarity is a sourced retail fact: each scene Init writes
  -- gSystem.screensFlipped then calls GfGfx_SwapDisplay, so scenes 1, 4,
  -- and 5 (TRUE) open with the main engine on the physical lower screen
  -- while scenes 2 and 3 (FALSE) open with it on the upper screen.
  local copyright = { nextIndex(events) }
  events[#events + 1] = event("setScreenMapping", "copyright", 0, { mainPhysical = "lower" })
  setPlaneVisible(events, planes, layers, "copyright", 0, "sub", 0, true)
  copyright[#copyright + 1] = #events
  setPlaneVisible(events, planes, layers, "copyright", 0, "main", 0, true)
  copyright[#copyright + 1] = #events
  copyright[#copyright + 1] = nextIndex(events)
  events[#events + 1] = event("setScroll", "copyright", 0, { engine = "main", bgSlot = 0, dx = 0, dy = 128, ticks = 0 })
  copyright[#copyright + 1] = nextIndex(events)
  events[#events + 1] =
    event("setScroll", "copyright", 0, { engine = "main", bgSlot = 0, dx = 0, dy = -128, ticks = 0 })
  copyright[#copyright + 1] = nextIndex(events)
  events[#events + 1] = event("waitTicks", "copyright", 0, { ticks = 30 })
  step(steps, "copyright", copyright, { kind = "duration", ticks = 30 })
  local fades = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("setBlend", "fades", 0, {
    engine = "main",
    firstMask = 1,
    secondMask = 32,
    direction = 1,
    ticks = 60,
    effect = "blend-copyright-main",
  })
  events[#events + 1] = event("setBlend", "fades", 0, {
    engine = "sub",
    firstMask = 1,
    secondMask = 32,
    direction = 1,
    ticks = 60,
    effect = "blend-copyright-sub",
  })
  step(steps, "fades", fades, { kind = "effect", effect = "blend-copyright-main" })
  local setup = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("waitTicks", "setup", 0, { ticks = 20 })
  events[#events + 1] = event("enableSkip", "setup", 20)
  setPlaneVisible(events, planes, layers, "setup", 20, "sub", 0, false)
  setup[#setup + 1] = #events
  setPlaneVisible(events, planes, layers, "setup", 20, "sub", 1, true)
  setup[#setup + 1] = #events
  step(steps, "setup", setup, { kind = "duration", ticks = 20 })
  local logo = { nextIndex(events) }
  events[#events + 1] = event("waitTicks", "logo", 0, { ticks = 110 })
  step(steps, "logo", logo, { kind = "duration", ticks = 110 })
  local sunrise = {}
  setLayerEvent(events, planes, layers, "sunrise", 0, "sub", 3, nil, true)
  sunrise[#sunrise + 1] = #events
  setLayerEvent(events, planes, layers, "sunrise", 0, "main", 1, nil, true)
  sunrise[#sunrise + 1] = #events
  setLayerEvent(events, planes, layers, "sunrise", 0, "main", 2, nil, true)
  sunrise[#sunrise + 1] = #events
  setLayerEvent(events, planes, layers, "sunrise", 0, "main", 3, nil, true)
  sunrise[#sunrise + 1] = #events
  sunrise[#sunrise + 1] = nextIndex(events)
  events[#events + 1] = event("waitTicks", "sunrise", 0, { ticks = 1 })
  step(steps, "sunrise", sunrise, { kind = "duration", ticks = 1 })
  local scroll = {}
  scroll[#scroll + 1] = nextIndex(events)
  events[#events + 1] = event("setBlend", "scroll", 0, {
    engine = "main",
    firstMask = 1,
    secondMask = 30,
    direction = 1,
    ticks = 80,
    effect = "scroll-sunrise-main",
  })
  scroll[#scroll + 1] = nextIndex(events)
  events[#events + 1] = event("setBlend", "scroll", 0, {
    engine = "sub",
    firstMask = 2,
    secondMask = 30,
    direction = 1,
    ticks = 80,
    effect = "scroll-sunrise-sub",
  })
  scroll[#scroll + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "scroll",
    0,
    { engine = "main", bgSlot = 1, dx = 0, dy = -0x20, ticks = 240, effect = "scroll-sunrise" }
  )
  scroll[#scroll + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "scroll",
    0,
    { engine = "main", bgSlot = 2, dx = 0, dy = -0x10, ticks = 240, effect = "scroll-sunrise" }
  )
  showSprite(events, 1, instances, clips, "scroll", 0, "sun", "bird", 0)
  scroll[#scroll + 1] = #events - 1
  scroll[#scroll + 1] = #events
  step(steps, "scroll", scroll, { kind = "effect", effect = "scroll-sunrise" })
  local bird = { nextIndex(events) }
  events[#events + 1] = event("waitTicks", "bird", 0, { ticks = 128 })
  showSprite(events, 1, instances, clips, "bird", 128, "bird", "bird", 1)
  bird[#bird + 1] = #events - 1
  bird[#bird + 1] = #events
  step(steps, "bird", bird, { kind = "duration", ticks = 128 })
  local run = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("waitTicks", "run", 0, { ticks = 90 })
  events[#events + 1] = event("setFade", "run", 90, { kind = "white", ticks = 65, effect = "fade-white" })
  step(steps, "run", run, { kind = "duration", ticks = 90 })
  local fadeFinish = nextIndex(events)
  events[#events + 1] = event("finish", "fade", 0)
  step(steps, "fade", {}, { kind = "effect", effect = "fade-white" }, { fadeFinish })
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
    local x, y = sourceLocalPosition(2, instance.engine, instance.x, instance.y)
    events[#events + 1] = event("setSpriteClip", stepId, atStepTick, {
      instanceId = instance.id,
      engine = instance.engine,
      x = x,
      y = y,
      drawOrder = instance.drawOrder,
      clipId = clip,
    })
    events[#events + 1] = event("spriteVisible", stepId, atStepTick, {
      instanceId = instance.id,
      engine = instance.engine,
      x = x,
      y = y,
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
      local rawX = startX + truncStep(xSpeed, tick, duration)
      local rawY = startY + truncStep(ySpeed, tick, duration)
      for _, instanceId in ipairs(groupIds) do
        local instance = instanceById(instances, instanceId)
        local x, y = sourceLocalPosition(2, instance.engine, rawX, rawY)
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
  events[#events + 1] = event("setScroll", "flyin", 0, { engine = "main", bgSlot = 1, dx = 0, dy = 320, ticks = 0 })
  flyin[#flyin + 1] = nextIndex(events)
  events[#events + 1] = event("setScroll", "flyin", 0, { engine = "main", bgSlot = 0, dx = 0, dy = 192, ticks = 0 })
  flyin[#flyin + 1] = nextIndex(events)
  events[#events + 1] = event("setScroll", "flyin", 0, { engine = "main", bgSlot = 2, dx = 0, dy = 64, ticks = -1 })
  flyin[#flyin + 1] = nextIndex(events)
  events[#events + 1] = event("setScroll", "flyin", 0, { engine = "sub", bgSlot = 0, dx = 0, dy = 64, ticks = -1 })
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
  events[#events + 1] = event("setScroll", "flyin", 56, { engine = "main", bgSlot = 1, dx = 0, dy = -0xC0, ticks = 5 })
  flyin[#flyin + 1] = nextIndex(events)
  events[#events + 1] = event("setScroll", "flyin", 56, { engine = "main", bgSlot = 0, dx = 0, dy = -0xC0, ticks = 5 })
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
        { engine = "main", bgSlot = slot, dx = dx, dy = dy, ticks = ticks, effect = "scroll-" .. id }
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
    { engine = "main", bgSlot = 1, dx = 0, dy = -0x80, ticks = 10, effect = "scroll-lyra-exit" }
  )
  exit[#exit + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "lyra-exit",
    0,
    { engine = "main", bgSlot = 0, dx = 0, dy = -0x40, ticks = 5, effect = "scroll-lyra-exit" }
  )
  for _, position in ipairs(panPositions("lyra-exit", ethanIds, 0, 0x80, 10, -64, 96)) do
    exit[#exit + 1] = position
  end
  for _, position in ipairs(panPositions("lyra-exit", lyraIds, 0, 0x80, 10, 192, 96)) do
    exit[#exit + 1] = position
  end
  step(steps, "lyra-exit", exit, { kind = "effect", effect = "scroll-lyra-exit" })
  local wipe = { nextIndex(events) }
  events[#events + 1] = event("circleWipe", "wipe", 0, { engine = "main", kind = 1, ticks = 8, effect = "wipe-circle" })
  step(steps, "wipe", wipe, { kind = "effect", effect = "wipe-circle" })
  local doneFinish = nextIndex(events)
  events[#events + 1] = event("finish", "done", 0)
  step(steps, "done", {}, { kind = "effect", effect = "wipe-circle" }, { doneFinish })
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
  -- Compiler-local slot images: plane toggles preserve the most recently
  -- staged tilemap variant instead of resetting the slot to base art.
  local planes = snapshotPlanes(layers)
  local function showPanel(stepId, atStepTick, phase)
    local slot = assert(panels[phase], "opening scene 3 phase names its panel: " .. tostring(phase))
    setLayerEvent(events, planes, layers, stepId, atStepTick, slot.engine, slot.bgSlot, slot.variant, nil)
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
  showSprite(events, 3, instances, clips, "show-new-bark-town", 0, "silver-silhouette", "silver", 0)
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
    -- Each town rises on the main engine: the first town opens with
    -- kind 0, later towns with kind 2, eight source ticks each. Step
    -- order gates the close below on the finished open.
    local openKind = town == 1 and 0 or 2
    show[#show + 1] = nextIndex(events)
    events[#events + 1] = event("circleWipe", "show-" .. towns[town], 0, {
      engine = "main",
      kind = openKind,
      ticks = 8,
      effect = "wipe-" .. towns[town] .. "-open",
    })
    show[#show + 1] = nextIndex(events)
    events[#events + 1] = event("waitTicks", "show-" .. towns[town], holds[town] + 1, { ticks = holds[town] })
    step(steps, "show-" .. towns[town], show, { kind = "duration", ticks = holds[town] + 1 })
    -- The town closes on the main engine with kind 3 over eight source
    -- ticks; the close step completes only when the close finishes, so
    -- the next town beat starts after its wipe.
    local close = { nextIndex(events) }
    events[#events + 1] = event("circleWipe", "close-" .. towns[town], 0, {
      engine = "main",
      kind = 3,
      ticks = 8,
      effect = "wipe-" .. towns[town] .. "-close",
    })
    step(steps, "close-" .. towns[town], close, { kind = "effect", effect = "wipe-" .. towns[town] .. "-close" })
  end
  -- The retail end-of-3D boundary sets whichMap=0xFFFF once the final
  -- town close finishes, before any rival-only output: town pixels stop
  -- while the staged town resources stay owned by the slot. Step order
  -- gates the reveal on the finished close.
  local rival = { nextIndex(events) }
  events[#events + 1] = event("circleWipe", "rival", 0, { engine = "sub", kind = 2, ticks = 8, effect = "wipe-rival" })
  rival[#rival + 1] = nextIndex(events)
  events[#events + 1] = event("setModelVisible", "rival", 0, { visible = false })
  step(steps, "rival", rival, { kind = "effect", effect = "wipe-rival" })
  local panelsStep = {}
  for index, delay in ipairs({ 56, 73, 92 }) do
    panelsStep[#panelsStep + 1] = showPanel("panels", delay, "rival-section-" .. index)
  end
  panelsStep[#panelsStep + 1] = nextIndex(events)
  local silhouette = instanceFor(instances, "silver-silhouette")
  local silhouetteX, silhouetteY = sourceLocalPosition(3, silhouette.engine, silhouette.x, silhouette.y)
  events[#events + 1] = event("spriteVisible", "panels", 92, {
    instanceId = silhouette.id,
    engine = silhouette.engine,
    x = silhouetteX,
    y = silhouetteY,
    drawOrder = silhouette.drawOrder,
    visible = false,
  })
  step(steps, "panels", panelsStep, { kind = "duration", ticks = 92 })
  local borders = { nextIndex(events) }
  events[#events + 1] = event("waitTicks", "borders", 0, { ticks = 10 })
  setPlaneVisible(events, planes, layers, "borders", 10, "sub", 0, false)
  borders[#borders + 1] = #events
  borders[#borders + 1] = showPanel("borders", 10, "rival-whole")
  step(steps, "borders", borders, { kind = "duration", ticks = 10 })
  -- One source step holds both the narrow pan at tick 5 and the widening
  -- pan, visibility, scroll, and plane enable at tick 44.
  local aspect = {}
  emitWindow(events, 3, "narrow-aspect", "aspect", 5, "window-aspect")
  aspect[#aspect + 1] = #events
  emitWindow(events, 3, "widen-aspect", "aspect", 44, "window-aspect-widen")
  aspect[#aspect + 1] = #events
  setWindowVisible(events, "aspect", 44, "sub", true)
  aspect[#aspect + 1] = #events
  aspect[#aspect + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "aspect",
    44,
    { engine = "sub", bgSlot = 0, dx = -256, dy = 0, ticks = 7, effect = "scroll-sub0" }
  )
  setPlaneVisible(events, planes, layers, "aspect", 44, "sub", 0, true)
  aspect[#aspect + 1] = #events
  step(steps, "aspect", aspect, { kind = "duration", ticks = 44 })
  local appearEntei = {}
  emitWindow(events, 3, "widen-entei", "appear-entei", 0, "window-appear-entei")
  appearEntei[#appearEntei + 1] = #events
  appearEntei[#appearEntei + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "appear-entei",
    0,
    { engine = "sub", bgSlot = 1, dx = 256, dy = 0, ticks = 7, effect = "scroll-sub1" }
  )
  setPlaneVisible(events, planes, layers, "appear-entei", 0, "sub", 1, true)
  appearEntei[#appearEntei + 1] = #events
  step(steps, "appear-entei", appearEntei, { kind = "effect", effect = "scroll-sub0" })
  local appearRaikou = {}
  emitWindow(events, 3, "widen-raikou", "appear-raikou", 0, "window-appear-raikou")
  appearRaikou[#appearRaikou + 1] = #events
  appearRaikou[#appearRaikou + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "appear-raikou",
    0,
    { engine = "sub", bgSlot = 2, dx = -256, dy = 0, ticks = 1, effect = "scroll-sub2" }
  )
  setPlaneVisible(events, planes, layers, "appear-raikou", 0, "sub", 2, true)
  appearRaikou[#appearRaikou + 1] = #events
  step(steps, "appear-raikou", appearRaikou, { kind = "effect", effect = "scroll-sub1" })
  local loadRockets = {}
  setWindowVisible(events, "load-rockets", 0, "sub", false)
  loadRockets[#loadRockets + 1] = #events
  setWindowVisible(events, "load-rockets", 0, "main", false)
  loadRockets[#loadRockets + 1] = #events
  step(steps, "load-rockets", loadRockets, { kind = "effect", effect = "scroll-sub2" })
  local narrowWindows = {}
  emitWindow(events, 3, "narrow-x", "narrow-windows", 42, "window-narrow-x")
  narrowWindows[#narrowWindows + 1] = #events
  setWindowVisible(events, "narrow-windows", 42, "sub", true)
  narrowWindows[#narrowWindows + 1] = #events
  step(steps, "narrow-windows", narrowWindows, { kind = "duration", ticks = 42 })
  step(steps, "wait-narrow", {}, { kind = "effect", effect = "window-narrow-x" })
  local sprites = {}
  showSprite(events, 3, instances, clips, "sprites", 56, "eusine", "eusine", 0)
  sprites[#sprites + 1] = #events - 1
  sprites[#sprites + 1] = #events
  showSprite(events, 3, instances, clips, "sprites", 145, "unown0", "eusine", 1)
  sprites[#sprites + 1] = #events - 1
  sprites[#sprites + 1] = #events
  emitWindow(events, 3, "slide-sprites", "sprites", 145, "window-sprites-slide")
  sprites[#sprites + 1] = #events
  setWindowSecondary(events, "sprites", 145, "sub", { 0x46, 0x40, 0xB9, 0xC0 }, 0x1D)
  sprites[#sprites + 1] = #events
  sprites[#sprites + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "sprites",
    145,
    { engine = "sub", bgSlot = 1, dx = -116, dy = 0, ticks = 10, effect = "scroll-sub1" }
  )
  step(steps, "sprites", sprites, { kind = "duration", ticks = 145 })
  local enteiDone = {}
  setPlaneVisible(events, planes, layers, "entei-exit", 0, "sub", 1, false)
  enteiDone[#enteiDone + 1] = #events
  emitWindow(events, 3, "nop-entei-exit", "entei-exit", 0, nil)
  enteiDone[#enteiDone + 1] = #events
  step(steps, "entei-exit", {}, { kind = "effect", effect = "scroll-sub1" }, enteiDone)
  local raikou = {}
  showSprite(events, 3, instances, clips, "raikou", 0, "unown1", "eusine", 2)
  raikou[#raikou + 1] = #events - 1
  raikou[#raikou + 1] = #events
  emitWindow(events, 3, "slide-raikou-exit", "raikou", 10, "window-raikou-exit")
  raikou[#raikou + 1] = #events
  setWindowSecondary(events, "raikou", 10, "sub", { 0x46, 0x40, 0xB9, 0x80 }, 0x19)
  raikou[#raikou + 1] = #events
  raikou[#raikou + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "raikou",
    10,
    { engine = "sub", bgSlot = 2, dx = -116, dy = 0, ticks = 10, effect = "scroll-sub2" }
  )
  step(steps, "raikou", raikou, { kind = "duration", ticks = 10 })
  local rocketsDone = {}
  setPlaneVisible(events, planes, layers, "rockets", 0, "sub", 2, false)
  rocketsDone[#rocketsDone + 1] = #events
  emitWindow(events, 3, "nop-rocket", "rockets", 0, nil)
  rocketsDone[#rocketsDone + 1] = #events
  for _, beast in ipairs({ "beast0", "beast1", "beast2" }) do
    rocketsDone[#rocketsDone + 1] = showPanel("rockets", 0, beast)
  end
  setPlaneVisible(events, planes, layers, "rockets", 0, "sub", 1, true)
  rocketsDone[#rocketsDone + 1] = #events
  setPlaneVisible(events, planes, layers, "rockets", 0, "sub", 2, true)
  rocketsDone[#rocketsDone + 1] = #events
  -- The beast panels show as a transition beat once both panel slides
  -- have finished; the beat completes on the latest slide.
  step(steps, "rockets", {}, { kind = "effects", effects = { "scroll-sub1", "scroll-sub2" } }, rocketsDone)
  local suicune = {}
  showSprite(events, 3, instances, clips, "suicune", 0, "unown2", "eusine", 3)
  suicune[#suicune + 1] = #events - 1
  suicune[#suicune + 1] = #events
  emitWindow(events, 3, "slide-suicune-exit", "suicune", 30, "window-suicune-exit")
  suicune[#suicune + 1] = #events
  setWindowSecondary(events, "suicune", 30, "sub", { 0x46, 0x40, 0xB9, 0x80 }, 0x1E)
  suicune[#suicune + 1] = #events
  suicune[#suicune + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "suicune",
    30,
    { engine = "sub", bgSlot = 0, dx = 0x74, dy = 0, ticks = 10, effect = "scroll-sub0" }
  )
  step(steps, "suicune", suicune, { kind = "duration", ticks = 30 })
  local viewportDone = {}
  setPlaneVisible(events, planes, layers, "viewport", 0, "sub", 0, false)
  viewportDone[#viewportDone + 1] = #events
  emitWindow(events, 3, "expand-viewport", "viewport", 0, "window-expand-viewport")
  viewportDone[#viewportDone + 1] = #events
  viewportDone[#viewportDone + 1] = nextIndex(events)
  events[#events + 1] =
    event("setScroll", "viewport", 0, { engine = "sub", bgSlot = 1, dx = 0, dy = -0x30, ticks = 254 })
  events[#events + 1] =
    event("setScroll", "viewport", 0, { engine = "sub", bgSlot = 2, dx = 0, dy = -0x20, ticks = 254 })
  viewportDone[#viewportDone + 1] = #events
  -- The viewport mutations run once the closing beast slide finishes; the
  -- tail scroll started by the next step runs under its own guard.
  step(steps, "viewport", {}, { kind = "effect", effect = "scroll-sub0" }, viewportDone)
  local viewportTail = { nextIndex(events) }
  events[#events + 1] = event(
    "setScroll",
    "viewport-tail",
    0,
    { engine = "sub", bgSlot = 3, dx = 0, dy = -0x08, ticks = 254, effect = "scroll-sub3" }
  )
  step(steps, "viewport-tail", viewportTail, { kind = "effect", effect = "scroll-sub3" })
  local adminsFinish = nextIndex(events)
  events[#events + 1] = event("finish", "admins", 0)
  step(steps, "admins", {}, { kind = "effect", effect = "scroll-sub1" }, { adminsFinish })
  return steps, events
end

---@param clips table<string, unknown>[]
---@param layers table<string, unknown>
---@return table<string, unknown>[], table<string, unknown>[] steps and events
local function scene4Program(clips, layers)
  local instances = SceneSources.spriteInstances(4)
  local steps, events = {}, {}
  local planes = snapshotPlanes(layers)
  local fadeIn = { nextIndex(events) }
  events[#events + 1] = event("setScreenMapping", "fade-in", 0, { mainPhysical = "lower" })
  fadeIn[#fadeIn + 1] = nextIndex(events)
  events[#events + 1] = event("setScroll", "fade-in", 0, { engine = "sub", bgSlot = 1, dx = -192, dy = 0, ticks = 0 })
  fadeIn[#fadeIn + 1] = nextIndex(events)
  events[#events + 1] = event("setScroll", "fade-in", 0, { engine = "main", bgSlot = 1, dx = 192, dy = 0, ticks = 0 })
  fadeIn[#fadeIn + 1] = nextIndex(events)
  events[#events + 1] = event("setFade", "fade-in", 0, { kind = "black-shutter-open", ticks = 10, effect = "fade-in" })
  step(steps, "fade-in", fadeIn, { kind = "effect", effect = "fade-in" })
  local slideIn = {}
  -- The simultaneous top pan addresses the sub engine while the bottom
  -- pan addresses the main engine; both span the full display width.
  emitWindow(events, 4, "slide-in-top", "slide-in", 0, nil)
  slideIn[#slideIn + 1] = #events
  emitWindow(events, 4, "slide-in-bottom", "slide-in", 0, nil)
  slideIn[#slideIn + 1] = #events
  slideIn[#slideIn + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "slide-in",
    0,
    { engine = "sub", bgSlot = 1, dx = 0xC0, dy = 0, ticks = 10, effect = "scroll-slide-in" }
  )
  slideIn[#slideIn + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "slide-in",
    0,
    { engine = "main", bgSlot = 1, dx = -0xC0, dy = 0, ticks = 10, effect = "scroll-slide-in" }
  )
  showSprite(events, 4, instances, clips, "slide-in", 0, "hand1", "hands", 0)
  slideIn[#slideIn + 1] = #events - 1
  slideIn[#slideIn + 1] = #events
  showSprite(events, 4, instances, clips, "slide-in", 0, "hand2", "hands", 1)
  slideIn[#slideIn + 1] = #events - 1
  slideIn[#slideIn + 1] = #events
  setPlaneVisible(events, planes, layers, "slide-in", 0, "main", 1, true)
  slideIn[#slideIn + 1] = #events
  setPlaneVisible(events, planes, layers, "slide-in", 0, "sub", 1, true)
  slideIn[#slideIn + 1] = #events
  step(steps, "slide-in", slideIn, { kind = "effect", effect = "scroll-slide-in" })
  local hold = { nextIndex(events) }
  events[#events + 1] = event("waitTicks", "hold", 26, { ticks = 25 })
  step(steps, "hold", hold, { kind = "duration", ticks = 26 })
  local slideOut = {}
  emitWindow(events, 4, "slide-out-top", "slide-out", 0, nil)
  slideOut[#slideOut + 1] = #events
  emitWindow(events, 4, "slide-out-bottom", "slide-out", 0, nil)
  slideOut[#slideOut + 1] = #events
  slideOut[#slideOut + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "slide-out",
    0,
    { engine = "sub", bgSlot = 1, dx = 0xC0, dy = 0, ticks = 10, effect = "scroll-slide-out" }
  )
  slideOut[#slideOut + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "slide-out",
    0,
    { engine = "main", bgSlot = 1, dx = -0xC0, dy = 0, ticks = 10, effect = "scroll-slide-out" }
  )
  step(steps, "slide-out", slideOut, { kind = "effect", effect = "scroll-slide-out" })
  local hide = {}
  setSpriteVisible(events, 4, instances, "hide-hands", 0, "hand1", false)
  hide[#hide + 1] = #events
  setSpriteVisible(events, 4, instances, "hide-hands", 0, "hand2", false)
  hide[#hide + 1] = #events
  setPlaneVisible(events, planes, layers, "hide-hands", 0, "main", 1, false)
  hide[#hide + 1] = #events
  setPlaneVisible(events, planes, layers, "hide-hands", 0, "sub", 1, false)
  hide[#hide + 1] = #events
  setWindowVisible(events, "hide-hands", 0, "main", false)
  hide[#hide + 1] = #events
  setWindowVisible(events, "hide-hands", 0, "sub", false)
  hide[#hide + 1] = #events
  step(steps, "hide-hands", hide, { kind = "effect", effect = "scroll-slide-out" })
  local starters = { "chikorita", "cyndaquil", "totodile" }
  local groups = { "grass", "fire", "water" }
  local emitterIds = { { 6, 7, 8 }, { 3, 4, 5 }, { 0, 1, 2 } }
  local banks = { "chikorita", "cyndaquil", "totodile" }
  for round = 1, 3 do
    local show = {}
    showSprite(events, 4, instances, clips, "starter-" .. starters[round], 0, starters[round], banks[round], 0)
    show[#show + 1] = #events - 1
    show[#show + 1] = #events
    show[#show + 1] = nextIndex(events)
    events[#events + 1] =
      event("startEmitters", "starter-" .. starters[round], 0, { group = groups[round], emitters = emitterIds[round] })
    step(steps, "starter-" .. starters[round], show, { kind = "effect", effect = "emitters-" .. groups[round] })
    if round < 3 then
      -- Retail Task_IntroMovie_Scene4_FlipScreens: argument 0 (after the
      -- first starter) clears the flip so main returns upper with main
      -- BG2 on/BG3 off and sub BG2 off/BG3 on; argument 1 (after the
      -- second starter) sets the flip so main returns lower with the
      -- mirrored plane masks.
      local flip = { nextIndex(events) }
      local afterFirst = round == 1
      events[#events + 1] = event(
        "setScreenMapping",
        "flip-" .. starters[round],
        0,
        afterFirst and { mainPhysical = "upper" } or { mainPhysical = "lower" }
      )
      setPlaneVisible(events, planes, layers, "flip-" .. starters[round], 0, "main", 2, afterFirst)
      flip[#flip + 1] = #events
      setPlaneVisible(events, planes, layers, "flip-" .. starters[round], 0, "main", 3, not afterFirst)
      flip[#flip + 1] = #events
      setPlaneVisible(events, planes, layers, "flip-" .. starters[round], 0, "sub", 2, not afterFirst)
      flip[#flip + 1] = #events
      setPlaneVisible(events, planes, layers, "flip-" .. starters[round], 0, "sub", 3, afterFirst)
      flip[#flip + 1] = #events
      step(steps, "flip-" .. starters[round], flip, { kind = "effect", effect = "emitters-" .. groups[round] })
    end
  end
  local finishTotodile = { nextIndex(events) }
  events[#events + 1] =
    event("setFade", "finish-totodile", 0, { kind = "black-shutter-close", ticks = 26, effect = "fade-close" })
  for _, bgSlot in ipairs({ 1, 2, 3 }) do
    setPlaneVisible(events, planes, layers, "finish-totodile", 0, "main", bgSlot, false)
    finishTotodile[#finishTotodile + 1] = #events
  end
  step(steps, "finish-totodile", finishTotodile, { kind = "effect", effect = "fade-close" })
  -- The closing sparkle waits on its own compiled clip: the animation's
  -- frame durations bound the wait, with no separate named effect.
  local sparkleClip = clipPath(clips, "hands", 2)
  local sparkle = {}
  showSprite(events, 4, instances, clips, "sparkle", 0, "sparkles", "hands", 2)
  sparkle[#sparkle + 1] = #events - 1
  sparkle[#sparkle + 1] = #events
  step(steps, "sparkle", sparkle, { kind = "effect", effect = sparkleClip })
  local doneFinish = nextIndex(events)
  events[#events + 1] = event("finish", "done", 0)
  step(steps, "done", {}, { kind = "effect", effect = sparkleClip }, { doneFinish })
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
  events[#events + 1] = event("setScroll", "wipe", 0, { engine = "main", bgSlot = 2, dx = 0, dy = 160, ticks = 0 })
  wipe[#wipe + 1] = nextIndex(events)
  events[#events + 1] = event("setScroll", "wipe", 0, { engine = "sub", bgSlot = 2, dx = 0, dy = 160, ticks = 0 })
  wipe[#wipe + 1] = nextIndex(events)
  events[#events + 1] = event("shutterFade", "wipe", 0, {
    order = "main-then-sub",
    mainPattern = "center-out",
    subPattern = "bottom-up",
    color = "black",
    steps = 18,
    framesPerStep = 1,
    effect = "scene5-shutter",
  })
  step(steps, "wipe", wipe, { kind = "duration", ticks = 18 })
  -- All four scroll programs begin together once the ordered shutter and
  -- its cleanup complete; the guard below holds their starts, it never
  -- starts them early.
  local scrollStarts = {}
  scrollStarts[#scrollStarts + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "scroll",
    0,
    { engine = "main", bgSlot = 1, dx = 0, dy = -0x40, ticks = 73, effect = "scroll-panorama" }
  )
  local paired = { { engine = "main", bgSlot = 2 }, { engine = "sub", bgSlot = 1 }, { engine = "sub", bgSlot = 2 } }
  for _, slot in ipairs(paired) do
    scrollStarts[#scrollStarts + 1] = nextIndex(events)
    events[#events + 1] = event("setScroll", "scroll", 0, {
      engine = slot.engine,
      bgSlot = slot.bgSlot,
      dx = 0,
      dy = direction == "left" and -0x40 or 0x40,
      ticks = 73,
      effect = "scroll-panorama",
    })
  end
  step(steps, "scroll", {}, { kind = "effect", effect = "scene5-shutter" }, scrollStarts)
  local wait = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("waitTicks", "wait", 0, { ticks = 20 })
  events[#events + 1] = event("setFade", "wait", 20, { kind = "white", ticks = 50, effect = "fade-white" })
  step(steps, "wait", wait, { kind = "duration", ticks = 20 })
  local fadeFinish = nextIndex(events)
  events[#events + 1] = event("finish", "fade", 0)
  step(steps, "fade", {}, { kind = "effect", effect = "fade-white" }, { fadeFinish })
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
    steps, events = scene4Program(clips, layers)
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
