-- Staged wild-transition cell-order payload (hgss-wild-cell-grid-orders-v1)
-- shaped like the compiled route data the fallback effect consumes.

local WildCellOrdersFixture = {}

---@return table payload fresh row and diagonal order tables
function WildCellOrdersFixture.payload()
  return {
    rows = { 7, 6, 5, 4, 3, 2, 1, 0, 8, 9, 10, 11, 12, 13, 14, 15, 23, 22, 21, 20, 19, 18, 17, 16 },
    rowsReverse = { 0, 1, 2, 3, 4, 5, 6, 7, 15, 14, 13, 12, 11, 10, 9, 8, 16, 17, 18, 19, 20, 21, 22, 23 },
    diagonalsA = { 0, 2, 9, 16, 4, 11, 18, 25, 32, 6, 13, 20, 27, 34, 41, 15, 22, 29, 36, 43, 31, 38, 45, 47 },
    diagonalsB = { 1, 8, 3, 10, 17, 24, 5, 12, 19, 26, 33, 40, 7, 14, 21, 28, 35, 42, 23, 30, 37, 44, 39, 46 },
  }
end

return WildCellOrdersFixture
