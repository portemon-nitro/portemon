-- Post-selection manifest contract: the generated Bag presentation must
-- publish the layered Action/Quantity/Move backgrounds (one pocket overlay
-- each for action/quantity over the shared browse base, count-variant move
-- bases plus the origin-marker patches), the retained selected-item panel,
-- lower-message geometry, activation feedback timing, and move commit clips
-- under the strict v19 schema with no standalone confirmation background.

local Assert = require("tests.support.Assert")
local BagAssetSchema = require("libs.assets.src.BagAssetSchema")
local BagPresentationFixture = require("tests.support.BagPresentationFixture")

local T = {}

local function manifest()
  return BagPresentationFixture.manifest()
end

function T.schema_identity_is_strictly_v19()
  Assert.equal(BagAssetSchema.SCHEMA, "g4-bag-assets-v19", "the generated contract carries the current identity")
  Assert.equal(manifest().schema, "g4-bag-assets-v19", "the published manifest carries the current identity")
end

function T.action_and_quantity_backgrounds_share_one_overlay_per_pocket()
  local backgrounds = assert(manifest().interactive.backgrounds, "the manifest publishes backgrounds")
  for _, state in ipairs({ "actionOverlay", "quantityOverlay" }) do
    local overlays = assert(backgrounds[state], "the manifest publishes the " .. state)
    for _, pocket in ipairs(BagAssetSchema.POCKETS) do
      local overlay = assert(overlays[pocket], state .. " covers pocket " .. pocket)
      Assert.isTrue(
        type(overlay) == "table" and type(overlay.image) == "string",
        state .. "/" .. pocket .. " publishes one overlay shared across every visible count"
      )
    end
  end
  Assert.isNil(backgrounds.action, "no baked per-count action background survives")
  Assert.isNil(backgrounds.quantity, "no baked per-count quantity background survives")
end

function T.move_backgrounds_carry_count_bases_and_origin_marker_patches()
  local backgrounds = assert(manifest().interactive.backgrounds, "the manifest publishes backgrounds")
  local move = assert(backgrounds.move, "the manifest publishes the move background")
  for _, pocket in ipairs(BagAssetSchema.POCKETS) do
    local perPocket = assert(move[pocket], "move covers pocket " .. pocket)
    for count = 0, 6 do
      local base = perPocket[count] or perPocket[tostring(count)]
      Assert.isTrue(
        type(base) == "table" and type(base.image) == "string",
        "move/" .. pocket .. " publishes its count " .. count .. " base without baked origins"
      )
      Assert.isNil(base.none, "move bases carry no origin-absent sub-variant")
    end
  end
  local marker = assert(backgrounds.moveMarker, "the manifest publishes the move origin marker")
  for _, pocket in ipairs(BagAssetSchema.POCKETS) do
    local patches = assert(marker.images[pocket], "the marker covers pocket " .. pocket)
    for _, band in ipairs({ "low", "high" }) do
      local patch = assert(patches[band], "the marker publishes the " .. band .. " band")
      Assert.equal(patch.width, 128, "marker patches are one row wide")
      Assert.equal(patch.height, 48, "marker patches are one row tall")
    end
  end
  Assert.equal(#marker.rects, 6, "the marker publishes all six origin rects")
  Assert.isNil(backgrounds.confirmation, "no standalone confirmation background survives")
end

function T.selected_item_panel_and_lower_message_geometry_are_published()
  local overlays = assert(manifest().interactive.overlays, "the manifest publishes overlays")
  local panel = assert(overlays.selectedItem, "the manifest publishes the retained selected-item panel")
  Assert.deepEqual(panel.iconCenter, { x = 86, y = 76 }, "the selected icon keeps its canonical center")
  Assert.deepEqual(
    panel.textRect,
    { x = 96, y = 56, width = 88, height = 32 },
    "the selected row keeps its text window"
  )
  local messages = assert(overlays.messages, "the manifest publishes lower-message geometry")
  Assert.deepEqual(
    messages.selected.contentRect,
    { x = 16, y = 8, width = 216, height = 16 },
    "action/move messages use the short framed window"
  )
  Assert.deepEqual(
    messages.modal.contentRect,
    { x = 16, y = 8, width = 216, height = 32 },
    "toss confirmation/result messages use the tall framed window"
  )
end

function T.feedback_and_move_transition_timing_are_published()
  local interactive = assert(manifest().interactive, "the manifest publishes the interactive pane")
  local feedback = assert(interactive.feedback, "the manifest publishes activation feedback")
  Assert.isTrue((feedback.totalTicks or 0) >= 1, "activation feedback carries a positive total")
  local moveTransition = assert(interactive.moveTransition, "the manifest publishes the move commit transition")
  for _, key in ipairs({ "unchanged", "changed" }) do
    local clip = assert(moveTransition[key], "the move transition publishes its " .. key .. " clip")
    Assert.isTrue((clip.totalTicks or 0) >= 1, "the " .. key .. " clip carries a positive total")
  end
end

function T.strict_validation_rejects_the_previous_manifest_shape()
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest()), "the current fixture validates once the contract lands")
  local incomplete = manifest()
  incomplete.interactive.backgrounds.move = nil
  Assert.isFalse(BagAssetSchema.isValidManifest(incomplete), "a manifest without move variants is not ready")
  local legacy = manifest()
  legacy.schema = "g4-bag-assets-v13"
  Assert.isFalse(BagAssetSchema.isValidManifest(legacy), "the previous schema identity is rejected")
end

return { tests = T }
