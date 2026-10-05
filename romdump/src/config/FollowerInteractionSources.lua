-- Pinned HGSS interaction archive identities and record sizes. The decoder
-- follows the retail matcher and task routines in overlay_02_02248728.s
-- (pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36).

local FollowerInteractionSources = {}

FollowerInteractionSources.ARCHIVES = {
  rules = "follower_interaction_rules",
  programs = "follower_interaction_programs",
  motions = "follower_interaction_motions",
  speciesClasses = "follower_interaction_species_classes",
}

FollowerInteractionSources.RULE_SIZE = 20
FollowerInteractionSources.COMMON_RULE_COUNT = 70
FollowerInteractionSources.SECTION_RULE_COUNT = 30
FollowerInteractionSources.PROGRAM_SIZE = 52
FollowerInteractionSources.MOTION_SIZE = 80
FollowerInteractionSources.SPECIES_CLASS_SOURCE_SIZE = 496
FollowerInteractionSources.ACCESSORY_COUNT = 100
FollowerInteractionSources.PLAIN_ACCESSORY_BANK = 216
FollowerInteractionSources.ARTICLE_ACCESSORY_BANK = 217

return FollowerInteractionSources
