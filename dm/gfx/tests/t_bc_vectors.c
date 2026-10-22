#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../tex/nvn_bcdec.h"
#include "../tex/nvn_bc_vectors.h"
#include "../tex/nvn_fmt_mtl.h"
int main(void) {
    unsigned formats=0;
    for (uint32_t format=0x41;format<=0x50;format++) for (unsigned variant=0;variant<2;variant++) {
        uint8_t block[16],pixel[8],input[2*48],output[7*72+16];unsigned bpp;
        assert(nvn_bc_vector(format,variant,block,pixel,&bpp));
        unsigned blockBytes=format==0x41 || format==0x42 || format==0x45 || format==0x46 || format==0x49 || format==0x4a?8:16;
        memset(input,0xEF,sizeof input);memset(output,0xCD,sizeof output);
        for(unsigned y=0;y<2;y++) for(unsigned x=0;x<2;x++) memcpy(input+y*48+x*blockBytes,block,blockBytes);
        assert(!nvn_bc_decode(format,input,48,7,5,output+8,72));
        for(unsigned y=0;y<5;y++) {
            for(unsigned x=0;x<7;x++) assert(!memcmp(output+8+y*72+x*bpp,pixel,bpp));
            for(unsigned x=7*bpp;x<72;x++) assert(output[8+y*72+x]==0xCD);
        }
        for(unsigned x=0;x<8;x++) assert(output[x]==0xCD);
        for(unsigned x=8+5*72;x<sizeof output;x++) assert(output[x]==0xCD);
        formats++;
    }
    uint32_t pf;uint8_t swizzle[4];
    assert(nvn_fmt_to_mtl(0x41,&pf,swizzle) && swizzle[3]==NVN_SWZ_ONE);
    assert(nvn_fmt_to_mtl(0x45,&pf,swizzle) && swizzle[3]==NVN_SWZ_ONE);
    assert(nvn_fmt_to_mtl(0x42,&pf,swizzle) && swizzle[3]==NVN_SWZ_A);
    uint8_t transparent[8]={0,0,0xff,0xff,0xff,0xff,0xff,0xff},decoded[64];
    assert(!nvn_bc_decode(0x41,transparent,8,4,4,decoded,16));
    for(unsigned i=0;i<16;i++)assert(decoded[i*4+3]==0);
    uint8_t block[16]={0},pixel[8]={0};unsigned bpp;assert(!nvn_bc_vector(0,0,block,pixel,&bpp));
    puts("32 independent BC1-7/sRGB/signed endpoint vectors, partial 7x5 edges, padded pitches and canaries passed");assert(formats==32);
}
