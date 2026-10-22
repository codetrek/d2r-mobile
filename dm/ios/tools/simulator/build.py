#!/usr/bin/env python3
"""Build a distinct ARM64 iOS Simulator app from explicit, read-only derived inputs."""

import argparse
import copy
from contextlib import suppress
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

sys.dont_write_bytecode = True
from shaders import sha
from inputs import validate_donor
import snapshot

IOS = Path(__file__).resolve().parents[2]
DM = IOS.parent
REPO = DM.parent
TARGET = 'DmIOSSimulator'


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def run(argv, root, env, name, capture=False, *, cwd):
    print('[simulator] ' + name, flush=True)
    output = []
    with (root / 'logs' / (name + '.log')).open('wb', buffering=0) as log:
        process = subprocess.Popen([str(x) for x in argv], env=env, cwd=cwd,
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
            with suppress(ProcessLookupError):
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


def project(base, root, chain, bundle_id, ios):
    target = copy.deepcopy(base['targets']['DmIOS'])
    target.pop('preBuildScripts')
    target.pop('entitlements')
    target['sources'] = [str(p) for p in sorted((ios / 'Sources').rglob('*'))
                         if p.suffix in ('.c', '.m', '.h', '.S') and p.name != 'dm_touch_native_art.c']
    target['sources'] += [str(ios / 'Assets.xcassets'), dict(path='Gen/src'),
                         dict(path='Gen/main/main.c', compilerFlags='-Dmain=dm_main'),
                         dict(path='Gen/native/dm_touch_native_art.c')]
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
                    '" -iquote "' + str(ios / 'Sources') + '"')
    return dict(name=TARGET, options=dict(deploymentTarget=dict(iOS='26.0')),
                configFiles={c: 'Gen/dm.xcconfig' for c in ('Release', 'Debug')},
                targets={TARGET: target}, schemes={TARGET: dict(build=dict(targets={TARGET: 'all'}))})


def native_art(app, destination, ios):
    generator = module('simulator_native_art', ios / 'tools/native_art/generate.py')
    manifest = json.loads((ios / 'Sources/TouchArt/native_art_manifest.json').read_text())
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
    generated = generator.write_source(rows, manifest, destination).encode()
    return dict(rows=len(rows), descriptor_index_sha256=manifest['descriptor_index_sha256'],
                generated_source_sha256=hashlib.sha256(generated).hexdigest(), generated_source_size=len(generated),
                producer_sha256=sha(ios / 'tools/native_art/generate.py'),
                input_sha256=sha(app / 'dm/derived.tsv'))


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
    original_inputs = {name: getattr(args, name).resolve() for name in
                       ('modules', 'app_resources', 'tables', 'shader_cache', 'shader_manifest', 'shader_metadata')}
    for name in ('shader_profile', 'profile_metadata'):
        value = getattr(args, name)
        if value is not None:
            original_inputs[name] = value.resolve()
    for path in original_inputs.values():
        if root.is_relative_to(path) or path.is_relative_to(root):
            raise ValueError('output overlaps a declared input')
    root.mkdir(parents=True, exist_ok=False)
    for path in ('logs', 'tmp', 'Gen', 'Gen/include', 'Gen/native', 'resources'):
        (root / path).mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, DEVELOPER_DIR=str(args.developer_dir), TMPDIR=str(root / 'tmp'),
               CLANG_MODULE_CACHE_PATH=str(root / 'clang-cache'), PYTHONUNBUFFERED='1',
               PYTHONPYCACHEPREFIX=str(root / 'pycache'), NSUnbufferedIO='YES')
    tool_paths = [Path(sys.executable).resolve(), Path(shutil.which('xcodegen')).resolve(),
                  Path('/usr/bin/codesign')]
    for name in ('clang', 'ld', 'xcodebuild'):
        tool_paths.append(Path(subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--find', name],
                                                     env=env, text=True).strip()).resolve())
    tool_inputs = {str(path): sha(path) for path in tool_paths}
    if args.shader_mode == 'derived-profile':
        tool_inputs[str(Path(args.validation_python).resolve())] = sha(Path(args.validation_python).resolve())
    source_root = root / 'inputs/source'
    source_proof = snapshot.source(REPO, source_root)
    dm, ios = source_root / 'dm', source_root / 'dm/ios'
    frozen_profiles = module('simulator_frozen_profile_inputs', ios / 'tools/simulator/profile_inputs.py')
    frozen_profiles.selected_inputs(args)
    groups = {}
    selected = {}
    for name, source in original_inputs.items():
        destination = root / 'inputs' / name
        if name == 'shader_manifest':
            entries = [(source.name, source)]
        elif name == 'modules':
            entries = [(m + s, source / (m + s)) for m in ('main', 'sdk')
                       for s in ('.patched.bin', '.fixups.tsv', '.gates.tsv')]
        elif name == 'tables':
            entries = [(n, source / n) for n in ('dm_hud_exp.h', 'dm_vault_tab.h', 'dm_bright_levels.inc')]
        elif name in {'shader_metadata', 'profile_metadata'}:
            entries = [(n, source / n) for n in ('shader_map.tsv', 'pso_manifest.tsv', 'c1_full.tsv')]
            if name == 'profile_metadata':
                if set(p.name for p in source.iterdir()) != frozen_profiles.METADATA_FILES:
                    raise ValueError('profile metadata must contain exactly four files')
                entries.append(('metadata-profile.json', source / 'metadata-profile.json'))
        elif name == 'app_resources':
            excluded = {'DmIOS', 'Info.plist', 'PkgInfo', 'Frameworks', '_CodeSignature',
                        'embedded.mobileprovision', 'Assets.car', 'msl', 'save_ref', 'save_ref_warlock',
                        'Extensions', 'PlugIns'}
            entries = [(n, p) for n, p in snapshot.tree_files(source)
                       if Path(n).parts[0] not in excluded and not Path(n).name.startswith('AppIcon')]
            entries.append(('Frameworks/Guest.framework/Guest', source / 'Frameworks/Guest.framework/Guest'))
        else:
            entries = snapshot.tree_files(source)
            destination /= source.name
        groups[name] = snapshot.capture(entries, destination)
        selected[name] = destination / source.name if name == 'shader_manifest' else destination
    args = copy.copy(args)
    for name, path in selected.items():
        setattr(args, name, path)
    app = args.app_resources
    product = dict(line.split('=', 1) for line in (app / 'dm/shell_info.txt').read_text().splitlines() if '=' in line)
    if product['PRODUCT'] != (dm / 'PRODUCT').read_text().strip():
        raise ValueError('derived app resources and source PRODUCT differ')
    donor_proof = validate_donor(app, args.modules)
    resource_bindings = {}
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
        files = [p for p in path.rglob('*') if p.is_file()] if path.is_dir() else [path]
        for item in files:
            name = str(item.relative_to(app))
            resource_bindings[name] = groups['app_resources']['files'][name]
        if path.is_dir():
            snapshot.copy_tree_owned(path, dst)
            source_inputs.update({str(p): sha(p) for p in path.rglob('*') if p.is_file()})
        else:
            shutil.copyfile(path, dst)
            source_inputs[str(path)] = sha(path)
    frozen_shaders = module('simulator_frozen_shaders', ios / 'tools/simulator/shaders.py')
    admission = None
    metadata = args.shader_metadata
    for module_name in ('main', 'sdk'):
        for suffix in ('.fixups.tsv', '.gates.tsv'):
            name = module_name + suffix
            resource_bindings['dm/' + name] = groups['modules']['files'][name]
            shutil.copyfile(args.modules / name, root / 'resources/dm' / name)
    if args.shader_mode == 'derived-profile':
        admission = frozen_profiles.admit(
            source_root, args.shader_cache, args.shader_manifest, args.shader_metadata,
            args.shader_profile, args.profile_metadata, args.metadata_descriptor_sha256,
            args.validation_python, root / 'profile-admission', args.developer_dir,
            lambda argv, cwd: run(argv, root, env, 'profile-admission', cwd=cwd))
        metadata = args.profile_metadata
        chain = admission['chain']
        shader_proof = frozen_shaders.stage_profile(args.shader_profile, admission,
                                                    root / 'resources/msl' / ('b-' + chain))
    else:
        expected = {line.split('\t')[3] for line in (metadata / 'shader_map.tsv').read_text().splitlines()
                    if line and not line.startswith(('#', 'package\t'))}
        fetch = module('simulator_dmsh_fetch', dm / 'gfx/tools/dmsh_fetch.py')
        bf_want = {line.strip() for line in (dm / 'gfx/nvn/bf_want.tsv').read_text().splitlines()
                   if line.strip() and not line.lstrip().startswith('#')}
        chain = json.loads(args.shader_manifest.read_text())['chain']
        shader_proof = frozen_shaders.stage(args.shader_cache, args.shader_manifest, root / 'resources/msl' / ('b-' + chain),
                                            fetch.variant, bf_want, expected)
    for name in shader_proof['identities']:
        if name.endswith(('.json', '.metallib')) and name != '_b_build.json':
            identity = (groups['shader_profile']['files']['b-' + chain + '/' + name] if admission is not None
                        else groups['shader_cache']['files'][name])
            resource_bindings['msl/b-' + chain + '/' + name] = identity
    metadata_stage = frozen_profiles.stage_metadata(
        metadata, groups['profile_metadata' if admission is not None else 'shader_metadata']['files'],
        root / 'resources/dm', profile=args.shader_profile if admission is not None else None,
        profile_identity=groups['shader_profile']['files']['profile.json'] if admission is not None else None)
    resource_bindings.update(metadata_stage['resources'])
    source_inputs.update(metadata_stage['sources'])
    if not (metadata / 'c1_full.tsv').read_text().startswith('# chain b-' + chain + ' '):
        raise ValueError('C1 metadata does not match the source shader chain')
    art_proof = native_art(app, root / 'Gen/native/dm_touch_native_art.c', ios)
    generated_bindings = {'native/dm_touch_native_art.c': dict(
        size=art_proof['generated_source_size'],
        sha256=art_proof['generated_source_sha256'])}
    config = run([sys.executable, ios / 'tools/gen_build.py', dm / 'host', root / 'Gen'], root, env, 'host-inputs', True, cwd=ios)
    config = config.replace('HEADER_SEARCH_PATHS = $(inherited) ',
                            'HEADER_SEARCH_PATHS = $(inherited) "' + str(root / 'Gen/include') + '" ', 1)
    config += 'OTHER_LDFLAGS = $(inherited) $(DM_FRAMEWORKS)\n'
    profile = frozen_profiles.constants(chain, admission,
                                         compiler_contract=frozen_profiles.library_contract_source(source_root))
    for name, content in (('dm.xcconfig', config), ('profile.h', profile)):
        data = content.encode()
        generated_bindings[name] = dict(size=len(data), sha256=hashlib.sha256(data).hexdigest())
        (root / 'Gen' / name).write_bytes(data)
    for name in ('dm_hud_exp.h', 'dm_vault_tab.h', 'dm_bright_levels.inc'):
        for target in ('Gen/include', 'Gen/src'):
            generated_bindings[target[4:] + '/' + name] = groups['tables']['files'][name]
            shutil.copyfile(args.tables / name, root / target / name)
    base_path = root / 'base-project.json'
    run(['xcodegen', 'dump', '--no-env', '--type', 'json', '--spec', ios / 'project.yml', '--file', base_path], root, env, 'project-input', cwd=ios)
    spec = project(json.loads(base_path.read_text()), root, chain, args.bundle_id, ios)
    spec_path = root / 'project.json'
    spec_path.write_text(json.dumps(spec, indent=2) + '\n')
    guest = module('simulator_guest_dylib', dm / 'tools/guest_dylib.py')
    fw, _ = guest.write(args.modules, root / 'frameworks', ['main', 'sdk'],
                        bundle_id=args.bundle_id + '.guest', platform=guest.Platform.IOS_SIMULATOR)
    framework_proof = inspect_platform(Path(fw) / 'Guest', 6)
    run(['xcodegen', 'generate', '--spec', spec_path, '--project', root], root, env, 'project-generate', cwd=ios)
    resource_proof = dict(files=resource_bindings)
    snapshot.verify(root / 'resources', resource_proof)
    for name, identity in generated_bindings.items():
        if sha(root / 'Gen' / name) != identity['sha256']:
            raise ValueError('generated or copied source identity changed: ' + name)
    staged_proof = {name: snapshot.fingerprint(root / name, source_root if name == 'Gen' else None)
                    for name in ('Gen', 'resources', 'frameworks', TARGET + '.xcodeproj')}
    project_inputs = {name: sha(root / name) for name in ('project.json', 'base-project.json')}
    run(['xcodebuild', '-project', root / (TARGET + '.xcodeproj'), '-scheme', TARGET,
         '-configuration', 'Release', '-sdk', 'iphonesimulator', '-destination', 'generic/platform=iOS Simulator',
         '-derivedDataPath', root / 'dd', '-jobs', str(args.jobs), 'build'], root, env, 'app-build', cwd=ios)
    result = root / 'dd/Build/Products/Release-iphonesimulator' / (TARGET + '.app')
    platform_files = snapshot.fingerprint(result)
    snapshot.package_resources(root / 'resources', result, resource_proof, platform_files['files'])
    frameworks = result / 'Frameworks'
    frameworks.mkdir(exist_ok=True)
    shutil.copytree(fw, frameworks / 'Guest.framework')
    run(['codesign', '--force', '--sign', '-', frameworks / 'Guest.framework'], root, env, 'sign-framework', cwd=ios)
    run(['codesign', '--force', '--sign', '-', result], root, env, 'sign-app', cwd=ios)
    app_proof = inspect_platform(result / TARGET, 2)
    signed_guest_proof = inspect_platform(frameworks / 'Guest.framework/Guest', 6)
    final_donor_proof = validate_donor(result, args.modules)
    if sha(frameworks / 'Guest.framework/Info.plist') != sha(Path(fw) / 'Info.plist'):
        raise ValueError('final Guest framework metadata differs from the generated profile')
    generated_files = set(platform_files['files']) | {
        'Frameworks/Guest.framework/' + name for name in ('Guest', 'Info.plist', '_CodeSignature/CodeResources')}
    snapshot.verify_package(result, resource_proof, generated_files)
    final_app_inventory = snapshot.fingerprint(result)
    for path, digest in source_inputs.items():
        if sha(path) != digest:
            raise ValueError('build input changed: ' + path)
    snapshot.verify(source_root, source_proof, originals=True)
    for name, proof in groups.items():
        base = selected[name].parent if name == 'shader_manifest' else selected[name]
        snapshot.verify(base, proof, originals=True)
    for name, proof in staged_proof.items():
        snapshot.verify(root / name, proof)
    for path, digest in tool_inputs.items():
        if sha(path) != digest:
            raise ValueError('build tool changed: ' + path)
    for name, digest in project_inputs.items():
        if sha(root / name) != digest:
            raise ValueError('generated project input changed: ' + name)
    manifest = dict(schema='d2r.ios-simulator-build.v3', state='built_unexecuted', profile=shader_proof['profile'],
                    source_revision=source_proof['revision'], source_diff_sha256=source_proof['diff_sha256'],
                    source_snapshot=source_proof, input_snapshots=groups, staged_inputs=staged_proof,
                    tool_inputs=tool_inputs, project_inputs=project_inputs,
                    resource_bindings=resource_proof, generated_source_bindings=generated_bindings,
                    final_app_inventory=final_app_inventory, final_bundled_modules=final_donor_proof,
                    source_inputs=source_inputs, app=str(result), app_identity=app_proof,
                    generated_guest_identity=framework_proof, guest_identity=signed_guest_proof,
                    shaders=shader_proof, shader_mode=args.shader_mode, profile_admission=admission,
                    renderer_profile_activated=False, native_art=art_proof, donor=donor_proof,
                    simulator_device_created=False, guest_executed=False)
    (root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(dict(app=str(result), profile=shader_proof['profile'], state='built_unexecuted')), flush=True)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('modules', 'app-resources', 'tables', 'shader-cache', 'shader-manifest', 'shader-metadata', 'out'):
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--shader-mode', required=True, choices=('canonical', 'derived-profile'))
    for name in ('shader-profile', 'profile-metadata', 'validation-python'):
        parser.add_argument('--' + name, type=Path)
    parser.add_argument('--metadata-descriptor-sha256')
    parser.add_argument('--developer-dir', type=Path, default=Path('/Applications/Xcode.app/Contents/Developer'))
    parser.add_argument('--bundle-id', default='org.d2rmobile.simulator')
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    if not 1 <= args.jobs <= 8:
        parser.error('--jobs must be between1 and8')
    build(args)


if __name__ == '__main__':
    main()
