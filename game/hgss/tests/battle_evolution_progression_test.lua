-- Frozen evolution acceptance: post-battle evolution must pair the native
-- evolution presentation with the existing evolution domain, and its result
-- must publish atomically exactly once. Eligibility and transformation stay
-- with the domain owner: an ineligible subject plans nothing and keeps its
-- input untouched, while the visual sequence, permitted cancel policy, and
-- multi-result branches belong to the battle side.
--
-- Dependency note: the shared eligibility entry point, the battle
-- evolution presentation state, and the battle child composition module are
-- all missing, so success, permitted cancel, appearance variants, and the
-- two-result branch have no owner yet. The red tests pin those misses. The
-- atomic multi-owner publication itself stays with the completion owner
-- covered by the failure-isolation suite.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Evolution = require("libs.mons.src.gen4.Evolution")

local COMPOSER_MODULE = "game.hgss.src.battle.BattleChildApplications"
local EVOLUTION_STATE_MODULE = "game.hgss.src.battle.BattleEvolutionState"

local T = {}

---@return table<string, unknown> subject with no eligible evolution slot
local function plainEevee()
  return {
    species = "EEVEE",
    form = 0,
    personality = 0,
    experience = 1000,
    moves = {},
  }
end

function T.ineligible_subjects_plan_nothing_and_keep_their_input()
  local catalog = CatalogFixture.makeCatalog()
  Assert.isTrue(type(Evolution.check) == "function", "setup: the domain owns eligibility checks")
  Assert.isTrue(type(Evolution.plan) == "function", "setup: the domain owns transformation planning")
  local before = plainEevee()
  local slot = Evolution.check(before, { trigger = { kind = "trade" } }, catalog)
  Assert.isNil(slot, "a subject with no eligible slot matches nothing")
  Assert.isNil(Evolution.plan(before, { trigger = { kind = "trade" } }, catalog), "planning stages nothing either")
  Assert.deepEqual(before, plainEevee(), "eligibility and planning never mutate their input")
end

function T.evolution_eligibility_and_application_share_one_domain_entry_point()
  Assert.isTrue(
    type(Evolution.candidates) == "function",
    "the domain exposes ordered evolution candidates for the visual state"
  )
  Assert.isTrue(
    type(Evolution.apply) == "function",
    "the domain exposes the single transformation application for the selected candidate"
  )
end

function T.postbattle_evolution_runs_through_its_native_presentation_state()
  local ok, state = pcall(require, EVOLUTION_STATE_MODULE)
  Assert.isTrue(ok, "the native evolution sequence owns its presentation state (" .. EVOLUTION_STATE_MODULE .. ")")
  assert(state ~= nil, "the evolution state loads")
end

function T.evolution_visuals_compose_through_the_battle_child_composer()
  local ok, composer = pcall(require, COMPOSER_MODULE)
  Assert.isTrue(ok, "evolution visuals compose through the battle child module (" .. COMPOSER_MODULE .. ")")
  assert(composer ~= nil, "the composer loads")
end

function T.soulsilver_variant_stays_blocked_without_its_owned_cache(context)
  local GameVersion = require("romdump.src.source.GameVersion")
  local RomImporter = require("romdump.src.source.RomImporter")
  local known = false
  for _, versionId in ipairs(GameVersion.ORDER) do
    if versionId == "soulsilver" then
      known = true
    end
  end
  Assert.isTrue(known, "setup: the second version is a known parity dimension")
  if not RomImporter.isReady("soulsilver") then
    context:skip(
      "BLOCKED: no ready soulsilver user-owned ROM cache in this checkout; second-version evolution parity is unverified"
    )
  end
  Assert.isTrue(
    false,
    "a ready soulsilver cache appeared: this probe must grow a real second-version comparison before it may pass"
  )
end

return { tests = T }
