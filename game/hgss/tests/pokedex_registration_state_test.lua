-- First-catch registration presentation through the battle-owned child:
-- the announcement holds its explicit post-text wait while the default
-- cue keeps its short hold, the child runs the source phase sequence on
-- a thirty-hertz clock with separate fades, a once-only cry, and fresh
-- dismissal input, and every failure or disposal path releases its
-- borrowed lease exactly once. The real battle timeline drives the
-- announcement clock; preparation and audio stay recording doubles. No
-- renderer, GPU, ROM, or save is involved.

local Assert = require("tests.support.Assert")
local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")
local FakeGraphics = require("tests.support.FakeGraphics")
local Fixture = require("tests.support.PokedexPresentationFixture")

local CHILD_MODULE = "game.hgss.src.pokedex.PokedexRegistrationState"

local T = {}

local TICK = 1 / 60

---@param behavior string missing child behavior under test
---@return table the loaded battle-owned registration state
local function requirePresent(behavior)
  local ok, loaded = pcall(require, CHILD_MODULE)
  Assert.isTrue(ok, "missing battle-owned first-catch presentation: " .. behavior .. " (" .. CHILD_MODULE .. ")")
  assert(loaded ~= nil, "the registration child module loads")
  return loaded --[[@as table]]
end

---@param timeline table cue player under test driving
---@param ticks integer internal ticks to advance
local function advanceTimeline(timeline, ticks)
  for _ = 1, ticks do
    timeline:update(TICK, function(_)
      return true
    end)
  end
end

---@param text string announcement wording under test driving
---@param hold integer? explicit post-text hold under test driving
---@return integer? ticks from announcement until the cue settles
local function settleTicks(text, hold)
  local timeline = BattleTimeline.new({ textSpeed = "fastest" })
  if hold == nil then
    timeline:announce(text, false)
  else
    timeline:announce(text, false, hold)
  end
  for tick = 1, 500 do
    advanceTimeline(timeline, 1)
    if timeline:settled() then
      return tick
    end
  end
  return nil
end

-- The explicit post-text hold lasts sixty internal ticks while an
-- identical default announcement keeps its short hold: the override
-- reproduces the source thirty-update wait without changing ordinary
-- narration.
function T.explicit_announcement_hold_uses_sixty_internal_ticks()
  local defaultTicks = settleTicks("X", nil)
  local overrideTicks = settleTicks("X", 60)
  Assert.notNil(defaultTicks, "the default announcement settles")
  Assert.notNil(overrideTicks, "the explicit-hold announcement settles")
  Assert.isTrue(defaultTicks <= 40, "the default announcement keeps its short post-text wait")
  Assert.equal(
    overrideTicks - defaultTicks,
    48,
    "an explicit sixty-tick hold extends the identical announcement by the source thirty updates"
  )
end

-- An acknowledgment edge arriving during the explicit hold is consumed
-- without touching the timer: it neither shortens the wait to the
-- default nor restarts it.
function T.acknowledgment_during_explicit_hold_never_resets_the_timer()
  local timeline = BattleTimeline.new({ textSpeed = "fastest" })
  timeline:announce("X", false, 60)
  advanceTimeline(timeline, 32)
  timeline:ack()
  advanceTimeline(timeline, 20)
  Assert.isFalse(
    timeline:settled(),
    "an edge during the explicit hold consumes without resetting it to the default"
  )
  advanceTimeline(timeline, 60)
  Assert.isTrue(timeline:settled(), "the explicit hold still completes after its full wait")
end

---@param script string[] preparation outcomes the fake lease serves in order
---@return table fake borrowed presentation owner with counts and demands
local function newPokedexFake(script)
  local releases = 0
  local demands = {}
  local rendererCalls = 0
  local fake = { releases = function()
    return releases
  end, demands = demands }
  local lease = {}
  function lease:prepare(demand)
    demands[#demands + 1] = demand
    local step = script[math.min(#demands, #script)] or script[#script]
    if step == "failed" then
      return { kind = "failed", error = "synthetic demand failure" }
    end
    if step == "ready" then
      return {
        kind = "ready",
        key = demand.key,
        assets = {
          messages = { registrationAnnouncement = "GOTCHA " .. tostring(demand.text.registration.displayName) },
          renderer = {
            drawRegistration = function(_prepared, _plan)
              rendererCalls = rendererCalls + 1
            end,
          },
          animations = {},
          chrome = {},
          pictures = {},
          icons = {},
        },
      }
    end
    return { kind = "pending" }
  end
  function lease:release()
    releases = releases + 1
  end
  function fake:acquire(_options)
    return lease
  end
  function fake:rendererCalls()
    return rendererCalls
  end
  return fake
end

---@return table audio double with controllable cry completion
local function newAudioFake()
  local audio = { calls = {}, cryDone = false }
  function audio.playCry(species, pattern, form)
    audio.calls[#audio.calls + 1] = { species = species, pattern = pattern, form = form }
    return true
  end
  function audio.isCryFinished()
    return audio.cryDone
  end
  function audio.select()
  end
  return audio
end

---@return table detached frozen first-catch facts for the child
local function frozenRegistration()
  local monCatalog, catalog = Fixture.catalogs()
  local dexOwner = Fixture.ownerWithHistory(monCatalog, catalog)
  local DexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
  local specimen = dexOwner:describe(DexFixture.makeMon(monCatalog, { species = "TOTODILE", personality = 12345 }))
  return {
    captureId = 7,
    mode = "wild",
    dexMode = "national",
    displayName = specimen.species,
    specimen = specimen,
  }
end

---@return table<string, unknown> measured display facts backing the child session
local function dualMeasurement()
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  return {
    width = 512,
    height = 384,
    topology = ScreenTopology.dualDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      touch = true,
      role = "world",
    }, {
      id = "lower",
      rect = { x = 0, y = 192, width = 256, height = 192 },
      touch = true,
      role = "auxiliary",
    }),
    pixelRatio = 1,
    signature = "registration-child-test:dual",
  }
end

---@param Child table child class under test driving
---@param registration table frozen first-catch facts under test driving
---@param pokedex table fake borrowed presentation owner under test driving
---@param audio table fake registration audio under test driving
---@param measure function display measurement under test driving
---@return table live child under test driving
---@return table borrowed timeline the test pumps as the parent
local function newChild(Child, registration, pokedex, audio, measure)
  local timeline = BattleTimeline.new({ textSpeed = "fastest" })
  local child = Child.new({
    registration = registration,
    pokedex = pokedex,
    timeline = timeline,
    audio = audio,
    measureDisplay = measure or dualMeasurement,
  })
  return child, timeline
end

---@param child table live child under test driving
---@param timeline table borrowed timeline the test pumps as the parent
---@param iterations integer update budget under test driving
---@return boolean completed true once the child reports completion
local function pump(child, timeline, iterations)
  for _ = 1, iterations do
    timeline:update(TICK, function(_)
      return true
    end)
    child:updateFixed(1 / 30)
    if child:status().complete == true then
      return true
    end
  end
  return child:status().complete == true
end

---@param child table live child under test driving
---@param timeline table borrowed timeline the test pumps as the parent
---@param iterations integer update budget under test driving
---@return boolean dismissed true once the child accepts dismissal
local function driveToDismissal(child, timeline, iterations)
  for _ = 1, iterations do
    timeline:update(TICK, function(_)
      return true
    end)
    child:updateFixed(1 / 30)
    if child:status().acceptsDismissal == true then
      return true
    end
    if child:status().complete == true then
      return false
    end
  end
  return child:status().acceptsDismissal == true
end

---@param demands table[] recorded immutable demands under inspection
---@param registration table frozen first-catch facts under inspection
local function checkLockedDemand(demands, registration)
  Assert.isTrue(#demands >= 1, "the child prepares its card through the borrowed lease")
  local firstKey = assert(demands[1].key, "the demand carries its stable generation key")
  Assert.isTrue(type(firstKey) == "string" and firstKey ~= "", "the generation key is a nonempty string")
  for _, demand in ipairs(demands) do
    Assert.equal(demand.key, firstKey, "one capture keeps one demand generation across updates")
    Assert.equal(demand.purpose, "registration", "the demand names the registration purpose")
    Assert.equal(demand.pageRole, "registration", "the demand names the registration page role")
    Assert.equal(demand.dexMode, registration.dexMode, "the demand freezes the eligibility number mode")
    Assert.equal(demand.language, "native", "card text uses the selected game language")
    Assert.deepEqual(demand.iconKeys, {}, "the registration demand carries no icon keys")
    Assert.equal(#demand.pictures, 1, "the demand carries exactly the captured picture")
    local picture = demand.pictures[1]
    Assert.equal(picture.slot, "registration", "the picture fills the registration slot")
    Assert.equal(picture.facing, "front", "the card shows the captured front")
    Assert.equal(picture.mode, "registration", "the picture uses the registration mode")
    Assert.deepEqual(picture.specimen, registration.specimen, "the picture freezes the actual specimen")
    Assert.deepEqual(demand.text.registration, registration, "the demand text freezes the terminal facts")
    Assert.equal(demand.profile, "base", "a non-Giratina capture measures on the base profile")
    Assert.deepEqual(demand.text.slots, {
      { role = "registration.dex-number", kind = "dex_number", species = registration.specimen.species },
      {
        role = "registration.species-name",
        kind = "species_name",
        species = registration.specimen.species,
        language = "native",
      },
      {
        role = "registration.category",
        kind = "category",
        species = registration.specimen.species,
        language = "native",
      },
      {
        role = "registration.flavor",
        kind = "flavor",
        species = registration.specimen.species,
        language = "native",
      },
      { role = "registration.height", kind = "height", species = registration.specimen.species },
      { role = "registration.weight", kind = "weight", species = registration.specimen.species },
    }, "the demand publishes the caught specimen's card text slots")
    Assert.equal(demand.cry.species, registration.specimen.species, "the cry names the captured species")
    Assert.equal(demand.cry.form, 0, "the cry always uses the base form")
  end
end

-- The child runs its source phase sequence on accepted thirty-hertz
-- quanta: preparation gates the announcement, the real borrowed timeline
-- carries the sixty-tick wait, the cry plays once with its fixed
-- pattern only after the entry fades, and completion freezes a drawable
-- final view while keeping the lease until disposal.
function T.registration_child_runs_source_phases_on_a_thirty_hz_clock()
  local Child = requirePresent("one complete battle-owned registration sequence")
  local registration = frozenRegistration()
  local pokedex = newPokedexFake({ "pending", "pending", "ready" })
  local audio = newAudioFake()
  local child, timeline = newChild(Child, registration, pokedex, audio)
  Assert.isTrue(child:status().complete == false, "the child starts incomplete")
  Assert.isNil(child:status().error, "the child starts without error")

  child:updateFixed(1 / 30)
  child:updateFixed(1 / 30)
  Assert.isTrue(child:status().complete == false, "pending preparation never completes the card")
  Assert.equal(#audio.calls, 0, "no cry plays before whole-demand readiness")
  checkLockedDemand(pokedex.demands, registration)

  -- Accepted child time never advances the announcement on its own: only
  -- parent timeline ticks settle the borrowed clock.
  for _ = 1, 200 do
    child:updateFixed(1 / 30)
  end
  Assert.isTrue(child:status().complete == false, "child quanta alone never settle the parent clock")
  for _ = 1, 50 do
    child:updateFixed(0)
  end
  Assert.isTrue(child:status().complete == false, "zero-duration updates never advance source time")
  Assert.equal(#audio.calls, 0, "no cry plays while the announcement is pending")

  -- An early confirmation edge is discarded: the announcement still needs
  -- its full borrowed wait before any later phase runs.
  child:input({ { type = "confirm" } })
  for _ = 1, 5 do
    timeline:update(TICK, function(_)
      return true
    end)
    child:updateFixed(1 / 30)
  end
  Assert.isTrue(child:status().complete == false, "a premature edge never skips the announcement")
  Assert.equal(#audio.calls, 0, "a premature edge never hurries the cry")

  -- The finished cry releases fresh dismissal without completing the card
  -- on its own: the ready card waits for a latched fresh edge.
  audio.cryDone = true
  Assert.isTrue(driveToDismissal(child, timeline, 1200), "the finished cry releases the ready card")
  Assert.isTrue(child:status().acceptsDismissal == true, "the ready card accepts fresh dismissal")
  Assert.isTrue(child:status().complete == false, "readiness alone never completes the card")
  Assert.equal(#audio.calls, 1, "the cry plays exactly once")
  Assert.equal(audio.calls[1].species, registration.specimen.species, "the cry names the captured species")
  Assert.equal(audio.calls[1].pattern, 14, "the card cry always uses its fixed pattern")
  Assert.equal(audio.calls[1].form, 0, "the card cry always uses the base form")
  Assert.equal(pokedex:releases(), 0, "the ready card keeps its lease until the existing parent boundary")
  Assert.equal(pokedex:rendererCalls(), 0, "headless status and view polling never draws")

  -- Even with the cry finished, the card never departs on its own: the
  -- banner timer is purely palette animation past timer32.
  for _ = 1, 100 do
    timeline:update(TICK, function(_)
      return true
    end)
    child:updateFixed(1 / 30)
  end
  Assert.isTrue(
    child:status().complete == false,
    "no banner timer departs the card without a fresh edge"
  )
  Assert.isTrue(
    child:status().acceptsDismissal == true,
    "the finished cry keeps the card dismissible across the banner cycle"
  )

  -- One fresh confirmation edge dismisses the ready card; the departure
  -- completes on the borrowed clock and freezes the final exit view.
  child:input({ { type = "confirm" } })
  Assert.isTrue(pump(child, timeline, 1200), "a fresh edge completes the dismissed card")
  Assert.isNil(child:status().error, "the dismissed sequence reports no error")
  Assert.isTrue(type(child:view()) == "table", "the completed child freezes its final exit view")
  Assert.equal(pokedex:releases(), 0, "completion keeps the lease until the existing parent boundary")
  child:draw({ graphics = FakeGraphics.new() })
  Assert.equal(pokedex:rendererCalls(), 1, "the frozen final exit view stays drawable")
  child:dispose()
  Assert.equal(pokedex:releases(), 1, "disposal releases the child lease exactly once")
  child:dispose()
  Assert.equal(pokedex:releases(), 1, "repeated disposal never releases twice")
end

-- Only fresh confirmation edges dismiss the ready card: cancellation
-- never dismisses, an early or held edge from before readiness never
-- carries across the boundary, and a layout change with cancelled
-- pointers still reaches the same single dismissal.
function T.only_fresh_confirm_edges_dismiss_the_ready_card()
  local Child = requirePresent("dismissal input across the card boundary")

  -- Cancellation at readiness is ignored; a fresh confirmation dismisses.
  do
    local registration = frozenRegistration()
    local pokedex = newPokedexFake({ "ready" })
    local audio = newAudioFake()
    audio.cryDone = true
    local child, timeline = newChild(Child, registration, pokedex, audio)
    Assert.isTrue(driveToDismissal(child, timeline, 1200), "the card becomes dismissible")
    child:input({ { type = "cancel" } })
    for _ = 1, 5 do
      timeline:update(TICK, function(_)
        return true
      end)
      child:updateFixed(1 / 30)
    end
    Assert.isTrue(child:status().complete == false, "cancellation never dismisses the card")
    Assert.isTrue(
      child:status().acceptsDismissal == true,
      "the ignored cancellation keeps the card dismissible"
    )
    child:input({ { type = "confirm" } })
    Assert.isTrue(pump(child, timeline, 1200), "a fresh confirmation dismisses the ready card")
    Assert.isNil(child:status().error, "the dismissed card reports no error")
    child:dispose()
    Assert.equal(pokedex:releases(), 1, "the dismissed child releases its lease once")
  end

  -- A confirmation from before readiness never carries across: the card
  -- still waits for a fresh edge after it becomes dismissible.
  do
    local registration = frozenRegistration()
    local pokedex = newPokedexFake({ "ready" })
    local audio = newAudioFake()
    audio.cryDone = true
    local child, timeline = newChild(Child, registration, pokedex, audio)
    for _ = 1, 3 do
      timeline:update(TICK, function(_)
        return true
      end)
      child:updateFixed(1 / 30)
    end
    Assert.isTrue(child:status().complete == false, "the card is still presenting")
    child:input({ { type = "confirm" } })
    Assert.isTrue(driveToDismissal(child, timeline, 1200), "the card still becomes dismissible")
    for _ = 1, 5 do
      timeline:update(TICK, function(_)
        return true
      end)
      child:updateFixed(1 / 30)
    end
    Assert.isTrue(
      child:status().complete == false,
      "the early edge never crosses the readiness boundary"
    )
    child:input({ { type = "confirm" } })
    Assert.isTrue(pump(child, timeline, 1200), "a fresh confirmation after readiness dismisses")
    child:dispose()
    Assert.equal(pokedex:releases(), 1, "the dismissed child releases its lease once")
  end

  -- Touch dismissal works, and a layout change with cancelled pointers
  -- still reaches the single touch dismissal.
  do
    local registration = frozenRegistration()
    local pokedex = newPokedexFake({ "ready" })
    local audio = newAudioFake()
    audio.cryDone = true
    local child, timeline = newChild(Child, registration, pokedex, audio)
    Assert.isTrue(driveToDismissal(child, timeline, 1200), "the card becomes dismissible")
    child:cancelPointerCapture()
    child:input({ { type = "touch_new", pointerId = 9 } })
    Assert.isTrue(pump(child, timeline, 1200), "a fresh touch dismisses the ready card")
    child:input({ { type = "confirm" } })
    Assert.isTrue(child:status().complete == true, "a repeated edge after completion is harmless")
    child:dispose()
    Assert.equal(pokedex:releases(), 1, "repeated input never releases twice")
  end
end

-- A slow cry holds the banner and the dismissal gate: palette animation
-- never advances while the cry is unfinished, fresh edges never dismiss
-- early, and the normal dismissal runs once the cry releases readiness.
function T.slow_cry_holds_the_banner_and_blocks_early_dismissal()
  local Child = requirePresent("cry-gated banner and dismissal")
  local registration = frozenRegistration()
  local pokedex = newPokedexFake({ "ready" })
  local audio = newAudioFake()
  local child, timeline = newChild(Child, registration, pokedex, audio)
  for _ = 1, 1200 do
    timeline:update(TICK, function(_)
      return true
    end)
    child:updateFixed(1 / 30)
    if #audio.calls >= 1 and child:status().phase == "readyCard" then
      break
    end
  end
  Assert.equal(#audio.calls, 1, "the cry plays once on the way to the ready card")
  Assert.equal(child:status().phase, "readyCard", "the slow cry still reaches the ready card")
  Assert.isTrue(child:status().complete == false, "the unfinished cry never completes the card")
  Assert.isTrue(
    child:status().acceptsDismissal == false,
    "the unfinished cry never releases dismissal"
  )
  child:input({ { type = "confirm" } })
  for _ = 1, 120 do
    timeline:update(TICK, function(_)
      return true
    end)
    child:updateFixed(1 / 30)
  end
  Assert.isTrue(child:status().complete == false, "a fresh edge never hurries the unfinished cry")
  Assert.isTrue(
    child:status().acceptsDismissal == false,
    "a fresh edge never releases dismissal early"
  )
  audio.cryDone = true
  Assert.isTrue(
    driveToDismissal(child, timeline, 1200),
    "the finished cry releases the ready card"
  )
  child:input({ { type = "confirm" } })
  Assert.isTrue(pump(child, timeline, 1200), "a fresh confirmation dismisses after the cry")
  Assert.isNil(child:status().error, "the cry-gated dismissal reports no error")
  child:dispose()
  Assert.equal(pokedex:releases(), 1, "the dismissed child releases its lease once")
end

-- Preparation, audio, and lifecycle failures never leak the borrowed
-- lease: the child latches one attributed error, disposal stays
-- exactly-once from any phase, and the borrowed timeline keeps working
-- for its parent.
function T.failure_and_disposal_release_the_child_lease_once()
  local Child = requirePresent("attributed failure and exactly-once teardown")

  -- A failed whole-demand preparation latches its cause and releases once.
  do
    local registration = frozenRegistration()
    local pokedex = newPokedexFake({ "failed" })
    local audio = newAudioFake()
    local child, timeline = newChild(Child, registration, pokedex, audio)
    for _ = 1, 10 do
      timeline:update(TICK, function(_)
        return true
      end)
      child:updateFixed(1 / 30)
    end
    Assert.isTrue(child:status().complete == false, "a failed preparation never completes")
    Assert.notNil(child:status().error, "the failed preparation latches its attributed cause")
    child:dispose()
    Assert.equal(pokedex:releases(), 1, "the failed child releases its lease once")
    child:dispose()
    Assert.equal(pokedex:releases(), 1, "repeated disposal after failure never releases twice")
  end

  -- A cry failure becomes the child error instead of a fake completion.
  do
    local registration = frozenRegistration()
    local pokedex = newPokedexFake({ "ready" })
    local audio = newAudioFake()
    function audio.playCry(species, pattern, form)
      audio.calls[#audio.calls + 1] = { species = species, pattern = pattern, form = form }
      error("synthetic cry failure")
    end
    local child, timeline = newChild(Child, registration, pokedex, audio)
    for _ = 1, 1200 do
      timeline:update(TICK, function(_)
        return true
      end)
      child:updateFixed(1 / 30)
      if child:status().error ~= nil or child:status().complete == true then
        break
      end
    end
    Assert.notNil(audio.calls[1], "the child attempts its once-only cry before failing")
    Assert.isTrue(child:status().complete == false, "a cry failure never fakes completion")
    Assert.notNil(child:status().error, "the cry failure latches its attributed cause")
    child:dispose()
    Assert.equal(pokedex:releases(), 1, "the cry-failed child releases its lease once")
  end

  -- Disposal from any phase releases once and never retires the
  -- borrowed parent clock: the orphan announcement drains through the
  -- same player instead of being withdrawn, preserving cue order.
  do
    local registration = frozenRegistration()
    local pokedex = newPokedexFake({ "pending", "pending", "ready" })
    local audio = newAudioFake()
    local child, timeline = newChild(Child, registration, pokedex, audio)
    child:dispose()
    Assert.equal(pokedex:releases(), 1, "disposal before readiness releases once")
    timeline:announce("later", false)
    advanceTimeline(timeline, 120)
    Assert.isTrue(timeline:settled(), "the borrowed timeline drains the later cue after child disposal")
    Assert.equal(pokedex:releases(), 1, "draining the borrowed clock never touches the released lease")
    timeline:announce("aftermath", false)
    advanceTimeline(timeline, 120)
    Assert.isTrue(
      timeline:settled(),
      "the borrowed timeline still accepts and advances new work after child disposal"
    )
  end
  do
    local registration = frozenRegistration()
    local pokedex = newPokedexFake({ "ready" })
    local audio = newAudioFake()
    local child, timeline = newChild(Child, registration, pokedex, audio)
    for _ = 1, 10 do
      timeline:update(TICK, function(_)
        return true
      end)
      child:updateFixed(1 / 30)
    end
    child:cancelPointerCapture()
    child:dispose()
    Assert.equal(pokedex:releases(), 1, "disposal during presentation releases once")
    timeline:announce("later", false)
    advanceTimeline(timeline, 120)
    Assert.isTrue(
      timeline:settled(),
      "the borrowed timeline drains the orphan and the later cue after mid-run disposal"
    )
    Assert.equal(pokedex:releases(), 1, "draining the borrowed clock never touches the released lease")
    timeline:announce("aftermath", false)
    advanceTimeline(timeline, 120)
    Assert.isTrue(
      timeline:settled(),
      "the borrowed timeline still accepts and advances new work after mid-run disposal"
    )
  end
end

return { tests = T }
