-- One event = one autocommit statement = one source GTID. No explicit transactions.
-- Each thread owns disjoint keys, including across its INSERT/UPDATE/DELETE cycle.
sysbench.cmdline.options = {
   rows_per_event = {"Rows changed by each statement", 1},
   payload_bytes = {"ASCII payload bytes per row", 100},
   tables = {"Number of benchmark tables", 1},
   table_distribution = {"uniform or hot80", "uniform"},
   table_run = {"Consecutive insert cycles per table selection", 1},
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
   -- Keep all phases of a mixed cycle on the same table. Thread IDs stagger
   -- routing, while row keys remain disjoint independently of table selection.
   local slot = math.floor(cycle / sysbench.opt.table_run) + sysbench.tid
   local table_id = slot % sysbench.opt.tables
   if sysbench.opt.table_distribution == "hot80" then
      table_id = slot % 5 < 4 and 0 or (1 + math.floor(slot / 5) % (sysbench.opt.tables - 1))
   end
   local name = table_id == 0 and "bench" or ("bench_" .. table_id)
   local first = (cycle * sysbench.opt.threads + sysbench.tid) * sysbench.opt.rows_per_event + 1
   local last = first + sysbench.opt.rows_per_event - 1
   if phase == 0 then
      local values = {}
      for id = first, last do
         values[#values + 1] = string.format("(%d,'%s',0)", id, payload)
      end
      connection:query("INSERT INTO " .. name .. "(id,payload,quantity) VALUES " .. table.concat(values, ","))
   elseif phase == 1 then
      connection:query(string.format("UPDATE %s SET quantity=quantity+1 WHERE id BETWEEN %d AND %d", name, first, last))
   else
      connection:query(string.format("DELETE FROM %s WHERE id BETWEEN %d AND %d", name, first, last))
   end
   ordinal = ordinal + 1
end

function thread_done()
   connection:disconnect()
end
