-- FieldAudio: the production field-audio composition. It adds HGSS field
-- policy around the shared audio runtime and application output sink.

local GameAudio = require("game.hgss.src.audio.GameAudio")

local FieldAudio = {}

---@class FieldAudioComposeOptions
---@field cacheFs CacheFs
---@field outputRate integer
---@field eventState unknown
---@field fieldPosition fun(): integer, integer
---@field dayNight fun(): "day"|"night"
---@field fieldDataForMap fun(mapIdOrSymbol: integer|string): unknown
---@field traversal (fun(): string)? the avatar's durable traversal mode, read for traversal music
---@field outputHost table<string, unknown>|nil
---@field channelMode string? the selected save's output channel mode, carried to the sink
---@field assetPreparation table<string, unknown>? shared preparation queue of the selected runtime
---@field acquireSource fun(reference: ResidentCache.BlobRef): table<string, unknown>? selected runtime's resident source acquirer

---@class FieldAudioComposition
---@field service FieldAudioController
---@field sink LoveAudioSink|nil
---@field dispose fun(self: FieldAudioComposition)

---@param opts FieldAudioComposeOptions
---@return FieldAudioComposition
function FieldAudio.compose(opts)
  assert(
    opts
      and opts.cacheFs
      and opts.outputRate
      and opts.eventState
      and opts.fieldPosition
      and opts.dayNight
      and opts.fieldDataForMap,
    "FieldAudio.compose requires cacheFs, outputRate, eventState, fieldPosition, dayNight, and fieldDataForMap"
  )
  ---@cast opts +{ outputHost: table<string, unknown>|nil }
  local core = GameAudio.compose({
    cacheFs = opts.cacheFs,
    outputRate = opts.outputRate,
    outputHost = opts.outputHost,
    channelMode = opts.channelMode,
    assetPreparation = opts.assetPreparation,
    acquireSource = opts.acquireSource,
    field = {
      eventState = opts.eventState,
      fieldPosition = opts.fieldPosition,
      dayNight = opts.dayNight,
      fieldDataForMap = opts.fieldDataForMap,
      traversal = opts.traversal,
    },
  })
  local service = core.fieldService
  if service == nil then
    -- A core without its field policy service is a construction failure: unwind
    -- the fully composed core instead of leaking its voices and sink.
    core:dispose()
    error("FieldAudio.compose requires the field audio policy service", 0)
  end
  local composition = { service = service, sink = core.sink }
  -- The wrapper borrows the core's ownership: disposing the field audio
  -- composition disposes the complete GameAudio composition, not only its sink.
  function composition:dispose()
    core:dispose()
  end
  ---@cast composition FieldAudioComposition
  return composition
end

return FieldAudio
