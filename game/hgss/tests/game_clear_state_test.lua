-- The League ending's presentation and input state: congratulations and the
-- credit roll advance only while their generated bundle is ready. A pending
-- bundle gates both frames and input instead of playing the source timeline
-- with no surfaces.

local Assert = require("tests.support.Assert")
local GameClearState = require("game.hgss.src.ending.GameClearState")
local HallOfFamePresentation = require("game.hgss.src.ending.HallOfFamePresentation")

local T = { tests = {} }

local MEMBER_FRAMES = 84

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
      frames = 4976,
      musicBoxWaitFrames = 380,
      messageBank = 440,
      titleMessages = { heartgold = 0, soulsilver = 1 },
      sceneTransitionTimings = { 890 },
      screenFlipTimings = { 890 },
      spriteResources = { charMember = 1, paletteMember = 0, cellMember = 2, animMember = 3 },
      cutsceneResources = { charBaseMember = 20, paletteMember = 149, count = 16 },
      scenes = {
        { index = 0, lower = { path = "data/generated/ending/images/a.png", sha1 = "aa" }, upper = { path = "data/generated/ending/images/b.png", sha1 = "bb" } },
      },
      pages = {
        { page = 0, startTime = 0, duration = 105, lines = {} },
      },
      theEnd = { path = "data/generated/ending/images/end.png", sha1 = "ee" },
    },
  }
end

local function actionInput()
  return { actionPressed = true, cancelPressed = false, menuPressed = false, uiEvents = {} }
end

local function fakeAdmissionResources()
  return {
    cacheFs = {
      read = function(_, _)
        return "png-bytes"
      end,
      newFileData = function(_, bytes, path)
        return { bytes = bytes, path = path }
      end,
    },
    graphics = {
      newImage = function(_)
        local image = {}
        function image:setFilter()
        end
        function image:release()
        end
        return image
      end,
      draw = function()
      end,
    },
    messageProvider = {
      acquireBank = function()
        return {}
      end,
      get = function(_, _, _)
        return { text = "admitted", tokens = {} }
      end,
      format = function(_, template)
        return { text = template.text, tokens = {} }
      end,
      releaseBank = function()
      end,
    },
    monCatalog = {
      species = function()
        return { name = "SPECIES", nativeId = 1 }
      end,
      move = function()
        return { nativeId = 1 }
      end,
    },
  }
end

local function admitRegistration(presentation)
  local admitted, failure = presentation:admitImages(fakeAdmissionResources(), { "registration" })
  Assert.isTrue(admitted, "registration text admits: " .. tostring(failure))
  presentation:noteIconsAdmitted()
end

local function admitCredits(presentation)
  local admitted, failure = presentation:admitImages(fakeAdmissionResources(), { "credits" })
  Assert.isTrue(admitted, "credit art and text admit: " .. tostring(failure))
end

function T.tests.congratulations_waits_while_the_bundle_is_pending()
  local presentation = HallOfFamePresentation.new(nil)
  local state = GameClearState.new({ vsRed = 0, previouslyCleared = false, presentation = presentation, partySize = 2 })
  for _ = 1, MEMBER_FRAMES * 2 + 10 do
    Assert.equal(state:step(actionInput()), "wait", "a pending bundle never acknowledges the congratulations")
  end
  Assert.equal(state:phase(), "congratulations", "the registration holds its phase until the bundle is ready")
  -- Preparing the bundle mid-phase is not enough: the phase clock and input
  -- stay blocked until the actually required text/icons receipt admits.
  presentation:prepare(bundle())
  for _ = 1, 10 do
    Assert.equal(state:step(actionInput()), "wait", "sections without admission never acknowledge")
  end
  admitRegistration(presentation)
  for _ = 1, MEMBER_FRAMES * 2 + 1 do
    Assert.equal(state:step(nil), "wait", "the reveal plays its source frames before accepting input")
  end
  Assert.equal(state:step(actionInput()), "publish", "the revealed party acknowledges and publishes")
  -- The terminal acknowledgment accepts A or B (never START): START alone
  -- never advances the registration.
  local restart = GameClearState.new({ vsRed = 0, previouslyCleared = false, presentation = presentation, partySize = 1 })
  for _ = 1, MEMBER_FRAMES + 1 do
    restart:step(nil)
  end
  Assert.equal(
    restart:step({ actionPressed = false, cancelPressed = false, menuPressed = true, uiEvents = {} }),
    "wait",
    "START alone never acknowledges the registration"
  )
  Assert.equal(
    restart:step({ actionPressed = false, cancelPressed = true, menuPressed = false, uiEvents = {} }),
    "publish",
    "B acknowledges the revealed party"
  )
end

function T.tests.credits_wait_while_the_bundle_is_pending()
  local presentation = HallOfFamePresentation.new(nil)
  local state = GameClearState.new({ vsRed = 1, previouslyCleared = true, presentation = presentation, partySize = 0 })
  -- A Red start holds its saving phase until its save-text receipt admits:
  -- publishing with no presented surface is never the source order.
  Assert.equal(state:step(nil), "wait", "a cold Red start never publishes")
  presentation:prepare(bundle())
  Assert.equal(state:step(nil), "wait", "sections without admission never publish")
  admitRegistration(presentation)
  Assert.equal(state:step(nil), "publish", "the Red ending publishes once its save receipt admits")
  state:saveSucceeded()
  for _ = 1, 100 do
    Assert.equal(state:step({ actionPressed = false, menuPressed = true, uiEvents = {} }), "wait", "pending credits never skip")
  end
  Assert.equal(state:phase(), "credits", "the roll holds its phase until the bundle is ready")
  admitCredits(presentation)
  Assert.equal(state:step({ actionPressed = false, menuPressed = true, uiEvents = {} }), "wait", "a later clear skips on START once ready")
  Assert.isTrue(state:wasSkipped(), "the skip is recorded")
end

function T.tests.without_a_presentation_owner_the_headless_timeline_is_unchanged()
  local state = GameClearState.new({ vsRed = 0, previouslyCleared = false, presentation = nil, partySize = 2 })
  Assert.equal(state:step(actionInput()), "publish", "a headless composition acknowledges at once")
end

return T
