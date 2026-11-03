"""Pure validation and cask rendering, shared by packaging and its tests."""
import re

VERSION = re.compile(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z')

def validate_version(version):
    if not VERSION.fullmatch(version):
        raise ValueError('Release versions must be stable major.minor.patch values')
    return version

def check_versions(cargo_version, app_version):
    validate_version(cargo_version)
    if cargo_version != app_version:
        raise ValueError('Cargo and app bundle versions must match before packaging')
    return cargo_version

def validate_request(tag, ref, version, acceptance_checked, tap_token_present):
    validate_version(version)
    if tag == 'dry-run':
        return False
    if tag != 'v' + version or ref != 'refs/tags/' + tag:
        raise ValueError('Run Release on the matching version tag, not a branch')
    if not acceptance_checked:
        raise ValueError('Complete the physical acceptance checks before publishing')
    if not tap_token_present:
        raise ValueError('Add HOMEBREW_TAP_TOKEN to this repository before publishing')
    return True

def archive_name(version):
    return f'StreamCam-Controls-{validate_version(version)}-arm64.dmg'

def render_cask(version, digest):
    validate_version(version)
    if not re.fullmatch('[0-9a-f]{64}', digest):
        raise ValueError('Expected a lowercase SHA-256 digest')
    return f'''cask "streamcam-controls" do
  version "{version}"
  sha256 "{digest}"

  url "https://github.com/dreamorosi/streamcam-controls/releases/download/v#{{version}}/StreamCam-Controls-#{{version}}-arm64.dmg"
  name "StreamCam Controls"
  desc "Native preview and controls for Logitech StreamCam"
  homepage "https://github.com/dreamorosi/streamcam-controls"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "StreamCam Controls.app"
  binary "#{{appdir}}/StreamCam Controls.app/Contents/MacOS/streamcam"

  uninstall quit: "com.dreamorosi.streamcam-controls"

  caveats <<~EOS
    This app is ad-hoc signed, not notarized. macOS may require explicit
    Open Anyway approval in System Settings > Privacy & Security.
    Launch the app and allow Camera access before using its preview.
  EOS
end
'''
