-- Public battle composition entrypoint, API 1: the versioned surface
-- mods and the application use to compose ordered content contributions
-- into one frozen battle binding set:
--
--     local Battle = require("gen4.battle")
--
-- A contribution is an already-ordered table carrying its concrete owner,
-- revision, and installer:
--
--     { owner = "sound", revision = "1", install = function(builder, behaviors) ... end }
--
-- Contribution order is supplied by the caller and never inferred here.
-- API 1 is not declared stable: until stability is explicitly declared the
-- surface stays minimal and incompatible cleanup is allowed. Session
-- creation arrives with the session provider and is not part of this
-- surface; this module exports working composition and registration APIs
-- only.

local ContentBuilder = require("libs.content.src.ContentBuilder")
local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
local BattleContent = require("libs.battle.src.BattleContent")
local Errors = require("libs.errors.src.Errors")

local Battle = {}

Battle.API_VERSION = 1

---@return ContentBuilder a fresh ordered content builder
function Battle.newContentBuilder()
  return ContentBuilder.new()
end

---@return BattleBehaviorBuilder a fresh typed behavior builder
function Battle.newBehaviorBuilder()
  return BattleBehaviorBuilder.new()
end

---@param contribution unknown
---@param index integer
local function checkContribution(contribution, index)
  if type(contribution) ~= "table" then
    Errors.raise("BATTLE_INVALID", "contribution " .. index .. " must be a record", {})
  end
  assert(contribution ~= nil, "the contribution check carries the validated record")
  if type(contribution.owner) ~= "string" or contribution.owner == "" then
    Errors.raise("BATTLE_INVALID", "contribution " .. index .. " must name its owner", {})
  end
  if type(contribution.revision) ~= "string" or contribution.revision == "" then
    Errors.raise("BATTLE_INVALID", "contribution " .. index .. " must name its revision", {})
  end
  if type(contribution.install) ~= "function" then
    Errors.raise("BATTLE_INVALID", "contribution " .. index .. " must carry its installer", {})
  end
end

-- Runs the supplied ordered contributions through fresh builders and
-- freezes the result. Any contributor failure prevents publication: nothing
-- is returned and no partial composition escapes.
---@param contributors table<integer, table<string, unknown>>
---@return ResolvedContent resolved the frozen composed content snapshot
---@return BoundBehaviors bound the frozen bound behavior registries
---@return BattleContent content the frozen executable battle binding set
function Battle.compose(contributors)
  assert(Battle.API_VERSION == 1, "the battle entrypoint carries its version")
  if type(contributors) ~= "table" then
    Errors.raise("BATTLE_INVALID", "composition requires its ordered contributors", {})
  end
  local builder = ContentBuilder.new()
  local behaviors = BattleBehaviorBuilder.new()
  for index, contribution in ipairs(contributors) do
    checkContribution(contribution, index)
    contribution.install(builder, behaviors)
  end
  local bound = behaviors:freeze()
  local resolved = builder:freeze()
  return resolved, bound, BattleContent.new(resolved, bound)
end

return Battle
