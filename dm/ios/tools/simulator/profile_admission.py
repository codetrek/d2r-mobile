"""CPU-only admission worker, executed from an isolated frozen tool closure."""

import argparse
from pathlib import Path
import sys

sys.dont_write_bytecode = True
import profile_metadata
from pso_toolchain import digest, encoded, identity


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('canonical-cache', 'qualification', 'canonical-metadata', 'profile', 'metadata', 'work', 'result', 'developer-dir'):
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--descriptor-sha256', required=True)
    args = parser.parse_args()
    descriptor = profile_metadata.validate_metadata(
        args.metadata, args.canonical_cache, args.qualification, args.profile,
        args.canonical_metadata,
        expected_descriptor_sha256=args.descriptor_sha256, work=args.work,
        developer_dir=args.developer_dir)
    profile = profile_metadata.read_json(args.profile / 'profile.json')
    chain = descriptor['provenance']['derived_chain']
    prefix = 'b-' + chain + '/'
    staged = {name: value for name, value in profile['artifacts'].items()
              if name.startswith(prefix) and name.endswith(('_b.json', '_b.metallib'))}
    result = {'schema': 'd2r.simulator-profile-admission.v1', 'chain': chain,
              'source_profile': profile['profile'], 'profile_sha256': identity(args.profile / 'profile.json')['sha256'],
              'metadata_sha256': args.descriptor_sha256, 'metadata_id': descriptor['provenance_id'],
              'native_layout_sha256': digest(descriptor['provenance']['native']['native_layout']),
              'keys': descriptor['provenance']['shader_keys'], 'staged_files': staged,
              'compiled': False, 'executed': False, 'renderer_qualified': False,
              'python': {'sha256': identity(Path(sys.executable).resolve())['sha256'], 'version': sys.version}}
    args.result.write_bytes(encoded(result))


if __name__ == '__main__':
    main()
