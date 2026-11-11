-- Private source-flow selection behind the ordered cue player. The cue
-- player keeps the clock, queue, and displayed facts; this owner only
-- selects which native branch an opening, action occurrence, capture,
-- substitution, or terminal result belongs to and in which order its
-- typed cues run. It never interprets raw battle script opcodes and
-- never recomputes mechanics, damage, catch probability, or rewards.
-- Native branches follow src/battle/battle_controller_player.c
-- (GET_BATTLE_MON, START_ENCOUNTER, TRAINER_MESSAGE, SEND_OUT), the
-- opponent-controller entry tasks in
-- asm/overlay_12_battle_controller_opponent.s, and the ordered waits in
-- src/battle/battle_command.c (BtlCmd_HealthbarSlideIn, BtlCmd_Wait,
-- BtlCmd_PlayMoveAnimation).

local BattleScene = require("libs.hgss.src.presentation.BattleScene")
local BattleMusicSelection = require("game.hgss.src.battle.BattleMusicSelection")

---@class BattlePresentationFlow
local BattlePresentationFlow = {}

-- Canonical semantic slot names behind the native side types 0..5.
-- The names and side types are runtime presentation vocabulary; no
-- source archive index leaks through this mapping.
local SLOT_BY_SIDE_TYPE = {
  [0] = "solo-player",
  [1] = "solo-enemy",
  [2] = "player-side-slot-1",
  [3] = "enemy-side-slot-1",
  [4] = "player-side-slot-2",
  [5] = "enemy-side-slot-2",
}

-- Partner slot behind one declared solo/side slot: the other occupant of
-- the same side, used for partner-aware placement and targeting.
local PARTNER_SLOT = {
  ["player-side-slot-1"] = "player-side-slot-2",
  ["player-side-slot-2"] = "player-side-slot-1",
  ["enemy-side-slot-1"] = "enemy-side-slot-2",
  ["enemy-side-slot-2"] = "enemy-side-slot-1",
}

-- Freezes the detached appearance table behind one event-time view
-- record: species with form, gender, and shiny when the record names
-- them. Records without a species picture nothing.
---@param record table<string, unknown>? event-time view record behind the appearance
---@return table<string, unknown>? detached appearance inputs, nil when the record pictures nothing
local function appearanceOf(record)
  if type(record) ~= "table" or type(record.species) ~= "string" then
    return nil
  end
  local appearance = { species = record.species } ---@type table<string, unknown>
  if type(record.form) == "number" then
    appearance.form = record.form
  end
  if type(record.gender) == "string" then
    appearance.gender = record.gender
  end
  if type(record.shiny) == "boolean" then
    appearance.shiny = record.shiny
  end
  return appearance
end

---@param packet table<string, unknown> detached delivery packet picturing the event battlers
---@param combatant integer combatant identity behind the view lookup
---@return table<string, unknown>? first before/after view record picturing the combatant, nil when absent
local function viewRecordOf(packet, combatant)
  for _, viewKey in ipairs({ "before", "after" }) do
    local view = packet[viewKey] --[[@as table<string, unknown>?]]
    if type(view) == "table" then
      for _, groupKey in ipairs({ "own", "foes" }) do
        local group = (view --[[@as table<string, unknown>]])[groupKey]
        if type(group) == "table" then
          for _, record in
            ipairs(group --[[@as table<integer, unknown>]])
          do
            if
              type(record) == "table" and (record --[[@as table<string, unknown>]]).combatant == combatant
            then
              return record --[[@as table<string, unknown>]]
            end
          end
        end
      end
    end
  end
  return nil
end

function BattlePresentationFlow.isWild(view)
  local foes = view.foes --[[@as table<integer, table<string, unknown>>?]]
  if type(foes) == "table" then
    local first = foes[1] --[[@as table<string, unknown>?]]
    if type(first) == "table" and first.controller == "wild" then
      return true
    end
    if type(first) == "table" and type(first.controller) == "string" then
      return false
    end
  end
  return true
end

---@param view table<string, unknown> detached opening dynamic view
---@return table<string, unknown>? first active own record, nil when no lead is active
function BattlePresentationFlow.activeLead(view)
  local own = view.own --[[@as table<integer, table<string, unknown>>?]]
  if type(own) ~= "table" then
    return nil
  end
  for _, record in ipairs(own) do
    if type(record) == "table" and record.active ~= false then
      return record --[[@as table<string, unknown>]]
    end
  end
  return nil
end

---@param view table<string, unknown> detached dynamic view
---@return table<string, unknown>? first listed foe record, nil when absent
function BattlePresentationFlow.firstFoe(view)
  local foes = view.foes --[[@as table<integer, table<string, unknown>>?]]
  if type(foes) == "table" then
    local first = foes[1] --[[@as table<string, unknown>?]]
    if type(first) == "table" then
      return first
    end
  end
  return nil
end

---@param packet table<string, unknown> detached delivery packet
---@return boolean opening true for the empty first delivery that carries only its views
function BattlePresentationFlow.isOpeningPacket(packet)
  if packet.result ~= nil then
    return false
  end
  local events = packet.events --[[@as table<integer, table<string, unknown>>?]]
  if type(events) == "table" and #events > 0 then
    return false
  end
  return type(packet.before) == "table" or type(packet.after) == "table"
end

---@param attacker integer? striking combatant under narration lookup
---@param move string executed move identity under narration lookup
---@return string occurrence key joining one attack narration across its hits
function BattlePresentationFlow.attackKey(attacker, move)
  local owner = attacker ~= nil and tostring(attacker) or "unknown"
  return owner .. "\0" .. move
end

---@param event table<string, unknown> sanitized kernel event carrying its explicit facts
---@return integer? combatant identity of the capture target, nil when unnamed
function BattlePresentationFlow.captureTarget(event)
  local targets = event.targets --[[@as table<integer, table<string, unknown>>?]]
  if type(targets) == "table" then
    local first = targets[1] --[[@as table<string, unknown>?]]
    if type(first) == "table" and type(first.combatant) == "number" then
      return first.combatant --[[@as integer]]
    end
  end
  local payload = event.payload --[[@as table<string, unknown>?]]
  if type(payload) == "table" and type(payload.target) == "number" then
    return payload.target --[[@as integer]]
  end
  return nil
end

---@param event table<string, unknown> sanitized kernel event carrying its faint facts
---@return integer? combatant identity of the departing battler, nil when unnamed
function BattlePresentationFlow.faintTarget(event)
  local payload = event.payload --[[@as table<string, unknown>?]]
  if type(payload) == "table" then
    if type(payload.combatant) == "number" then
      return payload.combatant --[[@as integer]]
    end
    if type(payload.target) == "number" then
      return payload.target --[[@as integer]]
    end
  end
  return nil
end

---@param event table<string, unknown> sanitized kernel event carrying its transform facts
---@return integer? combatant identity of the appearance donor, nil when unnamed
function BattlePresentationFlow.transformDonor(event)
  local payload = event.payload --[[@as table<string, unknown>?]]
  if type(payload) == "table" and type(payload.copiedFrom) == "number" then
    return payload.copiedFrom --[[@as integer]]
  end
  return nil
end

---@param word string terminal result word carried by the committed receipt
---@param wild boolean true while the victory answers a wild encounter
---@return string? staged victory BGM symbol for wins, nil when the word carries no music
function BattlePresentationFlow.resultMusicSymbol(word, wild)
  if word ~= "win" then
    return nil
  end
  -- Native victory is a plain BGM swap (PlayBGM SEQ_GS_WIN2 for wild wins).
  -- Direct timeline drivers carry no trainer class, so trainer wins keep
  -- the kind-level default here; the field leg refines by class.
  return BattleMusicSelection.victoryMusicSymbol(wild and "wild" or "trainer", nil)
end

---@param list table<integer, table<string, unknown>>? detached active records from one side
---@param seen table<integer, boolean> claimed positions already collected
---@param order integer[] sorted distinct positions under collection
local function collectSidePositions(list, seen, order)
  if type(list) ~= "table" then
    return
  end
  for _, record in ipairs(list) do
    if type(record) == "table" and type(record.position) == "number" then
      local position = record.position --[[@as integer]]
      if not seen[position] then
        seen[position] = true
        order[#order + 1] = position
      end
    end
  end
end

---@param packet table<string, unknown> detached delivery packet picturing the event battlers
---@param side integer battler side under ordering (1 ally, 2 foe)
---@return integer[] sorted distinct occupied positions for the side
local function sidePositionOrder(packet, side)
  local seen = {} ---@type table<integer, boolean>
  local order = {} ---@type integer[]
  local before = packet.before --[[@as table<string, unknown>?]]
  local after = packet.after --[[@as table<string, unknown>?]]
  if type(before) == "table" then
    if side == 1 then
      collectSidePositions(before.own --[[@as table<integer, table<string, unknown>>?]], seen, order)
    else
      collectSidePositions(before.foes --[[@as table<integer, table<string, unknown>>?]], seen, order)
    end
  end
  if type(after) == "table" then
    if side == 1 then
      collectSidePositions(after.own --[[@as table<integer, table<string, unknown>>?]], seen, order)
    else
      collectSidePositions(after.foes --[[@as table<integer, table<string, unknown>>?]], seen, order)
    end
  end
  table.sort(order)
  return order
end

---@param packet table<string, unknown> detached delivery packet picturing the event battlers
---@param combatant integer combatant identity under lookup
---@param activation unknown activation identity under lookup
---@return table<string, unknown>? exact event-time record, when one side still pictures it
---@return boolean stale true when the combatant survives under a different activation
local function findEventRecord(packet, combatant, activation)
  local stale = false
  local found = nil ---@type table<string, unknown>?
  local function scan(view)
    if type(view) ~= "table" then
      return
    end
    for _, group in ipairs({ view.own, view.foes }) do
      if type(group) == "table" then
        for _, record in ipairs(group) do
          if type(record) == "table" and record.combatant == combatant then
            if record.activation == activation then
              if found == nil then
                found = record --[[@as table<string, unknown>]]
              end
            else
              stale = true
            end
          end
        end
      end
    end
  end
  scan(packet.before --[[@as table<string, unknown>?]])
  scan(packet.after --[[@as table<string, unknown>?]])
  return found, stale
end

---@param packet table<string, unknown> detached delivery packet picturing the event battlers
---@param entry table<string, unknown> sanitized actor/target identity under resolution
---@param role string actor or target role under diagnosis
---@param slotGeometry table<integer, table<string, number>> published native slot rows
---@return table<string, unknown> frozen semantic slot behind the event-time record
local function resolveEntry(packet, entry, role, slotGeometry)
  assert(type(entry.combatant) == "number", role .. " names its combatant")
  assert(entry.activation ~= nil, role .. " names its activation")
  local combatant = entry.combatant --[[@as integer]]
  local record, stale = findEventRecord(packet, combatant, entry.activation)
  if record == nil then
    if stale then
      error(
        role .. " combatant " .. tostring(combatant) .. " no longer carries activation " .. tostring(entry.activation),
        0
      )
    end
    error(
      role
        .. " combatant "
        .. tostring(combatant)
        .. " has no event-time slot for activation "
        .. tostring(entry.activation),
      0
    )
  end
  local side = record.side
  if side ~= 1 and side ~= 2 then
    error(role .. " combatant " .. tostring(combatant) .. " carries no battle side", 0)
  end
  local position = record.position
  if type(position) ~= "number" then
    if type(entry.position) == "number" then
      position = entry.position
    else
      error(role .. " combatant " .. tostring(combatant) .. " carries no battle position", 0)
    end
  end
  local order = sidePositionOrder(packet, side --[[@as integer]])
  if #order == 0 then
    error(role .. " combatant " .. tostring(combatant) .. " has no live side positions", 0)
  end
  if #order > 2 then
    error(role .. " combatant " .. tostring(combatant) .. " has too many live side positions", 0)
  end
  local battler = { side = side, position = position }
  local row
  if #order == 1 then
    row = BattleScene.slotRow(battler, nil, slotGeometry)
  else
    local claimed = false
    for _, slot in ipairs(order) do
      if slot == position then
        claimed = true
        break
      end
    end
    if not claimed then
      error(
        role
          .. " combatant "
          .. tostring(combatant)
          .. " position "
          .. tostring(position)
          .. " is outside its live side order",
        0
      )
    end
    row = BattleScene.slotRow(battler, order, slotGeometry)
  end
  assert(type(row) == "table", role .. " resolves its native slot row")
  local sideType = row.sideType
  assert(type(sideType) == "number", role .. " resolves its native side type")
  local slot = SLOT_BY_SIDE_TYPE[
    sideType --[[@as integer]]
  ]
  if slot == nil then
    error(role .. " combatant " .. tostring(combatant) .. " resolves an unknown side type", 0)
  end
  if side == 1 and sideType ~= 0 and sideType ~= 2 and sideType ~= 4 then
    error(role .. " combatant " .. tostring(combatant) .. " resolves a foe side type", 0)
  end
  if side == 2 and sideType ~= 1 and sideType ~= 3 and sideType ~= 5 then
    error(role .. " combatant " .. tostring(combatant) .. " resolves an ally side type", 0)
  end
  return {
    combatant = combatant,
    activation = entry.activation,
    slot = slot,
    sideType = sideType,
  }
end

local function sourceBattlers(packet, slotGeometry)
  local bySideType = {}
  local function collect(view)
    if type(view) ~= "table" then
      return
    end
    for _, group in ipairs({ view.own, view.foes }) do
      if type(group) == "table" then
        for _, record in ipairs(group) do
          if type(record) == "table" and type(record.combatant) == "number" and record.activation ~= nil then
            local resolved = resolveEntry(packet, record, "source battler", slotGeometry)
            if bySideType[resolved.sideType] == nil then
              bySideType[resolved.sideType] = resolved
            end
          end
        end
      end
    end
  end
  collect(packet.before)
  collect(packet.after)
  local ordered = {}
  for sideType = 0, 5 do
    local battler = bySideType[sideType]
    if battler ~= nil then
      ordered[#ordered + 1] = battler
    end
  end
  return ordered
end

-- Applied status feedback roots by applied condition identity. Every
-- entry names the auxiliary member behind the source feedback script;
-- Rest sleeps through its own move program and never takes the extra
-- application root.
local STATUS_ROOTS = {
  sleep = "BATTLE_ANIMATION_ASLEEP",
  poison = "BATTLE_ANIMATION_POISONED",
  toxic = "BATTLE_ANIMATION_POISONED",
  burn = "BATTLE_ANIMATION_BURNED",
  freeze = "BATTLE_ANIMATION_FROZEN",
  paralysis = "BATTLE_ANIMATION_PARALYZED",
}

---@param packet table<string, unknown> detached delivery packet picturing the event battlers
---@param entries table<integer, table<string, unknown>> sanitized actor/target identities under resolution
---@param role string actor or target role under diagnosis
---@param slotGeometry table<integer, table<string, number>> published native slot rows
---@return table<integer, table<string, unknown>> frozen semantic slots in source order
local function resolveRoles(packet, entries, role, slotGeometry)
  if type(entries) ~= "table" or #entries < 1 then
    error("frozen requests carry at least one event " .. role, 0)
  end
  local resolved = {} ---@type table<integer, table<string, unknown>>
  for _, entry in ipairs(entries) do
    assert(type(entry) == "table", "frozen requests carry ordered " .. role .. " records")
    local binding = resolveEntry(packet, entry --[[@as table<string, unknown>]], role, slotGeometry)
    local pictured =
      appearanceOf(viewRecordOf(packet, (entry --[[@as table<string, unknown>]]).combatant --[[@as integer]]))
    if pictured ~= nil then
      binding.appearance = pictured
    end
    resolved[#resolved + 1] = binding
  end
  return resolved
end

-- Doubles partner slot behind the frozen lookup: solo slots never own
-- a partner, so they stay absent from this map.
---@param bound table<string, unknown> frozen semantic slot behind the partner lookup
---@param positions table<integer, table<string, unknown>> frozen source positions behind the lookup
---@return table<string, unknown>|boolean partner slot sharing the side, false for solo slots
local function partnerOf(bound, positions)
  local slot = bound.slot
  if type(slot) ~= "string" then
    return false
  end
  local partnerSlot = PARTNER_SLOT[
    slot --[[@as string]]
  ]
  if partnerSlot == nil then
    return false
  end
  for _, candidate in ipairs(positions) do
    if type(candidate) == "table" and candidate ~= bound and candidate.slot == partnerSlot then
      return candidate
    end
  end
  return false
end
-- Builds one detached frozen request behind a selected source call.
-- Context carries only event-time facts: the numeric source variant,
-- calculated signed damage for strikes, resolved power, friendship,
-- effective weather, and terrain when the event froze them, with
-- contests always false. Absent facts stay absent; nothing is
-- invented for programs that do not read them.
---@param launchId string owning launch behind the identity
---@param sequence integer kernel event sequence behind the identity
---@param ordinal integer selected source-call ordinal behind the identity
---@param effectKey string catalog key behind the request
---@param invocationKind string source caller kind behind the request
---@param disposition string admit or omit with an explicit gate reason
---@param stage string anchor stage behind the request
---@param index integer anchor index behind the request
---@param parts table<string, unknown> frozen roles, positions, and event behind the request
---@return table<string, unknown> detached frozen request
local function freezeRequest(launchId, sequence, ordinal, effectKey, invocationKind, disposition, stage, index, parts)
  local attacker = parts.attacker
  local defender = parts.defender
  local targets = parts.targets
  local positions = parts.positions --[[@as table<integer, table<string, unknown>>]]
  -- Playback context arrives prebuilt from the selector: the primary
  -- root's variant/damage/power/friendship and the frozen battle
  -- predicates. The event payload is never re-read here, so a later
  -- mutated view cannot change the frozen call facts.
  local context = parts.context --[[@as table<string, unknown>]]
  assert(type(context) == "table", "frozen requests carry their prebuilt playback context")
  local frozenTargets = {} ---@type table<integer, table<string, unknown>>
  if type(targets) == "table" then
    for _, binding in ipairs(targets) do
      frozenTargets[#frozenTargets + 1] = binding
    end
  end
  local attackerPartner = false ---@type table<string, unknown>|boolean
  if type(attacker) == "table" then
    attackerPartner = partnerOf(attacker --[[@as table<string, unknown>]], positions)
  end
  local defenderPartner = false ---@type table<string, unknown>|boolean
  if type(defender) == "table" then
    defenderPartner = partnerOf(defender --[[@as table<string, unknown>]], positions)
  end
  return {
    identity = { launchId = launchId, origin = "event", eventSequence = sequence, ordinal = ordinal },
    anchor = { origin = "event", eventSequence = sequence, stage = stage, index = index },
    effectKey = effectKey,
    invocationKind = invocationKind,
    disposition = disposition,
    playback = {
      launchId = launchId,
      identity = { launchId = launchId, origin = "event", eventSequence = sequence, ordinal = ordinal },
      context = context,
      topology = {
        attacker = attacker or false,
        defender = defender or false,
        attackerPartner = attackerPartner,
        defenderPartner = defenderPartner,
        targets = frozenTargets,
        sourceBattlers = positions,
      },
    },
  }
end

-- Selects the single ordered frozen request list behind one sanitized
-- event. Each request freezes its occurrence identity (launch, event
-- sequence, selected source-call ordinal), its anchor at an existing
-- narration/health/decision boundary, its catalog key and source
-- caller kind, an explicit admit/omit disposition with a source gate
-- reason, and the detached playback context and topology the player
-- consumes. Ordinals count selected source calls before gating, so an
-- omitted call keeps its ordinal. The delivery packet identity stays
-- diagnostic only and never enters the frozen identity, so redelivery
-- under another packet selects identical content.
---@param packet table<string, unknown> detached delivery packet carrying launch identity and event-time views
---@param event table<string, unknown> sanitized event carrying actor/target and effect facts
---@param slotGeometry table<integer, table<string, number>> published native slot rows
---@param options table<string, unknown>? factual prepass inputs: battleScene (launch scene choice; false omits optional move roots), sourceBindings (detached per-event source-slot snapshot), costLinks (owner-to-cost event sequence index)
---@return table<integer, table<string, unknown>> ordered detached frozen requests
function BattlePresentationFlow.animationPlayback(packet, event, slotGeometry, options)
  assert(type(packet) == "table", "frozen requests read their delivery packet")
  assert(type(event) == "table", "frozen requests read their sanitized event")
  assert(type(slotGeometry) == "table", "frozen requests read their slot geometry")
  if options ~= nil then
    assert(type(options) == "table", "frozen requests read their prepass options as a record")
    if options.battleScene ~= nil then
      assert(type(options.battleScene) == "boolean", "frozen requests read their launch scene choice as a boolean")
    end
  end
  local launchId = packet.launchId
  assert(type(launchId) == "string" and launchId ~= "", "frozen requests carry their launch identity")
  local sequence = event.sequence
  assert(
    type(sequence) == "number" and sequence % 1 == 0 and sequence >= 1,
    "frozen requests carry their event sequence"
  )
  local kind = event.kind
  assert(type(kind) == "string" and kind ~= "", "frozen requests read their event kind")
  local payload = event.payload
  assert(type(payload) == "table", "frozen requests read their event payload")
  local positions = sourceBattlers(packet, slotGeometry)

  -- Closed source-variant mapping behind one execution moment and
  -- branch. Flow owns this numeric mapping; the kernel never derives a
  -- variant from kind strings or marker presence.
  ---@param moment string closed execution moment behind the call
  ---@param branch string? closed execution branch, default when absent
  ---@return integer source animation variant behind the root
  local function variantFor(moment, branch)
    if
      moment == "charge-release"
      or moment == "bide-release"
      or moment == "transfer-complete"
      or moment == "delayed-hit"
      or moment == "snatch-interception"
      or moment == "pivot-departure"
    then
      return 1
    end
    if moment == "focus-preparation" or moment == "charge-start" then
      return 0
    end
    if branch ~= nil and branch ~= "default" then
      return 1
    end
    return 0
  end

  -- Feedback roots behind one residual operation effect. Binding ticks
  -- resolve through the stored binding move; skies never ride this
  -- arm (their continuation is a weather-continued operation).
  local RESIDUAL_EFFECT_ROOTS = {
    poison = "BATTLE_ANIMATION_POISONED",
    toxic = "BATTLE_ANIMATION_POISONED",
    burn = "BATTLE_ANIMATION_BURNED",
    curse = "BATTLE_ANIMATION_DAMAGE_CURSE",
    nightmare = "BATTLE_ANIMATION_DAMAGE_NIGHTMARE",
    ["leech-seed"] = "BATTLE_ANIMATION_DAMAGE_LEECH_SEED",
    wish = "BATTLE_ANIMATION_RESTORE_HP",
    ["aqua-ring"] = "BATTLE_ANIMATION_RESTORE_HP",
    ingrain = "BATTLE_ANIMATION_DAMAGE_INGRAIN",
  }

  -- Feedback roots behind one applied binding move.
  local BINDING_ROOTS = {
    BIND = "BATTLE_ANIMATION_DAMAGE_BIND",
    WRAP = "BATTLE_ANIMATION_DAMAGE_WRAP",
    FIRE_SPIN = "BATTLE_ANIMATION_DAMAGE_FIRE_SPIN",
    MAGMA_STORM = "BATTLE_ANIMATION_DAMAGE_MAGMA_STORM",
    CLAMP = "BATTLE_ANIMATION_DAMAGE_CLAMP",
    WHIRLPOOL = "BATTLE_ANIMATION_DAMAGE_WHIRLPOOL",
    SAND_TOMB = "BATTLE_ANIMATION_DAMAGE_SAND_TOMB",
  }

  -- Continuation roots behind one started or continued weather field.
  local WEATHER_ROOTS = {
    fog = "BATTLE_ANIMATION_WEATHER_FOG",
    rain = "BATTLE_ANIMATION_WEATHER_RAIN",
    hail = "BATTLE_ANIMATION_WEATHER_HAIL",
    sand = "BATTLE_ANIMATION_WEATHER_SAND",
    sun = "BATTLE_ANIMATION_WEATHER_SUN",
  }

  -- Feedback roots that stay eligible while the affected battler hides
  -- behind a substitute or while the scene is off: wrapper and doll
  -- traffic, the escape follow-up, and the weather continuations.
  local SUBSTITUTE_GATE_ROOTS = {
    ["BATTLE_ANIMATION_SUB_OUT"] = true,
    ["BATTLE_ANIMATION_SUB_IN"] = true,
    ["BATTLE_ANIMATION_ITEM_ESCAPE"] = true,
    ["BATTLE_ANIMATION_WEATHER_FOG"] = true,
    ["BATTLE_ANIMATION_WEATHER_RAIN"] = true,
    ["BATTLE_ANIMATION_WEATHER_HAIL"] = true,
    ["BATTLE_ANIMATION_WEATHER_SAND"] = true,
    ["BATTLE_ANIMATION_WEATHER_SUN"] = true,
    ["BATTLE_ANIMATION_SUBSTITUTE_IN"] = true,
    ["BATTLE_ANIMATION_SUBSTITUTE_OUT"] = true,
  }

  -- Selection reads only the producer's semantic facts: the execution
  -- moment selects the primary root with its source variant, each
  -- applied operation selects its feedback roots, and events without
  -- either omit with an explicit diagnostic reason. No kind-derived
  -- route table participates.
  local presentation = event.presentation
  local execution = nil ---@type table<string, unknown>?
  local operation = nil ---@type table<string, unknown>?
  local contextFacts = nil ---@type table<string, unknown>?
  if type(presentation) == "table" then
    local facts = presentation --[[@as table<string, unknown>]]
    if type(facts.execution) == "table" then
      execution = facts.execution --[[@as table<string, unknown>]]
    end
    if type(facts.operation) == "table" then
      operation = facts.operation --[[@as table<string, unknown>]]
    end
    if type(facts.context) == "table" then
      contextFacts = facts.context --[[@as table<string, unknown>]]
    end
  end

  -- Playback context behind one request: the source variant mapped
  -- from the execution moment and branch, calculated damage, resolved
  -- power, and friendship beside the frozen battle predicates. Absent
  -- values stay absent; nothing is invented for programs that do not
  -- read them.
  ---@param variant integer source animation variant behind the root
  ---@param moment table<string, unknown>? execution moment carrying damage, power, and friendship
  ---@return table<string, unknown> detached playback context
  local function requestContext(variant, moment)
    local context = { animationVariant = variant, isContest = false } ---@type table<string, unknown>
    if type(moment) == "table" then
      if type(moment.damage) == "number" then
        context.moveDamage = moment.damage
      end
      if type(moment.power) == "number" then
        context.movePower = moment.power
      end
      if type(moment.friendship) == "number" then
        context.friendship = moment.friendship
      end
    end
    if type(contextFacts) == "table" then
      for _, field in ipairs({ "effectiveWeather", "noFieldConditions", "terrain", "battleFormat" }) do
        local value = (contextFacts --[[@as table<string, unknown>]])[field]
        if value ~= nil then
          context[field] = value
        end
      end
    end
    return context
  end

  local requests = {} ---@type table<integer, table<string, unknown>>
  local ordinal = 1
  if type(execution) == "table" then
    local hit = (execution --[[@as table<string, unknown>]]).hitOrdinal
    if type(hit) == "number" and hit % 1 == 0 and hit >= 1 then
      ordinal = hit --[[@as integer]]
    end
  end

  ---@param effectKey string catalog key behind the request
  ---@param invocationKind string source caller kind behind the request
  ---@param disposition string admit or explicit omit reason behind the request
  ---@param stage string anchor stage behind the request
  ---@param index integer anchor index behind the request
  ---@param parts table<string, unknown> frozen attacker/defender/targets, context, and event behind the request
  local function pushRequest(effectKey, invocationKind, disposition, stage, index, parts)
    local attacker = parts.attacker
    local defender = parts.defender
    local targets = parts.targets
    requests[#requests + 1] =
      freezeRequest(launchId, sequence, ordinal, effectKey, invocationKind, disposition, stage, index, {
        attacker = attacker,
        defender = defender,
        targets = targets,
        positions = positions,
        event = event,
        context = parts.context,
      })
    ordinal = ordinal + 1
  end

  -- Frozen attacker/defender/targets behind one admission: explicit
  -- roles resolve through the event-time views and fail loudly naming
  -- the missing role instead of guessing a replacement.
  ---@param fallback table<string, unknown>? applied operation carrying the subject fallback
  ---@return table<string, unknown> attacker binding
  ---@return table<string, unknown> defender binding
  ---@return table<integer, table<string, unknown>> ordered target bindings
  local function admitRoles(fallback)
    local actorEntries = event.actors
    if (type(actorEntries) ~= "table" or #actorEntries == 0) and type(fallback) == "table" then
      local subject = (fallback --[[@as table<string, unknown>]]).subject
      if type(subject) == "table" then
        actorEntries = { subject }
      end
    end
    local targetEntries = event.targets
    if (type(targetEntries) ~= "table" or #targetEntries == 0) and type(fallback) == "table" then
      local subject = (fallback --[[@as table<string, unknown>]]).subject
      if type(subject) == "table" then
        targetEntries = { subject }
      end
    end
    local actors = resolveRoles(packet, actorEntries, "actor", slotGeometry)
    local targets = resolveRoles(packet, targetEntries, "target", slotGeometry)
    return actors[1], targets[1], targets
  end

  -- Soft topology behind an omission: roles that resolve picture
  -- nothing new, so unresolvable roles degrade to explicit false
  -- bindings instead of failing the surrounding narration and
  -- health work.
  ---@return table<string, unknown> frozen topology with explicit false bindings on failure
  local function omitTopology()
    local ok, attacker = pcall(resolveRoles, packet, event.actors, "actor", slotGeometry)
    local okTargets, targets = pcall(resolveRoles, packet, event.targets, "target", slotGeometry)
    if not ok or not okTargets then
      return {
        attacker = false,
        defender = false,
        targets = {},
      }
    end
    return { attacker = attacker[1], defender = targets[1], targets = targets }
  end

  -- Whether the operation subject hides behind a substitute or a
  -- semi-invulnerable turn in the frozen event-time context.
  ---@param subject table<string, unknown>? semantic operation subject under gate inspection
  ---@return boolean true when the subject's frozen binding hides
  local function subjectHides(subject)
    if type(subject) ~= "table" or type(contextFacts) ~= "table" then
      return false
    end
    local battlers = (contextFacts --[[@as table<string, unknown>]]).battlers
    if type(battlers) ~= "table" then
      return false
    end
    local combatant = (subject --[[@as table<string, unknown>]]).combatant
    for _, binding in ipairs(battlers) do
      if
        type(binding) == "table" and (binding --[[@as table<string, unknown>]]).combatant == combatant
      then
        local record = binding --[[@as table<string, unknown>]]
        return record.substitute == true or record.hidden == true
      end
    end
    return false
  end

  ---@param reason string explicit omit reason behind the diagnostic request
  local function pushOmit(reason)
    local topology = omitTopology()
    local key = type(event.cause) == "table" and type(event.cause.key) == "string" and event.cause.key
      or (event.move ~= nil and type(event.move.executed) == "string" and event.move.executed or kind)
    local invocation = (
      kind == "switch"
      or kind == "flee"
      or kind == "throw"
      or kind == "shake"
      or kind == "caught"
      or kind == "broke_free"
      or kind == "join"
      or kind == "acknowledge"
      or kind == "learn"
      or kind == "declined"
    )
        and "controller"
      or "feedback-script"
    pushRequest(key, invocation, reason, "after-announcement", 1, {
      attacker = topology.attacker,
      defender = topology.defender,
      targets = topology.targets,
      context = requestContext(0, nil),
    })
  end

  -- Omission behind a hit-kind event without producer facts: the
  -- strike names its actor and target explicitly, so missing roles
  -- fail loudly naming the role instead of degrading to false
  -- bindings. Narration-only kinds keep the soft topology; a hit
  -- never guesses.
  ---@param reason string explicit omit reason behind the diagnostic hit
  local function pushHitOmit(reason)
    local actors = resolveRoles(packet, event.actors, "actor", slotGeometry)
    local targets = resolveRoles(packet, event.targets, "target", slotGeometry)
    local key = type(event.cause) == "table" and type(event.cause.key) == "string" and event.cause.key
      or (event.move ~= nil and type(event.move.executed) == "string" and event.move.executed or kind)
    pushRequest(key, "feedback-script", reason, "after-announcement", 1, {
      attacker = actors[1],
      defender = targets[1],
      targets = targets,
      context = requestContext(0, nil),
    })
  end

  ---@param effectKey string admitted catalog key behind the request
  ---@param stage string anchor stage behind the request
  ---@param invocationKind string? source caller kind, feedback-script when absent
  ---@param appliedOp table<string, unknown>? applied operation carrying the subject fallback
  local function pushOperationAdmit(effectKey, stage, invocationKind, appliedOp)
    local attacker, defender, targets = admitRoles(appliedOp)
    local disposition = "admit" ---@type string
    if options ~= nil and options.battleScene == false and not SUBSTITUTE_GATE_ROOTS[effectKey] then
      disposition = "omit:scene-off" --[[@as string]]
    end
    if
      subjectHides(type(appliedOp) == "table" and (appliedOp --[[@as table<string, unknown>]]).subject or nil)
    then
      if not SUBSTITUTE_GATE_ROOTS[effectKey] then
        disposition = "omit:substitute-gate" --[[@as string]]
      end
    end
    pushRequest(effectKey, invocationKind or "feedback-script", disposition, stage, 1, {
      attacker = attacker,
      defender = defender,
      targets = targets,
      context = requestContext(0, nil),
    })
  end

  -- The primary root: the execution moment owns the source call, its
  -- variant maps from the moment and branch, and the scene gate keeps
  -- switched-off battles on narration and health while Transform
  -- still plays.
  if type(execution) == "table" then
    local moment = execution --[[@as table<string, unknown>]]
    local executed = moment.executedMove
    assert(type(executed) == "string" and executed ~= "", "primary moments name their executed move")
    local variant = variantFor(moment.moment --[[@as string]], moment.branch --[[@as string?]])
    local attacker, defender, targets = admitRoles(nil)
    -- The transformed subject pictures its donor: the game-side
    -- projection resolves the donor appearance from the marker facts,
    -- never by re-reading the pre-copy views.
    local donorAppearance = nil ---@type table<string, unknown>?
    if type(event.transformedAppearance) == "table" then
      local projected = event.transformedAppearance --[[@as table<string, unknown>]]
      donorAppearance = {
        species = projected.species,
        form = projected.form,
        gender = projected.gender,
        shiny = projected.shiny,
        personality = projected.personality,
      }
    elseif type(operation) == "table" then
      local applied = operation --[[@as table<string, unknown>]]
      if applied.kind == "transform-applied" and type(applied.donorAppearanceInput) == "table" then
        local input = applied.donorAppearanceInput --[[@as table<string, unknown>]]
        donorAppearance = { species = input.species, form = input.form }
        if type(input.personality) == "number" then
          donorAppearance.personality = input.personality
        end
        local donor = applied.donor --[[@as table<string, unknown>?]]
        if type(donor) == "table" and type(donor.combatant) == "number" then
          local pictured = viewRecordOf(packet, donor.combatant --[[@as integer]])
          if type(pictured) == "table" then
            local view = pictured --[[@as table<string, unknown>]]
            if type(view.gender) == "string" then
              donorAppearance.gender = view.gender
            end
            if type(view.shiny) == "boolean" then
              donorAppearance.shiny = view.shiny
            end
          end
        end
      end
    end
    if donorAppearance ~= nil then
      attacker.appearance = donorAppearance
    end
    local disposition = "admit" ---@type string
    if options ~= nil and options.battleScene == false and executed ~= "TRANSFORM" then
      disposition = "omit:scene-off" --[[@as string]]
    end
    pushRequest(executed, "move-script", disposition, "after-announcement", 1, {
      attacker = attacker,
      defender = defender,
      targets = targets,
      context = requestContext(variant, moment),
    })
  end

  -- Applied operations select their feedback roots after the primary:
  -- the same event may own both its move and its operation sequence,
  -- each with its own pre-gating ordinal.
  if type(operation) == "table" then
    local applied = operation --[[@as table<string, unknown>]]
    local operationKind = applied.kind --[[@as string]]
    if operationKind == "status-applied" then
      local condition = applied.condition
      local root = type(condition) == "string" and STATUS_ROOTS[
        condition --[[@as string]]
      ] or nil
      if applied.application == "rest" then
        pushOmit("omit:rest-uses-own-move")
      elseif type(root) == "string" then
        pushOperationAdmit(root, "before-feedback-message", nil, applied)
      else
        pushOmit("omit:status-route-pending-producer-facts")
      end
    elseif operationKind == "status-gate" then
      local outcome = applied.outcome
      if outcome == "expired" or outcome == "cured" then
        pushOmit("omit:gate-outcome-carries-no-root")
      else
        local condition = applied.condition
        local root = type(condition) == "string" and STATUS_ROOTS[
          condition --[[@as string]]
        ] or nil
        if type(root) == "string" and (outcome == "blocked" or outcome == "self-hit" or outcome == "passed") then
          pushOperationAdmit(root, "before-feedback-message", nil, applied)
        else
          pushOmit("omit:gate-outcome-carries-no-root")
        end
      end
    elseif operationKind == "confusion-applied" then
      pushOperationAdmit("BATTLE_ANIMATION_CONFUSED", "before-feedback-message", nil, applied)
    elseif operationKind == "stage-changed" then
      if applied.method == "reset" or applied.method == "copy" or applied.profile == "silent" then
        pushOmit("omit:silent-stage-carries-no-root")
      else
        local before = applied.before
        local after = applied.after
        if type(before) == "number" and type(after) == "number" and after ~= before then
          local root = after > before and "BATTLE_ANIMATION_STAT_BOOST" or "BATTLE_ANIMATION_STAT_DROP"
          pushOperationAdmit(root, "before-feedback-message", nil, applied)
        else
          pushOmit("omit:uncapped-stage-carries-no-root")
        end
      end
    elseif operationKind == "item-applied" then
      if applied.feedbackOwner ~= true then
        pushOmit("omit:item-feedback-owned-elsewhere")
      elseif applied.channel == "bag" then
        pushOperationAdmit("BATTLE_ANIMATION_BAG_ITEM", "before-feedback-message", "controller", applied)
      else
        pushOperationAdmit("BATTLE_ANIMATION_HELD_ITEM", "before-feedback-message", nil, applied)
      end
    elseif operationKind == "hp-restored" then
      if applied.profile == "weather-recovery" then
        pushOperationAdmit("BATTLE_ANIMATION_RESTORE_HP", "before-health", nil, applied)
      else
        pushOmit("omit:ordinary-recovery-carries-no-auxiliary-root")
      end
    elseif operationKind == "weather-started" or operationKind == "weather-continued" then
      local weather = applied.weather
      local root = type(weather) == "string" and WEATHER_ROOTS[
        weather --[[@as string]]
      ] or nil
      if type(root) == "string" then
        pushOperationAdmit(root, "before-feedback-message", nil, applied)
      else
        pushOmit("omit:unknown-weather-carries-no-root")
      end
    elseif operationKind == "residual" then
      local effect = applied.effect
      local root = type(effect) == "string" and RESIDUAL_EFFECT_ROOTS[
        effect --[[@as string]]
      ] or nil
      if effect == "bind" and type(applied.bindingMove) == "string" then
        root = BINDING_ROOTS[
          applied.bindingMove --[[@as string]]
        ]
      end
      if type(root) == "string" then
        pushOperationAdmit(root, "before-health", nil, applied)
      else
        pushOmit("omit:residual-route-pending-producer-facts")
      end
    elseif operationKind == "substitute-created" then
      local costSequence = applied.costEventSequence
      local anchor = { origin = "event", eventSequence = sequence, stage = "before-health", index = 1 }
      if type(costSequence) == "number" then
        anchor = { origin = "event", eventSequence = costSequence, stage = "before-health", index = 1 }
      end
      local attacker, defender, targets = admitRoles(applied)
      requests[#requests + 1] = freezeRequest(
        launchId,
        sequence,
        ordinal,
        "BATTLE_ANIMATION_SUBSTITUTE_IN",
        "feedback-script",
        "admit",
        anchor.stage --[[@as string]],
        anchor.index --[[@as integer]],
        {
          attacker = attacker,
          defender = defender,
          targets = targets,
          positions = positions,
          event = event,
          context = requestContext(0, nil),
        }
      )
      ordinal = ordinal + 1
      -- Cross-event anchors still name their event origin; freeze the
      -- cost link beside the request identity for the ordering layer.
      requests[#requests].costEventSequence = costSequence
    elseif operationKind == "substitute-hit" then
      if applied.broken == true then
        pushOperationAdmit("BATTLE_ANIMATION_SUBSTITUTE_OUT", "after-feedback-message", nil, applied)
        pushOperationAdmit("BATTLE_ANIMATION_SUB_IN", "after-feedback-message", nil, applied)
      else
        pushOmit("omit:substitute-holds-carries-no-root")
      end
    elseif operationKind == "transform-applied" then
      -- The picture change rides the admitted primary above; the
      -- operation itself owns no second root.
      pushOmit("omit:picture-owned-by-primary")
    elseif operationKind == "switch-ready" then
      local reason = applied.reason
      local departing = applied.departing
      local causeKey = type(event.cause) == "table" and (event.cause --[[@as table<string, unknown>]]).key or nil
      local root = type(causeKey) == "string" and causeKey or nil
      local variant = 0
      if reason == "u-turn" then
        variant = 1
      elseif reason ~= "baton-pass" then
        root = nil
      end
      if type(root) == "string" and type(departing) == "table" then
        local attacker = resolveEntry(packet, departing --[[@as table<string, unknown>]], "actor", slotGeometry)
        pushRequest(root, "move-script", "admit", "before-departure", 1, {
          attacker = attacker,
          defender = false,
          targets = { attacker },
          context = requestContext(variant, nil),
        })
      else
        pushOmit("omit:departure-carries-no-root")
      end
    elseif operationKind == "switch-applied" then
      pushOmit("omit:arrival-carries-no-animation-root")
    elseif operationKind == "entry-ready" then
      pushOmit("omit:entry-plays-through-entry-flow")
    elseif operationKind == "experience-awarded" then
      local active = applied.active == true
      local boundaries = applied.boundaries
      if not active or type(boundaries) ~= "table" or #boundaries == 0 then
        pushOmit(active and "omit:no-level-crossed" or "omit:reserve-recipient")
      else
        -- Level feedback pictures its recipient, never the defeated
        -- foe carried on the event actors: the operation subject is
        -- the only role with the recipient's live entry token.
        local subject = applied.subject --[[@as table<string, unknown>]]
        local pictured = resolveRoles(packet, { subject }, "recipient", slotGeometry)
        local attacker, defender, targets = pictured[1], pictured[1], pictured
        for _, boundary in ipairs(boundaries) do
          local segment = boundary --[[@as table<string, unknown>]]
          local expSegment = segment.expSegment
          if type(expSegment) ~= "number" then
            error("experience boundaries carry their original segment index", 0)
          end
          pushRequest(
            "BATTLE_ANIMATION_LEVEL_UP",
            "feedback-script",
            "admit",
            "after-exp",
            expSegment --[[@as integer]],
            {
              attacker = attacker,
              defender = defender,
              targets = targets,
              context = requestContext(0, nil),
            }
          )
        end
      end
    elseif operationKind == "item-escape" then
      pushOperationAdmit("BATTLE_ANIMATION_ITEM_ESCAPE", "after-announcement", "controller", applied)
    elseif operationKind == "health-cost" then
      pushOmit("omit:cost-carries-no-root")
    else
      pushOmit("omit:unmapped-operation-carries-no-root")
    end
  end

  -- Events without producer facts omit with a diagnostic reason that
  -- preserves the historical vocabulary: announcements narrate, health
  -- still interpolates, and only admitted roots play.
  if #requests == 0 then
    if kind == "struck" then
      local damage = payload.damage
      if type(damage) == "number" and damage == 0 then
        pushHitOmit("omit:unconnected-strike")
      else
        pushHitOmit("omit:spread-continues-shared-cycle")
      end
    elseif kind == "protected" then
      pushHitOmit("omit:incoming-protected")
    elseif kind == "missed" or kind == "move-failed" or kind == "immune" or kind == "blocked" then
      pushHitOmit("omit:unreached-animation-call")
    elseif kind == "switch-intent" then
      pushOmit("omit:intent-not-a-root")
    elseif kind == "status" then
      local cause = event.cause --[[@as table<string, unknown>?]]
      if type(cause) == "table" and cause.key == "REST" then
        pushOmit("omit:rest-uses-own-move")
      else
        pushOmit("omit:status-route-pending-producer-facts")
      end
    elseif kind == "cured" then
      pushOmit("omit:cure-carries-no-root")
    elseif kind == "stage" then
      pushOmit("omit:stage-route-pending-producer-facts")
    elseif kind == "status-gate" then
      pushOmit("omit:status-gate-route-pending-producer-facts")
    elseif kind == "healed" then
      pushOmit("omit:ordinary-recovery-carries-no-auxiliary-root")
    elseif kind == "tick" then
      pushOmit("omit:residual-route-pending-producer-facts")
    else
      local reasons = {
        ["cured"] = "omit:cure-carries-no-root",
        ["stats"] = "omit:stat-snapshot-carries-no-root",
        ["switch"] = "omit:switch-carries-no-animation-root",
        ["multi-hit"] = "omit:summary-carries-no-root",
        ["substitute-broke"] = "omit:substitute-break-route-pending-producer-facts",
        ["recoil"] = "omit:recoil-carries-no-auxiliary-root",
        ["drained"] = "omit:drain-carries-no-auxiliary-root",
        ["faint"] = "omit:faint-carries-no-root",
        ["fainted"] = "omit:faint-carries-no-root",
        ["item"] = "omit:item-route-pending-producer-facts",
        ["item-intent"] = "omit:item-route-pending-producer-facts",
        ["flee"] = "omit:escape-route-pending",
        ["throw"] = "omit:capture-route-pending",
        ["shake"] = "omit:capture-route-pending",
        ["caught"] = "omit:capture-route-pending",
        ["broke_free"] = "omit:capture-route-pending",
        ["join"] = "omit:entry-carries-no-event-root",
        ["acknowledge"] = "omit:acknowledgement-carries-no-root",
        ["learn"] = "omit:learn-carries-no-root",
        ["declined"] = "omit:learn-carries-no-root",
        ["mimicked"] = "omit:copy-route-pending-producer-facts",
        ["sketched"] = "omit:copy-route-pending-producer-facts",
      }
      local reason = reasons[kind] or ("omit:unmapped-kind-" .. kind)
      pushOmit(reason)
    end
  end

  return requests
end

return BattlePresentationFlow
