## feature/core
* Implement ability to pass several listening uries in different ways
  with different properties. Currently the only valid option is `transport`
  with `plain` value, with behaviour same as without this option. In the
  future, new options will appear that will determine the behavior of iproto
  threads. Fox example:
  ```lua
  box.cfg { listen = '10.10.0.1:3301' }
  box.cfg { listen = {'10.10.0.1:3301'} }
  box.cfg { listen = {'10.10.0.1:3301', '10.10.0.2:3302'} }
  box.cfg { {{uri='10.10.0.1:3301', transport='plain'}} }
  box.cfg { {'10.10.0.1:3301', {uri='10.10.0.2:3302', transport='plain'}} }
  box.cfg { {{uri='10.10.0.1:3301', transport='plain'},
            {uri='10.10.0.1:3313', transport='plain'}} }
  box.cfg { {uri='10.10.0.1:3301', transport={'plain', 'plain'}} }
  box.cfg { {uri='10.10.0.1:3301', transport='plain, plain'} }
  box.cfg { '10.10.0.1:3301, 10.10.0.1:3313' }
  box.cfg { '10.10.0.1:3301?transport=plain, 10.10.0.1:3313?transport=plain' }
  box.cfg { '10.10.0.1:3301?transport=plain&transport=plain' }
  ```