-- Bounded source orchestrator for one HGSS opening-movie scene. Reads only
-- that scene's source members from NARC_demo_opening_gs_opening (plus the
-- scene 4 particle member through the narrow particle compiler), decodes
-- 2D art through the shared G2D owners, scene 3 towns through the shared
-- dynamic model owner, and emits the strictly normalized source-independent
-- scene bundle: versioned manifest, staged PNG/mesh/clip files, closed
-- movie event program, and producer dependencies for the job receipt. No
-- LÖVE objects, no ROM handles, and no source member identities cross into
-- the manifest. Unsupported source members, animations, or particle data
-- fail the build with scene and member context; nothing is guessed.

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
---@return table<string, unknown> layers record
local function compileBackgrounds(archive, versionId, sceneNumber, root, files, dependencies)
  local layers = { upper = {}, lower = {} }
  for _, background in ipairs(SceneSources.backgrounds(versionId, sceneNumber)) do
    local role = background.engine == "main" and "upper" or "lower"
    local base = role .. "-" .. background.slot
    local charData = decodeChar(
      readMember(archive, background.char, base .. "-characters", sceneNumber, dependencies),
      base .. "-characters",
      sceneNumber,
      background.char
    )
    local screenData = decodeScreen(
      readMember(archive, background.screen, base .. "-screen", sceneNumber, dependencies),
      base .. "-screen",
      sceneNumber,
      background.screen
    )
    local paletteData = decodePalette(
      readMember(archive, background.palette, base .. "-palette", sceneNumber, dependencies),
      base .. "-palette",
      sceneNumber,
      background.palette
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
      layer = base,
    })
    local surface = RgbaImage.crop(rendered, { x = 0, y = 0, width = 256, height = 192 }, "opening scene " .. base)
    local path = root .. "/layers/" .. base .. ".png"
    files[path] = PngWriter.encode(surface.width, surface.height, surface.pixels)
    layers[role][#layers[role] + 1] = {
      slot = background.slot,
      image = path,
      width = surface.width,
      height = surface.height,
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

-- Event program helpers. atTick composes the source state durations and
-- named effect lengths along the scene's main path; atStepTick preserves
-- the source per-step fire tick (the retail u8 step timer the state
-- machine thresholds against). Parallel source effects compose through
-- waitEffects naming the started effects; steps with unknown-length waits
-- (circle wipes, particle runs, sprite animation completion) advance the
-- composition by zero and order through the effect wait.
local function event(op, stepId, atTick, atStepTick, extra)
  local record = { op = op, stepId = stepId, atTick = atTick, atStepTick = atStepTick }
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

---@param clips table<string, unknown>[]
---@param layers table<string, unknown>
---@return table<string, unknown>[], table<string, unknown>[] steps and events
local function scene1Program(clips, layers)
  local upper, lower = layers.upper, layers.lower
  local function art(role, slot)
    for _, layer in ipairs(role == "upper" and upper or lower) do
      if layer.slot == slot then
        return layer.image
      end
    end
    sourceError("opening scene 1 timeline references a missing background layer", { slot = slot })
  end
  local steps, events = {}, {}
  local copyright = { nextIndex(events), nextIndex(events) + 1, nextIndex(events) + 2, nextIndex(events) + 3 }
  events[#events + 1] = event("setLayer", "copyright", 0, 0, { role = "lower", art = art("lower", "sub0") })
  events[#events + 1] = event("setLayer", "copyright", 0, 0, { role = "lower", art = art("lower", "sub1") })
  events[#events + 1] = event("setLayer", "copyright", 0, 0, { role = "upper", art = art("upper", "main0") })
  events[#events + 1] = event("waitTicks", "copyright", 0, 0, { ticks = 30 })
  step(steps, "copyright", copyright, { kind = "duration", ticks = 30 })
  local fades = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] =
    event("setBlend", "fades", 30, 0, { effect = "blend-upper", ticks = 60, from = 0x20, to = 0x1F })
  events[#events + 1] =
    event("setBlend", "fades", 30, 0, { effect = "blend-lower", ticks = 60, from = 0x20, to = 0x1F })
  step(steps, "fades", fades, { kind = "effect", effect = "blend-copyright" })
  local setup = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("waitTicks", "setup", 90, 0, { ticks = 20 })
  events[#events + 1] = event("enableSkip", "setup", 110, 20)
  step(steps, "setup", setup, { kind = "duration", ticks = 20 })
  local logo = { nextIndex(events) }
  events[#events + 1] = event("waitTicks", "logo", 110, 0, { ticks = 110 })
  step(steps, "logo", logo, { kind = "duration", ticks = 110 })
  local sunrise = {}
  for _, slot in ipairs({ "sub3" }) do
    sunrise[#sunrise + 1] = nextIndex(events)
    events[#events + 1] = event("setLayer", "sunrise", 220, 0, { role = "lower", art = art("lower", slot) })
  end
  for _, slot in ipairs({ "main1", "main2", "main3" }) do
    sunrise[#sunrise + 1] = nextIndex(events)
    events[#events + 1] = event("setLayer", "sunrise", 220, 0, { role = "upper", art = art("upper", slot) })
  end
  sunrise[#sunrise + 1] = nextIndex(events)
  events[#events + 1] = event("waitTicks", "sunrise", 220, 0, { ticks = 1 })
  step(steps, "sunrise", sunrise, { kind = "duration", ticks = 1 })
  local scroll = {}
  scroll[#scroll + 1] = nextIndex(events)
  events[#events + 1] = event("setBlend", "scroll", 221, 0, { effect = "blend-sunrise-upper", ticks = 80, from = 0x1E })
  scroll[#scroll + 1] = nextIndex(events)
  events[#events + 1] = event("setBlend", "scroll", 221, 0, { effect = "blend-sunrise-lower", ticks = 80, from = 0x1E })
  scroll[#scroll + 1] = nextIndex(events)
  events[#events + 1] =
    event("setScroll", "scroll", 221, 0, { layer = "main1", dx = 0, dy = -0x20, ticks = 240, direction = "up" })
  scroll[#scroll + 1] = nextIndex(events)
  events[#events + 1] =
    event("setScroll", "scroll", 221, 0, { layer = "main2", dx = 0, dy = -0x10, ticks = 240, direction = "up" })
  scroll[#scroll + 1] = nextIndex(events)
  events[#events + 1] = event("setSpriteClip", "scroll", 221, 0, { sprite = "sun", clip = clipPath(clips, "bird", 0) })
  scroll[#scroll + 1] = nextIndex(events)
  events[#events + 1] = event("spriteVisible", "scroll", 221, 0, { sprite = "sun", visible = true })
  step(steps, "scroll", scroll, { kind = "effect", effect = "scroll-sunrise" })
  local bird = { nextIndex(events), nextIndex(events) + 1, nextIndex(events) + 2 }
  events[#events + 1] = event("waitTicks", "bird", 461, 0, { ticks = 128 })
  events[#events + 1] = event("setSpriteClip", "bird", 461, 128, { sprite = "bird", clip = clipPath(clips, "bird", 1) })
  events[#events + 1] = event("spriteVisible", "bird", 461, 128, { sprite = "bird", visible = true })
  step(steps, "bird", bird, { kind = "duration", ticks = 128 })
  local run = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("waitTicks", "run", 589, 0, { ticks = 90 })
  events[#events + 1] = event("setFade", "run", 589, 90, { kind = "white", ticks = 65 })
  step(steps, "run", run, { kind = "duration", ticks = 90 })
  local fade = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("waitEffects", "fade", 679, 0, { effects = { "fade-white" } })
  events[#events + 1] = event("finish", "fade", 679, 0)
  step(steps, "fade", fade, { kind = "effect", effect = "fade-white" })
  return steps, events
end

---@param clips table<string, unknown>[]
---@return table<string, unknown>[], table<string, unknown>[] steps and events
local function scene2Program(clips)
  local steps, events = {}, {}
  local flyin = { nextIndex(events) }
  events[#events + 1] = event("setFade", "flyin", 0, 0, { kind = "white-in", ticks = 3 })
  local flowerAt = { 1, 8, 16, 24, 28, 32, 34, 38, 42, 48 }
  local flowerSeq = { 0, 1, 2, 3, 0, 1, 2, 3, 0, 1 }
  for flower = 1, 10 do
    flyin[#flyin + 1] = nextIndex(events)
    events[#events + 1] = event(
      "setSpriteClip",
      "flyin",
      flowerAt[flower],
      flowerAt[flower],
      { sprite = "flower" .. flower, clip = clipPath(clips, "flowers", flowerSeq[flower]) }
    )
    flyin[#flyin + 1] = nextIndex(events)
    events[#events + 1] = event(
      "spriteVisible",
      "flyin",
      flowerAt[flower],
      flowerAt[flower],
      { sprite = "flower" .. flower, visible = true }
    )
  end
  flyin[#flyin + 1] = nextIndex(events)
  events[#events + 1] =
    event("setScroll", "flyin", 56, 56, { layer = "main1", dx = 0, dy = -0xC0, ticks = 5, direction = "down" })
  flyin[#flyin + 1] = nextIndex(events)
  events[#events + 1] =
    event("setScroll", "flyin", 56, 56, { layer = "main0", dx = 0, dy = -0xC0, ticks = 5, direction = "down" })
  flyin[#flyin + 1] = nextIndex(events)
  events[#events + 1] =
    event("setScroll", "flyin", 56, 56, { target = "flowers", dx = 0, dy = 0xC0, ticks = 5, direction = "up" })
  flyin[#flyin + 1] = nextIndex(events)
  events[#events + 1] =
    event("setScroll", "flyin", 56, 56, { target = "characters", dx = 0, dy = 0xC0, ticks = 5, direction = "up" })
  flyin[#flyin + 1] = nextIndex(events)
  events[#events + 1] = event("setFade", "flyin", 56, 56, { kind = "black-out", ticks = 8 })
  step(steps, "flyin", flyin, { kind = "duration", ticks = 56 })
  local function panStep(id, atTick, dx, dy, ticks)
    local indices = {}
    indices[#indices + 1] = nextIndex(events)
    events[#events + 1] = event("waitEffects", id, atTick, 0, { effects = { "scroll-" .. id .. "-in" } })
    for _, layer in ipairs({ "main1", "main0" }) do
      indices[#indices + 1] = nextIndex(events)
      events[#events + 1] =
        event("setScroll", id, atTick, 0, { layer = layer, dx = dx, dy = dy, ticks = ticks, direction = "pan" })
    end
    for _, target in ipairs({ "flowers", "characters" }) do
      indices[#indices + 1] = nextIndex(events)
      events[#events + 1] =
        event("setScroll", id, atTick, 0, { target = target, dx = -dx, dy = -dy, ticks = ticks, direction = "pan" })
    end
    step(steps, id, indices, { kind = "effect", effect = "scroll-" .. id })
    return atTick + ticks
  end
  local atTick = 56
  atTick = panStep("slow-pan-ethan", atTick, 0x20, 0, 90)
  atTick = panStep("fast-pan-lyra", atTick, 0x40, 0, 7)
  atTick = panStep("slow-pan-lyra", atTick, 0x20, 0, 66)
  local exit = { nextIndex(events) }
  events[#events + 1] = event("waitEffects", "lyra-exit", atTick, 0, { effects = { "scroll-slow-pan-lyra" } })
  exit[#exit + 1] = nextIndex(events)
  events[#events + 1] =
    event("setScroll", "lyra-exit", atTick, 0, { layer = "main1", dx = 0, dy = -0x80, ticks = 10, direction = "up" })
  exit[#exit + 1] = nextIndex(events)
  events[#events + 1] =
    event("setScroll", "lyra-exit", atTick, 0, { layer = "main0", dx = 0, dy = -0x40, ticks = 5, direction = "up" })
  exit[#exit + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "lyra-exit",
    atTick,
    0,
    { target = "flowers", dx = 0, dy = 0x80, ticks = 10, direction = "down" }
  )
  exit[#exit + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "lyra-exit",
    atTick,
    0,
    { target = "characters", dx = 0, dy = 0x80, ticks = 10, direction = "down" }
  )
  step(steps, "lyra-exit", exit, { kind = "effect", effect = "scroll-lyra-exit" })
  atTick = atTick + 10
  local wipe = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("waitEffects", "wipe", atTick, 0, { effects = { "scroll-lyra-exit" } })
  events[#events + 1] = event("circleWipe", "wipe", atTick, 0, { mode = "out" })
  step(steps, "wipe", wipe, { kind = "effect", effect = "wipe-circle" })
  local done = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("waitEffects", "done", atTick, 0, { effects = { "wipe-circle" } })
  events[#events + 1] = event("finish", "done", atTick, 0)
  step(steps, "done", done, { kind = "effect", effect = "wipe-circle" })
  return steps, events
end

---@param clips table<string, unknown>[]
---@return table<string, unknown>[], table<string, unknown>[] steps and events
local function scene3Program(clips)
  local steps, events = {}, {}
  local towns = { "new-bark-town", "goldenrod-city", "ecruteak-city" }
  -- Source hold thresholds (stepTimer > threshold fires at threshold + 1).
  local holds = { 40, 46, 98 }
  local atTick = 0
  for town = 1, 3 do
    local show = {}
    show[#show + 1] = nextIndex(events)
    events[#events + 1] =
      event("setModelClip", "show-" .. towns[town], atTick, 0, { model = towns[town], clip = "joint" })
    show[#show + 1] = nextIndex(events)
    events[#events + 1] =
      event("setCamera", "show-" .. towns[town], atTick, 0, { distance = 410.922119140625, angle = "sCameraParam" })
    show[#show + 1] = nextIndex(events)
    events[#events + 1] =
      event("setLighting", "show-" .. towns[town], atTick, 0, { map = town - 1, town = towns[town] })
    show[#show + 1] = nextIndex(events)
    events[#events + 1] = event("circleWipe", "show-" .. towns[town], atTick, 0, { mode = "in" })
    show[#show + 1] = nextIndex(events)
    events[#events + 1] = event("waitTicks", "show-" .. towns[town], atTick, holds[town] + 1, { ticks = holds[town] })
    step(steps, "show-" .. towns[town], show, { kind = "duration", ticks = holds[town] + 1 })
    atTick = atTick + holds[town] + 1
  end
  local rival = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("waitEffects", "rival", atTick, 0, { effects = { "wipe-circle" } })
  events[#events + 1] = event("circleWipe", "rival", atTick, 0, { mode = "out" })
  step(steps, "rival", rival, { kind = "effect", effect = "wipe-circle" })
  local panels = { nextIndex(events) }
  events[#events + 1] = event("waitEffects", "panels", atTick, 0, { effects = { "wipe-circle" } })
  for index, delay in ipairs({ 56, 73, 92 }) do
    panels[#panels + 1] = nextIndex(events)
    events[#events + 1] =
      event("setLayer", "panels", atTick + delay, delay, { role = "lower", art = "rival-section-" .. index })
  end
  panels[#panels + 1] = nextIndex(events)
  events[#events + 1] =
    event("spriteVisible", "panels", atTick + 92, 92, { sprite = "silver-silhouette", visible = false })
  step(steps, "panels", panels, { kind = "duration", ticks = 92 })
  atTick = atTick + 92
  local borders = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("waitTicks", "borders", atTick, 0, { ticks = 10 })
  events[#events + 1] = event("setLayer", "borders", atTick + 10, 10, { role = "lower", art = "rival-whole" })
  step(steps, "borders", borders, { kind = "duration", ticks = 10 })
  atTick = atTick + 10
  local aspect = { nextIndex(events) }
  events[#events + 1] = event("window", "aspect", atTick + 5, 5, { target = "lower", kind = "narrow-y" })
  step(steps, "aspect", aspect, { kind = "duration", ticks = 5 })
  atTick = atTick + 5
  local narrow = { nextIndex(events) }
  events[#events + 1] = event("waitEffects", "narrow", atTick, 0, { effects = { "window-aspect" } })
  step(steps, "narrow", narrow, { kind = "effect", effect = "window-aspect" })
  local sprites = {}
  sprites[#sprites + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setSpriteClip",
    "sprites",
    atTick + 56,
    56,
    { sprite = "eusine", clip = clipPath(clips, "eusine", 0), species = "guard" }
  )
  sprites[#sprites + 1] = nextIndex(events)
  events[#events + 1] = event("spriteVisible", "sprites", atTick + 56, 56, { sprite = "eusine", visible = true })
  sprites[#sprites + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setSpriteClip",
    "sprites",
    atTick + 145,
    145,
    { sprite = "unown0", clip = clipPath(clips, "eusine", 1), species = "unown" }
  )
  sprites[#sprites + 1] = nextIndex(events)
  events[#events + 1] = event("spriteVisible", "sprites", atTick + 145, 145, { sprite = "unown0", visible = true })
  sprites[#sprites + 1] = nextIndex(events)
  events[#events + 1] = event("window", "sprites", atTick + 145, 145, { target = "lower", kind = "slide-left" })
  sprites[#sprites + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "sprites",
    atTick + 145,
    145,
    { layer = "sub1", dx = -116, dy = 0, ticks = 10, direction = "left" }
  )
  step(steps, "sprites", sprites, { kind = "duration", ticks = 145 })
  atTick = atTick + 145
  local entei = { nextIndex(events) }
  events[#events + 1] = event("waitEffects", "entei-exit", atTick, 0, { effects = { "scroll-sub1" } })
  step(steps, "entei-exit", entei, { kind = "effect", effect = "scroll-sub1" })
  local raikou = {}
  raikou[#raikou + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setSpriteClip",
    "raikou",
    atTick,
    0,
    { sprite = "unown1", clip = clipPath(clips, "eusine", 2), species = "unown" }
  )
  raikou[#raikou + 1] = nextIndex(events)
  events[#events + 1] = event("spriteVisible", "raikou", atTick, 0, { sprite = "unown1", visible = true })
  raikou[#raikou + 1] = nextIndex(events)
  events[#events + 1] = event("window", "raikou", atTick + 10, 10, { target = "lower", kind = "slide-left" })
  raikou[#raikou + 1] = nextIndex(events)
  events[#events + 1] =
    event("setScroll", "raikou", atTick + 10, 10, { layer = "sub2", dx = -116, dy = 0, ticks = 10, direction = "left" })
  step(steps, "raikou", raikou, { kind = "duration", ticks = 10 })
  atTick = atTick + 10
  local rockets = {}
  rockets[#rockets + 1] = nextIndex(events)
  events[#events + 1] = event("waitEffects", "rockets", atTick, 0, { effects = { "scroll-sub1", "scroll-sub2" } })
  for _, beast in ipairs({ "beast0", "beast1", "beast2" }) do
    rockets[#rockets + 1] = nextIndex(events)
    events[#events + 1] = event("setLayer", "rockets", atTick, 0, { role = "lower", art = beast })
  end
  step(steps, "rockets", rockets, { kind = "effect", effect = "scroll-rockets" })
  local suicune = {}
  suicune[#suicune + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setSpriteClip",
    "suicune",
    atTick,
    0,
    { sprite = "unown2", clip = clipPath(clips, "eusine", 3), species = "unown" }
  )
  suicune[#suicune + 1] = nextIndex(events)
  events[#events + 1] = event("spriteVisible", "suicune", atTick, 0, { sprite = "unown2", visible = true })
  suicune[#suicune + 1] = nextIndex(events)
  events[#events + 1] = event("window", "suicune", atTick + 30, 30, { target = "lower", kind = "slide-right" })
  suicune[#suicune + 1] = nextIndex(events)
  events[#events + 1] = event(
    "setScroll",
    "suicune",
    atTick + 30,
    30,
    { layer = "sub0", dx = 0x74, dy = 0, ticks = 10, direction = "right" }
  )
  step(steps, "suicune", suicune, { kind = "duration", ticks = 30 })
  atTick = atTick + 30
  local viewport = { nextIndex(events), nextIndex(events) + 1, nextIndex(events) + 2, nextIndex(events) + 3 }
  events[#events + 1] = event("waitEffects", "viewport", atTick, 0, { effects = { "scroll-sub0" } })
  events[#events + 1] = event("window", "viewport", atTick, 0, { target = "lower", kind = "expand" })
  events[#events + 1] =
    event("setScroll", "viewport", atTick, 0, { layer = "sub1", dx = 0, dy = -0x30, ticks = 254, direction = "up" })
  events[#events + 1] =
    event("setScroll", "viewport", atTick, 0, { layer = "sub2", dx = 0, dy = -0x20, ticks = 254, direction = "up" })
  local viewportTail = { nextIndex(events) }
  events[#events + 1] = event(
    "setScroll",
    "viewport-tail",
    atTick,
    0,
    { layer = "sub3", dx = 0, dy = -0x08, ticks = 254, direction = "up" }
  )
  step(steps, "viewport", viewport, { kind = "effect", effect = "scroll-sub3" })
  step(steps, "viewport-tail", viewportTail, { kind = "effect", effect = "scroll-sub3" })
  local admins = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("waitEffects", "admins", atTick, 0, { effects = { "scroll-sub1" } })
  events[#events + 1] = event("finish", "admins", atTick, 0)
  step(steps, "admins", admins, { kind = "effect", effect = "scroll-sub1" })
  return steps, events
end

---@param clips table<string, unknown>[]
---@return table<string, unknown>[], table<string, unknown>[] steps and events
local function scene4Program(clips)
  local steps, events = {}, {}
  local fadeIn = { nextIndex(events) }
  events[#events + 1] = event("setFade", "fade-in", 0, 0, { kind = "black-shutter-open", ticks = 10 })
  step(steps, "fade-in", fadeIn, { kind = "effect", effect = "fade-in" })
  local slideIn = {}
  slideIn[#slideIn + 1] = nextIndex(events)
  events[#events + 1] = event("waitEffects", "slide-in", 10, 0, { effects = { "fade-in" } })
  slideIn[#slideIn + 1] = nextIndex(events)
  events[#events + 1] = event("window", "slide-in", 10, 0, { target = "upper", kind = "widen-left" })
  slideIn[#slideIn + 1] = nextIndex(events)
  events[#events + 1] = event("window", "slide-in", 10, 0, { target = "lower", kind = "widen-right" })
  slideIn[#slideIn + 1] = nextIndex(events)
  events[#events + 1] =
    event("setScroll", "slide-in", 10, 0, { layer = "sub1", dx = 0xC0, dy = 0, ticks = 10, direction = "right" })
  slideIn[#slideIn + 1] = nextIndex(events)
  events[#events + 1] =
    event("setScroll", "slide-in", 10, 0, { layer = "main1", dx = -0xC0, dy = 0, ticks = 10, direction = "left" })
  slideIn[#slideIn + 1] = nextIndex(events)
  events[#events + 1] =
    event("setSpriteClip", "slide-in", 10, 0, { sprite = "hand1", clip = clipPath(clips, "hands", 0) })
  slideIn[#slideIn + 1] = nextIndex(events)
  events[#events + 1] =
    event("setSpriteClip", "slide-in", 10, 0, { sprite = "hand2", clip = clipPath(clips, "hands", 1) })
  slideIn[#slideIn + 1] = nextIndex(events)
  events[#events + 1] = event("spriteVisible", "slide-in", 10, 0, { sprite = "hand1", visible = true })
  slideIn[#slideIn + 1] = nextIndex(events)
  events[#events + 1] = event("spriteVisible", "slide-in", 10, 0, { sprite = "hand2", visible = true })
  step(steps, "slide-in", slideIn, { kind = "effect", effect = "scroll-slide-in" })
  local hold = { nextIndex(events) }
  events[#events + 1] = event("waitTicks", "hold", 20, 26, { ticks = 25 })
  step(steps, "hold", hold, { kind = "duration", ticks = 26 })
  local slideOut = {}
  slideOut[#slideOut + 1] = nextIndex(events)
  events[#events + 1] = event("window", "slide-out", 46, 0, { target = "upper", kind = "narrow-right" })
  slideOut[#slideOut + 1] = nextIndex(events)
  events[#events + 1] = event("window", "slide-out", 46, 0, { target = "lower", kind = "narrow-left" })
  slideOut[#slideOut + 1] = nextIndex(events)
  events[#events + 1] =
    event("setScroll", "slide-out", 46, 0, { layer = "sub1", dx = 0xC0, dy = 0, ticks = 10, direction = "right" })
  slideOut[#slideOut + 1] = nextIndex(events)
  events[#events + 1] =
    event("setScroll", "slide-out", 46, 0, { layer = "main1", dx = -0xC0, dy = 0, ticks = 10, direction = "left" })
  step(steps, "slide-out", slideOut, { kind = "effect", effect = "scroll-slide-out" })
  local hide = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("spriteVisible", "hide-hands", 56, 0, { sprite = "hand1", visible = false })
  events[#events + 1] = event("spriteVisible", "hide-hands", 56, 0, { sprite = "hand2", visible = false })
  step(steps, "hide-hands", hide, { kind = "effect", effect = "scroll-slide-out" })
  local starters = { "chikorita", "cyndaquil", "totodile" }
  local groups = { "grass", "fire", "water" }
  local emitterIds = { { 6, 7, 8 }, { 3, 4, 5 }, { 0, 1, 2 } }
  for round = 1, 3 do
    local show = {}
    show[#show + 1] = nextIndex(events)
    local bank = round == 1 and "chikorita" or (round == 2 and "cyndaquil" or "totodile")
    events[#events + 1] = event("setSpriteClip", "starter-" .. starters[round], 56, 0, {
      sprite = starters[round],
      clip = clipPath(clips, bank, 0),
      species = SceneSources.starterSpecies(starters[round]),
    })
    show[#show + 1] = nextIndex(events)
    events[#events + 1] =
      event("spriteVisible", "starter-" .. starters[round], 56, 0, { sprite = starters[round], visible = true })
    show[#show + 1] = nextIndex(events)
    events[#events + 1] = event(
      "startEmitters",
      "starter-" .. starters[round],
      56,
      0,
      { group = groups[round], emitters = emitterIds[round] }
    )
    step(steps, "starter-" .. starters[round], show, { kind = "effect", effect = "emitters-" .. groups[round] })
    if round < 3 then
      local flip = { nextIndex(events) }
      events[#events + 1] = event(
        "setScreenRoles",
        "flip-" .. starters[round],
        56,
        0,
        round == 1 and { upper = "sub", lower = "main" } or { upper = "main", lower = "sub" }
      )
      step(steps, "flip-" .. starters[round], flip, { kind = "effect", effect = "emitters-" .. groups[round] })
    end
  end
  local finishTotodile = { nextIndex(events) }
  events[#events + 1] = event("setFade", "finish-totodile", 56, 0, { kind = "black-shutter-close", ticks = 26 })
  step(steps, "finish-totodile", finishTotodile, { kind = "effect", effect = "fade-close" })
  local sparkle = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] =
    event("setSpriteClip", "sparkle", 82, 0, { sprite = "sparkles", clip = clipPath(clips, "hands", 2) })
  events[#events + 1] = event("spriteVisible", "sparkle", 82, 0, { sprite = "sparkles", visible = true })
  step(steps, "sparkle", sparkle, { kind = "effect", effect = "sparkle-anim" })
  local done = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("waitEffects", "done", 82, 0, { effects = { "sparkle-anim" } })
  events[#events + 1] = event("finish", "done", 82, 0)
  step(steps, "done", done, { kind = "effect", effect = "sparkle-anim" })
  return steps, events
end

---@param versionId string
---@return table<string, unknown>[], table<string, unknown>[] steps and events
local function scene5Program(versionId)
  local direction = SceneSources.scene5ScrollDirection(versionId)
  local steps, events = {}, {}
  local wipe = { nextIndex(events) }
  events[#events + 1] = event("circleWipe", "wipe", 0, 0, { mode = "in", ticks = 18 })
  step(steps, "wipe", wipe, { kind = "duration", ticks = 18 })
  local scroll = {}
  scroll[#scroll + 1] = nextIndex(events)
  events[#events + 1] = event("waitEffects", "scroll", 18, 0, { effects = { "wipe-in" } })
  scroll[#scroll + 1] = nextIndex(events)
  events[#events + 1] =
    event("setScroll", "scroll", 18, 0, { layer = "main1", dx = 0, dy = -0x40, ticks = 73, direction = "up" })
  for _, layer in ipairs({ "main2", "sub1", "sub2" }) do
    scroll[#scroll + 1] = nextIndex(events)
    events[#events + 1] = event(
      "setScroll",
      "scroll",
      18,
      0,
      { layer = layer, dx = 0, dy = direction == "left" and -0x40 or 0x40, ticks = 73, direction = direction }
    )
  end
  step(steps, "scroll", scroll, { kind = "effect", effect = "scroll-panorama" })
  local wait = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("waitTicks", "wait", 91, 0, { ticks = 20 })
  events[#events + 1] = event("setFade", "wait", 91, 20, { kind = "white", ticks = 50 })
  step(steps, "wait", wait, { kind = "duration", ticks = 20 })
  local fade = { nextIndex(events), nextIndex(events) + 1 }
  events[#events + 1] = event("waitEffects", "fade", 111, 0, { effects = { "fade-white" } })
  events[#events + 1] = event("finish", "fade", 111, 0)
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
    steps, events = scene3Program(clips)
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
    initial = { screenRoles = "opening" },
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
