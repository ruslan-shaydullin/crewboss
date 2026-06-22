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
import json, os, shutil, subprocess, sys, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO   = os.environ.get("CB_REPO", "")
CB_HOME= os.environ.get("CB_HOME", os.path.expanduser("~/cbnet"))
RUN    = os.path.join(CB_HOME, "run")
TOKEN  = os.environ.get("CB_API_TOKEN", "")
PORT   = int(sys.argv[sys.argv.index("--port")+1]) if "--port" in sys.argv else int(os.environ.get("CB_API_PORT","8787"))
BOARD  = os.path.join(CB_HOME, "board-gh.sh")

def sh(args, timeout=30):
    try: return subprocess.run(args, capture_output=True, text=True, timeout=timeout).stdout
    except Exception: return ""

def read_json(path, default):
    try: return json.load(open(path))
    except Exception: return default

def save_queue(order):
    """Atomically persist the operator queue (ordered charter numbers) to run/queue.json.
    Mirrors the tempfile+rename pattern used for other run-state writes; the launcher reads
    it via jq '.order[]' (#281). Empty order = cleared queue -> launcher default behaviour."""
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
                                   phase="merging" if loop_running else "awaiting",
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

def build_state():
    issues = []
    if REPO:
        try:
            raw = sh(["gh","issue","list","-R",REPO,"--state","all","-L","100",
                      "--json","number,title,labels,state,body"]) or "[]"
            issues = json.loads(raw)
        except Exception: issues = []
    board = []
    for it in issues:
        labels = [l["name"] for l in it.get("labels",[])]
        if   "type:milestone" in labels:           kind = "milestone"
        elif "type:charter"   in labels:           kind = "charter"
        else:                                      kind = "leaf"
        if   it.get("state")=="CLOSED":            st="done"
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
    """Detail for one task: live status + the brief it was given + the redacted run log."""
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
        # CI gate
        r = subprocess.run(
            ["gh", "pr", "view", pr_num, "-R", REPO, "--json", "statusCheckRollup",
             "--jq", '[.statusCheckRollup[]?.state] | all(. == "SUCCESS")'],
            capture_output=True, text=True, timeout=30)
        try:
            ci_ok = r.stdout.strip() == "true"
        except Exception:
            ci_ok = False
        if not ci_ok:
            return {"ok": False, "msg": "CI gate not green — merge blocked"}
        # Promote draft
        r = subprocess.run(["gh", "pr", "ready", pr_num, "-R", REPO],
                           capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            return {"ok": False, "msg": r.stderr.strip() or "pr ready failed"}
        # Merge
        r = subprocess.run(["gh", "pr", "merge", pr_num, "-R", REPO, "--merge"],
                           capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            return {"ok": False, "msg": r.stderr.strip() or "merge failed"}
        # Close issue (best-effort)
        r2 = subprocess.run(
            ["gh", "issue", "close", n, "-R", REPO, "--comment", "Charter merged and closed."],
            capture_output=True, text=True, timeout=30)
        if r2.returncode != 0:
            print(f"WARNING: merge succeeded but issue close failed: {r2.stderr.strip()}", file=sys.stderr)
        return {"ok": True}
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
                    time.sleep(int(os.environ.get("CB_API_POLL","3")))
            except Exception: return
        return self._send(404,{"ok":False,"msg":"not found"})
    def do_POST(self):
        if not self._auth_ok(): return self._send(401,{"ok":False,"msg":"unauthorized"})
        path = self.path.split("?",1)[0]
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

if __name__=="__main__":
    if "--selftest-synthetic-gate" in sys.argv:
        # Verify that synthetic chips respect loop_running
        _by_n = {
            10: {"state": "review",     "kind": "leaf",    "title": "Leaf in review"},
            20: {"state": "needs-plan", "kind": "charter", "title": "Charter needing plan"},
        }
        failures = []

        # --- loop_running=False: both chips must be phase="awaiting" ---
        agents_idle = build_agents(_by_n, loop_running=False)
        for a in agents_idle:
            if a.get("role") == "integrator" and a.get("pid") is None:
                if a.get("phase") != "awaiting":
                    failures.append(f"FAIL integrator phase={a.get('phase')!r} when loop_running=False (expected 'awaiting')")
            if a.get("role") == "tech-lead" and a.get("pid") is None:
                if a.get("phase") != "awaiting":
                    failures.append(f"FAIL tech-lead phase={a.get('phase')!r} when loop_running=False (expected 'awaiting')")
        # Confirm chips ARE present (not suppressed)
        if not any(a.get("role") == "integrator" and a.get("pid") is None for a in agents_idle):
            failures.append("FAIL integrator synthetic chip missing when loop_running=False")
        if not any(a.get("role") == "tech-lead" and a.get("pid") is None for a in agents_idle):
            failures.append("FAIL tech-lead synthetic chip missing when loop_running=False")

        # --- loop_running=True: integrator=merging, tech-lead=planning ---
        agents_live = build_agents(_by_n, loop_running=True)
        for a in agents_live:
            if a.get("role") == "integrator" and a.get("pid") is None:
                if a.get("phase") != "merging":
                    failures.append(f"FAIL integrator phase={a.get('phase')!r} when loop_running=True (expected 'merging')")
            if a.get("role") == "tech-lead" and a.get("pid") is None:
                if a.get("phase") != "planning":
                    failures.append(f"FAIL tech-lead phase={a.get('phase')!r} when loop_running=True (expected 'planning')")

        if failures:
            for f in failures:
                print(f)
            sys.exit(1)
        print("PASS synthetic-gate: idle→awaiting, live→merging/planning")
        sys.exit(0)

    print(f"crewboss-api on :{PORT}  repo={REPO}  auth={'on' if TOKEN else 'OFF'}", flush=True)
    ThreadingHTTPServer(("127.0.0.1",PORT), H).serve_forever()
