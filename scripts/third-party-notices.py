"""Bundle upstream license files for the selected Apple Silicon dependency graph."""
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
metadata = json.loads(subprocess.check_output([
    'cargo', 'metadata', '--locked', '--format-version', '1', '--filter-platform',
    'aarch64-apple-darwin', '--manifest-path', str(root / 'backend/Cargo.toml')
], cwd=root, text=True))
nodes = {node['id']: node for node in metadata['resolve']['nodes']}
visited = set()
def visit(identity):
    if identity in visited:
        return
    visited.add(identity)
    for dependency in nodes[identity]['deps']:
        visit(dependency['pkg'])
visit(metadata['resolve']['root'])
packages = sorted((p for p in metadata['packages'] if p['id'] in visited and p['source']),
                  key=lambda p: (p['name'], p['version']))
sections = ['StreamCam Controls third-party notices\n\nThe upstream license files below '
            'retain their own terms. StreamCam Controls itself is MIT licensed.\n']
for package in packages:
    directory = Path(package['manifest_path']).parent
    files = {file for file in directory.iterdir() if file.is_file()
             and any(word in file.name.lower() for word in ['license', 'licence', 'copying', 'copyright'])}
    if package.get('license_file'):
        files.add(directory / package['license_file'])
    if not files:
        raise SystemExit(f"No upstream license text found for {package['name']} {package['version']}")
    sections.append(f"\n{'=' * 72}\n{package['name']} {package['version']}\n"
                    f"Declared license: {package.get('license') or 'see license files'}\n")
    for file in sorted(files):
        if not file.resolve().is_relative_to(directory.resolve()):
            raise SystemExit(f"License file escapes package directory: {package['name']}")
        sections.append(f"\n--- {file.name} ---\n{file.read_text()}\n")
Path(sys.argv[1]).write_text(''.join(sections))
print(f'Bundled upstream license texts for {len(packages)} dependencies.')
