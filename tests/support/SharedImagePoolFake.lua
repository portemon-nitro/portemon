-- Deterministic stand-in for the session-scoped shared GPU image owner used
-- by field scene acceptance tests. Logical texture requests resolve to one
-- physical image per texture path plus immutable sampler state, borrowers
-- hold explicit leases, and the last returned lease leaves the physical
-- image idle until prune reclaims it exactly once. Returned leases expose
-- the borrowed image on `.image`, matching the borrowing contract scene
-- owners code against, and carry the production pool-lease draw surface
-- (`draw`/`drawQuad` through the shared exact sampler) so renderer tests
-- exercise the same draw path as production. Nothing here touches love or
-- a worker; uploads are counted so tests can prove a texture resolved once
-- across scenes.

local ImageAssetPool = require("libs.hgss.src.presentation.ImageAssetPool")

---@class SharedImagePoolFake.Physical
---@field image table<string, unknown>
---@field leases integer
---@field path string
---@field sampler table<string, string>

---@class SharedImagePoolFake
---@field uploads integer physical images constructed so far
local SharedImagePoolFake = {}
SharedImagePoolFake.__index = SharedImagePoolFake

-- One physical identity: the texture path plus the full immutable sampler
-- state, so identical pixels sampled differently never alias.
---@param path string
---@param sampler table<string, string>
---@return string
local function keyFor(path, sampler)
  return table.concat({
    path,
    "|",
    sampler.wrapX,
    "|",
    sampler.wrapY,
    "|",
    sampler.minFilter or "nearest",
    "|",
    sampler.magFilter or "nearest",
  }, "")
end

local function fakeImage()
  local image = { released = false, releaseCount = 0 }
  function image:setFilter() end
  function image:setWrap() end
  function image:release()
    self.released = true
    self.releaseCount = self.releaseCount + 1
  end
  return image
end

---@return SharedImagePoolFake
function SharedImagePoolFake.new()
  return setmetatable(
    { uploads = 0, _requests = {}, _nextToken = 0, _physicals = {}, _failAfter = nil },
    SharedImagePoolFake
  )
end

-- Fail staged requests once the pool has published `count` physical images:
-- poll reports "failed" with `message` instead of staging further
-- textures, so a borrowing scene can prove its construction rollback
-- returns already-borrowed leases and publishes nothing new. Clear with
-- clearFailure; requests staged before the threshold stay acquirable.
---@param count integer
---@param message string?
function SharedImagePoolFake:failAfterUploads(count, message)
  assert(type(count) == "number" and count >= 0 and count % 1 == 0, "failure threshold is required")
  self._failAfter = { count = count, message = message or "injected shared image failure" }
end

function SharedImagePoolFake:clearFailure()
  self._failAfter = nil
end

-- Record logical interest in one texture under one immutable sampler state.
-- Returns an opaque token; the fake stages synchronously, so poll is ready.
---@param logicalPath string
---@param sampler table<string, string>
---@param _priority string?
---@return integer
function SharedImagePoolFake:request(logicalPath, sampler, _priority)
  assert(type(logicalPath) == "string", "shared image request path is required")
  assert(
    type(sampler) == "table" and type(sampler.wrapX) == "string" and type(sampler.wrapY) == "string",
    "shared image request needs an immutable sampler state"
  )
  self._nextToken = self._nextToken + 1
  local token = self._nextToken
  self._requests[token] = { state = "staged", physicalKey = keyFor(logicalPath, sampler) }
  return token
end

---@param token integer
---@return string status "ready", "failed" once the failure threshold tripped
---@return string? failure the injected failure message when status is "failed"
function SharedImagePoolFake:poll(token)
  local request = assert(self._requests[token], "unknown image request token")
  if request.state == "cancelled" then
    error("image request was cancelled", 0)
  end
  if request.state == "staged" and self._failAfter ~= nil and self.uploads >= self._failAfter.count then
    return "failed", self._failAfter.message
  end
  return "ready"
end

-- Borrow one staged request as an immutable lease record. The first request
-- for an identity constructs its physical image; later compatible requests
-- adopt the live image, so identical textures under matching sampler state
-- resolve to one image. Fails loudly before staging, after cancellation, or
-- on double acquisition of the same token.
---@param token integer
---@return table<string, unknown>
function SharedImagePoolFake:acquire(token)
  local request = assert(self._requests[token], "unknown image request token")
  if request.state == "cancelled" then
    error("image request was cancelled", 0)
  end
  if request.state == "acquired" then
    error("image request token is already acquired", 0)
  end
  assert(request.state == "staged", "image request is not ready: " .. tostring(request.state))
  local key = assert(request.physicalKey, "staged image request has no physical identity")
  local physical = self._physicals[key]
  if physical == nil then
    physical = { image = fakeImage(), leases = 0 }
    self._physicals[key] = physical
    self.uploads = self.uploads + 1
  end
  physical.leases = physical.leases + 1
  request.state = "acquired"
  return setmetatable({
    image = physical.image,
    palette = physical.palette,
    kind = physical.kind,
    width = physical.width,
    height = physical.height,
    physicalKey = key,
    _pool = self,
    _released = false,
  }, ImageAssetPool.Lease)
end

-- Drop logical interest in one request that never reached a lease.
-- Staged-but-unacquired records are forgotten; already-acquired tokens
-- keep their record for outstanding leases, so cancellation reports false
-- and changes nothing. Unknown tokens report false. Total: never fails.
---@param token integer
---@return boolean true when interest was dropped
function SharedImagePoolFake:cancel(token)
  local request = self._requests[token]
  if request == nil then
    return false
  end
  if request.state == "acquired" then
    return false
  end
  self._requests[token] = nil
  return true
end

-- Return one lease borrow. The first return releases the borrow and reports
-- true; repeating it reports false without side effects. A lease from
-- another pool fails loudly. The physical image stays resident (idle) once
-- its last lease returns; prune reclaims idle images.
---@param lease table<string, unknown>
---@return boolean
function SharedImagePoolFake:release(lease)
  assert(lease ~= nil and lease._pool == self, "image lease belongs to another pool")
  if lease._released then
    return false
  end
  lease._released = true
  local physical = assert(self._physicals[lease.physicalKey], "physical image left the pool under its lease")
  physical.leases = physical.leases - 1
  assert(physical.leases >= 0, "image lease returned more times than it was acquired")
  return true
end

-- Reclaim every physical image with no outstanding lease, oldest request
-- order is irrelevant to this fake; borrowed images stay resident.
-- Reports the evicted count.
---@return integer
function SharedImagePoolFake:prune()
  local evicted = 0
  for key, physical in pairs(self._physicals) do
    if physical.leases == 0 then
      physical.image:release()
      self._physicals[key] = nil
      evicted = evicted + 1
    end
  end
  return evicted
end

-- Cancel every unstaged request and release retained physical images
-- exactly once. Late acquisitions afterwards fail loudly.
function SharedImagePoolFake:dispose()
  for _, request in pairs(self._requests) do
    if request.state == "staged" then
      request.state = "cancelled"
    end
  end
  for key, physical in pairs(self._physicals) do
    physical.image:release()
    self._physicals[key] = nil
  end
end

-- Census for ownership assertions: live physical images and outstanding
-- lease borrows.
---@return { physicalImages: integer, outstandingLeases: integer }
function SharedImagePoolFake:stats()
  local physicalImages, outstandingLeases = 0, 0
  for _, physical in pairs(self._physicals) do
    physicalImages = physicalImages + 1
    outstandingLeases = outstandingLeases + physical.leases
  end
  return { physicalImages = physicalImages, outstandingLeases = outstandingLeases }
end

-- The live physical image for one texture path plus sampler, or nil when
-- that identity was never published or was already pruned.
---@param path string
---@param sampler table<string, string>
---@return table<string, unknown>?
function SharedImagePoolFake:findPhysical(path, sampler)
  local physical = self._physicals[keyFor(path, sampler)]
  return physical and physical.image or nil
end

return SharedImagePoolFake
