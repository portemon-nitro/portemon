-- Pure render-queue builder. Traverses ordered scene parts (map, building,
-- neighbour, and actor), and partitions their draw items into opaque / cutout /
-- mixedOpaque / wireframe passes, and blended translucent/mixed-translucent
-- entries. Source order is preserved for opaque/cutout/mixedOpaque/wireframe.
-- Blended draws sort by an approximation of the DS GX_SORTMODE_AUTO automatic
-- ordering: ascending bottom screen-space Y, then ascending top screen-space
-- Y, then original submission position. Screen Y is top-down normalized
-- (0 is the top of the screen), computed from the actual draw-item geometry
-- and the current camera matrices -- never a world/view-space Y or a
-- projected center alone. The item's traversal position across ordered parts
-- is the deterministic tie-breaker for equal-extent blended draws, so the
-- queue never invents cross-group ordering. This is an explicit approximation
-- of DS auto sorting, not a claim of exact hardware ordering: the DS sorts
-- individual clipped polygons, whereas this queue sorts whole draw batches.
-- Pure domain module: no love, arithmetic only.
--
-- Queue construction validates its input contract and never mutates the
-- caller's draw records: only the five known alpha classes are accepted
-- (anything else -- including a missing class -- fails loudly instead of
-- defaulting to opaque). Mixed items appear in mixedOpaque AND in blended
-- with fragmentPass="mixed"; blended contains queue-owned wrapper records
-- {item, fragmentPass} that reference the original items. Translucent
-- items appear only in blended with fragmentPass="translucent". Blended
-- depth/source-order keys live in reusable key storage owned by the scratch;
-- the visible blended array is filled with stable wrapper references after
-- sorting a reusable integer order array, so warmed builds allocate nothing.
-- The returned queue holds original items in
-- opaque/cutout/mixedOpaque/wireframe; blended holds wrapper records.

local ffi = require("ffi")

local Errors = require("libs.errors.src.Errors")
local Matrix4 = require("libs.math.src.Matrix4")
local AlphaClassifier = require("libs.nds.src.gx.AlphaClassifier")

ffi.cdef([[
typedef struct {
  double bottomY;
  double topY;
  int32_t position;
  int32_t entryIndex;
} G4RenderSortKey;
]])

local RenderQueue = {}
local RENDER_QUEUE_UNKNOWN_ALPHA_CLASS = "RENDER_QUEUE_UNKNOWN_ALPHA_CLASS"

local INITIAL_SORT_CAPACITY = 16

-- The item's renderer-facing alpha class selects the pass directly in
-- buildInto below; no separate membership lookup precedes the branch.
-- Queue classification is the authority for the pass an item lands in;
-- the renderer receives that selected class when drawing it.

-- The projection a draw item renders through, mirroring the NDS renderer's
-- own selection: billboard-flagged and field-effect items draw through the
-- camera's field-billboard projection, everything else through the world
-- projection.
---@param item table<string, unknown>
---@param worldProjection number[]
---@param billboardProjection number[]
---@return number[]
local function projectionForItem(item, worldProjection, billboardProjection)
  if item.billboardProjection == true or item.fieldEffect ~= nil then
    return billboardProjection
  end
  return worldProjection
end

-- Project one view-space point through a projection matrix into top-down
-- normalized screen Y (0 is the top of the screen). Returns nil when the
-- point is on or behind the near plane, or when the quotient is non-finite:
-- callers fall back to coarser placement rather than producing NaN/Infinity
-- sort keys.
---@param projection number[]
---@param viewX number
---@param viewY number
---@param viewZ number
---@return number?
local function screenY(projection, viewX, viewY, viewZ)
  local clipY = projection[2] * viewX + projection[6] * viewY + projection[10] * viewZ + projection[14]
  local clipW = projection[4] * viewX + projection[8] * viewY + projection[12] * viewZ + projection[16]
  if not (clipW > 0) or clipW == math.huge then
    return nil
  end
  if clipY ~= clipY or clipY == math.huge or clipY == -math.huge then
    return nil
  end
  local y = 0.5 * (1.0 - clipY / clipW)
  if y ~= y or y == math.huge or y == -math.huge then
    return nil
  end
  return y
end

-- Project the eight corners of a model-space AABB under an ordinary world
-- transform into top-down screen-Y extents. The item transform is fused
-- through view and projection once per item -- only the clip Y/W rows of
-- the fused matrix are ever read, so every corner then costs one clip
-- quotient instead of three full point transforms. Returns the bottom
-- (largest) and top (smallest) screen Y, or nil when any corner is
-- unprojectable: a partially clipped box never contributes mirrored garbage
-- keys. Allocates nothing: the fused rows and every corner flow through
-- scalar locals.
---@param bounds { minX: number, maxX: number, minY: number, maxY: number, minZ: number, maxZ: number }
---@param transform number[]
---@param viewMatrix number[]
---@param projection number[]
---@return number? bottomY
---@return number? topY
local function worldBoundsScreenY(bounds, transform, viewMatrix, projection)
  -- Rows 2 and 4 of (projection * viewMatrix), the only rows the screen-Y
  -- quotient below ever reads. Column-major: element (row, col) of A * B
  -- is the dot of A's row against B's column.
  local m21 = projection[2] * viewMatrix[1]
    + projection[6] * viewMatrix[2]
    + projection[10] * viewMatrix[3]
    + projection[14] * viewMatrix[4]
  local m22 = projection[2] * viewMatrix[5]
    + projection[6] * viewMatrix[6]
    + projection[10] * viewMatrix[7]
    + projection[14] * viewMatrix[8]
  local m23 = projection[2] * viewMatrix[9]
    + projection[6] * viewMatrix[10]
    + projection[10] * viewMatrix[11]
    + projection[14] * viewMatrix[12]
  local m24 = projection[2] * viewMatrix[13]
    + projection[6] * viewMatrix[14]
    + projection[10] * viewMatrix[15]
    + projection[14] * viewMatrix[16]
  local m41 = projection[4] * viewMatrix[1]
    + projection[8] * viewMatrix[2]
    + projection[12] * viewMatrix[3]
    + projection[16] * viewMatrix[4]
  local m42 = projection[4] * viewMatrix[5]
    + projection[8] * viewMatrix[6]
    + projection[12] * viewMatrix[7]
    + projection[16] * viewMatrix[8]
  local m43 = projection[4] * viewMatrix[9]
    + projection[8] * viewMatrix[10]
    + projection[12] * viewMatrix[11]
    + projection[16] * viewMatrix[12]
  local m44 = projection[4] * viewMatrix[13]
    + projection[8] * viewMatrix[14]
    + projection[12] * viewMatrix[15]
    + projection[16] * viewMatrix[16]
  -- Fold the item transform through: rows 2 and 4 of the fused matrix.
  local n21 = m21 * transform[1] + m22 * transform[2] + m23 * transform[3] + m24 * transform[4]
  local n22 = m21 * transform[5] + m22 * transform[6] + m23 * transform[7] + m24 * transform[8]
  local n23 = m21 * transform[9] + m22 * transform[10] + m23 * transform[11] + m24 * transform[12]
  local n24 = m21 * transform[13] + m22 * transform[14] + m23 * transform[15] + m24 * transform[16]
  local n41 = m41 * transform[1] + m42 * transform[2] + m43 * transform[3] + m44 * transform[4]
  local n42 = m41 * transform[5] + m42 * transform[6] + m43 * transform[7] + m44 * transform[8]
  local n43 = m41 * transform[9] + m42 * transform[10] + m43 * transform[11] + m44 * transform[12]
  local n44 = m41 * transform[13] + m42 * transform[14] + m43 * transform[15] + m44 * transform[16]
  local lowY, highY = math.huge, -math.huge
  for ix = 0, 1 do
    local cornerX = ix == 0 and bounds.minX or bounds.maxX
    for iy = 0, 1 do
      local cornerY = iy == 0 and bounds.minY or bounds.maxY
      for iz = 0, 1 do
        local cornerZ = iz == 0 and bounds.minZ or bounds.maxZ
        local clipY = n21 * cornerX + n22 * cornerY + n23 * cornerZ + n24
        local clipW = n41 * cornerX + n42 * cornerY + n43 * cornerZ + n44
        if not (clipW > 0) or clipW == math.huge then
          return nil
        end
        if clipY ~= clipY or clipY == math.huge or clipY == -math.huge then
          return nil
        end
        local y = 0.5 * (1.0 - clipY / clipW)
        if y ~= y or y == math.huge or y == -math.huge then
          return nil
        end
        if y < lowY then
          lowY = y
        end
        if y > highY then
          highY = y
        end
      end
    end
  end
  return highY, lowY
end

-- Project the eight corners of a billboard-local AABB through the same
-- camera-facing placement the renderer draws: the billboard center into view
-- space, plus each corner scaled by the billboard axes. Mirrors the vertex
-- bound the map shader bends (viewCenter + vertex * billboardScale) under
-- the item's selected projection. Returns bottom/top screen Y, or nil when
-- any corner is unprojectable. Allocates nothing.
---@param item table<string, unknown>
---@param bounds { minX: number, maxX: number, minY: number, maxY: number, minZ: number, maxZ: number }
---@param viewMatrix number[]
---@param projection number[]
---@return number? bottomY
---@return number? topY
local function billboardBoundsScreenY(item, bounds, viewMatrix, projection)
  local billboardCenter = assert(item.billboardCenter, "billboard item requires billboardCenter")
  local billboardScale = assert(item.billboardScale, "billboard item requires billboardScale")
  local centerX, centerY, centerZ =
    Matrix4.transformPoint(viewMatrix, billboardCenter[1], billboardCenter[2], billboardCenter[3])
  local lowY, highY = math.huge, -math.huge
  for ix = 0, 1 do
    local cornerX = ix == 0 and bounds.minX or bounds.maxX
    for iy = 0, 1 do
      local cornerY = iy == 0 and bounds.minY or bounds.maxY
      for iz = 0, 1 do
        local cornerZ = iz == 0 and bounds.minZ or bounds.maxZ
        local y = screenY(
          projection,
          centerX + cornerX * billboardScale[1],
          centerY + cornerY * billboardScale[2],
          centerZ + cornerZ * billboardScale[3]
        )
        if y == nil then
          return nil
        end
        if y < lowY then
          lowY = y
        end
        if y > highY then
          highY = y
        end
      end
    end
  end
  return highY, lowY
end

-- Project the item's model-space center through its live placement: an
-- ordinary world transform, or the camera-facing billboard placement when
-- the item carries one. Returns nil when the center is unprojectable.
---@param item table<string, unknown>
---@param viewMatrix number[]
---@param projection number[]
---@return number?
local function projectCenterY(item, viewMatrix, projection)
  local center = assert(item.center, "render item requires a model-space center")
  local viewX, viewY, viewZ
  if item.billboardCenter ~= nil then
    local billboardCenter = assert(item.billboardCenter, "billboard item requires billboardCenter")
    local billboardScale = assert(item.billboardScale, "billboard item requires billboardScale")
    local centerX, centerY, centerZ =
      Matrix4.transformPoint(viewMatrix, billboardCenter[1], billboardCenter[2], billboardCenter[3])
    viewX = centerX + center[1] * billboardScale[1]
    viewY = centerY + center[2] * billboardScale[2]
    viewZ = centerZ + center[3] * billboardScale[3]
  else
    local transform = assert(item.transform, "render item requires a transform")
    local worldX, worldY, worldZ = Matrix4.transformPoint(transform, center[1], center[2], center[3])
    viewX, viewY, viewZ = Matrix4.transformPoint(viewMatrix, worldX, worldY, worldZ)
  end
  return screenY(projection, viewX, viewY, viewZ)
end

-- The blended sort keys of one draw item: projected screen-Y extents of its
-- cached model-space AABB under the live camera, falling back to the
-- projected model-space center (identical top and bottom keys) when the item
-- carries no AABB, and to a deterministic top-of-screen constant when even
-- the center is unprojectable -- never the old view-Z sort. The fallback
-- stays deterministic, and clipped geometry is culled by the GPU regardless
-- of its queue position.
---@param item table<string, unknown>
---@param viewMatrix number[]
---@param worldProjection number[]
---@param billboardProjection number[]
---@return number bottomY
---@return number topY
local function sortScreenBounds(item, viewMatrix, worldProjection, billboardProjection)
  local projection = projectionForItem(item, worldProjection, billboardProjection)
  local bounds = item.sortBounds
  local bottomY, topY
  if bounds ~= nil then
    if item.billboardCenter ~= nil then
      bottomY, topY = billboardBoundsScreenY(item, bounds, viewMatrix, projection)
    else
      bottomY, topY = worldBoundsScreenY(bounds, assert(item.transform), viewMatrix, projection)
    end
  end
  if bottomY == nil or topY == nil then
    local centerY = projectCenterY(item, viewMatrix, projection)
    if centerY ~= nil then
      bottomY, topY = centerY, centerY
    else
      bottomY, topY = 0.0, 0.0
    end
  end
  return bottomY, topY
end

local function clear(items)
  for i = #items, 1, -1 do
    items[i] = nil
  end
end

---@class RenderQueueScratch
---@field opaque table[]
---@field cutout table[]
---@field mixedOpaque table[]
---@field wireframe table[]
---@field blended table[]
---@field _blendedEntries table[]
---@field _sortKeys ffi.cdata*
---@field _sortOrder number[]
---@field _sortCompare fun(leftIndex: number, rightIndex: number): boolean
---@field _sortCapacity integer

-- The only supported scratch constructor. Allocates the five pass arrays,
-- unsorted wrapper storage, the initial key buffer, the reusable order array,
-- and one comparator that reads the scratch key buffer dynamically so later
-- capacity growth cannot leave it pointing at stale storage.
---@return RenderQueueScratch
function RenderQueue.newScratch()
  local scratch = {
    opaque = {},
    cutout = {},
    mixedOpaque = {},
    wireframe = {},
    blended = {},
    _blendedEntries = {},
    _sortKeys = ffi.new("G4RenderSortKey[?]", INITIAL_SORT_CAPACITY),
    _sortOrder = {},
    _sortCapacity = INITIAL_SORT_CAPACITY,
  }
  ---@param leftIndex number
  ---@param rightIndex number
  ---@return boolean
  local function sortCompare(leftIndex, rightIndex)
    local keys = scratch._sortKeys
    local left = keys[leftIndex - 1]
    local right = keys[rightIndex - 1]
    if left.bottomY ~= right.bottomY then
      return left.bottomY < right.bottomY
    end
    if left.topY ~= right.topY then
      return left.topY < right.topY
    end
    return left.position < right.position
  end
  scratch._sortCompare = sortCompare
  return scratch
end

-- Grow the key buffer geometrically when the blended count exceeds capacity.
-- Copies the keys written so far in the current build so mid-build growth
-- preserves earlier entries.
---@param scratch RenderQueueScratch
---@param needed integer
local function ensureSortCapacity(scratch, needed)
  if needed <= scratch._sortCapacity then
    return
  end
  local grown = scratch._sortCapacity * 2
  if grown < needed then
    grown = needed
  end
  local replacement = ffi.new("G4RenderSortKey[?]", grown)
  local keys = scratch._sortKeys
  for index = 0, needed - 2 do
    replacement[index] = keys[index]
  end
  scratch._sortKeys = replacement
  scratch._sortCapacity = grown
end

-- Build into renderer-owned scratch storage. Parts are traversed in source
-- order and share one submission position sequence, including across part
-- boundaries. The scratch arrays retain their identities across calls.
-- Mixed items appear in both mixedOpaque and blended. Blended contains
-- queue-owned wrapper records referencing the original items. The caller
-- supplies the live camera matrices: the view plus the world and
-- field-billboard projections the renderer draws through, so blended keys
-- measure the projected screen-Y extents the DS auto-sort rule orders by.
---@param parts table[][]
---@param viewMatrix number[]
---@param worldProjection number[]
---@param billboardProjection number[]
---@param scratch RenderQueueScratch
---@return RenderQueueScratch
function RenderQueue.buildInto(parts, viewMatrix, worldProjection, billboardProjection, scratch)
  local opaque = scratch.opaque
  local cutout = scratch.cutout
  local mixedOpaque = scratch.mixedOpaque
  local wireframe = scratch.wireframe
  local blended = scratch.blended
  assert(opaque and cutout and mixedOpaque and wireframe and blended, "render queue scratch is incomplete")
  local unsorted = scratch._blendedEntries
  local order = scratch._sortOrder
  local compare = scratch._sortCompare
  assert(
    unsorted and scratch._sortKeys and order and compare and scratch._sortCapacity,
    "render queue scratch is incomplete"
  )

  clear(opaque)
  clear(cutout)
  clear(mixedOpaque)
  clear(wireframe)

  local position = 0
  local blendedCount = 0
  local capacity = scratch._sortCapacity
  for _, part in ipairs(parts) do
    for _, item in ipairs(part) do
      position = position + 1
      -- One branch chain on the item's renderer-facing class: no separate
      -- membership lookup precedes the pass selection. Only the five known
      -- classes land in a pass; anything else fails loudly here.
      local mode = item.alphaClass

      if mode == AlphaClassifier.OPAQUE then
        opaque[#opaque + 1] = item
      elseif mode == AlphaClassifier.CUTOUT then
        cutout[#cutout + 1] = item
      elseif mode == AlphaClassifier.MIXED then
        mixedOpaque[#mixedOpaque + 1] = item

        blendedCount = blendedCount + 1
        if blendedCount > capacity then
          ensureSortCapacity(scratch, blendedCount)
          capacity = scratch._sortCapacity
        end
        local entry = unsorted[blendedCount]
        if entry == nil then
          entry = {}
          unsorted[blendedCount] = entry
        end
        entry.item = item
        entry.fragmentPass = AlphaClassifier.MIXED
        local bottomY, topY = sortScreenBounds(item, viewMatrix, worldProjection, billboardProjection)
        local key = scratch._sortKeys[blendedCount - 1]
        key.bottomY = bottomY
        key.topY = topY
        key.position = position
        key.entryIndex = blendedCount
      elseif mode == AlphaClassifier.TRANSLUCENT then
        blendedCount = blendedCount + 1
        if blendedCount > capacity then
          ensureSortCapacity(scratch, blendedCount)
          capacity = scratch._sortCapacity
        end
        local entry = unsorted[blendedCount]
        if entry == nil then
          entry = {}
          unsorted[blendedCount] = entry
        end
        entry.item = item
        entry.fragmentPass = AlphaClassifier.TRANSLUCENT
        local bottomY, topY = sortScreenBounds(item, viewMatrix, worldProjection, billboardProjection)
        local key = scratch._sortKeys[blendedCount - 1]
        key.bottomY = bottomY
        key.topY = topY
        key.position = position
        key.entryIndex = blendedCount
      elseif mode == AlphaClassifier.WIREFRAME then
        wireframe[#wireframe + 1] = item
      else
        Errors.raise(
          RENDER_QUEUE_UNKNOWN_ALPHA_CLASS,
          "render item has unknown alpha class " .. tostring(mode),
          { alphaClass = mode }
        )
      end
    end
  end

  for index = 1, blendedCount do
    order[index] = index
  end
  for index = #order, blendedCount + 1, -1 do
    order[index] = nil
  end

  if blendedCount > 1 then
    table.sort(order, compare)
  end

  -- Order indexes double as unsorted-entry indexes: key slot i always
  -- describes entry i, so the sorted order maps directly to wrappers.
  for rank = 1, blendedCount do
    blended[rank] = unsorted[order[rank]]
  end
  for index = #blended, blendedCount + 1, -1 do
    blended[index] = nil
  end

  return scratch
end

return RenderQueue
