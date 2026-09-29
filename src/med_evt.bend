# med_evt.bend — fresh Medium service, part 7: typed commit events + subscribers.
# Every mutation emits MkEvt{seq, tenant, etype, payload}. The evlog is a
# bounded ring (1000 entries); the bounded-log helpers (evt_cap/evt_push/...)
# live in med_store.bend because WAL replay rebuilds the log on startup.
# Authenticated clients poll GET /v1/events?cursor=N for tenant-filtered
# replay; when no new events exist the socket parks as a MkPend until the
# next event or timeout.

def evt_head_opt(+log: List<&2, Evt>) -> Maybe<&1, Evt>:
  match log:
    case Nil{}: None{}
    case h <> _: Some{h}

def evt_emit_go(+st: MedState, +e: Evt) -> MedState:
  st_with_ev(st, evt_push(st_evlog(st), e), Nat.add(st_evseq(st), 1n))

def evt_emit(+st: MedState, +tenant: String, +etype: String, +payload: String) -> MedState:
  evt_emit_go(st, MkEvt{Nat.add(st_evseq(st), 1n), tenant, etype, payload})

def evt_to_json(+e: Evt) -> String:
  match e:
    case MkEvt{s, t, k, p}:
      "{\"seq\":" ++ Nat.show(s) ++ ",\"tenant\":\"" ++ json_esc(t) ++ "\",\"type\":\"" ++ json_esc(k) ++ "\",\"payload\":" ++ p ++ "}"

def evt_filter_cons(keep: Bool, +h: Evt, +acc: List<&2, String>) -> List<&2, String>:
  match keep:
    case True{}: evt_to_json(h) <> acc
    case False{}: acc

def evt_filter_go(+log: List<&2, Evt>, +tenant: String, +cursor: Nat, +acc: List<&2, String>) -> List<&2, String>:
  match log:
    case Nil{}: acc
    case h <> t:
      evt_filter_go(t, tenant, cursor, evt_filter_cons(Bool.and(Nat.is_lt(cursor, evt_seq(h)), String.eq(evt_tenant(h), tenant)), h, acc))

def evt_filter(+log: List<&2, Evt>, +tenant: String, +cursor: Nat) -> List<&2, String>:
  evt_filter_go(log, tenant, cursor, Nil{})

def evt_max_seq(+log: List<&2, Evt>, +cur: Nat) -> Nat:
  match log:
    case Nil{}: cur
    case h <> t: evt_max_seq(t, Nat.max(cur, evt_seq(h)))

# --- slow-poller truncation signal (Round 3 item 140) ---
# The evlog is a bounded 1000-entry ring; a client whose cursor predates the
# oldest buffered event has irrecoverably missed events. The poll response
# used to skip them silently and jump the cursor forward, making the loss
# undetectable. Poll responses (immediate and wakeup) now carry
# "truncated":true whenever the caller's cursor is older than the oldest
# buffered event, so slow pollers can re-sync (e.g. refetch state) instead
# of silently missing events. The flag is additive and only appears when
# the cursor is strictly older than the ring floor, so fresh cursors are
# unaffected.

def evt_oldest_seq_go(+log: List<&2, Evt>, +acc: Nat) -> Nat:
  match log:
    case Nil{}: acc
    case h <> t: evt_oldest_seq_go(t, evt_seq(h))

def evt_oldest_seq(+log: List<&2, Evt>) -> Nat:
  evt_oldest_seq_go(log, 0n)

def evt_trunc_flag(+log: List<&2, Evt>, +cursor: Nat) -> String:
  Bool.pick(String, Nat.is_lt(cursor, evt_oldest_seq(log)), ",\"truncated\":true", "")

# --- subscribers ---

def pend_add(+st: MedState, +sub: PendSub) -> MedState:
  st_with_pend(st, sub <> st_pend(st))

def pend_expire_cons(expired: Bool, +h: PendSub, +acc: List<&2, PendSub>) -> List<&2, PendSub>:
  match expired:
    case True{}: acc
    case False{}: h <> acc

def pend_expire_collect(+subs: List<&2, PendSub>, +now: Nat, +keep: List<&2, PendSub>, +expired: List<&2, PendSub>) -> List<&2, PendSub> & List<&2, PendSub>:
  match subs:
    case Nil{}: (keep, expired)
    case h <> t:
      pend_expire_collect(t, now,
        Bool.pick(List<&2, PendSub>, Nat.is_lt(Nat.add(pend_born(h), Nat.mul(250n, 100n)), now), keep, h <> keep),
        Bool.pick(List<&2, PendSub>, Nat.is_lt(Nat.add(pend_born(h), Nat.mul(250n, 100n)), now), h <> expired, expired))

def pend_len(+subs: List<&2, PendSub>) -> Nat:
  match subs:
    case Nil{}: 0n
    case _ <> t: Nat.add(1n, pend_len(t))

def pend_cap() -> Nat:
  100n

# Round 3 item 177: per-tenant parked-subscription cap. Any single tenant may
# hold at most 25 parked subs; the global 100-slot ceiling (pend_cap) remains
# as a backstop. This contains a FIN-park wedge (item 173) to the offending
# tenant: one tenant's burn can no longer wedge every other tenant's event
# feed until the 25s lazy sweep.
def pend_cap_tenant() -> Nat:
  25n

def pend_expire_keep_go(ke: List<&2, PendSub> & List<&2, PendSub>) -> List<&2, PendSub>:
  match ke:
    case (keep, _expired): keep

def pend_expire_keep(+st: MedState, +now: Nat) -> List<&2, PendSub>:
  pend_expire_keep_go(pend_expire_collect(st_pend(st), now, Nil{}, Nil{}))

def pend_expire(+st: MedState, +now: Nat) -> MedState:
  st_with_pend(st, pend_expire_keep(st, now))

def pend_for_tenant_cons(mine: Bool, +h: PendSub, +acc: List<&2, PendSub>) -> List<&2, PendSub>:
  match mine:
    case True{}: h <> acc
    case False{}: acc

def pend_for_tenant_go(+subs: List<&2, PendSub>, +tenant: String, +acc: List<&2, PendSub>) -> List<&2, PendSub>:
  match subs:
    case Nil{}: acc
    case h <> t:
      pend_for_tenant_go(t, tenant, pend_for_tenant_cons(String.eq(pend_tenant(h), tenant), h, acc))

def pend_for_tenant(+subs: List<&2, PendSub>, +tenant: String) -> List<&2, PendSub>:
  pend_for_tenant_go(subs, tenant, Nil{})

def pend_without_tenant_cons(mine: Bool, +h: PendSub, +acc: List<&2, PendSub>) -> List<&2, PendSub>:
  match mine:
    case True{}: acc
    case False{}: h <> acc

def pend_without_tenant_go(+subs: List<&2, PendSub>, +tenant: String, +acc: List<&2, PendSub>) -> List<&2, PendSub>:
  match subs:
    case Nil{}: acc
    case h <> t:
      pend_without_tenant_go(t, tenant, pend_without_tenant_cons(String.eq(pend_tenant(h), tenant), h, acc))

def pend_without_tenant(+subs: List<&2, PendSub>, +tenant: String) -> List<&2, PendSub>:
  pend_without_tenant_go(subs, tenant, Nil{})
