import QtQuick
import "../Common"
import "../Common/Format.js" as Format

// A rolling history plot. The time axis is a fixed window ending at `now`, so
// a short history fills in from the right instead of being stretched across
// the whole width, and the plot keeps moving between samples. Each series is
// { points: [{ at, value }], tint }; a null value breaks the line rather than
// dropping it to zero. Colours reach the 2D context as rgba() strings, which
// is the one form it reads alpha from reliably.
Canvas {
    id: root

    property var series: []
    // The value at the top edge. Callers with an open-ended scale (rates)
    // pass a rounded ceiling rather than the raw peak, so the plot does not
    // rescale on every sample.
    property real ceiling: 100
    property double span: 600000
    property double now: Date.now()
    property int divisions: 4
    property color gridColor: Theme.hairlineSoft
    property string description: "Recent history"

    // Keep the latest-point mark whole at the right edge.
    readonly property real inset: 3

    implicitHeight: 48
    Accessible.role: Accessible.Chart
    Accessible.name: description

    onSeriesChanged: requestPaint()
    onCeilingChanged: requestPaint()
    onNowChanged: requestPaint()
    onGridColorChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    function rgba(c, alpha) {
        return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + ","
            + Math.round(c.b * 255) + "," + (c.a * alpha).toFixed(3) + ")";
    }

    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();
        if (width <= root.inset * 2 || height <= 2)
            return;
        const top = 1;
        const bottom = height - 1;
        const plot = bottom - top;
        const right = width - root.inset;
        const start = root.now - root.span;
        const max = root.ceiling > 0 ? root.ceiling : 1;

        ctx.lineWidth = 1;
        ctx.strokeStyle = rgba(root.gridColor, 1);
        for (let i = 0; i <= root.divisions; i++) {
            const y = Math.round(top + plot * i / root.divisions) + 0.5;
            ctx.beginPath();
            ctx.moveTo(0, y);
            ctx.lineTo(width, y);
            ctx.stroke();
        }

        for (const line of root.series) {
            const runs = [];
            let run = [];
            for (const p of line.points) {
                if (p.value === null || p.value === undefined || !isFinite(p.value)) {
                    if (run.length)
                        runs.push(run);
                    run = [];
                    continue;
                }
                run.push([right * (p.at - start) / root.span,
                    bottom - plot * Format.clamp01(p.value / max)]);
            }
            if (run.length)
                runs.push(run);

            const fill = ctx.createLinearGradient(0, top, 0, bottom);
            fill.addColorStop(0, rgba(line.tint, 0.30));
            fill.addColorStop(1, rgba(line.tint, 0.02));
            ctx.lineJoin = "round";
            ctx.lineCap = "round";
            for (const r of runs) {
                if (r.length < 2)
                    continue;
                ctx.beginPath();
                ctx.moveTo(r[0][0], bottom);
                for (const point of r)
                    ctx.lineTo(point[0], point[1]);
                ctx.lineTo(r[r.length - 1][0], bottom);
                ctx.closePath();
                ctx.fillStyle = fill;
                ctx.fill();

                ctx.beginPath();
                ctx.moveTo(r[0][0], r[0][1]);
                for (const point of r)
                    ctx.lineTo(point[0], point[1]);
                ctx.lineWidth = 1.5;
                ctx.strokeStyle = rgba(line.tint, 1);
                ctx.stroke();
            }

            const last = runs.length ? runs[runs.length - 1] : null;
            if (last) {
                const point = last[last.length - 1];
                ctx.beginPath();
                ctx.arc(point[0], point[1], 2.5, 0, 2 * Math.PI);
                ctx.fillStyle = rgba(line.tint, 1);
                ctx.fill();
            }
        }
    }
}
