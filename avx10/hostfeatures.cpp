// Ground truth: ask LLVM itself what Cling would derive, rather than
// reimplementing getHostCPUFeatures() and hoping the reimplementation is
// faithful. Builds against both the LLVM 18/19 and the LLVM 20+ API.
//
// The signature changed in LLVM 20: 18/19 take a StringMap& and return bool,
// 20+ return the map. That difference is incidental, but it matters here
// because 18/19 are exactly the versions whose *derivation* of the avx10
// features differs, and those are the ones we need to interrogate.
#include "llvm/ADT/StringMap.h"
#include "llvm/Config/llvm-config.h"
#include "llvm/TargetParser/Host.h"
#include <cstdio>
#include <string>

int main() {
  printf("AVX10PROBE llvm_version=%d.%d.%d\n", LLVM_VERSION_MAJOR,
         LLVM_VERSION_MINOR, LLVM_VERSION_PATCH);
  printf("AVX10PROBE llvm_cpuname=%s\n", llvm::sys::getHostCPUName().str().c_str());

#if LLVM_VERSION_MAJOR >= 20
  const auto feats = llvm::sys::getHostCPUFeatures();
#else
  llvm::StringMap<bool, llvm::MallocAllocator> feats;
  if (!llvm::sys::getHostCPUFeatures(feats))
    printf("AVX10PROBE llvm_detect_failed=1\n");
#endif

  for (const auto &kv : feats) {
    std::string k = kv.first().str();
    if (k.rfind("avx10", 0) == 0 || k == "avx512f")
      printf("AVX10PROBE llvm_feature %s=%d\n", k.c_str(), (int)kv.second);
  }
  return 0;
}
