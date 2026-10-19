-- The field-owned Pokedex preparation owner: one lazy per-field resource
-- lifetime borrowing the session image pool, derived assets, caches, font0,
-- messages, and audio. It builds the single shared renderer once and hands
-- out independent per-open leases for the browser and the registration
-- card. Each lease owns exactly one icon demand over the shared pool and
-- publishes whole ready bundles only: icons alone never retire a visible
-- page. At most the committed generation plus one pending generation stays
-- resident; obsolete keys never publish. Neither the owner nor its leases
-- dispose borrowed pool, message, font0, or audio owners.

local MonCache = require("libs.assets.src.MonCache")
local PokedexCache = require("libs.assets.src.PokedexCache")
local PokedexRenderer = require("libs.hgss.src.ui.PokedexRenderer")

---@class PokedexPresentationResources
---@field _pool table<string, unknown> borrowed session image owner
---@field _monCatalog table<string, unknown> borrowed resolved mon catalog
---@field _catalog table<string, unknown> borrowed generated dex catalog
---@field _cacheFs table<string, unknown>? version cache reader behind manifest and portrait pages
---@field _graphics table<string, unknown>? host graphics namespace behind canvases and font warmup
---@field _derivedAssets table<string, unknown> semantic compilation seam
---@field _text table<string, unknown>? borrowed font0 text renderer
---@field _messages table<string, unknown>? borrowed field message provider
---@field _audio table<string, unknown>? borrowed field audio owner
---@field _renderer table<string, unknown> the one shared prepared rasterizer
---@field _manifest table<string, unknown>? loaded presentation manifest, synthetic when no cache backs the seam
---@field _manifestReady boolean
---@field _leases table<string, unknown>[] live per-open leases in acquisition order
---@field _released boolean
local PokedexPresentationResources = {}
PokedexPresentationResources.__index = PokedexPresentationResources

local POOLED_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }
local MAX_PICTURES = 4

-- The six serial compositor surfaces, in the order the renderer
-- consumes them: four BG planes, top-OBJ color, top-OBJ metadata.
local SURFACE_NAMES = { "bg0", "bg1", "bg2", "bg3", "objColor", "objMeta" }
local SURFACE_WIDTH = 256
local SURFACE_HEIGHT = 192

local PAGE_ROLES = {
  cover = true,
  grid = true,
  results = true,
  registration = true,
  ["search.criteria"] = true,
  ["search.order"] = true,
  ["search.name"] = true,
  ["search.type"] = true,
  ["search.height"] = true,
  ["search.weight"] = true,
  ["search.area"] = true,
  ["search.shape"] = true,
  ["entry.area"] = true,
  ["entry.size"] = true,
  ["entry.forms"] = true,
  ["entry.compare"] = true,
  ["entry.return"] = true,
}

---@param pool table<string, unknown>
local function checkPool(pool)
  assert(type(pool) == "table", "pokedex preparation borrows its shared image owner")
  assert(type(pool.request) == "function", "pokedex preparation borrows pool requests")
  assert(type(pool.poll) == "function", "pokedex preparation borrows pool polls")
  assert(type(pool.acquire) == "function", "pokedex preparation borrows pool acquisitions")
  assert(type(pool.release) == "function", "pokedex preparation borrows pool releases")
  assert(type(pool.cancel) == "function", "pokedex preparation borrows pool cancels")
end

---@param opts { imagePool: table<string, unknown>, monCatalog: table<string, unknown>, catalog: table<string, unknown>, cacheFs: table<string, unknown>, graphics: table<string, unknown>?, derivedAssets: table<string, unknown>, text: table<string, unknown>?, messages: table<string, unknown>?, audio: table<string, unknown>? }
---@return PokedexPresentationResources
function PokedexPresentationResources.new(opts)
  assert(type(opts) == "table", "pokedex preparation needs its collaborators")
  checkPool(assert(opts.imagePool, "pokedex preparation borrows its shared image owner"))
  assert(type(opts.monCatalog) == "table", "pokedex preparation borrows the resolved mon catalog")
  assert(type(opts.catalog) == "table", "pokedex preparation borrows the generated dex catalog")
  assert(type(opts.cacheFs) == "table", "pokedex preparation borrows its prepared cache filesystem")
  local derived = assert(opts.derivedAssets, "pokedex preparation needs its compilation seam")
  assert(type(derived) == "table", "pokedex preparation needs its compilation seam")
  local self = setmetatable({
    _pool = opts.imagePool,
    _monCatalog = opts.monCatalog,
    _catalog = opts.catalog,
    _cacheFs = opts.cacheFs,
    _graphics = opts.graphics,
    _derivedAssets = derived,
    _text = opts.text,
    _messages = opts.messages,
    _audio = opts.audio,
    _renderer = nil,
    _manifest = nil,
    _manifestReady = false,
    _portraitManifest = nil,
    _leases = {},
    _released = false,
  }, PokedexPresentationResources)
  self._renderer = PokedexRenderer.new({ graphics = opts.graphics, text = opts.text })
  return self
end

-- Loads the presentation manifest only after the presentation scope
-- reports ready through the semantic seam. The cache filesystem is a
-- required collaborator: scopes without one fail with attribution instead
-- of publishing a synthetic manifest.
---@param owner PokedexPresentationResources
---@return boolean ready
---@return string? failure nonempty cause when the published scope cannot be read
local function ensureManifest(owner)
  if owner._manifestReady then
    return true
  end
  if owner._cacheFs == nil then
    return false, "pokedex presentation needs its prepared cache filesystem"
  end
  local request = owner._derivedAssets.requestPokedex
  if type(request) ~= "function" then
    return false, "pokedex presentation compilation is unavailable"
  end
  local ok, ready, failure = pcall(request, "required")
  if not ok then
    return false, tostring(ready)
  end
  if failure ~= nil then
    return false, tostring(failure)
  end
  if not ready then
    return false, nil
  end
  local loaded, manifest = pcall(PokedexCache.loadManifest, owner._cacheFs)
  if not loaded then
    return false, tostring(manifest)
  end
  assert(type(manifest) == "table", "the pokedex manifest loads as a record")
  if manifest.animations == nil then
    return false, "the pokedex manifest carries no animations table"
  end
  if manifest.chrome == nil then
    return false, "the pokedex manifest carries no chrome table"
  end
  owner._manifest = manifest
  owner._manifestReady = true
  return true
end

---@param demand table<string, unknown>
---@param purpose string fixed lease purpose under validation
local function checkDemand(demand, purpose)
  assert(type(demand) == "table", "preparation demands arrive as records")
  assert(type(demand.key) == "string" and demand.key ~= "", "demands carry their generation key")
  assert(demand.purpose == purpose, "demands prepare through their own purpose lease")
  assert(
    type(demand.pageRole) == "string" and PAGE_ROLES[demand.pageRole] == true,
    "demands name a generated page role"
  )
  assert(demand.dexMode == "johto" or demand.dexMode == "national", "demands name their dex mode")
  assert(type(demand.language) == "string" and demand.language ~= "", "demands name their UI language")
  assert(type(demand.iconKeys) == "table", "demands carry their icon keys")
  for _, key in ipairs(demand.iconKeys) do
    assert(type(key) == "string" and key ~= "", "icon keys arrive as strings")
  end
  assert(type(demand.pictures) == "table", "demands carry their picture slots")
  assert(#demand.pictures <= MAX_PICTURES, "picture demand stays within the current plus pending slots")
  for _, picture in ipairs(demand.pictures) do
    assert(type(picture) == "table", "picture slots arrive as records")
    assert(type(picture.slot) == "string" or type(picture.slot) == "number", "picture slots name their slot")
    assert(type(picture.specimen) == "table", "picture slots carry detached specimen facts")
    assert(picture.facing == "front" or picture.facing == "back", "pictures face front or back")
    assert(
      picture.mode == "portrait" or picture.mode == "silhouette" or picture.mode == "registration",
      "pictures name their presentation mode"
    )
  end
  assert(type(demand.text) == "table", "demands carry their semantic text")
  if demand.cry ~= nil then
    assert(type(demand.cry) == "table", "cry demand arrives as a record")
    assert(type(demand.cry.species) == "string", "cry demand names its species")
    assert(type(demand.cry.form) == "number" and demand.cry.form % 1 == 0, "cry demand names its physical form")
  end
  if purpose == "registration" then
    assert(demand.pageRole == "registration", "registration leases prepare only the card role")
    assert(#demand.iconKeys == 0, "registration demands carry no icon keys")
  end
end

---@param owner PokedexPresentationResources
---@param specimen table<string, unknown> detached specimen facts
---@param facing string front or back
---@param browser boolean true forces the nonshiny browser policy
---@return string? canonical portrait selector
---@return string? absence cause when no legal selector resolves
local function pictureSelector(owner, specimen, facing, browser)
  if type(specimen.species) ~= "string" or specimen.species == "" then
    return nil, "picture specimens name their species"
  end
  if type(specimen.form) ~= "number" or specimen.form % 1 ~= 0 or specimen.form < 0 then
    return nil, "picture specimens name their physical form"
  end
  local shiny = specimen.shiny == true
  if browser then
    shiny = false
  end
  local gender = specimen.gender
  if gender ~= "male" and gender ~= "female" then
    local formOf = owner._monCatalog.form
    if type(formOf) ~= "function" then
      return nil, "picture specimens need the resolved mon catalog"
    end
    local okForm, formRecord = pcall(formOf, owner._monCatalog, specimen.species, specimen.form)
    if not okForm or type(formRecord) ~= "table" or type(formRecord.portrait) ~= "string" then
      return nil, "picture specimens need their declared portrait variant"
    end
    local declared = formRecord.portrait:match("^[^/]+/[^/]+/([^/]+)/[^/]+$")
    if declared ~= "male" and declared ~= "female" then
      return nil, "picture specimens need a declared male or female portrait variant"
    end
    gender = declared
  end
  local ok, selector = pcall(MonCache.portraitSelector, specimen.species, specimen.form, gender, shiny, facing)
  if not ok or type(selector) ~= "string" then
    return nil, tostring(selector)
  end
  return selector
end

---@param owner PokedexPresentationResources
---@param selector string canonical portrait selector
---@return string? pooled path behind the selector, nil when no legal page resolves
---@return string? absence cause when the generated manifest carries no page
local function portraitPath(owner, selector)
  if owner._cacheFs == nil then
    return "pokedex/portraits/" .. selector
  end
  local loaded, manifest = pcall(function()
    return owner._cacheFs:loadLua(MonCache.portraitManifestPath())
  end)
  if not loaded then
    return "pokedex/portraits/" .. selector
  end
  assert(type(manifest) == "table", "the portrait manifest loads as a record")
  local entries = manifest.entries
  if type(entries) ~= "table" then
    return "pokedex/portraits/" .. selector
  end
  local entry = entries[selector]
  if type(entry) ~= "table" or type(entry.pageId) ~= "number" then
    return nil, "the portrait manifest carries no page for " .. selector
  end
  return MonCache.portraitPagePath(entry.pageId)
end

-- One per-lease icon demand over the shared pool: the committed plus
-- pending key union stays borrowed until a whole replacement publishes,
-- then only the committed keys remain. At most one new pooled interest
-- enrolls per prepare call; polling and resident adoption never upload.
-- A real manifest-backed provider serves the demand wherever the backing
-- cache and graphics allow it; anywhere else the pool-direct fallback
-- answers the same seam over synthetic paths.
---@param lease table<string, unknown>
---@param keys string[] ordered distinct icon keys
local function warmProviderQuads(lease, keys)
  local icons = lease._icons
  if type(icons) ~= "table" or type(icons.warmQuad) ~= "function" then
    return
  end
  for _, key in ipairs(keys) do
    pcall(icons.warmQuad, icons, key)
  end
end

---@param lease table<string, unknown>
---@return table<string, unknown> icon demand owner
local function newIconDemand(lease)
  local owner = lease._owner
  if owner._cacheFs ~= nil and type(owner._graphics) == "table" then
    local derived = owner._derivedAssets
    if type(derived) == "table" and type(derived.requestIconPage) == "function" then
      local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")
      local ok, constructed = pcall(MonIconAssetProvider.new, owner._cacheFs, {
        graphics = owner._graphics,
        imagePool = owner._pool,
        derivedAssets = derived,
      })
      if ok and constructed ~= nil then
        local demand = { _lease = lease, _provider = constructed, _wanted = {}, _released = false }
        ---@param keys string[] ordered distinct icon keys
        function demand:setWanted(keys)
          local wanted, seen = {}, {}
          for _, key in ipairs(keys) do
            if not seen[key] then
              seen[key] = true
              wanted[#wanted + 1] = key
            end
          end
          self._wanted = wanted
        end
        ---@param allowance { remaining: integer } shared per-prepare admission budget
        ---@return boolean ready
        ---@return string? failure nonempty cause when a wanted key is unknown
        function demand:prepare(allowance)
          -- The provider admits its own page per call; count that
          -- allowance as consumed even when the set turns ready here.
          allowance.remaining = 0
          local owned = assert(self._provider, "preparation leases own their icon demand")
          local okPrepare, ready, failure = pcall(owned.prepareKeys, owned, self._wanted)
          if not okPrepare then
            return false, tostring(ready)
          end
          if failure ~= nil then
            return false, tostring(failure)
          end
          return ready == true
        end
        ---@param keys string[] committed icon keys
        function demand:commit(keys)
          local owned = assert(self._provider, "preparation leases own their icon demand")
          owned:prepareKeys(keys)
        end
        -- Prewarms one frame-1 quad per key during preparation so the
        -- draw pass only hits the provider quad cache and realizes
        -- nothing. Failures stay silent here; readiness reports them.
        ---@param key string icon key behind the quad
        function demand:warmQuad(key)
          local owned = self._provider
          if owned == nil then
            return
          end
          pcall(owned.quadFor, owned, key, 1)
        end
        ---@param key string prepared icon key
        ---@return MonIconSamplingHandle sampling handle carrying the adopted page lease surface
        function demand:handleFor(key)
          local owned = assert(self._provider, "preparation leases own their icon demand")
          return owned:handleFor(key)
        end
        ---@param key string prepared icon key
        ---@return love.Quad prepared frame-1 quad from the provider cache
        function demand:quadFor(key)
          local owned = assert(self._provider, "preparation leases own their icon demand")
          return owned:quadFor(key, 1)
        end
        function demand:release()
          if self._released then
            return
          end
          self._released = true
          local owned = self._provider
          self._provider = nil
          if owned ~= nil then
            owned:release()
          end
          self._wanted = {}
        end
        return demand
      end
    end
  end
  local demand = { _lease = lease, _wanted = {}, _tokens = {}, _leases = {}, _released = false }
  -- Replaces the wanted union, cancelling pending interests the new
  -- generation no longer watches while adopted leases stay until commit
  -- retires them. Never touches committed readiness by itself.
  ---@param keys string[] ordered distinct icon keys
  function demand:setWanted(keys)
    local wanted, seen = {}, {}
    for _, key in ipairs(keys) do
      if not seen[key] then
        seen[key] = true
        wanted[#wanted + 1] = key
      end
    end
    self._wanted = wanted
    local pool = self._lease._owner._pool
    for key, token in pairs(self._tokens) do
      if not seen[key] then
        pool:cancel(token)
        self._tokens[key] = nil
      end
    end
  end
  -- Admits at most one new pooled interest, polls every pending token,
  -- and adopts every ready lease. Reports ready only once every wanted
  -- key holds an adopted lease.
  ---@param allowance { remaining: integer } shared per-prepare admission budget
  ---@return boolean ready
  ---@return string? failure nonempty cause when a wanted key cannot be borrowed
  function demand:prepare(allowance)
    local pool = self._lease._owner._pool
    for _, key in ipairs(self._wanted) do
      if self._leases[key] == nil and self._tokens[key] == nil and allowance.remaining > 0 then
        self._tokens[key] = pool:request("pokedex/icons/" .. key, POOLED_SAMPLER, "demand")
        allowance.remaining = allowance.remaining - 1
      end
    end
    for _, key in ipairs(self._wanted) do
      if self._leases[key] == nil then
        local token = self._tokens[key]
        if token == nil then
          return false
        end
        local status, cause = pool:poll(token)
        if status == "failed" then
          pool:cancel(token)
          self._tokens[key] = nil
          return false, "compiled Pokedex icon missing for " .. key .. ": " .. tostring(cause)
        elseif status == "ready" then
          local ok, adopted = pcall(pool.acquire, pool, token)
          if not ok then
            self._tokens[key] = nil
            pool:cancel(token)
            return false, "compiled Pokedex icon missing for " .. key .. ": " .. tostring(adopted)
          end
          self._tokens[key] = nil
          self._leases[key] = adopted
        else
          assert(status == "pending", "icon preparation reports pending or ready")
          return false
        end
      end
    end
    return true
  end
  -- Retires adopted leases the committed generation no longer watches and
  -- drops their table entries so later leases re-borrow fresh identities.
  ---@param keys string[] committed icon keys
  function demand:commit(keys)
    local pool = self._lease._owner._pool
    local keep = {}
    for _, key in ipairs(keys) do
      keep[key] = true
    end
    for key, adopted in pairs(self._leases) do
      if not keep[key] then
        pool:release(adopted)
        self._leases[key] = nil
      end
    end
  end
  function demand:release()
    if self._released then
      return
    end
    self._released = true
    local pool = self._lease._owner._pool
    for key, token in pairs(self._tokens) do
      pool:cancel(token)
      self._tokens[key] = nil
    end
    for key, adopted in pairs(self._leases) do
      pool:release(adopted)
      self._leases[key] = nil
    end
    self._wanted = {}
  end
  -- Resolves the adopted pool lease behind one prepared icon key. The
  -- pool-direct fallback draws whole borrowed images, so no quad
  -- accompanies the handle; the provider path above serves quads.
  ---@param key string prepared icon key
  ---@return table<string, unknown> adopted pooled lease carrying the borrowed image
  function demand:handleFor(key)
    local adopted = self._leases[key]
    assert(type(adopted) == "table", "prepared icon keys resolve their lease: " .. tostring(key))
    return adopted
  end
  ---@param key string prepared icon key
  ---@return nil no quads accompany pool-direct borrowed images
  function demand:quadFor(key)
    local _ = key
    return nil
  end
  return demand
end

---@param lease table<string, unknown>
---@param demand table<string, unknown> validated demand under preparation
---@return string[]? wanted ordered distinct pooled portrait paths, nil when no legal selector resolves
---@return string? failure nonempty cause when a picture has no legal selector
local function wantedPortraitPaths(lease, demand)
  local owner = lease._owner
  local browser = demand.purpose == "browser"
  local wanted, seen = {}, {}
  for _, picture in ipairs(demand.pictures) do
    local selector, cause = pictureSelector(owner, picture.specimen, picture.facing, browser)
    if selector == nil then
      return nil, cause
    end
    local path, pathCause = portraitPath(owner, selector)
    if path == nil then
      return nil, pathCause
    end
    assert(type(path) == "string", "portrait paths resolve as strings")
    if not seen[path] then
      seen[path] = true
      wanted[#wanted + 1] = path
    end
  end
  return wanted
end

-- Admits at most one new portrait interest under the shared budget, polls
-- the pending set, and adopts ready leases. Stale paths the new union no
-- longer watches cancel before any new enrollment.
---@param lease table<string, unknown>
---@param wanted string[] ordered distinct pooled portrait paths
---@param allowance { remaining: integer } shared per-prepare admission budget
---@return boolean ready
---@return string? failure nonempty cause when a portrait cannot be borrowed
local function preparePortraits(lease, wanted, allowance)
  local pool = lease._owner._pool
  local keep = {}
  for _, path in ipairs(wanted) do
    keep[path] = true
  end
  for path, token in pairs(lease._portraitTokens) do
    if not keep[path] then
      pool:cancel(token)
      lease._portraitTokens[path] = nil
    end
  end
  for _, path in ipairs(wanted) do
    if lease._portraitLeases[path] == nil and lease._portraitTokens[path] == nil and allowance.remaining > 0 then
      lease._portraitTokens[path] = pool:request(path, POOLED_SAMPLER, "demand")
      allowance.remaining = allowance.remaining - 1
    end
  end
  for _, path in ipairs(wanted) do
    if lease._portraitLeases[path] == nil then
      local token = lease._portraitTokens[path]
      if token == nil then
        return false
      end
      local status, cause = pool:poll(token)
      if status == "failed" then
        pool:cancel(token)
        lease._portraitTokens[path] = nil
        return false, "compiled Pokedex portrait missing at " .. path .. ": " .. tostring(cause)
      elseif status == "ready" then
        local ok, adopted = pcall(pool.acquire, pool, token)
        if not ok then
          lease._portraitTokens[path] = nil
          pool:cancel(token)
          return false, "compiled Pokedex portrait missing at " .. path .. ": " .. tostring(adopted)
        end
        lease._portraitTokens[path] = nil
        lease._portraitLeases[path] = adopted
      else
        assert(status == "pending", "portrait preparation reports pending or ready")
        return false
      end
    end
  end
  return true
end

-- Releases portrait interests the committed generation no longer watches.
---@param lease table<string, unknown>
---@param wanted string[] committed portrait paths
local function commitPortraits(lease, wanted)
  local pool = lease._owner._pool
  local keep = {}
  for _, path in ipairs(wanted) do
    keep[path] = true
  end
  for path, adopted in pairs(lease._portraitLeases) do
    if not keep[path] then
      pool:release(adopted)
      lease._portraitLeases[path] = nil
    end
  end
  for path, token in pairs(lease._portraitTokens) do
    if not keep[path] then
      pool:cancel(token)
      lease._portraitTokens[path] = nil
    end
  end
end

---@param lease table<string, unknown>
---@param demand table<string, unknown> validated demand under preparation
---@return boolean ready
---@return string? failure nonempty cause when the cry bank cannot compile
local function prepareCry(lease, demand)
  if demand.cry == nil then
    return true
  end
  local owner = lease._owner
  local speciesOf = owner._monCatalog.species
  if type(speciesOf) ~= "function" then
    return false, "cry demand needs the resolved mon catalog"
  end
  local okSpecies, record = pcall(speciesOf, owner._monCatalog, demand.cry.species)
  if not okSpecies or type(record) ~= "table" or type(record.nativeId) ~= "number" then
    return false, "cry demand names an unknown species " .. tostring(demand.cry.species)
  end
  local CryPlayer = require("libs.hgss.src.audio.CryPlayer")
  local bank = CryPlayer.bankFor(record.nativeId, demand.cry.form)
  local request = owner._derivedAssets.requestAudioBank
  if type(request) ~= "function" then
    return true
  end
  local ok, ready, failure = pcall(request, bank, "required")
  if not ok then
    return false, tostring(ready)
  end
  if failure ~= nil then
    return false, tostring(failure)
  end
  return ready == true
end

---@param lease table<string, unknown>
---@param demand table<string, unknown> validated demand under preparation
---@return table<string, string> messages prepared message record
---@return string? failure nonempty cause when a required bank cannot be read
local function prepareMessages(lease, demand)
  local owner = lease._owner
  if demand.purpose ~= "registration" then
    return {}
  end
  local snapshot = demand.text.registration
  if type(snapshot) ~= "table" or type(snapshot.displayName) ~= "string" then
    return {}, "registration demands carry their immutable announcement snapshot"
  end
  local provider = owner._messages
  if provider == nil or type(provider.acquireBank) ~= "function" then
    return { registrationAnnouncement = snapshot.displayName }
  end
  -- The announcement bank joins the lease membership once; the release
  -- path returns it exactly once beside the pooled interests.
  if lease._messageBanks[197] ~= true then
    local okAcquire, acquireFailure = pcall(provider.acquireBank, provider, 197)
    if not okAcquire then
      return {}, tostring(acquireFailure)
    end
    lease._messageBanks[197] = true
  end
  local get = provider.get
  if type(get) ~= "function" then
    return { registrationAnnouncement = snapshot.displayName }
  end
  local okGet, template = pcall(get, provider, 197, 871)
  if not okGet or type(template) ~= "table" or type(template.text) ~= "string" or template.text == "" then
    return {}, "the registration announcement bank carries no source 197:871 string"
  end
  local formatted = template.text
  if formatted:find("{name}", 1, true) ~= nil then
    formatted = formatted:gsub("{name}", snapshot.displayName)
  elseif formatted:find("%%s") ~= nil then
    formatted = formatted:gsub("%%s", snapshot.displayName)
  end
  if formatted == "" then
    return {}, "the registration announcement formats to an empty string"
  end
  return { registrationAnnouncement = formatted }
end

---@param owner PokedexPresentationResources
---@param selector string canonical portrait selector
---@return table<string, unknown>? portrait manifest entry with its source viewport
local function portraitEntry(owner, selector)
  if owner._cacheFs == nil then
    return nil
  end
  if owner._portraitManifest == nil then
    local ok, manifest = pcall(function()
      return owner._cacheFs:loadLua(MonCache.portraitManifestPath())
    end)
    if not ok or type(manifest) ~= "table" then
      owner._portraitManifest = false
    else
      owner._portraitManifest = manifest
    end
  end
  if owner._portraitManifest == false then
    return nil
  end
  local entries = owner._portraitManifest.entries
  if type(entries) ~= "table" then
    return nil
  end
  local entry = entries[selector]
  if type(entry) ~= "table" then
    return nil
  end
  return entry
end

---@param lease table<string, unknown> preparation lease owning the serial surfaces
---@param allowance { remaining: integer } shared per-prepare admission budget
---@return boolean ready
---@return string? failure nonempty cause when a surface cannot be realized
local function prepareSurfaces(lease, allowance)
  local graphics = lease._owner._graphics
  if type(graphics) ~= "table" or type(graphics.newCanvas) ~= "function" then
    return true
  end
  local pending = false
  for _, surface in ipairs(lease._surfaces) do
    if surface.canvas == nil then
      if allowance.remaining > 0 then
        local ok, canvas = pcall(graphics.newCanvas, SURFACE_WIDTH, SURFACE_HEIGHT)
        if not ok then
          return false, "the pokedex compositor cannot realize its serial surfaces: " .. tostring(canvas)
        end
        surface.canvas = canvas
        allowance.remaining = allowance.remaining - 1
      else
        pending = true
      end
    end
  end
  for _, surface in ipairs(lease._surfaces) do
    if surface.canvas == nil then
      pending = true
    end
  end
  return not pending
end

---@param owner PokedexPresentationResources
---@param selector string canonical portrait selector
---@param handle table<string, unknown> adopted pooled lease carrying the borrowed image
---@return love.Quad? prepared static frame0 viewport, nil when no authored entry or canvas geometry resolves
local function pictureQuadFor(owner, selector, handle)
  local graphics = owner._graphics
  if type(graphics) ~= "table" or type(graphics.newQuad) ~= "function" then
    return nil
  end
  local entry = portraitEntry(owner, selector)
  if entry == nil then
    return nil
  end
  local image = handle.image
  if image == nil or type(image.getWidth) ~= "function" or type(image.getHeight) ~= "function" then
    return nil
  end
  local frame = { x = entry.x, y = entry.y, width = entry.width, height = entry.height }
  if type(entry.frames) == "table" and type(entry.frames[1]) == "table" then
    frame = entry.frames[1]
  end
  if type(frame.x) ~= "number" or type(frame.y) ~= "number" then
    return nil
  end
  if type(frame.width) ~= "number" or type(frame.height) ~= "number" then
    return nil
  end
  local ok, quad =
    pcall(graphics.newQuad, frame.x, frame.y, frame.width, frame.height, image:getWidth(), image:getHeight())
  if not ok then
    return nil
  end
  return quad
end

-- Derives the authored back vertical correction from the resolved
-- portrait entries: the back source viewport minus its front viewport,
-- defaulting to zero wherever no authored pair resolves.
---@param owner PokedexPresentationResources
---@param selector string canonical back portrait selector
---@return integer back vertical correction in source pixels
local function backYOffsetFor(owner, selector)
  local back = portraitEntry(owner, selector)
  if back == nil or type(back.y) ~= "number" then
    return 0
  end
  local frontSelector = selector:gsub("/back$", "")
  if frontSelector == selector then
    return 0
  end
  local front = portraitEntry(owner, frontSelector)
  if front == nil or type(front.y) ~= "number" then
    return 0
  end
  return back.y - front.y
end

---@param picture table<string, unknown> demanded picture slot
---@return boolean true when the slot needs a composed Spinda canvas
local function needsSpinda(picture)
  if type(picture.specimen) ~= "table" then
    return false
  end
  if picture.specimen.species ~= "SPINDA" then
    return false
  end
  return picture.mode ~= "silhouette"
end

---@param selector string canonical portrait selector
---@return string declared image gender behind the selector
local function selectorGender(selector)
  local gender = selector:match("^[^/]+/[^/]+/([^/]+)/")
  if gender == "female" then
    return "female"
  end
  return "male"
end

-- Composes at most one new Spinda canvas per prepare call under the
-- shared budget: every demanded slot keeps exactly one current record,
-- replaced in place when its detached facts change. Slots without
-- host canvases stay bound-only; a missing authored policy fails the
-- demand instead of drawing unspotted art.
---@param owner PokedexPresentationResources
---@param lease table<string, unknown>
---@param demand table<string, unknown> validated demand under preparation
---@param allowance { remaining: integer } shared per-prepare admission budget
---@return boolean ready
---@return string? failure nonempty cause when a required Spinda canvas cannot be composed
local function prepareSpindaPictures(owner, lease, demand, allowance)
  local graphics = owner._graphics
  if type(graphics) ~= "table" or type(graphics.newCanvas) ~= "function" then
    return true
  end
  local manifest = assert(owner._manifest, "prepared bundles carry their manifest")
  local ready = true
  for _, picture in ipairs(demand.pictures) do
    if needsSpinda(picture) then
      local specimen = picture.specimen
      local facing = picture.facing
      local frame = 0
      if facing == "back" then
        frame = 1
      end
      local selector = pictureSelector(owner, specimen, facing, demand.purpose == "browser")
      if selector == nil then
        return false, "spinda pictures need their declared portrait variant"
      end
      local personality = specimen.personality
      if type(personality) ~= "number" then
        personality = 0
      end
      local shiny = specimen.shiny == true
      local gender = specimen.gender
      if gender ~= "male" and gender ~= "female" then
        gender = selectorGender(selector)
      end
      local specKey = table.concat({
        tostring(demand.purpose),
        tostring(picture.slot),
        tostring(facing),
        tostring(personality),
        tostring(shiny),
        tostring(gender),
        tostring(frame),
      }, "|")
      local stored = lease._spindaCanvases[picture.slot]
      if type(stored) ~= "table" or stored.specKey ~= specKey then
        ready = false
        if allowance.remaining > 0 then
          local path = portraitPath(owner, selector)
          local base = path ~= nil and lease._portraitLeases[path] or nil
          local policy = manifest.spinda
          if type(policy) ~= "table" then
            return false, "the compiled manifest carries no Spinda personalization"
          end
          local ok, record = pcall(owner._renderer.prepareSpindaPicture, owner._renderer, {
            base = base,
            quad = base ~= nil and pictureQuadFor(owner, selector, base) or nil,
            policy = policy,
            personality = personality,
            shiny = shiny,
            gender = gender,
            frame = frame,
          })
          if not ok then
            return false, tostring(record)
          end
          if type(stored) == "table" and type(stored.record) == "table" then
            stored.record:release()
          end
          lease._spindaCanvases[picture.slot] = { specKey = specKey, record = record }
          allowance.remaining = allowance.remaining - 1
        end
      end
    end
  end
  return ready
end

-- Releases Spinda records the given demand no longer watches. The
-- committed bundle keeps its own records until adoption replaces them.
---@param owner PokedexPresentationResources
---@param lease table<string, unknown>
---@param demand table<string, unknown> demand selecting the retained slots
local function pruneSpindaCanvases(owner, lease, demand)
  local _ = owner
  local keep = {}
  for _, picture in ipairs(demand.pictures) do
    if needsSpinda(picture) then
      keep[picture.slot] = true
    end
  end
  for slot, stored in pairs(lease._spindaCanvases) do
    if not keep[slot] then
      if type(stored) == "table" and type(stored.record) == "table" then
        stored.record:release()
      end
      lease._spindaCanvases[slot] = nil
    end
  end
end

---@param owner PokedexPresentationResources
---@param lease table<string, unknown>
---@param demand table<string, unknown> validated demand under preparation
---@return table<string, unknown>? bundle borrowed read-only ready bundle
---@return string? failure nonempty cause when the demand cannot become ready
local function prepareBundle(owner, lease, demand)
  local manifestReady, manifestFailure = ensureManifest(owner)
  if not manifestReady then
    return nil, manifestFailure
  end
  local manifest = assert(owner._manifest, "prepared bundles carry their manifest")
  local allowance = { remaining = 1 }
  -- The six serial surfaces realize across separate prepare calls under
  -- the same single admission budget before any chrome or canvas work
  -- runs. Headless seams without host canvases skip this family.
  local surfacesReady, surfacesFailure = prepareSurfaces(lease, allowance)
  if surfacesFailure ~= nil then
    return nil, surfacesFailure
  end
  -- The chrome group enrolls its paths under the same single admission
  -- budget before any portrait or canvas work runs. Roles enroll in
  -- sorted order so staged preparation stays deterministic.
  local chromeReady = true
  do
    local pool = owner._pool
    local chrome = manifest.chrome
    assert(type(chrome) == "table", "prepared bundles carry their chrome inventory")
    local roles = {}
    for role in pairs(chrome) do
      roles[#roles + 1] = role
    end
    table.sort(roles, function(a, b)
      return tostring(a) < tostring(b)
    end)
    for _, role in ipairs(roles) do
      local record = chrome[role]
      assert(type(record) == "table", "chrome records stay records")
      local path = record.path
      if type(path) ~= "string" or path == "" then
        return nil, "chrome role " .. tostring(role) .. " carries no path"
      end
      if lease._chromeLeases[path] == nil and lease._chromeTokens[path] == nil and allowance.remaining > 0 then
        lease._chromeTokens[path] = pool:request(path, POOLED_SAMPLER, "demand")
        allowance.remaining = allowance.remaining - 1
      end
    end
    for _, role in ipairs(roles) do
      local record = chrome[role]
      assert(type(record) == "table", "chrome records stay records")
      local path = record.path --[[@as string]]
      if lease._chromeLeases[path] == nil then
        local token = lease._chromeTokens[path]
        if token == nil then
          chromeReady = false
          break
        end
        local status, cause = pool:poll(token)
        if status == "failed" then
          pool:cancel(token)
          lease._chromeTokens[path] = nil
          return nil, "compiled Pokedex chrome missing at " .. path .. ": " .. tostring(cause)
        elseif status == "ready" then
          local ok, adopted = pcall(pool.acquire, pool, token)
          if not ok then
            lease._chromeTokens[path] = nil
            pool:cancel(token)
            return nil, "compiled Pokedex chrome missing at " .. path .. ": " .. tostring(adopted)
          end
          lease._chromeTokens[path] = nil
          lease._chromeLeases[path] = adopted
        else
          assert(status == "pending", "chrome preparation reports pending or ready")
          chromeReady = false
          break
        end
      end
    end
  end
  -- Icon keys ride the lease-owned provider with its own committed plus
  -- pending union; a failed icon family surfaces before portraits enroll
  -- further work.
  local icons = assert(lease._icons, "preparation leases own their icon demand")
  icons:setWanted(demand.iconKeys)
  local iconsReady, iconsFailure = icons:prepare(allowance)
  if iconsFailure ~= nil then
    return nil, iconsFailure
  end
  -- Portrait slots resolve through the same budget after icons enroll, so
  -- one unready family never serializes the other.
  -- A picture with no legal selector fails the whole demand; an empty
  -- picture list prepares nothing.
  local wantedPortraits, portraitCause = wantedPortraitPaths(lease, demand)
  if wantedPortraits == nil then
    return nil, portraitCause
  end
  local portraitsReady, portraitsFailure = preparePortraits(lease, wantedPortraits, allowance)
  if portraitsFailure ~= nil then
    return nil, portraitsFailure
  end
  -- Cry banks compile through the provisioner seam without spending pool
  -- admission; a missing bank gates the bundle like any other family.
  local cryReady, cryFailure = prepareCry(lease, demand)
  if cryFailure ~= nil then
    return nil, cryFailure
  end
  -- Messages resolve through the borrowed provider membership; the
  -- detached registration snapshot already carries its display facts.
  local messages, messagesFailure = prepareMessages(lease, demand)
  if messagesFailure ~= nil then
    return nil, messagesFailure
  end
  -- Spinda canvases compose after portraits adopt their bases, at most
  -- one new canvas per call, and gate readiness wherever host canvases
  -- back the seam.
  local spindaReady, spindaFailure = prepareSpindaPictures(owner, lease, demand, allowance)
  if spindaFailure ~= nil then
    return nil, spindaFailure
  end
  -- Prepared icon quads warm during preparation so the draw pass only
  -- hits the provider cache and realizes nothing.
  warmProviderQuads(lease, demand.iconKeys)
  if
    not chromeReady
    or not iconsReady
    or not portraitsReady
    or not cryReady
    or not surfacesReady
    or not spindaReady
  then
    return nil, nil
  end
  local pictures = {}
  for _, picture in ipairs(demand.pictures) do
    local selector = pictureSelector(owner, picture.specimen, picture.facing, demand.purpose == "browser")
    assert(type(selector) == "string", "prepared pictures carry their selector")
    local path = portraitPath(owner, selector)
    assert(type(path) == "string", "prepared pictures carry their pooled path")
    local handle = lease._portraitLeases[path]
    local quad = nil
    if handle ~= nil then
      quad = pictureQuadFor(owner, selector, handle)
    end
    local backYOffset = 0
    if picture.facing == "back" then
      backYOffset = backYOffsetFor(owner, selector)
    end
    local stored = lease._spindaCanvases[picture.slot]
    local spinda = nil
    if type(stored) == "table" then
      spinda = stored.record
    end
    pictures[picture.slot] = {
      handle = handle,
      quad = quad,
      selector = selector,
      facing = picture.facing,
      mode = picture.mode,
      backYOffset = backYOffset,
      spinda = spinda,
    }
  end
  return {
    renderer = owner._renderer,
    manifest = manifest,
    animations = manifest.animations,
    fonts = { body = owner._text, header = owner._text },
    messages = messages,
    chrome = lease._chromeLeases,
    pictures = pictures,
    icons = icons,
    surfaces = lease._surfaces,
  }
end

---@param owner PokedexPresentationResources
---@param lease table<string, unknown>
local function releaseLeaseInterests(owner, lease)
  local pool = owner._pool
  for _, token in pairs(lease._portraitTokens) do
    pool:cancel(token)
  end
  lease._portraitTokens = {}
  for _, adopted in pairs(lease._portraitLeases) do
    pool:release(adopted)
  end
  lease._portraitLeases = {}
  for _, token in pairs(lease._chromeTokens) do
    pool:cancel(token)
  end
  lease._chromeTokens = {}
  for _, adopted in pairs(lease._chromeLeases) do
    pool:release(adopted)
  end
  lease._chromeLeases = {}
  for _, stored in pairs(lease._spindaCanvases) do
    if type(stored) == "table" and type(stored.record) == "table" then
      stored.record:release()
    end
  end
  lease._spindaCanvases = {}
  if type(lease._surfaces) == "table" then
    for _, surface in ipairs(lease._surfaces) do
      if type(surface) == "table" and surface.canvas ~= nil then
        if type(surface.canvas.release) == "function" then
          surface.canvas:release()
        end
        surface.canvas = nil
      end
    end
  end
  for bankId in pairs(lease._messageBanks) do
    local provider = owner._messages
    if provider ~= nil and type(provider.releaseBank) == "function" then
      provider:releaseBank(bankId)
    end
  end
  lease._messageBanks = {}
  local icons = lease._icons
  lease._icons = nil
  if icons ~= nil then
    icons:release()
  end
end

---@param owner PokedexPresentationResources
---@param lease table<string, unknown>
---@param demand table<string, unknown>
---@return table<string, unknown> prepare outcome
local function prepareLease(owner, lease, demand)
  assert(not owner._released, "pokedex preparation is released")
  assert(lease._released ~= true, "the preparation lease is released")
  assert(lease._owner == owner, "leases prepare through their owner")
  local okDemand, demandError = pcall(checkDemand, demand, lease._purpose)
  if not okDemand then
    return { kind = "failed", error = tostring(demandError) }
  end
  -- A committed generation answers immediately; a repeated pending key
  -- resumes its own progress; any other key replaces the pending set and
  -- can never adopt the superseded generation afterwards. A fresh
  -- replacement always answers pending on its first call even when every
  -- interest is already resident, so an obsolete key can never publish
  -- over the committed view in the same call that enrolls it.
  if lease._committed ~= nil and lease._committed.key == demand.key then
    return { kind = "ready", key = demand.key, assets = lease._committedAssets }
  end
  local deferAdoption = false
  if lease._pending == nil or lease._pending.key ~= demand.key then
    if lease._pending ~= nil then
      local pool = owner._pool
      for _, token in pairs(lease._portraitTokens) do
        pool:cancel(token)
      end
      lease._portraitTokens = {}
    end
    lease._pending = demand
    deferAdoption = true
    pruneSpindaCanvases(owner, lease, demand)
  end
  local bundle, failure = prepareBundle(owner, lease, demand)
  if failure ~= nil then
    -- Failure unwinds pending interests and leaves the committed bundle
    -- internally consistent; the error carries its original cause.
    local pool = owner._pool
    for _, token in pairs(lease._portraitTokens) do
      pool:cancel(token)
    end
    lease._portraitTokens = {}
    for path, adopted in pairs(lease._portraitLeases) do
      local wanted = false
      if lease._committed ~= nil then
        local committedPortraits = wantedPortraitPaths(lease, lease._committed)
        for _, committedPath in ipairs(committedPortraits or {}) do
          if committedPath == path then
            wanted = true
          end
        end
      end
      if not wanted then
        pool:release(adopted)
        lease._portraitLeases[path] = nil
      end
    end
    return { kind = "failed", error = failure }
  end
  if bundle == nil then
    return { kind = "pending" }
  end
  if deferAdoption then
    -- A fresh replacement never adopts in the same call that enrolls
    -- it, so an obsolete key can never publish over the committed view
    -- while its interests are still being admitted.
    return { kind = "pending" }
  end
  -- Whole-bundle adoption: only the keyed generation publishes, then the
  -- icon union retires to the committed set and stale portrait interests
  -- return to the shared owner. The same demand resolved its portraits
  -- above, so adoption cannot observe a new selector absence.
  local wantedPortraits = wantedPortraitPaths(lease, demand)
  assert(wantedPortraits ~= nil, "adopted demands carry their portrait paths")
  commitPortraits(lease, wantedPortraits)
  pruneSpindaCanvases(owner, lease, demand)
  local icons = assert(lease._icons, "preparation leases own their icon demand")
  icons:commit(demand.iconKeys)
  lease._committed = demand
  lease._committedAssets = bundle
  lease._pending = nil
  return { kind = "ready", key = demand.key, assets = bundle }
end

-- Acquires one opaque per-open preparation lease. Leases own only demand
-- membership; release is idempotent and never touches borrowed owners.
-- The purpose is fixed for the lease lifetime.
---@param opts { purpose: string }?
---@return table<string, unknown> lease with prepare and release
function PokedexPresentationResources:acquire(opts)
  assert(not self._released, "pokedex preparation is released")
  local purpose = opts ~= nil and opts.purpose or "browser"
  assert(purpose == "browser" or purpose == "registration", "leases acquire a browser or registration purpose")
  local owner = self
  local lease = {
    _owner = owner,
    _purpose = purpose,
    _released = false,
    _committed = nil,
    _committedAssets = nil,
    _pending = nil,
    _icons = nil,
    _portraitTokens = {},
    _portraitLeases = {},
    _chromeTokens = {},
    _chromeLeases = {},
    _spindaCanvases = {},
    _messageBanks = {},
    _surfaces = {},
  }
  -- The six serial compositor surfaces start bound-only; prepare
  -- realizes their canvases across separate calls under the shared
  -- allowance wherever host canvases back the seam.
  for _, name in ipairs(SURFACE_NAMES) do
    lease._surfaces[#lease._surfaces + 1] =
      { name = name, canvas = nil, width = SURFACE_WIDTH, height = SURFACE_HEIGHT }
  end
  lease._icons = newIconDemand(lease)
  function lease:prepare(demand)
    return prepareLease(owner, self, demand)
  end
  function lease:release()
    if self._released then
      return
    end
    self._released = true
    if not owner._released then
      releaseLeaseInterests(owner, self)
      for index, other in ipairs(owner._leases) do
        if other == self then
          table.remove(owner._leases, index)
          break
        end
      end
    end
  end
  self._leases[#self._leases + 1] = lease
  return lease
end

-- Idempotent release of the field lifetime: invalidates every remaining
-- lease, returns every adopted borrow exactly once, and releases only the
-- one shared renderer. Borrowed pool, text, message, and audio owners
-- stay alive.
function PokedexPresentationResources:release()
  if self._released then
    return
  end
  self._released = true
  for _, lease in ipairs(self._leases) do
    lease._released = true
    releaseLeaseInterests(self, lease)
  end
  self._leases = {}
  local renderer = self._renderer
  self._renderer = nil
  if renderer ~= nil then
    renderer:release()
  end
  self._manifest = nil
  self._manifestReady = false
  self._portraitManifest = nil
end

return PokedexPresentationResources
