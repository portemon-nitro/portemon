-- Production composition for the Oak/profile introduction. It reads trusted
-- published generated assets, captures generated message templates, and
-- transfers audio and presentation ownership to the constructed Oak state.

local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local IntroAssetCache = require("libs.assets.src.newgame.IntroAssetCache")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldFontLoader = require("libs.hgss.src.ui.FieldFontLoader")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
local DialogueLayout = require("libs.hgss.src.ui.DialogueLayout")
local FieldDialogueController = require("libs.hgss.src.ui.FieldDialogueController")
local FieldDialogueRenderer = require("libs.hgss.src.ui.FieldDialogueRenderer")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local LocalClock = require("game.src.LocalClock")
local ImageAssetPool = require("libs.hgss.src.presentation.ImageAssetPool")
local OakIntroController = require("game.hgss.src.newgame.OakIntroController")
local OakIntroMessages = require("game.hgss.src.newgame.OakIntroMessages")
local OakIntroState = require("game.hgss.src.newgame.OakIntroState")
local GameAudio = require("game.hgss.src.audio.GameAudio")

local OakIntroComposition = {}

local MESSAGE_IDS = {
  ["greeting.morning"] = 1,
  ["greeting.day"] = 2,
  ["greeting.evening"] = 3,
  ["greeting.night"] = 4,
  ["greeting.midnight"] = 5,
  ["oak.welcome"] = 6,
  ["oak.world_inhabited"] = 34,
  ["oak.live_alongside"] = 35,
  ["oak.tell_about_yourself"] = 36,
  ["profile.gender_question"] = 37,
  ["profile.gender_confirm.male"] = 38,
  ["profile.gender_confirm.female"] = 39,
  ["profile.name_prompt"] = 40,
  ["profile.name_confirm.male"] = 41,
  ["profile.name_confirm.female"] = 42,
  ["profile.final"] = 43,
  ["choice.yes"] = 47,
  ["choice.no"] = 48,
}

local function mapMessages(getMessage, includeChoices)
  local messages = {}
  for key, messageId in pairs(MESSAGE_IDS) do
    if includeChoices or key ~= "choice.yes" and key ~= "choice.no" then
      local message = assert(getMessage(messageId))
      messages[key] = message
    end
  end
  return messages
end

function OakIntroComposition.messageKeys(messages)
  return mapMessages(function(messageId)
    return messages[messageId]
  end)
end

function OakIntroComposition.randomU32(mathHost)
  mathHost = mathHost or love.math
  assert(type(mathHost.random) == "function", "Oak intro requires love.math.random")
  local function randomValue()
    local high = mathHost.random(0, 0xFFFF)
    local low = mathHost.random(0, 0xFFFF)
    return high * 0x10000 + low
  end
  return randomValue
end

-- Intro visuals sample exactly as the manifest declares: the stretched
-- background filters linearly while widgets sample nearest, so pooled
-- borrows draw identically to the retired direct construction.
local POOLED_SAMPLERS = {
  linear = { wrapX = "clamp", wrapY = "clamp", minFilter = "linear", magFilter = "linear" },
  nearest = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" },
}

-- Collects every intro-only generated image behind its declared sampler:
-- the linear background plus each widget frame. First declaration wins
-- for a path named twice, matching the renderer's own first-load cache.
---@param manifest table<string, unknown> validated intro manifest
---@return { path: string, sampler: table<string, string> }[] ordered unique intro image demands
local function introImageDemands(manifest)
  local demands = {}
  local seen = {}
  local function add(path, sampling)
    if type(path) ~= "string" or path == "" or seen[path] then
      return
    end
    seen[path] = true
    demands[#demands + 1] = {
      path = path,
      sampler = POOLED_SAMPLERS[sampling] or POOLED_SAMPLERS.nearest,
    }
  end
  local background = manifest.background
  if type(background) == "table" then
    add(background.image, type(background.sampling) == "string" and background.sampling or "linear")
  end
  local widgets = manifest.widgets
  if type(widgets) == "table" then
    local ids = {}
    for id in pairs(widgets) do
      ids[#ids + 1] = id
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local asset = widgets[id]
      if type(asset) == "table" then
        local sampling = type(asset.sampling) == "string" and asset.sampling or "nearest"
        if type(asset.frames) == "table" then
          for _, frame in ipairs(asset.frames) do
            if type(frame) == "table" then
              add(frame.image, sampling)
            end
          end
        end
      end
    end
  end
  return demands
end

-- Builds the intro-only shared image owner and its generated-image loader.
-- Every manifest-declared intro image is enrolled before the first
-- readiness wait so independent classifications run concurrently; the
-- loader then borrows each path on demand and remembers every borrow for
-- the single release at intro teardown. The pool is intro-owned and
-- disposed independently of the prepared field entry beside it: intro
-- pixels never copy into a second buffer for the bedroom handoff.
---@param cacheFs table<string, unknown> versioned derived cache behind the intro manifest
---@param graphics table<string, unknown> host graphics namespace behind GPU realization
---@param manifest table<string, unknown> validated intro manifest
---@return table<string, unknown> intro-owned shared image owner
---@return table<string, unknown>[] borrow records behind every loader borrow, in order
---@return fun(path: string): unknown generated-image loader resolving pooled borrows
local function pooledImageLoader(cacheFs, graphics, manifest)
  local pool = ImageAssetPool.new(cacheFs, { graphics = graphics })
  -- Every manifest-declared intro image enrolls before the first
  -- readiness wait so independent classifications run concurrently.
  local samplers = {}
  local tokens = {}
  for _, demand in ipairs(introImageDemands(manifest)) do
    samplers[demand.path] = demand.sampler
    tokens[demand.path] = pool:request(demand.path, demand.sampler, "demand")
  end
  local leases = {}
  local images = {}
  -- The loader answers pool leases so renderers draw through the lease
  -- sampler surface with zero new imports; the borrow stays cached
  -- beside its lease for release bookkeeping.
  local function loadImage(path)
    assert(type(path) == "string" and path ~= "", "intro image loads name their path")
    local known = images[path]
    if known ~= nil then
      return known
    end
    local token = tokens[path]
    if token == nil then
      token = pool:request(path, samplers[path] or POOLED_SAMPLERS.nearest, "demand")
      tokens[path] = token
    end
    local stalled = 0
    while true do
      local status, failure = pool:poll(token)
      if status == "ready" then
        local lease = pool:acquire(token)
        assert(lease.image, "shared borrows carry their resolved image")
        leases[#leases + 1] = lease
        images[path] = lease
        return lease
      end
      if status == "failed" then
        error("intro image missing at " .. path .. ": " .. tostring(failure), 0)
      end
      assert(status == "pending", "intro preparation reports pending or ready")
      stalled = stalled + 1
      if stalled > 10000 then
        error("intro image stalled at " .. path, 0)
      end
      local timer = love and love.timer
      if timer ~= nil and timer.sleep ~= nil then
        timer.sleep(0.001)
      end
    end
  end
  return pool, leases, loadImage
end

local function validManifest(manifest, validate, name)
  local valid, err = validate(manifest)
  if not valid then
    error(err or (name .. " manifest is invalid"), 0)
  end
  return manifest
end

---@param options table<string, unknown>
---@return OakIntroState
function OakIntroComposition.compose(options)
  assert(type(options) == "table", "Oak intro composition requires options")
  assert(type(options.candidate) == "table", "Oak intro composition requires a candidate")
  assert(type(options.versionId) == "string", "Oak intro composition requires a version")
  local preparedEntry = options.preparedEntry
  if preparedEntry ~= nil then
    assert(
      type(preparedEntry) == "table"
        and type(preparedEntry.poll) == "function"
        and type(preparedEntry.dispose) == "function",
      "Oak prepared entry must provide poll and dispose"
    )
  end

  local cacheFs = CacheFs.forVersion(options.versionId)
  local introManifest = assert(cacheFs:loadLua(IntroAssetCache.manifestPath()))
  assert(
    type(introManifest) == "table" and introManifest.schemaVersion == IntroAssetCache.SCHEMA_VERSION,
    "intro manifest is unavailable"
  )
  local uiManifest = validManifest(assert(cacheFs:loadLua(FieldUiAssetCache.manifestPath())), function(manifest)
    return type(manifest) == "table" and manifest.schema == FieldUiAssetCache.SCHEMA
  end, "field UI")
  local fontDef = FieldFontLoader.load(cacheFs)
  local frameIndexes = {}
  for frame = 0, uiManifest.dialogueFrames.count - 1 do
    frameIndexes[frame] = true
  end
  local playerDataContext = { charmap = fontDef.charmap, frameIndexes = frameIndexes }

  local provider = FieldMessageProvider.new(cacheFs)
  local bankAcquired = false
  local audio
  local audioLifetime
  local textRenderer
  local choiceText
  local dialogueRenderer
  local imagePool
  local imageLeases
  local pooledLoader
  local ok, state = pcall(function()
    assert(provider:acquireBank(219))
    bankAcquired = true
    local messages = mapMessages(function(messageId)
      return assert(provider:get(219, messageId))
    end, true)
    provider:releaseBank(219)
    bankAcquired = false
    local messageFormatter = OakIntroMessages.new({ templates = messages, fontDef = fontDef })

    audio = GameAudio.compose({
      cacheFs = cacheFs,
      outputRate = 32768,
      outputHost = options.audioOutput,
    })
    local function disposeAudio(self)
      if self.disposed then
        return
      end
      self.disposed = true
      if audio.sink then
        audio.sink:release()
      end
    end
    audioLifetime = {
      dispose = disposeAudio,
    }

    local graphics = options.graphics or love.graphics
    ---@cast graphics love.graphics
    -- The intro stages its own image owner beside the prepared bedroom
    -- entry: intro pixels stay intro-owned and release at intro teardown,
    -- never copying into a second buffer for the field handoff. An
    -- injected loader keeps its own ownership and builds no pool here, so
    -- the eager text below keeps its direct construction on that seam.
    if options.imageLoader == nil then
      imagePool, imageLeases, pooledLoader = pooledImageLoader(cacheFs, graphics, introManifest)
    end
    textRenderer = FieldTextRenderer.new({ cacheFs = cacheFs, graphics = graphics, imagePool = imagePool })
    choiceText = FieldTextRenderer.new({ cacheFs = cacheFs, fontId = 4, graphics = graphics, imagePool = imagePool })
    dialogueRenderer = FieldDialogueRenderer.new({
      cacheFs = cacheFs,
      manifest = uiManifest,
      text = textRenderer,
      graphics = graphics,
      drawFocusIndicator = false,
      imagePool = imagePool,
    })
    local function layoutDialogue(formatted)
      return DialogueLayout.layout(
        formatted.tokens,
        FieldDialogueTheme.fontMetrics(fontDef),
        { width = FieldDialogueTheme.textWidth, maxLines = FieldDialogueTheme.maxLines }
      )
    end
    local dialogueController = FieldDialogueController.new({
      layout = layoutDialogue,
      audio = audio.sound,
      continueCursor = uiManifest.dialogueFrames.continueCursor,
    })
    local controller = OakIntroController.new({
      candidate = options.candidate,
      clock = options.clock or LocalClock.system(),
      audio = audio.sound,
      messages = messages,
      assets = introManifest,
      playerDataContext = playerDataContext,
      randomU32 = options.randomU32 or OakIntroComposition.randomU32(),
    })
    return OakIntroState.new({
      controller = controller --[[@as unknown]],
      preparedEntry = preparedEntry,
      manifest = introManifest,
      uiManifest = uiManifest,
      textRenderer = textRenderer,
      choiceText = choiceText,
      graphics = graphics,
      displayContext = options.displayContext,
      namingOverrides = options.namingOverrides,
      imageLoader = options.imageLoader or pooledLoader,
      imagePool = imagePool,
      ownsImagePool = imagePool ~= nil,
      imageLeases = imageLeases or {},
      textInputHost = options.textInputHost,
      width = options.width,
      height = options.height,
      onComplete = options.onComplete,
      audioSink = audio.sink --[[@as OakIntroStateAudioSink?]],
      audioLifetime = audioLifetime,
      dialogueController = dialogueController,
      dialogueRenderer = dialogueRenderer,
      dialogueText = textRenderer,
      dialogueFormatter = messageFormatter,
      dialogueCursorPlacement = uiManifest.dialogueFrames.continueCursor.placement,
      screenTopology = options.screenTopology,
    })
  end)
  if not ok then
    if bankAcquired then
      pcall(provider.releaseBank, provider, 219)
    end
    if audioLifetime then
      audioLifetime:dispose()
    elseif audio and audio.sink then
      audio.sink:release()
    end
    if dialogueRenderer then
      pcall(dialogueRenderer.release, dialogueRenderer)
    end
    if textRenderer then
      pcall(textRenderer.release, textRenderer)
    end
    if choiceText then
      pcall(choiceText.release, choiceText)
    end
    if imagePool ~= nil then
      -- Renderer teardown above already released loader images it owned;
      -- returning the borrows here is bookkeeping-only and safe to
      -- repeat. The pool teardown below joins its worker before dropping
      -- bookkeeping, so its secondary release noise (if any) stays
      -- contained while the original composition failure propagates.
      for _, lease in ipairs(imageLeases or {}) do
        imagePool:release(lease)
      end
      pcall(imagePool.dispose, imagePool)
    end
    error(state, 0)
  end
  return state
end

return OakIntroComposition
