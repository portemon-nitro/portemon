-- Owns atomic custody changes for authored Mail across Party, Mailbox and Bag.
local Mail = require("libs.mons.src.gen4.Mail")

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
  return setmetatable(
    { mons = mons, mailbox = mailbox, bag = bag, stationery = stationery, nextToken = 0 },
    MailActions
  )
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

function MailActions:_itemKey(letter)
  local stationery = assert(self.stationery[letter.type], "mail stationery is compiled")
  local itemKey = assert(stationery.itemKey, "mail stationery has a semantic item key")
  self.bag:catalog():item(itemKey)
  return itemKey
end

function MailActions:_resolve(request)
  assert(type(request) == "table" and type(request.kind) == "string", "mail requests carry a kind")
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
  local resolved, reason = self:_resolve(request)
  if resolved == nil then
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
  local isGive = intent.kind == "ready" and intent.operation == "give"
  if (intent.kind ~= "confirm" and not isGive) or (intent.kind == "confirm" and confirmation ~= true) then
    return result("refused", { reason = "confirmation_required" })
  end
  self.intents[intent.token] = nil
  local request = intent.request
  local resolved, reason = self:_resolve(request)
  if resolved == nil or resolved.itemKey ~= intent.itemKey then
    return result("refused", { reason = reason or "stale" })
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
    if not partyChange or not mailboxChange then
      return result("refused", { reason = "stale" })
    end
    if not partyChange.isCurrent() or not mailboxChange.isCurrent() then
      return result("refused", { reason = "stale" })
    end
    partyChange.publish()
    mailboxChange.publish()
    return result("changed", { outcome = "given", targetSlot = request.targetSlot })
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
