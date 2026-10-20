-- Asset needs: the heavy assets a script's ops imply, as sorted unique
-- `kind:id` keys. Ops declare what they imply on their Schema.OPERATIONS
-- entry (`assets`: one `{kind, id}` need, or a function of the step that
-- returns a list), so a script never states them itself; the optional
-- `needs` hint on a script resource adds needs no op can show. One pure
-- extractor serves the producer (index closure) and the runtime (overrides).
-- Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local Schema = require("libs.script.src.Schema")
local ScriptErrors = require("libs.script.src.errors")

local AssetNeeds = {}

---@class AssetNeeds.Need
---@field kind string
---@field id string

---@param need AssetNeeds.Need
---@return string
function AssetNeeds.key(need)
  assert(type(need) == "table", "asset need must be a table")
  assert(
    type(need.kind) == "string" and need.kind ~= "" and not need.kind:find(":", 1, true),
    "asset need kind is invalid"
  )
  assert(type(need.id) == "string" and need.id ~= "", "asset need id is invalid")
  return need.kind .. ":" .. need.id
end

---@param key string
---@return AssetNeeds.Need
function AssetNeeds.parse(key)
  local kind, id
  if type(key) == "string" then
    kind, id = key:match("^([^:]+):(.+)$")
  end
  if kind == nil then
    Errors.raise(ScriptErrors.SCRIPT_SCHEMA_INVALID, "malformed asset need key", { key = tostring(key) })
  end
  return { kind = kind, id = id }
end

local function collect(steps, set)
  for _, step in ipairs(steps) do
    local spec = Schema.OPERATIONS[step.op]
    if spec ~= nil then
      local declared = spec.assets
      if type(declared) == "function" then
        for _, need in ipairs(declared(step)) do
          set[AssetNeeds.key(need)] = true
        end
      elseif declared ~= nil then
        set[AssetNeeds.key(declared)] = true
      end
      for name, field in pairs(spec.fields) do
        local value = step[name]
        if type(value) == "table" then
          if field.type == "steps" then
            collect(value, set)
          elseif field.type == "cases" then
            for _, caseSteps in pairs(value) do
              collect(caseSteps, set)
            end
          end
        end
      end
    end
  end
end

local function sorted(set)
  local list = {}
  for key in pairs(set) do
    list[#list + 1] = key
  end
  table.sort(list)
  return list
end

---@param steps table[]
---@return string[]
function AssetNeeds.forSteps(steps)
  local set = {}
  collect(steps, set)
  return sorted(set)
end

---@param resource table<string, unknown>
---@return string[]
function AssetNeeds.forResource(resource)
  local set = {}
  collect(resource.steps, set)
  for _, need in ipairs(resource.needs or {}) do
    if
      type(need) ~= "table"
      or type(need.kind) ~= "string"
      or need.kind == ""
      or need.kind:find(":", 1, true)
      or type(need.id) ~= "string"
      or need.id == ""
    then
      Errors.raise(ScriptErrors.SCRIPT_SCHEMA_INVALID, "malformed asset needs hint", { resource = resource.id })
    end
    set[AssetNeeds.key(need)] = true
  end
  return sorted(set)
end

return AssetNeeds
