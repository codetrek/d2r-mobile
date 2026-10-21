"""Synthetic platform and source-cache contracts; no game files or simulator required."""

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest

IOS = Path(__file__).resolve().parents[1]
REPO = IOS.parent.parent
sys.path.insert(0, str(IOS / 'tools/simulator'))
import shaders
import build as simulator_build
import inputs as simulator_inputs


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


guest = load('synthetic_guest', IOS.parent / 'tools/guest_dylib.py')
fetch = load('synthetic_fetch', IOS.parent / 'gfx/tools/dmsh_fetch.py')


class Contracts(unittest.TestCase):
    def setUp(self):
        root = REPO / '.tmp/simulator-tests'
        root.mkdir(parents=True, exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(dir=root)
        self.root = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def modules(self):
        (self.root / 'main.fixups.tsv').write_text('# TEXT_END 100\n# PATCH_OFF 8000\n')
        (self.root / 'main.patched.bin').write_bytes(bytes(range(256)) * 129)

    def platform(self, raw):
        offset = 32
        for _ in range(struct.unpack_from('<I', raw, 16)[0]):
            command, size = struct.unpack_from('<II', raw, offset)
            if command == 0x32:
                return struct.unpack_from('<I', raw, offset + 8)[0]
            offset += size
        self.fail('missing build version')

    def test_device_default_and_fresh_simulator_identity(self):
        self.modules()
        device = guest.build(self.root, ['main'])
        simulator = guest.build(self.root, ['main'], guest.Platform.IOS_SIMULATOR)
        self.assertEqual(self.platform(device), 2)
        self.assertEqual(self.platform(simulator), 7)
        self.assertNotEqual(device, simulator)
        self.assertEqual(simulator[0x4000:0x4100], bytes(range(256)))
        fw, _ = guest.write(self.root, self.root / 'output', ['main'], platform=guest.Platform.IOS_SIMULATOR)
        self.assertEqual(plistlib.loads((Path(fw) / 'Info.plist').read_bytes())['CFBundleSupportedPlatforms'], ['iPhoneSimulator'])
        self.assertEqual(simulator_build.inspect_platform(Path(fw) / 'Guest', 6)['platform'], 7)
        (self.root / 'device').write_bytes(device)
        with self.assertRaises(ValueError):
            simulator_build.inspect_platform(self.root / 'device', 6)

    def test_invalid_platform_does_not_create_output(self):
        with self.assertRaises(ValueError):
            guest.write(self.root, self.root / 'output', ['main'], platform='ios-simulator')
        self.assertFalse((self.root / 'output').exists())
        with self.assertRaises(ValueError):
            guest.Platform.parse('macos')

    def test_truncated_platform_commands(self):
        self.modules()
        raw = guest.build(self.root, ['main'], guest.Platform.IOS_SIMULATOR)
        for truncated in (raw[:16], raw[:64]):
            path = self.root / 'truncated'
            path.write_bytes(truncated)
            with self.assertRaises(ValueError):
                simulator_build.inspect_platform(path, 6)

    def donor(self):
        self.modules()
        (self.root / 'sdk.fixups.tsv').write_text('# TEXT_END 100\n# PATCH_OFF 8000\n')
        (self.root / 'sdk.patched.bin').write_bytes(b'\xa7' * 0x8200)
        app = self.root / 'donor.app'
        (app / 'dm').mkdir(parents=True)
        for name in ('main', 'sdk'):
            (self.root / (name + '.gates.tsv')).write_text('synthetic-' + name + '\n')
            for suffix in ('.fixups.tsv', '.gates.tsv'):
                (app / 'dm' / (name + suffix)).write_bytes((self.root / (name + suffix)).read_bytes())
        guest.write(self.root, app / 'Frameworks', ['main', 'sdk'])
        return app

    def test_donor_module_and_metadata_binding(self):
        app = self.donor()
        proof = simulator_inputs.validate_donor(app, self.root)
        self.assertTrue(proof['section_bytes_matched'])
        self.assertEqual(set(proof['metadata']), {'main.fixups.tsv', 'main.gates.tsv', 'sdk.fixups.tsv', 'sdk.gates.tsv'})
        self.assertEqual(proof['modules']['main'], shaders.sha(self.root / 'main.patched.bin'))
        for name in proof['metadata']:
            with self.subTest(name=name):
                path = app / 'dm' / name
                original = path.read_bytes()
                path.write_bytes(original + b'changed\n')
                with self.assertRaisesRegex(ValueError, 'metadata mismatch'):
                    simulator_inputs.validate_donor(app, self.root)
                path.write_bytes(original)

    def test_donor_guest_and_selected_module_bytes_must_match(self):
        app = self.donor()
        path = self.root / 'main.patched.bin'
        original = path.read_bytes()
        path.write_bytes(b'changed' + original[7:])
        with self.assertRaisesRegex(ValueError, 'module bytes mismatch'):
            simulator_inputs.validate_donor(app, self.root)
        path.write_bytes(original)
        donor = app / 'Frameworks/Guest.framework/Guest'
        raw = bytearray(donor.read_bytes())
        raw[0x4000] ^= 1
        donor.write_bytes(raw)
        with self.assertRaisesRegex(ValueError, 'module bytes mismatch'):
            simulator_inputs.validate_donor(app, self.root)

    def test_donor_container_bounds(self):
        app = self.donor()
        path = app / 'Frameworks/Guest.framework/Guest'
        raw = path.read_bytes()
        for malformed in (raw[:16], raw[:64], raw[:16] + struct.pack('<I', 1025) + raw[20:]):
            with self.subTest(size=len(malformed)):
                path.write_bytes(malformed)
                with self.assertRaises(ValueError):
                    simulator_inputs.validate_donor(app, self.root)

    def cache(self):
        self.key = 'a' * 16
        self.chain = 'b' * 12
        self.cache_path = self.root / ('b-' + self.chain)
        self.cache_path.mkdir()
        source = ('using namespace metal;\nstruct main0_out { float4 m_0 [[color(0)]]; };\n'
                  'fragment main0_out main0()\n{\n    main0_out out = {};\n'
                  '    out.m_0 = float4(1);\n    return out;\n}\n')
        variant, metadata = fetch.variant(source, [], om_only_ok=True)
        self.assertIsNotNone(variant)
        self.reflection = dict(key=self.key + '_b', chain=self.chain, stage='ps', entry='main0',
                               bindings=[], drv_unfillable=[], fetch=metadata)
        for suffix in ('.metal', '.metallib'):
            (self.cache_path / (self.key + '_b' + suffix)).write_text(source)
        (self.cache_path / (self.key + '_bf.metallib')).write_text(variant)
        (self.cache_path / (self.key + '_b.json')).write_text(json.dumps(self.reflection))
        (self.cache_path / '_b_build.json').write_text(json.dumps([dict(key=self.key, st='ok', err='')]))
        self.proof = dict(chain=self.chain, keys=1, counts=dict(reflection=1, msl=1, source_cache=2),
                          kind='translated MSL source; Metal compilation and execution not performed')
        self.refresh()

    def refresh(self):
        self.proof['artifacts'] = [dict(path='shader-cache/' + self.cache_path.name + '/' + p.name,
                                      size=p.stat().st_size, sha256=shaders.sha(p))
                                   for p in sorted(self.cache_path.iterdir())]
        self.manifest = self.root / 'qualification.json'
        self.manifest.write_text(json.dumps(self.proof))

    def validate(self):
        return shaders.validate(self.cache_path, self.manifest, fetch.variant, {self.key}, {self.key})

    def test_exact_source_and_bf_coverage(self):
        self.cache()
        proof = self.validate()
        self.assertEqual((proof['keys'], proof['libraries'], proof['variants']), (1, 2, 1))
        result = self.root / 'staged'
        shaders.stage(self.cache_path, self.manifest, result, fetch.variant, {self.key}, {self.key})
        self.assertEqual({p.name for p in result.iterdir()},
                         {self.key + '_b.json', self.key + '_b.metallib', self.key + '_bf.metallib'})
        with self.assertRaises(FileExistsError):
            shaders.stage(self.cache_path, self.manifest, result, fetch.variant, {self.key}, {self.key})

    def test_wrong_json_chain(self):
        self.cache()
        self.reflection['chain'] = 'c' * 12
        (self.cache_path / (self.key + '_b.json')).write_text(json.dumps(self.reflection))
        self.refresh()
        with self.assertRaisesRegex(ValueError, 'reflection mismatch'):
            self.validate()

    def test_missing_bf_even_with_refreshed_manifest(self):
        self.cache()
        (self.cache_path / (self.key + '_bf.metallib')).unlink()
        self.refresh()
        with self.assertRaises(FileNotFoundError):
            self.validate()

    def test_changed_bf_source_and_metadata(self):
        for mutate in ('source', 'metadata'):
            with self.subTest(mutate=mutate):
                self.cache()
                if mutate == 'source':
                    (self.cache_path / (self.key + '_bf.metallib')).write_text('different source')
                else:
                    self.reflection['fetch']['outputs'][0]['color'] = 1
                    (self.cache_path / (self.key + '_b.json')).write_text(json.dumps(self.reflection))
                self.refresh()
                with self.assertRaisesRegex(ValueError, 'BF source/reflection'):
                    self.validate()
                for path in self.cache_path.iterdir():
                    path.unlink()
                self.cache_path.rmdir()

    def test_empty_keys_and_wrong_expected_set(self):
        self.cache()
        with self.assertRaisesRegex(ValueError, 'explicit shader map'):
            shaders.validate(self.cache_path, self.manifest, fetch.variant, {self.key}, {'c' * 16})
        (self.cache_path / '_b_build.json').write_text('[]')
        self.refresh()
        with self.assertRaisesRegex(ValueError, 'empty'):
            self.validate()

    def test_source_identity_and_compiled_artifact_rejected(self):
        self.cache()
        path = self.cache_path / (self.key + '_b.metallib')
        path.write_bytes(b'MTLBnot-source')
        with self.assertRaisesRegex(ValueError, 'identity mismatch'):
            self.validate()
        self.refresh()
        with self.assertRaisesRegex(ValueError, 'not a compiled library'):
            self.validate()

    def test_extra_file_and_manifest_traversal(self):
        self.cache()
        (self.cache_path / 'extra').write_text('unexpected')
        with self.assertRaisesRegex(ValueError, 'artifact set'):
            self.validate()
        self.refresh()
        with self.assertRaisesRegex(ValueError, 'expected-set'):
            self.validate()
        self.proof['artifacts'][0]['path'] = '../' + self.proof['artifacts'][0]['path']
        self.manifest.write_text(json.dumps(self.proof))
        with self.assertRaisesRegex(ValueError, 'duplicate or missing'):
            self.validate()


if __name__ == '__main__':
    unittest.main()
