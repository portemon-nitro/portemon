-- Public battle composition entrypoint, API 1: the versioned surface
-- mods and the application use to compose ordered content contributions
-- into one frozen battle binding set:
--
--     local Battle = require("gen4.battle")
--
-- A contribution is an already-ordered table carrying its concrete owner,
-- revision, and installer:
--
--     { owner = "sound", revision = "1", install = function(builder, behaviors) ... end }
--
-- Declaration order decides patch resolution, never numeric fields: a
-- contributor may name `after`/`before` owners to constrain its position,
-- `priority` numbers are ignored for resolution, dependency cycles fail,
-- and a `suppresses` list of `{ kind, key }` entries removes exactly the
-- named canonical contributions. Absent `after`/`before` owners constrain
-- nothing. Headless session construction and scenario scaffolding live
-- here now that the session owner exists; the session never exposes its
-- private tables through this entrypoint.

local ContentBuilder = require("libs.content.src.ContentBuilder")
local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
local BattleContent = require("libs.battle.src.BattleContent")
local BattleScenario = require("libs.battle.src.BattleScenario")
local Errors = require("libs.errors.src.Errors")
local Mon = require("libs.mons.src.Mon")

local Battle = {}

Battle.apiVersion = 1
Battle.API_VERSION = Battle.apiVersion

---@type table<string, table<string, unknown>> versioned format bindings by key
local registeredFormats = {}
---@type table<string, table<string, unknown>> versioned action bindings by key
local registeredActions = {}

---@param value unknown
---@return unknown
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local input = value --[[@as table<unknown, unknown>]]
  local out = {}
  for key, item in pairs(input) do
    out[key] = copyValue(item)
  end
  return out
end

---@return ContentBuilder a fresh ordered content builder
function Battle.newContentBuilder()
  return ContentBuilder.new()
end

---@return BattleBehaviorBuilder a fresh typed behavior builder
function Battle.newBehaviorBuilder()
  return BattleBehaviorBuilder.new()
end

--- Registers a versioned format binding under the authoring surface. The
--- binding is validated here and installed into every later composition
--- ahead of contributor installs, so a contributor defining the same key
--- fails loudly instead of shadowing it.
---@param key string format identity under registration
---@param definition table<string, unknown> named format binding carrying its key
function Battle.registerFormat(key, definition)
  assert(Battle.apiVersion == 1, "the battle entrypoint carries its version")
  if type(key) ~= "string" or key == "" then
    Errors.raise("BATTLE_INVALID", "format registration requires a non-empty key", {})
  end
  if type(definition) ~= "table" then
    Errors.raise("BATTLE_INVALID", "format " .. key .. " must be a record", { key = key })
  end
  local record = definition --[[@as table<string, unknown>]]
  if record.key ~= key then
    Errors.raise("BATTLE_INVALID", "format " .. key .. " carries a mismatched key", { key = key })
  end
  if record.chart ~= nil and (type(record.chart) ~= "string" or record.chart == "") then
    Errors.raise("BATTLE_INVALID", "format " .. key .. " chart must be a non-empty string", { key = key })
  end
  if record.actionKinds ~= nil then
    local kinds = record.actionKinds --[[@as table<integer, unknown>]]
    if type(kinds) ~= "table" or #kinds == 0 then
      Errors.raise("BATTLE_INVALID", "format " .. key .. " actionKinds must be a non-empty array", { key = key })
    end
    for index, admitted in ipairs(kinds) do
      if type(admitted) ~= "string" or admitted == "" then
        Errors.raise(
          "BATTLE_INVALID",
          "format " .. key .. " actionKinds[" .. index .. "] must be a non-empty string",
          { key = key }
        )
      end
    end
  end
  if registeredFormats[key] ~= nil then
    Errors.raise("BATTLE_CONFLICT", "duplicate format " .. key, { key = key })
  end
  registeredFormats[key] = copyValue(record) --[[@as table<string, unknown>]]
end

--- Registers a versioned action binding under the authoring surface. The
--- binding names its callable module and positive integer version and is
--- installed into every later composition ahead of contributor installs.
---@param key string action identity under registration
---@param definition table<string, unknown> callable action binding carrying module and version
function Battle.registerAction(key, definition)
  assert(Battle.apiVersion == 1, "the battle entrypoint carries its version")
  if type(key) ~= "string" or key == "" then
    Errors.raise("BATTLE_INVALID", "action registration requires a non-empty key", {})
  end
  if type(definition) ~= "table" then
    Errors.raise("BATTLE_INVALID", "action " .. key .. " must be a record", { key = key })
  end
  local record = definition --[[@as table<string, unknown>]]
  if type(record.module) ~= "string" or record.module == "" then
    Errors.raise("BATTLE_INVALID", "action " .. key .. " must name its callable module", { key = key })
  end
  if type(record.version) ~= "number" or record.version % 1 ~= 0 or record.version < 1 then
    Errors.raise("BATTLE_INVALID", "action " .. key .. " must carry a positive integer version", { key = key })
  end
  for _, field in ipairs({ "parameters", "state" }) do
    if record[field] ~= nil and type(record[field]) ~= "table" then
      Errors.raise("BATTLE_INVALID", "action " .. key .. " " .. field .. " must be a record", { key = key })
    end
  end
  if registeredActions[key] ~= nil then
    Errors.raise("BATTLE_CONFLICT", "duplicate action " .. key, { key = key })
  end
  registeredActions[key] = copyValue(record) --[[@as table<string, unknown>]]
end

---@param contribution unknown
---@param index integer
local function checkContribution(contribution, index)
  if type(contribution) ~= "table" then
    Errors.raise("BATTLE_INVALID", "contribution " .. index .. " must be a record", {})
  end
  assert(contribution ~= nil, "the contribution check carries the validated record")
  if type(contribution.owner) ~= "string" or contribution.owner == "" then
    Errors.raise("BATTLE_INVALID", "contribution " .. index .. " must name its owner", {})
  end
  if type(contribution.revision) ~= "string" or contribution.revision == "" then
    Errors.raise("BATTLE_INVALID", "contribution " .. index .. " must name its revision", {})
  end
  if type(contribution.install) ~= "function" then
    Errors.raise("BATTLE_INVALID", "contribution " .. index .. " must carry its installer", {})
  end
  for _, field in ipairs({ "after", "before" }) do
    local declared = (contribution --[[@as table<string, unknown>]])[field]
    if declared ~= nil then
      if type(declared) ~= "table" then
        Errors.raise("BATTLE_INVALID", "contribution " .. index .. " carries " .. field .. " as an array", {})
      end
      for _, owner in
        ipairs(declared --[[@as table<integer, unknown>]])
      do
        if type(owner) ~= "string" or owner == "" then
          Errors.raise("BATTLE_INVALID", "contribution " .. index .. " names " .. field .. " owners", {})
        end
      end
    end
  end
  local suppresses = (contribution --[[@as table<string, unknown>]]).suppresses
  if suppresses ~= nil then
    if type(suppresses) ~= "table" then
      Errors.raise("BATTLE_INVALID", "contribution " .. index .. " carries suppresses as an array", {})
    end
    for _, entry in
      ipairs(suppresses --[[@as table<integer, unknown>]])
    do
      if type(entry) ~= "table" then
        Errors.raise("BATTLE_INVALID", "contribution " .. index .. " suppresses records", {})
      end
      local suppression = entry --[[@as table<string, unknown>]]
      if type(suppression.kind) ~= "string" or suppression.kind == "" then
        Errors.raise("BATTLE_INVALID", "contribution " .. index .. " suppressions name their kind", {})
      end
      if type(suppression.key) ~= "string" or suppression.key == "" then
        Errors.raise("BATTLE_INVALID", "contribution " .. index .. " suppressions name their key", {})
      end
    end
  end
end

---@param contributors table<integer, table<string, unknown>> validated contribution list
---@return table<integer, integer> contributor indices in declared dependency order
local function orderContributors(contributors)
  local count = #contributors
  local byOwner = {}
  for index, contribution in ipairs(contributors) do
    local owners = byOwner[
      contribution.owner --[[@as string]]
    ]
    if owners == nil then
      owners = {}
      byOwner[
        contribution.owner --[[@as string]]
      ] = owners
    end
    owners[#owners + 1] = index
  end
  local successors = {}
  local indegree = {}
  for index = 1, count do
    successors[index] = {}
    indegree[index] = 0
  end
  ---@param from integer
  ---@param to integer
  local function edge(from, to)
    if from == to then
      Errors.raise("BATTLE_INVALID", "contribution " .. from .. " cannot order against itself", {})
    end
    local targets = successors[from]
    for _, known in ipairs(targets) do
      if known == to then
        return
      end
    end
    targets[#targets + 1] = to
    indegree[to] = indegree[to] + 1
  end
  for index, contribution in ipairs(contributors) do
    for _, field in ipairs({ "after", "before" }) do
      local declared = contribution[field]
      if declared ~= nil then
        for _, owner in
          ipairs(declared --[[@as table<integer, string>]])
        do
          local others = byOwner[owner]
          if others ~= nil then
            for _, other in ipairs(others) do
              if field == "after" then
                edge(other, index)
              else
                edge(index, other)
              end
            end
          end
        end
      end
    end
  end
  local ordered = {}
  local ready = {}
  for index = 1, count do
    if indegree[index] == 0 then
      ready[#ready + 1] = index
    end
  end
  while #ready > 0 do
    table.sort(ready)
    local nextIndex = table.remove(ready, 1)
    ordered[#ordered + 1] = nextIndex
    for _, later in ipairs(successors[nextIndex]) do
      indegree[later] = indegree[later] - 1
      if indegree[later] == 0 then
        ready[#ready + 1] = later
      end
    end
  end
  if #ordered ~= count then
    local owners = {}
    for index = 1, count do
      if indegree[index] > 0 then
        owners[#owners + 1] = contributors[index].owner --[[@as string]]
      end
    end
    Errors.raise("BATTLE_INVALID", "contributor dependency cycle reaches " .. table.concat(owners, ", "), {})
  end
  return ordered
end

---@param contributors table<integer, table<string, unknown>> validated contribution list
---@return table<string, boolean> suppressed content and behavior identities
local function suppressedIdentities(contributors)
  local suppressed = {}
  for _, contribution in ipairs(contributors) do
    if contribution.suppresses ~= nil then
      for _, entry in
        ipairs(contribution.suppresses --[[@as table<integer, unknown>]])
      do
        local suppression = entry --[[@as table<string, unknown>]]
        suppressed[
          suppression.kind --[[@as string]] .. "\0" .. suppression.key --[[@as string]]
        ] =
          true
      end
    end
  end
  return suppressed
end

---@class SuppressionContentProxy
---@field private _builder ContentBuilder
---@field private _suppressed table<string, boolean>
local SuppressionContentProxy = {}
SuppressionContentProxy.__index = SuppressionContentProxy

---@param builder ContentBuilder live ordered content builder
---@param suppressed table<string, boolean> suppressed content identities
---@return SuppressionContentProxy suppression-aware content builder proxy
local function wrapContentBuilder(builder, suppressed)
  return setmetatable({ _builder = builder, _suppressed = suppressed }, SuppressionContentProxy)
end

---@param kind string
---@param key string
---@param record table<string, unknown>
---@param owner string
function SuppressionContentProxy:define(kind, key, record, owner)
  if self._suppressed[kind .. "\0" .. key] ~= true then
    self._builder:define(kind, key, record, owner)
  end
end

---@param kind string
---@param key string
---@param ops table<integer, table<string, unknown>>
---@param owner string
function SuppressionContentProxy:patch(kind, key, ops, owner)
  if self._suppressed[kind .. "\0" .. key] ~= true then
    self._builder:patch(kind, key, ops, owner)
  end
end

---@param kind string
---@param oldKey string
---@param key string
---@param owner string
function SuppressionContentProxy:alias(kind, oldKey, key, owner)
  if self._suppressed[kind .. "\0" .. oldKey] ~= true then
    self._builder:alias(kind, oldKey, key, owner)
  end
end

---@return ResolvedContent the frozen composed content snapshot
function SuppressionContentProxy:freeze()
  return self._builder:freeze()
end

---@class SuppressionBehaviorProxy
---@field private _behaviors BattleBehaviorBuilder
---@field private _suppressed table<string, boolean>
local SuppressionBehaviorProxy = {}
SuppressionBehaviorProxy.__index = SuppressionBehaviorProxy

---@param behaviors BattleBehaviorBuilder live typed behavior builder
---@param suppressed table<string, boolean> suppressed behavior identities
---@return SuppressionBehaviorProxy suppression-aware behavior builder proxy
local function wrapBehaviorBuilder(behaviors, suppressed)
  return setmetatable({ _behaviors = behaviors, _suppressed = suppressed }, SuppressionBehaviorProxy)
end

---@param kind string
---@param key string
---@param definition table<string, unknown>
---@param owner string
function SuppressionBehaviorProxy:_register(kind, key, definition, owner)
  if self._suppressed[kind .. "\0" .. key] ~= true then
    if kind == "moves" then
      self._behaviors:registerMove(key, definition, owner)
    elseif kind == "effects" then
      self._behaviors:registerEffect(key, definition, owner)
    elseif kind == "actions" then
      self._behaviors:registerAction(key, definition, owner)
    elseif kind == "formats" then
      self._behaviors:registerFormat(key, definition, owner)
    elseif kind == "rulesets" then
      self._behaviors:registerRuleset(key, definition, owner)
    else
      Errors.raise("BATTLE_INVALID", "unknown behavior kind " .. kind, { kind = kind })
    end
  end
end

---@param key string
---@param definition table<string, unknown>
---@param owner string
function SuppressionBehaviorProxy:registerMove(key, definition, owner)
  self:_register("moves", key, definition, owner)
end

---@param key string
---@param definition table<string, unknown>
---@param owner string
function SuppressionBehaviorProxy:registerEffect(key, definition, owner)
  self:_register("effects", key, definition, owner)
end

---@param key string
---@param definition table<string, unknown>
---@param owner string
function SuppressionBehaviorProxy:registerAction(key, definition, owner)
  self:_register("actions", key, definition, owner)
end

---@param key string
---@param definition table<string, unknown>
---@param owner string
function SuppressionBehaviorProxy:registerFormat(key, definition, owner)
  self:_register("formats", key, definition, owner)
end

---@param key string
---@param definition table<string, unknown>
---@param owner string
function SuppressionBehaviorProxy:registerRuleset(key, definition, owner)
  self:_register("rulesets", key, definition, owner)
end

---@return BoundBehaviors the frozen bound behavior registries
function SuppressionBehaviorProxy:freeze()
  return self._behaviors:freeze()
end

-- Runs the supplied ordered contributions through fresh builders and
-- freezes the result. Declared `after`/`before` owners decide application
-- order over contributor input order while numeric `priority` fields never
-- do; dependency cycles fail, and `suppresses` entries remove exactly the
-- named canonical contributions. Any contributor failure prevents
-- publication: nothing is returned and no partial composition escapes.
---@param contributors table<integer, table<string, unknown>>
---@return ResolvedContent resolved the frozen composed content snapshot
---@return BoundBehaviors bound the frozen bound behavior registries
---@return BattleContent content the frozen executable battle binding set
function Battle.compose(contributors)
  assert(Battle.apiVersion == 1, "the battle entrypoint carries its version")
  if type(contributors) ~= "table" then
    Errors.raise("BATTLE_INVALID", "composition requires its ordered contributors", {})
  end
  for index, contribution in ipairs(contributors) do
    checkContribution(contribution, index)
  end
  local ordered = orderContributors(contributors)
  local suppressed = suppressedIdentities(contributors)
  local builder = ContentBuilder.new()
  local behaviors = BattleBehaviorBuilder.new()
  local contentProxy = wrapContentBuilder(builder, suppressed)
  local behaviorProxy = wrapBehaviorBuilder(behaviors, suppressed)
  for key, definition in pairs(registeredFormats) do
    if suppressed["formats" .. "\0" .. key] ~= true then
      behaviorProxy:registerFormat(key, definition, "gen4.battle")
    end
  end
  for key, definition in pairs(registeredActions) do
    if suppressed["actions" .. "\0" .. key] ~= true then
      behaviorProxy:registerAction(key, definition, "gen4.battle")
    end
  end
  for _, index in ipairs(ordered) do
    local contribution = contributors[index]
    local install = contribution.install
    assert(type(install) == "function", "validated contributions carry their installer")
    install(contentProxy, behaviorProxy)
  end
  local bound = behaviors:freeze()
  local resolved = builder:freeze()
  return resolved, bound, BattleContent.new(resolved, bound)
end

---@return table<string, unknown> minimal persistent mon scaffold for generated scenarios
local function scaffoldMon()
  return { schema = Mon.SCHEMA, condition = { currentHp = 20 } }
end

-- Builds a detached scenario scaffold from a minimal specification. The
-- caller names the content ruleset, the battle format, and the unsigned
-- 32-bit random seed; everything else falls back to a one-active-per-side
-- singles scaffold the caller may override field by field. The scaffold is
-- validated before it returns, while ruleset and format binding stay with
-- session construction against frozen content.
---@param spec table<string, unknown> minimal scenario specification under construction
---@return table<string, unknown> detached validated battle setup record
function Battle.createScenario(spec)
  assert(Battle.apiVersion == 1, "the battle entrypoint carries its version")
  if type(spec) ~= "table" then
    Errors.raise("BATTLE_INVALID", "scenario construction requires its specification", {})
  end
  local record = spec --[[@as table<string, unknown>]]
  if type(record.ruleset) ~= "string" or record.ruleset == "" then
    Errors.raise("BATTLE_INVALID", "scenarios must name their ruleset", {})
  end
  if type(record.format) ~= "string" or record.format == "" then
    Errors.raise("BATTLE_INVALID", "scenarios must name their format", {})
  end
  local seed = record.seed
  if type(seed) ~= "number" or seed ~= seed or seed % 1 ~= 0 or seed < 0 or seed > 4294967295 then
    Errors.raise("BATTLE_INVALID", "scenario random seeds must be unsigned 32-bit integers", {})
  end
  local scenario = {
    ruleset = record.ruleset,
    format = record.format,
    sides = record.sides or {
      { id = 1, participants = { 1 } },
      { id = 2, participants = { 2 } },
    },
    participants = record.participants or {
      { id = 1, side = 1, controller = "alpha", roster = { { id = 1, mon = scaffoldMon() } }, context = {} },
      { id = 2, side = 2, controller = "beta", roster = { { id = 2, mon = scaffoldMon() } }, context = {} },
    },
    positions = record.positions or {
      { id = 1, side = 1, eligibleParticipants = { 1 }, occupant = 1 },
      { id = 2, side = 2, eligibleParticipants = { 2 }, occupant = 2 },
    },
    inventories = record.inventories or {},
    environment = record.environment or { weather = "none" },
    random = { seed = seed },
    formatState = record.formatState or {},
  }
  return BattleScenario.validate(scenario)
end

-- Constructs a headless session over a detached scenario copy and frozen
-- content. The scenario is validated before anything publishes, and the
-- returned session owns its private state for its whole lifetime. The
-- scenario's bound ruleset selects the mechanics executor: the native HGSS
-- key runs the private native lifecycle, while every other bound ruleset
-- keeps the generic session, so custom content never changes behavior.
---@param scenario table<string, unknown> detached serializable battle setup
---@param content BattleContent frozen executable battle content
---@return table<string, unknown> live headless session
function Battle.newSession(scenario, content)
  assert(Battle.apiVersion == 1, "the battle entrypoint carries its version")
  if type(scenario) == "table" and scenario.ruleset ~= nil then
    local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
    if scenario.ruleset == Executor.RULESET then
      return Executor.new(scenario, content)
    end
  end
  local BattleSession = require("libs.battle.src.BattleSession")
  return BattleSession.new(scenario, content)
end

return Battle
