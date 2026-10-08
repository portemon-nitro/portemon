-- Single-pane dock composition across every selected application frame:
-- all twenty generated frame styles address the fixed compact content
-- boxes through the real theme geometry, text origins stay clear of the
-- cap-overlap rows, and the resolved single-pane plan carries the same
-- boxes the frames draw. Frame entries and insets come from the prepared
-- versioned cache and the real dialogue theme; no bytes are committed.

local Assert = require("tests.support.Assert")
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local BattleScreenInterface = require("game.hgss.src.battle.BattleScreenInterface")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = { "field-ui:global" },
  },
  tests = {},
}

-- The fixed single-pane content boxes every dock mode draws through the
-- shared application border, with the outer allocation each derives from.
local DOCK_BOXES = {
  {
    name = "prompt",
    outer = { x = 0, y = 136, width = 112, height = 56 },
    content = { x = 8, y = 144, width = 96, height = 40 },
  },
  {
    name = "commands",
    outer = { x = 112, y = 136, width = 144, height = 56 },
    content = { x = 120, y = 144, width = 128, height = 40 },
  },
  {
    name = "moves",
    outer = { x = 0, y = 120, width = 192, height = 72 },
    content = { x = 8, y = 128, width = 176, height = 56 },
  },
  {
    name = "move-info",
    outer = { x = 192, y = 120, width = 64, height = 72 },
    content = { x = 200, y = 128, width = 48, height = 56 },
  },
  {
    name = "target",
    outer = { x = 0, y = 120, width = 256, height = 72 },
    content = { x = 8, y = 128, width = 240, height = 56 },
  },
  {
    name = "narration",
    outer = { x = 0, y = 136, width = 256, height = 56 },
    content = { x = 8, y = 144, width = 240, height = 40 },
  },
}

-- Text origins drawn inside the compact docks: the question, the command
-- labels right of their cursor columns, the move grid labels, the
-- information rows, and the narration line.
local TEXT_ORIGINS = {
  { x = 12, y = 146, box = "prompt" },
  { x = 128, y = 146, box = "commands" },
  { x = 192, y = 146, box = "commands" },
  { x = 128, y = 166, box = "commands" },
  { x = 192, y = 166, box = "commands" },
  { x = 16, y = 134, box = "moves" },
  { x = 104, y = 162, box = "moves" },
  { x = 202, y = 130, box = "move-info" },
  { x = 202, y = 148, box = "move-info" },
  { x = 12, y = 146, box = "narration" },
}

---@param context table? runner context carrying capability queries
---@return string[] ready version identities with a validated field-UI manifest
local function readyVersions(context)
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cacheFs = CacheFs.forVersion(versionId)
      local marker = cacheFs:read(FieldUiAssetCache.markerPath())
      if marker ~= nil and FieldUiAssetCache.isReady(cacheFs, marker) then
        versions[#versions + 1] = versionId
      end
    end
  end
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared field-ui assets")
    end
    error("the frame composition check needs a ready versioned field-UI cache", 0)
  end
  return versions
end

---@param context table? runner context under test driving
---@return table internal command snapshot for the single-pane resolver
local function commandSnapshot()
  return {
    mode = "command",
    selection = "fight",
    armed = nil,
    requestId = 7,
    message = "What will MINT do?",
    messageId = 1,
    battlers = {
      { combatant = 1, side = 1, hp = 52, maxHp = 52, visible = true, name = "LEAD", level = 20, shakeDx = 0 },
      { combatant = 3, side = 2, hp = 57, maxHp = 57, visible = true, name = "FOE", level = 20, shakeDx = 0 },
    },
    commands = {
      { id = "fight", enabled = true },
      { id = "bag", enabled = true },
      { id = "pokemon", enabled = true },
      { id = "run", enabled = true },
    },
    moves = {},
    partyRoster = {
      { slot = 0, hp = 52, maxHp = 52 },
    },
    foeCount = 1,
    arrowFrame = 0,
    childIntent = nil,
  }
end

-- Every selected frame style composes the compact docks: the generated
-- manifest carries all twenty frame entries, the real theme insets derive
-- each fixed content box from its outer allocation, the real tile
-- placements accept every box and stay inside their own panel bands, text
-- origins clear the cap-overlap rows, and the resolved single-pane plan
-- carries the same boxes the shared border draws.
function T.tests.every_selected_frame_addresses_the_compact_docks(context)
  for _, versionId in ipairs(readyVersions(context)) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = cacheFs:loadLua(FieldUiAssetCache.manifestPath())
    local frames = assert(manifest.dialogueFrames, "the field-UI manifest carries its dialogue frames: " .. versionId)
    Assert.equal(frames.count, 20, "the generated set carries all twenty frame styles: " .. versionId)
    for index = 0, frames.count - 1 do
      Assert.notNil(
        frames.frameTiles[index],
        "frame " .. tostring(index) .. " stays addressable to the shared border: " .. versionId
      )
    end
    local insets = FieldDialogueTheme.applicationFrameInsets()
    local boxes = {}
    for _, dock in ipairs(DOCK_BOXES) do
      local derived = {
        x = dock.outer.x + insets.left,
        y = dock.outer.y + insets.top + 1,
        width = dock.outer.width - insets.left - insets.right,
        height = dock.outer.height - insets.top - insets.bottom - 2,
      }
      Assert.equal(derived.x, dock.content.x, dock.name .. " keeps its left edge: " .. versionId)
      Assert.equal(derived.y, dock.content.y, dock.name .. " keeps its top edge: " .. versionId)
      Assert.equal(derived.width, dock.content.width, dock.name .. " keeps its width: " .. versionId)
      Assert.equal(derived.height, dock.content.height, dock.name .. " keeps its height: " .. versionId)
      boxes[dock.name] = dock.content
      local placements = FieldDialogueTheme.applicationFrameTilePlacements(dock.content)
      for _, group in ipairs({ placements.top, placements.sides, placements.bottom }) do
        for _, placement in ipairs(group) do
          Assert.isTrue(
            placement.x >= dock.outer.x - 8 and placement.x + 8 <= dock.outer.x + dock.outer.width + 8,
            dock.name .. " border tiles stay on their own panel band: " .. versionId
          )
          Assert.isTrue(
            placement.y >= dock.outer.y - 8 and placement.y + 8 <= dock.outer.y + dock.outer.height + 8,
            dock.name .. " cap tiles stay on their own dock band: " .. versionId
          )
        end
      end
    end
    -- Neighboring panel bands stay legitimate borders: the prompt border
    -- never reaches into the command content and vice versa.
    Assert.isTrue(
      boxes.prompt.x + boxes.prompt.width <= boxes.commands.x - 8,
      "the prompt border band stops before the command content: " .. versionId
    )
    for _, origin in ipairs(TEXT_ORIGINS) do
      local box = assert(boxes[origin.box], "the text origin names its dock box")
      Assert.isTrue(origin.y >= box.y + 2, "text stays two pixels below the cap-overlap row: " .. versionId)
      Assert.isTrue(
        origin.y + 16 <= box.y + box.height - 1,
        "text stays above the bottom cap-overlap row: " .. versionId
      )
    end
    local session = ApplicationPresentation.new(BattleScreenInterface.defaults(), nil)
    local plan = session:resolve({
      width = 256,
      height = 192,
      topology = ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 256, height = 192 },
        touch = true,
        role = "world",
      }),
      pixelRatio = 1,
      signature = "single-pane-frames-test:" .. versionId,
    }, commandSnapshot())
    Assert.isNil(
      plan.content.pendingAdapter,
      "the single-surface battle needs its single-pane composition, not the pending adapter: " .. versionId
    )
    Assert.isTrue(plan.content.compact == true, "the resolved plan is the compact composition: " .. versionId)
    Assert.equal(
      plan.content.prompt.content.x,
      boxes.prompt.x,
      "the plan prompts through the framed box: " .. versionId
    )
    Assert.equal(
      plan.content.prompt.content.y,
      boxes.prompt.y,
      "the plan prompts through the framed rows: " .. versionId
    )
    Assert.equal(
      plan.content.commands.content.width,
      boxes.commands.width,
      "the plan commands through the framed box: " .. versionId
    )
    Assert.equal(
      plan.content.commands.content.height,
      boxes.commands.height,
      "the plan commands through the framed rows: " .. versionId
    )
  end
end

return T
