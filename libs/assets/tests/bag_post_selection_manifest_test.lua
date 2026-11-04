-- Post-selection manifest contract: the generated Bag presentation must
-- publish the layered Action/Quantity/Move backgrounds (one pocket overlay
-- each for action/quantity, count-variant move bases plus the
-- origin-marker patches), the retained selected-item panel, lower-message
-- geometry, activation feedback timing, and move commit clips.

local Assert = require("tests.support.Assert")
local BagAssetSchema = require("libs.assets.src.BagAssetSchema")
local BagPresentationFixture = require("tests.support.BagPresentationFixture")

local T = {}

local function manifest()
  return BagPresentationFixture.manifest()
end

function T.state_backgrounds_share_overlays_and_marker_patches()
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
  local move = assert(backgrounds.move, "the manifest publishes the move background")
  for _, pocket in ipairs(BagAssetSchema.POCKETS) do
    local perPocket = assert(move[pocket], "move covers pocket " .. pocket)
    for count = 0, 6 do
      local base = perPocket[count] or perPocket[tostring(count)]
      Assert.isTrue(
        type(base) == "table" and type(base.image) == "string",
        "move/" .. pocket .. " publishes its count " .. count .. " base"
      )
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
end

function T.selection_panel_messages_and_timing_are_published()
  local manifested = manifest()
  local overlays = assert(manifested.interactive.overlays, "the manifest publishes overlays")
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
  local interactive = assert(manifested.interactive, "the manifest publishes the interactive pane")
  local feedback = assert(interactive.feedback, "the manifest publishes activation feedback")
  Assert.isTrue((feedback.totalTicks or 0) >= 1, "activation feedback carries a positive total")
  local moveTransition = assert(interactive.moveTransition, "the manifest publishes the move commit transition")
  for _, key in ipairs({ "unchanged", "changed" }) do
    local clip = assert(moveTransition[key], "the move transition publishes its " .. key .. " clip")
    Assert.isTrue((clip.totalTicks or 0) >= 1, "the " .. key .. " clip carries a positive total")
  end
end

return { tests = T }
