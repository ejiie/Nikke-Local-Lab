"""Source-free v3 assembly and completion-boundary regressions (no UnityPy/data)."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


assembler = load("candidate_assembler", "materialize-nll-boss-runtime-profile.py")
gate = load("candidate_gate", "verify-nll-boss-onboarding-candidate.py")
fx = gate.fx


def pin(payload):
    return {"sha256": fx.digest(payload), "byteLength": len(payload)}


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cache = self.root / "cache"
        self.cache.mkdir()
        self.qte = {"modeCode": "target_monster_linked_element_only", "recordCount": 5,
                    "monsterReferenceCount": 3, "sourceElementCodes": ["electric"],
                    **{key: fx.digest(key.encode()) for key in (
                        "recordSetSha256", "immutablePayloadSetSha256", "sourceElementSetSha256")}}
        self.qte_rows = ["electric"] * 5
        self.source = {"sourceAffinity": {"bossElementCode": "electric", "weaknessCode": "iron"},
                       "quickTimeEventAffinity": self.qte}
        self.shield = {"modeCode": "dynamic_affinity_linked", "functionRecordCount": 3, "fxVariants": []}
        for role in gate.TARGETS:
            payload = ("synthetic-" + role).encode()
            (self.cache / (role + ".bundle")).write_bytes(payload)
            self.shield["fxVariants"].append({"bossElementCode": role, "mappingSetSha256": fx.digest(payload),
                "mappings": [{"sourceKindCode": "common" if role in fx.ROLES else "boss_specific",
                              "assetBundles": [pin(payload)]}]})
        self.profile = {"schemaVersion": 3, "contractId": "nll/boss-runtime-variant-profile/v3",
                        "seasonNumber": 7, "profileCode": "synthetic-boss", **self.source,
                        "elementShield": self.shield}

    @staticmethod
    def materialize(source, target, unitypy):
        return target.read_bytes() + b"-derived", {
            "sourceTransformCount": 14, "targetTransformCount": 14,
            "matchedTransformCount": 13, "modifiedTransformCount": 4,
            "matchedTransformValueSetSha256": fx.digest(b"synthetic-transforms"),
            "nonTransformObjectSetSha256": fx.digest(target.read_bytes())}

    def assemble(self):
        return assembler.assemble_normalization(self.source, self.shield, self.cache, self.materialize, None)

    def test_automatic_plan_regenerates_without_draft(self):
        before = {p.name: p.read_bytes() for p in self.cache.iterdir()}
        plan = self.assemble()
        self.assertEqual([row["bossElementCode"] for row in plan["variants"]], list(fx.ROLES))
        for row in plan["variants"]:
            self.assertEqual(row["variantBundleSha256"], fx.digest(before[row["bossElementCode"] + ".bundle"] + b"-derived"))
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.cache.iterdir()})
        self.profile["shieldFxTransformNormalization"] = plan
        path = self.root / "profile.json"
        path.write_bytes(fx.encoded(self.profile))
        result = fx.create(path, gate.digest(path), self.cache, self.root / "candidate", self.materialize, None)
        fx.inspect_or_restore(self.root / "candidate", result["manifestSha256"])

    def test_qte_validation(self):
        self.assertEqual(assembler.require_v3_qte(self.source), self.qte)
        # Linked rows may keep other original elements; the variant handles each row.
        for codes in (["fire"], ["electric", "fire"], ["electric", "water"]):
            source = copy.deepcopy(self.source)
            source["quickTimeEventAffinity"]["sourceElementCodes"] = codes
            self.assertEqual(assembler.require_v3_qte(source)["sourceElementCodes"], codes)
        for field, values in {
            "modeCode": ["not_applicable", None], "recordCount": [0, -1, True, "5"],
            "monsterReferenceCount": [0, False],
            "sourceElementCodes": [[], None, "electric", ["unresolved"], ["fire", "electric"],
                                   ["electric", "electric"], [["electric"]],
                                   ["fire", "water", "wind", "electric", "iron", "unresolved"]],
            "recordSetSha256": [None, "X" * 64, assembler.EMPTY_SHA256],
            "immutablePayloadSetSha256": [None], "sourceElementSetSha256": [None],
        }.items():
            for value in values:
                source = copy.deepcopy(self.source)
                source["quickTimeEventAffinity"][field] = value
                with self.subTest(field=field, value=value), self.assertRaises(assembler.PipelineError):
                    assembler.require_v3_qte(source)

    def test_unsupported_source_and_family_rejected(self):
        for element in ("fire", "water", "wind", "iron"):
            self.source["sourceAffinity"]["bossElementCode"] = element
            with self.assertRaisesRegex(assembler.PipelineError, "fx_family_unsupported"):
                self.assemble()
        self.source["sourceAffinity"]["bossElementCode"] = "electric"
        self.shield["fxVariants"][0]["mappings"][0]["sourceKindCode"] = "boss_specific"
        with self.assertRaisesRegex(assembler.PipelineError, "fx_family_unsupported"):
            self.assemble()

    def test_missing_and_multiple_bundle_rejected(self):
        (self.cache / "iron.bundle").unlink()
        with self.assertRaises(Exception):
            self.assemble()
        self.shield["fxVariants"][0]["mappings"][0]["assetBundles"].append(pin(b"another"))
        with self.assertRaisesRegex(assembler.PipelineError, "fx_family_unsupported"):
            self.assemble()

    def receipt(self, weakness, v3=True):
        affinity = self.profile["sourceAffinity"]
        changed = weakness != affinity["weaknessCode"]
        self.profile["schemaVersion"] = 3 if v3 else 2
        if v3:
            self.profile["quickTimeEventAffinity"] = self.qte
        else:
            self.profile.pop("quickTimeEventAffinity", None)
        pack = self.root / (weakness + ".pack")
        if changed:
            pack.write_bytes(("synthetic-pack-" + weakness).encode())
        # Materializer semantics: convert every linked row, count actual differences.
        qte_modified = sum(code != gate.TARGETS[weakness] for code in self.qte_rows) if changed and v3 else 0
        codes = ["target_monster_element_reference", "target_dynamic_shield_fx_reference"] if changed else []
        if qte_modified:
            codes.append("target_qte_element_reference")
        target = next(row for row in self.shield["fxVariants"] if row["bossElementCode"] == gate.TARGETS[weakness])
        return {"schemaVersion": 1, "contractId": "nll/boss-affinity-static-data-variant/v1",
            "variantProfileCode": "synthetic-boss", "variantProfileSha256": "a" * 64,
            "seasonNumber": 7, "weaknessCode": weakness, "sourceBossElementCode": affinity["bossElementCode"],
            "sourceBossWeaknessCode": affinity["weaknessCode"], "targetBossElementCode": gate.TARGETS[weakness],
            "sourceStaticDataSha256": "b" * 64, "variantRequired": changed,
            "modifiedMonsterRecordCount": int(changed), "modifiedFunctionRecordCount": 3 if changed else 0,
            "modifiedQuickTimeEventRecordCount": qte_modified,
            "quickTimeEventAffinityContractVerified": v3, "modifiedElementRecordCount": 0,
            "modifiedTableCount": len(codes), "modifiedTableCodes": codes,
            "elementTablePreserved": True, "clientElementIndexInvariantVerified": True,
            "serverStaticDataModified": False, "officialInstallModified": False,
            "rawSourceIdentifierPersisted": False, "runtimeAdmissionStatusCode": "not_assessed",
            "shieldFxTransformStatusCode": "pending_isolated_asset_overlay"
                if v3 and gate.TARGETS[weakness] in fx.ROLES else "not_required",
            "elementShieldModeCode": "dynamic_affinity_linked",
            "variantStaticDataSha256": gate.digest(pack) if changed else None,
            "shieldFxAssetBundles": target["mappings"][0]["assetBundles"],
            "shieldFxMappingSetSha256": target["mappingSetSha256"]}, pack

    def validate(self, weakness, receipt, pack):
        rows = self.qte_rows if "quickTimeEventAffinity" in self.profile else []
        gate.validate_variant(self.profile, "a" * 64, "b" * 64, weakness, receipt, pack, rows)

    def test_five_variants_v2_and_v3(self):
        for v3 in (False, True):
            for weakness in gate.TARGETS:
                receipt, pack = self.receipt(weakness, v3)
                self.validate(weakness, receipt, pack)
                # A single-source boss keeps the previous expectation: all rows change.
                self.assertEqual(receipt["modifiedQuickTimeEventRecordCount"],
                                 5 if v3 and weakness != "iron" else 0)

    def use_mixed_water_boss(self):
        # Water boss whose linked rows keep electric x2 and water x1 (shared rows).
        self.profile["sourceAffinity"] = self.source["sourceAffinity"] = {
            "bossElementCode": "water", "weaknessCode": "electric"}
        self.qte_rows = ["electric", "electric", "water"]
        self.qte.update(recordCount=3, sourceElementCodes=["electric", "water"])

    def test_mixed_source_qte_counts_only_rows_that_change(self):
        self.use_mixed_water_boss()
        self.assertEqual(assembler.require_v3_qte(self.source)["sourceElementCodes"], ["electric", "water"])
        expected = {"electric": 0, "iron": 1, "fire": 3, "water": 3, "wind": 3}
        for weakness, count in expected.items():
            receipt, pack = self.receipt(weakness)
            self.assertEqual(receipt["modifiedQuickTimeEventRecordCount"], count)
            self.assertEqual("target_qte_element_reference" in receipt["modifiedTableCodes"], count > 0)
            self.assertEqual(pack.exists(), weakness != "electric")
            self.validate(weakness, receipt, pack)
            for wrong in {0, 1, 3} - {count}:
                with self.subTest(weakness=weakness, wrong=wrong), self.assertRaises(ValueError):
                    self.validate(weakness, {**receipt, "modifiedQuickTimeEventRecordCount": wrong}, pack)

    def test_tree_without_qte_node_changes_no_qte_row_for_any_weakness(self):
        # Linked rows are still in the sealed discovery, but the profile has no QTE
        # contract because the tree has no QTE node: every weakness changes 0 rows.
        self.use_mixed_water_boss()
        discovery = {"shieldPatterns": {"quickTimeEvents": [{"elementCode": code} for code in self.qte_rows]}}
        self.profile.pop("quickTimeEventAffinity")
        self.assertEqual(gate.qte_source_elements(self.profile, discovery), [])
        for weakness in gate.TARGETS:
            receipt, pack = self.receipt(weakness, v3=False)
            self.assertEqual(receipt["modifiedQuickTimeEventRecordCount"], 0)
            self.assertNotIn("target_qte_element_reference", receipt["modifiedTableCodes"])
            gate.validate_variant(self.profile, "a" * 64, "b" * 64, weakness, receipt, pack, [])
            for field, value in (("modifiedQuickTimeEventRecordCount", 1),
                                 ("modifiedQuickTimeEventRecordCount", 3),
                                 ("quickTimeEventAffinityContractVerified", True)):
                with self.subTest(weakness=weakness, field=field, value=value), self.assertRaises(ValueError):
                    gate.validate_variant(self.profile, "a" * 64, "b" * 64, weakness,
                                          {**receipt, field: value}, pack, [])

    def test_qte_rows_come_from_sealed_discovery(self):
        self.use_mixed_water_boss()
        self.profile["quickTimeEventAffinity"] = self.qte
        def discovery(codes):
            return {"shieldPatterns": {"quickTimeEvents": [{"elementCode": code} for code in codes]}}
        self.assertEqual(gate.qte_source_elements(self.profile, discovery(self.qte_rows)), self.qte_rows)
        for codes in (["electric", "electric"], ["electric", "electric", "fire"], ["electric", "electric", None],
                      ["electric"] * 3, []):
            with self.subTest(codes=codes), self.assertRaises(ValueError):
                gate.qte_source_elements(self.profile, discovery(codes))
        with self.assertRaises(ValueError):
            gate.qte_source_elements(self.profile, {})
        self.profile.pop("quickTimeEventAffinity")
        self.assertEqual(gate.qte_source_elements(self.profile, {}), [])

    def test_receipt_drift_missing_and_wrong_types_rejected(self):
        receipt, pack = self.receipt("fire")
        for key in receipt:
            changed = copy.deepcopy(receipt)
            del changed[key]
            with self.subTest(missing=key), self.assertRaises((ValueError, KeyError)):
                self.validate("fire", changed, pack)
        for field, values in {
            "variantProfileSha256": ["c" * 64], "sourceStaticDataSha256": ["c" * 64],
            "seasonNumber": [True, 8], "modifiedQuickTimeEventRecordCount": [0, 4, "5"],
            "modifiedFunctionRecordCount": [0, 4, True, "2"], "modifiedElementRecordCount": [1, False],
            "modifiedTableCodes": [["target_monster_element_reference"]],
            "quickTimeEventAffinityContractVerified": [False, "true"],
            "elementTablePreserved": [False], "runtimeAdmissionStatusCode": ["ready"],
            "variantStaticDataSha256": ["d" * 64], "shieldFxAssetBundles": [[], receipt["shieldFxAssetBundles"] * 2],
        }.items():
            for value in values:
                changed = copy.deepcopy(receipt)
                changed[field] = value
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    self.validate("fire", changed, pack)
        pack.write_bytes(b"drift")
        with self.assertRaises(ValueError):
            self.validate("fire", receipt, pack)

    def test_default_must_not_emit_pack_or_qte_changes(self):
        receipt, pack = self.receipt("iron")
        for field, value in (("modifiedQuickTimeEventRecordCount", 5), ("variantStaticDataSha256", "b" * 64)):
            changed = {**receipt, field: value}
            with self.assertRaises(ValueError):
                self.validate("iron", changed, pack)
        pack.write_bytes(b"unexpected")
        with self.assertRaises(ValueError):
            self.validate("iron", receipt, pack)

    def complete_fixture(self):
        root = self.root / "full-candidate"
        root.mkdir()
        (root / "five-affinity-variants").mkdir()
        source_pack = self.root / "source.pack"
        source_pack.write_bytes(b"synthetic-source-pack")
        self.profile["shieldFxTransformNormalization"] = self.assemble()
        behavior_bytes = b"synthetic-behavior"
        (self.cache / "behavior.bundle").write_bytes(behavior_bytes)
        self.profile["behaviorAssembly"] = {"bundleSha256": fx.digest(behavior_bytes), "bundleByteLength": len(behavior_bytes)}
        profile_path = root / "boss-runtime-variant.profile.json"
        profile_path.write_bytes(fx.encoded(self.profile))
        profile_sha = gate.digest(profile_path)
        discovery = {"seasonNumber": 7, "profileCode": "synthetic-boss", "shieldPatterns": {
            "quickTimeEvents": [{"elementCode": code} for code in self.qte_rows]}}
        discovery_path = root / "content-discovery.receipt.json"
        discovery_path.write_bytes(fx.encoded(discovery))
        behavior = {**discovery, "sourceDiscoverySha256": gate.digest(discovery_path)}
        behavior_path = root / "behavior-assembly.receipt.json"
        behavior_path.write_bytes(fx.encoded(behavior))
        (root / "onboarding-candidate.receipt.json").write_bytes(fx.encoded({
            **behavior, "contractId": "nll/boss-onboarding-candidate/v1", "profileSha256": profile_sha,
            "behaviorAssemblySha256": gate.digest(behavior_path), "runtimeAdmissionStatusCode": "not_assessed"}))
        fx.create(profile_path, profile_sha, self.cache, root / "shield-fx-candidate", self.materialize, None)
        for weakness in gate.TARGETS:
            receipt, pack = self.receipt(weakness)
            receipt["variantProfileSha256"] = profile_sha
            receipt["sourceStaticDataSha256"] = gate.digest(source_pack)
            (root / f"five-affinity-variants/{weakness}.receipt.json").write_bytes(fx.encoded(receipt))
            if pack.exists():
                pack.rename(root / f"five-affinity-variants/{weakness}.pack")
        return root, source_pack

    def seal(self, root, source):
        return gate.finalize(root, source, 7, "synthetic-boss", "e" * 64, self.cache)

    def test_complete_seal_is_candidate_only_and_exclusive(self):
        root, source = self.complete_fixture()
        result = self.seal(root, source)
        self.assertEqual(result["runtimeAdmissionStatusCode"], "not_assessed")
        self.assertFalse(result["registryModified"])
        self.assertEqual(result["statusCode"], "verified_candidate_pending_runtime_delivery")
        self.assertEqual(result["affinityVariantCount"], 5)
        self.assertFalse((root / "onboarding-admission.receipt.json").exists())
        with self.assertRaisesRegex(ValueError, "seal_exists"):
            self.seal(root, source)

    def test_partial_five_variants_never_seal(self):
        root, source = self.complete_fixture()
        (root / "five-affinity-variants/iron.receipt.json").unlink()
        with self.assertRaises(Exception):
            self.seal(root, source)
        self.assertFalse((root / "onboarding-verified-candidate.receipt.json").exists())

    def test_acquired_behavior_sealed_and_drift_cannot_use_legacy_copy(self):
        root, source = self.complete_fixture()
        acquired = root / 'acquired-behavior'
        acquired.mkdir()
        bundle = acquired / 'externalbehavior_assets_all_ab12.bundle'
        shutil.copyfile(self.cache / 'behavior.bundle', bundle)
        (root / 'behavior-acquisition.receipt.json').write_bytes(fx.encoded({
            'contractId': 'nll/boss-behavior-acquisition/v1', 'statusCode': 'acquired',
            'asset': pin(bundle.read_bytes())}))
        result = self.seal(root, source)
        paths = {r['relativePath'] for r in result['artifacts']}
        self.assertIn('acquired-behavior/' + bundle.name, paths)
        self.assertIn('behavior-acquisition.receipt.json', paths)
        bundle.write_bytes(b'drift')
        with self.assertRaises(fx.CandidateError):
            gate.build_receipt(root, source, 7, 'synthetic-boss', 'e' * 64, self.cache)

    def test_restored_or_drifted_fx_never_seal(self):
        root, source = self.complete_fixture()
        candidate = root / "shield-fx-candidate"
        manifest_sha = gate.digest(candidate / "manifest.json")
        fx.inspect_or_restore(candidate, manifest_sha, restore=True)
        with self.assertRaisesRegex(fx.CandidateError, "overlay_drifted"):
            self.seal(root, source)
        self.assertFalse((root / "onboarding-verified-candidate.receipt.json").exists())

    def test_profile_or_discovery_drift_never_seal(self):
        root, source = self.complete_fixture()
        (root / "content-discovery.receipt.json").write_bytes(fx.encoded({"seasonNumber": 8, "profileCode": "synthetic-boss"}))
        with self.assertRaises(ValueError):
            self.seal(root, source)
        self.assertFalse((root / "onboarding-verified-candidate.receipt.json").exists())

    def test_common_powershell_success_failure_retry_and_duplicate(self):
        pwsh = shutil.which("pwsh")
        self.assertIsNotNone(pwsh, "PowerShell 7 is required for the common pipeline checks")
        # Linux commonly exposes /usr/bin/pwsh as a symlink. Pass the actual
        # executable, preserving the production pipeline's no-reparse boundary.
        pwsh = str(Path(pwsh).resolve())
        fixture, source = self.complete_fixture()
        (self.cache / "behavior.bundle").rename(self.cache / "externalbehavior_assets_all_abcdef.bundle")
        inputs = self.root / "inputs"
        inputs.mkdir()
        source = source.rename(inputs / "source.pack")
        config = inputs / "config.json"
        config.write_text("{}")
        database = inputs / "db.json"
        database.write_text("{}")
        registry = inputs / "registry"
        registry.mkdir()
        (registry / "registry.json").write_text('{"contractId":"nll/boss-runtime-variant-registry/v1","schemaVersion":1,"profiles":[]}')
        unity = inputs / "unity"
        unity.mkdir()
        shim = inputs / "synthetic-tools.ps1"
        shim.write_text(r'''
$ErrorActionPreference = 'Stop'
$taskArguments = @($args)
function Arg([string]$Name) { $i = [Array]::IndexOf($taskArguments, $Name); if ($i -lt 0) { throw 'synthetic_argument_missing' }; $taskArguments[$i + 1] }
function Copy-Fixture([string]$Name, [string]$Output) { Copy-Item -LiteralPath (Join-Path $env:NLL_TEST_FIXTURE $Name) -Destination $Output }
switch ($taskArguments[0]) {
    '--discover-boss-content' {
        Copy-Fixture 'content-discovery.receipt.json' (Arg '--discover-boss-content')
        [IO.File]::WriteAllText((Arg '--private-discovery-output'), '{"synthetic":true}')
        [IO.File]::WriteAllText((Join-Path $env:NLL_TEST_FIXTURE 'last-private-path.txt'), (Arg '--private-discovery-output'))
    }
    '--validate-boss-variant-profile' {
        $profile = Get-Content -Raw -LiteralPath (Arg '--validate-boss-variant-profile') | ConvertFrom-Json
        @{ contractId = 'nll/boss-runtime-variant-profile-validation/v1'; seasonNumber = $profile.seasonNumber;
           profileCode = $profile.profileCode; profileSha256 = (Get-FileHash -LiteralPath (Arg '--validate-boss-variant-profile')).Hash.ToLowerInvariant() } | ConvertTo-Json -Compress
    }
    '--create-static-data-variant' {
        $weakness = Arg '--weakness-code'
        if ($env:NLL_TEST_FAILURE -eq 'partial' -and $weakness -eq 'wind') { exit 17 }
        Copy-Fixture ("five-affinity-variants/$weakness.receipt.json") (Arg '--variant-static-data-receipt')
        if ($weakness -ne 'iron') { Copy-Fixture ("five-affinity-variants/$weakness.pack") (Arg '--variant-static-pack') }
        if ($env:NLL_TEST_FAILURE -eq 'bad-qte' -and $weakness -eq 'iron') {
            $receipt = Get-Content -Raw -LiteralPath (Arg '--variant-static-data-receipt') | ConvertFrom-Json
            $receipt.modifiedQuickTimeEventRecordCount = 5
            [IO.File]::WriteAllText((Arg '--variant-static-data-receipt'), ($receipt | ConvertTo-Json -Depth 16))
        }
        if ($env:NLL_TEST_FAILURE -eq 'input-drift' -and $weakness -eq 'iron') {
            [IO.File]::AppendAllText((Arg '--source-db'), ' ')
        }
    }
    '-B' {
        switch ([IO.Path]::GetFileName($taskArguments[1])) {
            'inspect-nll-boss-behavior-assets.py' { Copy-Fixture 'behavior-assembly.receipt.json' (Arg '--output') }
            'materialize-nll-boss-runtime-profile.py' {
                if ($env:NLL_TEST_FAILURE -eq 'shield-missing') { exit 1 }
                if ($env:NLL_TEST_FAILURE -eq 'assembler-code') {
                    # A real child process, like the assembler: stderr text plus a controlled code.
                    & $env:NLL_TEST_PYTHON -c "import sys; sys.stderr.write('synthetic private raw-id-123\nboss_profile_qte_v3_discovery_invalid\n'); sys.exit(1)"
                    exit $LASTEXITCODE
                }
                $assessment = @{ contractId = 'nll/boss-shield-preparation-assessment/v1';
                    sourceDiscoverySha256 = (Get-FileHash -LiteralPath (Arg '--source-discovery')).Hash.ToLowerInvariant();
                    behaviorAssemblySha256 = (Get-FileHash -LiteralPath (Arg '--behavior-receipt')).Hash.ToLowerInvariant();
                    runtimeAdmissionStatusCode = 'not_assessed'; preparationStatusCode = 'not_required' }
                if ($env:NLL_TEST_FAILURE -eq 'shield-bound-drift') { $assessment.sourceDiscoverySha256 = '0' * 64 }
                if ($env:NLL_TEST_FAILURE -in @('shield-review', 'shield-review-exit0', 'shield-recipe-drift')) {
                    $recipeRoot = Join-Path (Split-Path -Parent (Arg '--profile-output')) 'shield-fx-preparation'
                    New-Item -ItemType Directory -Path $recipeRoot | Out-Null
                    $recipePath = Join-Path $recipeRoot 'recipes.receipt.json'
                    [IO.File]::WriteAllText($recipePath, '{"synthetic":true}')
                    $assessment.fx = @{}
                    $assessment.shieldFxRecipesSha256 = (Get-FileHash -LiteralPath $recipePath).Hash.ToLowerInvariant()
                    $assessment.shieldFxRecipeDeliveryStatusCode = 'verified_preparation_candidates'
                    $assessment.preparationStatusCode = 'review_required'
                    if ($env:NLL_TEST_FAILURE -eq 'shield-recipe-drift') { [IO.File]::AppendAllText($recipePath, ' ') }
                }
                [IO.File]::WriteAllText((Arg '--shield-assessment-output'), ($assessment | ConvertTo-Json -Depth 8))
                if ($env:NLL_TEST_FAILURE -in @('shield-review', 'shield-recipe-drift')) { exit 1 }
                Copy-Fixture 'boss-runtime-variant.profile.json' (Arg '--profile-output')
                Copy-Fixture 'onboarding-candidate.receipt.json' (Arg '--receipt-output')
            }
            'materialize-nll-shield-fx-candidate.py' {
                Copy-Item -LiteralPath (Join-Path $env:NLL_TEST_FIXTURE 'shield-fx-candidate') -Destination (Arg '--output-root') -Recurse
                if ($env:NLL_TEST_FAILURE -eq 'bad-fx') {
                    [IO.File]::WriteAllText((Join-Path (Arg '--output-root') 'overlay/fire.bundle'), 'drift')
                }
            }
            'verify-nll-boss-onboarding-candidate.py' { & $env:NLL_TEST_PYTHON @taskArguments; exit $LASTEXITCODE }
            default { throw 'synthetic_unknown_python_tool' }
        }
    }
    default {
        if ([IO.Path]::GetFileName($taskArguments[0]) -eq 'inspect-nll-boss-behavior-assets.py') {
            Copy-Fixture 'behavior-assembly.receipt.json' (Arg '--output')
        } else { throw 'synthetic_unknown_tool' }
    }
}
exit 0
''', encoding="utf-8")
        before_registry = (registry / "registry.json").read_bytes()
        env = {**os.environ, "NLL_TEST_FIXTURE": str(fixture), "NLL_TEST_PYTHON": sys.executable}
        command = [pwsh, "-NoProfile", "-File", str(Path(__file__).with_name("invoke-nll-boss-onboarding.ps1")),
                   "-CandidateOnly", "-SeasonNumber", "7", "-ProfileCode", "synthetic-boss", "-DisplayNameCode", "synthetic-boss",
                   "-MaterializerPath", str(shim), "-MaterializerHostPath", pwsh,
                   "-StaticDataPackPath", str(source), "-SourceDatabasePath", str(database), "-GameConfigPath", str(config),
                   "-AssetCacheRoot", str(self.cache), "-PythonPath", str(shim), "-UnityPyRoot", str(unity), "-RegistryRoot", str(registry)]
        for failure in ("partial", "bad-qte", "bad-fx", "input-drift", "shield-review", "shield-review-exit0",
                        "shield-recipe-drift", "shield-bound-drift", "shield-missing", "assembler-code", "none"):
            output = self.root / ("run-" + failure)
            result = subprocess.run([*command, "-OutputRoot", str(output)], env={**env, "NLL_TEST_FAILURE": failure},
                                    text=True, capture_output=True, timeout=90)
            with self.subTest(failure=failure):
                self.assertEqual(result.returncode == 0, failure == "none", result.stdout + result.stderr)
                self.assertEqual((output / "onboarding-verified-candidate.receipt.json").exists(), failure == "none")
                self.assertFalse((output / "onboarding-admission.receipt.json").exists())
                self.assertEqual((registry / "registry.json").read_bytes(), before_registry)
                self.assertEqual(len(list(registry.iterdir())), 1)
                private_path = Path((fixture / "last-private-path.txt").read_text())
                self.assertFalse(private_path.exists())
                expected = {"shield-review": "shield_preparation_review_required",
                            "shield-review-exit0": "shield_preparation_review_required",
                            "shield-recipe-drift": "shield_recipe_delivery_invalid",
                            "shield-bound-drift": "shield_assessment_invalid",
                            "shield-missing": "profile_assembly_failed"}.get(failure)
                if expected:
                    self.assertIn("boss_onboarding_" + expected, result.stderr)
                if failure == "assembler-code":
                    # The assembler's controlled code reaches the job; its other text does not.
                    self.assertIn("boss_profile_qte_v3_discovery_invalid", result.stderr)
                    self.assertNotIn("boss_onboarding_profile_assembly_failed", result.stderr)
                    self.assertNotIn("raw-id-123", result.stdout + result.stderr)
        # Same output root is rejected before discovery, including after failure.
        for suffix in ("partial", "none"):
            result = subprocess.run([*command, "-OutputRoot", str(self.root / ("run-" + suffix))], env=env,
                                    text=True, capture_output=True, timeout=20)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("boss_onboarding_output_exists", result.stderr)
        for extra, output, code in (
            (["-ReplaceExistingProfile"], self.root / "replace", "candidate_cannot_replace"),
            ([], self.cache / "overlap", "output_overlaps_input"),
        ):
            result = subprocess.run([*command, *extra, "-OutputRoot", str(output)], env=env,
                                    text=True, capture_output=True, timeout=20)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("boss_onboarding_" + code, result.stderr)
            self.assertFalse(output.exists())
        legacy = [arg for arg in command if arg != "-CandidateOnly"]
        result = subprocess.run([*legacy, "-OutputRoot", str(self.root / "legacy-v3")], env=env,
                                text=True, capture_output=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("boss_onboarding_v3_runtime_delivery_required", result.stderr)
        self.assertEqual((registry / "registry.json").read_bytes(), before_registry)


if __name__ == "__main__":
    unittest.main()
