"""Build an owned CPU codec and witness its actual ARM64 compiler layout."""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

import pso_native


REPO = Path(__file__).resolve().parents[4]
SOURCES = ('dm/ios/tools/simulator/pso_codec.c', 'dm/gfx/nvn/nvn_pso_profile.h',
           'dm/gfx/nvn/nvn_pso_wire.h', 'dm/gfx/nvn/nvn_obj.h',
           'dm/gfx/nvn/nvn_tex.h', 'dm/gfx/nvn/include/nvn.h')


def encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True) + '\n').encode()


def identity(path):
    path = Path(path)
    if not path.is_file() or path.is_symlink():
        raise ValueError('expected a regular, non-symlink input: ' + str(path))
    raw = path.read_bytes()
    return {'size': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}


def digest(value):
    return hashlib.sha256(encoded(value)).hexdigest()


class NativeCodec:
    """A fresh actual executable; historical executable bytes are not replay claims."""

    def __init__(self, work, developer_dir):
        self.work = Path(work)
        self.work.mkdir(parents=True, exist_ok=False)
        self.environment = dict(os.environ, DEVELOPER_DIR=str(developer_dir), TMPDIR=str(self.work),
                                CLANG_MODULE_CACHE_PATH=str(self.work / 'clang-cache'), LC_ALL='C')
        self.commands = []
        self.dependencies = {}
        self.source_identities = {name: identity(REPO / name) for name in SOURCES}
        for name in SOURCES:
            target = self.work / 'source' / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / name, target)
            target.chmod(0o444)
        self.clang = Path(self._run(['xcrun', '--find', 'clang']).decode().strip()).resolve()
        self.compiler = identity(self.clang)
        version = self._run([self.clang, '--version']).decode()
        resource = Path(self._run([self.clang, '-print-resource-dir']).decode().strip()).resolve()
        sdkroots = {sdk: Path(self._run(['xcrun', '--sdk', sdk, '--show-sdk-path']).decode().strip()).resolve()
                    for sdk in ('macosx', 'iphonesimulator')}
        simulator_version = self._run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version']).decode().strip()
        if not re.fullmatch(r'\d+\.\d+(?:\.\d+)?', simulator_version):
            raise ValueError('invalid Simulator SDK version')
        targets = {'macosx': 'arm64-apple-macos15.0',
                   'iphonesimulator': 'arm64-apple-ios' + simulator_version + '-simulator'}
        layouts, dependencies = {}, {}
        source = self.work / 'source' / SOURCES[0]
        for sdk, sdkroot in sdkroots.items():
            flags = ['-target', targets[sdk], '-isysroot', sdkroot, '-std=c11', '-O2',
                     '-Wall', '-Wextra', '-Werror', '-I', self.work / 'source/dm/gfx/nvn/include']
            base = [self.clang, *flags]
            raw = self._run([*base, '-M', source]).decode()
            # clang escapes spaces and backslashes in make dependencies.
            import shlex
            names = shlex.split(raw.split(': ', 1)[1].replace('\\\n', ' '))
            found = {}
            for name in names:
                path = Path(name).resolve()
                original = Path(name)
                item = identity(original)
                self.dependencies[str(original)] = item
                if path.is_relative_to((self.work / 'source').resolve()):
                    key = 'source/' + str(path.relative_to((self.work / 'source').resolve()))
                elif path.is_relative_to(sdkroot):
                    key = 'sdk/' + str(path.relative_to(sdkroot))
                elif path.is_relative_to(resource):
                    key = 'clang/' + str(path.relative_to(resource))
                else:
                    raise ValueError('unbound native compiler dependency: ' + str(path))
                if key in found:
                    raise ValueError('duplicate native compiler dependency')
                found[key] = item
            dependencies[sdk] = found
            raw = self._run([*base, '-Xclang', '-fdump-record-layouts-complete', '-fsyntax-only', source])
            (self.work / (sdk + '-layout.txt')).write_bytes(raw)
            records = [block.strip().replace(str(self.work / 'source') + '/', '')
                       for block in raw.decode().split('*** Dumping AST Record Layout\n')
                       if re.search(r'/nvn_(?:pso_wire|obj)\.h:', block.split('\n', 1)[0])]
            if not records:
                raise ValueError('compiler did not witness the native PSO records')
            layouts[sdk] = records
            if sdk == 'macosx':
                self.binary = self.work / 'pso-codec'
                self._run([*base, source, '-o', self.binary])
        if layouts['macosx'] != layouts['iphonesimulator']:
            raise ValueError('host and Simulator native PSO ABI differ')
        self.binary_identity = identity(self.binary)
        self.layout = self.inspect([])['layout']
        if self.layout['architecture'] != 'aarch64':
            raise ValueError('native codec must execute the intended ARM64 ABI')
        self.contract = {'schema': 'd2r.pso-native-toolchain.v1', 'sources': self.source_identities,
                         'compiler': self.compiler, 'compiler_version': version,
                         'targets': targets, 'flags': ['-std=c11', '-O2', '-Wall', '-Wextra', '-Werror'],
                         'dependencies': dependencies, 'native_layout': self.layout,
                         'cross_target_records': len(layouts['macosx']),
                         'cross_target_layout_sha256': digest(layouts['macosx'])}
        self.verify()
        (self.work / 'compile-receipt.json').write_bytes(encoded({
            'contract': self.contract, 'actual_binary': self.binary_identity,
            'commands': self.commands, 'historical_binary_reproducibility_claimed': False}))

    def _run(self, arguments):
        arguments = [str(value) for value in arguments]
        result = subprocess.run(arguments, env=self.environment, capture_output=True, timeout=120, check=True)
        self.commands.append({'argv': arguments, 'stdout_sha256': hashlib.sha256(result.stdout).hexdigest(),
                              'stderr_sha256': hashlib.sha256(result.stderr).hexdigest()})
        if result.stderr:
            raise ValueError('native compiler emitted diagnostics: ' + result.stderr.decode())
        return result.stdout

    def verify(self):
        if identity(self.clang) != self.compiler:
            raise ValueError('native compiler changed')
        for name, value in self.source_identities.items():
            if identity(REPO / name) != value or identity(self.work / 'source' / name) != value:
                raise ValueError('native codec source changed: ' + name)
        for name, value in self.dependencies.items():
            if identity(name) != value:
                raise ValueError('native compiler dependency changed: ' + name)
        if hasattr(self, 'binary_identity') and identity(self.binary) != self.binary_identity:
            raise ValueError('native codec changed')

    def inspect(self, keys):
        self.verify()
        result = pso_native.inspect_keys(self.binary, self.binary_identity['sha256'], keys)
        self.verify()
        return result
