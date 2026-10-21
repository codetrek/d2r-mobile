#!/usr/bin/env python3
"""Build a distinct ARM64 iOS Simulator app from explicit, read-only derived inputs."""

import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import selectors
import shutil
import signal
import subprocess
import sys
import time

from shaders import PROFILE, sha, stage

IOS = Path(__file__).resolve().parents[2]
DM = IOS.parent
REPO = DM.parent
TARGET = 'DmIOSSimulator'


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def run(argv, root, env, name, capture=False):
    print('[simulator] ' + name, flush=True)
    output = []
    with (root / 'logs' / (name + '.log')).open('wb', buffering=0) as log:
        process = subprocess.Popen([str(x) for x in argv], env=env, cwd=IOS,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   bufsize=0, start_new_session=True)
        deadline = time.monotonic() + 900
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while selector.get_map():
                    if time.monotonic() >= deadline:
                        raise TimeoutError(name + ' exceeded15 minutes')
                    for key, _ in selector.select(0.5):
                        chunk = os.read(key.fd, 65536)
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        log.write(chunk)
                        if capture:
                            output.append(chunk)
                        else:
                            sys.stdout.buffer.write(chunk)
                            sys.stdout.buffer.flush()
            result = process.wait(timeout=5)
        except BaseException:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise
        finally:
            process.stdout.close()
    if result:
        raise subprocess.CalledProcessError(result, argv)
    if not capture:
        print('[simulator] ' + name + ' complete', flush=True)
    return b''.join(output).decode()


def project(base, root, chain, bundle_id):
    target = copy.deepcopy(base['targets']['DmIOS'])
    target.pop('preBuildScripts')
    target.pop('entitlements')
    target['sources'] = [str(p) for p in sorted((IOS / 'Sources').rglob('*'))
                         if p.suffix in ('.c', '.m', '.h', '.S') and p.name != 'dm_touch_native_art.c']
    target['sources'] += [str(IOS / 'Assets.xcassets'), dict(path='Gen/src'),
                         dict(path='Gen/main/main.c', compilerFlags='-Dmain=dm_main'),
                         dict(path='Gen/native/dm_touch_native_art.c')]
    for item in sorted((root / 'resources').iterdir()):
        target['sources'].append(dict(path=str(item), type='folder' if item.is_dir() else 'file',
                                      buildPhase='resources'))
    target['dependencies'] = [d for d in target['dependencies'] if 'sdk' in d]
    target['info']['path'] = 'Gen/Info.plist'
    properties = target['info']['properties']
    for key in ('BAAppGroupID', 'BAHasManagedAssetPacks', 'BAUsesAppleHosting'):
        properties.pop(key)
    properties['CFBundleDisplayName'] = 'D2R Peer Simulator'
    settings = target['settings']
    settings.update(PRODUCT_BUNDLE_IDENTIFIER=bundle_id, DEVELOPMENT_TEAM='', CODE_SIGN_IDENTITY='-',
                    CODE_SIGN_STYLE='Manual', CODE_SIGNING_REQUIRED='NO',
                    SUPPORTED_PLATFORMS='iphonesimulator', SDKROOT='iphonesimulator', ARCHS='arm64',
                    ONLY_ACTIVE_ARCH='YES', TARGETED_DEVICE_FAMILY='1', DM_DEVICE_FAMILY='1',
                    OTHER_CFLAGS='$(inherited) -mcpu=apple-m1 -include "' + str(root / 'Gen/profile.h') +
                    '" -iquote "' + str(IOS / 'Sources') + '"')
    return dict(name=TARGET, options=dict(deploymentTarget=dict(iOS='26.0')),
                configFiles={c: 'Gen/dm.xcconfig' for c in ('Release', 'Debug')},
                targets={TARGET: target}, schemes={TARGET: dict(build=dict(targets={TARGET: 'all'}))})


def native_art(app, destination):
    generator = module('simulator_native_art', IOS / 'tools/native_art/generate.py')
    manifest = json.loads((IOS / 'Sources/TouchArt/native_art_manifest.json').read_text())
    rows = []
    for line in (app / 'dm/derived.tsv').read_text().splitlines():
        fields = line.split('\t')
        if fields[0] == 'TAROW':
            if len(fields) != 4:
                raise ValueError('invalid native-art derived row')
            rows.append([int(x) for x in fields[1:]])
    for asset in manifest['assets']:
        path = app / asset['asset']
        if sha(path) != asset['decoded_png_sha256']:
            raise ValueError('native-art PNG differs from the frozen original: ' + path.name)
    generator.write_source(rows, manifest, destination)
    return dict(rows=len(rows), descriptor_index_sha256=manifest['descriptor_index_sha256'])


def inspect_platform(path, expected_type):
    import struct
    raw = Path(path).read_bytes()
    if len(raw) < 32 or struct.unpack_from('<IiiI', raw) != (0xfeedfacf, 0x0100000c, 0, expected_type):
        # Executables may carry the arm64 capability bits in cpusubtype.
        if len(raw) < 32 or struct.unpack_from('<Ii', raw) != (0xfeedfacf, 0x0100000c) or struct.unpack_from('<I', raw, 12)[0] != expected_type:
            raise ValueError('expected a thin ARM64 Mach-O: ' + str(path))
    count, size = struct.unpack_from('<II', raw, 16)
    end = 32 + size
    if end > len(raw):
        raise ValueError('truncated Mach-O commands')
    offset = 32
    platforms = []
    for _ in range(count):
        if offset + 8 > end:
            raise ValueError('truncated Mach-O command')
        command, length = struct.unpack_from('<II', raw, offset)
        if length < 8 or offset + length > end:
            raise ValueError('invalid Mach-O command length')
        if command == 0x32:
            if length < 24:
                raise ValueError('invalid build-version command')
            platforms.append(struct.unpack_from('<I', raw, offset + 8)[0])
        offset += length
    if offset != end or platforms != [7]:
        raise ValueError('Mach-O is not explicitly iOS Simulator platform7')
    return dict(architecture='arm64', platform=7, sha256=sha(path))


def build(args):
    root = args.out.resolve()
    if not root.is_relative_to(REPO / '.tmp'):
        raise ValueError('--out must be within this repository .tmp directory')
    root.mkdir(parents=True, exist_ok=False)
    for path in ('logs', 'tmp', 'Gen', 'Gen/include', 'Gen/native', 'resources'):
        (root / path).mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, DEVELOPER_DIR=str(args.developer_dir), TMPDIR=str(root / 'tmp'),
               CLANG_MODULE_CACHE_PATH=str(root / 'clang-cache'), PYTHONUNBUFFERED='1',
               PYTHONPYCACHEPREFIX=str(root / 'pycache'), NSUnbufferedIO='YES')
    app = args.app_resources.resolve()
    product = dict(line.split('=', 1) for line in (app / 'dm/shell_info.txt').read_text().splitlines() if '=' in line)
    if product['PRODUCT'] != (DM / 'PRODUCT').read_text().strip():
        raise ValueError('derived app resources and source PRODUCT differ')
    source_inputs = {str(p): sha(p) for p in [args.shader_manifest, *(args.tables / n for n in
                    ('dm_hud_exp.h', 'dm_vault_tab.h', 'dm_bright_levels.inc')),
                    *(args.modules / (m + suffix) for m in ('main', 'sdk') for suffix in
                      ('.patched.bin', '.fixups.tsv', '.gates.tsv'))]}
    for path in sorted(app.iterdir()):
        if path.name in {'DmIOS', 'Info.plist', 'PkgInfo', 'Frameworks', '_CodeSignature',
                         'embedded.mobileprovision', 'Assets.car', 'msl', 'save_ref', 'save_ref_warlock',
                         'Extensions', 'PlugIns'} or path.name.startswith('AppIcon'):
            continue
        dst = root / 'resources' / path.name
        if path.is_dir():
            shutil.copytree(path, dst)
            source_inputs.update({str(p): sha(p) for p in path.rglob('*') if p.is_file()})
        else:
            shutil.copyfile(path, dst)
            source_inputs[str(path)] = sha(path)
    metadata = args.shader_metadata
    expected = {line.split('\t')[3] for line in (metadata / 'shader_map.tsv').read_text().splitlines()
                if line and not line.startswith(('#', 'package\t'))}
    fetch = module('simulator_dmsh_fetch', DM / 'gfx/tools/dmsh_fetch.py')
    bf_want = {line.strip() for line in (DM / 'gfx/nvn/bf_want.tsv').read_text().splitlines()
               if line.strip() and not line.lstrip().startswith('#')}
    chain = json.loads(args.shader_manifest.read_text())['chain']
    shader_proof = stage(args.shader_cache, args.shader_manifest, root / 'resources/msl' / ('b-' + chain),
                         fetch.variant, bf_want, expected)
    for name in ('shader_map.tsv', 'pso_manifest.tsv', 'c1_full.tsv'):
        source_inputs[str(metadata / name)] = sha(metadata / name)
        shutil.copyfile(metadata / name, root / 'resources/dm' / name)
    if not (metadata / 'c1_full.tsv').read_text().startswith('# chain b-' + chain + ' '):
        raise ValueError('C1 metadata does not match the source shader chain')
    art_proof = native_art(app, root / 'Gen/native/dm_touch_native_art.c')
    config = run([sys.executable, IOS / 'tools/gen_build.py', DM / 'host', root / 'Gen'], root, env, 'host-inputs', True)
    config = config.replace('HEADER_SEARCH_PATHS = $(inherited) ',
                            'HEADER_SEARCH_PATHS = $(inherited) "' + str(root / 'Gen/include') + '" ', 1)
    config += 'OTHER_LDFLAGS = $(inherited) $(DM_FRAMEWORKS)\n'
    (root / 'Gen/dm.xcconfig').write_text(config)
    (root / 'Gen/profile.h').write_text('#define DM_SHELL 1\n#define DM_NVN_M3 1\n#define DM_SIMULATOR_SHADER_CHAIN "' + chain + '"\n')
    for name in ('dm_hud_exp.h', 'dm_vault_tab.h', 'dm_bright_levels.inc'):
        for target in ('Gen/include', 'Gen/src'):
            shutil.copyfile(args.tables / name, root / target / name)
    base_path = root / 'base-project.json'
    run(['xcodegen', 'dump', '--no-env', '--type', 'json', '--spec', IOS / 'project.yml', '--file', base_path], root, env, 'project-input')
    spec = project(json.loads(base_path.read_text()), root, chain, args.bundle_id)
    spec_path = root / 'project.json'
    spec_path.write_text(json.dumps(spec, indent=2) + '\n')
    guest = module('simulator_guest_dylib', DM / 'tools/guest_dylib.py')
    fw, _ = guest.write(args.modules, root / 'frameworks', ['main', 'sdk'],
                        bundle_id=args.bundle_id + '.guest', platform=guest.Platform.IOS_SIMULATOR)
    framework_proof = inspect_platform(Path(fw) / 'Guest', 6)
    run(['xcodegen', 'generate', '--spec', spec_path, '--project', root], root, env, 'project-generate')
    run(['xcodebuild', '-project', root / (TARGET + '.xcodeproj'), '-scheme', TARGET,
         '-configuration', 'Release', '-sdk', 'iphonesimulator', '-destination', 'generic/platform=iOS Simulator',
         '-derivedDataPath', root / 'dd', '-jobs', str(args.jobs), 'build'], root, env, 'app-build')
    result = root / 'dd/Build/Products/Release-iphonesimulator' / (TARGET + '.app')
    frameworks = result / 'Frameworks'
    frameworks.mkdir(exist_ok=True)
    shutil.copytree(fw, frameworks / 'Guest.framework')
    run(['codesign', '--force', '--sign', '-', frameworks / 'Guest.framework'], root, env, 'sign-framework')
    run(['codesign', '--force', '--sign', '-', result], root, env, 'sign-app')
    app_proof = inspect_platform(result / TARGET, 2)
    signed_guest_proof = inspect_platform(frameworks / 'Guest.framework/Guest', 6)
    for path, digest in source_inputs.items():
        if sha(path) != digest:
            raise ValueError('build input changed: ' + path)
    manifest = dict(schema='d2r.ios-simulator-build.v1', state='built_unexecuted', profile=PROFILE,
                    source_revision=subprocess.check_output(['git', '-C', REPO, 'rev-parse', 'HEAD'], text=True).strip(),
                    source_diff_sha256=hashlib.sha256(subprocess.check_output(['git', '-C', REPO, 'diff', '--binary'])).hexdigest(),
                    source_inputs=source_inputs, app=str(result), app_identity=app_proof,
                    generated_guest_identity=framework_proof, guest_identity=signed_guest_proof,
                    shaders=shader_proof, native_art=art_proof,
                    simulator_device_created=False, guest_executed=False)
    (root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(dict(app=str(result), profile=PROFILE, state='built_unexecuted')), flush=True)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('modules', 'app-resources', 'tables', 'shader-cache', 'shader-manifest', 'shader-metadata', 'out'):
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--developer-dir', type=Path, default=Path('/Applications/Xcode.app/Contents/Developer'))
    parser.add_argument('--bundle-id', default='org.d2rmobile.simulator')
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    if not 1 <= args.jobs <= 8:
        parser.error('--jobs must be between1 and8')
    build(args)


if __name__ == '__main__':
    main()
