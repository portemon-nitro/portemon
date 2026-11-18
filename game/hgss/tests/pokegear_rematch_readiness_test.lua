-- Durable phone rematch readiness: the field query and the map marker
-- read one saved record behind the live native window, a registered
-- caller without a staged invitation is never ready, and no launch
-- invents a trainer team the generated catalog cannot resolve. Synthetic
-- contacts through the real asset schema and state owner; no ROM data.

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
          sortWeight = 10,
          rematchWeekday = 6,
          rematchTimeOfDay = 1,
        },
      },
      contactOrder = { "custom.leader-falkner" },
      callDefinitions = {},
      callTriggers = {},
      rematches = {},
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

-- One composed phone call over the real state owner, catalog, and
-- native window: only the saved record differs between the scenarios.
---@param seed integer
---@param staged { stage: integer, wins: integer }?
---@return table call, table state
local function freshRematchCall(seed, staged)
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local state = PokegearState.new({ seed = seed }, { catalog = record.catalog })
  state:registerContact(CONTACT)
  if staged ~= nil then
    state:setRematch(CONTACT, staged)
  end
  local world = {
    nativeSelectorFacts = function()
      return { localMap = false }
    end,
    rematchFacts = function()
      return { weekday = 6, timeOfDay = 1 }
    end,
    queryRematch = function(_, contact)
      return state:queryRematch(contact)
    end,
    setRematch = function(_, contact, entry)
      state:setRematch(contact, entry)
    end,
  }
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
  return call, state
end

-- The field query and the map marker read one saved record behind the
-- live window, and a launch the generated catalog cannot map to a team
-- fails attributed without touching saved progress.
function T.tests.rematch_readiness_follows_the_saved_invitation()
  local call, state = freshRematchCall(2024, { stage = 1, wins = 2 })
  local query = call:queryRematch(CONTACT)
  Assert.equal(query.ready, true, "the field query reports ready inside the eligibility window")
  Assert.isNil(query.tier, "the query does not guess a story tier")
  local marker = call:rematchMarker(CONTACT)
  Assert.equal(marker.ready, query.ready, "the map marker reads the same durable readiness")
  local before = state:queryRematch(CONTACT)
  local failure = Assert.throws(function()
    call:launchRematch(CONTACT)
  end, "launching without a source-backed mapping fails")
  Assert.equal(failure.code, require("libs.script.src.errors").FEATURE_UNAVAILABLE, "the missing team is attributed")
  Assert.deepEqual(state:queryRematch(CONTACT), before, "unsupported launch preserves saved progress")

  -- Registration alone never stages readiness, and the marker agrees.
  local unplayed, unplayedState = freshRematchCall(3031, nil)
  Assert.equal(unplayed:queryRematch(CONTACT).ready, false, "registration without an invitation never reports ready")
  Assert.isNil(unplayed:queryRematch(CONTACT).tier, "the query never guesses a story tier")
  local unplayedMarker = unplayed:rematchMarker(CONTACT)
  Assert.equal(unplayedMarker.ready, false, "the marker agrees that no invitation waits")
  Assert.isNil(unplayedMarker.tier, "the marker carries no invented tier")
  Assert.throws(function()
    unplayed:launchRematch(CONTACT)
  end, "launching without readiness never invents a team")
  Assert.isNil(unplayedState:queryRematch(CONTACT), "readiness queries never stage a record")
end

-- Playing the phone program for a rematch-shaped contact stages no
-- invitation the generated source stage does not authorize.
function T.tests.unsourced_phone_call_does_not_stage_a_rematch()
  local call, state = freshRematchCall(3032, nil)
  local handle = call:begin({ id = "rematch-full-party", contact = CONTACT, direction = "outgoing", kind = "rematch" })
  call:step(handle, {})
  call:step(handle, {})
  Assert.isNil(state:queryRematch(CONTACT), "the phone program does not fabricate an invitation")
  Assert.isFalse(call:queryRematch(CONTACT).ready, "an unsourced contact is not ready")
  local failure = Assert.throws(function()
    call:launchRematch(CONTACT)
  end, "an unsourced challenge cannot launch")
  Assert.equal(
    failure.code,
    require("libs.script.src.errors").FEATURE_UNAVAILABLE,
    "the unsupported launch is attributed"
  )
end

return T
