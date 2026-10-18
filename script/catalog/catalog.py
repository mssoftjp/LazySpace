#!/usr/bin/env python3
"""Translation tooling for the String Catalogs (Sources/<Module>/Resources/Localizable.xcstrings).

Run with python3 -I from anywhere:
  catalog.py glossary                      refresh the macOS names in glossary.json from this Mac's macOS 27 tables
  catalog.py fixed <lang>                  write the entries copied from macOS (MacItem names, desktops) and the separators
  catalog.py export <lang> [out]           write a work file for translating <lang> (default translations/<lang>.json)
  catalog.py apply <lang> <file>... [--dry-run]   validate work files, then write only <lang> into the catalogs
  catalog.py verify --base <ref>           English and Japanese are unchanged since <ref>
  catalog.py stale --since <ref> [lang]    entries whose English changed since <ref> while a translation did not
  catalog.py status                        entries each language lacks
  catalog.py selftest                      run the shared argument cases (argument-cases.json)

English is the source and Japanese the owner's translation: no subcommand writes either.
"""
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
MODULES = ["Copy", "Operations", "Settings", "MacSupport", "LazySpaceApp"]
SOURCES = {"en", "ja"}
LANGUAGES = ["en", "de", "es", "fr", "ja", "ko", "pt-BR", "zh-Hans", "zh-Hant"]
TABLE_CODE = {"pt-BR": "pt_BR", "zh-Hans": "zh_CN", "zh-Hant": "zh_TW"}
PLURALS = {"en": {"one", "other"}, "de": {"one", "other"}, "es": {"one", "other"}, "fr": {"one", "other"},
           "pt-BR": {"one", "other"}, "ja": {"other"}, "ko": {"other"}, "zh-Hans": {"other"}, "zh-Hant": {"other"}}
# Values that sit in a column the renderer cuts (CLI.padded): the longest text it keeps, in display columns.
BUDGETS = {"cli.app": 27, "cli.sizeAndPosition": 21}
BUDGET_SUFFIX = {"Syntax": 28}  # cliHelp.*Syntax: the help's command column

EXTENSIONS = Path("/System/Library/ExtensionKit/Extensions")
SETTINGS_APP = Path("/System/Applications/System Settings.app/Contents/Resources")
SHORTCUTS = EXTENSIONS / "KeyboardSettings.appex/Contents/Resources/DefaultShortcutsTable.loctable"
DOCK = Path("/System/Library/CoreServices/Dock.app/Contents/Resources")

# macOS names LazySpace quotes: glossary id -> (table, key). Values are read for every language.
MACOS_NAMES = {
    "missionControl": (EXTENSIONS / "DesktopSettings.appex/Contents/Resources/Localizable.loctable", "Mission Control"),
    "systemSettings": (EXTENSIONS / "TranslationAPIExtension.appex/Contents/Resources/Localizable.loctable", "SYSTEM_SETTINGS"),
    "keyboard": (SETTINGS_APP / "Localizable.loctable", "Keyboard"),
    "keyboardShortcuts": (EXTENSIONS / "KeyboardSettings.appex/Contents/Resources/Localizable.loctable", "Keyboard Shortcuts…"),
    "desktopAndDock": (SETTINGS_APP / "Localizable.loctable", "Desktop & Dock"),
    "privacyAndSecurity": (EXTENSIONS / "SecurityPrivacyExtension.appex/Contents/Resources/InfoPlist.loctable", "CFBundleDisplayName"),
    "general": (SETTINGS_APP / "Localizable.loctable", "General"),
    "notifications": (SETTINGS_APP / "Localizable.loctable", "Notifications"),
    "loginItemsExtensions": (EXTENSIONS / "LoginItems.appex/Contents/Resources/Localizable.loctable", "Login Items & Extensions"),
    "openAtLogin": (EXTENSIONS / "LoginItems.appex/Contents/Resources/Localizable.loctable", "Open at Login"),
    "stageManager": (EXTENSIONS / "DesktopSettings.appex/Contents/Resources/Localizable.loctable", "Stage Manager"),
    "separateSpaces": (EXTENSIONS / "DesktopSettings.appex/Contents/Resources/Localizable.loctable", "Displays have separate Spaces"),
    "autoRearrange": (EXTENSIONS / "DesktopSettings.appex/Contents/Resources/Localizable.loctable",
                      "Automatically rearrange Spaces based on most recent use"),
    "deviceControlAndDataAccess": (EXTENSIONS / "SecurityPrivacyExtension.appex/Contents/Resources/Localizable.loctable", "ACCESSIBILITY"),
    "accessibility": (EXTENSIONS / "LockScreen.appex/Contents/Resources/Localizable.loctable", "Accessibility"),
    "moveLeftASpace": (SHORTCUTS, "Move to previous space"),
    "moveRightASpace": (SHORTCUTS, "Move to next space"),
    "switchToDesktop3": (SHORTCUTS, "Switch to Space 3"),
}
# Copy entries filled from those names. switchToDesktop and desktop are templates with %@ for the number.
COPY_ENTRIES = {
    "copy.accessibility": "accessibility", "copy.deviceControlAndDataAccess": "deviceControlAndDataAccess",
    "copy.loginItemsExtensions": "loginItemsExtensions", "copy.openAtLogin": "openAtLogin", "copy.stageManager": "stageManager",
    "copy.separateSpaces": "separateSpaces", "copy.moveLeftASpace": "moveLeftASpace", "copy.moveRightASpace": "moveRightASpace",
}
SPEC = re.compile(r"%(?:(\d+)\$)?(lld|llu|ld|lu|lf|d|u|f|@)|%#@([A-Za-z0-9_]+)@|%arg|%%|%")
KINDS = {"lld": "int", "ld": "int", "d": "int", "llu": "uint", "lu": "uint", "u": "uint", "lf": "double", "f": "double", "@": "object"}


# ------------------------------------------------------------------ catalogs


def catalog_path(module):
    return ROOT / "Sources" / module / "Resources" / "Localizable.xcstrings"


def load(module):
    return json.loads(catalog_path(module).read_text(encoding="utf-8"))


def dump(catalog):
    return json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : ")) + "\n"


def save(module, catalog):
    catalog_path(module).write_text(dump(catalog), encoding="utf-8")


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def plain(localization):
    """A localization as a work-file value: a string, or {"value", "plural", "substitutions"}."""
    if localization is None:
        return None
    out = {}
    if "stringUnit" in localization:
        out["value"] = localization["stringUnit"]["value"]
    if "variations" in localization:
        out["plural"] = {c: f["stringUnit"]["value"] for c, f in localization["variations"]["plural"].items()}
    if "substitutions" in localization:
        out["substitutions"] = {n: {c: f["stringUnit"]["value"] for c, f in s["variations"]["plural"].items()}
                                for n, s in localization["substitutions"].items()}
    return out["value"] if set(out) == {"value"} else out


def build(value, english):
    """A catalog localization from a work-file value; substitution numbers and types come from English."""
    if isinstance(value, str):
        return unit(value)
    if not isinstance(value, dict) or not set(value) <= {"value", "plural", "substitutions"}:
        raise ValueError("a value is a string or an object with value, plural, substitutions")
    out = {}
    if "value" in value:
        out.update(unit(value["value"]))
    if "plural" in value:
        out["variations"] = {"plural": {c: unit(t) for c, t in value["plural"].items()}}
    if "substitutions" in value:
        subs = {}
        for name, forms in value["substitutions"].items():
            source = english.get("substitutions", {}).get(name)
            if source is None:
                raise ValueError(f"substitution {name!r} is not in English")
            subs[name] = {"argNum": source["argNum"], "formatSpecifier": source["formatSpecifier"],
                          "variations": {"plural": {c: unit(t) for c, t in forms.items()}}}
        out["substitutions"] = subs
    return out


# ------------------------------------------------------------------ arguments (same rules as CatalogTests)


def tokens(text, in_substitution=False):
    """(kind, payload) for every format token; kind is plain, substitution, arg, or bad."""
    out, number = [], 0
    for m in SPEC.finditer(text):
        token = m.group(0)
        if token == "%%":
            continue
        if token == "%arg":
            out.append(("arg", None) if in_substitution else ("bad", token))
        elif m.group(3):
            out.append(("substitution", m.group(3)))
        elif m.group(2):
            if m.group(1):
                index = int(m.group(1))
            else:
                number += 1
                index = number
            out.append(("plain", f"{index}:{KINDS[m.group(2)]}"))
        else:
            out.append(("bad", text[m.start():m.start() + 4]))
    return out


def argument_use(localization):
    """(shown, selectors, bad): arguments a localization shows, counts that only choose a plural form, malformed tokens."""
    subs = localization.get("substitutions", {})
    values = []
    if "stringUnit" in localization:
        values.append(localization["stringUnit"]["value"])
    values += [f["stringUnit"]["value"] for f in localization.get("variations", {}).get("plural", {}).values()]
    shown, selectors, bad = set(), set(), []
    for value in values:
        for kind, payload in tokens(value):
            if kind == "plain":
                shown.add(payload)
            elif kind == "bad":
                bad.append(payload)
            elif kind == "substitution":
                s = subs.get(payload)
                if s is None:
                    bad.append(f"%#@{payload}@ without a substitution")
                    continue
                argument = f"{s['argNum']}:{KINDS.get(s['formatSpecifier'], '?')}"
                forms = [f["stringUnit"]["value"] for f in s["variations"]["plural"].values()]
                displays = False
                for form in forms:
                    for k, p in tokens(form, in_substitution=True):
                        if k == "arg":
                            displays = True
                        elif k == "plain":
                            shown.add(p)
                        elif k in ("bad", "substitution"):
                            bad.append(p if k == "bad" else f"%#@{p}@ inside a substitution")
                (shown if displays else selectors).add(argument)
    return shown, selectors - shown, bad


def argument_problem(english, other):
    expected_shown, expected_selectors, _ = argument_use(english)
    shown, selectors, bad = argument_use(other)
    problems = [f"malformed {b!r}" for b in bad]
    if expected_shown - shown:
        problems.append(f"does not show {sorted(expected_shown - shown)}")
    if (shown | selectors) - (expected_shown | expected_selectors):
        problems.append(f"uses arguments English lacks {sorted((shown | selectors) - (expected_shown | expected_selectors))}")
    return problems


def plural_problems(localization, lang):
    required = PLURALS[lang]
    groups = []
    if "variations" in localization:
        groups.append(("plural", localization["variations"]["plural"]))
    groups += [(n, s["variations"]["plural"]) for n, s in localization.get("substitutions", {}).items()]
    return [f"{label} lacks {sorted(required - set(forms))}" for label, forms in groups if required - set(forms)]


def texts(localization):
    out = []
    if "stringUnit" in localization:
        out.append(localization["stringUnit"]["value"])
    out += [f["stringUnit"]["value"] for f in localization.get("variations", {}).get("plural", {}).values()]
    for s in localization.get("substitutions", {}).values():
        out += [f["stringUnit"]["value"] for f in s["variations"]["plural"].values()]
    return out


def width(text):
    import unicodedata
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in text)


def budget(key):
    if key in BUDGETS:
        return BUDGETS[key]
    for suffix, columns in BUDGET_SUFFIX.items():
        if key.startswith("cliHelp.") and key.endswith(suffix):
            return columns
    return None


# ------------------------------------------------------------------ glossary


def glossary_path():
    return HERE / "glossary.json"


def load_glossary():
    return json.loads(glossary_path().read_text(encoding="utf-8"))


def table(path):
    return plistlib.loads(Path(path).read_bytes())


def macos_value(name, lang):
    path, key = MACOS_NAMES[name]
    return table(path)[TABLE_CODE.get(lang, lang)][key]


def dock_desktop(lang):
    strings = plistlib.loads((DOCK / f"{TABLE_CODE.get(lang, lang)}.lproj" / "Localizable.strings").read_bytes())
    return strings["DesktopNum"]


def refresh_glossary():
    glossary = load_glossary()
    names = {}
    for name in MACOS_NAMES:
        names[name] = {lang: macos_value(name, lang) for lang in LANGUAGES}
    names["desktop"] = {lang: dock_desktop(lang) for lang in LANGUAGES}
    glossary["macosNames"] = names
    # Where each name comes from, so the tests compare the catalogs with macOS itself rather than with this file.
    glossary["macosSources"] = {name: [str(path), key] for name, (path, key) in MACOS_NAMES.items()}
    glossary["macosSources"]["desktop"] = [str(DOCK / "<lproj>.lproj" / "Localizable.strings"), "DesktopNum"]
    glossary["tableCodes"] = TABLE_CODE
    glossary_path().write_text(json.dumps(glossary, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"{len(names)} macOS names for {len(LANGUAGES)} languages")


# ------------------------------------------------------------------ writing


def only_target_changes(before, after, lang):
    """Every entry's other localizations, comment, and state are unchanged; nothing is added or removed."""
    problems = []
    for module in MODULES:
        old, new = before[module]["strings"], after[module]["strings"]
        if set(old) != set(new):
            problems.append(f"{module}: entries added or removed")
            continue
        for key in old:
            a, b = dict(old[key]), dict(new[key])
            la, lb = dict(a.pop("localizations")), dict(b.pop("localizations"))
            la.pop(lang, None)
            lb.pop(lang, None)
            if a != b or la != lb:
                problems.append(f"{module}/{key}: more than {lang} changed")
    return problems


def write_language(lang, values, dry_run=False):
    """values: {(module, key): localization}. Validates against English, then writes only lang (nothing with dry_run)."""
    if lang in SOURCES or lang not in PLURALS:
        sys.exit(f"catalog: refusing to write {lang!r}")
    before = {m: load(m) for m in MODULES}
    after = json.loads(json.dumps(before))
    errors = []
    for (module, key), localization in values.items():
        entry = after.get(module, {}).get("strings", {}).get(key)
        if entry is None:
            errors.append(f"{module}/{key}: no such entry")
            continue
        english = entry["localizations"]["en"]
        problems = argument_problem(english, localization) + plural_problems(localization, lang)
        separator = key.endswith("Separator")
        for text in texts(localization):
            if not separator and (not text or text != text.strip()):
                problems.append(f"empty or surrounded by whitespace: {text!r}")
            limit = budget(key)
            if limit is not None and width(text) > limit:
                problems.append(f"{width(text)} columns, over {limit}")
        if problems:
            errors.append(f"{module}/{key}: " + "; ".join(problems))
            continue
        entry["localizations"][lang] = localization
    errors += only_target_changes(before, after, lang)
    if errors:
        print("\n".join(errors))
        sys.exit(f"catalog: {len(errors)} problems; nothing written")
    if dry_run:
        print(f"{len(values)} {lang} values valid (dry run, nothing written)")
        return
    for module in MODULES:
        if after[module] != before[module]:
            save(module, after[module])
    print(f"{len(values)} {lang} values written")


def fixed(lang):
    glossary = load_glossary()
    names = glossary["macosNames"]
    values = {("Copy", key): unit(names[name][lang]) for key, name in COPY_ENTRIES.items()}
    # Pre-15 "Login Items" cannot be read on macOS 27; the glossary keeps it.
    values[("Copy", "copy.loginItems")] = unit(glossary["fixed"]["loginItems"][lang])
    switch = names["switchToDesktop3"][lang].replace("3", "%@", 1)
    if lang == "ko":
        # macOS varies the particle by the number's sound; after an unknown value Apple writes (으)로.
        switch = re.sub(r"%@(으로|로)", "%@(으)로", switch)
    values[("Copy", "copy.switchToDesktop")] = unit(switch)
    values[("Copy", "copy.desktop")] = unit(names["desktop"][lang])
    for key, per_language in glossary["fixed"].items():
        if key.startswith("copy.") or key.startswith("settings."):
            module = "Copy" if key.startswith("copy.") else "LazySpaceApp"
            values[(module, key)] = unit(per_language[lang])
    write_language(lang, values)


def export(lang, out):
    glossary = load_glossary()
    terms = glossary.get("terms", [])
    uses = usage_lines()
    rows = {}
    for module in MODULES:
        for key, entry in sorted(load(module)["strings"].items()):
            loc = entry["localizations"]
            en = plain(loc["en"])
            english_text = " ".join(texts(loc["en"]))
            found = {t["concept"]: t[lang] for t in terms if lang in t and re.search(t["match"], english_text, re.I)}
            found.update({names["en"]: names[lang] for names in glossary["macosNames"].values() if names["en"] in english_text})
            rows[f"{module}/{key}"] = {
                "comment": entry.get("comment"), "used": uses.get((module, symbol(key)), []), "en": en, "ja": plain(loc.get("ja")),
                "required_plural_categories": sorted(PLURALS[lang]), "terms": found, "budget": budget(key),
                lang: plain(loc.get(lang)),
            }
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    Path(out).write_text(json.dumps(rows, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{len(rows)} entries -> {out}")


def apply(lang, files, dry_run=False):
    values = {}
    for file in files:
        for qualified, row in json.loads(Path(file).read_text(encoding="utf-8")).items():
            value = row.get(lang) if isinstance(row, dict) and ("en" in row or lang in row) else row
            if value is None:
                continue
            module, key = qualified.split("/", 1)
            entry = load_cached(module)["strings"].get(key)
            if entry is None:
                sys.exit(f"catalog: {qualified}: no such entry")
            try:
                values[(module, key)] = build(value, entry["localizations"]["en"])
            except ValueError as error:
                sys.exit(f"catalog: {qualified}: {error}")
    write_language(lang, values, dry_run)


_cache = {}


def load_cached(module):
    if module not in _cache:
        _cache[module] = load(module)
    return _cache[module]


def symbol(key):
    parts = [p for p in re.split(r"[.\-_]", key) if p]
    name = "".join(p[:1].upper() + p[1:] for p in parts)
    return name[:1].lower() + name[1:]


def usage_lines():
    found = {}
    for module in MODULES:
        for file in sorted((ROOT / "Sources" / module).glob("*.swift")):
            for number, line in enumerate(file.read_text(encoding="utf-8").split("\n"), 1):
                for m in re.finditer(r"\.([a-z][A-Za-z0-9]*)\b", line):
                    lines = found.setdefault((module, m.group(1)), [])
                    if len(lines) < 2:
                        lines.append(f"{file.name}:{number}: {line.strip()[:220]}")
    return found


def at(ref, module):
    path = catalog_path(module).relative_to(ROOT)
    text = subprocess.run(["git", "-C", str(ROOT), "show", f"{ref}:{path}"], capture_output=True, text=True, check=True).stdout
    return json.loads(text)


def verify(base):
    problems = []
    for module in MODULES:
        old, new = at(base, module)["strings"], load(module)["strings"]
        for key in set(old) | set(new):
            for lang in sorted(SOURCES):
                a = old.get(key, {}).get("localizations", {}).get(lang)
                b = new.get(key, {}).get("localizations", {}).get(lang)
                if a != b:
                    problems.append(f"{module}/{key} [{lang}] changed since {base}")
    print("\n".join(problems) if problems else f"English and Japanese are unchanged since {base}")
    sys.exit(1 if problems else 0)


def stale(since, only):
    out = {}
    for module in MODULES:
        old, new = at(since, module)["strings"], load(module)["strings"]
        for key, entry in new.items():
            before = old.get(key, {}).get("localizations", {})
            loc = entry["localizations"]
            if key not in old or before.get("en") == loc["en"]:
                continue
            for lang in LANGUAGES:
                if lang in SOURCES or (only and lang != only) or lang not in loc:
                    continue
                if before.get(lang) == loc[lang]:
                    out.setdefault(lang, []).append(f"{module}/{key}")
    for lang, keys in sorted(out.items()):
        print(f"{lang}: {len(keys)} stale\n  " + "\n  ".join(keys))
    if not out:
        print(f"no translation is older than its English since {since}")


def status():
    langs = [l for l in LANGUAGES]
    missing = {l: 0 for l in langs}
    total = 0
    for module in MODULES:
        for entry in load(module)["strings"].values():
            total += 1
            for l in langs:
                missing[l] += l not in entry["localizations"]
    print(f"{total} entries; missing " + ", ".join(f"{l} {missing[l]}" for l in langs))


def selftest():
    cases = json.loads((HERE / "argument-cases.json").read_text(encoding="utf-8"))
    failures = 0
    for case in cases:
        problems = argument_problem(case["english"], case["other"])
        if bool(problems) == case["ok"]:
            failures += 1
            print(f"FAIL {case['name']}: {problems}")
    print(f"{len(cases) - failures}/{len(cases)} argument cases pass")
    sys.exit(1 if failures else 0)


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return
    command, rest = argv[0], argv[1:]
    if command == "glossary":
        refresh_glossary()
    elif command == "fixed":
        fixed(rest[0])
    elif command == "export":
        export(rest[0], rest[1] if len(rest) > 1 else str(ROOT / "translations" / f"{rest[0]}.json"))
    elif command == "apply":
        apply(rest[0], [r for r in rest[1:] if r != "--dry-run"], "--dry-run" in rest)
    elif command == "verify":
        verify(rest[rest.index("--base") + 1])
    elif command == "stale":
        stale(rest[rest.index("--since") + 1], next((r for r in rest if not r.startswith("--") and r != rest[rest.index("--since") + 1]), None))
    elif command == "status":
        status()
    elif command == "selftest":
        selftest()
    else:
        sys.exit(f"catalog: unknown command {command!r}")


if __name__ == "__main__":
    main(sys.argv[1:])
