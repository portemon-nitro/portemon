-- Neutral first-ROM import card: no edition, loader, or picker chrome.

local Errors = require("libs.errors.src.Errors")
local RomImporter = require("romdump.src.source.RomImporter")

---@class ImportState neutral first-ROM import card state
---@field importer RomImporter verified-ROM importer owned by the shell
---@field saveDir string?
---@field targetVersion string? expected edition for a targeted rebind, never rendered
---@field pickerAvailable boolean native bridge probed usable at construction
---@field onPick fun()? whole-card activation, present only when available
local ImportState = {}
ImportState.__index = ImportState

-- Single centered card geometry shared by drawing and hit-testing, derived
-- from the current drawable size so both stay consistent across resizes.
---@param width number current drawable width
---@param height number current drawable height
---@return number left
---@return number top
---@return number width
---@return number height
local function cardBounds(width, height)
  local cardWidth = math.min(width * 0.8, 480)
  local cardHeight = math.min(height * 0.5, 260)
  return (width - cardWidth) / 2, (height - cardHeight) / 2, cardWidth, cardHeight
end

local function hit(x, y, left, top, width, height)
  return x >= left and x <= left + width and y >= top and y <= top + height
end

---@param importer RomImporter
---@param saveDir string?
---@param options { targetVersion: string?, pickerAvailable: boolean?, onPick: fun()? }?
---@return ImportState
function ImportState.new(importer, saveDir, options)
  options = options or {}
  return setmetatable({
    importer = importer,
    saveDir = saveDir,
    -- Retained only to route file drops into the targeted importer session;
    -- never rendered, so the first card stays edition-neutral.
    targetVersion = options.targetVersion,
    pickerAvailable = options.pickerAvailable == true,
    onPick = options.onPick,
  }, ImportState)
end

function ImportState:update() end

function ImportState:resize() end

function ImportState:dispose() end

function ImportState:filedropped(file)
  self.importer:filedropped(file)
end

-- The picker is armed only when the platform bridge probed usable at screen
-- construction and no import is already running.
---@return boolean
function ImportState:_pickerArmed()
  if not self.pickerAvailable or self.onPick == nil then
    return false
  end
  local importer = self.importer
  if importer ~= nil and type(importer.isBusy) == "function" and importer:isBusy() then
    return false
  end
  return true
end

function ImportState:_openPicker()
  if self:_pickerArmed() then
    self.onPick()
  end
end

---@param key string
---@param isrepeat boolean?
function ImportState:keypressed(key, _, isrepeat)
  if isrepeat then
    return
  end
  if key == "escape" then
    love.event.quit(0)
  elseif key == "return" or key == "kpenter" or key == "space" then
    self:_openPicker()
  end
end

function ImportState:mousepressed(x, y, button)
  if button ~= 1 then
    return
  end
  self:_pointerpressed(x, y)
end

function ImportState:touchpressed(_, x, y)
  self:_pointerpressed(x, y)
end

function ImportState:_pointerpressed(x, y)
  local width, height = love.graphics.getDimensions()
  local left, top, cardWidth, cardHeight = cardBounds(width, height)
  if hit(x, y, left, top, cardWidth, cardHeight) then
    self:_openPicker()
  end
end

function ImportState:draw()
  local lg = love.graphics
  local width, height = lg.getDimensions()
  lg.setColor(0.055, 0.09, 0.13, 1)
  lg.rectangle("fill", 0, 0, width, height)

  local left, top, cardWidth, cardHeight = cardBounds(width, height)
  lg.setColor(0.10, 0.16, 0.20, 1)
  lg.rectangle("fill", left, top, cardWidth, cardHeight, 12, 12)
  lg.setColor(0.35, 0.55, 0.58, 1)
  lg.rectangle("line", left, top, cardWidth, cardHeight, 12, 12)

  local textX, textWidth = left + 16, cardWidth - 32
  lg.setColor(0.94, 0.94, 0.9, 1)
  lg.printf("Import a Pokémon ROM", textX, top + cardHeight * 0.14, textWidth, "center")
  lg.setColor(0.7, 0.78, 0.8, 1)
  if self.pickerAvailable then
    lg.printf(
      "Drop a supported .nds or .zip file anywhere on this card.",
      textX,
      top + cardHeight * 0.32,
      textWidth,
      "center"
    )
    lg.printf(
      "Click the card or press Return to browse for a file.",
      textX,
      top + cardHeight * 0.50,
      textWidth,
      "center"
    )
  else
    lg.printf(
      "Drop a supported .nds or .zip file onto this window to import it.",
      textX,
      top + cardHeight * 0.36,
      textWidth,
      "center"
    )
  end

  local status = self.importer:status()
  local s = RomImporter.STATES
  if status.state == s.ERROR then
    lg.setColor(1, 0.58, 0.53, 1)
    lg.printf(
      "Import failed [" .. tostring(status.errorCode or "ERROR") .. "]: " .. Errors.format(status.error),
      textX,
      top + cardHeight * 0.72,
      textWidth,
      "center"
    )
  elseif status.state == s.REGISTERING then
    lg.setColor(0.8, 0.9, 0.78, 1)
    lg.printf(
      (status.stageLabel or "Checking ROM") .. "  " .. tostring(math.floor((status.progress or 0) * 100 + 0.5)) .. "%",
      textX,
      top + cardHeight * 0.72,
      textWidth,
      "center"
    )
  elseif status.state == s.READING then
    lg.setColor(0.8, 0.9, 0.78, 1)
    lg.printf("Reading the selected file…", textX, top + cardHeight * 0.72, textWidth, "center")
  elseif status.state == s.VERIFYING then
    lg.setColor(0.8, 0.9, 0.78, 1)
    lg.printf("Verifying cartridge identity…", textX, top + cardHeight * 0.72, textWidth, "center")
  elseif status.state == s.COMPLETE then
    lg.setColor(0.8, 0.9, 0.78, 1)
    lg.printf("ROM accepted.", textX, top + cardHeight * 0.72, textWidth, "center")
  end
end

-- Stateless continuation renderer for a fresh import whose source
-- registration finished but whose mandatory first-play preparation is still
-- pending.
---@param facts { status: table<string, unknown>, saveDir: string? }
---@param preparationStatus table<string, unknown>?
---@param failure unknown?
function ImportState.renderContinuation(facts, preparationStatus, failure)
  local lg = love.graphics
  local importStatus = facts.status
  local x, y = 24, 24
  lg.setColor(1, 1, 1)
  lg.print("portemon — HeartGold / SoulSilver ROM import", x, y)
  lg.setColor(0.7, 0.7, 0.75)
  lg.print("Drop a matching .nds or .zip file onto this window to import it.", x, y + 28)
  if facts.saveDir ~= nil then
    lg.print("Private cache is written under:", x, y + 52)
    lg.print(tostring(facts.saveDir), x, y + 72)
  end

  y = y + 116
  lg.setColor(0.85, 0.9, 0.95)
  if importStatus.sourceName ~= nil then
    lg.print("File:   " .. tostring(importStatus.sourceName), x, y)
  end
  if importStatus.displayName ~= nil then
    lg.print("Target: " .. tostring(importStatus.displayName), x, y + 20)
  end

  if failure ~= nil then
    lg.setColor(1, 0.5, 0.5)
    lg.print("First-play preparation failed:", x, y + 48)
    lg.printf(tostring(failure), x, y + 72, lg.getWidth() - 48)
    lg.setColor(0.7, 0.7, 0.75)
    lg.print("Press escape to return.", x, y + 120)
    return
  end

  lg.setColor(0.6, 0.9, 0.6)
  lg.print("Import complete.", x, y + 48)
  lg.setColor(1, 1, 1)
  lg.print("Preparing imported ROM for first play...", x, y + 76)
  if type(preparationStatus) == "table" then
    lg.setColor(0.7, 0.7, 0.75)
    lg.print(
      string.format(
        "ready %d  queued %d  running %d",
        preparationStatus.ready or 0,
        preparationStatus.queued or 0,
        preparationStatus.running or 0
      ),
      x,
      y + 100
    )
  end
  lg.setColor(0.7, 0.7, 0.75)
  lg.print("Press escape to cancel.", x, y + 124)
end

return ImportState
