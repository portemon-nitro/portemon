-- In-memory staged-effect service double for the lazy battle-effect
-- acceptance coverage. A programmable staged store (effect records, markers,
-- payloads) is served through the four selected-effect service callbacks plus
-- drawable registration with refcounted fake GPU handles. The double mirrors
-- the production holder contract without parsing source or touching the GPU:
-- false while pending, schema-valid records only after readiness, shared
-- immutable handles across duplicate resolves, exactly-once release, and
-- terminal contextual failures that never masquerade as pending. Fake GPU
-- handles are plain records; only the graphics-layer suites prove real
-- driver upload and native pixels.

local BattleAnimationSchema = require("libs.assets.src.battle.BattleAnimationSchema")

local Fixture = {}
Fixture.__index = Fixture

-- Builds one raw RGBA8888 payload: a single opaque red pixel at the origin
-- over transparent black, so placement and transparency stay exact.
---@param width integer positive staged width
---@param height integer positive staged height
---@return string raw RGBA bytes
function Fixture.rgba(width, height)
  assert(type(width) == "number" and width % 1 == 0 and width > 0, "staged widths are positive integers")
  assert(type(height) == "number" and height % 1 == 0 and height > 0, "staged heights are positive integers")
  local parts = {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      if x == 0 and y == 0 then
        parts[#parts + 1] = string.char(255, 0, 0, 255)
      else
        parts[#parts + 1] = string.char(0, 0, 0, 0)
      end
    end
  end
  return table.concat(parts)
end

-- Builds a schema-valid synthetic closed effect record over the given
-- resource descriptors. Each descriptor carries kind, payload path and a
-- 40-hex content identity; the program carries one resourceless task so the
-- closure check stays exact without source parsing.
---@param key string flat semantic effect key
---@param resources table<integer, table<string, unknown>> resource descriptors in order
---@return table<string, unknown> schema-valid effect record
function Fixture.effectRecord(key, resources)
  local dependencies = {}
  local named = {}
  for _, descriptor in ipairs(resources) do
    dependencies[#dependencies + 1] = descriptor.key
    named[descriptor.key] = {
      kind = descriptor.kind,
      payload = descriptor.payload,
      contentIdentity = descriptor.contentIdentity,
    }
  end
  return {
    schema = BattleAnimationSchema.EFFECT_SCHEMA,
    key = key,
    catalogIdentity = "probe-catalog",
    program = {
      entry = "main",
      instructions = { { op = "start-visual-task", taskKind = "positioned-sound-motion", values = {} } },
      subprograms = {},
      taskKinds = { "positioned-sound-motion" },
    },
    dependencies = dependencies,
    resources = named,
    requiredContext = {},
  }
end

---@param opts table? { launchId: string } owning launch identity under diagnosing
---@return table fixture carrying its staged store and service double
function Fixture.new(opts)
  opts = opts or {}
  local self = setmetatable({
    launchId = opts.launchId or "probe-launch",
    staged = {},
    failures = {},
    failUpload = {},
    requests = {},
    uploads = 0,
    handles = {},
    refcounts = {},
    drops = {},
    imageErrors = {},
    failed = nil,
    disposed = false,
    services = {},
  }, Fixture)
  local services = self.services
  -- The holder always prepares its launch demand through these services;
  -- the staged-effect double answers ready without scene work.
  function services.prepare(_demand)
    return true
  end
  local function closureReady(entry)
    local dependencies = entry.record.dependencies
    local resources = entry.record.resources
    if type(dependencies) ~= "table" or type(resources) ~= "table" then
      return false
    end
    if #dependencies ~= 0 then
      local seen = {}
      for _, key in ipairs(dependencies) do
        if type(key) ~= "string" or seen[key] ~= nil then
          return false
        end
        seen[key] = true
        local descriptor = resources[key]
        if type(descriptor) ~= "table" or entry.payloads[descriptor.payload] == nil then
          return false
        end
      end
    end
    local count = 0
    for key in pairs(resources) do
      count = count + 1
      if entry.payloads[resources[key].payload] == nil then
        return false
      end
    end
    return count == #dependencies
  end
  local function readyEntry(key)
    local entry = self.staged[key]
    if entry == nil or entry.marker ~= true then
      return nil
    end
    if not closureReady(entry) then
      return nil
    end
    return entry
  end
  -- Requests the exact semantic effect: false while the worker closure is
  -- still staging, true only after the marker and every dependency payload
  -- are present, nil plus a terminal reason on flat-key violations, worker
  -- failures, or a latched earlier terminal.
  function services.requestEffect(key)
    if type(key) ~= "string" or key == "" or key:find("/", 1, true) ~= nil then
      return nil, "unknown battle effect key: " .. tostring(key)
    end
    self.requests[#self.requests + 1] = key
    if self.failed ~= nil then
      return nil, self.failed
    end
    if self.failures[key] ~= nil then
      self.failed = "battle effect "
        .. key
        .. " failed for launch "
        .. self.launchId
        .. ": "
        .. tostring(self.failures[key])
      return nil, self.failed
    end
    if readyEntry(key) == nil then
      return false, nil
    end
    return true, nil
  end
  -- Loads the exact generated effect, but only after readiness: schema
  -- violations and key mismatches are terminal, never a fallback record.
  function services.loadEffect(key)
    if self.failed ~= nil then
      return nil, self.failed
    end
    local entry = readyEntry(key)
    if entry == nil then
      return nil, "battle effect " .. tostring(key) .. " is not ready for launch " .. self.launchId
    end
    local ok, schemaErr = pcall(BattleAnimationSchema.assertEffect, entry.record)
    if not ok then
      return nil,
        "battle effect " .. tostring(key) .. " failed for launch " .. self.launchId .. ": " .. tostring(schemaErr)
    end
    if entry.record.key ~= key then
      return nil, "staged battle effect names " .. tostring(entry.record.key) .. ", not " .. tostring(key)
    end
    return entry.record
  end
  local function dropHandle(resourceKey)
    if self.handles[resourceKey] ~= nil then
      self.handles[resourceKey] = nil
      self.drops[resourceKey] = (self.drops[resourceKey] or 0) + 1
    end
  end
  -- Resolves one dependency of a loaded effect into a semantic lease.
  -- Texture leases share one immutable fake GPU handle across duplicate
  -- resolves and validate exact dimension/byte-length/content identity;
  -- other kinds arrive as immutable decoded records beside their staged
  -- path, mirroring the production holder contract. Upload failures
  -- latch the selected effect failed and release nothing here: the
  -- holder rolls back what it acquired through release.
  function services.resolveEffectResource(effect, resourceKey)
    if self.disposed then
      return nil, "battle effect resources are released for launch " .. self.launchId
    end
    if self.failed ~= nil then
      return nil, self.failed
    end
    if type(effect) ~= "table" or type(effect.key) ~= "string" then
      return nil, "effect leases resolve from a loaded effect for launch " .. self.launchId
    end
    local entry = readyEntry(effect.key)
    if entry == nil then
      return nil, "battle effect " .. tostring(effect.key) .. " is not ready for launch " .. self.launchId
    end
    local descriptor = entry.record.resources[resourceKey]
    if type(descriptor) ~= "table" then
      return nil,
        "unknown battle effect resource "
          .. tostring(resourceKey)
          .. " for effect "
          .. tostring(effect.key)
          .. " for launch "
          .. self.launchId
    end
    if self.failUpload[resourceKey] ~= nil then
      self.failed = "battle effect image "
        .. tostring(resourceKey)
        .. " failed for effect "
        .. tostring(effect.key)
        .. " for launch "
        .. self.launchId
        .. ": "
        .. tostring(self.failUpload[resourceKey])
      return nil, self.failed
    end
    local payload = entry.payloads[descriptor.payload]
    if payload == nil then
      self.failed = "battle effect resource "
        .. tostring(resourceKey)
        .. " is not staged for effect "
        .. tostring(effect.key)
        .. " for launch "
        .. self.launchId
      return nil, self.failed
    end
    if descriptor.kind == "texture" then
      if
        type(payload) ~= "table"
        or type(payload.width) ~= "number"
        or payload.width % 1 ~= 0
        or payload.width < 1
        or type(payload.height) ~= "number"
        or payload.height % 1 ~= 0
        or payload.height < 1
        or type(payload.rgba8888) ~= "string"
        or #payload.rgba8888 ~= payload.width * payload.height * 4
      then
        self.failed = "battle effect image "
          .. tostring(resourceKey)
          .. " failed for effect "
          .. tostring(effect.key)
          .. " for launch "
          .. self.launchId
          .. ": staged texture has no exact dimensions and bytes"
        return nil, self.failed
      end
      if self.handles[resourceKey] == nil then
        self.uploads = self.uploads + 1
        local width, height = payload.width, payload.height
        local handle = { handle = resourceKey, width = width, height = height }
        function handle:getDimensions()
          return width, height
        end
        self.handles[resourceKey] = handle
      end
      self.refcounts[resourceKey] = (self.refcounts[resourceKey] or 0) + 1
      return {
        key = resourceKey,
        kind = "texture",
        width = payload.width,
        height = payload.height,
        rgba8888 = payload.rgba8888,
        payload = descriptor.payload,
        contentIdentity = descriptor.contentIdentity,
        handle = self.handles[resourceKey],
      }
    end
    return {
      key = resourceKey,
      kind = descriptor.kind,
      payloadPath = descriptor.payload,
      contentIdentity = descriptor.contentIdentity,
      data = payload,
    }
  end
  -- Returns one lease: texture refcounts drop the shared handle at the
  -- last release, other kinds validate only. Drops are idempotent so a
  -- holder that releases at last lease and again at dispose still frees
  -- the GPU object exactly once.
  function services.releaseEffectResource(lease)
    if type(lease) ~= "table" or type(lease.key) ~= "string" then
      return nil, "effect releases name their lease for launch " .. self.launchId
    end
    local left = (self.refcounts[lease.key] or 0) - 1
    if left < 0 then
      return nil, "effect lease " .. tostring(lease.key) .. " is already released for launch " .. self.launchId
    end
    self.refcounts[lease.key] = left
    if left == 0 then
      dropHandle(lease.key)
    end
    return true
  end
  -- Resolves one staged semantic texture into its shared fake handle.
  -- Unknown keys stay legitimately pending with no error; terminal upload
  -- failures replay identically; a disposed launch hands out nothing.
  function services.drawable(key)
    if self.imageErrors[key] ~= nil then
      return nil, self.imageErrors[key]
    end
    if self.disposed then
      return nil, "battle effect resources are released for launch " .. self.launchId
    end
    if self.failed ~= nil then
      return nil, self.failed
    end
    return self.handles[key]
  end
  -- Releases one owned handle exactly once; never touches unowned keys.
  function services.release(key)
    dropHandle(key)
  end
  return self
end

-- Stages one synthetic closed effect: the schema-valid record, its
-- completion marker, and every dependency payload value.
---@param key string flat semantic effect key
---@param record table<string, unknown> schema-valid effect record
---@param payloads table<string, unknown> cache-relative payload path to staged value
function Fixture:stageEffect(key, record, payloads)
  self.staged[key] = { record = record, marker = true, payloads = payloads }
end

-- Marks one demanded effect terminally failed, as a worker/producer
-- failure would.
---@param key string flat semantic effect key
---@param reason string producer cause
function Fixture:failEffect(key, reason)
  self.failures[key] = reason
end

-- Injects one terminal GPU/payload failure for a texture resource.
---@param resourceKey string semantic texture resource key
---@param reason string driver or payload cause
function Fixture:failUploadFor(resourceKey, reason)
  self.failUpload[resourceKey] = reason
end

-- Notes the launch disposed so stale completions resolve to nothing.
function Fixture:dispose()
  self.disposed = true
end

return Fixture
