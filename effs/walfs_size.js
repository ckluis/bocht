// FS.file_size — JS backend stub.
//
// The JS effect runtime used here exposes no stat binding, so the size is
// unavailable on this backend (returns 0, i.e. "empty/missing"). The
// native backend returns the real size. The campaign builds and tests the
// native binary exclusively.

function fs_file_size(path) {
  return 0;
}
