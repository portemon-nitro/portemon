-- Source phone rematches: the field query and the map marker read one saved
-- invitation and answer the native trainer tier the generated source rematch
-- set resolves to, the unbeaten scan follows the source entry order and its
-- group fallback, Kenji alone waits for the daytime band, and only the
-- explicit seeking clear ends an invitation. Synthetic contacts through the
-- real asset schema and state owner; no ROM data.

local Assert = require("tests.support.Assert")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

local function visualRef(path)
  return { image = path, width = 32, height = 32, anchorX = 0, anchorY = 0 }
end

-- The required phone call-dim roles beside the panel stub: the suites
-- below never paint the phone, but the generated family identity
-- requires the dim roles on every validating manifest.
local function phoneDimSection()
  local section = {
    panel = visualRef("assets/generated/pokegear/phone-panel.png"),
    foregroundDim = {},
    foregroundDimChoice = {},
    dimShellForeground = {},
    listPaletteDim = {},
  }
  for skin = 0, 5 do
    local suffix = "-skin-" .. skin .. ".png"
    section.foregroundDim[skin] = visualRef("assets/generated/pokegear/phone-foreground-dim" .. suffix)
    section.foregroundDimChoice[skin] = visualRef("assets/generated/pokegear/phone-foreground-dim-choice" .. suffix)
    section.dimShellForeground[skin] = visualRef("assets/generated/pokegear/phone-dim-shell-foreground" .. suffix)
    local palette = {}
    for index = 1, 16 do
      palette[index] = { r = index, g = index, b = index }
    end
    section.listPaletteDim[skin] = palette
  end
  local dimSprites = {}
  for sequence = 1, 9 do
    dimSprites[sequence] = {
      frames = {
        {
          image = "assets/generated/pokegear/phone-sprite-dim-phone-" .. sequence .. "-1.png",
          width = 16,
          height = 16,
          anchorX = -8,
          anchorY = -8,
          duration = 1,
        },
      },
      playMode = "forward",
      loopStartFrameIdx = 0,
    }
  end
  section.spritesDim = { phone = dimSprites }
  return section
end

-- Synthetic companion catalog with one rematch trainer, validated through
-- the real asset schema so the journey borrows only genuine references.
---@return table
local function fixtureManifest()
  return {
    schema = "g4-pokegear-assets-v4",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png") },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png") },
    phone = phoneDimSection(),
    map = { base = visualRef("assets/generated/pokegear/map-base.png") },
    fly = { base = visualRef("assets/generated/pokegear/fly-base.png") },
    radio = { dial = visualRef("assets/generated/pokegear/radio-dial.png") },
    catalog = {
      contacts = {
        {
          key = "custom.leader-falkner",
          family = "gym",
          id = 18,
          trainerId = 7,
          messageBank = 648,
          sortWeight = 10,
          rematchWeekday = 6,
          rematchTimeOfDay = 1,
        },
        {
          key = "custom.kenji",
          family = "kenji",
          id = 16,
          trainerId = 17,
          messageBank = 706,
          sortWeight = 20,
          rematchWeekday = 0,
          rematchTimeOfDay = 1,
        },
        {
          key = "custom.daycare-man",
          family = "daycare",
          id = 6,
          trainerId = 0,
          messageBank = 661,
          sortWeight = 30,
          rematchWeekday = 3,
          rematchTimeOfDay = 2,
        },
      },
      contactOrder = { "custom.leader-falkner", "custom.kenji", "custom.daycare-man" },
      callDefinitions = {},
      callTriggers = {},
      -- Source rematch sets: the gym caller's three tiers and Kenji's four,
      -- each opening with its own base trainer and closed by TRAINER_NONE.
      rematches = {
        [7] = { 7, 7, 8, 9, 10, 0 },
        [17] = { 17, 17, 250, 278, 605, 0 },
      },
      gifts = {},
      momPurchases = {},
      locations = {
        { key = "custom.violet-city" },
      },
      flypoints = {},
      regionMap = require("tests.support.PokegearRegionMapFixture").build(),
      reception = {},
      shows = {},
      radioEffects = {},
    },
    text = {},
    sequences = {},
  }
end

local CONTACT = "custom.leader-falkner"
-- The Kenji phonebook contact: the one caller whose invitation also waits for
-- the source daytime band.
local KENJI = "custom.kenji"
local DAYCARE_MAN = "custom.daycare-man"

-- Source day and night bands for the Kenji gate.
local TIMEOFDAY_DAY = 1
local TIMEOFDAY_NIGHT = 2

---@param defeated integer[]
---@param unlockedGroups integer[]
---@param timeOfDay integer
---@return table world a world double answering the source rematch facts
local function rematchWorld(defeated, unlockedGroups, timeOfDay)
  local records = {}
  local defeatedSet = {}
  for _, trainerNo in ipairs(defeated) do
    defeatedSet[trainerNo] = true
  end
  local unlockedSet = {}
  for _, rematchNo in ipairs(unlockedGroups) do
    unlockedSet[rematchNo] = true
  end
  return {
    queryRematch = function(_, contact)
      local record = records[contact]
      if record == nil then
        return nil
      end
      return { stage = record.stage, wins = record.wins }
    end,
    setRematch = function(_, contact, record)
      records[contact] = record
    end,
    trainerDefeated = function(_, trainerNo)
      return defeatedSet[trainerNo] == true
    end,
    rematchGroupUnlocked = function(_, rematchNo)
      return unlockedSet[rematchNo] == true
    end,
    rematchFacts = function()
      return { weekday = 6, timeOfDay = timeOfDay }
    end,
  }
end

---@param seed integer
---@param world table
---@return table call, table state, table catalog
local function rematchCall(seed, world)
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local state = PokegearState.new({ seed = seed }, { catalog = record.catalog })
  for _, contact in ipairs({ CONTACT, KENJI, DAYCARE_MAN }) do
    state:registerContact(contact)
  end
  local call = PhoneCall.new({
    state = state,
    catalog = record.catalog,
    messages = {
      invitation = "custom.invitation",
      accept = "custom.accept",
      resolvePhoneUiMessage = function(_, entryId)
        return { text = "ui" .. tostring(entryId), tokens = { { kind = "glyph", text = "u" } } }
      end,
    },
    world = world,
    audio = {
      isEffectWaitComplete = function()
        return true
      end,
    },
    random = PokegearRandom.new(seed),
  })
  return call, state, record.catalog
end

-- The source rematch scan walks entries 1..5, ends at TRAINER_NONE with the
-- previous entry, skips the 0xFFFF holes, and falls back through the previous
-- non-hole entry when the entry's rematch group is still locked.
function T.tests.first_unbeaten_rematch_scan_follows_the_source_order()
  local TrainerPhonePrograms = require("game.hgss.src.pokegear.phone.TrainerPhonePrograms")
  local function defeats(set)
    return function(trainerNo)
      return set[trainerNo] == true
    end
  end
  -- Every entry is unbeaten: the scan stops at the first one.
  Assert.equal(
    TrainerPhonePrograms.firstUnbeatenRematch({ 7, 7, 8, 9, 10, 0 }, defeats({})),
    1,
    "the first unbeaten entry wins the scan"
  )
  -- The base trainer is beaten and the second entry is a hole: the scan
  -- steps over the hole instead of treating it as a trainer.
  Assert.equal(
    TrainerPhonePrograms.firstUnbeatenRematch({ 7, 7, 0xFFFF, 9, 10, 0 }, defeats({ [7] = true })),
    3,
    "the scan skips a source hole"
  )
  -- TRAINER_NONE ends the scan at the previous entry.
  Assert.equal(
    TrainerPhonePrograms.firstUnbeatenRematch(
      { 7, 7, 8, 9, 10, 0 },
      defeats({ [7] = true, [8] = true, [9] = true, [10] = true })
    ),
    4,
    "the none sentinel ends the scan at the previous entry"
  )
  -- A set whose last entry is a real trainer exhausts the scan at entry five.
  Assert.equal(
    TrainerPhonePrograms.firstUnbeatenRematch(
      { 7, 7, 8, 9, 10, 11 },
      defeats({ [7] = true, [8] = true, [9] = true, [10] = true, [11] = true })
    ),
    5,
    "an exhausted scan answers the last source entry"
  )
  Assert.equal(
    TrainerPhonePrograms.firstUnbeatenRematch({ 7, 7, 8, 0, 0, 0 }, defeats({ [7] = true, [8] = true })),
    2,
    "a short set stops at its own none sentinel"
  )
  -- The group fallback returns the previous non-hole entry, else the set's
  -- own base trainer.
  Assert.equal(
    TrainerPhonePrograms.previousRematch({ 7, 7, 0xFFFF, 9, 10, 0 }, 3),
    1,
    "the group fallback steps back over a hole"
  )
  Assert.equal(
    TrainerPhonePrograms.previousRematch({ 7, 7, 8, 9, 10, 0 }, 1),
    0,
    "the entry above the base trainer falls back to the base itself"
  )
end

-- The field query answers the native trainer tier of the contact's saved
-- invitation, never a boolean or a call-window readiness, and the marker
-- projects the same resolution.
function T.tests.rematch_query_answers_the_source_trainer_tier()
  local world = rematchWorld({ 7 }, {}, TIMEOFDAY_DAY)
  local call = rematchCall(2024, world)

  local unplayed = call:queryRematch(CONTACT)
  Assert.equal(unplayed.trainerId, 0, "a contact that never asked for a rematch offers no trainer")
  Assert.equal(unplayed.ready, false, "no saved invitation is never ready")
  Assert.equal(call:rematchMarker(CONTACT).trainerId, 0, "the marker carries no invented trainer")

  world.setRematch(world, CONTACT, { stage = 1, wins = 2 })
  -- The base trainer is beaten and the next entry's group is still locked,
  -- so the source falls back to the previous non-hole entry.
  local locked = call:queryRematch(CONTACT)
  Assert.equal(locked.trainerId, 7, "a locked rematch group offers the contact's own tier")
  Assert.equal(locked.ready, true, "the staged invitation answers ready")
  local marker = call:rematchMarker(CONTACT)
  Assert.equal(marker.trainerId, locked.trainerId, "the marker projects the same trainer tier")
  Assert.equal(marker.ready, true, "the marker projects the same readiness")

  -- Unlocking the group behind the next entry offers that tier instead.
  local unlockedWorld = rematchWorld({ 7 }, { 2 }, TIMEOFDAY_DAY)
  local unlockedCall = rematchCall(2024, unlockedWorld)
  unlockedWorld.setRematch(unlockedWorld, CONTACT, { stage = 1, wins = 2 })
  Assert.equal(unlockedCall:queryRematch(CONTACT).trainerId, 8, "an unlocked rematch group offers its own tier")

  -- The clear ends the invitation, keeps the accumulated wins, and repeated
  -- clears stay no-ops.
  local cleared = call:clearRematchSeeking(CONTACT)
  Assert.equal(cleared.ready, false, "the clear reports no invitation")
  Assert.equal(world.queryRematch(world, CONTACT).stage, 0, "the clear ends the saved invitation")
  Assert.equal(world.queryRematch(world, CONTACT).wins, 2, "the clear keeps the accumulated win count")
  Assert.equal(call:queryRematch(CONTACT).trainerId, 0, "a cleared invitation offers no trainer")
  call:clearRematchSeeking(CONTACT)
  Assert.equal(world.queryRematch(world, CONTACT).wins, 2, "a repeated clear changes nothing")
end

-- Kenji's invitation waits for the source daytime band; every other caller
-- does not. A contact without a rematch set answers numeric zero at any hour.
function T.tests.kenji_invitation_waits_for_the_source_daytime()
  local nightWorld = rematchWorld({ 17 }, {}, TIMEOFDAY_NIGHT)
  local night = rematchCall(4041, nightWorld)
  nightWorld.setRematch(nightWorld, KENJI, { stage = 1, wins = 0 })
  nightWorld.setRematch(nightWorld, CONTACT, { stage = 1, wins = 0 })
  nightWorld.setRematch(nightWorld, DAYCARE_MAN, { stage = 1, wins = 0 })
  Assert.equal(night:queryRematch(KENJI).trainerId, 0, "Kenji's invitation waits for its own daytime")
  Assert.equal(night:queryRematch(CONTACT).trainerId, 7, "another caller resolves at night")

  local dayWorld = rematchWorld({ 17 }, {}, TIMEOFDAY_DAY)
  local day = rematchCall(4041, dayWorld)
  dayWorld.setRematch(dayWorld, KENJI, { stage = 1, wins = 0 })
  dayWorld.setRematch(dayWorld, DAYCARE_MAN, { stage = 1, wins = 0 })
  Assert.equal(day:queryRematch(KENJI).trainerId, 17, "Kenji's invitation answers his own tier by day")
  Assert.equal(
    day:queryRematch(DAYCARE_MAN).trainerId,
    0,
    "a contact without a rematch set never offers a trainer"
  )
end

return T
