pragma ComponentBehavior: Bound
import QtQuick
import "../../Common"
import "../../Common/SysInfoHelpers.js" as SysInfoHelpers
import ".."

// The fixed identity and health summary at the top of Overview. It stays
// independent of drawer section settings: opening the Fedora button always
// answers which machine this is and how its core resources are doing.
Rectangle {
    id: root

    width: parent ? parent.width : 0
    height: implicitHeight
    implicitHeight: heroContent.implicitHeight + Theme.scaled(20)
    radius: Theme.rowRadius + 2
    color: Theme.chip
    border.width: 1
    border.color: Theme.hairlineSoft

    readonly property int logoSize: Theme.scaled(56)
    readonly property bool fedoraIdentity:
        SysInfo.osId.toLowerCase() === "fedora" && SysInfo.osName !== ""
    readonly property string osTitle:
        SysInfo.osName !== "" ? SysInfo.osName : "System information unavailable"
    readonly property string osReleaseLine: {
        const details = [];
        if (SysInfo.osVersion !== "")
            details.push("Version " + SysInfo.osVersion);
        if (SysInfo.osVariant !== "")
            details.push(SysInfo.osVariant);
        return details.length > 0 ? details.join(" · ") : "OS release unavailable";
    }
    readonly property string machine: {
        const details = [];
        if (SysInfo.deviceVendor !== "")
            details.push(SysInfo.deviceVendor);
        if (SysInfo.deviceModel !== "")
            details.push(SysInfo.deviceModel);
        return details.length > 0 ? details.join(" ") : "Device model unavailable";
    }
    readonly property string kernelUptime: "Kernel "
        + (SysInfo.kernelRelease !== "" ? SysInfo.kernelRelease : "unavailable")
        + " · Up " + SysInfoHelpers.formatUptime(SysInfo.uptimeSecs)
    readonly property string memoryDetail: {
        if (!SysInfo.memKnown)
            return "Memory unavailable";
        let result = root.capacity(true, SysInfo.memUsedBytes) + " / "
            + root.capacity(true, SysInfo.memTotalBytes) + " used";
        if (!SysInfo.swapKnown)
            return result + " · Swap unavailable";
        if (SysInfo.swapTotalBytes === 0)
            return result + " · No swap";
        return result + " · Swap "
            + root.capacity(true, SysInfo.swapUsedBytes) + " / "
            + root.capacity(true, SysInfo.swapTotalBytes) + " used";
    }
    readonly property string diskDetail: SysInfo.rootFsKnown
        ? root.capacity(true, SysInfo.rootFsUsedBytes) + " / "
            + root.capacity(true, SysInfo.rootFsTotalBytes) + " used · "
            + root.capacity(true, SysInfo.rootFsAvailableBytes) + " free · "
            + SysInfo.rootFsType
        : "Storage unavailable"

    function percentage(known, value) {
        return known ? Math.round(value) + "%" : "Unavailable";
    }

    function capacity(known, value) {
        return known ? SysInfoHelpers.formatIecBytes(value) : "Unavailable";
    }

    component MetricRow: Rectangle {
        id: metric

        required property string label
        required property bool known
        required property real percent
        required property string detail
        property string status: ""
        property color statusColor: Theme.textFaint
        property color meterColor: Theme.accent
        property int severity: 0
        property string accessibleDescription: ""
        required property string accessibleName

        width: parent ? parent.width : 0
        height: implicitHeight
        implicitHeight: metricContent.implicitHeight + Theme.scaled(14)
        radius: Theme.rowRadius
        color: severity >= 2 ? Theme.redBgSoft
            : severity === 1 ? Theme.amberBgSoft : "transparent"

        Accessible.role: Accessible.StaticText
        Accessible.name: metric.accessibleName
        Accessible.description: metric.accessibleDescription

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 1
            color: Theme.hairlineSoft
            Accessible.ignored: true
        }

        Column {
            id: metricContent

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: Theme.scaled(4)
            anchors.rightMargin: Theme.scaled(4)
            anchors.topMargin: Theme.scaled(8)
            spacing: Theme.scaled(3)

            Item {
                width: parent.width
                height: Math.max(metricLabel.implicitHeight,
                    metricReadingRow.implicitHeight)

                Text {
                    id: metricLabel
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: metric.label
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.metadata
                    font.weight: Theme.weightSemibold
                    font.letterSpacing: 0.7
                    color: Theme.textMid
                    Accessible.ignored: true
                }

                Row {
                    id: metricReadingRow

                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.scaled(5)

                    Text {
                        id: metricReading

                        text: root.percentage(metric.known, metric.percent)
                        font.family: Theme.fontNumeric
                        font.pixelSize: Theme.typography.primary
                        font.weight: Theme.weightSemibold
                        font.features: Theme.tabularNumberFeatures
                        color: metric.known ? Theme.textHi : Theme.textFaint
                        Accessible.ignored: true
                    }

                    Text {
                        visible: metric.status !== ""
                        text: "· " + metric.status
                        font.family: Theme.fontNumeric
                        font.pixelSize: Theme.typography.primary
                        font.weight: Theme.weightSemibold
                        font.features: Theme.tabularNumberFeatures
                        color: metric.statusColor
                        Accessible.ignored: true
                    }
                }
            }

            Text {
                width: parent.width
                text: metric.detail
                wrapMode: Text.Wrap
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightMedium
                color: Theme.textMid
                Accessible.ignored: true
            }

            BlockMeter {
                width: parent.width
                height: Theme.scaled(6)
                value: metric.known ? metric.percent / 100 : 0
                fillColor: metric.meterColor
                trackColor: Theme.hairline
                dimmed: !metric.known
                Accessible.ignored: true
            }
        }
    }

    Column {
        id: heroContent

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Theme.scaled(10)
        spacing: Theme.scaled(7)

        Item {
            width: parent.width
            height: Math.max(root.logoSize, identity.implicitHeight)

            Item {
                id: mark
                anchors.left: parent.left
                anchors.top: parent.top
                width: root.logoSize
                height: root.logoSize

                BrandIcon {
                    anchors.fill: parent
                    name: "fedora"
                    visible: root.fedoraIdentity
                }

                Rectangle {
                    anchors.fill: parent
                    visible: !root.fedoraIdentity
                    radius: Theme.rowRadius
                    color: Theme.chipHover

                    Sym {
                        anchors.centerIn: parent
                        name: "computer"
                        size: Theme.iconHero
                        color: Theme.accent
                    }
                }
            }

            Column {
                id: identity
                anchors.left: mark.right
                anchors.leftMargin: Theme.scaled(12)
                anchors.right: parent.right
                anchors.top: parent.top
                spacing: 2

                Text {
                    width: parent.width
                    text: root.osTitle
                    wrapMode: Text.Wrap
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.title
                    font.weight: Theme.weightBold
                    color: Theme.textHi
                }

                Text {
                    width: parent.width
                    text: root.osReleaseLine
                    wrapMode: Text.Wrap
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    font.weight: Theme.weightMedium
                    color: Theme.textMid
                }

                Text {
                    width: parent.width
                    text: root.machine
                    wrapMode: Text.Wrap
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.metadata
                    color: Theme.textMid
                }
            }
        }

        Text {
            width: parent.width
            text: root.kernelUptime
            wrapMode: Text.WrapAnywhere
            font.family: Theme.fontNumeric
            font.pixelSize: Theme.typography.metadata
            font.features: Theme.tabularNumberFeatures
            color: Theme.textMid
        }

        Column {
            width: parent.width
            spacing: 0

            MetricRow {
                label: "CPU"
                known: SysInfo.cpuUsageKnown
                percent: SysInfo.cpuUsage
                detail: SysInfo.cpuModel !== ""
                    ? SysInfo.cpuModel : "Processor model unavailable"
                status: SysInfo.cpuTempKnown
                    ? SysInfo.cpuTemp + "°C" : "Temp unavailable"
                statusColor: !SysInfo.cpuTempKnown ? Theme.textFaint
                    : SysInfo.cpuTemp >= 80 ? Theme.redText
                    : SysInfo.cpuTemp >= 65 ? Theme.amber : Theme.textMid
                severity: !SysInfo.cpuTempKnown ? 0
                    : SysInfo.cpuTemp >= 80 ? 2
                    : SysInfo.cpuTemp >= 65 ? 1 : 0
                accessibleName: "CPU, " + (SysInfo.cpuUsageKnown
                    ? Math.round(SysInfo.cpuUsage) + " percent utilization"
                    : "utilization unavailable") + ", "
                    + (SysInfo.cpuModel !== "" ? SysInfo.cpuModel
                        : "processor model unavailable") + ", "
                    + (SysInfo.cpuTempKnown
                        ? SysInfo.cpuTemp + " degrees Celsius"
                        : "temperature unavailable")
            }

            MetricRow {
                label: "MEMORY"
                known: SysInfo.memKnown
                percent: SysInfo.memUsage
                detail: root.memoryDetail
                meterColor: !SysInfo.memKnown ? Theme.accent
                    : SysInfo.memUsage >= 95 ? Theme.red
                    : SysInfo.memUsage >= 85 ? Theme.amber : Theme.accent
                severity: !SysInfo.memKnown ? 0
                    : SysInfo.memUsage >= 95 ? 2
                    : SysInfo.memUsage >= 85 ? 1 : 0
                accessibleName: "Memory, " + (SysInfo.memKnown
                    ? Math.round(SysInfo.memUsage) + " percent, "
                        + root.capacity(true, SysInfo.memUsedBytes)
                            + " used of "
                        + root.capacity(true, SysInfo.memTotalBytes)
                    : "unavailable") + ", "
                    + (!SysInfo.swapKnown ? "swap unavailable"
                        : SysInfo.swapTotalBytes === 0 ? "no swap"
                        : root.capacity(true, SysInfo.swapUsedBytes)
                            + " swap used of "
                            + root.capacity(true, SysInfo.swapTotalBytes))
            }

            MetricRow {
                label: "DISK /"
                known: SysInfo.rootFsKnown
                percent: SysInfo.rootFsUsage
                detail: root.diskDetail
                meterColor: !SysInfo.rootFsKnown ? Theme.accent
                    : SysInfo.rootFsUsage >= 90 ? Theme.red
                    : SysInfo.rootFsUsage >= 80 ? Theme.amber : Theme.accent
                severity: !SysInfo.rootFsKnown ? 0
                    : SysInfo.rootFsUsage >= 90 ? 2
                    : SysInfo.rootFsUsage >= 80 ? 1 : 0
                accessibleName: "Disk slash, " + (SysInfo.rootFsKnown
                    ? Math.round(SysInfo.rootFsUsage) + " percent, "
                        + root.capacity(true, SysInfo.rootFsUsedBytes)
                            + " used of "
                        + root.capacity(true, SysInfo.rootFsTotalBytes) + ", "
                        + root.capacity(true, SysInfo.rootFsAvailableBytes)
                            + " available, filesystem " + SysInfo.rootFsType
                    : "unavailable" + (SysInfo.rootFsError !== ""
                        ? ", " + SysInfo.rootFsError : ""))
                accessibleDescription: SysInfo.rootFsError
            }
        }
    }
}
