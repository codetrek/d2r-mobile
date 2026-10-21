"""Validate the relationship between derived modules and the resource donor."""

from pathlib import Path
import struct

from shaders import sha

PAGE = 0x4000
MAX_GUEST_BYTES = 256 << 20


def guest_sections(path):
    path = Path(path)
    if path.stat().st_size > MAX_GUEST_BYTES:
        raise ValueError('Guest container exceeds the inspection bound')
    raw = path.read_bytes()
    if len(raw) < 32 or struct.unpack_from('<IiiI', raw) != (0xfeedfacf, 0x0100000c, 0, 6):
        raise ValueError('donor Guest must be a thin ARM64 dynamic library')
    count, size = struct.unpack_from('<II', raw, 16)
    end = 32 + size
    if count > 1024 or end > len(raw):
        raise ValueError('invalid donor Guest load commands')
    offset = 32
    sections = {}
    for _ in range(count):
        if offset + 8 > end:
            raise ValueError('truncated donor Guest load command')
        command, length = struct.unpack_from('<II', raw, offset)
        if length < 8 or offset + length > end:
            raise ValueError('invalid donor Guest command size')
        if command == 0x19:
            if length < 72:
                raise ValueError('truncated donor Guest segment')
            nsections = struct.unpack_from('<I', raw, offset + 64)[0]
            if nsections > 128 or length != 72 + 80 * nsections:
                raise ValueError('invalid donor Guest section count')
            for index in range(nsections):
                base = offset + 72 + index * 80
                name, segment, _, size, start = struct.unpack_from('<16s16sQQI', raw, base)
                key = (segment.rstrip(b'\0').decode('ascii'), name.rstrip(b'\0').decode('ascii'))
                if key in sections or start + size > len(raw):
                    raise ValueError('duplicate or out-of-bounds donor Guest section')
                sections[key] = raw[start:start + size]
        offset += length
    if offset != end:
        raise ValueError('donor Guest commands do not exactly fill their declared range')
    return sections


def validate_donor(app, modules):
    app, modules = Path(app), Path(modules)
    metadata = {}
    for module in ('main', 'sdk'):
        for suffix in ('.fixups.tsv', '.gates.tsv'):
            name = module + suffix
            if (app / 'dm' / name).read_bytes() != (modules / name).read_bytes():
                raise ValueError('donor module metadata mismatch: ' + name)
            metadata[name] = sha(modules / name)
    donor = app / 'Frameworks/Guest.framework/Guest'
    sections = guest_sections(donor)
    identities = {}
    for module in ('main', 'sdk'):
        path = modules / (module + '.patched.bin')
        if path.stat().st_size > MAX_GUEST_BYTES:
            raise ValueError('derived module exceeds the inspection bound')
        image = path.read_bytes()
        values = dict(line[2:].split() for line in (modules / (module + '.fixups.tsv')).read_text().splitlines()
                      if line.startswith('# '))
        text = (int(values['TEXT_END'], 16) + PAGE - 1) & -PAGE
        patch = int(values['PATCH_OFF'], 16)
        end = (len(image) + PAGE - 1) & -PAGE
        if patch % PAGE or not 0 < text <= patch <= end:
            raise ValueError('invalid derived module split layout: ' + module)
        expected = [(('__TEXT', '__dm' + module + 'x0'), 0, text),
                    (('__DM' + module + 'W', '__img'), text, patch),
                    (('__TEXT', '__dm' + module + 'x1'), patch, end)]
        for key, lo, hi in expected:
            chunk = image[lo:min(hi, len(image))].ljust(hi - lo, b'\0')
            if sections.get(key) != chunk:
                raise ValueError('donor Guest module bytes mismatch: ' + module)
        identities[module] = sha(path)
    return dict(guest_sha256=sha(donor), modules=identities, metadata=metadata,
                section_bytes_matched=True, signature_authenticated=False)
