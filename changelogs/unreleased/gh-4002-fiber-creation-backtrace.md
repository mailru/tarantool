## feature/fiber

 * Added new subtable `parent_backtrace` to the `fiber.info()`
   containing C and Lua backtrace chunks of fiber creation.
 * Added `fiber.parent_bt_enable()` and `fiber.parent_bt_disable()`
   options in order to switch on/off the ability to collect
   parent backtraces for newly created fibers and to
   show/hide `parent_backtrace` subtables in the `fiber.info()`.
