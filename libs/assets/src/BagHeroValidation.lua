-- Validation for the generated Bag heroSection section.
local Checks = require("libs.assets.src.BagManifestChecks")
local Errors = require("libs.errors.src.Errors")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

local HeroValidation = {}

---@param heroData table<string, unknown>
---@param constantsForValidation { POCKETS: string[], POCKET_SET: table<string, boolean>, STATE_COUNT: integer, PANE_WIDTH: integer, PANE_HEIGHT: integer }
---@return true
function HeroValidation.validate(heroData, constantsForValidation)
  local validationContext = {}
  local function clipBySemantic(animations, semantic, schemaContext, what)
    local found = nil
    for _, clip in ipairs(animations) do
      if type(clip) == "table" and type(clip.semanticNames) == "table" then
        for _, name in ipairs(clip.semanticNames) do
          if name == semantic then
            if found ~= nil then
              Checks.reject(what .. " resolves to more than one clip", schemaContext)
            end
            found = clip
          end
        end
      end
    end
    if found == nil then
      Checks.reject(what .. " resolves to no clip", schemaContext)
    end
  end

  local function clipById(animations, id, schemaContext, what)
    for _, clip in ipairs(animations) do
      if type(clip) == "table" and clip.id == id then
        return
      end
    end
    Checks.reject(what .. " resolves to no clip", schemaContext)
  end

  local function checkModel(descriptor, schemaContext, what)
    local ok, err = pcall(ModelAsset.validate, descriptor)
    if not ok then
      if Errors.is(err) then
        Checks.reject(what .. " is invalid: " .. Errors.format(err), schemaContext)
      end
      error(err, 0)
    end
  end

  local function checkAnimations(animations, model, schemaContext, schemaConstants)
    Checks.checkRecord(animations, { states = true, material = true }, schemaContext, "animations")
    Checks.checkFixedArray(
      animations.states,
      schemaConstants.STATE_COUNT,
      schemaContext,
      "animations.states must carry exactly eight pocket states"
    )
    local seen = {}
    for index, state in ipairs(animations.states) do
      local what = "animations.states[" .. index .. "]"
      Checks.checkRecord(state, { pocket = true, pose = true, pattern = true }, schemaContext, what)
      if type(state.pocket) ~= "string" or state.pocket == "" then
        Checks.reject(what .. ".pocket must be a non-empty key", schemaContext)
      end
      if seen[state.pocket] then
        Checks.reject("animations.states repeats pocket " .. state.pocket, schemaContext)
      end
      seen[state.pocket] = true
      if type(state.pose) ~= "string" or state.pose == "" then
        Checks.reject(what .. ".pose must be a non-empty clip name", schemaContext)
      end
      if type(state.pattern) ~= "string" or state.pattern == "" then
        Checks.reject(what .. ".pattern must be a non-empty clip name", schemaContext)
      end
      for _, gender in ipairs({ "male", "female" }) do
        local animationsList = model[gender].animations
        clipBySemantic(animationsList, state.pose, schemaContext, what .. ".pose for " .. gender)
        clipBySemantic(animationsList, state.pattern, schemaContext, what .. ".pattern for " .. gender)
      end
    end
    for _, pocket in ipairs(schemaConstants.POCKETS) do
      if not seen[pocket] then
        Checks.reject("animations.states is missing pocket " .. pocket, schemaContext)
      end
    end
    local material = animations.material
    Checks.checkRecord(material, { male = true, female = true }, schemaContext, "animations.material")
    for _, gender in ipairs({ "male", "female" }) do
      if type(material[gender]) ~= "string" or material[gender] == "" then
        Checks.reject("animations.material." .. gender .. " must be a non-empty clip id", schemaContext)
      end
      clipById(model[gender].animations, material[gender], schemaContext, "animations.material." .. gender)
    end
  end

  local function checkCamera(camera, schemaContext)
    Checks.checkRecord(camera, {
      target = true,
      distance = true,
      angleXDegrees = true,
      angleYDegrees = true,
      perspectiveType = true,
      perspectiveAngle = true,
      clipNear = true,
      clipFar = true,
    }, schemaContext, "presentation.camera")
    local target = camera.target
    Checks.checkRecord(target, { x = true, y = true, z = true }, schemaContext, "presentation.camera.target")
    Checks.checkFinite(target.x, schemaContext, "presentation.camera.target.x")
    Checks.checkFinite(target.y, schemaContext, "presentation.camera.target.y")
    Checks.checkFinite(target.z, schemaContext, "presentation.camera.target.z")
    Checks.checkFinite(camera.distance, schemaContext, "presentation.camera.distance")
    if camera.distance <= 0 then
      Checks.reject("presentation.camera.distance must be positive", schemaContext)
    end
    Checks.checkFinite(camera.angleXDegrees, schemaContext, "presentation.camera.angleXDegrees")
    Checks.checkFinite(camera.angleYDegrees, schemaContext, "presentation.camera.angleYDegrees")
    Checks.checkInteger(
      camera.perspectiveType,
      schemaContext,
      "presentation.camera.perspectiveType",
      0,
      nil,
      "a non-negative integer"
    )
    Checks.checkInteger(
      camera.perspectiveAngle,
      schemaContext,
      "presentation.camera.perspectiveAngle",
      0,
      nil,
      "a non-negative integer"
    )
    Checks.checkFinite(camera.clipNear, schemaContext, "presentation.camera.clipNear")
    Checks.checkFinite(camera.clipFar, schemaContext, "presentation.camera.clipFar")
    if camera.clipNear <= 0 or camera.clipFar <= camera.clipNear then
      Checks.reject("presentation.camera clipping range is invalid", schemaContext)
    end
  end

  local function checkTransform(transform, schemaContext)
    Checks.checkRecord(
      transform,
      { translation = true, rotation = true, scale = true },
      schemaContext,
      "presentation.transform"
    )
    for _, block in ipairs({ "translation", "scale" }) do
      if type(transform[block]) ~= "table" then
        Checks.reject("presentation.transform." .. block .. " must be a record", schemaContext)
      end
    end
    for _, axis in ipairs({ "x", "y", "z" }) do
      Checks.checkFinite(transform.translation[axis], schemaContext, "presentation.transform.translation." .. axis)
      Checks.checkFinite(transform.scale[axis], schemaContext, "presentation.transform.scale." .. axis)
    end
    Checks.checkFixedArray(
      transform.rotation,
      9,
      schemaContext,
      "presentation.transform.rotation must carry nine matrix entries"
    )
    for _, entry in ipairs(transform.rotation) do
      Checks.checkFinite(entry, schemaContext, "presentation.transform.rotation entry")
    end
  end

  local function checkLightVector(vector, schemaContext, what)
    Checks.checkRecord(vector, { x = true, y = true, z = true }, schemaContext, what)
    Checks.checkFinite(vector.x, schemaContext, what .. ".x")
    Checks.checkFinite(vector.y, schemaContext, what .. ".y")
    Checks.checkFinite(vector.z, schemaContext, what .. ".z")
  end

  local function checkLights(lights, schemaContext)
    Checks.checkRecord(
      lights,
      { count = true, color = true, vectors = true },
      schemaContext,
      "hero.presentation.lights"
    )
    if lights.count ~= 4 then
      Checks.reject("hero.presentation.lights.count must be exactly four", schemaContext)
    end
    if type(lights.color) ~= "table" then
      Checks.reject("hero.presentation.lights.color must be a record", schemaContext)
    end
    for _, channel in ipairs({ "r", "g", "b" }) do
      Checks.checkInteger(
        lights.color[channel],
        schemaContext,
        "hero.presentation.lights.color." .. channel,
        0,
        31,
        "0..31"
      )
    end
    Checks.checkFixedArray(
      lights.vectors,
      4,
      schemaContext,
      "hero.presentation.lights.vectors must carry exactly four light vectors"
    )
    for index, vector in ipairs(lights.vectors) do
      checkLightVector(vector, schemaContext, "hero.presentation.lights.vectors[" .. index .. "]")
    end
  end

  local function checkMaterialRegister(register, schemaContext, what)
    Checks.checkRecord(register, { r = true, g = true, b = true }, schemaContext, what)
    for _, channel in ipairs({ "r", "g", "b" }) do
      Checks.checkInteger(register[channel], schemaContext, what .. "." .. channel, 0, 31, "0..31")
    end
  end

  local function checkMaterials(materials, schemaContext)
    Checks.checkRecord(materials, {
      diffuse = true,
      ambient = true,
      specular = true,
      emission = true,
    }, schemaContext, "hero.presentation.materials")
    for _, register in ipairs({ "diffuse", "ambient", "specular", "emission" }) do
      checkMaterialRegister(materials[register], schemaContext, "hero.presentation.materials." .. register)
    end
  end

  -- The retail heroSection edge-color table: exactly eight semantic 5-bit channel
  -- records feeding the shared DS edge-marking renderer. Trailing black
  -- entries are valid source data, not missing data.
  local function checkEdgeColors(edgeColors, schemaContext)
    Checks.checkFixedArray(
      edgeColors,
      8,
      schemaContext,
      "hero.presentation.edgeColors must carry exactly eight edge-color records"
    )
    for index, record in ipairs(edgeColors) do
      checkMaterialRegister(record, schemaContext, "hero.presentation.edgeColors[" .. index .. "]")
    end
  end

  local function checkFramingRecord(record, schemaContext, what)
    Checks.checkRecord(
      record,
      { angleXDegrees = true, angleYDegrees = true, distance = true, modelY = true },
      schemaContext,
      what
    )
    Checks.checkFinite(record.angleXDegrees, schemaContext, what .. ".angleXDegrees")
    Checks.checkFinite(record.angleYDegrees, schemaContext, what .. ".angleYDegrees")
    Checks.checkFinite(record.distance, schemaContext, what .. ".distance")
    Checks.checkFinite(record.modelY, schemaContext, what .. ".modelY")
  end

  -- Pocket-aware heroSection framing: the transition duration as plain pacing data,
  -- one neutral baseline record per gender, and one record per canonical
  -- pocket per gender. Transition progress stays runtime-owned; only these
  -- immutable facts reach the manifest.
  local function checkFraming(framing, schemaContext, schemaConstants)
    Checks.checkRecord(
      framing,
      { transitionTicks = true, baseline = true, byGender = true },
      schemaContext,
      "hero.presentation.framing"
    )
    Checks.checkInteger(
      framing.transitionTicks,
      schemaContext,
      "hero.presentation.framing.transitionTicks",
      1,
      nil,
      "a positive integer"
    )
    local baseline = framing.baseline
    Checks.checkRecord(baseline, { male = true, female = true }, schemaContext, "hero.presentation.framing.baseline")
    local byGender = framing.byGender
    Checks.checkRecord(byGender, { male = true, female = true }, schemaContext, "hero.presentation.framing.byGender")
    for _, gender in ipairs({ "male", "female" }) do
      checkFramingRecord(baseline[gender], schemaContext, "hero.presentation.framing.baseline." .. gender)
      local pockets = byGender[gender]
      Checks.checkRecord(
        pockets,
        schemaConstants.POCKET_SET,
        schemaContext,
        "hero.presentation.framing.byGender." .. gender,
        "a pocket record"
      )
      for _, pocket in ipairs(schemaConstants.POCKETS) do
        checkFramingRecord(
          pockets[pocket],
          schemaContext,
          "hero.presentation.framing.byGender." .. gender .. "." .. pocket
        )
      end
    end
  end

  local function checkHero(heroSection, schemaContext, schemaConstants)
    Checks.checkRecord(heroSection, {
      background = true,
      description = true,
      moveSummary = true,
      model = true,
      animations = true,
      presentation = true,
    }, schemaContext, "hero")
    local background = heroSection.background
    Checks.checkRecord(background, { male = true, female = true }, schemaContext, "hero.background")
    Checks.checkImage(background.male, schemaContext, "hero.background.male")
    Checks.checkImage(background.female, schemaContext, "hero.background.female")
    local description = heroSection.description
    Checks.checkRecord(description, { frame = true, textRect = true }, schemaContext, "hero.description")
    if type(description.frame) ~= "table" then
      Checks.reject("hero.description.frame must be a record", schemaContext)
    end
    Checks.checkKeys(description.frame, { image = true, rect = true }, schemaContext, "hero.description.frame")
    if type(description.frame.image) ~= "string" or description.frame.image == "" then
      Checks.reject("hero.description.frame.image must be a non-empty path", schemaContext)
    end
    Checks.checkRect(
      description.frame.rect,
      schemaContext,
      "hero.description.frame.rect",
      schemaConstants.PANE_WIDTH,
      schemaConstants.PANE_HEIGHT
    )
    Checks.checkRect(
      description.textRect,
      schemaContext,
      "hero.description.textRect",
      schemaConstants.PANE_WIDTH,
      schemaConstants.PANE_HEIGHT
    )
    local summary = heroSection.moveSummary
    Checks.checkRecord(summary, {
      background = true,
      labels = true,
      text = true,
      typeCenter = true,
      categoryCenter = true,
    }, schemaContext, "hero.moveSummary")
    Checks.checkImage(summary.background, schemaContext, "hero.moveSummary.background")
    local labels = summary.labels
    Checks.checkRecord(labels, {
      type = true,
      pp = true,
      category = true,
      power = true,
      accuracy = true,
      unavailable = true,
    }, schemaContext, "hero.moveSummary.labels")
    for _, key in ipairs({ "type", "pp", "category", "power", "accuracy", "unavailable" }) do
      if type(labels[key]) ~= "string" or labels[key] == "" then
        Checks.reject("hero.moveSummary.labels." .. key .. " must be text", schemaContext)
      end
    end
    local text = summary.text
    Checks.checkRecord(text, {
      type = true,
      pp = true,
      category = true,
      power = true,
      accuracy = true,
      ppValue = true,
      powerValue = true,
      accuracyValue = true,
    }, schemaContext, "hero.moveSummary.text")
    for _, key in ipairs({ "type", "pp", "category", "power", "accuracy", "ppValue", "powerValue", "accuracyValue" }) do
      Checks.checkPoint(
        text[key],
        schemaContext,
        "hero.moveSummary.text." .. key,
        schemaConstants.PANE_WIDTH,
        schemaConstants.PANE_HEIGHT
      )
    end
    Checks.checkPoint(
      summary.typeCenter,
      schemaContext,
      "hero.moveSummary.typeCenter",
      schemaConstants.PANE_WIDTH,
      schemaConstants.PANE_HEIGHT
    )
    Checks.checkPoint(
      summary.categoryCenter,
      schemaContext,
      "hero.moveSummary.categoryCenter",
      schemaConstants.PANE_WIDTH,
      schemaConstants.PANE_HEIGHT
    )
    local model = heroSection.model
    Checks.checkRecord(model, { male = true, female = true }, schemaContext, "hero.model")
    checkModel(model.male, schemaContext, "hero.model.male")
    checkModel(model.female, schemaContext, "hero.model.female")
    checkAnimations(heroSection.animations, model, schemaContext, schemaConstants)
    local presentation = heroSection.presentation
    Checks.checkRecord(presentation, {
      camera = true,
      transform = true,
      lights = true,
      materials = true,
      framing = true,
      edgeColors = true,
    }, schemaContext, "hero.presentation")
    checkCamera(presentation.camera, schemaContext)
    checkTransform(presentation.transform, schemaContext)
    checkLights(presentation.lights, schemaContext)
    checkMaterials(presentation.materials, schemaContext)
    checkFraming(presentation.framing, schemaContext, schemaConstants)
    checkEdgeColors(presentation.edgeColors, schemaContext)
  end

  checkHero(heroData, validationContext, constantsForValidation)
  return true
end

return HeroValidation
