// Net.send_timeout — JS backend stub.
//
// Best-effort mirror of tcp_send.js WITHOUT the deadline: the JS effect
// runtime used here exposes no deadline-capable park (io_park_on has no
// timeout parameter), so the write deadline is a native-only guarantee.
// The campaign builds and tests the native binary exclusively.

function net_send_timeout(socket, data, ms, k) {
  return tcp_send(socket, data, k);
}
