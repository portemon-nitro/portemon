-- Per-scene asset leases behind one field evolution scene: the verified
-- battle presentation core (message entries and Pokepic animation), the
-- late evolution leaf, its drawables, the two Pokepic portrait pages, and
-- the audio banks the scene voices.
-- Preparation and image resolution run through the battle presentation
-- services this holder borrows; it owns exactly the handles it acquired
-- and releases them once on disposal. It implements the asset port the
-- EvolutionScenePresenter reads (ensureEvolution, drawable, addSelectors,
-- state).

---@class FieldEvolutionAssets.Services
---@field prepare fun(demand: table<string, unknown>): boolean?, string?
---@field drawable fun(key: string): table<string, unknown>?, string?
---@field release fun(key: string)
---@field prepareEvolution fun(): table<string, unknown>?, string?

---@class FieldEvolutionAssets
---@field _services FieldEvolutionAssets.Services borrowed battle preparation services
---@field _verifiedManifest fun(): table<string, unknown>?, string? verified battle presentation core, nil while pending
---@field _audioBanks fun(): integer[] banks of the sequences the scene voices
---@field _sceneId string scene identity behind demands and failures
---@field _manifestView table<string, unknown>? per-scene shallow view over the verified core
---@field _evolutionRecord table<string, unknown>? staged evolution leaf, nil until ready
---@field _evolutionFailed string? terminal evolution failure, latched without retry
---@field _selectors string[] portrait selectors named so far
---@field _prepared boolean preparation accepted for the current demand
---@field _state "pending"|"ready"|"failed"
---@field _error string?
---@field _owned table<string, boolean> drawable keys acquired through this holder
---@field _disposed boolean
local FieldEvolutionAssets = {}
FieldEvolutionAssets.__index = FieldEvolutionAssets

---@class FieldEvolutionAssets.Options
---@field services FieldEvolutionAssets.Services borrowed battle preparation services
---@field verifiedManifest fun(): table<string, unknown>?, string? verified battle presentation core, nil while pending
---@field audioBanks fun(): integer[] banks of the sequences the scene voices
---@field sceneId string scene identity behind demands and failures

---@param opts FieldEvolutionAssets.Options
---@return FieldEvolutionAssets
function FieldEvolutionAssets.new(opts)
  assert(type(opts) == "table", "evolution assets require options")
  assert(type(opts.services) == "table", "evolution assets borrow the battle preparation services")
  assert(type(opts.verifiedManifest) == "function", "evolution assets read the verified presentation core")
  assert(type(opts.audioBanks) == "function", "evolution assets name the banks their scene voices")
  assert(type(opts.sceneId) == "string" and opts.sceneId ~= "", "evolution assets carry their scene identity")
  return setmetatable({
    _services = opts.services,
    _verifiedManifest = opts.verifiedManifest,
    _audioBanks = opts.audioBanks,
    _sceneId = opts.sceneId,
    _manifestView = nil,
    _evolutionRecord = nil,
    _evolutionFailed = nil,
    _selectors = {},
    _prepared = false,
    _state = "pending",
    _error = nil,
    _owned = {},
    _disposed = false,
  }, FieldEvolutionAssets)
end

-- Answers the per-scene manifest view once the verified core is staged:
-- the shared core is borrowed by reference and never mutated, while the
-- presenter writes its staged evolution sections onto the view.
---@return table<string, unknown>? view nil while the core is pending
---@return string? failure terminal core failure
function FieldEvolutionAssets:manifest()
  assert(not self._disposed, "disposed evolution assets answer no manifest")
  if self._manifestView ~= nil then
    return self._manifestView
  end
  local core, failure = self._verifiedManifest()
  if failure ~= nil then
    return nil, failure
  end
  if core == nil then
    return nil
  end
  local view = {}
  for key, value in pairs(core) do
    view[key] = value
  end
  self._manifestView = view
  return view
end

---@param message string failure text
---@return string failure with the scene identity
function FieldEvolutionAssets:_withScene(message)
  return message .. " for evolution scene " .. self._sceneId
end

---@return table<string, unknown>? record staged evolution leaf, nil while pending
---@return string? failure terminal failure, latched without retry
function FieldEvolutionAssets:ensureEvolution()
  if self._evolutionRecord ~= nil then
    return self._evolutionRecord
  end
  if self._evolutionFailed ~= nil then
    return nil, self._evolutionFailed
  end
  assert(not self._disposed, "disposed evolution assets stage nothing")
  local record, failure = self._services.prepareEvolution()
  if failure ~= nil then
    self._evolutionFailed = self:_withScene(failure)
    return nil, self._evolutionFailed
  end
  self._evolutionRecord = record
  return record
end

-- Names portrait selectors for demand. A genuinely grown set reopens
-- preparation on the next update.
---@param selectors string[]
function FieldEvolutionAssets:addSelectors(selectors)
  assert(type(selectors) == "table", "portrait selectors arrive as an array")
  local known = {}
  for _, selector in ipairs(self._selectors) do
    known[selector] = true
  end
  for _, selector in ipairs(selectors) do
    assert(type(selector) == "string" and selector ~= "", "portrait selectors are non-empty strings")
    if not known[selector] then
      known[selector] = true
      self._selectors[#self._selectors + 1] = selector
      if self._state ~= "failed" then
        self._state = "pending"
        self._prepared = false
      end
    end
  end
end

-- Runs preparation of the named portrait pages and the scene's audio banks
-- (with the species cry banks behind the pages) once per demand. A bare
-- not-yet answer polls again on the next call; a failure is terminal.
function FieldEvolutionAssets:update()
  assert(not self._disposed, "disposed evolution assets prepare nothing")
  if self._state ~= "pending" or self._prepared then
    return
  end
  local selectors = {}
  for index, selector in ipairs(self._selectors) do
    selectors[index] = selector
  end
  local ok, failure = self._services.prepare({
    launchId = self._sceneId,
    scenes = {},
    pages = selectors,
    partyPages = {},
    iconKeys = {},
    trainerPictures = {},
    battleBalls = {},
    audio = { roles = {}, banks = self._audioBanks(), cries = {} },
  })
  if ok == nil or failure ~= nil then
    self._state = "failed"
    self._error = self:_withScene(tostring(failure or "evolution preparation failed"))
    return
  end
  if ok == true then
    self._prepared = true
    self._state = "ready"
  end
end

-- Resolves one image through the battle preparation services, tracking
-- every handle acquired here. Unavailable images answer nil without an
-- error; a terminal upload failure latches the holder failed.
---@param key string drawable key under resolution
---@return table<string, unknown>? image nil while unavailable or after failure
---@return string? failure terminal failure naming the key
function FieldEvolutionAssets:drawable(key)
  assert(type(key) == "string" and key ~= "", "image resolution names its key")
  if self._state == "failed" then
    return nil, self._error
  end
  local handle, failure = self._services.drawable(key)
  if failure ~= nil then
    self._state = "failed"
    self._error = self:_withScene("evolution image " .. key .. " failed: " .. tostring(failure))
    return nil, self._error
  end
  if handle ~= nil then
    self._owned[key] = true
  end
  return handle
end

---@return "pending"|"ready"|"failed"
function FieldEvolutionAssets:state()
  return self._state
end

---@return string? failure terminal failure while failed
function FieldEvolutionAssets:error()
  return self._error
end

-- Releases every drawable acquired through this holder exactly once.
function FieldEvolutionAssets:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._evolutionRecord = nil
  for key in pairs(self._owned) do
    self._services.release(key)
  end
  self._owned = {}
end

return FieldEvolutionAssets
