-- The emitted Box graphics retain the retail ROM's
-- source geometry and bank 21 labels while carrying visible pixels.

local Assert = require("tests.support.Assert")
local PngReader = require("tests.support.PngReader")
local ApricornBoxAssetCompiler = require("romdump.src.digest.ui.ApricornBoxAssetCompiler")
local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
local ApricornBoxSources = require("romdump.src.config.ApricornBoxSources")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}
local compiled = {}
local ROW_KEYS = {
  "RED_APRICORN",
  "YLW_APRICORN",
  "BLU_APRICORN",
  "GRN_APRICORN",
  "PNK_APRICORN",
  "WHT_APRICORN",
  "BLK_APRICORN",
}
local ROW_LABELS =
  { "Red Apricorn", "Ylw Apricorn", "Blu Apricorn", "Grn Apricorn", "Pnk Apricorn", "Wht Apricorn", "Blk Apricorn" }

local function bundleFor(romFs, versionId)
  if compiled[versionId] == nil then
    compiled[versionId] = ApricornBoxAssetCompiler.compile(romFs)
  end
  return assert(compiled[versionId])
end

function T.box_panes_and_row_animation_frames_are_source_backed(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  Assert.equal(bundle.manifest.messageBankId, 21)
  local session = FieldMessageCompiler.newSession(romFs)
  local messageBundle = assert(session:compileBank(21))
  session:close()
  local paneNames = { "upper", "lower" }
  for _, paneName in ipairs(paneNames) do
    local pane = bundle.manifest[paneName]
    local width, height, rgba = PngReader.rgba(assert(bundle.assets[pane.image]))
    Assert.equal(width, 256, paneName .. " pane has native width")
    Assert.equal(height, 192, paneName .. " pane crops the 256x256 source screen to the visible display")
    Assert.equal(pane.width, width)
    Assert.equal(pane.height, height)
    local opaque = false
    for pixel = 4, #rgba, 4 do
      if string.byte(rgba, pixel) ~= 0 then
        opaque = true
        break
      end
    end
    Assert.isTrue(opaque, paneName .. " pane contains visible source pixels")
  end
  Assert.equal(#bundle.manifest.rows, 7)
  Assert.deepEqual(bundle.manifest.controls.sourceTable, ApricornBoxSources.geometry.touchMenu.sourceTable)
  Assert.deepEqual(bundle.manifest.actionMessageIds, ApricornBoxSources.messages.actionLabels)
  local actionMenu = bundle.manifest.actionMenu
  local menuWidth, menuHeight, menuPixels = PngReader.rgba(assert(bundle.assets[actionMenu.image]))
  Assert.equal(menuWidth, 216, "the source action control emits the 27 local NCGR tiles")
  Assert.equal(menuHeight, 8)
  local menuVisible = false
  for alpha = 4, #menuPixels, 4 do
    if string.byte(menuPixels, alpha) > 0 then
      menuVisible = true
      break
    end
  end
  Assert.isTrue(menuVisible, "NARC165 provides visible native rounded list-menu art")
  Assert.equal(bundle.manifest.pluralBankId, 224, "the confirm plural names resolve through bank 224")
  local ROW_ITEM_IDS = { 485, 486, 487, 488, 489, 490, 491 }
  for rowIndex, row in ipairs(bundle.manifest.rows) do
    Assert.equal(row.apricornKey, ROW_KEYS[rowIndex], "visible row has its native Apricorn identity")
    Assert.equal(row.nameMessageId, rowIndex + 6, "visible row points to its native source label")
    Assert.equal(
      row.itemId,
      ROW_ITEM_IDS[rowIndex],
      "visible row carries its native item identity for plural lookup"
    )
    Assert.equal(messageBundle.bank.messages[row.nameMessageId].text, ROW_LABELS[rowIndex])
    local source = ApricornBoxSources.geometry.rowIcons[rowIndex]
    Assert.equal(row.icon.x, source.x)
    Assert.equal(row.icon.y, source.y)
    local hitbox = bundle.manifest.rowHitboxes[rowIndex]
    local sourceHitbox = ApricornBoxSources.geometry.rowHitboxes[rowIndex]
    Assert.equal(hitbox.x, sourceHitbox.x)
    Assert.equal(hitbox.y, sourceHitbox.y)
    Assert.equal(hitbox.radius, sourceHitbox.radius)
    local countWindow = row.quantity.window
    local sourceCountWindow = ApricornBoxSources.geometry.countWindows[rowIndex]
    Assert.equal(countWindow.x, sourceCountWindow.x)
    Assert.equal(countWindow.y, sourceCountWindow.y)
    Assert.equal(countWindow.width, sourceCountWindow.width)
    Assert.equal(countWindow.height, sourceCountWindow.height)
    Assert.equal(row.icon.playMode, "forward_loop")
    Assert.isTrue(#row.icon.frames > 0, "source animation " .. source.animation .. " contains frames")
    for _, frame in ipairs(row.icon.frames) do
      local width, height, rgba = PngReader.rgba(assert(bundle.assets[frame.image]))
      Assert.equal(width, frame.width)
      Assert.equal(height, frame.height)
      Assert.isTrue(width > 0 and height > 0, "sprite frame has visible dimensions")
    end
    -- Each row keeps its source cell palette: at least one sprite pixel
    -- must be chromatic, never the grayscale chrome ramp. Exact palette
    -- values stay with the compiler; here any saturated pixel proves the
    -- cell tint survived compilation.
    local tinted = false
    for _, frame in ipairs(row.icon.frames) do
      local _, _, rgba = PngReader.rgba(assert(bundle.assets[frame.image]))
      for pixel = 1, #rgba - 3, 4 do
        local red, green, blue, alpha = string.byte(rgba, pixel, pixel + 3)
        if alpha > 0 then
          local spread = math.max(red, green, blue) - math.min(red, green, blue)
          if spread >= 48 then
            tinted = true
            break
          end
        end
      end
      if tinted then
        break
      end
    end
    Assert.isTrue(tinted, "row " .. rowIndex .. " keeps its source cell palette tint")
  end
  local panel = assert(bundle.manifest.quantityPanel, "the Kurt quantity panel is compiled")
  local panelWidth, panelHeight, panelRgba = PngReader.rgba(assert(bundle.assets[panel.image]))
  Assert.equal(panelWidth, 256, "the quantity panel covers one native display")
  Assert.equal(panelHeight, 192, "the quantity panel crops to the visible display")
  Assert.equal(panel.width, panelWidth)
  Assert.equal(panel.height, panelHeight)
  local panelVisible = false
  for alpha = 4, #panelRgba, 4 do
    if string.byte(panelRgba, alpha) > 0 then
      panelVisible = true
      break
    end
  end
  Assert.isTrue(panelVisible, "NARC 220 member 6 carries the visible quantity panel")
  for _, sequenceId in ipairs({ 24, 25, 26, 27, 28, 29, 30, 31 }) do
    local state = assert(
      bundle.manifest.selectionCursor.states[sequenceId],
      "quantity chrome sequence " .. sequenceId .. " is compiled"
    )
    Assert.isTrue(#state.frames > 0, "quantity chrome sequence " .. sequenceId .. " contains frames")
    for _, frame in ipairs(state.frames) do
      local width, height, rgba = PngReader.rgba(assert(bundle.assets[frame.image]))
      Assert.equal(width, frame.width)
      Assert.equal(height, frame.height)
      local frameVisible = false
      for alpha = 4, #rgba, 4 do
        if string.byte(rgba, alpha) > 0 then
          frameVisible = true
          break
        end
      end
      Assert.isTrue(frameVisible, "quantity chrome sequence " .. sequenceId .. " has visible pixels")
    end
  end
  local cursor = bundle.manifest.selectionCursor
  local cursorWidth, cursorHeight, cursorPixels = PngReader.rgba(assert(bundle.assets[cursor.image]))
  Assert.equal(cursorWidth, cursor.width)
  Assert.equal(cursorHeight, cursor.height)
  local cursorVisible = false
  for alpha = 4, #cursorPixels, 4 do
    if string.byte(cursorPixels, alpha) > 0 then
      cursorVisible = true
      break
    end
  end
  Assert.isTrue(cursorVisible, "the source default sprite sequence provides visible selection feedback")
end

return RomSuite.fromFacts(T)
