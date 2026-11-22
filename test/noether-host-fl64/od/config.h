// The noether host harness at FRAMELENGTH 64 — what norns runs scsynth at.
// Listed BEFORE test/noether-host on the include path, so it shadows the
// harness's own od/config.h (a verbatim copy of upstream's, fixed at 128).
#pragma once
#include <cstdint>
#define FRAMELENGTH 64
