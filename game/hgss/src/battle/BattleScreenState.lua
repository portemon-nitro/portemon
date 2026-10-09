-- One interactive battle screen over the real battle runtime. Owns
-- command, selection, narration, cue playback and the child slot for a
-- single launch: it forwards accepted choice fragments through the
-- injected submit boundary, plays ordered delivery packets through its
-- cue player, resolves paired complete plans through the shared
-- presentation session, and exposes a detached view with truthful
-- readiness. It never owns battle calculations or persistence; draw
-- calls are read-only and the fixed clock is the only thing that
-- advances presentation. Input after disposal is dropped, never
-- applied.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local BattlePresentationAssets = require("game.hgss.src.battle.BattlePresentationAssets")
local BattleScreenInterface = require("game.hgss.src.battle.BattleScreenInterface")
local BattleSubflows = require("game.hgss.src.battle.BattleSubflows")
local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")

---@class BattleScreenState
---@field _launchId string owning launch identity
---@field _manifest table<string, unknown> planning manifest behind the demand
---@field _submit fun(reply: table<string, unknown>): boolean, table<string, unknown>? accepted-choice boundary
---@field _measureDisplay fun(): table<string, unknown> live display facts
---@field _text table<string, unknown> borrowed text services
---@field _windows table<string, unknown> borrowed window services
---@field _audio table<string, unknown> semantic sound boundary
---@field _assets BattlePresentationAssets per-launch preparation leases
---@field _timeline BattleTimeline ordered visible-cue player
---@field _session ApplicationPresentation per-open presentation session
---@field _subflows BattleSubflows battle-local child coordinator
---@field _partySnapshot table<integer, table<string, unknown>>? latest detached own-party facts
---@field _inventorySnapshot table<string, integer>? latest detached battle stock
---@field _mode string closed controller mode
---@field _selection string? highlighted semantic identity
---@field _armed table<string, unknown>? pressed control awaiting release
---@field _child table<string, unknown>? open child intent
---@field _request table<string, unknown>? mirrored open request
---@field _options table<string, unknown>? latest decision options for the open request
---@field _pendingFinal table<string, unknown>? retained final view behind playing cues
---@field _pendingRequest table<string, unknown>? retained request behind playing cues
---@field _pendingResult table<string, unknown>? retained terminal result behind playing cues
---@field _openingReceived boolean first delivery arrived
---@field _introBuilt boolean opening cues queued
---@field _kind string battle kind wording for the opening narration
---@field _queue table<integer, table<string, unknown>> queued raw input batches
---@field _notice string? transient refusal banner
---@field _signature string? measurement signature behind the published plan
---@field _arrowTick integer selection arrow clock in presentation ticks
---@field _outcomeShown boolean terminal narration displayed
---@field _outcomeAcked boolean terminal narration acknowledged once
---@field _error string? failure context
---@field _disposed boolean
local BattleScreenState = {}
BattleScreenState.__index = BattleScreenState

-- Native command navigation follows the source touch topology, not a
-- compact grid order.
local COMMAND_NAV = {
  fight = { up = "fight", down = "run", left = "fight", right = "fight" },
  bag = { up = "fight", down = "bag", left = "bag", right = "run" },
  run = { up = "fight", down = "run", left = "bag", right = "pokemon" },
  pokemon = { up = "fight", down = "pokemon", left = "run", right = "pokemon" },
}

local MOVE_NAV = {
  ["move:0"] = { up = "move:0", down = "move:2", left = "move:0", right = "move:1" },
  ["move:1"] = { up = "move:1", down = "move:3", left = "move:0", right = "move:1" },
  ["move:2"] = { up = "move:0", down = "cancel", left = "move:2", right = "move:3" },
  ["move:3"] = { up = "move:1", down = "cancel", left = "move:2", right = "move:3" },
  cancel = { up = "move:2", down = "cancel", left = "cancel", right = "cancel" },
}

-- Six-cell arrow cycle: the zero-time entry never displays, the rest
-- hold their authored counts. A bounded scan skips the empty entry.
local ARROW_DURATIONS = { 0, 4, 4, 4, 16, 6 }

-- Collects the staged battle-music and interface role symbols behind the
-- launch demand: every staged wild, trainer, rival, and select symbol the
-- manifest verifies. A planning manifest stages no roles and demands
-- none; the preparation services fail closed on unstaged roles where
-- pixels are actually required.
---@param manifest table<string, unknown> staged or planning presentation manifest
---@return string[] staged audio role symbols
local function stagedAudioRoles(manifest)
  local roles = {}
  if type(manifest) == "table" and manifest.verified == true and type(manifest.audioRoles) == "table" then
    for _, role in ipairs({ "wild", "trainer", "rival", "select" }) do
      if type(manifest.audioRoles[role]) == "string" then
        roles[#roles + 1] = manifest.audioRoles[role]
      end
    end
  end
  return roles
end

---@param value unknown
---@return unknown detached copy without shared mutable state
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copyValue(item)
  end
  return out
end

---@class BattleScreenState.Options
---@field launchId string owning launch identity
---@field manifest table<string, unknown> planning manifest behind the demand
---@field model table<string, unknown> detached opening and packet boundary
---@field submit fun(reply: table<string, unknown>): boolean, table<string, unknown>? accepted-choice boundary
---@field measureDisplay fun(): table<string, unknown> live display facts
---@field assets BattlePresentationAssets.Services preparation services carrying prepare/drawable/release
---@field text table<string, unknown> borrowed text services
---@field windows table<string, unknown> borrowed window services
---@field audio table<string, unknown> semantic sound boundary
---@field itemCatalog table<string, unknown>? borrowed immutable item catalog for battle bag grouping
---@field monCatalog table<string, unknown>? borrowed immutable mon catalog for machine display facts
---@field overrides table<string, unknown>? per-instance scene/frame/case inputs

---@param opts BattleScreenState.Options
---@return BattleScreenState
function BattleScreenState.new(opts)
  assert(type(opts) == "table", "the battle screen requires options")
  assert(type(opts.launchId) == "string" and opts.launchId ~= "", "the battle screen needs its launch identity")
  assert(type(opts.manifest) == "table", "the battle screen needs its planning manifest")
  assert(type(opts.model) == "table", "the battle screen needs its detached view boundary")
  assert(type(opts.submit) == "function", "the battle screen needs its accepted-choice boundary")
  assert(type(opts.measureDisplay) == "function", "the battle screen needs its display facts")
  assert(type(opts.assets) == "table", "the battle screen needs its preparation services")
  assert(type(opts.text) == "table", "the battle screen borrows its text services")
  assert(type(opts.windows) == "table", "the battle screen borrows its window services")
  assert(type(opts.audio) == "table", "the battle screen needs its sound boundary")
  local overrides = opts.overrides or {}
  assert(type(overrides) == "table", "per-instance inputs arrive as a record")
  local manifest = opts.manifest --[[@as table<string, unknown>]]
  local sceneKey = overrides.sceneKey
  if sceneKey == nil and type(manifest.scenes) == "table" and type(manifest.scenes[1]) == "table" then
    sceneKey = manifest.scenes[1].key
  end
  assert(type(sceneKey) == "string" and sceneKey ~= "", "the battle screen resolves its scene identity")
  local self = setmetatable({
    _launchId = opts.launchId,
    _manifest = manifest,
    _model = opts.model,
    _submit = opts.submit,
    _measureDisplay = opts.measureDisplay,
    _text = opts.text,
    _windows = opts.windows,
    _audio = opts.audio,
    _assets = BattlePresentationAssets.new({
      assets = opts.assets,
      launchId = opts.launchId,
      sceneKey = sceneKey --[[@as string]],
      audioRoles = stagedAudioRoles(manifest),
      sceneImage = overrides.sceneImage --[[@as string?]],
      frameKey = overrides.frameKey --[[@as string?]],
      frames = overrides.frames --[[@as table<string, table<string, unknown>>?]],
    }),
    _timeline = nil,
    _session = nil,
    _subflows = BattleSubflows.new({
      launchId = opts.launchId,
      itemCatalog = opts.itemCatalog,
      monCatalog = opts.monCatalog,
      measureDisplay = opts.measureDisplay,
    }),
    _partySnapshot = nil,
    _inventorySnapshot = nil,
    _mode = "preparing",
    _selection = "fight",
    _armed = nil,
    _child = nil,
    _request = nil,
    _options = nil,
    _pendingFinal = nil,
    _pendingRequest = nil,
    _pendingResult = nil,
    _openingReceived = false,
    _introBuilt = false,
    _kind = "wild",
    _queue = {},
    _notice = nil,
    _signature = nil,
    _arrowTick = 0,
    _outcomeShown = false,
    _outcomeAcked = false,
    _error = nil,
    _disposed = false,
  }, BattleScreenState)
  -- Foe move sets never enter the detached views, so foe narration
  -- resolves display names through the borrowed mon catalog. The
  -- resolver stays optional: views and raw identities cover its absence.
  local moveNameOf = nil
  if type(opts.monCatalog) == "table" and type(opts.monCatalog.move) == "function" then
    local catalog = opts.monCatalog
    local lookup = opts.monCatalog.move --[[@as fun(self: table<string, unknown>, key: string): table<string, unknown>]]
    local function resolveMoveName(move)
      local ok, facts = pcall(lookup, catalog, move)
      if ok and type(facts) == "table" and type(facts.name) == "string" then
        return facts.name --[[@as string]]
      end
      return nil
    end
    moveNameOf = resolveMoveName
  end
  self._timeline = BattleTimeline.new({
    moveName = moveNameOf,
  })
  local cases = nil
  if type(overrides.cases) == "table" then
    cases = overrides.cases
  end
  local ok, session = pcall(ApplicationPresentation.new, BattleScreenInterface.defaults(), cases)
  if not ok then
    self._mode = "failed"
    self._error = tostring(session)
    return self
  end
  self._session = session
  local measuredOk, measurement = pcall(self._measureDisplay)
  if measuredOk and measurement ~= nil then
    pcall(function()
      self._session:resolve(measurement, self:_snapshot())
    end)
    self._signature = (measurement --[[@as table<string, unknown>]]).signature --[[@as string?]]
  end
  return self
end

---@return table<string, unknown> internal semantic snapshot for resolvers and renderers
function BattleScreenState:_snapshot()
  local battlers = self._timeline:battlers()
  for _, battler in ipairs(battlers) do
    battler.shakeDx = self._timeline:shake(battler.combatant --[[@as integer]])
  end
  local roster = {}
  local latest = self._pendingFinal or self._latestView
  if type(latest) == "table" and type(latest.own) == "table" then
    for _, record in ipairs(latest.own) do
      if type(record) == "table" then
        roster[#roster + 1] = { slot = record.slot, hp = record.hp, maxHp = record.maxHp }
      end
    end
  end
  local foes = 1
  if type(latest) == "table" and type(latest.foes) == "table" then
    foes = math.max(1, #latest.foes)
  end
  return {
    mode = self._mode,
    selection = self._selection,
    armed = self._armed ~= nil and { scope = self._armed.scope, id = self._armed.id } or nil,
    requestId = self._request ~= nil and self._request.requestId or 0,
    message = self._notice or self._timeline:message(),
    battlers = battlers,
    commands = self:_commands(),
    moves = self:_moves(),
    partyRoster = roster,
    foeCount = foes,
    arrowFrame = self:_arrowFrame(),
    childIntent = self._child ~= nil and copyValue(self._child) or nil,
  }
end

---@return integer arrow cell for the current selection clock
function BattleScreenState:_arrowFrame()
  local total = 0
  for _, duration in ipairs(ARROW_DURATIONS) do
    total = total + duration
  end
  if total <= 0 then
    return 0
  end
  local tick = self._arrowTick % total
  local elapsed = 0
  for index, duration in ipairs(ARROW_DURATIONS) do
    if duration > 0 and tick < elapsed + duration then
      return index - 1
    end
    elapsed = elapsed + duration
  end
  return 0
end

---@return table<integer, table<string, unknown>> command facts with kernel refusal reasons
function BattleScreenState:_commands()
  local runEnabled = true
  local runReason = nil
  if self._options ~= nil and type(self._options.actors) == "table" then
    for _, actor in ipairs(self._options.actors) do
      if type(actor) == "table" and type(actor.choices) == "table" then
        for _, choice in ipairs(actor.choices) do
          if type(choice) == "table" and choice.role == "run" then
            runEnabled = choice.enabled == true
            if type(choice.reason) == "string" and choice.reason ~= "" then
              runReason = choice.reason
            end
          end
        end
      end
    end
  end
  local commands = {
    { id = "fight", enabled = true },
    { id = "bag", enabled = true },
    { id = "pokemon", enabled = true },
    { id = "run", enabled = runEnabled },
  }
  if runReason ~= nil then
    commands[4].reason = runReason
  end
  return commands
end

---@param actor table<string, unknown> option actor carrying the move fragments
---@return table<integer|string, table<string, unknown>> move choices keyed by slot
local function moveChoices(actor)
  local found = {} ---@type table<integer|string, table<string, unknown>>
  if type(actor.choices) == "table" then
    for _, choice in ipairs(actor.choices) do
      if type(choice) == "table" and choice.role == "move" and type(choice.id) == "string" then
        local slot = choice.id:match("^move:(%d+)$")
        if slot ~= nil then
          found[tonumber(slot)] = choice
        elseif choice.id == "move:struggle" then
          found.struggle = choice
        end
      end
    end
  end
  return found
end

---@return table<integer, table<string, unknown>> four native move slots plus the kernel struggle entry when present
function BattleScreenState:_moves()
  local slots = {}
  local struggle = nil
  if self._options ~= nil and type(self._options.actors) == "table" then
    for _, actor in ipairs(self._options.actors) do
      if type(actor) == "table" then
        local found = moveChoices(actor)
        for slot = 0, 3 do
          if found[slot] ~= nil and slots[slot + 1] == nil then
            local choice = found[slot] --[[@as table<string, unknown>]]
            local display = choice.display --[[@as table<string, unknown>]]
            local entry = {
              slot = slot,
              name = display.name,
              pp = display.pp,
              maxPp = display.maxPp,
              moveType = display.type,
              enabled = choice.enabled == true,
            } --[[@as table<string, unknown>]]
            if type(choice.reason) == "string" and choice.reason ~= "" then
              entry.reason = choice.reason
            end
            slots[slot + 1] = entry
          end
        end
        if found.struggle ~= nil and struggle == nil then
          local choice = found.struggle --[[@as table<string, unknown>]]
          local display = choice.display --[[@as table<string, unknown>]]
          struggle = {
            slot = 4,
            name = display.name,
            pp = 0,
            maxPp = 0,
            enabled = choice.enabled == true,
          } --[[@as table<string, unknown>]]
          if type(choice.reason) == "string" and choice.reason ~= "" then
            struggle.reason = choice.reason
          end
        end
      end
    end
  end
  for slot = 0, 3 do
    if slots[slot + 1] == nil then
      slots[slot + 1] = { slot = slot, enabled = false, reason = "empty" }
    end
  end
  if struggle ~= nil then
    slots[#slots + 1] = struggle
  end
  return slots
end

---@return table<string, unknown> detached public view for the current frame
function BattleScreenState:view()
  local snapshot = self:_snapshot()
  -- Displayed battlers stay player-first with only their visible
  -- facts: identities never leave this boundary, so unrevealed enemy
  -- reserves cannot leak through the detached copy.
  local battlers = {}
  for _, battler in ipairs(snapshot.battlers) do
    battlers[#battlers + 1] = {
      side = battler.side,
      hp = battler.hp,
      maxHp = battler.maxHp,
      visible = battler.visible,
    }
  end
  return {
    message = snapshot.message,
    messageId = self._timeline:messageId(),
    selection = self._selection,
    commands = copyValue(snapshot.commands),
    moves = copyValue(snapshot.moves),
    battlers = battlers,
    childIntent = snapshot.childIntent,
  }
end

---@return boolean interactive true once preparation and the opening finish their cues
function BattleScreenState:_ready()
  if self._disposed or self._mode == "failed" or self._mode == "disposed" then
    return false
  end
  if self._assets:state() ~= "ready" then
    return false
  end
  if self._child ~= nil then
    return false
  end
  return self._timeline:settled()
end

---@return table<string, unknown> detached lifecycle status with the published plan
function BattleScreenState:status()
  local plan = nil
  if self._session ~= nil then
    local ok, published = pcall(self._session.plan, self._session)
    if ok then
      plan = published
    end
  end
  return {
    mode = self._mode,
    ready = self:_ready(),
    request = copyValue(self._request),
    presentation = plan,
    error = self._error,
  }
end

---@return table<string, fun(...)> five closure operations sharing one idempotent release guard
function BattleScreenState:presentationPort()
  local screen = self
  ---@param plan table<string, unknown> runtime entry plan carrying the launch kind
  ---@return boolean acknowledged true once required resources resolve
  local function portEnter(plan)
    return screen:_portEnter(plan)
  end
  ---@param packet table<string, unknown> detached delivery packet
  local function portPresent(packet)
    screen:_portPresent(packet)
  end
  ---@return boolean interactive true once preparation and the opening finish their cues
  local function portReady()
    return screen:_ready()
  end
  ---@param plan table<string, unknown> runtime return plan
  ---@return boolean acknowledged true once the terminal narration is shown
  local function portLeave(plan)
    return screen:_portLeave(plan)
  end
  local function portDispose()
    screen:dispose()
  end
  return {
    enter = portEnter,
    present = portPresent,
    ready = portReady,
    leave = portLeave,
    dispose = portDispose,
  }
end

---@param plan table<string, unknown> runtime entry plan carrying the launch kind
---@return boolean acknowledged true once required resources resolve
function BattleScreenState:_portEnter(plan)
  if self._disposed or self._mode == "failed" then
    return false
  end
  if type(plan) == "table" and type(plan.kind) == "string" then
    self._kind = plan.kind --[[@as string]]
  end
  return self._assets:state() == "ready"
end

---@param view table<string, unknown> detached after view carrying portrait facts
---@return string[] sorted portrait selectors for the demand
local function selectorsOf(view)
  local selectors = {}
  local seen = {}
  local function add(record, fallback)
    local species = record.species
    local form = record.form or 0
    local selector = record.selector or fallback
    if type(species) == "string" and type(selector) == "string" then
      local key = species .. "/" .. tostring(form) .. "/" .. selector
      if not seen[key] then
        seen[key] = true
        selectors[#selectors + 1] = key
      end
    end
  end
  if type(view.own) == "table" then
    for _, record in ipairs(view.own) do
      if type(record) == "table" then
        add(record, "back")
      end
    end
  end
  if type(view.foes) == "table" then
    for _, record in ipairs(view.foes) do
      if type(record) == "table" then
        add(record, "front")
      end
    end
  end
  table.sort(selectors)
  return selectors
end

---@param packet table<string, unknown> detached delivery packet
function BattleScreenState:_portPresent(packet)
  if self._disposed or self._mode == "failed" then
    return
  end
  if type(packet) ~= "table" or packet.launchId ~= self._launchId then
    return
  end
  if type(packet.packetId) ~= "number" then
    self._mode = "failed"
    self._error = "malformed battle packet for launch " .. self._launchId
    return
  end
  if not self._timeline:present(packet) then
    return
  end
  self._openingReceived = true
  if type(packet.after) == "table" then
    self._latestView = packet.after
    self._assets:addSelectors(selectorsOf(packet.after))
  end
  for _, view in ipairs({ packet.before, packet.after }) do
    if type(view) == "table" and type(view.foes) == "table" then
      for _, foe in ipairs(view.foes) do
        if type(foe) == "table" and type(foe.name) == "string" and self._lastFoeName == nil then
          self._lastFoeName = foe.name --[[@as string]]
        end
      end
    end
  end
  if packet.request ~= nil then
    self._pendingRequest = copyValue(packet.request)
  end
  if packet.result ~= nil then
    self._pendingResult = copyValue(packet.result)
  end
  if type(packet.party) == "table" then
    self._partySnapshot = copyValue(packet.party)
  end
  if type(packet.inventory) == "table" then
    self._inventorySnapshot = copyValue(packet.inventory)
  end
  self._pendingFinal = copyValue(packet.after)
end

---@param plan table<string, unknown> runtime return plan
---@return boolean acknowledged true once the terminal narration is shown
function BattleScreenState:_portLeave(plan)
  local _ = plan
  if self._disposed or self._mode == "failed" then
    return false
  end
  -- Leave cover is permitted once the terminal narration shows; the
  -- mode stays on the outcome until host teardown so the shown result
  -- and the completed lifetime can be observed together.
  if self._outcomeShown or self._mode == "leaving" then
    return true
  end
  return false
end

-- Queues one raw input batch. Batches map through the published plan on
-- the next fixed update; after disposal every batch is dropped.
---@param events table<integer, table<string, unknown>> semantic input batch
function BattleScreenState:input(events)
  if self._disposed then
    return
  end
  assert(type(events) == "table", "battle input arrives as an event list")
  for _, event in ipairs(events) do
    assert(type(event) == "table" and type(event.type) == "string", "battle events need a type")
  end
  -- Pointer and key edges act through the published plan immediately
  -- so pressed art follows the press without waiting for the next
  -- tick; clocks still advance only on fixed updates. After disposal
  -- every batch is dropped.
  if self._session == nil or self._mode == "failed" then
    return
  end
  local measurement = self._measureDisplay()
  if measurement ~= nil then
    local signature = measurement.signature
    if signature ~= nil and signature ~= self._signature then
      self:cancelPointerCapture()
      self._signature = signature
    end
    pcall(function()
      self._session:resolve(measurement, self:_snapshot())
    end)
    local converted = self._session:mapInput(events, self:_snapshot())
    for _, event in ipairs(converted) do
      self:_consume(event)
    end
    pcall(function()
      self._session:resolve(measurement, self:_snapshot())
    end)
  end
end

-- Cancels a held press through both owners so a stale release never
-- activates after remeasure, submission, or disposal.
function BattleScreenState:cancelPointerCapture()
  if self._session ~= nil then
    local ok = pcall(self._session.cancelPointers, self._session)
    local _ = ok
  end
  self._armed = nil
  if self._subflows ~= nil then
    self._subflows:cancelPointerCapture()
  end
end

---@param armed table<string, unknown>? pressed control awaiting release
---@param control table<string, unknown>? activated control under sealing
---@return boolean sealed
local function sameControl(armed, control)
  return armed ~= nil and control ~= nil and armed.scope == control.scope and armed.id == control.id
end

---@param reason string? supplied refusal reason under display
function BattleScreenState:_refuse(reason)
  if type(reason) == "string" and reason ~= "" then
    self._notice = reason
  else
    self._notice = "That choice is unavailable."
  end
end

---@param options table<string, unknown> decision options carrying the prepared fragments
---@param role string fragment role under lookup
---@return table<string, unknown>? prepared choice fragment, nil when absent or refused
local function fragmentFor(options, role)
  if type(options.actors) ~= "table" then
    return nil
  end
  for _, actor in ipairs(options.actors) do
    if type(actor) == "table" and type(actor.choices) == "table" then
      for _, choice in ipairs(actor.choices) do
        if type(choice) == "table" and choice.role == role and choice.enabled == true then
          return choice.choice --[[@as table<string, unknown>]]
        end
      end
    end
  end
  return nil
end

---@param options table<string, unknown> decision options carrying the prepared fragments
---@param id string move fragment identity under lookup
---@return table<string, unknown>? prepared choice fragment with its enabled flag
local function moveFragment(options, id)
  if type(options.actors) ~= "table" then
    return nil
  end
  for _, actor in ipairs(options.actors) do
    if type(actor) == "table" and type(actor.choices) == "table" then
      for _, choice in ipairs(actor.choices) do
        if type(choice) == "table" and choice.id == id then
          return choice
        end
      end
    end
  end
  return nil
end

-- Dispatches one semantic cue through the bound one-argument sink. A
-- rejected cue fails the launch once with launch and role context; the
-- envelope then reports the failed screen and later ticks replay
-- nothing because the timeline queue already drained exactly once.
---@param role string semantic sound role under dispatch
---@return boolean played true when the sink accepted the cue
function BattleScreenState:_playCue(role)
  local ok, err = pcall(self._audio.play, role)
  if ok then
    return true
  end
  if self._mode ~= "failed" then
    self._mode = "failed"
    self._error = "battle sound failed for launch "
      .. self._launchId
      .. ": role "
      .. tostring(role)
      .. ": "
      .. tostring(err)
  end
  return false
end

---@param fragment table<string, unknown> prepared choice fragment under submission
function BattleScreenState:_seal(fragment)
  assert(self._request ~= nil and self._options ~= nil, "replies answer the open request")
  local reply = {
    requestId = self._request.requestId,
    epoch = self._request.epoch,
    controller = self._request.controller,
    choices = { copyValue(fragment) },
  }
  local ok, accepted, failure = pcall(self._submit, reply)
  if not ok then
    self._mode = "failed"
    self._error = "battle submission failed for launch " .. self._launchId .. ": " .. tostring(accepted)
    return
  end
  if accepted ~= true then
    local reason = nil
    if type(failure) == "table" then
      reason = failure.message or failure.reason
    end
    self:_refuse(type(reason) == "string" and reason or nil)
    return
  end
  self._notice = nil
  -- The answered request is no longer open; its options stay cached
  -- for display until the next delivery replaces them.
  self._request = nil
  self._mode = "awaiting_resolution"
  self:cancelPointerCapture()
  self:_playCue("select")
end

-- Builds the child intent for the mirrored open request: battle-owned
-- snapshots and the projected options travel with the launch and request
-- identity so every child result binds back to this decision.
---@param kind string child kind under opening
---@param purpose string selection purpose under opening
---@param cancellable boolean cancel permission under opening
---@return table<string, unknown>? child intent, nil without an open request
function BattleScreenState:_childIntent(kind, purpose, cancellable)
  if self._request == nil or self._options == nil then
    return nil
  end
  return {
    kind = kind,
    purpose = purpose,
    launchId = self._launchId,
    requestId = self._request.requestId,
    epoch = self._request.epoch,
    controller = self._request.controller,
    cancellable = cancellable,
    request = copyValue(self._request),
    options = copyValue(self._options),
    party = copyValue(self._partySnapshot or {}),
    inventory = copyValue(self._inventorySnapshot or {}),
  }
end

-- Opens a voluntary child over the open command decision. A child that
-- cannot open keeps the command request with a visible refusal instead
-- of a half-open selection.
---@param kind string child kind under opening
---@param purpose string selection purpose under opening
function BattleScreenState:_openVoluntaryChild(kind, purpose)
  local intent = self:_childIntent(kind, purpose, true)
  if intent == nil then
    return
  end
  local ok, failure = self._subflows:open(intent)
  if not ok then
    self:_refuse(type(failure) == "string" and failure or nil)
    return
  end
  self._child = { kind = kind, cancellable = true, purpose = purpose, requestId = intent.requestId }
  self._mode = "child"
  self._notice = nil
end

---@param id string command identity under activation
function BattleScreenState:_activateCommand(id)
  if id == "fight" then
    self._mode = "moves"
    self._selection = self:_defaultMoveSelection()
    self._notice = nil
  elseif id == "bag" then
    self:_openVoluntaryChild("bag", "bag")
  elseif id == "pokemon" then
    self:_openVoluntaryChild("party", "switch")
  elseif id == "run" then
    local fragment = self._options ~= nil and fragmentFor(self._options, "run") or nil
    if fragment == nil then
      self:_refuse(self:_runReason())
    else
      self:_seal(fragment)
    end
  end
end

---@return string? kernel refusal reason for flight, nil when flight is legal
function BattleScreenState:_runReason()
  if self._options ~= nil and type(self._options.actors) == "table" then
    for _, actor in ipairs(self._options.actors) do
      if type(actor) == "table" and type(actor.choices) == "table" then
        for _, choice in ipairs(actor.choices) do
          if type(choice) == "table" and choice.role == "run" and type(choice.reason) == "string" then
            return choice.reason --[[@as string]]
          end
        end
      end
    end
  end
  return nil
end

---@return string first enabled move selection, falling back to the first slot
function BattleScreenState:_defaultMoveSelection()
  for _, move in ipairs(self:_moves()) do
    if move.enabled == true and type(move.slot) == "number" and move.slot < 4 then
      return "move:" .. tostring(move.slot)
    end
  end
  return "move:0"
end

---@param id string move control identity under activation
---@param armed table<string, unknown>? pressed control behind the release
function BattleScreenState:_activateMove(id, armed)
  if id == "cancel" then
    self._mode = "command"
    self._selection = "fight"
    self._notice = nil
    return
  end
  local entry = moveFragment(self._options or {}, id)
  if entry == nil or entry.enabled ~= true then
    local reason = (entry ~= nil and type(entry.reason) == "string") and entry.reason or "empty"
    self:_refuse(reason --[[@as string]])
    return
  end
  -- A matched release whose press began on the already-focused slot
  -- seals the projected fragment exactly like semantic confirm; any
  -- other release only moves focus.
  if armed ~= nil and armed.focused == true and self._selection == id then
    self:_submitMove(entry)
    return
  end
  self._selection = id
  self._notice = nil
end

---@param control table<string, unknown> sealed control under dispatch
---@param armed table<string, unknown>? pressed control behind the release
function BattleScreenState:_sealControl(control, armed)
  if self._mode == "command" then
    self:_activateCommand(control.id --[[@as string]])
  elseif self._mode == "moves" then
    self:_activateMove(control.id --[[@as string]], armed)
  end
end

-- Checks one staged child result against the mirrored open request.
-- Only the current launch, request, epoch, and controller seal.
---@param identity table<string, unknown> staged result or reply identity under validation
---@return boolean current true for the mirrored open request
function BattleScreenState:_childIdentityMatches(identity)
  if self._request == nil then
    return false
  end
  if type(identity.launchId) == "string" and identity.launchId ~= self._launchId then
    return false
  end
  return identity.requestId == self._request.requestId
    and identity.epoch == self._request.epoch
    and identity.controller == self._request.controller
end

-- Collects one staged child result: a bound choice seals through the
-- accepted-choice boundary, a permitted cancellation returns to the
-- mirrored request, and a stale identity discards without sealing. A
-- refused seal keeps the child open for another selection.
function BattleScreenState:_pollChild()
  local result = self._subflows:takeResult()
  if result == nil then
    local notice = self._subflows:status().notice
    if type(notice) == "string" and notice ~= "" then
      self._notice = notice
    end
    return
  end
  if result.kind == "cancelled" then
    if not self:_childIdentityMatches(result) then
      return
    end
    self._subflows:closeChild()
    self._child = nil
    self._notice = nil
    if self._request ~= nil then
      self._mode = self:_modeForOptions(self._options)
    else
      self._mode = "command"
    end
    return
  end
  if result.kind == "choice" then
    local reply = result.reply --[[@as table<string, unknown>]]
    if not self:_childIdentityMatches(reply) then
      self._subflows:closeChild()
      self._child = nil
      self._notice = "The selection expired."
      if self._request ~= nil then
        self._mode = self:_modeForOptions(self._options)
      else
        self._mode = "command"
      end
      return
    end
    local fragment = reply.choices --[[@as table<integer, table<string, unknown>>]]
    self:_seal(copyValue(fragment[1]))
    if self._mode == "awaiting_resolution" then
      self._subflows:closeChild()
      self._child = nil
    end
  end
end

---@param event table<string, unknown> mapped semantic input under consumption
function BattleScreenState:_consume(event)
  local eventType = event.type
  if eventType == "pointer_cancel" then
    self._armed = nil
    self._subflows:cancelPointerCapture()
    return
  end
  if self._mode == "child" and self._subflows:status().active then
    if eventType == "confirm" or eventType == "cancel" or eventType == "navigate" then
      self._subflows:update({ event })
      self:_pollChild()
    end
    return
  end
  if eventType == "battle_press" then
    if self._mode == "command" or self._mode == "moves" then
      self._armed = { scope = event.control.scope, id = event.control.id, pointerId = event.pointerId }
      if event.control.scope == "command" then
        self._selection = event.control.id --[[@as string]]
      elseif event.control.scope == "moves" then
        local id = event.control.id --[[@as string]]
        if id ~= "cancel" then
          local entry = moveFragment(self._options or {}, id)
          if entry ~= nil and entry.enabled == true then
            -- Remember whether the press began on the focused slot so
            -- the matched release can tell a focusing tap from a seal.
            self._armed.focused = (self._selection == id)
            self._selection = id
          end
        end
      end
    end
    return
  end
  if eventType == "battle_slide" then
    if
      not sameControl(self._armed, event.control --[[@as table<string, unknown>?]])
    then
      self._armed = nil
    end
    return
  end
  if eventType == "battle_activate" then
    local armed = self._armed
    self._armed = nil
    if
      sameControl(armed, event.control --[[@as table<string, unknown>?]])
    then
      self:_sealControl(event.control, armed)
    end
    return
  end
  if eventType == "confirm" then
    self:_confirm()
    return
  end
  if eventType == "cancel" then
    self:_cancel()
    return
  end
  if eventType == "navigate" then
    self:_navigate(event.direction --[[@as string]])
    return
  end
end

function BattleScreenState:_confirm()
  if self._mode == "command" and type(self._selection) == "string" then
    self:_activateCommand(self._selection --[[@as string]])
  elseif self._mode == "moves" and type(self._selection) == "string" then
    local selection = self._selection --[[@as string]]
    if selection == "cancel" then
      self:_activateMove("cancel")
    else
      local entry = moveFragment(self._options or {}, selection)
      if entry == nil or entry.enabled ~= true then
        local reason = (entry ~= nil and type(entry.reason) == "string") and entry.reason or "empty"
        self:_refuse(reason --[[@as string]])
      else
        self:_submitMove(entry)
      end
    end
  elseif self._mode == "narration" or self._mode == "intro" then
    self._timeline:ack()
  elseif self._mode == "outcome" then
    self._timeline:ack()
    self._outcomeAcked = true
  end
end

---@param entry table<string, unknown> accepted move option under sealing
function BattleScreenState:_submitMove(entry)
  -- Every enabled move option already carries its complete legal
  -- fragment: the choice seals detached and unchanged, whatever target
  -- kind the kernel projected, with no target rewrite.
  self:_seal(copyValue(entry.choice) --[[@as table<string, unknown>]])
end

function BattleScreenState:_cancel()
  if self._mode == "moves" then
    self._mode = "command"
    self._selection = "fight"
    self._notice = nil
  elseif self._mode == "child" and self._child ~= nil then
    if self._child.cancellable == true then
      self._child = nil
      self._notice = nil
      if self._request ~= nil then
        self._mode = self:_modeForOptions(self._options)
      else
        self._mode = "command"
      end
    else
      self:_refuse("That choice cannot be cancelled.")
    end
  end
end

---@param direction string? navigation direction under selection
function BattleScreenState:_navigate(direction)
  local table_ = nil
  if self._mode == "command" then
    table_ = COMMAND_NAV
  elseif self._mode == "moves" then
    table_ = MOVE_NAV
  end
  if table_ == nil or type(self._selection) ~= "string" then
    return
  end
  local links = table_[
    self._selection --[[@as string]]
  ]
  if
    links ~= nil
    and type(direction) == "string"
    and type(links[
      direction --[[@as string]]
    ]) == "string"
  then
    self._selection = links[
      direction --[[@as string]]
    ]
  end
end

---@param options table<string, unknown>? decision options carrying the actor kinds
---@return string mode for the request actor kind
function BattleScreenState:_modeForOptions(options)
  if type(options) == "table" and type(options.actors) == "table" then
    for _, actor in ipairs(options.actors) do
      if type(actor) == "table" and (actor.kind == "replacement" or actor.kind == "learn_move") then
        return "child"
      end
    end
  end
  return "command"
end

---@return string product-owned terminal narration for the result word
function BattleScreenState:_outcomeText()
  local word = self._pendingResult ~= nil and self._pendingResult.word or nil
  local foeName = self._lastFoeName
  if word == "win" then
    if type(foeName) == "string" then
      return "Defeated the foe " .. foeName .. "!"
    end
    return "The foe was defeated!"
  elseif word == "loss" then
    return "Your party can no longer battle!"
  elseif word == "flee" then
    return "Got away safely!"
  elseif word == "capture" then
    if type(foeName) == "string" then
      return "Gotcha! " .. foeName .. " was caught!"
    end
    return "Gotcha! The catch succeeded!"
  elseif word == "draw" then
    return "The battle ended in a draw."
  end
  return "The battle ended."
end

-- Applies the retained delivery once its cues drain: reconcile exact
-- final facts, then expose the next request or the terminal result.
-- Exposure waits for a fully settled tick so the finished frame
-- presents first: the next request never appears before, or on the
-- same tick as, the earlier cues finishing.
---@param settledTick boolean true when no cue played on this update
function BattleScreenState:_drain(settledTick)
  if not self._timeline:settled() then
    return
  end
  if self._pendingFinal ~= nil then
    self:_reconcile(self._pendingFinal)
    self._pendingFinal = nil
  end
  if not settledTick then
    return
  end
  if self._pendingResult ~= nil then
    self._timeline:announce(self:_outcomeText(), true)
    self._pendingResult = nil
    self._pendingRequest = nil
    self._request = nil
    self._options = nil
    self._outcomeShown = true
    self._mode = "outcome"
    self._notice = nil
    self._child = nil
    return
  end
  if self._mode == "child" and self._subflows:status().active then
    return
  end
  if self._pendingRequest ~= nil then
    local request = self._pendingRequest --[[@as table<string, unknown>]]
    self._pendingRequest = nil
    self._request = request
    self._options = request.options --[[@as table<string, unknown>?]]
    self._notice = nil
    local mode = self:_modeForOptions(self._options)
    self._mode = mode
    if mode == "command" then
      self._selection = "fight"
    elseif mode == "child" then
      local kind = "learn"
      local purpose = "learn"
      if type(self._options) == "table" and type(self._options.actors) == "table" then
        for _, actor in ipairs(self._options.actors) do
          if type(actor) == "table" and actor.kind == "replacement" then
            kind = "party"
            purpose = "replacement"
          end
        end
      end
      local intent = self:_childIntent(kind, purpose, false)
      local ok = false
      ---@type string?
      local failure = "the battle screen mirrors its request"
      if intent ~= nil then
        ok, failure = self._subflows:open(intent)
      end
      if not ok then
        self._mode = "failed"
        self._error = type(failure) == "string" and failure
          or "the requested child failed to open for launch " .. self._launchId
        self._child = nil
        return
      end
      self._child = { kind = kind, cancellable = false, purpose = purpose, requestId = request.requestId }
      self._selection = nil
    end
  end
end

---@param view table<string, unknown> detached final view under reconciliation
function BattleScreenState:_reconcile(view)
  local known = {}
  for _, id in ipairs(self._timeline:order()) do
    known[id] = true
  end
  local function apply(records)
    if type(records) ~= "table" then
      return
    end
    for _, record in ipairs(records) do
      if type(record) == "table" and type(record.combatant) == "number" then
        self._timeline:reconcileBattler(record --[[@as table<string, unknown>]], known[
          record.combatant --[[@as integer]]
        ] == true)
      end
    end
  end
  apply(view.own)
  apply(view.foes)
end

-- One fixed update: prepare, cancel held presses across remeasure, map
-- one queued batch batch per waiting slot in order, advance the cue
-- player on accepted time, then reconcile drained deliveries and
-- re-resolve the published plan.
---@param dt number accepted presentation seconds
function BattleScreenState:updateFixed(dt)
  if self._disposed then
    return
  end
  assert(type(dt) == "number" and dt == dt and dt >= 0, "battle updates take accepted seconds")
  self._assets:update()
  if self._assets:state() == "failed" then
    self._mode = "failed"
    self._error = self._assets:error()
  end
  local measurement = self._measureDisplay()
  assert(measurement ~= nil, "the battle screen requires current display facts")
  local signature = measurement.signature
  if signature ~= nil and signature ~= self._signature then
    if self._signature ~= nil then
      self:cancelPointerCapture()
    end
    self._signature = signature
  end
  if self._session ~= nil and self._mode ~= "failed" then
    self._session:resolve(measurement, self:_snapshot())
  end
  if self._mode ~= "failed" then
    if not self._introBuilt and self._openingReceived and self._assets:state() == "ready" then
      local opening = self._latestView
      if opening ~= nil then
        self._timeline:reset(opening)
        self._timeline:intro(opening, self._kind ~= "trainer")
        self._introBuilt = true
        if self._mode == "preparing" then
          self._mode = "intro"
        end
      end
    end
    ---@param key string image key under availability probe
    ---@return boolean available true while the preparation services resolve the key
    local function isAvailable(key)
      return self._assets:drawable(key) ~= nil
    end
    local hadCues = self._timeline:busy()
    self._timeline:update(dt, isAvailable)
    for _, name in ipairs(self._timeline:drainSounds()) do
      if not self:_playCue(name) then
        break
      end
    end
    self:_drain(not hadCues and self._timeline:settled())
    if self._mode == "intro" and self._introBuilt and self._timeline:settled() and self._pendingRequest == nil then
      self._mode = "narration"
    end
  end
  if self._mode == "child" and self._subflows:status().active then
    self._subflows:tick()
    self:_pollChild()
  end
  if self._mode == "command" or self._mode == "moves" or self._mode == "target" then
    self._arrowTick = self._arrowTick + 1
  else
    self._arrowTick = 0
  end
  if self._session ~= nil then
    pcall(function()
      self._session:resolve(measurement, self:_snapshot())
    end)
  end
end

-- Renders the published plan with the displayed view. Read-only: never
-- advances clocks, consumes input, submits, plays a sound, or mutates
-- health. After disposal or before the first plan it draws nothing.
---@param resources table<string, unknown> draw resources carrying the host graphics
function BattleScreenState:draw(resources)
  if self._disposed or self._session == nil then
    return
  end
  assert(type(resources) == "table" and resources.graphics ~= nil, "battle drawing needs its host graphics")
  local ok, plan = pcall(self._session.plan, self._session)
  if not ok or plan == nil then
    return
  end
  local owned = {
    graphics = resources.graphics,
    text = self._text,
    windows = self._windows,
    assets = self._assets,
    frameKey = self._assets:frameKey(),
    sceneImageKey = self._assets:sceneImage(),
  }
  -- The render runs under a bounded guard with the pushed scope owned
  -- here: a production-data render failure becomes failed with context
  -- instead of an unhandled host error, and the scope always pops so the
  -- host observes no graphics leak. Draws never substitute, never paint
  -- a blank success, and never raise.
  local snapshot = self:_snapshot()
  local graphics = resources.graphics
  graphics.push("all")
  local renderOk, renderErr = pcall(plan.render, owned, snapshot, plan)
  graphics.pop()
  if not renderOk then
    self._mode = "failed"
    self._error = "battle render failed for launch " .. self._launchId .. ": " .. tostring(renderErr)
  end
end

-- Idempotent release of the launch lifetime: owned handles release
-- exactly once, queued input is discarded, and borrowed field services
-- stay usable.
function BattleScreenState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._mode = "disposed"
  self:cancelPointerCapture()
  self._queue = {}
  if self._subflows ~= nil then
    self._subflows:dispose()
  end
  if self._assets ~= nil then
    self._assets:dispose()
  end
  if self._session ~= nil then
    self._session:dispose()
  end
end

return BattleScreenState
