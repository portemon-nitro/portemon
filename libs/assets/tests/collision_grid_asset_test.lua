-- Tests for CollisionGridAsset: the project-owned G4CL collision binary format.
-- encode/decode round trip, exact dimensions, blocked semantics, behavior and
-- terrain-response ids, and rejection of malformed magic/version/size/boolean
-- bytes. No HGSS packing knowledge belongs here or in the engine.

local Assert = require("tests.support.Assert")
local CollisionGridAsset = require("libs.assets.src.field.CollisionGridAsset")

local T = {}

---@param bytes string
---@return { code: string }
local function decodeErr(bytes)
  local grid, err = CollisionGridAsset.decode(bytes)
  Assert.isNil(grid)
  Assert.notNil(err)
  return assert(err)
end

-- A grid of the given dimensions; the block flag at (1,1) is set to `blocked`.
---@param width integer
---@param height integer
---@param blocked boolean
---@return { width: integer, height: integer, cells: table[] }
local function grid(width, height, blocked)
  local cells = {} ---@type table[]
  for index = 1, width * height do
    cells[index] = { behavior = 0, terrainResponseId = 0, blocked = false }
  end
  cells[1 * width + 2] = { behavior = blocked and 3 or 0, terrainResponseId = 6, blocked = blocked }
  return { width = width, height = height, cells = cells }
end

function T.encode_decode_round_trips_an_exact_grid()
  local g = grid(32, 32, true)
  local decoded = assert(CollisionGridAsset.decode(CollisionGridAsset.encode(g)))
  Assert.equal(decoded.width, 32)
  Assert.equal(decoded.height, 32)
  Assert.equal(#decoded.cells, 1024)
  Assert.equal(decoded.cells[1 * 32 + 2].behavior, 3)
  Assert.equal(decoded.cells[1 * 32 + 2].terrainResponseId, 6)
  Assert.isTrue(decoded.cells[1 * 32 + 2].blocked)
  Assert.isFalse(decoded.cells[0 * 32 + 1].blocked)
end

function T.small_grids_keep_exact_dimensions()
  local g = grid(2, 3, false)
  local decoded = assert(CollisionGridAsset.decode(CollisionGridAsset.encode(g)))
  Assert.equal(decoded.width, 2)
  Assert.equal(decoded.height, 3)
  Assert.equal(#decoded.cells, 6)
end

function T.passable_cells_round_trip_as_unblocked()
  local g = grid(4, 4, false)
  local decoded = assert(CollisionGridAsset.decode(CollisionGridAsset.encode(g)))
  Assert.isFalse(decoded.cells[1 * 4 + 2].blocked)
end

-- A structurally valid G4CL asset with the given version/dimensions and zero
-- cells; the caller then corrupts the field under test.
local function asset(version, width, height)
  local cells = string.rep(string.char(0, 0, 0), width * height)
  return "G4CL"
    .. string.char(version % 256, math.floor(version / 256))
    .. string.char(width % 256, math.floor(width / 256))
    .. string.char(height % 256, math.floor(height / 256))
    .. cells
end

function T.rejects_bad_magic()
  Assert.equal(decodeErr("G4CM" .. asset(1, 4, 4):sub(5)).code, "COLLISION_BAD_MAGIC")
end

function T.rejects_unsupported_version()
  Assert.equal(decodeErr(asset(2, 4, 4)).code, "COLLISION_BAD_VERSION")
end

function T.rejects_zero_dimensions()
  Assert.equal(decodeErr(asset(1, 0, 4)).code, "COLLISION_BAD_DIMENSIONS")
  Assert.equal(decodeErr(asset(1, 4, 0)).code, "COLLISION_BAD_DIMENSIONS")
end

function T.rejects_wrong_total_byte_length()
  local g = grid(2, 2, false)
  local bytes = CollisionGridAsset.encode(g)
  Assert.equal(decodeErr(bytes:sub(1, #bytes - 1)).code, "COLLISION_BAD_SIZE")
  Assert.equal(decodeErr(bytes .. "\0").code, "COLLISION_BAD_SIZE")
end

function T.rejects_blocked_bytes_other_than_zero_or_one()
  local bytes = asset(1, 2, 2)
  local corrupted = bytes:sub(1, 10) .. string.char(0, 0, 2) .. bytes:sub(14)
  Assert.equal(decodeErr(corrupted).code, "COLLISION_BAD_BLOCKED")
end

function T.rejects_a_header_shorter_than_the_format_prefix()
  Assert.equal(decodeErr("G4C").code, "COLLISION_BAD_SIZE")
end

-- Runtime collision reads the compact bytes instead of materializing the
-- normalized grid: open() validates the same header/extent/blocked domain and
-- answers single cells from the borrowed source, so a map never retains one
-- table per tile. Parity with decode() is checked over every cell.
function T.open_answers_cells_from_the_borrowed_bytes_without_materializing_cells()
  Assert.equal(
    type(CollisionGridAsset.open),
    "function",
    "runtime collision reading must borrow the compact cell bytes instead of expanding one table per cell"
  )
  local g = grid(32, 32, true)
  local bytes = CollisionGridAsset.encode(g)
  local source = assert(love.data.newByteData(bytes), "the compact collision bytes must be admissible as Data")
  local view = assert(CollisionGridAsset.open(source, { path = "map/collision.g4cl" }))
  Assert.equal(view.width, 32, "the view reports the stored width")
  Assert.equal(view.height, 32, "the view reports the stored height")
  Assert.isNil(view.cells, "a collision view keeps no per-cell table array")
  local blocked = assert(view:cell(1 * 32 + 1), "a view answers a zero-based cell index")
  Assert.equal(blocked.behavior, 3, "the borrowed cell keeps its behavior byte")
  Assert.equal(blocked.terrainResponseId, 6, "the borrowed cell keeps its terrain response byte")
  Assert.isTrue(blocked.blocked, "the borrowed cell keeps its blocked flag")
  Assert.isFalse(view:cell(0).blocked, "a passable cell reads as unblocked")
  for index = 0, 32 * 32 - 1 do
    local cell = view:cell(index)
    local decoded = g.cells[index + 1]
    Assert.equal(cell.behavior, decoded.behavior)
    Assert.equal(cell.terrainResponseId, decoded.terrainResponseId)
    Assert.equal(cell.blocked, decoded.blocked)
  end
end

-- Bounded reading rejects a short or malformed asset before any cell is
-- indexed, with the same format error identities the normalized reader uses.
function T.open_rejects_malformed_compact_bytes_before_reading_cells()
  Assert.equal(type(CollisionGridAsset.open), "function", "runtime collision reading must borrow the compact bytes")
  local bytes = CollisionGridAsset.encode(grid(4, 4, true))
  local short = assert(love.data.newByteData(bytes:sub(1, #bytes - 1)))
  local view, err = CollisionGridAsset.open(short, nil)
  Assert.isNil(view, "a truncated collision asset must not produce a view")
  Assert.equal(assert(err).code, "COLLISION_BAD_SIZE", "a truncated asset reports its exact extent failure")
  local corrupted = bytes:sub(1, 12) .. string.char(2) .. bytes:sub(14)
  local corruptedView, corruptedErr = CollisionGridAsset.open(assert(love.data.newByteData(corrupted)), nil)
  Assert.isNil(corruptedView, "a bad blocked byte must not produce a view")
  Assert.equal(assert(corruptedErr).code, "COLLISION_BAD_BLOCKED", "the blocked-byte domain is validated up front")
end

function T.encode_rejects_malformed_grids()
  Assert.throws(function()
    CollisionGridAsset.encode({ width = 2, height = 2, cells = { { blocked = false } } })
  end)
  Assert.throws(function()
    CollisionGridAsset.encode({ width = 2, height = 2, cells = {} })
  end)
  Assert.throws(function()
    CollisionGridAsset.encode({ width = 0, height = 2, cells = {} })
  end)
  Assert.throws(function()
    local g = grid(1, 1, false) ---@type { width: integer, height: integer, cells: table[] }
    local cell = g.cells[1] ---@type table
    cell.blocked = 1
    CollisionGridAsset.encode(g)
  end)
  Assert.throws(function()
    local g = grid(1, 1, false) ---@type { width: integer, height: integer, cells: table[] }
    local cell = g.cells[1] ---@type table
    cell.behavior = 256
    CollisionGridAsset.encode(g)
  end)
end

return { tests = T }
