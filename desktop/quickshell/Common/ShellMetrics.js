// Logical pixels only: Qt/Wayland applies each output's device scale once.
function calculate(settings) {
    var accessibility = settings.textScale === "larger" ? 1.30
        : settings.textScale === "large" ? 1.15 : 1;
    var density = settings.interfaceDensity === "compact" ? 0.92
        : settings.interfaceDensity === "comfortable" ? 1.16 : 1;
    var base = Math.max(1, Math.round(settings.shellFontSize * settings.shellScale / 100 * accessibility));
    return { fontBase: base, fontScale: base / 12, density: density,
        spacingScale: base / 12 * density };
}

function fitWidth(preferred, available, margin) {
    return Math.max(1, Math.min(preferred, Math.max(1, available - 2 * margin)));
}

if (typeof module !== "undefined" && module.exports)
    module.exports = { calculate: calculate, fitWidth: fitWidth };
