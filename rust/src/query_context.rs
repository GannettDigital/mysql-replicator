//! Typed QUERY status decoding reuses mysql_common. Its iterator can stop at an
//! unknown/truncated field, so verify complete byte consumption and uniqueness.
use super::*;
use mysql_common::binlog::events::{StatusVarsIterator, StatusVarVal};
#[repr(C)]
#[derive(Default, Clone, Copy)]
pub struct QueryContext {
    pub sql_mode: u64,
    pub present: u32,
    pub flags2: u32,
    pub charset_client: u32,
    pub collation_connection: u32,
    pub collation_server: u32,
    pub collation_database: u32,
    pub default_collation_utf8mb4: u32,
}
fn decode(bytes: &[u8]) -> Checked<QueryContext> {
    ensure(bytes.len() <= 65535, LIMIT, "query status limit")?;
    let mut out=QueryContext::default();
    let mut consumed=0;
    for variable in StatusVarsIterator::new(bytes) {
        let value=variable.get_value().map_err(|_|(MALFORMED,"invalid query status"))?;
        let (key,size)=match value {
            StatusVarVal::Flags2(v) => {out.flags2=v.0;(0,5)},
            StatusVarVal::SqlMode(v) => {out.sql_mode=v.0;(1,9)},
            StatusVarVal::Catalog(v) => (2,1+v.len()),
            StatusVarVal::AutoIncrement {..} => (3,5),
            StatusVarVal::Charset {charset_client,collation_connection,collation_server} => {
                out.charset_client=charset_client as u32;out.collation_connection=collation_connection as u32;
                out.collation_server=collation_server as u32;(4,7)
            },
            StatusVarVal::TimeZone(v) => (5,2+v.as_bytes().len()),
            StatusVarVal::CatalogNz(v) => (6,2+v.as_bytes().len()),
            StatusVarVal::LcTimeNames(_) => (7,3),
            StatusVarVal::CharsetDatabase(v) => {out.collation_database=v as u32;(8,3)},
            StatusVarVal::TableMapForUpdate(_) => (9,9),
            StatusVarVal::MasterDataWritten(_) => (10,5),
            StatusVarVal::Invoker {username,hostname} => (11,3+username.as_bytes().len()+hostname.as_bytes().len()),
            StatusVarVal::UpdatedDbNames(names) => (12,2+names.iter().map(|n|n.as_bytes().len()+1).sum::<usize>()),
            StatusVarVal::Microseconds(_) => (13,4),
            StatusVarVal::CommitTs(_) | StatusVarVal::CommitTs2(_) => return Err((UNSUPPORTED,"unsupported query commit timestamp")),
            StatusVarVal::ExplicitDefaultsForTimestamp(_) => (16,2),
            StatusVarVal::DdlLoggedWithXid(_) => (17,9),
            StatusVarVal::DefaultCollationForUtf8mb4(v) => {out.default_collation_utf8mb4=v as u32;(18,3)},
            StatusVarVal::SqlRequirePrimaryKey(_) => (19,2),
            StatusVarVal::DefaultTableEncryption(v) => {ensure(v==0,UNSUPPORTED,"encrypted DDL unsupported")?;(20,2)},
        };
        ensure(out.present & (1<<key)==0,MALFORMED,"duplicate query status")?;
        out.present |= 1<<key;consumed += size;
    }
    ensure(consumed==bytes.len(),UNSUPPORTED,"unknown or truncated query status")?;
    Ok(out)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_query_context_decode(bytes:*const u8,length:u64,out:*mut QueryContext) -> i32 {
    if out.is_null() || (bytes.is_null() && length != 0) {return ARG;}
    unsafe {*out=QueryContext::default();}
    if length>65535 {return LIMIT;}
    let bytes=if length==0 {&[]} else {unsafe {slice::from_raw_parts(bytes,length as usize)}};
    match catch_unwind(||decode(bytes)) {
        Ok(Ok(value)) => {unsafe {*out=value;};0},
        Ok(Err((code,_))) => code,
        Err(_) => INTERNAL,
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn context_is_complete_and_duplicates_and_truncation_fail() {
        let data=[1,0,0,0,0,0,0,0,0,4,45,0,224,0,255,0,18,45,0];
        let context=decode(&data).unwrap();
        assert_eq!(context.charset_client,45);assert_eq!(context.collation_server,255);
        assert_eq!(context.default_collation_utf8mb4,45);
        for end in [1,5,10,14,17,18] {assert!(decode(&data[..end]).is_err());}
        assert!(decode(&[4,45,0,224,0,255,0,4,45,0,224,0,255,0]).is_err());
        assert!(decode(&[255]).is_err());
    }
}
