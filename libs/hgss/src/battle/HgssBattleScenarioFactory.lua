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

-- Production player snapshot: every live party slot is read exactly once
-- and every non-egg record becomes a roster combatant in slot order with
-- the one party revision stamped on each seed. Eggs never become battle
-- combatants; fainted non-eggs ride along as ineligible benched records.
-- Without a live party service there is no snapshot (headless staged
-- drivers keep the explicit placeholder below); with one, a missing
-- conscious non-egg fails the build instead of inventing a combatant.
---@param party unknown
---@return table<string, unknown>? ordered seeds plus the opening roster index
local function snapshotParty(party)
  if type(party) ~= "table" then
    return nil
  end
  local service = party --[[@as table<string, unknown>]]
  if type(service.partyCount) ~= "function" or type(service.partyMon) ~= "function" then
    return nil
  end
  local revision = 0
  if type(service.partyRevision) == "function" then
    revision = service:partyRevision()
  end
  local count = service:partyCount()
  assert(type(count) == "number" and count % 1 == 0 and count >= 0, "party counts stay non-negative integers")
  local seeds = {} ---@type table<integer, table<string, unknown>>
  for slot0 = 0, count - 1 do
    local mon = service:partyMon(slot0)
    assert(type(mon) == "table", "the live party carries every slot record")
    local record = mon --[[@as table<string, unknown>]]
    if not record.isEgg then
      seeds[#seeds + 1] = { mon = copyValue(record), slot = slot0 + 1, revision = revision }
    end
  end
  if #seeds == 0 then
    error("production battles require a non-egg party member", 0)
  end
  -- The conscious lead fields the opening position, matching native
  -- entry. The slot must correspond to an included living non-egg, so a
  -- wiped roster fails here instead of leaking fainted state as an
  -- opener.
  local opening = nil ---@type integer?
  if type(service.leadAliveSlot) == "function" then
    local slot = service:leadAliveSlot()
    if slot ~= nil then
      assert(type(slot) == "number" and slot % 1 == 0 and slot >= 0, "party leads sit in a zero-based slot")
      for index, seed in ipairs(seeds) do
        if seed.slot == slot + 1 then
          local condition = (seed.mon --[[@as table<string, unknown>]]).condition
          if type(condition) == "table" and condition.currentHp > 0 then
            opening = index
          end
          break
        end
      end
      if opening == nil then
        error("production battles require a conscious opening combatant", 0)
      end
    else
      error("production battles require a conscious party member", 0)
    end
  else
    for index, seed in ipairs(seeds) do
      local condition = (seed.mon --[[@as table<string, unknown>]]).condition
      if type(condition) == "table" and condition.currentHp > 0 then
        opening = index
        break
      end
    end
    if opening == nil then
      error("production battles require a conscious party member", 0)
    end
  end
  return { seeds = seeds, opening = opening }
end

---@param snapshot table<string, unknown>? ordered party seeds plus the opening roster index
---@return table<string, unknown>[] ordered kernel combatant seeds for the player side
---@return integer opening combatant identity holding the first position
local function playerRoster(snapshot)
  if snapshot ~= nil then
    local roster = {} ---@type table<string, unknown>[]
    for index, seed in
      ipairs(snapshot.seeds --[[@as table<integer, table<string, unknown>>]])
    do
      local entry = seed --[[@as table<string, unknown>]]
      roster[#roster + 1] = {
        id = index,
        mon = entry.mon,
        source = {
          kind = "party",
          owner = "player",
          key = "party",
          slot = entry.slot,
          revision = entry.revision,
        },
      }
    end
    return roster, snapshot.opening --[[@as integer]]
  end
  return {
    {
      id = 1,
      mon = {
        schema = Mon.SCHEMA,
        species = "UNKNOWN",
        level = HgssBattleScenarioFactory.DESCRIPTOR_LEVEL,
        form = 0,
        condition = { currentHp = HgssBattleScenarioFactory.DESCRIPTOR_ENTRY_HP },
      },
      source = { kind = "placeholder", owner = "field", key = "placeholder" },
    },
  },
    1
end

-- Flattens one detached bag capture into battle stock: every pocket stack
-- contributes its semantic item quantity, registration and ordering never
-- enter battle state, and a repeated item across stacks fails as an
-- internal invariant breach because live storage keeps one stack per item.
---@param bag unknown live bag service under projection
---@return table<string, integer> detached positive battle stock by semantic item key
local function flattenBag(bag)
  local stock = {} ---@type table<string, integer>
  if type(bag) ~= "table" then
    return stock
  end
  local service = bag --[[@as table<string, unknown>]]
  if type(service.capture) ~= "function" then
    return stock
  end
  local captured = service:capture()
  assert(type(captured) == "table", "bag projection reads the detached capture")
  local pockets = (captured --[[@as table<string, unknown>]]).pockets
  assert(type(pockets) == "table", "bag captures carry their pockets")
  for _, slots in
    pairs(pockets --[[@as table<string, table>]])
  do
    assert(type(slots) == "table", "bag pockets carry their stacks")
    for _, slot in ipairs(slots) do
      assert(type(slot) == "table", "bag pocket slots stay records")
      local entry = slot --[[@as table<string, unknown>]]
      assert(type(entry.item) == "string" and entry.item ~= "", "bag stacks name their item")
      assert(
        type(entry.quantity) == "number" and entry.quantity % 1 == 0 and entry.quantity >= 1,
        "bag stacks carry positive quantities"
      )
      if
        stock[
          entry.item --[[@as string]]
        ] ~= nil
      then
        error("bag captures carry one stack per item: " .. tostring(entry.item), 0)
      end
      stock[
        entry.item --[[@as string]]
      ] = entry.quantity --[[@as integer]]
    end
  end
  return stock
end

-- Counts one trainer's finite carried list into battle stock, preserving
-- multiplicity. A missing list yields no stock; a malformed entry fails
-- instead of guessing.
---@param items unknown carried trainer item list under projection
---@return table<string, integer>? finite battle stock, nil when the trainer carries no list
local function trainerStock(items)
  if items == nil then
    return nil
  end
  assert(type(items) == "table", "trainer items arrive as a list")
  local stock = {} ---@type table<string, integer>
  for index, item in
    ipairs(items --[[@as table<integer, unknown>]])
  do
    if type(item) ~= "string" or item == "" then
      error("trainer item " .. index .. " names its item", 0)
    end
    stock[
      item --[[@as string]]
    ] = (
      stock[
        item --[[@as string]]
      ] or 0
    ) + 1
  end
  return stock
end

HgssBattleScenarioFactory.PLAYER_INVENTORY_ID = "player-bag"

---@param index integer one-based trainer order under inventory naming
---@return string deterministic trainer stock identity
local function trainerInventoryId(index)
  return "trainer-" .. index .. "-items"
end

-- Joins production-owned inventories with caller-authored additions.
-- Production identities win only by refusing collisions, never by
-- silently overwriting staged stock.
---@param generated table<integer, table<string, unknown>> production-owned inventories under assembly
---@param explicit unknown caller-authored inventories under assembly
---@return table<integer, table<string, unknown>> combined detached inventories
local function joinInventories(generated, explicit)
  local out = {} ---@type table<integer, table<string, unknown>>
  local seen = {} ---@type table<string, boolean>
  for _, inventory in ipairs(generated) do
    seen[
      inventory.id --[[@as string]]
    ] = true
    out[#out + 1] = inventory
  end
  if explicit == nil then
    return out
  end
  assert(type(explicit) == "table", "scenario inventories arrive as an array")
  for _, entry in
    ipairs(explicit --[[@as table<integer, unknown>]])
  do
    assert(type(entry) == "table", "scenario inventories stay records")
    local record = entry --[[@as table<string, unknown>]]
    if type(record.id) ~= "string" or record.id == "" then
      error("scenario inventories stay named", 0)
    end
    if
      seen[
        record.id --[[@as string]]
      ]
    then
      error("production inventory owns its identity: " .. tostring(record.id), 0)
    end
    seen[
      record.id --[[@as string]]
    ] = true
    out[#out + 1] = copyValue(record)
  end
  return out
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

---@param ctx table<string, unknown> scenario context carrying live field sources
---@param isProduction boolean true when a live party snapshot fields the player side
---@return table<string, unknown> detached player reward identity with its production marker, or the marker alone when facts are unavailable; headless sessions keep an empty context
local function playerRewardContext(ctx, isProduction)
  local base = {} ---@type table<string, unknown>
  if isProduction then
    base.productionPlayer = true
  end
  local player = ctx.player
  if type(player) ~= "table" then
    return base
  end
  local record = player --[[@as table<string, unknown>]]
  if
    type(record.trainerId) ~= "number"
    or type(record.trainerName) ~= "string"
    or record.trainerName == ""
    or type(record.language) ~= "string"
    or record.language == ""
  then
    return base
  end
  base.trainerId = record.trainerId
  base.trainerName = record.trainerName
  base.language = record.language
  return base
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
---@param heart table<string, unknown> normalized battle description
---@return table<string, unknown> scenario fragment
local function assemble(payload, heart)
  assert(type(payload) == "table", "scenario sources arrive as records")
  local players = heart.players --[[@as table<integer, table<string, unknown>>]]
  assert(type(players) == "table" and #players > 0, "production scenarios field their player roster")
  local sides = {
    { id = 1, participants = { 1 } },
    { id = 2, participants = heart.enemyIds },
  }
  local playerParticipant = {
    id = 1,
    side = 1,
    controller = HgssBattleScenarioFactory.PLAYER_CONTROLLER,
    roster = players,
    context = copyValue(heart.playerContext or {}),
  }
  if heart.playerInventoryId ~= nil then
    playerParticipant.inventoryId = heart.playerInventoryId
  end
  local participants = { playerParticipant }
  for index, enemy in
    ipairs(heart.enemies --[[@as table<integer, table<string, unknown>>]])
  do
    participants[#participants + 1] = enemy
    assert(
      enemy.id == (heart.enemyIds --[[@as table<integer, integer>]])[index],
      "enemy membership follows participant order"
    )
  end
  local positions = {
    { id = 1, side = 1, eligibleParticipants = { 1 }, occupant = heart.openingId },
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
    inventories = joinInventories(heart.inventories or {}, payload.inventories),
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
-- optional format/environment overrides. The live party (ctx.party) fields
-- the player side with every non-egg member when present, opening with the
-- first conscious member, and the live bag (ctx.bag) projects the detached
-- player stock; without a live party the player side enters as an
-- explicitly marked placeholder that can never write back.
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
  local snapshot = snapshotParty(context.party)
  local players, openingId = playerRoster(snapshot)
  local key = attemptId or enemy.species or "wild"
  local foeId = #players + 1
  local foe = enemySeed(copyValue(enemy), foeId, {
    kind = "wild",
    owner = "enemy",
    key = tostring(key),
  })
  local inventories = {}
  local playerInventoryId = nil ---@type string?
  if snapshot ~= nil then
    playerInventoryId = HgssBattleScenarioFactory.PLAYER_INVENTORY_ID
    inventories[#inventories + 1] = {
      id = playerInventoryId,
      owners = { 1 },
      quantities = flattenBag(context.bag),
    }
  end
  return assemble(payload, {
    attemptId = attemptId,
    kind = "wild",
    format = payload.format or "wild-single",
    enemyIds = { foeId },
    players = players,
    openingId = openingId,
    playerContext = playerRewardContext(context, snapshot ~= nil),
    playerInventoryId = playerInventoryId,
    inventories = inventories,
    enemies = {
      { id = foeId, side = 2, controller = HgssBattleScenarioFactory.WILD_CONTROLLER, roster = { foe }, context = {} },
    },
    mon = copyValue(enemy),
    trainer = nil,
  })
end

-- Builds the trainer-battle fragment. The payload names the trainer (or
-- trainers, for simultaneous native pairs) and carries each trainer's full
-- party records; trainer parties are never invented here. Each trainer
-- fields its own participant (and controller) so simultaneous pairs keep
-- their native double engagement. The compiled AI passes and carried
-- items ride the participant context when supplied and stay absent
-- otherwise; the application battle owner refuses to run a trainer side
-- without its pass facts.
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
  local snapshot = snapshotParty(context.party)
  local players, openingId = playerRoster(snapshot)
  local inventories = {}
  local playerInventoryId = nil ---@type string?
  if snapshot ~= nil then
    playerInventoryId = HgssBattleScenarioFactory.PLAYER_INVENTORY_ID
    inventories[#inventories + 1] = {
      id = playerInventoryId,
      owners = { 1 },
      quantities = flattenBag(context.bag),
    }
  end
  local enemies = {}
  local enemyIds = {}
  local combatantId = #players
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
    if entry.aiPasses ~= nil then
      enemyContext.aiPasses = copyValue(entry.aiPasses)
    end
    if entry.items ~= nil then
      enemyContext.items = copyValue(entry.items)
    end
    local enemy = {
      id = participantId,
      side = 2,
      controller = "trainer:" .. entry.id,
      roster = roster,
      context = enemyContext,
    }
    -- Finite trainer stock rides its own battle inventory beside the
    -- decision context: the session consumes those detached quantities
    -- and the trainer inventory never publishes to the live bag.
    local stock = trainerStock(entry.items)
    if stock ~= nil then
      local inventoryId = trainerInventoryId(index)
      inventories[#inventories + 1] = { id = inventoryId, owners = { participantId }, quantities = stock }
      enemy.inventoryId = inventoryId
    end
    enemies[#enemies + 1] = enemy
  end
  local attemptId = payload.attemptId or payload.id
  return assemble(payload, {
    attemptId = attemptId,
    kind = "trainer",
    format = payload.format or (#trainers > 1 and "double" or "single"),
    enemyIds = enemyIds,
    players = players,
    openingId = openingId,
    playerContext = playerRewardContext(context, snapshot ~= nil),
    playerInventoryId = playerInventoryId,
    inventories = inventories,
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
