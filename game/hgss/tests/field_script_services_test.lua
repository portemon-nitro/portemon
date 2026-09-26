-- Script service injection: the composed scheduler carries the travel
-- owner and the field-move runtime to the tasks that consume them. A
-- set_spawn slice updates the injected travel through the scheduler;
-- a pending field_move slice reaches the injected runtime. Override
-- slices install through the override layer like any source script.
-- No planning vocabulary here.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScripts = require("game.hgss.src.field.FieldScripts")
local FieldTravelState = require("libs.hgss.src.field.FieldTravelState")
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

local function sliceChunk(id, steps)
  local lines = { "return {", "  api = 1,", '  id = "' .. id .. '",', "  steps = {" }
  for _, step in ipairs(steps) do
    if step.op == "set_spawn" then
      lines[#lines + 1] = '    { op = "set_spawn", spawn = "' .. step.spawn .. '" },'
    elseif step.op == "field_move" then
      lines[#lines + 1] = '    { op = "field_move", source = "pending" },'
    else
      error("services harness covers set_spawn and pending field_move only", 0)
    end
  end
  lines[#lines + 1] = "  },"
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n")
end

local function driveSlice(services, id, steps)
  local function noop() end
  local args = {
    cacheFs = testCache(),
    overrideFs = overrideFs({ [id] = sliceChunk(id, steps) }),
    eventState = FieldEventState.new(),
    actors = stubActors(),
    player = { fieldX = 1, fieldZ = 2, worldY = 0, facing = "south" },
    profile = { gender = 0, name = "Gold" },
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
    travel = services.travel,
    fieldMoves = services.fieldMoves,
  }
  local platform = FieldScripts.new(args --[[@as FieldScriptsOptions]])
  local composed = assert(platform.composition:effective(id), "the slice must compose")
  platform.scheduler:createForeground(composed, nil, 100)
  platform.scheduler:step(100, nil)
  return platform
end

function T.tests.set_spawn_updates_the_injected_travel_service()
  local travel = FieldTravelState.new({ lastHealSpawn = "SPAWN_NEW_BARK" })
  driveSlice({ travel = travel, fieldMoves = nil }, "test.travel_slice", {
    { op = "set_spawn", spawn = "SPAWN_GOLDENROD" },
  })
  Assert.equal(travel:capture().lastHealSpawn, "SPAWN_GOLDENROD", "set_spawn records on the injected travel owner")
end

function T.tests.pending_field_move_reaches_the_injected_runtime()
  local takes = 0
  local fieldMoves = {
    takePending = function(_)
      takes = takes + 1
      error("no pending request queued", 0)
    end,
  }
  local ok, err = pcall(driveSlice, { travel = nil, fieldMoves = fieldMoves }, "test.moves_slice", {
    { op = "field_move", source = "pending" },
  })
  Assert.isFalse(ok, "an empty pending queue faults instead of succeeding")
  Assert.equal(takes, 1, "the task reads the injected runtime exactly once")
  Assert.isTrue(tostring(err):find("pending") ~= nil, "the fault names the missing queue: " .. tostring(err))
end

return T
