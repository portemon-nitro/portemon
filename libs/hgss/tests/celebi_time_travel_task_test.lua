-- Celebi time-travel task contract: the beat counts are pinned to the
-- decomp (30-tick model beat, 180-tick swirl, 210 polls to completion),
-- the task opens the source white fade-out through the screen service so
-- the following warp finds its opaque cover, completion needs both the
-- beats and the fade, cancellation settles, and only the documented state
-- shape validates.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CelebiTimeTravelTask = require("libs.hgss.src.script.tasks.CelebiTimeTravelTask")

local T = {}

-- A scripted screen backend: the fade reports done a fixed number of
-- polls after it starts, and an in-flight fade can be preloaded.
local function screen(doneAfter, busy)
  local backend = { starts = {}, polls = 0, doneAfter = doneAfter, busy = busy or false }
  function backend:startFade(spec)
    Assert.isFalse(self.busy, "the cutscene never overlaps fades")
    self.busy = true
    self.polls = 0
    self.starts[#self.starts + 1] = spec
  end
  function backend:fadeDone()
    if not self.busy then
      return true
    end
    return self.polls >= self.doneAfter
  end
  return backend
end

local function ctxWith(backend)
  return { services = { screen = backend } }
end

function T.completes_after_the_source_beats_with_an_opaque_cover()
  local backend = screen(30)
  local ctx = ctxWith(backend)
  local state = CelebiTimeTravelTask.create({}, ctx)
  Assert.equal(state.phase, "beat", "the cutscene opens on its model beat")
  local polls = 0
  while true do
    polls = polls + 1
    backend.polls = backend.polls + 1
    Assert.isTrue(polls <= 210, "the cutscene must settle within its source beats")
    local result = CelebiTimeTravelTask.poll(state, ctx)
    state = result.state
    if result.complete then
      break
    end
    if polls == 30 then
      Assert.equal(state.phase, "swirl", "the swirl starts exactly when the model beat ends")
      Assert.equal(state.elapsed, 0, "the swirl beat restarts its count")
    end
  end
  Assert.equal(polls, 210, "the 30-tick beat plus the 180-tick swirl complete together")
  Assert.equal(#backend.starts, 1, "the cutscene opens exactly one fade")
  Assert.equal(backend.starts[1].direction, "out", "the cutscene fades out of the field")
  Assert.equal(backend.starts[1].color, "white", "the time travel flashes white like the source")
end

function T.stays_incomplete_before_the_final_beat()
  local backend = screen(30)
  local ctx = ctxWith(backend)
  local state = CelebiTimeTravelTask.create({}, ctx)
  for _ = 1, 209 do
    backend.polls = backend.polls + 1
    local result = CelebiTimeTravelTask.poll(state, ctx)
    state = result.state
    Assert.isFalse(result.complete, "no earlier poll may settle the cutscene")
  end
  backend.polls = backend.polls + 1
  Assert.equal(CelebiTimeTravelTask.poll(state, ctx).complete, true, "the 210th poll settles it")
end

function T.a_slow_fade_holds_completion_open()
  local backend = screen(300)
  local ctx = ctxWith(backend)
  local state = CelebiTimeTravelTask.create({}, ctx)
  for _ = 1, 210 do
    backend.polls = backend.polls + 1
    local result = CelebiTimeTravelTask.poll(state, ctx)
    state = result.state
    Assert.isFalse(result.complete, "the open fade holds the cutscene past its beats")
  end
  Assert.isNil(CelebiTimeTravelTask.validate(state), "a held cutscene stays a valid saved state")
  for _ = 211, 400 do
    backend.polls = backend.polls + 1
    local result = CelebiTimeTravelTask.poll(state, ctx)
    state = result.state
    if result.complete then
      Assert.equal(backend.polls, 300, "the fade landing settles the cutscene")
      return
    end
  end
  Assert.isTrue(false, "the landed fade must settle the cutscene")
end

function T.an_in_flight_fade_lands_before_the_cutscene_fade_starts()
  local backend = screen(30, true)
  local ctx = ctxWith(backend)
  local state = CelebiTimeTravelTask.create({}, ctx)
  local result = CelebiTimeTravelTask.poll(state, ctx)
  Assert.isFalse(result.complete, "the in-flight fade must not settle the cutscene")
  Assert.equal(#backend.starts, 0, "the cutscene never overlaps fades")
  backend.busy = false
  backend.polls = backend.polls + 1
  result = CelebiTimeTravelTask.poll(state, ctx)
  Assert.equal(#backend.starts, 1, "the landed fade lets the cutscene fade start")
  Assert.isFalse(result.complete, "the fresh fade must not settle the cutscene")
end

function T.a_missing_screen_is_an_attributed_fault()
  local ok, err = pcall(CelebiTimeTravelTask.poll, CelebiTimeTravelTask.create({}, {}), { services = {} })
  Assert.isFalse(ok, "the cutscene requires its screen cover backend")
  Assert.isTrue(Errors.is(err), "the missing backend raises a structured fault")
  Assert.equal(err.code, "SCRIPT_SERVICE_MISSING", "the fault names the missing service")
end

function T.cancellation_settles_without_advancing()
  local backend = screen(30)
  local ctx = ctxWith(backend)
  local state = CelebiTimeTravelTask.create({}, ctx)
  backend.polls = backend.polls + 1
  CelebiTimeTravelTask.poll(state, ctx)
  CelebiTimeTravelTask.cancel(state, "acceptance injected failure")
  local result = CelebiTimeTravelTask.poll(state, ctx)
  Assert.isTrue(result.complete, "cancellation settles the cutscene")
  Assert.isNil(CelebiTimeTravelTask.validate(state), "the cancelled shape still validates")
end

function T.only_the_documented_state_shape_validates()
  Assert.isNil(
    CelebiTimeTravelTask.validate({ phase = "beat", elapsed = 0, fadeStarted = false }),
    "the fresh beat shape validates"
  )
  Assert.isNil(
    CelebiTimeTravelTask.validate({ phase = "swirl", elapsed = 180, fadeStarted = true }),
    "the terminal swirl count validates before consumption"
  )
  for _, state in ipairs({
    "beat",
    {},
    { phase = "fade", elapsed = 0, fadeStarted = false },
    { phase = "beat", elapsed = -1, fadeStarted = false },
    { phase = "beat", elapsed = 31, fadeStarted = false },
    { phase = "swirl", elapsed = 181, fadeStarted = true },
    { phase = "beat", elapsed = 0, fadeStarted = 0 },
    { phase = "beat", elapsed = 0, fadeStarted = false, swirl = true },
    { phase = "beat", elapsed = 0, fadeStarted = false, cancelled = 7 },
  }) do
    Assert.notNil(CelebiTimeTravelTask.validate(state), "a malformed shape must not validate")
  end
end

return { tests = T }
