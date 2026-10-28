-- Concrete battle result publication: stages every affected owner before
-- publishing, then installs all candidates in one synchronous,
-- non-yielding sequence exactly once per outcome. Callers hand over
-- already-staged preparations (party, bag, dex knowledge), detached
-- records (party updates, captures, rewards, player money facts, roamer
-- outcomes), and the live party owner when captures must be placed. The
-- committer validates everything during preparation; a preparation
-- failure changes no live owner, and a commit failure before publication
-- leaves every owner on its last known-good state. The preparation retains
-- its receipt so a repeated commit does not publish twice. This keeps
-- reward money, ball consumption, party insertion, caught knowledge, and
-- roamer updates never duplicate. No callbacks run between the owner
-- swaps; there is no generic transaction framework here, only the ordered
-- use of the existing owners. Durable saving stays with the save
-- pipeline, which receives the validated player candidate through the
-- receipt.

local Boxes = require("libs.mons.src.Boxes")
local Party = require("libs.mons.src.Party")
local PlayerData = require("libs.hgss.src.save.PlayerData")

---@class HgssBattleCommitter
local HgssBattleCommitter = {}

---@param owner unknown
---@return boolean
local function isPartyOwner(owner)
  return type(owner) == "table"
    and type(owner.partyCount) == "function"
    and type(owner.partyRevision) == "function"
    and type(owner.preparePartyBatch) == "function"
end

-- A spillover-capable owner stages the single PC candidate beside the
-- party batch: box slot reads plus the revision-checked PC preparation.
-- Party-only doubles stay valid where every capture fits the party.
---@param owner unknown
---@return boolean
local function isBoxOwner(owner)
  return type(owner) == "table"
    and type(owner.partyMon) == "function"
    and type(owner.boxCount) == "function"
    and type(owner.activeBox) == "function"
    and type(owner.boxMetadata) == "function"
    and type(owner.boxMon) == "function"
    and type(owner.boxRevision) == "function"
    and type(owner.preparePcChanges) == "function"
end

-- Collects the first free box slots scanning forward from the active box
-- cyclically through the configured boxes, slots ascending. Refuses with
-- capacity context before any publication when storage cannot retain
-- every capture.
---@param owner table<string, unknown> spillover-capable party owner under scanning
---@param partyFree integer free party slots already assigned
---@param needed integer captures still needing a box slot
---@param total integer successful captures under staging
---@return { box: integer, slot: integer }[] free box slots in scan order
local function collectFreeBoxSlots(owner, partyFree, needed, total)
  local boxCount = owner:boxCount()
  local active = owner:activeBox()
  local function exhausted(free)
    error(
      "battle commit captures exceed free party and box storage (partyFree="
        .. tostring(partyFree)
        .. ", boxFree="
        .. tostring(free)
        .. ", captures="
        .. tostring(total)
        .. ")",
      0
    )
  end
  if
    type(boxCount) ~= "number"
    or boxCount % 1 ~= 0
    or boxCount < 1
    or type(active) ~= "number"
    or active % 1 ~= 0
    or active < 0
    or active >= boxCount
  then
    exhausted(0)
  end
  local free = {}
  for offset = 0, boxCount - 1 do
    local box = (active + offset) % boxCount
    for slot = 0, Boxes.SLOTS_PER_BOX - 1 do
      if owner:boxMon(box, slot) == nil then
        free[#free + 1] = { box = box, slot = slot }
        if #free >= needed then
          return free
        end
      end
    end
  end
  exhausted(#free)
  error("unreachable", 0)
end

---@param preparation unknown
---@param what string
local function checkPreparation(preparation, what)
  if type(preparation) ~= "table" then
    error("battle commit " .. what .. " must be a staged preparation", 0)
  end
  local prep = preparation --[[@as { isCurrent: unknown, publish: unknown }]]
  if type(prep.isCurrent) ~= "function" or type(prep.publish) ~= "function" then
    error("battle commit " .. what .. " must expose currency and publication", 0)
  end
  local current = prep.isCurrent()
  if current ~= true then
    error("battle commit " .. what .. " is stale", 0)
  end
end

---@param outcome unknown
---@return string
local function checkOutcome(outcome)
  if type(outcome) ~= "table" then
    error("battle commit requires an outcome record", 0)
  end
  if type(outcome.id) ~= "string" or outcome.id == "" then
    error("battle commit requires a non-empty outcome id", 0)
  end
  if type(outcome.result) ~= "string" or outcome.result == "" then
    error("battle commit requires an outcome result", 0)
  end
  return outcome.id
end

---@generic T
---@param value T
---@return T
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copyValue(item)
  end
  return out
end

---@param capture unknown
---@param index integer
---@return table<string, unknown>?
local function checkCapture(capture, index)
  if type(capture) ~= "table" then
    error("battle commit capture " .. tostring(index) .. " must be a record", 0)
  end
  local entry = capture --[[@as table<string, unknown>]]
  if entry.success ~= true and entry.success ~= false then
    error("battle commit capture " .. tostring(index) .. " carries a success flag", 0)
  end
  if entry.success ~= true then
    return nil
  end
  -- A successful capture keeps its exact caught identity: the full mon
  -- record is mandatory and is never reconstructed from bare fields.
  if type(entry.mon) ~= "table" then
    error("battle commit capture " .. tostring(index) .. " carries the full caught mon on success", 0)
  end
  return entry
end

-- Stages every affected owner and validates the detached records without
-- publishing anything. The returned preparation is committed once through
-- commit; repeating commit reuses the recorded receipt.
---@param args { outcome: { id: string, result: string }, party: table<string, unknown>?, bag: table<string, unknown>?, dex: table<string, unknown>?, stats: table<string, unknown>?, partyOwner: table<string, unknown>?, partyUpdates: { slot: integer, mon: table<string, unknown> }[]?, captures: table<string, unknown>[]?, rewards: table<string, unknown>?, scriptFlags: table<string, unknown>?, player: { record: table<string, unknown>, context: table<string, unknown>, moneyDelta: integer? }?, pokegear: { isCurrent: fun(): boolean, publish: fun(): table<string, unknown> }?, roamer: { owner: table<string, unknown>, key: string, outcome: string, expectedRevision: integer, details: table<string, unknown> }?, stale: boolean? }
---@return table<string, unknown>
function HgssBattleCommitter.prepare(args)
  if type(args) ~= "table" then
    error("battle commit preparation requires an argument record", 0)
  end
  local outcomeId = checkOutcome(args.outcome)
  if args.stale == true then
    error("battle commit preparation found a stale owner revision", 0)
  end
  if args.party ~= nil then
    checkPreparation(args.party, "party candidate")
  end
  if args.bag ~= nil then
    checkPreparation(args.bag, "bag candidate")
  end
  if args.dex ~= nil then
    checkPreparation(args.dex, "dex candidate")
  end
  if args.stats ~= nil then
    checkPreparation(args.stats, "stats candidate")
  end
  local updates = args.partyUpdates or {}
  if type(updates) ~= "table" then
    error("battle commit party updates must be an array when present", 0)
  end
  local captures = {}
  local attempts = 0
  if args.captures ~= nil then
    if type(args.captures) ~= "table" then
      error("battle commit captures must be an array when present", 0)
    end
    for index, capture in ipairs(args.captures) do
      attempts = attempts + 1
      local entry = checkCapture(capture, index)
      if entry ~= nil then
        captures[#captures + 1] = entry
      end
    end
  end
  local owner = nil
  if #updates > 0 or #captures > 0 then
    if args.partyOwner == nil then
      error("battle commit captures and party updates need a party owner", 0)
    end
    if not isPartyOwner(args.partyOwner) then
      error("battle commit party owner must stage party batches", 0)
    end
    owner = args.partyOwner
  end
  if args.party ~= nil and owner ~= nil then
    error("battle commit stages party updates and captures through one batch", 0)
  end
  local ownerBatch = nil
  local ownerPc = nil
  local destinations = {}
  if owner ~= nil then
    -- Every successful capture needs a real destination before any
    -- publication exists: free party slots take captures in input order
    -- first, then the first empty box slots scanning forward from the
    -- active box. Party updates never change the roster size, so live
    -- capacity is the only party bound. Every record's species key is
    -- validated read-only here, before any publication; staged records
    -- pass full validation through the single batch below.
    local capacity = Party.MAX - owner:partyCount()
    if capacity < 0 then
      capacity = 0
    end
    for _, entry in ipairs(captures) do
      local mon = entry.mon --[[@as table<string, unknown>]]
      if type(mon.species) ~= "string" then
        error("battle commit captures name their caught species", 0)
      end
      -- Unknown species fail here, before any publication, through a
      -- read-only lookup that mutates nothing.
      owner:countSpecies(mon.species)
    end
    if #captures <= capacity then
      local appends = {}
      for _, entry in ipairs(captures) do
        appends[#appends + 1] = entry.mon
      end
      if #updates > 0 or #appends > 0 then
        local batch, reason = owner:preparePartyBatch(owner:partyRevision(), updates, appends)
        if batch == nil then
          error("battle commit party batch went stale: " .. tostring(reason), 0)
        end
        ownerBatch = batch
      end
      local baseSlot = owner:partyCount()
      for index, entry in ipairs(captures) do
        destinations[#destinations + 1] = {
          captureId = entry.captureId,
          destination = "party",
          partySlot = baseSlot + index - 1,
          mon = entry.mon,
        }
      end
    else
      -- Party-full or overflow: one PC staging carries the complete
      -- candidate roster (live party plus battle updates plus the
      -- party-destined appends) with explicit box updates, never
      -- separate conflicting party and PC candidates.
      if not isBoxOwner(owner) then
        error("battle commit captures exceed free party slots without storage", 0)
      end
      local freeSlots = collectFreeBoxSlots(owner, capacity, #captures - capacity, #captures)
      local activeBox = owner:activeBox()
      local activeMetadata = owner:boxMetadata(activeBox)
      assert(type(activeMetadata.name) == "string", "the active PC box carries its displayed name")
      local roster = {}
      for slot = 0, owner:partyCount() - 1 do
        roster[#roster + 1] = owner:partyMon(slot)
      end
      for _, update in ipairs(updates) do
        roster[update.slot + 1] = update.mon
      end
      for index = 1, capacity do
        local mon = captures[index].mon
        roster[#roster + 1] = mon
        destinations[#destinations + 1] = {
          captureId = captures[index].captureId,
          destination = "party",
          partySlot = owner:partyCount() + index - 1,
          mon = mon,
        }
      end
      local boxUpdates = {}
      for position = capacity + 1, #captures do
        local free = freeSlots[position - capacity]
        local boxMetadata = owner:boxMetadata(free.box)
        assert(type(boxMetadata.name) == "string", "the destination PC box carries its displayed name")
        boxUpdates[#boxUpdates + 1] = { box = free.box, slot = free.slot, mon = captures[position].mon }
        destinations[#destinations + 1] = {
          captureId = captures[position].captureId,
          destination = "box",
          box = free.box,
          slot = free.slot,
          pcHasSpace = free.box == activeBox,
          previousBoxName = activeMetadata.name,
          boxName = boxMetadata.name,
          mon = captures[position].mon,
        }
      end
      local pc, reason = owner:preparePcChanges({
        partyRevision = owner:partyRevision(),
        boxRevision = owner:boxRevision(),
      }, { party = roster, boxUpdates = boxUpdates })
      if pc == nil then
        error("battle commit party and box staging went stale: " .. tostring(reason), 0)
      end
      ownerPc = pc
    end
  end
  local playerCandidate = nil
  if args.player ~= nil then
    if type(args.player) ~= "table" then
      error("battle commit player changes must be a record when present", 0)
    end
    playerCandidate = PlayerData.prepareBattleChanges(args.player.record, args.player.context, {
      moneyDelta = args.player.moneyDelta or 0,
    })
  end
  local roamer = args.roamer
  if roamer ~= nil then
    if type(roamer) ~= "table" or type(roamer.owner) ~= "table" then
      error("battle commit roamer outcomes name their owning state", 0)
    end
  end
  local pokegearCandidate = nil
  if args.pokegear ~= nil then
    checkPreparation(args.pokegear, "pokegear candidate")
    pokegearCandidate = args.pokegear
  end
  if
    args.party == nil
    and args.bag == nil
    and args.dex == nil
    and args.stats == nil
    and ownerBatch == nil
    and attempts == 0
    and args.rewards == nil
    and args.player == nil
    and pokegearCandidate == nil
    and roamer == nil
  then
    error("battle commit preparation stages at least one result", 0)
  end
  local staged = {
    outcomeId = outcomeId,
    outcome = copyValue(args.outcome),
    party = args.party,
    bag = args.bag,
    dex = args.dex,
    stats = args.stats,
    pokegear = pokegearCandidate,
    owner = owner,
    ownerBatch = ownerBatch,
    ownerPc = ownerPc,
    captures = captures,
    destinations = destinations,
    rewards = copyValue(args.rewards),
    scriptFlags = copyValue(args.scriptFlags) or {},
    playerCandidate = playerCandidate,
    roamer = roamer,
  }
  return staged --[[@as CommitPreparation]]
end

---@class CommitPreparation
---@field outcomeId string
---@field outcome table<string, unknown>
---@field party { isCurrent: fun(): boolean, publish: fun() }?
---@field bag { isCurrent: fun(): boolean, publish: fun() }?
---@field dex { isCurrent: fun(): boolean, publish: fun() }?
---@field stats { isCurrent: fun(): boolean, publish: fun() }?
---@field pokegear { isCurrent: fun(): boolean, publish: fun(): table<string, unknown> }?
---@field owner HgssMonService?
---@field ownerBatch { isCurrent: fun(): boolean, publish: fun() }?
---@field ownerPc { isCurrent: fun(): boolean, publish: fun() }?
---@field captures table<string, unknown>[]
---@field destinations table<string, unknown>[]
---@field rewards table<string, unknown>?
---@field scriptFlags table<string, unknown>
---@field playerCandidate table<string, unknown>?
---@field roamer { owner: table<string, unknown>, key: string, outcome: string, expectedRevision: integer, details: table<string, unknown> }?
---@field receipt table<string, unknown>?

---@param preparation unknown
---@param what string
---@return (fun())?
local function checkedPublish(preparation, what)
  if preparation == nil then
    return nil
  end
  checkPreparation(preparation, what)
  local prep = preparation --[[@as { publish: fun() }]]
  local publish = prep.publish
  assert(type(publish) == "function", "battle commit " .. what .. " publishes")
  return publish
end

---@param prepared CommitPreparation
---@return table<string, unknown>
function HgssBattleCommitter.commit(prepared)
  if type(prepared) ~= "table" or type(prepared.outcomeId) ~= "string" then
    error("battle commit consumes a staged preparation", 0)
  end
  assert(type(prepared) == "table", "commit reads its staged preparation")
  local staged = prepared --[[@as CommitPreparation]]
  if staged.receipt ~= nil then
    return staged.receipt
  end
  local publishParty = checkedPublish(staged.party, "party candidate")
  local publishBag = checkedPublish(staged.bag, "bag candidate")
  local publishDex = checkedPublish(staged.dex, "dex candidate")
  local publishStats = checkedPublish(staged.stats, "stats candidate")
  local publishBatch = checkedPublish(staged.ownerBatch, "party batch")
  local publishPc = checkedPublish(staged.ownerPc, "party and box candidate")
  if publishBatch ~= nil and publishPc ~= nil then
    error("battle commit stages party updates and captures through one batch", 0)
  end
  local publishPokegear = checkedPublish(staged.pokegear, "pokegear candidate")
  -- The fallible roamer writeback runs before any owner swap, so its
  -- rejection leaves every live owner on the last known-good state.
  local roamerResult = nil
  if staged.roamer ~= nil then
    local roamerOwner = staged.roamer.owner
    local apply = roamerOwner.prepareResult
    assert(type(apply) == "function", "roamer outcomes commit through their owner")
    roamerResult = apply(
      roamerOwner,
      staged.roamer.key,
      staged.roamer.outcome,
      staged.roamer.expectedRevision,
      staged.roamer.details
    )
  end
  -- The companion savings publication runs first among the swaps, so
  -- its rejection still leaves party, bag, and dex on last known-good.
  local pokegearResult = nil
  if publishPokegear ~= nil then
    pokegearResult = publishPokegear()
  end
  if publishParty ~= nil then
    publishParty()
  end
  if publishBag ~= nil then
    publishBag()
  end
  if publishDex ~= nil then
    publishDex()
  end
  if publishStats ~= nil then
    publishStats()
  end
  if publishBatch ~= nil then
    publishBatch()
  end
  if publishPc ~= nil then
    publishPc()
  end
  local placements = {}
  -- Preparation assigned every successful capture its exact destination
  -- in input order, so each placement keys its capture identity to the
  -- party or box slot the single staged candidate published.
  for _, assigned in ipairs(staged.destinations or {}) do
    local record = assigned --[[@as table<string, unknown>]]
    if record.destination == "box" then
      placements[#placements + 1] = {
        captureId = record.captureId,
        retained = true,
        destination = "box",
        box = record.box,
        slot = record.slot,
        pcHasSpace = record.pcHasSpace,
        previousBoxName = record.previousBoxName,
        boxName = record.boxName,
        reason = "retained",
      }
    else
      placements[#placements + 1] = {
        captureId = record.captureId,
        retained = true,
        destination = "party",
        partySlot = record.partySlot,
        reason = "retained",
      }
    end
  end
  local receipt = {
    outcomeId = staged.outcomeId,
    committed = true,
    placements = placements,
    rewards = copyValue(staged.rewards),
    scriptFlags = copyValue(staged.scriptFlags),
    player = copyValue(staged.playerCandidate),
    pokegear = copyValue(pokegearResult),
    roamer = copyValue(roamerResult),
  }
  staged.receipt = receipt
  return receipt
end

return HgssBattleCommitter
