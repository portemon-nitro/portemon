-- Item-data decoding contract for the item catalog compiler. Fixture layout
-- mirrors pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981
-- include/item.h ItemData: a u16 price, the hold-effect byte, and the packed
-- bitfield u16 at offset 8 (naturalGiftType:5, prevent_toss:1, selectable:1,
-- fieldPocket:4, battlePocket:5 from the least-significant bit). Native
-- identity to member mapping mirrors the ITEMNARC_PARAM column of src/item.c
-- sItemNarcIds: identities without their own data row share member 0.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local ItemSources = require("romdump.src.config.ItemSources")

local T = {}

local function compiler()
  return require("romdump.src.digest.items.ItemCatalogCompiler")
end

local function memberWith(holdEffect, word, price)
  price = price or 100
  local low = word % 256
  local high = math.floor(word / 256) % 256
  return string.char(price % 256, math.floor(price / 256), holdEffect, 0, 0, 0, 0, 0, low, high)
    .. string.rep("\0", 34 - 10)
end

function T.decodes_the_catalog_consumed_fields()
  local decoded = assert(compiler().decodeItemData(memberWith(53, 0), {
    archive = "item_data",
    memberId = 196,
  }))
  Assert.equal(decoded.holdEffect, 53)
  Assert.isFalse(decoded.preventToss)
  Assert.isFalse(decoded.selectable)
  Assert.equal(decoded.fieldPocket, 0)
end

function T.decodes_pocket_toss_and_selectable_bits()
  -- fieldPocket 1 (medicine), prevent_toss set, selectable clear.
  local word = 1 * 32 + 1 * 128
  local decoded = assert(compiler().decodeItemData(memberWith(0, word), {
    archive = "item_data",
    memberId = 17,
  }))
  Assert.equal(decoded.fieldPocket, 1)
  Assert.isTrue(decoded.preventToss)
  Assert.isFalse(decoded.selectable)
  -- fieldPocket 7 (key items), selectable set, prevent_toss clear.
  local keyWord = 1 * 64 + 7 * 128
  local keyDecoded = assert(compiler().decodeItemData(memberWith(0, keyWord), {
    archive = "item_data",
    memberId = 450,
  }))
  Assert.equal(keyDecoded.fieldPocket, 7)
  Assert.isFalse(keyDecoded.preventToss)
  Assert.isTrue(keyDecoded.selectable)
end

function T.ignores_non_catalog_bitfields()
  -- Battle-pocket bits never leak into catalog facts; the natural-gift
  -- type bits project through their own facts below.
  local word = 31 + 31 * 2048
  local decoded = assert(compiler().decodeItemData(memberWith(0, word), {
    archive = "item_data",
    memberId = 149,
  }))
  Assert.equal(decoded.fieldPocket, 0)
  Assert.isFalse(decoded.preventToss)
  Assert.isFalse(decoded.selectable)
  Assert.equal(decoded.naturalGiftType, 31)
end

function T.decodes_fling_and_natural_gift_throw_facts()
  -- Cheri Berry shape: pluck/fling effects 1, fling power 10,
  -- natural-gift power 60, gift type 10 (fire) over the berries pocket.
  local word = 10 + 4 * 128
  local member = string.char(100, 0, 0, 0, 1, 1, 10, 60, word % 256, math.floor(word / 256) % 256, 0, 0, 0, 0)
    .. string.rep("\0", 20)
  Assert.equal(#member, 34)
  local decoded = assert(compiler().decodeItemData(member, {
    archive = "item_data",
    memberId = 127,
  }))
  Assert.equal(decoded.flingEffect, 1)
  Assert.equal(decoded.flingPower, 10)
  Assert.equal(decoded.naturalGiftPower, 60)
  Assert.equal(decoded.naturalGiftType, 10)
  Assert.equal(decoded.fieldPocket, 4)
end

function T.rejects_malformed_item_members()
  local _, sizeErr = compiler().decodeItemData(string.rep("\0", 33), {
    archive = "item_data",
    memberId = 0,
  })
  Assert.isTrue(Errors.is(sizeErr))
  assert(sizeErr, "malformed item member must fail")
  Assert.equal(sizeErr.code, "ITEM_DATA_BAD_SIZE")
end

function T.maps_native_identities_to_source_members()
  Assert.equal(ItemSources.itemDataMember(0), 0)
  Assert.equal(ItemSources.itemDataMember(112), 112)
  Assert.equal(ItemSources.itemDataMember(113), 0)
  Assert.equal(ItemSources.itemDataMember(134), 0)
  Assert.equal(ItemSources.itemDataMember(135), 113)
  Assert.equal(ItemSources.itemDataMember(427), 405)
  Assert.equal(ItemSources.itemDataMember(428), 0)
  Assert.equal(ItemSources.itemDataMember(429), 406)
  Assert.equal(ItemSources.itemDataMember(536), 513)
  Assert.isFalse(pcall(ItemSources.itemDataMember, 537))
end

function T.pins_the_friendship_and_ball_source_facts()
  Assert.equal(ItemSources.HOLD_EFFECT_FRIENDSHIP_UP, 53)
  Assert.equal(ItemSources.HOLD_EFFECT_MONEY_UP, 58)
  for _, nativeId in ipairs({ 1, 4, 16, 492, 498, 500 }) do
    Assert.isTrue(ItemSources.ballItemIds[nativeId] == true, "item " .. nativeId .. " is a ball")
  end
  for _, nativeId in ipairs({ 0, 17, 218, 327 }) do
    Assert.isNil(ItemSources.ballItemIds[nativeId], "item " .. nativeId .. " is not a ball")
  end
end

local function partyMember(partyUse, flags, params)
  local bytes = { 100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, partyUse and 1 or 0, 0 }
  for index = 1, 7 do
    bytes[#bytes + 1] = flags[index] or 0
  end
  for index = 1, 11 do
    local value = params[index] or 0
    if value < 0 then
      value = value + 256
    end
    bytes[#bytes + 1] = value
  end
  bytes[#bytes + 1] = 0
  bytes[#bytes + 1] = 0
  return string.char(unpack(bytes))
end

function T.decodes_party_flags_and_signed_params()
  -- Potion shape: hp_restore with a fixed amount of 20, no friendship.
  local potion =
    assert(compiler().decodeItemData(partyMember(true, { 0, 0, 0, 0, 0, 0x04, 0 }, { 0, 0, 0, 0, 0, 0, 20 }), {
      archive = "item_data",
      memberId = 17,
    }))
  Assert.isTrue(potion.partyUse)
  Assert.isTrue(potion.party.hpRestore)
  Assert.isFalse(potion.party.revive)
  Assert.equal(potion.party.hpRestoreParam, 20)
  Assert.isFalse(potion.party.friendshipLo)
  -- Energy powder shape: fixed 50 plus signed friendship penalties.
  local powder = assert(
    compiler().decodeItemData(
      partyMember(true, { 0, 0, 0, 0, 0, 0x04, 0x0E }, { 0, 0, 0, 0, 0, 0, 50, 0, -5, -5, -10 }),
      { archive = "item_data", memberId = 34 }
    )
  )
  Assert.isTrue(powder.party.hpRestore)
  Assert.equal(powder.party.hpRestoreParam, 50)
  Assert.isTrue(powder.party.friendshipLo)
  Assert.isTrue(powder.party.friendshipMed)
  Assert.isTrue(powder.party.friendshipHi)
  Assert.equal(powder.party.friendshipLoParam, -5)
  Assert.equal(powder.party.friendshipHiParam, -10)
  -- Revive shape: revive plus half restoration.
  local revive =
    assert(compiler().decodeItemData(partyMember(true, { 0, 0x01, 0, 0, 0, 0x04, 0 }, { 0, 0, 0, 0, 0, 0, 254 }), {
      archive = "item_data",
      memberId = 28,
    }))
  Assert.isTrue(revive.party.revive)
  Assert.isFalse(revive.party.reviveAll)
  Assert.equal(revive.party.hpRestoreParam, 254)
  -- Sacred Ash shape: revive_all plus full restoration.
  local ash =
    assert(compiler().decodeItemData(partyMember(true, { 0, 0x03, 0, 0, 0, 0x04, 0 }, { 0, 0, 0, 0, 0, 0, 255 }), {
      archive = "item_data",
      memberId = 44,
    }))
  Assert.isTrue(ash.party.reviveAll)
  -- Vitamin shape: signed positive effort delta with friendship bands.
  local vitamin = assert(
    compiler().decodeItemData(
      partyMember(true, { 0, 0, 0, 0, 0, 0x08, 0x0E }, { 10, 0, 0, 0, 0, 0, 0, 0, 5, 3, 2 }),
      { archive = "item_data", memberId = 45 }
    )
  )
  Assert.isTrue(vitamin.party.hpEvUp)
  Assert.equal(vitamin.party.hpEvDelta, 10)
  -- Berry shape: signed negative effort delta.
  local berry = assert(
    compiler().decodeItemData(
      partyMember(true, { 0, 0, 0, 0, 0, 0x08, 0x0E }, { -10, 0, 0, 0, 0, 0, 0, 0, 10, 5, 2 }),
      { archive = "item_data", memberId = 169 }
    )
  )
  Assert.equal(berry.party.hpEvDelta, -10)
  Assert.equal(berry.party.friendshipLoParam, 10)
  -- Ether shape: single-target fixed power-point restore.
  local ether =
    assert(compiler().decodeItemData(partyMember(true, { 0, 0, 0, 0, 0, 0x01, 0 }, { 0, 0, 0, 0, 0, 0, 0, 10 }), {
      archive = "item_data",
      memberId = 38,
    }))
  Assert.isTrue(ether.party.ppRestore)
  Assert.isFalse(ether.party.ppRestoreAll)
  Assert.equal(ether.party.ppRestoreParam, 10)
  -- PP Up shape: boost flag with friendship bands.
  local ppUp = assert(
    compiler().decodeItemData(
      partyMember(true, { 0, 0, 0, 0, 0x40, 0, 0x0E }, { 0, 0, 0, 0, 0, 0, 0, 0, 5, 3, 2 }),
      { archive = "item_data", memberId = 51 }
    )
  )
  Assert.isTrue(ppUp.party.ppUp)
  -- Members without the party-use byte decode no party facts.
  local tm = assert(compiler().decodeItemData(memberWith(0, 0), { archive = "item_data", memberId = 328 }))
  Assert.isFalse(tm.partyUse)
end

-- Synthetic public-path coverage for party-use normalization: the decoder
-- fixtures above pin raw bits, while the cases below drive the closed
-- normalized record through compileCatalog with a stub dump. Only the two
-- crafted members carry party flags; every other identity decodes to an
-- inert member with its source-required pocket so the build stays valid.
local function catalogBytes(word, partyUse, flags, params, price)
  price = price or 100
  local bytes = { price % 256, math.floor(price / 256), 0, 0, 0, 0, 0, 0, word % 256, math.floor(word / 256) % 256, 0, 0, partyUse and 1 or 0, 0 }
  for index = 1, 7 do
    bytes[#bytes + 1] = (flags and flags[index]) or 0
  end
  for index = 1, 11 do
    local value = (params and params[index]) or 0
    if value < 0 then
      value = value + 256
    end
    bytes[#bytes + 1] = value
  end
  bytes[#bytes + 1] = 0
  bytes[#bytes + 1] = 0
  return string.char(unpack(bytes))
end

local function stubCatalogRom(overrides)
  local inert = catalogBytes(0, false, nil, nil)
  local members = {}
  for memberId = 0, 513 do
    members[memberId + 1] = inert
  end
  -- The source ranges below only accept their own pocket; every other
  -- identity is valid as a plain "items" member.
  for nativeId = ItemSources.FIRST_MAIL, ItemSources.LAST_MAIL do
    members[ItemSources.itemDataMember(nativeId) + 1] = catalogBytes(5 * 128, false, nil, nil)
  end
  for nativeId = ItemSources.FIRST_BERRY, ItemSources.LAST_BERRY do
    members[ItemSources.itemDataMember(nativeId) + 1] = catalogBytes(4 * 128, false, nil, nil)
  end
  for nativeId = ItemSources.FIRST_TM, ItemSources.LAST_HM do
    members[ItemSources.itemDataMember(nativeId) + 1] = catalogBytes(3 * 128, false, nil, nil)
  end
  for nativeId, member in pairs(overrides) do
    members[ItemSources.itemDataMember(nativeId) + 1] = member
  end
  local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
  local charmap = require("romdump.src.reference.hgss.charmap")
  local codeForGlyph = {}
  for code, display in pairs(charmap.glyphs) do
    codeForGlyph[display] = code
  end
  local function textBank(count)
    local bank = {}
    for _ = 1, count do
      bank[#bank + 1] = { assert(codeForGlyph["A"], "fixture glyph A is missing"), 0xFFFF }
    end
    return FieldMessageBank.encodeForTests(bank, 7)
  end
  local filler = FieldMessageBank.encodeForTests({ { 0xFFFF } }, 7)
  local banks = {}
  for bankId = 0, 251 do
    banks[bankId + 1] = filler
  end
  banks[ItemSources.messageBanks.description + 1] = textBank(ItemSources.messageCounts.description)
  banks[ItemSources.messageBanks.name + 1] = textBank(ItemSources.messageCounts.name)
  banks[ItemSources.messageBanks.nameIndefinite + 1] = textBank(ItemSources.messageCounts.nameIndefinite)
  banks[ItemSources.messageBanks.namePlural + 1] = textBank(ItemSources.messageCounts.namePlural)
  banks[ItemSources.messageBanks.pocket + 1] = textBank(ItemSources.messageCounts.pocket)
  banks[ItemSources.messageBanks.berry + 1] = textBank(ItemSources.messageCounts.berry)
  local function u16(v)
    return string.char(v % 256, math.floor(v / 256) % 256)
  end
  local function u32(v)
    return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
  end
  local function packNarc(blobs)
    local btaf = u16(#blobs) .. u16(0)
    local running = 0
    for _, bytes in ipairs(blobs) do
      btaf = btaf .. u32(running) .. u32(running + #bytes)
      running = running + #bytes
    end
    local function block(magic, payload)
      return magic .. u32(8 + #payload) .. payload
    end
    return "NARC"
      .. string.char(0xFF, 0xFE)
      .. u16(0x0100)
      .. u32(0x10 + 8 + #btaf + 8 + running)
      .. u16(0x10)
      .. u16(2)
      .. block("BTAF", btaf)
      .. block("GMIF", table.concat(blobs))
  end
  local Narc = require("libs.nds.src.nitro.Narc")
  local itemBytes = packNarc(members)
  local messageBytes = packNarc(banks)
  return {
    openNarc = function(_, alias)
      assert(alias == "item_data" or alias == "messages", "unexpected archive " .. tostring(alias))
      if alias == "messages" then
        return assert(Narc.open(messageBytes, alias))
      end
      return assert(Narc.open(itemBytes, alias))
    end,
    version = function()
      return "heartgold"
    end,
  }
end

function T.item_price_is_required_source_metadata_from_decode_through_catalog()
  local zero = assert(compiler().decodeItemData(memberWith(0, 128, 0), {
    archive = "item_data",
    memberId = 17,
  }))
  local listed = assert(compiler().decodeItemData(memberWith(0, 128, 301), {
    archive = "item_data",
    memberId = 18,
  }))
  Assert.equal(zero.price, 0, "zero is a valid item price")
  Assert.equal(listed.price, 301, "item price is decoded in source money units")

  local partyPotion = catalogBytes(128, true, { 0, 0, 0, 0, 0, 0x04, 0 }, { 0, 0, 0, 0, 0, 0, 20 }, 0)
  local partyAntidote = catalogBytes(128, true, { 0, 0, 0, 0, 0, 0x04, 0 }, { 0, 0, 0, 0, 0, 0, 20 }, 301)
  local root = assert(compiler().compileCatalog(stubCatalogRom({ [17] = partyPotion, [18] = partyAntidote }), {
    versionId = "heartgold",
  }))
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local ItemAssetSchema = require("libs.assets.src.ItemAssetSchema")
  local items = ItemCatalog.new(root)
  Assert.equal(items:item("POTION").price, 0)
  Assert.equal(items:item("ANTIDOTE").price, 301)
  Assert.equal(math.floor(items:item("ANTIDOTE").price / 2), 150, "a consumer can derive the sale value from catalog metadata")
  Assert.equal(items:item("POTION").pocket, "medicine")
  Assert.equal(items:item("POTION").partyUse.kind, "medicine")
  Assert.equal(items:item("POTION").partyUse.restore.amount, 20)
  Assert.isFalse(items:item("POTION").preventToss)
  Assert.equal(items:item("POTION").icon, "POTION", "existing icon metadata survives price projection")

  root.items.POTION.price = nil
  Assert.isFalse(ItemAssetSchema.isValidCatalog(root), "the strict item schema rejects a missing price")
end

function T.mixed_party_families_fail_the_catalog_build()
  -- Potion shape carrying both a healing flag and a power-point flag.
  local mixed = catalogBytes(0, true, { 0, 0, 0, 0, 0, 0x05, 0 }, { 0, 0, 0, 0, 0, 0, 20, 10, 0, 0, 0 })
  local catalog, err = compiler().compileCatalog(stubCatalogRom({ [17] = mixed }), { versionId = "heartgold" })
  Assert.isNil(catalog)
  assert(err, "mixed effect families must fail the build")
  Assert.equal(err.code, "ITEM_PARTY_EFFECT_CONFLICT")
end

function T.shared_pp_operation_prefers_the_strongest_boost()
  -- Ether shape carrying ppUp, ppMax, and ppRestore together.
  local etherBytes = catalogBytes(0, true, { 0, 0, 0, 0, 0xC0, 0x01, 0 }, { 0, 0, 0, 0, 0, 0, 0, 10, 0, 0, 0 })
  local catalog = assert(compiler().compileCatalog(stubCatalogRom({ [38] = etherBytes }), { versionId = "heartgold" }))
  local ether = assert(catalog.items.ETHER, "ETHER must compile")
  Assert.equal(ether.partyUse.kind, "pp")
  Assert.equal(ether.partyUse.boost, 1)
end

function T.pins_the_machine_berry_and_mail_ranges()
  Assert.equal(ItemSources.FIRST_TM, 328)
  Assert.equal(ItemSources.LAST_HM, 427)
  Assert.equal(ItemSources.FIRST_BERRY, 149)
  Assert.equal(ItemSources.LAST_BERRY, 212)
  Assert.equal(ItemSources.FIRST_MAIL, 137)
  Assert.equal(ItemSources.LAST_MAIL, 148)
  Assert.equal(ItemSources.pocketKeys[0], "items")
  Assert.equal(ItemSources.pocketKeys[7], "key_items")
  Assert.equal(ItemSources.messageBanks.name, 222)
  Assert.equal(ItemSources.messageBanks.description, 221)
  Assert.equal(ItemSources.messageBanks.pocket, 226)
  Assert.equal(ItemSources.messageBanks.berry, 251)
end

function T.battle_only_items_carry_their_decoded_battle_use()
  -- X-attack shape: party-use byte set with only the attack-stage
  -- nibble, so party normalization defers to battle-only riders.
  local xAttack = catalogBytes(0, true, { 0, 0x10, 0, 0, 0, 0, 0 }, nil)
  local catalog = assert(compiler().compileCatalog(stubCatalogRom({ [57] = xAttack }), { versionId = "heartgold" }))
  local attack = assert(catalog.items.X_ATTACK, "X_ATTACK must compile")
  Assert.equal(attack.partyUse.kind, "deferred")
  Assert.equal(attack.partyUse.reason, "battle_only")
  local battleUse = assert(attack.battleUse, "battle-only items carry their battle use")
  Assert.deepEqual(battleUse.cures, { confusion = false, infatuation = false })
  Assert.isFalse(battleUse.guardSpec)
  Assert.deepEqual(battleUse.stages, {
    attack = 1,
    defense = 0,
    specialAttack = 0,
    specialDefense = 0,
    speed = 0,
    accuracy = 0,
    critical = 0,
  })
  -- Dire-hit shape: only the critical-rate bits set.
  local direHit = catalogBytes(0, true, { 0, 0, 0, 0, 0x10, 0, 0 }, nil)
  local catalogHit =
    assert(compiler().compileCatalog(stubCatalogRom({ [56] = direHit }), { versionId = "heartgold" }))
  local hit = assert(catalogHit.items.DIRE_HIT, "DIRE_HIT must compile")
  Assert.equal(hit.partyUse.kind, "deferred")
  local hitUse = assert(hit.battleUse, "dire hit carries its battle use")
  Assert.equal(hitUse.stages.critical, 1)
  Assert.equal(hitUse.stages.attack, 0)
  -- Guard-spec shape: only the guard flag set.
  local guardSpec = catalogBytes(0, true, { 0x80, 0, 0, 0, 0, 0, 0 }, nil)
  local catalogGuard =
    assert(compiler().compileCatalog(stubCatalogRom({ [55] = guardSpec }), { versionId = "heartgold" }))
  local guard = assert(catalogGuard.items.GUARD_SPEC_, "GUARD_SPEC_ must compile")
  Assert.equal(guard.partyUse.kind, "deferred")
  Assert.isTrue(assert(guard.battleUse, "guard spec carries its battle use").guardSpec)
  -- Ordinary medicine carries no battle use: the potion shape maps to
  -- its party family without riders.
  local potion = catalogBytes(0, true, { 0, 0, 0, 0, 0, 0x04, 0 }, { 0, 0, 0, 0, 0, 0, 20 })
  local catalogPotion =
    assert(compiler().compileCatalog(stubCatalogRom({ [17] = potion }), { versionId = "heartgold" }))
  Assert.isNil(catalogPotion.items.POTION.battleUse, "ordinary medicine carries no battle use")
end

return { tests = T }
