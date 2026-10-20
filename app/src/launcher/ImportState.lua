-- ROM-independent import entry and progress presentation.

local Errors = require("libs.errors.src.Errors")
local RomImporter = require("romdump.src.source.RomImporter")

local ImportState = {}
ImportState.__index = ImportState

local function hit(x, y, left, top, width, height)
  return x >= left and x <= left + width and y >= top and y <= top + height
end

function ImportState.new(importer, saveDir, options)
  options = options or {}
  return setmetatable({
    importer = importer,
    saveDir = saveDir,
    targetVersion = options.targetVersion,
    pickerError = options.pickerError,
    onPick = options.onPick,
    onSwitchEdition = options.onSwitchEdition,
  }, ImportState)
end

function ImportState:update(_) end

function ImportState:filedropped(file)
  self.importer:filedropped(file)
end

function ImportState:_openPicker()
  if self.onPick then
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
  elseif key == "tab" and self.onSwitchEdition then
    self.onSwitchEdition()
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
  local buttonWidth = math.min(width * 0.72, 420)
  local buttonHeight = math.max(64, math.min(height * 0.14, 84))
  local buttonX = (width - buttonWidth) / 2
  local buttonY = height * 0.5
  if hit(x, y, buttonX, buttonY, buttonWidth, buttonHeight) then
    self:_openPicker()
    return
  end

  local switchWidth, switchHeight = math.min(width * 0.7, 300), 50
  local switchX, switchY = (width - switchWidth) / 2, height * 0.78
  if self.onSwitchEdition and hit(x, y, switchX, switchY, switchWidth, switchHeight) then
    self.onSwitchEdition()
  end
end

function ImportState:draw()
  ImportState.render(self.importer:status(), self.saveDir, {
    targetVersion = self.targetVersion,
    pickerError = self.pickerError,
    onSwitchEdition = self.onSwitchEdition ~= nil,
  })
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

-- Stateless renderer driven by an importer status snapshot. `saveDir` may be nil.
function ImportState.render(status, saveDir, options)
  options = options or {}
  local lg = love.graphics
  local width, height = lg.getDimensions()
  local compact = width < 420 or height < 420
  local centerX = width / 2
  local title = options.targetVersion == "heartgold" and "Import HeartGold ROM"
    or options.targetVersion == "soulsilver" and "Import SoulSilver ROM"
    or "Bring your Pokémon game"

  lg.setColor(0.055, 0.09, 0.13, 1)
  lg.rectangle("fill", 0, 0, width, height)
  lg.setColor(0.13, 0.22, 0.28, 1)
  lg.circle("fill", centerX, height * 0.2, math.min(width, height) * 0.19)
  lg.setColor(0.86, 0.7, 0.38, 1)
  lg.circle("line", centerX, height * 0.2, math.min(width, height) * 0.19)
  lg.setColor(0.83, 0.88, 0.86, 1)
  lg.setLineWidth(3)
  lg.line(centerX - 34, height * 0.2, centerX + 34, height * 0.2)
  lg.circle("fill", centerX, height * 0.2, 9)

  lg.setColor(0.94, 0.94, 0.9, 1)
  lg.printf(title, 20, height * 0.34, width - 40, "center")
  lg.setColor(0.7, 0.78, 0.8, 1)
  lg.printf("Drop a supported .nds or .zip ROM here, or choose a file.", 20, height * 0.4, width - 40, "center")

  local buttonWidth = math.min(width * 0.72, 420)
  local buttonHeight = math.max(64, math.min(height * 0.14, 84))
  local buttonX, buttonY = centerX - buttonWidth / 2, height * 0.5
  lg.setColor(0.2, 0.42, 0.44, 1)
  lg.rectangle("fill", buttonX, buttonY, buttonWidth, buttonHeight, 14, 14)
  lg.setColor(0.9, 0.83, 0.6, 1)
  lg.rectangle("line", buttonX, buttonY, buttonWidth, buttonHeight, 14, 14)
  lg.setColor(1, 1, 1, 1)
  lg.printf("Choose ROM file", buttonX + 8, buttonY + buttonHeight * 0.35, buttonWidth - 16, "center")

  if options.onSwitchEdition then
    lg.setColor(0.76, 0.82, 0.82, 1)
    lg.printf("Switch edition", centerX - 150, height * 0.8, 300, "center")
  end

  local s = RomImporter.STATES
  if options.pickerError ~= nil then
    lg.setColor(1, 0.72, 0.55, 1)
    lg.printf(tostring(options.pickerError), 18, height * 0.87, width - 36, "center")
  elseif status.state == s.ERROR then
    lg.setColor(1, 0.58, 0.53, 1)
    lg.printf(
      "Import failed [" .. tostring(status.errorCode or "ERROR") .. "]: " .. Errors.format(status.error),
      18,
      height * 0.84,
      width - 36,
      "center"
    )
  elseif status.state == s.REGISTERING then
    lg.setColor(0.8, 0.9, 0.78, 1)
    lg.printf(
      (status.stageLabel or "Checking ROM") .. "  " .. tostring(math.floor((status.progress or 0) * 100 + 0.5)) .. "%",
      18,
      height * 0.85,
      width - 36,
      "center"
    )
  elseif status.state == s.READING or status.state == s.VERIFYING then
    lg.setColor(0.8, 0.9, 0.78, 1)
    lg.printf(
      status.state == s.READING and "Reading the selected file…" or "Verifying cartridge identity…",
      18,
      height * 0.85,
      width - 36,
      "center"
    )
  elseif status.state == s.COMPLETE then
    lg.setColor(0.8, 0.9, 0.78, 1)
    lg.printf("ROM accepted. Preparing the game…", 18, height * 0.85, width - 36, "center")
  end

  lg.setColor(0.62, 0.69, 0.71, 1)
  local instructionY = compact and height - 28 or height - 42
  lg.printf(
    "Drag and drop also works" .. (saveDir and ("  ·  Data stays in " .. saveDir) or ""),
    16,
    instructionY,
    width - 32,
    "center"
  )
end

return ImportState
