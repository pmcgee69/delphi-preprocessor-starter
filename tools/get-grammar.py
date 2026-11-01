"""Downloads the Delphi grammar, compiled, from a TreeSitter4D release, checks
it against the release's SHA-256, and puts the DLLs in build\\win64 and
build\\win32. Python's py-tree-sitter loads the one matching its own bits.

    python tools/get-grammar.py

Or download TreeSitter4D-<version>-dlls.zip yourself from
https://github.com/pmcgee69/TreeSitter4D/releases and unzip its win64 and
win32 folders into build\\.
"""
import hashlib
import io
import pathlib
import urllib.request
import zipfile

VERSION = '0.1.0'
SHA256 = 'e84085ef83ba5445fd964c66c19c9a3c589af25db720dd8af11ffec51fcf4b9a'
URL = (f'https://github.com/pmcgee69/TreeSitter4D/releases/download/v{VERSION}/'
       f'TreeSitter4D-{VERSION}-dlls.zip')
BUILD = pathlib.Path(__file__).resolve().parents[1] / 'build'

print('downloading', URL)
data = urllib.request.urlopen(URL, timeout=120).read()
got = hashlib.sha256(data).hexdigest()
if got != SHA256:
    raise SystemExit(f"checksum differs: expected {SHA256}, got {got}; nothing written")
with zipfile.ZipFile(io.BytesIO(data)) as z:
    for name in z.namelist():
        if name.startswith(('win64/', 'win32/', 'licenses/')) and not name.endswith('/'):
            dest = BUILD / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(z.read(name))
            print('  ', dest.relative_to(BUILD.parent))
print('done: the grammar is tree-sitter-delphi13, MIT (build/licenses)')
