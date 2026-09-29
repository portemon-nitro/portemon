-- Capability detection consumes host facts and the shell's prepared
-- requirement handoff; no cache identity is reconstructed in the child.

local Assert = require("tests.support.Assert")
local Capabilities = require("tests.runner.Capabilities")

local T = {}

local PREPARED_REQUIREMENTS = "PORTEMON_TEST_PREPARED_REQUIREMENTS"

local function detect(ready, prepared)
  return Capabilities.detect({
    versions = { "heartgold", "soulsilver" },
    isReady = function(versionId)
      return ready[versionId] == true
    end,
    env = prepared and { [PREPARED_REQUIREMENTS] = prepared } or {},
    graphics = false,
    image = false,
  })
end

function T.a_graphics_host_without_image_tooling_fails_the_preflight()
  local err = Assert.throws(function()
    Capabilities.detect({
      versions = {},
      env = {},
      graphics = { newShader = function() end },
      image = false,
    })
  end)

  Assert.isTrue(tostring(err):find("image", 1, true) ~= nil, "names the missing image namespace")
end

function T.no_ready_dump_offers_no_rom_capabilities()
  local capabilities, versions = detect({}, "map:7")

  Assert.isNil(capabilities.rom_dump)
  Assert.isNil(capabilities.derived_assets)
  Assert.isNil(capabilities.complete_derived_cache)
  Assert.deepEqual(versions, {})
end

function T.prepared_requirements_select_none_partial_or_complete_cache_capabilities()
  local none, _ = detect({ heartgold = true }, "")
  Assert.isTrue(none.rom_dump)
  Assert.isNil(none.derived_assets)
  Assert.isNil(none.complete_derived_cache)

  local partial, _ = detect({ heartgold = true }, "map:7 message-bank:542")
  Assert.isTrue(partial.derived_assets, "a bounded requirement list prepares derived assets")
  Assert.isNil(partial.complete_derived_cache, "bounded requirements do not imply the full corpus")

  local complete, _ = detect({ heartgold = true }, "bootstrap complete")
  Assert.isTrue(complete.derived_assets, "the complete corpus contains partial closures")
  Assert.isTrue(complete.complete_derived_cache, "the complete token grants the complete-corpus capability")
end

return { tests = T }
