// FS.rename_seg — JS backend stub.
//
// The JS effect runtime used here exposes no rename binding, so the move
// is unavailable on this backend (returns 0, failure). The native backend
// performs the real atomic rename. The campaign builds and tests the
// native binary exclusively.

function fs_rename_seg(from, to) {
  return 0;
}
