#!/usr/bin/env python3
"""Updates the Skeuo4Ever Cydia repo in the SITE directory (a working copy of the gh-pages branch).

Usage: scripts/make-repo.py [DEBS] [SITE]   (defaults: debs/ and _site/)
S4E_REPO_URL is the repo address, used for the Depiction, Icon and Homepage fields.

Like sqmrak/sqmrakdev, nothing published is ever rewritten:
  * SITE/published.json remembers every released version: file, sha256 and source fingerprint
    (DEBS/sources.json, written by build.sh);
  * the version is already released and the sources are the same: the published file stays and the
    new build is dropped (builds are not byte-for-byte reproducible, and Cydia must not get empty updates);
  * the sources changed but the version did not: error, bump Version in control;
  * old versions stay in the repo, so users can roll back.

Cydia on iOS 6 runs Description through APT's conversion to ASCII, so anything but English turns into
"?". Description is therefore a short English line; the full text lives on the package page
(the Depiction field), which Cydia opens in a browser where UTF-8 works. The page is bilingual:
depictions/<package>.en.txt and depictions/<package>.ru.txt, shown by the system language with a
switch at the top. Icons are icons/<package>.png.
"""

import bz2
import datetime
import gzip
import hashlib
import html
import json
import os
import shutil
import subprocess
import sys
from email.utils import formatdate
from functools import cmp_to_key
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEBS = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "debs"
SITE = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "_site"
REPO_URL = os.environ.get("S4E_REPO_URL", "").rstrip("/")
GENERATED = ["Packages", "Packages.gz", "Packages.bz2", "depictions"]  # Release is written separately

RELEASE_HEADER = """Origin: Skeuo4Ever
Label: Skeuo4Ever
Suite: stable
Version: 1.0
Codename: skeuo4ever
Architectures: iphoneos-arm
Components: main
Description: Modern iOS features, skeuomorphic forever
"""

DEPICTION = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<title>{name}</title>
<link rel="stylesheet" href="../../style.css">
<script src="../../language.js"></script>
</head>
<body>
<div class="page depiction">
<div class="hero" id="hero">{icon}<h1>{name}</h1></div>
<script>
  // Cydia already shows a header with the icon
  if (navigator.userAgent.indexOf("Cydia") >= 0) document.getElementById("hero").style.display = "none";
</script>
<p class="languages"><a href="#" data-lang="en">English</a> · <a href="#" data-lang="ru">Русский</a></p>
<div class="lang-en">
{body_en}
</div>
<div class="lang-ru">
{body_ru}
</div>
<h2><span class="lang-en">Details</span><span class="lang-ru">Подробности</span></h2>
<ul class="group">
<li class="row"><span class="lang-en">Compatibility</span><span class="lang-ru">Совместимость</span><em>iOS 6.0 – 6.1.x</em></li>
<li class="row"><span class="lang-en">Developer</span><span class="lang-ru">Разработчик</span><em>{author}</em></li>
</ul>
<h2><span class="lang-en">Versions</span><span class="lang-ru">Версии</span></h2>
<ul class="group">
{versions}
</ul>
</div>
</body>
</html>
"""


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def control_of(deb: Path) -> str:
    return subprocess.run(["dpkg-deb", "-f", str(deb)], check=True, capture_output=True).stdout.decode("utf-8").strip()


def field(control: str, name: str) -> str:
    for line in control.split("\n"):
        if line.startswith(name + ": "):
            return line[len(name) + 2:]
    return ""


def version_cmp(a: str, b: str) -> int:
    if a == b:
        return 0
    lower = subprocess.run(["dpkg", "--compare-versions", a, "lt", b]).returncode == 0
    return -1 if lower else 1


def render_text(text: str) -> str:
    """Paragraphs become cells, "## Heading" starts a new group, "- item" makes a list."""
    # "20 %" and "6.0 – 6.1" must not break across lines
    text = text.replace(" %", " %").replace(" –", " –")
    out, cells, bullets, paragraph = [], [], [], []

    def flush_paragraph():
        if paragraph:
            cells.append(f"<p>{html.escape(' '.join(paragraph))}</p>")
            paragraph.clear()

    def flush_bullets():
        if bullets:
            cells.append("<ul>" + "".join(f"<li>{html.escape(b)}</li>" for b in bullets) + "</ul>")
            bullets.clear()

    def flush_group():
        flush_paragraph()
        flush_bullets()
        if cells:
            out.append('<div class="group">' + "".join(cells) + "</div>")
            cells.clear()

    for line in text.strip().split("\n"):
        if line.startswith("- "):
            flush_paragraph()
            bullets.append(line[2:])
        elif line.startswith("## "):
            flush_group()
            out.append(f"<h2>{html.escape(line[3:])}</h2>")
        elif line.strip():
            flush_bullets()
            paragraph.append(line.strip())
        else:
            flush_paragraph()
            flush_bullets()
    flush_group()
    return "\n".join(out)


def publish_new(manifest: dict) -> list:
    """Adds new versions to SITE. Returns errors."""
    sources = json.loads((DEBS / "sources.json").read_text())
    today = datetime.date.today().isoformat()
    errors = []
    for deb in sorted(DEBS.glob("*.deb")):
        control = control_of(deb)
        package, version = field(control, "Package"), field(control, "Version")
        source = sources.get(package)
        versions = manifest.setdefault(package, {})
        if version in versions:
            if versions[version]["source"] != source:
                errors.append(f"{package} {version}: the sources changed but this version is already published — "
                              f"bump Version in control")
            continue
        newer = [v for v in versions if version_cmp(version, v) <= 0]
        if newer:
            errors.append(f"{package} {version}: a newer version is already published: {max(newer, key=cmp_to_key(version_cmp))}")
            continue
        target = SITE / "debs" / f"{package}_{version}_iphoneos-arm.deb"
        target.parent.mkdir(exist_ok=True)
        shutil.copy2(deb, target)
        versions[version] = {"file": f"debs/{target.name}", "sha256": sha256(target), "source": source, "date": today}
        print(f"+ {package} {version}")
    return errors


def write_depiction(package: str, control: str, versions: dict) -> dict:
    """The package page and icon. Returns extra fields for Packages."""
    folder = SITE / "depictions" / package
    folder.mkdir(parents=True, exist_ok=True)
    extra = {}
    icon = ROOT / "icons" / f"{package}.png"
    icon_html = ""
    if icon.exists():
        shutil.copy2(icon, folder / "icon.png")
        icon_html = '<img src="icon.png" alt="">'
        if REPO_URL:
            extra["Icon"] = f"{REPO_URL}/depictions/{package}/icon.png"

    def body(language: str) -> str:
        text = ROOT / "depictions" / f"{package}.{language}.txt"
        return render_text(text.read_text(encoding="utf-8")) if text.exists() else ""

    rows = "\n".join(
        f'<li class="row">{html.escape(v)}<em>{html.escape(versions[v]["date"])}</em></li>'
        for v in sorted(versions, key=cmp_to_key(version_cmp), reverse=True)
    )
    page = DEPICTION.format(
        name=html.escape(field(control, "Name") or package),
        icon=icon_html,
        body_en=body("en"),
        body_ru=body("ru") or body("en"),
        author=html.escape(field(control, "Author")),
        versions=rows,
    )
    (folder / "index.html").write_text(page, encoding="utf-8")
    if REPO_URL:
        extra["Depiction"] = f"{REPO_URL}/depictions/{package}/"
        extra["Homepage"] = f"{REPO_URL}/"
    return extra


def main() -> None:
    SITE.mkdir(parents=True, exist_ok=True)
    manifest_path = SITE / "published.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}

    errors = publish_new(manifest)
    for package, versions in manifest.items():
        for version, entry in versions.items():
            path = SITE / entry["file"]
            if not path.exists() or sha256(path) != entry["sha256"]:
                errors.append(f"{package} {version}: the published file {entry['file']} is missing or changed")
    if errors:
        print("\n".join(f"ERROR: {e}" for e in errors), file=sys.stderr)
        sys.exit(1)

    # Regenerate everything derived; debs/ and published.json are left alone
    for name in GENERATED:
        path = SITE / name
        if path.is_dir():
            shutil.rmtree(path)
        elif path.exists():
            path.unlink()
    shutil.copytree(ROOT / "repo", SITE, dirs_exist_ok=True)
    (SITE / ".nojekyll").touch()  # GitHub Pages serves the files as they are

    entries = []
    for package in sorted(manifest):
        versions = manifest[package]
        ordered = sorted(versions, key=cmp_to_key(version_cmp))
        latest_control = control_of(SITE / versions[ordered[-1]]["file"])
        extra = write_depiction(package, latest_control, versions)
        for version in ordered:
            path = SITE / versions[version]["file"]
            data = path.read_bytes()
            fields = [control_of(path), f"Filename: {versions[version]['file']}", f"Size: {len(data)}",
                      f"MD5sum: {hashlib.md5(data).hexdigest()}", f"SHA1: {hashlib.sha1(data).hexdigest()}",
                      f"SHA256: {versions[version]['sha256']}"]
            fields += [f"{key}: {value}" for key, value in extra.items()]
            entries.append("\n".join(fields))

    packages = ("\n\n".join(entries) + "\n").encode("utf-8")
    indexes = {
        "Packages": packages,
        "Packages.gz": gzip.compress(packages, mtime=0),
        "Packages.bz2": bz2.compress(packages),
    }
    for name, data in indexes.items():
        (SITE / name).write_bytes(data)

    checksums = []
    for title, algorithm in (("MD5Sum", hashlib.md5), ("SHA1", hashlib.sha1), ("SHA256", hashlib.sha256)):
        checksums.append(f"{title}:")
        checksums += [f" {algorithm(data).hexdigest()} {len(data)} {name}" for name, data in indexes.items()]
    # The date changes only when the indexes do: otherwise every build would make a gh-pages commit
    release_path = SITE / "Release"
    old_release = release_path.read_text() if release_path.exists() else ""
    if old_release.split("\nDate: ")[0] != RELEASE_HEADER.rstrip("\n") or not old_release.endswith("\n".join(checksums) + "\n"):
        release = [RELEASE_HEADER.rstrip("\n"), f"Date: {formatdate(usegmt=True)}"] + checksums
        release_path.write_text("\n".join(release) + "\n")

    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
    print(f"{sum(len(v) for v in manifest.values())} versions of {len(manifest)} packages → {SITE}")


if __name__ == "__main__":
    main()
