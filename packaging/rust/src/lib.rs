//! Packaging-only probe with a fixed trusted fixture. Not a production decoder.
use mysql_common::binlog::{consts::{BinlogVersion, BinlogChecksumAlg}, events::EventData, EventStreamReader};
fn exercise() -> Option<u64> {
    let bytes = include_bytes!("../../../tests/ReplicatorLabTests/Fixtures/source-positive.binlog");
    let compressed = zstd::stream::encode_all(&bytes[..], 1).ok()?;
    if zstd::stream::decode_all(&compressed[..]).ok()?.as_slice() != bytes { return None; }
    let mut reader = EventStreamReader::new(BinlogVersion::Version4);
    let (mut pos, mut events, mut rows) = (4, 0u32, 0u32);
    while pos < bytes.len() {
        let header = bytes.get(pos..pos + 19)?;
        let size = u32::from_le_bytes(header[9..13].try_into().ok()?) as usize;
        if !(19..=16 * 1024 * 1024).contains(&size) { return None; }
        let event = reader.read(bytes.get(pos..pos + size)?).ok()??;
        if event.footer().get_checksum_alg().ok()? != Some(BinlogChecksumAlg::BINLOG_CHECKSUM_ALG_CRC32) { return None; }
        if u32::from_le_bytes(event.checksum()?) != event.calc_checksum(BinlogChecksumAlg::BINLOG_CHECKSUM_ALG_CRC32) { return None; }
        if let EventData::RowsEvent(data) = event.read_data().ok()?? {
            for row in data.rows(reader.get_tme(data.table_id())?) { row.ok()?; rows += 1; }
        }
        events += 1;
        pos += size;
    }
    if events == 0 || rows < 4 { return None; }
    Some((u64::from(events) << 32) | u64::from(rows))
}
#[unsafe(no_mangle)]
pub extern "C" fn packaging_rust_self_test() -> u64 {
    std::panic::catch_unwind(exercise).ok().flatten().unwrap_or(0)
}
