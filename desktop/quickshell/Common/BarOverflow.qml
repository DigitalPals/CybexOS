pragma Singleton
import QtQuick
import Quickshell

// Filled by the More button immediately before opening its popover. This
// avoids one output overwriting another output's responsive overflow list.
Singleton {
    property var items: []
}
