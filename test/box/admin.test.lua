--# stop server default
--# start server default

space = box.schema.create_space('tweedledum', { id = 0 })
space:create_index('primary', 'hash', { parts = { 0, 'num' }})

box.stat()
help()
box.cfg()
box.stat()
box.insert(0, 1, 'tuple')
box.snapshot()
box.delete(0, 1)

--# setopt delimiter ';'
function check_type(arg, typeof)
    return type(arg) == typeof
end;

function test_box_info()
    local tmp = box.info()
    local num = {'pid', 'snapshot_pid', 'recovery_last_update', 'recovery_lag', 'uptime', 'logger_pid'}
    local buildstr = {'flags', 'target', 'compiler', 'options'}
    local str = {'version', 'status', 'config'}
    local failed = {}
    if check_type(tmp.lsn, 'cdata') == false then
        table.insert(failed1, 'box.info().lsn')
    else
        tmp.lsn = nil
    end
    for k, v in ipairs(num) do
        if check_type(tmp[v], 'number') == false then
            table.insert(failed, 'box.info().'..v)
        else
            tmp[v] = nil
        end
    end
    for k, v in ipairs(str) do
        if check_type(tmp[v], 'string') == false then
            table.insert(failed, 'box.info().'..v)
        else
            tmp[v] = nil
        end
    end
    if type(tmp.build) == 'table' then
        for k, v in ipairs(buildstr) do
            if check_type(tmp.build[v], 'string') == false then
                table.insert(failed, 'box.info().build.'..v)
            else
                tmp.build[v] = nil
            end
        end
        if #tmp.build == 0 then
            tmp.build = nil
        end
    else
        table.insert(failed, 'box.info().build failed')
    end
    if #tmp > 0 or #failed > 0 then
        return 'box.info() is not ok.', 'failed: ', failed, tmp
    else
        return 'box.info() is ok.'
    end
end;

function test_slab(tbl)
    local num = {'items', 'bytes_used', 'item_size', 'slabs', 'bytes_free'}
    local failed = {}
    for k, v in ipairs(num) do
        if check_type(tmp[v], 'number') == false then
            table.insert(failed, 'box.slab.info().<slab_size>.'..v)
        else
            tmp[v] = nil
        end
    end
    if #tbl > 0 or #failed > 0 then
        return false, failed
    else
        return true, {}
    end
end;

function test_box_slab_info()
    local tmp = box.slab.info()
    local cdata = {'arena_size', 'arena_used'}
    local failed = {}
    if type(tmp.slabs) == 'table' then
        for name, tbl in ipairs(tmp.slabs) do
            local bl, fld = test_slab(tbl)
            if bl == true then
                tmp[name] = nil
            else
                for k, v in ipairs(fld) do
                    table.append(failed, v)
                end
            end
        end
    else
        table.append(failed, 'box.slab.info().slabs is not ok')
    end
    if #tmp.slabs == 0 then
        tmp.slabs = nil
    end
    for k, v in ipairs(cdata) do
        if check_type(tmp[v], 'cdata') == false then
            table.insert(failed, 'box.slab.info().'..v)
        else
            tmp[v] = nil
        end
    end
    if #tmp > 0 or #failed > 0 then
        return "box.slab.info() is not ok", tmp, failed
    else
        return "box.slab.info() is ok"
    end
end;

function test_fiber(tbl)
    local num = {'fid', 'csw'}
    for k, v in ipairs(num) do
        if check_type(tmp[v], 'number') == false then
            table.insert(failed, 'box.fiber.info().<fiber_name>.'..v)
        else
            tmp[v] = nil
        end
    end
    if type(tbl.backtrace) == 'table' and #tbl.backtrace > 0 then
        tbl.backtrace = nil
    else
        table.append(failed, 'backtrace')
    end
    if #tbl > 0 or #failed > 0 then
        return false, failed
    else
        return true, {}
    end
end;

function test_box_fiber_info()
    local tmp = box.fiber.info()
    local failed = {}
    for name, tbl in ipairs(tmp) do
        local bl, fld = test_fiber(tbl)
        if bl == true then
            tmp[name] = nil
        else
            for k, v in ipairs(fld) do
                table.append(failed, v)
            end
        end
    end
    if #tmp > 0 or #failed > 0 then
        return "box.fiber.info is not ok. failed: ", tmp, failed
    else
        return "box.fiber.info() is ok"
    end
end;

test_box_info();
test_box_slab_info();
test_box_fiber_info();
box.space[0]:drop();
