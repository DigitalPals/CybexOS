import QtQuick
import "../Common"

// Product geometry presented as menubar furniture. BrandIcon keeps canonical
// paint for content identities elsewhere; this boundary makes every service
// and shell identity in the bar follow the same resting and hover ink as the
// generic Tabler glyphs beside it. Starting from the white paint variant
// prevents MultiEffect from scaling the tint by each brand's source luminance.
BrandIcon {
    colorized: true
    tint: Theme.barIcon
    normalizeTintSource: true
}
