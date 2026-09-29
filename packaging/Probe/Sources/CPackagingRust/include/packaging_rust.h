#include <stdint.h>
// Packaging-only self-test. Zero means failure; otherwise upper/lower words
// contain decoded event/row counts. No production decoder API is exposed.
uint64_t packaging_rust_self_test(void);
