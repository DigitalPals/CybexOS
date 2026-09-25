// Locates the Quickshell source tree for the tests in this directory.
//
// The tests used to live inside that tree, at Common/tests/, which meant the
// Ansible copies them into the vendor runtime along with the shell —
// non-runtime files accumulating in a directory that is supposed to be
// disposable. They are repo tests, so they live with the other repo tests now.
const path = require("node:path");

const shellDir = path.resolve(__dirname, "../../roles/desktop/files/quickshell");

// require() a pure-JS helper out of Common/ by name.
function load(name) {
    return require(path.join(shellDir, "Common", name));
}

// Directories vendored from upstream projects, unchanged (see each one's
// README.md). Repo style rules cannot be applied to code that must stay
// byte-identical to its source, so the tree-wide scans skip them; the tests
// for how the shell hosts them live elsewhere.
const VENDORED_DIRS = ["ModelUsage"];

// Whether `rel`, a path relative to shellDir (or an absolute one inside it),
// lies in a vendored directory.
function isVendored(rel) {
    const relative = path.isAbsolute(rel) ? path.relative(shellDir, rel) : rel;
    const top = path.normalize(relative).split(path.sep)[0];
    return VENDORED_DIRS.includes(top);
}

module.exports = { shellDir, load, VENDORED_DIRS, isVendored };
