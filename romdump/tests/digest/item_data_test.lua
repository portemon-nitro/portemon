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

local function memberWith(holdEffect, word)
  local low = word % 256
  local high = math.floor(word / 256) % 256
  return string.char(100, 0, holdEffect, 0, 0, 0, 0, 0, low, high) .. string.rep("\0", 34 - 10)
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
  -- naturalGiftType and battlePocket bits never leak into catalog facts.
  local word = 31 + 31 * 2048
  local decoded = assert(compiler().decodeItemData(memberWith(0, word), {
    archive = "item_data",
    memberId = 149,
  }))
  Assert.equal(decoded.fieldPocket, 0)
  Assert.isFalse(decoded.preventToss)
  Assert.isFalse(decoded.selectable)
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

return { tests = T }
