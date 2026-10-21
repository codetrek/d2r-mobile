"""Native-constructed PSO records and source-only codec admission checks."""

import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/ios/tools/simulator'))
import pso_native


FIXTURE = r'''
#include <stdio.h>
#include "nvn_pso_wire.h"
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    pso_skey k; memset(&k, 0, sizeof k);
    memcpy(k.vs,"0123456789abcdef_b",19); memcpy(k.fs,"fedcba9876543210_b",19); k.fs_stage=1;
    const char *name=argv[1];
    if (!strcmp(name,"ordinary")) {}
    else if (!strcmp(name,"depth")) { memset(k.fs,0,sizeof k.fs); k.fs_stage=0; }
    else if (!strcmp(name,"merged")) { k.merged=1; memset(&k.fz_desc,0xff,sizeof k.fz_desc); }
    else if (!strcmp(name,"specialized")) { k.fz=1; memset(&k.fz_desc,0xff,sizeof k.fz_desc); }
    else if (!strcmp(name,"both")) { k.fz=k.merged=1; }
    else if (!strcmp(name,"bf")) memcpy(k.fs,"fedcba9876543210_bf",20);
    else if (!strcmp(name,"bad-vs")) memset(k.vs,'a',sizeof k.vs);
    else if (!strcmp(name,"bad-fs")) k.fs[23]='f';
    else if (!strcmp(name,"ptr-vs")) k.k.vs=(void *)1;
    else if (!strcmp(name,"ptr-fs")) k.k.fs=(void *)1;
    else if (!strcmp(name,"ptr-fn")) k.k.fsfn=(void *)1;
    else if (!strcmp(name,"bad-stage")) k.vs_stage=1;
    else if (!strcmp(name,"bad-flags")) k.merged=2;
    else if (!strcmp(name,"ordinary-desc")) k.fz_desc.kind=1;
    else return 2;
    char hex[sizeof k*2+1]; pso_skey_hex(&k,hex); puts(hex); return 0;
}
'''


class NativePsoTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        parent = REPO / '.tmp/ios-simulator/metadata-codec/tests'
        parent.mkdir(parents=True, exist_ok=True)
        cls.temporary = tempfile.TemporaryDirectory(dir=parent)
        cls.root = Path(cls.temporary.name)
        cls.codec = cls.root / 'codec'
        cls.fixture = cls.root / 'fixture'
        source = cls.root / 'fixture.c'
        source.write_text(FIXTURE)
        common = ['clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-I', str(REPO / 'dm/gfx/nvn'),
                  '-I', str(REPO / 'dm/gfx/nvn/include')]
        subprocess.run([*common, str(REPO / 'dm/ios/tools/simulator/pso_codec.c'), '-o', str(cls.codec)], check=True)
        subprocess.run([*common, str(source), '-o', str(cls.fixture)], check=True)
        cls.digest = hashlib.sha256(cls.codec.read_bytes()).hexdigest()
        cls.hex = {name: subprocess.check_output([str(cls.fixture), name], text=True).strip()
                   for name in ('ordinary', 'depth', 'merged', 'specialized', 'both', 'bf', 'bad-vs', 'bad-fs',
                                'ptr-vs', 'ptr-fs', 'ptr-fn', 'bad-stage', 'bad-flags', 'ordinary-desc')}
        cls.output = subprocess.check_output([str(cls.codec)], input=(cls.hex['ordinary'] + '\n').encode()).decode()

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_native_named_records_and_layout(self):
        names = ('ordinary', 'depth', 'merged', 'specialized', 'both', 'bf')
        result = pso_native.inspect_keys(self.codec, self.digest, [self.hex[name] for name in names])
        self.assertEqual([row['features'] for row in result['records']], [0, 0, 1, 2, 3, 4])
        self.assertEqual(result['records'][1]['fs'], '')
        layout = result['layout']
        self.assertEqual(set(layout['types']), set(pso_native.FIELDS))
        self.assertEqual(layout['types']['pso_key']['fields']['vs']['size'], layout['pointer_bytes'])
        self.assertEqual(layout['types']['pso_skey']['fields']['k']['size'], layout['types']['pso_key']['size'])
        streamed = pso_native.inspect_keys(self.codec, self.digest, (self.hex[name] for name in names))
        self.assertEqual(streamed, result)

    def test_native_rejects_invalid_constructed_fields(self):
        for name in ('bad-vs', 'bad-fs', 'ptr-vs', 'ptr-fs', 'ptr-fn', 'bad-stage', 'bad-flags', 'ordinary-desc'):
            with self.subTest(name=name), self.assertRaises(subprocess.CalledProcessError) as raised:
                pso_native.inspect_keys(self.codec, self.digest, [self.hex[name]])
            self.assertEqual(raised.exception.returncode, 3)
            self.assertIn(b'rejected', raised.exception.stderr)

    def test_native_input_framing_and_empty_layout(self):
        good = self.hex['ordinary'].encode()
        for payload in (b'\n', b'g\n', good[:-1] + b'\n', good + b'0\n', good + b'\0\n', good + b'\n\n'):
            with self.subTest(payload=len(payload)):
                result = subprocess.run([str(self.codec)], input=payload, capture_output=True)
                self.assertEqual(result.returncode, 3)
                self.assertNotIn(b'END\t', result.stdout)
        for payload in (good.upper(), good + b'\n'):
            result = subprocess.run([str(self.codec)], input=payload, capture_output=True, check=True)
            self.assertEqual(len(pso_native.parse_output(result.stdout.decode(), 1)['records']), 1)
        self.assertEqual(pso_native.inspect_keys(self.codec, self.digest, [])['records'], [])

    def test_witness_mutations_rejected(self):
        lines = self.output.splitlines()
        field = next(line for line in lines if line.startswith('FIELD\tpso_skey\tfs\t'))
        parts = field.split('\t'); parts[3] = '0'
        row = next(line for line in lines if line.startswith('ROW\t'))
        bad_feature = row.split('\t'); bad_feature[-1] = '4'
        changes = [self.output.replace('d2r.pso-native-codec.v1', 'unknown'),
                   '\n'.join(lines[:-1]), self.output + 'END\t1\n', self.output.replace('END\t1', 'END\t2'),
                   self.output.replace(field, '\t'.join(parts)),
                   self.output.replace(field, field + '\n' + field),
                   self.output.replace('TYPE\tva_st', 'TYPE\tunknown'),
                   self.output.replace(row, '\t'.join(bad_feature)),
                   self.output.replace('ROW\t0', 'ROW\t1'),
                   self.output.replace(field + '\n', ''), '']
        for output in changes:
            with self.subTest(output=output[:60]), self.assertRaises(ValueError):
                pso_native.parse_output(output, 1)

    def test_identity_checks_before_and_after_native_process(self):
        with mock.patch.object(pso_native.subprocess, 'run') as run:
            with self.assertRaises(ValueError): pso_native.inspect_keys(self.codec, '0' * 64, [])
            run.assert_not_called()
        copy = self.root / 'copy'
        shutil.copyfile(self.codec, copy); copy.chmod(0o700)
        def mutate(*args, **kwargs):
            copy.write_bytes(b'changed during native execution')
            return subprocess.CompletedProcess(args, 0, self.output.encode(), b'')
        with mock.patch.object(pso_native.subprocess, 'run', side_effect=mutate), self.assertRaises(ValueError):
            pso_native.inspect_keys(copy, self.digest, [self.hex['ordinary']])
        link = self.root / 'link'; link.symlink_to(self.codec)
        with self.assertRaises(ValueError): pso_native.inspect_keys(link, self.digest, [])

    def test_python_rejects_non_hex_before_process(self):
        for key in ('', '0\n1', '0\0', 'ＦＦ', None):
            with self.subTest(key=key), self.assertRaises(ValueError):
                pso_native.inspect_keys(self.codec, self.digest, [key])


if __name__ == '__main__':
    unittest.main()
