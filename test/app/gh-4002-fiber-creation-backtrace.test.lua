yaml = require('yaml')
fiber = require('fiber')
test_run = require('test_run').new()

local stack_len = 0
local parent_stack_len = 0

test_run:cmd('setopt delimiter ";"')
foo = function()
    local id = fiber.self():id()
    local info = fiber.info()[id]
    local stack = info.backtrace
    stack_len = stack and #stack or -1
    local parent_stack = info.backtrace_parent
    parent_stack_len = parent_stack and #parent_stack or -1
end;

test_run:cmd('setopt delimiter ""');

local bar,baz

bar = function(n) if n ~= 0 then baz(n-1) else fiber.create(foo) end end
baz = function(n) bar(n) end

baz(10)
assert(parent_stack_len == -1)

if stack_len ~= -1 then fiber:parent_bt_enable() end
baz(10)
assert(parent_stack_len > 0 or stack_len == -1)

if stack_len ~= -1 then fiber:parent_bt_disable() end
baz(10)
assert(parent_stack_len == -1)
