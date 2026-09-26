import QtQuick
import "../Common"
import "../Common/Format.js" as Format

Canvas {
    id: root
    property var points: []
    property real ceiling: 100
    property color tint: Theme.accentText
    property string description: "Recent history"
    implicitHeight: 48
    Accessible.role: Accessible.Chart
    Accessible.name: description
    onPointsChanged: requestPaint()
    onCeilingChanged: requestPaint()
    onTintChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();
        if (points.length < 2 || width <= 0 || height <= 0) return;
        const start = points[0].at;
        const span = Math.max(1, points[points.length - 1].at - start);
        const max = ceiling > 0 ? ceiling : Math.max(1, ...points.map(p => p.value || 0));
        ctx.strokeStyle = Qt.alpha(tint, 0.15);
        ctx.lineWidth = 1;
        ctx.beginPath(); ctx.moveTo(0, height - 1); ctx.lineTo(width, height - 1); ctx.stroke();
        ctx.strokeStyle = tint;
        ctx.lineWidth = 2;
        ctx.lineJoin = "round";
        ctx.beginPath();
        let joined = false;
        for (const p of points) {
            if (p.value === null || !isFinite(p.value)) { joined = false; continue; }
            const x = 1 + (width - 2) * (p.at - start) / span;
            const y = height - 2 - (height - 4) * Format.clamp01(p.value / max);
            if (joined) ctx.lineTo(x, y); else ctx.moveTo(x, y);
            joined = true;
        }
        ctx.stroke();
    }
}
