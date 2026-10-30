-- Source-family membership for the generic Bag/item script protocol, audited
-- against the retail ROM. This data is intentionally independent of the
-- implementation catalog: membership states which source commands the
-- Bag/item protocol owns, while the catalog states how each command
-- executes. Supported rows are exactly the generic inventory primitives,
-- item queries, and buffered item text; every other item-touching command
-- stays deferred under its owning gameplay system.
--
-- Explicitly not owned here:
-- - fossil count/restoration (fossil rows below);
-- - Mystery Gift delivery (mystery_gift row below);
-- - daycare/communication sanitization item transfer (opcodes 689 and 690,
--   owned by the mon family as deferred daycare/communication commands);
-- - mart/shop buy/sell (shop rows below);
-- - mail commands (opcodes 428 and 781, owned by the mon family as
--   deferred mail commands);
-- - battle item use, which has no field-script command in this table: battle
--   item handling lives outside the field script protocol, so there is no
--   battle row to claim (representative battle opcodes 213, 220, and 589
--   stay outside this inventory);
-- - phone/gift feature commands, owned by the pocket-gear script family once
--   their executable semantics land (no phone_gift rows remain here);
-- - seal, prize, field rock-smash, and Apricorn/Kurt flows (rows below), whose
--   behavior is primarily another gameplay subsystem even when it reaches
--   inventory;
-- - opcode 757: its name mentions the Bag but it drives a cutscene prop,
--   never inventory, so a name match alone never confers membership.

local commands = {
  { opcode = 125, category = "items" },
  { opcode = 126, category = "items" },
  { opcode = 127, category = "items" },
  { opcode = 128, category = "items" },
  { opcode = 129, category = "items" },
  { opcode = 130, category = "items" },
  { opcode = 194, category = "items" },
  { opcode = 195, category = "items" },
  { opcode = 196, category = "items" },
  { opcode = 336, category = "items" },
  { opcode = 669, category = "items" },
  { opcode = 843, category = "items" },
  { opcode = 844, category = "items" },
  { opcode = 429, category = "fossil" },
  { opcode = 432, category = "fossil" },
  { opcode = 433, category = "fossil" },
  { opcode = 489, category = "mystery_gift" },
  { opcode = 275, category = "shop" },
  { opcode = 276, category = "shop" },
  { opcode = 277, category = "shop" },
  { opcode = 278, category = "shop" },
  { opcode = 782, category = "shop" },
  { opcode = 133, category = "seal" },
  { opcode = 134, category = "seal" },
  { opcode = 135, category = "seal" },
  { opcode = 572, category = "seal" },
  { opcode = 580, category = "seal" },
  { opcode = 850, category = "seal" },
  { opcode = 623, category = "apricorn" },
  { opcode = 624, category = "apricorn" },
  { opcode = 625, category = "apricorn" },
  { opcode = 626, category = "apricorn" },
  { opcode = 735, category = "apricorn" },
  { opcode = 736, category = "apricorn" },
  { opcode = 737, category = "apricorn" },
  { opcode = 738, category = "apricorn" },
  { opcode = 739, category = "apricorn" },
  { opcode = 567, category = "prize" },
  { opcode = 651, category = "prize" },
}

local byOpcode = {}
for _, command in ipairs(commands) do
  byOpcode[command.opcode] = command
end

return {
  commands = commands,
  byOpcode = byOpcode,
}
