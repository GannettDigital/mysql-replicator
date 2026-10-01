-- Run once, on SOURCE only, after demo-up and demo-start.
-- Each mutation is autocommit: this matches the qualified GTID -> MyISAM path.
SET NAMES utf8mb4;
SET autocommit=1;
CREATE SCHEMA demo DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
-- ENGINE is deliberately omitted: source uses InnoDB, each replica uses MyISAM.
CREATE TABLE demo.items (id INT PRIMARY KEY, value VARCHAR(100) NOT NULL, quantity BIGINT UNSIGNED NOT NULL);
INSERT INTO demo.items VALUES (1,'first',10),(2,'delete me',20);
UPDATE demo.items SET value='updated',quantity=11 WHERE id=1;
DELETE FROM demo.items WHERE id=2;
ALTER TABLE demo.items ADD COLUMN note VARCHAR(40) NULL;
UPDATE demo.items SET note='after DDL' WHERE id=1;
INSERT INTO demo.items VALUES (3,'third',30,NULL);
SELECT * FROM demo.items ORDER BY id;
