-- Foreground phone projection over live game domains: world flags and
-- variables, mon and Dex knowledge, PC capacity, Bag capacity, and the
-- production state behind Kurt, Day Care, and Safari contact branches.
-- Every read borrows its owner and returns borrowed facts without copying
-- authoritative state or keeping long-lived caches. A branch that needs an
-- absent owner fails with an attributed dependency error naming that
-- domain; it never synthesizes an empty-world answer. Branches that need
-- no production state answer locally. Pure adapter: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

---@class PhoneWorldContext
---@field private _owners table<string, unknown>
local PhoneWorldContext = {}
PhoneWorldContext.__index = PhoneWorldContext

---@param domain string
---@param message string
local function missingOwner(domain, message)
  local failure = Errors.new(
    ScriptErrors.FEATURE_UNAVAILABLE,
    "phone branch needs its missing " .. domain .. " owner: " .. message,
    { domain = domain }
  )
  error({ code = failure.code, message = failure.message, context = failure.context, domain = domain })
end

---@param owners unknown
---@return table<string, unknown>
local function checkOwners(owners)
  assert(type(owners) == "table", "phone world reads borrow their owners through a record")
  local borrowed = owners --[[@as table<string, unknown>]]
  assert(type(borrowed.state) == "table", "phone world reads borrow the companion state")
  return borrowed
end

-- Borrows the live owners behind phone branches. Only the companion state
-- is required; every other owner is optional and checked lazily by the
-- branch that reads it, so a local reply never demands a full world
-- simulation.
---@param owners { state: table<string, unknown> }
---@return PhoneWorldContext
function PhoneWorldContext.new(owners)
  return setmetatable({ _owners = checkOwners(owners) }, PhoneWorldContext)
end

---@param key unknown
---@return string domain, string fact
local function splitKey(key)
  assert(type(key) == "string" and key ~= "", "phone world reads name their domain fact")
  local domain, fact = key:match("^([^.]+)%.(.+)$")
  assert(domain ~= nil and fact ~= nil, "phone world reads name their domain fact")
  return domain, --[[@as string]]
    fact --[[@as string]]
end

---@param domain string
---@return table<string, unknown> the borrowed domain owner
function PhoneWorldContext:_domainOwner(domain)
  local owner = self._owners[domain]
  if type(owner) ~= "table" then
    missingOwner(domain, "no live " .. domain .. " simulation is available")
  end
  assert(type(owner) == "table", "phone world reads borrow a live domain owner")
  return owner --[[@as table<string, unknown>]]
end

-- Reads one typed world fact for the chosen source branch. Present facts
-- are borrowed references or scalars; an absent owner raises an
-- attributed dependency error before any effect; an unset fact inside a
-- present owner reads as nil rather than a fabricated default. Reads
-- never draw, mutate, or cache.
---@param key string
---@return unknown the borrowed fact, or nil when the owner carries no value for it
function PhoneWorldContext:read(key)
  local domain, fact = splitKey(key)
  if domain == "kurt" then
    if fact == "local-greeting" then
      return { key = "kurt.local-greeting" }
    end
    return self:_domainOwner("kurt")
  end
  if domain == "daycare" then
    return self:_domainOwner("daycare")
  end
  if domain == "safari" then
    return self:_domainOwner("safari")
  end
  if domain == "bill" then
    local pc = self._owners.pc
    if type(pc) ~= "table" then
      missingOwner("pc", "no live box capacity owner is available")
    end
    assert(type(pc) == "table", "phone box reads borrow the live capacity owner")
    local capacity = pc --[[@as table<string, unknown>]]
    if fact == "pc-free" then
      return capacity.freeSlots
    end
    assert(false, "phone box reads name a known bill fact")
  end
  if domain == "mom" then
    local flags = self._owners.flags
    if type(flags) ~= "table" then
      missingOwner("flags", "no live world flag owner is available")
    end
    assert(type(flags) == "table", "phone flag reads borrow the live flag owner")
    if fact == "savings-choice" then
      local choice = (flags --[[@as table<string, unknown>]]).savingsChoice
      if choice == nil then
        return nil
      end
      assert(type(choice) == "boolean", "the world savings choice stays a boolean once set")
      return choice
    end
    assert(false, "phone flag reads name a known mom fact")
  end
  if domain == "dex" then
    local dex = self:_domainOwner("dex")
    if fact == "seen" or fact == "caught" then
      return dex[fact]
    end
    assert(false, "phone dex reads name a known dex fact")
  end
  if domain == "party" then
    local party = self:_domainOwner("party")
    if fact == "count" then
      return party.count
    end
    assert(false, "phone party reads name a known party fact")
  end
  if domain == "bag" then
    local bag = self:_domainOwner("bag")
    if fact == "free-slots" then
      return bag.freeSlots
    end
    assert(false, "phone bag reads name a known bag fact")
  end
  error("phone world reads name a known domain", 0)
end

return PhoneWorldContext
