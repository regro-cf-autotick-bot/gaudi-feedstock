// Ground truth: ask LLVM 20 what Cling would see, rather than reimplementing
// getHostCPUFeatures() and hoping the reimplementation is faithful.
#include "llvm/ADT/StringMap.h"
#include "llvm/TargetParser/Host.h"
#include <cstdio>
#include <string>

int main() {
  printf("AVX10PROBE llvm_cpuname=%s\n", llvm::sys::getHostCPUName().str().c_str());
  auto feats = llvm::sys::getHostCPUFeatures();
  for (const auto &kv : feats) {
    std::string k = kv.first().str();
    if (k.rfind("avx10", 0) == 0 || k == "avx512f")
      printf("AVX10PROBE llvm_feature %s=%d\n", k.c_str(), (int)kv.second);
  }
  return 0;
}
