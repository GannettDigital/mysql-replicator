import base64
import struct
import unittest
import uuid
import zlib

from probe import apply_script, events, row_images, transaction_groups


def frame(kind, body=b"", flags=0):
    header = struct.pack("<IBIIIH", 0, kind, 991, 23 + len(body), 0, flags)
    data = header + body
    checked = bytearray(data)
    if kind == 15:
        checked[17] &= ~1
    return data + struct.pack("<I", zlib.crc32(checked))


class ProbeTests(unittest.TestCase):
    def test_fde_crc_excludes_only_binlog_in_use_flag(self):
        fde = frame(15, b"format", flags=1)
        self.assertEqual(list(events(b"\xfebin" + fde)), [fde])
        damaged = bytearray(fde)
        damaged[17] ^= 2
        with self.assertRaisesRegex(ValueError, "CRC32"):
            list(events(b"\xfebin" + damaged))

    def test_row_crc_and_truncated_input_are_rejected(self):
        row = frame(30, b"rows", flags=1)
        for data in [b"", b"\xfebin" + row[:-1], b"\xfebin" + row[:10],
                     b"\xfebin" + row[:-5] + b"x" + row[-4:]]:
            with self.subTest(data=data), self.assertRaises(ValueError):
                list(events(data))

    def test_groups_keep_all_row_frames_and_source_gtid(self):
        sid = uuid.UUID("11111111-1111-1111-1111-111111111111")
        gtid = frame(33, b"\0" + sid.bytes + struct.pack("<Q", 42))
        rows = [frame(19, b"map"), frame(30, b"row1"), frame(30, b"row2")]
        group = transaction_groups([gtid, *rows, frame(16, b"commit")])
        self.assertEqual(group, [dict(gtid=str(sid) + ":42", frames=rows)])
        for invalid in [[gtid, *rows], rows, [gtid, gtid], [frame(40)]]:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                transaction_groups(invalid)

    def test_script_separates_gtid_and_commit_from_binlog_rows(self):
        fde, row = frame(15, b"fde"), frame(30, b"row")
        groups = [dict(gtid="11111111-1111-1111-1111-111111111111:42", frames=[row])]
        sql = apply_script(fde, groups, "5.7")
        self.assertIn("pseudo_slave_mode=1", sql)
        self.assertIn("GTID_NEXT='" + groups[0]["gtid"] + "';\nBEGIN;", sql)
        self.assertIn("COMMIT;\nSET SESSION GTID_NEXT='AUTOMATIC';", sql)
        encoded = [line.split("'")[1] for line in sql.splitlines() if line.startswith("BINLOG ")]
        self.assertEqual([base64.b64decode(text) for text in encoded], [fde, row])
        self.assertIn("pseudo_replica_mode=1", apply_script(fde, groups, "8.4"))

    def test_row_comparison_ignores_padding_but_preserves_json_bytes(self):
        # Six-byte table ID, row flags, extra-header length, column count/bitmap.
        header = b"\0" * 8 + b"\x02\0\x03\xff"
        fields = struct.pack("<II", 1, 3) + b"\x0f\xfd\0" + b"\x02\0\0\xff"
        before = frame(30, header + b"\xf8" + fields)
        after = frame(30, header + b"\0" + fields)
        self.assertEqual(row_images([before]), row_images([after]))
        changed = frame(30, header + b"\0" + fields.replace(b"\x0f\xfd", b"\x0f\xfe"))
        self.assertNotEqual(row_images([before]), row_images([changed]))
        for body in [header + b"\x02" + fields, header + b"\0" + fields[:-1]]:
            with self.subTest(body=body), self.assertRaises(ValueError):
                row_images([frame(30, body)])


if __name__ == "__main__":
    unittest.main()
