-- Fixed tree identities from pret/pokeheartgold src/apricorn_tree_sys.c at
-- 971a70c2d4af62aa508830e97d35ea50283d5e8a.
-- Map objects use the matching BONGURI_* sprite while ripe and BONGURI when
-- the source animation consumes the fruit.

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
