#!/usr/bin/env python3
"""crewboss TUI — terminal control panel (design §10). Reads the board (gh issues+labels) +
run/*.json (Engine->View is read-only files + board), controls via flag-files / labels / a
backgrounded launcher. Run it in your SSH session:

    CB_REPO=owner/repo CB_HOME=~/cbnet python3 crewboss-tui.py        # interactive
    CB_REPO=owner/repo python3 crewboss-tui.py --dump                 # one-shot render (no curses)

Keys: [r]un launcher  [p]ause toggle  [k]ill-switch toggle  [a]pprove charter  [q]uit
"""
import curses, json, os, subprocess, sys, time

REPO    = os.environ.get("CB_REPO", "")
CB_HOME = os.environ.get("CB_HOME", os.path.expanduser("~/cbnet"))
RUN     = os.path.join(CB_HOME, "run")
REFRESH = int(os.environ.get("CB_TUI_REFRESH", "3"))

def sh(args, timeout=25):
    try: return subprocess.run(args, capture_output=True, text=True, timeout=timeout).stdout
    except Exception: return ""

def board():
    if not REPO: return []
    try: issues = json.loads(sh(["gh","issue","list","-R",REPO,"--state","all","-L","100",
                                 "--json","number,title,labels,state"]) or "[]")
    except Exception: return []
    rows = []
    for it in issues:
        labels = [l["name"] for l in it.get("labels", [])]
        kind = "charter" if "type:charter" in labels else "leaf"
        if   it.get("state") == "CLOSED":          st = "done"
        elif "hold" in labels:                     st = "held"
        elif "status:blocked" in labels:           st = "blocked"
        elif "status:review" in labels:            st = "review"
        elif "status:in-progress" in labels:       st = "in-progress"
        elif "status:approved" in labels:          st = "approved"
        elif "status:plan-review" in labels:       st = "plan-review"
        elif "status:needs-plan" in labels:        st = "needs-plan"
        else:                                      st = "open"
        role = next((l.split(":",1)[1] for l in labels if l.startswith("role:")), "")
        cost = pr = ""
        sj = os.path.join(RUN, "work", str(it["number"]), "status.json")
        if os.path.exists(sj):
            try:
                d = json.load(open(sj)); cost = d.get("cost_usd",""); pr = d.get("pr") or ""
            except Exception: pass
        rows.append(dict(n=it["number"], kind=kind, role=role, state=st, cost=cost, pr=pr,
                         title=it.get("title","")))
    return sorted(rows, key=lambda r: -r["n"])

def summary():
    spent = cap = 0.0
    try: spent = json.load(open(os.path.join(RUN,"budget.json")))["spent_usd"]
    except Exception: pass
    try:
        c = json.load(open(os.path.join(RUN,"config.json"))); cap = c["monthly_credit_usd"]*c["cost_pct"]/100
    except Exception: pass
    return spent, cap, os.path.exists(os.path.join(RUN,"pause")), os.path.exists(os.path.join(RUN,"kill_switch"))

def toggle(name):
    p = os.path.join(RUN, name)
    (os.remove(p) if os.path.exists(p) else open(p,"w").close())

def start_launcher():
    os.makedirs(RUN, exist_ok=True)
    try: subprocess.Popen(["bash", os.path.join(CB_HOME,"crewboss-launcher-gh.sh"),"run"],
                          env=os.environ, stdout=open(os.path.join(RUN,"launcher.out"),"a"),
                          stderr=subprocess.STDOUT)
    except Exception: pass

def approve(n):
    sh(["gh","issue","edit",str(n),"-R",REPO,"--add-label","status:approved","--remove-label","status:plan-review"])

# ---------- dump (non-interactive) ----------
def dump():
    spent, cap, paused, killed = summary()
    print(f"crewboss — {REPO}   pool ${spent:.4f}/${cap:.2f}   "
          f"pause={'ON' if paused else 'off'} kill={'ON' if killed else 'off'}")
    print(f"{'#':>5} {'kind':8} {'role':9} {'state':12} {'cost':>8}  pr / title")
    for r in board():
        tail = r["pr"] or r["title"][:48]
        c = f'{r["cost"]:.4f}' if isinstance(r["cost"],(int,float)) and r["cost"] else ""
        print(f'{r["n"]:>5} {r["kind"]:8} {r["role"][:9]:9} {r["state"]:12} {c:>8}  {tail}')

# ---------- curses ----------
COLORS = {"done":2,"review":5,"in-progress":4,"blocked":1,"held":3,"approved":2}
def ui(scr):
    curses.curs_set(0); curses.use_default_colors()
    for i,(fg) in enumerate([curses.COLOR_RED,curses.COLOR_GREEN,curses.COLOR_YELLOW,
                             curses.COLOR_BLUE,curses.COLOR_MAGENTA,curses.COLOR_CYAN],1):
        curses.init_pair(i, fg, -1)
    curses.halfdelay(max(1, REFRESH*10))
    msg = ""
    while True:
        scr.erase(); h,w = scr.getmaxyx()
        spent,cap,paused,killed = summary()
        hdr = f" crewboss  {REPO}   pool ${spent:.4f}/${cap:.2f} "
        flags = f"[pause {'ON' if paused else 'off'}] [kill {'ON' if killed else 'off'}]"
        scr.addstr(0,0, hdr.ljust(w-len(flags)-1)[:w-len(flags)-1], curses.A_REVERSE)
        scr.addstr(0, w-len(flags)-1, flags, curses.color_pair(1 if (paused or killed) else 6))
        cols = f"{'#':>5} {'kind':7} {'role':8} {'state':12} {'cost':>8}  pr / title"
        scr.addstr(2,0, cols[:w-1], curses.A_BOLD)
        y=3
        for r in board():
            if y>=h-2: break
            tail = (r["pr"] or r["title"])[:max(0,w-46)]
            c = f'{r["cost"]:.4f}' if isinstance(r["cost"],(int,float)) and r["cost"] else ""
            line = f'{r["n"]:>5} {r["kind"][:7]:7} {r["role"][:8]:8} {r["state"]:12} {c:>8}  {tail}'
            scr.addstr(y,0, line[:w-1], curses.color_pair(COLORS.get(r["state"],0)))
            y+=1
        foot = " [r]un  [p]ause  [k]ill  [a]pprove#  [q]uit    " + msg
        scr.addstr(h-1,0, foot[:w-1], curses.A_REVERSE)
        scr.refresh()
        try: ch = scr.getch()
        except KeyboardInterrupt: break
        if ch == -1: continue
        c = chr(ch) if 0<=ch<256 else ""
        if   c=="q": break
        elif c=="p": toggle("pause");       msg="paused"  if os.path.exists(os.path.join(RUN,"pause")) else "resumed"
        elif c=="k": toggle("kill_switch"); msg="kill-switch ON" if os.path.exists(os.path.join(RUN,"kill_switch")) else "kill-switch off"
        elif c=="r": start_launcher();      msg="launcher started (bg)"
        elif c=="a":
            curses.echo(); curses.curs_set(1); scr.addstr(h-1,0," approve charter #: ".ljust(w-1), curses.A_REVERSE)
            try: n=scr.getstr(h-1,19,8).decode().strip()
            except Exception: n=""
            curses.noecho(); curses.curs_set(0)
            if n.isdigit(): approve(n); msg=f"approved #{n}"

if __name__ == "__main__":
    if "--dump" in sys.argv: dump()
    else:
        try: curses.wrapper(ui)
        except KeyboardInterrupt: pass
