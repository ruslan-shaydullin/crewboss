#!/usr/bin/env python3
"""crewboss demon-API (UI roadmap phase 0). Thin HTTP+SSE layer over the engine, honoring
Engine<->View: it READS the board (board-gh.sh) + run/*.json and WRITES only via the same
mechanisms the launcher already uses (flag-files, labels, a backgrounded launcher). No new
deps (python3 stdlib only, like the proxy/bridge).

    CB_REPO=owner/repo CB_HOME=~/cbnet CB_API_TOKEN=secret python3 crewboss-api.py [--port 8787]

Endpoints (all under /api, bearer-auth except /api/health):
    GET  /api/health                 -> {ok:true}                       (no auth)
    GET  /api/state                  -> {board:[...], budget:{...}, flags:{...}, autonomy:{...}}
    GET  /api/events                 -> text/event-stream; emits "state" events on change
    POST /api/command {action,...}   -> run | pause | resume | kill | unkill | approve(#) | hold(#) | unhold(#)
Auth: header  Authorization: Bearer <CB_API_TOKEN>.  CORS open (UI is a separate origin).
"""
import hmac, hashlib
import json, os, shutil, subprocess, sys, tempfile, threading, time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO   = os.environ.get("CB_REPO", "")
CB_HOME= os.environ.get("CB_HOME", os.path.expanduser("~/cbnet"))
RUN    = os.path.join(CB_HOME, "run")
TOKEN  = os.environ.get("CB_API_TOKEN", "")
PORT   = int(sys.argv[sys.argv.index("--port")+1]) if "--port" in sys.argv else int(os.environ.get("CB_API_PORT","8787"))
BOARD  = os.path.join(CB_HOME, "board-gh.sh")
CB_INTEGRATOR = os.environ.get('CB_INTEGRATOR') or os.path.join(CB_HOME, 'crewboss-integrator.sh')

# HD-escalation command constants (charter #442 api-hd-actions)
CMD_APPROVE_HD         = "approve-hd"
CMD_REQUEST_CHANGES_HD = "request-changes-hd"
CMD_CLOSE_HD           = "close-hd"

_webhook_kick = threading.Event()
_etag_store = {}  # keyed by resource path
_cached_issues = None
_cached_charters = None
_cached_charter_issues = None  # charter-specific raw issues list (eviction fix #947)

def sh(args, timeout=30):
    try: return subprocess.run(args, capture_output=True, text=True, timeout=timeout).stdout
    except Exception: return ""

def read_json(path, default):
    try: return json.load(open(path))
    except Exception: return default

def save_queue(order):
    """Atomically persist the operator queue (ordered charter numbers) to run/queue.json.
    Mirrors the tempfile+rename pattern used for other run-state writes; the launcher reads
    it via jq '.order[]' (#281). Empty order = cleared queue -> launcher default behaviour.

    Belt path (#900/#626): after writing queue.json, for each charter ID in order that has
    type:charter but no status:* label, stamp status:needs-analysis via gh issue edit so
    the launcher's analysis-cycle picks it up on the very next tick instead of silently
    idling (bare charter with no status label is never emitted by plannable_scoped or
    matched by _analysis_boards without this stamp). Failures are swallowed (best-effort);
    the launcher's bare-charter guard (sibling leaf #898) acts as the suspenders fallback."""
    os.makedirs(RUN, exist_ok=True)
    path = os.path.join(RUN, "queue.json")
    fd, tmp = tempfile.mkstemp(dir=RUN, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump({"order": order}, f)
        os.replace(tmp, path)
    except Exception:
        try: os.remove(tmp)
        except Exception: pass
        raise
    # Belt: stamp status:needs-analysis on any bare type:charter in the new order.
    # Best-effort: failures are swallowed so a transient GitHub error never breaks
    # save_queue. The launcher bare-charter guard acts as suspenders fallback.
    import json as _json_sq
    import subprocess as _sp_sq
    _repo_sq = os.environ.get("CB_REPO", "")
    if _repo_sq:
        for _cid_sq in order:
            try:
                _raw_sq = _sp_sq.check_output(
                    ["gh", "issue", "view", str(_cid_sq), "-R", _repo_sq, "--json", "labels"],
                    timeout=10
                )
                _labels_sq = [l["name"] for l in _json_sq.loads(_raw_sq).get("labels", [])]
                _is_charter_sq = "type:charter" in _labels_sq
                _has_status_sq = any(l.startswith("status:") for l in _labels_sq)
                if _is_charter_sq and not _has_status_sq:
                    _sp_sq.run(
                        ["gh", "issue", "edit", str(_cid_sq), "-R", _repo_sq,
                         "--add-label", "status:needs-analysis"],
                        timeout=10, check=False
                    )
            except Exception:
                pass  # best-effort; launcher fallback covers failures
    return {"ok": True}

import re
_CHARTER_RE   = re.compile(r"(?im)^[\s*_>#-]*Charter\s*:\s*#?(\d+)")
_MILESTONE_RE = re.compile(r"(?im)^[\s*_>#-]*Milestone\s*:\s*#?(\d+)")
_ROLE_NAME_RE = re.compile(r'^[a-z0-9-]+$')
_ANSI_RE      = re.compile(r'\x1b\[[0-9;]*m')
def _charter_of(body):
    m = _CHARTER_RE.search(body or "")
    return int(m.group(1)) if m else None
def _milestone_of(body):
    m = _MILESTONE_RE.search(body or "")
    return int(m.group(1)) if m else None
def _hd_type(title):
    """Return HD gate type keyword from issue title substring (charter #442).
    Matches (case-insensitive): composition, analysis, approval, plan, acceptance."""
    tl = (title or "").lower()
    if "composition not converging"  in tl: return "composition"
    if "analysis did not converge"   in tl: return "analysis"
    if "approval required"           in tl: return "approval"
    if "plan did not converge"       in tl: return "plan"
    if "acceptance did not converge" in tl: return "acceptance"
    return None

def build_agents(by_n, loop_running=False):
    """Live agents = launcher run-state pids that are alive, joined with status.json + board."""
    agents = []
    sdir = os.path.join(RUN, "state")
    if os.path.isdir(sdir):
        for tid in sorted(os.listdir(sdir)):
            pf = os.path.join(sdir, tid, "pid")
            try: pid = int(open(pf).read().strip())
            except Exception: continue
            try: os.kill(pid, 0)
            except Exception: continue  # not alive -> not a live agent
            sj = read_json(os.path.join(RUN, "work", tid, "status.json"), {})
            def rd(f):
                try: return open(os.path.join(sdir, tid, f)).read().strip()
                except Exception: return ""
            tn = int(tid) if tid.isdigit() else tid
            agents.append(dict(task=tn, pid=pid,
                role=sj.get("role") or ("tech-lead" if rd("kind")=="charter" else "executor"),
                phase=sj.get("phase") or "starting",
                title=(by_n.get(tn, {}) or {}).get("title", ""),
                started=rd("starttime")))
    boss = os.path.join(RUN, "boss.session")
    if os.path.exists(boss):
        agents.append(dict(task=None, role="boss", phase="interactive", title="boss session", started=""))
    # Synthetic (non-PID) agents
    if loop_running:
        agents.append(dict(task=None, role="launcher", phase="running",
                           title="launcher loop", started="", pid=None))
    for n, item in by_n.items():
        if item.get("state") == "review":
            if not any(a.get("task") == n for a in agents):
                agents.append(dict(task=n, role="integrator",
                                   phase="awaiting-integration",
                                   title=item.get("title", ""), started="", pid=None))
    for n, item in by_n.items():
        if item.get("kind") == "charter" and item.get("state") == "needs-plan":
            if not any(a.get("task") == n for a in agents):
                agents.append(dict(task=n, role="tech-lead",
                                   phase="planning" if loop_running else "awaiting",
                                   title=item.get("title", ""), started="", pid=None))
    # TODO: analyst synthetic agent — pending P2/F1 implementation
    return agents

def build_loop_info(board=None):
    """Read loop-mode info from run-env.sh (same source as action=run, #148)."""
    run_env_sh = os.path.join(CB_HOME, "run-env.sh")
    home = os.environ.get("HOME", os.path.expanduser("~"))
    seed_env = {
        "HOME": home,
        "PATH": os.environ.get("PATH", "/usr/bin:/bin:/usr/local/bin"),
    }
    # Pass CB_NO_INTEGRATE through so D2 opt-out is respected when the daemon carries it
    if os.environ.get("CB_NO_INTEGRATE"):
        seed_env["CB_NO_INTEGRATE"] = os.environ["CB_NO_INTEGRATE"]
    env = {}
    if os.path.isfile(run_env_sh):
        try:
            env_raw = subprocess.run(
                ["bash", "-c", f'set -a; source "{run_env_sh}"; set +a; env'],
                capture_output=True, text=True, env=seed_env, timeout=15
            ).stdout
            for line in env_raw.splitlines():
                if "=" in line:
                    k, v = line.split("=", 1)
                    if k and k.isidentifier():
                        env[k] = v
        except Exception:
            pass
    # integrate: CB_GIT_REMOTE non-empty after sourcing run-env.sh (D2 logic)
    integrate = bool(env.get("CB_GIT_REMOTE", "").strip())
    try:    max_ticks    = int(env.get("CB_MAX_TICKS",    "1800"))
    except Exception: max_ticks    = 1800
    try:    max_parallel = int(env.get("CB_MAX_PARALLEL", "4"))
    except Exception: max_parallel = 4
    # running: launcher.pid present and process alive
    pid_file = os.path.join(RUN, "launcher.pid")
    running = False
    try:
        pid = int(open(pid_file).read().strip())
        os.kill(pid, 0)
        running = True
    except Exception:
        pass
    # stage: first-match wins
    if not running:
        stage = "idle"
    else:
        sdir = os.path.join(RUN, "state")
        has_finale = False
        if os.path.isdir(sdir):
            has_finale = any(e.startswith("finale-") for e in os.listdir(sdir))
        items = list(board) if board else []
        reviewing = [it for it in items if it.get("state") == "review" and it.get("kind") == "leaf"]
        in_progress = [it for it in items if it.get("state") == "in-progress"]
        needs_plan = [it for it in items if it.get("kind") == "charter"
                      and it.get("state") in ("needs-plan", "plan-review")]
        if has_finale:
            stage = "finale"
        elif reviewing and integrate:
            stage = "integrating"
        elif reviewing:
            stage = "reviewing"
        elif in_progress:
            stage = "executing"
        elif needs_plan:
            stage = "planning"
        else:
            stage = "running"
    return dict(integrate=integrate, max_ticks=max_ticks, max_parallel=max_parallel,
                running=running, stage=stage)

# Hard page cap for the issue paginator (charter #969 / issue #1020). per_page=100
# -> 100 pages == 10 000 issues, comfortably above the live repo (~1000 and growing)
# so it never re-caps below repo size, yet GUARANTEES a clean terminating exit in a
# small, fixed number of `gh` calls. Bump only if the repo ever nears this ceiling.
MAX_ISSUE_PAGES = 100
# How many pages to fetch concurrently per wave. One wave covers PAGE_BATCH*100
# issues, so the live repo (~1000) drains in ~1-2 waves and `/api/state` returns in
# a couple of seconds instead of paying gh's ~1s subprocess startup serially per
# page (11 serial pages ≈ 14s — the latency this batches away). Kept modest because
# each `gh` is a Go/TLS process: oversubscribing past ~the connection/core budget
# trades startup latency for contention (measured slower at 16/20/24 than at ~12 on
# 4c). 12 drains the live repo (~1000 / 11 pages) in ONE wave (~4s) and degrades
# gracefully to extra bounded waves as the repo grows, all under MAX_ISSUE_PAGES.
PAGE_BATCH = 12

def _fetch_issue_page(page, per_page):
    """One GET of the issues endpoint. Returns a list, or None on a non-list error
    OBJECT / parse failure (the #969 trap signal -> caller treats it as "stop")."""
    raw = sh(["gh", "api", "-X", "GET", f"/repos/{REPO}/issues",
              "-f", "state=all", "-f", f"per_page={per_page}", "-f", f"page={page}"])
    try:
        batch = json.loads(raw)
    except Exception:
        return None
    return batch if isinstance(batch, list) else None

def paginate_issues():
    """Fetch ALL repo issues (state=all) under a HARD page cap, terminating cleanly.

    Charter #969 fix (issue #1020 owns this contract). The defect that bracketed the
    live box was a `page=1; while True: gh api ... page+=1` client loop that could
    NEVER terminate when the endpoint returned a non-list error OBJECT (HTTP 422/403
    rate-limit): `if not batch:` is False on a truthy dict, so `/api/state` and
    `/api/search` spun -> HTTP 000, 40s+ timeout, cockpit OFFLINE (lesson #973).

    The replacement walks pages under an explicit `while page <= MAX_ISSUE_PAGES:`
    hard cap (no `while True`, cannot spin) in bounded CONCURRENT waves, with three
    independent clean exits so the request always completes in a couple of seconds
    and is economical with the GitHub rate limit:

      * page cap   -> the loop variable is hard-bounded by MAX_ISSUE_PAGES.
      * list-guard -> a non-list error OBJECT (the #969 trap) surfaces as None and
                      stops the walk instead of reading as a truthy "more pages".
      * short-page -> a page with < per_page rows is the last page; stop the wave
                      there so we never burn needless extra `gh` calls.

    Pages within a wave are fetched concurrently (gh subprocess startup dominates a
    single-page GET; serial paging is what made this ~14s). `-X GET` forces the GET
    method so `-f` fields become URL query params (without it `gh api` silently
    POSTs the moment a field flag is present). Returns a list of issue dicts
    (possibly empty), in page order; never raises, never hangs.
    """
    if not REPO:
        return []
    per_page = 100
    all_issues = []
    page = 1
    while page <= MAX_ISSUE_PAGES:
        hi = min(page + PAGE_BATCH - 1, MAX_ISSUE_PAGES)
        pages = list(range(page, hi + 1))
        with ThreadPoolExecutor(max_workers=len(pages)) as ex:
            batches = list(ex.map(lambda p: _fetch_issue_page(p, per_page), pages))
        stop = False
        for batch in batches:           # consume in strict page order
            if not batch:               # None or empty list -> last page reached
                stop = True
                break
            all_issues.extend(batch)
            if len(batch) < per_page:   # short page == last page -> clean exit
                stop = True
                break
        if stop:
            break
        page = hi + 1
    return all_issues

def _search_item(it):
    """Project ONE raw gh issue dict into the board-item shape used everywhere:
    {n, kind, state, title, labels}. Kind/state classification is identical to
    build_state() (closed→done; type:milestone→milestone, type:charter→charter,
    else leaf; status-label→state; case-insensitive state)."""
    labels = [l["name"] for l in it.get("labels", [])]
    if   "type:milestone" in labels: kind = "milestone"
    elif "type:charter"   in labels: kind = "charter"
    else:                            kind = "leaf"
    # Case-insensitive: REST /issues returns state=open|closed, gh issue list
    # returns CLOSED — both classify "done" (charter #969 case-mismatch fix).
    if   str(it.get("state", "")).lower() == "closed":  st = "done"
    elif "hold"               in labels:        st = "held"
    elif "status:blocked"     in labels:        st = "blocked"
    elif "status:review"      in labels:        st = "review"
    elif "status:in-progress" in labels:        st = "in-progress"
    elif "status:approved"    in labels:        st = "approved"
    elif "status:plan-review" in labels:        st = "plan-review"
    elif "status:needs-plan"  in labels:        st = "needs-plan"
    else:                                       st = "open"
    return {"n": it["number"], "kind": kind, "state": st,
            "title": it.get("title", ""), "labels": labels}

def search_board(q):
    """Resolve a board search with EXACTLY ONE bounded `gh` call per query — never
    a full-repo walk (charter #994 / issue #1054). The old implementation walked
    the FULL repo issue list (6+ page GETs, growing with the repo); under gh
    rate-limit throttle each page GET stalled toward the 30s `sh` timeout, so the
    whole call
    hung 40s+ → HTTP 000 and the cockpit search came back empty (lesson: merged +
    green on an instant mock ≠ live). This is O(1) gh calls regardless of repo
    size and returns well under a couple of seconds.

    Returns {"results": [board-item, ...]} with each item shaped exactly like
    build_state(): {n, kind, state, title, labels}.

    Routing:
      - empty q → {"results": []} (no gh call).
      - NUMBER query (q is "#N" or all-digits) → ONE direct
            gh api -X GET /repos/OWNER/REPO/issues/{N}
        returning a single issue OBJECT (not an array). Exact, instant, and NOT
        subject to the search-API rate limit. A not-found / non-object / error
        response → {"results": []} (NEVER raises).
      - TEXT query → ONE bounded
            gh api -X GET /search/issues -f q="repo:OWNER/REPO is:issue <terms>"
        whose response carries matches in a `.items` ARRAY (different shape from
        /issues). The scope is ALWAYS hard-pinned to `repo:OWNER/REPO is:issue`
        and the user's q is treated as plain TERMS only — any token carrying a
        qualifier (`repo:`, `org:`, `is:pr`, …) is stripped so a user cannot
        widen scope to other repos. (No shell-injection risk: sh() uses an arg
        list, not shell=True — but qualifier injection is a real scope concern.)
    """
    q = (q or "").strip()
    if not q:
        return {"results": []}

    # NUMBER query → ONE direct issue lookup (single OBJECT, not an array).
    q_num = q.lstrip("#")
    if (q.startswith("#") and q_num.isdigit()) or q.isdigit():
        raw = sh(["gh", "api", "-X", "GET", f"/repos/{REPO}/issues/{q_num}"])
        try:
            obj = json.loads(raw)
        except Exception:
            return {"results": []}
        if not isinstance(obj, dict) or "number" not in obj:
            return {"results": []}  # not-found / error object → empty (never raise)
        return {"results": [_search_item(obj)]}

    # TEXT query → ONE bounded /search/issues call, scope hard-pinned.
    # Strip qualifier-bearing tokens (anything with ':') so the user supplies
    # plain TERMS only and cannot inject repo:/org:/is: to widen the scope.
    terms = [tok for tok in q.split() if ":" not in tok]
    # If the query reduced to ZERO plain terms (e.g. the user typed ONLY
    # qualifiers like "is:pr repo:other/x"), there is nothing to match. Issue
    # #1057: do NOT fire a bare `repo:OWNER/REPO is:issue` search — that would
    # flood back up to per_page unrelated repo issues. Return empty, no gh call.
    if not terms:
        return {"results": []}
    search_q = ("repo:%s is:issue " % REPO) + " ".join(terms)
    raw = sh(["gh", "api", "-X", "GET", "/search/issues",
              "-f", "q=%s" % search_q, "-f", "per_page=30"])
    try:
        data = json.loads(raw)
        items = data.get("items", []) if isinstance(data, dict) else []
    except Exception:
        items = []
    results = [_search_item(it) for it in items
               if isinstance(it, dict) and "number" in it]
    return {"results": results}

def build_state():
    global _cached_issues, _cached_charters
    issues = []
    charters = []
    if REPO:
        try:
            cmd_c = ["gh", "api", f"/repos/{REPO}/issues", "--include", "-X", "GET",
                     "-F", "label=type:charter", "-F", "state=open", "-F", "per_page=100"]
            if _etag_store.get("charters"):
                cmd_c += ["-H", f"If-None-Match: {_etag_store['charters']}"]
            raw_c = sh(cmd_c)
            sep_c = "\r\n\r\n" if "\r\n\r\n" in raw_c else "\n\n"
            parts_c = raw_c.split(sep_c, 1)
            hdrs_c = parts_c[0] if len(parts_c) > 1 else ""
            body_c = parts_c[1] if len(parts_c) > 1 else raw_c
            if "304" in (hdrs_c.splitlines()[0] if hdrs_c else ""):
                charters = _cached_charters or []
            else:
                for line in hdrs_c.splitlines():
                    if line.lower().startswith("etag:"):
                        _etag_store["charters"] = line.split(":", 1)[1].strip()
                        break
                _cached_charters = json.loads(body_c)
                charters = _cached_charters
                if not isinstance(charters, list):
                    charters = []
        except Exception:
            charters = []
        try:
            # Fetch ALL issues via the bounded paginate_issues() walk (mirrors
            # search_board()). ETag caching is dropped for this call — multi-page
            # fetches cannot share a single ETag; correctness (seeing all 614+
            # issues) outweighs caching (charter #969 explicit trade-off). The old
            # `page=1; while True:` client loop is gone, replaced by a hard
            # MAX_ISSUE_PAGES cap: it could never terminate on a non-list error
            # object and hung /api/state (lesson #973 / issue #1020).
            issues = paginate_issues()
        except Exception: issues = []
        if not isinstance(issues, list):
            issues = []
        by_n = {it["number"]: it for it in issues if isinstance(it, dict) and "number" in it}
        for it in charters:
            if isinstance(it, dict) and "number" in it:
                by_n.setdefault(it["number"], it)  # charter wins if not in general call
        issues = list(by_n.values())
    board = []
    for it in issues:
        labels = [l["name"] for l in it.get("labels",[])]
        if   "type:milestone" in labels:           kind = "milestone"
        elif "type:charter"   in labels:           kind = "charter"
        else:                                      kind = "leaf"
        # Case-insensitive: gh issue list -> CLOSED, gh api -> closed (charter #969).
        if   str(it.get("state","")).lower()=="closed": st="done"
        elif "hold" in labels:                     st="held"
        elif "status:blocked" in labels:           st="blocked"
        elif "status:review" in labels:            st="review"
        elif "status:in-progress" in labels:       st="in-progress"
        elif "status:approved" in labels:          st="approved"
        elif "status:plan-review" in labels:       st="plan-review"
        elif "status:needs-plan" in labels:        st="needs-plan"
        else:                                      st="open"
        n = it["number"]
        sj = read_json(os.path.join(RUN,"work",str(n),"status.json"), {})
        body = it.get("body","")
        # git_status: label-derived freshness for open charters (MVP per issue #258)
        if kind == "charter":
            if "status:needs-conflict-resolution" in labels:
                git_status = "needs-conflict-resolution"
            else:
                git_status = "clean"
        else:
            git_status = None
        # blast_radius: label-derived serialization flag for charters (#265)
        if kind == "charter":
            if "blast-radius:high" in labels:
                blast_radius = "high"
            elif "blast-radius:low" in labels:
                blast_radius = "low"
            else:
                blast_radius = None
        else:
            blast_radius = None
        finale_pr = ""
        if kind == "charter":
            fp_path = os.path.join(RUN, "state", f"finale-{n}", "pr_num")
            try:
                fp_val = open(fp_path).read().strip()
                if fp_val:
                    finale_pr = fp_val
            except Exception:
                pass
        board.append(dict(n=n, kind=kind, state=st, title=it.get("title",""),
                          labels=labels, cost=sj.get("cost_usd"), pr=sj.get("pr") or "",
                          phase=sj.get("phase"),
                          charter=(_charter_of(body) if kind=="leaf" else None),
                          milestone=(_milestone_of(body) if kind=="charter" else None),
                          git_status=git_status, blast_radius=blast_radius,
                          finale_pr=finale_pr))
    board.sort(key=lambda r: -r["n"])
    by_n = {r["n"]: r for r in board}
    # Add rework_n counter for charter items
    for item in board:
        if item.get("kind") == "charter":
            rw = os.path.join(RUN, "state", str(item["n"]), "rework_n")
            try:
                item["rework_n"] = int(open(rw).read().strip())
            except Exception:
                item["rework_n"] = 0
    budget = read_json(os.path.join(RUN,"budget.json"), {"spent_usd":0,"runs":[]})
    cfg    = read_json(os.path.join(RUN,"config.json"), {"monthly_credit_usd":0,"cost_pct":0})
    cap = cfg.get("monthly_credit_usd",0)*cfg.get("cost_pct",0)/100
    flags = dict(paused=os.path.exists(os.path.join(RUN,"pause")),
                 killed=os.path.exists(os.path.join(RUN,"kill_switch")))
    loop = build_loop_info(board=board)
    agents = build_agents(by_n, loop_running=loop.get("running", False))
    # operator queue (#280): the ordered charter list the launcher consumes (#281). None when
    # absent or malformed, so the UI renders an empty cockpit rather than crashing.
    queue = read_json(os.path.join(RUN, "queue.json"), None)
    if not (isinstance(queue, dict) and isinstance(queue.get("order"), list)):
        queue = None
    return dict(board=board, agents=agents,
                budget=dict(spent=budget.get("spent_usd",0), cap=cap, runs=budget.get("runs",[])),
                flags=flags, autonomy=dict(repo=REPO),
                loop=loop, queue=queue)

def build_comments(n):
    """Comments for issue n: last 50, via gh CLI."""
    try:
        raw = sh(["gh", "issue", "view", str(n), "-R", REPO, "--json", "comments"]) or ""
        if not raw.strip():
            return {"ok": False, "comments": []}
        data = json.loads(raw)
        comments = data.get("comments", [])
        comments = comments[-50:]
        result = [{"id": c.get("id", ""),
                   "author": c.get("author", {}).get("login", ""),
                   "created": c.get("createdAt", ""),
                   "body": c.get("body", "")} for c in comments]
        return {"ok": True, "comments": result}
    except Exception:
        return {"ok": False, "comments": []}

def build_task(n):
    """Detail for one task: live status + the brief it was given + the redacted run log.

    The `body` field is populated for ALL task kinds (leaf, charter, milestone) via a single
    unconditional `gh issue view` call — no kind-branching required (#700).
    """
    w = os.path.join(RUN, "work", str(n))
    def rd(p, limit=None):
        try:
            s = open(p, encoding="utf-8", errors="replace").read()
            return s[-limit:] if limit else s
        except Exception: return ""
    st = read_json(os.path.join(w, "status.json"), {})
    pidf = os.path.join(RUN, "state", str(n), "pid")
    alive = False
    try: os.kill(int(open(pidf).read().strip()), 0); alive = True
    except Exception: alive = False
    started = rd(os.path.join(RUN, "state", str(n), "starttime")).strip()
    # body: fetched for all kinds (leaf, charter, milestone) — gh issue view works on any issue
    body = ""
    if REPO:
        try:
            raw = sh(["gh", "issue", "view", str(n), "-R", REPO, "--json", "body"]) or ""
            if raw.strip():
                body = json.loads(raw).get("body", "") or ""
        except Exception:
            body = ""
    return dict(n=n, status=st, alive=alive, started=started,
                prompt=rd(os.path.join(w, "task.prompt"), 4000).strip(),
                log=rd(os.path.join(w, "run.log"), 16000),  # run.log is written already-redacted
                body=body)

CB_TEAM = os.environ.get("CB_TEAM", os.path.join(CB_HOME, "team"))
def _frontmatter(path):
    out = {}
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except Exception: return out
    if not lines or lines[0].strip() != "---": return out
    for ln in lines[1:]:
        if ln.strip() == "---": break
        if ":" in ln:
            k, v = ln.split(":", 1); out[k.strip()] = v.strip()
    return out

def build_team():
    """The org manifest for the org-chart: org.json + per-role kind/domain/tools from roles/*.md."""
    org = read_json(os.path.join(CB_TEAM, "org.json"), None)
    if not org: return {"present": False, "nodes": [], "departments": [], "policy": {}}
    live = {}  # role -> count of live agents of that role (overlay)
    try:
        st = build_state()
        for a in st.get("agents", []): live[a.get("role")] = live.get(a.get("role"), 0) + 1
    except Exception: pass
    nodes = []
    for nd in org.get("nodes", []):
        role = nd.get("role")
        fm = _frontmatter(os.path.join(CB_TEAM, "roles", str(role) + ".md"))
        nodes.append(dict(role=role, reports_to=nd.get("reports_to"),
                          kind=fm.get("kind", "?"), domain=fm.get("domain", ""),
                          tools=fm.get("tools", ""), code_blind=fm.get("code_blind", "") == "true",
                          model=fm.get("model", ""), accesses=fm.get("accesses", ""),
                          live=live.get(role, 0)))
    # full role library (every roles/*.md) — the pool = library minus placed nodes
    roles = []
    rdir = os.path.join(CB_TEAM, "roles")
    if os.path.isdir(rdir):
        for fn in sorted(os.listdir(rdir)):
            if not fn.endswith(".md"): continue
            fm = _frontmatter(os.path.join(rdir, fn))
            roles.append(dict(role=fn[:-3], kind=fm.get("kind", "?"), domain=fm.get("domain", ""),
                              code_blind=fm.get("code_blind", "") == "true",
                              model=fm.get("model", ""), accesses=fm.get("accesses", "")))
    return {"present": True, "nodes": nodes, "roles": roles,
            "departments": org.get("departments", []), "policy": org.get("policy", {})}

def do_command(body):
    a = body.get("action"); n = str(body.get("number","")).strip()
    def flag(name, on):
        p=os.path.join(RUN,name); os.makedirs(RUN,exist_ok=True)
        if on: open(p,"w").close()
        elif os.path.exists(p): os.remove(p)
    if   a=="pause":  flag("pause",True);        return {"ok":True,"msg":"paused"}
    elif a=="resume": flag("pause",False);       return {"ok":True,"msg":"resumed"}
    elif a=="kill":   flag("kill_switch",True);  return {"ok":True,"msg":"kill-switch on"}
    elif a=="unkill": flag("kill_switch",False); return {"ok":True,"msg":"kill-switch off"}
    elif a=="run":
        ks = os.path.join(RUN, "kill_switch")
        if os.path.exists(ks):
            return {"ok": False, "msg": "kill-switch present — unkill first (run/kill_switch exists)"}
        # Singleton guard (root D): consult run/launcher.pid before spawning. If a live
        # loop already holds it, do NOT add another launcher process — keepalive and
        # operators both hit action=run, so an unguarded Popen over-spawns launchers.
        # A stale/absent pid (os.kill -> ProcessLookupError/OSError) means no live loop;
        # fall through and spawn as today, preserving the run-env seeding below.
        pid_file = os.path.join(RUN, "launcher.pid")
        try:
            with open(pid_file) as _pf:
                _pid = int(_pf.read().strip())
            os.kill(_pid, 0)
        except (FileNotFoundError, ValueError, ProcessLookupError, OSError):
            pass  # absent / unreadable / stale -> proceed to spawn
        else:
            return {"ok": True, "msg": "launcher already running"}
        os.makedirs(RUN,exist_ok=True)
        # Build full env from run-env.sh so the loop gets the complete contract even when
        # the daemon was restarted with an empty env (e.g. after deploy-runtime.sh — issue #148).
        # Never pass the daemon's os.environ directly — it is empty post-deploy, giving the
        # launcher 120 ticks / no integration (finding #1+#2/#142).  set -a auto-exports
        # everything sourced from run-env.sh including ~/.crewboss.env (CLAUDE_CODE_OAUTH_TOKEN).
        run_env_sh = os.path.join(CB_HOME, "run-env.sh")
        home = os.environ.get("HOME", os.path.expanduser("~"))
        seed_env = {
            "HOME": home,
            "PATH": os.environ.get("PATH", "/usr/bin:/bin:/usr/local/bin"),
        }
        try:
            env_raw = subprocess.run(
                ["bash", "-c", f'set -a; source "{run_env_sh}"; set +a; env'],
                capture_output=True, text=True, env=seed_env, timeout=15
            ).stdout
            launch_env = {}
            for line in env_raw.splitlines():
                if "=" in line:
                    k, v = line.split("=", 1)
                    if k and k.isidentifier():
                        launch_env[k] = v
            if not launch_env:
                launch_env = dict(seed_env)
        except Exception:
            launch_env = dict(seed_env)
        subprocess.Popen(["bash", os.path.join(CB_HOME, "crewboss-launcher-gh.sh"), "run"],
                         env=launch_env,
                         stdout=open(os.path.join(RUN,"launcher.out"),"a"),
                         stderr=subprocess.STDOUT)
        return {"ok":True,"msg":"launcher started"}
    elif a=="approve" and n.isdigit():
        sh(["gh","issue","edit",n,"-R",REPO,"--add-label","status:approved","--remove-label","status:plan-review"]); return {"ok":True,"msg":f"approved #{n}"}
    elif a=="hold" and n.isdigit():
        sh(["gh","issue","edit",n,"-R",REPO,"--add-label","hold"]); return {"ok":True,"msg":f"hold #{n}"}
    elif a=="unhold" and n.isdigit():
        sh(["gh","issue","edit",n,"-R",REPO,"--remove-label","hold"]); return {"ok":True,"msg":f"unhold #{n}"}
    elif a=="comment":
        comment_text = str(body.get("comment","")).strip()
        if not n.isdigit() or not comment_text:
            return {"ok":False,"msg":"comment required"}
        with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False, encoding="utf-8") as tmp:
            tmp.write(comment_text); tmp_path = tmp.name
        try:
            sh(["gh","issue","comment",n,"-R",REPO,"--body-file",tmp_path])
        finally:
            try: os.remove(tmp_path)
            except Exception: pass
        return {"ok":True,"msg":f"commented #{n}"}
    elif a=="request-changes":
        comment = str(body.get("comment","")).strip()
        if not n.isdigit() or not comment:
            return {"ok":False,"msg":"comment required"}
        tmp = None
        try:
            with tempfile.NamedTemporaryFile(mode="w",suffix=".txt",delete=False,encoding="utf-8") as f:
                f.write(f"🔁 План возвращён на доработку:\n\n{comment}"); tmp = f.name
            r = subprocess.run(["gh","issue","comment",n,"-R",REPO,"--body-file",tmp],
                               capture_output=True,text=True,timeout=30)
            if r.returncode != 0:
                return {"ok":False,"msg":(r.stderr.strip() or r.stdout.strip() or "gh comment failed")}
        finally:
            if tmp:
                try: os.unlink(tmp)
                except Exception: pass
        sh(["gh","issue","edit",n,"-R",REPO,"--add-label","status:needs-plan","--remove-label","status:plan-review"])
        return {"ok":True,"msg":f"requested changes #{n}"}
    elif a=="delete-comment":
        comment_id = str(body.get("comment_id","")).strip()
        if not n.isdigit():
            return {"ok":False,"msg":"number required"}
        if not comment_id:
            return {"ok":False,"msg":"comment_id required"}
        r = subprocess.run(
            ["gh","api","graphql","-f",
             f'query=mutation {{ deleteIssueComment(input:{{id:"{comment_id}"}}) {{ clientMutationId }} }}'],
            capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            return {"ok":False,"msg":(r.stderr.strip() or r.stdout.strip() or "delete failed")}
        return {"ok":True,"msg":"comment deleted"}
    elif a=="resolve-decision" and n.isdigit():
        decision_text = str(body.get("decision_text") or body.get("comment") or "").strip()
        comment_body = f"✅ Решение:\n\n{decision_text}" if decision_text else "✅ Задача решена."
        tmp = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False, encoding="utf-8") as f:
                f.write(comment_body); tmp = f.name
            rc = subprocess.run(["gh","issue","comment",n,"-R",REPO,"--body-file",tmp],
                                capture_output=True, text=True, timeout=30)
            if rc.returncode != 0:
                return {"ok":False,"msg":(rc.stderr.strip() or rc.stdout.strip() or "comment failed")}
        finally:
            if tmp:
                try: os.unlink(tmp)
                except Exception: pass
        rc2 = subprocess.run(["gh","issue","close",n,"-R",REPO],
                             capture_output=True, text=True, timeout=30)
        if rc2.returncode != 0:
            return {"ok":False,"msg":(rc2.stderr.strip() or rc2.stdout.strip() or "close failed")}
        return {"ok":True,"msg":f"resolved #{n}"}
    elif a=="set-check":
        index = body.get("index")
        checked = body.get("checked")
        if not n.isdigit() or index is None:
            return {"ok":False,"msg":"number and index required"}
        try: index = int(index)
        except Exception: return {"ok":False,"msg":"index must be integer"}
        # Fetch current issue body
        raw = sh(["gh","issue","view",n,"-R",REPO,"--json","body"]) or ""
        if not raw.strip():
            return {"ok":False,"msg":"could not fetch issue body"}
        try: issue_body = json.loads(raw).get("body","") or ""
        except Exception: return {"ok":False,"msg":"could not parse issue body"}
        # Find checkbox lines (supports - and * markers, indentation, [ ] and [x]/[X])
        CHECKBOX_LINE_RE = re.compile(r'^\s*[-*]\s+\[[ xX]\]')
        lines = issue_body.split("\n")
        checkbox_indices = [i for i, ln in enumerate(lines) if CHECKBOX_LINE_RE.match(ln)]
        if index < 0 or index >= len(checkbox_indices):
            return {"ok":False,"msg":f"checkbox index {index} out of range (found {len(checkbox_indices)})"}
        line_idx = checkbox_indices[index]
        original_line = lines[line_idx]
        # Extract item text for history comment
        m = re.match(r'^\s*[-*]\s+\[[ xX]\]\s*(.*)', original_line)
        item_text = m.group(1).strip() if m else original_line.strip()
        # Toggle checkbox marker
        if checked:
            new_line = re.sub(r'\[ \]', '[x]', original_line, count=1)
        else:
            new_line = re.sub(r'\[[xX]\]', '[ ]', original_line, count=1)
        lines[line_idx] = new_line
        new_body = "\n".join(lines)
        # Write updated body back to GitHub
        tmp_body = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", suffix=".md", delete=False, encoding="utf-8") as f:
                f.write(new_body); tmp_body = f.name
            r = subprocess.run(["gh","issue","edit",n,"-R",REPO,"--body-file",tmp_body],
                                capture_output=True, text=True, timeout=30)
            if r.returncode != 0:
                return {"ok":False,"msg":(r.stderr.strip() or r.stdout.strip() or "gh edit failed")}
        finally:
            if tmp_body:
                try: os.unlink(tmp_body)
                except Exception: pass
        # Post history comment
        history_text = f"✅ выполнено: {item_text}" if checked else f"↩️ снята отметка: {item_text}"
        tmp_comment = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False, encoding="utf-8") as f:
                f.write(history_text); tmp_comment = f.name
            sh(["gh","issue","comment",n,"-R",REPO,"--body-file",tmp_comment])
        finally:
            if tmp_comment:
                try: os.unlink(tmp_comment)
                except Exception: pass
        return {"ok":True,"msg":f"checkbox {index} updated"}
    elif a=="merge":
        if not n.isdigit():
            return {"ok": False, "msg": "invalid issue number"}
        pr_num_path = os.path.join(RUN, "state", f"finale-{n}", "pr_num")
        try:
            pr_num = open(pr_num_path).read().strip()
        except Exception:
            pr_num = ""
        if not pr_num:
            return {"ok": False, "msg": "no finale PR found"}
        # Idempotency guard: skip everything if PR is already merged
        r_state = subprocess.run(
            ["gh", "pr", "view", pr_num, "-R", REPO, "--json", "state", "--jq", ".state"],
            capture_output=True, text=True, timeout=30)
        if r_state.stdout.strip() == "MERGED":
            return {"ok": True, "msg": "already merged -- no-op", "merged": True}
        # Step 1: Guard CB_INTEGRATOR
        if not CB_INTEGRATOR or not os.path.exists(CB_INTEGRATOR):
            return {"ok": False, "msg": f"CB_INTEGRATOR not found: {CB_INTEGRATOR}"}
        # Step 2: Detect draft status and promote if needed
        r = subprocess.run(
            ["gh", "pr", "view", pr_num, "-R", REPO, "--json", "isDraft", "--jq", ".isDraft"],
            capture_output=True, text=True, timeout=30)
        if r.stdout.strip() == "true":
            r = subprocess.run(["gh", "pr", "ready", pr_num, "-R", REPO],
                               capture_output=True, text=True, timeout=30)
            if r.returncode != 0:
                return {"ok": False, "msg": f"gh pr ready failed: {r.stderr.strip()}"}
        # Step 3: Invoke verify-merged
        verify_timeout = int(os.environ.get("CB_VERIFY_TIMEOUT", "600")) + 60
        result = subprocess.run(
            ["bash", CB_INTEGRATOR, "verify-merged", f"charter/{n}", "main",
             "--remote", f"https://github.com/{REPO}"],
            capture_output=True, text=True, timeout=verify_timeout)
        if result.returncode != 0:
            return {"ok": False, "msg": "verify-merged failed", "verify_verdict": "red",
                    "verify_output": result.stdout}
        # Step 4: Merge
        r = subprocess.run(["gh", "pr", "merge", pr_num, "-R", REPO, "--admin", "--merge"],
                           capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            return {"ok": False, "msg": f"pr merge failed: {r.stderr.strip()}"}
        # Step 5A: Remove status:approved label (best-effort, non-blocking)
        subprocess.run(
            ["gh", "issue", "edit", n, "-R", REPO, "--remove-label", "status:approved"],
            capture_output=True, text=True, timeout=30)
        # Step 5B: Close issue (required -- failure surfaces as ok=False so caller can retry)
        r2 = subprocess.run(
            ["gh", "issue", "close", n, "-R", REPO, "--comment", "Charter merged and closed."],
            capture_output=True, text=True, timeout=30)
        if r2.returncode != 0:
            return {"ok": False, "msg": f"merge succeeded but issue close failed: {r2.stderr.strip()}"}
        # Step 5C: Only unlink pr_num_path after confirmed close (preserves retry invariant)
        os.unlink(pr_num_path)
        # Step 5D: Prune merged charter from queue (best-effort, non-blocking)
        try:
            _qdata = read_json(os.path.join(RUN, "queue.json"), {"order": []})
            _qorder = [x for x in _qdata.get("order", []) if x != int(n)]
            save_queue(_qorder)
        except Exception:
            pass  # best-effort — never block a successful merge
        return {"ok": True, "verify_verdict": "green", "verify_output": result.stdout, "merged": True}
    elif a in (CMD_APPROVE_HD, CMD_REQUEST_CHANGES_HD, CMD_CLOSE_HD) and n.isdigit():
        # ── HD-gate dispatch (charter #442 api-hd-actions) ──────────────────────
        # 1. Fetch the HD issue (labels + title + body)
        _hd_raw = sh(["gh","issue","view",n,"-R",REPO,"--json","labels,title,body"])
        try:
            _hd_issue = json.loads(_hd_raw) if (_hd_raw or "").strip() else {}
        except Exception:
            _hd_issue = {}
        _hd_lnames = [l["name"] for l in _hd_issue.get("labels", [])]
        if "type:human-decision" not in _hd_lnames:
            return {"ok": False, "msg": f"issue #{n} does not carry label type:human-decision"}
        _hd_title = _hd_issue.get("title", "")
        _hd_body  = _hd_issue.get("body",  "")
        # 2. Extract charter number from HD body ("Charter: #N")
        _cn = _charter_of(_hd_body)
        if _cn is None:
            return {"ok": False, "msg": f"could not parse Charter: #N from HD issue #{n}"}
        # 3. Identify HD type from title
        _ht = _hd_type(_hd_title)

        if a == CMD_APPROVE_HD:
            # Charter label mutations that unblock the matching launcher gate
            _add, _rm = [], []
            if   _ht == "composition": _add=["composition:approved","status:needs-plan"]; _rm=["status:team-review"]
            elif _ht == "analysis":    _add=["review:agreed"]
            elif _ht == "approval":    _add=["composition:approved","status:needs-plan"]; _rm=["status:team-review"]
            elif _ht == "plan":        _add=["plan:agreed"]
            elif _ht == "acceptance":  _add=["accept:agreed"]
            else: return {"ok": False, "msg": f"unrecognized HD type for issue #{n}: {_hd_title!r}"}
            _eargs = ["gh","issue","edit",str(_cn),"-R",REPO]
            if _add: _eargs += ["--add-label",    ",".join(_add)]
            if _rm:  _eargs += ["--remove-label", ",".join(_rm)]
            sh(_eargs)
            sh(["gh","issue","close",n,"-R",REPO,"--comment",
                f"HD approved — charter #{_cn} labels updated."])
            return {"ok": True, "msg": f"approve-hd #{n} (charter #{_cn})"}

        elif a == CMD_REQUEST_CHANGES_HD:
            _reason = str(body.get("reason","")).strip()
            # 1. Comment on the CHARTER with rejection reason
            _cc = f"❌ Human decision rejected: {_reason}" if _reason else "❌ Human decision rejected."
            sh(["gh","issue","comment",str(_cn),"-R",REPO,"--body",_cc])
            # 2. Exception: approval-required HD re-routes charter to analysis
            if _ht == "approval":
                sh(["gh","issue","edit",str(_cn),"-R",REPO,
                    "--add-label","status:needs-analysis","--remove-label","status:team-review"])
            # 3. Close HD with rejection comment
            _hc = f"❌ Changes requested: {_reason}" if _reason else "❌ Changes requested."
            sh(["gh","issue","close",n,"-R",REPO,"--comment",_hc])
            return {"ok": True, "msg": f"request-changes-hd #{n} (charter #{_cn})"}

        elif a == CMD_CLOSE_HD:
            # Neutral close — NO charter label mutations whatsoever
            sh(["gh","issue","close",n,"-R",REPO,"--comment",
                "HD closed (neutral — no charter label changes)."])
            return {"ok": True, "msg": f"close-hd #{n}"}

    return {"ok":False,"msg":f"unknown action: {a}"}

def do_issue(body):
    """Create a GitHub issue via gh CLI. kind=charter or kind=task."""
    kind  = body.get("kind", "")
    title = (body.get("title") or "").strip()
    if not kind or not title:
        return {"ok": False, "msg": "kind and title required"}

    if kind == "charter":
        what             = (body.get("what")        or "").strip()
        why              = (body.get("why")         or "").strip()
        scope            = (body.get("scope")       or "").strip()
        constraints      = (body.get("constraints") or "").strip()
        acceptance       = (body.get("acceptance")  or "").strip()
        auto_plan_approve = bool(body.get("auto_plan_approve", False))
        auto_merge        = bool(body.get("auto_merge", False))
        if not what or not why:
            return {"ok": False, "msg": "what and why are required for charter"}
        text = (
            "## Цель\n\n"
            f"**WHAT:** {what}\n\n"
            f"**WHY:** {why}\n\n"
            "## Скоуп\n\n"
            f"{scope}\n\n"
            "## Констрейнты\n\n"
            f"{constraints}\n\n"
            "## Acceptance\n\n"
            f"{acceptance}\n"
        )
        label = "type:charter,status:needs-plan"
        if auto_plan_approve:
            label += ",auto:plan-approve"
        if auto_merge:
            label += ",auto:merge"
    elif kind == "task":
        desc      = (body.get("description") or "").strip()
        charter_n = body.get("charter")
        depends   = (body.get("depends_on")  or "").strip()
        if not desc or not charter_n:
            return {"ok": False, "msg": "description and charter are required for task"}
        text = desc + f"\n\nCharter: #{charter_n}"
        if depends:
            text += f"\nDepends-on: #{depends}"
        text += "\n"
        label = "type:agent"
    else:
        return {"ok": False, "msg": f"unknown kind: {kind}"}

    with tempfile.NamedTemporaryFile(mode="w", suffix=".md", delete=False) as f:
        f.write(text)
        fname = f.name
    try:
        args = ["gh", "issue", "create", "--title", title, "--label", label, "--body-file", fname]
        if REPO:
            args += ["-R", REPO]
        r = subprocess.run(args, capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            return {"ok": False, "msg": (r.stderr or r.stdout or "gh error").strip()}
        url = (r.stdout or "").strip()
        m = re.search(r"/issues/(\d+)", url)
        num = int(m.group(1)) if m else None
        return {"ok": True, "msg": f"created #{num}" if num else "created", "number": num}
    except Exception as e:
        return {"ok": False, "msg": str(e)}
    finally:
        try: os.unlink(fname)
        except Exception: pass


def save_team(body):
    """Persist an edited org (policy+departments+nodes) back to CB_TEAM/org.json. The browser
    validates invariants live; here we keep only the structure and write atomically."""
    nodes = body.get("nodes")
    if not isinstance(nodes, list) or not nodes: return {"ok":False,"msg":"no nodes"}
    org = {"policy": body.get("policy",{}), "departments": body.get("departments",[]),
           "nodes": [{"role":x.get("role"),"reports_to":x.get("reports_to")} for x in nodes]}
    try:
        os.makedirs(CB_TEAM, exist_ok=True)
        p = os.path.join(CB_TEAM,"org.json"); tmp=p+".tmp"
        open(tmp,"w").write(json.dumps(org, indent=2)); os.replace(tmp, p)
        return {"ok":True,"msg":f"saved org.json ({len(nodes)} roles)"}
    except Exception as e:
        return {"ok":False,"msg":f"save failed: {e}"}

def _plain_copy_tree(src, dst):
    """Recursively copy a directory using plain open/read/write (avoids sendfile syscall)."""
    os.makedirs(dst, exist_ok=True)
    for item in os.listdir(src):
        s = os.path.join(src, item); d = os.path.join(dst, item)
        if os.path.isdir(s): _plain_copy_tree(s, d)
        else:
            with open(s, 'rb') as fi: data = fi.read()
            with open(d, 'wb') as fo: fo.write(data)

def _plain_copy_file(src, dst):
    with open(src, 'rb') as fi: data = fi.read()
    with open(dst, 'wb') as fo: fo.write(data)

def _parse_role_md(path):
    """Return (frontmatter_dict, body_str) from a roles/<name>.md file."""
    try:
        lines = open(path, encoding='utf-8', errors='replace').read().splitlines()
    except Exception:
        return {}, ''
    if not lines or lines[0].strip() != '---':
        return {}, '\n'.join(lines).strip()
    fm = {}; i = 1
    while i < len(lines):
        if lines[i].strip() == '---': break
        if ':' in lines[i]:
            k, v = lines[i].split(':', 1); fm[k.strip()] = v.strip()
        i += 1
    body = '\n'.join(lines[i+1:]).strip() if i + 1 < len(lines) else ''
    return fm, body

def get_role(name):
    if not _ROLE_NAME_RE.match(name):
        return {"ok": False, "msg": "invalid role name"}
    path = os.path.join(CB_TEAM, 'roles', name + '.md')
    if not os.path.exists(path):
        return {"ok": False, "msg": f"role '{name}' not found"}
    fm, prompt = _parse_role_md(path)
    return {"ok": True, "name": name, "frontmatter": fm, "prompt": prompt}

def _role_invariant_check(name, kind, tools, code_blind, model='', accesses=''):
    """Mirror the doctor's role-invariant rules so we catch errors even for roles not yet in org.

    model: known routing values = {'anthropic', 'qwen'} or a concrete model id string;
           empty or unknown values are forward-compatible and NOT blocked (forward-compat).
    accesses: CSV of access tokens (format check only; empty = deny-all semantics;
              enforcement is in F2/nsjail — only schema here, no hard allowlist yet).
    """
    _has = lambda t: bool(re.search(r'(?i)\b' + t + r'\b', tools))
    errs = []
    if kind in ('manager', 'analyst'):
        for t in ('Edit', 'Write', 'Agent'):
            if _has(t): errs.append(f"  FAIL {kind} '{name}' must NOT have {t} (tools: {tools})")
    elif kind == 'executor':
        if not _has('Edit') and not _has('Write'):
            errs.append(f"  FAIL executor '{name}' has no Edit/Write (tools: {tools})")
    else:
        errs.append(f"  FAIL role '{name}' has unknown kind '{kind}' (expected executor|analyst|manager)")
    if code_blind and _has('Read'):
        errs.append(f"  FAIL code-blind role '{name}' must NOT have Read (tools: {tools})")
    # model: forward-compat — known set (anthropic, qwen) documented; empty/unknown not blocked
    # accesses: CSV token format check — each token must match [a-zA-Z0-9:_/-]+
    if accesses:
        _csv_token_re = re.compile(r'^[a-zA-Z0-9:_/\-]+$')
        bad_tokens = [t.strip() for t in accesses.split(',')
                      if t.strip() and not _csv_token_re.match(t.strip())]
        if bad_tokens:
            errs.append(
                f"  FAIL role '{name}' accesses has invalid token format: {bad_tokens!r}"
                " (expected CSV of [a-zA-Z0-9:_/-]+)"
            )
    if errs:
        n = len(errs)
        return "== role invariants ==\n" + "\n".join(errs) + f"\n\nmanifest-doctor: {n} problem(s)"
    return ""

def save_role(body):
    name = str(body.get('name', '')).strip()
    if not _ROLE_NAME_RE.match(name):
        return {"ok": False, "msg": "invalid role name (must match ^[a-z0-9-]+$)"}
    kind      = str(body.get('kind',    '')).strip()
    domain    = str(body.get('domain',  '')).strip()
    tools     = str(body.get('tools',   '')).strip()
    profile   = str(body.get('profile', '')).strip()
    code_blind= bool(body.get('code_blind', False))
    skills    = str(body.get('skills',  '') or '').strip()
    model     = str(body.get('model',   '') or '').strip()
    accesses  = str(body.get('accesses','') or '').strip()
    prompt    = str(body.get('prompt',  '') or '').strip()

    # Pre-validate role invariants (mirrors doctor rules; catches new roles not yet in org)
    inv_err = _role_invariant_check(name, kind, tools, code_blind, model=model, accesses=accesses)
    if inv_err:
        return {"ok": False, "msg": inv_err}

    fm_lines = ['---', f'name: {name}', f'kind: {kind}', f'domain: {domain}',
                f'tools: {tools}', f'profile: {profile}']
    if code_blind: fm_lines.append('code_blind: true')
    if skills:     fm_lines.append(f'skills: {skills}')
    if model:      fm_lines.append(f'model: {model}')
    if accesses:   fm_lines.append(f'accesses: {accesses}')
    fm_lines.append('---')
    content = '\n'.join(fm_lines) + '\n' + (prompt + '\n' if prompt else '')

    tmpdir = tempfile.mkdtemp(prefix='crewboss-role-')
    try:
        tmp_manifest = os.path.join(tmpdir, 'manifest')
        if os.path.isdir(CB_TEAM):
            _plain_copy_tree(CB_TEAM, tmp_manifest)
        else:
            os.makedirs(tmp_manifest)
        os.makedirs(os.path.join(tmp_manifest, 'roles'), exist_ok=True)
        with open(os.path.join(tmp_manifest, 'roles', name + '.md'), 'w', encoding='utf-8') as f:
            f.write(content)
        # locate manifest-doctor.sh (prefer CB_TEAM copy, fall back to repo's team-example)
        doctor = os.path.join(CB_TEAM, 'manifest-doctor.sh')
        if not os.path.isfile(doctor):
            script_dir = os.path.dirname(os.path.abspath(__file__))
            doctor = os.path.abspath(os.path.join(script_dir, '..', '..', 'team-example', 'manifest-doctor.sh'))
        if not os.path.isfile(doctor):
            return {"ok": False, "msg": "manifest-doctor.sh not found"}
        r = subprocess.run(['bash', doctor, tmp_manifest], capture_output=True, text=True, timeout=30)
        out = _ANSI_RE.sub('', (r.stdout + r.stderr).strip())
        if r.returncode == 0:
            real_roles = os.path.join(CB_TEAM, 'roles')
            os.makedirs(real_roles, exist_ok=True)
            _plain_copy_file(os.path.join(tmp_manifest, 'roles', name + '.md'),
                             os.path.join(real_roles, name + '.md'))
            return {"ok": True}
        return {"ok": False, "msg": out}
    except Exception as e:
        return {"ok": False, "msg": f"error: {e}"}
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin","*")
        self.send_header("Access-Control-Allow-Headers","authorization,content-type")
        self.send_header("Access-Control-Allow-Methods","GET,POST,OPTIONS")
    def _send(self, code, obj):
        b=json.dumps(obj).encode(); self.send_response(code)
        self.send_header("Content-Type","application/json"); self._cors()
        self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def _auth_ok(self):
        if not TOKEN: return True
        if self.headers.get("Authorization","") == f"Bearer {TOKEN}": return True
        # EventSource (SSE) can't set headers -> allow ?token= on GET requests.
        from urllib.parse import urlparse, parse_qs
        return parse_qs(urlparse(self.path).query).get("token",[""])[0] == TOKEN
    def do_OPTIONS(self): self.send_response(204); self._cors(); self.end_headers()
    def _serve_static(self, path):
        # Serve the built dashboard (vite dist) so the box serves both API and UI on one
        # port — the user opens http://127.0.0.1:<port>/ over the existing SSH tunnel.
        import mimetypes
        root = os.environ.get("CB_WEB_DIR",
                              os.path.join(os.path.dirname(os.path.abspath(__file__)), "www"))
        rel = "index.html" if path in ("/", "") else path.lstrip("/")
        full = os.path.normpath(os.path.join(root, rel))
        if not full.startswith(os.path.normpath(root)):
            return self._send(403, {"ok": False, "msg": "forbidden"})
        if not os.path.isfile(full):
            full = os.path.join(root, "index.html")  # SPA fallback for client routes
        if not os.path.isfile(full):
            return self._send(404, {"ok": False, "msg": "ui not built (set CB_WEB_DIR or build ui/app)"})
        ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
        with open(full, "rb") as f: data = f.read()
        self.send_response(200); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data))); self._cors(); self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        path = self.path.split("?",1)[0]
        if not path.startswith("/api"): return self._serve_static(path)  # dashboard UI
        if path=="/api/health": return self._send(200,{"ok":True,"repo":REPO})
        if not self._auth_ok(): return self._send(401,{"ok":False,"msg":"unauthorized"})
        if path=="/api/state": return self._send(200, build_state())
        if path.startswith("/api/task/"):
            tail = path.rsplit("/",1)[-1]
            if not tail.isdigit(): return self._send(400,{"ok":False,"msg":"bad task id"})
            return self._send(200, build_task(int(tail)))
        if path.startswith("/api/comments/"):
            tail = path.rsplit("/",1)[-1]
            if not tail.isdigit(): return self._send(400,{"ok":False,"msg":"bad issue id"})
            return self._send(200, build_comments(int(tail)))
        if path=="/api/team": return self._send(200, build_team())
        if path.startswith("/api/role/"):
            name = path[len("/api/role/"):]
            if not name or "/" in name or ".." in name:
                return self._send(400, {"ok":False,"msg":"invalid role name"})
            return self._send(200, get_role(name))
        if path=="/api/events":
            self.send_response(200); self.send_header("Content-Type","text/event-stream")
            self.send_header("Cache-Control","no-cache"); self._cors(); self.end_headers()
            last=None
            try:
                while True:
                    cur=build_state(); s=json.dumps(cur,sort_keys=True)
                    if s!=last:
                        self.wfile.write(f"event: state\ndata: {json.dumps(cur)}\n\n".encode()); self.wfile.flush(); last=s
                    else:
                        self.wfile.write(b": keepalive\n\n"); self.wfile.flush()
                    # CB_API_POLL — seconds between SSE board refreshes. Default 10
                    # (was 3): each open dashboard tab re-queried GitHub every 3s,
                    # the dominant RL burner (~1200 reads/hr/tab) that silently
                    # exhausted the GraphQL budget (#526). 10s stays responsive
                    # while cutting that ~3x. Override via env for live debugging.
                    _webhook_kick.wait(timeout=int(os.environ.get("CB_API_POLL","10")))
                    _webhook_kick.clear()
            except Exception: return
        if path == "/api/search":
            from urllib.parse import urlparse, parse_qs
            q = parse_qs(urlparse(self.path).query).get("q", [""])[0]
            return self._send(200, search_board(q))
        return self._send(404,{"ok":False,"msg":"not found"})
    def do_POST(self):
        path = self.path.split("?",1)[0]          # 1. extract path first
        if path == "/api/gh-webhook":              # 2. webhook bypass (before Bearer check)
            return self._handle_webhook()
        if not self._auth_ok():                    # 3. auth gate for all other routes
            return self._send(401,{"ok":False,"msg":"unauthorized"})
        n=int(self.headers.get("Content-Length",0) or 0)
        try: body=json.loads(self.rfile.read(n) or b"{}")
        except Exception: body={}
        if path=="/api/command": return self._send(200, do_command(body))
        if path=="/api/team":    return self._send(200, save_team(body))
        if path=="/api/issue":   return self._send(200, do_issue(body))
        if path=="/api/role":    return self._send(200, save_role(body))
        if path=="/api/queue":
            order = body.get("order")
            if not isinstance(order, list):
                return self._send(400, {"ok":False,"msg":"order must be a list"})
            try: order = [int(x) for x in order]
            except (ValueError, TypeError):
                return self._send(400, {"ok":False,"msg":"order values must be integers"})
            return self._send(200, save_queue(order))
        return self._send(404,{"ok":False,"msg":"not found"})
    def _handle_webhook(self):
        secret = os.environ.get("CB_WEBHOOK_SECRET", "")
        if not secret:
            return self._send(500, {"ok": False, "msg": "server error"})
        length = int(self.headers.get("Content-Length", 0))
        body_bytes = self.rfile.read(length)
        sig_header = self.headers.get("X-Hub-Signature-256", "")
        # CRITICAL: GitHub sends "sha256=<hexdigest>", not bare hex.
        # Strip prefix before comparing; bare-hex or absent prefix → 401.
        expected = sig_header[len("sha256="):] if sig_header.startswith("sha256=") else ""
        computed = hmac.new(secret.encode(), body_bytes, hashlib.sha256).hexdigest()
        if not expected or not hmac.compare_digest(computed, expected):
            return self._send(401, {"ok": False, "msg": "unauthorized"})
        # Never log body_bytes or secret.
        try:
            event_type = self.headers.get("X-GitHub-Event", "")
        except Exception:
            event_type = ""
        if event_type in ("issues", "pull_request"):
            _webhook_kick.set()
        return self._send(200, {"ok": True})

if __name__=="__main__":
    if "--selftest-search" in sys.argv:
        # Inline proof for the NEW single-call search_board() (charter #994 /
        # issues #1054/#1057). Drives the rewritten code path: search_board() makes
        # EXACTLY ONE bounded gh call per query and NEVER walks the repo.
        #   * NUMBER query  -> ONE /repos/OWNER/REPO/issues/{N} returning a single
        #                      issue OBJECT (not an array).
        #   * TEXT query    -> ONE /search/issues returning {"items": [...]}.
        # We mock sh() to route by request PATH and LOG every call, then assert
        # single-call-per-query, number/digit/text paths, case-insensitivity,
        # scope-pinning (no qualifier injection), empty->[], not-found->[].
        import json as _json
        import re as _re
        import sys as _sys
        _failures = []
        _mod = _sys.modules[__name__]
        _real_sh  = _mod.sh
        _real_repo = _mod.REPO
        _mod.REPO = "owner/repo"  # deterministic scope for the assertions

        # Fixtures keyed by number. #99 is CLOSED (uppercase) to prove the
        # case-insensitive done-mapping; labels exercise kind/state parity.
        _ISSUES = {
            42:  {"number": 42,  "title": "Fix the alpha widget", "state": "open",
                  "labels": [{"name": "type:leaf"}, {"name": "status:in-progress"}]},
            99:  {"number": 99,  "title": "Old closed widget",    "state": "CLOSED",
                  "labels": [{"name": "type:leaf"}]},
            100: {"number": 100, "title": "Charter platform",     "state": "open",
                  "labels": [{"name": "type:charter"}]},
        }
        _calls = []  # every (args) passed to the mocked sh()

        def _fake_sh(args, timeout=30):
            _calls.append(list(args))
            path = next((a for a in args if a.startswith("/")), "")
            m = _re.match(r"^/repos/[^/]+/[^/]+/issues/(\d+)$", path)
            if m:  # NUMBER path -> single OBJECT, or error object on not-found
                obj = _ISSUES.get(int(m.group(1)))
                if obj is None:
                    return _json.dumps({"message": "Not Found"})
                return _json.dumps(obj)
            if path == "/search/issues":  # TEXT path -> {"items": [...]}
                q = next((a[2:] for a in args if a.startswith("q=")), "")
                # Plain terms = qualifier-free tokens of the (lowercased) query.
                terms = [t for t in q.lower().split() if ":" not in t]
                items = [_ISSUES[k] for k in sorted(_ISSUES)
                         if terms and all(t in _ISSUES[k]["title"].lower() for t in terms)]
                return _json.dumps({"items": items})
            return ""

        def _last_path():
            for a in reversed(_calls[-1]):
                if a.startswith("/"):
                    return a
            return ""

        try:
            _mod.sh = _fake_sh

            # --- T1: empty q -> {"results": []}, NO gh call ---
            _calls.clear()
            _r = search_board("")
            if _r != {"results": []}:
                _failures.append(f"T1 FAIL empty q returned {_r!r}")
            if _calls:
                _failures.append(f"T1 FAIL empty q made gh calls: {_calls!r}")
            _r = search_board("   ")
            if _r != {"results": []} or _calls:
                _failures.append("T1 FAIL whitespace-only q must short-circuit with no gh call")

            # --- T2: number '#42' -> ONE /repos/.../issues/42, single result ---
            _calls.clear()
            _r = search_board("#42")
            if len(_calls) != 1:
                _failures.append(f"T2 FAIL '#42' made {len(_calls)} gh calls (expected 1)")
            elif _last_path() != "/repos/owner/repo/issues/42":
                _failures.append(f"T2 FAIL '#42' path was {_last_path()!r}")
            if [i["n"] for i in _r["results"]] != [42]:
                _failures.append(f"T2 FAIL '#42' results {_r!r}")
            if _r["results"] and _r["results"][0]["state"] != "in-progress":
                _failures.append(f"T2 FAIL '#42' state {_r['results'][0]['state']!r} expected in-progress")
            # no /search/issues call leaked
            if any(_last_p == "/search/issues" for _last_p in
                   (next((a for a in c if a.startswith("/")), "") for c in _calls)):
                _failures.append("T2 FAIL number query leaked a /search/issues call")

            # --- T3: digit-only '99' -> number path; CLOSED -> done ---
            _calls.clear()
            _r = search_board("99")
            if len(_calls) != 1 or _last_path() != "/repos/owner/repo/issues/99":
                _failures.append(f"T3 FAIL '99' calls={_calls!r}")
            if [i["n"] for i in _r["results"]] != [99]:
                _failures.append(f"T3 FAIL '99' results {_r!r}")
            elif _r["results"][0]["state"] != "done":
                _failures.append(f"T3 FAIL CLOSED #99 state={_r['results'][0]['state']!r} expected done")

            # --- T4: not-found number -> {"results": []} (never raises) ---
            _calls.clear()
            _r = search_board("88888")
            if _r != {"results": []}:
                _failures.append(f"T4 FAIL not-found number returned {_r!r}")
            if len(_calls) != 1:
                _failures.append(f"T4 FAIL not-found made {len(_calls)} calls (expected 1)")

            # --- T5: text 'widget' -> ONE /search/issues, .items array ---
            _calls.clear()
            _r = search_board("widget")
            if len(_calls) != 1 or _last_path() != "/search/issues":
                _failures.append(f"T5 FAIL text calls={_calls!r}")
            _ns = sorted(i["n"] for i in _r["results"])
            if _ns != [42, 99]:
                _failures.append(f"T5 FAIL text 'widget' results {_ns!r} expected [42, 99]")
            # the pinned scope must be present in the q field
            _qfield = next((a[2:] for a in _calls[-1] if a.startswith("q=")), "")
            if "repo:owner/repo is:issue" not in _qfield:
                _failures.append(f"T5 FAIL q field not scope-pinned: {_qfield!r}")

            # --- T6: case-insensitivity: 'WIDGET' == 'widget' ---
            _r_lo = search_board("widget")
            _r_up = search_board("WIDGET")
            if sorted(i["n"] for i in _r_lo["results"]) != sorted(i["n"] for i in _r_up["results"]):
                _failures.append("T6 FAIL case-sensitivity: 'widget' != 'WIDGET'")

            # --- T7: scoping — user qualifiers stripped, cannot widen scope ---
            _calls.clear()
            _r = search_board("repo:other/x org:foo is:pr widget")
            _qfield = next((a[2:] for a in _calls[-1] if a.startswith("q=")), "")
            if "repo:owner/repo is:issue" not in _qfield:
                _failures.append(f"T7 FAIL scope pin lost: {_qfield!r}")
            _ql = _qfield.lower()
            if "other/x" in _ql or "org:foo" in _ql or "is:pr" in _ql:
                _failures.append(f"T7 FAIL user qualifiers leaked into q: {_qfield!r}")
            # widget term still survives -> still matches
            if sorted(i["n"] for i in _r["results"]) != [42, 99]:
                _failures.append(f"T7 FAIL stripped-qualifier query lost its term: {_r!r}")

            # --- T8: single-call-per-query holds across all paths ---
            for _qq in ("#42", "100", "platform", "nonsense-xyz"):
                _calls.clear()
                search_board(_qq)
                if len(_calls) != 1:
                    _failures.append(f"T8 FAIL '{_qq}' made {len(_calls)} gh calls (expected exactly 1)")

            # --- T9 (#1057): a qualifier-ONLY query reduces to zero plain terms
            # -> {"results": []} with NO gh call (never a bare scope-only flood) ---
            _calls.clear()
            _r = search_board("is:pr repo:other/x org:foo")
            if _r != {"results": []}:
                _failures.append(f"T9 FAIL qualifier-only query returned {_r!r} (expected [])")
            if _calls:
                _failures.append(f"T9 FAIL qualifier-only query made gh calls: {_calls!r}")

        finally:
            _mod.sh = _real_sh
            _mod.REPO = _real_repo

        if _failures:
            for _f in _failures:
                print(_f)
            sys.exit(1)
        print("PASS selftest-search: empty/whitespace no-op, number+digit single-OBJECT path, "
              "not-found->[], text /search/issues .items, case-insensitive, scope-pinned "
              "(qualifier injection stripped), single-call-per-query")
        sys.exit(0)

    if "--selftest-synthetic-gate" in sys.argv:
        # Verify that synthetic chips respect loop_running
        _by_n = {
            10: {"state": "review",     "kind": "leaf",    "title": "Leaf in review"},
            20: {"state": "needs-plan", "kind": "charter", "title": "Charter needing plan"},
        }
        failures = []

        # --- loop_running=False: integrator chip must be phase="awaiting-integration", tech-lead="awaiting" ---
        agents_idle = build_agents(_by_n, loop_running=False)
        for a in agents_idle:
            if a.get("role") == "integrator" and a.get("pid") is None:
                if a.get("phase") != "awaiting-integration":
                    failures.append(f"FAIL integrator phase={a.get('phase')!r} when loop_running=False (expected 'awaiting-integration')")
            if a.get("role") == "tech-lead" and a.get("pid") is None:
                if a.get("phase") != "awaiting":
                    failures.append(f"FAIL tech-lead phase={a.get('phase')!r} when loop_running=False (expected 'awaiting')")
        # Confirm chips ARE present (not suppressed)
        if not any(a.get("role") == "integrator" and a.get("pid") is None for a in agents_idle):
            failures.append("FAIL integrator synthetic chip missing when loop_running=False")
        if not any(a.get("role") == "tech-lead" and a.get("pid") is None for a in agents_idle):
            failures.append("FAIL tech-lead synthetic chip missing when loop_running=False")

        # --- loop_running=True: integrator=awaiting-integration, tech-lead=planning ---
        agents_live = build_agents(_by_n, loop_running=True)
        for a in agents_live:
            if a.get("role") == "integrator" and a.get("pid") is None:
                if a.get("phase") != "awaiting-integration":
                    failures.append(f"FAIL integrator phase={a.get('phase')!r} when loop_running=True (expected 'awaiting-integration')")
            if a.get("role") == "tech-lead" and a.get("pid") is None:
                if a.get("phase") != "planning":
                    failures.append(f"FAIL tech-lead phase={a.get('phase')!r} when loop_running=True (expected 'planning')")

        if failures:
            for f in failures:
                print(f)
            sys.exit(1)
        print("PASS synthetic-gate: integrator→awaiting-integration, tech-lead idle→awaiting/live→planning")
        sys.exit(0)

    if "--selftest-merge" in sys.argv:
        from unittest.mock import patch, MagicMock, mock_open
        _merge_failures = []
        _N = "716"

        # --- Test 1: idempotency guard (already-merged PR) ---
        # When the state-check returns MERGED the function must return immediately;
        # only 1 subprocess call should occur (no verify-script or pr-merge invoked).
        with patch("subprocess.run", side_effect=[
                MagicMock(stdout="MERGED", returncode=0),  # state-check
        ]) as _mock_run1, \
             patch("builtins.open", mock_open(read_data="PR_ID")), \
             patch("os.path.exists", return_value=True), \
             patch("os.unlink"):
            _res1 = do_command({"action": "merge", "number": _N})
            if _res1.get("ok") is not True:
                _merge_failures.append(
                    f"T1 FAIL ok={_res1.get('ok')!r} expected True")
            if _res1.get("merged") is not True:
                _merge_failures.append(
                    f"T1 FAIL merged={_res1.get('merged')!r} expected True")
            if _mock_run1.call_count != 1:
                _merge_failures.append(
                    f"T1 FAIL call_count={_mock_run1.call_count} expected 1 "
                    "(idempotency guard should short-circuit after state-check)")

        # --- Test 2: atomic cleanup happy path ---
        # order: state-check → isDraft → verify-script → pr-merge-cmd →
        #        issue-edit --remove-label → issue-close-cmd
        # Expect: ok=True, os.unlink(pr_num_path) called, both remove-label and
        # issue-close appear in subprocess call_args_list.
        _mock_unlink2 = MagicMock()
        with patch("subprocess.run", side_effect=[
                MagicMock(stdout="OPEN", returncode=0),    # state-check
                MagicMock(stdout="false", returncode=0),   # isDraft
                MagicMock(returncode=0),                   # verify-script
                MagicMock(returncode=0),                   # pr-merge-cmd
                MagicMock(returncode=0),                   # issue-edit --remove-label
                MagicMock(returncode=0),                   # issue-close-cmd
        ]) as _mock_run2, \
             patch("builtins.open", mock_open(read_data="PR_ID")), \
             patch("os.path.exists", return_value=True), \
             patch("os.unlink", _mock_unlink2):
            _res2 = do_command({"action": "merge", "number": _N})
            _pr_num_path2 = os.path.join(RUN, "state", f"finale-{_N}", "pr_num")
            if _res2.get("ok") is not True:
                _merge_failures.append(
                    f"T2 FAIL ok={_res2.get('ok')!r} expected True")
            _unlink_calls2 = [str(c) for c in _mock_unlink2.call_args_list]
            if not any(_pr_num_path2 in c for c in _unlink_calls2):
                _merge_failures.append(
                    f"T2 FAIL os.unlink not called with pr_num_path {_pr_num_path2!r}")
            _run_args2 = [str(c) for c in _mock_run2.call_args_list]
            if not any("--remove-label" in a for a in _run_args2):
                _merge_failures.append(
                    "T2 FAIL --remove-label not found in subprocess call_args_list")
            if not any("close" in a for a in _run_args2):
                _merge_failures.append(
                    "T2 FAIL issue-close-cmd not found in subprocess call_args_list")

        # --- Test 3: close-fail surfaces as ok=False AND pr_num file survives ---
        # Entry six (issue-close-cmd) returns returncode=1; the function must
        # return ok=False with a message referencing the failure, and must NOT
        # call os.unlink (preserves the retry invariant / no approved-zombie).
        _mock_unlink3 = MagicMock()
        with patch("subprocess.run", side_effect=[
                MagicMock(stdout="OPEN", returncode=0),    # state-check
                MagicMock(stdout="false", returncode=0),   # isDraft
                MagicMock(returncode=0),                   # verify-script
                MagicMock(returncode=0),                   # pr-merge-cmd
                MagicMock(returncode=0),                   # issue-edit --remove-label
                MagicMock(returncode=1, stderr="permission denied"),  # issue-close-cmd FAILS
        ]) as _mock_run3, \
             patch("builtins.open", mock_open(read_data="PR_ID")), \
             patch("os.path.exists", return_value=True), \
             patch("os.unlink", _mock_unlink3):
            _res3 = do_command({"action": "merge", "number": _N})
            if _res3.get("ok") is not False:
                _merge_failures.append(
                    f"T3 FAIL ok={_res3.get('ok')!r} expected False")
            _msg3 = _res3.get("msg", "")
            if "close" not in _msg3.lower() and "issue" not in _msg3.lower():
                _merge_failures.append(
                    f"T3 FAIL msg={_msg3!r} expected to contain issue-close failure text")
            if _mock_unlink3.called:
                _merge_failures.append(
                    "T3 FAIL os.unlink was called; pr_num_path must survive on close failure")

        if _merge_failures:
            for _mf in _merge_failures:
                print(_mf)
            sys.exit(1)
        print("PASS selftest-merge: idempotency-guard, atomic-cleanup, close-fail")
        sys.exit(0)

    print(f"crewboss-api on :{PORT}  repo={REPO}  auth={'on' if TOKEN else 'OFF'}", flush=True)
    ThreadingHTTPServer((os.environ.get("CB_API_HOST","127.0.0.1"), PORT), H).serve_forever()
