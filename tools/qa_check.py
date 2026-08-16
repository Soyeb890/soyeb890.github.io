#!/usr/bin/env python3
"""QA checker for the Raqeeb Garments Workshop V2 static site.

Python standard library only — no external dependencies. Recursively
inspects every .html file under the v2/ tree and reports ERRORs (things
that break the site) and WARNINGs (things worth a human's attention).
Mirrors tools/qa_check.ps1 for machines without PowerShell.

Usage:
    python tools/qa_check.py

Exit code is non-zero only if at least one ERROR was found. Warnings never
fail the run.
"""
import os
import re
import sys
from html.parser import HTMLParser
from urllib.parse import urlsplit, unquote

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE_ORIGIN = "https://www.raqeebgmt.com"
EXPECTED_SITE_NAME = "Raqeeb Garments Workshop"

EXTERNAL_SCHEMES = ("http://", "https://", "mailto:", "tel:", "javascript:", "//")

# Wording that is either an unverified/invented claim, or specifically
# scoped-out per Phase 3E owner review. Fabric terms are deliberately kept
# as WARNINGS (not ERRORS) since some may become verified later, and the
# T-shirt page's confirmed "Cotton" / "Polyester mesh" must never trip these
# — none of the patterns below match on bare "cotton" or "polyester".
SUSPICIOUS_PATTERNS = [
    (re.compile(r"5\s*[–\-]\s*14\s*days", re.I), "\"5-14 days\" turnaround claim"),
    (re.compile(r"high[\s-]?volume", re.I), "\"high-volume\" claim"),
    (re.compile(r"nothing\s+subcontracted\s+out", re.I), "\"nothing subcontracted out\" claim"),
    (re.compile(r"\b\d[\d,]*\+?\s*(specializ\w*\s+)?workers?\b", re.I), "worker-count language"),
    (re.compile(r"\b\d[\d,]*\+?\s*(stitching\s+)?machines?\b", re.I), "machine-count language"),
    (re.compile(r"\bfounder\b", re.I), "founder-experience language"),
    (re.compile(r"consistent\s+sizing", re.I), "\"consistent sizing\" outcome claim"),
    (re.compile(r"repeatable\s+tailoring", re.I), "\"repeatable tailoring\" claim"),
    (re.compile(r"\bunisex\b", re.I), "\"unisex\" claim"),
    (re.compile(r"poly-cotton", re.I), "\"poly-cotton\" fabric claim"),
    (re.compile(r"stretch[\s-]blend", re.I), "\"stretch blend\" fabric claim"),
]


class PageParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.title = None
        self.h1 = None
        self.h1_count = 0
        self.meta_description = None
        self.og_image = None
        self.og_site_name = None
        self.canonical = None
        self.robots = None
        self.ids = []          # (id, line)
        self.links = []        # (href, line)
        self.imgs = []         # (src, alt, line)
        self._in_title = False
        self._in_h1 = False
        self._h1_depth = 0

    def handle_starttag(self, tag, attrs):
        d = {}
        for k, v in attrs:
            d[k.lower()] = v if v is not None else ""
        line = self.getpos()[0]

        if "id" in d and d["id"].strip():
            self.ids.append((d["id"].strip(), line))

        if tag == "title":
            self._in_title = True
        elif tag == "h1":
            self.h1_count += 1
            if self.h1 is None:
                self._in_h1 = True
                self.h1 = ""
        elif tag == "meta":
            name = d.get("name", "").lower()
            prop = d.get("property", "").lower()
            if name == "description" and self.meta_description is None:
                self.meta_description = d.get("content", "")
            if prop == "og:image" and self.og_image is None:
                self.og_image = d.get("content", "")
            if prop == "og:site_name" and self.og_site_name is None:
                self.og_site_name = d.get("content", "")
            if name == "robots":
                self.robots = d.get("content", "")
        elif tag == "link":
            rel = d.get("rel", "").lower()
            if rel == "canonical":
                self.canonical = d.get("href")
            if "href" in d:
                self.links.append((d["href"], line))
        elif tag == "a":
            if "href" in d:
                self.links.append((d["href"], line))
        elif tag == "img":
            self.imgs.append((d.get("src"), d.get("alt"), line))

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False
        elif tag == "h1" and self._in_h1:
            self._in_h1 = False

    def handle_data(self, data):
        if self._in_title:
            self.title = (self.title or "") + data
        if self._in_h1:
            self.h1 += data


def read_file(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def find_html_files(root):
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", "tools", ".claude")]
        for fn in filenames:
            if fn.lower().endswith(".html"):
                out.append(os.path.join(dirpath, fn))
    return sorted(out)


def rel(path):
    return os.path.relpath(path, ROOT).replace("\\", "/")


def expected_canonical(rel_path):
    """Derives the production canonical URL for a file from its path
    relative to the site root. All indexable pages are either the root
    index.html, thanks.html, or a <dir>/index.html — directories become
    trailing-slash URLs with no "index.html" segment."""
    if rel_path == "index.html":
        return SITE_ORIGIN + "/"
    if rel_path == "thanks.html":
        return SITE_ORIGIN + "/thanks.html"
    if rel_path.endswith("/index.html"):
        dir_part = rel_path[: -len("index.html")]
        return SITE_ORIGIN + "/" + dir_part
    return SITE_ORIGIN + "/" + rel_path


def is_internal(href):
    if not href:
        return False
    h = href.strip()
    if not h or h.startswith("#"):
        return False
    low = h.lower()
    for scheme in EXTERNAL_SCHEMES:
        if low.startswith(scheme):
            return False
    return True


def resolve_link(file_path, href):
    """Resolve an internal href relative to the file that contains it.
    Returns (resolved_abs_path, path_only_without_query_or_fragment)."""
    path_only = href.split("#", 1)[0].split("?", 1)[0]
    path_only = unquote(path_only)
    if not path_only:
        return None, path_only
    base_dir = os.path.dirname(file_path)
    resolved = os.path.normpath(os.path.join(base_dir, path_only))
    return resolved, path_only


def main():
    html_files = find_html_files(ROOT)
    errors = []
    warnings = []

    pages = {}  # path -> PageParser
    raw = {}    # path -> raw text

    for path in html_files:
        text = read_file(path)
        raw[path] = text
        parser = PageParser()
        try:
            parser.feed(text)
        except Exception as e:
            errors.append((rel(path), 0, "failed to parse HTML: %s" % e))
            continue
        pages[path] = parser

    for path, parser in pages.items():
        r = rel(path)
        is_thanks_page = (r == "thanks.html")

        # --- Required metadata ---
        if not parser.title or not parser.title.strip():
            errors.append((r, 0, "missing <title>"))
        if parser.meta_description is None or not parser.meta_description.strip():
            errors.append((r, 0, "missing meta description"))
        if parser.h1_count == 0:
            errors.append((r, 0, "missing H1"))
        elif parser.h1_count > 1:
            errors.append((r, 0, "%d H1 elements found (expected exactly one)" % parser.h1_count))

        if not parser.canonical:
            errors.append((r, 0, "missing canonical link"))
        else:
            expected = expected_canonical(r)
            if parser.canonical != expected:
                errors.append((r, 0, "canonical does not match expected production URL: got \"%s\", expected \"%s\"" % (parser.canonical, expected)))

        # --- Indexing regressions ---
        has_noindex = bool(parser.robots and "noindex" in parser.robots.lower())
        if is_thanks_page:
            if not has_noindex:
                errors.append((r, 0, "thanks.html must stay noindex"))
        else:
            if has_noindex:
                errors.append((r, 0, "accidental noindex on an indexable page"))
            if not parser.og_site_name or not parser.og_site_name.strip():
                errors.append((r, 0, "missing og:site_name"))
            elif parser.og_site_name != EXPECTED_SITE_NAME:
                warnings.append((r, 0, "og:site_name is \"%s\", expected \"%s\"" % (parser.og_site_name, EXPECTED_SITE_NAME)))

        # --- Duplicate IDs within the page ---
        seen = {}
        for id_val, line in parser.ids:
            seen.setdefault(id_val, []).append(line)
        for id_val, lines in seen.items():
            if len(lines) > 1:
                errors.append((r, lines[1], "duplicate id \"%s\" (also at line %s)" % (id_val, lines[0])))

        # --- og:image relative ---
        if parser.og_image and not parser.og_image.lower().startswith(("http://", "https://")):
            warnings.append((r, 0, "og:image is relative, not absolute: %s" % parser.og_image))

        # --- alt text ---
        for src, alt, line in parser.imgs:
            if alt is None or not alt.strip():
                warnings.append((r, line, "image missing/empty alt text: %s" % (src or "(no src)")))

        # --- links: broken internal refs + explicit index.html requirement ---
        for href, line in parser.links:
            if not is_internal(href):
                continue
            resolved, path_only = resolve_link(path, href)
            if resolved is None:
                continue  # pure same-page anchor
            last_seg = path_only.rsplit("/", 1)[-1]
            looks_like_directory = path_only.endswith("/") or ("." not in last_seg)
            if looks_like_directory:
                errors.append((r, line, "internal link omits explicit index.html: %s" % href))
                # still check the implied index.html exists, if resolvable
                candidate = os.path.join(resolved, "index.html")
                if not os.path.isfile(candidate):
                    errors.append((r, line, "broken internal link (no index.html at target): %s" % href))
                continue
            if not os.path.isfile(resolved):
                errors.append((r, line, "broken internal link (target not found): %s" % href))

        # --- local image files exist ---
        for src, alt, line in parser.imgs:
            if not src or not is_internal(src):
                continue
            resolved, _ = resolve_link(path, src)
            if resolved and not os.path.isfile(resolved):
                errors.append((r, line, "broken image reference: %s" % src))

        # --- suspicious wording (raw text scan) ---
        text = raw[path]
        for pattern, label in SUSPICIOUS_PATTERNS:
            m = pattern.search(text)
            if m:
                line_no = text.count("\n", 0, m.start()) + 1
                warnings.append((r, line_no, "suspicious wording — %s" % label))

    # --- duplicate titles / descriptions across pages ---
    titles = {}
    descriptions = {}
    for path, parser in pages.items():
        r = rel(path)
        if parser.title:
            titles.setdefault(parser.title.strip(), []).append(r)
        if parser.meta_description:
            descriptions.setdefault(parser.meta_description.strip(), []).append(r)

    for title, files in titles.items():
        if len(files) > 1:
            warnings.append((", ".join(files), 0, "duplicate <title>: \"%s\"" % title))
    for desc, files in descriptions.items():
        if len(files) > 1:
            warnings.append((", ".join(files), 0, "duplicate meta description: \"%s\"" % desc[:70]))

    # --- orphan product pages: BFS from products/index.html ---
    hub_path = os.path.join(ROOT, "products", "index.html")
    product_dir = os.path.join(ROOT, "products")
    all_product_pages = set()
    if os.path.isdir(product_dir):
        for entry in os.listdir(product_dir):
            candidate = os.path.join(product_dir, entry, "index.html")
            if os.path.isfile(candidate):
                all_product_pages.add(os.path.normpath(candidate))

    reachable = set()
    if os.path.isfile(hub_path) and hub_path in pages:
        queue = [os.path.normpath(hub_path)]
        visited = set(queue)
        while queue:
            current = queue.pop(0)
            parser = pages.get(current)
            if parser is None:
                continue
            for href, _line in parser.links:
                if not is_internal(href):
                    continue
                resolved, path_only = resolve_link(current, href)
                if resolved is None:
                    continue
                if path_only.endswith("/"):
                    resolved = os.path.join(resolved, "index.html")
                resolved = os.path.normpath(resolved)
                if resolved.startswith(os.path.normpath(product_dir)) and os.path.isfile(resolved):
                    reachable.add(resolved)
                    if resolved not in visited:
                        visited.add(resolved)
                        queue.append(resolved)

    for page in sorted(all_product_pages):
        if page == os.path.normpath(hub_path):
            continue
        if page not in reachable:
            errors.append((rel(page), 0, "orphan product page not reachable from Products Hub"))

    # --- site-wide orphan check: BFS from the homepage across every
    # indexable page (catches pages outside products/, e.g. private-label/,
    # that the products-hub-scoped check above can't see) ---
    home_path = os.path.normpath(os.path.join(ROOT, "index.html"))
    indexable_paths = [p for p in html_files if rel(p) != "thanks.html"]
    if home_path in pages:
        site_reachable = {home_path}
        queue = [home_path]
        while queue:
            current = queue.pop(0)
            parser = pages.get(current)
            if parser is None:
                continue
            for href, _line in parser.links:
                if not is_internal(href):
                    continue
                resolved, path_only = resolve_link(current, href)
                if resolved is None:
                    continue
                if path_only.endswith("/"):
                    resolved = os.path.join(resolved, "index.html")
                resolved = os.path.normpath(resolved)
                if os.path.isfile(resolved) and resolved not in site_reachable:
                    site_reachable.add(resolved)
                    queue.append(resolved)

        for p in indexable_paths:
            if os.path.normpath(p) not in site_reachable:
                errors.append((rel(p), 0, "orphan page not reachable from the homepage"))

    # --- sitemap.xml checks ---
    sitemap_path = os.path.join(ROOT, "sitemap.xml")
    if not os.path.isfile(sitemap_path):
        errors.append(("sitemap.xml", 0, "file not found at site root"))
    else:
        sitemap_text = read_file(sitemap_path)
        sitemap_urls = [m.group(1).strip() for m in re.finditer(r"<loc>\s*([^<\s]+)\s*</loc>", sitemap_text)]

        counts = {}
        for u in sitemap_urls:
            counts[u] = counts.get(u, 0) + 1
        for u, c in counts.items():
            if c > 1:
                errors.append(("sitemap.xml", 0, "URL listed %d times, expected exactly once: %s" % (c, u)))

        thanks_url = expected_canonical("thanks.html")
        if thanks_url in sitemap_urls:
            errors.append(("sitemap.xml", 0, "thanks.html must be excluded from the sitemap"))

        expected_urls = {expected_canonical(rel(p)) for p in indexable_paths}
        sitemap_set = set(sitemap_urls)

        for u in expected_urls:
            if u not in sitemap_set:
                errors.append(("sitemap.xml", 0, "missing expected canonical URL: %s" % u))
        for u in sitemap_set:
            if u not in expected_urls and u != thanks_url:
                errors.append(("sitemap.xml", 0, "lists a URL with no matching indexable page: %s" % u))

    # --- robots.txt checks ---
    robots_path = os.path.join(ROOT, "robots.txt")
    if not os.path.isfile(robots_path):
        errors.append(("robots.txt", 0, "file not found at site root"))
    else:
        robots_text = read_file(robots_path)
        expected_sitemap_line = SITE_ORIGIN + "/sitemap.xml"
        if expected_sitemap_line not in robots_text:
            errors.append(("robots.txt", 0, "does not declare the sitemap URL (%s)" % expected_sitemap_line))
        if re.search(r"(?m)^\s*Disallow:\s*/\s*$", robots_text):
            errors.append(("robots.txt", 0, "blanket 'Disallow: /' would block all public pages"))

    # --- report ---
    def fmt(entry):
        location, line, msg = entry
        if line:
            return "%s:%s — %s" % (location, line, msg)
        return "%s — %s" % (location, msg)

    if errors:
        print("ERRORS (%d):" % len(errors))
        for e in sorted(errors):
            print("  [ERROR] " + fmt(e))
        print("")

    if warnings:
        print("WARNINGS (%d):" % len(warnings))
        for w in sorted(warnings):
            print("  [WARN]  " + fmt(w))
        print("")

    print("PASS SUMMARY: %d file(s) scanned, %d error(s), %d warning(s)."
          % (len(html_files), len(errors), len(warnings)))

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
