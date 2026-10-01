-- Shared builders for the headless battle session suites: frozen
-- composition from the real content owner, real mon records from the mon
-- domain owner, deterministic battle setup records, the test-owned decision
-- vocabulary, and small session drivers. Nothing here fakes catalog, item,
-- or party state; battle state itself comes only from the session owner
-- once it exists.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")

local SessionFixture = {}

SessionFixture.RULESET = "test:scripted"
SessionFixture.FORMAT = "test:scripted"
SessionFixture.RANDOM_SEED = 287454020

local cachedCatalog = nil

---@return table mon catalog built once from the fixed synthetic asset root
local function catalog()
  if cachedCatalog == nil then
    cachedCatalog = CatalogFixture.makeCatalog()
  end
  assert(cachedCatalog ~= nil, "the mon catalog builds from its fixture root")
  return cachedCatalog
end

--- Loads a battle module, failing with the behavior it provides instead of
--- a bare loader error.
---@param name string
---@param behavior string
---@return table
function SessionFixture.requirePresent(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing battle behavior: " .. behavior .. " (" .. name .. ")")
  assert(loaded ~= nil, "the battle module loads")
  return loaded --[[@as table]]
end

--- Requires the session, protocol, state, view, and snapshot owners plus
--- the battle entrypoint constructor they are exposed through.
---@return table contracts keyed by owner name
function SessionFixture.sessionContracts()
  local contracts = {
    Scenario = SessionFixture.requirePresent(
      "libs.battle.src.BattleScenario",
      "detached scenario validation owns setup order and membership"
    ),
    State = SessionFixture.requirePresent(
      "libs.battle.src.BattleState",
      "private battle data owns reference invariants"
    ),
    Protocol = SessionFixture.requirePresent(
      "libs.battle.src.BattleProtocol",
      "typed requests, replies, and events own the external protocol"
    ),
    Session = SessionFixture.requirePresent(
      "libs.battle.src.BattleSession",
      "one session owns simulation lifetime and stepping"
    ),
    Context = SessionFixture.requirePresent(
      "libs.battle.src.BattleContext",
      "validated mutation surface owns mechanics writes"
    ),
    View = SessionFixture.requirePresent(
      "libs.battle.src.BattleView",
      "perspective-safe snapshots own presentation reads"
    ),
    Snapshot = SessionFixture.requirePresent(
      "libs.battle.src.BattleSnapshot",
      "typed transient capture owns interruption state"
    ),
    DomainErrors = SessionFixture.requirePresent(
      "libs.battle.src.errors",
      "domain errors separate invalid input from broken invariants"
    ),
  }
  local Battle = require("gen4.battle")
  Assert.isTrue(
    type(Battle.newSession) == "function",
    "missing battle behavior: the battle entrypoint constructs headless sessions (gen4.battle.newSession)"
  )
  contracts.Battle = Battle
  return contracts
end

---@param attack string
---@param defend string
---@param numerator integer
---@param denominator integer
---@return table<string, unknown>
local function relation(attack, defend, numerator, denominator)
  return { attack = attack, defend = defend, numerator = numerator, denominator = denominator }
end

--- Frozen executable content carrying only the closed test ruleset over
--- the three base types with every directed pair resolved.
---@return table frozen battle content for session tests
function SessionFixture.makeContent()
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local builder = ContentBuilder.new()
  local behaviors = BattleBehaviorBuilder.new()
  local keys = { "normal", "fire", "water" }
  for _, key in ipairs(keys) do
    local scoped = {}
    for _, other in ipairs(keys) do
      local numerator, denominator = 1, 1
      if key == "fire" and other ~= "normal" then
        numerator, denominator = 1, 2
      elseif key == "water" and other == "fire" then
        numerator, denominator = 2, 1
      elseif key == "water" and other == "water" then
        numerator, denominator = 1, 2
      end
      scoped[#scoped + 1] = relation(key, other, numerator, denominator)
    end
    builder:define("types", key, { key = key, name = key, relations = scoped }, "session-tests")
  end
  behaviors:registerRuleset(
    SessionFixture.RULESET,
    { key = SessionFixture.RULESET, chart = SessionFixture.RULESET },
    "session-tests"
  )
  behaviors:registerFormat(
    SessionFixture.FORMAT,
    { key = SessionFixture.FORMAT, chart = SessionFixture.RULESET },
    "session-tests"
  )
  local bound = behaviors:freeze()
  local resolved = builder:freeze()
  return BattleContent.new(resolved, bound)
end

--- A real validated persistent mon record with a fixed identity per seed.
---@param seed integer fixed generator state for this roster member
---@param overrides table<string, unknown>|nil generation request overrides
---@return table persistent mon record owned by the mon domain
function SessionFixture.makeMon(seed, overrides)
  local factory = CatalogFixture.makeFactory(seed, catalog())
  return factory:createNormal(CatalogFixture.normalRequest(overrides or {}))
end

--- A roster entry with an explicit battle-local combatant identity.
---@param id integer nonreused positive combatant identity
---@param seed integer fixed generator state for the underlying mon
---@return table combatant seed in deterministic scenario order
function SessionFixture.combatant(id, seed)
  return { id = id, mon = SessionFixture.makeMon(seed) }
end

---@param id integer
---@param participantIds integer[]
---@return table side record owning its alliance membership
function SessionFixture.side(id, participantIds)
  return { id = id, participants = participantIds }
end

---@param id integer
---@param sideId integer
---@param controller string decision producer owning this roster
---@param roster table[] combatant seeds in scenario order
---@param inventoryId string|nil shared or private inventory handle
---@return table participant record owning its roster and context
function SessionFixture.participant(id, sideId, controller, roster, inventoryId)
  local spec = {
    id = id,
    side = sideId,
    controller = controller,
    roster = roster,
    context = {},
  }
  if inventoryId ~= nil then
    spec.inventoryId = inventoryId
  end
  return spec
end

---@param id integer
---@param sideId integer
---@param eligible integer[] participants allowed to occupy this slot
---@param occupant integer|nil combatant currently holding this slot
---@return table position record owning its occupancy
function SessionFixture.position(id, sideId, eligible, occupant)
  local spec = { id = id, side = sideId, eligibleParticipants = eligible }
  if occupant ~= nil then
    spec.occupant = occupant
  end
  return spec
end

---@param id string
---@param owners integer[]
---@param quantities table<string, integer>
---@return table inventory seed with explicit ownership
function SessionFixture.inventory(id, owners, quantities)
  return { id = id, owners = owners, quantities = quantities }
end

---@class ScenarioParts
---@field sides table[]
---@field participants table[]
---@field positions table[]
---@field inventories table[]

--- Assembles a detached serializable battle setup with fixed ruleset,
--- environment, and random state; only the topology varies per caller.
---@param parts ScenarioParts
---@return table battle setup record in deterministic order
function SessionFixture.buildScenario(parts)
  return {
    ruleset = SessionFixture.RULESET,
    format = SessionFixture.FORMAT,
    sides = parts.sides,
    participants = parts.participants,
    positions = parts.positions,
    inventories = parts.inventories or {},
    environment = { weather = "none" },
    random = { seed = SessionFixture.RANDOM_SEED },
    formatState = {},
  }
end

--- Constructs a session from an owned scenario copy and frozen content.
---@param contracts table owners from sessionContracts
---@param scenario table detached battle setup record
---@return table live headless session
function SessionFixture.newSession(contracts, scenario)
  local session = contracts.Battle.newSession(scenario, SessionFixture.makeContent())
  Assert.notNil(session, "session construction publishes a usable session")
  return session
end

---@param id integer
---@return table retargetable reference following the slot occupant
function SessionFixture.positionTarget(id)
  return { kind = "position", position = id }
end

---@param id integer
---@param activation integer|nil entry token locking the reference
---@return table roster reference pinned to a combatant entry
function SessionFixture.combatantTarget(id, activation)
  local ref = { kind = "combatant", combatant = id }
  if activation ~= nil then
    ref.activation = activation
  end
  return ref
end

---@param actor table combatant reference the choice is issued for
---@param moveSlot integer zero-based move slot
---@param target table target reference in the documented variants
---@return table validated decision payload for a strike
function SessionFixture.attackChoice(actor, moveSlot, target)
  return { actor = actor, kind = "attack", payload = { moveSlot = moveSlot, target = target } }
end

---@param actor table combatant reference leaving the field
---@param replacement integer combatant entering the vacated slot
---@return table validated decision payload for a replacement
function SessionFixture.switchChoice(actor, replacement)
  return { actor = actor, kind = "switch", payload = { replacement = replacement } }
end

---@param actor table combatant reference answering the prompt
---@return table validated decision payload acknowledging a prompt
function SessionFixture.confirmChoice(actor)
  return { actor = actor, kind = "confirm", payload = {} }
end

--- Builds the reply answering one pending request with per-actor choices.
---@param request table pending decision request
---@param choices table[] one choice per addressed actor
---@return table decision reply tied to the request identity and epoch
function SessionFixture.replyFor(request, choices)
  return {
    requestId = request.requestId,
    epoch = request.epoch,
    controller = request.controller,
    choices = choices,
  }
end

--- Advances until the session waits for input or ends, bounding the walk
--- so a stuck kernel fails loudly instead of spinning forever.
---@param session table live headless session
---@param budget integer|nil operations per advance call
---@return table frame waiting for decisions or reporting the outcome
function SessionFixture.driveUntilSettled(session, budget)
  local frame = nil
  for _ = 1, 64 do
    frame = session:advance(budget)
    Assert.notNil(frame, "advance returns a battle frame")
    Assert.isTrue(
      frame.status == "running" or frame.status == "waiting" or frame.status == "ended",
      "frames report running, waiting, or ended"
    )
    if frame.status ~= "running" then
      return frame
    end
  end
  error("session did not settle within its operation bound")
end

--- Advances until every event so far is collected and the session ends.
---@param session table live headless session
---@param budget integer|nil operations per advance call
---@param answer fun(request: table): table[] choices per pending request
---@return table[] every emitted event in sequence order
function SessionFixture.driveToEnd(session, budget, answer)
  local collected = {}
  for _ = 1, 256 do
    local frame = session:advance(budget)
    Assert.notNil(frame, "advance returns a battle frame")
    if frame.events ~= nil then
      for _, event in ipairs(frame.events) do
        collected[#collected + 1] = event
      end
    end
    if frame.status == "ended" then
      return collected
    end
    Assert.equal(frame.status, "waiting", "open sessions wait for decisions")
    Assert.notNil(frame.request, "waiting frames carry their decision batch")
    for _, request in ipairs(frame.request.requests) do
      local ok, err = session:submit(SessionFixture.replyFor(request, answer(request)))
      Assert.isTrue(ok, "scripted answers to open requests are accepted")
      Assert.isNil(err, "accepted replies carry no input error")
    end
  end
  error("session did not end within its operation bound")
end

--- Fails when any table reachable from the value carries a live function,
--- thread, or userdata reference: interruption state must stay plain data.
---@param value unknown interruption state under inspection
---@param path string|nil breadcrumb for diagnostics
function SessionFixture.assertPlainData(value, path)
  path = path or "snapshot"
  local seen = {}
  local function visit(node, trail)
    local kind = type(node)
    Assert.isTrue(kind ~= "function", trail .. " must not capture a function")
    Assert.isTrue(kind ~= "thread", trail .. " must not capture a thread")
    Assert.isTrue(kind ~= "userdata", trail .. " must not capture userdata")
    if kind == "table" then
      Assert.isNil(seen[node], trail .. " must not loop back on itself")
      seen[node] = true
      for key, item in pairs(node) do
        visit(item, trail .. "." .. tostring(key))
      end
    end
  end
  visit(value, path)
end

return SessionFixture
