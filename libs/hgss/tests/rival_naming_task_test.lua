-- Rival naming task: the source NameRival wait runs the shared field naming
-- host in rival mode and always accepts its result, so the committed name
-- (the typed name, or the edition default for an empty entry) is the one that
-- lands on the live player profile. The task keeps no name of its own and
-- never publishes a partial edit.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local PlayerData = require("libs.hgss.src.save.PlayerData")
local ScriptErrors = require("libs.script.src.errors")

local T = {}

local function requireTask()
  local ok, task = pcall(require, "libs.hgss.src.script.tasks.RivalNamingTask")
  Assert.isTrue(ok, "the HGSS task owns rival naming input")
  return assert(task)
end

-- The live saved profile, validated by its owning module: the task must
-- mutate this table, never a script-local copy.
local function profileFixture(rivalName)
  local record = assert(PlayerData.validate({
    profile = {
      name = "GOLD",
      rivalName = rivalName,
      gender = 0,
      trainerId = 0,
      money = 3000,
      badges = {},
      nationalDex = false,
      runningShoes = false,
      runningShoesLock = false,
      unionAvatar = 0,
    },
    options = {
      textFrame = 0,
      textSpeed = "mid",
      battleStyle = "shift",
      battleScene = true,
      soundMode = "stereo",
      battleSpeed = 1,
    },
  }, { charmap = CatalogFixture.CHARMAP, frameIndexes = { [0] = true } }))
  return record.profile
end

-- The shared field naming host, observed at its public boundary.
local function hostFixture()
  local host = { active = false, opened = {}, updates = 0, closed = 0, done = false, text = "" }
  function host:isActive()
    return self.active
  end
  function host:open(spec)
    self.active = true
    self.opened[#self.opened + 1] = spec
  end
  function host:handleInput(events)
    self.events = events
  end
  function host:updateFixed()
    self.updates = self.updates + 1
  end
  function host:status()
    if not self.active then
      return nil
    end
    return { done = self.done, text = self.text }
  end
  function host:close()
    self.active = false
    self.closed = self.closed + 1
  end
  return host
end

-- The script-facing player facade, reduced to the one operation this task
-- consumes, writing through to the real profile table.
local function playerFixture(profile)
  local writes = {}
  return {
    setRivalName = function(_, name)
      writes[#writes + 1] = name
      profile.rivalName = name
    end,
  },
    writes
end

local function fixture(rivalName, versionId)
  local profile = profileFixture(rivalName or "SILVER")
  local host = hostFixture()
  local player, writes = playerFixture(profile)
  return {
    services = { monNaming = host, player = player, versionId = versionId or "heartgold" },
    input = { uiEvents = { { type = "name_control", id = "ok" } } },
  },
    host,
    profile,
    writes
end

function T.changed_name_commits_to_the_saved_profile_and_returns_zero()
  local task = requireTask()
  local ctx, host, profile, writes = fixture()
  local state = task.create({}, ctx)
  ctx.input = { uiEvents = {} }
  Assert.isFalse(task.poll(state, ctx).complete, "the script waits while the naming screen is open")
  Assert.isTrue(host:isActive())
  ctx.input = { uiEvents = { { type = "text", text = "SOUL" } } }
  host.done = true
  host.text = "SOUL"
  local result = task.poll(state, ctx)
  Assert.isTrue(result.complete)
  Assert.equal(result.result, 0, "an accepted name reports the native accepted result")
  Assert.equal(profile.rivalName, "SOUL", "the accepted name lands on the live saved profile")
  Assert.deepEqual(writes, { "SOUL" }, "the task publishes the accepted name exactly once")
  Assert.equal(host.closed, 1)
end

-- The naming host runs in rival mode: the source command is not a party
-- nickname slot and uses the seven-glyph player name limit.
function T.naming_host_opens_in_rival_mode_at_the_player_name_limit()
  local task = requireTask()
  local ctx, host = fixture()
  local state = task.create({}, ctx)
  task.poll(state, ctx)
  Assert.equal(#host.opened, 1, "the first poll opens the one field naming host")
  Assert.equal(host.opened[1].kind, "rival")
  Assert.equal(host.opened[1].maxLength, 7)
  Assert.equal(host.opened[1].subject.kind, "rival")
end

-- An empty or all-space entry is the source default case, not a cancelled
-- one: the rival naming screen stores the edition default name (bank 254 row
-- 84 "Soul" for HeartGold and row 85 "Heart" for SoulSilver) and reports the
-- untouched accepted result.
function T.empty_submission_commits_the_edition_default_name()
  local task = requireTask()
  for _, case in ipairs({ { "heartgold", "Soul" }, { "soulsilver", "Heart" } }) do
    for _, submitted in ipairs({ "", "   " }) do
      local ctx, host, profile, writes = fixture("SILVER", case[1])
      local state = task.create({}, ctx)
      task.poll(state, ctx)
      host.done = true
      host.text = submitted
      local result = task.poll(state, ctx)
      local what = string.format("%q on %s", submitted, case[1])
      Assert.isTrue(result.complete, "an empty entry settles the task for " .. what)
      Assert.equal(result.result, 0, "the edition default is an accepted result for " .. what)
      Assert.equal(profile.rivalName, case[2], "the " .. case[1] .. " default lands on the live saved profile")
      Assert.deepEqual(writes, { case[2] }, "the default name is published exactly once")
      Assert.equal(host.closed, 1)
    end
  end
end

-- A typed entry is accepted even when it repeats the previously saved rival
-- name: the source compares the edit against its own entry buffer, never
-- against the stored rival name.
function T.typed_name_matching_the_saved_rival_name_is_accepted()
  local task = requireTask()
  local ctx, host, profile, writes = fixture("SILVER")
  local state = task.create({}, ctx)
  task.poll(state, ctx)
  host.done = true
  host.text = "SILVER"
  local result = task.poll(state, ctx)
  Assert.isTrue(result.complete)
  Assert.equal(result.result, 0, "a retyped saved name is an accepted result")
  Assert.equal(profile.rivalName, "SILVER")
  Assert.deepEqual(writes, { "SILVER" }, "the accepted name is published exactly once")
  Assert.equal(host.closed, 1)
end

-- Cancelling the blocked script closes the naming host exactly once and
-- publishes nothing.
function T.cancellation_releases_the_host_once_and_publishes_nothing()
  local task = requireTask()
  local ctx, host, profile, writes = fixture()
  local state = task.create({}, ctx)
  task.poll(state, ctx)
  task.cancel(state, "cancelled", ctx)
  task.cancel(state, "cancelled again", ctx)
  Assert.equal(host.closed, 1, "the host releases once across repeated cancellation")
  Assert.isFalse(host:isActive())
  Assert.equal(profile.rivalName, "SILVER")
  Assert.equal(#writes, 0)
end

-- A restored task reopens the same host with its retained editing buffer and
-- leaves the opening tick unadvanced, matching the shared naming task
-- lifecycle.
function T.restored_task_reopens_with_its_buffer_and_keeps_the_opening_tick()
  local task = requireTask()
  local ctx, host = fixture()
  local state = task.create({}, ctx)
  ctx.input = { uiEvents = {} }
  task.poll(state, ctx)
  Assert.equal(host.updates, 0, "the opening poll leaves the presentation at tick zero")
  task.poll(state, ctx)
  Assert.equal(host.updates, 1, "the next active poll advances the presentation once")

  state.currentText = "SOU"
  host.active = false
  task.poll(state, ctx)
  Assert.equal(host.opened[#host.opened].currentText, "SOU", "reopening restores the retained edit buffer")
  Assert.equal(host.opened[#host.opened].kind, "rival")
  Assert.equal(host.updates, 1, "the restored opening poll also preserves tick zero")
  Assert.isNil(task.validate(state), "the retained buffer stays serializable")
end

-- The task borrows the profile without carrying it: its serializable state
-- holds the editing buffer and lifetime flags only.
function T.task_state_carries_no_canonical_profile_state()
  local task = requireTask()
  local ctx, _, profile = fixture()
  local state = task.create({}, ctx)
  Assert.isNil(task.validate(state))
  for _, value in pairs(state) do
    Assert.isTrue(value ~= profile, "the task borrows the live profile, it never serializes it")
  end
  state.currentText = 7
  Assert.notNil(task.validate(state), "a malformed editing buffer is not serializable")
end

function T.missing_services_fault_before_the_screen_opens()
  local task = requireTask()
  local host = hostFixture()
  local function runUntilFault(ctx, code)
    local ok, err = pcall(function()
      task.poll(task.create({}, ctx), ctx)
    end)
    Assert.isFalse(ok, "a missing or invalid service faults instead of naming the rival")
    Assert.equal(err and err.code, code)
  end
  runUntilFault({ services = { monNaming = host } }, ScriptErrors.SCRIPT_SERVICE_MISSING)
  Assert.equal(#host.opened, 0, "no naming screen opens without the player facade")
  local player = playerFixture(profileFixture("SILVER"))
  runUntilFault({ services = { player = player } }, ScriptErrors.SCRIPT_SERVICE_MISSING)
  runUntilFault({ services = { monNaming = host, player = player } }, ScriptErrors.SCRIPT_SERVICE_MISSING)
  Assert.equal(#host.opened, 0, "no naming screen opens without the selected game version")
  runUntilFault({
    services = { monNaming = host, player = player, versionId = "platinum" },
  }, ScriptErrors.SCRIPT_INVALID_REFERENCE)
  Assert.equal(#host.opened, 0, "no naming screen opens for an unknown game version")
end

return { tests = T }
