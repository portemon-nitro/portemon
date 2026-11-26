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
  local signature = assert(bundle.signature, "the ending presentation bundle names its source signature")
  for _, section in ipairs(HallOfFamePresentation.SECTIONS) do
    assert(type(bundle[section]) == "table", "the ending presentation bundle carries its " .. section .. " section")
  end
  if self._images ~= nil then
    for _, image in pairs(self._images) do
      if type(image.release) == "function" then
        pcall(image.release, image)
      end
    end
    self._images = nil
  end
  self._textCache = {}
  self.signature = signature
  self.sections = bundle
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

-- One admitted source background: draw-only from the presentation's own
-- pre-admission table. Admission happens once outside draw (see
-- admitImages); a steady draw never touches the filesystem, never uploads a
-- new image, and never acquires a source lease. A missing admission draws
-- nothing so preparation can hold the timeline instead of faulting mid-roll.
---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param path string content-addressed generated image path
---@param x number?
---@param y number?
---@return boolean drawn
local function paintImage(self, resources, path, x, y)
  assert(type(path) == "string" and path ~= "", "the ending image names its published path")
  local graphics = assert(resources.graphics, "the ending presentation borrows its host graphics namespace")
  assert(type(graphics.draw) == "function", "the ending graphics draws its backgrounds")
  local image = self._images ~= nil and self._images[path] or nil
  if image == nil then
    return false
  end
  graphics.draw(image, x or 0, y or 0)
  return true
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

-- One message-bank line through the borrowed message provider's actual
-- acquisition/formatting contract (acquireBank/get/format/releaseBank over
-- FieldMessageProvider). A missing bank or message is a terminal bundle
-- fault, never a "bank..." stand-in: the roll draws source text or fails
-- closed with its source identity.
---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param bank integer
---@param id integer
---@return string
local function messageLine(self, resources, bank, id)
  self._textCache = self._textCache or {}
  local key = bank .. ":" .. id
  local cached = self._textCache[key]
  if type(cached) == "string" and cached ~= "" then
    return cached
  end
  local provider = assert(resources.messageProvider, "the ending presentation borrows its message provider")
  assert(type(provider.acquireBank) == "function", "the ending messages acquire their bank")
  assert(type(provider.get) == "function", "the ending messages read their template")
  assert(type(provider.format) == "function", "the ending messages format their template")
  assert(type(provider.releaseBank) == "function", "the ending messages release their bank")
  local acquired, acquireErr = provider:acquireBank(bank)
  if type(acquired) ~= "table" then
    Errors.raise("FIELD_ENDING_ASSET_MISSING", "the League ending message bank is unavailable", {
      bankId = bank,
      messageId = id,
      cause = acquireErr ~= nil and tostring(acquireErr) or "acquire failed",
    })
  end
  local template, templateErr = provider:get(bank, id)
  provider:releaseBank(bank)
  if type(template) ~= "table" then
    Errors.raise("FIELD_ENDING_ASSET_MISSING", "the League ending message is unavailable", {
      bankId = bank,
      messageId = id,
      cause = templateErr ~= nil and tostring(templateErr) or "missing message",
    })
  end
  assert(template ~= nil, "the ending message template is available after the missing-message error")
  local ok, formatted = pcall(provider.format, provider, template, {}, nil)
  if ok and type(formatted) == "table" and type(formatted.text) == "string" and formatted.text ~= "" then
    -- A template with unresolved substitutions cannot paint control codes:
    -- fall back to the raw text so a missing resolver never draws bytes.
    if formatted.hadUnresolvedSubstitutions ~= true then
      self._textCache[key] = formatted.text
      return formatted.text
    end
  end
  if type(template.text) == "string" and template.text ~= "" then
    self._textCache[key] = template.text
    return template.text
  end
  Errors.raise("FIELD_ENDING_ASSET_MISSING", "the League ending message has no text", {
    bankId = bank,
    messageId = id,
  })
  error("unreachable after missing ending text")
end

-- One localized species name through message bank 237 (msg_0237), keyed by
-- the catalog's native species identity like the retail showcase. Cached per
-- presentation so a steady team page performs no bank lease churn.
---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param speciesKey string
---@return string
local function speciesName(self, resources, speciesKey)
  self._textCache = self._textCache or {}
  local key = "species:" .. tostring(speciesKey)
  local cached = self._textCache[key]
  if type(cached) == "string" and cached ~= "" then
    return cached
  end
  local catalog = resources.monCatalog
  if catalog == nil or type(catalog.species) ~= "function" then
    return tostring(speciesKey)
  end
  local ok, definition = pcall(catalog.species, catalog, speciesKey)
  if not ok or type(definition) ~= "table" or type(definition.nativeId) ~= "number" then
    return tostring(speciesKey)
  end
  local fallback = tostring(definition.name or speciesKey)
  local provider = resources.messageProvider
  if provider == nil or type(provider.acquireBank) ~= "function" then
    return fallback
  end
  local acquired = provider:acquireBank(237)
  if type(acquired) ~= "table" then
    return fallback
  end
  local template = provider:get(237, definition.nativeId)
  provider:releaseBank(237)
  if type(template) == "table" and type(template.text) == "string" and template.text ~= "" then
    self._textCache[key] = template.text
    return template.text
  end
  return fallback
end

-- One localized move name through message bank 750 (msg_0750), keyed by the
-- catalog's native move identity like the retail showcase. Cached per
-- presentation so a steady detail page performs no bank lease churn.
---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param moveKey string
---@return string
local function moveName(self, resources, moveKey)
  self._textCache = self._textCache or {}
  local key = "move:" .. tostring(moveKey)
  local cached = self._textCache[key]
  if type(cached) == "string" and cached ~= "" then
    return cached
  end
  local catalog = resources.monCatalog
  if catalog == nil or type(catalog.move) ~= "function" then
    return tostring(moveKey)
  end
  local ok, definition = pcall(catalog.move, catalog, moveKey)
  if not ok or type(definition) ~= "table" or type(definition.nativeId) ~= "number" then
    return tostring(moveKey)
  end
  local provider = resources.messageProvider
  if provider == nil or type(provider.acquireBank) ~= "function" then
    return tostring(moveKey)
  end
  local acquired = provider:acquireBank(750)
  if type(acquired) ~= "table" then
    return tostring(moveKey)
  end
  local template = provider:get(750, definition.nativeId)
  provider:releaseBank(750)
  if type(template) == "table" and type(template.text) == "string" and template.text ~= "" then
    self._textCache[key] = template.text
    return template.text
  end
  return tostring(moveKey)
end

-- Derive the recorded member's gender from its personality and the
-- catalog's gender ratio, without adding persisted gender/shiny fields:
-- identity already carries everything the retail picture needs.
---@param resources table<string, unknown>
---@param speciesKey unknown
---@param personality integer
---@return string?
local function derivedGender(resources, speciesKey, personality)
  local catalog = resources.monCatalog
  if catalog == nil or type(catalog.species) ~= "function" or type(speciesKey) ~= "string" then
    return nil
  end
  local ok, definition = pcall(catalog.species, catalog, speciesKey)
  if not ok or type(definition) ~= "table" or type(definition.genderRatio) ~= "number" then
    return nil
  end
  local Personality = require("libs.mons.src.gen4.Personality")
  local okGender, gender = pcall(Personality.gender, definition.genderRatio, personality)
  if okGender and (gender == "male" or gender == "female") then
    return gender
  end
  return nil
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

---@param resources table<string, unknown> borrowed icon owners
---@param keys string[] prepared mon icon keys in party order
---@param x0 integer left edge of the icon column
---@param y0 integer top edge of the icon column
local function drawIcons(resources, keys, x0, y0)
  if #keys == 0 then
    return
  end
  local icons = assert(resources.icons, "the ending presentation borrows its mon icon provider")
  local graphics = assert(resources.graphics, "the ending presentation borrows its host graphics namespace")
  assert(type(icons.handleFor) == "function", "the ending icons resolve their sampling handle")
  assert(type(icons.quadFor) == "function", "the ending icons resolve their frame quad")
  -- A six-member party must stay inside the 192-pixel logical pane: lay out
  -- as two columns of three (32px cells) instead of one overflowing column.
  local y = y0
  local x = x0
  for index, key in ipairs(keys) do
    local prepared = true
    if type(icons.isPrepared) == "function" then
      local ok, isReady = pcall(icons.isPrepared, icons, key)
      prepared = ok and isReady == true
    end
    if prepared then
      local okHandle, handle = pcall(icons.handleFor, icons, key)
      local okQuad, quad = pcall(icons.quadFor, icons, key, 1)
      if okHandle and okQuad and type(handle) == "table" and type(handle.drawQuad) == "function" then
        handle:drawQuad(graphics, quad, x, y)
      end
    end
    if index % 3 == 0 then
      x = x + 32
      y = y0
    else
      y = y + 32
    end
  end
end

-- The showcase team page: the source record number and local date plus every
-- recorded party member by species and level.
---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param status table<string, unknown>
local function drawShowcaseTeam(self, resources, status)
  paintWindow(resources, { x = 0, y = 0, width = 256, height = 192 })
  paintText(resources, messageLine(self, resources, 181, 0), 8, 8)
  paintText(resources, tostring(status.recordNumber or 0), 8, 20)
  if status.date ~= nil then
    paintText(resources, dateText(status.date), 8, 32)
  end
  local party = status.party
  if type(party) ~= "table" then
    return
  end
  local keys = showcaseIconKeys(resources, party)
  drawIcons(resources, keys, 184, 40)
  local y = 48
  for _, mon in ipairs(party) do
    if type(mon) == "table" then
      local name = type(mon.species) == "string" and speciesName(self, resources, mon.species) or ""
      local levelLine = messageLine(self, resources, 181, 1)
      paintText(resources, name .. " " .. levelLine .. tostring(mon.level or 0), 8, y)
      y = y + 16
    end
  end
end

-- One recorded member's detail: nickname, species, level, OT name and moves.
-- Gender derives from the recorded personality/OT identity at draw time, so
-- the presenter's gender branches run for production detail views.
---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param status table<string, unknown>
local function drawShowcaseMon(self, resources, status)
  local mon = status.mon
  if type(mon) ~= "table" then
    drawShowcaseTeam(self, resources, status)
    return
  end
  paintWindow(resources, { x = 0, y = 0, width = 256, height = 192 })
  drawIcons(resources, showcaseIconKeys(resources, { mon }), 200, 8)
  paintText(resources, tostring(mon.nickname or mon.species or ""), 8, 8)
  local speciesLabel = type(mon.species) == "string" and speciesName(self, resources, mon.species) or ""
  local gender = mon.gender
  if gender == nil and type(mon.personality) == "number" then
    gender = derivedGender(resources, mon.species, mon.personality)
  end
  local genderSuffix = ""
  if gender == "male" then
    genderSuffix = " " .. messageLine(self, resources, 181, 3)
  elseif gender == "female" then
    genderSuffix = " " .. messageLine(self, resources, 181, 4)
  end
  local levelLine = messageLine(self, resources, 181, 1)
  paintText(resources, speciesLabel .. genderSuffix, 8, 24)
  paintText(resources, levelLine .. tostring(mon.level or 0), 8, 36)
  paintText(resources, messageLine(self, resources, 181, 2) .. tostring(mon.otName or ""), 8, 48)
  local moves = mon.moves
  if type(moves) == "table" then
    local y = 64
    for index = 1, 4 do
      local move = moves[index]
      if type(move) == "string" and move ~= "" then
        paintText(resources, moveName(self, resources, move), 8, y)
        y = y + 16
      end
    end
  end
end

-- The registration congratulations surface: the party the ending registers,
-- drawn from the immutable snapshot the transaction staged.
---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param status table<string, unknown>
local function drawRegistration(self, resources, status)
  local registration = status.registrationSection
  assert(type(registration) == "table", "the registration surface reads its bundle section")
  paintWindow(resources, { x = 0, y = 0, width = 256, height = 192 })
  paintText(resources, messageLine(self, resources, assert(registration.messageBank), 0), 8, 8)
  local party = status.party
  if type(party) ~= "table" then
    return
  end
  local keys = showcaseIconKeys(resources, party)
  drawIcons(resources, keys, 184, 24)
  local y = 24
  for _, mon in ipairs(party) do
    if type(mon) == "table" then
      local name = tostring(mon.nickname or mon.species or "")
      local speciesLabel = type(mon.species) == "string" and speciesName(self, resources, mon.species) or ""
      if name == "" or name == tostring(mon.species) then
        name = speciesLabel
      end
      local levelLine = messageLine(self, resources, 181, 1)
      paintText(resources, name .. " " .. levelLine .. tostring(mon.level or 0), 8, y)
      y = y + 16
    end
  end
end

-- The page of the credit roll visible at the status timer: the source shows
-- a page only while startTime <= timer < startTime + duration, with gaps of
-- no display between pages (PAGE_STATE_NO_DISPLAY). A gap draws backgrounds
-- only, never the expired page's lines.
---@param credits table<string, unknown>
---@param status table<string, unknown>
---@return table<string, unknown>? page, nil while no page displays
local function currentCreditPage(credits, status)
  local pages = assert(credits.pages, "the credit roll carries its pages")
  local timer = tonumber(status.timer) or 0
  for _, page in ipairs(pages) do
    local startTime = tonumber(page.startTime) or 0
    local duration = tonumber(page.duration) or 0
    if timer < startTime then
      break
    end
    if duration <= 0 or timer < startTime + duration then
      return page
    end
  end
  return nil
end

---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param status table<string, unknown>
local function drawCredits(self, resources, status)
  local credits = status.creditsSection
  assert(type(credits) == "table", "the credit roll reads its bundle section")
  local page = currentCreditPage(credits, status)
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
      if type(lower) == "table" and type(lower.path) == "string" then
        paintImage(self, resources, lower.path, 0, 0)
      end
      if type(upper) == "table" and type(upper.path) == "string" then
        paintImage(self, resources, upper.path, 0, 0)
      end
    end
  end
  if page == nil then
    return
  end
  local bank = assert(credits.messageBank, "the credit roll names its message bank")
  for _, line in ipairs(assert(page.lines, "a credit page carries its lines")) do
    local message = messageLine(self, resources, bank, assert(line.message))
    paintText(resources, message, math.floor(tonumber(line.x) or 8), math.floor(tonumber(line.y) or 24))
  end
end

-- The save-status surface: the source saving window (bank 40:15) while the
-- transaction stages, then the source save-result message. Success prints
-- bank 40:16 (player-name formatted; raw template when no resolver is
-- composed), while a failed publication paints the retryable status string
-- the coordinator reports.
---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param status table<string, unknown>
local function drawSaveStatus(self, resources, status)
  paintWindow(resources, { x = 0, y = 0, width = 256, height = 192 })
  local message = status.saveMessage
  if type(message) ~= "string" or message == "" then
    -- No explicit failure string: saving (15) before/during the write,
    -- save-result success (16) once the coordinator published.
    local phase = status.phase
    if phase == "save_status" or phase == "save_se" then
      message = messageLine(self, resources, 40, 16)
    else
      message = messageLine(self, resources, 40, 15)
    end
  end
  paintText(resources, message, 8, 88)
end

-- The End: the source disables the text/OBJ layers and shows only its own
-- screen (credits.c MAIN_FADE_OUT loads BG1 with The End and turns the
-- other planes off). No edition title is drawn over it: the title was
-- printed at credit initialization, not over The End.
---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param status table<string, unknown>
local function drawTheEndPresentation(self, resources, status)
  local credits = status.creditsSection
  assert(type(credits) == "table", "The End reads the credit bundle section")
  local theEnd = assert(credits.theEnd, "the bundle carries The End screen")
  assert(type(theEnd.path) == "string", "The End names its published image")
  paintImage(self, resources, theEnd.path, 0, 0)
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
  local self_ = self
  local function renderRegistration(resources, view)
    drawRegistration(self_, resources, {
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
  local self_ = self
  local function renderShowcase(resources, view)
    if view.page == "mon" then
      drawShowcaseMon(self_, resources, view)
    else
      drawShowcaseTeam(self_, resources, view)
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

-- Admit every published credit/The End image outside draw: synchronous
-- filesystem reads plus one GPU upload per path, cached for draw-only use.
-- Returns true once every required image is admitted; false stays pending
-- (never a draw-time load). A missing image is terminal bundle data.
---@param resources table<string, unknown> borrowed generated cache + graphics
---@return boolean admitted
---@return string? failure terminal admission failure
function HallOfFamePresentation:admitImages(resources)
  assert(not self.disposed, "disposed Hall of Fame presentation cannot admit")
  local sections = self.sections
  if sections == nil then
    return false, nil
  end
  local credits = assert(sections.credits, "the presentation bundle carries its credits section")
  local cacheFs = assert(resources.cacheFs, "image admission borrows its generated cache")
  local graphics = assert(resources.graphics, "image admission borrows its host graphics namespace")
  assert(type(cacheFs.read) == "function", "image admission reads its published images")
  assert(type(graphics.newImage) == "function", "image admission uploads its backgrounds")
  self._images = self._images or {}
  local function admitOne(path)
    if self._images[path] ~= nil then
      return true, nil
    end
    local bytes
    do
      local ok, data = pcall(cacheFs.read, cacheFs, path)
      if not ok or type(data) ~= "string" then
        return false, "the League ending bundle is missing its published image: " .. tostring(path)
      end
      bytes = data
    end
    local fileData
    if type(cacheFs.newFileData) == "function" then
      local ok, fd = pcall(cacheFs.newFileData, cacheFs, bytes, path)
      if not ok then
        return false, "the League ending image admits no file data: " .. tostring(path)
      end
      fileData = fd
    else
      fileData = love.filesystem.newFileData(bytes, path)
    end
    local ok, image = pcall(graphics.newImage, fileData)
    if not ok or image == nil then
      return false, "the League ending image uploads no GPU art: " .. tostring(path)
    end
    if type(image.setFilter) == "function" then
      pcall(image.setFilter, image, "nearest", "nearest")
    end
    self._images[path] = image
    return true, nil
  end
  local scenes = assert(credits.scenes, "the credit roll carries its scenes")
  for _, scene in ipairs(scenes) do
    for _, layer in ipairs({ scene.lower, scene.upper }) do
      local path = type(layer) == "table" and layer.path or nil
      assert(type(path) == "string", "a credit scene names its published image")
      local ok, failure = admitOne(path)
      if not ok then
        return false, failure
      end
    end
  end
  local theEnd = assert(credits.theEnd, "the bundle carries The End screen")
  assert(type(theEnd.path) == "string", "The End names its published image")
  do
    local ok, failure = admitOne(theEnd.path)
    if not ok then
      return false, failure
    end
  end
  -- Warm the static text cache outside draw so a steady roll performs no
  -- bank lease churn. Dynamic species/move names warm on their first draw
  -- and stay cached per presentation.
  if resources.messageProvider ~= nil then
    local staticIds = { { 180, 0 }, { 181, 0 }, { 181, 1 }, { 181, 2 }, { 181, 3 }, { 181, 4 }, { 40, 15 }, { 40, 16 } }
    for _, pair in ipairs(staticIds) do
      pcall(messageLine, self, resources, pair[1], pair[2])
    end
    local bank = credits.messageBank
    if type(bank) == "number" then
      for _, page in ipairs(assert(credits.pages, "the credit roll carries its pages")) do
        if type(page.lines) == "table" then
          for _, line in ipairs(page.lines) do
            if type(line.message) == "number" then
              pcall(messageLine, self, resources, bank, line.message)
            end
          end
        end
      end
    end
  end
  return true, nil
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
    elseif
      phase == "the_end"
      or phase == "the_end_music_box"
      or phase == "the_end_fade_in"
      or phase == "the_end_fade_out"
    then
      sectionName = "the_end"
    elseif
      phase == "saving"
      or phase == "save_failed"
      or phase == "save_status"
      or phase == "save_se"
      or phase == "save_fade"
    then
      sectionName = "save_status"
    elseif phase == "credits_fade" then
      sectionName = "credits"
    elseif phase == "credits" then
      sectionName = "credits"
    else
      sectionName = "credits"
    end
  end
  if sectionName == "registration" then
    local section = self:_require("registration")
    drawRegistration(self, resources, {
      registrationSection = section,
      party = view.party or {},
    })
    return
  end
  if sectionName == "showcase" then
    self:_require("showcase")
    if view.page == "mon" then
      drawShowcaseMon(self, resources, view)
    else
      drawShowcaseTeam(self, resources, view)
    end
    return
  end
  local credits = self:_require("credits")
  local savePhase = sectionName == "save_status"
  if savePhase then
    drawSaveStatus(self, resources, { saveMessage = view.saveMessage, phase = view.phase })
    return
  end
  if sectionName == "the_end" then
    drawTheEndPresentation(self, resources, { creditsSection = credits })
    return
  end
  drawCredits(self, resources, { creditsSection = credits, timer = view.timer or 0 })
end

function HallOfFamePresentation:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  self.sections = nil
  self._textCache = nil
  if self._images ~= nil then
    for _, image in pairs(self._images) do
      if type(image.release) == "function" then
        pcall(image.release, image)
      end
    end
    self._images = nil
  end
end

return HallOfFamePresentation
