-- Run once on SOURCE, after 03-after-skip.sql, while Swift is running.
-- Native 8.4 remains blocked on the earlier deliberate failure.
SET NAMES utf8mb4;
SET autocommit=1;
ALTER TABLE demo.items MODIFY COLUMN value VARCHAR(120) NOT NULL;
CREATE INDEX value_lookup ON demo.items (value(20));
ALTER TABLE demo.items RENAME INDEX value_lookup TO value_prefix;
ALTER TABLE demo.items DROP INDEX value_prefix, ADD INDEX value_prefix (value(30),quantity);
INSERT INTO demo.items VALUES (1001,REPEAT('x',110),41,'after MODIFY and indexes');
UPDATE demo.items SET value=CONCAT(REPEAT('x',109),'y'),quantity=42 WHERE id=1001;
DELETE FROM demo.items WHERE id=1001;
SHOW INDEX FROM demo.items;
SELECT * FROM demo.items ORDER BY id;
