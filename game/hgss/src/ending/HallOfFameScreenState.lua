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
    -- The source grid cursor: 0..partySize-1 party slots plus partySize as
    -- the exit target. Detail follows the cursor; there is no separate
    -- team/member page mode. B cancels the application from any cursor.
    cursor0 = 0,
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
      -- Retail B cancels the application from any cursor, never walks back
      -- to a team page: there is no page mode.
      self.closed = true
      return
    elseif event.type == "confirm" then
      local record = self:_record()
      if record ~= nil then
        local exitIndex = #record.party
        if self.cursor0 == exitIndex then
          self.closed = true
          return
        end
        -- Confirming a party slot keeps its detail selected: detail already
        -- follows the cursor, so no page transition exists.
      end
    elseif event.type == "navigate" then
      self:_navigate(event.direction)
    elseif event.type == "touch" and type(event.target) == "number" then
      self:_touchSelect(event.target)
    end
  end
end

-- Grid position for a cursor index: party slots in two columns of three
-- (matching the icon layout), the exit target below the right column.
---@param cursor integer
---@param partySize integer
---@return integer col
---@return integer row
local function cursorPos(cursor, partySize)
  if cursor >= partySize then
    return 1, 3
  end
  return math.floor(cursor / 3), cursor % 3
end

-- Cursor index for a grid position, or nil when the cell holds no party mon.
---@param col integer
---@param row integer
---@param partySize integer
---@return integer? cursor
local function cursorAt(col, row, partySize)
  if row == 3 then
    if col == 1 then
      return partySize
    end
    return nil
  end
  local cursor = col * 3 + row
  if cursor < partySize then
    return cursor
  end
  return nil
end

---@param direction string
function HallOfFameScreenState:_navigate(direction)
  local record = self:_record()
  if record == nil then
    return
  end
  local partySize = #record.party
  local col, row = cursorPos(self.cursor0, partySize)
  if direction == "up" then
    local target = cursorAt(col, row - 1, partySize)
    if target ~= nil then
      self.cursor0 = target
    end
    return
  end
  if direction == "down" then
    local target = cursorAt(col, row + 1, partySize)
    if target ~= nil then
      self.cursor0 = target
    end
    return
  end
  -- Left/right at the grid boundaries page through recorded clears newest
  -- first, refreshing both the icon set and the details. Otherwise they
  -- move within the grid.
  if direction == "left" then
    if col == 1 then
      local target = cursorAt(0, row, partySize)
      if target ~= nil then
        self.cursor0 = target
        return
      end
    end
    if self.recordIndex0 > 0 then
      self.recordIndex0 = self.recordIndex0 - 1
      self:_clampCursor()
    end
    return
  end
  if direction == "right" then
    if col == 0 then
      local target = cursorAt(1, row, partySize)
      if target ~= nil then
        self.cursor0 = target
        return
      end
    end
    if self.recordIndex0 < #self.records - 1 then
      self.recordIndex0 = self.recordIndex0 + 1
      self:_clampCursor()
    end
    return
  end
end

-- Keep the cursor on a valid cell after a record change: same grid position
-- when the new party fills it, otherwise the exit target or the last mon.
function HallOfFameScreenState:_clampCursor()
  local record = self:_record()
  if record == nil then
    self.cursor0 = 0
    return
  end
  local partySize = #record.party
  if self.cursor0 <= partySize then
    -- A party slot that vanished clamps to the exit target.
    if self.cursor0 < partySize then
      return
    end
    return
  end
  self.cursor0 = partySize
end

---@param target integer touched grid index, partySize for the exit target
function HallOfFameScreenState:_touchSelect(target)
  local record = self:_record()
  if record == nil then
    return
  end
  local partySize = #record.party
  if type(target) ~= "number" or target < 0 or target > partySize then
    return
  end
  self.cursor0 = math.floor(target)
  if self.cursor0 == partySize then
    self.closed = true
  end
end

-- Prepares the showcase's presented dependencies through the one feature-local
-- path the League ending shares: the semantic ending demand's terminal
-- receipt, then the generated bundle's validation plus every published image
-- the presented phase draws, then the recorded party's own icon pages.
-- Pending stays pending with no failure; a terminal demand failure, a
-- malformed bundle, or an icon demand failure attributes its failure. The
-- showcase admits only its own section: unrelated credit art never gates
-- the history viewer. Ready is published only after validation and the
-- actually required draw resources are admitted.
---@param env { cacheFs: table<string, unknown>|nil, icons: table<string, unknown>|nil, monCatalog: table<string, unknown>|nil, requestEnding: (fun(urgency: string): unknown)|nil }
---@return boolean ready
---@return string? failure
function HallOfFameScreenState:preparePresentation(env)
  assert(not self.disposed, "disposed Hall of Fame showcase cannot prepare")
  assert(type(env) == "table", "the showcase preparation needs its environment")
  local presentation = assert(self.presentation, "the showcase needs its presentation")
  if not presentation:isReady() then
    local EndingPresentationLoader = require("game.hgss.src.ending.EndingPresentationLoader")
    local _, failure = EndingPresentationLoader.prepare(presentation, {
      cacheFs = env.cacheFs,
      requestEnding = env.requestEnding,
      requiredSections = EndingPresentationLoader.SHOWCASE_SECTIONS,
    })
    if failure ~= nil then
      return false, failure
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
  local partySize = record ~= nil and #record.party or 0
  local cursor = math.min(self.cursor0, partySize)
  local exitSelected = cursor == partySize
  local view = {
    app = "hallOfFame",
    section = "showcase",
    phase = self.closed and "closed" or "browsing",
    recordNumber = self:_recordNumber(),
    total = self.total,
    retained = #self.records,
    date = record ~= nil and record.date or nil,
    partySize = partySize,
    party = {},
    cursor = cursor,
    exitSelected = exitSelected,
    selectedMon = exitSelected and nil or cursor,
    -- The grid shows the icon set and the selected detail together: no
    -- separate team/member page exists.
    page = "grid",
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
  if record ~= nil and not exitSelected then
    local mon = record.party[cursor + 1]
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
