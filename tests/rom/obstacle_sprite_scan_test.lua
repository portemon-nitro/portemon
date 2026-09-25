-- THROWAWAY ROM scan (delete after capturing counts): correlate facing-object
-- sprite ids 84/85/86 with map symbols, event flags and script ids.

local Assert = require("tests.support.Assert")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local ZoneEvents = require("romdump.src.digest.map.ZoneEvents")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local WANTED = { [84] = true, [85] = true, [86] = true }

function T.scan_obstacle_sprites(romFs, versionId)
  local archive = assert(romFs:openNarc("zone_events"))
  local total = 0
  local bySprite = {}
  local flagValues = {}
  local scriptValues = {}
  local examples = {}
  local mapCount = 0
  for map in MapCatalog.all() do
    if map.eventMemberId ~= nil then
      local ok, bytes = pcall(function()
        return archive:readMember(map.eventMemberId)
      end)
      if ok and bytes ~= nil then
        local decoded = assert(
          ZoneEvents.decode(bytes, { mapId = map.id, eventMemberId = map.eventMemberId }),
          "zone events must decode for the scan"
        )
        mapCount = mapCount + 1
        for _, event in ipairs(decoded.objectEvents) do
          total = total + 1
          if WANTED[event.spriteId] then
            bySprite[event.spriteId] = (bySprite[event.spriteId] or 0) + 1
            flagValues[event.spriteId] = flagValues[event.spriteId] or {}
            flagValues[event.spriteId][event.eventFlag] = (flagValues[event.spriteId][event.eventFlag] or 0) + 1
            scriptValues[event.spriteId] = scriptValues[event.spriteId] or {}
            scriptValues[event.spriteId][event.scriptId] = (scriptValues[event.spriteId][event.scriptId] or 0) + 1
            if #examples < 30 then
              examples[#examples + 1] = string.format(
                "sprite=%d map=%s event=%d flag=%s script=%s x=%s z=%s",
                event.spriteId,
                tostring(map.symbol),
                event.objectEventId,
                tostring(event.eventFlag),
                tostring(event.scriptId),
                tostring(event.x),
                tostring(event.z)
              )
            end
          end
        end
      end
    end
  end
  print("SCAN maps=" .. mapCount .. " objectEvents=" .. total .. " version=" .. tostring(versionId))
  for sprite, count in pairs(bySprite) do
    print("SCAN sprite=" .. sprite .. " count=" .. count)
    local flags = {}
    for flag, n in pairs(flagValues[sprite]) do
      flags[#flags + 1] = tostring(flag) .. "x" .. n
    end
    print("SCAN sprite=" .. sprite .. " flags: " .. table.concat(flags, ","))
    local scripts = {}
    for script, n in pairs(scriptValues[sprite]) do
      scripts[#scripts + 1] = tostring(script) .. "x" .. n
    end
    table.sort(scripts)
    print("SCAN sprite=" .. sprite .. " scripts: " .. table.concat(scripts, ","))
  end
  for _, line in ipairs(examples) do
    print("SCAN example " .. line)
  end
  Assert.isTrue(true)
end

return RomSuite.fromFacts(T)
