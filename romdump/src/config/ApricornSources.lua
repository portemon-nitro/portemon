-- Tree colors come from pret/pokeheartgold src/apricorn_tree_sys.c at
-- 971a70c2d4af62aa508830e97d35ea50283d5e8a. Sprite identities come from
-- pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981:
-- include/constants/sprites.h defines SPRITE_BONGURI and SPRITE_BONMI_*;
-- asm/overlay_01_sprite_data.s maps them to MMODEL_BONGURI* and MMODEL_BONMI*;
-- src/field/apricorn_tree_anim.c creates fruit as SPRITE_BONMI_R + apricornType.

local ApricornSources = {}
ApricornSources.depletedTreeSpriteId = 262
ApricornSources.treeSpriteIdByKey = {
  RED_APRICORN = 263,
  YLW_APRICORN = 264,
  BLU_APRICORN = 265,
  GRN_APRICORN = 266,
  PNK_APRICORN = 267,
  WHT_APRICORN = 268,
  BLK_APRICORN = 269,
}

ApricornSources.fruitSpriteIdByKey = {
  RED_APRICORN = 270,
  YLW_APRICORN = 271,
  BLU_APRICORN = 272,
  GRN_APRICORN = 273,
  PNK_APRICORN = 274,
  WHT_APRICORN = 275,
  BLK_APRICORN = 276,
}

ApricornSources.treeByIndex = {
  [0] = "BLK_APRICORN",
  "PNK_APRICORN",
  "YLW_APRICORN",
  "GRN_APRICORN",
  "BLU_APRICORN",
  "GRN_APRICORN",
  "GRN_APRICORN",
  "PNK_APRICORN",
  "BLK_APRICORN",
  "PNK_APRICORN",
  "BLK_APRICORN",
  "GRN_APRICORN",
  "BLU_APRICORN",
  "RED_APRICORN",
  "BLU_APRICORN",
  "BLK_APRICORN",
  "WHT_APRICORN",
  "GRN_APRICORN",
  "PNK_APRICORN",
  "GRN_APRICORN",
  "YLW_APRICORN",
  "BLK_APRICORN",
  "RED_APRICORN",
  "GRN_APRICORN",
  "GRN_APRICORN",
  "YLW_APRICORN",
  "BLU_APRICORN",
  "WHT_APRICORN",
  "RED_APRICORN",
  "YLW_APRICORN",
  "WHT_APRICORN",
}

return ApricornSources
