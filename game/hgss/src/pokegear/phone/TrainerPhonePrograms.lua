-- Trainer policies: ordinary callers, gym leaders, Kenji, and Irwin,
-- plus the single rematch policy shared by outgoing invitations,
-- incoming-call effects, the field rematch query, and map markers.
-- Registration is never readiness: only a staged invitation makes a
-- contact ready, and the source resolves it to a native trainer tier
-- from the generated rematch sets until the script clears the seeking.
-- Pure source policy over the borrowed world table, private to the
-- foreground phone feature.

---@class TrainerPhonePrograms
local TrainerPhonePrograms = {}

TrainerPhonePrograms.DEFAULT_GYM_WEEKDAY = "saturday"

-- Native rematch set sentinels (src/trainer_rematch.c): TRAINER_NONE ends the
-- unbeaten scan and 0xFFFF is a hole the scan skips.
TrainerPhonePrograms.TRAINER_NONE = 0
TrainerPhonePrograms.REMATCH_HOLE = 0xFFFF
TrainerPhonePrograms.REMATCH_ENTRIES = 6
-- The Kenji phonebook contact: alone among the callers, his invitation also
-- waits for the source daytime band (src/phone_rematch.c).
TrainerPhonePrograms.KENJI_CONTACT_ID = 0x10
TrainerPhonePrograms.TIMEOFDAY_DAY = 1

-- The dynamic gym-outgoing menu answers behind touchscreen menu 6
-- (bank-271 entries 18/19, Yes/No).
TrainerPhonePrograms.GYM_MENU_CHOICES = { "yes", "no" }

-- Resolves the dynamic gym outgoing opener bank entry 2.
---@return integer gym bank entry for the opener
function TrainerPhonePrograms.gymOutgoingOpenerEntry()
  return 2
end

-- Resolves the dynamic gym outgoing branch bank entry: 3 below
-- sixteen badges, 9 while the caller seeks a rematch, 4 outside the
-- rematch window, else the invitation 5 with the yes/no menu owed.
---@param hasBadges boolean sixteen-badge gate behind flag0
---@param seeking boolean staged rematch invitation behind flag1
---@param windowOk boolean rematch weekday and time match
---@return integer gym bank entry for the branch
function TrainerPhonePrograms.gymOutgoingBranchEntry(hasBadges, seeking, windowOk)
  if hasBadges ~= true then
    return 3
  end
  if seeking == true then
    return 9
  end
  if windowOk ~= true then
    return 4
  end
  return 5
end

-- Replicates the source dojo-full quirk exactly: the loop runs once
-- over the first compiled gym contact by source bug, and the
-- comparison keeps the source count<5 shape, so a yes always stages
-- the invitation with entry 6 and the room branch stays unreachable
-- as shipped (phone_scripts_gym_leader.c isDojoFull).
---@param callerKey string calling contact key
---@param firstKey string first compiled gym contact key
---@param firstSeeking boolean staged invitation on the first contact
---@return boolean dojo full
function TrainerPhonePrograms.gymDojoFull(callerKey, firstKey, firstSeeking)
  local count = 0
  -- Single-iteration source loop: only the first gym contact counts.
  if callerKey ~= firstKey and firstSeeking == true then
    count = count + 1
  end
  return count < 5
end

-- Resolves the dynamic gym outgoing answer bank entry: 7 on no,
-- 6 on yes with the staged invitation, else the unreachable room 8.
---@param answer string "yes"|"no" menu answer
---@param dojoFull boolean source dojo-full reading
---@return integer gym bank entry for the answer
function TrainerPhonePrograms.gymOutgoingAnswerEntry(answer, dojoFull)
  assert(answer == "yes" or answer == "no", "gym answers name their menu choice")
  if answer == "no" then
    return 7
  end
  if dojoFull == true then
    return 6
  end
  return 8
end

-- Advances the dynamic gym-outgoing menu: no answer waits, no ends
-- with 7 and no write, yes stages the seeking invitation with 6
-- behind the source always-full reading. Wins carry over from the
-- staged record exactly like the static rematch kind.
---@param session table<string, unknown> program session
---@param input table<string, unknown> player input
---@return string|{ status: string, entry: integer? } outcome
function TrainerPhonePrograms.stepGymMenu(session, input)
  assert(type(session) == "table", "gym menu steps its session")
  assert(type(input) == "table", "gym menu reads its input")
  local choice = input.choice
  if choice == nil then
    return { status = "waiting" }
  end
  assert(choice == "yes" or choice == "no", "gym answers name their menu choice")
  local facts = session.facts --[[@as table<string, unknown>]]
  assert(type(facts) == "table", "gym answers read their labelled facts")
  session.effectDone = true
  if choice == "no" then
    return { status = "done", entry = 7 }
  end
  local full = facts.dynamicGymDojoFull
  assert(type(full) == "boolean", "gym answers read the staged dojo reading")
  if full ~= true then
    return { status = "done", entry = 8 }
  end
  local world = session.world --[[@as table<string, unknown>]]
  assert(type(world) == "table", "gym invitations stage through the borrowed world")
  local setRematch = world.setRematch
  assert(type(setRematch) == "function", "gym invitations stage through durable companion state")
  local contact = session.contact --[[@as string]]
  local wins = 0
  local query = world.queryRematch
  if type(query) == "function" then
    local current = query(world, contact)
    if type(current) == "table" and type(current.wins) == "number" then
      wins = current.wins --[[@as integer]]
    end
  end
  setRematch(world, contact, { stage = 1, wins = wins })
  return { status = "done", entry = 6 }
end

-- Selects the trainer program identity for one named trainer family.
-- Pure dispatch over labelled facts with no owner reads.
---@param family string named trainer family
---@param facts table<string, unknown> labelled source facts for the caller
---@return string program identity
function TrainerPhonePrograms.selectName(family, facts)
  assert(type(family) == "string" and family ~= "", "trainer selection names its contact family")
  assert(type(facts) == "table", "trainer selection reads labelled facts")
  if family == "gym" or family == "rematch" then
    local window = facts.window --[[@as table<string, unknown>?]]
    local weekday = TrainerPhonePrograms.DEFAULT_GYM_WEEKDAY
    local morning = true
    if type(window) == "table" then
      if window.weekday ~= nil then
        assert(type(window.weekday) == "string", "rematch windows name their weekday")
        weekday = window.weekday --[[@as string]]
      end
      if window.morning ~= nil then
        assert(type(window.morning) == "boolean", "rematch windows name their morning half")
        morning = window.morning --[[@as boolean]]
      end
    end
    if facts.weekday == weekday and facts.morning == morning then
      return "gym-rematch"
    end
    return "gym-waiting"
  end
  if family == "kenji" then
    if facts.kenjiActive == true then
      return "kenji-active"
    end
    if facts.waitExpired == true then
      return "kenji-ready"
    end
    return "kenji-waiting"
  end
  if family == "irwin" then
    if facts.storyEvent == true then
      return "irwin-story"
    end
    return "irwin-greeting"
  end
  if facts.invitation == true then
    return "trainer-rematch"
  end
  return "trainer-ordinary"
end

-- Opens a trainer program session over the borrowed world. Selection
-- itself never mutates; invitation readiness stages once at the
-- program stage through step.
---@param world table<string, unknown> borrowed world table
---@param request { contact: string, family: string, facts: table<string, unknown> }
---@return table<string, unknown> program session
function TrainerPhonePrograms.select(world, request)
  assert(type(world) == "table", "trainer programs borrow their world")
  assert(type(request) == "table" and type(request.contact) == "string", "trainer programs name their contact")
  assert(type(request.family) == "string", "trainer programs name their contact family")
  assert(type(request.facts) == "table", "trainer programs read labelled facts")
  return {
    program = TrainerPhonePrograms.selectName(request.family, request.facts),
    contact = request.contact,
    family = request.family,
    world = world,
    facts = request.facts,
    effectDone = false,
  }
end

-- Advances one program step. Invitation and ordinary trainer programs
-- never create an invitation: no generated source record identifies a
-- native invitation stage yet. Returns done once the branch resolves.
---@param session table<string, unknown>
---@param input table<string, unknown>
---@return string|{ status: string, entry: integer? } outcome
function TrainerPhonePrograms.step(session, input)
  assert(type(session) == "table", "trainer programs step their session")
  assert(type(input) == "table", "trainer programs read their input")
  assert(type(session.program) == "string", "trainer sessions carry their program")
  assert(type(session.contact) == "string", "trainer sessions carry their contact")
  local facts = session.facts --[[@as table<string, unknown>]]
  if type(facts) == "table" and facts.dynamicGymMenu == true then
    return TrainerPhonePrograms.stepGymMenu(session, input)
  end
  if session.effectDone == true then
    return "done"
  end
  session.effectDone = true
  return "done"
end

---@param contact string
---@param catalog table<string, unknown>?
---@return { weekday: number, timeOfDay: number }? native contact window
local function catalogWindow(contact, catalog)
  if type(catalog) ~= "table" then
    return nil
  end
  local contacts = catalog.contacts
  if type(contacts) ~= "table" then
    return nil
  end
  for _, entry in
    ipairs(contacts --[[@as table<integer, unknown>]])
  do
    if type(entry) == "table" then
      local record = entry --[[@as table<string, unknown>]]
      if record.key == contact then
        local weekday, timeOfDay = record.rematchWeekday, record.rematchTimeOfDay
        if
          type(weekday) == "number"
          and weekday % 1 == 0
          and weekday >= 0
          and weekday <= 6
          and type(timeOfDay) == "number"
          and timeOfDay % 1 == 0
          and timeOfDay >= 0
          and timeOfDay <= 2
        then
          return { weekday = weekday, timeOfDay = timeOfDay }
        end
        return nil
      end
    end
  end
  return nil
end

-- Reports whether the native weekday and time fields match the live
-- field clock. Missing data cannot manufacture eligibility.
---@param contact string
---@param world table<string, unknown> borrowed world table
---@param catalog table<string, unknown>? borrowed contact catalog
---@return boolean eligible
function TrainerPhonePrograms.eligible(contact, world, catalog)
  assert(type(contact) == "string" and contact ~= "", "rematch eligibility names its contact")
  assert(type(world) == "table", "rematch eligibility reads the borrowed world")
  local window = catalogWindow(contact, catalog)
  if window == nil then
    return false
  end
  local readFacts = world.rematchFacts
  local facts = type(readFacts) == "function" and readFacts(world, contact) or world
  assert(type(facts) == "table", "rematch eligibility reads live contact window facts")
  return facts.weekday == window.weekday and facts.timeOfDay == window.timeOfDay
end

---@param world table<string, unknown>
---@param contact string
---@return { stage: integer, wins: integer }? saved record
local function rematchRecord(world, contact)
  local query = world.queryRematch
  assert(type(query) == "function", "rematch queries read durable companion state")
  return query(world, contact)
end

-- One source entry of a rematch set, addressed by the native rematch number
-- 0..5 where 0 is the set's own base trainer.
---@param entries integer[] six source entries in native order
---@param rematchNo integer native rematch number
---@return integer native trainer identity or sentinel
local function rematchEntry(entries, rematchNo)
  return entries[rematchNo + 1]
end

-- Source GetIndexOfFirstUnbeatenRematch: entries 1..5, TRAINER_NONE ends the
-- scan at the previous entry, and a 0xFFFF hole is never a trainer.
---@param entries integer[] six source entries in native order
---@param defeated fun(trainerNo: integer): boolean live trainer defeat check
---@return integer native rematch number of the first unbeaten entry
function TrainerPhonePrograms.firstUnbeatenRematch(entries, defeated)
  assert(type(entries) == "table", "rematch scans read one source set")
  assert(type(defeated) == "function", "rematch scans read live trainer defeats")
  for rematchNo = 1, TrainerPhonePrograms.REMATCH_ENTRIES - 1 do
    local trainerNo = rematchEntry(entries, rematchNo)
    if trainerNo == TrainerPhonePrograms.TRAINER_NONE then
      return rematchNo - 1
    end
    if trainerNo ~= TrainerPhonePrograms.REMATCH_HOLE and not defeated(trainerNo) then
      return rematchNo
    end
  end
  return TrainerPhonePrograms.REMATCH_ENTRIES - 1
end

-- Source GetPreviousRematchIndexForTrainer: the entry below the given one
-- that is not a hole, else the set's own base trainer.
---@param entries integer[] six source entries in native order
---@param rematchNo integer native rematch number
---@return integer native rematch number
function TrainerPhonePrograms.previousRematch(entries, rematchNo)
  for candidate = rematchNo - 1, 1, -1 do
    if rematchEntry(entries, candidate) ~= TrainerPhonePrograms.REMATCH_HOLE then
      return candidate
    end
  end
  return 0
end

-- Source CheckUnlockedRematchGroup: the base trainer always answers, and a
-- later entry needs its own FLAG_UNK_97B rematch-group flag before it is
-- offered; a locked group falls back to the previous non-hole entry.
---@param world table<string, unknown> borrowed world table
---@param entries integer[] six source entries in native order
---@param rematchNo integer native rematch number
---@return integer native rematch number
local function unlockedRematch(world, entries, rematchNo)
  if rematchNo == 0 then
    return 0
  end
  local unlocked = world.rematchGroupUnlocked
  assert(type(unlocked) == "function", "rematch groups read live unlock flags")
  if unlocked(world, rematchNo) == true then
    return rematchNo
  end
  return TrainerPhonePrograms.previousRematch(entries, rematchNo)
end

-- Source TryGetRematchTrainerIdByBaseTrainerId: the contact's own rematch set,
-- scanned for its first unbeaten entry, then gated by that entry's group.
---@param baseTrainerNo integer the contact's base trainer identity
---@param world table<string, unknown> borrowed world table
---@param catalog table<string, unknown> borrowed contact catalog
---@return integer native trainer identity, or numeric zero without a source set
function TrainerPhonePrograms.rematchTrainerId(baseTrainerNo, world, catalog)
  assert(type(baseTrainerNo) == "number" and baseTrainerNo % 1 == 0, "rematch resolution names its base trainer")
  local sets = catalog.rematches
  assert(type(sets) == "table", "rematch resolution reads the generated rematch sets")
  local entries = sets --[[@as table<integer, integer[]>]][baseTrainerNo]
  if entries == nil then
    return 0
  end
  local defeated = world.trainerDefeated
  assert(type(defeated) == "function", "rematch scans read live trainer defeats")
  local rematchNo = TrainerPhonePrograms.firstUnbeatenRematch(entries, function(trainerNo)
    return defeated(world, trainerNo) == true
  end)
  return rematchEntry(entries, unlockedRematch(world, entries, rematchNo))
end

-- Reads one catalogued contact record, or nil for an unknown contact.
---@param contact string
---@param catalog table<string, unknown>? borrowed contact catalog
---@return table<string, unknown>?
local function catalogContact(contact, catalog)
  if type(catalog) ~= "table" or type(catalog.contacts) ~= "table" then
    return nil
  end
  for _, entry in
    ipairs(catalog.contacts --[[@as table<integer, unknown>]])
  do
    if
      type(entry) == "table" and (entry --[[@as table<string, unknown>]]).key == contact
    then
      return entry --[[@as table<string, unknown>]]
    end
  end
  return nil
end

-- Source PhoneBookTrainerGetRematchInfo: a contact only answers while its
-- seeking record stands; Kenji alone also waits for the source daytime band;
-- the answer is the native trainer identity of the resolved rematch set, or
-- numeric zero when nothing is on offer. The saved seeking record, never an
-- outgoing call window, decides whether an invitation waits.
---@param contact string
---@param world table<string, unknown> borrowed world table
---@param catalog table<string, unknown>? borrowed contact catalog
---@return { ready: boolean, trainerId: integer }
function TrainerPhonePrograms.query(contact, world, catalog)
  assert(type(contact) == "string" and contact ~= "", "rematch queries name their contact")
  assert(type(world) == "table", "rematch queries read the borrowed world")
  local record = rematchRecord(world, contact)
  if type(record) ~= "table" or record.stage <= 0 then
    return { ready = false, trainerId = 0 }
  end
  local entry = catalogContact(contact, catalog)
  assert(type(entry) == "table", "rematch queries read the catalogued contact " .. contact)
  local contactCatalog = assert(catalog, "rematch queries read the catalogued contact " .. contact)
  if entry.id == TrainerPhonePrograms.KENJI_CONTACT_ID then
    local readFacts = world.rematchFacts
    assert(type(readFacts) == "function", "rematch queries read the live time band")
    local facts = readFacts(world, contact)
    assert(type(facts) == "table", "rematch queries read live contact facts")
    if facts.timeOfDay ~= TrainerPhonePrograms.TIMEOFDAY_DAY then
      return { ready = false, trainerId = 0 }
    end
  end
  local trainerNo = entry.trainerId
  assert(type(trainerNo) == "number" and trainerNo % 1 == 0, "catalogued contacts carry their native trainer")
  ---@cast trainerNo integer
  local trainerId = TrainerPhonePrograms.rematchTrainerId(trainerNo, world, contactCatalog)
  return { ready = trainerId ~= 0, trainerId = trainerId }
end

-- Projects the map marker for a contact from the same resolved readiness.
---@param contact string
---@param world table<string, unknown> borrowed world table
---@param catalog table<string, unknown>? borrowed contact catalog
---@return { trainerId: integer, ready: boolean }
function TrainerPhonePrograms.marker(contact, world, catalog)
  local status = TrainerPhonePrograms.query(contact, world, catalog)
  return { trainerId = status.trainerId, ready = status.ready }
end

-- Source ScrCmd_ClearPhoneRematchSeeking: ends the contact's saved invitation
-- while keeping its accumulated win count. Clearing an absent or already
-- cleared invitation leaves the durable owner untouched.
---@param contact string
---@param world table<string, unknown> borrowed world table
---@return { contact: string, ready: boolean }
function TrainerPhonePrograms.clearSeeking(contact, world)
  assert(type(contact) == "string" and contact ~= "", "rematch clears name their contact")
  assert(type(world) == "table", "rematch clears write durable companion state")
  local record = rematchRecord(world, contact)
  if type(record) ~= "table" or record.stage <= 0 then
    return { contact = contact, ready = false }
  end
  local write = world.setRematch
  assert(type(write) == "function", "rematch clears settle through durable companion state")
  write(world, contact, { stage = 0, wins = record.wins })
  return { contact = contact, ready = false }
end

return TrainerPhonePrograms
