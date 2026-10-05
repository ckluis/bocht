// Net.peer_ip — peer IP address of a connected socket.
//
// Base 2.0.18's TCP.accept calls accept(fd, NULL, NULL): the peer address
// is discarded and no Base effect recovers it, which makes per-IP rate
// limiting impossible with stock effects. The accepted fd is still
// connected, so getpeername() recovers the peer IP for the rate limiter.
// Returns "" when the peer cannot be determined (fail-closed: such
// connections share the "ip:" bucket).

Term net_peer_ip_run(Env e, Term* f, IoWork* w) {
  int fd = (int)io_hand_v(f[0]);
  struct sockaddr_storage ss;
  socklen_t sl = sizeof(ss);
  char buf[64];
  buf[0] = '\0';
  if (getpeername(fd, (struct sockaddr*)&ss, &sl) == 0) {
    if (ss.ss_family == AF_INET) {
      struct sockaddr_in* s4 = (struct sockaddr_in*)&ss;
      inet_ntop(AF_INET, &s4->sin_addr, buf, sizeof(buf));
    } else if (ss.ss_family == AF_INET6) {
      struct sockaddr_in6* s6 = (struct sockaddr_in6*)&ss;
      inet_ntop(AF_INET6, &s6->sin6_addr, buf, sizeof(buf));
    }
  }
  Term r = io_str(e, buf, strlen(buf));
  return io_tup(e, io_hand(fd), r);
}

static void __attribute__((constructor)) net_peer_ip_use(void) {
  io_eff(CID_NET_PEER_IP, net_peer_ip_run, 0);
}
