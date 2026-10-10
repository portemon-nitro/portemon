-- Phone rematch agreement through representative field ownership: the phone
-- invitation, the field readiness query, the map marker, and the launched
-- trainer team all report the same tier, and only a source-qualified
-- completion clears or advances readiness. Wins clear the invitation, losses
-- and cancellations preserve it, unregistered trainers stay unreadied, and a
-- full party or blackout never completes a rematch spuriously. World owners
-- are real-shaped injected fixtures; only the host audio boundary is
-- stubbed. No ROM data is required.

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
        { key = "custom.leader-falkner", family = "gym", sortWeight = 10 },
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

-- A phone invitation, its field readiness query, its map marker, and its
-- launched trainer team agree on one tier: the query reports ready inside
-- the source weekday window, the launched team carries the queried tier, a
-- win clears readiness while a loss or cancellation preserves it, and an
-- unregistered trainer is never ready.
function T.tests.invited_rematch_query_marker_and_trainer_team_agree_on_one_tier()
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

  -- Real-shaped world fixture: story tier, weekday clock inside the source
  -- eligibility window, and a trainer team owner keyed by tier.
  local world = {
    storyTier = 2,
    weekday = "saturday",
    morning = true,
    teamsByTier = {
      [2] = { tier = 2, members = { { species = "custom.pidgeotto", level = 13 } } },
    },
    launchedTier = nil,
    fieldFlags = {},
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

  -- The outgoing invitation stages readiness at its source step.
  local handle = call:begin({
    id = "rematch-1",
    contact = "custom.leader-falkner",
    direction = "outgoing",
    kind = "rematch",
  })
  call:step(handle, {})
  call:step(handle, {})
  local invitation = call:result(handle)
  Assert.notNil(invitation, "the accepted invitation reports a result")
  Assert.equal(invitation.ready, true, "the invitation stages readiness")

  -- The field query, the map marker, and the launched team agree with the
  -- invitation on a single tier.
  local query = call:queryRematch("custom.leader-falkner")
  Assert.equal(query.ready, true, "the field query reports ready inside the eligibility window")
  Assert.equal(query.tier, 2, "the query reports the story tier")
  local marker = call:rematchMarker("custom.leader-falkner")
  Assert.equal(marker.tier, query.tier, "the map marker projects the queried tier")
  local launched = call:launchRematch("custom.leader-falkner", world)
  Assert.equal(launched.tier, query.tier, "the launched trainer carries the queried tier")
  Assert.deepEqual(launched.team, world.teamsByTier[2], "the launched team is the tier-two team")

  -- A win clears readiness; the next query is no longer ready.
  call:resolveRematch("custom.leader-falkner", "win")
  local afterWin = call:queryRematch("custom.leader-falkner")
  Assert.equal(afterWin.ready, false, "only a source-qualified win clears readiness")

  -- A fresh invitation followed by a loss or a cancellation preserves
  -- readiness for another attempt.
  local second = call:begin({
    id = "rematch-2",
    contact = "custom.leader-falkner",
    direction = "outgoing",
    kind = "rematch",
  })
  call:step(second, {})
  call:step(second, {})
  call:resolveRematch("custom.leader-falkner", "loss")
  Assert.equal(
    call:queryRematch("custom.leader-falkner").ready,
    true,
    "a loss preserves the staged readiness"
  )
  call:resolveRematch("custom.leader-falkner", "cancel")
  Assert.equal(
    call:queryRematch("custom.leader-falkner").ready,
    true,
    "a cancellation preserves the staged readiness"
  )

  -- An unregistered trainer is never rematch-ready, and a blackout never
  -- completes a rematch spuriously.
  Assert.equal(
    call:queryRematch("custom.unregistered").ready,
    false,
    "an unregistered trainer reports no readiness"
  )
  call:resolveRematch("custom.leader-falkner", "blackout")
  Assert.equal(
    call:queryRematch("custom.leader-falkner").ready,
    true,
    "a blackout leaves the staged readiness untouched"
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
  state:registerContact("custom.leader-falkner")
  local world = {
    storyTier = 2,
    weekday = "saturday",
    morning = true,
    teamsByTier = {
      [2] = { tier = 2, members = { { species = "custom.pidgeotto", level = 13 } } },
    },
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
  Assert.equal(query.tier, 2, "the query still reports the story tier")
  local marker = call:rematchMarker("custom.leader-falkner")
  Assert.equal(marker.ready, false, "the marker agrees that no invitation waits")
  Assert.equal(marker.tier, query.tier, "the marker projects the queried tier")
  Assert.throws(function()
    call:launchRematch("custom.leader-falkner", world)
  end, "launching without readiness never invents a team")
end

-- A full party never completes a staged rematch: the interruption
-- preserves the invitation for another attempt exactly like a loss,
-- a cancellation, or a blackout.
function T.tests.full_party_never_completes_a_staged_rematch()
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
    storyTier = 2,
    weekday = "saturday",
    morning = true,
    teamsByTier = {
      [2] = { tier = 2, members = { { species = "custom.pidgeotto", level = 13 } } },
    },
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
  Assert.equal(
    call:queryRematch("custom.leader-falkner").ready,
    true,
    "the invitation stages readiness"
  )
  call:resolveRematch("custom.leader-falkner", "full-party")
  Assert.equal(
    call:queryRematch("custom.leader-falkner").ready,
    true,
    "a full party preserves the staged readiness"
  )
end

return T
