-- Concrete battle content composition root for the HeartGold and
-- SoulSilver application. It builds the native mon and item catalogs
-- through their existing constructors, applies the supplied ordered
-- contributor list through fresh composition builders, and freezes the
-- result into one immutable bundle. Native roots arrive from the
-- provisioning cache owners at the call site; this module never decodes
-- source formats. Any contributor failure prevents publication: build
-- returns nothing and publishes no partial bundle.

local MonCatalog = require("libs.mons.src.MonCatalog")
local ItemCatalog = require("libs.items.src.ItemCatalog")
local ContentBuilder = require("libs.content.src.ContentBuilder")
local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
local BattleContent = require("libs.battle.src.BattleContent")
local Errors = require("libs.errors.src.Errors")

---@class HgssBattleContent
local HgssBattleContent = {}

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

---@class HgssBattleContentOptions
---@field monRoot table<string, unknown> the native mon asset root from provisioning
---@field itemRoot table<string, unknown> the native item asset root from provisioning
---@field contributors? table<integer, table<string, unknown>> ordered contribution list

---@class HgssBattleContentBundle
---@field mons MonCatalog the frozen native mon catalog
---@field items ItemCatalog the frozen native item catalog
---@field resolved ResolvedContent the frozen composed content snapshot
---@field bound BoundBehaviors the frozen bound behavior registries
---@field content BattleContent the frozen executable battle binding set

-- Builds the frozen executable battle content for production sessions:
-- the native HGSS ruleset plus the application battle formats, frozen
-- together with no catalog dependency. Sessions resolve their mechanics
-- executor from the bound ruleset, so this bundle is what selects the
-- native lifecycle for field-owned battles.
---@return BattleContent the frozen native battle binding set
function HgssBattleContent.nativeContent()
  local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
  local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
  local builder = ContentBuilder.new()
  NativeTypeChart.install(builder, "battle-runtime")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(Executor.RULESET, { key = Executor.RULESET, chart = Executor.RULESET }, "battle-runtime")
  for _, formatKey in ipairs({ "wild-single", "single", "double" }) do
    behaviors:registerFormat(formatKey, { key = formatKey }, "battle-runtime")
  end
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

---@param options HgssBattleContentOptions
---@return HgssBattleContentBundle
function HgssBattleContent.build(options)
  if type(options) ~= "table" then
    Errors.raise("BATTLE_INVALID", "battle content requires its build options", {})
  end
  if type(options.monRoot) ~= "table" or type(options.itemRoot) ~= "table" then
    Errors.raise("BATTLE_INVALID", "battle content requires its native catalog roots", {})
  end
  local contributors = options.contributors or {}
  if type(contributors) ~= "table" then
    Errors.raise("BATTLE_INVALID", "battle content requires its ordered contributors", {})
  end
  local items = ItemCatalog.new(options.itemRoot)
  local mons = MonCatalog.new(options.monRoot, items)
  local builder = ContentBuilder.new()
  local behaviors = BattleBehaviorBuilder.new()
  for index, contribution in ipairs(contributors) do
    checkContribution(contribution, index)
    contribution.install(builder, behaviors)
  end
  local bound = behaviors:freeze()
  local resolved = builder:freeze()
  return {
    mons = mons,
    items = items,
    resolved = resolved,
    bound = bound,
    content = BattleContent.new(resolved, bound),
  }
end

return HgssBattleContent
