-- Stable error codes for the generated map-cache asset contract. The
-- producer (MapCacheWriter) and the contract owner (MapAssetCache) raise
-- Errors with exactly these codes; modules must reference the named
-- constants, never bare literals, so a rename stays in one place. Pure
-- domain module: no love dependency.

local Errors = {}

Errors.MAP_CACHE_BAD_TERRAIN = "MAP_CACHE_BAD_TERRAIN"
Errors.MAP_CACHE_BAD_NEIGHBOR_TERRAIN = "MAP_CACHE_BAD_NEIGHBOR_TERRAIN"
Errors.MAP_CACHE_READBACK_FAILED = "MAP_CACHE_READBACK_FAILED"
Errors.MAP_CACHE_MISSING_ASSET = "MAP_CACHE_MISSING_ASSET"
Errors.MAP_CACHE_SCENE_INVALID = "MAP_CACHE_SCENE_INVALID"
-- The League ending's generated bundle: a missing, partial or malformed
-- registration/showcase/credit-roll section.
Errors.ENDING_ASSET_INVALID = "ENDING_ASSET_INVALID"

return Errors
