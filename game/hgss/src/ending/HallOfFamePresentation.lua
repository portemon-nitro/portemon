-- The prepared presentation behind the League ending's three native surfaces:
-- the Hall of Fame registration view (msg_0180), the PC showcase
-- (msg_0181 with the recorded party's own art) and the credit roll
-- (NARC_a_2_6_3 with msg_0440). One owner per live ending or showcase child: it
-- prepares the generated bundle once, exposes readiness, draws only immutable
-- snapshots, and releases its leases exactly once.
--
-- The bundle is the producer's own source-derived artifact: this owner never
-- invents art, layout or text and fails closed with its source identity while
-- the required sections are missing. Plans and draws are built here from the
-- bundle's plain records; the cache never carries serialized callbacks.

local Errors = require("libs.errors.src.Errors")

---@class HallOfFamePresentation
---@field private sections table<string, unknown>?
---@field private signature string?
---@field private disposed boolean
local HallOfFamePresentation = {}
HallOfFamePresentation.__index = HallOfFamePresentation

-- The source surfaces this presenter draws, in bundle order.
HallOfFamePresentation.SECTIONS = { "registration", "showcase", "credits" }

---@param bundle table<string, unknown>|nil the loaded ending asset sections
---@return HallOfFamePresentation
function HallOfFamePresentation.new(bundle)
  local presentation = setmetatable({ sections = nil, signature = nil, disposed = false }, HallOfFamePresentation)
  if bundle ~= nil then
    presentation:prepare(bundle)
  end
  return presentation
end

-- Admits one loaded bundle. Every required section must be present before the
-- presentation becomes ready: a partially loaded bundle would draw a surface
-- with missing source records.
---@param bundle table<string, unknown>
function HallOfFamePresentation:prepare(bundle)
  assert(not self.disposed, "disposed Hall of Fame presentation cannot prepare")
  assert(type(bundle) == "table", "the ending presentation needs its generated bundle")
  for _, section in ipairs(HallOfFamePresentation.SECTIONS) do
    assert(type(bundle[section]) == "table", "the ending presentation bundle carries its " .. section .. " section")
  end
  self.sections = bundle
  self.signature = assert(bundle.signature, "the ending presentation bundle names its source signature")
end

---@return boolean
function HallOfFamePresentation:isReady()
  return self.sections ~= nil
end

---@param section string
---@return table<string, unknown>
function HallOfFamePresentation:_require(section)
  assert(not self.disposed, "disposed Hall of Fame presentation cannot draw")
  local sections = self.sections
  if sections == nil then
    Errors.raise(
      "FIELD_ENDING_ASSET_MISSING",
      "the League ending's generated presentation bundle is unavailable",
      { section = section }
    )
  end
  assert(sections ~= nil, "the presentation bundle is available after the missing-bundle error")
  return assert(sections[section], "the presentation bundle carries its " .. section .. " section")
end

---@param resources table<string, unknown> borrowed text/window/icon/image owners
---@param text string
---@param x integer
---@param y integer
local function paintText(resources, text, x, y)
  local textRenderer = assert(resources.textRenderer, "the ending presentation borrows its text renderer")
  assert(type(textRenderer.drawText) == "function", "the ending text renderer draws lines")
  textRenderer:drawText(text, x, y)
end

---@param resources table<string, unknown> borrowed text/window/icon/image owners
---@param box table<string, unknown>
local function paintWindow(resources, box)
  local windowRenderer = assert(resources.windowRenderer, "the ending presentation borrows its window renderer")
  assert(type(windowRenderer.drawStandardWindow) == "function", "the ending window renderer draws frames")
  local background = { 0, 0, 0, 1 }
  local textRenderer = resources.textRenderer
  if type(textRenderer) == "table" and type(textRenderer.windowBackgroundColor) == "function" then
    local ok, color = pcall(textRenderer.windowBackgroundColor, textRenderer)
    if ok and type(color) == "table" then
      background = color
    end
  end
  windowRenderer:drawStandardWindow(box, background)
end

-- One message-bank line through the borrowed message provider, falling back
-- to the source bank/message identity when no provider is composed (a
-- headless composition still exercises the page timeline, never blank).
---@param resources table<string, unknown>
---@param bank integer
---@param id integer
---@return string
local function messageLine(resources, bank, id)
  local provider = resources.messageProvider
  if provider ~= nil and type(provider.message) == "function" then
    local ok, text = pcall(provider.message, provider, bank, id)
    if ok and type(text) == "string" and text ~= "" then
      return text
    end
  end
  return "bank" .. tostring(bank) .. ":" .. tostring(id)
end

---@param value unknown
---@return string
local function dateText(value)
  if type(value) ~= "table" then
    return ""
  end
  local year = tonumber(value.year) or 0
  local month = tonumber(value.month) or 0
  local day = tonumber(value.day) or 0
  return string.format("%04d-%02d-%02d", year, month, day)
end

-- The showcase's party icon keys through the shared mon catalog, so the
-- recorded team draws its own art instead of inventing sprites.
---@param resources table<string, unknown>
---@param party table<string, unknown>[] recorded party members by value
---@return string[]
local function showcaseIconKeys(resources, party)
  local catalog = resources.monCatalog
  if catalog == nil or type(catalog.iconSelection) ~= "function" then
    return {}
  end
  local keys = {}
  for _, mon in ipairs(party) do
    if type(mon) == "table" and type(mon.species) == "string" then
      local ok, key = pcall(catalog.iconSelection, catalog, mon)
      if ok and type(key) == "string" and key ~= "" then
        keys[#keys + 1] = key
      end
    end
  end
  return keys
end

---@param resources table<string, unknown>
---@param keys string[]
local function touchIcons(resources, keys)
  local icons = resources.icons
  if icons == nil or #keys == 0 then
    return
  end
  if type(icons.dimensions) == "function" then
    for _, key in ipairs(keys) do
      pcall(icons.dimensions, icons, key)
    end
  end
end

-- The showcase team page: the source record number and local date plus every
-- recorded party member by species and level.
---@param resources table<string, unknown>
---@param status table<string, unknown>
local function drawShowcaseTeam(resources, status)
  paintWindow(resources, { x = 0, y = 0, width = 256, height = 192 })
  paintText(resources, "No." .. tostring(status.recordNumber or 0), 8, 8)
  if status.date ~= nil then
    paintText(resources, dateText(status.date), 8, 24)
  end
  local party = status.party
  if type(party) ~= "table" then
    return
  end
  touchIcons(resources, showcaseIconKeys(resources, party))
  local y = 40
  for _, mon in ipairs(party) do
    if type(mon) == "table" then
      paintText(resources, tostring(mon.species or "") .. " Lv" .. tostring(mon.level or 0), 8, y)
      y = y + 16
    end
  end
end

-- One recorded member's detail: nickname, species, level, OT name and moves.
---@param resources table<string, unknown>
---@param status table<string, unknown>
local function drawShowcaseMon(resources, status)
  local mon = status.mon
  if type(mon) ~= "table" then
    drawShowcaseTeam(resources, status)
    return
  end
  paintWindow(resources, { x = 0, y = 0, width = 256, height = 192 })
  touchIcons(resources, showcaseIconKeys(resources, { mon }))
  paintText(resources, tostring(mon.nickname or mon.species or ""), 8, 8)
  paintText(resources, tostring(mon.species or "") .. " Lv" .. tostring(mon.level or 0), 8, 24)
  paintText(resources, "OT " .. tostring(mon.otName or ""), 8, 40)
  local moves = mon.moves
  if type(moves) == "table" then
    local y = 56
    for index = 1, 4 do
      local move = moves[index]
      if type(move) == "string" and move ~= "" then
        paintText(resources, move, 8, y)
        y = y + 16
      end
    end
  end
end

-- The registration congratulations surface: the party the ending registers,
-- drawn from the immutable snapshot the transaction staged.
---@param resources table<string, unknown>
---@param status table<string, unknown>
local function drawRegistration(resources, status)
  local registration = status.registrationSection
  assert(type(registration) == "table", "the registration surface reads its bundle section")
  paintWindow(resources, { x = 0, y = 0, width = 256, height = 192 })
  paintText(resources, messageLine(resources, assert(registration.messageBank), 0), 8, 8)
  local party = status.party
  if type(party) ~= "table" then
    return
  end
  touchIcons(resources, showcaseIconKeys(resources, party))
  local y = 24
  for _, mon in ipairs(party) do
    if type(mon) == "table" then
      paintText(resources, tostring(mon.nickname or mon.species or "") .. " Lv" .. tostring(mon.level or 0), 8, y)
      y = y + 16
    end
  end
end

-- The page of the credit roll visible at the status timer: its source lines
-- in order, over the current scene background identity.
---@param credits table<string, unknown>
---@param status table<string, unknown>
---@return table<string, unknown> page
local function currentCreditPage(credits, status)
  local pages = assert(credits.pages, "the credit roll carries its pages")
  local timer = tonumber(status.timer) or 0
  local selected = pages[1]
  for _, page in ipairs(pages) do
    if tonumber(page.startTime) <= timer then
      selected = page
    else
      break
    end
  end
  return selected
end

---@param resources table<string, unknown>
---@param status table<string, unknown>
local function drawCredits(resources, status)
  local credits = status.creditsSection
  assert(type(credits) == "table", "the credit roll reads its bundle section")
  local page = currentCreditPage(credits, status)
  assert(page ~= nil, "the credit roll always has a visible page")
  local scenes = credits.scenes
  if type(scenes) == "table" and #scenes > 0 then
    local sceneIndex = 1
    local timings = credits.sceneTransitionTimings
    if type(timings) == "table" then
      local timer = tonumber(status.timer) or 0
      for index, timing in ipairs(timings) do
        if tonumber(timing) <= timer then
          sceneIndex = math.min(index + 1, #scenes)
        else
          break
        end
      end
    end
    local scene = scenes[sceneIndex]
    if type(scene) == "table" then
      local lower = scene.lower
      local upper = scene.upper
      if type(lower) == "table" and type(upper) == "table" then
        paintText(resources, "scene " .. tostring(scene.index or 0), 8, 8)
      end
    end
  end
  local bank = assert(credits.messageBank, "the credit roll names its message bank")
  local y = 24
  for _, line in ipairs(assert(page.lines, "a credit page carries its lines")) do
    paintText(resources, messageLine(resources, bank, assert(line.message)), math.floor(tonumber(line.x) or 8), y)
    y = y + 12
  end
end

-- The save-status surface: the source saving window while the transaction
-- stages, then the retryable save-status message the coordinator reports.
---@param resources table<string, unknown>
---@param status table<string, unknown>
local function drawSaveStatus(resources, status)
  paintWindow(resources, { x = 0, y = 0, width = 256, height = 192 })
  local message = status.saveMessage
  if type(message) ~= "string" or message == "" then
    message = messageLine(resources, 40, 15)
  end
  paintText(resources, message, 8, 88)
end

---@param resources table<string, unknown>
---@param status table<string, unknown>
local function drawTheEnd(resources, status)
  local credits = status.creditsSection
  assert(type(credits) == "table", "The End reads the credit bundle section")
  local theEnd = assert(credits.theEnd, "the bundle carries The End screen")
  assert(type(theEnd.path) == "string", "The End names its published image")
  paintWindow(resources, { x = 0, y = 0, width = 256, height = 192 })
  paintText(resources, messageLine(resources, assert(credits.messageBank), 0), 8, 88)
end

-- A minimal valid application plan over one pane: content draws through the
-- render callback, outer frames stay empty because the source surfaces are
-- self-framed. The pane placement is the native full-screen surface.
---@param inputKey string
---@param content table<string, unknown>
---@param render fun(resources: table<string, unknown>, view: table<string, unknown>, plan: table<string, unknown>)
---@return table<string, unknown>
local function fullScreenPlan(inputKey, content, render)
  local function noEndingMapInput()
    return nil
  end
  return {
    panes = {
      {
        id = "main",
        interactive = false,
        placement = {
          x = 0,
          y = 0,
          width = 256,
          height = 192,
          logicalWidth = 256,
          logicalHeight = 192,
        },
      },
    },
    frames = {},
    content = content,
    inputKey = inputKey,
    render = render,
    mapInput = noEndingMapInput,
  }
end

-- The registration view's own plan: the source party records the ending is
-- about to store, drawn by the generated registration section.
---@param status table<string, unknown> the ending's registration snapshot
---@return table<string, unknown>
function HallOfFamePresentation:registrationPlan(status)
  local section = self:_require("registration")
  assert(type(status) == "table", "the registration plan needs its snapshot")
  local content = { section = "registration", messageBank = section.messageBank, memberFrames = section.memberFrames }
  local function renderRegistration(resources, view)
    drawRegistration(resources, {
      registrationSection = section,
      party = assert(view.party, "the registration view carries its party"),
    })
  end
  return fullScreenPlan("hall-of-fame-registration", content, renderRegistration)
end

-- The showcase plan over one immutable record page.
---@param status table<string, unknown> the showcase's snapshot
---@return table<string, unknown>
function HallOfFamePresentation:presentationPlan(status)
  local section = self:_require("showcase")
  assert(type(status) == "table", "the showcase plan needs its snapshot")
  local content = { section = "showcase", messageBank = section.messageBank }
  local function renderShowcase(resources, view)
    if view.page == "mon" then
      drawShowcaseMon(resources, view)
    else
      drawShowcaseTeam(resources, view)
    end
  end
  return fullScreenPlan("hall-of-fame-showcase", content, renderShowcase)
end

-- The registration application's own timeline: the source per-member reveal
-- cadence times the recorded party size. A composition without the bundle
-- has no frames to play.
---@param partySize integer? the recorded non-Egg party count
---@return integer
function HallOfFamePresentation:congratulationsFrames(partySize)
  if self.sections == nil then
    return 0
  end
  local section = self:_require("registration")
  local memberFrames = math.floor(assert(section.memberFrames))
  if partySize == nil then
    return memberFrames
  end
  assert(type(partySize) == "number" and partySize >= 0, "the registration timeline needs its party size")
  return memberFrames * math.floor(partySize)
end

-- The source per-member reveal cadence behind one congratulations frame.
---@return integer
function HallOfFamePresentation:memberFrames()
  if self.sections == nil then
    return 0
  end
  local section = self:_require("registration")
  return math.floor(assert(section.memberFrames))
end

-- The credit roll's own source frame count. Without the bundle the roll
-- owns no timeline.
---@return integer
function HallOfFamePresentation:creditFrames()
  if self.sections == nil then
    return 0
  end
  local section = self:_require("credits")
  return math.floor(assert(section.frames))
end

-- The End's own source music-box wait. Without the bundle there is no wait.
---@return integer
function HallOfFamePresentation:musicBoxWaitFrames()
  if self.sections == nil then
    return 0
  end
  local section = self:_require("credits")
  return math.floor(assert(section.musicBoxWaitFrames))
end

-- The save-status message's own print duration, in fixed ticks. Without the
-- bundle nothing is printed, so nothing is waited for.
---@return integer
function HallOfFamePresentation:saveStatusFrames()
  if self.sections == nil then
    return 0
  end
  local section = self:_require("credits")
  local frames = section.saveStatusFrames
  return type(frames) == "number" and math.floor(frames) or 0
end

-- One palette fade's length. The source's own frame counts apply only while a
-- bundle is composed and there is a screen to fade.
---@param frames integer
---@return integer
function HallOfFamePresentation:fadeFrames(frames)
  assert(type(frames) == "number" and frames >= 0, "a fade declares its source frame count")
  if self.sections == nil then
    return 0
  end
  return math.floor(frames)
end

---@param resources table<string, unknown>
---@param status table<string, unknown>|nil
function HallOfFamePresentation:draw(resources, status)
  assert(not self.disposed, "disposed Hall of Fame presentation cannot draw")
  local view = status or {}
  assert(type(view) == "table", "the ending presentation draws its snapshot")
  local phase = view.phase
  local sectionName = view.section or (view.app == "hallOfFame" and "showcase") or nil
  if sectionName == nil then
    if phase == "congratulations" then
      sectionName = "registration"
    elseif phase == "the_end" or phase == "the_end_music_box" then
      sectionName = "the_end"
    elseif phase == "saving" or phase == "save_failed" or phase == "save_status" or phase == "save_se" then
      sectionName = "save_status"
    else
      sectionName = "credits"
    end
  end
  if sectionName == "registration" then
    local section = self:_require("registration")
    drawRegistration(resources, {
      registrationSection = section,
      party = view.party or {},
    })
    return
  end
  if sectionName == "showcase" then
    self:_require("showcase")
    if view.page == "mon" then
      drawShowcaseMon(resources, view)
    else
      drawShowcaseTeam(resources, view)
    end
    return
  end
  local credits = self:_require("credits")
  local savePhase = sectionName == "save_status"
  if savePhase then
    drawSaveStatus(resources, { saveMessage = view.saveMessage })
    return
  end
  if sectionName == "the_end" then
    drawTheEnd(resources, { creditsSection = credits })
    return
  end
  drawCredits(resources, { creditsSection = credits, timer = view.timer or 0 })
end

function HallOfFamePresentation:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  self.sections = nil
end

return HallOfFamePresentation
