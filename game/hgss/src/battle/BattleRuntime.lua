-- Application battle lifetime owner. One BattleRuntime runs one launched
-- battle from acquisition through return: preparing (presentation entry and
-- session build), entering, running (the live kernel session), resolving
-- (exactly-once commit through the battle committer), postbattle,
-- returning, then complete. Failures report through the failed phase and
-- never publish.
--
-- The runtime freezes nothing itself; the field owner pauses field input
-- while this lifetime is active. Simulation and presentation stay
-- independent: the session advances on update regardless of presentation
-- acknowledgements, while phase transitions wait for entry/return
-- readiness. Delayed readiness never consumes combat randomness and never
-- regenerates the prepared encounter: the scenario is copied once at
-- construction and the session is built once in preparing.
--
-- Decisions: requests owned by the "player" controller (and any
-- non-opponent controller) are exposed through status().request and
-- answered through submit; wild and trainer opponents answer through
-- their bound opponent controllers inside update. Invalid replies return
-- the session's typed input error without consuming randomness or
-- resources. A battle with no scenario runs the lifecycle only
-- (presentation and phase ownership without simulation or publication); it
-- never commits and never reports a receipt.
--
-- Combat executes through the kernel's scripted decision point: strikes
-- deal the kernel's scripted damage over its bounded round budget, and a
-- battle that reaches the bound with both sides standing settles as a
-- draw. No victory is ever invented: only a fainted enemy side reports a
-- win. Committed party health writeback carries the executed damage into
-- the live party through the committer's staged batch.

local BattleSession = require("libs.battle.src.BattleSession")
local ContentBuilder = require("libs.content.src.ContentBuilder")
local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
local BattleContent = require("libs.battle.src.BattleContent")
local BattleErrors = require("libs.battle.src.errors")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local BattleTask = require("libs.hgss.src.script.tasks.BattleTask")
local HgssBattleCommitter = require("libs.hgss.src.battle.HgssBattleCommitter")
local HgssBattleRewards = require("libs.hgss.src.battle.HgssBattleRewards")
local HgssOpponentControllers = require("libs.hgss.src.battle.HgssOpponentControllers")
local HgssTrainerAi = require("libs.hgss.src.battle.HgssTrainerAi")

---@class BattlePresentationPort
---@field enter fun(plan: table<string, unknown>): boolean
---@field present fun(frame: table<string, unknown>)
---@field leave fun(plan: table<string, unknown>): boolean
---@field dispose fun()

---@class BattlePartyOwner
---@field partyRevision fun(self: BattlePartyOwner): integer

---@class BattleBoundController
---@field kind string
---@field ai HgssTrainerAi?

---@class BattleRuntimeArgs
---@field request table<string, unknown> launch request carrying its identity and kind
---@field scenario table<string, unknown>? detached battle setup copied once at construction
---@field presentation table<string, unknown>? battle presentation port, headless when absent
---@field party table<string, unknown>? live party owner staging updates and captures
---@field bag table<string, unknown>? live bag owner flushing planned consumption
---@field bagDeltas table<integer, table<string, unknown>>? planned take/add deltas the committer applies
---@field dex table<string, unknown>? live dex knowledge staging sightings and catches
---@field roamer table<string, unknown>? roamer battle record with its owner, key, and revision
---@field player table<string, unknown>? player money facts with their validation context
---@field prize table<string, unknown>? trainer prize inputs with their class and base payout
---@field captures table<integer, table<string, unknown>>? battle capture results in committer shape
---@field trainerProgram table<string, unknown>? bound selection program for trainer controllers
---@field seed integer? unsigned 32-bit stream seed, derived from the launch identity when absent

---@class BattleRuntime
---@field _request { id: string, kind: string, payload: table<string, unknown> }
---@field _scenario table<string, unknown>?
---@field _presentation BattlePresentationPort
---@field _party BattlePartyOwner?
---@field _bag table<string, unknown>?
---@field _bagDeltas table<integer, table<string, unknown>>?
---@field _dex table<string, unknown>?
---@field _roamer table<string, unknown>?
---@field _player table<string, unknown>?
---@field _prize table<string, unknown>?
---@field _captures table<integer, table<string, unknown>>?
---@field _trainerProgram table<string, unknown>?
---@field _seed integer
---@field _phase string
---@field _task table<string, unknown>?
---@field _content table<string, unknown>?
---@field _session BattleSession?
---@field _selection table<string, unknown>?
---@field _controllers table<string, BattleBoundController>
---@field _answered table<string, boolean>?
---@field _openRequest table<string, unknown>?
---@field _outcome table<string, unknown>?
---@field _prepared table<string, unknown>?
---@field _receipt table<string, unknown>?
---@field _result string?
---@field _sourceResult integer
---@field _postTicks integer
---@field _runTicks integer
---@field _partyRevision integer?
---@field _error string?
---@field _disposed boolean
local BattleRuntime = {}
BattleRuntime.__index = BattleRuntime

BattleRuntime.PLAYER_CONTROLLER = "player"
BattleRuntime.WILD_CONTROLLER = "wild"
BattleRuntime.TRAINER_PREFIX = "trainer:"

BattleRuntime.KINDS = { wild = true, trainer = true, scripted = true, scenario = true }

-- Live battles indexed by their shared live party owner. The field input
-- gate consults this index so player input never leaks through to the field
-- while a battle constructed directly from the live owners (rather than
-- through the field runtime) owns decisions. Entries are keyed by owner
-- identity and removed at settlement or disposal, so unrelated fields
-- sharing a process never freeze each other; a battle without a live party
-- registers nothing. This is an owner index, not a singleton: many
-- lifetimes coexist and the field runtime's own battles bypass it through
-- their direct handle.
local ACTIVE_BY_OWNER = {}

---@param battle BattleRuntime
local function registerActive(battle)
  local party = battle._party
  if party ~= nil then
    ACTIVE_BY_OWNER[party] = battle
  end
end

---@param battle BattleRuntime
local function unregisterActive(battle)
  local party = battle._party
  if party ~= nil and ACTIVE_BY_OWNER[party] == battle then
    ACTIVE_BY_OWNER[party] = nil
  end
end

-- Reports whether an unsettled battle owns decisions for one live party
-- owner. Settlement and disposal release the owner.
---@param owner table<string, unknown>?
---@return boolean
function BattleRuntime.isActiveFor(owner)
  if owner == nil then
    return false
  end
  local battle = ACTIVE_BY_OWNER[owner]
  if battle == nil then
    return false
  end
  return not battle:isReleased()
end

-- Operation budget per update pump: enough to settle a waiting batch and
-- its commit without spinning the whole battle inside one field tick.
BattleRuntime.ADVANCE_BUDGET = 64

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

---@param text string
---@return integer stable seed bound to the launch identity
local function hashIdentity(text)
  local hash = 0x811C9DC5
  for index = 1, #text do
    hash = (hash * 33 + string.byte(text, index)) % 0x100000000
  end
  return hash
end

-- The default headless presentation port: acknowledges entry and return
-- immediately while recording nothing. Production presentation (the later
-- UI) may instead remain waiting, which holds the lifecycle in
-- entering/returning without touching simulation.
local function ackEntry(_)
  return true
end

local function ignoreFrame(_) end

local function ackLeave(_)
  return true
end

local function releasePort() end

---@return BattlePresentationPort
local function defaultPresentation()
  return { enter = ackEntry, present = ignoreFrame, leave = ackLeave, dispose = releasePort }
end

---@param request unknown
local function checkRequest(request)
  assert(type(request) == "table", "battle launches require a request record")
  local launch = request --[[@as table<string, unknown>]]
  assert(type(launch.id) == "string" and launch.id ~= "", "battle launches require a launch identity")
  assert(BattleRuntime.KINDS[launch.kind] == true, "battle launches name a known kind")
  assert(type(launch.payload) == "table", "battle launches carry their payload record")
  local payload = launch.payload --[[@as table<string, unknown>]]
  if launch.kind == "wild" then
    assert(type(payload.species) == "string" and payload.species ~= "", "wild launches name their species")
    assert(
      type(payload.level) == "number" and payload.level % 1 == 0 and payload.level >= 1 and payload.level <= 100,
      "wild launches carry their level in 1..100"
    )
  elseif launch.kind == "trainer" then
    local single = payload.trainer
    local several = payload.trainers
    assert(
      (type(single) == "string" and single ~= "") or (type(several) == "table" and #several > 0),
      "trainer launches name their trainer"
    )
  end
end

---@param args BattleRuntimeArgs construction record carrying the optional consequence inputs
local function checkConsequenceInputs(args)
  if args.bag ~= nil then
    assert(type(args.bag) == "table", "battle bag staging needs its live bag owner")
    assert(type(args.bag.prepareInventoryChanges) == "function", "the bag owner stages inventory changes")
    assert(type(args.bag.revision) == "function", "the bag owner carries its revision")
  end
  if args.bagDeltas ~= nil then
    assert(type(args.bagDeltas) == "table", "planned bag consumption arrives as a delta array")
  end
  if args.dex ~= nil then
    assert(type(args.dex) == "table", "battle dex staging needs its live knowledge owner")
    assert(type(args.dex.prepareChanges) == "function", "the dex owner stages knowledge changes")
  end
  if args.roamer ~= nil then
    assert(type(args.roamer) == "table", "roamer outcomes name their owning state")
    assert(type(args.roamer.owner) == "table", "roamer outcomes commit through their owner")
    assert(type(args.roamer.key) == "string" and args.roamer.key ~= "", "roamer outcomes name their record")
    assert(type(args.roamer.expectedRevision) == "number", "roamer outcomes carry their revision")
  end
  if args.player ~= nil then
    assert(type(args.player) == "table", "player money facts arrive as a record")
    assert(type(args.player.record) == "table", "player money facts carry their record")
    assert(type(args.player.context) == "table", "player money facts carry their context")
  end
  if args.prize ~= nil then
    assert(type(args.prize) == "table", "trainer prize inputs arrive as a record")
  end
  if args.captures ~= nil then
    assert(type(args.captures) == "table", "battle captures arrive as an array")
  end
end

---@param presentation unknown
---@return BattlePresentationPort validated presentation port
local function checkPresentation(presentation)
  if presentation == nil then
    return defaultPresentation()
  end
  assert(type(presentation) == "table", "battle presentation stays a record")
  local port = presentation --[[@as BattlePresentationPort]]
  assert(type(port.enter) == "function", "battle presentation implements enter")
  assert(type(port.present) == "function", "battle presentation implements present")
  assert(type(port.leave) == "function", "battle presentation implements leave")
  assert(type(port.dispose) == "function", "battle presentation implements dispose")
  return port
end

-- Application battle lifetime owner. The request shapes are validated here
-- (a malformed launch is a programming fault and raises); scenario and
-- session work happens in preparing so build failures report through the
-- failed phase instead of raising. Consequence inputs beyond the request
-- are all optional: the live bag and dex owners plus planned bag
-- consumption, the live roamer battle record, the player money facts with
-- the trainer prize inputs, and the battle capture results. Battle code
-- never mutates a live owner directly: every staged consequence commits
-- through the battle committer at resolution.
---@param args BattleRuntimeArgs construction record carrying the request and consequence inputs
---@return BattleRuntime
function BattleRuntime.new(args)
  assert(type(args) == "table", "battle construction requires an argument record")
  checkRequest(args.request)
  checkConsequenceInputs(args)
  local request = args.request --[[@as table<string, unknown>]]
  local presentation = checkPresentation(args.presentation)
  if args.seed ~= nil then
    assert(
      type(args.seed) == "number" and args.seed % 1 == 0 and args.seed >= 0 and args.seed <= 0xFFFFFFFF,
      "battle seeds stay unsigned 32-bit integers"
    )
  end
  local self = setmetatable({
    _request = { id = request.id, kind = request.kind, payload = copyValue(request.payload) },
    _scenario = args.scenario ~= nil and copyValue(args.scenario) or nil,
    _presentation = presentation,
    _party = args.party,
    _bag = args.bag,
    _bagDeltas = args.bagDeltas ~= nil and copyValue(args.bagDeltas) or nil,
    _dex = args.dex,
    _roamer = args.roamer,
    _player = args.player,
    _prize = args.prize ~= nil and copyValue(args.prize) or nil,
    _captures = args.captures ~= nil and copyValue(args.captures) or nil,
    _trainerProgram = args.trainerProgram,
    _seed = args.seed or hashIdentity(request.id --[[@as string]]),
    _phase = "preparing",
    _task = nil,
    _content = nil,
    _session = nil,
    _selection = nil,
    _controllers = {},
    _openRequest = nil,
    _outcome = nil,
    _prepared = nil,
    _receipt = nil,
    _result = nil,
    _sourceResult = BattleTask.SOURCE_NOT_WON,
    _postTicks = 0,
    _runTicks = 0,
    _partyRevision = nil,
    _error = nil,
    _disposed = false,
  }, BattleRuntime)
  if args.party ~= nil then
    local party = args.party --[[@as BattlePartyOwner]]
    self._partyRevision = party:partyRevision()
  end
  self._task = BattleTask.start(
    { launchId = self._request.id, kind = self._request.kind, details = self._request.payload },
    { services = {} }
  )
  registerActive(self)
  return self
end

---@return table<string, unknown> executable content for the kernel's decision point
function BattleRuntime:_executableContent()
  if self._content == nil then
    local builder = ContentBuilder.new()
    local behaviors = BattleBehaviorBuilder.new()
    -- The kernel executes exactly one decision point; later battle phases
    -- register their own rulesets through the same construction boundary.
    -- Full native behavior arrives with those phases, so this bundle
    -- carries only the executable binding, never test vocabulary.
    behaviors:registerRuleset(
      BattleSession.EXECUTABLE_RULESET,
      { key = BattleSession.EXECUTABLE_RULESET, chart = BattleSession.EXECUTABLE_RULESET },
      "battle-runtime"
    )
    -- The field scenario sources name their application formats; each one
    -- resolves through this registered policy instead of a guessed
    -- vocabulary, so a misspelled production key fails at construction.
    for _, formatKey in ipairs({ "wild-single", "single", "double" }) do
      behaviors:registerFormat(formatKey, { key = formatKey }, "battle-runtime")
    end
    self._content = BattleContent.new(builder:freeze(), behaviors:freeze())
  end
  assert(self._content ~= nil, "executable content builds once")
  return self._content
end

-- Opponent selection draws come from a dedicated stream seeded off the
-- launch identity: controller decisions stay deterministic without
-- shifting the combat draw stream the kernel consumes per strike.
---@return table<string, unknown> labeled selection stream over a dedicated generator
function BattleRuntime:_selectionStream()
  if self._selection == nil then
    local generator = Lcrng.new(self._seed)
    local function drawSelection(_, _, _)
      return generator:nextU16()
    end
    self._selection = { nextU16 = drawSelection }
  end
  assert(self._selection ~= nil, "the selection stream builds once")
  return self._selection
end

---@param participant table<string, unknown>
---@return table<string, unknown>? bound program for trainer controllers
function BattleRuntime:_trainerProgramFor(participant)
  local context = participant.context
  if type(context) == "table" and type(context.program) == "table" then
    return context.program --[[@as table<string, unknown>]]
  end
  if self._trainerProgram ~= nil then
    return self._trainerProgram
  end
  return nil
end

---@param controller string
---@return BattleBoundController answering controller for an owned request
function BattleRuntime:_controllerFor(controller)
  local cached = self._controllers[controller]
  if cached ~= nil then
    return cached
  end
  local bound
  if controller == BattleRuntime.WILD_CONTROLLER then
    bound = { kind = "wild" }
  elseif controller:sub(1, #BattleRuntime.TRAINER_PREFIX) == BattleRuntime.TRAINER_PREFIX then
    local scenario = assert(self._scenario, "trainer answers read the detached scenario")
    local program = nil
    for _, participant in
      ipairs(scenario.participants --[[@as table<integer, unknown>]])
    do
      local entry = participant --[[@as table<string, unknown>]]
      if entry.controller == controller then
        program = self:_trainerProgramFor(entry)
      end
    end
    if program == nil then
      error("trainer side " .. controller .. " names no selection program", 0)
    end
    bound = { kind = "trainer", ai = HgssTrainerAi.new({ program = program }) }
  else
    error("controller " .. controller .. " is answered externally", 0)
  end
  self._controllers[controller] = bound
  return bound
end

---@param request table<string, unknown> pending kernel request owned internally
---@return table<string, unknown> reply in the shared decision shape
function BattleRuntime:_answerOwned(request)
  local session = assert(self._session, "owned replies answer a live session")
  local view = session:view(request.controller)
  local bound = self:_controllerFor(request.controller)
  if bound.kind == "wild" then
    return HgssOpponentControllers.wild(request, view, self:_selectionStream())
  end
  local ai = assert(bound.ai, "trainer answers carry their controller")
  return ai:decide(request, view, self:_selectionStream())
end

---@param frame table<string, unknown> kernel frame at an atomic boundary
function BattleRuntime:_presentFrame(frame)
  if type(frame.events) == "table" then
    for _, event in
      ipairs(frame.events --[[@as table<integer, unknown>]])
    do
      self._presentation.present(event --[[@as table<string, unknown>]])
    end
  end
end

---@param message string
function BattleRuntime:_fail(message)
  self._error = message
  self._phase = "failed"
end

---@return boolean ready true once presentation acknowledges entry
function BattleRuntime:_enterPresentation()
  local plan = { launchId = self._request.id, kind = self._request.kind }
  return self._presentation.enter(plan) == true
end

-- Builds the live kernel session from the detached scenario. The ruleset
-- stamped here is the kernel's own executable contract (single owner in
-- the battle package); everything else rides the detached fragment.
function BattleRuntime:_buildSession()
  local record = copyValue(self._scenario)
  assert(type(record) == "table", "session builds need their scenario")
  record.ruleset = BattleSession.EXECUTABLE_RULESET
  self._session = BattleSession.new(record, self:_executableContent())
end

function BattleRuntime:_updatePreparing()
  if not self:_enterPresentation() then
    return
  end
  if self._scenario == nil then
    self._phase = "entering"
    return
  end
  local ok, err = pcall(BattleRuntime._buildSession, self)
  if not ok then
    self:_fail(tostring(err))
    return
  end
  self._phase = "entering"
end

function BattleRuntime:_updateEntering()
  local session = self._session
  if session == nil then
    self._phase = "running"
    return
  end
  local frame = session:advance(BattleRuntime.ADVANCE_BUDGET)
  self:_presentFrame(frame)
  if frame.status == "ended" then
    self._outcome = frame.outcome
    self._phase = "resolving"
  else
    self._phase = "running"
  end
end

---@param request table<string, unknown>
---@return string stable identity for an owned request
local function ownedKey(request)
  return tostring(request.requestId) .. ":" .. tostring(request.epoch) .. ":" .. tostring(request.controller)
end

---@param requests table<integer, unknown>
---@return table<string, unknown>? the exposed external request, when one is pending
function BattleRuntime:_drainOwned(requests)
  if self._answered == nil then
    self._answered = {}
  end
  local exposed = nil
  for _, item in ipairs(requests) do
    local request = item --[[@as table<string, unknown>]]
    local controller = request.controller --[[@as string]]
    if controller == BattleRuntime.PLAYER_CONTROLLER then
      exposed = request
    elseif self._answered[ownedKey(request)] == true then
      -- Already stored on an earlier pump while waiting for the external
      -- reply: skip it entirely instead of answering twice.
    else
      local owned = controller == BattleRuntime.WILD_CONTROLLER
        or controller:sub(1, #BattleRuntime.TRAINER_PREFIX) == BattleRuntime.TRAINER_PREFIX
      if owned then
        local session = assert(self._session, "owned replies answer a live session")
        local reply = self:_answerOwned(request)
        local accepted, replyErr = session:submit(reply)
        if not accepted then
          local detail = replyErr --[[@as table<string, unknown>]]
          error("owned reply rejected: " .. tostring(detail and detail.message or replyErr), 0)
        end
        self._answered[ownedKey(request)] = true
      else
        exposed = exposed or request
      end
    end
  end
  return exposed
end

function BattleRuntime:_updateRunning()
  local session = self._session
  if session == nil then
    -- Lifecycle-only battles own no simulation: they hold the running
    -- phase briefly for presentation, then drain through resolution
    -- without committing anything.
    self._runTicks = self._runTicks + 1
    if self._runTicks >= 3 then
      self._phase = "resolving"
    end
    return
  end
  for _ = 1, 4 do
    local frame = session:advance(BattleRuntime.ADVANCE_BUDGET)
    self:_presentFrame(frame)
    if frame.status == "ended" then
      self._outcome = frame.outcome
      self._openRequest = nil
      self._phase = "resolving"
      return
    end
    if frame.status ~= "waiting" then
      return
    end
    local batch = frame.request --[[@as table<string, unknown>]]
    local ok, exposed = pcall(BattleRuntime._drainOwned, self, batch.requests --[[@as table<integer, unknown>]])
    if not ok then
      self:_fail(tostring(exposed))
      return
    end
    if exposed ~= nil then
      self._openRequest = exposed --[[@as table<string, unknown>]]
      return
    end
    -- Every pending request was owned internally: keep draining under the
    -- same update instead of parking on an all-AI batch.
  end
end

---@param snapshot table<string, unknown>
---@return boolean, boolean player side alive, enemy side alive
local function survivorSides(snapshot)
  local combatants = snapshot.combatants --[[@as table<integer, table<string, unknown>>]]
  local participants = snapshot.participants --[[@as table<integer, table<string, unknown>>]]
  local playerAlive, enemyAlive = false, false
  for _, combatant in pairs(combatants) do
    if type(combatant.hp) == "number" and combatant.hp > 0 then
      local participant = participants[
        combatant.participant --[[@as integer]]
      ]
      if participant ~= nil and participant.controller == BattleRuntime.PLAYER_CONTROLLER then
        playerAlive = true
      else
        enemyAlive = true
      end
    end
  end
  return playerAlive, enemyAlive
end

---@return string outcome word for the committer
function BattleRuntime:_mapOutcome()
  local outcome = self._outcome or {}
  assert(type(outcome) == "table", "resolution maps the session outcome")
  if outcome.kind == "no_actors" or outcome.kind == "scripted_complete" then
    -- Terminal standings decide the word: a fainted enemy side reports a
    -- win and a fainted player side reports a loss, while two standing
    -- sides settle as a draw. No victory is ever invented beyond the
    -- executed combatant health.
    local session = assert(self._session, "outcomes map a live session")
    local playerAlive, enemyAlive = survivorSides(session:capture())
    if playerAlive and not enemyAlive then
      return "win"
    end
    if enemyAlive and not playerAlive then
      return "loss"
    end
    return "draw"
  end
  error("unknown battle outcome kind " .. tostring(outcome.kind), 0)
end

---@return table<integer, unknown> party slot updates carrying executed health
function BattleRuntime:_partyUpdates()
  local updates = {}
  if self._party == nil or self._session == nil then
    return updates
  end
  local session = self._session --[[@as BattleSession]]
  local snapshot = session:capture()
  local combatants = snapshot.combatants --[[@as table<integer, table<string, unknown>>]]
  local participants = snapshot.participants --[[@as table<integer, table<string, unknown>>]]
  for _, combatant in pairs(combatants) do
    local participant = participants[
      combatant.participant --[[@as integer]]
    ]
    if participant ~= nil and participant.controller == BattleRuntime.PLAYER_CONTROLLER then
      local source = combatant.source --[[@as table<string, unknown>]]
      if type(source) == "table" and source.kind == "party" and type(source.slot) == "number" then
        local mon = copyValue(combatant.mon)
        assert(type(mon) == "table", "writeback carries the combatant record")
        local record = mon --[[@as table<string, unknown>]]
        local condition = record.condition --[[@as table<string, unknown>]]
        assert(type(condition) == "table", "writeback carries the combatant condition")
        if combatant.hp ~= combatant.entryHp then
          condition.currentHp = combatant.hp
          updates[#updates + 1] = {
            slot = source.slot --[[@as integer]] - 1,
            mon = record,
          }
        end
      end
    end
  end
  table.sort(updates, function(a, b)
    local left = a --[[@as table<string, unknown>]]
    local right = b --[[@as table<string, unknown>]]
    local leftSlot = left.slot --[[@as integer]]
    local rightSlot = right.slot --[[@as integer]]
    return leftSlot < rightSlot
  end)
  return updates
end

---@param playerSide boolean true for the player side, false for the enemy sides
---@return string[] species in scenario order, deduplicated
function BattleRuntime:_sideSpecies(playerSide)
  local scenario = assert(self._scenario, "consequences read the detached scenario")
  local keys = {} ---@type string[]
  local seen = {} ---@type table<string, boolean>
  for _, participant in
    ipairs(scenario.participants --[[@as table<integer, unknown>]])
  do
    local entry = participant --[[@as table<string, unknown>]]
    if (entry.controller == BattleRuntime.PLAYER_CONTROLLER) == playerSide then
      for _, seed in
        ipairs(entry.roster --[[@as table<integer, unknown>]])
      do
        local mon = (seed --[[@as table<string, unknown>]]).mon --[[@as table<string, unknown>]]
        if type(mon) ~= "table" or type(mon.species) ~= "string" or mon.species == "" then
          error("battle consequence staging names every combatant species", 0)
        end
        if
          not seen[
            mon.species --[[@as string]]
          ]
        then
          seen[
            mon.species --[[@as string]]
          ] = true
          keys[#keys + 1] = mon.species
        end
      end
    end
  end
  return keys
end

---@param mon table<string, unknown> combatant mon carrying either its level or its record
---@return integer battle level for consequence planning
function BattleRuntime:_combatantLevel(mon)
  if type(mon.level) == "number" then
    return mon.level --[[@as integer]]
  end
  -- Full mon-domain records carry experience instead of a stored level:
  -- project it through the live party owner rather than duplicating the
  -- growth-curve derivation here.
  local party = self._party --[[@as table<string, unknown>]]
  if type(party) == "table" and type(party.derive) == "function" then
    local derive = party.derive --[[@as fun(self: table<string, unknown>, mon: table<string, unknown>): table<string, unknown>]]
    local projected = derive(party, mon)
    if type(projected.level) == "number" then
      return projected.level --[[@as integer]]
    end
  end
  error("battle consequence staging carries every combatant level", 0)
end

---@param playerSide boolean true for the player side, false for the enemy sides
---@return integer[] levels in scenario order
function BattleRuntime:_sideLevels(playerSide)
  local scenario = assert(self._scenario, "consequences read the detached scenario")
  local levels = {} ---@type integer[]
  for _, participant in
    ipairs(scenario.participants --[[@as table<integer, unknown>]])
  do
    local entry = participant --[[@as table<string, unknown>]]
    if (entry.controller == BattleRuntime.PLAYER_CONTROLLER) == playerSide then
      for _, seed in
        ipairs(entry.roster --[[@as table<integer, unknown>]])
      do
        local mon = (seed --[[@as table<string, unknown>]]).mon --[[@as table<string, unknown>]]
        if type(mon) ~= "table" then
          error("battle consequence staging carries every combatant level", 0)
        end
        levels[#levels + 1] = self:_combatantLevel(mon)
      end
    end
  end
  return levels
end

---@return table<integer, table<string, unknown>> committer-shaped captures
function BattleRuntime:_commitCaptures()
  local staged = {} ---@type table<integer, table<string, unknown>>
  for _, capture in ipairs(self._captures or {}) do
    if type(capture) ~= "table" then
      error("battle captures must be records", 0)
    end
    local entry = capture --[[@as table<string, unknown>]]
    staged[#staged + 1] = {
      captureId = entry.captureId or entry.id,
      success = entry.success,
      mon = entry.mon,
      species = entry.species,
      level = entry.level,
      ball = entry.ball,
    }
  end
  return staged
end

---@param result string outcome word the commit carries
---@return table<string, unknown> reward plan, or an empty record when nothing is owed
function BattleRuntime:_commitRewards(result)
  if result == "win" and self._request.kind == "trainer" and self._prize ~= nil then
    local prize = self._prize --[[@as table<string, unknown>]]
    if type(prize.trainerClass) ~= "string" or prize.trainerClass == "" then
      error("trainer prize inputs name their trainer class", 0)
    end
    if type(prize.basePayout) ~= "number" or prize.basePayout % 1 ~= 0 or prize.basePayout < 0 then
      error("trainer prize inputs carry a non-negative integer base payout", 0)
    end
    return HgssBattleRewards.planMoney({
      trainerClass = prize.trainerClass,
      partyLevels = self:_sideLevels(false),
      basePayout = prize.basePayout,
      scriptRewards = prize.scriptRewards,
    })
  end
  if result == "loss" and self._player ~= nil then
    local player = self._player --[[@as table<string, unknown>]]
    local record = player.record --[[@as table<string, unknown>]]
    local profile = record.profile --[[@as table<string, unknown>]]
    if type(profile) ~= "table" then
      error("player money facts carry their profile", 0)
    end
    return HgssBattleRewards.planLoss({
      money = profile.money,
      partyLevels = self:_sideLevels(true),
      badges = profile.badges or 0,
    })
  end
  return {}
end

---@param result string outcome word the commit carries
---@param rewards table<string, unknown> planned reward carrying its amount
---@return integer signed money delta, zero when nothing moves
local function moneyDeltaFor(result, rewards)
  if type(rewards.amount) ~= "number" then
    return 0
  end
  if result == "win" then
    return rewards.amount --[[@as integer]]
  end
  if result == "loss" then
    return -rewards.amount --[[@as integer]]
  end
  return 0
end

---@return table<string, unknown> staged committer preparation
function BattleRuntime:_prepareCommit()
  local result = self:_mapOutcome()
  self._result = result
  self._sourceResult = (result == "win") and BattleTask.SOURCE_WON or BattleTask.SOURCE_NOT_WON
  local updates = self:_partyUpdates()
  local captures = self:_commitCaptures()
  local rewards = self:_commitRewards(result)
  local args = {
    outcome = { id = self._request.id, result = result },
    rewards = rewards,
  }
  if #updates > 0 or #captures > 0 then
    local party = assert(self._party, "party updates stage through their owner")
    -- Exactly-once currency: the live party must not have moved under
    -- the battle. A concurrent mutation fails preparation instead of
    -- publishing over it.
    if party:partyRevision() ~= self._partyRevision then
      error("the live party changed during the battle", 0)
    end
    args.partyOwner = party
    args.partyUpdates = updates
    if #captures > 0 then
      args.captures = captures
    end
  end
  if self._dex ~= nil then
    local seen = self:_sideSpecies(false)
    local caught = {} ---@type string[]
    for _, entry in ipairs(captures) do
      if entry.success == true then
        local mon = entry.mon --[[@as table<string, unknown>]]
        local key = entry.species
        if type(mon) == "table" and type(mon.species) == "string" then
          key = mon.species
        end
        if type(key) == "string" then
          caught[#caught + 1] = key --[[@as string]]
        end
      end
    end
    if #seen > 0 or #caught > 0 then
      local dex = self._dex --[[@as table<string, unknown>]]
      local stage = dex.prepareChanges --[[@as fun(self: table<string, unknown>, changes: table<string, unknown>): table<string, unknown>]]
      args.dex = stage(dex, { seen = seen, caught = caught })
    end
  end
  if self._bag ~= nil and self._bagDeltas ~= nil and #self._bagDeltas > 0 then
    local bag = self._bag --[[@as table<string, unknown>]]
    local deltas = {} ---@type table<integer, table<string, unknown>>
    for _, delta in ipairs(self._bagDeltas) do
      if type(delta) ~= "table" then
        error("planned bag consumption carries delta records", 0)
      end
      local record = delta --[[@as table<string, unknown>]]
      deltas[#deltas + 1] = { op = record.op, item = record.item, quantity = record.quantity }
    end
    local prepare = bag.prepareInventoryChanges --[[@as fun(self: table<string, unknown>, revision: integer, deltas: table<integer, table<string, unknown>>): table<string, unknown>?]]
    local revisionOf = bag.revision --[[@as fun(self: table<string, unknown>): integer]]
    local prep = prepare(bag, revisionOf(bag), deltas)
    if prep == nil then
      error("battle bag staging went stale", 0)
    end
    args.bag = prep
  end
  local delta = moneyDeltaFor(result, rewards)
  if self._player ~= nil and delta ~= 0 then
    local player = self._player --[[@as table<string, unknown>]]
    args.player = { record = player.record, context = player.context, moneyDelta = delta }
  end
  if self._roamer ~= nil then
    local spec = self._roamer --[[@as table<string, unknown>]]
    local captured = false
    for _, entry in ipairs(captures) do
      if entry.success == true then
        captured = true
      end
    end
    local battleOutcome = "fled"
    if captured then
      battleOutcome = "captured"
    elseif result == "win" then
      battleOutcome = "defeated"
    end
    args.roamer = {
      owner = spec.owner,
      key = spec.key,
      outcome = battleOutcome,
      expectedRevision = spec.expectedRevision,
      details = spec.details or {},
    }
  end
  return HgssBattleCommitter.prepare(args)
end

function BattleRuntime:_updateResolving()
  if self._session == nil then
    self._phase = "postbattle"
    self._postTicks = 0
    return
  end
  if self._prepared == nil then
    local ok, prepared = pcall(BattleRuntime._prepareCommit, self)
    if not ok then
      self:_fail(tostring(prepared))
      return
    end
    self._prepared = prepared --[[@as table<string, unknown>]]
  end
  local okCommit, receipt = pcall(HgssBattleCommitter.commit, self._prepared)
  if not okCommit then
    self:_fail(tostring(receipt))
    return
  end
  self._receipt = receipt --[[@as table<string, unknown>]]
  self._phase = "postbattle"
  self._postTicks = 0
end

function BattleRuntime:_updatePostbattle()
  self._postTicks = self._postTicks + 1
  if self._receipt ~= nil then
    self._presentation.present({ kind = "outcome", receipt = copyValue(self._receipt) })
  end
  if self._postTicks >= 2 then
    self._phase = "returning"
  end
end

function BattleRuntime:_updateReturning()
  local plan = { launchId = self._request.id, kind = self._request.kind, result = self._result }
  if self._presentation.leave(plan) == true then
    self._phase = "complete"
  end
end

--- Advances the battle lifetime once. Simulation pumps regardless of
--- presentation acknowledgements, but phase transitions wait for entry and
--- return readiness, and running waits for externally owned decisions.
function BattleRuntime:update()
  if self._disposed or self._phase == "complete" or self._phase == "failed" then
    return
  end
  -- The script task observes the same lifecycle its scheduler would: once
  -- committed, every update polls the pending launch against this host, so
  -- direct-drive and script-driven battles record their outcomes through
  -- one path.
  if self._phase == "preparing" then
    self:_updatePreparing()
  elseif self._phase == "entering" then
    self:_updateEntering()
  elseif self._phase == "running" then
    self:_updateRunning()
  elseif self._phase == "resolving" then
    self:_updateResolving()
  elseif self._phase == "postbattle" then
    self:_updatePostbattle()
  elseif self._phase == "returning" then
    self:_updateReturning()
  end
  if self._task ~= nil and self._receipt ~= nil then
    BattleTask.poll(self._task, { services = { battle = self } })
  end
  if self:isReleased() then
    unregisterActive(self)
  end
end

-- Answers the exposed external request. Replies for internally owned
-- controllers are rejected: their controllers answer inside update.
---@param reply table<string, unknown> sealed controller reply
---@return boolean stored
---@return table<string, unknown>? input error when the reply is rejected
function BattleRuntime:submit(reply)
  local session = self._session
  if session == nil or self._phase ~= "running" or self._openRequest == nil then
    return false, BattleErrors.input("replies require an open external request", {})
  end
  if type(reply) ~= "table" then
    return false, BattleErrors.input("decision replies must be records", {})
  end
  local open = self._openRequest --[[@as table<string, unknown>]]
  if reply.requestId ~= open.requestId then
    return false, BattleErrors.input("replies must answer the open request", {})
  end
  return session:submit(reply)
end

---@return table<string, unknown> lifecycle status
function BattleRuntime:status()
  local status = {
    phase = self._phase,
    launchId = self._request.id,
    source = self._request.kind,
    request = self._openRequest,
    outcomeReceipt = self._receipt,
    result = self._result,
    sourceResult = self._sourceResult,
    error = self._error,
  }
  return status
end

-- Reports whether an ordinary durable save is safe. Only a completed and
-- committed battle re-enables saving; every subflow (and any lifecycle
-- without a committed receipt) stays busy with its owning phase named.
---@return boolean saveable
---@return table<string, unknown>? busy reason when unsafe
function BattleRuntime:canSave()
  if self._phase == "complete" and self._receipt ~= nil and self._receipt.committed == true then
    return true
  end
  return false, { phase = self._phase, launchId = self._request.id }
end

---@return boolean true once the lifetime settled or released its owner
function BattleRuntime:isReleased()
  return self._disposed or self._phase == "complete" or self._phase == "failed"
end

-- Releases battle ownership exactly once. Disposal is idempotent for
-- resources but never an implicit rollback: a published receipt survives
-- teardown, while an uncommitted lifecycle simply ends uncommitted.
function BattleRuntime:dispose()
  if self._disposed then
    return
  end
  unregisterActive(self)
  self._disposed = true
  if self._session ~= nil then
    self._session:dispose()
    self._session = nil
  end
  self._presentation.dispose()
end

-- BattleTask host observation: the committed outcome for one launch, or nil
-- when the identity names no owned launch.
---@param launchId string
---@return table<string, unknown>? { phase, committed, result, sourceResult }
function BattleRuntime:battleStatus(launchId)
  if launchId ~= self._request.id then
    return nil
  end
  return {
    phase = self._phase,
    committed = self._receipt ~= nil and self._receipt.committed == true,
    result = self._result,
    sourceResult = self._sourceResult,
  }
end

return BattleRuntime
