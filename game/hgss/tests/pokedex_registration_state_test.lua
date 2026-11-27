-- First-catch registration presentation through the battle-owned child:
-- the announcement holds its explicit post-text wait while the default
-- cue keeps its short hold, the child runs the source phase sequence on
-- the HGSS source clock with separate fades, a once-only cry, and fresh
-- dismissal input, and every failure or disposal path releases its
-- borrowed lease exactly once. The real battle timeline drives the
-- announcement clock; preparation and audio stay recording doubles. No
-- renderer, GPU, ROM, or save is involved.

local Assert = require("tests.support.Assert")
local BattleTimeline = require("game.hgss.tests.support.BattleTimelineFixture")
local FakeGraphics = require("tests.support.FakeGraphics")
local Fixture = require("tests.support.PokedexPresentationFixture")
local SourceTick = require("libs.hgss.src.field.SourceTick")

local CHILD_MODULE = "game.hgss.src.pokedex.PokedexRegistrationState"

local T = {}

local TICK = SourceTick.DT

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

-- The explicit post-text hold lasts sixty source ticks while an
-- identical default announcement carries no hold of its own: post-print
-- holds carry only the script wait behind the line, so a hold-free line
-- releases on its first post-print tick and the override costs the
-- remaining fifty-nine.
function T.explicit_announcement_hold_uses_sixty_internal_ticks()
  local defaultTicks = settleTicks("X", nil)
  local overrideTicks = settleTicks("X", 60)
  Assert.notNil(defaultTicks, "the default announcement settles")
  Assert.notNil(overrideTicks, "the explicit-hold announcement settles")
  Assert.isTrue(defaultTicks <= 40, "the default announcement keeps its short post-text wait")
  Assert.equal(
    overrideTicks - defaultTicks,
    59,
    "an explicit sixty-tick hold extends the identical hold-free announcement by fifty-nine ticks"
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
  Assert.isFalse(timeline:settled(), "an edge during the explicit hold consumes without resetting it to the default")
  advanceTimeline(timeline, 60)
  Assert.isTrue(timeline:settled(), "the explicit hold still completes after its full wait")
end

---@param script string[] preparation outcomes the fake lease serves in order
---@return table fake borrowed presentation owner with counts and demands
local function newPokedexFake(script)
  local releases = 0
  local demands = {}
  local rendererCalls = 0
  local fake = {
    releases = function()
      return releases
    end,
    demands = demands,
  }
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
  function fake:typesFor(species, form)
    local monCatalog = Fixture.catalogs()
    local okForm, record = pcall(monCatalog.form, monCatalog, species, form)
    if okForm and type(record) == "table" and type(record.types) == "table" then
      return record.types
    end
    local definition = monCatalog:species(species)
    assert(type(definition.types) == "table", "the fixture species carries its types")
    return definition.types
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
  function audio.select() end
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
      { role = "registration.mark-height", kind = "ui", messageId = 10, language = "native" },
      { role = "registration.height", kind = "height", species = registration.specimen.species },
      { role = "registration.mark-weight", kind = "ui", messageId = 11, language = "native" },
      { role = "registration.weight", kind = "weight", species = registration.specimen.species },
    }, "the demand publishes the caught specimen's card text slots")
    Assert.equal(demand.cry.species, registration.specimen.species, "the cry names the captured species")
    Assert.equal(demand.cry.form, 0, "the cry always uses the base form")
  end
end

-- The child runs its source phase sequence on accepted HGSS-source
-- quanta: preparation gates the announcement, the real borrowed timeline
-- carries the sixty-tick wait, the cry plays once with its fixed
-- pattern only after the entry fades, and completion freezes a drawable
-- final view while keeping the lease until disposal.
function T.registration_child_runs_source_phases_on_the_shared_clock()
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
  Assert.isTrue(child:status().complete == false, "no banner timer departs the card without a fresh edge")
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
    Assert.isTrue(child:status().acceptsDismissal == true, "the ignored cancellation keeps the card dismissible")
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
    Assert.isTrue(child:status().complete == false, "the early edge never crosses the readiness boundary")
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
  Assert.isTrue(child:status().acceptsDismissal == false, "the unfinished cry never releases dismissal")
  child:input({ { type = "confirm" } })
  for _ = 1, 120 do
    timeline:update(TICK, function(_)
      return true
    end)
    child:updateFixed(1 / 30)
  end
  Assert.isTrue(child:status().complete == false, "a fresh edge never hurries the unfinished cry")
  Assert.isTrue(child:status().acceptsDismissal == false, "a fresh edge never releases dismissal early")
  audio.cryDone = true
  Assert.isTrue(driveToDismissal(child, timeline, 1200), "the finished cry releases the ready card")
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
    Assert.isTrue(timeline:settled(), "the borrowed timeline still accepts and advances new work after child disposal")
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

---@param objects table[] detached card intents under test
---@param subject string intent subject under test
---@return table? the first intent naming the subject
local function findCardObject(objects, subject)
  Assert.isTrue(type(objects) == "table", "the card carries its sprite intents")
  for _, intent in ipairs(objects) do
    if type(intent) == "table" and intent.subject == subject then
      return intent
    end
  end
  return nil
end

-- The ready card projects its captured type art and footprint: the
-- first type names the frozen specimen type, a single-type capture
-- projects no second icon, the footprint names the species, all three
-- sit at the native card origins, and departure hides them together.
function T.ready_card_projects_type_and_footprint_intents()
  local Child = requirePresent("card sprite intents")
  local registration = frozenRegistration()
  local pokedex = newPokedexFake({ "ready" })
  local audio = newAudioFake()
  audio.cryDone = true
  local child, timeline = newChild(Child, registration, pokedex, audio)
  Assert.isTrue(driveToDismissal(child, timeline, 2000), "the card reaches its ready phase")
  local view = child:view()
  local first = assert(findCardObject(view.objects, "type-1"), "the ready card projects its first type")
  Assert.equal(first.choice, "water", "the totodile card names its captured type")
  Assert.equal(first.x, 168, "the first type keeps its native column")
  Assert.equal(first.y, 72, "the first type keeps its native row")
  Assert.isNil(findCardObject(view.objects, "type-2"), "a single-type capture projects no second icon")
  local foot = assert(findCardObject(view.objects, "footprint"), "the ready card projects its footprint")
  Assert.equal(foot.choice, "TOTODILE", "the footprint names the frozen species")
  Assert.equal(foot.x, 120, "the footprint keeps its native column")
  Assert.equal(foot.y, 80, "the footprint keeps its native row")
  Assert.isTrue(first.age >= 0, "card intents carry their accepted age")
  child:updateFixed(1 / 30)
  local later = assert(findCardObject(child:view().objects, "type-1"), "the card keeps its types across ticks")
  Assert.isTrue(later.age >= first.age, "accepted ticks never rewind card ages")
  child:dispose()
end

-- The completed card freezes the departure end state instead of snapping
-- back home: the picture stays centered, the popup sprites stay hidden,
-- and the terminal cover stays black until the owning screen releases it.
function T.completed_card_keeps_departure_end_state()
  local Child = requirePresent("frozen departure end state")
  local registration = frozenRegistration()
  local pokedex = newPokedexFake({ "ready" })
  local audio = newAudioFake()
  audio.cryDone = true
  local child, timeline = newChild(Child, registration, pokedex, audio)
  Assert.isTrue(driveToDismissal(child, timeline, 2000), "the card reaches its ready phase")
  child:input({ { type = "confirm" } })
  Assert.isTrue(pump(child, timeline, 1200), "a fresh edge completes the dismissed card")
  local view = child:view()
  Assert.equal(view.pictureX, 128, "the completed card keeps the centered picture")
  Assert.isTrue(view.spritesHidden == true, "the completed card keeps its sprites hidden")
  Assert.equal(view.paletteFade, 16, "the completed card holds its terminal cover")
  child:dispose()
end

-- The banner strip runs on the popup task, not the wall clock: bank 0 at
-- creation, palette 7 on the 16th popup update and back to palette 0 on
-- the 32nd, looping independently of the cry and of dismissal.
-- Preparation and the borrowed announcement accrue nothing before the
-- popup exists: the popup task counts its first update at creation, after
-- the battle announcement settles and the outgoing scene fade completes.
function T.banner_flashes_from_creation_and_loops_independently_of_the_cry()
  local Child = requirePresent("banner strip free-run")
  local child, timeline = newChild(Child, frozenRegistration(), newPokedexFake({ "ready" }), newAudioFake())
  local function advance(count)
    for _ = 1, count do
      child:updateFixed(1 / 30)
    end
  end
  -- Child-only updates never settle the borrowed announcement: no banner
  -- or sprite age accrues before popup creation.
  advance(20)
  Assert.equal(child:status().phase, "announcement", "setup: the card waits on its borrowed announcement")
  Assert.equal(child:view().banner, 0, "the announcement accrues no banner before popup creation")
  Assert.equal(child:view().spriteTick, 0, "the announcement accrues no sprite age before popup creation")
  -- Drive the borrowed clock to popup creation.
  local created = false
  for _ = 1, 1200 do
    timeline:update(TICK, function(_)
      return true
    end)
    child:updateFixed(1 / 30)
    if child:status().phase ~= "announcement" and child:status().phase ~= "preparing" then
      created = true
      break
    end
  end
  Assert.isTrue(created, "the settled announcement creates the popup")
  Assert.equal(child:view().banner, 0, "the created popup starts at palette 0")
  advance(15)
  Assert.equal(child:view().banner, 0, "the first fifteen popup updates keep palette 0")
  advance(1)
  Assert.equal(child:view().banner, 7, "the sixteenth popup update lights the banner")
  advance(15)
  Assert.equal(child:view().banner, 7, "the banner holds palette 7 through the thirty-first popup update")
  advance(1)
  Assert.equal(child:view().banner, 0, "the thirty-second popup update returns to palette 0")
  advance(16)
  Assert.equal(child:view().banner, 7, "the banner keeps looping after its reset")
  child:dispose()
end

-- Fresh touch dismisses the ready card with exactly one select sound while
-- confirmation stays silent; a duplicated or Normal second type never
-- projects a second icon; the Origin forme still requests its footprint;
-- contest departures fade both domains without sliding the picture.
function T.touch_type_and_footprint_follow_popup_rules_with_contest_departure()
  local Child = requirePresent("touch dismissal, popup type and footprint rules, and contest departure")

  -- A fresh touch edge dismisses with exactly one select sound.
  do
    local registration = frozenRegistration()
    local pokedex = newPokedexFake({ "ready" })
    local audio = newAudioFake()
    audio.cryDone = true
    local selectCalls = 0
    audio.select = function()
      selectCalls = selectCalls + 1
    end
    local child, timeline = newChild(Child, registration, pokedex, audio)
    Assert.isTrue(driveToDismissal(child, timeline, 1200), "the card becomes dismissible")
    child:input({ { type = "touch_new", pointerId = 9 } })
    Assert.isTrue(pump(child, timeline, 1200), "a fresh touch dismisses the ready card")
    Assert.equal(selectCalls, 1, "the accepted touch edge plays its select sound exactly once")
    child:dispose()
    Assert.equal(pokedex:releases(), 1, "the touch dismissal releases its lease once")
  end

  -- A confirmation edge dismisses silently.
  do
    local registration = frozenRegistration()
    local pokedex = newPokedexFake({ "ready" })
    local audio = newAudioFake()
    audio.cryDone = true
    local selectCalls = 0
    audio.select = function()
      selectCalls = selectCalls + 1
    end
    local child, timeline = newChild(Child, registration, pokedex, audio)
    Assert.isTrue(driveToDismissal(child, timeline, 1200), "the card becomes dismissible")
    child:input({ { type = "confirm" } })
    Assert.isTrue(pump(child, timeline, 1200), "a fresh confirmation dismisses the ready card")
    Assert.equal(selectCalls, 0, "a confirmation dismissal makes no select sound")
    child:dispose()
    Assert.equal(pokedex:releases(), 1, "the confirmation dismissal releases its lease once")
  end

  -- A duplicated or Normal second type projects no second icon.
  local function secondIconFor(types)
    local registration = frozenRegistration()
    local pokedex = newPokedexFake({ "ready" })
    function pokedex:typesFor(_species, _form)
      return types
    end
    local audio = newAudioFake()
    audio.cryDone = true
    local child, timeline = newChild(Child, registration, pokedex, audio)
    Assert.isTrue(driveToDismissal(child, timeline, 1200), "the card becomes dismissible")
    local objects = assert(child:view().objects, "the ready card carries its intents")
    local second = nil
    for _, intent in ipairs(objects) do
      if type(intent) == "table" and intent.subject == "type-2" then
        second = intent
      end
    end
    child:dispose()
    return second
  end
  Assert.isNil(secondIconFor({ "water", "water" }), "a duplicated second type projects no second icon")
  Assert.isNil(secondIconFor({ "water", "normal" }), "a Normal second type projects no second icon")

  -- The Origin forme still requests its footprint art.
  do
    local monCatalog, catalog = Fixture.catalogs()
    local dexOwner = Fixture.ownerWithHistory(monCatalog, catalog)
    local DexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
    local specimen =
      dexOwner:describe(DexFixture.makeMon(monCatalog, { species = "GIRATINA", form = 1, personality = 12345 }))
    local registration = {
      captureId = 9,
      mode = "wild",
      dexMode = "national",
      displayName = specimen.species,
      specimen = specimen,
    }
    local pokedex = newPokedexFake({ "ready" })
    local audio = newAudioFake()
    audio.cryDone = true
    local child, timeline = newChild(Child, registration, pokedex, audio)
    Assert.isTrue(driveToDismissal(child, timeline, 1200), "the Origin card becomes dismissible")
    local objects = assert(child:view().objects, "the Origin card carries its intents")
    local foot = nil
    for _, intent in ipairs(objects) do
      if type(intent) == "table" and intent.subject == "footprint" then
        foot = intent
      end
    end
    Assert.notNil(foot, "the popup footprint loads even for the Origin forme")
    assert(foot ~= nil, "the Origin footprint exists")
    Assert.equal(foot.choice, "GIRATINA", "the footprint names the frozen species")
    Assert.equal(foot.x, 120, "the footprint keeps its native column")
    Assert.equal(foot.y, 80, "the footprint keeps its native row")
    child:dispose()
  end

  -- A contest departure fades both domains without sliding the picture.
  do
    local registration = frozenRegistration()
    registration.mode = "contest"
    local pokedex = newPokedexFake({ "ready" })
    local audio = newAudioFake()
    audio.cryDone = true
    local child, timeline = newChild(Child, registration, pokedex, audio)
    Assert.isTrue(driveToDismissal(child, timeline, 1200), "the contest card becomes dismissible")
    Assert.equal(#audio.calls, 1, "the contest card cries exactly once")
    child:input({ { type = "confirm" } })
    local slid = false
    for _ = 1, 1200 do
      timeline:update(TICK, function(_)
        return true
      end)
      child:updateFixed(1 / 30)
      if child:view().pictureX ~= 48 then
        slid = true
      end
      if child:status().complete == true then
        break
      end
    end
    Assert.isTrue(child:status().complete == true, "the contest departure completes")
    Assert.isFalse(slid, "the contest departure never slides the picture")
    Assert.equal(child:view().pictureX, 48, "the contest exit keeps its creation center")
    Assert.equal(child:view().paletteFade, 16, "the contest exit fades its cover to black")
    Assert.equal(child:view().pictureFade, 16, "the contest exit fades its picture to black")
    child:dispose()
  end
end

-- The popup clock accrues only inside the visible card lifetime:
-- preparation, the borrowed announcement, and the frozen terminal never
-- advance the banner or sprite ages, equivalent accepted tick sequences
-- match, and failed acquisition stays explicit with exactly-once release.
function T.popup_clock_freezes_outside_the_visible_card_lifetime()
  local Child = requirePresent("popup-only banner and age accounting with lifecycle failures")

  -- Pending preparation accrues nothing.
  do
    local registration = frozenRegistration()
    local pokedex = newPokedexFake({ "pending", "pending", "pending" })
    local audio = newAudioFake()
    local child, _ = newChild(Child, registration, pokedex, audio)
    for _ = 1, 10 do
      child:updateFixed(1 / 30)
    end
    Assert.isTrue(child:status().complete == false, "pending preparation never completes")
    Assert.equal(child:view().banner, 0, "pending preparation accrues no banner")
    Assert.equal(child:view().spriteTick, 0, "pending preparation accrues no sprite age")
    child:dispose()
    Assert.equal(pokedex:releases(), 1, "disposal after pending preparation releases once")
  end

  -- The borrowed announcement accrues nothing before popup creation.
  do
    local registration = frozenRegistration()
    local pokedex = newPokedexFake({ "ready" })
    local audio = newAudioFake()
    local child, _ = newChild(Child, registration, pokedex, audio)
    child:updateFixed(1 / 30)
    Assert.equal(child:status().phase, "announcement", "setup: the card waits on its borrowed announcement")
    for _ = 1, 20 do
      child:updateFixed(1 / 30)
    end
    Assert.equal(child:status().phase, "announcement", "child quanta alone never settle the parent clock")
    Assert.equal(child:view().banner, 0, "the announcement accrues no banner before popup creation")
    Assert.equal(child:view().spriteTick, 0, "the announcement accrues no sprite age before popup creation")
    child:dispose()
  end

  -- The frozen terminal never advances once the popup deletes.
  do
    local registration = frozenRegistration()
    local pokedex = newPokedexFake({ "ready" })
    local audio = newAudioFake()
    audio.cryDone = true
    local child, timeline = newChild(Child, registration, pokedex, audio)
    Assert.isTrue(driveToDismissal(child, timeline, 1200), "the card becomes dismissible")
    child:input({ { type = "confirm" } })
    Assert.isTrue(pump(child, timeline, 1200), "the dismissal completes")
    local frozen = child:view()
    Assert.equal(frozen.pictureX, 128, "setup: the terminal keeps the centered picture")
    for _ = 1, 16 do
      timeline:update(TICK, function(_)
        return true
      end)
      child:updateFixed(1 / 30)
    end
    local later = child:view()
    Assert.equal(later.pictureX, frozen.pictureX, "the frozen terminal never moves its picture")
    Assert.equal(later.paletteFade, frozen.paletteFade, "the frozen terminal never changes its cover")
    Assert.equal(later.spriteTick, frozen.spriteTick, "the frozen terminal never advances sprite ages")
    Assert.equal(later.banner, frozen.banner, "the frozen terminal never advances its banner")
    child:dispose()
    Assert.equal(pokedex:releases(), 1, "the terminal releases once")
  end

  -- Equivalent accepted tick sequences publish the same view.
  do
    local function freshPair()
      local registration = frozenRegistration()
      local pokedex = newPokedexFake({ "ready" })
      local audio = newAudioFake()
      return newChild(Child, registration, pokedex, audio)
    end
    local childA, timelineA = freshPair()
    local childB, timelineB = freshPair()
    childA:updateFixed(1 / 30)
    childB:updateFixed(1 / 30)
    Assert.equal(childA:status().phase, "announcement", "setup: both cards wait on their announcement")
    for _ = 1, 3 do
      timelineA:update(TICK, function(_)
        return true
      end)
      childA:updateFixed(1 / 30)
    end
    for _ = 1, 3 do
      timelineB:update(TICK, function(_)
        return true
      end)
    end
    childB:updateFixed(3 / 30)
    Assert.equal(childB:status().phase, childA:status().phase, "equivalent accepted ticks reach the same phase")
    Assert.deepEqual(childB:view(), childA:view(), "equivalent accepted ticks publish the same view")
    childA:dispose()
    childB:dispose()
  end

  -- A failed acquisition latches its cause and never completes.
  do
    local registration = frozenRegistration()
    local audio = newAudioFake()
    local failing = {}
    function failing:acquire(_options)
      error("synthetic acquire failure")
    end
    function failing:typesFor(_species, _form)
      return { "water" }
    end
    local timeline = BattleTimeline.new({ textSpeed = "fastest" })
    local child = Child.new({
      registration = registration,
      pokedex = failing,
      timeline = timeline,
      audio = audio,
      measureDisplay = dualMeasurement,
    })
    Assert.isTrue(child:status().complete == false, "a failed acquisition never completes")
    Assert.notNil(child:status().error, "the failed acquisition latches its attributed cause")
    child:updateFixed(1 / 30)
    Assert.isTrue(child:status().complete == false, "updates never clear the acquisition error")
    child:dispose()
  end

  -- A layout change mid-card still reaches the single dismissal.
  do
    local registration = frozenRegistration()
    local pokedex = newPokedexFake({ "ready" })
    local audio = newAudioFake()
    audio.cryDone = true
    local measure = dualMeasurement()
    local signature = "dual"
    local child, timeline = newChild(Child, registration, pokedex, audio, function()
      local copy = {}
      for key, value in pairs(measure) do
        copy[key] = value
      end
      copy.signature = "registration-child-test:" .. signature
      return copy
    end)
    Assert.isTrue(driveToDismissal(child, timeline, 1200), "the card becomes dismissible")
    signature = "resized"
    child:cancelPointerCapture()
    child:input({ { type = "touch_new", pointerId = 9 } })
    Assert.isTrue(pump(child, timeline, 1200), "a fresh touch after resize dismisses")
    child:dispose()
    Assert.equal(pokedex:releases(), 1, "the resized dismissal releases once")
  end
end

return { tests = T }
