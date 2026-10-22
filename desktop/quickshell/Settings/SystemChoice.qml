import QtQuick

// A choice whose value lives in a system service rather than shell.json —
// a sound card's profile, a saved connection. It reads as any other dropdown
// row; there is no stored default, so it never wears the modified mark.
SelectRow {
    property var choices: []

    model: choices
    dirty: false
    resetKeys: []
}
