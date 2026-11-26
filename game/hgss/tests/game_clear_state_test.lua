-- The League ending's presentation and input state: congratulations and the
-- credit roll advance only while their generated bundle is ready. A pending
-- bundle gates both frames and input instead of playing the source timeline
-- with no surfaces.

local Assert = require("tests.support.Assert")
local GameClearState = require("game.hgss.src.ending.GameClearState")
local HallOfFamePresentation = require("game.hgss.src.ending.HallOfFamePresentation")

local T = { tests = {} }

local function trackSteps()
  local steps = {}
  for index = 1, 10 do
    steps[index] = { next = 0, duration = 1, xOffset = 0 }
  end
  steps[2] = { next = -1, duration = 0, xOffset = 0 }
  return steps
end

local function bundle()
  local tracks = {}
  tracks.SPECIES = {
    front = { cryDelay = 5, steps = trackSteps() },
    back = { cryDelay = 7, steps = trackSteps() },
    heights = { [0] = { male = 40, female = 40 } },
  }
  return {
    signature = "ending-cache-v1:rom:deps",
    registration = {
      messageBank = 180,
      monTracks = tracks,
    },
    showcase = { messageBank = 181 },
    credits = {
      frames = 4976,
      musicBoxWaitFrames = 380,
      messageBank = 440,
      titleMessages = { heartgold = 0, soulsilver = 1 },
      sceneTransitionTimings = { 890 },
      screenFlipTimings = { 890 },
      scenes = {
        {
          index = 0,
          lower = { path = "data/generated/ending/images/a.png", sha1 = "aa" },
          upper = { path = "data/generated/ending/images/b.png", sha1 = "bb" },
        },
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
        function image:setFilter() end
        function image:release() end
        return image
      end,
      draw = function() end,
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
      releaseBank = function() end,
    },
    monCatalog = {
      species = function()
        return { name = "SPECIES", nativeId = 1 }
      end,
      move = function()
        return { nativeId = 1 }
      end,
      iconSelection = function()
        return "icon:test"
      end,
    },
    fontDef = {
      charmap = setmetatable({}, {
        __index = function()
          return 1
        end,
      }),
    },
  }
end

local function sceneParty(count)
  local party = {}
  for _ = 1, count or 2 do
    party[#party + 1] = { species = "SPECIES", form = 0, gender = "male", owLarge = false }
  end
  return party
end

local function fakeParty(count)
  local party = {}
  for _ = 1, count or 2 do
    party[#party + 1] = {
      species = "SPECIES",
      level = 50,
      moves = { "MOVE" },
    }
  end
  return party
end

local function admitRegistration(presentation, partySize)
  local resources = fakeAdmissionResources()
  local admitted, failure = presentation:admitImages(resources, { "registration" })
  Assert.isTrue(admitted, "registration text admits: " .. tostring(failure))
  local partyAdmitted, partyFailure = presentation:admitParty(fakeParty(partySize or 2), resources)
  Assert.isTrue(partyAdmitted, "registration party admits: " .. tostring(partyFailure))
  presentation:noteIconsAdmitted()
  -- The unit composition stands in for FieldState's portrait/detail
  -- preparation: the fake bundle carries no portrait pages or memo maps,
  -- so the test marks their receipts the way the field owner would after
  -- admitting them through the real caches.
  presentation:notePortraitsAdmitted()
  presentation:noteDetailsAdmitted()
end

local function admitSave(presentation)
  local resources = fakeAdmissionResources()
  local admitted, failure = presentation:admitImages(resources, { "save" })
  Assert.isTrue(admitted, "save text admits: " .. tostring(failure))
  local saveAdmitted, saveFailure = presentation:admitSaveResult("TEST", resources)
  Assert.isTrue(saveAdmitted, "save result admits: " .. tostring(saveFailure))
end

local function admitCredits(presentation)
  local admitted, failure = presentation:admitImages(fakeAdmissionResources(), { "credits" })
  Assert.isTrue(admitted, "credit art and text admit: " .. tostring(failure))
end

function T.tests.congratulations_waits_while_the_bundle_is_pending()
  local presentation = HallOfFamePresentation.new(nil)
  local state = GameClearState.new({
    vsRed = 0,
    previouslyCleared = false,
    presentation = presentation,
    sceneParty = sceneParty(2),
  })
  for _ = 1, 50 do
    Assert.equal(state:step(actionInput()), "wait", "a pending bundle never acknowledges the congratulations")
  end
  Assert.equal(state:phase(), "congratulations", "the registration holds its phase until the bundle is ready")
  -- Preparing the bundle mid-phase is not enough: the phase clock and input
  -- stay blocked until the actually required text/icons/party receipt admits.
  presentation:prepare(bundle())
  for _ = 1, 10 do
    Assert.equal(state:step(actionInput()), "wait", "sections without admission never acknowledge")
  end
  admitRegistration(presentation, 2)
  admitSave(presentation)
  -- The reveal runs every recorded member's own source stages (one
  -- back-picture cry and one front-picture cry per member) before the
  -- whole-party photo wait; input is ignored everywhere before it.
  local sawIndiv = false
  for _ = 1, 4000 do
    Assert.equal(state:step(actionInput()), "wait", "the reveal ignores input before the photo wait")
    local registration = state:status().registration
    Assert.isTrue(registration ~= nil, "the congratulations phase publishes its registration scene")
    if registration.phase == "indiv" then
      sawIndiv = true
    end
    if state:phase() ~= "congratulations" or registration.photoWait then
      break
    end
  end
  Assert.isTrue(sawIndiv, "the reveal plays the individual scenes")
  Assert.equal(state:phase(), "congratulations", "the photo wait holds the congratulations phase")
  -- The terminal acknowledgment accepts A or B (never START): START alone
  -- never advances the registration, while A/B/touch do.
  for _ = 1, 30 do
    Assert.equal(
      state:step({ actionPressed = false, cancelPressed = false, menuPressed = true, uiEvents = {} }),
      "wait",
      "START alone never advances the photo wait"
    )
  end
  Assert.equal(state:phase(), "congratulations", "the photo wait holds through START")
  Assert.equal(state:step(actionInput()), "wait", "the photo wait acknowledges into its flashes")
  for _ = 1, 500 do
    Assert.equal(state:step(nil), "wait", "the accepted photo plays out before saving")
    if state:phase() == "saving" then
      break
    end
  end
  Assert.equal(state:phase(), "saving", "the played-out photo moves to saving")
  Assert.equal(state:step(nil), "wait", "the first saving tick arms the write while the message draws")
  Assert.equal(state:step(nil), "publish", "the saving surface publishes after its admitted frame")
end

-- The presented roll steps its choreography once ready: scene transitions,
-- flips and cutscene activation advance with the scene machine, and the
-- roll ends on its source frame count instead of the bare timer.
-- The shared fake bundle extended with a short choreography: tiny
-- transition/flip timelines and one two-tick cutscene sprite keep the
-- roll fast while exercising transitions, flips, activation, completion
-- and the source frame count.
local function choreographyBundle()
  local dance = {}
  for _, seqNo in ipairs({ 0, 1, 2, 3, 4, 5, 6, 7 }) do
    dance[seqNo] = { frames = { { durationTicks = 2, path = "dance", blank = false } }, playMode = "forward_loop" }
  end
  local staged = bundle()
  staged.credits.frames = 24
  staged.credits.sceneTransitionTimings = { 5, 10, 15, 20, 25 }
  staged.credits.screenFlipTimings = { 5, 10, 15, 20, 25 }
  staged.credits.danceSequences = dance
  staged.credits.danceSeqsByScene = { 6, 1, 2, 4, 3, 5 }
  staged.credits.cloudSeq = 7
  staged.credits.cutscenes = {
    {
      uniqueSprites = 1,
      totalSprites = 1,
      spriteIds = { 0 },
      params = {
        { spriteIdx = 0, animSeq = 2, x = 128, y = 96, activateTime = 4 },
      },
    },
  }
  staged.credits.cutsceneSprites = {
    [0] = { sequences = { [2] = { frames = { { durationTicks = 2, path = "cut", blank = false } }, playMode = "forward" } } },
  }
  return staged
end

function T.tests.credits_steps_its_choreography_once_ready()
  local presentation = HallOfFamePresentation.new(nil)
  local state = GameClearState.new({ vsRed = 1, previouslyCleared = false, presentation = presentation })
  presentation:prepare(choreographyBundle())
  admitSave(presentation)
  Assert.equal(state:step(nil), "wait", "the first admitted saving tick arms the write")
  Assert.equal(state:step(nil), "publish", "the Red ending publishes once its save receipt admits")
  state:saveSucceeded()
  admitCredits(presentation)
  presentation:noteCutsceneGender("male")
  for _ = 1, 100 do
    if state:phase() == "credits" then
      break
    end
    Assert.equal(state:step(nil), "wait", "the save result plays before the roll")
  end
  Assert.equal(state:phase(), "credits", "the roll starts after the save result")
  for _ = 1, 3 do
    Assert.equal(state:step(nil), "wait", "the roll holds while its scene starts")
  end
  local started = state:status().credits
  Assert.isTrue(started ~= nil, "the roll publishes its choreography scene")
  Assert.equal(started.timer, 3, "the scene owns the roll clock")
  Assert.equal(started.sceneIdx, 0, "the roll opens on its first scene")
  for _ = 1, 2 do
    state:step(nil)
  end
  local swapped = state:status().credits
  Assert.equal(swapped.timer, 5, "the choreography advances one frame per tick")
  Assert.isTrue(swapped.cloudsVisible, "clouds cover the first background swap")
  Assert.equal(swapped.cutsceneIdx, 0, "the cutscene holds while its sprite animates")
  state:step(nil)
  Assert.equal(state:status().credits.cutsceneIdx, 1, "the cutscene advances once its sprite finishes")
  for _ = 1, 19 do
    Assert.equal(state:step(nil), "wait", "the roll never skips without input")
  end
  Assert.equal(state:phase(), "credits_fade", "the roll ends on its source frame count")
end

function T.tests.credits_wait_while_the_bundle_is_pending()
  local presentation = HallOfFamePresentation.new(nil)
  local state = GameClearState.new({ vsRed = 1, previouslyCleared = true, presentation = presentation })
  -- A Red start holds its saving phase until its save-text receipt admits:
  -- publishing with no presented surface is never the source order.
  Assert.equal(state:step(nil), "wait", "a cold Red start never publishes")
  presentation:prepare(bundle())
  Assert.equal(state:step(nil), "wait", "sections without admission never publish")
  admitSave(presentation)
  Assert.equal(state:step(nil), "wait", "the first admitted saving tick arms the write")
  Assert.equal(state:step(nil), "publish", "the Red ending publishes once its save receipt admits")
  state:saveSucceeded()
  for _ = 1, 100 do
    Assert.equal(
      state:step({ actionPressed = false, menuPressed = true, uiEvents = {} }),
      "wait",
      "pending credits never skip"
    )
  end
  Assert.equal(state:phase(), "credits", "the roll holds its phase until the bundle is ready")
  admitCredits(presentation)
  Assert.equal(
    state:step({ actionPressed = false, menuPressed = true, uiEvents = {} }),
    "wait",
    "a later clear skips on START once ready"
  )
  Assert.isTrue(state:wasSkipped(), "the skip is recorded")
end

function T.tests.headless_composition_advances_on_bundle_readiness_without_draw_receipt()
  -- The real runtime-only composition always carries a presentation owner
  -- (FieldRuntime._composeGameClear), but no display: headless advances on
  -- bundle readiness alone instead of deadlocking on the GPU/icon receipt
  -- the presented path requires.
  local presentation = HallOfFamePresentation.new(nil)
  presentation:prepare(bundle())
  local headless = GameClearState.new({
    vsRed = 1,
    previouslyCleared = true,
    presentation = presentation,
    headless = true,
  })
  Assert.equal(headless:step(nil), "wait", "headless arms the write on its first saving tick")
  Assert.equal(headless:step(nil), "publish", "headless publishes without any draw admission")
  -- The same owner without the headless flag holds: the presented clock
  -- never runs ahead of its surface.
  local presented = GameClearState.new({
    vsRed = 1,
    previouslyCleared = true,
    presentation = presentation,
  })
  for _ = 1, 10 do
    Assert.equal(presented:step(nil), "wait", "presented saving holds without its draw receipt")
  end
  Assert.equal(presented:phase(), "saving", "presented saving never publishes cold")
end

function T.tests.without_a_presentation_owner_the_headless_timeline_is_unchanged()
  local state = GameClearState.new({
    vsRed = 0,
    previouslyCleared = false,
    presentation = nil,
    sceneParty = sceneParty(2),
  })
  -- Headless without a presentation owner keeps the explicit headless
  -- timeline: the full reveal plays without input, then saving publishes.
  for _ = 1, 4000 do
    Assert.equal(state:step(actionInput()), "wait", "the headless reveal ignores input before the photo wait")
    if state:phase() ~= "congratulations" then
      break
    end
  end
  Assert.equal(state:phase(), "saving", "headless moves to saving")
  Assert.equal(state:step(nil), "wait", "headless arms the write on its first saving tick")
  Assert.equal(state:step(nil), "publish", "headless saving publishes")
end

return T
