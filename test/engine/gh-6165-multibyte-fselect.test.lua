-- https://github.com/tarantool/tarantool/issues/6165
-- formatted select with multibyte characters
s = box.schema.space.create('test', {format = {{'name', 'string'}, {'surname', 'string'}}})
_ = s:create_index('pk')
_ = s:insert({'Ян', 'Ким'})
s:fselect()
s:drop()

s = box.schema.space.create('test', {format = {{'Первый столбец', 'string'}, {'Второй столбец', 'string'}}})
_ = s:create_index('pk')
_ = s:insert({'abcdef', 'cde'})
s:fselect()
s:drop()

s = box.schema.space.create('test', {format = {{'Первый столбец', 'string'}, {'Второй столбец', 'string'}}})
_ = s:create_index('pk')
_ = s:insert({'абв', 'гдежз'})
s:fselect()
s:drop()