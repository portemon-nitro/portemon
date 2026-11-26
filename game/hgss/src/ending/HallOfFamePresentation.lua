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

-- One rasterized source background through the borrowed generated cache and
-- host graphics namespace, cached per presentation so the roll draws real
-- GPU art instead of placeholder paths. A missing image is a terminal
-- bundle fault, never a skipped layer.
---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param path string content-addressed generated image path
---@param x number?
---@param y number?
local function paintImage(self, resources, path, x, y)
  assert(type(path) == "string" and path ~= "", "the ending image names its published path")
  local cacheFs = assert(resources.cacheFs, "the ending presentation borrows its generated cache")
  local graphics = assert(resources.graphics, "the ending presentation borrows its host graphics namespace")
  assert(type(cacheFs.read) == "function", "the ending cache reads its published images")
  assert(type(graphics.draw) == "function", "the ending graphics draws its backgrounds")
  self._images = self._images or {}
  local image = self._images[path]
  if image == nil then
    local bytes = assert(cacheFs:read(path), "the League ending bundle is missing its published image")
    assert(type(graphics.newImage) == "function", "the ending graphics uploads its backgrounds")
    assert(
      type(cacheFs.newFileData) == "function" or love.filesystem.newFileData ~= nil,
      "the ending images need file data"
    )
    local fileData
    if type(cacheFs.newFileData) == "function" then
      fileData = cacheFs:newFileData(bytes, path)
    else
      fileData = love.filesystem.newFileData(bytes, path)
    end
    image = graphics.newImage(fileData)
    if type(image.setFilter) == "function" then
      pcall(image.setFilter, image, "nearest", "nearest")
    end
    self._images[path] = image
  end
  graphics.draw(image, x or 0, y or 0)
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
---@param resources table<string, unknown>
---@param bank integer
---@param id integer
---@return string
local function messageLine(resources, bank, id)
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
    return formatted.text
  end
  if type(template.text) == "string" and template.text ~= "" then
    return template.text
  end
  Errors.raise("FIELD_ENDING_ASSET_MISSING", "the League ending message has no text", {
    bankId = bank,
    messageId = id,
  })
  error("unreachable after missing ending text")
end

-- One localized species name through message bank 237 (msg_0237), keyed by
-- the catalog's native species identity like the retail showcase.
---@param resources table<string, unknown>
---@param speciesKey string
---@return string
local function speciesName(resources, speciesKey)
  local catalog = resources.monCatalog
  if catalog == nil or type(catalog.species) ~= "function" then
    return tostring(speciesKey)
  end
  local ok, definition = pcall(catalog.species, catalog, speciesKey)
  if not ok or type(definition) ~= "table" or type(definition.nativeId) ~= "number" then
    return tostring(speciesKey)
  end
  local provider = resources.messageProvider
  if provider == nil or type(provider.acquireBank) ~= "function" then
    return tostring(definition.name or speciesKey)
  end
  local acquired = provider:acquireBank(237)
  if type(acquired) ~= "table" then
    return tostring(definition.name or speciesKey)
  end
  local template = provider:get(237, definition.nativeId)
  provider:releaseBank(237)
  if type(template) == "table" and type(template.text) == "string" and template.text ~= "" then
    return template.text
  end
  return tostring(definition.name or speciesKey)
end

-- One localized move name through message bank 750 (msg_0750), keyed by the
-- catalog's native move identity like the retail showcase.
---@param resources table<string, unknown>
---@param moveKey string
---@return string
local function moveName(resources, moveKey)
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
    return template.text
  end
  return tostring(moveKey)
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
  local y = y0
  for _, key in ipairs(keys) do
    local prepared = true
    if type(icons.isPrepared) == "function" then
      local ok, isReady = pcall(icons.isPrepared, icons, key)
      prepared = ok and isReady == true
    end
    if prepared then
      local okHandle, handle = pcall(icons.handleFor, icons, key)
      local okQuad, quad = pcall(icons.quadFor, icons, key, 1)
      if okHandle and okQuad and type(handle) == "table" and type(handle.drawQuad) == "function" then
        handle:drawQuad(graphics, quad, x0, y)
      end
    end
    y = y + 32
  end
end

-- The showcase team page: the source record number and local date plus every
-- recorded party member by species and level.
---@param resources table<string, unknown>
---@param status table<string, unknown>
local function drawShowcaseTeam(resources, status)
  paintWindow(resources, { x = 0, y = 0, width = 256, height = 192 })
  paintText(resources, messageLine(resources, 181, 0), 8, 8)
  paintText(resources, tostring(status.recordNumber or 0), 8, 20)
  if status.date ~= nil then
    paintText(resources, dateText(status.date), 8, 32)
  end
  local party = status.party
  if type(party) ~= "table" then
    return
  end
  local keys = showcaseIconKeys(resources, party)
  drawIcons(resources, keys, 200, 40)
  local y = 48
  for _, mon in ipairs(party) do
    if type(mon) == "table" then
      local name = type(mon.species) == "string" and speciesName(resources, mon.species) or ""
      local levelLine = messageLine(resources, 181, 1)
      paintText(resources, name .. " " .. levelLine .. tostring(mon.level or 0), 8, y)
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
  drawIcons(resources, showcaseIconKeys(resources, { mon }), 200, 8)
  paintText(resources, tostring(mon.nickname or mon.species or ""), 8, 8)
  local speciesLabel = type(mon.species) == "string" and speciesName(resources, mon.species) or ""
  local genderSuffix = ""
  if mon.gender == "male" then
    genderSuffix = " " .. messageLine(resources, 181, 3)
  elseif mon.gender == "female" then
    genderSuffix = " " .. messageLine(resources, 181, 4)
  end
  local levelLine = messageLine(resources, 181, 1)
  paintText(resources, speciesLabel .. genderSuffix, 8, 24)
  paintText(resources, levelLine .. tostring(mon.level or 0), 8, 36)
  paintText(resources, messageLine(resources, 181, 2) .. tostring(mon.otName or ""), 8, 48)
  local moves = mon.moves
  if type(moves) == "table" then
    local y = 64
    for index = 1, 4 do
      local move = moves[index]
      if type(move) == "string" and move ~= "" then
        paintText(resources, moveName(resources, move), 8, y)
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
  local keys = showcaseIconKeys(resources, party)
  drawIcons(resources, keys, 200, 24)
  local y = 24
  for _, mon in ipairs(party) do
    if type(mon) == "table" then
      local name = tostring(mon.nickname or mon.species or "")
      local speciesLabel = type(mon.species) == "string" and speciesName(resources, mon.species) or ""
      if name == "" or name == tostring(mon.species) then
        name = speciesLabel
      end
      local levelLine = messageLine(resources, 181, 1)
      paintText(resources, name .. " " .. levelLine .. tostring(mon.level or 0), 8, y)
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

---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param status table<string, unknown>
local function drawCredits(self, resources, status)
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
      if type(lower) == "table" and type(lower.path) == "string" then
        paintImage(self, resources, lower.path, 0, 0)
      end
      if type(upper) == "table" and type(upper.path) == "string" then
        paintImage(self, resources, upper.path, 0, 0)
      end
    end
  end
  local bank = assert(credits.messageBank, "the credit roll names its message bank")
  for _, line in ipairs(assert(page.lines, "a credit page carries its lines")) do
    local message = messageLine(resources, bank, assert(line.message))
    paintText(resources, message, math.floor(tonumber(line.x) or 8), math.floor(tonumber(line.y) or 24))
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
local function drawTheEndPresentation(self, resources, status)
  local credits = status.creditsSection
  assert(type(credits) == "table", "The End reads the credit bundle section")
  local theEnd = assert(credits.theEnd, "the bundle carries The End screen")
  assert(type(theEnd.path) == "string", "The End names its published image")
  paintImage(self, resources, theEnd.path, 0, 0)
  local titles = assert(credits.titleMessages, "the credit roll carries its title messages")
  local versionId = status.versionId or status.gameVersion
  local titleId = titles.soulsilver
  if versionId == nil or tostring(versionId):find("heartgold", 1, true) ~= nil then
    titleId = titles.heartgold
  end
  paintText(resources, messageLine(resources, assert(credits.messageBank), assert(titleId)), 8, 70)
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
    local versionId = view.versionId or view.gameVersion or resources.versionId
    drawTheEndPresentation(self, resources, { creditsSection = credits, versionId = versionId })
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
