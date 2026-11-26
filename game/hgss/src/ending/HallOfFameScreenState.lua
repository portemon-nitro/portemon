-- The source PC's Hall of Fame showcase: the blocking child the PC shell opens
-- (ScrCmd_OpenHallOfFameShowcase, src/scrcmd_c.c) over the saved history. The
-- child snapshots the recorded clears once when it opens, so navigating and
-- closing can never observe a party that changed while it ran, and it owns only
-- the selection: the history bucket and the live party stay with their owners.
--
-- Source reading order: the newest recorded clear first, its whole party as one
-- team page, then one framed member page per party slot (record number, local
-- date, species, level, nickname and OT name). Cancel walks one page back and
-- closes from the first one.

---@class HallOfFameScreenState
---@field private records table<string, unknown>[] newest first
---@field private total integer recorded-clear sequence
---@field private recordIndex0 integer zero-based recency of the open clear
---@field private monIndex0 integer|nil selected party slot, nil for the team page
---@field private closed boolean
---@field private resultTaken boolean
---@field private disposed boolean
---@field private presentation HallOfFamePresentation
local HallOfFameScreenState = {}
HallOfFameScreenState.__index = HallOfFameScreenState

-- The showcase app reads history only, but its pages draw the prepared bundle
-- and the recorded party's own icons: input stays gated until the
-- presentation admits every drawn dependency, so the player never navigates
-- or closes a surface it has not seen.

-- The source's own record paging: the team page, then one page per recorded
-- party member.
---@param request table<string, unknown> the host request
---@param options { hallOfFame: HallOfFameState, presentation: HallOfFamePresentation }
---@return HallOfFameScreenState
function HallOfFameScreenState.new(request, options)
  assert(type(request) == "table", "Hall of Fame child request is a record")
  assert(request.mode == nil, "the Hall of Fame showcase takes no application mode")
  local history = assert(options.hallOfFame, "the Hall of Fame showcase needs the saved history")
  local records = {}
  for index = 0, history:count() - 1 do
    records[#records + 1] = assert(history:record(index), "a retained record reads back by value")
  end
  return setmetatable({
    records = records,
    total = history:total(),
    recordIndex0 = 0,
    monIndex0 = nil,
    closed = false,
    resultTaken = false,
    disposed = false,
    presentation = assert(options.presentation, "the Hall of Fame showcase needs its presentation"),
  }, HallOfFameScreenState)
end

---@return table<string, unknown>|nil the open record
function HallOfFameScreenState:_record()
  return self.records[self.recordIndex0 + 1]
end

---@return integer the source's record number for the open clear
function HallOfFameScreenState:_recordNumber()
  return self.total - self.recordIndex0
end

---@param events table[] fixed-tick input events
function HallOfFameScreenState:updateFixed(events)
  assert(not self.disposed, "disposed Hall of Fame showcase cannot update")
  if self.closed then
    return
  end
  for _, event in ipairs(events) do
    if event.type == "cancel" then
      if self.monIndex0 ~= nil then
        self.monIndex0 = nil
      else
        self.closed = true
        return
      end
    elseif event.type == "confirm" and self.monIndex0 == nil then
      local record = assert(self:_record())
      if #record.party > 0 then
        self.monIndex0 = 0
      end
    elseif event.type == "navigate" then
      self:_navigate(event.direction)
    end
  end
end

---@param direction string
function HallOfFameScreenState:_navigate(direction)
  local record = assert(self:_record())
  local forward = direction == "right" or direction == "down"
  local backward = direction == "left" or direction == "up"
  if self.monIndex0 ~= nil then
    if forward then
      self.monIndex0 = math.min(self.monIndex0 + 1, #record.party - 1)
    elseif backward then
      self.monIndex0 = math.max(self.monIndex0 - 1, 0)
    end
    return
  end
  -- The team page pages through recorded clears, newest first.
  if forward then
    self.recordIndex0 = math.min(self.recordIndex0 + 1, #self.records - 1)
  elseif backward then
    self.recordIndex0 = math.max(self.recordIndex0 - 1, 0)
  end
end

-- Prepares the showcase's presented dependencies through the one feature-local
-- path the League ending shares: the semantic ending demand's terminal
-- receipt, then the generated bundle's validation plus every published image
-- the presented phase draws, then the recorded party's own icon pages.
-- Pending stays pending with no failure; a terminal demand failure, a
-- malformed bundle, a missing image, or an icon demand failure attributes
-- its failure. Ready is published only after validation and the actually
-- required draw resources are admitted.
---@param env { cacheFs: table<string, unknown>|nil, icons: table<string, unknown>|nil, monCatalog: table<string, unknown>|nil, requestEnding: (fun(urgency: string): unknown)|nil }
---@return boolean ready
---@return string? failure
function HallOfFameScreenState:preparePresentation(env)
  assert(not self.disposed, "disposed Hall of Fame showcase cannot prepare")
  assert(type(env) == "table", "the showcase preparation needs its environment")
  local presentation = assert(self.presentation, "the showcase needs its presentation")
  if not presentation:isReady() then
    local demandReady = false
    if env.requestEnding ~= nil then
      local ready, requestFailure = env.requestEnding("required")
      if requestFailure ~= nil then
        return false, "Hall of Fame ending demand failed: " .. tostring(requestFailure)
      end
      demandReady = ready == true
    end
    if env.cacheFs ~= nil then
      local EndingAssetCache = require("libs.assets.src.ending.EndingAssetCache")
      local loadOk, bundle = pcall(EndingAssetCache.load, env.cacheFs)
      if not loadOk or type(bundle) ~= "table" then
        if demandReady then
          return false, "Hall of Fame bundle failed: " .. tostring(bundle)
        end
      else
        local function missingImage(path)
          local existsOk, exists = pcall(function()
            return env.cacheFs:exists(path)
          end)
          return not existsOk or not exists
        end
        local imageFailure = nil
        local credits = bundle.credits
        if type(credits) ~= "table" or type(credits.scenes) ~= "table" then
          imageFailure = "Hall of Fame bundle failed: credit scenes are missing"
        else
          for _, scene in ipairs(credits.scenes) do
            for _, layer in ipairs({ scene.lower, scene.upper }) do
              if type(layer) ~= "table" or type(layer.path) ~= "string" then
                imageFailure = "Hall of Fame bundle failed: a credit scene names no image"
                break
              end
              if missingImage(layer.path) then
                imageFailure = "Hall of Fame bundle failed: missing credit image " .. tostring(layer.path)
                break
              end
            end
            if imageFailure ~= nil then
              break
            end
          end
          if imageFailure == nil then
            local theEnd = credits.theEnd
            if type(theEnd) ~= "table" or type(theEnd.path) ~= "string" then
              imageFailure = "Hall of Fame bundle failed: The End names no image"
            elseif missingImage(theEnd.path) then
              imageFailure = "Hall of Fame bundle failed: missing The End image " .. tostring(theEnd.path)
            end
          end
        end
        if imageFailure ~= nil then
          return false, imageFailure
        end
        local prepareOk, prepareErr = pcall(presentation.prepare, presentation, bundle)
        if not prepareOk then
          return false, "Hall of Fame bundle failed: " .. tostring(prepareErr)
        end
      end
    end
    if not presentation:isReady() then
      return false, nil
    end
  end
  local record = self:_record()
  if record == nil then
    return true
  end
  local icons = env.icons
  local catalog = env.monCatalog
  if icons == nil or catalog == nil then
    return false, "Hall of Fame showcase needs its shared icon owner"
  end
  if type(icons.prepareKeys) ~= "function" or type(catalog.iconSelection) ~= "function" then
    return false, "Hall of Fame showcase needs its shared icon owner"
  end
  local keys = {}
  for _, mon in ipairs(record.party) do
    if type(mon) == "table" and type(mon.species) == "string" then
      local ok, key = pcall(catalog.iconSelection, catalog, mon)
      if ok and type(key) == "string" and key ~= "" then
        keys[#keys + 1] = key
      end
    end
  end
  local ok, ready, failure = pcall(icons.prepareKeys, icons, keys)
  if not ok then
    return false, "Hall of Fame icons failed: " .. tostring(ready)
  end
  if ready then
    return true
  end
  return false, failure
end

---@return table<string, unknown> read-only showcase view
function HallOfFameScreenState:status()
  local record = self:_record()
  local view = {
    app = "hallOfFame",
    section = "showcase",
    phase = self.closed and "closed" or "browsing",
    recordNumber = self:_recordNumber(),
    total = self.total,
    retained = #self.records,
    date = record ~= nil and record.date or nil,
    partySize = record ~= nil and #record.party or 0,
    party = {},
    selectedMon = self.monIndex0,
    page = self.monIndex0 == nil and "team" or "mon",
  }
  if record ~= nil then
    for _, mon in ipairs(record.party) do
      -- Keep the recorded identity (personality/OT id) so the presenter
      -- derives gender/shininess instead of dropping the branches.
      view.party[#view.party + 1] = {
        species = mon.species,
        level = mon.level,
        form = mon.form,
        personality = mon.personality,
        otId = mon.otId,
        nickname = mon.nickname,
        otName = mon.otName,
      }
    end
  end
  if record ~= nil and self.monIndex0 ~= nil then
    local mon = record.party[self.monIndex0 + 1]
    if mon ~= nil then
      local moves = { "", "", "", "" }
      if type(mon.moves) == "table" then
        for index = 1, 4 do
          moves[index] = mon.moves[index]
        end
      end
      view.mon = {
        species = mon.species,
        level = mon.level,
        form = mon.form,
        personality = mon.personality,
        otId = mon.otId,
        nickname = mon.nickname,
        otName = mon.otName,
        moves = moves,
      }
    end
  end
  return view
end

---@return table<string, unknown>|nil the close result, exactly once
function HallOfFameScreenState:takeResult()
  if not self.closed or self.resultTaken then
    return nil
  end
  self.resultTaken = true
  return { kind = "closed" }
end

---@param resources table<string, unknown>
---@param status table<string, unknown>|nil
function HallOfFameScreenState:draw(resources, status)
  assert(not self.disposed, "disposed Hall of Fame showcase cannot draw")
  self.presentation:draw(resources, status or self:status())
end

---@return ApplicationPlan?
function HallOfFameScreenState:presentationPlan()
  return self.presentation:presentationPlan(self:status())
end

function HallOfFameScreenState:cancelPointerCapture() end

function HallOfFameScreenState:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  self.presentation:dispose()
end

return HallOfFameScreenState
