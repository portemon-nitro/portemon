-- Field, trainer, and wild sources mapped to one detached scenario shape.
-- Every constructor copies its inputs once and never rerolls: attempt
-- identities, prepared personalities, and supplied mon records survive
-- byte-identical, and later caller-side mutations can never reach the
-- emitted scenario. The output is kernel-scenario-shaped plain data (the
-- application battle owner stamps the executable ruleset and builds the
-- live session); this module never imports the battle package.
--
-- Mon identity policy: a supplied full mon-domain record is copied through
-- untouched; a bare descriptor (species/level without a record) becomes a
-- descriptor-sourced kernel combatant with fixed entry health. Production
-- encounters always carry materialized records (the encounter service
-- builds them through the wild factory), so the fixed entry health only
-- ever backs headless descriptor input and is never written to a live
-- owner. Species truth stays with the mon catalog upstream: an unknown
-- species string rides through here and fails at its owning boundary, but
-- a missing level or party is malformed input and fails here.

local Mon = require("libs.mons.src.Mon")

---@class HgssBattleScenarioFactory
local HgssBattleScenarioFactory = {}

-- Entry health for descriptor-sourced combatants: enough to survive the
-- kernel's bounded round budget in a singles fight, so headless descriptor
-- battles settle through the normal round bound instead of underflowing
-- into instant outcomes. Never persisted: only party-sourced combatants
-- carry a writeback source.
HgssBattleScenarioFactory.DESCRIPTOR_ENTRY_HP = 12
HgssBattleScenarioFactory.DESCRIPTOR_LEVEL = 5

HgssBattleScenarioFactory.PLAYER_CONTROLLER = "player"
HgssBattleScenarioFactory.WILD_CONTROLLER = "wild"

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

---@param value unknown
---@return boolean
local function isU32(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 0xFFFFFFFF
end

-- Stable non-cryptographic identity hash for seed derivation. Only the
-- determinism matters (same input identity always yields the same seed);
-- the values carry no gameplay meaning.
---@param text string
---@return integer
local function hashIdentity(text)
  local hash = 0x811C9DC5
  for index = 1, #text do
    hash = (hash * 33 + string.byte(text, index)) % 0x100000000
  end
  return hash
end

---@param payload table<string, unknown>
---@return integer stable seed for the detached scenario
local function scenarioSeed(payload)
  if isU32(payload.seed) then
    return payload.seed --[[@as integer]]
  end
  if isU32(payload.personality) then
    return payload.personality --[[@as integer]]
  end
  local anchor = payload.attemptId or payload.id or payload.species or payload.trainer or "battle"
  return hashIdentity(tostring(anchor))
end

---@param mon unknown
---@return boolean true when the value is a full mon-domain record
local function isFullRecord(mon)
  return type(mon) == "table" and mon.schema == Mon.SCHEMA and type(mon.condition) == "table"
end

---@param descriptor table<string, unknown>
---@return table<string, unknown> descriptor-sourced kernel combatant mon
local function descriptorMon(descriptor)
  local species = descriptor.species
  assert(type(species) == "string" and species ~= "", "descriptor combatants name their species")
  local level = descriptor.level
  if level == nil then
    level = HgssBattleScenarioFactory.DESCRIPTOR_LEVEL
  end
  assert(type(level) == "number" and level % 1 == 0, "descriptor combatant levels stay integral")
  local mon = {
    schema = Mon.SCHEMA,
    species = species,
    level = level,
    form = descriptor.form or 0,
    condition = { currentHp = HgssBattleScenarioFactory.DESCRIPTOR_ENTRY_HP },
  }
  if descriptor.personality ~= nil then
    mon.personality = descriptor.personality
  end
  if descriptor.ability ~= nil then
    mon.ability = descriptor.ability
  end
  return mon
end

---@param party unknown
---@return table<string, unknown>? detached live lead plus its zero-based slot
local function snapshotLead(party)
  if type(party) ~= "table" then
    return nil
  end
  local service = party --[[@as table<string, unknown>]]
  if type(service.partyCount) ~= "function" then
    return nil
  end
  if service:partyCount() == 0 then
    return nil
  end
  -- The conscious lead fields the player side, matching native entry.
  -- A wiped party yields no snapshot (the placeholder path below), so a
  -- fainted roster can never leak live state into the detached scenario.
  if type(service.leadAliveSlot) ~= "function" then
    return nil
  end
  local slot = service:leadAliveSlot()
  if slot == nil then
    return nil
  end
  assert(type(slot) == "number" and slot % 1 == 0 and slot >= 0, "party leads sit in a zero-based slot")
  local mon = service:partyMon(slot)
  assert(type(mon) == "table", "the live party carries its lead record")
  local revision = 0
  if type(service.partyRevision) == "function" then
    revision = service:partyRevision()
  end
  return { mon = copyValue(mon), slot = slot, revision = revision }
end

---@param snapshot table<string, unknown>?
---@param combatantId integer
---@return table<string, unknown> kernel combatant seed for the player side
local function playerSeed(snapshot, combatantId)
  if snapshot ~= nil then
    return {
      id = combatantId,
      mon = snapshot.mon,
      source = {
        kind = "party",
        owner = "player",
        key = "party",
        slot = snapshot.slot + 1,
        revision = snapshot.revision,
      },
    }
  end
  return {
    id = combatantId,
    mon = {
      schema = Mon.SCHEMA,
      species = "UNKNOWN",
      level = HgssBattleScenarioFactory.DESCRIPTOR_LEVEL,
      form = 0,
      condition = { currentHp = HgssBattleScenarioFactory.DESCRIPTOR_ENTRY_HP },
    },
    source = { kind = "placeholder", owner = "field", key = "placeholder" },
  }
end

---@param mon table<string, unknown> detached enemy mon (record or descriptor)
---@param combatantId integer
---@param source table<string, unknown>
---@return table<string, unknown> kernel combatant seed for the enemy side
local function enemySeed(mon, combatantId, source)
  local combatant = mon
  if not isFullRecord(mon) then
    assert(type(mon) == "table", "enemy combatants carry a mon descriptor or record")
    combatant = descriptorMon(mon --[[@as table<string, unknown>]])
  end
  return { id = combatantId, mon = combatant, source = source }
end

---@param fragment table<string, unknown>
---@return table<string, unknown> kernel-scenario-shaped record (ruleset stamped by the consumer)
local function kernelShape(fragment)
  return {
    attemptId = fragment.attemptId,
    kind = fragment.kind,
    format = fragment.format,
    sides = fragment.sides,
    participants = fragment.participants,
    positions = fragment.positions,
    inventories = fragment.inventories,
    environment = fragment.environment,
    random = fragment.random,
    formatState = fragment.formatState,
    mon = fragment.mon,
    trainer = fragment.trainer,
  }
end

---@param payload table<string, unknown>
---@param heart table<string, unknown> normalized enemy description
---@return table<string, unknown> scenario fragment
local function assemble(payload, heart)
  assert(type(payload) == "table", "scenario sources arrive as records")
  local sides = {
    { id = 1, participants = { 1 } },
    { id = 2, participants = heart.enemyIds },
  }
  local participants = {
    {
      id = 1,
      side = 1,
      controller = HgssBattleScenarioFactory.PLAYER_CONTROLLER,
      roster = { heart.player },
      context = {},
    },
  }
  for index, enemy in ipairs(heart.enemies) do
    participants[#participants + 1] = enemy
    assert(enemy.id == heart.enemyIds[index], "enemy membership follows participant order")
  end
  local positions = {
    { id = 1, side = 1, eligibleParticipants = { 1 }, occupant = heart.player.id },
  }
  for index, enemy in ipairs(heart.enemies) do
    local lead = enemy.roster[1]
    assert(type(lead) == "table" and type(lead.id) == "number", "enemy participants declare their lead")
    positions[#positions + 1] = {
      id = 1 + index,
      side = 2,
      eligibleParticipants = { enemy.id },
      occupant = lead.id,
    }
  end
  return kernelShape({
    attemptId = heart.attemptId,
    kind = heart.kind,
    format = heart.format,
    sides = sides,
    participants = participants,
    positions = positions,
    inventories = copyValue(payload.inventories) or {},
    environment = copyValue(payload.environment) or { weather = "none" },
    random = { seed = scenarioSeed(payload) },
    formatState = copyValue(payload.formatState) or {},
    mon = heart.mon,
    trainer = heart.trainer,
  })
end

-- Builds the wild-battle fragment from a prepared encounter or a bare wild
-- descriptor. The payload carries the encounter identity (attemptId or id),
-- the enemy as `mon` (a full record or a species/level descriptor), and the
-- optional format/environment overrides. The live party lead (ctx.party)
-- fields the player side when present; without one the player side enters
-- as an explicitly marked placeholder that can never write back.
---@param payload table<string, unknown>
---@param ctx table<string, unknown>?
---@return table<string, unknown> detached wild scenario fragment
function HgssBattleScenarioFactory.fromEncounter(payload, ctx)
  assert(type(payload) == "table", "wild sources arrive as records")
  local context = ctx or {}
  assert(type(context) == "table", "scenario context stays a record")
  local enemy = payload.mon
  if enemy == nil and type(payload.species) == "string" then
    enemy = {
      species = payload.species,
      level = payload.level,
      form = payload.form,
      personality = payload.personality,
      ability = payload.ability,
    }
  end
  if type(enemy) ~= "table" then
    error("wild battles require their enemy mon descriptor or record", 0)
  end
  assert(type(enemy) == "table", "the enemy check carries the mon value")
  if not isFullRecord(enemy) then
    local descriptor = enemy --[[@as table<string, unknown>]]
    if type(descriptor.species) ~= "string" or descriptor.species == "" then
      error("wild battles require their enemy species", 0)
    end
    if
      type(descriptor.level) ~= "number"
      or descriptor.level % 1 ~= 0
      or descriptor.level < 1
      or descriptor.level > 100
    then
      error("wild battles require their enemy level in 1..100", 0)
    end
  end
  local attemptId = payload.attemptId or payload.id
  local lead = snapshotLead(context.party)
  local player = playerSeed(lead, 1)
  local key = attemptId or enemy.species or "wild"
  local foe = enemySeed(copyValue(enemy), 2, {
    kind = "wild",
    owner = "enemy",
    key = tostring(key),
  })
  return assemble(payload, {
    attemptId = attemptId,
    kind = "wild",
    format = payload.format or "wild-single",
    enemyIds = { 2 },
    player = player,
    enemies = {
      { id = 2, side = 2, controller = HgssBattleScenarioFactory.WILD_CONTROLLER, roster = { foe }, context = {} },
    },
    mon = copyValue(enemy),
    trainer = nil,
  })
end

-- Builds the trainer-battle fragment. The payload names the trainer (or
-- trainers, for simultaneous native pairs) and carries each trainer's full
-- party records; trainer parties are never invented here. Each trainer
-- fields its own participant (and controller) so simultaneous pairs keep
-- their native double engagement. The bound selection program rides the
-- participant context when supplied and stays absent otherwise; the
-- application battle owner refuses to run a trainer side without one.
---@param payload table<string, unknown>
---@param ctx table<string, unknown>?
---@return table<string, unknown> detached trainer scenario fragment
function HgssBattleScenarioFactory.fromTrainer(payload, ctx)
  assert(type(payload) == "table", "trainer sources arrive as records")
  local context = ctx or {}
  assert(type(context) == "table", "scenario context stays a record")
  local trainers = payload.trainers
  if trainers == nil then
    if type(payload.trainer) ~= "string" and type(payload.trainer) ~= "number" then
      error("trainer battles require their trainer identity", 0)
    end
    if payload.trainer == "" then
      error("trainer battles require their trainer identity", 0)
    end
    trainers = { { id = payload.trainer, party = payload.party, program = payload.program } }
  end
  assert(type(trainers) == "table" and #trainers > 0, "trainer battles field at least one trainer")
  local lead = snapshotLead(context.party)
  local player = playerSeed(lead, 1)
  local enemies = {}
  local enemyIds = {}
  local combatantId = 1
  for index, trainer in ipairs(trainers) do
    assert(type(trainer) == "table", "trainer entries stay records")
    local entry = trainer --[[@as table<string, unknown>]]
    if type(entry.id) ~= "string" and type(entry.id) ~= "number" then
      error("trainer battles require every trainer identity", 0)
    end
    if entry.id == "" then
      error("trainer battles require every trainer identity", 0)
    end
    local party = entry.party or (index == 1 and context.trainerParty or nil)
    if type(party) ~= "table" or #party == 0 then
      error("trainer battles require their trainer party records", 0)
    end
    assert(type(party) == "table", "the party check carries the trainer party")
    local roster = {}
    for _, member in ipairs(party) do
      if not isFullRecord(member) then
        error("trainer parties carry full mon records", 0)
      end
      combatantId = combatantId + 1
      roster[#roster + 1] = {
        id = combatantId,
        mon = copyValue(member),
        source = { kind = "trainer", owner = "enemy", key = tostring(entry.id) },
      }
    end
    local participantId = 1 + index
    enemyIds[#enemyIds + 1] = participantId
    local enemyContext = {}
    local program = entry.program or (index == 1 and context.trainerProgram or nil)
    if program ~= nil then
      enemyContext.program = copyValue(program)
    end
    enemies[#enemies + 1] = {
      id = participantId,
      side = 2,
      controller = "trainer:" .. entry.id,
      roster = roster,
      context = enemyContext,
    }
  end
  local attemptId = payload.attemptId or payload.id
  return assemble(payload, {
    attemptId = attemptId,
    kind = "trainer",
    format = payload.format or (#trainers > 1 and "double" or "single"),
    enemyIds = enemyIds,
    player = player,
    enemies = enemies,
    mon = nil,
    trainer = copyValue(trainers),
  })
end

-- Builds the scripted-battle fragment (tutorial, rival story variants, and
-- other explicitly staged fights). The payload carries the kernel sides,
-- participants, and positions verbatim; nothing is inferred or defaulted
-- beyond the shared environment/format-state containers, so an incomplete
-- staged fight fails loudly instead of entering half-built.
---@param payload table<string, unknown>
---@param ctx table<string, unknown>?
---@return table<string, unknown> detached scripted scenario fragment
function HgssBattleScenarioFactory.fromScript(payload, ctx)
  assert(type(payload) == "table", "scripted sources arrive as records")
  local context = ctx or {}
  assert(type(context) == "table", "scenario context stays a record")
  for _, field in ipairs({ "sides", "participants", "positions" }) do
    if type(payload[field]) ~= "table" or #payload[field] == 0 then
      error("scripted battles declare their " .. field, 0)
    end
  end
  return kernelShape({
    attemptId = payload.attemptId or payload.id,
    kind = "scripted",
    format = payload.format or "single",
    sides = copyValue(payload.sides),
    participants = copyValue(payload.participants),
    positions = copyValue(payload.positions),
    inventories = copyValue(payload.inventories) or {},
    environment = copyValue(payload.environment) or { weather = "none" },
    random = { seed = scenarioSeed(payload) },
    formatState = copyValue(payload.formatState) or {},
    mon = copyValue(payload.mon),
    trainer = copyValue(payload.trainer),
  })
end

return HgssBattleScenarioFactory
