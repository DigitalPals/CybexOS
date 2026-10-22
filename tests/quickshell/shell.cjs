// Locates the Quickshell source tree for the tests in this directory.
//
// The tests used to live inside that tree, at Common/tests/, which meant the
// NixOS modules copies them into the vendor runtime along with the shell —
// non-runtime files accumulating in a directory that is supposed to be
// disposable. They are repo tests, so they live with the other repo tests now.
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const executable = name => execFileSync("sh", ["-c", "command -v " + name], { encoding: "utf8" }).trim();

const shellDir = path.resolve(__dirname, "../../desktop/quickshell");

// require() a pure-JS helper out of Common/ by name.
function load(name) {
    return require(path.join(shellDir, "Common", name));
}

// Directories vendored from upstream projects (see each README for reviewed
// integration patches). Repo style rules cannot be applied to these sources,
// so the tree-wide scans skip them; the tests
// for how the shell hosts them live elsewhere.
const VENDORED_DIRS = ["ModelUsage"];

// Whether `rel`, a path relative to shellDir (or an absolute one inside it),
// lies in a vendored directory.
function isVendored(rel) {
    const relative = path.isAbsolute(rel) ? path.relative(shellDir, rel) : rel;
    const top = path.normalize(relative).split(path.sep)[0];
    return VENDORED_DIRS.includes(top);
}

// QML source as its English text reads: I18n.tr("Text") becomes "Text".
// Structure tests assert the copy a view shows in English; whether that copy
// is translated is i18n.test.cjs's concern (docs/shell-translations.md).
function untranslated(source) {
    return String(source).replace(/I18n\.tr\(("(?:[^"\\]|\\.)*")\)/g, "$1");
}

module.exports = { shellDir, load, VENDORED_DIRS, isVendored, untranslated, executable };
