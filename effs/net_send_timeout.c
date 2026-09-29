// Net.send_timeout — TCP.send with a bounded write deadline.
//
// Base 2.0.18's TCP.send parks the task until the socket is writable, with
// NO deadline: a peer that advertises a zero window forever parks the
// writer forever. This effect mirrors tcp_send.c but parks on POLLOUT only
// until the deadline (ms); past it, the effect fails with ETIMEDOUT so the
// caller can close the socket and reclaim the task.
//
// Deadline handling mirrors tcp_poll.c: io_wait_on takes an absolute tick
// deadline, and the resume function re-checks io_tick() against
// w->time after every wake. (Bend 2.0.29 removed the io_wait_time()
// helper; the deadline now lives directly on IoWork as w->time.)

static Term net_send_timeout_more(Env e, IoWork* w) {
  int fd = (int)w->hand;
  u64 at = w->time;
  while (w->code == 0 && (u64)w->made < w->size) {
    ssize_t n = send(fd, w->data + w->made, w->size - (u64)w->made, 0);
    if (n < 0 && errno == EAGAIN) {
      if (io_tick() < at) {
        return io_wait_on(w, fd, POLLOUT, at, net_send_timeout_more);
      }
      w->code = ETIMEDOUT;
      break;
    }
    w->made += io_sys_end(w, n);
  }
  Term r = w->code != 0 ? io_fail(e, w->code, NULL)
    : io_done(e, term_pak(CID_UNIT, 0));
  free(w->data);
  return io_tup(e, io_hand(w->hand), r);
}

Term net_send_timeout_run(Env e, Term* f, IoWork* w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->data = io_cstr(e, f[1], &w->size);
  w->made = 0;
  w->code = 0;
  u64 at = io_tick() + (u64)(u32)f[2] * 1000000ull;
  while (w->code == 0 && (u64)w->made < w->size) {
    ssize_t n = send((int)w->hand, w->data + w->made, w->size - (u64)w->made, 0);
    if (n < 0 && errno == EAGAIN) {
      return io_wait_on(w, (int)w->hand, POLLOUT, at, net_send_timeout_more);
    }
    w->made += io_sys_end(w, n);
  }
  Term r = w->code != 0 ? io_fail(e, w->code, NULL)
    : io_done(e, term_pak(CID_UNIT, 0));
  free(w->data);
  return io_tup(e, io_hand(w->hand), r);
}

static void __attribute__((constructor)) net_send_timeout_use(void) {
  io_eff(CID_NET_SEND_TIMEOUT, net_send_timeout_run, 0);
}
