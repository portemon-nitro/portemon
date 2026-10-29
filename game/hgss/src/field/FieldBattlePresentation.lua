-- Field-local presented-battle adapter. One envelope per field lifetime owns
-- cover and readiness while delegating each launch to a live per-launch
-- battle screen built through its bindable factory. It never chooses
-- moves, generates opponents, interprets raw battle graphics, or publishes
-- party, bag, or money consequences: the field runtime owns the launch
-- machine and receipts, the battle runtime owns mechanics and publication,
-- and the blackout flow owns defeat recovery. Draw calls are read-only;
-- the fixed clock is the only thing that advances presentation.

local SourceTick = require("libs.hgss.src.field.SourceTick")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local BattleAudio = require("libs.hgss.src.audio.BattleAudio")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local MoveIconCache = require("libs.assets.src.MoveIconCache")
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
local BattleScreenState = require("game.hgss.src.battle.BattleScreenState")
local MonCache = require("libs.assets.src.MonCache")
local BattleEncounterTransition = require("libs.hgss.src.transition.BattleEncounterTransition")
local BattleMusicSelection = require("game.hgss.src.battle.BattleMusicSelection")
local TransitionFamilyFactory = require("libs.hgss.src.transition.TransitionFamilyFactory")

---@class FieldBattlePresentation
---@field _cacheFs table<string, unknown> versioned derived cache behind demand validation
---@field _derivedAssets table<string, function>? borrowed staged battle-art demand host, never disposed here
---@field _text table<string, unknown> borrowed text services behind plan rendering
---@field _windows table<string, unknown> borrowed window services behind plan rendering
---@field _screenAudio table<string, unknown> semantic cue-audio boundary behind the screen
---@field _pokedex table<string, unknown>? borrowed field presentation resource owner behind the registration card
---@field _itemCatalog table<string, unknown>? borrowed immutable item catalog behind battle bag grouping
---@field _monCatalog table<string, unknown>? borrowed immutable mon catalog behind machine display facts
---@field _monIconProvider table<string, unknown>? field-owned icon page provider borrowed for battle command icons
---@field _battleMenus table<string, unknown> borrowed field-owned bag and party presentation services
---@field _imageFailures table<string, string> terminal upload failures by key, latched for the envelope lifetime
---@field _pendingSceneImage { path: string, token: integer }? pre-enrolled scene image ticket behind the pending build
---@field _pendingUploads table<string, integer> pre-enrolled pool tickets by staged image path behind the pending build
---@field _enrolledUploads table<string, boolean> staged image paths already enrolled this launch
---@field _warmPinned table<string, FieldBattlePresentation.PooledHandle> scene-independent borrows kept across launches
---@field _warmPaths table<string, string> staged image path behind each warm pin, for exact reuse matching
---@field _warmTickets { key: string, path: string, token: integer }[] pending speculative pool tickets in enrollment order
---@field _warmDesired string? predicted scene key the speculative ledger currently serves
---@field _warmFailed table<string, string> latched speculative failures by staged image path for the desired scene
---@field _warmBg3Key string? scene key behind the staged speculative BG3 source values
---@field _warmBg3 table<string, unknown>? staged speculative BG3 characters/map/palette source values by exact scene
---@field _warmFailure string? last attributable idle warmup diagnostic, never raised into field update
---@field _manifestDocs table<string, table<string, unknown>> parsed staged documents by cache-relative path
---@field _stagedMembersOk boolean true once the staged menu, HUD, font, and audio membership validated
---@field _measureDisplay fun(): table<string, unknown> live display facts
---@field _graphics table<string, unknown>? host graphics namespace enabling GPU upload, nil for data descriptors
---@field _manifest table<string, unknown> staged or planning presentation manifest
---@field _services table<string, unknown> cache-backed preparation services carrying prepare/drawable/release
---@field _preparedDemands table<integer, table<string, unknown>> exact launch demands requested, in order
---@field _launchId string? active launch identity, nil outside launches
---@field _descriptor table<string, unknown>? active launch descriptor from the runtime
---@field _pendingFailed boolean true once the envelope reported its terminal launch failure
---@field _pendingBuild boolean true while a scheduled launch still awaits its deferred screen
---@field _portDisposed boolean true once the live five-operation port released its screen
---@field _recoveryPointerId string|number|nil pending recovery press identity awaiting its release
---@field _screen table<string, unknown>? live per-launch battle screen
---@field _port table<string, unknown>? live five-operation port behind the owned battle
---@field _innerPort table<string, unknown>? owned screen port a pending facade forwards to once built
---@field _lastStatus table<string, unknown>? latest observed launch status snapshot
---@field _cover integer current opaque-black cover coefficient on the 0..16 scale
---@field _accumulator number source-frame time held toward the next cover step
---@field _revealingBattle boolean true once the constructed battle starts its reveal
---@field _musicStarted boolean true once battle music was attempted for the launch
---@field _musicNote string? battle-music start note, set once the staged track voices
---@field _musicRole string? chosen battle-music symbol behind the exact demand closure
---@field _resultMusicPlayed boolean true once the result music swap was attempted for the launch
---@field _pool table<string, unknown>? borrowed shared generated-image owner, required once graphics resolve pixels
---@field _leases table<string, FieldBattlePresentation.PooledHandle> shared-owner leases by drawable key
---@field _fieldRenderer table<string, unknown>? field-local native plane compositor
---@field _fieldCamera fun(): table<string, unknown>? current field camera provider
---@field _captureFieldLayers fun(): table<string, unknown>? fresh launch-owned native field planes
---@field _transition table<string, unknown>? selected launch-owned native transition
---@field _transitionContext table<string, unknown>? immutable context captured before field mutation
---@field _transitionCapture table<string, unknown>? latest source-tick native field planes
---@field _transitionFailed boolean true after a reported native transition failure
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
---@field pokedex table<string, unknown>? borrowed field presentation resource owner behind the registration card
---@field measureDisplay fun(): table<string, unknown> live display facts
---@field derivedAssets table<string, function>? borrowed staged battle-art demand host
---@field graphics table<string, unknown>? host graphics namespace enabling GPU upload, nil for data descriptors
---@field itemCatalog table<string, unknown>? borrowed immutable item catalog behind battle bag grouping
---@field monCatalog table<string, unknown>? borrowed immutable mon catalog behind machine display facts
---@field monIconProvider table<string, unknown>? borrowed field icon page provider for the active command icon
---@field battleMenus table<string, unknown> borrowed field-owned bag and party presentation services
---@field imagePool table<string, unknown>? borrowed shared generated-image owner behind pooled uploads, required to resolve graphical drawables
---@field fieldRenderer table<string, unknown>? field-local native plane compositor
---@field fieldCamera fun(): table<string, unknown>? current field camera provider
---@field captureFieldLayers fun(): table<string, unknown>? fresh launch-owned native field planes
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

---@class FieldBattlePresentation.StagedImage
---@field image string cache-relative staged image path

---@class FieldBattlePresentation.MoveButton
---@field empty string blank-slot image path
---@field types table<string, table<string, string>> image paths by move type, then by normal/pressed state

---@class FieldBattlePresentation.MenuScreen
---@field image string base screen image path
---@field backgrounds table<string, string>? image paths by scene background that changes the screen pixels
---@field touchBackgrounds table<string, string>? touch-feedback image paths by scene background
---@field feedback table<string, table<string, FieldBattlePresentation.StagedImage>>? patches by control id, then state
---@field moveButtons FieldBattlePresentation.MoveButton[]? fight-menu buttons by slot

---@class FieldBattlePresentation.MenuSection
---@field image string
---@field screens FieldBattlePresentation.MenuScreen[]

-- The staged manifest members this envelope reads, each one required by
-- BattlePresentationSchema.assertManifest.
---@class FieldBattlePresentation.StagedManifest
---@field scenes { key: string }[]
---@field pictures { shadow: FieldBattlePresentation.StagedImage }
---@field hud { player: FieldBattlePresentation.StagedImage, enemy: FieldBattlePresentation.StagedImage, doubles: table<"playerLeft"|"playerRight"|"enemyLeft"|"enemyRight", FieldBattlePresentation.StagedImage>, arrow: FieldBattlePresentation.StagedImage, cursor: FieldBattlePresentation.StagedImage, partyGauges: FieldBattlePresentation.StagedImage[] }
---@field menus { command: FieldBattlePresentation.MenuSection, moves: FieldBattlePresentation.MenuSection, target: FieldBattlePresentation.MenuSection, twoOption: FieldBattlePresentation.MenuSection, lower: { pulseMask: string } }
---@field messages { roles: table<string, { font: string }> }
---@field audioRoles { wild: string, trainer: string, rival: string, select: string }

-- The one staged/planning decision. BattlePresentationCache.load answers
-- either a verified manifest that passed
-- BattlePresentationSchema.assertManifest or the unverified planning
-- inventory, which carries only its scenes; a staged manifest is then
-- indexed directly as the schema guarantees.
---@param manifest table<string, unknown> loaded presentation manifest
---@return FieldBattlePresentation.StagedManifest? staged manifest, nil for the planning inventory
local function stagedManifest(manifest)
  if manifest.verified ~= true then
    return nil
  end
  return manifest --[[@as FieldBattlePresentation.StagedManifest]]
end

-- Battle visuals sample point-filtered and clamped, matching the direct
-- construction below, so pooled borrows draw identically.
local POOLED_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }

-- Fixed drawables every graphical launch reaches for, pinned at the
-- envelope lifetime: HUD composites, command surfaces, and the shadow
-- never vary by scene, so a repeat battle reuses the same borrow
-- instead of re-enrolling worker and GPU work.
local WARM_PINNED_KEYS = {
  ["hud:enemy"] = true,
  ["hud:player"] = true,
  ["menu:command"] = true,
  ["menu:moves"] = true,
  ["menu:target"] = true,
  ["shadow"] = true,
}

-- Parses one staged Lua document once per envelope lifetime: manifests
-- never change under a live envelope, so repeat launches share the
-- single parse instead of re-reading and re-compiling the same chunk
-- on every preparation round. Missing documents stay uncached and keep
-- retrying instead of pinning an absence.
---@param envelope FieldBattlePresentation
---@param path string cache-relative Lua document path
---@return table<string, unknown>? parsed document, nil when the document is missing
local function stagedDoc(envelope, path)
  local cached = envelope._manifestDocs[path]
  if cached ~= nil then
    return cached
  end
  local doc = envelope._cacheFs:loadLua(path)
  if type(doc) ~= "table" then
    return nil
  end
  envelope._manifestDocs[path] = doc
  return doc
end

-- The exact drawable keys forming one predicted scene group, in stable
-- adoption order: the scene image first, then its intro and terrain art.
-- These are the same keys the launch preparation resolves, so a warmed
-- group answers through the canonical drawable without a second owner.
---@param sceneKey string validated scene key behind the group
---@return string[] exact scene-group drawable keys in adoption order
local function warmSceneKeys(sceneKey)
  return {
    "scene:" .. sceneKey,
    "scene-intro:" .. sceneKey,
    "scene-terrain:" .. sceneKey .. ":player",
    "scene-terrain:" .. sceneKey .. ":foe",
  }
end

-- Names the scene behind one scene-group drawable key, or nil for fixed
-- and foreign keys. Only exact canonical shapes resolve, so a guessed
-- variant never retires or reuses another scene's pins.
---@param key string drawable key under inspection
---@return string? owning scene key, nil unless the key names one exactly
local function warmSceneOfKey(key)
  local text = tostring(key)
  local scene = text:match("^scene:(.+)$")
  if scene ~= nil and BattlePresentationCache.parseSceneKey(scene) ~= nil then
    return scene
  end
  scene = text:match("^scene%-intro:(.+)$")
  if scene ~= nil and BattlePresentationCache.parseSceneKey(scene) ~= nil then
    return scene
  end
  local playerScene = text:match("^scene%-terrain:(.+):player$")
  if playerScene ~= nil and BattlePresentationCache.parseSceneKey(playerScene) ~= nil then
    return playerScene
  end
  local foeScene = text:match("^scene%-terrain:(.+):foe$")
  if foeScene ~= nil and BattlePresentationCache.parseSceneKey(foeScene) ~= nil then
    return foeScene
  end
  return nil
end

-- Whether one scene group reads fully warm: every exact group key holds
-- its pin. Only a complete successor retires its predecessor, so a
-- pending replacement never deletes the last usable scene record.
---@param envelope FieldBattlePresentation
---@param sceneKey string predicted scene key under inspection
---@return boolean complete
local function warmGroupComplete(envelope, sceneKey)
  for _, groupKey in ipairs(warmSceneKeys(sceneKey)) do
    if envelope._warmPinned[groupKey] == nil then
      return false
    end
  end
  return true
end

-- Retires every other scene's group pins once the kept scene reads fully
-- warm: each superseded lease returns to the shared owner exactly once.
-- Fixed art stays scene-independent. Runs only from idle adoption, never
-- while a real launch owns the envelope.
---@param envelope FieldBattlePresentation
---@param keepScene string completed scene group surviving the retirement
local function retireWarmGroups(envelope, keepScene)
  local pool = envelope._pool
  for key, record in pairs(envelope._warmPinned) do
    local scene = warmSceneOfKey(key)
    if scene ~= nil and scene ~= keepScene then
      envelope._warmPinned[key] = nil
      if envelope._warmPaths ~= nil then
        envelope._warmPaths[key] = nil
      end
      if pool ~= nil and record ~= nil then
        pcall(pool.release, pool, record.lease)
      end
    end
  end
end

-- Pins one resolved pooled borrow at the envelope lifetime: fixed
-- drawables and one complete scene group survive launch disposal. A
-- newly pinned scene key never evicts its predecessor on its own: the
-- prior scene's group retires only once the successor group reads
-- fully warm, so a mid-replacement launch never strands a split group
-- of half-old, half-new scene art.
---@param envelope FieldBattlePresentation
---@param key string drawable key behind the installed borrow
local function pinWarm(envelope, key)
  if WARM_PINNED_KEYS[key] == true then
    envelope._warmPinned[key] = envelope._leases[key]
    return
  end
  local scene = warmSceneOfKey(key)
  if scene == nil then
    return
  end
  envelope._warmPinned[key] = envelope._leases[key]
  if warmGroupComplete(envelope, scene) then
    retireWarmGroups(envelope, scene)
  end
end

-- Enrolls one prefetch ticket per missing entry; adopted pins and live
-- tickets never re-enroll, and latched failures stay quiet until the
-- prediction changes. A pin behind a changed path releases once here
-- before its replacement enrolls. Enrolled paths mark the launch
-- enrollment ledger so the matching foreground demand takes over the
-- ticket instead of stacking a second enrollment behind it.
---@param envelope FieldBattlePresentation
---@param pool table<string, unknown> borrowed shared generated-image owner
---@param entries { key: string, path: string }[] key/path pairs in adoption order
---@param ticketed table<string, boolean> keys already holding a live ticket
local function enrollWarmEntries(envelope, pool, entries, ticketed)
  for _, entry in ipairs(entries) do
    local pinned = envelope._warmPinned[entry.key] ---@type FieldBattlePresentation.PooledHandle?
    if pinned ~= nil and envelope._warmPaths[entry.key] ~= entry.path then
      envelope._warmPinned[entry.key] = nil
      envelope._warmPaths[entry.key] = nil
      pcall(pool.release, pool, pinned.lease)
      pinned = nil
    end
    if pinned == nil and ticketed[entry.key] ~= true and envelope._warmFailed[entry.path] == nil then
      local token = pool:request(entry.path, POOLED_SAMPLER, "prefetch")
      envelope._warmTickets[#envelope._warmTickets + 1] = { key = entry.key, path = entry.path, token = token }
      ticketed[entry.key] = true
      envelope._enrolledUploads[entry.path] = true
    end
  end
end

-- Cancels every outstanding speculative ticket exactly once and forgets
-- it: a late worker response for an abandoned ticket can never publish
-- into a newer prediction, and a cancelled token is never consumed.
-- Adopted pins and launch tickets are untouched.
---@param envelope FieldBattlePresentation
local function cancelWarmTickets(envelope)
  local tickets = envelope._warmTickets
  envelope._warmTickets = {}
  if tickets == nil then
    return
  end
  local pool = envelope._pool
  if pool == nil then
    return
  end
  for _, ticket in ipairs(tickets) do
    pcall(pool.cancel, pool, ticket.token)
  end
end

-- Enrolls one staged image decode on the shared owner without waiting:
-- preparation overlaps worker work for art the pending build will draw,
-- and the drawable takes over the ticket instead of enrolling again.
-- Each path enrolls once per launch; consumed or dropped tickets leave
-- through the drawable takeover or the launch teardown.
---@param envelope FieldBattlePresentation
---@param path string cache-relative staged image path
local function enrollUpload(envelope, path)
  local pool = envelope._pool
  if pool == nil then
    return
  end
  if envelope._enrolledUploads[path] == true or envelope._pendingUploads[path] ~= nil then
    return
  end
  envelope._enrolledUploads[path] = true
  envelope._pendingUploads[path] = pool:request(path, POOLED_SAMPLER, "demand")
end

-- Takes over one pre-enrolled upload ticket for the staged path, if the
-- pending build enrolled it: the drawable awaits the shared decode
-- instead of stacking a second enrollment behind it.
---@param envelope FieldBattlePresentation
---@param path string cache-relative staged image path
---@return integer? pre-enrolled pool ticket, nil when preparation enrolled nothing
local function takePendingUpload(envelope, path)
  local token = envelope._pendingUploads[path]
  if token ~= nil then
    envelope._pendingUploads[path] = nil
  end
  return token
end

---@param manifest table<string, unknown> staged or planning presentation manifest
---@param sceneKey string semantic scene key under admission
---@return boolean true when the manifest inventories the scene
local function inventoriesScene(manifest, sceneKey)
  for _, entry in
    ipairs(manifest.scenes --[[@as { key: string }[] ]])
  do
    if entry.key == sceneKey then
      return true
    end
  end
  return false
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
  local portraits = stagedDoc(envelope, MonCache.portraitManifestPath())
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

-- Validates and queues the exact semantic trainer pictures behind an
-- opening demand. The selected-game host owns generation; staged manifest
-- entries alone never claim readiness while a host says they are pending.
---@param envelope FieldBattlePresentation
---@param selectors string[] semantic `front:<class>` / `back:<class>` selectors
---@return boolean? ready true when every picture is staged, false while building
---@return string? terminal failure naming the exact selector
local function checkTrainerPictures(envelope, selectors)
  if #selectors == 0 then
    return true
  end
  local manifest = stagedDoc(envelope, BattlePresentationCache.manifestPath())
  local pictures = type(manifest) == "table" and manifest.trainerPictures or nil
  local entries = type(pictures) == "table" and pictures.entries or nil
  if type(entries) ~= "table" then
    return nil, "battle demand needs its staged trainer picture manifest: " .. tostring(selectors[1])
  end
  local host = envelope._derivedAssets
  local requestPicture = type(host) == "table" and host.requestBattleTrainerPicture or nil
  local waiting = false
  for _, selector in ipairs(selectors) do
    if type(selector) ~= "string" then
      return nil, "trainer picture selectors must name a front/back class"
    end
    local role, classKey = selector:match("^(front):([%w_]+)$")
    if role == nil then
      role, classKey = selector:match("^(back):([%w_]+)$")
    end
    if role == nil or classKey == nil then
      return nil, "trainer picture selectors must name a front/back class: " .. tostring(selector)
    end
    local entry = entries[selector]
    if
      type(entry) ~= "table"
      or entry.drawableKey ~= ("trainer:" .. role .. ":" .. classKey)
      or entry.width ~= 80
      or entry.height ~= 80
      or type(entry.image) ~= "string"
      or entry.image == ""
    then
      return nil, "battle demand names an unstaged trainer picture: " .. selector
    end
    local sequences = type(entry.animation) == "table" and entry.animation.sequences or nil
    if entry.animation ~= nil and sequences == nil then
      return nil, "battle demand names a trainer picture without source sequences: " .. selector
    end
    if sequences ~= nil then
      if type(sequences) ~= "table" or #sequences == 0 then
        return nil, "battle demand names a trainer picture without source sequences: " .. selector
      end
      for sequenceIndex, sequence in ipairs(sequences) do
        if type(sequence) ~= "table" or sequence.sourceSequence ~= sequenceIndex - 1 then
          return nil, "battle demand names an invalid trainer source sequence: " .. selector
        end
        local frames = sequence.frames
        if type(frames) ~= "table" or #frames == 0 then
          return nil, "battle demand names a trainer sequence without source frames: " .. selector
        end
        for frameIndex, frame in ipairs(frames) do
          local expectedKey
          if sequence.sourceSequence == 0 then
            expectedKey = frameIndex == 1 and entry.drawableKey
              or (entry.drawableKey .. ":frame:" .. tostring(frameIndex - 1))
          else
            expectedKey = entry.drawableKey
              .. ":sequence:"
              .. tostring(sequence.sourceSequence)
              .. ":frame:"
              .. tostring(frameIndex - 1)
          end
          if
            type(frame) ~= "table"
            or frame.sourceFrame ~= frameIndex - 1
            or frame.drawableKey ~= expectedKey
            or type(frame.image) ~= "string"
            or frame.image == ""
          then
            return nil, "battle demand names an invalid trainer source frame: " .. selector
          end
        end
      end
    end
    if type(requestPicture) == "function" then
      local ready, failure = requestPicture(selector, "required")
      if failure ~= nil then
        return nil, "trainer picture " .. selector .. ": " .. tostring(failure)
      end
      if ready ~= true then
        waiting = true
      elseif envelope._graphics ~= nil and not envelope._cacheFs:exists(entry.image, "file") then
        return nil, "trainer picture image is not staged: " .. selector .. ": " .. entry.image
      end
    elseif envelope._graphics ~= nil and not envelope._cacheFs:exists(entry.image, "file") then
      return nil, "trainer picture image is not staged: " .. selector .. ": " .. entry.image
    end
  end
  if waiting then
    return false
  end
  return true
end

---@param envelope FieldBattlePresentation
---@param selectors string[] semantic `ball:<key>` selectors
---@return boolean? ready true when every ball frame is staged, false while building
---@return string? terminal failure naming the exact selector
local function checkBattleBalls(envelope, selectors)
  if #selectors == 0 then
    return true
  end
  local manifest = stagedDoc(envelope, BattlePresentationCache.manifestPath())
  local balls = type(manifest) == "table" and manifest.battleBalls or nil
  local entries = type(balls) == "table" and balls.entries or nil
  if type(entries) ~= "table" then
    return nil, "battle demand needs its staged ball manifest: " .. tostring(selectors[1])
  end
  local host = envelope._derivedAssets
  local requestBalls = type(host) == "table" and host.requestBattleBalls or nil
  local waiting = false
  for _, selector in ipairs(selectors) do
    if type(selector) ~= "string" or selector:match("^ball:[%w_]+$") == nil then
      return nil, "battle ball selectors must name semantic balls: " .. tostring(selector)
    end
    local ballKey = selector:match("^ball:([%w_]+)$")
    local entry = entries[selector]
    local frames = type(entry) == "table" and entry.frames or nil
    if type(frames) ~= "table" or #frames == 0 then
      return nil, "battle demand names an unstaged ball: " .. selector
    end
    for frameIndex, frame in ipairs(frames) do
      local drawableKey = "battle-ball:" .. ballKey .. ":" .. tostring(frameIndex - 1)
      if
        type(frame) ~= "table"
        or frame.drawableKey ~= drawableKey
        or type(frame.image) ~= "string"
        or frame.image == ""
        or type(frame.width) ~= "number"
        or frame.width <= 0
        or type(frame.height) ~= "number"
        or frame.height <= 0
      then
        return nil, "battle demand names an invalid ball frame: " .. selector .. ":" .. tostring(frameIndex - 1)
      end
    end
    if type(requestBalls) == "function" then
      local ready, failure = requestBalls({ selector }, "required")
      if failure ~= nil then
        return nil, "battle ball " .. selector .. ": " .. tostring(failure)
      end
      if ready ~= true then
        waiting = true
      elseif envelope._graphics ~= nil then
        for _, frame in ipairs(frames) do
          if not envelope._cacheFs:exists(frame.image, "file") then
            return nil, "battle ball image is not staged: " .. selector .. ": " .. frame.image
          end
        end
      end
    elseif envelope._graphics ~= nil then
      for _, frame in ipairs(frames) do
        if not envelope._cacheFs:exists(frame.image, "file") then
          return nil, "battle ball image is not staged: " .. selector .. ": " .. frame.image
        end
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
  if opts.pokedex ~= nil then
    assert(type(opts.pokedex) == "table", "the registration card borrows its presentation owner")
    assert(type(opts.pokedex.acquire) == "function", "the borrowed owner acquires registration leases")
  end
  local envelope = setmetatable({
    _cacheFs = opts.cacheFs,
    _text = opts.text,
    _windows = opts.windows,
    _screenAudio = opts.audio or nullAudio(),
    _pokedex = opts.pokedex,
    _measureDisplay = opts.measureDisplay,
    _derivedAssets = opts.derivedAssets,
    _graphics = opts.graphics,
    _itemCatalog = opts.itemCatalog,
    _monCatalog = opts.monCatalog,
    _monIconProvider = opts.monIconProvider,
    _battleMenus = opts.battleMenus,
    _overrides = opts.overrides or {},
    _manifest = loadManifest(opts.cacheFs),
    _preparedDemands = {},
    _launchId = nil,
    _descriptor = nil,
    _pendingFailed = false,
    _pendingBuild = false,
    _portDisposed = false,
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
    _musicRole = nil,
    _resultMusicPlayed = false,
    _fieldRenderer = opts.fieldRenderer,
    _fieldCamera = opts.fieldCamera,
    _captureFieldLayers = opts.captureFieldLayers,
    _transition = nil,
    _transitionContext = nil,
    _transitionCapture = nil,
    _transitionFailed = false,
    _disposed = false,
    _images = {},
    _imageFailures = {},
    _pendingSceneImage = nil,
    _pendingUploads = {},
    _enrolledUploads = {},
    _warmPinned = {},
    _warmPaths = {},
    _warmTickets = {},
    _manifestDocs = {},
    _stagedMembersOk = false,
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

-- Borrows one staged page through the shared owner under a drawable key:
-- the same bounded stall and keyed terminal failure as a whole-image
-- borrow, answering the raw lease so cell drawables can pair the pooled
-- page with their renderer-owned quad.
---@param envelope FieldBattlePresentation
---@param key string drawable key behind diagnostics
---@param path string cache-relative staged page path behind diagnostics
---@param token integer? already-enrolled pool ticket to await instead of requesting again
---@return table<string, unknown>? resolved page lease, nil on terminal failure
---@return string? terminal failure naming the key and path, nil on success
local function borrowPage(envelope, key, path, token)
  local pool = assert(envelope._pool, "pooled battle uploads borrow the shared image owner")
  if token == nil then
    token = pool:request(path, POOLED_SAMPLER, "demand")
  end
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
-- installing the resolved image as the drawable behind the key. A
-- pre-enrolled ticket (scene image enrolled at admission) rides instead
-- of a fresh request so the worker decodes concurrently with the
-- pending build.
---@param envelope FieldBattlePresentation
---@param key string drawable key behind diagnostics
---@param path string cache-relative staged image path behind diagnostics
---@param token integer? already-enrolled pool ticket to await instead of requesting again
---@return table<string, unknown>? resolved drawable lease, nil on terminal failure
---@return string? terminal failure naming the key and path, nil on success
local function acquirePooled(envelope, key, path, token)
  -- A matching warm pin answers with no new borrow: the envelope owns
  -- the borrow across launches, and the scene staging closure calls
  -- here directly instead of through the drawable fast path. An
  -- orphaned launch ticket behind the hit is cancelled instead of
  -- retained unclaimed.
  local pinned = envelope._warmPinned[key]
  if pinned ~= nil and envelope._warmPaths ~= nil and envelope._warmPaths[key] == path then
    if token ~= nil then
      local pool = envelope._pool
      if pool ~= nil then
        pcall(pool.cancel, pool, token)
      end
    end
    return pinned.handle
  end
  -- A pre-enrolled ticket from preparation rides instead of a fresh
  -- request so the drawable awaits the shared decode instead of
  -- stacking a second enrollment behind it.
  if token == nil then
    token = takePendingUpload(envelope, path)
  end
  local lease, failure = borrowPage(envelope, key, path, token)
  if lease == nil then
    return nil, failure
  end
  assert(lease.image, "shared borrows carry their resolved image")
  envelope._leases[key] = { lease = lease, handle = lease }
  pinWarm(envelope, key)
  if envelope._warmPinned[key] ~= nil then
    envelope._warmPaths = envelope._warmPaths or {}
    envelope._warmPaths[key] = path
  end
  return lease
end

-- Uploads one staged image file through the host graphics namespace:
-- decode the staged bytes, then build and configure the owned image.
-- Success answers the owned handle. Staged bytes that fail decoding or
-- GPU upload answer a terminal keyed failure so the caller fails closed
-- instead of holding forever on a deterministic corrupt image.
---@param graphics table<string, unknown> host graphics namespace enabling GPU upload
---@param key string drawable key behind diagnostics
---@param path string cache-relative staged image path behind diagnostics
---@param bytes string staged image bytes
---@return table<string, unknown>? owned image handle, nil on terminal failure
---@return string? terminal failure naming the key and path, nil on success
local function uploadStaged(graphics, key, path, bytes)
  local ok, imageOrErr = pcall(function()
    local pixels = love.image.newImageData(love.filesystem.newFileData(bytes, path))
    local uploaded = graphics.newImage(pixels)
    assert(uploaded ~= nil, "the graphics driver handed out no image")
    uploaded:setFilter("nearest", "nearest")
    return uploaded
  end)
  if ok and imageOrErr ~= nil then
    return imageOrErr
  end
  local cause = ok and "empty image handle" or tostring(imageOrErr)
  return nil, "battle image " .. tostring(key) .. " upload failed: " .. tostring(path) .. ": " .. cause
end

-- Uploads one staged effect texture descriptor through the host graphics
-- namespace: validate the exact typed RGBA payload dimensions and byte
-- length, expand the bytes into one nearest-filtered image, and answer
-- the owned handle. Anything short of an exact payload, a missing
-- graphics namespace, or a driver failure answers a terminal failure
-- naming the effect, resource, and payload path so the caller fails
-- closed instead of holding forever on a deterministic corrupt image.
---@param graphics table<string, unknown>? host graphics namespace enabling GPU upload
---@param effectKey string selected semantic effect key behind diagnostics
---@param resourceKey string semantic texture resource key behind diagnostics
---@param path string cache-relative staged payload path behind diagnostics
---@param payload table<string, unknown> staged typed texture payload under upload
---@return table<string, unknown>? owned image handle, nil on terminal failure
---@return string? terminal failure naming effect, resource, and path, nil on success
local function uploadEffectTexture(graphics, effectKey, resourceKey, path, payload)
  local function invalid(cause)
    return nil,
      "battle effect image "
        .. tostring(resourceKey)
        .. " failed for effect "
        .. tostring(effectKey)
        .. ": "
        .. tostring(path)
        .. ": "
        .. tostring(cause)
  end
  local width = type(payload) == "table" and payload.width or nil
  local height = type(payload) == "table" and payload.height or nil
  local rgba = type(payload) == "table" and payload.rgba8888 or nil
  if
    type(width) ~= "number"
    or width % 1 ~= 0
    or width < 1
    or type(height) ~= "number"
    or height % 1 ~= 0
    or height < 1
    or type(rgba) ~= "string"
    or #rgba ~= width * height * 4
  then
    return invalid("staged texture has no exact dimensions and bytes")
  end
  if graphics == nil then
    return invalid("no graphics namespace stages effect images")
  end
  local textureWidth = width --[[@as integer]]
  local textureHeight = height --[[@as integer]]
  local textureBytes = rgba --[[@as string]]
  local ok, imageOrErr = pcall(function()
    local pixels = love.image.newImageData(textureWidth, textureHeight)
    local at = 1
    for y = 0, textureHeight - 1 do
      for x = 0, textureWidth - 1 do
        local red, green, blue, alpha = string.byte(textureBytes, at, at + 3)
        assert(
          red ~= nil and green ~= nil and blue ~= nil and alpha ~= nil,
          "the staged texture bytes cover every pixel"
        )
        pixels:setPixel(x, y, red / 255, green / 255, blue / 255, alpha / 255)
        at = at + 4
      end
    end
    local uploaded = graphics.newImage(pixels)
    assert(uploaded ~= nil, "the graphics driver handed out no image")
    uploaded:setFilter("nearest", "nearest")
    return uploaded
  end)
  if ok and imageOrErr ~= nil then
    return imageOrErr
  end
  return invalid(ok and "empty image handle" or tostring(imageOrErr))
end

-- Uploads one staged portrait cell for a canonical portrait selector:
-- decode the owning atlas page, crop exactly the staged cell, then
-- build and configure the owned image. Success answers the owned
-- handle; a page the worker has not attested yet answers a legitimate
-- pending wait without touching the image driver; staged bytes that
-- fail decoding or GPU upload answer a terminal failure naming the
-- canonical selector and its page path.
---@param graphics table<string, unknown>? host graphics namespace captured by the preparation services
---@param envelope FieldBattlePresentation envelope carrying the versioned derived cache
---@param selector string canonical staged portrait selector
---@return table<string, unknown>? owned image handle, nil while pending or on terminal failure
---@return string? terminal failure naming the selector and page path, nil while pending or on success
local function uploadPortraitCell(graphics, envelope, selector)
  -- Graphics nil-checks live inside the upload pcall below: a headless
  -- envelope reports the same staged terminal failure instead of
  -- escaping as a host error, matching the pool-less production path.
  -- The namespace arrives from the services closure (construction-time),
  -- never the live envelope field the audio suite nils to force headless.
  local cacheFs = envelope._cacheFs
  local pagePath = nil
  local entry = nil
  do
    -- Only a worker-attested page decodes: an unstaged page waits for
    -- preparation instead of decoding missing bytes or standing in
    -- another image. Structural manifest problems still fail below.
    local portraits = stagedDoc(envelope, MonCache.portraitManifestPath())
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
    assert(graphics ~= nil, "portrait upload stages through its host graphics namespace")
    assert(type(graphics.newImage) == "function", "portrait upload needs host image construction")
    assert(type(entry) == "table", "the staged manifest plans no such portrait: " .. tostring(selector))
    assert(type(entry.pageId) == "number", "the staged portrait names its page: " .. tostring(selector))
    assert(type(entry.frames) == "table" and #entry.frames == 2, "the staged battle portrait names both Pokepic frames")
    local path = MonCache.pageImagePath("portraits", entry.pageId)
    pagePath = path
    local bytes = cacheFs:read(path)
    assert(type(bytes) == "string", "the staged portrait page is not staged: " .. tostring(path))
    local page = love.image.newImageData(love.filesystem.newFileData(bytes, path))
    local frames = {}
    for index, frame in ipairs(entry.frames) do
      local cropped = love.image.newImageData(frame.width, frame.height)
      cropped:paste(page, 0, 0, frame.x, frame.y, frame.width, frame.height)
      local uploaded = graphics.newImage(cropped)
      assert(uploaded ~= nil, "the graphics driver handed out no portrait frame image")
      uploaded:setFilter("nearest", "nearest")
      frames[index] = uploaded
    end
    return { frames = frames }
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

-- Borrows one staged portrait cell through the shared image owner:
-- the whole atlas page decodes on the worker and uploads once while
-- every battler on the page resolves its own frame cell pairing the
-- page lease with its frame quad. Quads need host quad construction;
-- callers pair at most one cell per staged frame. An unstaged page
-- waits without touching the pool; a failed decode or upload latches
-- the keyed terminal failure instead of hanging the cue.
---@param envelope FieldBattlePresentation envelope carrying the versioned derived cache
---@param graphics table<string, unknown> host graphics namespace captured by the preparation services
---@param key string drawable key behind diagnostics
---@param selector string canonical staged portrait selector
---@return table<string, unknown>? portrait cell handle, nil while pending or on terminal failure
---@return string? terminal failure naming the selector and page path, nil while pending or on success
local function borrowPortraitCell(envelope, graphics, key, selector)
  local pool = assert(envelope._pool, "pooled battler portraits borrow the shared image owner")
  assert(type(graphics.newQuad) == "function", "pooled battler portraits need host quad construction")
  local entry = nil
  local pagePath = nil
  local pageId = nil
  do
    -- Only a worker-attested page borrows: an unstaged page waits for
    -- preparation instead of decoding missing bytes or standing in
    -- another image. Structural manifest problems still fail below.
    local portraits = stagedDoc(envelope, MonCache.portraitManifestPath())
    if type(portraits) == "table" and type(portraits.entries) == "table" then
      entry = portraits.entries[selector]
    end
    pageId = type(entry) == "table" and entry.pageId or nil
    if type(pageId) == "number" and pageId % 1 == 0 and pageId >= 0 then
      if
        checkStagedPortraitPage(envelope._cacheFs, pageId --[[@as integer]]) ~= nil
      then
        return nil, nil
      end
      pagePath = MonCache.pageImagePath("portraits", pageId --[[@as integer]])
    end
  end
  assert(type(entry) == "table", "the staged manifest plans no such portrait: " .. tostring(selector))
  assert(type(entry.frames) == "table" and #entry.frames == 2, "the staged battle portrait names both Pokepic frames")
  assert(type(pagePath) == "string", "the staged portrait names its page: " .. tostring(selector))
  -- A pre-enrolled ticket rides when preparation staged one; a second
  -- battler on the same page enrolls its own borrow instead of
  -- starving behind the consumed ticket, exactly like whole-image
  -- borrows fall back to a fresh request.
  local token = takePendingUpload(envelope, pagePath)
  if token == nil then
    token = pool:request(pagePath, POOLED_SAMPLER, "demand")
  end
  local status, cause = pool:poll(token)
  if status == "failed" then
    return nil,
      "battle image mon:" .. tostring(selector) .. " " .. tostring(pagePath) .. " upload failed: " .. tostring(cause)
  end
  if status ~= "ready" then
    assert(status == "pending", "portrait preparation reports pending or ready")
    envelope._pendingUploads[pagePath] = token
    return nil, nil
  end
  local ok, leaseOrCause = pcall(pool.acquire, pool, token)
  if not ok then
    return nil,
      "battle image mon:" .. tostring(selector) .. " " .. tostring(pagePath) .. " upload failed: " .. tostring(
        leaseOrCause
      )
  end
  local lease = leaseOrCause
  assert(lease.image, "shared borrows carry their resolved image")
  local pageWidth, pageHeight = lease.width, lease.height
  assert(
    type(pageWidth) == "number" and type(pageHeight) == "number",
    "shared portrait pages carry their staged dimensions"
  )
  local frames = {}
  for index, frame in ipairs(entry.frames) do
    assert(type(frame.x) == "number" and type(frame.y) == "number", "the staged battle portrait frames its origin")
    assert(
      type(frame.width) == "number" and type(frame.height) == "number",
      "the staged battle portrait frames its size"
    )
    frames[index] = {
      image = lease.image,
      lease = lease,
      quad = graphics.newQuad(frame.x, frame.y, frame.width, frame.height, pageWidth, pageHeight),
      width = frame.width,
      height = frame.height,
      frameX = frame.x,
      frameY = frame.y,
      frameW = frame.width,
      frameH = frame.height,
    }
  end
  -- Battler portraits stay launch-owned: pages vary per battle while
  -- the shared owner keeps idle pages resident under its own budget,
  -- so no envelope pin grows without bound here.
  envelope._leases[key] = { lease = lease, handle = { frames = frames } }
  return envelope._leases[key].handle
end

-- Menu layout names inside drawable keys, by manifest menu section.
local MENU_LAYOUTS = { command = "command", moves = "moves", target = "target", twoOption = "two-option" }
local MENU_ORDER = { "command", "moves", "target", "twoOption" }
local MENU_SECTIONS = {} ---@type table<string, string> manifest menu section by drawable-key layout
for section, layout in pairs(MENU_LAYOUTS) do
  MENU_SECTIONS[layout] = section
end

-- Whole staged images behind fixed drawable keys, as member paths into
-- the verified manifest. Doubled health boxes resolve through the staged
-- doubled family by slot: each row owns its dedicated strip, never a
-- shared single-battle strip.
---@type table<string, (string|integer)[]>
local FIXED_ART = {
  ["shadow"] = { "pictures", "shadow", "image" },
  ["hud:enemy"] = { "hud", "enemy", "image" },
  ["hud:player"] = { "hud", "player", "image" },
  ["hud:player-left"] = { "hud", "doubles", "playerLeft", "image" },
  ["hud:player-right"] = { "hud", "doubles", "playerRight", "image" },
  ["hud:enemy-left"] = { "hud", "doubles", "enemyLeft", "image" },
  ["hud:enemy-right"] = { "hud", "doubles", "enemyRight", "image" },
  ["arrow"] = { "hud", "arrow", "image" },
  ["cursor"] = { "hud", "cursor", "image" },
  ["gauges:enemy"] = { "hud", "partyGauges", 1, "image" },
  ["gauges:player"] = { "hud", "partyGauges", 2, "image" },
  ["menu:command"] = { "menus", "command", "image" },
  ["menu:moves"] = { "menus", "moves", "image" },
  ["menu:target"] = { "menus", "target", "image" },
  ["menu:pulse-mask"] = { "menus", "lower", "pulseMask" },
}

---@param manifest FieldBattlePresentation.StagedManifest
---@param members (string|integer)[] schema-required member path ending at a staged image path
---@return string cache-relative staged image path
local function fixedArt(manifest, members)
  local value = manifest --[[@as table]]
  for _, member in ipairs(members) do
    value = value[member]
  end
  return value --[[@as string]]
end

---@param manifest FieldBattlePresentation.StagedManifest
---@param layout string menu layout named by a drawable key
---@return FieldBattlePresentation.MenuSection? staged menu section, nil for an unknown layout
local function menuSection(manifest, layout)
  local section = MENU_SECTIONS[layout]
  if section == nil then
    return nil
  end
  return manifest.menus[section] --[[@as FieldBattlePresentation.MenuSection]]
end

-- Screen keys name the active scene background after the screen index;
-- screens drawing the background-dependent lower palette stage one image
-- per background that changes their pixels, and touch feedback prefers its
-- own variant. Any other screen falls back to its base image.
---@param screen FieldBattlePresentation.MenuScreen
---@param suffix string drawable-key text after the screen index
---@return string? cache-relative staged image path, nil for a malformed suffix
local function screenArt(screen, suffix)
  if suffix == "" then
    return screen.image
  end
  local background = suffix:match("^@([%w_]+):touch$")
  if background ~= nil and screen.touchBackgrounds ~= nil and screen.touchBackgrounds[background] ~= nil then
    return screen.touchBackgrounds[background]
  end
  background = background or suffix:match("^@([%w_]+)$")
  if background == nil then
    return nil
  end
  return screen.backgrounds ~= nil and screen.backgrounds[background] or screen.image
end

-- Resolves one menu or HUD drawable key to its staged image path through
-- the verified manifest. Per-control artwork has no staged counterpart
-- and resolves to nothing so those controls draw labels only.
---@param manifest FieldBattlePresentation.StagedManifest
---@param key string drawable key under resolution
---@return string? cache-relative staged image path, nil without a staged counterpart
local function stagedArtPath(manifest, key)
  local fixed = FIXED_ART[key]
  if fixed ~= nil then
    return fixedArt(manifest, fixed)
  end
  -- Fight-menu move buttons: one render per slot and move type and state,
  -- plus the blank button of an empty slot.
  local slot, variant = key:match("^menu:moves:move%-button:(%d+):(.+)$")
  if slot ~= nil then
    local buttons = manifest.menus.moves.screens[1].moveButtons
    local button = buttons ~= nil and buttons[tonumber(slot) + 1] or nil
    if button == nil then
      return nil
    end
    if variant == "empty" then
      return button.empty
    end
    local typeKey, state = variant:match("^([a-z]+):([a-z]+)$")
    local states = typeKey ~= nil and button.types[typeKey] or nil
    return states ~= nil and states[state] or nil
  end
  local layout, screenIndex, suffix = key:match("^menu:([%a%-]+):screen:(%d+)(.*)$")
  if layout ~= nil then
    local section = menuSection(manifest, layout)
    local screen = section ~= nil and section.screens[tonumber(screenIndex)] or nil
    return screen ~= nil and screenArt(screen, suffix) or nil
  end
  local feedbackLayout, controlId, state = key:match("^menu:([%a%-]+):feedback:(.+):(%a+)$")
  if feedbackLayout ~= nil then
    local section = menuSection(manifest, feedbackLayout)
    local feedback = section ~= nil and section.screens[1].feedback or nil
    local patches = feedback ~= nil and feedback[controlId] or nil
    local patch = patches ~= nil and patches[state] or nil
    return patch ~= nil and patch.image or nil
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

local NOT_STAGED = "battle presentation is not staged: the launch needs its staged menu, HUD, font, and audio roles"

-- The ordinary interface roles a demand may name beside its chosen track.
local ORDINARY_AUDIO_ROLES = { "wild", "trainer", "rival", "select" }

-- Fixed drawables every graphical launch reaches for.
local REQUIRED_FIXED_ART = {
  "menu:command",
  "menu:moves",
  "menu:target",
  "hud:enemy",
  "hud:player",
  "cursor",
  "menu:pulse-mask",
  "hud:player-left",
  "hud:player-right",
  "hud:enemy-left",
  "hud:enemy-right",
}

-- Validates the demanded audio members against the staged manifest
-- roles: every demanded role must be one of the staged wild, trainer,
-- rival, or select symbols. Banks and cries ride the demand for
-- exactness; without the normalized audio membership in presentation
-- scope only their shape is checked here.
---@param manifest FieldBattlePresentation.StagedManifest
---@param musicRole string? launch's chosen battle-music symbol
---@param demand table<string, unknown> exact launch demand under validation
---@return string? reason, nil when the audio members validate
local function checkAudioMembers(manifest, musicRole, demand)
  local audio = demand.audio or { roles = {}, banks = {}, cries = {} }
  if type(audio) ~= "table" then
    return "battle demands carry their audio roles"
  end
  local stagedRoles = {}
  for _, role in ipairs(ORDINARY_AUDIO_ROLES) do
    stagedRoles[manifest.audioRoles[role]] = true
  end
  for _, symbol in pairs(BattleAudio.SINK_SOUNDS) do
    stagedRoles[symbol] = true
  end
  -- The launch's chosen battle-music track is legitimate by
  -- construction from the source selector beside the staged interface
  -- roles: special-species and class tracks name staged sequences
  -- outside the four ordinary roles.
  if type(musicRole) == "string" and musicRole ~= "" then
    stagedRoles[musicRole] = true
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
---@param cacheFs table<string, unknown> versioned derived cache behind demand validation
---@param manifest FieldBattlePresentation.StagedManifest
---@return string? reason, nil when the staged members validate
local function checkStagedMembers(cacheFs, manifest)
  local moveIcons = cacheFs:loadLua(MoveIconCache.manifestPath())
  if type(moveIcons) ~= "table" or moveIcons.schema ~= MoveIconCache.SCHEMA then
    return "battle move type icons are not staged"
  end
  local iconsOk, iconPaths = pcall(MoveIconCache.referencedPaths, moveIcons)
  if not iconsOk or type(iconPaths) ~= "table" then
    return "battle move type icons are not staged"
  end
  for _, path in ipairs(iconPaths) do
    local bytes = cacheFs:read(path)
    if type(bytes) ~= "string" or #bytes == 0 then
      return "battle move type icons are not staged"
    end
  end
  local required = {} ---@type { key: string, path: string? }[]
  local function need(key, path)
    required[#required + 1] = { key = key, path = path }
  end
  for _, key in ipairs(REQUIRED_FIXED_ART) do
    need(key, fixedArt(manifest, FIXED_ART[key]))
  end
  for _, sectionName in ipairs(MENU_ORDER) do
    local prefix = "menu:" .. MENU_LAYOUTS[sectionName]
    local section = manifest.menus[sectionName] --[[@as FieldBattlePresentation.MenuSection]]
    for index, screen in ipairs(section.screens) do
      local screenKey = prefix .. ":screen:" .. tostring(index)
      need(screenKey, screen.image)
      if screen.moveButtons ~= nil then
        for slotIndex, button in ipairs(screen.moveButtons) do
          local buttonKey = "menu:moves:move-button:" .. tostring(slotIndex - 1) .. ":"
          need(buttonKey .. "empty", button.empty)
          for typeKey, states in pairs(button.types) do
            for state, image in pairs(states) do
              need(buttonKey .. typeKey .. ":" .. state, image)
            end
          end
        end
      end
      if screen.backgrounds ~= nil then
        for background, image in pairs(screen.backgrounds) do
          need(screenKey .. "@" .. background, image)
        end
      end
      if screen.touchBackgrounds ~= nil then
        for background, image in pairs(screen.touchBackgrounds) do
          need(screenKey .. "@" .. background .. ":touch", image)
        end
      end
      -- Feedback patches validate through the same resolution the
      -- renderers draw with.
      if screen.feedback ~= nil then
        for controlId, states in pairs(screen.feedback) do
          for state in pairs(states) do
            local feedbackKey = prefix .. ":feedback:" .. controlId .. ":" .. state
            need(feedbackKey, stagedArtPath(manifest, feedbackKey))
          end
        end
      end
    end
  end
  for _, entry in ipairs(required) do
    local bytes = entry.path ~= nil and cacheFs:read(entry.path) or nil
    if type(bytes) ~= "string" or #bytes == 0 then
      return "battle menu art is not staged: " .. entry.key
    end
  end
  local textRoles = manifest.messages.roles
  for _, role in ipairs({ "narration", "menu", "hud" }) do
    local record = textRoles[role]
    if record == nil or type(cacheFs:read(record.font)) ~= "string" then
      return "battle font is not staged: " .. role
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
  local images = self._images --[[@as table<string, unknown>]]
  local moveIconManifest = nil
  local trainerPictureManifest = nil
  local battleBallManifest = nil
  local stagedSceneKey = nil
  local stagedSceneLayer = nil
  local backgroundPixels = nil
  local backgroundImage = nil
  local effectRefs = {} ---@type table<string, integer> outstanding texture leases by semantic resource key
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
        if not cacheFs:exists(BattlePresentationCache.sceneImagePath(sceneKey), "file") then
          if not scheduled then
            return nil,
              "battle scene image is not staged: " .. tostring(sceneKey) .. ": no scene demand host to schedule it"
          end
          return nil, "battle scene image is not staged: " .. tostring(sceneKey)
        end
        if stagedSceneKey ~= sceneKey then
          local previousSceneKey = stagedSceneKey
          local layer = record.layers[1]
          -- An idle-warmed exact scene reuses its staged BG3 source
          -- values instead of rereading them; anything else takes the
          -- original read path with its validation intact. The key match
          -- is never trusted alone: the staged values revalidate below.
          local warmStage = envelope._warmBg3
          local characters, map, palette ---@type string?, table?, table?
          if
            warmStage ~= nil
            and envelope._warmBg3Key == sceneKey
            and warmStage.sceneKey == sceneKey
            and type(warmStage.characters) == "string"
            and type(warmStage.map) == "table"
            and type(warmStage.palette) == "table"
          then
            characters = warmStage.characters --[[@as string]]
            map = warmStage.map --[[@as table]]
            palette = warmStage.palette --[[@as table]]
          else
            characters = cacheFs:read(layer.characters.path)
            map = cacheFs:loadLua(layer.map.path)
            palette = cacheFs:loadLua(layer.palette.path)
          end
          if type(characters) ~= "string" or type(map) ~= "table" or type(palette) ~= "table" then
            return nil, "battle scene BG3 payload is not staged: " .. tostring(sceneKey)
          end
          assert(layer.characters.format == "indexed8", "persistent BG3 uses the staged 8bpp character format")
          local intro = record.introLayer
          local sprites = record.terrainSprites
          for _, imagePath in ipairs({ intro.image, sprites.player.image, sprites.foe.image }) do
            if not cacheFs:exists(imagePath, "file") then
              return nil, "battle scene intro art is not staged: " .. tostring(sceneKey) .. ": " .. imagePath
            end
          end
          local introKey = "scene-intro:" .. sceneKey
          -- The warm pins this attempt did not create: a failed attempt
          -- below drops only pins it installed itself, so a pre-existing
          -- complete group survives while partial debris from the failure
          -- returns to the shared owner exactly once. A failed launch is
          -- never a valid successor, so its partial group must not linger
          -- as warm state.
          local warmBefore = {} ---@type table<string, boolean>
          for pinnedKey in pairs(envelope._warmPinned) do
            warmBefore[pinnedKey] = true
          end
          local introDrawable, introFailure = acquirePooled(envelope, introKey, intro.image)
          if introDrawable == nil then
            return nil, assert(introFailure, "scene intro lease failures carry a reason")
          end
          local playerKey = "scene-terrain:" .. sceneKey .. ":player"
          local playerDrawable, playerFailure = acquirePooled(envelope, playerKey, sprites.player.image)
          if playerDrawable == nil then
            -- A failed attempt returns its own partial pins to the shared
            -- owner: services.release forgets the launch lease but retains
            -- the pin by design, so an attempt-installed pin is dropped
            -- here before its borrow is returned. Pins the attempt only
            -- reused (already present above) stay warm.
            for _, key in ipairs({ introKey }) do
              services.release(key)
              local attemptPin = envelope._warmPinned[key]
              if attemptPin ~= nil and warmBefore[key] == nil then
                envelope._warmPinned[key] = nil
                if envelope._warmPaths ~= nil then
                  envelope._warmPaths[key] = nil
                end
                local attemptPool = envelope._pool
                if attemptPool ~= nil then
                  pcall(attemptPool.release, attemptPool, attemptPin.lease)
                end
              end
            end
            return nil, assert(playerFailure, "player terrain lease failures carry a reason")
          end
          local foeKey = "scene-terrain:" .. sceneKey .. ":foe"
          local foeDrawable, foeFailure = acquirePooled(envelope, foeKey, sprites.foe.image)
          if foeDrawable == nil then
            for _, key in ipairs({ introKey, playerKey }) do
              services.release(key)
              local attemptPin = envelope._warmPinned[key]
              if attemptPin ~= nil and warmBefore[key] == nil then
                envelope._warmPinned[key] = nil
                if envelope._warmPaths ~= nil then
                  envelope._warmPaths[key] = nil
                end
                local attemptPool = envelope._pool
                if attemptPool ~= nil then
                  pcall(attemptPool.release, attemptPool, attemptPin.lease)
                end
              end
            end
            return nil, assert(foeFailure, "foe terrain lease failures carry a reason")
          end
          stagedSceneKey = sceneKey
          stagedSceneLayer = {
            characters = characters,
            map = map,
            palette = palette,
            colorMode = "8bpp",
            introLayer = {
              drawable = introDrawable,
              width = intro.width,
              height = intro.height,
            },
            terrainSprites = {
              player = {
                drawable = playerDrawable,
                width = sprites.player.width,
                height = sprites.player.height,
                origin = { x = sprites.player.origin.x, y = sprites.player.origin.y },
              },
              foe = {
                drawable = foeDrawable,
                width = sprites.foe.width,
                height = sprites.foe.height,
                origin = { x = sprites.foe.origin.x, y = sprites.foe.origin.y },
              },
            },
          }
          if previousSceneKey ~= nil then
            for _, key in ipairs({
              "scene-intro:" .. previousSceneKey,
              "scene-terrain:" .. previousSceneKey .. ":player",
              "scene-terrain:" .. previousSceneKey .. ":foe",
            }) do
              services.release(key)
            end
          end
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
    -- Staged portrait pages decode while icons and audio still pend:
    -- the battler drawables take over each page ticket instead of
    -- decoding the shared atlas behind the remaining build.
    if envelope._pool ~= nil then
      local portraitsDoc = stagedDoc(envelope, MonCache.portraitManifestPath())
      local entries = type(portraitsDoc) == "table" and portraitsDoc.entries or nil
      if type(entries) == "table" then
        for _, selector in ipairs(demand.pages or {}) do
          local entry = entries[selector]
          local pageId = type(entry) == "table" and entry.pageId or nil
          if type(pageId) == "number" and pageId % 1 == 0 and pageId >= 0 then
            enrollUpload(envelope, MonCache.pageImagePath("portraits", pageId --[[@as integer]]))
          end
        end
      end
    end
    local trainerOk, trainerErr = checkTrainerPictures(envelope, demand.trainerPictures or {})
    if trainerOk == nil then
      return nil, trainerErr
    end
    if trainerOk == false then
      return false, nil
    end
    if #(demand.trainerPictures or {}) > 0 then
      local battleDoc = assert(
        stagedDoc(envelope, BattlePresentationCache.manifestPath()),
        "trainer picture demand needs its staged battle manifest"
      )
      trainerPictureManifest =
        assert(battleDoc.trainerPictures, "trainer picture demand needs its staged trainer pictures")
      -- Staged trainer art decodes while portraits and audio still
      -- pend: the drawable takes over each ticket instead of waiting
      -- behind the remaining build.
      for _, selector in ipairs(demand.trainerPictures or {}) do
        local entry = trainerPictureManifest.entries[selector]
        local animation = type(entry) == "table" and entry.animation or nil
        local sequences = type(animation) == "table" and animation.sequences or nil
        if type(sequences) == "table" then
          for _, sequence in ipairs(sequences) do
            for _, frame in ipairs(sequence.frames) do
              enrollUpload(envelope, frame.image)
            end
          end
        elseif type(entry) == "table" and type(entry.image) == "string" then
          enrollUpload(envelope, entry.image)
        end
      end
    end
    local battleBallsOk, battleBallsErr = checkBattleBalls(envelope, demand.battleBalls or {})
    if battleBallsOk == nil then
      return nil, battleBallsErr
    end
    if battleBallsOk == false then
      return false, nil
    end
    if #(demand.battleBalls or {}) > 0 then
      local battleDoc = assert(
        stagedDoc(envelope, BattlePresentationCache.manifestPath()),
        "battle ball demand needs its staged battle manifest"
      )
      battleBallManifest = assert(battleDoc.battleBalls, "battle ball demand needs its staged battle balls")
      -- Staged ball frames decode while the rest of the build still
      -- pends, like trainer art above.
      for _, selector in ipairs(demand.battleBalls or {}) do
        local entry = battleBallManifest.entries[selector]
        local frames = type(entry) == "table" and entry.frames or nil
        if type(frames) == "table" then
          for _, frame in ipairs(frames) do
            if type(frame) == "table" and type(frame.image) == "string" then
              enrollUpload(envelope, frame.image)
            end
          end
        end
      end
    end
    local iconKeys = demand.iconKeys or {}
    if envelope._monIconProvider ~= nil or #iconKeys > 0 then
      local icons = assert(envelope._monIconProvider, "battle icon demand borrows the field icon provider")
      local iconsReady, iconsFailure = icons:prepareKeys(iconKeys)
      if iconsFailure ~= nil then
        return nil, "battle command icon preparation failed: " .. tostring(iconsFailure)
      end
      if iconsReady ~= true then
        return false, nil
      end
    end
    -- Menu, HUD, font, and audio members are required only where
    -- pixels are actually required: headless composition keeps its
    -- descriptor behavior so recording views prove without staged art.
    if graphics ~= nil then
      local staged = stagedManifest(envelope._manifest)
      if staged == nil then
        return nil, NOT_STAGED
      end
      -- Membership validates once per envelope: staged files never
      -- un-stage under a live envelope, so repeat launches skip the
      -- full manifest and art reads the first launch already proved.
      -- A failure always re-checks instead of pinning a stale answer.
      if not envelope._stagedMembersOk then
        local stagedErr = checkStagedMembers(cacheFs, staged)
        if stagedErr ~= nil then
          return nil, stagedErr
        end
        envelope._stagedMembersOk = true
      end
      local audioErr = checkAudioMembers(staged, envelope._musicRole, demand)
      if audioErr ~= nil then
        return nil, audioErr
      end
      -- Fixed art decodes while the remaining launch-specific members
      -- still pend: every graphical launch draws these paths, so the
      -- first validation enrolls them once per launch and the drawables
      -- take over each ticket instead of serializing behind the build.
      for _, key in ipairs(REQUIRED_FIXED_ART) do
        local path = fixedArt(staged, FIXED_ART[key])
        if type(path) == "string" then
          enrollUpload(envelope, path)
        end
      end
    end
    return true
  end
  function services.sceneLayer()
    return stagedSceneLayer
  end
  function services.background(raster)
    assert(graphics ~= nil, "BG3 image upload requires host graphics")
    assert(type(raster) == "table", "BG3 upload takes a composed raster")
    if raster == backgroundPixels then
      return backgroundImage
    end
    local ok, uploadedOrError = pcall(function()
      local imageData = love.image.newImageData(raster.width, raster.height)
      for y = 0, raster.height - 1 do
        for x = 0, raster.width - 1 do
          local r, g, b, a = raster:pixel(x, y)
          imageData:setPixel(x, y, r / 255, g / 255, b / 255, a / 255)
        end
      end
      local uploaded = graphics.newImage(imageData)
      assert(uploaded ~= nil, "the graphics driver handed out no BG3 image")
      uploaded:setFilter("nearest", "nearest")
      return uploaded
    end)
    if not ok or uploadedOrError == nil then
      local cause = ok and "empty BG3 image handle" or tostring(uploadedOrError)
      return nil, "battle scene BG3 upload failed for " .. tostring(stagedSceneKey) .. ": " .. cause
    end
    if backgroundImage ~= nil and type(backgroundImage.release) == "function" then
      backgroundImage:release()
    end
    backgroundPixels = raster
    backgroundImage = uploadedOrError
    images["battle-background"] = backgroundImage
    return backgroundImage
  end
  function services.drawable(key)
    assert(type(key) == "string" and key ~= "", "image resolution names its key")
    local leases = envelope._leases --[[@as table<string, FieldBattlePresentation.PooledHandle>]]
    if leases[key] ~= nil then
      return leases[key].handle
    end
    if images[key] ~= nil then
      return images[key]
    end
    -- A pinned warm borrow answers without touching the shared owner:
    -- the envelope owns the borrow across launches, so the holder
    -- borrows it back without enrolling worker or GPU work. The pin
    -- stays envelope-owned and is never installed as a launch lease.
    local pinned = envelope._warmPinned[key]
    if pinned ~= nil then
      return pinned.handle
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
    local iconKey, frameIndexText = tostring(key):match("^battle:icon:(.+):frame:(%d+)$")
    if iconKey == nil then
      iconKey = tostring(key):match("^battle:icon:(.+)$")
    end
    if iconKey ~= nil then
      local icons = assert(envelope._monIconProvider, "battle command icons borrow the field icon provider")
      local dimensions = icons:dimensions(iconKey)
      local handle = icons:handleFor(iconKey)
      local frameIndex = frameIndexText ~= nil and tonumber(frameIndexText) or 1
      local quad = icons:quadFor(iconKey, frameIndex --[[@as integer]])
      local drawable = { width = dimensions.width, height = dimensions.height }
      function drawable:getDimensions()
        return self.width, self.height
      end
      function drawable:draw(drawGraphics, x, y, ...)
        return handle:drawQuad(drawGraphics, quad, x, y, ...)
      end
      function drawable:drawQuad(drawGraphics, _, x, y, ...)
        return handle:drawQuad(drawGraphics, quad, x, y, ...)
      end
      return drawable
    end
    -- Production drawables are real owned handles, legitimate waits, or
    -- terminal failures: staged bytes that fail decoding or GPU upload
    -- latch one keyed error instead of answering an unusable nil that
    -- the caller would poll forever. Unknown decorative keys stay
    -- legitimate nils with no error.
    local sceneKey = tostring(key):match("^scene:(.+)$")
    if sceneKey ~= nil then
      -- A scene key without staged naming resolves to nothing, like any
      -- unknown decorative key: path construction below asserts staged
      -- naming, and a probe or foreign key must poll instead of raising.
      if BattlePresentationCache.parseSceneKey(sceneKey) == nil then
        return nil
      end
      local path = BattlePresentationCache.sceneImagePath(sceneKey)
      -- Manifest-declared battle art borrows the shared owner when the
      -- host provides one; without a pool the envelope uploads and owns
      -- the staged bytes directly so pool-less production draws resolve.
      if envelope._pool ~= nil then
        -- A scene ticket enrolled at admission decodes while the required
        -- scene demand still stages: taking it over here avoids a second
        -- enrollment and the serial worker wait behind the build.
        local staged = envelope._pendingSceneImage
        local stagedToken = nil
        if staged ~= nil and staged.path == path then
          envelope._pendingSceneImage = nil
          stagedToken = staged.token
        end
        local image, failure = acquirePooled(envelope, key, path, stagedToken)
        if image == nil then
          assert(type(failure) == "string", "staged upload failures carry their reason")
          failures[key] = failure --[[@as string]]
          return nil, failure
        end
        return image
      end
      local bytes = cacheFs:read(path)
      if type(bytes) ~= "string" then
        return nil
      end
      local image, failure = uploadStaged(graphics, key, path, bytes)
      if image == nil then
        assert(type(failure) == "string", "staged upload failures carry their reason")
        failures[key] = failure --[[@as string]]
        return nil, failure
      end
      images[key] = image
      return image
    end
    local typeKey = key:match("^battle:move%-type%-icon:([a-z%-]+)$")
    if typeKey ~= nil then
      if moveIconManifest == nil then
        moveIconManifest = MoveIconCache.loadManifest(cacheFs)
      end
      local types = moveIconManifest.types --[[@as table<string, table<string, unknown>>]]
      local visual = types[typeKey]
      if type(visual) ~= "table" then
        return nil
      end
      local artPath = assert(visual.image, "the generated move type icon names its staged image") --[[@as string]]
      local handle = nil
      if envelope._pool ~= nil then
        local failure
        handle, failure = acquirePooled(envelope, key, artPath)
        if handle == nil then
          assert(type(failure) == "string", "staged upload failures carry their reason")
          failures[key] = failure
          return nil, failure
        end
      else
        local bytes = cacheFs:read(artPath)
        if type(bytes) ~= "string" then
          return nil
        end
        local failure
        handle, failure = uploadStaged(graphics, key, artPath, bytes)
        if handle == nil then
          assert(type(failure) == "string", "staged upload failures carry their reason")
          failures[key] = failure
          return nil, failure
        end
        images[key] = handle
      end
      local drawable = {
        lease = handle,
        width = assert(visual.width, "generated move type icon carries its width"),
        height = assert(visual.height, "generated move type icon carries its height"),
        offset = visual.offset,
      }
      function drawable:getDimensions()
        return self.width, self.height
      end
      function drawable:draw(drawGraphics, x, y, ...)
        if type(self.lease.draw) == "function" then
          return self.lease:draw(drawGraphics, x, y, ...)
        end
        return drawGraphics.draw(self.lease, x, y, ...)
      end
      function drawable:drawQuad(drawGraphics, quad, x, y, ...)
        if type(self.lease.drawQuad) == "function" then
          return self.lease:drawQuad(drawGraphics, quad, x, y, ...)
        end
        return drawGraphics.draw(self.lease, quad, x, y, ...)
      end
      if envelope._pool ~= nil then
        leases[key].handle = drawable
      else
        images[key] = drawable
      end
      return drawable
    end
    local staged = stagedManifest(envelope._manifest)
    local artPath = staged ~= nil and stagedArtPath(staged, key) or nil
    if artPath ~= nil then
      if envelope._pool ~= nil then
        local image, failure = acquirePooled(envelope, key, artPath)
        if image == nil then
          assert(type(failure) == "string", "staged upload failures carry their reason")
          failures[key] = failure --[[@as string]]
          return nil, failure
        end
        return image
      end
      local bytes = cacheFs:read(artPath)
      if type(bytes) ~= "string" then
        return nil
      end
      local image, failure = uploadStaged(graphics, key, artPath, bytes)
      if image == nil then
        assert(type(failure) == "string", "staged upload failures carry their reason")
        failures[key] = failure --[[@as string]]
        return nil, failure
      end
      images[key] = image
      return image
    end
    local selector = exactPortraitSelector(key)
    if selector ~= nil then
      -- A shared owner borrows the whole atlas page once per envelope
      -- while every battler on the page resolves its own frame cell:
      -- worker decode and GPU upload leave the game thread, and the
      -- drawables draw through the page lease plus their frame quad.
      -- Without a pool the envelope still crops and owns its cells
      -- directly, so pool-less production draws resolve.
      if envelope._pool ~= nil then
        local handle, failure = borrowPortraitCell(envelope, graphics, key, selector)
        if handle == nil then
          if failure == nil then
            return nil
          end
          failures[key] = failure --[[@as string]]
          return nil, failure
        end
        return handle
      end
      local cell, failure = uploadPortraitCell(graphics, envelope, selector)
      if cell == nil then
        if failure == nil then
          return nil
        end
        failures[key] = failure --[[@as string]]
        return nil, failure
      end
      images[key] = cell
      return cell
    end
    local trainerRole, classKey, sequenceText, frameText =
      key:match("^trainer:(front):([%w_]+):sequence:(%d+):frame:(%d+)$")
    if trainerRole == nil then
      trainerRole, classKey, sequenceText, frameText = key:match("^trainer:(back):([%w_]+):sequence:(%d+):frame:(%d+)$")
    end
    if trainerRole == nil then
      trainerRole, classKey, frameText = key:match("^trainer:(front):([%w_]+):frame:(%d+)$")
    end
    if trainerRole == nil then
      trainerRole, classKey, frameText = key:match("^trainer:(back):([%w_]+):frame:(%d+)$")
    end
    if trainerRole == nil then
      trainerRole, classKey = key:match("^trainer:(front):([%w_]+)$")
    end
    if trainerRole == nil then
      trainerRole, classKey = key:match("^trainer:(back):([%w_]+)$")
    end
    if trainerRole ~= nil and classKey ~= nil and trainerPictureManifest ~= nil then
      local selectorKey = trainerRole .. ":" .. classKey
      local entry = trainerPictureManifest.entries[selectorKey]
      if type(entry) ~= "table" then
        return nil
      end
      local path = entry.image --[[@as string]]
      if sequenceText ~= nil then
        local sourceSequence = assert(tonumber(sequenceText), "trainer drawable names an integer source sequence")
        local sourceFrame = assert(tonumber(frameText), "trainer drawable names an integer source frame")
        local sequences = type(entry.animation) == "table" and entry.animation.sequences or nil
        local sequence = type(sequences) == "table" and sequences[sourceSequence + 1] or nil
        local frames = type(sequence) == "table" and sequence.frames or nil
        local frame = type(frames) == "table" and frames[sourceFrame + 1] or nil
        if
          type(sequence) ~= "table"
          or sequence.sourceSequence ~= sourceSequence
          or type(frame) ~= "table"
          or frame.sourceFrame ~= sourceFrame
          or frame.drawableKey ~= key
        then
          return nil
        end
        path = frame.image
      elseif frameText ~= nil then
        local sourceFrame = assert(tonumber(frameText), "trainer drawable names an integer source frame")
        local frames = type(entry.animation) == "table" and entry.animation.frames or nil
        local frame = type(frames) == "table" and frames[sourceFrame + 1] or nil
        if type(frame) ~= "table" or frame.sourceFrame ~= sourceFrame or frame.drawableKey ~= key then
          return nil
        end
        path = frame.image
      end
      local image = nil
      local failure = nil
      if envelope._pool ~= nil then
        image, failure = acquirePooled(envelope, key, path)
      else
        local bytes = cacheFs:read(path)
        if type(bytes) == "string" then
          image, failure = uploadStaged(graphics, key, path, bytes)
        end
      end
      if image == nil then
        if failure ~= nil then
          failures[key] = failure
        end
        return nil, failure
      end
      images[key] = image
      return image
    end
    local ballKey, ballFrameText = key:match("^battle%-ball:([%w_]+):(%d+)$")
    if ballKey ~= nil and battleBallManifest ~= nil then
      local selectorKey = "ball:" .. ballKey
      local entry = battleBallManifest.entries[selectorKey]
      local frames = type(entry) == "table" and entry.frames or nil
      local frameIndex = assert(tonumber(ballFrameText), "battle ball drawable names a numeric frame") + 1
      local frame = type(frames) == "table" and frames[frameIndex] or nil
      if type(frame) ~= "table" or frame.drawableKey ~= key then
        return nil
      end
      local path = frame.image --[[@as string]]
      local image = nil
      local failure = nil
      if envelope._pool ~= nil then
        image, failure = acquirePooled(envelope, key, path)
      else
        local bytes = cacheFs:read(path)
        if type(bytes) == "string" then
          image, failure = uploadStaged(graphics, key, path, bytes)
        end
      end
      if image == nil then
        if failure ~= nil then
          failures[key] = failure
        end
        return nil, failure
      end
      images[key] = image
      return image
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
      -- A pinned warm borrow stays envelope-owned across launches:
      -- the launch forgets it here without returning it, so the next
      -- launch reuses the same borrow instead of re-enrolling.
      if envelope._warmPinned[key] == nil then
        local pool = assert(envelope._pool, "pooled battle borrows return to the shared image owner")
        pool:release(pooled.lease)
      end
    end
    if key == "battle-background" and backgroundImage ~= nil and type(backgroundImage.release) == "function" then
      backgroundImage:release()
      backgroundImage = nil
      backgroundPixels = nil
    end
    images[key] = nil
  end
  -- Demands one lazily staged battle effect through the borrowed
  -- selected-game host at the current generation: the exact flat key is
  -- requested, then the staged record, marker, and full dependency
  -- closure must validate before readiness. Pending stays a bare false
  -- wait; worker, schema, and key-mismatch failures are terminal with
  -- the effect key and cause. Nothing compiles or parses source here.
  function services.requestEffect(key)
    if type(key) ~= "string" or key == "" or key:find("/", 1, true) ~= nil then
      return nil, "unknown battle effect key: " .. tostring(key)
    end
    if envelope._disposed then
      return nil, "battle effect " .. key .. " is not staged: the presented battle envelope is disposed"
    end
    local host = envelope._derivedAssets
    local requestBattleEffect = type(host) == "table" and host.requestBattleEffect or nil
    if type(requestBattleEffect) == "function" then
      local ready, failure = requestBattleEffect(key, "required")
      if failure ~= nil then
        return nil, "battle effect " .. key .. " failed: " .. tostring(failure)
      end
      if ready ~= true then
        return false
      end
    end
    if cacheFs:loadLua(BattlePresentationCache.effectPath(key)) == nil then
      return false
    end
    local record, recordErr = BattlePresentationCache.loadEffect(cacheFs, key)
    if record == nil then
      return nil, tostring(recordErr or ("battle effect " .. key .. " is not staged"))
    end
    if not BattlePresentationCache.isEffectReady(cacheFs, { key = key, resources = record.dependencies }) then
      return false
    end
    return true
  end
  -- Loads the exact staged effect record once ready: schema and key
  -- identity validate through the shared cache loader. A missing
  -- record never fabricates a fallback effect.
  function services.loadEffect(key)
    if type(key) ~= "string" or key == "" or key:find("/", 1, true) ~= nil then
      return nil, "unknown battle effect key: " .. tostring(key)
    end
    if envelope._disposed then
      return nil, "battle effect " .. key .. " is not staged: the presented battle envelope is disposed"
    end
    return BattlePresentationCache.loadEffect(cacheFs, key)
  end
  -- Resolves one dependency of a loaded effect into a semantic lease.
  -- Texture descriptors validate exact dimensions and bytes, upload
  -- once through the host graphics namespace, and share the one owned
  -- image across duplicate resolves; other kinds arrive as immutable
  -- decoded records beside their staged path, never the path alone.
  -- Malformed payloads and driver failures are terminal naming effect,
  -- resource, and path; nothing is cached on failure so a retry never
  -- observes a half upload.
  function services.resolveEffectResource(effect, resourceKey)
    if envelope._disposed then
      return nil, "battle effect resources are released: the presented battle envelope is disposed"
    end
    if type(effect) ~= "table" or type(effect.key) ~= "string" or effect.key == "" then
      return nil, "effect leases resolve from a loaded effect"
    end
    local effectKey = effect.key --[[@as string]]
    if type(resourceKey) ~= "string" or resourceKey == "" then
      return nil, "unknown battle effect resource " .. tostring(resourceKey) .. " for effect " .. effectKey
    end
    local resources = effect.resources
    local descriptor = type(resources) == "table" and resources[resourceKey] or nil
    if type(descriptor) ~= "table" then
      return nil, "unknown battle effect resource " .. tostring(resourceKey) .. " for effect " .. effectKey
    end
    if descriptor.kind ~= "texture" then
      if type(descriptor.payload) ~= "string" or not cacheFs:exists(descriptor.payload, "file") then
        return nil, "battle effect resource " .. tostring(resourceKey) .. " is not staged for effect " .. effectKey
      end
      -- Non-texture payloads decode here, once per resolve: tasks only
      -- ever read the decoded record and must never mistake the staged
      -- path for data. The decoded table is borrowed immutable.
      local data = cacheFs:loadLua(descriptor.payload)
      if type(data) ~= "table" then
        return nil,
          "battle effect resource " .. tostring(resourceKey) .. " failed for effect " .. effectKey .. ": " .. tostring(
            descriptor.payload
          ) .. ": staged payload is not a normalized record"
      end
      return {
        key = resourceKey,
        kind = descriptor.kind,
        payloadPath = descriptor.payload,
        contentIdentity = descriptor.contentIdentity,
        data = data,
      }
    end
    local payload = cacheFs:loadLua(descriptor.payload)
    if type(payload) ~= "table" then
      return nil,
        "battle effect image " .. tostring(resourceKey) .. " failed for effect " .. effectKey .. ": " .. tostring(
          descriptor.payload
        ) .. ": staged texture is not staged"
    end
    -- Without a graphics namespace there is no GPU to upload through:
    -- the validated staged payload still answers a handle-less descriptor
    -- lease (like every non-texture kind), so headless presentation can
    -- complete its audio and timing contract without inventing pixels.
    local image = images[resourceKey]
    if image == nil and graphics ~= nil then
      local uploaded, failure = uploadEffectTexture(
        graphics,
        effectKey,
        resourceKey,
        descriptor.payload,
        payload --[[@as table<string, unknown>]]
      )
      if uploaded == nil then
        assert(type(failure) == "string", "effect upload failures carry their reason")
        return nil, failure
      end
      image = uploaded
      images[resourceKey] = image
    end
    effectRefs[resourceKey] = (effectRefs[resourceKey] or 0) + 1
    local staged = payload --[[@as table<string, unknown>]]
    return {
      key = resourceKey,
      kind = "texture",
      width = staged.width,
      height = staged.height,
      rgba8888 = staged.rgba8888,
      payload = descriptor.payload,
      contentIdentity = descriptor.contentIdentity,
      handle = image,
    }
  end
  -- Returns one effect lease: texture refcounts drop the shared image
  -- at the last release, other kinds validate only. A release the
  -- holder already returned reports its double release instead of
  -- freeing a foreign handle.
  function services.releaseEffectResource(lease)
    if type(lease) ~= "table" or type(lease.key) ~= "string" or lease.key == "" then
      return nil, "effect releases name their lease"
    end
    local resourceKey = lease.key --[[@as string]]
    if lease.kind ~= nil and lease.kind ~= "texture" then
      return true
    end
    local left = (effectRefs[resourceKey] or 0) - 1
    if left < 0 then
      return nil, "effect lease " .. resourceKey .. " is already released"
    end
    effectRefs[resourceKey] = left
    if left == 0 then
      images[resourceKey] = nil
    end
    return true
  end
  return services
end

---@return table<integer, table<string, unknown>> exact launch demands requested, in order
function FieldBattlePresentation:preparedDemands()
  return self._preparedDemands
end

-- Advances idle speculation for one predicted scene without blocking the
-- field: near-urgency semantic demand, bounded prefetch tickets, and at
-- most one pool adoption per granted GPU allowance. Answers whether this
-- call consumed the one shared idle realization, plus an attributable
-- failure naming scene, key, and path. Settles quietly when prerequisites
-- are missing or the group reads fully warm; never raises into the field
-- update. Never enrolls synchronous borrows: tickets request and poll
-- explicitly, and adoption publishes the canonical warm-pin record.
---@param sceneKey string predicted scene key under warming
---@param gpuAllowance integer 1 when the shared idle slot is still free, 0 otherwise
---@return boolean usedGpu true once a ready image pair was adopted
---@return string? failure attributable idle diagnostic, nil when quiet
function FieldBattlePresentation:advanceWarmup(sceneKey, gpuAllowance)
  local ok, used, failure = pcall(FieldBattlePresentation._advanceWarmupInner, self, sceneKey, gpuAllowance)
  if ok then
    if failure ~= nil then
      self._warmFailure = failure
    end
    return used == true, failure
  end
  local cause = "battle warmup " .. tostring(sceneKey) .. " failed: " .. tostring(used)
  self._warmFailure = cause
  return false, cause
end

---@param sceneKey string predicted scene key under warming
---@param gpuAllowance integer shared idle realization allowance
---@return boolean usedGpu
---@return string? failure
function FieldBattlePresentation._advanceWarmupInner(self, sceneKey, gpuAllowance)
  if self._disposed then
    return false, nil
  end
  if self._launchId ~= nil then
    return false, nil
  end
  local pool = self._pool
  if self._graphics == nil or pool == nil then
    return false, nil
  end
  if type(sceneKey) ~= "string" or BattlePresentationCache.parseSceneKey(sceneKey) == nil then
    return false, nil
  end
  local host = self._derivedAssets
  if type(host) ~= "table" then
    return false, nil
  end
  local requestPresentation = host.requestBattlePresentation
  local requestScene = host.requestBattleScene
  if type(requestPresentation) ~= "function" or type(requestScene) ~= "function" then
    return false, nil
  end
  local allowance = (type(gpuAllowance) == "number" and gpuAllowance >= 1) and 1 or 0
  if self._warmTickets == nil then
    self._warmTickets = {}
  end
  if self._warmPaths == nil then
    self._warmPaths = {}
  end
  if self._warmDesired ~= sceneKey then
    cancelWarmTickets(self)
    self._warmDesired = sceneKey
    self._warmFailed = {}
  end
  if self._warmFailed == nil then
    self._warmFailed = {}
  end
  -- Semantic demand stays below the foreground: near compilation only,
  -- and a pending source waits without touching missing files.
  local okPresentation, readyPresentation, failurePresentation = pcall(requestPresentation, "near")
  if not okPresentation then
    return false, "battle warmup " .. sceneKey .. " presentation demand failed: " .. tostring(readyPresentation)
  end
  if failurePresentation ~= nil then
    return false, "battle warmup " .. sceneKey .. " presentation demand failed: " .. tostring(failurePresentation)
  end
  if readyPresentation ~= true then
    return false, nil
  end
  local okScene, readyScene, failureScene = pcall(requestScene, sceneKey, "near")
  if not okScene then
    return false, "battle warmup " .. sceneKey .. " scene demand failed: " .. tostring(readyScene)
  end
  if failureScene ~= nil then
    return false, "battle warmup " .. sceneKey .. " scene demand failed: " .. tostring(failureScene)
  end
  if readyScene ~= true then
    return false, nil
  end
  -- The scene record resolves first and its group enrolls before the
  -- slower global validation below: the worker decodes the priority
  -- scene image while the field validates the shared manifest.
  local record, recordErr = BattlePresentationCache.loadScene(self._cacheFs, sceneKey)
  if record == nil then
    return false, "battle warmup " .. sceneKey .. " scene is not staged: " .. tostring(recordErr)
  end
  local introLayer = record.introLayer
  local terrainSprites = record.terrainSprites
  if type(introLayer) ~= "table" or type(introLayer.image) ~= "string" or introLayer.image == "" then
    return false, "battle warmup " .. sceneKey .. " scene has no staged intro art"
  end
  if
    type(terrainSprites) ~= "table"
    or type(terrainSprites.player) ~= "table"
    or type(terrainSprites.player.image) ~= "string"
    or terrainSprites.player.image == ""
    or type(terrainSprites.foe) ~= "table"
    or type(terrainSprites.foe.image) ~= "string"
    or terrainSprites.foe.image == ""
  then
    return false, "battle warmup " .. sceneKey .. " scene has no staged terrain art"
  end
  local grouped = {} ---@type { key: string, path: string }[]
  local groupKeys = warmSceneKeys(sceneKey)
  grouped[#grouped + 1] = { key = groupKeys[1], path = BattlePresentationCache.sceneImagePath(sceneKey) }
  grouped[#grouped + 1] = { key = groupKeys[2], path = introLayer.image }
  grouped[#grouped + 1] = { key = groupKeys[3], path = terrainSprites.player.image }
  grouped[#grouped + 1] = { key = groupKeys[4], path = terrainSprites.foe.image }
  local ticketed = {} ---@type table<string, boolean>
  for _, ticket in ipairs(self._warmTickets) do
    ticketed[ticket.key] = true
  end
  enrollWarmEntries(self, pool, grouped, ticketed)
  -- A ready global refreshes the envelope manifest the same way the
  -- pending build does; an unvalidated answer keeps the current one.
  local refreshed = loadManifest(self._cacheFs)
  if stagedManifest(refreshed) ~= nil then
    self._manifest = refreshed
  end
  local staged = stagedManifest(self._manifest)
  if staged == nil then
    return false, nil
  end
  local ordered = {} ---@type { key: string, path: string }[]
  for _, entry in ipairs(grouped) do
    ordered[#ordered + 1] = entry
  end
  local fixedKeys = {} ---@type string[]
  for fixedKey in pairs(WARM_PINNED_KEYS) do
    fixedKeys[#fixedKeys + 1] = fixedKey
  end
  table.sort(fixedKeys)
  for _, fixedKey in ipairs(fixedKeys) do
    local artPath = stagedArtPath(staged, fixedKey)
    if type(artPath) ~= "string" or artPath == "" then
      return false, "battle warmup " .. sceneKey .. " fixed art is not staged: " .. fixedKey
    end
    ordered[#ordered + 1] = { key = fixedKey, path = artPath }
  end
  -- The BG3 source values stage once per predicted scene as pure cache
  -- reads under any allowance; a pending replacement keeps the preceding
  -- usable record until its own successor stages.
  if self._warmBg3Key ~= sceneKey then
    local layers = record.layers
    local layer = type(layers) == "table" and layers[1] or nil
    local charactersEntry = type(layer) == "table" and layer.characters or nil
    local mapEntry = type(layer) == "table" and layer.map or nil
    local paletteEntry = type(layer) == "table" and layer.palette or nil
    if type(charactersEntry) ~= "table" or type(mapEntry) ~= "table" or type(paletteEntry) ~= "table" then
      return false, "battle warmup " .. sceneKey .. " BG3 source paths are not staged"
    end
    if charactersEntry.format ~= "indexed8" then
      return false, "battle warmup " .. sceneKey .. " BG3 keeps the staged 8bpp character format"
    end
    local charactersPath = charactersEntry.path
    local mapPath = mapEntry.path
    local palettePath = paletteEntry.path
    if type(charactersPath) ~= "string" or type(mapPath) ~= "string" or type(palettePath) ~= "string" then
      return false, "battle warmup " .. sceneKey .. " BG3 source paths are not staged"
    end
    local characters = self._cacheFs:read(charactersPath)
    local map = self._cacheFs:loadLua(mapPath)
    local palette = self._cacheFs:loadLua(palettePath)
    if type(characters) ~= "string" or type(map) ~= "table" or type(palette) ~= "table" then
      return false, "battle warmup " .. sceneKey .. " BG3 payload is not staged"
    end
    self._warmBg3 = { sceneKey = sceneKey, characters = characters, map = map, palette = palette }
    self._warmBg3Key = sceneKey
  end
  -- A fully warm group settles without touching the hosts again.
  local settled = self._warmBg3Key == sceneKey
  if settled then
    for _, entry in ipairs(ordered) do
      if self._warmPinned[entry.key] == nil or self._warmPaths[entry.key] ~= entry.path then
        settled = false
        break
      end
    end
  end
  if settled then
    return false, nil
  end
  enrollWarmEntries(self, pool, ordered, ticketed)
  -- Poll every ticket without blocking; the first failure names its
  -- scene, key, and path while the remaining tickets stay pending.
  local readyTicket = nil ---@type { key: string, path: string, token: integer }?
  local index = 1
  while index <= #self._warmTickets do
    local ticket = self._warmTickets[index]
    local okPoll, status, cause = pcall(pool.poll, pool, ticket.token)
    if okPoll and status == "ready" then
      if readyTicket == nil then
        readyTicket = ticket
      end
      index = index + 1
    elseif okPoll and status == "pending" then
      index = index + 1
    else
      table.remove(self._warmTickets, index)
      local reason = okPoll and tostring(cause) or tostring(status)
      self._warmFailed[ticket.path] = reason
      return false,
        "battle warmup " .. sceneKey .. " image " .. ticket.key .. " upload failed: " .. ticket.path .. ": " .. reason
    end
  end
  if allowance < 1 or readyTicket == nil then
    return false, nil
  end
  -- One pool adoption per granted allowance: the source and palette
  -- pair behind the ticket counts as the single operation.
  local ticketKey, ticketPath, ticketToken = readyTicket.key, readyTicket.path, readyTicket.token
  local okAcquire, lease = pcall(pool.acquire, pool, ticketToken)
  for position, ticket in ipairs(self._warmTickets) do
    if ticket.token == ticketToken then
      table.remove(self._warmTickets, position)
      break
    end
  end
  if not okAcquire or type(lease) ~= "table" or lease.image == nil then
    local reason = okAcquire and "empty image lease" or tostring(lease)
    self._warmFailed[ticketPath] = reason
    return false,
      "battle warmup " .. sceneKey .. " image " .. ticketKey .. " upload failed: " .. ticketPath .. ": " .. reason
  end
  self._warmPinned[ticketKey] = { lease = lease, handle = lease }
  self._warmPaths[ticketKey] = ticketPath
  if warmGroupComplete(self, sceneKey) then
    retireWarmGroups(self, sceneKey)
  end
  return true, nil
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
---@return table<string, unknown>? fresh five-operation port behind the launch, nil once the build fails loudly
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
  self._enrolledUploads = {}
  assert(next(self._pendingUploads) == nil, "a launch never inherits pre-enrolled upload tickets")
  self._pendingBuild = false
  self._portDisposed = false
  self._screen = nil
  self._innerPort = nil
  self._lastStatus = nil
  self._cover = 0
  self._accumulator = 0
  self._revealingBattle = false
  self._musicStarted = false
  self._musicNote = nil
  self._musicRole = descriptor.musicRole
  self._resultMusicPlayed = false
  self._transition = nil
  self._transitionCapture = nil
  self._transitionFailed = false
  self:_startTransition(descriptor)
  -- Enroll the scene image on the shared owner while the transition
  -- and the required scene demand still run: the worker decodes
  -- concurrently instead of serializing behind the build, and the
  -- drawable takes over this ticket instead of requesting again. No
  -- draw happens here; the ticket is cancelled with the launch when the
  -- build never needs it.
  -- An accepted launch preempts speculation: pending warm tickets
  -- cancel while adopted warm pins stay for exact-key reuse.
  cancelWarmTickets(self)
  assert(self._pendingSceneImage == nil, "a launch never inherits a staged scene ticket")
  local pool = self._pool
  if pool ~= nil then
    local imagePath = BattlePresentationCache.sceneImagePath(sceneKey)
    self._pendingSceneImage = { path = imagePath, token = pool:request(imagePath, POOLED_SAMPLER, "demand") }
  end
  local derived = self._derivedAssets
  local scheduled = self._graphics ~= nil
    and type(derived) == "table"
    and type(derived.requestBattleScene) == "function"
  if not scheduled then
    -- A directly built screen can still fail against an unstaged
    -- manifest: like the deferred completion below, the first failure
    -- reports once with its launch context instead of escaping as a
    -- host error, and admission hands back no port.
    local okBuild, constructed = pcall(function()
      return self:_buildPort(descriptor)
    end)
    if not okBuild then
      self:_failPendingLaunch("battle scene " .. tostring(sceneKey) .. ": " .. tostring(constructed))
      return nil
    end
    self._port = constructed
    return constructed
  end
  self._pendingBuild = true
  local launchId = descriptor.launchId --[[@as string]]
  -- The scheduled port moves pending -> live -> disposed, with build
  -- failure latched separately in _pendingFailed. Disposal releases only
  -- screen-owned resources: the descriptor, cover, and host stay with
  -- the envelope until the host settles or tears down, so the return
  -- driver survives terminal disposal. Stale or disposed ports forward
  -- nothing and schedule nothing.
  local facade = {}
  local notified = false
  local function owned()
    if self._portDisposed then
      return nil
    end
    if self._launchId ~= launchId or self._descriptor == nil then
      return nil
    end
    return self._innerPort
  end
  -- Reports one port-operation failure with its launch and operation
  -- context instead of silently degrading to not-ready. The first
  -- report wins; the coordinator collapses any later screen report for
  -- the same launch the same way, so the original cause survives.
  local function reportOpFailure(op, err)
    if notified then
      return
    end
    notified = true
    local cause = op .. " failed for launch " .. tostring(launchId) .. ": " .. tostring(err)
    local host = descriptor.host --[[@as table<string, unknown>]]
    if host ~= nil and type(host.notify) == "function" then
      local _, _ = pcall(host.notify, "screen-failed", cause)
    end
  end
  function facade.enter(plan)
    local inner = owned()
    if inner == nil then
      return false
    end
    local ok, acknowledged = pcall(inner.enter, plan)
    if not ok then
      reportOpFailure("enter", acknowledged)
      return false
    end
    return acknowledged == true
  end
  function facade.present(packet)
    local inner = owned()
    if inner == nil then
      return
    end
    local ok, err = pcall(inner.present, packet)
    if not ok then
      reportOpFailure("present", err)
    end
  end
  function facade.ready()
    local inner = owned()
    if inner == nil then
      return false
    end
    local ok, interactive = pcall(inner.ready)
    if not ok then
      reportOpFailure("ready", interactive)
      return false
    end
    return interactive == true
  end
  function facade.leave(plan)
    local inner = owned()
    if inner == nil then
      return false
    end
    local ok, acknowledged = pcall(inner.leave, plan)
    if not ok then
      reportOpFailure("leave", acknowledged)
      return false
    end
    return acknowledged == true
  end
  function facade.openCompletion(intent)
    local inner = owned()
    if inner == nil then
      return false
    end
    local ok, accepted = pcall(inner.openCompletion, intent)
    if not ok then
      reportOpFailure("openCompletion", accepted)
      return false
    end
    return accepted == true
  end
  function facade.takeCompletion()
    local inner = owned()
    if inner == nil then
      return nil
    end
    local ok, result = pcall(inner.takeCompletion)
    if not ok then
      reportOpFailure("takeCompletion", result)
      return nil
    end
    return result
  end
  function facade.dispose()
    if self._launchId ~= launchId then
      return
    end
    if self._portDisposed then
      return
    end
    -- A pending disposal cancels its screen build while a live disposal
    -- releases the live screen once; both retain the outer descriptor,
    -- cover, and host for the continuing return. The outer launch is
    -- forgotten only when the host settles or the envelope tears down.
    self._portDisposed = true
    self._pendingBuild = false
    local screen = self._screen
    self._screen = nil
    self._innerPort = nil
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
  -- A disposed or settled port never publishes: disposal cancels the
  -- pending build and terminal teardown already released the screen, so
  -- a late worker answer builds nothing for either.
  if self._portDisposed then
    return
  end
  if self._screen ~= nil or self._innerPort ~= nil then
    return
  end
  if self._pendingFailed or not self._pendingBuild then
    return
  end
  -- The host settlement is observed before any build, exactly as the
  -- cover step observes it before any advance: a worker answer that
  -- arrives after the host settled or tore down builds no screen for
  -- the dead launch, and the launch drains here instead of lingering
  -- until the next accepted tick.
  local host = descriptor.host
  if host == nil then
    self:_dropLaunch()
    return
  end
  if type(host.status) == "function" then
    local okStatus, status = pcall(function()
      return host.status()
    end)
    local phase = type(status) == "table" and status.phase or nil
    if not okStatus or status == nil or phase == "failed" or phase == "complete" then
      self:_dropLaunch()
      return
    end
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
  if stagedManifest(manifest) == nil then
    if type(requestScene) ~= "function" then
      self:_failPendingLaunch("battle scene " .. tostring(sceneKey) .. ": no scene demand host to schedule it")
    else
      self:_failPendingLaunch(
        "battle scene " .. tostring(sceneKey) .. ": the staged battle presentation is unavailable"
      )
    end
    return
  end
  if not inventoriesScene(manifest, sceneKey) then
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

-- Latches the first terminal failure for the launch and reports it
-- through the host exactly once. This latch owns every envelope-level
-- terminal report: pending build failures and battle-music failures
-- share it, so the first report wins with its launch context and any
-- later failure for the same launch collapses without a second host
-- report. The host faults the runtime with it on its next launch pump;
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
      local staged = stagedManifest(manifest)
      assert(staged ~= nil, "battle sound needs its staged select role for launch " .. launchId)
      return controller:play(staged.audioRoles.select)
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

-- Adapts the shared audio controller behind the narrow registration
-- audio seam: the card cries resolve their semantic species through the
-- mon catalog and forward the numeric voice, completion forwards the
-- true-when-finished query, and select plays the staged semantic role.
-- Capabilities validate when a registration actually uses them, so old
-- deliberate no-registration headless cue sinks keep composing; a
-- missing required capability fails explicitly, never as no-op audio.
---@param launchId string owning launch identity behind failure context
---@return table<string, unknown> registration audio adapter with dot-call operations
function FieldBattlePresentation:_registrationAudioFor(launchId)
  local controller = self._screenAudio
  local manifest = self._manifest
  local monCatalog = self._monCatalog
  local audio = {}
  function audio.playCry(speciesKey, pattern, form)
    assert(
      type(speciesKey) == "string" and speciesKey ~= "",
      "registration cries name their species for launch " .. launchId
    )
    assert(type(controller.playCry) == "function", "registration cries need their audio voice for launch " .. launchId)
    assert(monCatalog ~= nil, "registration cries need their mon catalog for launch " .. launchId)
    local facts = monCatalog:species(speciesKey)
    assert(
      type(facts) == "table" and type(facts.nativeId) == "number",
      "registration cries name a cataloged species for launch " .. launchId .. ": " .. tostring(speciesKey)
    )
    return controller:playCry(facts.nativeId, pattern, form)
  end
  function audio.isCryFinished()
    assert(
      type(controller.isCryFinished) == "function",
      "registration cries need their completion query for launch " .. launchId
    )
    return controller:isCryFinished()
  end
  function audio.select()
    assert(type(controller.play) == "function", "registration select needs its audio sink for launch " .. launchId)
    local staged = stagedManifest(manifest)
    assert(staged ~= nil, "registration sound needs its staged select role for launch " .. launchId)
    return controller:play(staged.audioRoles.select)
  end
  return audio
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
  assert(
    inventoriesScene(manifest, sceneKey),
    "launch scene is outside the presentation inventory: " .. tostring(sceneKey)
  )
  local host = descriptor.host
  local function submit(reply)
    if host == nil then
      return false, { message = "the presented launch carries no host" }
    end
    return host.submit(reply)
  end
  local launchSpeed = descriptor.textSpeed or "mid"
  local envelope = self
  local function onResultMusic(word)
    return envelope:_startResultMusic(word)
  end
  local screen = BattleScreenState.new({
    launchId = descriptor.launchId,
    manifest = manifest,
    model = BattlePresentationModel,
    musicRole = self._musicRole,
    musicBanks = self:_audioBanks(),
    textSpeed = launchSpeed,
    submit = submit,
    onResultMusic = onResultMusic,
    measureDisplay = self._measureDisplay,
    pokedex = self._pokedex,
    registrationAudio = self:_registrationAudioFor(descriptor.launchId),
    assets = self._services,
    text = self._text,
    windows = self._windows,
    audio = self._screenAudio,
    itemCatalog = self._itemCatalog,
    monCatalog = self._monCatalog,
    monIconProvider = self._monIconProvider,
    battleMenus = self._battleMenus,
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

-- Resolves battle music and emitted sound effects to their bank closure
-- through the staged audio index. A cold or unstaged index stages nothing.
---@return integer[] battle audio bank identities, empty without a staged index
function FieldBattlePresentation:_audioBanks()
  local ok, index = pcall(function()
    return self._cacheFs:loadLua(AudioCache.indexPath())
  end)
  if not ok or type(index) ~= "table" then
    return {}
  end
  local sequences = index.sequences --[[@as table<integer, table<string, unknown>>?]]
  local bySymbol = index.sequenceBySymbol --[[@as table<string, integer>?]]
  if type(sequences) ~= "table" or type(bySymbol) ~= "table" then
    return {}
  end
  local roles = {}
  if type(self._musicRole) == "string" and self._musicRole ~= "" then
    roles[#roles + 1] = self._musicRole
  end
  for _, symbol in pairs(BattleAudio.SINK_SOUNDS) do
    roles[#roles + 1] = symbol
  end
  local banks, seen = {}, {}
  for _, role in ipairs(roles) do
    local id = type(role) == "string" and bySymbol[role] or nil
    local entry = type(id) == "number" and sequences[id] or nil
    local bank = type(entry) == "table" and entry.bankId or nil
    if type(bank) == "number" and not seen[bank] then
      seen[bank] = true
      banks[#banks + 1] = bank
    end
  end
  table.sort(banks)
  return banks
end

---@return string? battle-music start note, nil until the staged track voices
function FieldBattlePresentation:musicNote()
  return self._musicNote
end

-- Starts the source-selected transition for a graphical field launch.
-- Data-only envelope compositions have no field renderer and retain their
-- host-only presentation contract; the production field supplies both
-- collaborators together.
---@param descriptor table<string, unknown> admitted launch descriptor
function FieldBattlePresentation:_startTransition(descriptor)
  if self._fieldRenderer == nil and self._captureFieldLayers == nil then
    return
  end
  assert(
    self._fieldRenderer ~= nil and type(self._captureFieldLayers) == "function",
    "transition rendering is composed as a pair"
  )
  local context = descriptor.transitionContext
  if context == nil then
    -- Direct test launches bypass the field coordinator that captures
    -- selector facts: without a context there is no transition to run,
    -- and the launch continues cover-driven. A present but malformed
    -- context still fails fast below.
    return
  end
  assert(type(context) == "table", "presented field launches carry their captured semantic transition context")
  local function emitAudio(_, operation)
    assert(type(operation) == "table" and operation.kind == "start-battle-music", "transition audio is typed")
    self:_startBattleMusic()
  end
  local function createEffect(route, resources, launchContext)
    return TransitionFamilyFactory.new(
      route,
      resources,
      assert(self._graphics, "source transition sprites need the field graphics owner"),
      {
        camera = self._fieldCamera and self._fieldCamera() or nil,
        fieldRenderer = assert(self._fieldRenderer, "source camera transitions borrow the field compositor"),
      },
      launchContext
    )
  end
  assert(type(descriptor.environment) == "table", "presented field launches carry their selected scene key")
  local function loadStagedManifest()
    local manifest = loadManifest(self._cacheFs)
    assert(stagedManifest(manifest), "a ready battle scene publishes its verified presentation manifest")
    return manifest
  end
  local transition = BattleEncounterTransition.new({
    loadManifest = loadStagedManifest,
    cacheFs = self._cacheFs,
    battleAssets = assert(
      self._derivedAssets,
      "battle transition waits on its selected scene through the selected-game host"
    ),
    sceneKey = assert(descriptor.environment.sceneKey, "presented field launches carry their selected scene key"),
    audioOperations = { emit = emitAudio },
    effectFactory = createEffect,
  })
  self._transition = transition
  self._transitionContext = context
end

function FieldBattlePresentation:_startReadyTransition()
  local transition = assert(self._transition, "selected transition handle is retained by the launch")
  transition:start()
  local capture = assert(self._captureFieldLayers, "the field launch supplies fresh source captures")
  self._transitionCapture = capture()
  transition:acceptFieldLayers(self._transitionCapture)
end

-- Advances one selected source callback, then captures the field after its
-- camera/state mutation. The frame consumed by draw is therefore current,
-- while repeated draw calls cannot advance tasks or recapture the world.
function FieldBattlePresentation:_stepTransition()
  local transition = self._transition
  if transition == nil then
    return
  end
  local ok, err = pcall(function()
    local phase = transition:status().phase
    if phase == "new" or phase == "pending" then
      local readiness = transition:prepare(assert(self._transitionContext))
      if readiness == "ready" then
        self:_startReadyTransition()
      end
      return
    end
    if transition:status().phase ~= "running" then
      return
    end
    transition:stepSourceTick()
    local state = transition:status()
    if state.phase == "running" then
      local frame = transition:frame()
      if frame.requiresCurrentFieldLayers == true then
        local nextCapture = self._captureFieldLayers()
        local previous = self._transitionCapture
        self._transitionCapture = nextCapture
        transition:acceptFieldLayers(nextCapture)
        if previous ~= nil then
          previous:dispose()
        end
      end
    elseif state.phase == "complete" then
      local previous = self._transitionCapture
      self._transitionCapture = nil
      if previous ~= nil then
        previous:dispose()
      end
    end
  end)
  if not ok then
    self:_reportTransitionFailure("source update", err)
  end
end

-- Presents the latest captured field and source task frame without changing
-- either owner. The caller supplies the live destination so resize affects
-- only mapping, never native transition state.
---@param destination table<string, number> live field viewport
---@return boolean whether a field transition owned this frame
function FieldBattlePresentation:drawTransition(destination)
  if self._transitionFailed then
    return true
  end
  local transition = self._transition
  if transition == nil or transition:status().phase ~= "running" then
    return false
  end
  local ok, err = pcall(function()
    assert(self._transitionCapture ~= nil, "a running field transition owns its native source planes")
    self._fieldRenderer:drawTransition(self._transitionCapture, transition:frame(), destination)
  end)
  if not ok then
    self:_reportTransitionFailure("draw", err)
  end
  -- The failed route consumed this frame. Do not replace its pixels with
  -- the battle screen or the unrelated generic cover; C01 owns recovery.
  return true
end

-- Reports one native task/render failure to the existing launch owner before
-- releasing the route's images, field planes, and family task exactly once.
---@param operation string transition operation that failed
---@param cause unknown original transition failure
function FieldBattlePresentation:_reportTransitionFailure(operation, cause)
  if self._transitionFailed then
    return
  end
  self._transitionFailed = true
  local descriptor = self._descriptor
  local launchId = descriptor ~= nil and descriptor.launchId or "unknown"
  local detail = "battle transition "
    .. operation
    .. " failed for launch "
    .. tostring(launchId)
    .. ": "
    .. tostring(cause)
  local host = descriptor ~= nil and descriptor.host or nil
  if host ~= nil and type(host.notify) == "function" then
    host.notify("screen-failed", detail)
  end
  self:_disposeTransition()
end

---@return table<string, unknown>? detached launch-scoped transition status
function FieldBattlePresentation:transitionStatus()
  local transition = self._transition
  if transition == nil then
    return nil
  end
  return transition:status()
end

-- Advances the envelope on the accepted source clock: the scheduled scene
-- behind a pending launch is observed outside time, then every accepted
-- tick runs encounter cover work, the coordinator advance exactly once, and
-- the active battle tasks in source order. A frame carrying less than one
-- tick performs no semantic advance; a long frame obeys the same catch-up
-- cap with discarded time advancing no subsystem. The failed-screen report
-- stays reachable with a disposed inner screen because the coordinator
-- advance never depends on it. Draw, resize, and status polling never
-- advance these clocks.
---@param dt number accepted presentation seconds
function FieldBattlePresentation:updateFixed(dt)
  assert(type(dt) == "number" and dt == dt and dt >= 0, "presentation updates take accepted seconds")
  assert(not self._disposed, "the presented battle envelope is disposed")
  -- The scheduled scene behind a pending launch resolves here: the
  -- worker is observed before any accepted tick runs, so the battle runtime
  -- cannot publish a packet before its screen exists and a terminal
  -- build failure reaches the host before any further advance.
  self:_pollPendingScreen()
  self._accumulator = self._accumulator + dt
  local steps = 0
  while
    self._accumulator + FieldBattlePresentation.SOURCE_EPSILON >= FieldBattlePresentation.SOURCE_FRAME
    and steps < FieldBattlePresentation.MAX_CATCH_UP
  do
    self._accumulator = self._accumulator - FieldBattlePresentation.SOURCE_FRAME
    steps = steps + 1
    self:_stepTransition()
    self:_stepCover()
    -- The presented launch advances only here: the runtime phase machine
    -- and the owned battle clock run once per accepted tick, never through
    -- the host-update pump as well.
    local descriptor = self._descriptor
    local host = descriptor ~= nil and descriptor.host or nil
    if self._launchId ~= nil and host ~= nil then
      host.advance()
    end
    local screen = self._screen
    if screen ~= nil then
      screen:updateFixed(FieldBattlePresentation.SOURCE_FRAME)
      self:_observeScreenFailure()
    end
  end
  if self._accumulator + FieldBattlePresentation.SOURCE_EPSILON >= FieldBattlePresentation.SOURCE_FRAME then
    local discarded =
      math.floor((self._accumulator + FieldBattlePresentation.SOURCE_EPSILON) / FieldBattlePresentation.SOURCE_FRAME)
    self._accumulator = self._accumulator - discarded * FieldBattlePresentation.SOURCE_FRAME
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
    -- The source encounter task starts its selected music in the same
    -- initialization tick that launches the native transition effect.
    -- Keep this operation at task admission; the host cover remains a
    -- separate safety layer and may continue after the transition starts.
    if
      self._transition ~= nil
      and self._transition:status().phase ~= "running"
      and self._transition:status().phase ~= "complete"
    then
      return
    end
    self:_stepCoverUp()
    if
      self._cover >= FieldBattlePresentation.COVER_MAX
      and (self._transition == nil or self._transition:status().phase == "complete")
    then
      host.notify("cover-complete")
    end
    if self._cover >= FieldBattlePresentation.COVER_MAX then
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

-- Starts the source-defined battle music role once under full cover:
-- the staged chosen-track closure voices through the launch voice
-- operations at the transition boundary. The start is attempted exactly
-- once per launch. A missing role, a rejected start, or a missing
-- staged track fails the launch through the host with its music
-- identity instead of continuing silently; a launch without a music
-- port keeps its headless test-sink contract.
function FieldBattlePresentation:_startBattleMusic()
  if self._musicStarted then
    return
  end
  self._musicStarted = true
  local launchId = self._launchId
  local descriptor = self._descriptor
  local role = self._musicRole
  local audio = descriptor ~= nil and descriptor.audio or nil
  if type(role) ~= "string" or role == "" then
    self:_failMusic("battle music needs its staged track role for launch " .. tostring(launchId))
    return
  end
  if audio == nil or type(audio.playMusic) ~= "function" then
    return
  end
  local voice = BattleAudio.new({
    sink = audio,
    launchId = launchId --[[@as string]],
  })
  local ok, err = pcall(voice.startMusic, voice, role)
  if not ok then
    self:_failMusic(tostring(err))
  else
    self._musicNote = "started:" .. role
  end
end

-- Reports one battle-music failure through the envelope's first-failure
-- latch with its launch and track identity: whichever terminal failure
-- comes first for the launch wins, whether it names the music role or
-- the scene worker, and any later failure collapses without a second
-- host report. The coordinator faults the runtime with the original
-- cause.
---@param reason string failure context behind the report
function FieldBattlePresentation:_failMusic(reason)
  self:_failPendingLaunch(reason)
end

-- Swaps the victory BGM once on the screen terminal beat: wins voice
-- the class-routed victory track, captures voice the wild-win track at
-- the gotcha beat (native BGM swaps at battle_command.c exp-gain/gotcha
-- and battle_controller_player.c class switch; battle exit fades the BGM
-- instead). The bound screen invokes this at its outcome narration
-- entry, before any explicit acknowledgement, so the outer result status
-- is never consulted for music. The swap rides the launch voice
-- operations so a rejected start fails through the host with its
-- identity while the committed words survive through the existing
-- committed path. A launch without a music port keeps its headless
-- test-sink contract. Any other word or a missing admitted launch
-- fails loudly with its provenance instead of guessing a track.
---@param word string terminal result word behind the BGM swap
---@return boolean started true once the beat was admitted for this launch
function FieldBattlePresentation:_startResultMusic(word)
  if self._resultMusicPlayed then
    return true
  end
  self._resultMusicPlayed = true
  local launchId = self._launchId
  local descriptor = self._descriptor
  if type(launchId) ~= "string" or launchId == "" or type(descriptor) ~= "table" then
    error("result music needs its admitted launch for word " .. tostring(word), 0)
  end
  local symbol = nil
  if word == "win" then
    local kind = descriptor.kind
    local trainerClass = descriptor.trainerClass
    symbol = BattleMusicSelection.victoryMusicSymbol(kind == "trainer" and "trainer" or "wild", trainerClass)
  elseif word == "capture" then
    -- The gotcha beat voices the wild victory even though captures never
    -- route by class; victoryMusicSymbol("wild") is that track by
    -- construction.
    symbol = BattleMusicSelection.victoryMusicSymbol("wild", nil)
  else
    error("result music voices no track for word " .. tostring(word) .. " for launch " .. launchId, 0)
  end
  local audio = descriptor.audio
  if audio == nil or type(audio.playMusic) ~= "function" then
    return true
  end
  local voice = BattleAudio.new({ sink = audio, launchId = launchId })
  local ok, err = pcall(voice.startMusic, voice, symbol)
  if not ok then
    self:_failMusic(tostring(err))
  end
  return true
end

-- Observes a failed screen and reports the launch through the runtime
-- instead of polling a dead presentation: the screen disposes once while
-- the descriptor, black cover, and launch identity stay with the host
-- until the safe field returns. Repeats collapse into the first report
-- because the screen is gone after the first one, and a terminal music
-- failure that already went out suppresses this report through the
-- same latch while the dead screen is still released.
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
    -- Shares the envelope's first-failure latch with the pending-build
    -- and battle-music reports: a music failure that already went out
    -- for this launch suppresses this second host report, while the
    -- dead screen is still released exactly once below either way.
    local firstReport = not self._pendingFailed
    self._pendingFailed = true
    if firstReport then
      host.notify("screen-failed", status.error)
    end
    -- The report runs synchronously: the owner may have disposed the
    -- battle (and this screen with it) from inside the notification, so
    -- only the screen still owned here is released, exactly once. The
    -- inner forwarding reference clears either way so no later delivery
    -- reaches the failed screen.
    if self._screen == screen then
      local _, _ = pcall(function()
        return screen:dispose()
      end)
      self._screen = nil
    end
    self._innerPort = nil
  end
end

-- Forgets a cleared launch: the host settled or the envelope tore down,
-- so only envelope bookkeeping remains. Runs only from settlement
-- observation or full disposal, never from port disposal.
function FieldBattlePresentation:_dropLaunch()
  self:_disposeTransition()
  local staged = self._pendingSceneImage
  self._pendingSceneImage = nil
  if staged ~= nil and self._pool ~= nil then
    pcall(self._pool.cancel, self._pool, staged.token)
  end
  -- Pre-enrolled upload tickets never outlive their launch: the worker
  -- interest behind an undrawn ticket is discarded instead of retained
  -- unclaimed, and the next launch enrolls its own paths.
  if self._pool ~= nil then
    for path, token in pairs(self._pendingUploads) do
      self._pendingUploads[path] = nil
      pcall(self._pool.cancel, self._pool, token)
    end
  else
    self._pendingUploads = {}
  end
  self._enrolledUploads = {}
  self._launchId = nil
  self._descriptor = nil
  self._pendingFailed = false
  self._pendingBuild = false
  self._portDisposed = false
  self._recoveryPointerId = nil
  self._screen = nil
  self._port = nil
  self._innerPort = nil
  self._lastStatus = nil
  self._revealingBattle = false
  self._musicStarted = false
  self._musicNote = nil
  self._musicRole = nil
  self._resultMusicPlayed = false
  self._transitionFailed = false
end

-- Releases the active native task and its latest launch-owned field planes
-- exactly once, including completion, failure, and envelope disposal.
function FieldBattlePresentation:_disposeTransition()
  local transition = self._transition
  self._transition = nil
  self._transitionContext = nil
  if transition ~= nil then
    transition:dispose()
  end
  local capture = self._transitionCapture
  self._transitionCapture = nil
  if capture ~= nil then
    capture:dispose()
  end
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
  -- Launch leases go back unless a warm pin still owns them; pins
  -- release separately below so a mid-launch disposal never frees a
  -- pinned borrow twice.
  local pool = self._pool
  for key, pooled in pairs(self._leases) do
    self._leases[key] = nil
    if pool ~= nil and self._warmPinned[key] == nil then
      pool:release(pooled.lease)
    end
  end
  for key, pinned in pairs(self._warmPinned) do
    self._warmPinned[key] = nil
    if self._warmPaths ~= nil then
      self._warmPaths[key] = nil
    end
    if pool ~= nil then
      pool:release(pinned.lease)
    end
  end
  for key, _ in pairs(self._imageFailures) do
    self._imageFailures[key] = nil
  end
  cancelWarmTickets(self)
  self._warmDesired = nil
  self._warmFailed = {}
  self._warmBg3Key = nil
  self._warmBg3 = nil
  self._warmFailure = nil
  self:_dropLaunch()
  self._cover = 0
  self._accumulator = 0
end

return FieldBattlePresentation
