#ifndef REPLICATOR_CODEC_H
#define REPLICATOR_CODEC_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Bootstrap ABI only. No decode capabilities are advertised yet. */
uint32_t replicator_codec_abi_version(void);
uint64_t replicator_codec_capabilities(void);
#ifdef __cplusplus
}
#endif
#endif
