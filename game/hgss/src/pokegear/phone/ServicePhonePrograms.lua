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

-- Resolves the dynamic Bill intro bank entry: the gendered pair 3
-- (male) / 4 (female) behind GearPhoneCall_Bill case 1. An unknown
-- gender defaults to the male entry, mirroring the local friend
-- branch.
---@param facts table<string, unknown> labelled source facts for the caller
---@return integer bank-665 entry for the intro
function ServicePhonePrograms.billIntroEntry(facts)
  assert(type(facts) == "table", "bill intro reads labelled facts")
  local gender = facts.playerGender
  if gender == "female" or gender == 1 then
    return 4
  end
  return 3
end

-- Resolves the dynamic Bill box-status bank entry: 9 when the active
-- box set is full, else one of 5/6/7 behind the source LCRandom()%3.
---@param freeSlots integer empty spots across all boxes
---@param roll integer 0..2 source draw
---@return integer bank-665 entry for the status
function ServicePhonePrograms.billStatusEntry(freeSlots, roll)
  assert(type(freeSlots) == "number" and freeSlots % 1 == 0, "bill status reads the free box count")
  assert(type(roll) == "number" and roll % 1 == 0 and roll >= 0 and roll <= 2, "bill status reads its source draw")
  if freeSlots == 0 then
    return 9
  end
  return 5 + roll
end

-- Resolves the dynamic Bill closer bank entry behind case 3.
---@return integer bank-665 entry for the closer
function ServicePhonePrograms.billCloserEntry()
  return 8
end

-- The source map order behind GearPhoneCall_EthanLyra: the 73 map
-- identities whose caller location prints entries 13..85
-- (ov101_021F86CC order, native map ids).
ServicePhonePrograms.FRIEND_LOCATION_MAPS = {
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  16,
  17,
  18,
  19,
  20,
  21,
  22,
  23,
  24,
  25,
  26,
  91,
  92,
  93,
  27,
  28,
  29,
  30,
  31,
  32,
  33,
  34,
  35,
  36,
  37,
  38,
  39,
  40,
  41,
  42,
  43,
  94,
  95,
  44,
  45,
  46,
  47,
  48,
  151,
  152,
  49,
  50,
  51,
  52,
  53,
  54,
  55,
  56,
  57,
  58,
  59,
  60,
  67,
  73,
  74,
  75,
  76,
  77,
  78,
  87,
  88,
  89,
  90,
  96,
  113,
  174,
}

-- The source region availability behind EthanLyra2 random messages:
-- one condition per location-table row (gEthanLyraRandomMsgConditions
-- order). Row 0 always shows; 1 needs the flypoint; 2 needs any map
-- unlock; 3 needs the second unlock tier.
ServicePhonePrograms.FRIEND_REGION_CONDITIONS = {
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  2,
  2,
  3,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  1,
  1,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  2,
  3,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  1,
}

-- The source apricorn-to-ball identity behind Kurt's status line:
-- sApricornBallItems order (red, yellow, blue, green, pink, white,
-- black) keyed by the project apricorn catalog keys.
ServicePhonePrograms.KURT_APRICORN_BALLS = {
  RED_APRICORN = "LEVEL_BALL",
  YELLOW_APRICORN = "MOON_BALL",
  BLUE_APRICORN = "LURE_BALL",
  GREEN_APRICORN = "FRIEND_BALL",
  PINK_APRICORN = "LOVE_BALL",
  WHITE_APRICORN = "FAST_BALL",
  BLACK_APRICORN = "HEAVY_BALL",
}

-- Resolves the dynamic Buena incoming intro bank entry: the gendered
-- time-of-day pair 3/5/7 (male) or 4/6/8 (female). An unknown gender
-- defaults to the male entry, mirroring the local friend branch.
---@param gender unknown player gender fact
---@param timeOfDay integer 0..2 source time band
---@return integer bank-641 entry for the intro
function ServicePhonePrograms.buenaIntroEntry(gender, timeOfDay)
  assert(type(timeOfDay) == "number" and timeOfDay % 1 == 0, "buena intro reads the source time band")
  local base = 3 + timeOfDay * 2
  if gender == "female" or gender == 1 then
    return base + 1
  end
  return base
end

-- Resolves the dynamic Buena incoming extra bank entry 10..12 behind
-- the source LCRandom()%3.
---@param roll integer 0..2 source draw
---@return integer bank-641 entry for the extra
function ServicePhonePrograms.buenaExtraEntry(roll)
  assert(type(roll) == "number" and roll % 1 == 0 and roll >= 0 and roll <= 2, "buena extra reads its source draw")
  return 10 + roll
end

-- Resolves the dynamic Buena outgoing intro bank entry: the gendered
-- time-of-day pair 15/17/19 (male) or 16/18/20 (female).
---@param gender unknown player gender fact
---@param timeOfDay integer 0..2 source time band
---@return integer bank-641 entry for the intro
function ServicePhonePrograms.buena2IntroEntry(gender, timeOfDay)
  assert(type(timeOfDay) == "number" and timeOfDay % 1 == 0, "buena outgoing intro reads the source time band")
  local base = 15 + timeOfDay * 2
  if gender == "female" or gender == 1 then
    return base + 1
  end
  return base
end

-- Resolves the dynamic Buena outgoing body bank entry: 36 while the
-- password is on the air, the gendered 34/35 pair on a roll of 13,
-- else 21 plus the roll. The caller passes the source shared var
-- (password-on-air hour identity) and clear flag with the draw.
---@param sharedU8 integer source password-on-air identity
---@param gameClear boolean clear flag behind the message count
---@param roll integer 0..13 source draw
---@param gender unknown player gender fact
---@return integer bank-641 entry for the body
function ServicePhonePrograms.buena2BodyEntry(sharedU8, gameClear, roll, gender)
  assert(type(sharedU8) == "number" and sharedU8 % 1 == 0, "buena body reads the password-on-air identity")
  assert(type(roll) == "number" and roll % 1 == 0 and roll >= 0, "buena body reads its source draw")
  if sharedU8 == 3 then
    return 36
  end
  local count = gameClear == true and 14 or 11
  assert(roll < count, "buena body draws inside the source message count")
  if roll == 13 then
    if gender == "female" or gender == 1 then
      return 35
    end
    return 34
  end
  return 21 + roll
end

-- Resolves the dynamic friend incoming intro bank entry 4..6 behind
-- the source time of day.
---@param timeOfDay integer 0..2 source time band
---@return integer bank-662 entry for the intro
function ServicePhonePrograms.friendIntroEntry(timeOfDay)
  assert(type(timeOfDay) == "number" and timeOfDay % 1 == 0, "friend intro reads the source time band")
  return 4 + timeOfDay
end

-- Resolves the dynamic friend incoming location bank entry: 13 plus
-- the location-table row for a known caller map, else 10 plus the
-- fallback draw 0..2.
---@param mapId integer? current native map identity
---@param roll integer 0..2 fallback source draw
---@return integer bank-662 entry for the location message
function ServicePhonePrograms.friendLocationEntry(mapId, roll)
  assert(type(roll) == "number" and roll % 1 == 0 and roll >= 0 and roll <= 2, "friend location reads its source draw")
  if type(mapId) == "number" then
    for index, known in ipairs(ServicePhonePrograms.FRIEND_LOCATION_MAPS) do
      if known == mapId then
        return 12 + index
      end
    end
  end
  return 10 + roll
end

-- Resolves the dynamic gym incoming opener bank entry 10.
---@return integer gym bank entry for the opener
function ServicePhonePrograms.gymIncomingOpenerEntry()
  return 10
end

-- Resolves the dynamic gym incoming body bank entry: 11 while the
-- caller seeks a rematch, else 12..14 behind the source LCRandom()%3.
---@param seeking boolean staged rematch invitation
---@param roll integer 0..2 source draw
---@return integer gym bank entry for the body
function ServicePhonePrograms.gymIncomingBodyEntry(seeking, roll)
  assert(type(roll) == "number" and roll % 1 == 0 and roll >= 0 and roll <= 2, "gym body reads its source draw")
  if seeking == true then
    return 11
  end
  return 12 + roll
end

-- Resolves the dynamic Kurt intro bank entry: 6 while the order flag
-- stands, else 2.
---@param flag127 boolean source order flag
---@return integer bank-643 entry for the intro
function ServicePhonePrograms.kurtIntroEntry(flag127)
  if flag127 == true then
    return 6
  end
  return 2
end

-- Resolves the dynamic Kurt status bank entry: 5 with nothing handed
-- over, 4 while the balls are made, else 3 with the staged item name
-- and quantity.
---@param quantity integer handed-over apricorn count
---@param making boolean ball-making flag
---@return integer bank-643 entry for the status
function ServicePhonePrograms.kurtStatusEntry(quantity, making)
  assert(type(quantity) == "number" and quantity % 1 == 0 and quantity >= 0, "kurt status reads the handed count")
  if quantity == 0 then
    return 5
  end
  if making == true then
    return 4
  end
  return 3
end

-- Resolves the dynamic Kurt ball item behind the status line:
-- sApricornBallItems order through the handed apricorn identity. An
-- unknown apricorn fails loudly instead of inventing a ball.
---@param apricorn string project apricorn catalog key
---@return string project item catalog key for the ball
function ServicePhonePrograms.kurtBallItem(apricorn)
  local ball = ServicePhonePrograms.KURT_APRICORN_BALLS[apricorn]
  assert(type(ball) == "string" and ball ~= "", "kurt orders name a known apricorn, got " .. tostring(apricorn))
  return ball
end

-- Reads and validates the Kurt apricorn owner behind the status line:
-- the handed quantity with its apricorn identity. An absent owner
-- fails with attribution instead of an invented empty box.
---@param world table<string, unknown> borrowed world table
---@return { quantity: integer, apricorn: string? } handed order
function ServicePhonePrograms.kurtPending(world)
  assert(type(world) == "table", "kurt status borrows its world")
  local read = world.read
  assert(type(read) == "function", "kurt status reads its apricorn owner")
  local pending = read(world, "kurt.pending")
  assert(type(pending) == "table", "kurt orders resolve through the apricorn owner")
  local quantity = (pending --[[@as table<string, unknown>]]).quantity
  assert(type(quantity) == "number" and quantity % 1 == 0 and quantity >= 0, "kurt status reads the handed count")
  local apricorn = (pending --[[@as table<string, unknown>]]).apricorn
  if quantity > 0 then
    assert(type(apricorn) == "string" and apricorn ~= "", "a kurt order names its apricorn")
  end
  return { quantity = quantity, apricorn = apricorn }
end

-- Resolves the dynamic friend outgoing intro bank entry 7..9 behind
-- the source time of day.
---@param timeOfDay integer 0..2 source time band
---@return integer bank-662 entry for the intro
function ServicePhonePrograms.friendOutgoingIntroEntry(timeOfDay)
  assert(type(timeOfDay) == "number" and timeOfDay % 1 == 0, "friend outgoing intro reads the source time band")
  return 7 + timeOfDay
end

-- Resolves the dynamic friend outgoing fixed bank entry 10..12 behind
-- the source (LCRandom()%900)/300 draw.
---@param roll integer 0..899 source draw
---@return integer bank-662 entry for the fixed message
function ServicePhonePrograms.friendFixedEntry(roll)
  assert(type(roll) == "number" and roll % 1 == 0 and roll >= 0 and roll < 900, "friend fixed reads its source draw")
  return 10 + math.floor(roll / 300)
end

-- Resolves the dynamic friend outgoing region bank entry 86..158:
-- the candidate rows whose availability class the unlock state opens,
-- picked by the source LCRandom()%count draw. An empty candidate set
-- fails loudly instead of dividing by zero.
---@param available table<integer, boolean> open availability classes 0..3
---@param roll integer 0..count-1 source draw
---@return integer bank-662 entry for the region message
function ServicePhonePrograms.friendRegionEntry(available, roll)
  assert(type(available) == "table", "friend regions read their unlock state")
  assert(type(roll) == "number" and roll % 1 == 0 and roll >= 0, "friend regions read their source draw")
  local candidates = {}
  for index, class in ipairs(ServicePhonePrograms.FRIEND_REGION_CONDITIONS) do
    if available[class] == true then
      candidates[#candidates + 1] = index - 1
    end
  end
  assert(#candidates > 0, "friend regions open at least one candidate row")
  assert(roll < #candidates, "friend regions draw inside the candidate count")
  return 86 + candidates[roll + 1]
end

-- Reads and validates the daycare owner behind the Day Care
-- conversations: the stabled count with per-mon nicknames and level
-- growth, the pending egg, and the breeding compatibility 0..3. An
-- absent owner fails with attribution instead of an invented empty
-- daycare.
---@param world table<string, unknown> borrowed world table
---@return { count: integer, egg: boolean, compatibility: integer, nicknames: string[], growths: integer[] } daycare status
function ServicePhonePrograms.daycareStatus(world)
  assert(type(world) == "table", "daycare status borrows its world")
  local read = world.read
  assert(type(read) == "function", "daycare status reads its daycare owner")
  local status = read(world, "daycare.status")
  assert(type(status) == "table", "daycare status resolves through the daycare owner")
  local clean = status --[[@as table<string, unknown>]]
  local count = clean.count
  assert(
    type(count) == "number" and count % 1 == 0 and count >= 0 and count <= 2,
    "daycare status reads its stabled count"
  )
  local egg = clean.egg == true
  local compatibility = clean.compatibility or 0
  assert(
    type(compatibility) == "number" and compatibility % 1 == 0 and compatibility >= 0 and compatibility <= 3,
    "daycare status reads its breeding compatibility"
  )
  local nicknames = clean.nicknames
  assert(type(nicknames) == "table", "daycare status reads its stabled nicknames")
  local growths = clean.growths
  assert(type(growths) == "table", "daycare status reads its level growth")
  for index = 1, count do
    assert(type(nicknames[index]) == "string" and nicknames[index] ~= "", "daycare status names every stabled mon")
    assert(
      type(growths[index]) == "number" and growths[index] % 1 == 0 and growths[index] >= 0,
      "daycare status grows every stabled mon"
    )
  end
  return {
    count = count,
    egg = egg,
    compatibility = compatibility,
    nicknames = nicknames,
    growths = growths,
  }
end

-- Resolves the dynamic Day Care Man entry sequence: the opener 2,
-- then the egg message 3, the empty 4, the single-mon 5, or the pair
-- 6 with the compatibility message 7..10, always closed by 11 except
-- on the egg branch.
---@param status { count: integer, egg: boolean, compatibility: integer } daycare status
---@return integer[] bank-661 entries in source order
function ServicePhonePrograms.daycareManEntries(status)
  assert(type(status) == "table", "daycare man reads its daycare status")
  if status.egg == true then
    return { 2, 3 }
  end
  if status.count == 0 then
    return { 2, 4, 11 }
  end
  if status.count == 1 then
    return { 2, 5, 11 }
  end
  return { 2, 6, 7 + status.compatibility, 11 }
end

-- Resolves the dynamic Day Care Lady gendered intro: 3 (male) or 4
-- (female). An unknown gender defaults to the male entry, mirroring
-- the local friend branch.
---@param gender unknown player gender fact
---@return integer bank-660 entry for the intro
function ServicePhonePrograms.daycareLadyIntroEntry(gender)
  if gender == "female" or gender == 1 then
    return 4
  end
  return 3
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
