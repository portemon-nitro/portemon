-- Runtime-facing validation for the battle presentation family: the
-- staged global manifest, one composed scene record, and exact launch
-- demands. Fixtures are synthetic; the ROM suite proves the staged
-- compiler output satisfies the same contract.

local Assert = require("tests.support.Assert")
local Schema = require("libs.assets.src.battle.BattlePresentationSchema")

local T = {}

local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local manifest = ManifestFixture.manifest
local makeIntroMusic = ManifestFixture.makeIntroMusic
local scriptMessageProgramContext = ManifestFixture.scriptMessageProgramContext

function T.transition_routes_require_semantic_context_and_staged_resources()
  local missingResource = manifest()
  missingResource.transitions.routes["trainer/red"].assetGroups.sprite.palette = "missing"
  Assert.isFalse(Schema.isValidManifest(missingResource), "transition asset groups must reference staged resources")

  local nativeInput = manifest()
  nativeInput.transitions.routes["trainer/red"].sourceSelector = 46
  Assert.isFalse(Schema.isValidManifest(nativeInput), "transition routes must not expose native selector indexes")
end

function T.animation_frames_require_integer_translation()
  local valid = manifest()
  local validResult, validError = Schema.isValidManifest(valid)
  Assert.isTrue(
    validResult,
    "the manifest carries explicit zero translation where frames are static: " .. tostring(validError)
  )

  local missing = manifest()
  missing.hud.cursor.animations[1].frames[1].x = nil
  Assert.isFalse(Schema.isValidManifest(missing), "animation translation is required even when it is zero")

  local fractional = manifest()
  fractional.hud.cursor.animations[1].frames[1].y = 0.5
  Assert.isFalse(Schema.isValidManifest(fractional), "animation translation must be integer pixels")
end

function T.wild_fallback_routes_require_the_staged_cell_grid_order_contract()
  local valid = manifest()
  local key = "transition/data/wild-cell-grid-orders/test"
  valid.resources[key] = {
    kind = "transition-data",
    contentIdentity = string.rep("a", 40),
    format = "hgss-wild-cell-grid-orders-v1",
    geometry = { gridWidth = 8, gridHeight = 6, orderCount = 24 },
    path = "data/generated/battle/resources/wild-cell-grid-orders.lua",
  }
  local route = valid.transitions.routes["trainer/red"]
  route.role = "plain-wild-fallback"
  route.resources[#route.resources + 1] = key
  route.assetGroups.wildCellOrders = key
  local admission = valid.coverage["transition/trainer/red"]
  admission.resources[#admission.resources + 1] = key
  admission.operations[1] = "plain-wild-fallback"
  local routeValid, routeError = Schema.isValidManifest(valid)
  Assert.isTrue(
    routeValid,
    "plain wild routes load strict producer-staged retail cell orders: " .. tostring(routeError)
  )

  local missing = manifest()
  missing.transitions.routes["trainer/red"].role = "plain-wild-fallback"
  Assert.isFalse(Schema.isValidManifest(missing), "wild routes cannot omit source cell grid orders")

  local malformed = manifest()
  malformed.resources[key] = {
    kind = "transition-data",
    contentIdentity = string.rep("a", 40),
    format = "hgss-wild-cell-grid-orders-v1",
    geometry = { gridWidth = 8, gridHeight = 5, orderCount = 24 },
    path = "data/generated/battle/resources/wild-cell-grid-orders.lua",
  }
  Assert.isFalse(
    Schema.isValidManifest(malformed),
    "wild cell order geometry rejects mismatched retail grid dimensions"
  )
end

function T.trainer_pictures_validate_semantic_role_selectors_and_staged_images()
  local valid = manifest()
  Assert.isTrue(Schema.isValidManifest(valid), "semantic front and back trainer images validate")

  valid.trainerPictures.entries["front:YOUNGSTER"].drawableKey = "trainer:front:POKEBALL"
  Assert.isFalse(Schema.isValidManifest(valid), "a trainer selector cannot point at another drawable identity")

  local missingOffset = manifest()
  missingOffset.trainerPictures.entries["front:YOUNGSTER"].rasterOffset = nil
  Assert.isFalse(Schema.isValidManifest(missingOffset), "trainer pictures require their source raster offset")

  local missingAnimation = manifest()
  missingAnimation.trainerPictures.entries["front:YOUNGSTER"].animation = nil
  Assert.isFalse(Schema.isValidManifest(missingAnimation), "every trainer picture retains its source frame sequence")
  local fractionalOffset = manifest()
  fractionalOffset.trainerPictures.entries["front:YOUNGSTER"].rasterOffset.x = -40.5
  Assert.isFalse(Schema.isValidManifest(fractionalOffset), "trainer raster offsets are integer source coordinates")
end

function T.trainer_picture_sequences_validate_ordered_staged_source_frames()
  local image0 = "assets/generated/battle/trainer-back-PKMN_TRAINER_ETHAN.png"
  local image1 = "assets/generated/battle/trainer-back-PKMN_TRAINER_ETHAN-frame-1.png"
  local sequenceImage = "assets/generated/battle/trainer-back-PKMN_TRAINER_ETHAN-sequence-1-frame-0.png"
  local function entryFixture()
    local frames = {
      {
        drawableKey = "trainer:back:PKMN_TRAINER_ETHAN",
        image = image0,
        rasterOffset = { x = -40, y = -40 },
        durationTicks = 2,
        sourceFrame = 0,
        userAttr = 0,
      },
      {
        drawableKey = "trainer:back:PKMN_TRAINER_ETHAN:frame:1",
        image = image1,
        rasterOffset = { x = -24, y = -40 },
        durationTicks = 5,
        sourceFrame = 1,
        userAttr = 1,
      },
    }
    return {
      drawableKey = "trainer:back:PKMN_TRAINER_ETHAN",
      image = image0,
      width = 8,
      height = 8,
      rasterOffset = { x = -40, y = -40 },
      animation = {
        sourceSequence = 0,
        playMode = "forward_loop",
        loopStartFrameIdx = 0,
        frames = frames,
        sequences = {
          { sourceSequence = 0, playMode = "forward_loop", loopStartFrameIdx = 0, frames = frames },
          {
            sourceSequence = 1,
            playMode = "forward",
            loopStartFrameIdx = 0,
            frames = {
              {
                drawableKey = "trainer:back:PKMN_TRAINER_ETHAN:sequence:1:frame:0",
                image = sequenceImage,
                rasterOffset = { x = -40, y = -40 },
                durationTicks = 3,
                sourceFrame = 0,
                userAttr = 0xFFF,
              },
            },
          },
        },
      },
      throwOffsets = {
        { x = 0, y = 128 },
        { x = -34, y = 4 },
        { x = -28, y = -11 },
        { x = 50, y = -12 },
        { x = 32767, y = 32767 },
        { x = 32767, y = 32767 },
      },
    }
  end
  local valid = manifest()
  local entry = entryFixture()
  valid.trainerPictures.entries["back:PKMN_TRAINER_ETHAN"] = entry
  valid.menus.images[image0] = { width = 8, height = 8 }
  valid.menus.images[image1] = { width = 8, height = 8 }
  valid.menus.images[sequenceImage] = { width = 8, height = 8 }
  local validResult, validError = Schema.isValidManifest(valid)
  Assert.isTrue(
    validResult,
    "two source-order trainer frames and their image closure validate: " .. tostring(validError)
  )

  local missingImage = manifest()
  local missingEntry = entryFixture()
  missingEntry.animation.frames[2].image = "assets/generated/battle/missing-trainer-frame.png"
  missingImage.trainerPictures.entries["back:PKMN_TRAINER_ETHAN"] = missingEntry
  missingImage.menus.images[image0] = { width = 8, height = 8 }
  Assert.isFalse(Schema.isValidManifest(missingImage), "every source frame image must be staged")

  local duplicateFrame = manifest()
  local duplicateEntry = entryFixture()
  duplicateEntry.animation.frames[2].sourceFrame = 0
  duplicateFrame.trainerPictures.entries["back:PKMN_TRAINER_ETHAN"] = duplicateEntry
  duplicateFrame.menus.images[image0] = { width = 8, height = 8 }
  duplicateFrame.menus.images[image1] = { width = 8, height = 8 }
  Assert.isFalse(Schema.isValidManifest(duplicateFrame), "source frame indices are unique and ordered")

  local invalidDuration = manifest()
  local invalidEntry = entryFixture()
  invalidEntry.animation.frames[2].durationTicks = 0.5
  invalidDuration.trainerPictures.entries["back:PKMN_TRAINER_ETHAN"] = invalidEntry
  invalidDuration.menus.images[image0] = { width = 8, height = 8 }
  invalidDuration.menus.images[image1] = { width = 8, height = 8 }
  Assert.isFalse(Schema.isValidManifest(invalidDuration), "source frame durations are integer ticks")

  local invalidUserAttr = manifest()
  local invalidAttrEntry = entryFixture()
  invalidAttrEntry.animation.sequences[2].frames[1].userAttr = -1
  invalidUserAttr.trainerPictures.entries["back:PKMN_TRAINER_ETHAN"] = invalidAttrEntry
  invalidUserAttr.menus.images[image0] = { width = 8, height = 8 }
  invalidUserAttr.menus.images[image1] = { width = 8, height = 8 }
  invalidUserAttr.menus.images[sequenceImage] = { width = 8, height = 8 }
  Assert.isFalse(Schema.isValidManifest(invalidUserAttr), "UAAT values are unsigned source integers")

  local oversizedUserAttr = manifest()
  local oversizedAttrEntry = entryFixture()
  oversizedAttrEntry.animation.sequences[2].frames[1].userAttr = 0x100000000
  oversizedUserAttr.trainerPictures.entries["back:PKMN_TRAINER_ETHAN"] = oversizedAttrEntry
  oversizedUserAttr.menus.images[image0] = { width = 8, height = 8 }
  oversizedUserAttr.menus.images[image1] = { width = 8, height = 8 }
  oversizedUserAttr.menus.images[sequenceImage] = { width = 8, height = 8 }
  Assert.isFalse(Schema.isValidManifest(oversizedUserAttr), "UAAT values fit their source u32 representation")

  local missingSequenceImage = manifest()
  local missingSequenceEntry = entryFixture()
  missingSequenceEntry.animation.sequences[2].frames[1].image =
    "assets/generated/battle/missing-trainer-sequence-frame.png"
  missingSequenceImage.trainerPictures.entries["back:PKMN_TRAINER_ETHAN"] = missingSequenceEntry
  missingSequenceImage.menus.images[image0] = { width = 8, height = 8 }
  missingSequenceImage.menus.images[image1] = { width = 8, height = 8 }
  Assert.isFalse(Schema.isValidManifest(missingSequenceImage), "every selected source sequence frame must be staged")

  local skippedSequence = manifest()
  local skippedSequenceEntry = entryFixture()
  skippedSequenceEntry.animation.sequences[2].sourceSequence = 2
  skippedSequence.trainerPictures.entries["back:PKMN_TRAINER_ETHAN"] = skippedSequenceEntry
  skippedSequence.menus.images[image0] = { width = 8, height = 8 }
  skippedSequence.menus.images[image1] = { width = 8, height = 8 }
  skippedSequence.menus.images[sequenceImage] = { width = 8, height = 8 }
  Assert.isFalse(Schema.isValidManifest(skippedSequence), "source sequence IDs remain ordered and explicit")

  local missingThrowAnchor = manifest()
  local missingAnchorEntry = entryFixture()
  missingAnchorEntry.throwOffsets = nil
  missingThrowAnchor.trainerPictures.entries["back:PKMN_TRAINER_ETHAN"] = missingAnchorEntry
  missingThrowAnchor.menus.images[image0] = { width = 8, height = 8 }
  missingThrowAnchor.menus.images[image1] = { width = 8, height = 8 }
  Assert.isFalse(Schema.isValidManifest(missingThrowAnchor), "animated backpics require source throw attachments")
end

function T.battle_ball_frames_validate_ordered_semantic_drawables_and_staged_images()
  local valid = manifest()
  Assert.isTrue(Schema.isValidManifest(valid), "the source-shaped ball frame manifest validates")
  local missingImage = manifest()
  missingImage.battleBalls.entries["ball:POKE_BALL"].frames[1].image = "assets/generated/battle/missing.png"
  Assert.isFalse(Schema.isValidManifest(missingImage), "ball frames must reference staged images")
  local wrongFrame = manifest()
  wrongFrame.battleBalls.entries["ball:POKE_BALL"].frames[1].drawableKey = "battle-ball:POKE_BALL:1"
  Assert.isFalse(Schema.isValidManifest(wrongFrame), "ball frame drawables follow the zero-based source order")
end

function T.transition_routes_accept_strict_normalized_camera_task_data()
  local valid = manifest()
  local poses = {}
  for index = 1, 16 do
    poses[index] = {
      distanceFx32 = 2731713,
      angleXRaw = 54786,
      angleYRaw = 0,
      perspectiveRaw = 1473,
      waitTicks = 4,
    }
  end
  valid.transitions.routes["trainer/red"].task = {
    kind = "field-camera-pose-sequence",
    parameters = {
      poses = poses,
      fadeTicks = 10,
      graphicsMode = { mode = 3, bank = 15 },
    },
  }
  Assert.isTrue(Schema.isValidManifest(valid), "a source-normalized task and its typed parameters are valid")

  local missingPose = manifest()
  missingPose.transitions.routes["trainer/red"].task = {
    kind = "field-camera-pose-sequence",
    parameters = { poses = {}, fadeTicks = 10, graphicsMode = { mode = 3, bank = 15 } },
  }
  Assert.isFalse(Schema.isValidManifest(missingPose), "camera task schema requires the complete source pose sequence")

  local nativeId = manifest()
  nativeId.transitions.routes["trainer/red"].task = {
    kind = "field-camera-pose-sequence",
    callback = 34,
    parameters = {
      poses = poses,
      fadeTicks = 10,
      graphicsMode = { mode = 3, bank = 15 },
    },
  }
  Assert.isFalse(
    Schema.isValidManifest(nativeId),
    "normalized transition tasks do not publish native callback ordinals"
  )
end

function T.overlay115_task_parameters_are_source_normalized_and_strict()
  local gym = manifest()
  gym.transitions.routes["trainer/red"].task = {
    kind = "overlay115-gym-rival-intro",
    parameters = { endXFx32 = 214 * 4096 },
  }
  local gymValid, gymError = Schema.isValidManifest(gym)
  Assert.isTrue(gymValid, "gym route keeps its source FX32 endpoint: " .. tostring(gymError))

  local elite = manifest()
  elite.transitions.routes["trainer/red"].task = {
    kind = "overlay115-elite-intro",
    parameters = { shakeTicks = 9 },
  }
  Assert.isTrue(Schema.isValidManifest(elite), "elite route keeps its source shake duration")

  local pixels = manifest()
  pixels.transitions.routes["trainer/red"].task = {
    kind = "overlay115-gym-rival-intro",
    parameters = { endXFx32 = 214 },
  }
  Assert.isFalse(Schema.isValidManifest(pixels), "FX32 endpoints are not silently interpreted as pixels")
end

function T.transition_trainer_name_routes_bind_a_semantic_trainer_context()
  local valid = manifest()
  local route = valid.transitions.routes["trainer/red"]
  route.trainer = { key = "will" }
  route.requiredContext = { "battleType", "transitionTrainer" }
  Assert.isTrue(Schema.isValidManifest(valid), "a transition route may bind a source-selected semantic trainer")

  local missingContext = manifest()
  missingContext.transitions.routes["trainer/red"].trainer = { key = "will" }
  Assert.isFalse(
    Schema.isValidManifest(missingContext),
    "a trainer identity requires its typed transitionTrainer context"
  )

  local sourceId = manifest()
  sourceId.transitions.routes["trainer/red"].trainer = { key = "will", trainerId = 0xf5 }
  sourceId.transitions.routes["trainer/red"].requiredContext = { "battleType", "transitionTrainer" }
  Assert.isFalse(Schema.isValidManifest(sourceId), "a native trainer ID cannot enter a transition route")
end

function T.rival_transition_keeps_its_source_name_context_and_route()
  local rival = manifest()
  rival.messages.routes["transition/rival-name"] = {
    template = "transition/trainer-name",
    inputs = { "rivalName" },
  }
  rival.transitions.routes["trainer/red"].requiredContext = { "battleType", "rivalName" }
  rival.transitions.routes["trainer/red"].messages = { "transition/rival-name" }
  Assert.isTrue(
    Schema.isValidManifest(rival),
    "the selector-specific rival-name route keeps its typed source context and normalized message route"
  )
end

function T.red_transition_does_not_require_a_source_absent_name_route()
  local red = manifest()
  local route = red.transitions.routes["trainer/red"]
  route.trainer = { key = "red" }
  route.requiredContext = { "battleType", "transitionTrainer" }
  route.messages = nil
  Assert.isTrue(
    Schema.isValidManifest(red),
    "a typed transition trainer can select the source-authored Red route without a name message"
  )
end

function T.coverage_closes_each_transition_route_with_semantic_resources()
  local missing = manifest()
  missing.coverage["transition/trainer/red"] = nil
  Assert.isFalse(Schema.isValidManifest(missing), "every transition route requires an admission closure")

  local unstaged = manifest()
  unstaged.coverage["transition/trainer/red"].resources[1] = "transition/missing"
  Assert.isFalse(Schema.isValidManifest(unstaged), "transition admission cannot reference an unstaged resource")

  local incomplete = manifest()
  incomplete.coverage["transition/trainer/red"].closureIdentity = "not-a-content-identity"
  Assert.isFalse(Schema.isValidManifest(incomplete), "transition admission requires a closure identity")

  local genericOperation = manifest()
  genericOperation.coverage["transition/trainer/red"].operations = { "transition-route" }
  Assert.isFalse(
    Schema.isValidManifest(genericOperation),
    "transition coverage identifies the source callback's semantic operation"
  )
end

function T.coverage_requires_semantic_menu_message_roots()
  local missingMenu = manifest()
  missingMenu.coverage.command = nil
  Assert.isFalse(Schema.isValidManifest(missingMenu), "every menu route requires an admission closure")

  local missingMessage = manifest()
  missingMessage.coverage["battle/script-message"] = nil
  Assert.isFalse(Schema.isValidManifest(missingMessage), "every semantic message route requires an admission closure")
end

function T.dynamic_menu_asset_roles_require_a_semantic_catalog_binding()
  local missingBinding = manifest()
  missingBinding.menus.routes.command.assetRoles = { "pokemonIcon" }
  missingBinding.coverage.command.assetRoles = { "pokemonIcon" }
  missingBinding.coverage.command.assetBindings = {}
  Assert.isFalse(
    Schema.isValidManifest(missingBinding),
    "a dynamic icon role must identify its semantic selector catalog and context inputs"
  )
end

function T.message_catalog_routes_reference_staged_semantic_banks()
  local incomplete = manifest()
  incomplete.messages.banks.scriptController = 197
  Assert.isFalse(Schema.isValidManifest(incomplete), "message bank role must not expose a native member ID")

  local missingResource = manifest()
  missingResource.messages.banks.scriptController = "message-bank/missing"
  Assert.isFalse(Schema.isValidManifest(missingResource), "message bank roles must reference staged message resources")

  local badRange = manifest()
  badRange.messages.dynamicRoutes.captureShake.maximum = 5
  Assert.isFalse(
    Schema.isValidManifest(badRange),
    "capture shake route must stay within its source-derived record range"
  )
end

function T.message_source_routes_reject_unstaged_and_native_references()
  local missingBank = manifest()
  missingBank.messages.sourceRoutes["battle/script-message"].banks[1] = "message-bank/missing"
  Assert.isFalse(Schema.isValidManifest(missingBank), "source routes must reference staged semantic banks")

  local missingIndex = manifest()
  missingIndex.messages.sourceRoutes["battle/trainer-pair-speech"].resources[1] = "trainer-index/missing"
  Assert.isFalse(Schema.isValidManifest(missingIndex), "trainer pair routes must reference staged decoded indexes")

  local nativeOperand = manifest()
  nativeOperand.messages.sourceRoutes["battle/script-message"].sourceSelector = 19
  Assert.isFalse(Schema.isValidManifest(nativeOperand), "message route runtime data cannot leak a native selector")

  local wrongPlaceholder = manifest()
  wrongPlaceholder.messages.placeholders.species.bank = "message-bank/missing"
  Assert.isFalse(Schema.isValidManifest(wrongPlaceholder), "placeholder roles must reference their staged bank")
end

function T.message_source_routes_may_link_staged_message_selection_routes()
  local linked = manifest()
  local route = linked.messages.sourceRoutes["battle/trainer-pair-speech"]
  route.routes = { "menu/vs-recorder-feedback" }
  route.resources = { "trainer-message-index/offsets", "trainer-message-index/pairs" }
  Assert.isTrue(
    Schema.isValidManifest(linked),
    "message source route dependencies may point at staged normalized message selection routes"
  )
end

function T.unsupported_template_inputs_require_a_reason_without_inventing_an_input()
  local unsupported = manifest()
  unsupported.messages.templateInputs.poffin = { supported = false, reason = "unused-in-HGSS" }
  Assert.isTrue(
    Schema.isValidManifest(unsupported),
    "an explicitly unsupported template input may omit a runtime input and retain its source reason"
  )

  local contradictory = manifest()
  contradictory.messages.templateInputs.poffin = {
    input = "invented-value",
    supported = false,
    reason = "unused-in-HGSS",
  }
  Assert.isFalse(Schema.isValidManifest(contradictory), "unsupported template inputs cannot publish runtime values")
end

function T.script_message_route_binds_record_and_placeholder_inputs_to_battle_context()
  local missing = manifest()
  missing.messages.sourceRoutes["battle/script-message"].programContext = nil
  missing.coverage["battle/script-message"].programContext = nil
  Assert.isFalse(
    Schema.isValidManifest(missing),
    "script-message coverage must bind its record and tag operands to a typed battle context"
  )

  local linked = manifest()
  Assert.isTrue(
    Schema.isValidManifest(linked),
    "the script record, tag schema, context resolvers, and placeholder expansion route form one linked context"
  )

  local missingExpansion = manifest()
  missingExpansion.coverage["battle/script-message"].messageRoutes = {}
  Assert.isFalse(
    Schema.isValidManifest(missingExpansion),
    "script-message coverage must include the linked placeholder expansion route"
  )

  local missingTagResolver = manifest()
  missingTagResolver.messages.tagInputs.move = nil
  Assert.isFalse(Schema.isValidManifest(missingTagResolver), "every tag slot requires its source context resolver")

  local missingTagBuffer = manifest()
  missingTagBuffer.messages.placeholders.move = nil
  missingTagBuffer.messages.placeholderBanks.move = nil
  Assert.isFalse(
    Schema.isValidManifest(missingTagBuffer),
    "every tag slot requires a source message buffer or formatted-template contract"
  )

  local wrongRecordBank = manifest()
  wrongRecordBank.messages.sourceRoutes["battle/script-message"].programContext.record.bank = "message-bank/missing"
  wrongRecordBank.coverage["battle/script-message"].programContext.record.bank = "message-bank/missing"
  Assert.isFalse(Schema.isValidManifest(wrongRecordBank), "script record context must use its staged bank")

  local nativeMessageId = manifest()
  nativeMessageId.messages.sourceRoutes["battle/script-message"].programContext.record.messageId = 197
  Assert.isFalse(Schema.isValidManifest(nativeMessageId), "source message record IDs cannot leak into runtime context")

  local mismatchedCoverage = manifest()
  mismatchedCoverage.coverage["battle/script-message"].programContext = {
    program = "battle-script",
    context = "battle-message",
  }
  Assert.isFalse(Schema.isValidManifest(mismatchedCoverage), "coverage must preserve the linked message context")
end

function T.global_script_message_route_preserves_global_delivery_semantics()
  local candidate = manifest()
  local programContext = scriptMessageProgramContext()
  programContext.delivery = "message-scope-global"
  candidate.messages.sourceRoutes["battle/global-script-message"] = {
    banks = { "message-bank/script-controller" },
    inputs = { "messageRecordReference", "messageTagSymbol", "tagTypedParameters" },
    recordSelection = "literal-at-script-callsite",
    placeholderPlan = "battleMessageTags",
    programContext = programContext,
  }
  candidate.coverage["battle/global-script-message"] = {
    kind = "message-route",
    route = "battle/global-script-message",
    closureIdentity = string.rep("f", 40),
    resources = { "message-bank/script-controller" },
    operations = { "message-route" },
    messageRoutes = { "battle/message-template" },
    programContext = programContext,
  }
  local valid, failure = Schema.isValidManifest(candidate)
  Assert.isTrue(valid, "global script messages preserve their shared tag expansion path: " .. tostring(failure))

  local missingDelivery = manifest()
  local missingContext = scriptMessageProgramContext()
  missingContext.delivery = nil
  missingDelivery.messages.sourceRoutes["battle/global-script-message"] = {
    banks = { "message-bank/script-controller" },
    inputs = { "messageRecordReference", "messageTagSymbol", "tagTypedParameters" },
    recordSelection = "literal-at-script-callsite",
    placeholderPlan = "battleMessageTags",
    programContext = missingContext,
  }
  missingDelivery.coverage["battle/global-script-message"] = {
    kind = "message-route",
    route = "battle/global-script-message",
    closureIdentity = string.rep("f", 40),
    resources = { "message-bank/script-controller" },
    operations = { "message-route" },
    messageRoutes = { "battle/message-template" },
    programContext = missingContext,
  }
  Assert.isFalse(
    Schema.isValidManifest(missingDelivery),
    "global delivery must be explicit in normalized message context"
  )

  local wrongDelivery = manifest()
  local localContext = scriptMessageProgramContext()
  localContext.delivery = "message-scope-local"
  wrongDelivery.messages.sourceRoutes["battle/global-script-message"] = {
    banks = { "message-bank/script-controller" },
    inputs = { "messageRecordReference", "messageTagSymbol", "tagTypedParameters" },
    recordSelection = "literal-at-script-callsite",
    placeholderPlan = "battleMessageTags",
    programContext = localContext,
  }
  wrongDelivery.coverage["battle/global-script-message"] = {
    kind = "message-route",
    route = "battle/global-script-message",
    closureIdentity = string.rep("f", 40),
    resources = { "message-bank/script-controller" },
    operations = { "message-route" },
    messageRoutes = { "battle/message-template" },
    programContext = localContext,
  }
  Assert.isFalse(Schema.isValidManifest(wrongDelivery), "global route cannot claim local message delivery")
end

function T.staged_manifests_validate()
  local valid, failure = Schema.isValidManifest(manifest())
  Assert.isTrue(valid, "a complete staged manifest validates: " .. tostring(failure))
end

function T.text_roles_reject_native_font_ids()
  local leakedSourceId = manifest()
  leakedSourceId.messages.roles.narration.sourceFontId = 1
  Assert.isFalse(
    Schema.isValidManifest(leakedSourceId),
    "runtime text roles expose the resolved font path without native source IDs"
  )
end

function T.audio_roles_reject_native_narration_bank()
  local nativeBank = manifest()
  nativeBank.audioRoles.narrationBank = 197
  Assert.isFalse(Schema.isValidManifest(nativeBank), "runtime audio roles do not expose native narration-bank IDs")
end

function T.trainer_pair_message_route_requires_both_source_index_tables()
  local valid = Schema.isValidManifest(manifest())
  Assert.isTrue(valid, "trainer-pair lookup declares its decoded offset and pair tables")

  local missingPairs = manifest()
  missingPairs.messages.dynamicRoutes.trainerPairSpeech.selection.pairsResource = nil
  Assert.isFalse(Schema.isValidManifest(missingPairs), "trainer-pair selection cannot omit its pair table")

  local wrongStride = manifest()
  wrongStride.messages.dynamicRoutes.trainerPairSpeech.selection.pairSelection.recordStrideBytes = 2
  Assert.isFalse(Schema.isValidManifest(wrongStride), "trainer-pair rows retain the source four-byte stride")
end

function T.intro_music_requires_source_routes_and_audio_closure()
  local valid = manifest()
  valid.audioRoles.introMusic = makeIntroMusic()
  Assert.isTrue(Schema.isValidManifest(valid), "source-normalized intro music routes and closures validate")

  local missingBank = manifest()
  missingBank.audioRoles.introMusic = makeIntroMusic()
  missingBank.audioRoles.introMusic.sequenceClosures["audio/sequence/SEQ_GS_VS_NORAPOKE"].bankKey = nil
  Assert.isFalse(Schema.isValidManifest(missingBank), "every selected sequence closure names its compiled bank")

  local missingSamples = manifest()
  missingSamples.audioRoles.introMusic = makeIntroMusic()
  missingSamples.audioRoles.introMusic.sequenceClosures["audio/sequence/SEQ_GS_VS_NORAPOKE"].sampleKeys = {}
  Assert.isFalse(Schema.isValidManifest(missingSamples), "every selected sequence closure lists its samples")

  local malformedIdentity = manifest()
  malformedIdentity.audioRoles.introMusic = makeIntroMusic()
  malformedIdentity.audioRoles.introMusic.sequenceClosures["audio/sequence/SEQ_GS_VS_NORAPOKE"].closureIdentity =
    "not-a-sha1"
  Assert.isFalse(Schema.isValidManifest(malformedIdentity), "every selected sequence closure has a content identity")

  for _, field in ipairs({ "categoryId", "sequenceId", "bankId", "playerId" }) do
    local nativeId = manifest()
    nativeId.audioRoles.introMusic = makeIntroMusic()
    nativeId.audioRoles.introMusic.sequenceClosures["audio/sequence/SEQ_GS_VS_NORAPOKE"][field] = 1
    Assert.isFalse(Schema.isValidManifest(nativeId), "intro music runtime records reject native " .. field)
  end
end

function T.resources_require_decoded_cache_payloads()
  local incomplete = manifest()
  incomplete.resources["synthetic-transition-palette"].path = "assets/generated/battle/palette.bin"
  Assert.isFalse(
    Schema.isValidManifest(incomplete),
    "resource descriptors identify owned decoded payloads inside the battle cache"
  )
end

function T.particle_resources_require_decoded_emitter_and_resource_counts()
  local missing = manifest()
  missing.resources["transition/particle/synthetic"].geometry.resourceCount = nil
  Assert.isFalse(Schema.isValidManifest(missing), "APS descriptors identify decoded resource records")

  local negative = manifest()
  negative.resources["transition/particle/synthetic"].geometry.emitterCount = -1
  Assert.isFalse(Schema.isValidManifest(negative), "APS descriptors cannot publish negative emitter counts")
end

function T.effect_resources_accept_every_emitted_semantic_kind()
  for index, kind in ipairs({ "particle-emitter", "multi-cell", "multi-cell-animation" }) do
    local candidate = manifest()
    local contentIdentity = string.rep(tostring(index), 40)
    local key = "battle/effect-resource/" .. contentIdentity
    candidate.resources[key] = {
      kind = kind,
      contentIdentity = contentIdentity,
      format = "battle-effect-resource-v1",
      geometry = {},
      path = "data/generated/battle/resources/effect/content/" .. contentIdentity .. ".lua",
    }
    local valid, failure = Schema.isValidManifest(candidate)
    Assert.isTrue(valid, kind .. " is a producer-emitted semantic resource kind: " .. tostring(failure))
  end

  local unknown = manifest()
  unknown.resources["battle/effect-resource/unknown"] = {
    kind = "future-resource",
    contentIdentity = string.rep("4", 40),
    format = "battle-effect-resource-v1",
    geometry = {},
    path = "data/generated/battle/resources/effect/content/unknown.lua",
  }
  Assert.isFalse(Schema.isValidManifest(unknown), "the resource-kind allowlist remains closed")
end

function T.manifests_reject_missing_roles_and_bad_geometry()
  local missing = manifest()
  missing.hud.arrow = nil
  Assert.isFalse(Schema.isValidManifest(missing), "a manifest without its arrow role never validates")
  local missingDoubles = manifest()
  missingDoubles.hud.doubles = nil
  Assert.isFalse(
    Schema.isValidManifest(missingDoubles),
    "a manifest without its doubled health-box family never validates"
  )
  local badCell = manifest()
  badCell.hud.player.cells[1].objs[1].width = 0 - (0 / 0)
  Assert.isFalse(Schema.isValidManifest(badCell), "NaN sprite geometry never validates")
  local negative = manifest()
  negative.hud.player.cells[1].objs[1].width = -1
  Assert.isFalse(Schema.isValidManifest(negative), "negative sprite dimensions never validate")
  local unknown = manifest()
  unknown.audioRoles = { wild = "SEQ_MISSING" }
  Assert.isFalse(Schema.isValidManifest(unknown), "an incomplete audio role map never validates")
  local foreign = manifest()
  foreign.extraNative = { memberId = 3 }
  Assert.isFalse(Schema.isValidManifest(foreign), "native-shaped extension data never validates")
  local stale = manifest()
  stale.schema = "g4-battle-presentation-v1"
  Assert.isFalse(Schema.isValidManifest(stale), "an old catalog schema never validates as current")
end

function T.health_box_patch_spans_are_complete_and_stay_in_character_tile_units()
  local missing = manifest()
  missing.hud.patchSpans = nil
  Assert.isFalse(Schema.isValidManifest(missing), "the manifest includes source HUD patch spans")

  local valid = manifest()
  local sourceSpans = require("romdump.src.config.BattlePresentationSources").HUD_PATCH_SPANS
  valid.hud.patchSpans = sourceSpans
  Assert.isTrue(Schema.isValidManifest(valid), "source tile spans normalize into runtime character-buffer units")

  local incompleteNumbers = manifest()
  local numberSpans = {}
  for category, records in pairs(sourceSpans) do
    numberSpans[category] = records
  end
  numberSpans.currentHp = { sourceSpans.currentHp[1], sourceSpans.currentHp[2] }
  incompleteNumbers.hud.patchSpans = numberSpans
  Assert.isFalse(Schema.isValidManifest(incompleteNumbers), "HP numeral spans cover all six native side types")

  local invalidNumberTile = manifest()
  local invalidNumberSpans = {}
  for category, records in pairs(sourceSpans) do
    invalidNumberSpans[category] = records
  end
  invalidNumberSpans.maximumHp = { { sideType = 0, tile = 1022, count = 3 }, unpack(sourceSpans.maximumHp, 2) }
  invalidNumberTile.hud.patchSpans = invalidNumberSpans
  Assert.isFalse(Schema.isValidManifest(invalidNumberTile), "HP numeral spans stay within character tile bounds")

  local physicalOffset = manifest()
  physicalOffset.hud.patchSpans = {
    hp = { { sideType = 0, spans = { { offset = 0x4E0, size = 0 } } } },
    experience = {},
  }
  Assert.isFalse(Schema.isValidManifest(physicalOffset), "byte offsets and physical partial span tables are rejected")

  local incomplete = manifest()
  incomplete.hud.patchSpans = {
    hp = { { sideType = 0, spans = { { tile = 39, count = 0 }, { tile = 97, count = 6 } } } },
    experience = { { tile = 51, count = 5 }, { tile = 112, count = 7 } },
  }
  Assert.isFalse(Schema.isValidManifest(incomplete), "every semantic side type has its own complete patch map")
end

function T.double_player_mode_patch_spans_require_native_tiles_for_both_rows()
  local sourceSpans = require("romdump.src.config.BattlePresentationSources").HUD_PATCH_SPANS
  local valid = manifest()
  valid.hud.patchSpans = sourceSpans
  Assert.isTrue(Schema.isValidManifest(valid), "both double-player mode rows publish native character patches")

  local missing = manifest()
  local patchSpans = {}
  for key, value in pairs(sourceSpans) do
    patchSpans[key] = value
  end
  patchSpans.playerDoubleMode = { sourceSpans.playerDoubleMode[1] }
  missing.hud.patchSpans = patchSpans
  Assert.isFalse(Schema.isValidManifest(missing), "double-player mode patches cover both player rows")

  local badComponent = manifest()
  local invalidModes = { sourceSpans.playerDoubleMode[1], sourceSpans.playerDoubleMode[2] }
  invalidModes[1] = {
    sideType = 2,
    gauge = { { tile = 38, sourceTile = 78 }, unpack(sourceSpans.playerDoubleMode[1].gauge, 2) },
    numbers = sourceSpans.playerDoubleMode[1].numbers,
  }
  patchSpans = {}
  for key, value in pairs(sourceSpans) do
    patchSpans[key] = value
  end
  patchSpans.playerDoubleMode = invalidModes
  badComponent.hud.patchSpans = patchSpans
  Assert.isFalse(Schema.isValidManifest(badComponent), "native mode patches use staged component tiles")
end

function T.manifests_require_catalog_identity_and_source_backed_sections()
  local missingIdentity = manifest()
  missingIdentity.catalogIdentity = nil
  Assert.isFalse(Schema.isValidManifest(missingIdentity), "a staged catalog identifies its exact ROM bytes")
  local emptyLayouts = manifest()
  emptyLayouts.layouts = {}
  Assert.isFalse(Schema.isValidManifest(emptyLayouts), "an empty layout section never claims catalog readiness")
  local emptyMessages = manifest()
  emptyMessages.messages.entries = {}
  Assert.isFalse(Schema.isValidManifest(emptyMessages), "an empty message section never claims catalog readiness")
  local oldShape = manifest()
  oldShape.command = oldShape.menus.command
  Assert.isFalse(Schema.isValidManifest(oldShape), "old flat menu fields are rejected by the v2 contract")
end

function T.menu_feedback_patches_are_normalized_screen_assets()
  local nativeFeedback = manifest()
  local screen = nativeFeedback.menus.command.screens[1]
  screen.plane = 1
  screen.feedback = {
    fight = {
      selected = {
        image = screen.image,
        x = 16,
        y = 32,
        width = 224,
        height = 96,
      },
      pressed = {
        image = screen.image,
        x = 16,
        y = 32,
        width = 224,
        height = 96,
      },
    },
  }
  Assert.isTrue(
    Schema.isValidManifest(nativeFeedback),
    "native feedback states and physical BG plane use staged source bounds"
  )

  local invalidPlane = manifest()
  invalidPlane.menus.command.screens[1].plane = 4
  Assert.isFalse(Schema.isValidManifest(invalidPlane), "a menu screen names one physical BG plane")

  local outsideScreen = manifest()
  outsideScreen.menus.command.screens[1].feedback = nativeFeedback.menus.command.screens[1].feedback
  outsideScreen.menus.command.screens[1].feedback.fight.selected.x = 250
  Assert.isFalse(Schema.isValidManifest(outsideScreen), "a feedback patch stays inside its source screen")

  local unsupportedState = manifest()
  unsupportedState.menus.command.screens[1].feedback = nativeFeedback.menus.command.screens[1].feedback
  unsupportedState.menus.command.screens[1].feedback.fight.disabled =
    unsupportedState.menus.command.screens[1].feedback.fight.selected
  Assert.isFalse(Schema.isValidManifest(unsupportedState), "feedback states are source-selected or pressed only")
end

function T.native_slot_geometry_is_complete_unique_and_semantic()
  local missing = manifest()
  missing.battlefield = nil
  Assert.isFalse(Schema.isValidManifest(missing), "slot geometry is required by the current manifest schema")

  local duplicate = manifest()
  duplicate.battlefield.slots[6].sideType = duplicate.battlefield.slots[5].sideType
  Assert.isFalse(Schema.isValidManifest(duplicate), "each native side type occurs exactly once")

  local native = manifest()
  native.battlefield.slots[1].memberId = 24
  Assert.isFalse(Schema.isValidManifest(native), "physical producer identities do not enter runtime geometry")

  local priorities = manifest()
  priorities.battlefield.slots[1].hudPriority = 23
  priorities.battlefield.slots[1].hudBgPriority = 0
  Assert.isTrue(Schema.isValidManifest(priorities), "native HUD plane priorities are normalized")

  local missingPriority = manifest()
  missingPriority.battlefield.slots[1].hudPriority = nil
  Assert.isFalse(Schema.isValidManifest(missingPriority), "HUD OBJ priority is required")

  local invalidPriority = manifest()
  invalidPriority.battlefield.slots[1].hudPriority = 32
  Assert.isFalse(Schema.isValidManifest(invalidPriority), "HUD OBJ priority is bounded")
end

---@return table valid composed scene record
local function scene()
  return {
    schema = "g4-battle-scene-v3",
    key = "general/grass/day",
    background = "general",
    terrain = "grass",
    time = "day",
    canvasWidth = 512,
    canvasHeight = 256,
    viewport = { x = 0, y = 0, width = 256, height = 192 },
    layers = {
      {
        key = "background",
        backing = { width = 512, height = 256, mapWidth = 64, mapHeight = 32 },
        viewport = { x = 0, y = 0, width = 256, height = 192 },
        scroll = { x = 0, y = 0 },
        characters = {
          key = "battle-scene/general-grass-day/background/characters",
          path = "data/generated/battle/scenes/general-grass-day.bg3.chars",
          format = "indexed8",
        },
        map = {
          key = "battle-scene/general-grass-day/background/map",
          path = "data/generated/battle/scenes/general-grass-day.bg3.map",
          format = "tilemap",
        },
        palette = {
          key = "battle-scene/general-grass-day/background/palette",
          path = "data/generated/battle/scenes/general-grass-day.bg3.palette.lua",
          format = "rgb888",
        },
      },
    },
    imagePath = "assets/generated/battle/scenes/general-grass-day.png",
    introLayer = {
      image = "assets/generated/battle/scenes/general-grass-day-intro.png",
      width = 512,
      height = 256,
    },
    terrainSprites = {
      player = {
        image = "assets/generated/battle/scenes/general-grass-day-terrain-player.png",
        width = 80,
        height = 80,
        origin = { x = -40, y = -40 },
      },
      foe = {
        image = "assets/generated/battle/scenes/general-grass-day-terrain-foe.png",
        width = 80,
        height = 80,
        origin = { x = -40, y = -40 },
      },
    },
  }
end

function T.scene_records_validate_their_key_and_viewport()
  Assert.isTrue(Schema.isValidScene(scene()), "a composed scene record validates")
  local missingIntroLayer = scene()
  missingIntroLayer.introLayer = nil
  Assert.isFalse(Schema.isValidScene(missingIntroLayer), "a scene must stage its unbaked intro BG3 image")
  local missingTerrainSprites = scene()
  missingTerrainSprites.terrainSprites.foe = nil
  Assert.isFalse(Schema.isValidScene(missingTerrainSprites), "a scene must stage both terrain OBJ images")
  local fractionalOrigin = scene()
  fractionalOrigin.terrainSprites.player.origin.x = 0.5
  Assert.isFalse(Schema.isValidScene(fractionalOrigin), "terrain OBJ origins are integer cell coordinates")
  local escapingImage = scene()
  escapingImage.introLayer.image = "assets/generated/battle/scenes/../outside.png"
  Assert.isFalse(Schema.isValidScene(escapingImage), "scene images cannot escape their generated root")
  local escaped = scene()
  escaped.viewport = { x = 300, y = 0, width = 256, height = 192 }
  Assert.isFalse(Schema.isValidScene(escaped), "a viewport escaping its canvas never validates")
  local mismatch = scene()
  mismatch.key = "general/grass/night"
  Assert.isFalse(Schema.isValidScene(mismatch), "a scene key disagreeing with its axes never validates")
  local effect = scene()
  effect.key = "effect/flash/day"
  effect.background = "effect"
  Assert.isFalse(Schema.isValidScene(effect), "an effect background never validates as a scene")
  local stale = scene()
  stale.schema = "g4-battle-scene-v2"
  Assert.isFalse(Schema.isValidScene(stale), "an old scene schema never validates as current")
end

function T.picture_attributes_reject_runtime_unsafe_records()
  local base = manifest()
  Assert.isTrue(Schema.isValidManifest(base), "a native zero height and ordered ten-step animation validate")
  local badHeight = manifest()
  badHeight.pictures.attributes["pokemon/CHIKORITA/form-0/male/back"].height = 256
  Assert.isFalse(Schema.isValidManifest(badHeight), "picture height stays within its source byte")
  local shortAnimation = manifest()
  table.remove(shortAnimation.pictures.attributes["pokemon/CHIKORITA/form-0/male/back"].animation.steps)
  Assert.isFalse(Schema.isValidManifest(shortAnimation), "picture animation keeps all ten ordered entries")
  local badLoop = manifest()
  badLoop.pictures.attributes["pokemon/CHIKORITA/form-0/male/back"].animation.steps[1].next = -12
  Assert.isFalse(Schema.isValidManifest(badLoop), "picture animation loop targets stay inside the script")
  local badAuxiliary = manifest()
  badAuxiliary.pictures.attributes["pokemon/CHIKORITA/form-0/male/back"].animation.steps[1].auxiliary = 128
  Assert.isFalse(Schema.isValidManifest(badAuxiliary), "all signed animation bytes validate their range")
end

function T.pokepic_shadow_regions_require_all_bounded_native_sizes()
  Assert.isTrue(Schema.isValidManifest(manifest()), "the source-selected 64x64 shadow atlas validates")
  local missing = manifest()
  table.remove(missing.pictures.shadow.regions)
  Assert.isFalse(Schema.isValidManifest(missing), "all four native shadow-size regions are required")
  local outside = manifest()
  outside.pictures.shadow.regions[3].y = 60
  Assert.isFalse(Schema.isValidManifest(outside), "a native shadow crop cannot escape its staged image")
  local repeated = manifest()
  repeated.pictures.shadow.regions[4].size = 2
  Assert.isFalse(Schema.isValidManifest(repeated), "each source shadow-size selector occurs once")
end

function T.menu_contexts_publish_typed_source_inputs()
  local valid = manifest()
  Assert.isTrue(Schema.isValidManifest(valid), "source-derived menu context schemas validate")
  local missing = manifest()
  missing.menus.contexts = nil
  Assert.isFalse(Schema.isValidManifest(missing), "a manifest cannot omit typed menu context requirements")
  local invalid = manifest()
  invalid.menus.contexts.bugContest.caughtPokemon.fields.gender.values = { "male", "female" }
  Assert.isFalse(Schema.isValidManifest(invalid), "Bug Contest context preserves genderless caught Pokemon")
end

function T.scene_records_reject_incomplete_layer_closures()
  local missingMap = scene()
  missingMap.layers[1].map = nil
  Assert.isFalse(Schema.isValidScene(missingMap), "a scene cannot omit the BG3 map resource")
  local rasterSized = scene()
  rasterSized.layers[1].backing.width = 256
  Assert.isFalse(Schema.isValidScene(rasterSized), "the BG3 backing retains native map dimensions")
  local leakedProvenance = scene()
  leakedProvenance.layers[1].provenance = { terrainMember = 1 }
  Assert.isFalse(Schema.isValidScene(leakedProvenance), "producer provenance stays outside runtime scene records")
end

function T.launch_demands_carry_exact_deduplicated_members()
  local demand = {
    scenes = { "general/grass/day" },
    pages = { "CHIKORITA/f0/male/plain/back" },
    trainerPictures = { "front:YOUNGSTER", "back:PKMN_TRAINER_ETHAN" },
    battleBalls = { "ball:POKE_BALL" },
    iconKeys = {},
    audio = { roles = { "SEQ_GS_VS_NORAPOKE" }, banks = {}, cries = { "cry:CHIKORITA" } },
  }
  Assert.isTrue(Schema.isValidDemand(demand), "an exact launch demand validates")
  demand.trainerPictures[1] = "front:3"
  Assert.isFalse(Schema.isValidDemand(demand), "trainer demand cannot leak a raw class identifier")
  local empty = {
    scenes = {},
    pages = {},
    trainerPictures = {},
    battleBalls = {},
    iconKeys = {},
    audio = { roles = {}, banks = {}, cries = {} },
  }
  Assert.isFalse(Schema.isValidDemand(empty), "an empty demand never validates")
  local duplicated = {
    scenes = { "general/grass/day", "general/grass/day" },
    pages = {},
    trainerPictures = {},
    battleBalls = {},
    iconKeys = {},
    audio = { roles = {}, banks = {}, cries = {} },
  }
  Assert.isFalse(Schema.isValidDemand(duplicated), "a duplicated scene demand never validates")
end

return { tests = T }
