-- Synthetic generated-script cache for runtime and consumer tests: writes one
-- readable member bundle per member plus the single active index through a
-- CacheFs-shaped cache. The bundle text mirrors the generated member schema
-- (schema, ordered scripts, compact direct facts per source slot, one coverage
-- record) so a fixture cache reads back exactly like a published generation
-- without depending on the producer.

local ScriptCache = require("libs.assets.src.ScriptCache")

local ScriptCacheFixture = {}

local REPOSITORY = "portemon"
local ROM_SHA = "rom-sha"

---@class ScriptCacheFixture.Script
---@field id string
---@field steps string? Lua source of the step list contents (defaults to one stop)

local function bundleSource(scripts, prelude)
  local lines = {}
  lines[#lines + 1] = 'local S = require("gen4.script")'
  for _, line in ipairs(prelude or {}) do
    lines[#lines + 1] = line
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "return {"
  lines[#lines + 1] = "  schema = " .. string.format("%q", ScriptCache.MEMBER_SCHEMA) .. ","
  lines[#lines + 1] = "  scripts = {"
  for _, entry in ipairs(scripts) do
    lines[#lines + 1] = "    S.script {"
    lines[#lines + 1] = "      api = 1,"
    lines[#lines + 1] = "      id = " .. string.format("%q", entry.id) .. ","
    lines[#lines + 1] = "      metadata = { generated = true },"
    lines[#lines + 1] = "      steps = { " .. (entry.steps or "S.stop()") .. " },"
    lines[#lines + 1] = "    },"
  end
  lines[#lines + 1] = "  },"
  lines[#lines + 1] = "  direct = {"
  for index = 1, #scripts do
    lines[#lines + 1] = "    ["
      .. tostring(index - 1)
      .. "] = { audioSequences = {}, scriptTargets = {}, assetNeeds = {} },"
  end
  lines[#lines + 1] = "  },"
  lines[#lines + 1] = "  coverage = {"
  lines[#lines + 1] = "    source = { repository = "
    .. string.format("%q", REPOSITORY)
    .. ", romSha1 = "
    .. string.format("%q", ROM_SHA)
    .. " },"
  lines[#lines + 1] = "    totals = {"
  lines[#lines + 1] = "      members = 1,"
  lines[#lines + 1] = "      scripts = " .. tostring(#scripts) .. ","
  lines[#lines + 1] = "      reachableInstructions = " .. tostring(#scripts) .. ","
  lines[#lines + 1] = "      supportedInstructions = " .. tostring(#scripts) .. ","
  lines[#lines + 1] = "      unsupportedInstructions = 0,"
  lines[#lines + 1] = "      malformedInstructions = 0,"
  lines[#lines + 1] = "    },"
  lines[#lines + 1] = "    opcodes = {},"
  lines[#lines + 1] = "    scripts = {},"
  lines[#lines + 1] = "  },"
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n") .. "\n"
end

-- The bundle module source for one member, for callers that stage cache files
-- themselves.
---@param scripts ScriptCacheFixture.Script[]
---@param prelude string[]|nil
---@return string
function ScriptCacheFixture.memberSource(scripts, prelude)
  return bundleSource(scripts, prelude)
end

-- Write the whole selection: every member's bundle, the active index that maps
-- each logical id to its member and source slot, and empty per-member closures.
---@param cache CacheFs
---@param generation string
---@param marker string
---@param members table<integer, ScriptCacheFixture.Script[]>
function ScriptCacheFixture.write(cache, generation, marker, members, opts)
  opts = opts or {}
  local memberIds = {}
  for memberId in pairs(members) do
    memberIds[#memberIds + 1] = memberId
  end
  table.sort(memberIds)
  local resources = {}
  local audio = {}
  local needs = {}
  for _, memberId in ipairs(memberIds) do
    local scripts = members[memberId]
    table.sort(scripts, function(left, right)
      return left.id < right.id
    end)
    for index, entry in ipairs(scripts) do
      resources[#resources + 1] = { id = entry.id, member = memberId, scriptIndex = index - 1 }
    end
    cache:write(ScriptCache.memberPath(generation, memberId), bundleSource(scripts, opts.prelude))
    audio[tostring(memberId)] = {}
    needs[tostring(memberId)] = {}
  end
  table.sort(resources, function(left, right)
    return left.id < right.id
  end)
  cache:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    version = cache.versionId,
    generation = generation,
    marker = marker,
    memberCount = #memberIds,
    scriptMemberCount = #memberIds,
    skippedMemberCount = 0,
    scriptCount = #resources,
    resourceCount = #resources,
    resources = resources,
    memberAudioSequences = audio,
    memberAssetNeeds = needs,
  })
end

-- Write one generation holding a single member 0.
---@param cache CacheFs
---@param generation string
---@param marker string
---@param scripts ScriptCacheFixture.Script[]
---@param opts table<string, unknown>|nil
function ScriptCacheFixture.writeSingleMember(cache, generation, marker, scripts, opts)
  ScriptCacheFixture.write(cache, generation, marker, { [0] = scripts }, opts)
end

return ScriptCacheFixture
