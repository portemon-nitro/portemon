-- Validates and publishes source-shaped PC operations against the live
-- mon and Bag owners. Preview records are value-only and revision-bound.

local HeldItemFormPolicy = require("libs.hgss.src.mons.HeldItemFormPolicy")

---@class PcStorageActions
---@field _mons HgssMonService
---@field _bag HgssBagService
local PcStorageActions = {}
PcStorageActions.__index = PcStorageActions

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = copy(child)
  end
  return result
end

local function sameAddress(left, right)
  return left.kind == right.kind
    and (
      left.kind == "party" and left.slot == right.slot
      or left.kind == "box" and left.box == right.box and left.slot == right.slot
    )
end

function PcStorageActions.new(options)
  assert(type(options) == "table", "Storage actions require owners")
  assert(options.mons ~= nil and options.bag ~= nil, "Storage actions borrow mon and Bag services")
  return setmetatable({ _mons = options.mons, _bag = options.bag }, PcStorageActions)
end

function PcStorageActions:_validateAddress(address, requireOccupied)
  assert(type(address) == "table", "mon addresses are records")
  if address.kind == "party" then
    assert(type(address.slot) == "number" and address.slot % 1 == 0, "party addresses have integer slots")
    local upper = self._mons:partyCount() - (requireOccupied == false and 0 or 1)
    assert(address.slot >= 0 and address.slot <= upper, "party address is occupied or the next insertion slot")
  else
    assert(address.kind == "box", "mon addresses identify party or box custody")
    assert(type(address.box) == "number" and address.box % 1 == 0, "box addresses have integer boxes")
    assert(type(address.slot) == "number" and address.slot % 1 == 0, "box addresses have integer slots")
    assert(address.box >= 0 and address.box < self._mons:boxCount(), "box address is in range")
    assert(address.slot >= 0 and address.slot < 30, "box addresses have thirty slots")
  end
end

function PcStorageActions:_read(address)
  self:_validateAddress(address)
  if address.kind == "party" then
    return self._mons:partyMon(address.slot)
  end
  return self._mons:boxMon(address.box, address.slot)
end

function PcStorageActions:_expectations()
  return {
    partyRevision = self._mons:partyRevision(),
    boxRevision = self._mons:boxRevision(),
    bagRevision = self._bag:revision(),
  }
end

local function refusal(reason)
  return { kind = "refused", reason = reason, message = reason }
end

local function hasMail(mon)
  return type(mon.mail) == "table" and next(mon.mail) ~= nil
end

local function hasCapsule(mon)
  local capsule = mon.capsule
  return type(capsule) == "table" and (capsule.id ~= 0 or #capsule.seals > 0)
end

function PcStorageActions:_firstProtectedMove(mon)
  for _, entry in ipairs(mon.moves) do
    local definition = self._mons:catalog():move(entry.move)
    local id = definition.nativeId
    if id == 57 or id == 431 or id == 127 or id == 19 then
      return entry.move
    end
  end
  return nil
end

function PcStorageActions:_hasOtherMove(target, moveKey)
  for slot = 0, self._mons:partyCount() - 1 do
    local address = { kind = "party", slot = slot }
    if not sameAddress(address, target) then
      for _, entry in ipairs(self._mons:partyMon(slot).moves) do
        if entry.move == moveKey then
          return true
        end
      end
    end
  end
  for box = 0, self._mons:boxCount() - 1 do
    for slot = 0, 29 do
      local address = { kind = "box", box = box, slot = slot }
      if not sameAddress(address, target) then
        local mon = self._mons:boxMon(box, slot)
        if mon ~= nil then
          for _, entry in ipairs(mon.moves) do
            if entry.move == moveKey then
              return true
            end
          end
        end
      end
    end
  end
  return false
end

function PcStorageActions:_isMail(itemKey)
  return itemKey ~= "NONE" and self._bag:catalog():item(itemKey).pocket == "mail"
end

function PcStorageActions:_isGriseous(itemKey)
  return itemKey ~= "NONE" and self._bag:catalog():item(itemKey).heldFormEffect == "griseous_orb"
end

function PcStorageActions:_normalizeBox(mon)
  local normalized = copy(mon)
  normalized.condition.currentHp = self._mons:derive(normalized).maxHp
  for _, move in ipairs(normalized.moves) do
    local definition = self._mons:catalog():move(move.move)
    move.pp = definition.basePp + math.floor(definition.basePp * move.ppUps / 5)
  end
  if normalized.species == "SHAYMIN" then
    normalized.form = 0
  end
  return normalized
end

function PcStorageActions:_normalizeParty(mon)
  local normalized = copy(mon)
  normalized.condition.status = 0
  normalized.condition.currentHp = self._mons:derive(normalized).maxHp
  return normalized
end

function PcStorageActions:_lastUsableAfterRemoving(address)
  local usable = false
  for slot = 0, self._mons:partyCount() - 1 do
    if not (address.kind == "party" and address.slot == slot) then
      local mon = self._mons:partyMon(slot)
      if not mon.isEgg and mon.condition.currentHp > 0 then
        usable = true
      end
    end
  end
  return usable
end

function PcStorageActions:preview(request)
  assert(type(request) == "table", "Storage action requests are records")
  local expected = self:_expectations()
  local normalized = copy(request)
  local decision = { kind = "allowed", expected = expected, request = normalized }

  if request.kind == "deposit" or request.kind == "withdraw" or request.kind == "move" or request.kind == "swap" then
    self:_validateAddress(assert(request.source, "custody actions have a source"))
    local source = self:_read(request.source)
    if source == nil then
      return refusal("empty_source")
    end
    normalized.sourceMon = source
    local destination = nil
    if request.destination ~= nil then
      self:_validateAddress(request.destination, false)
      if request.destination.kind ~= "party" or request.destination.slot < self._mons:partyCount() then
        destination = self:_read(request.destination)
      end
      normalized.destinationMon = destination
      if request.kind ~= "swap" and destination ~= nil then
        return refusal("occupied_destination")
      end
      if request.kind == "swap" and destination == nil then
        return refusal("empty_destination")
      end
    end
    local partyExitAddress, partyExitMon, incomingPartyMon
    if request.kind == "deposit" then
      assert(
        request.source.kind == "party" and request.destination.kind == "box",
        "deposit moves party custody into a box"
      )
      partyExitAddress, partyExitMon = request.source, source
    elseif request.kind == "move" and request.source.kind == "party" and request.destination.kind == "box" then
      partyExitAddress, partyExitMon = request.source, source
    elseif request.kind == "swap" and request.source.kind ~= request.destination.kind then
      if request.source.kind == "party" then
        partyExitAddress, partyExitMon, incomingPartyMon = request.source, source, destination
      else
        partyExitAddress, partyExitMon, incomingPartyMon = request.destination, destination, source
      end
    end

    if request.kind == "withdraw" then
      assert(
        request.source.kind == "box" and request.destination.kind == "party",
        "withdraw moves box custody into the party"
      )
      if self._mons:partyCount() >= 6 then
        return refusal("party_full")
      end
    end
    if partyExitAddress ~= nil then
      if hasMail(partyExitMon) then
        return refusal("mail_attached")
      end
      if hasCapsule(partyExitMon) then
        return refusal("capsule_attached")
      end
      local partyRemainsUsable = self:_lastUsableAfterRemoving(partyExitAddress)
      if incomingPartyMon ~= nil and not incomingPartyMon.isEgg and incomingPartyMon.condition.currentHp > 0 then
        partyRemainsUsable = true
      end
      if not partyRemainsUsable then
        return refusal("last_usable")
      end
    end
  elseif request.kind == "release" then
    self:_validateAddress(assert(request.source, "release has a source"))
    local mon = self:_read(request.source)
    if mon == nil then
      return refusal("empty_source")
    end
    if mon.isEgg then
      return refusal("egg")
    end
    if hasMail(mon) then
      return refusal("mail_attached")
    end
    if hasCapsule(mon) then
      return refusal("capsule_attached")
    end
    if request.source.kind == "party" and not self:_lastUsableAfterRemoving(request.source) then
      return refusal("last_usable")
    end
    local protected = self:_firstProtectedMove(mon)
    if protected ~= nil and not self:_hasOtherMove(request.source, protected) then
      decision.kind = "refused"
      decision.reason = "hm_return"
      decision.message = "hm_return"
      decision.returnMove = protected
      decision.outcome = "returned"
      return decision
    end
    decision.kind = "confirm"
    decision.returnMove = protected
    decision.outcome = "removed"
    return decision
  elseif request.kind == "takeItem" or request.kind == "giveItem" then
    self:_validateAddress(assert(request.source, "held-item actions have a source"))
    local mon = self:_read(request.source)
    if mon == nil then
      return refusal("empty_source")
    end
    normalized.sourceMon = mon
    if request.kind == "takeItem" then
      if mon.heldItem == "NONE" then
        return refusal("no_item")
      end
      if self:_isMail(mon.heldItem) then
        return refusal("mail")
      end
      if not self._bag:hasSpace(mon.heldItem, 1) then
        return refusal("bag_full")
      end
      normalized.item = mon.heldItem
    else
      assert(type(request.item) == "string", "giving names a semantic item")
      local item = self._bag:catalog():item(request.item)
      if item.pocket == "mail" then
        return refusal("mail")
      end
      if mon.isEgg then
        return refusal("egg")
      end
      if not item.canHold then
        return refusal("cannot_hold")
      end
      if self:_isGriseous(request.item) and mon.species ~= HeldItemFormPolicy.GIRATINA then
        return refusal("griseous_orb")
      end
      if not self._bag:has(request.item, 1) then
        return refusal("item_missing")
      end
      if mon.heldItem ~= "NONE" and not request.confirmed then
        decision.kind = "confirm"
      end
    end
    return decision
  elseif request.kind == "swapItems" then
    decision.expected.bagRevision = nil
    self:_validateAddress(assert(request.source, "item swaps have a source"))
    self:_validateAddress(assert(request.destination, "item swaps have a destination"))
    assert(not sameAddress(request.source, request.destination), "item swaps use distinct mon addresses")
    local source, destination = self:_read(request.source), self:_read(request.destination)
    if source == nil or destination == nil then
      return refusal("empty_source")
    end
    normalized.sourceMon, normalized.destinationMon = source, destination
    for _, pair in ipairs({ { source, destination.heldItem }, { destination, source.heldItem } }) do
      local mon, incoming = pair[1], pair[2]
      if incoming ~= "NONE" then
        if mon.isEgg then
          return refusal("egg")
        end
        if self:_isMail(incoming) then
          return refusal("mail")
        end
        if not self._bag:catalog():item(incoming).canHold then
          return refusal("cannot_hold")
        end
        if self:_isGriseous(incoming) and mon.species ~= HeldItemFormPolicy.GIRATINA then
          return refusal("griseous_orb")
        end
      end
    end
  elseif request.kind == "markings" then
    self:_validateAddress(assert(request.source, "markings have a source"))
    local mon = self:_read(request.source)
    if mon == nil then
      return refusal("empty_source")
    end
    assert(
      type(request.mask) == "number" and request.mask % 1 == 0 and request.mask >= 0 and request.mask < 64,
      "markings are six bits"
    )
    normalized.sourceMon = mon
  elseif request.kind == "boxName" or request.kind == "wallpaper" then
    assert(
      type(request.box) == "number"
        and request.box % 1 == 0
        and request.box >= 0
        and request.box < self._mons:boxCount(),
      "box metadata names a valid box"
    )
    if request.kind == "boxName" then
      assert(type(request.name) == "string", "box names are text")
    end
    if request.kind == "wallpaper" then
      assert(type(request.wallpaperId) == "number", "wallpaper selection is numeric")
    end
  elseif request.kind == "activeBox" then
    assert(
      type(request.box) == "number"
        and request.box % 1 == 0
        and request.box >= 0
        and request.box < self._mons:boxCount(),
      "active box is in range"
    )
  else
    assert(false, "unknown Storage action " .. tostring(request.kind))
  end
  return decision
end

function PcStorageActions:commit(intent, confirmation)
  assert(type(intent) == "table", "Storage commits use a preview intent")
  if intent.kind == "refused" then
    return intent
  end
  assert(type(intent.request) == "table", "Storage commit-capable intents carry a preview request")
  local expected = intent.expected
  if
    expected.partyRevision ~= self._mons:partyRevision()
    or expected.boxRevision ~= self._mons:boxRevision()
    or (expected.bagRevision ~= nil and expected.bagRevision ~= self._bag:revision())
  then
    return { kind = "stale", reason = "stale" }
  end
  if intent.kind == "confirm" and confirmation ~= true then
    return { kind = "refused", reason = "confirmation_required" }
  end

  local request = intent.request
  local party, boxUpdates, metadata, activeBox, deltas = nil, {}, {}, nil, {}
  local function partyRoster()
    local roster = {}
    for slot = 0, self._mons:partyCount() - 1 do
      roster[#roster + 1] = self._mons:partyMon(slot)
    end
    return roster
  end
  local function clearParty(roster, slot)
    table.remove(roster, slot + 1)
  end
  local function setParty(roster, slot, mon)
    roster[slot + 1] = mon
  end

  if request.kind == "deposit" or request.kind == "withdraw" or request.kind == "move" or request.kind == "swap" then
    local source, destination = request.sourceMon, request.destinationMon
    if request.kind == "deposit" or request.kind == "withdraw" or request.kind == "move" then
      local mon = source
      if request.source.kind == "party" and request.destination.kind == "box" then
        mon = self:_normalizeBox(mon)
      elseif request.source.kind == "box" and request.destination.kind == "party" then
        mon = self:_normalizeParty(mon)
      end
      if request.source.kind == "party" then
        party = partyRoster()
        clearParty(party, request.source.slot)
      else
        boxUpdates[#boxUpdates + 1] = { box = request.source.box, slot = request.source.slot, mon = false }
      end
      if request.destination.kind == "party" then
        party = party or partyRoster()
        local slot = request.destination.slot or #party
        if slot == #party then
          party[#party + 1] = mon
        else
          setParty(party, slot, mon)
        end
      else
        boxUpdates[#boxUpdates + 1] = { box = request.destination.box, slot = request.destination.slot, mon = mon }
      end
    else
      local sourceMon, destinationMon = source, destination
      if request.source.kind == "party" and request.destination.kind == "box" then
        sourceMon = self:_normalizeBox(sourceMon)
        destinationMon = self:_normalizeParty(destinationMon)
      elseif request.source.kind == "box" and request.destination.kind == "party" then
        sourceMon = self:_normalizeParty(sourceMon)
        destinationMon = self:_normalizeBox(destinationMon)
      end
      if request.source.kind == "party" or request.destination.kind == "party" then
        party = partyRoster()
        if request.source.kind == "party" then
          setParty(party, request.source.slot, destinationMon)
        else
          setParty(party, request.destination.slot, sourceMon)
        end
      end
      if request.source.kind == "box" then
        boxUpdates[#boxUpdates + 1] = {
          box = request.source.box,
          slot = request.source.slot,
          mon = destinationMon,
        }
      end
      if request.destination.kind == "box" then
        boxUpdates[#boxUpdates + 1] = {
          box = request.destination.box,
          slot = request.destination.slot,
          mon = sourceMon,
        }
      end
    end
  elseif request.kind == "release" then
    if request.source.kind == "party" then
      party = partyRoster()
      clearParty(party, request.source.slot)
    else
      boxUpdates[#boxUpdates + 1] = { box = request.source.box, slot = request.source.slot, mon = false }
    end
  elseif request.kind == "takeItem" or request.kind == "giveItem" then
    local mon = request.sourceMon
    local itemKey = request.kind == "takeItem" and mon.heldItem or request.item
    local item = self._bag:catalog():item(itemKey)
    local updated =
      HeldItemFormPolicy.apply(mon, request.kind == "takeItem" and self._bag:catalog():item("NONE") or item, self._mons)
    if request.kind == "takeItem" then
      updated.heldItem = "NONE"
      deltas = { { op = "add", item = itemKey, quantity = 1 } }
    else
      if mon.heldItem ~= "NONE" then
        deltas[#deltas + 1] = { op = "add", item = mon.heldItem, quantity = 1 }
      end
      deltas[#deltas + 1] = { op = "take", item = itemKey, quantity = 1 }
      updated.heldItem = itemKey
    end
    party = request.source.kind == "party" and partyRoster() or nil
    if party ~= nil then
      setParty(party, request.source.slot, updated)
    else
      boxUpdates[#boxUpdates + 1] = { box = request.source.box, slot = request.source.slot, mon = updated }
    end
  elseif request.kind == "swapItems" then
    local source, destination = request.sourceMon, request.destinationMon
    local sourceItem = source.heldItem
    local destinationItem = destination.heldItem
    local updatedSource = HeldItemFormPolicy.apply(source, self._bag:catalog():item(destinationItem), self._mons)
    local updatedDestination = HeldItemFormPolicy.apply(destination, self._bag:catalog():item(sourceItem), self._mons)
    updatedSource.heldItem, updatedDestination.heldItem = destinationItem, sourceItem
    if request.source.kind == "party" or request.destination.kind == "party" then
      party = partyRoster()
      if request.source.kind == "party" then
        setParty(party, request.source.slot, updatedSource)
      end
      if request.destination.kind == "party" then
        setParty(party, request.destination.slot, updatedDestination)
      end
    end
    if request.source.kind == "box" then
      boxUpdates[#boxUpdates + 1] = {
        box = request.source.box,
        slot = request.source.slot,
        mon = updatedSource,
      }
    end
    if request.destination.kind == "box" then
      boxUpdates[#boxUpdates + 1] = {
        box = request.destination.box,
        slot = request.destination.slot,
        mon = updatedDestination,
      }
    end
  elseif request.kind == "markings" then
    local mon = copy(request.sourceMon)
    mon.markings = request.mask
    if request.source.kind == "party" then
      party = partyRoster()
      setParty(party, request.source.slot, mon)
    else
      boxUpdates[#boxUpdates + 1] = { box = request.source.box, slot = request.source.slot, mon = mon }
    end
  elseif request.kind == "boxName" then
    metadata = { { box = request.box, name = request.name } }
  elseif request.kind == "wallpaper" then
    metadata = { { box = request.box, wallpaperId = request.wallpaperId } }
  elseif request.kind == "activeBox" then
    activeBox = request.box
  end

  local bagPreparation
  if #deltas > 0 then
    local reason
    bagPreparation, reason = self._bag:prepareInventoryChanges(expected.bagRevision, deltas)
    if bagPreparation == nil then
      return { kind = reason == "stale" and "stale" or "refused", reason = reason }
    end
  end
  local monPreparation, reason = self._mons:preparePcChanges(expected, {
    party = party,
    boxUpdates = boxUpdates,
    metadata = metadata,
    activeBox = activeBox,
  })
  if monPreparation == nil then
    return { kind = reason == "stale" and "stale" or "refused", reason = reason }
  end
  if not monPreparation.isCurrent() or (bagPreparation ~= nil and not bagPreparation.isCurrent()) then
    return { kind = "stale", reason = "stale" }
  end
  monPreparation.publish()
  if bagPreparation ~= nil then
    bagPreparation.publish()
  end
  return {
    kind = monPreparation.changed and "changed" or "unchanged",
    partyChanged = party ~= nil,
    boxChanged = #boxUpdates > 0 or #metadata > 0 or activeBox ~= nil,
  }
end

return PcStorageActions
