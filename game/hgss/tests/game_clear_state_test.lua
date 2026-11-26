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
    registration = { messageBank = 180, memberFrames = MEMBER_FRAMES },
    showcase = { messageBank = 181 },
    credits = {
      frames = 4976,
      musicBoxWaitFrames = 380,
      messageBank = 440,
      titleMessages = { heartgold = 0, soulsilver = 1 },
      sceneTransitionTimings = { 890 },
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
  return { actionPressed = true, menuPressed = false, uiEvents = {} }
end

function T.tests.congratulations_waits_while_the_bundle_is_pending()
  local presentation = HallOfFamePresentation.new(nil)
  local state = GameClearState.new({ vsRed = 0, previouslyCleared = false, presentation = presentation, partySize = 2 })
  for _ = 1, MEMBER_FRAMES * 2 + 10 do
    Assert.equal(state:step(actionInput()), "wait", "a pending bundle never acknowledges the congratulations")
  end
  Assert.equal(state:phase(), "congratulations", "the registration holds its phase until the bundle is ready")
  -- Preparing the bundle mid-phase unblocks the same state: no restart is needed.
  presentation:prepare(bundle())
  for _ = 1, MEMBER_FRAMES * 2 + 1 do
    Assert.equal(state:step(nil), "wait", "the reveal plays its source frames before accepting input")
  end
  Assert.equal(state:step(actionInput()), "publish", "the revealed party acknowledges and publishes")
end

function T.tests.credits_wait_while_the_bundle_is_pending()
  local presentation = HallOfFamePresentation.new(nil)
  local state = GameClearState.new({ vsRed = 1, previouslyCleared = true, presentation = presentation, partySize = 0 })
  -- The Red ending skips congratulations and saves immediately; force the
  -- roll phase through the published save to isolate the credits gate.
  Assert.equal(state:step(nil), "publish", "the Red ending publishes without a congratulations")
  state:saveSucceeded()
  for _ = 1, 100 do
    Assert.equal(state:step({ actionPressed = false, menuPressed = true, uiEvents = {} }), "wait", "pending credits never skip")
  end
  Assert.equal(state:phase(), "credits", "the roll holds its phase until the bundle is ready")
  presentation:prepare(bundle())
  Assert.equal(state:step({ actionPressed = false, menuPressed = true, uiEvents = {} }), "wait", "a later clear skips on START once ready")
  Assert.isTrue(state:wasSkipped(), "the skip is recorded")
end

function T.tests.without_a_presentation_owner_the_headless_timeline_is_unchanged()
  local state = GameClearState.new({ vsRed = 0, previouslyCleared = false, presentation = nil, partySize = 2 })
  Assert.equal(state:step(actionInput()), "publish", "a headless composition acknowledges at once")
end

return T
