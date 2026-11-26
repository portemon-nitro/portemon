-- Feature-local presenter over the generated League ending bundle: plans and
-- draws are built from the bundle's plain records, never from serialized
-- callbacks. An unready presentation draws nothing and reports zero frames;
-- a prepared one exposes the source member cadence, credit timelines and the
-- recorded party surfaces through borrowed text/window/icon/image owners.

local Assert = require("tests.support.Assert")
local HallOfFamePresentation = require("game.hgss.src.ending.HallOfFamePresentation")

local T = { tests = {} }

local MEMBER_FRAMES = 84
local CREDIT_FRAMES = 4976
local MUSIC_BOX_WAIT = 380

local function bundle()
  return {
    signature = "ending-cache-v1:rom:deps",
    registration = { messageBank = 180, memberFrames = MEMBER_FRAMES },
    showcase = { messageBank = 181 },
    credits = {
      frames = CREDIT_FRAMES,
      musicBoxWaitFrames = MUSIC_BOX_WAIT,
      messageBank = 440,
      titleMessages = { heartgold = 0, soulsilver = 1 },
      sceneTransitionTimings = { 890, 1780, 2615, 3030, 4295 },
      scenes = {
        { index = 0, lower = { path = "data/generated/ending/images/a.png", sha1 = "aa" }, upper = { path = "data/generated/ending/images/b.png", sha1 = "bb" } },
      },
      pages = {
        { page = 0, startTime = 0, duration = 105, lines = { { x = 0, y = 70, message = 0 } } },
        { page = 1, startTime = 110, duration = 105, lines = { { x = 20, y = 80, message = 3 } } },
      },
      theEnd = { path = "data/generated/ending/images/end.png", sha1 = "ee" },
    },
  }
end

local function showcaseStatus()
  return {
    app = "hallOfFame",
    section = "showcase",
    phase = "browsing",
    recordNumber = 7,
    total = 7,
    retained = 1,
    date = { year = 2000, month = 1, day = 1 },
    partySize = 2,
    party = {
      { species = "TYPHLOSION", level = 60, form = 0 },
      { species = "PIDGEOT", level = 55, form = 0 },
    },
    selectedMon = nil,
    page = "team",
    mon = nil,
  }
end

local function fakeResources(sink)
  return {
    graphics = {},
    textRenderer = {
      drawText = function(_, text, x, y)
        sink.text[#sink.text + 1] = { text = text, x = x, y = y }
      end,
    },
    windowRenderer = {
      drawStandardWindow = function(_, box)
        sink.windows[#sink.windows + 1] = box
      end,
    },
    icons = {
      dimensions = function(_, _)
        return { width = 32, height = 32 }
      end,
    },
    monCatalog = {
      iconSelection = function(_, mon)
        return "icon:" .. tostring(mon.species)
      end,
    },
    messageProvider = {
      message = function(_, bank, id)
        return "bank" .. tostring(bank) .. ":" .. tostring(id)
      end,
    },
    images = {},
  }
end

function T.tests.unready_presentation_draws_nothing_and_reports_zero_frames()
  local presentation = HallOfFamePresentation.new(nil)
  Assert.isFalse(presentation:isReady(), "a presentation without a bundle is not ready")
  Assert.equal(presentation:congratulationsFrames(6), 0, "an unready presentation owns no registration frames")
  Assert.equal(presentation:creditFrames(), 0, "an unready presentation owns no credit frames")
  local ok, err = pcall(function()
    return presentation:presentationPlan(showcaseStatus())
  end)
  Assert.isFalse(ok, "an unready presentation builds no showcase plan")
  Assert.isTrue(
    tostring(err):find("FIELD_ENDING_ASSET_MISSING", 1, true) ~= nil,
    "the missing bundle is attributed, not an assertion: " .. tostring(err)
  )
  local sink = { text = {}, windows = {} }
  local drawOk, drawErr = pcall(function()
    presentation:draw(fakeResources(sink), showcaseStatus())
  end)
  Assert.isFalse(drawOk, "an unready presentation draws nothing")
  Assert.equal(#sink.text, 0, "no text is drawn before readiness")
end

function T.tests.prepared_presentation_reports_source_timelines()
  local presentation = HallOfFamePresentation.new(bundle())
  Assert.isTrue(presentation:isReady(), "a prepared presentation is ready")
  Assert.equal(
    presentation:congratulationsFrames(2),
    MEMBER_FRAMES * 2,
    "the registration reveal runs the source per-member cadence for the party"
  )
  Assert.equal(presentation:creditFrames(), CREDIT_FRAMES, "the roll keeps the source credit frames")
  Assert.equal(
    presentation:musicBoxWaitFrames(),
    MUSIC_BOX_WAIT,
    "The End keeps the source music-box wait"
  )
end

function T.tests.prepared_showcase_plan_draws_record_party_and_credit_layers()
  local presentation = HallOfFamePresentation.new(bundle())
  local status = showcaseStatus()
  local plan = assert(presentation:presentationPlan(status), "a prepared presentation plans the showcase")
  Assert.equal(plan.inputKey, "hall-of-fame-showcase", "the showcase plan names its input geometry")
  Assert.isTrue(type(plan.render) == "function", "the showcase plan carries its render callback")
  local sink = { text = {}, windows = {} }
  plan.render(fakeResources(sink), status, plan)
  local joined = {}
  for _, entry in ipairs(sink.text) do
    joined[#joined + 1] = tostring(entry.text)
  end
  local painted = table.concat(joined, "\n")
  Assert.isTrue(painted:find("7", 1, true) ~= nil, "the showcase paints the source record number")
  Assert.isTrue(painted:find("TYPHLOSION", 1, true) ~= nil, "the showcase paints the recorded party species")
  Assert.isTrue(painted:find("PIDGEOT", 1, true) ~= nil, "the showcase paints every recorded party member")
end

function T.tests.prepared_registration_draws_congratulations_party()
  local presentation = HallOfFamePresentation.new(bundle())
  local status = {
    section = "registration",
    phase = "congratulations",
    party = {
      { species = "TYPHLOSION", level = 60, form = 0, nickname = "TYPHLOSION", otName = "GOLD" },
    },
  }
  local plan = assert(presentation:registrationPlan(status), "a prepared presentation plans the registration")
  Assert.equal(plan.inputKey, "hall-of-fame-registration", "the registration plan names its input geometry")
  local sink = { text = {}, windows = {} }
  plan.render(fakeResources(sink), status, plan)
  local joined = {}
  for _, entry in ipairs(sink.text) do
    joined[#joined + 1] = tostring(entry.text)
  end
  Assert.isTrue(
    table.concat(joined, "\n"):find("TYPHLOSION", 1, true) ~= nil,
    "the congratulations surface paints the registered party"
  )
end

function T.tests.prepared_credits_draw_paints_current_page_lines()
  local presentation = HallOfFamePresentation.new(bundle())
  local status = { section = "credits", phase = "credits", timer = 115, page = 1 }
  local sink = { text = {}, windows = {} }
  presentation:draw(fakeResources(sink), status)
  local joined = {}
  for _, entry in ipairs(sink.text) do
    joined[#joined + 1] = tostring(entry.text)
  end
  Assert.isTrue(
    table.concat(joined, "\n"):find("bank440:3", 1, true) ~= nil,
    "the roll paints the current page's source message line"
  )
end

function T.tests.save_status_draw_paints_the_reported_message()
  local presentation = HallOfFamePresentation.new(bundle())
  local sink = { text = {}, windows = {} }
  presentation:draw(fakeResources(sink), { phase = "save_failed", saveMessage = "Save failed: disk" })
  local joined = {}
  for _, entry in ipairs(sink.text) do
    joined[#joined + 1] = tostring(entry.text)
  end
  Assert.isTrue(
    table.concat(joined, "\n"):find("Save failed: disk", 1, true) ~= nil,
    "the save-status surface paints the retryable failure"
  )
end

function T.tests.the_end_draw_paints_without_party()
  local presentation = HallOfFamePresentation.new(bundle())
  local sink = { text = {}, windows = {} }
  presentation:draw(fakeResources(sink), { phase = "the_end" })
  Assert.isTrue(#sink.text > 0, "The End paints its title surface")
  Assert.equal(#sink.windows, 1, "The End paints one framed surface")
end

function T.tests.prepare_rejects_a_bundle_missing_a_section()
  local presentation = HallOfFamePresentation.new(nil)
  local bad = bundle()
  bad.showcase = nil
  local ok, err = pcall(function()
    presentation:prepare(bad)
  end)
  Assert.isFalse(ok, "a bundle missing a section never becomes ready")
  Assert.isFalse(presentation:isReady(), "a rejected bundle leaves the presentation unready")
  Assert.isTrue(tostring(err):find("showcase", 1, true) ~= nil, "the rejection names the section")
end

return T
