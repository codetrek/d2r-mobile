# bcdec

Source: [iOrange/bcdec v0.985, commit 80859ed3b7afb1c527a2a99d70c61457bea72d0c](https://github.com/iOrange/bcdec/tree/80859ed3b7afb1c527a2a99d70c61457bea72d0c). The license in `LICENSE` permits either MIT or public-domain use.

The local header uses masked unsigned arithmetic for endpoint sign extension. This preserves the decoder result while avoiding signed left-shift overflow exposed by the signed BC6H endpoint tests. The decoder's formats and API remain unchanged. `dm/gfx/tests/t_bc_vectors.c` checks independent constant-endpoint vectors for every BC1–7 variant, signed formats, partial blocks and padded rows, including the BC6H endpoints that triggered the original undefined operation. `dm/gfx/tests/t_bc_sign.c` checks every endpoint bit pattern at widths 1–16 against an independent 64-bit arithmetic oracle and also checks masked extreme inputs.

The renderer calls this library through `dm/gfx/tex/nvn_bcdec.c`. The simulator transfer path decodes owned GPU readback bytes after producer synchronization; backend selection and physical upload orchestration remain unchanged. The defined-arithmetic correction also applies to the physical CPU fallback.
