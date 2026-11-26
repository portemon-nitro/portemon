-- The single script-owned care child: one request, one scene, one terminal
-- result. Four closed application kinds exist: the egg hatch scene, the app71
-- trade sequence, the move reminder / singleton tutor application and the
-- script Summary application. The blocking task owns the source lifecycle and
-- the save policy; this host owns only the child handle, its presentation
-- bundle and its result lease. The scene advances on the owning scheduler
-- tick, so the field never steps it, and the renderer only reads its
-- snapshots. Stale handles and presentation failures propagate after cleanup.
-- Game-side leaf: never imported by libs/script.

local EggHatchState = require("game.hgss.src.field.EggHatchState")
local MoveRelearnerState = require("game.hgss.src.field.MoveRelearnerState")
local NpcTradeState = require("game.hgss.src.field.NpcTradeState")
local PokemonCareInterface = require("libs.hgss.src.ui.PokemonCareInterface")
local SummaryCache = require("libs.assets.src.SummaryCache")
local SummaryScreenState = require("game.hgss.src.field.SummaryScreenState")

-- The frozen bundle a headless composition commits: no presented field realizes
-- images, so the screen runs its source states with nothing to draw.
local EMPTY_ASSETS = {}

---@class PokemonCareScriptHost
---@field private _runtime table<string, unknown> owning field runtime behind the presentation binding
---@field private _nextId integer handle identity counter
---@field private _active { handle: table<string, unknown>, state: table<string, unknown>, lease: table<string, unknown>?, request: table<string, unknown> }? live child
---@field private _last { handle: table<string, unknown>, result: table<string, unknown>? }? retained terminal result behind the just-closed child
---@field private _activeAssets table<string, unknown>? the committed presentation bundle of the live child
---@field private _summaryManifest table<string, unknown>? the loaded summary family behind the script Summary children
---@field private _disposed boolean teardown flag
local PokemonCareScriptHost = {}
PokemonCareScriptHost.__index = PokemonCareScriptHost

---@param args { runtime: table<string, unknown> }
---@return PokemonCareScriptHost
function PokemonCareScriptHost.new(args)
  assert(type(args) == "table", "care host requires its owner")
  assert(type(args.runtime) == "table", "care host borrows its field runtime")
  return setmetatable({
    _runtime = args.runtime,
    _nextId = 0,
    _active = nil,
    _last = nil,
    _activeAssets = nil,
    _summaryManifest = nil,
    _disposed = false,
  }, PokemonCareScriptHost)
end

-- The script Summary children draw the field's own summary family. The
-- presented composition already loads it beside the menus; a script Summary
-- loaded here is the same validated family, never a second definition.
---@return table<string, unknown>
function PokemonCareScriptHost:_summaryFamily()
  if self._summaryManifest == nil then
    local runtime = self._runtime
    self._summaryManifest =
      SummaryCache.loadManifest(assert(runtime.cacheFs, "script summaries need the version cache"))
  end
  return assert(self._summaryManifest, "the summary family stays loaded for the child lifetime")
end

-- The one subject a script Summary picker shows: the canonical party record at
-- the requested slot, read live so a replacement publishes against the party
-- revision the screen observed.
---@param slot0 integer
---@return SummarySubjectPort
function PokemonCareScriptHost:_singleSubjectPort(slot0)
  local mons = assert(self._runtime.monService, "a script Summary needs the live mon service")
  local function countSubjects()
    return 1
  end
  local function partyRevision()
    return mons:partyRevision()
  end
  local function readSubject(index)
    assert(index == 0, "a one-subject Summary reads its only subject")
    return mons:partyMon(slot0)
  end
  local function publishSubject(index, mon, expectedRevision)
    local preparation, reason = mons:preparePartyChanges(expectedRevision, { { slot = index, mon = mon } })
    if preparation == nil then
      assert(reason == "stale", "preparation refuses stale revisions loudly")
      return { kind = "stale" }
    end
    preparation.publish()
    return { kind = "changed" }
  end
  return {
    count = countSubjects,
    revision = partyRevision,
    read = readSubject,
    publish = publishSubject,
  }
end

-- The closed picker request a script Summary opens with: the deletion picker
-- allows every row, the tutor replacement protects the hidden machines exactly
-- like the machine picker and previews the offered move.
---@param mode string
---@param slot0 integer
---@param moveToLearn string?
---@return table<string, unknown>
function PokemonCareScriptHost:_pickerRequest(mode, slot0, moveToLearn)
  if mode == PokemonCareInterface.SUMMARY_MODES.delete_move then
    return { context = "delete_move" }
  end
  local request = { context = "replace_tutor" }
  if moveToLearn == nil then
    return request
  end
  local mons = assert(self._runtime.monService, "a replacement picker needs the live mon service")
  local catalog = mons:catalog()
  local items = assert(self._runtime.itemCatalog, "a replacement picker needs the item catalog")
  local hms = items:hmMoveNativeIds()
  local protected = {}
  for index, entry in ipairs(assert(mons:partyMon(slot0).moves, "a stored mon carries its moves")) do
    if hms[catalog:move(entry.move).nativeId] == true then
      protected[index] = "hm"
    end
  end
  request.prospectiveMove = moveToLearn
  request.protected = protected
  return request
end

-- The replacement Summary's preparation: the presented field owns one summary
-- preparation owner, so its lease realizes the picker's portraits and chrome.
-- A composition without that owner (a headless field, or a host that binds the
-- care presentation alone) rides the bundle the care application already
-- committed, which is the same summary family the screen draws.
---@return table<string, unknown>
function PokemonCareScriptHost:_summaryPreparation()
  local runtime = self._runtime
  local acquire = runtime.acquireSummaryPreparation
  if type(acquire) == "function" then
    local lease = acquire(runtime)
    if lease ~= nil then
      return lease --[[@as table<string, unknown>]]
    end
  end
  local host = self
  local function prepareLeaseDemand(_, demand)
    return host:_prepareLeaseDemand(demand)
  end
  local function releaseLeaseDemand() end
  return {
    prepare = prepareLeaseDemand,
    release = releaseLeaseDemand,
  }
end

-- The committed care bundle's summary family, or the empty bundle a headless
-- composition rides. A live child's own lease prepares first, so a failed
-- preparation refuses the demand instead of drawing a partial family.
---@param demand table<string, unknown> the requested family key
---@return table<string, unknown> preparation outcome
function PokemonCareScriptHost:_prepareLeaseDemand(demand)
  assert(type(demand) == "table" and type(demand.key) == "string", "summary demands carry their key")
  local active = self._active
  local careLease = active ~= nil and active.lease or nil
  if careLease ~= nil then
    local outcome = careLease:prepare()
    if outcome.kind ~= "ready" then
      return outcome
    end
  end
  return { kind = "ready", key = demand.key, assets = self._activeAssets or EMPTY_ASSETS }
end

-- The screen a script Summary or a replacement picker runs: the field's own
-- concrete Summary application over the requested subject.
---@param request PokemonCareSummaryRequest
---@return table<string, unknown> live screen
function PokemonCareScriptHost:_summaryChild(request)
  local runtime = self._runtime
  local mons = assert(runtime.monService, "a script Summary needs the live mon service")
  local manifest = self:_summaryFamily()
  local FieldMenuCompositionCoordinator = require("game.hgss.src.field.FieldMenuCompositionCoordinator")
  local host = self
  local function measureDisplay()
    return assert(runtime.presentationDisplay, "a script Summary needs the display facts")
  end
  local function readNavigation()
    local input = assert(runtime.input, "a script Summary needs the field input")
    return input:lastUiNavigation()
  end
  local function acquirePreparation()
    return host:_summaryPreparation()
  end
  local options = {
    mons = mons,
    manifest = manifest,
    initialSlot = request.slot,
    measureDisplay = measureDisplay,
    context = FieldMenuCompositionCoordinator.summaryContextProvider(runtime, manifest),
    readNavigation = readNavigation,
    acquirePreparation = acquirePreparation,
    overrides = runtime.presentationOverrides ~= nil and runtime.presentationOverrides.summary or nil,
  }
  if request.mode == PokemonCareInterface.SUMMARY_MODES.summary then
    options.mode = "summary"
  else
    options.mode = "move_pick"
    options.initialSlot = 0
    options.subjectPort = self:_singleSubjectPort(request.slot)
    options.request = self:_pickerRequest(request.mode, request.slot, request.moveToLearn)
  end
  return SummaryScreenState.new(options)
end

-- The script Summary's scene protocol over the concrete screen: the host owns
-- one child shape, so the Summary application answers the same
-- snapshot/result/dispose contract as the care scenes. The screen gates itself
-- through its own preparation lease; a bundle that cannot be committed cancels
-- instead of leaving the script waiting on a black screen.
---@param child table<string, unknown> the concrete Summary screen
---@param request PokemonCareSummaryRequest
---@return table<string, unknown> scene
local function summaryScene(child, request)
  local result = nil
  local picker = request.mode ~= PokemonCareInterface.SUMMARY_MODES.summary
  local function cancelled()
    return {
      kind = PokemonCareInterface.KINDS.summary_application,
      partySlot = request.slot,
      moveSlot = picker and 4 or nil,
      cancelled = true,
      done = true,
    }
  end
  local scene = {}
  -- The Summary consumes the scheduler's UI event list; the care host is the
  -- modal's input owner, so its raw edges map to those same events.
  ---@param input table<string, unknown>?
  function scene:updateFixed(input)
    child:updateFixed(PokemonCareInterface.summaryInputEvents(input))
    if result ~= nil then
      return
    end
    local answer = child:takeResult()
    if answer == nil then
      return
    end
    if answer.kind == "move_selected" then
      result = {
        kind = PokemonCareInterface.KINDS.summary_application,
        partySlot = assert(answer.slot, "a picked row answers its party slot"),
        moveSlot = assert(answer.moveSlot, "a picked row answers its move row"),
        cancelled = false,
        done = true,
      }
      return
    end
    if answer.kind == "return" then
      result = {
        kind = PokemonCareInterface.KINDS.summary_application,
        partySlot = assert(answer.slot, "a closed Summary answers its final party slot"),
        cancelled = false,
        done = true,
      }
      return
    end
    assert(answer.kind == "cancelled", "the Summary answers return, a pick or cancellation")
    result = cancelled()
  end
  function scene:setPresentation(ready, _)
    if ready == false and result == nil then
      result = cancelled()
    end
  end
  function scene:snapshot()
    return child:status()
  end
  function scene:isDone()
    return result ~= nil
  end
  function scene:result()
    assert(result ~= nil, "an unfinished Summary application has no result")
    return result
  end
  function scene:dispose()
    child:dispose()
  end
  return scene
end

-- Opens the one care child. The presentation lease is acquired through the
-- runtime's binding, which the presented field installs; a headless
-- composition has none, so the scene still runs its source frames and waits
-- while the renderer reports no bundle. A failed acquisition surfaces as the
-- scene's own preparation error instead of a silent blank screen.
---@param request table<string, unknown> the closed application request
---@return table<string, unknown> handle live child identity
function PokemonCareScriptHost:open(request)
  assert(not self._disposed, "disposed care host cannot open a child")
  assert(self._active == nil, "a care application already owns the script modal")
  assert(type(request) == "table", "care applications open from a request record")
  local runtime = self._runtime
  local audio = assert(
    runtime.audio or (runtime.scriptHosts and runtime.scriptHosts.audio),
    "care host needs the source audio host"
  )
  self._nextId = self._nextId + 1
  local handle = { id = self._nextId }
  local typed, state
  if request.kind == PokemonCareInterface.KINDS.trade then
    typed = PokemonCareInterface.assertTradeRequest(request)
    state = NpcTradeState.new({ request = typed, audio = audio })
  elseif request.kind == PokemonCareInterface.KINDS.move_relearner then
    typed = PokemonCareInterface.assertRelearnerRequest(request)
    local tutor = assert(runtime.moveTutor, "the reminder lesson needs the move tutor owner")
    local catalog = assert(runtime.monService, "the reminder lesson needs the mon service"):catalog()
    local host = self
    local function teachMove(move, targetSlot)
      return tutor:teach(typed.slot, move, targetSlot, typed.revision)
    end
    local function openSummary(childRequest)
      return host:_summaryChild(childRequest)
    end
    state = MoveRelearnerState.new({
      request = typed,
      catalog = catalog,
      audio = audio,
      teach = teachMove,
      openSummary = openSummary,
    })
  elseif request.kind == PokemonCareInterface.KINDS.summary_application then
    typed = PokemonCareInterface.assertSummaryRequest(request)
    state = summaryScene(self:_summaryChild(typed), typed)
  else
    typed = PokemonCareInterface.assertHatchRequest(request)
    state = EggHatchState.new({
      variant = typed.variant,
      species = typed.species,
      form = typed.form,
      audio = audio,
      hatched = { messageId = 0, frames = 1 },
      question = { messageId = 1, frames = 1 },
    })
  end
  local lease = nil
  if type(runtime.acquirePokemonCarePresentation) == "function" then
    lease = runtime:acquirePokemonCarePresentation(typed)
  end
  self._active = { handle = handle, state = state, lease = lease, request = typed }
  self._activeAssets = nil
  self._last = nil
  return handle
end

---@return table<string, unknown>? handle live child identity when a child is open
function PokemonCareScriptHost:activeHandle()
  local active = self._active
  if active == nil then
    return nil
  end
  return active.handle
end

---@param handle table<string, unknown>
---@return { handle: table<string, unknown>, state: table<string, unknown>, lease: table<string, unknown>?, request: table<string, unknown> }
local function activeFor(self, handle)
  local active = assert(self._active, "no care application is open")
  assert(handle == active.handle, "care application handle is stale or foreign")
  return active
end

-- Steps the live child once over the scheduler input snapshot and advances the
-- generated presentation bundle. A failed bundle is reported on the scene's
-- own snapshot instead of aborting the gameplay path.
---@param handle table<string, unknown> live child identity
---@param input table<string, unknown>? scheduler input snapshot
function PokemonCareScriptHost:step(handle, input)
  local active = activeFor(self, handle)
  local lease = active.lease
  if lease ~= nil then
    local ok, outcome = pcall(lease.prepare, lease)
    if not ok then
      active.state:setPresentation(false, tostring(outcome))
    elseif outcome ~= nil then
      if outcome.kind == "ready" then
        self._activeAssets = outcome.assets
        active.state:setPresentation(true, nil, outcome.assets)
      elseif outcome.kind == "failed" then
        active.state:setPresentation(false, tostring(outcome.error))
      else
        active.state:setPresentation(false, nil)
      end
    end
  end
  -- A source scene that hit-tests its own presented surface takes the ordered
  -- host pointer batch: the session inverts the point into the interactive
  -- screen's coordinates and the scene answers the source's own target.
  local pointerEvents = nil
  if type(active.state.handlePointer) == "function" then
    local fieldInput = self._runtime.input
    if type(fieldInput) == "table" and type(fieldInput.takePointerEvents) == "function" then
      pointerEvents = fieldInput:takePointerEvents()
    end
  end
  active.state:updateFixed(input)
  if pointerEvents ~= nil and #pointerEvents > 0 and not active.state:isDone() then
    local presented = lease ~= nil and lease:presentation() or nil
    local renderer = presented ~= nil and presented.renderer or nil
    if renderer ~= nil and type(renderer.mapPointer) == "function" then
      local target = renderer:mapPointer(pointerEvents, active.state:snapshot())
      if target ~= nil then
        active.state:handlePointer(target)
      end
    end
  end
  local presentation = lease ~= nil and lease:presentation() or nil
  if presentation == nil then
    return
  end
  local snapshot = active.state:snapshot()
  if snapshot.kind == PokemonCareInterface.KINDS.hatch then
    local requested = snapshot.particles --[[@as integer[]|nil ]]
    if requested ~= nil and #requested > 0 then
      presentation.renderer:emitParticles(assert(snapshot.variant) --[[@as string]], requested)
    end
    presentation.renderer:updateFixed()
  end
end

-- Reads the terminal result: nil until the scene finished, then the detached
-- answer. The host caches that publication and serves it until close, so the
-- owning task and an observer share one terminal read.
---@param handle table<string, unknown> live or just-closed child identity
---@return table<string, unknown>? terminal scene result
function PokemonCareScriptHost:result(handle)
  local active = self._active
  if active ~= nil then
    assert(handle == active.handle, "care application handle is stale or foreign")
    if not active.state:isDone() then
      return nil
    end
    return active.state:result()
  end
  local last = self._last
  if last ~= nil and handle == last.handle then
    self._last = nil
    return last.result
  end
  assert(false, "care application handle is stale or foreign")
  error("unreachable", 0)
end

-- Releases the child, its scene and its presentation lease. Idempotent:
-- closing without a child or with the live handle both succeed exactly once
-- per open.
---@param handle table<string, unknown>? live child identity
function PokemonCareScriptHost:close(handle)
  local active = self._active
  if active == nil then
    return
  end
  assert(handle == active.handle, "care application handle is stale or foreign")
  local result = active.state:isDone() and active.state:result() or nil
  if active.lease ~= nil then
    active.lease:release()
  end
  active.state:dispose()
  self._active = nil
  self._activeAssets = nil
  self._last = { handle = active.handle, result = result }
end

---@return boolean
function PokemonCareScriptHost:isActive()
  return self._active ~= nil
end

-- A care child owns the field from its open through its close and the receipt
-- publication that follows: no field record may describe the half-applied
-- hatch while it lives.
---@return boolean
function PokemonCareScriptHost:isStableForSave()
  return self._active == nil
end

-- Forwards the live scene's immutable snapshot for drawing. Status never
-- advances the scene.
---@param handle table<string, unknown>? live child identity
---@return table<string, unknown>? scene snapshot
function PokemonCareScriptHost:status(handle)
  local active = self._active
  if active == nil then
    return nil
  end
  if handle ~= nil then
    assert(handle == active.handle, "care application handle is stale or foreign")
  end
  return active.state:snapshot()
end

-- The committed presentation bundle behind the live scene, or nil while it is
-- still pending or unusable.
---@return table<string, unknown>?
function PokemonCareScriptHost:presentation()
  local active = self._active
  if active == nil or active.lease == nil then
    return nil
  end
  return active.lease:presentation()
end

-- The live snapshot the renderer draws, or nil when no child is open.
---@return table<string, unknown>?
function PokemonCareScriptHost:snapshot()
  local active = self._active
  if active == nil then
    return nil
  end
  return active.state:snapshot()
end

-- Releases the owned child once for the given reason. Idempotent.
---@param reason string
function PokemonCareScriptHost:cancel(reason)
  assert(type(reason) == "string" and reason ~= "", "care cancellation requires a reason")
  local active = self._active
  if active ~= nil then
    self:close(active.handle)
  end
end

-- Idempotent teardown: releases the child and refuses further opens.
function PokemonCareScriptHost:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  local active = self._active
  if active ~= nil then
    self:close(active.handle)
  end
  self._summaryManifest = nil
end

return PokemonCareScriptHost
