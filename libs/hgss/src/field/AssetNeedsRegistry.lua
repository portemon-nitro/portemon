-- Maps an asset need kind to the preparer that makes it ready, and runs the
-- prepared work in bounded slices. A preparer starts a job for one need id; a
-- job does one unit of work per `step` call and reports whether it is done.
-- The registry owns the time budget, isolates a failing job from its
-- siblings, and cancels a job exactly once when its need goes away. It knows
-- nothing about any particular asset: composition registers the preparers.

local AssetNeeds = require("libs.script.src.AssetNeeds")
local ScriptCache = require("libs.assets.src.ScriptCache")

local AssetNeedsRegistry = {}
AssetNeedsRegistry.__index = AssetNeedsRegistry

---@class AssetNeedsRegistry.Job
---@field step fun(): boolean one unit of work; true when the need is ready
---@field cancel fun() releases what the job built, exactly once

---@class AssetNeedsRegistry.Preparer
---@field start fun(id: string): AssetNeedsRegistry.Job? nil when this host does not prepare that id

---@class AssetNeedsRegistry.Entry
---@field key string
---@field kind string
---@field job AssetNeedsRegistry.Job?
---@field state "live"|"done"|"failed"
---@field error string?

---@class AssetNeedsRegistry
---@field _clock fun(): number
---@field _preparers table<string, AssetNeedsRegistry.Preparer>
---@field _entries table<string, AssetNeedsRegistry.Entry>
---@field _order string[] enrollment order of the entries
---@field register fun(self: AssetNeedsRegistry, kind: string, preparer: AssetNeedsRegistry.Preparer)
---@field unregister fun(self: AssetNeedsRegistry, kind: string)
---@field enroll fun(self: AssetNeedsRegistry, key: string): boolean
---@field retain fun(self: AssetNeedsRegistry, wanted: table<string, true>)
---@field step fun(self: AssetNeedsRegistry, budget: number)
---@field failures fun(self: AssetNeedsRegistry): { key: string, message: string }[]
---@field dispose fun(self: AssetNeedsRegistry)

---@param options { clock: (fun(): number)? }? clock defaults to os.clock
---@return AssetNeedsRegistry
function AssetNeedsRegistry.new(options)
  return setmetatable({
    _clock = options and options.clock or os.clock,
    _preparers = {},
    _entries = {},
    _order = {},
  }, AssetNeedsRegistry)
end

---@param kind string
---@param preparer AssetNeedsRegistry.Preparer
function AssetNeedsRegistry:register(kind, preparer)
  assert(type(kind) == "string" and kind ~= "", "asset need kind is required")
  assert(type(preparer) == "table" and type(preparer.start) == "function", "asset need preparer requires start")
  assert(self._preparers[kind] == nil, "asset need kind is already registered: " .. kind)
  self._preparers[kind] = preparer
end

---@param entry AssetNeedsRegistry.Entry
local function cancelEntry(entry)
  local job = entry.job
  if job ~= nil then
    entry.job = nil
    job.cancel()
  end
end

---@param self AssetNeedsRegistry
---@param key string
local function removeEntry(self, key)
  self._entries[key] = nil
  for index, candidate in ipairs(self._order) do
    if candidate == key then
      table.remove(self._order, index)
      return
    end
  end
end

-- Removes a kind and cancels its jobs.
---@param kind string
function AssetNeedsRegistry:unregister(kind)
  local keys = {}
  for key, entry in pairs(self._entries) do
    if entry.kind == kind then
      keys[#keys + 1] = key
    end
  end
  for _, key in ipairs(keys) do
    cancelEntry(self._entries[key])
    removeEntry(self, key)
  end
  self._preparers[kind] = nil
end

---@param self AssetNeedsRegistry
---@param key string
---@param kind string
---@param message string
local function recordFailure(self, key, kind, message)
  if self._entries[key] == nil then
    self._order[#self._order + 1] = key
  end
  self._entries[key] = { key = key, kind = kind, state = "failed", error = message }
end

-- Starts preparing one need. False when no preparer handles it (an
-- unregistered kind, a host that declines the id) or when it has failed; a
-- malformed key raises. A need is started once however often it is enrolled.
---@param key string `kind:id`
---@return boolean enrolled
function AssetNeedsRegistry:enroll(key)
  local need = AssetNeeds.parse(key)
  local existing = self._entries[key]
  if existing ~= nil then
    return existing.state ~= "failed"
  end
  local preparer = self._preparers[need.kind]
  if preparer == nil then
    return false
  end
  local ok, job = pcall(preparer.start, need.id)
  if not ok then
    recordFailure(self, key, need.kind, tostring(job))
    return false
  end
  if job == nil then
    return false
  end
  self._entries[key] = { key = key, kind = need.kind, job = job, state = "live" }
  self._order[#self._order + 1] = key
  return true
end

-- Keeps only the needs in `wanted` (a set of keys): every other job is
-- cancelled once and forgotten, so the need can be enrolled again later.
---@param wanted table<string, true>
function AssetNeedsRegistry:retain(wanted)
  local dropped = {}
  for key in pairs(self._entries) do
    if not wanted[key] then
      dropped[#dropped + 1] = key
    end
  end
  for _, key in ipairs(dropped) do
    cancelEntry(self._entries[key])
    removeEntry(self, key)
  end
end

-- Steps every job in enrollment order, one unit at a time, until the budget
-- (in the clock's units) is spent; at least one unit runs when any job is
-- unfinished. A finished job is polled once per call, so one whose conditions
-- changed (it then reports unfinished) resumes. A job that raises is
-- cancelled and marked failed; its siblings still run.
---@param budget number
function AssetNeedsRegistry:step(budget)
  local started = self._clock()
  local order = { table.unpack(self._order) }
  for _, key in ipairs(order) do
    local entry = self._entries[key]
    while entry ~= nil and entry.state ~= "failed" do
      local job = assert(entry.job)
      local ok, done = pcall(job.step)
      if not ok then
        cancelEntry(entry)
        entry.state, entry.error = "failed", tostring(done)
      else
        entry.state = done and "done" or "live"
      end
      if self._clock() - started >= budget then
        return
      end
      if entry.state ~= "live" then
        break
      end
    end
  end
end

-- The needs whose jobs failed, by key, until their need is dropped.
---@return { key: string, message: string }[]
function AssetNeedsRegistry:failures()
  local list = {}
  for key, entry in pairs(self._entries) do
    if entry.state == "failed" then
      list[#list + 1] = { key = key, message = entry.error or "" }
    end
  end
  table.sort(list, function(a, b)
    return a.key < b.key
  end)
  return list
end

-- Cancels every job; the registry stays usable.
function AssetNeedsRegistry:dispose()
  local keys = { table.unpack(self._order) }
  for _, key in ipairs(keys) do
    cancelEntry(self._entries[key])
    removeEntry(self, key)
  end
end

-- The needs of one script member: the published index closure plus the needs
-- of any override-layer resource of that member. A malformed index
-- contributes nothing; the synchronous path raises if it ever needs the asset.
---@param index table<string, unknown> the published script index
---@param memberId integer
---@param overrideNeeds fun(id: string): string[]? needs of an id's override resource, nil when it has none
---@return table<string, true> needs set of `kind:id` keys
function AssetNeedsRegistry.needsForMember(index, memberId, overrideNeeds)
  local needs = {}
  for _, key in ipairs(ScriptCache.assetNeedsForMember(index, memberId) or {}) do
    needs[key] = true
  end
  if type(index) == "table" and type(index.resources) == "table" then
    for _, entry in ipairs(index.resources) do
      if entry.member == memberId then
        for _, key in ipairs(overrideNeeds(entry.id) or {}) do
          needs[key] = true
        end
      end
    end
  end
  return needs
end

return AssetNeedsRegistry
