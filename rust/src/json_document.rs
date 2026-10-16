//! Full binary JSON documents. Do not flatten MySQL opaque values into strings.
use crate::{Checked, LIMIT, MALFORMED, UNSUPPORTED, ensure, parsed};
use mysql_common::{binlog::jsonb::{Value, ComplexValue, StorageFormat, Array, Object}, io::ParseBuf, proto::MyDeserialize};
use std::collections::HashSet;
use mysql_common::binlog::{decimal::{Decimal, decimal_bin_size}, time::MysqlTime};

struct Typed { path: String, code: u16, raw: Vec<u8>, value: String, precision: usize, scale: usize }

struct Writer { out: Vec<u8>, maximum: usize, nodes: usize, typed: Vec<Typed>, typed_bytes: usize }
impl Writer {
    fn bytes(&mut self, bytes: &[u8]) -> Checked<()> {
        ensure(bytes.len() <= self.maximum.saturating_sub(self.out.len()), LIMIT, "JSON output limit exceeded")?;
        self.out.extend_from_slice(bytes); Ok(())
    }
    fn string(&mut self, bytes: &[u8]) -> Checked<()> {
        ensure(std::str::from_utf8(bytes).is_ok(), MALFORMED, "invalid JSON UTF-8")?;
        self.bytes(b"\"")?;
        let mut start = 0;
        for (i, &b) in bytes.iter().enumerate() {
            if b < 32 || b == b'"' || b == b'\\' {
                self.bytes(&bytes[start..i])?;
                if b < 32 { self.bytes(format!("\\u{b:04x}").as_bytes())?; }
                else { self.bytes(&[b'\\', b])?; }
                start = i + 1;
            }
        }
        self.bytes(&bytes[start..])?; self.bytes(b"\"")
    }
    fn array<T: StorageFormat>(&mut self, a: &ComplexValue<'_, T, Array>, depth: usize, path: &str) -> Checked<()> {
        self.bytes(b"[")?;
        for (i, value) in a.iter().enumerate() {
            if i > 0 { self.bytes(b",")?; }
            self.value(parsed(value)?, depth + 1, &format!("{path}[{i}]"))?;
        }
        self.bytes(b"]")
    }
    fn object<T: StorageFormat>(&mut self, o: &ComplexValue<'_, T, Object>, depth: usize, path: &str) -> Checked<()> {
        self.bytes(b"{")?;
        let mut keys = HashSet::new();
        for (i, pair) in o.iter().enumerate() {
            let (key, value) = parsed(pair)?;
            ensure(keys.insert(key.value_raw().to_vec()), MALFORMED, "duplicate binary JSON key")?;
            if i > 0 { self.bytes(b",")?; }
            self.string(key.value_raw())?; self.bytes(b":")?;
            let mut escaped = Writer::new(self.maximum, 1);
            escaped.string(key.value_raw())?;
            let key_path = format!("{path}.{}", String::from_utf8(escaped.out).unwrap());
            self.value(value, depth + 1, &key_path)?;
        }
        self.bytes(b"}")
    }
    fn integer(&mut self, value: String, code: u16, path: &str) -> Checked<()> {
        self.typed_scalar(code, &[], value, 0, 0, path)
    }
    fn typed_scalar(&mut self, code: u16, raw: &[u8], value: String, precision: usize, scale: usize, path: &str) -> Checked<()> {
        // Binary containers can point several entries at the same payload.
        // Bound retained annotations before copying those payloads.
        let size = raw.len().saturating_mul(2).saturating_add(path.len()).saturating_add(value.len()).saturating_add(128);
        ensure(size <= self.maximum.saturating_sub(self.typed_bytes), LIMIT, "JSON typed output limit exceeded")?;
        self.typed_bytes += size;
        self.typed.push(Typed { path: path.to_owned(), code, raw: raw.to_vec(), value, precision, scale });
        self.bytes(b"null")
    }
    fn value(&mut self, value: Value<'_>, depth: usize, path: &str) -> Checked<()> {
        ensure(depth <= 100 && self.nodes > 0, LIMIT, "JSON depth or traversal limit exceeded")?;
        self.nodes -= 1;
        match value {
            Value::Null => self.bytes(b"null"),
            Value::Bool(v) => self.bytes(if v { b"true" } else { b"false" }),
            Value::I16(v) => self.integer(v.to_string(), 1000, path),
            Value::U16(v) => self.integer(v.to_string(), 1001, path),
            Value::I32(v) => self.integer(v.to_string(), 1000, path),
            Value::U32(v) => self.integer(v.to_string(), 1001, path),
            Value::I64(v) => self.integer(v.to_string(), 1000, path),
            Value::U64(v) => self.integer(v.to_string(), 1001, path),
            Value::F64(v) => {
                ensure(v.is_finite(), UNSUPPORTED, "non-finite JSON double")?;
                // Debug formatting retains a decimal point or exponent for integral doubles.
                self.bytes(format!("{v:?}").as_bytes())
            }
            Value::String(v) => self.string(v.str_raw()),
            Value::SmallArray(v) => self.array(&v, depth, path),
            Value::LargeArray(v) => self.array(&v, depth, path),
            Value::SmallObject(v) => self.object(&v, depth, path),
            Value::LargeObject(v) => self.object(&v, depth, path),
            Value::Opaque(v) => {
                let raw = v.data_raw(); let code = v.value_type() as u16;
                let (value, precision, scale) = match code {
                    246 => {
                        ensure(raw.len() >= 2, MALFORMED, "truncated JSON DECIMAL")?;
                        let p = raw[0] as usize; let s = raw[1] as usize;
                        // Json_decimal stores my_decimal's internal precision. Its
                        // integer part can be padded to a nine-digit word, so a
                        // SQL DECIMAL(65,30) can carry precision 66 here.
                        ensure((1..=81).contains(&p) && s <= p && s <= 30
                            && (p-s).div_ceil(9) + s.div_ceil(9) <= 9
                            && raw.len() == 2 + decimal_bin_size(p,s), MALFORMED, "invalid JSON DECIMAL metadata")?;
                        (parsed(Decimal::read_packed(raw, false))?.to_string(), p, s)
                    }
                    7 | 10 | 11 | 12 => {
                        ensure(raw.len() == 8, MALFORMED, "invalid packed JSON temporal length")?;
                        let packed = i64::from_le_bytes(raw.try_into().unwrap());
                        ensure(packed != i64::MIN, MALFORMED, "invalid packed JSON temporal value")?;
                        if code == 10 {
                            ensure(packed >= 0 && packed & ((1i64 << 41) - 1) == 0, MALFORMED, "invalid packed JSON DATE bits")?;
                        }
                        if code == 11 {
                            ensure(packed.unsigned_abs() >> 46 == 0, MALFORMED, "invalid packed JSON TIME bits")?;
                        }
                        let t = match code {
                            10 => MysqlTime::from_int64_date_packed(packed),
                            11 => MysqlTime::from_int64_time_packed(packed),
                            _ => MysqlTime::from_int64_datetime_packed(packed),
                        };
                        ensure(t.year <= 9999 && t.month <= 12 && t.day <= 31 && t.minute <= 59 && t.second <= 59 && t.second_part <= 999999 && (if code == 11 { t.hour <= 838 } else { !t.neg && t.hour <= 23 }), MALFORMED, "invalid JSON temporal fields")?;
                        let value = if code == 10 { format!("{:04}-{:02}-{:02}", t.year,t.month,t.day) }
                        else if code == 11 { format!("{}{:02}:{:02}:{:02}.{:06}",if t.neg { "-" } else { "" },t.hour,t.minute,t.second,t.second_part) }
                        else { format!("{:04}-{:02}-{:02} {:02}:{:02}:{:02}.{:06}",t.year,t.month,t.day,t.hour,t.minute,t.second,t.second_part) };
                        (value,0,0)
                    }
                    _ => (String::new(),0,0),
                };
                self.typed_scalar(code, raw, value, precision, scale, path)
            },
        }
    }
}
impl Writer {
    fn new(maximum: usize, nodes: usize) -> Self { Self { out: Vec::new(), maximum, nodes, typed: Vec::new(), typed_bytes: 0 } }
    fn envelope(self) -> Checked<Vec<u8>> {
        let mut out = Writer::new(self.maximum, 1);
        out.bytes(b"{\"text\":")?; out.string(&self.out)?; out.bytes(b",\"typed\":[")?;
        for (i,t) in self.typed.iter().enumerate() {
            if i > 0 { out.bytes(b",")?; }
            out.bytes(b"{\"path\":")?; out.string(t.path.as_bytes())?;
            out.bytes(format!(",\"type\":{},\"precision\":{},\"scale\":{},\"value\":",t.code,t.precision,t.scale).as_bytes())?;
            out.string(t.value.as_bytes())?; out.bytes(b",\"rawHex\":\"")?;
            for b in &t.raw { out.bytes(format!("{b:02x}").as_bytes())?; }
            out.bytes(b"\"}")?;
        }
        out.bytes(b"]}")?; Ok(out.out)
    }
}
pub(crate) fn decode(bytes: &[u8], maximum: usize) -> Checked<Vec<u8>> {
    let mut buf = ParseBuf(bytes);
    let value = parsed(Value::deserialize((), &mut buf))?;
    ensure(buf.is_empty(), MALFORMED, "trailing binary JSON bytes")?;
    let mut writer = Writer::new(maximum, bytes.len().saturating_mul(2).max(1));
    writer.value(value, 1, "$")?;
    writer.envelope()
}
pub(crate) fn length(buf: &mut &[u8]) -> Checked<usize> {
    let first = crate::take(buf,1)?[0];
    let n = match first { 0..=250 => return Ok(first as usize), 252 => 2, 253 => 3, 254 => 8, _ => return Err((MALFORMED,"invalid JSON length code")) };
    let bytes = crate::take(buf,n)?;
    let value = bytes.iter().enumerate().fold(0u64, |n,(i,b)| n | (u64::from(*b) << (i*8)));
    usize::try_from(value).map_err(|_| (LIMIT,"JSON length overflow"))
}
pub(crate) fn delta(mut bytes: &[u8], maximum: usize) -> Checked<Vec<u8>> {
    let mut out = Writer::new(maximum,1); out.bytes(b"[")?;
    let mut first = true;
    while !bytes.is_empty() {
        let op = crate::take(&mut bytes,1)?[0]; ensure(op <= 2,MALFORMED,"unknown JSON diff operation")?;
        let length = length(&mut bytes)?; let path = crate::take(&mut bytes,length)?;
        if !first { out.bytes(b",")?; } first = false;
        out.bytes(format!("{{\"operation\":{op},\"path\":").as_bytes())?; out.string(path)?;
        if op != 2 {
            let length = self::length(&mut bytes)?; let value = crate::take(&mut bytes,length)?;
            out.bytes(b",\"value\":")?;
            let document = decode(value,maximum.saturating_sub(out.out.len()))?; out.bytes(&document)?;
        }
        out.bytes(b"}")?;
    }
    out.bytes(b"]")?; Ok(out.out)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bounds_and_malformed_types_fail_without_lossy_conversion() {
        assert_eq!(decode(&[4, 0], 100).unwrap(), br#"{"text":"null","typed":[]}"#);
        assert_eq!(decode(&[4, 0], 3).unwrap_err().0, LIMIT);
        assert_eq!(decode(&[15, 246, 0], 100).unwrap_err().0, MALFORMED);
        let mut nested = vec![12, 1, b'x'];
        for _ in 0..100 {
            let size = (7 + nested.len() - 1) as u16;
            let mut array = vec![2, 1, 0];
            array.extend(size.to_le_bytes());
            array.extend([nested[0], 7, 0]);
            array.extend(&nested[1..]);
            nested = array;
        }
        assert_eq!(decode(&nested, 10000).unwrap_err().0, LIMIT);
        // Every truncated prefix of a valid string fails.
        let valid = [12, 4, 0xf0, 0x9f, 0x98, 0x80];
        for n in 1..valid.len() { assert!(decode(&valid[..n], 100).is_err()); }
    }
}
