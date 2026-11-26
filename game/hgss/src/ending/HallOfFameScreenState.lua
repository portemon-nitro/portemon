-- The source PC's Hall of Fame showcase: the blocking child the PC shell opens
-- (ScrCmd_OpenHallOfFameShowcase, src/scrcmd_c.c) over the saved history. The
-- child snapshots the recorded clears once when it opens, so navigating and
-- closing can never observe a party that changed while it ran, and it owns only
-- the selection: the history bucket and the live party stay with their owners.
--
-- Source reading order: the newest recorded clear first, shown as one grid
-- page (the whole party's icons plus the cursor-following selected detail
-- with record number, local date, species, level, nickname and OT name).
-- Cancel closes the application from any cursor.

local HallOfFamePresentationMapper = require("game.hgss.src.ending.HallOfFamePresentation")

---@class HallOfFameScreenState
---@field private records table<string, unknown>[] newest first
---@field private total integer recorded-clear sequence
---@field private recordIndex0 integer zero-based recency of the open clear
---@field private cursor0 integer selected grid cell 0..6
---@field private closed boolean
---@field private resultTaken boolean
---@field private disposed boolean
---@field private presentation HallOfFamePresentation
local HallOfFameScreenState = {}
HallOfFameScreenState.__index = HallOfFameScreenState

-- Retail grid geometry (hall_of_fame_showcase_data.s): icon positions
-- (0x38,0x48),(0x80,0x48),(0xC8,0x48) over (0x38,0x88),(0x80,0x88),
-- (0xC8,0x88) plus exit (0xE0,0xB0). Dpad neighbor table decoded from
-- gHallOfFameShowcaseGridDpadBoxes: {left,top,_,_,up,down,left,right}.
-- The icon anchors themselves live once in the presentation owner
-- (GRID_ANCHORS), which draws them and hangs its hit boxes off them, so
-- navigation, drawing and touch share one geometry instead of each
-- inventing it.
local EXIT_INDEX = 6
HallOfFameScreenState.EXIT_INDEX = EXIT_INDEX
local GRID_NEIGHBORS = {
  [0] = { up = 0, down = 3, left = 0, right = 1 },
  [1] = { up = 1, down = 4, left = 0, right = 2 },
  [2] = { up = 2, down = 5, left = 1, right = 2 },
  [3] = { up = 0, down = 6, left = 3, right = 4 },
  [4] = { up = 1, down = 6, left = 3, right = 5 },
  [5] = { up = 2, down = 6, left = 4, right = 5 },
  [6] = { up = 5, down = 6, left = 6, right = 6 },
}
HallOfFameScreenState.GRID_NEIGHBORS = GRID_NEIGHBORS

---@param cursor number
---@param direction string
---@return number neighbor in 0..6
function HallOfFameScreenState.neighbor(cursor, direction)
  local clamped = math.floor(tonumber(cursor) or 0)
  if clamped < 0 then
    clamped = 0
  elseif clamped > EXIT_INDEX then
    clamped = EXIT_INDEX
  end
  local row = GRID_NEIGHBORS[clamped]
  if row == nil then
    return clamped
  end
  local target = row[direction]
  if type(target) ~= "number" then
    return clamped
  end
  return target
end

---@param cursor number 0..6
---@return integer 0..6 clamped cursor
local function clampCursor(cursor)
  if type(cursor) ~= "number" then
    return 0
  end
  local floored = math.floor(cursor)
  if floored < 0 then
    return 0
  end
  if floored > EXIT_INDEX then
    return EXIT_INDEX
  end
  return floored
end

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
    -- The source grid: three columns by two rows (indices 0-5) plus the
    -- exit target 6 (PARTY_SIZE). Detail follows the cursor; there is no
    -- separate team/member page mode. B cancels the application from any
    -- cursor. Empty slots stay navigable with hidden detail, matching
    -- retail ShowMonDetail hiding when index >= numMons.
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
  -- Raw host pointer edges arrive untranslated through the PC host step;
  -- route them through the one shared press-only mapper instead of
  -- inventing a second translation. Only a new press selects; motion and
  -- release never activate, so paging fires exactly once per press.
  for _, event in ipairs(events) do
    if event.type == "cancel" then
      -- Retail B cancels the application from any cursor, never walks back
      -- to a team page: there is no page mode.
      self.closed = true
      return
    elseif event.type == "confirm" then
      -- Retail A on the exit target exits; A on a party slot keeps its
      -- detail selected (detail already follows the cursor).
      if clampCursor(self.cursor0) == EXIT_INDEX then
        self.closed = true
        return
      end
    elseif event.type == "navigate" then
      self:_navigate(event.direction)
    elseif event.type == "touch" and type(event.target) == "number" then
      self:_touchSelect(event.target)
    elseif event.type == "pointer_down" then
      local mapped = HallOfFamePresentationMapper.mapPointerPress(event)
      if type(mapped) == "table" and mapped.type == "touch" and type(mapped.target) == "number" then
        self:_touchSelect(mapped.target)
      end
    end
  end
end

---@param direction string
function HallOfFameScreenState:_navigate(direction)
  if self:_record() == nil then
    return
  end
  self.cursor0 = clampCursor(self.cursor0)
  local neighbors = GRID_NEIGHBORS[self.cursor0]
  if neighbors == nil then
    return
  end
  local target = nil
  if direction == "up" then
    target = neighbors.up
  elseif direction == "down" then
    target = neighbors.down
  elseif direction == "left" then
    target = neighbors.left
  elseif direction == "right" then
    target = neighbors.right
  else
    return
  end
  if target ~= nil and target ~= self.cursor0 then
    self.cursor0 = target
    return
  end
  -- No grid movement: left at 0/3 pages to the newer record, right at
  -- 2/5 pages to the older record (hall_of_fame_showcase.c HandleInput).
  -- Any other held edge keeps the cursor.
  if direction == "left" then
    if (self.cursor0 == 0 or self.cursor0 == 3) and self.recordIndex0 > 0 then
      self.recordIndex0 = self.recordIndex0 - 1
      self:_clampCursor()
      self:_invalidatePartyNames()
    end
    return
  end
  if direction == "right" then
    if (self.cursor0 == 2 or self.cursor0 == 5) and self.recordIndex0 < #self.records - 1 then
      self.recordIndex0 = self.recordIndex0 + 1
      self:_clampCursor()
      self:_invalidatePartyNames()
    end
    return
  end
end

-- Keep the cursor on a valid grid cell after a record change: the cursor is
-- always 0..6, so a record page never invents an invalid index. Empty slots
-- stay navigable with hidden detail, matching retail.
function HallOfFameScreenState:_clampCursor()
  self.cursor0 = clampCursor(self.cursor0)
end

-- A record page swaps the showcased party: previously warmed species/move
-- names no longer cover the open detail until the new party admits.
function HallOfFameScreenState:_invalidatePartyNames()
  local presentation = self.presentation
  if presentation ~= nil and type(presentation.invalidateParty) == "function" then
    presentation:invalidateParty()
  end
end

---@param target integer touched grid index 0..6, 7 prev record, 8 next record
function HallOfFameScreenState:_touchSelect(target)
  if self:_record() == nil then
    return
  end
  if target == 7 then
    if self.recordIndex0 > 0 then
      self.recordIndex0 = self.recordIndex0 - 1
      self:_clampCursor()
      self:_invalidatePartyNames()
    end
    return
  end
  if target == 8 then
    if self.recordIndex0 < #self.records - 1 then
      self.recordIndex0 = self.recordIndex0 + 1
      self:_clampCursor()
      self:_invalidatePartyNames()
    end
    return
  end
  if type(target) ~= "number" or target < 0 or target > EXIT_INDEX then
    return
  end
  self.cursor0 = math.floor(target)
  if self.cursor0 == EXIT_INDEX then
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
  local cursor = clampCursor(self.cursor0)
  local exitSelected = cursor == EXIT_INDEX
  local emptySelected = (not exitSelected) and (cursor >= partySize)
  local selectedMon = nil
  if not exitSelected and not emptySelected then
    selectedMon = cursor
  end
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
    selectedMon = selectedMon,
    -- The grid shows the icon set and the selected detail together: no
    -- separate team/member page exists.
    page = "grid",
  }
  if record ~= nil then
    for _, mon in ipairs(record.party) do
      -- Keep the recorded identity (personality/OT id) so the presenter
      -- derives gender/shininess instead of dropping the branches. Keep
      -- moves so admission warms the selected detail's names.
      local movesCopy = nil
      if type(mon.moves) == "table" then
        movesCopy = {}
        for index = 1, 4 do
          movesCopy[index] = mon.moves[index]
        end
      end
      view.party[#view.party + 1] = {
        species = mon.species,
        level = mon.level,
        form = mon.form,
        personality = mon.personality,
        otId = mon.otId,
        nickname = mon.nickname,
        otName = mon.otName,
        moves = movesCopy,
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
