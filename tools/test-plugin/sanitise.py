#!/usr/bin/env python3
"""Regenerate a sanitised fixture HTML from a source page.

The repo NEVER contains real bank-page data. Every fixture under
`tools/test-plugin/fixtures/<host>/` is a heavy regeneration of a
source page that lives only on the contributor's local machine
(typically `~/Downloads/Moolah Sites/`).

The redaction is config-driven (per-fixture `<scenario>.sanitise.yml`)
on top of a baseline of removal rules that apply to every fixture.

Usage:
    python3 tools/test-plugin/sanitise.py <fixture-dir>/<scenario>.sanitise.yml

The script reads the config, opens the source HTML it points at, walks
the DOM, applies the rules, and writes
`<fixture-dir>/<scenario>.html` next to the config.

This is a stand-alone tool. It only uses the Python stdlib (xml + html
parsers) and a hand-rolled tiny YAML reader. No pip install required.
"""
from __future__ import annotations

import argparse
import hashlib
import html
import os
import random
import re
import sys
from dataclasses import dataclass, field
from html.parser import HTMLParser
from pathlib import Path
from typing import Iterable

# --------------------------------------------------------------------------
# Tiny YAML subset
# --------------------------------------------------------------------------
# Supported shapes:
#   key: scalar
#   key: "scalar with spaces"
#   key:
#     - item
#     - item
# That covers everything sanitise configs need. Comments (`# ...`) and
# blank lines are ignored. We deliberately do not depend on PyYAML.


def parse_minimal_yaml(text: str) -> dict:
    result: dict[str, object] = {}
    current_list: list[str] | None = None
    current_key: str | None = None
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        if line.startswith("  - "):
            if current_list is None:
                raise ValueError(f"list item without parent key: {raw!r}")
            current_list.append(_unquote(line[4:].strip()))
            continue
        if line.startswith(" ") or line.startswith("\t"):
            raise ValueError(f"unexpected indent: {raw!r}")
        key, _, value = line.partition(":")
        key = key.strip()
        value = value.strip()
        if value == "":
            current_list = []
            result[key] = current_list
            current_key = key
        else:
            result[key] = _unquote(value)
            current_list = None
            current_key = key
    return result


def _unquote(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        return value[1:-1]
    return value


# --------------------------------------------------------------------------
# Sanitise config
# --------------------------------------------------------------------------


@dataclass
class SanitiseConfig:
    source: str
    seed: int = 42
    synthetic_url: str = ""
    keep_classes: list[str] = field(default_factory=list)
    merchant_selectors: list[str] = field(default_factory=list)
    amount_selectors: list[str] = field(default_factory=list)
    date_selectors: list[str] = field(default_factory=list)
    account_hint_selectors: list[str] = field(default_factory=list)
    strip_selectors: list[str] = field(default_factory=list)
    keep_attributes: list[str] = field(default_factory=list)

    @classmethod
    def from_dict(cls, data: dict, config_dir: Path) -> "SanitiseConfig":
        def as_list(key: str) -> list[str]:
            value = data.get(key, [])
            if isinstance(value, list):
                return [str(v) for v in value]
            return [str(value)] if value else []

        source = str(data.get("source", "")).strip()
        if not source:
            raise ValueError(f"sanitise config {config_dir} missing 'source'")
        source_path = os.path.expanduser(source)
        if not os.path.isabs(source_path):
            source_path = str((config_dir / source_path).resolve())
        return cls(
            source=source_path,
            seed=int(data.get("seed", 42)),
            synthetic_url=str(data.get("synthetic_url", "")).strip(),
            keep_classes=as_list("keep_classes"),
            merchant_selectors=as_list("merchant_selectors"),
            amount_selectors=as_list("amount_selectors"),
            date_selectors=as_list("date_selectors"),
            account_hint_selectors=as_list("account_hint_selectors"),
            strip_selectors=as_list("strip_selectors"),
            keep_attributes=as_list("keep_attributes"),
        )


# --------------------------------------------------------------------------
# Minimal HTML DOM
# --------------------------------------------------------------------------


# Void elements that don't take a closing tag.
VOID_ELEMENTS = {
    "area", "base", "br", "col", "embed", "hr", "img", "input",
    "link", "meta", "param", "source", "track", "wbr",
}

# Tags whose entire subtree is dropped regardless of config.
ALWAYS_STRIPPED_TAGS = {
    "script", "style", "noscript", "svg", "img", "iframe", "object",
    "embed", "link", "meta", "video", "audio", "canvas", "picture", "source",
}

# Attributes that are stripped from every element regardless of config.
ALWAYS_STRIPPED_ATTRS = {
    "id", "name", "style", "srcset", "formaction", "background",
    "onclick", "onchange", "onload", "onerror", "onfocus", "onblur",
    "onsubmit", "tabindex",
}

# Attributes that are safe to keep verbatim if the value is short.
SAFE_ATTRS = {"class", "scope", "type", "role", "alt", "aria-hidden", "data-text-align"}


@dataclass
class Node:
    tag: str
    attrs: dict[str, str] = field(default_factory=dict)
    children: list = field(default_factory=list)  # list[Node | str]
    is_void: bool = False


class DOMBuilder(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=False)
        self.root = Node(tag="#document")
        self.stack: list[Node] = [self.root]

    def handle_starttag(self, tag: str, attrs):  # type: ignore[override]
        node = Node(tag=tag, attrs={k: (v or "") for k, v in attrs}, is_void=tag in VOID_ELEMENTS)
        self.stack[-1].children.append(node)
        if not node.is_void:
            self.stack.append(node)

    def handle_startendtag(self, tag: str, attrs):  # type: ignore[override]
        node = Node(tag=tag, attrs={k: (v or "") for k, v in attrs}, is_void=True)
        self.stack[-1].children.append(node)

    def handle_endtag(self, tag: str):  # type: ignore[override]
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                self.stack = self.stack[: i]
                return

    def handle_data(self, data: str):  # type: ignore[override]
        self.stack[-1].children.append(data)

    def handle_entityref(self, name: str):  # type: ignore[override]
        try:
            self.stack[-1].children.append(html.unescape(f"&{name};"))
        except Exception:
            pass

    def handle_charref(self, name: str):  # type: ignore[override]
        try:
            self.stack[-1].children.append(html.unescape(f"&#{name};"))
        except Exception:
            pass

    def handle_comment(self, _data: str):  # type: ignore[override]
        return


# --------------------------------------------------------------------------
# Selector matching (tag + class + simple attr equality)
# --------------------------------------------------------------------------


def _node_classes(node: Node) -> list[str]:
    return (node.attrs.get("class") or "").split()


def _matches_selector(node: Node, selector: str) -> bool:
    """Match one CSS-ish selector token against a node.

    Supported syntax — deliberately tiny:
      tag
      .class
      tag.class
      [attr]
      [attr=value]
      tag[attr=value]
      *
    Combinators are not supported.
    """
    s = selector.strip()
    if s == "*":
        return True
    tag = None
    classes: list[str] = []
    attrs: list[tuple[str, str | None]] = []

    while s:
        if s.startswith("."):
            m = re.match(r"\.([A-Za-z0-9_-]+)", s)
            if not m:
                return False
            classes.append(m.group(1))
            s = s[m.end():]
        elif s.startswith("["):
            m = re.match(r"\[([A-Za-z0-9_-]+)(?:=\"?([^\"\\]]*)\"?)?\]", s)
            if not m:
                return False
            attrs.append((m.group(1), m.group(2)))
            s = s[m.end():]
        else:
            m = re.match(r"[A-Za-z][A-Za-z0-9-]*", s)
            if not m:
                return False
            tag = m.group(0)
            s = s[m.end():]

    if tag and node.tag != tag:
        return False
    for c in classes:
        if c not in _node_classes(node):
            return False
    for key, value in attrs:
        if key not in node.attrs:
            return False
        if value is not None and node.attrs[key] != value:
            return False
    return True


def matches_any_selector(node: Node, selectors: Iterable[str]) -> bool:
    return any(_matches_selector(node, s) for s in selectors)


def find_first_ancestor_matching(path: list[Node], selectors: Iterable[str]) -> Node | None:
    for n in reversed(path):
        if matches_any_selector(n, selectors):
            return n
    return None


# --------------------------------------------------------------------------
# Synthesisers
# --------------------------------------------------------------------------


MERCHANTS = [
    "MERCHANT ALPHA", "MERCHANT BRAVO", "MERCHANT CHARLIE", "MERCHANT DELTA",
    "MERCHANT ECHO", "MERCHANT FOXTROT", "MERCHANT GOLF", "MERCHANT HOTEL",
    "MERCHANT INDIA", "MERCHANT JULIET", "MERCHANT KILO", "MERCHANT LIMA",
]
AMOUNTS = [
    "12.50", "7.20", "130.00", "42.85", "9.99", "88.30", "5.40", "250.00",
    "33.15", "18.95", "61.40", "14.00", "75.50", "3.99", "199.00",
]
DAYS = list(range(5, 16))   # 5..15 Jan 2026
MONTHS_LONG = ["January", "February", "March", "April", "May", "June",
               "July", "August", "September", "October", "November", "December"]
MONTHS_SHORT = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


class Synthesiser:
    def __init__(self, seed: int) -> None:
        self._rng = random.Random(seed)
        self._index = 0

    def next_merchant(self) -> str:
        m = MERCHANTS[self._index % len(MERCHANTS)]
        self._index += 1
        return m

    def next_amount(self) -> str:
        return self._rng.choice(AMOUNTS)

    def signed_amount(self, original: str) -> str:
        """Replace an amount-like text with a synthetic equivalent, preserving
        the original sign / surrounding markup if present.
        """
        new = self.next_amount()
        text = original.replace(" ", " ")
        # Preserve leading sign character if present.
        sign_match = re.search(r"[-−]\s*\$?", text)
        prefix = ""
        if sign_match:
            prefix = "-"
        currency = "$" if "$" in text else ""
        return f"{prefix}{currency}{new}"

    def next_date_dd_mon(self) -> str:
        day = self._rng.choice(DAYS)
        month = self._rng.choice(MONTHS_SHORT)
        return f"{day} {month}"

    def next_date_iso(self) -> str:
        day = self._rng.choice(DAYS)
        return f"2026-01-{day:02d}"

    def next_date_dd_mm_yyyy(self) -> str:
        day = self._rng.choice(DAYS)
        return f"{day:02d}/01/2026"

    def replace_date_text(self, original: str) -> str:
        text = original.replace(" ", " ")
        # Try several common formats.
        if re.search(r"\d{4}-\d{2}-\d{2}", text):
            return re.sub(r"\d{4}-\d{2}-\d{2}", self.next_date_iso(), text)
        if re.search(r"\d{1,2}/\d{1,2}/\d{4}", text):
            return re.sub(r"\d{1,2}/\d{1,2}/\d{4}", self.next_date_dd_mm_yyyy(), text)
        m = re.search(r"\d{1,2}\s+[A-Z][a-z]{2}\b", text)
        if m:
            return text[: m.start()] + self.next_date_dd_mon() + text[m.end():]
        return text

    def synthetic_account_hint(self) -> str:
        return f"XXXX{self._rng.randint(1000, 9999)}"


# --------------------------------------------------------------------------
# Walker
# --------------------------------------------------------------------------


CLASS_HASH_RE = re.compile(r"^(?:_jss\d+|_emotion-\d+|css-[a-z0-9]{6,}|ng-tns-[a-z0-9-]+|_nghost-[a-z0-9-]+|_ngcontent-[a-z0-9-]+)$")
LONG_DIGIT_RE = re.compile(r"\d{4,}")
TOKEN_VALUE_RE = re.compile(r"^[A-Za-z0-9_-]{16,}$")
AMOUNT_TEXT_RE = re.compile(r"-?\$?\s?\d[\d,]*\.\d{2}")
NBSP = " "


def clean_classes(node: Node, keep_classes: set[str]) -> None:
    classes = _node_classes(node)
    cleaned = [
        c for c in classes
        if c in keep_classes or not CLASS_HASH_RE.match(c)
    ]
    if cleaned:
        node.attrs["class"] = " ".join(cleaned)
    else:
        node.attrs.pop("class", None)


def clean_attrs(node: Node, keep_attributes: set[str]) -> None:
    drop = []
    for key, value in list(node.attrs.items()):
        lk = key.lower()
        if lk in ALWAYS_STRIPPED_ATTRS:
            drop.append(key)
            continue
        if lk in SAFE_ATTRS:
            continue
        if lk in keep_attributes:
            continue
        if lk.startswith("data-"):
            # Keep data-testid (used by some parsers) but redact opaque values
            if lk == "data-testid":
                continue
            # Drop other data-* with token-shaped values
            if TOKEN_VALUE_RE.match(value or ""):
                drop.append(key)
                continue
            continue
        if lk.startswith("aria-"):
            continue
        if lk.startswith("on"):
            drop.append(key)
            continue
        if lk in {"href", "src", "action", "formaction"}:
            node.attrs[key] = "#"
            continue
        # Default: drop unknown attributes (defensive)
        drop.append(key)
    for key in drop:
        node.attrs.pop(key, None)


def transform(
    node: Node,
    parents: list[Node],
    config: SanitiseConfig,
    synth: Synthesiser,
    covered_by_selector: bool = False,
) -> Node | None:
    if isinstance(node, str):
        return node
    if node.tag in ALWAYS_STRIPPED_TAGS:
        return None
    if matches_any_selector(node, config.strip_selectors):
        return None

    keep_class_set = set(config.keep_classes)
    keep_attr_set = set(config.keep_attributes)
    clean_classes(node, keep_class_set)
    clean_attrs(node, keep_attr_set)

    has_merchant = matches_any_selector(node, config.merchant_selectors)
    has_account = matches_any_selector(node, config.account_hint_selectors)
    has_date = matches_any_selector(node, config.date_selectors)
    has_amount = matches_any_selector(node, config.amount_selectors)
    selector_match = has_merchant or has_account or has_date or has_amount

    # Children of a selector-matched node have their text preserved through
    # the baseline redaction pass. We apply the selector-driven replacement
    # AFTER child recursion so it sees the original text — running it
    # before would let the baseline redaction overwrite the synthetic
    # value, and running it after the baseline would feed a redacted value
    # (e.g. "0.00") into the synthesiser.
    child_covered = covered_by_selector or selector_match

    new_children: list[Node | str] = []
    for child in node.children:
        if isinstance(child, str):
            new_children.append(child if child_covered else _redact_text_baseline(child, synth))
        else:
            kept = transform(child, parents + [node], config, synth, child_covered)
            if kept is not None:
                new_children.append(kept)
    node.children = new_children

    if has_merchant:
        _replace_text(node, synth.next_merchant())
    if has_account:
        _replace_text(node, synth.synthetic_account_hint())
    if has_date:
        _replace_text_with(node, synth.replace_date_text)
    if has_amount:
        _replace_text_with(node, synth.signed_amount)

    return node


def _replace_text(node: Node, replacement: str) -> None:
    """Replace all descendant text with `replacement`. If multiple text
    leaves exist we put the replacement on the first non-empty one and
    blank the rest, preserving structure."""
    leaves = _text_leaves(node)
    placed = False
    for parent, idx in leaves:
        text = parent.children[idx]
        if text.strip() and not placed:
            parent.children[idx] = replacement
            placed = True
        else:
            parent.children[idx] = ""
    if not placed:
        node.children.append(replacement)


def _replace_text_with(node: Node, transformer) -> None:
    leaves = _text_leaves(node)
    for parent, idx in leaves:
        text = parent.children[idx]
        if text.strip():
            parent.children[idx] = transformer(text)


def _text_leaves(node: Node) -> list[tuple[Node, int]]:
    out: list[tuple[Node, int]] = []
    for i, child in enumerate(node.children):
        if isinstance(child, str):
            out.append((node, i))
        else:
            out.extend(_text_leaves(child))
    return out


def _redact_text_baseline(text: str, synth: Synthesiser | None = None) -> str:
    """Catch-all redaction applied to every text node — strips long digit
    runs that escaped selector-driven rules. When `synth` is provided,
    amount-shaped numbers get a synthetic amount instead of being
    blanked to `0.00` — that's the right shape-preserving treatment
    for amounts that selector rules didn't cover (e.g. credit rows in
    a bank that uses a `.minus` class on debit rows only)."""
    text = text.replace(NBSP, " ")
    if synth is None:
        text = AMOUNT_TEXT_RE.sub("0.00", text)
    else:
        text = AMOUNT_TEXT_RE.sub(lambda _m: synth.next_amount(), text)
    text = LONG_DIGIT_RE.sub("0000", text)
    return text


# --------------------------------------------------------------------------
# Serialisation
# --------------------------------------------------------------------------


def serialise(node: Node) -> str:
    if isinstance(node, str):
        return html.escape(node, quote=False)
    if node.tag == "#document":
        body = "".join(serialise(c) for c in node.children)
        return body
    attrs_str = "".join(
        f' {k}="{html.escape(v, quote=True)}"' for k, v in node.attrs.items() if v != ""
    ) + "".join(
        f' {k}' for k, v in node.attrs.items() if v == ""
    )
    if node.is_void or node.tag in VOID_ELEMENTS:
        return f"<{node.tag}{attrs_str}>"
    inner = "".join(serialise(c) for c in node.children)
    return f"<{node.tag}{attrs_str}>{inner}</{node.tag}>"


def minify(text: str) -> str:
    # Collapse consecutive whitespace inside tags only — preserve text
    # content. Heuristic: replace runs of \s{2,} between '>' and '<' with
    # a single space, drop \n\r\t entirely between tags.
    text = re.sub(r">\s+<", "><", text)
    text = re.sub(r"\s{2,}", " ", text)
    return text.strip()


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------


def sanitise(config: SanitiseConfig, out_path: Path) -> None:
    source_path = Path(config.source)
    if not source_path.exists():
        raise SystemExit(
            f"source HTML not found: {config.source} (expected on contributor's machine — never in repo)"
        )
    source_text = source_path.read_text(encoding="utf-8", errors="ignore")
    builder = DOMBuilder()
    builder.feed(source_text)
    builder.close()

    synth = Synthesiser(seed=config.seed)
    cleaned = transform(builder.root, [], config, synth)
    if cleaned is None:
        raise SystemExit("everything was stripped — config probably wrong")

    html_body = serialise(cleaned)
    html_body = minify(html_body)
    # Wrap in a minimal doctype + html so jsdom is happy.
    if "<html" not in html_body:
        html_body = f"<!DOCTYPE html><html><body>{html_body}</body></html>"
    out_path.write_text(html_body + "\n", encoding="utf-8")
    digest = hashlib.sha256(html_body.encode("utf-8")).hexdigest()[:12]
    print(f"wrote {out_path} ({len(html_body)} bytes, sha256:{digest})")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("config", help="path to <scenario>.sanitise.yml")
    args = parser.parse_args(argv)
    config_path = Path(args.config).resolve()
    if not config_path.exists():
        parser.error(f"config not found: {config_path}")
    data = parse_minimal_yaml(config_path.read_text(encoding="utf-8"))
    config = SanitiseConfig.from_dict(data, config_path.parent)
    out_path = config_path.with_suffix("").with_suffix(".html")
    # The above strips .sanitise then changes suffix to .html — but for
    # foo.sanitise.yml that yields foo.html which is what we want.
    out_path = config_path.parent / (config_path.name.removesuffix(".sanitise.yml") + ".html")
    sanitise(config, out_path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
