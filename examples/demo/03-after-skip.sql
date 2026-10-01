-- Run on SOURCE after skipping the rejected CREATE and resuming Swift.
-- Row 999 was already queued by 02-failure.sql; this is a new transaction.
SET NAMES utf8mb4;
SET autocommit=1;
INSERT INTO demo.items VALUES (1000,'replicated after skip',1000,'fresh insert');
SELECT * FROM demo.items WHERE id IN (999,1000) ORDER BY id;
