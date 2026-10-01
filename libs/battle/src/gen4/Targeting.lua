-- Ordered target policy resolution. A selected target reference resolves
-- to an ordered set of positional targets at the sample point, in
-- ascending slot order: near positions 0 and 2 hold one side, far
-- positions 1 and 3 hold the other. Departed selections retarget through
-- the native policy to the live foe instead of fizzling, redirection owns
-- its own entry point, and spread callers sample the eligible target count
-- from the same ordered set. Positional identity stays separate from
-- activation locks: targets name slots, never combatant entries.

---@class TargetRef
---@field kind string
---@field position integer?

---@class TargetRequest
---@field policy string
---@field user TargetRef?
---@field selected TargetRef?

---@class TargetRedirectRequest
---@field policy string
---@field user TargetRef?
---@field selected TargetRef?
---@field redirectTo TargetRef

---@class TargetResolution
---@field targets TargetRef[]

---@class TargetOccupant
---@field combatant integer
---@field activation integer?
---@field active boolean?

---@class TargetFieldSlot
---@field id integer
---@field side integer
---@field occupant TargetOccupant?

---@class TargetFieldSide
---@field id integer
---@field positions integer[]

---@class TargetField
---@field positions TargetFieldSlot[]
---@field sides TargetFieldSide[]?
local Targeting = {}

Targeting.MIN_POSITION = 0
Targeting.MAX_POSITION = 3

local SELECTION_POLICIES = { selected_foe = true, selected_ally = true }

local KNOWN_POLICIES = {
  user = true,
  selected_foe = true,
  selected_ally = true,
  ally = true,
  both_foes = true,
  all_foes = true,
  all_others = true,
  entire_field = true,
  own_side = true,
  foe_side = true,
  random_foe = true,
}

---@param ref TargetRef reference under test
---@param name string value being read
---@return integer validated slot identity
local function requirePosition(ref, name)
  assert(type(ref) == "table" and ref.kind == "position", name .. " names a positional target")
  assert(
    type(ref.position) == "number"
      and ref.position % 1 == 0
      and ref.position >= Targeting.MIN_POSITION
      and ref.position <= Targeting.MAX_POSITION,
    name .. " names a known field slot"
  )
  assert(ref.position ~= nil, "the range check carries the validated slot")
  return ref.position
end

---@param field TargetField field under test
---@param id integer slot identity under test
---@return TargetFieldSlot? slot holding the identity, or nil when absent
local function slotById(field, id)
  assert(type(field) == "table" and type(field.positions) == "table", "targeting resolves over its field")
  for _, slot in ipairs(field.positions) do
    if slot.id == id then
      return slot
    end
  end
  return nil
end

---@param slot TargetFieldSlot slot under test
---@return boolean whether a live combatant holds the slot
local function isLive(slot)
  return slot.occupant ~= nil and slot.occupant.active ~= false
end

---@param field TargetField field under test
---@param id integer slot identity under test
---@return TargetFieldSlot slot holding the identity
local function requireSlot(field, id)
  local slot = slotById(field, id)
  assert(slot ~= nil, "targeting resolves known field slots")
  assert(slot ~= nil, "the presence check carries the validated slot")
  return slot
end

---@param selection TargetRequest selection under test
local function requireSelection(selection)
  assert(type(selection) == "table", "targeting validates its selection")
  assert(type(selection.policy) == "string" and KNOWN_POLICIES[selection.policy], "targeting names a known policy")
  if SELECTION_POLICIES[selection.policy] then
    assert(type(selection.selected) == "table", "selection policies name their selected target")
    requirePosition(selection.selected, "selected targets")
  end
end

---@param id integer slot identity under test
---@return TargetRef fresh positional reference for the slot
local function ref(id)
  return { kind = "position", position = id }
end

---@param field TargetField field under test
---@return integer[] identities of live slots in ascending slot order
local function liveSlots(field)
  local ids = {}
  for _, slot in ipairs(field.positions) do
    if isLive(slot) then
      ids[#ids + 1] = slot.id
    end
  end
  table.sort(ids)
  return ids
end

---@param field TargetField field under test
---@param side integer side identity under test
---@param exclude integer? slot identity left out of the set
---@return integer[] live slot identities on the side in ascending order
local function liveOnSide(field, side, exclude)
  local ids = {}
  for _, slot in ipairs(field.positions) do
    if slot.side == side and isLive(slot) and slot.id ~= exclude then
      ids[#ids + 1] = slot.id
    end
  end
  table.sort(ids)
  return ids
end

---@param ids integer[] slot identities under test
---@return TargetRef[] fresh positional references in the given order
local function refs(ids)
  local targets = {}
  for _, id in ipairs(ids) do
    targets[#targets + 1] = ref(id)
  end
  return targets
end

---@param selection TargetRequest selection under test
---@return boolean whether live selections validate
function Targeting.validateSelection(selection)
  requireSelection(selection)
  return true
end

---@param request TargetRequest target request under test
---@param field TargetField field sampled at the native point
---@param stream BattleRng? stream drawing the random-target index
---@return TargetResolution ordered target set at the sample point
function Targeting.resolve(request, field, stream)
  requireSelection(request)
  assert(type(field) == "table" and type(field.positions) == "table", "targeting resolves over its field")
  local policy = request.policy

  if policy == "selected_foe" or policy == "selected_ally" then
    assert(request.selected ~= nil, "missing selections never resolve silently")
    local selected = requirePosition(request.selected, "selected targets")
    local slot = requireSlot(field, selected)
    if isLive(slot) then
      return { targets = refs({ selected }) }
    end
    local userId = nil
    if request.user ~= nil then
      userId = requirePosition(request.user, "user")
    end
    return { targets = refs(liveOnSide(field, slot.side, userId)) }
  end

  if policy == "user" then
    assert(request.user ~= nil, "user policies name their user")
    return { targets = refs({ requirePosition(request.user, "user") }) }
  end

  assert(request.user ~= nil, "side policies name their user")
  local userId = requirePosition(request.user, "user")
  local userSlot = requireSlot(field, userId)

  if policy == "ally" then
    return { targets = refs(liveOnSide(field, userSlot.side, userId)) }
  end
  if policy == "own_side" then
    return { targets = refs(liveOnSide(field, userSlot.side, nil)) }
  end
  if policy == "both_foes" or policy == "all_foes" or policy == "foe_side" then
    local ids = {}
    for _, slot in ipairs(field.positions) do
      if slot.side ~= userSlot.side and isLive(slot) then
        ids[#ids + 1] = slot.id
      end
    end
    table.sort(ids)
    return { targets = refs(ids) }
  end
  if policy == "all_others" then
    local ids = {}
    for _, id in ipairs(liveSlots(field)) do
      if id ~= userId then
        ids[#ids + 1] = id
      end
    end
    return { targets = refs(ids) }
  end
  if policy == "entire_field" then
    return { targets = refs(liveSlots(field)) }
  end
  assert(policy == "random_foe", "targeting names a known policy")
  local foes = {}
  for _, slot in ipairs(field.positions) do
    if slot.side ~= userSlot.side and isLive(slot) then
      foes[#foes + 1] = slot.id
    end
  end
  table.sort(foes)
  assert(#foes > 0, "random targets need a live foe")
  if stream ~= nil then
    assert(type(stream.nextU16) == "function", "random targets draw from the battle stream")
    local draw = stream:nextU16("target_roll", { kind = "target_roll" })
    return { targets = refs({ foes[(draw % #foes) + 1] }) }
  end
  return { targets = refs({ foes[1] }) }
end

---@param request TargetRedirectRequest redirect request under test
---@param field TargetField field sampled at the native point
---@return TargetResolution ordered target set owned by redirection
function Targeting.redirect(request, field)
  assert(type(request) == "table", "redirection reads its request")
  assert(type(request.redirectTo) == "table", "redirection names its destination")
  local destination = requirePosition(request.redirectTo, "redirect destinations")
  requireSlot(field, destination)
  return { targets = refs({ destination }) }
end

return Targeting
