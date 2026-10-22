pragma Singleton
import QtQuick

// Load once for the entire shell, including plugins. Bundled fonts make
// deployment independent of fontconfig and other installed icon versions.
QtObject {
    readonly property FontLoader outline: FontLoader {
        source: "../assets/tabler/outline.ttf"
    }
    readonly property bool ready: outline.status === FontLoader.Ready
}
