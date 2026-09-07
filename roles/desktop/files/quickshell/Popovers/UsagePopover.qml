pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// Per-provider usage view: brand header with mini provider tabs, blocked-bar
// window blocks with absolute reset times, and credits.
//
// Each limit is a compact tile so neighbouring reset details and meters stay
// visually contained. A limit in trouble colours its own number and meter
// rather than washing the whole tile with a status colour.
Surface {
    id: root

    // Usage derives the countdown and ticks it only while a view asks;
    // no resync on open, because a derived value cannot drift.
    Claim {
        active: root.visible
        onClaimed: Usage.acquireCountdown()
        onReleased: Usage.releaseCountdown()
    }

    // Right-island popouts run a touch wider (design t5).
    implicitWidth: availableWidth > 0
        ? Math.min(Theme.popWideWidth, availableWidth) : Theme.popWideWidth
    padding: Theme.panelPadding
    spacing: Theme.panelSectionSpacing

    readonly property string sel: Usage.selected
    readonly property bool hasProvider:
        Usage.providerKeys.indexOf(sel) !== -1
    readonly property var p: hasProvider ? Usage.provider(sel) : null
    readonly property var info: hasProvider ? Usage.meta[sel] : ({
        name: "Models", title: "Model usage", icon: "", cmd: ""
    })
    readonly property double readingAt: p && p.observedAt
        ? p.observedAt * 1000 : Usage.updatedAt

    readonly property real cardW: (width - 2 * padding - Theme.panelSectionSpacing) / 2
    readonly property int cardPadding: 12
    readonly property int cardMinHeight: 148

    function cardLabel(label) {
        const m = label.match(/^(.*) \((5 hour|7 day)\)$/i);
        if (m)
            return `${m[1]}\n${m[2].replace(" ", "-")} usage`.toUpperCase();
        const weekly = label.match(/^Weekly \((\w+)\)$/);
        const title = weekly ? weekly[1] + " weekly" : label;
        // Keep the subtitle lane even when a provider only supplies a title,
        // so readings and meters align with two-line cards beside them.
        return `${title.toUpperCase()}\n\u00a0`;
    }

    function remainColor(rem) {
        if (rem <= 10)
            return Theme.redText;
        if (rem <= 25)
            return Theme.amber;
        return Theme.textHi;
    }

    function barColor(rem) {
        if (rem <= 10)
            return Theme.red;
        if (rem <= 25)
            return Theme.amber;
        return Theme.accent;
    }

    function errorTitle(prov) {
        const name = Usage.meta[Usage.selected].name;
        switch (prov.kind) {
        case "config":
            return Usage.sourceName + " setup required";
        case "nocreds":
            return name + " sign-in required";
        case "expired":
            return name + " token expired";
        case "rate":
            return name + " is rate limited";
        case "refresh":
            return name + " refresh failed";
        case "wait":
            return name + " update pending";
        default:
            return name + " fetch failed";
        }
    }

    function errorBody(prov) {
        const cmd = Usage.meta[Usage.selected].cmd;
        const proxied = Settings.modOpts.usage.source !== "direct";
        switch (prov.kind) {
        case "config":
            return prov.message || "Check the " + Usage.sourceName + " connection in widget settings.";
        case "nocreds":
            if (proxied)
                return prov.message || "No matching account is enabled in " + Usage.sourceName + ".";
            return `No CLI credentials found. Run <font color="${Theme.textMid}" face="${Theme.fontMono}">${cmd}</font> in a terminal, complete the sign-in, then press Refresh.`;
        case "expired":
            if (proxied)
                return prov.message || "The managed provider token was rejected.";
            return `The stored token has expired. Run <font color="${Theme.textMid}" face="${Theme.fontMono}">${cmd}</font> in a terminal, then press Refresh.`;
        case "rate":
            return "The usage endpoint is rate limiting requests. Polling will retry automatically.";
        case "refresh":
            return `${prov.message || "Claude Code could not refresh the saved login."} Run <font color="${Theme.textMid}" face="${Theme.fontMono}">${cmd}</font> if it does not recover automatically.`;
        case "wait":
            return prov.message || "The previous quota period has reset. Its old reading was hidden; polling will fetch the new period when the five-minute endpoint interval allows it.";
        default:
            return prov.message || "The usage endpoint returned an unexpected response.";
        }
    }

    function staleBody(prov, nowMs) {
        let message = "The endpoint could not be updated, so these are the last valid readings.";
        switch (prov.staleKind) {
        case "rate":
            message = "The usage endpoint is rate limited. These are the last valid readings.";
            break;
        case "expired":
            message = Settings.modOpts.usage.source !== "direct"
                ? "A managed provider token was rejected. These are the last valid readings."
                : Settings.modOpts.usage.claudeAutoRefresh
                ? "Claude's login could not be refreshed. These are the last valid readings."
                : "Claude auto-refresh is off. These are the last valid readings.";
            break;
        case "refresh":
            message = "Claude Code could not refresh its login. These are the last valid readings.";
            break;
        }
        if (prov.retryAt && prov.retryAt > nowMs / 1000)
            message += " Retrying in " + Usage.formatReset(prov.retryAt) + ".";
        return message;
    }

    // ---- Header: brand mark, meta, mini tabs, refresh ------------------
    Item {
        width: parent.width
        height: Theme.panelHeaderHeight

        // The provider mark sits inline with its name at bar-icon size, the
        // way the T3 wordmark does. The old filled 46px brand square was a
        // block of saturated colour standing in for a 16px logo.
        BrandIcon {
            id: brandSquare
            visible: root.hasProvider
            x: 2
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.iconMedium
            height: Theme.iconMedium
            name: root.info.icon
        }

        Sym {
            visible: !root.hasProvider
            x: 2
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.iconMedium
            height: Theme.iconMedium
            name: "data_usage"
            size: Theme.iconMedium
            color: Theme.textMid
        }

        Rectangle {
            x: -root.padding
            y: parent.height - 1
            width: root.width
            height: 1
            color: Theme.hairlineSoft
        }

        Row {
            id: tabsRow
            anchors.right: parent.right
            anchors.rightMargin: 0
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.panelRowSpacing

            Repeater {
                model: Usage.providerKeys

                delegate: Rectangle {
                    id: miniTab

                    required property string modelData
                    readonly property bool active: Usage.selected === modelData

                    width: Theme.chipHeight
                    height: Theme.chipHeight
                    radius: Theme.chipRadius
                    color: active ? Theme.chipHover : miniTabMouse.containsMouse ? Theme.chip : "transparent"

                    BrandIcon {
                        anchors.centerIn: parent
                        width: miniTab.modelData === "codex" ? 12 : 11
                        height: width
                        name: Usage.meta[miniTab.modelData].icon
                        opacity: miniTab.active ? 1 : 0.45
                    }

                    MouseArea {
                        id: miniTabMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        // Hover-through: mirroring the bar chips, hovering a
                        // tab switches the whole view to that provider.
                        onEntered: Usage.selected = miniTab.modelData
                        onClicked: Usage.selected = miniTab.modelData
                    }
                }
            }

            Rectangle {
                width: Theme.chipHeight
                height: Theme.chipHeight
                radius: Theme.chipRadius
                color: refreshMouse.containsMouse ? Theme.chipHover : "transparent"

                Sym {
                    anchors.centerIn: parent
                    name: "refresh"
                    size: Theme.iconSmall
                    color: refreshMouse.containsMouse ? Theme.textHi : Theme.textLow
                }

                MouseArea {
                    id: refreshMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Usage.refresh()
                }
            }
        }

        Column {
            anchors.left: brandSquare.right
            anchors.leftMargin: 8
            anchors.right: tabsRow.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            Text {
                width: parent.width
                text: root.info.title
                font.family: Theme.fontMenu
                font.pixelSize: Theme.fontBody
                font.weight: Theme.weightSemibold
                color: Theme.textHi
                elide: Text.ElideRight
            }

            Text {
                width: parent.width
                text: {
                    if (!root.p || root.p.status !== "ok")
                        return "";
                    return root.p.plan || "";
                }
                font.family: Theme.fontMenu
                font.pixelSize: Theme.fontMicro
                color: Theme.textFaint
                elide: Text.ElideRight
            }
        }
    }

    // CLIProxyAPI may legitimately manage none of the providers this widget
    // understands. Keep that source-level state neutral rather than reviving
    // whichever provider happened to be selected before the inventory changed.
    Rectangle {
        visible: !root.hasProvider
        width: parent.width
        height: noProviderColumn.implicitHeight + 24
        radius: Theme.chipRadius
        color: Theme.tile
        border.width: 1
        border.color: Theme.hairlineSoft

        Column {
            id: noProviderColumn
            x: 12
            y: 12
            width: parent.width - 24
            spacing: 3

            Text {
                width: parent.width
                text: Usage.loading ? "Loading provider inventory…"
                    : "No managed usage providers"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.fontBody
                font.weight: Theme.weightMedium
                color: Theme.textHi
            }

            Text {
                width: parent.width
                text: Usage.loading ? "Waiting for " + Usage.sourceName + "."
                    : Usage.sourceName + " did not return a supported enabled provider."
                font.family: Theme.fontMenu
                font.pixelSize: Theme.fontSecondary
                color: Theme.textLow
                wrapMode: Text.Wrap
                lineHeight: Theme.proseLineHeight
            }
        }
    }

    // ---- Error panel ---------------------------------------------------
    Rectangle {
        visible: root.p !== null && root.p.status !== "ok"
        width: parent.width
        height: errRow.implicitHeight + 24
        radius: Theme.chipRadius
        color: Theme.redBgSoft

        Row {
            id: errRow
            x: 12
            y: 12
            width: parent.width - 24
            spacing: 10

            Sym {
                width: 18
                horizontalAlignment: Text.AlignHCenter
                name: "warning"
                size: Theme.fontBody
                color: Theme.redText
            }

            Column {
                width: parent.width - 28
                spacing: 3

                Text {
                    width: parent.width
                    text: root.p ? root.errorTitle(root.p) : ""
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.fontBody
                    font.weight: Theme.weightMedium
                    color: Theme.textHi
                }

                Text {
                    width: parent.width
                    textFormat: Text.RichText
                    text: root.p ? root.errorBody(root.p) : ""
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.fontSecondary
                    color: Theme.textLow
                    wrapMode: Text.Wrap
                    lineHeight: Theme.proseLineHeight
                }
            }
        }
    }

    // ---- Stale-data warning --------------------------------------------
    Rectangle {
        visible: root.p !== null && root.p.status === "ok" && root.p.stale === true
        width: parent.width
        height: staleRow.implicitHeight + 24
        radius: Theme.chipRadius
        color: Theme.amberBgSoft

        Row {
            id: staleRow
            x: 12
            y: 12
            width: parent.width - 24
            spacing: 10

            Sym {
                width: 18
                horizontalAlignment: Text.AlignHCenter
                name: "schedule"
                size: Theme.fontBody
                color: Theme.amber
            }

            Column {
                width: parent.width - 28
                spacing: 3

                Text {
                    width: parent.width
                    text: "Showing last known usage"
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.fontBody
                    font.weight: Theme.weightMedium
                    color: Theme.textHi
                }

                Text {
                    width: parent.width
                    text: root.p ? root.staleBody(root.p, Usage.countdownNow) : ""
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.fontSecondary
                    color: Theme.textLow
                    wrapMode: Text.Wrap
                    lineHeight: Theme.proseLineHeight
                }
            }
        }
    }

    // ---- Usage window cards ---------------------------------------------
    Grid {
        visible: root.p !== null && root.p.status === "ok"
        columns: 2
        columnSpacing: Theme.panelSectionSpacing
        rowSpacing: Theme.panelSectionSpacing
        width: parent.width

        Repeater {
            model: root.p && root.p.status === "ok" ? root.p.windows : []

            delegate: Rectangle {
                id: card

                required property var modelData
                readonly property bool hasUsage: typeof modelData.used === "number"
                    && isFinite(modelData.used)
                readonly property int remaining: hasUsage
                    ? Math.round(100 - modelData.used) : -1
                readonly property bool crit: hasUsage && remaining <= 10
                readonly property bool low: hasUsage && remaining > 10 && remaining <= 25
                readonly property bool hasReset: modelData.resetsAt !== null
                    && modelData.resetsAt !== undefined

                width: root.cardW
                height: Math.max(root.cardMinHeight,
                    cardCol.implicitHeight + 2 * root.cardPadding)
                radius: Theme.cardRadius
                color: Theme.tile
                border.width: 1
                border.color: Theme.hairlineSoft
                clip: true

                Column {
                    id: cardCol
                    x: root.cardPadding
                    y: root.cardPadding
                    width: parent.width - 2 * root.cardPadding
                    spacing: 7

                    Text {
                        id: cardLabel
                        width: parent.width
                        text: root.cardLabel(card.modelData.label)
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.fontCaption
                        font.weight: Theme.weightSemibold
                        font.letterSpacing: 0.6
                        color: Theme.textDim
                        wrapMode: Text.Wrap
                    }

                    // Sized to the reading, with the suffix hung off its
                    // baseline. A Row would take its height from the small
                    // suffix and let the reading overhang it by an ascender.
                    Item {
                        width: parent.width
                        height: Math.max(remainingValue.implicitHeight, badge.implicitHeight)

                        Text {
                            id: remainingValue
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            text: card.hasUsage ? card.remaining : "—"
                            font.family: Theme.fontMono
                            font.pixelSize: Theme.fontProminent
                            font.weight: Theme.weightSemibold
                            color: card.hasUsage
                                ? root.remainColor(card.remaining) : Theme.textHi
                        }

                        Text {
                            id: remainingSuffix
                            anchors.left: remainingValue.right
                            anchors.leftMargin: 3
                            anchors.baseline: remainingValue.baseline
                            text: card.hasUsage ? "% left" : "usage unavailable"
                            font.family: Theme.fontMono
                            font.pixelSize: Theme.fontCaption
                            color: Theme.textLow
                        }

                        Rectangle {
                            id: badge
                            visible: card.crit || card.low
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            width: badgeText.implicitWidth + 10
                            implicitHeight: badgeText.implicitHeight + 4
                            radius: 4
                            color: card.crit ? Theme.redBg : Theme.amberBg

                            Text {
                                id: badgeText
                                anchors.centerIn: parent
                                text: card.crit ? "CRITICAL" : "LOW"
                                font.family: Theme.fontMenu
                                font.pixelSize: Theme.fontCaption
                                font.weight: Theme.weightSemibold
                                font.letterSpacing: 0.5
                                color: card.crit ? Theme.redText : Theme.amber
                            }
                        }
                    }

                    BlockMeter {
                        visible: card.hasUsage
                        width: parent.width
                        height: 10
                        value: card.hasUsage ? card.remaining / 100 : 0
                        fillColor: root.barColor(card.remaining)
                    }

                    Column {
                        id: resetCol

                        visible: card.hasReset
                        width: parent.width
                        spacing: 2

                        Text {
                            width: parent.width
                            text: card.hasReset
                                ? "resets in " + Usage.formatReset(card.modelData.resetsAt) : ""
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.fontCaption
                            color: Theme.textLow
                            elide: Text.ElideRight
                        }

                        Text {
                            width: parent.width
                            text: card.hasReset ? Usage.formatResetAbs(card.modelData.resetsAt) : ""
                            font.family: Theme.fontMono
                            font.pixelSize: Theme.fontCaption
                            color: Theme.textFaint
                            elide: Text.ElideRight
                        }
                    }
                }
            }
        }

        // Extra usage / credits card
        Rectangle {
            id: creditsCard

            readonly property var c: root.p && root.p.status === "ok" ? root.p.credits : null
            readonly property bool hasMeter: c !== null && c !== undefined
                && c.used !== null && c.used !== undefined
                && c.limit !== null && c.limit !== undefined && c.limit > 0
            readonly property bool creditsStyle: c !== null && c !== undefined && !hasMeter
                && c.remaining !== null && c.remaining !== undefined
            readonly property string displayValue: {
                if (!c)
                    return "";
                if (c.unlimited)
                    return "Unlimited";
                if (hasMeter)
                    return "$" + c.used.toFixed(2);
                if (c.remaining !== null && c.remaining !== undefined)
                    return Number(c.remaining).toLocaleString(Qt.locale("en_US"), "f",
                        c.remaining % 1 === 0 ? 0 : 2);
                return "—";
            }
            readonly property string displaySuffix: !c || c.unlimited ? ""
                : hasMeter ? "/ $" + c.limit.toFixed(2) : "left"

            visible: root.p !== null && root.p.status === "ok" && c !== null && c !== undefined
            width: root.cardW
            height: Math.max(root.cardMinHeight,
                creditsCol.implicitHeight + 2 * root.cardPadding)
            radius: Theme.cardRadius
            color: Theme.tile
            border.width: 1
            border.color: Theme.hairlineSoft
            clip: true

            Column {
                id: creditsCol
                x: root.cardPadding
                y: root.cardPadding
                width: parent.width - 2 * root.cardPadding
                spacing: 7

                Item {
                    width: parent.width
                    height: creditsLabel.implicitHeight

                    Text {
                        id: creditsLabel
                        anchors.verticalCenter: parent.verticalCenter
                        text: creditsCard.c && creditsCard.c.label
                            ? String(creditsCard.c.label).toUpperCase()
                            : creditsCard.creditsStyle ? "CREDITS" : "EXTRA USAGE"
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.fontCaption
                        font.weight: Theme.weightSemibold
                        font.letterSpacing: 0.6
                        color: Theme.textDim
                    }
                }

                Item {
                    width: creditsValue.implicitWidth + 5 + creditsSuffix.implicitWidth
                    height: creditsValue.implicitHeight

                    Text {
                        id: creditsValue
                        anchors.left: parent.left
                        anchors.top: parent.top
                        text: creditsCard.displayValue
                        font.family: Theme.fontMono
                        font.pixelSize: Theme.fontHeading
                        font.weight: Theme.weightSemibold
                        color: Theme.textHi
                    }

                    Text {
                        id: creditsSuffix
                        anchors.left: creditsValue.right
                        anchors.leftMargin: 5
                        anchors.baseline: creditsValue.baseline
                        text: creditsCard.displaySuffix
                        font.family: Theme.fontMono
                        font.pixelSize: Theme.fontSecondary
                        color: Theme.textLow
                    }
                }

                BlockMeter {
                    visible: creditsCard.hasMeter
                    width: parent.width
                    height: 10
                    value: creditsCard.hasMeter ? creditsCard.c.used / creditsCard.c.limit : 0
                    fillColor: Theme.textLow
                }

                Text {
                    width: parent.width
                    text: creditsCard.c && creditsCard.c.description
                        ? creditsCard.c.description
                        : creditsCard.creditsStyle ? "use credits beyond plan limits"
                        : "pay-as-you-go beyond plan limits"
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.fontCaption
                    color: Theme.textDim
                    wrapMode: Text.Wrap
                    lineHeight: Theme.proseLineHeight
                }
            }
        }
    }

    // ---- Footer -----------------------------------------------------------
    Item {
        width: parent.width
        height: Theme.panelFooterHeight

        Rectangle {
            x: -root.padding
            anchors.top: parent.top
            width: root.width
            height: 1
            color: Theme.hairlineSoft
        }

        Text {
            x: 2
            anchors.verticalCenter: parent.verticalCenter
            // A fetcher failure is plain text — a Python traceback can carry
            // "<module>" and would otherwise be read as markup — and elides
            // instead of running under the countdown. The journal has it in
            // full.
            width: parent.width - 4 - nextPoll.implicitWidth - 8
            elide: Text.ElideRight
            textFormat: Usage.fetchError !== "" ? Text.PlainText : Text.RichText
            text: Usage.fetchError !== ""
                ? Usage.fetchError
                : !root.hasProvider
                    ? Usage.loading ? "Loading…" : "No managed providers"
                : root.readingAt > 0
                    ? `${root.p && root.p.stale === true ? "last live" : "updated"} <font color="${Theme.textLow}" face="${Theme.fontMono}">${Qt.formatTime(new Date(root.readingAt), "HH:mm:ss")}</font>`
                    : "Loading…"
            font.family: Theme.fontMenu
            font.pixelSize: Theme.fontMicro
            color: Usage.fetchError !== "" ? Theme.redText : Theme.textFaint
        }

        Text {
            id: nextPoll
            anchors.right: parent.right
            anchors.rightMargin: 2
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.RichText
            text: root.p && root.p.retryAt
                    && root.p.retryAt > Usage.countdownNow / 1000
                ? `retry in <font color="${Theme.textLow}" face="${Theme.fontMono}">${Usage.formatReset(root.p.retryAt)}</font>`
                : `next poll <font color="${Theme.textLow}" face="${Theme.fontMono}">${Usage.formatCountdown(Usage.nextPollSecs)}</font>`
            font.family: Theme.fontMenu
            font.pixelSize: Theme.fontMicro
            color: Theme.textFaint
        }
    }
}
