-- The fresh-New-Game-only source event initializer handoff: applies the
-- generated `_std_init` operations in source order to a finalized Oak
-- candidate's authoritative worldState before FieldState/FieldRuntime construct any
-- actor. It never creates a second event-state copy, never touches
-- player/profile/options, and never runs on Continue. The initializer is
-- producer-validated before publication (NewGameInitCacheWriter readback),
-- so runtime uses the published operations and initial location directly.

local NewGameInitCache = require("libs.assets.src.newgame.NewGameInitCache")

local NewGameInitialization = {}

---@param cacheFs table<string, unknown> selected epoch's installed generated view
---@return table<string, unknown> published startup initializer operations
local function loadArtifact(cacheFs)
  assert(type(cacheFs) == "table", "NewGameInitialization requires the installed generated view")
  local artifact = assert(
    cacheFs:loadLua(NewGameInitCache.path()),
    "fresh-game startup initializer is missing from the installed generated view"
  )
  assert(type(artifact) == "table", "fresh-game startup initializer is missing from the installed generated view")
  return artifact
end

local function validateU16(value)
  if type(value) ~= "number" or value ~= math.floor(value) or value < 0 or value > 0xFFFF then
    error("randomU16 must return an integer in 0..0xFFFF, got " .. tostring(value))
  end
  return value
end

local function defaultRandomU16()
  local v = love.math.random(0, 0xFFFF)
  return validateU16(v)
end

local function applyRollLotoId(operation, candidate, randomU16)
  local lowDraw = validateU16(randomU16())
  candidate.worldState:setVar(operation.lowVariableId, lowDraw)
  local highDraw = validateU16(randomU16())
  candidate.worldState:setVar(operation.lowVariableId, highDraw)
end

function NewGameInitialization.apply(candidate, artifactOrOptions)
  assert(type(candidate) == "table", "apply requires a candidate")
  assert(
    type(candidate.worldState) == "table"
      and type(candidate.worldState.setFlag) == "function"
      and type(candidate.worldState.setVar) == "function"
      and type(candidate.worldState.serialize) == "function",
    "apply requires a candidate with an authoritative worldState"
  )

  local artifact
  local randomU16
  local cacheFs
  if artifactOrOptions ~= nil then
    if
      type(artifactOrOptions) == "table"
      and (artifactOrOptions.artifact ~= nil or artifactOrOptions.randomU16 ~= nil or artifactOrOptions.cacheFs ~= nil)
    then
      artifact = artifactOrOptions.artifact
      randomU16 = artifactOrOptions.randomU16
      cacheFs = artifactOrOptions.cacheFs
    elseif
      type(artifactOrOptions) == "table" and (artifactOrOptions.operations ~= nil or artifactOrOptions.schema ~= nil)
    then
      artifact = artifactOrOptions
    end
  end
  artifact = artifact or loadArtifact(assert(cacheFs, "applying the startup initializer requires the generated view"))
  assert(type(artifact.operations) == "table", "fresh-game startup initializer artifact has no operations")

  if randomU16 ~= nil then
    assert(type(randomU16) == "function", "randomU16 must be a function")
  else
    randomU16 = defaultRandomU16
  end

  for _, operation in ipairs(artifact.operations) do
    if operation.op == "set_flag" then
      candidate.worldState:setFlag(operation.id)
    elseif operation.op == "roll_loto_id" then
      applyRollLotoId(operation, candidate, randomU16)
    else
      error("unsupported startup operation " .. tostring(operation.op))
    end
  end
  return candidate
end

--- Reads the generated initial player-room location for a fresh New Game.
--- Uses the published artifact record directly and returns a fresh
--- caller-owned copy of the location; a missing artifact fails loudly
--- instead of falling back to a default location.
---@param cacheFs table<string, unknown> selected epoch's installed generated view
---@return table<string, string|integer> location
function NewGameInitialization.initialLocation(cacheFs)
  local artifact = loadArtifact(cacheFs)
  local location = artifact.initialLocation
  assert(type(location) == "table", "fresh-game startup initializer cache has no initial location")
  return {
    mapSymbol = location.mapSymbol,
    fieldX = location.fieldX,
    fieldZ = location.fieldZ,
    facing = location.facing,
  }
end

return NewGameInitialization
