//! Exact MySQL 5.7-compatible scalar representations. No floating-point conversion.
use super::*;

pub(super) fn decode<'a>(
    ty: ColumnType,
    meta: &'a [u8],
    kind: u32,
    buf: &mut ParseBuf<'a>,
) -> Checked<Cell> {
    use ColumnType::*;
    // mysql_common treats YEAR's zero byte as 1900; MySQL uses the special year 0000.
    if ty == MYSQL_TYPE_YEAR {
        let year = take(&mut buf.0, 1)?[0];
        return Ok(Cell::Temporal(
            format!("{:04}", if year == 0 { 0 } else { 1900 + u32::from(year) }).into_bytes(),
        ));
    }
    let scalar_type = if ty == MYSQL_TYPE_DATE {
        MYSQL_TYPE_NEWDATE
    } else {
        ty
    };
    let value = if ty == MYSQL_TYPE_TIME2 && matches!(meta[0], 1 | 2) {
        // mysql_common uses unsigned subtraction for negative short fractions.
        // MySQL 5.7 sql-common/my_time.c::my_time_packed_from_binary requires
        // a signed fraction when undoing the reversed fractional encoding.
        let bytes = take(&mut buf.0, 4)?;
        let mut whole =
            ((i64::from(bytes[0]) << 16) | (i64::from(bytes[1]) << 8) | i64::from(bytes[2]))
                - 0x800000;
        let mut fraction = i64::from(bytes[3]);
        if whole < 0 && fraction != 0 {
            whole += 1;
            fraction -= 256;
        }
        BinlogValue::Value(mysql_common::binlog::misc::time_from_packed(
            whole * (1 << 24) + fraction * 10_000,
        ))
    } else {
        parsed(BinlogValue::deserialize(
            (scalar_type, meta, false, false),
            buf,
        ))?
    };
    let text = match value {
        BinlogValue::Value(Value::Bytes(v)) if kind == 6 => return Ok(Cell::Decimal(v)),
        BinlogValue::Value(Value::Bytes(v)) if ty == MYSQL_TYPE_TIMESTAMP2 => {
            let raw = std::str::from_utf8(&v).map_err(|_| (MALFORMED, "invalid timestamp"))?;
            let (seconds, fraction) = raw.split_once('.').unwrap_or((raw, "000000"));
            let seconds: u32 = seconds
                .parse()
                .map_err(|_| (MALFORMED, "invalid timestamp seconds"))?;
            ensure(
                seconds <= i32::MAX as u32,
                UNSUPPORTED,
                "timestamp outside MySQL 5.7 range",
            )?;
            if seconds == 0 {
                ensure(fraction == "000000", MALFORMED, "fractional zero timestamp")?;
                "0000-00-00 00:00:00.000000".to_owned()
            } else {
                // Integer-only UTC calendar conversion over MySQL 5.7's 1970..2038 range.
                let mut days = seconds / 86400;
                let mut year = 1970;
                loop {
                    let n = if leap(year) { 366 } else { 365 };
                    if days < n {
                        break;
                    }
                    days -= n;
                    year += 1;
                }
                let mut month = 1;
                for n in [
                    31,
                    if leap(year) { 29 } else { 28 },
                    31,
                    30,
                    31,
                    30,
                    31,
                    31,
                    30,
                    31,
                    30,
                    31,
                ] {
                    if days < n {
                        break;
                    }
                    days -= n;
                    month += 1;
                }
                format!(
                    "{year:04}-{month:02}-{:02} {:02}:{:02}:{:02}.{fraction}",
                    days + 1,
                    seconds / 3600 % 24,
                    seconds / 60 % 60,
                    seconds % 60
                )
            }
        }
        BinlogValue::Value(Value::Date(y, m, d, h, min, s, us)) => {
            ensure(
                y <= 9999 && m <= 12 && d <= 31 && h < 24 && min < 60 && s < 60 && us < 1_000_000,
                MALFORMED,
                "invalid date/time fields",
            )?;
            if matches!(ty, MYSQL_TYPE_DATE | MYSQL_TYPE_NEWDATE) {
                format!("{y:04}-{m:02}-{d:02}")
            } else {
                format!("{y:04}-{m:02}-{d:02} {h:02}:{min:02}:{s:02}.{us:06}")
            }
        }
        BinlogValue::Value(Value::Time(negative, days, h, min, s, us)) => {
            let hours = u64::from(days) * 24 + u64::from(h);
            ensure(
                hours <= 838
                    && min < 60
                    && s < 60
                    && us < 1_000_000
                    && (hours < 838 || min < 59 || s < 59 || us == 0),
                MALFORMED,
                "invalid TIME fields",
            )?;
            let sign = if negative && (hours != 0 || min != 0 || s != 0 || us != 0) {
                "-"
            } else {
                ""
            };
            format!("{sign}{hours:02}:{min:02}:{s:02}.{us:06}")
        }
        _ => return Err((UNSUPPORTED, "unsupported scalar representation")),
    };
    Ok(Cell::Temporal(text.into_bytes()))
}

fn leap(year: u32) -> bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn text(ty: ColumnType, meta: &[u8], kind: u32, bytes: &[u8]) -> String {
        let mut input = ParseBuf(bytes);
        let value = decode(ty, meta, kind, &mut input).unwrap();
        assert!(input.is_empty());
        match value {
            Cell::Decimal(v) | Cell::Temporal(v) => String::from_utf8(v).unwrap(),
            _ => panic!("wrong scalar kind"),
        }
    }
    #[test]
    fn exact_decimal_and_year_wire_vectors() {
        use ColumnType::*;
        // DECIMAL(5,2): two bytes for three integer digits, one for two fractional digits.
        assert_eq!(
            text(MYSQL_TYPE_NEWDECIMAL, &[5, 2], 6, &[0x80, 0x7b, 0x2d]),
            "123.45"
        );
        assert_eq!(
            text(MYSQL_TYPE_NEWDECIMAL, &[5, 2], 6, &[0x7f, 0x84, 0xd2]),
            "-123.45"
        );
        assert_eq!(text(MYSQL_TYPE_YEAR, &[], 7, &[0]), "0000");
        assert_eq!(text(MYSQL_TYPE_YEAR, &[], 7, &[255]), "2155");
        let packed = (2024_u32 * 16 + 2) * 32 + 29;
        assert_eq!(
            text(MYSQL_TYPE_DATE, &[], 7, &packed.to_le_bytes()[..3]),
            "2024-02-29"
        );
    }
    #[test]
    fn timestamp_utc_boundaries_and_fraction_are_exact() {
        use ColumnType::*;
        assert_eq!(
            text(MYSQL_TYPE_TIMESTAMP2, &[0], 7, &[0, 0, 0, 0]),
            "0000-00-00 00:00:00.000000"
        );
        assert_eq!(
            text(MYSQL_TYPE_TIMESTAMP2, &[0], 7, &[0, 0, 0, 1]),
            "1970-01-01 00:00:01.000000"
        );
        assert_eq!(
            text(
                MYSQL_TYPE_TIMESTAMP2,
                &[6],
                7,
                &[0x7f, 0xff, 0xff, 0xff, 0x0f, 0x42, 0x3f]
            ),
            "2038-01-19 03:14:07.999999"
        );
        let mut out_of_range = ParseBuf(&[0x80, 0, 0, 0]);
        assert!(decode(MYSQL_TYPE_TIMESTAMP2, &[0], 7, &mut out_of_range).is_err());
        let mut truncated = ParseBuf(&[0, 0, 0]);
        assert!(decode(MYSQL_TYPE_TIMESTAMP2, &[6], 7, &mut truncated).is_err());
    }
    #[test]
    fn negative_short_time_fractions_use_signed_arithmetic() {
        use ColumnType::*;
        assert_eq!(
            text(MYSQL_TYPE_TIME2, &[0], 7, &[0x7f, 0x37, 0x48]),
            "-12:34:56.000000"
        );
        assert_eq!(
            text(MYSQL_TYPE_TIME2, &[3], 7, &[0x7f, 0xff, 0xff, 0xfb, 0x32]),
            "-00:00:00.123000"
        );
        assert_eq!(
            text(MYSQL_TYPE_TIME2, &[4], 7, &[0x7f, 0xff, 0xff, 0xfb, 0x2e]),
            "-00:00:00.123400"
        );
        for (precision, micros) in [(5, 123450_u64), (6, 123456_u64)] {
            let packed = ((1_u64 << 47) - micros).to_be_bytes();
            assert_eq!(
                text(MYSQL_TYPE_TIME2, &[precision], 7, &packed[2..]),
                format!("-00:00:00.{micros:06}")
            );
        }
        assert_eq!(
            text(MYSQL_TYPE_TIME2, &[1], 7, &[0x7f, 0xff, 0xff, 0xf6]),
            "-00:00:00.100000"
        );
        assert_eq!(
            text(MYSQL_TYPE_TIME2, &[2], 7, &[0x7f, 0xff, 0xff, 0xff]),
            "-00:00:00.010000"
        );
        assert_eq!(
            text(MYSQL_TYPE_TIME2, &[2], 7, &[0x80, 0xc8, 0xb8, 12]),
            "12:34:56.120000"
        );
    }
}
