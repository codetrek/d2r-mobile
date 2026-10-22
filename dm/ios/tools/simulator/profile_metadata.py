"""Produce and replay source-only Simulator metadata without enabling a renderer."""

from collections import Counter
import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

import shader_profile
from pso_toolchain import NativeCodec, digest, encoded, identity


REPO = Path(__file__).resolve().parents[4]
SCHEMA = 'd2r.simulator-profile-metadata.v1'
FILES = {'shader_map.tsv', 'c1_full.tsv', 'pso_manifest.tsv', 'metadata-profile.json'}
MAP_HEADER = ('package\tindex\tstage\tdm_ctl_sha16\tpc_dxbc_sha16\tmetallib\tpc_outputs\tdm_outputs\t'
              'dm_ubo\tdm_tex\tdm_samp\tdm_ssbo\tsubset_ok(cb|t<<1|s<<2|ssbo全等<<3)')
STAGES = {'vs': 0, 'ps': 1, 'hs': 3, 'ds': 4, 'cs': 5}
KEY = re.compile(r'[0-9a-f]{16}')
SHADER_KEY = re.compile(r'([0-9a-f]{16})_(b|bf)')
SHA = re.compile(r'[0-9a-f]{64}')
PRODUCERS = ('dm/ios/tools/simulator/profile_metadata.py', 'dm/ios/tools/simulator/pso_toolchain.py',
             'dm/ios/tools/simulator/pso_native.py', 'dm/ios/tools/simulator/shader_profile.py',
             'dm/gfx/tools/c1_guard.py')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_json(path):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'duplicate JSON field: ' + key)
            result[key] = value
        return result
    def constant(value):
        raise ValueError('invalid JSON constant: ' + value)
    return json.loads(Path(path).read_bytes(), object_pairs_hook=pairs, parse_constant=constant)


def record(value, fields, label):
    require(isinstance(value, dict) and set(value) == set(fields), 'invalid ' + label + ' fields')


def file_identity(value):
    record(value, {'size', 'sha256'}, 'artifact identity')
    require(type(value['size']) is int and value['size'] >= 0 and
            isinstance(value['sha256'], str) and SHA.fullmatch(value['sha256']), 'invalid artifact identity')


def clean_path(path, *, output=False):
    path = Path(path).absolute()
    require(not any(part.is_symlink() for part in (path, *path.parents)), 'symlink path is not admitted')
    resolved = path.resolve()
    if output:
        tmp = (REPO / '.tmp').resolve()
        require(resolved.is_relative_to(tmp) and resolved != tmp, 'output must be a project .tmp child')
    return resolved


def paths(canonical_cache, qualification, derived, metadata, destination, work):
    inputs = [clean_path(p) for p in (canonical_cache, qualification, derived, metadata)]
    destination, work = (clean_path(p, output=True) for p in (destination, work))
    require(not work.exists(), 'work directory must be fresh')
    for output in (destination, work):
        for other in inputs:
            require(not output.is_relative_to(other) and not other.is_relative_to(output), 'input/output overlap')
    require(not work.is_relative_to(destination) and not destination.is_relative_to(work), 'output/work overlap')
    return (*inputs, destination, work)


def stage_contract():
    source = (REPO / 'dm/gfx/nvn/nvn_mtl.m').read_text()
    matches = list(re.finditer(r'static int stage_of\(NSString \*zh\) \{([^{}]*)\}', source))
    require(len(matches) == 1, 'runtime stage contract is ambiguous')
    body = matches[0][1]
    pattern = re.compile(r'if \(\[zh isEqualToString:@"([^"]+)"\]\) return ([0-5]);')
    rows = pattern.findall(body)
    require(pattern.sub('', body).strip() == 'return -1;' and len(rows) == 5 and
            len({label for label, _ in rows}) == 5 and {int(n) for _, n in rows} == set(STAGES.values()),
            'unsupported runtime stage contract')
    return {'body_sha256': hashlib.sha256(body.encode()).hexdigest(),
            'labels': {label: int(number) for label, number in rows}}


def shader_map(raw, labels):
    stage_by_key, header = {}, False
    for line in raw.decode('utf-8').split('\n'):
        if not line or line.startswith('#'):
            continue
        if not header:
            require(line == MAP_HEADER, 'shader map header mismatch')
            header = True
            continue
        columns = line.split('\t')
        require(len(columns) == 13 and all(value and value.isprintable() for value in columns) and columns[2] in labels,
                'invalid shader map row/columns/stage')
        key = columns[3]
        require(KEY.fullmatch(key) and int(key, 16) != 0 and
                re.fullmatch(r'0|[1-9][0-9]*', columns[1]), 'invalid shader map key/index')
        stage = labels[columns[2]]
        require(key not in stage_by_key or stage_by_key[key] == stage, 'shader map stage conflict')
        stage_by_key[key] = stage
    require(header and stage_by_key, 'empty shader map')
    return stage_by_key


def source_snapshot(metadata, qualification, derived):
    return {'metadata': {name: identity(metadata / name) for name in ('shader_map.tsv', 'pso_manifest.tsv', 'c1_full.tsv')},
            'canonical_qualification': identity(qualification), 'shader_profile': identity(derived / 'profile.json'),
            'producers': {name: identity(REPO / name) for name in PRODUCERS}, 'runtime_stages': stage_contract(),
            'python': {'executable': identity(Path(sys.executable).resolve()), 'version': sys.version}}


def check_shaders(cache, qualification, derived, expected):
    profile = shader_profile.validate_derived(derived, cache=cache, qualification=qualification,
                                              expected_keys=sorted(expected))
    require(profile['profile'] == shader_profile.PROFILE and profile['variants'] == 0,
            'unsupported derived shader profile')
    refs = {}
    for key, stage in expected.items():
        canonical = read_json(cache / (key + '_b.json'))
        reflection = read_json(derived / ('b-' + profile['chain']) / (key + '_b.json'))
        require(STAGES[canonical['stage']] == stage == STAGES[reflection['stage']],
                'map/canonical/derived stage mismatch: ' + key)
        refs[key] = canonical
    return profile, refs


def parse_c1(raw, chain, expected):
    lines = raw.decode('utf-8').split('\n')
    if lines[-1] == '':
        lines.pop()
    require(lines, 'empty C1 output')
    prefix = '# chain b-' + chain + ' '
    require(lines[0].startswith(prefix), 'C1 producer chain mismatch')
    timestamp = lines[0][len(prefix):]
    require(re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}', timestamp),
            'invalid C1 producer timestamp grammar')
    parsed = datetime.datetime.fromisoformat(timestamp)
    require(parsed.tzinfo is not None, 'C1 timestamp needs a timezone')
    keys = lines[1:]
    require(keys == sorted(set(keys)) and all(KEY.fullmatch(key) and key in expected for key in keys),
            'invalid C1 ordered guard keys')
    return keys


def generate_c1(cache, derived, metadata, profile, expected, work):
    outputs = {}
    original = REPO / 'dm/gfx/tools/c1_guard.py'
    producer_identity = identity(original)
    producer = work / 'c1_guard.py'
    producer.write_bytes(original.read_bytes())
    producer.chmod(0o444)
    require(identity(producer) == producer_identity, 'C1 producer snapshot mismatch')
    for name, directory in [('canonical', cache), ('derived', derived / ('b-' + profile['chain']))]:
        output = work / (name + '-c1.tsv')
        result = subprocess.run([sys.executable, str(producer), str(directory), str(output)],
                                capture_output=True, timeout=120, check=True)
        require(not result.stderr, 'C1 producer diagnostics')
        outputs[name] = output.read_bytes()
    require(identity(producer) == producer_identity == identity(original), 'C1 producer changed')
    canonical_chain = profile['provenance']['input']['chain']
    supplied = (metadata / 'c1_full.tsv').read_bytes()
    keys = parse_c1(outputs['canonical'], canonical_chain, expected)
    require(parse_c1(supplied, canonical_chain, expected) == keys ==
            parse_c1(outputs['derived'], profile['chain'], expected), 'C1 guard invariance failed')
    return outputs['derived'], {'producer': producer_identity, 'guard_keys': keys,
            'ordered_rows_sha256': hashlib.sha256(''.join(k + '\n' for k in keys).encode()).hexdigest()}, {
                'canonical_output': identity(work / 'canonical-c1.tsv'),
                'derived_output': identity(work / 'derived-c1.tsv')}


def seed_records(raw, expected, refs, codec):
    parsed = []
    for number, body in enumerate(raw.decode('utf-8').split('\n'), 1):
        if not body or body.startswith('#'):
            continue
        columns = body.split('\t')
        require(columns[0] in {'S', 'R', 'C'}, 'unknown seed record')
        require(len(columns) == (3 if columns[0] == 'S' else 2), 'seed record arity')
        parsed.append((number, body, columns))
    witness = codec.inspect([columns[1] for _, _, columns in parsed if columns[0] == 'R'])
    rendered = iter(witness['records'])
    output, ledger = [], []
    counts, retained = Counter(), Counter()
    def shader(key, stage):
        match = SHADER_KEY.fullmatch(key)
        require(match and match[1] in expected and expected[match[1]] == stage,
                'seed shader key/stage mismatch: ' + key)
        if match[2] == 'bf':
            require(stage == 1 and 'fetch' in refs[match[1]], 'BF key has no canonical variant declaration')
            return ['framebuffer_fetch']
        return []
    for number, body, columns in parsed:
        kind = columns[0]
        counts[kind] += 1
        reasons = []
        if kind == 'S':
            require(re.fullmatch(r'[01345]', columns[2]), 'invalid S stage')
            reasons = shader(columns[1], int(columns[2]))
        elif kind == 'C':
            reasons = shader(columns[1], 5) if columns[1] else ['empty_compute']
        else:
            row = next(rendered)
            shader(row['vs'], row['vs_stage'])
            if row['fs']:
                shader(row['fs'], row['fs_stage'])
            reasons = [name for bit, name in [(1, 'merged'), (2, 'specialized'), (4, 'framebuffer_fetch')]
                       if row['features'] & bit]
        decision = 'exclude' if reasons else 'retain'
        ledger.append({'line': number, 'kind': kind, 'body_sha256': hashlib.sha256(body.encode()).hexdigest(),
                       'decision': decision, 'reasons': reasons})
        if not reasons:
            output.append(body + '\n')
            retained[kind] += 1
    require(parsed, 'empty source seed')
    summary = {'source': {kind: counts[kind] for kind in ('S', 'R', 'C')},
               'retained': {kind: retained[kind] for kind in ('S', 'R', 'C')},
               'excluded_records': sum(row['decision'] == 'exclude' for row in ledger),
               'exclusion_features': dict(sorted(Counter(reason for row in ledger for reason in row['reasons']).items())),
               'ordered_output_body_sha256': hashlib.sha256(''.join(output).encode()).hexdigest()}
    return ''.join(output).encode(), ledger, summary, witness


def seed_header(provenance_id, provenance):
    return ('# schema ' + SCHEMA + '\n# profile ' + shader_profile.PROFILE + '\n# chain b-' +
            provenance['derived_chain'] + '\n# provenance ' + provenance_id + '\n# native-layout ' +
            digest(provenance['native']['native_layout']) + '\n# source-seed ' +
            provenance['inputs']['metadata']['pso_manifest.tsv']['sha256'] +
            '\n# source-only; Metal compilation and execution not performed\n').encode()


def prepare(cache, qualification, derived, metadata, work, developer_dir):
    work.mkdir(parents=True, exist_ok=False)
    before = source_snapshot(metadata, qualification, derived)
    map_raw = (metadata / 'shader_map.tsv').read_bytes()
    expected = shader_map(map_raw, before['runtime_stages']['labels'])
    profile, refs = check_shaders(cache, qualification, derived, expected)
    codec = NativeCodec(work / 'native', developer_dir)
    body, ledger, summary, witness = seed_records((metadata / 'pso_manifest.tsv').read_bytes(), expected, refs, codec)
    c1, c1_contract, c1_execution = generate_c1(cache, derived, metadata, profile, expected, work)
    provenance = {'inputs': before, 'profile': shader_profile.PROFILE, 'capabilities': profile['provenance']['capabilities'],
                  'canonical_chain': profile['provenance']['input']['chain'], 'derived_chain': profile['chain'],
                  'shader_keys': len(expected), 'native': codec.contract, 'c1': c1_contract}
    provenance_id = digest(provenance)
    artifacts = {'shader_map.tsv': map_raw, 'c1_full.tsv': c1,
                 'pso_manifest.tsv': seed_header(provenance_id, provenance) + body}
    descriptor = {'schema': SCHEMA, 'profile': shader_profile.PROFILE,
                  'compiled': False, 'executed': False, 'renderer_qualified': False,
                  'provenance': provenance, 'provenance_id': provenance_id,
                  'artifacts': {name: {'size': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
                                for name, raw in artifacts.items()},
                  'ledger': ledger, 'summary': summary,
                  'native_execution': {'binary': codec.binary_identity, 'semantic_witness_sha256': digest(witness),
                                       'historical_binary_reproducibility_claimed': False},
                  'c1_execution': c1_execution}
    codec.verify()
    check_shaders(cache, qualification, derived, expected)
    require(source_snapshot(metadata, qualification, derived) == before, 'metadata source/producers changed')
    return descriptor, artifacts, codec


def descriptor_shape(descriptor):
    record(descriptor, {'schema', 'profile', 'compiled', 'executed', 'renderer_qualified', 'provenance',
                       'provenance_id', 'artifacts', 'ledger', 'summary', 'native_execution', 'c1_execution'}, 'metadata descriptor')
    require(descriptor['schema'] == SCHEMA and descriptor['profile'] == shader_profile.PROFILE and
            all(descriptor[field] is False for field in ('compiled', 'executed', 'renderer_qualified')),
            'invalid source-only metadata claims')
    record(descriptor['artifacts'], FILES - {'metadata-profile.json'}, 'output artifacts')
    for value in descriptor['artifacts'].values():
        file_identity(value)
    record(descriptor['native_execution'], {'binary', 'semantic_witness_sha256', 'historical_binary_reproducibility_claimed'}, 'native execution')
    file_identity(descriptor['native_execution']['binary'])
    require(descriptor['native_execution']['historical_binary_reproducibility_claimed'] is False and
            isinstance(descriptor['native_execution']['semantic_witness_sha256'], str) and
            SHA.fullmatch(descriptor['native_execution']['semantic_witness_sha256']), 'invalid native execution claims')
    record(descriptor['c1_execution'], {'canonical_output', 'derived_output'}, 'C1 execution')
    for value in descriptor['c1_execution'].values():
        file_identity(value)
    require(isinstance(descriptor['provenance_id'], str) and SHA.fullmatch(descriptor['provenance_id']) and
            digest(descriptor['provenance']) == descriptor['provenance_id'], 'metadata provenance identity mismatch')


def verify_shader_artifacts(cache, qualification, derived, inputs):
    require(identity(qualification) == inputs['canonical_qualification'] and
            identity(derived / 'profile.json') == inputs['shader_profile'], 'shader descriptors changed during final admission')
    canonical = {Path(item['path']).name: {'size': item['size'], 'sha256': item['sha256']}
                 for item in read_json(qualification)['artifacts']}
    derivative = dict(read_json(derived / 'profile.json')['artifacts'])
    derivative['profile.json'] = inputs['shader_profile']
    for root, expected in ((cache, canonical), (derived, derivative)):
        actual, directories = set(), set()
        for path in root.rglob('*'):
            require(not path.is_symlink(), 'shader artifact symlink during final admission')
            if path.is_file():
                actual.add(str(path.relative_to(root)))
            elif path.is_dir():
                directories.add(str(path.relative_to(root)))
            else:
                raise ValueError('unsupported shader artifact during final admission')
        expected_directories = {str(parent) for name in expected for parent in Path(name).parents
                                if str(parent) != '.'}
        require(actual == set(expected) and directories == expected_directories,
                'shader artifact set changed during final admission')
        for name, value in expected.items():
            require(identity(root / name) == value, 'shader artifact changed during final admission: ' + name)


def verify_final_inputs(cache, qualification, derived, metadata, descriptor, codec):
    inputs = descriptor['provenance']['inputs']
    verify_shader_artifacts(cache, qualification, derived, inputs)
    codec.verify()
    require(source_snapshot(metadata, qualification, derived) == inputs,
            'metadata inputs changed during final admission')


def produce_metadata(canonical_cache, qualification, derived, metadata, destination, *, work,
                     developer_dir=Path('/Applications/Xcode.app/Contents/Developer')):
    cache, qualification, derived, metadata, destination, work = paths(
        canonical_cache, qualification, derived, metadata, destination, work)
    require(not destination.exists(), 'metadata destination must be fresh')
    descriptor, artifacts, codec = prepare(cache, qualification, derived, metadata, work, developer_dir)
    descriptor_shape(descriptor)
    destination.mkdir(parents=True, exist_ok=False)
    for name, raw in artifacts.items():
        (destination / name).write_bytes(raw)
    expected = shader_map(artifacts['shader_map.tsv'], descriptor['provenance']['inputs']['runtime_stages']['labels'])
    check_shaders(cache, qualification, derived, expected)
    # Publish only the final descriptor atomically; scratch remains outside the
    # four-file bundle so incomplete production cannot appear admitted.
    with tempfile.NamedTemporaryFile(dir=work, prefix='descriptor-', delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(encoded(descriptor))
    verify_final_inputs(cache, qualification, derived, metadata, descriptor, codec)
    require(set(p.name for p in destination.iterdir()) == set(artifacts), 'metadata output set changed')
    for name, value in descriptor['artifacts'].items():
        require(identity(destination / name) == value, 'metadata output changed before publication')
    require(temporary.read_bytes() == encoded(descriptor), 'temporary descriptor changed before publication')
    temporary.replace(destination / 'metadata-profile.json')
    return descriptor


def validate_metadata(destination, canonical_cache, qualification, derived, metadata, *,
                      expected_descriptor_sha256, work,
                      developer_dir=Path('/Applications/Xcode.app/Contents/Developer')):
    cache, qualification, derived, metadata, destination, work = paths(
        canonical_cache, qualification, derived, metadata, destination, work)
    require(isinstance(expected_descriptor_sha256, str) and SHA.fullmatch(expected_descriptor_sha256),
            'explicit metadata descriptor digest required')
    require(destination.is_dir() and set(p.name for p in destination.iterdir()) == FILES,
            'metadata output artifact set mismatch')
    descriptor_path = destination / 'metadata-profile.json'
    before = {name: identity(destination / name) for name in FILES}
    require(before['metadata-profile.json']['sha256'] == expected_descriptor_sha256, 'metadata descriptor identity mismatch')
    descriptor = read_json(descriptor_path)
    descriptor_shape(descriptor)
    for name, value in descriptor['artifacts'].items():
        require(before[name] == value, 'metadata artifact identity mismatch')
    replay, artifacts, codec = prepare(cache, qualification, derived, metadata, work, developer_dir)
    for field in ('schema', 'profile', 'compiled', 'executed', 'renderer_qualified', 'provenance',
                  'provenance_id', 'ledger', 'summary'):
        require(encoded(descriptor[field]) == encoded(replay[field]), 'metadata replay differs: ' + field)
    require(descriptor['native_execution']['semantic_witness_sha256'] ==
            replay['native_execution']['semantic_witness_sha256'], 'native semantic replay differs')
    for name in ('shader_map.tsv', 'pso_manifest.tsv'):
        require((destination / name).read_bytes() == artifacts[name], 'metadata replay bytes differ: ' + name)
    require(parse_c1((destination / 'c1_full.tsv').read_bytes(), descriptor['provenance']['derived_chain'],
                     set(shader_map(artifacts['shader_map.tsv'], descriptor['provenance']['inputs']['runtime_stages']['labels']))) ==
            descriptor['provenance']['c1']['guard_keys'], 'published C1 guards differ')
    require(descriptor['c1_execution']['derived_output'] == descriptor['artifacts']['c1_full.tsv'],
            'historical C1 output/artifact disagreement')
    verify_final_inputs(cache, qualification, derived, metadata, descriptor, codec)
    require(set(p.name for p in destination.iterdir()) == FILES and
            {name: identity(destination / name) for name in FILES} == before, 'metadata bundle changed during replay')
    return descriptor
