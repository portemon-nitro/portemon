-- Source-derived core Summary presentation over the required native
-- geometry: one 256x192 content pane with a nickname header, three page
-- tabs, a body, and a footer carrying member controls and Return. The
-- Overview reserves the leaf row for badge frames drawn from the Party
-- family (five anchored leaves or the explicit crown, first animation
-- frame, source offsets applied once); other pages draw no badges. Long
-- metadata paginates by measured width with a continuation marker, never
-- silently truncated. Portraits resolve through the injected provider
-- (male variant first, female fallback for genderless records); eggs draw
-- their icon instead. Draw never mutates services or consumes input.

local LayoutGeometry = require("libs.ui.src.LayoutGeometry")

---@class SummaryRenderer
---@field _graphics love.graphics
---@field _text table<string, unknown> the borrowed generated-font collaborator
local SummaryRenderer = {}
SummaryRenderer.__index = SummaryRenderer

SummaryRenderer.PANE_WIDTH = 256
SummaryRenderer.PANE_HEIGHT = 192
SummaryRenderer.HEADER = { x = 8, y = 4, width = 240, height = 16 }
SummaryRenderer.TAB_WIDTH = 80
SummaryRenderer.TAB_HEIGHT = 16
SummaryRenderer.TAB_Y = 24
SummaryRenderer.BODY = { x = 8, y = 48, width = 240, height = 120 }
SummaryRenderer.BODY_LINE_HEIGHT = 12
SummaryRenderer.BODY_CAPACITY_LINES = 9
SummaryRenderer.MOVE_ROW_HEIGHT = 20
SummaryRenderer.DETAIL = { x = 8, y = 128, width = 240, height = 40 }
SummaryRenderer.DETAIL_CAPACITY_LINES = 3
SummaryRenderer.FOOTER_Y = 172
SummaryRenderer.MEMBER_PREV = { x = 8, y = 172, width = 56, height = 16 }
SummaryRenderer.MEMBER_NEXT = { x = 72, y = 172, width = 56, height = 16 }
SummaryRenderer.RETURN_RECT = { x = 192, y = 172, width = 56, height = 16 }
SummaryRenderer.LEAF_ROW = { x = 88, y = 176, width = 48, height = 15 }
SummaryRenderer.CONTINUATION_COLOR = { 1, 0.85, 0.2 }
SummaryRenderer.TAB_LABELS = { "Overview", "Stats", "Moves" }
SummaryRenderer.GENDER_TEXT = { male = "M", female = "F", genderless = "" }
SummaryRenderer.HM_NOTICE = "An HM move can't be forgotten here."

---@param opts { graphics?: love.graphics, text: table<string, unknown> }
---@return SummaryRenderer
function SummaryRenderer.new(opts)
  assert(type(opts) == "table", "the summary renderer requires options")
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(
    graphics and graphics.rectangle and graphics.draw and graphics.setColor,
    "SummaryRenderer requires love.graphics"
  )
  local text = assert(opts.text, "the summary renderer requires the generated font")
  assert(
    type(text.drawText) == "function" and type(text.textWidth) == "function",
    "the summary renderer borrows generated text drawing and measurement"
  )
  return setmetatable({ _graphics = graphics, _text = text }, SummaryRenderer)
end

-- Word-aware measured pagination: splits text into drawn lines of at
-- most maxWidth units, then reports the total alongside the visible
-- window so callers draw continuation markers instead of clipping
-- silently. Pure in its measure function; drawn behavior never depends on
-- hidden renderer state.
---@param measure fun(text: string): number
---@param text string
---@param maxWidth number
---@param maxLines integer
---@param offset integer zero-based first visible line
---@return { lines: string[], total: integer, truncated: boolean, leading: boolean }
function SummaryRenderer.paginate(measure, text, maxWidth, maxLines, offset)
  assert(type(measure) == "function", "pagination measures through the font")
  assert(type(text) == "string", "pagination needs the source text")
  assert(type(maxWidth) == "number" and maxWidth > 0, "pagination needs a positive width")
  assert(type(maxLines) == "number" and maxLines % 1 == 0 and maxLines >= 1, "pagination needs capacity")
  assert(type(offset) == "number" and offset % 1 == 0 and offset >= 0, "pagination needs an offset")
  local lines = {}
  local function wrapSegment(segment)
    local line = ""
    for word in segment:gmatch("%S+") do
      local candidate = line == "" and word or (line .. " " .. word)
      if measure(candidate) <= maxWidth then
        line = candidate
      else
        if line ~= "" then
          lines[#lines + 1] = line
        end
        line = word
      end
    end
    lines[#lines + 1] = line
  end
  local segments = {}
  for segment in (text .. "\n"):gmatch("(.-)\n") do
    segments[#segments + 1] = segment
  end
  if #segments > 0 and segments[#segments] == "" then
    segments[#segments] = nil
  end
  for index, segment in ipairs(segments) do
    if index > 1 then
      lines[#lines + 1] = ""
    end
    wrapSegment(segment)
  end
  if #lines == 0 then
    lines[1] = ""
  end
  local shown = {}
  for index = offset + 1, math.min(offset + maxLines, #lines) do
    shown[#shown + 1] = lines[index]
  end
  return {
    lines = shown,
    total = #lines,
    truncated = offset + maxLines < #lines,
    leading = offset > 0,
  }
end

-- The closed native geometry for a move count: header, tabs, body,
-- footer controls, move rows, and a coordinate hit test. Pure: the same
-- record drives the controller pointer path and every draw call.
---@param moveCount integer
---@return table<string, unknown>
function SummaryRenderer.layout(moveCount)
  assert(
    type(moveCount) == "number" and moveCount % 1 == 0 and moveCount >= 0 and moveCount <= 4,
    "summary layouts carry zero to four move rows"
  )
  local tabs = {}
  for index = 1, 3 do
    tabs[index] = {
      x = SummaryRenderer.HEADER.x + (index - 1) * SummaryRenderer.TAB_WIDTH,
      y = SummaryRenderer.TAB_Y,
      width = SummaryRenderer.TAB_WIDTH,
      height = SummaryRenderer.TAB_HEIGHT,
    }
  end
  local rows = {}
  for index = 1, moveCount do
    rows[index] = {
      x = SummaryRenderer.BODY.x,
      y = SummaryRenderer.BODY.y + (index - 1) * SummaryRenderer.MOVE_ROW_HEIGHT,
      width = SummaryRenderer.BODY.width,
      height = SummaryRenderer.MOVE_ROW_HEIGHT,
    }
  end
  local geometry = {
    header = SummaryRenderer.HEADER,
    tabs = tabs,
    body = SummaryRenderer.BODY,
    footerY = SummaryRenderer.FOOTER_Y,
    memberPrev = SummaryRenderer.MEMBER_PREV,
    memberNext = SummaryRenderer.MEMBER_NEXT,
    returnRect = SummaryRenderer.RETURN_RECT,
    leafRow = SummaryRenderer.LEAF_ROW,
    moveRows = rows,
    detail = SummaryRenderer.DETAIL,
  }
  local pages = { "overview", "stats", "moves" }
  ---@param x number
  ---@param y number
  ---@return table<string, unknown>? the pressed target, or nil outside controls
  local function hitTest(x, y)
    assert(type(x) == "number" and type(y) == "number", "hit tests carry coordinates")
    for index, tab in ipairs(tabs) do
      if LayoutGeometry.containsPoint(tab, x, y) then
        return { kind = "tab", page = pages[index] }
      end
    end
    for index, row in ipairs(rows) do
      if LayoutGeometry.containsPoint(row, x, y) then
        return { kind = "move", index = index - 1 }
      end
    end
    if LayoutGeometry.containsPoint(geometry.returnRect, x, y) then
      return { kind = "return" }
    end
    if LayoutGeometry.containsPoint(geometry.memberPrev, x, y) then
      return { kind = "member", direction = -1 }
    end
    if LayoutGeometry.containsPoint(geometry.memberNext, x, y) then
      return { kind = "member", direction = 1 }
    end
    return nil
  end
  geometry.hitTest = hitTest
  return geometry
end

---@param graphics love.graphics
---@param color number[]
local function setColor(graphics, color)
  graphics.setColor(color[1], color[2], color[3], color[4] or 1)
end

local CHROME = {
  box = { 0.16, 0.2, 0.32, 1 },
  tab = { 0.24, 0.28, 0.44, 1 },
  selected = { 0.95, 0.8, 0.3, 1 },
  text = { 1, 1, 1, 1 },
  dim = { 0.7, 0.7, 0.75, 1 },
}

---@param text table<string, unknown>
---@param value string
---@param x number
---@param y number
local function drawLine(text, value, x, y)
  text.drawText(text, value, x, y)
end

---@param status table<string, unknown>
---@param layout table<string, unknown>
local function drawChrome(self, status, layout)
  local graphics = self._graphics
  local header = assert(layout.header, "layouts carry their header")
  setColor(graphics, CHROME.box)
  graphics.rectangle("fill", header.x, header.y, header.width, header.height)
  local tabs = assert(layout.tabs, "layouts carry their tabs")
  local pages = { "overview", "stats", "moves" }
  for index, tab in ipairs(tabs) do
    local selected = status.page == pages[index]
    setColor(graphics, selected and CHROME.selected or CHROME.tab)
    graphics.rectangle("fill", tab.x, tab.y, tab.width, tab.height)
    setColor(graphics, CHROME.text)
    drawLine(self._text, SummaryRenderer.TAB_LABELS[index], tab.x + 6, tab.y + 2)
  end
  local body = assert(layout.body, "layouts carry their body")
  setColor(graphics, CHROME.box)
  graphics.rectangle("fill", body.x, body.y, body.width, body.height)
  setColor(graphics, CHROME.tab)
  graphics.rectangle("fill", layout.memberPrev.x, layout.memberPrev.y, 56, 16)
  graphics.rectangle("fill", layout.memberNext.x, layout.memberNext.y, 56, 16)
  graphics.rectangle("fill", layout.returnRect.x, layout.returnRect.y, 56, 16)
  setColor(graphics, CHROME.text)
  drawLine(self._text, "< Prev", layout.memberPrev.x + 6, layout.memberPrev.y + 2)
  drawLine(self._text, "Next >", layout.memberNext.x + 6, layout.memberNext.y + 2)
  drawLine(self._text, "Return", layout.returnRect.x + 6, layout.returnRect.y + 2)
end

---@param layout table<string, unknown>
---@param facts table<string, unknown>
local function drawOverview(self, layout, facts)
  local text = self._text
  local genderText = SummaryRenderer.GENDER_TEXT[facts.gender]
  assert(genderText ~= nil, "overview genders stay in the closed set")
  local header = string.format(
    "%s  Lv%d %s",
    assert(facts.displayName, "facts carry a display name"),
    assert(facts.level, "facts carry a level"),
    genderText
  )
  if facts.shiny == true then
    header = header .. "  Shiny"
  end
  drawLine(text, header, layout.header.x + 4, layout.header.y + 2)
  local body = layout.body
  local textX = body.x + 88
  local lines = {
    "Species " .. assert(facts.speciesName, "facts carry a species name"),
    "Type " .. table.concat(assert(facts.types, "facts carry types"), "/"),
    "OT " .. assert(facts.otName, "facts carry a trainer name") .. "  ID " .. tostring(
      assert(facts.otVisibleId, "facts carry a visible ID")
    ),
    "Nature " .. tostring(assert(facts.nature, "facts carry a nature")),
    "Ability " .. assert(facts.abilityName, "facts carry an ability name"),
    "Item " .. (facts.heldItemName or "None"),
    "HP " .. tostring(assert(facts.currentHp, "facts carry current health")) .. "/" .. tostring(
      assert(facts.maxHp, "facts carry maximum health")
    ),
  }
  local y = body.y + 4
  for _, line in ipairs(lines) do
    drawLine(text, line, textX, y)
    y = y + SummaryRenderer.BODY_LINE_HEIGHT
  end
  local description = assert(facts.abilityDescription, "facts carry an ability description")
  local page = SummaryRenderer.paginate(function(value)
    return text.textWidth(text, value)
  end, description, body.width - 92, 2, 0)
  for _, line in ipairs(page.lines) do
    drawLine(text, line, textX, y)
    y = y + SummaryRenderer.BODY_LINE_HEIGHT
  end
  if page.truncated then
    self:_drawMarker(body.x + body.width - 8, body.y + body.height - 10)
  end
end

---@param layout table<string, unknown>
---@param facts table<string, unknown>
local function drawStats(self, layout, facts)
  local text = self._text
  local body = layout.body
  local stats = assert(facts.stats, "hatched mons carry battle stats")
  local lines = {
    "HP " .. tostring(facts.currentHp) .. "/" .. tostring(facts.maxHp),
    "Attack " .. tostring(stats.attack),
    "Defense " .. tostring(stats.defense),
    "Speed " .. tostring(stats.speed),
    "Sp.Atk " .. tostring(stats.specialAttack),
    "Sp.Def " .. tostring(stats.specialDefense),
    "Status " .. tostring(facts.status),
  }
  local progress = "MAX"
  if facts.expToNext ~= nil then
    progress = "Next " .. tostring(facts.expToNext)
  end
  lines[#lines + 1] = "EXP " .. tostring(assert(facts.experience, "facts carry experience")) .. "  " .. progress
  local y = body.y + 4
  for _, line in ipairs(lines) do
    drawLine(text, line, body.x + 4, y)
    y = y + SummaryRenderer.BODY_LINE_HEIGHT
  end
end

---@param move table<string, unknown>
---@return string
local function powerText(move)
  if move.power == 0 then
    return "--"
  end
  return tostring(move.power)
end

---@param move table<string, unknown>
---@return string
local function accuracyText(move)
  if move.accuracy == 0 then
    return "--"
  end
  return tostring(move.accuracy)
end

---@param status table<string, unknown>
---@param layout table<string, unknown>
---@param facts table<string, unknown>
local function drawMoves(self, status, layout, facts)
  local text = self._text
  local moves = assert(facts.moves, "facts carry their move rows")
  local rows = assert(layout.moveRows, "layouts carry their move rows")
  for index, move in ipairs(moves) do
    local row = assert(rows[index], "layouts carry one row per move")
    local selected = status.moveIndex == index - 1
    if selected then
      setColor(self._graphics, CHROME.selected)
      self._graphics.rectangle("fill", row.x, row.y, row.width, row.height)
    end
    setColor(self._graphics, CHROME.text)
    drawLine(
      text,
      string.format("%s  PP %d/%d", assert(move.name, "moves carry a name"), move.pp, move.maxPp),
      row.x + 4,
      row.y + 3
    )
  end
  local selected = moves[(status.moveIndex or 0) + 1]
  if selected == nil then
    return
  end
  local detail = layout.detail
  local info = string.format(
    "%s/%s  Pwr %s  Acc %s",
    tostring(selected.moveType),
    tostring(selected.category),
    powerText(selected),
    accuracyText(selected)
  )
  drawLine(text, info, detail.x + 4, detail.y + 2)
  local description = assert(selected.description, "moves carry a description")
  local page = SummaryRenderer.paginate(function(value)
    return text.textWidth(text, value)
  end, description, detail.width - 8, 2, status.detailOffset or 0)
  local y = detail.y + 16
  for _, line in ipairs(page.lines) do
    drawLine(text, line, detail.x + 4, y)
    y = y + SummaryRenderer.BODY_LINE_HEIGHT
  end
  if page.truncated or page.leading then
    self:_drawMarker(detail.x + detail.width - 8, detail.y + detail.height - 10)
  end
end

---@param layout table<string, unknown>
---@param facts table<string, unknown>
---@param assets table<string, unknown>
local function drawEgg(self, layout, facts, assets)
  local text = self._text
  local graphics = self._graphics
  local body = layout.body
  drawLine(text, "Egg", layout.header.x + 4, layout.header.y + 2)
  local icons = assert(assets.icons, "eggs draw their icon through the icon provider")
  assert(
    type(icons.image) == "function" and type(icons.quadFor) == "function",
    "icon providers expose image and quadFor"
  )
  local iconKey = assert(facts.iconKey, "eggs carry their icon key")
  graphics.draw(icons:image(iconKey), icons:quadFor(iconKey), body.x + 4, body.y + 4)
  local textX = body.x + 48
  local egg = assert(facts.egg, "eggs carry their met facts")
  local lines = {
    "Location " .. tostring(egg.location),
    "Met " .. tostring(egg.metLocation) .. "  Lv" .. tostring(egg.metLevel),
  }
  if egg.date ~= nil then
    lines[#lines + 1] = string.format("Date %04d/%02d/%02d", egg.date.year or 0, egg.date.month or 0, egg.date.day or 0)
  end
  local y = body.y + 4
  for _, line in ipairs(lines) do
    drawLine(text, line, textX, y)
    y = y + SummaryRenderer.BODY_LINE_HEIGHT
  end
end

-- Draws the five anchored leaf frames or the explicit crown frame from
-- the Party family: absolute source anchors plus one frame offset,
-- applied once. First animation frames only, so repeated draws stay
-- identical.
---@param facts table<string, unknown>
---@param badges table<string, unknown> { manifest, imageFor }
local function drawBadges(self, facts, badges)
  local manifest = assert(badges.manifest, "badge drawing needs the party manifest")
  local leavesRecord = assert(manifest.shinyLeaves, "the party manifest carries leaf badges")
  local graphics = self._graphics
  local imageFor = assert(badges.imageFor, "badge drawing needs its image provider")
  local leaves = assert(facts.leaves, "overview facts carry leaf visibility")
  if leaves.crown == true then
    local crown = assert(leavesRecord.crown, "the party manifest carries the crown visual")
    local frame = assert(crown.frames[1], "crown visuals carry frames")
    local anchor = assert(leavesRecord.crownAnchor, "the party manifest carries the crown anchor")
    local offset = frame.offset or { x = 0, y = 0 }
    graphics.draw(imageFor(frame), anchor.x + offset.x, anchor.y + offset.y)
    return
  end
  local visual = assert(leavesRecord.leaves, "the party manifest carries the leaf visual")
  local frame = assert(visual.frames[1], "leaf visuals carry frames")
  local offset = frame.offset or { x = 0, y = 0 }
  local anchors = assert(leavesRecord.anchors, "the party manifest carries five anchors")
  local shown = leaves.leaves
  for index = 1, 5 do
    if shown[index] == true then
      local anchor = assert(anchors[index], "the party manifest carries five anchors")
      graphics.draw(imageFor(frame), anchor.x + offset.x, anchor.y + offset.y)
    end
  end
end

---@param x number
---@param y number
function SummaryRenderer:_drawMarker(x, y)
  local graphics = self._graphics
  local color = SummaryRenderer.CONTINUATION_COLOR
  setColor(graphics, color)
  graphics.rectangle("fill", x, y, 6, 6)
end

---@param status table<string, unknown> controller status with facts
---@param layout table<string, unknown> the closed geometry for the move count
---@param assets table<string, unknown> { manifest, portraits, icons?, badgeImage }
function SummaryRenderer:draw(status, layout, assets)
  assert(type(status) == "table", "the summary renderer needs its status")
  if not status.open then
    return
  end
  assert(type(layout) == "table", "the summary renderer needs its layout")
  assert(type(assets) == "table", "the summary renderer needs its asset collaborators")
  local facts = assert(status.facts, "open summaries carry their facts")
  local graphics = self._graphics
  local portraits = assert(assets.portraits, "the summary renderer needs its portrait provider")
  assert(
    type(portraits.image) == "function"
      and type(portraits.quadFor) == "function"
      and type(portraits.dimensions) == "function",
    "portrait providers expose image, quadFor, and dimensions"
  )
  drawChrome(self, status, layout)
  if facts.isEgg == true then
    drawEgg(self, layout, facts, assets)
  elseif status.page == "overview" then
    local selector = assert(facts.portraitSelector, "hatched mons select a portrait")
    local ok, quad = pcall(portraits.quadFor, portraits, selector)
    if not ok then
      local fallback = selector:gsub("/male/", "/female/")
      assert(fallback ~= selector, "genderless portraits fall back across variants")
      selector = fallback
      quad = portraits:quadFor(selector)
    end
    local image = portraits:image()
    local dims = portraits:dimensions(selector)
    assert(type(dims.width) == "number" and type(dims.height) == "number", "portraits report dimensions")
    setColor(graphics, { 1, 1, 1, 1 })
    graphics.draw(image, quad, layout.body.x + 4, layout.body.y + 4)
    drawOverview(self, layout, facts)
    drawBadges(self, facts, {
      manifest = assert(assets.manifest, "overview badges need the party manifest"),
      imageFor = assert(assets.badgeImage, "overview badges need their image provider"),
    })
  elseif status.page == "stats" then
    drawStats(self, layout, facts)
  elseif status.page == "moves" then
    drawMoves(self, status, layout, facts)
  else
    error("unknown summary page " .. tostring(status.page), 0)
  end
  if status.notice ~= nil then
    local reason = status.notice.reason
    local line = nil
    if reason == "hm" then
      line = SummaryRenderer.HM_NOTICE
    elseif reason == "stale" then
      line = "The party changed; choose again."
    elseif reason == "empty" then
      line = "No move in that row."
    end
    assert(type(line) == "string", "notices stay in the closed vocabulary")
    setColor(graphics, CHROME.text)
    drawLine(self._text, line, layout.body.x + 4, layout.body.y + layout.body.height - 14)
  end
  setColor(graphics, { 1, 1, 1, 1 })
end

return SummaryRenderer
