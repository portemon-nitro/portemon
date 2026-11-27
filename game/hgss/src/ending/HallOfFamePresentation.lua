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
---@field private _silhouettes table<string, { image: love.Image }>?
---@field private _quads table<string, unknown>?
local HallOfFamePresentation = {}
HallOfFamePresentation.__index = HallOfFamePresentation

-- The source surfaces this presenter draws, in bundle order.
HallOfFamePresentation.SECTIONS = { "registration", "showcase", "credits" }

-- One feature-owned phase-to-sections mapping: every production phase's
-- actually drawn receipt. Registration draws party icons/text; saving
-- draws only save text (no party icons); the roll/The End draw credit art.
-- All field owners consume this helper so the mapping lives once in the
-- ending owner instead of duplicated across runtime/state/resources.
---@param phase string
---@return string[] required sections for the phase
function HallOfFamePresentation.requiredSectionsForPhase(phase)
  if phase == "congratulations" then
    return { "registration" }
  end
  if phase == "credits" or phase == "credits_fade" then
    return { "credits" }
  end
  if
    phase == "the_end"
    or phase == "the_end_music_box"
    or phase == "the_end_fade_in"
    or phase == "the_end_fade_out"
  then
    return { "credits" }
  end
  if
    phase == "saving"
    or phase == "save_failed"
    or phase == "save_status"
    or phase == "save_se"
    or phase == "save_fade"
  then
    return { "save" }
  end
  return { "registration" }
end

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
  local function releaseImage(image)
    if image ~= nil and type(image.release) == "function" then
      pcall(image.release, image)
    end
  end
  if self._images ~= nil then
    for _, image in pairs(self._images) do
      releaseImage(image)
    end
    self._images = nil
  end
  if self._portraitPages ~= nil then
    for _, record in pairs(self._portraitPages) do
      if type(record) == "table" then
        releaseImage(record.image)
      end
    end
  end
  if self._silhouettes ~= nil then
    for _, record in pairs(self._silhouettes) do
      if type(record) == "table" then
        releaseImage(record.image)
      end
    end
  end
  self._textCache = {}
  self._quads = nil
  self._admittedSections = {}
  self._textAdmittedSections = {}
  self._admissionFailure = nil
  self._admissionDepth = 0
  self._iconsAdmitted = false
  self._portraitsAdmitted = false
  self._detailAdmitted = false
  self._cutsceneGender = nil
  self._partyAdmitted = false
  self._portraitPages = nil
  self._portraitManifest = nil
  self._silhouettes = nil
  self._memoLandmarks = nil
  self._headerAdmitted = false
  self._saveResultAdmitted = false
  self.signature = signature
  self.sections = bundle
end

---@return boolean
function HallOfFamePresentation:isReady()
  return self.sections ~= nil
end

-- Whether the actually required phase receipt for the named sections is
-- admitted outside the fixed tick: required static source text warmed.
-- Sections present is not enough; a composed owner without its static text
-- receipt stays pending and holds its phase clock. Dynamic party/header/
-- save text and icons/images gate draw (isDrawReady), not this clock, so
-- headless acceptance (which stops before rendering) advances on static
-- text while presented production holds its surface on the full receipt.
-- Explicit headless vs presented one-receipt unification remains follow-up.
---@param required string[]|nil the sections the advancing phase draws; nil means all
---@return boolean
function HallOfFamePresentation:isPhaseReady(required)
  if self.sections == nil or self.disposed then
    return false
  end
  if self._admissionFailure ~= nil then
    return false
  end
  local admitted = self._textAdmittedSections
  if admitted == nil then
    return false
  end
  local names = required or HallOfFamePresentation.SECTIONS
  for _, name in ipairs(names) do
    if admitted[name] ~= true then
      return false
    end
  end
  return true
end

-- Whether the actually required draw resources for the named sections are
-- admitted outside draw: published images uploaded, required source text
-- warmed, the party's localized names warmed, and the party icons admitted.
-- Sections present or phase-ready is not enough; a composed owner without
-- its full draw receipt paints nothing and holds its surface.
---@param required string[]|nil the sections the advancing phase draws; nil means all
---@return boolean
function HallOfFamePresentation:isDrawReady(required)
  if self.sections == nil or self.disposed then
    return false
  end
  if self._admissionFailure ~= nil then
    return false
  end
  local admitted = self._admittedSections
  if admitted == nil then
    return false
  end
  local names = required or HallOfFamePresentation.SECTIONS
  for _, name in ipairs(names) do
    if admitted[name] ~= true then
      return false
    end
    -- Registration and showcase paint the recorded party's own icons,
    -- localized names/levels and (showcase) the expanded record header:
    -- cold icons, names or header hold those phases exactly like cold
    -- images/text. Registration additionally paints the recorded party's
    -- own front/back pictures: cold portrait pages hold the
    -- congratulations exactly like cold icons. Saving draws the saving
    -- window plus the player-named result: both must admit before the
    -- write/result prints.
    if name == "registration" or name == "showcase" then
      if self._iconsAdmitted ~= true then
        return false
      end
      if self._partyAdmitted ~= true then
        return false
      end
      if name == "showcase" and self._headerAdmitted ~= true then
        return false
      end
      -- Both registration and showcase paint the selected member's own
      -- front portrait: cold portrait pages hold either surface exactly
      -- like cold icons.
      if self._portraitsAdmitted ~= true then
        return false
      end
      if name == "registration" and self._detailAdmitted ~= true then
        return false
      end
    end
    if name == "save" and self._saveResultAdmitted ~= true then
      return false
    end
  end
  return true
end

---@return string? terminal admission failure, nil while pending or ready
function HallOfFamePresentation:admissionFailure()
  return self._admissionFailure
end

-- The shared mon icon pages the registration/showcase phases draw are
-- admitted by the field's icon owner outside draw. A cold icon page holds
-- its phase clock like cold images/text: the mandatory sequence never draws
-- tolerantly with missing party art.
function HallOfFamePresentation:noteIconsAdmitted()
  self._iconsAdmitted = true
end

-- The recorded party's portrait pages (plus their white silhouettes) are
-- admitted through the shared portrait provider outside draw. A cold
-- portrait page holds the congratulations clock like cold icons.
function HallOfFamePresentation:notePortraitsAdmitted()
  self._portraitsAdmitted = true
end

-- The admitted memo landmark maps, or nil while pending.
---@return table<string, unknown>? maps
function HallOfFamePresentation:memoMaps()
  return self._memoLandmarks
end

-- Invalidate warmed party names when the showcased record changes: a new
-- party's species/move names must admit before the detail draws.
function HallOfFamePresentation:invalidateParty()
  self._partyAdmitted = false
  self._headerAdmitted = false
end

-- Invalidate the warmed save-result line when the player identity changes.
function HallOfFamePresentation:invalidateSaveResult()
  self._saveResultAdmitted = false
end

-- The recorded registration detail lines (headers, per-member details and
-- whole-party windows) are warmed outside draw. Cold detail holds the
-- congratulations exactly like cold static text.
function HallOfFamePresentation:noteDetailsAdmitted()
  self._detailAdmitted = true
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
-- new image, and never acquires a source lease. A missing admission on a
-- draw-ready phase is a terminal bundle fault, never a silent skip: pending
-- phases never reach draw because their clock and input stay blocked and
-- drawEnding paints nothing until isDrawReady holds.
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
    Errors.raise("FIELD_ENDING_ASSET_MISSING", "the League ending draws only admitted images", { path = path })
  end
  assert(image ~= nil, "the ending image is admitted after the missing-image error")
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

-- Draw consumes only the admitted snapshot: bank acquisition is allowed
-- only while an admit* entry holds the admission gate open. A cache miss
-- outside admission is a loud programming fault (the phase must hold on
-- its receipt instead of drawing), never a silent draw-time bank acquire.
---@param self HallOfFamePresentation
---@return boolean
local function acquireAllowed(self)
  return (self._admissionDepth or 0) > 0
end

-- Runs an admission body with the draw-time bank-acquire gate open.
-- Re-entrant: nested admit entries (admitParty warming levels) share the
-- gate, and the gate always closes, even when the body raises.
---@param self HallOfFamePresentation
---@param body fun(): boolean, string?
---@return boolean admitted
---@return string? failure
local function withAdmission(self, body)
  self._admissionDepth = (self._admissionDepth or 0) + 1
  local results = { pcall(body) }
  self._admissionDepth = (self._admissionDepth or 0) - 1
  if not results[1] then
    error(results[2], 0)
  end
  return results[2], results[3]
end

---@param self HallOfFamePresentation
---@param key string
---@param context string|nil admission site naming the missing receipt
---@return string
local function requireCached(self, key, context)
  self._textCache = self._textCache or {}
  local cached = self._textCache[key]
  if type(cached) == "string" and cached ~= "" then
    return cached
  end
  Errors.raise("FIELD_ENDING_ASSET_MISSING", "the League ending draws only admitted text", {
    key = key,
    context = context,
  })
  error("unreachable after missing admitted text")
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
  if not acquireAllowed(self) then
    return requireCached(self, key, "messageLine")
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
    -- Static lines must resolve with no substitutions: an unresolved
    -- template here is a terminal bundle fault, not a raw fallback.
    -- Dynamic lines (record header, level, save result) format through
    -- formatDynamic below with real values; they never warm here.
    if formatted.hadUnresolvedSubstitutions ~= true then
      self._textCache[key] = formatted.text
      return formatted.text
    end
    Errors.raise("FIELD_ENDING_ASSET_MISSING", "the League ending message needs its substitutions", {
      bankId = bank,
      messageId = id,
    })
  end
  if type(template.text) == "string" and template.text ~= "" then
    -- A static template with no substitution tokens paints raw; dynamic
    -- templates never reach this branch because the format above raises.
    self._textCache[key] = template.text
    return template.text
  end
  Errors.raise("FIELD_ENDING_ASSET_MISSING", "the League ending message has no text", {
    bankId = bank,
    messageId = id,
  })
  error("unreachable after missing ending text")
end

-- One dynamic message-bank line with real substitution values (record
-- header, level, save result). Warmed outside draw with the actual values
-- the phase draws; draw reads only the cache, never acquiring a bank.
-- Substitution reuses the shared token contract: the slot is each
-- marker's own first token argument (ScriptDialogueHost precedent), so a
-- control occurring at several slots resolves every occurrence from its
-- own slot. Values re-enter as glyph tokens through asciiGlyphTokens, and
-- an unmappable value or an unresolvable marker is a terminal bundle
-- fault, never a raw fallback.
---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param bank integer
---@param id integer
---@param slotValues table<integer, string> slot -> already-formatted text
---@param cacheKey string admit/draw cache identity including the values
---@return string formatted text
local function formatDynamic(self, resources, bank, id, slotValues, cacheKey)
  self._textCache = self._textCache or {}
  local cached = self._textCache[cacheKey]
  if type(cached) == "string" and cached ~= "" then
    return cached
  end
  if not acquireAllowed(self) then
    return requireCached(self, cacheKey, "formatDynamic")
  end
  local provider = assert(resources.messageProvider, "the ending presentation borrows its message provider")
  assert(type(provider.acquireBank) == "function", "the ending messages acquire their bank")
  assert(type(provider.get) == "function", "the ending messages read their template")
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
  if type(template) ~= "table" or type(template.text) ~= "string" or template.text == "" then
    Errors.raise("FIELD_ENDING_ASSET_MISSING", "the League ending message is unavailable", {
      bankId = bank,
      messageId = id,
      cause = templateErr ~= nil and tostring(templateErr) or "missing message",
    })
  end
  assert(template ~= nil, "the ending dynamic template is available after the missing-message error")
  local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
  local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
  local fontDef = resources.fontDef
  -- One resolver per substitution control in the template: each occurrence
  -- resolves from its own first token argument. TRNAME carries no slot and
  -- always names the player, which rides in slot 0 for the save result.
  local function resolvePlayerName()
    local value = slotValues[0]
    if type(value) ~= "string" or value == "" or fontDef == nil then
      return nil
    end
    local tokens = FieldMessageProvider.asciiGlyphTokens(value, fontDef)
    if tokens == nil then
      return nil
    end
    return tokens
  end
  local function resolveSlot(_, args, _)
    local slot = args ~= nil and args[1] or nil
    local value = slot ~= nil and slotValues[slot] or nil
    if type(value) ~= "string" or value == "" or fontDef == nil then
      return nil
    end
    local tokens = FieldMessageProvider.asciiGlyphTokens(value, fontDef)
    if tokens == nil then
      return nil
    end
    return tokens
  end
  local resolvers = {}
  if type(template.tokens) == "table" then
    for _, token in ipairs(template.tokens) do
      if token.kind == "substitution" and token.control ~= nil and resolvers[token.control] == nil then
        if token.control == FieldMessageText.TRNAME then
          resolvers[token.control] = resolvePlayerName
        else
          resolvers[token.control] = resolveSlot
        end
      end
    end
  end
  assert(type(provider.format) == "function", "the ending messages format their template")
  local ok, formatted = pcall(provider.format, provider, template, {}, resolvers)
  if
    not ok
    or type(formatted) ~= "table"
    or type(formatted.text) ~= "string"
    or formatted.text == ""
    or formatted.hadUnresolvedSubstitutions == true
  then
    Errors.raise("FIELD_ENDING_ASSET_MISSING", "the League ending dynamic message needs its values", {
      bankId = bank,
      messageId = id,
    })
  end
  assert(formatted ~= nil, "the ending dynamic message formats after the missing-values error")
  local text = formatted.text
  self._textCache[cacheKey] = text
  return text
end

-- Month abbreviation behind showcase header slot 2 (msg_0239, retail
-- BufferMonthNameAbbr). Read through the provider so the abbreviation stays
-- source-grounded, not hardcoded.
---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param month number 1..12
---@return string abbrev
local function monthAbbrev(self, resources, month)
  local key = "month:" .. tostring(month)
  self._textCache = self._textCache or {}
  local cached = self._textCache[key]
  if type(cached) == "string" and cached ~= "" then
    return cached
  end
  if not acquireAllowed(self) then
    return requireCached(self, key, "monthAbbrev")
  end
  local provider = assert(resources.messageProvider, "the ending presentation borrows its message provider")
  local m = math.floor(tonumber(month) or 1)
  if m < 1 or m > 12 then
    m = 1
  end
  local acquired = provider:acquireBank(239)
  if type(acquired) ~= "table" then
    Errors.raise("FIELD_ENDING_ASSET_MISSING", "the League ending month bank is unavailable", { month = m })
  end
  local template = provider:get(239, m - 1)
  provider:releaseBank(239)
  if type(template) ~= "table" or type(template.text) ~= "string" or template.text == "" then
    Errors.raise("FIELD_ENDING_ASSET_MISSING", "the League ending month is unavailable", { month = m })
  end
  assert(template ~= nil, "the ending month template is available after the missing-month error")
  self._textCache[key] = template.text
  return template.text
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
  if not acquireAllowed(self) then
    return requireCached(self, key, "speciesName")
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
  if not acquireAllowed(self) then
    return requireCached(self, key, "moveName")
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

-- The single showcase geometry owner: source icon/sprite columns
-- (hall_of_fame_showcase_data.s IconPositions columns 56,128,200 plus the
-- exit sprite column) with port-adapted rows, shared by drawing,
-- hit-testing and the cursor. Anchors are upper-left icon origins; hit
-- boxes hang off them with the source cell sizes (32x32 party cells).
-- Rows are compressed to y=32/68 so the 3x2 grid (32..100) never overlaps
-- the detail panel (112..192); the source rows (72/136) would collide
-- with OT/move text on one pane. Columns stay source-exact; only rows
-- and the exit placement are transformed for the single-pane composite.
local GRID_ANCHORS = {
  [0] = { x = 0x38, y = 32 },
  [1] = { x = 0x80, y = 32 },
  [2] = { x = 0xC8, y = 32 },
  [3] = { x = 0x38, y = 68 },
  [4] = { x = 0x80, y = 68 },
  [5] = { x = 0xC8, y = 68 },
  [6] = { x = 192, y = 168 },
}

-- Shared showcase hit geometry, derived from the one anchor owner above:
-- 3x2 party grid (32x32 cells) plus the source-sized exit target
-- (x=192..255,y=160..191) so the Return label has room. Prev/next paging
-- targets sit at the grid mid-height on both edges inside the pane.
local SHOWCASE_HIT_CELLS = {
  [0] = { x = GRID_ANCHORS[0].x, y = GRID_ANCHORS[0].y, w = 32, h = 32 },
  [1] = { x = GRID_ANCHORS[1].x, y = GRID_ANCHORS[1].y, w = 32, h = 32 },
  [2] = { x = GRID_ANCHORS[2].x, y = GRID_ANCHORS[2].y, w = 32, h = 32 },
  [3] = { x = GRID_ANCHORS[3].x, y = GRID_ANCHORS[3].y, w = 32, h = 32 },
  [4] = { x = GRID_ANCHORS[4].x, y = GRID_ANCHORS[4].y, w = 32, h = 32 },
  [5] = { x = GRID_ANCHORS[5].x, y = GRID_ANCHORS[5].y, w = 32, h = 32 },
  [6] = { x = 192, y = 160, w = 64, h = 32 },
}
-- Source touchscreen paging rects (hall_of_fame_showcase_data.s
-- gHallOfFameShowcaseHitboxes), transformed to the compressed grid: the
-- previous arrow occupies x=0..23 at grid mid-height, the next arrow
-- mirrors it at the right edge so both boxes stay inside the 256-wide pane.
local SHOWCASE_PREV_HIT = { x = 0, y = 52, w = 24, h = 32 }
local SHOWCASE_NEXT_HIT = { x = 232, y = 52, w = 24, h = 32 }

---@param box table<string, integer>
---@param x number
---@param y number
---@return boolean
local function hitContains(box, x, y)
  return x >= box.x and x < box.x + box.w and y >= box.y and y < box.y + box.h
end

---@param resources table<string, unknown> borrowed icon owners
---@param keys string[] prepared mon icon keys in party order
local function drawIcons(resources, keys)
  if #keys == 0 then
    return
  end
  local icons = assert(resources.icons, "the ending presentation borrows its mon icon provider")
  local graphics = assert(resources.graphics, "the ending presentation borrows its host graphics namespace")
  assert(type(icons.handleFor) == "function", "the ending icons resolve their sampling handle")
  assert(type(icons.quadFor) == "function", "the ending icons resolve their frame quad")
  -- One shared geometry owner: retail 3x2 party icon anchors
  -- (hall_of_fame_showcase_data.s IconPositions: columns 56,128,200 by
  -- rows 72,136) plus the exit sprite anchor. Icons, hit-testing and the
  -- cursor all read these same anchors; hit boxes hang off them below.
  for index, key in ipairs(keys) do
    local anchor = GRID_ANCHORS[index - 1]
    if anchor == nil then
      break
    end
    if type(icons.isPrepared) == "function" then
      local ok, isReady = pcall(icons.isPrepared, icons, key)
      if not (ok and isReady == true) then
        Errors.raise("FIELD_ENDING_ASSET_MISSING", "the League ending draws only admitted party icons", {
          key = key,
        })
      end
    end
    local okHandle, handle = pcall(icons.handleFor, icons, key)
    local okQuad, quad = pcall(icons.quadFor, icons, key, 1)
    if not (okHandle and okQuad and type(handle) == "table" and type(handle.drawQuad) == "function") then
      Errors.raise("FIELD_ENDING_ASSET_MISSING", "the League ending party icon is unavailable", {
        key = key,
      })
    end
    assert(type(handle.drawQuad) == "function", "the ending icon draws its quad after the missing-icon error")
    handle:drawQuad(graphics, quad, anchor.x, anchor.y)
  end
end

-- The source showcase grid: the expanded record header (bank 181:0 with
-- record number/date), the 3x2 party icon set with the exit target, the
-- selected member's front portrait (correct species/shiny/form/gender via
-- the portrait owner, Nidoran-safe through the shared gender rule) and the
-- selected detail together on one 256x192 surface. The retail twin-display
-- layout (main grid + sub portrait/detail over NARC_a_0_9_7 backgrounds) is
-- adapted explicitly: the main background paints fullscreen, the sub
-- background backs the detail panel, and the sub portrait is scaled into
-- the top-right corner panel so icons, portrait, detail, cursor, arrows
-- and exit never overlap. No species text list is painted: retail shows
-- icons, not a text roster. Cursor movement refreshes icons, portrait and
-- detail; record paging refreshes all three as well. B cancels from any
-- cursor. Arrows paint only while a page exists in that direction (retail
-- arrow visibility), at the source touchscreen rects.
---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param status table<string, unknown>
local function drawShowcaseGrid(self, resources, status)
  local section = self:_require("showcase")
  -- Main display background fullscreen; the sub display background backs
  -- only the detail panel so both source surfaces stay visible instead of
  -- one opaque layer covering the other. Both are required realized
  -- surfaces (v3 contract): a missing background fails closed, never a
  -- generic window.
  do
    local mainBg = section.mainBg
    if type(mainBg) ~= "table" or type(mainBg.path) ~= "string" then
      Errors.raise("FIELD_ENDING_ASSET_MISSING", "the showcase needs its realized main background", {})
    end
    paintImage(self, resources, mainBg.path, 0, 0)
  end
  do
    local subBg = section.subBg
    if type(subBg) ~= "table" or type(subBg.path) ~= "string" then
      Errors.raise("FIELD_ENDING_ASSET_MISSING", "the showcase needs its realized sub background", {})
    end
    local graphics = resources.graphics
    if type(graphics) == "table" and type(graphics.newQuad) == "function" then
      local subImage = self:_admittedImage(subBg.path)
      local width, height = 256, 192
      if type(subImage.getWidth) == "function" then
        local okW, w = pcall(subImage.getWidth, subImage)
        if okW and type(w) == "number" and w > 0 then
          width = w
        end
        local okH, h = pcall(subImage.getHeight, subImage)
        if okH and type(h) == "number" and h > 0 then
          height = h
        end
      end
      -- Crop quad is owned with the admitted page, not rebuilt every
      -- frame: key by realized dimensions so host resizes reuse it.
      local quad = self:_showcaseSubBgQuad(resources, width, height)
      self:_drawTinted(resources, subImage, quad, 0, 112, { r = 1, g = 1, b = 1 }, 1)
    end
  end
  -- Expanded header with real record number/date (no separate unexpanded
  -- paints): warmed in admission, drawn from cache with no bank acquire.
  do
    local recordNumber = tonumber(status.recordNumber) or 0
    local date = status.date
    local year = 0
    local month = 1
    local day = 1
    if type(date) == "table" then
      year = tonumber(date.year) or 0
      month = tonumber(date.month) or 1
      day = tonumber(date.day) or 1
    end
    local abbrev = monthAbbrev(self, resources, month)
    local slots = {
      [0] = tostring(math.floor(recordNumber)),
      [1] = tostring(math.floor(year)),
      [2] = abbrev,
      [3] = tostring(math.floor(day)),
    }
    local cacheKey = string.format("181:0:rec:%s:date:%s-%s-%s", slots[0], slots[1], slots[2], slots[3])
    paintText(resources, formatDynamic(self, resources, 181, 0, slots, cacheKey), 8, 8)
  end
  local party = status.party
  if type(party) ~= "table" then
    return
  end
  local keys = showcaseIconKeys(resources, party)
  drawIcons(resources, keys)
  local cursor = math.floor(tonumber(status.cursor) or 0)
  local exitSelected = status.exitSelected == true
  -- Cursor: the selected cell carries the marker so keyboard and touch
  -- operate on the same visible control; empty slots show no marker.
  if not exitSelected and party[cursor + 1] ~= nil then
    local anchor = GRID_ANCHORS[cursor]
    if anchor ~= nil then
      paintText(resources, ">", math.max(0, anchor.x - 10), anchor.y + 8)
    end
  end
  -- Selected portrait: the correct member's own front picture from the
  -- shared portrait owner (shiny/form/gender resolved, Nidoran-safe),
  -- scaled into the corner panel. Empty selection draws nothing.
  local selected = status.mon
  if type(selected) ~= "table" then
    selected = (not exitSelected) and party[cursor + 1] or nil
  end
  if type(selected) == "table" and type(selected.species) == "string" then
    local normalized = {
      species = selected.species,
      form = tonumber(selected.form) or 0,
      personality = tonumber(selected.personality) or 0,
      origin = { trainerId = tonumber(selected.otId) or 0 },
    }
    local pair = HallOfFamePresentation.portraitSelectorsFor(normalized, resources.monCatalog)
    if pair ~= nil then
      self:_drawPortrait(resources, pair.front, 1, 200, 8, "normal", 1, 0.5)
    end
  end
  -- Selected detail: nickname/species/level/OT/moves for the cursor
  -- member, in the detail panel over the sub background (112..192).
  -- Layout is a deliberate single-pane adaptation: header lines stack at
  -- 10px rows (116/126/136) and all four moves paint in a two-column
  -- grid (148/158/168/178 split across x=8 and x=104) so long names and
  -- four-move sets never clip and never overlap the 3x2 icon grid above.
  -- Empty slots and the exit target draw the Return line instead.
  if not exitSelected and type(selected) == "table" then
    local mon = selected
    local name = tostring(mon.nickname or mon.species or "")
    local speciesLabel = type(mon.species) == "string" and speciesName(self, resources, mon.species) or ""
    if name == "" or name == tostring(mon.species) then
      name = speciesLabel
    end
    local gender = mon.gender
    if gender == nil and type(mon.personality) == "number" then
      gender = derivedGender(resources, mon.species, mon.personality)
    end
    -- Retail suppresses the gender mark for Nidoran F/M
    -- (hall_of_fame_showcase.c ShowMonDetail): both sexes paint no mark.
    local genderSuffix = ""
    if mon.species ~= "NIDORAN_F" and mon.species ~= "NIDORAN_M" then
      if gender == "male" then
        genderSuffix = " " .. messageLine(self, resources, 181, 3)
      elseif gender == "female" then
        genderSuffix = " " .. messageLine(self, resources, 181, 4)
      end
    end
    local lv = math.floor(tonumber(mon.level) or 0)
    local levelKey = "181:1:lv:" .. tostring(lv)
    local levelLine = formatDynamic(self, resources, 181, 1, { [0] = tostring(lv) }, levelKey)
    paintText(resources, name .. " " .. speciesLabel .. genderSuffix, 8, 116)
    paintText(resources, levelLine, 8, 126)
    paintText(resources, messageLine(self, resources, 181, 2) .. tostring(mon.otName or ""), 8, 136)
    local moves = mon.moves
    if type(moves) == "table" then
      -- Two-column move grid: all four slots paint, empty slots paint
      -- nothing but keep their cells so navigation geometry stays stable.
      for index = 1, 4 do
        local move = moves[index]
        if type(move) == "string" and move ~= "" then
          local col = (index - 1) % 2
          local row = math.floor((index - 1) / 2)
          local moveX = col == 0 and 8 or 104
          local moveY = 148 + row * 12
          if moveY + 8 > 192 then
            moveY = 192 - 8
          end
          paintText(resources, moveName(self, resources, move), moveX, moveY)
        end
      end
    end
  else
    paintText(resources, messageLine(self, resources, 181, 6), 8, 116)
  end
  -- Paint the exit target at its own anchor in both states (not only
  -- while selected) and the paging arrows only while a page exists that
  -- way, so keyboard and touch operate on the same visible controls.
  do
    local recordNumber = tonumber(status.recordNumber) or 0
    local total = tonumber(status.total) or recordNumber
    local retained = tonumber(status.retained) or 1
    if retained < 1 then
      retained = 1
    end
    local hasPrev = recordNumber < total
    local hasNext = recordNumber > total - retained + 1
    local exitAnchor = GRID_ANCHORS[6]
    local exitMarker = exitSelected and "> " or "  "
    paintText(resources, exitMarker .. messageLine(self, resources, 181, 6), exitAnchor.x, exitAnchor.y)
    if hasPrev then
      paintText(resources, "<", SHOWCASE_PREV_HIT.x, SHOWCASE_PREV_HIT.y)
    end
    if hasNext then
      paintText(resources, ">", SHOWCASE_NEXT_HIT.x, SHOWCASE_NEXT_HIT.y)
    end
  end
end

-- Draw helpers behind the registration and credit choreography. All art is
-- admitted before draw; a missing image, page, or text line is a terminal
-- bundle fault, never a silent skip, so the mandatory sequences never play
-- over a partial surface.

-- One admitted bundle image, failing closed when the phase draws an image
-- its receipt never admitted.
---@param self HallOfFamePresentation
---@param path string content-addressed image path
---@return love.Image
function HallOfFamePresentation:_admittedImage(path)
  assert(type(path) == "string" and path ~= "", "an admitted image names its path")
  local image = self._images ~= nil and self._images[path] or nil
  if image == nil then
    Errors.raise("FIELD_ENDING_ASSET_MISSING", "the League ending draws only admitted images", { path = path })
  end
  assert(image ~= nil, "an admitted image exists after the missing-image error")
  return image
end

-- The showcase detail-panel crop quad, owned with the admitted page: keyed
-- by realized dimensions so host resizes reuse it instead of rebuilding
-- the quad every frame. Lives on the class so local draw functions never
-- reach the private quad cache directly.
---@param resources table<string, unknown>
---@param width number realized image width
---@param height number realized image height
---@return love.Quad quad
function HallOfFamePresentation:_showcaseSubBgQuad(resources, width, height)
  local graphics = assert(resources.graphics, "the showcase quad borrows its host graphics namespace")
  assert(type(graphics.newQuad) == "function", "the showcase quad needs its host quad constructor")
  self._quads = self._quads or {}
  local key = string.format("showcase:subBg:%dx%d", width, height)
  local quad = self._quads[key]
  if quad == nil then
    quad = graphics.newQuad(0, 112, 256, 80, width, height)
    self._quads[key] = quad
  end
  assert(quad ~= nil, "the showcase sub background caches its crop quad")
  return quad
end

-- Draws one image, tinted when the phase draws a silhouette instead of the
-- admitted pixels: black silhouettes reuse the admitted image with a black
-- ink, so only white and red variants are precolored at admission.
---@param resources table<string, unknown>
---@param image love.Image
---@param quad love.Quad? nil draws the whole image
---@param x number
---@param y number
---@param ink { r: number, g: number, b: number } multiply ink, 0..1 per channel
---@param alpha number opacity
---@param scaleX number? uniform horizontal scale, 1 when absent
---@param scaleY number? uniform vertical scale, defaults to scaleX
function HallOfFamePresentation:_drawTinted(resources, image, quad, x, y, ink, alpha, scaleX, scaleY)
  local graphics = assert(resources.graphics, "the ending presentation borrows its host graphics namespace")
  assert(type(graphics.draw) == "function", "the ending graphics draws its images")
  local lg = love ~= nil and love.graphics or nil
  local prevR, prevG, prevB, prevA = 1, 1, 1, 1
  if lg ~= nil and type(lg.getColor) == "function" and type(lg.setColor) == "function" then
    prevR, prevG, prevB, prevA = lg.getColor()
    lg.setColor(ink.r, ink.g, ink.b, alpha)
  end
  local sx = tonumber(scaleX) or 1
  local sy = tonumber(scaleY) or sx
  if sx ~= 1 or sy ~= 1 then
    if quad ~= nil then
      graphics.draw(image, quad, x, y, 0, sx, sy)
    else
      graphics.draw(image, x, y, 0, sx, sy)
    end
  elseif quad ~= nil then
    graphics.draw(image, quad, x, y)
  else
    graphics.draw(image, x, y)
  end
  if lg ~= nil and type(lg.setColor) == "function" then
    lg.setColor(prevR, prevG, prevB, prevA)
  end
end

-- One admitted portrait frame: the page image (or its white silhouette
-- variant) plus a cached frame quad. Black silhouettes reuse the admitted
-- page with a black ink instead of another copy.
---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param selector string portrait selector
---@param frameIdx integer 1-based portrait frame
---@param palette string "normal" | "black" | "white"
---@return love.Image image, love.Quad quad
function HallOfFamePresentation:_portraitFrame(resources, selector, frameIdx, palette)
  assert(type(selector) == "string" and selector ~= "", "a portrait draw names its selector")
  local manifest = assert(self._portraitManifest, "portraits draw from the admitted manifest")
  assert(type(manifest.entries) == "table", "the portrait manifest carries its entries")
  local entry = assert(manifest.entries[selector], "the portrait manifest carries its selector: " .. selector)
  assert(type(entry.frames) == "table", "a portrait entry carries its frames: " .. selector)
  local frame = assert(entry.frames[frameIdx], "a portrait entry carries its frame: " .. selector)
  local MonCache = require("libs.assets.src.MonCache")
  local pagePath = MonCache.portraitPagePath(assert(entry.pageId, "a portrait entry carries its page"))
  local pages = self._portraitPages
  assert(type(pages) == "table", "portrait pages admit before they draw")
  local record = pages[pagePath]
  assert(type(record) == "table", "a portrait page is admitted before it draws: " .. selector)
  local image = record.image
  assert(image ~= nil, "an admitted portrait page carries its image")
  -- Quads are keyed by selector (not page): two selectors sharing one page
  -- sample different manifest rectangles even at the same frame index.
  local key = selector .. "#" .. tostring(frameIdx)
  if palette == "white" then
    local silhouettes = assert(self._silhouettes, "silhouettes admit before they draw")
    local white = assert(silhouettes["white:" .. pagePath], "a white silhouette is admitted before it draws")
    image = assert(white.image, "an admitted white silhouette carries its image")
    key = key .. ":white"
  end
  self._quads = self._quads or {}
  local quad = self._quads[key]
  if quad == nil then
    local graphics = assert(resources.graphics, "portrait quads need their host graphics namespace")
    assert(type(graphics.newQuad) == "function", "portrait quads need their host quad constructor")
    local width, height = image:getWidth(), image:getHeight()
    quad = graphics.newQuad(frame.x, frame.y, frame.width, frame.height, width, height)
    self._quads[key] = quad
  end
  return image, quad
end

-- Draws one baked animation frame at a sprite anchor, honoring the
-- source bounding-box origin. Blank frames draw nothing. White and red
-- silhouettes draw the precolored variant admitted for that image.
---@param resources table<string, unknown>
---@param frames table[] baked frames with paths and origins
---@param frameIndex number 1-based frame, integral
---@param x number anchor x
---@param y number anchor y
---@param palette string "normal" | "black" | "white" | "red"
---@param alpha number opacity
---@param scale number? uniform sprite scale from the scene track, 1 when absent
function HallOfFamePresentation:_drawBakedFrame(resources, frames, frameIndex, x, y, palette, alpha, scale)
  local frame = frames[frameIndex]
  if type(frame) ~= "table" or frame.blank == true then
    return
  end
  local framePath = frame.path
  assert(type(framePath) == "string", "a drawn frame names its published image")
  local image = self:_admittedImage(framePath)
  if palette == "white" or palette == "red" then
    local key = framePath .. ":" .. palette
    local silhouettes = self._silhouettes
    assert(type(silhouettes) == "table", "silhouettes admit before they draw")
    local cached = silhouettes[key]
    assert(type(cached) == "table", "a silhouette variant is admitted before it draws: " .. key)
    local variant = cached.image
    assert(variant ~= nil, "an admitted silhouette carries its image: " .. key)
    image = variant
  end
  local ox = 0
  local oy = 0
  if type(frame.origin) == "table" then
    ox = tonumber(frame.origin.x) or 0
    oy = tonumber(frame.origin.y) or 0
  end
  local drawScale = tonumber(scale) or 1
  -- Scale the source bounding-box origin with the frame: the native
  -- origin is in unscaled cell pixels around the sprite anchor, so a
  -- nonzero origin must scale with the frame instead of shifting the
  -- scaled sprite by the full unscaled offset.
  local sx = x + ox * drawScale
  local sy = y + oy * drawScale
  if palette == "black" then
    self:_drawTinted(resources, image, nil, sx, sy, { r = 0, g = 0, b = 0 }, alpha, drawScale, drawScale)
  else
    self:_drawTinted(resources, image, nil, sx, sy, { r = 1, g = 1, b = 1 }, alpha, drawScale, drawScale)
  end
end

-- Draws one recorded mon picture: the admitted portrait page (or its white
-- silhouette variant) framed by the manifest rectangle.
---@param resources table<string, unknown>
---@param selector string portrait selector
---@param frameIdx integer 1-based portrait frame
---@param x number
---@param y number
---@param palette string "normal" | "black" | "white"
---@param alpha number opacity
---@param scale number? uniform sprite scale from the scene track, 1 when absent
function HallOfFamePresentation:_drawPortrait(resources, selector, frameIdx, x, y, palette, alpha, scale)
  local image, quad = self:_portraitFrame(resources, selector, frameIdx, palette)
  local drawScale = tonumber(scale) or 1
  if palette == "black" then
    self:_drawTinted(resources, image, quad, x, y, { r = 0, g = 0, b = 0 }, alpha, drawScale, drawScale)
  else
    self:_drawTinted(resources, image, quad, x, y, { r = 1, g = 1, b = 1 }, alpha, drawScale, drawScale)
  end
end

-- One text line, drawn from the admitted cache only.
---@param resources table<string, unknown>
---@param key string admit/draw cache identity
---@param x integer
---@param y integer
function HallOfFamePresentation:_paintCached(resources, key, x, y)
  paintText(resources, requireCached(self, key, "registration draw"), x, y)
end

-- One precolored silhouette copy of an admitted bundle image, cached by
-- identity. Black silhouettes draw straight from the admitted image with
-- a black ink instead of another copy. Missing host namespaces stay
-- pending; a missing image or unreadable pixels is terminal.
---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param path string admitted bundle image path to recolor
---@param color {r: integer, g: integer, b: integer}
---@param key string cache identity
---@return love.Image? image, nil while pending
---@return string? failure
function HallOfFamePresentation:_silhouetteCopy(resources, path, color, key)
  self._silhouettes = self._silhouettes or {}
  local cached = self._silhouettes[key]
  if cached ~= nil then
    return cached.image, nil
  end
  local okImage, image = pcall(self._admittedImage, self, path)
  if not okImage then
    return nil, tostring(image)
  end
  local cacheFs = resources.cacheFs
  local graphics = resources.graphics
  if cacheFs == nil or graphics == nil then
    return nil, nil
  end
  if type(love) ~= "table" or type(love.image) ~= "table" or type(love.image.newImageData) ~= "function" then
    return nil, nil
  end
  local okBytes, bytes = pcall(cacheFs.read, cacheFs, path)
  if not okBytes or type(bytes) ~= "string" then
    return nil, "silhouette reads no published bytes: " .. tostring(path)
  end
  local fileData
  if type(cacheFs.newFileData) == "function" then
    local okFd, fd = pcall(cacheFs.newFileData, cacheFs, bytes, path)
    if not okFd then
      return nil, "silhouette admits no file data: " .. tostring(path)
    end
    fileData = fd
  else
    fileData = love.filesystem.newFileData(bytes, path)
  end
  local okData, data = pcall(love.image.newImageData, fileData)
  if not okData or data == nil then
    return nil, "silhouette reads no admitted pixels: " .. tostring(path)
  end
  assert(data ~= nil, "silhouette pixels exist after the missing-pixels check")
  local width, height = data:getWidth(), data:getHeight()
  local okMap, mapErr = pcall(function()
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        local _, _, _, a = data:getPixel(x, y)
        if a == 0 then
          data:setPixel(x, y, 0, 0, 0, 0)
        else
          data:setPixel(x, y, color.r / 31, color.g / 31, color.b / 31, a)
        end
      end
    end
  end)
  if not okMap then
    return nil, "silhouette maps no admitted pixels: " .. tostring(mapErr)
  end
  local okUpload, uploaded = pcall(graphics.newImage, data)
  if not okUpload or uploaded == nil then
    return nil, "silhouette uploads no GPU art: " .. tostring(path)
  end
  assert(uploaded ~= nil, "a silhouette image exists after the missing-image check")
  if type(uploaded.setFilter) == "function" then
    pcall(uploaded.setFilter, uploaded, "nearest", "nearest")
  end
  local record = { image = uploaded }
  self._silhouettes[key] = record
  return uploaded, nil
end

-- A fullscreen color overlay (photo flashes fade in from white, fades and
-- The End transitions fade through black).
---@param resources table<string, unknown>
---@param r number
---@param g number
---@param b number
---@param alpha number
local function paintOverlay(resources, r, g, b, alpha)
  local graphics = assert(resources.graphics, "the ending presentation borrows its host graphics namespace")
  assert(type(graphics.rectangle) == "function", "the ending graphics draws its overlays")
  local lg = love ~= nil and love.graphics or nil
  local prevR, prevG, prevB, prevA = 1, 1, 1, 1
  if lg ~= nil and type(lg.getColor) == "function" and type(lg.setColor) == "function" then
    prevR, prevG, prevB, prevA = lg.getColor()
    lg.setColor(r, g, b, alpha)
  end
  graphics.rectangle("fill", 0, 0, 256, 192)
  if lg ~= nil and type(lg.setColor) == "function" then
    lg.setColor(prevR, prevG, prevB, prevA)
  end
end

-- Draws a text line that may carry the source's own line break: lines stack
-- at a fixed 12px leading so the caught detail keeps its two-line shape.
---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param key string admit/draw cache identity
---@param x integer
---@param y integer
local function paintCachedLines(self, resources, key, x, y)
  local text = requireCached(self, key, "registration draw")
  local lineY = y
  for line in tostring(text):gmatch("[^\n]+") do
    paintText(resources, line, x, lineY)
    lineY = lineY + 12
  end
end

-- The individual reveal for the open member: background layers with the
-- scene's scroll offsets, back and front pictures with their animation
-- frames and silhouettes, the follower sprite with the shared overworld
-- frames, and the header/nickname/species/caught windows as each prints.
---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param view table<string, unknown> draw snapshot with the scene and party
---@param scene table<string, unknown> immutable individual snapshot
---@param registration table<string, unknown> bundle registration section
local function drawIndivScene(self, resources, view, scene, registration)
  local party = view.party
  assert(type(party) == "table", "the individual reveal draws its recorded party")
  local mon = assert(party[scene.monIndex + 1], "the individual reveal draws its open member")
  local catalog = resources.monCatalog
  -- Background layers with the scene's scroll offsets.
  local bg = scene.bg or {}
  local bgLayers = registration.bgIndiv
  assert(type(bgLayers) == "table", "the bundle carries its individual backgrounds")
  for index = 1, 3 do
    local layer = bg[index + 1]
    local section = bgLayers[index]
    if type(section) == "table" and type(section.path) == "string" and type(layer) == "table" then
      self:_drawTinted(resources, self:_admittedImage(section.path), nil, layer.x or 0, layer.y or 0, {
        r = 1,
        g = 1,
        b = 1,
      }, 1)
    end
  end
  -- Party members and shadows, in back-to-front order.
  local selectors = HallOfFamePresentation.portraitSelectorsFor(mon, catalog)
  assert(selectors ~= nil, "the individual reveal resolves its portrait: " .. tostring(mon.species))
  local backFrame = math.floor(tonumber(scene.backFrame) or 0) + 1
  local frontFrame = math.floor(tonumber(scene.frontFrame) or 0) + 1
  for _, sprite in ipairs(scene.sprites or {}) do
    if sprite.visible ~= false then
      local kinds = {
        back = { selector = selectors.back, frame = backFrame, size = 80 },
        front = { selector = selectors.front, frame = frontFrame, size = 80 },
      }
      local entry = kinds[sprite.kind]
      if entry ~= nil then
        self:_drawPortrait(
          resources,
          entry.selector,
          entry.frame,
          sprite.x,
          sprite.y,
          sprite.palette or "normal",
          tonumber(sprite.alpha) or 1,
          tonumber(sprite.scale) or 1
        )
      elseif sprite.kind == "ow" then
        -- Species-specific follower stand-in: the correct mon's own front
        -- portrait at half scale (documented 2D adaptation), never a
        -- generic overworld frame shared across species.
        self:_drawPortrait(
          resources,
          selectors.front,
          1,
          sprite.x,
          sprite.y,
          sprite.palette or "normal",
          tonumber(sprite.alpha) or 1,
          (tonumber(sprite.scale) or 1) * 0.5
        )
      elseif sprite.kind == "backShadow" or sprite.kind == "frontShadow" or sprite.kind == "owShadow" then
        local shadow = assert(registration.shadow, "the bundle carries its shadow frames")
        local shadowSeq = assert(shadow[0], "the shadow sequence carries its rest frame")
        local frames = assert(shadowSeq.frames, "a shadow sequence carries its frames")
        self:_drawBakedFrame(
          resources,
          frames,
          1,
          sprite.x,
          sprite.y,
          sprite.palette or "black",
          tonumber(sprite.alpha) or 1,
          tonumber(sprite.scale) or 1
        )
      end
    end
  end
  -- Windows: the header plus nickname/species/caught detail as each prints.
  -- Single-pane layout: the text column follows the reveal side.
  local left = scene.side ~= "right"
  local listX = left and 8 or 136
  local windows = scene.windows or {}
  if windows.header then
    paintWindow(resources, { x = 0, y = 0, width = 256, height = 16 })
    self:_paintCached(resources, "180:0", 8, 2)
  end
  local speciesLabel = speciesName(self, resources, tostring(mon.species))
  local nickname = mon.nickname
  if type(nickname) ~= "string" or nickname == "" then
    nickname = speciesLabel
  end
  if windows.nickname then
    paintWindow(resources, { x = listX, y = 24, width = 112, height = 16 })
    self:_paintCached(resources, "180:4:nick:" .. nickname, listX + 2, 26)
  end
  if windows.species then
    paintWindow(resources, { x = listX, y = 48, width = 112, height = 32 })
    local gender, printGender = HallOfFamePresentation.monGender(mon, resources.monCatalog)
    local line = 3
    if printGender and gender == "male" then
      line = 1
    elseif printGender and gender == "female" then
      line = 2
    end
    self:_paintCached(resources, "180:" .. line .. ":sp:" .. speciesLabel, listX + 2, 50)
    self:_paintCached(resources, "180:5:lv:" .. tostring(mon.level), listX + 2, 62)
  end
  if windows.caught then
    paintWindow(resources, { x = listX, y = 96, width = 112, height = 72 })
    local otName = tostring(mon.otName or (type(mon.origin) == "table" and mon.origin.trainerName or ""))
    self:_paintCached(resources, "180:6:ot:" .. otName, listX + 2, 98)
    local kind = HallOfFamePresentation.metDetailKind(mon, {
      name = tostring(view.playerName or ""),
      trainerId = tonumber(view.trainerId) or 0,
    })
    -- The detail key mirrors admission exactly: location-detail lines
    -- key on the resolved landmark name, never the numeric location.
    local line = 9
    if kind == "caught" then
      line = 7
    elseif kind == "hatched" then
      line = 8
    elseif kind == "kanto" then
      line = 10
    elseif kind == "hoenn" then
      line = 11
    elseif kind == "orre" then
      line = 12
    elseif kind == "fateful" then
      line = 13
    elseif kind == "sinnoh" then
      line = 14
    elseif kind == "shuckie" or kind == "kenya" then
      line = 15
    end
    if line == 7 or line == 8 or line == 15 then
      local metLocation = 0
      if type(mon.met) == "table" and type(mon.met.location) == "number" then
        metLocation = mon.met.location
      end
      local memo = assert(self:memoMaps(), "the memo maps admit before the reveal draws")
      local landmark = HallOfFamePresentation.landmarkName(memo, metLocation)
      paintCachedLines(self, resources, "180:" .. tostring(line) .. ":loc:" .. landmark, listX + 2, 110)
    else
      paintCachedLines(self, resources, "180:" .. tostring(line), listX + 2, 110)
    end
  end
  -- Photo flash and fade overlays ride above the reveal.
  if (tonumber(scene.flashAlpha) or 0) > 0 then
    paintOverlay(resources, 1, 1, 1, tonumber(scene.flashAlpha) or 0)
  end
  local fade = tonumber(scene.fadeAlpha) or 0
  if fade > 0 then
    paintOverlay(resources, 0, 0, 0, fade)
  end
end

-- The whole-party group photo: the admitted whole-party backgrounds, the
-- six recorded mons with shadows, the player picture with its twinkle,
-- spotlights and confetti while the effects run, and the two whole-party
-- windows. The terminal wait leaves the group on screen behind the
-- acknowledgment input.
---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param view table<string, unknown> draw snapshot with the scene and party
---@param scene table<string, unknown> immutable whole-party snapshot
---@param registration table<string, unknown> bundle registration section
local function drawWholeScene(self, resources, view, scene, registration)
  local party = view.party
  assert(type(party) == "table", "the whole-party scene draws its recorded party")
  local whole = assert(registration.bgWhole, "the bundle carries its whole-party backgrounds")
  local scrollX = 0
  if type(scene.bg) == "table" then
    for _, layer in ipairs(scene.bg) do
      if type(layer) == "table" and layer.key == "bgWhole1" then
        scrollX = tonumber(layer.x) or 0
      end
    end
  end
  if type(whole[1]) == "table" and type(whole[1].path) == "string" then
    -- The polka-dot layer wraps over its own width so a continuously held
    -- photo never scrolls the finite layer offscreen.
    local wrappedX = scrollX
    local admitted = self:_admittedImage(whole[1].path)
    if type(admitted.getWidth) == "function" then
      local okWidth, layerWidth = pcall(admitted.getWidth, admitted)
      if okWidth and type(layerWidth) == "number" and layerWidth > 0 then
        wrappedX = scrollX % layerWidth
        if wrappedX > 0 then
          wrappedX = wrappedX - layerWidth
        end
        self:_drawTinted(resources, admitted, nil, wrappedX + layerWidth, 0, { r = 1, g = 1, b = 1 }, 1)
      end
    end
    self:_drawTinted(resources, admitted, nil, wrappedX, 0, { r = 1, g = 1, b = 1 }, 1)
  end
  if type(whole[2]) == "table" and type(whole[2].path) == "string" then
    self:_drawTinted(resources, self:_admittedImage(whole[2].path), nil, 0, 0, { r = 1, g = 1, b = 1 }, 1)
  end
  local catalog = resources.monCatalog
  local function frameIndex(sequence, tick)
    return HallOfFamePresentation.frameAt(sequence, tick)
  end
  for _, sprite in ipairs(scene.sprites or {}) do
    if sprite.visible ~= false then
      local alpha = tonumber(sprite.alpha) or 1
      if sprite.kind == "mon" then
        local mon = party[(tonumber(sprite.slot) or 0) + 1]
        if type(mon) == "table" and type(mon.species) == "string" then
          local selectors = HallOfFamePresentation.portraitSelectorsFor(mon, catalog)
          if selectors ~= nil then
            self:_drawPortrait(
              resources,
              selectors.front,
              1,
              sprite.x,
              sprite.y,
              sprite.palette or "normal",
              alpha,
              tonumber(sprite.scale) or 1
            )
          end
        end
      elseif sprite.kind == "monShadow" then
        local shadow = assert(registration.shadow, "the bundle carries its shadow frames")
        local seq = assert(shadow[0], "the shadow sequence carries its rest frame")
        local index = frameIndex(seq, tonumber(scene.tick) or 0)
        local trackFrames = seq.frames
        assert(type(trackFrames) == "table", "a mon track carries its front frames")
        self:_drawBakedFrame(
          resources,
          trackFrames,
          index,
          sprite.x,
          sprite.y,
          "white",
          alpha,
          tonumber(sprite.scale) or 1
        )
      elseif sprite.kind == "player" then
        local playerPics = view.playerGender == "female" and registration.playerLyra or registration.playerEthan
        assert(type(playerPics) == "table", "the bundle carries its player frames")
        local playerSeq = playerPics[0]
        assert(type(playerSeq) == "table", "the player pictures carry their rest frame")
        local playerFrames = playerSeq.frames
        assert(type(playerFrames) == "table", "a player sequence carries its frames")
        local index = frameIndex({ frames = playerFrames }, tonumber(scene.wholeClock) or 0)
        self:_drawBakedFrame(
          resources,
          playerFrames,
          index,
          sprite.x,
          sprite.y,
          "normal",
          alpha,
          tonumber(sprite.scale) or 1
        )
      elseif sprite.kind == "playerShadow" then
        local twinkleShadow = registration.twinkleShadow
        assert(type(twinkleShadow) == "table", "the bundle carries its twinkle shadow")
        local shadowSeq = twinkleShadow[0]
        assert(type(shadowSeq) == "table", "the twinkle shadow carries its rest frame")
        local shadowFrames = shadowSeq.frames
        assert(type(shadowFrames) == "table", "a shadow sequence carries its frames")
        local index = frameIndex({ frames = shadowFrames }, tonumber(scene.wholeClock) or 0)
        self:_drawBakedFrame(
          resources,
          shadowFrames,
          index,
          sprite.x,
          sprite.y,
          "normal",
          alpha,
          tonumber(sprite.scale) or 1
        )
      elseif sprite.kind == "twinkle" then
        local tw = scene.twinkle
        if type(tw) == "table" then
          local twinkle = assert(registration.twinkle, "the bundle carries its twinkle frames")
          local twinkleSeq = assert(twinkle[0], "the twinkle carries its rest frame")
          local index = frameIndex(twinkleSeq, tonumber(tw.clock) or 0)
          self:_drawBakedFrame(
            resources,
            assert(twinkleSeq.frames),
            index,
            tonumber(tw.x) or 0,
            tonumber(tw.y) or 0,
            "normal",
            alpha
          )
        end
      end
    end
  end
  -- Spotlights sweep while the whole-party effects run: translucent beams
  -- from the top of the pane, ping-ponging between 10 and 170 degrees at
  -- the source speeds over the source colors.
  if scene.spotlights then
    local inits = { 20, 60, 40, 140, 120, 160 }
    local speeds = { 0.75, 0.6875, 0.625, 0.75, 0.6875, 0.625 }
    local colors = registration.spotlightColors
    if type(colors) == "table" then
      for index = 1, 6 do
        local cycle = ((inits[index] - 10 + speeds[index] * (tonumber(scene.tick) or 0)) % 320 + 320) % 320
        local angle = cycle <= 160 and (10 + cycle) or (170 - (cycle - 160))
        local spread = (angle - 90) * 1.5
        local color = colors[index] or { 31, 31, 31 }
        self:_paintSpotlight(resources, 40 + index * 32, spread, color)
      end
    end
  end
  -- Confetti drifts down while the whole-party effects generate it.
  if scene.confetti and type(scene.confettiParticles) == "table" then
    local colors = registration.confettiColors
    if type(colors) == "table" and #colors > 0 then
      for particleIndex, particle in ipairs(scene.confettiParticles) do
        if type(particle) == "table" then
          local color = colors[((particleIndex - 1) % #colors) + 1]
          self:_paintConfetti(
            resources,
            tonumber(particle.x) or 0,
            tonumber(particle.y) or 0,
            tonumber(particle.spin) or 0,
            color
          )
        end
      end
    end
  end
  -- Whole-party windows: the congratulations line up top and the player
  -- identity/play-time line at the bottom.
  paintWindow(resources, { x = 0, y = 0, width = 256, height = 16 })
  paintCachedLines(self, resources, "180:16", 8, 2)
  paintWindow(resources, { x = 0, y = 176, width = 256, height = 16 })
  local wholeKey = self._wholePartyKey
  assert(type(wholeKey) == "string", "the whole-party line is admitted before it draws")
  paintCachedLines(self, resources, wholeKey, 8, 178)
  -- Photo flash and fade overlays ride above the group.
  if (tonumber(scene.flashAlpha) or 0) > 0 then
    paintOverlay(resources, 1, 1, 1, tonumber(scene.flashAlpha) or 0)
  end
  local fade = tonumber(scene.fadeAlpha) or 0
  if fade > 0 then
    paintOverlay(resources, 0, 0, 0, fade)
  end
  local finalFade = tonumber(scene.finalFadeAlpha) or 0
  if finalFade > 0 then
    paintOverlay(resources, 0, 0, 0, finalFade)
  end
end

-- One translucent spotlight beam from the top of the pane, swaying with its
-- source angle. The pane is the single-pane adaptation of the source 3D
-- cones: color and timing stay source-derived, the volume does not.
---@param resources table<string, unknown>
---@param x number top anchor
---@param sway number horizontal drift in pixels
---@param color {r: integer, g: integer, b: integer}
function HallOfFamePresentation:_paintSpotlight(resources, x, sway, color)
  local graphics = assert(resources.graphics, "the ending presentation borrows its host graphics namespace")
  local lg = love ~= nil and love.graphics or nil
  local prevR, prevG, prevB, prevA = 1, 1, 1, 1
  if lg ~= nil and type(lg.getColor) == "function" and type(lg.setColor) == "function" then
    prevR, prevG, prevB, prevA = lg.getColor()
    lg.setColor(color[1] / 31, color[2] / 31, color[3] / 31, 0.15)
  end
  if type(graphics.polygon) == "function" then
    graphics.polygon("fill", x, 0, x + 24, 0, x + 24 + sway + 30, 192, x + sway - 30, 192)
  end
  if lg ~= nil and type(lg.setColor) == "function" then
    lg.setColor(prevR, prevG, prevB, prevA)
  end
end

-- One confetti quad, rotated by its spin. Colors cycle through the source
-- table in spawn order.
---@param resources table<string, unknown>
---@param x number
---@param y number
---@param spin number ticks since the particle spawned
---@param color {r: integer, g: integer, b: integer}
function HallOfFamePresentation:_paintConfetti(resources, x, y, spin, color)
  local graphics = assert(resources.graphics, "the ending presentation borrows its host graphics namespace")
  local lg = love ~= nil and love.graphics or nil
  local prevR, prevG, prevB, prevA = 1, 1, 1, 1
  if lg ~= nil and type(lg.getColor) == "function" and type(lg.setColor) == "function" then
    prevR, prevG, prevB, prevA = lg.getColor()
    lg.setColor(color[1] / 31, color[2] / 31, color[3] / 31, 1)
  end
  if type(graphics.polygon) == "function" then
    local radians = spin * math.pi / 16
    local cosTheta, sinTheta = math.cos(radians), math.sin(radians)
    local half = 3
    local corners = {}
    for _, corner in ipairs({ { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }) do
      corners[#corners + 1] = x + (corner[1] * half * cosTheta - corner[2] * half * sinTheta)
      corners[#corners + 1] = y + (corner[1] * half * sinTheta + corner[2] * half * cosTheta)
    end
    graphics.polygon("fill", corners)
  end
  if lg ~= nil and type(lg.setColor) == "function" then
    lg.setColor(prevR, prevG, prevB, prevA)
  end
end
-- The registration congratulations surface: the source two-scene
-- application over the admitted backgrounds. Every reveal draws its back
-- and front pictures (animated through the baked scripts), the follower
-- sprite, the header and detail windows, shadows and silhouettes at the
-- source stages; the whole-party scene draws its group, player picture,
-- spotlights, confetti and twinkle.
---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param view table<string, unknown> draw snapshot with the scene and party
local function drawRegistration(self, resources, view)
  local registration = view.registrationSection
  assert(type(registration) == "table", "the registration surface reads its bundle section")
  local scene = assert(view.registration, "the registration draw needs its scene snapshot")
  local party = view.party
  assert(type(party) == "table", "the registration surface draws its recorded party")
  if scene.phase == "whole" then
    drawWholeScene(self, resources, view, scene, registration)
    return
  end
  drawIndivScene(self, resources, view, scene, registration)
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

-- The six single-pane dance anchors behind the roll: the source top-screen
-- formation (x 16/240, three rows). The bottom-screen set shares the same
-- baked sequences, so the visible set follows the source display flip while
-- every staged mon keeps dancing its scene's sequence.
---@param index integer 0-based mon within its set of six
---@return integer x, integer y
local function danceAnchor(index)
  local x = 16
  if index >= 3 then
    x = 240
  end
  return x, (index % 3) * 80 + 16
end

-- One realized cutscene sprite sequence: player (5) and friend (7) slots
-- exchange their realized sequences by player gender, mirroring the scene
-- machine's construction-time resolution. A bundle gap is terminal, never
-- a skipped sprite.
---@param credits table<string, unknown> bundle credits section
---@param gender string "male" | "female"
---@param spriteId number source sprite slot
---@param animSeq number source animation sequence number
---@return table<string, unknown> baked sequence
local function cutsceneSequence(credits, gender, spriteId, animSeq)
  local sprites = assert(credits.cutsceneSprites, "the bundle carries its cutscene sprites")
  local entry = assert(sprites[spriteId], "the bundle carries the cutscene sprite: " .. tostring(spriteId))
  local sequences = entry.sequences
  if (spriteId == 5 or spriteId == 7) and gender == "female" then
    sequences = entry.femaleSequences
  end
  assert(type(sequences) == "table", "the bundle carries the cutscene sequences: " .. tostring(spriteId))
  return assert(sequences[animSeq], "the bundle carries the sprite animation: " .. tostring(animSeq))
end

-- The dancing mons and transition clouds over the scene backgrounds. The
-- visible set follows the source display flip: the flip swaps which logical
-- surface the single pane shows, so dancer anchors mirror horizontally
-- while the background layer stack stays stable. Without a scene snapshot
-- only backgrounds roll.
---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param credits table<string, unknown> bundle credits section
---@param choreo table<string, unknown> scene snapshot
local function drawChoreographyDancers(self, resources, credits, choreo)
  local danceSequences = assert(credits.danceSequences, "the bundle carries its dance sequences")
  local danceSeq = assert(danceSequences[choreo.danceSeq], "the bundle carries the scene dance")
  local danceClock = tonumber(choreo.danceClock) or 0
  local flipped = choreo.screensFlipped == true
  for index = 0, 5 do
    local x, y = danceAnchor(index)
    if flipped then
      x = 256 - x
    end
    local frameIndex = HallOfFamePresentation.frameAt(danceSeq, danceClock)
    self:_drawBakedFrame(resources, assert(danceSeq.frames), frameIndex, x, y, "normal", 1)
  end
  if choreo.cloudsVisible then
    local cloudSeq = assert(danceSequences[choreo.cloudSeq], "the bundle carries its cloud sequence")
    local cloudClock = tonumber(choreo.cloudClock) or 0
    for index = 0, 5 do
      local x, y = danceAnchor(index)
      local frameIndex = HallOfFamePresentation.frameAt(cloudSeq, cloudClock)
      self:_drawBakedFrame(resources, assert(cloudSeq.frames), frameIndex, x, y, "normal", 1)
    end
  end
end

-- The active story cutscene sprites over the dancing mons. Each draws its
-- source anchor while active; finished sprites leave with their cutscene.
-- The source places story sprites on the non-primary display
-- (CreateCutsceneSprite) while the text window rides the sub BG
-- (DisplayWindow): the single-pane port keeps both surfaces visible and
-- routes the flip to surface placement (mirrored x), never to the
-- background layer stack.
---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param credits table<string, unknown> bundle credits section
---@param choreo table<string, unknown> scene snapshot
local function drawChoreographyCutscenes(self, resources, credits, choreo)
  local sprites = choreo.cutsceneSprites
  if type(sprites) ~= "table" then
    return
  end
  local gender = choreo.gender == "female" and "female" or "male"
  local flipped = choreo.screensFlipped == true
  for _, sprite in ipairs(sprites) do
    if type(sprite) == "table" and sprite.active then
      local sequence = cutsceneSequence(credits, gender, sprite.spriteId, sprite.animSeq)
      local elapsed = tonumber(sprite.elapsed) or 0
      local frameIndex = HallOfFamePresentation.frameAt(sequence, elapsed)
      local x = tonumber(sprite.x) or 0
      if flipped then
        x = 256 - x
      end
      self:_drawBakedFrame(resources, assert(sequence.frames), frameIndex, x, tonumber(sprite.y) or 0, "normal", 1)
    end
  end
end

---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param status table<string, unknown>
local function drawCredits(self, resources, status)
  local credits = status.creditsSection
  assert(type(credits) == "table", "the credit roll reads its bundle section")
  -- CreditsScene:status() is the sole source of the rendered
  -- scene/flip/page state. The raw timer fallback below serves only
  -- hand-built component snapshots without a choreography; production
  -- always carries the choreography (or its frozen fade snapshot).
  local choreo = status.credits
  local timer = tonumber(status.timer) or 0
  if type(choreo) == "table" and tonumber(choreo.timer) ~= nil then
    timer = tonumber(choreo.timer) or timer
  end
  local page = currentCreditPage(credits, { timer = timer })
  local scenes = credits.scenes
  if type(scenes) == "table" and #scenes > 0 then
    local sceneIndex = 1
    if type(choreo) == "table" and tonumber(choreo.sceneIdx) ~= nil then
      sceneIndex = math.min(math.max(math.floor(tonumber(choreo.sceneIdx) or 0) + 1, 1), #scenes)
    else
      local timings = credits.sceneTransitionTimings
      if type(timings) == "table" then
        for index, timing in ipairs(timings) do
          if tonumber(timing) <= timer then
            sceneIndex = math.min(index + 1, #scenes)
          else
            break
          end
        end
      end
    end
    local scene = scenes[sceneIndex]
    if type(scene) == "table" then
      -- Single-pane adaptation (documented): the source keeps BG2/BG3 as
      -- layers within each engine and swaps which engine drives which
      -- physical display (credits.c HandleSceneFlip). The port composites
      -- one pane, so the background layer stack stays stable (lower then
      -- upper) and the flip routes the logical surfaces (dancers /
      -- cutscenes / text) instead of reordering opaque background layers.
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
  -- The dancing mons, transition clouds and story cutscenes play over the
  -- backgrounds while the text rolls above them, matching the source plane
  -- order in the single-pane composite. Surface flip mirrors dancer and
  -- cutscene placement; text always rides above both surfaces.
  if type(choreo) == "table" and type(choreo.danceSeq) == "number" then
    drawChoreographyDancers(self, resources, credits, choreo)
    drawChoreographyCutscenes(self, resources, credits, choreo)
  end
  -- The source prints the game title at credit init (credits.c), before the
  -- first page rolls: HeartGold message 0, SoulSilver message 1. Painted
  -- after backgrounds so opaque pixels cannot cover it in the single-pane
  -- port (source uses separate BG/text planes).
  if timer < 105 then
    local titles = credits.titleMessages
    if type(titles) == "table" then
      local version = status.versionId
      local titleId = titles.heartgold
      if type(version) == "string" and version:lower():find("soulsilver", 1, true) ~= nil then
        titleId = titles.soulsilver
      end
      if type(titleId) == "number" then
        local bank = assert(credits.messageBank, "the credit roll names its message bank")
        paintText(resources, messageLine(self, resources, bank, titleId), 0, 70)
      end
    end
  end
  if page ~= nil then
    local bank = assert(credits.messageBank, "the credit roll names its message bank")
    for _, line in ipairs(assert(page.lines, "a credit page carries its lines")) do
      local message = messageLine(self, resources, bank, assert(line.message))
      paintText(resources, message, math.floor(tonumber(line.x) or 8), math.floor(tonumber(line.y) or 24))
    end
  end
  -- Source fade envelope: retain the frozen frame and darken it through
  -- the fade instead of restarting the roll. The overlay always applies
  -- after the scene, even while no text page displays, so page gaps and
  -- the opening title fade together with paged frames.
  local fadeAlpha = tonumber(status.fadeAlpha) or 0
  if fadeAlpha > 0 then
    paintOverlay(resources, 0, 0, 0, math.min(1, fadeAlpha))
  end
end

-- The save-status surface: the source saving window (bank 40:15) while the
-- transaction stages, then the source save-result message (bank 40:16 with
-- the real player name, warmed in admission). A failed publication paints
-- the retryable status string the coordinator reports.
---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param status table<string, unknown>
local function drawSaveStatus(self, resources, status)
  paintWindow(resources, { x = 0, y = 0, width = 256, height = 192 })
  local message = status.saveMessage
  if type(message) ~= "string" or message == "" then
    -- No explicit failure string: saving (15) before/during the write,
    -- save-result success (16) once the coordinator published, expanded
    -- with the live player name from cache (no bank acquire in draw).
    -- The fade retains the success surface instead of regressing to the
    -- saving line after publication.
    local phase = status.phase
    if phase == "save_status" or phase == "save_se" or phase == "save_fade" then
      local playerName = type(status.playerName) == "string" and status.playerName or ""
      if playerName ~= "" then
        local cacheKey = "40:16:player:" .. playerName
        message = formatDynamic(self, resources, 40, 16, { [0] = playerName }, cacheKey)
      else
        message = messageLine(self, resources, 40, 15)
      end
    else
      message = messageLine(self, resources, 40, 15)
    end
  end
  paintText(resources, message, 8, 88)
  local fadeAlpha = tonumber(status.fadeAlpha) or 0
  if fadeAlpha > 0 then
    paintOverlay(resources, 0, 0, 0, math.min(1, fadeAlpha))
  end
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
  local fadeAlpha = tonumber(status.fadeAlpha) or 0
  if fadeAlpha > 0 then
    paintOverlay(resources, 0, 0, 0, math.min(1, fadeAlpha))
  end
end

-- A minimal valid application plan over one pane: content draws through the
-- render callback, outer frames stay empty because the source surfaces are
-- self-framed. The pane placement is the native full-screen surface. The
-- showcase pane is interactive with hit-testing over the shared 3x2+exit
-- geometry so touch selects party slots, exit, and record paging.
---@param inputKey string
---@param content table<string, unknown>
---@param render fun(resources: table<string, unknown>, view: table<string, unknown>, plan: table<string, unknown>)
---@param mapInput (fun(event: table<string, unknown>, view: table<string, unknown>|nil, plan: table<string, unknown>|nil): table<string, unknown>|nil)|nil
---@return table<string, unknown>
local function fullScreenPlan(inputKey, content, render, mapInput)
  local function defaultMapInput()
    return nil
  end
  local resolvedMapInput = mapInput or defaultMapInput
  return {
    panes = {
      {
        id = "main",
        interactive = true,
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
    mapInput = resolvedMapInput,
  }
end

-- Shared showcase hit geometry, derived from the one anchor owner above:
-- (moved beside GRID_ANCHORS so drawing and hit-testing share it).

-- Touch routing for the showcase grid: party slots and exit select via
-- touch targets 0..6, record paging via 7 (prev) and 8 (next), matching
-- the source prev/next/exit sprites. Dpad/key navigation still flows
-- through the ScreenState neighbor table. Only a new press
-- (pointer_down) selects: motion and release never activate, so a press
-- on a paging target pages exactly once and hovering/dragging over exit
-- cannot close the app (retail TouchscreenHitbox press semantics).
---@param event table<string, unknown> raw host pointer event
---@return table<string, unknown>|nil
local function showcaseMapInput(event, _, _)
  if type(event) ~= "table" or event.type ~= "pointer_down" or event.outside == true then
    return nil
  end
  local x = tonumber(event.x)
  local y = tonumber(event.y)
  if x == nil or y == nil then
    return nil
  end
  if hitContains(SHOWCASE_PREV_HIT, x, y) then
    return { type = "touch", target = 7 }
  end
  if hitContains(SHOWCASE_NEXT_HIT, x, y) then
    return { type = "touch", target = 8 }
  end
  for index = 0, 6 do
    local box = SHOWCASE_HIT_CELLS[index]
    if box ~= nil and hitContains(box, x, y) then
      return { type = "touch", target = index }
    end
  end
  return nil
end

-- The raw-press mapper the PC showcase child shares: HallOfFameScreenState
-- has no ApplicationPresentation session, so it routes its host pointer
-- batch through this same press-only mapping instead of inventing its own.
---@param event table<string, unknown> raw host pointer event
---@return table<string, unknown>|nil mapped touch event or nil
function HallOfFamePresentation.mapPointerPress(event)
  return showcaseMapInput(event, nil, nil)
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
    drawShowcaseGrid(self_, resources, view)
  end
  return fullScreenPlan("hall-of-fame-showcase", content, renderShowcase, showcaseMapInput)
end

---@return table<string, unknown>|nil per-species picture tracks, nil before the bundle is ready
function HallOfFamePresentation:monTracks()
  if self.sections == nil then
    return nil
  end
  local registration = self.sections.registration
  if type(registration) ~= "table" then
    return nil
  end
  return registration.monTracks
end

-- The credit roll's choreography tables: baked dance sequences by number,
-- one dance sequence per displayed scene, the cloud sequence, the sixteen
-- cutscenes with their sprite params, and realized cutscene sprite
-- sequences by id (female player/friend variants included). Without the
-- bundle the roll owns no choreography.
---@return table<string, unknown>? { danceSequences, danceSeqsByScene, cloudSeq, cutscenes, cutsceneSprites }
function HallOfFamePresentation:creditChoreography()
  if self.sections == nil then
    return nil
  end
  local section = self.sections.credits
  if type(section) ~= "table" then
    return nil
  end
  return {
    danceSequences = section.danceSequences,
    danceSeqsByScene = section.danceSeqsByScene,
    cloudSeq = section.cloudSeq,
    cutscenes = section.cutscenes,
    cutsceneSprites = section.cutsceneSprites,
    transitionTimings = section.sceneTransitionTimings,
    flipTimings = section.screenFlipTimings,
  }
end

-- Notes the player gender the field owner resolved: cutscene player (5)
-- and friend (7) sprites exchange their realized sequences by gender.
---@param gender string "male" | "female"
function HallOfFamePresentation:noteCutsceneGender(gender)
  assert(not self.disposed, "disposed Hall of Fame presentation cannot admit")
  assert(gender == "male" or gender == "female", "the cutscene gender stays binary")
  self._cutsceneGender = gender
end

-- The noted player gender for cutscene sprites, nil until the field owner
-- resolves it outside draw.
---@return string? "male" | "female"
function HallOfFamePresentation:cutsceneGender()
  return self._cutsceneGender
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

-- The save-result dwell, in fixed ticks. Port-wide adaptation (documented):
-- the port paints the saving/result string whole in one frame instead of
-- running the source text printer with the player Options timing, so there
-- is no source printer duration to reproduce. The dwell keeps the success
-- message visible for its full hold before the save sound, independent of
-- bundle art; it is a presentation constant, never a generated property.
HallOfFamePresentation.SAVE_RESULT_DWELL_FRAMES = 30

---@return integer
function HallOfFamePresentation:saveStatusFrames()
  if self.sections == nil then
    return 0
  end
  return HallOfFamePresentation.SAVE_RESULT_DWELL_FRAMES
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

-- Admit the advancing phase's required text and images outside draw:
-- synchronous filesystem reads plus one GPU upload per path, cached for
-- draw-only use. Returns true once every required receipt is admitted; false
-- stays pending (never a draw-time load). A missing image or message is
-- terminal bundle data.
---@param resources table<string, unknown> borrowed generated cache + graphics + message provider
---@param required string[]|nil sections the advancing phase draws; nil means all
---@return boolean admitted
---@return string? failure terminal admission failure
function HallOfFamePresentation:admitImages(resources, required)
  assert(not self.disposed, "disposed Hall of Fame presentation cannot admit")
  local function admit()
    local sections = self.sections
    if sections == nil then
      return false, nil
    end
    local names = required or HallOfFamePresentation.SECTIONS
    -- Already-admitted immutable section preparation is an immediate
    -- no-op: re-walking every published image record on each admitted tick
    -- is pure overhead once the receipt holds.
    do
      local allAdmitted = true
      if self._admittedSections ~= nil and self._admissionFailure == nil then
        for _, name in ipairs(names) do
          if self._admittedSections[name] ~= true then
            allAdmitted = false
            break
          end
        end
      else
        allAdmitted = false
      end
      if allAdmitted then
        return true, nil
      end
    end
    local needed = {}
    for _, name in ipairs(names) do
      needed[name] = true
    end
    self._admittedSections = self._admittedSections or {}
    self._textAdmittedSections = self._textAdmittedSections or {}
    -- A failed receipt stays terminal: never retry a known malformed bundle
    -- as if it were a cold cache.
    if self._admissionFailure ~= nil then
      return false, self._admissionFailure
    end
    local function markAdmitted()
      for _, name in ipairs(names) do
        self._admittedSections[name] = true
        self._textAdmittedSections[name] = true
      end
    end
    local function markTextAdmitted()
      for _, name in ipairs(names) do
        self._textAdmittedSections[name] = true
      end
    end
    -- Admits one published bundle image outside draw: synchronous
    -- filesystem read plus one GPU upload, cached for draw-only use.
    self._images = self._images or {}
    local function admitOne(path)
      if self._images[path] ~= nil then
        return true, nil
      end
      local cacheFs = resources.cacheFs
      local graphics = resources.graphics
      if cacheFs == nil or graphics == nil then
        return false, nil
      end
      assert(type(cacheFs.read) == "function", "image admission reads its published images")
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
    -- Admits every published image in one bundle section by walking its
    -- image records. Pending (not failed) while GPU resources are absent.
    local function admitSectionImages(section)
      local seen = {}
      local pending = false
      local function walk(node)
        if type(node) ~= "table" or seen[node] then
          return true
        end
        seen[node] = true
        if type(node.path) == "string" then
          local ok, failure = admitOne(node.path)
          if not ok then
            if failure == nil then
              pending = true
            else
              return false, failure
            end
          end
          return true
        end
        for _, value in pairs(node) do
          if type(value) == "table" then
            local ok, failure = walk(value)
            if not ok then
              return false, failure
            end
          end
        end
        return true
      end
      local ok, failure = walk(section)
      if not ok then
        return false, failure
      end
      if pending then
        return false, nil
      end
      return true, nil
    end
    -- Warm the required static text outside draw so a steady phase performs
    -- no bank lease churn and a corrupt or unavailable required message
    -- fails here, never mid-draw. A missing provider stays pending: the host
    -- has not composed the text owner yet.
    local provider = resources.messageProvider
    if provider == nil then
      return false, nil
    end
    local staticIds = {}
    if needed.registration then
      -- The static header and caught-detail lines; nickname, species,
      -- level, OT name, landmark-bearing and whole-party lines carry
      -- substitutions and warm separately with real values.
      staticIds[#staticIds + 1] = { 180, 0 }
      for _, id in ipairs({ 9, 10, 11, 12, 13, 14, 16 }) do
        staticIds[#staticIds + 1] = { 180, id }
      end
    end
    if needed.showcase then
      -- Static showcase labels: OT/, gender marks, exit. The record header
      -- (181:0) and level (181:1) are dynamic and warm separately with real
      -- record/level values.
      for _, id in ipairs({ 2, 3, 4, 6 }) do
        staticIds[#staticIds + 1] = { 181, id }
      end
    end
    -- The static saving window (bank 40:15). The save result (40:16) carries
    -- the player name and warms separately via admitSaveResult.
    if needed.save or needed.registration or needed.credits then
      staticIds[#staticIds + 1] = { 40, 15 }
    end
    for _, pair in ipairs(staticIds) do
      local ok, result = pcall(messageLine, self, resources, pair[1], pair[2])
      if not ok then
        self._admissionFailure = "League ending text failed: " .. tostring(result)
        return false, self._admissionFailure
      end
      if type(result) ~= "string" or result == "" then
        self._admissionFailure =
          string.format("League ending text failed: bank %d message %d has no text", pair[1], pair[2])
        return false, self._admissionFailure
      end
    end
    -- Admit the registration backgrounds, overworld/twinkle/shadow frames
    -- and whole-party player frames the reveal draws, whenever the
    -- advancing phase needs them.
    if needed.registration then
      local registration = assert(sections.registration, "the presentation bundle carries its registration section")
      local ok, failure = admitSectionImages(registration)
      if failure ~= nil then
        self._admissionFailure = tostring(failure)
        return false, self._admissionFailure
      end
      if not ok then
        return false, nil
      end
    end
    -- Admit the showcase's own main/sub backgrounds whenever the PC
    -- history surface needs them.
    if needed.showcase then
      local showcase = assert(sections.showcase, "the presentation bundle carries its showcase section")
      local ok, failure = admitSectionImages(showcase)
      if failure ~= nil then
        self._admissionFailure = tostring(failure)
        return false, self._admissionFailure
      end
      if not ok then
        return false, nil
      end
    end
    if not needed.credits then
      markAdmitted()
      return true, nil
    end
    do
      local credits = assert(sections.credits, "the presentation bundle carries its credits section")
      local bank = credits.messageBank
      if type(bank) == "number" then
        -- Edition titles print before the first page (credits.c init).
        local titles = credits.titleMessages
        if type(titles) == "table" then
          for _, titleId in pairs({ titles.heartgold, titles.soulsilver }) do
            if type(titleId) == "number" then
              local ok, result = pcall(messageLine, self, resources, bank, titleId)
              if not ok then
                self._admissionFailure = "League ending text failed: " .. tostring(result)
                return false, self._admissionFailure
              end
              if type(result) ~= "string" or result == "" then
                self._admissionFailure =
                  string.format("League ending text failed: bank %d message %d has no text", bank, titleId)
                return false, self._admissionFailure
              end
            end
          end
        end
        for _, page in ipairs(assert(credits.pages, "the credit roll carries its pages")) do
          if type(page.lines) == "table" then
            for _, line in ipairs(page.lines) do
              if type(line.message) == "number" then
                local ok, result = pcall(messageLine, self, resources, bank, line.message)
                if not ok then
                  self._admissionFailure = "League ending text failed: " .. tostring(result)
                  return false, self._admissionFailure
                end
                if type(result) ~= "string" or result == "" then
                  self._admissionFailure =
                    string.format("League ending text failed: bank %d message %d has no text", bank, line.message)
                  return false, self._admissionFailure
                end
              end
            end
          end
        end
      end
      local cacheFs = resources.cacheFs
      local graphics = resources.graphics
      -- Text is admitted even when GPU resources are absent: the transaction
      -- clock advances on text headless while draw holds on images. Mark the
      -- text receipt before the graphics gate so headless ticks unblock.
      markTextAdmitted()
      if cacheFs == nil or graphics == nil then
        return false, nil
      end
      assert(type(cacheFs.read) == "function", "image admission reads its published images")
      assert(type(graphics.newImage) == "function", "image admission uploads its backgrounds")
      -- Admit every published credit image, including the dancing, cloud
      -- and cutscene frames the choreography draws.
      do
        local ok, failure = admitSectionImages(credits)
        if failure ~= nil then
          self._admissionFailure = tostring(failure)
          return false, self._admissionFailure
        end
        if not ok then
          return false, nil
        end
      end
      markAdmitted()
      return true, nil
    end
  end
  return withAdmission(self, admit)
end

-- Warm the showcase record header (bank 181:0) with its real record number
-- and local date, outside draw. Retail expands placeholders for record
-- number, year, month abbrev and day (hall_of_fame_showcase.c ChangeRecord).
---@param recordNumber integer
---@param date table<string, integer>|nil {year,month,day}
---@param resources table<string, unknown> message provider + fontDef
---@return boolean admitted
---@return string? failure
function HallOfFamePresentation:admitShowcaseHeader(recordNumber, date, resources)
  assert(not self.disposed, "disposed Hall of Fame presentation cannot admit")
  local function admit()
    if self.sections == nil then
      return false, nil
    end
    if self._admissionFailure ~= nil then
      return false, self._admissionFailure
    end
    if resources.messageProvider == nil then
      return false, nil
    end
    local year = 0
    local month = 1
    local day = 1
    if type(date) == "table" then
      year = tonumber(date.year) or 0
      month = tonumber(date.month) or 1
      day = tonumber(date.day) or 1
    end
    local abbrevOk, abbrev = pcall(monthAbbrev, self, resources, month)
    if not abbrevOk or type(abbrev) ~= "string" or abbrev == "" then
      self._admissionFailure = "League ending month failed: " .. tostring(abbrev)
      return false, self._admissionFailure
    end
    local slots = {
      [0] = tostring(math.floor(tonumber(recordNumber) or 0)),
      [1] = tostring(math.floor(year)),
      [2] = abbrev,
      [3] = tostring(math.floor(day)),
    }
    local cacheKey = string.format("181:0:rec:%s:date:%s-%s-%s", slots[0], slots[1], slots[2], slots[3])
    local ok, result = pcall(formatDynamic, self, resources, 181, 0, slots, cacheKey)
    if not ok then
      self._admissionFailure = "League ending header failed: " .. tostring(result)
      return false, self._admissionFailure
    end
    if type(result) ~= "string" or result == "" then
      self._admissionFailure = "League ending header has no text"
      return false, self._admissionFailure
    end
    self._headerAdmitted = true
    return true, nil
  end
  return withAdmission(self, admit)
end

-- Warm one level line (bank 181:1 "Lv.{level}") with its real level.
---@param level integer
---@param resources table<string, unknown>
---@return boolean admitted
---@return string? failure
function HallOfFamePresentation:admitLevel(level, resources)
  assert(not self.disposed, "disposed Hall of Fame presentation cannot admit")
  local function admit()
    if self.sections == nil then
      return false, nil
    end
    if self._admissionFailure ~= nil then
      return false, self._admissionFailure
    end
    if resources.messageProvider == nil then
      return false, nil
    end
    local lv = math.floor(tonumber(level) or 0)
    local cacheKey = "181:1:lv:" .. tostring(lv)
    local ok, result = pcall(formatDynamic, self, resources, 181, 1, { [0] = tostring(lv) }, cacheKey)
    if not ok then
      self._admissionFailure = "League ending level failed: " .. tostring(result)
      return false, self._admissionFailure
    end
    if type(result) ~= "string" or result == "" then
      self._admissionFailure = "League ending level has no text"
      return false, self._admissionFailure
    end
    return true, nil
  end
  return withAdmission(self, admit)
end

-- Warm the save-result line (bank 40:16 "{player} saved the game.") with
-- its real player name.
---@param playerName string
---@param resources table<string, unknown>
---@return boolean admitted
---@return string? failure
function HallOfFamePresentation:admitSaveResult(playerName, resources)
  assert(not self.disposed, "disposed Hall of Fame presentation cannot admit")
  local function admit()
    if self.sections == nil then
      return false, nil
    end
    if self._admissionFailure ~= nil then
      return false, self._admissionFailure
    end
    if resources.messageProvider == nil then
      return false, nil
    end
    if type(playerName) ~= "string" or playerName == "" then
      return false, nil
    end
    local cacheKey = "40:16:player:" .. playerName
    local ok, result = pcall(formatDynamic, self, resources, 40, 16, { [0] = playerName }, cacheKey)
    if not ok then
      self._admissionFailure = "League ending save result failed: " .. tostring(result)
      return false, self._admissionFailure
    end
    if type(result) ~= "string" or result == "" then
      self._admissionFailure = "League ending save result has no text"
      return false, self._admissionFailure
    end
    self._saveResultAdmitted = true
    return true, nil
  end
  return withAdmission(self, admit)
end

-- Warm one party's required localized species/move names outside draw so a
-- steady registration/showcase phase performs no bank acquisition while
-- painting. A missing catalog, provider, bank, or message is terminal: the
-- phase must hold instead of drawing a fallback name on its ready path.
---@param party table<string, unknown>[] recorded or live party members by value
---@param resources table<string, unknown> borrowed mon catalog + message provider
---@return boolean admitted
---@return string? failure terminal admission failure
function HallOfFamePresentation:admitParty(party, resources)
  assert(not self.disposed, "disposed Hall of Fame presentation cannot admit")
  local function admit()
    if self.sections == nil then
      return false, nil
    end
    if self._admissionFailure ~= nil then
      return false, self._admissionFailure
    end
    if type(party) ~= "table" or #party == 0 then
      self._partyAdmitted = true
      return true, nil
    end
    local catalog = resources.monCatalog
    local provider = resources.messageProvider
    if catalog == nil or provider == nil then
      return false, nil
    end
    self._textCache = self._textCache or {}
    for _, mon in ipairs(party) do
      if type(mon) == "table" and type(mon.species) == "string" then
        -- Level line warms with its real level so draw performs no acquire.
        if mon.level ~= nil then
          local levelAdmitted, levelFailure = self:admitLevel(mon.level, resources)
          if levelFailure ~= nil then
            return false, levelFailure
          end
          if not levelAdmitted then
            return false, nil
          end
        end
        local key = "species:" .. tostring(mon.species)
        if self._textCache[key] == nil then
          local okDef, definition = pcall(catalog.species, catalog, mon.species)
          if not okDef or type(definition) ~= "table" or type(definition.nativeId) ~= "number" then
            self._admissionFailure = "League ending species failed: " .. tostring(mon.species)
            return false, self._admissionFailure
          end
          local acquired = provider:acquireBank(237)
          if type(acquired) ~= "table" then
            self._admissionFailure = "League ending species bank unavailable"
            return false, self._admissionFailure
          end
          local template = provider:get(237, definition.nativeId)
          provider:releaseBank(237)
          if type(template) ~= "table" or type(template.text) ~= "string" or template.text == "" then
            self._admissionFailure = "League ending species failed: " .. tostring(mon.species)
            return false, self._admissionFailure
          end
          self._textCache[key] = template.text
        end
        if type(mon.moves) == "table" then
          for _, moveKey in ipairs(mon.moves) do
            if type(moveKey) == "string" and moveKey ~= "" then
              local moveCacheKey = "move:" .. tostring(moveKey)
              if self._textCache[moveCacheKey] == nil then
                local okMove, moveDef = pcall(catalog.move, catalog, moveKey)
                if not okMove or type(moveDef) ~= "table" or type(moveDef.nativeId) ~= "number" then
                  self._admissionFailure = "League ending move failed: " .. tostring(moveKey)
                  return false, self._admissionFailure
                end
                local acquiredMove = provider:acquireBank(750)
                if type(acquiredMove) ~= "table" then
                  self._admissionFailure = "League ending move bank unavailable"
                  return false, self._admissionFailure
                end
                local templateMove = provider:get(750, moveDef.nativeId)
                provider:releaseBank(750)
                if type(templateMove) ~= "table" or type(templateMove.text) ~= "string" or templateMove.text == "" then
                  self._admissionFailure = "League ending move failed: " .. tostring(moveKey)
                  return false, self._admissionFailure
                end
                self._textCache[moveCacheKey] = templateMove.text
              end
            end
          end
        end
      end
    end
    self._partyAdmitted = true
    return true, nil
  end
  return withAdmission(self, admit)
end

-- One recorded mon's gender wording: the catalog ratio resolved through the
-- personality, with the retail Nidoran suppression (hall_of_fame_showcase.c
-- suppresses the gender mark for Nidoran F/M).
---@param mon table<string, unknown> recorded member with species/personality
---@param catalog table<string, unknown>? live mon catalog
---@return string gender "male", "female" or "genderless"
---@return boolean printGender whether the gender mark paints
function HallOfFamePresentation.monGender(mon, catalog)
  local gender = "genderless"
  if catalog ~= nil and type(catalog.species) == "function" and type(mon.personality) == "number" then
    local ok, definition = pcall(catalog.species, catalog, mon.species)
    if ok and type(definition) == "table" and type(definition.genderRatio) == "number" then
      local Personality = require("libs.mons.src.gen4.Personality")
      local okGender, derived = pcall(Personality.gender, definition.genderRatio, mon.personality)
      if okGender and (derived == "male" or derived == "female" or derived == "genderless") then
        gender = derived
      end
    end
  end
  local printGender = mon.species ~= "NIDORAN_F" and mon.species ~= "NIDORAN_M"
  return gender, printGender
end

-- One recorded mon's front/back portrait selectors through the same
-- gender/shiny resolution the summary projection owns, with an explicit
-- facing (the manifest carries both facings; nothing is guessed).
---@param mon table<string, unknown> recorded member with species/form/personality/origin
---@param catalog table<string, unknown> live mon catalog
---@return table<string, string>|nil selectors {front, back}, nil when unresolvable
function HallOfFamePresentation.portraitSelectorsFor(mon, catalog)
  if type(mon) ~= "table" or type(mon.species) ~= "string" or type(mon.form) ~= "number" then
    return nil
  end
  if type(mon.personality) ~= "number" or type(mon.origin) ~= "table" then
    return nil
  end
  if type(catalog.species) ~= "function" or type(catalog.form) ~= "function" then
    return nil
  end
  local ok, front, back = pcall(function()
    local Personality = require("libs.mons.src.gen4.Personality")
    local MonCache = require("libs.assets.src.MonCache")
    local definition = catalog:species(mon.species)
    local shiny = Personality.shiny(assert(mon.origin.trainerId, "origins carry id"), mon.personality)
    local gender = Personality.gender(assert(definition.genderRatio, "species carry ratio"), mon.personality)
    local variant = gender
    if gender ~= "male" and gender ~= "female" then
      local formRecord = catalog:form(mon.species, mon.form)
      local declared = assert(formRecord.portrait, "generated forms declare their portrait variant")
      variant = assert(declared:match("^[^/]+/[^/]+/([^/]+)/[^/]+$"), "portrait variants stay binary")
    end
    return MonCache.portraitSelector(mon.species, mon.form, variant, shiny),
      MonCache.portraitSelector(mon.species, mon.form, variant, shiny, "back")
  end)
  if not ok or type(front) ~= "string" or type(back) ~= "string" then
    return nil
  end
  return { front = front, back = back }
end

-- The frame index one baked animation sequence shows at the given tick:
-- forward sequences hold their terminal frame, looping sequences wrap at
-- their loop start. Blank frames resolve like any other frame; the caller
-- skips drawing them.
---@param sequence table<string, unknown> baked {frames, playMode, loopStart}
---@param tick number ticks since the sequence started, integral
---@return integer 1-based frame index
function HallOfFamePresentation.frameAt(sequence, tick)
  local frames = assert(sequence.frames, "a baked sequence carries its frames")
  assert(#frames > 0, "a baked sequence is not empty")
  if tick < 0 then
    tick = 0
  end
  if sequence.playMode == "forward_loop" or sequence.playMode == "reverse_loop" then
    local total = 0
    for _, frame in ipairs(frames) do
      total = total + (frame.durationTicks or 0)
    end
    if total <= 0 then
      return 1
    end
    local loopFrom = math.floor(tonumber(sequence.loopStart) or 0) + 1
    if loopFrom < 1 then
      loopFrom = 1
    end
    if loopFrom > #frames then
      loopFrom = #frames
    end
    local prefix = 0
    for index = 1, loopFrom - 1 do
      prefix = prefix + ((frames[index] or {}).durationTicks or 0)
    end
    if tick < prefix then
      return HallOfFamePresentation.frameAt({ frames = frames, playMode = "forward" }, tick)
    end
    local looped = tick - prefix
    local loopTotal = total - prefix
    local offset = loopTotal > 0 and (looped % loopTotal) or 0
    local elapsed = prefix + offset
    local accumulated = 0
    for index, frame in ipairs(frames) do
      accumulated = accumulated + (frame.durationTicks or 0)
      if elapsed < accumulated then
        return index
      end
    end
    return #frames
  end
  local elapsed = 0
  for index, frame in ipairs(frames) do
    elapsed = elapsed + (frame.durationTicks or 0)
    if tick < elapsed then
      return index
    end
  end
  return #frames
end

-- The admitted portrait page behind one selector, uploading the generated
-- page on first use. Pages stay admitted until disposal; a missing page
-- stays pending so provisioning can catch up.
---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param selector string
---@return { image: love.Image, path: string, entry: { pageId: integer, frames: table[], width: integer, height: integer }, fileData: love.FileData }? page image record, nil while pending
---@return string? failure
function HallOfFamePresentation:_admitPortraitPage(resources, selector)
  self._portraitPages = self._portraitPages or {}
  local entryPreview = self._portraitManifest ~= nil
      and self._portraitManifest.entries ~= nil
      and self._portraitManifest.entries[selector]
    or nil
  if type(entryPreview) == "table" and type(entryPreview.pageId) == "number" then
    local MonCachePreview = require("libs.assets.src.MonCache")
    local previewPath = MonCachePreview.portraitPagePath(entryPreview.pageId)
    local preview = self._portraitPages[previewPath]
    if preview ~= nil then
      return preview, nil
    end
  end
  local cacheFs = resources.cacheFs
  local graphics = resources.graphics
  if cacheFs == nil or graphics == nil then
    return nil, nil
  end
  if self._portraitManifest == nil then
    return nil, nil
  end
  local entry = self._portraitManifest.entries ~= nil and self._portraitManifest.entries[selector] or nil
  if type(entry) ~= "table" or type(entry.pageId) ~= "number" then
    return nil, "portrait manifest carries no page for " .. tostring(selector)
  end
  local MonCache = require("libs.assets.src.MonCache")
  local path = MonCache.portraitPagePath(entry.pageId)
  local ok, bytes = pcall(cacheFs.read, cacheFs, path)
  if not ok or type(bytes) ~= "string" then
    return nil, nil
  end
  local fileData
  if type(cacheFs.newFileData) == "function" then
    local okFd, fd = pcall(cacheFs.newFileData, cacheFs, bytes, path)
    if not okFd then
      return nil, "portrait page admits no file data: " .. tostring(path)
    end
    fileData = fd
  else
    fileData = love.filesystem.newFileData(bytes, path)
  end
  local okImage, image = pcall(graphics.newImage, fileData)
  if not okImage or image == nil then
    return nil, "portrait page uploads no GPU art: " .. tostring(path)
  end
  if type(image.setFilter) == "function" then
    pcall(image.setFilter, image, "nearest", "nearest")
  end
  local record = { image = image, path = path, entry = entry, fileData = fileData }
  -- Pages are keyed by page path (not selector): co-resident selectors
  -- share one uploaded page instead of duplicating identical bytes.
  self._portraitPages[path] = record
  return record, nil
end

-- One silhouette variant of an admitted page: every opaque pixel takes the
-- source silhouette color while alpha is preserved. Black silhouettes draw
-- straight from the admitted page with a black ink instead.
---@param self HallOfFamePresentation
---@param resources table<string, unknown>
---@param pageRecord { image: love.Image, path: string, entry: { pageId: integer, frames: table[], width: integer, height: integer }, fileData: love.FileData } admitted page record
---@param color {r: integer, g: integer, b: integer}
---@param key string cache identity
---@return { image: love.Image }? variant image record, nil while pending
---@return string? failure
function HallOfFamePresentation:_admitSilhouetteVariant(resources, pageRecord, color, key)
  self._silhouettes = self._silhouettes or {}
  local cached = self._silhouettes[key]
  if cached ~= nil then
    return cached, nil
  end
  local graphics = resources.graphics
  if graphics == nil then
    return nil, nil
  end
  if type(love) ~= "table" or type(love.image) ~= "table" or type(love.image.newImageData) ~= "function" then
    return nil, "silhouettes need their host image namespace"
  end
  local fileData = assert(pageRecord.fileData, "an admitted page carries its file data")
  local ok, data = pcall(love.image.newImageData, fileData)
  if not ok or data == nil then
    return nil, "a silhouette reads no page pixels"
  end
  local width, height = data:getDimensions()
  local okMap, mapErr = pcall(function()
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        local _, _, _, a = data:getPixel(x, y)
        if a == 0 then
          data:setPixel(x, y, 0, 0, 0, 0)
        else
          data:setPixel(x, y, color.r / 31, color.g / 31, color.b / 31, a)
        end
      end
    end
  end)
  if not okMap then
    return nil, "a silhouette maps no page pixels: " .. tostring(mapErr)
  end
  local okImage, image = pcall(graphics.newImage, data)
  if not okImage or image == nil then
    return nil, "a silhouette uploads no GPU art"
  end
  if type(image.setFilter) == "function" then
    pcall(image.setFilter, image, "nearest", "nearest")
  end
  local record = { image = image }
  self._silhouettes[key] = record
  return record, nil
end

-- Admits the recorded party's portrait pages. Registration needs front/back
-- plus the white silhouette pages the whole-party pre-flash draws; the PC
-- showcase needs only the selected fronts and never draws silhouettes.
-- Pending while pages or images are unavailable; terminal on malformed
-- selectors or manifests. Only the current record's required pages stay
-- pinned: browsing history prunes stale pages, white variants and quads so
-- the 30-record viewer holds bounded live interest.
---@param resources table<string, unknown> borrowed generated cache + graphics + mon catalog
---@param party table<string, unknown>[] recorded party members with identity records
---@return boolean admitted
---@return string? failure terminal admission failure, nil while pending
function HallOfFamePresentation:admitPortraits(resources, party)
  assert(not self.disposed, "disposed Hall of Fame presentation cannot admit")
  if self.sections == nil then
    return false, nil
  end
  if self._admissionFailure ~= nil then
    return false, self._admissionFailure
  end
  if type(party) ~= "table" or #party == 0 then
    return true, nil
  end
  return withAdmission(self, function()
    local cacheFs = resources.cacheFs
    local catalog = resources.monCatalog
    if cacheFs == nil or catalog == nil then
      return false, nil
    end
    if self._portraitManifest == nil then
      local MonCache = require("libs.assets.src.MonCache")
      local ok, manifest = pcall(cacheFs.loadLua, cacheFs, MonCache.portraitManifestPath())
      if not ok or type(manifest) ~= "table" or type(manifest.entries) ~= "table" then
        return false, nil
      end
      self._portraitManifest = manifest
    end
    local selectors = {}
    local needsBack = self._admittedSections == nil or self._admittedSections.registration == true
    -- Showcase-only receipts never warm backs or silhouettes: the viewer
    -- draws the selected front only. Registration warms both facings.
    for _, mon in ipairs(party) do
      if type(mon) ~= "table" or type(mon.species) ~= "string" then
        self._admissionFailure = "the registration draws only identified party members"
        return false, self._admissionFailure
      end
      local pair = HallOfFamePresentation.portraitSelectorsFor(mon, catalog)
      if pair == nil then
        self._admissionFailure = "the registration resolves no portrait: " .. tostring(mon.species)
        return false, self._admissionFailure
      end
      selectors[#selectors + 1] = pair.front
      if needsBack then
        selectors[#selectors + 1] = pair.back
      end
    end
    local MonCachePages = require("libs.assets.src.MonCache")
    local requiredPaths = {}
    for _, selector in ipairs(selectors) do
      local _, failure = self:_admitPortraitPage(resources, selector)
      if failure ~= nil then
        self._admissionFailure = tostring(failure)
        return false, self._admissionFailure
      end
      local manifestEntry = assert(self._portraitManifest.entries[selector], "a portrait selector resolves its page")
      local pagePath = MonCachePages.portraitPagePath(assert(manifestEntry.pageId))
      requiredPaths[pagePath] = true
      if self._portraitPages[pagePath] == nil then
        return false, nil
      end
      if needsBack then
        local page = self._portraitPages[pagePath]
        -- White silhouettes are keyed by page path: co-resident selectors
        -- share one recolored page instead of baking identical copies.
        local whiteKey = "white:" .. pagePath
        if self._silhouettes == nil or self._silhouettes[whiteKey] == nil then
          local _, whiteFailure = self:_admitSilhouetteVariant(resources, page, { r = 31, g = 31, b = 31 }, whiteKey)
          if whiteFailure ~= nil then
            self._admissionFailure = tostring(whiteFailure)
            return false, self._admissionFailure
          end
          if self._silhouettes == nil or self._silhouettes[whiteKey] == nil then
            return false, nil
          end
        end
      end
    end
    -- Prune pages, silhouette variants and quads the current record no
    -- longer needs so history browsing holds only live front interest.
    do
      local function releaseImage(image)
        if image ~= nil and type(image.release) == "function" then
          pcall(image.release, image)
        end
      end
      if self._portraitPages ~= nil then
        for path, record in pairs(self._portraitPages) do
          if requiredPaths[path] ~= true then
            if type(record) == "table" then
              releaseImage(record.image)
            end
            self._portraitPages[path] = nil
            local whiteKey = "white:" .. path
            if self._silhouettes ~= nil and self._silhouettes[whiteKey] ~= nil then
              local white = self._silhouettes[whiteKey]
              if type(white) == "table" then
                releaseImage(white.image)
              end
              self._silhouettes[whiteKey] = nil
            end
          end
        end
      end
      if self._quads ~= nil then
        for key, _ in pairs(self._quads) do
          local keep = false
          for _, selector in ipairs(selectors) do
            if type(key) == "string" and key:sub(1, #selector) == selector then
              keep = true
              break
            end
          end
          if not keep then
            self._quads[key] = nil
          end
        end
      end
    end
    -- White and red copies of the whole-party shadow blob for the
    -- pre-flash silhouettes and the individual-scene red shadows.
    -- Black silhouettes draw straight from the admitted frames. The
    -- showcase never draws these registration-only silhouettes, so a
    -- showcase-only receipt skips them instead of demanding registration
    -- art outside its own phase.
    if self._admittedSections == nil or self._admittedSections.registration ~= true then
      -- Pre-warm portrait quads outside draw so the first showcase frame
      -- performs no new persistent allocations.
      local graphics = resources.graphics
      if graphics ~= nil and type(graphics.newQuad) == "function" then
        self._quads = self._quads or {}
        for _, selector in ipairs(selectors) do
          local entry = self._portraitManifest.entries[selector]
          if type(entry) == "table" and type(entry.frames) == "table" then
            local pagePath = require("libs.assets.src.MonCache").portraitPagePath(assert(entry.pageId))
            local record = self._portraitPages[pagePath]
            if type(record) == "table" and record.image ~= nil then
              local okW, w = pcall(record.image.getWidth, record.image)
              local okH, h = pcall(record.image.getHeight, record.image)
              if okW and okH and type(w) == "number" and type(h) == "number" then
                for frameIdx, frame in ipairs(entry.frames) do
                  if type(frame) == "table" then
                    local key = selector .. "#" .. tostring(frameIdx)
                    if self._quads[key] == nil then
                      local okQ, quad = pcall(graphics.newQuad, frame.x, frame.y, frame.width, frame.height, w, h)
                      if okQ and quad ~= nil then
                        self._quads[key] = quad
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
      return true, nil
    end
    local registration = assert(self.sections.registration, "the bundle carries its registration section")
    local shadow = assert(registration.shadow, "the bundle carries its shadow frames")
    local shadowSeq = assert(shadow[0], "the shadow sequence carries its rest frame")
    assert(type(shadowSeq.frames) == "table", "a shadow sequence carries its frames")
    for _, frame in ipairs(shadowSeq.frames) do
      if type(frame) == "table" and type(frame.path) == "string" then
        for _, colorName in ipairs({ "white", "red" }) do
          local color = colorName == "white" and { r = 31, g = 31, b = 31 } or { r = 31, g = 0, b = 0 }
          local key = frame.path .. ":" .. colorName
          if self._silhouettes == nil or self._silhouettes[key] == nil then
            local _, failure = self:_silhouetteCopy(resources, frame.path, color, key)
            if failure ~= nil then
              self._admissionFailure = tostring(failure)
              return false, self._admissionFailure
            end
            if self._silhouettes == nil or self._silhouettes[key] == nil then
              return false, nil
            end
          end
        end
      end
    end
    return true, nil
  end)
end
-- The source meeting-location threshold behind the fateful branch
-- (map_sections.h METLOC_DAY_CARE_COUPLE): packed locations at or above it
-- never read a wild landmark.
local METLOC_DAY_CARE_COUPLE = 2000

-- The source met-location reading order (GetMetLocationType): migrated
-- origin games first, then fateful encounters, then the two in-game trades,
-- then a mismatched original trainer, then the day-care threshold, with
-- anything else splitting on the egg month.
---@param mon table<string, unknown> recorded member with origin/met/egg records and trade kind
---@param profile table<string, unknown> player profile {name, trainerId}
---@return string met-location type: caught|hatched|traded|kanto|hoenn|sinnoh|orre|fateful|shuckie|kenya
function HallOfFamePresentation.metDetailKind(mon, profile)
  assert(type(mon) == "table", "the caught detail reads its recorded member")
  local origin = mon.origin
  assert(type(origin) == "table", "a recorded member carries its origin record")
  local game = origin.game
  if game == "sapphire" or game == "ruby" or game == "emerald" then
    return "hoenn"
  end
  if game == "firered" or game == "leafgreen" then
    return "kanto"
  end
  if game == "gamecube" then
    return "orre"
  end
  if game == "diamond" or game == "pearl" or game == "platinum" then
    return "sinnoh"
  end
  if mon.fatefulEncounter == true then
    return "fateful"
  end
  if mon.tradeKind == "shuckie" or mon.tradeKind == "kenya" then
    return mon.tradeKind
  end
  if origin.trainerId ~= profile.trainerId or origin.trainerName ~= profile.name then
    return "traded"
  end
  local met = mon.met
  if type(met) == "table" and type(met.location) == "number" and met.location >= METLOC_DAY_CARE_COUPLE then
    return "fateful"
  end
  local egg = mon.egg
  if type(egg) == "table" and type(egg.date) == "table" and tonumber(egg.date.month) ~= 0 then
    return "hatched"
  end
  return "caught"
end

-- The source landmark reading (landmark reader with the memo gift/normal/
-- external banks): gift-packed locations read the gift bank, everything
-- else the wild bank, unmapped locations the out-of-range fallback.
---@param memo table<string, unknown> admitted memo landmark maps
---@param location integer packed met location
---@return string landmark name
function HallOfFamePresentation.landmarkName(memo, location)
  assert(type(memo) == "table", "landmark names need their admitted maps")
  local giftByLocation = memo.giftByLocation
  if type(giftByLocation) == "table" and type(giftByLocation[location]) == "string" then
    return giftByLocation[location]
  end
  local wildByLocation = memo.wildByLocation
  if type(wildByLocation) == "table" and type(wildByLocation[location]) == "string" then
    return wildByLocation[location]
  end
  local fallback = memo.fallback
  assert(type(fallback) == "string" and fallback ~= "", "memo landmarks carry their fallback")
  return fallback
end

-- Admits the summary memo landmark maps the caught detail reads. The
-- manifest rides the generated summary family; a missing manifest stays
-- pending so provisioning can catch up.
---@param cacheFs table<string, unknown>?
---@return boolean admitted
---@return string? failure
function HallOfFamePresentation:admitMemoMaps(cacheFs)
  if self._memoLandmarks ~= nil then
    return true, nil
  end
  if type(cacheFs) ~= "table" or type(cacheFs.loadLua) ~= "function" then
    return false, nil
  end
  local SummaryCache = require("libs.assets.src.SummaryCache")
  local ok, manifest = pcall(cacheFs.loadLua, cacheFs, SummaryCache.manifestPath())
  if not ok or type(manifest) ~= "table" then
    return false, nil
  end
  local memo = manifest.memo
  if type(memo) ~= "table" or type(memo.landmarks) ~= "table" then
    return false, "the summary family carries no memo landmarks"
  end
  local landmarks = memo.landmarks
  self._memoLandmarks = {
    wildByLocation = landmarks.wildByLocation,
    giftByLocation = landmarks.giftByLocation,
    fallback = landmarks.fallback,
  }
  return true, nil
end

-- Warms one recorded member's registration lines outside draw: nickname,
-- gendered species, level and OT lines plus the met-location caught
-- detail, with real names, dates and landmark wording.
---@param mon table<string, unknown> recorded member with identity and meeting records
---@param resources table<string, unknown> borrowed mon catalog + message provider + fontDef
---@param memo table<string, unknown> admitted memo landmark maps
---@param profile table<string, unknown> player profile
---@return boolean admitted
---@return string? failure
function HallOfFamePresentation:admitRegistrationDetail(mon, resources, memo, profile)
  assert(not self.disposed, "disposed Hall of Fame presentation cannot admit")
  if self.sections == nil then
    return false, nil
  end
  if self._admissionFailure ~= nil then
    return false, self._admissionFailure
  end
  return withAdmission(self, function()
    if resources.messageProvider == nil then
      return false, nil
    end
    local speciesLabel = speciesName(self, resources, tostring(mon.species or ""))
    local nickname = mon.nickname
    if type(nickname) ~= "string" or nickname == "" then
      nickname = speciesLabel
    end
    local ok, result = pcall(formatDynamic, self, resources, 180, 4, { [0] = nickname }, "180:4:nick:" .. nickname)
    if not ok or type(result) ~= "string" or result == "" then
      self._admissionFailure = "League ending nickname failed: " .. tostring(result)
      return false, self._admissionFailure
    end
    local gender, printGender = HallOfFamePresentation.monGender(mon, resources.monCatalog)
    local genderLine = 3
    if printGender and gender == "male" then
      genderLine = 1
    elseif printGender and gender == "female" then
      genderLine = 2
    end
    ok, result = pcall(
      formatDynamic,
      self,
      resources,
      180,
      genderLine,
      { [0] = speciesLabel },
      "180:" .. genderLine .. ":sp:" .. speciesLabel
    )
    if not ok or type(result) ~= "string" or result == "" then
      self._admissionFailure = "League ending species line failed: " .. tostring(result)
      return false, self._admissionFailure
    end
    local level = tostring(math.floor(tonumber(mon.level) or 0))
    ok, result = pcall(formatDynamic, self, resources, 180, 5, { [0] = level }, "180:5:lv:" .. tostring(mon.level))
    if not ok or type(result) ~= "string" or result == "" then
      self._admissionFailure = "League ending level failed: " .. tostring(result)
      return false, self._admissionFailure
    end
    local otName = tostring(type(mon.origin) == "table" and mon.origin.trainerName or "")
    ok, result = pcall(formatDynamic, self, resources, 180, 6, { [0] = otName }, "180:6:ot:" .. otName)
    if not ok or type(result) ~= "string" or result == "" then
      self._admissionFailure = "League ending OT line failed: " .. tostring(result)
      return false, self._admissionFailure
    end
    local kind = HallOfFamePresentation.metDetailKind(mon, profile)
    local line = 9
    if kind == "caught" then
      line = 7
    elseif kind == "hatched" then
      line = 8
    elseif kind == "kanto" then
      line = 10
    elseif kind == "hoenn" then
      line = 11
    elseif kind == "orre" then
      line = 12
    elseif kind == "fateful" then
      line = 13
    elseif kind == "sinnoh" then
      line = 14
    elseif kind == "shuckie" or kind == "kenya" then
      line = 15
    end
    if line == 7 or line == 8 or line == 15 then
      local metLocation = 0
      if type(mon.met) == "table" and type(mon.met.location) == "number" then
        metLocation = mon.met.location
      end
      local landmark = HallOfFamePresentation.landmarkName(memo, metLocation)
      local key = string.format("180:%d:loc:%s", line, landmark)
      ok, result = pcall(formatDynamic, self, resources, 180, line, { [0] = landmark }, key)
      if not ok or type(result) ~= "string" or result == "" then
        self._admissionFailure = "League ending caught detail failed: " .. tostring(result)
        return false, self._admissionFailure
      end
    end
    -- Static detail lines (trades, regions, fateful meetings) warm with
    -- the rest of bank 180 in admitImages.
    return true, nil
  end)
end

-- Warms the whole-party windows: the static congratulations line and the
-- player/ID/play-time line with real values.
---@param playerName string
---@param trainerId integer full trainer identity
---@param hours integer in-game hours
---@param minutes integer in-game minutes
---@param resources table<string, unknown> borrowed message provider + fontDef
---@return boolean admitted
---@return string? failure
function HallOfFamePresentation:admitWholePartyLines(playerName, trainerId, hours, minutes, resources)
  assert(not self.disposed, "disposed Hall of Fame presentation cannot admit")
  if self.sections == nil then
    return false, nil
  end
  if self._admissionFailure ~= nil then
    return false, self._admissionFailure
  end
  return withAdmission(self, function()
    if resources.messageProvider == nil then
      return false, nil
    end
    local ok, result = pcall(messageLine, self, resources, 180, 16)
    if not ok or type(result) ~= "string" or result == "" then
      self._admissionFailure = "League ending whole-party header failed: " .. tostring(result)
      return false, self._admissionFailure
    end
    local visible = string.format("%05d", math.floor(tonumber(trainerId) or 0) % 65536)
    local hourText = string.format("%-3d", math.floor(tonumber(hours) or 0))
    local minuteText = string.format("%02d", math.floor(tonumber(minutes) or 0))
    local slots = { [0] = tostring(playerName), [1] = visible, [2] = hourText, [3] = minuteText }
    local key = "180:17:who:" .. slots[0] .. ":" .. slots[1] .. ":" .. slots[2] .. ":" .. slots[3]
    ok, result = pcall(formatDynamic, self, resources, 180, 17, slots, key)
    if not ok or type(result) ~= "string" or result == "" then
      self._admissionFailure = "League ending whole-party line failed: " .. tostring(result)
      return false, self._admissionFailure
    end
    -- Draw consumes the stashed key instead of recomputing it: the play
    -- clock can roll over between admission and draw within one frame.
    self._wholePartyKey = key
    return true, nil
  end)
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
      registration = view.registration,
      playerName = view.playerName,
      trainerId = view.trainerId,
      playerGender = view.playerGender,
    })
    return
  end
  if sectionName == "showcase" then
    self:_require("showcase")
    drawShowcaseGrid(self, resources, view)
    return
  end
  local credits = self:_require("credits")
  local savePhase = sectionName == "save_status"
  if savePhase then
    drawSaveStatus(self, resources, {
      saveMessage = view.saveMessage,
      phase = view.phase,
      playerName = view.playerName,
      fadeAlpha = view.fadeAlpha,
    })
    return
  end
  if sectionName == "the_end" then
    drawTheEndPresentation(self, resources, { creditsSection = credits, fadeAlpha = view.fadeAlpha })
    return
  end
  drawCredits(self, resources, {
    creditsSection = credits,
    timer = view.timer or 0,
    versionId = view.versionId,
    credits = view.credits,
    fadeAlpha = view.fadeAlpha,
  })
end

function HallOfFamePresentation:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  self.sections = nil
  self._textCache = nil
  self._admittedSections = nil
  self._textAdmittedSections = nil
  self._admissionFailure = nil
  self._admissionDepth = 0
  self._iconsAdmitted = false
  self._portraitsAdmitted = false
  self._detailAdmitted = false
  self._cutsceneGender = nil
  self._partyAdmitted = false
  self._quads = nil
  local function releaseImage(image)
    if image ~= nil and type(image.release) == "function" then
      pcall(image.release, image)
    end
  end
  if self._portraitPages ~= nil then
    for _, record in pairs(self._portraitPages) do
      if type(record) == "table" then
        releaseImage(record.image)
      end
    end
  end
  self._portraitPages = nil
  self._portraitManifest = nil
  if self._silhouettes ~= nil then
    for _, record in pairs(self._silhouettes) do
      if type(record) == "table" then
        releaseImage(record.image)
      end
    end
  end
  self._silhouettes = nil
  self._memoLandmarks = nil
  self._headerAdmitted = false
  self._saveResultAdmitted = false
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
