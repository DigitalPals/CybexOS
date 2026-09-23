const test = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./shell.cjs");

const P = load("PaletteHelpers.js");
const S = load("SettingsHelpers.js");

const dark = {
    background: "#121318", surface: "#121318",
    surface_container_low: "#1b1b21", surface_container: "#1f1f25",
    surface_container_high: "#292a2f", on_surface: "#e3e1e9",
    on_surface_variant: "#c6c5d0", primary: "#b9c3ff",
    primary_container: "#384379", on_primary: "#212c61",
    outline_variant: "#45464f", error: "#ffb4ab",
    error_container: "#93000a", on_error: "#690005"
};

const light = {
    background: "#fbf8ff", surface: "#fbf8ff",
    surface_container_low: "#f5f2fa", surface_container: "#efedf4",
    surface_container_high: "#e9e7ef", on_surface: "#1b1b21",
    on_surface_variant: "#45464f", primary: "#505b92",
    primary_container: "#dee1ff", on_primary: "#ffffff",
    outline_variant: "#c6c5d0", error: "#ba1a1a",
    error_container: "#ffdad6", on_error: "#ffffff"
};

function output() {
    const colors = { ignored_role: { dark: "#000000", light: "#ffffff" } };
    for (const input of P.ROLE_KEYS)
        colors[input] = { dark: dark[input], default: dark[input], light: light[input] };
    return { colors };
}

test("Matugen tonal-spot JSON is whitelisted and normalized", () => {
    const palette = P.sanitizeMatugen(JSON.stringify(output()));
    assert.ok(palette);
    assert.equal(Object.keys(palette.dark).length, P.ROLE_KEYS.length);
    assert.equal("ignoredRole" in palette.dark, false);
    assert.equal(palette.dark.surfaceContainerLow, dark.surface_container_low);
    assert.equal(palette.light.onSurfaceVariant, light.on_surface_variant);
    assert.equal(palette.light.primary, "#505b92");
});

test("malformed and incomplete Matugen output is rejected", () => {
    assert.equal(P.sanitizeMatugen("not json"), null);
    assert.equal(P.sanitizeMatugen("[]"), null);
    assert.equal(P.sanitizeMatugen({ colors: {} }), null);
    const missing = output();
    delete missing.colors.primary.light;
    assert.equal(P.sanitizeMatugen(missing), null);
    const badColor = output();
    badColor.colors.surface.dark = "rgb(0,0,0)";
    assert.equal(P.sanitizeMatugen(badColor), null);
});

test("light and dark selection uses one validated palette", () => {
    const palette = P.sanitizeMatugen(output());
    assert.equal(P.activeVariant(palette, "dark").primary, dark.primary);
    assert.equal(P.activeVariant(palette, "light").primary, light.primary);
    assert.equal(P.activeVariant(palette, "system").primary, dark.primary);
});

test("cache reads require the exact version and wallpaper identity", () => {
    const palette = P.sanitizeMatugen(output());
    const identity = "/wallpapers/current.jpg";
    const serialized = P.serializeCache(identity, palette, "100 2000");
    assert.deepEqual(P.readCache(serialized, identity), palette);
    assert.deepEqual(P.readCache(serialized, identity, "100 2000"), palette);
    assert.equal(P.readCache(serialized, "/wallpapers/next.jpg"), null);

    const wrongVersion = JSON.parse(serialized);
    wrongVersion.v = P.CACHE_VERSION + 1;
    assert.equal(P.readCache(wrongVersion, identity), null);
    const malformed = JSON.parse(serialized);
    malformed.entries[0].palette.dark.primary = "blue";
    assert.equal(P.readCache(malformed, identity), null);
    assert.equal(P.readCache({ v: 1, identity, palette }, identity), null,
        "a v1 single-entry cache is not read as a match");
});

test("a file replaced under the same path misses the cache", () => {
    const palette = P.sanitizeMatugen(output());
    const identity = "/wallpapers/current.jpg";
    const serialized = P.serializeCache(identity, palette, "100 2000");
    assert.equal(P.readCache(serialized, identity, "101 2000"), null, "mtime changed");
    assert.equal(P.readCache(serialized, identity, "100 2001"), null, "size changed");
    assert.equal(P.serializeCache(identity, palette, ""), "",
        "an unreadable file has no key and is never cached");
    assert.equal(P.fingerprint("1726000000 48213\n"), "1726000000 48213");
    assert.equal(P.fingerprint(""), "");
    assert.equal(P.fingerprint("stat: cannot statx"), "");
    assert.equal(P.fingerprint(undefined), "");
});

test("the cache keeps recent wallpapers, newest first, one entry per path", () => {
    const palette = P.sanitizeMatugen(output());
    let text = "";
    for (let i = 0; i < 5; i++)
        text = P.serializeCache(`/w/${i}.jpg`, palette, `${i} 1`, text, 3);
    assert.deepEqual(P.cacheEntries(text).map(entry => entry.identity),
        ["/w/4.jpg", "/w/3.jpg", "/w/2.jpg"]);
    assert.equal(P.readCache(text, "/w/1.jpg"), null, "the oldest entry was evicted");

    text = P.serializeCache("/w/2.jpg", palette, "9 9", text, 3);
    assert.deepEqual(P.cacheEntries(text).map(entry => entry.identity),
        ["/w/2.jpg", "/w/4.jpg", "/w/3.jpg"]);
    assert.equal(P.readCache(text, "/w/2.jpg", "2 1"), null,
        "regenerating a path replaces its old fingerprint");
    assert.deepEqual(P.readCache(text, "/w/2.jpg", "9 9"), palette);
    assert.ok(P.CACHE_LIMIT >= 8);
});

test("stale results are rejected and fixed fallback remains selectable", () => {
    const palette = P.sanitizeMatugen(output());
    assert.equal(P.resultIsCurrent("/a.jpg", "/a.jpg"), true);
    assert.equal(P.resultIsCurrent("/a.jpg", "/b.jpg"), false);
    const fallback = { primary: "#5e9bff", surface: "#161424" };
    assert.equal(P.selectOrFallback(palette, "dark", fallback, false), fallback);
    assert.equal(P.selectOrFallback(null, "dark", fallback, true), fallback);
    assert.equal(P.selectOrFallback(palette, "light", fallback, true).primary,
        light.primary);
});

test("representative Matugen copy roles retain AA contrast", () => {
    const palette = P.sanitizeMatugen(output());
    for (const mode of ["dark", "light"]) {
        const roles = P.activeVariant(palette, mode);
        const surfaces = [roles.surface, roles.surfaceContainerLow,
            roles.surfaceContainer, roles.surfaceContainerHigh];
        const copy = S.semanticPalette(roles.surfaceContainerHigh,
            roles.onSurface, roles.onSurfaceVariant);
        for (const surface of surfaces) {
            for (const role of ["textHi", "textMid", "textLow", "textDim",
                                "textFaint", "icon"])
                assert.ok(S.contrastRatio(copy[role], surface) >= 4.5,
                    `${mode} ${role} fails on ${surface}`);
        }

        const preservedCopyColors = mode === "dark"
            ? ["#ffc26e", "#63d68c", "#bfc6da", "#a8b0c4", "#949aa8",
               "#6ab0ea", "#c8e2f5", "#a992e0", "#d97757", "#4fb8a8",
               "#4d6bfe"]
            : ["#b5761e", "#1f9d57", "#bfc6da", "#5c6377", "#5f6572",
               "#6ab0ea", "#4a8fbe", "#a992e0", "#d97757", "#4fb8a8",
               "#4d6bfe"];
        for (const candidate of preservedCopyColors) {
            const safe = S.ensureContrast(candidate, roles.surfaceContainerHigh, 4.5);
            for (const surface of surfaces)
                assert.ok(S.contrastRatio(safe, surface) >= 4.5,
                    `${mode} ${candidate} fails on ${surface}`);
        }
        assert.ok(S.contrastRatio(
            S.ensureContrast(roles.onPrimary, roles.primary, 4.5), roles.primary) >= 4.5);
    }
});
