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

  local wrongKind = manifest()
  wrongKind.coverage["transition/trainer/red"].program = "synthetic-effect-probe"
  Assert.isFalse(Schema.isValidManifest(wrongKind), "transition callback routes are not animation stream programs")

  local genericOperation = manifest()
  genericOperation.coverage["transition/trainer/red"].operations = { "transition-route" }
  Assert.isFalse(
    Schema.isValidManifest(genericOperation),
    "transition coverage identifies the source callback's semantic operation"
  )
end

function T.coverage_requires_typed_program_and_semantic_menu_message_roots()
  local missingContext = manifest()
  missingContext.programs["synthetic-effect-probe"].requiredContext = nil
  Assert.isFalse(Schema.isValidManifest(missingContext), "program coverage requires typed runtime context")

  local missingMenu = manifest()
  missingMenu.coverage.command = nil
  Assert.isFalse(Schema.isValidManifest(missingMenu), "every menu route requires an admission closure")

  local missingMessage = manifest()
  missingMessage.coverage["battle/script-message"] = nil
  Assert.isFalse(Schema.isValidManifest(missingMessage), "every semantic message route requires an admission closure")
end

function T.unavailable_programs_and_coverage_use_a_closed_cause_variant()
  local valid = manifest()
  valid.version.id = "heartgold"
  local key = "CHARGE"
  local failure = { kind = "missing-selected-member", detail = "selected source dependency is absent" }
  valid.programs[key] = { status = "unavailable", failure = failure }
  valid.coverage[key] = {
    kind = "animation-program",
    program = key,
    status = "unavailable",
    failure = failure,
    resources = {},
    operations = { "unavailable" },
  }
  Assert.isTrue(Schema.isValidManifest(valid), "an unavailable route preserves its source cause without a fake closure")

  local available = manifest()
  available.version.id = "heartgold"
  available.programs[key] = available.programs["synthetic-effect-probe"]
  available.coverage[key] = available.coverage["synthetic-effect-probe"]
  available.coverage[key].program = key
  available.programs[key].status = "unavailable"
  Assert.isFalse(
    Schema.isValidManifest(available),
    "an unavailable program cannot retain executable content and claim a complete closure"
  )

  local causeMismatch = valid
  causeMismatch.coverage[key].failure = { kind = failure.kind, detail = "different source cause" }
  Assert.isFalse(Schema.isValidManifest(causeMismatch), "program and coverage causes must agree")

  local sourceIdentity = manifest()
  sourceIdentity.version.id = "heartgold"
  sourceIdentity.programs[key] = { status = "unavailable", failure = failure, memberId = 1970 }
  sourceIdentity.coverage[key] = {
    kind = "animation-program",
    program = key,
    status = "unavailable",
    failure = failure,
    resources = {},
    operations = { "unavailable" },
  }
  Assert.isFalse(Schema.isValidManifest(sourceIdentity), "unavailable runtime records contain no physical source ID")

  local unapprovedCause = manifest()
  unapprovedCause.version.id = "heartgold"
  unapprovedCause.programs[key] = { status = "unavailable", failure = { kind = "other", detail = "source failure" } }
  unapprovedCause.coverage[key] = {
    kind = "animation-program",
    program = key,
    status = "unavailable",
    failure = { kind = "other", detail = "source failure" },
    resources = {},
    operations = { "unavailable" },
  }
  Assert.isFalse(Schema.isValidManifest(unapprovedCause), "only the approved source cause kinds validate")
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

function T.animation_roots_require_complete_programs()
  local incomplete = manifest()
  local programKey = "synthetic-effect-probe"
  incomplete.programs[programKey].status = "unavailable"
  Assert.isFalse(Schema.isValidManifest(incomplete), "a catalog cannot mark an unavailable animation root as complete")
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

---@return table valid composed scene record
local function scene()
  return {
    schema = "g4-battle-scene-v2",
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
          key = "battle-scene/general-grass-day/bg3/characters",
          path = "data/generated/battle/scenes/general-grass-day.bg3.chars",
          format = "indexed4",
        },
        map = {
          key = "battle-scene/general-grass-day/bg3/map",
          path = "data/generated/battle/scenes/general-grass-day.bg3.map",
          format = "tilemap",
        },
        palette = {
          key = "battle-scene/general-grass-day/bg3/palette",
          path = "data/generated/battle/scenes/general-grass-day.bg3.palette.lua",
          format = "rgb888",
        },
      },
    },
    imagePath = "assets/generated/battle/scenes/general-grass-day.png",
  }
end

function T.scene_records_validate_their_key_and_viewport()
  Assert.isTrue(Schema.isValidScene(scene()), "a composed scene record validates")
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
  stale.schema = "g4-battle-scene-v1"
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
    audio = { roles = { "SEQ_GS_VS_NORAPOKE" }, banks = {}, cries = { "cry:CHIKORITA" } },
  }
  Assert.isTrue(Schema.isValidDemand(demand), "an exact launch demand validates")
  local empty = { scenes = {}, pages = {}, audio = { roles = {}, banks = {}, cries = {} } }
  Assert.isFalse(Schema.isValidDemand(empty), "an empty demand never validates")
  local duplicated = {
    scenes = { "general/grass/day", "general/grass/day" },
    pages = {},
    audio = { roles = {}, banks = {}, cries = {} },
  }
  Assert.isFalse(Schema.isValidDemand(duplicated), "a duplicated scene demand never validates")
end

return { tests = T }
