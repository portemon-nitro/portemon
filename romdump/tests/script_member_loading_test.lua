-- Lazy generated-script loading over published member bundles: installing the
-- index reads no member payload, the first request for one logical script
-- evaluates its member exactly once, later requests in that member reuse the
-- evaluated bundle, checked-in overrides keep precedence, and a new generation
-- never reuses an earlier generation's parsed member.

local Assert = require("tests.support.Assert")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptSounds = require("romdump.src.catalog.hgss.sndseq")
local ScriptCacheBuildFixture = require("tests.support.ScriptCacheBuildFixture")
local ScriptFixture = require("tests.support.ScriptFixture")
local ScriptLoader = require("libs.script.src.ScriptLoader")
local ScriptOverrides = require("libs.assets.src.ScriptOverrides")

local T = {}

local GENERATION_A = string.rep("a", 40)
local GENERATION_B = string.rep("b", 40)
local OUTER_A = "outer-generation-a"
local OUTER_B = "outer-generation-b"

local function scriptBytes(sound)
  return ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = { { op = 73, args = { { value = sound, width = 2 } } }, { op = 2, args = {} } },
      },
    },
  })
end

-- Generation A: member 0 holds three scripts, member 1 holds two. The member 0
-- scripts differ by their sound operand so a wrong-slot or stale-generation
-- read is visible in the returned steps.
local function generationAMembers()
  return {
    ScriptFixture.member({
      scripts = {
        {
          offset = 0x20,
          instructions = { { op = 73, args = { { value = 1500, width = 2 } } }, { op = 2, args = {} } },
        },
        {
          offset = 0x28,
          instructions = { { op = 73, args = { { value = 1501, width = 2 } } }, { op = 2, args = {} } },
        },
        { offset = 0x30, instructions = { { op = 2, args = {} } } },
      },
    }),
    ScriptFixture.member({
      scripts = {
        {
          offset = 0x20,
          instructions = { { op = 73, args = { { value = 1502, width = 2 } } }, { op = 2, args = {} } },
        },
        { offset = 0x28, instructions = { { op = 2, args = {} } } },
      },
    }),
  }
end

-- Generation B changes the first member's script bodies while keeping the same
-- logical ids.
local function generationBMembers()
  return {
    ScriptFixture.member({
      scripts = {
        {
          offset = 0x20,
          instructions = { { op = 73, args = { { value = 1501, width = 2 } } }, { op = 2, args = {} } },
        },
        {
          offset = 0x28,
          instructions = { { op = 73, args = { { value = 1502, width = 2 } } }, { op = 2, args = {} } },
        },
        { offset = 0x30, instructions = { { op = 2, args = {} } } },
      },
    }),
    ScriptFixture.member({
      scripts = {
        {
          offset = 0x20,
          instructions = { { op = 73, args = { { value = 1502, width = 2 } } }, { op = 2, args = {} } },
        },
        { offset = 0x28, instructions = { { op = 2, args = {} } } },
      },
    }),
  }
end

-- One checked-in override for a logical id in the first member: its steps must
-- replace the generated base.
local function overrideFs(id)
  local manifest = "return {\n  " .. string.format("%q", id) .. ",\n}\n"
  local content = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = '
    .. string.format("%q", id)
    .. ", steps = { S.stop() } }\n"
  return {
    read = function(_, path)
      if path == ScriptOverrides.MANIFEST then
        return manifest
      end
      if path == ScriptOverrides.DIR .. "/" .. id .. ".lua" then
        return content
      end
      return nil
    end,
  }
end

local function requireShim(name)
  if name == "gen4.script" then
    return require("gen4.script")
  end
  error("unexpected require in a generated chunk: " .. tostring(name))
end

-- Counts cache reads of member payload chunks by their emitted module shape,
-- independent of the physical member path.
local function countMemberReads(backend)
  local reads = {}
  local original = backend.read
  backend.read = function(self, path)
    local data = original(self, path)
    if type(data) == "string" and data:find('require("gen4.script")', 1, true) ~= nil then
      reads[#reads + 1] = path
    end
    return data
  end
  return reads
end

local function publishGeneration(romFs, cache, generationKey, outerGeneration, stagePrefix)
  local plan = ScriptCacheBuildFixture.plan(romFs, generationKey)
  for _, memberPlan in ipairs(plan.members) do
    local memberId = memberPlan.memberId
    local compiled = ScriptCacheBuildFixture.compileMember(romFs, plan, memberId)
    ScriptCacheBuildFixture.publishMember(
      cache,
      outerGeneration,
      plan,
      compiled,
      stagePrefix .. "-member-" .. tostring(memberId)
    )
  end
  ScriptCacheBuildFixture.publishSummary(cache, outerGeneration, plan, stagePrefix .. "-summary")
  return plan
end

function T.lazy_member_loading_keeps_overrides_and_generation_isolation()
  local romFsA = ScriptCacheBuildFixture.romFs(generationAMembers())
  local cache = ScriptCacheBuildFixture.cache()
  local planA = publishGeneration(romFsA, cache, GENERATION_A, OUTER_A, "generation-a")
  local scripts = planA.members[1].scripts
  local firstId = scripts[1].id
  local overrideId = scripts[2].id
  local sameMemberId = scripts[3].id
  local otherMemberId = planA.members[2].scripts[1].id

  local memberReads = countMemberReads(cache.backend)
  local registry, selection = ScriptLoader.buildRegistry(cache, overrideFs(overrideId), requireShim, { lazy = true })
  Assert.equal(selection.generation, GENERATION_A)
  Assert.deepEqual(memberReads, {}, "installing the generated index reads no member payload")
  Assert.equal(#registry:ids(), #planA.resources, "the deferred index registers every logical script")

  local first = assert(registry:base(firstId))
  Assert.equal(first.id, firstId, "the member bundle returns the requested logical script")
  Assert.equal(first.steps[1].op, "play_sound", "the requested script keeps its compiled steps")
  Assert.equal(#memberReads, 1, "the first request evaluates its member once; member reads: " .. #memberReads)

  local sameMember = assert(registry:base(sameMemberId))
  Assert.equal(sameMember.id, sameMemberId, "a later slot in the same member returns its own script")
  Assert.equal(sameMember.steps[1].op, "stop")
  Assert.equal(
    #memberReads,
    1,
    "a later script in the same member reuses the evaluated member; member reads: " .. #memberReads
  )

  local overridden = assert(registry:base(overrideId))
  Assert.equal(overridden.id, overrideId, "the override keeps the logical id")
  Assert.equal(#overridden.steps, 1, "the checked-in override replaces the generated steps")
  Assert.equal(overridden.steps[1].op, "stop")
  Assert.equal(#memberReads, 1, "a resolved override needs no member payload; member reads: " .. #memberReads)

  local other = assert(registry:base(otherMemberId))
  Assert.equal(other.id, otherMemberId, "a script from another member returns its own resource")
  Assert.equal(other.steps[1].op, "play_sound")
  Assert.equal(#memberReads, 2, "another member is evaluated on its first request; member reads: " .. #memberReads)

  local romFsB = ScriptCacheBuildFixture.romFs(generationBMembers())
  local planB = publishGeneration(romFsB, cache, GENERATION_B, OUTER_B, "generation-b")
  Assert.equal(planB.members[1].scripts[1].id, firstId, "the new generation keeps the logical script ids")

  local readsBeforeB = #memberReads
  local registryB, selectionB = ScriptLoader.buildRegistry(cache, overrideFs(overrideId), requireShim, { lazy = true })
  Assert.equal(selectionB.generation, GENERATION_B)
  Assert.equal(#memberReads, readsBeforeB, "installing the new generation reads no member payload")

  local reloaded = assert(registryB:base(firstId))
  Assert.equal(reloaded.id, firstId)
  -- The lowered DSL carries the canonical sndseq symbol of the source operand,
  -- so the two generations' operands must resolve to distinct symbols.
  Assert.isTrue(ScriptSounds.byId[1501] ~= ScriptSounds.byId[1500], "the fixture operands are distinct sounds")
  Assert.equal(reloaded.steps[1].sound, ScriptSounds.byId[1501], "the new generation returns its own compiled bytes")
  Assert.equal(
    #memberReads,
    readsBeforeB + 1,
    "the new generation evaluates its member once; member reads: " .. #memberReads
  )

  local retained = assert(registry:base(firstId))
  Assert.equal(retained.steps[1].sound, ScriptSounds.byId[1500], "the earlier registry keeps its own parsed member")
end

return { metadata = { capabilities = {} }, tests = T }
