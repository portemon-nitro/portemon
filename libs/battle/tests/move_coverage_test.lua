-- Every usable native move resolves to exactly one executable handler:
-- the native registry binds the full source inventory through disjoint
-- per-family owners, removing one binding fails naming the move, malformed
-- inventories fail before any binding is consulted, and moves with
-- disjoint mechanics never share a single generic handler.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local BattleSources = require("romdump.src.config.BattleSources")
local DomainErrors = require("libs.errors.src.Errors")

local T = {}

---@param behavior string missing owner under test
---@return table the loaded native move registry
local function moveRegistry(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.behaviors.NativeMoves", behavior)
end

---@param path string family module under test
---@param behavior string missing owner under test
---@return table the loaded move behavior family
local function moveFamily(path, behavior)
  return SessionFixture.requirePresent(path, behavior)
end

---@return table<string, function> every native move handler by source key
local function registeredHandlers()
  local NativeMoves = moveRegistry("the native move registry owns the complete move binding set")
  local handlers = {}
  NativeMoves.register(handlers)
  return handlers
end

---@param err unknown raised failure under test
---@param identity string source identity the failure must name
local function assertFailureNames(err, identity)
  if DomainErrors.is(err) then
    local context = (err --[[@as table]]).context
    if type(context) == "table" and (context.key == identity or context.identity == identity) then
      return
    end
  end
  local text = tostring(err)
  Assert.isTrue(text:find(identity, 1, true) ~= nil, "the failure names " .. identity .. ", got: " .. text)
end

---@return string[] sorted usable move keys from the source inventory
local function usableMoves()
  local keys = {}
  for key in pairs(BattleSources.moveBindings) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

---@param set table<string, unknown> handler set under inspection
---@return string[] sorted handler keys for deterministic comparison
local function sortedHandlerKeys(set)
  local keys = {}
  for key in pairs(set) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

-- The registry covers the whole usable inventory: every source move owns
-- an executable handler and the registry check accepts the full set.
function T.every_usable_move_resolves_to_exactly_one_executable_handler()
  local NativeMoves = moveRegistry("the native move registry owns the complete move binding set")
  local handlers = registeredHandlers()
  Assert.isTrue(NativeMoves.assertCoverage(handlers, BattleSources), "the full handler set covers the inventory")
  local usable = usableMoves()
  Assert.isTrue(#usable > 400, "the usable inventory spans the source move set, got " .. tostring(#usable))
  local count = 0
  for _, key in ipairs(usable) do
    Assert.equal(type(handlers[key]), "function", "the usable move " .. key .. " owns an executable handler")
    count = count + 1
  end
  Assert.equal(count, #usable, "every usable move is bound exactly once")
end

-- Behavior lives in grouped family owners rather than one shared switch:
-- each family binds a nonempty set, family sets never overlap, and their
-- union is exactly the native registration with no silent gaps.
function T.families_contribute_disjoint_handler_sets_covering_the_registry()
  local families = {
    {
      name = "direct damage owns the arithmetic hit path",
      path = "libs.battle.src.gen4.behaviors.moves.DamageMoves",
    },
    {
      name = "status and field changes own the condition path",
      path = "libs.battle.src.gen4.behaviors.moves.ConditionMoves",
    },
    {
      name = "charging and delayed sequences own the multi-turn path",
      path = "libs.battle.src.gen4.behaviors.moves.SequenceMoves",
    },
    {
      name = "transforming and copying owns the identity path",
      path = "libs.battle.src.gen4.behaviors.moves.IdentityMoves",
    },
    {
      name = "metronome-class selection owns the called-move path",
      path = "libs.battle.src.gen4.behaviors.moves.CalledMoves",
    },
  }
  local union = {}
  for _, family in ipairs(families) do
    local owner = moveFamily(family.path, family.name)
    local contributed = {}
    owner.register(contributed)
    local keys = sortedHandlerKeys(contributed)
    Assert.isTrue(#keys > 0, family.name .. " binds a nonempty handler set")
    for _, key in ipairs(keys) do
      Assert.isNil(union[key], "the move " .. key .. " is bound by exactly one family")
      union[key] = contributed[key]
    end
  end
  local registered = registeredHandlers()
  Assert.deepEqual(sortedHandlerKeys(union), sortedHandlerKeys(registered), "family handlers union to the registry")
end

-- The registry check guards both directions: an inventory entry without a
-- handler fails naming that entry, and a handler naming nothing in the
-- inventory fails naming the extra key.
function T.removing_one_handler_fails_naming_the_move()
  local NativeMoves = moveRegistry("the native move registry owns the complete move binding set")
  local handlers = registeredHandlers()
  handlers.TACKLE = nil
  local absent = Assert.throws(function()
    NativeMoves.assertCoverage(handlers, BattleSources)
  end)
  assertFailureNames(absent, "TACKLE")

  local extra = registeredHandlers()
  extra.SOMETHING_UNBOUND = extra.SPLASH
  local unknown = Assert.throws(function()
    NativeMoves.assertCoverage(extra, BattleSources)
  end)
  assertFailureNames(unknown, "SOMETHING_UNBOUND")
end

-- The registry check validates its inputs first: an inventory without the
-- binding tables fails as invalid state instead of reporting false gaps.
function T.malformed_inventories_fail_before_binding_checks()
  local NativeMoves = moveRegistry("the native move registry owns the complete move binding set")
  local handlers = registeredHandlers()
  local shapeless = Assert.throws(function()
    NativeMoves.assertCoverage(handlers, {})
  end)
  Assert.isTrue(DomainErrors.is(shapeless), "a shapeless inventory fails as invalid state")
  local notInventory = Assert.throws(function()
    NativeMoves.assertCoverage(handlers, 7)
  end)
  Assert.isTrue(DomainErrors.is(notInventory), "a non-table inventory fails as invalid state")
end

-- Moves with disjoint mechanics never share one handler: damage, identity
-- change, called selection, and delayed damage each resolve to their own
-- function, so no single generic-damage fallback can serve them all.
function T.moves_with_disjoint_mechanics_never_share_one_handler()
  local handlers = registeredHandlers()
  local representatives = { "TACKLE", "EXPLOSION", "TRANSFORM", "METRONOME", "SLEEP_TALK", "FUTURE_SIGHT" }
  for _, key in ipairs(representatives) do
    Assert.equal(type(handlers[key]), "function", "the representative move " .. key .. " owns a handler")
  end
  for leftIndex = 1, #representatives do
    for rightIndex = leftIndex + 1, #representatives do
      local left = representatives[leftIndex]
      local right = representatives[rightIndex]
      Assert.isTrue(
        handlers[left] ~= handlers[right],
        "the disjoint moves " .. left .. " and " .. right .. " never share one handler"
      )
    end
  end
end

return { tests = T }
