"""Validate and stage an explicit source-MSL cache for the simulator."""

import hashlib
import json
from pathlib import Path
import re
import shutil


PROFILE = 'ios-simulator-arm64-m3-source-v1'
KEY = re.compile(r'[0-9a-f]{16}')
CHAIN = re.compile(r'[0-9a-f]{12}')


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def validate(cache, manifest, fetch_variant, bf_want, expected_keys):
    cache = Path(cache)
    proof = json.loads(Path(manifest).read_text())
    chain = proof['chain']
    if not CHAIN.fullmatch(chain) or cache.name != 'b-' + chain:
        raise ValueError('source cache directory/chain mismatch')
    if proof['kind'] != 'translated MSL source; Metal compilation and execution not performed':
        raise ValueError('expected an explicitly qualified source-MSL cache')
    actual = {p.name for p in cache.iterdir() if p.is_file()}
    identities = {}
    for item in proof['artifacts']:
        name = Path(item['path']).name
        parts = Path(item['path']).parts
        if (name in identities or Path(item['path']).is_absolute() or '..' in parts
                or len(parts) < 2 or parts[-2] != cache.name or name not in actual):
            raise ValueError('duplicate or missing source artifact: ' + name)
        path = cache / name
        if path.stat().st_size != item['size'] or sha(path) != item['sha256']:
            raise ValueError('source artifact identity mismatch: ' + name)
        identities[name] = item['sha256']
    if actual != set(identities):
        raise ValueError('source cache artifact set differs from qualification manifest')
    rows = json.loads((cache / '_b_build.json').read_text())
    keys = [row['key'] for row in rows]
    if not keys or len(set(keys)) != len(keys) or any(not KEY.fullmatch(k) for k in keys):
        raise ValueError('source shader key set is empty, duplicate or invalid')
    if not expected_keys or set(keys) != set(expected_keys):
        raise ValueError('source shader keys differ from the explicit shader map')
    if any(row['st'] != 'ok' or row['err'] for row in rows) or proof['keys'] != len(keys):
        raise ValueError('source shader translation was incomplete')
    expected = {'_b_build.json'}
    libraries = []
    for key in keys:
        base = key + '_b'
        expected.update(base + suffix for suffix in ('.json', '.metal', '.metallib'))
        reflection = json.loads((cache / (base + '.json')).read_text())
        if reflection['chain'] != chain or reflection['key'] != base or reflection['drv_unfillable']:
            raise ValueError('source shader reflection mismatch: ' + key)
        source = (cache / (base + '.metal')).read_text()
        raw = (cache / (base + '.metallib')).read_bytes()
        if not raw or raw.startswith(b'MTLB') or raw != source.encode():
            raise ValueError('expected exact source MSL, not a compiled library: ' + key)
        if not re.search(r'\b' + re.escape(reflection['entry']) + r'\s*\(', source):
            raise ValueError('source MSL entry is missing: ' + key)
        variant, metadata = (fetch_variant(source, reflection['bindings'], om_only_ok=key in bf_want)
                             if reflection['stage'] == 'ps' else (None, None))
        if variant:
            variant_name = key + '_bf.metallib'
            expected.add(variant_name)
            if reflection.get('fetch') != metadata or (cache / variant_name).read_bytes() != variant.encode():
                raise ValueError('BF source/reflection does not match current generator: ' + key)
            libraries.append(variant_name)
        elif 'fetch' in reflection:
            raise ValueError('unexpected BF reflection: ' + key)
        libraries.append(base + '.metallib')
    if actual != expected:
        raise ValueError('source/reflection/BF expected-set mismatch')
    if proof['counts'] != dict(reflection=len(keys), msl=len(keys), source_cache=len(libraries)):
        raise ValueError('source-MSL coverage counts differ')
    return dict(profile=PROFILE, chain=chain, keys=len(keys), libraries=len(libraries),
                variants=len(libraries) - len(keys), identities=identities,
                qualification_sha256=sha(manifest), compiled=False)


def stage(cache, manifest, destination, fetch_variant, bf_want, expected_keys):
    proof = validate(cache, manifest, fetch_variant, bf_want, expected_keys)
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=False)
    for name in proof['identities']:
        if name.endswith(('.json', '.metallib')) and name != '_b_build.json':
            shutil.copyfile(Path(cache) / name, destination / name)
    return proof
