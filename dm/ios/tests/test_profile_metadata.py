"""Owned native fixtures and source-only metadata production/replay contracts."""

from copy import deepcopy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/ios/tools/simulator'))
import profile_metadata as metadata
import shader_profile
from pso_toolchain import NativeCodec, encoded, identity
import pso_toolchain


KEYS = {stage: f'{number:016x}' for number, stage in enumerate(('vs', 'ps', 'cs', 'hs', 'ds'), 1)}
CHAIN = '0123456789ab'
FIXTURE = r'''
#include <stdio.h>
#include "nvn_pso_wire.h"
int main(int argc, char **argv) {
    if(argc!=2)return 2;
    pso_skey k={0}; memcpy(k.vs,"0000000000000001_b",19);
    memcpy(k.fs,"0000000000000002_b",19); k.fs_stage=1;
    if(!strcmp(argv[1],"ordinary")){}
    else if(!strcmp(argv[1],"depth")){memset(k.fs,0,sizeof k.fs);k.fs_stage=0;}
    else if(!strcmp(argv[1],"merged")){k.merged=1;k.fz_desc.kind=2;}
    else if(!strcmp(argv[1],"specialized")){k.fz=1;memset(&k.fz_desc,0xff,sizeof k.fz_desc);}
    else if(!strcmp(argv[1],"both")){k.merged=k.fz=1;k.fz_desc.kind=2;}
    else if(!strcmp(argv[1],"bf"))memcpy(k.fs,"0000000000000002_bf",20);
    else if(!strcmp(argv[1],"pointer"))k.k.vs=(void*)1;
    else if(!strcmp(argv[1],"stage"))k.vs_stage=1;
    else return 2;
    char hex[sizeof k*2+1];pso_skey_hex(&k,hex);puts(hex);return 0;
}
'''


class ProfileMetadataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        parent = REPO / '.tmp/ios-simulator/metadata-producer/tests'
        parent.mkdir(parents=True, exist_ok=True)
        cls.temporary = tempfile.TemporaryDirectory(dir=parent)
        cls.root = Path(cls.temporary.name)
        fixture = cls.root / 'fixture.c'
        fixture.write_text(FIXTURE)
        binary = cls.root / 'fixture'
        subprocess.run(['clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                        '-I', str(REPO / 'dm/gfx/nvn'), '-I', str(REPO / 'dm/gfx/nvn/include'),
                        str(fixture), '-o', str(binary)], check=True)
        cls.hex = {name: subprocess.check_output([str(binary), name], text=True).strip()
                   for name in ('ordinary', 'depth', 'merged', 'specialized', 'both', 'bf', 'pointer', 'stage')}
        cls.codec = NativeCodec(cls.root / 'codec', Path('/Applications/Xcode.app/Contents/Developer'))

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def setUp(self):
        self.case = tempfile.TemporaryDirectory(dir=self.root)
        self.directory = Path(self.case.name)
        self.cache = self.directory / ('b-' + CHAIN)
        self.cache.mkdir()
        for stage, key in KEYS.items():
            kind = {'vs': 'vertex', 'ps': 'fragment', 'cs': 'kernel', 'hs': 'kernel', 'ds': 'vertex'}[stage]
            source = kind + ' float4 main0() { return float4(1); }\n'
            reflection = {'key': key + '_b', 'route': 'B', 'chain': CHAIN, 'dm_ctl': key,
                          'source': 'owned-synthetic.bin#0', 'pc_paired': '1111111111111111',
                          'stage': stage, 'entry': 'main0', 'msl_entry_kind': kind,
                          'threadgroup_size': [1, 1, 1] if stage == 'cs' else None,
                          'c1': '', 'notes': [], 'drv_reads': {}, 'drv_unfillable': [], 'bindings': [],
                          'vertex_inputs': [], 'raster': {'discard': 0, 'sample_mask': 0, 'colors': [0]}
                          if stage == 'ps' else {'pos_attr': -1} if stage == 'vs' else {},
                          'chain_metal': 'owned synthetic source-only fixture'}
            if stage == 'ps':
                reflection['fetch'] = {'calls': [], 'mixed_regs': [], 'outputs': []}
                (self.cache / (key + '_bf.metallib')).write_text('owned canonical variant declaration\n')
            for suffix, raw in (('.metal', source.encode()), ('.metallib', source.encode()), ('.json', encoded(reflection))):
                (self.cache / (key + '_b' + suffix)).write_bytes(raw)
        (self.cache / '_b_build.json').write_bytes(encoded([{'key': k, 'st': 'ok', 'err': ''} for k in KEYS.values()]))
        self.qualification = self.directory / 'qualification.json'
        self.qualification.write_bytes(encoded({'chain': CHAIN, 'keys': 5, 'kind': shader_profile.KIND,
            'counts': {'reflection': 5, 'msl': 5, 'source_cache': 6},
            'artifacts': [dict(path=self.cache.name + '/' + p.name, **identity(p)) for p in sorted(self.cache.iterdir())]}))
        self.derived = self.directory / 'derived'
        shader_profile.derive_cache(self.cache, self.qualification, self.derived, KEYS.values(),
                                    capabilities=shader_profile.CAPABILITIES)
        self.source = self.directory / 'metadata'
        self.source.mkdir()
        labels = metadata.stage_contract()['labels']
        by_number = {number: name for name, number in labels.items()}
        rows = [metadata.MAP_HEADER]
        for stage, key in KEYS.items():
            rows.append('\t'.join(['owned.bin', '0', by_number[metadata.STAGES[stage]], key,
                                   '1111111111111111', '1', '-1', '-1', '-', '-', '-', '-', '15']))
        (self.source / 'shader_map.tsv').write_text('\n'.join(rows) + '\n')
        subprocess.run([sys.executable, str(REPO / 'dm/gfx/tools/c1_guard.py'), str(self.cache),
                        str(self.source / 'c1_full.tsv')], capture_output=True, check=True)
        self.bodies = ['C\t' + KEYS['cs'] + '_b', 'R\t' + self.hex['merged'],
                       'S\t' + KEYS['ps'] + '_b\t1', 'R\t' + self.hex['ordinary'],
                       'C\t', 'R\t' + self.hex['both'], 'S\t' + KEYS['ps'] + '_bf\t1',
                       'R\t' + self.hex['depth'], 'R\t' + self.hex['specialized'],
                       'R\t' + self.hex['bf'], 'S\t' + KEYS['hs'] + '_b\t3',
                       'S\t' + KEYS['ds'] + '_b\t4']
        (self.source / 'pso_manifest.tsv').write_text('# source fixture\n' + '\n'.join(self.bodies) + '\n')
        self.out = self.directory / 'output'
        self.counter = 0

    def tearDown(self):
        self.case.cleanup()

    def work(self):
        self.counter += 1
        return self.directory / ('work-' + str(self.counter))

    def produce(self):
        return metadata.produce_metadata(self.cache, self.qualification, self.derived, self.source,
                                          self.out, work=self.work())

    def validate(self):
        return metadata.validate_metadata(self.out, self.cache, self.qualification, self.derived, self.source,
            expected_descriptor_sha256=identity(self.out / 'metadata-profile.json')['sha256'], work=self.work())

    def save(self, descriptor):
        (self.out / 'metadata-profile.json').write_bytes(encoded(descriptor))

    def test_real_production_native_order_and_timestamp_honesty(self):
        original = {p.name: identity(p) for p in self.source.iterdir()}
        result = self.produce()
        expected = [self.bodies[n] for n in (0, 2, 3, 7, 10, 11)]
        actual = [line for line in (self.out / 'pso_manifest.tsv').read_text().splitlines() if not line.startswith('#')]
        self.assertEqual(actual, expected)
        self.assertEqual(result['summary']['source'], {'S': 4, 'R': 6, 'C': 2})
        self.assertEqual(result['summary']['retained'], {'S': 3, 'R': 2, 'C': 1})
        self.assertEqual([row['reasons'] for row in result['ledger']], [[], ['merged'], [], [], ['empty_compute'],
                         ['merged', 'specialized'], ['framebuffer_fetch'], [], ['specialized'],
                         ['framebuffer_fetch'], [], []])
        self.assertEqual(self.validate(), result)
        self.assertEqual({p.name: identity(p) for p in self.source.iterdir()}, original)
        self.assertEqual((self.out / 'c1_full.tsv').read_bytes(), (self.directory / 'work-1/derived-c1.tsv').read_bytes())
        self.assertFalse(result['native_execution']['historical_binary_reproducibility_claimed'])
        self.assertEqual(set(p.name for p in self.out.iterdir()), metadata.FILES)

    def test_map_and_source_seed_failures(self):
        expected = metadata.shader_map((self.source / 'shader_map.tsv').read_bytes(), metadata.stage_contract()['labels'])
        refs = {key: metadata.read_json(self.cache / (key + '_b.json')) for key in KEYS.values()}
        for body in ('Z\tx', 'C', 'S\t' + KEYS['ps'] + '_b\t01', 'C\t' + KEYS['ps'] + '_b',
                     'S\t000000000000ffff_b\t1', 'R\t' + self.hex['pointer'], 'R\t' + self.hex['stage'],
                     'R\t0', 'C\t\t', 'S\t' + KEYS['vs'] + '_bf\t0'):
            with self.subTest(body=body[:30]), self.assertRaises((ValueError, subprocess.CalledProcessError)):
                metadata.seed_records(body.encode(), expected, refs, self.codec)
        no_variant = deepcopy(refs)
        del no_variant[KEYS['ps']]['fetch']
        with self.assertRaises(ValueError):
            metadata.seed_records(('R\t' + self.hex['bf']).encode(), expected, no_variant, self.codec)
        raw = (self.source / 'shader_map.tsv').read_bytes()
        for changed in (raw.replace(b'package\tindex', b'wrong\tindex'), raw + b'incomplete\n',
                        raw.replace(KEYS['ps'].encode(), KEYS['vs'].encode()), raw.replace(b'owned.bin', b'owned\0.bin')):
            with self.subTest(map=changed[:20]), self.assertRaises(ValueError):
                metadata.shader_map(changed, metadata.stage_contract()['labels'])

    def test_closed_schema_ledger_counters_and_provenance_mutations(self):
        original = self.produce()
        changes = []
        for field in ('compiled', 'executed', 'renderer_qualified'):
            value = deepcopy(original); value[field] = True; changes.append(value)
        value = deepcopy(original); value['extra'] = 1; changes.append(value)
        value = deepcopy(original); value['native_execution']['extra'] = 1; changes.append(value)
        value = deepcopy(original); value['ledger'][0]['reasons'] = ['merged']; changes.append(value)
        value = deepcopy(original); value['ledger'].reverse(); changes.append(value)
        value = deepcopy(original); value['summary']['retained']['C'] = 999; changes.append(value)
        value = deepcopy(original); value['provenance']['native']['native_layout']['types']['pso_key']['size'] += 8
        value['provenance_id'] = metadata.digest(value['provenance']); changes.append(value)
        value = deepcopy(original); value['provenance']['future'] = True
        value['provenance_id'] = metadata.digest(value['provenance']); changes.append(value)
        for value in changes:
            self.save(value)
            with self.subTest(fields=set(value)), self.assertRaises(ValueError):
                self.validate()
        self.save(original)
        raw = (self.out / 'metadata-profile.json').read_bytes()
        (self.out / 'metadata-profile.json').write_bytes(raw[:-2] + b',"compiled":false}\n')
        with self.assertRaisesRegex(ValueError, 'duplicate JSON field'):
            self.validate()

    def test_output_identity_artifact_set_and_bad_c1_header(self):
        original = self.produce()
        with self.assertRaisesRegex(ValueError, 'descriptor identity'):
            metadata.validate_metadata(self.out, self.cache, self.qualification, self.derived, self.source,
                expected_descriptor_sha256='0' * 64, work=self.work())
        for name in ('shader_map.tsv', 'pso_manifest.tsv', 'c1_full.tsv'):
            path = self.out / name; raw = path.read_bytes(); path.write_bytes(raw + b'mutated\n')
            with self.subTest(name=name), self.assertRaises(ValueError): self.validate()
            path.write_bytes(raw)
        extra = self.out / 'extra'; extra.write_text('unexpected')
        with self.assertRaises(ValueError): self.validate()
        extra.unlink()
        path = self.out / 'c1_full.tsv'; raw = path.read_bytes(); path.write_text('# chain b-bad not-a-timestamp\n')
        changed = deepcopy(original); changed['artifacts']['c1_full.tsv'] = identity(path)
        changed['c1_execution']['derived_output'] = identity(path); self.save(changed)
        with self.assertRaises(ValueError): self.validate()
        path.write_bytes(raw); self.save(original)
        target = self.out / 'shader_map.tsv'; raw = target.read_bytes(); target.unlink()
        source = self.directory / 'linked-map'; source.write_bytes(raw); target.symlink_to(source)
        with self.assertRaises(ValueError): self.validate()

    def test_source_qualification_profile_and_c1_drift(self):
        self.produce()
        for path in (self.qualification, self.derived / 'profile.json', self.source / 'pso_manifest.tsv',
                     self.source / 'c1_full.tsv'):
            raw = path.read_bytes(); path.write_bytes(raw + b'changed')
            with self.subTest(path=path.name), self.assertRaises((ValueError, json.JSONDecodeError)):
                self.validate()
            path.write_bytes(raw)

    def test_fresh_paths_overlap_and_symlink_rejected(self):
        self.produce()
        with self.assertRaisesRegex(ValueError, 'must be fresh'): self.produce()
        for destination in (self.source / 'child', self.directory, self.derived / 'child'):
            with self.subTest(path=destination), self.assertRaises(ValueError):
                metadata.produce_metadata(self.cache, self.qualification, self.derived, self.source,
                                          destination, work=self.work())
        alias = self.directory / 'alias'; alias.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(ValueError):
            metadata.produce_metadata(self.cache, self.qualification, self.derived, alias,
                                      self.directory / 'new', work=self.work())

    def test_frozen_native_source_and_ordered_c1_guards_reject_drift(self):
        source = self.codec.work / 'source/dm/ios/tools/simulator/pso_codec.c'
        raw = source.read_bytes()
        source.chmod(0o600)
        try:
            source.write_bytes(raw + b'\n/* changed frozen source */\n')
            with self.assertRaisesRegex(ValueError, 'source changed'):
                self.codec.inspect([])
        finally:
            source.write_bytes(raw)
            source.chmod(0o444)
        self.assertEqual(self.codec.inspect([])['records'], [])
        header = (self.source / 'c1_full.tsv').read_text().split('\n')[0] + '\n'
        for rows in ([KEYS['vs'], KEYS['vs']], [KEYS['ps'], KEYS['vs']], ['9999999999999999'], ['bad']):
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                metadata.parse_c1((header + '\n'.join(rows) + '\n').encode(), CHAIN, set(KEYS.values()))

    def copy_production_sources(self, name):
        root = self.directory / name
        for item in set(metadata.PRODUCERS) | set(pso_toolchain.SOURCES) | {'dm/gfx/nvn/nvn_mtl.m'}:
            destination = root / item
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / item, destination)
        return root

    def test_late_publication_drift_is_rejected_without_descriptor(self):
        originals = {path: path.read_bytes() for path in self.source.iterdir()}
        shader = self.cache / (KEYS['vs'] + '_b.metallib')
        shader_bytes = shader.read_bytes()
        for variant in ('output', 'extra', 'input', 'producer', 'native', 'shader'):
            root = self.copy_production_sources('late-' + variant)
            out, work = root / '.tmp/output', root / '.tmp/work'
            check = metadata.check_shaders
            calls = 0
            def late_drift(*args):
                nonlocal calls
                result = check(*args)
                calls += 1
                if calls == 3:
                    if variant == 'output': (out / 'shader_map.tsv').write_bytes(b'late output drift\n')
                    elif variant == 'extra': (out / 'unexpected').write_bytes(b'extra')
                    elif variant == 'input': (self.source / 'c1_full.tsv').write_bytes(b'late input drift\n')
                    elif variant == 'producer':
                        path = root / 'dm/gfx/tools/c1_guard.py'
                        path.write_bytes(path.read_bytes() + b'\n# late producer drift\n')
                    elif variant == 'native':
                        path = root / 'dm/gfx/nvn/nvn_pso_wire.h'
                        path.write_bytes(path.read_bytes() + b'\n/* late native closure drift */\n')
                    else: shader.write_bytes(b'late shader input drift\n')
                return result
            try:
                with self.subTest(variant=variant), mock.patch.object(metadata, 'REPO', root), \
                        mock.patch.object(pso_toolchain, 'REPO', root), \
                        mock.patch.object(metadata, 'check_shaders', late_drift), self.assertRaises(ValueError):
                    metadata.produce_metadata(self.cache, self.qualification, self.derived, self.source,
                                              out, work=work)
                self.assertEqual(calls, 3)
                self.assertFalse((out / 'metadata-profile.json').exists())
            finally:
                for path, raw in originals.items(): path.write_bytes(raw)
                shader.write_bytes(shader_bytes)

    def test_runtime_stage_contract_ignores_unrelated_renderer_edits(self):
        root = self.copy_production_sources('stage-contract')
        path = root / 'dm/gfx/nvn/nvn_mtl.m'
        raw = path.read_bytes()
        with mock.patch.object(metadata, 'REPO', root):
            before = metadata.stage_contract()
            path.write_bytes(raw + b'\n/* unrelated renderer implementation change */\n')
            self.assertNotEqual(hashlib.sha256(raw).hexdigest(), identity(path)['sha256'])
            self.assertEqual(metadata.stage_contract(), before)
            changed = path.read_text().replace('isEqualToString:@"外壳"', 'isEqualToString:@"ChangedStage"')
            path.write_text(changed)
            self.assertNotEqual(metadata.stage_contract(), before)

    def test_late_validation_canonical_and_derived_drift_is_rejected(self):
        original = self.produce()
        for name, path in [('canonical', self.cache / (KEYS['vs'] + '_b.metallib')),
                           ('derived', self.derived / ('b-' + original['provenance']['derived_chain']) /
                            (KEYS['vs'] + '_b.metallib'))]:
            raw = path.read_bytes()
            check = metadata.check_shaders
            calls = 0
            def late_drift(*args):
                nonlocal calls
                result = check(*args)
                calls += 1
                if calls == 2:
                    path.write_bytes(b'late validation shader drift\n')
                return result
            try:
                with self.subTest(shader=name), mock.patch.object(metadata, 'check_shaders', late_drift), \
                        self.assertRaisesRegex(ValueError, 'shader artifact changed during final admission'):
                    self.validate()
                self.assertEqual(calls, 2)
            finally:
                path.write_bytes(raw)


if __name__ == '__main__':
    unittest.main()
