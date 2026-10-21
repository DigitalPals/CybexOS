// Adapted from Omarchy v4.5.0-rc1 Detect.js and Security.js,
// 03ff1eff3812933f7088484533784d2f63eaf19a. Engine originally Omapager,
// Copyright (c) 2026 Neil Jagdish Patel. See docs/desktop-notifications.md.
/*
Copyright (c) David Heinemeier Hansson

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/
var MAX_APP_NAME=256, MAX_SUMMARY=2048, MAX_BODY=32768
var MAX_ACTIONS=16, MAX_ACTION_LABEL=256, MAX_ACTION_ID=256, MAX_SOURCE=253
var MAX_URL=4096, MAX_CODES=8, MAX_PHONE=64
function bounded(value, max) { return typeof value === 'string' ? value.slice(0,max) : '' }
function containsControlChars(s) { return /[\x00-\x20\x7f-\x9f\\]/.test(s) }
function canonicalHostname(raw) {
  if (typeof raw !== 'string' || raw.length > MAX_SOURCE) return ''
  var h=raw.toLowerCase().replace(/\.$/,'')
  if (!/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/.test(h)) return ''
  // WHATWG parses a numeric-looking last label (decimal, octal, 0x hex) as an
  // IPv4 address, so "0x7f.0x0.0x0.0x1" would reach 127.0.0.1.
  if (/^(?:0x[0-9a-f]*|[0-9]+)$/i.test(h.split('.').pop())) return ''
  return h
}
function urlHasUserInfo(s) { return /^[a-z]+:\/\/[^/?#]*@/i.test(s) }
function safeHttpUrl(raw) {
  if (typeof raw !== 'string' || raw.length > MAX_URL || containsControlChars(raw) || /[^\x21-\x7e]/.test(raw)) return ''
  // Reject nested escapes and encoded controls; never decode and re-authorize.
  if (/%(?:0[0-9a-f]|1[0-9a-f]|7f|25|5c)/i.test(raw) || /[<>"']/.test(raw)) return ''
  var m=raw.match(/^(https?):\/\/([^/?#]+)([^]*)$/i)
  if (!m || urlHasUserInfo(raw)) return ''
  var a=m[2].match(/^([^:%@]+)(?::([0-9]{1,5}))?$/)
  if (!a) return ''
  var h=canonicalHostname(a[1])
  if (!h || (a[2] && (+a[2]<1 || +a[2]>65535))) return ''
  // Invalid escapes can acquire different meaning in different URL handlers.
  if (/%(?![0-9a-f]{2})/i.test(m[3])) return ''
  return m[1].toLowerCase()+'://'+h+(a[2]?':'+String(+a[2]):'')+(m[3]||'/')
}
function safeMailtoUrl(raw) {
  if (typeof raw !== 'string' || raw.length > MAX_URL || containsControlChars(raw) || /[^\x21-\x7e]/.test(raw)) return ''
  // One address only: no headers, attachments, percent encoding or URI queries.
  var m=raw.match(/^mailto:([a-z0-9.!#$&'*+\/=?^_`{|}~-]{1,64})@([^?\/#]+)$/i)
  if (!m || /[?#]/.test(m[1])) return ''
  var h=canonicalHostname(m[2]); return h ? 'mailto:'+m[1]+'@'+h : ''
}
function safeExternalUrl(raw) { return /^mailto:/i.test(raw) ? safeMailtoUrl(raw) : safeHttpUrl(raw) }
function hostOf(raw) {
  var u=safeHttpUrl(raw), m=u.match(/^https?:\/\/([^/:?#]+)/)
  return m ? m[1] : ''
}
var CODE_WORDS = /\b(verificatiecode|beveiligingscode|inlogcode|bevestigingscode|toegangscode|pincode|code|otp|one[\s-]?time|verification|verify|passcode|pin|2fa|two[\s-]factor|security key|confirm(?:ation)?)\b/i

// "482913", "482 913", "84 2139", "482-913", "G-482913".
var CODE_SHAPE = /(?:^|[^\w-])((?:[A-Za-z]-)?\d{2,4}[\s-]\d{2,5}|(?:[A-Za-z]-)?\d{4,8})(?![\w-])/g

// Uppercase alphanumeric with at least one digit and one letter: "A9F3K2".
var CODE_ALNUM = /(?:^|[^\w-])([A-Z0-9]{5,8})(?![\w-])/g

// The code must sit near its keyword, or "Claude Code" would offer the next
// build number in the body.
var NEAR_BEFORE = 24
var NEAR_AFTER = 72

// "Claude Code", "VS Code": a capitalised word before a capitalised "Code" is
// a product name. "use code SAVE20" and "Your Verification Code" are not.
function isProductName(t, at, word) {
  if (String(word).toLowerCase() !== "code") return false
  if (word[0] !== word[0].toUpperCase()) return false
  var before = t.slice(Math.max(0, at - 20), at).match(/([A-Za-z][\w.]*)\s+$/)
  if (!before || !/^([A-Z][a-z]+|[A-Z]{2,})$/.test(before[1])) return false
  return !CODE_WORDS.test(before[1])
}

function windows(t) {
  var out = [], m
  var re = new RegExp(CODE_WORDS.source, "gi")
  while ((m = re.exec(t)) !== null) {
    if (!isProductName(t, m.index, m[0]))
      out.push([Math.max(0, m.index - NEAR_BEFORE), m.index + m[0].length + NEAR_AFTER])
    if (re.lastIndex === m.index) re.lastIndex++
  }
  return out.slice(0, MAX_CODES)
}

function harvest(t, re, seen, out, keep) {
  var m
  re.lastIndex = 0
  while ((m = re.exec(t)) !== null) {
    var value = keep(m[1])
    if (!value || seen[value]) continue
    seen[value] = true
    out.push(value)
  }
}

function codes(text) {
  var t = bounded(text, MAX_BODY)
  var spans = windows(t)
  if (!spans.length) return []

  var out = [], seen = {}
  for (var i = 0; i < spans.length; i++) {
    harvest(t.slice(spans[i][0], spans[i][1]), CODE_SHAPE, seen, out, function (raw) {
      var value = raw.replace(/^[A-Za-z]-/, "").replace(/[\s-]/g, "")
      if (value.length < 4 || value.length > 8) return ""
      if (/^(19|20)\d\d$/.test(value)) return ""      // a year
      return value
    })
  }
  if (out.length) return out.slice(0, MAX_CODES)

  for (var j = 0; j < spans.length; j++) {
    harvest(t.slice(spans[j][0], spans[j][1]), CODE_ALNUM, seen, out, function (raw) {
      // Needs both a digit and a letter, or it is a word in caps.
      return (/\d/.test(raw) && /[A-Z]/.test(raw)) ? raw : ""
    })
  }
  return out.slice(0, MAX_CODES)
}

function links(text) {
  var out = [], seen = {}, m
  var re = /(https?:\/\/[^\s<>"']+)/g
  while ((m = re.exec(bounded(text, MAX_BODY))) !== null) {
    // Trailing punctuation belongs to the sentence, not the URL.
    var url = safeHttpUrl(m[1].replace(/[.,;:!?)\]}'"]+$/, ""))
    if (!url || seen[url]) continue
    seen[url] = true
    out.push(url)
  }
  return out.slice(0, MAX_CODES)
}


// Decode nested entity escapes for detection only. Display text remains plain.
function detectionText(value) {
    var text = bounded(value, MAX_BODY);
    for (var i = 0; i < 3; i++) {
        text = text.replace(/&#(x[0-9a-f]+|[0-9]+);/gi, function(_, n) {
            var hex = n.charAt(0).toLowerCase() === "x";
            var cp = parseInt(hex ? n.slice(1) : n, hex ? 16 : 10);
            return cp > 0 && cp <= 0x10ffff ? String.fromCodePoint(cp) : "";
        }).replace(/&amp;/gi, "&").replace(/&lt;/gi, "<")
          .replace(/&gt;/gi, ">").replace(/&quot;/gi, '"').replace(/&nbsp;/gi, " ");
    }
    return text.replace(/<[^>]*>/g, " ").replace(/[\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]/g, "")
        .replace(/\s+/g, " ");
}
function scan(summary, body) {
    var text = detectionText(bounded(summary, MAX_SUMMARY) + "\n" + bounded(body, MAX_BODY));
    return { codes: codes(text), links: links(text) };
}
function persistable(row) {
    // Whitelist rather than copying the live row: no hints, raw text, images,
    // URLs, fingerprints, executable payloads or QObject/action references.
    var candidates = [row.appName, row.desktopEntry, row.webOrigin, row.summary,
        row.body, row.displayAppName, row.displaySummary, row.displayBody];
    var sensitive = row.codes && row.codes.length > 0;
    var keyword = false, shape = false;
    for (var i = 0; i < candidates.length; i++) {
        var candidate = detectionText(candidates[i]);
        sensitive = sensitive || codes(candidate).length > 0;
        keyword = keyword || CODE_WORDS.test(candidate);
        shape = shape || new RegExp(CODE_SHAPE.source).test(candidate)
            || new RegExp(CODE_ALNUM.source).test(candidate);
    }
    // Storage errs toward redaction even when a keyword and token sit in
    // separate fields, farther apart than the copy detector's proximity gate.
    sensitive = sensitive || (keyword && shape);
    var out = { arrived: row.lastArrived || row.arrived,
        urgency: row.urgency, occurrences: row.occurrences || 1 };
    if (sensitive || row.redacted) {
        out.appName = "Notification";
        out.desktopEntry = "";
        out.webOrigin = "";
        out.displayAppName = "Notification";
        out.displaySummary = "Verification notification";
        out.displayBody = "Content redacted";
    } else {
        out.appName = bounded(row.appName, 256);
        out.desktopEntry = bounded(row.desktopEntry, 256);
        out.webOrigin = bounded(row.webOrigin, 253);
        out.displayAppName = bounded(row.displayAppName, 256);
        out.displaySummary = bounded(row.displaySummary, 2048);
        out.displayBody = bounded(row.displayBody, 4096);
    }
    return out;
}
var MAX_IMAGE_PATH = 1024
var KERNEL_PATHS = /^\/(?:proc|sys|dev)(?:\/|$)/
var RUN_PATHS = /^\/(?:var\/)?run(?:\/|$)/
function localImagePath(raw) {
  var text = typeof raw === "string" && raw.length <= MAX_IMAGE_PATH * 3 ? raw : ""
  if (text.indexOf("image://icon/") === 0) text = text.slice("image://icon/".length)
  if (/^file:\/\//i.test(text)) {
    if (!/^file:\/\/\//i.test(text) || /[?#]/.test(text)) return ""
    try { text = decodeURIComponent(text.slice("file://".length)) } catch (e) { return "" }
  }
  if (!text || text.length > MAX_IMAGE_PATH || text.charAt(0) !== "/" || /[\x00-\x1f\x7f-\x9f]/.test(text)) return ""
  // One spelling per file: no empty, `.` or `..` segment.
  var parts = text.slice(1).split("/")
  for (var i = 0; i < parts.length; i++)
    if (parts[i] === "" || parts[i] === "." || parts[i] === "..") return ""
  if (KERNEL_PATHS.test(text)) return ""
  // /run holds sockets and other services' state; only a runtime dir, which
  // only its owner can read, keeps images there.
  if (RUN_PATHS.test(text) && !/^\/run\/user\/[0-9]+\/./.test(text)) return ""
  return text
}

// The file:// URL Qt loads a local image path from, each segment escaped.
function localImageUrl(path) {
  var text = localImagePath(path)
  return text ? "file://" + text.split("/").map(encodeURIComponent).join("/") : ""
}

if (typeof module !== "undefined" && module.exports)
    module.exports = { safeHttpUrl: safeHttpUrl, safeExternalUrl: safeExternalUrl,
        canonicalHostname: canonicalHostname, localImageUrl: localImageUrl, detectionText: detectionText,
        codes: codes, links: links, scan: scan, persistable: persistable };
