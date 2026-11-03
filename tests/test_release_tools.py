import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'scripts'))
from release_tools import archive_name, check_versions, render_cask, validate_request, validate_version

class ReleaseToolsTests(unittest.TestCase):
    def test_stable_versions_only(self):
        self.assertEqual(validate_version('0.1.0'), '0.1.0')
        for value in ['v0.1.0', '0.1', '01.1.0', '0.1.0-beta', '0.1.0;bad', '0.1.0\n']:
            with self.assertRaises(ValueError):
                validate_version(value)

    def test_versions_must_agree(self):
        self.assertEqual(check_versions('0.1.0', '0.1.0'), '0.1.0')
        with self.assertRaises(ValueError):
            check_versions('0.1.0', '0.2.0')

    def test_dry_run_cannot_publish(self):
        self.assertFalse(validate_request('dry-run', 'refs/heads/main', '0.1.0', False, False))

    def test_publishing_requires_matching_tag_and_ref(self):
        self.assertTrue(validate_request('v0.1.0', 'refs/tags/v0.1.0', '0.1.0', True, True))
        for tag, ref in [('v0.1.0', 'refs/heads/main'), ('v0.2.0', 'refs/tags/v0.2.0')]:
            with self.assertRaises(ValueError):
                validate_request(tag, ref, '0.1.0', True, True)

    def test_publication_requires_acceptance_and_token(self):
        for checked, token in [(False, True), (True, False)]:
            with self.assertRaises(ValueError):
                validate_request('v0.1.0', 'refs/tags/v0.1.0', '0.1.0', checked, token)

    def test_cask_targets_app_and_bundled_cli(self):
        cask = render_cask('0.1.0', 'a' * 64)
        self.assertIn('app "StreamCam Controls.app"', cask)
        self.assertIn('binary "#{appdir}/StreamCam Controls.app/Contents/MacOS/streamcam"', cask)
        self.assertIn('depends_on arch: :arm64', cask)
        self.assertIn('depends_on macos: :sonoma', cask)
        self.assertIn('not notarized', cask)
        self.assertNotIn('no-quarantine', cask)
        self.assertEqual(archive_name('0.1.0'), 'StreamCam-Controls-0.1.0-arm64.dmg')

    def test_invalid_hash_is_rejected(self):
        for value in ['abc', 'g' * 64, 'A' * 64, 'a' * 64 + '\n']:
            with self.assertRaises(ValueError):
                render_cask('0.1.0', value)

if __name__ == '__main__':
    unittest.main()
