START TRANSACTION;
UPDATE reverse_poc.aux SET counter=counter+1 WHERE id=1;
UPDATE reverse_poc.items SET choice='done' WHERE id=2;
COMMIT;
