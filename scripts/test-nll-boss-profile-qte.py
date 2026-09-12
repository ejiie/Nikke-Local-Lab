"""Source-free checks: a v2 onboarding profile cannot silently discard QTE."""

import copy
import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    "boss_profile", Path(__file__).with_name("materialize-nll-boss-runtime-profile.py")
)
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)


class QteAdmissionTests(unittest.TestCase):
    def baseline(self):
        return {"quickTimeEventAffinity": {
            "modeCode": "not_applicable", "recordCount": 0, "monsterReferenceCount": 0,
            "sourceElementCodes": [], "recordSetSha256": profile.EMPTY_SHA256,
            "immutablePayloadSetSha256": profile.EMPTY_SHA256,
            "sourceElementSetSha256": profile.EMPTY_SHA256,
        }}

    def test_closed_no_qte_allowed(self):
        source = self.baseline()
        before = copy.deepcopy(source)
        profile.require_v2_qte_compatibility(source)
        self.assertEqual(before, source)

    def test_absent_discovery_rejected(self):
        for value in ({}, {"quickTimeEventAffinity": None}, {"quickTimeEventAffinity": []}):
            with self.subTest(value=value):
                with self.assertRaisesRegex(profile.PipelineError, "^boss_profile_qte_discovery_missing$"):
                    profile.require_v2_qte_compatibility(value)

    def test_elemental_qte_requires_v3(self):
        source = self.baseline()
        source["quickTimeEventAffinity"].update({
            "modeCode": "target_monster_linked_element_only", "recordCount": 5,
            "monsterReferenceCount": 3, "sourceElementCodes": ["electric"],
        })
        with self.assertRaisesRegex(profile.PipelineError, "^boss_profile_qte_v3_pipeline_required$"):
            profile.require_v2_qte_compatibility(source)

    def test_inconsistent_or_incomplete_closure_rejected(self):
        changes = {
            "modeCode": [None, "unresolved", "target_monster_linked_element_only"],
            "recordCount": [False, "0", -1, 1],
            "monsterReferenceCount": [False, "0", -1, 1],
            "sourceElementCodes": [None, ["unresolved"], ["electric"]],
            "recordSetSha256": [None, "0" * 64],
            "immutablePayloadSetSha256": [None, "0" * 64],
            "sourceElementSetSha256": [None, "0" * 64],
        }
        for field, values in changes.items():
            for value in values:
                source = self.baseline()
                source["quickTimeEventAffinity"][field] = value
                with self.subTest(field=field, value=value):
                    with self.assertRaisesRegex(profile.PipelineError, "^boss_profile_qte_v3_pipeline_required$"):
                        profile.require_v2_qte_compatibility(source)
            source = self.baseline()
            del source["quickTimeEventAffinity"][field]
            with self.subTest(missing=field):
                with self.assertRaisesRegex(profile.PipelineError, "^boss_profile_qte_v3_pipeline_required$"):
                    profile.require_v2_qte_compatibility(source)


if __name__ == "__main__":
    unittest.main()
