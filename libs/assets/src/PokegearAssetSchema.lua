-- Strict source-independent manifest shape for the HGSS Pokegear family:
-- six-skin planes, anchored animation frames, and the immutable
-- contact/map/radio semantic catalogs. Custom source-neutral records
-- validate here without ROM identities; producer/audit boundaries use
-- validate, while warm runtime reads trust the published receipt.

local Contract = require("libs.assets.src.DerivedAssetContract")
local Errors = require("libs.errors.src.Errors")

local PokegearAssetSchema = { SCHEMA = Contract.pokegear.schema }

PokegearAssetSchema.ERROR = {
  SCHEMA_MISMATCH = "POKEGEAR_SCHEMA_MISMATCH",
  SHAPE_INVALID = "POKEGEAR_SHAPE_INVALID",
  DUPLICATE_KEY = "POKEGEAR_DUPLICATE_KEY",
  DANGLING_REFERENCE = "POKEGEAR_DANGLING_REFERENCE",
}

local ASSET_PREFIX = "assets/generated/pokegear/"
local NATIVE_MAP_COUNT = 540

local ROOT_FIELDS = {
  schema = true,
  skins = true,
  shell = true,
  configure = true,
  phone = true,
  map = true,
  fly = true,
  radio = true,
  catalog = true,
  text = true,
  sequences = true,
}

local CATALOG_FIELDS = {
  contacts = true,
  contactOrder = true,
  callDefinitions = true,
  safariAreaMessageBank = true,
  callPermissions = true,
  momCallIntroParameters = true,
  callTriggers = true,
  friendMapPhrases = true,
  rematches = true,
  rematchSets = true,
  gifts = true,
  momPurchases = true,
  locations = true,
  flypoints = true,
  reception = true,
  shows = true,
  radioEffects = true,
  landmarkLabels = true,
  regionMap = true,
}

local PLAY_MODES = {
  forward = true,
  forward_loop = true,
  reverse = true,
  reverse_loop = true,
}

local function fail(code, message, context)
  return Errors.new(code, message, context or {})
end

local function isInteger(value)
  return type(value) == "number" and value % 1 == 0
end

local function checkAssetPath(path, label)
  if type(path) ~= "string" or path:sub(1, #ASSET_PREFIX) ~= ASSET_PREFIX then
    return fail(
      PokegearAssetSchema.ERROR.SHAPE_INVALID,
      label .. " must reference a pokegear-owned asset",
      { label = label }
    )
  end
  if path:find("\\", 1, true) then
    return fail(
      PokegearAssetSchema.ERROR.SHAPE_INVALID,
      label .. " must use canonical asset path separators",
      { label = label }
    )
  end
  for component in (path:sub(#ASSET_PREFIX + 1) .. "/"):gmatch("(.-)/") do
    if component == "" or component == "." or component == ".." or component:find("\0", 1, true) then
      return fail(
        PokegearAssetSchema.ERROR.SHAPE_INVALID,
        label .. " must stay within the pokegear asset family",
        { label = label }
      )
    end
  end
  return nil
end

local function checkVisual(visual, label)
  if type(visual) ~= "table" then
    return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. " must be a visual record", { label = label })
  end
  for _, key in ipairs({ "image", "width", "height", "anchorX", "anchorY" }) do
    if visual[key] == nil then
      return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. " is missing " .. key, { label = label })
    end
  end
  for key in pairs(visual) do
    if key ~= "image" and key ~= "width" and key ~= "height" and key ~= "anchorX" and key ~= "anchorY" then
      return fail(
        PokegearAssetSchema.ERROR.SHAPE_INVALID,
        label .. " has unexpected key " .. tostring(key),
        { label = label }
      )
    end
  end
  local pathError = checkAssetPath(visual.image, label .. ".image")
  if pathError then
    return pathError
  end
  for _, key in ipairs({ "width", "height" }) do
    if not isInteger(visual[key]) or visual[key] <= 0 then
      return fail(
        PokegearAssetSchema.ERROR.SHAPE_INVALID,
        label .. "." .. key .. " must be a positive integer",
        { label = label }
      )
    end
  end
  for _, key in ipairs({ "anchorX", "anchorY" }) do
    if not isInteger(visual[key]) then
      return fail(
        PokegearAssetSchema.ERROR.SHAPE_INVALID,
        label .. "." .. key .. " must be an integer source-local anchor",
        { label = label }
      )
    end
  end
  return nil
end

local function checkFrame(frame, label)
  if type(frame) ~= "table" then
    return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. " must be a rendered frame", { label = label })
  end
  local duration = frame.durationTicks ~= nil and frame.durationTicks or frame.duration
  local visualError = checkVisual({
    image = frame.image,
    width = frame.width,
    height = frame.height,
    anchorX = frame.anchorX,
    anchorY = frame.anchorY,
  }, label)
  if visualError then
    return visualError
  end
  if not isInteger(duration) or duration <= 0 then
    return fail(
      PokegearAssetSchema.ERROR.SHAPE_INVALID,
      label .. " must carry a positive source duration",
      { label = label }
    )
  end
  for key in pairs(frame) do
    if
      key ~= "image"
      and key ~= "width"
      and key ~= "height"
      and key ~= "anchorX"
      and key ~= "anchorY"
      and key ~= "duration"
      and key ~= "durationTicks"
    then
      return fail(
        PokegearAssetSchema.ERROR.SHAPE_INVALID,
        label .. " has unexpected key " .. tostring(key),
        { label = label }
      )
    end
  end
  return nil
end

-- Loop behavior stays a source play mode plus a loop-start frame, never a
-- boolean flag or a frame-rate shorthand.
local function checkAnimation(record, label)
  if type(record) ~= "table" or type(record.frames) ~= "table" or #record.frames == 0 then
    return fail(
      PokegearAssetSchema.ERROR.SHAPE_INVALID,
      label .. " must carry ordered animation frames",
      { label = label }
    )
  end
  for key in pairs(record) do
    if
      key ~= "frames"
      and key ~= "playMode"
      and key ~= "loopStart"
      and key ~= "loopStartFrameIdx"
      and key ~= "loopStartFrame"
    then
      return fail(
        PokegearAssetSchema.ERROR.SHAPE_INVALID,
        label .. " has unexpected key " .. tostring(key),
        { label = label }
      )
    end
  end
  if type(record.playMode) ~= "string" or not PLAY_MODES[record.playMode] then
    return fail(
      PokegearAssetSchema.ERROR.SHAPE_INVALID,
      label .. " must carry a source play mode, never a boolean",
      { label = label }
    )
  end
  local loopStart = record.loopStart
  if loopStart == nil then
    loopStart = record.loopStartFrameIdx
  end
  if loopStart == nil then
    loopStart = record.loopStartFrame
  end
  if not isInteger(loopStart) or loopStart < 0 or loopStart >= #record.frames then
    return fail(
      PokegearAssetSchema.ERROR.SHAPE_INVALID,
      label .. " must carry its source loop-start frame",
      { label = label }
    )
  end
  if record.fps ~= nil then
    return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. " carries no frame rate shorthand", { label = label })
  end
  for index, frame in ipairs(record.frames) do
    local frameError = checkFrame(frame, label .. ".frames[" .. index .. "]")
    if frameError then
      return frameError
    end
  end
  return nil
end

-- Sections carry nested visuals and animations under app-owned role names;
-- any table shaped like a visual or an animation is validated as one.
local function checkSectionVisuals(node, label)
  if type(node) ~= "table" then
    return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. " must be a record", { label = label })
  end
  if next(node) == nil then
    return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. " must not be empty", { label = label })
  end
  if node.image ~= nil then
    return checkVisual(node, label)
  end
  if node.frames ~= nil then
    return checkAnimation(node, label)
  end
  for key, child in pairs(node) do
    if type(child) == "table" then
      local childError = checkSectionVisuals(child, label .. "." .. tostring(key))
      if childError then
        return childError
      end
    elseif type(child) ~= "number" and type(child) ~= "string" and type(child) ~= "boolean" then
      return fail(
        PokegearAssetSchema.ERROR.SHAPE_INVALID,
        label .. "." .. tostring(key) .. " must be a visual, animation, or scalar",
        { label = label }
      )
    end
  end
  return nil
end

local function checkSkins(value)
  if type(value) ~= "table" then
    return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "skins must list the six source skins", {})
  end
  local count, seen = 0, {}
  for key, entry in pairs(value) do
    count = count + 1
    if type(entry) == "number" then
      if not isInteger(entry) or entry < 0 or entry > 5 or seen[entry] then
        return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "skins carries an invalid skin identity", { key = key })
      end
      seen[entry] = true
    elseif type(entry) == "table" and entry.image ~= nil then
      local visualError = checkVisual(entry, "skins." .. tostring(key))
      if visualError then
        return visualError
      end
      if seen[key] then
        return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "skins carries a duplicate skin", { key = key })
      end
      seen[key] = true
    else
      return fail(
        PokegearAssetSchema.ERROR.SHAPE_INVALID,
        "skins entries are skin identities or compiled visuals",
        { key = key }
      )
    end
  end
  if count ~= 6 then
    return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "skins must list exactly six source skins", { count = count })
  end
  return nil
end

local function checkNamespacedKey(key, label)
  if type(key) ~= "string" or key == "" or key:find(".", 1, true) == nil then
    return fail(
      PokegearAssetSchema.ERROR.SHAPE_INVALID,
      label .. " must carry a namespaced semantic key",
      { label = label }
    )
  end
  return nil
end

local LOCATION_FIELDS = {
  mapId = 65535,
  mapSymbol = false,
  x = 255,
  y = 255,
  width = 15,
  height = 15,
  objXOffset = 15,
  objYOffset = 15,
  flavorEntry = 255,
  previewBlock = 255,
  sectionEntry = 65535,
  overlay = false,
}
local LOCATION_OVERLAY_FIELDS = { srcX = 255, srcY = 255, width = 255, height = 255 }
local FLYPOINT_FIELDS = {
  nameMapId = 65535,
  nameSectionEntry = 65535,
  warpMapId = 65535,
  flypoint = 255,
  x = 255,
  y = 255,
  width = 15,
  height = 15,
  overlay = false,
}
local FLYPOINT_OVERLAY_FIELDS = { srcX = 255, srcY = 255, destX = 15, destY = 15, width = 15, height = 15 }

-- Exact-key record whose integer fields are bounded to [0, max]; a false max
-- marks a field the caller validates itself.
local function checkBoundedRecord(record, fields, label)
  if type(record) ~= "table" then
    return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. " must be a record", {})
  end
  for key in pairs(record) do
    if fields[key] == nil then
      return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. " has unexpected key " .. tostring(key), {})
    end
  end
  for key, max in pairs(fields) do
    local field = record[key]
    if field == nil then
      return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. " is missing " .. key, {})
    end
    if max and (not isInteger(field) or field < 0 or field > max) then
      return fail(
        PokegearAssetSchema.ERROR.SHAPE_INVALID,
        label .. "." .. key .. " must be an integer in [0, " .. max .. "]",
        {}
      )
    end
  end
  return nil
end

local function checkRegionMapList(list, fields, overlayFields, label)
  if type(list) ~= "table" or #list == 0 then
    return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. " must be a non-empty record list", {})
  end
  for key in pairs(list) do
    if not isInteger(key) or key < 1 or key > #list then
      return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. " must be a dense list", {})
    end
  end
  for index, record in ipairs(list) do
    local recordLabel = label .. "[" .. index .. "]"
    local recordError = checkBoundedRecord(record, fields, recordLabel)
    if recordError then
      return recordError
    end
    if fields.mapSymbol == false and (type(record.mapSymbol) ~= "string" or record.mapSymbol == "") then
      return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, recordLabel .. ".mapSymbol must be a string", {})
    end
    local overlayError = checkBoundedRecord(record.overlay, overlayFields, recordLabel .. ".overlay")
    if overlayError then
      return overlayError
    end
  end
  return nil
end

local function checkRegionMap(value)
  if type(value) ~= "table" then
    return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "catalog.regionMap must be a record", {})
  end
  for key in pairs(value) do
    if key ~= "locations" and key ~= "flypoints" then
      return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "catalog.regionMap has unexpected key " .. tostring(key), {})
    end
  end
  return checkRegionMapList(value.locations, LOCATION_FIELDS, LOCATION_OVERLAY_FIELDS, "catalog.regionMap.locations")
    or checkRegionMapList(value.flypoints, FLYPOINT_FIELDS, FLYPOINT_OVERLAY_FIELDS, "catalog.regionMap.flypoints")
end

local function checkCallPermissions(value, requireNativeCoverage)
  if type(value) ~= "table" then
    return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "catalog.callPermissions must be a map record", {})
  end
  local count = 0
  local maxMapId = -1
  for mapId, permissions in pairs(value) do
    if not isInteger(mapId) or mapId < 0 then
      return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "catalog.callPermissions keys must be map IDs", {})
    end
    count = count + 1
    maxMapId = math.max(maxMapId, mapId)
    if type(permissions) ~= "table" then
      return fail(
        PokegearAssetSchema.ERROR.SHAPE_INVALID,
        "catalog.callPermissions entries must be records",
        { mapId = mapId }
      )
    end
    for key in pairs(permissions) do
      if key ~= "incoming" and key ~= "outgoing" then
        return fail(
          PokegearAssetSchema.ERROR.SHAPE_INVALID,
          "catalog.callPermissions entries have unexpected direction " .. tostring(key),
          { mapId = mapId }
        )
      end
    end
    if type(permissions.incoming) ~= "boolean" or type(permissions.outgoing) ~= "boolean" then
      return fail(
        PokegearAssetSchema.ERROR.SHAPE_INVALID,
        "catalog.callPermissions entries require incoming and outgoing booleans",
        { mapId = mapId }
      )
    end
  end
  if requireNativeCoverage and (count ~= NATIVE_MAP_COUNT or maxMapId ~= NATIVE_MAP_COUNT - 1) then
    return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "native catalog.callPermissions must cover every map ID", {})
  end
  if requireNativeCoverage then
    for mapId = 0, NATIVE_MAP_COUNT - 1 do
      if value[mapId] == nil then
        return fail(
          PokegearAssetSchema.ERROR.SHAPE_INVALID,
          "native catalog.callPermissions is missing map " .. mapId,
          { mapId = mapId }
        )
      end
    end
  end
  return nil
end

local function checkCatalog(value)
  if type(value) ~= "table" then
    return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "catalog must be a record", {})
  end
  for key in pairs(value) do
    if not CATALOG_FIELDS[key] then
      return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "catalog has unexpected key " .. tostring(key), {})
    end
  end
  for key in pairs(CATALOG_FIELDS) do
    if
      value[key] == nil
      and key ~= "landmarkLabels"
      and key ~= "callPermissions"
      and key ~= "momCallIntroParameters"
      and key ~= "friendMapPhrases"
      and key ~= "rematchSets"
      and key ~= "safariAreaMessageBank"
    then
      return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "catalog is missing " .. key, {})
    end
  end
  local fullNativeCatalog = type(value.callDefinitions) == "table" and #value.callDefinitions == 455
  if
    value.safariAreaMessageBank ~= nil
    and (not isInteger(value.safariAreaMessageBank) or value.safariAreaMessageBank < 0)
  then
    return fail(
      PokegearAssetSchema.ERROR.SHAPE_INVALID,
      "catalog.safariAreaMessageBank must be a non-negative message bank ID",
      {}
    )
  end
  if fullNativeCatalog and value.safariAreaMessageBank == nil then
    return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "native catalog is missing safariAreaMessageBank", {})
  end
  if fullNativeCatalog and type(value.rematchSets) ~= "table" then
    return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "native catalog is missing rematchSets", {})
  end
  if value.rematchSets ~= nil then
    local groups = {}
    local count = 0
    for baseTrainerId, record in pairs(value.rematchSets) do
      count = count + 1
      if
        not isInteger(baseTrainerId)
        or baseTrainerId <= 0
        or baseTrainerId > 0xFFFF
        or type(record) ~= "table"
        or not isInteger(record.group)
        or record.group < 0
        or record.group >= 63
        or groups[record.group]
        or type(record.trainers) ~= "table"
        or #record.trainers ~= 6
        or record.trainers[1] ~= baseTrainerId
      then
        return fail(
          PokegearAssetSchema.ERROR.SHAPE_INVALID,
          "catalog.rematchSets must key native six-trainer groups",
          {}
        )
      end
      groups[record.group] = true
      local sentinel = false
      for _, trainerId in ipairs(record.trainers) do
        if not isInteger(trainerId) or trainerId < 0 or trainerId > 0xFFFF then
          return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "catalog.rematchSets contains an invalid trainer ID", {})
        end
        if trainerId == 0 then
          sentinel = true
        elseif sentinel then
          return fail(
            PokegearAssetSchema.ERROR.SHAPE_INVALID,
            "catalog.rematchSets has a trainer after its sentinel",
            {}
          )
        end
      end
    end
    if fullNativeCatalog and count ~= 63 then
      return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "native catalog must contain all 63 rematch groups", {})
    end
  end
  if fullNativeCatalog or value.friendMapPhrases ~= nil then
    local rows = value.friendMapPhrases
    if type(rows) ~= "table" or #rows ~= 73 then
      return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "catalog.friendMapPhrases must preserve 73 native rows", {})
    end
    local seenMaps = {}
    for index, row in ipairs(rows) do
      if type(row) ~= "table" then
        return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "catalog.friendMapPhrases rows must be records", {})
      end
      for key in pairs(row) do
        if key ~= "mapId" and key ~= "sourceIndex" and key ~= "unlockGroup" then
          return fail(
            PokegearAssetSchema.ERROR.SHAPE_INVALID,
            "catalog.friendMapPhrases has unexpected row key " .. tostring(key),
            { index = index }
          )
        end
      end
      if
        not isInteger(row.mapId)
        or row.mapId < 0
        or row.mapId >= NATIVE_MAP_COUNT
        or seenMaps[row.mapId]
        or row.sourceIndex ~= index - 1
        or not isInteger(row.unlockGroup)
        or row.unlockGroup < 0
        or row.unlockGroup > 3
      then
        return fail(
          PokegearAssetSchema.ERROR.SHAPE_INVALID,
          "catalog.friendMapPhrases rows must retain unique maps, source order, and unlock groups",
          { index = index }
        )
      end
      seenMaps[row.mapId] = true
    end
  end
  if fullNativeCatalog or value.momCallIntroParameters ~= nil then
    if type(value.momCallIntroParameters) ~= "table" then
      return fail(
        PokegearAssetSchema.ERROR.SHAPE_INVALID,
        "native catalog is missing Mom call introduction parameters",
        {}
      )
    end
    for mapId = 0, NATIVE_MAP_COUNT - 1 do
      local parameter = value.momCallIntroParameters[mapId]
      if not isInteger(parameter) or parameter < 0 then
        return fail(
          PokegearAssetSchema.ERROR.SHAPE_INVALID,
          "catalog.momCallIntroParameters must cover native map IDs with non-negative parameters",
          { mapId = mapId }
        )
      end
    end
    for mapId in pairs(value.momCallIntroParameters) do
      if not isInteger(mapId) or mapId < 0 or mapId >= NATIVE_MAP_COUNT then
        return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "catalog.momCallIntroParameters has an unknown map ID", {})
      end
    end
  end
  if value.callPermissions == nil and fullNativeCatalog then
    return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "native catalog is missing callPermissions", {})
  end
  if value.callPermissions ~= nil then
    local permissionsError = checkCallPermissions(value.callPermissions, fullNativeCatalog)
    if permissionsError then
      return permissionsError
    end
  end
  if type(value.callDefinitions) == "table" and #value.callDefinitions > 0 then
    local labels = value.landmarkLabels
    if
      type(labels) ~= "table"
      or not isInteger(labels.bank)
      or labels.bank < 0
      or not isInteger(labels.fallbackBank)
      or labels.fallbackBank < 0
      or not isInteger(labels.fallbackEntry)
      or labels.fallbackEntry < 0
    then
      return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "catalog.landmarkLabels must carry message references", {})
    end
  end
  local regionMapError = checkRegionMap(value.regionMap)
  if regionMapError then
    return regionMapError
  end
  if type(value.contacts) ~= "table" then
    return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "catalog.contacts must be a record list", {})
  end
  local contactKeys = {}
  for index, contact in ipairs(value.contacts) do
    local label = "catalog.contacts[" .. index .. "]"
    if type(contact) ~= "table" then
      return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. " must be a record", {})
    end
    local keyError = checkNamespacedKey(contact.key, label .. ".key")
    if keyError then
      return keyError
    end
    if contactKeys[contact.key] then
      return fail(
        PokegearAssetSchema.ERROR.DUPLICATE_KEY,
        "duplicate contact key " .. contact.key,
        { key = contact.key }
      )
    end
    contactKeys[contact.key] = true
    if type(value.callDefinitions) == "table" and #value.callDefinitions > 0 then
      if
        type(contact.messageBank) ~= "number"
        or type(contact.name) ~= "table"
        or contact.name.bank ~= contact.messageBank
        or contact.name.entry ~= 0
      then
        return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. " must resolve its name from bank entry zero", {})
      end
      local class = contact.class
      if type(class) ~= "table" then
        return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. ".class must carry a native class rule", {})
      end
      if class.kind == "blank" then
        if class.bank ~= nil or class.entry ~= nil then
          return fail(
            PokegearAssetSchema.ERROR.SHAPE_INVALID,
            label .. ".class blank rule has no message reference",
            {}
          )
        end
      elseif class.kind == "message" then
        if not isInteger(class.bank) or class.bank < 0 or not isInteger(class.entry) or class.entry < 0 then
          return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. ".class message reference is invalid", {})
        end
      else
        return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. ".class has an unknown rule", {})
      end
      if contact.family == "trainer" then
        for _, field in ipairs({ "trainerClass", "trainerId", "mapId" }) do
          if not isInteger(contact[field]) or contact[field] < 0 or contact[field] > 65535 then
            return fail(
              PokegearAssetSchema.ERROR.SHAPE_INVALID,
              label .. "." .. field .. " must preserve its native phonebook value",
              {}
            )
          end
        end
      end
      if contact.family == "trainer" and (fullNativeCatalog or contact.genericCallHeaders ~= nil) then
        local headers = contact.genericCallHeaders
        if type(headers) ~= "table" then
          return fail(
            PokegearAssetSchema.ERROR.SHAPE_INVALID,
            label .. ".genericCallHeaders must carry native source rows",
            {}
          )
        end
        for _, direction in ipairs({ "outgoing", "incoming" }) do
          local rows = headers[direction]
          if type(rows) ~= "table" or #rows ~= 8 then
            return fail(
              PokegearAssetSchema.ERROR.SHAPE_INVALID,
              label .. ".genericCallHeaders." .. direction .. " must preserve eight native slots",
              {}
            )
          end
          for rowIndex, row in ipairs(rows) do
            local rowKeys = { type = true, chance = true, scriptType = true, scriptId = true }
            if type(row) == "table" then
              for key in pairs(row) do
                if not rowKeys[key] then
                  return fail(
                    PokegearAssetSchema.ERROR.SHAPE_INVALID,
                    label
                      .. ".genericCallHeaders."
                      .. direction
                      .. "["
                      .. rowIndex
                      .. "] has unexpected key "
                      .. tostring(key),
                    {}
                  )
                end
              end
            end
            if
              type(row) ~= "table"
              or not isInteger(row.type)
              or (row.type ~= 0 and row.type ~= 255 and (row.type < 1 or row.type > 8))
              or not isInteger(row.chance)
              or row.chance < 0
              or row.chance > 100
              or (row.scriptType ~= 0 and row.scriptType ~= 1 and row.scriptType ~= 2)
              or not isInteger(row.scriptId)
              or (
                row.type == 0 and (row.chance ~= 100 or row.scriptType ~= 0 or row.scriptId ~= 65535)
                or row.type == 255 and (row.chance ~= 0 or row.scriptType ~= 0 or row.scriptId ~= 65535)
                or row.type ~= 0 and row.type ~= 255 and (row.scriptId < 1 or row.scriptId > 455)
              )
            then
              return fail(
                PokegearAssetSchema.ERROR.SHAPE_INVALID,
                label .. ".genericCallHeaders." .. direction .. "[" .. rowIndex .. "] is invalid",
                {}
              )
            end
          end
        end
        for key in pairs(headers) do
          if key ~= "outgoing" and key ~= "incoming" then
            return fail(
              PokegearAssetSchema.ERROR.SHAPE_INVALID,
              label .. ".genericCallHeaders has unexpected key " .. tostring(key),
              {}
            )
          end
        end
      elseif contact.genericCallHeaders ~= nil then
        return fail(
          PokegearAssetSchema.ERROR.SHAPE_INVALID,
          label .. ".genericCallHeaders is only valid for trainer contacts",
          {}
        )
      end
    end
    if contact.sortWeights ~= nil then
      if type(contact.sortWeights) ~= "table" or #contact.sortWeights == 0 then
        return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. ".sortWeights must list source sort weights", {})
      end
      for _, weight in ipairs(contact.sortWeights) do
        if not isInteger(weight) then
          return fail(
            PokegearAssetSchema.ERROR.SHAPE_INVALID,
            label .. ".sortWeights must carry integer source weights",
            {}
          )
        end
      end
    elseif contact.sortWeight ~= nil then
      if not isInteger(contact.sortWeight) then
        return fail(
          PokegearAssetSchema.ERROR.SHAPE_INVALID,
          label .. ".sortWeight must be an integer source weight",
          {}
        )
      end
    end
  end
  if type(value.contactOrder) ~= "table" then
    return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "catalog.contactOrder must list contact keys", {})
  end
  local ordered = {}
  for index, key in ipairs(value.contactOrder) do
    if type(key) ~= "string" then
      return fail(
        PokegearAssetSchema.ERROR.SHAPE_INVALID,
        "catalog.contactOrder[" .. index .. "] must be a contact key",
        {}
      )
    end
    if not contactKeys[key] then
      return fail(
        PokegearAssetSchema.ERROR.DANGLING_REFERENCE,
        "contact order references missing contact " .. key,
        { key = key }
      )
    end
    if ordered[key] then
      return fail(PokegearAssetSchema.ERROR.DUPLICATE_KEY, "contact order repeats contact " .. key, { key = key })
    end
    ordered[key] = true
  end
  for _, key in ipairs({
    "callDefinitions",
    "callTriggers",
    "rematches",
    "gifts",
    "momPurchases",
    "locations",
    "flypoints",
    "reception",
    "radioEffects",
  }) do
    if type(value[key]) ~= "table" then
      return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "catalog." .. key .. " must be a record list", {})
    end
  end
  local triggerSlots = {}
  for index, trigger in ipairs(value.callTriggers) do
    local label = "catalog.callTriggers[" .. index .. "]"
    if
      type(trigger) ~= "table"
      or not isInteger(trigger.slot)
      or trigger.slot < 0
      or type(trigger.key) ~= "string"
      or type(trigger.contact) ~= "string"
      or (trigger.kind ~= 0 and trigger.kind ~= 3)
      or type(trigger.clearOnPickup) ~= "boolean"
      or (trigger.scriptedCallType ~= nil and (trigger.scriptedCallType ~= 3 or not isInteger(
        trigger.predefinedScriptId
      ) or trigger.predefinedScriptId < 0 or trigger.predefinedScriptId > 455))
      or (trigger.scriptedCallType == nil and trigger.predefinedScriptId ~= nil)
    then
      return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. " must carry a source trigger record", {})
    end
    if triggerSlots[trigger.slot] then
      return fail(PokegearAssetSchema.ERROR.DUPLICATE_KEY, label .. " repeats a trigger slot", {})
    end
    if not contactKeys[trigger.contact] then
      return fail(PokegearAssetSchema.ERROR.DANGLING_REFERENCE, label .. " references a missing contact", {})
    end
    triggerSlots[trigger.slot] = true
    for key in pairs(trigger) do
      if
        key ~= "slot"
        and key ~= "key"
        and key ~= "contact"
        and key ~= "kind"
        and key ~= "clearOnPickup"
        and key ~= "scriptedCallType"
        and key ~= "predefinedScriptId"
      then
        return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. " has unexpected key " .. tostring(key), {})
      end
    end
  end
  if #value.momPurchases > 0 and #value.momPurchases ~= 26 then
    return fail(
      PokegearAssetSchema.ERROR.SHAPE_INVALID,
      "catalog.momPurchases must contain nine purchases and seventeen berries",
      {}
    )
  end
  for index, purchase in ipairs(value.momPurchases) do
    local expectedKind = index <= 9 and "purchase" or "berry"
    if
      type(purchase) ~= "table"
      or purchase.kind ~= expectedKind
      or purchase.sourceIndex ~= (index <= 9 and index - 1 or index - 10)
      or not isInteger(purchase.nativeItemId)
      or purchase.nativeItemId <= 0
      or not isInteger(purchase.threshold)
      or (index <= 9 and purchase.threshold <= 0 or index > 9 and purchase.threshold ~= 0)
      or not isInteger(purchase.cost)
      or (index <= 9 and purchase.cost < 0 or index > 9 and purchase.cost ~= 100)
    then
      return fail(
        PokegearAssetSchema.ERROR.SHAPE_INVALID,
        "catalog.momPurchases must preserve native source order and item identities",
        {}
      )
    end
  end
  if #value.callDefinitions > 0 then
    local definitions = value.callDefinitions
    if #definitions ~= 455 then
      return fail(
        PokegearAssetSchema.ERROR.SHAPE_INVALID,
        "catalog.callDefinitions must contain all 455 native scripts",
        {}
      )
    end
    local contactBanks = {}
    for _, contact in ipairs(value.contacts) do
      contactBanks[contact.messageBank] = true
    end
    for index, definition in ipairs(definitions) do
      local label = "catalog.callDefinitions[" .. index .. "]"
      if type(definition) ~= "table" or definition.id ~= index then
        return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. " must preserve its native script index", {})
      end
      for _, gender in ipairs({ "male", "female" }) do
        local message = definition[gender]
        if
          type(message) ~= "table"
          or not isInteger(message.bank)
          or not isInteger(message.entry)
          or message.entry < 0
          or contactBanks[message.bank] ~= true
        then
          return fail(
            PokegearAssetSchema.ERROR.DANGLING_REFERENCE,
            label .. " has a message outside its contact banks",
            {}
          )
        end
      end
      if definition.male.bank ~= definition.female.bank then
        return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. " gender messages must share a caller bank", {})
      end
      if
        definition.kind ~= "none"
        and definition.kind ~= "flag"
        and definition.kind ~= "rematch"
        and definition.kind ~= "item"
        and definition.kind ~= "word"
      then
        return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. " has an unknown native script type", {})
      end
    end
  end
  if type(value.shows) ~= "table" then
    return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "catalog.shows must be a record list", {})
  end
  local showKeys = {}
  for index, show in ipairs(value.shows) do
    local label = "catalog.shows[" .. index .. "]"
    if type(show) ~= "table" then
      return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. " must be a record", {})
    end
    local keyError = checkNamespacedKey(show.key, label .. ".key")
    if keyError then
      return keyError
    end
    if showKeys[show.key] then
      return fail(PokegearAssetSchema.ERROR.DUPLICATE_KEY, "duplicate show key " .. show.key, { key = show.key })
    end
    showKeys[show.key] = true
  end
  return nil
end

local function checkSequences(value, label)
  if type(value) ~= "table" then
    return fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. " must be a record", { label = label })
  end
  for key, child in pairs(value) do
    if type(child) == "table" and child.frames ~= nil then
      local childError = checkAnimation(child, label .. "." .. tostring(key))
      if childError then
        return childError
      end
    elseif type(child) == "table" then
      local childError = checkSequences(child, label .. "." .. tostring(key))
      if childError then
        return childError
      end
    else
      return fail(
        PokegearAssetSchema.ERROR.SHAPE_INVALID,
        label .. "." .. tostring(key) .. " must be an animation or animation map",
        { label = label }
      )
    end
  end
  return nil
end

---@param manifest unknown
---@return table<string, unknown>|nil record
---@return Errors.Error|nil
function PokegearAssetSchema.validate(manifest)
  if type(manifest) ~= "table" then
    return nil, fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "root must be a record", {})
  end
  ---@cast manifest table<string, unknown>
  for key in pairs(manifest) do
    if not ROOT_FIELDS[key] then
      return nil, fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "root has unexpected key " .. tostring(key), {})
    end
  end
  for key in pairs(ROOT_FIELDS) do
    if manifest[key] == nil then
      return nil, fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "root is missing " .. key, {})
    end
  end
  if manifest.schema ~= PokegearAssetSchema.SCHEMA then
    return nil,
      fail(
        PokegearAssetSchema.ERROR.SCHEMA_MISMATCH,
        "schema does not match " .. PokegearAssetSchema.SCHEMA,
        { schema = manifest.schema }
      )
  end
  local skinsError = checkSkins(manifest.skins)
  if skinsError then
    return nil, skinsError
  end
  for _, section in ipairs({ "shell", "configure", "phone", "map", "fly", "radio" }) do
    local sectionError = checkSectionVisuals(manifest[section], section)
    if sectionError then
      return nil, sectionError
    end
  end
  local catalogError = checkCatalog(manifest.catalog)
  if catalogError then
    return nil, catalogError
  end
  if type(manifest.text) ~= "table" then
    return nil, fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "text must be a record", {})
  end
  local sequencesError = checkSequences(manifest.sequences, "sequences")
  if sequencesError then
    return nil, sequencesError
  end
  return manifest
end

-- The separately published single-word entry section: eleven ordered
-- source groups with cumulative decimal bases plus the selector cursor
-- sequences. Core manifests never carry this record; producer staging and
-- explicit audit validate it here instead.
---@param section unknown
---@return table<string, unknown>|nil record
---@return Errors.Error|nil
function PokegearAssetSchema.validateWordEntry(section)
  if type(section) ~= "table" then
    return nil, fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "word entry must be a record", {})
  end
  ---@cast section table<string, unknown>
  for key in pairs(section) do
    if key ~= "groups" and key ~= "cursor" and key ~= "background" and key ~= "text" and key ~= "input" then
      return nil, fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "word entry has unexpected key " .. tostring(key), {})
    end
  end
  local groups = section.groups
  if type(groups) ~= "table" or #groups ~= 11 then
    return nil, fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "word entry groups must list eleven source groups", {})
  end
  local base = 0
  for index, entry in ipairs(groups) do
    local label = "word entry groups[" .. index .. "]"
    if type(entry) ~= "table" then
      return nil, fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. " must be a record", {})
    end
    ---@cast entry table<string, unknown>
    for key in pairs(entry) do
      if key ~= "group" and key ~= "bank" and key ~= "count" and key ~= "firstWordId" then
        return nil, fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. " has unexpected key " .. tostring(key), {})
      end
    end
    if entry.group ~= index - 1 then
      return nil, fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. " breaks the source group order", {})
    end
    if
      not isInteger(entry.bank)
      or entry.bank --[[@as integer]]
        <= 0
    then
      return nil, fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. ".bank must be a positive message bank", {})
    end
    if
      not isInteger(entry.count)
      or entry.count --[[@as integer]]
        < 1
    then
      return nil, fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, label .. ".count must be a positive word count", {})
    end
    if entry.firstWordId ~= base then
      return nil,
        fail(
          PokegearAssetSchema.ERROR.SHAPE_INVALID,
          label .. ".firstWordId must continue the cumulative word order",
          {}
        )
    end
    base = base + entry.count --[[@as integer]]
  end
  local cursor = section.cursor
  if type(cursor) ~= "table" then
    return nil, fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "word entry cursor must be a record", {})
  end
  ---@cast cursor table<string, unknown>
  for key in pairs(cursor) do
    if key ~= "sequences" then
      return nil,
        fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "word entry cursor has unexpected key " .. tostring(key), {})
    end
  end
  local sequences = cursor.sequences
  if type(sequences) ~= "table" or #sequences == 0 then
    return nil, fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "word entry cursor must carry its source sequences", {})
  end
  for index, sequence in ipairs(sequences) do
    local sequenceError = checkAnimation(sequence, "word entry cursor.sequences[" .. index .. "]")
    if sequenceError then
      return nil, sequenceError
    end
  end
  local background = section.background
  if type(background) ~= "table" then
    return nil, fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "word entry background must be a record", {})
  end
  ---@cast background table<string, unknown>
  for key in pairs(background) do
    if key ~= "screenMember" and key ~= "charMember" and key ~= "layers" then
      return nil,
        fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "word entry background has unexpected key " .. tostring(key), {})
    end
  end
  if not isInteger(background.screenMember) or not isInteger(background.charMember) then
    return nil, fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "word entry background members must be integers", {})
  end
  local layers = background.layers
  if type(layers) ~= "table" then
    return nil, fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "word entry background layers must be a list", {})
  end
  for _, layer in ipairs(layers) do
    if not isInteger(layer) then
      return nil, fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "word entry background layers must be integers", {})
    end
  end
  local text = section.text
  if type(text) ~= "table" then
    return nil, fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "word entry text must be a record", {})
  end
  ---@cast text table<string, unknown>
  for key in pairs(text) do
    if key ~= "interfaceBanks" and key ~= "interfaceCounts" then
      return nil,
        fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "word entry text has unexpected key " .. tostring(key), {})
    end
  end
  for _, field in ipairs({ "interfaceBanks", "interfaceCounts" }) do
    local list = text[field]
    if type(list) ~= "table" or #list == 0 then
      return nil,
        fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "word entry text." .. field .. " must be a non-empty list", {})
    end
    for _, bank in ipairs(list) do
      if
        not isInteger(bank)
        or bank --[[@as integer]]
          <= 0
      then
        return nil,
          fail(
            PokegearAssetSchema.ERROR.SHAPE_INVALID,
            "word entry text." .. field .. " must carry positive message banks",
            {}
          )
      end
    end
  end
  local input = section.input
  if type(input) ~= "table" then
    return nil, fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "word entry input must be a record", {})
  end
  ---@cast input table<string, unknown>
  for key in pairs(input) do
    if key ~= "hitboxes" and key ~= "touchYMin" and key ~= "touchYMax" and key ~= "confirmSound" then
      return nil,
        fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "word entry input has unexpected key " .. tostring(key), {})
    end
  end
  if
    not isInteger(input.hitboxes)
    or input.hitboxes --[[@as integer]]
      <= 0
  then
    return nil, fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "word entry input.hitboxes must be positive", {})
  end
  if
    not isInteger(input.touchYMin)
    or not isInteger(input.touchYMax)
    or input.touchYMin --[[@as integer]]
      >= input.touchYMax --[[@as integer]]
  then
    return nil, fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "word entry input touch bounds must order", {})
  end
  if
    not isInteger(input.confirmSound)
    or input.confirmSound --[[@as integer]]
      <= 0
  then
    return nil, fail(PokegearAssetSchema.ERROR.SHAPE_INVALID, "word entry input.confirmSound must be positive", {})
  end
  return section
end

---@param manifest unknown
---@return table<string, unknown> record
function PokegearAssetSchema.assertManifest(manifest)
  local record, err = PokegearAssetSchema.validate(manifest)
  if record == nil then
    error(err, 0)
  end
  return record
end

---@param manifest unknown
---@return boolean
function PokegearAssetSchema.isValidManifest(manifest)
  local record = PokegearAssetSchema.validate(manifest)
  return record ~= nil
end

return PokegearAssetSchema
