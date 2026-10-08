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
-- Combat executes through the native HGSS lifecycle: ordered actions
-- run the shared move continuation with the combatants' carried facts and
-- knockouts settle through faint ownership until a terminal outcome. A
-- capture or escape that leaves both sides standing settles as a draw. No victory is ever
-- invented: only a fainted enemy side reports a win. Committed party
-- writeback carries the executed damage and the earned knockout
-- progression into the live party through the committer's staged batch.

local Battle = require("gen4.battle")
local CaptureContext = require("libs.battle.src.gen4.CaptureContext")
local HgssBattleContent = require("game.hgss.src.battle.HgssBattleContent")
local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
local BattleErrors = require("libs.battle.src.errors")
local BattleTask = require("libs.hgss.src.script.tasks.BattleTask")
local HgssBattleCommitter = require("libs.hgss.src.battle.HgssBattleCommitter")
local HgssBattleRewards = require("libs.hgss.src.battle.HgssBattleRewards")
local HgssOpponentControllers = require("libs.hgss.src.battle.HgssOpponentControllers")

---@class BattlePresentationPort
---@field enter fun(plan: table<string, unknown>): boolean
---@field present fun(frame: table<string, unknown>)
---@field leave fun(plan: table<string, unknown>): boolean
---@field dispose fun()

---@class BattlePartyOwner
---@field partyRevision fun(self: BattlePartyOwner): integer
---@field partyMon (fun(self: BattlePartyOwner, slot0: integer): table<string, unknown>)? reads the current live party slot record

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
---@field captures table<integer, table<string, unknown>>? battle capture results in committer shape
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
---@field _captures table<integer, table<string, unknown>>?
---@field _seed integer
---@field _phase string
---@field _task table<string, unknown>?
---@field _content table<string, unknown>?
---@field _session table<string, unknown>?
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
---@field _bagRevision integer?
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
      (type(single) == "string" and single ~= "")
        or type(single) == "number"
        or (type(several) == "table" and #several > 0),
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
-- consumption, the live roamer battle record, the player money facts,
-- and the battle capture results. Trainer prize money needs no caller
-- inputs: the detached scenario carries the defeated trainers' native
-- reward facts and the live session carries the battle-local money
-- multiplier, so a trainer win plans its own reward. Battle code
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
  if args.party ~= nil then
    local current = ACTIVE_BY_OWNER[args.party]
    if current ~= nil and not current:isReleased() then
      error("a battle already owns this party", 0)
    end
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
    _captures = args.captures ~= nil and copyValue(args.captures) or nil,
    _seed = args.seed or hashIdentity(request.id --[[@as string]]),
    _phase = "preparing",
    _task = nil,
    _content = nil,
    _session = nil,
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
  if args.bag ~= nil then
    -- Exactly-once currency for the live bag mirrors the party guard: the
    -- construction-time revision is the only expected revision at
    -- resolution, so a concurrent live mutation fails preparation instead
    -- of publishing over it.
    local bag = args.bag --[[@as table<string, unknown>]]
    local revisionOf = bag.revision --[[@as fun(self: table<string, unknown>): integer]]
    self._bagRevision = revisionOf(bag)
  end
  self._task = BattleTask.start(
    { launchId = self._request.id, kind = self._request.kind, details = self._request.payload },
    { services = {} }
  )
  registerActive(self)
  return self
end

---@return table<string, unknown> executable content carrying the native HGSS bundle
function BattleRuntime:_executableContent()
  if self._content == nil then
    self._content = HgssBattleContent.nativeContent()
  end
  assert(self._content ~= nil, "executable content builds once")
  return self._content
end

-- Owned opponent answers draw from the same native battle stream the
-- kernel consumes per strike, so one deterministic trace spans opponent
-- choice and combat. Wild fighters answer through their bound policy
-- inside the session decision lease; trainer sides answer through the
-- native session seam, which decides from session state, facts, stock,
-- and topology. The runtime owns no generator and keeps no decision
-- state: generic answered-request bookkeeping in the request pump keeps
-- repeated polls of one open request from drawing again.
---@param request table<string, unknown> pending kernel request owned internally
---@return table<string, unknown> reply in the shared decision shape
function BattleRuntime:_answerOwned(request)
  local session = assert(self._session, "owned replies answer a live session")
  if request.controller == BattleRuntime.WILD_CONTROLLER then
    assert(type(session.withDecisionStream) == "function", "owned replies draw from the session stream")
    return session:withDecisionStream(request, function(stream)
      return HgssOpponentControllers.wild(request, session:view(request.controller), stream)
    end)
  end
  assert(type(session.answerTrainer) == "function", "trainer replies answer through the native session seam")
  return session:answerTrainer(request)
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

-- Collects the static identities a detached scenario references for fact
-- resolution: distinct record-backed move identities plus distinct combatant
-- species forms. Malformed fragments contribute nothing here; scenario
-- validation still owns malformation errors, and executions naming
-- unprovisioned facts fail explicitly at their own boundary.
---@param record table<string, unknown> detached scenario under session construction
---@return string[] sorted distinct referenced move identities
---@return table<integer, { species: string, form: integer }> sorted distinct referenced species forms
local function referencedStaticKeys(record)
  local moves = {} ---@type table<string, boolean>
  local forms = {} ---@type table<string, table<integer, boolean>>
  local participants = record.participants
  if type(participants) == "table" then
    for _, entry in
      ipairs(participants --[[@as table<integer, unknown>]])
    do
      if type(entry) == "table" then
        local roster = (entry --[[@as table<string, unknown>]]).roster
        if type(roster) == "table" then
          for _, seed in
            ipairs(roster --[[@as table<integer, unknown>]])
          do
            if type(seed) == "table" then
              local mon = (seed --[[@as table<string, unknown>]]).mon
              if type(mon) == "table" then
                local seedRecord = mon --[[@as table<string, unknown>]]
                local species = seedRecord.species
                local form = seedRecord.form
                if type(species) == "string" and species ~= "" then
                  if type(form) == "number" and form % 1 == 0 then
                    local bucket = forms[species]
                    if bucket == nil then
                      bucket = {}
                      forms[species] = bucket
                    end
                    bucket[form] = true
                  end
                end
                local entries = seedRecord.moves
                if type(entries) == "table" then
                  for _, moveEntry in
                    ipairs(entries --[[@as table<integer, unknown>]])
                  do
                    if type(moveEntry) == "table" then
                      local key = (moveEntry --[[@as table<string, unknown>]]).move
                      if type(key) == "string" and key ~= "" then
                        moves[key] = true
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  local moveKeys = {}
  for key in pairs(moves) do
    moveKeys[#moveKeys + 1] = key
  end
  table.sort(moveKeys)
  local speciesKeys = {}
  for key in pairs(forms) do
    speciesKeys[#speciesKeys + 1] = key
  end
  table.sort(speciesKeys)
  local speciesForms = {} ---@type table<integer, { species: string, form: integer }>
  for _, key in ipairs(speciesKeys) do
    local formKeys = {}
    for form in pairs(forms[key]) do
      formKeys[#formKeys + 1] = form
    end
    table.sort(formKeys)
    for _, form in ipairs(formKeys) do
      speciesForms[#speciesForms + 1] = { species = key, form = form }
    end
  end
  return moveKeys, speciesForms
end

---@return table<string, unknown>? live party catalog when the owner exposes one
function BattleRuntime:_factCatalog()
  local party = self._party --[[@as table<string, unknown>]]
  if type(party) == "table" and type(party.catalog) == "function" then
    local resolve = party.catalog --[[@as fun(self: table<string, unknown>): table<string, unknown>]]
    local catalog = resolve(party)
    if type(catalog) == "table" then
      return catalog
    end
  end
  return nil
end

-- Resolves the immutable move facts the detached scenario references through
-- the live party catalog: every distinct record-backed move identity plus the
-- explicit fallback action. Record-backed identities must resolve, so an
-- unknown record move fails the build instead of guessing; the fallback
-- action is provisioned only when the catalog carries it, and executions
-- naming an unprovisioned move still fail explicitly at the move boundary.
-- Battles without a fact source carry no facts and fail the same way on
-- their first offending execution.
---@param record table<string, unknown> detached scenario under session construction
---@return table<string, table<string, unknown>> immutable move facts for the referenced moves
function BattleRuntime:_sessionMoveFacts(record)
  local facts = {} ---@type table<string, table<string, unknown>>
  local catalog = self:_factCatalog()
  if catalog == nil then
    return facts
  end
  local source = catalog --[[@as table<string, unknown>]]
  local moveByName = source.move --[[@as fun(self: table<string, unknown>, key: string): table<string, unknown>]]
  assert(type(moveByName) == "function", "move facts resolve through the mon catalog")
  local moveKeys = referencedStaticKeys(record)
  for _, key in ipairs(moveKeys) do
    facts[key] = copyValue(moveByName(source, key))
  end
  -- Knockout rewards learn through level-up learnsets, so every learnset
  -- move of a referenced form resolves beside the carried move sets.
  local formByKey = source.form --[[@as fun(self: table<string, unknown>, speciesKey: string, form: integer): table<string, unknown>]]
  assert(type(formByKey) == "function", "learnset moves resolve through the mon catalog")
  local _, speciesForms = referencedStaticKeys(record)
  for _, entry in ipairs(speciesForms) do
    local formRecord = formByKey(source, entry.species, entry.form)
    assert(type(formRecord.levelUpMoves) == "table", "species forms carry their learnsets")
    for _, chance in
      ipairs(formRecord.levelUpMoves --[[@as table<integer, table<string, unknown>>]])
    do
      local move = chance.move --[[@as string]]
      if facts[move] == nil then
        facts[move] = copyValue(moveByName(source, move))
      end
    end
  end
  local ok, fallback = pcall(moveByName, source, "STRUGGLE")
  if ok then
    facts["STRUGGLE"] = copyValue(fallback)
  end
  return facts
end

-- Resolves the minimal static species facts the detached scenario references
-- through the live party catalog: base stats, semantic form types, the
-- growth curve, the level-up learnset, and the knockout yields per
-- referenced species and form. Unresolvable species fail the build instead
-- of guessing; battles without a fact source carry no facts and fail
-- explicitly on their first offending execution.
---@param record table<string, unknown> detached scenario under session construction
---@return table<string, SpeciesFormFacts> static species facts by species and form
function BattleRuntime:_sessionSpeciesFacts(record)
  local facts = {} ---@type table<string, SpeciesFormFacts>
  local catalog = self:_factCatalog()
  if catalog == nil then
    return facts
  end
  local source = catalog --[[@as table<string, unknown>]]
  local speciesByKey = source.species --[[@as fun(self: table<string, unknown>, key: string): table<string, unknown>]]
  local formByKey = source.form --[[@as fun(self: table<string, unknown>, speciesKey: string, form: integer): table<string, unknown>]]
  local curveByKey = source.growthCurve --[[@as fun(self: table<string, unknown>, key: string): table<integer, integer>]]
  assert(
    type(speciesByKey) == "function" and type(formByKey) == "function" and type(curveByKey) == "function",
    "species facts resolve through the mon catalog"
  )
  local _, speciesForms = referencedStaticKeys(record)
  for _, entry in ipairs(speciesForms) do
    local speciesRecord = speciesByKey(source, entry.species)
    local curveKey = speciesRecord.growthCurve
    assert(type(curveKey) == "string", "species records name their growth curve")
    local formRecord = formByKey(source, entry.species, entry.form)
    assert(type(formRecord.baseStats) == "table", "species forms carry their base stats")
    local formTypes = formRecord.types
    assert(type(formTypes) == "table" and #formTypes > 0, "species forms carry their semantic types")
    local types = {} ---@type string[]
    for _, key in
      ipairs(formTypes --[[@as string[] ]])
    do
      assert(type(key) == "string" and key ~= "", "species types name their semantic key")
      types[#types + 1] = key
    end
    assert(type(formRecord.levelUpMoves) == "table", "species forms carry their learnsets")
    assert(type(speciesRecord.baseExpYield) == "number", "species records carry their base experience yield")
    assert(type(speciesRecord.evYield) == "table", "species records carry their effort yield")
    -- Gender ratios travel for attract and captivate law; the executor
    -- resolves battle genders without reaching back into the catalog.
    assert(type(speciesRecord.genderRatio) == "number", "species records carry their gender ratio")
    -- Species weights travel for weight-law strikes; the executor
    -- resolves kilograms without reaching back into the catalog.
    -- Records without a weight stay absent and fail loudly in their
    -- handler instead of guessing.
    local weightHg = nil
    if type(speciesRecord.weight) == "number" then
      weightHg = speciesRecord.weight
    end
    local bucket = facts[entry.species]
    if bucket == nil then
      bucket = {}
      facts[entry.species] = bucket
    end
    bucket[entry.form] = {
      baseStats = copyValue(formRecord.baseStats),
      growthCurve = copyValue(curveByKey(source, curveKey --[[@as string]])),
      types = types,
      levelUpMoves = copyValue(formRecord.levelUpMoves),
      baseExpYield = speciesRecord.baseExpYield,
      evYield = copyValue(speciesRecord.evYield),
      genderRatio = speciesRecord.genderRatio,
      weightHg = weightHg,
    }
  end
  return facts
end

-- Resolves the money-up held items the detached scenario carries through
-- the live party catalog: every distinct held key on a battle record is
-- classified through its compiled held behavior, so the session entry
-- scan latches on data, never on item names. Descriptor combatants carry
-- no item and contribute nothing; battles without a fact source carry no
-- facts and never latch.
---@param record table<string, unknown> detached scenario under session construction
---@return string[] sorted distinct held-item keys carrying the money-up effect
function BattleRuntime:_sessionMoneyUpItems(record)
  local found = {} ---@type table<string, boolean>
  local catalog = self:_factCatalog()
  if catalog == nil then
    return {}
  end
  local source = catalog --[[@as table<string, unknown>]]
  local itemByKey = source.item --[[@as fun(self: table<string, unknown>, key: string): table<string, unknown>]]
  assert(type(itemByKey) == "function", "money-up facts resolve through the mon catalog")
  local participants = record.participants
  if type(participants) ~= "table" then
    return {}
  end
  for _, entry in
    ipairs(participants --[[@as table<integer, unknown>]])
  do
    if type(entry) == "table" then
      local roster = (entry --[[@as table<string, unknown>]]).roster
      if type(roster) == "table" then
        for _, seed in
          ipairs(roster --[[@as table<integer, unknown>]])
        do
          if type(seed) == "table" then
            local mon = (seed --[[@as table<string, unknown>]]).mon
            if type(mon) == "table" then
              local held = (mon --[[@as table<string, unknown>]]).heldItem
              if type(held) == "string" and held ~= "" and found[held] == nil then
                local definition = itemByKey(source, held)
                local behavior = definition.heldBehavior
                if type(behavior) == "table" and behavior.key == "money_up" then
                  found[held] = true
                end
              end
            end
          end
        end
      end
    end
  end
  local keys = {} ---@type string[]
  for key in pairs(found) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

-- Resolves the detached semantic item facts the detached scenario
-- references through the live party catalog: every distinct non-ball
-- inventory key contributes exactly its generated party-use record plus
-- its battle-use and held-behavior riders when present, and every held
-- item contributes its throw facts for fling and natural gift alongside
-- its held behavior. Balls serve through the
-- capture owner and need no facts; unknown keys stay absent so their
-- selection fails explicitly at the battle boundary. Battles without a
-- fact source carry no facts and fail the same way on their first
-- serving.
---@param record table<string, unknown> detached scenario under session construction
---@return table<string, table<string, unknown>> immutable item facts for the referenced items
function BattleRuntime:_sessionItemFacts(record)
  local facts = {} ---@type table<string, table<string, unknown>>
  local catalog = self:_factCatalog()
  if catalog == nil then
    return facts
  end
  local source = catalog --[[@as table<string, unknown>]]
  local itemByKey = source.item --[[@as fun(self: table<string, unknown>, key: string): table<string, unknown>]]
  assert(type(itemByKey) == "function", "item facts resolve through the mon catalog")
  local inventories = record.inventories
  if type(inventories) == "table" then
    for _, entry in
      ipairs(inventories --[[@as table<integer, unknown>]])
    do
      if type(entry) == "table" then
        local quantities = (entry --[[@as table<string, unknown>]]).quantities
        if type(quantities) == "table" then
          for key in
            pairs(quantities --[[@as table<string, unknown>]])
          do
            if type(key) == "string" and key ~= "" and facts[key] == nil and not CaptureContext.isBall(key) then
              local ok, definition = pcall(itemByKey, source, key)
              if ok and type(definition) == "table" and type(definition.partyUse) == "table" then
                local projected = { partyUse = copyValue(definition.partyUse) } --[[@as table<string, unknown>]]
                if type(definition.battleUse) == "table" then
                  projected.battleUse = copyValue(definition.battleUse)
                end
                -- Canonical held behavior rides beside the use facts so
                -- trainer switch and item checks can inspect held effects
                -- through this same map instead of a second catalog.
                if type(definition.heldBehavior) == "table" then
                  projected.heldBehavior = copyValue(definition.heldBehavior)
                end
                facts[key] = projected
              end
            end
          end
        end
      end
    end
  end
  local participants = record.participants
  if type(participants) == "table" then
    for _, entry in
      ipairs(participants --[[@as table<integer, unknown>]])
    do
      if type(entry) == "table" then
        local roster = (entry --[[@as table<string, unknown>]]).roster
        if type(roster) == "table" then
          for _, seed in
            ipairs(roster --[[@as table<integer, unknown>]])
          do
            if type(seed) == "table" then
              local mon = (seed --[[@as table<string, unknown>]]).mon
              if type(mon) == "table" then
                local held = (mon --[[@as table<string, unknown>]]).heldItem
                if type(held) == "string" and held ~= "" and held ~= "NONE" then
                  local ok, definition = pcall(itemByKey, source, held)
                  if ok and type(definition) == "table" then
                    local resolved = definition --[[@as table<string, unknown>]]
                    -- Held-only entries exist for throw facts alone: keys
                    -- without generated throw facts project nothing, so
                    -- synthetic catalogs stay valid while ROM records keep
                    -- their fling and natural-gift facts. Canonical held
                    -- behavior projects beside them through the same
                    -- record for trainer checks.
                    if
                      type(resolved.naturalGift) == "table"
                      or type(resolved.fling) == "table"
                      or type(resolved.heldBehavior) == "table"
                    then
                      local projected = facts[held]
                      if projected == nil then
                        projected = {}
                        facts[held] = projected
                      end
                      if type(resolved.naturalGift) == "table" and projected.naturalGift == nil then
                        projected.naturalGift = copyValue(resolved.naturalGift)
                      end
                      if type(resolved.fling) == "table" and projected.fling == nil then
                        projected.fling = copyValue(resolved.fling)
                      end
                      if type(resolved.heldBehavior) == "table" and projected.heldBehavior == nil then
                        projected.heldBehavior = copyValue(resolved.heldBehavior)
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  return facts
end

-- Builds the live session from the detached scenario. The stamped ruleset
-- is the native HGSS contract, and the common battle entrypoint selects
-- the native executor from it; everything else rides the detached
-- fragment.
function BattleRuntime:_buildSession()
  local record = copyValue(self._scenario)
  assert(type(record) == "table", "session builds need their scenario")
  record.ruleset = Executor.RULESET
  record.moveFacts = self:_sessionMoveFacts(record --[[@as table<string, unknown>]])
  record.speciesFacts = self:_sessionSpeciesFacts(record --[[@as table<string, unknown>]])
  record.moneyUpItems = self:_sessionMoneyUpItems(record --[[@as table<string, unknown>]])
  record.itemFacts = self:_sessionItemFacts(record --[[@as table<string, unknown>]])
  self._session = Battle.newSession(record, self:_executableContent())
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
  if outcome.kind == "no_actors" or outcome.kind == "escaped" or outcome.kind == "captured" then
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

---@param left unknown
---@param right unknown
---@return boolean equal true when both values carry the same data
local function valuesEqual(left, right)
  if type(left) ~= type(right) then
    return false
  end
  if type(left) ~= "table" then
    return left == right
  end
  local leftRecord = left --[[@as table<string, unknown>]]
  local rightRecord = right --[[@as table<string, unknown>]]
  for key, value in pairs(leftRecord) do
    if not valuesEqual(value, rightRecord[key]) then
      return false
    end
  end
  for key, _ in pairs(rightRecord) do
    if leftRecord[key] == nil then
      return false
    end
  end
  return true
end

-- Reports whether the staged combatant copy carries knockout progression
-- the live party slot record lacks: experience, derived level, effort
-- values, or the move set. Health is excluded: the caller already stages
-- every health change, so this covers exactly the undamaged recipients
-- whose gains the health-only rule silently dropped.
---@param live table<string, unknown> current live party slot record
---@param staged table<string, unknown> battle-owned combatant copy under staging
---@return boolean changed true when progression differs
local function progressionChanged(live, staged)
  if live.experience ~= staged.experience then
    return true
  end
  if live.level ~= staged.level then
    return true
  end
  if not valuesEqual(live.evs, staged.evs) then
    return true
  end
  if not valuesEqual(live.moves, staged.moves) then
    return true
  end
  return false
end

---@return table<integer, unknown> party slot updates carrying executed health and knockout progression
function BattleRuntime:_partyUpdates()
  local updates = {}
  if self._party == nil or self._session == nil then
    return updates
  end
  local session = self._session --[[@as table<string, unknown>]]
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
        local slot0 = source.slot --[[@as integer]] - 1
        condition.currentHp = combatant.hp
        local healthChanged = combatant.hp ~= combatant.entryHp
        local progressed = false
        if not healthChanged then
          local party = self._party --[[@as BattlePartyOwner]]
          local reader = party.partyMon
          if type(reader) == "function" then
            progressed = progressionChanged(reader(party, slot0), record)
          end
        end
        if healthChanged or progressed then
          updates[#updates + 1] = {
            slot = slot0,
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
  -- Ordinary production captures originate from the executed battle:
  -- the session ledger records the throw owner's complete result and
  -- this mapping only reshapes it into the existing committer shape.
  -- Explicitly injected captures above stay for the proven scripted and
  -- test drivers that stage them directly.
  if self._session ~= nil then
    local session = self._session --[[@as table<string, unknown>]]
    local snapshot = session.capture(session) --[[@as table<string, unknown>]]
    local ledger = snapshot.captures
    assert(type(ledger) == "table", "session captures arrive as an array")
    for _, record in
      ipairs(ledger --[[@as table<integer, unknown>]])
    do
      if type(record) ~= "table" then
        error("battle captures must be records", 0)
      end
      local entry = record --[[@as table<string, unknown>]]
      staged[#staged + 1] = {
        captureId = entry.id,
        success = entry.success,
        mon = entry.mon,
        species = entry.species,
        level = entry.level,
        ball = entry.ball,
      }
    end
  end
  return staged
end

---@return table<integer, table<string, unknown>> detached per-trainer native reward facts
function BattleRuntime:_trainerRewardFacts()
  local scenario = assert(self._scenario, "trainer rewards read the detached scenario")
  local trainers = scenario.trainer
  if type(trainers) ~= "table" or #trainers == 0 then
    error("trainer rewards require the defeated trainer entries", 0)
  end
  local facts = {} ---@type table<integer, table<string, unknown>>
  for index, entry in ipairs(trainers) do
    if type(entry) ~= "table" then
      error("trainer reward entry " .. index .. " stays a record", 0)
    end
    local trainer = entry --[[@as table<string, unknown>]]
    local prize = trainer.prizeMoney
    facts[#facts + 1] = {
      trainerClass = trainer.class,
      partyLevels = trainer.partyLevels,
      classRate = type(prize) == "table" and (prize --[[@as table<string, unknown>]]).classRate or nil,
    }
  end
  return facts
end

---@return string represented battle format settling the reward
function BattleRuntime:_rewardFormat()
  local scenario = assert(self._scenario, "trainer rewards read the detached scenario")
  local format = scenario.format
  if format ~= "single" and format ~= "double" then
    error("trainer rewards settle a represented singles or doubles battle", 0)
  end
  return format --[[@as string]]
end

---@return integer battle-local money multiplier latched by the session entry scan
function BattleRuntime:_rewardMultiplier()
  local session = assert(self._session, "trainer rewards read the live session")
  local snapshot = session:capture()
  local multiplier = snapshot.prizeMoneyValue
  if multiplier == nil then
    return 1
  end
  if multiplier ~= 1 and multiplier ~= 2 then
    error("battle money multipliers stay 1 or 2", 0)
  end
  return multiplier --[[@as integer]]
end

---@param result string outcome word the commit carries
---@return table<string, unknown> reward plan, or an empty record when nothing is owed
function BattleRuntime:_commitRewards(result)
  if result == "win" and self._request.kind == "trainer" then
    -- Native trainer wins derive their own reward inputs from the
    -- materialized trainer entries and the live battle state: no
    -- caller-injected prize is required, and incomplete reward facts
    -- fail planning before anything publishes. Scattered pay day coins
    -- ride the session snapshot into the same plan.
    local snapshot = self._session:capture()
    return HgssBattleRewards.planMoney({
      trainers = self:_trainerRewardFacts(),
      battleFormat = self:_rewardFormat(),
      moneyMultiplier = self:_rewardMultiplier(),
      paydayScattered = snapshot.paydayScattered or 0,
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

-- Translates native session consumption into live bag deltas. Only ledger
-- entries owned by the player participant inventory publish: each negative
-- delta becomes one take of the positive quantity, identical items
-- combine, and trainer-owned entries are battle-local evidence only. An
-- unknown inventory or an unsupported player delta fails before
-- publication instead of guessing ownership.
---@return table<integer, table<string, unknown>> live take deltas for the staged bag preparation
function BattleRuntime:_sessionBagDeltas()
  local deltas = {} ---@type table<integer, table<string, unknown>>
  if self._session == nil or self._scenario == nil then
    return deltas
  end
  local scenario = self._scenario --[[@as table<string, unknown>]]
  local declared = {} ---@type table<string, boolean>
  for _, entry in ipairs(scenario.inventories or {}) do
    if type(entry) == "table" and type(entry.id) == "string" then
      declared[
        entry.id --[[@as string]]
      ] = true
    end
  end
  local playerInventories = {} ---@type table<string, boolean>
  for _, entry in ipairs(scenario.participants or {}) do
    if type(entry) == "table" then
      local participant = entry --[[@as table<string, unknown>]]
      if participant.controller == BattleRuntime.PLAYER_CONTROLLER and type(participant.inventoryId) == "string" then
        playerInventories[
          participant.inventoryId --[[@as string]]
        ] = true
      end
    end
  end
  if next(playerInventories) == nil then
    return deltas
  end
  local session = self._session --[[@as table<string, unknown>]]
  local snapshot = session:capture()
  local ledger = snapshot.ledger
  assert(type(ledger) == "table", "session snapshots carry their consumption ledger")
  local takes = {} ---@type table<string, integer>
  for _, record in
    ipairs(ledger --[[@as table<integer, unknown>]])
  do
    if type(record) ~= "table" then
      error("session consumption carries ledger records", 0)
    end
    local entry = record --[[@as table<string, unknown>]]
    if
      type(entry.inventoryId) ~= "string"
      or type(entry.item) ~= "string"
      or entry.item == ""
      or type(entry.delta) ~= "number"
    then
      error("session consumption carries identified deltas", 0)
    end
    local inventoryId = entry.inventoryId --[[@as string]]
    local item = entry.item --[[@as string]]
    local delta = entry.delta --[[@as integer]]
    if playerInventories[inventoryId] then
      if delta >= 0 then
        error("player session consumption only takes: " .. item, 0)
      end
      takes[item] = (takes[item] or 0) + -delta
    elseif declared[inventoryId] then
      -- Trainer-owned battle-local stock never reaches the live bag.
    else
      error("session consumption names an unknown inventory: " .. inventoryId, 0)
    end
  end
  local keys = {} ---@type string[]
  for key in pairs(takes) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    deltas[#deltas + 1] = { op = "take", item = key, quantity = takes[key] }
  end
  return deltas
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
  -- Native session consumption reaches the live bag exactly once: player
  -- inventory ledger entries become take deltas staged against the
  -- construction-time revision, trainer stock stays battle-local, and any
  -- still-supported explicit driver delta rides the same preparation.
  local bagDeltas = self:_sessionBagDeltas()
  if self._bagDeltas ~= nil then
    for _, delta in ipairs(self._bagDeltas) do
      if type(delta) ~= "table" then
        error("planned bag consumption carries delta records", 0)
      end
      local record = delta --[[@as table<string, unknown>]]
      bagDeltas[#bagDeltas + 1] = { op = record.op, item = record.item, quantity = record.quantity }
    end
  end
  if self._bag ~= nil and #bagDeltas > 0 then
    local bag = self._bag --[[@as table<string, unknown>]]
    local prepare = bag.prepareInventoryChanges --[[@as fun(self: table<string, unknown>, revision: integer, deltas: table<integer, table<string, unknown>>): table<string, unknown>?]]
    local expected = assert(self._bagRevision, "bag staging keeps its construction revision")
    local prep = prepare(bag, expected, bagDeltas)
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
