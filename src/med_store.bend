# med_store.bend — fresh Medium service, part 6: storage + WAL + snapshots.
# DB keys (all tenant-scoped):
#   u:<tenant>:<id>          -> name \t bio
#   a:<tenant>:<id>          -> author_kid \t title \t body \t pub \t created_ms
#   p:<tenant>:<id>          -> owner_kid \t name \t desc
#   pm:<tenant>:<pub>:<kid>  -> role (writer|editor)
#   c:<tenant>:<aid>:<kid>   -> count
# WAL lines (tab-separated, \n-terminated):
#   SET \t key \t value
#   DEL \t key
#   KEY \t kid \t verifier-or-name \t tenant \t role \t expires \t revoked
#   SEQ \t n

def db_get_v(mv: Map<&2, String> & String) -> String:
  (m2, v) = mv
  v

def db_get(+db: Map<&2, String>, +key: String) -> String:
  db_get_v(Map.get(String, "", db, key))

def db_has(+db: Map<&2, String>, +key: String) -> Bool:
  Bool.not(String.is_empty(db_get(db, key)))

# --- bounded commit-event log (newest-first, cap 1000) ---
# Lives in the storage layer because WAL replay rebuilds it on startup.
# evt_emit (med_evt.bend) appends; every EVT line in WAL/snapshot replays here.

def evt_cap() -> Nat:
  Nat.mul(10n, 100n)

def evt_len(+log: List<&2, Evt>) -> Nat:
  match log:
    case Nil{}: 0n
    case _ <> t: Nat.add(1n, evt_len(t))

def evt_drop_last(+log: List<&2, Evt>) -> List<&2, Evt>:
  match log:
    case Nil{}: Nil{}
    case _ <> Nil{}: Nil{}
    case h <> t: h <> evt_drop_last(t)

def evt_trim_over(is_over: Bool, +log: List<&2, Evt>) -> List<&2, Evt>:
  match is_over:
    case True{}: evt_drop_last(log)
    case False{}: log

def evt_trim(+log: List<&2, Evt>) -> List<&2, Evt>:
  evt_trim_over(Nat.is_lt(evt_cap(), evt_len(log)), log)

def evt_push(+log: List<&2, Evt>, +e: Evt) -> List<&2, Evt>:
  evt_trim(e <> log)

# --- WAL append ---
# fsync'd (Round 2 item 7): a commit is acknowledged only after its WAL
# record is on stable storage. wal_write_done fsyncs the file AFTER the
# write and BEFORE the close; the Bool the owner waits on is True only if
# write AND sync both succeeded. A sync failure surfaces as
# 500 "wal_write_failed", never a silent ack.

def wal_sync_done(sr: File & Result<&1, &1, U32 & String, Unit>) -> IO(Bool):
  (f3, sres) = sr
  match sres:
    case Fail{e}:
      do IO<Bool>:
        _c : Unit <- File.close(f3)
        IO.pure(Bool, False{})
    case Done{u}:
      do IO<Bool>:
        _c : Unit <- File.close(f3)
        IO.pure(Bool, True{})

def wal_write_done(wr: File & Result<&1, &1, U32 & String, Unit>) -> IO(Bool):
  (f2, res) = wr
  match res:
    case Fail{e}:
      do IO<Bool>:
        _c : Unit <- File.close(f2)
        IO.pure(Bool, False{})
    case Done{u}:
      do IO<Bool>:
        sr : File & Result<&1, &1, U32 & String, Unit> <- File.sync(f2)
        wal_sync_done(sr)

def wal_write_open(r: Result<&1, &1, U32 & String, File>, +entry: String) -> IO(Bool):
  match r:
    case Fail{e}: IO.pure(Bool, False{})
    case Done{f}:
      do IO<Bool>:
        wr : File & Result<&1, &1, U32 & String, Unit> <- File.write(f, entry)
        wal_write_done(wr)

# --- Segmented WAL (Round 3 item 14) ---
#
# The single bocht.wal is replaced by numbered segments:
#   wal/active/seg-000042.wal            - not yet covered by a snapshot
#   wal/archive/YYYY/MM/seg-000042.wal   - covered by a durable snapshot
#
# Rollover policy: SIZE-BASED. Before each append the current segment is
# statted; when it has reached MEDIUM_WAL_SEG_CAP bytes (default 64 MiB)
# the counter advances and the write starts seg-N+1. 64 MiB is the production
# rollover policy; the per-file replay read cap is 80 MiB, so no segment can
# outgrow a single replay read. Time-based rollover was rejected: it needs
# clock bookkeeping and still allows unbounded growth under burst load.
# (The snapshot-every-500 cadence usually archives the current segment
# before it fills; that is fine.)
#
# Crash-safety sequence:
#   1. Every commit appends to the current active segment and is fsync'd
#      before the ack - the same ack-after-durable guarantee as before.
#   2. On snapshot: tmp write + fsync + validate, main write + fsync +
#      validate - exactly as before.
#   3. ONLY after the snapshot validates, the archive step runs: the
#      destination is clash-checked first (the archive aborts, retrying
#      after the next snapshot, if a planned archive name already exists),
#      then the segment counter is bumped past every active segment number
#      (fsync'd; the archive aborts if the bump fails), then every active
#      segment is moved with atomic rename(2) into wal/archive/YYYY/MM/,
#      then both directories are fsync'd.
#   4. A crash before step 3 completes leaves segments in wal/active/;
#      they replay harmlessly (replay is idempotent; every record carries
#      its sequence number).
#   5. rename(2) is atomic: a segment is never half-moved and never
#      deleted by the move. A destination-clash guard aborts the archive
#      (rather than overwriting) if a planned archive name already exists.
#   6. The counter only ever increases, so a segment number is never
#      reused and an archived seg-N can never collide with a new seg-N.
#
# Boot: wal/ and wal/active/ are created (a mkdir failure is fatal: the
# service refuses to start rather than serve without a WAL); a legacy
# single bocht.wal (from pre-segmentation installs) is imported ONCE as
# wal/active/seg-000000.wal iff no segments exist yet; the counter is
# reconciled to the next free segment number - max(counter file, active
# max, archive max), bumped past the archive max when wal/active/ is empty
# (the max walk alone cannot tell "archive empty" from "archive holds
# seg-0", and reusing the newest archived number would clash on the next
# archive). A segment number is therefore never reused, and an archived
# seg-N can never collide with a new seg-N.
#
# Purge: wal/archive/ is scanned at boot (dry-run first, then for real);
# segments older than MEDIUM_WAL_PURGE_DAYS are deleted. The named
# constant WAL_PURGE_RETENTION_DAYS is 10000, i.e. effectively disabled
# (user decision 2026-09-21: build the infrastructure, purge nothing).
# A stat failure yields "now" as the mtime, so an unreadable segment is
# never purged (fail-closed).

def wal_dir() -> String:
  "wal"

def wal_active_dir() -> String:
  "wal/active"

def wal_archive_dir() -> String:
  "wal/archive"

def wal_segcounter_path() -> String:
  "wal/segcounter"

# Named retention constant: 10000 days. The purge scanner runs, but
# nothing is purged until an operator lowers this (or sets
# MEDIUM_WAL_PURGE_DAYS). User decision 2026-09-21.
def wal_purge_retention_days_default() -> Nat:
  10000n

# 64 MiB = 64 * 1024 * 1024, built arithmetically: Nat literals above ~1000
# expand at compile time and overflow the stack.
def wal_seg_cap_default() -> Nat:
  Nat.mul(64n, Nat.mul(Nat.mul(32n, 32n), Nat.mul(32n, 32n)))

def wal_zpad2(+n: Nat) -> String:
  String.drop(Nat.show(Nat.add(100n, n)), 1n)

def wal_zpad4(+n: Nat) -> String:
  String.drop(Nat.show(Nat.add(10000n, n)), 1n)

def wal_zpad6_go(small: Bool, +n: Nat) -> String:
  match small:
    case True{}: String.drop(Nat.show(Nat.add(1000000n, n)), 1n)
    case False{}: Nat.show(n)

def wal_zpad6(+n: Nat) -> String:
  wal_zpad6_go(Nat.is_lt(n, 1000000n), n)

def wal_seg_name(+n: Nat) -> String:
  "seg-" ++ wal_zpad6(n) ++ ".wal"

def wal_seg_path(+n: Nat) -> String:
  wal_active_dir() ++ "/" ++ wal_seg_name(n)

def u32_ok(+v: U32) -> Bool:
  Bool.not(U32.is_eq(v, (0 : U32)))

# --- segment counter (fsync'd via wal_write_open; reconciled at boot) ---

def wal_segcounter_num(mn: Maybe<&1, Nat>) -> Nat:
  match mn:
    case None{}: 0n
    case Some{n}: n

# The counter file is written as "N\n". parse_nat_opt rejects the trailing
# newline (it is not a digit), so the whole content must never be parsed
# directly: parse only the first line. (Bug found 2026-09-21: parsing the
# raw content made every boot read counter=0, reuse segment numbers after
# an archive, and clash/defer the next archive.)
def wal_segcounter_head(+parts: List<&2, String>) -> Maybe<&1, Nat>:
  match parts:
    case Nil{}: None{}
    case h <> t: parse_nat_opt(h)

def wal_segcounter_got(rr: File & Result<&1, &1, U32 & String, String>) -> IO(Nat):
  (f2, res) = rr
  match res:
    case Fail{e}:
      do IO<Nat>:
        _c : Unit <- File.close(f2)
        IO.pure(Nat, 0n)
    case Done{content}:
      do IO<Nat>:
        _c : Unit <- File.close(f2)
        IO.pure(Nat, wal_segcounter_num(wal_segcounter_head(split_char(content, ch_lf()))))

def wal_segcounter_read(r: Result<&1, &1, U32 & String, File>) -> IO(Nat):
  match r:
    case Fail{e}: IO.pure(Nat, 0n)
    case Done{f}:
      do IO<Nat>:
        rr : File & Result<&1, &1, U32 & String, String> <- File.read(f, 16777216)
        wal_segcounter_got(rr)

def wal_seg_current() -> IO(Nat):
  do IO<Nat>:
    r : Result<&1, &1, U32 & String, File> <- File.open(wal_segcounter_path(), "r")
    wal_segcounter_read(r)

def wal_seg_set_current(+n: Nat) -> IO(Bool):
  do IO<Bool>:
    r : Result<&1, &1, U32 & String, File> <- File.open(wal_segcounter_path(), "w")
    wal_write_open(r, Nat.show(n) ++ "\n")

# --- size-based rollover ---

def wal_seg_cap_pos(is_zero: Bool, +n: Nat) -> Nat:
  match is_zero:
    case True{}: wal_seg_cap_default()
    case False{}: n

def wal_seg_cap_nz(+n: Nat) -> Nat:
  wal_seg_cap_pos(Nat.is_eq(n, 0n), n)

def wal_seg_cap_num(mn: Maybe<&1, Nat>) -> Nat:
  match mn:
    case None{}: wal_seg_cap_default()
    case Some{n}: wal_seg_cap_nz(n)

def wal_seg_cap_env(mr: Result<&1, &1, U32 & String, String>) -> Nat:
  match mr:
    case Fail{e}: wal_seg_cap_default()
    case Done{+s}: wal_seg_cap_num(parse_nat_opt(s))

def wal_seg_cap() -> IO(Nat):
  do IO<Nat>:
    mr : Result<&1, &1, U32 & String, String> <- IO.get_env("MEDIUM_WAL_SEG_CAP")
    IO.pure(Nat, wal_seg_cap_env(mr))

def wal_append_seg(+n: Nat, +entry: String) -> IO(Bool):
  do IO<Bool>:
    r : Result<&1, &1, U32 & String, File> <- File.open(wal_seg_path(n), "a")
    wal_write_open(r, entry)

# A failed counter bump must fail the commit (500 wal_write_failed), not
# silently append to a segment number the counter does not own (that would
# risk reusing a number and clashing on archive).
def wal_write_roll_bump(ok: Bool, +entry: String, +cur: Nat) -> IO(Bool):
  match ok:
    case False{}: IO.pure(Bool, False{})
    case True{}: wal_append_seg(Nat.add(cur, 1n), entry)

def wal_write_roll(roll: Bool, +entry: String, +cur: Nat) -> IO(Bool):
  match roll:
    case False{}: wal_append_seg(cur, entry)
    case True{}:
      do IO<Bool>:
        ok : Bool <- wal_seg_set_current(Nat.add(cur, 1n))
        wal_write_roll_bump(ok, entry, cur)

def wal_write_sz(+entry: String, +cur: Nat, +cap: Nat, sz: U32) -> IO(Bool):
  wal_write_roll(Bool.not(Nat.is_lt(U32.to_nat(sz), cap)), entry, cur)

def wal_write_go(+cur: Nat, +entry: String, +cap: Nat) -> IO(Bool):
  do IO<Bool>:
    sz : U32 <- FS.file_size(wal_seg_path(cur))
    wal_write_sz(entry, cur, cap, sz)

def wal_write(+entry: String) -> IO(Bool):
  do IO<Bool>:
    cap : Nat <- wal_seg_cap()
    cur : Nat <- wal_seg_current()
    wal_write_go(cur, entry, cap)

# --- segment-number parsing ("seg-000042.wal" -> 42) ---

def wal_is_segname(+h: String) -> Bool:
  Bool.and(String.starts_with(h, "seg-"), String.ends_with(h, ".wal"))

def wal_segnum_head2(+h: String) -> Maybe<&1, Nat>:
  parse_nat_opt(String.drop(h, 4n))

def wal_segnum_head(+parts: List<&2, String>) -> Maybe<&1, Nat>:
  match parts:
    case Nil{}: None{}
    case h <> t: wal_segnum_head2(h)

def wal_segnum_checked(ok: Bool, +h: String) -> Maybe<&1, Nat>:
  match ok:
    case False{}: None{}
    case True{}: wal_segnum_head(split_char(h, ch_dot()))

def wal_segnum_name(+h: String) -> Maybe<&1, Nat>:
  wal_segnum_checked(wal_is_segname(h), h)

# --- small Nat list helpers (insertion sort; segments are few) ---

def nats_min_ab(+a: Nat, +b: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_lt(a, b), a, b)

def nats_min_go(+xs: List<&2, Nat>, +best: Nat) -> Nat:
  match xs:
    case Nil{}: best
    case h <> t: nats_min_go(t, nats_min_ab(h, best))

def nats_min(+xs: List<&2, Nat>) -> Nat:
  match xs:
    case Nil{}: 0n
    case h <> t: nats_min_go(t, h)

def nats_max_ab(+a: Nat, +b: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_lt(a, b), b, a)

def nats_max_go(+xs: List<&2, Nat>, +best: Nat) -> Nat:
  match xs:
    case Nil{}: best
    case h <> t: nats_max_go(t, nats_max_ab(h, best))

def nats_max(+xs: List<&2, Nat>) -> Nat:
  nats_max_go(xs, 0n)

# Ascending insertion sort on Nat lists. Segment counts at boot are small
# (each segment is up to 64 MiB), so O(n^2) is negligible. Sorting the
# enumerated directory listing replaces the old min..max range reads: a
# single hostile seg-999999.wal (or a bogus 9999/ archive year) can no
# longer turn replay into a million-file boot scan.
#
# Bend forbids mutual recursion, so the Bool dispatch cannot live in a
# helper that calls back into nats_insert. Instead the caller always
# computes the recursively-inserted tail (strict evaluation; the unused
# arm drops it) and a leaf helper defined first branches on the Bool.
def nats_insert_branch(lt: Bool, +x: Nat, +h: Nat, +t_sorted: List<&2, Nat>, +t: List<&2, Nat>) -> List<&2, Nat>:
  match lt:
    case True{}: h <> t_sorted
    case False{}: x <> h <> t

def nats_insert(+x: Nat, +xs: List<&2, Nat>) -> List<&2, Nat>:
  match xs:
    case Nil{}: x <> Nil{}
    case h <> t: nats_insert_branch(Nat.is_lt(h, x), x, h, nats_insert(x, t), t)

def nats_sort(+xs: List<&2, Nat>) -> List<&2, Nat>:
  match xs:
    case Nil{}: Nil{}
    case h <> t: nats_insert(h, nats_sort(t))

def wal_set(+k: String, +v: String) -> IO(Bool):
  wal_write("SET" ++ s_tab() ++ k ++ s_tab() ++ v ++ "\n")

def wal_del(+k: String) -> IO(Bool):
  wal_write("DEL" ++ s_tab() ++ k ++ "\n")

def wal_key(+a: Auth) -> IO(Bool):
  wal_write("KEY" ++ s_tab() ++ apikey_serialize(a) ++ "\n")

def wal_keyrot(+old_v: String, +new: Auth) -> IO(Bool):
  wal_write("KEYROT" ++ s_tab() ++ old_v ++ s_tab() ++ apikey_serialize(new) ++ "\n")

# Revoked-key tombstone reclamation (Round 3 item 15): snapshot-time compaction
# drops revoked keys from the live map and persists each drop as one KEYDEL
# line (fsync'd like every WAL write). Replay drops them too, so a crash
# between compaction and snapshot promotion cannot resurrect them. Revocation
# is permanent and auth rejects missing keys with 401 exactly like revoked
# ones, so dropping is behavior-preserving; the WAL archive keeps the full
# KEY/KEYDEL history for audit.
def wal_keydel(v: String) -> IO(Bool):
  wal_write("KEYDEL" ++ s_tab() ++ v ++ "\n")

# Combined single-line commit records (Round 2 item 7b): a mutation and its
# sequence number are written as ONE line with ONE fsync. A crash can only
# leave this line fully present (replayed atomically: both the mutation and
# the sequence advance together) or torn-and-unterminated (dropped by
# wal_replay's trailing-record trim). The old two-write form (wal_set then
# wal_seq) had a crash window where a durable SET replayed with a stale SEQ,
# causing the next create to reuse the same id and silently overwrite.
def wal_setseq(+k: String, +v: String, +n: Nat) -> IO(Bool):
  wal_write("SSET" ++ s_tab() ++ k ++ s_tab() ++ v ++ s_tab() ++ Nat.show(n) ++ "\n")

def wal_keyseq(+a: Auth, +n: Nat) -> IO(Bool):
  wal_write("SKEY" ++ s_tab() ++ apikey_serialize(a) ++ s_tab() ++ Nat.show(n) ++ "\n")

# --- single-line integrated commit records (Round 2 item 9) ---
# Item 8 wrote SSET/SET + EVT as two lines in one write() call. A torn
# OS-crash write could then leave the mutation line complete but the EVT
# line torn (dropped by wal_drop_torn): a durable mutation with no event.
# The V records integrate mutation + event into ONE line, so a torn write
# drops both atomically — the event log can never diverge from the DB:
#   SSETV\t<k>\t<v>\t<n>\t<evseq>\t<tenant>\t<etype>\t<payload>
#   SETV \t<k>\t<v>\t<evseq>\t<tenant>\t<etype>\t<payload>
#   DELV \t<k>\t<evseq>\t<tenant>\t<etype>\t<payload>
# v may contain structural tabs (user/article/pub serialization), so replay
# takes k first and peels the fixed trailing event fields off the reversed
# remainder, re-joining the middle as v. tenant/etype/payload are tab-free:
# payloads are built only from json_esc + Nat.show, and valid_tenant
# rejects tabs in tenant names (the same invariant KEY records rely on).
# Legacy SSET/SET/DEL/EVT lines remain replayable (dispatch order below).

def wal_evt_fields(+e: Evt) -> String:
  match e:
    case MkEvt{s, t, k, p}:
      Nat.show(s) ++ s_tab() ++ t ++ s_tab() ++ k ++ s_tab() ++ p

# Legacy two-line form, still used by snapshot EVT sections (snapshots are
# written to .tmp + renamed, so the torn-write concern does not apply).
def wal_evt_line(+e: Evt) -> String:
  "EVT" ++ s_tab() ++ wal_evt_fields(e) ++ "\n"

def wal_setseq_evt_go(me: Maybe<&1, Evt>, +k: String, +v: String, +n: Nat) -> IO(Bool):
  match me:
    case None{}: wal_setseq(k, v, n)
    case Some{+e}:
      wal_write("SSETV" ++ s_tab() ++ k ++ s_tab() ++ v ++ s_tab() ++ Nat.show(n) ++ s_tab() ++ wal_evt_fields(e) ++ "\n")

def wal_setseq_evt(+k: String, +v: String, +n: Nat, e: Maybe<&1, Evt>) -> IO(Bool):
  wal_setseq_evt_go(e, k, v, n)

def wal_set_evt_go(me: Maybe<&1, Evt>, +k: String, +v: String) -> IO(Bool):
  match me:
    case None{}: wal_set(k, v)
    case Some{+e}:
      wal_write("SETV" ++ s_tab() ++ k ++ s_tab() ++ v ++ s_tab() ++ wal_evt_fields(e) ++ "\n")

def wal_set_evt(+k: String, +v: String, e: Maybe<&1, Evt>) -> IO(Bool):
  wal_set_evt_go(e, k, v)

def wal_del_evt_go(me: Maybe<&1, Evt>, +k: String) -> IO(Bool):
  match me:
    case None{}: wal_del(k)
    case Some{+e}:
      wal_write("DELV" ++ s_tab() ++ k ++ s_tab() ++ wal_evt_fields(e) ++ "\n")

def wal_del_evt(+k: String, e: Maybe<&1, Evt>) -> IO(Bool):
  wal_del_evt_go(e, k)

# --- WAL replay (pure; uses split_char, never String.split) ---

def wal_do_set2(+k: String, +t: List<&2, String>, +st: MedState) -> MedState:
  match t:
    case Nil{}: st
    case _ <> _: st_with_db(st, Map.set(&2, String, st_db(st), k, join_str(t, s_tab())))

def wal_do_set(+rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: st
    case k <> t: wal_do_set2(k, t, st)

def wal_do_del(+rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: st
    case k <> t: st_with_db(st, Map.del(&2, String, st_db(st), k))

def wal_do_key_go(mk: Maybe<&1, Auth>, +st: MedState) -> MedState:
  match mk:
    case None{}: st
    case Some{+a}: st_with_keys(st, Map.set(&2, Auth, st_keys(st), auth_key(a), a))

def wal_do_key(+rest: List<&2, String>, +st: MedState) -> MedState:
  wal_do_key_go(apikey_deserialize(join_str(rest, s_tab())), st)

def wal_do_keyrot_go(mk: Maybe<&1, Auth>, +old_v: String, +st: MedState) -> MedState:
  match mk:
    case None{}: st
    case Some{+a}: st_with_keys(st, Map.set(&2, Auth, Map.del(&2, Auth, st_keys(st), old_v), auth_key(a), a))

def wal_do_keyrot(+rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: st
    case old_v <> t: wal_do_keyrot_go(apikey_deserialize(join_str(t, s_tab())), old_v, st)

def wal_do_keydel(+rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: st
    case v <> _: st_with_keys(st, Map.del(&2, Auth, st_keys(st), v))

def wal_do_seq_go(mn: Maybe<&1, Nat>, +st: MedState) -> MedState:
  match mn:
    case None{}: st
    # Round 3 item 136: max-defense on the record-id counter. Bare SEQ lines
    # are only ever written in the snapshot trailer; the live server never
    # emits them into WAL segments, so a bare SEQ in a segment is corrupt /
    # forged input. Applying it blindly rewinds st_seq: post-reboot writes
    # reuse ids and silently clobber existing records (evseq already takes
    # the max as defense in wal_push_evt; st_seq gets the same here and at
    # the SSET/SKEY/SSETV replay sites below). No-op on legitimate replay:
    # the single owner emits strictly increasing seqs.
    case Some{n}: st_with_seq(st, Nat.max(n, st_seq(st)))

def wal_do_seq(+rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: st
    case n <> t: wal_do_seq_go(parse_nat_opt(n), st)

# SSET: one line carries both the mutation and its sequence number.
# Format: SSET\t<k>\t<v>\t<seq>; v may itself contain tabs, seq is last.
def wal_do_setseq_apply(+k: String, +v: String, mn: Maybe<&1, Nat>, +st: MedState) -> MedState:
  match mn:
    case None{}: st
    case Some{n}: st_with_seq(st_with_db(st, Map.set(&2, String, st_db(st), k, v)), Nat.max(n, st_seq(st)))

def wal_do_setseq_v(+k: String, +seqs: String, +vparts: List<&2, String>, +st: MedState) -> MedState:
  wal_do_setseq_apply(k, join_str(vparts, s_tab()), parse_nat_opt(seqs), st)

def wal_do_setseq_rev(+k: String, +rev: List<&2, String>, +st: MedState) -> MedState:
  match rev:
    case Nil{}: st
    case seqs <> vrev: wal_do_setseq_v(k, seqs, List.reverse(&2, String, vrev), st)

def wal_do_setseq(+rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: st
    case k <> t: wal_do_setseq_rev(k, List.reverse(&2, String, t), st)

# SKEY: one line carries both the key record and its sequence number.
# Format: SKEY\t<kid>\t<k>\t<t>\t<r>\t<e>\t<rv>\t<seq>; seq is last.
def wal_do_keyseq_set(n: Nat, mk: Maybe<&1, Auth>, +st: MedState) -> MedState:
  match mk:
    case None{}: st
    case Some{+a}: st_with_seq(st_with_keys(st, Map.set(&2, Auth, st_keys(st), auth_key(a), a)), Nat.max(n, st_seq(st)))

def wal_do_keyseq_apply(+arec: List<&2, String>, mn: Maybe<&1, Nat>, +st: MedState) -> MedState:
  match mn:
    case None{}: st
    case Some{n}: wal_do_keyseq_set(n, apikey_deserialize(join_str(arec, s_tab())), st)

def wal_do_keyseq_rev(+rev: List<&2, String>, +st: MedState) -> MedState:
  match rev:
    case Nil{}: st
    case seqs <> arev: wal_do_keyseq_apply(List.reverse(&2, String, arev), parse_nat_opt(seqs), st)

def wal_do_keyseq(+rest: List<&2, String>, +st: MedState) -> MedState:
  wal_do_keyseq_rev(List.reverse(&2, String, rest), st)

# EVT replay: rebuild the in-memory evlog and evseq from persisted events so
# cursors survive restart. evseq takes the max as defense; the single owner
# emits strictly increasing seqs so replay order == seq order.
# Idempotent replay (Round 3 item 128): a SIGKILL between snapshot_save and
# wal_archive_covered leaves covered entries in wal/active; boot replays them
# over a snapshot that already contains them. SET/SEQ are absolute and
# idempotent, but evt_push is a blind prepend, so replaying a covered EVT
# duplicated the event. The live path always assigns es = evseq+1 (evt_emit)
# and snapshot EVT lines replay in increasing order from an empty state, so
# skipping a replayed event with es <= evseq can only drop an event the state
# already holds.
def wal_push_evt_go(skip: Bool, +st: MedState, +e: Evt, +es: Nat) -> MedState:
  match skip:
    case True{}: st
    case False{}: st_with_ev(st, evt_push(st_evlog(st), e), es)

def wal_push_evt(+st: MedState, +e: Evt, +es: Nat) -> MedState:
  wal_push_evt_go(Nat.is_le(es, st_evseq(st)), st, e, es)

def wal_do_evt_n(+n: Nat, +tenant: String, +etype: String, +payload: String, +st: MedState) -> MedState:
  wal_push_evt(st, MkEvt{n, tenant, etype, payload}, n)

def wal_do_evt_apply(mn: Maybe<&1, Nat>, +tenant: String, +etype: String, +payload: String, +st: MedState) -> MedState:
  match mn:
    case None{}: st
    case Some{n}: wal_do_evt_n(n, tenant, etype, payload, st)

def wal_do_evt_rest(mn: Maybe<&1, Nat>, +tenant: String, +rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: st
    case etype <> t: wal_do_evt_apply(mn, tenant, etype, join_str(t, s_tab()), st)

def wal_do_evt_tenant(mn: Maybe<&1, Nat>, +rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: st
    case tenant <> t: wal_do_evt_rest(mn, tenant, t, st)

def wal_do_evt(+rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: st
    case seqs <> t: wal_do_evt_tenant(parse_nat_opt(seqs), t, st)

# --- V-record replay (Round 2 item 9) ---
# SSETV: fields after op are k, v-parts.., n, evseq, tenant, etype, payload.
# v may contain structural tabs, so k is taken first and the five trailing
# event fields are peeled off the reversed remainder; the middle re-joins
# to v. Malformed records are skipped, never half-applied.
def wal_do_ssetv_ev_go(+es: Nat, +k: String, +vrev: List<&2, String>, +n: Nat, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  wal_push_evt(st_with_seq(st_with_db(st, Map.set(&2, String, st_db(st), k, join_str(List.reverse(&2, String, vrev), s_tab()))), Nat.max(n, st_seq(st))), MkEvt{es, tn, et, p}, es)

def wal_do_ssetv_ev(mes: Maybe<&1, Nat>, +k: String, +vrev: List<&2, String>, +n: Nat, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  match mes:
    case None{}: st
    case Some{es}: wal_do_ssetv_ev_go(es, k, vrev, n, tn, et, p, st)

def wal_do_ssetv_seq(mn: Maybe<&1, Nat>, +k: String, +vrev: List<&2, String>, +es: String, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  match mn:
    case None{}: st
    case Some{n}: wal_do_ssetv_ev(parse_nat_opt(es), k, vrev, n, tn, et, p, st)

def wal_do_ssetv_apply(+k: String, +vrev: List<&2, String>, +ns: String, +es: String, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  wal_do_ssetv_seq(parse_nat_opt(ns), k, vrev, es, tn, et, p, st)

def wal_do_ssetv_n(+k: String, +rev: List<&2, String>, +es: String, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  match rev:
    case Nil{}: st
    case ns <> vrev: wal_do_ssetv_apply(k, vrev, ns, es, tn, et, p, st)

def wal_do_ssetv_es(+k: String, +rev: List<&2, String>, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  match rev:
    case Nil{}: st
    case es <> r1: wal_do_ssetv_n(k, r1, es, tn, et, p, st)

def wal_do_ssetv_t(+k: String, +rev: List<&2, String>, +et: String, +p: String, +st: MedState) -> MedState:
  match rev:
    case Nil{}: st
    case tn <> r1: wal_do_ssetv_es(k, r1, tn, et, p, st)

def wal_do_ssetv_e(+k: String, +rev: List<&2, String>, +p: String, +st: MedState) -> MedState:
  match rev:
    case Nil{}: st
    case et <> r1: wal_do_ssetv_t(k, r1, et, p, st)

def wal_do_ssetv_p(+k: String, +rev: List<&2, String>, +st: MedState) -> MedState:
  match rev:
    case Nil{}: st
    case p <> r1: wal_do_ssetv_e(k, r1, p, st)

def wal_do_ssetv(+rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: st
    case k <> t: wal_do_ssetv_p(k, List.reverse(&2, String, t), st)

# SETV: fields after op are k, v-parts.., evseq, tenant, etype, payload
# (no sequence advance; used by claps and membership changes).
def wal_do_setv_ev_go(+es: Nat, +k: String, +vrev: List<&2, String>, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  wal_push_evt(st_with_db(st, Map.set(&2, String, st_db(st), k, join_str(List.reverse(&2, String, vrev), s_tab()))), MkEvt{es, tn, et, p}, es)

def wal_do_setv_ev(mes: Maybe<&1, Nat>, +k: String, +vrev: List<&2, String>, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  match mes:
    case None{}: st
    case Some{es}: wal_do_setv_ev_go(es, k, vrev, tn, et, p, st)

def wal_do_setv_apply(+k: String, +vrev: List<&2, String>, +es: String, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  wal_do_setv_ev(parse_nat_opt(es), k, vrev, tn, et, p, st)

def wal_do_setv_es(+k: String, +rev: List<&2, String>, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  match rev:
    case Nil{}: st
    case es <> vrev: wal_do_setv_apply(k, vrev, es, tn, et, p, st)

def wal_do_setv_t(+k: String, +rev: List<&2, String>, +et: String, +p: String, +st: MedState) -> MedState:
  match rev:
    case Nil{}: st
    case tn <> r1: wal_do_setv_es(k, r1, tn, et, p, st)

def wal_do_setv_e(+k: String, +rev: List<&2, String>, +p: String, +st: MedState) -> MedState:
  match rev:
    case Nil{}: st
    case et <> r1: wal_do_setv_t(k, r1, et, p, st)

def wal_do_setv_p(+k: String, +rev: List<&2, String>, +st: MedState) -> MedState:
  match rev:
    case Nil{}: st
    case p <> r1: wal_do_setv_e(k, r1, p, st)

def wal_do_setv(+rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: st
    case k <> t: wal_do_setv_p(k, List.reverse(&2, String, t), st)

# DELV: fixed six fields — DELV\t<k>\t<evseq>\t<tenant>\t<etype>\t<payload>.
def wal_do_delv_ev_go(+es: Nat, +k: String, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  wal_push_evt(st_with_db(st, Map.del(&2, String, st_db(st), k)), MkEvt{es, tn, et, p}, es)

def wal_do_delv_ev(mes: Maybe<&1, Nat>, +k: String, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  match mes:
    case None{}: st
    case Some{es}: wal_do_delv_ev_go(es, k, tn, et, p, st)

def wal_do_delv_apply(+k: String, +es: String, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  wal_do_delv_ev(parse_nat_opt(es), k, tn, et, p, st)

def wal_do_delv_p2(+k: String, +es: String, +tn: String, +et: String, +p: String, +rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: wal_do_delv_apply(k, es, tn, et, p, st)
    case _ <> _: st

def wal_do_delv_p(+k: String, +es: String, +tn: String, +et: String, +t: List<&2, String>, +st: MedState) -> MedState:
  match t:
    case Nil{}: st
    case p <> rest: wal_do_delv_p2(k, es, tn, et, p, rest, st)

def wal_do_delv_e(+k: String, +es: String, +tn: String, +t: List<&2, String>, +st: MedState) -> MedState:
  match t:
    case Nil{}: st
    case et <> t2: wal_do_delv_p(k, es, tn, et, t2, st)

def wal_do_delv_t(+k: String, +es: String, +t: List<&2, String>, +st: MedState) -> MedState:
  match t:
    case Nil{}: st
    case tn <> t2: wal_do_delv_e(k, es, tn, t2, st)

def wal_do_delv_es(+k: String, +t: List<&2, String>, +st: MedState) -> MedState:
  match t:
    case Nil{}: st
    case es <> t2: wal_do_delv_t(k, es, t2, st)

def wal_do_delv(+rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: st
    case k <> t: wal_do_delv_es(k, t, st)

def wal_replay_op_keydel(is_keydel: Bool, +rest: List<&2, String>, +st: MedState) -> MedState:
  match is_keydel:
    case True{}: wal_do_keydel(rest, st)
    case False{}: st

def wal_replay_op5(is_keyrot: Bool, is_keydel: Bool, +rest: List<&2, String>, +st: MedState) -> MedState:
  match is_keyrot:
    case True{}: wal_do_keyrot(rest, st)
    case False{}: wal_replay_op_keydel(is_keydel, rest, st)

def wal_replay_op4(is_seq: Bool, is_keyrot: Bool, is_keydel: Bool, +rest: List<&2, String>, +st: MedState) -> MedState:
  match is_seq:
    case True{}: wal_do_seq(rest, st)
    case False{}: wal_replay_op5(is_keyrot, is_keydel, rest, st)

def wal_replay_op3(is_key: Bool, is_seq: Bool, is_keyrot: Bool, is_keydel: Bool, +rest: List<&2, String>, +st: MedState) -> MedState:
  match is_key:
    case True{}: wal_do_key(rest, st)
    case False{}: wal_replay_op4(is_seq, is_keyrot, is_keydel, rest, st)

def wal_replay_op2(is_del: Bool, is_key: Bool, is_seq: Bool, is_keyrot: Bool, is_keydel: Bool, +rest: List<&2, String>, +st: MedState) -> MedState:
  match is_del:
    case True{}: wal_do_del(rest, st)
    case False{}: wal_replay_op3(is_key, is_seq, is_keyrot, is_keydel, rest, st)

def wal_replay_op_go(is_set: Bool, is_del: Bool, is_key: Bool, is_seq: Bool, is_keyrot: Bool, is_keydel: Bool, +rest: List<&2, String>, +st: MedState) -> MedState:
  match is_set:
    case True{}: wal_do_set(rest, st)
    case False{}: wal_replay_op2(is_del, is_key, is_seq, is_keyrot, is_keydel, rest, st)

# New single-line commit records are dispatched before the legacy chain.
def wal_replay_op_legacy(+op: String, +rest: List<&2, String>, +st: MedState) -> MedState:
  wal_replay_op_go(String.eq(op, "SET"), String.eq(op, "DEL"), String.eq(op, "KEY"), String.eq(op, "SEQ"), String.eq(op, "KEYROT"), String.eq(op, "KEYDEL"), rest, st)

def wal_replay_op_new3(is_evt: Bool, +op: String, +rest: List<&2, String>, +st: MedState) -> MedState:
  match is_evt:
    case True{}: wal_do_evt(rest, st)
    case False{}: wal_replay_op_legacy(op, rest, st)

def wal_replay_op_new2(is_skey: Bool, is_evt: Bool, +op: String, +rest: List<&2, String>, +st: MedState) -> MedState:
  match is_skey:
    case True{}: wal_do_keyseq(rest, st)
    case False{}: wal_replay_op_new3(is_evt, op, rest, st)

def wal_replay_op_new(is_sset: Bool, is_skey: Bool, is_evt: Bool, +op: String, +rest: List<&2, String>, +st: MedState) -> MedState:
  match is_sset:
    case True{}: wal_do_setseq(rest, st)
    case False{}: wal_replay_op_new2(is_skey, is_evt, op, rest, st)

# The single-line V records dispatch before the legacy chain; legacy
# SSET/SKEY/EVT/SET/DEL/KEY/SEQ/KEYROT lines remain replayable.
def wal_replay_op_v3(is_delv: Bool, +op: String, +rest: List<&2, String>, +st: MedState) -> MedState:
  match is_delv:
    case True{}: wal_do_delv(rest, st)
    case False{}: wal_replay_op_new(String.eq(op, "SSET"), String.eq(op, "SKEY"), String.eq(op, "EVT"), op, rest, st)

def wal_replay_op_v2(is_setv: Bool, is_delv: Bool, +op: String, +rest: List<&2, String>, +st: MedState) -> MedState:
  match is_setv:
    case True{}: wal_do_setv(rest, st)
    case False{}: wal_replay_op_v3(is_delv, op, rest, st)

def wal_replay_op_v(is_ssetv: Bool, is_setv: Bool, is_delv: Bool, +op: String, +rest: List<&2, String>, +st: MedState) -> MedState:
  match is_ssetv:
    case True{}: wal_do_ssetv(rest, st)
    case False{}: wal_replay_op_v2(is_setv, is_delv, op, rest, st)

def wal_replay_op(+op: String, +rest: List<&2, String>, +st: MedState) -> MedState:
  wal_replay_op_v(String.eq(op, "SSETV"), String.eq(op, "SETV"), String.eq(op, "DELV"), op, rest, st)

def wal_replay_parts(+parts: List<&2, String>, +st: MedState) -> MedState:
  match parts:
    case Nil{}: st
    case op <> rest: wal_replay_op(op, rest, st)

def wal_replay_line_empty(is_empty: Bool, +line: String, +st: MedState) -> MedState:
  match is_empty:
    case True{}: st
    case False{}: wal_replay_parts(split_char(line, ch_tab()), st)

def wal_replay_line(+line: String, +st: MedState) -> MedState:
  wal_replay_line_empty(String.is_empty(line), line, st)

def wal_replay_lines(+lines: List<&2, String>, +st: MedState) -> MedState:
  match lines:
    case Nil{}: st
    case h <> t: wal_replay_lines(t, wal_replay_line(h, st))

# A well-formed WAL always ends each record with \n, so split_char's last
# segment is "". A non-empty last segment is a torn trailing write from a
# crash mid-write: drop it rather than replaying a partial record.
def wal_drop_torn_decide(empty: Bool, +h: String, +t: List<&2, String>) -> List<&2, String>:
  match empty:
    case True{}: List.reverse(&2, String, h <> t)
    case False{}: List.reverse(&2, String, t)

def wal_drop_torn_head(+h: String, +t: List<&2, String>) -> List<&2, String>:
  wal_drop_torn_decide(String.is_empty(h), h, t)

def wal_drop_torn(+rev: List<&2, String>) -> List<&2, String>:
  match rev:
    case Nil{}: Nil{}
    case h <> t: wal_drop_torn_head(h, t)

def wal_replay(+content: String, +st: MedState) -> MedState:
  wal_replay_lines(wal_drop_torn(List.reverse(&2, String, split_char(content, ch_lf()))), st)

# --- snapshots ---
# Snapshot writes are fsync'd like WAL writes (Round 2 item 7): the Bool
# returned is True only if write AND sync both succeeded, so a promoted
# snapshot is durable against process death and OS crashes. This is not a
# power-loss claim, and newly created file metadata would need a
# parent-directory fsync for the strongest POSIX durability argument.

def snap_sync_done(sr: File & Result<&1, &1, U32 & String, Unit>) -> IO(Bool):
  (f3, sres) = sr
  match sres:
    case Fail{e}:
      do IO<Bool>:
        _c : Unit <- File.close(f3)
        IO.pure(Bool, False{})
    case Done{u}:
      do IO<Bool>:
        _c : Unit <- File.close(f3)
        IO.pure(Bool, True{})

def snap_write_done(wr: File & Result<&1, &1, U32 & String, Unit>) -> IO(Bool):
  (f2, res) = wr
  match res:
    case Fail{e}:
      do IO<Bool>:
        _c : Unit <- File.close(f2)
        IO.pure(Bool, False{})
    case Done{u}:
      do IO<Bool>:
        sr : File & Result<&1, &1, U32 & String, Unit> <- File.sync(f2)
        snap_sync_done(sr)

def snap_write_open(r: Result<&1, &1, U32 & String, File>, +content: String) -> IO(Bool):
  match r:
    case Fail{e}: IO.pure(Bool, False{})
    case Done{f}:
      do IO<Bool>:
        wr : File & Result<&1, &1, U32 & String, Unit> <- File.write(f, content)
        snap_write_done(wr)

def snap_kv(+k: String, +v: String) -> String:
  "SET" ++ s_tab() ++ k ++ s_tab() ++ v ++ "\n"

def snap_db_go(+kvs: List<&2, Sigma<&2, &2, String, _ => String>>) -> String:
  match kvs:
    case Nil{}: ""
    case h <> t:
      (k, v) = h
      snap_kv(k, v) ++ snap_db_go(t)

def snap_db(+db: Map<&2, String>) -> String:
  snap_db_go(Map.to_list(&2, String, db))

def snap_keys_go(+kvs: List<&2, Sigma<&2, &2, String, _ => Auth>>) -> String:
  match kvs:
    case Nil{}: ""
    case h <> t:
      (k, +a) = h
      "KEY" ++ s_tab() ++ apikey_serialize(a) ++ "\n" ++ snap_keys_go(t)

def snap_keys(+keys: Map<&2, Auth>) -> String:
  snap_keys_go(Map.to_list(&2, Auth, keys))

# Persisted commit events in the snapshot (Round 2 item 8): the in-memory
# evlog is newest-first; serialize oldest-first so replay (which prepends
# via evt_push) rebuilds newest-first. Bounded by the same 1000-entry trim.
# Placed before the SEQ trailer so snap_trailer_ok is unaffected.
def snap_evts_go(+log: List<&2, Evt>) -> String:
  match log:
    case Nil{}: ""
    case h <> t: wal_evt_line(h) ++ snap_evts_go(t)

def snap_evts(+log: List<&2, Evt>) -> String:
  snap_evts_go(List.reverse(&2, Evt, log))

# --- rate-limit bucket persistence across graceful restart (Round 3 item 172) ---
# The rl map ("bucket-id" -> "window_start,count"; windows anchored on the
# monotonic IO.now clock, one iprl_window_ms window) used to be absent from
# snapshots, so every restart wiped ALL buckets. For kr: (Round 3 item 20,
# MEDIUM_RESTART_RL/60s per presented token) that is self-defeating: the
# limiter lives in the very map the restart destroys, so it could never
# bind an admin chaining restarts -- the exact permanent-restart-loop threat
# the item-20 comment names. The same wipe also refreshed kt:/kb:/ks:/ip:/
# ipd: quotas on every restart (quota amplification via restart chaining).
#
# Fix: the final pre-restart snapshot (st.restart is set; periodic
# snapshots are unaffected) carries an RL section with every still-live
# bucket entry, serialized as a pure duration:
#   RL\t<bucket-id>\t<remaining_ms>\t<count>
# Boot (med_init_after_boot) rebases each entry into the new monotonic
# clock domain: start' = max(0, now + rem - window), rem clamped to one
# window. Expired entries (rem 0) are dropped at save; malformed RL lines
# are skipped at load (fail-closed: a bad line restores nothing). Bucket
# ids are server-constructed ("kr:/ks:/kb:v1$<64hex>", "kt:<alnum-_>",
# "ip:/ipd:<addr>") and cannot contain tab/LF, so the tab-separated line
# format is injection-safe by construction. Crash recovery (SIGKILL) still
# wipes: no final snapshot runs, and periodic snapshots carry no RL
# section -- accepted and documented.

def iprl_window_ms() -> Nat:
  Nat.mul(600n, 100n)

def snap_rl_rem(+now: Nat, +start: Nat) -> Nat:
  Nat.sub(iprl_window_ms(), Nat.sub(now, start))

def snap_rl_emit(skip: Bool, +rem: Nat, +k: String, +count: Nat) -> String:
  match skip:
    case True{}: ""
    case False{}: "RL" ++ s_tab() ++ k ++ s_tab() ++ Nat.show(rem) ++ s_tab() ++ Nat.show(count) ++ "\n"

def snap_rl_line_go(+now: Nat, +k: String, +start: Nat, +count: Nat) -> String:
  snap_rl_emit(Nat.is_eq(snap_rl_rem(now, start), 0n), snap_rl_rem(now, start), k, count)

def snap_rl_parsed(+now: Nat, +k: String, sc: Nat & Nat) -> String:
  (+start, count) = sc
  snap_rl_line_go(now, k, start, count)

def snap_rl_line(+now: Nat, +kv: Sigma<&2, &2, String, _ => String>) -> String:
  (k, v) = kv
  snap_rl_parsed(now, k, rl_parse(v))

def snap_rl_go(+now: Nat, +kvs: List<&2, Sigma<&2, &2, String, _ => String>>) -> String:
  match kvs:
    case Nil{}: ""
    case h <> t: snap_rl_line(now, h) ++ snap_rl_go(now, t)

def snap_rl_section_go(is_restart: Bool, +st: MedState, +now: Nat) -> String:
  match is_restart:
    case True{}: snap_rl_go(now, Map.to_list(&2, String, st_rl(st)))
    case False{}: ""

def snap_rl_section(+st: MedState, +now: Nat) -> String:
  snap_rl_section_go(st_restart(st), st, now)

# --- record-count binding in the snapshot trailer (Round 3 item 189) ---
# Item-188 E8 proved a silent-partial-state path: a snapshot cut at a real
# line boundary with the original valid "SEQ\t<n>" trailer re-appended
# passes the purely syntactic snap_trailer_ok, boots clean, and serves
# 354/600 articles — 246 silently missing (the item-138 archive-coverage
# guard only replays segments newer than the claimed SEQ, so the middle
# range vanishes). The trailer now also carries the number of record lines
# the snapshot claims, and boot verifies the actual count matches (see
# snap_count_ok + the tamper gate in med_init_boot_after_tamper).
# Every record line is one non-empty "\n"-terminated line, so the record
# count is the number of non-empty lines. Replay is unaffected: wal_do_seq
# takes the first field and ignores the rest; snap_seq_of still works
# because rl_nat stops at the first non-digit.
def snap_record_count_go(+lines: List<&2, String>, +acc: Nat) -> Nat:
  match lines:
    case Nil{}: acc
    case h <> t: snap_record_count_go(t, Nat.add(acc, Bool.pick(Nat, String.is_empty(h), 0n, 1n)))

def snap_record_count(+body: String) -> Nat:
  snap_record_count_go(split_char(body, ch_lf()), 0n)

def snap_body(+st: MedState, +now: Nat) -> String:
  snap_db(st_db(st)) ++ snap_keys(st_keys(st)) ++ snap_evts(st_evlog(st)) ++ snap_rl_section(st, now)

def snap_with_trailer(+st: MedState, +body: String) -> String:
  body ++ "SEQ" ++ s_tab() ++ Nat.show(st_seq(st)) ++ s_tab() ++ Nat.show(snap_record_count(body)) ++ "\n"

def snap_content(+st: MedState, +now: Nat) -> String:
  snap_with_trailer(st, snap_body(st, now))

# Item 197: the unsigned snapshot content (body ++ "SEQ\t<seq>\t<count>",
# no trailing newline): the exact bytes the trailer MAC is computed over.
# Pure helper so the affine state can feed both body and seq.
def snap_unsigned_content(+st: MedState, +now: Nat) -> String:
  +body : String = snap_body(st, now)
  body ++ "SEQ" ++ s_tab() ++ Nat.show(st_seq(st)) ++ s_tab() ++ Nat.show(snap_record_count(body))

# Item 197: snapshot content with a signed trailer when a key is configured:
#   SEQ\t<seq>\t<count>\t<mac>
# mac = HMAC-SHA256(key, body ++ "SEQ\t" ++ seq ++ "\t" ++ count).
# With the key empty, byte-identical to snap_content (item-189 3-field
# trailer). The key is read at each snapshot cycle, so a rotation takes
# effect on the next cycle without a restart.
def snap_add_mac(+unsigned: String, +key: String) -> IO(String):
  do IO<String>:
    mac : String <- FS.hmac_sha256_hex(key, unsigned)
    IO.pure(String, unsigned ++ s_tab() ++ mac ++ "\n")

def snap_content_signed_go(no_key: Bool, +st: MedState, +now: Nat, +key: String) -> IO(String):
  match no_key:
    case True{}: IO.pure(String, snap_content(st, now))
    case False{}: snap_add_mac(snap_unsigned_content(st, now), key)

def snap_content_signed(+st: MedState, +now: Nat, +key: String) -> IO(String):
  snap_content_signed_go(String.is_empty(key), st, now, key)

def snap_write_path(+path: String, +content: String) -> IO(Bool):
  do IO<Bool>:
    r : Result<&1, &1, U32 & String, File> <- File.open(path, "w")
    snap_write_open(r, content)

def snap_read_done(rr: File & Result<&1, &1, U32 & String, String>) -> IO(String):
  (f2, res) = rr
  match res:
    case Fail{e}:
      do IO<String>:
        _c : Unit <- File.close(f2)
        IO.pure(String, "")
    case Done{content}:
      do IO<String>:
        _c : Unit <- File.close(f2)
        IO.pure(String, content)

def snap_read_open(r: Result<&1, &1, U32 & String, File>) -> IO(String):
  match r:
    case Fail{e}: IO.pure(String, "")
    case Done{f}:
      do IO<String>:
        # 80 MiB read cap: covers 64 MiB segments plus headroom for the final
        # appended record.
        rr : File & Result<&1, &1, U32 & String, String> <- File.read(f, U32.mul(80, U32.mul(U32.mul(32, 32), U32.mul(32, 32))))
        snap_read_done(rr)

def snap_read_path(+path: String) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    snap_read_open(r)

# --- snapshot trailer validation ---
# A snapshot is complete iff it ends with "\n" and its last non-empty line
# is the SEQ trailer. Used to pick a good file on startup and to verify
# writes before truncating the WAL.

def snap_nonempty_last(+lines: List<&2, String>, +acc: String) -> String:
  match lines:
    case Nil{}: acc
    case h <> t:
      snap_nonempty_last(t, Bool.pick(String, String.is_empty(h), acc, h))

def snap_trailer_ok(+content: String) -> Bool:
  Bool.and(String.ends_with(content, "\n"),
    String.starts_with(snap_nonempty_last(split_char(content, ch_lf()), ""), "SEQ" ++ s_tab()))

def snap_seq_of_field(+fields: List<&2, String>) -> Nat:
  match fields:
    case Nil{}: 0n
    case seq_s <> _: rl_nat(seq_s)

def snap_seq_of(+content: String) -> Nat:
  snap_seq_of_field(split_char(String.drop(snap_nonempty_last(split_char(content, ch_lf()), ""), 4n), ch_tab()))

# --- snapshot trailer HMAC (Round 3 item 197; T7 residual) ---
# The item-189 count binding ("SEQ\t<seq>\t<count>") stops the naive E8
# forgery, but a filesystem writer can rewrite the count to match a forged
# body. The item-197 trailer appends a 4th field:
#   SEQ\t<seq>\t<count>\t<mac>
# mac = HMAC-SHA256(key, body ++ "SEQ\t" ++ seq ++ "\t" ++ count), where
# key comes from MEDIUM_SNAPSHOT_HMAC_KEY (out-of-band env, never the
# waldir). Pure-Bend HMAC measured ~2 KiB/s native — infeasible for
# boot-time verification of multi-MiB snapshots — so the MAC runs in the
# snap_hmac.c effect (self-contained FIPS 180-4 + RFC 2104).
#
# Key semantics:
# - MEDIUM_SNAPSHOT_HMAC_KEY unset/empty: writer emits the byte-identical
#   item-189 3-field trailer; boot verifies nothing (loud once-per-boot
#   warning). Documented safe default: existing deployments keep working;
#   the degraded mode is exactly the shipped item-189 posture.
# - KEY set: writer signs; boot FATALS on missing/mismatched MAC.
# - MEDIUM_SNAPSHOT_HMAC_KEY_PREV: accepted for VERIFICATION ONLY (never
#   signing). Rotation: set PREV=old + KEY=new, wait one snapshot cycle
#   (500 seqs, or a graceful shutdown's final snapshot), unset PREV.
# - MEDIUM_SNAPSHOT_HMAC_ALLOW_LEGACY=1: one-boot migration flag. With KEY
#   set, a MAC-less trailer is accepted with a loud WARNING (instead of
#   the steady-state FATAL) and the next snapshot cycle re-signs it.
def snap_hmac_key_env(mr: Result<&1, &1, U32 & String, String>) -> String:
  match mr:
    case Fail{e}: ""
    case Done{+s}: s

def snap_hmac_key() -> IO(String):
  do IO<String>:
    mr : Result<&1, &1, U32 & String, String> <- IO.get_env("MEDIUM_SNAPSHOT_HMAC_KEY")
    IO.pure(String, snap_hmac_key_env(mr))

def snap_hmac_key_prev() -> IO(String):
  do IO<String>:
    mr : Result<&1, &1, U32 & String, String> <- IO.get_env("MEDIUM_SNAPSHOT_HMAC_KEY_PREV")
    IO.pure(String, snap_hmac_key_env(mr))

def snap_hmac_allow_legacy_env(mr: Result<&1, &1, U32 & String, String>) -> Bool:
  match mr:
    case Fail{e}: False{}
    case Done{+s}: String.eq(s, "1")

def snap_hmac_allow_legacy() -> IO(Bool):
  do IO<Bool>:
    mr : Result<&1, &1, U32 & String, String> <- IO.get_env("MEDIUM_SNAPSHOT_HMAC_ALLOW_LEGACY")
    IO.pure(Bool, snap_hmac_allow_legacy_env(mr))

# --- snapshot record-count verification (Round 3 item 189) ---
# The trailer line is "SEQ\t<seq>\t<count>" (item 189+). Pre-item-189
# trailers carry only "SEQ\t<seq>" — no count to check; accepted for
# r56->r57 upgrade continuity, with a loud boot warning (see
# snapshot_boot_check below). A trailer with 3+ fields is malformed and
# fails the check loudly.
def snap_trailer_line(+content: String) -> String:
  snap_nonempty_last(split_char(content, ch_lf()), "")

def snap_rest_nonempty(+rest: List<&2, String>) -> Bool:
  match rest:
    case Nil{}: False{}
    case _ <> _: True{}

def snap_count_field_present(+fields: List<&2, String>) -> Bool:
  match fields:
    case Nil{}: False{}
    case _ <> rest: snap_rest_nonempty(rest)

def snap_trailer_has_count(+content: String) -> Bool:
  snap_count_field_present(split_char(String.drop(snap_trailer_line(content), 4n), ch_tab()))

def snap_claimed_count_tail(+tail: List<&2, String>, +cnt: String, +content: String) -> Bool:
  match tail:
    case Nil{}: Nat.is_eq(rl_nat(cnt), Nat.sub(snap_record_count(content), 1n))
    case _ <> _: False{}

def snap_claimed_count_rest(+rest: List<&2, String>, +content: String) -> Bool:
  match rest:
    case Nil{}: True{}
    case cnt <> tail: snap_claimed_count_tail(tail, cnt, content)

def snap_claimed_count_go(+fields: List<&2, String>, +content: String) -> Bool:
  match fields:
    case Nil{}: False{}
    case _ <> rest: snap_claimed_count_rest(rest, content)

def snap_count_ok(+content: String) -> Bool:
  snap_claimed_count_go(split_char(String.drop(snap_trailer_line(content), 4n), ch_tab()), content)

def snap_full_ok(+content: String) -> Bool:
  Bool.and(snap_trailer_ok(content), snap_count_ok(content))

# --- atomic-ish snapshot save ---
# No File.rename in Base, so: write tmp -> verify tmp -> overwrite main ->
# verify main -> clear tmp. A crash during the main overwrite leaves the
# verified tmp behind; startup prefers a verified main, else falls back to
# a verified tmp (tmp is cleared after every successful cycle, so any
# non-empty tmp is strictly newer than main).

def snap_tmp_check(ok: Bool) -> IO(Bool):
  match ok:
    case False{}: IO.pure(Bool, False{})
    case True{}:
      do IO<Bool>:
        content : String <- snap_read_path("bocht.snapshot.tmp")
        IO.pure(Bool, snap_trailer_ok(content))

def snapshot_save_tmp(+st: MedState) -> IO(Bool):
  do IO<Bool>:
    now : Nat <- IO.now()
    key : String <- snap_hmac_key()
    content : String <- snap_content_signed(st, now, key)
    ok : Bool <- snap_write_path("bocht.snapshot.tmp", content)
    snap_tmp_check(ok)

def snap_promote_check(ok: Bool) -> IO(Bool):
  match ok:
    case False{}: IO.pure(Bool, False{})
    case True{}:
      do IO<Bool>:
        content : String <- snap_read_path("bocht.snapshot")
        IO.pure(Bool, snap_trailer_ok(content))

def snapshot_promote(+st: MedState) -> IO(Bool):
  do IO<Bool>:
    now : Nat <- IO.now()
    key : String <- snap_hmac_key()
    content : String <- snap_content_signed(st, now, key)
    ok : Bool <- snap_write_path("bocht.snapshot", content)
    snap_promote_check(ok)

def snap_save_clear(ok: Bool) -> IO(Bool):
  match ok:
    case False{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: snapshot promote FAILED, keeping WAL\n")
        IO.pure(Bool, False{})
    case True{}:
      do IO<Bool>:
        _b : Bool <- snap_write_path("bocht.snapshot.tmp", "")
        IO.pure(Bool, True{})

def snap_save_promote(tmp_ok: Bool, +st: MedState) -> IO(Bool):
  match tmp_ok:
    case False{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: snapshot tmp write FAILED, keeping WAL\n")
        IO.pure(Bool, False{})
    case True{}:
      do IO<Bool>:
        ok : Bool <- snapshot_promote(st)
        snap_save_clear(ok)

def snapshot_save(+st: MedState) -> IO(Bool):
  do IO<Bool>:
    tmp_ok : Bool <- snapshot_save_tmp(st)
    snap_save_promote(tmp_ok, st)

def snapshot_load_tmp_ok(ok: Bool, +tmp: String) -> IO(String):
  match ok:
    case True{}: IO.pure(String, tmp)
    case False{}: IO.pure(String, "")

def snapshot_load_tmp_go(+tmp: String) -> IO(String):
  snapshot_load_tmp_ok(snap_trailer_ok(tmp), tmp)

def snapshot_load_tmp() -> IO(String):
  do IO<String>:
    tmp : String <- snap_read_path("bocht.snapshot.tmp")
    snapshot_load_tmp_go(tmp)

def snapshot_load_pick(main_ok: Bool, +main: String) -> IO(String):
  match main_ok:
    case True{}: IO.pure(String, main)
    case False{}: snapshot_load_tmp()

def snapshot_load_go(+main: String) -> IO(String):
  snapshot_load_pick(snap_trailer_ok(main), main)

def snapshot_load() -> IO(String):
  do IO<String>:
    main : String <- snap_read_path("bocht.snapshot")
    snapshot_load_go(main)

# --- tamper-evident boot gate (Round 3 item 189) ---
# A non-empty snapshot file with a syntactically valid trailer whose
# record-count binding fails is evidence of out-of-band truncation or
# tampering (the item-188 E8 forgery shape: 354 records + the original
# valid trailer re-appended). Torn/incomplete writes have NO valid trailer
# and are not tamper evidence — they keep the existing fallback/cover
# behavior. Pre-item-189 ("legacy") trailers carry no count field; they
# are accepted for r56->r57 upgrade continuity with a loud warning, and
# are rewritten in the new format on the next snapshot cycle.
def snap_file_bad(+content: String) -> Bool:
  Bool.and(Bool.not(String.is_empty(content)),
    Bool.and(snap_trailer_ok(content), Bool.not(snap_count_ok(content))))

def snap_boot_warn(+content: String) -> Bool:
  Bool.and(Bool.not(String.is_empty(content)),
    Bool.and(snap_trailer_ok(content), Bool.not(snap_trailer_has_count(content))))

def snap_boot_warn_print(warn: Bool) -> IO(Unit):
  match warn:
    case True{}: IO.print("medium-fresh: WARNING: legacy snapshot trailer without record-count binding (pre-item-189 format); accepted for upgrade continuity, rewritten on next snapshot cycle\n")
    case False{}: IO.pure(Unit, Unit{})

def snap_boot_warn_print2(+main: String, +tmp: String) -> IO(Unit):
  do IO<Unit>:
    _a : Unit <- snap_boot_warn_print(snap_boot_warn(main))
    _b : Unit <- snap_boot_warn_print(snap_boot_warn(tmp))
    IO.pure(Unit, Unit{})

def snap_boot_bad2(+main: String, +tmp: String) -> Bool:
  Bool.or(snap_file_bad(main), snap_file_bad(tmp))

def snapshot_boot_check_go(+main: String, +tmp: String) -> IO(Bool):
  do IO<Bool>:
    _w : Unit <- snap_boot_warn_print2(main, tmp)
    IO.pure(Bool, snap_boot_bad2(main, tmp))

def snapshot_boot_check_tmp(+main: String) -> IO(Bool):
  do IO<Bool>:
    tmp : String <- snap_read_path("bocht.snapshot.tmp")
    snapshot_boot_check_go(main, tmp)

def snapshot_boot_check() -> IO(Bool):
  do IO<Bool>:
    main : String <- snap_read_path("bocht.snapshot")
    snapshot_boot_check_tmp(main)

# --- single-split snapshot boot (Round 3 item 196) ---
# Boot used to run split_char over the FULL snapshot content ~10 times
# (snapshot_load trailer pick, snapshot_boot_check trailer+count,
# wal_snap_ok x3, wal_replay, snap_seq_of, wal_snap_max_seq,
# snap_rl_restore). At ~25s per 52 MiB pass (measured 2026-09-28 on the
# item-196 burst snapshot), boot exceeded 5 minutes on large snapshots and
# the SIGKILL+reboot durability probe timed out. snapshot_boot_load splits
# each snapshot file ONCE and every downstream boot step works from that
# single line list. All predicates below are equivalent to their
# content-based originals: snap_ends_lf == String.ends_with(content, "\n"),
# and the empty-content guard in snap_file_bad is subsumed by trailer_ok
# (a trailer_ok file is never empty).

def snap_ends_lf_last(+rest: List<&2, String>, +last: String, +n: Nat) -> Bool:
  match rest:
    case Nil{}: Bool.and(Nat.is_ge(n, 2n), String.is_empty(last))
    case h <> t: snap_ends_lf_last(t, h, Nat.add(n, 1n))

def snap_ends_lf(+lines: List<&2, String>) -> Bool:
  match lines:
    case Nil{}: False{}
    case h <> t: snap_ends_lf_last(t, h, 1n)

def snap_lines_ok(+lines: List<&2, String>) -> Bool:
  Bool.and(snap_ends_lf(lines),
    String.starts_with(snap_nonempty_last(lines, ""), "SEQ" ++ s_tab()))

# Item 197: a 4-field trailer [seq, count, mac] still binds the count
# (the MAC covers it too); 5+ fields is malformed.
def snap_claimed_count_tail_rest(+rest: List<&2, String>, +c: String, +cnt: Nat) -> Bool:
  match rest:
    case Nil{}: Nat.is_eq(rl_nat(c), Nat.sub(cnt, 1n))
    case _ <> _: False{}

def snap_claimed_count_tail_scan(+tail: List<&2, String>, +c: String, +cnt: Nat) -> Bool:
  match tail:
    case Nil{}: Nat.is_eq(rl_nat(c), Nat.sub(cnt, 1n))
    case _ <> rest: snap_claimed_count_tail_rest(rest, c, cnt)

def snap_claimed_count_rest_scan(+rest: List<&2, String>, +cnt: Nat) -> Bool:
  match rest:
    case Nil{}: True{}
    case c <> tail: snap_claimed_count_tail_scan(tail, c, cnt)

def snap_claimed_count_scan(+fields: List<&2, String>, +cnt: Nat) -> Bool:
  match fields:
    case Nil{}: False{}
    case _ <> rest: snap_claimed_count_rest_scan(rest, cnt)

def snap_count_ok_trailer(+trailer: String, +cnt: Nat) -> Bool:
  +fields : List<&2, String> = split_char(String.drop(trailer, 4n), ch_tab())
  snap_claimed_count_scan(fields, cnt)

def snap_lines_count_ok(+lines: List<&2, String>) -> Bool:
  +trailer : String = snap_nonempty_last(lines, "")
  +cnt : Nat = snap_record_count_go(lines, 0n)
  snap_count_ok_trailer(trailer, cnt)

def snap_lines_bad(+lines: List<&2, String>) -> Bool:
  Bool.and(snap_lines_ok(lines), Bool.not(snap_lines_count_ok(lines)))

def snap_lines_pick_tmp(tmp_ok: Bool, +tampered: Bool, +tlines: List<&2, String>) -> List<&2, String> & Bool:
  match tmp_ok:
    case True{}: (tlines, tampered)
    case False{}: (split_char("", ch_lf()), tampered)

def snap_lines_pick_which(main_ok: Bool, tmp_ok: Bool, +tampered: Bool, +mlines: List<&2, String>, +tlines: List<&2, String>) -> List<&2, String> & Bool:
  match main_ok:
    case True{}: (mlines, tampered)
    case False{}: snap_lines_pick_tmp(tmp_ok, tampered, tlines)

def snap_lines_pick(+mlines: List<&2, String>, +tlines: List<&2, String>) -> List<&2, String> & Bool:
  +main_ok : Bool = snap_lines_ok(mlines)
  +tmp_ok : Bool = snap_lines_ok(tlines)
  +tampered : Bool = Bool.or(snap_lines_bad(mlines), snap_lines_bad(tlines))
  snap_lines_pick_which(main_ok, tmp_ok, tampered, mlines, tlines)

# --- snapshot trailer HMAC verification (Round 3 item 197) ---
# Runs on the single-split line lists (item-196): no extra full-content
# passes. The MAC message is rebuilt from the scanned lines as
#   body ++ "SEQ\t" ++ seq_field ++ "\t" ++ count_field
# using the RAW field strings, so the verifier hashes byte-identical input
# to the writer. Body = all lines except the trailer line and the trailing
# "" (joined with "\n" plus one "\n"; "" when the body is empty).

# The trailer line's fields after "SEQ\t": [seq], [seq, count],
# [seq, count, mac], or longer (malformed).
def snap_trailer_fields(+lines: List<&2, String>) -> List<&2, String>:
  split_char(String.drop(snap_nonempty_last(lines, ""), 4n), ch_tab())

def snap_drop2(+lines: List<&2, String>) -> List<&2, String>:
  match lines:
    case Nil{}: Nil{}
    case _ <> rest:
      match rest:
        case Nil{}: Nil{}
        case _ <> rest2: rest2

def snap_body_lines(+lines: List<&2, String>) -> List<&2, String>:
  List.reverse(&2, String, snap_drop2(List.reverse(&2, String, lines)))

def snap_join_body(+lines: List<&2, String>) -> String:
  match lines:
    case Nil{}: ""
    case _ <> _: join_str(lines, "\n") ++ "\n"

def snap_mac_msg_of(+lines: List<&2, String>, +seq_s: String, +count_s: String) -> String:
  snap_join_body(snap_body_lines(lines)) ++ "SEQ" ++ s_tab() ++ seq_s ++ s_tab() ++ count_s

def snap_hmac_prev_cmp(ok: Bool) -> IO(Bool):
  match ok:
    case True{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: NOTICE snapshot trailer verified under MEDIUM_SNAPSHOT_HMAC_KEY_PREV (rotation in progress; re-sign with the new key on the next snapshot cycle)\n")
        IO.pure(Bool, False{})
    case False{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: FATAL snapshot trailer HMAC mismatch under both MEDIUM_SNAPSHOT_HMAC_KEY and MEDIUM_SNAPSHOT_HMAC_KEY_PREV (possible forgery); refusing to boot\n")
        IO.pure(Bool, True{})

def snap_hmac_try_prev(prev_empty: Bool, +lines: List<&2, String>, +seq_s: String, +count_s: String, +mac_s: String, +prev: String) -> IO(Bool):
  match prev_empty:
    case True{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: FATAL snapshot trailer HMAC mismatch (possible forgery or wrong MEDIUM_SNAPSHOT_HMAC_KEY); refusing to boot\n")
        IO.pure(Bool, True{})
    case False{}:
      do IO<Bool>:
        pmac : String <- FS.hmac_sha256_hex(prev, snap_mac_msg_of(lines, seq_s, count_s))
        snap_hmac_prev_cmp(String.eq(pmac, mac_s))

def snap_hmac_mac_cmp(ok: Bool, +lines: List<&2, String>, +seq_s: String, +count_s: String, +mac_s: String, +prev: String) -> IO(Bool):
  match ok:
    case True{}: IO.pure(Bool, False{})
    case False{}: snap_hmac_try_prev(String.is_empty(prev), lines, seq_s, count_s, mac_s, prev)

def snap_hmac_verify_mac_go(no_key: Bool, +lines: List<&2, String>, +seq_s: String, +count_s: String, +mac_s: String, +key: String, +prev: String) -> IO(Bool):
  match no_key:
    case True{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: WARNING snapshot trailer carries a MAC but MEDIUM_SNAPSHOT_HMAC_KEY is not set; cannot verify (count binding only)\n")
        IO.pure(Bool, False{})
    case False{}:
      do IO<Bool>:
        mac : String <- FS.hmac_sha256_hex(key, snap_mac_msg_of(lines, seq_s, count_s))
        snap_hmac_mac_cmp(String.eq(mac, mac_s), lines, seq_s, count_s, mac_s, prev)

def snap_hmac_verify_mac(+lines: List<&2, String>, +seq_s: String, +count_s: String, +mac_s: String, +key: String, +prev: String) -> IO(Bool):
  snap_hmac_verify_mac_go(String.is_empty(key), lines, seq_s, count_s, mac_s, key, prev)

def snap_hmac_nomac_key_set(+allow_legacy: Bool, +desc: String) -> IO(Bool):
  match allow_legacy:
    case True{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: WARNING " ++ desc ++ " but MEDIUM_SNAPSHOT_HMAC_KEY is set; accepted via MEDIUM_SNAPSHOT_HMAC_ALLOW_LEGACY=1, will re-sign on next snapshot cycle\n")
        IO.pure(Bool, False{})
    case False{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: FATAL " ++ desc ++ " but MEDIUM_SNAPSHOT_HMAC_KEY is set (downgrade shape); refusing to boot (set MEDIUM_SNAPSHOT_HMAC_ALLOW_LEGACY=1 for one boot to migrate)\n")
        IO.pure(Bool, True{})

def snap_hmac_nomac_bad_go(no_key: Bool, +allow_legacy: Bool, +desc: String) -> IO(Bool):
  match no_key:
    case True{}: IO.pure(Bool, False{})
    case False{}: snap_hmac_nomac_key_set(allow_legacy, desc)

def snap_hmac_nomac_bad(+key: String, +allow_legacy: Bool, +desc: String) -> IO(Bool):
  snap_hmac_nomac_bad_go(String.is_empty(key), allow_legacy, desc)

def snap_hmac_after_mac(+rest3: List<&2, String>, +seq_s: String, +count_s: String, +mac_s: String, +lines: List<&2, String>, +key: String, +prev: String) -> IO(Bool):
  match rest3:
    case Nil{}: snap_hmac_verify_mac(lines, seq_s, count_s, mac_s, key, prev)
    case _ <> _:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: FATAL snapshot trailer has more than 4 fields (malformed); refusing to boot\n")
        IO.pure(Bool, True{})

def snap_hmac_after_count(+rest2: List<&2, String>, +seq_s: String, +count_s: String, +lines: List<&2, String>, +key: String, +prev: String, +allow_legacy: Bool) -> IO(Bool):
  match rest2:
    case Nil{}:
      snap_hmac_nomac_bad(key, allow_legacy, "snapshot trailer without MAC (item-189 format)")
    case mac_s <> rest3: snap_hmac_after_mac(rest3, seq_s, count_s, mac_s, lines, key, prev)

def snap_hmac_after_seq(+rest: List<&2, String>, +seq_s: String, +lines: List<&2, String>, +key: String, +prev: String, +allow_legacy: Bool) -> IO(Bool):
  match rest:
    case Nil{}:
      snap_hmac_nomac_bad(key, allow_legacy, "legacy snapshot trailer (pre item-189, no count/MAC)")
    case count_s <> rest2: snap_hmac_after_count(rest2, seq_s, count_s, lines, key, prev, allow_legacy)

def snap_hmac_fields_bad(+fields: List<&2, String>, +lines: List<&2, String>, +key: String, +prev: String, +allow_legacy: Bool) -> IO(Bool):
  match fields:
    case Nil{}: IO.pure(Bool, False{})
    case seq_s <> rest: snap_hmac_after_seq(rest, seq_s, lines, key, prev, allow_legacy)

def snap_file_hmac_bad_go(ok: Bool, +lines: List<&2, String>, +key: String, +prev: String, +allow_legacy: Bool) -> IO(Bool):
  match ok:
    case False{}: IO.pure(Bool, False{})
    case True{}: snap_hmac_fields_bad(snap_trailer_fields(lines), lines, key, prev, allow_legacy)

# Item 197: IO verdict for one snapshot file's trailer. True = HMAC-tampered
# (boot must refuse). Prints the specific diagnostic; the generic boot
# FATAL fires downstream via the tampered flag. Files without a valid
# trailer are not our concern here (torn writes keep the item-182 cover
# behavior; they are not tamper evidence).
def snap_file_hmac_bad(+lines: List<&2, String>, +key: String, +prev: String, +allow_legacy: Bool) -> IO(Bool):
  snap_file_hmac_bad_go(snap_lines_ok(lines), lines, key, prev, allow_legacy)

def snap_hmac_boot_bad(+mlines: List<&2, String>, +tlines: List<&2, String>, +key: String, +prev: String, +allow_legacy: Bool) -> IO(Bool):
  do IO<Bool>:
    b1 : Bool <- snap_file_hmac_bad(mlines, key, prev, allow_legacy)
    b2 : Bool <- snap_file_hmac_bad(tlines, key, prev, allow_legacy)
    IO.pure(Bool, Bool.or(b1, b2))

def snap_combine_bad(res: List<&2, String> & Bool, +hmac_bad: Bool) -> List<&2, String> & Bool:
  match res:
    case (lines, bad): (lines, Bool.or(bad, hmac_bad))

# Item 197: once-per-boot loud warning when the HMAC key is unset. The
# degraded mode is exactly the shipped item-189 posture (count binding
# only); the warning makes the posture explicit instead of silent.
def snap_hmac_boot_warn_go(no_key: Bool) -> IO(Unit):
  match no_key:
    case True{}: IO.print("medium-fresh: WARNING MEDIUM_SNAPSHOT_HMAC_KEY is not set — snapshot trailer HMAC signing/verification DISABLED (count binding only)\n")
    case False{}: IO.pure(Unit, Unit{})

def snap_hmac_boot_warn(+key: String) -> IO(Unit):
  snap_hmac_boot_warn_go(String.is_empty(key))

# snapshot_boot_load: read main+tmp, split each ONCE, pick the valid one,
# and report the tamper flag (item-189 count binding OR item-197 HMAC).
# Replaces the snapshot_load + snapshot_boot_check pair (which re-read and
# re-split everything).
def snapshot_boot_load() -> IO(List<&2, String> & Bool):
  do IO<List<&2, String> & Bool>:
    +main : String <- snap_read_path("bocht.snapshot")
    +tmp : String <- snap_read_path("bocht.snapshot.tmp")
    +mlines : List<&2, String> = split_char(main, ch_lf())
    +tlines : List<&2, String> = split_char(tmp, ch_lf())
    +key : String <- snap_hmac_key()
    +prev : String <- snap_hmac_key_prev()
    +allow_legacy : Bool <- snap_hmac_allow_legacy()
    _w : Unit <- snap_hmac_boot_warn(key)
    +hmac_bad : Bool <- snap_hmac_boot_bad(mlines, tlines, key, prev, allow_legacy)
    IO.pure(List<&2, String> & Bool, snap_combine_bad(snap_lines_pick(mlines, tlines), hmac_bad))

# --- segmented-WAL boot, replay, archive, purge (Round 3 item 14) ---
# Block B: uses snap_read_path/snap_trailer_ok (defined above).

def wal_segnums_add(mn: Maybe<&1, Nat>, +acc: List<&2, Nat>) -> List<&2, Nat>:
  match mn:
    case None{}: acc
    case Some{n}: n <> acc

def wal_segnums_go(+names: List<&2, String>, +acc: List<&2, Nat>) -> List<&2, Nat>:
  match names:
    case Nil{}: acc
    case h <> t: wal_segnums_go(t, wal_segnums_add(wal_segnum_name(h), acc))

def wal_segnums_dir(+dir: String) -> IO(List<&2, Nat>):
  do IO<List<&2, Nat>>:
    listing : String <- FS.list_dir(dir)
    IO.pure(List<&2, Nat>, wal_segnums_go(split_char(listing, ch_lf()), Nil{}))

# --- torn-tail amputation at boot (Round 3 item 145 fix) ---
# wal_drop_torn drops a torn trailing record from the REPLAYED TEXT ONLY; the
# torn bytes stay in the segment file. The next wal_write then GLUES its
# complete line onto the torn bytes (append mode, no truncation, no tail
# check): the glued line parses as a record under the torn key (garbage
# value, seq still advanced) or is dropped for a garbage opcode, and a crash
# before the next snapshot loses the 201-acked write for good (item 145:
# 201-acked article -> 404, 201-acked key -> 401 after the second crash).
# Amputate once per boot, after replay and before any wal_write (including
# the purge preservation write): if the max-numbered active segment is
# non-empty and its last byte is not "\n", rewrite it keeping only bytes
# through the last "\n" via tmp + atomic FS.rename_seg, so every later append
# starts on a clean line boundary. The torn bytes contributed nothing to
# replayed state, so the rewrite is state-preserving. Fail-open: any IO error
# leaves the file untouched (the old drop_torn replay behavior still protects
# replay) and is logged loudly. Returns True when the tail is clean or was
# successfully amputated.

def wal_torn_kept_tail(+t: List<&2, String>) -> String:
  match t:
    case Nil{}: ""
    case _ <> _: join_str(List.reverse(&2, String, t), "\n") ++ "\n"

def wal_torn_kept_rev(+rev: List<&2, String>) -> String:
  match rev:
    case Nil{}: ""
    case _h <> t: wal_torn_kept_tail(t)

def wal_torn_kept(+parts: List<&2, String>) -> String:
  wal_torn_kept_rev(List.reverse(&2, String, parts))

def wal_tail_torn_byte(+bs: List<&2, U32>) -> Bool:
  match bs:
    case Nil{}: False{}
    case b <> _t: Bool.not(U32.is_eq(b, (10 : U32)))

def wal_amputate_tail_rr(rr: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(Bool):
  (f2, res) = rr
  match res:
    case Fail{e}:
      do IO<Bool>:
        _c : Unit <- File.close(f2)
        IO.pure(Bool, False{})
    case Done{+bs}:
      do IO<Bool>:
        _c : Unit <- File.close(f2)
        IO.pure(Bool, wal_tail_torn_byte(bs))

def wal_amputate_tail_go(is_empty: Bool, f: File, +sz: U32) -> IO(Bool):
  match is_empty:
    case True{}:
      do IO<Bool>:
        _c : Unit <- File.close(f)
        IO.pure(Bool, True{})
    case False{}:
      do IO<Bool>:
        +off : U32 = U32.sub(sz, (1 : U32))
        tr : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_at(f, off, (1 : U32))
        wal_amputate_tail_rr(tr)

def wal_amputate_sized(rr: File & Result<&1, &1, U32 & String, U32>) -> IO(Bool):
  (f2, res) = rr
  match res:
    case Fail{e}:
      do IO<Bool>:
        _c : Unit <- File.close(f2)
        IO.pure(Bool, False{})
    case Done{+sz}:
      wal_amputate_tail_go(U32.is_eq(sz, (0 : U32)), f2, sz)

def wal_amputate_open(r: Result<&1, &1, U32 & String, File>) -> IO(Bool):
  match r:
    case Fail{e}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: WAL torn-tail check: cannot open segment, leaving untouched\n")
        IO.pure(Bool, False{})
    case Done{f}:
      do IO<Bool>:
        sr : File & Result<&1, &1, U32 & String, U32> <- File.size(f)
        wal_amputate_sized(sr)

def wal_amputate_tail_torn(+path: String) -> IO(Bool):
  do IO<Bool>:
    r : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    wal_amputate_open(r)

def wal_amputate_rename_logged(ok: Bool, +path: String) -> IO(Bool):
  match ok:
    case False{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: WAL torn-tail amputation: rename FAILED, leaving segment untouched\n")
        IO.pure(Bool, False{})
    case True{}:
      do IO<Bool>:
        _a : U32 <- FS.sync_dir(wal_active_dir())
        _u : Unit <- IO.print("medium-fresh: WAL torn-tail amputation: amputated torn tail of " ++ path ++ "\n")
        IO.pure(Bool, True{})

def wal_amputate_rename_done(ok: Bool, +path: String, +tmp: String) -> IO(Bool):
  do IO<Bool>:
    _d : U32 <- FS.unlink(tmp)
    wal_amputate_rename_logged(ok, path)

def wal_amputate_renamed(ok: Bool, +path: String, +tmp: String) -> IO(Bool):
  match ok:
    case False{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: WAL torn-tail amputation: tmp write FAILED, leaving segment untouched\n")
        IO.pure(Bool, False{})
    case True{}:
      do IO<Bool>:
        r : U32 <- FS.rename_seg(tmp, path)
        wal_amputate_rename_done(u32_ok(r), path, tmp)

def wal_amputate_rewrite(+path: String, +content: String) -> IO(Bool):
  +kept : String = wal_torn_kept(split_char(content, ch_lf()))
  +tmp : String = path ++ ".amputmp"
  do IO<Bool>:
    ok : Bool <- snap_write_path(tmp, kept)
    wal_amputate_renamed(ok, path, tmp)

def wal_amputate_decide(torn: Bool, +path: String) -> IO(Bool):
  match torn:
    case False{}: IO.pure(Bool, True{})
    case True{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: WAL torn-tail amputation: torn tail detected in " ++ path ++ ", amputating\n")
        content : String <- snap_read_path(path)
        wal_amputate_rewrite(path, content)

def wal_amputate_max(+m: Nat) -> IO(Bool):
  do IO<Bool>:
    torn : Bool <- wal_amputate_tail_torn(wal_seg_path(m))
    wal_amputate_decide(torn, wal_seg_path(m))

def wal_amputate_nums(+nums: List<&2, Nat>) -> IO(Bool):
  match nums:
    case Nil{}: IO.pure(Bool, True{})
    case _ <> _: wal_amputate_max(nats_max(nums))

def wal_amputate_torn_tail() -> IO(Bool):
  do IO<Bool>:
    nums : List<&2, Nat> <- wal_segnums_dir(wal_active_dir())
    wal_amputate_nums(nums)


def wal_dirnums_add(mn: Maybe<&1, Nat>, +acc: List<&2, Nat>) -> List<&2, Nat>:
  match mn:
    case None{}: acc
    case Some{n}: n <> acc

def wal_dirnums_go(+names: List<&2, String>, +acc: List<&2, Nat>) -> List<&2, Nat>:
  match names:
    case Nil{}: acc
    case h <> t: wal_dirnums_go(t, wal_dirnums_add(parse_nat_opt(h), acc))

def wal_dirnums(+dir: String) -> IO(List<&2, Nat>):
  do IO<List<&2, Nat>>:
    listing : String <- FS.list_dir(dir)
    IO.pure(List<&2, Nat>, wal_dirnums_go(split_char(listing, ch_lf()), Nil{}))

# Recursive archive-tree walk collecting segment numbers. No tuples, no
# list append: subdirectories recurse inline, numbers cons onto acc.
# Bounded-depth archive scan (wal/archive/YYYY/MM/). The archive layout is
# fixed at two levels, so no general recursive tree walk is needed (Bend
# forbids the mutual recursion a general walk would require). Directory
# listings are filtered by wal_segnums_dir/wal_dirnums, which safely skip
# non-matching names (including the empty trailing entry from split).

def wal_boot_max_months(+ms: List<&2, Nat>, +ydir: String, +best: Nat) -> IO(Nat):
  match ms:
    case Nil{}: IO.pure(Nat, best)
    case m <> t:
      do IO<Nat>:
        nums : List<&2, Nat> <- wal_segnums_dir(ydir ++ "/" ++ wal_zpad2(m))
        wal_boot_max_months(t, ydir, nats_max_ab(best, nats_max(nums)))

def wal_boot_max_year(+y: Nat, +best: Nat) -> IO(Nat):
  do IO<Nat>:
    ms : List<&2, Nat> <- wal_dirnums(wal_archive_dir() ++ "/" ++ wal_zpad4(y))
    wal_boot_max_months(ms, wal_archive_dir() ++ "/" ++ wal_zpad4(y), best)

def wal_boot_max_years(+ys: List<&2, Nat>, +best: Nat) -> IO(Nat):
  match ys:
    case Nil{}: IO.pure(Nat, best)
    case y <> t:
      do IO<Nat>:
        b2 : Nat <- wal_boot_max_year(y, best)
        wal_boot_max_years(t, b2)

def wal_boot_max_arch() -> IO(Nat):
  do IO<Nat>:
    ys : List<&2, Nat> <- wal_dirnums(wal_archive_dir())
    wal_boot_max_years(ys, 0n)

# Archive-nonempty walk (companion to wal_boot_max_arch): the max walk alone
# cannot distinguish "archive empty" (max 0) from "archive holds seg-0"
# (max 0). Both walks are boot-only and the tree is shallow, so the extra
# pass is cheap. Self-recursive (Bend forbids the mutual recursion a
# shared decide-helper would need).

def wal_list_empty(+xs: List<&2, Nat>) -> Bool:
  match xs:
    case Nil{}: True{}
    case _ <> _: False{}

def wal_arch_any_month(+ms: List<&2, Nat>, +ydir: String) -> IO(Bool):
  match ms:
    case Nil{}: IO.pure(Bool, False{})
    case m <> t:
      do IO<Bool>:
        nums : List<&2, Nat> <- wal_segnums_dir(ydir ++ "/" ++ wal_zpad2(m))
        rest : Bool <- wal_arch_any_month(t, ydir)
        IO.pure(Bool, Bool.or(Bool.not(wal_list_empty(nums)), rest))

def wal_arch_any_year(+y: Nat) -> IO(Bool):
  do IO<Bool>:
    ms : List<&2, Nat> <- wal_dirnums(wal_archive_dir() ++ "/" ++ wal_zpad4(y))
    wal_arch_any_month(ms, wal_archive_dir() ++ "/" ++ wal_zpad4(y))

def wal_arch_any_years(+ys: List<&2, Nat>) -> IO(Bool):
  match ys:
    case Nil{}: IO.pure(Bool, False{})
    case y <> t:
      do IO<Bool>:
        one : Bool <- wal_arch_any_year(y)
        rest : Bool <- wal_arch_any_years(t)
        IO.pure(Bool, Bool.or(one, rest))

def wal_archive_nonempty() -> IO(Bool):
  do IO<Bool>:
    ys : List<&2, Nat> <- wal_dirnums(wal_archive_dir())
    wal_arch_any_years(ys)

# --- boot ---

def wal_boot_legacy_done(ok: Bool) -> IO(Bool):
  match ok:
    case False{}: IO.pure(Bool, False{})
    case True{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: imported legacy bocht.wal as wal/active/seg-000000.wal\n")
        IO.pure(Bool, True{})

def wal_boot_legacy_sz(nonempty: Bool) -> IO(Bool):
  match nonempty:
    case False{}: IO.pure(Bool, True{})
    case True{}:
      do IO<Bool>:
        r : U32 <- FS.rename_seg("bocht.wal", wal_seg_path(0n))
        wal_boot_legacy_done(u32_ok(r))

def wal_boot_legacy(empty: Bool) -> IO(Bool):
  match empty:
    case False{}: IO.pure(Bool, True{})
    case True{}:
      do IO<Bool>:
        sz : U32 <- FS.file_size("bocht.wal")
        wal_boot_legacy_sz(u32_ok(sz))

# The counter must exceed every segment number ever assigned. The counter
# file is authoritative when present; when it is missing or unreadable and
# wal/active/ is empty, fall back to archive_max+1 - never archive_max
# (reusing the newest archived number would clash on the next archive and
# confuse replay ranges). When wal/active/ is non-empty its max is the live
# segment being appended to, so the counter stays there.
def wal_boot_fix_empty(arch_nonempty: Bool, +base: Nat, +arch_max: Nat) -> Nat:
  match arch_nonempty:
    case False{}: base
    case True{}: nats_max_ab(base, Nat.add(arch_max, 1n))

def wal_boot_fix(active_empty: Bool, arch_nonempty: Bool, +base: Nat, +arch_max: Nat) -> Nat:
  match active_empty:
    case False{}: base
    case True{}: wal_boot_fix_empty(arch_nonempty, base, arch_max)

def wal_boot_max_act(+act: List<&2, Nat>, +cur: Nat, arch_nonempty: Bool, +arch_max: Nat) -> Nat:
  match act:
    case Nil{}: wal_boot_fix(True{}, arch_nonempty, nats_max_ab(cur, arch_max), arch_max)
    case _ <> _: wal_boot_fix(False{}, arch_nonempty, nats_max_ab(cur, nats_max_ab(nats_max(act), arch_max)), arch_max)

def wal_boot_max(+cur: Nat) -> IO(Nat):
  do IO<Nat>:
    arch : Nat <- wal_boot_max_arch()
    act : List<&2, Nat> <- wal_segnums_dir(wal_active_dir())
    nonempty : Bool <- wal_archive_nonempty()
    IO.pure(Nat, wal_boot_max_act(act, cur, nonempty, arch))

def wal_boot_done(+maxn: Nat) -> IO(Bool):
  do IO<Bool>:
    _s : Bool <- wal_seg_set_current(maxn)
    _d : U32 <- FS.sync_dir(wal_dir())
    _u : Unit <- IO.print("medium-fresh: segmented WAL ready (wal/active/, counter=" ++ Nat.show(maxn) ++ ")\n")
    IO.pure(Bool, True{})

# A wal/ or wal/active/ that cannot be created is fatal: serving without a
# WAL would silently lose every commit, so the service refuses to start.
def wal_boot_mkdir(ok: Bool) -> IO(Bool):
  match ok:
    case False{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: FATAL: cannot create wal/ or wal/active/, refusing to start\n")
        IO.pure(Bool, False{})
    case True{}:
      do IO<Bool>:
        _c : U32 <- FS.sync_dir(wal_dir())
        act : List<&2, Nat> <- wal_segnums_dir(wal_active_dir())
        _l : Bool <- wal_boot_legacy(wal_list_empty(act))
        cur : Nat <- wal_seg_current()
        maxn : Nat <- wal_boot_max(cur)
        wal_boot_done(maxn)

def wal_boot() -> IO(Bool):
  do IO<Bool>:
    a : U32 <- FS.mkdir_p(wal_dir())
    b : U32 <- FS.mkdir_p(wal_active_dir())
    wal_boot_mkdir(Bool.and(u32_ok(a), u32_ok(b)))

# --- replay: active segments in numeric order; archive only as fallback ---
# On a valid snapshot only wal/active/ replays (archived segments are
# covered by the snapshot). On a corrupt/missing snapshot the archive
# replays first in (year, month, segnum) order, then wal/active/.

# Replay reads exactly the segments the directory listing enumerates, in
# ascending numeric order. Gaps are harmless (a missing name simply has no
# file). This never ranges over min..max: a hostile seg-999999.wal cannot
# turn boot replay into a million-file scan.
def wal_concat_segs_each(+nums: List<&2, Nat>, +dir: String, +acc: String) -> IO(String):
  match nums:
    case Nil{}: IO.pure(String, acc)
    case n <> t:
      do IO<String>:
        c : String <- snap_read_path(dir ++ "/" ++ wal_seg_name(n))
        # Item 146 fix: strip a torn tail from EVERY segment before
        # concatenating. The old `acc ++ c` glued a non-final segment's torn
        # tail onto the next segment's first line, destroying a
        # 201-acknowledged record at replay (and the phantom record the glue
        # created was then persisted into snapshots). Every wal_write entry
        # ends with \n, so bytes after the last \n are always a torn partial
        # write, never a valid record. This covers active and archived
        # segments (both flow through here) and all opcodes. The item-145
        # max-segment physical amputation is kept: it prevents the distinct
        # append-glue bug, which a read-time strip cannot address.
        wal_concat_segs_each(t, dir, acc ++ wal_torn_kept(split_char(c, ch_lf())))

def wal_concat_segs_go(is_empty: Bool, +nums: List<&2, Nat>, +dir: String) -> IO(String):
  match is_empty:
    case True{}: IO.pure(String, "")
    case False{}: wal_concat_segs_each(nats_sort(nums), dir, "")

def wal_concat_active_go(+nums: List<&2, Nat>) -> IO(String):
  wal_concat_segs_go(wal_list_empty(nums), nums, wal_active_dir())

def wal_concat_active() -> IO(String):
  do IO<String>:
    nums : List<&2, Nat> <- wal_segnums_dir(wal_active_dir())
    wal_concat_active_go(nums)

def wal_concat_month_go(+nums: List<&2, Nat>, +y: Nat, +m: Nat) -> IO(String):
  wal_concat_segs_go(wal_list_empty(nums), nums, wal_archive_dir() ++ "/" ++ wal_zpad4(y) ++ "/" ++ wal_zpad2(m))

def wal_concat_month(+y: Nat, +m: Nat) -> IO(String):
  do IO<String>:
    nums : List<&2, Nat> <- wal_segnums_dir(wal_archive_dir() ++ "/" ++ wal_zpad4(y) ++ "/" ++ wal_zpad2(m))
    wal_concat_month_go(nums, y, m)

def wal_concat_months_n(+n: Nat, +y: Nat, +m: Nat, +acc: String) -> IO(String):
  match n:
    case 0n: IO.pure(String, acc)
    case 1n+p:
      do IO<String>:
        c : String <- wal_concat_month(y, m)
        wal_concat_months_n(p, y, Nat.add(m, 1n), acc ++ c)

def wal_concat_year(+y: Nat) -> IO(String):
  wal_concat_months_n(12n, y, 1n, "")

# Archive years iterate the enumerated year directories (sorted ascending),
# never a min..max range: a bogus 9999/ directory cannot force thousands of
# empty year scans at boot.
def wal_concat_years_each(+ys: List<&2, Nat>, +acc: String) -> IO(String):
  match ys:
    case Nil{}: IO.pure(String, acc)
    case y <> t:
      do IO<String>:
        c : String <- wal_concat_year(y)
        wal_concat_years_each(t, acc ++ c)

def wal_concat_archive_go(is_empty: Bool, +ys: List<&2, Nat>) -> IO(String):
  match is_empty:
    case True{}: IO.pure(String, "")
    case False{}: wal_concat_years_each(nats_sort(ys), "")

def wal_concat_archive_go2(+ys: List<&2, Nat>) -> IO(String):
  wal_concat_archive_go(wal_list_empty(ys), ys)

def wal_concat_archive() -> IO(String):
  do IO<String>:
    ys : List<&2, Nat> <- wal_dirnums(wal_archive_dir())
    wal_concat_archive_go2(ys)

def wal_read_all(snap_ok: Bool) -> IO(String):
  match snap_ok:
    case True{}: wal_concat_active()
    case False{}:
      do IO<String>:
        arch : String <- wal_concat_archive()
        act : String <- wal_concat_active()
        IO.pure(String, arch ++ act)

# --- archive: move covered segments after a verified snapshot ---
# Civil date via Howard Hinnant's days-to-civil algorithm (branch-free;
# large constants built arithmetically - see wal_seg_cap_default note).

def wal_c_1000() -> Nat:
  Nat.mul(10n, Nat.mul(10n, 10n))

def wal_c_719468() -> Nat:
  Nat.add(Nat.mul(719n, wal_c_1000()), 468n)

def wal_c_146097() -> Nat:
  Nat.add(Nat.mul(146n, wal_c_1000()), 97n)

def wal_c_146096() -> Nat:
  Nat.add(Nat.mul(146n, wal_c_1000()), 96n)

def wal_c_36524() -> Nat:
  Nat.add(Nat.mul(36n, wal_c_1000()), 524n)

def wal_pick_m(is_lt10: Bool, +mp: Nat) -> Nat:
  match is_lt10:
    case True{}: Nat.add(mp, 3n)
    case False{}: Nat.sub(mp, 9n)

def wal_pick_y2(is_le2: Bool, +y: Nat) -> Nat:
  match is_le2:
    case True{}: Nat.add(y, 1n)
    case False{}: y

# Seconds per day: 86,400.
def wal_c_day_secs() -> Nat:
  Nat.add(Nat.mul(86n, wal_c_1000()), 400n)

def wal_ym_code(+days: Nat) -> Nat:
  +z : Nat = Nat.add(days, wal_c_719468())
  +era : Nat = Nat.div(z, wal_c_146097())
  +doe : Nat = Nat.sub(z, Nat.mul(era, wal_c_146097()))
  +yoe : Nat = Nat.div(Nat.sub(Nat.add(Nat.sub(doe, Nat.div(doe, 1460n)), Nat.div(doe, wal_c_36524())), Nat.div(doe, wal_c_146096())), 365n)
  +y : Nat = Nat.add(yoe, Nat.mul(era, 400n))
  +doy : Nat = Nat.sub(doe, Nat.sub(Nat.add(Nat.mul(365n, yoe), Nat.div(yoe, 4n)), Nat.div(yoe, 100n)))
  +mp : Nat = Nat.div(Nat.add(Nat.mul(5n, doy), 2n), 153n)
  +m : Nat = wal_pick_m(Nat.is_lt(mp, 10n), mp)
  +y2 : Nat = wal_pick_y2(Nat.is_le(m, 2n), y)
  Nat.add(Nat.mul(y2, 100n), m)

def wal_ym_path(+ym: Nat) -> String:
  wal_zpad4(Nat.div(ym, 100n)) ++ "/" ++ wal_zpad2(Nat.mod(ym, 100n))

# Wall-clock epoch seconds via native effect. (IO.now() is monotonic/uptime,
# not wall-clock, so it cannot be used for archive dating or purge ages.)
def wal_now_sec() -> IO(Nat):
  do IO<Nat>:
    t : U32 <- FS.now_sec()
    IO.pure(Nat, U32.to_nat(t))

def wal_yyyymm(+now_sec: Nat) -> String:
  wal_ym_path(wal_ym_code(Nat.div(now_sec, wal_c_day_secs())))

def wal_num_member_go(+n: Nat, +nums: List<&2, Nat>) -> Bool:
  match nums:
    case Nil{}: False{}
    case h <> t: Bool.or(Nat.is_eq(n, h), wal_num_member_go(n, t))

def wal_any_member(+xs: List<&2, Nat>, +ys: List<&2, Nat>) -> Bool:
  match xs:
    case Nil{}: False{}
    case h <> t: Bool.or(wal_num_member_go(h, ys), wal_any_member(t, ys))

def wal_archive_clash(+dest: String, +nums: List<&2, Nat>) -> IO(Bool):
  do IO<Bool>:
    existing : List<&2, Nat> <- wal_segnums_dir(dest)
    IO.pure(Bool, wal_any_member(nums, existing))

def wal_archive_bump(ok: Bool, +moved: Nat) -> Nat:
  match ok:
    case True{}: Nat.add(moved, 1n)
    case False{}: moved

# A failed rename is only a moved-count shortfall in wal_archive_go, so log it
# loudly here: the segment stays active and retries after the next snapshot.
def wal_archive_one_logged(ok: Bool, +n: Nat) -> IO(Bool):
  match ok:
    case True{}: IO.pure(Bool, True{})
    case False{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: WAL archive WARNING: rename failed for " ++ wal_seg_name(n) ++ "; segment stays active and will retry after next snapshot\n")
        IO.pure(Bool, False{})

def wal_archive_one(+n: Nat, +dest: String) -> IO(Bool):
  do IO<Bool>:
    r : U32 <- FS.rename_seg(wal_seg_path(n), dest ++ "/" ++ wal_seg_name(n))
    wal_archive_one_logged(u32_ok(r), n)

def wal_archive_go(+nums: List<&2, Nat>, +dest: String, +moved: Nat) -> IO(Nat):
  match nums:
    case Nil{}:
      do IO<Nat>:
        _a : U32 <- FS.sync_dir(dest)
        _b : U32 <- FS.sync_dir(wal_active_dir())
        IO.pure(Nat, moved)
    case n <> t:
      do IO<Nat>:
        ok : Bool <- wal_archive_one(n, dest)
        wal_archive_go(t, dest, wal_archive_bump(ok, moved))

def wal_archive_checked(ok: Bool, +nums: List<&2, Nat>, +dest: String) -> IO(Nat):
  match ok:
    case False{}:
      do IO<Nat>:
        _u : Unit <- IO.print("medium-fresh: WAL archive deferred (setup failed); will retry after next snapshot\n")
        IO.pure(Nat, 0n)
    case True{}: wal_archive_go(nums, dest, 0n)

# The clash is checked BEFORE the counter bump: a deferred archive must not
# advance the counter (the bump is only meaningful when the moves that
# follow will actually happen). Returns False on clash (defer) or a failed
# bump.
def wal_archive_bump_go(clash: Bool, +nums: List<&2, Nat>) -> IO(Bool):
  match clash:
    case True{}: IO.pure(Bool, False{})
    case False{}: wal_seg_set_current(Nat.add(nats_max(nums), 1n))

def wal_archive_precheck(+ym: String, +nums: List<&2, Nat>) -> IO(Bool):
  do IO<Bool>:
    mk : U32 <- FS.mkdir_p(wal_archive_dir() ++ "/" ++ ym)
    _sd : U32 <- FS.sync_dir(wal_archive_dir() ++ "/" ++ ym)
    _sp : U32 <- FS.sync_dir(wal_archive_dir())
    clash : Bool <- wal_archive_clash(wal_archive_dir() ++ "/" ++ ym, nums)
    bump : Bool <- wal_archive_bump_go(clash, nums)
    IO.pure(Bool, Bool.and(u32_ok(mk), bump))

def wal_archive_nums(+nums: List<&2, Nat>, +ym: String) -> IO(Nat):
  match nums:
    case Nil{}: IO.pure(Nat, 0n)
    case _ <> _:
      do IO<Nat>:
        ok : Bool <- wal_archive_precheck(ym, nums)
        wal_archive_checked(ok, nums, wal_archive_dir() ++ "/" ++ ym)

def wal_archive_covered(+now_sec: Nat) -> IO(Nat):
  do IO<Nat>:
    nums : List<&2, Nat> <- wal_segnums_dir(wal_active_dir())
    wal_archive_nums(nums, wal_yyyymm(now_sec))

# --- purge: delete archived segments older than the retention window ---
# Runs at boot: dry-run first (logged), then for real (logged). With the
# 10000-day default retention both remove nothing.

def wal_purge_retention_num(mn: Maybe<&1, Nat>) -> Nat:
  match mn:
    case None{}: wal_purge_retention_days_default()
    case Some{n}: n

def wal_purge_retention_env(mr: Result<&1, &1, U32 & String, String>) -> Nat:
  match mr:
    case Fail{e}: wal_purge_retention_days_default()
    case Done{+s}: wal_purge_retention_num(parse_nat_opt(s))

def wal_purge_retention_days() -> IO(Nat):
  do IO<Nat>:
    mr : Result<&1, &1, U32 & String, String> <- IO.get_env("MEDIUM_WAL_PURGE_DAYS")
    IO.pure(Nat, wal_purge_retention_env(mr))

def wal_purge_old2(in_past: Bool, +age_s: Nat, +days: Nat) -> Bool:
  match in_past:
    case False{}: False{}
    case True{}: Bool.not(Nat.is_le(Nat.div(age_s, wal_c_day_secs()), days))

def wal_purge_old(+mt_s: Nat, +now_s: Nat, +days: Nat) -> Bool:
  wal_purge_old2(Nat.is_le(mt_s, now_s), Nat.sub(now_s, mt_s), days)


def wal_purge_unlink2(+dry: Bool, +full: String) -> IO(Bool):
  match dry:
    case True{}: IO.pure(Bool, True{})
    case False{}:
      do IO<Bool>:
        ok : U32 <- FS.unlink(full)
        # FS.unlink returns 1 on success (ENOENT counts as success: the
        # purge is idempotent), 0 on failure. Report honestly so the
        # "removed N" log count is real (Round 3 item 144 fix: it used to
        # report True unconditionally).
        IO.pure(Bool, Nat.is_eq(U32.to_nat(ok), 1n))

def wal_purge_unlink(do_it: Bool, +dry: Bool, +full: String) -> IO(Bool):
  match do_it:
    case False{}: IO.pure(Bool, False{})
    case True{}: wal_purge_unlink2(dry, full)

def wal_del_bump(gone: Bool, +deleted: Nat) -> Nat:
  match gone:
    case True{}: Nat.add(deleted, 1n)
    case False{}: deleted

def wal_purge_one(+full: String, +now_s: Nat, +days: Nat, +dry: Bool) -> IO(Bool):
  do IO<Bool>:
    mt : U32 <- FS.file_mtime(full)
    wal_purge_unlink(wal_purge_old(U32.to_nat(mt), now_s, days), dry, full)

def wal_purge_nums(+nums: List<&2, Nat>, +d: String, +now_s: Nat, +days: Nat, +dry: Bool, +deleted: Nat) -> IO(Nat):
  match nums:
    case Nil{}: IO.pure(Nat, deleted)
    case n <> t:
      do IO<Nat>:
        gone : Bool <- wal_purge_one(d ++ "/" ++ wal_seg_name(n), now_s, days, dry)
        wal_purge_nums(t, d, now_s, days, dry, wal_del_bump(gone, deleted))

def wal_purge_month(+y: Nat, +m: Nat, +now_s: Nat, +days: Nat, +dry: Bool, +deleted: Nat) -> IO(Nat):
  do IO<Nat>:
    nums : List<&2, Nat> <- wal_segnums_dir(wal_archive_dir() ++ "/" ++ wal_zpad4(y) ++ "/" ++ wal_zpad2(m))
    wal_purge_nums(nums, wal_archive_dir() ++ "/" ++ wal_zpad4(y) ++ "/" ++ wal_zpad2(m), now_s, days, dry, deleted)

def wal_purge_months(+ms: List<&2, Nat>, +y: Nat, +now_s: Nat, +days: Nat, +dry: Bool, +deleted: Nat) -> IO(Nat):
  match ms:
    case Nil{}: IO.pure(Nat, deleted)
    case m <> t:
      do IO<Nat>:
        d2 : Nat <- wal_purge_month(y, m, now_s, days, dry, deleted)
        wal_purge_months(t, y, now_s, days, dry, d2)

def wal_purge_year(+y: Nat, +now_s: Nat, +days: Nat, +dry: Bool, +deleted: Nat) -> IO(Nat):
  do IO<Nat>:
    ms : List<&2, Nat> <- wal_dirnums(wal_archive_dir() ++ "/" ++ wal_zpad4(y))
    wal_purge_months(ms, y, now_s, days, dry, deleted)

def wal_purge_years(+ys: List<&2, Nat>, +now_s: Nat, +days: Nat, +dry: Bool, +deleted: Nat) -> IO(Nat):
  match ys:
    case Nil{}: IO.pure(Nat, deleted)
    case y <> t:
      do IO<Nat>:
        d2 : Nat <- wal_purge_year(y, now_s, days, dry, deleted)
        wal_purge_years(t, now_s, days, dry, d2)

def wal_purge_days(+days: Nat, +dry: Bool) -> IO(Nat):
  do IO<Nat>:
    now_sec : Nat <- wal_now_sec()
    ys : List<&2, Nat> <- wal_dirnums(wal_archive_dir())
    wal_purge_years(ys, now_sec, days, dry, 0n)

def wal_purge_dry() -> IO(Nat):
  do IO<Nat>:
    days : Nat <- wal_purge_retention_days()
    wal_purge_days(days, True{})

def wal_purge() -> IO(Nat):
  do IO<Nat>:
    days : Nat <- wal_purge_retention_days()
    wal_purge_days(days, False{})

def wal_snap_ok(+snap: String) -> Bool:
  snap_trailer_ok(snap)

# --- purge key preservation (Round 3 item 144 fix) ---
# The purge deletes archived segments whose records may be the ONLY WAL
# copy of key records: the bootstrap admin key is written once at
# bootstrap and never re-recorded (unless rotated), so it always sits in
# the oldest archived segment — the first purge victim. The purge gate
# ("a valid snapshot exists") only proves the snapshot covers those
# records NOW; if that snapshot is later lost or corrupted (the exact
# scenario the snapshot+WAL dual exists to survive — cf. the defensive
# boot guard, items 137/138/143), the purged keys are unrecoverable.
# Demonstrated live: after a purge deleted the admin KEY record, a
# snapshot corruption left the admin credential permanently at 401, with
# ~1000 articles unrecoverable the same way.
# Fix: when the dry-run finds >=1 segment to delete, first re-append every
# LIVE key as a KEY line to the active WAL (fsync'd via wal_write), then
# delete. Replay is idempotent and last-write-wins per key, and the
# forwarded records ARE the live state, so appending them after all
# retained segments is correct. Revoked keys are absent from the live map,
# so nothing is resurrected. Data (article) records keep snapshot-coverage
# semantics: purged-then-snapshot-lost data is unrecoverable, and since
# item 182 (r55) the boot gate refuses loudly (FATAL) in that case rather
# than serving silently incomplete data. With the default 10000-day
# retention the dry-run is always 0 and this is a complete no-op.
def wal_purge_preserve_blob(+kvs: List<&2, Sigma<&2, &2, String, _ => Auth>>) -> String:
  match kvs:
    case Nil{}: ""
    case h <> t:
      (k, +a) = h
      "KEY" ++ s_tab() ++ apikey_serialize(a) ++ "\n" ++ wal_purge_preserve_blob(t)

def wal_purge_preserve_logged(ok: Bool, n: Nat) -> IO(Unit):
  match ok:
    case False{}:
      IO.print("medium-fresh: WAL purge: KEY PRESERVATION WRITE FAILED - skipping deletion of archived segments\n")
    case True{}:
      IO.print("medium-fresh: WAL purge: preserved " ++ Nat.show(n) ++ " live key record(s) in active WAL\n")

# Returns True when the live keys are safely re-anchored in the active WAL
# (or when there is nothing to preserve). The purge MUST NOT delete
# archived segments unless this returns True: if the preservation write
# fails (disk full, IO error), deletion is skipped and the failure is
# logged loudly. Fail-closed: an un-anchored key record must never have
# its last archived copy deleted.
def wal_purge_do_preserve_ok(+keys: Map<&2, Auth>) -> IO(Bool):
  do IO<Bool>:
    +ok : Bool <- wal_write(wal_purge_preserve_blob(Map.to_list(&2, Auth, keys)))
    _u : Unit <- wal_purge_preserve_logged(ok, Map.size(&2, Auth, keys))
    IO.pure(Bool, ok)

def wal_purge_maybe_preserve_ok(has_old: Bool, +keys: Map<&2, Auth>) -> IO(Bool):
  match has_old:
    case False{}: IO.pure(Bool, True{})
    case True{}: wal_purge_do_preserve_ok(keys)

def wal_purge_boot5(+n: Nat) -> IO(Nat):
  do IO<Nat>:
    _v : Unit <- IO.print("medium-fresh: WAL purge: removed " ++ Nat.show(n) ++ " archived segment(s)\n")
    IO.pure(Nat, n)

def wal_purge_log_path() -> String:
  "wal/purge.log"

# --- purge-log compaction (Round 3 item 191) ---
# wal/purge.log is the item-182 durable tombstone: append-only, one
# "PURGED\t<unix_sec>\t<count>\n" line per boot-with-purge. With the
# 10000-day default retention it never grows; once an operator lowers
# retention it grows ~20-25B per purging boot (item 188 C) - a slow,
# operator-driven leak with no cap. This section bounds it WITHOUT
# weakening the item-182 fail-closed boot gate.
#
# Design: in-place COMPACTION, not generation rotation. A generation rename
# (old -> purge.log.1, then write a fresh purge.log) has a crash window in
# which purge.log is absent or empty: the boot gate (wal_purge_log_has_entries)
# would then read "no purge happened" - a false negative that resurrects the
# r53 silent-data-loss bug. Compaction has no such window:
#   write purge.log.compacttmp (fsync) -> atomic rename over purge.log ->
#   fsync dir. The rename is the only destructive step and it happens last.
# Crash analysis:
#   - crash before rename: the original log is intact -> fail-closed preserved
#   - crash after rename: the cumulative line carries the signal forward
# Boot-gate semantics are UNCHANGED: ANY line starting with "PURGED\t"
# (individual or cumulative) is a load-bearing tombstone, so a missing/
# invalid snapshot plus any recorded purge still refuses loudly (FATAL).
# The cumulative count keeps the item-187 probe-level property "tombstone
# counts sum == files deleted" (the sum equals total segments purged ever).
# Audit note: individual purge-event lines folded away by a compaction lose
# their per-event timestamps; only the cumulative total survives. The count
# is monotonic across compactions.
# Compaction is itself fail-closed: on any failure (read/write/rename) the
# original log is untouched (rename is last) and the pending tombstone still
# appends to the original log, so the pending deletion's signal is never lost.
# A log with no PURGED lines at all is never compacted: writing a
# "PURGED\t0" line there would FABRICATE a tombstone (false FATAL later).

def wal_purge_log_max_default() -> Nat:
  65536n

def wal_purge_log_max_num(mn: Maybe<&1, Nat>) -> Nat:
  match mn:
    case None{}: wal_purge_log_max_default()
    case Some{n}: n

def wal_purge_log_max_env(mr: Result<&1, &1, U32 & String, String>) -> Nat:
  match mr:
    case Fail{e}: wal_purge_log_max_default()
    case Done{+s}: wal_purge_log_max_num(parse_nat_opt(s))

def wal_purge_log_max_bytes() -> IO(Nat):
  do IO<Nat>:
    mr : Result<&1, &1, U32 & String, String> <- IO.get_env("MEDIUM_WAL_PURGE_LOG_MAX_BYTES")
    IO.pure(Nat, wal_purge_log_max_env(mr))

def wal_purge_nat_of(mn: Maybe<&1, Nat>) -> Nat:
  match mn:
    case None{}: 0n
    case Some{n}: n

def wal_purge_log_fields_count(+fields: List<&2, String>) -> Nat:
  match fields:
    case Nil{}: 0n
    case _tag <> rest:
      match rest:
        case Nil{}: 0n
        case _ts <> rest2:
          match rest2:
            case Nil{}: 0n
            case cnt <> _: wal_purge_nat_of(parse_nat_opt(cnt))

# The tag check stays at line level (same as wal_purge_log_has_go): only a
# line starting with "PURGED\t" is a tombstone. The field split is only
# for extracting the count; a "PURGEDX\t..." junk line never reaches it.
def wal_purge_log_line_count(+line: String) -> Nat:
  Bool.pick(Nat, String.starts_with(line, "PURGED" ++ s_tab()),
    wal_purge_log_fields_count(split_char(line, ch_tab())), 0n)

def wal_purge_log_fold(+lines: List<&2, String>, +acc: Nat) -> Nat:
  match lines:
    case Nil{}: acc
    case h <> t:
      wal_purge_log_fold(t, Nat.add(acc, wal_purge_log_line_count(h)))

def wal_purge_log_compact_tmp() -> String:
  wal_purge_log_path() ++ ".compacttmp"

def wal_purge_log_compact_done(ok: Bool, +tmp: String) -> IO(Bool):
  match ok:
    case False{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: WAL purge.log compaction: rename FAILED, keeping original log\n")
        _d : U32 <- FS.unlink(tmp)
        IO.pure(Bool, False{})
    case True{}:
      do IO<Bool>:
        _d : U32 <- FS.sync_dir(wal_dir())
        _u : Unit <- IO.print("medium-fresh: WAL purge.log compacted (cumulative tombstone)\n")
        IO.pure(Bool, True{})

def wal_purge_log_compact_promote(ok: Bool, +tmp: String) -> IO(Bool):
  match ok:
    case False{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: WAL purge.log compaction: tmp write FAILED, keeping original log\n")
        IO.pure(Bool, False{})
    case True{}:
      do IO<Bool>:
        r : U32 <- FS.rename_seg(tmp, wal_purge_log_path())
        wal_purge_log_compact_done(u32_ok(r), tmp)

def wal_purge_log_compact_write(skip: Bool, +total: Nat, +now_s: Nat) -> IO(Bool):
  match skip:
    case True{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: WAL purge.log compaction: no tombstones to fold, leaving log untouched\n")
        IO.pure(Bool, True{})
    case False{}:
      do IO<Bool>:
        +line : String = "PURGED" ++ s_tab() ++ Nat.show(now_s) ++ s_tab() ++ Nat.show(total) ++ "\n"
        +tmp : String = wal_purge_log_compact_tmp()
        ok : Bool <- snap_write_path(tmp, line)
        wal_purge_log_compact_promote(ok, tmp)

def wal_purge_log_compact_do() -> IO(Bool):
  do IO<Bool>:
    content : String <- snap_read_path(wal_purge_log_path())
    now_s : Nat <- wal_now_sec()
    +total : Nat = wal_purge_log_fold(split_char(content, ch_lf()), 0n)
    wal_purge_log_compact_write(Nat.is_eq(total, 0n), total, now_s)

def wal_purge_log_compact_decide(big: Bool) -> IO(Bool):
  match big:
    case False{}: IO.pure(Bool, True{})
    case True{}: wal_purge_log_compact_do()

# Missing file -> FS.file_size returns 0 -> below any cap -> no-op.
def wal_purge_log_compact_maybe() -> IO(Bool):
  do IO<Bool>:
    maxb : Nat <- wal_purge_log_max_bytes()
    sz : U32 <- FS.file_size(wal_purge_log_path())
    wal_purge_log_compact_decide(Nat.is_ge(U32.to_nat(sz), maxb))

# --- purge tombstone log (Round 3 item 182, r55) ---
# Every archived-segment deletion performed by the purge is recorded FIRST
# in wal/purge.log (append + fsync; the deletion is skipped if the log
# write fails - fail-closed, same philosophy as the item-144 key
# preservation). A snapshot that is missing/invalid at boot combined with
# ANY recorded purge means retired segments' records are unrecoverable:
# their only other copy was the snapshot. Boot then refuses loudly (FATAL)
# instead of serving silently incomplete data (demonstrated live on r53:
# 498/600 articles vanished with a clean boot and no error).
#
# Why a log and not filename inference: the purge deletes by mtime age,
# which need not be a prefix - manipulated mtimes can make it delete a
# MIDDLE segment while seg-0 remains, and seg-0's presence then proves
# nothing. The log records what the server itself deleted, immune to
# hostile segment filenames (item14 P6b's seg-999999.wal) and to
# non-prefix purges alike. Line format: "PURGED\t<unix_sec>\t<count>\n";
# only the leading "PURGED\t" tag is load-bearing at boot.

def wal_purge_log_append(+line: String) -> IO(Bool):
  do IO<Bool>:
    r : Result<&1, &1, U32 & String, File> <- File.open(wal_purge_log_path(), "a")
    wal_write_open(r, line)

def wal_purge_tombstone_logged(ok: Bool) -> IO(Bool):
  match ok:
    case True{}:
      do IO<Bool>:
        _d : U32 <- FS.sync_dir(wal_dir())
        IO.pure(Bool, True{})
    case False{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: WAL purge: TOMBSTONE WRITE FAILED - skipping deletion of archived segments\n")
        IO.pure(Bool, False{})

def wal_purge_tombstone_go(none: Bool, +dry: Nat) -> IO(Bool):
  match none:
    case True{}: IO.pure(Bool, True{})
    case False{}:
      do IO<Bool>:
        # Round 3 item 191: compact the tombstone log before appending, so it
        # stays bounded. Compaction failure is non-fatal here: the tombstone
        # still appends to the original log (fail-closed; the pending
        # deletion's signal is never lost).
        _c : Bool <- wal_purge_log_compact_maybe()
        now_s : Nat <- wal_now_sec()
        ok : Bool <- wal_purge_log_append("PURGED" ++ s_tab() ++ Nat.show(now_s) ++ s_tab() ++ Nat.show(dry) ++ "\n")
        wal_purge_tombstone_logged(ok)

def wal_purge_tombstone_write(+dry: Nat) -> IO(Bool):
  wal_purge_tombstone_go(Nat.is_eq(dry, 0n), dry)

def wal_purge_delete_after_tombstone(tombstoned: Bool, +days: Nat) -> IO(Nat):
  match tombstoned:
    case False{}: IO.pure(Nat, 0n)
    case True{}:
      do IO<Nat>:
        n : Nat <- wal_purge_days(days, False{})
        wal_purge_boot5(n)

def wal_purge_delete_tombstoned(+days: Nat, +dry: Nat) -> IO(Nat):
  do IO<Nat>:
    tombstoned : Bool <- wal_purge_tombstone_write(dry)
    wal_purge_delete_after_tombstone(tombstoned, days)

def wal_purge_maybe_delete(ok: Bool, +days: Nat, +dry: Nat) -> IO(Nat):
  match ok:
    case False{}: IO.pure(Nat, 0n)
    case True{}: wal_purge_delete_tombstoned(days, dry)

def wal_purge_log_has_go(+lines: List<&2, String>) -> Bool:
  match lines:
    case Nil{}: False{}
    case h <> t: Bool.or(String.starts_with(h, "PURGED" ++ s_tab()), wal_purge_log_has_go(t))

def wal_purge_log_has_entries() -> IO(Bool):
  do IO<Bool>:
    content : String <- snap_read_path(wal_purge_log_path())
    IO.pure(Bool, wal_purge_log_has_go(split_char(content, ch_lf())))

def wal_purge_boot4(+keys: Map<&2, Auth>, +days: Nat, +dry: Nat) -> IO(Nat):
  do IO<Nat>:
    _u : Unit <- IO.print("medium-fresh: WAL purge dry-run: " ++ Nat.show(dry) ++ " archived segment(s) older than " ++ Nat.show(days) ++ " days\n")
    ok : Bool <- wal_purge_maybe_preserve_ok(Bool.not(Nat.is_eq(dry, 0n)), keys)
    n : Nat <- wal_purge_maybe_delete(ok, days, dry)
    wal_purge_boot5(n)

def wal_purge_boot3(+keys: Map<&2, Auth>, +days: Nat) -> IO(Nat):
  do IO<Nat>:
    dry : Nat <- wal_purge_days(days, True{})
    wal_purge_boot4(keys, days, dry)

def wal_purge_boot2(+keys: Map<&2, Auth>) -> IO(Nat):
  do IO<Nat>:
    days : Nat <- wal_purge_retention_days()
    wal_purge_boot3(keys, days)

def wal_purge_boot(+keys: Map<&2, Auth>, snap_ok: Bool) -> IO(Nat):
  match snap_ok:
    case False{}:
      do IO<Nat>:
        _u : Unit <- IO.print("medium-fresh: WAL purge skipped (no valid snapshot)\n")
        IO.pure(Nat, 0n)
    case True{}: wal_purge_boot2(keys)

# --- persistence wiring: replay + snapshotting ---
# Replay order on startup: snapshot first, then WAL (WAL wins; all ops are
# idempotent). Snapshot cycle: save -> verify (content ends with the current
# SEQ line, proving the write completed) -> truncate WAL. The verify step
# makes truncation safe: we never discard the WAL unless the snapshot is
# known-good. Without it, a crash during truncation could lose the WAL tail.

def med_empty() -> MedState:
  MkMed{Map.new(&2, String), Map.new(&2, Auth), 1n, Nil{}, 0n, Nil{}, Map.new(&2, String), 0n, 0n, 0n, False{}, default_restart_rl(), default_key_rl()}

# --- defensive boot guard: snapshot-must-cover-archive (Round 3 item 138) ---
# The valid-snapshot boot path skips the archive on the load-bearing
# invariant that every archived segment is covered by the snapshot: the
# archive runs only after a verified snapshot save, and the single-threaded
# owner makes snapshot+archive atomic w.r.t. writes, so every archived
# record/event seq is <= the snapshot's. If the archive ever holds a NEWER
# seq than the snapshot (unreachable in real operation; producible only by
# out-of-band corruption or tampering with the snapshot files), the snapshot
# does NOT cover the archive and skipping it would silently drop data. The
# guard replays the archive too in that case - and logs loudly - instead of
# skipping it silently.
# The max-seq scan reuses wal_replay itself (torn lines dropped, item-136
# max-defense on st_seq, max-defense on evseq), so "max seq found" is exactly
# what a replay of that text would apply; both the record-id space (st_seq)
# and the event space (st_evseq) are compared, because a violation can hide
# in either. Provably a no-op on legitimate boots: the archive then holds
# only pre-snapshot seqs, so arch_max <= snap_max always and the active-only
# path is taken exactly as before (empty archive -> arch_max 1 <= snap_max).
# A false positive fails safe: the fallback is a superset replay and all
# replay ops are idempotent. Boot-cost note: the guard reads the full
# archive on every valid-snapshot boot (retention-bounded).

def wal_state_max_seq(+st: MedState) -> Nat:
  nats_max_ab(st_seq(st), st_evseq(st))

# --- archive high-water mark (Round 3 item 196) ---
# O(1) replacement for the item-138 guard's archive scan. After a verified
# snapshot, every archived segment holds only seqs <= wal_state_max_seq(st).
# We persist that max in wal/archive/COVERED before moving segments; boot
# compares it to the snapshot trailer seq. If COVERED > snap_seq, the
# snapshot may not cover the archive -> defensive replay of the archive.
# Crash-safe: written BEFORE the moves. A crash after the write but before
# the moves leaves COVERED high with segments still active; the just-written
# snapshot (seq S) then satisfies COVERED <= S unless evseq > S, in which
# case we take a safe false-positive archive replay. COVERED never
# underestimates the archive max (high-water mark), so a missed violation
# is impossible. Missing/unparseable COVERED (pre-fix archives) ->
# conservative: replay the archive rather than skipping it.
# Note: snap_seq_of is the trailer's st_seq, which can understate the true
# snapshot max when evseq > st_seq; understating only causes safe false
# positives, never missed violations.
def wal_covered_path() -> String:
  wal_archive_dir() ++ "/COVERED"

def wal_covered_write_nat(+cv: Nat) -> IO(Bool):
  do IO<Bool>:
    r : Result<&1, &1, U32 & String, File> <- File.open(wal_covered_path(), "w")
    wal_write_open(r, Nat.show(cv) ++ "\n")

def wal_covered_read_head(+parts: List<&2, String>) -> Maybe<&1, Nat>:
  match parts:
    case Nil{}: None{}
    case h <> _t: parse_nat_opt(h)

def wal_covered_read_got(rr: File & Result<&1, &1, U32 & String, String>) -> IO(Maybe<&1, Nat>):
  (f2, res) = rr
  match res:
    case Fail{e}:
      do IO<Maybe<&1, Nat>>:
        _c : Unit <- File.close(f2)
        IO.pure(Maybe<&1, Nat>, None{})
    case Done{content}:
      do IO<Maybe<&1, Nat>>:
        _c : Unit <- File.close(f2)
        IO.pure(Maybe<&1, Nat>, wal_covered_read_head(split_char(content, ch_lf())))

def wal_covered_read_open(r: Result<&1, &1, U32 & String, File>) -> IO(Maybe<&1, Nat>):
  match r:
    case Fail{e}: IO.pure(Maybe<&1, Nat>, None{})
    case Done{f}:
      do IO<Maybe<&1, Nat>>:
        rr : File & Result<&1, &1, U32 & String, String> <- File.read(f, 64)
        wal_covered_read_got(rr)

def wal_covered_read() -> IO(Maybe<&1, Nat>):
  do IO<Maybe<&1, Nat>>:
    r : Result<&1, &1, U32 & String, File> <- File.open(wal_covered_path(), "r")
    wal_covered_read_open(r)

def wal_defend_branch(violated: Bool, +arch_max: Nat, +snap_max: Nat) -> IO(String):
  match violated:
    case False{}: wal_concat_active()
    case True{}:
      do IO<String>:
        _u : Unit <- IO.print("medium-fresh: DEFENSIVE BOOT: archive max seq " ++ Nat.show(arch_max) ++ " exceeds snapshot max seq " ++ Nat.show(snap_max) ++ "; replaying archived segments instead of skipping (snapshot does not cover the archive)\n")
        arch : String <- wal_concat_archive()
        act : String <- wal_concat_active()
        IO.pure(String, arch ++ act)

def wal_defend_covered(mcov: Maybe<&1, Nat>, +snap: String) -> IO(String):
  match mcov:
    case Some{+c}:
      wal_defend_branch(Nat.is_lt(snap_seq_of(snap), c), c, snap_seq_of(snap))
    case None{}:
      do IO<String>:
        _u : Unit <- IO.print("medium-fresh: DEFENSIVE BOOT: no archive high-water mark (pre-fix archive); replaying archived segments conservatively\n")
        arch : String <- wal_concat_archive()
        act : String <- wal_concat_active()
        IO.pure(String, arch ++ act)

def wal_defend_true(+snap: String) -> IO(String):
  do IO<String>:
    mcov : Maybe<&1, Nat> <- wal_covered_read()
    wal_defend_covered(mcov, snap)

def wal_read_all_defended_go(snap_ok: Bool, +snap: String) -> IO(String):
  match snap_ok:
    case False{}: wal_read_all(False{})
    case True{}: wal_defend_true(snap)

def wal_read_all_defended(+snap: String) -> IO(String):
  wal_read_all_defended_go(wal_snap_ok(snap), snap)

def snap_lines_seq_field(+fields: List<&2, String>) -> Nat:
  match fields:
    case Nil{}: 0n
    case seq_s <> _: rl_nat(seq_s)

def snap_lines_seq(+lines: List<&2, String>) -> Nat:
  snap_lines_seq_field(split_char(String.drop(snap_nonempty_last(lines, ""), 4n), ch_tab()))

def wal_defend_covered_lines(mcov: Maybe<&1, Nat>, +lines: List<&2, String>) -> IO(String):
  match mcov:
    case Some{+c}:
      wal_defend_branch(Nat.is_lt(snap_lines_seq(lines), c), c, snap_lines_seq(lines))
    case None{}:
      do IO<String>:
        _u : Unit <- IO.print("medium-fresh: DEFENSIVE BOOT: no archive high-water mark (pre-fix archive); replaying archived segments conservatively\n")
        arch : String <- wal_concat_archive()
        act : String <- wal_concat_active()
        IO.pure(String, arch ++ act)

def wal_read_all_defended_scan(+lines: List<&2, String>) -> IO(String):
  do IO<String>:
    mcov : Maybe<&1, Nat> <- wal_covered_read()
    wal_defend_covered_lines(mcov, lines)

# --- snapshot-loss loud failure (Round 3 item 182; r55 tombstone) ---
# If the snapshot is missing or fails trailer validation, refuse to boot
# when retired WAL data is provably unrecoverable. Two layers:
#
# 1. Purge tombstone (primary): every archived-segment deletion performed
#    by the purge is recorded first in wal/purge.log (append + fsync; the
#    deletion is skipped if the log write fails). ANY recorded purge means
#    retired segments were deleted whose only other copy was the snapshot,
#    so a missing/invalid snapshot makes their records unrecoverable.
#    This is exact - no filename inference - and covers non-prefix purges
#    (mtime manipulation deleting a middle segment while seg-0 remains)
#    as well as the classic oldest-first case. Immune to hostile segment
#    filenames (item14 P6b's seg-999999.wal): planting files never writes
#    the log.
# 2. seg-0 fallback: if the log shows no purge (pre-tombstone data, or the
#    log itself lost out-of-band) but segments exist without seg-0, the
#    oldest retired records are unaccounted for - refuse as well. A fresh
#    server (no segments at all) passes vacuously.
#
# Booting in either case would serve silently incomplete data (demonstrated
# live on r53: 498/600 articles vanished with a clean boot and no error).
# Refuse loudly instead (fail-closed, cf. item 144). Note this supersedes
# the old fail-open "retention trade-off" expectation (items 144/169):
# purge + snapshot loss is provably unrecoverable, so it must not boot.

def wal_list_append_go(+t: List<&2, Nat>, +ys: List<&2, Nat>) -> List<&2, Nat>:
  match t:
    case Nil{}: ys
    case h <> t2: h <> wal_list_append_go(t2, ys)

def wal_list_append(+xs: List<&2, Nat>, +ys: List<&2, Nat>) -> List<&2, Nat>:
  match xs:
    case Nil{}: ys
    case h <> t: h <> wal_list_append_go(t, ys)

def wal_arch_segnums_month(+y: Nat, +m: Nat, +acc: List<&2, Nat>) -> IO(List<&2, Nat>):
  do IO<List<&2, Nat>>:
    nums : List<&2, Nat> <- wal_segnums_dir(wal_archive_dir() ++ "/" ++ wal_zpad4(y) ++ "/" ++ wal_zpad2(m))
    IO.pure(List<&2, Nat>, wal_list_append(acc, nums))

def wal_arch_segnums_months(+ms: List<&2, Nat>, +y: Nat, +acc: List<&2, Nat>) -> IO(List<&2, Nat>):
  match ms:
    case Nil{}: IO.pure(List<&2, Nat>, acc)
    case m <> t:
      do IO<List<&2, Nat>>:
        a2 : List<&2, Nat> <- wal_arch_segnums_month(y, m, acc)
        wal_arch_segnums_months(t, y, a2)

def wal_arch_segnums_year(+y: Nat, +acc: List<&2, Nat>) -> IO(List<&2, Nat>):
  do IO<List<&2, Nat>>:
    ms : List<&2, Nat> <- wal_dirnums(wal_archive_dir() ++ "/" ++ wal_zpad4(y))
    wal_arch_segnums_months(ms, y, acc)

def wal_arch_segnums_years(+ys: List<&2, Nat>, +acc: List<&2, Nat>) -> IO(List<&2, Nat>):
  match ys:
    case Nil{}: IO.pure(List<&2, Nat>, acc)
    case y <> t:
      do IO<List<&2, Nat>>:
        a2 : List<&2, Nat> <- wal_arch_segnums_year(y, acc)
        wal_arch_segnums_years(t, a2)

def wal_all_arch_segnums() -> IO(List<&2, Nat>):
  do IO<List<&2, Nat>>:
    ys : List<&2, Nat> <- wal_dirnums(wal_archive_dir())
    wal_arch_segnums_years(ys, Nil{})

def wal_has_seg0_go(+xs: List<&2, Nat>) -> Bool:
  match xs:
    case Nil{}: False{}
    case h <> t: Bool.or(Nat.is_eq(h, 0n), wal_has_seg0_go(t))

def wal_cover_ok_go(+xs: List<&2, Nat>) -> Bool:
  match xs:
    case Nil{}: True{}
    case _ <> _: wal_has_seg0_go(xs)

# A recorded purge with a missing/invalid snapshot is provably
# unrecoverable: the purged segments' only other copy was the snapshot.
# Otherwise fall back to the seg-0 heuristic (pre-tombstone purges, or a
# tombstone lost out-of-band): with segments present but seg-0 absent, the
# oldest retired records are unaccounted for.
def wal_cover_after_tombstone(tombstoned: Bool) -> IO(Bool):
  match tombstoned:
    case True{}: IO.pure(Bool, False{})
    case False{}:
      do IO<Bool>:
        +arch : List<&2, Nat> <- wal_all_arch_segnums()
        +act : List<&2, Nat> <- wal_segnums_dir(wal_active_dir())
        all : List<&2, Nat> = wal_list_append(arch, act)
        # Empty (fresh server) passes vacuously; otherwise seg-0 must exist.
        IO.pure(Bool, wal_cover_ok_go(all))

def wal_cover_ok() -> IO(Bool):
  do IO<Bool>:
    tombstoned : Bool <- wal_purge_log_has_entries()
    wal_cover_after_tombstone(tombstoned)

def snap_verify(+content: String, +expect_seq: Nat) -> Bool:
  Bool.and(snap_trailer_ok(content), Nat.is_eq(snap_seq_of(content), expect_seq))

# Segmented-WAL snapshot cycle (Round 3 item 14): instead of truncating the
# single bocht.wal, every active segment is archived (moved) into
# wal/archive/YYYY/MM/ AFTER the snapshot has been written, fsync'd and
# verified. The counter is bumped past the archived segment numbers first
# (inside wal_archive_covered), so a new segment number is never reused.
# The archive aborts (and retries after the next snapshot) if the counter
# bump fails or a destination name clash is detected - a crash mid-move
# therefore leaves each segment either active or archived, never deleted.
def snap_cycle_archived_go(is_zero: Bool, +moved: Nat) -> IO(Bool):
  match is_zero:
    case True{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: snapshot saved and verified, WAL archived (no active segments)\n")
        IO.pure(Bool, True{})
    case False{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: snapshot saved and verified, WAL archived (" ++ Nat.show(moved) ++ " segment(s))\n")
        IO.pure(Bool, True{})

def snap_cycle_archived(+moved: Nat) -> IO(Bool):
  snap_cycle_archived_go(Nat.is_eq(moved, 0n), moved)

def snap_cycle_archived_st(+moved: Nat, +st: MedState) -> IO(MedState):
  do IO<MedState>:
    _b : Bool <- snap_cycle_archived(moved)
    IO.pure(MedState, st_with_snapseq(st, st_seq(st)))

def snap_cycle_trunc(ok: Bool, +st: MedState) -> IO(MedState):
  match ok:
    case False{}: IO.pure(MedState, st)
    case True{}:
      do IO<MedState>:
        # Item 196: persist the archive high-water mark BEFORE moving
        # segments (crash-safe: a high COVERED with segments still active
        # can only cause a safe false-positive defensive replay).
        _c : Bool <- wal_covered_write_nat(wal_state_max_seq(st))
        now_sec : Nat <- wal_now_sec()
        moved : Nat <- wal_archive_covered(now_sec)
        snap_cycle_archived_st(moved, st)

# --- revoked-key tombstone compaction (Round 3 item 15) ---
# Revocation marks keys in place (Map.set: no per-revoke growth) but a
# revoked key is a permanent tombstone — nothing ever reclaims it, so the
# keys map (and every snapshot serializing it) grows monotonically with
# creates. At snapshot time we reclaim: every revoked key is dropped from the
# live map, with one fsync'd KEYDEL WAL line per drop written BEFORE the
# snapshot. Crash windows:
# - crash after KEYDEL, before the snapshot validates: restart replays the
#   old snapshot (still lists the revoked keys) + the KEYDEL lines, which
#   drop them again. Revoked keys stay rejected either way (auth maps a
#   missing key to the same 401 as a revoked one), so this window is safe.
# - a KEYDEL write fails (disk full): compaction is skipped for this cycle
#   and retried at the next snapshot; the map keeps the revoked keys.
# Compaction is O(keys) per snapshot (every 500 seq) and writes zero WAL
# lines when nothing is revoked. The archived WAL keeps the full KEY/KEYDEL
# history, so the audit trail is preserved.

def key_compact_collect(+kvs: List<&2, Sigma<&2, &2, String, _ => Auth>>, +dropped: List<&2, String>) -> List<&2, String>:
  match kvs:
    case Nil{}: dropped
    case h <> t:
      (v, +a) = h
      key_compact_collect(t, Bool.pick(List<&2, String>, auth_revoked(a), v <> dropped, dropped))

def key_compact_wal_go(+vs: List<&2, String>) -> IO(Bool):
  match vs:
    case Nil{}: IO.pure(Bool, True{})
    case v <> t:
      do IO<Bool>:
        ok : Bool <- wal_keydel(v)
        rest : Bool <- key_compact_wal_go(t)
        IO.pure(Bool, Bool.and(ok, rest))

def key_compact_del_go(+kvs: List<&2, Sigma<&2, &2, String, _ => Auth>>, +m: Map<&2, Auth>) -> Map<&2, Auth>:
  match kvs:
    case Nil{}: m
    case h <> t:
      (v, +a) = h
      key_compact_del_go(t, Bool.pick(Map<&2, Auth>, auth_revoked(a), Map.del(&2, Auth, m, v), m))

def key_compact_pick(ok: Bool, +keys: Map<&2, Auth>) -> Map<&2, Auth>:
  match ok:
    case True{}: key_compact_del_go(Map.to_list(&2, Auth, keys), keys)
    case False{}: keys

def key_compact(+keys: Map<&2, Auth>) -> IO(Map<&2, Auth>):
  do IO<Map<&2, Auth>>:
    ok : Bool <- key_compact_wal_go(key_compact_collect(Map.to_list(&2, Auth, keys), Nil{}))
    IO.pure(Map<&2, Auth>, key_compact_pick(ok, keys))

def key_compact_st(+st: MedState) -> IO(MedState):
  do IO<MedState>:
    ckeys : Map<&2, Auth> <- key_compact(st_keys(st))
    IO.pure(MedState, st_with_keys(st, ckeys))

def snap_cycle_go(+st2: MedState) -> IO(MedState):
  do IO<MedState>:
    ok : Bool <- snapshot_save(st2)
    snap_cycle_trunc(ok, st2)

def snap_cycle(+st: MedState) -> IO(MedState):
  do IO<MedState>:
    st2 : MedState <- key_compact_st(st)
    snap_cycle_go(st2)

def snap_interval() -> Nat:
  500n

def snap_due(+st: MedState) -> Bool:
  Bool.and(Bool.not(Nat.is_eq(st_seq(st), 0n)),
    Bool.not(Nat.is_lt(st_seq(st), Nat.add(st_snapseq(st), snap_interval()))))

def maybe_snapshot_go(due: Bool, +st: MedState) -> IO(MedState):
  match due:
    case False{}: IO.pure(MedState, st)
    case True{}: snap_cycle(st)

def maybe_snapshot(+st: MedState) -> IO(MedState):
  maybe_snapshot_go(snap_due(st), st)
