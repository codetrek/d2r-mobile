#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../../gfx/nvn/nvn_pso_profile.h"

#if defined(__aarch64__)
#define CODEC_ARCH "aarch64"
#elif defined(__x86_64__)
#define CODEC_ARCH "x86_64"
#else
#error Unsupported native PSO architecture
#endif
#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error Native PSO codec requires a little-endian target
#endif

#define TYPE(T) printf("TYPE\t%s\t%zu\t%zu\n", #T, sizeof(T), _Alignof(T))
#define FIELD(T, f) printf("FIELD\t%s\t%s\t%zu\t%zu\n", #T, #f, offsetof(T, f), sizeof(((T *)0)->f))

static int emit_record(const char *line, unsigned long index) {
    pso_skey key;
    PsoProfileStatus status = pso_profile_parse(line, &key);
    if (status) { fprintf(stderr, "native render record %lu rejected (status=%d)\n", index, status); return 3; }
    printf("ROW\t%lu\t%s\t%s\t%u\t%u\t%u\n", index, key.vs, key.fs,
           key.vs_stage, key.fs_stage, pso_profile_features(&key));
    return 0;
}

int main(int argc, char **argv) {
    (void)argv;
    if (argc != 1) { fputs("usage: pso_codec < native-render-key-hex-lines\n", stderr); return 2; }
    printf("SCHEMA\td2r.pso-native-codec.v1\nABI\t%s\tlittle\t%zu\n", CODEC_ARCH, sizeof(void *));
    TYPE(pso_skey); TYPE(pso_key); TYPE(pso_fz_desc); TYPE(blend_st); TYPE(va_st); TYPE(vs_st);
    FIELD(pso_skey, vs); FIELD(pso_skey, fs); FIELD(pso_skey, vs_stage); FIELD(pso_skey, fs_stage);
    FIELD(pso_skey, merged); FIELD(pso_skey, fz); FIELD(pso_skey, fz_desc); FIELD(pso_skey, k);
    FIELD(pso_key, vs); FIELD(pso_key, fs); FIELD(pso_key, cfmt); FIELD(pso_key, dfmt); FIELD(pso_key, sfmt);
    FIELD(pso_key, samples); FIELD(pso_key, blend_en); FIELD(pso_key, chmask); FIELD(pso_key, a2c);
    FIELD(pso_key, blend); FIELD(pso_key, attr); FIELD(pso_key, stream); FIELD(pso_key, lmap); FIELD(pso_key, fsfn);
    FIELD(pso_fz_desc, kind); FIELD(pso_fz_desc, fbmask); FIELD(pso_fz_desc, fx);
    char line[sizeof(pso_skey) * 2 + 1];
    unsigned long count = 0;
    size_t length = 0;
    for (int character; (character = getchar()) != EOF;) {
        if (character == '\n') {
            line[length] = 0;
            int status = emit_record(line, count++);
            if (status) return status;
            length = 0;
        } else {
            if (length >= sizeof line - 1 ||
                !((character >= '0' && character <= '9') || (character >= 'a' && character <= 'f') ||
                  (character >= 'A' && character <= 'F'))) {
                fprintf(stderr, "native render record %lu has invalid hex bytes or length\n", count); return 3;
            }
            line[length++] = (char)character;
        }
    }
    if (ferror(stdin)) { perror("read native render records"); return 4; }
    if (length) {
        line[length] = 0;
        int status = emit_record(line, count++);
        if (status) return status;
    }
    printf("END\t%lu\n", count);
    if (fflush(stdout) || ferror(stdout)) { perror("write native codec result"); return 5; }
    return 0;
}
