/* TEMPORARY DEBUG - remove before merging. See root-project/root#23542.
 *
 * Dumps the CPUID state that LLVM's getHostCPUFeatures() reads to decide the
 * AVX10 features, and evaluates the pre-fix and post-fix logic side by side.
 *
 * Why this rather than trying to reproduce the warning: a Granite Rapids runner
 * swept clang 18.1.8, 20.1.8 and 20.1.8 and was clean on all three, so the CPU
 * model is not the discriminator. Real GNR reports leaf 0x24 EBX bit 18 (512 bit
 * support) set, which makes both avx10.1-256 and avx10.1-512 come out true even
 * pre-fix, and no warning is emitted. The warning needs leaf 0x24 to report
 * version >= 1 with bit 18 CLEAR, which real silicon does not do - so the
 * suspicion is a hypervisor exposing an incomplete leaf 0x24. This prints the
 * raw registers so that can be confirmed or ruled out on any runner, whether or
 * not it warns.
 *
 * Pre-fix LLVM (through llvmorg-21.x, so including ROOT 6.40's LLVM 20.1.8):
 *   HasAVX10  = leaf7.1 EDX bit 19
 *   HasLeaf24 = MaxLevel >= 0x24 && cpuid(0x24) succeeded
 *   AVX10Ver  = HasLeaf24 && (EBX & 0xff)      <- collapses to 0/1
 *   Has512Len = HasLeaf24 && ((EBX >> 18) & 1)
 *   avx10.1-256 = HasAVX10 && AVX10Ver >= 1
 *   avx10.1-512 = HasAVX10 && AVX10Ver >= 1 && Has512Len
 *
 * clang warns when avx10.1-256 is set alongside AVX-512 and avx10.1-512 is not.
 */
#include <stdio.h>
#include <stdint.h>
#include <cpuid.h>

static int leaf(uint32_t l, uint32_t sub, uint32_t r[4]) {
    uint32_t max = __get_cpuid_max(0, 0);
    if (l > max) return 0;
    __cpuid_count(l, sub, r[0], r[1], r[2], r[3]);
    return 1;
}

int main(void) {
    uint32_t r[4], max = __get_cpuid_max(0, 0);
    char vendor[13] = {0};

    __cpuid(0, r[0], r[1], r[2], r[3]);
    *(uint32_t *)(vendor + 0) = r[1];
    *(uint32_t *)(vendor + 4) = r[3];
    *(uint32_t *)(vendor + 8) = r[2];

    printf("vendor:            %s\n", vendor);
    printf("leaf 0 EAX:        0x%08x  (MaxLevel; >= 0x24 needed)\n", max);

    int has_avx10 = 0, has_avx512f = 0;
    if (leaf(7, 0, r)) {
        has_avx512f = (r[1] >> 16) & 1;
        printf("leaf 7.0 EBX:      0x%08x  avx512f=%d\n", r[1], has_avx512f);
    }
    if (leaf(7, 1, r)) {
        has_avx10 = (r[3] >> 19) & 1;
        printf("leaf 7.1 EDX:      0x%08x  bit19 HasAVX10=%d\n", r[3], has_avx10);
    } else {
        printf("leaf 7.1:          unavailable\n");
    }

    /* The uninitialised-ECX bug means the real read may not have been subleaf 0,
     * so show what several subleaves return. */
    uint32_t ebx0 = 0;
    int has_leaf24 = 0;
    if (max >= 0x24) {
        const uint32_t subs[] = {0, 1, 7, 0xffffffff};
        for (unsigned i = 0; i < sizeof subs / sizeof *subs; i++) {
            if (!leaf(0x24, subs[i], r)) continue;
            has_leaf24 = 1;
            if (subs[i] == 0) ebx0 = r[1];
            printf("leaf 0x24 ECX=0x%-8x EBX=0x%08x  ver=%u b16=%u b17=%u b18(512)=%u\n",
                   subs[i], r[1], r[1] & 0xff,
                   (r[1] >> 16) & 1, (r[1] >> 17) & 1, (r[1] >> 18) & 1);
        }
    } else {
        printf("leaf 0x24:         not supported (MaxLevel 0x%x < 0x24)\n", max);
    }

    int ver_prefix  = has_leaf24 && (ebx0 & 0xff);          /* the 0/1 collapse */
    int ver_postfix = has_leaf24 ? (int)(ebx0 & 0xff) : 0;
    int has512      = has_leaf24 && ((ebx0 >> 18) & 1);

    int pre_256  = has_avx10 && ver_prefix  >= 1;
    int pre_512  = has_avx10 && ver_prefix  >= 1 && has512;
    int post_256 = has_avx10 && ver_postfix >= 1;
    int post_512 = has_avx10 && ver_postfix >= 1 && has512;

    printf("\npre-fix:           avx10.1-256=%d avx10.1-512=%d\n", pre_256, pre_512);
    printf("post-fix:          avx10.1-256=%d avx10.1-512=%d\n", post_256, post_512);

    int warns = pre_256 && !pre_512 && has_avx512f;
    printf("VERDICT would_warn=%d avx512f=%d has_avx10=%d leaf24=%d ebx0=0x%08x\n",
           warns, has_avx512f, has_avx10, has_leaf24, ebx0);
    return 0;
}
