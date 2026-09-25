-- Pure machine-teaching policy: compatibility planning over validated
-- catalog facts. Resolves the taught move through the item and mon
-- catalogs (never an independent number table), notices known moves
-- before compatibility, and plans full base-PP entries with source
-- learning friendship and mood. Returns decisions only: the caller
-- (PartyActions) prepares and publishes through the owning services.
-- Learning friendship adds band 1/1/0 with the held luxury, egg-location
-- and friendship bonuses before clamping to 0..255; mood rises 40 clamped
-- to -127..127, applied before the friendship write. Teaching never
-- queries badges or field position, and replacing an HM move is refused
-- in this machine context while the domain delete primitive keeps its
-- general legality.

local MachineTeaching = {}

-- Source learning companions: the LEARN_TMHM friendship bands with the
-- learning mood delta, applied once per successful machine use.
local LEARN_FRIENDSHIP_BANDS = { lo = 1, med = 1, hi = 0 }
local LEARN_MOOD = 40

---@param mon table<string, unknown>
---@return table<string, unknown> a private copy with its own move entries
local function copyMon(mon)
  local staged = {}
  for key, value in pairs(mon) do
    staged[key] = value
  end
  local moves = assert(mon.moves, "teaching requires the stored moves")
  assert(type(moves) == "table", "teaching requires the stored moves")
  local entries = {}
  for index, entry in ipairs(moves) do
    assert(type(entry) == "table", "stored moves carry entry records")
    entries[index] = {
      move = assert(entry.move, "stored entries name their move"),
      pp = assert(entry.pp, "stored entries carry power points"),
      ppUps = assert(entry.ppUps, "stored entries carry power-point ups"),
    }
  end
  staged.moves = entries
  return staged
end

---@param staged table<string, unknown>
---@param location integer|nil
---@param items table<string, unknown> the item catalog for held friendship boosts
local function applyLearningCompanions(staged, location, items)
  local mood = assert(staged.mood, "teaching requires the stored mood")
  assert(type(mood) == "number" and mood % 1 == 0, "teaching requires the stored mood")
  local adjusted = mood + LEARN_MOOD
  if adjusted > 127 then
    adjusted = 127
  elseif adjusted < -127 then
    adjusted = -127
  end
  staged.mood = adjusted
  local friendship = assert(staged.friendship, "teaching requires the stored friendship")
  assert(type(friendship) == "number" and friendship % 1 == 0, "teaching requires the stored friendship")
  local mod = nil
  if friendship < 100 then
    mod = LEARN_FRIENDSHIP_BANDS.lo
  elseif friendship < 200 then
    mod = LEARN_FRIENDSHIP_BANDS.med
  else
    mod = LEARN_FRIENDSHIP_BANDS.hi
  end
  if friendship == 255 and mod > 0 then
    return
  end
  if friendship == 0 and mod < 0 then
    return
  end
  if mod > 0 then
    if
      staged.origin ~= nil and (staged.origin --[[@as table<string, unknown>]]).ball == "LUXURY_BALL"
    then
      mod = mod + 1
    end
    if
      location ~= nil
      and staged.egg ~= nil
      and (staged.egg --[[@as table<string, unknown>]]).location == location
    then
      mod = mod + 1
    end
    local held = staged.heldItem
    if type(held) == "string" then
      local lookup = items.item
      assert(type(lookup) == "function", "held items resolve through the catalog")
      local definition = lookup(items, held)
      assert(type(definition) == "table", "held items resolve through the catalog")
      if
        (definition --[[@as table<string, unknown>]]).friendshipBoost == true
      then
        mod = math.floor(mod * 150 / 100)
      end
    end
  end
  local total = mod + friendship
  if total > 255 then
    total = 255
  end
  if total < 0 then
    total = 0
  end
  staged.friendship = total
end

---@param request table<string, unknown> { mon, item, replaceSlot?, expectedOldMove? }
---@param catalogs table<string, unknown> { items, mons }
---@param context table<string, unknown> { location? }
---@return { kind: string, reason: string?, move: string?, moveSlot: integer?, mon: table<string, unknown>?, consumption: integer?, feedback: table<string, unknown>? } refusal or candidate
function MachineTeaching.plan(request, catalogs, context)
  assert(type(request) == "table", "teaching requires its request record")
  assert(type(catalogs) == "table", "teaching requires its catalogs")
  assert(type(context) == "table", "teaching requires its context")
  local mon = assert(request.mon, "teaching requires its mon record")
  assert(type(mon) == "table", "teaching requires its mon record")
  local itemKey = assert(request.item, "teaching requires its machine item")
  assert(type(itemKey) == "string", "teaching requires its machine item")
  local items = assert(catalogs.items, "teaching requires the item catalog")
  local monCatalog = assert(catalogs.mons, "teaching requires the mon catalog")
  local definition = items:item(itemKey)
  assert(type(definition) == "table", "teaching resolves its machine definition")
  assert(
    definition.pocket == "tmhm"
      and type(definition.partyUse) == "table"
      and (definition.partyUse --[[@as table<string, unknown>]]).kind == "machine",
    "teaching plans machine items only"
  )
  local moveNative = assert(definition.tmhmMoveNativeId, "machine records name their move")
  assert(type(moveNative) == "number", "machine records name their move")
  local moveKey = monCatalog:moveKeyByNativeId(moveNative)
  if mon.isEgg == true then
    return { kind = "incompatible", reason = "egg" }
  end
  local moves = assert(mon.moves, "teaching requires the stored moves")
  assert(type(moves) == "table", "teaching requires the stored moves")
  assert(#moves <= 4, "teaching plans four slots at most")
  for _, entry in ipairs(moves) do
    assert(type(entry) == "table", "stored moves carry entry records")
    if entry.move == moveKey then
      return { kind = "known" }
    end
  end
  local species = assert(mon.species, "teaching requires the stored species")
  assert(type(species) == "string", "teaching requires the stored species")
  local form = assert(mon.form, "teaching requires the stored form")
  assert(type(form) == "number", "teaching requires the stored form")
  local compatible = false
  for _, allowed in ipairs(assert(monCatalog:form(species, form).tmhm, "forms carry machine lists")) do
    if allowed == moveKey then
      compatible = true
      break
    end
  end
  if not compatible then
    return { kind = "incompatible", reason = "form" }
  end
  local moveSlot = #moves
  if #moves == 4 then
    if request.replaceSlot == nil then
      return { kind = "needs_replacement", move = moveKey }
    end
    assert(type(request.replaceSlot) == "number" and request.replaceSlot % 1 == 0, "teaching replaces an integer slot")
    assert(request.replaceSlot >= 0 and request.replaceSlot <= 3, "teaching replaces a learned slot")
    moveSlot = request.replaceSlot
    local current = assert(moves[moveSlot + 1], "a full set carries the replaced entry")
    assert(type(current) == "table", "stored moves carry entry records")
    local currentNative = assert(monCatalog:move(assert(current.move, "entries name their move")).nativeId)
    assert(type(currentNative) == "number", "catalog moves carry native identities")
    if items:hmMoveNativeIds()[currentNative] == true then
      return { kind = "protected", move = moveKey, moveSlot = moveSlot }
    end
    if request.expectedOldMove ~= nil and request.expectedOldMove ~= current.move then
      return { kind = "stale" }
    end
  end
  local basePp = assert(monCatalog:move(moveKey).basePp, "catalog moves carry base power points")
  assert(type(basePp) == "number", "catalog moves carry base power points")
  local staged = copyMon(mon)
  staged.moves[moveSlot + 1] = { move = moveKey, pp = basePp, ppUps = 0 }
  local location = context.location
  assert(location == nil or type(location) == "number", "teaching locations arrive as integers")
  applyLearningCompanions(staged, location --[[@as integer|nil]], items)
  local consumption = 0
  if definition.isHm ~= true then
    consumption = 1
  end
  return {
    kind = "candidate",
    move = moveKey,
    moveSlot = moveSlot,
    mon = staged,
    consumption = consumption,
    feedback = { textKey = "learned", bindings = { move = moveKey } },
  }
end

return MachineTeaching
