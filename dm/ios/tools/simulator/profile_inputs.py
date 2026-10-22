"""Admit descriptor-selected source profiles using copied, frozen CPU tools."""

import hashlib
import json
from pathlib import Path
import re
import shutil


SCHEMA = 'd2r.simulator-profile-admission.v1'
MODE = 'derived-profile'
CLOSURE = ('dm/ios/tools/simulator/profile_admission.py', 'dm/ios/tools/simulator/profile_metadata.py',
           'dm/ios/tools/simulator/shader_profile.py', 'dm/ios/tools/simulator/pso_toolchain.py',
           'dm/ios/tools/simulator/pso_native.py', 'dm/ios/tools/simulator/pso_codec.c',
           'dm/gfx/tools/c1_guard.py', 'dm/gfx/nvn/nvn_pso_profile.h', 'dm/gfx/nvn/nvn_pso_wire.h',
           'dm/gfx/nvn/nvn_obj.h', 'dm/gfx/nvn/nvn_tex.h', 'dm/gfx/nvn/include/nvn.h',
           'dm/gfx/nvn/nvn_mtl.m')
METADATA_FILES = {'shader_map.tsv', 'pso_manifest.tsv', 'c1_full.tsv', 'metadata-profile.json'}
SHA = re.compile(r'[0-9a-f]{64}')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def identity(path):
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), 'profile input must be a regular file')
    raw = path.read_bytes()
    return {'size': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}


def encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()


def read_json(path):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'duplicate profile JSON field')
            result[key] = value
        return result
    def constant(value):
        raise ValueError('invalid profile JSON constant: ' + value)
    return json.loads(Path(path).read_bytes(), object_pairs_hook=pairs, parse_constant=constant)


def fingerprint(root):
    root = Path(root)
    result = {}
    for path in sorted(root.rglob('*')):
        require(not path.is_symlink(), 'profile source symlink')
        if path.is_file():
            result[str(path.relative_to(root))] = identity(path)
        else:
            require(path.is_dir(), 'unsupported profile source entry')
    require(result, 'empty frozen profile source')
    return result


def selected_inputs(args):
    require(args.shader_mode in {'canonical', MODE}, 'explicit shader mode required')
    paired = [args.shader_profile, args.profile_metadata, args.metadata_descriptor_sha256, args.validation_python]
    if args.shader_mode == 'canonical':
        require(all(value is None for value in paired), 'canonical mode cannot select derived descriptors')
        return {}
    require(all(value is not None for value in paired), 'derived mode requires paired descriptors and interpreter')
    require(SHA.fullmatch(args.metadata_descriptor_sha256), 'explicit metadata descriptor digest required')
    return {'shader_profile': Path(args.shader_profile), 'profile_metadata': Path(args.profile_metadata)}


def copy_exact(source, destination, expected):
    destination.mkdir(parents=True, exist_ok=False)
    require(set(path.name for path in source.iterdir()) == set(expected), 'metadata input set mismatch')
    for name in expected:
        require(identity(source / name) == expected[name], 'profile input changed')
        shutil.copyfile(source / name, destination / name)
        (destination / name).chmod(0o444)
    require({name: identity(destination / name) for name in expected} == expected, 'profile copy changed')


def admit(source_root, canonical_cache, qualification, canonical_metadata, profile, metadata,
          descriptor_sha256, python, work, developer_dir, execute):
    source_root, canonical_cache, qualification, canonical_metadata, profile, metadata, work = map(
        lambda value: Path(value).resolve(), (source_root, canonical_cache, qualification, canonical_metadata,
                                             profile, metadata, work))
    require(not work.exists(), 'profile admission workspace must be fresh')
    for input_path in (source_root, canonical_cache, qualification, canonical_metadata, profile, metadata):
        require(not work.is_relative_to(input_path) and not input_path.is_relative_to(work), 'profile workspace overlap')
    before = fingerprint(source_root)
    metadata_before = {name: identity(metadata / name) for name in METADATA_FILES}
    require(set(p.name for p in metadata.iterdir()) == METADATA_FILES, 'profile metadata must contain exactly four files')
    require(SHA.fullmatch(descriptor_sha256) and
            metadata_before['metadata-profile.json']['sha256'] == descriptor_sha256, 'profile descriptor identity')
    descriptor = read_json(metadata / 'metadata-profile.json')
    python = Path(python).resolve()
    interpreter = identity(python)
    require(interpreter == descriptor['provenance']['inputs']['python']['executable'],
            'validation interpreter differs from recorded Python; select the recorded Python 3.13 executable')
    source_profile_before = fingerprint(profile)
    canonical_before = fingerprint(canonical_cache)
    qualification_before = identity(qualification)
    canonical_metadata_before = {name: identity(canonical_metadata / name)
                                 for name in ('shader_map.tsv', 'pso_manifest.tsv', 'c1_full.tsv')}
    workspace = work / 'source'
    for name in CLOSURE:
        require(name in before, 'frozen validation closure is incomplete: ' + name)
        target = workspace / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source_root / name, target)
        target.chmod(0o444)
        require(identity(target) == before[name], 'frozen validation tool copy differs')
    scratch = workspace / '.tmp'
    scratch.mkdir()
    selected = scratch / 'selected-metadata'
    copy_exact(metadata, selected, metadata_before)
    canonical = scratch / 'canonical-inputs'
    canonical.mkdir()
    shutil.copyfile(qualification, canonical / qualification.name)
    (canonical / qualification.name).chmod(0o444)
    copy_exact(canonical_metadata, canonical / 'canonical-metadata', canonical_metadata_before)
    result_path = scratch / 'admission-result.json'
    argv = [python, workspace / CLOSURE[0], '--canonical-cache', canonical_cache,
            '--qualification', canonical / qualification.name, '--canonical-metadata', canonical / 'canonical-metadata', '--profile', profile,
            '--metadata', selected, '--descriptor-sha256', descriptor_sha256,
            '--work', scratch / 'replay', '--result', result_path, '--developer-dir', developer_dir]
    execute(argv, workspace)
    result = read_json(result_path)
    fields = {'schema', 'chain', 'source_profile', 'profile_sha256', 'metadata_sha256', 'metadata_id',
              'native_layout_sha256', 'keys', 'staged_files', 'compiled', 'executed', 'renderer_qualified', 'python'}
    require(isinstance(result, dict) and set(result) == fields and result['schema'] == SCHEMA,
            'invalid profile admission result schema')
    require(all(result[name] is False for name in ('compiled', 'executed', 'renderer_qualified')),
            'profile admission cannot claim rendering qualification')
    require(result['metadata_sha256'] == descriptor_sha256 and
            result['metadata_id'] == descriptor['provenance_id'] and
            result['chain'] == descriptor['provenance']['derived_chain'] and
            result['source_profile'] == descriptor['profile'] and
            result['native_layout_sha256'] == hashlib.sha256(encoded(descriptor['provenance']['native']['native_layout'])).hexdigest() and
            set(result['python']) == {'sha256', 'version'} and
            result['python']['sha256'] == interpreter['sha256'] and
            result['python']['version'] == descriptor['provenance']['inputs']['python']['version'] and
            result['profile_sha256'] == source_profile_before['profile.json']['sha256'],
            'profile admission identity mismatch')
    require(type(result['keys']) is int and result['keys'] == descriptor['provenance']['shader_keys'] and result['keys'] > 0 and
            len(result['staged_files']) == result['keys'] * 2, 'profile admission key coverage')
    expected_names = {f"b-{result['chain']}/{key}_b{suffix}" for key in
                      read_json(profile / 'profile.json')['provenance']['input']['keys']
                      for suffix in ('.json', '.metallib')}
    require(set(result['staged_files']) == expected_names and all(
        source_profile_before[name] == value for name, value in result['staged_files'].items()),
        'profile admission base file coverage differs')
    require(fingerprint(source_root) == before, 'primary frozen source changed during validation')
    require(fingerprint(workspace / 'dm') == {name[3:]: before[name] for name in CLOSURE},
            'isolated validation source closure changed')
    require(fingerprint(profile) == source_profile_before and fingerprint(canonical_cache) == canonical_before and
            identity(qualification) == qualification_before and
            {name: identity(canonical_metadata / name) for name in canonical_metadata_before} == canonical_metadata_before and
            {name: identity(metadata / name) for name in METADATA_FILES} == metadata_before and
            {name: identity(selected / name) for name in METADATA_FILES} == metadata_before and
            identity(canonical / qualification.name) == qualification_before and
            {name: identity(canonical / 'canonical-metadata' / name) for name in canonical_metadata_before} == canonical_metadata_before and
            identity(python) == interpreter, 'profile inputs changed during admission')
    result['validation'] = {'source_fingerprint_sha256': hashlib.sha256(encoded(before)).hexdigest(),
                            'closure': {name: before[name] for name in CLOSURE},
                            'interpreter': interpreter, 'worker_result': identity(result_path),
                            'primary_source_unchanged': True, 'isolated_tools_unchanged': True}
    return result


def constants(chain, admission):
    require(isinstance(chain, str) and re.fullmatch(r'[0-9a-f]{12}', chain), 'invalid generated shader chain')
    content = '#define DM_SHELL 1\n#define DM_NVN_M3 1\n#define DM_SIMULATOR_SHADER_CHAIN "' + chain + '"\n'
    content += '#define DM_SIMULATOR_PROFILE_ACTIVATED 0\n'
    if admission is not None:
        for macro, value in [('DM_SIMULATOR_SOURCE_PROFILE', admission['source_profile']),
                             ('DM_SIMULATOR_METADATA_SHA256', admission['metadata_sha256']),
                             ('DM_SIMULATOR_METADATA_ID', admission['metadata_id'])]:
            require(re.fullmatch(r'[a-z0-9-]+', value), 'invalid generated source profile constant')
            content += '#define ' + macro + ' "' + value + '"\n'
    return content


def stage_metadata(metadata, identities, destination, *, profile, profile_identity):
    metadata, destination = Path(metadata), Path(destination)
    derived = profile is not None
    require(set(identities) == (METADATA_FILES if derived else METADATA_FILES - {'metadata-profile.json'}),
            'metadata staging mode/descriptor mismatch')
    selected = {name: (metadata / name, identities[name]) for name in ('shader_map.tsv', 'c1_full.tsv', 'pso_manifest.tsv')}
    descriptor_names = ('simulator-shader-profile.json', 'simulator-metadata-profile.json')
    if derived:
        require(profile_identity is not None, 'paired shader profile identity is required')
        selected[descriptor_names[0]] = (Path(profile) / 'profile.json', profile_identity)
        selected[descriptor_names[1]] = (metadata / 'metadata-profile.json', identities['metadata-profile.json'])
    else:
        require(profile_identity is None and not any((destination / name).exists() for name in descriptor_names),
                'canonical mode cannot stage stale derived descriptors')
    destination.mkdir(parents=True, exist_ok=True)
    for name, (source, expected) in selected.items():
        require(identity(source) == expected, 'metadata source identity changed before staging')
        shutil.copyfile(source, destination / name)
    for name, (source, expected) in selected.items():
        require(identity(source) == expected == identity(destination / name), 'metadata staged/source identity mismatch')
    return {'resources': {'dm/' + name: expected for name, (_, expected) in selected.items()},
            'sources': {str(source): expected['sha256'] for source, expected in selected.values()}}
