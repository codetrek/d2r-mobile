"""Inspect native PSO records through the renderer's compiled serialization API."""

import hashlib
from pathlib import Path
import re
import subprocess


SCHEMA = 'd2r.pso-native-codec.v1'
FIELDS = {
    'pso_skey': {'vs', 'fs', 'vs_stage', 'fs_stage', 'merged', 'fz', 'fz_desc', 'k'},
    'pso_key': {'vs', 'fs', 'cfmt', 'dfmt', 'sfmt', 'samples', 'blend_en', 'chmask',
                'a2c', 'blend', 'attr', 'stream', 'lmap', 'fsfn'},
    'pso_fz_desc': {'kind', 'fbmask', 'fx'},
    'blend_st': set(), 'va_st': set(), 'vs_st': set(),
}
KEY = re.compile(r'[0-9a-f]{16}_bf?')


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _number(value):
    _require(value.isascii() and value.isdecimal(), 'non-decimal native codec integer')
    result = int(value)
    _require(str(result) == value, 'noncanonical native codec integer')
    return result


def parse_output(output, expected_records):
    """Validate the native witness without reconstructing offsets in Python."""
    lines = output.splitlines()
    _require(len(lines) >= 3 and lines[0] == 'SCHEMA\t' + SCHEMA, 'native codec schema')
    abi = lines[1].split('\t')
    _require(len(abi) == 4 and abi[0] == 'ABI' and abi[1] in {'aarch64', 'x86_64'}
             and abi[2] == 'little' and abi[3] == '8', 'native codec ABI')
    layout = {'architecture': abi[1], 'byte_order': abi[2], 'pointer_bytes': 8, 'types': {}}
    records = []
    ended = False
    for ordinal, line in enumerate(lines[2:], 2):
        row = line.split('\t')
        _require(not ended, 'trailing native codec output')
        if row[0] == 'TYPE':
            _require(len(row) == 4 and row[1] in FIELDS and row[1] not in layout['types']
                     and not records, 'native type set/order')
            size, alignment = map(_number, row[2:])
            _require(size > 0 and alignment > 0 and alignment <= size
                     and alignment & (alignment - 1) == 0, 'native type size/alignment')
            layout['types'][row[1]] = {'size': size, 'alignment': alignment, 'fields': {}}
        elif row[0] == 'FIELD':
            _require(len(row) == 5 and row[1] in layout['types'] and row[2] in FIELDS[row[1]]
                     and not records, 'native field set/order')
            item = layout['types'][row[1]]
            _require(row[2] not in item['fields'], 'duplicate native field')
            offset, size = map(_number, row[3:])
            _require(size > 0 and offset + size <= item['size'], 'native field bounds')
            item['fields'][row[2]] = {'offset': offset, 'size': size}
        elif row[0] == 'ROW':
            _require(len(row) == 7 and _number(row[1]) == len(records), 'native record sequence')
            _require(KEY.fullmatch(row[2]) and (not row[3] or KEY.fullmatch(row[3])), 'native shader keys')
            vs_stage, fs_stage, features = map(_number, row[4:])
            _require(vs_stage == 0 and fs_stage == (1 if row[3] else 0) and features <= 7,
                     'native stage/features')
            has_bf = row[2].endswith('_bf') or row[3].endswith('_bf')
            _require(bool(features & 4) == has_bf, 'native feature/key disagreement')
            records.append({'vs': row[2], 'fs': row[3], 'vs_stage': vs_stage,
                            'fs_stage': fs_stage, 'features': features})
        elif row[0] == 'END':
            _require(len(row) == 2 and _number(row[1]) == len(records) == expected_records
                     and ordinal == len(lines) - 1, 'native completion/count')
            ended = True
        else:
            raise ValueError('unknown native codec output record')
    _require(ended and set(layout['types']) == set(FIELDS), 'incomplete native codec witness')
    for name, item in layout['types'].items():
        _require(set(item['fields']) == FIELDS[name], 'incomplete native fields: ' + name)
        end = 0
        for field in sorted(item['fields'].values(), key=lambda value: value['offset']):
            _require(field['offset'] >= end, 'overlapping native fields')
            end = field['offset'] + field['size']
    return {'schema': SCHEMA, 'layout': layout, 'records': records}


def inspect_keys(codec, codec_sha256, render_keys):
    """Run one exact owned codec; malformed input or witness is an error."""
    render_keys = tuple(render_keys)
    codec = Path(codec)
    _require(re.fullmatch(r'[0-9a-f]{64}', codec_sha256), 'explicit native codec digest required')
    _require(codec.is_file() and not codec.is_symlink(), 'native codec must be a regular file')
    _require(hashlib.sha256(codec.read_bytes()).hexdigest() == codec_sha256, 'native codec identity')
    for key in render_keys:
        _require(isinstance(key, str) and re.fullmatch(r'[0-9a-fA-F]+', key), 'native input hex')
    payload = ''.join(key + '\n' for key in render_keys).encode('ascii')
    result = subprocess.run([str(codec.resolve())], input=payload, capture_output=True, timeout=30, check=True)
    _require(hashlib.sha256(codec.read_bytes()).hexdigest() == codec_sha256, 'native codec changed during inspection')
    _require(not result.stderr, 'unexpected native codec diagnostics')
    return parse_output(result.stdout.decode('ascii'), len(render_keys))
