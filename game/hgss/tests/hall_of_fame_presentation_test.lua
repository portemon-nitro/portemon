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
    registration = {
      messageBank = 180,
      memberFrames = MEMBER_FRAMES,
      backgroundArchive = "NARC_a_1_0_1",
      backgroundMembers = { 0, 1, 2, 3, 4, 5, 6, 7, 8 },
      spriteMembers = { 16, 17, 18 },
      spotlightArchive = "NARC_a_0_0_8",
      spotlightMembers = { 76, 77, 78 },
    },
    showcase = { messageBank = 181, backgroundArchive = "NARC_a_0_9_7" },
    credits = {
      frames = CREDIT_FRAMES,
      musicBoxWaitFrames = MUSIC_BOX_WAIT,
      messageBank = 440,
      titleMessages = { heartgold = 0, soulsilver = 1 },
      sceneTransitionTimings = { 890, 1780, 2615, 3030, 4295 },
      screenFlipTimings = { 890, 1780, 2615, 3030, 4295 },
      spriteResources = { charMember = 1, paletteMember = 0, cellMember = 2, animMember = 3 },
      cutsceneResources = { charBaseMember = 20, paletteMember = 149, count = 16 },
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
    cursor = 0,
    exitSelected = false,
    selectedMon = 0,
    page = "grid",
    mon = nil,
  }
end

local function fakeResources(sink)
  local images = {}
  return {
    graphics = {
      draw = function(_, image, x, y)
        sink.images = sink.images or {}
        sink.images[#sink.images + 1] = { image = image, x = x, y = y }
      end,
      newImage = function(_, fileData)
        local image = { fileData = fileData }
        function image:setFilter()
        end
        function image:release()
        end
        return image
      end,
    },
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
      handleFor = function(_, key)
        return {
          drawQuad = function(_, graphics, quad, x, y)
            sink.icons = sink.icons or {}
            sink.icons[#sink.icons + 1] = { key = key, x = x, y = y }
          end,
        }
      end,
      quadFor = function(_, key, frame)
        return { key = key, frame = frame }
      end,
    },
    monCatalog = {
      iconSelection = function(_, mon)
        return "icon:" .. tostring(mon.species)
      end,
      species = function(_, key)
        return { name = tostring(key), nativeId = 157 }
      end,
      move = function(_, key)
        return { nativeId = 33 }
      end,
    },
    messageProvider = {
      acquireBank = function()
        return {}
      end,
      get = function(_, bank, id)
        return { bankId = bank, messageId = id, text = "msg" .. tostring(bank) .. ":" .. tostring(id), tokens = {} }
      end,
      format = function(_, template)
        return { text = template.text, tokens = {} }
      end,
      releaseBank = function()
      end,
    },
    images = images,
    cacheFs = {
      read = function(_, path)
        return "png-bytes:" .. tostring(path)
      end,
      newFileData = function(_, bytes, path)
        return { bytes = bytes, path = path }
      end,
      exists = function()
        return true
      end,
    },
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
  Assert.isTrue(painted:find("msg181:0", 1, true) ~= nil, "the showcase paints its source header from bank 181")
  Assert.isTrue((sink.icons ~= nil and #sink.icons == 2), "the showcase draws the recorded party's own icons")
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
    table.concat(joined, "\n"):find("msg237:", 1, true) ~= nil,
    "the congratulations surface paints the localized species from bank 237"
  )
  Assert.isTrue((sink.icons ~= nil and #sink.icons == 1), "the congratulations draws the party's own icon")
end

function T.tests.prepared_credits_draw_paints_current_page_lines()
  local presentation = HallOfFamePresentation.new(bundle())
  local status = { section = "credits", phase = "credits", timer = 115, page = 1 }
  local sink = { text = {}, windows = {} }
  local drawResources = fakeResources(sink)
  -- Images admit outside draw; a steady draw then performs no filesystem or
  -- GPU work and still paints the admitted layers.
  local admitted, admitFailure = presentation:admitImages(drawResources)
  Assert.isTrue(admitted, "credit images admit before the first draw: " .. tostring(admitFailure))
  presentation:draw(drawResources, status)
  local joined = {}
  for _, entry in ipairs(sink.text) do
    joined[#joined + 1] = tostring(entry.text)
  end
  Assert.isTrue(
    table.concat(joined, "\n"):find("msg440:", 1, true) ~= nil,
    "the roll paints the current page's source message line from bank 440"
  )
  Assert.isTrue(sink.images ~= nil and #sink.images >= 2, "the roll draws its source background layers")
  for _, line in ipairs(sink.text) do
    Assert.isNil(tostring(line.text):find("scene ", 1, true), "the roll never paints a diagnostic scene label")
    Assert.isNil(tostring(line.text):find("bank", 1, true), "the roll never paints a bank identity stand-in")
  end
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
  local drawResources = fakeResources(sink)
  local admitted, admitFailure = presentation:admitImages(drawResources)
  Assert.isTrue(admitted, "The End admits before the first draw: " .. tostring(admitFailure))
  presentation:draw(drawResources, { phase = "the_end" })
  -- The source disables text/OBJ layers over The End and prints no edition
  -- title on top of it (the title ran at credit init).
  Assert.equal(#sink.text, 0, "The End draws its source art, not overlaid text")
  Assert.isTrue(sink.images ~= nil and #sink.images == 1, "The End draws its published source art")
  Assert.equal(#sink.windows, 0, "The End draws its source art, not a generic window")
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

-- The semantic demand distinguishes pending from terminal: an explicit
-- demand failure is terminal, a ready receipt with a missing bundle is
-- terminal, and only an unready receipt without a failure stays pending.
function T.tests.showcase_preparation_distinguishes_pending_from_terminal()
  local HallOfFameScreenState = require("game.hgss.src.ending.HallOfFameScreenState")
  local HallOfFameState = require("libs.hgss.src.save.HallOfFameState")
  local function screen()
    return HallOfFameScreenState.new({ app = "hallOfFame" }, {
      hallOfFame = HallOfFameState.empty(),
      presentation = HallOfFamePresentation.new(nil),
    })
  end
  -- Pending demand + missing bundle: pending, never a failure.
  do
    local state = screen()
    local ready, failure = state:preparePresentation({
      cacheFs = {
        loadLua = function()
          error("missing index")
        end,
      },
      requestEnding = function()
        return nil, nil
      end,
    })
    Assert.isFalse(ready == true, "a cold bundle stays pending")
    Assert.isNil(failure, "pending carries no failure")
  end
  -- Explicit demand failure: terminal.
  do
    local state = screen()
    local ready, failure = state:preparePresentation({
      requestEnding = function()
        return nil, "worker boom"
      end,
    })
    Assert.isFalse(ready == true, "a failed demand never reads ready")
    Assert.isTrue(tostring(failure):find("boom", 1, true) ~= nil, "the demand failure is attributed")
  end
  -- Ready receipt but missing bundle: terminal, not an endless pending.
  do
    local state = screen()
    local ready, failure = state:preparePresentation({
      cacheFs = {
        loadLua = function()
          error("missing index")
        end,
      },
      requestEnding = function()
        return true, nil
      end,
    })
    Assert.isFalse(ready == true, "a ready receipt with no bundle never reads ready")
    Assert.isTrue(failure ~= nil, "the published-but-missing bundle is terminal")
  end
end

return T
