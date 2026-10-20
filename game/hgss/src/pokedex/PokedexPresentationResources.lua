-- The field-owned Pokedex preparation owner: one lazy per-field resource
-- lifetime borrowing the session image pool, derived assets, caches, font0,
-- messages, and audio. It builds the single shared renderer once and hands
-- out independent per-open leases for the browser and the registration
-- card. Each lease owns exactly one icon demand over the shared pool and
-- publishes whole ready bundles only: icons alone never retire a visible
-- page. At most the committed generation plus one pending generation stays
-- resident; obsolete keys never publish. Neither the owner nor its leases
-- dispose borrowed pool, message, font0, or audio owners.

local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
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
---@field _headerFont table<string, unknown>? owned font4 header renderer, created once on first font4 demand
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
    _headerFont = nil,
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
  if demand.profile ~= nil then
    assert(type(demand.profile) == "string" and demand.profile ~= "", "demands name their measurement profile")
  end
  assert(type(demand.iconKeys) == "table", "demands carry their icon keys")
  for _, key in ipairs(demand.iconKeys) do
    assert(type(key) == "string" and key ~= "", "icon keys arrive as strings")
  end
  if demand.spriteRoles ~= nil then
    assert(type(demand.spriteRoles) == "table", "sprite role demand arrives as a list")
    for _, role in ipairs(demand.spriteRoles) do
      assert(type(role) == "string" and role ~= "", "demanded sprite roles arrive as strings")
    end
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

-- The closed page-local chrome closure: backgrounds, cell parts, and
-- sprite animation cells behind one generated page role. Footprints and
-- every other role enter only when the page references them through one
-- of those inventories; the whole-manifest union never stages.
---@param manifest table<string, unknown> loaded presentation manifest
---@param pageRole string generated page role under preparation
---@return string[]? sorted unique chrome roles behind the page
---@return string? failure nonempty cause when the page or one of its references is unknown
local function requiredChromeRoles(manifest, pageRole)
  local pages = manifest.pages
  if type(pages) ~= "table" then
    return nil, "the pokedex manifest carries no pages table"
  end
  local page = pages[pageRole]
  if type(page) ~= "table" then
    return nil, "the pokedex manifest carries no page " .. tostring(pageRole)
  end
  local cells = manifest.cells
  if type(cells) ~= "table" then
    cells = {}
  end
  local sprites = manifest.sprites
  if type(sprites) ~= "table" then
    sprites = {}
  end
  local animations = manifest.animations
  if type(animations) ~= "table" then
    animations = {}
  end
  local seen, roles = {}, {}
  ---@param role unknown referenced chrome role
  ---@return string? failure nonempty cause when the reference names no role
  local function add(role)
    if type(role) ~= "string" or role == "" then
      return "a page reference names no chrome role"
    end
    if not seen[role] then
      seen[role] = true
      roles[#roles + 1] = role
    end
    return nil
  end
  ---@param cellRole unknown referenced cell role
  ---@return string? failure nonempty cause when the cell or one of its parts is unknown
  local function addCellParts(cellRole)
    local cell = cells[cellRole]
    if type(cell) ~= "table" then
      return "the " .. pageRole .. " page references an unknown cell " .. tostring(cellRole)
    end
    if type(cell.parts) ~= "table" then
      return "cell " .. tostring(cellRole) .. " carries no parts"
    end
    for _, part in ipairs(cell.parts) do
      if type(part) ~= "table" then
        return "cell " .. tostring(cellRole) .. " carries no part record"
      end
      local failure = add(part.chrome)
      if failure ~= nil then
        return failure
      end
    end
    return nil
  end
  if type(page.backgrounds) == "table" then
    for _, pane in ipairs({ "information", "controls" }) do
      local entries = page.backgrounds[pane]
      if type(entries) == "table" then
        for _, entry in ipairs(entries) do
          if type(entry) ~= "table" then
            return nil, "the " .. pageRole .. " page carries no background record"
          end
          local failure = add(entry.chrome)
          if failure ~= nil then
            return nil, failure
          end
        end
      end
    end
  end
  if type(page.cells) == "table" then
    for _, cellRole in ipairs(page.cells) do
      local failure = addCellParts(cellRole)
      if failure ~= nil then
        return nil, failure
      end
    end
  end
  if type(page.sprites) == "table" then
    for _, spriteRole in ipairs(page.sprites) do
      local sprite = sprites[spriteRole]
      if type(sprite) ~= "table" then
        return nil, "the " .. pageRole .. " page references an unknown sprite " .. tostring(spriteRole)
      end
      if type(sprite.animation) ~= "string" or sprite.animation == "" then
        return nil, "sprite " .. tostring(spriteRole) .. " names no animation"
      end
      local animation = animations[sprite.animation]
      if type(animation) ~= "table" then
        return nil, "sprite " .. tostring(spriteRole) .. " references an unknown animation"
      end
      if type(animation.frames) ~= "table" then
        return nil, "animation " .. tostring(sprite.animation) .. " carries no frames"
      end
      for _, frame in ipairs(animation.frames) do
        if type(frame) ~= "table" or type(frame.cell) ~= "string" then
          return nil, "animation " .. tostring(sprite.animation) .. " names no cell"
        end
        local failure = addCellParts(frame.cell)
        if failure ~= nil then
          return nil, failure
        end
      end
    end
  end
  table.sort(roles)
  return roles
end

-- Releases one owned sprite viewport: realized viewports release their GPU
-- handle; doubles without one simply leave the ownership ledger.
---@param quad table<string, unknown> owned prepared viewport
local function releaseSpriteQuad(quad)
  if type(quad) == "table" and type(quad.release) == "function" then
    quad:release()
  end
end

-- Resolves one demanded sprite role to its selected frame cells: the resting
-- frame for statically placed roles, the full active sequence for explicit
-- dynamic roles. Every manifest reference failure names its cause.
---@param manifest table<string, unknown> loaded presentation manifest
---@param pageRole string generated page role under preparation
---@param spriteRole string demanded sprite role
---@param dynamic boolean true when the demand names the role explicitly
---@return table[]? selected ordered frame cells with their parts
---@return string? failure nonempty cause when the role cannot resolve
local function resolveSpriteCells(manifest, pageRole, spriteRole, dynamic)
  local inventory = manifest.sprites
  if type(inventory) ~= "table" then
    return nil, "the pokedex manifest carries no sprite inventory"
  end
  local sprite = inventory[spriteRole]
  if type(sprite) ~= "table" then
    return nil, "the " .. pageRole .. " page references an unknown sprite " .. tostring(spriteRole)
  end
  if type(sprite.animation) ~= "string" or sprite.animation == "" then
    return nil, "sprite " .. tostring(spriteRole) .. " names no animation"
  end
  local animations = manifest.animations
  if type(animations) ~= "table" then
    return nil, "the pokedex manifest carries no animations table"
  end
  local animation = animations[sprite.animation]
  if type(animation) ~= "table" then
    return nil, "sprite " .. tostring(spriteRole) .. " references an unknown animation"
  end
  if type(animation.frames) ~= "table" or #animation.frames < 1 then
    return nil, "animation " .. tostring(sprite.animation) .. " carries no frames"
  end
  local cells = manifest.cells
  if type(cells) ~= "table" then
    return nil, "the pokedex manifest carries no cells table"
  end
  local selected = {}
  for index, frame in ipairs(animation.frames) do
    if dynamic or index == 1 then
      if type(frame) ~= "table" or type(frame.cell) ~= "string" then
        return nil, "animation " .. tostring(sprite.animation) .. " names no cell"
      end
      local cell = cells[frame.cell]
      if type(cell) ~= "table" then
        return nil, "sprite " .. tostring(spriteRole) .. " references an unknown cell " .. tostring(frame.cell)
      end
      if type(cell.parts) ~= "table" then
        return nil, "cell " .. tostring(frame.cell) .. " carries no parts"
      end
      selected[#selected + 1] = { frame = index, parts = cell.parts }
    end
  end
  return selected
end

-- The finite page-local sprite viewport closure: every genuinely placed
-- sprite role on the demanded page (anchored off the unplaced origin
-- sentinel, exactly the renderer predicate) resolves its resting frame,
-- while the bounded explicit dynamic roles the demand names resolve their
-- full active sequence. Records parked at the origin stay out; the renderer
-- never draws them. Returns the ordered role entries or a failure.
---@param manifest table<string, unknown> loaded presentation manifest
---@param pageRole string generated page role under preparation
---@param dynamicRoles string[] explicit demanded sprite roles
---@return table[]? ordered role entries with their dynamic selection
---@return string? failure nonempty cause when the closure cannot resolve
local function wantedSpriteRoles(manifest, pageRole, dynamicRoles)
  local pages = manifest.pages
  if type(pages) ~= "table" then
    return nil, "the pokedex manifest carries no pages table"
  end
  local page = pages[pageRole]
  if type(page) ~= "table" then
    return nil, "the pokedex manifest carries no page " .. tostring(pageRole)
  end
  local inventory = manifest.sprites
  if type(inventory) ~= "table" then
    return nil, "the pokedex manifest carries no sprite inventory"
  end
  local order, dynamic, onPage = {}, {}, {}
  if type(page.sprites) == "table" then
    for _, spriteRole in ipairs(page.sprites) do
      if type(spriteRole) ~= "string" or spriteRole == "" then
        return nil, "the " .. pageRole .. " page names no sprite role"
      end
      local sprite = inventory[spriteRole]
      if type(sprite) ~= "table" then
        return nil, "the " .. pageRole .. " page references an unknown sprite " .. tostring(spriteRole)
      end
      onPage[spriteRole] = true
      if sprite.x ~= 0 or sprite.y ~= 0 then
        if dynamic[spriteRole] == nil then
          dynamic[spriteRole] = false
          order[#order + 1] = spriteRole
        end
      end
    end
  end
  for _, spriteRole in ipairs(dynamicRoles) do
    if not onPage[spriteRole] then
      return nil, "the demand names a sprite role outside page " .. pageRole .. ": " .. tostring(spriteRole)
    end
    if dynamic[spriteRole] == nil then
      dynamic[spriteRole] = true
      order[#order + 1] = spriteRole
    else
      dynamic[spriteRole] = true
    end
  end
  local entries = {}
  for _, spriteRole in ipairs(order) do
    entries[#entries + 1] = { role = spriteRole, dynamic = dynamic[spriteRole] == true }
  end
  return entries
end

-- Prepares the finite page-local sprite viewports before any raster draw:
-- every required source rectangle resolves against its adopted chrome image,
-- validates inside the image bounds, and realizes at most the remaining
-- admission budget, one viewport per call. Identical chrome rectangles share
-- one viewport even across roles. Returns readiness plus, when whole, the
-- immutable role/frame/part map and its owned viewport membership.
---@param owner PokedexPresentationResources
---@param lease table<string, unknown> preparation lease owning the viewports
---@param manifest table<string, unknown> loaded presentation manifest
---@param demand table<string, unknown> validated demand under preparation
---@param rolePath table<string, string> page chrome role to pooled path
---@param allowance { remaining: integer } shared per-prepare admission budget
---@return boolean ready
---@return string? failure nonempty cause when a required viewport cannot be prepared
---@return table<string, unknown>? spriteParts immutable map when whole
---@return table<string, boolean>? spriteKeys owned viewport membership when whole
local function prepareSpriteParts(owner, lease, manifest, demand, rolePath, allowance)
  local dynamicRoles = demand.spriteRoles or {}
  local wanted, closureFailure = wantedSpriteRoles(manifest, demand.pageRole, dynamicRoles)
  if wanted == nil then
    return false, closureFailure
  end
  local graphics = owner._graphics
  if type(graphics) ~= "table" or type(graphics.newQuad) ~= "function" then
    -- Seams without viewport realization publish no parts; only a
    -- graphics-backed draw can consume them.
    return true, nil, {}, {}
  end
  -- Resolve every required viewport before admitting any: bounds validate
  -- against the adopted chrome image, so a malformed rectangle fails with
  -- its sprite role instead of realizing.
  local needed, seen, keyOrder, roleFrames = {}, {}, {}, {}
  for _, entry in ipairs(wanted) do
    local cells, cellsFailure = resolveSpriteCells(manifest, demand.pageRole, entry.role, entry.dynamic)
    if cells == nil then
      return false, cellsFailure
    end
    local frames = {}
    roleFrames[entry.role] = frames
    for _, selected in ipairs(cells) do
      local frameKeys = {}
      frames[selected.frame] = frameKeys
      for _, part in ipairs(selected.parts) do
        if type(part) ~= "table" then
          return false, "sprite " .. entry.role .. " carries no part record"
        end
        if type(part.chrome) ~= "string" or part.chrome == "" then
          return false, "sprite " .. entry.role .. " names no chrome role"
        end
        local source = part.source
        if type(source) ~= "table" then
          return false, "sprite " .. entry.role .. " carries no source viewport"
        end
        local path = rolePath[part.chrome]
        if type(path) ~= "string" then
          return false, "sprite " .. entry.role .. " watches chrome outside its page: " .. tostring(part.chrome)
        end
        local handle = lease._chromeLeases[path]
        if handle == nil then
          return false, nil
        end
        local image = handle.image
        if image == nil or type(image.getWidth) ~= "function" or type(image.getHeight) ~= "function" then
          return false, "sprite " .. entry.role .. " watches chrome without a measurable image"
        end
        local imageWidth, imageHeight = image:getWidth(), image:getHeight()
        if
          type(source.x) ~= "number"
          or type(source.y) ~= "number"
          or type(source.width) ~= "number"
          or type(source.height) ~= "number"
        then
          return false, "sprite " .. entry.role .. " carries no source viewport"
        end
        if
          source.x < 0
          or source.y < 0
          or source.width <= 0
          or source.height <= 0
          or source.x + source.width > imageWidth
          or source.y + source.height > imageHeight
        then
          return false,
            "sprite "
              .. entry.role
              .. " references a viewport outside its chrome image (x="
              .. tostring(source.x)
              .. ",y="
              .. tostring(source.y)
              .. ",w="
              .. tostring(source.width)
              .. ",h="
              .. tostring(source.height)
              .. " on "
              .. tostring(imageWidth)
              .. "x"
              .. tostring(imageHeight)
              .. ")"
        end
        local key = table.concat({
          path,
          tostring(source.x),
          tostring(source.y),
          tostring(source.width),
          tostring(source.height),
        }, "|")
        if not seen[key] then
          seen[key] = true
          keyOrder[#keyOrder + 1] = key
          needed[key] = { role = entry.role, handle = handle, source = source }
        end
        frameKeys[#frameKeys + 1] = { key = key, part = part }
      end
    end
  end
  -- Admit at most the remaining budget; anything still missing keeps the
  -- generation pending without publishing a partial map.
  for _, key in ipairs(keyOrder) do
    if lease._spritePartQuads[key] == nil then
      if allowance.remaining <= 0 then
        return false, nil
      end
      local item = needed[key]
      local source = item.source
      local image = item.handle.image
      local ok, quad =
        pcall(graphics.newQuad, source.x, source.y, source.width, source.height, image:getWidth(), image:getHeight())
      if not ok then
        return false,
          "sprite " .. item.role .. " cannot realize its viewport (x=" .. tostring(source.x) .. ",y=" .. tostring(
            source.y
          ) .. ",w=" .. tostring(source.width) .. ",h=" .. tostring(source.height) .. ") on page " .. tostring(
            demand.pageRole
          ) .. ": " .. tostring(quad)
      end
      lease._spritePartQuads[key] = quad
      allowance.remaining = allowance.remaining - 1
    end
  end
  -- Publish a fresh immutable map per generation, never an alias of the
  -- working ledger, so pending work cannot mutate the displayed bundle.
  -- Roles sharing one animation closure reference the same viewport.
  local spriteParts = {}
  for _, entry in ipairs(wanted) do
    local frames = {}
    spriteParts[entry.role] = frames
    for frameIndex, frameKeys in pairs(roleFrames[entry.role]) do
      local parts = {}
      frames[frameIndex] = parts
      for _, frameKey in ipairs(frameKeys) do
        local item = needed[frameKey.key]
        local quad = lease._spritePartQuads[frameKey.key]
        assert(quad ~= nil, "admitted viewports resolve their quad")
        parts[#parts + 1] = {
          handle = item.handle,
          quad = quad,
          partOffsetX = frameKey.part.x or 0,
          partOffsetY = frameKey.part.y or 0,
          flipX = frameKey.part.flipX == true,
          flipY = frameKey.part.flipY == true,
        }
      end
    end
  end
  local spriteKeys = {}
  for _, key in ipairs(keyOrder) do
    spriteKeys[key] = true
  end
  return true, nil, spriteParts, spriteKeys
end

---@param owner PokedexPresentationResources
---@param speciesKey string
---@return integer? stable catalog numeric species identity
---@return string? failure nonempty cause when the species is unknown
local function nativeSpeciesId(owner, speciesKey)
  local speciesOf = owner._monCatalog.species
  if type(speciesOf) ~= "function" then
    return nil, "prepared text needs the resolved mon catalog"
  end
  local ok, record = pcall(speciesOf, owner._monCatalog, speciesKey)
  if not ok or type(record) ~= "table" or type(record.nativeId) ~= "number" then
    return nil, "prepared text names an unknown species " .. tostring(speciesKey)
  end
  return record.nativeId
end

-- Resolves the display number behind one dex-number slot: the position
-- of the species in the demanded order of the borrowed generated
-- catalog, matching the controller's active-number projection.
---@param owner PokedexPresentationResources
---@param dexMode string demanded number mode
---@param slot table<string, unknown> one semantic text request
---@return integer? one-based display number
---@return string? failure nonempty cause when the number has no source order
local function dexDisplayNumber(owner, dexMode, slot)
  if type(slot.species) ~= "string" or slot.species == "" then
    return nil, "text slot " .. tostring(slot.role) .. " names no species"
  end
  local catalog = owner._catalog
  if type(catalog) ~= "table" or type(catalog.dexOrders) ~= "table" then
    return nil, "prepared text needs its generated dex catalog"
  end
  local order = catalog.dexOrders[dexMode]
  if type(order) ~= "table" then
    return nil, "prepared text names an unknown dex mode " .. tostring(dexMode)
  end
  for index, key in ipairs(order) do
    if key == slot.species then
      return index
    end
  end
  return nil, "prepared text names a species outside the " .. tostring(dexMode) .. " order: " .. tostring(slot.species)
end

-- Resolves the source bank and entry behind one bank-backed text slot.
-- Species names, categories, and flavors read the requested language
-- entry bank by stable catalog species identity, never by display
-- number; heights and weights read the demanded measurement profile.
-- Unknown kinds, languages, profiles, or species fail instead of
-- falling back to another bank.
---@param manifest table<string, unknown> loaded presentation manifest
---@param owner PokedexPresentationResources
---@param slot table<string, unknown> one semantic text request
---@param profile string demanded measurement profile
---@return integer? source bank identity
---@return integer? source entry identity
---@return string? failure nonempty cause when the slot has no source bank
local function messageBankEntry(manifest, owner, slot, profile)
  local kind = slot.kind
  if kind == "ui" then
    local bindings = manifest.text
    if type(bindings) ~= "table" or type(bindings.ui) ~= "table" then
      return nil, nil, "the pokedex manifest carries no UI text bindings"
    end
    if type(bindings.ui.bankId) ~= "number" then
      return nil, nil, "the pokedex manifest carries no UI bank"
    end
    if type(slot.messageId) ~= "number" then
      return nil, nil, "ui text slot " .. tostring(slot.role) .. " names no message"
    end
    return bindings.ui.bankId, slot.messageId
  end
  if kind == "species_name" or kind == "category" or kind == "flavor" then
    local bindings = manifest.text
    if type(bindings) ~= "table" or type(bindings.entryByLanguage) ~= "table" then
      return nil, nil, "the pokedex manifest carries no entry text bindings"
    end
    if type(slot.language) ~= "string" or slot.language == "" then
      return nil, nil, "text slot " .. tostring(slot.role) .. " names no language"
    end
    local banks = bindings.entryByLanguage[slot.language]
    if type(banks) ~= "table" then
      return nil, nil, "prepared text names an unknown language " .. tostring(slot.language)
    end
    local bankKey = "nameBankId"
    if kind == "category" then
      bankKey = "categoryBankId"
    elseif kind == "flavor" then
      bankKey = "flavorBankId"
    end
    if type(banks[bankKey]) ~= "number" then
      return nil, nil, "prepared text names an unbound " .. tostring(kind) .. " bank"
    end
    if type(slot.species) ~= "string" or slot.species == "" then
      return nil, nil, "text slot " .. tostring(slot.role) .. " names no species"
    end
    local nativeId, failure = nativeSpeciesId(owner, slot.species)
    if nativeId == nil then
      return nil, nil, failure
    end
    return banks[bankKey], nativeId
  end
  if kind == "height" or kind == "weight" then
    local bindings = manifest.text
    if type(bindings) ~= "table" or type(bindings.measureByProfile) ~= "table" then
      return nil, nil, "the pokedex manifest carries no measure text bindings"
    end
    local measures = bindings.measureByProfile[profile]
    if type(measures) ~= "table" then
      return nil, nil, "prepared text names an unknown measure profile " .. tostring(profile)
    end
    local bankKey = "heightBankId"
    if kind == "weight" then
      bankKey = "weightBankId"
    end
    if type(measures[bankKey]) ~= "number" then
      return nil, nil, "prepared text names an unbound " .. tostring(kind) .. " bank"
    end
    if type(slot.species) ~= "string" or slot.species == "" then
      return nil, nil, "text slot " .. tostring(slot.role) .. " names no species"
    end
    local nativeId, failure = nativeSpeciesId(owner, slot.species)
    if nativeId == nil then
      return nil, nil, failure
    end
    return measures[bankKey], nativeId
  end
  return nil, nil, "text slot " .. tostring(slot.role) .. " names an unknown kind " .. tostring(kind)
end

-- Acquires one message bank behind the lease membership, exactly once no
-- matter how many visible slots share it. Already-held banks answer
-- immediately without touching the provider again.
---@param lease table<string, unknown>
---@param bankId integer source bank identity
---@return string? failure nonempty cause when the bank cannot be prepared
local function acquireMessageBank(lease, bankId)
  if lease._messageBanks[bankId] == true then
    return nil
  end
  local provider = lease._owner._messages
  if provider == nil or type(provider.acquireBank) ~= "function" then
    return "prepared text needs its borrowed message provider for bank " .. tostring(bankId)
  end
  local ok, bank, acquireError = pcall(provider.acquireBank, provider, bankId)
  if not ok then
    return tostring(bank)
  end
  if bank == nil then
    return tostring(acquireError)
  end
  lease._messageBanks[bankId] = true
  return nil
end

---@param lease table<string, unknown>
---@param bankId integer acquired source bank identity
---@param entryId integer source entry identity
---@return string? prepared immutable message string
---@return string? failure nonempty cause when the entry carries no source string
local function readMessageEntry(lease, bankId, entryId)
  local provider = lease._owner._messages
  local get = provider ~= nil and provider.get or nil
  if type(get) ~= "function" then
    return nil, "prepared text needs its borrowed message provider for bank " .. tostring(bankId)
  end
  local ok, template, templateError = pcall(get, provider, bankId, entryId)
  if not ok then
    return nil, tostring(template)
  end
  if type(template) ~= "table" or type(template.text) ~= "string" or template.text == "" then
    local cause = "message " .. tostring(entryId) .. " in bank " .. tostring(bankId) .. " carries no string"
    if templateError ~= nil then
      cause = cause .. ": " .. tostring(templateError)
    end
    return nil, cause
  end
  return template.text
end

-- Whether the demanded page draws any source header window: only then the
-- owner lazily prepares its one owned font4 renderer.
---@param manifest table<string, unknown> loaded presentation manifest
---@param pageRole string generated page role under preparation
---@return boolean demanded true while a font4 window is behind the page
local function needsHeaderFont(manifest, pageRole)
  local pages = manifest.pages
  if type(pages) ~= "table" then
    return false
  end
  local page = pages[pageRole]
  if type(page) ~= "table" or type(page.windows) ~= "table" then
    return false
  end
  local windows = manifest.windows
  if type(windows) ~= "table" then
    return false
  end
  for _, role in ipairs(page.windows) do
    local record = windows[role]
    if type(record) == "table" and record.font == 4 then
      return true
    end
  end
  return false
end

-- Expands `{STRVAR_1 selector, slot, ...}` formatter markers from the
-- demand's preformatted fields: the buffer slot is each marker's own
-- first argument, the same slot rule the script dialogue host resolves
-- by. Values arrive preformatted by the demand owner (counts padded,
-- names detached), so preparation stays a verbatim projection of source
-- text plus owned facts. Unbound slots fail instead of painting raw
-- control codes (decomp reference at the pinned snapshot: the popup and
-- dex-number windows expand msgFormat field 0 behind `{STRVAR_1 52, 0,
-- 0}`, the registration announcement behind `{STRVAR_1 1, 0, 0}`).
---@param text string source message text behind the slot
---@param fields table<integer, string>? preformatted demand values by buffer slot
---@param identity string bank/entry/role attribution behind the slot
---@return string? expanded text
---@return string? failure naming the unbound slot when a marker has no field
local function expandStrvarMarkers(text, fields, identity)
  local unbound = nil
  local expanded = text:gsub("{STRVAR_1%s+(%d+)%s*,%s*(%d+)[^}]*}", function(_, slot)
    local index = tonumber(slot)
    local value = type(fields) == "table" and index ~= nil and fields[index] or nil
    if type(value) ~= "string" or value == "" then
      unbound = "prepared text " .. identity .. " names an unbound STRVAR slot " .. tostring(slot)
      return nil
    end
    return value
  end)
  if unbound ~= nil then
    return nil, unbound
  end
  return expanded
end

---@param lease table<string, unknown>
---@param manifest table<string, unknown> loaded presentation manifest
---@param owner PokedexPresentationResources
---@param dexMode string demanded number mode behind dex-number slots
---@param slots table[] detached semantic text slot requests
---@param profile string demanded measurement profile
---@return table<string, string>? messages prepared message record
---@return table<integer, boolean>? banks source bank identities behind the messages
---@return string? failure nonempty cause when a slot has no source string
-- Resolves one array of text slots through the shared bank/acquire
-- path: numeric slots verbatim, dex-number slots from the demanded
-- catalog order, ui slots with demand-field formatter substitution, and
-- every other slot by its source bank and stable species identity.
local function prepareSlotMessages(lease, manifest, owner, dexMode, slots, profile)
  local messages = {}
  local bankSet = {}
  local pending = {}
  for _, slot in ipairs(slots) do
    if type(slot) ~= "table" then
      return nil, nil, "text slots arrive as records"
    end
    if type(slot.role) ~= "string" or slot.role == "" then
      return nil, nil, "text slots name their role"
    end
    if slot.kind == "numeric" then
      if type(slot.value) ~= "string" or slot.value == "" then
        return nil, nil, "numeric text slot " .. slot.role .. " carries no preformatted value"
      end
      messages[slot.role] = slot.value
    elseif slot.kind == "dex_number" then
      local number, failure = dexDisplayNumber(owner, dexMode, slot)
      if number == nil then
        return nil, nil, failure
      end
      messages[slot.role] = string.format("%03d", number)
    elseif slot.kind == "ui" and slot.fields ~= nil and type(slot.fields) ~= "table" then
      return nil, nil, "ui text slot " .. slot.role .. " carries malformed fields"
    else
      local bankId, entryId, failure = messageBankEntry(manifest, owner, slot, profile)
      if bankId == nil then
        return nil, nil, failure
      end
      assert(type(entryId) == "number", "prepared text resolves its entry")
      bankSet[bankId] = true
      pending[#pending + 1] =
        { role = slot.role, kind = slot.kind, bankId = bankId, entryId = entryId, fields = slot.fields }
    end
  end
  for bankId in pairs(bankSet) do
    local failure = acquireMessageBank(lease, bankId)
    if failure ~= nil then
      return nil, nil, failure
    end
  end
  for _, item in ipairs(pending) do
    local resolved, failure = readMessageEntry(lease, item.bankId, item.entryId)
    if resolved == nil then
      return nil, nil, failure
    end
    -- UI templates may carry formatter markers over demand fields;
    -- species, category, flavor, height, and weight entries read
    -- verbatim, exactly as the native getters return them.
    if item.kind == "ui" then
      local expanded, expandFailure = expandStrvarMarkers(
        resolved,
        item.fields,
        "bank " .. tostring(item.bankId) .. " entry " .. tostring(item.entryId) .. " (" .. tostring(item.role) .. ")"
      )
      if expanded == nil then
        return nil, nil, expandFailure
      end
      messages[item.role] = expanded
    else
      messages[item.role] = resolved
    end
  end
  return messages, bankSet
end

---@param lease table<string, unknown>
---@param demand table<string, unknown> validated demand under preparation
---@return table<string, string>? messages prepared message record
---@return table<integer, boolean>? banks source bank identities behind the messages
---@return string? failure nonempty cause when a required bank cannot be prepared
-- Resolves every visible text slot to an immutable prepared string: ui
-- slots by their UI bank and message with demand-field formatter
-- substitution, species slots by the requested
-- language entry bank and stable species identity, heights and weights
-- by the demanded measurement profile, and numeric slots by their
-- preformatted value. Banks join the lease membership once and stay
-- until a successful replacement retires them; the registration card
-- keeps its producer-authoritative announcement with the capture name
-- substituted into the native field-0 marker.
local function prepareMessages(lease, demand)
  local owner = lease._owner
  local manifest = assert(owner._manifest, "prepared messages read their manifest")
  local profile = demand.profile
  if type(profile) ~= "string" or profile == "" then
    profile = "base"
  end
  if demand.purpose == "registration" then
    local snapshot = demand.text.registration
    if type(snapshot) ~= "table" or type(snapshot.displayName) ~= "string" then
      return nil, nil, "registration demands carry their immutable announcement snapshot"
    end
    local cardSlots = demand.text.slots
    if type(cardSlots) ~= "table" then
      return nil, nil, "registration demands carry their card text slots"
    end
    local bankId, messageId = 197, 871
    local bindings = manifest.text
    if type(bindings) == "table" and type(bindings.registrationAnnouncement) == "table" then
      bankId = bindings.registrationAnnouncement.bankId
      messageId = bindings.registrationAnnouncement.messageId
    end
    if type(bankId) ~= "number" or bankId % 1 ~= 0 or type(messageId) ~= "number" or messageId % 1 ~= 0 then
      return nil, nil, "the pokedex manifest carries no registration announcement binding"
    end
    local provider = lease._owner._messages
    if provider == nil or type(provider.acquireBank) ~= "function" then
      return { registrationAnnouncement = snapshot.displayName }, {}
    end
    local slotMessages, slotBanks, slotFailure =
      prepareSlotMessages(lease, manifest, owner, demand.dexMode, cardSlots, profile)
    if slotMessages == nil then
      return nil, nil, slotFailure
    end
    local acquireFailure = acquireMessageBank(lease, bankId --[[@as integer]])
    if acquireFailure ~= nil then
      return nil, nil, acquireFailure
    end
    local announcement, readFailure = readMessageEntry(lease, bankId --[[@as integer]], messageId --[[@as integer]])
    if announcement == nil then
      return nil, nil, readFailure
    end
    -- The announcement template carries the native field-0 marker for
    -- the capture name (a wild first catch has no nickname yet, so the
    -- detached display name is the battle field-0 fact).
    local formatted, expandFailure = expandStrvarMarkers(
      announcement,
      { [0] = snapshot.displayName },
      "bank " .. tostring(bankId) .. " entry " .. tostring(messageId) .. " (registrationAnnouncement)"
    )
    if formatted == nil then
      return nil, nil, expandFailure
    end
    if formatted == "" then
      return nil, nil, "the registration announcement formats to an empty string"
    end
    slotMessages.registrationAnnouncement = formatted
    slotBanks[bankId] = true
    return slotMessages, slotBanks
  end
  local text = demand.text
  if type(text) ~= "table" then
    return nil, nil, "browser demands carry their semantic text"
  end
  return prepareSlotMessages(lease, manifest, owner, demand.dexMode, text, profile)
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
            lease._spindaRetired[#lease._spindaRetired + 1] = stored.record
          end
          lease._spindaCanvases[picture.slot] = { specKey = specKey, record = record }
          allowance.remaining = allowance.remaining - 1
        end
      end
    end
  end
  return ready
end

-- Retires Spinda records the given demand no longer watches. Retired
-- records stay alive until the replacement publishes, so the committed
-- bundle never points at a released canvas.
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
        lease._spindaRetired[#lease._spindaRetired + 1] = stored.record
      end
      lease._spindaCanvases[slot] = nil
    end
  end
end

-- Returns banks the failed generation acquired without touching the
-- committed set: a doomed generation never grows the lease membership.
---@param lease table<string, unknown>
---@param preBanks table<integer, boolean> membership before the failed call
local function unwindNewBanks(lease, preBanks)
  local committed = lease._committedBanks
  local provider = lease._owner._messages
  for bankId in pairs(lease._messageBanks) do
    if not preBanks[bankId] and (committed == nil or committed[bankId] ~= true) then
      if provider ~= nil and type(provider.releaseBank) == "function" then
        provider:releaseBank(bankId)
      end
      lease._messageBanks[bankId] = nil
    end
  end
end

---@param owner PokedexPresentationResources
---@param lease table<string, unknown>
---@param demand table<string, unknown> validated demand under preparation
---@return table<string, unknown>? bundle borrowed read-only ready bundle
---@return string? failure nonempty cause when the demand cannot become ready
---@return table<string, boolean>? chromePaths adopted paths behind the staged bundle
---@return table<integer, boolean>? bankSet source banks behind the staged messages
---@return table<string, boolean>? spriteKeys owned viewports behind the staged sprite parts
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
  -- The chrome group stages only the current page closure under the
  -- same single admission budget before any portrait or canvas work
  -- runs. Roles enroll in sorted order so staged preparation stays
  -- deterministic; pending tokens the new generation no longer watches
  -- cancel before any new enrollment.
  local wantedRoles, closureFailure = requiredChromeRoles(manifest, demand.pageRole)
  if wantedRoles == nil then
    return nil, closureFailure
  end
  local chromeInventory = manifest.chrome
  if type(chromeInventory) ~= "table" then
    return nil, "prepared bundles carry their chrome inventory"
  end
  local rolePath, wantedPaths = {}, {}
  for _, role in ipairs(wantedRoles) do
    local record = chromeInventory[role]
    if type(record) ~= "table" then
      return nil, "chrome role " .. tostring(role) .. " is not a record"
    end
    local path = record.path
    if type(path) ~= "string" or path == "" then
      return nil, "chrome role " .. tostring(role) .. " carries no path"
    end
    rolePath[role] = path
    wantedPaths[path] = true
  end
  local chromeReady = true
  do
    local pool = owner._pool
    for path, token in pairs(lease._chromeTokens) do
      if not wantedPaths[path] then
        pool:cancel(token)
        lease._chromeTokens[path] = nil
      end
    end
    for _, role in ipairs(wantedRoles) do
      local path = rolePath[role]
      assert(type(path) == "string", "prepared chrome resolves its path")
      if lease._chromeLeases[path] == nil and lease._chromeTokens[path] == nil and allowance.remaining > 0 then
        lease._chromeTokens[path] = pool:request(path, POOLED_SAMPLER, "demand")
        allowance.remaining = allowance.remaining - 1
      end
    end
    for _, role in ipairs(wantedRoles) do
      local path = rolePath[role]
      assert(type(path) == "string", "prepared chrome polls its path")
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
  -- Banks acquired below unwind when a later family fails, so a doomed
  -- generation never grows the lease membership.
  local preBanks = {}
  for bankId in pairs(lease._messageBanks) do
    preBanks[bankId] = true
  end
  local messages, messageBanks, messagesFailure = prepareMessages(lease, demand)
  if messagesFailure ~= nil then
    unwindNewBanks(lease, preBanks)
    return nil, messagesFailure
  end
  assert(type(messageBanks) == "table", "prepared text names its banks")
  -- The header font prepares once per owner lifetime, only while a
  -- demanded font4 window waits and the admission budget stays open.
  local fonts = { body = owner._text, header = owner._headerFont or owner._text }
  if needsHeaderFont(manifest, demand.pageRole) then
    if owner._headerFont == nil then
      if allowance.remaining <= 0 then
        return nil, nil
      end
      local ok, header =
        pcall(FieldTextRenderer.new, { cacheFs = owner._cacheFs, fontId = 4, graphics = owner._graphics })
      if not ok or header == nil then
        unwindNewBanks(lease, preBanks)
        return nil, "the pokedex header font cannot be prepared: " .. tostring(header)
      end
      owner._headerFont = header
      allowance.remaining = 0
    end
    fonts = { body = owner._text, header = owner._headerFont }
  end
  -- Spinda canvases compose after portraits adopt their bases, at most
  -- one new canvas per call, and gate readiness wherever host canvases
  -- back the seam.
  local spindaReady, spindaFailure = prepareSpindaPictures(owner, lease, demand, allowance)
  if spindaFailure ~= nil then
    unwindNewBanks(lease, preBanks)
    return nil, spindaFailure
  end
  -- Page sprite viewports realize after every other budgeted family, at most
  -- one new viewport per call, and gate readiness wherever host viewports
  -- back the seam.
  local spriteReady, spriteFailure, spriteParts, spriteKeys =
    prepareSpriteParts(owner, lease, manifest, demand, rolePath, allowance)
  if spriteFailure ~= nil then
    unwindNewBanks(lease, preBanks)
    return nil, spriteFailure
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
    or not spriteReady
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
  -- The published chrome maps exact required roles to adopted handles:
  -- a fresh immutable table per generation, never an alias of the
  -- working membership, so pending work cannot mutate the displayed
  -- generation.
  local chromeByRole = {}
  for _, role in ipairs(wantedRoles) do
    local path = rolePath[role]
    assert(type(path) == "string", "published chrome resolves its path")
    local adopted = lease._chromeLeases[path]
    assert(type(adopted) == "table", "published chrome holds its adopted lease")
    chromeByRole[role] = adopted
  end
  assert(type(spriteParts) == "table", "published bundles carry their sprite parts")
  assert(type(spriteKeys) == "table", "published bundles carry their sprite membership")
  return {
    renderer = owner._renderer,
    manifest = manifest,
    animations = manifest.animations,
    fonts = fonts,
    messages = messages,
    chrome = chromeByRole,
    pictures = pictures,
    icons = icons,
    surfaces = lease._surfaces,
    spriteParts = spriteParts,
  },
    nil,
    wantedPaths,
    messageBanks,
    spriteKeys
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
  for _, quad in pairs(lease._spritePartQuads) do
    releaseSpriteQuad(quad)
  end
  lease._spritePartQuads = {}
  lease._committedSpriteKeys = nil
  for _, stored in pairs(lease._spindaCanvases) do
    if type(stored) == "table" and type(stored.record) == "table" then
      stored.record:release()
    end
  end
  lease._spindaCanvases = {}
  for _, record in ipairs(lease._spindaRetired) do
    if type(record) == "table" and type(record.release) == "function" then
      record:release()
    end
  end
  lease._spindaRetired = {}
  lease._committedPaths = nil
  lease._committedBanks = nil
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
      for _, token in pairs(lease._chromeTokens) do
        pool:cancel(token)
      end
      lease._chromeTokens = {}
      -- A superseded generation never publishes, so viewports its pending
      -- work realized retire now; the committed bundle keeps its own.
      local committedSpriteKeys = lease._committedSpriteKeys or {}
      for key, quad in pairs(lease._spritePartQuads) do
        if not committedSpriteKeys[key] then
          releaseSpriteQuad(quad)
          lease._spritePartQuads[key] = nil
        end
      end
    end
    lease._pending = demand
    deferAdoption = true
    pruneSpindaCanvases(owner, lease, demand)
  end
  local bundle, failure, stagedPaths, stagedBanks, stagedSpriteKeys = prepareBundle(owner, lease, demand)
  if failure ~= nil then
    -- Failure unwinds pending interests and leaves the committed bundle
    -- internally consistent; the error carries its original cause.
    -- Message banks the failed generation acquired already unwound
    -- inside the bundle; only pooled chrome and portrait interests
    -- remain here.
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
    for _, token in pairs(lease._chromeTokens) do
      pool:cancel(token)
    end
    lease._chromeTokens = {}
    local committedPaths = lease._committedPaths or {}
    for path, adopted in pairs(lease._chromeLeases) do
      if not committedPaths[path] then
        pool:release(adopted)
        lease._chromeLeases[path] = nil
      end
    end
    -- Pending-only viewports retire with the doomed generation; the
    -- committed bundle keeps the viewports it still watches.
    local committedSpriteKeys = lease._committedSpriteKeys or {}
    for key, quad in pairs(lease._spritePartQuads) do
      if not committedSpriteKeys[key] then
        releaseSpriteQuad(quad)
        lease._spritePartQuads[key] = nil
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
  -- icon union retires to the committed set and stale portrait and
  -- chrome interests return to the shared owner. The same demand
  -- resolved its portraits and chrome above, so adoption cannot observe
  -- a new absence. Stale message banks and retired Spinda records
  -- release only now that the replacement owns the display.
  assert(type(stagedPaths) == "table", "adopted bundles carry their staged closure")
  assert(type(stagedBanks) == "table", "adopted bundles carry their staged banks")
  assert(type(stagedSpriteKeys) == "table", "adopted bundles carry their staged sprite membership")
  -- Whole-bundle adoption retires viewports the displayed generation no
  -- longer watches exactly once, only now that the replacement owns them.
  for key, quad in pairs(lease._spritePartQuads) do
    if not stagedSpriteKeys[key] then
      releaseSpriteQuad(quad)
      lease._spritePartQuads[key] = nil
    end
  end
  lease._committedSpriteKeys = stagedSpriteKeys
  local wantedPortraits = wantedPortraitPaths(lease, demand)
  assert(wantedPortraits ~= nil, "adopted demands carry their portrait paths")
  commitPortraits(lease, wantedPortraits)
  pruneSpindaCanvases(owner, lease, demand)
  do
    local pool = owner._pool
    for path, adopted in pairs(lease._chromeLeases) do
      if not stagedPaths[path] then
        pool:release(adopted)
        lease._chromeLeases[path] = nil
      end
    end
  end
  lease._committedPaths = stagedPaths
  do
    local provider = owner._messages
    for bankId in pairs(lease._messageBanks) do
      if not stagedBanks[bankId] then
        if provider ~= nil and type(provider.releaseBank) == "function" then
          provider:releaseBank(bankId)
        end
        lease._messageBanks[bankId] = nil
      end
    end
  end
  lease._committedBanks = stagedBanks
  for _, record in ipairs(lease._spindaRetired) do
    if type(record) == "table" and type(record.release) == "function" then
      record:release()
    end
  end
  lease._spindaRetired = {}
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
    _spritePartQuads = {},
    _committedSpriteKeys = nil,
    _committedPaths = nil,
    _spindaCanvases = {},
    _spindaRetired = {},
    _messageBanks = {},
    _committedBanks = nil,
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
  local header = self._headerFont
  self._headerFont = nil
  if header ~= nil and type(header.release) == "function" then
    header:release()
  end
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
