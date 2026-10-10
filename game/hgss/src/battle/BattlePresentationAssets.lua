-- Per-launch battle resource leases behind one battle screen. Resolves
-- the selected scene image and window frame through the injected
-- preparation services, tracks exactly the handles acquired here, and
-- reports truthful pending/ready/failed preparation with semantic error
-- context. Frame selection merges per-instance declarations over the one
-- built-in default: an undeclared frame key is an explicit content
-- failure, never a substitution. Borrowed text and window services are
-- never owned here.

---@class BattlePresentationAssets.Services
---@field prepare fun(demand: table<string, unknown>): boolean?, string?
---@field drawable fun(key: string): table<string, unknown>?, string?
---@field release fun(key: string)

---@class BattlePresentationAssets
---@field _assets BattlePresentationAssets.Services preparation services carrying prepare/drawable/release
---@field _launchId string owning launch identity
---@field _sceneKey string semantic scene identity for the demand
---@field _sceneImage string selected scene image key
---@field _audioRoles string[] staged audio role symbols behind the demand
---@field _frameKey string selected window frame key
---@field _frames table<string, table<string, unknown>>? per-instance frame declarations
---@field _state "pending"|"ready"|"failed"
---@field _error string?
---@field _prepared boolean preparation accepted for the current demand
---@field _selectors string[] portrait selectors named so far
---@field _owned table<string, boolean> image keys acquired through this holder
---@field _imageErrors table<string, string> terminal upload failures by key, latched without retry
---@field _released boolean release guard
local BattlePresentationAssets = {}
BattlePresentationAssets.__index = BattlePresentationAssets

BattlePresentationAssets.DEFAULT_FRAME = "default"

---@class BattlePresentationAssets.Options
---@field assets BattlePresentationAssets.Services preparation services carrying prepare/drawable/release
---@field launchId string owning launch identity
---@field sceneKey string semantic scene identity for the demand
---@field audioRoles string[]? staged audio role symbols behind the demand, none when absent
---@field sceneImage string? selected scene image key, derived from the scene key when absent
---@field frameKey string? selected window frame key, the built-in default when absent
---@field frames table<string, table<string, unknown>>? per-instance frame declarations

---@param opts BattlePresentationAssets.Options
---@return BattlePresentationAssets
function BattlePresentationAssets.new(opts)
  assert(type(opts) == "table", "the resource holder requires options")
  assert(type(opts.assets) == "table", "the resource holder requires its preparation services")
  assert(type(opts.assets.prepare) == "function", "the preparation services prepare demands")
  assert(type(opts.assets.drawable) == "function", "the preparation services resolve drawables")
  assert(type(opts.assets.release) == "function", "the preparation services release handles")
  assert(type(opts.launchId) == "string" and opts.launchId ~= "", "the resource holder needs its launch identity")
  assert(type(opts.sceneKey) == "string" and opts.sceneKey ~= "", "the resource holder needs its scene identity")
  if opts.frameKey ~= nil then
    assert(type(opts.frameKey) == "string" and opts.frameKey ~= "", "the frame selection names its key")
  end
  if opts.frames ~= nil then
    assert(type(opts.frames) == "table", "frame declarations arrive as a keyed record")
  end
  if opts.audioRoles ~= nil then
    assert(type(opts.audioRoles) == "table", "staged audio roles arrive as an array")
  end
  return setmetatable({
    _assets = opts.assets,
    _launchId = opts.launchId,
    _sceneKey = opts.sceneKey,
    _audioRoles = opts.audioRoles or {},
    _sceneImage = opts.sceneImage or ("scene:" .. opts.sceneKey),
    _frameKey = opts.frameKey or BattlePresentationAssets.DEFAULT_FRAME,
    _frames = opts.frames,
    _state = "pending",
    _error = nil,
    _prepared = false,
    _selectors = {},
    _owned = {},
    _imageErrors = {},
    _released = false,
  }, BattlePresentationAssets)
end

---@return boolean valid
local function frameDeclared(self)
  if self._frameKey == BattlePresentationAssets.DEFAULT_FRAME then
    return true
  end
  return type(self._frames) == "table" and type(self._frames[self._frameKey]) == "table"
end

---@return table<string, unknown> exact launch demand for the preparation services
function BattlePresentationAssets:_demand()
  local selectors = {}
  for _, selector in ipairs(self._selectors) do
    selectors[#selectors + 1] = selector
  end
  local roles = {}
  for _, role in ipairs(self._audioRoles) do
    roles[#roles + 1] = role
  end
  local seenCries, cries = {}, {}
  for _, selector in ipairs(selectors) do
    local species = tostring(selector):match("^([^/]+)")
    if type(species) == "string" and species ~= "" then
      local cry = "cry:" .. species
      if not seenCries[cry] then
        seenCries[cry] = true
        cries[#cries + 1] = cry
      end
    end
  end
  table.sort(cries)
  return {
    launchId = self._launchId,
    scenes = { self._sceneKey },
    pages = selectors,
    audio = { roles = roles, banks = {}, cries = cries },
  }
end

-- Image keys the launch always draws: the selected scene, both HUD
-- composites, and all three menu surfaces. Battler portraits stay
-- cue-gated through their side keys instead: their selectors arrive
-- after the opening delivery, so readiness cannot wait on them.
local REQUIRED_DRAWABLES = { "hud:enemy", "hud:player", "menu:command", "menu:moves", "menu:target" }

-- Runs preparation once per demand: an invalid frame selection or a
-- service failure becomes failed with context; a missing required image
-- stays pending until its drawable resolves instead of failing. A
-- drawable that answers a terminal upload error fails closed with that
-- key's context and never retries; already acquired handles stay owned
-- until exactly-once disposal.
function BattlePresentationAssets:update()
  if self._state == "failed" or self._state == "ready" then
    return
  end
  if not frameDeclared(self) then
    self._state = "failed"
    self._error = "unknown battle frame: " .. self._frameKey
    return
  end
  if not self._prepared then
    local ok, failure = self._assets.prepare(self:_demand())
    if ok == nil or failure ~= nil then
      self._state = "failed"
      self._error = tostring(failure or "battle preparation failed")
      return
    end
    -- A bare not-yet answer polls again: false without a failure string
    -- means the demand is still preparing. A nil answer, or any answer
    -- carrying a failure string, is a terminal preparation failure and
    -- fails closed with context.
    if ok == false then
      return
    end
    self._prepared = true
  end
  local sceneHandle, sceneFailure = self._assets.drawable(self._sceneImage)
  if sceneFailure ~= nil then
    self._state = "failed"
    self._error = "battle scene image failed for launch " .. self._launchId .. ": " .. tostring(sceneFailure)
    self._imageErrors[self._sceneImage] = self._error --[[@as string]]
    return
  end
  if sceneHandle == nil then
    return
  end
  self._owned[self._sceneImage] = true
  for _, key in ipairs(REQUIRED_DRAWABLES) do
    local handle, failure = self._assets.drawable(key)
    if failure ~= nil then
      self._state = "failed"
      self._error = "battle image failed for launch " .. self._launchId .. ": " .. tostring(failure)
      self._imageErrors[key] = self._error --[[@as string]]
      return
    end
    if handle == nil then
      return
    end
    self._owned[key] = true
  end
  self._state = "ready"
end

-- Names portrait selectors for later demand growth. Re-preparation runs
-- on the next update so incoming images prefetch without showing early.
---@param selectors string[]
function BattlePresentationAssets:addSelectors(selectors)
  assert(type(selectors) == "table", "portrait selectors arrive as an array")
  local known = {}
  for _, selector in ipairs(self._selectors) do
    known[selector] = true
  end
  local grown = false
  for _, selector in ipairs(selectors) do
    if type(selector) == "string" and selector ~= "" and not known[selector] then
      known[selector] = true
      self._selectors[#self._selectors + 1] = selector
      grown = true
    end
  end
  -- Later images prefetch through a fresh demand without reopening
  -- readiness: preparation already succeeded for this launch.
  if grown and self._state == "ready" then
    local ok, failure = self._assets.prepare(self:_demand())
    -- A bare not-yet answer keeps readiness: the grown selectors stay
    -- named for a later demand, while nil or a failure string fails.
    if ok == nil or failure ~= nil then
      self._state = "failed"
      self._error = tostring(failure or "battle preparation failed")
    end
  end
end

-- Resolves one image through the preparation services, tracking
-- ownership of every handle acquired here. Unavailable images report
-- nil with no error so cues can hold instead of drawing substitutes.
-- A terminal upload error latches the holder failed with the exact
-- image key and replays identically without re-entering the services.
---@param key string image key under resolution
---@return table<string, unknown>? image handle, nil while unavailable or after failure
---@return string? terminal failure naming the exact image key, nil while pending or ready
function BattlePresentationAssets:drawable(key)
  assert(type(key) == "string" and key ~= "", "image resolution names its key")
  if self._imageErrors[key] ~= nil then
    return nil, self._imageErrors[key]
  end
  if self._state == "failed" then
    return nil, self._error
  end
  local handle, failure = self._assets.drawable(key)
  if failure ~= nil then
    self._state = "failed"
    self._error = "battle image " .. key .. " failed for launch " .. self._launchId .. ": " .. tostring(failure)
    self._imageErrors[key] = self._error --[[@as string]]
    return nil, self._error
  end
  if handle ~= nil then
    self._owned[key] = true
  end
  return handle
end

---@return string selected scene image key
function BattlePresentationAssets:sceneImage()
  return self._sceneImage
end

---@return string selected window frame key
function BattlePresentationAssets:frameKey()
  return self._frameKey
end

---@return "pending"|"ready"|"failed"
function BattlePresentationAssets:state()
  return self._state
end

---@return string? failure context, nil unless failed
function BattlePresentationAssets:error()
  return self._error
end

-- Releases each owned handle exactly once. Borrowed text and window
-- services are never touched here.
function BattlePresentationAssets:dispose()
  if self._released then
    return
  end
  self._released = true
  for key in pairs(self._owned) do
    self._assets.release(key)
  end
  self._owned = {}
end

return BattlePresentationAssets
