-- Concrete HGSS party action orchestration: give, take and exchange of
-- ordinary held items plus machine move teaching over the borrowed mon
-- and bag services. Requests are
-- value-only records qualified by both owners' revisions; selection
-- identity is revision plus slot, never nickname, species or PID. Every
-- expected failure is decided before the publication window: both
-- preparations are validated and allocated, confirmed current, then
-- published synchronously with no yield, callback, rendering, audio or
-- fallible work between them. Discarding a preparation has no effect.

local HeldItemFormPolicy = require("libs.hgss.src.mons.HeldItemFormPolicy")
local MachineTeaching = require("libs.hgss.src.mons.MachineTeaching")
local PartyItemEffects = require("libs.hgss.src.mons.PartyItemEffects")

---@class PartyActions
---@field private _mons HgssMonService
---@field private _bag HgssBagService
local PartyActions = {}
PartyActions.__index = PartyActions

---@class PartyActionDisplayFacts
---@field heldItem string
---@field form integer
---@field maxHp integer

---@class PartyActionRequest
---@field kind string
---@field slot integer
---@field partyRevision integer
---@field bagRevision integer
---@field item string?
---@field expectedHeld string?
---@field confirmed boolean?
---@field moveSlot integer?
---@field targetSlot integer?
---@field expectedOldMove string?

---@param opts { mons: HgssMonService, bag: HgssBagService }
---@return PartyActions
function PartyActions.new(opts)
  assert(type(opts) == "table", "party actions require an options record")
  assert(opts.mons ~= nil, "party actions borrow the mon service")
  assert(opts.bag ~= nil, "party actions borrow the bag service")
  return setmetatable({ _mons = opts.mons, _bag = opts.bag }, PartyActions)
end

---@param mon table<string, unknown>
---@return { heldItem: string, form: integer, maxHp: integer }
function PartyActions:_displayFacts(mon)
  assert(type(mon.heldItem) == "string", "display facts require the held item")
  assert(type(mon.form) == "number", "display facts require the stored form")
  return { heldItem = mon.heldItem, form = mon.form, maxHp = self._mons:derive(mon).maxHp }
end

---@param key string
---@return boolean
function PartyActions:_isMail(key)
  return self._bag:catalog():item(key).pocket == "mail"
end

-- Decides a request without touching either owner. Returns either a refusal
-- record or a ready plan carrying the staged updates, deltas and
-- before/after display facts. Item uses and health transfers plan through
-- the pure effect policy on copied facts; give/take keep the held-item
-- exchange below.
---@param request PartyActionRequest
---@return { kind: string, updates: { slot: integer, mon: table<string, unknown> }[]?, deltas: { op: string, item: string, quantity: integer }[]?, before: PartyActionDisplayFacts?, after: PartyActionDisplayFacts?, feedback: table<string, unknown>? }
function PartyActions:_resolve(request)
  assert(type(request) == "table", "party actions require a request record")
  assert(
    request.kind == "give"
      or request.kind == "take"
      or request.kind == "use_item"
      or request.kind == "transfer_hp"
      or request.kind == "teach_move",
    "party action kind must be give, take, use_item, transfer_hp or teach_move"
  )
  assert(type(request.slot) == "number" and request.slot % 1 == 0, "party action slot must be an integer")
  if request.partyRevision ~= self._mons:partyRevision() or request.bagRevision ~= self._bag:revision() then
    return { kind = "stale" }
  end
  local mon = self._mons:partyMon(request.slot)
  if request.kind == "teach_move" then
    return self:_resolveTeach(request, mon)
  end
  if request.kind == "use_item" then
    return self:_resolveUseItem(request, mon)
  end
  if request.kind == "transfer_hp" then
    return self:_resolveTransfer(request, mon)
  end
  if request.expectedHeld ~= nil and mon.heldItem ~= request.expectedHeld then
    return { kind = "stale" }
  end
  if mon.heldItem ~= "NONE" and self:_isMail(mon.heldItem) then
    return { kind = "feature_unavailable" }
  end
  if request.kind == "take" then
    if mon.heldItem == "NONE" then
      return { kind = "no_effect" }
    end
    if not self._bag:hasSpace(mon.heldItem, 1) then
      return { kind = "bag_full" }
    end
    local noneDef = self._bag:catalog():item("NONE")
    local heldItem = mon.heldItem
    assert(type(heldItem) == "string", "a held item resolves to its key")
    local staged = HeldItemFormPolicy.apply(mon, noneDef, self._mons)
    staged.heldItem = "NONE"
    return {
      kind = "ready",
      updates = { { slot = request.slot, mon = staged } },
      deltas = { { op = "add", item = heldItem, quantity = 1 } },
      before = self:_displayFacts(mon),
      after = self:_displayFacts(staged),
    }
  end
  assert(type(request.item) == "string", "a give request names its item")
  local definition = self._bag:catalog():item(request.item)
  if definition.pocket == "mail" then
    return { kind = "feature_unavailable" }
  end
  if not self._bag:has(request.item, 1) then
    return { kind = "stale" }
  end
  if mon.heldItem == request.item then
    return { kind = "no_effect" }
  end
  if not definition.canHold then
    return { kind = "ineligible" }
  end
  if mon.heldItem ~= "NONE" then
    if not request.confirmed then
      return { kind = "needs_confirmation" }
    end
    -- Source capacity order: the old item's destination is decided before
    -- the new stack is removed, so a full pocket rejects instead of
    -- exploiting a transient free slot.
    if not self._bag:hasSpace(mon.heldItem, 1) then
      return { kind = "bag_full" }
    end
    local heldItem = mon.heldItem
    assert(type(heldItem) == "string", "an exchanged item resolves to its key")
    local staged = HeldItemFormPolicy.apply(mon, definition, self._mons)
    staged.heldItem = request.item
    return {
      kind = "ready",
      updates = { { slot = request.slot, mon = staged } },
      deltas = {
        { op = "take", item = request.item, quantity = 1 },
        { op = "add", item = heldItem, quantity = 1 },
      },
      before = self:_displayFacts(mon),
      after = self:_displayFacts(staged),
    }
  end
  local staged = HeldItemFormPolicy.apply(mon, definition, self._mons)
  staged.heldItem = request.item
  return {
    kind = "ready",
    updates = { { slot = request.slot, mon = staged } },
    deltas = { { op = "take", item = request.item, quantity = 1 } },
    before = self:_displayFacts(mon),
    after = self:_displayFacts(staged),
  }
end

-- Plans one machine teaching: the pure compatibility policy stages the
-- taught entry with source friendship and mood on a copied mon, while
-- publication consumes one TM or retains the HM with no bag revision.
-- Refusals (known, incompatible, replacement, protected, stale) publish
-- nothing and consume nothing.
---@param request PartyActionRequest
---@param mon table<string, unknown>
---@return { kind: string, updates: { slot: integer, mon: table<string, unknown> }[]?, deltas: { op: string, item: string, quantity: integer }[]?, before: PartyActionDisplayFacts?, after: PartyActionDisplayFacts?, feedback: table<string, unknown>? }
function PartyActions:_resolveTeach(request, mon)
  assert(type(request.item) == "string", "a teach request names its machine")
  if not self._bag:has(request.item, 1) then
    return { kind = "stale" }
  end
  local catalogs = { items = self._bag:catalog(), mons = self._mons:catalog() }
  local planned = MachineTeaching.plan({
    mon = mon,
    item = request.item,
    replaceSlot = request.moveSlot,
    expectedOldMove = request.expectedOldMove,
  }, catalogs, { location = self._mons:currentMapSection() })
  if planned.kind ~= "candidate" then
    return {
      kind = planned.kind --[[@as string]],
    }
  end
  local staged = assert(planned.mon) --[[@as table<string, unknown>]]
  local consumption = assert(planned.consumption) --[[@as integer]]
  local deltas = {}
  if consumption > 0 then
    deltas = { { op = "take", item = request.item, quantity = 1 } }
  end
  local feedback = assert(planned.feedback) --[[@as table<string, unknown>]]
  local bindings = assert(feedback.bindings) --[[@as table<string, unknown>]]
  bindings.item = request.item
  return {
    kind = "ready",
    updates = { { slot = request.slot, mon = staged } },
    deltas = deltas,
    before = self:_displayFacts(mon),
    after = self:_displayFacts(staged),
    feedback = feedback,
  }
end

-- Plans one item use: single-target effects stage one mon update and take
-- exactly one item, while revive-all plans every fainted non-egg member
-- before anything publishes and still consumes once. Pure planning never
-- touches either owner; effort changes finalize health through the shared
-- service adjustment after planning.
---@param request PartyActionRequest
---@param mon table<string, unknown>
---@return { kind: string, updates: { slot: integer, mon: table<string, unknown> }[]?, deltas: { op: string, item: string, quantity: integer }[]?, before: PartyActionDisplayFacts?, after: PartyActionDisplayFacts?, feedback: table<string, unknown>? }
function PartyActions:_resolveUseItem(request, mon)
  assert(type(request.item) == "string", "a use request names its item")
  local definition = self._bag:catalog():item(request.item)
  if not self._bag:has(request.item, 1) then
    return { kind = "stale" }
  end
  local context = { location = self._mons:currentMapSection(), catalog = self._mons:catalog() }
  local partyUse = definition.partyUse
  if
    type(partyUse) == "table" and (partyUse --[[@as table<string, unknown>]]).kind == "revive_all"
  then
    return self:_resolveReviveAll(request, definition, context)
  end
  local derived = self._mons:derive(mon)
  local staged = PartyItemEffects.plan(mon, definition, request.moveSlot, context, derived)
  if staged.kind ~= "ready" then
    return {
      kind = staged.kind --[[@as string]],
    }
  end
  local updates = assert(staged.updates) --[[@as table<string, unknown>]]
  if
    type(partyUse) == "table" and (partyUse --[[@as table<string, unknown>]]).kind == "ev"
  then
    updates = self._mons:refreshStagedHp(updates, derived.maxHp)
  end
  local feedback = assert(staged.feedback) --[[@as table<string, unknown>]]
  local bindings = assert(feedback.bindings) --[[@as table<string, unknown>]]
  bindings.item = request.item
  return {
    kind = "ready",
    updates = { { slot = request.slot, mon = updates } },
    deltas = { { op = "take", item = request.item, quantity = 1 } },
    before = self:_displayFacts(mon),
    after = self:_displayFacts(updates),
    feedback = feedback,
  }
end

-- Plans the all-party revival: every fainted non-egg member revives fully
-- in one party revision with one consumed item and sequential feedback.
---@param request PartyActionRequest
---@param definition table<string, unknown>
---@param context table<string, unknown>
---@return { kind: string, updates: { slot: integer, mon: table<string, unknown> }[]?, deltas: { op: string, item: string, quantity: integer }[]?, before: PartyActionDisplayFacts?, after: PartyActionDisplayFacts?, feedback: table<string, unknown>? }
function PartyActions:_resolveReviveAll(request, definition, context)
  assert(type(request.item) == "string", "a revive-all request names its item")
  local updates = {}
  local slots = {}
  for slot0 = 0, self._mons:partyCount() - 1 do
    local member = self._mons:partyMon(slot0)
    if member.isEgg ~= true then
      local staged = PartyItemEffects.plan(member, definition, nil, context, self._mons:derive(member))
      if staged.kind == "ready" then
        updates[#updates + 1] = { slot = slot0, mon = assert(staged.updates) }
        local facts = assert((assert(staged.feedback) --[[@as table<string, unknown>]]).slots) --[[@as table<integer, table<string, unknown>>]]
        local entry = assert(facts[1]) --[[@as table<string, unknown>]]
        entry.slot = slot0
        slots[#slots + 1] = entry
      end
    end
  end
  if #updates == 0 then
    return { kind = "no_effect" }
  end
  local first = assert(updates[1]) --[[@as table<string, unknown>]]
  local bindings = { item = request.item }
  return {
    kind = "ready",
    updates = updates,
    deltas = { { op = "take", item = request.item, quantity = 1 } },
    before = self:_displayFacts(self._mons:partyMon(first.slot --[[@as integer]])),
    after = self:_displayFacts(first.mon --[[@as table<string, unknown>]]),
    feedback = { slots = slots, textKey = "sacred_ash", bindings = bindings },
  }
end

-- Plans a donor-to-recipient health transfer: two mon updates publish in
-- one party revision with no bag movement and no power-point cost.
---@param request PartyActionRequest
---@param donor table<string, unknown>
---@return { kind: string, updates: { slot: integer, mon: table<string, unknown> }[]?, deltas: { op: string, item: string, quantity: integer }[]?, before: PartyActionDisplayFacts?, after: PartyActionDisplayFacts?, feedback: table<string, unknown>? }
function PartyActions:_resolveTransfer(request, donor)
  assert(
    type(request.targetSlot) == "number" and request.targetSlot % 1 == 0,
    "a transfer request names an integer target slot"
  )
  if request.targetSlot == request.slot then
    return { kind = "ineligible" }
  end
  local recipient = self._mons:partyMon(request.targetSlot)
  local staged = PartyItemEffects.planTransfer(donor, recipient, self._mons:derive(donor), self._mons:derive(recipient))
  if staged.kind ~= "ready" then
    return {
      kind = staged.kind --[[@as string]],
    }
  end
  local feedback = assert(staged.feedback) --[[@as table<string, unknown>]]
  local slots = assert(feedback.slots) --[[@as table<integer, table<string, unknown>>]]
  assert(slots[1] ~= nil and slots[2] ~= nil, "transfer feedback carries both slots")
  local donorFacts = assert(slots[1]) --[[@as table<string, unknown>]]
  local recipientFacts = assert(slots[2]) --[[@as table<string, unknown>]]
  donorFacts.slot = request.slot
  recipientFacts.slot = request.targetSlot
  return {
    kind = "ready",
    updates = {
      { slot = request.slot, mon = assert(staged.donor) },
      { slot = request.targetSlot, mon = assert(staged.recipient) },
    },
    deltas = {},
    before = self:_displayFacts(donor),
    after = self:_displayFacts(assert(staged.donor) --[[@as table<string, unknown>]]),
    feedback = feedback,
  }
end

-- Read-only preview: reports what commit would decide without preparing or
-- publishing anything.
---@param request PartyActionRequest
---@return { kind: string }
function PartyActions:preview(request)
  local decision = self:_resolve(request)
  if decision.kind == "ready" then
    return { kind = "ready" }
  end
  return { kind = decision.kind }
end

-- Validates, prepares both owners, rechecks currency, then publishes once.
---@param request PartyActionRequest
---@return { kind: string, slot: integer?, targetSlot: integer?, before: PartyActionDisplayFacts?, after: PartyActionDisplayFacts?, partyRevision: integer?, bagRevision: integer?, feedback: table<string, unknown>? }
function PartyActions:commit(request)
  local decision = self:_resolve(request)
  if decision.kind ~= "ready" then
    return { kind = decision.kind }
  end
  assert(decision.updates ~= nil and decision.deltas ~= nil, "a ready decision carries its plan")
  local monChange, monReason = self._mons:preparePartyChanges(request.partyRevision, decision.updates)
  if monChange == nil then
    assert(type(monReason) == "string", "a rejected mon preparation names its reason")
    return { kind = monReason }
  end
  local bagChange, bagReason = self._bag:prepareInventoryChanges(request.bagRevision, decision.deltas)
  if bagChange == nil then
    assert(type(bagReason) == "string", "a rejected bag preparation names its reason")
    return { kind = bagReason }
  end
  if not monChange.isCurrent() or not bagChange.isCurrent() then
    return { kind = "stale" }
  end
  -- Preparation has completed every recoverable check and allocation.
  monChange.publish()
  bagChange.publish()
  return {
    kind = "changed",
    slot = request.slot,
    targetSlot = request.targetSlot,
    before = decision.before,
    after = decision.after,
    partyRevision = self._mons:partyRevision(),
    bagRevision = self._bag:revision(),
    feedback = decision.feedback,
  }
end

return PartyActions
