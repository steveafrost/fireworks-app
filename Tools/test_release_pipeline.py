"""Offline release-contract checks; not a substitute for Apple notarization."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ReleaseContractTests(unittest.TestCase):
    def test_archive_uses_distribution_identity_and_hardened_runtime(self):
        script = (ROOT / "Tools/release-dmg.sh").read_text()
        archive = script.split('say "Archiving (Release)"', 1)[1].split('say "Exporting', 1)[0]
        self.assertIn('CODE_SIGN_IDENTITY="$IDENTITY"', archive)
        self.assertIn('ENABLE_HARDENED_RUNTIME=YES', archive)

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
