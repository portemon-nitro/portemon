-- Source-backed transition resource closure from the pinned pret/pokeheartgold
-- commit 9d8b7591f09b65804da2fb2dfd56f320633e0d36, overlay_120.s.

local Assert = require("tests.support.Assert")
local Sources = require("romdump.src.config.BattlePresentationSources")

local T = {}

local function includesSelector(record, selector)
  for _, candidate in ipairs(record.selectors) do
    if candidate == selector then
      return true
    end
  end
  return false
end

function T.red_transition_closure_contains_every_async_helper_resource()
  local route = assert(Sources.TRANSITION_SELECTOR_ROUTES[46])
  Assert.equal(route.key, "trainer/red", "the Red callback resolves to its semantic route")

  local loaderResources = {
    { member = 0xa0, kind = "palette" },
    { member = 0xa1, kind = "texture" },
    { member = 0xa4, kind = "texture" },
    { member = 0xa2, kind = "map" },
    { member = 0xa5, kind = "map" },
  }
  for _, required in ipairs(loaderResources) do
    local selected = false
    for _, record in ipairs(Sources.TRANSITION_TYPED_RESOURCES) do
      if record.memberId == required.member and record.kind == required.kind then
        selected = selected or includesSelector(record, 46)
      end
    end
    Assert.equal(
      selected,
      true,
      "Red's asynchronous helper load is included in its route closure: " .. required.kind .. "/" .. required.member
    )
  end
end

return { tests = T }
