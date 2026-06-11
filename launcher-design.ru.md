# Лаунчер crewboss — design (автономный, nsjail + OAuth-подписка)

> Супер-подробный документ для работы. Простыми словами — [launcher-brief.ru.md](launcher-brief.ru.md).
> Связанные: [board-orchestration.md](board-orchestration.md) (Арх-2), [ux-roadmap.ru.md](ux-roadmap.ru.md).
> Код: `reference/launcher/`, CLI: `reference/bin/crewboss`. Статус: **DESIGN** (после red-team: 35 находок, 5 блокеров — учтены). Дата: 2026-06.

---

## 0. Цель и не-цели

**Цель.** Автономный многоролевой оркестратор: сам подхватывает задачи с борда в **детерминированную приоритетную
очередь** и запускает каждого агента **эфемерной `claude -p`-сессией в nsjail-песочнице** на Linux-хосте, на **токене
подписки (OAuth)**; плюс терминальный пульт (TUI).

**Не-цели.** НЕ веб/GUI. НЕ заменять `claude --agent`+скрипты. НЕ растворять честный потолок. НЕ предикат-LLM.
**НЕ LLM-диспетчер** — explicit non-goal: детерминированной очереди (prio→FIFO + role-routing + бюджет-гард) достаточно
при лимитах подписки (~1–3 параллельных); LLM-планировщик на таком флоте бесполезен и сам жрёт бюджет-пул
(red-team-кластер: дублирует рельсы, пропускает агрегатно-плохие планы, сходимость не доказана). Вернуть — только если
флот стабильно >5–7 и появится конкретный кейс плохого порядка.

**Платформа.** Флот на **Linux-хосте/VPS** (nsjail = Linux-only). Dev-машина (macOS) — только пульт/чат.

---

## 1. Что есть → меняем
`crewboss-launcher.sh`: poll, env-конфиг, **worktree + foreground executor**, claim, handle_result, retry, budget, kill-switch.
**Меняем:** worktree→**nsjail+`claude -p`**; один executor→**все роли**; один cap→**per-role**; нет приоритета→**детерм. очередь**;
PR в develop→**чартерные ветки**; нет статус-файлов→**контракт для панели**; API-ключ→**OAuth-токен подписки**; нет образа→**provision+nsjail-профиль**.

---

## 2. Архитектура — ДВА слоя

```
  Слой 2: ПАНЕЛЬ / TUI — наблюдатель+контроллер. Читает ground-truth, рисует флот, шлёт control.
          Политику не считает. Управляет и boss-сессией.   Можно убить — рельсы живут.
                    ▲ status.json/run.log/борд          ▼ control: flag-files, kill -SIG, gh, resume
  Слой 1: РЕЛЬСЫ / floor — детерминированно (включая планировщик), un-gated, но крошечно и в тестах.
          predicate (право) · детерм. scheduler (приоритет/кэпы/роутинг) · budget($-пул) · role-contracts ·
          nsjail-спавн · reconciler.    Никакого LLM. Никакого un-gated «мозга».
```
**LLM-диспетчера НЕТ** (см. §0). «Умность» планирования — детерминированные jq/bash-правила в рельсах → тестируемо,
без токен-цены, без негейченного суждения. Слои общаются **только через ФС + борд** (рестарт-безопасно, умирают независимо).

---

## 3. Принципы (до кода)
1. **Всё планирование детерминировано** (`launchable.sh` + scheduler-правила). Никаких LLM-решений «кого/в каком порядке».
2. **Caps — hard floor** ($-бюджет, per-role concurrency, kill-switch, retry, rate). В коде, в тестах.
3. **Keep floor small & tested.** Floor несёт много обязанностей (очередь+reconciler+provision+budget+спавн) → каждая бага = негейченное действие → **обязателен тест на каждую** (§15). Числовой ceiling размера floor — в README.
4. **Ground-truth, не самоотчёт.** Жив — `kill -0`+starttime; PR есть; лейбл; хвост лога. status.json — подсказка.
5. **Голый путь работает всегда** (без TUI — дешёвый предсказуемый режим).
6. **Эфемерность.** Один процесс/задача. Исключение — boss (resumable).

---

## 4. Слой 1 — Рельсы

### 4.1 Предикат (роли)
`launchable.sh` → список `{issue, role, charter, base, prio}`:

| Роль | Триггер |
|---|---|
| tech-lead | charter `type:charter` + `status:needs-plan` |
| executor | leaf: charter `approved` + deps закрыты + open + не {in-progress,review,blocked,hold} |
| analyst | `type:analysis`/`type:research` open; **или** leaf `status:blocked` (авто-триаж) |
| task-helper | `type:human-decision` + метка «нужен черновик» (если `autonomy.auto_answer`) |
| boss | не в очереди — человеком, §7 |

### 4.2 Детерминированный планировщик (бывший «диспетчер»)
Чистые правила, без LLM:
- **Очередь:** сорт launchable по `prio:P0>P1>P2` → FIFO. Авто-подхват.
- **Per-(issue,role) spawn-счётчик** в `run/budget.json` → hard-cap переспавна одной пары (закрывает analyst-петлю на blocked-leaf независимо от исхода).
- **Conservative-parallel — НЕ умом, а позицией:** необъявленные конфликты файлов (#82↔#83) ловит `Depends-on` (апстрим-качество tech-lead) + **бэкстоп на мерже в `charter/N`** («коллизия = переделка, не порча»). Планировщик не пытается быть умным.
- **Caps:** `concurrency.<role>` (executors — настраивается; дефолт **маленький**, §5), `concurrency.total`, `budget.cost_pct`, `budget.launches`, `retry_cap`, `rate_limit`, `pause`/`kill_switch` (флаг-файлы).

### 4.3 Role-contracts (валидация до/после)
| Роль | Запуск (prompt-to-file) | Success | Провал |
|---|---|---|---|
| tech-lead | декомпозируй charter #N в self-contained лифы (`Charter:`,`Depends-on`), `plan-review`, стоп | лифы + charter→`plan-review` | нет лифов → retry/blocked-charter |
| executor | возьми #N на `task/M` от `charter/C`; **`gh pr create -B charter/C -H task/M`** с `Closes #N`; стоп | PR в `charter/C` → leaf `review` | нет PR → retry→`blocked` |
| analyst | исследуй #N, findings-коммент с `crewboss-digest` | дайджест → close-gate | нет дайджеста → retry |
| task-helper | черновик ответа на #N | коммент+лейбл | — |

`handle_result` ветвится по `role`. Отдельные исходы кроме executor-fail: `infra/clone-failed → re-queue` (НЕ retry-capped), `net/egress-fail → re-queue` (отличать сетевой exit-код/5xx/timeout от «чистого прогона без артефакта» — иначе транзиентный egress даёт ложный `blocked`).

### 4.4 Спавн в nsjail (ядро — с фиксами)
```
nsjail --config run/profiles/<role>.cfg \
  --env CLAUDE_CODE_OAUTH_TOKEN --env GH_TOKEN --env GH_REPO=OWNER/REPO \
  --env HOME=/work/.home --env CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  --env CLAUDE_CODE_SKIP_PROMPT_HISTORY=1 \
  -- claude --agent <role> -p @/work/task.prompt --output-format json --no-session-persistence \
  2>&1 | redact_secrets > run/work/<task>/run.log
```
- **`claude -p` (НЕ `--bare`)** — `--bare` игнорит OAuth-токен. `ANTHROPIC_API_KEY` **не пробрасываем** (приоритетнее OAuth → ушёл бы на платный API; nsjail чистит env → ок).
- **GH_REPO=OWNER/REPO** обязателен: в `--local`-клоне нет github-remote → `gh` иначе падает «no git remotes point to a known GitHub host».
- **prompt-to-file** (`@/work/task.prompt`) — никакой интерполяции title/body (экранирование + инъекция из недоверенного issue-текста).
- **redact_secrets** на stdout/stderr → маскирует `ghp_*`/`ghs_*`/`sk-ant-*`/`ya29.*` (любой `set -x`/verbose/echo $TOKEN не утечёт в `run.log`); `run.log`+`status.json` создаём **0600**; crash-cleanup чистит каталог.
- **rootfs (a):** bind-RO `/usr`,`/bin`,libs+toolchain (**видны RO** — формулировка «host невидим» неверна, оговорка относится к остатку), **`nosuid,nodev`** на всех bind-mount, **NNP включён** (disable_no_new_privs=false).
- **rlimits в профиле** (против враждебных дефолтов nsjail): `rlimit_fsize_mb≥512` (дефолт 1MiB → SIGXFSZ), `rlimit_nofile≥4096` (дефолт 32 → EMFILE на старте Node+claude+git), `rlimit_as` = LLONG_MAX/≥8192 (реальный кап — cgroup mem), `rlimit_cpu`=unlimited (кап — cgroup `cpu.max` + wall-clock stall-timeout reconciler'а; rlimit_cpu непредсказуем под I/O-wait).
- **seccomp** (Kafel allowlist под syscall-поверхность Node+git+gh) — **обязателен** (nsjail по умолчанию seccomp НЕ применяет; без него jail держит только namespaces+rlimits, а ядерная attack-surface открыта — это и есть «третий гвоздь», без seccomp его НЕТ). **✅ Валидировано (Раунд 3c, 2026-06-10):** `claude.kafel` (`DEFAULT KILL_PROCESS`, 168 имён + 5 числовых `SYSCALL[n]` — kafel-таблица amd64 не знает stat/fstat/lstat/sendfile/uname); claude+git проходят под фильтром, 23 опасных syscall'а убиты SIGSYS. Поверхность снята на смоук-слайсе — пере-снять на боевом executor'е (npm/vitest/build). Рецепт — [proto/seccomp/README.md](proto/seccomp/README.md).
- **Сеть** — §8. **Liveness/логи:** jail — обычный процесс хоста → `kill -0 <pid>`+starttime; stdout в хостовый `run.log`.

### 4.5 Репо в песочницу (свежо+изолированно+дёшево — с фиксами)
- Хост: **`git clone --mirror`** (refspec `+refs/*:refs/*`; **не `--bare`** — тот без fetch-refspec, новые `charter/N` не подтянутся). Освежать `git remote update --prune` под **`flock -x mirror.lock`**.
- На задачу: **`flock -s mirror.lock` → `git clone --local <mirror> repo`** (хардлинк — мгновенно; shared-lock: N клонов ок, но не одновременно с update, иначе gc/repack побьёт хардлинки) → таргетный `git fetch origin charter/C` (минимизировать гонку) → checkout `charter/C`.
- **🔴 Фикс push:** сразу после клона — `git -C repo remote set-url --push origin https://x-access-token:$GH_TOKEN@github.com/OWNER/REPO.git` (или второй remote `github`). Иначе origin указывает на **локальное зеркало**, push не уходит на GitHub, PR не появляется, **все** задачи метятся провалом.
- **Инвариант: зеркало и `run/work/` — на ОДНОЙ ФС** (один `st_dev`), иначе `--local` молча делает полный копи (ломает «cold-start ~ноль», раздувает диск). doctor сравнивает device-номера; для tmpfs/overlay-работ — либо общая ФС, либо `git worktree add` из зеркала.
- **charter/C** создаёт **floor** (а не code-blind tech-lead) идемпотентно: `git push origin <approved-base-sha>:refs/heads/charter/C` (если ветка ушла вперёд от прошлых коммитов — НЕ ресетить).
- После выхода — каталог задачи выбрасываем (исход уже захвачен).

### 4.6 Reconciler (с reboot-survival)
- На claim писать **pid+starttime** (`/proc/pid/stat` поле 22 или cgroup-id) атомарно — чтобы `kill -0` после reboot не давал false-alive из-за переиспользованного PID.
- Каждый тик: для активных — `kill -0`+starttime + возраст. Мёртвый без артефакта → провал (retry/blocked). Завис (лог не растёт > timeout) → флаг `stalled`.
- **Reconcile-on-startup:** скан `run/work/*`; для `status.json` с phase≠done/failed проверить pid+starttime, осиротевшие (reboot/SIGKILL) — снять `in-progress`, вернуть в очередь. **Cleanup** `run/work/*` (trap EXIT + startup sweep) — токены/секреты не должны остаться на диске после краша.

### 4.7 provision + doctor (вместо образа)
`crewboss provision`: toolchain (node+claude+gh+git+jq) на хост; nsjail-профили ролей; bare-**mirror**; пре-апрув OAuth-токена (одноразовый «usage approval» промпт).
`crewboss doctor` (hard-fail на блокерах): Linux; **user-namespaces включены — HARD-FAIL если нет** (без них mapped-root=настоящий host-root; не warn-and-continue); nsjail+**seccomp-запись в профиле**; toolchain; `CLAUDE_CODE_OAUTH_TOKEN` задан, **`ANTHROPIC_API_KEY` пуст**; bot-`GH_TOKEN` (fine-grained, §11); **push-URL task-репо резолвится в github.com**; зеркало имеет `+refs/*:refs/*`; зеркало и `run/work` на одной ФС; redaction-фильтр присутствует; **нет другого лаунчера** (§9-lock); branch protection.

---

## 5. Токены подписки + бюджет (несущий)
- **Auth:** один раз `claude setup-token` → OAuth-токен (срок refresh-токена ~1 год; access ~60 мин, CLI рефрешит сам). В jail только `CLAUDE_CODE_OAUTH_TOKEN`. **`claude -p` (не `--bare`) + OAuth работает на подписке** (доки: precedence API-key > OAuth → API-key не должно быть; bare игнорит OAuth). Каждый — **своя личная подписка** (не Claude-team).
- **Биллинг (с 15.06.2026):** headless `claude -p` жрёт **отдельный месячный долларовый credit-pool** ($20 Pro / $100 Max5x / $200 Max20x) **по standard API-ценам, без отката** (исчерпан → запросы fail, не queue). Реальный потолок флота — **доллары в пуле**, не «N параллельных» ($20 Pro по Opus = единицы прогонов executor'а). Config: `budget.monthly_credit_usd` (размер пула твоего плана), `budget.cost_pct` (% стоп), `overflow_billing` (default=false → hard-stop при исчерпании; true = реальные деньги по API).
- **Параллельность:** реально 1–3 (Pro≈1, Max5x≈2, Max20x≈3–4) — но ограничитель **бюджет, не счётчик сессий**. Opus-heavy флот выжигает $100 Max5x за дни.
- **Бюджет-гард:** `--output-format json` → `total_cost_usd` на прогон → сумма в `run/budget.json`, стоп при ≥`cost_pct`. (`total_cost_usd` по API-ставкам, под OAuth может не совпасть с реальным списанием из пула — оговорка.) Две ветки исчерпания: **(a) HTTP 429** → пауза+backoff+requeue; **(b) исчерпание пула** (класс ошибки снять эмпирически — может быть НЕ 429, а billing/insufficient-credit) → **hard-stop всех + алерт человеку** (backoff бесполезен).
- **Fair-use:** авто-флот на персональной подписке — серая зона ToS («необычная активность» → риск throttle). Помечаем честно; account-sharing отпадает (каждый под своим токеном).

---

## 6. Авто-гейты (boss/task-helper) — opt-in
`autonomy.auto_approve_plans` / `auto_answer_human_tasks` по умолчанию **off** (человек в петле). Панель показывает уровень автономии крупно.

---

## 7. Boss — управляется лаунчером (особый)
- **Resumable-сессия:** `run/boss.session` хранит id; «открыть boss» = `claude --agent boss --resume <id>`. Контекст не теряется.
- **Code-blind** (`tools: Bash`, хук блокит чтение кода) → **без jail** (или лёгкий: только `gh`+сеть к github). Не нужен ни репо, ни push-токен.
- **В TUI:** пейн/действие «Boss» — attach (suspend-and-handover TTY), чат, detach; виден статус сессии.
- Таксономия: **эфемерные автономные** (executor/tech-lead/analyst/task-helper) vs **boss — интерактивный, человеком, из пульта**.

---

## 8. Сеть / egress (host-side, выбрать одну модель)
nsjail по умолчанию `clone_newnet=true` → netns с **одним loopback, без маршрутов/DNS** → без host-side-обвязки ни claude, ни git не выйдут НИКУДА (мгновенный фейл, неотличим от «агент не справился»). Egress — **host-side артефакт**, его корректность = безопасность хоста.

**Рекомендуется: фильтрующий прокси** (slirp4netns/pasta — без CAP_NET_ADMIN): jail видит только loopback+маршрут до localhost-прокси; прокси держит **доменный allowlist** и сам резолвит DNS (внутри jail DNS не нужен, DNS-туннелинг закрыт; drop UDP/53 наружу). **✅ Валидировано (Раунд 3b, 2026-06-10):** реализация — CONNECT-прокси на unix-сокете (python3, без slirp/pasta — их на AL2023 нет из коробки) + in-jail TCP-мост; рецепт и скрипты — prototype-log / `proto/net/`.
**Альтернатива (veth+NAT):** host-provision = bridge + veth-пара/задача + nftables FORWARD/MASQUERADE + `ip_forward=1` + `/etc/netns/<ns>/resolv.conf`; «host-provision раз» vs «per-spawn подключение (мс)».

**Allowlist (полный):** `github.com`, `api.github.com`, `codeload.github.com`, `*.githubusercontent.com`, `objects.githubusercontent.com`, `api.anthropic.com`, **`console.anthropic.com`**, **`platform.claude.com`** (последние два — OAuth-refresh, без них 401-петля). Доменный allowlist (не IP): github/anthropic CDN-фронтятся, `api.github.com/meta` отдаёт ~108 ротирующихся CIDR → жёсткий nft-set ронит `git push`/`gh` при первой ротации. IP-слой — только как defense-in-depth (Anthropic публикует стабильный `160.79.104.0/23` для inference; github — нет).

**Честно:** allowlist держит «куда тянуться», но **не** эксфильтрацию через сам разрешённый канал — неустранимо. Лог egress для аудита.

---

## 9. Контракт Engine↔View + single-instance
Рельсы пишут, панель читает — **только файлы + борд**:
- `run/work/<task>/status.json`: `{task,role,charter,branch,base,pid,starttime,phase,started_at,updated_at,last_line(≤200,redacted),exit_code,cost_usd,pr,review_decision,stalled}` (0600).
- `run/work/<task>/run.log` (redacted, 0600) · `run/launcher.json` (режим/caps/totals/autonomy/heartbeat) · `run/budget.json` (сумма $, %, per-(issue,role) счётчики) · `run/boss.session` · **борд** (каноничная state-machine).
- **Single-instance:** `flock run/launcher.lock` на старте + doctor-проверка. Два лаунчера → double-spend дорогого $-пула мимо `cost_pct` + двойной спавн. (board-orchestration.md строка 47 «несколько лаунчеров» — обновить: требует партиционирования `hash(#)%N` + per-shard budget-файлов.)

Контроль (панель→рельсы): флаг-файлы (`pause`,`kill_switch`), сигналы по pgid (kill #N), `gh issue edit` (approve #N), запись конфига, `claude --resume` (boss). Никакого RPC.

---

## 10. Панель (TUI)
- **Данные на агента:** `status.json` + `kill -0`+starttime + хвост `run.log` + `reviewDecision`. Фазы executor: `starting→writing-code→opening-pr→done|failed`.
- **3 режима** (настройка+хоткей): компактный (строка) · таблица (issue·role·charter·branch·phase·elapsed·pid·cost·pr·review, сорт.) · подробный (карточка+хвост лога). + опц. ambient (второй монитор) — **читает только redacted last_line**.
- **Виды:** Fleet · Board · Queue (что в очереди/почему ждёт) · Detail/Log (tail+attach) · **Boss** (чат) · Settings.
- **Управление:** переиспользуемые хоткеи (`j/k`,`l` launch/approve,`p` pause,`K` kill,`a` attach,`b` boss,`v` вид,`?` help) + command-палитра `:` + `?` авто-из таблицы хоткеев. **Confirm-модалка** на деструктив (даже в autonomy).
- **Cadence:** focused ~100ms · fleet ~250–500ms · борд/тик ~10s · health/reconcile ~30s. Не блокировать render; анти-flicker = diff кадра.
- **Robustness:** `isatty`→`--headless`/`--json`; `NO_COLOR`; SIGWINCH (layout из измеренных размеров); восстановление терминала на любом выходе; bounded-логи; reconcile-on-startup.

---

## 11. Безопасность / честный потолок
- **nsjail держит** host-ФС, чужие сети/репо, ресурсы (cgroup/rlimits), **и ядерную attack-surface — ТОЛЬКО если задан seccomp** (§4.4). Без seccomp «третьего гвоздя» нет.
- **nsjail НЕ держит** злоупотребление токеном в разрешённом github-канале и эксфильтрацию через него — неустранимо для агента, которому нужны github+anthropic. Не продавать sandbox как полный enforcement (та же over-claim-ловушка).
- **Скоуп токена:** **fine-grained PAT** на целевой репо, permissions `contents:write`+`pull_requests:write` only (issues/metadata внутри jail НЕ нужны — все label/state делает claim/handle_result на ХОСТЕ). Иначе `repo`-scope даёт jailed-агенту **подменить лейблы стейт-машины борда** (обойти координацию) — egress-allowlist это не ловит, branch protection держит только мерж. doctor warn'ит на classic repo-scope.
- **Реальные якоря** (как и в crewboss): tool-absence (`--agent`) + completion-gate (non-author APPROVED + green) + server-side branch protection + fine-grained token. Jail+seccomp — defense-in-depth поверх, не вместо.
- **brief-формулировка** «не вылезет за периметр» квалифицируется: в рамках модели угроз lazy/over-eager/dishonest; kernel-exploit вне scope.

---

## 12. Tech-stack
- **Рельсы — bash** (спавн nsjail + redact-redirect + `kill -0` + jq-планировщик; профиль декларативен). Оставляем.
- **Панель** — сначала **контракт §9**, минимальная панель (bash+tmux ок), затем при упоре в потолок — **Go/Bubble Tea** отдельным бинарём по тому же контракту, не трогая рельсы.
- Референсы: Operator/Baton (poll-dispatch-reconcile по борду) · Claude Squad/Recon (status из файлов агента, display-modes) · k9s/lazygit/lazydocker (UI) · nsjail (изоляция недоверенного процесса).

---

## 13. Честные напряжения
1. **Un-gated «мозга» больше нет** (LLM-диспетчер выкинут) → планирование детерминировано/тестируемо; граница доверия — только caps+гейты. Главное напряжение прошлой версии снято.
2. **Floor несёт 10+ обязанностей** (§3.3) — каждая бага = негейченное действие (недосчёт бюджета→перерасход пула; false-dead reconciler→убитый живой executor). Митигация: тест на каждую (§15) + числовой ceiling размера в README + mirror-refresh в cron/timer, не в poll-тике.
3. **Коррелированное доверие** — merge гейтят люди/BP, не лаунчер.
4. **nsjail не панацея** (§11) — token-channel + exfil неустранимы; root-jail-фолбэк hard-fail (§4.7).
5. **Подписка ограничивает флот** ($-пул) — бюджет-гард несущий; авто-флот на персональной подписке = серая зона ToS.
6. **user-namespaces** обязательны (на managed-VPS часто off → doctor hard-fail, не root-режим).

---

## 14. Фазовый план (slices)
- **Slice 0 — рельсы.** nsjail-спавн (профиль+seccomp+rlimits+nosuid) + `claude -p`/OAuth + все роли (`handle_result` по роли) + предикат `{issue,role,…}` + детерм. планировщик (prio→FIFO + per-(issue,role)-cap + role-routing) + чартерные ветки (floor создаёт `charter/C`) + mirror+`--local`+push-remote-fix+одна-ФС+flock + GH_REPO + prompt-to-file + redaction + статус-файлы(0600) + бюджет-гард($-пул) + single-instance-lock + `crewboss provision`/`doctor`. **Сетевой слой (§8) — часть Slice 0** (иначе ничего не работает).
- **Slice 1 — минимальная панель + boss.** Контракт §9; Fleet+Board+Queue; хоткеи pause/kill/approve/attach; boss из пульта (resume+attach); headless/json.
- **Slice 2 — полный TUI.** 3 режима, палитра, settings-форма, resize/NO_COLOR/terminal-restore, ambient.
- **Slice 3 — reconciler-полировка + integrate-PR** (charter/N→develop автооткрытие) + adaptive.
*(LLM-диспетчер — НЕ slice; возможный будущий триггер: флот стабильно >5–7.)*

---

## 15. Тестирование
- **git-фиксы (критично):** push-URL task-репо резолвится в github (не локально); зеркало `--mirror` тянет новый `charter/N`; одна-ФС → `--local` хардлинкает (не копи).
- **nsjail-профиль:** jail режет (нет хостового репо, нет лишней сети, лимиты применяются); **ложно-малые rlimits НЕ ловятся голым smoke** → отдельный тест: executor на репо-фикстуре завершается exit 0, не от сигнала; seccomp: блокированный сисколл (ptrace/add_key) убивается; setuid-бинарь не повышает привилегии (nosuid).
- **Бюджет:** property-тест сумматора `total_cost_usd` (конкурентная запись + краш-в-середине) — money-gating нельзя на одном integration-тесте.
- **Рельсы:** per-role контракты; nsjail-спавн через стаб; reconciler reboot (pid-reuse → не false-alive); infra/clone-failed/net-fail → re-queue (не blocked).
- **doctor/provision:** hard-fail без userns; все проверки §4.7.
- **Панель:** `teatest`(Go)/snapshot(bash); isatty/headless.

---

## 16. Открытые решения (нужен ты)
1. Панель A (bash+tmux) или B (Go) — или «контракт сначала» (рекоменд.).
2. ТУЗ-бот сейчас? (нужен для «2 из 3» на мерже).
3. Авто-boss/авто-assist opt-in? (рекоменд. default человек).
4. **Где Linux-хост** (свой VPS/облако) — от этого user-namespaces (managed часто off) и возможность host-side egress.
5. **Egress-модель:** фильтрующий прокси (рекоменд.) vs veth+NAT.
6. **Тариф подписки под флот:** $20 Pro (единицы Opus-прогонов) / $200 Max20x / прямой API. После 15.06 ограничитель — $-пул.
7. Подтвердить `-p`+OAuth **30-сек смоуком на хосте** перед опорой (доки ясны, но эмпирика финальна).
