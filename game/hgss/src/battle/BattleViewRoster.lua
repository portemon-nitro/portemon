-- Read-only projections over a battle snapshot's displayed battler
-- records, shared by the paired renderer and the compact interface: the
-- live battlers per side in slot order, every side's claimed native
-- positions, the legacy first-record-per-side singles projection, and the
-- acting battler's name during multi-actor decisions. Positions stay
-- opaque: only their relative order matters, never a hardcoded slot.

---@class BattleViewRoster
local BattleViewRoster = {}

---@param record table<string, unknown> displayed battler facts under projection
---@return boolean true when the record owns a live battlefield slot
local function liveSlot(record)
  -- A faint can hide its picture while the health box finishes sliding
  -- away. Such a record still owns its stable battlefield row.
  return type(record) == "table" and record.active ~= false and (record.visible ~= false or record.hudVisible == true)
end

---@param records table<integer, table<string, unknown>> one side live records under ordering
local function sortBySlot(records)
  -- The combatant identity breaks position ties deterministically.
  table.sort(records, function(a, b)
    local pa, pb = a.position, b.position
    if type(pa) == "number" and type(pb) == "number" and pa ~= pb then
      return pa < pb
    end
    return a.combatant < b.combatant
  end)
end

---@param view table<string, unknown> internal semantic snapshot
---@return table<integer, table<string, unknown>> live player-side battler facts in slot order
---@return table<integer, table<string, unknown>> live enemy-side battler facts in slot order
function BattleViewRoster.liveSides(view)
  local players, enemies = {}, {}
  if type(view.battlers) == "table" then
    for _, battler in ipairs(view.battlers) do
      if liveSlot(battler) then
        if battler.side == 1 then
          players[#players + 1] = battler
        else
          enemies[#enemies + 1] = battler
        end
      end
    end
  end
  sortBySlot(players)
  sortBySlot(enemies)
  return players, enemies
end

-- Canonical side slot order behind stable rows and cells: every distinct
-- native position an active record claims on the side, hidden records
-- included, in slot order. Withdrawal, faint and reveal cues hide and
-- show records without moving slots, so the survivors keep their place
-- while a neighbor transitions instead of reindexing onto its place.
---@param view table<string, unknown> internal semantic snapshot
---@param playerSide boolean true for the near player side, false for the far foe side
---@return integer[] distinct claimed native positions in slot order
function BattleViewRoster.claimedPositions(view, playerSide)
  local seen = {} ---@type table<integer, boolean>
  local order = {} ---@type integer[]
  if type(view.battlers) == "table" then
    for _, battler in ipairs(view.battlers) do
      if
        type(battler) == "table"
        and battler.active ~= false
        and type(battler.position) == "number"
        and (battler.side == 1) == playerSide
        and not seen[
          battler.position --[[@as integer]]
        ]
      then
        seen[
          battler.position --[[@as integer]]
        ] = true
        order[#order + 1] = battler.position --[[@as integer]]
      end
    end
  end
  table.sort(order)
  return order
end

-- Resolves one live battler's stable index in its side's claimed order,
-- so a surviving slot never slides onto a hidden neighbor's place.
-- Records without a claimed native position keep their live-order index.
---@param order integer[] claimed native positions in slot order
---@param battler table<string, unknown> live battler facts under projection
---@param fallback integer live-order index behind position-less records
---@return integer stable index into the side's rows or cells
function BattleViewRoster.claimedIndex(order, battler, fallback)
  local position = battler.position
  if type(position) == "number" then
    for index, slot in ipairs(order) do
      if slot == position then
        return index
      end
    end
  end
  return fallback
end

-- The legacy singles projection: the first record per side in view
-- order, visibility decided by the caller, so single-side geometry never
-- moves with or without native slots.
---@param view table<string, unknown> internal semantic snapshot
---@return table<string, unknown>? first player-side battler facts in view order
---@return table<string, unknown>? first enemy-side battler facts in view order
function BattleViewRoster.firstPerSide(view)
  local player, enemy = nil, nil
  if type(view.battlers) == "table" then
    for _, battler in ipairs(view.battlers) do
      if type(battler) == "table" then
        if battler.side == 1 and player == nil then
          player = battler
        elseif battler.side ~= 1 and enemy == nil then
          enemy = battler
        end
      end
    end
  end
  return player, enemy
end

---@param view table<string, unknown> internal semantic snapshot
---@return string? acting battler display name, nil outside multi-actor decisions
function BattleViewRoster.actingName(view)
  local actor = view.actor --[[@as table<string, unknown>?]]
  if type(actor) ~= "table" or type(actor.total) ~= "number" or actor.total <= 1 then
    return nil
  end
  if type(view.battlers) == "table" then
    for _, battler in ipairs(view.battlers) do
      if
        type(battler) == "table"
        and battler.combatant == actor.combatant
        and type(battler.name) == "string"
        and battler.name ~= ""
      then
        return battler.name --[[@as string]]
      end
    end
  end
  return nil
end

return BattleViewRoster
