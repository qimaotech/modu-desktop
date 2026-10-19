#!/usr/bin/env python3
import argparse
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
VERSION = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
REFERENCE = re.compile(
    r" {0,3}\[(?:\\.|[^\[\]\\\n])+\]:[ \t]*(?:\n[ \t]*)?"
    r"(?:<[^<>\n]*>|[^\s<>]+)"
    r"(?:(?=[ \t\n])[ \t]*(?:\n[ \t]*)?"
    r"(?:\"(?:\\.|[^\"\\\n]|\n(?![ \t]*\n))*\""
    r"|'(?:\\.|[^'\\\n]|\n(?![ \t]*\n))*'"
    r"|\((?:\\.|[^()\\\n]|\n(?![ \t]*\n))*\)))?"
    r"[ \t]*(?=\n|$)"
)


def main():
    parser = argparse.ArgumentParser(description="Validate a release tag and extract its CHANGELOG notes.")
    parser.add_argument("tag")
    parser.add_argument("--version-file", type=Path, default=ROOT / "Version.xcconfig")
    parser.add_argument("--changelog", type=Path, default=ROOT / "CHANGELOG.md")
    arguments = parser.parse_args()
    try:
        notes = release_notes(arguments.tag, arguments.version_file.read_text(encoding="utf-8"),
                              arguments.changelog.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError) as error:
        print(f"Release notes failed: {error}", file=sys.stderr)
        return 1
    print(notes)
    return 0


def release_notes(tag, configuration, changelog):
    if not re.fullmatch(rf"v{VERSION}", tag):
        raise ValueError("Expected a release tag in vX.Y.Z format.")
    versions = re.findall(r"^[ \t]*MARKETING_VERSION[ \t]*=[ \t]*([^\r\n]+)", configuration, re.MULTILINE)
    if len(versions) != 1 or versions[0].split("//", 1)[0].strip() != tag[1:]:
        raise ValueError(f"Tag {tag} does not match MARKETING_VERSION in Version.xcconfig.")
    return changelog_section(changelog, tag[1:])


def changelog_section(changelog, version):
    lines = changelog.splitlines()
    visible = without_html_comments(changelog)
    headings = []
    references = []
    fence = None
    offset = 0
    reference_end = 0
    for index, original in enumerate(visible.splitlines(keepends=True)):
        position = offset
        offset += len(original)
        line = original.rstrip("\r\n")
        if index < reference_end:
            continue
        if fence:
            if re.fullmatch(rf" {{0,3}}{re.escape(fence[0])}{{{len(fence)},}}[ \t]*", line):
                fence = None
            continue
        opening = re.match(r" {0,3}(`{3,}|~{3,})", line)
        if opening:
            fence = opening[1]
            continue
        if re.match(r"##[ \t]+", line):
            headings.append((index, line.strip()))
        reference = REFERENCE.match(visible, position)
        if reference:
            reference_end = index + reference[0].count("\n") + 1
            references.append((index, reference_end, changelog[reference.start():reference.end()]))

    pattern = rf"##[ \t]+\[{re.escape(version)}\][ \t]+-[ \t]+\d{{4}}-\d{{2}}-\d{{2}}"
    matches = [position for position, (_, heading) in enumerate(headings) if re.fullmatch(pattern, heading)]
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one CHANGELOG section headed '## [{version}] - YYYY-MM-DD'.")
    position = matches[0]
    start = headings[position][0] + 1
    end = headings[position + 1][0] if position + 1 < len(headings) else len(lines)
    body = "\n".join(lines[start:end]).strip()
    reference_lines = {index for first, last, _ in references for index in range(first, last)}
    if not any(line.strip() and index not in reference_lines and not re.match(r"#{1,6}[ \t]+", line)
               for index, line in enumerate(visible.splitlines()[start:end], start)):
        raise ValueError(f"CHANGELOG section {version} has no release notes.")
    definitions = [definition for first, _, definition in references if not start <= first < end]
    return body + ("\n\n" + "\n".join(definitions) if definitions else "")


def without_html_comments(markdown):
    tokens = re.compile(r"^ {0,3}(?P<fence>`{3,}|~{3,})[^\n]*(?:\n|$)"
                        r"|(?P<code>`+)(?!`)|(?P<comment><!--)", re.MULTILINE)
    visible = list(markdown)
    position = 0
    while token := tokens.search(markdown, position):
        position = token.end()
        if token["fence"]:
            marker = token["fence"]
            closing = re.compile(rf"^ {{0,3}}{re.escape(marker[0])}{{{len(marker)},}}[ \t]*(?:\n|$)", re.MULTILINE)
            end = closing.search(markdown, position)
            position = end.end() if end else len(markdown)
        elif token["code"]:
            paragraph = re.search(r"\n[ \t]*\n", markdown[position:])
            limit = position + paragraph.start() if paragraph else len(markdown)
            closing = re.compile(rf"(?<!`){re.escape(token['code'])}(?!`)")
            end = closing.search(markdown, position, limit)
            if end:
                position = end.end()
        else:
            end = markdown.find("-->", position)
            position = end + 3 if end != -1 else len(markdown)
            for index in range(token.start(), position):
                if markdown[index] not in "\r\n":
                    visible[index] = " "
    return "".join(visible)


if __name__ == "__main__":
    sys.exit(main())
