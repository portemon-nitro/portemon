-- Field script badge service wiring: the composed scheduler carries a live
-- badge progression bound to the supplied profile, so badge operations read
-- and mutate the same persisted mask. Without a profile the badge
-- operations keep their missing-service fault instead of reading zero.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScripts = require("game.hgss.src.field.FieldScripts")
local PlayerProgression = require("libs.hgss.src.save.PlayerProgression")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptOverrides = require("libs.assets.src.ScriptOverrides")

local T = { tests = {} }

local SCRIPT_GENERATION = string.rep("a", 40)
local SCRIPT_MARKER = "scripts-test-marker"

local function testCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:write(ScriptCache.markerPath(), SCRIPT_MARKER)
  cache:write(ScriptCache.generationMarkerPath(SCRIPT_GENERATION), SCRIPT_MARKER)
  cache:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = SCRIPT_GENERATION,
    marker = SCRIPT_MARKER,
  })
  cache:writeLua(ScriptCache.generationIndexPath(SCRIPT_GENERATION), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = SCRIPT_GENERATION,
    marker = SCRIPT_MARKER,
    resources = {},
  })
  return cache
end

local function overrideFs(files)
  local ids = {}
  for id in pairs(files) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  local manifest = "return {"
  for index, id in ipairs(ids) do
    manifest = manifest .. string.format("%q%s", id, index < #ids and ", " or "")
  end
  manifest = manifest .. "}\n"
  return {
    read = function(_, path)
      if path == ScriptOverrides.MANIFEST then
        return manifest
      end
      for id, content in pairs(files) do
        if path == ScriptOverrides.DIR .. "/" .. id .. ".lua" then
          return content
        end
      end
      return nil
    end,
  }
end

local function stubActors()
  local function noop() end
  return {
    getActor = function()
      return nil
    end,
    show = noop,
    hide = noop,
    setPosition = noop,
    setFacing = noop,
    setMovementType = noop,
    setAnimationPaused = noop,
    getPosition = function()
      return { fieldX = 0, fieldZ = 0, worldY = 0 }
    end,
    getFacing = function()
      return "south"
    end,
    numericId = function()
      return nil
    end,
    actorIdForMapIndex = function()
      return nil
    end,
    cameraTargetId = function()
      return nil
    end,
    partnerId = function()
      return nil
    end,
    isVisible = function()
      return true
    end,
    setPresentationOffset = noop,
    clearPresentationOffset = noop,
  }
end

local function baseArgs(overrides)
  local function noop() end
  local args = {
    cacheFs = testCache(),
    overrideFs = overrides.fs,
    eventState = FieldEventState.new(),
    actors = stubActors(),
    player = { fieldX = 1, fieldZ = 2, worldY = 0, facing = "south" },
    profile = overrides.profile,
    dialogue = { isModal = noop },
    messageProvider = {},
    layout = function()
      return {}
    end,
    fontDef = { charmap = {} },
    signpost = { isModal = true, updateFixed = noop },
    windowStyles = {
      resolve = function()
        return {}
      end,
    },
    transition = {},
    mapLoader = {},
    sourceMap = { fieldData = { mapId = 7, scriptBankId = 3, initScripts = {} } },
    auxiliaryUi = { advance = noop },
    menu = {},
    contextChoice = {},
  }
  return args
end

local function driveSlice(profile, id, chunk)
  local emitted = {}
  local args = baseArgs({ fs = overrideFs({ [id] = chunk }), profile = profile })
  args.events = {
    emit = function(_, name, payload)
      emitted[#emitted + 1] = { name = name, payload = payload }
    end,
  }
  local platform = FieldScripts.new(args --[[@as FieldScriptsOptions]])
  local composed = assert(platform.composition:effective(id), "the slice must compose")
  platform.scheduler:createForeground(composed, nil, 100)
  for tick = 101, 110 do
    platform.scheduler:step(tick, nil)
    if platform.scheduler:foregroundEnvironmentId() == nil then
      break
    end
  end
  return platform, emitted
end

local function errorRecords(emitted)
  local faults = {}
  for _, record in ipairs(emitted) do
    if record.name == "script.error" then
      faults[#faults + 1] = record
    end
  end
  return faults
end

local function liveProfile()
  return { gender = 0, name = "Gold", trainerId = 1, money = 3000, badges = 0 }
end

function T.tests.award_then_check_observes_the_live_profile_mask()
  local profile = liveProfile()
  local platform, emitted = driveSlice(profile, "test.badge_award_check", [[
return {
  api = 1,
  id = "test.badge_award_check",
  steps = {
    { op = "award_badge", badge = "plain" },
    { op = "check_badge", badge = "plain", result = { value = "var", id = "VAR_SPECIAL_RESULT" } },
    { op = "stop" },
  },
}
]])
  Assert.isTrue(PlayerProgression.new(profile):hasBadge("plain"), "the award must land on the live profile mask")
  Assert.equal(
    platform.worldState:getVar("VAR_SPECIAL_RESULT"),
    1,
    "the check must read back the awarded badge through the scheduler"
  )
  Assert.equal(#errorRecords(emitted), 0, "badge operations through the live service must not fault")
end

function T.tests.count_reports_badges_awarded_through_the_same_profile()
  local profile = liveProfile()
  local setup = PlayerProgression.new(profile)
  setup:awardBadge("zephyr")
  setup:awardBadge("plain")
  local platform, emitted = driveSlice(profile, "test.badge_count", [[
return {
  api = 1,
  id = "test.badge_count",
  steps = {
    { op = "count_badges", result = { value = "var", id = "VAR_SPECIAL_RESULT" } },
    { op = "stop" },
  },
}
]])
  Assert.equal(
    platform.worldState:getVar("VAR_SPECIAL_RESULT"),
    2,
    "the counter must report the live profile mask through the scheduler"
  )
  Assert.equal(#errorRecords(emitted), 0, "the counter through the live service must not fault")
end

function T.tests.badge_operations_without_a_profile_keep_the_missing_service_fault()
  local profile = nil
  local _, emitted = driveSlice(profile, "test.badge_no_profile", [[
return {
  api = 1,
  id = "test.badge_no_profile",
  steps = {
    { op = "award_badge", badge = "plain" },
    { op = "stop" },
  },
}
]])
  local faults = errorRecords(emitted)
  Assert.equal(#faults, 1, "a badge operation without a profile must record exactly one script fault")
  Assert.equal(faults[1].payload.code, "SCRIPT_SERVICE_MISSING", "the fault must name the missing service")
end

return T
