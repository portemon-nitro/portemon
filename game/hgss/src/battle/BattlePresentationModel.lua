-- Product presentation boundary for battle display facts. This module
-- converts privileged runtime snapshots into detached frontend records:
-- the opening roster, per-packet dynamic views, and sanitized event
-- batches. It owns names, privacy filtering, and presentation identity
-- (front/back selectors, party-slot mapping); the kernel keeps owning
-- legality, randomness, and settlement. Every function is pure: it reads
-- the supplied snapshot and scenario and returns detached plain data,
-- never the live session, generator state, trainer policy, unrevealed
-- enemy reserves, enemy move sets, or sealed peer choices.

local BattleProtocol = require("libs.battle.src.BattleProtocol")
local Experience = require("libs.mons.src.gen4.Experience")
local Mon = require("libs.mons.src.Mon")
local Personality = require("libs.mons.src.gen4.Personality")

---@class BattlePresentationModel
local BattlePresentationModel = {}

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

---@param mon table<string, unknown> battle-local mon record under inspection
---@return string? major condition key, nil when healthy
local function majorConditionOf(mon)
  local condition = mon.condition --[[@as table<string, unknown>?]]
  if type(condition) ~= "table" then
    return nil
  end
  local effects = (condition --[[@as table<string, unknown>]]).effects --[[@as table<integer, unknown>?]]
  if type(effects) ~= "table" then
    return nil
  end
  local current = (effects --[[@as table<integer, unknown>]])[1] --[[@as table<string, unknown>?]]
  if type(current) ~= "table" or type(current.key) ~= "string" then
    return nil
  end
  return current.key --[[@as string]]
end

---@param deps table<string, unknown>? model dependencies carrying the mon catalog
---@param species string species key under lookup
---@return table<string, unknown>? species record, nil without a catalog or entry
local function speciesRecord(deps, species)
  if type(deps) ~= "table" then
    return nil
  end
  local catalog = (deps --[[@as table<string, unknown>]]).catalog --[[@as table<string, unknown>?]]
  if type(catalog) ~= "table" then
    return nil
  end
  local lookup = catalog.species --[[@as fun(self: table<string, unknown>, key: string): table<string, unknown>?]]
  if type(lookup) ~= "function" then
    return nil
  end
  local ok, record = pcall(lookup, catalog, species)
  if not ok or type(record) ~= "table" then
    return nil
  end
  return record --[[@as table<string, unknown>]]
end

---@param deps table<string, unknown>? model dependencies carrying the mon catalog
---@param mon table<string, unknown> battle-local mon record under level resolution
---@param species table<string, unknown>? species record carrying the growth curve
---@return integer? battle level, nil when no level or experience fact resolves
local function combatLevel(deps, mon, species)
  if type(mon.level) == "number" then
    return mon.level --[[@as integer]]
  end
  if type(mon.experience) ~= "number" then
    return nil
  end
  if type(deps) ~= "table" or species == nil then
    return nil
  end
  local catalog = (deps --[[@as table<string, unknown>]]).catalog --[[@as table<string, unknown>?]]
  if type(catalog) ~= "table" then
    return nil
  end
  local curveKey = species.growthCurve --[[@as string?]]
  if type(curveKey) ~= "string" then
    return nil
  end
  local curveOf = catalog.growthCurve --[[@as fun(self: table<string, unknown>, key: string): table<integer, integer>?]]
  if type(curveOf) ~= "function" then
    return nil
  end
  local ok, curve = pcall(curveOf, catalog, curveKey)
  if not ok or type(curve) ~= "table" then
    return nil
  end
  local okLevel, level = pcall(Experience.level, curve, mon.experience --[[@as integer]])
  if not okLevel or type(level) ~= "number" then
    return nil
  end
  return level --[[@as integer]]
end

---@param deps table<string, unknown>? model dependencies carrying the mon catalog
---@param move string move identity under display
---@param entry table<string, unknown> battle-local move entry carrying power points
---@return table<string, unknown> display facts for one own move
local function moveFacts(deps, move, entry)
  local display = {
    move = move,
    name = move,
    pp = entry.pp,
    maxPp = entry.pp,
  } --[[@as table<string, unknown>]]
  if type(deps) == "table" then
    local catalog = (deps --[[@as table<string, unknown>]]).catalog --[[@as table<string, unknown>?]]
    if type(catalog) == "table" then
      local lookup = catalog.move --[[@as fun(self: table<string, unknown>, key: string): table<string, unknown>?]]
      if type(lookup) == "function" then
        local ok, facts = pcall(lookup, catalog, move)
        if ok and type(facts) == "table" then
          local record = facts --[[@as table<string, unknown>]]
          if type(record.name) == "string" then
            display.name = record.name
          end
          if type(record.moveType) == "string" then
            display.type = record.moveType
          end
          if type(record.basePp) == "number" then
            local ups = entry.ppUps
            if type(ups) ~= "number" then
              ups = 0
            end
            display.maxPp = record.basePp --[[@as integer]]
              + math.floor(record.basePp --[[@as integer]] * ups --[[@as integer]] / 5)
          end
        end
      end
    end
  end
  return display
end

---@param deps table<string, unknown>? model dependencies carrying the mon catalog
---@param mon table<string, unknown> battle-local mon record under projection
---@return table<string, unknown>[] display facts for the own move set
local function ownMoves(deps, mon)
  local out = {} ---@type table<string, unknown>[]
  local moves = mon.moves --[[@as table<integer, unknown>?]]
  if type(moves) ~= "table" then
    return out
  end
  for index = 1, #moves do
    local entry = moves[index] --[[@as table<string, unknown>?]]
    if type(entry) == "table" and type(entry.move) == "string" then
      out[#out + 1] = moveFacts(deps, entry.move --[[@as string]], entry)
    end
  end
  return out
end

---@param deps table<string, unknown>? model dependencies carrying the mon catalog
---@param mon table<string, unknown> battle-local mon record under projection
---@param species table<string, unknown>? species record for name and gender facts
---@return string visible mon name: nickname first, catalog name next, species key last
local function visibleName(deps, mon, species)
  if type(mon.nickname) == "string" and mon.nickname ~= "" then
    return mon.nickname --[[@as string]]
  end
  if species ~= nil and type(species.name) == "string" then
    return species.name --[[@as string]]
  end
  if type(deps) == "table" then
    local catalog = (deps --[[@as table<string, unknown>]]).catalog
    if catalog ~= nil then
      local ok, name = pcall(Mon.displayName, mon, catalog)
      if ok and type(name) == "string" then
        return name --[[@as string]]
      end
    end
  end
  return tostring(mon.species)
end

---@param mon table<string, unknown> battle-local mon record under projection
---@param species table<string, unknown>? species record carrying the gender ratio
---@return string? gender word when the record can answer, nil otherwise
local function visibleGender(mon, species)
  if type(mon.personality) ~= "number" then
    return nil
  end
  if species == nil or type(species.genderRatio) ~= "number" then
    return nil
  end
  local ok, gender = pcall(Personality.gender, species.genderRatio --[[@as integer]], mon.personality --[[@as integer]])
  if not ok or (gender ~= "masculine" and gender ~= "feminine") then
    return nil
  end
  return gender --[[@as string]]
end

---@param mon table<string, unknown> battle-local mon record under projection
---@return boolean? true when the record is shiny, nil when it cannot answer
local function visibleShiny(mon)
  local origin = mon.origin --[[@as table<string, unknown>?]]
  if type(origin) ~= "table" or type(origin.trainerId) ~= "number" then
    return nil
  end
  if type(mon.personality) ~= "number" then
    return nil
  end
  local ok, shiny = pcall(Personality.shiny, origin.trainerId --[[@as integer]], mon.personality --[[@as integer]])
  if not ok or type(shiny) ~= "boolean" then
    return nil
  end
  return shiny --[[@as boolean]]
end

---@param deps table<string, unknown>? model dependencies carrying the mon catalog
---@param snapshot table<string, unknown> detached battle snapshot under projection
---@param id integer combatant identity under projection
---@param own boolean true for the owning side, false for visible opponents
---@return table<string, unknown> public display record for one combatant
local function combatantRecord(deps, snapshot, id, own)
  local combatants = snapshot.combatants --[[@as table<integer, table<string, unknown>>]]
  local combatant = combatants[id] --[[@as table<string, unknown>]]
  local mon = combatant.mon --[[@as table<string, unknown>]]
  local species = nil
  if type(mon.species) == "string" then
    species = speciesRecord(deps, mon.species --[[@as string]])
  end
  local ceiling = combatant.maxHp
  if type(ceiling) ~= "number" then
    ceiling = combatant.entryHp
  end
  local record = {
    combatant = id,
    participant = combatant.participant,
    side = nil,
    active = combatant.active ~= nil,
    hp = combatant.hp,
    maxHp = ceiling,
    condition = majorConditionOf(mon),
    species = mon.species,
    form = mon.form,
    name = visibleName(deps, mon, species),
    level = combatLevel(deps, mon, species),
    selector = own and "back" or "front",
  } --[[@as table<string, unknown>]]
  local participants = snapshot.participants --[[@as table<integer, table<string, unknown>>?]]
  if type(participants) == "table" then
    local participant = participants[
      combatant.participant --[[@as integer]]
    ] --[[@as table<string, unknown>?]]
    if type(participant) == "table" then
      record.side = participant.side
      record.controller = participant.controller
    end
  end
  if combatant.active ~= nil then
    local active = combatant.active --[[@as table<string, unknown>]]
    record.position = active.position
    record.activation = active.activation
  end
  local gender = visibleGender(mon, species)
  if gender ~= nil then
    record.gender = gender
  end
  local shiny = visibleShiny(mon)
  if shiny ~= nil then
    record.shiny = shiny
  end
  if own then
    -- The owning side reads its own roster in full: party-slot mapping,
    -- move power points, progression, and holdings. Opponents never
    -- receive these fields.
    local source = combatant.source --[[@as table<string, unknown>?]]
    if type(source) == "table" and source.kind == "party" and type(source.slot) == "number" then
      record.slot = source.slot --[[@as integer]] - 1
    end
    record.moves = ownMoves(deps, mon)
    if type(mon.experience) == "number" then
      record.experience = mon.experience
    end
    if type(mon.heldItem) == "string" then
      record.heldItem = mon.heldItem
    end
  end
  return record
end

---@param snapshot table<string, unknown> detached battle snapshot under projection
---@return table<integer, boolean> participant identities owned by the player controller
local function playerParticipants(snapshot)
  local owned = {} ---@type table<integer, boolean>
  local participants = snapshot.participants --[[@as table<integer, table<string, unknown>>?]]
  if type(participants) ~= "table" then
    return owned
  end
  for id, participant in pairs(participants) do
    if type(participant) == "table" and participant.controller == "player" then
      owned[
        id --[[@as integer]]
      ] = true
    end
  end
  return owned
end

-- Dynamic facts view over one detached snapshot: the current own roster
-- with party-slot mapping and the active visible opponents. Foe
-- reserves, move sets, inventories, trainer policy, and sealed choices
-- never enter the view.
---@param snapshot table<string, unknown> detached battle snapshot under projection
---@param scenario table<string, unknown>? detached scenario carrying the environment
---@param deps table<string, unknown>? model dependencies carrying the mon catalog
---@return table<string, unknown> detached dynamic facts view
function BattlePresentationModel.view(snapshot, scenario, deps)
  assert(type(snapshot) == "table", "presentation views read their snapshot")
  local owned = playerParticipants(snapshot)
  local combatants = snapshot.combatants --[[@as table<integer, table<string, unknown>>?]]
  local combatantOrder = snapshot.combatantOrder --[[@as integer[]?]]
  local own = {} ---@type table<integer, table<string, unknown>>
  local foes = {} ---@type table<integer, table<string, unknown>>
  if type(combatants) == "table" and type(combatantOrder) == "table" then
    for _, id in ipairs(combatantOrder) do
      local combatant = combatants[
        id --[[@as integer]]
      ] --[[@as table<string, unknown>?]]
      if type(combatant) == "table" then
        if
          owned[
            combatant.participant --[[@as integer]]
          ] == true
        then
          own[#own + 1] = combatantRecord(deps, snapshot, id --[[@as integer]], true)
        elseif combatant.active ~= nil then
          foes[#foes + 1] = combatantRecord(deps, snapshot, id --[[@as integer]], false)
        end
      end
    end
  end
  local participants = {} ---@type table<integer, table<string, unknown>>
  local listed = snapshot.participants --[[@as table<integer, table<string, unknown>>?]]
  if type(listed) == "table" then
    local ids = {} ---@type integer[]
    for id in pairs(listed) do
      ids[#ids + 1] = id --[[@as integer]]
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local participant = listed[id] --[[@as table<string, unknown>]]
      if type(participant) == "table" then
        participants[#participants + 1] =
          { participant = id, side = participant.side, controller = participant.controller }
      end
    end
  end
  local environment = {}
  if type(scenario) == "table" and type(scenario.environment) == "table" then
    environment = copyValue(scenario.environment)
  end
  return {
    round = snapshot.round,
    status = snapshot.status,
    own = own,
    foes = foes,
    participants = participants,
    environment = environment,
  }
end

-- Detached opening record for one launch: the launch identity and kind
-- beside the current dynamic facts. The frontend opens from this
-- record, never from the live session.
---@param snapshot table<string, unknown> detached battle snapshot under projection
---@param scenario table<string, unknown>? detached scenario carrying the environment
---@param deps table<string, unknown>? model dependencies carrying the mon catalog
---@param launch table<string, unknown>? launch identity carrying its id and kind
---@return table<string, unknown> detached opening record
function BattlePresentationModel.opening(snapshot, scenario, deps, launch)
  local dynamic = BattlePresentationModel.view(snapshot, scenario, deps)
  if type(launch) == "table" then
    dynamic.launchId = launch.id
    dynamic.kind = launch.kind
  end
  if type(scenario) == "table" and type(scenario.format) == "string" then
    dynamic.format = scenario.format
  end
  return dynamic
end

---@param event table<string, unknown> native event under sanitizing
---@return table<string, unknown> public event with its event-time checkpoint
function BattlePresentationModel.sanitizeEvent(event)
  assert(type(event) == "table", "sanitized packets carry event records")
  local public = {
    sequence = event.sequence,
    kind = event.kind,
    cause = copyValue(event.cause),
    audience = event.audience,
    payload = copyValue(event.payload),
  } --[[@as table<string, unknown>]]
  if event.actionId ~= nil then
    public.actionId = event.actionId
  end
  if event.hitIndex ~= nil then
    public.hitIndex = event.hitIndex
  end
  -- The internal checkpoint already projects active public facts only;
  -- the copy keeps the packet detached from the kernel outbox.
  if type(event.observation) == "table" then
    public.after = copyValue(event.observation)
  else
    public.after = {}
  end
  BattleProtocol.validateEvent(public)
  return public
end

-- Detached delivery packet for one mechanics result: ordered sanitized
-- events with event-time checkpoints, the detached before/after views
-- for reconciliation, and the optional player request, result summary,
-- and own-party/inventory facts for the next decision. Mutating the
-- packet cannot reach the kernel, the saved request, or later packets.
---@param beforeView table<string, unknown> detached dynamic view preceding the frame
---@param frame table<string, unknown> kernel frame at an atomic boundary
---@param afterView table<string, unknown> detached dynamic view following the frame
---@param context table<string, unknown> delivery context carrying launch and packet identity
---@return table<string, unknown> detached validated delivery packet
function BattlePresentationModel.packet(beforeView, frame, afterView, context)
  assert(type(beforeView) == "table", "delivery packets carry their before view")
  assert(type(frame) == "table", "delivery packets carry their mechanics frame")
  assert(type(afterView) == "table", "delivery packets carry their after view")
  assert(type(context) == "table", "delivery packets carry their delivery context")
  local launchId = context.launchId --[[@as string]]
  local packetId = context.packetId --[[@as integer]]
  assert(type(launchId) == "string" and launchId ~= "", "delivery packets carry their launch identity")
  assert(
    type(packetId) == "number" and packetId --[[@as integer]] % 1 == 0 and packetId --[[@as integer]] >= 1,
    "delivery packets carry a monotonic per-launch identity"
  )
  local events = {} ---@type table<integer, table<string, unknown>>
  if type(frame.events) == "table" then
    for _, event in
      ipairs(frame.events --[[@as table<integer, table<string, unknown>>]])
    do
      events[#events + 1] = BattlePresentationModel.sanitizeEvent(event)
    end
  end
  local packet = {
    launchId = launchId,
    packetId = packetId,
    events = events,
    before = copyValue(beforeView),
    after = copyValue(afterView),
  } --[[@as table<string, unknown>]]
  if context.request ~= nil then
    packet.request = copyValue(context.request)
  end
  if context.result ~= nil then
    packet.result = copyValue(context.result)
  end
  if context.party ~= nil then
    packet.party = copyValue(context.party)
  end
  if context.inventory ~= nil then
    packet.inventory = copyValue(context.inventory)
  end
  BattleProtocol.validatePacket(packet)
  return packet
end

return BattlePresentationModel
