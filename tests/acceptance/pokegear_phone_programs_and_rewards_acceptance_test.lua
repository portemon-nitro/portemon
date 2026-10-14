-- Durable phone rematches use PokegearState, native trainer groups and
-- field progression facts.

local Assert = require("tests.support.Assert")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

-- Loads the phone session owner that does not exist yet at this baseline.
-- The failure names the missing behaviour instead of surfacing as a suite
-- load error, so the pre-implementation red stays attributable.
---@param moduleName string
---@param missingMessage string
---@return table
local function requireFeature(moduleName, missingMessage)
  local ok, mod = pcall(require, moduleName)
  if not ok then
    error(missingMessage, 0)
  end
  assert(type(mod) == "table", missingMessage)
  return mod --[[@as table]]
end

local function visualRef(path)
  return { image = path, width = 32, height = 32, anchorX = 0, anchorY = 0 }
end

-- Synthetic companion catalog with one rematch trainer, validated through
-- the real asset schema so the journey borrows only genuine references.
---@return table
local function fixtureManifest()
  return {
    schema = "g4-pokegear-assets-v3",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png") },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png") },
    phone = { panel = visualRef("assets/generated/pokegear/phone-panel.png") },
    map = { base = visualRef("assets/generated/pokegear/map-base.png") },
    fly = { base = visualRef("assets/generated/pokegear/fly-base.png") },
    radio = { dial = visualRef("assets/generated/pokegear/radio-dial.png") },
    catalog = {
      contacts = {
        {
          key = "custom.native-rematch",
          family = "trainer",
          trainerId = 20,
          sortWeight = 10,
          rematchWeekday = 6,
          rematchTime = 1,
        },
      },
      contactOrder = { "custom.native-rematch" },
      callDefinitions = {},
      callTriggers = {},
      rematches = {},
      rematchSets = {
        [20] = { group = 47, trainers = { 20, 20, 712, 0, 0, 0 } },
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

-- An existing seeking record and native trainer progression drive one
-- query, marker and trainer identity, regardless of the offer window.
function T.tests.saved_rematch_readiness_uses_native_trainer_availability()
  local PhoneCall = requireFeature(
    "game.hgss.src.pokegear.PhoneCall",
    "phone calls have no foreground session owner yet: invitations, readiness queries, and launched trainer tiers cannot agree"
  )
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")

  local state = PokegearState.new({ seed = 2024 }, { catalog = record.catalog })
  state:registerContact("custom.native-rematch")

  state:setRematch("custom.native-rematch", { stage = 1, wins = 2 })
  local world = {
    canCall = function()
      return true
    end,
    nativeSelectorFacts = function()
      return { localMap = false }
    end,
    rematchFacts = function()
      return { weekday = 0, timeOfDay = 0 }
    end,
    trainerDefeated = function(_, trainerId)
      return trainerId == 20
    end,
    rematchGroupUnlocked = function(_, tier)
      return tier == 2
    end,
    queryRematch = function(_, contact)
      return state:queryRematch(contact)
    end,
    setRematch = function(_, contact, entry)
      state:setRematch(contact, entry)
    end,
  }
  local random = PokegearRandom.new(2024)
  local audio = {
    isEffectWaitComplete = function()
      return true
    end,
  }
  local call = PhoneCall.new({
    state = state,
    catalog = record.catalog,
    messages = { invitation = "custom.invitation", accept = "custom.accept" },
    world = world,
    audio = audio,
    random = random,
  })

  -- The field query and map marker read one saved record and live window.
  local query = call:queryRematch("custom.native-rematch")
  Assert.equal(query.ready, true, "the first undefeated unlocked native trainer is ready outside the offer window")
  Assert.equal(query.trainerId, 712, "the field query returns the source trainer identity")
  local marker = call:rematchMarker("custom.native-rematch")
  Assert.equal(marker.ready, query.ready, "the map marker reads the same native readiness")
  Assert.equal(marker.trainerId, query.trainerId, "the map marker preserves native trainer identity")
  Assert.equal(call:launchRematch("custom.native-rematch"), 712, "launch resolves only the native trainer identity")
  Assert.deepEqual(
    state:queryRematch("custom.native-rematch"),
    { stage = 1, wins = 2 },
    "a readiness query and trainer resolution preserve saved seeking"
  )
end

-- A registered trainer without an invitation is never ready: neither
-- registration nor an unplayed challenge stages readiness, the field
-- query and the marker agree on that, and launching without readiness
-- fails instead of inventing a team.
function T.tests.registered_trainer_without_an_invitation_is_never_ready()
  local PhoneCall = requireFeature(
    "game.hgss.src.pokegear.PhoneCall",
    "phone calls have no foreground session owner yet: invitations, readiness queries, and launched trainer tiers cannot agree"
  )
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")

  local state = PokegearState.new({ seed = 3031 }, { catalog = record.catalog })
  state:registerContact("custom.native-rematch")
  local world = {
    queryRematch = function(_, contact)
      return state:queryRematch(contact)
    end,
    rematchFacts = function()
      return { weekday = 6, timeOfDay = 1 }
    end,
  }
  local call = PhoneCall.new({
    state = state,
    catalog = record.catalog,
    messages = { invitation = "custom.invitation", accept = "custom.accept" },
    world = world,
    audio = {
      isEffectWaitComplete = function()
        return true
      end,
    },
    random = PokegearRandom.new(3031),
  })

  local query = call:queryRematch("custom.native-rematch")
  Assert.equal(query.ready, false, "registration without an invitation never reports ready")
  Assert.isNil(query.tier, "the query never guesses a story tier")
  local marker = call:rematchMarker("custom.native-rematch")
  Assert.equal(marker.ready, false, "the marker agrees that no invitation waits")
  Assert.isNil(marker.tier, "the marker carries no invented tier")
  Assert.throws(function()
    call:launchRematch("custom.native-rematch")
  end, "launching without readiness never invents a team")
end

-- Passing rematch as call intent does not stage seeking by itself; only
-- an executed source program can publish an invitation.
function T.tests.unsourced_phone_call_does_not_stage_a_rematch()
  local PhoneCall = requireFeature(
    "game.hgss.src.pokegear.PhoneCall",
    "phone calls have no foreground session owner yet: invitations, readiness queries, and launched trainer tiers cannot agree"
  )
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")

  local state = PokegearState.new({ seed = 3032 }, { catalog = record.catalog })
  state:registerContact("custom.native-rematch")
  local world = {
    canCall = function()
      return true
    end,
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
      resolveLine = function()
        return { tokens = { { kind = "glyph", code = 1, text = "X", raw = { 1 } } } }
      end,
      resolveContactEntry = function()
        return { tokens = { { kind = "glyph", code = 1, text = "X", raw = { 1 } } } }
      end,
    },
    world = world,
    audio = {
      isEffectWaitComplete = function()
        return true
      end,
    },
    random = PokegearRandom.new(3032),
  })
  local handle = call:begin({
    id = "rematch-full-party",
    contact = "custom.native-rematch",
    direction = "outgoing",
    kind = "rematch",
  })
  Assert.isNil(call:result(handle), "the unadvanced call has not completed or published an invitation")
  Assert.isNil(state:queryRematch("custom.native-rematch"), "the phone program does not fabricate an invitation")
  Assert.isFalse(call:queryRematch("custom.native-rematch").ready, "an unsourced contact is not ready")
  local failure = Assert.throws(function()
    call:launchRematch("custom.native-rematch")
  end, "an unsourced challenge cannot launch")
  Assert.equal(
    failure.code,
    require("libs.script.src.errors").FEATURE_UNAVAILABLE,
    "the unsupported launch is attributed"
  )
  call:release(handle)
end

return T
