import QtQuick
import Quickshell
import "Common"
import "Bar"

ShellRoot {
    id: root
    UserWidgetHost {
        id: host
        descriptor: ({id:"qualification.widget", source:"", error:"", settings:{}, width:120})
        width: 120
        height: 30
        screenName: "qualification"
        themeValues: ({foreground:"#ffffff", background:"#000000", accent:"#00ff00", fontFamily:"sans-serif", fontSize:13, reducedMotion:true})
    }
    Timer {
        interval: 1000; running: true
        onTriggered: {
            if (typeof UserPlugins.plugins !== "undefined" && typeof OmarchyPlugins.records !== "undefined") {
                console.warn("CYBEXOS_DESKTOP_CHECK_PASS");
                Qt.quit();
            }
        }
    }
}
