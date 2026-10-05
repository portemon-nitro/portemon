-- The composed Party flow reads a held letter in an owned read-only child.

local Assert = require("tests.support.Assert")
local BagCursor = require("libs.hgss.src.items.BagCursor")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local ItemFixture = require("libs.items.tests.item_fixture")
local ItemCatalog = require("libs.items.src.ItemCatalog")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local Mailbox = require("libs.hgss.src.save.Mailbox")
local PhotoAlbum = require("libs.hgss.src.save.PhotoAlbum")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PartyPresentationFixture = require("tests.support.PartyPresentationFixture")
local PokemonMenuComposition = require("game.hgss.src.field.PokemonMenuComposition")
local MailboxScreenState = require("game.hgss.src.pc.MailboxScreenState")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

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

local function letter()
  return {
    schema = "g4-mail-v1",
    type = 0,
    author = { trainerId = 54321, name = "MISTY", gender = 1, language = 2, game = 8 },
    icons = {
      { species = "CHIKORITA", form = 0, palette = 2 },
      false,
      { species = "TOTODILE", form = 0, palette = 1 },
    },
    lines = {
      { template = "mail.line.first", words = { "word.water", false } },
      { template = "mail.line.second", words = { "word.friend", false } },
      { template = "mail.line.third", words = { "word.goodbye", false } },
    },
  }
end

local function pcManifest()
  local stationery = {}
  for type = 0, 11 do
    stationery[type] = {
      itemKey = STATIONERY[type + 1],
      background = {
        image = "assets/generated/pc/stationery-" .. type .. ".png",
        width = 256,
        height = 192,
        anchorX = 0,
        anchorY = 0,
      },
    }
  end
  return {
    schema = "g4-pc-v2",
    mailbox = { background = {}, geometry = { visibleLetters = 10 }, pageSize = 10 },
    mail = { stationery = stationery, geometry = { iconSlots = 3 }, text = { sourceBanks = {} }, wordDictionary = {} },
    text = {},
    sequences = {},
  }
end

local function measurement()
  return {
    width = 256,
    height = 192,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      role = "world",
      touch = true,
    }),
    pixelRatio = 1,
    signature = "pc-mail-party-flow:256x192",
  }
end

local function worldPorts()
  return {
    actors = {
      getActor = function() end,
      actorsOf = function()
        return {}
      end,
      getPosition = function() end,
      getCollisionAt = function() end,
      beginScriptedAction = function() end,
      advanceScriptedAction = function() end,
      commitScriptedAction = function() end,
      cancelScriptedMovement = function() end,
      isScriptedMoving = function()
        return false
      end,
      removePresence = function() end,
      syncEventStateChanges = function() end,
    },
    events = {
      setFlag = function() end,
      isFlagSet = function()
        return false
      end,
    },
    maps = {
      current = function()
        return { symbol = "MAP_TEST", id = 1, fieldUse = {} }
      end,
      runtimeMap = function()
        return {}
      end,
    },
    player = {
      position = function()
        return { fieldX = 0, fieldZ = 0, worldY = 0 }
      end,
      facing = function()
        return "south"
      end,
      beginScriptedAction = function() end,
      advanceScriptedAction = function() end,
      commitScriptedAction = function() end,
      cancelScriptedMovement = function() end,
      isScriptedMoving = function()
        return false
      end,
      queueAvatarTransition = function() end,
      applyAvatarTransitions = function() end,
    },
    profile = { badges = 0xFFFF },
    weather = { change = function() end },
    reactions = { dispatch = function() end },
  }
end

local function makeComposition(attachMail)
  local items = itemCatalog()
  local catalog = MonCatalog.new(CatalogFixture.buildAssetRoot(), items)
  local bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x12345678):capture(), catalog:fingerprint())
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
  local factory = CatalogFixture.makeFactory(0x87654321, catalog)
  for _, species in ipairs({ "CHIKORITA", "TOTODILE" }) do
    Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = species }))))
  end
  local sender = mons:partyMon(0)
  if attachMail ~= false then
    sender.heldItem = "GRASS_MAIL"
    sender.mail = letter()
    local publication = assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 0, mon = sender } }))
    publication.publish()
  end

  local bag = HgssBagService.new({ catalog = items })
  local mailbox = Mailbox.new()
  local composition = PokemonMenuComposition.create({
    mons = mons,
    bag = bag,
    mailbox = mailbox,
    photoAlbum = PhotoAlbum.new(),
    pcManifest = pcManifest(),
    cacheFs = {
      read = function()
        return ""
      end,
    },
    bagCursor = BagCursor.new(),
    itemCatalog = items,
    monCatalog = catalog,
    profile = CatalogFixture.profile(),
    versionId = "heartgold",
    derivedAssets = require("tests.support.FieldStatePresentationFixture").iconHost().derivedAssets,
    charmap = CatalogFixture.CHARMAP,
    bagManifest = {},
    partyManifest = PartyPresentationFixture.manifest(),
    uiManifest = FieldUiFixture.manifest(),
    heroGender = "male",
    measureDisplay = measurement,
    prepareIcons = function()
      return true
    end,
    cancelIconPreparation = function() end,
    contextSources = function()
      return { badges = 0xFFFF, mapSymbol = "MAP_TEST", fieldUse = {}, avatarMode = "walking" }
    end,
    worldPorts = worldPorts(),
  })
  return composition.makePartyFlow(), mons, mailbox, sender, bag, composition
end

local function status(flow)
  local value = flow:status()
  Assert.isTrue(value.open, "the composed Party application remains open")
  return value
end

local function update(flow, events)
  flow:updateFixed(events or {})
  for _ = 1, 16 do
    local value = flow:status()
    if value.transition == nil then
      return value
    end
    flow:updateFixed({})
  end
  return status(flow)
end

local function waitFor(flow, label, predicate)
  for _ = 1, 60 do
    local value = status(flow)
    if predicate(value) then
      return value
    end
    flow:updateFixed({})
  end
  local final = status(flow)
  error(
    "the composed Party flow never reaches "
      .. label
      .. "; page="
      .. tostring(final.page)
      .. "; phase="
      .. tostring(final.child and final.child.phase)
      .. "; state="
      .. tostring(final.child and final.child.state),
    0
  )
end

local function chooseMenuEntry(flow, kind)
  for _ = 1, 60 do
    local current = status(flow)
    local child = assert(current.child)
    local entries = child.menu
    if type(entries) == "table" then
      local target = nil
      for index, entry in ipairs(entries) do
        if entry.kind == kind then
          target = index
        end
      end
      Assert.notNil(target, "the composed Party menu offers " .. kind)
      local selected = child.menuIndex or 1
      if selected == target then
        local priorState = child.state
        update(flow, { { type = "confirm" } })
        return waitFor(flow, "the " .. kind .. " dispatch", function(value)
          return value.page ~= current.page or value.child == nil or value.child.state ~= priorState
        end)
      end
      update(flow, { { type = "navigate", direction = selected < target and "down" or "up" } })
    else
      flow:updateFixed({})
    end
  end
  local final = status(flow)
  error(
    "the composed Party menu never offers "
      .. kind
      .. "; page="
      .. tostring(final.page)
      .. "; state="
      .. tostring(final.child and final.child.state)
      .. "; menu="
      .. tostring(final.child and final.child.menu),
    0
  )
end

function T.composed_party_read_opens_read_only_letter_and_returns_without_mutation()
  local flow, mons, mailbox, original = makeComposition(true)
  local partyRevision = mons:partyRevision()
  local mailboxRevision = mailbox:revision()

  waitFor(flow, "the interactive Party browse", function(value)
    return value.child ~= nil and value.child.phase == "interactive"
  end)
  flow:updateFixed({})
  flow:updateFixed({})
  update(flow, { { type = "confirm" } })
  chooseMenuEntry(flow, "mail")
  chooseMenuEntry(flow, "read_mail")
  local reading = waitFor(flow, "the Party read view", function(value)
    return value.page ~= "party_browse"
  end)
  Assert.equal(reading.child.viewMode, "read")
  Assert.deepEqual(reading.child.letter, original.mail, "the read child carries the authored copy")
  Assert.equal(mons:partyRevision(), partyRevision, "reading does not publish a party revision")
  Assert.equal(mailbox:revision(), mailboxRevision, "reading does not publish a mailbox revision")

  update(flow, { { type = "cancel" } })
  local returned = waitFor(flow, "the original Party context", function(value)
    return value.page == "party_browse" and value.child ~= nil
  end)
  Assert.isTrue(returned.open)
  Assert.deepEqual(mons:partyMon(0), original, "closing the read view preserves the original letter and held item")
  Assert.equal(mons:partyRevision(), partyRevision)
  flow:dispose()
end

function T.composed_party_take_offers_and_sends_the_authored_letter_to_mailbox()
  local flow, mons, mailbox, _, bag = makeComposition(true)
  waitFor(flow, "the interactive Party browse", function(value)
    return value.child ~= nil and value.child.phase == "interactive"
  end)
  flow:updateFixed({})
  flow:updateFixed({})
  update(flow, { { type = "confirm" } })
  chooseMenuEntry(flow, "mail")
  chooseMenuEntry(flow, "take_mail")
  update(flow, { { type = "navigate", direction = "up" } })
  update(flow, { { type = "confirm" } })
  local offer = waitFor(flow, "the send-to-PC offer", function(value)
    return value.page == "mail_confirm"
  end)
  Assert.equal(offer.child.phase, "confirm")
  update(flow, { { type = "confirm" } })
  waitFor(flow, "the restored Party context", function(value)
    return value.page == "party_browse" and value.transition == nil
  end)
  Assert.deepEqual(mailbox:get(0), letter(), "the entire authored letter moves into the Mailbox")
  local cleared = mons:partyMon(0)
  Assert.deepEqual(cleared.mail, {}, "sending clears the party Mail payload")
  Assert.equal(cleared.heldItem, "NONE", "sending clears the stationery held item")
  flow:dispose()
end

function T.production_composition_sends_gives_and_reads_the_same_authored_letter()
  local flow, mons, mailbox, original, _, composition = makeComposition(true)
  waitFor(flow, "the interactive Party browse", function(value)
    return value.child ~= nil and value.child.phase == "interactive"
  end)
  flow:updateFixed({})
  flow:updateFixed({})
  update(flow, { { type = "confirm" } })
  chooseMenuEntry(flow, "mail")
  chooseMenuEntry(flow, "take_mail")
  update(flow, { { type = "navigate", direction = "up" } })
  update(flow, { { type = "confirm" } })
  waitFor(flow, "the send-to-PC offer", function(value)
    return value.page == "mail_confirm"
  end)
  update(flow, { { type = "confirm" } })
  waitFor(flow, "the restored Party context", function(value)
    return value.page == "party_browse" and value.transition == nil
  end)
  Assert.deepEqual(mailbox:get(0), original.mail)

  local mailboxChild = composition.makeMailboxChild()
  mailboxChild:updateFixed({ { type = "confirm" } })
  mailboxChild:updateFixed({ { type = "navigate", direction = "down" } })
  mailboxChild:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(mailboxChild:status().action, "give")
  mailboxChild:updateFixed({ { type = "confirm" } })
  Assert.equal(mailboxChild:status().phase, "picker")
  for _ = 1, 20 do
    mailboxChild:updateFixed({})
  end
  Assert.equal(mailboxChild.picker:status().phase, "interactive", "the real party picker finishes its reveal")
  mailboxChild:updateFixed({ { type = "navigate", direction = "right" } })
  mailboxChild:updateFixed({ { type = "confirm" } })
  Assert.equal(mailboxChild:status().phase, "list")
  Assert.equal(
    mailbox:get(0),
    nil,
    "giving clears the persisted source slot; outcome=" .. tostring(mailboxChild:status().outcome.kind)
  )
  Assert.deepEqual(mons:partyMon(1).mail, original.mail, "the production picker gives the original authored value")
  mailboxChild:dispose()
  flow:dispose()

  local recipientFlow = composition.makePartyFlow()
  waitFor(recipientFlow, "the recipient's interactive Party context", function(value)
    return value.page == "party_browse" and value.child ~= nil and value.child.phase == "interactive"
  end)
  recipientFlow:updateFixed({})
  recipientFlow:updateFixed({})
  update(recipientFlow, { { type = "navigate", direction = "right" } })
  Assert.equal(
    status(recipientFlow).child.cursorNode,
    1,
    "Party navigation focuses the Pokemon that received the letter; cursor="
      .. tostring(status(recipientFlow).child.cursorNode)
  )
  update(recipientFlow, { { type = "confirm" } })
  chooseMenuEntry(recipientFlow, "mail")
  chooseMenuEntry(recipientFlow, "read_mail")
  local reader = waitFor(recipientFlow, "the recipient's read-only letter", function(value)
    return value.page == "mail_read"
  end)
  Assert.deepEqual(reader.child.letter, original.mail, "the recipient reads the unchanged authored letter")
  Assert.deepEqual(mons:partyMon(0).mail, {}, "only the chosen recipient retains Mail")
  recipientFlow:dispose()
  composition.dispose()
end

function T.composed_party_declining_send_requires_a_separate_confirmed_mail_loss()
  local flow, mons, mailbox, _, bag = makeComposition(true)
  waitFor(flow, "the interactive Party browse", function(value)
    return value.child ~= nil and value.child.phase == "interactive"
  end)
  flow:updateFixed({})
  flow:updateFixed({})
  update(flow, { { type = "confirm" } })
  chooseMenuEntry(flow, "mail")
  chooseMenuEntry(flow, "take_mail")
  update(flow, { { type = "navigate", direction = "up" } })
  update(flow, { { type = "confirm" } })
  waitFor(flow, "the send-to-PC offer", function(value)
    return value.page == "mail_confirm"
  end)
  local bagRevision = bag:revision()
  update(flow, { { type = "cancel" } })
  local eraseOffer = waitFor(flow, "the separate message-loss confirmation", function(value)
    return value.page == "mail_erase_confirm"
  end)
  Assert.equal(eraseOffer.child.phase, "confirm")
  Assert.equal(mailbox:revision(), 0, "declining send does not mutate the Mailbox")
  Assert.deepEqual(mons:partyMon(0).mail, letter(), "declining send does not erase before separate consent")
  Assert.equal(bag:revision(), bagRevision, "declining send does not return stationery")

  update(flow, { { type = "confirm" } })
  local returned = waitFor(flow, "the Party context after confirmed message loss", function(value)
    return value.page == "party_browse" and value.transition == nil
  end)
  Assert.deepEqual(mons:partyMon(0).mail, {}, "confirmed message loss erases the party record")
  Assert.equal(mons:partyMon(0).heldItem, "NONE")
  Assert.equal(bag:quantity("GRASS_MAIL"), 1, "confirmed message loss returns stationery")
  Assert.equal(returned.mailOutcome.kind, "changed")
  Assert.equal(returned.mailOutcome.outcome, "returned")
  flow:dispose()
end

function T.composed_party_declining_both_mail_prompts_preserves_the_letter()
  local flow, mons, mailbox, _, bag = makeComposition(true)
  waitFor(flow, "the interactive Party browse", function(value)
    return value.child ~= nil and value.child.phase == "interactive"
  end)
  flow:updateFixed({})
  flow:updateFixed({})
  update(flow, { { type = "confirm" } })
  chooseMenuEntry(flow, "mail")
  chooseMenuEntry(flow, "take_mail")
  update(flow, { { type = "navigate", direction = "up" } })
  update(flow, { { type = "confirm" } })
  waitFor(flow, "the send-to-PC offer", function(value)
    return value.page == "mail_confirm"
  end)
  update(flow, { { type = "cancel" } })
  waitFor(flow, "the separate message-loss confirmation", function(value)
    return value.page == "mail_erase_confirm"
  end)
  update(flow, { { type = "cancel" } })
  waitFor(flow, "the restored Party context", function(value)
    return value.page == "party_browse" and value.transition == nil
  end)
  Assert.deepEqual(mons:partyMon(0).mail, letter(), "two declined prompts preserve the exact authored letter")
  Assert.equal(mons:partyMon(0).heldItem, "GRASS_MAIL")
  Assert.equal(mailbox:revision(), 0)
  Assert.equal(bag:quantity("GRASS_MAIL"), 0)
  flow:dispose()
end

function T.composed_party_mail_projection_offers_mail_submenu()
  local flow = makeComposition(true)
  waitFor(flow, "the interactive Party browse", function(value)
    return value.child ~= nil and value.child.phase == "interactive"
  end)
  flow:updateFixed({})
  flow:updateFixed({})
  update(flow, { { type = "confirm" } })
  local party = waitFor(flow, "the selected Party context", function(value)
    return value.child ~= nil and type(value.child.menu) == "table"
  end)
  local kinds = {}
  for _, entry in ipairs(party.child.menu) do
    kinds[#kinds + 1] = entry.kind
  end
  Assert.deepEqual(kinds, { "summary", "switch", "mail", "quit" })
  flow:dispose()
end

function T.ordinary_held_item_still_opens_the_ordinary_item_submenu()
  local flow = makeComposition(false)
  waitFor(flow, "the interactive Party browse", function(value)
    return value.child ~= nil and value.child.phase == "interactive"
  end)
  flow:updateFixed({})
  flow:updateFixed({})
  update(flow, { { type = "confirm" } })
  chooseMenuEntry(flow, "item")
  local child = status(flow).child
  local kinds = {}
  for _, entry in ipairs(assert(child.menu, "the ordinary held-item submenu remains available")) do
    kinds[#kinds + 1] = entry.kind
  end
  Assert.deepEqual(kinds, { "give", "take", "quit" }, "ordinary held items retain their existing submenu")
  flow:dispose()
end

return { tests = T }
