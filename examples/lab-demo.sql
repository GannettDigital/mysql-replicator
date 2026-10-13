-- Common to all profiles. Run once in a fresh demo.
INSERT INTO reverse_poc.aux VALUES (1,10),(2,20);
UPDATE reverse_poc.aux SET counter=counter+1 WHERE id=1;
DELETE FROM reverse_poc.aux WHERE id=2;
CREATE DATABASE lab_example CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE TABLE lab_example.items(id INT PRIMARY KEY, value VARCHAR(40));
INSERT INTO lab_example.items VALUES(1,'created through replication');
-- demo compare checks the baseline reverse_poc tables. Inspect lab_example
-- in the printed SQL shells; use the correctness suite for full DDL assertions.
