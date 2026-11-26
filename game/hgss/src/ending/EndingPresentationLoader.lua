-- The one feature-local admission owner behind the League ending's generated
-- bundle: the registration, showcase and credit-roll sections plus the
-- published images the admitted phase actually draws. Both the field ending
-- and the PC showcase consume this owner so pending/terminal/ready mean the
-- same thing on both routes. GPU upload is selective to the required
-- sections, but bundle load still validates every section; a malformed
-- credits section fails the showcase load as well.
--
-- Pending stays pending with no failure; a terminal demand failure, a
-- malformed bundle, or a missing required image attributes its failure. Ready
-- publishes only after validation and the actually required draw resources
-- are admitted.

local EndingPresentationLoader = {}

-- Sections whose published images the showcase draws. The showcase
-- record pages draw windows, text and party icons; credit scenes and The End
-- are not uploaded on the showcase path, though bundle validation still
-- covers them.
EndingPresentationLoader.SHOWCASE_SECTIONS = { "showcase" }
EndingPresentationLoader.ENDING_SECTIONS = { "registration", "showcase", "credits" }

---@param sections string[]|nil
---@return boolean needsCredits
local function needsCredits(sections)
  if sections == nil then
    return true
  end
  for _, name in ipairs(sections) do
    if name == "credits" then
      return true
    end
  end
  return false
end

---@param cacheFs table<string, unknown>
---@param path string
---@return boolean missing
local function missingImage(cacheFs, path)
  local existsOk, exists = pcall(function()
    return cacheFs:exists(path)
  end)
  return not existsOk or not exists
end

---@param bundle table<string, unknown>
---@param cacheFs table<string, unknown>
---@param sections string[]|nil
---@return string? failure
local function checkRequiredImages(bundle, cacheFs, sections)
  if not needsCredits(sections) then
    return nil
  end
  local credits = bundle.credits
  if type(credits) ~= "table" or type(credits.scenes) ~= "table" then
    return "League ending bundle failed: credit scenes are missing"
  end
  for _, scene in ipairs(credits.scenes) do
    for _, layer in ipairs({ scene.lower, scene.upper }) do
      if type(layer) ~= "table" or type(layer.path) ~= "string" then
        return "League ending bundle failed: a credit scene names no image"
      end
      if missingImage(cacheFs, layer.path) then
        return "League ending bundle failed: missing credit image " .. tostring(layer.path)
      end
    end
  end
  local theEnd = credits.theEnd
  if type(theEnd) ~= "table" or type(theEnd.path) ~= "string" then
    return "League ending bundle failed: The End names no image"
  end
  if missingImage(cacheFs, theEnd.path) then
    return "League ending bundle failed: missing The End image " .. tostring(theEnd.path)
  end
  return nil
end

-- Admit one generated bundle into a presentation owner through the shared
-- pending/terminal contract.
---@param presentation table<string, unknown> the presentation owner to prepare
---@param env { cacheFs: table<string, unknown>|nil, requestEnding: (fun(urgency: string): unknown)|nil, requiredSections: string[]|nil }
---@return table<string, unknown>|nil presentation
---@return string? failure terminal preparation failure, nil while pending or ready
function EndingPresentationLoader.prepare(presentation, env)
  assert(presentation ~= nil, "the ending admission needs its presentation owner")
  assert(type(env) == "table", "the ending admission needs its environment")
  if presentation:isReady() then
    return presentation, nil
  end
  local demandReady = false
  if env.requestEnding ~= nil then
    local ready, requestFailure = env.requestEnding("required")
    if requestFailure ~= nil then
      return nil, "League ending demand failed: " .. tostring(requestFailure)
    end
    demandReady = ready == true
  end
  local cacheFs = env.cacheFs
  if cacheFs == nil then
    return presentation, nil
  end
  local EndingAssetCache = require("libs.assets.src.ending.EndingAssetCache")
  local loadOk, bundle = pcall(EndingAssetCache.load, cacheFs)
  if not loadOk or type(bundle) ~= "table" then
    if demandReady then
      return nil, "League ending bundle failed: " .. tostring(bundle)
    end
    return presentation, nil
  end
  local imageFailure = checkRequiredImages(bundle, cacheFs, env.requiredSections)
  if imageFailure ~= nil then
    return nil, imageFailure
  end
  local prepareOk, prepareErr = pcall(presentation.prepare, presentation, bundle)
  if not prepareOk then
    return nil, "League ending bundle failed: " .. tostring(prepareErr)
  end
  return presentation, nil
end

return EndingPresentationLoader
