-- ROM-backed source proof for the post-selection Bag contract: the compiled
-- presentation follows the retail state variants and the field-runtime
-- cache closure covers every sound bank the Bag effects resolve to through
-- the real audio plan.

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

function T.compiled_bag_layers_share_state_overlays_and_move_bases(romFs)
  local bundle = compile(romFs)
  local manifest = assert(bundle.manifest)
  Assert.equal(manifest.schema, "g4-bag-assets-v20", "the compiled bundle carries the current contract")
  local backgrounds = assert(manifest.interactive.backgrounds, "the bundle publishes backgrounds")
  local browse = assert(backgrounds.browse, "the bundle publishes the browse base and rows")
  local perPocket = assert(browse[POCKET], "browse covers the pocket")
  Assert.notNil(perPocket.base, "browse publishes its blank-slot base")
  Assert.equal(#perPocket.rows, 3, "browse publishes three row patches")
  for row = 1, 3 do
    local patch = assert(perPocket.rows[row], "browse publishes row patch " .. row)
    Assert.equal(patch.width, 124, "row patches keep the audited art width")
    Assert.equal(patch.height, 38, "row patches keep the audited art height")
  end
  Assert.equal(#assert(backgrounds.browseCells, "the bundle publishes browse cell rects"), 6)
  local actionOverlay = assert(backgrounds.actionOverlay, "the bundle publishes the action overlay")
  local quantityOverlay = assert(backgrounds.quantityOverlay, "the bundle publishes the quantity overlay")
  local move = assert(backgrounds.move, "the bundle publishes the move background")
  local actionLayer = assert(
    (actionOverlay[POCKET] or {}).image,
    "the action overlay resolves one pocket layer shared across every visible count"
  )
  local quantityLayer = assert(
    (quantityOverlay[POCKET] or {}).image,
    "the quantity overlay resolves one pocket layer shared across every visible count"
  )
  Assert.isTrue(
    quantityLayer ~= actionLayer,
    "quantity layers its own overlay over the retained selected-item surface"
  )
  local moveBase =
    assert((move[POCKET] or {})[1], "the move background resolves its count base without baked origins")
  Assert.isTrue(actionLayer ~= moveBase.image, "action and move publish distinct retail state surfaces")
  local shared = assert((move[POCKET] or {})[0], "move resolves its shared unmutated base")
  Assert.isTrue(
    (move[POCKET] or {})[5] == shared and (move[POCKET] or {})[6] == shared,
    "the identical move counts 0, 5, and 6 share one base"
  )
  local marker = assert(backgrounds.moveMarker, "the bundle publishes the move origin marker")
  local patches = assert((marker.images or {})[POCKET], "the marker covers the pocket")
  Assert.notNil(patches.low, "the marker publishes the low band")
  Assert.notNil(patches.high, "the marker publishes the high band")
  Assert.equal(#marker.rects, 6, "the marker publishes all six origin rects")
  Assert.isNil(backgrounds.confirmation, "the toss flow owns no separate background")
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
    local sequenceId = assert(index.sequenceBySymbol[symbol], "the real audio plan resolves " .. symbol)
    local record = assert(index.sequences[sequenceId], symbol .. " has an index record")
    local bankId = assert(record.bankId, symbol .. " names its sound bank")
    Assert.isTrue(
      jobs["audio-bank:" .. tostring(bankId)] == true,
      symbol .. " resolves to bank " .. tostring(bankId) .. ", which the field-runtime closure must include"
    )
  end
  local tossAmount = assert(index.sequenceBySymbol["SEQ_SE_DP_BAG_004"], "the plan resolves the toss amount effect")
  local tossBank = assert(index.sequences[tossAmount].bankId, "the toss amount effect names its bank")
  Assert.equal(tossBank, 750, "the toss amount effect resolves to its verified bank")
  Assert.equal(index.bankBySymbol["BANK_SE_BAG"], 752, "the named bag bank keeps its pinned identity")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
