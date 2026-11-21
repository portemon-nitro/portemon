-- Acceptance-only observation of a source transport that a foreground script
-- owns: the per-tick player and follower world positions while that script
-- holds the field, so a scenario can assert source travel, arrivals, heights
-- and audio without reaching into the mechanism. It drives ordinary fixed
-- ticks through the production runtime and never assembles field internals.

local TransportTrace = {}

---@class TransportTrace.Sample
---@field x number
---@field y number
---@field z number
---@field fieldX integer
---@field fieldZ integer
---@field motion string
---@field follower { x: number, y: number, z: number, fieldX: integer, fieldZ: integer }|nil
---@field followerActorId string|nil

-- The partner actor identity the follower owner publishes.
local PARTNER_ACTOR = "field:partner"

local function followerOf(snapshot)
  local actor = snapshot.actors and snapshot.actors[PARTNER_ACTOR] or nil
  if actor == nil then
    return nil
  end
  return { fieldX = actor.fieldX, fieldZ = actor.fieldZ }
end

local function sampleOf(game, snapshot)
  local player = snapshot.player
  local follower = followerOf(snapshot)
  local followerWorld = nil
  if follower ~= nil then
    for _, record in ipairs(game.runtime.actors:drawRecords()) do
      if record.actorId == PARTNER_ACTOR then
        followerWorld = { x = record.world.x, y = record.world.y, z = record.world.z }
        break
      end
    end
  end
  return {
    x = player.worldX,
    y = player.worldY,
    z = player.worldZ,
    fieldX = player.fieldX,
    fieldZ = player.fieldZ,
    motion = player.motion,
    follower = followerWorld and {
      x = followerWorld.x,
      y = followerWorld.y,
      z = followerWorld.z,
      fieldX = follower.fieldX,
      fieldZ = follower.fieldZ,
    } or nil,
    followerActorId = follower and PARTNER_ACTOR or nil,
  }
end

-- Waits for a foreground script to claim the field, then samples every fixed
-- tick until it releases the field (or `options.stopWhen(snapshot)` answers
-- true). Returns the samples in tick order; the first sample is the claim
-- tick and the last is the first released tick.
---@param game table
---@param options { label: string, claimTicks: integer?, settleTicks: integer?, stopWhen: (fun(snapshot: table): boolean)?, onTick: (fun(snapshot: table): void)? }
---@return TransportTrace.Sample[]
function TransportTrace.observe(game, options)
  assert(type(options) == "table" and type(options.label) == "string", "transport observation needs a label")
  local claim = game:advanceUntil(options.label .. " claims the field", function(snapshot)
    return snapshot.fieldLocked
  end, options.claimTicks or 240)
  local samples = { sampleOf(game, claim) }
  local settle = options.settleTicks or 1200
  for _ = 1, settle do
    if options.stopWhen ~= nil and options.stopWhen(game:snapshot()) then
      break
    end
    local snapshot = game:step()
    samples[#samples + 1] = sampleOf(game, snapshot)
    if options.onTick ~= nil then
      options.onTick(snapshot)
    end
    if not snapshot.fieldLocked then
      break
    end
  end
  return samples
end

-- Total travelled distance in tiles over the sampled world positions.
---@param samples TransportTrace.Sample[]
---@return number
function TransportTrace.travel(samples)
  local total = 0
  for index = 2, #samples do
    local previous, current = samples[index - 1], samples[index]
    local dx, dz = current.x - previous.x, current.z - previous.z
    total = total + math.sqrt(dx * dx + dz * dz)
  end
  return total
end

-- Per-axis extent of the sampled world positions, in tiles.
---@param samples TransportTrace.Sample[]
---@return { x: number, z: number }
function TransportTrace.span(samples)
  local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
  for _, sample in ipairs(samples) do
    minX, maxX = math.min(minX, sample.x), math.max(maxX, sample.x)
    minZ, maxZ = math.min(minZ, sample.z), math.max(maxZ, sample.z)
  end
  return { x = maxX - minX, z = maxZ - minZ }
end

-- Consecutive height changes in tiles, in tick order.
---@param samples TransportTrace.Sample[]
---@return number[]
function TransportTrace.heightSteps(samples)
  local steps = {}
  for index = 2, #samples do
    steps[#steps + 1] = samples[index].y - samples[index - 1].y
  end
  return steps
end

---@param samples TransportTrace.Sample[]
---@return number
function TransportTrace.firstHeight(samples)
  return samples[1].y
end

---@param samples TransportTrace.Sample[]
---@return number
function TransportTrace.lastHeight(samples)
  return samples[#samples].y
end

return TransportTrace
