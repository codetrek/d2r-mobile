"""Frozen CPU admission, base-only staging and descriptor-bound package checks."""

from copy import deepcopy
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/ios/tools/simulator'))
import profile_inputs
import shaders
import snapshot
import test_profile_metadata as fixtures


class ProfileStagingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fixtures.ProfileMetadataTests.setUpClass()

    @classmethod
    def tearDownClass(cls):
        fixtures.ProfileMetadataTests.tearDownClass()

    def setUp(self):
        self.fixture = fixtures.ProfileMetadataTests('test_real_production_native_order_and_timestamp_honesty')
        self.fixture.setUp()
        self.root = self.fixture.directory

    def tearDown(self):
        self.fixture.tearDown()

    def source(self):
        root = self.root / 'frozen-source'
        proof = snapshot.capture([(name, REPO / name) for name in profile_inputs.CLOSURE], root)
        return root, proof

    def admit(self, source, metadata=None, execute=None, name='admission'):
        fixture = self.fixture
        selected = fixture.out if metadata is None else metadata
        def run(argv, cwd):
            subprocess.run([str(value) for value in argv], cwd=cwd, check=True)
        return profile_inputs.admit(source, fixture.cache, fixture.qualification, fixture.source,
                                    fixture.derived, selected,
                                    profile_inputs.identity(fixture.out / 'metadata-profile.json')['sha256'],
                                    Path(sys.executable), self.root / name,
                                    Path('/Applications/Xcode.app/Contents/Developer'), run if execute is None else execute)

    def test_explicit_modes_and_missing_paired_descriptors(self):
        args = SimpleNamespace(shader_mode='canonical', shader_profile=None, profile_metadata=None,
                               metadata_descriptor_sha256=None, validation_python=None)
        self.assertEqual(profile_inputs.selected_inputs(args), {})
        args.shader_profile = self.root
        with self.assertRaises(ValueError): profile_inputs.selected_inputs(args)
        args.shader_mode = 'derived-profile'
        with self.assertRaises(ValueError): profile_inputs.selected_inputs(args)
        args.profile_metadata = self.root
        args.metadata_descriptor_sha256 = 'a' * 64
        args.validation_python = Path(sys.executable)
        self.assertEqual(set(profile_inputs.selected_inputs(args)), {'shader_profile', 'profile_metadata'})
        args.shader_mode = 'unknown'
        with self.assertRaises(ValueError): profile_inputs.selected_inputs(args)

    def test_frozen_native_admission_stage_and_packaging(self):
        descriptor = self.fixture.produce()
        source, proof = self.source()
        result = self.admit(source)
        snapshot.verify(source, proof, originals=True)
        self.assertTrue(result['validation']['primary_source_unchanged'])
        self.assertEqual(result['keys'], 5)
        self.assertEqual(len(result['staged_files']), 10)
        resources = self.root / 'resources'
        destination = resources / 'msl' / ('b-' + result['chain'])
        staged = shaders.stage_profile(self.fixture.derived, result, destination)
        self.assertEqual(staged['variants'], 0)
        self.assertFalse(any('_bf' in path.name for path in destination.iterdir()))
        metadata_ids = {name: profile_inputs.identity(self.fixture.out / name) for name in profile_inputs.METADATA_FILES}
        meta = profile_inputs.stage_metadata(self.fixture.out, metadata_ids, resources / 'dm',
                    profile=self.fixture.derived, profile_identity=profile_inputs.identity(self.fixture.derived / 'profile.json'))
        expected = {'msl/b-' + result['chain'] + '/' + name: profile_inputs.identity(destination / name)
                    for name in staged['identities']}
        expected.update(meta['resources'])
        package = self.root / 'package'
        package.mkdir()
        (package / 'executable').write_bytes(b'owned generated binary placeholder')
        snapshot.package_resources(resources, package, {'files': expected}, {'executable'})
        snapshot.verify_package(package, {'files': expected}, {'executable'})
        (package / 'dm/simulator-metadata-profile.json').write_bytes(b'corrupt descriptor')
        with self.assertRaises(ValueError): snapshot.verify_package(package, {'files': expected}, {'executable'})
        constants = profile_inputs.constants(result['chain'], result)
        self.assertIn('#define DM_SIMULATOR_PROFILE_ACTIVATED 0', constants)
        self.assertNotIn('#define DM_NVN_SIMULATOR ', constants)
        self.assertIn(descriptor['provenance_id'], constants)

    def test_admission_rejects_wrong_interpreter_extra_descriptor_and_source_drift(self):
        self.fixture.produce()
        source, proof = self.source()
        extra = self.fixture.out / 'extra'
        extra.write_bytes(b'unbound')
        with self.assertRaises(ValueError): self.admit(source, name='extra-admission')
        extra.unlink()
        with self.assertRaisesRegex(ValueError, 'interpreter'):
            profile_inputs.admit(source, self.fixture.cache, self.fixture.qualification, self.fixture.source,
                self.fixture.derived, self.fixture.out,
                profile_inputs.identity(self.fixture.out / 'metadata-profile.json')['sha256'],
                Path('/usr/bin/python3'), self.root / 'bad-python', Path('/Applications/Xcode.app/Contents/Developer'),
                lambda argv, cwd: self.fail('wrong interpreter must fail before execution'))
        def mutate(argv, cwd):
            subprocess.run([str(value) for value in argv], cwd=cwd, check=True)
            path = source / profile_inputs.CLOSURE[0]
            path.chmod(0o600)
            path.write_bytes(path.read_bytes() + b'\n# changed primary frozen input\n')
        with self.assertRaisesRegex(ValueError, 'primary frozen source changed'):
            self.admit(source, execute=mutate, name='drift-admission')

    def staging(self):
        profile = self.root / 'tiny-profile'
        cache = profile / 'b-0123456789ab'
        cache.mkdir(parents=True)
        files = {}
        for suffix in ('.json', '.metallib'):
            path = cache / ('1234567890abcdef_b' + suffix)
            path.write_bytes(b'owned source bytes\n')
            files[str(path.relative_to(profile))] = profile_inputs.identity(path)
        admission = dict(chain='0123456789ab', keys=1, staged_files=files, source_profile='owned-profile',
                         metadata_sha256='a' * 64, metadata_id='b' * 64,
                         compiled=False, executed=False, renderer_qualified=False)
        return profile, admission

    def test_base_pair_bf_and_chain_staging_negatives(self):
        profile, admission = self.staging()
        for change in ('bf', 'chain', 'missing-pair', 'compiled'):
            altered = deepcopy(admission)
            if change == 'bf':
                name = next(iter(altered['staged_files']))
                value = altered['staged_files'].pop(name)
                altered['staged_files'][name.replace('_b.', '_bf.')] = value
            elif change == 'chain': altered['chain'] = 'a' * 12
            elif change == 'missing-pair': altered['staged_files'].pop(next(iter(altered['staged_files'])))
            else: altered['compiled'] = True
            with self.subTest(change=change), self.assertRaises(ValueError):
                shaders.stage_profile(profile, altered, self.root / ('invalid-' + change))

    def test_staging_late_copy_corruption_and_extra_files(self):
        profile, admission = self.staging()
        original = shaders.shutil.copyfile
        for mode in ('corrupt', 'extra'):
            destination = self.root / ('late-' + mode)
            def copy(source, target):
                result = original(source, target)
                if mode == 'corrupt': Path(target).write_bytes(b'changed staged bytes')
                else: (Path(target).parent / 'unexpected').write_bytes(b'extra')
                return result
            with self.subTest(mode=mode), mock.patch.object(shaders.shutil, 'copyfile', copy), self.assertRaises(ValueError):
                shaders.stage_profile(profile, admission, destination)

    def test_descriptor_staging_requires_pair_and_identity(self):
        self.fixture.produce()
        ids = {name: profile_inputs.identity(self.fixture.out / name) for name in profile_inputs.METADATA_FILES}
        with self.assertRaises(ValueError):
            profile_inputs.stage_metadata(self.fixture.out, ids, self.root / 'bad-dm', profile=None, profile_identity=None)
        ids['metadata-profile.json']['sha256'] = '0' * 64
        with self.assertRaises(ValueError):
            profile_inputs.stage_metadata(self.fixture.out, ids, self.root / 'bad-descriptor', profile=self.fixture.derived,
                                           profile_identity=profile_inputs.identity(self.fixture.derived / 'profile.json'))

    def test_worker_result_abi_and_copied_tool_closure_drift_rejected(self):
        self.fixture.produce()
        source, proof = self.source()
        for variant in ('abi', 'closure'):
            def corrupt(argv, cwd):
                subprocess.run([str(value) for value in argv], cwd=cwd, check=True)
                if variant == 'abi':
                    result = Path(argv[argv.index('--result') + 1])
                    data = profile_inputs.read_json(result)
                    data['native_layout_sha256'] = '0' * 64
                    result.write_bytes(profile_inputs.encoded(data))
                else:
                    (Path(cwd) / 'dm/unbound.py').write_text('unexpected copied tool')
            with self.subTest(variant=variant), self.assertRaises(ValueError):
                self.admit(source, execute=corrupt, name='corrupt-' + variant)
        snapshot.verify(source, proof, originals=True)


if __name__ == '__main__':
    unittest.main()
