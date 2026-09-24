-- Concrete HGSS party action orchestration: give, take and exchange of
-- ordinary held items over the borrowed mon and bag services. Requests are
-- value-only records qualified by both owners' revisions; selection
-- identity is revision plus slot, never nickname, species or PID. Every
-- expected failure is decided before the publication window: both
-- preparations are validated and allocated, confirmed current, then
-- published synchronously with no yield, callback, rendering, audio or
-- fallible work between them. Discarding a preparation has no effect.

local HeldItemFormPolicy = require("libs.hgss.src.mons.HeldItemFormPolicy")

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
-- before/after display facts.
---@param request PartyActionRequest
---@return { kind: string, updates: { slot: integer, mon: table<string, unknown> }[]?, deltas: { op: string, item: string, quantity: integer }[]?, before: PartyActionDisplayFacts?, after: PartyActionDisplayFacts? }
function PartyActions:_resolve(request)
  assert(type(request) == "table", "party actions require a request record")
  assert(request.kind == "give" or request.kind == "take", "party action kind must be give or take")
  assert(type(request.slot) == "number" and request.slot % 1 == 0, "party action slot must be an integer")
  if request.partyRevision ~= self._mons:partyRevision() or request.bagRevision ~= self._bag:revision() then
    return { kind = "stale" }
  end
  local mon = self._mons:partyMon(request.slot)
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
---@return { kind: string, slot: integer?, before: PartyActionDisplayFacts?, after: PartyActionDisplayFacts?, partyRevision: integer?, bagRevision: integer? }
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
    before = decision.before,
    after = decision.after,
    partyRevision = self._mons:partyRevision(),
    bagRevision = self._bag:revision(),
  }
end

return PartyActions
