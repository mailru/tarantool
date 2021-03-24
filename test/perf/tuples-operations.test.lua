-- Test to check performance of inserts/replaces/upserts/deletes tuples.
-- Test executes 10,000 operations of each type and calculates performance
-- of each type of operation in Mrps. Results are saved in table format in
-- the file with a name perf.txt, located in test working directory.
-- If you want to check performance of you changes, run this test several
-- times before and after them, calculate the average values of the results
-- for each type of operation, and compare them with each other.
-- Do not forget that file with test results is overwritten every time
-- the test is restarted.
env = require('test_run')
clock = require('clock')
test_run = env.new()

objcount = 10000
test_run:cmd("setopt delimiter ';'")
function benchmark(op, count, space, result)
    local time_before = clock.monotonic64()
    if op == "insert" then
        for key = 1, count do
            space:insert({key, key + 1000})
        end
    elseif op == "replace" then
        for key = 1, count do
            space:replace({key, key + 5000})
        end
    elseif op == "upsert" then
        for key = 1, count do
            space:upsert({key, key + 5000}, {{'=', 2, key + 10000}})
        end
    elseif op == "delete" then
        for key = 1, count do
            space:delete({key})
        end
    else
        assert(0)
    end
    result[op] = (count * 1.0e9) / (1.0e6 * tonumber(clock.monotonic64() - time_before))
end;
function benchmark_save_result(result)
    local ops = { ["insert"] = true, ["replace"] = true,
                  ["upsert"] = true, ["delete"] = true }
    local file = io.open("tuples-operations-perf.txt", "w+")
    if file == nil then
        return
    end
    io.output(file)
    io.write(" _______________________________________\n")
    io.write("|     operation     | performance, Mrps |\n")
    io.write("|---------------------------------------|\n")
    for op, val in pairs(result) do
        assert(ops[op])
        io.write(string.format("|     %s", op))
        for _ = 1, 14 - #op do
            io.write(" ")
        end
        io.write(string.format("|       %0.3f       |\n", val))
    end
    io.write("|---------------------------------------|\n")
    io.close(file)
end;
test_run:cmd("setopt delimiter ''");

space = box.schema.space.create('test')
test_run:cmd("setopt delimiter ';'")
space:format({ {name = 'id', type = 'unsigned'},
               {name = 'year', type = 'unsigned'} });
test_run:cmd("setopt delimiter ''");
_ = space:create_index('primary', { parts = {'id'} })

result = {}
ops = { "insert", "replace", "upsert", "delete" }
test_run:cmd("setopt delimiter ';'")
for i = 1, #ops  do
    benchmark(ops[i], objcount, space, result)
end;
test_run:cmd("setopt delimiter ''");
benchmark_save_result(result)
space:drop()