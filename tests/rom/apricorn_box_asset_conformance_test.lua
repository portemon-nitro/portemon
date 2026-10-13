-- The emitted Box graphics retain pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981
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
  for rowIndex, row in ipairs(bundle.manifest.rows) do
    Assert.equal(row.apricornKey, ROW_KEYS[rowIndex], "visible row has its native Apricorn identity")
    Assert.equal(row.nameMessageId, rowIndex + 6, "visible row points to its native source label")
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
      local width, height = PngReader.rgba(assert(bundle.assets[frame.image]))
      Assert.equal(width, frame.width)
      Assert.equal(height, frame.height)
      Assert.isTrue(width > 0 and height > 0, "sprite frame has visible dimensions")
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
