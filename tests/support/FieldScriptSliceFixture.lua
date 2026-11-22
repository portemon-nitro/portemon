-- A composed field-script platform running one synthetic override slice: the
-- real FieldScripts composition over a fake cache, a script-override
-- filesystem, and the injected owners the slice needs. Shared by the script
-- service tests and the field presentation draw tests so both drive the same
-- production composition instead of hand-built schedulers.

local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldMessageFixture = require("tests.support.FieldMessageFixture")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local FieldScripts = require("game.hgss.src.field.FieldScripts")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptOverrides = require("libs.assets.src.ScriptOverrides")

local FieldScriptSliceFixture = {}

local SCRIPT_GENERATION = string.rep("a", 40)
local SCRIPT_MARKER = "scripts-test-marker"

local function testCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    version = "heartgold",
    generation = SCRIPT_GENERATION,
    marker = SCRIPT_MARKER,
    memberCount = 0,
    scriptMemberCount = 0,
    skippedMemberCount = 0,
    scriptCount = 0,
    resourceCount = 0,
    resources = {},
    memberAudioSequences = {},
    memberAssetNeeds = {},
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
    removePresence = noop,
    materializeObject = noop,
  }
end

local SLICE_OPS =
  "set_spawn, set_special_spawn, field_move, game_score_event, battle, money ops, set_var, dynamic warp, floor window, field clock, and yield_tick"

---@param id string
---@param steps table[]
---@return string
function FieldScriptSliceFixture.sliceChunk(id, steps)
  local lines = { "return {", "  api = 1,", '  id = "' .. id .. '",', "  steps = {" }
  for _, step in ipairs(steps) do
    if step.op == "set_spawn" then
      lines[#lines + 1] = '    { op = "set_spawn", spawn = "' .. step.spawn .. '" },'
    elseif step.op == "set_special_spawn" then
      lines[#lines + 1] = string.format(
        '    { op = "set_special_spawn", map = %q, fieldX = %d, fieldZ = %d, warpId = %d, direction = %q },',
        step.map,
        step.fieldX,
        step.fieldZ,
        step.warpId,
        step.direction
      )
    elseif step.op == "field_move" then
      lines[#lines + 1] = '    { op = "field_move", source = "pending" },'
    elseif step.op == "game_score_event" then
      lines[#lines + 1] = string.format('    { op = "game_score_event", event = %d },', step.event)
    elseif step.op == "battle_launch" then
      lines[#lines + 1] =
        '    { op = "battle_launch", kind = "wild", details = { species = "TOTODILE", level = 4 }, result = { value = "var", id = "VAR_TEMP_x4001" } },'
    elseif step.op == "battle_result" then
      lines[#lines + 1] = '    { op = "battle_result", result = { value = "var", id = "VAR_TEMP_x4002" } },'
    elseif step.op == "set_dynamic_warp" then
      lines[#lines + 1] = string.format(
        '    { op = "set_dynamic_warp", map = %d, warpId = %d, fieldX = %d, fieldZ = %d, direction = %q },',
        step.map,
        step.warpId,
        step.fieldX,
        step.fieldZ,
        step.direction
      )
    elseif step.op == "get_dynamic_warp_floor" then
      lines[#lines + 1] = '    { op = "get_dynamic_warp_floor", result = { value = "var", id = "VAR_TEMP_x4001" } },'
    elseif step.op == "floor_window_show" then
      lines[#lines + 1] = string.format(
        '    { op = "floor_window_show", tileX = %d, tileY = %d, floor = %d, result = { value = "var", id = "VAR_TEMP_x4001" } },',
        step.tileX,
        step.tileY,
        step.floor
      )
    elseif step.op == "field_clock_hour" then
      lines[#lines + 1] = '    { op = "field_clock_hour", result = { value = "var", id = "VAR_TEMP_x4002" } },'
    elseif step.op == "set_var" then
      lines[#lines + 1] =
        string.format('    { op = "set_var", variable = "%s", value = %d },', step.variable, step.value)
    elseif step.op == "money_change" then
      lines[#lines + 1] = string.format(
        '    { op = "money_change", action = %q, amount = %s },',
        step.action,
        FieldScriptSliceFixture.operandLiteral(step.amount)
      )
    elseif step.op == "money_check" then
      lines[#lines + 1] = string.format(
        '    { op = "money_check", amount = %s, result = { value = "var", id = "%s" } },',
        FieldScriptSliceFixture.operandLiteral(step.amount),
        step.result
      )
    elseif step.op == "money_box" then
      if step.action == "show" then
        lines[#lines + 1] = string.format(
          '    { op = "money_box", action = "show", tileX = %s, tileY = %s },',
          FieldScriptSliceFixture.operandLiteral(step.tileX),
          FieldScriptSliceFixture.operandLiteral(step.tileY)
        )
      else
        lines[#lines + 1] = string.format('    { op = "money_box", action = %q },', step.action)
      end
    elseif step.op == "yield_tick" then
      lines[#lines + 1] = '    { op = "yield_tick" },'
    else
      error("the composed slice harness covers " .. SLICE_OPS .. " only", 0)
    end
  end
  lines[#lines + 1] = "  },"
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n")
end

-- A source operand is either a plain number or a named script variable.
---@param operand integer|string
---@return string
function FieldScriptSliceFixture.operandLiteral(operand)
  if type(operand) == "number" then
    return string.format("%d", operand)
  end
  return string.format('{ value = "var", id = "%s" }', operand)
end

---@class FieldScriptSliceServices
---@field travel table|nil
---@field fieldMoves table|nil
---@field battle table|nil
---@field gameStats table|nil
---@field clock table|nil
---@field mapLoader table|nil
---@field sourceMap table|nil
---@field profile table|nil
---@field versionId string|nil selected game version behind script edition splits
---@field messageProvider table|nil
---@field monNaming table|nil
---@field fontDef table|nil
---@field encode fun(id: string, steps: table[]): string|nil

---@param services FieldScriptSliceServices
---@param id string
---@param steps table[]
---@return FieldScripts
function FieldScriptSliceFixture.compose(services, id, steps)
  local function noop() end
  local chunk = services.encode or FieldScriptSliceFixture.sliceChunk
  return FieldScripts.new({
    cacheFs = testCache(),
    overrideFs = overrideFs({ [id] = chunk(id, steps) }),
    eventState = FieldEventState.new(),
    actors = stubActors(),
    player = { fieldX = 1, fieldZ = 2, worldY = 0, facing = "south" },
    profile = services.profile or { gender = 0, name = "Gold", badges = {} },
    versionId = services.versionId,
    dialogue = { isModal = noop },
    messageProvider = services.messageProvider or {},
    layout = function()
      return {}
    end,
    fontDef = services.fontDef or { charmap = {} },
    signpost = { isModal = true, updateFixed = noop },
    windowStyles = {
      resolve = function()
        return {}
      end,
    },
    transition = {},
    mapLoader = services.mapLoader or {},
    sourceMap = services.sourceMap or { fieldData = { mapId = 7, scriptBankId = 3, initScripts = {} } },
    auxiliaryUi = { advance = noop },
    menu = {},
    contextChoice = {},
    clock = services.clock,
    travel = services.travel,
    fieldMoves = services.fieldMoves,
    battle = services.battle,
    gameStats = services.gameStats,
    monNaming = services.monNaming,
  } --[[@as FieldScriptsOptions]])
end

-- The generated message bank the source money box reads its two rows from:
-- the row label (msg_0435_00030 = "Money") and the money format, which is the
-- source `${STRVAR_1 55, 0, 0}` marker the balance expands into. The provider is
-- the real one, so the box resolves its strings through the same path dialogue
-- does.
---@param label string the first-row label text
---@return FieldMessageProvider
function FieldScriptSliceFixture.moneyMessageProvider(label)
  local messages = {}
  for index = 1, 32 do
    messages[index] = { FieldMessageFixture.eos() }
  end
  messages[31] = { FieldMessageFixture.glyph(0x0121, label or "MONEY"), FieldMessageFixture.eos() }
  messages[32] = {
    FieldMessageFixture.glyph(0x01A8, "$"),
    FieldMessageFixture.control(FieldMessageText.STRVAR_1 + 55, { 0, 0 }),
    FieldMessageFixture.eos(),
  }
  return FieldMessageFixture.provider({ [435] = messages })
end

return FieldScriptSliceFixture
