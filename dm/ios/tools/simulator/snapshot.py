"""Bounded source/input snapshots and complete file-set verification."""

import os
from pathlib import Path
import shutil
import subprocess

from shaders import sha

MAX_FILES = 30000
MAX_FILE_BYTES = 256 << 20
MAX_TOTAL_BYTES = 4 << 30


def tree_files(root, link_root=None):
    root = Path(root)
    paths = []
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            if (link_root is None or not path.resolve(strict=True).is_relative_to(Path(link_root).resolve())
                    or not path.is_file()):
                raise ValueError('snapshot input contains an unbound symlink: ' + str(path))
        if path.is_file():
            paths.append((str(path.relative_to(root)), path))
    return paths


def copy_tree_owned(source, destination):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=False)
    for name, path in tree_files(source):
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)


def capture(entries, destination):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=False)
    files, origins, total = {}, {}, 0
    for name, source in entries:
        relative, source = Path(name), Path(source)
        if (relative.is_absolute() or '..' in relative.parts or str(relative) != name
                or name in files or source.is_symlink()):
            raise ValueError('invalid or duplicate snapshot input: ' + str(name))
        before = source.stat()
        total += before.st_size
        if len(files) >= MAX_FILES or before.st_size > MAX_FILE_BYTES or total > MAX_TOTAL_BYTES:
            raise ValueError('snapshot input exceeds resource bounds')
        target = destination / relative
        if target.exists():
            raise ValueError('snapshot output path collision: ' + name)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        digest = sha(target)
        after = source.stat()
        identity = lambda st: (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns)
        if identity(before) != identity(after) or digest != sha(source):
            raise ValueError('input changed during snapshot: ' + str(source))
        target.chmod(0o444)
        files[name] = dict(size=before.st_size, sha256=digest)
        origins[name] = str(source.resolve())
    if not files:
        raise ValueError('snapshot input set is empty')
    return dict(files=files, origins=origins, bytes=total)


def verify(root, proof, originals=False):
    actual = dict(tree_files(root, proof.get('link_root')))
    if set(actual) != set(proof['files']):
        raise ValueError('snapshot file set changed')
    for name, identity in proof['files'].items():
        path = actual[name]
        expected_link = identity.get('link_target')
        actual_link = str(path.resolve(strict=True)) if path.is_symlink() else None
        if actual_link != expected_link:
            raise ValueError('snapshot symlink target changed: ' + name)
        if path.stat().st_size != identity['size'] or sha(path) != identity['sha256']:
            raise ValueError('snapshot identity changed: ' + name)
        if originals and sha(proof['origins'][name]) != identity['sha256']:
            raise ValueError('original input changed: ' + name)


def fingerprint(root, link_root=None):
    files = tree_files(root, link_root)
    if not files or len(files) > MAX_FILES:
        raise ValueError('staged file set is empty or exceeds bounds')
    proof = dict(files={name: dict(size=p.stat().st_size, sha256=sha(p),
                                  **({'link_target': str(p.resolve())} if p.is_symlink() else {}))
                        for name, p in files})
    if link_root is not None:
        proof['link_root'] = str(Path(link_root).resolve())
    return proof


def verify_package(root, resources, generated_files):
    actual = dict(tree_files(root))
    if set(actual) != set(resources['files']) | set(generated_files):
        raise ValueError('final package file set changed')
    for name, identity in resources['files'].items():
        path = actual[name]
        if path.stat().st_size != identity['size'] or sha(path) != identity['sha256']:
            raise ValueError('final package resource identity changed: ' + name)


def package_resources(source, destination, resources, generated_files):
    verify(source, resources)
    for name in resources['files']:
        target = Path(destination) / name
        if target.exists():
            raise ValueError('generated and derived package paths collide: ' + name)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(Path(source) / name, target)
    verify_package(destination, resources, generated_files)


def source(repo, destination):
    repo = Path(repo)
    scopes = ['dm']
    names = subprocess.check_output(['git', '-C', repo, 'ls-files', '--cached', '--others',
                                     '--exclude-standard', '-z', *scopes]).split(b'\0')
    names = sorted({os.fsdecode(name) for name in names if name})
    entries = [(name, repo / name) for name in names]
    revision = subprocess.check_output(['git', '-C', repo, 'rev-parse', 'HEAD'], text=True).strip()
    diff = subprocess.check_output(['git', '-C', repo, 'diff', '--binary'])
    import hashlib
    proof = capture(entries, destination)
    proof.update(revision=revision, diff_sha256=hashlib.sha256(diff).hexdigest(),
                 scope=scopes, includes_untracked_inputs=True)
    verify(destination, proof, originals=True)
    return proof
