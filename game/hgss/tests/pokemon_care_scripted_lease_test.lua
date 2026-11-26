-- Focused coverage for the scripted care leases: the reminder and trade
-- applications resolve their subject pictures from the generated portrait
-- family before the renderer commits, so the per-open lease publishes the
-- picture (reminder) or the per-subject pictures (trade) even when the
-- renderer's own family is thin.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MonCache = require("libs.assets.src.MonCache")
local PokemonCareCache = require("libs.assets.src.PokemonCareCache")
local PokemonCareInterface = require("libs.hgss.src.ui.PokemonCareInterface")
local SharedImagePoolFake = require("tests.support.SharedImagePoolFake")
local SummaryCache = require("libs.assets.src.SummaryCache")

local T = { tests = {} }

local REMINDER_SURFACE = PokemonCareCache.reminderDir() .. "/main.png"

---@param selector string
---@return integer pageId, table frame
local function portraitEntry(pageId)
  return pageId, { x = 0, y = 0, width = 64, height = 64 }
end

-- The generated families a scripted lease reads: the summary family the child
-- screen draws, the reminder family, and the portrait entry for every subject
-- selector the lease resolves.
---@param subjects { speciesKey: string, form: integer, gender: string, shiny: boolean }[]
---@return CacheFs
local function scriptedCache(subjects)
  local cacheFs = CacheFs.forVersion("soulsilver", FakeCache.new())
  cacheFs:writeLua(SummaryCache.manifestPath(), { schema = SummaryCache.SCHEMA })
  cacheFs:writeLua(PokemonCareCache.reminderManifestPath(), {
    schema = PokemonCareCache.REMINDER_SCHEMA,
    main = { image = REMINDER_SURFACE },
    sub = { image = PokemonCareCache.reminderDir() .. "/sub.png" },
    buttons = { image = PokemonCareCache.reminderDir() .. "/buttons.png" },
    windows = {},
    messages = { { id = 0, text = "Which move should be remembered?" } },
  })
  local entries = {}
  for _, subject in ipairs(subjects) do
    local pageId, frame = portraitEntry(0)
    entries[MonCache.portraitSelector(subject.speciesKey, subject.form, subject.gender, subject.shiny)] = {
      pageId = pageId,
      frames = { frame },
    }
  end
  cacheFs:writeLua(MonCache.portraitManifestPath(), { entries = entries })
  return cacheFs
end

---@param cacheFs CacheFs
---@return table resources, table pool
local function resources(cacheFs)
  local PokemonCarePresentationResources = require("game.hgss.src.field.PokemonCarePresentationResources")
  local pool = SharedImagePoolFake.new()
  return PokemonCarePresentationResources.new({
    cacheFs = cacheFs,
    graphics = { draw = function() end },
    imagePool = pool,
    text = {
      windowBackgroundColor = function()
        return { 0, 0, 0 }
      end,
      drawTextWithPalette = function() end,
      drawFocusIndicator = function() end,
    },
    window = { drawWindow = function() end },
    fontDef = {},
    frameIndex = 0,
    measureDisplay = function()
      return { top = { width = 256, height = 192 }, bottom = { width = 256, height = 192 } }
    end,
  }), pool
end

-- The trade family's staged surfaces: every source phase carries one layer
-- and the effect sheet one frame, so the lease requests the whole set.
---@return table
local function tradeManifest(heights)
  local path = PokemonCareCache.tradeDir() .. "/surface.png"
  local scenes = {}
  for _, phase in ipairs({ "send", "depart", "recede", "exchange", "approach", "arrive", "receive" }) do
    scenes[phase] = { layers = { { image = path } } }
  end
  return {
    schema = PokemonCareCache.TRADE_SCHEMA,
    pictures = { heights = heights },
    scenes = scenes,
    sprites = { effect = { sequences = { { frames = { { image = path } } } } } },
  }
end

local SUBJECT = { speciesKey = "PICHU", form = 0, gender = "male", shiny = false }

function T.tests.a_reminder_lease_resolves_its_subject_picture()
  local cacheFs = scriptedCache({ SUBJECT })
  local owner = resources(cacheFs)
  local lease = owner:acquire(PokemonCareInterface.assertRelearnerRequest({
    kind = PokemonCareInterface.KINDS.move_relearner,
    mode = PokemonCareInterface.RELEARNER_MODES.relearn,
    slot = 0,
    revision = 0,
    nickname = "PICHU",
    moves = { "THUNDERSHOCK" },
    known = {},
    subject = SUBJECT,
  }))
  Assert.equal(lease:prepare().kind, "ready", "the reminder lease commits its presentation")
  Assert.notNil(lease._picture, "the reminder lease resolves its subject picture before the renderer")
  local picture = assert(lease._picture)
  Assert.equal(picture.page, MonCache.portraitPagePath(0), "the picture names the generated portrait page")
  Assert.equal(picture.frame.width, 64, "the picture carries its source frame extent")
  Assert.notNil(lease._reminderManifest, "the lease holds the reminder family its renderer draws")
  lease:release()
end

function T.tests.the_subject_picture_follows_the_shiny_selector()
  local shiny = { speciesKey = "PICHU", form = 0, gender = "male", shiny = true }
  local cacheFs = scriptedCache({ shiny })
  local owner = resources(cacheFs)
  local lease = owner:acquire(PokemonCareInterface.assertRelearnerRequest({
    kind = PokemonCareInterface.KINDS.move_relearner,
    mode = PokemonCareInterface.RELEARNER_MODES.tutor,
    slot = 0,
    revision = 0,
    nickname = "PICHU",
    moves = { "THUNDERSHOCK" },
    known = {},
    subject = shiny,
  }))
  Assert.equal(lease:prepare().kind, "ready", "the tutor lease commits its presentation")
  Assert.notNil(lease._picture, "a shiny subject resolves through its own selector")
  lease:release()
end

function T.tests.a_trade_lease_resolves_both_subject_pictures()
  local outgoing = { speciesKey = "PICHU", form = 0, gender = "male", shiny = false }
  local incoming = { speciesKey = "PIKACHU", form = 0, gender = "female", shiny = true }
  local cacheFs = scriptedCache({ outgoing, incoming })
  local plainIncoming = MonCache.portraitSelector(incoming.speciesKey, incoming.form, incoming.gender, false)
  cacheFs:writeLua(
    PokemonCareCache.tradeManifestPath(),
    tradeManifest({ [MonCache.portraitSelector("PICHU", 0, "male", false)] = 32, [plainIncoming] = 40 })
  )
  local owner = resources(cacheFs)
  local lease = owner:acquire({
    kind = PokemonCareInterface.KINDS.trade,
    outgoing = outgoing,
    incoming = incoming,
    playerName = "GOLD",
  })
  lease:prepare()
  Assert.notNil(lease._pictures, "the trade lease resolves its subject pictures before the renderer")
  local pictures = assert(lease._pictures)
  Assert.equal(pictures.outgoing.page, MonCache.portraitPagePath(0), "the outgoing picture names its portrait page")
  Assert.equal(pictures.outgoing.height, 32, "the outgoing picture carries the manifest's front height")
  Assert.equal(pictures.incoming.height, 40, "a shiny subject shares its plain entry's front height")
  lease:release()
end

return T
