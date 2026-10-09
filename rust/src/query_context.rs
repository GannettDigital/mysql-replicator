//! Typed QUERY status decoding reuses mysql_common. Its iterator can stop at an
//! unknown/truncated field, so verify complete byte consumption and uniqueness.
use super::*;
use mysql_common::binlog::events::{StatusVarsIterator, StatusVarVal};
#[repr(C)]
#[derive(Clone, Copy)]
pub struct QueryContext {
    pub sql_mode: u64,
    pub present: u32,
    pub flags2: u32,
    pub charset_client: u32,
    pub collation_connection: u32,
    pub collation_server: u32,
    pub collation_database: u32,
    pub default_collation_utf8mb4: u32,
    pub microseconds: u32,
    pub explicit_defaults_timestamp: u32,
    pub time_zone_length: u32,
    pub time_zone: [u8; 64],
}
impl Default for QueryContext {
    fn default() -> Self { unsafe { std::mem::zeroed() } }
}
fn decode(bytes: &[u8]) -> Checked<QueryContext> {
    ensure(bytes.len() <= 65535, LIMIT, "query status limit")?;
    let mut out=QueryContext::default();
    let mut consumed=0;
    while consumed < bytes.len() {
        // mysql_common does not skip each name's NUL terminator, and its
        // iterator interprets the over-limit sentinel as a count of names.
        // This field only schedules native parallel workers; validate framing
        // here without depending on the decoded (unused) database names.
        if bytes[consumed]==12 {
            ensure(out.present & (1<<12)==0,MALFORMED,"duplicate query status")?;
            let count=*bytes.get(consumed+1).ok_or((MALFORMED,"truncated updated databases"))?;
            ensure(count!=0 && (count<=16 || count==254),MALFORMED,"invalid updated database count")?;
            consumed+=2;
            if count!=254 {
                for _ in 0..count {
                    let end=bytes[consumed..].iter().position(|b| *b==0)
                        .ok_or((MALFORMED,"truncated updated databases"))?;
                    consumed+=end+1;
                }
            }
            out.present |= 1<<12;
            continue;
        }
        let variable=StatusVarsIterator::new(&bytes[consumed..]).next()
            .ok_or((UNSUPPORTED,"unknown or truncated query status"))?;
        // The pinned mysql_common iterator correctly bounds Q_MICROSECONDS to
        // three bytes, but get_value() tries to read a u32 and rejects it. Keep
        // the upstream framing and decode that one 24-bit value here.
        let value=if bytes[consumed]==13 {
            let raw=bytes.get(consumed+1..consumed+4).ok_or((MALFORMED,"truncated query microseconds"))?;
            StatusVarVal::Microseconds(u32::from_le_bytes([raw[0],raw[1],raw[2],0]))
        } else {variable.get_value().map_err(|_|(MALFORMED,"invalid query status"))?};
        let (key,size)=match value {
            StatusVarVal::Flags2(v) => {out.flags2=v.0;(0,5)},
            StatusVarVal::SqlMode(v) => {out.sql_mode=v.0;(1,9)},
            StatusVarVal::Catalog(v) => (2,1+v.len()),
            StatusVarVal::AutoIncrement {..} => (3,5),
            StatusVarVal::Charset {charset_client,collation_connection,collation_server} => {
                out.charset_client=charset_client as u32;out.collation_connection=collation_connection as u32;
                out.collation_server=collation_server as u32;(4,7)
            },
            StatusVarVal::TimeZone(v) => {
                let bytes=v.as_bytes(); ensure(bytes.len()<=64,UNSUPPORTED,"time zone too long")?;
                out.time_zone_length=bytes.len() as u32; out.time_zone[..bytes.len()].copy_from_slice(bytes);
                (5,2+bytes.len())
            },
            StatusVarVal::CatalogNz(v) => (6,2+v.as_bytes().len()),
            StatusVarVal::LcTimeNames(_) => (7,3),
            StatusVarVal::CharsetDatabase(v) => {out.collation_database=v as u32;(8,3)},
            StatusVarVal::TableMapForUpdate(_) => (9,9),
            StatusVarVal::MasterDataWritten(_) => (10,5),
            StatusVarVal::Invoker {username,hostname} => (11,3+username.as_bytes().len()+hostname.as_bytes().len()),
            StatusVarVal::UpdatedDbNames(_) => unreachable!("updated databases decoded above"),
            StatusVarVal::Microseconds(v) => {ensure(v<=999999,MALFORMED,"invalid query microseconds")?;out.microseconds=v;(13,4)},
            StatusVarVal::CommitTs(_) | StatusVarVal::CommitTs2(_) => return Err((UNSUPPORTED,"unsupported query commit timestamp")),
            StatusVarVal::ExplicitDefaultsForTimestamp(v) => {out.explicit_defaults_timestamp=v as u32;(16,2)},
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
    fn updated_databases_skip_each_terminator_and_preserve_following_fields() {
        let data=b"\x0c\x02rejected\0mysql\0\x10\x01";
        let context=decode(data).unwrap();
        assert_eq!(context.present,(1<<12)|(1<<16));
        assert_eq!(context.explicit_defaults_timestamp,1);
        for end in 1..17 { assert!(decode(&data[..end]).is_err()); }
        assert!(decode(b"\x0c\x01db\0\x0c\x01db\0").is_err());
        assert!(decode(b"\x0c\x02db\0other").is_err());
        assert!(decode(b"\x0c\x00").is_err());
        assert!(decode(b"\x0c\xff").is_err());
        let sentinel=decode(&[12,254,16,1]).unwrap();
        assert_eq!(sentinel.explicit_defaults_timestamp,1);
    }
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
    #[test]
    fn ddl_clock_context_preserves_timezone_precision_and_timestamp_mode() {
        let data=[5,6,b'+',b'0',b'0',b':',b'0',b'0',13,64,226,1,16,1];
        let context=decode(&data).unwrap();
        assert_eq!(&context.time_zone[..context.time_zone_length as usize],b"+00:00");
        assert_eq!(context.microseconds,123456);
        assert_eq!(context.explicit_defaults_timestamp,1);
        assert!(decode(&[13,255,255,255]).is_err());
        assert!(decode(&[5,6,b'+']).is_err());
    }
}
