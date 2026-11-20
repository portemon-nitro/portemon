-- A presentation preparation queue stand-in: requests resolve to a
-- caller-supplied payload per kind, and `pending`/`failure` can be injected so
-- a staged build's yield and failure branches are reachable without a worker.
-- Models the exact request/poll/take/wait/cancel shape a staged owner consumes.
-- `deferred` withholds every request until the test publishes it, so an owner
-- can be suspended on one specific ticket; `publish` then models the worker
-- reply and reports false for a ticket whose owner already dropped it. Polls,
-- promotions, cancellations, and ready-payload bytes are recorded so a test can
-- prove who waited, who spun, and who paid for an unclaimed packet. The
-- outstanding-ticket census mirrors the real queue: a terminal failure result
-- and a throwing wait both leave the ticket owned by the caller.

local FakePreparationQueue = {}

---@class FakePreparationQueue.Options
---@field pending boolean? every poll reports pending until the test publishes
---@field failure string? every poll reports this terminal failure
---@field deferred boolean? every request stays pending until the test publishes it
---@field payloadBytes integer? ready-payload weight charged until taken or cancelled
---@field pollLimit integer? polls allowed before the fake reports a spinning owner
---@field payload (fun(kind: string, path: string): table<string, unknown>)?

---@param opts FakePreparationQueue.Options?
---@return table<string, unknown>
function FakePreparationQueue.new(opts)
  opts = opts or {}
  local queue = {
    pending = opts.pending == true,
    failure = opts.failure,
    requests = {},
    cancelCalls = {},
    waited = 0,
    polls = 0,
    promotions = {},
    payloadBytes = opts.payloadBytes or 4096,
    readyBytes = 0,
  }
  local deferred = opts.deferred == true
  local pollFault = nil
  local tokens = {}
  local nextToken = 0
  local function payloadFor(kind, path)
    if opts.payload ~= nil then
      return opts.payload(kind, path)
    end
    return {}
  end
  -- A published result charges the ready-payload budget the real queue keeps
  -- until the payload is taken (or dropped with the ticket).
  local function settle(record)
    if record.state == "queued" then
      record.state = "ready"
      queue.readyBytes = queue.readyBytes + queue.payloadBytes
    end
  end
  function queue:request(kind, path, priority)
    nextToken = nextToken + 1
    local token = nextToken
    self.requests[#self.requests + 1] = { kind = kind, path = path, priority = priority, token = token }
    local record = { kind = kind, path = path, state = "queued", held = deferred }
    tokens[token] = record
    if not (self.pending or record.held) then
      settle(record)
    end
    return token
  end
  function queue:poll(token)
    self.polls = self.polls + 1
    if pollFault ~= nil then
      error(pollFault, 0)
    end
    if opts.pollLimit ~= nil and self.polls > opts.pollLimit then
      error("preparation poll budget exceeded after " .. self.polls .. " polls", 0)
    end
    local record = assert(tokens[token], "unknown preparation token")
    if self.failure ~= nil then
      return "failed", self.failure
    end
    if self.pending or record.held then
      return "pending"
    end
    settle(record)
    return "ready"
  end
  function queue:take(token)
    local record = assert(tokens[token], "take before ready")
    assert(record.state == "ready", "preparation result is not ready")
    tokens[token] = nil
    self.readyBytes = self.readyBytes - self.payloadBytes
    return payloadFor(record.kind, record.path)
  end
  function queue:wait(token)
    self.waited = self.waited + 1
    assert(not self.pending, "a blocking wait never observes a pending fake")
    local record = assert(tokens[token], "wait before request")
    record.held = false
    settle(record)
    return self:take(token)
  end
  function queue:cancel(token)
    self.cancelCalls[#self.cancelCalls + 1] = token
    local record = tokens[token]
    if record == nil then
      return false
    end
    tokens[token] = nil
    if record.state == "ready" then
      self.readyBytes = self.readyBytes - self.payloadBytes
    end
    return true
  end
  function queue:promote(token, priority)
    self.promotions[#self.promotions + 1] = { token = token, priority = priority }
    local record = tokens[token]
    if record ~= nil then
      record.priority = priority
    end
  end
  -- The worker reply for one withheld ticket. Reports false when the owner
  -- already dropped its interest, exactly like a late reply the queue discards.
  function queue:publish(token)
    local record = tokens[token]
    if record == nil then
      return false
    end
    record.held = false
    if self.pending or self.failure ~= nil then
      return false
    end
    settle(record)
    return true
  end
  -- Make every poll raise while keeping the tickets live: a queue-level fault
  -- under a suspended owner, not a per-ticket failure result.
  function queue:failPoll(message)
    pollFault = message
  end
  -- Live tickets the queue still holds for an owner: queued, running, or
  -- ready records that no take, wait, or cancel consumed, the census an
  -- abandoned build must leave empty.
  ---@return integer
  function queue:outstandingTickets()
    local total = 0
    for _ in pairs(tokens) do
      total = total + 1
    end
    return total
  end
  function queue:release() end
  return queue
end

return FakePreparationQueue
