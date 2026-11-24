-- The blocking hatch task: the source order around the scene, the receipt
-- published exactly once before the naming screen, the default name kept on a
-- blank submission, the field restored only after the child closed, and an
-- interrupted application that still finalizes and reopens the field. Every
-- collaborator is a recording stand-in over the real task contract.

local Assert = require("tests.support.Assert")
local Task = require("libs.hgss.src.script.tasks.EggHatchTask")

local T = { tests = {} }

---@param options { wantToName: boolean?, nameText: string?, interrupt: boolean? }
---@return table ctx, table record
local function fixture(options)
  local record = {
    opens = {},
    steps = 0,
    closes = 0,
    finished = 0,
    released = 0,
    leaves = 0,
    restores = 0,
    namingOpens = {},
    namingCloses = 0,
    nicknames = {},
    children = 0,
  }
  local care = {
    open = function(_, request)
      record.opens[#record.opens + 1] = request
      record.children = record.children + 1
      return { id = record.children }
    end,
    activeHandle = function()
      return record.children > 0 and { id = record.children } or nil
    end,
    isActive = function()
      return record.children > 0
    end,
    step = function()
      record.steps = record.steps + 1
    end,
    result = function()
      if record.steps < 2 then
        return nil
      end
      return { kind = "hatch", wantToName = options.wantToName == true, done = true }
    end,
    close = function()
      record.children = 0
      record.closes = record.closes + 1
    end,
    cancel = function()
      record.children = 0
      record.closes = record.closes + 1
    end,
  }
  local daycare = {
    activeHatch = function()
      return {
        slot = 0,
        subject = { slot = 0, speciesId = 172, form = 0, nickname = "PICHU", variant = "egg" },
      }
    end,
    finishHatch = function()
      record.finished = record.finished + 1
    end,
    releaseHatch = function()
      record.released = record.released + 1
    end,
  }
  local overworld = {
    leave = function()
      record.leaves = record.leaves + 1
    end,
    restore = function()
      record.restores = record.restores + 1
    end,
    phase = function()
      return record.restores > 0 and "present" or "absent"
    end,
    updateFixed = function() end,
  }
  local naming = {
    isActive = function()
      return record.namingOpened == true
    end,
    open = function(_, spec)
      record.namingOpens[#record.namingOpens + 1] = spec
      record.namingOpened = true
    end,
    handleInput = function() end,
    updateFixed = function() end,
    status = function()
      return { done = true, text = options.nameText or "" }
    end,
    close = function()
      record.namingOpened = false
      record.namingCloses = record.namingCloses + 1
    end,
  }
  local mons = {
    partyMon = function()
      return { species = "PICHU", form = 0, personality = 1, moves = {} }
    end,
    catalog = function()
      return {
        species = function()
          return { nativeId = 172, genderRatio = 127, growthCurve = 0 }
        end,
        iconSelection = function()
          return "icon/pichu"
        end,
      }
    end,
    setNickname = function(_, slot, text)
      record.nicknames[#record.nicknames + 1] = { slot = slot, text = text }
    end,
  }
  local ctx = {
    instance = { scriptId = "common.hatch_egg" },
    services = {
      pokemonCare = care,
      daycare = daycare,
      overworld = overworld,
      monNaming = naming,
      mons = mons,
    },
    input = {},
  }
  return ctx, record
end

function T.tests.the_task_runs_the_source_stages_and_names_the_mon()
  local ctx, record = fixture({ wantToName = true, nameText = "SPARKY" })
  local state = Task.create({}, ctx)
  Assert.equal(record.leaves, 1, "the field leaves the overworld before the scene")
  Assert.equal(#record.opens, 1, "the care host opens exactly one child")
  Assert.equal(record.opens[1].kind, "hatch", "the request names the hatch application")
  Assert.equal(record.opens[1].variant, "egg", "the request names its scene variant")
  Assert.equal(record.opens[1].species, 172, "the request names the hatched species")
  Assert.equal(record.opens[1].nickname, "PICHU", "the request carries the default name")

  local polled = Task.poll(state, ctx)
  Assert.isFalse(polled.complete, "the scene keeps the script blocked while it runs")
  Assert.equal(record.finished, 0, "no receipt publishes before the scene answers")

  polled = Task.poll(state, ctx)
  Assert.isFalse(polled.complete, "the naming stage keeps the script blocked")
  Assert.equal(record.finished, 1, "the receipt publishes once before the naming screen")
  Assert.equal(record.closes, 1, "the scene child closed before naming")

  polled = Task.poll(state, ctx)
  Assert.isFalse(polled.complete, "the naming screen owns the field")
  Assert.equal(#record.namingOpens, 1, "the source nickname question opens the naming screen")
  Assert.equal(record.namingOpens[1].currentText, "", "the naming screen starts blank")
  Assert.equal(record.namingOpens[1].subject.kind, "pokemon", "the naming subject is the hatched mon")
  Assert.equal(#record.nicknames, 0, "the name commits only after the screen closes")

  polled = Task.poll(state, ctx)
  Assert.isFalse(polled.complete, "the restore stage runs before completion")
  Assert.deepEqual(record.nicknames, { { slot = 0, text = "SPARKY" } }, "the chosen name is committed")
  polled = Task.poll(state, ctx)
  Assert.isTrue(polled.complete, "the task completes after the field is restored")
  Assert.equal(record.restores, 1, "the field is restored exactly once")
  Assert.equal(record.released, 1, "the claim releases after the field returns")
  Assert.equal(record.finished, 1, "the receipt publishes exactly once")
  Assert.isNil(Task.validate(state), "the task state stays serializable")
end

function T.tests.a_blank_answer_keeps_the_default_name()
  local ctx, record = fixture({ wantToName = true, nameText = "   " })
  local state = Task.create({}, ctx)
  for _ = 1, 6 do
    Task.poll(state, ctx)
  end
  Assert.equal(#record.namingOpens, 1, "the blank answer still opens the naming screen")
  Assert.equal(#record.nicknames, 0, "a blank submission writes no nickname")
end

function T.tests.refusing_the_question_skips_naming()
  local ctx, record = fixture({ wantToName = false })
  local state = Task.create({}, ctx)
  Task.poll(state, ctx)
  local polled = Task.poll(state, ctx)
  Assert.isFalse(polled.complete)
  Assert.equal(#record.namingOpens, 0, "the no answer opens no naming screen")
  Assert.equal(record.finished, 1, "the receipt still publishes once")
  polled = Task.poll(state, ctx)
  Assert.isTrue(polled.complete, "the task completes after the restore")
end

function T.tests.an_interrupted_application_finalizes_once_and_restores_the_field()
  local ctx, record = fixture({ wantToName = true })
  local state = Task.create({}, ctx)
  Task.poll(state, ctx)
  Assert.equal(record.finished, 0, "the receipt waits for the committed hatch")
  Task.cancel(state, "acceptance interrupted the hatch", ctx)
  Assert.equal(record.finished, 1, "the interrupted application publishes its receipt once")
  Assert.equal(record.released, 1, "the interrupted application releases its claim")
  Assert.equal(record.closes, 1, "the interrupted child closes once")
  Assert.equal(record.restores, 1, "the interrupted application restores the field")
  Task.cancel(state, "a second interruption", ctx)
  Assert.equal(record.finished, 1, "a repeated interruption publishes nothing again")
  Assert.equal(record.releases or record.released, 1, "the claim releases exactly once")
end

function T.tests.a_script_without_a_waiting_egg_faults_loudly()
  local ctx = fixture({})
  ctx.services.daycare.activeHatch = function()
    return nil
  end
  local ok, err = pcall(Task.create, {}, ctx)
  Assert.isFalse(ok, "a hatch scene without a waiting egg fails")
  assert(type(err) == "table", "the failure is structured")
  Assert.equal(err.code, "FEATURE_UNAVAILABLE", "the failure names the missing claim")
end

return T
