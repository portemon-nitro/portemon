-- A synchronous stand-in for the selected presentation preparation worker over
-- a physical fixture cache: every request realizes the same packed upload shape
-- the worker publishes for those fixture bytes, so the real GPU pool and staged
-- scene builds consume a lease exactly like they do in production. The paired
-- decoded owner accepts the lease return; it holds no kernel because nothing is
-- coalesced across requests here.

local SceneMesh = require("libs.hgss.src.presentation.SceneMesh")

local ScenePreparationFixture = {}

---@class ScenePreparationFixture.Queue
---@field requests { kind: string, path: string, priority: string }[] every request in dispatch order

---@param cacheFs table<string, unknown> fixture cache serving geometry payloads
---@return ScenePreparationFixture.Queue queue
---@return { returnLease: fun(self: table, lease: table): boolean, trim: fun(self: table) } decoded
function ScenePreparationFixture.new(cacheFs)
  assert(type(cacheFs) == "table" and type(cacheFs.read) == "function", "a fixture cache serves prepared geometry")
  ---@type ScenePreparationFixture.Queue
  local queue = { requests = {} }
  local tokens = {}
  local nextToken = 0

  ---@param token { kind: string, path: string }
  ---@return table<string, unknown> borrowed lease over the prepared payload
  local function realize(token)
    local bytes = assert(cacheFs:read(token.path), "missing fixture geometry " .. tostring(token.path))
    local payload = token.kind == "g4gx" and SceneMesh.prepareNativeBank(bytes) or SceneMesh.prepareUpload(bytes)
    return { value = { kind = token.kind, payload = payload } }
  end

  function queue:request(kind, path, priority)
    nextToken = nextToken + 1
    local token = { token = nextToken, kind = kind, path = path }
    tokens[nextToken] = token
    self.requests[#self.requests + 1] = token
    return nextToken
  end

  function queue:poll(token)
    assert(tokens[token] ~= nil, "unknown preparation token")
    return "ready"
  end

  function queue:take(token)
    local record = assert(tokens[token], "take before request")
    tokens[token] = nil
    return realize(record)
  end

  function queue:wait(token)
    return self:take(token)
  end

  function queue:cancel(token)
    if tokens[token] == nil then
      return false
    end
    tokens[token] = nil
    return true
  end

  function queue:promote(token, priority)
    local record = tokens[token]
    if record ~= nil then
      record.priority = priority
    end
  end

  function queue:release() end

  function queue:acquireSource(reference)
    local lease = { value = assert(reference and reference.data, "a source acquisition needs a resolved reference") }
    function lease:release()
      self.value = nil
    end
    return lease
  end

  local decoded = {}
  function decoded:returnLease(_)
    return true
  end
  function decoded:trim() end
  return queue, decoded
end

return ScenePreparationFixture
