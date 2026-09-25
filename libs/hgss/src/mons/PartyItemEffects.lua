-- Pure party-item effect arithmetic and HP-transfer planning. Every planner
-- works on a private copy of the caller-supplied mon facts and returns
-- candidate changes only: the caller (PartyActions) prepares and publishes
-- through the owning services. Eligibility mirrors the source party-target
-- checks (pret/pokeheartgold@0985e8718d src/use_item_on_mon.c
-- CanUseItemOnPokemon, src/party_menu.c TransferHP): status cures need
-- their bits, revival needs zero HP, restoration needs injury but not
-- fainting, power-point operations need a chosen occupied move, effort
-- changes follow TryModEV order, and friendship-only reduction berries stay
-- usable. Source mutation order (src/use_item_on_mon.c UseItemOnPokemon)
-- applies status, health, power points, effort, then friendship/mood; a
-- primary miss with an attempted effect consumes nothing and applies no
-- friendship. Timeout/toxic counter bits clear with poison; full-health
-- single-point mons restore one point; power-point ups preserve spent
-- points; effort vitamins cap at 100 per stat and 510 total; Shedinja
-- ignores health-effort effects. Friendship adds the Luxury Ball and
-- matching egg-location bonuses before the held friendship multiplier with
-- source integer flooring, then clamps to 0..255; mood clamps to -127..127.

local ItemErrors = require("libs.items.src.errors")

---@class PartyItemEffects
local PartyItemEffects = {}

-- Persistent condition bits (include/constants/pokemon.h MON_STATUS_*):
-- sleep occupies the low three bits, poison and toxic share the cure, and
-- the toxic turn counter rides in bits 8..11.
local STATUS_SLEEP_BITS = 0x7
local STATUS_POISON = 0x8
local STATUS_BURN = 0x10
local STATUS_FREEZE = 0x20
local STATUS_PARALYSIS = 0x40
local STATUS_TOXIC = 0x80
local STATUS_TOXIC_COUNTER = 0xF00

local EV_ORDER = { "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }
local MAX_EV_SINGLE = 100
local MAX_EV_TOTAL = 510

---@param value unknown
---@return unknown
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

---@param bits integer
---@param bit integer
---@return boolean
local function hasBit(bits, bit)
  return math.floor(bits / bit) % 2 == 1
end

---@param bits integer
---@param mask integer
---@return integer
local function clearBits(bits, mask)
  local out = 0
  local place = 1
  local remaining = bits
  local remainingMask = mask
  while remaining > 0 or remainingMask > 0 do
    local bit = remaining % 2
    local masked = remainingMask % 2
    if bit == 1 and masked == 0 then
      out = out + place
    end
    remaining = math.floor(remaining / 2)
    remainingMask = math.floor(remainingMask / 2)
    place = place * 2
  end
  return out
end

---@param maxHp integer
---@param restore table<string, unknown>
---@return integer
local function restoreAmount(maxHp, restore)
  assert(type(maxHp) == "number" and maxHp % 1 == 0 and maxHp >= 1, "restore needs the derived maximum")
  if maxHp == 1 then
    return 1
  end
  if restore.kind == "full" then
    return maxHp
  elseif restore.kind == "half" then
    return math.floor(maxHp / 2)
  elseif restore.kind == "quarter" then
    return math.floor(maxHp / 4)
  end
  assert(restore.kind == "fixed", "restore names a closed amount kind")
  local amount = assert(restore.amount) --[[@as integer]]
  assert(type(amount) == "number" and amount % 1 == 0 and amount >= 1, "fixed restore needs a positive amount")
  return amount
end

-- Source TryModEV order (src/use_item_on_mon.c): reject lowering zero,
-- reject raising past either budget, then add, clamp to 0..100, and fit the
-- total budget. Returns nil when nothing may change.
---@param ev integer
---@param othersSum integer
---@param by integer
---@return integer|nil
local function tryModEv(ev, othersSum, by)
  if ev == 0 and by < 0 then
    return nil
  end
  if ev >= MAX_EV_SINGLE and by > 0 then
    return nil
  end
  if ev + othersSum >= MAX_EV_TOTAL and by > 0 then
    return nil
  end
  ev = ev + by
  if ev > MAX_EV_SINGLE then
    ev = MAX_EV_SINGLE
  elseif ev < 0 then
    ev = 0
  end
  if ev + othersSum > MAX_EV_TOTAL then
    ev = MAX_EV_TOTAL - othersSum
  end
  return ev
end

---@param evs table<string, integer>
---@return integer
local function evTotal(evs)
  local total = 0
  for _, stat in ipairs(EV_ORDER) do
    total = total + (evs[stat] or 0)
  end
  return total
end

-- Source friendship write (src/use_item_on_mon.c DoItemFriendshipMod):
-- positive deltas add the Luxury Ball and matching egg-location bonuses
-- before the held friendship multiplier with integer flooring; negative
-- deltas take no bonus. Clamps to 0..255.
---@param mon table<string, unknown>
---@param friendship integer
---@param mod integer
---@param location integer|nil
---@param catalog table<string, unknown>
---@return integer
local function applyFriendship(mon, friendship, mod, location, catalog)
  if friendship == 255 and mod > 0 then
    return friendship
  end
  if friendship == 0 and mod < 0 then
    return friendship
  end
  if mod > 0 then
    if
      mon.origin ~= nil and (mon.origin --[[@as table<string, unknown>]]).ball == "LUXURY_BALL"
    then
      mod = mod + 1
    end
    if
      location ~= nil
      and mon.egg ~= nil
      and (mon.egg --[[@as table<string, unknown>]]).location == location
    then
      mod = mod + 1
    end
    local held = mon.heldItem
    if type(held) == "string" then
      local lookup = catalog.item
      assert(type(lookup) == "function", "held items resolve through the catalog")
      local definition = lookup(catalog, held)
      assert(type(definition) == "table", "held items resolve through the catalog")
      if
        (definition --[[@as table<string, unknown>]]).friendshipBoost == true
      then
        mod = math.floor(mod * 150 / 100)
      end
    end
  end
  mod = mod + friendship
  if mod > 255 then
    mod = 255
  end
  if mod < 0 then
    mod = 0
  end
  return mod
end

---@param definition table<string, unknown>
---@return table<string, unknown>
local function partyUseOf(definition)
  assert(type(definition) == "table", "effect planning needs an item definition")
  local partyUse = definition.partyUse
  if type(partyUse) ~= "table" then
    ItemErrors.raise(ItemErrors.CATALOG_INVALID, "item definition carries no party-use metadata", {})
  end
  assert(type(partyUse) == "table", "party-use metadata validated above")
  return partyUse
end

---@param staged table<string, unknown>
---@param hpBefore integer
---@param statusBefore integer
---@return table<string, integer>
local function slotFacts(staged, hpBefore, statusBefore)
  local condition = assert(staged.condition) --[[@as table<string, unknown>]]
  return {
    hpBefore = hpBefore,
    hpAfter = assert(condition.currentHp) --[[@as integer]],
    statusBefore = statusBefore,
    statusAfter = assert(condition.status) --[[@as integer]],
  }
end

-- Applies the friendship band and mood of a successful primary effect, or
-- of a friendship-only reduction berry. Source order applies the mood
-- before the friendship write, even when the write cannot move.
---@param staged table<string, unknown>
---@param partyUse table<string, unknown>
---@param location integer|nil
---@param catalog table<string, unknown>
local function applyCompanions(staged, partyUse, location, catalog)
  local friendship = partyUse.friendship
  if friendship == nil then
    return
  end
  assert(type(friendship) == "table", "friendship bands form a record")
  local bands = friendship --[[@as table<string, integer>]]
  local current = assert(staged.friendship) --[[@as integer]]
  local mod = nil
  if current < 100 then
    mod = bands.lo
  elseif current < 200 then
    mod = bands.med
  else
    mod = bands.hi
  end
  local mood = partyUse.mood or 0
  assert(type(mood) == "number" and mood % 1 == 0, "mood deltas are integers")
  if mood ~= 0 then
    local adjusted = (
      assert(staged.mood) --[[@as integer]]
    ) + mood
    if adjusted > 127 then
      adjusted = 127
    elseif adjusted < -127 then
      adjusted = -127
    end
    staged.mood = adjusted
  end
  assert(type(mod) == "number", "the matching friendship band names a delta")
  staged.friendship = applyFriendship(staged, current, mod, location, catalog)
end

-- Whether a reduction berry may be used for friendship alone: the effort
-- value cannot move but the current band carries a positive delta.
---@param partyUse table<string, unknown>
---@param friendship integer
---@return boolean
local function friendshipOnlyUsable(partyUse, friendship)
  if friendship >= 255 then
    return false
  end
  local bands = partyUse.friendship
  if type(bands) ~= "table" then
    return false
  end
  local named = bands --[[@as table<string, integer>]]
  local mod = nil
  if friendship < 100 then
    mod = named.lo
  elseif friendship < 200 then
    mod = named.med
  else
    mod = named.hi
  end
  return type(mod) == "number" and mod > 0
end

---@param staged table<string, unknown>
---@param partyUse table<string, unknown>
---@param maxHp integer
---@return boolean
local function planMedicine(staged, partyUse, maxHp)
  local condition = assert(staged.condition) --[[@as table<string, unknown>]]
  local hp = assert(condition.currentHp) --[[@as integer]]
  local status = assert(condition.status) --[[@as integer]]
  local cures = assert(partyUse.cures) --[[@as table<string, boolean>]]
  local changed = false
  if cures.sleep == true and status % 8 ~= 0 then
    condition.status = clearBits(status, STATUS_SLEEP_BITS)
    status = condition.status --[[@as integer]]
    changed = true
  end
  if cures.poison == true and (hasBit(status, STATUS_POISON) or hasBit(status, STATUS_TOXIC)) then
    condition.status = clearBits(status, STATUS_POISON + STATUS_TOXIC + STATUS_TOXIC_COUNTER)
    status = condition.status --[[@as integer]]
    changed = true
  end
  if cures.burn == true and hasBit(status, STATUS_BURN) then
    condition.status = clearBits(status, STATUS_BURN)
    status = condition.status --[[@as integer]]
    changed = true
  end
  if cures.freeze == true and hasBit(status, STATUS_FREEZE) then
    condition.status = clearBits(status, STATUS_FREEZE)
    status = condition.status --[[@as integer]]
    changed = true
  end
  if cures.paralysis == true and hasBit(status, STATUS_PARALYSIS) then
    condition.status = clearBits(status, STATUS_PARALYSIS)
    status = condition.status --[[@as integer]]
    changed = true
  end
  local revive = partyUse.revive or "none"
  local restore = partyUse.restore
  if hp == 0 then
    -- Revival carries its own restore amount; plain restoration never
    -- revives, matching the source eligibility order.
    if revive == "single" then
      if restore ~= nil then
        condition.currentHp = math.min(restoreAmount(maxHp, restore --[[@as table<string, unknown>]]), maxHp)
      else
        condition.currentHp = maxHp
      end
      changed = true
    end
  elseif restore ~= nil and (revive == "none" or changed) and hp < maxHp then
    -- A revival-flagged item heals the living only alongside a cured
    -- status; otherwise restoration belongs to unflagged medicine.
    condition.currentHp = math.min(hp + restoreAmount(maxHp, restore --[[@as table<string, unknown>]]), maxHp)
    changed = true
  end
  return changed
end

---@param staged table<string, unknown>
---@param partyUse table<string, unknown>
---@param moveSlot integer|nil
---@param catalog table<string, unknown>
---@return string
local function planPp(staged, partyUse, moveSlot, catalog)
  local moves = assert(staged.moves) --[[@as table<integer, table<string, unknown>>]]
  local lookup = catalog.move
  assert(type(lookup) == "function", "move lookup resolves base power points")
  local function maxPpOf(entry)
    local definition = lookup(catalog, entry.move)
    assert(type(definition) == "table", "known moves carry definitions")
    local basePp = (definition --[[@as table<string, unknown>]]).basePp
    assert(type(basePp) == "number" and basePp % 1 == 0, "moves carry integer base power points")
    local ups = assert(entry.ppUps) --[[@as integer]]
    basePp = basePp --[[@as integer]]
    return basePp, basePp + math.floor(basePp * ups / 5)
  end
  if partyUse.target == "one" then
    if moveSlot == nil then
      return "needs_move"
    end
    assert(type(moveSlot) == "number" and moveSlot % 1 == 0, "move slots are zero-based integers")
    local entry = moves[moveSlot + 1]
    if type(entry) ~= "table" then
      return "ineligible"
    end
    if partyUse.boost ~= nil then
      local ups = assert(entry.ppUps) --[[@as integer]]
      if ups >= 3 then
        return "no_effect"
      end
      local basePp, oldMax = maxPpOf(entry)
      if basePp < 5 then
        return "no_effect"
      end
      local newUps = ups + partyUse.boost --[[@as integer]]
      if newUps > 3 then
        newUps = 3
      end
      local newMax = basePp + math.floor(basePp * newUps / 5)
      entry.ppUps = newUps
      entry.pp = (
        assert(entry.pp) --[[@as integer]]
      )
        + newMax
        - oldMax
      return "ready"
    end
    local _, maxPp = maxPpOf(entry)
    local pp = assert(entry.pp) --[[@as integer]]
    if pp >= maxPp then
      return "no_effect"
    end
    if partyUse.restore == "full" then
      entry.pp = maxPp
    else
      local amount = assert(partyUse.restore) --[[@as integer]]
      assert(type(amount) == "number", "fixed restoration names an amount")
      entry.pp = math.min(pp + amount, maxPp)
    end
    return "ready"
  end
  assert(partyUse.target == "all", "power-point targets are one or all")
  local restored = false
  for _, entry in ipairs(moves) do
    if type(entry) == "table" then
      local _, maxPp = maxPpOf(entry)
      local pp = assert(entry.pp) --[[@as integer]]
      if pp < maxPp then
        if partyUse.restore == "full" then
          entry.pp = maxPp
        else
          local amount = assert(partyUse.restore) --[[@as integer]]
          entry.pp = math.min(pp + amount, maxPp)
        end
        restored = true
      end
    end
  end
  if restored then
    return "ready"
  end
  return "no_effect"
end

---@param staged table<string, unknown>
---@param partyUse table<string, unknown>
---@return string
local function planEv(staged, partyUse)
  local evs = assert(staged.evs) --[[@as table<string, integer>]]
  local changes = assert(partyUse.changes) --[[@as table<integer, table<string, unknown>>]]
  local changed = false
  for _, change in ipairs(changes) do
    local entry = change --[[@as table<string, unknown>]]
    local stat = assert(entry.stat) --[[@as string]]
    local delta = assert(entry.delta) --[[@as integer]]
    if stat == "hp" and staged.species == "SHEDINJA" then
      -- Shedinja ignores health-effort effects outright.
    elseif delta > 0 then
      local ev = assert(evs[stat]) --[[@as integer]]
      if ev < MAX_EV_SINGLE and evTotal(evs) < MAX_EV_TOTAL then
        local others = evTotal(evs) - ev
        local result = tryModEv(ev, others, delta)
        assert(result ~= nil, "positive deltas passing eligibility always apply")
        evs[stat] = result
        changed = true
      end
    else
      local ev = assert(evs[stat]) --[[@as integer]]
      if ev > 0 then
        local others = evTotal(evs) - ev
        local result = tryModEv(ev, others, delta)
        assert(result ~= nil, "lowering a positive value always applies")
        evs[stat] = result
        changed = true
      end
    end
  end
  if changed then
    return "ready"
  end
  return "friendship_check"
end

-- Plans a single party-item use on copied facts. Returns a ready plan with
-- the staged mon and presentation feedback, needs_move when a power-point
-- item still needs its target move, no_effect when nothing may change,
-- ineligible for the wrong target, or feature_unavailable for explicitly
-- deferred effects. Malformed generated metadata raises loudly.
---@param mon table<string, unknown>
---@param itemDefinition table<string, unknown>
---@param moveSlot integer|nil
---@param context table<string, unknown>
---@param derived table<string, unknown>
---@return table<string, unknown>
function PartyItemEffects.plan(mon, itemDefinition, moveSlot, context, derived)
  assert(type(mon) == "table", "effect planning needs a mon record")
  assert(type(context) == "table", "effect planning needs a context record")
  assert(type(derived) == "table", "effect planning needs the derived facts")
  local maxHp = assert(derived.maxHp) --[[@as integer]]
  assert(type(maxHp) == "number" and maxHp % 1 == 0 and maxHp >= 1, "derived facts carry the maximum")
  local partyUse = partyUseOf(itemDefinition)
  local kind = partyUse.kind
  if kind == "machine" or kind == "deferred" then
    return { kind = "feature_unavailable" }
  end
  if kind == "none" then
    return { kind = "ineligible" }
  end
  if kind ~= "medicine" and kind ~= "pp" and kind ~= "ev" and kind ~= "revive_all" then
    ItemErrors.raise(ItemErrors.CATALOG_INVALID, "item definition carries an unknown party-use kind", {
      kind = tostring(kind),
    })
  end
  if mon.isEgg == true then
    return { kind = "ineligible" }
  end
  local staged = copyValue(mon)
  local condition = staged.condition
  assert(type(condition) == "table", "mon facts carry a condition record")
  local hpBefore = assert(condition.currentHp) --[[@as integer]]
  local statusBefore = assert(condition.status) --[[@as integer]]
  local catalog = assert(context.catalog) --[[@as table<string, unknown>]]
  assert(type(catalog) == "table", "effect planning needs a catalog in context")
  local location = context.location
  assert(location == nil or type(location) == "number", "context location is an integer when present")
  if kind == "revive_all" then
    if hpBefore ~= 0 then
      return { kind = "no_effect" }
    end
    condition.currentHp = maxHp
    return {
      kind = "ready",
      updates = staged,
      feedback = {
        slots = { slotFacts(staged, hpBefore, statusBefore) },
        textKey = "revived",
        bindings = {},
      },
    }
  end
  if kind == "medicine" then
    if not planMedicine(staged, partyUse, maxHp) then
      return { kind = "no_effect" }
    end
    applyCompanions(staged, partyUse, location, catalog)
    local afterFacts = assert(staged.condition) --[[@as table<string, unknown>]]
    local textKey = "status_cured"
    local bindings = {}
    if hpBefore == 0 then
      textKey = "revived"
    elseif
      afterFacts.currentHp --[[@as integer]]
      ~= hpBefore
    then
      textKey = "hp_restored"
      bindings.amount = afterFacts.currentHp --[[@as integer]] - hpBefore
    end
    return {
      kind = "ready",
      updates = staged,
      feedback = {
        slots = { slotFacts(staged, hpBefore, statusBefore) },
        textKey = textKey,
        bindings = bindings,
      },
    }
  end
  if kind == "pp" then
    local verdict = planPp(staged, partyUse, moveSlot, catalog)
    if verdict ~= "ready" then
      return { kind = verdict }
    end
    applyCompanions(staged, partyUse, location, catalog)
    local bindings = {}
    if moveSlot ~= nil then
      local entry = (assert(staged.moves) --[[@as table<integer, table<string, unknown>>]])[moveSlot + 1]
      bindings.move = (entry --[[@as table<string, unknown>]]).move
    end
    local textKey = "pp_restored"
    if partyUse.boost ~= nil then
      textKey = "pp_boosted"
    end
    return {
      kind = "ready",
      updates = staged,
      feedback = {
        slots = { slotFacts(staged, hpBefore, statusBefore) },
        textKey = textKey,
        bindings = bindings,
      },
    }
  end
  local verdict = planEv(staged, partyUse)
  if verdict == "ready" then
    applyCompanions(staged, partyUse, location, catalog)
    return {
      kind = "ready",
      updates = staged,
      feedback = {
        slots = { slotFacts(staged, hpBefore, statusBefore) },
        textKey = "ev_changed",
        bindings = {},
      },
    }
  end
  local friendship = assert(staged.friendship) --[[@as integer]]
  if friendshipOnlyUsable(partyUse, friendship) then
    applyCompanions(staged, partyUse, location, catalog)
    return {
      kind = "ready",
      updates = staged,
      feedback = {
        slots = { slotFacts(staged, hpBefore, statusBefore) },
        textKey = "friendship_changed",
        bindings = {},
      },
      friendshipOnly = true,
    }
  end
  return { kind = "no_effect" }
end

-- Plans a donor-to-recipient health transfer on copied facts. The donor
-- loses the full fifth of its derived maximum while the recipient gains up
-- to its missing health; no power points or bag items move.
---@param donor table<string, unknown>
---@param recipient table<string, unknown>
---@param donorDerived table<string, unknown>
---@param recipientDerived table<string, unknown>
---@return table<string, unknown>
function PartyItemEffects.planTransfer(donor, recipient, donorDerived, recipientDerived)
  assert(type(donor) == "table" and type(recipient) == "table", "transfer planning needs both mon records")
  if donor == recipient then
    return { kind = "ineligible" }
  end
  local donorMax = assert(donorDerived.maxHp) --[[@as integer]]
  local recipientMax = assert(recipientDerived.maxHp) --[[@as integer]]
  assert(type(donorMax) == "number" and donorMax % 1 == 0 and donorMax >= 1, "transfer needs the donor maximum")
  assert(
    type(recipientMax) == "number" and recipientMax % 1 == 0 and recipientMax >= 1,
    "transfer needs the recipient maximum"
  )
  local amount = math.floor(donorMax / 5)
  local donorCondition = assert(donor.condition) --[[@as table<string, unknown>]]
  local recipientCondition = assert(recipient.condition) --[[@as table<string, unknown>]]
  local donorHp = assert(donorCondition.currentHp) --[[@as integer]]
  local recipientHp = assert(recipientCondition.currentHp) --[[@as integer]]
  if amount < 1 then
    return { kind = "ineligible" }
  end
  if donor.isEgg == true or recipient.isEgg == true then
    return { kind = "ineligible" }
  end
  if donorHp <= amount then
    return { kind = "ineligible" }
  end
  if recipientHp == 0 or recipientHp >= recipientMax then
    return { kind = "ineligible" }
  end
  local stagedDonor = copyValue(donor)
  local donorFacts = assert(stagedDonor.condition) --[[@as table<string, unknown>]]
  donorFacts.currentHp = donorHp - amount
  local stagedRecipient = copyValue(recipient)
  local recipientFacts = assert(stagedRecipient.condition) --[[@as table<string, unknown>]]
  recipientFacts.currentHp = math.min(recipientHp + amount, recipientMax)
  local received = recipientFacts.currentHp --[[@as integer]] - recipientHp
  return {
    kind = "ready",
    donor = stagedDonor,
    recipient = stagedRecipient,
    feedback = {
      slots = {
        {
          hpBefore = donorHp,
          hpAfter = donorHp - amount,
          statusBefore = donorCondition.status,
          statusAfter = donorCondition.status,
        },
        {
          hpBefore = recipientHp,
          hpAfter = recipientHp + received,
          statusBefore = recipientCondition.status,
          statusAfter = recipientCondition.status,
        },
      },
      textKey = "hp_transfer",
      bindings = { amount = received },
    },
  }
end

return PartyItemEffects
