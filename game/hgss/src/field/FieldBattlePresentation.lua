-- Field-local presented-battle adapter. One envelope per field lifetime owns
-- cover and readiness while delegating each launch to a live per-launch
-- battle screen built through its bindable factory. It never chooses
-- moves, generates opponents, interprets raw battle graphics, or publishes
-- party, bag, or money consequences: the field runtime owns the launch
-- machine and receipts, the battle runtime owns mechanics and publication,
-- and the blackout flow owns defeat recovery. Draw calls are read-only;
-- the fixed clock is the only thing that advances presentation.

local SourceTick = require("libs.hgss.src.field.SourceTick")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
local BattleScreenState = require("game.hgss.src.battle.BattleScreenState")
local MonCache = require("libs.assets.src.MonCache")
local PngWriter = require("libs.assets.src.PngWriter")

---@class FieldBattlePresentation
---@field _cacheFs table<string, unknown> versioned derived cache behind demand validation
---@field _derivedAssets table<string, function>? borrowed scene-demand host, never disposed here
---@field _text table<string, unknown> borrowed text services behind plan rendering
---@field _windows table<string, unknown> borrowed window services behind plan rendering
---@field _screenAudio table<string, unknown> semantic cue-audio boundary behind the screen
---@field _itemCatalog table<string, unknown>? borrowed immutable item catalog behind battle bag grouping
---@field _monCatalog table<string, unknown>? borrowed immutable mon catalog behind machine display facts
---@field _imageFailures table<string, string> terminal upload failures by key, latched for the envelope lifetime
---@field _measureDisplay fun(): table<string, unknown> live display facts
---@field _graphics table<string, unknown>? host graphics namespace enabling GPU upload, nil for data descriptors
---@field _manifest table<string, unknown> staged or planning presentation manifest
---@field _services table<string, unknown> cache-backed preparation services carrying prepare/drawable/release
---@field _preparedDemands table<integer, table<string, unknown>> exact launch demands requested, in order
---@field _launchId string? active launch identity, nil outside launches
---@field _descriptor table<string, unknown>? active launch descriptor from the runtime
---@field _pendingFailed boolean true once a pending launch reported its terminal build failure
---@field _pendingBuild boolean true while a scheduled launch still awaits its deferred screen
---@field _recoveryPointerId string|number|nil pending recovery press identity awaiting its release
---@field _screen table<string, unknown>? live per-launch battle screen
---@field _port table<string, unknown>? live five-operation port behind the owned battle
---@field _innerPort table<string, unknown>? owned screen port a pending facade forwards to once built
---@field _lastStatus table<string, unknown>? latest observed launch status snapshot
---@field _cover integer current opaque-black cover coefficient on the 0..16 scale
---@field _accumulator number source-frame time held toward the next cover step
---@field _revealingBattle boolean true once the constructed battle starts its reveal
---@field _musicStarted boolean true once battle music was attempted for the launch
---@field _musicNote string? battle-music start outcome for launch diagnostics
---@field _pool table<string, unknown>? borrowed shared generated-image owner, required once graphics resolve pixels
---@field _leases table<string, FieldBattlePresentation.PooledHandle> shared-owner leases by drawable key
---@field _disposed boolean
local FieldBattlePresentation = {}
FieldBattlePresentation.__index = FieldBattlePresentation

FieldBattlePresentation.COVER_MAX = 16
FieldBattlePresentation.COVER_STEP = 2
FieldBattlePresentation.COVER_COLOR = 0
FieldBattlePresentation.SOURCE_FRAME = SourceTick.DT
FieldBattlePresentation.SOURCE_EPSILON = 1e-12
FieldBattlePresentation.MAX_CATCH_UP = 6

---@class FieldBattlePresentation.Options
---@field cacheFs table<string, unknown> versioned derived cache behind demand validation
---@field windows table<string, unknown> borrowed window services behind plan rendering
---@field text table<string, unknown> borrowed text services behind plan rendering
---@field audio table<string, unknown>? semantic cue-audio boundary behind the screen
---@field measureDisplay fun(): table<string, unknown> live display facts
---@field derivedAssets table<string, function>? borrowed scene-demand host behind lazy scene waits
---@field graphics table<string, unknown>? host graphics namespace enabling GPU upload, nil for data descriptors
---@field itemCatalog table<string, unknown>? borrowed immutable item catalog behind battle bag grouping
---@field monCatalog table<string, unknown>? borrowed immutable mon catalog behind machine display facts
---@field imagePool table<string, unknown>? borrowed shared generated-image owner behind pooled uploads, required to resolve graphical drawables
---@field overrides table<string, unknown>? per-instance scene, frame, and case inputs

---@class FieldBattlePresentation.PooledHandle
---@field lease table<string, unknown> shared-owner borrow returned at release or disposal
---@field handle table<string, unknown> resolved drawable behind the borrow: the pool lease itself for whole images, or a lease-plus-quad pair for atlas cells. Renderers draw through the lease sampler surface, never the bare image.

---@return table<string, unknown> silent cue sink used when no audio boundary is composed
local function nullAudio()
  local function play(_)
    return true
  end
  return {
    play = play,
  }
end

---@param cacheFs table<string, unknown>
---@return table<string, unknown> staged manifest, or the planning inventory before staging
local function loadManifest(cacheFs)
  return BattlePresentationCache.load(cacheFs)
end

---@param cacheFs table<string, unknown> versioned derived cache behind demand validation
---@param pageId integer zero-based portrait page identity under validation
---@return string? reason, nil when the staged marker and PNG envelope validate
local function checkStagedPortraitPage(cacheFs, pageId)
  local marker = cacheFs:read(MonCache.pageMarkerPath("portraits", pageId))
  if type(marker) ~= "string" or marker == "" then
    return "missing page marker"
  end
  -- The staged marker only reuses the envelope validator here: the
  -- worker-ready answer (or the accepted already-staged page without a
  -- host) is the generation authority, never equality with itself.
  if not MonCache.isPageReady(cacheFs, "portraits", pageId, marker) then
    return "invalid page image"
  end
  return nil
end

-- Maps demanded canonical portrait selectors to their staged atlas pages
-- and drives each page through the borrowed selected-game host: unknown
-- selectors fail terminally naming the selector, worker failures
-- propagate with page and cause, post-ready corrupt pages fail naming
-- selector and page, and still-building pages wait. Every needed page is
-- enqueued before waiting so independent pages build concurrently. The
-- whole-family index is never read: only the exact pages behind the
-- disclosed selectors are demanded, without the full mon summary.
---@param envelope FieldBattlePresentation
---@param selectors string[] exact canonical portrait selectors under demand
---@return boolean? ready true when every demanded page validates, false while building
---@return string? terminal failure naming selector, page, and cause
local function checkPortraitPages(envelope, selectors)
  if #selectors == 0 then
    return true
  end
  local cacheFs = envelope._cacheFs
  local portraits = cacheFs:loadLua(MonCache.portraitManifestPath())
  if type(portraits) ~= "table" or type(portraits.entries) ~= "table" then
    return nil, "battle demand needs its staged portrait manifest: " .. tostring(selectors[1])
  end
  local entries = portraits.entries --[[@as table<string, table<string, unknown>>]]
  local groups = {} ---@type table<integer, { pageId: integer, selectors: string[] }>
  local byPage = {} ---@type table<integer, integer>
  for _, selector in ipairs(selectors) do
    if type(selector) ~= "string" or selector == "" then
      return nil, "portrait selectors must be non-empty strings"
    end
    local entry = entries[selector]
    local pageId = type(entry) == "table" and entry.pageId or nil
    if type(pageId) ~= "number" or pageId % 1 ~= 0 or pageId < 0 then
      return nil, "battle demand names an unstaged portrait: " .. tostring(selector)
    end
    local numericPage = pageId --[[@as integer]]
    local at = byPage[numericPage]
    if at == nil then
      groups[#groups + 1] = { pageId = numericPage, selectors = { selector } }
      byPage[numericPage] = #groups
    else
      groups[at].selectors[#groups[at].selectors + 1] = selector
    end
  end
  table.sort(groups, function(a, b)
    return a.pageId < b.pageId
  end)
  local host = envelope._derivedAssets
  local requestPage = type(host) == "table" and host.requestMonPortraitPage or nil
  local graphics = envelope._graphics
  local waiting = false
  for _, group in ipairs(groups) do
    local names = table.concat(group.selectors, ", ")
    if type(requestPage) == "function" then
      local ready, failure = requestPage(group.pageId, "required")
      if failure ~= nil then
        return nil, "battle portrait page " .. tostring(group.pageId) .. " for " .. names .. ": " .. tostring(failure)
      end
      if ready ~= true then
        waiting = true
      else
        local stagedErr = checkStagedPortraitPage(cacheFs, group.pageId)
        if stagedErr ~= nil then
          return nil,
            "battle portrait page " .. tostring(group.pageId) .. " for " .. names .. " is not staged: " .. stagedErr
        end
      end
    else
      -- Without a host nothing can build the page: a graphical launch
      -- accepts only an already-staged and structurally valid page,
      -- while headless descriptors validate the same staged identity.
      local stagedErr = checkStagedPortraitPage(cacheFs, group.pageId)
      if stagedErr ~= nil then
        local reason = "battle portrait page "
          .. tostring(group.pageId)
          .. " for "
          .. names
          .. " is not staged: "
          .. stagedErr
        if graphics ~= nil then
          reason = reason .. ": portrait:" .. tostring(group.pageId)
        end
        return nil, reason
      end
    end
  end
  if waiting then
    return false
  end
  return true
end

---@param opts FieldBattlePresentation.Options
---@return FieldBattlePresentation
function FieldBattlePresentation.new(opts)
  assert(type(opts) == "table", "the presented battle envelope requires options")
  assert(opts.cacheFs ~= nil, "the presented battle envelope requires its cache")
  assert(type(opts.windows) == "table", "the presented battle envelope borrows its window services")
  assert(type(opts.text) == "table", "the presented battle envelope borrows its text services")
  assert(type(opts.measureDisplay) == "function", "the presented battle envelope needs its display facts")
  if opts.graphics ~= nil then
    assert(type(opts.graphics) == "table", "the graphics namespace arrives as a record")
  end
  if opts.derivedAssets ~= nil then
    assert(type(opts.derivedAssets) == "table", "the scene demand host arrives as a record")
  end
  local envelope = setmetatable({
    _cacheFs = opts.cacheFs,
    _text = opts.text,
    _windows = opts.windows,
    _screenAudio = opts.audio or nullAudio(),
    _measureDisplay = opts.measureDisplay,
    _derivedAssets = opts.derivedAssets,
    _graphics = opts.graphics,
    _itemCatalog = opts.itemCatalog,
    _monCatalog = opts.monCatalog,
    _overrides = opts.overrides or {},
    _manifest = loadManifest(opts.cacheFs),
    _preparedDemands = {},
    _launchId = nil,
    _descriptor = nil,
    _pendingFailed = false,
    _pendingBuild = false,
    _recoveryPointerId = nil,
    _screen = nil,
    _port = nil,
    _innerPort = nil,
    _lastStatus = nil,
    _cover = 0,
    _accumulator = 0,
    _revealingBattle = false,
    _musicStarted = false,
    _musicNote = nil,
    _disposed = false,
    _imageFailures = {},
    _pool = opts.imagePool,
    _leases = {},
  }, FieldBattlePresentation)
  -- Pool interface validation stays at composition: graphical resolution
  -- requires the pool at first use (acquirePooled asserts it), so pending
  -- and headless flows compose without one while no private GPU image
  -- can be constructed beside the pool on any drawn path.
  if envelope._pool ~= nil then
    assert(type(envelope._pool.request) == "function", "the shared image owner carries pooled requests")
    assert(type(envelope._pool.poll) == "function", "the shared image owner carries pooled readiness")
    assert(type(envelope._pool.acquire) == "function", "the shared image owner carries pooled borrows")
    assert(type(envelope._pool.release) == "function", "the shared image owner carries pooled returns")
  end
  envelope._services = envelope:_preparationServices()
  return envelope
end

-- Battle visuals sample point-filtered and clamped, matching the direct
-- construction below, so pooled borrows draw identically.
local POOLED_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }

-- Borrows one staged page through the shared owner under a drawable key:
-- the same bounded stall and keyed terminal failure as a whole-image
-- borrow, answering the raw lease so cell drawables can pair the pooled
-- page with their renderer-owned quad.
---@param envelope FieldBattlePresentation
---@param key string drawable key behind diagnostics
---@param path string cache-relative staged page path behind diagnostics
---@return table<string, unknown>? resolved page lease, nil on terminal failure
---@return string? terminal failure naming the key and path, nil on success
local function borrowPage(envelope, key, path)
  local pool = assert(envelope._pool, "pooled battle uploads borrow the shared image owner")
  local token = pool:request(path, POOLED_SAMPLER, "demand")
  local stalled = 0
  while true do
    local status, failure = pool:poll(token)
    if status == "ready" then
      local ok, leaseOrCause = pcall(function()
        return pool:acquire(token)
      end)
      if ok then
        return leaseOrCause
      end
      return nil,
        "battle image " .. tostring(key) .. " upload failed: " .. tostring(path) .. ": " .. tostring(leaseOrCause)
    end
    if status == "failed" then
      return nil, "battle image " .. tostring(key) .. " upload failed: " .. tostring(path) .. ": " .. tostring(failure)
    end
    assert(status == "pending", "battle preparation reports pending or ready")
    stalled = stalled + 1
    if stalled > 10000 then
      return nil, "battle image " .. tostring(key) .. " upload failed: " .. tostring(path) .. ": stalled"
    end
    local timer = love and love.timer
    if timer ~= nil and timer.sleep ~= nil then
      timer.sleep(0.001)
    end
  end
end

-- Borrows one staged whole battle visual through the shared owner,
-- installing the resolved image as the drawable behind the key.
---@param envelope FieldBattlePresentation
---@param key string drawable key behind diagnostics
---@param path string cache-relative staged image path behind diagnostics
---@return table<string, unknown>? resolved drawable lease, nil on terminal failure
---@return string? terminal failure naming the key and path, nil on success
local function acquirePooled(envelope, key, path)
  local lease, failure = borrowPage(envelope, key, path)
  if lease == nil then
    return nil, failure
  end
  assert(lease.image, "shared borrows carry their resolved image")
  envelope._leases[key] = { lease = lease, handle = lease }
  return lease
end

-- Borrows one staged portrait cell for a canonical portrait selector:
-- the owning atlas page comes from the shared owner under the drawable
-- key while the cell rectangle stays renderer-owned geometry over the
-- borrowed page, so exact staged pixels draw through one pooled atlas
-- quad instead of a private per-battler copy. A page the worker has not
-- attested yet answers a legitimate pending wait without touching the
-- image driver or the shared owner; staged bytes that fail
-- classification or GPU upload answer a terminal failure naming the
-- canonical selector and its page path.
---@param envelope FieldBattlePresentation
---@param key string drawable key behind diagnostics
---@param graphics table<string, unknown> host graphics namespace carrying quad construction
---@param cacheFs table<string, unknown> versioned derived cache behind demand validation
---@param selector string canonical staged portrait selector
---@return table<string, unknown>? cell handle pairing the pool lease with its renderer-owned quad, nil while pending or on terminal failure
---@return string? terminal failure naming the selector and page path, nil while pending or on success
local function acquirePortraitCell(envelope, key, graphics, cacheFs, selector)
  local pagePath = nil
  local entry = nil
  do
    -- Only a worker-attested page borrows: an unstaged page waits for
    -- preparation instead of borrowing missing bytes or standing in
    -- another image. Structural manifest problems still fail below.
    local portraits = cacheFs:loadLua(MonCache.portraitManifestPath())
    if type(portraits) == "table" and type(portraits.entries) == "table" then
      local entries = portraits.entries --[[@as table<string, table<string, unknown>>]]
      entry = entries[selector]
    end
    local pageId = type(entry) == "table" and entry.pageId or nil
    if type(pageId) == "number" and pageId % 1 == 0 and pageId >= 0 then
      if
        checkStagedPortraitPage(cacheFs, pageId --[[@as integer]]) ~= nil
      then
        return nil, nil
      end
    end
  end
  local ok, handleOrErr = pcall(function()
    assert(type(entry) == "table", "the staged manifest plans no such portrait: " .. tostring(selector))
    assert(type(entry.pageId) == "number", "the staged portrait names its page: " .. tostring(selector))
    assert(
      type(entry.x) == "number" and type(entry.y) == "number",
      "the staged portrait names its cell origin: " .. tostring(selector)
    )
    assert(
      type(entry.width) == "number" and type(entry.height) == "number",
      "the staged portrait names its cell size: " .. tostring(selector)
    )
    local path = MonCache.pageImagePath("portraits", entry.pageId)
    pagePath = path
    local lease, failure = borrowPage(envelope, key, path)
    assert(lease ~= nil, failure)
    assert(lease.image, "shared borrows carry their resolved image")
    -- Hoisted before the call: assert returns all its arguments, so an
    -- inline assert in final position would leak its message string into
    -- the quad argument list.
    local pageWidth = assert(lease.width, "shared borrows carry their page width")
    local pageHeight = assert(lease.height, "shared borrows carry their page height")
    local quad = graphics.newQuad(entry.x, entry.y, entry.width, entry.height, pageWidth, pageHeight)
    local handle = { lease = lease, quad = quad }
    envelope._leases[key] = { lease = lease, handle = handle }
    return handle
  end)
  if ok and handleOrErr ~= nil then
    return handleOrErr
  end
  local cause = ok and "empty portrait handle" or tostring(handleOrErr)
  local label = "mon:" .. tostring(selector)
  if pagePath ~= nil then
    label = label .. " " .. tostring(pagePath)
  end
  return nil, "battle image " .. label .. " upload failed: " .. cause
end

-- Resolves one menu or HUD drawable key to its staged image path through
-- the verified manifest. Per-control artwork has no staged counterpart
-- and resolves to nothing so those controls draw labels only. A
-- planning manifest stages nothing and resolves nothing.
---@param envelope FieldBattlePresentation
---@param key string drawable key under resolution
---@return string? cache-relative staged image path, nil without a staged counterpart
local function stagedArtPath(envelope, key)
  local manifest = envelope._manifest
  if type(manifest) ~= "table" or manifest.verified ~= true then
    return nil
  end
  if key == "hud:enemy" then
    return type(manifest.enemyHud) == "table" and manifest.enemyHud.image or nil
  end
  if key == "hud:player" then
    return type(manifest.playerHud) == "table" and manifest.playerHud.image or nil
  end
  -- Doubled health boxes resolve through the staged doubled family by
  -- slot: each row owns its dedicated strip, never a shared
  -- single-battle strip.
  local doublesSlot = tostring(key):match("^hud:(.+)$")
  if
    doublesSlot == "player-left"
    or doublesSlot == "player-right"
    or doublesSlot == "enemy-left"
    or doublesSlot == "enemy-right"
  then
    local family = type(manifest.doublesHud) == "table" and manifest.doublesHud or nil
    local section = nil
    if type(family) == "table" then
      if doublesSlot == "player-left" then
        section = family.playerLeft
      elseif doublesSlot == "player-right" then
        section = family.playerRight
      elseif doublesSlot == "enemy-left" then
        section = family.enemyLeft
      else
        section = family.enemyRight
      end
    end
    return type(section) == "table" and section.image or nil
  end
  if key == "menu:command" then
    return type(manifest.command) == "table" and manifest.command.image or nil
  end
  if key == "menu:moves" then
    return type(manifest.moves) == "table" and manifest.moves.image or nil
  end
  if key == "menu:target" then
    return type(manifest.target) == "table" and manifest.target.image or nil
  end
  if key == "arrow" then
    return type(manifest.arrow) == "table" and manifest.arrow.image or nil
  end
  -- Both interaction-pane gauge rows use the 16-pixel family: no roster
  -- state selects the 32-pixel family, which stays staged but unused.
  if key == "gauges:player" or key == "gauges:enemy" then
    local family = type(manifest.partyGauges) == "table" and manifest.partyGauges[1] or nil
    return type(family) == "table" and family.image or nil
  end
  return nil
end

-- Resolves one battler-side drawable key to its canonical staged
-- Resolves one battler drawable key to its exact canonical staged
-- portrait selector. Anything else resolves to nothing so cues hold
-- instead of drawing a guessed variant.
---@param key string battler drawable key under resolution
---@return string? canonical staged portrait selector, nil unless the key names one exactly
local function exactPortraitSelector(key)
  -- Battler drawables name their exact canonical selector after the
  -- "mon:" prefix. Anything else resolves to nothing so cues hold
  -- instead of drawing a guessed variant.
  local selector = tostring(key):match("^mon:(.+)$")
  if type(selector) ~= "string" or selector == "" then
    return nil
  end
  if selector == "player:back" or selector == "enemy:front" then
    return nil
  end
  return selector
end

-- Validates the demanded audio members against the staged manifest
-- roles: every demanded role must be one of the staged wild, trainer,
-- rival, or select symbols. Banks and cries ride the demand for
-- exactness; without the normalized audio membership in presentation
-- scope only their shape is checked here.
---@param envelope FieldBattlePresentation
---@param demand table<string, unknown> exact launch demand under validation
---@return string? reason, nil when the audio members validate
local function checkAudioMembers(envelope, demand)
  local manifest = envelope._manifest
  if type(manifest) ~= "table" or manifest.verified ~= true then
    return "battle presentation is not staged: the launch needs its staged menu, HUD, font, and audio roles"
  end
  local audio = demand.audio or { roles = {}, banks = {}, cries = {} }
  if type(audio) ~= "table" then
    return "battle demands carry their audio roles"
  end
  local stagedRoles = {}
  if type(manifest.audioRoles) == "table" then
    for _, role in ipairs({ "wild", "trainer", "rival", "select" }) do
      if type(manifest.audioRoles[role]) == "string" then
        stagedRoles[manifest.audioRoles[role]] = true
      end
    end
  end
  if type(audio.roles) ~= "table" then
    return "battle demands carry their audio roles"
  end
  for _, role in ipairs(audio.roles) do
    if type(role) ~= "string" or role == "" then
      return "battle audio roles must be non-empty strings"
    end
    if not stagedRoles[role] then
      return "battle demand names an unstaged audio role: " .. tostring(role)
    end
  end
  if type(audio.banks) ~= "table" then
    return "battle demands carry their audio banks"
  end
  for _, bank in ipairs(audio.banks) do
    if type(bank) ~= "number" then
      return "battle audio banks must be bank identities"
    end
  end
  if type(audio.cries) ~= "table" then
    return "battle demands carry their audio cries"
  end
  for _, cry in ipairs(audio.cries) do
    if type(cry) ~= "string" or cry == "" then
      return "battle audio cries must be non-empty strings"
    end
  end
  return nil
end

-- Validates the staged menu, HUD, and font members behind the launch:
-- every drawable the renderers reach for must have its staged image,
-- and every manifest text role must have its staged font definition.
-- The borrowed field text renderer owns font pixels; this checks the
-- staged definitions the roles reference.
---@param envelope FieldBattlePresentation
---@return string? reason, nil when the staged members validate
local function checkStagedMembers(envelope)
  local manifest = envelope._manifest
  if type(manifest) ~= "table" or manifest.verified ~= true then
    return "battle presentation is not staged: the launch needs its staged menu, HUD, font, and audio roles"
  end
  local cacheFs = assert(envelope._cacheFs, "preparation requires the envelope cache")
  local required = {
    { key = "menu:command", path = type(manifest.command) == "table" and manifest.command.image or nil },
    { key = "menu:moves", path = type(manifest.moves) == "table" and manifest.moves.image or nil },
    { key = "menu:target", path = type(manifest.target) == "table" and manifest.target.image or nil },
    { key = "hud:enemy", path = type(manifest.enemyHud) == "table" and manifest.enemyHud.image or nil },
    { key = "hud:player", path = type(manifest.playerHud) == "table" and manifest.playerHud.image or nil },
    { key = "hud:player-left", path = stagedArtPath(envelope, "hud:player-left") },
    { key = "hud:player-right", path = stagedArtPath(envelope, "hud:player-right") },
    { key = "hud:enemy-left", path = stagedArtPath(envelope, "hud:enemy-left") },
    { key = "hud:enemy-right", path = stagedArtPath(envelope, "hud:enemy-right") },
  }
  for _, entry in ipairs(required) do
    local bytes = type(entry.path) == "string" and cacheFs:read(entry.path) or nil
    if type(bytes) ~= "string" or #bytes == 0 then
      return "battle menu art is not staged: " .. tostring(entry.key)
    end
  end
  if type(manifest.textRoles) ~= "table" then
    return "battle presentation is not staged: the launch needs its staged font roles"
  end
  for _, role in ipairs({ "narration", "menu", "hud" }) do
    local record = manifest.textRoles[role]
    local font = type(record) == "table" and record.font or nil
    if type(font) ~= "string" or type(cacheFs:read(font)) ~= "string" then
      return "battle font is not staged: " .. tostring(role)
    end
  end
  return nil
end

-- The cache-backed preparation services behind one envelope: prepare
-- validates the exact launch demand against the staged or planning
-- manifest, the portrait manifest and page markers, and -- where pixels
-- are actually required -- the staged menu, HUD, font, and audio
-- members; drawable resolves validated handles through the owned image
-- cache without ever inventing a second uploader; release forgets owned
-- handles exactly once. Missing staged scene pixels stay pending as data
-- descriptors in headless composition and fail closed only where pixels
-- are actually required.
---@return table<string, unknown> preparation services carrying prepare/drawable/release
function FieldBattlePresentation:_preparationServices()
  local envelope = self
  local cacheFs = assert(self._cacheFs, "preparation requires the envelope cache")
  local graphics = self._graphics
  local services = {}
  function services.prepare(demand)
    if type(demand) ~= "table" then
      return nil, "battle demands arrive as records"
    end
    envelope._preparedDemands[#envelope._preparedDemands + 1] = demand
    for _, sceneKey in ipairs(demand.scenes or {}) do
      if BattlePresentationCache.parseSceneKey(sceneKey) == nil then
        return nil, "unknown battle scene key: " .. tostring(sceneKey)
      end
      if graphics ~= nil then
        -- A launch scene the worker has not staged yet waits under cover:
        -- the borrowed host only queues and observes, so pending answers
        -- poll again while genuine build failures fail closed naming the
        -- scene. Staged bytes still validate after a ready answer, and a
        -- demand without a host to schedule keeps its explicit failure.
        local host = envelope._derivedAssets
        local requestScene = host ~= nil and host.requestBattleScene or nil
        local scheduled = type(requestScene) == "function"
        if type(requestScene) == "function" then
          local ready, failure = requestScene(sceneKey, "required")
          if failure ~= nil then
            return nil, "battle scene " .. tostring(sceneKey) .. ": " .. tostring(failure)
          end
          if ready ~= true then
            return false, nil
          end
        end
        local record, recordErr = BattlePresentationCache.loadScene(cacheFs, sceneKey)
        if record == nil then
          local cause = tostring(recordErr or ("no staged battle scene for " .. sceneKey))
          if not scheduled then
            return nil, cause .. ": no scene demand host to schedule battle scene " .. tostring(sceneKey)
          end
          return nil, "battle scene " .. tostring(sceneKey) .. ": " .. cause
        end
        local bytes = cacheFs:read(BattlePresentationCache.sceneImagePath(sceneKey))
        if type(bytes) ~= "string" or #bytes ~= PngWriter.encodedSize(record.canvasWidth, record.canvasHeight) then
          if not scheduled then
            return nil,
              "battle scene image is not staged: " .. tostring(sceneKey) .. ": no scene demand host to schedule it"
          end
          return nil, "battle scene image is not staged: " .. tostring(sceneKey)
        end
      end
    end
    local portraitsOk, portraitsErr = checkPortraitPages(envelope, demand.pages or {})
    if portraitsOk == nil then
      return nil, portraitsErr
    end
    if portraitsOk == false then
      return false, nil
    end
    -- Menu, HUD, font, and audio members are required only where
    -- pixels are actually required: headless composition keeps its
    -- descriptor behavior so recording views prove without staged art.
    if graphics ~= nil then
      local stagedErr = checkStagedMembers(envelope)
      if stagedErr ~= nil then
        return nil, stagedErr
      end
      local audioErr = checkAudioMembers(envelope, demand)
      if audioErr ~= nil then
        return nil, audioErr
      end
    end
    return true
  end
  function services.drawable(key)
    assert(type(key) == "string" and key ~= "", "image resolution names its key")
    local leases = envelope._leases --[[@as table<string, FieldBattlePresentation.PooledHandle>]]
    if leases[key] ~= nil then
      return leases[key].handle
    end
    -- A terminal upload failure replays identically without re-entering
    -- the driver: the decode already proved deterministic for this
    -- envelope lifetime.
    local failures = envelope._imageFailures --[[@as table<string, string>]]
    if failures[key] ~= nil then
      return nil, failures[key]
    end
    if graphics == nil then
      -- Data descriptors carry the validated staged identity without
      -- GPU objects: the recording boundary proves views while pixels
      -- stay unstaged in headless composition. Descriptors stay
      -- drawable-shaped so inspection draws record exactly like the raw
      -- draws they replace; production never draws them (a GPU-backed
      -- envelope resolves leases instead).
      local descriptor = { kind = "staged", key = key }
      function descriptor:draw(drawGraphics, x, y, ...)
        drawGraphics.draw(self, x, y, ...)
      end
      function descriptor:drawQuad(drawGraphics, quad, x, y, ...)
        drawGraphics.draw(self, quad, x, y, ...)
      end
      return descriptor
    end
    -- Production drawables are real owned handles, legitimate waits, or
    -- terminal failures: staged bytes that fail decoding or GPU upload
    -- latch one keyed error instead of answering an unusable nil that
    -- the caller would poll forever. Unknown decorative keys stay
    -- legitimate nils with no error.
    local sceneKey = tostring(key):match("^scene:(.+)$")
    if sceneKey ~= nil then
      local path = BattlePresentationCache.sceneImagePath(sceneKey)
      -- Manifest-declared battle art borrows the shared owner: the
      -- staged request classifies through its worker and the borrow
      -- resolves exactly one pooled image per key.
      local image, failure = acquirePooled(envelope, key, path)
      if image == nil then
        assert(type(failure) == "string", "staged upload failures carry their reason")
        failures[key] = failure --[[@as string]]
        return nil, failure
      end
      return image
    end
    local artPath = stagedArtPath(envelope, key)
    if artPath ~= nil then
      local image, failure = acquirePooled(envelope, key, artPath)
      if image == nil then
        assert(type(failure) == "string", "staged upload failures carry their reason")
        failures[key] = failure --[[@as string]]
        return nil, failure
      end
      return image
    end
    local selector = exactPortraitSelector(key)
    if selector ~= nil then
      local cell, failure = acquirePortraitCell(envelope, key, graphics, cacheFs, selector)
      if cell == nil then
        if failure == nil then
          return nil
        end
        failures[key] = failure --[[@as string]]
        return nil, failure
      end
      return cell
    end
    return nil
  end
  function services.release(key)
    -- Returned borrows rest resident under the shared owner until its own
    -- eviction: releasing forgets the borrow here so a later resolution
    -- borrows it again instead of drawing through a returned lease.
    local leases = envelope._leases --[[@as table<string, FieldBattlePresentation.PooledHandle>]]
    local pooled = leases[key]
    if pooled ~= nil then
      leases[key] = nil
      local pool = assert(envelope._pool, "pooled battle borrows return to the shared image owner")
      pool:release(pooled.lease)
    end
  end
  return services
end

---@return table<integer, table<string, unknown>> exact launch demands requested, in order
function FieldBattlePresentation:preparedDemands()
  return self._preparedDemands
end

-- The bindable per-launch factory: each descriptor admits one launch and
-- returns one fresh five-operation port. Descriptor-only composition keeps
-- its synchronous screen; a launch with a scene scheduler behind it gets
-- a pending facade that stays unacknowledged until the scheduled scene
-- and its staged companion manifest publish, then builds exactly one
-- production screen behind the same port. Admission failures raise;
-- operational build failures report through the host once.
---@return fun(descriptor: table<string, unknown>): table<string, unknown>
function FieldBattlePresentation:factory()
  local envelope = self
  local function buildPort(descriptor)
    return envelope:_admitLaunch(descriptor)
  end
  return buildPort
end

-- Admits one launch behind its identity: validates the descriptor shape
-- and its scene naming, opens cover and music bookkeeping, and either
-- builds the descriptor screen at once or hands out the pending facade
-- that the fixed update completes. Concurrent launches fail at
-- admission; the launch owns one launch at a time.
---@param descriptor table<string, unknown> detached launch descriptor from the runtime
---@return table<string, unknown> fresh five-operation port behind the launch
function FieldBattlePresentation:_admitLaunch(descriptor)
  assert(type(descriptor) == "table", "presentation factories take a launch descriptor")
  assert(
    type(descriptor.launchId) == "string" and descriptor.launchId ~= "",
    "presentation factories take the launch identity"
  )
  assert(type(descriptor.environment) == "table", "presentation factories take the launch environment")
  assert(not self._disposed, "the presented battle envelope is disposed")
  assert(self._launchId == nil, "the envelope owns one launch at a time")
  local environment = descriptor.environment --[[@as table<string, unknown>]]
  local sceneKey = environment.sceneKey
  assert(type(sceneKey) == "string" and sceneKey ~= "", "launch environments resolve their scene identity")
  assert(BattlePresentationCache.parseSceneKey(sceneKey) ~= nil, "unknown battle scene key: " .. tostring(sceneKey))
  self._launchId = descriptor.launchId
  self._descriptor = descriptor
  self._pendingFailed = false
  self._pendingBuild = false
  self._screen = nil
  self._innerPort = nil
  self._lastStatus = nil
  self._cover = 0
  self._accumulator = 0
  self._revealingBattle = false
  self._musicStarted = false
  self._musicNote = nil
  local derived = self._derivedAssets
  local scheduled = self._graphics ~= nil
    and type(derived) == "table"
    and type(derived.requestBattleScene) == "function"
  if not scheduled then
    local constructed = self:_buildPort(descriptor)
    self._port = constructed
    return constructed
  end
  self._pendingBuild = true
  local launchId = descriptor.launchId --[[@as string]]
  local facade = {}
  local function owned()
    if self._launchId ~= launchId or self._descriptor == nil then
      return nil
    end
    return self._innerPort
  end
  function facade.enter(plan)
    local inner = owned()
    if inner == nil then
      return false
    end
    local ok, acknowledged = pcall(inner.enter, plan)
    return ok and acknowledged == true
  end
  function facade.present(packet)
    local inner = owned()
    if inner == nil then
      return
    end
    local _, _ = pcall(inner.present, packet)
  end
  function facade.ready()
    local inner = owned()
    if inner == nil then
      return false
    end
    local ok, interactive = pcall(inner.ready)
    return ok and interactive == true
  end
  function facade.leave(plan)
    local inner = owned()
    if inner == nil then
      return false
    end
    local ok, acknowledged = pcall(inner.leave, plan)
    return ok and acknowledged == true
  end
  function facade.dispose()
    if self._launchId ~= launchId then
      return
    end
    local screen = self._screen
    self:_dropLaunch()
    if screen ~= nil then
      local _, _ = pcall(function()
        return screen:dispose()
      end)
    end
  end
  self._port = facade
  return facade
end

-- Builds the single production screen for a pending launch once its
-- scheduled scene published: reloads the current companion manifest,
-- requires its staged mark and the exact demanded scene, then
-- constructs through the one construction site. Pending answers build
-- nothing; terminal answers report once and keep the launch covered
-- until the field drains it. Runs before the host advance on the same
-- fixed tick, never from inside a port callback.
function FieldBattlePresentation:_pollPendingScreen()
  if self._disposed then
    return
  end
  if self._graphics == nil then
    return
  end
  local descriptor = self._descriptor
  if self._launchId == nil or type(descriptor) ~= "table" then
    return
  end
  if self._screen ~= nil or self._innerPort ~= nil then
    return
  end
  if self._pendingFailed or not self._pendingBuild then
    return
  end
  local environment = descriptor.environment --[[@as table<string, unknown>]]
  local sceneKey = type(environment) == "table" and environment.sceneKey or nil
  if type(sceneKey) ~= "string" or sceneKey == "" then
    self:_failPendingLaunch("launch environments resolve their scene identity")
    return
  end
  local derived = self._derivedAssets
  local requestScene = type(derived) == "table" and derived.requestBattleScene or nil
  if type(requestScene) == "function" then
    local ok, ready, failure = pcall(requestScene, sceneKey, "required")
    if not ok then
      self:_failPendingLaunch("battle scene " .. tostring(sceneKey) .. ": " .. tostring(ready))
      return
    end
    if failure ~= nil then
      self:_failPendingLaunch("battle scene " .. tostring(sceneKey) .. ": " .. tostring(failure))
      return
    end
    if ready ~= true then
      return
    end
  end
  local manifest = loadManifest(self._cacheFs)
  if type(manifest) ~= "table" or manifest.verified ~= true then
    if type(requestScene) ~= "function" then
      self:_failPendingLaunch("battle scene " .. tostring(sceneKey) .. ": no scene demand host to schedule it")
    else
      self:_failPendingLaunch(
        "battle scene " .. tostring(sceneKey) .. ": the staged battle presentation is not verified"
      )
    end
    return
  end
  local known = false
  if type(manifest.scenes) == "table" then
    for _, entry in ipairs(manifest.scenes) do
      if type(entry) == "table" and entry.key == sceneKey then
        known = true
        break
      end
    end
  end
  if not known then
    self:_failPendingLaunch("launch scene is outside the presentation inventory: " .. tostring(sceneKey))
    return
  end
  self._manifest = manifest
  local okBuild, innerOrErr = pcall(function()
    return self:_buildPort(descriptor)
  end)
  self._pendingBuild = false
  if not okBuild then
    self._screen = nil
    self._innerPort = nil
    self:_failPendingLaunch("battle scene " .. tostring(sceneKey) .. ": " .. tostring(innerOrErr))
    return
  end
  self._innerPort = innerOrErr
end

-- Latches the first terminal build failure for the pending launch and
-- reports it through the host exactly once. The descriptor, cover, and
-- launch identity stay with the host until the field drains the abort;
-- a disposed launch reports nothing late.
---@param reason string terminal failure context behind the report
function FieldBattlePresentation:_failPendingLaunch(reason)
  if self._pendingFailed then
    return
  end
  local descriptor = self._descriptor
  if self._launchId == nil or type(descriptor) ~= "table" then
    return
  end
  self._pendingFailed = true
  local host = descriptor.host --[[@as table<string, unknown>]]
  if host ~= nil and type(host.notify) == "function" then
    host.notify("screen-failed", reason)
  end
end

-- Adapts one launch behind the screen-owned one-argument cue sink.
-- A method-based production controller resolves `select` to the staged
-- interface role and `cry:<species>` to the numeric species cry; every
-- other role is an explicit failure with launch context. An injected
-- semantic sink (no cry voice of its own) passes through untouched for
-- the deliberate headless contract, never as a production fallback.
---@param launchId string owning launch identity behind failure context
---@return table<string, unknown> one-argument cue sink behind the screen
function FieldBattlePresentation:_screenAudioFor(launchId)
  local controller = self._screenAudio
  if type(controller.playCry) ~= "function" then
    return controller
  end
  local manifest = self._manifest
  local monCatalog = self._monCatalog
  local function play(role)
    assert(type(role) == "string" and role ~= "", "battle cues name their sound role")
    if role == "select" then
      local audioRoles = type(manifest) == "table" and manifest.audioRoles or nil
      assert(type(audioRoles) == "table", "battle sound needs its staged select role for launch " .. launchId)
      local symbol = audioRoles.select
      assert(
        type(symbol) == "string" and symbol ~= "",
        "battle sound needs its staged select role for launch " .. launchId
      )
      return controller:play(symbol)
    end
    local speciesKey = role:match("^cry:(.+)$")
    if speciesKey ~= nil then
      assert(monCatalog ~= nil, "battle cries need their mon catalog for launch " .. launchId)
      local facts = monCatalog:species(speciesKey)
      assert(
        type(facts) == "table" and type(facts.nativeId) == "number",
        "battle cries name a cataloged species for launch " .. launchId .. ": " .. tostring(role)
      )
      return controller:playCry(facts.nativeId, 0)
    end
    error("unknown battle sound role for launch " .. launchId .. ": " .. tostring(role), 0)
  end
  return { play = play }
end

---@param descriptor table<string, unknown> admitted launch descriptor from the runtime
---@return table<string, unknown> fresh five-operation port behind a fresh screen
function FieldBattlePresentation:_buildPort(descriptor)
  assert(type(descriptor) == "table", "presentation factories take a launch descriptor")
  assert(
    type(descriptor.launchId) == "string" and descriptor.launchId ~= "",
    "presentation factories take the launch identity"
  )
  assert(type(descriptor.environment) == "table", "presentation factories take the launch environment")
  assert(not self._disposed, "the presented battle envelope is disposed")
  assert(self._launchId == descriptor.launchId, "the envelope builds only its admitted launch")
  assert(self._screen == nil, "the envelope builds one screen per launch")
  local environment = descriptor.environment --[[@as table<string, unknown>]]
  local sceneKey = environment.sceneKey
  assert(type(sceneKey) == "string" and sceneKey ~= "", "launch environments resolve their scene identity")
  local manifest = self._manifest
  local sceneKnown = false
  if type(manifest) == "table" and type(manifest.scenes) == "table" then
    for _, entry in ipairs(manifest.scenes) do
      if type(entry) == "table" and entry.key == sceneKey then
        sceneKnown = true
        break
      end
    end
  end
  assert(sceneKnown, "launch scene is outside the presentation inventory: " .. tostring(sceneKey))
  local host = descriptor.host
  local function submit(reply)
    if host == nil then
      return false, { message = "the presented launch carries no host" }
    end
    return host.submit(reply)
  end
  local launchSpeed = descriptor.textSpeed or "mid"
  local screen = BattleScreenState.new({
    launchId = descriptor.launchId,
    manifest = manifest,
    model = BattlePresentationModel,
    textSpeed = launchSpeed,
    submit = submit,
    measureDisplay = self._measureDisplay,
    assets = self._services,
    text = self._text,
    windows = self._windows,
    audio = self:_screenAudioFor(descriptor.launchId),
    itemCatalog = self._itemCatalog,
    monCatalog = self._monCatalog,
    overrides = { sceneKey = sceneKey },
  })
  self._screen = screen
  return screen:presentationPort()
end

---@return table<string, unknown>? live per-launch battle screen, nil after its port disposes
function FieldBattlePresentation:liveScreen()
  local screen = self._screen
  if screen == nil then
    return nil
  end
  local ok, status = pcall(function()
    return screen:status()
  end)
  if not ok or type(status) ~= "table" or status.mode == "disposed" then
    return nil
  end
  return screen
end

---@return { coefficient: integer, color: integer } opaque-black cover status, 16 fully opaque
function FieldBattlePresentation:cover()
  return { coefficient = self._cover, color = FieldBattlePresentation.COVER_COLOR }
end

---@return boolean true while a presented launch holds field input and foreground
function FieldBattlePresentation:ownsInput()
  if self._launchId == nil then
    return false
  end
  if self:liveScreen() ~= nil then
    local status = self._lastStatus
    return status == nil or status.phase ~= "transfer"
  end
  -- The failed screen is gone while its launch still settles through
  -- the host: input stays held only while opaque cover still hides the
  -- field or the host still answers its recovery wait through the
  -- envelope. A screenless launch with nothing left to show or answer
  -- releases, so a failure before entry never pins field input behind
  -- a dead presentation.
  if self._cover > 0 then
    return true
  end
  local observed = self._lastStatus
  return observed ~= nil and observed.phase == "recovering"
end

-- Routes one semantic input batch to the live battle or child. While the
-- owned launch recovers through its defeat message, genuine edges answer
-- that wait instead: confirm acts, cancel cancels, and only a pointer
-- release matching its press taps. The disposed battle screen never sees
-- recovery input, and recovery edges never reach field input. Batches
-- without a live screen are dropped: focus loss and teardown neither
-- answer nor cancel a battle request.
---@param events table<integer, table<string, unknown>> semantic input batch
function FieldBattlePresentation:input(events)
  local descriptor = self._descriptor
  local host = descriptor ~= nil and descriptor.host or nil
  if host ~= nil and type(host.recoveryInput) == "function" then
    local okStatus, status = pcall(function()
      return host.status()
    end)
    if okStatus and type(status) == "table" and status.phase == "recovering" then
      self:_inputRecovery(host, events)
      return
    end
    self._recoveryPointerId = nil
  end
  local screen = self:liveScreen()
  if screen == nil then
    return
  end
  screen:input(events)
end

-- Answers the waiting defeat message with one genuine edge per press:
-- confirm acts, cancel cancels, and a pointer release taps only its own
-- matching press. Orphan releases, moves, and anything else stay silent,
-- and every release forgets its press whether it matched or not.
---@param host table<string, unknown> owning launch host behind the recovery callback
---@param events table<integer, table<string, unknown>> semantic input batch
function FieldBattlePresentation:_inputRecovery(host, events)
  assert(type(events) == "table", "recovery input arrives as an event list")
  for _, event in ipairs(events) do
    if type(event) == "table" then
      if event.type == "confirm" then
        host.recoveryInput({ pressedAction = true })
      elseif event.type == "cancel" then
        host.recoveryInput({ pressedCancel = true })
      elseif event.type == "pointer_down" then
        if event.outside ~= true then
          local pointerId = event.pointerId
          if type(pointerId) == "string" or type(pointerId) == "number" then
            self._recoveryPointerId = pointerId
          end
        end
      elseif event.type == "pointer_up" then
        local pressed = self._recoveryPointerId
        self._recoveryPointerId = nil
        if pressed ~= nil and event.pointerId == pressed then
          host.recoveryInput({ touchPressed = true })
        end
      end
    end
  end
end

-- Cancels a held press through both owners so a stale release never
-- activates after remeasure, submission, focus loss, or disposal.
function FieldBattlePresentation:cancelPointerCapture()
  self._recoveryPointerId = nil
  local screen = self._screen
  if screen ~= nil then
    screen:cancelPointerCapture()
  end
end

-- Draws the live battle through its screen owner with outer draw
-- resources. The sole painting bridge: fixed updates never draw, so
-- callers pass their own host graphics on every visible frame. Never
-- draws after the port disposes; the caller owns cover and field
-- composition around it.
---@param resources table<string, unknown> outer draw resources carrying host graphics
---@return boolean drawn true while a live screen drew
function FieldBattlePresentation:drawBattle(resources)
  local screen = self:liveScreen()
  if screen == nil then
    return false
  end
  assert(type(resources) == "table" and resources.graphics ~= nil, "battle drawing needs its host graphics")
  screen:draw(resources)
  return true
end

---@return string? battle-music start outcome for launch diagnostics
function FieldBattlePresentation:musicNote()
  return self._musicNote
end

-- Advances the envelope one accepted fixed quantum: the cover machine
-- follows the observed launch phase while the live screen and its cue
-- accumulator advance on the accepted time only. Draw, resize, and status
-- polling never advance these clocks.
---@param dt number accepted presentation seconds
function FieldBattlePresentation:updateFixed(dt)
  assert(type(dt) == "number" and dt == dt and dt >= 0, "presentation updates take accepted seconds")
  assert(not self._disposed, "the presented battle envelope is disposed")
  self._accumulator = self._accumulator + dt
  local steps = 0
  while
    self._accumulator + FieldBattlePresentation.SOURCE_EPSILON >= FieldBattlePresentation.SOURCE_FRAME
    and steps < FieldBattlePresentation.MAX_CATCH_UP
  do
    self._accumulator = self._accumulator - FieldBattlePresentation.SOURCE_FRAME
    steps = steps + 1
    self:_stepCover()
  end
  if self._accumulator + FieldBattlePresentation.SOURCE_EPSILON >= FieldBattlePresentation.SOURCE_FRAME then
    local discarded =
      math.floor((self._accumulator + FieldBattlePresentation.SOURCE_EPSILON) / FieldBattlePresentation.SOURCE_FRAME)
    self._accumulator = self._accumulator - discarded * FieldBattlePresentation.SOURCE_FRAME
  end
  -- The scheduled scene behind a pending launch resolves here: the
  -- worker is observed before the host advances, so the battle runtime
  -- cannot publish a packet before its screen exists and a terminal
  -- build failure reaches the host before any further advance.
  self:_pollPendingScreen()
  -- The presented launch advances only here: the runtime phase machine
  -- and the owned battle clock run once per envelope tick, never through
  -- the host-update pump as well.
  local descriptor = self._descriptor
  local host = descriptor ~= nil and descriptor.host or nil
  if self._launchId ~= nil and host ~= nil then
    host.advance()
  end
  -- After fixed cover and host advance, update semantic battle state only.
  local screen = self._screen
  if screen ~= nil then
    screen:updateFixed(steps * FieldBattlePresentation.SOURCE_FRAME)
    self:_observeScreenFailure()
  end
  -- No screen:draw call here; the field's draw callback owns painting.
end

-- One source-clock cover step behind the observed launch phase. Cover
-- completion, terminal cover, and reveal each notify the runtime exactly
-- once at their threshold; stale notifications are ignored there.
function FieldBattlePresentation:_stepCover()
  local launchId = self._launchId
  if launchId == nil then
    if self._cover > 0 then
      self._cover = math.max(0, self._cover - FieldBattlePresentation.COVER_STEP)
    end
    return
  end
  local descriptor = self._descriptor
  local host = descriptor ~= nil and descriptor.host or nil
  if host == nil then
    self:_dropLaunch()
    return
  end
  local okStatus, status = pcall(function()
    return host.status()
  end)
  if not okStatus or status == nil then
    self:_dropLaunch()
    return
  end
  self._lastStatus = status
  local phase = status.phase
  if phase == nil or phase == "failed" or phase == "complete" then
    self:_dropLaunch()
    return
  end
  if phase == "covering" then
    self:_stepCoverUp()
    if self._cover >= FieldBattlePresentation.COVER_MAX then
      host.notify("cover-complete")
      -- Battle music starts once under full cover: the role was selected
      -- from staged source data at admission.
      self:_startBattleMusic()
    end
    return
  end
  if phase == "terminal" then
    self:_stepCoverUp()
    if self._cover >= FieldBattlePresentation.COVER_MAX then
      host.notify("battle-covered")
    end
    self._revealingBattle = false
    return
  end
  if phase == "revealing" then
    self:_stepCoverDown()
    if self._cover <= 0 then
      host.notify("revealed")
    end
    return
  end
  if phase == "recovering" or phase == "transfer" then
    -- The recovery UI owns input under its own cover once its message
    -- presents: the retained battle cover transfers instead of layering
    -- over the message. Until then full cover is retained.
    local blackoutPhase = status.blackoutPhase
    if blackoutPhase == "message_in" or blackoutPhase == "message_wait" or blackoutPhase == "message_out" then
      self:_stepCoverDown()
    end
    return
  end
  if phase == "restoring" then
    self:_stepCoverUp()
    return
  end
  if phase == "aborting" then
    -- The field is still gone or on its way back: hold full cover until
    -- the host confirms the restored field and starts the abort reveal.
    self:_stepCoverUp()
    return
  end
  if phase == "abort-revealing" then
    self:_stepCoverDown()
    if self._cover <= 0 then
      host.notify("revealed")
    end
    return
  end
  -- Leaving and active hold full cover until the constructed battle
  -- proves exact-asset readiness; the reveal then runs beside the intro.
  if self._revealingBattle then
    self:_stepCoverDown()
    return
  end
  if self._cover >= FieldBattlePresentation.COVER_MAX and self:_portEnterReady() then
    self._revealingBattle = true
    self:_stepCoverDown()
  end
end

function FieldBattlePresentation:_stepCoverUp()
  if self._cover < FieldBattlePresentation.COVER_MAX then
    self._cover = math.min(FieldBattlePresentation.COVER_MAX, self._cover + FieldBattlePresentation.COVER_STEP)
  end
end

function FieldBattlePresentation:_stepCoverDown()
  if self._cover > 0 then
    self._cover = math.max(0, self._cover - FieldBattlePresentation.COVER_STEP)
  end
end

-- Polls exact-asset readiness through the port's idempotent entry: true
-- once the constructed opening model resolves its scene demand. Repeated
-- polls never restart entry.
---@return boolean ready
function FieldBattlePresentation:_portEnterReady()
  local port = self._port
  local descriptor = self._descriptor
  if port == nil or descriptor == nil then
    return false
  end
  local ok, ready = pcall(port.enter, { launchId = descriptor.launchId, kind = descriptor.kind })
  return ok and ready == true
end

-- Starts the source-defined battle music role once under full cover. The
-- start is attempted exactly once per launch; an unstaged bank records
-- its outcome and the launch continues, since the acceptance closure
-- stages no audio sequences while production playback resolves through
-- the normalized catalog.
function FieldBattlePresentation:_startBattleMusic()
  if self._musicStarted then
    return
  end
  self._musicStarted = true
  local descriptor = self._descriptor
  local role = descriptor ~= nil and descriptor.musicRole or nil
  local audio = descriptor ~= nil and descriptor.audio or nil
  if type(role) ~= "string" or role == "" then
    self._musicNote = "skipped-no-role"
    return
  end
  if audio == nil or type(audio.playMusic) ~= "function" then
    self._musicNote = "skipped-no-audio"
    return
  end
  local ok, err = pcall(function()
    return audio:playMusic(role)
  end)
  if ok then
    self._musicNote = "started:" .. role
  else
    self._musicNote = "unstaged:" .. role .. ":" .. tostring(err)
  end
end

-- Observes a failed screen and reports the launch through the runtime
-- instead of polling a dead presentation: the screen disposes once while
-- the descriptor, black cover, and launch identity stay with the host
-- until the safe field returns. Repeats collapse into the first report
-- because the screen is gone after the first one.
function FieldBattlePresentation:_observeScreenFailure()
  local screen = self._screen
  local descriptor = self._descriptor
  if screen == nil or descriptor == nil then
    return
  end
  local host = descriptor.host
  if host == nil then
    return
  end
  local ok, status = pcall(function()
    return screen:status()
  end)
  if ok and type(status) == "table" and status.mode == "failed" then
    host.notify("screen-failed", status.error)
    local _, _ = pcall(function()
      return screen:dispose()
    end)
    self._screen = nil
  end
end

-- Forgets a cleared launch: the runtime disposed the battle port (and its
-- screen) before clearing, so only envelope bookkeeping remains.
function FieldBattlePresentation:_dropLaunch()
  self._launchId = nil
  self._descriptor = nil
  self._pendingFailed = false
  self._pendingBuild = false
  self._recoveryPointerId = nil
  self._screen = nil
  self._port = nil
  self._innerPort = nil
  self._lastStatus = nil
  self._revealingBattle = false
  self._musicStarted = false
  self._musicNote = nil
end

-- Idempotent release of the envelope lifetime: the live screen releases
-- exactly once while borrowed field font, window, and audio services stay
-- usable for their owner. The factory binding belongs to the field
-- lifetime and is removed there, never here.
function FieldBattlePresentation:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self:cancelPointerCapture()
  local screen = self._screen
  if screen ~= nil then
    local _, _ = pcall(function()
      return screen:dispose()
    end)
  end
  -- Battle closure returns every shared borrow exactly once; the shared
  -- owner alone frees physical images, so no raw image release runs here.
  local pool = self._pool
  for key, pooled in pairs(self._leases) do
    self._leases[key] = nil
    if pool ~= nil then
      pool:release(pooled.lease)
    end
  end
  for key, _ in pairs(self._imageFailures) do
    self._imageFailures[key] = nil
  end
  self:_dropLaunch()
  self._cover = 0
  self._accumulator = 0
end

return FieldBattlePresentation
