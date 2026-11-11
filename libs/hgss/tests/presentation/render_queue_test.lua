-- Tests for RenderQueue: classification, pass-order preservation for
-- opaque/cutout/mixedOpaque/wireframe, translucent screen-Y automatic-sort
-- ordering, MIXED item splitting into opaque and blended passes, and
-- deterministic tie-breaking by traversal position across ordered parts.
-- Queue construction validates its input contract and never mutates the
-- caller's draw records.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local RenderQueue = require("libs.hgss.src.presentation.RenderQueue")
local Matrix4 = require("libs.math.src.Matrix4")

local T = {}

local IDENTITY = Matrix4.identity()

-- A linear, fully predictable screen-Y projection for the ordering tests:
-- identity view plus an orthographic projection maps model Y directly to
-- top-down screen Y (0 is the top): screenY(y) = 0.5 * (1 - y / 10).
local function orthoProjection()
  return Matrix4.orthographic(-10, 10, -10, 10, 0.1, 100)
end

local function item(id, mode, center, transform, opts)
  opts = opts or {}
  return {
    id = id,
    alphaClass = mode,
    center = center or { 0, 0, 0 },
    transform = transform or Matrix4.identity(),
    sortBounds = opts.sortBounds,
    projectedBounds = opts.projectedBounds,
    billboardCenter = opts.billboardCenter,
    billboardScale = opts.billboardScale,
    billboardProjection = opts.billboardProjection,
    fieldEffect = opts.fieldEffect,
  }
end

-- Model-space AABB helper: the pool mesh-entry bounds shape the queue reads.
local function bounds(minX, maxX, minY, maxY, minZ, maxZ)
  return { minX = minX, maxX = maxX, minY = minY, maxY = maxY, minZ = minZ, maxZ = maxZ }
end

local function ids(queue, key)
  local out = {}
  local entries = queue[key]
  if key == "blended" then
    -- blended contains {item, fragmentPass} records
    for _, record in ipairs(entries) do
      out[#out + 1] = record.item.id
    end
  else
    for _, it in ipairs(entries) do
      out[#out + 1] = it.id
    end
  end
  return out
end

local function fragmentPassesIn(queue, key)
  local out = {}
  if key == "blended" then
    for _, record in ipairs(queue[key]) do
      out[#out + 1] = record.fragmentPass
    end
  end
  return out
end

local function scratch()
  return RenderQueue.newScratch()
end

local function build(parts, viewMatrix, worldProjection, billboardProjection)
  return RenderQueue.buildInto(
    parts,
    viewMatrix or IDENTITY,
    worldProjection or IDENTITY,
    billboardProjection or IDENTITY,
    scratch()
  )
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(
    Errors.is(err) and err.code == code,
    "expected " .. code .. ", got " .. tostring(Errors.is(err) and err.code or err)
  )
  return err
end

function T.classifies_by_alpha_class()
  local items = {
    item("a", "opaque"),
    item("b", "cutout"),
    item("c", "translucent"),
    item("d", "wireframe"),
  }
  local q = build({ items }, Matrix4.identity())
  Assert.deepEqual(ids(q, "opaque"), { "a" })
  Assert.deepEqual(ids(q, "cutout"), { "b" })
  Assert.deepEqual(ids(q, "blended"), { "c" })
  Assert.deepEqual(ids(q, "wireframe"), { "d" })
end

function T.classifies_mixed_items()
  local items = {
    item("mixed1", "mixed"),
    item("mixed2", "mixed"),
  }
  local q = build({ items }, Matrix4.identity())
  Assert.deepEqual(ids(q, "mixedOpaque"), { "mixed1", "mixed2" })
  -- Mixed items also appear in blended with fragmentPass
  Assert.deepEqual(ids(q, "blended"), { "mixed1", "mixed2" })
  Assert.deepEqual(
    fragmentPassesIn(q, "blended"),
    { "mixed", "mixed" },
    "mixed items in blended have fragmentPass='mixed'"
  )
end

function T.build_into_reuses_caller_owned_scratch_arrays()
  local storage = scratch()
  local opaque = storage.opaque
  local cutout = storage.cutout
  local mixedOpaque = storage.mixedOpaque
  local wireframe = storage.wireframe
  local blended = storage.blended

  local queue = RenderQueue.buildInto({
    { item("map", "opaque"), item("glass", "translucent") },
    { item("building", "cutout") },
    { item("actor", "wireframe") },
  }, Matrix4.identity(), IDENTITY, IDENTITY, storage)

  Assert.isTrue(queue == storage)
  Assert.isTrue(queue.opaque == opaque)
  Assert.isTrue(queue.cutout == cutout)
  Assert.isTrue(queue.mixedOpaque == mixedOpaque)
  Assert.isTrue(queue.wireframe == wireframe)
  Assert.isTrue(queue.blended == blended)
  Assert.deepEqual(ids(queue, "opaque"), { "map" })
  Assert.deepEqual(ids(queue, "cutout"), { "building" })
  Assert.deepEqual(ids(queue, "blended"), { "glass" })
  Assert.deepEqual(ids(queue, "wireframe"), { "actor" })
end

function T.build_into_preserves_order_across_parts()
  local queue = RenderQueue.buildInto({
    { item("map-a", "opaque"), item("map-b", "cutout") },
    { item("building", "opaque") },
    { item("neighbor", "cutout") },
    { item("actor", "opaque") },
  }, Matrix4.identity(), IDENTITY, IDENTITY, scratch())

  Assert.deepEqual(ids(queue, "opaque"), { "map-a", "building", "actor" })
  Assert.deepEqual(ids(queue, "cutout"), { "map-b", "neighbor" })
end

function T.build_into_clears_stale_tail_entries()
  local storage = scratch()
  RenderQueue.buildInto({
    {
      item("opaque-a", "opaque"),
      item("opaque-b", "opaque"),
      item("cutout", "cutout"),
      item("far", "translucent", { 0, 0, -2 }),
      item("near", "translucent", { 0, 0, -1 }),
      item("wire", "wireframe"),
    },
  }, Matrix4.identity(), IDENTITY, IDENTITY, storage)

  RenderQueue.buildInto({ { item("only", "opaque") } }, Matrix4.identity(), IDENTITY, IDENTITY, storage)

  Assert.deepEqual(ids(storage, "opaque"), { "only" })
  Assert.equal(#storage.cutout, 0)
  Assert.equal(#storage.mixedOpaque, 0)
  Assert.equal(#storage.wireframe, 0)
  Assert.equal(#storage.blended, 0)
end

-- Bottom screen Y orders first, mixing ordinary and mixed-translucent
-- entries jointly: the lower item on screen sorts later even though it is
-- the nearer one in camera space.
function T.mixed_and_translucent_sort_jointly_by_screen_y()
  local ortho = orthoProjection()
  local queue = build({
    {
      item("low-far", "translucent", { 0, -4, -20 }),
      item("high-near", "mixed", { 0, 4, -5 }),
    },
  }, IDENTITY, ortho, ortho)

  Assert.deepEqual(ids(queue, "blended"), { "high-near", "low-far" })
  Assert.deepEqual(fragmentPassesIn(queue, "blended"), { "mixed", "translucent" })
end

function T.mixed_and_translucent_equal_extent_tie_by_position()
  local queue = build({
    { item("trans1", "translucent", { 0, 0, -5 }) },
    { item("mixed1", "mixed", { 0, 0, -5 }) },
    { item("trans2", "translucent", { 0, 0, -5 }) },
    { item("mixed2", "mixed", { 0, 0, -5 }) },
  }, Matrix4.identity())

  Assert.deepEqual(
    ids(queue, "blended"),
    { "trans1", "mixed1", "trans2", "mixed2" },
    "equal-extent items maintain submission order"
  )
end

function T.mixed_item_in_opaque_and_blended_passes()
  local ortho = orthoProjection()
  local storage = scratch()
  local queue = RenderQueue.buildInto({
    {
      item("opaque", "opaque"),
      item("mixed", "mixed", { 0, 2, -5 }),
      item("translucent", "translucent", { 0, -2, -5 }),
    },
  }, IDENTITY, ortho, ortho, storage)

  -- Mixed appears in mixedOpaque for the opaque subpass
  Assert.deepEqual(ids(queue, "mixedOpaque"), { "mixed" })
  -- Mixed also appears in blended for the translucent subpass
  Assert.deepEqual(ids(queue, "blended"), { "mixed", "translucent" })
  -- Verify fragmentPass markers
  Assert.deepEqual(fragmentPassesIn(queue, "blended"), { "mixed", "translucent" })
end

-- Queue construction branches once on each item's renderer-facing alpha
-- class: one build carrying all five valid classes lands every item in
-- its pass.
function T.build_into_sorts_all_five_alpha_classes()
  local ortho = orthoProjection()
  local queue = RenderQueue.buildInto({
    { item("wall", "opaque"), item("fence", "cutout") },
    {
      item("high-glass", "translucent", { 0, 3, -10 }),
      item("low-glass", "mixed", { 0, -3, -5 }),
      item("edges", "wireframe"),
    },
  }, IDENTITY, ortho, ortho, scratch())
  Assert.deepEqual(ids(queue, "opaque"), { "wall" })
  Assert.deepEqual(ids(queue, "cutout"), { "fence" })
  Assert.deepEqual(ids(queue, "mixedOpaque"), { "low-glass" })
  Assert.deepEqual(ids(queue, "wireframe"), { "edges" })
  Assert.deepEqual(ids(queue, "blended"), { "high-glass", "low-glass" })
  Assert.deepEqual(fragmentPassesIn(queue, "blended"), { "translucent", "mixed" })
end

-- Queue construction validates its input contract once: an unknown class,
-- a material-only class, and a missing class all fail loudly with the same
-- contract code instead of landing in an arbitrary pass.
function T.rejects_invalid_alpha_classes()
  local unknown = throwsCode("RENDER_QUEUE_UNKNOWN_ALPHA_CLASS", function()
    build({ { item("ghostly", "ghostly") } }, Matrix4.identity())
  end)
  Assert.equal(unknown.context.alphaClass, "ghostly")

  local materialOnly = throwsCode("RENDER_QUEUE_UNKNOWN_ALPHA_CLASS", function()
    build({
      {
        {
          id = "mat",
          material = { alphaClass = "cutout" },
          center = { 0, 0, 0 },
          transform = Matrix4.identity(),
        },
      },
    }, Matrix4.identity())
  end)
  Assert.isNil(materialOnly.context.alphaClass)

  throwsCode("RENDER_QUEUE_UNKNOWN_ALPHA_CLASS", function()
    build({ { { center = { 0, 0, 0 }, transform = Matrix4.identity() } } }, Matrix4.identity())
  end)
end

function T.preserves_submission_order_for_opaque()
  local items = { item("a", "opaque"), item("b", "opaque"), item("c", "opaque") }
  local q = build({ items }, Matrix4.identity())
  Assert.deepEqual(ids(q, "opaque"), { "a", "b", "c" })
end

function T.preserves_submission_order_for_cutout_and_wireframe()
  local items = { item("a", "cutout"), item("b", "wireframe"), item("c", "cutout") }
  local q = build({ items }, Matrix4.identity())
  Assert.deepEqual(ids(q, "cutout"), { "a", "c" })
  Assert.deepEqual(ids(q, "wireframe"), { "b" })
end

-- The automatic screen-Y rule replaces camera-depth sorting: far-low sits
-- deeper in camera space (world Z -10 versus -1 under the same view) yet
-- sorts last, because near-high sits higher on screen.
function T.sorts_translucent_by_screen_y_where_camera_depth_would_differ()
  local view = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local projection = Matrix4.perspective(math.rad(60), 1, 0.1, 100)
  local items = {
    item("near-high", "translucent", { 0, 2, -1 }),
    item("far-low", "translucent", { 0, -3, -10 }),
  }
  local q = build({ items }, view, projection, projection)
  Assert.deepEqual(ids(q, "blended"), { "near-high", "far-low" })
end

-- Equal screen extents tie-break by traversal position across the ordered
-- parts: the earlier part (map geometry) draws before the later part
-- (actors) deterministically.
function T.equal_extent_ties_break_by_part_position()
  local ortho = orthoProjection()
  local parts = {
    { item("first", "translucent", { 0, 1, -5 }) },
    { item("second", "translucent", { 0, 1, -5 }) },
    { item("third", "translucent", { 0, 1, -5 }) },
  }
  local q = build(parts, IDENTITY, ortho, ortho)
  Assert.deepEqual(ids(q, "blended"), { "first", "second", "third" })
end

-- Two items translated vertically: the higher one on screen sorts first,
-- while the camera-space Z of both stays identical.
function T.transforms_center_by_item_transform()
  local ortho = orthoProjection()
  local upper = item("upper", "translucent", { 0, 0, 0 }, Matrix4.translate(0, 3, 0))
  local lower = item("lower", "translucent", { 0, 0, 0 }, Matrix4.translate(0, -3, 0))
  local q = build({ { lower, upper } }, IDENTITY, ortho, ortho)
  Assert.deepEqual(ids(q, "blended"), { "upper", "lower" })
end

-- A nonzero model-space center is transformed exactly once by the item
-- transform: translating a +1 center by +32 reaches world Y 33, below the
-- control at 49. A double application (+65) would sort the translated item
-- first instead.
function T.transforms_nonzero_model_center_once_before_sorting()
  local ortho = orthoProjection()
  local translated = item("translated", "translucent", { 0, 1, 0 }, Matrix4.translate(0, 32, 0))
  local origin = item("origin", "translucent", { 0, 49, 0 }, Matrix4.identity())
  local q = build({ { translated, origin } }, IDENTITY, ortho, ortho)
  Assert.deepEqual(ids(q, "blended"), { "origin", "translated" })
end

-- Sorting leaves the persistent draw records untouched: Blended entries
-- are scratch records, and repeated construction from the same items is
-- deterministic. The before/after snapshot below proves non-mutation
-- generically, without naming the scratch's current sort-key fields.
function T.build_does_not_mutate_input_items()
  local ortho = orthoProjection()
  local items = {
    item("a", "opaque", { 0, 0, 0 }),
    item("b", "translucent", { 0, 2, -10 }),
    item("c", "translucent", { 0, -2, -5 }),
    item("d", "cutout"),
    item("e", "wireframe"),
  }
  local before = {}
  for i, it in ipairs(items) do
    before[i] = {}
    for k, v in pairs(it) do
      before[i][k] = v
    end
  end
  local first = build({ items }, IDENTITY, ortho, ortho)
  local second = build({ items }, IDENTITY, ortho, ortho)
  for i, it in ipairs(items) do
    Assert.deepEqual(it, before[i], "item " .. i .. " mutated by queue construction")
  end
  Assert.deepEqual(ids(first, "blended"), ids(second, "blended"))
end

-- The returned queue holds the original item tables in opaque/cutout/mixedOpaque/wireframe.
-- Blended entries are scratch records that point to original items via .item field.
function T.queue_entries_are_the_original_items()
  local items = {
    item("a", "opaque"),
    item("b", "translucent"),
    item("c", "cutout"),
    item("d", "wireframe"),
  }
  local q = build({ items }, Matrix4.identity())
  Assert.isTrue(q.opaque[1] == items[1], "opaque pass returns the original item")
  Assert.isTrue(q.blended[1].item == items[2], "blended pass record points to original item")
  Assert.isTrue(q.cutout[1] == items[3], "cutout pass returns the original item")
  Assert.isTrue(q.wireframe[1] == items[4], "wireframe pass returns the original item")
end

-- A rotated item: the model-space center is transformed exactly once by the
-- item transform, so the sort reflects the true world position. A 90-degree
-- Y rotation maps a +X model offset to -Z, and the extra upward translation
-- then places the rotated item higher on screen.
function T.transforms_rotated_translated_centers_once()
  local ortho = orthoProjection()
  local rotate = Matrix4.rotateY(math.pi / 2)
  local move = Matrix4.translate(0, 4, 0)
  local transform = Matrix4.multiply(move, rotate)
  -- A model-local center at +X maps, under the 90-degree Y rotation, to -Z
  -- with the +4 lift; the unrotated item at the origin stays lower.
  local rotated = item(1, "translucent", { 5, 0, 0 }, transform)
  local origin = item(2, "translucent", { 0, 0, 0 }, Matrix4.identity())
  local q = build({ { origin, rotated } }, IDENTITY, ortho, ortho)
  Assert.deepEqual(ids(q, "blended"), { 1, 2 }, "higher (rotated and lifted) first, origin last")
end

-- A billboard sorts from its camera-facing placement: the billboard center
-- into view space plus the model-space extents scaled by the billboard
-- axes. Doubling the vertical scale of a unit box spreads its screen-Y
-- extents exactly like the shader's view-space placement.
function T.sorts_billboards_from_their_camera_facing_placement()
  local ortho = orthoProjection()
  local billboard = item("billboard", "translucent", { 0, 0, 0 }, nil, {
    sortBounds = bounds(-1, 1, -1, 1, 0, 0),
    billboardCenter = { 0, 0, -5 },
    billboardScale = { 1, 2, 1 },
  })
  -- The scaled box spans view Y in [-2, 2]: bottom screen Y 0.6.
  local ordinary = item("ordinary", "translucent", { 0, 1, -5 })

  local q = build({ { billboard, ordinary } }, IDENTITY, ortho, ortho)

  Assert.deepEqual(
    ids(q, "blended"),
    { "ordinary", "billboard" },
    "the ordinary center at screen Y 0.45 sorts before the billboard bottom 0.6"
  )
end

-- Projection selection mirrors the renderer: billboard-flagged and
-- field-effect items project through the billboard projection, ordinary
-- items through the world projection. A scaled billboard projection moves
-- the billboard item across an ordinary control item that both projections
-- would otherwise agree on.
function T.billboard_and_field_effect_items_use_the_billboard_projection()
  local worldProjection = Matrix4.identity()
  local billboardProjection = Matrix4.scale(1, 2, 1)
  local flagged = item("flagged", "translucent", { 0, 0, 0 }, nil, {
    sortBounds = bounds(0, 0, 2, 6, 0, 0),
    billboardCenter = { 0, 0, 0 },
    billboardScale = { 1, 1, 1 },
    billboardProjection = true,
  })
  local effect = item("effect", "translucent", { 0, 0, 0 }, nil, {
    sortBounds = bounds(0, 0, 2, 6, 0, 0),
    fieldEffect = "warp_entrance",
  })
  -- Ordinary control: projected center at world screen Y -1.0, between the
  -- world-projection reading (-0.5) and the billboard-projection reading
  -- (-1.5) of the same bounds.
  local control = item("control", "translucent", { 0, 3, 0 })

  local q = build({ { control, flagged, effect } }, IDENTITY, worldProjection, billboardProjection)

  Assert.deepEqual(
    ids(q, "blended"),
    { "flagged", "effect", "control" },
    "billboard and field-effect bounds project through the billboard projection"
  )
end

-- Ordinary items always project through the world projection, even when the
-- billboard projection differs.
function T.ordinary_items_use_the_world_projection()
  local worldProjection = Matrix4.identity()
  local billboardProjection = Matrix4.scale(1, 2, 1)
  local ordinary = item("ordinary", "translucent", { 0, 3, 0 })
  local control = item("control", "translucent", { 0, 1, 0 })

  local q = build({ { control, ordinary } }, IDENTITY, worldProjection, billboardProjection)

  -- World screen Y: ordinary -1.0, control 0.0.
  Assert.deepEqual(ids(q, "blended"), { "ordinary", "control" })
end

-- World geometry sorts from its transformed AABB, not its center or its
-- camera depth: two boxes sharing one center order by their vertical
-- extents, and a translated box moves with its transform.
function T.world_geometry_sorts_from_the_transformed_aabb()
  local ortho = orthoProjection()
  -- Same center, different extents: the taller box reaches lower on screen.
  local tall = item("tall", "translucent", { 0, 0, -5 }, Matrix4.identity(), {
    sortBounds = bounds(-1, 1, -4, 1, -1, 1),
  })
  local short = item("short", "translucent", { 0, 0, -5 }, Matrix4.identity(), {
    sortBounds = bounds(-1, 1, -1, 1, -1, 1),
  })
  local q = build({ { tall, short } }, IDENTITY, ortho, ortho)
  Assert.deepEqual(ids(q, "blended"), { "short", "tall" })

  -- A translated box carries its extents with it: +4 lift sorts above an
  -- untranslated box even though both share the model-space AABB.
  local lifted = item("lifted", "translucent", { 0, 0, -5 }, Matrix4.translate(0, 4, 0), {
    sortBounds = bounds(-1, 1, -1, 1, -1, 1),
  })
  local grounded = item("grounded", "translucent", { 0, 0, -5 }, Matrix4.identity(), {
    sortBounds = bounds(-1, 1, -1, 1, -1, 1),
  })
  local moved = build({ { grounded, lifted } }, IDENTITY, ortho, ortho)
  Assert.deepEqual(ids(moved, "blended"), { "lifted", "grounded" })
end

-- Equal bottom screen Y breaks on ascending top screen Y: two boxes sharing
-- a bottom edge order by their top edge, not by submission.
function T.bottom_tie_breaks_on_top_screen_y()
  local ortho = orthoProjection()
  local tall = item("tall", "translucent", { 0, 0, -5 }, Matrix4.identity(), {
    sortBounds = bounds(-1, 1, -5, 5, -1, 1),
  })
  local flat = item("flat", "translucent", { 0, 0, -5 }, Matrix4.identity(), {
    sortBounds = bounds(-1, 1, -5, 0, -1, 1),
  })
  -- Tall spans screen Y [0.25, 0.75]; flat spans [0.5, 0.75]: equal bottoms.
  local q = build({ { flat, tall } }, IDENTITY, ortho, ortho)
  Assert.deepEqual(ids(q, "blended"), { "tall", "flat" })
end

-- An item without cached bounds falls back to its projected center with
-- identical top and bottom keys: deterministic, with no return to the old
-- view-Z sort.
function T.missing_bounds_falls_back_to_the_projected_center()
  local ortho = orthoProjection()
  local storage = scratch()
  local upper = item("upper", "translucent", { 0, 4, -5 })
  local lower = item("lower", "translucent", { 0, -4, -5 })
  local queue = RenderQueue.buildInto({ { lower, upper } }, IDENTITY, ortho, ortho, storage)

  Assert.deepEqual(ids(queue, "blended"), { "upper", "lower" })
  Assert.equal(storage._sortKeys[0].bottomY, storage._sortKeys[0].topY)
  Assert.equal(storage._sortKeys[1].bottomY, storage._sortKeys[1].topY)
  -- Key slots follow entry (submission) order: slot 0 is the lower item.
  Assert.isTrue(storage._sortKeys[1].bottomY < storage._sortKeys[0].bottomY)
end

-- Geometry that cannot project (behind the camera plane) receives a
-- deterministic top-of-screen constant instead of NaN/Infinity keys, and
-- rebuilds agree exactly.
function T.unprojectable_geometry_receives_deterministic_finite_keys()
  local projection = Matrix4.perspective(math.rad(60), 1, 0.1, 100)
  local storage = scratch()
  local behind = item("behind", "translucent", { 0, 0, 5 }, Matrix4.identity(), {
    sortBounds = bounds(-1, 1, -1, 1, -1, 1),
  })
  local first = RenderQueue.buildInto({ { behind } }, IDENTITY, projection, projection, storage)
  local bottomY, topY = storage._sortKeys[0].bottomY, storage._sortKeys[0].topY
  Assert.equal(bottomY, 0.0)
  Assert.equal(topY, 0.0)
  Assert.isTrue(bottomY == bottomY and topY == topY, "unprojectable keys are never NaN")
  local second = RenderQueue.buildInto({ { behind } }, IDENTITY, projection, projection, storage)
  Assert.deepEqual(ids(first, "blended"), ids(second, "blended"))
  Assert.equal(storage._sortKeys[0].bottomY, bottomY)
end

-- Blended entries are renderer-owned scratch records with {item, fragmentPass}.
-- They must be reused across frames so repeated queue construction does not
-- allocate new entry tables.
function T.blended_entries_are_reused_scratch_records()
  local storage = scratch()
  local q1 = RenderQueue.buildInto({
    { item("trans1", "translucent"), item("trans2", "translucent") },
  }, Matrix4.identity(), IDENTITY, IDENTITY, storage)

  local firstEntry1 = q1.blended[1]
  local firstEntry2 = q1.blended[2]

  local q2 = RenderQueue.buildInto({
    { item("trans1", "translucent"), item("trans2", "translucent") },
  }, Matrix4.identity(), IDENTITY, IDENTITY, storage)

  -- Same storage object is reused
  Assert.isTrue(q2 == storage)
  -- Scratch entry tables are reused (same object identities)
  Assert.isTrue(q2.blended[1] == firstEntry1, "blended entry 1 table is reused")
  Assert.isTrue(q2.blended[2] == firstEntry2, "blended entry 2 table is reused")
end

-- After a smaller frame, stale blended entries and stale sort-order
-- indexes are truncated together.
function T.blended_tail_truncation_after_smaller_frame()
  local storage = scratch()
  RenderQueue.buildInto({
    {
      item("t1", "translucent"),
      item("t2", "translucent"),
      item("t3", "translucent"),
    },
  }, Matrix4.identity(), IDENTITY, IDENTITY, storage)

  Assert.equal(#storage.blended, 3)
  Assert.equal(#storage._sortOrder, 3)

  RenderQueue.buildInto({
    { item("t1", "translucent") },
  }, Matrix4.identity(), IDENTITY, IDENTITY, storage)

  Assert.equal(#storage.blended, 1, "stale blended tail is removed")
  Assert.isNil(storage.blended[2], "no stale blended reference survives shrinking")
  Assert.equal(#storage._sortOrder, 1, "shrinking clears stale order indexes")
  Assert.isNil(storage._sortOrder[2], "no stale order index survives shrinking")
end

-- Blended records must have fragmentPass field set to the correct pass type.
function T.blended_records_have_fragment_pass_field()
  local storage = scratch()
  RenderQueue.buildInto({
    {
      item("trans", "translucent"),
      item("mixed", "mixed"),
    },
  }, Matrix4.identity(), IDENTITY, IDENTITY, storage)

  Assert.equal(storage.blended[1].fragmentPass, "translucent")
  Assert.equal(storage.blended[2].fragmentPass, "mixed")
end

-- MIXED items must not be in the translucent-only array, and must appear separately.
function T.mixed_does_not_confuse_with_translucent_only()
  local storage = scratch()
  local items = {
    item("trans-a", "translucent"),
    item("mixed-a", "mixed"),
    item("trans-b", "translucent"),
    item("mixed-b", "mixed"),
  }
  RenderQueue.buildInto({ items }, Matrix4.identity(), IDENTITY, IDENTITY, storage)

  -- mixedOpaque contains only mixed items
  Assert.deepEqual(ids(storage, "mixedOpaque"), { "mixed-a", "mixed-b" })
  -- blended contains all items (mixed + translucent)
  Assert.deepEqual(ids(storage, "blended"), { "trans-a", "mixed-a", "trans-b", "mixed-b" })
  -- Verify the fragmentPass values
  Assert.deepEqual(fragmentPassesIn(storage, "blended"), { "translucent", "mixed", "translucent", "mixed" })
end

-- Blended ordering through the queue-owned scratch constructor: every alpha
-- class across multiple parts lands in its pass, blended sorts by ascending
-- bottom screen Y with source-position tie breaks, and mixed items reference
-- the same original record in both passes.
function T.preserves_exact_pass_membership_and_blended_order_through_owned_scratch()
  local storage = RenderQueue.newScratch()
  local ortho = orthoProjection()
  local wall = item("wall", "opaque")
  local fence = item("fence", "cutout")
  local high = item("high", "translucent", { 0, 4, -10 })
  local mixedMid = item("mixed-mid", "mixed", { 0, 0, -5 })
  local tieLate = item("tie-late", "translucent", { 0, 0, -5 })
  local low = item("low", "translucent", { 0, -4, -1 })
  local wire = item("wire", "wireframe")
  local queue = RenderQueue.buildInto({
    { wall, fence, high, mixedMid },
    { tieLate, low },
    { wire },
  }, IDENTITY, ortho, ortho, storage)

  Assert.isTrue(queue == storage)
  Assert.deepEqual(ids(queue, "opaque"), { "wall" })
  Assert.deepEqual(ids(queue, "cutout"), { "fence" })
  Assert.deepEqual(ids(queue, "mixedOpaque"), { "mixed-mid" })
  Assert.deepEqual(ids(queue, "wireframe"), { "wire" })
  Assert.deepEqual(ids(queue, "blended"), { "high", "mixed-mid", "tie-late", "low" })
  Assert.deepEqual(fragmentPassesIn(queue, "blended"), { "translucent", "mixed", "translucent", "translucent" })
  Assert.isTrue(
    queue.mixedOpaque[1] == mixedMid and queue.blended[2].item == mixedMid,
    "the mixed item reaches both passes by identity"
  )
  Assert.isTrue(queue.blended[1].item == high, "the first entry is the highest draw")
  Assert.isTrue(queue.blended[#queue.blended].item == low, "the last entry is the lowest draw")
end

-- Warmed rebuilds at a stable blended cardinality reuse every piece of sort
-- storage owned by the scratch: one comparator, one key buffer, the same
-- unsorted wrapper objects, the same order table, and the same visible
-- blended array. The field renderer must build its lifetime scratch through
-- the same queue-owned constructor so production always carries valid sort
-- storage.
function T.warmed_rebuilds_reuse_sort_storage_and_leave_inputs_untouched()
  local storage = RenderQueue.newScratch()
  Assert.isTrue(type(storage._sortCompare) == "function", "the scratch owns one comparator")
  Assert.notNil(storage._sortKeys, "the scratch owns reusable key storage")
  Assert.notNil(storage._sortOrder, "the scratch owns a reusable order table")

  local ortho = orthoProjection()
  local first = item("first", "translucent", { 0, 3, -5 })
  local second = item("mixed-second", "mixed", { 0, 0, -5 })
  local third = item("third", "translucent", { 0, -3, -5 })
  local parts = { { first, second, third } }
  local before = {}
  for index, original in ipairs(parts[1]) do
    before[index] = {}
    for key, value in pairs(original) do
      before[index][key] = value
    end
  end

  RenderQueue.buildInto(parts, IDENTITY, ortho, ortho, storage)
  local comparator = storage._sortCompare
  local keys = storage._sortKeys
  local order = storage._sortOrder
  local blendedArray = storage.blended
  local wrappers = {}
  for index, wrapper in ipairs(storage.blended) do
    wrappers[index] = wrapper
  end
  Assert.equal(#wrappers, 3)

  RenderQueue.buildInto(parts, IDENTITY, ortho, ortho, storage)

  Assert.isTrue(storage._sortCompare == comparator, "the comparator is reused, not recreated per build")
  Assert.isTrue(storage._sortKeys == keys, "the key buffer is reused across warmed builds")
  Assert.isTrue(storage._sortOrder == order, "the order table is reused across warmed builds")
  Assert.isTrue(storage.blended == blendedArray, "the visible blended array is reused across warmed builds")
  Assert.equal(#storage.blended, 3)
  for index, wrapper in ipairs(storage.blended) do
    Assert.isTrue(wrapper == wrappers[index], "unsorted wrapper " .. index .. " is reused across warmed builds")
  end
  Assert.deepEqual(ids(storage, "blended"), { "first", "mixed-second", "third" })
  for index, original in ipairs(parts[1]) do
    Assert.deepEqual(original, before[index], "caller item " .. index .. " is untouched by warmed rebuilds")
  end

  local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
  local renderer = FieldRenderer.new({
    gxRenderer = { stats = {}, draw = function() end, release = function() end },
  })
  Assert.isTrue(
    type(renderer._queueScratch._sortCompare) == "function"
      and renderer._queueScratch._sortKeys ~= nil
      and renderer._queueScratch._sortOrder ~= nil,
    "the field renderer lifetime scratch carries the queue-owned sort storage"
  )
  local rendererQueue = RenderQueue.buildInto(parts, IDENTITY, ortho, ortho, renderer._queueScratch)
  Assert.deepEqual(ids(rendererQueue, "blended"), { "first", "mixed-second", "third" })
end

-- The battle compositor keeps native submission order for translucent
-- polygons even when their screen extents oppose it, and orders the single
-- shared opaque sequence by clipped native extents. These manual-mode
-- behaviors ride the existing queue scratch without changing the field
-- default: absent options keep automatic Y sorting and the current passes.
function T.manual_scratch_keeps_translucent_submission_order_against_opposing_extents()
  local ortho = orthoProjection()
  local submittedFirst = item("submitted-first", "translucent", { 0, -8, 0 }, nil, {
    sortBounds = bounds(-1, 1, -9, -7, -1, 1),
  })
  local submittedSecond = item("submitted-second", "translucent", { 0, 8, 0 }, nil, {
    sortBounds = bounds(-1, 1, 7, 9, -1, 1),
  })
  local manual = RenderQueue.newScratch({ sortMode = "manual" })
  Assert.isTrue(
    manual ~= nil,
    "the queue admits the battle manual sort mode on its existing scratch"
  )
  local queue = RenderQueue.buildInto({ { submittedFirst, submittedSecond } }, IDENTITY, ortho, ortho, manual)
  Assert.deepEqual(
    ids(queue, "blended"),
    { "submitted-first", "submitted-second" },
    "manual mode preserves native submission order for translucent polygons "
      .. "instead of automatic screen-Y sorting"
  )
end

function T.manual_queue_publishes_one_ordered_opaque_sequence()
  local ortho = orthoProjection()
  local low = item("low-opaque", "opaque", { 0, -6, 0 }, nil, {
    sortBounds = bounds(-1, 1, -7, -5, -1, 1),
  })
  local high = item("high-cutout", "cutout", { 0, 6, 0 }, nil, {
    sortBounds = bounds(-1, 1, 5, 7, -1, 1),
  })
  local manual = RenderQueue.newScratch({ sortMode = "manual" })
  local queue = RenderQueue.buildInto({ { high, low } }, IDENTITY, ortho, ortho, manual)
  Assert.notNil(
    queue.opaqueOrder,
    "manual mode publishes one ordered opaque sequence for the shared 3D pass"
  )
  local ordered = {}
  for _, entry in ipairs(queue.opaqueOrder) do
    ordered[#ordered + 1] = entry.item.id
  end
  Assert.deepEqual(
    ordered,
    { "low-opaque", "high-cutout" },
    "the shared opaque sequence follows native bottom/top extents across classes, "
      .. "not submission order"
  )
end

function T.manual_queue_prefers_clipped_projected_bounds_over_model_boxes()
  local ortho = orthoProjection()
  -- The unprojected model boxes claim boxed-top sits above clipped-bottom,
  -- but the exact clipped native bounds reverse them; the shared opaque
  -- sequence must follow the clipped bounds.
  local clippedBottom = item("clipped-bottom", "opaque", { 0, -8, 0 }, nil, {
    sortBounds = bounds(-1, 1, -9, -7, -1, 1),
    projectedBounds = { topY = 0.8, bottomY = 0.9 },
  })
  local boxedTop = item("boxed-top", "opaque", { 0, 8, 0 }, nil, {
    sortBounds = bounds(-1, 1, 7, 9, -1, 1),
    projectedBounds = { topY = 0.1, bottomY = 0.2 },
  })
  local manual = RenderQueue.newScratch({ sortMode = "manual" })
  local queue = RenderQueue.buildInto({ { clippedBottom, boxedTop } }, IDENTITY, ortho, ortho, manual)
  Assert.notNil(
    queue.opaqueOrder,
    "manual mode publishes one ordered opaque sequence for the shared 3D pass"
  )
  local ordered = {}
  for _, entry in ipairs(queue.opaqueOrder) do
    ordered[#ordered + 1] = entry.item.id
  end
  Assert.deepEqual(
    ordered,
    { "boxed-top", "clipped-bottom" },
    "the shared opaque sequence reads exact clipped native bounds before "
      .. "falling back to the unprojected model box"
  )
end

return { tests = T }
