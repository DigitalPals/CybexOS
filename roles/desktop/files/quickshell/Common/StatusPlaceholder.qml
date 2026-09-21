import QtQuick

// Intentional empty/loading/error treatment for content areas. The loading
// mark is the only continuously animated piece and stops with `shown`, so a
// closed panel or settled state consumes no animation frames.
Item {
    id: root

    property bool shown: true
    property string kind: "empty"
    property string glyph: {
        if (kind === "loading")
            return "progress_activity";
        if (kind === "error")
            return "cloud_off";
        return "inbox";
    }
    property string title: ""
    property string detail: ""
    property string fontFamily: Theme.fontMenu
    property color accentColor: Theme.accentText
    property color accentFill: Theme.accentBgSoft
    property color outlineColor: Theme.hairlineSoft
    property color primaryTextColor: Theme.textMid
    property color secondaryTextColor: Theme.textDim
    property color errorColor: Theme.redText
    property color errorFill: Theme.redBgSoft
    property color errorOutline: Theme.redBorder
    property int transitionDuration: Theme.expandDuration
    property int fadeDuration: Theme.chipFadeDuration
    property int loadingDuration: 1100

    implicitHeight: shown ? content.implicitHeight + 12 : 0
    visible: shown || opacity > 0.001
    opacity: shown ? 1 : 0
    clip: true

    transform: Translate {
        y: root.shown ? 0 : 8

        Behavior on y {
            NumberAnimation {
                duration: root.transitionDuration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Theme.springCurve
            }
        }
    }

    Behavior on implicitHeight {
        NumberAnimation {
            duration: root.transitionDuration
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Theme.springCurve
        }
    }

    Behavior on opacity {
        NumberAnimation { duration: root.fadeDuration; easing.type: Easing.OutCubic }
    }

    Column {
        id: content

        anchors.centerIn: parent
        width: Math.min(parent.width, 320)
        spacing: Theme.iconTextSpacing

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            // An empty state is a quiet mark and a sentence. The filled,
            // bordered badge it used to draw was the most emphatic thing on a
            // panel that had nothing to say.
            width: Theme.iconHero
            height: Theme.iconHero
            radius: Theme.chipRadius
            color: root.kind === "error" ? root.errorFill : "transparent"
            border.width: root.kind === "error" ? 1 : 0
            border.color: root.errorOutline

            Sym {
                id: statusGlyph
                anchors.centerIn: parent
                name: root.glyph
                size: Theme.iconLarge
                fill: root.kind === "loading" ? 0 : 1
                color: root.kind === "error" ? root.errorColor : root.accentColor

                RotationAnimation on rotation {
                    running: root.shown && root.visible && !Theme.reducedMotion && root.kind === "loading"
                    from: 0
                    to: 360
                    duration: root.loadingDuration
                    loops: Animation.Infinite
                }
            }
        }

        Text {
            visible: text !== ""
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            text: root.title
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            font.family: root.fontFamily
            font.pixelSize: Theme.typography.secondary
            font.weight: Theme.weightSemibold
            color: root.kind === "error" ? root.errorColor : root.primaryTextColor
        }

        Text {
            visible: text !== ""
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            text: root.detail
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
            lineHeight: Theme.proseLineHeight
            font.family: root.fontFamily
            font.pixelSize: Theme.typography.caption
            color: root.secondaryTextColor
        }
    }
}
