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

-- The showcase app reads history only; its pages are immutable record
-- snapshots, so it consumes input without waiting for a GPU frame. A blank or
-- partially prepared presentation never changes what an input means.
HallOfFameScreenState.acceptsInputWithoutPresentation = true

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

-- Prepares the showcase's presented dependencies: the generated ending
-- bundle through the shared demand, then the recorded party's own icon
-- pages through the shared provider. A cold bundle stays pending with no
-- failure; a malformed bundle or icon demand attributes its failure.
-- Readiness here is data plus icon admission; drawing stays wait-free.
---@param env { cacheFs: table<string, unknown>|nil, icons: table<string, unknown>|nil, monCatalog: table<string, unknown>|nil, requestEnding: (fun(urgency: string): unknown)|nil }
---@return boolean ready
---@return string? failure
function HallOfFameScreenState:preparePresentation(env)
  assert(not self.disposed, "disposed Hall of Fame showcase cannot prepare")
  assert(type(env) == "table", "the showcase preparation needs its environment")
  local presentation = assert(self.presentation, "the showcase needs its presentation")
  if not presentation:isReady() then
    if env.requestEnding ~= nil then
      pcall(env.requestEnding, "required")
    end
    if env.cacheFs ~= nil then
      local EndingAssetCache = require("libs.assets.src.ending.EndingAssetCache")
      local readyOk, ready = pcall(EndingAssetCache.isReady, env.cacheFs)
      if readyOk and ready then
        local loadOk, bundle = pcall(EndingAssetCache.load, env.cacheFs)
        if loadOk and type(bundle) == "table" then
          local prepareOk, prepareErr = pcall(presentation.prepare, presentation, bundle)
          if not prepareOk then
            return false, "Hall of Fame bundle failed: " .. tostring(prepareErr)
          end
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
      view.party[#view.party + 1] = { species = mon.species, level = mon.level, form = mon.form }
    end
  end
  if record ~= nil and self.monIndex0 ~= nil then
    local mon = record.party[self.monIndex0 + 1]
    if mon ~= nil then
      view.mon = {
        species = mon.species,
        level = mon.level,
        form = mon.form,
        nickname = mon.nickname,
        otName = mon.otName,
        moves = { mon.moves[1], mon.moves[2], mon.moves[3], mon.moves[4] },
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
