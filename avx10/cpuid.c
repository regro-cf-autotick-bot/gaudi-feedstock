/* Dumps the CPUID state LLVM reads to derive the AVX10 features, and evaluates
 * the pre- and post-172350 expressions side by side.
 *
 * Only one CPUID shape can produce the warning: leaf 7.1 EDX bit 19 set, and
 * leaf 0x24 reporting version >= 1 with bit 18 (512 bit) CLEAR. No shipping
 * Intel part enumerates that - real Granite Rapids reports 0x00070001, with bit
 * 18 set, and is measurably clean. So the point of this is to capture the shape
 * on a machine that does warn, or to show the trigger is something else.
 *
 * Note for a host reporting version 1 with bit 18 clear the pre- and post-fix
 * expressions evaluate identically, so PR 172350 would not fix it. warn_pre vs
 * warn_post below is what decides that.
 */
#include <stdio.h>
#include <string.h>

static void cpuid_ex(unsigned leaf, unsigned sub,
                     unsigned *a, unsigned *b, unsigned *c, unsigned *d) {
    unsigned ea = leaf, eb = 0, ec = sub, ed = 0;
    __asm__ __volatile__("cpuid" : "+a"(ea), "=b"(eb), "+c"(ec), "=d"(ed));
    *a = ea; *b = eb; *c = ec; *d = ed;
}

/* Mimics LLVM's getX86CpuIDAndInfo: ECX is output-only, so the subleaf input is
 * whatever happened to be live in the register. Build at -O0 and -O2, because
 * which value that is depends on register allocation. */
static void cpuid_llvm(unsigned leaf,
                       unsigned *a, unsigned *b, unsigned *c, unsigned *d) {
    __asm__ __volatile__("cpuid"
                         : "=a"(*a), "=b"(*b), "=c"(*c), "=d"(*d) : "a"(leaf));
}

static void report(const char *how, int has_avx10, int has_leaf24,
                   unsigned ebx) {
    int ver_pre  = has_leaf24 && (ebx & 0xff);         /* pre-172350: 0/1     */
    int ver_post = has_leaf24 ? (int)(ebx & 0xff) : 0; /* post-172350: actual */
    int has512   = has_leaf24 && ((ebx >> 18) & 1);
    int p256 = has_avx10 && ver_pre  >= 1, p512 = p256 && has512;
    int q256 = has_avx10 && ver_post >= 1, q512 = q256 && has512;
    printf("AVX10PROBE how=%s has_avx10=%d leaf24=%d ebx=0x%08x ver=%u "
           "l128=%d l256=%d l512=%d pre256=%d pre512=%d post256=%d post512=%d "
           "warn_pre=%d warn_post=%d\n",
           how, has_avx10, has_leaf24, ebx, ebx & 0xff,
           (ebx >> 16) & 1, (ebx >> 17) & 1, (ebx >> 18) & 1,
           p256, p512, q256, q512,
           p256 && !p512, q256 && !q512);
}

int main(void) {
    unsigned a, b, c, d;
    cpuid_ex(0, 0, &a, &b, &c, &d);
    unsigned MaxLevel = a;
    char vend[13] = {0};
    memcpy(vend, &b, 4); memcpy(vend + 4, &d, 4); memcpy(vend + 8, &c, 4);

    cpuid_ex(1, 0, &a, &b, &c, &d);
    printf("AVX10PROBE vendor=%s maxlevel=0x%x sig=0x%08x hypervisor=%d\n",
           vend, MaxLevel, a, (c >> 31) & 1);

    unsigned s0a, s0b, s0c, s0d;
    cpuid_ex(7, 0, &s0a, &s0b, &s0c, &s0d);
    int has7s1 = MaxLevel >= 7 && s0a >= 1;
    unsigned x, y, z, w;
    cpuid_ex(7, 1, &x, &y, &z, &w);
    int has_avx10 = has7s1 && ((w >> 19) & 1);
    printf("AVX10PROBE leaf7_maxsub=%u leaf7_0_ebx=0x%08x leaf7_1_eax=0x%08x "
           "leaf7_1_edx=0x%08x bit19=%d has_avx10=%d avx512f=%d\n",
           s0a, s0b, x, w, (w >> 19) & 1, has_avx10, (s0b >> 16) & 1);

    unsigned subs[] = {0, 1, 2, 7, 0xffffffffu};
    for (unsigned i = 0; i < sizeof subs / sizeof *subs; i++) {
        unsigned p, q, r, s;
        int has24 = 0; unsigned ebx = 0;
        if (MaxLevel >= 0x24) {
            cpuid_ex(0x24, subs[i], &p, &q, &r, &s);
            has24 = 1; ebx = q;
            printf("AVX10PROBE raw24 sub=0x%x eax=0x%08x ebx=0x%08x "
                   "ecx=0x%08x edx=0x%08x\n", subs[i], p, q, r, s);
        }
        char how[32]; snprintf(how, sizeof how, "ecx=0x%x", subs[i]);
        report(how, has_avx10, has24, ebx);
    }

    /* the genuine LLVM code path, ECX uninitialised */
    {
        int has24 = 0; unsigned ebx = 0;
        if (MaxLevel >= 0x24) {
            cpuid_llvm(0x24, &a, &b, &c, &d);
            has24 = 1; ebx = b;
            printf("AVX10PROBE raw24 sub=UNINIT eax=0x%08x ebx=0x%08x "
                   "ecx=0x%08x edx=0x%08x\n", a, b, c, d);
        }
        report("uninit", has_avx10, has24, ebx);
    }
    return 0;
}
