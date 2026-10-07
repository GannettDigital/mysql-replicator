-- Tables are preloaded on all three nodes. DDL is deliberately outside this demo.
START TRANSACTION;
INSERT INTO reverse_poc.items VALUES
  ('2026-10-06',2,'demo',2.25,'ready','a,b',X'00FF'),
  ('2026-10-06',3,'temporary',3.50,'done','b',NULL);
INSERT INTO reverse_poc.aux VALUES(1,10);
UPDATE reverse_poc.items SET value='updated',amount=7.75 WHERE id=2;
UPDATE reverse_poc.items SET report_date='2026-10-07' WHERE id=2;
DELETE FROM reverse_poc.items WHERE id=3;
COMMIT;
