// FS.file_mtime — JS backend stub.
//
// The JS effect runtime used here exposes no stat binding, so the mtime
// is unavailable on this backend (returns 0). The native backend returns
// the real mtime, fail-closed to "now" on stat errors. The campaign
// builds and tests the native binary exclusively.

function fs_file_mtime(path) {
  return 0;
}
