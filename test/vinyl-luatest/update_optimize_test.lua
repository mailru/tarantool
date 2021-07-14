local t = require('luatest')
local g = t.group()
local fiber = require('fiber')
local log = require('log')

g.before_all = function()
    pcall(log.cfg, {level = 6})
    box.cfg {
        listen            = os.getenv("LISTEN"),
        memtx_memory      = 512 * 1024 * 1024,
        memtx_max_tuple_size = 4 * 1024 * 1024,
        vinyl_read_threads = 2,
        vinyl_write_threads = 3,
        vinyl_memory = 512 * 1024 * 1024,
        vinyl_range_size = 1024 * 64,
        vinyl_page_size = 1024,
        vinyl_run_count_per_level = 1,
        vinyl_run_size_ratio = 2,
        vinyl_cache = 10240, -- 10kB
        vinyl_max_tuple_size = 1024 * 1024 * 6,
    }

    require('console').listen(os.getenv('ADMIN'))
end

g.before_each(function()
    space = box.schema.space.create('test', { engine = 'vinyl' })
end)

g.after_each(function()
    space:drop()
end)

local function dumped_stmt_count(indices)
    local dumped_count = 0
    for _, index in ipairs(indices) do
        dumped_count = dumped_count + index:stat().disk.dump.output.rows
    end
    return dumped_count
end

local function wait_for_dump(index, old_count)
    while index:stat().disk.dump.count == old_count do
        fiber.sleep(0)
    end
    return index:stat().disk.dump.count
end

g.test_optimize_one_index = function()
    -- optimize one index

    local index = space:create_index('primary', { run_count_per_level = 20 })
    local index2 = space:create_index('secondary',
        { parts = {5, 'unsigned'}, run_count_per_level = 20 })
    t.assert_equals(box.snapshot(), 'ok')

    local dump_count = index:stat().disk.dump.count
    old_stmt_count = dumped_stmt_count({index, index2})
    t.assert_equals(space:insert({1, 2, 3, 4, 5}), {1, 2, 3, 4, 5})
    t.assert_equals(space:insert({2, 3, 4, 5, 6}), {2, 3, 4, 5, 6})
    t.assert_equals(space:insert({3, 4, 5, 6, 7}), {3, 4, 5, 6, 7})
    t.assert_equals(space:insert({4, 5, 6, 7, 8}), {4, 5, 6, 7, 8})
    t.assert_equals(box.snapshot(), 'ok')
    -- Wait for dump both indexes.
    dump_count = wait_for_dump(index, dump_count)
    local new_stmt_count = dumped_stmt_count({index, index2})
    t.assert_equals(new_stmt_count - old_stmt_count, 8)
    old_stmt_count = new_stmt_count
    -- not optimized updates
    -- change secondary index field
    t.assert_equals(space:update({1}, {{'=', 5, 10}}), {1, 2, 3, 4, 10})
    -- Need a snapshot after each operation to avoid purging some
    -- statements in vy_write_iterator during dump.
    t.assert_equals(box.snapshot(), 'ok')
    dump_count = wait_for_dump(index, dump_count)
    -- move range containing index field
    t.assert_equals(space:update({1}, {{'!', 4, 20}}), {1, 2, 3, 20, 4, 10})
    t.assert_equals(box.snapshot(), 'ok')
    dump_count = wait_for_dump(index, dump_count)
    -- move range containing index field
    t.assert_equals(space:update({1}, {{'#', 3, 1}}), {1, 2, 20, 4, 10})
    t.assert_equals(box.snapshot(), 'ok')
    dump_count = wait_for_dump(index, dump_count)
    new_stmt_count = dumped_stmt_count({index, index2})
    t.assert_equals(new_stmt_count - old_stmt_count, 9)
    old_stmt_count = new_stmt_count
    t.assert_equals(space:select{},
        {{1, 2, 20, 4, 10},
        {2, 3, 4, 5, 6},
        {3, 4, 5, 6, 7},
        {4, 5, 6, 7, 8}}
    )
    t.assert_equals(index2:select{},
        {{2, 3, 4, 5, 6},
        {3, 4, 5, 6, 7},
        {4, 5, 6, 7, 8},
        {1, 2, 20, 4, 10}}
    )
    -- optimized updates
    -- change not indexed field
    t.assert_equals(space:update({2}, {{'=', 6, 10}}), {2, 3, 4, 5, 6, 10})
    t.assert_equals(box.snapshot(), 'ok')
    dump_count = wait_for_dump(index, dump_count)
    -- Move range that doesn't contain indexed fields.
    t.assert_equals(space:update({2}, {{'!', 7, 20}}), {2, 3, 4, 5, 6, 10, 20})
    t.assert_equals(box.snapshot(), 'ok')
    dump_count = wait_for_dump(index, dump_count)
    t.assert_equals(space:update({2}, {{'#', 6, 1}}), {2, 3, 4, 5, 6, 20})
    t.assert_equals(box.snapshot(), 'ok')
    dump_count = wait_for_dump(index, dump_count)
    new_stmt_count = dumped_stmt_count({index, index2})
    t.assert_equals(new_stmt_count - old_stmt_count, 3)
    old_stmt_count = new_stmt_count
    t.assert_equals(space:select{},
        {{1, 2, 20, 4, 10},
        {2, 3, 4, 5, 6, 20},
        {3, 4, 5, 6, 7},
        {4, 5, 6, 7, 8}}
    )
    t.assert_equals(index2:select{},
        {{2, 3, 4, 5, 6, 20},
        {3, 4, 5, 6, 7},
        {4, 5, 6, 7, 8},
        {1, 2, 20, 4, 10}}
    )
end

g.test_optimize_two_indices = function()
    -- optimize two indexes
    local index = space:create_index('primary',
        { parts = {2, 'unsigned'}, run_count_per_level = 20 } )
    local index2 = space:create_index('secondary',
        { parts = {4, 'unsigned', 3, 'unsigned'}, run_count_per_level = 20 })
    local index3 = space:create_index('third',
        { parts = {5, 'unsigned'}, run_count_per_level = 20 })
    t.assert_equals(box.snapshot(), 'ok')
    local dump_count = index:stat().run_count
    local old_stmt_count = dumped_stmt_count({index, index2, index3})
    t.assert_equals(space:insert({1, 2, 3, 4, 5}), {1, 2, 3, 4, 5})
    t.assert_equals(space:insert({2, 3, 4, 5, 6}), {2, 3, 4, 5, 6})
    t.assert_equals(space:insert({3, 4, 5, 6, 7}), {3, 4, 5, 6, 7})
    t.assert_equals(space:insert({4, 5, 6, 7, 8}), {4, 5, 6, 7, 8})
    t.assert_equals(box.snapshot(), 'ok')
    dump_count = wait_for_dump(index, dump_count)
    local new_stmt_count = dumped_stmt_count({index, index2, index3})
    t.assert_equals(new_stmt_count - old_stmt_count, 12)
    old_stmt_count = new_stmt_count
    -- not optimizes updates
    t.assert_equals(
    index:update({2}, {{'+', 1, 10}, {'+', 3, 10}, {'+', 4, 10}, {'+', 5, 10}}),
        {11, 2, 13, 14, 15}) -- change all fields
    t.assert_equals(box.snapshot(), 'ok')
    dump_count = wait_for_dump(index, dump_count)
    t.assert_equals(
        index:update({2}, {{'!', 3, 20}}),
        {11, 2, 20, 13, 14, 15}) -- move range containing all indexes
    t.assert_equals(box.snapshot(), 'ok')
    dump_count = wait_for_dump(index, dump_count)
    t.assert_equals(
        index:update({2}, {{'=', 7, 100}, {'+', 5, 10}, {'#', 3, 1}}),
        {11, 2, 13, 24, 15, 100}
    )-- change two cols but then move range with all indexed fields
    t.assert_equals(box.snapshot(), 'ok')
    dump_count = wait_for_dump(index, dump_count)
    new_stmt_count = dumped_stmt_count({index, index2, index3})
    t.assert_equals(new_stmt_count - old_stmt_count, 15)
    old_stmt_count = new_stmt_count
    t.assert_equals(
        space:select{}, {{11, 2, 13, 24, 15, 100},
                         {2, 3, 4, 5, 6},
                         {3, 4, 5, 6, 7},
                         {4, 5, 6, 7, 8}})
    t.assert_equals(
        index2:select{}, {{2, 3, 4, 5, 6},
                         {3, 4, 5, 6, 7},
                         {4, 5, 6, 7, 8},
                         {11, 2, 13, 24, 15, 100}})
    t.assert_equals(
        index3:select{}, {{2, 3, 4, 5, 6},
                         {3, 4, 5, 6, 7},
                         {4, 5, 6, 7, 8},
                         {11, 2, 13, 24, 15, 100}})
    -- optimize one 'secondary' index update
    t.assert_equals(
        index:update({3}, {{'+', 1, 10}, {'-', 5, 2}, {'!', 6, 100}}),
        {12, 3, 4, 5, 4, 100}
    ) -- change only index 'third'
    t.assert_equals(box.snapshot(), 'ok')
    dump_count = wait_for_dump(index, dump_count)
    new_stmt_count = dumped_stmt_count({index, index2, index3})
    t.assert_equals(new_stmt_count - old_stmt_count, 3)
    old_stmt_count = new_stmt_count
    -- optimize one 'third' index update
    t.assert_equals(
    index:update(
        {3}, {{'=', 1, 20}, {'+', 3, 5}, {'=', 4, 30}, {'!', 6, 110}}),
        {20, 3, 9, 30, 4, 110, 100}
    ) -- change only index 'secondary'
    t.assert_equals(box.snapshot(), 'ok')
    dump_count = wait_for_dump(index, dump_count)
    new_stmt_count = dumped_stmt_count({index, index2, index3})
    t.assert_equals(new_stmt_count - old_stmt_count, 3)
    old_stmt_count = new_stmt_count
    -- optimize both indexes
    t.assert_equals(
        index:update({3}, {{'+', 1, 10}, {'#', 6, 1}}), {30, 3, 9, 30, 4, 100}
    ) -- don't change any indexed fields
    t.assert_equals(box.snapshot(), 'ok')
    dump_count = wait_for_dump(index, dump_count)
    new_stmt_count = dumped_stmt_count({index, index2, index3})
    t.assert_equals(new_stmt_count - old_stmt_count, 1)
    old_stmt_count = new_stmt_count
    t.assert_equals(
        space:select{}, {{11, 2, 13, 24, 15, 100},
                         {30, 3, 9, 30, 4, 100},
                         {3, 4, 5, 6, 7},
                         {4, 5, 6, 7, 8}})
    t.assert_equals(
        index2:select{}, {{3, 4, 5, 6, 7},
                          {4, 5, 6, 7, 8},
                          {11, 2, 13, 24, 15, 100},
                          {30, 3, 9, 30, 4, 100}})
    t.assert_equals(
        index3:select{}, {{30, 3, 9, 30, 4, 100},
                          {3, 4, 5, 6, 7},
                          {4, 5, 6, 7, 8},
                          {11, 2, 13, 24, 15, 100}})
end
g.before_test('test_field_greater_64', function()
    index = space:create_index('primary',
        { parts = {2, 'unsigned'}, run_count_per_level = 20 } )
    index2 = space:create_index('secondary',
        { parts = {4, 'unsigned', 3, 'unsigned'}, run_count_per_level = 20 })
    index3 = space:create_index('third',
        { parts = {5, 'unsigned'}, run_count_per_level = 20 })
    space:insert({1, 2, 3, 4, 5})
end)

g.test_field_greater_64 = function()
    -- gh-1716: optimize UPDATE with fieldno > 64.
    --
    -- Create a big tuple.
    local long_tuple = {}
    for i = 1, 70 do long_tuple[i] = i end
    local _ = space:replace(long_tuple)
    t.assert_equals(box.snapshot(), 'ok')
    -- Make update of not indexed field with pos > 64.
    local dump_count = wait_for_dump(index, dump_count)
    local old_stmt_count = dumped_stmt_count({index, index2, index3})
    _ = index:update({2}, {{'=', 65, 1000}})
    t.assert_equals(box.snapshot(), 'ok')
    -- Check the only primary index to be changed.
    dump_count = wait_for_dump(index, dump_count)
    local new_stmt_count = dumped_stmt_count({index, index2, index3})
    t.assert_equals(new_stmt_count - old_stmt_count, 1)
    old_stmt_count = new_stmt_count
    t.assert_equals(space:get{2}[65], 1000)
    -- Try to optimize update with negative field numbers.
    t.assert_equals(index:update({2}, {{'#', -65, 65}}), {1, 2, 3, 4, 5})
    t.assert_equals(box.snapshot(), 'ok')
    dump_count = wait_for_dump(index, dump_count)
    new_stmt_count = dumped_stmt_count({index, index2, index3})
    t.assert_equals(new_stmt_count - old_stmt_count, 1)
    old_stmt_count = new_stmt_count
    t.assert_equals(index:select{}, {{1, 2, 3, 4, 5}})
    t.assert_equals(index2:select{}, {{1, 2, 3, 4, 5}})
    t.assert_equals(index3:select{}, {{1, 2, 3, 4, 5}})

    -- Optimize index2 with negative update op.
    t.assert_equals(space:replace{10, 20, 30, 40, 50}, {10, 20, 30, 40, 50})
    t.assert_equals(box.snapshot(), 'ok')
    dump_count = wait_for_dump(index, dump_count)
    old_stmt_count = dumped_stmt_count({index, index2, index3})
    t.assert_equals(index:update({20}, {{'=', -1, 500}}), {10, 20, 30, 40, 500})
    t.assert_equals(box.snapshot(), 'ok')
    dump_count = wait_for_dump(index, dump_count)
    new_stmt_count = dumped_stmt_count({index, index2, index3})
    -- 3 = REPLACE in index1 and DELETE + REPLACE in index3.
    t.assert_equals(new_stmt_count - old_stmt_count, 3)
    old_stmt_count = new_stmt_count
    t.assert_equals(
        index:select{}, {{1, 2, 3, 4, 5},
                         {10, 20, 30, 40, 500}})
    t.assert_equals(
        index2:select{}, {{1, 2, 3, 4, 5},
                          {10, 20, 30, 40, 500}})
    t.assert_equals(
        index3:select{}, {{1, 2, 3, 4, 5},
                          {10, 20, 30, 40, 500}})
end

g.before_test('test_during_dump_optimizes_update_not_skip_entire_key',
function()
    index = space:create_index('primary',
        { parts = {2, 'unsigned'}, run_count_per_level = 20 } )
    index2 = space:create_index('secondary',
        { parts = {4, 'unsigned', 3, 'unsigned'}, run_count_per_level = 20 })
    index3 = space:create_index('third',
        { parts = {5, 'unsigned'}, run_count_per_level = 20 })

    space:insert({1, 2, 3, 4, 5})
    local long_tuple = {}
    for i = 1, 70 do long_tuple[i] = i end
    local _ = space:replace(long_tuple)
    index:update({2}, {{'=', 65, 1000}})
    index:update({2}, {{'#', -65, 65}})
    space:replace{10, 20, 30, 40, 50}
    index:update({20}, {{'=', -1, 500}})
end)

g.test_during_dump_optimizes_update_not_skip_entire_key = function()
    -- Check if optimizes update do not skip the entire key during dump.
    t.assert_equals(space:replace{10, 100, 1000, 10000, 100000, 1000000},
        {10, 100, 1000, 10000, 100000, 1000000})
    t.assert_equals(
        index:update({100}, {{'=', 6, 1}}), {10, 100, 1000, 10000, 100000, 1})

    box.begin()
    t.assert_equals(space:replace{20, 200, 2000, 20000, 200000, 2000000},
        {20, 200, 2000, 20000, 200000, 2000000})
    t.assert_equals(
        index:update({200}, {{'=', 6, 2}}), {20, 200, 2000, 20000, 200000, 2})
    box.commit()
    t.assert_equals(box.snapshot(), 'ok')
    local dump_count = wait_for_dump(index, dump_count)
    local old_stmt_count = dumped_stmt_count({index, index2, index3})
    t.assert_equals(
        index:select{}, {{1, 2, 3, 4, 5},
                         {10, 20, 30, 40, 500},
                         {10, 100, 1000, 10000, 100000, 1},
                         {20, 200, 2000, 20000, 200000, 2}})
    t.assert_equals(
        index2:select{}, {{1, 2, 3, 4, 5},
                          {10, 20, 30, 40, 500},
                          {10, 100, 1000, 10000, 100000, 1},
                          {20, 200, 2000, 20000, 200000, 2}})
    t.assert_equals(
        index3:select{}, {{1, 2, 3, 4, 5},
                          {10, 20, 30, 40, 500},
                          {10, 100, 1000, 10000, 100000, 1},
                          {20, 200, 2000, 20000, 200000, 2}})
end

g.before_test('test_key_uniqueness', function()
    index = space:create_index('primary',
        { parts = {2, 'unsigned'}, run_count_per_level = 20 } )
    index2 = space:create_index('secondary',
        { parts = {4, 'unsigned', 3, 'unsigned'}, run_count_per_level = 20 })
    index3 = space:create_index('third',
        { parts = {5, 'unsigned'}, run_count_per_level = 20 })
    t.assert_equals(space:replace{1, 1, 1, 1, 1}, {1, 1, 1, 1, 1})
end)

g.test_key_uniqueness = function()
    -- gh-2980: key uniqueness is not checked if indexed fields
    -- are not updated.
    local LOOKUPS_BASE = {0, 0, 0}
    local function lookups()
        local ret = {}
        for i = 1, #LOOKUPS_BASE do
            local info = space.index[i - 1]:stat()
            table.insert(ret, info.lookup - LOOKUPS_BASE[i])
        end
        return ret
    end
    LOOKUPS_BASE = lookups()
    -- update of a field that is not indexed
    t.assert_equals(space:update(1, {{'+', 1, 1}}), {2, 1, 1, 1, 1})
    t.assert_equals(lookups(), {1, 0, 0})
    -- update of a field indexed by space.index[1]
    t.assert_equals(space:update(1, {{'+', 3, 1}}), {2, 1, 2, 1, 1})
    t.assert_equals(lookups(), {2, 1, 0})
    -- update of a field indexed by space.index[2]
    t.assert_equals(space:update(1, {{'+', 5, 1}}), {2, 1, 2, 1, 2})
    t.assert_equals(lookups(), {3, 1, 1})
end

g.test_phantom_tuples_not_affect_on_indices = function()
    -- gh-3607: phantom tuples in secondary index if UPDATE does not
    -- change key fields.
    local _ = space:create_index('pk')
    _ = space:create_index('sk', {parts = {2, 'unsigned'}, run_count_per_level = 10})
    t.assert_equals(space:insert{1, 10}, {1, 10})
    -- Some padding to prevent last-level compaction (gh-3657).
    for i = 1001, 1010 do space:replace{i, i} end
    t.assert_equals(box.snapshot(), 'ok')
    t.assert_equals(space:update(1, {{'=', 2, 10}}), {1, 10})
    space:delete(1)
    t.assert_equals(box.snapshot(), 'ok')
    -- Should be 12: INSERT{10, 1} and INSERT[1001..1010] in the first run
    -- plus DELETE{10, 1} in the second run.
    t.assert_equals(space.index.sk:stat().rows, 12)
    t.assert_equals(space:insert{1, 20}, {1, 20})
    t.assert_equals(
        space.index.sk:select(), {{1, 20},
                              {1001, 1001},
                              {1002, 1002},
                              {1003, 1003},
                              {1004, 1004},
                              {1005, 1005},
                              {1006, 1006},
                              {1007, 1007},
                              {1008, 1008},
                              {1009, 1009},
                              {1010, 1010}})
end

