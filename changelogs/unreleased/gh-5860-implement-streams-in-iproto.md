## feature/core

* Implement streams in iproto. Each stream is associated with its id.
  Id is generated on the client side, but is hidden from the actual user.
  Instead, user operates on a stream object and internally it is mapped to
  the corresponding id. Requests with omited or zero stream_id means old
  behavior.
  All requests in a stream are processed synchronously. Each stream can start
  its own transaction, so they allows multiplexing several transactions over
  one connection.
