-- Durable phone rematches use PokegearState and native contact windows.
-- The current generated catalog has no contact-to-team mapping, so launch
-- stays attributed and leaves saved progress unchanged.

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
    schema = "g4-pokegear-assets-v1",
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
          key = "custom.leader-falkner",
          family = "gym",
          sortWeight = 10,
          rematchWeekday = 6,
          rematchTime = 1,
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
      reception = {},
      shows = {},
      radioEffects = {},
    },
    text = {},
    sequences = {},
  }
end

-- An existing save record and the native contact window drive one query
-- and marker. Launch is refused before any battle or record mutation when
-- source data cannot resolve the trainer team.
function T.tests.saved_rematch_window_is_shared_by_query_and_marker_without_fake_team()
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
  state:registerContact("custom.leader-falkner")

  state:setRematch("custom.leader-falkner", { stage = 1, wins = 2 })
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
  local query = call:queryRematch("custom.leader-falkner")
  Assert.equal(query.ready, true, "the field query reports ready inside the eligibility window")
  Assert.isNil(query.tier, "the query does not guess a story tier")
  local marker = call:rematchMarker("custom.leader-falkner")
  Assert.equal(marker.ready, query.ready, "the map marker reads the same durable readiness")
  local before = state:queryRematch("custom.leader-falkner")
  local failure = Assert.throws(function()
    call:launchRematch("custom.leader-falkner")
  end, "launching without a source-backed mapping fails")
  Assert.equal(failure.code, require("libs.script.src.errors").FEATURE_UNAVAILABLE, "the missing team is attributed")
  Assert.deepEqual(state:queryRematch("custom.leader-falkner"), before, "unsupported launch preserves saved progress")
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
  state:registerContact("custom.leader-falkner")
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

  local query = call:queryRematch("custom.leader-falkner")
  Assert.equal(query.ready, false, "registration without an invitation never reports ready")
  Assert.isNil(query.tier, "the query never guesses a story tier")
  local marker = call:rematchMarker("custom.leader-falkner")
  Assert.equal(marker.ready, false, "the marker agrees that no invitation waits")
  Assert.isNil(marker.tier, "the marker carries no invented tier")
  Assert.throws(function()
    call:launchRematch("custom.leader-falkner")
  end, "launching without readiness never invents a team")
end

-- Calling a rematch-shaped contact does not invent readiness when no
-- generated source stage authorizes an invitation.
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
  state:registerContact("custom.leader-falkner")
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
    messages = { invitation = "custom.invitation", accept = "custom.accept" },
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
    contact = "custom.leader-falkner",
    direction = "outgoing",
    kind = "rematch",
  })
  call:step(handle, {})
  call:step(handle, {})
  Assert.isNil(state:queryRematch("custom.leader-falkner"), "the phone program does not fabricate an invitation")
  Assert.isFalse(call:queryRematch("custom.leader-falkner").ready, "an unsourced contact is not ready")
  local failure = Assert.throws(function()
    call:launchRematch("custom.leader-falkner")
  end, "an unsourced challenge cannot launch")
  Assert.equal(
    failure.code,
    require("libs.script.src.errors").FEATURE_UNAVAILABLE,
    "the unsupported launch is attributed"
  )
end

return T
