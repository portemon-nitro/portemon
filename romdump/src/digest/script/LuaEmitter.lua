-- Lua DSL emitter : renders generated script content as deterministic,
-- byte-stable gen4 DSL Lua. Output uses stable key order, one trailing
-- newline, no timestamps, and no machine-specific paths; re-running against
-- identical inputs produces byte-identical files. Every step, action,
-- condition, value, and reference is emitted as its canonical schema table
-- through one mechanical serializer: no constructor dispatch, no
-- field-selective special cases, no accidental field loss. Pure domain
-- module: no love dependency.

local ScriptCache = require("libs.assets.src.ScriptCache")

local LuaEmitter = {}

-- The generated-resource metadata version, shared by every emitter path
-- (cache emission and override emission) so the version has one owner.
LuaEmitter.GENERATOR_VERSION = 1

local LUA_KEYWORDS = {
  ["and"] = true,
  ["break"] = true,
  ["do"] = true,
  ["else"] = true,
  ["elseif"] = true,
  ["end"] = true,
  ["false"] = true,
  ["for"] = true,
  ["function"] = true,
  ["goto"] = true,
  ["if"] = true,
  ["in"] = true,
  ["local"] = true,
  ["nil"] = true,
  ["not"] = true,
  ["or"] = true,
  ["repeat"] = true,
  ["return"] = true,
  ["then"] = true,
  ["true"] = true,
  ["until"] = true,
  ["while"] = true,
}

-- Deterministic key order for table emission (numeric keys first, then
-- sorted string keys).
---@param t table<string, unknown>
---@return string[]
local function orderedKeys(t)
  local fields, others = {}, {}
  for key in pairs(t) do
    if type(key) == "number" then
      fields[#fields + 1] = key
    else
      others[#others + 1] = key
    end
  end
  table.sort(fields)
  table.sort(others)
  for _, key in ipairs(others) do
    fields[#fields + 1] = key
  end
  return fields
end

-- Render one keyed table entry's key text (`name = `, `["k"] = `, or
-- `[1] = `).
---@param key string|number
---@return string
local function keyText(key)
  if type(key) == "number" then
    return "[" .. tostring(key) .. "]"
  end
  if key:match("^[%a_][%w_]*$") and not LUA_KEYWORDS[key] then
    return key
  end
  return "[" .. string.format("%q", key) .. "]"
end

-- Render one serializable value (scalar, reference, condition, value,
-- message, text descriptor, step, action, or nested list) as canonical Lua.
---@param value unknown
---@param indent string
---@return string
local function literal(value, indent)
  local ty = type(value)
  if ty == "nil" then
    return "nil"
  end
  if ty == "boolean" then
    return value and "true" or "false"
  end
  if ty == "number" then
    return tostring(value)
  end
  if ty == "string" then
    return string.format("%q", value)
  end
  if ty == "table" then
    local keys = orderedKeys(value)
    local parts = {}
    for _, key in ipairs(keys) do
      parts[#parts + 1] = keyText(key) .. " = " .. literal(value[key], indent .. "  ")
    end
    if #parts == 0 then
      return "{}"
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
  end
  error("cannot emit a " .. ty .. " value")
end

-- Render a steps list (or movement action list) as a table literal.
---@param steps table[]
---@param indent string
---@return string
local function stepsLiteral(steps, indent)
  local parts = {}
  for _, step in ipairs(steps or {}) do
    parts[#parts + 1] = indent .. "  " .. literal(step, indent .. "  ") .. ","
  end
  return table.concat(parts, "\n")
end

-- Render a whole generated member bundle: every source script of one script
-- archive member in source order, the compiler's compact direct dependency
-- facts per source script slot, and the member's coverage record. The bundle
-- is the physical unit of generated script content; its member id and
-- generation come from the path it is published under, so no source
-- provenance is repeated inside it.
---@param member { resources: { id: string, scriptIndex: integer, resource: table<string, unknown>, directDependencies: table<string, unknown> }[], coverage: table<string, unknown> }
---@return string
function LuaEmitter.emitMember(member)
  local resources = member.resources or {}
  local ordered = {}
  for _, entry in ipairs(resources) do
    local scriptIndex = entry.scriptIndex
    assert(
      type(scriptIndex) == "number" and scriptIndex % 1 == 0 and scriptIndex >= 0,
      "a member script index is a zero-based integer"
    )
    assert(ordered[scriptIndex] == nil, "a member bundle holds one script per source slot")
    ordered[scriptIndex] = entry
  end
  local count = 0
  while ordered[count] ~= nil do
    count = count + 1
  end
  assert(count == #resources, "a member bundle's source slots must be dense from zero")

  local lines = {}
  lines[#lines + 1] = "-- Generated script member: every script of one source archive member in"
  lines[#lines + 1] = "-- source order. Do not edit by hand."
  lines[#lines + 1] = 'local S = require("gen4.script")'
  lines[#lines + 1] = ""
  lines[#lines + 1] = "return {"
  lines[#lines + 1] = "  schema = " .. string.format("%q", ScriptCache.MEMBER_SCHEMA) .. ","
  lines[#lines + 1] = "  scripts = {"
  for scriptIndex = 0, count - 1 do
    local entry = ordered[scriptIndex]
    local resource = entry.resource
    assert(type(resource) == "table", "a member script entry requires its resource")
    assert(resource.id == entry.id, "a member script entry id must match its resource")
    lines[#lines + 1] = "    S.script {"
    lines[#lines + 1] = "      api = " .. tostring(resource.api) .. ","
    lines[#lines + 1] = "      id = " .. string.format("%q", resource.id) .. ","
    lines[#lines + 1] = "      metadata = { generated = true },"
    lines[#lines + 1] = "      steps = {"
    local body = stepsLiteral(resource.steps, "      ")
    if body ~= "" then
      lines[#lines + 1] = body
    end
    lines[#lines + 1] = "      },"
    lines[#lines + 1] = "    },"
  end
  lines[#lines + 1] = "  },"
  lines[#lines + 1] = "  direct = {"
  for scriptIndex = 0, count - 1 do
    local direct = ordered[scriptIndex].directDependencies
    assert(type(direct) == "table", "a member script entry requires its direct dependency facts")
    lines[#lines + 1] = "    [" .. tostring(scriptIndex) .. "] = {"
    for _, field in ipairs({ "audioSequences", "scriptTargets", "assetNeeds" }) do
      lines[#lines + 1] = "      " .. field .. " = " .. literal(direct[field], "      ") .. ","
    end
    lines[#lines + 1] = "    },"
  end
  lines[#lines + 1] = "  },"
  lines[#lines + 1] = "  coverage = {"
  for _, key in ipairs(orderedKeys(assert(member.coverage, "a member bundle requires its coverage record"))) do
    lines[#lines + 1] = "    " .. keyText(key) .. " = " .. literal(member.coverage[key], "    ") .. ","
  end
  lines[#lines + 1] = "  },"
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n") .. "\n"
end

-- Render an override resource for `data/scripts/overrides/<id>.lua` (the
-- script override system): the supported flow of the translated script with
-- unsupported commands collapsed into explicit unsupported nodes. Deterministic
-- like the cache emission; the header states the override origin and the
-- `replaces` field names the generated base when the override id is curated.
---@param resource table<string, unknown>
---@param meta table<string, unknown> { member, scriptIndex, sourcePath, replaces? }
---@return string
function LuaEmitter.emitOverride(resource, meta)
  local lines = {}
  lines[#lines + 1] = "-- Generated override (script override system): the supported flow of the"
  lines[#lines + 1] = "-- translated script with unsupported commands collapsed into explicit"
  lines[#lines + 1] = "-- unsupported nodes. Regenerate, do not hand-edit."
  lines[#lines + 1] = 'local S = require("gen4.script")'
  lines[#lines + 1] = ""
  lines[#lines + 1] = "return S.script {"
  lines[#lines + 1] = "  api = 1,"
  lines[#lines + 1] = "  id = " .. string.format("%q", resource.id) .. ","
  if meta.replaces ~= nil then
    lines[#lines + 1] = "  replaces = " .. string.format("%q", meta.replaces) .. ","
  end
  lines[#lines + 1] = "  metadata = {"
  lines[#lines + 1] = "    override = true,"
  lines[#lines + 1] = "    generated = true,"
  lines[#lines + 1] = '    generator = { name = "hgss-script-translator", version = '
    .. tostring(LuaEmitter.GENERATOR_VERSION)
    .. " },"
  lines[#lines + 1] = "    source = {"
  lines[#lines + 1] = '      repository = "portemon",'
  lines[#lines + 1] = "      path = " .. string.format("%q", meta.sourcePath) .. ","
  lines[#lines + 1] = '      game = "heartgold",'
  lines[#lines + 1] = '      archive = "scr_seq",'
  lines[#lines + 1] = "      member = " .. tostring(meta.member) .. ","
  lines[#lines + 1] = "      scriptIndex = " .. tostring(meta.scriptIndex) .. ","
  lines[#lines + 1] = "    },"
  local coverage = resource.metadata and resource.metadata.coverage or { complete = true, unsupportedCount = 0 }
  lines[#lines + 1] = "    coverage = { complete = "
    .. tostring(coverage.complete == true)
    .. ", unsupportedCount = "
    .. tostring(coverage.unsupportedCount or 0)
    .. " },"
  lines[#lines + 1] = "  },"
  lines[#lines + 1] = "  steps = {"
  lines[#lines + 1] = stepsLiteral(resource.steps, "  ")
  lines[#lines + 1] = "  },"
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n") .. "\n"
end

return LuaEmitter
