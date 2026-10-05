# med_types.bend — fresh Medium service, part 3: types + field accessors.
# Auth bakes in the kid lesson from the start: `key` is the INTERNAL lookup
# identity (env key name, or verifier "v1$<64 hex>" for managed keys) used
# for authentication, rate limits and logs; `kid` is the STABLE PUBLIC
# identity (env name, or "k_<n>") used for authorship, ownership and claps.
# The raw secret never appears in the DB, WAL, snapshots, or logs.

type Auth is Data:
  MkAuth{kid: String, key: String, tenant: String, role: String, expires: Nat, revoked: Bool}

def auth_kid(+a: Auth) -> String:
  match a:
    case MkAuth{kid, key, tenant, role, expires, revoked}: kid

def auth_key(+a: Auth) -> String:
  match a:
    case MkAuth{kid, key, tenant, role, expires, revoked}: key

def auth_tenant(+a: Auth) -> String:
  match a:
    case MkAuth{kid, key, tenant, role, expires, revoked}: tenant

def auth_role(+a: Auth) -> String:
  match a:
    case MkAuth{kid, key, tenant, role, expires, revoked}: role

def auth_expires(+a: Auth) -> Nat:
  match a:
    case MkAuth{kid, key, tenant, role, expires, revoked}: expires

def auth_revoked(+a: Auth) -> Bool:
  match a:
    case MkAuth{kid, key, tenant, role, expires, revoked}: revoked

# Commit event for the shared-state log (newest first in state, cap 1000).
type Evt is Data:
  MkEvt{seq: Nat, tenant: String, etype: String, payload: String}

def evt_seq(+e: Evt) -> Nat:
  match e:
    case MkEvt{seq, tenant, etype, payload}: seq

def evt_tenant(+e: Evt) -> String:
  match e:
    case MkEvt{seq, tenant, etype, payload}: tenant

def evt_type(+e: Evt) -> String:
  match e:
    case MkEvt{seq, tenant, etype, payload}: etype

def evt_payload(+e: Evt) -> String:
  match e:
    case MkEvt{seq, tenant, etype, payload}: payload

# Parked long-poll subscriber. The Socket travels in a 1-shot Chan(Socket):
# Chan is Data so it can live in MedState; Socket is a law type and cannot
# be a Data constructor field.
type PendSub is Data:
  MkPend{sch: Chan(Socket), tenant: String, cursor: Nat, born: Nat}

def pend_tenant(+p: PendSub) -> String:
  match p:
    case MkPend{sch, tenant, cursor, born}: tenant

def pend_cursor(+p: PendSub) -> Nat:
  match p:
    case MkPend{sch, tenant, cursor, born}: cursor

def pend_born(+p: PendSub) -> Nat:
  match p:
    case MkPend{sch, tenant, cursor, born}: born

def pend_sch(+p: PendSub) -> Chan(Socket):
  match p:
    case MkPend{sch, tenant, cursor, born}: sch

# Assembled request handed to the serialized owner task.
type ReqBody is Data:
  MkReqBody{method: String, path: String, headers: Map<&2, String>, body: String, sockch: Chan(Socket)}

# Owner mailbox: requests from connection handlers, ticks from the ticker.
type OwnMsg is Data:
  ReqM{rb: ReqBody}
  TickM{}

# Whole server state, owned by the single serialized owner task.
# db: tenant-scoped records. keys: lookup-id -> Auth. seq: id counter.
# evlog: newest-first commit events. evseq: monotonic event seq.
# pend: parked long-poll subscribers. rl: lookup-id -> "window_start,count".
# rlprune: ms timestamp of the last rl-map prune (0 = never).
type MedState is Data:
  MkMed{db: Map<&2, String>, keys: Map<&2, Auth>, seq: Nat, evlog: List<&2, Evt>, evseq: Nat, pend: List<&2, PendSub>, rl: Map<&2, String>, snapseq: Nat, rlprune: Nat, rlcur: Nat, restart: Bool, rrl: Nat, krl: Nat}

def st_db(+st: MedState) -> Map<&2, String>:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: db

def st_keys(+st: MedState) -> Map<&2, Auth>:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: keys

def st_seq(+st: MedState) -> Nat:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: seq

def st_evlog(+st: MedState) -> List<&2, Evt>:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: evlog

def st_evseq(+st: MedState) -> Nat:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: evseq

def st_pend(+st: MedState) -> List<&2, PendSub>:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: pend

def st_rl(+st: MedState) -> Map<&2, String>:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: rl

def st_snapseq(+st: MedState) -> Nat:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: snapseq

def st_with_snapseq(+st: MedState, +snapseq: Nat) -> MedState:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq0, rlprune, rlcur, restart, rrl, krl}: MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}

def st_with_db(+st: MedState, +db: Map<&2, String>) -> MedState:
  match st:
    case MkMed{db0, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}

def st_with_keys(+st: MedState, +keys: Map<&2, Auth>) -> MedState:
  match st:
    case MkMed{db, keys0, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}

def st_with_seq(+st: MedState, +seq: Nat) -> MedState:
  match st:
    case MkMed{db, keys, seq0, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}

def st_with_ev(+st: MedState, +evlog: List<&2, Evt>, +evseq: Nat) -> MedState:
  match st:
    case MkMed{db, keys, seq, evlog0, evseq0, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}

def st_with_pend(+st: MedState, +pend: List<&2, PendSub>) -> MedState:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend0, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}

def st_with_rl(+st: MedState, +rl: Map<&2, String>) -> MedState:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl0, snapseq, rlprune, rlcur, restart, rrl, krl}: MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}

def st_rlprune(+st: MedState) -> Nat:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: rlprune

def st_with_rlprune(+st: MedState, +rlprune: Nat) -> MedState:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune0, rlcur, restart, rrl, krl}: MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}

def st_rlcur(+st: MedState) -> Nat:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: rlcur

def st_with_rlcur(+st: MedState, +rlcur: Nat) -> MedState:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur0, restart, rrl, krl}: MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}

# restart: graceful-restart request flag (Round 3 item 19). In-memory only:
# snap_content serializes db/keys/evlog/seq, so this never persists across
# boots and a shutdown snapshot cannot cause a restart loop.
def st_restart(+st: MedState) -> Bool:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: restart

def st_with_restart(+st: MedState, +restart: Bool) -> MedState:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart0, rrl, krl}: MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}

# rrl: per-credential restart rate limit (Round 3 item 20). In-memory config:
# how many POST /v1/admin/restart requests one bearer token may make per
# 60s window. Set once at boot from MEDIUM_RESTART_RL (default 5); never
# changed at runtime and never persisted in snapshots (snap_content only
# serializes db/keys/evlog/seq).
def st_rrl(+st: MedState) -> Nat:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: rrl

def st_with_rrl(+st: MedState, +rrl: Nat) -> MedState:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl0, krl}: MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}

# krl: per-credential key-management rate limit (Round 3 item 21). In-memory
# config: how many mutating key-plane requests (POST /v1/keys create,
# POST /v1/keys/:kid/rotate, POST /v1/keys/:kid/revoke) one Bearer <redacted>
# may make per 60s window. Set once at boot from MEDIUM_KEY_RL (default 5);
# never changed at runtime and never persisted in snapshots (snap_content
# only serializes db/keys/evlog/seq).
def st_krl(+st: MedState) -> Nat:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: krl

def st_with_krl(+st: MedState, +krl: Nat) -> MedState:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl0}: MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}

def default_key_rl() -> Nat:
  5n

def default_restart_rl() -> Nat:
  5n

# HTTP head assembly state (forked connection handler).
type HeadSt is Data:
  MkHs{done: Bool, ok: Bool, code: U32, head: String, rest: String, acc: String}

type HGot is Data:
  MkHg{head: String, rest: String, ok: Bool, code: U32}

# HTTP body assembly state.
type BodySt is Data:
  MkBs{done: Bool, rem: Nat, acc: String}

# Content-Length spec.
type BodySpec is Data:
  CLMissing{}
  CLBad{}
  CLOk{n: Nat}

# Parsed request line.
type HeadRes is Data:
  MkHr{method: String, path: String, ver: String}
