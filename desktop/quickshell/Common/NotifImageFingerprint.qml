// Fixed-URL optional wrapper: source-only previews may lack the native module.
import QtQml
import NerdOS.Images 1.0

QtObject {
    readonly property string error: ImageFingerprints.error
    function fingerprint(source: string): string {
        return ImageFingerprints.fingerprint(source);
    }
}
