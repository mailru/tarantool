c = box.net.sql.connect('abcd')
function dump(v) return box.cjson.encode(v) end

connect = {}
for tk in string.gmatch(os.getenv('MYSQL'), '[^:]+') do table.insert(connect, tk) end

-- mysql
c = box.net.sql.connect('mysql', unpack(connect))
for k, v in pairs(c) do print(k, ': ', type(v)) end

c:execute('SEL ECT 1')
dump({c:execute('SELECT ? AS bool1, ? AS bool2, ? AS nil, ? AS num, ? AS str', true, false, nil, 123, 'abc')})

dump({c:execute('SELECT * FROM (SELECT ?) t WHERE 1 = 0', 2)})
dump({c:execute('CREATE PROCEDURE p1() BEGIN SELECT 1 AS One; SELECT 2 AS Two, 3 AS Three; END')})
dump({c:execute('CALL p1')})
dump({c:execute('DROP PROCEDURE p1')})
dump({c:execute('SELECT 1 AS one UNION ALL SELECT 2')})
dump({c:execute('SELECT 1 AS one UNION ALL SELECT 2; SELECT ? AS two', 'abc')})

c:quote('test \"abc\" test')

c:begin_work()
c:rollback()
c:begin_work()
c:commit()
