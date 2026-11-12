-- Owns atomic custody changes for authored Mail across Party, Mailbox, Bag,
-- and GameStats. Ordinary held-item replacement, Bag capacity accounting,
-- and canonical held-item form effects ride the existing Party/Bag owners;
-- the written-Mail count rides the shared stats owner. Fresh letters enter
-- only through the composition boundary: previewComposition answers
-- eligibility without mutating or retaining an intent, and only a final
-- complete draft earns a one-use compose intent. Nothing publishes until
-- every prepared candidate is current, and no optimistic take/rollback
-- ever runs: a failure before publication changes none of Party, Bag, or
-- stats. The already-committed Mailbox erase is a separate completed
-- transaction outside this invariant.
local Mail = require("libs.mons.src.gen4.Mail")
local MailTemplate = require("libs.hgss.src.field.MailTemplate")
local HeldItemFormPolicy = require("libs.hgss.src.mons.HeldItemFormPolicy")

local MailActions = {}
MailActions.__index = MailActions

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, child in pairs(value) do
    out[key] = copy(child)
  end
  return out
end

local function same(left, right)
  if type(left) ~= type(right) then
    return false
  end
  if type(left) ~= "table" then
    return left == right
  end
  for key, value in pairs(left) do
    if not same(value, right[key]) then
      return false
    end
  end
  for key in pairs(right) do
    if left[key] == nil then
      return false
    end
  end
  return true
end

function MailActions.new(deps)
  assert(type(deps) == "table", "Mail actions require collaborators")
  local mons = assert(deps.mons)
  local mailbox = assert(deps.mailbox)
  local bag = assert(deps.bag)
  local manifest = assert(deps.manifest)
  local stationery = assert(manifest.mail.stationery)
  return setmetatable({
    mons = mons,
    mailbox = mailbox,
    bag = bag,
    stationery = stationery,
    catalog = deps.catalog,
    gameStats = deps.gameStats,
    nextToken = 0,
  }, MailActions)
end

function MailActions:revisionSnapshot()
  return {
    partyRevision = self.mons:partyRevision(),
    mailboxRevision = self.mailbox:revision(),
    bagRevision = self.bag:revision(),
  }
end

local function result(kind, fields)
  local value = fields or {}
  value.kind = kind
  return value
end

-- Existing give display facts: the held item, the stored form, and the
-- derived maximum HP through the mon service.
function MailActions:_displayFacts(mon)
  assert(type(mon.heldItem) == "string", "display facts require the held item")
  assert(type(mon.form) == "number", "display facts require the stored form")
  return { heldItem = mon.heldItem, form = mon.form, maxHp = self.mons:derive(mon).maxHp }
end

function MailActions:_itemKey(letter)
  local stationery = assert(self.stationery[letter.type], "mail stationery is compiled")
  local itemKey = assert(stationery.itemKey, "mail stationery has a semantic item key")
  self.bag:catalog():item(itemKey)
  return itemKey
end

-- Resolves one stationery item key to its matching compiled type 0..11,
-- or nil when the key names no stationery.
---@param itemKey string
---@return integer?
function MailActions:_stationeryType(itemKey)
  for stationeryType = 0, 11 do
    local record = self.stationery[stationeryType]
    if record ~= nil and record.itemKey == itemKey then
      return stationeryType
    end
  end
  return nil
end

function MailActions:_isMail(itemKey)
  return self.bag:catalog():item(itemKey).pocket == "mail"
end

-- Shared composition eligibility for the preflight and the final draft.
-- Never mutates and retains no intent. Replacement consent precedes the
-- Bag capacity test: an unconfirmed ordinary held item answers
-- needs_confirmation before capacity is examined, and only a confirmed
-- replacement tests the return fit. The letter rides only the final
-- draft; the preflight carries none and creates no stored intent.
---@param request table<string, unknown>
---@return table<string, unknown> eligibility { status:"ready"|"needs_confirmation", stationeryType, recipient, before } or { status:"refused", reason }
function MailActions:_compositionEligibility(request)
  if request.partyRevision ~= self.mons:partyRevision() then
    return { status = "refused", reason = "stale" }
  end
  if request.bagRevision ~= self.bag:revision() then
    return { status = "refused", reason = "stale" }
  end
  local itemKey = assert(request.itemKey, "composition carries its stationery")
  local stationeryType = self:_stationeryType(itemKey)
  if stationeryType == nil then
    return { status = "refused", reason = "missing_stationery" }
  end
  local recipient = self.mons:partyMon(assert(request.targetSlot, "composition names its recipient slot"))
  if recipient == nil or recipient.isEgg then
    return { status = "refused", reason = "ineligible_recipient" }
  end
  if self:_isMail(recipient.heldItem) then
    return { status = "refused", reason = "recipient_holds_mail" }
  end
  local before = self:_displayFacts(recipient)
  if recipient.heldItem ~= "NONE" and request.confirmed ~= true then
    return { status = "needs_confirmation", stationeryType = stationeryType, recipient = recipient, before = before }
  end
  if recipient.heldItem ~= "NONE" then
    if not self.bag:hasSpace(recipient.heldItem, 1) then
      return { status = "refused", reason = "bag_full" }
    end
  end
  if not self.bag:has(itemKey, 1) then
    return { status = "refused", reason = "bag_missing_item" }
  end
  return { status = "ready", stationeryType = stationeryType, recipient = recipient, before = before }
end

-- Preflight for a fresh letter: readiness, replacement consent, or a
-- structured refusal. Carries no letter and creates no stored intent.
---@param request { targetSlot: integer, itemKey: string, partyRevision: integer, bagRevision: integer, confirmed?: boolean }
---@return table<string, unknown>
function MailActions:previewComposition(request)
  assert(type(request) == "table", "composition preflight requires a request")
  local eligibility = self:_compositionEligibility(request)
  if eligibility.status == "ready" then
    return result("ready", { stationeryType = eligibility.stationeryType, before = eligibility.before })
  end
  if eligibility.status == "needs_confirmation" then
    return result("needs_confirmation", { before = eligibility.before })
  end
  return result("refused", { reason = eligibility.reason })
end

function MailActions:_resolve(request)
  assert(type(request) == "table" and type(request.kind) == "string", "mail requests carry a kind")
  if request.kind == "composeGiveMail" then
    local eligibility = self:_compositionEligibility(request)
    if eligibility.status == "refused" then
      return nil, eligibility.reason
    end
    if eligibility.status == "needs_confirmation" then
      return nil, "needs_confirmation", eligibility.before
    end
    local catalog = assert(self.catalog, "composed letters need the shared word catalog")
    local letter = assert(request.letter, "composed give carries its accepted letter")
    local composedOk, reason = MailTemplate.checkComposed(letter, catalog)
    if not composedOk then
      return nil, reason == "incomplete" and "invalid_letter" or (reason or "invalid_letter")
    end
    if letter.type ~= eligibility.stationeryType then
      return nil, "mail_stationery_mismatch"
    end
    return {
      letter = letter,
      itemKey = assert(request.itemKey, "composed give carries its stationery"),
      recipient = eligibility.recipient,
      targetSlot = request.targetSlot,
      partyRevision = self.mons:partyRevision(),
      before = eligibility.before,
    }
  end
  if request.kind == "eraseMailboxMessage" or request.kind == "giveMailboxMail" then
    if request.mailboxRevision ~= self.mailbox:revision() then
      return nil, "stale"
    end
    local letter = self.mailbox:get(assert(request.slot))
    if letter == nil then
      return nil, "empty"
    end
    local itemKey = self:_itemKey(letter)
    if request.kind == "giveMailboxMail" then
      if request.partyRevision ~= self.mons:partyRevision() then
        return nil, "stale"
      end
      local recipient = self.mons:partyMon(assert(request.targetSlot))
      if recipient == nil or recipient.isEgg then
        return nil, "ineligible_recipient"
      end
      if self:_isMail(recipient.heldItem) then
        return nil, "recipient_holds_mail"
      end
      if recipient.heldItem ~= "NONE" then
        return nil, "recipient_holds_item"
      end
      return {
        letter = letter,
        itemKey = itemKey,
        recipient = recipient,
        targetSlot = request.targetSlot,
        mailboxRevision = self.mailbox:revision(),
        partyRevision = self.mons:partyRevision(),
      }
    end
    return { letter = letter, itemKey = itemKey, mailboxRevision = self.mailbox:revision() }
  end
  if request.kind == "readParty" or request.kind == "sendPartyToMailbox" or request.kind == "erasePartyMessage" then
    if request.partyRevision ~= self.mons:partyRevision() then
      return nil, "stale"
    end
    local mon = self.mons:partyMon(assert(request.slot))
    if mon == nil or not Mail.isWritten(mon.mail) then
      return nil, "no_written_message"
    end
    local itemKey = self:_itemKey(mon.mail)
    if mon.heldItem ~= itemKey then
      return nil, "mail_stationery_mismatch"
    end
    return { letter = copy(mon.mail), mon = mon, itemKey = itemKey, partyRevision = self.mons:partyRevision() }
  end
  return nil, "unavailable"
end

function MailActions:preview(request)
  local resolved, reason, before = self:_resolve(request)
  if resolved == nil then
    if reason == "needs_confirmation" then
      return result("needs_confirmation", { before = assert(before, "replacement consent carries its display facts") })
    end
    return result("refused", { reason = reason })
  end
  if request.kind == "readParty" then
    return result("ready", { letter = copy(resolved.letter) })
  end
  if request.kind == "sendPartyToMailbox" then
    if request.mailboxRevision ~= self.mailbox:revision() then
      return result("refused", { reason = "stale" })
    end
    for slot = 0, self.mailbox:count() - 1 do
      if self.mailbox:get(slot) == nil then
        return self:_intent("confirm", request, resolved, "send")
      end
    end
    return result("refused", { reason = "mailbox_full" })
  end
  if request.kind == "eraseMailboxMessage" or request.kind == "erasePartyMessage" then
    if request.bagRevision ~= self.bag:revision() then
      return result("refused", { reason = "stale" })
    end
    return self:_intent("confirm", request, resolved, "erase")
  end
  if request.kind == "giveMailboxMail" then
    return self:_intent("ready", request, resolved, "give")
  end
  if request.kind == "composeGiveMail" then
    if request.bagRevision ~= self.bag:revision() then
      return result("refused", { reason = "stale" })
    end
    return self:_intent("ready", request, resolved, "compose")
  end
  return result("refused", { reason = "unavailable" })
end

function MailActions:_intent(kind, request, resolved, operation)
  self.nextToken = self.nextToken + 1
  local intent = result(kind, {
    token = self.nextToken,
    request = copy(request),
    letter = copy(resolved.letter),
    itemKey = resolved.itemKey,
    operation = operation,
  })
  self.intents = self.intents or {}
  self.intents[intent.token] = copy(intent)
  return intent
end

function MailActions:commit(intent, confirmation)
  assert(type(intent) == "table", "mail commits consume an intent")
  local pending = self.intents and self.intents[intent.token]
  if pending == nil then
    return result("refused", { reason = "stale_intent" })
  end
  if not same(intent, pending) then
    self.intents[intent.token] = nil
    return result("refused", { reason = "stale_intent" })
  end
  if intent.kind == "confirm" and confirmation == false then
    self.intents[intent.token] = nil
    return result("refused", { reason = "declined" })
  end
  -- Ready intents publish without further confirmation: the give and
  -- compose selections already confirmed through the party picker.
  local isDirect = intent.kind == "ready" and (intent.operation == "give" or intent.operation == "compose")
  if (intent.kind ~= "confirm" and not isDirect) or (intent.kind == "confirm" and confirmation ~= true) then
    return result("refused", { reason = "confirmation_required" })
  end
  self.intents[intent.token] = nil
  local request = intent.request
  local resolved, reason = self:_resolve(request)
  if resolved == nil then
    if reason == "needs_confirmation" then
      return result("refused", { reason = "stale" })
    end
    return result("refused", { reason = reason or "stale" })
  end
  if resolved.itemKey ~= intent.itemKey then
    return result("refused", { reason = "stale" })
  end
  if request.kind == "sendPartyToMailbox" then
    if request.mailboxRevision ~= self.mailbox:revision() then
      return result("refused", { reason = "stale" })
    end
    local target
    for slot = 0, self.mailbox:count() - 1 do
      if self.mailbox:get(slot) == nil then
        target = slot
        break
      end
    end
    if target == nil then
      return result("refused", { reason = "mailbox_full" })
    end
    local mon = resolved.mon
    mon.mail, mon.heldItem = {}, "NONE"
    local partyChange = self.mons:preparePartyChanges(request.partyRevision, { { slot = request.slot, mon = mon } })
    local mailboxChange =
      self.mailbox:prepareChanges(request.mailboxRevision, { { slot = target, value = intent.letter } })
    if not partyChange or not mailboxChange or not partyChange.isCurrent() or not mailboxChange.isCurrent() then
      return result("refused", { reason = "stale" })
    end
    partyChange.publish()
    mailboxChange.publish()
    return result("changed", { outcome = "sent", slot = target })
  end
  if request.kind == "giveMailboxMail" then
    local partyChange = self.mons:preparePartyChanges(request.partyRevision, {
      {
        slot = request.targetSlot,
        mon = (function()
          local recipient = resolved.recipient
          recipient.heldItem, recipient.mail = intent.itemKey, copy(intent.letter)
          return recipient
        end)(),
      },
    })
    local mailboxChange =
      self.mailbox:prepareChanges(request.mailboxRevision, { { slot = request.slot, value = false } })
    if not partyChange then
      return result("refused", { reason = "stale" })
    end
    if not partyChange.isCurrent() or not mailboxChange.isCurrent() then
      return result("refused", { reason = "stale" })
    end
    partyChange.publish()
    mailboxChange.publish()
    return result("changed", { outcome = "given", targetSlot = request.targetSlot })
  end
  if request.kind == "composeGiveMail" then
    if request.bagRevision ~= self.bag:revision() then
      return result("refused", { reason = "stale" })
    end
    local gameStats = assert(self.gameStats, "composed letters need the shared stats owner")
    -- The copied recipient carries the letter and its stationery before
    -- the canonical held-item form policy adjusts form, ability, and HP.
    local staged = copy(resolved.recipient)
    staged.heldItem, staged.mail = intent.itemKey, copy(intent.letter)
    local itemDef = self.bag:catalog():item(intent.itemKey)
    staged = HeldItemFormPolicy.apply(staged, itemDef, self.mons)
    local before = resolved.before or self:_displayFacts(resolved.recipient)
    local after = self:_displayFacts(staged)
    -- One stationery removal plus the optional return of the prior
    -- ordinary item: the capacity fit was already verified, so the add
    -- cannot overflow a current Bag.
    local deltas = { { op = "take", item = intent.itemKey, quantity = 1 } }
    if before.heldItem ~= "NONE" then
      deltas[#deltas + 1] = { op = "add", item = before.heldItem, quantity = 1 }
    end
    local bagChange, bagReason = self.bag:prepareInventoryChanges(request.bagRevision, deltas)
    if bagChange == nil then
      return result("refused", { reason = bagReason or "stale" })
    end
    local partyChange =
      self.mons:preparePartyChanges(request.partyRevision, { { slot = request.targetSlot, mon = staged } })
    if partyChange == nil then
      return result("refused", { reason = "stale" })
    end
    local statsChange = gameStats:prepareChanges({ observations = { { kind = "mail_written" } } })
    if not bagChange.isCurrent() or not partyChange.isCurrent() or not statsChange.isCurrent() then
      return result("refused", { reason = "stale" })
    end
    -- No callback, yield, asset operation, or further fallible
    -- derivation runs between these publications.
    partyChange.publish()
    bagChange.publish()
    statsChange.publish()
    return result("changed", {
      outcome = "given",
      targetSlot = request.targetSlot,
      before = before,
      after = after,
    })
  end
  local bagRevision = request.bagRevision
  if bagRevision ~= self.bag:revision() then
    return result("refused", { reason = "stale" })
  end
  local bagChange, bagReason = self.bag:prepareInventoryChanges(bagRevision, {
    { op = "add", item = intent.itemKey, quantity = 1 },
  })
  if bagReason == "bag_full" and request.kind == "eraseMailboxMessage" then
    bagChange = nil
  elseif bagChange == nil then
    return result("refused", { reason = bagReason or "stale", outcome = bagReason == "bag_full" and "bag_full" or nil })
  end
  if request.kind == "eraseMailboxMessage" then
    local mailboxChange, mailboxReason =
      self.mailbox:prepareChanges(request.mailboxRevision, { { slot = request.slot, value = false } })
    if not mailboxChange then
      return result("refused", { reason = mailboxReason or "stale" })
    end
    if not mailboxChange.isCurrent() or (bagChange ~= nil and not bagChange.isCurrent()) then
      return result("refused", { reason = "stale" })
    end
    mailboxChange.publish()
    if bagChange then
      bagChange.publish()
      return result("changed", { outcome = "returned" })
    end
    return result("changed", { outcome = "discarded" })
  end
  if request.kind == "erasePartyMessage" then
    if not bagChange then
      return result("refused", { reason = "bag_full", outcome = "bag_full" })
    end
    local mon = resolved.mon
    mon.mail, mon.heldItem = {}, "NONE"
    local partyChange = self.mons:preparePartyChanges(request.partyRevision, { { slot = request.slot, mon = mon } })
    if not partyChange or not partyChange.isCurrent() or not bagChange.isCurrent() then
      return result("refused", { reason = "stale" })
    end
    partyChange.publish()
    bagChange.publish()
    return result("changed", { outcome = "returned" })
  end
  return result("refused", { reason = "unavailable" })
end

return MailActions
