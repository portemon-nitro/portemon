-- Flower Gift changes the user's live damage facts only while sun is active.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = { tests = {} }
local FORMAT = "test:flower-gift-format"

local function content()
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
  local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
  local assets = ContentBuilder.new()
  NativeTypeChart.install(assets, "flower-gift-session-tests")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(Executor.RULESET, { key = Executor.RULESET, chart = Executor.RULESET }, "tests")
  behaviors:registerFormat(FORMAT, { key = FORMAT }, "tests")
  return BattleContent.new(assets:freeze(), behaviors:freeze())
end

local function combatant(id, seed, ability, moves)
  local entry = { id = id, mon = SessionFixture.makeMon(seed, { level = 50 }) }
  entry.mon.ability = ability
  entry.mon.moves = moves
  return entry
end

local function scenario(placement)
  local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
  local selfCase = placement == "self" or placement == "self-baseline"
  local allyCase = placement == "ally" or placement == "ally-baseline"
  local userMoves = selfCase and { { move = "SUNNY_DAY", pp = 5, ppUps = 0 }, { move = "TACKLE", pp = 35, ppUps = 0 } }
    or { { move = "TACKLE", pp = 35, ppUps = 0 } }
  local user = combatant(1, 11, placement == "self" and "FLOWER_GIFT" or "NONE", userMoves)
  local ally = combatant(3, 31, placement == "ally" and "FLOWER_GIFT" or "NONE", {
    { move = "SUNNY_DAY", pp = 5, ppUps = 0 },
  })
  local foe = combatant(2, 23, "NONE", { { move = "TACKLE", pp = 35, ppUps = 0 } })
  local foeAlly = combatant(4, 41, "NONE", { { move = "TACKLE", pp = 35, ppUps = 0 } })
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local speciesFacts = {}
  local seeds = allyCase and { user, ally, foe, foeAlly } or { user, foe }
  for _, entry in ipairs(seeds) do
    local mon = entry.mon
    local species = mon.species
    local form = mon.form
    local formFacts = catalog:form(species, form)
    local speciesFactsForMon = catalog:species(species)
    speciesFacts[species] = speciesFacts[species] or {}
    speciesFacts[species][form] = {
      baseStats = formFacts.baseStats,
      growthCurve = catalog:growthCurve(speciesFactsForMon.growthCurve),
      types = formFacts.types,
      levelUpMoves = formFacts.levelUpMoves,
      baseExpYield = speciesFactsForMon.baseExpYield,
      evYield = speciesFactsForMon.evYield,
    }
  end
  local moveFacts = {}
  moveFacts.TACKLE = {}
  for key, value in pairs(catalog:move("TACKLE")) do
    if key ~= "flags" then
      moveFacts.TACKLE[key] = value
    end
  end
  moveFacts.TACKLE.flags = {}
  moveFacts.SUNNY_DAY = {
    power = 0,
    accuracy = 0,
    category = "other",
    moveType = "fire",
    effectChance = 0,
    priority = 0,
    target = "user",
    flags = {},
  }
  return {
    ruleset = Executor.RULESET,
    format = FORMAT,
    sides = allyCase and { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) }
      or { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", allyCase and { user, ally } or { user }),
      SessionFixture.participant(2, 2, "beta", allyCase and { foe, foeAlly } or { foe }),
    },
    positions = allyCase and {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(3, 1, { 1 }, 3),
      SessionFixture.position(2, 2, { 2 }, 2),
      SessionFixture.position(4, 2, { 2 }, 4),
    } or {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = 0x1BADB002 },
    formatState = {},
    speciesFacts = speciesFacts,
    moveFacts = moveFacts,
  }
end

local function run(placement)
  local selfCase = placement == "self" or placement == "self-baseline"
  local contracts = SessionFixture.sessionContracts()
  local session = contracts.Battle.newSession(scenario(placement), content())
  local collected = {}
  for _ = 1, 256 do
    local frame = session:advance(64)
    for _, event in ipairs(frame.events or {}) do
      collected[#collected + 1] = event
      if type(event.cause) == "table" and event.cause.key == "TACKLE" then
        local payload = event.payload
        if type(payload) == "table" and payload.target == 2 then
          local sunnyDaySeen = false
          for _, observed in ipairs(collected) do
            if type(observed.cause) == "table" and observed.cause.key == "SUNNY_DAY" then
              sunnyDaySeen = true
            end
          end
          if sunnyDaySeen then
            session:dispose()
            return collected
          end
        end
      end
    end
    if frame.status == "ended" then
      session:dispose()
      return collected
    end
    Assert.equal(frame.status, "waiting", "the native session waits for move choices")
    for _, request in ipairs(frame.request.requests) do
      local choices = {}
      for _, actor in ipairs(request.actors) do
        if request.controller == "alpha" then
          local actorId = type(actor) == "number" and actor or actor.combatant
          local moveSlot = selfCase and actorId == 1 and 1 or 0
          if selfCase and actorId == 1 then
            local sunnyDayUsed = false
            for _, event in ipairs(collected) do
              if type(event.cause) == "table" and event.cause.key == "SUNNY_DAY" then
                sunnyDayUsed = true
              end
            end
            moveSlot = sunnyDayUsed and 1 or 0
          end
          choices[#choices + 1] = SessionFixture.attackChoice(actor, moveSlot, SessionFixture.positionTarget(2))
        else
          choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(1))
        end
      end
      Assert.isTrue(session:submit(SessionFixture.replyFor(request, choices)), "the native move choice is accepted")
    end
  end
  error("the Flower Gift native battle did not settle")
end

local function sunnyTackleDamage(events)
  local damage = nil
  local sunnyDaySeen = false
  local observed = {}
  for _, event in ipairs(events) do
    local cause = event.cause
    observed[#observed + 1] = event.kind .. ":" .. tostring(type(cause) == "table" and cause.key or "")
    if type(cause) == "table" and cause.key == "SUNNY_DAY" then
      sunnyDaySeen = true
    elseif event.kind == "struck" then
      local cause = event.cause --[[@as table<string, unknown>]]
      local payload = event.payload --[[@as table<string, unknown>]]
      if sunnyDaySeen and cause.key == "TACKLE" and payload.target == 2 then
        damage = payload.damage --[[@as integer]]
        break
      end
    end
  end
  Assert.notNil(damage, "the live session records the user's Sunny Day Tackle: " .. table.concat(observed, ","))
  return damage --[[@as integer]]
end

function T.tests.flower_gift_boosts_its_holder_in_a_live_sunny_session()
  local baseline = sunnyTackleDamage(run("self-baseline"))
  local gifted = sunnyTackleDamage(run("self"))
  Assert.isTrue(gifted > baseline, "live Flower Gift boosts the holder's physical Attack in sun")
end

function T.tests.flower_gift_boosts_its_ally_in_a_live_sunny_session()
  local baseline = sunnyTackleDamage(run("ally-baseline"))
  local gifted = sunnyTackleDamage(run("ally"))
  Assert.isTrue(
    gifted > baseline,
    "live Flower Gift boosts an ally's physical Attack in sun: " .. gifted .. " vs " .. baseline
  )
end

return T
