-- Published League ending bundle: the registration, showcase and credit-roll
-- sections one generated artifact owns, with the source background images the
-- roll draws. The schema is closed: every section, timing table and image
-- reference is validated before the bundle is admitted, and a bundle missing a
-- required part is never treated as ready.
--
-- Pure asset contract module: paths and validation only, no love dependency.

local Contract = require("libs.assets.src.DerivedAssetContract")
local AssetErrors = require("libs.assets.src.errors")
local Errors = require("libs.errors.src.Errors")

---@class EndingAssetCache
local EndingAssetCache = {}

local DIR = "data/generated/ending"
local INDEX = DIR .. "/index.lua"
local MARKER = DIR .. "/marker"

EndingAssetCache.DIR = DIR
EndingAssetCache.FORMAT = Contract.ending.format
EndingAssetCache.SCHEMA = Contract.ending.indexSchema

---@param message string
---@param context table<string, unknown>
local function fail(message, context)
  Errors.raise(AssetErrors.ENDING_ASSET_INVALID, message, context)
end

---@param value unknown
---@return boolean
local function isInteger(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value % 1 == 0
end

---@return string
function EndingAssetCache.indexPath()
  return INDEX
end

---@return string
function EndingAssetCache.markerPath()
  return MARKER
end

-- One rasterized source image inside the bundle's own asset root.
---@param sha1 string
---@return string
function EndingAssetCache.imagePath(sha1)
  assert(type(sha1) == "string" and sha1:match("^%x+$") ~= nil, "an ending image is addressed by its content digest")
  return DIR .. "/images/" .. sha1 .. ".png"
end

---@param romSha1 string
---@param depHash string
---@return string
function EndingAssetCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", Contract.ending.format, romSha1, depHash)
end

---@param value unknown
---@param what string
---@return table<string, unknown>
local function checkRecord(value, what)
  if type(value) ~= "table" then
    fail("the League ending bundle " .. what .. " must be a record", { field = what })
  end
  return value --[[@as table<string, unknown>]]
end

---@param value unknown
---@param what string
---@param min integer? the smallest accepted value, zero when absent
---@return integer
local function checkInteger(value, what, min)
  if not isInteger(value) or value < (min or 0) then
    fail("the League ending bundle " .. what .. " must be an integer", { field = what, value = value })
  end
  return value --[[@as integer]]
end

---@param value unknown
---@param what string
---@return table<string, unknown>
local function checkImage(value, what)
  local image = checkRecord(value, what)
  if type(image.path) ~= "string" or image.path == "" or type(image.sha1) ~= "string" or image.sha1 == "" then
    fail("the League ending bundle " .. what .. " must name its published image", { field = what })
  end
  if image.path ~= EndingAssetCache.imagePath(image.sha1) then
    fail("the League ending bundle " .. what .. " names its own content-addressed image", { field = what })
  end
  return image
end

-- One background scene: its transition frame and its two source layers.
---@param value unknown
---@param index integer
---@return table<string, unknown>
local function checkScene(value, index)
  local scene = checkRecord(value, "credit scene " .. index)
  if scene.index ~= index - 1 then
    fail("the League ending bundle orders its credit scenes by source scene", { index = index })
  end
  checkImage(scene.lower, "credit scene lower layer")
  checkImage(scene.upper, "credit scene upper layer")
  return scene
end

-- One realized animation frame: published pixels with its tick duration,
-- or a blank mark with its duration when the source shows nothing.
---@param frame unknown
---@param what string
local function checkFrame(frame, what)
  if type(frame) ~= "table" then
    fail("a realized animation frame is a record: " .. what, {})
  end
  checkInteger(frame.durationTicks, what .. " frame duration", 0)
  if frame.blank == true then
    return
  end
  local origin = frame.origin
  if type(origin) ~= "table" or type(origin.x) ~= "number" or type(origin.y) ~= "number" then
    fail("a realized animation frame carries its origin: " .. what, {})
  end
  if type(frame.path) ~= "string" or frame.path == "" then
    fail("a realized animation frame names its published image: " .. what, {})
  end
  checkInteger(frame.width, what .. " frame width", 1)
  checkInteger(frame.height, what .. " frame height", 1)
end

-- One realized animation sequence: its frames with the source play mode.
---@param sequence unknown
---@param what string
local function checkSequence(sequence, what)
  if type(sequence) ~= "table" then
    fail("a realized animation sequence is a record: " .. what, {})
  end
  if
    sequence.playMode ~= "forward"
    and sequence.playMode ~= "forward_loop"
    and sequence.playMode ~= "reverse"
    and sequence.playMode ~= "reverse_loop"
  then
    fail("a realized animation sequence names its play mode: " .. what, {})
  end
  local frames = sequence.frames
  if type(frames) ~= "table" or #frames == 0 then
    fail("a realized animation sequence carries its frames: " .. what, {})
  end
  for index, frame in ipairs(frames) do
    checkFrame(frame, what .. " frame " .. index)
  end
end

-- One roll page: its own start time, duration and printed lines.
---@param value unknown
---@param index integer
---@return table<string, unknown>
local function checkPage(value, index)
  local page = checkRecord(value, "credit page " .. index)
  if page.page ~= index - 1 then
    fail("the League ending bundle orders its credit pages by source page", { index = index })
  end
  checkInteger(page.startTime, "credit page start time", 0)
  checkInteger(page.duration, "credit page duration", 0)
  if type(page.lines) ~= "table" then
    fail("the League ending bundle credit page carries its lines", { index = index })
  end
  for lineIndex, line in ipairs(page.lines) do
    checkRecord(line, "credit line " .. index .. ":" .. lineIndex)
    checkInteger(line.x, "credit line x", 0)
    checkInteger(line.y, "credit line y", 0)
    checkInteger(line.message, "credit line message", 0)
  end
  return page
end

---@param section unknown
---@return table<string, unknown>
local function checkCredits(section)
  local credits = checkRecord(section, "credits section")
  checkInteger(credits.frames, "credit frames", 1)
  checkInteger(credits.musicBoxWaitFrames, "credit music-box wait", 1)
  checkInteger(credits.messageBank, "credit message bank", 1)
  local titles = checkRecord(credits.titleMessages, "credit title messages")
  checkInteger(titles.heartgold, "HeartGold title message", 0)
  checkInteger(titles.soulsilver, "SoulSilver title message", 0)
  if type(credits.sceneTransitionTimings) ~= "table" or #credits.sceneTransitionTimings < #credits.scenes - 1 then
    fail("the League ending bundle carries one scene transition per scene change", {})
  end
  for index, timing in ipairs(credits.sceneTransitionTimings) do
    if not isInteger(timing) or timing < 0 then
      fail("a credit scene transition timing is invalid", { index = index })
    end
  end
  -- The source display-swap timeline behind HandleSceneFlip rides with the
  -- transitions; a bundle without it cannot drive the display choreography.
  if type(credits.screenFlipTimings) ~= "table" or #credits.screenFlipTimings == 0 then
    fail("the League ending bundle carries its screen flip timings", {})
  end
  for index, timing in ipairs(credits.screenFlipTimings) do
    if not isInteger(timing) or timing < 0 then
      fail("a credit screen flip timing is invalid", { index = index })
    end
  end
  local sprites = credits.spriteResources
  if type(sprites) == "table" then
    checkInteger(sprites.charMember, "credit sprite char member", 0)
    checkInteger(sprites.paletteMember, "credit sprite palette member", 0)
    checkInteger(sprites.cellMember, "credit sprite cell member", 0)
    checkInteger(sprites.animMember, "credit sprite anim member", 0)
  end
  local cutsceneResources = credits.cutsceneResources
  if type(cutsceneResources) == "table" then
    checkInteger(cutsceneResources.charBaseMember, "credit cutscene char base member", 0)
    checkInteger(cutsceneResources.paletteMember, "credit cutscene palette member", 0)
    checkInteger(cutsceneResources.count, "credit cutscene count", 1)
  end
  if type(credits.scenes) ~= "table" or #credits.scenes == 0 then
    fail("the League ending bundle carries its credit scenes", {})
  end
  for index, scene in ipairs(credits.scenes) do
    checkScene(scene, index)
  end
  if type(credits.pages) ~= "table" or #credits.pages == 0 then
    fail("the League ending bundle carries its credit pages", {})
  end
  for index, page in ipairs(credits.pages) do
    checkPage(page, index)
  end
  checkImage(credits.theEnd, "The End screen")
  -- The dancing/cloud choreography: one realized sequence per source
  -- animation sequence (dancing) plus the cloud sequence.
  local dance = credits.danceSequences
  if type(dance) ~= "table" then
    fail("the roll carries its dancing sequences", {})
  end
  for seqNo = 0, 7 do
    checkSequence(dance[seqNo], "dance sequence " .. seqNo)
  end
  if type(credits.danceSeqsByScene) ~= "table" or #credits.danceSeqsByScene ~= 6 then
    fail("the roll carries one dancing sequence per scene", {})
  end
  checkInteger(credits.cloudSeq, "cloud sequence", 0)
  -- The sixteen cutscenes with their sprite params and per-sprite
  -- realized sequences (plus the female char/pal variants for the
  -- player and friend slots).
  local cutscenes = credits.cutscenes
  if type(cutscenes) ~= "table" or #cutscenes ~= 16 then
    fail("the roll carries its sixteen cutscenes", {})
  end
  for cutsceneIndex, cutscene in ipairs(cutscenes) do
    if type(cutscene) ~= "table" then
      fail("a cutscene is a record", { cutscene = cutsceneIndex })
    end
    checkInteger(cutscene.uniqueSprites, "cutscene unique sprite count", 1)
    checkInteger(cutscene.totalSprites, "cutscene total sprite count", 1)
    if type(cutscene.spriteIds) ~= "table" then
      fail("a cutscene carries its sprite ids", { cutscene = cutsceneIndex })
    end
    if type(cutscene.params) ~= "table" or #cutscene.params == 0 then
      fail("a cutscene carries its sprite params", { cutscene = cutsceneIndex })
    end
    for paramIndex, param in ipairs(cutscene.params) do
      if type(param) ~= "table" then
        fail("a cutscene sprite param is a record", { cutscene = cutsceneIndex, param = paramIndex })
      end
      checkInteger(param.spriteIdx, "cutscene sprite index", 0)
      checkInteger(param.animSeq, "cutscene animation sequence", 0)
      checkInteger(param.x, "cutscene sprite x", 0)
      checkInteger(param.y, "cutscene sprite y", 0)
      checkInteger(param.activateTime, "cutscene sprite cue", 0)
    end
  end
  local cutsceneSprites = credits.cutsceneSprites
  if type(cutsceneSprites) ~= "table" then
    fail("the roll carries its cutscene sprites", {})
  end
  for _, cutscene in ipairs(cutscenes) do
    for _, param in ipairs(cutscene.params) do
      local spriteId = cutscene.spriteIds[param.spriteIdx + 1]
      if type(spriteId) ~= "number" then
        fail("a cutscene param names its sprite", {})
      end
      local entry = cutsceneSprites[spriteId]
      if type(entry) ~= "table" then
        fail("a placed cutscene sprite is realized", { sprite = spriteId })
      end
      if type(entry.sequences) ~= "table" or type(entry.sequences[param.animSeq]) ~= "table" then
        fail("a placed cutscene sprite realizes its sequence", { sprite = spriteId, seq = param.animSeq })
      end
      checkSequence(entry.sequences[param.animSeq], "cutscene sprite " .. spriteId .. " seq " .. param.animSeq)
    end
  end
  return credits
end

---@param section unknown
---@return table<string, unknown>
local function checkRegistration(section)
  local registration = checkRecord(section, "registration section")
  checkInteger(registration.messageBank, "registration message bank", 1)
  local bgIndiv = registration.bgIndiv
  if type(bgIndiv) ~= "table" or #bgIndiv ~= 3 then
    fail("the registration individual scene carries its three background layers", {})
  end
  for index, layer in ipairs(bgIndiv) do
    checkImage(layer, "registration individual background layer " .. index)
  end
  local bgWhole = registration.bgWhole
  if type(bgWhole) ~= "table" or #bgWhole ~= 2 then
    fail("the registration whole-party scene carries its two background layers", {})
  end
  for index, layer in ipairs(bgWhole) do
    checkImage(layer, "registration whole-party background layer " .. index)
  end
  local function checkSequences(sequences, what, expected)
    if type(sequences) ~= "table" then
      fail("the registration carries its " .. what .. " sequences", {})
    end
    for _, seqNo in ipairs(expected) do
      checkSequence(sequences[seqNo], what .. " sequence " .. seqNo)
    end
  end
  checkSequences(registration.twinkle, "registration twinkle", { 0 })
  checkSequences(registration.twinkleShadow, "registration twinkle shadow", { 0 })
  checkSequences(registration.playerEthan, "registration male player", { 0 })
  checkSequences(registration.playerLyra, "registration female player", { 0 })
  checkSequences(registration.shadow, "registration shadow", { 0 })
  local tracks = registration.monTracks
  if type(tracks) ~= "table" or next(tracks) == nil then
    fail("the registration carries per-species picture tracks", {})
  end
  for speciesKey, track in pairs(tracks) do
    if type(track) ~= "table" then
      fail("a species picture track is a record", { species = speciesKey })
    end
    for _, facing in ipairs({ "front", "back" }) do
      local entry = track[facing]
      if type(entry) ~= "table" then
        fail("a species picture track carries its " .. facing .. " entry", { species = speciesKey })
      end
      checkInteger(entry.cryDelay, speciesKey .. " " .. facing .. " cry delay", 0)
      if type(entry.steps) ~= "table" or #entry.steps ~= 10 then
        fail("a species picture track carries its ten animation steps", { species = speciesKey, facing = facing })
      end
      for stepIndex, step in ipairs(entry.steps) do
        if type(step) ~= "table" or type(step.next) ~= "number" or type(step.duration) ~= "number" then
          fail("a picture animation step is a record", { species = speciesKey, step = stepIndex })
        end
      end
    end
    if type(track.heights) ~= "table" then
      fail("a species picture track carries its heights", { species = speciesKey })
    end
  end
  for _, key in ipairs({ "spotlightColors", "confettiColors" }) do
    local colors = registration[key]
    if type(colors) ~= "table" or #colors ~= 8 then
      fail("the registration carries its eight " .. key, {})
    end
    for index, color in ipairs(colors) do
      if type(color) ~= "table" or #color ~= 3 then
        fail("a registration effect color is an RGB triple", { key = key, index = index })
      end
    end
  end
  checkInteger(registration.flashFrames, "registration flash frames", 1)
  checkInteger(registration.reflashFrames, "registration reflash frames", 1)
  checkInteger(registration.fadeFrames, "registration fade frames", 1)
  if type(registration.flashSe) ~= "string" or registration.flashSe == "" then
    fail("the registration names its flash sound", {})
  end
  if type(registration.kanseiSe) ~= "string" or registration.kanseiSe == "" then
    fail("the registration names its kansei sound", {})
  end
  if type(registration.bgm) ~= "string" or registration.bgm == "" then
    fail("the registration names its music", {})
  end
  return registration
end

---@param section unknown
---@return table<string, unknown>
local function checkShowcase(section)
  local showcase = checkRecord(section, "showcase section")
  checkInteger(showcase.messageBank, "showcase message bank", 1)
  checkImage(showcase.mainBg, "showcase main background")
  checkImage(showcase.subBg, "showcase sub background")
  return showcase
end

---@param cacheFs table<string, unknown>
---@param expectedMarker string|nil
---@return boolean ready
function EndingAssetCache.isReady(cacheFs, expectedMarker)
  if expectedMarker ~= nil and cacheFs:read(MARKER) ~= expectedMarker then
    return false
  end
  local loaded, index = pcall(cacheFs.loadLua, cacheFs, INDEX)
  if not loaded or type(index) ~= "table" or index.schema ~= EndingAssetCache.SCHEMA then
    return false
  end
  local sections = index.sections
  if type(sections) ~= "table" then
    return false
  end
  for _, name in ipairs({ "registration", "showcase", "credits" }) do
    local path = sections[name]
    if type(path) ~= "string" or path ~= DIR .. "/" .. name .. ".lua" then
      return false
    end
    local sectionLoaded, section = pcall(cacheFs.loadLua, cacheFs, path)
    if not sectionLoaded or type(section) ~= "table" then
      return false
    end
    local valid = pcall(function()
      if name == "credits" then
        checkCredits(section)
      elseif name == "registration" then
        checkRegistration(section)
      else
        checkShowcase(section)
      end
    end)
    if not valid then
      return false
    end
  end
  -- Every published image every phase draws must be present in the bundle:
  -- walk each admitted section for published image records instead of
  -- naming the roll's layers, so registration and choreography art gate
  -- readiness exactly like credit backgrounds.
  local function requireSectionImages(section, seen)
    seen = seen or {}
    if type(section) ~= "table" or seen[section] then
      return
    end
    seen[section] = true
    if type(section.path) == "string" then
      if not cacheFs:exists(section.path) then
        fail("the League ending bundle is missing a published image", { path = section.path })
      end
      return
    end
    for _, value in pairs(section) do
      if type(value) == "table" then
        requireSectionImages(value, seen)
      end
    end
  end
  for _, name in ipairs({ "registration", "showcase", "credits" }) do
    requireSectionImages(assert(cacheFs:loadLua(sections[name])))
  end
  return true
end

-- The complete published bundle, for a composition that draws the ending.
---@param cacheFs table<string, unknown>
---@return table<string, unknown> bundle
function EndingAssetCache.load(cacheFs)
  local index, indexErr = cacheFs:loadLua(INDEX)
  if index == nil then
    Errors.raise(AssetErrors.ENDING_ASSET_INVALID, "the League ending bundle is unavailable", {
      path = INDEX,
      cause = tostring(indexErr),
    })
  end
  assert(index ~= nil, "the ending index is available after the missing-bundle error")
  if index.schema ~= EndingAssetCache.SCHEMA then
    fail("the League ending bundle schema is unsupported", { schema = index.schema })
  end
  local function section(name)
    local value, loadErr = cacheFs:loadLua(assert(index.sections[name], "the bundle carries " .. name))
    if value == nil then
      fail("the League ending bundle section failed to load", { section = name, cause = tostring(loadErr) })
    end
    return assert(value)
  end
  return {
    signature = assert(index.marker, "the bundle names its source signature"),
    registration = checkRegistration(section("registration")),
    showcase = checkShowcase(section("showcase")),
    credits = checkCredits(section("credits")),
  }
end

return EndingAssetCache
