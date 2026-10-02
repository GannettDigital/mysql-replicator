//! Strict bounded offline adapter around the pinned mysql_common codec.
//! No transport, transaction/application policy, or JSON serialization lives here.
mod query_context;
use mysql_common::{
    binlog::{
        consts::{BinlogChecksumAlg, BinlogVersion},
        events::{
            Event, EventData, FormatDescriptionEvent, OptionalMetaExtractor, OptionalMetadataField,
            TableMapEvent,
        },
        value::BinlogValue,
    },
    constants::ColumnType,
    io::ParseBuf,
    proto::MyDeserialize,
    value::Value,
};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    panic::{AssertUnwindSafe, catch_unwind},
    ptr, slice,
};
const ARG: i32 = 1;
const MALFORMED: i32 = 2;
const CRC: i32 = 3;
const UNSUPPORTED: i32 = 4;
const LIMIT: i32 = 5;
const POISONED: i32 = 6;
const SCHEMA: i32 = 7;
const INTERNAL: i32 = 8;
mod scalars;

const MAX_COLUMNS: usize = 256;
const MAX_ROWS: usize = 4096;
const MAX_TABLES: usize = 64;
const MAX_TABLE_BYTES: usize = 4 * 1024 * 1024;
const MAX_VALUE: usize = 1024 * 1024;
const MAX_OUTPUT: usize = 16 * 1024 * 1024;
type Failure = (i32, &'static str);
type Checked<T> = Result<T, Failure>;
fn ensure(ok: bool, code: i32, message: &'static str) -> Checked<()> {
    if ok { Ok(()) } else { Err((code, message)) }
}
fn parsed<T>(value: std::io::Result<T>) -> Checked<T> {
    value.map_err(|_| (MALFORMED, "malformed event payload"))
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Bytes {
    data: *const u8,
    length: u64,
}
impl Bytes {
    fn new(bytes: &[u8]) -> Self {
        Self {
            data: bytes.as_ptr(),
            length: bytes.len() as u64,
        }
    }
}
#[repr(C)]
pub struct EventView {
    offset: u64,
    number: u64,
    table_id: u64,
    event_type: u32,
    timestamp: u32,
    server_id: u32,
    next_position: u32,
    flags: u32,
    row_count: u32,
    column_count: u32,
    event_size: u32,
    payload_flags: u32,
    query_error_code: u32,
    query_status: Bytes,
    name: Bytes,
    database: Bytes,
    table: Bytes,
    detail: Bytes,
    raw: Bytes,
    error: Bytes,
    fingerprint: Bytes,
}
#[repr(C)]
pub struct ColumnView {
    kind: u32,
    column_type: u32,
    maximum_bytes: u32,
    nullable: u32,
    collation: u32,
    primary_key: u32,
    name: Bytes,
    metadata: Bytes,
    unsigned_flag: u32,
}
struct MapColumn {
    kind: u32,
    column_type: u32,
    maximum_bytes: u32,
    nullable: u32,
    collation: u32,
    primary_key: u32,
    name: Vec<u8>,
    metadata: Vec<u8>,
    unsigned_flag: u32,
}
#[repr(C)]
pub struct ValueView {
    kind: u32,
    signed_value: i64,
    unsigned_value: u64,
    bytes: Bytes,
}
#[derive(Clone, Debug)]
enum Cell {
    Absent,
    Null,
    Signed(i64),
    Unsigned(u64),
    Text(Vec<u8>),
    Binary(Vec<u8>),
    Decimal(Vec<u8>),
    Temporal(Vec<u8>),
}
impl Cell {
    fn view(&self) -> ValueView {
        let mut v = ValueView {
            kind: 0,
            signed_value: 0,
            unsigned_value: 0,
            bytes: Bytes::new(&[]),
        };
        match self {
            Self::Absent => (),
            Self::Null => v.kind = 1,
            Self::Signed(x) => {
                v.kind = 2;
                v.signed_value = *x;
            }
            Self::Unsigned(x) => {
                v.kind = 3;
                v.unsigned_value = *x;
            }
            Self::Text(x) => {
                v.kind = 4;
                v.bytes = Bytes::new(x);
            }
            Self::Decimal(x) => {
                v.kind = 6;
                v.bytes = Bytes::new(x);
            }
            Self::Temporal(x) => {
                v.kind = 7;
                v.bytes = Bytes::new(x);
            }
            Self::Binary(x) => {
                v.kind = 5;
                v.bytes = Bytes::new(x);
            }
        }
        v
    }
}
struct Table {
    event: TableMapEvent<'static>,
    kinds: Vec<u32>,
    size: usize,
    filtered: bool,
}
pub struct Decoder {
    fde: Option<FormatDescriptionEvent<'static>>,
    tables: HashMap<u64, Table>,
    max_event: usize,
    next_offset: u64,
    poisoned: bool,
    #[cfg(test)]
    panic_next: bool,
}
pub struct Batch {
    offset: u64,
    number: u64,
    table_id: u64,
    event_type: u32,
    timestamp: u32,
    server_id: u32,
    next_position: u32,
    flags: u32,
    name: Vec<u8>,
    database: Vec<u8>,
    table: Vec<u8>,
    detail: Vec<u8>,
    raw: Vec<u8>,
    error: Vec<u8>,
    fingerprint: Vec<u8>,
    map_columns: Vec<MapColumn>,
    rows: Vec<[Vec<Cell>; 2]>,
    columns: usize,
    payload_flags: u32,
    query_error_code: u32,
    query_status: Vec<u8>,
    filtered: bool,
}
impl Batch {
    fn new(offset: u64, event_type: u32) -> Self {
        Self {
            offset,
            event_type,
            number: 0,
            table_id: 0,
            timestamp: 0,
            server_id: 0,
            next_position: 0,
            flags: 0,
            name: vec![],
            database: vec![],
            table: vec![],
            detail: vec![],
            raw: vec![],
            error: vec![],
            fingerprint: vec![],
            map_columns: vec![],
            rows: vec![],
            columns: 0,
            payload_flags: 0,
            query_error_code: 0,
            query_status: vec![],
            filtered: false,
        }
    }
    fn view(&self) -> EventView {
        EventView {
            offset: self.offset,
            number: self.number,
            table_id: self.table_id,
            event_type: self.event_type,
            timestamp: self.timestamp,
            server_id: self.server_id,
            next_position: self.next_position,
            flags: self.flags,
            row_count: self.rows.len() as u32,
            column_count: self.columns as u32,
            event_size: self.raw.len() as u32,
            payload_flags: self.payload_flags,
            query_error_code: self.query_error_code,
            query_status: Bytes::new(&self.query_status),
            name: Bytes::new(&self.name),
            database: Bytes::new(&self.database),
            table: Bytes::new(&self.table),
            detail: Bytes::new(&self.detail),
            raw: Bytes::new(&self.raw),
            error: Bytes::new(&self.error),
            fingerprint: Bytes::new(&self.fingerprint),
        }
    }
}
fn take<'a>(data: &mut &'a [u8], n: usize) -> Checked<&'a [u8]> {
    ensure(n <= data.len(), MALFORMED, "truncated payload")?;
    let (head, tail) = data.split_at(n);
    *data = tail;
    Ok(head)
}
fn u64le(data: &mut &[u8]) -> Checked<u64> {
    Ok(u64::from_le_bytes(take(data, 8)?.try_into().unwrap()))
}
// Bound counts before the upstream PREVIOUS_GTIDS parser's Vec::with_capacity.
fn check_previous(mut data: &[u8]) -> Checked<()> {
    let count = u64le(&mut data)?;
    ensure(
        count >> 56 == 0,
        UNSUPPORTED,
        "tagged previous-GTID sets are unsupported",
    )?;
    ensure(count <= 64, LIMIT, "previous-GTID SID limit exceeded")?;
    for _ in 0..count {
        take(&mut data, 16)?;
        let n = u64le(&mut data)?;
        ensure(n <= 4096, LIMIT, "previous-GTID interval limit exceeded")?;
        take(&mut data, n as usize * 16)?;
    }
    ensure(data.is_empty(), MALFORMED, "trailing previous-GTID bytes")
}
fn check_column(table: &TableMapEvent<'_>, index: usize, kind: u32) -> Checked<ColumnType> {
    let ty = table
        .get_column_type(index)
        .map_err(|_| (UNSUPPORTED, "unknown column type"))?
        .ok_or((MALFORMED, "missing column type"))?;
    use ColumnType::*;
    let valid = match ty {
        MYSQL_TYPE_TINY | MYSQL_TYPE_SHORT | MYSQL_TYPE_LONG | MYSQL_TYPE_LONGLONG
        | MYSQL_TYPE_INT24 => kind == 2 || kind == 3,
        MYSQL_TYPE_VARCHAR | MYSQL_TYPE_VAR_STRING | MYSQL_TYPE_STRING | MYSQL_TYPE_BLOB => {
            kind == 4 || kind == 5
        }
        MYSQL_TYPE_NEWDECIMAL => kind == 6,
        MYSQL_TYPE_DATE
        | MYSQL_TYPE_NEWDATE
        | MYSQL_TYPE_YEAR
        | MYSQL_TYPE_TIMESTAMP2
        | MYSQL_TYPE_DATETIME2
        | MYSQL_TYPE_TIME2 => kind == 7,
        _ => {
            return Err((
                UNSUPPORTED,
                "column type not supported by this decoder increment",
            ));
        }
    };
    ensure(
        valid,
        SCHEMA,
        "historical column interpretation conflicts with wire type",
    )?;
    let meta = table.get_column_metadata(index).unwrap_or(&[]);
    match ty {
        MYSQL_TYPE_VARCHAR | MYSQL_TYPE_VAR_STRING | MYSQL_TYPE_STRING => {
            ensure(meta.len() == 2, MALFORMED, "invalid string metadata")?
        }
        MYSQL_TYPE_BLOB => ensure(
            meta.len() == 1 && (1..=4).contains(&meta[0]),
            MALFORMED,
            "invalid BLOB metadata",
        )?,
        MYSQL_TYPE_NEWDECIMAL => ensure(
            meta.len() == 2 && (1..=65).contains(&meta[0]) && meta[1] <= 30 && meta[1] <= meta[0],
            MALFORMED,
            "invalid DECIMAL metadata",
        )?,
        MYSQL_TYPE_TIMESTAMP2 | MYSQL_TYPE_DATETIME2 | MYSQL_TYPE_TIME2 => ensure(
            meta.len() == 1 && meta[0] <= 6,
            MALFORMED,
            "invalid temporal precision",
        )?,
        _ => (),
    }
    Ok(ty)
}
// Row-image framing supplies authoritative signedness; the upstream BinlogRow
// API otherwise defaults missing signedness to signed. Scalar decoding uses
// mysql_common with the narrow correctness fixes in scalars.rs and below.
fn image<'a>(
    buf: &mut ParseBuf<'a>,
    table: &'a Table,
    present: &[bool],
    budget: &mut usize,
) -> Checked<Vec<Cell>> {
    let count = present.iter().filter(|x| **x).count();
    ensure(count > 0, MALFORMED, "empty row image bitmap")?;
    let nulls = take(&mut buf.0, count.div_ceil(8))?;
    *budget = budget
        .checked_add(present.len() * std::mem::size_of::<Cell>())
        .ok_or((LIMIT, "output overflow"))?;
    ensure(
        *budget <= MAX_OUTPUT,
        LIMIT,
        "decoded output limit exceeded",
    )?;
    let mut values = Vec::with_capacity(present.len());
    let mut image_index = 0;
    for (index, included) in present.iter().enumerate() {
        if !included {
            values.push(Cell::Absent);
            continue;
        }
        let is_null = nulls[image_index / 8] & (1 << (image_index % 8)) != 0;
        image_index += 1;
        if is_null {
            ensure(
                table.event.null_bitmask().get(index).is_some_and(|b| *b),
                MALFORMED,
                "NULL in nonnullable column",
            )?;
            values.push(Cell::Null);
            continue;
        }
        let kind = table.kinds[index];
        let ty = check_column(&table.event, index, kind)?;
        let meta = table.event.get_column_metadata(index).unwrap_or(&[]);
        if kind == 6 || kind == 7 {
            let cell = scalars::decode(ty, meta, kind, buf)?;
            let size = match &cell {
                Cell::Decimal(v) | Cell::Temporal(v) => v.len(),
                _ => unreachable!(),
            };
            *budget += size;
            ensure(
                *budget <= MAX_OUTPUT,
                LIMIT,
                "decoded output limit exceeded",
            )?;
            values.push(cell);
            continue;
        }
        let value = parsed(BinlogValue::deserialize((ty, meta, kind == 3, false), buf))?;
        let cell = match value {
            // The pinned mysql_common LeI24 reader zero-extends its three bytes.
            // Restore the sign bit before publishing a signed MEDIUMINT value.
            BinlogValue::Value(Value::Int(v)) if kind == 2 && ty == ColumnType::MYSQL_TYPE_INT24 => {
                Cell::Signed(((v as i32) << 8 >> 8) as i64)
            }
            BinlogValue::Value(Value::Int(v)) if kind == 2 => Cell::Signed(v),
            BinlogValue::Value(Value::UInt(v)) if kind == 3 => Cell::Unsigned(v),
            // mysql_common emits INT24 UNSIGNED as nonnegative Value::Int.
            BinlogValue::Value(Value::Int(v)) if kind == 3 && v >= 0 => Cell::Unsigned(v as u64),
            BinlogValue::Value(Value::Bytes(v)) if kind == 4 || kind == 5 => {
                ensure(
                    v.len() <= MAX_VALUE,
                    LIMIT,
                    "individual value limit exceeded",
                )?;
                *budget += v.len();
                ensure(
                    *budget <= MAX_OUTPUT,
                    LIMIT,
                    "decoded output limit exceeded",
                )?;
                if kind == 4 {
                    ensure(
                        std::str::from_utf8(&v).is_ok(),
                        MALFORMED,
                        "invalid UTF-8 for historical text column",
                    )?;
                    Cell::Text(v)
                } else {
                    Cell::Binary(v)
                }
            }
            _ => return Err((UNSUPPORTED, "unsupported decoded value")),
        };
        values.push(cell);
    }
    Ok(values)
}
impl Decoder {
    fn new(max_event: usize) -> Self {
        Self {
            fde: None,
            tables: HashMap::new(),
            max_event,
            next_offset: 4,
            poisoned: false,
            #[cfg(test)]
            panic_next: false,
        }
    }
    fn decode_filtered(
        &mut self,
        bytes: &[u8],
        offset: u64,
        kinds: &[u32],
        filter_table: bool,
    ) -> Checked<Batch> {
        #[cfg(test)]
        if std::mem::take(&mut self.panic_next) {
            panic!("test-only parser panic");
        }
        ensure(
            !self.poisoned,
            POISONED,
            "decoder is poisoned; reset and replay from FDE",
        )?;
        ensure(
            offset == self.next_offset,
            MALFORMED,
            "noncontiguous input offset",
        )?;
        ensure(
            bytes.len() <= self.max_event,
            LIMIT,
            "event size limit exceeded",
        )?;
        ensure(bytes.len() >= 23, MALFORMED, "short event header/checksum")?;
        let size = u32::from_le_bytes(bytes[9..13].try_into().unwrap()) as usize;
        ensure(
            size == bytes.len(),
            MALFORMED,
            "event length differs from frame length",
        )?;
        let code = bytes[4];
        ensure(
            !filter_table || (code == 19 && kinds.is_empty()),
            ARG,
            "filter flag requires a table map without column history",
        )?;
        ensure(
            matches!(
                code,
                2 | 3 | 4 | 15 | 16 | 19 | 23 | 24 | 25 | 30 | 31 | 32 | 33 | 34 | 35
            ),
            UNSUPPORTED,
            "unsupported binlog event type",
        )?;
        ensure(
            code == 19 || kinds.is_empty(),
            ARG,
            "column context is only valid for table-map events",
        )?;
        if code == 15 {
            ensure(
                self.fde.is_none() && offset == 4,
                MALFORMED,
                "unexpected format-description event",
            )?;
            ensure(
                bytes.len() >= 81 && bytes.len() <= 4096,
                MALFORMED,
                "invalid format-description size",
            )?;
            ensure(
                bytes[bytes.len() - 5] == 1,
                UNSUPPORTED,
                "only CRC32 binlog checksums are supported",
            )?;
        } else {
            ensure(
                self.fde.is_some(),
                MALFORMED,
                "format-description event required first",
            )?;
        }
        // Validate physical CRC before any payload parser or state change. Only
        // FDE's BINLOG_IN_USE flag is masked, per MySQL's checksum convention.
        let mut crc = crc32fast::Hasher::new();
        if code == 15 {
            crc.update(&bytes[..17]);
            crc.update(&[bytes[17] & !1]);
            crc.update(&bytes[18..bytes.len() - 4]);
        } else {
            crc.update(&bytes[..bytes.len() - 4]);
        }
        ensure(
            crc.finalize() == u32::from_le_bytes(bytes[bytes.len() - 4..].try_into().unwrap()),
            CRC,
            "binlog CRC32 mismatch",
        )?;
        let placeholder = FormatDescriptionEvent::new(BinlogVersion::Version4);
        let event = parsed(Event::read(
            self.fde.as_ref().unwrap_or(&placeholder),
            bytes,
        ))?;
        ensure(
            event.footer().get_checksum_alg().ok().flatten()
                == Some(BinlogChecksumAlg::BINLOG_CHECKSUM_ALG_CRC32),
            UNSUPPORTED,
            "unsupported checksum algorithm",
        )?;
        if code == 35 {
            check_previous(event.data())?;
        }
        if (23..=25).contains(&code) {
            ensure(
                event
                    .fde()
                    .get_event_type_header_length(event.header().event_type().unwrap())
                    == 8,
                UNSUPPORTED,
                "v1 row event absent from format description",
            )?;
        }
        let mut out = Batch::new(offset, code as u32);
        let header = event.header();
        out.timestamp = header.timestamp();
        out.server_id = header.server_id();
        out.next_position = header.log_pos();
        out.flags = header.flags_raw() as u32;
        out.name = format!(
            "{:?}",
            header
                .event_type()
                .map_err(|_| (UNSUPPORTED, "unknown event type"))?
        )
        .into_bytes();
        out.raw = bytes.to_vec();
        out.fingerprint = Sha256::digest(bytes).to_vec();
        let data = parsed(event.read_data())?.ok_or((UNSUPPORTED, "event has no decoder"))?;
        match data {
            EventData::FormatDescriptionEvent(fde) => {
                ensure(
                    fde.binlog_version() == BinlogVersion::Version4
                        && fde.event_header_length() == 19,
                    UNSUPPORTED,
                    "unsupported binlog format",
                )?;
                // Qualify modern row framing only; never let forged FDE lengths
                // silently reinterpret row events or skip their extra-data field.
                for (ty, expected) in [
                    (2u8, 13u8),
                    (4, 8),
                    (16, 0),
                    (19, 8),
                    (23, 8),
                    (24, 8),
                    (25, 8),
                    (30, 10),
                    (31, 10),
                    (32, 10),
                ] {
                    if let Some(actual) = fde.event_type_header_lengths().get(ty as usize - 1) {
                        ensure(
                            *actual == expected || ((23..=25).contains(&ty) && *actual == 0),
                            UNSUPPORTED,
                            "unsupported event post-header length",
                        )?;
                    }
                }
                out.detail = fde.server_version_raw().to_vec();
                self.fde = Some(fde.into_owned());
            }
            EventData::QueryEvent(query) => {
                self.tables.clear();
                out.database = query.schema_raw().to_vec();
                out.detail = query.query_raw().to_vec();
                out.query_error_code = query.error_code() as u32;
                out.query_status = query.status_vars_raw().to_vec();
            }
            EventData::RotateEvent(rotate) => {
                out.detail = rotate.name_raw().to_vec();
                out.number = rotate.position();
                self.tables.clear();
            }
            EventData::XidEvent(xid) => {
                ensure(
                    event.data().len() == 8,
                    MALFORMED,
                    "invalid XID payload length",
                )?;
                out.number = xid.xid;
            }
            EventData::GtidEvent(gtid) => {
                out.detail = gtid.sid().to_vec();
                ensure(gtid.gno() > 0, MALFORMED, "zero sequence in named GTID")?;
                out.number = gtid.gno();
                out.payload_flags = gtid.flags_raw() as u32;
            }
            EventData::AnonymousGtidEvent(gtid) => {
                ensure(
                    gtid.0.gno() == 0 && gtid.0.sid() == [0; 16],
                    MALFORMED,
                    "nonzero anonymous GTID identity",
                )?;
                out.detail = event.data().to_vec();
                out.payload_flags = gtid.0.flags_raw() as u32;
            }
            EventData::PreviousGtidsEvent(_) => out.detail = event.data().to_vec(),
            EventData::StopEvent => {
                ensure(event.data().is_empty(), MALFORMED, "trailing STOP bytes")?
            }
            EventData::TableMapEvent(table) => {
                let n = table.columns_count() as usize;
                ensure(
                    n > 0 && n <= MAX_COLUMNS,
                    LIMIT,
                    "table column limit exceeded",
                )?;
                ensure(
                    kinds.is_empty() || kinds.len() == n,
                    SCHEMA,
                    "historical column count differs",
                )?;
                if !filter_table {
                    // The upstream extractor otherwise accepts duplicate/conflicting
                    // TLVs with last/first-wins semantics. Fail before decoding rows.
                    let mut seen = std::collections::HashSet::new();
                    let mut charset = false;
                    let mut primary = false;
                    for field in table.iter_optional_meta() {
                        let field = parsed(field)?;
                        ensure(
                            seen.insert(std::mem::discriminant(&field)),
                            MALFORMED,
                            "duplicate table metadata",
                        )?;
                        match field {
                            OptionalMetadataField::DefaultCharset(_)
                            | OptionalMetadataField::ColumnCharset(_) => {
                                ensure(!charset, MALFORMED, "conflicting charset metadata")?;
                                charset = true;
                            }
                            OptionalMetadataField::SimplePrimaryKey(_)
                            | OptionalMetadataField::PrimaryKeyWithPrefix(_) => {
                                ensure(!primary, MALFORMED, "conflicting primary key metadata")?;
                                primary = true;
                            }
                            _ => (),
                        }
                    }
                    let optional = parsed(OptionalMetaExtractor::new(table.iter_optional_meta()))?;
                    let mut signedness = optional.iter_signedness();
                    let mut charsets = optional.iter_charset();
                    let names = optional
                        .iter_column_name()
                        .take(n + 1)
                        .map(|x| parsed(x).map(|x| x.name_raw().to_vec()))
                        .collect::<Checked<Vec<_>>>()?;
                    ensure(
                        names.is_empty() || names.len() == n,
                        MALFORMED,
                        "column name count differs",
                    )?;
                    let keys = optional
                        .iter_primary_key()
                        .take(n + 1)
                        .map(parsed)
                        .collect::<Checked<Vec<_>>>()?;
                    ensure(
                        keys.len() <= n && keys.iter().all(|x| *x < n as u64),
                        MALFORMED,
                        "invalid source primary key metadata",
                    )?;
                    for i in 0..n {
                        let ty = table
                            .get_column_type(i)
                            .map_err(|_| (UNSUPPORTED, "unknown column type"))?
                            .ok_or((MALFORMED, "missing column type"))?;
                        let numeric = ty.is_numeric_type();
                        let scalar_kind = match ty as u8 {
                            246 => 6,
                            10 | 14 | 13 | 17 | 18 | 19 => 7,
                            _ => {
                                if numeric {
                                    2
                                } else {
                                    5
                                }
                            }
                        };
                        // This default only validates wire metadata; it is NOT stored
                        // as history or used to interpret row values.
                        check_column(&table, i, kinds.get(i).copied().unwrap_or(scalar_kind))?;
                        let mut kind = if scalar_kind >= 6 { scalar_kind } else { 0 };
                        let mut unsigned_flag = 0;
                        let mut collation = 0;
                        if numeric {
                            if let Some(unsigned) = signedness.next() {
                                unsigned_flag = if unsigned { 2 } else { 1 };
                                if scalar_kind < 6 {
                                    kind = if unsigned { 3 } else { 2 };
                                }
                                if let Some(kind) = kinds.get(i) {
                                    ensure(
                                        *kind >= 6 || unsigned == (*kind == 3),
                                        SCHEMA,
                                        "history conflicts with wire signedness",
                                    )?;
                                }
                            }
                        } else if scalar_kind != 7 {
                            if let Some(charset) = charsets.next() {
                                collation = parsed(charset)? as u32;
                                kind = match collation {
                                    63 => 5,
                                    45 | 46 | 224 | 255 => 4,
                                    _ => 0,
                                };
                            }
                        }
                        let meta = table.get_column_metadata(i).unwrap_or(&[]);
                        let maximum_bytes = if ty as u8 == 15 && meta.len() == 2 {
                            u16::from_le_bytes([meta[0], meta[1]]) as u32
                        } else {
                            0
                        };
                        out.map_columns.push(MapColumn {
                            kind,
                            column_type: ty as u32,
                            maximum_bytes,
                            nullable: table.null_bitmask()[i] as u32,
                            collation,
                            primary_key: keys.contains(&(i as u64)) as u32,
                            name: names.get(i).cloned().unwrap_or_default(),
                            metadata: meta.to_vec(),
                            unsigned_flag,
                        });
                    }
                    drop(signedness);
                    drop(charsets);
                    drop(optional);
                }
                out.filtered = filter_table;
                let total: usize = self
                    .tables
                    .iter()
                    .filter(|(id, _)| **id != table.table_id())
                    .map(|(_, t)| t.size)
                    .sum();
                ensure(
                    total + bytes.len() <= MAX_TABLE_BYTES,
                    LIMIT,
                    "table-map memory limit exceeded",
                )?;
                ensure(
                    self.tables.contains_key(&table.table_id()) || self.tables.len() < MAX_TABLES,
                    LIMIT,
                    "table-map count limit exceeded",
                )?;
                out.table_id = table.table_id();
                out.columns = n;
                out.database = table.database_name_raw().to_vec();
                out.table = table.table_name_raw().to_vec();
                self.tables.insert(
                    table.table_id(),
                    Table {
                        event: table.into_owned(),
                        kinds: kinds.to_vec(),
                        size: bytes.len(),
                        filtered: filter_table,
                    },
                );
            }
            EventData::RowsEvent(rows) => {
                // The unified upstream accessor truncates unknown flag bits.
                // Preserve them through the ABI so policy can reject them.
                use mysql_common::binlog::events::RowsEventData::*;
                out.payload_flags = match &rows {
                    WriteRowsEventV1(e) => e.flags_raw(),
                    UpdateRowsEventV1(e) => e.flags_raw(),
                    DeleteRowsEventV1(e) => e.flags_raw(),
                    WriteRowsEvent(e) => e.flags_raw(),
                    UpdateRowsEvent(e) => e.flags_raw(),
                    DeleteRowsEvent(e) => e.flags_raw(),
                    PartialUpdateRowsEvent(e) => e.flags_raw(),
                } as u32;
                let table = self
                    .tables
                    .get(&rows.table_id())
                    .ok_or((SCHEMA, "rows event has no table map"))?;
                ensure(
                    rows.num_columns() == table.event.columns_count(),
                    MALFORMED,
                    "row/table-map column count differs",
                )?;
                out.table_id = rows.table_id();
                out.columns = table.event.columns_count() as usize;
                out.database = table.event.database_name_raw().to_vec();
                out.table = table.event.table_name_raw().to_vec();
                out.filtered = table.filtered;
                ensure(!rows.rows_data().is_empty(), MALFORMED, "empty rows event")?;
                if !table.filtered {
                    ensure(
                        !table.kinds.is_empty(),
                        SCHEMA,
                        "historical signedness/encoding required for this table map",
                    )?;
                    let before = rows
                        .columns_before_image()
                        .map(|bits| bits.iter().map(|b| *b).collect::<Vec<_>>());
                    let after = rows
                        .columns_after_image()
                        .map(|bits| bits.iter().map(|b| *b).collect::<Vec<_>>());
                    let mut buf = ParseBuf(rows.rows_data());
                    let mut budget = bytes.len();
                    out.table_id = rows.table_id();
                    out.columns = table.kinds.len();
                    out.database = table.event.database_name_raw().to_vec();
                    out.table = table.event.table_name_raw().to_vec();
                    while !buf.is_empty() {
                        ensure(
                            out.rows.len() < MAX_ROWS,
                            LIMIT,
                            "rows per event limit exceeded",
                        )?;
                        let old = buf.len();
                        let b = match &before {
                            Some(bits) => image(&mut buf, table, bits, &mut budget)?,
                            None => vec![],
                        };
                        let a = match &after {
                            Some(bits) => image(&mut buf, table, bits, &mut budget)?,
                            None => vec![],
                        };
                        ensure(buf.len() < old, MALFORMED, "row decoder made no progress")?;
                        out.rows.push([b, a]);
                    }
                    ensure(!out.rows.is_empty(), MALFORMED, "empty rows event")?;
                }
                // Statement-end means table IDs can be reused. Clear both maps
                // and their schema interpretations together, never retain stale history.
                if rows.flags().bits() & 1 != 0 {
                    self.tables.clear();
                }
            }
            _ => return Err((UNSUPPORTED, "unsupported decoded event")),
        }
        self.next_offset = offset
            .checked_add(bytes.len() as u64)
            .ok_or((LIMIT, "offset overflow"))?;
        Ok(out)
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn replicator_codec_abi_version() -> u32 {
    5
}
#[unsafe(no_mangle)]
pub extern "C" fn replicator_codec_capabilities() -> u64 {
    1
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_decoder_create(max_event: u32, out: *mut *mut Decoder) -> i32 {
    if out.is_null() {
        return ARG;
    }
    unsafe {
        *out = ptr::null_mut();
    }
    if !(23..=16 * 1024 * 1024).contains(&max_event) {
        return ARG;
    }
    match catch_unwind(|| Box::new(Decoder::new(max_event as usize))) {
        Ok(value) => {
            unsafe {
                *out = Box::into_raw(value);
            }
            0
        }
        Err(_) => INTERNAL,
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_decoder_reset(context: *mut Decoder) -> i32 {
    if context.is_null() {
        return ARG;
    }
    let context = unsafe { &mut *context };
    match catch_unwind(AssertUnwindSafe(|| {
        *context = Decoder::new(context.max_event)
    })) {
        Ok(()) => 0,
        Err(_) => {
            context.poisoned = true;
            INTERNAL
        }
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_decoder_free(context: *mut Decoder) {
    if !context.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
            drop(Box::from_raw(context));
        }));
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_decoder_feed(
    context: *mut Decoder,
    bytes: *const u8,
    length: u64,
    offset: u64,
    kinds: *const u32,
    count: u32,
    out: *mut *mut Batch,
) -> i32 {
    unsafe { rc_decoder_feed_filtered(context, bytes, length, offset, kinds, count, 0, out) }
}
/// filter_table=1 is permitted only on TABLE_MAP. Rows for that map retain
/// checked framing/CRC/identity/flags, but their value payload is opaque.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_decoder_feed_filtered(
    context: *mut Decoder,
    bytes: *const u8,
    length: u64,
    offset: u64,
    kinds: *const u32,
    count: u32,
    filter_table: u32,
    out: *mut *mut Batch,
) -> i32 {
    if context.is_null() {
        return ARG;
    }
    let context = unsafe { &mut *context };
    if out.is_null() {
        context.poisoned = true;
        return ARG;
    }
    unsafe {
        *out = ptr::null_mut();
    }
    let decoded = catch_unwind(AssertUnwindSafe(|| {
        ensure(
            !context.poisoned,
            POISONED,
            "decoder is poisoned; reset and replay from FDE",
        )?;
        ensure(
            !bytes.is_null() && (count == 0 || !kinds.is_null()),
            ARG,
            "null input buffer",
        )?;
        ensure(
            length <= context.max_event as u64,
            LIMIT,
            "event size limit exceeded",
        )?;
        ensure(
            count as usize <= MAX_COLUMNS,
            LIMIT,
            "historical column limit exceeded",
        )?;
        let bytes = unsafe { slice::from_raw_parts(bytes, length as usize) };
        let kinds = if count == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(kinds, count as usize) }
        };
        ensure(filter_table <= 1, ARG, "invalid filter mode")?;
        context.decode_filtered(bytes, offset, kinds, filter_table == 1)
    }));
    let (status, value) = match decoded {
        Ok(Ok(value)) => (0, value),
        error => {
            context.poisoned = true;
            let (code, message) = match error {
                Ok(Err(e)) => e,
                _ => (INTERNAL, "Rust parser panic; context discarded"),
            };
            let mut value = Batch::new(offset, 0);
            // Do not dereference unchecked buffers on failure. Swift also records
            // the observed header type alongside the structured error.
            value.error = message.as_bytes().to_vec();
            (code, value)
        }
    };
    unsafe {
        *out = Box::into_raw(Box::new(value));
    }
    status
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_result_is_filtered(result: *const Batch) -> u32 {
    if result.is_null() {
        return 0;
    }
    unsafe { (&*result).filtered as u32 }
}
// Getters perform only checked indexing and copy fixed-width fields; no parser,
// allocation, destructors, formatting or panicking operations cross these calls.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_result_event(result: *const Batch, out: *mut EventView) -> i32 {
    if result.is_null() || out.is_null() {
        return ARG;
    }
    unsafe {
        *out = (&*result).view();
    }
    0
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_result_column(
    result: *const Batch,
    column: u32,
    out: *mut ColumnView,
) -> i32 {
    if result.is_null() || out.is_null() {
        return ARG;
    }
    let Some(c) = (unsafe { &*result }).map_columns.get(column as usize) else {
        return ARG;
    };
    unsafe {
        *out = ColumnView {
            kind: c.kind,
            column_type: c.column_type,
            maximum_bytes: c.maximum_bytes,
            nullable: c.nullable,
            collation: c.collation,
            primary_key: c.primary_key,
            name: Bytes::new(&c.name),
            metadata: Bytes::new(&c.metadata),
            unsigned_flag: c.unsigned_flag,
        };
    }
    0
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_result_value(
    result: *const Batch,
    row: u32,
    image: u32,
    column: u32,
    out: *mut ValueView,
) -> i32 {
    if result.is_null() || out.is_null() {
        return ARG;
    }
    let batch = unsafe { &*result };
    if column as usize >= batch.columns {
        return ARG;
    }
    let Some(row) = batch.rows.get(row as usize) else {
        return ARG;
    };
    let Some(values) = row.get(image as usize) else {
        return ARG;
    };
    unsafe {
        *out = values.get(column as usize).unwrap_or(&Cell::Absent).view();
    }
    0
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_result_free(result: *mut Batch) {
    if !result.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
            drop(Box::from_raw(result));
        }));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const FILE: &[u8] =
        include_bytes!("../../tests/ReplicatorLabTests/Fixtures/source-positive.binlog");
    #[test]
    fn panic_is_contained_at_the_export_and_requires_replay() {
        let n = u32::from_le_bytes(FILE[13..17].try_into().unwrap()) as usize;
        let frame = &FILE[4..4 + n];
        let mut context = Decoder::new(1024);
        context.panic_next = true;
        let mut result = ptr::null_mut();
        unsafe {
            assert_eq!(
                rc_decoder_feed(
                    &mut context,
                    frame.as_ptr(),
                    frame.len() as u64,
                    4,
                    ptr::null(),
                    0,
                    &mut result
                ),
                INTERNAL
            );
            assert!((*result).rows.is_empty());
            assert_eq!((*result).error, b"Rust parser panic; context discarded");
            rc_result_free(result);
            assert_eq!(
                rc_decoder_feed(
                    &mut context,
                    frame.as_ptr(),
                    frame.len() as u64,
                    4,
                    ptr::null(),
                    0,
                    &mut result
                ),
                POISONED
            );
            rc_result_free(result);
            assert_eq!(rc_decoder_reset(&mut context), 0);
            assert_eq!(
                rc_decoder_feed(
                    &mut context,
                    frame.as_ptr(),
                    frame.len() as u64,
                    4,
                    ptr::null(),
                    0,
                    &mut result
                ),
                0
            );
            rc_result_free(result);
        }
    }
}
