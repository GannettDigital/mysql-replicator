//! Bootstrap ABI. Decoder state, typed values and strict validation are pending.
//! Exports below have no allocations, input pointers or panicking operations.
#[unsafe(no_mangle)]
pub extern "C" fn replicator_codec_abi_version() -> u32 { 1 }

#[unsafe(no_mangle)]
pub extern "C" fn replicator_codec_capabilities() -> u64 { 0 }
