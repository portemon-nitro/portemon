-- ROM-backed source proof for the post-selection Bag contract: the compiled
-- presentation follows the retail state variants, the toss flow owns no
-- separate background, and the field-runtime cache closure covers every
-- sound bank the Bag effects resolve to through the real audio plan.

local Assert = require("tests.support.Assert")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
local BagAssetCompiler = require("romdump.src.digest.ui.BagAssetCompiler")
local BagAssetSchema = require("libs.assets.src.BagAssetSchema")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local POCKET = "medicine"

local function compile(romFs)
  local bundle, err = BagAssetCompiler.compile(romFs)
  Assert.notNil(bundle, "the production Bag compiler rebuilds the presentation bundle: " .. tostring(err))
  return assert(bundle)
end

local function runtimeJobSet()
  local set = {}
  for _, job in ipairs(ArtifactJobs.fieldRuntimeJobs()) do
    set[job.kind .. ":" .. tostring(job.key)] = true
  end
  return set
end

function T.compiled_action_and_move_follow_their_retail_state_variants(romFs)
  local bundle = compile(romFs)
  local manifest = assert(bundle.manifest)
  Assert.equal(manifest.schema, "g4-bag-assets-v16", "the compiled bundle carries the current contract")
  local backgrounds = assert(manifest.interactive.backgrounds, "the bundle publishes backgrounds")
  local action = assert(backgrounds.action, "the bundle publishes the action background")
  local move = assert(backgrounds.move, "the bundle publishes the move background")
  local actionVariant = assert(
    (action[POCKET] or {})[1] or (action[POCKET] or {})["1"],
    "the action background varies with the visible count"
  )
  local moveVariant = assert(
    ((move[POCKET] or {})[1] or (move[POCKET] or {})["1"] or {}).none,
    "the move background varies with the visible count and origin row"
  )
  Assert.isTrue(
    actionVariant.image ~= moveVariant.image,
    "action and move publish distinct retail state surfaces"
  )
  Assert.isNil(backgrounds.confirmation, "the toss flow owns no separate background")
end

function T.quantity_keeps_the_selected_panel_surface(romFs)
  local bundle = compile(romFs)
  local backgrounds = assert(bundle.manifest.interactive.backgrounds)
  local quantity = assert(backgrounds.quantity, "the bundle publishes the quantity background")
  local action = assert(backgrounds.action, "the bundle publishes the action background")
  local quantityVariant = assert(
    (quantity[POCKET] or {})[1] or (quantity[POCKET] or {})["1"],
    "the quantity background varies with the visible count"
  )
  local actionVariant = assert(
    (action[POCKET] or {})[1] or (action[POCKET] or {})["1"],
    "setup resolves the matching action variant"
  )
  Assert.isTrue(
    quantityVariant.image ~= actionVariant.image,
    "quantity layers its own overlay over the retained selected-item surface"
  )
end

function T.bag_effect_banks_belong_to_the_field_runtime_closure(romFs)
  local catalog = assert(AudioCompiler.plan(romFs))
  local index = assert(catalog.index, "the audio plan publishes its sequence index")
  local symbols = {
    "SEQ_SE_DP_SELECT",
    "SEQ_SE_GS_GEARCANCEL",
    "SEQ_SE_DP_BAG_004",
    "SEQ_SE_DP_BOX03",
    "SEQ_SE_DP_BUTTON9",
  }
  local jobs = runtimeJobSet()
  for _, symbol in ipairs(symbols) do
    local sequenceId = assert(
      index.sequenceBySymbol[symbol],
      "the real audio plan resolves " .. symbol
    )
    local record = assert(index.sequences[sequenceId], symbol .. " has an index record")
    local bankId = assert(record.bankId, symbol .. " names its sound bank")
    Assert.isTrue(
      jobs["audio-bank:" .. tostring(bankId)] == true,
      symbol .. " resolves to bank " .. tostring(bankId) .. ", which the field-runtime closure must include"
    )
  end
  local tossAmount = assert(index.sequenceBySymbol["SEQ_SE_DP_BAG_004"], "the plan resolves the toss amount effect")
  local tossBank = assert(index.sequences[tossAmount].bankId, "the toss amount effect names its bank")
  local namedBagBank = index.bankBySymbol["BANK_SE_BAG"]
  Assert.equal(tossBank, 750, "the toss amount effect resolves to its verified bank")
  Assert.equal(namedBagBank, 752, "the named bag bank keeps its pinned identity")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
