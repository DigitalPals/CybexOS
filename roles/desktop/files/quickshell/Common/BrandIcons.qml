pragma Singleton
import QtQuick
import Quickshell

// The allow-list for product marks bundled with the shell.
//
// Generic interface glyphs belong in Sym, and installed applications belong
// to the desktop icon theme. Only an identity that must keep its own mark is
// admitted here. Keeping the filenames behind this boundary also prevents
// provider/service data from becoming an arbitrary asset path.
Singleton {
    id: root

    readonly property var names: [
        "claude", "fedora", "gemini", "github", "grok", "kimi", "openai",
        "slack", "t3", "tailscale", "whatsapp", "youtube"
    ]
    readonly property var files: ({
        claude: "claude.svg",
        fedora: "fedora.svg",
        gemini: "gemini.svg",
        github: "github.svg",
        grok: "grok.svg",
        kimi: "kimi.svg",
        openai: "openai.svg",
        slack: "slack.svg",
        t3: "t3.svg",
        tailscale: "tailscale.svg",
        whatsapp: "whatsapp.svg",
        youtube: "youtube.svg"
    })
    // Hover marks are real SVG paint variants rather than alpha masks.  Their
    // paths and viewBoxes match the canonical files byte-for-byte, which
    // keeps thin outlines (notably OpenAI's) at their original weight.
    readonly property var highlightFiles: ({
        claude: "claude-white.svg",
        fedora: "fedora-white.svg",
        gemini: "gemini-white.svg",
        github: "github-white.svg",
        grok: "grok-white.svg",
        kimi: "kimi-white.svg",
        openai: "openai-white.svg",
        slack: "slack-white.svg",
        // The canonical T3 wordmark is already white.
        t3: "t3.svg",
        tailscale: "tailscale-white.svg",
        whatsapp: "whatsapp-white.svg",
        youtube: "youtube-white.svg"
    })
    readonly property var labels: ({
        claude: "Claude",
        fedora: "Fedora",
        gemini: "Gemini",
        github: "GitHub",
        grok: "Grok",
        kimi: "Kimi",
        openai: "OpenAI",
        slack: "Slack",
        t3: "T3 Code",
        tailscale: "Tailscale",
        whatsapp: "WhatsApp",
        youtube: "YouTube"
    })

    function key(value) {
        return String(value ?? "").trim().toLowerCase();
    }

    function has(value) {
        return names.indexOf(key(value)) >= 0;
    }

    function source(value) {
        const name = key(value);
        return has(name) ? Quickshell.shellDir + "/assets/" + files[name] : "";
    }

    function highlightSource(value) {
        const name = key(value);
        return has(name)
            ? Quickshell.shellDir + "/assets/" + highlightFiles[name] : "";
    }

    function label(value) {
        const name = key(value);
        return has(name) ? labels[name] : "";
    }
}
