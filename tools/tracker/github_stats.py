#!/usr/bin/env python3
"""Writes docs/tracker/github.json: the public Zenith repo's activity for the progress dashboard's
GitHub section, as one list of rows told apart by `kind`.

    python tools/tracker/github_stats.py [--repo Zenith-3D-Team/Zenith]

Needs `gh` signed in with push access to the repo (GitHub shows traffic only to those). GitHub keeps
traffic (views, clones) for 14 days only, and download counts only as running totals, so each run
merges what it reads into art-src/tracker/github_history.json (git-ignored, kept between runs):
run it daily or the older days are lost. Stars, forks and issues carry their own dates, so their
history is complete from the first run. Commits are counted from this checkout's `main` (the private
development repo), per day.

Rows:
  day       date, views, view_uniques, clones, clone_uniques, stars, forks, issues_opened,
            issues_closed, commits, downloads (GitHub release files, running total on days a run
            saw it), portal_downloads (the bridge mod on mods.factorio.com, likewise)
  release   tag, published, asset, platform, downloads
  referrer  referrer, views, uniques (the last 14 days)
  path      path, views, uniques (the last 14 days, top 10)
  issue     number, title, state, created, closed (issues only, not pull requests)
  summary   one row: the totals now
"""

import argparse
import datetime as dt
import json
import os
import subprocess
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(REPO_DIR, "docs", "tracker", "github.json")
HISTORY = os.path.join(REPO_DIR, "art-src", "tracker", "github_history.json")
PORTAL = "https://mods.factorio.com/api/mods/factorio-3d-bridge"


def gh(path, accept=None, paginate=False):
    cmd = ["gh", "api", path]
    if accept:
        cmd += ["-H", "Accept: " + accept]
    if paginate:
        cmd += ["--paginate", "--slurp"]
    out = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", check=True).stdout
    data = json.loads(out)
    if paginate:  # --slurp gives a list of pages
        return [x for page in data for x in page]
    return data


def day_of(stamp):
    return stamp[:10] if stamp else None


def platform_of(asset):
    name = asset.lower()
    if name.startswith("factorio-3d-bridge"):
        return "Mod zip"
    for key, label in (("windows-arm64", "Windows ARM64"), ("linux-arm64", "Linux ARM64"),
                       ("macos", "macOS"), ("windows", "Windows"), ("linux", "Linux")):
        if key in name:
            return label
    return "Other"


def commits_per_day():
    out = subprocess.run(["git", "-C", REPO_DIR, "log", "main", "--format=%cI"],
                         capture_output=True, text=True, check=True).stdout
    counts = {}
    for line in out.split():
        d = dt.datetime.fromisoformat(line).astimezone(dt.timezone.utc).date().isoformat()
        counts[d] = counts.get(d, 0) + 1
    return counts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="Zenith-3D-Team/Zenith")
    args = ap.parse_args()
    repo = "repos/" + args.repo
    today = dt.datetime.now(dt.timezone.utc).date().isoformat()

    history = {"traffic": {}, "downloads": {}, "portal": {}}
    if os.path.exists(HISTORY):
        with open(HISTORY, encoding="utf-8") as f:
            history.update(json.load(f))

    info = gh(repo)
    views = gh(repo + "/traffic/views")
    clones = gh(repo + "/traffic/clones")
    # A day GitHub still lists is replaced (today's count grows until the day ends).
    for v in views["views"]:
        history["traffic"].setdefault(day_of(v["timestamp"]), {}).update(
            views=v["count"], view_uniques=v["uniques"])
    for c in clones["clones"]:
        history["traffic"].setdefault(day_of(c["timestamp"]), {}).update(
            clones=c["count"], clone_uniques=c["uniques"])

    releases = gh(repo + "/releases", paginate=True)
    downloads = sum(a["download_count"] for r in releases for a in r["assets"])
    history["downloads"][today] = downloads
    try:
        with urllib.request.urlopen(PORTAL, timeout=20) as r:
            portal = json.load(r).get("downloads_count")
        if portal is not None:
            history["portal"][today] = portal
    except Exception:
        portal = None

    stars = gh(repo + "/stargazers?per_page=100", accept="application/vnd.github.star+json", paginate=True)
    forks = gh(repo + "/forks?per_page=100", paginate=True)
    issues = [i for i in gh(repo + "/issues?state=all&per_page=100", paginate=True) if "pull_request" not in i]
    referrers = gh(repo + "/traffic/popular/referrers")
    paths = gh(repo + "/traffic/popular/paths")
    commits = commits_per_day()

    os.makedirs(os.path.dirname(HISTORY), exist_ok=True)
    with open(HISTORY, "w", encoding="utf-8") as f:
        json.dump(history, f, indent=1, sort_keys=True)

    def count_by_day(stamps):
        c = {}
        for s in stamps:
            if s:
                c[day_of(s)] = c.get(day_of(s), 0) + 1
        return c

    star_days = count_by_day(s["starred_at"] for s in stars)
    fork_days = count_by_day(f["created_at"] for f in forks)
    opened = count_by_day(i["created_at"] for i in issues)
    closed = count_by_day(i["closed_at"] for i in issues)

    known = [d for d in (list(star_days) + list(history["traffic"]) + list(opened)) if d]
    first = min(known) if known else today
    rows = []
    d = dt.date.fromisoformat(first)
    while d.isoformat() <= today:
        k = d.isoformat()
        t = history["traffic"].get(k, {})
        rows.append({
            "kind": "day", "date": k,
            "views": t.get("views"), "view_uniques": t.get("view_uniques"),
            "clones": t.get("clones"), "clone_uniques": t.get("clone_uniques"),
            "stars": star_days.get(k, 0), "forks": fork_days.get(k, 0),
            "issues_opened": opened.get(k, 0), "issues_closed": closed.get(k, 0),
            "commits": commits.get(k, 0),
            "downloads": history["downloads"].get(k), "portal_downloads": history["portal"].get(k),
        })
        d += dt.timedelta(days=1)
    # GitHub lists traffic days with nothing in them; start at the first day anything happened.
    def busy(r):
        return any(r[k] for k in ("views", "clones", "stars", "forks", "issues_opened", "commits"))
    while len(rows) > 1 and not busy(rows[0]):
        rows.pop(0)

    for r in releases:
        for a in r["assets"]:
            rows.append({"kind": "release", "tag": r["tag_name"], "published": day_of(r["published_at"]),
                         "asset": a["name"], "platform": platform_of(a["name"]),
                         "downloads": a["download_count"]})
    for r in referrers:
        rows.append({"kind": "referrer", "referrer": r["referrer"], "views": r["count"], "uniques": r["uniques"]})
    for p in paths[:10]:
        rows.append({"kind": "path", "path": p["path"], "views": p["count"], "uniques": p["uniques"]})
    for i in issues:
        rows.append({"kind": "issue", "number": i["number"], "title": i["title"], "state": i["state"],
                     "created": day_of(i["created_at"]), "closed": day_of(i["closed_at"])})
    rows.append({
        "kind": "summary", "stars": info["stargazers_count"], "forks": info["forks_count"],
        "watchers": info.get("subscribers_count"), "open_issues": sum(1 for i in issues if i["state"] == "open"),
        "issues_total": len(issues), "downloads": downloads, "portal_downloads": portal,
        "views_14d": views["count"], "view_uniques_14d": views["uniques"], "clones_14d": clones["count"],
        "latest_release": releases[0]["tag_name"] if releases else None, "as_of": today,
    })

    with open(OUT, "w", encoding="utf-8") as f:
        json.dump({"rows": rows}, f, indent=1)
    print(f"{OUT}: {len(rows)} rows, {sum(1 for r in rows if r['kind'] == 'day')} days, "
          f"{info['stargazers_count']} stars, {downloads} downloads, portal {portal}")


if __name__ == "__main__":
    main()
