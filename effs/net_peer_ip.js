// Net.peer_ip — JS backend stub.
//
// The JS effect runtime used here exposes no getpeername binding, so the
// peer address is unavailable on this backend (returns ""). The native
// backend returns the real peer IP. The campaign builds and tests the
// native binary exclusively.

function net_peer_ip(socket) {
  return io_tup(socket, "");
}
