"""Synthetic contracts for the source-only Simulator sampler-alias profile."""

from copy import deepcopy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/ios/tools/simulator'))
import shader_profile as profile


KEY = '1234567890abcdef'
CHAIN = '0123456789ab'
NEW_CHAIN = 'abcdef012345'


def reflection(bindings):
    return {'key': KEY + '_b', 'route': 'B', 'chain': CHAIN, 'dm_ctl': KEY,
            'source': 'synthetic.bin#0', 'pc_paired': '1111111111111111',
            'stage': 'ps', 'entry': 'main0', 'msl_entry_kind': 'fragment',
            'threadgroup_size': None, 'c1': '', 'notes': [], 'drv_reads': {},
            'drv_unfillable': [], 'bindings': bindings, 'vertex_inputs': [],
            'raster': {'discard': 0, 'sample_mask': 0, 'colors': [0]},
            'chain_metal': 'synthetic canonical source-only fixture'}


def sampler(name, aid, kind='samp', reg=0):
    return {'msl_name': name, 'msl_type': 'sampler', 'arg_id': aid, 'kind': kind, 'reg': reg}


def source(bindings, body='return float4(1);'):
    if not bindings:
        return 'fragment float4 main0() { ' + body + ' }\n'
    fields = '\n'.join(f"    {b['msl_type']} {b['msl_name']} [[id({b['arg_id']})]];" for b in bindings)
    return ('struct spvDescriptorSetBuffer0 {\n' + fields + '\n};\n'
            'fragment float4 main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]]) {\n'
            + body + '\n}\n')


class ShaderProfileTests(unittest.TestCase):
    def setUp(self):
        root = REPO / '.tmp/ios-simulator/shader-profile/tests'
        root.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=root)
        self.directory = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def transform(self, bindings, body='return float4(1);'):
        return profile.transform_shader(source(bindings, body), reflection(bindings), NEW_CHAIN)

    def cache(self, bindings=None, bf=False):
        bindings = [sampler('one', 2), sampler('two', 7)] if bindings is None else bindings
        cache = self.directory / ('b-' + CHAIN)
        cache.mkdir()
        shader = source(bindings, 'use(spvDescriptorSet0.two); return float4(1);' if bindings else 'return float4(1);')
        refl = reflection(bindings)
        if bf:
            refl['fetch'] = {'calls': [], 'mixed_regs': [], 'outputs': []}
            (cache / (KEY + '_bf.metallib')).write_text('synthetic omitted BF')
        for suffix, raw in (('.metal', shader.encode()), ('.metallib', shader.encode()), ('.json', json.dumps(refl).encode())):
            (cache / (KEY + '_b' + suffix)).write_bytes(raw)
        (cache / '_b_build.json').write_text(json.dumps([{'key': KEY, 'st': 'ok', 'err': ''}]))
        qualification = self.directory / 'input-qualification.json'
        self.qualify(cache, qualification, bf)
        return cache, qualification

    def qualify(self, cache, qualification, bf=False):
        qualification.write_text(json.dumps({'chain': CHAIN, 'keys': 1, 'kind': profile.KIND,
            'counts': {'reflection': 1, 'msl': 1, 'source_cache': 2 if bf else 1},
            'artifacts': [dict(path=cache.name + '/' + p.name, **profile._identity(p)) for p in sorted(cache.iterdir())]}))

    def derive(self, cache, qualification, name='derived'):
        return profile.derive_cache(cache, qualification, self.directory / name, [KEY], capabilities=profile.CAPABILITIES)

    def test_exact_aliases_dense_ids_and_metadata(self):
        bindings = [sampler('one', 2), sampler('two', 9), sampler('three', 16, 'samp_tex'), sampler('four', 23, reg=1)]
        original = reflection(bindings)
        original['fetch'] = {'calls': [], 'mixed_regs': [], 'outputs': []}
        text = source(bindings, 'use(spvDescriptorSet0.one, spvDescriptorSet0.two, spvDescriptorSet0.three, spvDescriptorSet0.four); return float4(1);')
        untouched = deepcopy(original)
        result = profile.transform_shader(text, original, NEW_CHAIN)
        self.assertEqual(original, untouched)
        self.assertEqual([b['msl_name'] for b in result['reflection']['bindings']], ['one', 'three', 'four'])
        self.assertEqual([b['arg_id'] for b in result['reflection']['bindings']], [0, 1, 2])
        self.assertIn('use(spvDescriptorSet0.one, spvDescriptorSet0.one, spvDescriptorSet0.three, spvDescriptorSet0.four)', result['source'])
        self.assertNotIn('sampler two', result['source'])
        self.assertNotIn('fetch', result['reflection'])
        self.assertEqual(result['reflection']['chain'], NEW_CHAIN)
        self.assertIn('execution not performed', result['reflection']['chain_metal'])
        self.assertEqual(result['proof']['aliases'], 1)
        self.assertEqual(result['proof']['bindings'][1]['output_name'], 'one')
        self.assertEqual(result['proof']['bindings'][1]['source'], {'reg': 0})

    def test_comments_strings_and_token_boundaries(self):
        bindings = [sampler('one', 2), sampler('two', 7)]
        result = self.transform(bindings, '// spvDescriptorSet0.two\nconst char* text = "spvDescriptorSet0.two";\nint two_suffix = 0; /* two */\nuse(spvDescriptorSet0 /* gap */ . two); return float4(two_suffix);')
        self.assertIn('// spvDescriptorSet0.two', result['source'])
        self.assertIn('"spvDescriptorSet0.two"', result['source'])
        self.assertIn('two_suffix', result['source'])
        self.assertIn('/* two */', result['source'])
        self.assertIn('spvDescriptorSet0 /* gap */ . one', result['source'])

    def test_reject_raw_strings_and_line_splicing(self):
        bindings = [sampler('one', 2), sampler('two', 7)]
        for body in ['auto text = R"tag(a " spvDescriptorSet0.two)tag";',
                     '// continued comment ' + chr(92) + '\nuse(spvDescriptorSet0.two);']:
            with self.subTest(body=body), self.assertRaises(ValueError):
                self.transform(bindings, body)

    def test_reject_shadow_escape_or_other_member(self):
        bindings = [sampler('one', 2), sampler('two', 7)]
        for body in ['sampler two; use(spvDescriptorSet0.two);',
                     'Other spvDescriptorSet0; use(spvDescriptorSet0.two);',
                     'use(spvDescriptorSet0);', 'use(other.two);',
                     'use(spvDescriptorSet0.missing);']:
            with self.subTest(body=body), self.assertRaises(ValueError):
                self.transform(bindings, body)

    def test_reject_conflicting_or_unknown_metadata(self):
        bindings = [sampler('one', 2), sampler('two', 7)]
        for change in [('arg_id', 2), ('msl_name', 'one'), ('msl_type', 'texture2d<float>'), ('reg', None), ('future_id', 7)]:
            refl = reflection(deepcopy(bindings))
            refl['bindings'][1][change[0]] = change[1]
            with self.subTest(change=change), self.assertRaises(ValueError):
                profile.transform_shader(source(bindings), refl, NEW_CHAIN)
        refl = reflection(bindings)
        refl['future_metadata'] = {}
        with self.assertRaises(ValueError):
            profile.transform_shader(source(bindings), refl, NEW_CHAIN)

    def test_unsupported_generated_shapes_and_inconsistent_source(self):
        bindings = [sampler('one', 2), sampler('two', 7)]
        raw = source(bindings)
        for text in [raw.replace('id(7)', 'id(8)'), raw.replace('sampler two', 'sampler two[2]'),
                     raw.replace('constant spvDescriptorSetBuffer0&', 'device spvDescriptorSetBuffer0&'),
                     raw + '/* unterminated', raw + 'struct spvDescriptorSetBuffer1 {};']:
            with self.subTest(text=text), self.assertRaises(ValueError):
                profile.transform_shader(text, reflection(bindings), NEW_CHAIN)

    def test_untouched_resource_helper_names_are_preserved(self):
        bindings = [{'msl_name': 'support_buffer', 'msl_type': 'constant uint*', 'arg_id': 0, 'kind': 'support'},
                    sampler('one', 2), sampler('two', 7)]
        helper = 'float helper(constant uint& support_buffer) { return float(support_buffer); }\n'
        raw = helper + source(bindings, 'use(spvDescriptorSet0.two); return float4(1);')
        result = profile.transform_shader(raw, reflection(bindings), NEW_CHAIN)
        self.assertTrue(result['source'].startswith(helper))
        self.assertEqual(result['reflection']['bindings'][0], bindings[0])

    def test_nested_unknown_metadata_and_declaration_order(self):
        bindings = [sampler('one', 2), sampler('two', 7)]
        for field, value in [('raster', {'unknown_binding_id': 7}),
                             ('vertex_inputs', [{'location': 0, 'msl_type': 'float4', 'arg_id': 7}]),
                             ('drv_reads', {'2': {'vec4_offsets': [], 'dynamic': False, 'name': 'two'}}),
                             ('fetch', {'calls': [], 'mixed_regs': [], 'outputs': [], 'arg_id': 7})]:
            refl = reflection(bindings)
            refl[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                profile.transform_shader(source(bindings), refl, NEW_CHAIN)
        with self.assertRaisesRegex(ValueError, 'declaration order'):
            profile.transform_shader(source(bindings), reflection(list(reversed(bindings))), NEW_CHAIN)

    def test_crlf_source_bytes_are_preserved(self):
        raw = source([], 'return float4(7);').replace('\n', '\r\n')
        self.assertEqual(profile.transform_shader(raw, reflection([]), NEW_CHAIN)['source'], raw)

    def test_empty_bindings_preserve_computation(self):
        raw = source([], 'return float4(7);')
        result = profile.transform_shader(raw, reflection([]), NEW_CHAIN)
        self.assertEqual(result['source'], raw)
        self.assertEqual(result['proof']['bindings_after'], 0)
        with self.assertRaises(ValueError):
            profile.transform_shader('', reflection([]), NEW_CHAIN)

    def test_caps_and_distinct_sources(self):
        bindings = [sampler('s' + str(i), i, reg=i) for i in range(17)]
        with self.assertRaisesRegex(ValueError, 'resource caps'):
            self.transform(bindings)
        bindings = [{'msl_name': 't' + str(i), 'msl_type': 'texture2d<float>', 'arg_id': i, 'kind': 'tex', 'reg': i} for i in range(65)]
        with self.assertRaisesRegex(ValueError, 'resource caps'):
            self.transform(bindings)
        bindings = [sampler('one', 2), sampler('two', 7, 'samp_tex'), sampler('three', 9, reg=1)]
        self.assertEqual(self.transform(bindings)['proof']['aliases'], 0)

    def test_reproducible_distinct_chain_and_no_bf(self):
        cache, qualification = self.cache(bf=True)
        before = {p.name: p.read_bytes() for p in cache.iterdir()}
        first = self.derive(cache, qualification)
        second = self.derive(cache, qualification, 'again')
        self.assertEqual(first, second)
        self.assertNotEqual(first['chain'], CHAIN)
        self.assertEqual(first['keys'], 1)
        self.assertEqual(first['variants'], 0)
        self.assertFalse(first['compiled'])
        self.assertFalse(first['renderer_qualified'])
        self.assertFalse(any('_bf.' in name for name in first['artifacts']))
        self.assertEqual(before, {p.name: p.read_bytes() for p in cache.iterdir()})
        with self.assertRaises(FileExistsError):
            self.derive(cache, qualification)

    def test_duplicate_missing_incomplete_keys_and_changed_bytes(self):
        cache, qualification = self.cache()
        for rows in [[], [{'key': KEY, 'st': 'error', 'err': 'synthetic'}],
                     [{'key': KEY, 'st': 'ok', 'err': ''}] * 2,
                     [{'key': '1111111111111111', 'st': 'ok', 'err': ''}]]:
            (cache / '_b_build.json').write_text(json.dumps(rows))
            self.qualify(cache, qualification)
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                self.derive(cache, qualification)
        (cache / '_b_build.json').write_text(json.dumps([{'key': KEY, 'st': 'ok', 'err': ''}]))
        self.qualify(cache, qualification)
        (cache / (KEY + '_b.metal')).write_text('changed')
        with self.assertRaisesRegex(ValueError, 'identity mismatch'):
            self.derive(cache, qualification)
        self.assertFalse((self.directory / 'derived').exists())

    def test_empty_and_nonidentical_base_source(self):
        cache, qualification = self.cache()
        for raw in [b'', b'MTLBsynthetic', b'fragment changed']:
            (cache / (KEY + '_b.metal')).write_bytes(raw)
            if not raw:
                (cache / (KEY + '_b.metallib')).write_bytes(raw)
            self.qualify(cache, qualification)
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                self.derive(cache, qualification)

    def test_changed_input_during_derivation_cleans_exclusive_output(self):
        cache, qualification = self.cache()
        transform = profile.transform_shader
        def mutate(*args):
            result = transform(*args)
            (cache / (KEY + '_b.metal')).write_text('changed mid-derivation')
            return result
        with mock.patch.object(profile, 'transform_shader', mutate), self.assertRaises(ValueError):
            self.derive(cache, qualification)
        self.assertFalse((self.directory / 'derived').exists())

    def test_output_drift_and_extra_artifacts(self):
        cache, qualification = self.cache()
        result = self.derive(cache, qualification)
        root = self.directory / 'derived'
        output = root / ('b-' + result['chain']) / (KEY + '_b.metallib')
        output.write_text('drift')
        with self.assertRaisesRegex(ValueError, 'identity drift'):
            profile.validate_derived(root)
        (root / 'unexpected').write_text('extra')
        with self.assertRaisesRegex(ValueError, 'artifact set drift'):
            profile.validate_derived(root)

    def test_output_validation_failure_cleans_output(self):
        cache, qualification = self.cache()
        validate = profile._validate_profile
        def mutate(path, value, **options):
            self.assertFalse((path / 'profile.json').exists())
            (path / 'unexpected').write_text('extra')
            return validate(path, value, **options)
        with mock.patch.object(profile, '_validate_profile', mutate), self.assertRaises(ValueError):
            self.derive(cache, qualification)
        self.assertFalse((self.directory / 'derived').exists())

    def test_duplicate_json_fields_and_input_symlinks(self):
        with self.assertRaisesRegex(ValueError, 'duplicate JSON'):
            profile._read_json('{"key":1,"key":2}')
        cache, qualification = self.cache()
        original = cache / (KEY + '_b.metal')
        outside = self.directory / 'original.metal'
        original.rename(outside)
        original.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'non-symlink'):
            self.derive(cache, qualification)

    def rewrite_artifact(self, root, name, raw):
        path = root / name
        path.write_bytes(raw)
        value = json.loads((root / 'profile.json').read_bytes())
        value['artifacts'][name] = profile._identity(path)
        (root / 'profile.json').write_bytes(profile._json(value))

    def test_exact_profile_claims_and_corpus_negatives(self):
        cache, qualification = self.cache()
        self.derive(cache, qualification)
        root = self.directory / 'derived'
        path = root / 'profile.json'
        original = json.loads(path.read_bytes())
        cases = [('keys', 0, 'key count'), ('renderer_qualified', True, 'source-only'),
                 ('compiled', True, 'source-only'), ('variants', False, 'base-only'),
                 ('unknown_metadata', {}, 'profile.*fields'),
                 ('corpus', dict(original['corpus'], aliases_removed=123), 'corpus summary'),
                 ('corpus', dict(original['corpus'], stages={'ps': 0}), 'corpus summary'),
                 ('corpus', dict(original['corpus'], unknown=1), 'corpus summary'),
                 ('metadata_requirements', [], 'base-only')]
        for field, value, message in cases:
            modified = deepcopy(original)
            modified[field] = value
            path.write_bytes(profile._json(modified))
            with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, message):
                profile.validate_derived(root)
        path.write_bytes(profile._json(original))
        self.assertEqual(profile.validate_derived(root), original)

    def test_malformed_missing_extra_or_false_alias_records_with_refreshed_digest(self):
        cache, qualification = self.cache()
        self.derive(cache, qualification)
        root = self.directory / 'derived'
        path = root / 'alias-proof.jsonl'
        original = path.read_bytes()
        record = json.loads(original)
        records = [b'{}\n', b'\n', original + original,
                   profile._json(dict(record, key='1111111111111111')),
                   profile._json(dict(record, aliases=0)),
                   profile._json(dict(record, bindings_after=0)),
                   profile._json(dict(record, unknown_id=7)),
                   profile._json(dict(record, input_source_sha256='0' * 64))]
        wrong_alias = deepcopy(record)
        wrong_alias['bindings'][1]['output_name'] = 'two'
        records.append(profile._json(wrong_alias))
        wrong_source = deepcopy(record)
        wrong_source['bindings'][1]['source']['reg'] = 1
        records.append(profile._json(wrong_source))
        wrong_metadata = deepcopy(record)
        wrong_metadata['input_metadata']['chain_metal'] = 'altered input metadata'
        records.append(profile._json(wrong_metadata))
        for raw in records:
            self.rewrite_artifact(root, 'alias-proof.jsonl', raw)
            with self.subTest(raw=raw[:80]), self.assertRaises(ValueError):
                profile.validate_derived(root)
        self.rewrite_artifact(root, 'alias-proof.jsonl', original)
        profile.validate_derived(root)

    def test_provenance_options_code_and_input_semantics_are_bound(self):
        cache, qualification = self.cache()
        self.derive(cache, qualification)
        root = self.directory / 'derived'
        path = root / 'profile.json'
        original = json.loads(path.read_bytes())
        changes = [lambda p: p['provenance']['options'].update(base_only=False),
                   lambda p: p['provenance'].update(transform_sha256='0' * 64),
                   lambda p: p['provenance']['input']['reflection_semantics'].update({KEY: '0' * 64}),
                   lambda p: p['provenance']['input'].update(keys=[]),
                   lambda p: p['provenance']['input'].update(unknown={}),
                   lambda p: p['provenance'].update(unknown={})]
        for change in changes:
            value = deepcopy(original)
            change(value)
            path.write_bytes(profile._json(value))
            with self.subTest(change=change), self.assertRaises(ValueError):
                profile.validate_derived(root)
        path.write_bytes(profile._json(original))
        profile.validate_derived(root, cache=cache, qualification=qualification, expected_keys=[KEY])
        with self.assertRaisesRegex(ValueError, 'requires cache'):
            profile.validate_derived(root, cache=cache)
        original_source = cache / (KEY + '_b.metal')
        original_source.write_text('canonical changed')
        with self.assertRaises(ValueError):
            profile.validate_derived(root, cache=cache, qualification=qualification, expected_keys=[KEY])

    def test_full_replay_rejects_computation_drift_even_with_self_hashes_refreshed(self):
        cache, qualification = self.cache()
        value = self.derive(cache, qualification)
        root = self.directory / 'derived'
        prefix = 'b-' + value['chain'] + '/'
        changed = (root / (prefix + KEY + '_b.metal')).read_bytes().replace(b'float4(1)', b'float4(9)')
        for suffix in ('.metal', '.metallib'):
            self.rewrite_artifact(root, prefix + KEY + '_b' + suffix, changed)
        proof = json.loads((root / 'alias-proof.jsonl').read_bytes())
        proof['output_source_sha256'] = profile._digest(changed)
        self.rewrite_artifact(root, 'alias-proof.jsonl', profile._json(proof))
        with self.assertRaisesRegex(ValueError, 'transformation replay mismatch'):
            profile.validate_derived(root, cache=cache, qualification=qualification, expected_keys=[KEY])

    def test_generated_directives_and_conditional_contexts_are_rejected(self):
        bindings = [sampler('one', 2), sampler('two', 7)]
        raw = source(bindings, 'use(spvDescriptorSet0.two); return float4(1);')
        directives = ['#define one nonexistent_member', '#define two one', '#undef spvDescriptorSet0',
                      '#if 1', '#ifdef one', '#ifndef one', '#elif 1', '#else', '#endif',
                      '#include "untrusted.h"', '#pragma pack(1)', '%:define one missing']
        for directive in directives:
            for offset in (0, raw.index('fragment')):
                modified = raw[:offset] + directive + '\n' + raw[offset:]
                with self.subTest(directive=directive, offset=offset), self.assertRaises(ValueError):
                    profile.transform_shader(modified, reflection(bindings), NEW_CHAIN)
        for directive in profile.DIRECTIVES:
            checked = profile.transform_shader(directive + '\n' + raw, reflection(bindings), NEW_CHAIN)
            self.assertTrue(checked['source'].startswith(directive + '\n'))
        with self.assertRaisesRegex(ValueError, 'directive/context'):
            profile.transform_shader(raw.replace('fragment', '#include <metal_stdlib>\nfragment'), reflection(bindings), NEW_CHAIN)

    def test_nested_scalar_and_range_corruptions(self):
        bindings = [sampler('one', 2), sampler('two', 7)]
        fragment = reflection(bindings)
        vertex = deepcopy(fragment)
        vertex.update(stage='vs', msl_entry_kind='vertex', vertex_inputs=[{'location': 0, 'msl_type': 'float4'}],
                      raster={'pos_attr': 0, 'pos_w': 'one', 'uv_from_attr': {'0': 0},
                              'uv_affine': {'0': {'attr': 0, 'sx': [0, 0, 0], 'ox': [0, 0, 0], 'sy': [0, 0, 0], 'oy': [0, 0, 0]}}})
        cases = []
        for bad in ({'arg_id': 7}, -1, 32, True):
            value = deepcopy(vertex)
            value['vertex_inputs'][0]['location'] = bad
            cases.append(value)
        for bad in ({'arg_id': 7}, -1, 16, True):
            value = deepcopy(vertex)
            value['raster']['uv_from_attr']['0'] = bad
            cases.append(value)
        for bad in ({'arg_id': 7}, -2, 16, True):
            value = deepcopy(vertex)
            value['raster']['pos_attr'] = bad
            cases.append(value)
        for bad in ({'arg_id': 7}, -1, 2, True):
            for field in ('discard', 'sample_mask'):
                value = deepcopy(fragment)
                value['raster'][field] = bad
                cases.append(value)
        for bad in ([{}], [-1], [8], [True], [0, 0]):
            value = deepcopy(fragment)
            value['raster']['colors'] = bad
            cases.append(value)
        for bad in ({}, [0, 0], [16, 0, 0], [0, 64, 0], [0, 0, 4], [False, 0, 0], [0, {}, 0]):
            value = deepcopy(vertex)
            value['raster']['uv_affine']['0']['sx'] = bad
            cases.append(value)
        for bad in ({'arg_id': 7}, -1, 1, True):
            value = deepcopy(fragment)
            value['drv_reads'] = {'2': {'vec4_offsets': [bad], 'dynamic': False}}
            cases.append(value)
        for bad in ({'arg_id': 7}, -1, 32, True):
            value = deepcopy(fragment)
            value['fetch'] = {'calls': [{'fc': bad, 'tex_reg': 0, 'varying_locn': 0}], 'mixed_regs': [], 'outputs': []}
            cases.append(value)
        for value in cases:
            raw = source(bindings).replace('fragment', value['msl_entry_kind'])
            with self.subTest(value=value), self.assertRaises(ValueError):
                profile.transform_shader(raw, value, NEW_CHAIN)
        raw = source(bindings).replace('fragment', 'vertex')
        profile.transform_shader(raw, vertex, NEW_CHAIN)

    def test_explicit_caps_and_output_location(self):
        cache, qualification = self.cache()
        with self.assertRaises(ValueError):
            profile.derive_cache(cache, qualification, self.directory / 'derived', [KEY], capabilities={})
        with self.assertRaises(ValueError):
            profile.derive_cache(cache, qualification, REPO / 'outside-tmp', [KEY], capabilities=profile.CAPABILITIES)
        with self.assertRaises(ValueError):
            profile.derive_cache(cache, qualification, self.directory / 'derived', [KEY, KEY], capabilities=profile.CAPABILITIES)


if __name__ == '__main__':
    unittest.main()
