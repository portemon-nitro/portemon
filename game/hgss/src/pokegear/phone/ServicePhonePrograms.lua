-- Named service-contact policies: friend, Bill, Bike Shop, Kurt, Day
-- Care, Buena, and Baoba. Each branch reads only the typed facts its
-- source branch needs; a branch that needs a production owner it was
-- not given fails with an attributed dependency error before any side
-- effect, while a local acknowledgement branch answers without one.
-- Pure source policy over the borrowed world table, private to the
-- foreground phone feature.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

---@class ServicePhonePrograms
local ServicePhonePrograms = {}

---@param domain string
local function missingOwner(domain)
  local failure = Errors.new(
    ScriptErrors.FEATURE_UNAVAILABLE,
    "phone service branch needs its missing " .. domain .. " owner",
    { domain = domain }
  )
  error({ code = failure.code, message = failure.message, context = failure.context, domain = domain })
end

---@param world table<string, unknown>
---@param domain string
---@return table<string, unknown> the borrowed domain owner
local function domainOwner(world, domain)
  local owner = world[domain]
  if type(owner) ~= "table" then
    missingOwner(domain)
  end
  assert(type(owner) == "table", "service branches borrow their domain owner")
  return owner --[[@as table<string, unknown>]]
end

-- Selects the service program identity for one named contact family.
-- Pure dispatch over labelled facts with no owner reads; owner-gated
-- branches resolve their production program here and preflight the
-- owner at the program stage through step.
---@param family string named service family
---@param facts table<string, unknown> labelled source facts for the caller
---@return string program identity
function ServicePhonePrograms.selectName(family, facts)
  assert(type(family) == "string" and family ~= "", "service selection names its contact family")
  assert(type(facts) == "table", "service selection reads labelled facts")
  if family == "bill" then
    if facts.acknowledged == true then
      return "bill-greeting"
    end
    if facts.pcFreeSlots == 0 then
      return "bill-full"
    end
    if facts.pcFreeSlots ~= nil then
      return "bill-advice"
    end
    return "bill-greeting"
  end
  if family == "buena" then
    if facts.takeover == true or facts.closed == true then
      return "buena-closed"
    end
    if facts.passwordKnown == true then
      return "buena-reward"
    end
    if facts.blueCard == true then
      return "buena-password"
    end
    return "buena-greeting"
  end
  if family == "kurt" then
    if facts.aboutProduction == true then
      return "kurt-production"
    end
    return "kurt-greeting"
  end
  if family == "daycare" then
    if facts.aboutEgg == true then
      return "daycare-egg"
    end
    return "daycare-greeting"
  end
  if family == "bike" then
    if facts.acknowledged == true then
      return "bike-greeting"
    end
    if facts.hasBicycle == true then
      return "bike-owned"
    end
    return "bike-offer"
  end
  if family == "friend" then
    if facts.subject ~= nil then
      return "friend-topic"
    end
    return "friend-greeting"
  end
  if family == "baoba" then
    if facts.safariTest == true then
      return "baoba-test"
    end
    return "baoba-greeting"
  end
  error("service selection covers the named service families", 0)
end

-- Programs whose branch reads production state, preflighted at the
-- program stage before any effect. Local branches are absent here and
-- resolve without an owner.
local PRODUCTION_PROGRAMS = {
  ["kurt-production"] = "kurt",
  ["daycare-egg"] = "daycare",
  ["baoba-test"] = "safari",
  ["bill-advice"] = "pc",
  ["bill-full"] = "pc",
  ["buena-reward"] = "buena",
  ["buena-password"] = "buena",
}

-- Opens a service program session over the borrowed world. Selection
-- itself never mutates and never requires an owner; the program stage
-- preflights the branch owner through step before any effect.
---@param world table<string, unknown> borrowed world table
---@param request { contact: string, family: string, facts: table<string, unknown> }
---@return table<string, unknown> program session
function ServicePhonePrograms.select(world, request)
  assert(type(world) == "table", "service programs borrow their world")
  assert(type(request) == "table" and type(request.contact) == "string", "service programs name their contact")
  assert(type(request.family) == "string", "service programs name their contact family")
  assert(type(request.facts) == "table", "service programs read labelled facts")
  return {
    program = ServicePhonePrograms.selectName(request.family, request.facts),
    contact = request.contact,
    family = request.family,
    world = world,
    effectDone = false,
  }
end

-- Advances one program step. Production branches preflight their owner
-- first: a missing owner fails with attribution and changes nothing.
-- Service branches carry no other world effect. Returns done once the
-- branch has resolved.
---@param session table<string, unknown>
---@param input table<string, unknown>
---@return string "done"
function ServicePhonePrograms.step(session, input)
  assert(type(session) == "table", "service programs step their session")
  assert(type(input) == "table", "service programs read their input")
  assert(type(session.program) == "string", "service sessions carry their program")
  if session.effectDone == true then
    return "done"
  end
  local program = session.program --[[@as string]]
  local domain = PRODUCTION_PROGRAMS[program]
  if domain ~= nil then
    local world = session.world --[[@as table<string, unknown>]]
    assert(type(world) == "table", "service effects stage through the borrowed world")
    domainOwner(world, domain)
  end
  session.effectDone = true
  return "done"
end

return ServicePhonePrograms
