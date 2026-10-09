local Assert = require("tests.support.Assert")
local DialoguePresentationLayout = require("libs.hgss.src.ui.DialoguePresentationLayout")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local FieldUiFixture = require("tests.support.FieldUiFixture")

local T = {}
local CURSOR_PLACEMENT = FieldUiFixture.manifest().dialogueFrames.continueCursor.placement

function T.computes_centered_bottom_aligned_local_geometry()
  local presentation = DialoguePresentationLayout.compute(
    { x = 37, y = 11, width = 900, height = 420 },
    { cursorPlacement = CURSOR_PLACEMENT }
  )
  Assert.equal(presentation.scale, 3)
  Assert.deepEqual(presentation.origin, { x = 103, y = 287 })
  Assert.deepEqual(presentation.box, { x = 16, y = 8, width = 216, height = 32 })
  Assert.deepEqual(presentation.text, { x = 16, y = 8, width = 216, height = 32 })
  Assert.equal(
    presentation.text.width,
    FieldDialogueTheme.textWidth,
    "presentation text width must match the pagination/theme content width"
  )
  Assert.equal(presentation.text.width, presentation.box.width, "no text width is reserved for the cursor")
  Assert.equal(presentation.lineHeight, FieldDialogueTheme.lineHeight)
  Assert.deepEqual(presentation.outerRect, {
    x = presentation.origin.x,
    y = presentation.origin.y,
    width = 256 * presentation.scale,
    height = 48 * presentation.scale,
  })
end

function T.exact_scale_and_cap_are_validated()
  local exact = DialoguePresentationLayout.compute(
    { x = 0, y = 0, width = 640, height = 480 },
    { scale = 2, cursorPlacement = CURSOR_PLACEMENT }
  )
  Assert.equal(exact.scale, 2)
  local capped = DialoguePresentationLayout.compute(
    { x = 0, y = 0, width = 640, height = 480 },
    { maxScale = 2, cursorPlacement = CURSOR_PLACEMENT }
  )
  Assert.equal(capped.scale, 2)
  Assert.isFalse(pcall(function()
    DialoguePresentationLayout.compute(
      { x = 0, y = 0, width = 100, height = 100 },
      { scale = 1, cursorPlacement = CURSOR_PLACEMENT }
    )
  end))
  Assert.isFalse(
    pcall(function()
      DialoguePresentationLayout.compute(
        { x = 0, y = 0, width = 640, height = 480 },
        { scale = 1.5, cursorPlacement = CURSOR_PLACEMENT }
      )
    end),
    "an explicit fractional raster scale is rejected"
  )
end

function T.one_x_clipping_is_explicit_and_narrow()
  local undersized = { x = 0, y = 0, width = 255, height = 48 }
  Assert.isFalse(
    pcall(function()
      DialoguePresentationLayout.compute(undersized, { scale = 1, cursorPlacement = CURSOR_PLACEMENT })
    end),
    "one-x overflow remains strict without the explicit clipping policy"
  )

  local clipped = DialoguePresentationLayout.compute(undersized, {
    scale = 1,
    allowClipping = true,
    cursorPlacement = CURSOR_PLACEMENT,
  })
  Assert.equal(clipped.scale, 1)
  Assert.equal(clipped.outerRect.width, 256)

  Assert.isFalse(
    pcall(function()
      DialoguePresentationLayout.compute({ x = 0, y = 0, width = 511, height = 95 }, {
        scale = 2,
        allowClipping = true,
        cursorPlacement = CURSOR_PLACEMENT,
      })
    end),
    "the clipping policy cannot authorize a non-fitting scale above one"
  )
end

function T.generated_cursor_placement_maps_to_the_local_strip_without_a_fallback()
  local placement = FieldUiFixture.manifest().dialogueFrames.continueCursor.placement
  for _, bounds in ipairs({
    { x = 37, y = 11, width = 900, height = 420 },
    { x = 0, y = 0, width = 390, height = 844 },
  }) do
    local presentation = DialoguePresentationLayout.compute(bounds, { cursorPlacement = placement })
    Assert.deepEqual(presentation.cursor, { x = 240, y = 24, width = 16, height = 16 })
  end

  Assert.isFalse(
    pcall(function()
      DialoguePresentationLayout.compute({ x = 0, y = 0, width = 640, height = 480 })
    end),
    "missing generated cursor placement must not select a layout fallback"
  )
end

function T.constrained_bounds_keep_native_scale_and_clip_the_raster()
  local bounds = { x = 5, y = 7, width = 200, height = 40 }
  local presentation = DialoguePresentationLayout.compute(bounds, {
    allowClipping = true,
    cursorPlacement = CURSOR_PLACEMENT,
  })
  Assert.equal(presentation.scale, 1, "an undersized host preserves native source pixels")
  Assert.deepEqual(presentation.bounds, bounds)
  Assert.deepEqual(presentation.placement.clipRect, bounds, "only the visible host bounds are painted")
  Assert.equal(presentation.outerRect.width, 256, "the source strip is never minified")
  Assert.equal(presentation.outerRect.height, 48, "the source strip is never minified")
end

return { tests = T }
