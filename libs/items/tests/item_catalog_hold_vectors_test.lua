-- Item holdability and form vectors: the synthetic catalog agrees with the
-- source action contract. TMs stay holdable while HMs and key items never
-- attach, mail stays separate, and only the sixteen plates plus the
-- griseous orb carry a form effect. ROM compilation of the same facts is
-- covered by the item catalog conformance suite.

local Assert = require("tests.support.Assert")
local ItemFixture = require("libs.items.tests.item_fixture")

local T = {}

local function catalog()
  return ItemFixture.makeCatalog()
end

function T.machine_holdability_splits_tm_from_hm()
  local items = catalog()
  Assert.isFalse(items:item("TM01").isHm)
  Assert.isTrue(items:item("TM01").canHold, "TMs may be held")
  local hm = items:item("HM01")
  Assert.isTrue(hm.isHm, "HM01 opens the hidden-move run")
  Assert.isFalse(hm.canHold, "HMs may not be held")
  Assert.equal(hm.nativeId, 420)
  local lastHm = items:item("ITEM_427")
  Assert.isTrue(lastHm.isHm)
  Assert.isFalse(lastHm.canHold)
end

function T.money_up_items_share_one_held_behavior()
  local items = catalog()
  for _, key in ipairs({ "AMULET_COIN", "LUCK_INCENSE" }) do
    local held = assert(items:item(key).heldBehavior, key .. " carries its held behavior")
    Assert.equal(held.key, "money_up", key .. " classifies through the money-up hold effect")
    Assert.equal(held.params.holdEffect, 58, key .. " carries the source hold-effect byte")
  end
  Assert.isNil(items:item("POTION").heldBehavior, "effectless items carry no held behavior")
end

function T.key_items_and_mail_never_attach()
  local items = catalog()
  Assert.isFalse(items:item("BICYCLE").canHold)
  -- Placeholder identities keep their keys, so the mail assertion uses a
  -- native identity the source pocket table assigns to mail.
  local mail = items:item("ITEM_9")
  Assert.equal(mail.pocket, "mail")
  Assert.isFalse(mail.canHold)
end

function T.form_effects_cover_only_plates_and_the_orb()
  local items = catalog()
  Assert.equal(items:item("ITEM_112").heldFormEffect, "griseous_orb")
  for nativeId = 298, 313 do
    Assert.equal(
      items:itemByNativeId(nativeId).heldFormEffect,
      "arceus_plate",
      "plate identity carries its effect: " .. nativeId
    )
  end
  for _, key in ipairs({ "POTION", "TM01", "BICYCLE", "CHERI_BERRY", "SOOTHE_BELL" }) do
    Assert.equal(items:item(key).heldFormEffect, "none", "ordinary items carry no form effect: " .. key)
  end
end

return { tests = T }
