
// Readable names for POSIX locale values ("en_US.UTF-8" is English, United
// States). Names are English source text, translated by I18n.localeName(),
// so the catalog carries the Dutch names. The table covers
// the installer's languages and other common locales; anything else keeps
// its raw value rather than a guess.

var LANGUAGES = {
    ar: "Arabic", bg: "Bulgarian", ca: "Catalan", cs: "Czech", da: "Danish", de: "German",
    el: "Greek", en: "English", es: "Spanish", et: "Estonian", eu: "Basque", fi: "Finnish",
    fr: "French", ga: "Irish", gl: "Galician", he: "Hebrew", hi: "Hindi", hr: "Croatian",
    hu: "Hungarian", id: "Indonesian", is: "Icelandic", it: "Italian", ja: "Japanese",
    ko: "Korean", lt: "Lithuanian", lv: "Latvian", nb: "Norwegian Bokmål", nl: "Dutch",
    nn: "Norwegian Nynorsk", no: "Norwegian", pl: "Polish", pt: "Portuguese", ro: "Romanian",
    ru: "Russian", sk: "Slovak", sl: "Slovenian", sr: "Serbian", sv: "Swedish", th: "Thai",
    tr: "Turkish", uk: "Ukrainian", vi: "Vietnamese", zh: "Chinese"
};
var TERRITORIES = {
    AR: "Argentina", AT: "Austria", AU: "Australia", BE: "Belgium", BG: "Bulgaria", BR: "Brazil",
    CA: "Canada", CH: "Switzerland", CL: "Chile", CN: "China", CO: "Colombia", CZ: "Czechia",
    DE: "Germany", DK: "Denmark", EE: "Estonia", ES: "Spain", FI: "Finland", FR: "France",
    GB: "United Kingdom", GR: "Greece", HK: "Hong Kong", HR: "Croatia", HU: "Hungary",
    ID: "Indonesia", IE: "Ireland", IL: "Israel", IN: "India", IS: "Iceland", IT: "Italy",
    JP: "Japan", KR: "South Korea", LT: "Lithuania", LU: "Luxembourg", LV: "Latvia",
    MX: "Mexico", NL: "Netherlands", NO: "Norway", NZ: "New Zealand", PL: "Poland",
    PT: "Portugal", RO: "Romania", RS: "Serbia", RU: "Russia", SE: "Sweden", SG: "Singapore",
    SI: "Slovenia", SK: "Slovakia", TH: "Thailand", TR: "Turkey", TW: "Taiwan", UA: "Ukraine",
    US: "United States", VN: "Vietnam", ZA: "South Africa"
};

// { language, territory } English names of "ll_TT.codeset@modifier", or
// null when the language is unknown (including C and POSIX). An unknown
// territory leaves `territory` empty.
function names(value) {
    var match = /^([a-z]{2,3})(?:_([A-Z]{2}))?(?:\.[^@]*)?(?:@.*)?$/.exec(String(value || "").trim());
    if (!match || !LANGUAGES.hasOwnProperty(match[1]))
        return null;
    return { language: LANGUAGES[match[1]],
        territory: match[2] && TERRITORIES.hasOwnProperty(match[2]) ? TERRITORIES[match[2]] : "" };
}

var exported = { LANGUAGES: LANGUAGES, TERRITORIES: TERRITORIES, names: names };
if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
