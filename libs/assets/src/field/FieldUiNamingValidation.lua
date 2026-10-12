-- Validation for the generated field-UI naming-screen manifest section.
local Checks = require("libs.assets.src.field.FieldUiManifestChecks")
local Validate = require("libs.assets.src.Validate")

local reject = Checks.reject
local checkInteger = Checks.checkInteger
local demandCount = Checks.demandCount
local demandDenseSequence = Checks.demandDenseSequence
local checkAtlasRect = Checks.checkAtlasRect
local checkFrameOffset = Checks.checkFrameOffset
local checkSignedPoint = Checks.checkSignedPoint
local isSignedInteger = Checks.isSignedInteger
local checkCanonicalPoint = Checks.checkCanonicalPoint
local ANIMATION_PLAY_MODES = { forward = true, forward_loop = true, reverse = true, reverse_loop = true }
local NAMING_CONTROL_ANCHORS = {
  upper = { x = 26, y = 68 },
  lower = { x = 58, y = 68 },
  symbols = { x = 90, y = 68 },
  back = { x = 158, y = 68 },
  ok = { x = 198, y = 68 },
  backing = { x = 22, y = 56 },
}

local function checkNamingScreenBaseAndPlacement(s, atlases)
  if type(s.base) ~= "table" then
    reject("namingScreen.base must be a table", {})
  end
  local baseAsset = atlases[s.base.asset]
  if type(s.base.asset) ~= "string" or not baseAsset then
    reject("namingScreen.base must reference an indexed asset", {})
  end
  if s.base.width ~= 256 or s.base.height ~= 192 or baseAsset.width ~= 256 or baseAsset.height ~= 192 then
    reject("namingScreen.base must be the opaque 256x192 surface", {})
  end
  if type(s.pages) ~= "table" then
    reject("namingScreen.pages must be a table", {})
  end
  local pageKeys = { "upper", "lower", "symbols" }
  demandCount(s.pages, #pageKeys, "namingScreen.pages must carry exactly upper, lower, and symbols", {})
  for _, key in ipairs(pageKeys) do
    local page = s.pages[key]
    if type(page) ~= "table" then
      reject("namingScreen.pages." .. key .. " must be a table", {})
    end
    local pageAsset = atlases[page.asset]
    if type(page.asset) ~= "string" or not pageAsset then
      reject("namingScreen.pages." .. key .. " must reference an indexed asset", {})
    end
    if page.width ~= 256 or page.height ~= 112 or pageAsset.width ~= 256 or pageAsset.height ~= 112 then
      reject("namingScreen.pages." .. key .. " must be the 256x112 overlay", {})
    end
  end
  local placement = s.placement
  if
    type(placement) ~= "table"
    or placement.x ~= 11
    or placement.y ~= 80
    or placement.width ~= 256
    or placement.height ~= 112
  then
    reject("namingScreen.placement must be the x=11 y=80 overlay", {})
  end
end

local function checkNamingScreenText(text)
  if type(text) ~= "table" then
    reject("namingScreen.text must be a table", {})
  end
  if type(text.name) ~= "table" or text.name.x ~= 80 or text.name.y ~= 24 or text.name.advanceX ~= 12 then
    reject("namingScreen.text.name must be the (80,24)+12px entry origin", {})
  end
  if type(text.keyboard) ~= "table" or type(text.keyboard.cells) ~= "table" then
    reject("namingScreen.text.keyboard.cells must be a table", {})
  end
  demandCount(text.keyboard.cells, 5, "namingScreen.text.keyboard must carry five source rows", {})
  for row = 1, 5 do
    local cells = text.keyboard.cells[row]
    if type(cells) ~= "table" then
      reject("namingScreen.text.keyboard row " .. row .. " is missing", {})
    end
    demandCount(cells, 13, "namingScreen.text.keyboard row " .. row .. " must carry thirteen cells", {})
    for column = 1, 13 do
      local cell = cells[column]
      if
        type(cell) ~= "table"
        or not Validate.isNonNegativeInteger(cell.x)
        or not Validate.isNonNegativeInteger(cell.y)
        or cell.width ~= 16
        or cell.x + cell.width > 256
        or cell.y > 191
      then
        reject("namingScreen.text.keyboard row " .. row .. " column " .. column .. " must be a 16px canonical cell", {})
      end
    end
  end
end

local function checkAnimationRecord(record, atlases, what, isCursor)
  if type(record) ~= "table" then
    reject(what .. " must be a table", { what = what })
  end
  if ANIMATION_PLAY_MODES[record.playMode] ~= true then
    reject(what .. " carries an unsupported play mode", { what = what })
  end
  if type(record.frames) ~= "table" then
    reject(what .. " must carry animation frames", { what = what })
  end
  local frameCount = demandDenseSequence(record.frames, what .. " frames must be a dense sequence", { what = what })
  checkInteger(record.loopStartFrameIdx, 0, frameCount - 1, what .. " loop start is outside its frames", {
    what = what,
  })
  local pulseAsset = nil
  if isCursor then
    pulseAsset = record.pulseAsset
    if type(pulseAsset) ~= "string" or atlases[pulseAsset] == nil then
      reject(what .. " must reference its indexed pulse-mask atlas", { what = what })
    end
  elseif record.pulseAsset ~= nil then
    reject(what .. " carries no pulse-mask role", { what = what })
  end
  for index = 1, frameCount do
    local frame = record.frames[index]
    local frameWhat = what .. " frame " .. index
    if type(frame) ~= "table" then
      reject(frameWhat .. " must be a table", { what = frameWhat })
    end
    if type(frame.asset) ~= "string" or atlases[frame.asset] == nil then
      reject(frameWhat .. " must reference an indexed atlas", { what = frameWhat })
    end
    checkAtlasRect(frame.rect, atlases, frame.asset, frameWhat .. " rect")
    checkFrameOffset(frame.offset, frameWhat .. " must carry the generated frame offset", { what = frameWhat })
    checkInteger(frame.duration, 1, nil, frameWhat .. " duration must be a positive integer", { what = frameWhat })
    if isCursor then
      checkAtlasRect(frame.pulseRect, atlases, pulseAsset, frameWhat .. " pulse rect")
      if frame.pulseRect.width ~= frame.rect.width or frame.pulseRect.height ~= frame.rect.height then
        reject(frameWhat .. " pulse rect must match its frame size", { what = frameWhat })
      end
    elseif frame.pulseRect ~= nil then
      reject(frameWhat .. " carries no pulse-mask role", { what = frameWhat })
    end
  end
end

-- One OAM-composed visual: a generated image drawn at its canonical
-- anchor plus the compositor's frame offset. The asset must be indexed
-- with matching dimensions; the offset may be negative (a cell whose
-- objects start below the source origin shifts the frame).

local function checkNamingSprite(record, atlases, what)
  if type(record) ~= "table" then
    reject(what .. " must be a table", { what = what })
  end
  local asset = atlases[record.asset]
  if type(record.asset) ~= "string" or not asset then
    reject(what .. " must reference an indexed asset", { what = what })
  end
  if record.width ~= asset.width or record.height ~= asset.height then
    reject(what .. " dimensions must match its indexed asset", { what = what })
  end
  if record.width < 1 or record.height < 1 then
    reject(what .. " must be non-empty", { what = what })
  end
  checkCanonicalPoint(record.anchor, what .. " anchor")
  checkFrameOffset(record.offset, what .. " must carry the generated frame offset", { what = what })
end

local function checkNamingScreenControls(controls, atlases)
  if type(controls) ~= "table" then
    reject("namingScreen.controls must be a table", {})
  end
  demandCount(controls, 6, "namingScreen.controls must carry six source visuals", {})
  for id, anchor in pairs(NAMING_CONTROL_ANCHORS) do
    checkNamingSprite(controls[id], atlases, "namingScreen.controls." .. id)
    local recordAnchor = controls[id].anchor
    if recordAnchor.x ~= anchor.x or recordAnchor.y ~= anchor.y then
      reject("namingScreen.controls." .. id .. " must keep its source anchor", {})
    end
  end
end

local function checkNamingScreenCursor(cursor, atlases)
  if type(cursor) ~= "table" then
    reject("namingScreen.cursor must be a table", {})
  end
  local keyboardCursor = cursor.keyboard
  checkAnimationRecord(keyboardCursor, atlases, "namingScreen.cursor.keyboard", true)
  if
    type(keyboardCursor.origin) ~= "table"
    or keyboardCursor.origin.x ~= 26
    or keyboardCursor.origin.y ~= 91
    or keyboardCursor.stepX ~= 16
    or keyboardCursor.stepY ~= 19
  then
    reject("namingScreen.cursor.keyboard must step 16px by 19px from (26,91)", {})
  end
  if type(cursor.home) ~= "table" then
    reject("namingScreen.cursor.home must be a table", {})
  end
  demandCount(cursor.home, 5, "namingScreen.cursor.home must carry five control variants", {})
  for _, id in ipairs({ "upper", "lower", "symbols", "back", "ok" }) do
    checkAnimationRecord(cursor.home[id], atlases, "namingScreen.cursor.home." .. id, true)
    checkCanonicalPoint(cursor.home[id].anchor, "namingScreen.cursor.home." .. id .. " anchor")
  end
end

local function checkNamingScreenEntrySlots(entrySlots, atlases)
  if type(entrySlots) ~= "table" then
    reject("namingScreen.entrySlots must be a table", {})
  end
  if
    type(entrySlots.origin) ~= "table"
    or entrySlots.origin.x ~= 80
    or entrySlots.origin.y ~= 39
    or entrySlots.stepX ~= 12
  then
    reject("namingScreen.entrySlots must start at (80,39) stepping 12px", {})
  end
  checkNamingSprite(entrySlots.normal, atlases, "namingScreen.entrySlots.normal")
  checkAnimationRecord(entrySlots.selected, atlases, "namingScreen.entrySlots.selected", false)
end

local function checkNamingScreenPlayerSubjects(playerSubjects, atlases)
  if type(playerSubjects) ~= "table" then
    reject("namingScreen.playerSubjects must be a table", {})
  end
  demandCount(playerSubjects, 2, "namingScreen.playerSubjects must carry male and female", {})
  for _, id in ipairs({ "male", "female" }) do
    checkAnimationRecord(playerSubjects[id], atlases, "namingScreen.playerSubjects." .. id, false)
    local anchor = playerSubjects[id].anchor
    if type(anchor) ~= "table" or anchor.x ~= 24 or anchor.y ~= 8 then
      reject("namingScreen.playerSubjects." .. id .. " must anchor at (24,8)", {})
    end
  end
end

local function checkNamingScreenPokemonSubjectPart(part, partWhat)
  if
    type(part) ~= "table"
    or part.iconFrame ~= 1
    or type(part.offset) ~= "table"
    or not isSignedInteger(part.offset.x)
    or not isSignedInteger(part.offset.y)
  then
    reject(partWhat .. " is invalid", {})
  end
  if
    part.asset ~= nil
    or part.image ~= nil
    or part.rect ~= nil
    or part.pulseRect ~= nil
    or part.width ~= nil
    or part.height ~= nil
  then
    reject(partWhat .. " carries generated pixels", {})
  end
end

local function checkNamingScreenPokemonSubjectFrame(frame, index)
  local frameWhat = "namingScreen.pokemonSubject frame " .. index
  if type(frame) ~= "table" then
    reject(frameWhat .. " must be a table", {})
  end
  checkInteger(frame.duration, 1, nil, frameWhat .. " has an invalid duration", {})
  if type(frame.parts) ~= "table" then
    reject(frameWhat .. " must carry icon parts", {})
  end
  local partCount = demandDenseSequence(frame.parts, frameWhat .. " must carry a dense nonempty part sequence", {})
  for partIndex = 1, partCount do
    checkNamingScreenPokemonSubjectPart(frame.parts[partIndex], frameWhat .. " part " .. partIndex)
  end
  if frame.offset ~= nil or frame.iconFrame ~= nil or frame.asset ~= nil or frame.rect ~= nil then
    reject("namingScreen.pokemonSubject frames carry no flattened icon record", {})
  end
end

local function checkNamingScreenPokemonSubject(pokemonSubject)
  if type(pokemonSubject) ~= "table" then
    reject("namingScreen.pokemonSubject must be a table", {})
  end
  checkSignedPoint(pokemonSubject.anchor, "namingScreen.pokemonSubject anchor must be a signed integer point")
  if ANIMATION_PLAY_MODES[pokemonSubject.playMode] ~= true then
    reject("namingScreen.pokemonSubject carries an unsupported play mode", {})
  end
  if type(pokemonSubject.frames) ~= "table" then
    reject("namingScreen.pokemonSubject must carry animation frames", {})
  end
  local pokemonFrameCount = demandDenseSequence(
    pokemonSubject.frames,
    "namingScreen.pokemonSubject frames must be a dense nonempty sequence",
    {}
  )
  checkInteger(
    pokemonSubject.loopStartFrameIdx,
    0,
    pokemonFrameCount - 1,
    "namingScreen.pokemonSubject loop start is outside its frames",
    {}
  )
  for index = 1, pokemonFrameCount do
    checkNamingScreenPokemonSubjectFrame(pokemonSubject.frames[index], index)
  end
end

local function checkNamingScreenGenderMarkers(genderMarkers, atlases)
  if type(genderMarkers) ~= "table" then
    reject("namingScreen.pokemonGenderMarkers must be a table", {})
  end
  checkSignedPoint(genderMarkers.anchor, "namingScreen.pokemonGenderMarkers anchor must be a signed integer point")
  for _, gender in ipairs({ "male", "female" }) do
    checkAnimationRecord(genderMarkers[gender], atlases, "namingScreen.pokemonGenderMarkers." .. gender, false)
  end
end

-- Below this point are the generic, source-independent validation
-- primitives: the most reusable and least specific to this file's own
-- domain, so they sit last, under every function that uses them.

local function checkNamingScreen(s, atlases)
  checkNamingScreenBaseAndPlacement(s, atlases)
  checkNamingScreenText(s.text)
  checkNamingScreenControls(s.controls, atlases)
  checkNamingScreenCursor(s.cursor, atlases)
  checkNamingScreenEntrySlots(s.entrySlots, atlases)
  checkNamingScreenPlayerSubjects(s.playerSubjects, atlases)
  checkNamingScreenPokemonSubject(s.pokemonSubject)
  checkNamingScreenGenderMarkers(s.pokemonGenderMarkers, atlases)
end

-- The two-row choice prompt: exactly the compact shape, one 48x32 button
-- per row with a normal and a selected visual each. Every visual resolves
-- through the shared asset index by semantic id; the section carries no
-- source archive, member, tile, palette, or background identities.

local M = {}
function M.validate(section, atlases, _, _)
  checkNamingScreen(section, atlases)
end
return M
