-- Feature-local presenter over the generated League ending bundle: plans and
-- draws are built from the bundle's plain records, never from serialized
-- callbacks. An unready presentation draws nothing and reports zero frames;
-- a prepared one exposes the source member cadence, credit timelines and the
-- recorded party surfaces through borrowed text/window/icon/image owners.

local Assert = require("tests.support.Assert")
local HallOfFamePresentation = require("game.hgss.src.ending.HallOfFamePresentation")

local T = { tests = {} }

local CREDIT_FRAMES = 4976
local MUSIC_BOX_WAIT = 380

local function bundle()
  return {
    signature = "ending-cache-v1:rom:deps",
    registration = {
      messageBank = 180,
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

-- Valid blank PNG bytes so silhouette admission can decode them through
-- the real image decoder while the fake graphics stack stays non-rendering.
local function blankPng(width, height)
  local pixels = {}
  for _ = 1, (width or 80) * (height or 80) do
    pixels[#pixels + 1] = string.char(0, 0, 0, 0)
  end
  local data = love.image.newImageData(width or 80, height or 80)
  return data:encode("png"):getString()
end

local BLANK_PNG = blankPng(80, 80)

local function fakeResources(sink)
  local images = {}
  return {
    graphics = {
      draw = function(first, second, third, fourth)
        -- Host calls use dot syntax (no self): (image, x, y) or
        -- (image, quad, x, y).
        local image, x, y
        if fourth ~= nil then
          image, x, y = first, third, fourth
        else
          image, x, y = first, second, third
        end
        sink.images = sink.images or {}
        sink.images[#sink.images + 1] = { image = image, x = x, y = y }
      end,
      newImage = function(_, fileData)
        local image = { fileData = fileData }
        function image:setFilter()
        end
        function image:release()
        end
        function image:getWidth()
          return 256
        end
        function image:getHeight()
          return 256
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
        return { name = tostring(key), nativeId = 157, genderRatio = 31 }
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
        return BLANK_PNG
      end,
      newFileData = function(_, bytes, path)
        return love.filesystem.newFileData(bytes, path)
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
  local drawResources = fakeResources(sink)
  -- The draw receipt admits outside draw: static text, the record header
  -- with its real number/date, and the party's localized names. A steady
  -- draw then performs no bank acquisition.
  local admitted, admitFailure = presentation:admitImages(drawResources, { "showcase" })
  Assert.isTrue(admitted, "showcase text admits before the first draw: " .. tostring(admitFailure))
  local headerAdmitted, headerFailure =
    presentation:admitShowcaseHeader(status.recordNumber, status.date, drawResources)
  Assert.isTrue(headerAdmitted, "showcase header admits before the first draw: " .. tostring(headerFailure))
  local partyAdmitted, partyFailure = presentation:admitParty(status.party, drawResources)
  Assert.isTrue(partyAdmitted, "showcase party admits before the first draw: " .. tostring(partyFailure))
  plan.render(drawResources, status, plan)
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
  local tracks = {}
  local steps = {}
  for index = 1, 10 do
    steps[index] = { next = 0, duration = 1, xOffset = 0 }
  end
  tracks.TYPHLOSION = {
    front = { cryDelay = 5, steps = steps },
    back = { cryDelay = 7, steps = steps },
    heights = { [0] = { male = 40, female = 40 } },
  }
  local function frame(path)
    return { frames = { { path = path, width = 32, height = 32, origin = { x = 0, y = 0 }, durationTicks = 1 } }, playMode = "forward", loopStart = 0 }
  end
  local bundle = {
    signature = "ending-cache-v1:rom:deps",
    registration = {
      messageBank = 180,
      bgIndiv = { { path = "bg0", sha1 = "aa" }, { path = "bg1", sha1 = "bb" }, { path = "bg2", sha1 = "cc" } },
      bgWhole = { { path = "bgw0", sha1 = "dd" }, { path = "bgw1", sha1 = "ee" } },
      owSmall = { [0] = frame("ow"), [1] = frame("ow"), [2] = frame("ow"), [3] = frame("ow") },
      owLarge = { [0] = frame("ow"), [1] = frame("ow"), [2] = frame("ow"), [3] = frame("ow") },
      twinkle = { [0] = frame("tw") },
      twinkleShadow = { [0] = frame("tws") },
      shadow = { [0] = frame("sh") },
      playerEthan = { [0] = frame("pl") },
      playerLyra = { [0] = frame("pl") },
      monTracks = tracks,
      spotlightColors = { { 31, 31, 12 }, { 31, 31, 16 }, { 31, 28, 8 }, { 31, 31, 12 }, { 31, 31, 16 }, { 31, 28, 8 }, { 31, 31, 12 }, { 31, 31, 12 } },
      confettiColors = { { 31, 0, 0 }, { 0, 31, 0 }, { 0, 0, 31 }, { 31, 31, 0 }, { 0, 31, 31 }, { 31, 0, 31 }, { 31, 31, 31 }, { 16, 16, 16 } },
      flashFrames = 40,
      reflashFrames = 15,
      fadeFrames = 15,
      flashSe = "SEQ_SE_GS_DENDOUIRI_FLASH",
      kanseiSe = "SEQ_SE_GS_DENDOUIRI_KANSEI",
      bgm = "SEQ_GS_E_DENDOUIRI",
    },
    showcase = { messageBank = 181 },
    credits = {
      frames = CREDIT_FRAMES,
      musicBoxWaitFrames = MUSIC_BOX_WAIT,
      messageBank = 440,
      titleMessages = { heartgold = 0, soulsilver = 1 },
      sceneTransitionTimings = { 890 },
      screenFlipTimings = { 890 },
      scenes = {},
      pages = { { page = 0, startTime = 0, duration = 105, lines = {} } },
      theEnd = { path = "data/generated/ending/images/end.png", sha1 = "ee" },
    },
  }
  local presentation = HallOfFamePresentation.new(bundle)
  local status = {
    section = "registration",
    phase = "congratulations",
    party = {
      { species = "TYPHLOSION", level = 60, form = 0, personality = 0, nickname = "TYPHLOSION", otName = "GOLD", origin = { trainerId = 1, trainerName = "GOLD", game = "heartgold" }, met = { location = 1 }, egg = { location = 0 } },
    },
    playerName = "GOLD",
    trainerId = 1,
    playHours = 1,
    playMinutes = 2,
  }
  local sink = { text = {}, windows = {} }
  local drawResources = fakeResources(sink)
  drawResources.monCatalog.form = function(_, _)
    return { portrait = "TYPHLOSION/f0/male/plain" }
  end
  drawResources.cacheFs.loadLua = function(_, path)
    if tostring(path):find("portraits", 1, true) ~= nil then
      return {
        entries = {
          ["TYPHLOSION/f0/male/plain"] = {
            pageId = 0,
            width = 80,
            height = 80,
            frames = { { x = 0, y = 0, width = 80, height = 80 } },
          },
          ["TYPHLOSION/f0/male/plain/back"] = {
            pageId = 0,
            width = 80,
            height = 80,
            frames = { { x = 0, y = 0, width = 80, height = 80 } },
          },
          ["TYPHLOSION/f0/female/plain"] = {
            pageId = 0,
            width = 80,
            height = 80,
            frames = { { x = 0, y = 0, width = 80, height = 80 } },
          },
          ["TYPHLOSION/f0/female/plain/back"] = {
            pageId = 0,
            width = 80,
            height = 80,
            frames = { { x = 0, y = 0, width = 80, height = 80 } },
          },
          ["TYPHLOSION/f0/female/shiny"] = {
            pageId = 0,
            width = 80,
            height = 80,
            frames = { { x = 0, y = 0, width = 80, height = 80 } },
          },
          ["TYPHLOSION/f0/female/shiny/back"] = {
            pageId = 0,
            width = 80,
            height = 80,
            frames = { { x = 0, y = 0, width = 80, height = 80 } },
          },
          ["TYPHLOSION/f0/male/plain/back"] = {
            pageId = 0,
            width = 80,
            height = 80,
            frames = { { x = 0, y = 0, width = 80, height = 80 } },
          },
        },
      }
    end
    return {
      memo = {
        landmarks = { wildByLocation = { [1] = "TOWN" }, giftByLocation = {}, fallback = "NOWHERE" },
      },
    }
  end
  drawResources.graphics.newQuad = function(_, x, y, w, h, iw, ih)
    return { x = x, y = y, width = w, height = h, imageWidth = iw, imageHeight = ih }
  end
  local HallOfFamePresentation = require("game.hgss.src.ending.HallOfFamePresentation")
  local admitted, admitFailure = presentation:admitImages(drawResources, { "registration" })
  Assert.isTrue(admitted, "registration art and text admit before the first draw: " .. tostring(admitFailure))
  local partyAdmitted, partyFailure = presentation:admitParty(status.party, drawResources)
  Assert.isTrue(partyAdmitted, "registration party admits before the first draw: " .. tostring(partyFailure))
  presentation:noteIconsAdmitted()
  local portraitsAdmitted, portraitsFailure = presentation:admitPortraits(drawResources, status.party)
  Assert.isTrue(portraitsAdmitted, "registration portraits admit before the first draw: " .. tostring(portraitsFailure))
  presentation:notePortraitsAdmitted()
  local _, memoFailure = presentation:admitMemoMaps(drawResources.cacheFs)
  Assert.isNil(memoFailure, "memo landmarks admit before the first draw")
  local memo = assert(presentation:memoMaps(), "memo landmarks admit before the first draw")
  local detailAdmitted, detailFailure =
    presentation:admitRegistrationDetail(status.party[1], drawResources, memo, { name = "GOLD", trainerId = 1 }, nil)
  Assert.isTrue(detailAdmitted, "registration detail admits before the first draw: " .. tostring(detailFailure))
  local wholeAdmitted, wholeFailure = presentation:admitWholePartyLines("GOLD", 1, 1, 2, drawResources)
  Assert.isTrue(wholeAdmitted, "whole-party lines admit before the first draw: " .. tostring(wholeFailure))
  presentation:noteDetailsAdmitted()
  -- Drive the scene to its whole-party photo wait, then draw one frame of
  -- the group photo: no bank acquisition, no missing art, no crash.
  local RegistrationScene = require("game.hgss.src.ending.RegistrationScene")
  local scene = RegistrationScene.new({ party = status.party, tracks = tracks })
  local guard = 0
  while not scene:status().photoWait and guard < 5000 do
    scene:step(nil)
    guard = guard + 1
  end
  Assert.isTrue(scene:status().photoWait, "the reveal reaches its photo wait")
  status.registration = scene:status()
  local drawOk, drawErr = pcall(presentation.draw, presentation, drawResources, status)
  Assert.isTrue(drawOk, "the whole-party photo draws its admitted bundle: " .. tostring(drawErr))
  local joined = {}
  for _, entry in ipairs(sink.text) do
    joined[#joined + 1] = tostring(entry.text)
  end
  Assert.isTrue(
    table.concat(joined, "\n"):find("msg180:16", 1, true) ~= nil,
    "the whole-party photo paints its congratulations line"
  )
  Assert.isTrue(#sink.windows > 0, "the whole-party photo paints its windows")
  Assert.isTrue(sink.images ~= nil and #sink.images > 0, "the whole-party photo draws its admitted art")
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

function T.tests.credits_draw_paints_dancers_clouds_and_cutscenes()
  local staged = bundle()
  local function baked(path)
    return { frames = { { path = path, blank = false, durationTicks = 2 } }, playMode = "forward_loop" }
  end
  staged.credits.danceSequences = { [6] = baked("dance"), [7] = baked("cloud") }
  staged.credits.danceSeqsByScene = { 6, 1, 2, 4, 3, 5 }
  staged.credits.cloudSeq = 7
  staged.credits.cutscenes = {
    {
      uniqueSprites = 1,
      totalSprites = 1,
      spriteIds = { 0 },
      params = { { spriteIdx = 0, animSeq = 2, x = 128, y = 96, activateTime = 4 } },
    },
  }
  staged.credits.cutsceneSprites = {
    [0] = { sequences = { [2] = baked("cutscene") } },
  }
  local presentation = HallOfFamePresentation.new(staged)
  local sink = { text = {}, windows = {} }
  local drawResources = fakeResources(sink)
  local admitted, admitFailure = presentation:admitImages(drawResources, { "credits" })
  Assert.isTrue(admitted, "choreography art admits before the first draw: " .. tostring(admitFailure))
  local status = {
    phase = "credits",
    timer = 890,
    versionId = "soulsilver",
    credits = {
      timer = 890,
      sceneIdx = 0,
      danceSeq = 6,
      danceClock = 890,
      cloudSeq = 7,
      cloudsVisible = true,
      cloudClock = 0,
      screensFlipped = false,
      flipCount = 1,
      cutsceneIdx = 0,
      cutsceneSprites = { { spriteId = 0, animSeq = 2, x = 128, y = 96, active = true, elapsed = 1 } },
      gender = "male",
      done = false,
    },
  }
  local drawOk, drawErr = pcall(presentation.draw, presentation, drawResources, status)
  Assert.isTrue(drawOk, "the choreography draws its admitted bundle: " .. tostring(drawErr))
  local images = sink.images or {}
  -- Two background layers plus six dancers, six transition clouds and one
  -- active cutscene sprite, all from the admitted bundle.
  Assert.equal(#images, 15, "the roll draws its backgrounds, dancers, clouds and cutscene")
  local cutscene = false
  local dancer = false
  for _, entry in ipairs(images) do
    if entry.x == 128 and entry.y == 96 then
      cutscene = true
    end
    if entry.x == 16 and entry.y == 16 then
      dancer = true
    end
  end
  Assert.isTrue(cutscene, "the active cutscene sprite draws at its source anchor")
  Assert.isTrue(dancer, "the visible dance set draws at its source formation")
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
