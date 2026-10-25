-- Authored Mail transfers preserve custody across Party, Mailbox and Bag.

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
local PcMailActions = require("libs.hgss.src.field.MailActions")
local ItemCatalog = require("libs.items.src.ItemCatalog")

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

local function mail(type)
  return {
    schema = "g4-mail-v1",
    type = type,
    author = { trainerId = 12345, name = "MISTY", gender = 1, language = 2, game = 8 },
    icons = {
      { species = "CHIKORITA", form = 0, palette = 2 },
      false,
      { species = "TOTODILE", form = 0, palette = 1 },
    },
    lines = {
      { template = "mail.line.1", words = { "word.water", false } },
      { template = "mail.line.2", words = { "word.friend", "word.hello" } },
      { template = "mail.line.3", words = { "word.goodbye", false } },
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

local function composeManifest()
  local stationery = {}
  for type = 0, 11 do
    stationery[type] = { itemKey = STATIONERY[type + 1] }
  end
  -- The composed templates carry the two source EC slots each; only the
  -- browsed words are compiled so validation mirrors the renderer check.
  local twoSlotTemplate = {
    { kind = "text", value = "fixture" },
    { kind = "substitution" },
    { kind = "substitution" },
  }
  return {
    mail = {
      stationery = stationery,
      text = { templates = { ["mail-template:0:0"] = twoSlotTemplate } },
      wordDictionary = {
        ["0"] = { { kind = "text", value = "PIKA" } },
        ["1"] = { { kind = "text", value = "CHU" } },
      },
    },
  }
end

local function composedLetter(type)
  return {
    schema = "g4-mail-v1",
    type = type,
    author = { trainerId = 12345, name = "MISTY", gender = 1, language = 2, game = 8 },
    icons = { false, false, false },
    lines = {
      { template = "mail-template:0:0", words = { "0", "1" } },
      false,
      false,
    },
  }
end

local function services(mailboxSnapshot, manifestOverride)
  local items = itemCatalog()
  local catalog = MonCatalog.new(CatalogFixture.buildAssetRoot(), items)
  local rng = Lcrng.new(0x11223344)
  local bucket = MonsSave.capture(Party.new():capture(), rng:capture())
  local mons = HgssMonService.new({
    catalog = catalog,
    bucket = bucket,
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  })
  local factory = CatalogFixture.makeFactory(0x55667788, catalog)
  for _, species in ipairs({ "CHIKORITA", "TOTODILE" }) do
    local mon = factory:createNormal(CatalogFixture.normalRequest({ species = species }))
    Assert.isTrue(mons:addMon(mon), "setup adds a real party member")
  end
  local held = mons:partyMon(0)
  held.heldItem = "GRASS_MAIL"
  held.mail = mail(0)
  local prepared = assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 0, mon = held } }))
  prepared.publish()
  local mailbox = Mailbox.new(mailboxSnapshot)
  local bag = HgssBagService.new({ catalog = items })
  local applied = manifestOverride or manifest()
  return mons, mailbox, bag, PcMailActions.new({ mons = mons, mailbox = mailbox, bag = bag, manifest = applied })
end

local function fullMailbox(letter)
  local slots = {}
  for slot = 1, Mailbox.CAPACITY do
    slots[slot] = letter
  end
  return { schema = Mailbox.SCHEMA, slots = slots }
end

function T.full_mailbox_refuses_party_send_without_changing_party_or_mailbox()
  local letter = mail(0)
  local mons, mailbox, _, actions = services(fullMailbox(letter))
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
    slots[slot] = slot == 1 and mail(0) or false
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
  Assert.deepEqual(mailbox:get(0), mail(0), "preview leaves the stored letter in place")
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
  Assert.equal(refused.outcome, "bag_full", "party removal does not inherit stored-Mail discard semantics")
  Assert.deepEqual(mons:partyMon(0), partyBefore, "the party letter survives failed stationery return")
  Assert.equal(bag:quantity("FLAME_MAIL"), 1, "the full Bag remains unchanged")
  Assert.equal(bag:quantity("GRASS_MAIL"), 999, "the full stationery stack remains unchanged")
end

function T.giving_mail_consumes_stationery_and_preserves_the_letter_for_the_selected_mon()
  local stored = mail(3)
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
  local stored = mail(0)
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

function T.hold_erased_mail_attaches_the_retained_letter_and_consumes_stationery()
  local slots = { mail(0) }
  for slot = 2, Mailbox.CAPACITY do
    slots[slot] = false
  end
  local mons, mailbox, bag, actions = services({ schema = Mailbox.SCHEMA, slots = slots })
  Assert.isTrue(bag:add("GRASS_MAIL", 1), "the erased stationery returns to the Bag")
  local mailboxBefore = mailbox:capture()
  local missing = actions:preview({
    kind = "holdErasedMail",
    targetSlot = 1,
    letter = mail(3),
    itemKey = "BLOOM_MAIL",
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
  })
  Assert.equal(missing.kind, "refused", "hold-mail refuses without its stationery in the Bag")
  Assert.equal(missing.reason, "bag_missing_item")

  local holder = actions:preview({
    kind = "holdErasedMail",
    targetSlot = 0,
    letter = mail(0),
    itemKey = "GRASS_MAIL",
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
  })
  Assert.equal(holder.kind, "refused", "a mon holding an item cannot hold Mail")
  Assert.equal(holder.reason, "recipient_holds_item")

  local intent = actions:preview({
    kind = "holdErasedMail",
    targetSlot = 1,
    letter = mail(0),
    itemKey = "GRASS_MAIL",
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
  })
  Assert.equal(intent.kind, "ready", "hold-mail previews without further confirmation")
  local outcome = actions:commit(intent)
  Assert.equal(outcome.kind, "changed")
  Assert.equal(outcome.outcome, "held")
  Assert.equal(outcome.targetSlot, 1)
  Assert.deepEqual(mons:partyMon(1).mail, mail(0), "the retained letter reaches its selected recipient")
  Assert.equal(mons:partyMon(1).heldItem, "GRASS_MAIL")
  Assert.equal(bag:quantity("GRASS_MAIL"), 0, "holding consumes the returned stationery")
  Assert.deepEqual(mailbox:capture(), mailboxBefore, "hold-mail never touches Mailbox custody")
end

function T.confirmation_intent_cannot_be_mutated_before_commit()
  local slots = { mail(0) }
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

function T.compose_give_mail_attaches_the_composed_letter_and_consumes_stationery()
  local slots = { mail(0) }
  for slot = 2, Mailbox.CAPACITY do
    slots[slot] = false
  end
  local ours = composeManifest()
  local mons, mailbox, bag, actions = services({ schema = Mailbox.SCHEMA, slots = slots }, ours)
  Assert.isTrue(bag:add("GRASS_MAIL", 1), "the erased stationery returns to the Bag")
  local mailboxBefore = mailbox:capture()
  local unknown = composedLetter(0)
  unknown.lines[1].words = { "0", "1494" }
  local refusedWord = actions:preview({
    kind = "composeGiveMail",
    targetSlot = 1,
    letter = unknown,
    itemKey = "GRASS_MAIL",
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
  })
  Assert.equal(refusedWord.kind, "refused", "uncompiled words never reach custody")
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
  Assert.equal(holder.kind, "refused", "a mon holding an item cannot hold composed Mail")
  Assert.equal(holder.reason, "recipient_holds_item")

  local intent = actions:preview({
    kind = "composeGiveMail",
    targetSlot = 1,
    letter = composedLetter(0),
    itemKey = "GRASS_MAIL",
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
  })
  Assert.equal(intent.kind, "ready", "composed Mail previews without further confirmation")
  Assert.equal(intent.operation, "compose")
  local outcome = actions:commit(intent)
  Assert.equal(outcome.kind, "changed")
  Assert.equal(outcome.outcome, "held")
  Assert.equal(outcome.targetSlot, 1)
  Assert.deepEqual(mons:partyMon(1).mail, composedLetter(0), "the composed letter reaches its recipient")
  Assert.equal(mons:partyMon(1).heldItem, "GRASS_MAIL")
  Assert.equal(bag:quantity("GRASS_MAIL"), 0, "giving consumes the composed stationery")
  Assert.deepEqual(mailbox:capture(), mailboxBefore, "composed giving never touches Mailbox custody")
end

function T.compose_give_mail_accepts_trailing_null_fields_on_single_slot_templates()
  local slots = { mail(0) }
  for slot = 2, Mailbox.CAPACITY do
    slots[slot] = false
  end
  local ours = composeManifest()
  ours.mail.text.templates["mail-template:0:1"] = {
    { kind = "text", value = "fixture" },
    { kind = "substitution" },
  }
  local mons, mailbox, bag, actions = services({ schema = Mailbox.SCHEMA, slots = slots }, ours)
  Assert.isTrue(bag:add("GRASS_MAIL", 1), "the erased stationery returns to the Bag")
  local garbage = composedLetter(0)
  garbage.lines[1] = { template = "mail-template:0:1", words = { "0", "1" } }
  local refused = actions:preview({
    kind = "composeGiveMail",
    targetSlot = 1,
    letter = garbage,
    itemKey = "GRASS_MAIL",
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
  })
  Assert.equal(refused.kind, "refused", "trailing garbage never reaches custody")
  Assert.equal(refused.reason, "invalid_letter")

  local single = composedLetter(0)
  single.lines[1] = { template = "mail-template:0:1", words = { "0", false } }
  local intent = actions:preview({
    kind = "composeGiveMail",
    targetSlot = 1,
    letter = single,
    itemKey = "GRASS_MAIL",
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
  })
  Assert.equal(intent.kind, "ready", "a single filled slot with trailing null previews")
  local outcome = actions:commit(intent)
  Assert.equal(outcome.kind, "changed")
  Assert.deepEqual(mons:partyMon(1).mail, single, "the single-slot letter reaches its recipient")
  Assert.equal(bag:quantity("GRASS_MAIL"), 0, "giving consumes the composed stationery")
end

return { tests = T }
