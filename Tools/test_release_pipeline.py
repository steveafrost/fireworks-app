"""Offline release-contract checks; not a substitute for Apple notarization."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ReleaseContractTests(unittest.TestCase):
    def test_archive_is_unsigned_and_hardened_for_developer_id_export(self):
        """The Developer ID identity is applied at export, never at archive.

        Pinning CODE_SIGN_IDENTITY on top of the project's automatic signing makes
        Xcode refuse the archive ("conflicting provisioning settings"), and letting
        it sign the archive automatically demands a Mac development profile this
        team cannot get without a registered Mac ("Your team has no devices from
        which to generate a provisioning profile"). So the archive is built with
        signing off and the export applies the Developer ID options.
        """
        script = (ROOT / "Tools/release-dmg.sh").read_text()
        archive = script.split('say "Archiving (Release)"', 1)[1].split('say "Exporting', 1)[0]
        self.assertNotIn(
            'CODE_SIGN_IDENTITY="$IDENTITY"', archive,
            "pinning the identity over automatic signing makes Xcode refuse the archive",
        )
        self.assertIn("CODE_SIGNING_ALLOWED=NO", archive)
        self.assertIn("ENABLE_HARDENED_RUNTIME=YES", archive)
        export = script.split('say "Exporting', 1)[1]
        self.assertIn("ExportOptions-developer-id.plist", export)

    def test_a_failed_build_prints_the_real_error(self):
        """xcodebuild piped through `tail` reports a failure with no reason given.

        That is how a Release-only compile error and a provisioning failure both
        arrived as "Archiving project ... (1 failure)". Both steps now log in full
        and surface the error: lines on failure.
        """
        script = (ROOT / "Tools/release-dmg.sh").read_text()
        self.assertNotIn("| tail -", script, "piping xcodebuild discards the real error")
        self.assertIn("build/release-evidence/archive.log", script)
        self.assertIn('grep -E "error:" build/release-evidence/archive.log', script)
        self.assertIn('grep -E "error:" build/release-evidence/export.log', script)

    def test_dmg_is_stapled_before_its_hash_is_published(self):
        script = (ROOT / "Tools/release-dmg.sh").read_text()
        packaging = script.split('say "Packaging the DMG"', 1)[1]
        self.assertIn('xcrun notarytool submit "$DMG"', packaging)
        self.assertIn('xcrun stapler staple "$DMG"', packaging)
        self.assertIn('xcrun stapler validate "$DMG"', packaging)
        self.assertLess(packaging.index('xcrun stapler validate'), packaging.index('SHA='))

    def test_publishable_cask_comes_from_checked_in_template(self):
        path = ROOT / "Tools/fireworks.rb.in"
        self.assertTrue(path.exists(), "a checked-in cask template is required")
        template = path.read_text()
        self.assertIn('version "@VERSION@"', template)
        self.assertIn('sha256 "@SHA256@"', template)
        self.assertIn('depends_on macos: ">= :sonoma"', template)
        script = (ROOT / "Tools/release-dmg.sh").read_text()
        self.assertIn('Tools/fireworks.rb.in', script)
        self.assertIn('tee build/fireworks.rb', script)
        self.assertLess(script.index('xcrun stapler validate "$DMG"'), script.index('tee build/fireworks.rb'))


if __name__ == "__main__":
    unittest.main()
