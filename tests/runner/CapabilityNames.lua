-- The runner-owned capability names, shared so `Capabilities` (detection),
-- `Cli` (ROM-gated requirement selection), and `Suite` (declaration
-- validation) cannot drift out of agreement on the same string.

local CapabilityNames = {}

CapabilityNames.GRAPHICS = "graphics"
CapabilityNames.ROM_DUMP = "rom_dump"
CapabilityNames.DERIVED_ASSETS = "derived_assets"
CapabilityNames.COMPLETE_DERIVED_CACHE = "complete_derived_cache"

return CapabilityNames
