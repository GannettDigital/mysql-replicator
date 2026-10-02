-- One event = one autocommit statement = one source GTID. No explicit transactions.
-- Each thread owns disjoint keys, including across its INSERT/UPDATE/DELETE cycle.
sysbench.cmdline.options = {
   rows_per_event = {"Rows changed by each statement", 1},
   payload_bytes = {"ASCII payload bytes per row", 100},
   workload = {"insert or mixed", "insert"}
}

function thread_init()
   connection = sysbench.sql.driver():connect()
   connection:query("SET SESSION autocommit=1")
   connection:query("SET NAMES utf8mb4 COLLATE utf8mb4_bin")
   ordinal = 0
   payload = string.rep("x", sysbench.opt.payload_bytes)
end

function event()
   local mixed = sysbench.opt.workload == "mixed"
   local cycle = mixed and math.floor(ordinal / 3) or ordinal
   local phase = mixed and ordinal % 3 or 0
   local first = (cycle * sysbench.opt.threads + sysbench.tid) * sysbench.opt.rows_per_event + 1
   local last = first + sysbench.opt.rows_per_event - 1
   if phase == 0 then
      local values = {}
      for id = first, last do
         values[#values + 1] = string.format("(%d,'%s',0)", id, payload)
      end
      connection:query("INSERT INTO bench(id,payload,quantity) VALUES " .. table.concat(values, ","))
   elseif phase == 1 then
      connection:query(string.format("UPDATE bench SET quantity=quantity+1 WHERE id BETWEEN %d AND %d", first, last))
   else
      connection:query(string.format("DELETE FROM bench WHERE id BETWEEN %d AND %d", first, last))
   end
   ordinal = ordinal + 1
end

function thread_done()
   connection:disconnect()
end
