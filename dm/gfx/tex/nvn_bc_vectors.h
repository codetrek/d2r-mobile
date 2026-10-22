#pragma once
#include <stdint.h>
#include <string.h>

// Synthetic constant-endpoint blocks used by CPU and host-only GPU diagnostics.
// Expected pixels come from the endpoint encodings, independently of bcdec.
static inline void nvn_bc_vector_bits(uint8_t *block, unsigned *at, unsigned value, unsigned count) {
    for (unsigned bit=0;bit<count;bit++,(*at)++) block[*at/8]|=((value>>bit)&1u)<<(*at%8);
}
static inline int nvn_bc_vector(uint32_t format, unsigned variant, uint8_t block[16], uint8_t pixel[8], unsigned *bpp) {
    memset(block,0,16); memset(pixel,0,8); *bpp=4;
    uint32_t f=format;
    if (f>=0x45 && f<=0x48) f-=4;
    if (f==0x4e) f=0x4d;
    if (f>=0x41 && f<=0x44) {
        unsigned rgb=f==0x43 || f==0x44?8:0;
        uint16_t color=variant?0x07e0:0xf800; block[rgb]=(uint8_t)color; block[rgb+1]=(uint8_t)(color>>8);
        pixel[variant?1:0]=255; pixel[3]=255;
        if (f==0x43) memset(block,0xff,8);
        if (f==0x44) block[0]=variant?128:255;
        if (f==0x44) pixel[3]=block[0];
        return 1;
    }
    if (f>=0x49 && f<=0x4c) {
        *bpp=f<=0x4a?1:2;
        int sign=f==0x4a || f==0x4c;
        block[0]=pixel[0]=sign?(variant?127:129):(variant?64:128);
        if (*bpp==2) block[8]=pixel[1]=sign?(variant?129:127):(variant?128:64);
        return 1;
    }
    if (f==0x4d) {
        unsigned at=0; nvn_bc_vector_bits(block,&at,64,7);
        for (unsigned component=0;component<4;component++) for (unsigned endpoint=0;endpoint<2;endpoint++)
            nvn_bc_vector_bits(block,&at,(component==(variant?1:0) || component==3)?127:0,7);
        pixel[variant?1:0]=254;pixel[3]=254;return 1;
    }
    if (f==0x4f || f==0x50) {
        unsigned at=0; nvn_bc_vector_bits(block,&at,3,5);
        unsigned endpoint=f==0x4f?(variant?511:512):(variant?0:1023);
        for (unsigned e=0;e<2;e++) { nvn_bc_vector_bits(block,&at,endpoint,10); nvn_bc_vector_bits(block,&at,0,10); nvn_bc_vector_bits(block,&at,0,10); }
        uint16_t rgb=f==0x4f?(variant?0x7bff:0xfbff):(variant?0:0x7bff),alpha=0x3c00;
        memcpy(pixel,&rgb,2);memcpy(pixel+6,&alpha,2);*bpp=8;return 1;
    }
    return 0;
}
