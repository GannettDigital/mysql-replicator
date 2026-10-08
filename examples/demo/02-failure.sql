-- Run on SOURCE only, after 01-success.sql and a passing demo compare.
-- Source accepts this. The native replica disables InnoDB (error 3161).
-- Swift rejects explicit InnoDB without rewriting it or advancing its checkpoint.
SET NAMES utf8mb4;
SET autocommit=1;
CREATE TABLE demo.explicit_innodb (id INT PRIMARY KEY) ENGINE=InnoDB;
-- This valid later event must NOT reach either target after the DDL failure.
INSERT INTO demo.items VALUES (999,'must not replicate',999,'after failure');
SELECT * FROM demo.items WHERE id=999;
