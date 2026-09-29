-- Initial moveset replay. Canonical source: pret/pokeheartgold,
-- src/pokemon.c (InitBoxMonMoveset, TryAppendBoxMonMove,
-- DeleteBoxMonFirstMoveAndAppend). Eligible learnset entries at or below the
-- current level are considered in source order: a move already present is
-- skipped without shifting, a new move is appended, and appending past four
-- moves drops the oldest. Current power points start at the move's base
-- value with no power-point ups.

local Stats = require("libs.mons.src.gen4.Stats")

---@class Moves
local Moves = {}

Moves.MAX_SLOTS = 4
Moves.MAX_PP_UPS = 3

---@param learnset { level: integer, move: string }[]
---@param level integer
---@param catalog MonCatalog
---@return { move: string, pp: integer, ppUps: integer }[]
function Moves.initial(learnset, level, catalog)
  assert(type(learnset) == "table", "learnset must be a table")
  assert(
    type(level) == "number" and level % 1 == 0 and level >= 1 and level <= Stats.MAX_LEVEL,
    "level must be an integer in 1.." .. Stats.MAX_LEVEL
  )
  assert(catalog ~= nil, "moves need a catalog for base power points")
  local moves = {}
  local known = {}
  for _, entry in ipairs(learnset) do
    if entry.level > level then
      break
    end
    if not known[entry.move] then
      known[entry.move] = true
      local definition = catalog:move(entry.move)
      moves[#moves + 1] = { move = entry.move, pp = definition.basePp, ppUps = 0 }
      if #moves > Moves.MAX_SLOTS then
        local dropped = table.remove(moves, 1)
        known[dropped.move] = nil
      end
    end
  end
  return moves
end

return Moves
