-- Controllable stand-in for the session-scoped shared image owner that
-- borrowing renderers and staged scene builds code against: logical requests
-- resolve to one physical image per reference plus immutable sampler state,
-- borrowers hold explicit leases, and the worker reply stays withheld until the
-- test publishes it, so an owner can be suspended on exactly one ticket.
--
-- A settled payload is charged to the ready budget until it is acquired or
-- dropped, and every cancellation is recorded, so a test can prove which ticket
-- an owner dropped, that it dropped it exactly once, and that no unclaimed
-- packet stayed charged. Nothing here touches love or a worker; uploads are
-- counted instead of realized.

local ControllableImageOwner = {}
ControllableImageOwner.__index = ControllableImageOwner

-- One reference as a stable identity: a PNG path, or the named texel/palette
-- pair a native texture-bank selector carries.
---@param source string|table
---@return string
local function sourceIdentity(source)
  if type(source) == "string" then
    return source
  end
  return string.format("%s#%s#%s", tostring(source.file), tostring(source.textureName), tostring(source.paletteName))
end

local function fakeImage()
  local image = { released = false, releaseCount = 0 }
  function image:release()
    self.released = true
    self.releaseCount = self.releaseCount + 1
  end
  return image
end

---@class ControllableImageOwner.Ticket
---@field key string physical identity
---@field source string reference identity the per-path holds name
---@field state string "staged" while the worker is busy, then "ready"
---@field held boolean global hold captured when the request was made
---@field published boolean an explicit worker reply outranks a per-path hold

---@class ControllableImageOwner.Options
---@field payloadBytes integer? ready-payload weight charged until taken or dropped
---@field held boolean? withhold every request until the test publishes it

---@class ControllableImageOwner
---@field requests { token: integer, path: string|table, priority: string, wrapX: string, wrapY: string }[]
---@field cancelCalls integer[] tokens in cancellation order
---@field withheld table<string, boolean> per-path holds the test may clear
---@field held boolean global hold on every request
---@field uploads integer physical images constructed so far
---@field readyBytes integer payload weight currently charged to the budget
---@field payloadBytes integer weight one settled payload charges
---@field releasedLeases integer leases returned so far
---@field _physicals table<string, { image: table, leases: integer }>

---@param opts ControllableImageOwner.Options?
---@return ControllableImageOwner
function ControllableImageOwner.new(opts)
  opts = opts or {}
  return setmetatable({
    requests = {},
    cancelCalls = {},
    withheld = {},
    held = opts.held ~= false,
    uploads = 0,
    readyBytes = 0,
    payloadBytes = opts.payloadBytes or 2048,
    releasedLeases = 0,
    failAfter = nil,
    failMessage = nil,
    _failure = nil,
    _nextToken = 0,
    _tickets = {},
    _physicals = {},
    -- The borrowed CPU preparation a real session image owner exposes to the
    -- scene GPU pool; texture-only fixtures never read through it.
    _preparation = { queue = {}, decoded = {} },
  }, ControllableImageOwner)
end

-- The stable borrowed CPU-owner record the scene GPU pool resolves when it
-- has no explicit pair.
---@return { queue: table, decoded: table }
function ControllableImageOwner:preparation()
  return self._preparation
end

-- One worker result becomes a ready payload exactly once: the budget charge
-- mirrors the owner that keeps the packet until it is acquired or cancelled.
---@param ticket ControllableImageOwner.Ticket
function ControllableImageOwner:_settle(ticket)
  if ticket.state == "staged" then
    ticket.state = "ready"
    self.readyBytes = self.readyBytes + self.payloadBytes
  end
end

---@param path string|table
---@param sampler table<string, string>
---@param priority string
---@return integer token
function ControllableImageOwner:request(path, sampler, priority)
  assert(
    type(sampler) == "table" and sampler.wrapX ~= nil and sampler.wrapY ~= nil,
    "shared image request needs sampler state"
  )
  self._nextToken = self._nextToken + 1
  local token = self._nextToken
  self.requests[#self.requests + 1] = {
    token = token,
    path = path,
    priority = priority,
    wrapX = sampler.wrapX,
    wrapY = sampler.wrapY,
  }
  self._tickets[token] = {
    key = sourceIdentity(path) .. "|" .. sampler.wrapX .. "|" .. sampler.wrapY,
    source = sourceIdentity(path),
    state = "staged",
    held = self.held,
    published = false,
  }
  return token
end

-- Declare one staged ticket a current need. The controllable owner stages
-- synchronously, so promotion changes no scheduling; it exists so the promoter
-- capability production composes is modeled here too.
---@param token integer
function ControllableImageOwner:promote(token)
  assert(self._tickets[token] ~= nil, "unknown controllable image token")
end

---@param token integer
---@return string status "pending", "ready", or "failed"
---@return string? cause failure message
function ControllableImageOwner:poll(token)
  local ticket = assert(self._tickets[token], "unknown shared image ticket")
  if self._failure ~= nil then
    return "failed", self._failure
  end
  if self.failAfter ~= nil and self.uploads >= self.failAfter then
    return "failed", self.failMessage or "injected shared image failure"
  end
  if not ticket.published and (ticket.held or self.withheld[ticket.source] == true) then
    return "pending"
  end
  self:_settle(ticket)
  return "ready"
end

-- The worker reply for one withheld ticket, or for every withheld ticket when
-- omitted. Reports false for a token the owner already dropped, exactly like a
-- late reply the real owner discards.
---@param token integer?
---@return boolean published
function ControllableImageOwner:publish(token)
  if self._failure ~= nil then
    return false
  end
  if token ~= nil then
    local ticket = self._tickets[token]
    if ticket == nil then
      return false
    end
    ticket.published = true
    self:_settle(ticket)
    return true
  end
  self.held = false
  for _, ticket in pairs(self._tickets) do
    ticket.held = false
    self:_settle(ticket)
  end
  return true
end

-- Withhold one path from now on, independent of the global hold: a test can
-- release paths selectively while the rest of the build stays warm.
---@param path string
function ControllableImageOwner:withhold(path)
  self.withheld[path] = true
end

-- Every poll from the next upload threshold on reports this failure.
---@param count integer
---@param message string?
function ControllableImageOwner:failAfterUploads(count, message)
  self.failAfter = count
  self.failMessage = message
end

-- Every poll reports this failure immediately.
---@param message string
function ControllableImageOwner:failNow(message)
  self._failure = message
end

-- Drop the injected failure so a test can prove an independent retry after a
-- failed borrow still succeeds.
function ControllableImageOwner:clearFailure()
  self._failure = nil
  self.failAfter = nil
  self.failMessage = nil
end

---@param token integer
---@return table lease
function ControllableImageOwner:acquire(token)
  local ticket = assert(self._tickets[token], "unknown shared image ticket")
  assert(ticket.state == "ready", "shared image ticket is not ready")
  self._tickets[token] = nil
  self.readyBytes = self.readyBytes - self.payloadBytes
  local physical = self._physicals[ticket.key]
  if physical == nil then
    physical = { image = fakeImage(), leases = 0 }
    self._physicals[ticket.key] = physical
    self.uploads = self.uploads + 1
  end
  physical.leases = physical.leases + 1
  return { image = physical.image, palette = nil, kind = "rgba8", _key = ticket.key, _owner = self, _released = false }
end

-- Dropping interest: a staged, ready, or absent ticket all answer with the
-- recorded call, so a test can prove the owner asked exactly once.
---@param token integer
---@return boolean cancelled true when a live ticket was dropped
function ControllableImageOwner:cancel(token)
  self.cancelCalls[#self.cancelCalls + 1] = token
  local ticket = self._tickets[token]
  if ticket == nil then
    return false
  end
  self._tickets[token] = nil
  if ticket.state == "ready" then
    self.readyBytes = self.readyBytes - self.payloadBytes
  end
  return true
end

---@param lease table
---@return boolean released false for a repeated release
function ControllableImageOwner:release(lease)
  assert(lease ~= nil and lease._owner == self, "image lease belongs to another owner")
  if lease._released then
    return false
  end
  lease._released = true
  self.releasedLeases = self.releasedLeases + 1
  local physical = assert(self._physicals[lease._key], "physical image left the owner under its lease")
  physical.leases = physical.leases - 1
  return true
end

-- Live requests the owner still holds: staged or ready tickets that no
-- acquisition or cancellation dropped, the census a rolled-back borrower must
-- leave empty.
---@return integer
function ControllableImageOwner:outstandingTickets()
  local total = 0
  for _ in pairs(self._tickets) do
    total = total + 1
  end
  return total
end

-- The live physical image for one reference plus sampler, or nil when that
-- identity was never published.
---@param path string|table
---@param sampler table<string, string>
---@return table<string, unknown>?
function ControllableImageOwner:findPhysical(path, sampler)
  local physical = self._physicals[sourceIdentity(path) .. "|" .. sampler.wrapX .. "|" .. sampler.wrapY]
  return physical and physical.image or nil
end

---@return integer
function ControllableImageOwner:outstandingLeases()
  local total = 0
  for _, physical in pairs(self._physicals) do
    total = total + physical.leases
  end
  return total
end

return ControllableImageOwner
