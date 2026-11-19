-- A presentation preparation queue stand-in: requests resolve to a
-- caller-supplied payload per kind, and `pending`/`failure` can be injected so
-- a staged build's yield and failure branches are reachable without a worker.
-- Models the exact request/poll/take/wait/cancel shape a staged owner consumes.

local FakePreparationQueue = {}

---@class FakePreparationQueue.Options
---@field pending boolean? every poll reports pending until the test publishes
---@field failure string? every poll reports this terminal failure
---@field payload (fun(kind: string, path: string): table<string, unknown>)?

---@param opts FakePreparationQueue.Options?
---@return table<string, unknown>
function FakePreparationQueue.new(opts)
  opts = opts or {}
  local queue = {
    pending = opts.pending == true,
    failure = opts.failure,
    requests = {},
    cancelled = 0,
    waited = 0,
  }
  local tokens = {}
  local nextToken = 0
  local function payloadFor(kind, path)
    if opts.payload ~= nil then
      return opts.payload(kind, path)
    end
    return {}
  end
  function queue:request(kind, path, priority)
    nextToken = nextToken + 1
    local token = nextToken
    self.requests[#self.requests + 1] = { kind = kind, path = path, priority = priority, token = token }
    tokens[token] = { kind = kind, path = path }
    return token
  end
  function queue:poll(token)
    assert(tokens[token], "unknown preparation token")
    if self.failure ~= nil then
      return "failed", self.failure
    end
    if self.pending then
      return "pending"
    end
    return "ready"
  end
  function queue:take(token)
    local record = assert(tokens[token], "take before ready")
    tokens[token] = nil
    return payloadFor(record.kind, record.path)
  end
  function queue:wait(token)
    self.waited = self.waited + 1
    assert(not self.pending, "a blocking wait never observes a pending fake")
    return self:take(token)
  end
  function queue:cancel(token)
    if tokens[token] ~= nil then
      tokens[token] = nil
      self.cancelled = self.cancelled + 1
    end
  end
  function queue:promote(_token, _priority) end
  function queue:release() end
  return queue
end

return FakePreparationQueue
