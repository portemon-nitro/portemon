-- Authored Mail transfers preserve custody across Party, Mailbox, Bag,
-- and GameStats. Ordinary held-item replacement asks consent before any
-- composer opens, capacity is tested after Yes, and one accepted letter
-- publishes party, bag, and stats atomically with canonical form
-- effects. Failures before publication change nothing.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ItemFixture = require("libs.items.tests.item_fixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Mailbox = require("libs.hgss.src.save.Mailbox")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local GameStats = require("libs.hgss.src.mons.GameStats")
local PcMailActions = require("libs.hgss.src.field.MailActions")
local ItemCatalog = require("libs.items.src.ItemCatalog")

---@param _ unknown
local function void(_) end

local T = {}

local STATIONERY = {
  "GRASS_MAIL",
  "FLAME_MAIL",
  "BUBBLE_MAIL",
  "BLOOM_MAIL",
  "TUNNEL_MAIL",
  "STEEL_MAIL",
  "HEART_MAIL",
  "SNOW_MAIL",
  "SPACE_MAIL",
  "AIR_MAIL",
  "MOSAIC_MAIL",
  "BRICK_MAIL",
}

local function itemCatalog()
  local root = ItemFixture.buildAssetRoot()
  root.items["POTION"] = {
    nativeId = 17,
    price = 300,
    name = "Potion",
    nameIndefinite = "a potion",
    namePlural = "potions",
    description = "Restores HP.",
    pocket = "items",
    preventToss = false,
    selectable = true,
    isBall = false,
    friendshipBoost = false,
    icon = "POTION",
    isHm = false,
    canHold = true,
    heldFormEffect = "none",
    partyUse = { kind = "none" },
  }
  for type = 0, 11 do
    local nativeId = 137 + type
    root.items["ITEM_" .. nativeId] = nil
    root.items[STATIONERY[type + 1]] = {
      nativeId = nativeId,
      price = 50,
      name = STATIONERY[type + 1],
      nameIndefinite = "a letter",
      namePlural = "letters",
      description = "A written letter.",
      pocket = "mail",
      preventToss = false,
      selectable = true,
      isBall = false,
      friendshipBoost = false,
      icon = STATIONERY[type + 1],
      isHm = false,
      canHold = false,
      heldFormEffect = "none",
      partyUse = { kind = "none" },
    }
  end
  return ItemCatalog.new(root)
end

local function author()
  return { trainerId = 12345, name = "MISTY", gender = 1, language = 2, game = 8 }
end

local function letter(type, lines)
  return {
    schema = "g4-mail-v2",
    type = type,
    author = author(),
    icons = { "CHIKORITA/f0", false, "TOTODILE/f0" },
    lines = lines or {
      { template = "mail-template:2:4", words = { "1371", "1417" } },
      { template = "mail-template:3:1", words = { "1479", false } },
      false,
    },
  }
end

local function composedLetter(type)
  return {
    schema = "g4-mail-v2",
    type = type,
    author = author(),
    icons = { false, false, false },
    lines = {
      { template = "mail-template:0:0", words = { "0", "1" } },
      false,
      false,
    },
  }
end

local function manifest()
  local stationery = {}
  for type = 0, 11 do
    stationery[type] = { itemKey = STATIONERY[type + 1] }
  end
  return { mail = { stationery = stationery } }
end

-- Faithful C01 double for the custody boundary: one two-substitution
-- template with two known words.
local function catalog()
  return {
    template = function(_, bank, number)
      if bank == 0 and number == 0 then
        return { bank = 0, number = 0, wordCount = 2, tokens = {} }
      end
      return nil
    end,
    messageStatus = function(_, message)
      if type(message) ~= "table" or message.bank ~= 0 or message.number ~= 0 then
        return "invalid"
      end
      if type(message.words) ~= "table" then
        return "invalid"
      end
      for _, id in ipairs(message.words) do
        if id ~= 0 and id ~= 1 and id ~= 65535 then
          return "invalid"
        end
      end
      if message.words[1] == 65535 or message.words[2] == 65535 then
        return "incomplete"
      end
      return "complete"
    end,
    expandMessage = function()
      error("custody never expands", 0)
    end,
  }
end

local function statsOwner()
  return GameStats.new({ species = { CHIKORITA = true, TOTODILE = true, GIRATINA = true } })
end

local function services(mailboxSnapshot)
  local items = itemCatalog()
  local monRoot = CatalogFixture.buildAssetRoot()
  local monCatalog = MonCatalog.new(monRoot, items)
  local rng = Lcrng.new(0x11223344)
  local bucket = MonsSave.capture(Party.new():capture(), rng:capture())
  local stats = statsOwner()
  local mons = HgssMonService.new({
    catalog = monCatalog,
    bucket = bucket,
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    stats = stats,
  })
  local factory = CatalogFixture.makeFactory(0x55667788, monCatalog)
  for _, species in ipairs({ "CHIKORITA", "TOTODILE" }) do
    local mon = factory:createNormal(CatalogFixture.normalRequest({ species = species }))
    Assert.isTrue(mons:addMon(mon), "setup adds a real party member")
  end
  local held = mons:partyMon(0)
  held.heldItem = "GRASS_MAIL"
  held.mail = letter(0)
  local prepared = assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 0, mon = held } }))
  prepared.publish()
  local mailbox = Mailbox.new(mailboxSnapshot, { catalog = monCatalog })
  local bag = HgssBagService.new({ catalog = items })
  local actions = PcMailActions.new({
    mons = mons,
    mailbox = mailbox,
    bag = bag,
    manifest = manifest(),
    catalog = catalog(),
    gameStats = stats,
  })
  return mons, mailbox, bag, actions, stats
end

local function fullMailbox(value)
  local slots = {}
  for slot = 1, Mailbox.CAPACITY do
    slots[slot] = value
  end
  return { schema = Mailbox.SCHEMA, slots = slots }
end

local function snapshotBucket(stats)
  return stats:bucket()
end

function T.full_mailbox_refuses_party_send_without_changing_party_or_mailbox()
  local value = letter(0)
  local mons, mailbox, _, actions = services(fullMailbox(value))
  local before = mons:partyMon(0)
  local mailboxBefore = mailbox:capture()
  local intent = actions:preview({
    kind = "sendPartyToMailbox",
    slot = 0,
    partyRevision = mons:partyRevision(),
    mailboxRevision = mailbox:revision(),
  })

  Assert.equal(intent.kind, "refused", "a full mailbox refuses the send")
  Assert.equal(actions:commit(intent).kind, "refused")
  Assert.deepEqual(mons:partyMon(0), before, "the exact party letter remains held")
  Assert.deepEqual(mailbox:capture(), mailboxBefore, "a full mailbox remains byte-for-byte equivalent")
end

function T.full_bag_distinguishes_stored_mail_discard_from_party_removal_refusal()
  local slots = {}
  for slot = 1, Mailbox.CAPACITY do
    slots[slot] = slot == 1 and letter(0) or false
  end
  local mons, mailbox, bag, actions = services({ schema = Mailbox.SCHEMA, slots = slots })
  for _, itemKey in ipairs(STATIONERY) do
    local quantity = itemKey == "GRASS_MAIL" and 999 or 1
    Assert.isTrue(bag:add(itemKey, quantity), "the Mail pocket carries its full stack capacity")
  end

  local erase = actions:preview({
    kind = "eraseMailboxMessage",
    slot = 0,
    mailboxRevision = mailbox:revision(),
    bagRevision = bag:revision(),
  })
  Assert.equal(erase.kind, "confirm", "stored Mail erasure asks before changing custody")
  Assert.deepEqual(mailbox:get(0).lines, letter(0).lines, "preview leaves the stored letter in place")
  local discarded = actions:commit(erase, true)
  Assert.equal(discarded.kind, "changed", "confirmed stored Mail erasure follows the source discard branch")
  Assert.equal(discarded.outcome, "discarded", "the full-Bag outcome remains explicit")
  Assert.isNil(mailbox:get(0), "the confirmed letter is erased")
  Assert.equal(bag:quantity("FLAME_MAIL"), 1, "the unrelated full-Bag item is retained")
  Assert.equal(bag:quantity("GRASS_MAIL"), 999, "the full stationery stack is retained")

  local partyErase = actions:preview({
    kind = "erasePartyMessage",
    slot = 0,
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
  })
  Assert.equal(partyErase.kind, "confirm", "party message loss uses a separate confirmation")
  local partyBefore = mons:partyMon(0)
  local refused = actions:commit(partyErase, true)
  Assert.equal(refused.kind, "refused", "party removal refuses when its stationery cannot return to Bag")
  Assert.equal(refused.reason, "bag_full", "party removal reports its Bag reason")
  Assert.equal(refused.outcome, "bag_full", "party removal does not inherit stored-Mail discard semantics")
  Assert.deepEqual(mons:partyMon(0), partyBefore, "the party letter survives failed stationery return")
  Assert.equal(bag:quantity("FLAME_MAIL"), 1, "the full Bag remains unchanged")
  Assert.equal(bag:quantity("GRASS_MAIL"), 999, "the full stationery stack remains unchanged")
end

function T.giving_mail_consumes_no_stationery_and_moves_the_letter_unchanged()
  local stored = letter(3)
  local slots = { stored }
  for slot = 2, Mailbox.CAPACITY do
    slots[slot] = false
  end
  local mons, mailbox, bag, actions = services({ schema = Mailbox.SCHEMA, slots = slots })
  local bagRevision = bag:revision()
  local recipient = mons:partyMon(1)
  Assert.equal(recipient.heldItem, "NONE")
  local intent = actions:preview({
    kind = "giveMailboxMail",
    slot = 0,
    targetSlot = 1,
    mailboxRevision = mailbox:revision(),
    partyRevision = mons:partyRevision(),
    bagRevision = bagRevision,
  })
  Assert.equal(intent.kind, "ready")
  local outcome = actions:commit(intent)
  Assert.equal(outcome.kind, "changed")
  Assert.deepEqual(mailbox:get(0), nil, "the persistent slot clears after the transfer")
  Assert.deepEqual(mons:partyMon(1).mail, stored, "the exact authored letter reaches its selected recipient")
  Assert.equal(mons:partyMon(1).heldItem, "BLOOM_MAIL")
  Assert.equal(bag:revision(), bagRevision, "the stored letter carries its stationery outside Bag")
end

function T.confirmation_and_give_intents_cannot_publish_after_decline_or_recipient_change()
  local stored = letter(0)
  local slots = { stored }
  for slot = 2, Mailbox.CAPACITY do
    slots[slot] = false
  end
  local mons, mailbox, bag, actions = services({ schema = Mailbox.SCHEMA, slots = slots })
  local mailboxBefore, bagBefore = mailbox:capture(), bag:capture()
  local erase = actions:preview({
    kind = "eraseMailboxMessage",
    slot = 0,
    mailboxRevision = mailbox:revision(),
    bagRevision = bag:revision(),
  })
  Assert.equal(erase.kind, "confirm")
  Assert.equal(actions:commit(erase, false).reason, "declined")
  Assert.equal(actions:commit(erase, true).reason, "stale_intent", "a declined confirmation cannot be replayed")
  Assert.deepEqual(mailbox:capture(), mailboxBefore, "declining source confirmation preserves Mailbox custody")
  Assert.deepEqual(bag:capture(), bagBefore, "declining source confirmation preserves stationery inventory")

  local give = actions:preview({
    kind = "giveMailboxMail",
    slot = 0,
    targetSlot = 1,
    mailboxRevision = mailbox:revision(),
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
  })
  Assert.equal(give.kind, "ready")
  local recipient = mons:partyMon(1)
  recipient.heldItem = "POTION"
  local partyChange = assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 1, mon = recipient } }))
  partyChange.publish()
  local stale = actions:commit(give)
  Assert.equal(stale.kind, "refused", "a changed recipient invalidates the staged attachment")
  Assert.deepEqual(mailbox:capture(), mailboxBefore, "a stale recipient cannot clear the source slot")
  Assert.equal(mons:partyMon(1).heldItem, "POTION", "a stale recipient retains the intervening held item")
  Assert.deepEqual(mons:partyMon(1).mail, {}, "a stale recipient never receives the authored letter")
end

function T.confirmation_intent_cannot_be_mutated_before_commit()
  local slots = { letter(0) }
  for slot = 2, Mailbox.CAPACITY do
    slots[slot] = false
  end
  local _, mailbox, bag, actions = services({ schema = Mailbox.SCHEMA, slots = slots })
  local mailboxBefore, bagBefore = mailbox:capture(), bag:capture()
  local intent = actions:preview({
    kind = "eraseMailboxMessage",
    slot = 0,
    mailboxRevision = mailbox:revision(),
    bagRevision = bag:revision(),
  })
  intent.letter.author.name = "SPOOFED"
  Assert.equal(actions:commit(intent, true).reason, "stale_intent")
  Assert.deepEqual(mailbox:capture(), mailboxBefore, "mutating a caller-held intent cannot erase Mail")
  Assert.deepEqual(bag:capture(), bagBefore, "mutating a caller-held intent cannot mint stationery")
end

function T.preflight_answers_readiness_consent_and_refusals_without_mutation()
  local slots = { letter(0) }
  for slot = 2, Mailbox.CAPACITY do
    slots[slot] = false
  end
  local mons, _, bag, actions, stats = services({ schema = Mailbox.SCHEMA, slots = slots })
  Assert.isTrue(bag:add("GRASS_MAIL", 2), "the journey stocks its stationery")
  local partyRevision, bagRevision = mons:partyRevision(), bag:revision()
  local statsBefore = snapshotBucket(stats)

  -- An empty-handed recipient is ready at once.
  local ready = actions:previewComposition({
    targetSlot = 1,
    itemKey = "GRASS_MAIL",
    partyRevision = partyRevision,
    bagRevision = bagRevision,
  })
  Assert.equal(ready.kind, "ready")
  Assert.equal(ready.stationeryType, 0)
  Assert.equal(ready.before.heldItem, "NONE")
  Assert.isTrue(ready.before.maxHp > 0, "preflight derives the recipient maximum HP")

  -- An ordinary held item asks its replacement question before any
  -- capacity test: the preflight carries no letter and retains nothing.
  local recipient = mons:partyMon(1)
  recipient.heldItem = "POTION"
  local staged = assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 1, mon = recipient } }))
  staged.publish()
  partyRevision = mons:partyRevision()
  local asked = actions:previewComposition({
    targetSlot = 1,
    itemKey = "GRASS_MAIL",
    partyRevision = partyRevision,
    bagRevision = bagRevision,
  })
  Assert.equal(asked.kind, "needs_confirmation", "an ordinary held item asks before any composer opens")
  Assert.equal(asked.before.heldItem, "POTION")
  -- A second identical preflight answers the same: no intent is retained.
  local repeated = actions:previewComposition({
    targetSlot = 1,
    itemKey = "GRASS_MAIL",
    partyRevision = partyRevision,
    bagRevision = bagRevision,
  })
  Assert.equal(repeated.kind, "needs_confirmation", "preflight retains no intent token")

  -- After Yes, a fitting return pocket readies the composition.
  local consented = actions:previewComposition({
    targetSlot = 1,
    itemKey = "GRASS_MAIL",
    partyRevision = partyRevision,
    bagRevision = bagRevision,
    confirmed = true,
  })
  Assert.equal(consented.kind, "ready", "confirmed replacement with return space readies")

  -- A held-Mail recipient refuses without opening a composer.
  recipient = mons:partyMon(0)
  local held = actions:previewComposition({
    targetSlot = 0,
    itemKey = "GRASS_MAIL",
    partyRevision = partyRevision,
    bagRevision = bagRevision,
  })
  Assert.equal(held.kind, "refused")
  Assert.equal(held.reason, "recipient_holds_mail")
  void(recipient)

  -- An egg recipient is ineligible.
  local egged = mons:partyMon(1)
  egged.isEgg = true
  local eggStaged = assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 1, mon = egged } }))
  eggStaged.publish()
  local eggedRefusal = actions:previewComposition({
    targetSlot = 1,
    itemKey = "GRASS_MAIL",
    partyRevision = mons:partyRevision(),
    bagRevision = bagRevision,
  })
  Assert.equal(eggedRefusal.kind, "refused")
  Assert.equal(eggedRefusal.reason, "ineligible_recipient")

  -- Stale revisions refuse.
  local stale = actions:previewComposition({
    targetSlot = 1,
    itemKey = "GRASS_MAIL",
    partyRevision = partyRevision,
    bagRevision = bagRevision,
  })
  Assert.equal(stale.kind, "refused")
  Assert.equal(stale.reason, "stale")

  -- Unknown stationery refuses.
  local missing = actions:previewComposition({
    targetSlot = 1,
    itemKey = "POTION",
    partyRevision = mons:partyRevision(),
    bagRevision = bagRevision,
  })
  Assert.equal(missing.kind, "refused")
  Assert.equal(missing.reason, "missing_stationery")

  Assert.deepEqual(snapshotBucket(stats), statsBefore, "preflight moves no statistics")
  Assert.equal(bag:quantity("GRASS_MAIL"), 2, "preflight moves no inventory")
end

function T.confirmed_replacement_refuses_when_the_old_item_cannot_return()
  local slots = { letter(0) }
  for slot = 2, Mailbox.CAPACITY do
    slots[slot] = false
  end
  local mons, _, bag, actions = services({ schema = Mailbox.SCHEMA, slots = slots })
  Assert.isTrue(bag:add("GRASS_MAIL", 1), "the journey stocks its stationery")
  Assert.isTrue(bag:add("POTION", 999), "the ordinary stack fills to its maximum quantity")
  local recipient = mons:partyMon(1)
  recipient.heldItem = "POTION"
  local staged = assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 1, mon = recipient } }))
  staged.publish()
  local refused = actions:previewComposition({
    targetSlot = 1,
    itemKey = "GRASS_MAIL",
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
    confirmed = true,
  })
  Assert.equal(refused.kind, "refused", "replacement refuses when the old item cannot fit")
  Assert.equal(refused.reason, "bag_full")
  Assert.equal(mons:partyMon(1).heldItem, "POTION", "refusal keeps the ordinary held item")
  Assert.equal(bag:quantity("GRASS_MAIL"), 1, "refusal moves no stationery")
end

function T.compose_give_mail_moves_custody_stats_and_form_effects_exactly_once()
  local slots = { letter(0) }
  for slot = 2, Mailbox.CAPACITY do
    slots[slot] = false
  end
  local mons, mailbox, bag, actions, stats = services({ schema = Mailbox.SCHEMA, slots = slots })
  Assert.isTrue(bag:add("GRASS_MAIL", 1), "the journey stocks its stationery")
  local mailboxBefore = mailbox:capture()
  local statsBefore = snapshotBucket(stats)

  local unknown = composedLetter(0)
  unknown.lines[1].words = { "0", "7" }
  local refusedWord = actions:preview({
    kind = "composeGiveMail",
    targetSlot = 1,
    letter = unknown,
    itemKey = "GRASS_MAIL",
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
  })
  Assert.equal(refusedWord.kind, "refused", "unknown words never reach custody")
  Assert.equal(refusedWord.reason, "invalid_letter")

  local mismatched = actions:preview({
    kind = "composeGiveMail",
    targetSlot = 1,
    letter = composedLetter(3),
    itemKey = "GRASS_MAIL",
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
  })
  Assert.equal(mismatched.kind, "refused", "stationery must match the composed type")
  Assert.equal(mismatched.reason, "mail_stationery_mismatch")

  local holder = actions:preview({
    kind = "composeGiveMail",
    targetSlot = 0,
    letter = composedLetter(0),
    itemKey = "GRASS_MAIL",
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
  })
  Assert.equal(holder.kind, "refused", "a mon holding Mail never reaches the replacement question")
  Assert.equal(holder.reason, "recipient_holds_mail")

  local intent = actions:preview({
    kind = "composeGiveMail",
    targetSlot = 1,
    letter = composedLetter(0),
    itemKey = "GRASS_MAIL",
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
  })
  Assert.equal(intent.kind, "ready", "a complete draft on an empty hand previews ready")
  Assert.equal(intent.operation, "compose")
  local outcome = actions:commit(intent)
  Assert.equal(outcome.kind, "changed")
  Assert.equal(outcome.outcome, "given")
  Assert.equal(outcome.targetSlot, 1)
  Assert.equal(outcome.before.heldItem, "NONE", "the preflight facts ride the completion")
  Assert.equal(outcome.after.heldItem, "GRASS_MAIL")
  Assert.isTrue(outcome.after.maxHp > 0, "completion derives the new maximum HP")
  Assert.deepEqual(mons:partyMon(1).mail, composedLetter(0), "the composed letter reaches its recipient")
  Assert.equal(mons:partyMon(1).heldItem, "GRASS_MAIL")
  Assert.equal(bag:quantity("GRASS_MAIL"), 0, "giving consumes the composed stationery")
  Assert.equal(stats:bucket().mailWritten, statsBefore.mailWritten + 1, "one write increments its count once")
  Assert.equal(stats:bucket().score, statsBefore.score + 1, "one write increments the score once")
  Assert.deepEqual(mailbox:capture(), mailboxBefore, "composed giving never touches Mailbox custody")

  -- A reread or a duplicated intent earns nothing more.
  Assert.equal(actions:commit(intent).reason, "stale_intent", "a consumed intent cannot publish twice")
  Assert.equal(stats:bucket().mailWritten, statsBefore.mailWritten + 1, "duplicates add no further count")
end

function T.replacement_give_returns_the_old_item_and_applies_form_effects()
  local slots = { letter(0) }
  for slot = 2, Mailbox.CAPACITY do
    slots[slot] = false
  end
  local mons, _, bag, actions, stats = services({ schema = Mailbox.SCHEMA, slots = slots })
  Assert.isTrue(bag:add("GRASS_MAIL", 1), "the journey stocks its stationery")
  local recipient = mons:partyMon(1)
  recipient.heldItem = "POTION"
  local staged = assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 1, mon = recipient } }))
  staged.publish()
  local statsBefore = snapshotBucket(stats)
  local formBefore = mons:partyMon(1).form

  local asked = actions:preview({
    kind = "composeGiveMail",
    targetSlot = 1,
    letter = composedLetter(0),
    itemKey = "GRASS_MAIL",
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
  })
  Assert.equal(asked.kind, "needs_confirmation", "an ordinary held item asks before any composer opens")
  Assert.equal(bag:quantity("GRASS_MAIL"), 1, "preflight moves no inventory")

  local intent = actions:preview({
    kind = "composeGiveMail",
    targetSlot = 1,
    letter = composedLetter(0),
    itemKey = "GRASS_MAIL",
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
    confirmed = true,
  })
  Assert.equal(intent.kind, "ready")
  local outcome = actions:commit(intent)
  Assert.equal(outcome.kind, "changed")
  Assert.equal(outcome.outcome, "given")
  Assert.equal(outcome.before.heldItem, "POTION")
  Assert.equal(outcome.after.heldItem, "GRASS_MAIL")
  Assert.equal(mons:partyMon(1).heldItem, "GRASS_MAIL", "the fresh letter attaches its stationery")
  Assert.deepEqual(mons:partyMon(1).mail, composedLetter(0), "the fresh letter reaches its recipient")
  Assert.equal(bag:quantity("POTION"), 1, "the old ordinary item returns exactly once")
  Assert.equal(bag:quantity("GRASS_MAIL"), 0, "exactly one stationery is consumed")
  Assert.equal(mons:partyMon(1).form, formBefore, "an ordinary mon keeps its form through the swap")
  Assert.equal(stats:bucket().mailWritten, statsBefore.mailWritten + 1, "replacement writes increment once")
  Assert.equal(stats:bucket().score, statsBefore.score + 1, "replacement writes score once")
end

function T.stored_letter_moves_earn_no_written_count()
  local stored = letter(0)
  local slots = { stored }
  for slot = 2, Mailbox.CAPACITY do
    slots[slot] = false
  end
  local mons, mailbox, bag, actions, stats = services({ schema = Mailbox.SCHEMA, slots = slots })
  local statsBefore = snapshotBucket(stats)
  local intent = actions:preview({
    kind = "giveMailboxMail",
    slot = 0,
    targetSlot = 1,
    mailboxRevision = mailbox:revision(),
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
  })
  Assert.equal(intent.kind, "ready")
  local outcome = actions:commit(intent)
  Assert.equal(outcome.kind, "changed")
  Assert.deepEqual(mons:partyMon(1).mail, stored, "stored give moves the authored value unchanged")
  Assert.deepEqual(snapshotBucket(stats), statsBefore, "a stored-letter move earns no write count")
end

function T.failed_or_tampered_compose_intents_publish_nothing()
  local slots = { letter(0) }
  for slot = 2, Mailbox.CAPACITY do
    slots[slot] = false
  end
  local mons, mailbox, bag, actions, stats = services({ schema = Mailbox.SCHEMA, slots = slots })
  Assert.isTrue(bag:add("GRASS_MAIL", 1), "the journey stocks its stationery")
  local partyRevision, bagRevision = mons:partyRevision(), bag:revision()
  local statsBefore = snapshotBucket(stats)
  local recipientBefore = { heldItem = mons:partyMon(1).heldItem, mail = mons:partyMon(1).mail }

  local intent = actions:preview({
    kind = "composeGiveMail",
    targetSlot = 1,
    letter = composedLetter(0),
    itemKey = "GRASS_MAIL",
    partyRevision = partyRevision,
    bagRevision = bagRevision,
  })
  Assert.equal(intent.kind, "ready")
  -- Invalidating the Bag revision between preview and commit refuses
  -- without publishing anything.
  Assert.isTrue(bag:add("POTION", 1), "an unrelated Bag change invalidates the staged revision")
  local stale = actions:commit(intent)
  Assert.equal(stale.kind, "refused")
  Assert.equal(stale.reason, "stale")
  Assert.equal(mons:partyMon(1).heldItem, recipientBefore.heldItem)
  Assert.deepEqual(mons:partyMon(1).mail, recipientBefore.mail)
  Assert.equal(bag:quantity("GRASS_MAIL"), 1)
  Assert.deepEqual(snapshotBucket(stats), statsBefore, "a stale draft adds no write count")

  -- A forged intent never authenticates.
  local forged = {
    kind = "ready",
    token = intent.token,
    request = intent.request,
    letter = composedLetter(0),
    itemKey = "FLAME_MAIL",
    operation = "compose",
  }
  Assert.equal(actions:commit(forged).reason, "stale_intent")
  Assert.equal(mons:partyMon(1).heldItem, recipientBefore.heldItem)
  Assert.deepEqual(snapshotBucket(stats), statsBefore, "a forged intent adds no write count")
  void(mailbox)
end

return { tests = T }
