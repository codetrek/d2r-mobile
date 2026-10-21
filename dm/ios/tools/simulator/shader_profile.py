"""Derive a source-only iOS Simulator shader profile from an immutable B cache.

Only sampler fields backed by the same exact (kind, register) are aliases. The
accepted generated dialect has one descriptor struct and one entry parameter;
ambiguous declarations, identifier uses and metadata are errors.
"""

from copy import deepcopy
import hashlib
import json
from pathlib import Path
import re
import shutil
import tempfile


PROFILE = 'ios-simulator-native-arguments-sampler-alias-v1'
CAPABILITIES = {
    'platform': 'ios-simulator', 'argument_encoding': 'public-native-encoder',
    'argument_buffer_tier': 0, 'metal3': False, 'bc_texture_compression': False,
    'framebuffer_fetch': False, 'max_sampler_sources': 16, 'max_bindings': 64,
}
KIND = 'translated MSL source; Metal compilation and execution not performed'
KEY = re.compile(r'[0-9a-f]{16}')
CHAIN = re.compile(r'[0-9a-f]{12}')
IDENTIFIER = re.compile(r'[A-Za-z_]\w*', re.ASCII)
OPAQUE = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\[\s\S]|[^"\\])*"|\'(?:\\[\s\S]|[^\'\\])*\'')
MEMBER = re.compile(r'(?P<type>[\w\s:<>,*]+?)\s+(?P<name>[A-Za-z_]\w*)\s*\[\[\s*id\s*\(\s*(?P<id>\d+)\s*\)\s*\]\]\s*;', re.ASCII)
ROOT_FIELDS = set('key route chain dm_ctl source pc_paired stage entry msl_entry_kind threadgroup_size c1 notes drv_reads drv_unfillable bindings vertex_inputs raster chain_metal'.split())
BIND_FIELDS = {
    **{k: {'reg'} for k in ('cbuf', 'tex', 'samp', 'samp_tex', 'img', 'tbuf')},
    **{k: {'reg', 'index', 'rw'} for k in ('sbuf', 'ubo_ptr')},
    'support': set(), 'c1': {'bank'}, 'drvcb': {'bank'},
}
BASE_FIELDS = {'msl_name', 'msl_type', 'arg_id', 'kind'}
REPO = Path(__file__).resolve().parents[4]
OPTIONS = {'sampler_alias': ['kind', 'reg'], 'argument_ids': 'dense-in-declaration-order',
           'base_only': True, 'preprocessor': 'generated-prefix-include-diagnostic-allowlist-v1'}
METADATA_REQUIREMENTS = ['rerun-c1_guard.py', 'bind-shader-map-invariant-key-stage-fields', 'regenerate-profile-aware-pso-seeds']
DIRECTIVES = {'#include <metal_stdlib>', '#include <simd/simd.h>', '#include <metal_atomic>',
              '#pragma clang diagnostic ignored "-Wmissing-prototypes"',
              '#pragma clang diagnostic ignored "-Wunused-variable"',
              '#pragma clang diagnostic ignored "-Wmissing-braces"'}


def _json(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True) + '\n').encode()


def _digest(data):
    return hashlib.sha256(data).hexdigest()


def _read_json(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('duplicate JSON field: ' + key)
            result[key] = value
        return result
    def invalid_constant(value):
        raise ValueError('invalid JSON numeric constant: ' + value)
    return json.loads(raw, object_pairs_hook=pairs, parse_constant=invalid_constant)


def _identity(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError('artifact must be a regular non-symlink file: ' + str(path))
    data = path.read_bytes()
    return {'size': len(data), 'sha256': _digest(data)}


def _integer(value, label, maximum=65535):
    if type(value) is not int or not 0 <= value <= maximum:
        raise ValueError('invalid ' + label)


def _mask(source):
    if re.search(r'\\(?:\r\n|\n|\r)', source):
        raise ValueError('line-spliced generated source is unsupported')
    def opaque(match):
        prefix = source[max(0, match.start() - 5):match.start()]
        if match[0].startswith('"') and re.search(r'\b(?:u8|u|U|L)?R$', prefix):
            raise ValueError('raw string generated source is unsupported')
        return ''.join('\n' if c == '\n' else ' ' for c in match[0])
    masked = OPAQUE.sub(opaque, source)
    if re.search(r'/\*|\*/|["\']', masked):
        raise ValueError('unterminated or unsupported comment/string')
    return masked


def _tokens(value):
    return re.findall(r'\w+|[^\s]', value, re.ASCII)


def _record(value, fields, label):
    if not isinstance(value, dict) or set(value) != fields:
        raise ValueError('unsupported ' + label + ' fields')


def _range(value, label, minimum, maximum):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError('invalid ' + label)


def _key(value, label, maximum):
    if not isinstance(value, str) or not re.fullmatch(r'0|[1-9][0-9]*', value) or int(value) > maximum:
        raise ValueError('invalid ' + label)


def _validate_preprocessor(source, masked):
    seen_code = False
    for original, code in zip(source.splitlines(), masked.splitlines(), strict=True):
        stripped = code.strip()
        if stripped.startswith('#'):
            if seen_code or original.strip() not in DIRECTIVES:
                raise ValueError('unsupported generated preprocessor directive/context')
        elif stripped:
            if '#' in stripped or '%:' in stripped or '??=' in stripped:
                raise ValueError('unsupported preprocessor token')
            seen_code = True


def _validate_reflection(reflection):
    if not isinstance(reflection, dict) or set(reflection) not in (ROOT_FIELDS, ROOT_FIELDS | {'fetch'}):
        raise ValueError('unsupported reflection fields')
    key = reflection['dm_ctl']
    if not isinstance(key, str) or not KEY.fullmatch(key) or int(key, 16) == 0 or reflection['key'] != key + '_b':
        raise ValueError('invalid base shader identity')
    if reflection['route'] != 'B' or not isinstance(reflection['chain'], str) or not CHAIN.fullmatch(reflection['chain']):
        raise ValueError('invalid route/chain')
    stage = {'vs': 'vertex', 'ps': 'fragment', 'cs': 'kernel', 'hs': 'kernel', 'ds': 'vertex'}
    if not isinstance(reflection['stage'], str) or reflection['stage'] not in stage or reflection['msl_entry_kind'] != stage[reflection['stage']]:
        raise ValueError('unsupported stage/entry kind')
    if not isinstance(reflection['entry'], str) or not IDENTIFIER.fullmatch(reflection['entry']) or reflection['drv_unfillable'] != []:
        raise ValueError('invalid entry or unfillable driver reads')
    if not isinstance(reflection['chain_metal'], str) or not reflection['chain_metal']:
        raise ValueError('invalid compilation description')
    if not isinstance(reflection['c1'], str) or not re.fullmatch(r'(?:[0-9a-f]{2}){0,4096}', reflection['c1']):
        raise ValueError('invalid C1 bytes')
    if reflection['notes'] != [] or not isinstance(reflection['source'], str) or not reflection['source']:
        raise ValueError('unsupported notes/source metadata')
    if not isinstance(reflection['pc_paired'], str) or not KEY.fullmatch(reflection['pc_paired']):
        raise ValueError('invalid paired shader identity')
    tg = reflection['threadgroup_size']
    if reflection['stage'] == 'cs':
        if not isinstance(tg, list) or len(tg) != 3:
            raise ValueError('invalid threadgroup size')
        for extent in tg:
            _range(extent, 'threadgroup extent', 1, 65535)
    elif tg is not None:
        raise ValueError('unexpected threadgroup size')
    raster = reflection['raster']
    if reflection['stage'] == 'ps':
        _record(raster, {'colors', 'discard', 'sample_mask'}, 'fragment raster')
        for field in ('discard', 'sample_mask'):
            _range(raster[field], field, 0, 1)
        if not isinstance(raster['colors'], list) or len(raster['colors']) > 8:
            raise ValueError('invalid raster colors')
        for color in raster['colors']:
            _range(color, 'raster color', 0, 7)
        if len(set(raster['colors'])) != len(raster['colors']):
            raise ValueError('duplicate raster color')
    elif reflection['stage'] == 'vs':
        if not isinstance(raster, dict) or set(raster) not in ({'pos_attr'}, {'pos_attr', 'pos_w', 'uv_from_attr', 'uv_affine'}):
            raise ValueError('unsupported vertex raster fields')
        _range(raster['pos_attr'], 'position attribute', -1, 15)
        if set(raster) == {'pos_attr'}:
            if raster['pos_attr'] != -1:
                raise ValueError('incomplete position metadata')
        else:
            if raster['pos_attr'] < 0 or raster['pos_w'] not in ('attr', 'one'):
                raise ValueError('invalid position metadata')
            for field in ('uv_from_attr', 'uv_affine'):
                if not isinstance(raster[field], dict):
                    raise ValueError('invalid UV metadata')
                for location, item in raster[field].items():
                    _key(location, 'UV location', 31)
                    if field == 'uv_from_attr':
                        _range(item, 'UV attribute', 0, 15)
                    else:
                        _record(item, {'attr', 'sx', 'ox', 'sy', 'oy'}, 'affine UV')
                        _range(item['attr'], 'affine attribute', 0, 15)
                        for component in ('sx', 'ox', 'sy', 'oy'):
                            reference = item[component]
                            if not isinstance(reference, list) or len(reference) != 3:
                                raise ValueError('invalid affine uniform reference')
                            for value, maximum in zip(reference, (15, 63, 3), strict=True):
                                _range(value, 'affine uniform component', 0, maximum)
    else:
        _record(raster, set(), 'non-raster stage')
    vertices = reflection['vertex_inputs']
    if not isinstance(vertices, list) or len(vertices) > 32 or (vertices and reflection['stage'] not in ('vs', 'hs', 'ds')):
        raise ValueError('invalid vertex inputs')
    locations = set()
    for vertex in vertices:
        _record(vertex, {'location', 'msl_type'}, 'vertex input')
        _range(vertex['location'], 'vertex location', 0, 31)
        if vertex['location'] in locations or vertex['msl_type'] not in ('float4', 'int4', 'uint4'):
            raise ValueError('duplicate vertex location or invalid vertex type')
        locations.add(vertex['location'])
    reads = reflection['drv_reads']
    if not isinstance(reads, dict) or set(reads) - {'0', '2'}:
        raise ValueError('unsupported driver read metadata')
    for value in reads.values():
        _record(value, {'vec4_offsets', 'dynamic'}, 'driver read')
        if type(value['dynamic']) is not bool or not isinstance(value['vec4_offsets'], list):
            raise ValueError('invalid driver read values')
        for offset in value['vec4_offsets']:
            _range(offset, 'driver read offset', 0, 65520)
            if offset % 16:
                raise ValueError('unaligned driver vec4 read')
        if value['vec4_offsets'] != sorted(set(value['vec4_offsets'])):
            raise ValueError('driver offsets must be unique and ordered')
    if 'fetch' in reflection:
        fetch = reflection['fetch']
        _record(fetch, {'calls', 'mixed_regs', 'outputs'}, 'fetch')
        if reflection['stage'] != 'ps' or not isinstance(fetch['calls'], list) or len(fetch['calls']) > 32:
            raise ValueError('invalid fetch calls')
        for index, call in enumerate(fetch['calls']):
            _record(call, {'fc', 'tex_reg', 'varying_locn'}, 'fetch call')
            _range(call['fc'], 'fetch constant', 0, 31)
            if call['fc'] != index:
                raise ValueError('nonconsecutive fetch constants')
            _range(call['tex_reg'], 'fetch texture register', 0, 127)
            _range(call['varying_locn'], 'fetch varying location', 0, 31)
        for field, maximum in [('mixed_regs', 128), ('outputs', 4)]:
            if not isinstance(fetch[field], list) or len(fetch[field]) > maximum:
                raise ValueError('invalid fetch ' + field)
        for reg in fetch['mixed_regs']:
            _range(reg, 'mixed fetch register', 0, 127)
        if len(set(fetch['mixed_regs'])) != len(fetch['mixed_regs']):
            raise ValueError('duplicate mixed fetch register')
        colors = set()
        for output in fetch['outputs']:
            _record(output, {'color', 'type'}, 'fetch output')
            _range(output['color'], 'fetch output color', 0, 7)
            if output['color'] in colors or output['type'] != 'float4':
                raise ValueError('duplicate fetch color or invalid output type')
            colors.add(output['color'])
    if not isinstance(reflection['bindings'], list):
        raise ValueError('bindings must be an array')
    names, aids = set(), set()
    for binding in reflection['bindings']:
        if not isinstance(binding, dict) or not isinstance(binding.get('kind'), str) or binding['kind'] not in BIND_FIELDS:
            raise ValueError('unsupported binding kind')
        _record(binding, BASE_FIELDS | BIND_FIELDS[binding['kind']], 'binding')
        name, aid, ty = binding['msl_name'], binding['arg_id'], binding['msl_type']
        if not isinstance(name, str) or not IDENTIFIER.fullmatch(name) or name in names:
            raise ValueError('duplicate or invalid binding name')
        _integer(aid, 'argument ID')
        if aid in aids or not isinstance(ty, str) or not ty:
            raise ValueError('duplicate argument ID or invalid type')
        names.add(name)
        aids.add(aid)
        if 'reg' in binding:
            maximum = 15 if binding['kind'] in ('cbuf', 'sbuf', 'ubo_ptr') else 31 if binding['kind'] == 'img' else 127
            _integer(binding['reg'], 'register', maximum)
        if binding['kind'] in ('samp', 'samp_tex') and ty != 'sampler':
            raise ValueError('sampler binding has a different MSL type')
        if 'bank' in binding and (type(binding['bank']) is not int or binding['bank'] not in ((1,) if binding['kind'] == 'c1' else (0, 2))):
            raise ValueError('invalid constant bank')
        if 'index' in binding:
            _integer(binding['index'], 'storage index')
            if type(binding['rw']) is not bool:
                raise ValueError('storage rw must be boolean')

def transform_shader(source, reflection, chain):
    """Return source/reflection/proof without changing either caller-owned input.

    ``chain`` is a new derivative identity chosen by derive_cache, or an explicit
    synthetic identity for unit tests. No Metal compiler or device is contacted.
    """
    _validate_reflection(reflection)
    if not isinstance(source, str) or not source or not CHAIN.fullmatch(chain) or chain == reflection['chain']:
        raise ValueError('nonempty source and distinct derivative chain required')
    masked = _mask(source)
    _validate_preprocessor(source, masked)
    bindings = reflection['bindings']
    structs = list(re.finditer(r'\bstruct\s+spvDescriptorSetBuffer0\s*\{([^{}]*)\}\s*;', masked))
    if len(structs) != bool(bindings) or re.search(r'\bspvDescriptorSetBuffer[1-9]\d*\b', masked):
        raise ValueError('unsupported descriptor struct shape')
    declarations = {}
    if structs:
        body_start, body_end = structs[0].span(1)
        cursor = body_start
        for member in MEMBER.finditer(masked, body_start, body_end):
            if masked[cursor:member.start()].strip():
                raise ValueError('unsupported descriptor member syntax')
            name = member['name']
            if name in declarations:
                raise ValueError('duplicate source member')
            declarations[name] = member
            cursor = member.end()
        if masked[cursor:body_end].strip() or len(declarations) != len(bindings):
            raise ValueError('source/reflection member set mismatch')
    if list(declarations) != [binding['msl_name'] for binding in bindings]:
        raise ValueError('source/reflection declaration order mismatch')
    for binding in bindings:
        member = declarations.get(binding['msl_name'])
        if member is None or int(member['id']) != binding['arg_id'] or _tokens(member['type']) != _tokens(binding['msl_type']):
            raise ValueError('source/reflection member metadata mismatch')
    entry_pattern = r'\b' + re.escape(reflection['msl_entry_kind']) + r'\s+\w+\s+' + re.escape(reflection['entry']) + r'\s*\('
    entries = list(re.finditer(entry_pattern, masked))
    if len(entries) != 1:
        raise ValueError('expected one generated entry definition')
    entry = entries[0]
    # Balanced delimiters delimit the parameter list and body before any edits.
    def close_at(start, opening, closing):
        depth = 0
        for offset in range(start, len(masked)):
            if masked[offset] == opening:
                depth += 1
            elif masked[offset] == closing:
                depth -= 1
                if depth == 0:
                    return offset
        raise ValueError('unbalanced entry delimiters')
    parameters_end = close_at(entry.end() - 1, '(', ')')
    body_start = parameters_end + 1
    while body_start < len(masked) and masked[body_start].isspace():
        body_start += 1
    if body_start == len(masked) or masked[body_start] != '{':
        raise ValueError('unsupported entry body')
    body_end = close_at(body_start, '{', '}')
    parameter = re.compile(r'\bconstant\s+spvDescriptorSetBuffer0\s*&\s*(spvDescriptorSet0)\s*\[\[\s*buffer\s*\(\s*0\s*\)\s*\]\]')
    parameters = list(parameter.finditer(masked, entry.end(), parameters_end))
    if len(parameters) != bool(bindings):
        raise ValueError('unsupported descriptor entry parameter')
    parameter_name_span = parameters[0].span(1) if parameters else None
    references = []
    for occurrence in re.finditer(r'\bspvDescriptorSet0\b', masked):
        if occurrence.span() == parameter_name_span:
            continue
        member = re.match(r'\s*\.\s*([A-Za-z_]\w*)\b', masked[occurrence.end():], re.ASCII)
        if not body_start < occurrence.start() < body_end or member is None or member[1] not in declarations:
            raise ValueError('descriptor variable escapes or is shadowed')
        start, end = member.span(1)
        references.append((member[1], occurrence.end() + start, occurrence.end() + end))
    # Removed field names are accepted only in their declaration or in an
    # access through the verified entry parameter. This rejects local shadows;
    # untouched resource names may also be independent helper parameters.
    allowed = {declarations[name].span('name') for name in declarations}
    allowed.update((start, end) for _, start, end in references)
    alias_candidates, sampler_sources = [], set()
    for binding in bindings:
        if binding['kind'] in ('samp', 'samp_tex'):
            source_key = (binding['kind'], binding['reg'])
            if source_key in sampler_sources:
                alias_candidates.append(binding['msl_name'])
            sampler_sources.add(source_key)
    name_pattern = re.compile(r'\b(?:' + '|'.join(map(re.escape, alias_candidates)) + r')\b') if alias_candidates else None
    if name_pattern and any(m.span() not in allowed for m in name_pattern.finditer(masked)):
        raise ValueError('descriptor field has an unsupported unqualified/shadowed use')
    retained, aliases, groups, edits, proof = [], {}, {}, [], []
    for binding in bindings:
        name = binding['msl_name']
        member = declarations[name]
        source_key = (binding['kind'], binding['reg']) if binding['kind'] in ('samp', 'samp_tex') else None
        canonical = groups.get(source_key) if source_key is not None else None
        if canonical is not None:
            aliases[name] = canonical['msl_name']
            # Preserve comments and line structure while removing code tokens.
            start = member.start()
            while masked[start].isspace():
                start += 1
            end = member.end()
            replacement = ''.join(c if masked[i].isspace() else ' ' for i, c in enumerate(source[start:end], start))
            edits.append((start, end, replacement))
            output_id = canonical['arg_id']
            output_name = canonical['msl_name']
        else:
            updated = dict(binding, arg_id=len(retained))
            retained.append(updated)
            if source_key is not None:
                groups[source_key] = updated
            edits.append((*member.span('id'), str(updated['arg_id'])))
            output_id, output_name = updated['arg_id'], name
        proof.append({'name': name, 'msl_type': binding['msl_type'], 'kind': binding['kind'], 'source': {k: v for k, v in binding.items() if k not in BASE_FIELDS},
                      'input_id': binding['arg_id'], 'output_name': output_name, 'output_id': output_id})
    for name, start, end in references:
        if name in aliases:
            edits.append((start, end, aliases[name]))
    if len(groups) > CAPABILITIES['max_sampler_sources'] or len(retained) > CAPABILITIES['max_bindings']:
        raise ValueError('derived shader exceeds profile resource caps')
    edits.sort()
    cursor, pieces = 0, []
    for start, end, replacement in edits:
        if start < cursor:
            raise ValueError('overlapping source edits')
        pieces.extend((source[cursor:start], replacement))
        cursor = end
    pieces.append(source[cursor:])
    output = ''.join(pieces)
    result = deepcopy(reflection)
    result['bindings'] = retained
    result['chain'] = chain
    result['chain_metal'] = KIND + '; ' + PROFILE
    result.pop('fetch', None)
    return {'source': output, 'reflection': result, 'proof': {
        'key': reflection['dm_ctl'], 'bindings_before': len(bindings), 'bindings_after': len(retained),
        'samplers_before': sum(b['kind'] in ('samp', 'samp_tex') for b in bindings),
        'samplers_after': len(groups), 'aliases': len(aliases), 'bindings': proof,
        'input_metadata': {k: deepcopy(reflection[k]) for k in ('chain_metal', 'fetch') if k in reflection},
        'input_source_sha256': _digest(source.encode()), 'output_source_sha256': _digest(output.encode()),
        'input_reflection_sha256': _digest(_json(reflection)), 'output_reflection_sha256': _digest(_json(result)),
        'preserved_metadata_sha256': _digest(_json({k: v for k, v in reflection.items() if k not in {'bindings', 'chain', 'chain_metal', 'fetch'}})),
    }}


def _input_snapshot(cache, qualification, expected_keys):
    qualification_identity = _identity(qualification)
    raw = qualification.read_bytes()
    if {'size': len(raw), 'sha256': _digest(raw)} != qualification_identity:
        raise ValueError('qualification changed while reading')
    manifest = _read_json(raw)
    if set(manifest) != {'chain', 'keys', 'counts', 'kind', 'artifacts'} or manifest['kind'] != KIND:
        raise ValueError('unsupported source qualification')
    chain = manifest['chain']
    if not isinstance(chain, str) or not CHAIN.fullmatch(chain) or cache.name != 'b-' + chain:
        raise ValueError('input cache chain mismatch')
    if cache.is_symlink() or not cache.is_dir():
        raise ValueError('input cache must be a non-symlink directory')
    if type(manifest['keys']) is not int or manifest['keys'] <= 0 or not isinstance(manifest['artifacts'], list):
        raise ValueError('invalid qualification key/artifact counts')
    if not isinstance(manifest['counts'], dict) or set(manifest['counts']) != {'reflection', 'msl', 'source_cache'} or any(type(n) is not int or n <= 0 for n in manifest['counts'].values()):
        raise ValueError('invalid qualification coverage counts')
    identities = {}
    for item in manifest['artifacts']:
        if set(item) != {'path', 'size', 'sha256'}:
            raise ValueError('unsupported artifact identity fields')
        _integer(item['size'], 'artifact size', 2**63 - 1)
        if not isinstance(item['sha256'], str) or not re.fullmatch(r'[0-9a-f]{64}', item['sha256']):
            raise ValueError('invalid artifact digest')
        path = Path(item['path'])
        if path.is_absolute() or '..' in path.parts or len(path.parts) < 2 or path.parts[-2] != cache.name or path.name in identities:
            raise ValueError('unsafe or duplicate source artifact')
        actual = _identity(cache / path.name)
        if actual != {k: item[k] for k in ('size', 'sha256')}:
            raise ValueError('input artifact identity mismatch: ' + path.name)
        identities[path.name] = actual
    if {p.name for p in cache.iterdir()} != set(identities):
        raise ValueError('input cache artifact set mismatch')
    rows = _read_json((cache / '_b_build.json').read_bytes())
    if not isinstance(rows, list) or any(not isinstance(r, dict) or set(r) != {'key', 'st', 'err'} for r in rows):
        raise ValueError('unsupported build rows')
    keys = [row['key'] for row in rows]
    if not keys or len(set(keys)) != len(keys) or any(not isinstance(k, str) or not KEY.fullmatch(k) or int(k, 16) == 0 for k in keys):
        raise ValueError('empty, duplicate or invalid input keys')
    if set(keys) != set(expected_keys) or any(row['st'] != 'ok' or row['err'] != '' for row in rows) or manifest['keys'] != len(keys):
        raise ValueError('incomplete source key coverage')
    expected = {'_b_build.json'}
    semantics = {}
    variants = 0
    for key in keys:
        expected.update(key + '_b' + suffix for suffix in ('.json', '.metal', '.metallib'))
        reflection = _read_json((cache / (key + '_b.json')).read_bytes())
        _validate_reflection(reflection)
        semantics[key] = _digest(_json(reflection))
        if reflection['chain'] != chain or reflection['key'] != key + '_b':
            raise ValueError('reflection input identity mismatch')
        source = (cache / (key + '_b.metal')).read_bytes()
        if not source or source.startswith(b'MTLB') or source != (cache / (key + '_b.metallib')).read_bytes():
            raise ValueError('expected nonempty identical source MSL/cache bytes')
        if 'fetch' in reflection:
            variants += 1
            expected.add(key + '_bf.metallib')
    if set(identities) != expected or manifest['counts'] != {'reflection': len(keys), 'msl': len(keys), 'source_cache': len(keys) + variants}:
        raise ValueError('source qualification coverage/count mismatch')
    return {'chain': chain, 'keys': sorted(keys), 'artifacts': identities, 'reflection_semantics': semantics, 'qualification': {'size': len(raw), 'sha256': _digest(raw)}}


def _artifact_identity(value, label):
    _record(value, {'size', 'sha256'}, label)
    _range(value['size'], label + ' size', 1, 2**63 - 1)
    if not isinstance(value['sha256'], str) or not re.fullmatch(r'[0-9a-f]{64}', value['sha256']):
        raise ValueError('invalid ' + label + ' digest')


def _corpus(proofs, stages):
    return {'stages': stages, 'aliases_removed': sum(p['aliases'] for p in proofs),
            'max_bindings_before': max(p['bindings_before'] for p in proofs),
            'max_bindings_after': max(p['bindings_after'] for p in proofs),
            'max_samplers_before': max(p['samplers_before'] for p in proofs),
            'max_samplers_after': max(p['samplers_after'] for p in proofs)}


def _validate_profile(destination, profile, *, published, cache=None, qualification=None, expected_keys=None):
    _record(profile, {'profile', 'chain', 'keys', 'variants', 'compiled', 'artifacts', 'provenance',
                      'corpus', 'metadata_requirements', 'renderer_qualified'}, 'derived profile')
    if profile['profile'] != PROFILE or profile['compiled'] is not False or profile['renderer_qualified'] is not False:
        raise ValueError('invalid source-only profile claims')
    _range(profile['keys'], 'derived key count', 1, 2**63 - 1)
    if type(profile['variants']) is not int or profile['variants'] != 0 or _json(profile['metadata_requirements']) != _json(METADATA_REQUIREMENTS):
        raise ValueError('invalid base-only profile requirements')
    provenance = profile['provenance']
    _record(provenance, {'input', 'transform_sha256', 'profile', 'capabilities', 'options'}, 'provenance')
    if provenance['profile'] != PROFILE or _json(provenance['capabilities']) != _json(CAPABILITIES) or _json(provenance['options']) != _json(OPTIONS):
        raise ValueError('unsupported provenance profile/options/capabilities')
    if provenance['transform_sha256'] != _identity(Path(__file__))['sha256']:
        raise ValueError('derived transformation code identity mismatch')
    if not isinstance(profile['chain'], str) or not CHAIN.fullmatch(profile['chain']) or profile['chain'] != _digest(_json(provenance))[:12]:
        raise ValueError('derived provenance/chain mismatch')
    original = provenance['input']
    _record(original, {'chain', 'keys', 'artifacts', 'reflection_semantics', 'qualification'}, 'canonical input')
    if not isinstance(original['chain'], str) or not CHAIN.fullmatch(original['chain']) or original['chain'] == profile['chain']:
        raise ValueError('invalid canonical input chain')
    keys = original['keys']
    if not isinstance(keys, list) or len(keys) != profile['keys'] or any(not isinstance(k, str) or not KEY.fullmatch(k) or int(k, 16) == 0 for k in keys):
        raise ValueError('invalid canonical key coverage')
    if keys != sorted(set(keys)):
        raise ValueError('canonical keys must be unique and ordered')
    _artifact_identity(original['qualification'], 'canonical qualification')
    if not isinstance(original['artifacts'], dict) or not isinstance(original['reflection_semantics'], dict) or set(original['reflection_semantics']) != set(keys):
        raise ValueError('invalid canonical artifact/semantic coverage')
    for name, identity in original['artifacts'].items():
        if not isinstance(name, str) or Path(name).name != name:
            raise ValueError('unsafe canonical artifact name')
        _artifact_identity(identity, 'canonical artifact')
    for digest in original['reflection_semantics'].values():
        if not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest):
            raise ValueError('invalid canonical reflection semantic digest')
    prefix = 'b-' + profile['chain'] + '/'
    expected_artifacts = {prefix + '_b_build.json', 'alias-proof.jsonl', 'shader-qualification.json'}
    expected_input = {'_b_build.json'}
    for key in keys:
        for suffix in ('.json', '.metal', '.metallib'):
            expected_artifacts.add(prefix + key + '_b' + suffix)
            expected_input.add(key + '_b' + suffix)
    if not isinstance(profile['artifacts'], dict) or set(profile['artifacts']) != expected_artifacts:
        raise ValueError('derived key/artifact coverage mismatch')
    paths = list(destination.rglob('*'))
    if destination.is_symlink() or any(p.is_symlink() for p in paths):
        raise ValueError('derived output contains symlinks')
    actual = {str(p.relative_to(destination)) for p in paths if p.is_file()}
    if actual != expected_artifacts | ({'profile.json'} if published else set()):
        raise ValueError('derived output artifact set drift')
    if {str(p.relative_to(destination)) for p in paths if p.is_dir()} != {prefix[:-1]}:
        raise ValueError('derived output directory set drift')
    for name, identity in profile['artifacts'].items():
        _artifact_identity(identity, 'derived artifact')
        if _identity(destination / name) != identity:
            raise ValueError('derived output identity drift: ' + name)
    supplied = (cache is not None, qualification is not None, expected_keys is not None)
    if any(supplied) and not all(supplied):
        raise ValueError('canonical replay requires cache, qualification and expected keys')
    replay = all(supplied)
    if replay:
        cache, qualification = Path(cache), Path(qualification)
        expected_keys = list(expected_keys)
        if _json(_input_snapshot(cache, qualification, expected_keys)) != _json(original):
            raise ValueError('canonical replay input identities/semantics mismatch')
    raw_proofs = (destination / 'alias-proof.jsonl').read_bytes()
    lines = raw_proofs.splitlines(keepends=True)
    if len(lines) != len(keys):
        raise ValueError('alias proof key coverage mismatch')
    proofs, stages = [], {}
    proof_fields = {'key', 'bindings_before', 'bindings_after', 'samplers_before', 'samplers_after', 'aliases',
                    'bindings', 'input_metadata', 'input_source_sha256', 'output_source_sha256',
                    'input_reflection_sha256', 'output_reflection_sha256', 'preserved_metadata_sha256'}
    binding_fields = {'name', 'msl_type', 'kind', 'source', 'input_id', 'output_name', 'output_id'}
    for key, line in zip(keys, lines, strict=True):
        proof = _read_json(line)
        _record(proof, proof_fields, 'per-key alias proof')
        if line != _json(proof) or proof['key'] != key:
            raise ValueError('alias proof order/key/encoding mismatch')
        for field in ('bindings_before', 'bindings_after', 'samplers_before', 'samplers_after', 'aliases'):
            _range(proof[field], 'alias proof ' + field, 0, 65536)
        if not isinstance(proof['bindings'], list) or len(proof['bindings']) != proof['bindings_before']:
            raise ValueError('alias binding proof count mismatch')
        metadata = proof['input_metadata']
        if not isinstance(metadata, dict) or set(metadata) not in ({'chain_metal'}, {'chain_metal', 'fetch'}):
            raise ValueError('unsupported alias input metadata')
        source_bytes = (destination / (prefix + key + '_b.metal')).read_bytes()
        reflection_bytes = (destination / (prefix + key + '_b.json')).read_bytes()
        reflection = _read_json(reflection_bytes)
        _validate_reflection(reflection)
        if reflection['chain'] != profile['chain'] or reflection['dm_ctl'] != key or 'fetch' in reflection or reflection['chain_metal'] != KIND + '; ' + PROFILE:
            raise ValueError('derived reflection source-only identity mismatch')
        if reflection_bytes != _json(reflection) or not source_bytes or source_bytes.startswith(b'MTLB') or source_bytes != (destination / (prefix + key + '_b.metallib')).read_bytes():
            raise ValueError('derived source/reflection encoding mismatch')
        restored = deepcopy(reflection)
        restored['chain'] = original['chain']
        restored.update(deepcopy(metadata))
        restored['bindings'] = []
        retained, groups = [], {}
        for item in proof['bindings']:
            _record(item, binding_fields, 'alias binding proof')
            kind = item['kind']
            if not isinstance(kind, str) or kind not in BIND_FIELDS:
                raise ValueError('invalid alias binding kind')
            _record(item['source'], BIND_FIELDS[kind], 'alias source')
            binding = dict(item['source'], msl_name=item['name'], msl_type=item['msl_type'], arg_id=item['input_id'], kind=kind)
            restored['bindings'].append(binding)
            source_key = (kind, binding['reg']) if kind in ('samp', 'samp_tex') else None
            canonical = groups.get(source_key) if source_key is not None else None
            if canonical is None:
                canonical = dict(binding, arg_id=len(retained))
                retained.append(canonical)
                if source_key is not None:
                    groups[source_key] = canonical
            _integer(item['output_id'], 'alias output ID')
            if item['output_name'] != canonical['msl_name'] or item['output_id'] != canonical['arg_id']:
                raise ValueError('alias output is not the exact-source canonical field')
        _validate_reflection(restored)
        if _json(retained) != _json(reflection['bindings']):
            raise ValueError('alias proof/derived binding correspondence mismatch')
        samplers_before = sum(b['kind'] in ('samp', 'samp_tex') for b in restored['bindings'])
        expected_counts = {'bindings_before': len(restored['bindings']), 'bindings_after': len(retained),
                           'samplers_before': samplers_before, 'samplers_after': len(groups),
                           'aliases': len(restored['bindings']) - len(retained)}
        if any(proof[field] != count for field, count in expected_counts.items()) or len(groups) > CAPABILITIES['max_sampler_sources'] or len(retained) > CAPABILITIES['max_bindings']:
            raise ValueError('alias proof counts/resource caps mismatch')
        if 'fetch' in metadata:
            expected_input.add(key + '_bf.metallib')
        source_identity = original['artifacts'].get(key + '_b.metal')
        if source_identity is None or source_identity != original['artifacts'].get(key + '_b.metallib'):
            raise ValueError('canonical source/cache identities differ')
        expected_hashes = {'input_source_sha256': source_identity['sha256'],
                           'output_source_sha256': _digest(source_bytes),
                           'input_reflection_sha256': _digest(_json(restored)),
                           'output_reflection_sha256': _digest(reflection_bytes),
                           'preserved_metadata_sha256': _digest(_json({k: v for k, v in restored.items() if k not in {'bindings', 'chain', 'chain_metal', 'fetch'}}))}
        if any(proof[field] != digest for field, digest in expected_hashes.items()) or proof['input_reflection_sha256'] != original['reflection_semantics'][key]:
            raise ValueError('alias proof input/output semantic digest mismatch')
        source = source_bytes.decode('utf-8')
        if replay:
            result = transform_shader((cache / (key + '_b.metal')).read_bytes().decode('utf-8'),
                                      _read_json((cache / (key + '_b.json')).read_bytes()), profile['chain'])
            if result['source'] != source or _json(result['reflection']) != reflection_bytes or _json(result['proof']) != line:
                raise ValueError('canonical shader transformation replay mismatch: ' + key)
        else:
            checked = transform_shader(source, reflection, original['chain'])
            if checked['source'] != source or checked['proof']['aliases'] != 0:
                raise ValueError('derived source is not a canonical dense argument profile')
            removed = {p['name'] for p in proof['bindings'] if p['name'] != p['output_name']}
            if removed and re.search(r'\b(?:' + '|'.join(map(re.escape, removed)) + r')\b', _mask(source)):
                raise ValueError('removed sampler alias survives in derived code')
        stage = reflection['stage']
        stages[stage] = stages.get(stage, 0) + 1
        proofs.append(proof)
    if set(original['artifacts']) != expected_input:
        raise ValueError('canonical input key/artifact/BF coverage mismatch')
    expected_summary = _corpus(proofs, stages)
    if _json(profile['corpus']) != _json(expected_summary):
        raise ValueError('derived corpus summary differs from per-key facts')
    build_rows = [{'key': key, 'st': 'ok', 'err': ''} for key in keys]
    if (destination / (prefix + '_b_build.json')).read_bytes() != _json(build_rows):
        raise ValueError('derived build rows/key coverage mismatch')
    qualification_artifacts = {name: identity for name, identity in profile['artifacts'].items() if name.startswith(prefix)}
    expected_qualification = {'chain': profile['chain'], 'keys': len(keys), 'kind': KIND,
                              'counts': {'reflection': len(keys), 'msl': len(keys), 'source_cache': len(keys)},
                              'artifacts': [dict(path=name, **identity) for name, identity in sorted(qualification_artifacts.items())]}
    if (destination / 'shader-qualification.json').read_bytes() != _json(expected_qualification):
        raise ValueError('derived qualification/key/artifact coverage mismatch')
    if replay and _json(_input_snapshot(cache, qualification, expected_keys)) != _json(original):
        raise ValueError('canonical input changed during validation replay')
    if _identity(Path(__file__))['sha256'] != provenance['transform_sha256']:
        raise ValueError('transformation code changed during validation')
    for name, identity in profile['artifacts'].items():
        if _identity(destination / name) != identity:
            raise ValueError('derived output changed during validation: ' + name)
    return profile


def validate_derived(destination, *, cache=None, qualification=None, expected_keys=None):
    """Validate all derived claims and witnesses; optional canonical inputs replay every transform.

    Standalone validation checks source grammar, exact-source alias relationships,
    semantic metadata, identities, coverage and aggregate counts. Canonical replay
    additionally proves every output computation against immutable input bytes.
    """
    destination = Path(destination)
    path = destination / 'profile.json'
    identity = _identity(path)
    profile = _read_json(path.read_bytes())
    result = _validate_profile(destination, profile, published=True, cache=cache,
                               qualification=qualification, expected_keys=expected_keys)
    if _identity(path) != identity:
        raise ValueError('published profile changed during validation')
    return result

def derive_cache(cache, qualification, destination, expected_keys, *, capabilities):
    """Publish a new base-only cache and proof in a fresh project .tmp directory.

    Metadata staging is intentionally a separate integration requirement: rerun
    c1_guard.py, bind unchanged shader-map fields, and regenerate/filter PSO seeds
    using the profile's lack of framebuffer fetch before renderer qualification.
    """
    cache, qualification, destination = map(lambda p: Path(p).absolute(), (cache, qualification, destination))
    expected_keys = list(expected_keys)
    if not expected_keys or len(set(expected_keys)) != len(expected_keys):
        raise ValueError('explicit nonempty unique expected keys required')
    if capabilities != CAPABILITIES:
        raise ValueError('explicit capabilities differ from the supported profile')
    tmp = (REPO / '.tmp').resolve()
    if not destination.resolve().is_relative_to(tmp) or destination.resolve() == tmp or destination.is_symlink():
        raise ValueError('derived destination must be a fresh project .tmp child')
    if destination.resolve().is_relative_to(cache.resolve()) or cache.resolve().is_relative_to(destination.resolve()):
        raise ValueError('input/output paths overlap')
    before = _input_snapshot(cache, qualification, expected_keys)
    provenance = {'input': before, 'transform_sha256': _identity(Path(__file__))['sha256'],
                  'profile': PROFILE, 'capabilities': capabilities,
                  'options': deepcopy(OPTIONS)}
    chain = _digest(_json(provenance))[:12]
    if chain == before['chain']:
        raise ValueError('derived chain collided with canonical chain')
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.mkdir(exist_ok=False)
    try:
        target = destination / ('b-' + chain)
        target.mkdir()
        proofs, stages = [], {}
        for key in before['keys']:
            try:
                result = transform_shader((cache / (key + '_b.metal')).read_bytes().decode('utf-8'),
                                          _read_json((cache / (key + '_b.json')).read_bytes()), chain)
            except ValueError as error:
                raise ValueError(key + ': ' + str(error)) from error
            source = result['source'].encode()
            for suffix, raw in (('.metal', source), ('.metallib', source), ('.json', _json(result['reflection']))):
                (target / (key + '_b' + suffix)).write_bytes(raw)
            proofs.append(result['proof'])
            stage = result['reflection']['stage']
            stages[stage] = stages.get(stage, 0) + 1
        (target / '_b_build.json').write_bytes(_json([{'key': key, 'st': 'ok', 'err': ''} for key in before['keys']]))
        (destination / 'alias-proof.jsonl').write_bytes(b''.join(_json(p) for p in proofs))
        artifacts = {str(p.relative_to(destination)): _identity(p) for p in sorted(target.iterdir())}
        qualification_output = {'chain': chain, 'keys': len(proofs), 'kind': KIND,
                                'counts': {'reflection': len(proofs), 'msl': len(proofs), 'source_cache': len(proofs)},
                                'artifacts': [dict(path=name, **identity) for name, identity in artifacts.items()]}
        (destination / 'shader-qualification.json').write_bytes(_json(qualification_output))
        artifacts['alias-proof.jsonl'] = _identity(destination / 'alias-proof.jsonl')
        artifacts['shader-qualification.json'] = _identity(destination / 'shader-qualification.json')
        profile = {'profile': PROFILE, 'chain': chain, 'keys': len(proofs), 'variants': 0,
                   'compiled': False, 'artifacts': artifacts, 'provenance': provenance,
                   'corpus': _corpus(proofs, stages),
                   'metadata_requirements': list(METADATA_REQUIREMENTS),
                   'renderer_qualified': False}
        if _identity(Path(__file__))['sha256'] != provenance['transform_sha256']:
            raise ValueError('transformation implementation changed during derivation')
        if _input_snapshot(cache, qualification, expected_keys) != before:
            raise ValueError('canonical input changed during derivation')
        _validate_profile(destination, profile, published=False, cache=cache,
                          qualification=qualification, expected_keys=expected_keys)
        # Only this exclusive directory is owned by this invocation. The final
        # proof appears atomically after all identities and input checks pass.
        with tempfile.NamedTemporaryFile(dir=destination, prefix='.profile-', delete=False) as stream:
            stream.write(_json(profile))
            temporary = Path(stream.name)
        temporary.replace(destination / 'profile.json')
        if (destination / 'profile.json').read_bytes() != _json(profile):
            raise ValueError('published profile bytes differ from validated proof')
        return profile
    except BaseException:
        shutil.rmtree(destination)
        raise
